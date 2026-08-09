use anyhow::{Context, Result};
use std::collections::HashSet;
use std::time::{Duration, Instant};
use uuid::Uuid;

use crate::backup::{read_encrypted, write_encrypted};
use crate::codex;
use crate::env::AppEnv;
use crate::model::{
    AccountUsageView, AccountView, ActivateOutput, AutoSwitchOutput, DeleteOutput, DisplayIdentity,
    LegacyRecoveryOutput, ListOutput, RunningCodexProcess, SaveAction, SaveOutput, SnapshotBlob,
    StatusOutput, TokenUsageSummaryOutput, UsageOutput, UsageSource,
};
use crate::operation_lock::{AuthLock, OperationLock};
use crate::repository::SnapshotRepository;
use crate::secrets::SecretStore;
use crate::settings::{load_settings, save_settings};
use crate::usage::{
    FetchUsageError, fetch_usage, usage_error_blocks_activation, usage_error_message,
    usage_target_from_snapshot,
};

const ALLOW_LIVE_TOKEN_REFRESH: bool = false;
const _: () = assert!(!ALLOW_LIVE_TOKEN_REFRESH);

use super::{
    App, account_view, match_saved_account, saved_identity, should_verify_activation_stability,
    subject_bound_identity_matches,
};

impl<S> App<S>
where
    S: SecretStore,
{
    pub fn new(env: AppEnv, repository: SnapshotRepository<S>) -> Self {
        Self { env, repository }
    }

    pub(crate) fn env(&self) -> &AppEnv {
        &self.env
    }

    pub fn status(&self) -> Result<StatusOutput> {
        let saved_accounts = self.repository.list_accounts(&self.env.kind)?;
        let live = codex::try_read_live_auth_bundle(&self.env)?;
        let current_saved_id = live
            .as_ref()
            .and_then(|bundle| match_saved_account(&saved_accounts, &bundle.identity))
            .map(|account| account.id);
        Ok(StatusOutput {
            environment: self.env.kind.clone(),
            codex_root: self.env.codex_root.display().to_string(),
            current_account: live.map(|bundle| bundle.identity),
            current_account_saved_id: current_saved_id,
            saved_accounts: saved_accounts.len(),
            process_warnings: crate::process::detect_running_codex_processes(),
        })
    }

    pub fn auto_switch_enabled(&self) -> Result<bool> {
        Ok(load_settings(&self.env.app_data_dir)?.auto_switch_when_exhausted)
    }

    pub fn set_auto_switch_when_exhausted(&self, enabled: bool) -> Result<AutoSwitchOutput> {
        let _operation_lock = OperationLock::acquire(&self.env.app_data_dir)?;
        let mut settings = load_settings(&self.env.app_data_dir)?;
        settings.auto_switch_when_exhausted = enabled;
        if !enabled {
            settings.last_auto_switch_at = None;
            settings.last_auto_switch_target = None;
        }
        save_settings(&self.env.app_data_dir, &settings)?;
        Ok(AutoSwitchOutput {
            enabled,
            status: if enabled { "enabled" } else { "disabled" }.to_owned(),
            active_account_id: None,
            candidate_account_id: None,
            candidate_display_name: None,
            detail: None,
        })
    }

    pub fn auto_switch(&self, apply: bool) -> Result<AutoSwitchOutput> {
        self.auto_switch_with_candidate(apply, None, false)
    }

    pub fn auto_switch_with_candidate(
        &self,
        apply: bool,
        preferred_candidate_id: Option<Uuid>,
        force: bool,
    ) -> Result<AutoSwitchOutput> {
        let enabled = self.auto_switch_enabled()?;
        if codex::add_account_session_active(&self.env) {
            return Ok(auto_switch_output(
                enabled,
                "waiting_for_login",
                None,
                None,
                None,
                Some(
                    "Account login is in progress; the current session was left unchanged."
                        .to_owned(),
                ),
            ));
        }
        if !enabled {
            return Ok(auto_switch_output(
                false, "disabled", None, None, None, None,
            ));
        }
        // Apply reuses the prior decision when possible — avoid a second Keychain/network
        // fan-out that unlocks the keychain and blocks ChatGPT relaunch.
        if apply {
            return self.apply_auto_switch(enabled, preferred_candidate_id, force);
        }
        self.decide_auto_switch(enabled)
    }

    fn decide_auto_switch(&self, enabled: bool) -> Result<AutoSwitchOutput> {
        // Fresh check of the live account only. Candidates prefer cached quota to
        // avoid decrypting every saved snapshot on each 60s poll.
        let _ = self.usage(None)?;
        let active = self
            .list()?
            .accounts
            .into_iter()
            .find(|account| account.is_active);
        let Some(active) = active else {
            return Ok(auto_switch_output(
                enabled,
                "waiting_for_login",
                None,
                None,
                None,
                None,
            ));
        };
        if !is_exhausted_for_switch(active.usage.as_ref()) {
            return Ok(auto_switch_output(
                enabled,
                "active_has_quota",
                Some(active.id),
                None,
                None,
                None,
            ));
        }

        let settings = load_settings(&self.env.app_data_dir)?;
        let now = time::OffsetDateTime::now_utc();
        let candidates = self.repository.list_accounts(&self.env.kind)?;
        let mut usable_candidate_ids = HashSet::new();
        for candidate in candidates.iter().filter(|candidate| {
            candidate.id != active.id
                && !candidate.archived
                && !candidate
                    .cached_usage_error
                    .as_deref()
                    .is_some_and(usage_error_blocks_activation)
        }) {
            // Fresh cache (usable or not) skips network/decrypt. Only refresh stale/missing.
            if cached_usage_is_fresh(candidate.cached_usage.as_ref(), now) {
                if is_usable_for_switch(candidate.cached_usage.as_ref()) {
                    usable_candidate_ids.insert(candidate.id);
                }
                continue;
            }
            if self.usage(Some(candidate.id)).is_ok() {
                usable_candidate_ids.insert(candidate.id);
            }
        }

        let candidate = self
            .list()?
            .accounts
            .into_iter()
            .filter(|candidate| {
                candidate.id != active.id
                    && !accounts_represent_same_identity(candidate, &active)
                    && !candidate.archived
                    && !candidate
                        .usage_error
                        .as_deref()
                        .is_some_and(usage_error_blocks_activation)
                    && is_usable_for_switch(candidate.usage.as_ref())
                    && usable_candidate_ids.contains(&candidate.id)
                    && !is_in_auto_switch_cooldown(&settings, candidate.id, now)
            })
            .max_by_key(|candidate| switch_quota_score(candidate.usage.as_ref()));

        let Some(candidate) = candidate else {
            return Ok(auto_switch_output(
                enabled,
                "all_accounts_exhausted",
                Some(active.id),
                None,
                None,
                Some("No eligible saved account has fresh usable quota.".to_owned()),
            ));
        };
        Ok(auto_switch_output(
            enabled,
            "ready",
            Some(active.id),
            Some(candidate.id),
            Some(account_display_name(&candidate)),
            None,
        ))
    }

    fn apply_auto_switch(
        &self,
        enabled: bool,
        preferred_candidate_id: Option<Uuid>,
        force: bool,
    ) -> Result<AutoSwitchOutput> {
        let accounts = self.list()?.accounts;
        let active = accounts.iter().find(|account| account.is_active);
        let Some(active) = active else {
            return Ok(auto_switch_output(
                enabled,
                "waiting_for_login",
                None,
                None,
                None,
                None,
            ));
        };
        if !is_exhausted_for_switch(active.usage.as_ref()) {
            // Active may have recovered quota between check and apply.
            return Ok(auto_switch_output(
                enabled,
                "active_has_quota",
                Some(active.id),
                None,
                None,
                None,
            ));
        }

        let settings = load_settings(&self.env.app_data_dir)?;
        let now = time::OffsetDateTime::now_utc();
        let candidate = if let Some(preferred_id) = preferred_candidate_id {
            // Revalidate only the decided candidate — never re-rank a stale roster cache.
            let preferred = match self.usage(Some(preferred_id)) {
                Ok(_) => self
                    .list()?
                    .accounts
                    .into_iter()
                    .find(|account| account.id == preferred_id)
                    .filter(|candidate| {
                        candidate.id != active.id
                            && !accounts_represent_same_identity(candidate, active)
                            && !candidate.archived
                            && !candidate
                                .usage_error
                                .as_deref()
                                .is_some_and(usage_error_blocks_activation)
                            && is_usable_for_switch(candidate.usage.as_ref())
                            && !is_in_auto_switch_cooldown(&settings, candidate.id, now)
                    }),
                Err(_) => None,
            };
            // If the selected candidate changed while revalidating, use the next
            // usable cached candidate rather than reporting every account exhausted
            // and waiting for the next monitor tick.
            preferred.or_else(|| {
                best_cached_auto_switch_candidate(
                    &accounts,
                    active,
                    &settings,
                    now,
                    Some(preferred_id),
                )
            })
        } else {
            best_cached_auto_switch_candidate(&accounts, active, &settings, now, None)
        };

        let Some(candidate) = candidate else {
            return Ok(auto_switch_output(
                enabled,
                "all_accounts_exhausted",
                Some(active.id),
                None,
                None,
                Some("No eligible saved account has usable quota.".to_owned()),
            ));
        };

        let warnings = self.activation_preflight_warnings();
        if !warnings.is_empty() && !force {
            return Ok(auto_switch_output(
                enabled,
                "waiting_for_processes",
                Some(active.id),
                Some(candidate.id),
                Some(account_display_name(&candidate)),
                Some("Close Codex and ChatGPT before automatic switching.".to_owned()),
            ));
        }
        if force {
            self.activate_with_expected_active(candidate.id, true, Some(active.id))?;
        } else {
            self.activate_if_active_matches(candidate.id, active.id)?;
        }
        let _operation_lock = OperationLock::acquire(&self.env.app_data_dir)?;
        let mut settings = load_settings(&self.env.app_data_dir)?;
        settings.last_auto_switch_at = Some(now);
        settings.last_auto_switch_target = Some(candidate.id);
        save_settings(&self.env.app_data_dir, &settings)?;
        Ok(auto_switch_output(
            enabled,
            "switched",
            Some(active.id),
            Some(candidate.id),
            Some(account_display_name(&candidate)),
            None,
        ))
    }

    pub fn recover_legacy_snapshots(&self) -> Result<LegacyRecoveryOutput> {
        let _operation_lock = OperationLock::acquire(&self.env.app_data_dir)?;
        let mut recovered_accounts = 0;
        let mut imported_accounts = 0;
        let mut skipped_accounts = 0;
        for legacy_data_dir in crate::env::legacy_data_dirs()? {
            if legacy_data_dir == self.env.app_data_dir || !legacy_data_dir.exists() {
                continue;
            }
            let (recovered, imported, skipped) = self
                .repository
                .recover_legacy_snapshots(&self.env.kind, &legacy_data_dir)?;
            recovered_accounts += recovered;
            imported_accounts += imported;
            skipped_accounts += skipped;
        }
        Ok(LegacyRecoveryOutput {
            recovered_accounts,
            imported_accounts,
            skipped_accounts,
        })
    }

    pub fn list(&self) -> Result<ListOutput> {
        let accounts = self.repository.list_accounts(&self.env.kind)?;
        let live = codex::try_read_live_auth_bundle(&self.env)?;
        let active_id = live
            .as_ref()
            .and_then(|bundle| match_saved_account(&accounts, &bundle.identity))
            .map(|account| account.id);
        Ok(ListOutput {
            environment: self.env.kind.clone(),
            accounts: accounts
                .into_iter()
                .map(|account| account_view(account, active_id, None, None))
                .collect(),
        })
    }

    pub fn save_current(&self) -> Result<SaveOutput> {
        let _auth_lock = AuthLock::acquire(&self.env.app_data_dir)?;
        self.save_current_inner(true)
    }

    /// Save and back up the live session before starting device login.
    ///
    /// The existing live auth remains available for Codex to reuse a trusted
    /// session, and cancel still restores the backed-up session if login changes it.
    pub fn begin_add_account_session(&self) -> Result<()> {
        let _auth_lock = AuthLock::acquire(&self.env.app_data_dir)?;
        // Login is an explicit credential transaction, not an account switch.
        // Leave Desktop running and pause Roster background work via the marker.
        if codex::try_read_live_auth_bundle(&self.env)?.is_some() {
            self.save_current_inner(true)?;
        }
        let _operation_lock = OperationLock::acquire(&self.env.app_data_dir)?;
        codex::begin_add_account_session(&self.env)
    }

    pub fn save_added_account_session(&self) -> Result<SaveOutput> {
        let _auth_lock = AuthLock::acquire(&self.env.app_data_dir)?;
        if !codex::add_account_auth_changed(&self.env)? {
            anyhow::bail!(
                "Codex login has not written new credentials yet; finish the browser login and wait for it to complete before saving"
            );
        }
        let output = self.save_current_inner(true)?;
        let _operation_lock = OperationLock::acquire(&self.env.app_data_dir)?;
        codex::finish_add_account_session(&self.env)?;
        Ok(output)
    }

    pub fn cancel_add_account_session(&self) -> Result<()> {
        let _auth_lock = AuthLock::acquire(&self.env.app_data_dir)?;
        let _operation_lock = OperationLock::acquire(&self.env.app_data_dir)?;
        codex::cancel_add_account_session(&self.env)
    }

    pub fn add_account_session_active(&self) -> bool {
        codex::add_account_session_active(&self.env)
    }

    pub fn add_account_session_auth_changed(&self) -> Result<bool> {
        codex::add_account_auth_changed(&self.env)
    }

    /// Import one or more accounts from a JSON file.
    ///
    /// Supported formats:
    /// - Codex `auth.json` (single account)
    /// - Roster `SnapshotBlob` JSON (single account)
    /// - Plaintext Roster `BackupBundle` JSON (one or more accounts)
    pub fn import_accounts_from_json(
        &self,
        path: &std::path::Path,
        custom_label: Option<String>,
    ) -> Result<crate::model::ImportJsonOutput> {
        let bytes =
            std::fs::read(path).with_context(|| format!("failed to read {}", path.display()))?;
        let value: serde_json::Value = serde_json::from_slice(&bytes)
            .with_context(|| format!("failed to parse JSON from {}", path.display()))?;

        if looks_like_auth_json(&value) {
            let (identity, snapshot) = codex::snapshot_from_auth_json(&bytes)?;
            let _operation_lock = OperationLock::acquire(&self.env.app_data_dir)?;
            let (metadata, created) =
                self.repository
                    .save_snapshot(&self.env.kind, &identity, &snapshot)?;
            let metadata =
                if let Some(label) = custom_label.filter(|value| !value.trim().is_empty()) {
                    self.repository.set_custom_label(
                        &self.env.kind,
                        metadata.id,
                        Some(label.trim().to_owned()),
                    )?
                } else {
                    metadata
                };
            return Ok(crate::model::ImportJsonOutput {
                format: "auth_json".to_owned(),
                created: usize::from(created),
                updated: usize::from(!created),
                accounts: vec![account_view(metadata, None, None, None)],
            });
        }

        if let Ok(snapshot) = serde_json::from_value::<SnapshotBlob>(value.clone()) {
            codex::validate_snapshot(&snapshot)?;
            let identity = codex::identity_from_snapshot(&snapshot)?;
            let _operation_lock = OperationLock::acquire(&self.env.app_data_dir)?;
            let (metadata, created) =
                self.repository
                    .save_snapshot(&self.env.kind, &identity, &snapshot)?;
            let metadata =
                if let Some(label) = custom_label.filter(|value| !value.trim().is_empty()) {
                    self.repository.set_custom_label(
                        &self.env.kind,
                        metadata.id,
                        Some(label.trim().to_owned()),
                    )?
                } else {
                    metadata
                };
            return Ok(crate::model::ImportJsonOutput {
                format: "snapshot".to_owned(),
                created: usize::from(created),
                updated: usize::from(!created),
                accounts: vec![account_view(metadata, None, None, None)],
            });
        }

        if let Ok(bundle) = serde_json::from_value::<crate::backup::BackupBundle>(value) {
            if custom_label.is_some() {
                anyhow::bail!(
                    "custom labels are only supported when importing a single auth.json or snapshot"
                );
            }
            let _operation_lock = OperationLock::acquire(&self.env.app_data_dir)?;
            let before = self.repository.list_accounts(&self.env.kind)?;
            let (created, updated) = self.repository.import_backup(&self.env.kind, bundle)?;
            let after = self.repository.list_accounts(&self.env.kind)?;
            let changed_ids = after
                .iter()
                .filter(|account| {
                    before.iter().all(|previous| previous.id != account.id)
                        || before.iter().any(|previous| {
                            previous.id == account.id && previous.updated_at != account.updated_at
                        })
                })
                .map(|account| account.id)
                .collect::<HashSet<_>>();
            let accounts = after
                .into_iter()
                .filter(|account| changed_ids.contains(&account.id))
                .map(|account| account_view(account, None, None, None))
                .collect();
            return Ok(crate::model::ImportJsonOutput {
                format: "backup_bundle".to_owned(),
                created,
                updated,
                accounts,
            });
        }

        anyhow::bail!(
            "unrecognized JSON format; expected Codex auth.json, a Roster snapshot, or a plaintext Roster backup bundle"
        )
    }

    fn save_current_for_activation(&self) -> Result<SaveOutput> {
        self.save_current_inner(false)
    }

    fn save_current_inner(&self, write_backup: bool) -> Result<SaveOutput> {
        let _operation_lock = OperationLock::acquire(&self.env.app_data_dir)?;
        let live = codex::read_live_auth_bundle(&self.env).with_context(|| {
            format!(
                "no live Codex auth bundle found at {}",
                self.env.codex_root.display()
            )
        })?;
        let (metadata, created) = if write_backup {
            self.repository
                .save_snapshot(&self.env.kind, &live.identity, &live.snapshot)?
        } else {
            self.repository.save_snapshot_without_backup(
                &self.env.kind,
                &live.identity,
                &live.snapshot,
            )?
        };
        Ok(SaveOutput {
            account: account_view(metadata.clone(), Some(metadata.id), None, None),
            action: if created {
                SaveAction::Created
            } else {
                SaveAction::Refreshed
            },
        })
    }

    pub fn activate(&self, account_id: Uuid) -> Result<ActivateOutput> {
        self.activate_with_running_policy(account_id, false)
    }

    pub fn validate_activation_target(&self, account_id: Uuid) -> Result<()> {
        let _ = self.load_activation_target(account_id)?;
        Ok(())
    }

    pub fn activate_with_running_policy(
        &self,
        account_id: Uuid,
        force_running: bool,
    ) -> Result<ActivateOutput> {
        self.activate_with_expected_active(account_id, force_running, None)
    }

    fn activate_if_active_matches(
        &self,
        account_id: Uuid,
        expected_active_id: Uuid,
    ) -> Result<ActivateOutput> {
        self.activate_with_expected_active(account_id, false, Some(expected_active_id))
    }

    fn activate_with_expected_active(
        &self,
        account_id: Uuid,
        force_running: bool,
        expected_active_id: Option<Uuid>,
    ) -> Result<ActivateOutput> {
        let started = Instant::now();
        let _auth_lock = AuthLock::acquire(&self.env.app_data_dir)?;
        let initial_warnings = activation_process_warnings();
        ensure_activation_processes_stopped(&initial_warnings)?;
        self.refresh_current_saved_account_before_activation()?;
        let refreshed_current_at = Instant::now();
        let _operation_lock = OperationLock::acquire(&self.env.app_data_dir)?;
        let acquired_lock_at = Instant::now();
        let warnings = activation_process_warnings();
        ensure_activation_processes_stopped(&warnings)?;
        let scanned_processes_at = Instant::now();
        if let Some(expected_active_id) = expected_active_id {
            let accounts = self.repository.list_accounts(&self.env.kind)?;
            let live = codex::try_read_live_auth_bundle(&self.env)?;
            let active_id = live
                .as_ref()
                .and_then(|bundle| match_saved_account(&accounts, &bundle.identity))
                .map(|account| account.id);
            if active_id != Some(expected_active_id) {
                anyhow::bail!("automatic switch was superseded because the active account changed");
            }
        }
        let (snapshot, snapshot_identity, restore_identity) =
            self.load_activation_target(account_id)?;
        // Preserve the legacy ownership model: restore the saved auth document
        // unchanged and let Codex's official auth manager refresh it in place.
        // Roster must never consume an inactive account's rotating refresh token.
        let loaded_target_at = Instant::now();
        let verify_stable = should_verify_activation_stability(force_running, &warnings);
        let verify_retries = 4;
        let verify_delay = Duration::from_millis(250);
        codex::restore_snapshot_with_retry(
            &self.env,
            &snapshot,
            &restore_identity,
            verify_stable,
            verify_retries,
            verify_delay,
        )
        .context("failed to restore the selected account snapshot")?;
        let restored_snapshot_at = Instant::now();
        let metadata = self
            .repository
            .sync_activated_account(&self.env.kind, account_id, &snapshot_identity)
            .context("activated live auth but failed to update local metadata")?;
        let synced_metadata_at = Instant::now();
        if std::env::var_os("CODEX_ROSTER_PROFILE_SWITCH").is_some() {
            eprintln!(
                "activation profile: save-current={}ms lock={}ms process-scan={}ms load-target={}ms restore={}ms metadata={}ms total={}ms",
                refreshed_current_at.duration_since(started).as_millis(),
                acquired_lock_at
                    .duration_since(refreshed_current_at)
                    .as_millis(),
                scanned_processes_at
                    .duration_since(acquired_lock_at)
                    .as_millis(),
                loaded_target_at
                    .duration_since(scanned_processes_at)
                    .as_millis(),
                restored_snapshot_at
                    .duration_since(loaded_target_at)
                    .as_millis(),
                synced_metadata_at
                    .duration_since(restored_snapshot_at)
                    .as_millis(),
                synced_metadata_at.duration_since(started).as_millis(),
            );
        }
        Ok(ActivateOutput {
            account: account_view(metadata, Some(account_id), None, None),
            warnings,
        })
    }

    fn refresh_current_saved_account_before_activation(&self) -> Result<()> {
        let saved_accounts = self.repository.list_accounts(&self.env.kind)?;
        let Some(live) = codex::try_read_live_auth_bundle(&self.env)? else {
            return Ok(());
        };
        let Some(_current_saved) = match_saved_account(&saved_accounts, &live.identity) else {
            return Ok(());
        };
        self.save_current_for_activation()
            .context("could not preserve the active Codex session before switching accounts")?;
        Ok(())
    }

    fn load_activation_target(
        &self,
        account_id: Uuid,
    ) -> Result<(SnapshotBlob, DisplayIdentity, DisplayIdentity)> {
        let (metadata, snapshot) = self.repository.load_snapshot(&self.env.kind, account_id)?;
        let expected_identity = saved_identity(&metadata);
        let snapshot_identity = codex::identity_from_snapshot(&snapshot)?;
        let restore_identity = if expected_identity.subject.is_some() {
            if !subject_bound_identity_matches(&expected_identity, &snapshot_identity) {
                anyhow::bail!(
                    "saved snapshot identity does not match the selected account: expected {:?}, got {:?}",
                    expected_identity,
                    snapshot_identity
                );
            }
            expected_identity.clone()
        } else {
            snapshot_identity.clone()
        };
        Ok((snapshot, snapshot_identity, restore_identity))
    }

    pub fn activation_preflight_warnings(&self) -> Vec<RunningCodexProcess> {
        crate::process::detect_running_codex_processes()
    }

    pub fn refresh_saved_usage_cache(&self) -> Result<()> {
        let accounts = self.repository.list_accounts(&self.env.kind)?;
        for account in accounts {
            let _ = self.usage(Some(account.id));
        }
        Ok(())
    }

    /// Refresh usage for every saved account whose cached quota is stale, so the
    /// whole roster picks up an off-schedule ChatGPT reset without waiting for a
    /// manual refresh or an auto-switch decision. Accounts that still have quota
    /// in every window (fresh cache) are skipped to avoid needless network and
    /// token churn; accounts that need a fresh login are skipped because they
    /// cannot be refreshed without the user.
    pub fn refresh_stale_saved_usage(&self) -> Result<()> {
        let accounts = self.repository.list_accounts(&self.env.kind)?;
        let now = time::OffsetDateTime::now_utc();
        for account in accounts {
            if account.archived {
                continue;
            }
            if account
                .cached_usage_error
                .as_deref()
                .is_some_and(usage_error_blocks_activation)
            {
                continue;
            }
            if cached_usage_is_fresh(account.cached_usage.as_ref(), now) {
                continue;
            }
            let _ = self.usage(Some(account.id));
        }
        Ok(())
    }

    /// Refresh usage for the roster the way a GUI poll needs it: always re-query
    /// the live/active account so its own reset shows promptly, then sweep every
    /// stale saved account so an off-schedule ChatGPT reset surfaces across the
    /// whole list. GUI frontends (macOS/Windows) call short-lived CLI processes
    /// and never host the background worker, so this gives them one entry point.
    pub fn refresh_usage_for_display(&self) -> Result<()> {
        let _ = self.usage(None);
        self.refresh_stale_saved_usage()
    }

    pub fn token_usage_summary(&self) -> Result<TokenUsageSummaryOutput> {
        crate::token_usage::summarize_session_tokens(
            &self.env.codex_root.join("sessions"),
            time::OffsetDateTime::now_local().unwrap_or_else(|_| time::OffsetDateTime::now_utc()),
        )
    }

    pub fn set_account_label(&self, account_id: Uuid, custom_label: Option<String>) -> Result<()> {
        let _operation_lock = OperationLock::acquire(&self.env.app_data_dir)?;
        self.repository
            .set_custom_label(&self.env.kind, account_id, custom_label)?;
        Ok(())
    }

    pub fn set_account_archived(&self, account_id: Uuid, archived: bool) -> Result<()> {
        let _operation_lock = OperationLock::acquire(&self.env.app_data_dir)?;
        self.repository
            .set_archived(&self.env.kind, account_id, archived)?;
        Ok(())
    }

    pub fn export_backup(&self, path: &std::path::Path, password: &str) -> Result<usize> {
        let _operation_lock = OperationLock::acquire(&self.env.app_data_dir)?;
        let backup = self.repository.export_backup(&self.env.kind)?;
        let count = backup.accounts.len();
        write_encrypted(path, &backup, password)?;
        Ok(count)
    }

    pub fn import_backup(&self, path: &std::path::Path, password: &str) -> Result<(usize, usize)> {
        let _operation_lock = OperationLock::acquire(&self.env.app_data_dir)?;
        self.repository
            .import_backup(&self.env.kind, read_encrypted(path, password)?)
    }

    pub fn restore_latest_account_list_backup(&self) -> Result<usize> {
        let _operation_lock = OperationLock::acquire(&self.env.app_data_dir)?;
        self.repository.restore_latest_account_list_backup()
    }

    pub fn restore_latest_full_backup(&self) -> Result<usize> {
        let _operation_lock = OperationLock::acquire(&self.env.app_data_dir)?;
        self.repository.restore_latest_full_backup(&self.env.kind)
    }

    pub fn create_automatic_full_backup(&self) -> Result<usize> {
        let _operation_lock = OperationLock::acquire(&self.env.app_data_dir)?;
        self.repository.create_automatic_full_backup(&self.env.kind)
    }

    pub fn usage(&self, account_id: Option<Uuid>) -> Result<UsageOutput> {
        if codex::add_account_session_active(&self.env) {
            anyhow::bail!(
                "account login is in progress; quota refresh is paused until the new credential is saved or cancelled"
            );
        }
        let _auth_lock = AuthLock::acquire(&self.env.app_data_dir)?;
        self.usage_with_auth_lock(account_id)
    }

    fn usage_with_auth_lock(&self, account_id: Option<Uuid>) -> Result<UsageOutput> {
        // Keep the account-state lock off the network path. AuthLock still
        // serializes the full token transaction across processes so single-use
        // refresh tokens cannot race.
        match account_id {
            Some(account_id) => {
                // OAuth refresh tokens rotate. Refreshing a copy of the active
                // account would invalidate the token still present in Codex's
                // live auth.json, so always update the live bundle instead.
                if self.is_live_saved_account(account_id)? {
                    return self.usage_with_auth_lock(None);
                }
                // A snapshot that no longer decrypts must surface as an error on
                // the account, not silently keep stale quota forever. Record it
                // so the roster can distinguish local recovery from a real
                // server-side sign-in requirement.
                let (snapshot, _, _) = match self.load_activation_target(account_id) {
                    Ok(target) => target,
                    Err(error) => {
                        let _operation_lock = OperationLock::acquire(&self.env.app_data_dir)?;
                        let _ = self.repository.record_usage_error(
                            &self.env.kind,
                            account_id,
                            usage_error_message(&error),
                        );
                        return Err(error);
                    }
                };
                let target = usage_target_from_snapshot(
                    self.env.kind.clone(),
                    snapshot,
                    UsageSource::SavedAccessToken,
                    false,
                )?;
                match fetch_usage(target) {
                    Ok((output, refreshed_snapshot)) => {
                        let _operation_lock = OperationLock::acquire(&self.env.app_data_dir)?;
                        self.repository.replace_snapshot_without_backup(
                            &self.env.kind,
                            account_id,
                            &output.account,
                            &refreshed_snapshot,
                            Some(output.usage.clone()),
                        )?;
                        Ok(output)
                    }
                    Err(error) => {
                        self.persist_rotated_saved_auth(account_id, &error)?;
                        let _operation_lock = OperationLock::acquire(&self.env.app_data_dir)?;
                        let _ = self.repository.record_usage_error(
                            &self.env.kind,
                            account_id,
                            usage_error_message(error.error()),
                        );
                        Err(error.into_error())
                    }
                }
            }
            None => {
                let live = codex::read_live_auth_bundle(&self.env).with_context(|| {
                    format!(
                        "no live Codex auth bundle found at {}",
                        self.env.codex_root.display()
                    )
                })?;
                let live_identity = live.identity.clone();
                let live_snapshot = live.snapshot.clone();
                // The live refresh token belongs exclusively to Codex. Process
                // detection is inherently racy: Codex can start after the scan
                // and refresh the same single-use token while Roster is doing so.
                // Only read quota with the current access token here. If it has
                // expired, retain the last verified quota until Codex refreshes
                // its own live session instead of risking a surprise logout.
                let allow_refresh = ALLOW_LIVE_TOKEN_REFRESH;
                let target = usage_target_from_snapshot(
                    self.env.kind.clone(),
                    live.snapshot,
                    UsageSource::LiveAccessToken,
                    allow_refresh,
                )?;
                match fetch_usage(target) {
                    Ok((output, refreshed_snapshot)) => {
                        let _operation_lock = OperationLock::acquire(&self.env.app_data_dir)?;
                        let persisted = self.write_back_live_auth_if_unchanged(
                            &live_snapshot,
                            &refreshed_snapshot,
                            &output.account,
                        )?;
                        if let Some(account_id) = self.saved_account_id_for_identity(&live_identity)
                        {
                            let snapshot_for_repo = self.snapshot_safe_for_saved_live_copy(
                                &live_snapshot,
                                &refreshed_snapshot,
                                persisted,
                            );
                            self.repository.replace_snapshot_without_backup(
                                &self.env.kind,
                                account_id,
                                &output.account,
                                &snapshot_for_repo,
                                Some(output.usage.clone()),
                            )?;
                        }
                        Ok(output)
                    }
                    Err(error) => {
                        self.persist_rotated_live_auth(&live_identity, &live_snapshot, &error)?;
                        let _operation_lock = OperationLock::acquire(&self.env.app_data_dir)?;
                        self.record_usage_error_for_identity(&live_identity, error.error());
                        Err(error.into_error())
                    }
                }
            }
        }
    }

    fn persist_rotated_saved_auth(&self, account_id: Uuid, error: &FetchUsageError) -> Result<()> {
        let Some(refreshed_snapshot) = &error.refreshed_snapshot else {
            return Ok(());
        };
        let (current_metadata, _) = self.repository.load_snapshot(&self.env.kind, account_id)?;
        let identity = codex::identity_from_snapshot(refreshed_snapshot)?;
        let _operation_lock = OperationLock::acquire(&self.env.app_data_dir)?;
        self.repository.replace_snapshot_without_backup(
            &self.env.kind,
            account_id,
            &identity,
            refreshed_snapshot,
            current_metadata.cached_usage,
        )?;
        Ok(())
    }

    fn persist_rotated_live_auth(
        &self,
        live_identity: &DisplayIdentity,
        previous_live_snapshot: &SnapshotBlob,
        error: &FetchUsageError,
    ) -> Result<()> {
        let Some(refreshed_snapshot) = &error.refreshed_snapshot else {
            return Ok(());
        };
        let identity = codex::identity_from_snapshot(refreshed_snapshot)
            .unwrap_or_else(|_| live_identity.clone());
        let _operation_lock = OperationLock::acquire(&self.env.app_data_dir)?;
        let persisted = self.write_back_live_auth_if_unchanged(
            previous_live_snapshot,
            refreshed_snapshot,
            &identity,
        )?;
        if let Some(account_id) = self.saved_account_id_for_identity(live_identity) {
            let cached_usage =
                self.repository
                    .list_accounts(&self.env.kind)
                    .ok()
                    .and_then(|accounts| {
                        accounts
                            .into_iter()
                            .find(|account| account.id == account_id)
                            .and_then(|account| account.cached_usage)
                    });
            let snapshot_for_repo = self.snapshot_safe_for_saved_live_copy(
                previous_live_snapshot,
                refreshed_snapshot,
                persisted,
            );
            self.repository.replace_snapshot_without_backup(
                &self.env.kind,
                account_id,
                &identity,
                &snapshot_for_repo,
                cached_usage,
            )?;
        }
        Ok(())
    }

    /// Prefer tokens that actually landed in `~/.codex`. Never keep a Roster-only
    /// rotated refresh token when Desktop already moved the live session.
    fn snapshot_safe_for_saved_live_copy(
        &self,
        previous_live_snapshot: &SnapshotBlob,
        refreshed_snapshot: &SnapshotBlob,
        persisted_to_live: bool,
    ) -> SnapshotBlob {
        if persisted_to_live || refreshed_snapshot == previous_live_snapshot {
            return refreshed_snapshot.clone();
        }
        match codex::try_read_live_auth_bundle(&self.env) {
            Ok(Some(live)) => live.snapshot,
            _ => previous_live_snapshot.clone(),
        }
    }

    fn write_back_live_auth_if_unchanged(
        &self,
        previous_live_snapshot: &SnapshotBlob,
        refreshed_snapshot: &SnapshotBlob,
        identity: &DisplayIdentity,
    ) -> Result<bool> {
        if refreshed_snapshot == previous_live_snapshot {
            return Ok(true);
        }
        if live_bundle_still_matches_snapshot(&self.env, previous_live_snapshot) {
            codex::restore_snapshot(&self.env, refreshed_snapshot, identity, false)
                .context("refreshed live auth but failed to update local auth files")?;
            return Ok(true);
        }
        Ok(false)
    }

    fn saved_account_id_for_identity(&self, identity: &DisplayIdentity) -> Option<Uuid> {
        self.repository
            .list_accounts(&self.env.kind)
            .ok()
            .and_then(|accounts| match_saved_account(&accounts, identity).map(|account| account.id))
    }

    pub(crate) fn is_live_saved_account(&self, account_id: Uuid) -> Result<bool> {
        let Some(live) = codex::try_read_live_auth_bundle(&self.env)? else {
            return Ok(false);
        };
        let accounts = self.repository.list_accounts(&self.env.kind)?;
        Ok(match_saved_account(&accounts, &live.identity)
            .is_some_and(|account| account.id == account_id))
    }

    fn record_usage_error_for_identity(&self, identity: &DisplayIdentity, error: &anyhow::Error) {
        let Ok(accounts) = self.repository.list_accounts(&self.env.kind) else {
            return;
        };
        let Some(account) = match_saved_account(&accounts, identity) else {
            return;
        };
        let _ = self.repository.record_usage_error(
            &self.env.kind,
            account.id,
            usage_error_message(error),
        );
    }

    pub fn delete(&self, account_id: Uuid) -> Result<DeleteOutput> {
        let _operation_lock = OperationLock::acquire(&self.env.app_data_dir)?;
        self.repository
            .delete_snapshot(&self.env.kind, account_id)?;
        Ok(DeleteOutput {
            deleted_account_id: account_id,
        })
    }
}

