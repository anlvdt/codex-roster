use anyhow::{Context, Result};
use std::collections::HashSet;
use std::time::{Duration, Instant};
use time::OffsetDateTime;
use uuid::Uuid;

use crate::backup::{read_encrypted, write_encrypted};
use crate::codex;
use crate::env::AppEnv;
use crate::model::{
    AccountUsageView, AccountView, ActivateOutput, AutoSwitchOutput, DeadAccountEntry,
    DeadAccountReport, DeleteOutput, DisplayIdentity, LegacyRecoveryOutput, ListOutput,
    RunningCodexProcess, SaveAction, SaveOutput, SavedAccountMetadata, SnapshotBlob, StatusOutput,
    TokenUsageSummaryOutput, UsageOutput, UsageSource, UsageWindowView,
};
use crate::operation_lock::{AuthLock, AutoSwitchLock, OperationLock};
use crate::repository::SnapshotRepository;
use crate::secrets::SecretStore;
use crate::settings::{load_settings, save_settings};
use crate::usage::{
    FetchUsageError, fetch_usage, usage_error_account_deactivated, usage_error_blocks_activation,
    usage_error_is_deferred_access_token_refresh, usage_error_message, usage_error_requires_login,
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
        let codex_model = codex::read_configured_model(&self.env.codex_root);
        let process_warnings = crate::process::detect_running_codex_processes();
        let activity = crate::codex_activity::summarize(&self.env.codex_root, &process_warnings);
        Ok(StatusOutput {
            environment: self.env.kind.clone(),
            codex_root: self.env.codex_root.display().to_string(),
            current_account: live.map(|bundle| bundle.identity),
            current_account_saved_id: current_saved_id,
            saved_accounts: saved_accounts.len(),
            process_warnings,
            vibe_usage: crate::vibe_usage::load_cached(&self.env.app_data_dir),
            codex_model,
            activity: Some(activity),
            warnings: crate::repository::last_backup_warning()
                .into_iter()
                .collect(),
        })
    }

    pub fn auto_switch_enabled(&self) -> Result<bool> {
        Ok(load_settings(&self.env.app_data_dir)?.auto_switch_when_exhausted)
    }

    pub fn enable_luna_reserve(
        &self,
        account_id: Option<Uuid>,
    ) -> Result<crate::model::EnableLunaReserveOutput> {
        if let Some(target_id) = account_id
            && !self.is_live_saved_account(target_id)?
        {
            // Activation owns its locks; do not acquire them recursively.
            self.activate(target_id)?;
        }

        let _auth_lock = AuthLock::acquire(&self.env.app_data_dir)?;
        let _operation_lock = OperationLock::acquire(&self.env.app_data_dir)?;
        if let Some(target_id) = account_id
            && !self.is_live_saved_account(target_id)?
        {
            anyhow::bail!(
                "active account changed before enabling Luna Reserve; retry for the selected account"
            );
        }

        let live = codex::try_read_live_auth_bundle(&self.env)?
            .ok_or_else(|| anyhow::anyhow!("no active account found to enable Luna Reserve for"))?;

        let previous_model = codex::read_configured_model(&self.env.codex_root);
        codex::set_configured_model(&self.env.codex_root, "gpt-5.6-luna")?;

        Ok(crate::model::EnableLunaReserveOutput {
            status: "enabled".to_owned(),
            account_email: live.identity.email,
            model: "gpt-5.6-luna".to_owned(),
            previous_model,
        })
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
            session_resume: None,
            usage_unknown: false,
            warnings: Vec::new(),
            candidate_switch_score: None,
            next_probe_seconds: None,
        })
    }

    pub fn auto_resume_session_status(
        &self,
    ) -> Result<crate::model::AutoResumeSessionStatusOutput> {
        let settings = load_settings(&self.env.app_data_dir)?;
        Ok(crate::model::AutoResumeSessionStatusOutput {
            enabled: settings.auto_resume_session,
        })
    }

    pub fn set_auto_resume_session(
        &self,
        enabled: bool,
    ) -> Result<crate::model::AutoResumeSessionStatusOutput> {
        let _operation_lock = OperationLock::acquire(&self.env.app_data_dir)?;
        let mut settings = load_settings(&self.env.app_data_dir)?;
        settings.auto_resume_session = enabled;
        save_settings(&self.env.app_data_dir, &settings)?;
        Ok(crate::model::AutoResumeSessionStatusOutput { enabled })
    }

    /// Live discover interrupted / quota-blocked threads for same-account recovery
    /// (banked-reset redeem). Does not mutate the pending-continue index used by
    /// auto-switch.
    pub fn continue_interrupted_sessions(&self) -> Result<crate::model::SessionResumeHint> {
        let settings = load_settings(&self.env.app_data_dir)?;
        let active_id = self
            .list()?
            .accounts
            .into_iter()
            .find(|account| account.is_active)
            .map(|account| account.id);
        crate::session_resume::hint_for_interrupted_sessions(
            &self.env.codex_root,
            settings.auto_resume_session,
            active_id,
        )
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
        // Finish or discard whatever a previous run left in flight before making
        // another decision (audit U6).
        match crate::switch_txn::reconcile(
            &self.env.app_data_dir,
            time::OffsetDateTime::now_utc(),
            self.live_saved_account_id().unwrap_or(None),
        )? {
            crate::switch_txn::ReconcileOutcome::Completed(phase) => {
                eprintln!(
                    "recovered an interrupted account switch (phase {phase:?}); treating it as applied"
                );
                let _ = crate::switch_txn::clear(&self.env.app_data_dir);
            }
            crate::switch_txn::ReconcileOutcome::RolledBack => {
                eprintln!(
                    "recovered an interrupted account switch; the previous account is still live"
                );
            }
            _ => {}
        }
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
        let now = time::OffsetDateTime::now_utc();
        let settings = load_settings(&self.env.app_data_dir)?;
        // No current known window and no usable credits means the live probe
        // failed (for example an expired access token, which Roster deliberately
        // does not refresh) or the cached windows already reset. Say so instead
        // of claiming the active account has quota (audit S2).
        if !has_usable_credits(active.usage.as_ref(), now)
            && !has_current_five_hour_window(active.usage.as_ref(), now)
        {
            let mut output = auto_switch_output(
                enabled,
                // A distinct status: `active_has_quota` made the app treat an
                // unknown-quota poll as a *recovery* and resume interrupted turns
                // on an account that may still be exhausted (review finding 1).
                "usage_unknown",
                Some(active.id),
                None,
                None,
                Some(
                    "Quota is unknown for the active account; open Codex to refresh the session."
                        .to_owned(),
                ),
            );
            output.usage_unknown = true;
            return Ok(output);
        }
        // An idle account (no rollout write in the last ~20s) is the only safe
        // moment for a proactive switch: moving mid-turn would strand a turn on
        // an account that is about to be swapped away (audit U2).
        let activity = crate::codex_activity::summarize(&self.env.codex_root, &[]);
        let activity_idle = activity.working == 0 && activity.waiting == 0;
        let proactive =
            proactive_switch_allowed(active.usage.as_ref(), &settings, activity_idle, now);
        if !is_exhausted_for_switch(active.usage.as_ref(), now) && !proactive {
            let mut output = auto_switch_output(
                enabled,
                "active_has_quota",
                Some(active.id),
                None,
                None,
                None,
            );
            output.next_probe_seconds =
                next_probe_seconds_for_active(active.usage.as_ref(), &settings, now);
            return Ok(output);
        }

        // Minimum dwell between automatic switches, on both the reactive and the
        // proactive path: without it an exhausted roster can bounce A→B→C→A every
        // poll (audit S5/U2).
        if !dwell_satisfied(&settings, now) {
            let mut waiting = auto_switch_output(
                enabled,
                "waiting_for_dwell",
                Some(active.id),
                None,
                None,
                Some("Waiting for the minimum dwell between automatic switches.".to_owned()),
            );
            // Sleep exactly until the dwell ends rather than on the fixed clock.
            waiting.next_probe_seconds = settings.last_auto_switch_at.map(|last| {
                let elapsed = (now - last).whole_seconds().max(0) as u64;
                settings
                    .auto_switch_dwell_minutes
                    .saturating_mul(60)
                    .saturating_sub(elapsed)
                    .clamp(1, NEXT_PROBE_MAX_IDLE_SECONDS)
            });
            return Ok(waiting);
        }
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
            // Deferred AT unauthorized with fresh usable cache is also eligible —
            // never call usage(Some) on deferred (early-bail / no RT prove).
            if cached_usage_is_fresh(candidate.cached_usage.as_ref(), now) && confirmed_paid {
                if is_usable_for_switch(candidate.cached_usage.as_ref(), now) {
                    usable_candidate_ids.insert(candidate.id);
                }
                continue;
            }
            if candidate
                .cached_usage_error
                .as_deref()
                .is_some_and(usage_error_is_deferred_access_token_refresh)
            {
                continue;
            }
            // Exhausted/unusable caches never pass cached_usage_is_fresh (depleted
            // windows). Without a backoff, decide would AT-probe every saved
            // account every poll while all-exhausted — sticky deferred storms.
            // Re-probe after the backoff so off-schedule resets still surface.
            if confirmed_paid
                && exhausted_cached_usage_skips_probe(candidate.cached_usage.as_ref(), now)
            {
                continue;
            }
            if recent_usage_error_skips_probe(candidate, now) {
                continue;
            }
            match self.usage(Some(candidate.id)) {
                Ok(output) if fresh_usage_passes_auto_switch_gate(&output.usage, now) => {
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
        ranked.sort_by(|left, right| compare_candidates(left, right, now));
        // A live Codex CLI session cannot be switched past: apply would refuse
        // after the GUI already quit Desktop, bouncing the session in a loop.
        // Report `waiting_for_processes` instead of `ready` (audit S1).
        let preflight = self.activation_blocking_report(true);
        if preflight.has_live_cli() {
            let mut waiting = auto_switch_output(
                enabled,
                "waiting_for_processes",
                Some(active.id),
                None,
                None,
                Some(crate::process::format_blocking_report(&preflight).join("; ")),
            );
            waiting.next_probe_seconds = Some(NEXT_PROBE_BLOCKED_SECONDS);
            return Ok(waiting);
        }

        // Never tell the GUI to quit ChatGPT on a cache-only guess. A stale
        // >0% window on the only other row (often the same exhausted identity)
        // would otherwise close Desktop every 10s and bounce the session.
        // `ready` is returned only after revalidated_auto_switch_candidate gates
        // on fresh usable (non-exhausted, non-Free) AT usage.
        for cached in ranked {
            if let Some(candidate) =
                self.revalidated_auto_switch_candidate(cached.id, &active, &settings, now)
            {
                let mut output = auto_switch_output(
                    enabled,
                    "ready",
                    Some(active.id),
                    Some(candidate.id),
                    Some(account_display_name(&candidate)),
                    None,
                );
                // Explain the pick before the switch happens, not only after.
                output.candidate_switch_score = switch_score_breakdown(&candidate, now);
                return Ok(output);
            }
        }

        // A banked reset is valuable but not immediately usable quota. OpenAI's
        // own client redeems it through a separate, explicit consume action, so
        // never spend it or switch to a still-exhausted account silently. Return
        // a distinct state so the UI can explain exactly why monitoring did not
        // switch while keeping the normal paid/quota path fully automatic.
        let active_banked_reset_count = banked_reset_count(active.usage.as_ref(), now);
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
                        banked_reset_count(candidate.usage.as_ref(), now),
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
        // Decide re-probed the live account seconds ago; only re-probe when that
        // cache is older than the decide→quit→apply hop so a mid-flight reset can
        // still cancel the switch without paying a second network round-trip.
        let now = time::OffsetDateTime::now_utc();
        let live_cache_recent = self
            .list()?
            .accounts
            .iter()
            .find(|account| account.is_active)
            .and_then(|account| account.usage.as_ref())
            .is_some_and(|usage| now - usage.fetched_at < RECENT_LIVE_PROBE_WINDOW);
        if !live_cache_recent {
            let _ = self.usage(None);
        }
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
        if !is_exhausted_for_switch(active.usage.as_ref(), now) {
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

        // Final belt: never activate an exhausted / unusable candidate even if a
        // preferred id or list row slipped past revalidation.
        if !is_usable_for_switch(candidate.usage.as_ref(), now)
            || is_exhausted_for_switch(candidate.usage.as_ref(), now)
        {
            return Ok(auto_switch_output(
                enabled,
                "all_accounts_exhausted",
                Some(active.id),
                None,
                None,
                Some("No eligible saved account has usable quota.".to_owned()),
            ));
        }

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
        // Durable saga: record the intent on disk before the first mutation so a
        // crash leaves a recoverable trace instead of a half-applied switch
        // (audit U6).
        let mut txn =
            crate::switch_txn::begin(&self.env.app_data_dir, active.id, candidate.id, now)?;
        // Freeze the live thread that hit usage limits BEFORE swapping auth.
        // Shared ~/.codex keeps that thread; the new account's quota pays for
        // the next turns. Do not use the target account's old workspace hint.
        let mut bookkeeping_warnings = Vec::new();
        if let Err(error) = crate::session_resume::capture_pending_continue(
            &self.env.app_data_dir,
            &self.env.codex_root,
            active.id,
        ) {
            // A timed-out index lock used to be discarded, so the interrupted
            // thread was silently never resumed (review finding 8).
            bookkeeping_warnings.push(format!(
                "session switched, but the interrupted thread could not be recorded: {error:#}"
            ));
        }
        txn = crate::switch_txn::advance(
            &self.env.app_data_dir,
            &txn,
            crate::switch_txn::SwitchPhase::Captured,
        )?;
        let activated = if force {
            self.activate_with_expected_active(candidate.id, true, Some(active.id))
        } else {
            self.activate_if_active_matches(candidate.id, active.id)
        };
        let _activated = match activated {
            Ok(activated) => activated,
            Err(error) => {
                // The swap did not complete: record the rollback and clean up so
                // the next poll is not blocked by a phantom transaction.
                let _ = crate::switch_txn::advance(
                    &self.env.app_data_dir,
                    &txn,
                    crate::switch_txn::SwitchPhase::RolledBack,
                );
                let _ = crate::switch_txn::clear(&self.env.app_data_dir);
                return Err(error);
            }
        };
        txn = crate::switch_txn::advance(
            &self.env.app_data_dir,
            &txn,
            crate::switch_txn::SwitchPhase::AuthSwapped,
        )?;
        // Verify the live session really is the target. An unreadable auth file
        // is inconclusive (not a failure); a live session that maps to another
        // saved account means the swap did not land and must be reverted.
        let live_after_swap = self.live_saved_account_id().unwrap_or(None);
        if let Some(live) = live_after_swap
            && live != candidate.id
            && live == active.id
        {
            let _ = self.activate_with_expected_active(active.id, true, None);
            let _ = crate::switch_txn::advance(
                &self.env.app_data_dir,
                &txn,
                crate::switch_txn::SwitchPhase::RolledBack,
            );
            let _ = crate::switch_txn::clear(&self.env.app_data_dir);
            return Err(anyhow::anyhow!(
                "automatic switch did not take effect; the previous account was restored"
            ));
        }
        crate::switch_txn::advance(
            &self.env.app_data_dir,
            &txn,
            crate::switch_txn::SwitchPhase::Verified,
        )?;
        let _operation_lock = OperationLock::acquire(&self.env.app_data_dir)?;
        let mut settings = load_settings(&self.env.app_data_dir)?;
        settings.last_auto_switch_at = Some(now);
        settings.last_auto_switch_target = Some(candidate.id);
        settings.last_auto_switch_from = Some(active.id);
        if let Err(error) = save_settings(&self.env.app_data_dir, &settings) {
            // The credential swap already succeeded. Report the switch with a
            // warning instead of failing and losing cooldown/resume (audit S7).
            bookkeeping_warnings.push(format!(
                "session switched, but auto-switch cooldown bookkeeping failed: {error:#}"
            ));
        }
        let mut output = auto_switch_output(
            enabled,
            "switched",
            Some(active.id),
            Some(candidate.id),
            Some(account_display_name(&candidate)),
            None,
        );
        output.candidate_switch_score = switch_score_breakdown(&candidate, now);
        let auto_resume_enabled = settings.auto_resume_session;
        match crate::session_resume::take_pending_continue_hint(
            &self.env.app_data_dir,
            auto_resume_enabled,
        ) {
            Ok(hint) => output.session_resume = hint,
            Err(error) => bookkeeping_warnings.push(format!(
                "session switched, but the resume hint could not be read: {error:#}"
            )),
        }
        output.warnings = bookkeeping_warnings;
        // The switch is fully applied and recorded: drop the transaction so the
        // next run starts clean.
        let _ = crate::switch_txn::clear(&self.env.app_data_dir);
        Ok(output)
    }

    /// Burn-rate forecast for one account's windows, from recorded samples.
    ///
    /// Uses cached quota (no network) and the local `quota_history` series, so it
    /// is safe to call from the UI or a script at any time.
    pub fn quota_forecast(
        &self,
        account_id: Option<Uuid>,
    ) -> Result<crate::model::QuotaForecastOutput> {
        let list = self.list()?;
        let account = match account_id {
            Some(id) => list
                .accounts
                .iter()
                .find(|account| account.id == id)
                .ok_or_else(|| anyhow::anyhow!("no saved account matches that id"))?,
            None => list
                .accounts
                .iter()
                .find(|account| account.is_active)
                .ok_or_else(|| anyhow::anyhow!("no active account; pass an account id"))?,
        };
        let now = time::OffsetDateTime::now_utc();
        let now_minute = now.unix_timestamp() / 60;
        let samples =
            crate::quota_history::load_samples(&self.env.app_data_dir, account.id, now).samples;
        let usage = account.usage.as_ref();
        let five = usage
            .and_then(|usage| usage.five_hour.as_ref())
            .map(|window| f64::from(window.remaining_percent));
        let weekly = usage
            .and_then(|usage| usage.weekly.as_ref())
            .map(|window| f64::from(window.remaining_percent));
        Ok(crate::model::QuotaForecastOutput {
            account_id: Some(account.id),
            generated_at: now,
            five_hour: five.and_then(|remaining| {
                crate::forecast::forecast_window(
                    &samples,
                    crate::forecast::WindowKind::FiveHour,
                    remaining,
                    now_minute,
                )
            }),
            weekly: weekly.and_then(|remaining| {
                crate::forecast::forecast_window(
                    &samples,
                    crate::forecast::WindowKind::Weekly,
                    remaining,
                    now_minute,
                )
            }),
        })
    }

    fn revalidated_auto_switch_candidate(
        &self,
        candidate_id: Uuid,
        active: &AccountView,
        settings: &crate::settings::AppSettings,
        now: time::OffsetDateTime,
    ) -> Option<AccountView> {
        // Session longevity: deferred AT + fresh usable paid cache is enough for
        // candidacy. Do not call usage(Some) — that early-bails deferred and must
        // never exchange RTs here. Activation still restores the snapshot unchanged
        // so Codex/Desktop owns refresh after launch.
        if let Some(account) = self.list().ok()?.accounts.into_iter().find(|account| {
            account.id == candidate_id
                && deferred_fresh_usable_auto_switch_candidate(account, active, settings, now)
        }) {
            return Some(account);
        }

        // Decide often just AT-probed this id seconds earlier. Reuse a still-fresh
        // usable paid cache instead of a duplicate network hit on apply — still
        // refuses Free/Go, exhausted, and stale caches.
        if let Some(account) = self.list().ok()?.accounts.into_iter().find(|account| {
            account.id == candidate_id
                && fresh_usable_paid_cached_auto_switch_candidate(account, active, settings, now)
        }) {
            return Some(account);
        }

        // AT-only probe (usage never rotates RT here). Gate on the fresh payload
        // before trusting list eligibility, so a stale roster row cannot make an
        // exhausted account look ready/activate-able.
        let output = self.usage(Some(candidate_id)).ok()?;
        if !fresh_usage_passes_auto_switch_gate(&output.usage, now) {
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

    /// Read-only report of saved accounts that are dead or look dead.
    ///
    /// Nothing is removed: the report carries the exact `archive`/`delete`
    /// commands so the user decides. A missing 5h/7d window is deliberately NOT
    /// evidence — Free/Go accounts only carry a monthly limit, so they report no
    /// weekly window by design.
    pub fn dead_accounts(&self, stale_days: i64, deep: bool) -> Result<DeadAccountReport> {
        let (deep_checked, deep_alive) = if deep {
            self.deep_check_inactive_accounts()?
        } else {
            (0, 0)
        };
        let now = OffsetDateTime::now_utc();
        let mut confirmed = Vec::new();
        let mut suspects = Vec::new();
        for account in self.list()?.accounts {
            let Some((reason, detail)) = classify_dead_account(&account, now, stale_days) else {
                continue;
            };
            let entry = dead_account_entry(account, reason, detail);
            match reason {
                DeadAccountReason::Deactivated => confirmed.push(entry),
                DeadAccountReason::StaleAuthFailure => suspects.push(entry),
            }
        }
        Ok(DeadAccountReport {
            generated_at: now,
            stale_after_days: stale_days,
            deep_checked,
            deep_alive,
            confirmed,
            suspects,
            note: DEAD_ACCOUNT_NOTE.to_owned(),
        })
    }

    /// Exchange each inactive account's refresh token once to learn whether its
    /// grant still exists. Returns `(checked, alive)`.
    ///
    /// This is the only way to tell a deactivated account from one that merely
    /// has not been used for a while. It **consumes the rotating refresh token**,
    /// so it is explicit (`--deep`), never runs in a background sweep, and the
    /// rotated snapshot is persisted immediately so a live grant is never lost.
    /// The account currently live in `~/.codex` is skipped: Codex owns that
    /// refresh token and rotating it would force a re-login.
    fn deep_check_inactive_accounts(&self) -> Result<(usize, usize)> {
        let _auth_lock = AuthLock::acquire(&self.env.app_data_dir)?;
        let active_id = self.live_saved_account_id()?;
        let accounts = self.repository.list_accounts(&self.env.kind)?;
        let mut checked = 0;
        let mut alive = 0;
        for account in accounts {
            // Never touch the live account: Codex owns that refresh token.
            if account.archived || active_id == Some(account.id) {
                continue;
            }
            let Ok((metadata, snapshot)) =
                self.repository.load_snapshot(&self.env.kind, account.id)
            else {
                continue;
            };
            checked += 1;
            match crate::usage::prove_saved_session_refresh(&snapshot) {
                Ok(refreshed) => {
                    // Persist the rotated tokens before anything else: the old
                    // refresh token is already spent, so dropping the new one
                    // would strand the account.
                    let identity = saved_identity(&metadata);
                    self.repository
                        .save_snapshot(&self.env.kind, &identity, &refreshed)?;
                    self.repository.record_usage_error(
                        &self.env.kind,
                        account.id,
                        String::new(),
                    )?;
                    alive += 1;
                }
                Err(error) => {
                    let _ = self.repository.record_usage_error(
                        &self.env.kind,
                        account.id,
                        usage_error_message(&error),
                    );
                }
            }
        }
        Ok((checked, alive))
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
    /// Critical: write the *current* live credentials into that account's saved
    /// snapshot before the add/re-login marker is set. Codex login may replace
    /// `~/.codex` auth; without this write-back, any tokens Codex already
    /// rotated in the live files would be lost and the previous account would
    /// later fail prove/refresh with a dead refresh token.
    ///
    /// The existing live auth remains available for Codex to reuse a trusted
    /// session, and cancel still restores the backed-up session if login changes it.
    pub fn begin_add_account_session(&self) -> Result<()> {
        let _auth_lock = AuthLock::acquire(&self.env.app_data_dir)?;
        // Login is an explicit credential transaction, not an account switch.
        // Leave Desktop running and pause Roster background work via the marker.
        if codex::try_read_live_auth_bundle(&self.env)?.is_some() {
            self.save_current_inner(true).context(
                "could not preserve the active Codex session before starting add-account login",
            )?;
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
            Self::refuse_duplicate_import(&self.repository, &self.env.kind, &identity)?;
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
            Self::refuse_duplicate_import(&self.repository, &self.env.kind, &identity)?;
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

    /// Single-account auth.json / snapshot import must not silently refresh an
    /// existing roster row — that path is for enrollment. Backup-bundle import
    /// still updates matching identities.
    fn refuse_duplicate_import(
        repository: &SnapshotRepository<S>,
        environment: &crate::model::EnvironmentKind,
        identity: &DisplayIdentity,
    ) -> Result<()> {
        let accounts = repository.list_accounts(environment)?;
        if match_saved_account(&accounts, identity).is_some() {
            anyhow::bail!("Tài khoản đã có trong danh bạ / Account already in roster");
        }
        Ok(())
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
        // Remember this account's latest Codex user-thread pointer while the live
        // ~/.codex session is still the outgoing one (including the pre-quit save
        // on Desktop switch). Never touches refresh tokens.
        let _ = crate::session_resume::capture_for_account(
            &self.env.app_data_dir,
            &self.env.codex_root,
            metadata.id,
        );
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
        // Housekeeping under the auth lock: staged recovery directories from a
        // crashed switch are removed once they are clearly abandoned (audit A2).
        codex::prune_stale_recovery_dirs(&self.env.codex_root);
        let initial_warnings = activation_process_warnings(force_running, &self.env.codex_root);
        ensure_activation_processes_stopped(&initial_warnings)?;
        let previous_account_id = self.refresh_current_saved_account_before_activation()?;
        // Remember outgoing Codex rollout metadata (session id + cwd) before we
        // replace auth. Never touches refresh tokens.
        if let Some(outgoing_id) = previous_account_id {
            let _ = crate::session_resume::capture_for_account(
                &self.env.app_data_dir,
                &self.env.codex_root,
                outgoing_id,
            );
        }
        let refreshed_current_at = Instant::now();
        let _operation_lock = OperationLock::acquire(&self.env.app_data_dir)?;
        let acquired_lock_at = Instant::now();
        let warnings = activation_process_warnings(force_running, &self.env.codex_root);
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
        // Tenure floor for the next switch-away capture so idle accounts do not
        // inherit another account's shared ~/.codex/sessions rollout.
        let _ = crate::session_resume::mark_activated(&self.env.app_data_dir, account_id);
        let auto_resume_enabled = load_settings(&self.env.app_data_dir)
            .map(|settings| settings.auto_resume_session)
            .unwrap_or(true);
        let session_resume = crate::session_resume::hint_for_account(
            &self.env.app_data_dir,
            account_id,
            auto_resume_enabled,
        )
        .ok();
        Ok(ActivateOutput {
            account: account_view(metadata, Some(account_id), None, None),
            previous_account_id,
            warnings,
            session_resume,
        })
    }

    /// Which saved account the live `~/.codex` session currently maps to.
    fn live_saved_account_id(&self) -> Result<Option<Uuid>> {
        let Some(live) = codex::try_read_live_auth_bundle(&self.env)? else {
            return Ok(None);
        };
        let accounts = self.repository.list_accounts(&self.env.kind)?;
        Ok(match_saved_account(&accounts, &live.identity).map(|account| account.id))
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
        crate::process::processes_blocking_activation(allow_desktop, &self.env.codex_root)
    }

    /// Blocking decision with reasons, for actionable CLI/GUI messages.
    pub fn activation_blocking_report(
        &self,
        allow_desktop: bool,
    ) -> crate::process::BlockingReport {
        crate::process::blocking_report(allow_desktop, &self.env.codex_root)
    }

    pub fn refresh_saved_usage_cache(&self) -> Result<()> {
        // Same skip set as refresh_stale_saved_usage: never mass-call usage(Some)
        // across archived / login-blocked / deferred-AT accounts (that burns RTs).
        if codex::add_account_session_active(&self.env) {
            return Ok(());
        }
        let accounts = self.repository.list_accounts(&self.env.kind)?;
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
            if account
                .cached_usage_error
                .as_deref()
                .is_some_and(usage_error_is_deferred_access_token_refresh)
            {
                continue;
            }
            let _ = self.usage(Some(account.id));
        }
        Ok(())
    }

    /// Refresh usage for every saved account whose cached quota is stale, so the
    /// whole roster picks up an off-schedule ChatGPT reset without waiting for a
    /// manual refresh or an auto-switch decision. Accounts that still have quota
    /// in every window (fresh cache) are skipped to avoid needless network and
    /// token churn. Deferred access-token unauthorized accounts are also skipped
    /// here — re-probing them on every display poll burns single-use refresh
    /// tokens and races with add/re-login. RT proof is deferred until
    /// activation/switch (Codex owns refresh then).
    /// Accounts that need a fresh login or local recovery are skipped because
    /// they cannot be refreshed without the user.
    pub fn refresh_stale_saved_usage(&self) -> Result<()> {
        if codex::add_account_session_active(&self.env) {
            return Ok(());
        }
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
            // Do not mass-prove deferred AT accounts on display/background sweeps.
            if account
                .cached_usage_error
                .as_deref()
                .is_some_and(usage_error_is_deferred_access_token_refresh)
            {
                continue;
            }
            if cached_usage_is_fresh(account.cached_usage.as_ref(), now) {
                continue;
            }
            // Exhausted caches never count as fresh; reuse the 10-minute probe
            // backoff so a mostly-exhausted roster does not hold AuthLock ~0.7s
            // per account every 45s poll (that starved auto-switch decide).
            if exhausted_cached_usage_skips_probe(account.cached_usage.as_ref(), now) {
                continue;
            }
            if recent_usage_error_skips_probe(&account, now) {
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
        if codex::add_account_session_active(&self.env) {
            return Ok(());
        }
        let _ = self.usage(None);
        self.refresh_stale_saved_usage()
    }

    pub fn token_usage_summary(&self) -> Result<TokenUsageSummaryOutput> {
        crate::token_usage::summarize_session_tokens(
            &self.env.codex_root.join("sessions"),
            time::OffsetDateTime::now_local().unwrap_or_else(|_| time::OffsetDateTime::now_utc()),
        )
    }

    pub fn quota_history(
        &self,
        account_id: Option<Uuid>,
    ) -> Result<crate::quota_history::QuotaHistoryOutput> {
        let account_id = match account_id {
            Some(id) => id,
            None => self
                .status()?
                .current_account_saved_id
                .ok_or_else(|| anyhow::anyhow!("no active saved account for quota history"))?,
        };
        Ok(crate::quota_history::load_samples(
            &self.env.app_data_dir,
            account_id,
            time::OffsetDateTime::now_utc(),
        ))
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
        write_encrypted(path, &backup, password)?;
        Ok(backup.accounts.len() + backup.provider_accounts.len())
    }

    pub fn import_backup(&self, path: &std::path::Path, password: &str) -> Result<(usize, usize)> {
        let _operation_lock = OperationLock::acquire(&self.env.app_data_dir)?;
        let bundle = read_encrypted(path, password)?;
        self.repository.import_backup(&self.env.kind, bundle)
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
                // Session longevity: never auto-prove / exchange RTs on usage or
                // quota sweeps for inactive saved accounts. A prior AT 401 is
                // sticky-deferred until the user activates/switches — Codex owns
                // refresh then. Re-probing here burned single-use RTs and mass-
                // marked accounts Login required.
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
                        // AT 401 → deferred [access_token_unauthorized] only.
                        // Do not call prove_saved_session_refresh here (hot path).
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
        // Deleting the live account would remove the only rollback snapshot for
        // the session currently in ~/.codex. The app blocks this in the UI; the
        // CLI must refuse it too (review finding 6).
        if self.live_saved_account_id()? == Some(account_id) {
            anyhow::bail!("refusing to delete the active account; switch to another account first");
        }
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
fn activation_process_warnings(
    allow_desktop: bool,
    codex_root: &std::path::Path,
) -> Vec<RunningCodexProcess> {
    crate::process::processes_blocking_activation(allow_desktop, codex_root)
}

#[cfg(test)]
fn activation_process_warnings(
    _allow_desktop: bool,
    _codex_root: &std::path::Path,
) -> Vec<RunningCodexProcess> {
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
        session_resume: None,
        usage_unknown: false,
        warnings: Vec::new(),
        candidate_switch_score: None,
        next_probe_seconds: None,
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

/// Returns true if the window has not yet expired. A window with reset_at in
/// the past is stale and must not be used for decision-making.
fn window_is_current(window: &UsageWindowView, now: OffsetDateTime) -> bool {
    window.reset_at > now
}

fn is_exhausted_for_switch(usage: Option<&AccountUsageView>, now: OffsetDateTime) -> bool {
    if has_usable_credits(usage, now) {
        return false;
    }
    let Some(usage) = usage else {
        return false;
    };
    // Only windows still in effect can be exhausted. A window whose `reset_at`
    // has passed is *unknown* (it may already have reset); the caller must
    // refetch instead of trusting its stale percentage (audit Q1).
    quota_windows(Some(usage))
        .filter(|window| window_is_current(window, now))
        .any(|window| window_is_depleted(window.remaining_percent))
}

/// True when the 5-hour window is known and still in effect. That window is the
/// one that blocks a turn, so it is the gate for "the active account's quota is
/// known" (audit Q3/S2).
fn has_current_five_hour_window(usage: Option<&AccountUsageView>, now: OffsetDateTime) -> bool {
    usage
        .and_then(|usage| usage.five_hour.as_ref())
        .is_some_and(|window| window_is_current(window, now))
}

/// Weekly-dominant usability plus completeness: the 5-hour window is the one
/// that actually blocks a turn, so it must be known, current and not depleted
/// unless the account has usable credits. An unknown or expired 5h window is
/// never eligible (audit Q3). Missing weekly still falls back to 5h-only.
fn is_usable_for_switch(usage: Option<&AccountUsageView>, now: OffsetDateTime) -> bool {
    if has_usable_credits(usage, now) {
        return true;
    }
    let Some(usage) = usage else {
        return false;
    };
    let five_ok = usage.five_hour.as_ref().is_some_and(|five| {
        window_is_current(five, now) && !window_is_depleted(five.remaining_percent)
    });
    if !five_ok {
        return false;
    }
    match usage.weekly.as_ref() {
        Some(weekly) => {
            window_is_current(weekly, now) && !window_is_depleted(weekly.remaining_percent)
        }
        None => true,
    }
}

/// Live revalidation gate: fresh AT usage must be spendable, not exhausted, and
/// not Free/Go. Used by `revalidated_auto_switch_candidate` before list eligibility.
fn fresh_usage_passes_auto_switch_gate(usage: &AccountUsageView, now: OffsetDateTime) -> bool {
    is_usable_for_switch(Some(usage), now)
        && !is_exhausted_for_switch(Some(usage), now)
        && !is_free_plan_label(usage.plan_label.as_deref())
}

/// Deferred AT unauthorized accounts with a still-fresh usable paid cache may be
/// auto-switch candidates without a network usage probe. Never marks Login required.
fn deferred_fresh_usable_auto_switch_candidate(
    candidate: &AccountView,
    active: &AccountView,
    settings: &crate::settings::AppSettings,
    now: time::OffsetDateTime,
) -> bool {
    candidate
        .usage_error
        .as_deref()
        .is_some_and(usage_error_is_deferred_access_token_refresh)
        && candidate.usage.as_ref().is_some_and(|usage| {
            cached_usage_is_fresh(Some(usage), now)
                && fresh_usage_passes_auto_switch_gate(usage, now)
        })
        && is_eligible_auto_switch_candidate(candidate, active, settings, now, None)
}

/// Fresh usable paid cache (within the normal freshness window) may skip a
/// duplicate AT probe during revalidation — typically decide → apply seconds
/// later. Never promotes Free/Go, exhausted, or stale caches.
fn fresh_usable_paid_cached_auto_switch_candidate(
    candidate: &AccountView,
    active: &AccountView,
    settings: &crate::settings::AppSettings,
    now: time::OffsetDateTime,
) -> bool {
    candidate.usage.as_ref().is_some_and(|usage| {
        cached_usage_is_fresh(Some(usage), now) && fresh_usage_passes_auto_switch_gate(usage, now)
    }) && is_eligible_auto_switch_candidate(candidate, active, settings, now, None)
}

/// How long a credits payload stays usable evidence. Credits have no expiry
/// field in the view, so the fetch age is the only bound we have.
const CREDITS_FRESH_MINUTES: i64 = 30;

/// True when the account has spendable credits **and** that observation is
/// recent. Without the age gate a weeks-old `has_credits: true` would suppress
/// auto-switch forever and make a dead account look usable (review finding 3).
/// What is deliberately *not* evidence that an account is dead: a missing
/// 5-hour or weekly window. Free/Go plans have no 7-day limit and only a monthly
/// one, so their primary window is monthly and `weekly` is legitimately absent.
pub const DEAD_ACCOUNT_NOTE: &str = "Missing 5h/7d windows are NOT evidence of a dead account: Free/Go plans have no weekly limit and only a monthly one. Only an explicit account_deactivated error is proof.";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DeadAccountReason {
    /// OpenAI explicitly reported the account as deleted/deactivated.
    Deactivated,
    /// Auth keeps failing and nothing has been fetched for a long time.
    StaleAuthFailure,
}

impl DeadAccountReason {
    fn as_str(self) -> &'static str {
        match self {
            Self::Deactivated => "account_deactivated",
            Self::StaleAuthFailure => "auth_failure_stale",
        }
    }
}

fn classify_dead_account(
    account: &AccountView,
    now: OffsetDateTime,
    stale_days: i64,
) -> Option<(DeadAccountReason, String)> {
    if account.archived {
        return None;
    }
    let error = account.usage_error.as_deref().unwrap_or("");
    if error.is_empty() {
        return None;
    }
    if usage_error_account_deactivated(error) {
        return Some((DeadAccountReason::Deactivated, error.to_owned()));
    }
    // Only auth-shaped failures count, and only when the account has produced
    // nothing for a while. A window that is merely absent never qualifies.
    let auth_failure =
        usage_error_requires_login(error) || usage_error_is_deferred_access_token_refresh(error);
    if !auth_failure {
        return None;
    }
    match account.usage.as_ref().map(|usage| now - usage.fetched_at) {
        None => Some((
            DeadAccountReason::StaleAuthFailure,
            "no usage was ever fetched for this account".to_owned(),
        )),
        Some(age) if age >= time::Duration::days(stale_days.max(1)) => Some((
            DeadAccountReason::StaleAuthFailure,
            format!(
                "auth has been failing for {} day(s) (last successful fetch: {})",
                age.whole_days(),
                account
                    .usage
                    .as_ref()
                    .map(|usage| usage.fetched_at.date().to_string())
                    .unwrap_or_else(|| "never".to_owned())
            ),
        )),
        Some(_) => None,
    }
}

fn dead_account_entry(
    account: AccountView,
    reason: DeadAccountReason,
    detail: String,
) -> DeadAccountEntry {
    let account_id = account.id;
    DeadAccountEntry {
        account_id,
        name: account.name.clone(),
        email: account.email.clone(),
        plan_label: account.plan_label.clone(),
        archived: account.archived,
        is_active: account.is_active,
        reason: reason.as_str().to_owned(),
        detail,
        last_usage_at: account.usage.as_ref().map(|usage| usage.fetched_at),
        suggested_commands: vec![
            format!("codex-roster archive {account_id}"),
            format!("codex-roster delete {account_id}"),
        ],
    }
}

fn has_usable_credits(usage: Option<&AccountUsageView>, now: OffsetDateTime) -> bool {
    let Some(usage) = usage else {
        return false;
    };
    if now - usage.fetched_at > time::Duration::minutes(CREDITS_FRESH_MINUTES) {
        return false;
    }
    usage.credits.as_ref().is_some_and(|credits| {
        credits.unlimited || (credits.has_credits && credit_balance_is_positive(&credits.balance))
    })
}

fn banked_reset_count(usage: Option<&AccountUsageView>, now: OffsetDateTime) -> i64 {
    usage
        .and_then(|usage| usage.banked_resets.as_ref())
        .map(|resets| {
            let from_credits = resets
                .credits
                .as_deref()
                .unwrap_or(&[])
                .iter()
                .filter(|credit| credit.status.eq_ignore_ascii_case("available"))
                // Expired credits are not redeemable (audit Q6).
                .filter(|credit| credit.expires_at.is_none_or(|expires| expires > now))
                .count() as i64;
            resets.available_count.max(0).max(from_credits)
        })
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
        && !is_usable_for_switch(candidate.usage.as_ref(), now)
        && !is_free_plan(candidate)
        && banked_reset_count(candidate.usage.as_ref(), now) > 0
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
        && is_usable_for_switch(candidate.usage.as_ref(), now)
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
        && is_usable_for_switch(candidate.usage.as_ref(), now)
        && !is_free_plan_label(plan_hint_for_auto_switch(candidate))
        && !is_in_auto_switch_cooldown(settings, candidate.id, now)
}

/// Weekly-dominant ranking: `weekly * 1000 + five_hour` so any weekly gap
/// outranks any 5H-only difference. Depleted weekly (or missing usable windows)
/// scores `-1`.
/// Bonus constants for candidate ranking. Documented so the numbers in the UI
/// can be explained (audit U5): a paid plan and an imminent weekly reset are
/// worth more than a slightly fuller window; a stale cache is worth less.
const PLAN_BONUS_PRO: i64 = 15;
const PLAN_BONUS_PLUS: i64 = 5;
const WEEKLY_RESET_BONUS: i64 = 10;
const STALE_CACHE_PENALTY: i64 = 20;
const BANKED_RESET_BONUS: i64 = 5;
const STALE_CACHE_MINUTES: i64 = 10;

fn plan_rank(label: Option<&str>) -> i64 {
    match label.map(|value| value.to_ascii_lowercase()) {
        Some(value) if value.contains("pro") => 2,
        Some(value) if value.contains("plus") => 1,
        _ => 0,
    }
}

/// Full ranking score for one candidate. `None` means "not eligible", which is
/// how the caller excludes Free/Go, exhausted and unusable accounts.
pub fn switch_score_breakdown(
    account: &AccountView,
    now: OffsetDateTime,
) -> Option<crate::model::SwitchScoreBreakdown> {
    let quota = switch_quota_score(account.usage.as_ref(), now);
    if quota < 0 && !is_usable_for_switch(account.usage.as_ref(), now) {
        return None;
    }
    // A credits-only account is usable with no quota score; still explain it
    // instead of omitting the breakdown for exactly the unusual pick
    // (review finding 14).
    let quota = quota.max(0);
    let credits_only = quota == 0;
    let plan_bonus = match plan_rank(plan_for_auto_switch(account)) {
        2 => PLAN_BONUS_PRO,
        1 => PLAN_BONUS_PLUS,
        _ => 0,
    };
    let reset_bonus = account
        .usage
        .as_ref()
        .and_then(|usage| usage.weekly.as_ref())
        .filter(|window| {
            window.reset_at > now && window.reset_at - now <= time::Duration::hours(24)
        })
        .map(|_| WEEKLY_RESET_BONUS)
        .unwrap_or(0);
    let freshness_penalty = account
        .usage
        .as_ref()
        .filter(|usage| now - usage.fetched_at > time::Duration::minutes(STALE_CACHE_MINUTES))
        .map(|_| STALE_CACHE_PENALTY)
        .unwrap_or(0);
    let banked_bonus = if banked_reset_count(account.usage.as_ref(), now) > 0 {
        BANKED_RESET_BONUS
    } else {
        0
    };
    let score = i64::from(quota) + plan_bonus + reset_bonus - freshness_penalty + banked_bonus;
    let mut reasons = if credits_only {
        vec!["credits".to_owned()]
    } else {
        vec![format!("quota {quota}")]
    };
    if plan_bonus > 0 {
        reasons.push(format!("plan +{plan_bonus}"));
    }
    if reset_bonus > 0 {
        reasons.push(format!("weekly reset +{reset_bonus}"));
    }
    if freshness_penalty > 0 {
        reasons.push(format!("stale cache -{freshness_penalty}"));
    }
    if banked_bonus > 0 {
        reasons.push(format!("banked reset +{banked_bonus}"));
    }
    Some(crate::model::SwitchScoreBreakdown {
        score,
        quota_component: i64::from(quota),
        plan_bonus,
        reset_bonus,
        freshness_penalty,
        banked_bonus,
        reason: reasons.join(", "),
    })
}

/// How long the monitor should wait before the next probe when the active
/// account still has quota: nothing can change until its 5-hour window resets,
/// so sleep until then (capped so a clock skew or a manual change is still
/// noticed). Unknown usage keeps the normal cadence (audit A1).
pub const NEXT_PROBE_MAX_IDLE_SECONDS: u64 = 15 * 60;
pub const NEXT_PROBE_MIN_IDLE_SECONDS: u64 = 30;
/// A live CLI session usually ends within seconds to minutes.
pub const NEXT_PROBE_BLOCKED_SECONDS: u64 = 15;

fn next_probe_seconds_for_active(
    usage: Option<&AccountUsageView>,
    settings: &crate::settings::AppSettings,
    now: OffsetDateTime,
) -> Option<u64> {
    let five = usage
        .and_then(|usage| usage.five_hour.as_ref())
        .filter(|window| window_is_current(window, now))?;
    if !window_is_depleted(five.remaining_percent) {
        return None;
    }
    let until_reset = (five.reset_at - now).whole_seconds().max(0) as u64;
    let dwell_seconds = settings.auto_switch_dwell_minutes.saturating_mul(60);
    Some(until_reset.clamp(
        NEXT_PROBE_MIN_IDLE_SECONDS,
        NEXT_PROBE_MAX_IDLE_SECONDS.max(dwell_seconds),
    ))
}

/// Minimum dwell between two automatic switches, applied to the reactive and
/// proactive paths alike so A→B→C→A thrash cannot happen (audit S5/U2).
fn dwell_satisfied(settings: &crate::settings::AppSettings, now: OffsetDateTime) -> bool {
    match settings.last_auto_switch_at {
        Some(last) => {
            now - last >= time::Duration::minutes(settings.auto_switch_dwell_minutes as i64)
        }
        None => true,
    }
}

/// Opt-in proactive trigger: switch before the 5-hour window is empty, but only
/// when the account is idle, the weekly window is healthy, and the dwell has
/// elapsed. Any missing signal means "do not switch" — the reactive path still
/// handles the exhausted case.
fn proactive_switch_allowed(
    usage: Option<&AccountUsageView>,
    settings: &crate::settings::AppSettings,
    idle: bool,
    now: OffsetDateTime,
) -> bool {
    if !settings.auto_switch_proactive || !idle || !dwell_satisfied(settings, now) {
        return false;
    }
    let Some(usage) = usage else {
        return false;
    };
    let Some(five) = usage
        .five_hour
        .as_ref()
        .filter(|window| window_is_current(window, now))
    else {
        return false;
    };
    let Some(weekly) = usage
        .weekly
        .as_ref()
        .filter(|window| window_is_current(window, now))
    else {
        return false;
    };
    five.remaining_percent <= settings.auto_switch_threshold_percent
        && weekly.remaining_percent >= settings.auto_switch_weekly_floor_percent
}

/// Deterministic candidate order: score, then plan, then the least recently
/// activated account, then id. The last two make ties stable across runs so a
/// flip-flop between equal accounts cannot happen (audit U5).
pub fn compare_candidates(
    left: &AccountView,
    right: &AccountView,
    now: OffsetDateTime,
) -> std::cmp::Ordering {
    let left_score = switch_score_breakdown(left, now).map(|breakdown| breakdown.score);
    let right_score = switch_score_breakdown(right, now).map(|breakdown| breakdown.score);
    right_score
        .cmp(&left_score)
        .then_with(|| {
            plan_rank(plan_for_auto_switch(right)).cmp(&plan_rank(plan_for_auto_switch(left)))
        })
        .then_with(|| match (left.last_activated_at, right.last_activated_at) {
            (Some(left_at), Some(right_at)) => left_at.cmp(&right_at),
            (Some(_), None) => std::cmp::Ordering::Less,
            (None, Some(_)) => std::cmp::Ordering::Greater,
            (None, None) => std::cmp::Ordering::Equal,
        })
        .then_with(|| left.id.cmp(&right.id))
}

fn switch_quota_score(usage: Option<&AccountUsageView>, now: OffsetDateTime) -> i32 {
    let Some(usage) = usage else {
        return -1;
    };
    // A missing or expired 5-hour window makes the account ineligible, so it
    // must not outrank an eligible one (audit Q3).
    let Some(five) = usage
        .five_hour
        .as_ref()
        .filter(|window| window_is_current(window, now))
    else {
        return -1;
    };
    if window_is_depleted(five.remaining_percent) {
        return -1;
    }
    if let Some(weekly) = usage
        .weekly
        .as_ref()
        .filter(|window| window_is_current(window, now))
    {
        if window_is_depleted(weekly.remaining_percent) {
            return -1;
        }
        return i32::from(weekly.remaining_percent) * 1000 + i32::from(five.remaining_percent);
    }
    i32::from(five.remaining_percent)
}

/// Keep source/target out of the next auto-switch briefly to avoid thrashing,
/// without blocking a third account or a later recovery switch for long.
const AUTO_SWITCH_ACCOUNT_COOLDOWN: time::Duration = time::Duration::minutes(2);

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
            .is_some_and(|last_switch| now - last_switch < AUTO_SWITCH_ACCOUNT_COOLDOWN)
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
    candidates.sort_by(|left, right| compare_candidates(left, right, now));
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
        let windows = quota_windows(Some(usage)).collect::<Vec<_>>();
        now - usage.fetched_at < time::Duration::minutes(15)
            && !windows.is_empty()
            // Any window past its reset time makes the whole cache stale: the
            // percentage may belong to a window that already reset (audit Q1).
            && windows.iter().all(|window| window_is_current(window, now))
            && windows
                .iter()
                .all(|window| !window_is_depleted(window.remaining_percent))
    })
}

/// Trust a recently fetched unusable/exhausted cache long enough to stop
/// all-exhausted decide from mass AT-probing the roster every 60s.
const EXHAUSTED_USAGE_PROBE_BACKOFF: time::Duration = time::Duration::minutes(10);

/// Decide already re-probed the live account; apply skips a second network
/// probe when that cache is younger than the decide→quit→apply hop.
const RECENT_LIVE_PROBE_WINDOW: time::Duration = time::Duration::seconds(20);

fn exhausted_cached_usage_skips_probe(
    usage: Option<&AccountUsageView>,
    now: time::OffsetDateTime,
) -> bool {
    usage.is_some_and(|usage| {
        !is_usable_for_switch(Some(usage), now)
            && now - usage.fetched_at < EXHAUSTED_USAGE_PROBE_BACKOFF
            // Never let the backoff hide a natural reset: a window whose reset
            // time has passed must be re-probed immediately (audit Q2).
            && quota_windows(Some(usage)).all(|window| window_is_current(window, now))
    })
}

/// A non-login usage failure (e.g. 402 deactivated workspace) recorded within
/// the backoff is not worth another AuthLock-held network probe every sweep.
fn recent_usage_error_skips_probe(
    account: &SavedAccountMetadata,
    now: time::OffsetDateTime,
) -> bool {
    account.cached_usage_error.as_deref().is_some_and(|error| {
        !usage_error_blocks_activation(error)
            && !usage_error_is_deferred_access_token_refresh(error)
            && now - account.updated_at < EXHAUSTED_USAGE_PROBE_BACKOFF
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
    use crate::usage::{
        deferred_access_token_unauthorized_message, usage_error_blocks_activation,
        usage_error_is_deferred_access_token_refresh,
    };
    use time::OffsetDateTime;

    use crate::model::SnapshotFile;
    use crate::model::{
        AccountUsageView, DisplayIdentity, EnvironmentKind, UsageSource, UsageWindowView,
    };
    use crate::secrets::test_support::MemorySecretStore;

    #[test]
    fn luna_reserve_enables_active_and_inactive_saved_accounts_without_recursive_locks() {
        for already_active in [false, true] {
            let temp = tempdir().expect("tempdir");
            let env = AppEnv {
                kind: EnvironmentKind::Linux,
                home_dir: temp.path().to_path_buf(),
                codex_root: temp.path().join(".codex"),
                app_data_dir: temp.path().join("app"),
            };
            std::fs::create_dir_all(&env.codex_root).expect("codex root");
            let target_auth = auth_json_fixture("target@example.com", "target", Some("pro"));
            let (identity, snapshot) =
                codex::snapshot_from_auth_json(target_auth.as_bytes()).expect("snapshot");
            let repo = SnapshotRepository::new(&env.app_data_dir, MemorySecretStore::default());
            let target_id = repo
                .save_snapshot(&env.kind, &identity, &snapshot)
                .expect("save")
                .0
                .id;
            let current_auth = if already_active {
                target_auth
            } else {
                auth_json_fixture("current@example.com", "current", Some("pro"))
            };
            std::fs::write(env.codex_root.join("auth.json"), current_auth).expect("auth");
            std::fs::write(
                env.codex_root.join("config.toml"),
                "model = \"previous-model\"\n",
            )
            .expect("config");
            let app = App::new(env, repo);

            let output = app
                .enable_luna_reserve(Some(target_id))
                .expect("enable Luna");

            assert_eq!(output.account_email, "target@example.com");
            assert_eq!(output.previous_model.as_deref(), Some("previous-model"));
            assert!(
                app.is_live_saved_account(target_id)
                    .expect("selected identity")
            );
            assert_eq!(
                codex::read_configured_model(&app.env.codex_root).as_deref(),
                Some("gpt-5.6-luna")
            );
            let _auth = AuthLock::acquire(&app.env.app_data_dir).expect("released auth lock");
            let _operation =
                OperationLock::acquire(&app.env.app_data_dir).expect("released state lock");
        }
    }

    #[test]
    fn luna_reserve_failed_activation_leaves_model_unchanged() {
        let temp = tempdir().expect("tempdir");
        let env = AppEnv {
            kind: EnvironmentKind::Linux,
            home_dir: temp.path().to_path_buf(),
            codex_root: temp.path().join(".codex"),
            app_data_dir: temp.path().join("app"),
        };
        std::fs::create_dir_all(&env.codex_root).expect("codex root");
        let original = "model = \"previous-model\"\n";
        std::fs::write(env.codex_root.join("config.toml"), original).expect("config");
        let repo = SnapshotRepository::new(&env.app_data_dir, MemorySecretStore::default());
        let app = App::new(env, repo);
        assert!(app.enable_luna_reserve(Some(Uuid::new_v4())).is_err());
        assert!(app.enable_luna_reserve(None).is_err());
        assert_eq!(
            std::fs::read_to_string(app.env.codex_root.join("config.toml")).expect("config"),
            original
        );
    }

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
    fn deferred_unauthorized_saved_account_is_permanently_bailed_until_activation() {
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

        assert!(
            format!("{error:#}").contains("deferred until this account is activated"),
            "deferred AT unauthorized must early-bail (no RT prove on usage path): {error:#}"
        );
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
    fn begin_add_account_persists_latest_live_tokens_before_login_marker() {
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
            auth_json_fixture("live@example.com", "sub-live", Some("pro")),
        )
        .expect("auth");
        std::fs::write(env.codex_root.join("cap_sid"), "sid").expect("cap");

        let app = App::new(
            env.clone(),
            SnapshotRepository::new(&env.app_data_dir, MemorySecretStore::default()),
        );
        let live_id = app.save_current().expect("initial save").account.id;

        let mut rotated: serde_json::Value = serde_json::from_str(&auth_json_fixture(
            "live@example.com",
            "sub-live",
            Some("pro"),
        ))
        .expect("fixture json");
        rotated["tokens"]["refresh_token"] = serde_json::json!("rotated-live-refresh");
        rotated["tokens"]["access_token"] = serde_json::json!("rotated-live-access");
        std::fs::write(
            env.codex_root.join("auth.json"),
            serde_json::to_string_pretty(&rotated).expect("serialize"),
        )
        .expect("write rotated live auth");

        app.begin_add_account_session()
            .expect("begin must save live then set marker");
        assert!(app.add_account_session_active());

        let (_, snapshot) = app
            .repository
            .load_snapshot(&app.env.kind, live_id)
            .expect("load preserved snapshot");
        let auth_file = snapshot
            .files
            .iter()
            .find(|file| file.name == "auth.json")
            .expect("auth.json in snapshot");
        let auth_bytes = base64::engine::general_purpose::STANDARD
            .decode(&auth_file.bytes_base64)
            .expect("decode snapshot auth");
        let saved_auth: serde_json::Value =
            serde_json::from_slice(&auth_bytes).expect("parse snapshot auth");
        assert_eq!(
            saved_auth["tokens"]["refresh_token"].as_str(),
            Some("rotated-live-refresh"),
            "begin-add must write back the current live RT before login can replace ~/.codex"
        );

        let usage_error = app
            .usage(None)
            .expect_err("usage must pause while add-account is active");
        assert!(
            format!("{usage_error:#}").contains("login is in progress"),
            "unexpected usage error during login: {usage_error:#}"
        );
        app.refresh_stale_saved_usage()
            .expect("stale sweep must no-op during login");
        app.refresh_usage_for_display()
            .expect("display refresh must no-op during login");

        app.cancel_add_account_session().expect("cancel");
    }

    #[test]
    fn refresh_stale_saved_usage_skips_deferred_access_token_accounts() {
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
                    email: "deferred@example.com".to_owned(),
                    subject: Some("sub-deferred".to_owned()),
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
        // Fresh cached quota would normally skip, but the regression forced a
        // reprove for deferred accounts even then — ensure that path is gone.
        let fresh_usage = AccountUsageView {
            primary_window_kind: None,
            source: UsageSource::SavedAccessToken,
            fetched_at: OffsetDateTime::now_utc(),
            five_hour: Some(UsageWindowView {
                used_percent: 10,
                remaining_percent: 90,
                reset_at: OffsetDateTime::now_utc() + time::Duration::hours(5),
            }),
            weekly: Some(UsageWindowView {
                used_percent: 10,
                remaining_percent: 90,
                reset_at: OffsetDateTime::now_utc() + time::Duration::hours(5),
            }),
            credits: None,
            banked_resets: None,
            plan_label: Some("Plus".to_owned()),
            subscription_active_until: None,
            luna_reserve: None,
            five_hour_known: false,
            weekly_known: false,
        };
        repo.replace_snapshot_without_backup(
            &env.kind,
            saved.id,
            &DisplayIdentity {
                email: "deferred@example.com".to_owned(),
                subject: Some("sub-deferred".to_owned()),
                name: None,
                plan_label: Some("Plus".to_owned()),
            },
            &SnapshotBlob {
                schema_version: 1,
                files: vec![],
            },
            Some(fresh_usage),
        )
        .expect("seed fresh usage");
        repo.record_usage_error(
            &env.kind,
            saved.id,
            deferred_access_token_unauthorized_message(),
        )
        .expect("record deferred");

        let app = App::new(env, repo);
        app.refresh_stale_saved_usage()
            .expect("deferred accounts must be skipped by display/background sweeps");

        let account = app
            .repository
            .get_account(&app.env.kind, saved.id)
            .expect("load")
            .expect("account");
        assert!(
            account
                .cached_usage_error
                .as_deref()
                .is_some_and(usage_error_is_deferred_access_token_refresh),
            "sweep must not escalate or clear deferred status: {:?}",
            account.cached_usage_error
        );
        assert!(
            !account
                .cached_usage_error
                .as_deref()
                .is_some_and(|error| error.contains("Login required")),
            "sweep must not mark deferred accounts Login required"
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

    fn window_view(remaining: u8, reset_in_hours: i64) -> UsageWindowView {
        UsageWindowView {
            used_percent: 100u8.saturating_sub(remaining),
            remaining_percent: remaining,
            reset_at: OffsetDateTime::now_utc() + time::Duration::hours(reset_in_hours),
        }
    }

    fn usage_with(
        five: Option<UsageWindowView>,
        weekly: Option<UsageWindowView>,
        credits: Option<crate::model::CreditsView>,
        fetched_minutes_ago: i64,
    ) -> AccountUsageView {
        AccountUsageView {
            primary_window_kind: None,
            source: UsageSource::LiveAccessToken,
            fetched_at: OffsetDateTime::now_utc() - time::Duration::minutes(fetched_minutes_ago),
            five_hour_known: five.is_some(),
            weekly_known: weekly.is_some(),
            five_hour: five,
            weekly,
            credits,
            banked_resets: None,
            plan_label: Some("Plus".to_owned()),
            subscription_active_until: None,
            luna_reserve: None,
        }
    }

    #[test]
    fn expired_window_is_unknown_not_usable_or_exhausted() {
        let now = OffsetDateTime::now_utc();
        // Plenty of percentage left, but the window's reset time already passed:
        // the number belongs to a window that may have reset (audit Q1).
        let stale = usage_with(
            Some(window_view(90, -1)),
            Some(window_view(80, -2)),
            None,
            2,
        );
        assert!(!has_current_five_hour_window(Some(&stale), now));
        assert!(!is_usable_for_switch(Some(&stale), now));
        assert!(!is_exhausted_for_switch(Some(&stale), now));
        assert!(!cached_usage_is_fresh(Some(&stale), now));

        // Same percentages with current windows stay usable.
        let current = usage_with(Some(window_view(90, 1)), Some(window_view(80, 48)), None, 2);
        assert!(has_current_five_hour_window(Some(&current), now));
        assert!(is_usable_for_switch(Some(&current), now));
        assert!(cached_usage_is_fresh(Some(&current), now));
    }

    #[test]
    fn missing_five_hour_window_is_not_eligible_without_credits() {
        let now = OffsetDateTime::now_utc();
        // Weekly looks healthy but the 5h window (the one that blocks turns) is
        // absent: not eligible, and not a reason to claim active_has_quota.
        let no_five = usage_with(None, Some(window_view(90, 48)), None, 1);
        assert!(!is_usable_for_switch(Some(&no_five), now));
        assert!(!has_current_five_hour_window(Some(&no_five), now));
        assert_eq!(switch_quota_score(Some(&no_five), now), -1);

        // Usable credits make the account spendable even without a 5h window.
        let credits = crate::model::CreditsView {
            has_credits: true,
            unlimited: false,
            balance: "12.50".to_owned(),
            credit_limit: None,
        };
        let with_credits = usage_with(None, Some(window_view(90, 48)), Some(credits), 1);
        assert!(is_usable_for_switch(Some(&with_credits), now));
    }

    #[test]
    fn exhausted_probe_backoff_never_hides_a_natural_reset() {
        let now = OffsetDateTime::now_utc();
        // Exhausted 3 minutes ago with a reset still in the future: back off.
        let pending = usage_with(Some(window_view(0, 1)), Some(window_view(0, 48)), None, 3);
        assert!(exhausted_cached_usage_skips_probe(Some(&pending), now));

        // Same cache, but a window's reset time already passed: probe now, so a
        // natural reset is never hidden for up to ten minutes (audit Q2).
        let reset_passed = usage_with(Some(window_view(0, -1)), Some(window_view(0, 48)), None, 3);
        assert!(!exhausted_cached_usage_skips_probe(
            Some(&reset_passed),
            now
        ));
    }

    #[test]
    fn auto_switch_requires_every_reported_window_to_be_usable() {
        let usage = AccountUsageView {
            primary_window_kind: None,
            source: UsageSource::SavedAccessToken,
            fetched_at: OffsetDateTime::now_utc(),
            five_hour: Some(UsageWindowView {
                used_percent: 100,
                remaining_percent: 0,
                reset_at: OffsetDateTime::now_utc() + time::Duration::hours(5),
            }),
            weekly: Some(UsageWindowView {
                used_percent: 10,
                remaining_percent: 90,
                reset_at: OffsetDateTime::now_utc() + time::Duration::hours(5),
            }),
            credits: None,
            banked_resets: None,
            plan_label: None,
            subscription_active_until: None,
            luna_reserve: None,
            five_hour_known: false,
            weekly_known: false,
        };
        let now = OffsetDateTime::now_utc();

        assert!(is_exhausted_for_switch(Some(&usage), now));
        assert!(!is_usable_for_switch(Some(&usage), now));
    }

    #[test]
    fn auto_switch_weekly_depleted_blocks_leftover_five_hour() {
        let now = OffsetDateTime::now_utc();
        let weekly_dead = AccountUsageView {
            primary_window_kind: None,
            source: UsageSource::SavedAccessToken,
            fetched_at: now,
            five_hour: Some(UsageWindowView {
                used_percent: 10,
                remaining_percent: 90,
                reset_at: now + time::Duration::hours(5),
            }),
            weekly: Some(UsageWindowView {
                used_percent: 100,
                remaining_percent: 0,
                reset_at: now + time::Duration::hours(5),
            }),
            credits: None,
            banked_resets: None,
            plan_label: Some("Pro".to_owned()),
            subscription_active_until: None,
            luna_reserve: None,
            five_hour_known: false,
            weekly_known: false,
        };
        assert!(is_exhausted_for_switch(Some(&weekly_dead), now));
        assert!(!is_usable_for_switch(Some(&weekly_dead), now));
        assert_eq!(switch_quota_score(Some(&weekly_dead), now), -1);

        let high_weekly = AccountUsageView {
            five_hour: Some(UsageWindowView {
                used_percent: 95,
                remaining_percent: 5,
                reset_at: now + time::Duration::hours(5),
            }),
            weekly: Some(UsageWindowView {
                used_percent: 40,
                remaining_percent: 60,
                reset_at: now + time::Duration::hours(5),
            }),
            ..weekly_dead.clone()
        };
        let low_weekly = AccountUsageView {
            five_hour: Some(UsageWindowView {
                used_percent: 1,
                remaining_percent: 99,
                reset_at: now + time::Duration::hours(5),
            }),
            weekly: Some(UsageWindowView {
                used_percent: 50,
                remaining_percent: 50,
                reset_at: now + time::Duration::hours(5),
            }),
            ..weekly_dead
        };
        assert!(is_usable_for_switch(Some(&high_weekly), now));
        assert!(is_usable_for_switch(Some(&low_weekly), now));
        assert_eq!(switch_quota_score(Some(&high_weekly), now), 60_005);
        assert_eq!(switch_quota_score(Some(&low_weekly), now), 50_099);
        assert!(
            switch_quota_score(Some(&high_weekly), now)
                > switch_quota_score(Some(&low_weekly), now)
        );
    }

    fn scored_candidate(
        email: &str,
        plan: Option<&str>,
        five: u8,
        weekly: u8,
        last_activated_minutes_ago: Option<i64>,
    ) -> AccountView {
        let now = OffsetDateTime::now_utc();
        AccountView {
            id: Uuid::new_v4(),
            provider: crate::model::AiProvider::OpenAi,
            email: email.to_owned(),
            subject: None,
            name: None,
            custom_label: None,
            plan_label: plan.map(str::to_owned),
            environment: EnvironmentKind::Linux,
            is_active: false,
            created_at: now,
            updated_at: now,
            last_activated_at: last_activated_minutes_ago
                .map(|minutes| now - time::Duration::minutes(minutes)),
            archived: false,
            // `plan_for_auto_switch` trusts the usage-reported plan once a
            // fetch exists, so the fixture must set it there.
            usage: Some(AccountUsageView {
                plan_label: plan.map(str::to_owned),
                ..usage_with(
                    Some(window_view(five, 1)),
                    Some(window_view(weekly, 48)),
                    None,
                    1,
                )
            }),
            usage_error: None,
        }
    }

    fn proactive_settings() -> crate::settings::AppSettings {
        crate::settings::AppSettings {
            auto_switch_proactive: true,
            ..crate::settings::AppSettings::default()
        }
    }

    fn credits_view(unlimited: bool, balance: &str) -> crate::model::CreditsView {
        crate::model::CreditsView {
            has_credits: true,
            unlimited,
            balance: balance.to_owned(),
            credit_limit: None,
        }
    }

    fn dead_candidate(
        email: &str,
        plan: &str,
        error: &str,
        usage: Option<AccountUsageView>,
    ) -> AccountView {
        let now = OffsetDateTime::now_utc();
        AccountView {
            id: Uuid::new_v4(),
            provider: crate::model::AiProvider::OpenAi,
            email: email.to_owned(),
            subject: None,
            name: None,
            custom_label: None,
            plan_label: Some(plan.to_owned()),
            environment: EnvironmentKind::Linux,
            is_active: false,
            created_at: now,
            updated_at: now,
            last_activated_at: None,
            archived: false,
            usage,
            usage_error: if error.is_empty() {
                None
            } else {
                Some(error.to_owned())
            },
        }
    }

    #[test]
    fn a_deactivated_account_is_confirmed_while_a_stale_auth_failure_is_only_a_suspect() {
        let now = OffsetDateTime::now_utc();
        // Authoritative: OpenAI said the account is gone.
        let deactivated = dead_candidate(
            "gone@example.com",
            "K12",
            "Account deactivated [account_deactivated]: OpenAI reports this account was deleted or deactivated",
            None,
        );
        assert_eq!(
            classify_dead_account(&deactivated, now, 14).map(|(reason, _)| reason),
            Some(DeadAccountReason::Deactivated)
        );

        // Corroborating only: auth keeps failing and nothing was ever fetched.
        let stale = dead_candidate(
            "stale@example.com",
            "Free",
            "Usage unavailable [access_token_unauthorized]: OpenAI rejected the current access token, but the saved refresh token was not proven invalid.",
            None,
        );
        assert_eq!(
            classify_dead_account(&stale, now, 14).map(|(reason, _)| reason),
            Some(DeadAccountReason::StaleAuthFailure)
        );

        // Same error but a recent successful fetch: still healthy, not a suspect.
        let healthy = dead_candidate(
            "healthy@example.com",
            "Free",
            "Usage unavailable [access_token_unauthorized]: OpenAI rejected the current access token, but the saved refresh token was not proven invalid.",
            Some(usage_with(None, None, None, 5)),
        );
        assert!(classify_dead_account(&healthy, now, 14).is_none());

        // Archived accounts are already out of the way.
        let mut archived = stale.clone();
        archived.archived = true;
        assert!(classify_dead_account(&archived, now, 14).is_none());
    }

    #[test]
    fn a_free_go_account_with_only_a_monthly_window_is_never_flagged() {
        let now = OffsetDateTime::now_utc();
        // Free/Go plans have no weekly limit and only a monthly one, so the
        // primary window arrives as `five_hour` with a reset a month out and
        // `weekly` is absent. That must not look like a dead account.
        let free = dead_candidate(
            "free@example.com",
            "Free",
            "",
            Some(usage_with(
                Some(window_view(0, 60 * 24 * 30)),
                None,
                None,
                3,
            )),
        );
        assert!(
            classify_dead_account(&free, now, 14).is_none(),
            "a Free account with only a monthly window and no error must not be flagged"
        );
        // And with an auth error but a fresh monthly fetch, it is still healthy.
        let mut errored = free.clone();
        errored.usage_error = Some(
            "Usage unavailable [access_token_unauthorized]: OpenAI rejected the current access token"
                .to_owned(),
        );
        assert!(classify_dead_account(&errored, now, 14).is_none());
        assert!(DEAD_ACCOUNT_NOTE.contains("Free/Go"));
    }

    #[test]
    fn delete_refuses_the_account_that_is_currently_live() {
        let swap = auto_switch_swap_fixture();
        let error = swap
            .app
            .delete(swap.active_id)
            .expect_err("deleting the live account must be refused");
        assert!(
            format!("{error:#}").contains("active account"),
            "unexpected error: {error:#}"
        );
        // A saved account that is not the live session is still deletable.
        swap.app
            .delete(swap.candidate_id)
            .expect("a non-live account stays deletable");
    }

    #[test]
    fn stale_credits_do_not_suppress_switching_forever() {
        let now = OffsetDateTime::now_utc();
        // Fresh credits with a positive balance make an exhausted account usable.
        let fresh = usage_with(
            Some(window_view(0, 1)),
            Some(window_view(0, 48)),
            Some(credits_view(false, "12.50")),
            1,
        );
        assert!(has_usable_credits(Some(&fresh), now));
        assert!(!is_exhausted_for_switch(Some(&fresh), now));

        // The same payload a week later is not evidence any more (review
        // finding 3: credits have no expiry field, so the fetch age bounds them).
        let stale = usage_with(
            Some(window_view(0, 1)),
            Some(window_view(0, 48)),
            Some(credits_view(false, "12.50")),
            7 * 24 * 60,
        );
        assert!(!has_usable_credits(Some(&stale), now));
        assert!(
            is_exhausted_for_switch(Some(&stale), now),
            "a stale credits payload must not keep an exhausted account switchable"
        );
        assert!(!is_usable_for_switch(Some(&stale), now));
    }

    #[test]
    fn unlimited_credits_also_expire_with_the_observation() {
        let now = OffsetDateTime::now_utc();
        let fresh = usage_with(None, None, Some(credits_view(true, "0")), 2);
        assert!(has_usable_credits(Some(&fresh), now));
        let stale = usage_with(None, None, Some(credits_view(true, "0")), 120);
        assert!(!has_usable_credits(Some(&stale), now));
    }

    #[test]
    fn next_probe_waits_for_an_exhausted_window_to_reset() {
        let now = OffsetDateTime::now_utc();
        let settings = crate::settings::AppSettings::default();
        let mut usage = usage_with(Some(window_view(0, 1)), Some(window_view(50, 48)), None, 1);
        usage.five_hour.as_mut().unwrap().reset_at = now + time::Duration::minutes(5);

        let scheduled =
            next_probe_seconds_for_active(Some(&usage), &settings, now).expect("scheduled");
        assert!(
            (295..=305).contains(&scheduled),
            "expected ~300s until the reset, got {scheduled}"
        );

        // A reset far away is capped so a manual change is still noticed.
        usage.five_hour.as_mut().unwrap().reset_at = now + time::Duration::hours(3);
        assert_eq!(
            next_probe_seconds_for_active(Some(&usage), &settings, now),
            Some(NEXT_PROBE_MAX_IDLE_SECONDS)
        );
    }

    #[test]
    fn a_healthy_or_unknown_window_keeps_the_normal_cadence() {
        let now = OffsetDateTime::now_utc();
        let settings = crate::settings::AppSettings::default();
        // Plenty of quota: nothing to schedule, use the default poll.
        let healthy = usage_with(Some(window_view(80, 1)), Some(window_view(90, 48)), None, 1);
        assert_eq!(
            next_probe_seconds_for_active(Some(&healthy), &settings, now),
            None
        );
        // No usage at all: keep probing.
        assert_eq!(next_probe_seconds_for_active(None, &settings, now), None);
    }

    #[test]
    fn proactive_switch_stays_off_unless_enabled() {
        let now = OffsetDateTime::now_utc();
        // 3% left is inside the default 5% threshold, but the feature is opt-in.
        let usage = usage_with(Some(window_view(3, 1)), Some(window_view(50, 48)), None, 1);
        let settings = crate::settings::AppSettings::default();
        assert!(!proactive_switch_allowed(
            Some(&usage),
            &settings,
            true,
            now
        ));
        assert!(proactive_switch_allowed(
            Some(&usage),
            &proactive_settings(),
            true,
            now
        ));
    }

    #[test]
    fn proactive_switch_requires_an_idle_account() {
        let now = OffsetDateTime::now_utc();
        let usage = usage_with(Some(window_view(3, 1)), Some(window_view(50, 48)), None, 1);
        assert!(!proactive_switch_allowed(
            Some(&usage),
            &proactive_settings(),
            false,
            now
        ));
    }

    #[test]
    fn proactive_switch_respects_threshold_and_weekly_floor() {
        let now = OffsetDateTime::now_utc();
        let settings = proactive_settings();
        // Above the 5% threshold: no proactive switch.
        let healthy = usage_with(Some(window_view(40, 1)), Some(window_view(50, 48)), None, 1);
        assert!(!proactive_switch_allowed(
            Some(&healthy),
            &settings,
            true,
            now
        ));
        // Below the threshold but the weekly window is nearly spent: refuse.
        let thin_week = usage_with(Some(window_view(3, 1)), Some(window_view(10, 48)), None, 1);
        assert!(!proactive_switch_allowed(
            Some(&thin_week),
            &settings,
            true,
            now
        ));
        // Unknown windows never trigger it.
        assert!(!proactive_switch_allowed(None, &settings, true, now));
    }

    #[test]
    fn dwell_blocks_a_second_switch_until_it_elapses() {
        let now = OffsetDateTime::now_utc();
        let mut settings = proactive_settings();
        assert!(dwell_satisfied(&settings, now), "no previous switch");
        settings.last_auto_switch_at = Some(now - time::Duration::minutes(5));
        assert!(
            !dwell_satisfied(&settings, now),
            "default dwell is 10 minutes"
        );
        let usage = usage_with(Some(window_view(3, 1)), Some(window_view(50, 48)), None, 1);
        assert!(!proactive_switch_allowed(
            Some(&usage),
            &settings,
            true,
            now
        ));
        settings.last_auto_switch_at = Some(now - time::Duration::minutes(11));
        assert!(dwell_satisfied(&settings, now));
        assert!(proactive_switch_allowed(Some(&usage), &settings, true, now));
    }

    #[test]
    fn switch_score_is_monotonic_in_weekly_quota() {
        let now = OffsetDateTime::now_utc();
        let low = scored_candidate("low@example.com", Some("Plus"), 50, 30, None);
        let high = scored_candidate("high@example.com", Some("Plus"), 50, 70, None);
        let low_score = switch_score_breakdown(&low, now).expect("eligible").score;
        let high_score = switch_score_breakdown(&high, now).expect("eligible").score;
        assert!(
            high_score > low_score,
            "weekly 70 ({high_score}) must outrank weekly 30 ({low_score})"
        );
    }

    #[test]
    fn switch_score_explains_its_components() {
        let now = OffsetDateTime::now_utc();
        let account = scored_candidate("pro@example.com", Some("Pro"), 10, 80, None);
        let breakdown = switch_score_breakdown(&account, now).expect("eligible");
        assert_eq!(breakdown.quota_component, 80_010);
        assert_eq!(breakdown.plan_bonus, PLAN_BONUS_PRO);
        assert_eq!(breakdown.freshness_penalty, 0, "cache is one minute old");
        assert_eq!(breakdown.score, 80_010 + PLAN_BONUS_PRO);
        assert!(breakdown.reason.contains("quota 80010"));
    }

    #[test]
    fn ineligible_candidates_have_no_score() {
        let now = OffsetDateTime::now_utc();
        let mut depleted = scored_candidate("empty@example.com", Some("Plus"), 0, 0, None);
        assert!(switch_score_breakdown(&depleted, now).is_none());
        depleted.usage = None;
        assert!(switch_score_breakdown(&depleted, now).is_none());
    }

    #[test]
    fn tie_break_is_deterministic_by_plan_then_age_then_id() {
        let now = OffsetDateTime::now_utc();
        // Identical quota: the paid plan must win, then the least recently used.
        let pro = scored_candidate("pro@example.com", Some("Pro"), 50, 50, Some(30));
        let plus_old = scored_candidate("plus-old@example.com", Some("Plus"), 50, 50, Some(90));
        let plus_new = scored_candidate("plus-new@example.com", Some("Plus"), 50, 50, Some(5));
        let mut ranked = [plus_new.clone(), pro.clone(), plus_old.clone()];
        ranked.sort_by(|left, right| compare_candidates(left, right, now));
        assert_eq!(ranked[0].email, pro.email, "Pro plan wins the tie");
        assert_eq!(ranked[1].email, plus_old.email, "older activation first");
        assert_eq!(ranked[2].email, plus_new.email);

        // Sorting is stable regardless of the input order.
        let mut reversed = [plus_new, plus_old, pro];
        reversed.sort_by(|left, right| compare_candidates(left, right, now));
        assert_eq!(ranked[0].email, reversed[0].email);
        assert_eq!(ranked[1].email, reversed[1].email);
    }

    #[test]
    fn golden_ranking_of_five_candidates() {
        let now = OffsetDateTime::now_utc();
        let candidates = vec![
            scored_candidate("a@example.com", Some("Plus"), 5, 20, None),
            scored_candidate("b@example.com", Some("Pro"), 90, 60, None),
            scored_candidate("c@example.com", Some("Plus"), 99, 50, None),
            scored_candidate("d@example.com", Some("Plus"), 10, 60, None),
            // 1% is already treated as exhausted, so keep every row eligible.
            scored_candidate("e@example.com", Some("Plus"), 4, 55, None),
        ];
        let mut ranked = candidates.clone();
        ranked.sort_by(|left, right| compare_candidates(left, right, now));
        let order: Vec<&str> = ranked
            .iter()
            .map(|account| account.email.as_str())
            .collect();
        // b (weekly 60 + Pro) > d (weekly 60) > e (weekly 55) > c (weekly 50) > a (weekly 20)
        assert_eq!(
            order,
            vec![
                "b@example.com",
                "d@example.com",
                "e@example.com",
                "c@example.com",
                "a@example.com"
            ]
        );
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

        let expired = crate::settings::AppSettings {
            last_auto_switch_at: Some(now - time::Duration::minutes(2)),
            last_auto_switch_target: Some(target),
            last_auto_switch_from: Some(from),
            ..crate::settings::AppSettings::default()
        };
        assert!(!is_in_auto_switch_cooldown(&expired, from, now));
        assert!(!is_in_auto_switch_cooldown(&expired, target, now));
    }

    #[test]
    fn auto_switch_uses_usage_plan_not_stale_roster_label() {
        let now = OffsetDateTime::now_utc();
        let usage = |plan: Option<&str>| AccountUsageView {
            primary_window_kind: None,
            source: UsageSource::SavedAccessToken,
            fetched_at: now,
            five_hour: Some(UsageWindowView {
                used_percent: 10,
                remaining_percent: 90,
                reset_at: now + time::Duration::hours(5),
            }),
            weekly: Some(UsageWindowView {
                used_percent: 10,
                remaining_percent: 90,
                reset_at: now + time::Duration::hours(5),
            }),
            credits: None,
            banked_resets: None,
            plan_label: plan.map(str::to_owned),
            subscription_active_until: None,
            luna_reserve: None,
            five_hour_known: false,
            weekly_known: false,
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
            primary_window_kind: None,
            source: UsageSource::SavedAccessToken,
            fetched_at: now,
            five_hour: Some(UsageWindowView {
                used_percent: 100u8.saturating_sub(remaining),
                remaining_percent: remaining,
                reset_at: now + time::Duration::hours(5),
            }),
            weekly: Some(UsageWindowView {
                used_percent: 100u8.saturating_sub(remaining),
                remaining_percent: remaining,
                reset_at: now + time::Duration::hours(5),
            }),
            credits,
            banked_resets: None,
            plan_label: Some("Pro".to_owned()),
            subscription_active_until: None,
            luna_reserve: None,
            five_hour_known: false,
            weekly_known: false,
        };

        let exhausted = usage(0, None);
        assert!(is_exhausted_for_switch(Some(&exhausted), now));
        assert!(!is_usable_for_switch(Some(&exhausted), now));

        let unlimited = usage(
            0,
            Some(crate::model::CreditsView {
                has_credits: false,
                unlimited: true,
                balance: "0".to_owned(),
                credit_limit: None,
            }),
        );
        assert!(!is_exhausted_for_switch(Some(&unlimited), now));
        assert!(is_usable_for_switch(Some(&unlimited), now));

        let paid_credits = usage(
            0,
            Some(crate::model::CreditsView {
                has_credits: true,
                unlimited: false,
                balance: "12.50".to_owned(),
                credit_limit: None,
            }),
        );
        assert!(!is_exhausted_for_switch(Some(&paid_credits), now));
        assert!(is_usable_for_switch(Some(&paid_credits), now));

        let empty_credits = usage(
            0,
            Some(crate::model::CreditsView {
                has_credits: true,
                unlimited: false,
                balance: "0".to_owned(),
                credit_limit: None,
            }),
        );
        assert!(is_exhausted_for_switch(Some(&empty_credits), now));
        assert!(!is_usable_for_switch(Some(&empty_credits), now));
    }

    #[test]
    fn floored_ninety_nine_percent_window_counts_as_exhausted() {
        // OpenAI floors `used_percent`, so a window ChatGPT already blocks reads
        // back as 99/1 instead of 100/0. It must not be treated as spendable
        // quota, otherwise the switcher stalls on an account that cannot serve
        // another request.
        let now = OffsetDateTime::now_utc();
        let depleted = AccountUsageView {
            primary_window_kind: None,
            source: UsageSource::SavedAccessToken,
            fetched_at: now,
            five_hour: Some(UsageWindowView {
                used_percent: 99,
                remaining_percent: 1,
                reset_at: now + time::Duration::hours(5),
            }),
            weekly: None,
            credits: None,
            banked_resets: None,
            plan_label: Some("Pro".to_owned()),
            subscription_active_until: None,
            luna_reserve: None,
            five_hour_known: false,
            weekly_known: false,
        };
        assert!(is_exhausted_for_switch(Some(&depleted), now));
        assert!(!is_usable_for_switch(Some(&depleted), now));
        assert!(!cached_usage_is_fresh(Some(&depleted), now));

        let usable = AccountUsageView {
            five_hour: Some(UsageWindowView {
                used_percent: 98,
                remaining_percent: 2,
                reset_at: now + time::Duration::hours(5),
            }),
            ..depleted
        };
        assert!(!is_exhausted_for_switch(Some(&usable), now));
        assert!(is_usable_for_switch(Some(&usable), now));
    }

    #[test]
    fn auto_switch_reports_banked_resets_without_treating_them_as_spendable_quota() {
        let now = OffsetDateTime::now_utc();
        let usage = |plan: &str, reset_count: i64| AccountUsageView {
            primary_window_kind: None,
            source: UsageSource::SavedAccessToken,
            fetched_at: now,
            five_hour: Some(UsageWindowView {
                used_percent: 100,
                remaining_percent: 0,
                reset_at: now + time::Duration::hours(5),
            }),
            weekly: None,
            credits: None,
            banked_resets: Some(crate::model::BankedResetSummaryView {
                available_count: reset_count,
                credits: None,
            }),
            plan_label: Some(plan.to_owned()),
            subscription_active_until: None,
            luna_reserve: None,
            five_hour_known: false,
            weekly_known: false,
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

        assert!(is_exhausted_for_switch(candidate.usage.as_ref(), now));
        assert!(!is_usable_for_switch(candidate.usage.as_ref(), now));
        assert_eq!(banked_reset_count(candidate.usage.as_ref(), now), 1);
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
            reset_at: now + time::Duration::hours(5),
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
                primary_window_kind: None,
                source: UsageSource::SavedAccessToken,
                fetched_at: now,
                five_hour: Some(window(remaining)),
                weekly: Some(window(remaining)),
                credits: None,
                banked_resets: None,
                plan_label: Some(plan.to_owned()),
                subscription_active_until: None,
                luna_reserve: None,
                five_hour_known: false,
                weekly_known: false,
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
    fn auto_switch_exhausted_zero_percent_never_passes_fresh_gate_or_eligibility() {
        // Exhausted 0% 5H/Weekly must never be eligible, and revalidation's fresh
        // usage gate must reject it (returns None path in revalidated_*).
        let now = OffsetDateTime::now_utc();
        let settings = crate::settings::AppSettings::default();
        let window = |remaining: u8| UsageWindowView {
            used_percent: 100u8.saturating_sub(remaining),
            remaining_percent: remaining,
            reset_at: now + time::Duration::hours(5),
        };
        let exhausted_usage = AccountUsageView {
            primary_window_kind: None,
            source: UsageSource::SavedAccessToken,
            fetched_at: now,
            five_hour: Some(window(0)),
            weekly: Some(window(0)),
            credits: None,
            banked_resets: None,
            plan_label: Some("Pro".to_owned()),
            subscription_active_until: None,
            luna_reserve: None,
            five_hour_known: false,
            weekly_known: false,
        };
        let exhausted = AccountView {
            id: Uuid::new_v4(),
            provider: crate::model::AiProvider::OpenAi,
            email: "exhausted@example.com".to_owned(),
            subject: Some("subject-exhausted".to_owned()),
            name: None,
            custom_label: None,
            plan_label: Some("Pro".to_owned()),
            environment: EnvironmentKind::Linux,
            is_active: false,
            created_at: now,
            updated_at: now,
            last_activated_at: None,
            archived: false,
            usage: Some(exhausted_usage.clone()),
            usage_error: None,
        };
        let mut active = exhausted.clone();
        active.id = Uuid::new_v4();
        active.email = "active@example.com".to_owned();
        active.subject = Some("subject-active".to_owned());
        active.is_active = true;

        assert!(is_exhausted_for_switch(Some(&exhausted_usage), now));
        assert!(!is_usable_for_switch(Some(&exhausted_usage), now));
        assert!(!fresh_usage_passes_auto_switch_gate(&exhausted_usage, now));
        assert!(!is_eligible_auto_switch_candidate(
            &exhausted, &active, &settings, now, None
        ));
        // Preferred exhausted id: apply's revalidation + final belt both refuse.
        let preferred_exhausted_would_activate =
            fresh_usage_passes_auto_switch_gate(exhausted.usage.as_ref().expect("usage"), now)
                && is_eligible_auto_switch_candidate(&exhausted, &active, &settings, now, None);
        assert!(
            !preferred_exhausted_would_activate,
            "apply must not activate a preferred exhausted id"
        );
        let apply_status = if preferred_exhausted_would_activate {
            "switched"
        } else {
            "all_accounts_exhausted"
        };
        assert_eq!(apply_status, "all_accounts_exhausted");
    }

    #[test]
    fn exhausted_cached_usage_skips_probe_within_backoff_then_allows_refetch() {
        let now = OffsetDateTime::now_utc();
        let window = |remaining: u8| UsageWindowView {
            used_percent: 100u8.saturating_sub(remaining),
            remaining_percent: remaining,
            reset_at: now + time::Duration::hours(5),
        };
        let recent_exhausted = AccountUsageView {
            primary_window_kind: None,
            source: UsageSource::SavedAccessToken,
            fetched_at: now - time::Duration::minutes(2),
            five_hour: Some(window(0)),
            weekly: Some(window(0)),
            credits: None,
            banked_resets: None,
            plan_label: Some("Pro".to_owned()),
            subscription_active_until: None,
            luna_reserve: None,
            five_hour_known: false,
            weekly_known: false,
        };
        let stale_exhausted = AccountUsageView {
            fetched_at: now - time::Duration::minutes(11),
            ..recent_exhausted.clone()
        };
        let usable = AccountUsageView {
            primary_window_kind: None,
            source: UsageSource::SavedAccessToken,
            fetched_at: now - time::Duration::minutes(2),
            five_hour: Some(window(40)),
            weekly: Some(window(80)),
            credits: None,
            banked_resets: None,
            plan_label: Some("Pro".to_owned()),
            subscription_active_until: None,
            luna_reserve: None,
            five_hour_known: false,
            weekly_known: false,
        };

        assert!(exhausted_cached_usage_skips_probe(
            Some(&recent_exhausted),
            now
        ));
        assert!(!exhausted_cached_usage_skips_probe(
            Some(&stale_exhausted),
            now
        ));
        assert!(!exhausted_cached_usage_skips_probe(Some(&usable), now));
        assert!(!exhausted_cached_usage_skips_probe(None, now));
        // Exhausted caches are never "fresh" — backoff is what stops the fan-out.
        assert!(!cached_usage_is_fresh(Some(&recent_exhausted), now));
    }

    #[test]
    fn refresh_stale_saved_usage_skips_exhausted_accounts_within_backoff() {
        let temp = tempdir().expect("tempdir");
        let env = AppEnv {
            kind: EnvironmentKind::Linux,
            home_dir: temp.path().to_path_buf(),
            codex_root: temp.path().join(".codex"),
            app_data_dir: temp.path().join("app"),
        };
        std::fs::create_dir_all(&env.codex_root).expect("codex root");
        let repo = SnapshotRepository::new(&env.app_data_dir, MemorySecretStore::default());
        let now = OffsetDateTime::now_utc();
        let exhausted_usage = |minutes_ago: i64| AccountUsageView {
            primary_window_kind: None,
            source: UsageSource::SavedAccessToken,
            fetched_at: now - time::Duration::minutes(minutes_ago),
            five_hour: Some(UsageWindowView {
                used_percent: 100,
                remaining_percent: 0,
                reset_at: now + time::Duration::hours(5),
            }),
            weekly: Some(UsageWindowView {
                used_percent: 100,
                remaining_percent: 0,
                reset_at: now + time::Duration::hours(5),
            }),
            credits: None,
            banked_resets: None,
            plan_label: Some("Pro".to_owned()),
            subscription_active_until: None,
            luna_reserve: None,
            five_hour_known: false,
            weekly_known: false,
        };
        let save = |email: &str, minutes_ago: i64| {
            let identity = DisplayIdentity {
                email: email.to_owned(),
                subject: Some(format!("sub-{email}")),
                name: None,
                plan_label: Some("Pro".to_owned()),
            };
            let saved = repo
                .save_snapshot(
                    &env.kind,
                    &identity,
                    &SnapshotBlob {
                        schema_version: 1,
                        files: vec![],
                    },
                )
                .expect("save")
                .0;
            repo.replace_snapshot_without_backup(
                &env.kind,
                saved.id,
                &identity,
                &SnapshotBlob {
                    schema_version: 1,
                    files: vec![],
                },
                Some(exhausted_usage(minutes_ago)),
            )
            .expect("seed exhausted usage");
            saved.id
        };
        // 2-minute-old exhausted cache: inside the probe backoff → skipped.
        let recent_id = save("recent@example.com", 2);
        // 11-minute-old exhausted cache: past the backoff → probed, and the
        // probe records a usage error on the empty snapshot.
        let stale_id = save("stale@example.com", 11);

        let app = App::new(env, repo);
        app.refresh_stale_saved_usage()
            .expect("stale sweep must not fail");

        let recent = app
            .repository
            .get_account(&app.env.kind, recent_id)
            .expect("load recent")
            .expect("recent account");
        assert!(
            recent.cached_usage_error.is_none(),
            "recent exhausted account must be skipped, not probed: {:?}",
            recent.cached_usage_error
        );
        let stale = app
            .repository
            .get_account(&app.env.kind, stale_id)
            .expect("load stale")
            .expect("stale account");
        assert!(
            stale.cached_usage_error.is_some(),
            "stale exhausted account is past the backoff and must be probed"
        );
    }

    #[test]
    fn refresh_stale_saved_usage_skips_recent_non_login_usage_errors() {
        let temp = tempdir().expect("tempdir");
        let env = AppEnv {
            kind: EnvironmentKind::Linux,
            home_dir: temp.path().to_path_buf(),
            codex_root: temp.path().join(".codex"),
            app_data_dir: temp.path().join("app"),
        };
        std::fs::create_dir_all(&env.codex_root).expect("codex root");
        let repo = SnapshotRepository::new(&env.app_data_dir, MemorySecretStore::default());
        let payment_error = "Usage unavailable: usage request failed with 402 Payment Required";
        let save = |email: &str| {
            let identity = DisplayIdentity {
                email: email.to_owned(),
                subject: Some(format!("sub-{email}")),
                name: None,
                plan_label: Some("Pro".to_owned()),
            };
            let saved = repo
                .save_snapshot(
                    &env.kind,
                    &identity,
                    &SnapshotBlob {
                        schema_version: 1,
                        files: vec![],
                    },
                )
                .expect("save")
                .0;
            repo.record_usage_error(&env.kind, saved.id, payment_error.to_owned())
                .expect("record error");
            saved.id
        };
        // Error recorded just now: inside the probe backoff → skipped, error
        // string untouched.
        let recent_id = save("recent-402@example.com");
        // Same error but recorded 11 minutes ago: past the backoff → probed,
        // which re-records a snapshot-load error instead of the 402.
        let stale_id = save("stale-402@example.com");
        let index_path = env.app_data_dir.join("metadata.json");
        let mut index: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&index_path).expect("read index"))
                .expect("parse index");
        let old_updated_at =
            serde_json::to_value(OffsetDateTime::now_utc() - time::Duration::minutes(11))
                .expect("serialize updated_at");
        for account in index["accounts"]
            .as_array_mut()
            .expect("accounts array")
            .iter_mut()
        {
            if account["id"].as_str() == Some(stale_id.to_string().as_str()) {
                account["updated_at"] = old_updated_at.clone();
            }
        }
        std::fs::write(
            &index_path,
            serde_json::to_string_pretty(&index).expect("serialize index"),
        )
        .expect("write index");

        let app = App::new(env, repo);
        app.refresh_stale_saved_usage()
            .expect("stale sweep must not fail");

        let recent = app
            .repository
            .get_account(&app.env.kind, recent_id)
            .expect("load recent")
            .expect("recent account");
        assert_eq!(
            recent.cached_usage_error.as_deref(),
            Some(payment_error),
            "recent 402 account must be skipped, not re-probed: {:?}",
            recent.cached_usage_error
        );
        let stale = app
            .repository
            .get_account(&app.env.kind, stale_id)
            .expect("load stale")
            .expect("stale account");
        assert_ne!(
            stale.cached_usage_error.as_deref(),
            Some(payment_error),
            "stale 402 account is past the backoff and must be re-probed"
        );
        assert!(
            stale.cached_usage_error.is_some(),
            "re-probe records a new error on the empty snapshot"
        );
    }

    #[test]
    fn apply_auto_switch_skips_live_probe_when_decide_cache_is_recent() {
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
            auth_json_fixture("apply-live@example.com", "sub-apply", Some("pro")),
        )
        .expect("auth");
        let repo = SnapshotRepository::new(&env.app_data_dir, MemorySecretStore::default());
        let app = App::new(env.clone(), repo);
        let live_id = app.save_current().expect("initial save").account.id;
        crate::settings::save_settings(
            &env.app_data_dir,
            &crate::settings::AppSettings {
                auto_switch_when_exhausted: true,
                ..crate::settings::AppSettings::default()
            },
        )
        .expect("enable auto-switch");

        let identity = DisplayIdentity {
            email: "apply-live@example.com".to_owned(),
            subject: Some("sub-apply".to_owned()),
            name: None,
            plan_label: Some("Pro".to_owned()),
        };
        let exhausted_usage = |fetched_at: OffsetDateTime| AccountUsageView {
            primary_window_kind: None,
            source: UsageSource::LiveAccessToken,
            fetched_at,
            five_hour: Some(UsageWindowView {
                used_percent: 100,
                remaining_percent: 0,
                reset_at: OffsetDateTime::now_utc() + time::Duration::hours(5),
            }),
            weekly: Some(UsageWindowView {
                used_percent: 100,
                remaining_percent: 0,
                reset_at: OffsetDateTime::now_utc() + time::Duration::hours(5),
            }),
            credits: None,
            banked_resets: None,
            plan_label: Some("Pro".to_owned()),
            subscription_active_until: None,
            luna_reserve: None,
            five_hour_known: false,
            weekly_known: false,
        };
        let seed_usage = |fetched_at: OffsetDateTime| {
            app.repository
                .replace_snapshot_without_backup(
                    &app.env.kind,
                    live_id,
                    &identity,
                    &SnapshotBlob {
                        schema_version: 1,
                        files: vec![],
                    },
                    Some(exhausted_usage(fetched_at)),
                )
                .expect("seed usage");
            app.repository
                .get_account(&app.env.kind, live_id)
                .expect("load")
                .expect("account")
        };

        // Fresh decide cache (seconds old): apply must not re-probe — a probe
        // would hit the network offline and record a usage error.
        seed_usage(OffsetDateTime::now_utc());
        let output = app.auto_switch(true).expect("apply");
        assert_eq!(output.status, "all_accounts_exhausted");
        assert!(
            seed_usage(OffsetDateTime::now_utc())
                .cached_usage_error
                .is_none(),
            "recent live cache must skip the second usage(None) probe"
        );

        // Cache older than the window: apply re-probes, which fails offline
        // and records a usage error on the live account.
        seed_usage(OffsetDateTime::now_utc() - time::Duration::seconds(30));
        let _ = app.auto_switch(true).expect("apply");
        assert!(
            app.repository
                .get_account(&app.env.kind, live_id)
                .expect("load")
                .expect("account")
                .cached_usage_error
                .is_some(),
            "stale live cache must re-probe the live account"
        );
    }

    /// A two-account temp roster for exercising the real apply path: the live
    /// account is exhausted and the saved candidate has a fresh usable paid
    /// cache, so no network or Keychain access is needed.
    struct AutoSwitchSwap {
        _temp: tempfile::TempDir,
        app: App<MemorySecretStore>,
        active_id: Uuid,
        candidate_id: Uuid,
    }

    fn write_live_auth(env: &AppEnv, email: &str, subject: &str, plan: &str, sid: &str) {
        std::fs::write(
            env.codex_root.join("auth.json"),
            auth_json_fixture(email, subject, Some(plan)),
        )
        .expect("write live auth");
        std::fs::write(env.codex_root.join("cap_sid"), sid).expect("write cap_sid");
    }

    fn seed_cached_usage(app: &App<MemorySecretStore>, account_id: Uuid, usage: AccountUsageView) {
        let (metadata, snapshot) = app
            .repository
            .load_snapshot(&app.env.kind, account_id)
            .expect("load snapshot");
        app.repository
            .replace_snapshot_without_backup(
                &app.env.kind,
                account_id,
                &saved_identity(&metadata),
                &snapshot,
                Some(usage),
            )
            .expect("seed cached usage");
    }

    /// The exhausted live account: both windows depleted but still current, so
    /// `is_exhausted_for_switch` holds and the recent cache skips the live probe.
    fn exhausted_switch_usage() -> AccountUsageView {
        usage_with(Some(window_view(0, 5)), Some(window_view(0, 48)), None, 0)
    }

    /// The replacement account: fresh, current, paid, and not exhausted.
    fn usable_switch_usage() -> AccountUsageView {
        usage_with(Some(window_view(80, 5)), Some(window_view(90, 48)), None, 0)
    }

    fn save_live_account(app: &App<MemorySecretStore>) -> Uuid {
        let live = crate::codex::read_live_auth_bundle(&app.env).expect("live auth bundle");
        app.repository
            .save_snapshot_without_backup(&app.env.kind, &live.identity, &live.snapshot)
            .expect("save live account")
            .0
            .id
    }

    fn auto_switch_swap_fixture() -> AutoSwitchSwap {
        let temp = tempdir().expect("tempdir");
        let env = AppEnv {
            kind: EnvironmentKind::Linux,
            home_dir: temp.path().to_path_buf(),
            codex_root: temp.path().join(".codex"),
            app_data_dir: temp.path().join("app"),
        };
        std::fs::create_dir_all(&env.codex_root).expect("codex root");
        let app = App::new(
            env.clone(),
            SnapshotRepository::new(&env.app_data_dir, MemorySecretStore::default()),
        );
        // Save both accounts from real (temp) live auth bundles, then make the
        // exhausted one live again so the switch has somewhere to move away from.
        // The snapshot is written without the unrelated first full-backup pass.
        write_live_auth(
            &env,
            "active@example.com",
            "sub-active",
            "pro",
            "sid-active",
        );
        let active_id = save_live_account(&app);
        write_live_auth(
            &env,
            "candidate@example.com",
            "sub-candidate",
            "plus",
            "sid-candidate",
        );
        let candidate_id = save_live_account(&app);
        write_live_auth(
            &env,
            "active@example.com",
            "sub-active",
            "pro",
            "sid-active",
        );
        seed_cached_usage(&app, active_id, exhausted_switch_usage());
        seed_cached_usage(&app, candidate_id, usable_switch_usage());
        crate::settings::save_settings(
            &env.app_data_dir,
            &crate::settings::AppSettings {
                auto_switch_when_exhausted: true,
                ..crate::settings::AppSettings::default()
            },
        )
        .expect("enable auto-switch");
        AutoSwitchSwap {
            _temp: temp,
            app,
            active_id,
            candidate_id,
        }
    }

    /// End-to-end apply: a real `auto_switch_with_candidate(true, ...)` swaps the
    /// temp `~/.codex` auth, records the durable switch transaction before the
    /// mutation, advances it, removes it, and reports the pick score.
    #[test]
    fn auto_switch_apply_completes_the_durable_switch_saga_end_to_end() {
        use crate::switch_txn::{SwitchPhase, path as txn_path};

        // ---- Case 1: a successful swap, with the transaction observed mid-flight.
        let AutoSwitchSwap {
            _temp,
            app,
            active_id,
            candidate_id,
        } = auto_switch_swap_fixture();
        let app_data_dir = app.env.app_data_dir.clone();
        assert!(
            !txn_path(&app_data_dir).exists(),
            "no transaction may exist before a switch starts"
        );

        // Hold AuthLock so the switch thread parks right after the `Captured`
        // phase (which is written before `activate` mutates auth). That makes the
        // durable intermediate state observable without changing production code.
        let auth_lock = AuthLock::acquire(&app_data_dir).expect("hold auth lock");
        let output = std::thread::scope(|scope| {
            let switching =
                scope.spawn(|| app.auto_switch_with_candidate(true, Some(candidate_id), true));
            let deadline = Instant::now() + Duration::from_secs(2);
            loop {
                if let Ok(Some(txn)) = crate::switch_txn::load(&app_data_dir)
                    && txn.phase == SwitchPhase::Captured
                {
                    assert_eq!(
                        txn.from_account, active_id,
                        "transaction records the source"
                    );
                    assert_eq!(
                        txn.to_account, candidate_id,
                        "transaction records the target"
                    );
                    break;
                }
                assert!(
                    Instant::now() < deadline,
                    "the durable switch transaction never reached the captured phase"
                );
                std::thread::sleep(Duration::from_millis(5));
            }
            drop(auth_lock);
            switching.join().expect("switch thread")
        })
        .expect("apply auto-switch");

        assert_eq!(output.status, "switched");
        assert_eq!(output.active_account_id, Some(active_id));
        assert_eq!(output.candidate_account_id, Some(candidate_id));
        assert!(
            output.warnings.is_empty(),
            "a clean switch must not warn: {:?}",
            output.warnings
        );
        let score = output
            .candidate_switch_score
            .expect("the pick must be explained by a score");
        assert!(
            score.quota_component > 0 && score.score > 0,
            "unexpected score: {score:?}"
        );
        assert!(
            score.reason.contains("quota"),
            "the score must explain the pick: {score:?}"
        );

        // The auth mutation really landed on the candidate...
        let live = crate::codex::read_live_auth_bundle(&app.env).expect("live bundle");
        assert_eq!(live.identity.email, "candidate@example.com");
        assert_eq!(live.identity.subject.as_deref(), Some("sub-candidate"));

        // ...the durable transaction was removed before returning...
        assert!(
            !txn_path(&app_data_dir).exists(),
            "a finished switch must not leave switch-txn.json behind"
        );
        assert!(
            crate::switch_txn::load(&app_data_dir)
                .expect("load switch transaction")
                .is_none(),
            "the finished transaction must be cleared"
        );

        // ...and the post-`verified` cooldown bookkeeping ran.
        let settings = crate::settings::load_settings(&app_data_dir).expect("settings");
        assert_eq!(settings.last_auto_switch_target, Some(candidate_id));
        assert_eq!(settings.last_auto_switch_from, Some(active_id));
        assert!(settings.last_auto_switch_at.is_some());

        // ---- Case 2: a failing resume-hint read warns but keeps the switch.
        let AutoSwitchSwap {
            _temp: _temp2,
            app: app2,
            active_id: active2,
            candidate_id: candidate2,
        } = auto_switch_swap_fixture();
        let app_data_dir2 = app2.env.app_data_dir.clone();
        // A directory where the resume index should be makes only the post-swap
        // hint read fail; the credential swap must still be reported as applied.
        let resume_index = app_data_dir2.join("session-resume.json");
        let _ = std::fs::remove_file(&resume_index);
        std::fs::create_dir(&resume_index).expect("break the resume index");
        let output2 = app2
            .auto_switch_with_candidate(true, Some(candidate2), true)
            .expect("apply must survive a resume-hint read failure");
        assert_eq!(output2.status, "switched");
        assert_eq!(output2.active_account_id, Some(active2));
        assert_eq!(output2.candidate_account_id, Some(candidate2));
        assert!(
            output2
                .warnings
                .iter()
                .any(|warning| warning.contains("resume hint")),
            "the failed hint read must surface as a warning: {:?}",
            output2.warnings
        );
        assert!(!txn_path(&app_data_dir2).exists());
        assert_eq!(
            crate::codex::read_live_auth_bundle(&app2.env)
                .expect("live bundle")
                .identity
                .email,
            "candidate@example.com"
        );

        // ---- Case 3: a failed swap leaves no transaction and no cooldown.
        let AutoSwitchSwap {
            _temp: _temp3,
            app: app3,
            active_id: _active3,
            candidate_id: candidate3,
        } = auto_switch_swap_fixture();
        let app_data_dir3 = app3.env.app_data_dir.clone();
        // Break activation after the saga has begun: the saved metadata subject no
        // longer matches the snapshot identity, so the restore is refused.
        let (metadata3, snapshot3) = app3
            .repository
            .load_snapshot(&app3.env.kind, candidate3)
            .expect("load candidate snapshot");
        app3.repository
            .replace_snapshot_without_backup(
                &app3.env.kind,
                candidate3,
                &DisplayIdentity {
                    subject: Some("sub-mismatch".to_owned()),
                    ..saved_identity(&metadata3)
                },
                &snapshot3,
                Some(usable_switch_usage()),
            )
            .expect("mismatch the candidate metadata");
        let error = app3
            .auto_switch_with_candidate(true, Some(candidate3), true)
            .expect_err("a mismatched snapshot must fail the swap");
        assert!(
            format!("{error:#}").contains("does not match the selected account"),
            "unexpected error: {error:#}"
        );
        assert!(
            !txn_path(&app_data_dir3).exists(),
            "the failure path must remove switch-txn.json"
        );
        assert!(
            crate::switch_txn::load(&app_data_dir3)
                .expect("load switch transaction")
                .is_none()
        );
        assert_eq!(
            crate::codex::read_live_auth_bundle(&app3.env)
                .expect("live bundle")
                .identity
                .email,
            "active@example.com",
            "a failed swap must leave the previous account live"
        );
        assert_eq!(
            crate::settings::load_settings(&app_data_dir3)
                .expect("settings")
                .last_auto_switch_target,
            None,
            "a failed swap must not record a cooldown"
        );
    }

    #[test]
    fn deferred_fresh_usable_cache_is_auto_switch_candidate_without_network() {
        let now = OffsetDateTime::now_utc();
        let settings = crate::settings::AppSettings::default();
        let window = |remaining: u8| UsageWindowView {
            used_percent: 100u8.saturating_sub(remaining),
            remaining_percent: remaining,
            reset_at: now + time::Duration::hours(5),
        };
        let usable = AccountUsageView {
            primary_window_kind: None,
            source: UsageSource::SavedAccessToken,
            fetched_at: now,
            five_hour: Some(window(40)),
            weekly: Some(window(80)),
            credits: None,
            banked_resets: None,
            plan_label: Some("Pro".to_owned()),
            subscription_active_until: None,
            luna_reserve: None,
            five_hour_known: false,
            weekly_known: false,
        };
        let deferred = AccountView {
            id: Uuid::new_v4(),
            provider: crate::model::AiProvider::OpenAi,
            email: "deferred@example.com".to_owned(),
            subject: Some("subject-deferred".to_owned()),
            name: None,
            custom_label: None,
            plan_label: Some("Pro".to_owned()),
            environment: EnvironmentKind::Linux,
            is_active: false,
            created_at: now,
            updated_at: now,
            last_activated_at: None,
            archived: false,
            usage: Some(usable.clone()),
            usage_error: Some(deferred_access_token_unauthorized_message()),
        };
        let mut active = deferred.clone();
        active.id = Uuid::new_v4();
        active.email = "active@example.com".to_owned();
        active.subject = Some("subject-active".to_owned());
        active.is_active = true;
        active.usage_error = None;
        active.usage = Some(AccountUsageView {
            primary_window_kind: None,
            source: UsageSource::SavedAccessToken,
            fetched_at: now,
            five_hour: Some(window(0)),
            weekly: Some(window(0)),
            credits: None,
            banked_resets: None,
            plan_label: Some("Pro".to_owned()),
            subscription_active_until: None,
            luna_reserve: None,
            five_hour_known: false,
            weekly_known: false,
        });

        assert!(usage_error_is_deferred_access_token_refresh(
            deferred.usage_error.as_deref().expect("deferred")
        ));
        assert!(!usage_error_blocks_activation(
            deferred.usage_error.as_deref().expect("deferred")
        ));
        assert!(deferred_fresh_usable_auto_switch_candidate(
            &deferred, &active, &settings, now
        ));
        assert!(is_eligible_auto_switch_candidate(
            &deferred, &active, &settings, now, None
        ));

        // Login-required must never qualify via the deferred soft path.
        let mut login_required = deferred.clone();
        login_required.usage_error = Some(
            "Login required [refresh_token_rejected]: OpenAI rejected the saved refresh token."
                .to_owned(),
        );
        assert!(!deferred_fresh_usable_auto_switch_candidate(
            &login_required,
            &active,
            &settings,
            now
        ));
    }

    #[test]
    fn fresh_usable_paid_cache_skips_duplicate_revalidate_probe() {
        let now = OffsetDateTime::now_utc();
        let settings = crate::settings::AppSettings::default();
        let window = |remaining: u8| UsageWindowView {
            used_percent: 100u8.saturating_sub(remaining),
            remaining_percent: remaining,
            reset_at: now + time::Duration::hours(5),
        };
        let usable = AccountUsageView {
            primary_window_kind: None,
            source: UsageSource::SavedAccessToken,
            fetched_at: now,
            five_hour: Some(window(40)),
            weekly: Some(window(80)),
            credits: None,
            banked_resets: None,
            plan_label: Some("Pro".to_owned()),
            subscription_active_until: None,
            luna_reserve: None,
            five_hour_known: false,
            weekly_known: false,
        };
        let candidate = AccountView {
            id: Uuid::new_v4(),
            provider: crate::model::AiProvider::OpenAi,
            email: "ready@example.com".to_owned(),
            subject: Some("subject-ready".to_owned()),
            name: None,
            custom_label: None,
            plan_label: Some("Pro".to_owned()),
            environment: EnvironmentKind::Linux,
            is_active: false,
            created_at: now,
            updated_at: now,
            last_activated_at: None,
            archived: false,
            usage: Some(usable.clone()),
            usage_error: None,
        };
        let mut active = candidate.clone();
        active.id = Uuid::new_v4();
        active.email = "active@example.com".to_owned();
        active.subject = Some("subject-active".to_owned());
        active.is_active = true;
        active.usage = Some(AccountUsageView {
            primary_window_kind: None,
            source: UsageSource::SavedAccessToken,
            fetched_at: now,
            five_hour: Some(window(0)),
            weekly: Some(window(0)),
            credits: None,
            banked_resets: None,
            plan_label: Some("Pro".to_owned()),
            subscription_active_until: None,
            luna_reserve: None,
            five_hour_known: false,
            weekly_known: false,
        });

        assert!(fresh_usable_paid_cached_auto_switch_candidate(
            &candidate, &active, &settings, now
        ));

        // Free must never skip via fresh-cache short-circuit.
        let mut free = candidate.clone();
        free.plan_label = Some("Free".to_owned());
        free.usage = Some(AccountUsageView {
            primary_window_kind: None,
            source: UsageSource::SavedAccessToken,
            fetched_at: now,
            five_hour: Some(window(40)),
            weekly: Some(window(80)),
            credits: None,
            banked_resets: None,
            plan_label: Some("Free".to_owned()),
            subscription_active_until: None,
            luna_reserve: None,
            five_hour_known: false,
            weekly_known: false,
        });
        assert!(!fresh_usable_paid_cached_auto_switch_candidate(
            &free, &active, &settings, now
        ));

        // Stale cache must fall through to a live AT probe.
        let mut stale = candidate.clone();
        stale.usage = Some(AccountUsageView {
            primary_window_kind: None,
            source: UsageSource::SavedAccessToken,
            fetched_at: now - time::Duration::minutes(20),
            five_hour: Some(window(40)),
            weekly: Some(window(80)),
            credits: None,
            banked_resets: None,
            plan_label: Some("Pro".to_owned()),
            subscription_active_until: None,
            luna_reserve: None,
            five_hour_known: false,
            weekly_known: false,
        });
        assert!(!fresh_usable_paid_cached_auto_switch_candidate(
            &stale, &active, &settings, now
        ));
    }

    #[test]
    fn auto_switch_mixed_roster_only_usable_candidate_can_be_ready() {
        let now = OffsetDateTime::now_utc();
        let settings = crate::settings::AppSettings::default();
        let window = |remaining: u8| UsageWindowView {
            used_percent: 100u8.saturating_sub(remaining),
            remaining_percent: remaining,
            reset_at: now + time::Duration::hours(5),
        };
        let account = |email: &str, plan: &str, remaining: u8, active: bool| AccountView {
            id: Uuid::new_v4(),
            provider: crate::model::AiProvider::OpenAi,
            email: email.to_owned(),
            subject: Some(format!("subject-{email}")),
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
                primary_window_kind: None,
                source: UsageSource::SavedAccessToken,
                fetched_at: now,
                five_hour: Some(window(remaining)),
                weekly: Some(window(remaining)),
                credits: None,
                banked_resets: None,
                plan_label: Some(plan.to_owned()),
                subscription_active_until: None,
                luna_reserve: None,
                five_hour_known: false,
                weekly_known: false,
            }),
            usage_error: None,
        };
        let active = account("active@example.com", "Plus", 0, true);
        let exhausted = account("exhausted@example.com", "Pro", 0, false);
        let usable = account("usable@example.com", "Pro", 40, false);
        let roster = [active.clone(), exhausted.clone(), usable.clone()];

        assert!(!fresh_usage_passes_auto_switch_gate(
            exhausted.usage.as_ref().expect("usage"),
            now
        ));
        assert!(fresh_usage_passes_auto_switch_gate(
            usable.usage.as_ref().expect("usage"),
            now
        ));
        assert!(!is_eligible_auto_switch_candidate(
            &exhausted, &active, &settings, now, None
        ));
        assert!(is_eligible_auto_switch_candidate(
            &usable, &active, &settings, now, None
        ));

        let ranked = ranked_cached_auto_switch_candidates(&roster, &active, &settings, now, None);
        assert_eq!(ranked.len(), 1);
        assert_eq!(ranked[0].id, usable.id);

        // decide's ready path: only a fresh-gated usable id may become the candidate.
        let ready_candidate = ranked.into_iter().find(|candidate| {
            fresh_usage_passes_auto_switch_gate(candidate.usage.as_ref().expect("usage"), now)
                && is_eligible_auto_switch_candidate(candidate, &active, &settings, now, None)
        });
        assert_eq!(
            ready_candidate.as_ref().map(|c| c.id),
            Some(usable.id),
            "mixed roster must only surface the usable account as ready"
        );
        assert_ne!(ready_candidate.as_ref().map(|c| c.id), Some(exhausted.id));
    }

    #[test]
    fn auto_switch_all_exhausted_has_no_usable_candidate_for_decide_or_apply() {
        // Contract for decide/apply: when every paid sibling is at 0% (banked
        // resets do not count), ranking is empty → status is
        // all_accounts_exhausted and apply must not activate anyone.
        let now = OffsetDateTime::now_utc();
        let settings = crate::settings::AppSettings::default();
        let window = |remaining: u8| UsageWindowView {
            used_percent: 100u8.saturating_sub(remaining),
            remaining_percent: remaining,
            reset_at: now + time::Duration::hours(5),
        };
        let account =
            |email: &str, plan: &str, remaining: u8, banked: i64, active: bool| AccountView {
                id: Uuid::new_v4(),
                provider: crate::model::AiProvider::OpenAi,
                email: email.to_owned(),
                subject: Some(format!("subject-{email}")),
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
                    primary_window_kind: None,
                    source: UsageSource::SavedAccessToken,
                    fetched_at: now,
                    five_hour: Some(window(remaining)),
                    weekly: Some(window(remaining)),
                    credits: None,
                    banked_resets: (banked > 0).then_some(crate::model::BankedResetSummaryView {
                        available_count: banked,
                        credits: None,
                    }),
                    plan_label: Some(plan.to_owned()),
                    subscription_active_until: None,
                    luna_reserve: None,
                    five_hour_known: false,
                    weekly_known: false,
                }),
                usage_error: None,
            };
        let active = account("active@example.com", "Plus", 0, 0, true);
        let exhausted = account("exhausted@example.com", "Pro", 0, 0, false);
        let banked_only = account("banked@example.com", "Pro", 0, 2, false);
        let roster = [active.clone(), exhausted.clone(), banked_only.clone()];

        assert!(is_exhausted_for_switch(active.usage.as_ref(), now));
        assert!(!is_usable_for_switch(exhausted.usage.as_ref(), now));
        assert!(!is_usable_for_switch(banked_only.usage.as_ref(), now));
        assert!(!fresh_usage_passes_auto_switch_gate(
            exhausted.usage.as_ref().expect("usage"),
            now
        ));
        assert!(!is_eligible_auto_switch_candidate(
            &exhausted, &active, &settings, now, None
        ));
        assert!(!is_eligible_auto_switch_candidate(
            &banked_only,
            &active,
            &settings,
            now,
            None
        ));

        let ranked = ranked_cached_auto_switch_candidates(&roster, &active, &settings, now, None);
        assert!(
            ranked.is_empty(),
            "all-exhausted roster must not surface a switch candidate"
        );
        assert!(
            best_cached_auto_switch_candidate(&roster, &active, &settings, now, None).is_none()
        );

        // Mirrors apply_auto_switch's empty-candidate / final-belt branch: no activation.
        let apply_status = if ranked.is_empty()
            || ranked.iter().any(|c| {
                !is_usable_for_switch(c.usage.as_ref(), now)
                    || is_exhausted_for_switch(c.usage.as_ref(), now)
            }) {
            "all_accounts_exhausted"
        } else {
            "ready"
        };
        assert_eq!(apply_status, "all_accounts_exhausted");
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

        let again = app.import_accounts_from_json(&auth_path, None);
        let err = again.expect_err("duplicate import must refuse");
        assert!(
            err.to_string().contains("Account already in roster")
                || err.to_string().contains("Tài khoản đã có trong danh bạ"),
            "unexpected error: {err}"
        );
        assert_eq!(app.list().expect("list").accounts.len(), 1);
    }

    #[test]
    fn cached_exhausted_usage_is_stale_once_the_window_resets() {
        let now = OffsetDateTime::now_utc();
        let usage = AccountUsageView {
            primary_window_kind: None,
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
            luna_reserve: None,
            five_hour_known: false,
            weekly_known: false,
        };

        assert!(!cached_usage_is_fresh(Some(&usage), now));
    }

    #[test]
    fn cached_exhausted_usage_is_stale_even_before_the_scheduled_reset() {
        // Guards against ChatGPT mass resets that lift a limit off-schedule: an
        // exhausted window must be refetched, not trusted until its old reset_at.
        let now = OffsetDateTime::now_utc();
        let usage = AccountUsageView {
            primary_window_kind: None,
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
            luna_reserve: None,
            five_hour_known: false,
            weekly_known: false,
        };

        assert!(!cached_usage_is_fresh(Some(&usage), now));
    }

    #[test]
    fn cached_usage_with_quota_stays_fresh_within_window() {
        let now = OffsetDateTime::now_utc();
        let usage = AccountUsageView {
            primary_window_kind: None,
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
            luna_reserve: None,
            five_hour_known: false,
            weekly_known: false,
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
                primary_window_kind: None,
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
                luna_reserve: None,
                five_hour_known: false,
                weekly_known: false,
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
                primary_window_kind: None,
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
                luna_reserve: None,
                five_hour_known: false,
                weekly_known: false,
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
    // Defense-in-depth for the macOS force-switch path: Desktop must save/flush
    // first, but activate itself always re-saves the live session under AuthLock
    // before restoring the target snapshot (see AccountActivationSafety.forceSwitchOrderedSteps).
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
