use anyhow::{Context, Result};

use crate::env::AppEnv;
use crate::model::{
    AiProvider, DisplayIdentity, ProviderCapability, ProviderUsageView, SnapshotBlob,
};

pub(crate) mod claude;
pub(crate) use claude::UNKNOWN_EMAIL;
mod claude_keychain;
mod claude_locks;
mod cursor;
mod grok;
mod openai;
mod pace;

pub struct ProviderAuthBundle {
    pub identity: DisplayIdentity,
    pub snapshot: SnapshotBlob,
}

pub enum SnapshotRefresh {
    Unsupported,
    Refreshed(SnapshotBlob),
    Dead(String),
    Transient(String),
}

pub trait ProviderAdapter: Sync {
    fn provider(&self) -> AiProvider;
    fn capabilities(&self) -> &'static [ProviderCapability];
    fn try_read_live_auth(&self, env: &AppEnv) -> Result<Option<ProviderAuthBundle>>;
    fn read_live_auth(&self, env: &AppEnv) -> Result<ProviderAuthBundle>;
    fn try_read_live_identity_noninteractive(
        &self,
        env: &AppEnv,
    ) -> Result<Option<DisplayIdentity>> {
        Ok(self.try_read_live_auth(env)?.map(|bundle| bundle.identity))
    }
    fn identity_from_snapshot(&self, snapshot: &SnapshotBlob) -> Result<DisplayIdentity>;
    fn restore_snapshot(&self, env: &AppEnv, snapshot: &SnapshotBlob) -> Result<()>;
    fn fetch_usage(&self, snapshot: &SnapshotBlob) -> Result<ProviderUsageView>;

    fn acquire_switch_guard(&self, _env: &AppEnv) -> Result<Box<dyn std::any::Any>> {
        Ok(Box::new(()))
    }

    fn snapshot_access_token_expired(&self, _snapshot: &SnapshotBlob) -> bool {
        false
    }
    fn snapshot_access_token_expires_within(
        &self,
        _snapshot: &SnapshotBlob,
        _within: std::time::Duration,
    ) -> bool {
        false
    }
    fn refresh_snapshot(&self, _snapshot: &SnapshotBlob) -> SnapshotRefresh {
        SnapshotRefresh::Unsupported
    }
    fn snapshot_shares_live_credential(&self, _env: &AppEnv, _snapshot: &SnapshotBlob) -> bool {
        false
    }
    fn snapshots_share_credential(&self, _a: &SnapshotBlob, _b: &SnapshotBlob) -> bool {
        false
    }

    fn requires_relaunch_after_switch(&self) -> bool {
        false
    }
}

pub fn adapter(provider: AiProvider) -> &'static dyn ProviderAdapter {
    match provider {
        AiProvider::OpenAi => &openai::OPENAI,
        AiProvider::Claude => &claude::CLAUDE,
        AiProvider::Cursor => &cursor::CURSOR,
        AiProvider::Grok => &grok::GROK,
    }
}

pub fn all() -> impl Iterator<Item = &'static dyn ProviderAdapter> {
    AiProvider::ALL.into_iter().map(adapter)
}

/// Byte-level backup + rollback for multi-target provider restores.
///
/// Pattern borrowed from cc-switch's write engine: stage every target file's
/// original bytes (or an explicit absent marker) before the first write, then
/// let the guard roll back on `Drop` unless `commit` ran. Writers inside the
/// guard still use atomic temp+rename, so readers never observe a partial file;
/// the guard exists so a failure halfway through a multi-file restore cannot
/// leave credentials/config half-switched.
///
/// The backup lives in a private temp directory under `parent` so rollback can
/// never leak credential bytes into a world-readable location.
pub(crate) struct FileRestoreGuard {
    backup_dir: std::path::PathBuf,
    targets: Vec<std::path::PathBuf>,
    committed: bool,
}

impl FileRestoreGuard {
    /// Snapshot the current bytes of each `target` (or record it absent) into a
    /// private backup dir created under `parent`.
    pub fn stage(
        parent: &std::path::Path,
        targets: &[std::path::PathBuf],
    ) -> Result<Self> {
        let backup_dir = parent.join(format!(".roster-restore-{}", uuid::Uuid::new_v4().simple()));
        #[cfg(unix)]
        {
            use std::os::unix::fs::DirBuilderExt;
            std::fs::DirBuilder::new()
                .recursive(true)
                .mode(0o700)
                .create(&backup_dir)
                .with_context(|| format!("failed to create {}", backup_dir.display()))?;
        }
        #[cfg(not(unix))]
        std::fs::create_dir_all(&backup_dir)
            .with_context(|| format!("failed to create {}", backup_dir.display()))?;

        for (index, target) in targets.iter().enumerate() {
            let slot = backup_dir.join(index.to_string());
            if target.exists() {
                let bytes = std::fs::read(target)
                    .with_context(|| format!("failed to back up {}", target.display()))?;
                write_private(&slot, &bytes)?;
            } else {
                write_private(&backup_dir.join(format!("{index}.absent")), b"")?;
            }
        }
        Ok(Self {
            backup_dir,
            targets: targets.to_vec(),
            committed: false,
        })
    }

