use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

mod codec;
mod index_store;

use anyhow::{Context, Result, anyhow};
use time::OffsetDateTime;
use uuid::Uuid;

use crate::backup::{
    BackupAccount, BackupBundle, MAX_BACKUP_ACCOUNTS, automatic_backup_password, read_encrypted,
    write_encrypted,
};
use crate::model::{
    AccountUsageView, AiProvider, DisplayIdentity, EnvironmentKind, METADATA_SCHEMA_VERSION,
    MetadataIndex, SavedAccountMetadata, SnapshotBlob,
};
use crate::secrets::{LocalSecretStore, SecretStore};
use crate::usage::{usage_error_blocks_activation, usage_error_requires_login};
use codec::{decode_snapshot, encode_snapshot};
use index_store::MetadataIndexStore;

pub struct SnapshotRepository<S> {
    data_dir: PathBuf,
    index_store: MetadataIndexStore,
    secret_store: S,
}

struct PreparedBackupImport {
    index: MetadataIndex,
    snapshots: Vec<PreparedSnapshot>,
    created: usize,
    updated: usize,
}

struct PreparedSnapshot {
    secret_key: String,
    encoded_snapshot: Vec<u8>,
    previous_value: Option<Vec<u8>>,
}

impl<S> SnapshotRepository<S>
where
    S: SecretStore,
{
    pub fn new(data_dir: &Path, secret_store: S) -> Self {
        Self {
            data_dir: data_dir.to_path_buf(),
            index_store: MetadataIndexStore::new(data_dir),
            secret_store,
        }
    }

    pub fn list_accounts(
        &self,
        environment: &EnvironmentKind,
    ) -> Result<Vec<SavedAccountMetadata>> {
        let mut accounts = self
            .index_store
            .load_index()?
            .accounts
            .into_iter()
            .filter(|account| &account.environment == environment)
            .collect::<Vec<_>>();
        accounts.sort_by_key(|account| std::cmp::Reverse(account.updated_at));
        Ok(accounts)
    }

    pub fn recover_legacy_snapshots(
        &self,
        environment: &EnvironmentKind,
        legacy_data_dir: &Path,
    ) -> Result<(usize, usize, usize)> {
        let legacy_index = MetadataIndexStore::new(legacy_data_dir).load_index()?;
        let legacy_store = LocalSecretStore::new(&legacy_data_dir.join("snapshots"));
        let mut current_index = self.index_store.load_index()?;
        let mut recovered_accounts = 0;
        let mut imported_accounts = 0;
        let mut skipped_accounts = 0;

        for legacy in legacy_index
            .accounts
            .into_iter()
            .filter(|account| &account.environment == environment)
        {
            if legacy
                .cached_usage_error
                .as_deref()
                .is_some_and(usage_error_blocks_activation)
            {
                skipped_accounts += 1;
                continue;
            }
            let Some(encoded_snapshot) = legacy_store.load(&legacy.secret_key)? else {
                skipped_accounts += 1;
                continue;
            };
            if decode_snapshot(&encoded_snapshot).is_err() {
                skipped_accounts += 1;
                continue;
            }

            self.secret_store
                .save(&legacy.secret_key, &encoded_snapshot)?;
            if let Some(position) = current_index
                .accounts
                .iter()
                .position(|account| account.id == legacy.id)
            {
                let current = &mut current_index.accounts[position];
                current.email = legacy.email;
                current.subject = legacy.subject;
                current.name = legacy.name;
                current.custom_label = legacy.custom_label;
                current.plan_label = legacy.plan_label;
                current.provider = legacy.provider;
                current.secret_key = legacy.secret_key;
                current.cached_usage = legacy.cached_usage;
                current.cached_usage_error = None;
                recovered_accounts += 1;
            } else {
                let mut imported = legacy;
                imported.cached_usage_error = None;
                current_index.accounts.push(imported);
                imported_accounts += 1;
            }
        }

        if recovered_accounts > 0 || imported_accounts > 0 {
            self.index_store.save_index(&current_index)?;
        }
        Ok((recovered_accounts, imported_accounts, skipped_accounts))
    }

    pub fn get_account(
        &self,
        environment: &EnvironmentKind,
        account_id: Uuid,
    ) -> Result<Option<SavedAccountMetadata>> {
        Ok(self
            .list_accounts(environment)?
            .into_iter()
            .find(|account| account.id == account_id))
    }

    pub fn save_snapshot(
        &self,
        environment: &EnvironmentKind,
        identity: &DisplayIdentity,
        snapshot: &SnapshotBlob,
    ) -> Result<(SavedAccountMetadata, bool)> {
        self.save_snapshot_inner(environment, identity, snapshot, true)
    }

    /// Persist the live account without decrypting every snapshot for a full backup.
    /// Used on the activate hot path where backup latency would block switching.
    pub fn save_snapshot_without_backup(
        &self,
        environment: &EnvironmentKind,
        identity: &DisplayIdentity,
        snapshot: &SnapshotBlob,
    ) -> Result<(SavedAccountMetadata, bool)> {
        self.save_snapshot_inner(environment, identity, snapshot, false)
    }

    fn save_snapshot_inner(
        &self,
        environment: &EnvironmentKind,
        identity: &DisplayIdentity,
        snapshot: &SnapshotBlob,
        write_backup: bool,
    ) -> Result<(SavedAccountMetadata, bool)> {
        let mut index = self.index_store.load_index()?;
        let now = OffsetDateTime::now_utc();
        let encoded_snapshot = encode_snapshot(snapshot)?;
        let existing_index = index.accounts.iter().position(|account| {
            &account.environment == environment
                && DisplayIdentity {
                    email: account.email.clone(),
                    subject: account.subject.clone(),
                    name: account.name.clone(),
                    plan_label: account.plan_label.clone(),
                }
                .matches(identity)
        });

        let (metadata, created) = if let Some(position) = existing_index {
            let account = &mut index.accounts[position];
            account.email = identity.email.clone();
            account.subject = identity.subject.clone();
            account.name = identity.name.clone();
            account.plan_label = identity.plan_label.clone();
            account.cached_usage_error = None;
            account.updated_at = now;
            (account.clone(), false)
        } else {
            let id = Uuid::new_v4();
            let metadata = SavedAccountMetadata {
                id,
                environment: environment.clone(),
                provider: AiProvider::OpenAi,
                email: identity.email.clone(),
                subject: identity.subject.clone(),
                name: identity.name.clone(),
                custom_label: None,
                plan_label: identity.plan_label.clone(),
                secret_key: format!("snapshot:{id}"),
                created_at: now,
                updated_at: now,
                last_activated_at: None,
                archived: false,
                cached_usage: None,
                cached_usage_error: None,
            };
            index.accounts.push(metadata.clone());
            (metadata, true)
        };

        self.secret_store
            .save(&metadata.secret_key, &encoded_snapshot)?;
        self.index_store.save_index(&index)?;
        if write_backup {
            self.maybe_write_automatic_full_backup(environment);
        }
        Ok((metadata, created))
    }

    pub fn load_snapshot(
        &self,
        environment: &EnvironmentKind,
        account_id: Uuid,
    ) -> Result<(SavedAccountMetadata, SnapshotBlob)> {
        let metadata = self
            .get_account(environment, account_id)?
            .ok_or_else(|| anyhow!("saved account {account_id} not found"))?;
        let encoded_snapshot = self
            .secret_store
            .load(&metadata.secret_key)?
            .ok_or_else(|| {
                anyhow!(
                    "saved snapshot data missing for {}. Re-save that account while logged into it.",
                    metadata.email
                )
            })?;
        let snapshot = decode_snapshot(&encoded_snapshot)?;
        Ok((metadata, snapshot))
    }

    pub fn replace_snapshot(
        &self,
        environment: &EnvironmentKind,
        account_id: Uuid,
        identity: &DisplayIdentity,
        snapshot: &SnapshotBlob,
        usage: Option<AccountUsageView>,
    ) -> Result<SavedAccountMetadata> {
        self.replace_snapshot_inner(environment, account_id, identity, snapshot, usage, true)
    }

    /// Update cached usage/auth without decrypting every account for a full backup.
    pub fn replace_snapshot_without_backup(
        &self,
        environment: &EnvironmentKind,
        account_id: Uuid,
        identity: &DisplayIdentity,
        snapshot: &SnapshotBlob,
        usage: Option<AccountUsageView>,
    ) -> Result<SavedAccountMetadata> {
        self.replace_snapshot_inner(environment, account_id, identity, snapshot, usage, false)
    }

    fn replace_snapshot_inner(
        &self,
        environment: &EnvironmentKind,
        account_id: Uuid,
        identity: &DisplayIdentity,
        snapshot: &SnapshotBlob,
        usage: Option<AccountUsageView>,
        write_backup: bool,
    ) -> Result<SavedAccountMetadata> {
        let mut index = self.index_store.load_index()?;
        let position = index
            .accounts
            .iter()
            .position(|account| account.id == account_id && &account.environment == environment)
            .ok_or_else(|| anyhow!("saved account {account_id} not found"))?;
        let encoded_snapshot = encode_snapshot(snapshot)?;
        let account = &mut index.accounts[position];
        account.email = identity.email.clone();
        account.subject = identity.subject.clone();
        account.name = identity.name.clone();
        account.plan_label = identity.plan_label.clone();
        account.cached_usage = usage;
        account.cached_usage_error = None;
        let metadata = account.clone();
        self.secret_store
            .save(&metadata.secret_key, &encoded_snapshot)?;
        self.index_store.save_index(&index)?;
        if write_backup {
            self.maybe_write_automatic_full_backup(environment);
        }
        Ok(metadata)
    }

    pub fn record_usage_error(
        &self,
        environment: &EnvironmentKind,
        account_id: Uuid,
        usage_error: String,
    ) -> Result<SavedAccountMetadata> {
        let mut index = self.index_store.load_index()?;
        let position = index
            .accounts
            .iter()
            .position(|account| account.id == account_id && &account.environment == environment)
            .ok_or_else(|| anyhow!("saved account {account_id} not found"))?;
        let account = &mut index.accounts[position];
        let confirms_usage_access = usage_error.contains("usage access forbidden (403)");
        if account
            .cached_usage_error
            .as_deref()
            .is_some_and(usage_error_blocks_activation)
            && !usage_error_requires_login(&usage_error)
            && !confirms_usage_access
        {
            return Ok(account.clone());
        }
        account.cached_usage_error = Some(usage_error);
        let metadata = account.clone();
        self.index_store.save_index(&index)?;
        Ok(metadata)
    }

    pub fn set_custom_label(
        &self,
        environment: &EnvironmentKind,
        account_id: Uuid,
        custom_label: Option<String>,
    ) -> Result<SavedAccountMetadata> {
        let mut index = self.index_store.load_index()?;
        let account = index
            .accounts
            .iter_mut()
            .find(|account| account.id == account_id && &account.environment == environment)
            .ok_or_else(|| anyhow!("saved account {account_id} not found"))?;
        account.custom_label = custom_label.filter(|value| !value.trim().is_empty());
        account.updated_at = OffsetDateTime::now_utc();
        let metadata = account.clone();
        self.index_store.save_index(&index)?;
        Ok(metadata)
    }

    pub fn set_archived(
        &self,
        environment: &EnvironmentKind,
        account_id: Uuid,
        archived: bool,
    ) -> Result<SavedAccountMetadata> {
        let mut index = self.index_store.load_index()?;
        let account = index
            .accounts
            .iter_mut()
            .find(|account| account.id == account_id && &account.environment == environment)
            .ok_or_else(|| anyhow!("saved account {account_id} not found"))?;
        account.archived = archived;
        account.updated_at = OffsetDateTime::now_utc();
        let metadata = account.clone();
        self.index_store.save_index(&index)?;
        Ok(metadata)
    }

    pub fn export_backup(&self, environment: &EnvironmentKind) -> Result<BackupBundle> {
        let mut accounts = Vec::new();
        for metadata in self.list_accounts(environment)? {
            let (_, snapshot) = self.load_snapshot(environment, metadata.id)?;
            accounts.push(BackupAccount {
                identity: DisplayIdentity {
                    email: metadata.email,
                    subject: metadata.subject,
                    name: metadata.name,
                    plan_label: metadata.plan_label,
                },
                custom_label: metadata.custom_label,
                archived: metadata.archived,
                snapshot,
            });
        }
        Ok(BackupBundle::new(accounts))
    }

    pub fn import_backup(
        &self,
        environment: &EnvironmentKind,
        backup: BackupBundle,
    ) -> Result<(usize, usize)> {
        let prepared = self.prepare_backup_import(environment, backup, false)?;
        self.apply_backup_import(&prepared)?;
        self.maybe_write_automatic_full_backup(environment);
        Ok((prepared.created, prepared.updated))
    }

    pub fn restore_latest_account_list_backup(&self) -> Result<usize> {
        self.index_store.restore_latest_automatic_backup()
    }

    pub fn restore_latest_full_backup(&self, environment: &EnvironmentKind) -> Result<usize> {
        let password = automatic_backup_password()?;
        // Prefer the fullest readable backup so a newer empty/shrunk backup cannot
        // destroy a larger prior roster when the user asks to restore.
        let backup = self
            .best_automatic_full_backup(&password)?
            .ok_or_else(|| anyhow!("no automatic full backup is available"))?;
        let count = backup.accounts.len();
        let previous_index = self.index_store.load_index()?;
        let prepared = self.prepare_backup_import(environment, backup, true)?;
        self.apply_backup_import(&prepared)?;
        let retained_keys = prepared
            .index
            .accounts
            .iter()
            .map(|account| account.secret_key.as_str())
            .collect::<HashSet<_>>();
        for removed in previous_index.accounts.iter().filter(|account| {
            &account.environment == environment
                && !retained_keys.contains(account.secret_key.as_str())
        }) {
            let _ = self.secret_store.delete(&removed.secret_key);
        }
        self.maybe_write_automatic_full_backup(environment);
        Ok(count)
    }

    fn best_automatic_full_backup(&self, password: &str) -> Result<Option<BackupBundle>> {
        let directory = self.automatic_backup_dir();
        if !directory.exists() {
            return Ok(None);
        }
        let mut paths = std::fs::read_dir(&directory)
            .with_context(|| format!("failed to read {}", directory.display()))?
            .filter_map(|entry| entry.ok())
            .map(|entry| entry.path())
            .filter(|path| {
                path.extension().and_then(|extension| extension.to_str()) == Some("codexroster")
            })
            .collect::<Vec<_>>();
        paths.sort_by_key(|path| {
            std::cmp::Reverse(
                std::fs::metadata(path)
                    .and_then(|metadata| metadata.modified())
                    .unwrap_or(SystemTime::UNIX_EPOCH),
            )
        });
        let mut best: Option<BackupBundle> = None;
        for path in paths {
            let Ok(bundle) = read_encrypted(&path, password) else {
                continue;
            };
            let replace = match &best {
                None => true,
                Some(current) => {
                    bundle.accounts.len() > current.accounts.len()
                        || (bundle.accounts.len() == current.accounts.len()
                            && bundle.exported_at > current.exported_at)
                }
            };
            if replace {
                best = Some(bundle);
            }
        }
        Ok(best)
    }

    fn prepare_backup_import(
        &self,
        environment: &EnvironmentKind,
        backup: BackupBundle,
        replace_environment: bool,
    ) -> Result<PreparedBackupImport> {
        if backup.accounts.len() > MAX_BACKUP_ACCOUNTS {
            return Err(anyhow!("backup contains too many accounts"));
        }
        let current = self.index_store.load_index()?;
        let mut index = if replace_environment {
            MetadataIndex {
                schema_version: METADATA_SCHEMA_VERSION,
                write_generation: current.write_generation,
                accounts: current
                    .accounts
                    .iter()
                    .filter(|account| &account.environment != environment)
                    .cloned()
                    .collect(),
            }
        } else {
            current.clone()
        };
        let now = OffsetDateTime::now_utc();
        let mut seen_identities = HashSet::new();
        let mut snapshots = Vec::with_capacity(backup.accounts.len());
        let mut created = 0;
        let mut updated = 0;

        for account in backup.accounts {
            crate::codex::validate_snapshot(&account.snapshot)
                .context("backup contains an invalid account snapshot")?;
            let snapshot_identity = crate::codex::identity_from_snapshot(&account.snapshot)
                .context("backup snapshot identity is invalid")?;
            if !backup_identity_matches_snapshot(&account.identity, &snapshot_identity) {
                return Err(anyhow!(
                    "backup metadata identity does not match its authentication snapshot"
                ));
            }
            let identity_key = snapshot_identity
                .subject
                .as_deref()
                .map(|subject| format!("subject:{subject}"))
                .unwrap_or_else(|| {
                    format!("email:{}", snapshot_identity.email.to_ascii_lowercase())
                });
            if !seen_identities.insert(identity_key) {
                return Err(anyhow!("backup contains duplicate account identities"));
            }
            let encoded_snapshot = encode_snapshot(&account.snapshot)?;
            let position = index.accounts.iter().position(|saved| {
                &saved.environment == environment
                    && DisplayIdentity {
                        email: saved.email.clone(),
                        subject: saved.subject.clone(),
                        name: saved.name.clone(),
                        plan_label: saved.plan_label.clone(),
                    }
                    .matches(&snapshot_identity)
            });
            let metadata = if let Some(position) = position {
                let saved = &mut index.accounts[position];
                saved.email = snapshot_identity.email.clone();
                saved.subject = snapshot_identity.subject.clone();
                saved.name = snapshot_identity.name.clone();
                saved.plan_label = snapshot_identity.plan_label.clone();
                saved.custom_label = account
                    .custom_label
                    .filter(|label| !label.trim().is_empty());
                saved.archived = account.archived;
                saved.cached_usage = None;
                saved.cached_usage_error = None;
                saved.updated_at = now;
                updated += 1;
                saved.clone()
            } else {
                let id = Uuid::new_v4();
                let metadata = SavedAccountMetadata {
                    id,
                    environment: environment.clone(),
                    provider: AiProvider::OpenAi,
                    email: snapshot_identity.email.clone(),
                    subject: snapshot_identity.subject.clone(),
                    name: snapshot_identity.name.clone(),
                    custom_label: account
                        .custom_label
                        .filter(|label| !label.trim().is_empty()),
                    plan_label: snapshot_identity.plan_label.clone(),
                    secret_key: format!("snapshot:{id}"),
                    created_at: now,
                    updated_at: now,
                    last_activated_at: None,
                    archived: account.archived,
                    cached_usage: None,
                    cached_usage_error: None,
                };
                index.accounts.push(metadata.clone());
                created += 1;
                metadata
            };
            snapshots.push(PreparedSnapshot {
                previous_value: self.secret_store.load(&metadata.secret_key)?,
                secret_key: metadata.secret_key,
                encoded_snapshot,
            });
        }
        Ok(PreparedBackupImport {
            index,
            snapshots,
            created,
            updated,
        })
    }

    fn apply_backup_import(&self, prepared: &PreparedBackupImport) -> Result<()> {
        let mut written = Vec::with_capacity(prepared.snapshots.len());
        for snapshot in &prepared.snapshots {
            if let Err(error) = self
                .secret_store
                .save(&snapshot.secret_key, &snapshot.encoded_snapshot)
            {
                self.restore_prepared_snapshots(&written);
                return Err(error).context("failed to persist imported snapshot data");
            }
            written.push(snapshot);
        }
        if let Err(error) = self.index_store.save_index(&prepared.index) {
            self.restore_prepared_snapshots(&written);
            return Err(error).context("failed to persist imported roster metadata");
        }
        Ok(())
    }

    fn restore_prepared_snapshots(&self, snapshots: &[&PreparedSnapshot]) {
        for snapshot in snapshots.iter().rev() {
            match snapshot.previous_value.as_deref() {
                Some(value) => {
                    let _ = self.secret_store.save(&snapshot.secret_key, value);
                }
                None => {
                    let _ = self.secret_store.delete(&snapshot.secret_key);
                }
            }
        }
    }

    pub fn create_automatic_full_backup(&self, environment: &EnvironmentKind) -> Result<usize> {
        let count = self.list_accounts(environment)?.len();
        self.write_automatic_full_backup(environment)?;
        Ok(count)
    }

    fn automatic_backup_dir(&self) -> PathBuf {
        self.data_dir.join("automatic-full-backups")
    }

    /// Full backups decrypt every saved snapshot with scrypt. Never do that on the
    /// activate/switch hot path more than once per cooldown window.
    const AUTOMATIC_FULL_BACKUP_COOLDOWN: Duration = Duration::from_secs(30 * 60);

    fn maybe_write_automatic_full_backup(&self, environment: &EnvironmentKind) {
        if !self.should_write_automatic_full_backup() {
            return;
        }
        let _ = self.write_automatic_full_backup(environment);
    }

    fn should_write_automatic_full_backup(&self) -> bool {
        let directory = self.automatic_backup_dir();
        let Ok(entries) = std::fs::read_dir(&directory) else {
            return true;
        };
        let newest = entries
            .filter_map(|entry| entry.ok())
            .filter_map(|entry| entry.metadata().ok()?.modified().ok())
            .max();
        match newest {
            Some(modified) => SystemTime::now()
                .duration_since(modified)
                .map(|age| age >= Self::AUTOMATIC_FULL_BACKUP_COOLDOWN)
                .unwrap_or(true),
            None => true,
        }
    }

    fn write_automatic_full_backup(&self, environment: &EnvironmentKind) -> Result<()> {
        let password = automatic_backup_password()?;
        let backup = self.export_backup(environment)?;
        let directory = self.automatic_backup_dir();
        std::fs::create_dir_all(&directory)
            .with_context(|| format!("failed to create {}", directory.display()))?;
        let path = directory.join(format!(
            "backup-{}-{}.codexroster",
            OffsetDateTime::now_utc().unix_timestamp(),
            Uuid::new_v4().simple()
        ));
        write_encrypted(&path, &backup, &password)?;
        let mut backups = std::fs::read_dir(&directory)
            .with_context(|| format!("failed to read {}", directory.display()))?
            .filter_map(|entry| entry.ok())
            .map(|entry| entry.path())
            .collect::<Vec<_>>();
        backups.sort_by_key(|path| {
            std::fs::metadata(path)
                .and_then(|metadata| metadata.modified())
                .unwrap_or(SystemTime::UNIX_EPOCH)
        });
        for path in backups.into_iter().rev().skip(5) {
            let _ = std::fs::remove_file(path);
        }
        Ok(())
    }

    pub fn delete_snapshot(&self, environment: &EnvironmentKind, account_id: Uuid) -> Result<()> {
        let mut index = self.index_store.load_index()?;
        let Some(position) = index
            .accounts
            .iter()
            .position(|account| account.id == account_id && &account.environment == environment)
        else {
            return Err(anyhow!("saved account {account_id} not found"));
        };
        let metadata = index.accounts.remove(position);
        let deleted_secret = self.secret_store.load(&metadata.secret_key).ok().flatten();
        if let Err(error) = self.secret_store.delete(&metadata.secret_key) {
            return Err(error).context("failed to delete saved snapshot data");
        }
        if let Err(error) = self.index_store.save_index(&index) {
            if let Some(serialized_snapshot) = deleted_secret.as_deref()
                && let Err(restore_error) = self
                    .secret_store
                    .save(&metadata.secret_key, serialized_snapshot)
            {
                return Err(anyhow!(
                    "failed to persist deleted metadata and failed to restore saved snapshot data: {error:#}; restore error: {restore_error:#}"
                ));
            }
            return Err(error);
        }
        self.maybe_write_automatic_full_backup(environment);
        Ok(())
    }

    pub fn sync_activated_account(
        &self,
        environment: &EnvironmentKind,
        account_id: Uuid,
        identity: &DisplayIdentity,
    ) -> Result<SavedAccountMetadata> {
        let mut index = self.index_store.load_index()?;
        let now = OffsetDateTime::now_utc();
        let Some(account_position) = index
            .accounts
            .iter()
            .position(|account| account.id == account_id && &account.environment == environment)
        else {
            return Err(anyhow!("saved account {account_id} not found"));
        };
        // Only collapse true same-subject duplicates. Email-only matches used to
        // delete unrelated subjectless rows during activate and silently shrink the roster.
        let duplicate_positions = index
            .accounts
            .iter()
            .enumerate()
            .filter(|(position, account)| {
                *position != account_position
                    && &account.environment == environment
                    && subjects_equal(account.subject.as_deref(), identity.subject.as_deref())
            })
            .map(|(position, _)| position)
            .collect::<Vec<_>>();
        let duplicates = duplicate_positions
            .into_iter()
            .rev()
            .map(|position| index.accounts.remove(position))
            .collect::<Vec<_>>();
        let adjusted_position = index
            .accounts
            .iter()
            .position(|account| account.id == account_id && &account.environment == environment)
            .ok_or_else(|| anyhow!("saved account {account_id} not found"))?;
        let account = &mut index.accounts[adjusted_position];
        account.email = identity.email.clone();
        account.subject = identity.subject.clone();
        account.name = identity.name.clone();
        account.plan_label = identity.plan_label.clone();
        account.last_activated_at = Some(now);
        account.updated_at = now;
        let updated = account.clone();
        self.index_store.save_index(&index)?;
        for duplicate in duplicates {
            let _ = self.secret_store.delete(&duplicate.secret_key);
        }
        Ok(updated)
    }
}

