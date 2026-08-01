use std::fs::{self, File, OpenOptions};
use std::path::Path;

use anyhow::{Context, Result, anyhow};
use fs2::FileExt;

/// A non-blocking, cross-process lease for operations that mutate auth or roster state.
pub struct OperationLock(File);

impl OperationLock {
    pub fn acquire(app_data_dir: &Path) -> Result<Self> {
        fs::create_dir_all(app_data_dir)
            .with_context(|| format!("failed to create {}", app_data_dir.display()))?;
        let path = app_data_dir.join(".operation.lock");
        let file = OpenOptions::new()
            .create(true)
            .read(true)
            .write(true)
            .truncate(false)
            .open(&path)
            .with_context(|| format!("failed to open {}", path.display()))?;
        file.try_lock_exclusive().map_err(|error| {
            anyhow!(
                "another Codex Roster operation is already changing account state; retry after it finishes: {error}"
            )
        })?;
        Ok(Self(file))
    }
}

impl Drop for OperationLock {
    fn drop(&mut self) {
        let _ = self.0.unlock();
    }
}
