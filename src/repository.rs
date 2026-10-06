use std::collections::HashSet;
use std::fs;
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
    explicit_restore: bool,
    snapshots: Vec<PreparedSnapshot>,
    created: usize,
    updated: usize,
}

struct PreparedSnapshot {
    secret_key: String,
    encoded_snapshot: Vec<u8>,
    previous_value: Option<Vec<u8>>,
}

/// Provider APIs persist immediately, so prepare their entire local store in a
/// sibling directory and retain the old store until the Codex commit succeeds.
struct PreparedProviderImport {
    staging_dir: PathBuf,
    destination: PathBuf,
    committed: bool,
    created: usize,
    updated: usize,
}

impl PreparedProviderImport {
    fn new(data_dir: &Path) -> Result<Self> {
        fs::create_dir_all(data_dir)?;
        let staging_dir = data_dir.join(format!(".backup-import-{}", Uuid::new_v4().simple()));
        fs::create_dir(&staging_dir)?;
        let prepared = Self {
            staging_dir,
            destination: data_dir.join("providers"),
            committed: false,
            created: 0,
            updated: 0,
        };
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&prepared.staging_dir, fs::Permissions::from_mode(0o700))?;
        }
        if prepared.destination.exists() {
            copy_provider_directory(
                &prepared.destination,
                &prepared.staging_dir.join("providers"),
            )?;
        }
        Ok(prepared)
    }

    fn commit(&mut self) -> Result<()> {
        let original = self.staging_dir.join("original-providers");
        if self.destination.exists() {
            fs::rename(&self.destination, &original).context("failed to retain provider store")?;
        }
        if let Err(error) = fs::rename(self.staging_dir.join("providers"), &self.destination) {
            if original.exists()
                && let Err(rollback) = fs::rename(&original, &self.destination)
            {
                self.committed = true; // Preserve the original for manual recovery.
                return Err(anyhow!(
                    "provider commit failed: {error}; rollback failed: {rollback}; original retained at {}",
                    original.display()
                ));
            }
            return Err(error).context("failed to persist prepared providers");
        }
        self.committed = true;
        Ok(())
    }

    fn rollback(&mut self) -> Result<()> {
        if self.destination.exists() {
            fs::rename(&self.destination, self.staging_dir.join("providers"))?;
        }
        let original = self.staging_dir.join("original-providers");
        if original.exists() {
            fs::rename(&original, &self.destination).with_context(|| {
                format!(
                    "failed to restore provider store retained at {}",
                    original.display()
                )
            })?;
        }
        self.committed = false;
        Ok(())
    }
}

impl Drop for PreparedProviderImport {
    fn drop(&mut self) {
        if !self.committed {
            let _ = fs::remove_dir_all(&self.staging_dir);
        }
    }
}

fn copy_provider_directory(source: &Path, destination: &Path) -> Result<()> {
    if !fs::symlink_metadata(source)?.is_dir() {
        return Err(anyhow!(
            "provider staging requires a regular directory: {}",
            source.display()
        ));
    }
    fs::create_dir(destination)?;
    fs::set_permissions(destination, fs::metadata(source)?.permissions())?;
    for entry in fs::read_dir(source)? {
        let entry = entry?;
        let target = destination.join(entry.file_name());
        let kind = entry.file_type()?;
        if kind.is_dir() {
            copy_provider_directory(&entry.path(), &target)?;
        } else if kind.is_file() {
            let modified = fs::metadata(entry.path())?.modified()?;
            fs::copy(entry.path(), &target)?;
            // Recovery ranks candidates by source age, not staging copy order.
            fs::File::open(&target)?
                .set_times(fs::FileTimes::new().set_modified(modified))
                .with_context(|| {
                    format!("failed to preserve modified time at {}", target.display())
                })?;
        } else {
            return Err(anyhow!(
                "cannot stage provider entry {}",
                entry.path().display()
            ));
        }
    }
    Ok(())
}

/// Explicit restore can rebuild damaged provider metadata. Work only on the
/// private staged copy, preserving recovery bytes before normal store cleanup.
fn recover_provider_index_for_restore(staging_dir: &Path) -> Result<()> {
    use crate::file_store::{RecoveryFileKind, list_recovery_files, replace_file_with_recovery};

    let path = staging_dir.join("providers/index.json");
    let mut candidates = list_recovery_files(&path, None)?;
    candidates.sort_by_key(|entry| {
        (
            entry.kind != RecoveryFileKind::Canonical,
            std::cmp::Reverse(entry.modified),
        )
    });
    let valid_index = |bytes: &[u8]| {
        let Ok(value) = serde_json::from_slice::<serde_json::Value>(bytes) else {
            return false;
        };
        value["schema_version"].as_u64() == Some(1)
            && serde_json::from_value::<Vec<crate::provider_store::ProviderSavedAccount>>(
                value
                    .get("accounts")
                    .cloned()
                    .unwrap_or_else(|| serde_json::json!([])),
            )
            .is_ok()
    };
    let mut recovered = None;
    for entry in &candidates {
        if let Ok(bytes) = fs::read(&entry.path)
            && valid_index(&bytes)
        {
            if entry.kind == RecoveryFileKind::Canonical {
                return Ok(());
            }
            recovered = Some(bytes);
            break;
        }
    }
    let directory = path.parent().expect("provider index parent");
    fs::create_dir_all(directory)?;
    for entry in candidates {
        let preserved = directory.join(format!("preserved-index-{}.json", Uuid::new_v4().simple()));
        fs::copy(&entry.path, &preserved)
            .map(|_| ())
            .or_else(|_| fs::hard_link(&entry.path, &preserved))
            .with_context(|| {
                format!(
                    "failed to preserve provider index at {}",
                    entry.path.display()
                )
            })?;
    }
    let bytes = recovered.unwrap_or_else(|| br#"{"schema_version":1,"accounts":[]}"#.to_vec());
    replace_file_with_recovery(&path, None, |temp| {
        fs::write(temp, &bytes)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(temp, fs::Permissions::from_mode(0o600))?;
        }
        Ok(())
    })
}

struct SnapshotImportUndo {
    directory: PathBuf,
    retain: bool,
}

impl SnapshotImportUndo {
    fn new(data_dir: &Path, snapshots: &[PreparedSnapshot]) -> Result<Self> {
        let directory = data_dir.join(format!(".snapshot-import-undo-{}", Uuid::new_v4().simple()));
        fs::create_dir_all(&directory)?;
        let undo = Self {
            directory,
            retain: false,
        };
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&undo.directory, fs::Permissions::from_mode(0o700))?;
        }
        let store = LocalSecretStore::new(&undo.directory.join("snapshots"));
        for snapshot in snapshots {
            if let Some(previous) = &snapshot.previous_value {
                store
                    .save(&snapshot.secret_key, previous)
                    .context("failed to retain previous snapshot before import")?;
            }
        }
        let manifest = snapshots
            .iter()
            .map(|snapshot| (&snapshot.secret_key, snapshot.previous_value.is_some()))
            .collect::<Vec<_>>();
        fs::write(
            undo.directory.join("manifest.json"),
            serde_json::to_vec_pretty(&manifest)?,
        )?;
        Ok(undo)
    }
}

impl Drop for SnapshotImportUndo {
    fn drop(&mut self) {
        if !self.retain {
            let _ = fs::remove_dir_all(&self.directory);
        }
    }
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
        // Secrets are written before the index so a crash can only leave an
        // unreferenced secret, never an index entry pointing at nothing. The
        // undo log (key, previous value) lets a failure roll those writes back
        // so they do not linger as orphans or silently replace a live snapshot.
        let mut undo: Vec<(String, Option<Vec<u8>>)> = Vec::new();

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
            let encoded_snapshot = match legacy_store.load(&legacy.secret_key) {
                Ok(snapshot) => snapshot,
                Err(error) => return Err(self.roll_back_recovered_secrets(&undo, error)),
            };
            let Some(encoded_snapshot) = encoded_snapshot else {
                skipped_accounts += 1;
                continue;
            };
            if decode_snapshot(&encoded_snapshot).is_err() {
                skipped_accounts += 1;
                continue;
            }

