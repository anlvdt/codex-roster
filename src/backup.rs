use std::collections::HashMap;
use std::io::{Read, Write};
use std::path::Path;
use std::sync::{Mutex, OnceLock};
use std::time::SystemTime;

use age::secrecy::SecretString;
use anyhow::{Context, Result, anyhow};
use serde::{Deserialize, Serialize};
use time::OffsetDateTime;

use crate::model::{AiProvider, DisplayIdentity, SnapshotBlob};

const BACKUP_SCHEMA_VERSION: u32 = 1;
const AUTOMATIC_BACKUP_KEY_SERVICE: &str = "com.codexroster.app";
const AUTOMATIC_BACKUP_KEY_ACCOUNT: &str = "automatic-backup-key-v1";
#[cfg(not(test))]
const LOCAL_SNAPSHOT_KEY_ACCOUNT: &str = "local-snapshot-key-v1";
const MAX_ENCRYPTED_BACKUP_BYTES: u64 = 64 * 1024 * 1024;
const MAX_DECRYPTED_BACKUP_BYTES: u64 = 96 * 1024 * 1024;
pub const MAX_BACKUP_ACCOUNTS: usize = 100;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct BackupBundle {
    pub schema_version: u32,
    pub exported_at: OffsetDateTime,
    pub accounts: Vec<BackupAccount>,
    /// External provider accounts (Claude, Cursor, Grok).  Absent in bundles
    /// created by older versions of Roster; treated as an empty list on import.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub provider_accounts: Vec<ProviderBackupAccount>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct BackupAccount {
    pub identity: DisplayIdentity,
    pub custom_label: Option<String>,
    pub archived: bool,
    pub snapshot: SnapshotBlob,
}

/// An external provider account (Claude, Cursor, or Grok) included in a backup.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ProviderBackupAccount {
    pub provider: AiProvider,
    pub identity: DisplayIdentity,
    pub custom_label: Option<String>,
    pub snapshot: SnapshotBlob,
}

impl BackupBundle {
    pub fn new(accounts: Vec<BackupAccount>) -> Self {
        Self {
            schema_version: BACKUP_SCHEMA_VERSION,
            exported_at: OffsetDateTime::now_utc(),
            accounts,
            provider_accounts: Vec::new(),
        }
    }
}

pub fn write_encrypted(path: &Path, bundle: &BackupBundle, password: &str) -> Result<()> {
    ensure_password(password)?;
    let plaintext = serde_json::to_vec(bundle).context("failed to encode backup")?;
    let encryptor = age::Encryptor::with_user_passphrase(SecretString::from(password.to_owned()));
    write_backup_atomically(path, |file| {
        let mut writer = encryptor
            .wrap_output(file)
            .context("failed to initialize encrypted backup")?;
        writer
            .write_all(&plaintext)
            .context("failed to write encrypted backup")?;
        writer.finish().context("failed to finish encrypted backup")
    })
}

fn write_backup_atomically<F>(path: &Path, write: F) -> Result<()>
where
    F: FnOnce(std::fs::File) -> Result<std::fs::File>,
{
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    let name = path
        .file_name()
        .ok_or_else(|| anyhow!("backup path needs a file name"))?;
    let temp = parent.join(format!(
        "{}.tmp-{}",
        name.to_string_lossy(),
        uuid::Uuid::new_v4().simple()
    ));
    let result = (|| {
        let file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temp)?;
        let mut file = write(file)?;
        file.flush().context("failed to flush encrypted backup")?;
        file.sync_all().context("failed to sync encrypted backup")?;
        drop(file);
        #[cfg(not(windows))]
        std::fs::rename(&temp, path).context("failed to replace encrypted backup")?;
        // std::fs::rename cannot overwrite an existing destination on Windows.
        #[cfg(windows)]
        crate::file_store::replace_file_with_recovery(path, None, |staged| {
            std::fs::copy(&temp, staged)?;
            Ok(())
        })?;
        Ok(())
    })();
    let _ = std::fs::remove_file(&temp);
    result
}