fn ensure_activation_processes_stopped(warnings: &[RunningCodexProcess]) -> Result<()> {
    if warnings.is_empty() {
        return Ok(());
    }
    anyhow::bail!(
        "account switch blocked because {} Codex process(es) are still running; the current session was left unchanged",
        warnings.len()
    )
}

#[cfg(not(test))]
fn activation_process_warnings() -> Vec<RunningCodexProcess> {
    crate::process::detect_running_codex_processes()
}

#[cfg(test)]
fn activation_process_warnings() -> Vec<RunningCodexProcess> {
    Vec::new()
}

fn live_bundle_still_matches_snapshot(env: &AppEnv, snapshot: &SnapshotBlob) -> bool {
    for attempt in 0..3 {
        if codex::live_bundle_matches_snapshot(env, snapshot).unwrap_or(false) {
            return true;
        }
        if attempt < 2 {
            std::thread::sleep(Duration::from_millis(25));
        }
    }
    false
}

fn looks_like_auth_json(value: &serde_json::Value) -> bool {
    value
        .get("tokens")
        .and_then(|tokens| tokens.get("access_token"))
        .and_then(|token| token.as_str())
        .is_some_and(|token| !token.is_empty())
}

fn auto_switch_output(
    enabled: bool,
    status: &str,
    active_account_id: Option<Uuid>,
    candidate_account_id: Option<Uuid>,
    candidate_display_name: Option<String>,
    detail: Option<String>,
) -> AutoSwitchOutput {
    AutoSwitchOutput {
        enabled,
        status: status.to_owned(),
        active_account_id,
        candidate_account_id,
        candidate_display_name,
        detail,
    }
}

