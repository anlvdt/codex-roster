use std::time::Duration as StdDuration;

use anyhow::{Result, bail};
use time::OffsetDateTime;
use uuid::Uuid;

use crate::model::{
    AiProvider, ClaudeAutoSwitchStrategy, ProviderAutoSwitchOutput, ProviderUsageStatus,
    ProviderUsageView,
};
use crate::operation_lock::{AuthLock, AutoSwitchLock, OperationLock};
use crate::provider::{SnapshotRefresh, adapter};
use crate::provider_store::LOGIN_REQUIRED_ERROR_PREFIX;
use crate::settings::{AppSettings, load_settings, save_settings};

use super::App;
use crate::secrets::SecretStore;

const USAGE_FRESHNESS: time::Duration = time::Duration::minutes(2);
const FRESHEN_WITHIN: StdDuration = StdDuration::from_secs(600);

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Trigger {
    AtLimit,
    Proactive,
    ConsumeFirst,
}

impl Trigger {
    fn label(self) -> &'static str {
        match self {
            Trigger::AtLimit => "at_limit",
            Trigger::Proactive => "proactive",
            Trigger::ConsumeFirst => "consume_first",
        }
    }
}

#[derive(Clone, Debug)]
pub(crate) struct CandidateRow {
    pub id: Uuid,
    pub display_name: String,
    pub headroom: u8,
    pub utilization: u8,
    pub seven_day_reset_at: Option<OffsetDateTime>,
}

#[derive(Debug)]
enum Decision {
    BelowThreshold,
    Cooldown {
        trigger: Trigger,
    },
    NoCandidate {
        trigger: Trigger,
    },
    Switch {
        trigger: Trigger,
        candidate: CandidateRow,
    },
}

fn claude_binding_utilization(usage: &ProviderUsageView) -> Option<u8> {
    if usage.status != ProviderUsageStatus::Ok
        || !crate::provider::claude::usage_covers_required_limits(usage, None)
    {
        return None;
    }
    usage
        .windows
        .iter()
        .filter(|window| {
            matches!(window.key.as_str(), "five_hour" | "seven_day")
                || window.key.starts_with("seven_day_")
        })
        .filter_map(|window| window.used_percent)
        .max()
}

#[cfg(test)]
fn claude_headroom(usage: &ProviderUsageView) -> Option<u8> {
    claude_binding_utilization(usage).map(|utilization| 100u8.saturating_sub(utilization))
}

fn seven_day_reset_at(usage: &ProviderUsageView) -> Option<OffsetDateTime> {
    usage
        .windows
        .iter()
        .find(|window| window.key == "seven_day")
        .and_then(|window| window.reset_at)
}

fn usage_is_fresh(usage: &ProviderUsageView, now: OffsetDateTime) -> bool {
    (now - usage.fetched_at) <= USAGE_FRESHNESS
        && usage.fetched_at <= now + time::Duration::minutes(1)
        && !usage.windows.iter().any(|window| {
            window
                .reset_at
                .is_some_and(|reset| usage.fetched_at < reset && reset <= now)
        })
}