pub fn read_encrypted(path: &Path, password: &str) -> Result<BackupBundle> {
    ensure_password(password)?;
    let metadata =
        std::fs::metadata(path).with_context(|| format!("failed to inspect {}", path.display()))?;
    if metadata.len() > MAX_ENCRYPTED_BACKUP_BYTES {
        return Err(anyhow!("backup exceeds the allowed encrypted size"));
    }
    let encrypted =
        std::fs::read(path).with_context(|| format!("failed to read {}", path.display()))?;
    let decryptor = age::Decryptor::new(encrypted.as_slice())
        .context("backup is not a valid encrypted Codex Roster file")?;
    if !decryptor.is_scrypt() {
        return Err(anyhow!("backup is not protected by a passphrase"));
    }
    let identity = age::scrypt::Identity::new(SecretString::from(password.to_owned()));
    let mut reader = decryptor
        .decrypt(std::iter::once(&identity as &dyn age::Identity))
        .context("could not decrypt backup; check the password")?;
    let mut plaintext = Vec::new();
    reader
        .by_ref()
        .take(MAX_DECRYPTED_BACKUP_BYTES + 1)
        .read_to_end(&mut plaintext)
        .context("failed to read decrypted backup")?;
    if plaintext.len() as u64 > MAX_DECRYPTED_BACKUP_BYTES {
        return Err(anyhow!("decrypted backup exceeds the allowed size"));
    }
    let bundle: BackupBundle =
        serde_json::from_slice(&plaintext).context("backup contents are invalid")?;
    if bundle.schema_version != BACKUP_SCHEMA_VERSION {
        return Err(anyhow!(
            "backup schema version {} is not supported",
            bundle.schema_version
        ));
    }
    if bundle.accounts.len() + bundle.provider_accounts.len() > MAX_BACKUP_ACCOUNTS {
        return Err(anyhow!("backup contains too many accounts"));
    }
    Ok(bundle)
}

fn ensure_password(password: &str) -> Result<()> {
    if password.trim().is_empty() {
        Err(anyhow!("a backup password is required"))
    } else {
        Ok(())
    }
}

pub fn automatic_backup_password() -> Result<String> {
    cached_keyring_password(AUTOMATIC_BACKUP_KEY_ACCOUNT, "automatic-backup", true)
}

#[cfg(not(test))]
pub fn local_snapshot_password() -> Result<String> {
    // Decrypt path: never mint a replacement key (that bricks existing ciphertext).
    cached_keyring_password(LOCAL_SNAPSHOT_KEY_ACCOUNT, "local-snapshot", false)
}

#[cfg(not(test))]
pub fn local_snapshot_password_for_write() -> Result<String> {
    cached_keyring_password(LOCAL_SNAPSHOT_KEY_ACCOUNT, "local-snapshot", true)
}

#[cfg(test)]
pub fn local_snapshot_password() -> Result<String> {
    Ok("codex-roster-test-local-snapshot-key".to_owned())
}

#[cfg(test)]
pub fn local_snapshot_password_for_write() -> Result<String> {
    local_snapshot_password()
}

fn cached_keyring_password(account: &str, key_name: &str, allow_create: bool) -> Result<String> {
    // One Keychain read per process — avoids repeated Unlock Keychain dialogs
    // during auto-switch usage fan-out / encrypt/decrypt loops.
    static CACHE: OnceLock<Mutex<HashMap<String, String>>> = OnceLock::new();
    let cache = CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    if let Ok(guard) = cache.lock()
        && let Some(password) = guard.get(account)
    {
        return Ok(password.clone());
    }
    let password = keyring_password(account, key_name, allow_create)?;
    if let Ok(mut guard) = cache.lock() {
        guard.insert(account.to_owned(), password.clone());
    }
    Ok(password)
}

fn keyring_password(account: &str, key_name: &str, allow_create: bool) -> Result<String> {
    // File-first. A key file in the app data directory survives app updates,
    // unlike a Keychain item whose access is bound to the app's (ad-hoc) code
    // signature — a changed signature silently orphaned older snapshots. The
    // Keychain remains a migration source and a redundant copy.
    if let Some(password) = read_key_file(account) {
        return Ok(password);
    }
    let entry = keyring::Entry::new(AUTOMATIC_BACKUP_KEY_SERVICE, account)
        .with_context(|| format!("failed to access the {key_name} key"))?;
    match entry.get_password() {
        Ok(password) if !password.is_empty() => {
            // Migrate the working key to a file so future updates keep decrypting.
            let _ = write_key_file(account, &password);
            Ok(password)
        }
        Ok(_) | Err(keyring::Error::NoEntry) if allow_create => {
            let password = format!(
                "{}{}",
                uuid::Uuid::new_v4().simple(),
                uuid::Uuid::new_v4().simple()
            );
            // The file is now the source of truth; keep a best-effort Keychain copy.
            write_key_file(account, &password)?;
            let _ = entry.set_password(&password);
            Ok(password)
        }
        // Missing key (NoEntry / empty) with no permission to create, or an access
        // error: never mint a replacement here — that would brick existing
        // ciphertext. Surface the same recoverable error as before.
        Ok(_) | Err(keyring::Error::NoEntry) => Err(anyhow!(
            "the {key_name} key is missing from the system credential store; existing encrypted sessions cannot be opened until that key is restored"
        )),
        Err(error) => Err(error).with_context(|| {
            format!("failed to read the {key_name} key from the system credential store")
        }),
    }
}

