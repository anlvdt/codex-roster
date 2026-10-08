//! Desktop's web login is independent of CLI OAuth. Keep its encrypted OAuth
//! cache and only Claude authentication cookies in a separate local vault.
use std::{fs, io::Write, path::Path};

use anyhow::{Context, Result, bail, ensure};
use base64::{Engine, engine::general_purpose::STANDARD};
use rusqlite::{
    Connection, OpenFlags, params_from_iter,
    types::{Value, ValueRef},
};
use serde::{Deserialize, Serialize};
use serde_json::Map;
use uuid::Uuid;

use super::App;
use crate::{
    model::{AiProvider, EnvironmentKind, SNAPSHOT_SCHEMA_VERSION, SnapshotBlob, SnapshotFile},
    operation_lock::AuthLock,
    secrets::{LocalSecretStore, SecretStore},
};

const AUTH_KEYS: &[&str] = &[
    "lastKnownAccountUuid",
    "oauth:tokenCache",
    "oauth:tokenCacheV2",
];
const COOKIE_NAMES: &[&str] = &[
    "sessionKey",
    "sessionKeyV3",
    "sessionKeyLC",
    "sessionKeyV3LC",
    "lastActiveOrg",
    "__Host-ant_trusted_device",
    "routingHint",
];
const COOKIE_FILTER: &str = "host_key IN ('claude.ai', '.claude.ai') AND name IN ('sessionKey','sessionKeyV3','sessionKeyLC','sessionKeyV3LC','lastActiveOrg','__Host-ant_trusted_device','routingHint')";

#[derive(Serialize)]
pub struct DesktopLoginStatus {
    pub saved: bool,
    pub live_account_matches: bool,
}

#[derive(Serialize, Deserialize)]
struct DesktopProfile {
    account: Uuid,
    auth: Map<String, serde_json::Value>,
    columns: Vec<String>,
    cookies: Vec<Vec<Cell>>,
}

#[derive(Serialize, Deserialize)]
enum Cell {
    Null,
    Integer(i64),
    Real(f64),
    Text(String),
    Blob(String),
}

impl Cell {
    fn from_value(value: ValueRef<'_>) -> Result<Self> {
        Ok(match value {
            ValueRef::Null => Self::Null,
            ValueRef::Integer(v) => Self::Integer(v),
            ValueRef::Real(v) => Self::Real(v),
            ValueRef::Text(v) => Self::Text(std::str::from_utf8(v)?.to_owned()),
            ValueRef::Blob(v) => Self::Blob(STANDARD.encode(v)),
        })
    }
    fn sql_value(&self) -> Result<Value> {
        Ok(match self {
            Self::Null => Value::Null,
            Self::Integer(v) => Value::Integer(*v),
            Self::Real(v) => Value::Real(*v),
            Self::Text(v) => Value::Text(v.clone()),
            Self::Blob(v) => Value::Blob(STANDARD.decode(v)?),
        })
    }
    fn text(&self) -> Option<&str> {
        if let Self::Text(v) = self {
            Some(v)
        } else {
            None
        }
    }
}

fn config(root: &Path) -> Result<Map<String, serde_json::Value>> {
    for path in [
        root.to_path_buf(),
        root.join("config.json"),
        root.join("Cookies"),
    ] {
        ensure!(
            !fs::symlink_metadata(&path)?.file_type().is_symlink(),
            "Desktop login path is a symlink"
        );
    }
    Ok(serde_json::from_slice(&fs::read(
        root.join("config.json"),
    )?)?)
}

fn account_in(auth: &Map<String, serde_json::Value>) -> Option<Uuid> {
    auth.get("lastKnownAccountUuid")?.as_str()?.parse().ok()
}

fn capture(root: &Path, expected: Uuid) -> Result<DesktopProfile> {
    let live = config(root)?;
    ensure!(
        account_in(&live) == Some(expected),
        "Desktop is signed in to a different account. Sign in to this account in Desktop before saving its login."
    );
    let db = Connection::open_with_flags(root.join("Cookies"), OpenFlags::SQLITE_OPEN_READ_ONLY)?;
    db.busy_timeout(std::time::Duration::from_secs(2))?;
    let mut statement = db.prepare(&format!("SELECT * FROM cookies WHERE {COOKIE_FILTER}"))?;
    let columns = statement
        .column_names()
        .iter()
        .map(|s| s.to_string())
        .collect::<Vec<_>>();
    let mut rows = statement.query([])?;
    let mut cookies = Vec::new();
    while let Some(row) = rows.next()? {
        cookies.push(
            (0..columns.len())
                .map(|i| Cell::from_value(row.get_ref(i)?))
                .collect::<Result<Vec<_>>>()?,
        );
    }
    let auth = live
        .into_iter()
        .filter(|(key, _)| AUTH_KEYS.contains(&key.as_str()))
        .collect();
    let profile = DesktopProfile {
        account: expected,
        auth,
        columns,
        cookies,
    };
    validate(&profile, expected)?;
    Ok(profile)
}