fn subjects_equal(left: Option<&str>, right: Option<&str>) -> bool {
    matches!((left, right), (Some(left), Some(right)) if left == right)
}

fn backup_identity_matches_snapshot(
    metadata: &DisplayIdentity,
    snapshot: &DisplayIdentity,
) -> bool {
    metadata.email.eq_ignore_ascii_case(&snapshot.email)
        && metadata
            .subject
            .as_ref()
            .is_none_or(|subject| snapshot.subject.as_ref() == Some(subject))
}

#[cfg(test)]
impl<S> SnapshotRepository<S>
where
    S: SecretStore,
{
    fn best_available_index(&self) -> Result<Option<crate::model::MetadataIndex>> {
        self.index_store.best_available_index()
    }
}

#[cfg(test)]
mod tests {
    use std::fs;

    use anyhow::{Result, anyhow};
    use base64::Engine;
    use tempfile::tempdir;
    use time::Duration;

    use super::*;
    use crate::codex::auth_json_fixture;
    use crate::model::{METADATA_SCHEMA_VERSION, MetadataIndex};
    use crate::repository::codec::SNAPSHOT_ENCODING_V1_MAGIC;
    use crate::secrets::{SecretStore, test_support::MemorySecretStore};

    fn identity(email: &str, subject: &str) -> DisplayIdentity {
        DisplayIdentity {
            email: email.to_owned(),
            subject: Some(subject.to_owned()),
            name: Some("Tester".to_owned()),
            plan_label: Some("Pro".to_owned()),
        }
    }

