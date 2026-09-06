use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, anyhow, bail};
use serde::{Deserialize, Serialize};
use time::OffsetDateTime;
use uuid::Uuid;

use crate::file_store::replace_file_with_recovery;
use crate::model::{
    AiProvider, DisplayIdentity, EnvironmentKind, ProviderAccountView, ProviderUsageStatus,
    ProviderUsageView, SnapshotBlob,
};
use crate::secrets::SecretStore;

const PROVIDER_INDEX_SCHEMA_VERSION: u32 = 1;

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
    #[serde(default)]
    pub cached_usage: Option<ProviderUsageView>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cached_usage_error: Option<String>,
}

impl ProviderSavedAccount {
    pub(crate) fn view(&self, is_active: bool) -> ProviderAccountView {
        ProviderAccountView {
            id: self.id,
            provider: self.provider,
            email: self.identity.email.clone(),
            subject: self.identity.subject.clone(),
            name: self.identity.name.clone(),
            custom_label: None,
            plan_label: self.identity.plan_label.clone(),
            environment: self.environment.clone(),
            is_active,
            created_at: self.created_at,
            updated_at: self.updated_at,
            last_activated_at: self.last_activated_at,
            usage: self.cached_usage.clone(),
            usage_error: self.cached_usage_error.clone(),
        }
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
                cached_usage: None,
                cached_usage_error: None,
            };
            index.accounts.push(record.clone());
            (record, true)
        };
        let bytes = serde_json::to_vec(snapshot).context("failed to encode provider snapshot")?;
        self.secret_store.save(&record.secret_key, &bytes)?;
        self.save_index(&index)?;
        Ok((record, created))
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
        account.updated_at = OffsetDateTime::now_utc();
        let result = account.clone();
        self.save_index(&index)?;
        Ok(result)
    }

    fn load_index(&self) -> Result<ProviderIndex> {
        match fs::read(&self.index_path) {
            Ok(bytes) => {
                let index: ProviderIndex = serde_json::from_slice(&bytes).with_context(|| {
                    format!(
                        "failed to parse provider index at {}",
                        self.index_path.display()
                    )
                })?;
                if index.schema_version != PROVIDER_INDEX_SCHEMA_VERSION {
                    bail!(
                        "unsupported provider index schema {} at {}",
                        index.schema_version,
                        self.index_path.display()
                    )
                }
                Ok(index)
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                Ok(ProviderIndex::default())
            }
            Err(error) => {
                Err(error).with_context(|| format!("failed to read {}", self.index_path.display()))
            }
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
}