fn validate(profile: &DesktopProfile, expected: Uuid) -> Result<()> {
    ensure!(
        profile.account == expected && account_in(&profile.auth) == Some(expected),
        "Saved Desktop login identity does not match the selected account"
    );
    ensure!(
        profile.auth.keys().all(|k| AUTH_KEYS.contains(&k.as_str())),
        "Unexpected Desktop auth field"
    );
    ensure!(
        ["oauth:tokenCache", "oauth:tokenCacheV2"]
            .iter()
            .any(|key| profile
                .auth
                .get(*key)
                .and_then(|v| v.as_str())
                .is_some_and(|s| !s.is_empty())),
        "Desktop OAuth cache is missing; sign in and save again"
    );
    let host = profile
        .columns
        .iter()
        .position(|c| c == "host_key")
        .context("Cookie host column missing")?;
    let name = profile
        .columns
        .iter()
        .position(|c| c == "name")
        .context("Cookie name column missing")?;
    ensure!(
        !profile.cookies.is_empty(),
        "Desktop login cookies are missing; sign in and save again"
    );
    ensure!(
        profile.cookies.iter().any(|r| r
            .get(name)
            .and_then(Cell::text)
            .is_some_and(|s| s == "sessionKey" || s == "sessionKeyV3")),
        "Desktop session cookie is missing; sign in and save again"
    );
    for row in &profile.cookies {
        ensure!(row.len() == profile.columns.len(), "Invalid cookie row");
        ensure!(
            matches!(row[host].text(), Some("claude.ai" | ".claude.ai")),
            "Unexpected cookie domain"
        );
        ensure!(
            row[name].text().is_some_and(|s| COOKIE_NAMES.contains(&s)),
            "Unexpected cookie name"
        );
    }
    Ok(())
}

fn write_config(path: &Path, data: &[u8]) -> Result<()> {
    crate::file_store::replace_file_with_recovery(path, None, |temporary| {
        let mut options = fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options.open(temporary)?;
        file.write_all(data)?;
        file.sync_all()?;
        Ok(())
    })
}

fn restore(root: &Path, profile: &DesktopProfile, expected: Uuid) -> Result<()> {
    validate(profile, expected)?;
    let mut live = config(root)?;
    let original = serde_json::to_vec(&live)?;
    for key in AUTH_KEYS {
        live.remove(*key);
    }
    live.extend(profile.auth.clone());
    let mut db =
        Connection::open_with_flags(root.join("Cookies"), OpenFlags::SQLITE_OPEN_READ_WRITE)?;
    db.busy_timeout(std::time::Duration::from_secs(2))?;
    let columns = {
        let statement = db.prepare("SELECT * FROM cookies LIMIT 0")?;
        statement
            .column_names()
            .iter()
            .map(|s| s.to_string())
            .collect::<Vec<_>>()
    };
    ensure!(
        columns == profile.columns,
        "Desktop cookie schema changed; sign in and save this login again"
    );
    let names = columns
        .iter()
        .map(|s| format!("\"{}\"", s.replace('"', "\"\"")))
        .collect::<Vec<_>>()
        .join(",");
    let placeholders = vec!["?"; columns.len()].join(",");
    let transaction = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
    transaction.execute(&format!("DELETE FROM cookies WHERE {COOKIE_FILTER}"), [])?;
    for row in &profile.cookies {
        let values = row
            .iter()
            .map(Cell::sql_value)
            .collect::<Result<Vec<_>>>()?;
        transaction.execute(
            &format!("INSERT INTO cookies ({names}) VALUES ({placeholders})"),
            params_from_iter(values),
        )?;
    }
    if let Err(error) = write_config(
        &root.join("config.json"),
        &serde_json::to_vec_pretty(&live)?,
    ) {
        write_config(&root.join("config.json"), &original)
            .context("Desktop config write failed and rollback failed")?;
        return Err(error);
    }
    if let Err(error) = transaction.commit() {
        write_config(&root.join("config.json"), &original)
            .context("Desktop cookie commit failed and config rollback failed")?;
        return Err(error.into());
    }
    Ok(())
}