fn quota_windows(
    usage: Option<&AccountUsageView>,
) -> impl Iterator<Item = &crate::model::UsageWindowView> {
    usage
        .into_iter()
        .flat_map(|usage| [usage.weekly.as_ref(), usage.five_hour.as_ref()])
        .flatten()
}

fn is_exhausted_for_switch(usage: Option<&AccountUsageView>) -> bool {
    quota_windows(usage).any(|window| window.remaining_percent == 0)
}

fn is_usable_for_switch(usage: Option<&AccountUsageView>) -> bool {
    let windows = quota_windows(usage).collect::<Vec<_>>();
    !windows.is_empty() && windows.iter().all(|window| window.remaining_percent > 0)
}

fn switch_quota_score(usage: Option<&AccountUsageView>) -> u8 {
    quota_windows(usage)
        .map(|window| window.remaining_percent)
        .min()
        .unwrap_or_default()
}

fn is_in_auto_switch_cooldown(
    settings: &crate::settings::AppSettings,
    candidate_id: Uuid,
    now: time::OffsetDateTime,
) -> bool {
    settings.last_auto_switch_target == Some(candidate_id)
        && settings
            .last_auto_switch_at
            .is_some_and(|last_switch| now - last_switch < time::Duration::minutes(5))
}

fn best_cached_auto_switch_candidate(
    accounts: &[AccountView],
    active: &AccountView,
    settings: &crate::settings::AppSettings,
    now: time::OffsetDateTime,
    excluded_id: Option<Uuid>,
) -> Option<AccountView> {
    accounts
        .iter()
        .filter(|candidate| {
            candidate.id != active.id
                && !accounts_represent_same_identity(candidate, active)
                && Some(candidate.id) != excluded_id
                && !candidate.archived
                && !candidate
                    .usage_error
                    .as_deref()
                    .is_some_and(usage_error_blocks_activation)
                && is_usable_for_switch(candidate.usage.as_ref())
                && !is_in_auto_switch_cooldown(settings, candidate.id, now)
        })
        .max_by_key(|candidate| switch_quota_score(candidate.usage.as_ref()))
        .cloned()
}