fn key_file_path(account: &str) -> Option<std::path::PathBuf> {
    directories::ProjectDirs::from("com", "codexroster", "codex-roster").map(|dirs| {
        dirs.data_local_dir()
            .join("keys")
            .join(format!("{account}.key"))
    })
}

fn read_key_file(account: &str) -> Option<String> {
    let path = key_file_path(account)?;
    let contents = std::fs::read_to_string(&path).ok()?;
    let trimmed = contents.trim();
    if trimmed.is_empty() {
        return None;
    }
    // Key files written by older versions were chmod'ed after creation and
    // never excluded from backups; bring them up to the current protection.
    let _ = protect_key_file(&path);
    Some(trimmed.to_owned())
}

fn write_key_file(account: &str, password: &str) -> Result<()> {
    let Some(path) = key_file_path(account) else {
        return Ok(());
    };
    write_key_file_at(&path, password)
}

/// Store the key privately and keep it out of backups.
///
/// Tradeoff: the key file is deliberately *not* carried by Time Machine or
/// other backup tools that honor the exclusion marker, so a backup of the
/// encrypted snapshots does not also contain the key that opens them. After a
/// restore onto a new machine the file is absent and the key is recovered from
/// the Keychain copy (`keyring_password` migrates it back to a file).
fn write_key_file_at(path: &Path, password: &str) -> Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| anyhow!("key file path {} has no parent", path.display()))?;
    create_private_key_directory(parent)?;
    let temp = parent.join(format!(
        ".{}.tmp-{}",
        path.file_name().and_then(|n| n.to_str()).unwrap_or("key"),
        uuid::Uuid::new_v4().simple()
    ));
    let result = write_private_new_file(&temp, password.as_bytes())
        .and_then(|()| {
            std::fs::rename(&temp, path)
                .with_context(|| format!("failed to store the key file {}", path.display()))
        })
        .and_then(|()| protect_key_file(path));
    if result.is_err() {
        let _ = std::fs::remove_file(&temp);
    }
    result
}

fn create_private_key_directory(dir: &Path) -> Result<()> {
    std::fs::create_dir_all(dir).with_context(|| format!("failed to create {}", dir.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))
            .with_context(|| format!("failed to protect {}", dir.display()))?;
    }
    exclude_from_backup(dir);
    Ok(())
}

/// Create `path` exclusively with mode 0600 from the start (no window where
/// it exists with umask-derived permissions).
fn write_private_new_file(path: &Path, bytes: &[u8]) -> Result<()> {
    use std::io::Write;
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options
        .open(path)
        .with_context(|| format!("failed to store the key file {}", path.display()))?;
    file.write_all(bytes)
        .with_context(|| format!("failed to store the key file {}", path.display()))?;
    file.sync_all()
        .with_context(|| format!("failed to store the key file {}", path.display()))
}

fn protect_key_file(path: &Path) -> Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))
            .with_context(|| format!("failed to protect {}", path.display()))?;
    }
    exclude_from_backup(path);
    Ok(())
}

/// Binary plist for the string "com.apple.backupd": the value Time Machine
/// reads from `com.apple.metadata:com_apple_backup_excludeItem` (the same
/// marker `NSURLIsExcludedFromBackupKey` sets).
#[cfg(target_os = "macos")]
const BACKUP_EXCLUDE_XATTR_HEX: &str = "62706c69737430305f1011636f6d2e6170706c652e6261636b75706408000000000000010100000000000000010000000000000000000000000000001c";

