mod auto_start;
mod auto_switch_monitor;
mod service;
mod tui;
mod usage_refresh;

use uuid::Uuid;

pub use auto_start::spawn_auto_start_usage_windows_worker;
#[cfg(windows)]
pub(crate) use auto_start::{
    run_auto_start_usage_windows_check_now, subscribe_auto_start_usage_windows_checks,
};
pub use auto_switch_monitor::spawn_auto_switch_worker;
#[cfg(windows)]
pub(crate) use auto_switch_monitor::{run_auto_switch_check_now, subscribe_auto_switch_checks};
#[cfg(windows)]
pub(crate) use usage_refresh::subscribe_usage_refresh_checks;
pub use usage_refresh::{spawn_usage_refresh_worker, spawn_vibe_usage_worker};

use crate::env::AppEnv;
use crate::model::{
    AccountUsageView, AccountView, DisplayIdentity, RunningCodexProcess, SavedAccountMetadata,
};
use crate::repository::SnapshotRepository;
use crate::usage::usage_error_blocks_activation;

pub struct App<S> {
    env: AppEnv,
    repository: SnapshotRepository<S>,
}

#[derive(Clone, Copy)]
pub enum InteractiveMode {
    Persistent,
    ActivateOnce,
    DeleteOnce,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InteractiveExit {
    Quit,
    #[cfg(windows)]
    SendToTray,
}

fn account_view(
    account: SavedAccountMetadata,
    active_id: Option<Uuid>,
    usage: Option<AccountUsageView>,
    usage_error: Option<String>,
) -> AccountView {
    let usage_error = usage_error.or(account.cached_usage_error);
    let usage = if usage_error
        .as_deref()
        .is_some_and(usage_error_blocks_activation)
    {
        None
    } else {
        usage.or(account.cached_usage)
    };
    AccountView {
        id: account.id,
        provider: account.provider,
        email: account.email,
        subject: account.subject,
        name: account.name,
        custom_label: account.custom_label,
        plan_label: account.plan_label,
        environment: account.environment,
        is_active: active_id.is_some_and(|id| id == account.id),
        created_at: account.created_at,
        updated_at: account.updated_at,
        last_activated_at: account.last_activated_at,
        archived: account.archived,
        usage,
        usage_error,
    }
}

fn match_saved_account<'a>(
    accounts: &'a [SavedAccountMetadata],
    identity: &DisplayIdentity,
) -> Option<&'a SavedAccountMetadata> {
    accounts
        .iter()
        .find(|account| saved_identity(account).matches(identity))
}

fn account_view_matches_identity(account: &AccountView, identity: &DisplayIdentity) -> bool {
    DisplayIdentity {
        email: account.email.clone(),
        subject: account.subject.clone(),
        name: account.name.clone(),
        plan_label: account.plan_label.clone(),
    }
    .matches(identity)
}

fn saved_identity(account: &SavedAccountMetadata) -> DisplayIdentity {
    DisplayIdentity {
        email: account.email.clone(),
        subject: account.subject.clone(),
        name: account.name.clone(),
        plan_label: account.plan_label.clone(),
    }
}

fn subject_bound_identity_matches(expected: &DisplayIdentity, snapshot: &DisplayIdentity) -> bool {
    match (&expected.subject, &snapshot.subject) {
        (Some(left), Some(right)) => left == right,
        _ => false,
    }
}

fn should_verify_activation_stability(
    _force_running: bool,
    _warnings: &[RunningCodexProcess],
) -> bool {
    // Always verify for a full second after replacing auth files. A helper can
    // start just after the final process scan and write the previous session
    // back even when the scan itself was clean.
    true
}