/// A legacy/imported roster can contain duplicate records for one OpenAI
/// account. A different record ID must never make auto-switch restore the same
/// exhausted subject/email.
fn accounts_represent_same_identity(left: &AccountView, right: &AccountView) -> bool {
    match (&left.subject, &right.subject) {
        (Some(left_subject), Some(right_subject)) => left_subject == right_subject,
        _ => left.email.eq_ignore_ascii_case(&right.email),
    }
}

fn cached_usage_is_fresh(
    usage: Option<&crate::model::AccountUsageView>,
    now: time::OffsetDateTime,
) -> bool {
    usage.is_some_and(|usage| {
        // An exhausted window is never treated as "fresh" on the strength of a
        // future reset_at. ChatGPT can lift a limit off-schedule (mass reset),
        // and trusting reset_at would keep re-querying suppressed until the old
        // scheduled time, hiding restored quota. Only accounts that still have
        // quota in every reported window skip the refetch.
        now - usage.fetched_at < time::Duration::minutes(15)
            && quota_windows(Some(usage)).all(|window| window.remaining_percent > 0)
    })
}

fn account_display_name(account: &AccountView) -> String {
    account
        .custom_label
        .as_deref()
        .filter(|label| !label.is_empty())
        .or(account.name.as_deref().filter(|name| !name.is_empty()))
        .unwrap_or(&account.email)
        .to_owned()
}