/// Best-effort: failing to set the marker must not block key storage.
fn exclude_from_backup(path: &Path) {
    #[cfg(target_os = "macos")]
    {
        let _ = std::process::Command::new("/usr/bin/xattr")
            .args([
                "-wx",
                "com.apple.metadata:com_apple_backup_excludeItem",
                BACKUP_EXCLUDE_XATTR_HEX,
            ])
            .arg(path)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status();
    }
    #[cfg(not(target_os = "macos"))]
    let _ = path;
}

pub fn newest_automatic_backup(directory: &Path) -> Result<std::path::PathBuf> {
    let mut paths = std::fs::read_dir(directory)
        .with_context(|| format!("failed to read {}", directory.display()))?
        .filter_map(|entry| entry.ok())
        .filter_map(|entry| {
            let path = entry.path();
            (path.extension().and_then(|extension| extension.to_str()) == Some("codexroster"))
                .then_some(path)
        })
        .collect::<Vec<_>>();
    paths.sort_by_key(|path| {
        std::fs::metadata(path)
            .and_then(|metadata| metadata.modified())
            .unwrap_or(SystemTime::UNIX_EPOCH)
    });
    paths
        .pop()
        .ok_or_else(|| anyhow!("no automatic full backup is available"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn review_regression_failed_backup_write_preserves_existing_destination() {
        let temp = tempdir().unwrap();
        let path = temp.path().join("backup.codexroster");
        std::fs::write(&path, b"previous encrypted backup").unwrap();
        let error = write_backup_atomically(&path, |mut file| {
            file.write_all(b"partial encrypted output")?;
            Err(anyhow!("injected encryption/finalization failure"))
        })
        .unwrap_err();
        assert!(error.to_string().contains("injected"));
        assert_eq!(std::fs::read(&path).unwrap(), b"previous encrypted backup");
        assert_eq!(std::fs::read_dir(temp.path()).unwrap().count(), 1);
    }

    #[test]
    fn review_regression_backup_success_replaces_existing_file_after_finish() {
        let temp = tempdir().unwrap();
        let path = temp.path().join("backup.codexroster");
        std::fs::write(&path, b"previous").unwrap();
        let bundle = BackupBundle::new(Vec::new());
        write_encrypted(&path, &bundle, "fixture-password").unwrap();
        assert_eq!(
            read_encrypted(&path, "fixture-password")
                .unwrap()
                .exported_at,
            bundle.exported_at
        );
        assert_eq!(std::fs::read_dir(temp.path()).unwrap().count(), 1);
    }

    #[cfg(unix)]
    #[test]
    fn key_file_is_private_atomic_and_leaves_no_temp_files() {
        use std::os::unix::fs::PermissionsExt;
        let temp = tempdir().expect("tempdir");
        let path = temp.path().join("keys").join("acct.key");
        write_key_file_at(&path, "first").expect("write");
        write_key_file_at(&path, "second").expect("overwrite");
        assert_eq!(std::fs::read_to_string(&path).expect("read"), "second");
        let file_mode = std::fs::metadata(&path).expect("meta").permissions().mode();
        assert_eq!(file_mode & 0o777, 0o600);
        let dir_mode = std::fs::metadata(path.parent().expect("parent"))
            .expect("meta")
            .permissions()
            .mode();
        assert_eq!(dir_mode & 0o777, 0o700);
        let entries = std::fs::read_dir(path.parent().expect("parent"))
            .expect("read_dir")
            .count();
        assert_eq!(entries, 1, "temp file must not remain");
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn key_file_is_marked_excluded_from_backup() {
        let temp = tempdir().expect("tempdir");
        let path = temp.path().join("keys").join("acct.key");
        write_key_file_at(&path, "secret").expect("write");
        let output = std::process::Command::new("/usr/bin/xattr")
            .arg(&path)
            .output()
            .expect("xattr");
        assert!(
            String::from_utf8_lossy(&output.stdout)
                .contains("com.apple.metadata:com_apple_backup_excludeItem")
        );
    }

    #[test]
    fn encrypted_backup_round_trips() {
        let temp = tempdir().expect("tempdir");
        let path = temp.path().join("backup.codexroster");
        write_encrypted(
            &path,
            &BackupBundle::new(Vec::new()),
            "correct horse battery staple",
        )
        .expect("write");
        assert!(read_encrypted(&path, "correct horse battery staple").is_ok());
        assert!(read_encrypted(&path, "wrong").is_err());
    }
}
