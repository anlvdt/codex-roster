use base64::Engine;
use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, anyhow, bail};
use serde::{Deserialize, Serialize};
use time::OffsetDateTime;
use uuid::Uuid;

use crate::file_store::{RecoveryFileKind, list_recovery_files, replace_file_with_recovery};
use crate::model::{
    AiProvider, DisplayIdentity, EnvironmentKind, ProviderAccountView, ProviderUsageStatus,
    ProviderUsageView, SnapshotBlob,
};
use crate::provider::claude::UNKNOWN_EMAIL;
use crate::secrets::SecretStore;

const PROVIDER_INDEX_SCHEMA_VERSION: u32 = 1;

pub(crate) const LOGIN_REQUIRED_ERROR_PREFIX: &str = "login_required";

#[derive(Clone, Debug, Serialize, Deserialize)]
pub(crate) struct ProviderSavedAccount {
    pub id: Uuid,
    pub provider: AiProvider,
    pub environment: EnvironmentKind,
    pub identity: DisplayIdentity,
    pub secret_key: String,
    pub created_at: OffsetDateTime,
    pub updated_at: OffsetDateTime,
    pub last_activated_at: Option<OffsetDateTime>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub custom_label: Option<String>,
    #[serde(default)]
    pub cached_usage: Option<ProviderUsageView>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cached_usage_error: Option<String>,
    #[serde(default)]
    pub consecutive_auth_failures: u8,
}

impl ProviderSavedAccount {
    pub(crate) fn view(&self, is_active: bool) -> ProviderAccountView {
        ProviderAccountView {
            id: self.id,
            provider: self.provider,
            email: self.identity.email.clone(),
            subject: self.identity.subject.clone(),
            name: self.identity.name.clone(),
            custom_label: self.custom_label.clone(),
            plan_label: self.identity.plan_label.clone(),
            environment: self.environment.clone(),
            is_active,
            created_at: self.created_at,
            updated_at: self.updated_at,
            last_activated_at: self.last_activated_at,
            usage: self.cached_usage.clone(),
            usage_error: self.cached_usage_error.clone(),
            can_activate: true,
            activation_block_reason: None,
        }
    }

    pub(crate) fn activation_block_reason(
        &self,
        snapshot: Option<&SnapshotBlob>,
    ) -> Option<String> {
        if self.identity.email == UNKNOWN_EMAIL {
            return Some("identity placeholder; sign in and save this account again".to_owned());
        }
        if self.consecutive_auth_failures >= 2 {
            return Some(
                "HTTP 401 authentication failures; sign in and save this account again".to_owned(),
            );
        }
        if self.provider == AiProvider::Claude {
            let has_oauth_account = snapshot
                .and_then(|snapshot| {
                    snapshot
                        .files
                        .iter()
                        .find(|file| file.name == "claude_config.json")
                })
                .and_then(|file| {
                    base64::engine::general_purpose::STANDARD
                        .decode(&file.bytes_base64)
                        .ok()
                })
                .and_then(|bytes| serde_json::from_slice::<serde_json::Value>(&bytes).ok())
                .and_then(|value| value.get("oauthAccount").cloned())
                .is_some_and(|value| value.is_object());
            if !has_oauth_account {
                return Some(
                    "Claude snapshot is missing oauthAccount; save this account again".to_owned(),
                );
            }
        }
        self.cached_usage_error
            .as_deref()
            .filter(|error| error.starts_with(LOGIN_REQUIRED_ERROR_PREFIX))
            .map(|_| {
                "saved credential is no longer valid; sign in and save this account again"
                    .to_owned()
            })
    }