fn decide(
    active_utilization: u8,
    active_reset: Option<OffsetDateTime>,
    candidates: &[CandidateRow],
    settings: &AppSettings,
    now: OffsetDateTime,
) -> Decision {
    let threshold = settings.claude_auto_switch_threshold_percent;
    let hysteresis = settings.claude_auto_switch_hysteresis_percent;
    let cooldown = time::Duration::seconds(settings.claude_auto_switch_cooldown_seconds as i64);
    let trigger = if active_utilization >= 99 {
        Trigger::AtLimit
    } else if active_utilization >= threshold {
        Trigger::Proactive
    } else if settings.claude_auto_switch_strategy == ClaudeAutoSwitchStrategy::ConsumeFirst {
        Trigger::ConsumeFirst
    } else {
        return Decision::BelowThreshold;
    };
    let in_cooldown = settings
        .claude_last_auto_switch_at
        .is_some_and(|last| now - last < cooldown);
    if trigger != Trigger::AtLimit && in_cooldown {
        return Decision::Cooldown { trigger };
    }
    let active_headroom = 100u8.saturating_sub(active_utilization);
    let mut eligible: Vec<&CandidateRow> = candidates
        .iter()
        .filter(|candidate| {
            if candidate.utilization >= threshold {
                return false;
            }
            if trigger != Trigger::AtLimit
                && in_cooldown
                && settings.claude_last_auto_switch_from == Some(candidate.id)
            {
                return false;
            }
            match trigger {
                Trigger::AtLimit => true,
                Trigger::Proactive => {
                    candidate.headroom >= active_headroom.saturating_add(hysteresis)
                }
                Trigger::ConsumeFirst => {
                    candidate.utilization <= threshold.saturating_sub(hysteresis)
                        && matches!(
                            (candidate.seven_day_reset_at, active_reset),
                            (Some(candidate_reset), Some(active_reset))
                                if candidate_reset < active_reset
                        )
                }
            }
        })
        .collect();
    match trigger {
        Trigger::ConsumeFirst => eligible.sort_by_key(|candidate| {
            (
                candidate
                    .seven_day_reset_at
                    .map_or(i64::MAX, |reset| reset.unix_timestamp()),
                std::cmp::Reverse(candidate.headroom),
            )
        }),
        _ => eligible.sort_by_key(|candidate| {
            (
                std::cmp::Reverse(candidate.headroom),
                candidate
                    .seven_day_reset_at
                    .map_or(i64::MAX, |reset| reset.unix_timestamp()),
            )
        }),
    }
    match eligible.into_iter().next() {
        Some(candidate) => Decision::Switch {
            trigger,
            candidate: candidate.clone(),
        },
        None => Decision::NoCandidate { trigger },
    }
}