    fn valid_snapshot(email: &str, subject: &str) -> SnapshotBlob {
        SnapshotBlob {
            schema_version: 1,
            files: vec![
                crate::model::SnapshotFile {
                    name: "auth.json".to_owned(),
                    bytes_base64: base64::engine::general_purpose::STANDARD
                        .encode(auth_json_fixture(email, subject, Some("pro"))),
                },
                crate::model::SnapshotFile {
                    name: "cap_sid".to_owned(),
                    bytes_base64: base64::engine::general_purpose::STANDARD.encode("sid"),
                },
            ],
        }
    }

    fn rewrite_index(path: &Path, email: &str, updated_at: OffsetDateTime, write_generation: u64) {
        let raw = fs::read_to_string(path).expect("read index");
        let mut index: MetadataIndex = serde_json::from_str(&raw).expect("parse index");
        let account = index.accounts.first_mut().expect("account");
        account.email = email.to_owned();
        account.updated_at = updated_at;
        index.write_generation = write_generation;
        fs::write(
            path,
            serde_json::to_string_pretty(&index).expect("serialize index"),
        )
        .expect("write index");
    }

    #[test]
    fn refreshes_existing_account_by_subject() {
        let temp = tempdir().expect("tempdir");
        let repo = SnapshotRepository::new(temp.path(), MemorySecretStore::default());
        let env = EnvironmentKind::Windows;
        let snapshot = SnapshotBlob {
            schema_version: 1,
            files: vec![],
        };
        let (first, created) = repo
            .save_snapshot(&env, &identity("person@example.com", "sub-1"), &snapshot)
            .expect("save");
        assert!(created);
        let (second, created) = repo
            .save_snapshot(&env, &identity("person2@example.com", "sub-1"), &snapshot)
            .expect("save");
        assert!(!created);
        assert_eq!(first.id, second.id);
        assert_eq!(second.email, "person2@example.com");
    }

