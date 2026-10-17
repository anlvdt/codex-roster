use std::collections::HashMap;

use anyhow::{Context, Result, anyhow, bail};
use uuid::Uuid;

use crate::model::{
    AccountUsageView, AccountView, AiProvider, ProviderAccountView, ProviderActivateOutput,
    ProviderListOutput, ProviderSaveOutput, ProviderStateView, ProviderStatusOutput,
    ProviderUsageOutput, ProviderUsageStatus, ProviderUsageView, ProviderUsageWindowView,
    SaveAction, SnapshotBlob, UsageFidelity,
};
use crate::operation_lock::{AuthLock, OperationLock};
use crate::provider::{ProviderAdapter, SnapshotRefresh, adapter};
use crate::provider_store::{
    LOGIN_REQUIRED_ERROR_PREFIX, ProviderAccountStore, ProviderSavedAccount,
};
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
            let (live_identity, live_error) =
                match adapter.try_read_live_identity_noninteractive(&self.env) {
                    Ok(live) => (live, None),
                    Err(error) => (None, Some(error.to_string())),
                };
            let (saved_accounts, current_account_saved_id) = if provider == AiProvider::OpenAi {
                let accounts = openai_accounts
                    .iter()
                    .filter(|account| account.provider == AiProvider::OpenAi)
                    .collect::<Vec<_>>();
                let active_id = live_identity.as_ref().and_then(|identity| {
                    accounts
                        .iter()
                        .find(|account| {
                            crate::model::DisplayIdentity {
                                email: account.email.clone(),
                                subject: account.subject.clone(),
                                name: account.name.clone(),
                                plan_label: account.plan_label.clone(),
                            }
                            .matches(identity)
                        })
                        .map(|account| account.id)
                });
                (accounts.len(), active_id)
            } else {
                let accounts = store.list(&self.env.kind, Some(provider))?;
                let active_id = live_identity.as_ref().and_then(|identity| {
                    accounts
                        .iter()
                        .find(|account| account.identity.matches(identity))
                        .map(|account| account.id)
                });
                (accounts.len(), active_id)
            };
            providers.push(ProviderStateView {
                provider,
                available: live_identity.is_some(),
                capabilities: adapter.capabilities().to_vec(),
                identity: live_identity,
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
                    .try_read_live_identity_noninteractive(&self.env)
                    .ok()
                    .flatten()
            });
            let is_active = live_identity
                .as_ref()
                .is_some_and(|identity| account.identity.matches(identity));
            let snapshot = store
                .load_snapshot(&self.env.kind, account.id)
                .ok()
                .map(|(_, snapshot)| snapshot);
            let mut view = account.view(is_active);
            view.activation_block_reason = account.activation_block_reason(snapshot.as_ref());
            view.can_activate = view.activation_block_reason.is_none();
            accounts.push(view);
        }
        accounts.sort_by_key(|account| std::cmp::Reverse(account.updated_at));
        Ok(ProviderListOutput {
            environment: self.env.kind.clone(),
            provider,
            accounts,
        })
    }

    pub fn provider_sync_claude(&self, email: &str) -> Result<ProviderListOutput> {
        self.provider_sync_claude_with_adapter(email, adapter(AiProvider::Claude))
    }

    fn provider_sync_claude_with_adapter(
        &self,
        email: &str,
        provider_adapter: &dyn ProviderAdapter,
    ) -> Result<ProviderListOutput> {
        let _auth_lock = AuthLock::acquire(&self.env.app_data_dir)?;
        let live = provider_adapter.read_live_auth(&self.env)?;
        if provider_adapter.provider() != AiProvider::Claude
            || !crate::provider::claude::has_oauth_token(&live.snapshot)
            || email.trim().is_empty()
            || live.identity.email == crate::provider::claude::UNKNOWN_EMAIL
            || !live.identity.email.eq_ignore_ascii_case(email.trim())
        {
            bail!("Claude CLI login does not match the verified signed-in account");
        }
        let _operation_lock = OperationLock::acquire(&self.env.app_data_dir)?;
        let store = self.provider_store();
        if let Some(record) =
            store.find_matching(&self.env.kind, AiProvider::Claude, &live.identity)?
        {
            let (_, snapshot) = store.load_snapshot(&self.env.kind, record.id)?;
            if snapshot != live.snapshot {
                preserve_claude_api_cooldown(
                    &self.env.home_dir,
                    &record,
                    time::OffsetDateTime::now_utc(),
                )?;
                let auth_error = record.requires_login()
                    || record.consecutive_auth_failures > 0
                    || record.cached_usage_error.as_deref().is_some_and(|error| {
                        error.contains("HTTP 401")
                            || error.contains("HTTP 403")
                            || error.contains("claude_cli_auth_missing")
                            || error.contains("OAuth access token not found")
                    });
                if auth_error {
                    store.save_for_record(
                        &self.env.kind,
                        record.id,
                        &live.identity,
                        &live.snapshot,
                    )?;
                } else {
                    store.save_rotated_snapshot(
                        &self.env.kind,
                        record.id,
                        &snapshot,
                        &live.snapshot,
                    )?;
                }
            }
        } else {
            store.save(
                &self.env.kind,
                AiProvider::Claude,
                &live.identity,
                &live.snapshot,
            )?;
        }
        let mut accounts = Vec::new();
        for record in store.list(&self.env.kind, Some(AiProvider::Claude))? {
            let (_, snapshot) = store.load_snapshot(&self.env.kind, record.id)?;
            let mut view = record.view(record.identity.matches(&live.identity));
            view.activation_block_reason = record.activation_block_reason(Some(&snapshot));
            view.can_activate = view.activation_block_reason.is_none();
            accounts.push(view);
        }
        Ok(ProviderListOutput {
            environment: self.env.kind.clone(),
            provider: Some(AiProvider::Claude),
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
        let _auth_lock = AuthLock::acquire(&self.env.app_data_dir)?;
        let live = adapter(provider)
            .read_live_auth(&self.env)
            .with_context(|| format!("no live {provider} authentication found"))?;
        if provider == AiProvider::Claude
            && !crate::provider::claude::has_oauth_token(&live.snapshot)
        {
            bail!(
                "Claude CLI is not signed in. Use Add account → Sign in; a Desktop identity alone cannot be saved as a CLI login."
            );
        }
        let _operation_lock = OperationLock::acquire(&self.env.app_data_dir)?;
        let store = self.provider_store();
        let provider_adapter = adapter(provider);
        let adoptable: Vec<Uuid> = store
            .list(&self.env.kind, Some(provider))?
            .into_iter()
            .filter(|record| !record.identity.matches(&live.identity))
            .filter(|record| {
                store
                    .load_snapshot(&self.env.kind, record.id)
                    .ok()
                    .is_some_and(|(_, snapshot)| {
                        provider_adapter.snapshots_share_credential(&snapshot, &live.snapshot)
                    })
            })
            .map(|record| record.id)
            .collect();
        let (record, created) = if adoptable.len() == 1 {
            (
                store.save_for_record(
                    &self.env.kind,
                    adoptable[0],
                    &live.identity,
                    &live.snapshot,
                )?,
                false,
            )
        } else {
            store.save(&self.env.kind, provider, &live.identity, &live.snapshot)?
        };
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
                warnings: Vec::new(),
            });
        }

        let _auth_lock = AuthLock::acquire(&self.env.app_data_dir)?;
        self.provider_activate_with_auth_lock(account_id)
    }

    pub(crate) fn provider_activate_with_auth_lock(
        &self,
        account_id: Uuid,
    ) -> Result<ProviderActivateOutput> {
        let store = self.provider_store();
        let (target, mut snapshot) = store.load_snapshot(&self.env.kind, account_id)?;
        let provider = target.provider;
        let provider_adapter = adapter(provider);
        let snapshot_identity = provider_adapter.identity_from_snapshot(&snapshot)?;
        if let Some(reason) = target.activation_block_reason(Some(&snapshot)) {
            bail!("cannot activate {}: {reason}", target.identity.email);
        }
        if !target.identity.matches(&snapshot_identity) {
            bail!(
                "saved {provider} snapshot identity does not match account {}",
                target.identity.email
            )
        }

        let _switch_guard = provider_adapter.acquire_switch_guard(&self.env)?;

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
        if let Some(live) = &previous_live {
            // Preserve rotated live tokens, including same-account activation.
            let _operation_lock = OperationLock::acquire(&self.env.app_data_dir)?;
            store.save(&self.env.kind, provider, &live.identity, &live.snapshot)?;
            if live.identity.matches(&target.identity) {
                snapshot = live.snapshot.clone();
            }
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
        // Auth is already restored and verified. Ancillary bookkeeping must not
        // turn this into an apparent failed switch and suppress Desktop handoff.
        let metadata = (|| {
            let _operation_lock = OperationLock::acquire(&self.env.app_data_dir)?;
            store.mark_activated(&self.env.kind, account_id, &verified.identity)
        })();
        let (record, warnings) = match metadata {
            Ok(record) => (record, Vec::new()),
            Err(error) => {
                let mut record = target;
                record.identity = verified.identity;
                record.last_activated_at = Some(time::OffsetDateTime::now_utc());
                (
                    record,
                    vec![format!(
                        "Login changed, but local activation metadata could not be saved: {error:#}"
                    )],
                )
            }
        };
        Ok(ProviderActivateOutput {
            account: record.view(true),
            previous_account_id,
            requires_relaunch: provider_adapter.requires_relaunch_after_switch(),
            warnings,
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

        self.provider_usage_with_adapter(
            adapter(provider),
            account_id,
            &crate::claude_quota_bridge::config_dir(&self.env.home_dir),
        )
    }

    fn provider_usage_with_adapter(
        &self,
        provider_adapter: &dyn ProviderAdapter,
        account_id: Option<Uuid>,
        claude_config_dir: &std::path::Path,
    ) -> Result<ProviderUsageOutput> {
        let provider = provider_adapter.provider();
        let store = self.provider_store();
        let is_live_request = account_id.is_none();
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
                let live = provider_adapter.read_live_auth(&self.env)?;
                let record = if provider == AiProvider::Claude {
                    store
                        .list(&self.env.kind, Some(provider))?
                        .into_iter()
                        .find(|record| record.identity.matches(&live.identity))
                } else {
                    None
                };
                (live.identity, live.snapshot, record)
            }
        };
        let local_cooldown = if provider == AiProvider::Claude {
            saved_record
                .as_ref()
                .map(|record| {
                    preserve_claude_api_cooldown_in_dir(
                        claude_config_dir,
                        record,
                        time::OffsetDateTime::now_utc(),
                    )
                })
                .transpose()?
                .flatten()
        } else {
            None
        };
        if provider == AiProvider::Claude
            && crate::claude_quota_bridge::covers_known_limits(
                saved_record
                    .as_ref()
                    .and_then(|record| record.cached_usage.as_ref()),
            )
            && let Some(usage) = crate::claude_quota_bridge::read_usage(
                claude_config_dir,
                &identity,
                time::OffsetDateTime::now_utc(),
            )
            && saved_record
                .as_ref()
                .and_then(|record| record.cached_usage.as_ref())
                .is_none_or(|cached| {
                    usage.fetched_at > cached.fetched_at
                        || (usage.fetched_at == cached.fetched_at
                            && cached
                                .detail
                                .as_deref()
                                .is_some_and(|detail| detail.starts_with("Claude Code statusline")))
                })
        {
            return Ok(ProviderUsageOutput {
                environment: self.env.kind.clone(),
                account: identity,
                usage,
            });
        }
        if let Some(record) = &saved_record
            && let Some(wait) = local_cooldown
        {
            let mut usage = record.cached_usage.clone().unwrap_or(ProviderUsageView {
                provider,
                fetched_at: record.updated_at,
                status: ProviderUsageStatus::RateLimited,
                fidelity: crate::model::UsageFidelity::Official,
                headline_window: None,
                windows: Vec::new(),
                plan_label: None,
                detail: None,
            });
            usage.status = if usage.windows.is_empty() {
                ProviderUsageStatus::RateLimited
            } else {
                ProviderUsageStatus::Stale
            };
            usage.detail = Some(format!(
                "Claude usage endpoint returned HTTP 429; retry in {} seconds",
                wait.whole_seconds().max(1)
            ));
            return Ok(ProviderUsageOutput {
                environment: self.env.kind.clone(),
                account: identity,
                usage,
            });
        }
        let mut fetched = match &saved_record {
            _ if is_live_request => provider_adapter.fetch_usage(&snapshot),
            Some(record) => match self.fetch_saved_usage_with_refresh(
                &store,
                provider_adapter,
                record,
                snapshot.clone(),
            ) {
                Ok((usage, used_snapshot)) => {
                    snapshot = used_snapshot;
                    Ok(usage)
                }
                Err(error) => Err(error),
            },
            None => provider_adapter.fetch_usage(&snapshot),
        };
        if is_live_request
            && fetched
                .as_ref()
                .is_ok_and(|usage| should_retry_live_credentials(usage.status))
            && let Ok(refreshed) = provider_adapter.read_live_auth(&self.env)
            && refreshed.snapshot != snapshot
        {
            if !identity.matches(&refreshed.identity) {
                bail!(
                    "live {provider} identity changed while checking usage; retry for the current account"
                );
            }
            identity = refreshed.identity;
            snapshot = refreshed.snapshot;
            fetched = provider_adapter.fetch_usage(&snapshot);
        }
        let usage = match fetched {
            Ok(mut usage) if usage.status == ProviderUsageStatus::Ok => {
                if provider == AiProvider::Claude
                    && !crate::provider::claude::usage_covers_required_limits(
                        &usage,
                        saved_record
                            .as_ref()
                            .and_then(|record| record.cached_usage.as_ref()),
                    )
                {
                    usage.status = ProviderUsageStatus::Error;
                    usage.detail = Some("Claude quota response omits required or previously known limits; quota is unknown".into());
                    stale_or_status(saved_record.as_ref(), usage)
                } else {
                    usage
                }
            }
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

    pub fn provider_delete(
        &self,
        account_id: Uuid,
        force: bool,
    ) -> Result<crate::model::ProviderDeleteOutput> {
        if self
            .repository
            .get_account(&self.env.kind, account_id)?
            .is_some()
        {
            bail!("use `delete` for Codex/OpenAI accounts");
        }
        let _auth_lock = AuthLock::acquire(&self.env.app_data_dir)?;
        let store = self.provider_store();
        let record = store
            .get(&self.env.kind, account_id)?
            .ok_or_else(|| anyhow!("provider account {account_id} not found"))?;
        if !force {
            let live = adapter(record.provider)
                .try_read_live_identity_noninteractive(&self.env)
                .ok()
                .flatten();
            if live
                .as_ref()
                .is_some_and(|identity| record.identity.matches(identity))
            {
                bail!(
                    "account {} is currently signed in to {}; re-run with --force to delete it",
                    record.identity.email,
                    record.provider
                );
            }
        }
        let _operation_lock = OperationLock::acquire(&self.env.app_data_dir)?;
        let removed = store.remove(&self.env.kind, account_id)?;
        LocalSecretStore::new(&self.env.app_data_dir.join("claude-desktop-logins"))
            .delete(&account_id.to_string())?;
        Ok(crate::model::ProviderDeleteOutput {
            id: removed.id,
            email: removed.identity.email,
            status: "deleted".to_owned(),
        })
    }

    pub fn provider_set_label(
        &self,
        account_id: Uuid,
        label: Option<String>,
    ) -> Result<ProviderAccountView> {
        if self
            .repository
            .get_account(&self.env.kind, account_id)?
            .is_some()
        {
            bail!("use `set-label` for Codex/OpenAI accounts");
        }
        let store = self.provider_store();
        let _operation_lock = OperationLock::acquire(&self.env.app_data_dir)?;
        let record = store.set_label(&self.env.kind, account_id, label)?;
        let is_active = adapter(record.provider)
            .try_read_live_identity_noninteractive(&self.env)
            .ok()
            .flatten()
            .is_some_and(|identity| record.identity.matches(&identity));
        Ok(record.view(is_active))
    }

    /// Read the zero-network Claude Code feed for display. Never refresh tokens
    /// or call the subscription API on this fast polling path.
    pub fn provider_local_claude_usage(&self) -> Result<ProviderListOutput> {
        let mut list = self.provider_list(Some(AiProvider::Claude))?;
        let dir = crate::claude_quota_bridge::config_dir(&self.env.home_dir);
        let now = time::OffsetDateTime::now_utc();
        for account in &mut list.accounts {
            let identity = crate::model::DisplayIdentity {
                email: account.email.clone(),
                subject: account.subject.clone(),
                name: account.name.clone(),
                plan_label: account.plan_label.clone(),
            };
            if let Some(local) = crate::claude_quota_bridge::read_usage(&dir, &identity, now) {
                account.usage = Some(local_quota_display(local, account.usage.as_ref()));
            }
        }
        Ok(list)
    }

    pub fn provider_refresh_usage(
        &self,
        provider: AiProvider,
        force: bool,
    ) -> Result<ProviderListOutput> {
        if provider == AiProvider::OpenAi {
            bail!("refresh-usage is only supported for external providers");
        }
        let store = self.provider_store();
        let records = store.list(&self.env.kind, Some(provider))?;
        let live_identity = if provider == AiProvider::Claude {
            adapter(provider)
                .try_read_live_identity_noninteractive(&self.env)
                .ok()
                .flatten()
        } else {
            None
        };
        for record in records {
            let local_cooldown = if provider == AiProvider::Claude {
                preserve_claude_api_cooldown(
                    &self.env.home_dir,
                    &record,
                    time::OffsetDateTime::now_utc(),
                )?
            } else {
                None
            };
            if provider == AiProvider::Claude
                && crate::claude_quota_bridge::covers_known_limits(record.cached_usage.as_ref())
                && let Some(usage) = crate::claude_quota_bridge::read_usage(
                    &crate::claude_quota_bridge::config_dir(&self.env.home_dir),
                    &record.identity,
                    time::OffsetDateTime::now_utc(),
                )
                && record
                    .cached_usage
                    .as_ref()
                    .is_none_or(|cached| usage.fetched_at > cached.fetched_at)
            {
                let _operation_lock = OperationLock::acquire(&self.env.app_data_dir)?;
                store.record_usage(&self.env.kind, record.id, usage)?;
                continue;
            }
            // A forced UI refresh also respects the server's rate-limit cooldown.
            if local_cooldown.is_some() {
                continue;
            }
            let is_live = live_identity
                .as_ref()
                .is_some_and(|identity| record.identity.matches(identity));
            if record.requires_login() && !force && !is_live {
                continue;
            }
            let stale = force
                || quota_refresh_due(
                    record.cached_usage.as_ref(),
                    is_live,
                    time::OffsetDateTime::now_utc(),
                );
            if !stale {
                continue;
            }
            if is_live {
                let live_usage = self.provider_usage(provider, None);
                let _operation_lock = OperationLock::acquire(&self.env.app_data_dir)?;
                match live_usage {
                    Ok(output)
                        if record.identity.matches(&output.account)
                            && output.usage.status == ProviderUsageStatus::Ok =>
                    {
                        store.record_usage(&self.env.kind, record.id, output.usage)?;
                    }
                    Ok(output) => {
                        let detail = if !record.identity.matches(&output.account) {
                            "Claude account changed while fetching quota; refresh the roster"
                                .to_owned()
                        } else {
                            output.usage.detail.unwrap_or_else(|| {
                                "Claude quota is unavailable; retry later".to_owned()
                            })
                        };
                        store.record_usage_error(&self.env.kind, record.id, detail)?;
                    }
                    Err(error) => {
                        store.record_usage_error(&self.env.kind, record.id, error.to_string())?;
                    }
                }
                continue;
            }
            if let Err(error) = self.provider_usage(provider, Some(record.id)) {
                let _operation_lock = OperationLock::acquire(&self.env.app_data_dir)?;
                let _ = store.record_usage_error(&self.env.kind, record.id, error.to_string());
            }
        }
        if provider == AiProvider::Claude {
            self.provider_local_claude_usage()
        } else {
            self.provider_list(Some(provider))
        }
    }

    pub(crate) fn provider_store(&self) -> ProviderAccountStore<LocalSecretStore> {
        ProviderAccountStore::new(
            &self.env.app_data_dir,
            LocalSecretStore::new(&self.env.app_data_dir.join("providers").join("snapshots")),
        )
    }

    fn fetch_saved_usage_with_refresh(
        &self,
        store: &ProviderAccountStore<LocalSecretStore>,
        provider_adapter: &dyn ProviderAdapter,
        record: &ProviderSavedAccount,
        snapshot: SnapshotBlob,
    ) -> Result<(ProviderUsageView, SnapshotBlob)> {
        let live = provider_adapter
            .try_read_live_identity_noninteractive(&self.env)
            .ok()
            .flatten();
        let shares_live = provider_adapter.snapshot_shares_live_credential(&self.env, &snapshot);
        let may_refresh = should_attempt_refresh(record, live.as_ref(), shares_live);
        let mut snapshot = snapshot;
        let mut attempted = false;
        if may_refresh && provider_adapter.snapshot_access_token_expired(&snapshot) {
            attempted = true;
            match self.attempt_snapshot_refresh(store, provider_adapter, record, &snapshot)? {
                RefreshStep::Rotated(new) => {
                    snapshot = new;
                }
                RefreshStep::Quarantined(usage) => return Ok((usage, snapshot)),
                RefreshStep::Skipped => {}
            }
        }
        let mut usage = provider_adapter.fetch_usage(&snapshot)?;
        if may_refresh && !attempted && usage.status == ProviderUsageStatus::CredentialExpired {
            match self.attempt_snapshot_refresh(store, provider_adapter, record, &snapshot)? {
                RefreshStep::Rotated(new) => {
                    snapshot = new;
                    usage = provider_adapter.fetch_usage(&snapshot)?;
                }
                RefreshStep::Quarantined(usage) => return Ok((usage, snapshot)),
                RefreshStep::Skipped => {}
            }
        }
        Ok((usage, snapshot))
    }

    fn attempt_snapshot_refresh(
        &self,
        store: &ProviderAccountStore<LocalSecretStore>,
        provider_adapter: &dyn ProviderAdapter,
        record: &ProviderSavedAccount,
        snapshot: &SnapshotBlob,
    ) -> Result<RefreshStep> {
        // Serialize read → token exchange → save across Roster processes.
        let _auth_lock = AuthLock::acquire(&self.env.app_data_dir)?;
        let (current_record, current_snapshot) = store.load_snapshot(&self.env.kind, record.id)?;
        if current_snapshot != *snapshot {
            return Ok(RefreshStep::Rotated(current_snapshot));
        }
        let live = provider_adapter.try_read_live_identity_noninteractive(&self.env)?;
        if !should_attempt_refresh(
            &current_record,
            live.as_ref(),
            provider_adapter.snapshot_shares_live_credential(&self.env, &current_snapshot),
        ) {
            return Ok(RefreshStep::Skipped);
        }
        match provider_adapter.refresh_snapshot(&current_snapshot) {
            SnapshotRefresh::Refreshed(new) => {
                let _operation_lock = OperationLock::acquire(&self.env.app_data_dir)?;
                store.save_rotated_snapshot(&self.env.kind, record.id, &current_snapshot, &new)?;
                eprintln!("refreshed Claude token for {}", record.identity.email);
                Ok(RefreshStep::Rotated(new))
            }
            SnapshotRefresh::Dead(reason) => {
                let detail = format!(
                    "{LOGIN_REQUIRED_ERROR_PREFIX}: refresh token rejected ({reason}); sign in with Claude Code as this account and save it again"
                );
                Ok(RefreshStep::Quarantined(crate::provider::needs_auth_view(
                    record.provider,
                    detail,
                )))
            }
            SnapshotRefresh::Transient(_) | SnapshotRefresh::Unsupported => {
                Ok(RefreshStep::Skipped)
            }
        }
    }
}

/// Persist cooldown via the last recorded error so restarts and CLI callers
/// cannot repeatedly hit a throttled account. Quota exhaustion is unrelated.
fn preserve_claude_api_cooldown(
    home: &std::path::Path,
    record: &ProviderSavedAccount,
    now: time::OffsetDateTime,
) -> Result<Option<time::Duration>> {
    let dir = crate::claude_quota_bridge::config_dir(home);
    preserve_claude_api_cooldown_in_dir(&dir, record, now)
}

fn preserve_claude_api_cooldown_in_dir(
    dir: &std::path::Path,
    record: &ProviderSavedAccount,
    now: time::OffsetDateTime,
) -> Result<Option<time::Duration>> {
    if let Some(wait) = claude_rate_limit_wait(record, now) {
        crate::claude_quota_bridge::remember_api_cooldown(dir, record.id, now + wait)?;
    }
    Ok(crate::claude_quota_bridge::api_cooldown(
        dir, record.id, now,
    ))
}

fn claude_rate_limit_wait(
    record: &ProviderSavedAccount,
    now: time::OffsetDateTime,
) -> Option<time::Duration> {
    if record.provider != AiProvider::Claude {
        return None;
    }
    let error = record.cached_usage_error.as_deref()?;
    if !error.contains("HTTP 429") {
        return None;
    }
    let seconds = error
        .split_once("retry after ")
        .and_then(|(_, text)| text.split_whitespace().next())
        .and_then(|value| value.parse::<i64>().ok())
        .filter(|value| *value > 0)
        .unwrap_or(300)
        .min(86_400);
    let elapsed = (now - record.updated_at).max(time::Duration::ZERO);
    let remaining = time::Duration::seconds(seconds) - elapsed;
    (remaining > time::Duration::ZERO).then_some(remaining)
}

enum RefreshStep {
    Rotated(SnapshotBlob),
    Quarantined(ProviderUsageView),
    Skipped,
}

fn should_attempt_refresh(
    record: &ProviderSavedAccount,
    live: Option<&crate::model::DisplayIdentity>,
    shares_live_credential: bool,
) -> bool {
    if record.requires_login() {
        return false;
    }
    if record.identity.email == crate::provider::claude::UNKNOWN_EMAIL {
        return false;
    }
    match live {
        Some(identity) => !record.identity.matches(identity) && !shares_live_credential,
        None => false,
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
    if status_usage.status == ProviderUsageStatus::NeedsAuth {
        return status_usage;
    }
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
        can_activate: true,
        activation_block_reason: None,
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
            ..Default::default()
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
            ..Default::default()
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

/// Active account telemetry follows the two-minute selection freshness budget;
/// inactive accounts retain the lower-cost background interval.
fn quota_refresh_due(
    usage: Option<&ProviderUsageView>,
    active: bool,
    now: time::OffsetDateTime,
) -> bool {
    let interval = if active {
        time::Duration::minutes(2)
    } else {
        time::Duration::minutes(15)
    };
    usage.is_none_or(|usage| {
        now - usage.fetched_at >= interval
            || usage.windows.iter().any(|window| {
                window
                    .reset_at
                    .is_some_and(|reset| usage.fetched_at < reset && reset <= now)
            })
    })
}

/// Local aggregate updates may be shown alongside old model caps and spending, but the
/// combined snapshot must never become verified evidence for auto-switching.
fn local_quota_display(
    mut local: ProviderUsageView,
    previous: Option<&ProviderUsageView>,
) -> ProviderUsageView {
    if let Some(previous) = previous.filter(|usage| usage.fetched_at >= local.fetched_at) {
        return previous.clone();
    }
    if let Some(previous) = previous.filter(|usage| {
        !crate::claude_quota_bridge::covers_known_limits(Some(usage))
            || usage
                .windows
                .iter()
                .any(|window| window.key == "extra_usage")
    }) {
        local.windows.extend(
            previous
                .windows
                .iter()
                .filter(|window| {
                    window.key.starts_with("seven_day_") || window.key == "extra_usage"
                })
                .cloned(),
        );
        local.status = ProviderUsageStatus::Stale;
        local.detail = Some(format!(
            "Claude Code statusline aggregates observed at {}; supplemental limits and spending last checked at {} (OAuth refresh pending)",
            local.fetched_at, previous.fetched_at
        ));
        local.fetched_at = previous.fetched_at;
    }
    local
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{DisplayIdentity, EnvironmentKind};

    struct ReviewAdapter {
        live: std::sync::Mutex<std::collections::VecDeque<crate::provider::ProviderAuthBundle>>,
        fetched: std::sync::Mutex<std::collections::VecDeque<ProviderUsageView>>,
    }

    impl ProviderAdapter for ReviewAdapter {
        fn provider(&self) -> AiProvider {
            AiProvider::Claude
        }
        fn capabilities(&self) -> &'static [crate::model::ProviderCapability] {
            &[]
        }
        fn try_read_live_auth(
            &self,
            env: &crate::env::AppEnv,
        ) -> Result<Option<crate::provider::ProviderAuthBundle>> {
            self.read_live_auth(env).map(Some)
        }
        fn read_live_auth(
            &self,
            _env: &crate::env::AppEnv,
        ) -> Result<crate::provider::ProviderAuthBundle> {
            Ok(self
                .live
                .lock()
                .unwrap()
                .pop_front()
                .expect("fixture live identity"))
        }
        fn try_read_live_identity_noninteractive(
            &self,
            _env: &crate::env::AppEnv,
        ) -> Result<Option<DisplayIdentity>> {
            Ok(None)
        }
        fn identity_from_snapshot(&self, _snapshot: &SnapshotBlob) -> Result<DisplayIdentity> {
            bail!("unused fixture identity extraction")
        }
        fn restore_snapshot(
            &self,
            _env: &crate::env::AppEnv,
            _snapshot: &SnapshotBlob,
        ) -> Result<()> {
            bail!("fixture must not restore credentials")
        }
        fn fetch_usage(&self, _snapshot: &SnapshotBlob) -> Result<ProviderUsageView> {
            Ok(self
                .fetched
                .lock()
                .unwrap()
                .pop_front()
                .expect("fixture quota response"))
        }
    }

    fn review_app() -> (
        tempfile::TempDir,
        App<crate::secrets::test_support::MemorySecretStore>,
    ) {
        let temp = tempfile::tempdir().unwrap();
        let env = crate::env::AppEnv {
            kind: EnvironmentKind::Macos,
            home_dir: temp.path().join("home"),
            codex_root: temp.path().join("home/.codex"),
            app_data_dir: temp.path().join("data"),
        };
        let repository = crate::repository::SnapshotRepository::new(
            &env.app_data_dir,
            crate::secrets::test_support::MemorySecretStore::default(),
        );
        (temp, App::new(env, repository))
    }

    fn review_bundle(subject: &str, token: &str) -> crate::provider::ProviderAuthBundle {
        use base64::Engine;
        crate::provider::ProviderAuthBundle {
            identity: DisplayIdentity {
                email: format!("{subject}@example.com"),
                subject: Some(subject.into()),
                name: None,
                plan_label: None,
            },
            snapshot: SnapshotBlob {
                schema_version: crate::model::SNAPSHOT_SCHEMA_VERSION,
                files: vec![crate::model::SnapshotFile {
                    name: "claude_credentials.json".into(),
                    bytes_base64: base64::engine::general_purpose::STANDARD.encode(format!(
                        r#"{{"claudeAiOauth":{{"accessToken":"{token}"}}}}"#
                    )),
                }],
            },
        }
    }

    fn review_quota(percent: u8) -> ProviderUsageView {
        let mut quota = usage(ProviderUsageStatus::Ok, None);
        quota.fetched_at = time::OffsetDateTime::now_utc();
        quota.windows = ["five_hour", "seven_day"]
            .into_iter()
            .map(|key| ProviderUsageWindowView {
                key: key.into(),
                used_percent: Some(percent),
                ..Default::default()
            })
            .collect();
        quota
    }

    #[test]
    fn sync_claude_detects_new_login_and_preserves_unchanged_record() {
        let (_root, app) = review_app();
        let bundle = review_bundle("synced", "token-one");
        let fixture = ReviewAdapter {
            live: std::sync::Mutex::new(
                [
                    review_bundle("synced", "token-one"),
                    review_bundle("synced", "token-one"),
                ]
                .into(),
            ),
            fetched: std::sync::Mutex::new([].into()),
        };
        let output = app
            .provider_sync_claude_with_adapter("SYNCED@example.com", &fixture)
            .unwrap();
        assert_eq!(output.accounts.len(), 1);
        assert!(output.accounts[0].is_active);
        let id = output.accounts[0].id;
        let store = app.provider_store();
        store
            .record_usage(&app.env.kind, id, review_quota(20))
            .unwrap();
        store
            .record_usage_error(
                &app.env.kind,
                id,
                "Claude usage endpoint returned HTTP 429; retry after 600 seconds".into(),
            )
            .unwrap();
        let before = store.get(&app.env.kind, id).unwrap().unwrap();
        app.provider_sync_claude_with_adapter("synced@example.com", &fixture)
            .unwrap();
        let after = store.get(&app.env.kind, id).unwrap().unwrap();
        assert_eq!(before.updated_at, after.updated_at);
        assert_eq!(before.cached_usage_error, after.cached_usage_error);
        assert_eq!(before.cached_usage, after.cached_usage);
        assert_eq!(
            store.load_snapshot(&app.env.kind, id).unwrap().1,
            bundle.snapshot
        );
    }

    #[test]
    fn sync_claude_rotates_known_credentials_without_losing_quota_or_label() {
        let (_root, app) = review_app();
        let old = review_bundle("synced", "token-one");
        let new = review_bundle("synced", "token-two");
        let store = app.provider_store();
        let (record, _) = store
            .save(
                &app.env.kind,
                AiProvider::Claude,
                &old.identity,
                &old.snapshot,
            )
            .unwrap();
        store
            .set_label(&app.env.kind, record.id, Some("Work".into()))
            .unwrap();
        store
            .record_usage(&app.env.kind, record.id, review_quota(20))
            .unwrap();
        store
            .record_usage_error(
                &app.env.kind,
                record.id,
                "Claude usage endpoint returned HTTP 429; retry after 600 seconds".into(),
            )
            .unwrap();
        let fixture = ReviewAdapter {
            live: std::sync::Mutex::new([review_bundle("synced", "token-two")].into()),
            fetched: std::sync::Mutex::new([].into()),
        };
        let output = app
            .provider_sync_claude_with_adapter("synced@example.com", &fixture)
            .unwrap();
        assert_eq!(output.accounts.len(), 1);
        assert_eq!(output.accounts[0].id, record.id);
        let saved = store.get(&app.env.kind, record.id).unwrap().unwrap();
        assert_eq!(saved.custom_label.as_deref(), Some("Work"));
        assert!(saved.cached_usage.is_some());
        assert!(saved.cached_usage_error.as_deref().unwrap().contains("429"));
        assert_eq!(
            store.load_snapshot(&app.env.kind, record.id).unwrap().1,
            new.snapshot
        );
        assert!(
            crate::claude_quota_bridge::api_cooldown(
                &crate::claude_quota_bridge::config_dir(&app.env.home_dir),
                record.id,
                time::OffsetDateTime::now_utc()
            )
            .is_some()
        );
    }

    #[test]
    fn sync_claude_rejects_unverified_identity_and_missing_credentials() {
        let (_root, app) = review_app();
        let saved = review_bundle("saved", "saved-token");
        let store = app.provider_store();
        let (record, _) = store
            .save(
                &app.env.kind,
                AiProvider::Claude,
                &saved.identity,
                &saved.snapshot,
            )
            .unwrap();
        let mut missing = review_bundle("synced", "token");
        missing.snapshot.files.clear();
        let mut unknown = review_bundle("synced", "token");
        unknown.identity.email = crate::provider::claude::UNKNOWN_EMAIL.into();
        for bundle in [missing, unknown, review_bundle("wrong", "token")] {
            let fixture = ReviewAdapter {
                live: std::sync::Mutex::new([bundle].into()),
                fetched: std::sync::Mutex::new([].into()),
            };
            assert!(
                app.provider_sync_claude_with_adapter("synced@example.com", &fixture)
                    .is_err()
            );
            assert_eq!(
                store
                    .list(&app.env.kind, Some(AiProvider::Claude))
                    .unwrap()
                    .len(),
                1
            );
            let (after, snapshot) = store.load_snapshot(&app.env.kind, record.id).unwrap();
            assert_eq!(after.updated_at, record.updated_at);
            assert_eq!(snapshot, saved.snapshot);
        }
    }

    #[test]
    fn sync_claude_changed_credentials_clear_missing_auth_error() {
        for error in [
            "claude_cli_auth_missing: sign in",
            "Claude OAuth access token not found",
        ] {
            let (_root, app) = review_app();
            let old = review_bundle("synced", "old-token");
            let store = app.provider_store();
            let (record, _) = store
                .save(
                    &app.env.kind,
                    AiProvider::Claude,
                    &old.identity,
                    &old.snapshot,
                )
                .unwrap();
            store
                .record_usage_error(&app.env.kind, record.id, error.into())
                .unwrap();
            let fixture = ReviewAdapter {
                live: std::sync::Mutex::new([review_bundle("synced", "new-token")].into()),
                fetched: std::sync::Mutex::new([].into()),
            };
            app.provider_sync_claude_with_adapter("synced@example.com", &fixture)
                .unwrap();
            assert!(
                store
                    .get(&app.env.kind, record.id)
                    .unwrap()
                    .unwrap()
                    .cached_usage_error
                    .is_none(),
                "{error}"
            );
        }
    }

    #[test]
    fn sync_claude_changed_credentials_recover_login_error() {
        let (_root, app) = review_app();
        let old = review_bundle("synced", "old-token");
        let store = app.provider_store();
        let (record, _) = store
            .save(
                &app.env.kind,
                AiProvider::Claude,
                &old.identity,
                &old.snapshot,
            )
            .unwrap();
        store
            .record_usage(&app.env.kind, record.id, review_quota(20))
            .unwrap();
        store
            .record_usage_error(
                &app.env.kind,
                record.id,
                format!("{LOGIN_REQUIRED_ERROR_PREFIX}: expired token"),
            )
            .unwrap();
        let fixture = ReviewAdapter {
            live: std::sync::Mutex::new([review_bundle("synced", "new-token")].into()),
            fetched: std::sync::Mutex::new([].into()),
        };
        app.provider_sync_claude_with_adapter("synced@example.com", &fixture)
            .unwrap();
        let after = store.get(&app.env.kind, record.id).unwrap().unwrap();
        assert!(!after.requires_login());
        assert_eq!(after.id, record.id);
        assert!(after.cached_usage.is_some());
    }

    #[test]
    fn review_fix_refresh_completion_does_not_recreate_deleted_account() {
        struct DeleteDuringRefresh<'a> {
            app: &'a App<crate::secrets::test_support::MemorySecretStore>,
            id: Uuid,
            replacement: SnapshotBlob,
        }
        impl ProviderAdapter for DeleteDuringRefresh<'_> {
            fn provider(&self) -> AiProvider {
                AiProvider::Claude
            }
            fn capabilities(&self) -> &'static [crate::model::ProviderCapability] {
                &[]
            }
            fn try_read_live_auth(
                &self,
                _: &crate::env::AppEnv,
            ) -> Result<Option<crate::provider::ProviderAuthBundle>> {
                Ok(Some(review_bundle("other", "other-token")))
            }
            fn read_live_auth(
                &self,
                env: &crate::env::AppEnv,
            ) -> Result<crate::provider::ProviderAuthBundle> {
                Ok(self.try_read_live_auth(env)?.unwrap())
            }
            fn identity_from_snapshot(&self, _: &SnapshotBlob) -> Result<DisplayIdentity> {
                unreachable!()
            }
            fn restore_snapshot(&self, _: &crate::env::AppEnv, _: &SnapshotBlob) -> Result<()> {
                unreachable!()
            }
            fn fetch_usage(&self, _: &SnapshotBlob) -> Result<ProviderUsageView> {
                unreachable!()
            }
            fn refresh_snapshot(&self, _: &SnapshotBlob) -> SnapshotRefresh {
                self.app
                    .provider_store()
                    .remove(&self.app.env.kind, self.id)
                    .unwrap();
                SnapshotRefresh::Refreshed(self.replacement.clone())
            }
        }
        let (_temp, app) = review_app();
        let store = app.provider_store();
        let old = review_bundle("saved", "old-token");
        let (record, _) = store
            .save(
                &app.env.kind,
                AiProvider::Claude,
                &old.identity,
                &old.snapshot,
            )
            .unwrap();
        let fixture = DeleteDuringRefresh {
            app: &app,
            id: record.id,
            replacement: review_bundle("saved", "new-token").snapshot,
        };
        let result = app.attempt_snapshot_refresh(&store, &fixture, &record, &old.snapshot);
        assert!(
            store
                .list(&app.env.kind, Some(AiProvider::Claude))
                .unwrap()
                .is_empty(),
            "refresh must not resurrect a removed record"
        );
        assert!(result.is_err());
    }

    #[test]
    fn review_fix_delete_waits_for_authentication_transaction() {
        let (_temp, app) = review_app();
        let store = app.provider_store();
        let bundle = review_bundle("saved", "token");
        let (record, _) = store
            .save(
                &app.env.kind,
                AiProvider::Claude,
                &bundle.identity,
                &bundle.snapshot,
            )
            .unwrap();
        let auth = AuthLock::acquire(&app.env.app_data_dir).unwrap();
        let (started_tx, started_rx) = std::sync::mpsc::channel();
        let (done_tx, done_rx) = std::sync::mpsc::channel();
        std::thread::scope(|scope| {
            scope.spawn(|| {
                started_tx.send(()).unwrap();
                done_tx
                    .send(app.provider_delete(record.id, true).is_ok())
                    .unwrap();
            });
            started_rx.recv().unwrap();
            let early = done_rx.recv_timeout(std::time::Duration::from_millis(150));
            drop(auth);
            assert!(
                early.is_err(),
                "deletion completed during an auth transaction"
            );
            assert!(
                done_rx
                    .recv_timeout(std::time::Duration::from_secs(2))
                    .unwrap()
            );
        });
        assert!(store.get(&app.env.kind, record.id).unwrap().is_none());
    }

    #[test]
    fn review_fix_activation_reports_success_after_metadata_failure() {
        use base64::Engine;
        use std::os::unix::fs::PermissionsExt;
        let (_temp, app) = review_app();
        let path = app
            .env
            .home_dir
            .join("Library/Application Support/Cursor/User/globalStorage/state.vscdb");
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        rusqlite::Connection::open(&path)
            .unwrap()
            .execute_batch("CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value BLOB);")
            .unwrap();
        let payload = serde_json::json!({
            "cursorAuth/cachedEmail": base64::engine::general_purpose::STANDARD.encode("target@example.com"),
            "cursorAuth/accessToken": base64::engine::general_purpose::STANDARD.encode("target-token")
        });
        let snapshot = SnapshotBlob {
            schema_version: 1,
            files: vec![crate::model::SnapshotFile {
                name: "cursor_auth.json".into(),
                bytes_base64: base64::engine::general_purpose::STANDARD
                    .encode(serde_json::to_vec(&payload).unwrap()),
            }],
        };
        let identity = adapter(AiProvider::Cursor)
            .identity_from_snapshot(&snapshot)
            .unwrap();
        let (record, _) = app
            .provider_store()
            .save(&app.env.kind, AiProvider::Cursor, &identity, &snapshot)
            .unwrap();
        let directory = app.env.app_data_dir.join("providers");
        std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o500)).unwrap();
        let result = app.provider_activate(record.id);
        std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o700)).unwrap();
        assert_eq!(
            adapter(AiProvider::Cursor)
                .read_live_auth(&app.env)
                .unwrap()
                .identity
                .email,
            "target@example.com"
        );
        assert!(
            result.is_ok(),
            "verified credential switch must remain successful: {result:?}"
        );
    }

    #[test]
    fn review_fix_rotated_credentials_survive_unwritable_index() {
        use std::os::unix::fs::PermissionsExt;
        struct RotatingAdapter {
            replacement: SnapshotBlob,
        }
        impl ProviderAdapter for RotatingAdapter {
            fn provider(&self) -> AiProvider {
                AiProvider::Claude
            }
            fn capabilities(&self) -> &'static [crate::model::ProviderCapability] {
                &[]
            }
            fn try_read_live_auth(
                &self,
                _: &crate::env::AppEnv,
            ) -> Result<Option<crate::provider::ProviderAuthBundle>> {
                Ok(Some(review_bundle("other", "other-token")))
            }
            fn read_live_auth(
                &self,
                env: &crate::env::AppEnv,
            ) -> Result<crate::provider::ProviderAuthBundle> {
                Ok(self.try_read_live_auth(env)?.unwrap())
            }
            fn identity_from_snapshot(&self, _: &SnapshotBlob) -> Result<DisplayIdentity> {
                unreachable!()
            }
            fn restore_snapshot(&self, _: &crate::env::AppEnv, _: &SnapshotBlob) -> Result<()> {
                unreachable!()
            }
            fn fetch_usage(&self, _: &SnapshotBlob) -> Result<ProviderUsageView> {
                unreachable!()
            }
            fn refresh_snapshot(&self, _: &SnapshotBlob) -> SnapshotRefresh {
                SnapshotRefresh::Refreshed(self.replacement.clone())
            }
        }
        let (_temp, app) = review_app();
        let store = app.provider_store();
        let old = review_bundle("saved", "old-token");
        let new = review_bundle("saved", "rotated-token").snapshot;
        let (record, _) = store
            .save(
                &app.env.kind,
                AiProvider::Claude,
                &old.identity,
                &old.snapshot,
            )
            .unwrap();
        let parent = app.env.app_data_dir.join("providers");
        std::fs::set_permissions(&parent, std::fs::Permissions::from_mode(0o500)).unwrap();
        let result = app.attempt_snapshot_refresh(
            &store,
            &RotatingAdapter {
                replacement: new.clone(),
            },
            &record,
            &old.snapshot,
        );
        std::fs::set_permissions(&parent, std::fs::Permissions::from_mode(0o700)).unwrap();
        assert_eq!(
            store.load_snapshot(&app.env.kind, record.id).unwrap().1,
            new,
            "single-use token exchange must not be undone by a metadata failure"
        );
        assert!(matches!(result, Ok(RefreshStep::Rotated(_))));
        assert_eq!(
            store
                .list(&app.env.kind, Some(AiProvider::Claude))
                .unwrap()
                .len(),
            1
        );
    }

    #[test]
    fn provider_review_identity_changed_retry_leaves_both_caches_untouched() {
        let (_temp, app) = review_app();
        let store = app.provider_store();
        let a = review_bundle("a", "a-token");
        let b = review_bundle("b", "b-token");
        let (record_a, _) = store
            .save(&app.env.kind, AiProvider::Claude, &a.identity, &a.snapshot)
            .unwrap();
        let (record_b, _) = store
            .save(&app.env.kind, AiProvider::Claude, &b.identity, &b.snapshot)
            .unwrap();
        store
            .record_usage(&app.env.kind, record_a.id, review_quota(10))
            .unwrap();
        store
            .record_usage(&app.env.kind, record_b.id, review_quota(90))
            .unwrap();
        let before_a = store.get(&app.env.kind, record_a.id).unwrap().unwrap();
        let before_b = store.get(&app.env.kind, record_b.id).unwrap().unwrap();
        let fixture = ReviewAdapter {
            live: std::sync::Mutex::new([a, b].into()),
            fetched: std::sync::Mutex::new(
                [
                    usage(ProviderUsageStatus::CredentialExpired, Some("HTTP 401")),
                    review_quota(90),
                ]
                .into(),
            ),
        };
        let error = app
            .provider_usage_with_adapter(&fixture, None, &app.env.home_dir.join(".claude"))
            .unwrap_err();
        assert!(error.to_string().contains("identity changed"));
        assert_eq!(
            fixture.fetched.lock().unwrap().len(),
            1,
            "must reject before fetching the new account"
        );
        for before in [before_a, before_b] {
            let after = store.get(&app.env.kind, before.id).unwrap().unwrap();
            assert_eq!(after.cached_usage, before.cached_usage);
            assert_eq!(after.cached_usage_error, before.cached_usage_error);
        }
    }

    #[test]
    fn provider_review_same_identity_token_rotation_still_retries_and_caches() {
        let (_temp, app) = review_app();
        let store = app.provider_store();
        let a = review_bundle("a", "old-token");
        let (record, _) = store
            .save(&app.env.kind, AiProvider::Claude, &a.identity, &a.snapshot)
            .unwrap();
        let fresh = review_quota(40);
        let fixture = ReviewAdapter {
            live: std::sync::Mutex::new([a, review_bundle("a", "rotated-token")].into()),
            fetched: std::sync::Mutex::new(
                [
                    usage(ProviderUsageStatus::CredentialExpired, None),
                    fresh.clone(),
                ]
                .into(),
            ),
        };
        let output = app
            .provider_usage_with_adapter(&fixture, None, &app.env.home_dir.join(".claude"))
            .unwrap();
        assert_eq!(output.account.subject.as_deref(), Some("a"));
        assert_eq!(output.usage, fresh);
        assert_eq!(
            store
                .get(&app.env.kind, record.id)
                .unwrap()
                .unwrap()
                .cached_usage,
            Some(fresh)
        );
        assert!(fixture.fetched.lock().unwrap().is_empty());
    }

    #[test]
    fn older_valid_local_observation_cannot_replace_newer_oauth() {
        let (_temp, app) = review_app();
        let store = app.provider_store();
        let a = review_bundle("a", "fixture-token");
        let (record, _) = store
            .save(&app.env.kind, AiProvider::Claude, &a.identity, &a.snapshot)
            .unwrap();
        let cached = review_quota(80);
        store
            .record_usage(&app.env.kind, record.id, cached.clone())
            .unwrap();
        let dir = app.env.home_dir.join(".claude");
        std::fs::create_dir_all(dir.join("roster-usage")).unwrap();
        let now = time::OffsetDateTime::now_utc();
        std::fs::write(
            dir.join("roster-usage/session.json"),
            serde_json::json!({
                "email": a.identity.email, "subject": "a", "observed_at": now.unix_timestamp() - 30,
                "rate_limits": {
                    "five_hour": {"used_percentage": 5, "resets_at": now.unix_timestamp() + 3600},
                    "seven_day": {"used_percentage": 5, "resets_at": now.unix_timestamp() + 7200}
                }
            })
            .to_string(),
        )
        .unwrap();
        let local = crate::claude_quota_bridge::read_usage(&dir, &a.identity, now).unwrap();
        store
            .record_usage(&app.env.kind, record.id, local.clone())
            .unwrap();
        let local_fixture = ReviewAdapter {
            live: std::sync::Mutex::new([review_bundle("a", "fixture-token")].into()),
            fetched: std::sync::Mutex::new([].into()),
        };
        let equal = app
            .provider_usage_with_adapter(&local_fixture, None, &dir)
            .unwrap();
        assert_eq!(equal.usage.fetched_at, local.fetched_at);
        store
            .record_usage(&app.env.kind, record.id, cached.clone())
            .unwrap();
        let fixture = ReviewAdapter {
            live: std::sync::Mutex::new([a].into()),
            fetched: std::sync::Mutex::new([review_quota(90)].into()),
        };
        let output = app
            .provider_usage_with_adapter(&fixture, None, &dir)
            .unwrap();
        assert_eq!(output.usage.windows[0].used_percent, Some(90));
        let after = store.get(&app.env.kind, record.id).unwrap().unwrap();
        assert_eq!(
            after.cached_usage.as_ref().unwrap().windows[0].used_percent,
            Some(90)
        );
        app.provider_refresh_usage(AiProvider::Claude, false)
            .unwrap();
        let after = store.get(&app.env.kind, record.id).unwrap().unwrap();
        assert_eq!(
            after.cached_usage.as_ref().unwrap().windows[0].used_percent,
            Some(90)
        );
    }

    #[test]
    fn newer_local_observation_cannot_erase_monthly_spending() {
        let (_temp, app) = review_app();
        let store = app.provider_store();
        let a = review_bundle("a", "fixture-token");
        let (record, _) = store
            .save(&app.env.kind, AiProvider::Claude, &a.identity, &a.snapshot)
            .unwrap();
        let mut cached = review_quota(80);
        cached.fetched_at -= time::Duration::seconds(30);
        cached.windows.push(ProviderUsageWindowView {
            key: "extra_usage".into(),
            used_percent: Some(25),
            ..Default::default()
        });
        store
            .record_usage(&app.env.kind, record.id, cached.clone())
            .unwrap();
        let dir = app.env.home_dir.join(".claude");
        std::fs::create_dir_all(dir.join("roster-usage")).unwrap();
        let now = time::OffsetDateTime::now_utc();
        std::fs::write(
            dir.join("roster-usage/session.json"),
            serde_json::json!({
                "email": a.identity.email, "subject": "a", "observed_at": now.unix_timestamp(),
                "rate_limits": {
                    "five_hour": {"used_percentage": 5, "resets_at": now.unix_timestamp() + 3600},
                    "seven_day": {"used_percentage": 5, "resets_at": now.unix_timestamp() + 7200}
                }
            })
            .to_string(),
        )
        .unwrap();
        app.provider_refresh_usage(AiProvider::Claude, false)
            .unwrap();
        assert_eq!(
            store
                .get(&app.env.kind, record.id)
                .unwrap()
                .unwrap()
                .cached_usage,
            Some(cached.clone())
        );
        let fixture = ReviewAdapter {
            live: std::sync::Mutex::new([a].into()),
            fetched: std::sync::Mutex::new([cached.clone()].into()),
        };
        let output = app
            .provider_usage_with_adapter(&fixture, None, &dir)
            .unwrap();
        assert_eq!(output.usage, cached);
        assert!(fixture.fetched.lock().unwrap().is_empty());
    }

    #[test]
    fn provider_review_omitted_known_model_cap_preserves_cache_as_stale() {
        let (_temp, app) = review_app();
        let store = app.provider_store();
        let a = review_bundle("a", "fixture-token");
        let (record, _) = store
            .save(&app.env.kind, AiProvider::Claude, &a.identity, &a.snapshot)
            .unwrap();
        let mut cached = review_quota(10);
        cached.windows.push(ProviderUsageWindowView {
            key: "seven_day_opus".into(),
            used_percent: Some(100),
            ..Default::default()
        });
        store
            .record_usage(&app.env.kind, record.id, cached.clone())
            .unwrap();
        let fixture = ReviewAdapter {
            live: std::sync::Mutex::new([a].into()),
            fetched: std::sync::Mutex::new([review_quota(1)].into()),
        };
        let output = app
            .provider_usage_with_adapter(&fixture, None, &app.env.home_dir.join(".claude"))
            .unwrap();
        assert_eq!(output.usage.status, ProviderUsageStatus::Stale);
        assert_eq!(output.usage.windows, cached.windows);
        let after = store.get(&app.env.kind, record.id).unwrap().unwrap();
        assert_eq!(after.cached_usage, Some(cached));
        assert!(
            after
                .cached_usage_error
                .unwrap()
                .contains("previously known limits")
        );
    }

    #[test]
    #[cfg(unix)]
    fn provider_review_failed_index_write_retains_desktop_snapshot() {
        use std::os::unix::fs::PermissionsExt;
        let (_temp, app) = review_app();
        let store = app.provider_store();
        let a = review_bundle("a", "fixture-token");
        let (record, _) = store
            .save(&app.env.kind, AiProvider::Claude, &a.identity, &a.snapshot)
            .unwrap();
        let desktop_store =
            LocalSecretStore::new(&app.env.app_data_dir.join("claude-desktop-logins"));
        let payload = serde_json::to_vec(&a.snapshot).unwrap();
        desktop_store
            .save(&record.id.to_string(), &payload)
            .unwrap();
        let index_dir = app.env.app_data_dir.join("providers");
        let previous_permissions = std::fs::metadata(&index_dir).unwrap().permissions();
        std::fs::set_permissions(&index_dir, std::fs::Permissions::from_mode(0o500)).unwrap();
        let result = app.provider_delete(record.id, true);
        std::fs::set_permissions(&index_dir, previous_permissions).unwrap();
        assert!(result.is_err(), "fixture must prevent the index write");
        assert!(store.get(&app.env.kind, record.id).unwrap().is_some());
        assert_eq!(
            desktop_store.load(&record.id.to_string()).unwrap(),
            Some(payload)
        );
        assert!(store.load_snapshot(&app.env.kind, record.id).is_ok());
    }

    #[test]
    fn provider_review_successful_delete_removes_desktop_snapshot() {
        let (_temp, app) = review_app();
        let store = app.provider_store();
        let a = review_bundle("a", "fixture-token");
        let (record, _) = store
            .save(&app.env.kind, AiProvider::Claude, &a.identity, &a.snapshot)
            .unwrap();
        let desktop_store =
            LocalSecretStore::new(&app.env.app_data_dir.join("claude-desktop-logins"));
        desktop_store
            .save(
                &record.id.to_string(),
                &serde_json::to_vec(&a.snapshot).unwrap(),
            )
            .unwrap();
        app.provider_delete(record.id, true).unwrap();
        assert!(store.get(&app.env.kind, record.id).unwrap().is_none());
        assert!(
            desktop_store
                .load(&record.id.to_string())
                .unwrap()
                .is_none()
        );
    }

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
            custom_label: None,
            cached_usage: Some(cached.clone()),
            cached_usage_error: None,
            consecutive_auth_failures: 0,
        };

        let result = stale_or_status(
            Some(&record),
            usage(ProviderUsageStatus::RateLimited, Some("HTTP 429")),
        );

        assert_eq!(result.status, ProviderUsageStatus::Stale);
        assert_eq!(result.fetched_at, cached.fetched_at);
        assert_eq!(result.detail.as_deref(), Some("HTTP 429"));
    }

    fn record(error: Option<&str>) -> ProviderSavedAccount {
        ProviderSavedAccount {
            id: Uuid::nil(),
            provider: AiProvider::Claude,
            environment: EnvironmentKind::Macos,
            identity: DisplayIdentity {
                email: "claude@example.com".to_owned(),
                subject: Some("sub-1".to_owned()),
                name: None,
                plan_label: None,
            },
            secret_key: "test".to_owned(),
            created_at: time::OffsetDateTime::UNIX_EPOCH,
            updated_at: time::OffsetDateTime::UNIX_EPOCH,
            last_activated_at: None,
            custom_label: None,
            cached_usage: None,
            cached_usage_error: error.map(str::to_owned),
            consecutive_auth_failures: 0,
        }
    }

    #[test]
    fn active_quota_refreshes_after_two_minutes_while_inactive_is_less_frequent() {
        let now = time::OffsetDateTime::now_utc();
        let mut cached = usage(ProviderUsageStatus::Ok, None);
        cached.fetched_at = now - time::Duration::seconds(119);
        assert!(!quota_refresh_due(Some(&cached), true, now));
        cached.fetched_at = now - time::Duration::seconds(120);
        assert!(quota_refresh_due(Some(&cached), true, now));
        assert!(!quota_refresh_due(Some(&cached), false, now));
        cached.fetched_at = now - time::Duration::minutes(15);
        assert!(quota_refresh_due(Some(&cached), false, now));
        assert!(quota_refresh_due(None, true, now));
    }

    #[test]
    fn live_display_keeps_model_caps_and_does_not_renew_their_freshness() {
        let mut previous = usage(ProviderUsageStatus::Ok, None);
        previous.fetched_at = time::OffsetDateTime::UNIX_EPOCH;
        previous.windows = vec![ProviderUsageWindowView {
            key: "seven_day_opus".into(),
            used_percent: Some(100),
            ..Default::default()
        }];
        let mut local = usage(ProviderUsageStatus::Ok, Some("Claude Code statusline"));
        local.fetched_at = time::OffsetDateTime::now_utc();
        local.windows = vec![ProviderUsageWindowView {
            key: "five_hour".into(),
            used_percent: Some(42),
            ..Default::default()
        }];
        let display = local_quota_display(local, Some(&previous));
        assert_eq!(display.fetched_at, previous.fetched_at);
        assert_eq!(display.status, ProviderUsageStatus::Stale);
        assert!(
            display
                .windows
                .iter()
                .any(|w| w.key == "five_hour" && w.used_percent == Some(42))
        );
        assert!(
            display
                .windows
                .iter()
                .any(|w| w.key == "seven_day_opus" && w.used_percent == Some(100))
        );
    }

    #[test]
    fn live_display_keeps_monthly_spending_without_renewing_its_freshness() {
        let mut previous = usage(ProviderUsageStatus::Ok, None);
        previous.fetched_at = time::OffsetDateTime::UNIX_EPOCH;
        previous.windows = vec![ProviderUsageWindowView {
            key: "extra_usage".into(),
            used_percent: Some(25),
            ..Default::default()
        }];
        let mut local = usage(ProviderUsageStatus::Ok, Some("Claude Code statusline"));
        local.fetched_at = time::OffsetDateTime::now_utc();
        local.windows = vec![ProviderUsageWindowView {
            key: "five_hour".into(),
            used_percent: Some(42),
            ..Default::default()
        }];
        let display = local_quota_display(local, Some(&previous));
        assert_eq!(display.fetched_at, previous.fetched_at);
        assert_eq!(display.status, ProviderUsageStatus::Stale);
        assert!(
            display
                .detail
                .as_deref()
                .unwrap()
                .contains(&previous.fetched_at.to_string())
        );
        assert!(
            display
                .windows
                .iter()
                .any(|w| w.key == "extra_usage" && w.used_percent == Some(25))
        );
        assert!(
            display
                .windows
                .iter()
                .any(|w| w.key == "five_hour" && w.used_percent == Some(42))
        );
    }

    #[test]
    fn refresh_is_only_attempted_for_known_inactive_accounts() {
        let quarantined = record(Some("login_required: refresh token rejected"));
        let normal = record(None);
        let mut placeholder = record(None);
        placeholder.identity.email = crate::provider::claude::UNKNOWN_EMAIL.to_owned();
        let live_matching = DisplayIdentity {
            email: "claude@example.com".to_owned(),
            subject: Some("sub-1".to_owned()),
            name: None,
            plan_label: None,
        };
        let live_other = DisplayIdentity {
            email: "other@example.com".to_owned(),
            subject: Some("sub-2".to_owned()),
            name: None,
            plan_label: None,
        };
        assert!(!should_attempt_refresh(
            &quarantined,
            Some(&live_other),
            false
        ));
        assert!(!should_attempt_refresh(
            &placeholder,
            Some(&live_other),
            false
        ));
        assert!(!should_attempt_refresh(&normal, None, false));
        assert!(!should_attempt_refresh(
            &normal,
            Some(&live_matching),
            false
        ));
        assert!(!should_attempt_refresh(&normal, Some(&live_other), true));
        assert!(should_attempt_refresh(&normal, Some(&live_other), false));
    }

    #[test]
    fn needs_auth_survives_stale_fallback() {
        let mut record = record(None);
        record.cached_usage = Some(usage(ProviderUsageStatus::Ok, None));
        let quarantined = usage(ProviderUsageStatus::NeedsAuth, Some("login_required: x"));
        let result = stale_or_status(Some(&record), quarantined);
        assert_eq!(result.status, ProviderUsageStatus::NeedsAuth);
    }
    #[test]
    fn quota_rate_limit_cooldown_survives_cached_usage_and_expires() {
        let mut throttled = record(Some("Claude usage endpoint returned HTTP 429"));
        let now = time::OffsetDateTime::now_utc();
        throttled.updated_at = now;
        throttled.cached_usage = Some(usage(ProviderUsageStatus::Ok, None));
        assert_eq!(
            claude_rate_limit_wait(&throttled, now),
            Some(time::Duration::seconds(300))
        );
        assert_eq!(
            claude_rate_limit_wait(&throttled, now + time::Duration::seconds(299)),
            Some(time::Duration::seconds(1))
        );
        assert!(claude_rate_limit_wait(&throttled, now + time::Duration::seconds(300)).is_none());
        assert_eq!(
            throttled.cached_usage.as_ref().unwrap().status,
            ProviderUsageStatus::Ok
        );
        assert!(claude_rate_limit_wait(&record(Some("HTTP 401")), now).is_none());
    }

    #[test]
    fn quota_rate_limit_cooldown_respects_retry_after_and_provider() {
        let mut throttled = record(Some(
            "Claude usage endpoint returned HTTP 429; retry after 900 seconds",
        ));
        let now = time::OffsetDateTime::now_utc();
        throttled.updated_at = now;
        assert_eq!(
            claude_rate_limit_wait(&throttled, now + time::Duration::seconds(300)),
            Some(time::Duration::seconds(600))
        );
        throttled.provider = AiProvider::Cursor;
        assert!(claude_rate_limit_wait(&throttled, now).is_none());
    }
}