impl<S> App<S>
where
    S: SecretStore,
{
    fn claude_auto_switch_output(
        &self,
        settings: &AppSettings,
        status: &str,
        trigger: Option<Trigger>,
        active_account_id: Option<Uuid>,
        candidate: Option<&CandidateRow>,
        detail: Option<String>,
    ) -> ProviderAutoSwitchOutput {
        ProviderAutoSwitchOutput {
            provider: AiProvider::Claude,
            enabled: settings.claude_auto_switch,
            status: status.to_owned(),
            trigger: trigger.map(Trigger::label).map(str::to_owned),
            active_account_id,
            candidate_account_id: candidate.map(|candidate| candidate.id),
            candidate_display_name: candidate.map(|candidate| candidate.display_name.clone()),
            detail,
            threshold_percent: settings.claude_auto_switch_threshold_percent,
            hysteresis_percent: settings.claude_auto_switch_hysteresis_percent,
            cooldown_seconds: settings.claude_auto_switch_cooldown_seconds,
            strategy: settings.claude_auto_switch_strategy,
        }
    }

    pub fn claude_auto_switch_decide(&self) -> Result<ProviderAutoSwitchOutput> {
        let settings = load_settings(&self.env.app_data_dir)?;
        if !settings.claude_auto_switch {
            return Ok(
                self.claude_auto_switch_output(&settings, "disabled", None, None, None, None)
            );
        }
        let provider_adapter = adapter(AiProvider::Claude);
        let store = self.provider_store();
        let live_identity = provider_adapter
            .try_read_live_identity_noninteractive(&self.env)
            .ok()
            .flatten();
        let Some(live_identity) = live_identity else {
            return Ok(self.claude_auto_switch_output(
                &settings,
                "waiting_for_login",
                None,
                None,
                None,
                Some("no live Claude Code session".to_owned()),
            ));
        };
        let Some(active) =
            store.find_matching(&self.env.kind, AiProvider::Claude, &live_identity)?
        else {
            return Ok(self.claude_auto_switch_output(
                &settings,
                "waiting_for_login",
                None,
                None,
                None,
                Some("live Claude account is not saved".to_owned()),
            ));
        };
        // The active snapshot can be older than Claude Code's live, rotated token.
        let live_usage = match self.provider_usage(AiProvider::Claude, None) {
            Ok(output) => output,
            Err(error) => {
                return Ok(self.claude_auto_switch_output(
                    &settings,
                    "usage_unavailable",
                    None,
                    Some(active.id),
                    None,
                    Some(format!("Claude usage request failed: {error}")),
                ));
            }
        };
        if !active.identity.matches(&live_usage.account) {
            return Ok(self.claude_auto_switch_output(
                &settings,
                "waiting_for_login",
                None,
                None,
                None,
                Some("live Claude identity changed while checking usage".to_owned()),
            ));
        }
        let active_usage = live_usage.usage;
        if active_usage.status == ProviderUsageStatus::Ok {
            let _operation_lock = OperationLock::acquire(&self.env.app_data_dir)?;
            store.record_usage(&self.env.kind, active.id, active_usage.clone())?;
        }
        let Some(active_utilization) = claude_binding_utilization(&active_usage) else {
            return Ok(self.claude_auto_switch_output(
                &settings,
                "usage_unavailable",
                None,
                Some(active.id),
                None,
                active_usage
                    .detail
                    .clone()
                    .or_else(|| Some("Claude quota is unavailable; retry later".to_owned())),
            ));
        };
        let active_reset = seven_day_reset_at(&active_usage);
        let (_active_record, active_snapshot) = store.load_snapshot(&self.env.kind, active.id)?;
        let now = OffsetDateTime::now_utc();
        let mut candidates = Vec::new();
        for record in store.list(&self.env.kind, Some(AiProvider::Claude))? {
            if record.id == active.id || record.requires_login() {
                continue;
            }
            let Ok((_candidate_record, snapshot)) = store.load_snapshot(&self.env.kind, record.id)
            else {
                continue;
            };
            if record.activation_block_reason(Some(&snapshot)).is_some()
                || provider_adapter.snapshots_share_credential(&snapshot, &active_snapshot)
            {
                continue;
            }
            let usage = match record.cached_usage.as_ref() {
                Some(cached)
                    if record.cached_usage_error.is_none() && usage_is_fresh(cached, now) =>
                {
                    cached.clone()
                }
                _ => match self.provider_usage(AiProvider::Claude, Some(record.id)) {
                    Ok(output) => output.usage,
                    Err(_) => continue,
                },
            };
            let Some(utilization) = claude_binding_utilization(&usage) else {
                continue;
            };
            candidates.push(CandidateRow {
                id: record.id,
                display_name: record.identity.email.clone(),
                headroom: 100u8.saturating_sub(utilization),
                utilization,
                seven_day_reset_at: seven_day_reset_at(&usage),
            });
        }
        let decision = decide(
            active_utilization,
            active_reset,
            &candidates,
            &settings,
            now,
        );
        let output = match decision {
            Decision::BelowThreshold => self.claude_auto_switch_output(
                &settings,
                "below_threshold",
                None,
                Some(active.id),
                None,
                None,
            ),
            Decision::Cooldown { trigger } => self.claude_auto_switch_output(
                &settings,
                "cooldown",
                Some(trigger),
                Some(active.id),
                None,
                None,
            ),
            Decision::NoCandidate { trigger } => {
                let status = if !candidates.is_empty()
                    && candidates
                        .iter()
                        .all(|candidate| candidate.utilization >= 99)
                {
                    "all_accounts_exhausted"
                } else {
                    "no_candidate"
                };
                self.claude_auto_switch_output(
                    &settings,
                    status,
                    Some(trigger),
                    Some(active.id),
                    None,
                    None,
                )
            }
            Decision::Switch { trigger, candidate } => self.claude_auto_switch_output(
                &settings,
                "ready",
                Some(trigger),
                Some(active.id),
                Some(&candidate),
                None,
            ),
        };
        Ok(output)
    }

    pub fn claude_auto_switch_apply(
        &self,
        preferred: Option<Uuid>,
    ) -> Result<ProviderAutoSwitchOutput> {
        let _auto_switch_lock = AutoSwitchLock::acquire(&self.env.app_data_dir)?;
        let output = self.claude_auto_switch_decide()?;
        if output.status != "ready" {
            return Ok(output);
        }
        let Some(candidate_id) = output.candidate_account_id else {
            bail!("auto-switch decided ready without a candidate");
        };
        if preferred.is_some_and(|id| id != candidate_id) {
            let settings = load_settings(&self.env.app_data_dir)?;
            return Ok(self.claude_auto_switch_output(
                &settings,
                "no_candidate",
                None,
                output.active_account_id,
                None,
                Some("candidate changed during auto-switch decision".to_owned()),
            ));
        }
        let _auth_lock = AuthLock::acquire(&self.env.app_data_dir)?;
        let store = self.provider_store();
        let provider_adapter = adapter(AiProvider::Claude);
        let (record, snapshot) = store.load_snapshot(&self.env.kind, candidate_id)?;
        if let Some(reason) = record.activation_block_reason(Some(&snapshot)) {
            let settings = load_settings(&self.env.app_data_dir)?;
            return Ok(self.claude_auto_switch_output(
                &settings,
                "no_candidate",
                None,
                output.active_account_id,
                None,
                Some(reason),
            ));
        }
        // AuthLock remains held through the expected-active check and restore.
        {
            let _operation_lock = OperationLock::acquire(&self.env.app_data_dir)?;
            let current_live_id = provider_adapter
                .try_read_live_auth(&self.env)?
                .and_then(|bundle| {
                    store
                        .find_matching(&self.env.kind, AiProvider::Claude, &bundle.identity)
                        .ok()
                        .flatten()
                })
                .map(|acc| acc.id);
            if current_live_id != output.active_account_id {
                let settings = load_settings(&self.env.app_data_dir)?;
                return Ok(self.claude_auto_switch_output(
                    &settings,
                    "no_candidate",
                    None,
                    current_live_id,
                    None,
                    Some(
                        "active account changed between auto-switch decision and apply".to_owned(),
                    ),
                ));
            }
        }
        if provider_adapter.snapshot_access_token_expires_within(&snapshot, FRESHEN_WITHIN) {
            match provider_adapter.refresh_snapshot(&snapshot) {
                SnapshotRefresh::Refreshed(new_snapshot) => {
                    let _operation_lock = OperationLock::acquire(&self.env.app_data_dir)?;
                    store.save_rotated_snapshot(
                        &self.env.kind,
                        record.id,
                        &snapshot,
                        &new_snapshot,
                    )?;
                    eprintln!("refreshed Claude token for {}", record.identity.email);
                }
                SnapshotRefresh::Dead(reason) => {
                    let detail = format!(
                        "{LOGIN_REQUIRED_ERROR_PREFIX}: refresh token rejected ({reason}); sign in with Claude Code as this account and save it again"
                    );
                    let _operation_lock = OperationLock::acquire(&self.env.app_data_dir)?;
                    store.record_usage_error(&self.env.kind, record.id, detail.clone())?;
                    let settings = load_settings(&self.env.app_data_dir)?;
                    return Ok(self.claude_auto_switch_output(
                        &settings,
                        "no_candidate",
                        output.trigger.as_deref().map(|label| match label {
                            "at_limit" => Trigger::AtLimit,
                            "consume_first" => Trigger::ConsumeFirst,
                            _ => Trigger::Proactive,
                        }),
                        output.active_account_id,
                        None,
                        Some(detail),
                    ));
                }
                SnapshotRefresh::Transient(_) | SnapshotRefresh::Unsupported => {}
            }
        }
        let activation = self.provider_activate_with_auth_lock(candidate_id)?;
        self.complete_claude_auto_switch(output, activation.warnings)
    }

    fn complete_claude_auto_switch(
        &self,
        output: ProviderAutoSwitchOutput,
        mut warnings: Vec<String>,
    ) -> Result<ProviderAutoSwitchOutput> {
        let candidate_id = output.candidate_account_id;
        let bookkeeping = (|| {
            let _operation_lock = OperationLock::acquire(&self.env.app_data_dir)?;
            let mut settings = load_settings(&self.env.app_data_dir)?;
            settings.claude_last_auto_switch_at = Some(OffsetDateTime::now_utc());
            settings.claude_last_auto_switch_from = output.active_account_id;
            settings.claude_last_auto_switch_target = candidate_id;
            save_settings(&self.env.app_data_dir, &settings)
        })();
        if let Err(error) = bookkeeping {
            warnings.push(format!(
                "Login changed, but auto-switch settings could not be saved: {error:#}"
            ));
        }
        let mut output = output;
        output.status = "switched".to_owned();
        if !warnings.is_empty() {
            output.detail = Some(warnings.join("; "));
        }
        Ok(output)
    }

    pub fn set_claude_auto_switch(
        &self,
        enabled: Option<bool>,
        threshold: Option<u8>,
        hysteresis: Option<u8>,
        cooldown: Option<u64>,
        strategy: Option<ClaudeAutoSwitchStrategy>,
    ) -> Result<ProviderAutoSwitchOutput> {
        let _operation_lock = OperationLock::acquire(&self.env.app_data_dir)?;
        let mut settings = load_settings(&self.env.app_data_dir)?;
        if let Some(threshold) = threshold {
            if !(50..=100).contains(&threshold) {
                bail!("claude auto-switch threshold must be between 50 and 100");
            }
            settings.claude_auto_switch_threshold_percent = threshold;
        }
        if let Some(hysteresis) = hysteresis {
            if hysteresis > 50 {
                bail!("claude auto-switch hysteresis must be between 0 and 50");
            }
            settings.claude_auto_switch_hysteresis_percent = hysteresis;
        }
        if let Some(cooldown) = cooldown {
            if cooldown > 3600 {
                bail!("claude auto-switch cooldown must be between 0 and 3600 seconds");
            }
            settings.claude_auto_switch_cooldown_seconds = cooldown;
        }
        if let Some(strategy) = strategy {
            settings.claude_auto_switch_strategy = strategy;
        }
        if let Some(enabled) = enabled {
            settings.claude_auto_switch = enabled;
            if !enabled {
                settings.claude_last_auto_switch_at = None;
                settings.claude_last_auto_switch_from = None;
                settings.claude_last_auto_switch_target = None;
            }
        }
        save_settings(&self.env.app_data_dir, &settings)?;
        Ok(self.claude_auto_switch_output(
            &settings,
            if settings.claude_auto_switch {
                "enabled"
            } else {
                "disabled"
            },
            None,
            None,
            None,
            None,
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn review_fix_switched_result_survives_settings_failure() {
        use std::os::unix::fs::PermissionsExt;
        let temp = tempfile::tempdir().unwrap();
        let env = crate::env::AppEnv {
            kind: crate::model::EnvironmentKind::Macos,
            home_dir: temp.path().join("home"),
            codex_root: temp.path().join("home/.codex"),
            app_data_dir: temp.path().join("data"),
        };
        let repository = crate::repository::SnapshotRepository::new(
            &env.app_data_dir,
            crate::secrets::test_support::MemorySecretStore::default(),
        );
        let app = App::new(env, repository);
        drop(OperationLock::acquire(&app.env.app_data_dir).unwrap());
        let candidate = CandidateRow {
            id: Uuid::new_v4(),
            display_name: "target".into(),
            headroom: 90,
            utilization: 10,
            seven_day_reset_at: None,
        };
        let output = app.claude_auto_switch_output(
            &AppSettings::default(),
            "ready",
            Some(Trigger::AtLimit),
            Some(Uuid::new_v4()),
            Some(&candidate),
            None,
        );
        std::fs::set_permissions(
            &app.env.app_data_dir,
            std::fs::Permissions::from_mode(0o500),
        )
        .unwrap();
        let result = app.complete_claude_auto_switch(output, Vec::new());
        std::fs::set_permissions(
            &app.env.app_data_dir,
            std::fs::Permissions::from_mode(0o700),
        )
        .unwrap();
        let result = result.expect("completed credential switch must not be reported as failed");
        assert_eq!(result.status, "switched");
        assert_eq!(result.candidate_account_id, Some(candidate.id));
        assert!(result.detail.unwrap().contains("settings"));
    }

    #[test]
    fn provider_review_partial_usage_cannot_qualify_for_auto_switch() {
        for missing in ["five_hour", "seven_day"] {
            let mut partial = usage(ProviderUsageStatus::Ok, 1, 1);
            partial.windows.retain(|window| window.key != missing);
            assert_eq!(claude_binding_utilization(&partial), None);
        }
        let mut invalid = usage(ProviderUsageStatus::Ok, 1, 1);
        invalid.windows[1].used_percent = None;
        assert_eq!(claude_binding_utilization(&invalid), None);
        invalid.windows[1].used_percent = Some(101);
        assert_eq!(claude_binding_utilization(&invalid), None);
        let mut model_unknown = usage(ProviderUsageStatus::Ok, 1, 1);
        model_unknown
            .windows
            .push(crate::model::ProviderUsageWindowView {
                key: "seven_day_opus".into(),
                used_percent: None,
                ..Default::default()
            });
        assert_eq!(claude_binding_utilization(&model_unknown), None);
        assert_eq!(
            claude_binding_utilization(&usage(ProviderUsageStatus::Ok, 1, 99)),
            Some(99)
        );
    }

    fn settings(
        strategy: ClaudeAutoSwitchStrategy,
        last_at: Option<OffsetDateTime>,
        last_from: Option<Uuid>,
    ) -> AppSettings {
        AppSettings {
            claude_auto_switch: true,
            claude_auto_switch_threshold_percent: 95,
            claude_auto_switch_hysteresis_percent: 10,
            claude_auto_switch_cooldown_seconds: 300,
            claude_auto_switch_strategy: strategy,
            claude_last_auto_switch_at: last_at,
            claude_last_auto_switch_from: last_from,
            claude_last_auto_switch_target: None,
            ..AppSettings::default()
        }
    }

    fn candidate(utilization: u8, reset_secs: Option<i64>) -> CandidateRow {
        CandidateRow {
            id: Uuid::new_v4(),
            display_name: "c".to_owned(),
            headroom: 100u8.saturating_sub(utilization),
            utilization,
            seven_day_reset_at: reset_secs
                .map(|secs| OffsetDateTime::UNIX_EPOCH + time::Duration::seconds(secs)),
        }
    }

    fn usage(status: ProviderUsageStatus, five_hour: u8, seven_day: u8) -> ProviderUsageView {
        ProviderUsageView {
            provider: AiProvider::Claude,
            fetched_at: OffsetDateTime::now_utc(),
            status,
            fidelity: crate::model::UsageFidelity::Official,
            headline_window: None,
            windows: vec![
                crate::model::ProviderUsageWindowView {
                    key: "five_hour".to_owned(),
                    label: "5 hour".to_owned(),
                    used_percent: Some(five_hour),
                    remaining_percent: Some(100 - five_hour),
                    reset_at: None,
                    used: None,
                    limit: None,
                    unit: None,
                    ..Default::default()
                },
                crate::model::ProviderUsageWindowView {
                    key: "seven_day".to_owned(),
                    label: "7 day".to_owned(),
                    used_percent: Some(seven_day),
                    remaining_percent: Some(100 - seven_day),
                    reset_at: None,
                    used: None,
                    limit: None,
                    unit: None,
                    ..Default::default()
                },
            ],
            plan_label: None,
            detail: None,
        }
    }

    #[test]
    fn generic_model_limit_prevents_selecting_an_exhausted_account() {
        let mut u = usage(ProviderUsageStatus::Ok, 10, 20);
        u.windows.push(crate::model::ProviderUsageWindowView {
            key: "seven_day_fable".into(),
            used_percent: Some(100),
            ..Default::default()
        });
        assert_eq!(claude_binding_utilization(&u), Some(100));
        assert_eq!(claude_headroom(&u), Some(0));
    }

    #[test]
    fn binding_utilization_includes_model_limits_and_rejects_stale_data() {
        let mut u = usage(ProviderUsageStatus::Ok, 40, 70);
        u.windows.push(crate::model::ProviderUsageWindowView {
            key: "seven_day_opus".to_owned(),
            label: "7 day Opus".to_owned(),
            used_percent: Some(99),
            remaining_percent: Some(1),
            reset_at: None,
            used: None,
            limit: None,
            unit: None,
            ..Default::default()
        });
        assert_eq!(claude_binding_utilization(&u), Some(99));
        assert_eq!(claude_headroom(&u), Some(1));
        u.status = ProviderUsageStatus::Stale;
        assert_eq!(claude_binding_utilization(&u), None);
        u.status = ProviderUsageStatus::CredentialExpired;
        assert_eq!(claude_binding_utilization(&u), None);
    }

    #[test]
    fn below_threshold_when_active_under_line() {
        let s = settings(ClaudeAutoSwitchStrategy::Best, None, None);
        let now = OffsetDateTime::now_utc();
        match decide(50, None, &[candidate(10, Some(100))], &s, now) {
            Decision::BelowThreshold => {}
            _ => panic!("expected BelowThreshold"),
        }
    }

    #[test]
    fn proactive_picks_max_headroom_clearing_hysteresis() {
        let s = settings(ClaudeAutoSwitchStrategy::Best, None, None);
        let now = OffsetDateTime::now_utc();
        // active util 96 >= 95, headroom 4 → need candidate headroom >= 14
        let weak = candidate(90, Some(100)); // headroom 10 < 14
        let strong = candidate(80, Some(50)); // headroom 20
        match decide(
            96,
            Some(OffsetDateTime::UNIX_EPOCH),
            &[weak, strong],
            &s,
            now,
        ) {
            Decision::Switch { trigger, candidate } => {
                assert_eq!(trigger, Trigger::Proactive);
                assert_eq!(candidate.utilization, 80);
            }
            _ => panic!("expected Switch"),
        }
    }

    #[test]
    fn proactive_refuses_when_no_candidate_clears_hysteresis() {
        let s = settings(ClaudeAutoSwitchStrategy::Best, None, None);
        let now = OffsetDateTime::now_utc();
        // active util 96, headroom 4; candidate headroom 10 < 14
        match decide(96, None, &[candidate(90, Some(100))], &s, now) {
            Decision::NoCandidate { trigger } => assert_eq!(trigger, Trigger::Proactive),
            _ => panic!("expected NoCandidate"),
        }
    }

    #[test]
    fn at_limit_ignores_hysteresis_and_cooldown() {
        let mut s = settings(ClaudeAutoSwitchStrategy::Best, None, None);
        s.claude_last_auto_switch_at = Some(OffsetDateTime::now_utc());
        let now = OffsetDateTime::now_utc();
        // active util 99 → at_limit; headroom 10 fails hysteresis (needs 11) but AtLimit ignores it
        match decide(99, None, &[candidate(90, Some(100))], &s, now) {
            Decision::Switch { trigger, .. } => assert_eq!(trigger, Trigger::AtLimit),
            _ => panic!("expected Switch"),
        }
    }

    #[test]
    fn cooldown_blocks_proactive() {
        let mut s = settings(ClaudeAutoSwitchStrategy::Best, None, None);
        s.claude_last_auto_switch_at = Some(OffsetDateTime::now_utc());
        let now = OffsetDateTime::now_utc();
        match decide(96, None, &[candidate(10, Some(100))], &s, now) {
            Decision::Cooldown { trigger } => assert_eq!(trigger, Trigger::Proactive),
            _ => panic!("expected Cooldown"),
        }
    }

    #[test]
    fn consume_first_picks_sooner_reset_with_room() {
        let s = settings(ClaudeAutoSwitchStrategy::ConsumeFirst, None, None);
        let now = OffsetDateTime::now_utc();
        let sooner = candidate(50, Some(100));
        let later = candidate(10, Some(500));
        let active_reset = Some(OffsetDateTime::UNIX_EPOCH + time::Duration::seconds(1000));
        match decide(50, active_reset, &[later.clone(), sooner.clone()], &s, now) {
            Decision::Switch { trigger, candidate } => {
                assert_eq!(trigger, Trigger::ConsumeFirst);
                assert_eq!(candidate.id, sooner.id);
            }
            _ => panic!("expected Switch"),
        }
        // active resets sooner than every candidate → no move
        match decide(
            50,
            Some(OffsetDateTime::UNIX_EPOCH),
            &[later, sooner],
            &s,
            now,
        ) {
            Decision::NoCandidate { trigger } => assert_eq!(trigger, Trigger::ConsumeFirst),
            _ => panic!("expected NoCandidate"),
        }
        // no active reset → no consume-first move at all
        match decide(50, None, &[candidate(10, Some(50))], &s, now) {
            Decision::NoCandidate { .. } => {}
            _ => panic!("expected NoCandidate"),
        }
    }

    #[test]
    fn never_switches_to_candidate_at_or_over_threshold() {
        let s = settings(ClaudeAutoSwitchStrategy::Best, None, None);
        let now = OffsetDateTime::now_utc();
        match decide(99, None, &[candidate(96, Some(100))], &s, now) {
            Decision::NoCandidate { .. } => {}
            _ => panic!("expected NoCandidate"),
        }
    }

    #[test]
    fn cached_usage_expires_after_reset_or_freshness_window() {
        let mut u = usage(ProviderUsageStatus::Ok, 10, 20);
        let now = OffsetDateTime::now_utc();
        assert!(usage_is_fresh(&u, now));
        u.windows[0].reset_at = Some(now);
        assert!(!usage_is_fresh(&u, now));
        u.windows[0].reset_at = None;
        u.fetched_at = now - time::Duration::minutes(20);
        assert!(!usage_is_fresh(&u, now));
    }
}