    #[test]
    fn import_rejects_backup_snapshot_with_unmanaged_file() {
        let temp = tempdir().expect("tempdir");
        let repo = SnapshotRepository::new(temp.path(), MemorySecretStore::default());
        let backup = BackupBundle::new(vec![BackupAccount {
            identity: identity("person@example.com", "sub-1"),
            custom_label: None,
            archived: false,
            snapshot: SnapshotBlob {
                schema_version: 1,
                files: vec![
                    crate::model::SnapshotFile {
                        name: "auth.json".to_owned(),
                        bytes_base64: "e30=".to_owned(),
                    },
                    crate::model::SnapshotFile {
                        name: "cap_sid".to_owned(),
                        bytes_base64: "c2lk".to_owned(),
                    },
                    crate::model::SnapshotFile {
                        name: "/tmp/unmanaged".to_owned(),
                        bytes_base64: "bWFsaWNpb3Vz".to_owned(),
                    },
                ],
            },
        }]);

        let error = repo
            .import_backup(&EnvironmentKind::Macos, backup)
            .expect_err("unmanaged backup file must be rejected");

        assert!(format!("{error:#}").contains("invalid account snapshot"));
        assert!(
            repo.list_accounts(&EnvironmentKind::Macos)
                .expect("list")
                .is_empty()
        );
    }

