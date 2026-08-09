use std::collections::HashMap;
use std::io::{Read, Write};
use std::path::Path;
use std::sync::{Mutex, OnceLock};
use std::time::SystemTime;

use age::secrecy::SecretString;
use anyhow::{Context, Result, anyhow};
use serde::{Deserialize, Serialize};
use time::OffsetDateTime;

use crate::model::{DisplayIdentity, SnapshotBlob};

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
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct BackupAccount {
    pub identity: DisplayIdentity,
    pub custom_label: Option<String>,
    pub archived: bool,
    pub snapshot: SnapshotBlob,
}

impl BackupBundle {
    pub fn new(accounts: Vec<BackupAccount>) -> Self {
        Self {
            schema_version: BACKUP_SCHEMA_VERSION,
            exported_at: OffsetDateTime::now_utc(),
            accounts,
        }
    }
}

pub fn write_encrypted(path: &Path, bundle: &BackupBundle, password: &str) -> Result<()> {
    ensure_password(password)?;
    let plaintext = serde_json::to_vec(bundle).context("failed to encode backup")?;
    let encryptor = age::Encryptor::with_user_passphrase(SecretString::from(password.to_owned()));
    let file = std::fs::File::create(path)
        .with_context(|| format!("failed to create {}", path.display()))?;
    let mut writer = encryptor
        .wrap_output(file)
        .context("failed to initialize encrypted backup")?;
    writer
        .write_all(&plaintext)
        .context("failed to write encrypted backup")?;
    writer
        .finish()
        .context("failed to finish encrypted backup")?;
    Ok(())
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
    if bundle.accounts.len() > MAX_BACKUP_ACCOUNTS {
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
    directories::ProjectDirs::from("com", "codexroster", "codex-roster")
        .map(|dirs| dirs.data_local_dir().join("keys").join(format!("{account}.key")))
}

fn read_key_file(account: &str) -> Option<String> {
    let path = key_file_path(account)?;
    let contents = std::fs::read_to_string(&path).ok()?;
    let trimmed = contents.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_owned())
    }
}

fn write_key_file(account: &str, password: &str) -> Result<()> {
    let Some(path) = key_file_path(account) else {
        return Ok(());
    };
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("failed to create {}", parent.display()))?;
    }
    std::fs::write(&path, password)
        .with_context(|| format!("failed to store the key file {}", path.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
    }
    Ok(())
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
