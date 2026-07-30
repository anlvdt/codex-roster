use std::io::{Read, Write};
use std::path::Path;
use std::time::SystemTime;

use age::secrecy::SecretString;
use anyhow::{Context, Result, anyhow};
use serde::{Deserialize, Serialize};
use time::OffsetDateTime;

use crate::model::{DisplayIdentity, SnapshotBlob};

const BACKUP_SCHEMA_VERSION: u32 = 1;
const AUTOMATIC_BACKUP_KEY_SERVICE: &str = "com.codexroster.app";
const AUTOMATIC_BACKUP_KEY_ACCOUNT: &str = "automatic-backup-key-v1";

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
        .read_to_end(&mut plaintext)
        .context("failed to read decrypted backup")?;
    let bundle: BackupBundle =
        serde_json::from_slice(&plaintext).context("backup contents are invalid")?;
    if bundle.schema_version != BACKUP_SCHEMA_VERSION {
        return Err(anyhow!(
            "backup schema version {} is not supported",
            bundle.schema_version
        ));
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
    let entry = keyring::Entry::new(AUTOMATIC_BACKUP_KEY_SERVICE, AUTOMATIC_BACKUP_KEY_ACCOUNT)
        .context("failed to access the automatic-backup key")?;
    match entry.get_password() {
        Ok(password) if !password.is_empty() => Ok(password),
        Ok(_) | Err(keyring::Error::NoEntry) => {
            let password = format!(
                "{}{}",
                uuid::Uuid::new_v4().simple(),
                uuid::Uuid::new_v4().simple()
            );
            entry
                .set_password(&password)
                .context("failed to store the automatic-backup key in Keychain")?;
            Ok(password)
        }
        Err(error) => Err(error).context("failed to read the automatic-backup key from Keychain"),
    }
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
