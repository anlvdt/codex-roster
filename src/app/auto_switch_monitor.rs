use std::sync::mpsc::Sender;
#[cfg(windows)]
use std::sync::mpsc::{self, Receiver};
use std::sync::{Mutex, OnceLock};
use std::thread;
use std::time::Duration as StdDuration;

use anyhow::{Context, Result};

use crate::env::AppEnv;
use crate::repository::SnapshotRepository;
use crate::secrets::MigratingSecretStore;

use super::App;

pub const AUTO_SWITCH_POLL_SECONDS: u64 = 60;

static AUTO_SWITCH_RUN_LOCK: OnceLock<Mutex<()>> = OnceLock::new();
static AUTO_SWITCH_CHECK_LISTENERS: OnceLock<Mutex<Vec<Sender<()>>>> = OnceLock::new();

#[cfg(windows)]
pub(crate) fn subscribe_auto_switch_checks() -> Receiver<()> {
    let (sender, receiver) = mpsc::channel();
    let mut listeners = AUTO_SWITCH_CHECK_LISTENERS
        .get_or_init(|| Mutex::new(Vec::new()))
        .lock()
        .expect("auto-switch listener lock poisoned");
    listeners.push(sender);
    receiver
}

pub fn spawn_auto_switch_worker(env: AppEnv) {
    static STARTED: OnceLock<()> = OnceLock::new();
    STARTED.get_or_init(move || {
        let _ = thread::Builder::new()
            .name("auto-switch-monitor".to_owned())
            .spawn(move || {
                loop {
                    if let Err(error) = run_auto_switch_for_env(env.clone()) {
                        eprintln!("auto-switch monitor failed: {error:#}");
                    }
                    notify_auto_switch_checked();
                    thread::sleep(StdDuration::from_secs(AUTO_SWITCH_POLL_SECONDS));
                }
            });
    });
}

#[cfg(windows)]
pub(crate) fn run_auto_switch_check_now(env: AppEnv) -> Result<()> {
    run_auto_switch_for_env(env)
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

fn run_auto_switch_for_env(env: AppEnv) -> Result<()> {
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
        return Ok(());
    }

    let decision = app.auto_switch(false)?;
    if decision.status != "ready" {
        return Ok(());
    }

    #[cfg(windows)]
    let relaunch_paths = {
        let paths = crate::windows_shell::close_desktop_for_switch();
        // After an explicit Desktop close, lingering Electron helpers must not
        // block apply forever — same policy as the Windows tray activate path.
        let applied = app.auto_switch_with_candidate(
            true,
            decision.candidate_account_id,
            true,
        )?;
        if applied.status != "switched" {
            crate::windows_shell::relaunch_desktop(&paths);
            return Ok(());
        }
        paths
    };
    #[cfg(not(windows))]
    {
        let applied = app.auto_switch_with_candidate(
            true,
            decision.candidate_account_id,
            false,
        )?;
        if applied.status != "switched" {
            return Ok(());
        }
    }

    #[cfg(windows)]
    crate::windows_shell::relaunch_desktop(&relaunch_paths);
    let _ = app.list().context("reload roster after auto-switch")?;
    Ok(())
}
