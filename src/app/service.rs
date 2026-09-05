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
use crate::operation_lock::{AuthLock, AutoSwitchLock, OperationLock};
use crate::repository::SnapshotRepository;
use crate::secrets::SecretStore;
use crate::settings::{load_settings, save_settings};
use crate::usage::{
    FetchUsageError, fetch_usage, usage_error_blocks_activation,
    usage_error_is_deferred_access_token_refresh, usage_error_message, usage_target_from_snapshot,
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
            vibe_usage: crate::vibe_usage::load_cached(&self.env.app_data_dir),
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
            settings.last_auto_switch_from = None;
        }
        save_settings(&self.env.app_data_dir, &settings)?;
        Ok(AutoSwitchOutput {
            enabled,
            status: if enabled { "enabled" } else { "disabled" }.to_owned(),
            active_account_id: None,
            candidate_account_id: None,
            candidate_display_name: None,
            detail: None,
            banked_reset_count: 0,
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
        let _auto_switch_lock = AutoSwitchLock::acquire(&self.env.app_data_dir)?;
        // Apply reuses the prior decision when possible — avoid a second Keychain/network
        // fan-out that unlocks the keychain and blocks ChatGPT relaunch.
        if apply {
            return self.apply_auto_switch(enabled, preferred_candidate_id, force);
        }
        self.decide_auto_switch(enabled)
    }

    fn decide_auto_switch(&self, enabled: bool) -> Result<AutoSwitchOutput> {
        // Fresh check of the live account only. A transient probe error must not
        // hide an already-cached 0% window — fall through to roster cache.
        let _ = self.usage(None);
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
            let confirmed_paid = !is_free_plan_label(plan_for_auto_switch_from(
                candidate.plan_label.as_deref(),
                candidate.cached_usage.as_ref(),
            ));
            // Fresh paid cache skips network/decrypt. Unlabeled or Free must refetch
            // so a stale Plus/Pro roster label cannot hide a Free downgrade, and so
            // a paid account missing plan_label can still become eligible.
            if cached_usage_is_fresh(candidate.cached_usage.as_ref(), now) && confirmed_paid {
                if is_usable_for_switch(candidate.cached_usage.as_ref()) {
                    usable_candidate_ids.insert(candidate.id);
                }
                continue;
            }
            match self.usage(Some(candidate.id)) {
                Ok(output)
                    if is_usable_for_switch(Some(&output.usage))
                        && !is_free_plan_label(output.usage.plan_label.as_deref()) =>
                {
                    usable_candidate_ids.insert(candidate.id);
                }
                _ => {}
            }
        }

        let accounts = self.list()?.accounts;
        let mut ranked: Vec<_> = accounts
            .iter()
            .filter(|candidate| {
                is_eligible_auto_switch_candidate(candidate, &active, &settings, now, None)
                    && usable_candidate_ids.contains(&candidate.id)
            })
            .cloned()
            .collect();
        ranked.sort_by_key(|candidate| {
            std::cmp::Reverse(switch_quota_score(candidate.usage.as_ref()))
        });
        // Never tell the GUI to quit ChatGPT on a cache-only guess. A stale
        // >0% window on the only other row (often the same exhausted identity)
        // would otherwise close Desktop every 10s and bounce the session.
        for cached in ranked {
            if let Some(candidate) =
                self.revalidated_auto_switch_candidate(cached.id, &active, &settings, now)
            {
                return Ok(auto_switch_output(
                    enabled,
                    "ready",
                    Some(active.id),
                    Some(candidate.id),
                    Some(account_display_name(&candidate)),
                    None,
                ));
            }
        }

        // A banked reset is valuable but not immediately usable quota. OpenAI's
        // own client redeems it through a separate, explicit consume action, so
        // never spend it or switch to a still-exhausted account silently. Return
        // a distinct state so the UI can explain exactly why monitoring did not
        // switch while keeping the normal paid/quota path fully automatic.
        let active_banked_reset_count = banked_reset_count(active.usage.as_ref());
        let banked_reset_candidate = if active_banked_reset_count > 0 {
            Some((active.clone(), active_banked_reset_count))
        } else {
            let mut candidates = accounts
                .iter()
                .filter(|candidate| {
                    is_banked_reset_fallback_candidate(candidate, &active, &settings, now)
                })
                .map(|candidate| {
                    (
                        candidate.clone(),
                        banked_reset_count(candidate.usage.as_ref()),
                    )
                })
                .collect::<Vec<_>>();
            candidates.sort_by_key(|(_, count)| std::cmp::Reverse(*count));
            candidates.into_iter().next()
        };
        if let Some((candidate, count)) = banked_reset_candidate {
            let mut output = auto_switch_output(
                enabled,
                "banked_reset_available",
                Some(active.id),
                Some(candidate.id),
                Some(account_display_name(&candidate)),
                Some(
                    "A banked rate-limit reset is available but must be redeemed explicitly before it becomes usable quota."
                        .to_owned(),
                ),
            );
            output.banked_reset_count = count;
            return Ok(output);
        }
        Ok(auto_switch_output(
            enabled,
            "all_accounts_exhausted",
            Some(active.id),
            None,
            None,
            Some("No eligible saved account has fresh usable quota.".to_owned()),
        ))
    }

    fn apply_auto_switch(
        &self,
        enabled: bool,
        preferred_candidate_id: Option<Uuid>,
        force: bool,
    ) -> Result<AutoSwitchOutput> {
        // Re-probe the live account first so a mid-flight reset does not switch away.
        let _ = self.usage(None);
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
        // Never activate from roster cache alone. A stale >0% window can hide a
        // live 0% or a plan that just became Free. Walk every cached candidate
        // until one live-validates.
        let mut tried = HashSet::new();
        let mut candidate = preferred_candidate_id.and_then(|preferred_id| {
            tried.insert(preferred_id);
            self.revalidated_auto_switch_candidate(preferred_id, active, &settings, now)
        });
        if candidate.is_none() {
            for cached in ranked_cached_auto_switch_candidates(
                &accounts,
                active,
                &settings,
                now,
                preferred_candidate_id,
            ) {
                if !tried.insert(cached.id) {
                    continue;
                }
                if let Some(verified) =
                    self.revalidated_auto_switch_candidate(cached.id, active, &settings, now)
                {
                    candidate = Some(verified);
                    break;
                }
            }
        }

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
        settings.last_auto_switch_from = Some(active.id);
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

    fn revalidated_auto_switch_candidate(
        &self,
        candidate_id: Uuid,
        active: &AccountView,
        settings: &crate::settings::AppSettings,
        now: time::OffsetDateTime,
    ) -> Option<AccountView> {
        if self.usage(Some(candidate_id)).is_err() {
            return None;
        }
        self.list().ok()?.accounts.into_iter().find(|account| {
            account.id == candidate_id
                && is_eligible_auto_switch_candidate(account, active, settings, now, None)
        })
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
        codex::auth_debug(
            &self.env,
            &format!(
                "SAVE-LIVE email={} {}",
                live.identity.email,
                codex::auth_fingerprint(&live.snapshot)
            ),
        );
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
        let initial_warnings = activation_process_warnings(force_running);
        ensure_activation_processes_stopped(&initial_warnings)?;
        let previous_account_id = self.refresh_current_saved_account_before_activation()?;
        let refreshed_current_at = Instant::now();
        let _operation_lock = OperationLock::acquire(&self.env.app_data_dir)?;
        let acquired_lock_at = Instant::now();
        let warnings = activation_process_warnings(force_running);
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
        codex::auth_debug(
            &self.env,
            &format!(
                "RESTORE-TARGET email={} {}",
                snapshot_identity.email,
                codex::auth_fingerprint(&snapshot)
            ),
        );
        // Preserve the legacy ownership model: Roster copies the complete
        // saved auth document unchanged, then the official Codex/ChatGPT auth
        // manager refreshes it after launch. Roster must never consume an
        // inactive account's rotating refresh token during activation.
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
        codex::auth_debug(
            &self.env,
            &format!(
                "RESTORED-OK email={} live={}",
                snapshot_identity.email,
                codex::try_read_live_auth_bundle(&self.env)
                    .ok()
                    .flatten()
                    .map_or_else(
                        || "none".to_owned(),
                        |bundle| codex::auth_fingerprint(&bundle.snapshot)
                    )
            ),
        );
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
            previous_account_id,
            warnings,
        })
    }

    fn refresh_current_saved_account_before_activation(&self) -> Result<Option<Uuid>> {
        if codex::try_read_live_auth_bundle(&self.env)?.is_none() {
            return Ok(None);
        }
        // Always preserve the current live session before replacing ~/.codex.
        // If it was not in the roster yet, saving it creates the rollback point.
        let saved = self
            .save_current_for_activation()
            .context("could not preserve the active Codex session before switching accounts")?;
        Ok(Some(saved.account.id))
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

    pub fn activation_blocking_warnings(&self, allow_desktop: bool) -> Vec<RunningCodexProcess> {
        crate::process::processes_blocking_activation(allow_desktop)
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
                if self
                    .repository
                    .get_account(&self.env.kind, account_id)?
                    .and_then(|account| account.cached_usage_error)
                    .as_deref()
                    .is_some_and(usage_error_is_deferred_access_token_refresh)
                {
                    anyhow::bail!(
                        "saved access-token check is deferred until this account is activated"
                    );
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
                codex::auth_debug(
                    &self.env,
                    &format!(
                        "PROBE-LIVE email={} {}",
                        live_identity.email,
                        codex::auth_fingerprint(&live_snapshot)
                    ),
                );
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
                        codex::auth_debug(
                            &self.env,
                            &format!(
                                "PROBE-FAIL email={} err={}",
                                live_identity.email,
                                usage_error_message(error.error())
                            ),
                        );
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
fn activation_process_warnings(allow_desktop: bool) -> Vec<RunningCodexProcess> {
    crate::process::processes_blocking_activation(allow_desktop)
}

#[cfg(test)]
fn activation_process_warnings(_allow_desktop: bool) -> Vec<RunningCodexProcess> {
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
        banked_reset_count: 0,
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

/// The Codex usage API reports `used_percent` as a server-side floored integer,
/// so a window that ChatGPT already blocks reads back as `used_percent = 99`
/// (`remaining_percent = 1`) rather than a clean 100/0. Treat anything at or
/// below this remaining threshold as depleted so a still-blocked account is not
/// mistaken for one that has quota to spend.
const EXHAUSTED_REMAINING_PERCENT: u8 = 1;

fn window_is_depleted(remaining_percent: u8) -> bool {
    remaining_percent <= EXHAUSTED_REMAINING_PERCENT
}

fn is_exhausted_for_switch(usage: Option<&AccountUsageView>) -> bool {
    !has_usable_credits(usage)
        && quota_windows(usage).any(|window| window_is_depleted(window.remaining_percent))
}

fn is_usable_for_switch(usage: Option<&AccountUsageView>) -> bool {
    if has_usable_credits(usage) {
        return true;
    }
    let windows = quota_windows(usage).collect::<Vec<_>>();
    !windows.is_empty()
        && windows
            .iter()
            .all(|window| !window_is_depleted(window.remaining_percent))
}

fn has_usable_credits(usage: Option<&AccountUsageView>) -> bool {
    usage
        .and_then(|usage| usage.credits.as_ref())
        .is_some_and(|credits| {
            credits.unlimited
                || (credits.has_credits && credit_balance_is_positive(&credits.balance))
        })
}

fn banked_reset_count(usage: Option<&AccountUsageView>) -> i64 {
    usage
        .and_then(|usage| usage.banked_resets.as_ref())
        .map(|resets| resets.available_count.max(0))
        .unwrap_or_default()
}

fn is_banked_reset_fallback_candidate(
    candidate: &AccountView,
    active: &AccountView,
    settings: &crate::settings::AppSettings,
    now: time::OffsetDateTime,
) -> bool {
    candidate.id != active.id
        && !accounts_represent_same_identity(candidate, active)
        && !candidate.archived
        && !candidate
            .usage_error
            .as_deref()
            .is_some_and(usage_error_blocks_activation)
        && !is_usable_for_switch(candidate.usage.as_ref())
        && !is_free_plan(candidate)
        && banked_reset_count(candidate.usage.as_ref()) > 0
        && !is_in_auto_switch_cooldown(settings, candidate.id, now)
}

fn credit_balance_is_positive(balance: &str) -> bool {
    let trimmed = balance.trim();
    if trimmed.is_empty() || trimmed.eq_ignore_ascii_case("null") {
        return false;
    }
    let numeric: String = trimmed
        .chars()
        .filter(|ch| ch.is_ascii_digit() || *ch == '.')
        .collect();
    numeric.parse::<f64>().is_ok_and(|value| value > 0.0)
}

/// Automatic switching must never silently downgrade the user onto a Free plan.
/// Missing/blank plan labels are treated the same way so an unlabeled Free
/// account cannot sneak through. A Free account is only ever reached by an
/// explicit manual switch.
fn is_free_plan(account: &AccountView) -> bool {
    is_free_plan_label(plan_for_auto_switch(account))
}

fn plan_for_auto_switch(account: &AccountView) -> Option<&str> {
    plan_for_auto_switch_from(account.plan_label.as_deref(), account.usage.as_ref())
}

/// Cache-only hint: if this usage fetch never recorded a plan, still try
/// roster metadata so a pre-migration Plus/Pro row can be live-revalidated.
fn plan_hint_for_auto_switch(account: &AccountView) -> Option<&str> {
    account
        .usage
        .as_ref()
        .and_then(|usage| usage.plan_label.as_deref())
        .or(account.plan_label.as_deref())
}

fn plan_for_auto_switch_from<'a>(
    roster_plan: Option<&'a str>,
    usage: Option<&'a AccountUsageView>,
) -> Option<&'a str> {
    match usage {
        // A usage payload is the last live confirmation. If that fetch omitted
        // plan_type, do not fall back to a stale roster Plus/Pro label.
        Some(usage) => usage.plan_label.as_deref(),
        None => roster_plan,
    }
}

fn is_free_plan_label(plan: Option<&str>) -> bool {
    let normalized = plan.unwrap_or("").replace(['-', '_'], " ");
    let mut words = normalized.split_whitespace().peekable();
    words.peek().is_none()
        || words.any(|word| word.eq_ignore_ascii_case("free") || word.eq_ignore_ascii_case("go"))
}

fn is_eligible_auto_switch_candidate(
    candidate: &AccountView,
    active: &AccountView,
    settings: &crate::settings::AppSettings,
    now: time::OffsetDateTime,
    excluded_id: Option<Uuid>,
) -> bool {
    candidate.id != active.id
        && !accounts_represent_same_identity(candidate, active)
        && Some(candidate.id) != excluded_id
        && !candidate.archived
        && !candidate
            .usage_error
            .as_deref()
            .is_some_and(usage_error_blocks_activation)
        && is_usable_for_switch(candidate.usage.as_ref())
        && !is_free_plan(candidate)
        && !is_in_auto_switch_cooldown(settings, candidate.id, now)
}

fn is_cached_auto_switch_hint(
    candidate: &AccountView,
    active: &AccountView,
    settings: &crate::settings::AppSettings,
    now: time::OffsetDateTime,
    excluded_id: Option<Uuid>,
) -> bool {
    candidate.id != active.id
        && !accounts_represent_same_identity(candidate, active)
        && Some(candidate.id) != excluded_id
        && !candidate.archived
        && !candidate
            .usage_error
            .as_deref()
            .is_some_and(usage_error_blocks_activation)
        && is_usable_for_switch(candidate.usage.as_ref())
        && !is_free_plan_label(plan_hint_for_auto_switch(candidate))
        && !is_in_auto_switch_cooldown(settings, candidate.id, now)
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
    let recently_used = settings.last_auto_switch_target == Some(candidate_id)
        || settings.last_auto_switch_from == Some(candidate_id);
    recently_used
        && settings
            .last_auto_switch_at
            .is_some_and(|last_switch| now - last_switch < time::Duration::minutes(5))
}

#[cfg(test)]
fn best_cached_auto_switch_candidate(
    accounts: &[AccountView],
    active: &AccountView,
    settings: &crate::settings::AppSettings,
    now: time::OffsetDateTime,
    excluded_id: Option<Uuid>,
) -> Option<AccountView> {
    ranked_cached_auto_switch_candidates(accounts, active, settings, now, excluded_id)
        .into_iter()
        .next()
}

fn ranked_cached_auto_switch_candidates(
    accounts: &[AccountView],
    active: &AccountView,
    settings: &crate::settings::AppSettings,
    now: time::OffsetDateTime,
    excluded_id: Option<Uuid>,
) -> Vec<AccountView> {
    let mut candidates: Vec<_> = accounts
        .iter()
        .filter(|candidate| {
            is_cached_auto_switch_hint(candidate, active, settings, now, excluded_id)
        })
        .cloned()
        .collect();
    candidates
        .sort_by_key(|candidate| std::cmp::Reverse(switch_quota_score(candidate.usage.as_ref())));
    candidates
}

/// A legacy/imported roster can contain duplicate records for one OpenAI
/// account. A different record ID must never make auto-switch restore the same
/// exhausted subject/email.
fn accounts_represent_same_identity(left: &AccountView, right: &AccountView) -> bool {
    if left.email.eq_ignore_ascii_case(&right.email) {
        return true;
    }
    match (&left.subject, &right.subject) {
        (Some(left_subject), Some(right_subject)) => left_subject == right_subject,
        _ => false,
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
            && quota_windows(Some(usage))
                .all(|window| !window_is_depleted(window.remaining_percent))
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
            origin: Some("cli".to_owned()),
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
    fn inactive_unauthorized_access_token_is_not_probed_again() {
        let temp = tempdir().expect("tempdir");
        let env = AppEnv {
            kind: EnvironmentKind::Linux,
            home_dir: temp.path().to_path_buf(),
            codex_root: temp.path().join(".codex"),
            app_data_dir: temp.path().join("app"),
        };
        std::fs::create_dir_all(&env.codex_root).expect("codex root");
        let repo = SnapshotRepository::new(&env.app_data_dir, MemorySecretStore::default());
        let saved = repo
            .save_snapshot(
                &env.kind,
                &DisplayIdentity {
                    email: "inactive@example.com".to_owned(),
                    subject: Some("sub-inactive".to_owned()),
                    name: None,
                    plan_label: Some("Plus".to_owned()),
                },
                &SnapshotBlob {
                    schema_version: 1,
                    files: vec![],
                },
            )
            .expect("save")
            .0;
        repo.record_usage_error(
            &env.kind,
            saved.id,
            "Usage unavailable [access_token_unauthorized]: deferred".to_owned(),
        )
        .expect("record usage error");
        let app = App::new(env, repo);

        let error = app
            .usage(Some(saved.id))
            .expect_err("probe must be deferred");

        assert!(format!("{error:#}").contains("deferred until this account is activated"));
        let account = app
            .repository
            .get_account(&app.env.kind, saved.id)
            .expect("load account")
            .expect("saved account");
        assert!(
            account
                .cached_usage_error
                .as_deref()
                .is_some_and(usage_error_is_deferred_access_token_refresh)
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
            banked_resets: None,
            plan_label: None,
            subscription_active_until: None,
        };

        assert!(is_exhausted_for_switch(Some(&usage)));
        assert!(!is_usable_for_switch(Some(&usage)));
    }

    #[test]
    fn auto_switch_excludes_free_plan_candidates() {
        let account = |plan: Option<&str>| crate::model::AccountView {
            id: Uuid::new_v4(),
            provider: crate::model::AiProvider::OpenAi,
            email: "person@example.com".to_owned(),
            subject: None,
            name: None,
            custom_label: None,
            plan_label: plan.map(str::to_owned),
            environment: EnvironmentKind::Linux,
            is_active: false,
            created_at: OffsetDateTime::now_utc(),
            updated_at: OffsetDateTime::now_utc(),
            last_activated_at: None,
            archived: false,
            usage: None,
            usage_error: None,
        };

        // Free accounts must never be auto-switch targets, regardless of casing.
        assert!(is_free_plan(&account(Some("Free"))));
        assert!(is_free_plan(&account(Some("free"))));
        assert!(is_free_plan(&account(Some("  FREE  "))));
        assert!(is_free_plan(&account(Some("Free Plan"))));
        assert!(is_free_plan(&account(Some("free_plan"))));
        assert!(is_free_plan(&account(Some("chatgpt-free"))));
        assert!(is_free_plan(&account(Some("ChatGPT Free"))));
        assert!(is_free_plan(&account(Some("Go"))));
        assert!(is_free_plan(&account(Some("chatgpt_go"))));
        // Unlabeled accounts are treated as Free so hidden Free rows cannot be picked.
        assert!(is_free_plan(&account(None)));
        assert!(is_free_plan(&account(Some(""))));
        assert!(is_free_plan(&account(Some("   "))));
        // Known paid plans stay eligible.
        assert!(!is_free_plan(&account(Some("Plus"))));
        assert!(!is_free_plan(&account(Some("Pro"))));
        assert!(!is_free_plan(&account(Some("Pro Lite"))));
        assert!(!is_free_plan(&account(Some("Team"))));
    }

    #[test]
    fn auto_switch_treats_same_email_as_the_same_account() {
        let now = OffsetDateTime::now_utc();
        let row = |email: &str, subject: Option<&str>| crate::model::AccountView {
            id: Uuid::new_v4(),
            provider: crate::model::AiProvider::OpenAi,
            email: email.to_owned(),
            subject: subject.map(str::to_owned),
            name: None,
            custom_label: None,
            plan_label: Some("Plus".to_owned()),
            environment: EnvironmentKind::Linux,
            is_active: false,
            created_at: now,
            updated_at: now,
            last_activated_at: None,
            archived: false,
            usage: None,
            usage_error: None,
        };
        assert!(accounts_represent_same_identity(
            &row("person@example.com", Some("sub-a")),
            &row("PERSON@example.com", Some("sub-b")),
        ));
        assert!(!accounts_represent_same_identity(
            &row("one@example.com", Some("sub-a")),
            &row("two@example.com", Some("sub-b")),
        ));
    }

    #[test]
    fn auto_switch_cools_down_both_source_and_target() {
        let now = OffsetDateTime::now_utc();
        let from = Uuid::new_v4();
        let target = Uuid::new_v4();
        let other = Uuid::new_v4();
        let settings = crate::settings::AppSettings {
            last_auto_switch_at: Some(now - time::Duration::minutes(1)),
            last_auto_switch_target: Some(target),
            last_auto_switch_from: Some(from),
            ..crate::settings::AppSettings::default()
        };
        assert!(is_in_auto_switch_cooldown(&settings, from, now));
        assert!(is_in_auto_switch_cooldown(&settings, target, now));
        assert!(!is_in_auto_switch_cooldown(&settings, other, now));
    }

    #[test]
    fn auto_switch_uses_usage_plan_not_stale_roster_label() {
        let now = OffsetDateTime::now_utc();
        let usage = |plan: Option<&str>| AccountUsageView {
            source: UsageSource::SavedAccessToken,
            fetched_at: now,
            five_hour: Some(UsageWindowView {
                used_percent: 10,
                remaining_percent: 90,
                reset_at: now,
            }),
            weekly: Some(UsageWindowView {
                used_percent: 10,
                remaining_percent: 90,
                reset_at: now,
            }),
            credits: None,
            banked_resets: None,
            plan_label: plan.map(str::to_owned),
            subscription_active_until: None,
        };
        let account = |roster: Option<&str>, usage_plan: Option<&str>| crate::model::AccountView {
            id: Uuid::new_v4(),
            provider: crate::model::AiProvider::OpenAi,
            email: "person@example.com".to_owned(),
            subject: None,
            name: None,
            custom_label: None,
            plan_label: roster.map(str::to_owned),
            environment: EnvironmentKind::Linux,
            is_active: false,
            created_at: now,
            updated_at: now,
            last_activated_at: None,
            archived: false,
            usage: Some(usage(usage_plan)),
            usage_error: None,
        };

        // Usage omitted plan_type: do not trust roster Plus.
        assert!(is_free_plan(&account(Some("Plus"), None)));
        // Usage confirms Free even if roster still says Pro.
        assert!(is_free_plan(&account(Some("Pro"), Some("Free"))));
        // Unlabeled roster becomes eligible once usage confirms Plus.
        assert!(!is_free_plan(&account(None, Some("Plus"))));
        // Pre-migration cache omitted usage.plan_label: do not activate on the
        // roster Plus, but still queue the row for a live revalidation.
        let mut stale = account(Some("Plus"), None);
        stale.email = "stale-plus@example.com".to_owned();
        stale.subject = Some("sub-stale".to_owned());
        assert!(is_free_plan(&stale));
        let settings = crate::settings::AppSettings::default();
        let mut active = account(Some("Pro"), Some("Pro"));
        active.email = "active-pro@example.com".to_owned();
        active.subject = Some("sub-active".to_owned());
        active.is_active = true;
        assert!(is_cached_auto_switch_hint(
            &stale, &active, &settings, now, None
        ));
        assert!(!is_eligible_auto_switch_candidate(
            &stale, &active, &settings, now, None
        ));
    }

    #[test]
    fn auto_switch_treats_credits_as_remaining_quota() {
        let now = OffsetDateTime::now_utc();
        let usage = |remaining: u8, credits: Option<crate::model::CreditsView>| AccountUsageView {
            source: UsageSource::SavedAccessToken,
            fetched_at: now,
            five_hour: Some(UsageWindowView {
                used_percent: 100u8.saturating_sub(remaining),
                remaining_percent: remaining,
                reset_at: now,
            }),
            weekly: Some(UsageWindowView {
                used_percent: 100u8.saturating_sub(remaining),
                remaining_percent: remaining,
                reset_at: now,
            }),
            credits,
            banked_resets: None,
            plan_label: Some("Pro".to_owned()),
            subscription_active_until: None,
        };

        let exhausted = usage(0, None);
        assert!(is_exhausted_for_switch(Some(&exhausted)));
        assert!(!is_usable_for_switch(Some(&exhausted)));

        let unlimited = usage(
            0,
            Some(crate::model::CreditsView {
                has_credits: false,
                unlimited: true,
                balance: "0".to_owned(),
            }),
        );
        assert!(!is_exhausted_for_switch(Some(&unlimited)));
        assert!(is_usable_for_switch(Some(&unlimited)));

        let paid_credits = usage(
            0,
            Some(crate::model::CreditsView {
                has_credits: true,
                unlimited: false,
                balance: "12.50".to_owned(),
            }),
        );
        assert!(!is_exhausted_for_switch(Some(&paid_credits)));
        assert!(is_usable_for_switch(Some(&paid_credits)));

        let empty_credits = usage(
            0,
            Some(crate::model::CreditsView {
                has_credits: true,
                unlimited: false,
                balance: "0".to_owned(),
            }),
        );
        assert!(is_exhausted_for_switch(Some(&empty_credits)));
        assert!(!is_usable_for_switch(Some(&empty_credits)));
    }

    #[test]
    fn floored_ninety_nine_percent_window_counts_as_exhausted() {
        // OpenAI floors `used_percent`, so a window ChatGPT already blocks reads
        // back as 99/1 instead of 100/0. It must not be treated as spendable
        // quota, otherwise the switcher stalls on an account that cannot serve
        // another request.
        let now = OffsetDateTime::now_utc();
        let depleted = AccountUsageView {
            source: UsageSource::SavedAccessToken,
            fetched_at: now,
            five_hour: Some(UsageWindowView {
                used_percent: 99,
                remaining_percent: 1,
                reset_at: now,
            }),
            weekly: None,
            credits: None,
            banked_resets: None,
            plan_label: Some("Pro".to_owned()),
            subscription_active_until: None,
        };
        assert!(is_exhausted_for_switch(Some(&depleted)));
        assert!(!is_usable_for_switch(Some(&depleted)));
        assert!(!cached_usage_is_fresh(Some(&depleted), now));

        let usable = AccountUsageView {
            five_hour: Some(UsageWindowView {
                used_percent: 98,
                remaining_percent: 2,
                reset_at: now,
            }),
            ..depleted
        };
        assert!(!is_exhausted_for_switch(Some(&usable)));
        assert!(is_usable_for_switch(Some(&usable)));
    }

    #[test]
    fn auto_switch_reports_banked_resets_without_treating_them_as_spendable_quota() {
        let now = OffsetDateTime::now_utc();
        let usage = |plan: &str, reset_count: i64| AccountUsageView {
            source: UsageSource::SavedAccessToken,
            fetched_at: now,
            five_hour: Some(UsageWindowView {
                used_percent: 100,
                remaining_percent: 0,
                reset_at: now,
            }),
            weekly: None,
            credits: None,
            banked_resets: Some(crate::model::BankedResetSummaryView {
                available_count: reset_count,
                credits: None,
            }),
            plan_label: Some(plan.to_owned()),
            subscription_active_until: None,
        };
        let account = |email: &str, plan: &str, reset_count: i64| AccountView {
            id: Uuid::new_v4(),
            provider: crate::model::AiProvider::OpenAi,
            email: email.to_owned(),
            subject: Some(format!("subject-{email}")),
            name: None,
            custom_label: None,
            plan_label: Some(plan.to_owned()),
            environment: EnvironmentKind::Linux,
            is_active: false,
            created_at: now,
            updated_at: now,
            last_activated_at: None,
            archived: false,
            usage: Some(usage(plan, reset_count)),
            usage_error: None,
        };
        let mut active = account("active@example.com", "Plus", 0);
        active.is_active = true;
        let candidate = account("candidate@example.com", "Plus", 1);
        let settings = crate::settings::AppSettings::default();

        assert!(is_exhausted_for_switch(candidate.usage.as_ref()));
        assert!(!is_usable_for_switch(candidate.usage.as_ref()));
        assert_eq!(banked_reset_count(candidate.usage.as_ref()), 1);
        assert!(is_banked_reset_fallback_candidate(
            &candidate, &active, &settings, now
        ));

        let free = account("free@example.com", "Free", 1);
        assert!(!is_banked_reset_fallback_candidate(
            &free, &active, &settings, now
        ));
        let mut blocked = account("blocked@example.com", "Plus", 1);
        blocked.usage_error =
            Some("Login required [refresh_token_invalidated]: sign in again".to_owned());
        assert!(!is_banked_reset_fallback_candidate(
            &blocked, &active, &settings, now
        ));
    }

    #[test]
    fn auto_switch_cached_picker_skips_free_and_zero_quota() {
        let now = OffsetDateTime::now_utc();
        let settings = crate::settings::AppSettings::default();
        let window = |remaining: u8| UsageWindowView {
            used_percent: 100u8.saturating_sub(remaining),
            remaining_percent: remaining,
            reset_at: now,
        };
        let account = |plan: &str, remaining: u8, active: bool| crate::model::AccountView {
            id: Uuid::new_v4(),
            provider: crate::model::AiProvider::OpenAi,
            email: format!("{plan}-{remaining}@example.com"),
            subject: Some(format!("{plan}-{remaining}")),
            name: None,
            custom_label: None,
            plan_label: Some(plan.to_owned()),
            environment: EnvironmentKind::Linux,
            is_active: active,
            created_at: now,
            updated_at: now,
            last_activated_at: None,
            archived: false,
            usage: Some(AccountUsageView {
                source: UsageSource::SavedAccessToken,
                fetched_at: now,
                five_hour: Some(window(remaining)),
                weekly: Some(window(remaining)),
                credits: None,
                banked_resets: None,
                plan_label: Some(plan.to_owned()),
                subscription_active_until: None,
            }),
            usage_error: None,
        };
        let active = account("Plus", 0, true);
        let free = account("Free", 80, false);
        let unlabeled = {
            let mut account = account("Hidden", 90, false);
            account.plan_label = None;
            if let Some(usage) = account.usage.as_mut() {
                usage.plan_label = None;
            }
            account
        };
        let zero = account("Pro", 0, false);
        let paid = account("Pro", 40, false);
        let picked = best_cached_auto_switch_candidate(
            &[active.clone(), free, unlabeled, zero, paid.clone()],
            &active,
            &settings,
            now,
            None,
        )
        .expect("paid usable account");
        assert_eq!(picked.id, paid.id);
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
            banked_resets: None,
            plan_label: None,
            subscription_active_until: None,
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
            banked_resets: None,
            plan_label: None,
            subscription_active_until: None,
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
            banked_resets: None,
            plan_label: None,
            subscription_active_until: None,
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
                banked_resets: None,
                plan_label: None,
                subscription_active_until: None,
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
                banked_resets: None,
                plan_label: None,
                subscription_active_until: None,
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
    fn activate_saves_unsaved_current_session_and_restores_target_unchanged() {
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
            auth_json_fixture("unsaved@example.com", "sub-unsaved", Some("pro")),
        )
        .expect("auth");
        std::fs::write(env.codex_root.join("cap_sid"), "sid-unsaved").expect("cap");

        let app = App::new(
            env.clone(),
            SnapshotRepository::new(&env.app_data_dir, MemorySecretStore::default()),
        );
        let unsaved_live = crate::codex::read_live_auth_bundle(&env).expect("unsaved live");

        let mut target_auth: serde_json::Value = serde_json::from_str(&auth_json_fixture(
            "target@example.com",
            "sub-target",
            Some("plus"),
        ))
        .expect("fixture json");
        target_auth["tokens"]["refresh_token"] = serde_json::json!("official-owner-token");
        let target_bytes = serde_json::to_vec(&target_auth).expect("serialize target auth");
        let (target_identity, target_snapshot) =
            crate::codex::snapshot_from_auth_json(&target_bytes).expect("target snapshot");
        let target_id = app
            .repository
            .save_snapshot(&env.kind, &target_identity, &target_snapshot)
            .expect("save target")
            .0
            .id;

        let output = app.activate(target_id).expect("activate target");
        let previous_id = output
            .previous_account_id
            .expect("unsaved current session must become a rollback point");
        let (_, preserved_previous) = app
            .repository
            .load_snapshot(&env.kind, previous_id)
            .expect("load rollback point");
        let live_after_switch = crate::codex::read_live_auth_bundle(&env).expect("target live");

        assert_eq!(preserved_previous, unsaved_live.snapshot);
        assert_eq!(live_after_switch.snapshot, target_snapshot);
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