    #[test]
    fn import_validates_every_account_before_mutating_the_roster() {
        let temp = tempdir().expect("tempdir");
        let repo = SnapshotRepository::new(temp.path(), MemorySecretStore::default());
        let environment = EnvironmentKind::Macos;
        repo.save_snapshot(
            &environment,
            &identity("existing@example.com", "existing"),
            &valid_snapshot("existing@example.com", "existing"),
        )
        .expect("seed roster");
        let backup = BackupBundle::new(vec![
            BackupAccount {
                identity: identity("valid@example.com", "valid"),
                custom_label: None,
                archived: false,
                snapshot: valid_snapshot("valid@example.com", "valid"),
            },
            BackupAccount {
                identity: identity("invalid@example.com", "invalid"),
                custom_label: None,
                archived: false,
                snapshot: SnapshotBlob {
                    schema_version: 1,
                    files: vec![],
                },
            },
        ]);

        repo.import_backup(&environment, backup)
            .expect_err("invalid later account must reject the whole import");

        let accounts = repo.list_accounts(&environment).expect("list roster");
        assert_eq!(accounts.len(), 1);
        assert_eq!(accounts[0].email, "existing@example.com");
    }

    #[test]
    fn import_rejects_metadata_that_does_not_match_the_snapshot_identity() {
        let temp = tempdir().expect("tempdir");
        let repo = SnapshotRepository::new(temp.path(), MemorySecretStore::default());
        let backup = BackupBundle::new(vec![BackupAccount {
            identity: identity("metadata@example.com", "metadata"),
            custom_label: None,
            archived: false,
            snapshot: valid_snapshot("snapshot@example.com", "snapshot"),
        }]);

        let error = repo
            .import_backup(&EnvironmentKind::Macos, backup)
            .expect_err("mismatched backup metadata must be rejected");

        assert!(format!("{error:#}").contains("metadata identity"));
        assert!(
            repo.list_accounts(&EnvironmentKind::Macos)
                .expect("list roster")
                .is_empty()
        );
    }

    #[derive(Clone, Default)]
    struct FailingDeleteSecretStore {
        inner: MemorySecretStore,
    }

    impl SecretStore for FailingDeleteSecretStore {
        fn save(&self, key: &str, value: &[u8]) -> Result<()> {
            self.inner.save(key, value)
        }

        fn load(&self, key: &str) -> Result<Option<Vec<u8>>> {
            self.inner.load(key)
        }

        fn delete(&self, _key: &str) -> Result<()> {
            Err(anyhow!("delete failed"))
        }
    }

