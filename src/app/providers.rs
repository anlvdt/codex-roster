use std::collections::HashMap;

use anyhow::{Context, Result, bail};
use uuid::Uuid;

use crate::model::{
    AccountUsageView, AccountView, AiProvider, ProviderAccountView, ProviderActivateOutput,
    ProviderListOutput, ProviderSaveOutput, ProviderStateView, ProviderStatusOutput,
    ProviderUsageOutput, ProviderUsageStatus, ProviderUsageView, ProviderUsageWindowView,
    SaveAction, UsageFidelity,
};
use crate::operation_lock::{AuthLock, OperationLock};
use crate::provider::adapter;
use crate::provider_store::{ProviderAccountStore, ProviderSavedAccount};
use crate::secrets::{LocalSecretStore, SecretStore};

use super::App;

impl<S> App<S>
where
    S: SecretStore,
{
    pub fn providers_status(&self) -> Result<ProviderStatusOutput> {
        let store = self.provider_store();
        let openai_accounts = self.repository.list_accounts(&self.env.kind)?;
        let mut providers = Vec::with_capacity(AiProvider::ALL.len());
        for provider in AiProvider::ALL {
            let adapter = adapter(provider);
            let (live, live_error) = match adapter.try_read_live_auth(&self.env) {
                Ok(live) => (live, None),
                Err(error) => (None, Some(error.to_string())),
            };
            let (saved_accounts, current_account_saved_id) = if provider == AiProvider::OpenAi {
                let accounts = openai_accounts
                    .iter()
                    .filter(|account| account.provider == AiProvider::OpenAi)
                    .collect::<Vec<_>>();
                let active_id = live.as_ref().and_then(|bundle| {
                    accounts
                        .iter()
                        .find(|account| {
                            crate::model::DisplayIdentity {
                                email: account.email.clone(),
                                subject: account.subject.clone(),
                                name: account.name.clone(),
                                plan_label: account.plan_label.clone(),
                            }
                            .matches(&bundle.identity)
                        })
                        .map(|account| account.id)
                });
                (accounts.len(), active_id)
            } else {
                let accounts = store.list(&self.env.kind, Some(provider))?;
                let active_id = live.as_ref().and_then(|bundle| {
                    accounts
                        .iter()
                        .find(|account| account.identity.matches(&bundle.identity))
                        .map(|account| account.id)
                });
                (accounts.len(), active_id)
            };
            providers.push(ProviderStateView {
                provider,
                available: live.is_some(),
                capabilities: adapter.capabilities().to_vec(),
                identity: live.map(|bundle| bundle.identity),
                saved_accounts,
                current_account_saved_id,
                usage: None,
                usage_error: live_error,
            });
        }
        Ok(ProviderStatusOutput {
            environment: self.env.kind.clone(),
            providers,
        })
    }

    pub fn provider_list(&self, provider: Option<AiProvider>) -> Result<ProviderListOutput> {
        let mut accounts = Vec::new();
        if provider.is_none_or(|provider| provider == AiProvider::OpenAi) {
            let live = adapter(AiProvider::OpenAi).try_read_live_auth(&self.env)?;
            for account in self
                .repository
                .list_accounts(&self.env.kind)?
                .into_iter()
                .filter(|account| account.provider == AiProvider::OpenAi)
            {
                let is_active = live.as_ref().is_some_and(|bundle| {
                    saved_openai_identity(&account).matches(&bundle.identity)
                });
                accounts.push(openai_account_view(account_view_from_saved(
                    account, is_active,
                )));
            }
        }

        let store = self.provider_store();
        let external = store.list(
            &self.env.kind,
            provider.filter(|value| *value != AiProvider::OpenAi),
        )?;
        let mut live_identities = HashMap::new();
        for account in external {
            if provider == Some(AiProvider::OpenAi) {
                break;
            }
            let live_identity = live_identities.entry(account.provider).or_insert_with(|| {
                adapter(account.provider)
                    .try_read_live_auth(&self.env)
                    .ok()
                    .flatten()
                    .map(|bundle| bundle.identity)
            });
            let is_active = live_identity
                .as_ref()
                .is_some_and(|identity| account.identity.matches(identity));
            accounts.push(account.view(is_active));
        }
        accounts.sort_by_key(|account| std::cmp::Reverse(account.updated_at));
        Ok(ProviderListOutput {
            environment: self.env.kind.clone(),
            provider,
            accounts,
        })
    }

    pub fn provider_save_current(&self, provider: AiProvider) -> Result<ProviderSaveOutput> {
        if provider == AiProvider::OpenAi {
            let output = self.save_current()?;
            return Ok(ProviderSaveOutput {
                account: openai_account_view(output.account),
                action: output.action,
            });
        }
        let live = adapter(provider)
            .read_live_auth(&self.env)
            .with_context(|| format!("no live {provider} authentication found"))?;
        let _operation_lock = OperationLock::acquire(&self.env.app_data_dir)?;
        let store = self.provider_store();
        let (record, created) =
            store.save(&self.env.kind, provider, &live.identity, &live.snapshot)?;
        Ok(ProviderSaveOutput {
            account: record.view(true),
            action: if created {
                SaveAction::Created
            } else {
                SaveAction::Refreshed
            },
        })
    }

    pub fn provider_activate(&self, account_id: Uuid) -> Result<ProviderActivateOutput> {
        if let Some(account) = self.repository.get_account(&self.env.kind, account_id)?
            && account.provider == AiProvider::OpenAi
        {
            let output = self.activate(account_id)?;
            return Ok(ProviderActivateOutput {
                account: openai_account_view(output.account),
                previous_account_id: output.previous_account_id,
                requires_relaunch: adapter(AiProvider::OpenAi).requires_relaunch_after_switch(),
            });
        }

        let _auth_lock = AuthLock::acquire(&self.env.app_data_dir)?;
        let store = self.provider_store();
        let (target, snapshot) = store.load_snapshot(&self.env.kind, account_id)?;
        let provider = target.provider;
        let provider_adapter = adapter(provider);
        let snapshot_identity = provider_adapter.identity_from_snapshot(&snapshot)?;
        if !target.identity.matches(&snapshot_identity) {
            bail!(
                "saved {provider} snapshot identity does not match account {}",
                target.identity.email
            )
        }

        let previous_live = provider_adapter.try_read_live_auth(&self.env)?;
        let previous_account_id = previous_live
            .as_ref()
            .and_then(|bundle| {
                store
                    .find_matching(&self.env.kind, provider, &bundle.identity)
                    .ok()
                    .flatten()
            })
            .map(|account| account.id);
        if let Some(live) = &previous_live
            && !live.identity.matches(&target.identity)
        {
            let _operation_lock = OperationLock::acquire(&self.env.app_data_dir)?;
            store.save(&self.env.kind, provider, &live.identity, &live.snapshot)?;
        }

        if let Err(error) = provider_adapter.restore_snapshot(&self.env, &snapshot) {
            if let Some(previous) = &previous_live {
                let _ = provider_adapter.restore_snapshot(&self.env, &previous.snapshot);
            }
            return Err(error).context("failed to restore provider snapshot");
        }
        let verified = provider_adapter.read_live_auth(&self.env);
        let verified = match verified {
            Ok(bundle) if bundle.identity.matches(&target.identity) => bundle,
            Ok(bundle) => {
                if let Some(previous) = &previous_live {
                    let _ = provider_adapter.restore_snapshot(&self.env, &previous.snapshot);
                }
                bail!(
                    "{provider} restored a different identity (expected {}, got {})",
                    target.identity.email,
                    bundle.identity.email
                )
            }
            Err(error) => {
                if let Some(previous) = &previous_live {
                    let _ = provider_adapter.restore_snapshot(&self.env, &previous.snapshot);
                }
                return Err(error).context("provider restore could not be verified");
            }
        };
        let _operation_lock = OperationLock::acquire(&self.env.app_data_dir)?;
        let record = store.mark_activated(&self.env.kind, account_id, &verified.identity)?;
        Ok(ProviderActivateOutput {
            account: record.view(true),
            previous_account_id,
            requires_relaunch: provider_adapter.requires_relaunch_after_switch(),
        })
    }

    pub fn provider_usage(
        &self,
        provider: AiProvider,
        account_id: Option<Uuid>,
    ) -> Result<ProviderUsageOutput> {
        if provider == AiProvider::OpenAi {
            let output = self.usage(account_id)?;
            return Ok(ProviderUsageOutput {
                environment: output.environment,
                account: output.account,
                usage: legacy_usage_to_provider(output.usage),
            });
        }

        let store = self.provider_store();
        let (mut identity, mut snapshot, saved_record) = match account_id {
            Some(account_id) => {
                let (record, snapshot) = store.load_snapshot(&self.env.kind, account_id)?;
                if record.provider != provider {
                    bail!(
                        "account {account_id} belongs to {}, not {provider}",
                        record.provider
                    )
                }
                (record.identity.clone(), snapshot, Some(record))
            }
            None => {
                let live = adapter(provider).read_live_auth(&self.env)?;
                (live.identity, live.snapshot, None)
            }
        };
        let provider_adapter = adapter(provider);
        let mut fetched = provider_adapter.fetch_usage(&snapshot);
        if saved_record.is_none()
            && fetched
                .as_ref()
                .is_ok_and(|usage| should_retry_live_credentials(usage.status))
            && let Ok(refreshed) = provider_adapter.read_live_auth(&self.env)
            && refreshed.snapshot != snapshot
        {
            identity = refreshed.identity;
            snapshot = refreshed.snapshot;
            fetched = provider_adapter.fetch_usage(&snapshot);
        }
        let usage = match fetched {
            Ok(usage) if usage.status == ProviderUsageStatus::Ok => usage,
            Ok(usage) => stale_or_status(saved_record.as_ref(), usage),
            Err(error) => {
                if let Some(record) = &saved_record
                    && let Some(cached) = &record.cached_usage
                {
                    let mut stale = cached.clone();
                    stale.status = ProviderUsageStatus::Stale;
                    stale.detail = Some(error.to_string());
                    stale
                } else {
                    return Err(error);
                }
            }
        };

        if let Some(record) = &saved_record {
            let _operation_lock = OperationLock::acquire(&self.env.app_data_dir)?;
            if usage.status == ProviderUsageStatus::Ok {
                store.record_usage(&self.env.kind, record.id, usage.clone())?;
            } else if let Some(detail) = usage.detail.clone() {
                store.record_usage_error(&self.env.kind, record.id, detail)?;
            }
        }
        Ok(ProviderUsageOutput {
            environment: self.env.kind.clone(),
            account: identity,
            usage,
        })
    }

    fn provider_store(&self) -> ProviderAccountStore<LocalSecretStore> {
        ProviderAccountStore::new(
            &self.env.app_data_dir,
            LocalSecretStore::new(&self.env.app_data_dir.join("providers").join("snapshots")),
        )
    }
}