fn vault_save(store: &impl SecretStore, key: &str, profile: &DesktopProfile) -> Result<()> {
    let snapshot = SnapshotBlob {
        schema_version: SNAPSHOT_SCHEMA_VERSION,
        files: vec![SnapshotFile {
            name: "claude_desktop_login.json".to_owned(),
            bytes_base64: STANDARD.encode(serde_json::to_vec(profile)?),
        }],
    };
    let data = serde_json::to_vec(&snapshot)?;
    ensure!(
        data.len() < 4 * 1024 * 1024,
        "Desktop login snapshot is too large"
    );
    store.save(key, &data)
}

fn vault_load(
    store: &impl SecretStore,
    key: &str,
    account: Uuid,
) -> Result<Option<DesktopProfile>> {
    let Some(data) = store.load(key)? else {
        return Ok(None);
    };
    let snapshot: SnapshotBlob = serde_json::from_slice(&data)?;
    ensure!(
        snapshot.schema_version == SNAPSHOT_SCHEMA_VERSION
            && snapshot.files.len() == 1
            && snapshot.files[0].name == "claude_desktop_login.json",
        "Invalid Desktop login snapshot"
    );
    let profile: DesktopProfile =
        serde_json::from_slice(&STANDARD.decode(&snapshot.files[0].bytes_base64)?)?;
    validate(&profile, account)?;
    Ok(Some(profile))
}

fn ensure_desktop_closed() -> Result<()> {
    let system = sysinfo::System::new_all();
    ensure!(
        !system.processes().values().any(|p| p.name() == "Claude"
            || p.exe().is_some_and(|path| path
                .to_string_lossy()
                .contains("/Claude.app/Contents/MacOS/"))),
        "Quit Claude Desktop before saving or restoring its login"
    );
    Ok(())
}

fn restore_same_account_login(
    root: &Path,
    vault: &impl SecretStore,
    key: &str,
    target: &DesktopProfile,
) -> Result<()> {
    match capture(root, target.account) {
        // A healthy live login may have rotated since the snapshot was saved.
        Ok(live) => vault_save(vault, key, &live),
        // Missing live auth must not block recovery or replace the saved login.
        Err(_) => restore(root, target, target.account),
    }
}