            let previous = match self.secret_store.load(&legacy.secret_key) {
                Ok(previous) => previous,
                Err(error) => {
                    return Err(self.roll_back_recovered_secrets(&undo, error));
                }
            };
            undo.push((legacy.secret_key.clone(), previous));
            if let Err(error) = self
                .secret_store
                .save(&legacy.secret_key, &encoded_snapshot)
            {
                return Err(self.roll_back_recovered_secrets(&undo, error));
            }
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

        if (recovered_accounts > 0 || imported_accounts > 0)
            && let Err(error) = self.index_store.save_index(&current_index)
        {
            return Err(self.roll_back_recovered_secrets(&undo, error));
        }
        Ok((recovered_accounts, imported_accounts, skipped_accounts))
    }

    /// Undo secret writes made by `recover_legacy_snapshots`, newest first, and
    /// return `cause` annotated with any rollback problem.
    fn roll_back_recovered_secrets(
        &self,
        undo: &[(String, Option<Vec<u8>>)],
        cause: anyhow::Error,
    ) -> anyhow::Error {
        let mut failures = Vec::new();
        for (key, previous) in undo.iter().rev() {
            let result = match previous {
                Some(value) => self.secret_store.save(key, value),
                None => self.secret_store.delete(key),
            };
            if let Err(error) = result {
                failures.push(format!("{key}: {error:#}"));
            }
        }
        if failures.is_empty() {
            cause.context("legacy snapshot recovery failed; imported snapshots were rolled back")
        } else {
            cause.context(format!(
                "legacy snapshot recovery failed and rollback was incomplete ({})",
                failures.join("; ")
            ))
        }
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
            // Saving only proves that a local auth bundle exists. Preserve any
            // server-auth marker until a successful usage/refresh request proves
            // that the replacement session is accepted by OpenAI.
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
        account.updated_at = OffsetDateTime::now_utc();
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
        let mut backup = BackupBundle::new(accounts);
        let store = self.provider_backup_store();
        for record in store.list(environment, None)? {
            let (_, snapshot) = store.load_snapshot(environment, record.id)?;
            backup
                .provider_accounts
                .push(crate::backup::ProviderBackupAccount {
                    provider: record.provider,
                    identity: record.identity,
                    custom_label: record.custom_label,
                    snapshot,
                });
        }
        Ok(backup)
    }

    fn provider_backup_store(
        &self,
    ) -> crate::provider_store::ProviderAccountStore<LocalSecretStore> {
        crate::provider_store::ProviderAccountStore::new(
            &self.data_dir,
            LocalSecretStore::new(&self.data_dir.join("providers").join("snapshots")),
        )
    }

    fn validate_provider_backup(
        &self,
        accounts: &[crate::backup::ProviderBackupAccount],
    ) -> Result<()> {
        for account in accounts {
            if account.provider == AiProvider::OpenAi {
                return Err(anyhow!(
                    "OpenAI snapshots must use the Codex backup accounts"
                ));
            }
            let identity = crate::provider::adapter(account.provider)
                .identity_from_snapshot(&account.snapshot)?;
            if !backup_identity_matches_snapshot(&account.identity, &identity) {
                return Err(anyhow!(
                    "provider backup metadata identity does not match its snapshot"
                ));
            }
        }
        Ok(())
    }

    fn import_provider_backup(
        &self,
        environment: &EnvironmentKind,
        accounts: &[crate::backup::ProviderBackupAccount],
    ) -> Result<Option<PreparedProviderImport>> {
        if accounts.is_empty() {
            return Ok(None);
        }
        let mut staged = PreparedProviderImport::new(&self.data_dir)?;
        let store = crate::provider_store::ProviderAccountStore::new(
            &staged.staging_dir,
            LocalSecretStore::new(&staged.staging_dir.join("providers/snapshots")),
        );
        let mut created = 0;
        let mut updated = 0;
        for account in accounts {
            let (record, is_new) = store.save(
                environment,
                account.provider,
                &account.identity,
                &account.snapshot,
            )?;
            store.set_label(environment, record.id, account.custom_label.clone())?;
            if is_new {
                created += 1;
            } else {
                updated += 1;
            }
        }
        staged.created = created;
        staged.updated = updated;
        Ok(Some(staged))
    }

    fn prepare_provider_full_restore(
        &self,
        environment: &EnvironmentKind,
        accounts: &[crate::backup::ProviderBackupAccount],
    ) -> Result<Option<PreparedProviderImport>> {
        if accounts.is_empty() && !self.data_dir.join("providers").exists() {
            return Ok(None);
        }
        let mut staged = PreparedProviderImport::new(&self.data_dir)?;
        recover_provider_index_for_restore(&staged.staging_dir)?;
        let store = crate::provider_store::ProviderAccountStore::new(
            &staged.staging_dir,
            LocalSecretStore::new(&staged.staging_dir.join("providers/snapshots")),
        );
        for account in accounts {
            let (record, is_new) = store.save(
                environment,
                account.provider,
                &account.identity,
                &account.snapshot,
            )?;
            store.set_label(environment, record.id, account.custom_label.clone())?;
            if is_new {
                staged.created += 1;
            } else {
                staged.updated += 1;
            }
        }
        // Full restore replaces this environment's roster, including an empty
        // provider list. Perform removals only in the prepared directory.
        for record in store.list(environment, None)? {
            if !accounts.iter().any(|account| {
                account.provider == record.provider && account.identity.matches(&record.identity)
            }) {
                store.remove(environment, record.id)?;
            }
        }
        Ok(Some(staged))
    }

    pub fn import_backup(
        &self,
        environment: &EnvironmentKind,
        mut backup: BackupBundle,
    ) -> Result<(usize, usize)> {
        let provider_accounts = std::mem::take(&mut backup.provider_accounts);
        self.validate_provider_backup(&provider_accounts)?;
        let prepared = self.prepare_backup_import(environment, backup, false)?;
        let providers = self.import_provider_backup(environment, &provider_accounts)?;
        let (provider_created, provider_updated) = providers
            .as_ref()
            .map(|prepared| (prepared.created, prepared.updated))
            .unwrap_or_default();
        self.apply_combined_backup_import(&prepared, providers)?;
        self.maybe_write_automatic_full_backup(environment);
        Ok((
            prepared.created + provider_created,
            prepared.updated + provider_updated,
        ))
    }

    pub fn restore_latest_account_list_backup(&self) -> Result<usize> {
        self.index_store.restore_latest_automatic_backup()
    }

    pub fn restore_latest_full_backup(&self, environment: &EnvironmentKind) -> Result<usize> {
        let password = automatic_backup_password()?;
        let mut backup = self
            .best_automatic_full_backup(&password)?
            .ok_or_else(|| anyhow!("no automatic full backup is available"))?;
        let count = backup.accounts.len() + backup.provider_accounts.len();
        let provider_accounts = std::mem::take(&mut backup.provider_accounts);
        self.validate_provider_backup(&provider_accounts)?;
        let previous_index = self.index_store.index_for_restore()?;
        let prepared = self.prepare_backup_import(environment, backup, true)?;
        let providers = self.prepare_provider_full_restore(environment, &provider_accounts)?;
        self.apply_combined_backup_import(&prepared, providers)?;
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
            let mut seen_identities = HashSet::new();
            if self
                .validate_provider_backup(&bundle.provider_accounts)
                .is_err()
                || bundle.accounts.iter().any(|account| {
                    crate::codex::validate_snapshot(&account.snapshot).is_err()
                        || !crate::codex::identity_from_snapshot(&account.snapshot).is_ok_and(
                            |identity| {
                                let key = identity
                                    .subject
                                    .as_deref()
                                    .map(|subject| format!("subject:{subject}"))
                                    .unwrap_or_else(|| {
                                        format!("email:{}", identity.email.to_ascii_lowercase())
                                    });
                                backup_identity_matches_snapshot(&account.identity, &identity)
                                    && seen_identities.insert(key)
                            },
                        )
                })
            {
                continue;
            }
            let replace = match &best {
                None => true,
                Some(current) => bundle.exported_at > current.exported_at,
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
        let current = if replace_environment {
            self.index_store.index_for_restore()?
        } else {
            self.index_store.load_index()?
        };
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
            explicit_restore: replace_environment,
            snapshots,
            created,
            updated,
        })
    }

    fn apply_backup_import(&self, prepared: &PreparedBackupImport) -> Result<()> {
        let mut undo = SnapshotImportUndo::new(&self.data_dir, &prepared.snapshots)?;
        let mut written = Vec::with_capacity(prepared.snapshots.len());
        for snapshot in &prepared.snapshots {
            written.push(snapshot);
            if let Err(error) = self
                .secret_store
                .save(&snapshot.secret_key, &snapshot.encoded_snapshot)
            {
                return Err(self.failed_backup_import(&written, error, &mut undo))
                    .context("failed to persist imported snapshot data");
            }
        }
        let result = if prepared.explicit_restore {
            self.index_store.restore_index(&prepared.index)
        } else {
            self.index_store.save_index(&prepared.index)
        };
        if let Err(error) = result {
            return Err(self.failed_backup_import(&written, error, &mut undo))
                .context("failed to persist imported roster metadata");
        }
        Ok(())
    }

    fn restore_prepared_snapshots(&self, snapshots: &[&PreparedSnapshot]) -> Result<()> {
        let mut failures = Vec::new();
        for snapshot in snapshots.iter().rev() {
            let result = match &snapshot.previous_value {
                Some(value) => self.secret_store.save(&snapshot.secret_key, value),
                None => self.secret_store.delete(&snapshot.secret_key),
            };
            if let Err(error) = result {
                failures.push(format!("{}: {error:#}", snapshot.secret_key));
            }
        }
        if failures.is_empty() {
            Ok(())
        } else {
            Err(anyhow!("{}", failures.join("; ")))
        }
    }

    fn failed_backup_import(
        &self,
        written: &[&PreparedSnapshot],
        cause: anyhow::Error,
        undo: &mut SnapshotImportUndo,
    ) -> anyhow::Error {
        match self.restore_prepared_snapshots(written) {
            Ok(()) => cause.context("imported snapshots were rolled back"),
            Err(rollback) => {
                undo.retain = true;
                cause.context(format!(
                    "snapshot rollback was incomplete: {rollback:#}; encrypted undo retained at {}",
                    undo.directory.display()
                ))
            }
        }
    }

    fn apply_combined_backup_import(
        &self,
        prepared: &PreparedBackupImport,
        mut providers: Option<PreparedProviderImport>,
    ) -> Result<()> {
        if let Some(providers) = &mut providers {
            providers.commit()?;
        }
        if let Err(error) = self.apply_backup_import(prepared) {
            if let Some(providers) = &mut providers
                && let Err(rollback) = providers.rollback()
            {
                return Err(
                    error.context(format!("provider rollback was incomplete: {rollback:#}"))
                );
            }
            return Err(error);
        }
        if let Some(providers) = &mut providers {
            providers.committed = false; // Drop cleans up the retained old store.
        }
        Ok(())
    }

    pub fn create_automatic_full_backup(&self, environment: &EnvironmentKind) -> Result<usize> {
        let count = self.export_backup(environment)?;
        let count = count.accounts.len() + count.provider_accounts.len();
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
        let deleted_secret = self.secret_store.load(&metadata.secret_key)?;
        let preimage = PreparedSnapshot {
            secret_key: metadata.secret_key.clone(),
            encoded_snapshot: Vec::new(),
            previous_value: deleted_secret,
        };
        let mut undo = SnapshotImportUndo::new(&self.data_dir, std::slice::from_ref(&preimage))?;
        if let Err(error) = self.secret_store.delete(&metadata.secret_key) {
            return Err(self.failed_backup_import(&[&preimage], error, &mut undo))
                .context("failed to delete saved snapshot data");
        }
        if let Err(error) = self.index_store.save_index(&index) {
            return Err(self.failed_backup_import(&[&preimage], error, &mut undo))
                .context("failed to persist deleted metadata");
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

    fn review_mixed_backup() -> BackupBundle {
        let mut backup = BackupBundle::new(vec![BackupAccount {
            identity: identity("codex@example.com", "codex-sub"),
            custom_label: None,
            archived: false,
            snapshot: valid_snapshot("codex@example.com", "codex-sub"),
        }]);
        backup
            .provider_accounts
            .push(crate::backup::ProviderBackupAccount {
                provider: AiProvider::Claude,
                identity: DisplayIdentity {
                    email: "claude@example.com".to_owned(),
                    subject: None,
                    name: None,
                    plan_label: None,
                },
                custom_label: Some("Imported label".to_owned()),
                snapshot: SnapshotBlob {
                    schema_version: 1,
                    files: vec![crate::model::SnapshotFile {
                        name: "claude_config.json".to_owned(),
                        bytes_base64: base64::engine::general_purpose::STANDARD
                            .encode(r#"{"oauthAccount":{"emailAddress":"claude@example.com"}}"#),
                    }],
                },
            });
        backup
    }

    struct ReviewFailingDeleteStore {
        inner: MemorySecretStore,
        fail: std::cell::Cell<bool>,
    }

    #[test]
    fn review_recovery_full_restore_preserves_recovered_codex_environment() {
        for corrupt in [false, true] {
            let temp = tempdir().unwrap();
            let repo = SnapshotRepository::new(temp.path(), MemorySecretStore::default());
            let env = EnvironmentKind::Macos;
            let other_env = EnvironmentKind::Linux;
            let other_snapshot = valid_snapshot("other@example.com", "other-sub");
            let other = repo
                .save_snapshot_without_backup(
                    &other_env,
                    &identity("other@example.com", "other-sub"),
                    &other_snapshot,
                )
                .unwrap()
                .0;
            let mut recovered = repo.index_store.load_index().unwrap();
            recovered.write_generation = 100;
            fs::write(
                temp.path().join("account-list-backups/metadata-100.json"),
                serde_json::to_vec(&recovered).unwrap(),
            )
            .unwrap();
            let path = temp.path().join("metadata.json");
            if corrupt {
                fs::write(&path, b"{damaged metadata").unwrap();
            } else {
                fs::remove_file(&path).unwrap();
            }
            let mut backup = review_mixed_backup();
            backup.provider_accounts.clear();
            let prepared = repo.prepare_backup_import(&env, backup, true).unwrap();
            assert_eq!(prepared.index.write_generation, 100);
            repo.apply_combined_backup_import(&prepared, None).unwrap();
            assert_eq!(repo.index_store.load_index().unwrap().write_generation, 101);
            assert_eq!(
                repo.load_snapshot(&other_env, other.id).unwrap().1,
                other_snapshot
            );
            let restored = repo.list_accounts(&env).unwrap().remove(0);
            repo.set_custom_label(&env, restored.id, Some("After restore".to_owned()))
                .unwrap();
            assert_eq!(repo.index_store.load_index().unwrap().write_generation, 102);
            assert_eq!(repo.restore_latest_account_list_backup().unwrap(), 2);
            assert_eq!(
                repo.get_account(&env, restored.id)
                    .unwrap()
                    .unwrap()
                    .custom_label
                    .as_deref(),
                Some("After restore")
            );
            assert_eq!(
                repo.load_snapshot(&other_env, other.id).unwrap().1,
                other_snapshot
            );
        }
    }

    #[test]
    fn review_recovery_provider_restore_rebuilds_corrupt_index() {
        for empty in [false, true] {
            for recovery in [
                None,
                Some("index.json.bak-valid"),
                Some("index.json.tmp-valid"),
            ] {
                let temp = tempdir().unwrap();
                let repo = SnapshotRepository::new(temp.path(), MemorySecretStore::default());
                let env = EnvironmentKind::Macos;
                let other_env = EnvironmentKind::Linux;
                let mut backup = review_mixed_backup();
                let account = backup.provider_accounts[0].clone();
                let store = repo.provider_backup_store();
                let (other, _) = store
                    .save(
                        &other_env,
                        account.provider,
                        &account.identity,
                        &account.snapshot,
                    )
                    .unwrap();
                let (removed, _) = store
                    .save(&env, account.provider, &account.identity, &account.snapshot)
                    .unwrap();
                let path = temp.path().join("providers/index.json");
                let valid = fs::read(&path).unwrap();
                if let Some(name) = recovery {
                    fs::write(path.with_file_name(name), &valid).unwrap();
                }
                fs::write(
                    path.with_file_name("index.json.bak-invalid"),
                    b"{bad recovery",
                )
                .unwrap();
                let damaged = b"{damaged provider metadata";
                fs::write(&path, damaged).unwrap();
                // Recovery is explicit: ordinary import still rejects this store.
                assert!(repo.import_backup(&env, backup.clone()).is_err());
                assert_eq!(fs::read(&path).unwrap(), damaged);
                if empty {
                    backup.provider_accounts.clear();
                }
                let providers = repo
                    .prepare_provider_full_restore(&env, &backup.provider_accounts)
                    .unwrap();
                assert_eq!(fs::read(&path).unwrap(), damaged);
                let prepared = repo.prepare_backup_import(&env, backup, true).unwrap();
                repo.apply_combined_backup_import(&prepared, providers)
                    .unwrap();
                assert_eq!(store.list(&env, None).unwrap().len(), usize::from(!empty));
                if empty {
                    assert!(store.get(&env, removed.id).unwrap().is_none());
                }
                if recovery.is_some() {
                    assert_eq!(
                        store.load_snapshot(&other_env, other.id).unwrap().1,
                        account.snapshot
                    );
                }
                assert!(
                    fs::read_dir(temp.path().join("providers"))
                        .unwrap()
                        .flatten()
                        .any(|entry| {
                            entry
                                .file_name()
                                .to_string_lossy()
                                .starts_with("preserved-index-")
                                && fs::read(entry.path()).unwrap() == damaged
                        })
                );
            }
        }
    }

    #[test]
    fn review_recovery_provider_restore_keeps_source_candidate_order() {
        for empty in [false, true] {
            for (older_name, newer_name) in [
                ("index.json.bak-older", "index.json.tmp-newer"),
                ("index.json.tmp-older", "index.json.bak-newer"),
            ] {
                let temp = tempdir().unwrap();
                let repo = SnapshotRepository::new(temp.path(), MemorySecretStore::default());
                let env = EnvironmentKind::Macos;
                let other_env = EnvironmentKind::Linux;
                let mut backup = review_mixed_backup();
                let account = backup.provider_accounts[0].clone();
                let store = repo.provider_backup_store();
                store
                    .save(&env, account.provider, &account.identity, &account.snapshot)
                    .unwrap();
                let path = temp.path().join("providers/index.json");
                let older = fs::read(&path).unwrap();
                let (other, _) = store
                    .save(
                        &other_env,
                        account.provider,
                        &account.identity,
                        &account.snapshot,
                    )
                    .unwrap();
                let newer = fs::read(&path).unwrap();
                let older_time = SystemTime::UNIX_EPOCH + std::time::Duration::from_secs(60);
                let newer_time = SystemTime::UNIX_EPOCH + std::time::Duration::from_secs(120);
                for (name, bytes, modified) in [
                    (older_name, older.as_slice(), older_time),
                    (newer_name, newer.as_slice(), newer_time),
                ] {
                    let candidate = path.with_file_name(name);
                    fs::write(&candidate, bytes).unwrap();
                    fs::File::open(&candidate)
                        .unwrap()
                        .set_times(fs::FileTimes::new().set_modified(modified))
                        .unwrap();
                    #[cfg(unix)]
                    {
                        use std::os::unix::fs::PermissionsExt;
                        fs::set_permissions(&candidate, fs::Permissions::from_mode(0o400)).unwrap();
                    }
                }
                let damaged = b"{damaged provider metadata";
                fs::write(&path, damaged).unwrap();
                if empty {
                    backup.provider_accounts.clear();
                }
                let providers = repo
                    .prepare_provider_full_restore(&env, &backup.provider_accounts)
                    .unwrap()
                    .unwrap();
                for (name, modified) in [(older_name, older_time), (newer_name, newer_time)] {
                    assert_eq!(
                        fs::metadata(providers.staging_dir.join("providers").join(name))
                            .unwrap()
                            .modified()
                            .unwrap(),
                        modified
                    );
                }
                assert_eq!(fs::read(&path).unwrap(), damaged);
                let prepared = repo.prepare_backup_import(&env, backup, true).unwrap();
                repo.apply_combined_backup_import(&prepared, Some(providers))
                    .unwrap();
                assert_eq!(store.list(&env, None).unwrap().len(), usize::from(!empty));
                assert_eq!(
                    store.load_snapshot(&other_env, other.id).unwrap().1,
                    account.snapshot
                );
            }
        }
    }

    #[test]
    fn review_recovery_provider_restore_rolls_back_original_corruption() {
        let temp = tempdir().unwrap();
        let repo = SnapshotRepository::new(
            temp.path(),
            ReviewFailingSaveStore {
                inner: MemorySecretStore::default(),
                fail_next: std::cell::Cell::new(false),
            },
        );
        let env = EnvironmentKind::Macos;
        let backup = review_mixed_backup();
        let account = &backup.provider_accounts[0];
        repo.provider_backup_store()
            .save(
                &EnvironmentKind::Linux,
                account.provider,
                &account.identity,
                &account.snapshot,
            )
            .unwrap();
        let path = temp.path().join("providers/index.json");
        let valid = fs::read(&path).unwrap();
        fs::write(path.with_file_name("index.json.bak-valid"), &valid).unwrap();
        let damaged = b"{damaged provider metadata";
        fs::write(&path, damaged).unwrap();
        let providers = repo
            .prepare_provider_full_restore(&env, &backup.provider_accounts)
            .unwrap();
        let prepared = repo.prepare_backup_import(&env, backup, true).unwrap();
        repo.secret_store.fail_next.set(true);
        assert!(
            repo.apply_combined_backup_import(&prepared, providers)
                .is_err()
        );
        assert_eq!(fs::read(&path).unwrap(), damaged);
        assert_eq!(
            fs::read(path.with_file_name("index.json.bak-valid")).unwrap(),
            valid
        );
        assert!(repo.list_accounts(&env).unwrap().is_empty());
    }

    #[test]
    fn review_regression_full_restore_replaces_provider_roster_and_preserves_other_environment() {
        for empty in [false, true] {
            let temp = tempdir().unwrap();
            let repo = SnapshotRepository::new(temp.path(), MemorySecretStore::default());
            let env = EnvironmentKind::Windows;
            let other_env = EnvironmentKind::Linux;
            let backup = review_mixed_backup();
            let account = &backup.provider_accounts[0];
            let store = repo.provider_backup_store();
            let (_, _) = store
                .save(&env, account.provider, &account.identity, &account.snapshot)
                .unwrap();
            let (other, _) = store
                .save(
                    &other_env,
                    account.provider,
                    &account.identity,
                    &account.snapshot,
                )
                .unwrap();
            let mut removed_identity = account.identity.clone();
            removed_identity.email = "removed@example.com".to_owned();
            let (removed, _) = store
                .save(&env, account.provider, &removed_identity, &account.snapshot)
                .unwrap();
            let original_index = fs::read(temp.path().join("providers/index.json")).unwrap();
            let accounts = if empty {
                &[][..]
            } else {
                backup.provider_accounts.as_slice()
            };
            let providers = repo.prepare_provider_full_restore(&env, accounts).unwrap();
            assert_eq!(
                fs::read(temp.path().join("providers/index.json")).unwrap(),
                original_index
            );
            let prepared = repo
                .prepare_backup_import(&env, backup.clone(), true)
                .unwrap();
            repo.apply_combined_backup_import(&prepared, providers)
                .unwrap();
            assert_eq!(store.list(&env, None).unwrap().len(), usize::from(!empty));
            assert!(store.get(&env, removed.id).unwrap().is_none());
            assert_eq!(
                store.load_snapshot(&other_env, other.id).unwrap().1,
                account.snapshot
            );
            assert!(!fs::read_dir(temp.path()).unwrap().flatten().any(|entry| {
                entry
                    .file_name()
                    .to_string_lossy()
                    .starts_with(".backup-import-")
            }));
        }
    }

    impl SecretStore for ReviewFailingDeleteStore {
        fn save(&self, key: &str, value: &[u8]) -> Result<()> {
            if self.fail.get() {
                return Err(anyhow!("injected rollback failure"));
            }
            self.inner.save(key, value)
        }
        fn load(&self, key: &str) -> Result<Option<Vec<u8>>> {
            self.inner.load(key)
        }
        fn delete(&self, key: &str) -> Result<()> {
            self.inner.delete(key)?;
            if self.fail.get() {
                return Err(anyhow!("injected partial delete failure"));
            }
            Ok(())
        }
    }

    #[test]
    fn review_regression_delete_failed_rollback_retains_encrypted_preimage() {
        let temp = tempdir().unwrap();
        let repo = SnapshotRepository::new(
            temp.path(),
            ReviewFailingDeleteStore {
                inner: MemorySecretStore::default(),
                fail: std::cell::Cell::new(false),
            },
        );
        let env = EnvironmentKind::Windows;
        let record = repo
            .save_snapshot_without_backup(
                &env,
                &identity("codex@example.com", "codex-sub"),
                &valid_snapshot("codex@example.com", "codex-sub"),
            )
            .unwrap()
            .0;
        let previous = repo.secret_store.load(&record.secret_key).unwrap().unwrap();
        let metadata = fs::read(temp.path().join("metadata.json")).unwrap();
        repo.secret_store.fail.set(true);
        let error = repo.delete_snapshot(&env, record.id).unwrap_err();
        assert!(format!("{error:#}").contains("encrypted undo retained at"));
        assert_eq!(
            fs::read(temp.path().join("metadata.json")).unwrap(),
            metadata
        );
        assert!(
            repo.secret_store
                .load(&record.secret_key)
                .unwrap()
                .is_none()
        );
        let retained = fs::read_dir(temp.path())
            .unwrap()
            .flatten()
            .find(|entry| {
                entry
                    .file_name()
                    .to_string_lossy()
                    .starts_with(".snapshot-import-undo-")
            })
            .unwrap()
            .path();
        assert_eq!(
            LocalSecretStore::new(&retained.join("snapshots"))
                .load(&record.secret_key)
                .unwrap()
                .unwrap(),
            previous
        );
    }

    struct ReviewFailNthSaveStore {
        inner: MemorySecretStore,
        remaining: std::cell::Cell<usize>,
    }

    impl SecretStore for ReviewFailNthSaveStore {
        fn save(&self, key: &str, value: &[u8]) -> Result<()> {
            self.inner.save(key, value)?;
            let remaining = self.remaining.get();
            if remaining > 0 {
                self.remaining.set(remaining - 1);
                if remaining == 1 {
                    return Err(anyhow!("injected later partial write"));
                }
            }
            Ok(())
        }
        fn load(&self, key: &str) -> Result<Option<Vec<u8>>> {
            self.inner.load(key)
        }
        fn delete(&self, key: &str) -> Result<()> {
            self.inner.delete(key)
        }
    }

    #[test]
    fn review_regression_later_partial_import_restores_updated_and_absent_preimages() {
        let temp = tempdir().unwrap();
        let repo = SnapshotRepository::new(
            temp.path(),
            ReviewFailNthSaveStore {
                inner: MemorySecretStore::default(),
                remaining: std::cell::Cell::new(0),
            },
        );
        let env = EnvironmentKind::Windows;
        let original = valid_snapshot("codex@example.com", "codex-sub");
        let record = repo
            .save_snapshot_without_backup(
                &env,
                &identity("codex@example.com", "codex-sub"),
                &original,
            )
            .unwrap()
            .0;
        let metadata_before = fs::read(temp.path().join("metadata.json")).unwrap();
        let secret_before = repo.secret_store.load(&record.secret_key).unwrap();
        let mut backup = review_mixed_backup();
        backup.accounts[0].snapshot.files[1].bytes_base64 =
            base64::engine::general_purpose::STANDARD.encode("changed sid");
        backup.accounts.push(BackupAccount {
            identity: identity("new@example.com", "new-sub"),
            custom_label: None,
            archived: false,
            snapshot: valid_snapshot("new@example.com", "new-sub"),
        });
        let provider = &backup.provider_accounts[0];
        let store = repo.provider_backup_store();
        let (provider_record, _) = store
            .save(
                &env,
                provider.provider,
                &provider.identity,
                &provider.snapshot,
            )
            .unwrap();
        store
            .set_label(&env, provider_record.id, Some("old label".to_owned()))
            .unwrap();
        let provider_before = fs::read(temp.path().join("providers/index.json")).unwrap();
        let provider_snapshot_before = store.load_snapshot(&env, provider_record.id).unwrap().1;
        let prepared = repo
            .prepare_backup_import(&env, backup.clone(), false)
            .unwrap();
        let absent_key = prepared.snapshots[1].secret_key.clone();
        let providers = repo
            .import_provider_backup(&env, &backup.provider_accounts)
            .unwrap();
        repo.secret_store.remaining.set(2);
        assert!(
            repo.apply_combined_backup_import(&prepared, providers)
                .is_err()
        );
        assert_eq!(
            repo.secret_store.load(&record.secret_key).unwrap(),
            secret_before
        );
        assert!(repo.secret_store.load(&absent_key).unwrap().is_none());
        assert_eq!(
            fs::read(temp.path().join("metadata.json")).unwrap(),
            metadata_before
        );
        assert_eq!(
            fs::read(temp.path().join("providers/index.json")).unwrap(),
            provider_before
        );
        assert_eq!(
            store.load_snapshot(&env, provider_record.id).unwrap().1,
            provider_snapshot_before
        );
        assert!(!fs::read_dir(temp.path()).unwrap().flatten().any(|entry| {
            let name = entry.file_name();
            let name = name.to_string_lossy();
            name.starts_with(".backup-import-") || name.starts_with(".snapshot-import-undo-")
        }));
    }

    #[test]
    fn review_regression_duplicate_identity_full_backup_is_skipped() {
        let temp = tempdir().unwrap();
        let repo = SnapshotRepository::new(temp.path(), MemorySecretStore::default());
        fs::create_dir(repo.automatic_backup_dir()).unwrap();
        let mut valid = review_mixed_backup();
        valid.exported_at = OffsetDateTime::now_utc() - Duration::days(1);
        let mut duplicate = valid.clone();
        duplicate.exported_at += Duration::hours(1);
        duplicate.accounts.push(duplicate.accounts[0].clone());
        write_encrypted(
            &repo.automatic_backup_dir().join("valid.codexroster"),
            &valid,
            "fixture-password",
        )
        .unwrap();
        write_encrypted(
            &repo.automatic_backup_dir().join("duplicate.codexroster"),
            &duplicate,
            "fixture-password",
        )
        .unwrap();
        assert_eq!(
            repo.best_automatic_full_backup("fixture-password")
                .unwrap()
                .unwrap()
                .exported_at,
            valid.exported_at
        );
    }

    #[test]
    fn review_regression_mixed_import_provider_prepare_failure_preserves_codex() {
        let temp = tempdir().unwrap();
        let repo = SnapshotRepository::new(temp.path(), MemorySecretStore::default());
        let env = EnvironmentKind::Windows;
        let account = repo
            .save_snapshot_without_backup(
                &env,
                &identity("codex@example.com", "codex-sub"),
                &valid_snapshot("codex@example.com", "codex-sub"),
            )
            .unwrap()
            .0;
        let metadata_before = fs::read(temp.path().join("metadata.json")).unwrap();
        let secret_before = repo.secret_store.load(&account.secret_key).unwrap();
        fs::create_dir(temp.path().join("providers")).unwrap();
        fs::write(
            temp.path().join("providers/index.json"),
            b"{corrupt provider index",
        )
        .unwrap();
        let error = repo.import_backup(&env, review_mixed_backup()).unwrap_err();
        assert!(format!("{error:#}").contains("provider index"));
        assert_eq!(
            fs::read(temp.path().join("metadata.json")).unwrap(),
            metadata_before
        );
        assert_eq!(
            repo.secret_store.load(&account.secret_key).unwrap(),
            secret_before
        );
        assert_eq!(
            fs::read(temp.path().join("providers/index.json")).unwrap(),
            b"{corrupt provider index"
        );
        assert!(!fs::read_dir(temp.path()).unwrap().flatten().any(|entry| {
            entry
                .file_name()
                .to_string_lossy()
                .starts_with(".backup-import-")
        }));
    }

    struct ReviewFailingSaveStore {
        inner: MemorySecretStore,
        fail_next: std::cell::Cell<bool>,
    }

    impl SecretStore for ReviewFailingSaveStore {
        fn save(&self, key: &str, value: &[u8]) -> Result<()> {
            self.inner.save(key, value)?;
            if self.fail_next.replace(false) {
                return Err(anyhow!("injected partial snapshot write failure"));
            }
            Ok(())
        }
        fn load(&self, key: &str) -> Result<Option<Vec<u8>>> {
            self.inner.load(key)
        }
        fn delete(&self, key: &str) -> Result<()> {
            self.inner.delete(key)
        }
    }

    #[test]
    fn review_regression_mixed_import_rolls_back_both_stores_after_codex_write_failure() {
        let temp = tempdir().unwrap();
        let repo = SnapshotRepository::new(
            temp.path(),
            ReviewFailingSaveStore {
                inner: MemorySecretStore::default(),
                fail_next: std::cell::Cell::new(false),
            },
        );
        let env = EnvironmentKind::Windows;
        let account = repo
            .save_snapshot_without_backup(
                &env,
                &identity("codex@example.com", "codex-sub"),
                &valid_snapshot("codex@example.com", "codex-sub"),
            )
            .unwrap()
            .0;
        let metadata_before = fs::read(temp.path().join("metadata.json")).unwrap();
        let secret_before = repo.secret_store.load(&account.secret_key).unwrap();
        let provider = review_mixed_backup().provider_accounts.remove(0);
        let store = repo.provider_backup_store();
        let (record, _) = store
            .save(
                &env,
                provider.provider,
                &provider.identity,
                &provider.snapshot,
            )
            .unwrap();
        store
            .set_label(&env, record.id, Some("Original label".to_owned()))
            .unwrap();
        let provider_before = fs::read(temp.path().join("providers/index.json")).unwrap();
        let provider_secret = store.load_snapshot(&env, record.id).unwrap().1;
        repo.secret_store.fail_next.set(true);
        assert!(repo.import_backup(&env, review_mixed_backup()).is_err());
        assert_eq!(
            fs::read(temp.path().join("metadata.json")).unwrap(),
            metadata_before
        );
        assert_eq!(
            repo.secret_store.load(&account.secret_key).unwrap(),
            secret_before
        );
        assert_eq!(
            fs::read(temp.path().join("providers/index.json")).unwrap(),
            provider_before
        );
        assert_eq!(
            store.load_snapshot(&env, record.id).unwrap().1,
            provider_secret
        );
    }

    #[test]
    fn review_regression_mixed_import_rolls_back_provider_when_codex_metadata_save_fails() {
        let temp = tempdir().unwrap();
        let repo = SnapshotRepository::new(temp.path(), MemorySecretStore::default());
        let env = EnvironmentKind::Windows;
        let prepared = repo
            .prepare_backup_import(&env, review_mixed_backup(), false)
            .unwrap();
        let providers = repo
            .import_provider_backup(&env, &review_mixed_backup().provider_accounts)
            .unwrap();
        // Make the canonical metadata destination a nonempty directory. Its
        // recovery read must fail after provider commit, without permissions tricks.
        fs::create_dir(temp.path().join("metadata.json")).unwrap();
        fs::write(temp.path().join("metadata.json/blocker"), b"fixture").unwrap();
        assert!(
            repo.apply_combined_backup_import(&prepared, providers)
                .is_err()
        );
        assert!(!temp.path().join("providers").exists());
        for snapshot in prepared.snapshots {
            assert!(
                repo.secret_store
                    .load(&snapshot.secret_key)
                    .unwrap()
                    .is_none()
            );
        }
    }

    #[test]
    fn review_regression_explicit_full_restore_accepts_missing_or_corrupt_metadata() {
        for metadata in [None, Some(b"{damaged metadata".as_slice())] {
            let temp = tempdir().unwrap();
            let repo = SnapshotRepository::new(temp.path(), MemorySecretStore::default());
            fs::create_dir(temp.path().join("snapshots")).unwrap();
            fs::write(temp.path().join("snapshots/orphan.snapshot"), b"fixture").unwrap();
            if let Some(bytes) = metadata {
                fs::write(temp.path().join("metadata.json"), bytes).unwrap();
            }
            let env = EnvironmentKind::Windows;
            let backup = review_mixed_backup();
            let prepared = repo
                .prepare_backup_import(&env, backup.clone(), true)
                .unwrap();
            let providers = repo
                .import_provider_backup(&env, &backup.provider_accounts)
                .unwrap();
            repo.apply_combined_backup_import(&prepared, providers)
                .unwrap();
            assert_eq!(repo.list_accounts(&env).unwrap().len(), 1);
            assert_eq!(
                repo.provider_backup_store().list(&env, None).unwrap().len(),
                1
            );
            if let Some(bytes) = metadata {
                assert!(fs::read_dir(temp.path()).unwrap().flatten().any(|entry| {
                    entry
                        .file_name()
                        .to_string_lossy()
                        .starts_with("preserved-metadata-")
                        && fs::read(entry.path()).unwrap() == bytes
                }));
            }
        }
    }

    #[test]
    fn review_regression_legacy_late_load_error_undoes_earlier_writes() {
        let legacy = tempdir().unwrap();
        let legacy_repo = SnapshotRepository::new(legacy.path(), MemorySecretStore::default());
        let env = EnvironmentKind::Windows;
        let snapshot = valid_snapshot("legacy@example.com", "legacy-sub");
        let first = legacy_repo
            .save_snapshot_without_backup(
                &env,
                &identity("legacy@example.com", "legacy-sub"),
                &snapshot,
            )
            .unwrap()
            .0;
        let second = legacy_repo
            .save_snapshot_without_backup(
                &env,
                &identity("broken@example.com", "broken-sub"),
                &valid_snapshot("broken@example.com", "broken-sub"),
            )
            .unwrap()
            .0;
        fs::create_dir(legacy.path().join("snapshots")).unwrap();
        let secret_path = |key: &str| {
            legacy.path().join("snapshots").join(format!(
                "{}.snapshot",
                base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(key)
            ))
        };
        fs::write(
            secret_path(&first.secret_key),
            serde_json::to_vec(&snapshot).unwrap(),
        )
        .unwrap();
        fs::create_dir(secret_path(&second.secret_key)).unwrap();
        let current = tempdir().unwrap();
        let repo = SnapshotRepository::new(current.path(), MemorySecretStore::default());
        repo.secret_store
            .save(&first.secret_key, b"previous secret")
            .unwrap();
        let error = repo
            .recover_legacy_snapshots(&env, legacy.path())
            .unwrap_err();
        assert!(format!("{error:#}").contains("rolled back"));
        assert_eq!(
            repo.secret_store.load(&first.secret_key).unwrap().unwrap(),
            b"previous secret"
        );
        assert!(repo.list_accounts(&env).unwrap().is_empty());
    }

    #[test]
    fn review_regression_partial_local_secret_delete_restores_account_snapshot() {
        let temp = tempdir().unwrap();
        let repo = SnapshotRepository::new(
            temp.path(),
            LocalSecretStore::new(&temp.path().join("snapshots")),
        );
        let env = EnvironmentKind::Windows;
        let snapshot = valid_snapshot("codex@example.com", "codex-sub");
        let account = repo
            .save_snapshot_without_backup(
                &env,
                &identity("codex@example.com", "codex-sub"),
                &snapshot,
            )
            .unwrap()
            .0;
        let filename = format!(
            "{}.snapshot.bak-stale",
            base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(&account.secret_key)
        );
        fs::create_dir(temp.path().join("snapshots").join(filename)).unwrap();
        assert!(repo.delete_snapshot(&env, account.id).is_err());
        assert_eq!(repo.load_snapshot(&env, account.id).unwrap().1, snapshot);
        assert_eq!(repo.list_accounts(&env).unwrap().len(), 1);
    }

    #[test]
    fn review_regression_full_backup_selection_uses_newest_valid_instead_of_largest() {
        let temp = tempdir().unwrap();
        let repo = SnapshotRepository::new(temp.path(), MemorySecretStore::default());
        fs::create_dir(repo.automatic_backup_dir()).unwrap();
        let mut old = review_mixed_backup();
        old.exported_at = OffsetDateTime::now_utc() - Duration::days(2);
        let mut latest = BackupBundle::new(vec![BackupAccount {
            identity: identity("new@example.com", "new-sub"),
            custom_label: None,
            archived: false,
            snapshot: valid_snapshot("new@example.com", "new-sub"),
        }]);
        latest.exported_at = old.exported_at + Duration::days(1);
        write_encrypted(
            &repo.automatic_backup_dir().join("old.codexroster"),
            &old,
            "fixture-password",
        )
        .unwrap();
        write_encrypted(
            &repo.automatic_backup_dir().join("latest.codexroster"),
            &latest,
            "fixture-password",
        )
        .unwrap();
        fs::write(
            repo.automatic_backup_dir().join("corrupt.codexroster"),
            b"invalid ciphertext",
        )
        .unwrap();
        let selected = repo
            .best_automatic_full_backup("fixture-password")
            .unwrap()
            .unwrap();
        assert_eq!(selected.accounts.len(), 1);
        assert_eq!(selected.accounts[0].identity.email, "new@example.com");
        assert!(selected.provider_accounts.is_empty());
    }

    #[test]
    fn review_regression_newer_decryptable_but_invalid_full_backup_is_skipped() {
        let temp = tempdir().unwrap();
        let repo = SnapshotRepository::new(temp.path(), MemorySecretStore::default());
        fs::create_dir(repo.automatic_backup_dir()).unwrap();
        let mut valid = review_mixed_backup();
        valid.exported_at = OffsetDateTime::now_utc() - Duration::days(1);
        let mut invalid = valid.clone();
        invalid.exported_at += Duration::hours(1);
        invalid.accounts[0].snapshot.files[0].bytes_base64 = "not base64".to_owned();
        write_encrypted(
            &repo.automatic_backup_dir().join("valid.codexroster"),
            &valid,
            "fixture-password",
        )
        .unwrap();
        write_encrypted(
            &repo.automatic_backup_dir().join("invalid.codexroster"),
            &invalid,
            "fixture-password",
        )
        .unwrap();
        assert_eq!(
            repo.best_automatic_full_backup("fixture-password")
                .unwrap()
                .unwrap()
                .exported_at,
            valid.exported_at
        );
    }

    #[test]
    fn review_regression_provider_failed_rollback_retains_original_directory() {
        let temp = tempdir().unwrap();
        let repo = SnapshotRepository::new(temp.path(), MemorySecretStore::default());
        let env = EnvironmentKind::Windows;
        let provider = review_mixed_backup().provider_accounts.remove(0);
        repo.provider_backup_store()
            .save(
                &env,
                provider.provider,
                &provider.identity,
                &provider.snapshot,
            )
            .unwrap();
        let previous = fs::read(temp.path().join("providers/index.json")).unwrap();
        let mut staged = repo
            .import_provider_backup(&env, &[provider])
            .unwrap()
            .unwrap();
        let retained = staged.staging_dir.clone();
        staged.commit().unwrap();
        fs::create_dir(staged.staging_dir.join("providers")).unwrap();
        fs::write(staged.staging_dir.join("providers/blocker"), b"fixture").unwrap();
        assert!(staged.rollback().is_err());
        drop(staged);
        assert_eq!(
            fs::read(retained.join("original-providers/index.json")).unwrap(),
            previous
        );
    }

    #[cfg(unix)]
    #[test]
    fn review_regression_provider_staging_is_private_and_rejects_symlinks() {
        use std::os::unix::fs::{PermissionsExt, symlink};
        let temp = tempdir().unwrap();
        let repo = SnapshotRepository::new(temp.path(), MemorySecretStore::default());
        let provider = review_mixed_backup().provider_accounts.remove(0);
        let staged = repo
            .import_provider_backup(&EnvironmentKind::Windows, std::slice::from_ref(&provider))
            .unwrap()
            .unwrap();
        assert_eq!(
            fs::metadata(&staged.staging_dir)
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o700
        );
        assert_eq!(
            fs::metadata(staged.staging_dir.join("providers/snapshots"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o700
        );
        drop(staged);
        fs::create_dir(temp.path().join("providers")).unwrap();
        fs::write(temp.path().join("unrelated"), b"unchanged").unwrap();
        symlink(
            temp.path().join("unrelated"),
            temp.path().join("providers/link"),
        )
        .unwrap();
        assert!(
            repo.import_provider_backup(&EnvironmentKind::Windows, &[provider])
                .is_err()
        );
        assert_eq!(
            fs::read(temp.path().join("unrelated")).unwrap(),
            b"unchanged"
        );
    }

    struct ReviewRollbackFailureStore {
        inner: MemorySecretStore,
        failure_mode: std::cell::Cell<u8>,
    }

    impl SecretStore for ReviewRollbackFailureStore {
        fn save(&self, key: &str, value: &[u8]) -> Result<()> {
            if self.failure_mode.get() == 1 {
                self.inner.save(key, value)?;
                self.failure_mode.set(2);
                return Err(anyhow!("injected partial write failure"));
            }
            if self.failure_mode.get() == 2 {
                return Err(anyhow!("injected persistent save failure"));
            }
            self.inner.save(key, value)
        }
        fn load(&self, key: &str) -> Result<Option<Vec<u8>>> {
            self.inner.load(key)
        }
        fn delete(&self, key: &str) -> Result<()> {
            self.inner.delete(key)
        }
    }

    #[test]
    fn review_regression_failed_snapshot_rollback_retains_encrypted_previous_value() {
        let temp = tempdir().unwrap();
        let repo = SnapshotRepository::new(
            temp.path(),
            ReviewRollbackFailureStore {
                inner: MemorySecretStore::default(),
                failure_mode: std::cell::Cell::new(0),
            },
        );
        let env = EnvironmentKind::Windows;
        let snapshot = valid_snapshot("codex@example.com", "codex-sub");
        let record = repo
            .save_snapshot_without_backup(
                &env,
                &identity("codex@example.com", "codex-sub"),
                &snapshot,
            )
            .unwrap()
            .0;
        let previous = repo.secret_store.load(&record.secret_key).unwrap().unwrap();
        let prepared = repo
            .prepare_backup_import(&env, review_mixed_backup(), false)
            .unwrap();
        repo.secret_store.failure_mode.set(1);
        let error = repo.apply_backup_import(&prepared).unwrap_err();
        assert!(format!("{error:#}").contains("encrypted undo retained at"));
        let retained = fs::read_dir(temp.path())
            .unwrap()
            .flatten()
            .find(|entry| {
                entry
                    .file_name()
                    .to_string_lossy()
                    .starts_with(".snapshot-import-undo-")
            })
            .unwrap()
            .path();
        assert_eq!(
            LocalSecretStore::new(&retained.join("snapshots"))
                .load(&record.secret_key)
                .unwrap()
                .unwrap(),
            previous
        );
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                fs::metadata(retained).unwrap().permissions().mode() & 0o777,
                0o700
            );
        }
    }

    #[test]
    fn external_provider_backup_round_trips_snapshot_and_label() {
        let source = tempdir().expect("source");
        let repo = SnapshotRepository::new(source.path(), MemorySecretStore::default());
        let identity = DisplayIdentity {
            email: "claude@example.com".to_owned(),
            subject: None,
            name: None,
            plan_label: None,
        };
        let snapshot = SnapshotBlob {
            schema_version: 1,
            files: vec![crate::model::SnapshotFile {
                name: "claude_config.json".to_owned(),
                bytes_base64: base64::engine::general_purpose::STANDARD
                    .encode(r#"{"oauthAccount":{"emailAddress":"claude@example.com"}}"#),
            }],
        };
        let store = repo.provider_backup_store();
        let (record, _) = store
            .save(
                &EnvironmentKind::Macos,
                AiProvider::Claude,
                &identity,
                &snapshot,
            )
            .expect("save provider");
        store
            .set_label(&EnvironmentKind::Macos, record.id, Some("Work".to_owned()))
            .expect("label");
        let backup = repo.export_backup(&EnvironmentKind::Macos).expect("export");
        assert_eq!(backup.provider_accounts.len(), 1);
        let path = source.path().join("backup.codexroster");
        write_encrypted(&path, &backup, "fixture-password").expect("encrypt");
        let decoded = read_encrypted(&path, "fixture-password").expect("decrypt");
        let destination = tempdir().expect("destination");
        let restored = SnapshotRepository::new(destination.path(), MemorySecretStore::default());
        // Keep the automatic-backup cooldown active, avoiding system key access.
        fs::create_dir(restored.automatic_backup_dir()).expect("backup directory");
        fs::write(restored.automatic_backup_dir().join("cooldown"), b"").expect("cooldown");
        assert_eq!(
            restored
                .import_backup(&EnvironmentKind::Macos, decoded)
                .expect("import"),
            (1, 0)
        );
        let exported = restored
            .export_backup(&EnvironmentKind::Macos)
            .expect("re-export");
        assert_eq!(exported.provider_accounts[0].snapshot, snapshot);
        assert_eq!(
            exported.provider_accounts[0].custom_label.as_deref(),
            Some("Work")
        );
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

    #[cfg(unix)]
    #[test]
    fn legacy_recovery_rolls_back_secrets_when_the_index_cannot_be_saved() {
        use std::os::unix::fs::PermissionsExt;
        let env = EnvironmentKind::Windows;
        let snapshot = SnapshotBlob {
            schema_version: 1,
            files: vec![],
        };

        let legacy_dir = tempdir().expect("legacy tempdir");
        let legacy_repo = SnapshotRepository::new(
            legacy_dir.path(),
            LocalSecretStore::new(&legacy_dir.path().join("snapshots")),
        );
        legacy_repo
            .save_snapshot(
                &env,
                &identity("legacy@example.com", "sub-legacy"),
                &snapshot,
            )
            .expect("legacy save");

        let current_dir = tempdir().expect("current tempdir");
        let secrets = MemorySecretStore::default();
        let repo = SnapshotRepository::new(current_dir.path(), secrets.clone());
        // Make the roster index unwritable while secrets remain writable.
        fs::set_permissions(current_dir.path(), fs::Permissions::from_mode(0o500)).expect("chmod");

        let result = repo.recover_legacy_snapshots(&env, legacy_dir.path());

        fs::set_permissions(current_dir.path(), fs::Permissions::from_mode(0o700))
            .expect("restore chmod");
        let error = result.expect_err("index save must fail");
        assert!(format!("{error:#}").contains("rolled back"), "{error:#}");
        let legacy_accounts = MetadataIndexStore::new(legacy_dir.path())
            .load_index()
            .expect("legacy index")
            .accounts;
        assert_eq!(legacy_accounts.len(), 1);
        assert!(
            secrets
                .load(&legacy_accounts[0].secret_key)
                .expect("load")
                .is_none(),
            "imported secrets must not remain as orphans"
        );
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
    fn saving_local_auth_does_not_clear_unverified_login_error() {
        let temp = tempdir().expect("tempdir");
        let repo = SnapshotRepository::new(temp.path(), MemorySecretStore::default());
        let env = EnvironmentKind::Macos;
        let snapshot = SnapshotBlob {
            schema_version: 1,
            files: vec![],
        };
        let identity = identity("person@example.com", "sub-1");
        let saved = repo
            .save_snapshot(&env, &identity, &snapshot)
            .expect("save")
            .0;
        repo.record_usage_error(&env, saved.id, "Login required".to_owned())
            .expect("record error");

        repo.save_snapshot(&env, &identity, &snapshot)
            .expect("re-save local auth");

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
    fn recording_usage_error_updates_the_diagnostic_timestamp() {
        let temp = tempdir().expect("tempdir");
        let repo = SnapshotRepository::new(temp.path(), MemorySecretStore::default());
        let env = EnvironmentKind::Linux;
        let snapshot = SnapshotBlob {
            schema_version: 1,
            files: vec![],
        };
        let saved = repo
            .save_snapshot(&env, &identity("person@example.com", "sub-1"), &snapshot)
            .expect("save")
            .0;
        std::thread::sleep(std::time::Duration::from_millis(1));

        let updated = repo
            .record_usage_error(&env, saved.id, "Usage unavailable".to_owned())
            .expect("record error");

        assert!(updated.updated_at > saved.updated_at);
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