fn should_retry_live_credentials(status: ProviderUsageStatus) -> bool {
    matches!(
        status,
        ProviderUsageStatus::CredentialExpired | ProviderUsageStatus::AccessDenied
    )
}

fn stale_or_status(
    saved_record: Option<&ProviderSavedAccount>,
    status_usage: ProviderUsageView,
) -> ProviderUsageView {
    if let Some(cached) = saved_record.and_then(|record| record.cached_usage.as_ref()) {
        let mut stale = cached.clone();
        stale.status = ProviderUsageStatus::Stale;
        stale.detail = status_usage.detail;
        return stale;
    }
    status_usage
}

fn saved_openai_identity(
    account: &crate::model::SavedAccountMetadata,
) -> crate::model::DisplayIdentity {
    crate::model::DisplayIdentity {
        email: account.email.clone(),
        subject: account.subject.clone(),
        name: account.name.clone(),
        plan_label: account.plan_label.clone(),
    }
}

fn account_view_from_saved(
    account: crate::model::SavedAccountMetadata,
    is_active: bool,
) -> AccountView {
    AccountView {
        id: account.id,
        provider: account.provider,
        email: account.email,
        subject: account.subject,
        name: account.name,
        custom_label: account.custom_label,
        plan_label: account.plan_label,
        environment: account.environment,
        is_active,
        created_at: account.created_at,
        updated_at: account.updated_at,
        last_activated_at: account.last_activated_at,
        archived: account.archived,
        usage: account.cached_usage,
        usage_error: account.cached_usage_error,
    }
}