    #[test]
    fn delete_rolls_back_metadata_when_secret_delete_fails() {
        let temp = tempdir().expect("tempdir");
        let repo = SnapshotRepository::new(temp.path(), FailingDeleteSecretStore::default());
        let env = EnvironmentKind::Windows;
        let snapshot = SnapshotBlob {
            schema_version: 1,
            files: vec![],
        };
        let (saved, _) = repo
            .save_snapshot(&env, &identity("person@example.com", "sub-1"), &snapshot)
            .expect("save");

        let error = repo
            .delete_snapshot(&env, saved.id)
            .expect_err("delete should fail");
        let rendered = format!("{error:#}");
        assert!(rendered.contains("failed to delete saved snapshot data"));
        assert!(rendered.contains("delete failed"));
        let restored = repo.get_account(&env, saved.id).expect("get account");
        assert!(restored.is_some());
    }

    #[test]
    fn recovers_metadata_from_backup_when_primary_is_missing() {
        let temp = tempdir().expect("tempdir");
        let repo = SnapshotRepository::new(temp.path(), MemorySecretStore::default());
        let env = EnvironmentKind::Windows;
        let snapshot = SnapshotBlob {
            schema_version: 1,
            files: vec![],
        };
        let (saved, _) = repo
            .save_snapshot(&env, &identity("person@example.com", "sub-1"), &snapshot)
            .expect("save");

        let metadata_path = temp.path().join("metadata.json");
        let backup_path = temp.path().join("metadata.json.bak-test");
        fs::rename(&metadata_path, &backup_path).expect("move backup");

        let recovered = repo.get_account(&env, saved.id).expect("recover account");
        assert!(recovered.is_some());
        assert!(!metadata_path.exists());
        assert!(backup_path.exists());
    }

    #[test]
    fn recovers_newer_temp_before_older_backup() {
        let temp = tempdir().expect("tempdir");
        let repo = SnapshotRepository::new(temp.path(), MemorySecretStore::default());
        let env = EnvironmentKind::Windows;
        let snapshot = SnapshotBlob {
            schema_version: 1,
            files: vec![],
        };
        let (saved, _) = repo
            .save_snapshot(&env, &identity("first@example.com", "sub-1"), &snapshot)
            .expect("save");

        let metadata_path = temp.path().join("metadata.json");
        let now = OffsetDateTime::now_utc();
        rewrite_index(&metadata_path, "first@example.com", now, 1);
        let backup_path = temp.path().join("metadata.json.bak-test");
        fs::rename(&metadata_path, &backup_path).expect("move backup");

        let temp_path = temp.path().join("metadata.json.tmp-test");
        fs::copy(&backup_path, &temp_path).expect("copy temp");
        rewrite_index(&temp_path, "second@example.com", now + Duration::days(1), 2);

        let recovered = repo.get_account(&env, saved.id).expect("recover account");
        assert_eq!(recovered.expect("account").email, "second@example.com");
        assert!(!metadata_path.exists());
        assert!(temp_path.exists());
    }

    #[test]
    fn falls_back_to_backup_when_temp_is_invalid() {
        let temp = tempdir().expect("tempdir");
        let repo = SnapshotRepository::new(temp.path(), MemorySecretStore::default());
        let env = EnvironmentKind::Windows;
        let snapshot = SnapshotBlob {
            schema_version: 1,
            files: vec![],
        };
        let (saved, _) = repo
            .save_snapshot(&env, &identity("first@example.com", "sub-1"), &snapshot)
            .expect("save");

        let metadata_path = temp.path().join("metadata.json");
        let backup_path = temp.path().join("metadata.json.bak-test");
        fs::rename(&metadata_path, &backup_path).expect("move backup");
        fs::write(temp.path().join("metadata.json.tmp-test"), "{not-json").expect("write temp");

        let recovered = repo.get_account(&env, saved.id).expect("recover account");
        assert_eq!(recovered.expect("account").email, "first@example.com");
    }

    #[test]
    fn ignores_recovery_candidates_with_unsupported_schema() {
        let temp = tempdir().expect("tempdir");
        let repo = SnapshotRepository::new(temp.path(), MemorySecretStore::default());
        let env = EnvironmentKind::Windows;
        let snapshot = SnapshotBlob {
            schema_version: 1,
            files: vec![],
        };
        let (saved, _) = repo
            .save_snapshot(&env, &identity("first@example.com", "sub-1"), &snapshot)
            .expect("save");

        let metadata_path = temp.path().join("metadata.json");
        let backup_path = temp.path().join("metadata.json.bak-test");
        fs::rename(&metadata_path, &backup_path).expect("move backup");
        let raw = fs::read_to_string(&backup_path).expect("read backup");
        let mut index: MetadataIndex = serde_json::from_str(&raw).expect("parse backup");
        index.schema_version = METADATA_SCHEMA_VERSION + 1;
        fs::write(
            temp.path().join("metadata.json.tmp-test"),
            serde_json::to_string_pretty(&index).expect("serialize temp"),
        )
        .expect("write temp");

        let recovered = repo.get_account(&env, saved.id).expect("recover account");
        assert_eq!(recovered.expect("account").email, "first@example.com");
    }

    #[test]
    fn errors_when_only_invalid_recovery_candidates_exist() {
        let temp = tempdir().expect("tempdir");
        let repo = SnapshotRepository::new(temp.path(), MemorySecretStore::default());

        fs::write(temp.path().join("metadata.json.tmp-test"), "{not-json").expect("write temp");

        let error = repo
            .best_available_index()
            .expect_err("invalid recovery state should fail");
        assert!(format!("{error:#}").contains("failed to parse metadata recovery state"));
    }

    #[test]
    fn ignores_invalid_pending_metadata_when_no_other_index_exists() {
        let temp = tempdir().expect("tempdir");
        let repo = SnapshotRepository::new(temp.path(), MemorySecretStore::default());

        fs::write(temp.path().join("metadata.json.pending"), "{not-json").expect("write pending");

        let index = repo.best_available_index().expect("pending-only recovery");
        assert!(index.is_none());
    }

    #[test]
    fn errors_when_canonical_metadata_is_unreadable() {
        let temp = tempdir().expect("tempdir");
        let repo = SnapshotRepository::new(temp.path(), MemorySecretStore::default());
        let env = EnvironmentKind::Windows;

        fs::write(temp.path().join("metadata.json"), "{not-json").expect("write metadata");

        let error = repo.list_accounts(&env).expect_err("list should fail");
        assert!(format!("{error:#}").contains("failed to parse"));
    }