#[cfg(test)]
mod tests {
    use base64::Engine;
    use tempfile::tempdir;

    use super::*;
    use crate::codex::auth_json_fixture;
    use time::OffsetDateTime;

    use crate::model::SnapshotFile;
    use crate::model::{
        AccountUsageView, DisplayIdentity, EnvironmentKind, UsageSource, UsageWindowView,
    };
    use crate::secrets::test_support::MemorySecretStore;

    #[test]
    fn activation_never_forces_through_running_codex_processes() {
        let warnings = vec![RunningCodexProcess {
            pid: 42,
            executable: "codex".to_owned(),
            role: "app-server".to_owned(),
            summary: None,
        }];

        let error = ensure_activation_processes_stopped(&warnings).expect_err("must block");
        assert!(format!("{error:#}").contains("current session was left unchanged"));
    }

    #[test]
    fn list_marks_active_account() {
        let temp = tempdir().expect("tempdir");
        let env = AppEnv {
            kind: EnvironmentKind::Linux,
            home_dir: temp.path().to_path_buf(),
            codex_root: temp.path().join(".codex"),
            app_data_dir: temp.path().join("app"),
        };
        std::fs::create_dir_all(&env.codex_root).expect("codex root");
        std::fs::write(
            env.codex_root.join("auth.json"),
            auth_json_fixture("active@example.com", "sub-1", Some("pro")),
        )
        .expect("auth");
        std::fs::write(env.codex_root.join("cap_sid"), "sid").expect("cap");
        let repo = SnapshotRepository::new(&env.app_data_dir, MemorySecretStore::default());
        let saved = repo
            .save_snapshot(
                &env.kind,
                &DisplayIdentity {
                    email: "active@example.com".to_owned(),
                    subject: Some("sub-1".to_owned()),
                    name: None,
                    plan_label: Some("Pro".to_owned()),
                },
                &SnapshotBlob {
                    schema_version: 1,
                    files: vec![],
                },
            )
            .expect("save")
            .0;
        let app = App::new(env, repo);
        let output = app.list().expect("list");
        assert_eq!(output.accounts.len(), 1);
        assert!(output.accounts[0].is_active);
        assert!(
            app.is_live_saved_account(saved.id)
                .expect("active account check")
        );
    }