fn openai_account_view(account: AccountView) -> ProviderAccountView {
    ProviderAccountView {
        id: account.id,
        provider: account.provider,
        email: account.email,
        subject: account.subject,
        name: account.name,
        custom_label: account.custom_label,
        plan_label: account.plan_label,
        environment: account.environment,
        is_active: account.is_active,
        created_at: account.created_at,
        updated_at: account.updated_at,
        last_activated_at: account.last_activated_at,
        usage: account.usage.map(legacy_usage_to_provider),
        usage_error: account.usage_error,
    }
}

fn legacy_usage_to_provider(usage: AccountUsageView) -> ProviderUsageView {
    let mut windows = Vec::new();
    if let Some(window) = usage.five_hour {
        windows.push(ProviderUsageWindowView {
            key: "five_hour".to_owned(),
            label: "5 hour".to_owned(),
            used_percent: Some(window.used_percent),
            remaining_percent: Some(window.remaining_percent),
            reset_at: Some(window.reset_at),
            used: None,
            limit: None,
            unit: None,
        });
    }
    if let Some(window) = usage.weekly {
        windows.push(ProviderUsageWindowView {
            key: "weekly".to_owned(),
            label: "Weekly".to_owned(),
            used_percent: Some(window.used_percent),
            remaining_percent: Some(window.remaining_percent),
            reset_at: Some(window.reset_at),
            used: None,
            limit: None,
            unit: None,
        });
    }
    ProviderUsageView {
        provider: AiProvider::OpenAi,
        fetched_at: usage.fetched_at,
        status: ProviderUsageStatus::Ok,
        fidelity: UsageFidelity::Official,
        headline_window: windows.first().map(|window| window.key.clone()),
        windows,
        plan_label: usage.plan_label,
        detail: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{DisplayIdentity, EnvironmentKind};

    fn usage(status: ProviderUsageStatus, detail: Option<&str>) -> ProviderUsageView {
        ProviderUsageView {
            provider: AiProvider::Claude,
            fetched_at: time::OffsetDateTime::UNIX_EPOCH,
            status,
            fidelity: UsageFidelity::Official,
            headline_window: None,
            windows: Vec::new(),
            plan_label: None,
            detail: detail.map(str::to_owned),
        }
    }

    #[test]
    fn credential_retry_is_limited_to_live_auth_failures() {
        assert!(should_retry_live_credentials(
            ProviderUsageStatus::CredentialExpired
        ));
        assert!(should_retry_live_credentials(
            ProviderUsageStatus::AccessDenied
        ));
        assert!(!should_retry_live_credentials(
            ProviderUsageStatus::RateLimited
        ));
        assert!(!should_retry_live_credentials(ProviderUsageStatus::Error));
    }

    #[test]
    fn cached_usage_is_preserved_as_stale_on_provider_status_error() {
        let cached = usage(ProviderUsageStatus::Ok, None);
        let record = ProviderSavedAccount {
            id: Uuid::nil(),
            provider: AiProvider::Claude,
            environment: EnvironmentKind::Macos,
            identity: DisplayIdentity {
                email: "claude@example.com".to_owned(),
                subject: Some("claude-subject".to_owned()),
                name: None,
                plan_label: None,
            },
            secret_key: "test".to_owned(),
            created_at: time::OffsetDateTime::UNIX_EPOCH,
            updated_at: time::OffsetDateTime::UNIX_EPOCH,
            last_activated_at: None,
            cached_usage: Some(cached.clone()),
            cached_usage_error: None,
        };

        let result = stale_or_status(
            Some(&record),
            usage(ProviderUsageStatus::RateLimited, Some("HTTP 429")),
        );

        assert_eq!(result.status, ProviderUsageStatus::Stale);
        assert_eq!(result.fetched_at, cached.fetched_at);
        assert_eq!(result.detail.as_deref(), Some("HTTP 429"));
    }
}