    #[test]
    fn recovers_newest_valid_candidate_across_temp_and_backup() {
        let temp = tempdir().expect("tempdir");
        let repo = SnapshotRepository::new(temp.path(), MemorySecretStore::default());
        let env = EnvironmentKind::Windows;
        let snapshot = SnapshotBlob {
            schema_version: 1,
            files: vec![],
        };
        let (saved, _) = repo
            .save_snapshot(&env, &identity("first@example.com", "sub-1"), &snapshot)
            .expect("save");

        let metadata_path = temp.path().join("metadata.json");
        let now = OffsetDateTime::now_utc();
        let temp_path = temp.path().join("metadata.json.tmp-old");
        fs::copy(&metadata_path, &temp_path).expect("copy temp");
        rewrite_index(&temp_path, "second@example.com", now, 1);
        let backup_path = temp.path().join("metadata.json.bak-new");
        rewrite_index(
            &metadata_path,
            "first@example.com",
            now + Duration::days(1),
            2,
        );
        fs::rename(&metadata_path, &backup_path).expect("move backup");

        let recovered = repo.get_account(&env, saved.id).expect("recover account");
        assert_eq!(recovered.expect("account").email, "first@example.com");
    }

    #[test]
    fn prefers_canonical_when_metadata_file_is_valid() {
        let temp = tempdir().expect("tempdir");
        let repo = SnapshotRepository::new(temp.path(), MemorySecretStore::default());
        let env = EnvironmentKind::Windows;
        let snapshot = SnapshotBlob {
            schema_version: 1,
            files: vec![],
        };
        let (saved, _) = repo
            .save_snapshot(&env, &identity("first@example.com", "sub-1"), &snapshot)
            .expect("save");

        let metadata_path = temp.path().join("metadata.json");
        let now = OffsetDateTime::now_utc();
        rewrite_index(&metadata_path, "first@example.com", now, 1);
        let temp_path = temp.path().join("metadata.json.tmp-new");
        fs::copy(&metadata_path, &temp_path).expect("copy temp");
        rewrite_index(&temp_path, "second@example.com", now + Duration::days(1), 2);

        let recovered = repo.get_account(&env, saved.id).expect("recover account");
        assert_eq!(recovered.expect("account").email, "first@example.com");
    }

    #[test]
    fn prefers_pending_temp_when_it_is_newer_than_canonical() {
        let temp = tempdir().expect("tempdir");
        let repo = SnapshotRepository::new(temp.path(), MemorySecretStore::default());
        let env = EnvironmentKind::Windows;
        let snapshot = SnapshotBlob {
            schema_version: 1,
            files: vec![],
        };
        let (saved, _) = repo
            .save_snapshot(&env, &identity("first@example.com", "sub-1"), &snapshot)
            .expect("save");

        let metadata_path = temp.path().join("metadata.json");
        let now = OffsetDateTime::now_utc();
        rewrite_index(&metadata_path, "first@example.com", now, 1);
        let temp_path = temp.path().join("metadata.json.tmp-new");
        fs::copy(&metadata_path, &temp_path).expect("copy temp");
        rewrite_index(&temp_path, "second@example.com", now + Duration::days(1), 2);
        fs::copy(&temp_path, temp.path().join("metadata.json.pending")).expect("write pending");

        let recovered = repo.get_account(&env, saved.id).expect("recover account");
        assert_eq!(recovered.expect("account").email, "second@example.com");
    }

    #[test]
    fn successful_save_cleans_up_its_recovery_artifacts() {
        let temp = tempdir().expect("tempdir");
        let repo = SnapshotRepository::new(temp.path(), MemorySecretStore::default());
        let env = EnvironmentKind::Windows;
        let snapshot = SnapshotBlob {
            schema_version: 1,
            files: vec![],
        };

        repo.save_snapshot(&env, &identity("person@example.com", "sub-1"), &snapshot)
            .expect("save");

        let entries = fs::read_dir(temp.path())
            .expect("read dir")
            .filter_map(|entry| entry.ok())
            .map(|entry| entry.file_name().to_string_lossy().into_owned())
            .collect::<Vec<_>>();
        assert!(
            !entries
                .iter()
                .any(|name| name.starts_with("metadata.json.tmp-"))
        );
        assert!(
            !entries
                .iter()
                .any(|name| name.starts_with("metadata.json.bak-"))
        );
    }

    #[test]
    fn falls_back_to_valid_recovery_when_canonical_is_corrupt() {
        let temp = tempdir().expect("tempdir");
        let repo = SnapshotRepository::new(temp.path(), MemorySecretStore::default());
        let env = EnvironmentKind::Windows;
        let snapshot = SnapshotBlob {
            schema_version: 1,
            files: vec![],
        };
        let (saved, _) = repo
            .save_snapshot(&env, &identity("person@example.com", "sub-1"), &snapshot)
            .expect("save");

        let metadata_path = temp.path().join("metadata.json");
        let backup_path = temp.path().join("metadata.json.bak-test");
        fs::copy(&metadata_path, &backup_path).expect("copy backup");
        fs::write(&metadata_path, "{not-json").expect("corrupt canonical");

        let recovered = repo.get_account(&env, saved.id).expect("recover account");
        assert!(recovered.is_some());
    }

    #[test]
    fn activation_sync_keeps_rows_with_different_subjects() {
        let temp = tempdir().expect("tempdir");
        let repo = SnapshotRepository::new(temp.path(), MemorySecretStore::default());
        let env = EnvironmentKind::Windows;
        let snapshot = SnapshotBlob {
            schema_version: 1,
            files: vec![],
        };

        let other = repo
            .save_snapshot(&env, &identity("other@example.com", "sub-other"), &snapshot)
            .expect("save other")
            .0;
        let current = repo
            .save_snapshot(&env, &identity("current@example.com", "sub-1"), &snapshot)
            .expect("save current")
            .0;

        repo.sync_activated_account(&env, current.id, &identity("current@example.com", "sub-1"))
            .expect("sync");

        let accounts = repo.list_accounts(&env).expect("list");
        assert_eq!(accounts.len(), 2);
        assert!(accounts.iter().any(|account| account.id == other.id));
        assert!(accounts.iter().any(|account| account.id == current.id));
    }

    #[test]
    fn activation_sync_removes_duplicate_identity_rows() {
        let temp = tempdir().expect("tempdir");
        let repo = SnapshotRepository::new(temp.path(), MemorySecretStore::default());
        let env = EnvironmentKind::Windows;
        let snapshot = SnapshotBlob {
            schema_version: 1,
            files: vec![],
        };

        let first = repo
            .save_snapshot(
                &env,
                &DisplayIdentity {
                    email: "legacy@example.com".to_owned(),
                    subject: None,
                    name: Some("Tester".to_owned()),
                    plan_label: Some("Pro".to_owned()),
                },
                &snapshot,
            )
            .expect("save first")
            .0;
        let duplicate = repo
            .save_snapshot(&env, &identity("current@example.com", "sub-1"), &snapshot)
            .expect("save duplicate")
            .0;

        let updated = repo
            .sync_activated_account(&env, first.id, &identity("current@example.com", "sub-1"))
            .expect("sync");
        assert_eq!(updated.email, "current@example.com");

        let accounts = repo.list_accounts(&env).expect("list");
        assert_eq!(accounts.len(), 1);
        assert_eq!(accounts[0].id, first.id);
        assert!(
            repo.secret_store
                .load(&duplicate.secret_key)
                .expect("load duplicate secret")
                .is_none()
        );
    }

