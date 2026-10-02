use std::sync::mpsc::Sender;
use std::sync::{Condvar, Mutex, OnceLock};
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
pub const VIBE_USAGE_SYNC_POLL_SECONDS: u64 = 1800;

static USAGE_REFRESH_RUN_LOCK: OnceLock<Mutex<()>> = OnceLock::new();
static USAGE_REFRESH_CHECK_LISTENERS: OnceLock<Mutex<Vec<Sender<()>>>> = OnceLock::new();

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

/// One-shot stop flag whose waiters sleep on a condvar, so a stop request
/// interrupts a long poll sleep immediately instead of after the full interval.
struct StopSignal {
    stopped: Mutex<bool>,
    wake: Condvar,
}

impl StopSignal {
    const fn new() -> Self {
        Self {
            stopped: Mutex::new(false),
            wake: Condvar::new(),
        }
    }

    fn stop(&self) {
        if let Ok(mut stopped) = self.stopped.lock() {
            *stopped = true;
        }
        self.wake.notify_all();
    }

    fn is_stopped(&self) -> bool {
        self.stopped.lock().map(|stopped| *stopped).unwrap_or(true)
    }

    /// Sleep up to `duration`; returns `true` if the signal was (or becomes) stopped.
    fn sleep(&self, duration: StdDuration) -> bool {
        let Ok(guard) = self.stopped.lock() else {
            return true;
        };
        match self
            .wake
            .wait_timeout_while(guard, duration, |stopped| !*stopped)
        {
            Ok((stopped, _)) => *stopped,
            Err(_) => true,
        }
    }
}

static VIBE_USAGE_STOP: StopSignal = StopSignal::new();

/// Ask the VibeCafe sync worker to exit. It stops at its next checkpoint: right
/// away if sleeping, or once an in-flight sync finishes.
pub fn stop_vibe_usage_worker() {
    VIBE_USAGE_STOP.stop();
}

/// Periodically sync local Codex usage to VibeCafe when the user has configured
/// the optional collector. A missing Node.js/package is intentionally silent.
/// The worker exits when `stop_vibe_usage_worker` is called.
pub fn spawn_vibe_usage_worker(env: AppEnv) {
    static STARTED: OnceLock<()> = OnceLock::new();
    STARTED.get_or_init(|| {
        let _ = thread::Builder::new()
            .name("vibe-usage".to_owned())
            .spawn(move || {
                let poll = StdDuration::from_secs(VIBE_USAGE_SYNC_POLL_SECONDS);
                while !VIBE_USAGE_STOP.is_stopped() {
                    if !crate::vibe_usage::is_configured(&env.home_dir) {
                        if VIBE_USAGE_STOP.sleep(poll) {
                            break;
                        }
                        continue;
                    }
                    let sync_ok = std::process::Command::new("npx")
                        .args(["--yes", crate::vibe_usage::VIBE_USAGE_NPM_SPEC, "sync"])
                        .status()
                        .is_ok_and(|status| status.success());
                    if VIBE_USAGE_STOP.is_stopped() {
                        break;
                    }
                    if sync_ok {
                        let _ =
                            crate::vibe_usage::fetch_and_cache(&env.home_dir, &env.app_data_dir);
                    }
                    if VIBE_USAGE_STOP.sleep(poll) {
                        break;
                    }
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

#[cfg(all(test, windows))]
mod tests {
    use super::*;

    #[test]
    fn usage_refresh_notification_reaches_listener() {
        let receiver = subscribe_usage_refresh_checks();

        notify_usage_refresh_checked();

        receiver
            .recv_timeout(StdDuration::from_secs(1))
            .expect("listener should receive usage-refresh notification");
    }
}

#[cfg(test)]
mod stop_signal_tests {
    use super::*;
    use std::time::Instant;

    #[test]
    fn stop_signal_times_out_when_not_stopped() {
        let signal = StopSignal::new();
        assert!(!signal.sleep(StdDuration::from_millis(20)));
        assert!(!signal.is_stopped());
    }

    #[test]
    fn stop_signal_interrupts_a_long_sleep() {
        static SIGNAL: StopSignal = StopSignal::new();
        let waiter = thread::spawn(|| {
            let started = Instant::now();
            let stopped = SIGNAL.sleep(StdDuration::from_secs(60));
            (stopped, started.elapsed())
        });
        thread::sleep(StdDuration::from_millis(50));
        SIGNAL.stop();
        let (stopped, elapsed) = waiter.join().expect("join");
        assert!(stopped);
        assert!(elapsed < StdDuration::from_secs(5), "took {elapsed:?}");
        assert!(SIGNAL.sleep(StdDuration::from_secs(60)), "stays stopped");
    }
}