impl<S: SecretStore> App<S> {
    pub fn claude_desktop_login(
        &self,
        account_id: Uuid,
        action: &str,
    ) -> Result<DesktopLoginStatus> {
        ensure!(
            self.env.kind == EnvironmentKind::Macos,
            "Desktop login switching is currently supported on macOS only"
        );
        let store = self.provider_store();
        let (account, _) = store.load_snapshot(&self.env.kind, account_id)?;
        ensure!(
            account.provider == AiProvider::Claude,
            "Select a saved Claude account"
        );
        let uuid: Uuid = account
            .identity
            .subject
            .as_deref()
            .context("Claude account UUID is missing; sign in and save it again")?
            .parse()?;
        let root = self.env.home_dir.join("Library/Application Support/Claude");
        let vault = LocalSecretStore::new(&self.env.app_data_dir.join("claude-desktop-logins"));
        let key = account_id.to_string();
        if action == "status" {
            return Ok(DesktopLoginStatus {
                saved: vault_load(&vault, &key, uuid)?.is_some(),
                live_account_matches: config(&root).ok().and_then(|c| account_in(&c)) == Some(uuid),
            });
        }
        let _lock = AuthLock::acquire(&self.env.app_data_dir)?;
        ensure_desktop_closed()?;
        match action {
            "save" => vault_save(&vault, &key, &capture(&root, uuid)?)?,
            "restore" => {
                let target = vault_load(&vault, &key, uuid)?.context("Desktop login has not been saved for this account. Sign in to it in Desktop and use Save Desktop login once.")?;
                // Preserve the previous Desktop login even when CLI and Desktop
                // currently use different accounts.
                if let Some(live) = config(&root).ok().and_then(|c| account_in(&c)) {
                    if live == uuid {
                        restore_same_account_login(&root, &vault, &key, &target)?;
                        return Ok(DesktopLoginStatus {
                            saved: true,
                            live_account_matches: true,
                        });
                    }
                    for saved in store.list(&self.env.kind, Some(AiProvider::Claude))? {
                        if saved
                            .identity
                            .subject
                            .as_deref()
                            .and_then(|s| s.parse::<Uuid>().ok())
                            == Some(live)
                        {
                            vault_save(&vault, &saved.id.to_string(), &capture(&root, live)?)?;
                            break;
                        }
                    }
                }
                restore(&root, &target, uuid)?;
            }
            _ => bail!("Unknown Desktop login action"),
        }
        Ok(DesktopLoginStatus {
            saved: true,
            live_account_matches: true,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(root: &Path, account: Uuid, token: &str) {
        fs::create_dir_all(root).unwrap();
        fs::write(
            root.join("config.json"),
            serde_json::to_vec(&serde_json::json!({
                "lastKnownAccountUuid": account, "oauth:tokenCache": token,
                "theme": "dark", "projectSetting": {"trusted": true}
            }))
            .unwrap(),
        )
        .unwrap();
        let db = Connection::open(root.join("Cookies")).unwrap();
        db.execute_batch("CREATE TABLE cookies (host_key TEXT, name TEXT, encrypted_value BLOB, expires_utc INTEGER, UNIQUE(host_key,name));
            INSERT INTO cookies VALUES ('example.com','sessionKey',X'FF',1);
            INSERT INTO cookies VALUES ('.claude.ai','unrelated',X'FE',2);").unwrap();
        db.execute(
            "INSERT INTO cookies VALUES ('.claude.ai','sessionKey',?1,99)",
            [token.as_bytes()],
        )
        .unwrap();
        fs::create_dir_all(root.join("claude-code-sessions")).unwrap();
        fs::write(
            root.join("claude-code-sessions/history.json"),
            b"keep conversation",
        )
        .unwrap();
    }

    #[test]
    fn restores_only_auth_and_keeps_settings_other_cookies_and_code_history() {
        let directory = tempfile::tempdir().unwrap();
        let target = directory.path().join("target");
        let live = directory.path().join("live");
        let id = Uuid::new_v4();
        fixture(&target, id, "new-login");
        fixture(&live, Uuid::new_v4(), "old-login");
        let profile = capture(&target, id).unwrap();
        assert_eq!(profile.cookies.len(), 1);
        restore(&live, &profile, id).unwrap();
        let config = config(&live).unwrap();
        assert_eq!(account_in(&config), Some(id));
        assert_eq!(config["oauth:tokenCache"], "new-login");
        assert_eq!(config["theme"], "dark");
        let db = Connection::open(live.join("Cookies")).unwrap();
        let bytes: Vec<u8> = db.query_row("SELECT encrypted_value FROM cookies WHERE name='sessionKey' AND host_key='.claude.ai'", [], |r| r.get(0)).unwrap();
        assert_eq!(bytes, b"new-login");
        let count: i64 = db
            .query_row("SELECT COUNT(*) FROM cookies", [], |r| r.get(0))
            .unwrap();
        assert_eq!(count, 3);
        assert_eq!(
            fs::read(live.join("claude-code-sessions/history.json")).unwrap(),
            b"keep conversation"
        );
    }

    #[test]
    fn wrong_identity_and_changed_schema_are_refused_without_modifying_login() {
        let directory = tempfile::tempdir().unwrap();
        let id = Uuid::new_v4();
        fixture(directory.path(), id, "login");
        let profile = capture(directory.path(), id).unwrap();
        let before = fs::read(directory.path().join("config.json")).unwrap();
        assert!(capture(directory.path(), Uuid::new_v4()).is_err());
        assert!(restore(directory.path(), &profile, Uuid::new_v4()).is_err());
        let db = Connection::open(directory.path().join("Cookies")).unwrap();
        db.execute_batch("ALTER TABLE cookies ADD COLUMN changed TEXT")
            .unwrap();
        assert!(restore(directory.path(), &profile, id).is_err());
        assert_eq!(
            before,
            fs::read(directory.path().join("config.json")).unwrap()
        );
    }

    #[test]
    fn insertion_failure_rolls_back_cookie_deletion_and_leaves_config_untouched() {
        let directory = tempfile::tempdir().unwrap();
        let id = Uuid::new_v4();
        fixture(directory.path(), id, "login");
        let mut profile = capture(directory.path(), id).unwrap();
        profile.cookies.push(vec![
            Cell::Text(".claude.ai".into()),
            Cell::Text("sessionKey".into()),
            Cell::Blob(STANDARD.encode(b"duplicate")),
            Cell::Integer(99),
        ]);
        let before = fs::read(directory.path().join("config.json")).unwrap();
        assert!(restore(directory.path(), &profile, id).is_err());
        assert_eq!(
            before,
            fs::read(directory.path().join("config.json")).unwrap()
        );
        let db = Connection::open(directory.path().join("Cookies")).unwrap();
        let bytes: Vec<u8> = db.query_row("SELECT encrypted_value FROM cookies WHERE name='sessionKey' AND host_key='.claude.ai'", [], |r| r.get(0)).unwrap();
        assert_eq!(bytes, b"login");
    }

    #[test]
    fn desktop_vault_encrypts_and_rejects_other_account() {
        let directory = tempfile::tempdir().unwrap();
        let root = directory.path().join("desktop");
        let id = Uuid::new_v4();
        fixture(&root, id, "unique-private-login-marker");
        let profile = capture(&root, id).unwrap();
        let store = LocalSecretStore::new(&directory.path().join("vault"));
        vault_save(&store, "account", &profile).unwrap();
        assert!(vault_load(&store, "account", id).unwrap().is_some());
        assert!(vault_load(&store, "account", Uuid::new_v4()).is_err());
        for entry in fs::read_dir(directory.path().join("vault")).unwrap() {
            let bytes = fs::read(entry.unwrap().path()).unwrap();
            assert!(!String::from_utf8_lossy(&bytes).contains("unique-private-login-marker"));
        }
    }

    #[test]
    fn same_account_restore_recovers_missing_auth_without_overwriting_saved_login() {
        for missing in ["cookies", "oauth_cache"] {
            let directory = tempfile::tempdir().unwrap();
            let root = directory.path().join("desktop");
            let id = Uuid::new_v4();
            fixture(&root, id, "saved-login");
            let store = crate::secrets::test_support::MemorySecretStore::default();
            vault_save(&store, "account", &capture(&root, id).unwrap()).unwrap();
            let saved = store.load("account").unwrap().unwrap();
            let target = vault_load(&store, "account", id).unwrap().unwrap();
            if missing == "cookies" {
                Connection::open(root.join("Cookies"))
                    .unwrap()
                    .execute(&format!("DELETE FROM cookies WHERE {COOKIE_FILTER}"), [])
                    .unwrap();
            } else {
                let mut live = config(&root).unwrap();
                live.remove("oauth:tokenCache");
                fs::write(root.join("config.json"), serde_json::to_vec(&live).unwrap()).unwrap();
            }
            assert!(capture(&root, id).is_err());
            restore_same_account_login(&root, &store, "account", &target).unwrap();
            assert_eq!(config(&root).unwrap()["oauth:tokenCache"], "saved-login");
            let db = Connection::open(root.join("Cookies")).unwrap();
            let cookie: Vec<u8> = db
                .query_row("SELECT encrypted_value FROM cookies WHERE host_key='.claude.ai' AND name='sessionKey'", [], |row| row.get(0))
                .unwrap();
            assert_eq!(cookie, b"saved-login");
            assert_eq!(store.load("account").unwrap().unwrap(), saved);
        }
    }

    #[test]
    fn same_account_restore_preserves_and_saves_rotated_healthy_login() {
        let directory = tempfile::tempdir().unwrap();
        let root = directory.path().join("desktop");
        let id = Uuid::new_v4();
        fixture(&root, id, "saved-login");
        let store = crate::secrets::test_support::MemorySecretStore::default();
        vault_save(&store, "account", &capture(&root, id).unwrap()).unwrap();
        let target = vault_load(&store, "account", id).unwrap().unwrap();
        let mut live = config(&root).unwrap();
        live.insert("oauth:tokenCache".into(), "rotated-login".into());
        fs::write(root.join("config.json"), serde_json::to_vec(&live).unwrap()).unwrap();
        Connection::open(root.join("Cookies"))
            .unwrap()
            .execute("UPDATE cookies SET encrypted_value=?1 WHERE host_key='.claude.ai' AND name='sessionKey'", [b"rotated-login".as_slice()])
            .unwrap();
        restore_same_account_login(&root, &store, "account", &target).unwrap();
        assert_eq!(config(&root).unwrap()["oauth:tokenCache"], "rotated-login");
        let saved = vault_load(&store, "account", id).unwrap().unwrap();
        assert_eq!(saved.auth["oauth:tokenCache"], "rotated-login");
        assert_eq!(
            saved.cookies[0][2].sql_value().unwrap(),
            Value::Blob(b"rotated-login".to_vec())
        );
    }
}