    /// Restore every staged target to its pre-guard state. Best-effort per file:
    /// the first error is returned after attempting all targets.
    pub fn rollback(&self) -> Result<()> {
        let mut first_error = None;
        for (index, target) in self.targets.iter().enumerate() {
            let slot = self.backup_dir.join(index.to_string());
            let absent = self.backup_dir.join(format!("{index}.absent")).exists();
            let result: Result<()> = if absent {
                match std::fs::remove_file(target) {
                    Ok(()) => Ok(()),
                    Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
                    Err(error) => Err(error)
                        .with_context(|| format!("failed to remove {}", target.display())),
                }
            } else {
                match std::fs::read(&slot) {
                    Ok(bytes) => write_atomic_bytes(target, &bytes),
                    Err(error) => Err(error).with_context(|| {
                        format!("failed to read backup for {}", target.display())
                    }),
                }
            };
            if let Err(error) = result
                && first_error.is_none()
            {
                first_error = Some(error);
            }
        }
        match first_error {
            Some(error) => Err(error),
            None => Ok(()),
        }
    }

    /// Keep the restored files: drop the backup without rolling back.
    pub fn commit(mut self) {
        self.committed = true;
        let _ = std::fs::remove_dir_all(&self.backup_dir);
    }
}

impl Drop for FileRestoreGuard {
    fn drop(&mut self) {
        if self.committed {
            return;
        }
        // A mid-restore error unwinds through here; rollback is best-effort so a
        // rollback failure cannot mask the original error. The backup dir is
        // left in place for manual recovery when rollback itself fails.
        if self.rollback().is_ok() {
            let _ = std::fs::remove_dir_all(&self.backup_dir);
        }
    }
}

fn write_private(path: &std::path::Path, bytes: &[u8]) -> Result<()> {
    #[cfg(unix)]
    {
        use std::fs::OpenOptions;
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(path)
            .with_context(|| format!("failed to write {}", path.display()))?;
        file.write_all(bytes)
            .with_context(|| format!("failed to write {}", path.display()))?;
    }
    #[cfg(not(unix))]
    std::fs::write(path, bytes)
        .with_context(|| format!("failed to write {}", path.display()))?;
    Ok(())
}

/// Atomically replace `path` with `bytes`: private sibling temp + rename.
/// Same-file write used by rollback so a crash mid-restore never leaves a
/// truncated credential file.
pub(crate) fn write_atomic_bytes(path: &std::path::Path, bytes: &[u8]) -> Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("failed to create {}", parent.display()))?;
    }
    let name = path
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| "file".to_owned());
    let tmp = path.with_file_name(format!(".{}.tmp-{}", name, uuid::Uuid::new_v4().simple()));
    if let Err(error) = write_private(&tmp, bytes) {
        let _ = std::fs::remove_file(&tmp);
        return Err(error);
    }
    if let Err(error) = std::fs::rename(&tmp, path) {
        let _ = std::fs::remove_file(&tmp);
        return Err(error).with_context(|| format!("failed to replace {}", path.display()));
    }
    Ok(())
}

pub(crate) fn needs_auth_view(provider: AiProvider, detail: String) -> ProviderUsageView {
    ProviderUsageView {
        provider,
        fetched_at: time::OffsetDateTime::now_utc(),
        status: crate::model::ProviderUsageStatus::NeedsAuth,
        fidelity: crate::model::UsageFidelity::Official,
        headline_window: None,
        windows: Vec::new(),
        plan_label: None,
        detail: Some(detail),
    }
}

pub(crate) fn percent_window(
    key: impl Into<String>,
    label: impl Into<String>,
    used_percent: f64,
    reset_at: Option<time::OffsetDateTime>,
) -> crate::model::ProviderUsageWindowView {
    let used = used_percent.clamp(0.0, 100.0).round() as u8;
    crate::model::ProviderUsageWindowView {
        key: key.into(),
        label: label.into(),
        used_percent: Some(used),
        remaining_percent: Some(100u8.saturating_sub(used)),
        reset_at,
        used: None,
        limit: None,
        unit: None,
        ..Default::default()
    }
}

pub(crate) fn parse_datetime(value: &serde_json::Value) -> Option<time::OffsetDateTime> {
    use time::format_description::well_known::Rfc3339;

    if let Some(text) = value.as_str() {
        if let Ok(parsed) = time::OffsetDateTime::parse(text, &Rfc3339) {
            return Some(parsed);
        }
        if let Ok(epoch) = text.parse::<i64>() {
            return timestamp_from_number(epoch);
        }
    }
    value.as_i64().and_then(timestamp_from_number)
}