    #[test]
    fn activation_sync_succeeds_when_duplicate_secret_cleanup_fails() {
        let temp = tempdir().expect("tempdir");
        let repo = SnapshotRepository::new(temp.path(), FailingDeleteSecretStore::default());
        let env = EnvironmentKind::Windows;
        let snapshot = SnapshotBlob {
            schema_version: 1,
            files: vec![],
        };

        let first = repo
            .save_snapshot(
                &env,
                &DisplayIdentity {
                    email: "legacy@example.com".to_owned(),
                    subject: None,
                    name: Some("Tester".to_owned()),
                    plan_label: Some("Pro".to_owned()),
                },
                &snapshot,
            )
            .expect("save first")
            .0;
        let duplicate = repo
            .save_snapshot(&env, &identity("current@example.com", "sub-1"), &snapshot)
            .expect("save duplicate")
            .0;

        let updated = repo
            .sync_activated_account(&env, first.id, &identity("current@example.com", "sub-1"))
            .expect("sync");
        assert_eq!(updated.email, "current@example.com");

        let accounts = repo.list_accounts(&env).expect("list");
        assert_eq!(accounts.len(), 1);
        assert_eq!(accounts[0].id, first.id);
        assert!(
            repo.secret_store
                .load(&duplicate.secret_key)
                .expect("load duplicate secret")
                .is_some()
        );
    }

    #[test]
    fn save_snapshot_stores_compressed_payload_and_loads_it_back() {
        let temp = tempdir().expect("tempdir");
        let repo = SnapshotRepository::new(temp.path(), MemorySecretStore::default());
        let env = EnvironmentKind::Windows;
        let snapshot = SnapshotBlob {
            schema_version: 1,
            files: vec![
                crate::model::SnapshotFile {
                    name: "auth.json".to_owned(),
                    bytes_base64: "auth-payload".to_owned(),
                },
                crate::model::SnapshotFile {
                    name: "cap_sid".to_owned(),
                    bytes_base64: "cap-payload".to_owned(),
                },
            ],
        };

        let (saved, _) = repo
            .save_snapshot(&env, &identity("person@example.com", "sub-1"), &snapshot)
            .expect("save");
        let raw = repo
            .secret_store
            .load(&saved.secret_key)
            .expect("load stored payload")
            .expect("stored payload");
        assert!(raw.starts_with(SNAPSHOT_ENCODING_V1_MAGIC));

        let loaded = repo.load_snapshot(&env, saved.id).expect("load snapshot").1;
        assert_eq!(loaded.schema_version, snapshot.schema_version);
        assert_eq!(loaded.files.len(), snapshot.files.len());
        assert_eq!(loaded.files[0].bytes_base64, "auth-payload");
        assert_eq!(loaded.files[1].bytes_base64, "cap-payload");
    }

    #[test]
    fn usage_error_is_persisted_and_cleared_by_snapshot_refresh() {
        let temp = tempdir().expect("tempdir");
        let repo = SnapshotRepository::new(temp.path(), MemorySecretStore::default());
        let env = EnvironmentKind::Windows;
        let snapshot = SnapshotBlob {
            schema_version: 1,
            files: vec![],
        };
        let saved = repo
            .save_snapshot(&env, &identity("person@example.com", "sub-1"), &snapshot)
            .expect("save")
            .0;

        repo.record_usage_error(&env, saved.id, "Login required".to_owned())
            .expect("record error");
        assert_eq!(
            repo.get_account(&env, saved.id)
                .expect("get")
                .expect("account")
                .cached_usage_error
                .as_deref(),
            Some("Login required")
        );

        repo.replace_snapshot(
            &env,
            saved.id,
            &identity("person@example.com", "sub-1"),
            &snapshot,
            None,
        )
        .expect("replace");

        assert!(
            repo.get_account(&env, saved.id)
                .expect("get")
                .expect("account")
                .cached_usage_error
                .is_none()
        );
    }

    #[test]
    fn transient_usage_error_does_not_replace_login_required_marker() {
        let temp = tempdir().expect("tempdir");
        let repo = SnapshotRepository::new(temp.path(), MemorySecretStore::default());
        let env = EnvironmentKind::Windows;
        let snapshot = SnapshotBlob {
            schema_version: 1,
            files: vec![],
        };
        let saved = repo
            .save_snapshot(&env, &identity("person@example.com", "sub-1"), &snapshot)
            .expect("save")
            .0;

        repo.record_usage_error(&env, saved.id, "Login required".to_owned())
            .expect("record login error");
        repo.record_usage_error(
            &env,
            saved.id,
            "Usage unavailable: failed to query Codex usage".to_owned(),
        )
        .expect("record transient error");

        assert_eq!(
            repo.get_account(&env, saved.id)
                .expect("get")
                .expect("account")
                .cached_usage_error
                .as_deref(),
            Some("Login required")
        );
    }

    #[test]
    fn load_snapshot_accepts_legacy_plain_json_payloads() {
        let temp = tempdir().expect("tempdir");
        let repo = SnapshotRepository::new(temp.path(), MemorySecretStore::default());
        let env = EnvironmentKind::Windows;
        let snapshot = SnapshotBlob {
            schema_version: 1,
            files: vec![
                crate::model::SnapshotFile {
                    name: "auth.json".to_owned(),
                    bytes_base64: "legacy-auth".to_owned(),
                },
                crate::model::SnapshotFile {
                    name: "cap_sid".to_owned(),
                    bytes_base64: "legacy-cap".to_owned(),
                },
            ],
        };
        let (saved, _) = repo
            .save_snapshot(&env, &identity("person@example.com", "sub-1"), &snapshot)
            .expect("save");
        let legacy = serde_json::to_vec(&snapshot).expect("serialize legacy");
        repo.secret_store
            .save(&saved.secret_key, &legacy)
            .expect("overwrite with legacy payload");

        let loaded = repo.load_snapshot(&env, saved.id).expect("load snapshot").1;
        assert_eq!(loaded.schema_version, snapshot.schema_version);
        assert_eq!(loaded.files[0].bytes_base64, "legacy-auth");
        assert_eq!(loaded.files[1].bytes_base64, "legacy-cap");
    }
}
