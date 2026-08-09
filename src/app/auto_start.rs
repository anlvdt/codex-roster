use std::sync::mpsc::Sender;
#[cfg(windows)]
use std::sync::mpsc::{self, Receiver};
use std::sync::{Mutex, OnceLock};
use std::thread;
use std::time::Duration as StdDuration;

use anyhow::{Result, anyhow};
use time::OffsetDateTime;

use crate::env::AppEnv;
use crate::model::{
    AutoStartUsageWindowAccountResult, AutoStartUsageWindowsRunOutput,
    AutoStartUsageWindowsStatusOutput,
};
use crate::operation_lock::OperationLock;
use crate::repository::SnapshotRepository;
use crate::secrets::{MigratingSecretStore, SecretStore};
use crate::settings::{load_settings, save_settings};

use super::App;

pub const AUTO_START_USAGE_WINDOW_POLL_SECONDS: u64 = 300;

impl<S> App<S>
where
    S: SecretStore,
{
    pub fn auto_start_usage_windows_status(&self) -> Result<AutoStartUsageWindowsStatusOutput> {
        let settings = load_settings(&self.env.app_data_dir)?;
        Ok(auto_start_status_output(settings.auto_start_usage_windows))
    }

    pub fn set_auto_start_usage_windows(
        &self,
        enabled: bool,
    ) -> Result<AutoStartUsageWindowsStatusOutput> {
        let _operation_lock = OperationLock::acquire(&self.env.app_data_dir)?;
        let mut settings = load_settings(&self.env.app_data_dir)?;
        settings.auto_start_usage_windows = enabled;
        save_settings(&self.env.app_data_dir, &settings)?;
        Ok(auto_start_status_output(enabled))
    }

    pub fn auto_start_usage_windows_once(
        &self,
        require_enabled: bool,
    ) -> Result<AutoStartUsageWindowsRunOutput> {
        let settings = load_settings(&self.env.app_data_dir)?;
        let enabled = settings.auto_start_usage_windows;
        let mut output = AutoStartUsageWindowsRunOutput {
            enabled,
            checked_accounts: 0,
            pinged_accounts: Vec::new(),
            skipped: Vec::new(),
        };
        if require_enabled && !enabled {
            return Ok(output);
        }

        let _run_guard = AUTO_START_RUN_LOCK
            .get_or_init(|| Mutex::new(()))
            .lock()
            .map_err(|_| anyhow!("auto-start usage-window run lock poisoned"))?;
        let accounts = self.repository.list_accounts(&self.env.kind)?;
        output.checked_accounts = accounts.len();
        let now = OffsetDateTime::now_utc();
        let mut due_accounts = Vec::new();
        for account in &accounts {
            match self.usage(Some(account.id)) {
                Ok(usage) => {
                    if usage
                        .usage
                        .weekly
                        .as_ref()
                        .is_some_and(|weekly| usage_window_needs_ping(weekly.reset_at, now))
                    {
                        due_accounts.push((account.id, account.email.clone()));
                    }
                }
                Err(error) => output
                    .skipped
                    .push(format!("{}: usage unavailable: {error:#}", account.email)),
            }
        }
        if due_accounts.is_empty() {
            return Ok(output);
        }

        for (account_id, email) in due_accounts {
            if self.is_live_saved_account(account_id)? {
                // Let the official active session own any credential refresh.
                let _ = self.usage(None);
                output.pinged_accounts.push(AutoStartUsageWindowAccountResult {
                    account_id,
                    email,
                    status: "skipped_live".to_owned(),
                    detail: Some(
                        "active live session is refreshed through the official Codex credential store"
                            .to_owned(),
                    ),
                });
                continue;
            }
            output.pinged_accounts.push(AutoStartUsageWindowAccountResult {
                account_id,
                email,
                status: "skipped_inactive".to_owned(),
                detail: Some(
                    "inactive session preserved; background Codex login is disabled because it can rotate and invalidate saved refresh tokens"
                        .to_owned(),
                ),
            });
        }

        Ok(output)
    }
}

static AUTO_START_RUN_LOCK: OnceLock<Mutex<()>> = OnceLock::new();
static AUTO_START_CHECK_LISTENERS: OnceLock<Mutex<Vec<Sender<()>>>> = OnceLock::new();

#[cfg(windows)]
pub(crate) fn subscribe_auto_start_usage_windows_checks() -> Receiver<()> {
    let (sender, receiver) = mpsc::channel();
    let mut listeners = AUTO_START_CHECK_LISTENERS
        .get_or_init(|| Mutex::new(Vec::new()))
        .lock()
        .expect("auto-start usage-window listener lock poisoned");
    listeners.push(sender);
    receiver
}

pub fn spawn_auto_start_usage_windows_worker(env: AppEnv) {
    static STARTED: OnceLock<()> = OnceLock::new();
    STARTED.get_or_init(move || {
        let _ = thread::Builder::new()
            .name("auto-start-usage-windows".to_owned())
            .spawn(move || {
                loop {
                    if let Err(error) = run_auto_start_usage_windows_for_env(env.clone()) {
                        eprintln!("auto-start usage-window check failed: {error:#}");
                    }
                    notify_auto_start_usage_windows_checked();
                    thread::sleep(StdDuration::from_secs(AUTO_START_USAGE_WINDOW_POLL_SECONDS));
                }
            });
    });
}

fn notify_auto_start_usage_windows_checked() {
    let Some(listeners) = AUTO_START_CHECK_LISTENERS.get() else {
        return;
    };
    let Ok(mut listeners) = listeners.lock() else {
        eprintln!("auto-start usage-window listener lock poisoned");
        return;
    };
    listeners.retain(|listener| listener.send(()).is_ok());
}

#[cfg(windows)]
pub(crate) fn run_auto_start_usage_windows_check_now(env: AppEnv) -> Result<()> {
    run_auto_start_usage_windows_for_env(env)
}

fn run_auto_start_usage_windows_for_env(env: AppEnv) -> Result<()> {
    let repository = SnapshotRepository::new(
        &env.app_data_dir,
        MigratingSecretStore::new(&env.app_data_dir.join("snapshots")),
    );
    let app = App::new(env, repository);
    let _ = app.auto_start_usage_windows_once(true)?;
    Ok(())
}

fn auto_start_status_output(enabled: bool) -> AutoStartUsageWindowsStatusOutput {
    AutoStartUsageWindowsStatusOutput {
        enabled,
        poll_seconds: AUTO_START_USAGE_WINDOW_POLL_SECONDS,
    }
}

fn usage_window_needs_ping(reset_at: OffsetDateTime, now: OffsetDateTime) -> bool {
    reset_at <= now
}

#[cfg(test)]
mod tests {
    use time::Duration;

    use super::*;

    #[test]
    fn usage_window_needs_ping_when_reset_is_due_or_past() {
        let now = OffsetDateTime::now_utc();

        assert!(usage_window_needs_ping(now, now));
        assert!(usage_window_needs_ping(now - Duration::minutes(1), now));
        assert!(!usage_window_needs_ping(now + Duration::minutes(1), now));
    }

    #[cfg(windows)]
    #[test]
    fn auto_start_check_notification_reaches_listener() {
        let receiver = subscribe_auto_start_usage_windows_checks();

        notify_auto_start_usage_windows_checked();

        receiver
            .recv_timeout(StdDuration::from_secs(1))
            .expect("listener should receive auto-start check notification");
    }
}