fn timestamp_from_number(value: i64) -> Option<time::OffsetDateTime> {
    if value.abs() > 10_000_000_000 {
        time::OffsetDateTime::from_unix_timestamp_nanos(i128::from(value) * 1_000_000).ok()
    } else {
        time::OffsetDateTime::from_unix_timestamp(value).ok()
    }
}

pub(crate) fn find_value<'a>(
    value: &'a serde_json::Value,
    keys: &[&str],
) -> Option<&'a serde_json::Value> {
    match value {
        serde_json::Value::Object(map) => {
            for key in keys {
                if let Some(found) = map.get(*key) {
                    return Some(found);
                }
            }
            map.values().find_map(|child| find_value(child, keys))
        }
        serde_json::Value::Array(items) => items.iter().find_map(|child| find_value(child, keys)),
        _ => None,
    }
}

pub(crate) fn find_string(value: &serde_json::Value, keys: &[&str]) -> Option<String> {
    find_value(value, keys)
        .and_then(serde_json::Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .map(str::to_owned)
}

pub(crate) fn find_number(value: &serde_json::Value, keys: &[&str]) -> Option<f64> {
    let value = find_value(value, keys)?;
    value
        .as_f64()
        .or_else(|| value.as_str()?.parse::<f64>().ok())
}

pub(crate) fn decode_jwt_claims(token: &str) -> Option<serde_json::Value> {
    use base64::Engine;
    let payload = token.split('.').nth(1)?;
    let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(payload)
        .or_else(|_| base64::engine::general_purpose::URL_SAFE.decode(payload))
        .ok()?;
    serde_json::from_slice(&bytes).ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn restore_guard_rolls_back_changed_and_new_files_on_drop() {
        let temp = tempfile::tempdir().expect("temp dir");
        let existing = temp.path().join("auth.json");
        let created = temp.path().join("new.json");
        fs::write(&existing, "old-bytes").expect("seed");

        {
            let guard = FileRestoreGuard::stage(
                temp.path(),
                &[existing.clone(), created.clone()],
            )
            .expect("stage");
            write_atomic_bytes(&existing, b"new-bytes").expect("write");
            write_atomic_bytes(&created, b"created").expect("write");
            drop(guard); // no commit -> rollback
        }

        assert_eq!(fs::read_to_string(&existing).expect("read"), "old-bytes");
        assert!(!created.exists());
        // A successful rollback also cleans the private backup dir.
        assert_eq!(
            fs::read_dir(temp.path())
                .expect("read dir")
                .filter_map(|entry| entry.ok())
                .filter(|entry| {
                    entry
                        .file_name()
                        .to_string_lossy()
                        .starts_with(".roster-restore-")
                })
                .count(),
            0
        );
    }

    #[test]
    fn restore_guard_commit_keeps_new_bytes_and_drops_backup() {
        let temp = tempfile::tempdir().expect("temp dir");
        let target = temp.path().join("auth.json");
        fs::write(&target, "old").expect("seed");

        let guard =
            FileRestoreGuard::stage(temp.path(), std::slice::from_ref(&target)).expect("stage");
        write_atomic_bytes(&target, b"new").expect("write");
        guard.commit();

        assert_eq!(fs::read_to_string(&target).expect("read"), "new");
    }

    #[cfg(unix)]
    #[test]
    fn write_atomic_bytes_creates_private_file() {
        use std::os::unix::fs::PermissionsExt;
        let temp = tempfile::tempdir().expect("temp dir");
        let target = temp.path().join("secret.json");
        write_atomic_bytes(&target, b"{\"token\":1}").expect("write");
        let mode = fs::metadata(&target).expect("metadata").permissions().mode();
        assert_eq!(mode & 0o777, 0o600);
        assert_eq!(fs::read_to_string(&target).expect("read"), "{\"token\":1}");
    }

    #[test]
    fn provider_capabilities_match_v1_implementation() {
        assert_eq!(
            adapter(AiProvider::Claude).capabilities(),
            &[
                ProviderCapability::ReadIdentity,
                ProviderCapability::MonitorUsage,
                ProviderCapability::SnapshotAuth,
                ProviderCapability::SwitchAccount,
            ]
        );
        assert_eq!(
            adapter(AiProvider::Cursor).capabilities(),
            &[
                ProviderCapability::ReadIdentity,
                ProviderCapability::MonitorUsage,
                ProviderCapability::SnapshotAuth,
                ProviderCapability::SwitchAccount,
                ProviderCapability::RelaunchApp,
            ]
        );
        assert_eq!(
            adapter(AiProvider::Grok).capabilities(),
            &[
                ProviderCapability::ReadIdentity,
                ProviderCapability::MonitorUsage,
                ProviderCapability::SnapshotAuth,
                ProviderCapability::SwitchAccount,
                ProviderCapability::ApiBilling,
            ]
        );
    }
}
