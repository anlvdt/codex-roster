use std::sync::mpsc::Sender;
#[cfg(windows)]
use std::sync::mpsc::{self, Receiver};
use std::sync::{Mutex, OnceLock};
use std::thread;
use std::time::Duration as StdDuration;

use anyhow::Result;

use crate::env::AppEnv;
use crate::repository::SnapshotRepository;
use crate::secrets::MigratingSecretStore;

use super::App;

/// How often the background worker sweeps saved accounts for stale quota.
/// Kept short enough that an off-schedule ChatGPT reset surfaces on the roster
/// within a couple of minutes, but only stale accounts actually hit the network.
pub const USAGE_REFRESH_POLL_SECONDS: u64 = 120;

static USAGE_REFRESH_RUN_LOCK: OnceLock<Mutex<()>> = OnceLock::new();
static USAGE_REFRESH_CHECK_LISTENERS: OnceLock<Mutex<Vec<Sender<()>>>> = OnceLock::new();

#[cfg(windows)]
pub(crate) fn subscribe_usage_refresh_checks() -> Receiver<()> {
    let (sender, receiver) = mpsc::channel();
    let mut listeners = USAGE_REFRESH_CHECK_LISTENERS
        .get_or_init(|| Mutex::new(Vec::new()))
        .lock()
        .expect("usage-refresh listener lock poisoned");
    listeners.push(sender);
    receiver
}

pub fn spawn_usage_refresh_worker(env: AppEnv) {
    static STARTED: OnceLock<()> = OnceLock::new();
    STARTED.get_or_init(move || {
        let _ = thread::Builder::new()
            .name("usage-refresh".to_owned())
            .spawn(move || {
                loop {
                    if let Err(error) = run_usage_refresh_for_env(env.clone()) {
                        eprintln!("usage refresh sweep failed: {error:#}");
                    }
                    notify_usage_refresh_checked();
                    thread::sleep(StdDuration::from_secs(USAGE_REFRESH_POLL_SECONDS));
                }
            });
    });
}

fn notify_usage_refresh_checked() {
    let Some(listeners) = USAGE_REFRESH_CHECK_LISTENERS.get() else {
        return;
    };
    let Ok(mut listeners) = listeners.lock() else {
        eprintln!("usage-refresh listener lock poisoned");
        return;
    };
    listeners.retain(|listener| listener.send(()).is_ok());
}

fn run_usage_refresh_for_env(env: AppEnv) -> Result<()> {
    let _run_guard = USAGE_REFRESH_RUN_LOCK
        .get_or_init(|| Mutex::new(()))
        .lock()
        .map_err(|_| anyhow::anyhow!("usage-refresh run lock poisoned"))?;
    let repository = SnapshotRepository::new(
        &env.app_data_dir,
        MigratingSecretStore::new(&env.app_data_dir.join("snapshots")),
    );
    let app = App::new(env, repository);
    app.refresh_stale_saved_usage()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(windows)]
    #[test]
    fn usage_refresh_notification_reaches_listener() {
        let receiver = subscribe_usage_refresh_checks();

        notify_usage_refresh_checked();

        receiver
            .recv_timeout(StdDuration::from_secs(1))
            .expect("listener should receive usage-refresh notification");
    }
}
