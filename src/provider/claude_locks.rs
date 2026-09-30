use std::fs;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant, SystemTime};

use anyhow::{Context, Result, bail};

use crate::env::AppEnv;

const CREDENTIALS_STALENESS: Duration = Duration::from_secs(60);
const CONFIG_STALENESS: Duration = Duration::from_secs(10);
const DEFAULT_TIMEOUT: Duration = Duration::from_secs(9);
const TOUCH_INTERVAL: Duration = Duration::from_secs(3);

#[derive(Debug)]
pub(crate) struct LockGuard {
    dir: PathBuf,
    stop: Option<mpsc::Sender<()>>,
    toucher: Option<thread::JoinHandle<()>>,
}

impl Drop for LockGuard {
    fn drop(&mut self) {
        drop(self.stop.take());
        if let Some(toucher) = self.toucher.take() {
            let _ = toucher.join();
        }
        match fs::remove_dir(&self.dir) {
            Ok(()) => {}
            Err(error) if error.kind() == ErrorKind::NotFound => {}
            Err(error) => {
                eprintln!("failed to release lock {}: {error}", self.dir.display());
            }
        }
    }
}

pub(crate) fn acquire(
    lock_dir: &Path,
    timeout: Duration,
    staleness: Duration,
) -> Result<LockGuard> {
    if let Some(parent) = lock_dir.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("failed to create {}", parent.display()))?;
    }
    let start = Instant::now();
    loop {
        match fs::create_dir(lock_dir) {
            Ok(()) => break,
            Err(error) if error.kind() == ErrorKind::AlreadyExists => {}
            Err(error) => {
                return Err(error)
                    .with_context(|| format!("failed to create {}", lock_dir.display()));
            }
        }
        if start.elapsed() > timeout {
            bail!(
                "Could not acquire {} — Claude Code appears to be refreshing credentials. Retry in a few seconds.",
                lock_dir
                    .file_name()
                    .map(|name| name.to_string_lossy().into_owned())
                    .unwrap_or_else(|| lock_dir.display().to_string())
            );
        }
        match fs::metadata(lock_dir).and_then(|meta| meta.modified()) {
            Ok(mtime) => {
                if SystemTime::now().duration_since(mtime).unwrap_or_default() > staleness {
                    if fs::remove_dir(lock_dir).is_err() {
                        thread::sleep(Duration::from_millis(50));
                    }
                    continue;
                }
            }
            Err(error) if error.kind() == ErrorKind::NotFound => continue,
            Err(_) => {}
        }
        let jitter = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .map(|elapsed| elapsed.subsec_nanos() as u64 % 250)
            .unwrap_or(0);
        thread::sleep(Duration::from_millis(250 + jitter));
    }

    let (stop_tx, stop_rx) = mpsc::channel::<()>();
    let toucher = {
        let dir = lock_dir.to_path_buf();
        thread::spawn(move || {
            while let Err(mpsc::RecvTimeoutError::Timeout) = stop_rx.recv_timeout(TOUCH_INTERVAL) {
                if let Ok(file) = fs::File::open(&dir)
                    && file.set_modified(SystemTime::now()).is_err()
                {
                    break;
                }
            }
        })
    };
    Ok(LockGuard {
        dir: lock_dir.to_path_buf(),
        stop: Some(stop_tx),
        toucher: Some(toucher),
    })
}

pub(crate) fn credentials_lock(env: &AppEnv) -> Result<[LockGuard; 2]> {
    let claude_dir = env.home_dir.join(".claude");
    let refresh = acquire(
        &claude_dir.join(".oauth_refresh.lock"),
        DEFAULT_TIMEOUT,
        CREDENTIALS_STALENESS,
    )?;
    let legacy = acquire(
        &env.home_dir.join(".claude.lock"),
        DEFAULT_TIMEOUT,
        CREDENTIALS_STALENESS,
    )?;
    Ok([refresh, legacy])
}

pub(crate) fn config_lock(env: &AppEnv) -> Result<LockGuard> {
    acquire(
        &env.home_dir.join(".claude.json.lock"),
        DEFAULT_TIMEOUT,
        CONFIG_STALENESS,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn acquire_creates_dir_and_drop_removes_it() {
        let temp = tempfile::tempdir().expect("temp dir");
        let lock = temp.path().join("test.lock");
        {
            let _guard =
                acquire(&lock, Duration::from_secs(1), Duration::from_secs(60)).expect("acquire");
            assert!(lock.is_dir());
        }
        assert!(!lock.exists());
    }

    #[test]
    fn held_lock_times_out_for_second_acquire() {
        let temp = tempfile::tempdir().expect("temp dir");
        let lock = temp.path().join("test.lock");
        let _guard =
            acquire(&lock, Duration::from_secs(1), Duration::from_secs(60)).expect("acquire");
        let error = acquire(&lock, Duration::from_millis(300), Duration::from_secs(120))
            .expect_err("held lock should time out");
        assert!(error.to_string().contains("Could not acquire"));
    }

    #[test]
    fn stale_lock_is_stolen() {
        let temp = tempfile::tempdir().expect("temp dir");
        let lock = temp.path().join("test.lock");
        fs::create_dir(&lock).expect("lock dir");
        let file = fs::File::open(&lock).expect("open dir");
        file.set_modified(SystemTime::now() - Duration::from_secs(120))
            .expect("set mtime");
        drop(file);
        let _guard = acquire(&lock, Duration::from_millis(300), Duration::from_secs(60))
            .expect("stale lock should be stolen");
        assert!(lock.is_dir());
    }

    #[test]
    fn drop_completes_quickly() {
        let temp = tempfile::tempdir().expect("temp dir");
        let lock = temp.path().join("test.lock");
        let guard =
            acquire(&lock, Duration::from_secs(1), Duration::from_secs(60)).expect("acquire");
        let start = Instant::now();
        drop(guard);
        assert!(start.elapsed() < Duration::from_millis(500));
        assert!(!lock.exists());
    }
}
