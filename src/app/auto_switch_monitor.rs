use std::sync::mpsc::Sender;
use std::sync::{Mutex, OnceLock};
use std::thread;
use std::time::Duration as StdDuration;

use anyhow::{Context, Result};

use crate::env::AppEnv;
use crate::repository::SnapshotRepository;
use crate::secrets::MigratingSecretStore;

use super::App;

pub const AUTO_SWITCH_POLL_SECONDS: u64 = 60;
/// Natural reset wait — keep AT probe load low while every account is empty.
pub const AUTO_SWITCH_EXHAUSTED_BACKOFF_SECONDS: u64 = 90;
/// Banked-reset wait — user may redeem any moment; poll more often so
/// same-account auto-resume fires promptly after redeem.
pub const AUTO_SWITCH_BANKED_RESET_BACKOFF_SECONDS: u64 = 45;

static AUTO_SWITCH_RUN_LOCK: OnceLock<Mutex<()>> = OnceLock::new();
static AUTO_SWITCH_CHECK_LISTENERS: OnceLock<Mutex<Vec<Sender<()>>>> = OnceLock::new();

pub fn spawn_auto_switch_worker(env: AppEnv) {
    static STARTED: OnceLock<()> = OnceLock::new();
    STARTED.get_or_init(move || {
        let _ = thread::Builder::new()
            .name("auto-switch-monitor".to_owned())
            .spawn(move || {
                loop {
                    let next_sleep = match run_auto_switch_for_env(env.clone()) {
                        Ok(seconds) => seconds,
                        Err(error) => {
                            eprintln!("auto-switch monitor failed: {error:#}");
                            AUTO_SWITCH_POLL_SECONDS
                        }
                    };
                    notify_auto_switch_checked();
                    thread::sleep(StdDuration::from_secs(next_sleep));
                }
            });
    });
}

fn notify_auto_switch_checked() {
    let Some(listeners) = AUTO_SWITCH_CHECK_LISTENERS.get() else {
        return;
    };
    let Ok(mut listeners) = listeners.lock() else {
        eprintln!("auto-switch listener lock poisoned");
        return;
    };
    listeners.retain(|listener| listener.send(()).is_ok());
}

fn run_auto_switch_for_env(env: AppEnv) -> Result<u64> {
    let _run_guard = AUTO_SWITCH_RUN_LOCK
        .get_or_init(|| Mutex::new(()))
        .lock()
        .map_err(|_| anyhow::anyhow!("auto-switch run lock poisoned"))?;
    let repository = SnapshotRepository::new(
        &env.app_data_dir,
        MigratingSecretStore::new(&env.app_data_dir.join("snapshots")),
    );
    let app = App::new(env, repository);
    if !app.auto_switch_enabled()? {
        return Ok(AUTO_SWITCH_POLL_SECONDS);
    }

    let decision = app.auto_switch(false)?;
    match decision.status.as_str() {
        "ready" => {}
        "banked_reset_available" => {
            return Ok(AUTO_SWITCH_BANKED_RESET_BACKOFF_SECONDS);
        }
        "all_accounts_exhausted" => {
            return Ok(AUTO_SWITCH_EXHAUSTED_BACKOFF_SECONDS);
        }
        _ => return Ok(AUTO_SWITCH_POLL_SECONDS),
    }

    let applied = app.auto_switch_with_candidate(true, decision.candidate_account_id, false)?;
    if applied.status != "switched" {
        let backoff = if applied.status == "all_accounts_exhausted" {
            AUTO_SWITCH_EXHAUSTED_BACKOFF_SECONDS
        } else if applied.status == "banked_reset_available" {
            AUTO_SWITCH_BANKED_RESET_BACKOFF_SECONDS
        } else {
            AUTO_SWITCH_POLL_SECONDS
        };
        return Ok(backoff);
    }

    let _ = app.list().context("reload roster after auto-switch")?;
    Ok(AUTO_SWITCH_POLL_SECONDS)
}