    #[test]
    fn save_added_account_rejects_unchanged_live_credentials() {
        let temp = tempdir().expect("tempdir");
        let env = AppEnv {
            kind: EnvironmentKind::Linux,
            home_dir: temp.path().to_path_buf(),
            codex_root: temp.path().join(".codex"),
            app_data_dir: temp.path().join("app"),
        };
        std::fs::create_dir_all(&env.codex_root).expect("codex root");
        std::fs::write(
            env.codex_root.join("auth.json"),
            auth_json_fixture("person@example.com", "sub-1", Some("pro")),
        )
        .expect("auth");
        let app = App::new(
            env,
            SnapshotRepository::new(temp.path(), MemorySecretStore::default()),
        );

        app.begin_add_account_session().expect("begin login");
        let error = app
            .save_added_account_session()
            .expect_err("unchanged auth must not be accepted");

        assert!(format!("{error:#}").contains("has not written new credentials"));
        app.cancel_add_account_session().expect("cancel");
    }

    #[test]
    fn auto_switch_requires_every_reported_window_to_be_usable() {
        let usage = AccountUsageView {
            source: UsageSource::SavedAccessToken,
            fetched_at: OffsetDateTime::now_utc(),
            five_hour: Some(UsageWindowView {
                used_percent: 100,
                remaining_percent: 0,
                reset_at: OffsetDateTime::now_utc(),
            }),
            weekly: Some(UsageWindowView {
                used_percent: 10,
                remaining_percent: 90,
                reset_at: OffsetDateTime::now_utc(),
            }),
            credits: None,
        };

        assert!(is_exhausted_for_switch(Some(&usage)));
        assert!(!is_usable_for_switch(Some(&usage)));
    }

    #[test]
    fn auto_switch_does_nothing_when_disabled() {
        let temp = tempdir().expect("tempdir");
        let env = AppEnv {
            kind: EnvironmentKind::Linux,
            home_dir: temp.path().to_path_buf(),
            codex_root: temp.path().join(".codex"),
            app_data_dir: temp.path().join("app"),
        };
        let app = App::new(
            env.clone(),
            SnapshotRepository::new(&env.app_data_dir, MemorySecretStore::default()),
        );

        let output = app.auto_switch(false).expect("disabled auto-switch");

        assert!(!output.enabled);
        assert_eq!(output.status, "disabled");
    }

    #[test]
    fn imports_account_from_auth_json_file() {
        let temp = tempdir().expect("tempdir");
        let env = AppEnv {
            kind: EnvironmentKind::Linux,
            home_dir: temp.path().to_path_buf(),
            codex_root: temp.path().join(".codex"),
            app_data_dir: temp.path().join("app"),
        };
        let auth_path = temp.path().join("import-auth.json");
        std::fs::write(
            &auth_path,
            auth_json_fixture("json-import@example.com", "sub-json", Some("plus")),
        )
        .expect("write auth json");
        let app = App::new(
            env.clone(),
            SnapshotRepository::new(&env.app_data_dir, MemorySecretStore::default()),
        );

        let output = app
            .import_accounts_from_json(&auth_path, Some("Từ JSON".to_owned()))
            .expect("import");

        assert_eq!(output.format, "auth_json");
        assert_eq!(output.created, 1);
        assert_eq!(output.updated, 0);
        assert_eq!(output.accounts.len(), 1);
        assert_eq!(output.accounts[0].email, "json-import@example.com");
        assert_eq!(output.accounts[0].custom_label.as_deref(), Some("Từ JSON"));

        let again = app
            .import_accounts_from_json(&auth_path, None)
            .expect("reimport");
        assert_eq!(again.created, 0);
        assert_eq!(again.updated, 1);
        assert_eq!(app.list().expect("list").accounts.len(), 1);
    }

