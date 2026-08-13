use std::fs::{self, File, OpenOptions};
use std::io;
use std::path::Path;
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, anyhow};
use fs2::FileExt;

const ACQUIRE_TIMEOUT: Duration = Duration::from_secs(90);
const RETRY_INTERVAL: Duration = Duration::from_millis(50);

/// A cross-process lease for operations that mutate auth or roster state.
///
/// Contended acquires wait briefly instead of failing immediately, so a usage
/// refresh does not make account activation fail with a transient lock error.
pub struct OperationLock(File);
pub struct AuthLock(File);

impl OperationLock {
    pub fn acquire(app_data_dir: &Path) -> Result<Self> {
        acquire_named_lock(app_data_dir, ".operation.lock", "account-state").map(Self)
    }
}

impl AuthLock {
    /// Serialize the complete read → OAuth refresh/Codex use → write transaction
    /// across every Roster process. Refresh tokens are single-use, so locking
    /// only the final file write is too late to prevent session invalidation.
    pub fn acquire(app_data_dir: &Path) -> Result<Self> {
        acquire_named_lock(app_data_dir, ".auth-operation.lock", "authentication").map(Self)
    }
}

fn acquire_named_lock(app_data_dir: &Path, file_name: &str, operation: &str) -> Result<File> {
    fs::create_dir_all(app_data_dir)
        .with_context(|| format!("failed to create {}", app_data_dir.display()))?;
    let path = app_data_dir.join(file_name);
    let file = OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .truncate(false)
        .open(&path)
        .with_context(|| format!("failed to open {}", path.display()))?;
    let deadline = Instant::now() + ACQUIRE_TIMEOUT;
    loop {
        match file.try_lock_exclusive() {
            Ok(()) => return Ok(file),
            Err(error) if is_lock_contention(&error) && Instant::now() < deadline => {
                thread::sleep(RETRY_INTERVAL);
            }
            Err(error) if is_lock_contention(&error) => {
                return Err(anyhow!(
                    "another Codex Roster {operation} operation is still running; timed out waiting for it to finish"
                ));
            }
            Err(error) => {
                return Err(anyhow!(
                    "failed to acquire Codex Roster {operation} lock: {error}"
                ));
            }
        }
    }
}

impl Drop for OperationLock {
    fn drop(&mut self) {
        let _ = self.0.unlock();
    }
}

impl Drop for AuthLock {
    fn drop(&mut self) {
        let _ = self.0.unlock();
    }
}

fn is_lock_contention(error: &io::Error) -> bool {
    matches!(
        error.kind(),
        io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut | io::ErrorKind::Interrupted
    ) || error.raw_os_error() == Some(35) // EAGAIN / EWOULDBLOCK on macOS
        || error.raw_os_error() == Some(11) // EAGAIN on Linux
        || error.raw_os_error() == Some(16) // EBUSY on some platforms
        || error.raw_os_error() == Some(33) // ERROR_LOCK_VIOLATION on Windows
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Barrier};
    use tempfile::tempdir;

    #[test]
    fn acquire_waits_for_contended_lock() {
        let temp = tempdir().expect("tempdir");
        let app_data_dir = temp.path().to_path_buf();
        let barrier = Arc::new(Barrier::new(2));

        let holder_dir = app_data_dir.clone();
        let holder_barrier = Arc::clone(&barrier);
        let holder = thread::spawn(move || {
            let lock = OperationLock::acquire(&holder_dir).expect("holder acquire");
            holder_barrier.wait();
            thread::sleep(Duration::from_millis(200));
            drop(lock);
        });

        barrier.wait();
        let started = Instant::now();
        let lock = OperationLock::acquire(&app_data_dir).expect("waiter acquire");
        assert!(started.elapsed() >= Duration::from_millis(150));
        drop(lock);
        holder.join().expect("holder thread");
    }

    #[test]
    fn auth_lock_waits_for_contended_token_transaction() {
        let temp = tempdir().expect("tempdir");
        let app_data_dir = temp.path().to_path_buf();
        let barrier = Arc::new(Barrier::new(2));

        let holder_dir = app_data_dir.clone();
        let holder_barrier = Arc::clone(&barrier);
        let holder = thread::spawn(move || {
            let lock = AuthLock::acquire(&holder_dir).expect("holder acquire");
            holder_barrier.wait();
            thread::sleep(Duration::from_millis(200));
            drop(lock);
        });

        barrier.wait();
        let started = Instant::now();
        let lock = AuthLock::acquire(&app_data_dir).expect("waiter acquire");
        assert!(started.elapsed() >= Duration::from_millis(150));
        drop(lock);
        holder.join().expect("holder thread");
    }

    #[test]
    fn is_lock_contention_detects_would_block() {
        assert!(is_lock_contention(&io::Error::from(
            io::ErrorKind::WouldBlock
        )));
        assert!(is_lock_contention(&io::Error::from_raw_os_error(35)));
        assert!(is_lock_contention(&io::Error::from_raw_os_error(33)));
        assert!(!is_lock_contention(&io::Error::from(
            io::ErrorKind::PermissionDenied
        )));
    }
}