    pub(crate) fn requires_login(&self) -> bool {
        self.cached_usage_error
            .as_deref()
            .is_some_and(|error| error.starts_with(LOGIN_REQUIRED_ERROR_PREFIX))
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct ProviderIndex {
    schema_version: u32,
    #[serde(default)]
    accounts: Vec<ProviderSavedAccount>,
}

impl Default for ProviderIndex {
    fn default() -> Self {
        Self {
            schema_version: PROVIDER_INDEX_SCHEMA_VERSION,
            accounts: Vec::new(),
        }
    }
}

pub(crate) struct ProviderAccountStore<S> {
    index_path: PathBuf,
    secret_store: S,
}

impl<S> ProviderAccountStore<S>
where
    S: SecretStore,
{
    pub(crate) fn new(app_data_dir: &Path, secret_store: S) -> Self {
        Self {
            index_path: app_data_dir.join("providers").join("index.json"),
            secret_store,
        }
    }

    pub(crate) fn list(
        &self,
        environment: &EnvironmentKind,
        provider: Option<AiProvider>,
    ) -> Result<Vec<ProviderSavedAccount>> {
        let mut accounts = self
            .load_index()?
            .accounts
            .into_iter()
            .filter(|account| &account.environment == environment)
            .filter(|account| provider.is_none_or(|provider| account.provider == provider))
            .collect::<Vec<_>>();
        accounts.sort_by_key(|account| std::cmp::Reverse(account.updated_at));
        Ok(accounts)
    }

    pub(crate) fn get(
        &self,
        environment: &EnvironmentKind,
        account_id: Uuid,
    ) -> Result<Option<ProviderSavedAccount>> {
        Ok(self
            .list(environment, None)?
            .into_iter()
            .find(|account| account.id == account_id))
    }

    pub(crate) fn find_matching(
        &self,
        environment: &EnvironmentKind,
        provider: AiProvider,
        identity: &DisplayIdentity,
    ) -> Result<Option<ProviderSavedAccount>> {
        Ok(self
            .list(environment, Some(provider))?
            .into_iter()
            .find(|account| account.identity.matches(identity)))
    }

    pub(crate) fn save(
        &self,
        environment: &EnvironmentKind,
        provider: AiProvider,
        identity: &DisplayIdentity,
        snapshot: &SnapshotBlob,
    ) -> Result<(ProviderSavedAccount, bool)> {
        if provider == AiProvider::OpenAi {
            bail!("OpenAI snapshots must use the existing Codex repository")
        }
        let mut index = self.load_index()?;
        let now = OffsetDateTime::now_utc();
        let existing = index.accounts.iter().position(|account| {
            &account.environment == environment
                && account.provider == provider
                && account.identity.matches(identity)
        });
        let (record, created) = if let Some(position) = existing {
            let account = &mut index.accounts[position];
            account.identity = identity.clone();
            account.cached_usage_error = None;
            account.consecutive_auth_failures = 0;
            account.updated_at = now;
            (account.clone(), false)
        } else {
            let id = Uuid::new_v4();
            let record = ProviderSavedAccount {
                id,
                provider,
                environment: environment.clone(),
                identity: identity.clone(),
                secret_key: format!("provider:{}:{id}", provider.slug()),
                created_at: now,
                updated_at: now,
                last_activated_at: None,
                custom_label: None,
                cached_usage: None,
                cached_usage_error: None,
                consecutive_auth_failures: 0,
            };
            index.accounts.push(record.clone());
            (record, true)
        };
        let bytes = serde_json::to_vec(snapshot).context("failed to encode provider snapshot")?;
        self.save_snapshot_and_index(&record.secret_key, &bytes, &index)?;
        Ok((record, created))
    }

    pub(crate) fn save_for_record(
        &self,
        environment: &EnvironmentKind,
        account_id: Uuid,
        identity: &DisplayIdentity,
        snapshot: &SnapshotBlob,
    ) -> Result<ProviderSavedAccount> {
        let mut index = self.load_index()?;
        let account = index
            .accounts
            .iter_mut()
            .find(|account| account.id == account_id && &account.environment == environment)
            .ok_or_else(|| anyhow!("provider account {account_id} not found"))?;
        account.identity = identity.clone();
        account.cached_usage_error = None;
        account.consecutive_auth_failures = 0;
        account.updated_at = OffsetDateTime::now_utc();
        let record = account.clone();
        let bytes = serde_json::to_vec(snapshot).context("failed to encode provider snapshot")?;
        self.save_snapshot_and_index(&record.secret_key, &bytes, &index)?;
        Ok(record)
    }

    /// Persist a token rotation without rewriting unrelated account metadata.
    /// Callers hold AuthLock then OperationLock; the ID and preimage check also
    /// reject stale completions rather than creating or overwriting an account.
    pub(crate) fn save_rotated_snapshot(
        &self,
        environment: &EnvironmentKind,
        account_id: Uuid,
        expected: &SnapshotBlob,
        rotated: &SnapshotBlob,
    ) -> Result<()> {
        let (record, current) = self.load_snapshot(environment, account_id)?;
        if &current != expected {
            bail!("provider snapshot changed during token refresh");
        }
        let bytes =
            serde_json::to_vec(rotated).context("failed to encode rotated provider snapshot")?;
        // A successful exchange consumes its old refresh token. Never roll the
        // new pair back just because an index timestamp cannot be published.
        self.secret_store.save(&record.secret_key, &bytes)
    }

    fn save_snapshot_and_index(
        &self,
        key: &str,
        bytes: &[u8],
        index: &ProviderIndex,
    ) -> Result<()> {
        let previous = self.secret_store.load(key)?;
        // The production store encrypts this preimage like every other snapshot.
        // Keep it if rollback fails, rather than losing the only original login.
        let undo_key = format!("provider-save-undo:{}", Uuid::new_v4());
        if let Some(previous) = &previous {
            self.secret_store
                .save(&undo_key, previous)
                .context("failed to retain provider snapshot before save")?;
        }
        let result = self
            .secret_store
            .save(key, bytes)
            .and_then(|()| self.save_index(index));
        if let Err(error) = result {
            let rollback = match &previous {
                Some(previous) => self.secret_store.save(key, previous),
                None => self.secret_store.delete(key),
            };
            if let Err(rollback) = rollback {
                return Err(error.context(format!(
                    "provider snapshot rollback failed: {rollback:#}; recovery secret key: {}",
                    if previous.is_some() { &undo_key } else { key }
                )));
            }
            let _ = self.secret_store.delete(&undo_key);
            return Err(error.context("provider snapshot was rolled back"));
        }
        let _ = self.secret_store.delete(&undo_key);
        Ok(())
    }

    pub(crate) fn load_snapshot(
        &self,
        environment: &EnvironmentKind,
        account_id: Uuid,
    ) -> Result<(ProviderSavedAccount, SnapshotBlob)> {
        let account = self
            .get(environment, account_id)?
            .ok_or_else(|| anyhow!("provider account {account_id} not found"))?;
        let bytes = self
            .secret_store
            .load(&account.secret_key)?
            .ok_or_else(|| {
                anyhow!(
                    "provider snapshot data missing for {}",
                    account.identity.email
                )
            })?;
        let snapshot =
            serde_json::from_slice(&bytes).context("failed to decode provider snapshot")?;
        Ok((account, snapshot))
    }

    pub(crate) fn remove(
        &self,
        environment: &EnvironmentKind,
        account_id: Uuid,
    ) -> Result<ProviderSavedAccount> {
        let mut index = self.load_index()?;
        let position = index
            .accounts
            .iter()
            .position(|account| account.id == account_id && &account.environment == environment)
            .ok_or_else(|| anyhow!("provider account {account_id} not found"))?;
        let record = index.accounts.remove(position);
        // Commit metadata before deleting the secret so an index-write failure
        // leaves the saved snapshot available to the existing account record.
        self.save_index(&index)?;
        self.secret_store.delete(&record.secret_key)?;
        Ok(record)
    }

    pub(crate) fn set_label(
        &self,
        environment: &EnvironmentKind,
        account_id: Uuid,
        label: Option<String>,
    ) -> Result<ProviderSavedAccount> {
        let mut index = self.load_index()?;
        let account = index
            .accounts
            .iter_mut()
            .find(|account| account.id == account_id && &account.environment == environment)
            .ok_or_else(|| anyhow!("provider account {account_id} not found"))?;
        account.custom_label = label
            .map(|label| label.trim().to_owned())
            .filter(|label| !label.is_empty());
        account.updated_at = OffsetDateTime::now_utc();
        let record = account.clone();
        self.save_index(&index)?;
        Ok(record)
    }

    pub(crate) fn mark_activated(
        &self,
        environment: &EnvironmentKind,
        account_id: Uuid,
        identity: &DisplayIdentity,
    ) -> Result<ProviderSavedAccount> {
        let mut index = self.load_index()?;
        let account = index
            .accounts
            .iter_mut()
            .find(|account| account.id == account_id && &account.environment == environment)
            .ok_or_else(|| anyhow!("provider account {account_id} not found"))?;
        account.identity = identity.clone();
        let now = OffsetDateTime::now_utc();
        account.updated_at = now;
        account.last_activated_at = Some(now);
        let result = account.clone();
        self.save_index(&index)?;
        Ok(result)
    }

    pub(crate) fn record_usage(
        &self,
        environment: &EnvironmentKind,
        account_id: Uuid,
        usage: ProviderUsageView,
    ) -> Result<ProviderSavedAccount> {
        let mut index = self.load_index()?;
        let account = index
            .accounts
            .iter_mut()
            .find(|account| account.id == account_id && &account.environment == environment)
            .ok_or_else(|| anyhow!("provider account {account_id} not found"))?;
        if usage.status == ProviderUsageStatus::Ok {
            if let Some(plan_label) = usage.plan_label.clone() {
                account.identity.plan_label = Some(plan_label);
            }
            account.cached_usage = Some(usage);
            account.cached_usage_error = None;
            account.consecutive_auth_failures = 0;
        }
        account.updated_at = OffsetDateTime::now_utc();
        let result = account.clone();
        self.save_index(&index)?;
        Ok(result)
    }

    pub(crate) fn record_usage_error(
        &self,
        environment: &EnvironmentKind,
        account_id: Uuid,
        error: String,
    ) -> Result<ProviderSavedAccount> {
        let mut index = self.load_index()?;
        let account = index
            .accounts
            .iter_mut()
            .find(|account| account.id == account_id && &account.environment == environment)
            .ok_or_else(|| anyhow!("provider account {account_id} not found"))?;
        account.cached_usage_error = Some(error);
        if is_auth_failure(account.cached_usage_error.as_deref().unwrap_or_default()) {
            account.consecutive_auth_failures = account.consecutive_auth_failures.saturating_add(1);
        } else {
            account.consecutive_auth_failures = 0;
        }
        account.updated_at = OffsetDateTime::now_utc();
        let result = account.clone();
        self.save_index(&index)?;
        Ok(result)
    }

    fn load_index(&self) -> Result<ProviderIndex> {
        // Try the canonical path first. When it is absent (e.g., in the brief
        // window between replace_file_with_recovery renaming it to the backup
        // slot and placing the new canonical file), fall back to the newest
        // backup written by replace_file_with_recovery so readers concurrent
        // with a writer never see an empty account list.
        if let Some(index) = self.try_read_index(&self.index_path)? {
            return Ok(index);
        }
        let mut backups = list_recovery_files(&self.index_path, None)?
            .into_iter()
            .filter(|file| file.kind == RecoveryFileKind::Backup)
            .collect::<Vec<_>>();
        backups.sort_by_key(|file| std::cmp::Reverse(file.modified));
        // The writer may have completed while recovery files were enumerated.
        if let Some(index) = self.try_read_index(&self.index_path)? {
            return Ok(index);
        }
        for backup in backups {
            if let Some(index) = self.try_read_index(&backup.path)? {
                return Ok(index);
            }
        }
        Ok(self.try_read_index(&self.index_path)?.unwrap_or_default())
    }

    fn try_read_index(&self, path: &std::path::Path) -> Result<Option<ProviderIndex>> {
        match fs::read(path) {
            Ok(bytes) => {
                let index: ProviderIndex = serde_json::from_slice(&bytes).with_context(|| {
                    format!("failed to parse provider index at {}", path.display())
                })?;
                if index.schema_version != PROVIDER_INDEX_SCHEMA_VERSION {
                    bail!(
                        "unsupported provider index schema {} at {}",
                        index.schema_version,
                        path.display()
                    )
                }
                Ok(Some(index))
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(error).with_context(|| format!("failed to read {}", path.display())),
        }
    }

    fn save_index(&self, index: &ProviderIndex) -> Result<()> {
        let bytes = serde_json::to_vec_pretty(index).context("failed to encode provider index")?;
        replace_file_with_recovery(&self.index_path, None, |temp_path| {
            fs::write(temp_path, &bytes)
                .with_context(|| format!("failed to write {}", temp_path.display()))?;
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                fs::set_permissions(temp_path, fs::Permissions::from_mode(0o600))
                    .with_context(|| format!("failed to protect {}", temp_path.display()))?;
            }
            Ok(())
        })
    }
}

fn is_auth_failure(error: &str) -> bool {
    // Only count errors that indicate the credential is permanently invalid
    // (refresh token rejected or explicit login_required).  A plain HTTP 401
    // on a usage fetch merely means the access token expired and can be healed
    // by a token refresh; treating it as a hard auth failure would accumulate
    // two consecutive 401 poll results and permanently block the account even
    // though a valid refresh token is still present.
    error.starts_with(LOGIN_REQUIRED_ERROR_PREFIX) || error.contains("refresh token rejected")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{SNAPSHOT_SCHEMA_VERSION, SnapshotFile};
    use crate::secrets::test_support::MemorySecretStore;

    fn identity(email: &str, subject: &str) -> DisplayIdentity {
        DisplayIdentity {
            email: email.to_owned(),
            subject: Some(subject.to_owned()),
            name: None,
            plan_label: None,
        }
    }

    #[test]
    fn review_fix_failed_identity_adoption_restores_original_snapshot() {
        use std::os::unix::fs::PermissionsExt;
        let temp = tempfile::tempdir().unwrap();
        let store = ProviderAccountStore::new(temp.path(), MemorySecretStore::default());
        let original = SnapshotBlob {
            schema_version: 1,
            files: vec![],
        };
        let replacement = SnapshotBlob {
            schema_version: 1,
            files: vec![SnapshotFile {
                name: "auth".into(),
                bytes_base64: "e30=".into(),
            }],
        };
        let (record, _) = store
            .save(
                &EnvironmentKind::Macos,
                AiProvider::Claude,
                &identity("unknown", "unknown"),
                &original,
            )
            .unwrap();
        let parent = store.index_path.parent().unwrap();
        fs::set_permissions(parent, fs::Permissions::from_mode(0o500)).unwrap();
        let result = store.save_for_record(
            &EnvironmentKind::Macos,
            record.id,
            &identity("known@example.com", "known"),
            &replacement,
        );
        fs::set_permissions(parent, fs::Permissions::from_mode(0o700)).unwrap();
        assert!(result.is_err());
        let (loaded, snapshot) = store
            .load_snapshot(&EnvironmentKind::Macos, record.id)
            .unwrap();
        assert_eq!(loaded.identity, record.identity);
        assert_eq!(snapshot, original);
    }

    #[test]
    fn review_fix_failed_new_save_removes_unpublished_secret() {
        use std::os::unix::fs::PermissionsExt;
        #[derive(Default)]
        struct TrackingStore(std::sync::Mutex<std::collections::HashMap<String, Vec<u8>>>);
        impl SecretStore for TrackingStore {
            fn save(&self, key: &str, value: &[u8]) -> Result<()> {
                self.0.lock().unwrap().insert(key.into(), value.into());
                Ok(())
            }
            fn load(&self, key: &str) -> Result<Option<Vec<u8>>> {
                Ok(self.0.lock().unwrap().get(key).cloned())
            }
            fn delete(&self, key: &str) -> Result<()> {
                self.0.lock().unwrap().remove(key);
                Ok(())
            }
        }
        let temp = tempfile::tempdir().unwrap();
        let store = ProviderAccountStore::new(temp.path(), TrackingStore::default());
        let parent = store.index_path.parent().unwrap();
        fs::create_dir_all(parent).unwrap();
        fs::set_permissions(parent, fs::Permissions::from_mode(0o500)).unwrap();
        let result = store.save(
            &EnvironmentKind::Macos,
            AiProvider::Cursor,
            &identity("new@example.com", "new"),
            &SnapshotBlob {
                schema_version: 1,
                files: vec![],
            },
        );
        fs::set_permissions(parent, fs::Permissions::from_mode(0o700)).unwrap();
        assert!(result.is_err());
        assert!(store.secret_store.0.lock().unwrap().is_empty());
        assert!(
            store
                .list(&EnvironmentKind::Macos, None)
                .unwrap()
                .is_empty()
        );
    }

    #[test]
    fn review_fix_failed_rollback_retains_original_recovery_secret() {
        use std::os::unix::fs::PermissionsExt;
        #[derive(Default)]
        struct FailingRollbackStore {
            values: std::sync::Mutex<std::collections::HashMap<String, Vec<u8>>>,
            failure: std::sync::Mutex<Option<(String, Vec<u8>)>>,
        }
        impl SecretStore for FailingRollbackStore {
            fn save(&self, key: &str, value: &[u8]) -> Result<()> {
                if self
                    .failure
                    .lock()
                    .unwrap()
                    .as_ref()
                    .is_some_and(|(k, v)| k == key && v == value)
                {
                    anyhow::bail!("injected rollback failure");
                }
                self.values.lock().unwrap().insert(key.into(), value.into());
                Ok(())
            }
            fn load(&self, key: &str) -> Result<Option<Vec<u8>>> {
                Ok(self.values.lock().unwrap().get(key).cloned())
            }
            fn delete(&self, key: &str) -> Result<()> {
                self.values.lock().unwrap().remove(key);
                Ok(())
            }
        }
        let temp = tempfile::tempdir().unwrap();
        let store = ProviderAccountStore::new(temp.path(), FailingRollbackStore::default());
        let original = SnapshotBlob {
            schema_version: 1,
            files: vec![],
        };
        let replacement = SnapshotBlob {
            schema_version: 1,
            files: vec![SnapshotFile {
                name: "auth".into(),
                bytes_base64: "e30=".into(),
            }],
        };
        let identity = identity("saved@example.com", "saved");
        let (record, _) = store
            .save(
                &EnvironmentKind::Macos,
                AiProvider::Cursor,
                &identity,
                &original,
            )
            .unwrap();
        let original_bytes = serde_json::to_vec(&original).unwrap();
        *store.secret_store.failure.lock().unwrap() =
            Some((record.secret_key.clone(), original_bytes.clone()));
        let parent = store.index_path.parent().unwrap();
        fs::set_permissions(parent, fs::Permissions::from_mode(0o500)).unwrap();
        let result = store.save(
            &EnvironmentKind::Macos,
            AiProvider::Cursor,
            &identity,
            &replacement,
        );
        fs::set_permissions(parent, fs::Permissions::from_mode(0o700)).unwrap();
        let error = format!("{:#}", result.unwrap_err());
        let values = store.secret_store.values.lock().unwrap();
        let (key, recovered) = values
            .iter()
            .find(|(key, _)| key.starts_with("provider-save-undo:"))
            .unwrap();
        assert_eq!(recovered, &original_bytes);
        assert!(error.contains(key));
        assert!(error.contains("rollback failed"));
    }

    #[test]
    fn same_email_is_scoped_by_provider() {
        let temp = tempfile::tempdir().expect("tempdir");
        let store = ProviderAccountStore::new(temp.path(), MemorySecretStore::default());
        let snapshot = SnapshotBlob {
            schema_version: SNAPSHOT_SCHEMA_VERSION,
            files: vec![SnapshotFile {
                name: "auth".to_owned(),
                bytes_base64: "e30=".to_owned(),
            }],
        };
        let claude = store
            .save(
                &EnvironmentKind::Macos,
                AiProvider::Claude,
                &identity("same@example.com", "claude-1"),
                &snapshot,
            )
            .expect("save claude")
            .0;
        let cursor = store
            .save(
                &EnvironmentKind::Macos,
                AiProvider::Cursor,
                &identity("same@example.com", "cursor-1"),
                &snapshot,
            )
            .expect("save cursor")
            .0;
        assert_ne!(claude.id, cursor.id);
        assert_eq!(store.list(&EnvironmentKind::Macos, None).unwrap().len(), 2);
    }

    #[test]
    fn save_existing_clears_cached_usage_error() {
        let temp = tempfile::tempdir().expect("tempdir");
        let store = ProviderAccountStore::new(temp.path(), MemorySecretStore::default());
        let snapshot = SnapshotBlob {
            schema_version: SNAPSHOT_SCHEMA_VERSION,
            files: vec![SnapshotFile {
                name: "auth".to_owned(),
                bytes_base64: "e30=".to_owned(),
            }],
        };
        let record = store
            .save(
                &EnvironmentKind::Macos,
                AiProvider::Claude,
                &identity("user@example.com", "claude-1"),
                &snapshot,
            )
            .expect("save")
            .0;
        store
            .record_usage_error(
                &EnvironmentKind::Macos,
                record.id,
                format!("{LOGIN_REQUIRED_ERROR_PREFIX}: test"),
            )
            .expect("record error");
        let quarantined = store
            .get(&EnvironmentKind::Macos, record.id)
            .expect("get")
            .expect("record");
        assert!(quarantined.requires_login());

        let (saved, created) = store
            .save(
                &EnvironmentKind::Macos,
                AiProvider::Claude,
                &identity("user@example.com", "claude-1"),
                &snapshot,
            )
            .expect("re-save");
        assert!(!created);
        assert_eq!(saved.id, record.id);
        assert!(!saved.requires_login());
        assert!(saved.cached_usage_error.is_none());
    }

    #[test]
    fn save_for_record_rewrites_identity_and_snapshot() {
        let temp = tempfile::tempdir().expect("tempdir");
        let store = ProviderAccountStore::new(temp.path(), MemorySecretStore::default());
        let snapshot = SnapshotBlob {
            schema_version: SNAPSHOT_SCHEMA_VERSION,
            files: vec![SnapshotFile {
                name: "auth".to_owned(),
                bytes_base64: "e30=".to_owned(),
            }],
        };
        let record = store
            .save(
                &EnvironmentKind::Macos,
                AiProvider::Claude,
                &identity("old@example.com", "claude-1"),
                &snapshot,
            )
            .expect("save")
            .0;
        store
            .record_usage_error(
                &EnvironmentKind::Macos,
                record.id,
                format!("{LOGIN_REQUIRED_ERROR_PREFIX}: test"),
            )
            .expect("record error");

        let new_snapshot = SnapshotBlob {
            schema_version: SNAPSHOT_SCHEMA_VERSION,
            files: vec![SnapshotFile {
                name: "auth".to_owned(),
                bytes_base64: "eyJ4IjoxfQ==".to_owned(),
            }],
        };
        let saved = store
            .save_for_record(
                &EnvironmentKind::Macos,
                record.id,
                &identity("new@example.com", "claude-2"),
                &new_snapshot,
            )
            .expect("save_for_record");

        assert_eq!(saved.id, record.id);
        assert_eq!(saved.identity.email, "new@example.com");
        assert!(saved.cached_usage_error.is_none());
        let (_record, loaded) = store
            .load_snapshot(&EnvironmentKind::Macos, record.id)
            .expect("load");
        assert_eq!(loaded, new_snapshot);
        assert_eq!(store.list(&EnvironmentKind::Macos, None).unwrap().len(), 1);
    }

    #[test]
    fn remove_deletes_record_and_secret() {
        let temp = tempfile::tempdir().expect("tempdir");
        let store = ProviderAccountStore::new(temp.path(), MemorySecretStore::default());
        let snapshot = SnapshotBlob {
            schema_version: SNAPSHOT_SCHEMA_VERSION,
            files: vec![SnapshotFile {
                name: "auth".to_owned(),
                bytes_base64: "e30=".to_owned(),
            }],
        };
        let record = store
            .save(
                &EnvironmentKind::Macos,
                AiProvider::Claude,
                &identity("user@example.com", "claude-1"),
                &snapshot,
            )
            .expect("save")
            .0;
        let removed = store
            .remove(&EnvironmentKind::Macos, record.id)
            .expect("remove");
        assert_eq!(removed.id, record.id);
        assert!(
            store
                .list(&EnvironmentKind::Macos, None)
                .unwrap()
                .is_empty()
        );
        assert!(
            store
                .load_snapshot(&EnvironmentKind::Macos, record.id)
                .is_err()
        );
        assert!(store.remove(&EnvironmentKind::Macos, record.id).is_err());
    }

    #[test]
    fn recovery_backup_is_read_when_canonical_is_absent() {
        let temp = tempfile::tempdir().expect("tempdir");
        let store = ProviderAccountStore::new(temp.path(), MemorySecretStore::default());
        let snapshot = SnapshotBlob {
            schema_version: 1,
            files: vec![],
        };
        let (record, _) = store
            .save(
                &EnvironmentKind::Macos,
                AiProvider::Cursor,
                &identity("user@example.com", "cursor-1"),
                &snapshot,
            )
            .expect("save");
        fs::rename(
            &store.index_path,
            store.index_path.with_file_name("index.json.bak-test"),
        )
        .expect("backup");
        assert_eq!(
            store.list(&EnvironmentKind::Macos, None).expect("list")[0].id,
            record.id
        );
    }

    #[cfg(unix)]
    #[test]
    fn failed_index_delete_preserves_secret() {
        use std::os::unix::fs::PermissionsExt;
        let temp = tempfile::tempdir().expect("tempdir");
        let store = ProviderAccountStore::new(temp.path(), MemorySecretStore::default());
        let snapshot = SnapshotBlob {
            schema_version: 1,
            files: vec![],
        };
        let (record, _) = store
            .save(
                &EnvironmentKind::Macos,
                AiProvider::Cursor,
                &identity("user@example.com", "cursor-1"),
                &snapshot,
            )
            .expect("save");
        let directory = store.index_path.parent().unwrap();
        let permissions = fs::metadata(directory).unwrap().permissions();
        fs::set_permissions(directory, fs::Permissions::from_mode(0o500)).expect("block writes");
        let result = store.remove(&EnvironmentKind::Macos, record.id);
        fs::set_permissions(directory, permissions).expect("restore permissions");
        assert!(result.is_err());
        assert!(
            store
                .secret_store
                .load(&record.secret_key)
                .expect("secret")
                .is_some()
        );
        assert!(
            store
                .get(&EnvironmentKind::Macos, record.id)
                .expect("get")
                .is_some()
        );
    }

    #[test]
    fn expired_access_token_does_not_quarantine_account() {
        let temp = tempfile::tempdir().expect("tempdir");
        let store = ProviderAccountStore::new(temp.path(), MemorySecretStore::default());
        let snapshot = SnapshotBlob {
            schema_version: 1,
            files: vec![],
        };
        let (record, _) = store
            .save(
                &EnvironmentKind::Macos,
                AiProvider::Cursor,
                &identity("user@example.com", "cursor-1"),
                &snapshot,
            )
            .expect("save");
        for _ in 0..2 {
            store
                .record_usage_error(&EnvironmentKind::Macos, record.id, "HTTP 401".to_owned())
                .expect("usage error");
        }
        let record = store
            .get(&EnvironmentKind::Macos, record.id)
            .unwrap()
            .unwrap();
        assert_eq!(record.consecutive_auth_failures, 0);
        assert!(record.activation_block_reason(Some(&snapshot)).is_none());
    }

    #[test]
    fn set_label_trims_and_clears() {
        let temp = tempfile::tempdir().expect("tempdir");
        let store = ProviderAccountStore::new(temp.path(), MemorySecretStore::default());
        let snapshot = SnapshotBlob {
            schema_version: SNAPSHOT_SCHEMA_VERSION,
            files: vec![SnapshotFile {
                name: "auth".to_owned(),
                bytes_base64: "e30=".to_owned(),
            }],
        };
        let record = store
            .save(
                &EnvironmentKind::Macos,
                AiProvider::Claude,
                &identity("user@example.com", "claude-1"),
                &snapshot,
            )
            .expect("save")
            .0;
        let labeled = store
            .set_label(
                &EnvironmentKind::Macos,
                record.id,
                Some("  Work  ".to_owned()),
            )
            .expect("set label");
        assert_eq!(labeled.custom_label.as_deref(), Some("Work"));
        assert_eq!(labeled.view(false).custom_label.as_deref(), Some("Work"));
        let cleared = store
            .set_label(&EnvironmentKind::Macos, record.id, Some("   ".to_owned()))
            .expect("clear label");
        assert!(cleared.custom_label.is_none());
    }
}