    #[test]
    fn cached_exhausted_usage_is_stale_once_the_window_resets() {
        let now = OffsetDateTime::now_utc();
        let usage = AccountUsageView {
            source: UsageSource::SavedAccessToken,
            fetched_at: now,
            five_hour: Some(UsageWindowView {
                used_percent: 100,
                remaining_percent: 0,
                reset_at: now - time::Duration::minutes(1),
            }),
            weekly: None,
            credits: None,
        };

        assert!(!cached_usage_is_fresh(Some(&usage), now));
    }

    #[test]
    fn cached_exhausted_usage_is_stale_even_before_the_scheduled_reset() {
        // Guards against ChatGPT mass resets that lift a limit off-schedule: an
        // exhausted window must be refetched, not trusted until its old reset_at.
        let now = OffsetDateTime::now_utc();
        let usage = AccountUsageView {
            source: UsageSource::SavedAccessToken,
            fetched_at: now,
            five_hour: Some(UsageWindowView {
                used_percent: 100,
                remaining_percent: 0,
                reset_at: now + time::Duration::hours(48),
            }),
            weekly: None,
            credits: None,
        };

        assert!(!cached_usage_is_fresh(Some(&usage), now));
    }

    #[test]
    fn cached_usage_with_quota_stays_fresh_within_window() {
        let now = OffsetDateTime::now_utc();
        let usage = AccountUsageView {
            source: UsageSource::SavedAccessToken,
            fetched_at: now - time::Duration::minutes(5),
            five_hour: Some(UsageWindowView {
                used_percent: 40,
                remaining_percent: 60,
                reset_at: now + time::Duration::hours(1),
            }),
            weekly: None,
            credits: None,
        };

        assert!(cached_usage_is_fresh(Some(&usage), now));
    }

    #[test]
    fn list_keeps_saved_account_when_live_account_is_unsaved() {
        let temp = tempdir().expect("tempdir");
        let env = AppEnv {
            kind: EnvironmentKind::Linux,
            home_dir: temp.path().to_path_buf(),
            codex_root: temp.path().join(".codex"),
            app_data_dir: temp.path().join("app"),
        };
        std::fs::create_dir_all(&env.codex_root).expect("codex root");
        std::fs::write(
            env.codex_root.join("auth.json"),
            auth_json_fixture("current@example.com", "sub-2", Some("plus")),
        )
        .expect("auth");
        std::fs::write(env.codex_root.join("cap_sid"), "sid-current").expect("cap");
        let repo = SnapshotRepository::new(&env.app_data_dir, MemorySecretStore::default());
        repo.save_snapshot(
            &env.kind,
            &DisplayIdentity {
                email: "saved@example.com".to_owned(),
                subject: Some("sub-1".to_owned()),
                name: None,
                plan_label: Some("Pro".to_owned()),
            },
            &SnapshotBlob {
                schema_version: 1,
                files: vec![],
            },
        )
        .expect("save");
        let app = App::new(env, repo);
        let output = app.list().expect("list");
        assert_eq!(output.accounts.len(), 1);
        assert_eq!(output.accounts[0].email, "saved@example.com");
        assert!(!output.accounts[0].is_active);
    }

    #[test]
    fn list_surfaces_cached_usage_error() {
        let temp = tempdir().expect("tempdir");
        let env = AppEnv {
            kind: EnvironmentKind::Linux,
            home_dir: temp.path().to_path_buf(),
            codex_root: temp.path().join(".codex"),
            app_data_dir: temp.path().join("app"),
        };
        let repo = SnapshotRepository::new(&env.app_data_dir, MemorySecretStore::default());
        let saved = repo
            .save_snapshot(
                &env.kind,
                &DisplayIdentity {
                    email: "expired@example.com".to_owned(),
                    subject: Some("sub-1".to_owned()),
                    name: None,
                    plan_label: Some("Pro".to_owned()),
                },
                &SnapshotBlob {
                    schema_version: 1,
                    files: vec![],
                },
            )
            .expect("save")
            .0;
        repo.replace_snapshot(
            &env.kind,
            saved.id,
            &DisplayIdentity {
                email: "expired@example.com".to_owned(),
                subject: Some("sub-1".to_owned()),
                name: None,
                plan_label: Some("Pro".to_owned()),
            },
            &SnapshotBlob {
                schema_version: 1,
                files: vec![],
            },
            Some(AccountUsageView {
                source: UsageSource::SavedAccessToken,
                fetched_at: OffsetDateTime::UNIX_EPOCH,
                five_hour: None,
                weekly: Some(UsageWindowView {
                    used_percent: 0,
                    remaining_percent: 100,
                    reset_at: OffsetDateTime::UNIX_EPOCH,
                }),
                credits: None,
            }),
        )
        .expect("replace");
        repo.record_usage_error(
            &env.kind,
            saved.id,
            "Login required: Codex auth expired or was logged out.".to_owned(),
        )
        .expect("record usage error");

        let app = App::new(env, repo);
        let output = app.list().expect("list");

        assert_eq!(
            output.accounts[0].usage_error.as_deref(),
            Some("Login required: Codex auth expired or was logged out.")
        );
        assert!(output.accounts[0].usage.is_none());
    }

    #[test]
    fn list_keeps_cached_usage_for_transient_usage_error() {
        let temp = tempdir().expect("tempdir");
        let env = AppEnv {
            kind: EnvironmentKind::Linux,
            home_dir: temp.path().to_path_buf(),
            codex_root: temp.path().join(".codex"),
            app_data_dir: temp.path().join("app"),
        };
        let repo = SnapshotRepository::new(&env.app_data_dir, MemorySecretStore::default());
        let identity = DisplayIdentity {
            email: "person@example.com".to_owned(),
            subject: Some("sub-1".to_owned()),
            name: None,
            plan_label: Some("Pro".to_owned()),
        };
        let snapshot = SnapshotBlob {
            schema_version: 1,
            files: vec![],
        };
        let saved = repo
            .save_snapshot(&env.kind, &identity, &snapshot)
            .expect("save")
            .0;
        repo.replace_snapshot(
            &env.kind,
            saved.id,
            &identity,
            &snapshot,
            Some(AccountUsageView {
                source: UsageSource::SavedAccessToken,
                fetched_at: OffsetDateTime::UNIX_EPOCH,
                five_hour: None,
                weekly: Some(UsageWindowView {
                    used_percent: 10,
                    remaining_percent: 90,
                    reset_at: OffsetDateTime::UNIX_EPOCH,
                }),
                credits: None,
            }),
        )
        .expect("replace");
        repo.record_usage_error(
            &env.kind,
            saved.id,
            "Usage unavailable: failed to query Codex usage".to_owned(),
        )
        .expect("record usage error");

        let app = App::new(env, repo);
        let output = app.list().expect("list");

        assert!(output.accounts[0].usage.is_some());
        assert_eq!(
            output.accounts[0].usage_error.as_deref(),
            Some("Usage unavailable: failed to query Codex usage")
        );
    }

    #[test]
    fn subject_bound_identity_requires_matching_subject() {
        let expected = DisplayIdentity {
            email: "person@example.com".to_owned(),
            subject: Some("sub-1".to_owned()),
            name: Some("Tester".to_owned()),
            plan_label: Some("Pro".to_owned()),
        };
        let missing_subject = DisplayIdentity {
            email: "person@example.com".to_owned(),
            subject: None,
            name: Some("Tester".to_owned()),
            plan_label: Some("Pro".to_owned()),
        };
        let wrong_subject = DisplayIdentity {
            email: "person@example.com".to_owned(),
            subject: Some("sub-2".to_owned()),
            name: Some("Tester".to_owned()),
            plan_label: Some("Pro".to_owned()),
        };
        let matching_subject = DisplayIdentity {
            email: "other@example.com".to_owned(),
            subject: Some("sub-1".to_owned()),
            name: Some("Tester".to_owned()),
            plan_label: Some("Pro".to_owned()),
        };
        assert!(!subject_bound_identity_matches(&expected, &missing_subject));
        assert!(!subject_bound_identity_matches(&expected, &wrong_subject));
        assert!(subject_bound_identity_matches(&expected, &matching_subject));
    }

    #[test]
    fn activate_returns_refreshed_identity_after_subject_stable_restore() {
        let temp = tempdir().expect("tempdir");
        let env = AppEnv {
            kind: EnvironmentKind::Linux,
            home_dir: temp.path().to_path_buf(),
            codex_root: temp.path().join(".codex"),
            app_data_dir: temp.path().join("app"),
        };
        std::fs::create_dir_all(&env.codex_root).expect("codex root");
        std::fs::write(
            env.codex_root.join("auth.json"),
            auth_json_fixture("current@example.com", "sub-current", Some("pro")),
        )
        .expect("auth");
        std::fs::write(env.codex_root.join("cap_sid"), "sid-a").expect("cap");

        let repo = SnapshotRepository::new(&env.app_data_dir, MemorySecretStore::default());
        let saved = repo
            .save_snapshot(
                &env.kind,
                &DisplayIdentity {
                    email: "before@example.com".to_owned(),
                    subject: Some("sub-1".to_owned()),
                    name: Some("Before".to_owned()),
                    plan_label: Some("Pro".to_owned()),
                },
                &SnapshotBlob {
                    schema_version: 1,
                    files: vec![
                        SnapshotFile {
                            name: "auth.json".to_owned(),
                            bytes_base64: base64::engine::general_purpose::STANDARD.encode(
                                auth_json_fixture("after@example.com", "sub-1", Some("plus")),
                            ),
                        },
                        SnapshotFile {
                            name: "cap_sid".to_owned(),
                            bytes_base64: base64::engine::general_purpose::STANDARD.encode("sid-b"),
                        },
                    ],
                },
            )
            .expect("save")
            .0;

        let app = App::new(env.clone(), repo);
        let output = app.activate(saved.id).expect("activate");
        assert_eq!(output.account.email, "after@example.com");
        assert_eq!(output.account.plan_label.as_deref(), Some("Plus"));

        let list = app.list().expect("list");
        assert_eq!(list.accounts[0].email, "after@example.com");
    }

    #[test]
    fn activate_preserves_latest_live_tokens_before_switching() {
        let temp = tempdir().expect("tempdir");
        let env = AppEnv {
            kind: EnvironmentKind::Linux,
            home_dir: temp.path().to_path_buf(),
            codex_root: temp.path().join(".codex"),
            app_data_dir: temp.path().join("app"),
        };
        std::fs::create_dir_all(&env.codex_root).expect("codex root");
        std::fs::write(
            env.codex_root.join("auth.json"),
            auth_json_fixture("current@example.com", "sub-current", Some("pro")),
        )
        .expect("auth");
        std::fs::write(env.codex_root.join("cap_sid"), "sid-old").expect("cap");

        let app = App::new(
            env.clone(),
            SnapshotRepository::new(&env.app_data_dir, MemorySecretStore::default()),
        );
        let current_id = app.save_current().expect("save current").account.id;

        let mut latest_auth: serde_json::Value = serde_json::from_str(&auth_json_fixture(
            "current@example.com",
            "sub-current",
            Some("pro"),
        ))
        .expect("fixture json");
        latest_auth["tokens"]["refresh_token"] = serde_json::json!("latest-live-refresh");
        std::fs::write(
            env.codex_root.join("auth.json"),
            serde_json::to_vec(&latest_auth).expect("serialize latest auth"),
        )
        .expect("latest auth");
        std::fs::write(env.codex_root.join("cap_sid"), "sid-latest").expect("latest cap");
        let latest_live = crate::codex::read_live_auth_bundle(&env).expect("latest live");

        let target_auth = auth_json_fixture("target@example.com", "sub-target", Some("plus"));
        let (target_identity, target_snapshot) =
            crate::codex::snapshot_from_auth_json(target_auth.as_bytes()).expect("target snapshot");
        let target_id = app
            .repository
            .save_snapshot(&env.kind, &target_identity, &target_snapshot)
            .expect("save target")
            .0
            .id;

        app.activate(target_id).expect("activate target");

        let (_, preserved_current) = app
            .repository
            .load_snapshot(&env.kind, current_id)
            .expect("load preserved current");
        assert_eq!(preserved_current, latest_live.snapshot);
    }

    #[test]
    fn activate_rejects_snapshot_that_does_not_match_selected_account() {
        let temp = tempdir().expect("tempdir");
        let env = AppEnv {
            kind: EnvironmentKind::Linux,
            home_dir: temp.path().to_path_buf(),
            codex_root: temp.path().join(".codex"),
            app_data_dir: temp.path().join("app"),
        };
        std::fs::create_dir_all(&env.codex_root).expect("codex root");
        std::fs::write(
            env.codex_root.join("auth.json"),
            auth_json_fixture("active@example.com", "sub-1", Some("pro")),
        )
        .expect("auth");
        std::fs::write(env.codex_root.join("cap_sid"), "sid-a").expect("cap");

        let repo = SnapshotRepository::new(&env.app_data_dir, MemorySecretStore::default());
        let saved = repo
            .save_snapshot(
                &env.kind,
                &DisplayIdentity {
                    email: "expected@example.com".to_owned(),
                    subject: Some("sub-expected".to_owned()),
                    name: Some("Expected".to_owned()),
                    plan_label: Some("Pro".to_owned()),
                },
                &SnapshotBlob {
                    schema_version: 1,
                    files: vec![
                        SnapshotFile {
                            name: "auth.json".to_owned(),
                            bytes_base64: base64::engine::general_purpose::STANDARD.encode(
                                auth_json_fixture("wrong@example.com", "sub-wrong", Some("plus")),
                            ),
                        },
                        SnapshotFile {
                            name: "cap_sid".to_owned(),
                            bytes_base64: base64::engine::general_purpose::STANDARD.encode("sid-b"),
                        },
                    ],
                },
            )
            .expect("save")
            .0;

        let app = App::new(env.clone(), repo);
        let error = app.activate(saved.id).expect_err("activate should fail");
        assert!(format!("{error:#}").contains("does not match the selected account"));
        let live = crate::codex::read_live_auth_bundle(&env).expect("live bundle");
        assert_eq!(live.identity.email, "active@example.com");
    }

    #[test]
    fn activate_allows_legacy_metadata_without_subject_to_refresh_email() {
        let temp = tempdir().expect("tempdir");
        let env = AppEnv {
            kind: EnvironmentKind::Linux,
            home_dir: temp.path().to_path_buf(),
            codex_root: temp.path().join(".codex"),
            app_data_dir: temp.path().join("app"),
        };
        std::fs::create_dir_all(&env.codex_root).expect("codex root");
        std::fs::write(
            env.codex_root.join("auth.json"),
            auth_json_fixture("active@example.com", "sub-1", Some("pro")),
        )
        .expect("auth");
        std::fs::write(env.codex_root.join("cap_sid"), "sid-a").expect("cap");

        let repo = SnapshotRepository::new(&env.app_data_dir, MemorySecretStore::default());
        let saved = repo
            .save_snapshot(
                &env.kind,
                &DisplayIdentity {
                    email: "old@example.com".to_owned(),
                    subject: None,
                    name: Some("Old".to_owned()),
                    plan_label: Some("Pro".to_owned()),
                },
                &SnapshotBlob {
                    schema_version: 1,
                    files: vec![
                        SnapshotFile {
                            name: "auth.json".to_owned(),
                            bytes_base64: base64::engine::general_purpose::STANDARD.encode(
                                auth_json_fixture("new@example.com", "sub-new", Some("plus")),
                            ),
                        },
                        SnapshotFile {
                            name: "cap_sid".to_owned(),
                            bytes_base64: base64::engine::general_purpose::STANDARD.encode("sid-b"),
                        },
                    ],
                },
            )
            .expect("save")
            .0;

        let app = App::new(env.clone(), repo);
        let output = app.activate(saved.id).expect("activate");
        assert_eq!(output.account.email, "new@example.com");
        assert_eq!(output.account.subject.as_deref(), Some("sub-new"));
    }
}
