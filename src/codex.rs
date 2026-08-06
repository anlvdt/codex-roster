use std::fs;
use std::path::Path;
use std::time::Duration;

use anyhow::{Context, Result, bail};
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
#[cfg(test)]
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use uuid::Uuid;

use crate::env::AppEnv;
use crate::identity::parse_identity_from_auth_json;
use crate::model::{
    AUTH_FILES, DisplayIdentity, SNAPSHOT_SCHEMA_VERSION, SnapshotBlob, SnapshotFile,
};

const MAX_AUTH_FILE_BYTES: usize = 1024 * 1024;
const MAX_AUTH_FILE_BASE64_BYTES: usize = (MAX_AUTH_FILE_BYTES * 4).div_ceil(3);

#[derive(Clone, Debug)]
pub struct LiveAuthBundle {
    pub identity: DisplayIdentity,
    pub snapshot: SnapshotBlob,
}

pub fn try_read_live_auth_bundle(env: &AppEnv) -> Result<Option<LiveAuthBundle>> {
    let auth_json_path = env.codex_root.join("auth.json");
    if !auth_json_path.exists() {
        return Ok(None);
    }
    read_live_auth_bundle(env).map(Some)
}

pub fn read_live_auth_bundle(env: &AppEnv) -> Result<LiveAuthBundle> {
    let mut files = Vec::with_capacity(AUTH_FILES.len());
    let mut auth_json_bytes = None;
    for file_name in AUTH_FILES {
        let path = env.codex_root.join(file_name);
        let bytes = match fs::read(&path) {
            Ok(bytes) => bytes,
            // Newer Codex installs can use auth.json without a cap_sid file. Keep
            // a stable, restorable snapshot by representing the optional file as
            // empty; restore will recreate it when needed.
            Err(error)
                if file_name == "cap_sid" && error.kind() == std::io::ErrorKind::NotFound =>
            {
                Vec::new()
            }
            Err(error) => {
                return Err(error).with_context(|| format!("failed to read {}", path.display()));
            }
        };
        if file_name == "auth.json" {
            auth_json_bytes = Some(bytes.clone());
        }
        files.push(SnapshotFile {
            name: file_name.to_owned(),
            bytes_base64: STANDARD.encode(bytes),
        });
    }
    let auth_json_bytes = auth_json_bytes.context("auth.json missing from live auth bundle")?;
    let identity = parse_identity_from_auth_json(&auth_json_bytes)?;
    Ok(LiveAuthBundle {
        identity,
        snapshot: SnapshotBlob {
            schema_version: SNAPSHOT_SCHEMA_VERSION,
            files,
        },
    })
}

const ADD_ACCOUNT_AUTH_BACKUP: &str = "auth.json.roster-add-bak";
const ADD_ACCOUNT_CAP_BACKUP: &str = "cap_sid.roster-add-bak";
const ADD_ACCOUNT_MARKER: &str = ".roster-add-account";

pub fn add_account_session_active(env: &AppEnv) -> bool {
    env.codex_root.join(ADD_ACCOUNT_MARKER).exists()
}

/// Preserve the current session before starting a new device login.
///
/// Keep the live files in place while the login starts, matching the legacy
/// behavior. This lets Codex/OpenAI reuse a trusted local session when it can,
/// while the backups below still make cancelling safe if the login replaces it.
pub fn begin_add_account_session(env: &AppEnv) -> Result<()> {
    if add_account_session_active(env) {
        bail!("an add-account session is already in progress; save it or cancel it first");
    }
    fs::create_dir_all(&env.codex_root)
        .with_context(|| format!("failed to create {}", env.codex_root.display()))?;
    let auth = env.codex_root.join("auth.json");
    let cap_sid = env.codex_root.join("cap_sid");
    let backup_auth = env.codex_root.join(ADD_ACCOUNT_AUTH_BACKUP);
    let backup_sid = env.codex_root.join(ADD_ACCOUNT_CAP_BACKUP);
    if auth.exists() {
        fs::copy(&auth, &backup_auth).with_context(|| {
            format!(
                "failed to back up {} to {}",
                auth.display(),
                backup_auth.display()
            )
        })?;
        if cap_sid.exists() {
            fs::copy(&cap_sid, &backup_sid).with_context(|| {
                format!(
                    "failed to back up {} to {}",
                    cap_sid.display(),
                    backup_sid.display()
                )
            })?;
        }
    }
    fs::write(env.codex_root.join(ADD_ACCOUNT_MARKER), b"pending").with_context(|| {
        format!(
            "failed to start add-account session in {}",
            env.codex_root.display()
        )
    })?;
    Ok(())
}

pub fn finish_add_account_session(env: &AppEnv) -> Result<()> {
    if !add_account_session_active(env) {
        bail!("no add-account session is in progress");
    }
    ensure_cap_sid_exists(env)?;
    clear_add_account_artifacts(env);
    Ok(())
}

/// Cancel an unfinished login and put the previous live Codex session back.
pub fn cancel_add_account_session(env: &AppEnv) -> Result<()> {
    if !add_account_session_active(env) {
        return Ok(());
    }
    let auth = env.codex_root.join("auth.json");
    let cap_sid = env.codex_root.join("cap_sid");
    let backup_auth = env.codex_root.join(ADD_ACCOUNT_AUTH_BACKUP);
    let backup_sid = env.codex_root.join(ADD_ACCOUNT_CAP_BACKUP);
    if backup_auth.exists() {
        fs::copy(&backup_auth, &auth).with_context(|| {
            format!(
                "failed to restore {} from {}",
                auth.display(),
                backup_auth.display()
            )
        })?;
        if backup_sid.exists() {
            fs::copy(&backup_sid, &cap_sid).with_context(|| {
                format!(
                    "failed to restore {} from {}",
                    cap_sid.display(),
                    backup_sid.display()
                )
            })?;
        } else {
            remove_file_if_exists(&cap_sid)?;
        }
    }
    clear_add_account_artifacts(env);
    Ok(())
}

fn ensure_cap_sid_exists(env: &AppEnv) -> Result<()> {
    let path = env.codex_root.join("cap_sid");
    if !path.exists() {
        fs::write(&path, b"").with_context(|| format!("failed to create {}", path.display()))?;
    }
    Ok(())
}

fn clear_add_account_artifacts(env: &AppEnv) {
    for file_name in [
        ADD_ACCOUNT_AUTH_BACKUP,
        ADD_ACCOUNT_CAP_BACKUP,
        ADD_ACCOUNT_MARKER,
    ] {
        let _ = fs::remove_file(env.codex_root.join(file_name));
    }
}

fn remove_file_if_exists(path: &Path) -> Result<()> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error).with_context(|| format!("failed to remove {}", path.display())),
    }
}

pub fn identity_from_snapshot(snapshot: &SnapshotBlob) -> Result<DisplayIdentity> {
    validate_snapshot(snapshot)?;
    let auth_file = snapshot
        .files
        .iter()
        .find(|file| file.name == "auth.json")
        .context("snapshot missing auth.json")?;
    let auth_json_bytes = STANDARD
        .decode(&auth_file.bytes_base64)
        .context("failed to decode snapshot auth.json")?;
    parse_identity_from_auth_json(&auth_json_bytes)
}

/// Build a managed snapshot from a Codex `auth.json` document (plus empty `cap_sid`).
pub fn snapshot_from_auth_json(auth_json_bytes: &[u8]) -> Result<(DisplayIdentity, SnapshotBlob)> {
    let root: serde_json::Value =
        serde_json::from_slice(auth_json_bytes).context("failed to parse auth.json")?;
    let tokens = root
        .get("tokens")
        .and_then(|value| value.as_object())
        .context("auth.json must contain a tokens object")?;
    if tokens
        .get("access_token")
        .and_then(|value| value.as_str())
        .is_none_or(str::is_empty)
    {
        bail!("auth.json is missing tokens.access_token");
    }
    if tokens
        .get("refresh_token")
        .and_then(|value| value.as_str())
        .is_none_or(str::is_empty)
    {
        bail!("auth.json is missing tokens.refresh_token");
    }
    let identity = parse_identity_from_auth_json(auth_json_bytes)?;
    let snapshot = SnapshotBlob {
        schema_version: SNAPSHOT_SCHEMA_VERSION,
        files: vec![
            SnapshotFile {
                name: "auth.json".to_owned(),
                bytes_base64: STANDARD.encode(auth_json_bytes),
            },
            SnapshotFile {
                name: "cap_sid".to_owned(),
                bytes_base64: STANDARD.encode([]),
            },
        ],
    };
    validate_snapshot(&snapshot)?;
    Ok((identity, snapshot))
}

pub fn restore_snapshot(
    env: &AppEnv,
    snapshot: &SnapshotBlob,
    expected_identity: &DisplayIdentity,
    verify_stable: bool,
) -> Result<()> {
    restore_snapshot_with_retry(
        env,
        snapshot,
        expected_identity,
        verify_stable,
        4,
        Duration::from_millis(250),
    )
}

pub fn restore_snapshot_with_retry(
    env: &AppEnv,
    snapshot: &SnapshotBlob,
    expected_identity: &DisplayIdentity,
    verify_stable: bool,
    stable_attempts: usize,
    stable_delay: Duration,
) -> Result<()> {
    validate_snapshot(snapshot)?;
    fs::create_dir_all(&env.codex_root)
        .with_context(|| format!("failed to create {}", env.codex_root.display()))?;
    let backup_dir = env
        .codex_root
        .join(format!(".cas-backup-{}", Uuid::new_v4()));
    let temp_dir = env
        .codex_root
        .join(format!(".cas-restore-{}", Uuid::new_v4()));
    create_private_directory(&backup_dir)?;
    create_private_directory(&temp_dir)?;

    if let Err(error) = stage_and_restore(&env.codex_root, &backup_dir, &temp_dir, snapshot) {
        let _ = restore_from_backup(&env.codex_root, &backup_dir);
        let _ = fs::remove_dir_all(&temp_dir);
        let _ = fs::remove_dir_all(&backup_dir);
        return Err(error);
    }

    if let Err(error) = verify_live_snapshot_once(env, snapshot, expected_identity) {
        let _ = restore_from_backup(&env.codex_root, &backup_dir);
        let _ = fs::remove_dir_all(&temp_dir);
        let _ = fs::remove_dir_all(&backup_dir);
        return Err(error);
    }

    if verify_stable
        && let Err(error) = verify_live_snapshot_stable_with_retry(
            env,
            snapshot,
            expected_identity,
            stable_attempts,
            stable_delay,
        )
    {
        let _ = restore_from_backup(&env.codex_root, &backup_dir);
        let _ = fs::remove_dir_all(&temp_dir);
        let _ = fs::remove_dir_all(&backup_dir);
        return Err(error);
    }

    let _ = fs::remove_dir_all(&temp_dir);
    let _ = fs::remove_dir_all(&backup_dir);
    Ok(())
}

pub fn live_bundle_matches_snapshot(env: &AppEnv, snapshot: &SnapshotBlob) -> Result<bool> {
    let Some(live) = try_read_live_auth_bundle(env)? else {
        return Ok(false);
    };
    Ok(snapshot_matches(&live.snapshot, snapshot))
}

pub fn verify_live_snapshot_stable(
    env: &AppEnv,
    expected_snapshot: &SnapshotBlob,
    expected_identity: &DisplayIdentity,
) -> Result<()> {
    verify_live_snapshot_stable_with_retry(
        env,
        expected_snapshot,
        expected_identity,
        4,
        Duration::from_millis(250),
    )
}

pub fn validate_snapshot(snapshot: &SnapshotBlob) -> Result<()> {
    if snapshot.schema_version != SNAPSHOT_SCHEMA_VERSION {
        bail!(
            "unsupported snapshot schema version {}; expected {}",
            snapshot.schema_version,
            SNAPSHOT_SCHEMA_VERSION
        );
    }
    if snapshot.files.len() != AUTH_FILES.len() {
        bail!("snapshot must contain exactly the managed auth files");
    }
    for file_name in AUTH_FILES {
        let matches = snapshot
            .files
            .iter()
            .filter(|file| file.name == file_name)
            .collect::<Vec<_>>();
        if matches.len() != 1 {
            bail!("snapshot must contain exactly one {file_name}");
        }
        if matches[0].bytes_base64.len() > MAX_AUTH_FILE_BASE64_BYTES {
            bail!("snapshot file {file_name} exceeds the allowed size");
        }
        let decoded = STANDARD
            .decode(&matches[0].bytes_base64)
            .with_context(|| format!("failed to decode snapshot file {file_name}"))?;
        if decoded.len() > MAX_AUTH_FILE_BYTES {
            bail!("snapshot file {file_name} exceeds the allowed size");
        }
    }
    if let Some(unmanaged) = snapshot.files.iter().find(|file| {
        !AUTH_FILES
            .iter()
            .any(|managed_name| *managed_name == file.name)
    }) {
        bail!("snapshot contains unmanaged file {:?}", unmanaged.name);
    }
    Ok(())
}

fn stage_and_restore(
    codex_root: &Path,
    backup_dir: &Path,
    temp_dir: &Path,
    snapshot: &SnapshotBlob,
) -> Result<()> {
    for file in &snapshot.files {
        let decoded = STANDARD
            .decode(&file.bytes_base64)
            .with_context(|| format!("failed to decode snapshot file {}", file.name))?;
        let temp_path = temp_dir.join(&file.name);
        write_private_staged_file(&temp_path, &decoded)?;
    }

    for file_name in AUTH_FILES {
        let live_path = codex_root.join(file_name);
        if live_path.exists() {
            let backup_path = backup_dir.join(file_name);
            fs::copy(&live_path, &backup_path).with_context(|| {
                format!(
                    "failed to back up {} to {}",
                    live_path.display(),
                    backup_path.display()
                )
            })?;
            set_private_file_permissions(&backup_path)?;
            fs::remove_file(&live_path)
                .with_context(|| format!("failed to remove {}", live_path.display()))?;
        }
        let staged_path = temp_dir.join(file_name);
        fs::copy(&staged_path, &live_path).with_context(|| {
            format!(
                "failed to restore {} from {}",
                live_path.display(),
                staged_path.display()
            )
        })?;
    }
    Ok(())
}

fn create_private_directory(path: &Path) -> Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(path)
            .with_context(|| format!("failed to create {}", path.display()))?;
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o700))
            .with_context(|| format!("failed to protect {}", path.display()))?;
    }
    #[cfg(not(unix))]
    fs::create_dir_all(path).with_context(|| format!("failed to create {}", path.display()))?;
    Ok(())
}

fn write_private_staged_file(path: &Path, bytes: &[u8]) -> Result<()> {
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
            .with_context(|| format!("failed to stage {}", path.display()))?;
        file.write_all(bytes)
            .with_context(|| format!("failed to stage {}", path.display()))?;
    }
    #[cfg(not(unix))]
    fs::write(path, bytes).with_context(|| format!("failed to stage {}", path.display()))?;
    Ok(())
}

fn set_private_file_permissions(path: &Path) -> Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o600))
            .with_context(|| format!("failed to protect {}", path.display()))?;
    }
    #[cfg(not(unix))]
    let _ = path;
    Ok(())
}

fn restore_from_backup(codex_root: &Path, backup_dir: &Path) -> Result<()> {
    for file_name in AUTH_FILES {
        let backup_path = backup_dir.join(file_name);
        let live_path = codex_root.join(file_name);
        if backup_path.exists() {
            if live_path.exists() {
                fs::remove_file(&live_path)
                    .with_context(|| format!("failed to remove {}", live_path.display()))?;
            }
            fs::copy(&backup_path, &live_path).with_context(|| {
                format!(
                    "failed to restore backup {} to {}",
                    backup_path.display(),
                    live_path.display()
                )
            })?;
        } else if live_path.exists() {
            fs::remove_file(&live_path).with_context(|| {
                format!("failed to remove newly restored {}", live_path.display())
            })?;
        }
    }
    Ok(())
}

fn verify_live_snapshot_stable_with_retry(
    env: &AppEnv,
    expected_snapshot: &SnapshotBlob,
    expected_identity: &DisplayIdentity,
    polls: usize,
    delay: Duration,
) -> Result<()> {
    verify_live_snapshot_once(env, expected_snapshot, expected_identity)?;
    for _ in 0..polls {
        std::thread::sleep(delay);
        verify_live_snapshot_once(env, expected_snapshot, expected_identity)
            .context("restored auth bundle changed again after activation")?;
    }
    Ok(())
}

fn verify_live_snapshot_once(
    env: &AppEnv,
    expected_snapshot: &SnapshotBlob,
    expected_identity: &DisplayIdentity,
) -> Result<()> {
    let live = read_live_auth_bundle(env).context("failed to verify restored auth bundle")?;
    if !snapshot_matches(&live.snapshot, expected_snapshot) {
        bail!(
            "restore verification failed: managed auth files no longer match the restored snapshot"
        );
    }
    if !live.identity.matches(expected_identity) {
        bail!(
            "restore verification failed: expected {:?}, got {:?}",
            expected_identity,
            live.identity
        );
    }
    Ok(())
}

fn snapshot_matches(left: &SnapshotBlob, right: &SnapshotBlob) -> bool {
    left.schema_version == right.schema_version
        && AUTH_FILES.iter().all(|file_name| {
            let left_files = snapshot_files(left, file_name);
            let right_files = snapshot_files(right, file_name);
            left_files.len() == 1 && right_files.len() == 1 && left_files[0] == right_files[0]
        })
}

fn snapshot_files<'a>(snapshot: &'a SnapshotBlob, file_name: &str) -> Vec<&'a str> {
    snapshot
        .files
        .iter()
        .filter(|file| file.name == file_name)
        .map(|file| file.bytes_base64.as_str())
        .collect()
}

#[cfg(test)]
pub fn auth_json_fixture(email: &str, subject: &str, plan: Option<&str>) -> String {
    let payload = serde_json::json!({
        "email": email,
        "sub": subject,
        "name": "Tester",
        "https://api.openai.com/auth": {
            "chatgpt_plan_type": plan
        }
    });
    let header = URL_SAFE_NO_PAD.encode(r#"{"alg":"none"}"#);
    let payload = URL_SAFE_NO_PAD.encode(payload.to_string());
    serde_json::json!({
        "tokens": {
            "id_token": format!("{header}.{payload}."),
            "access_token": "access",
            "refresh_token": "refresh",
            "account_id": "acct"
        },
        "auth_mode": "chatgpt"
    })
    .to_string()
}

#[cfg(test)]
mod tests {
    use anyhow::Result;
    use tempfile::tempdir;

    use super::*;
    use crate::model::EnvironmentKind;

    #[test]
    fn reads_bundle_and_restores_it() -> Result<()> {
        let temp = tempdir()?;
        let codex_root = temp.path().join(".codex");
        fs::create_dir_all(&codex_root)?;
        fs::write(
            codex_root.join("auth.json"),
            auth_json_fixture("person@example.com", "sub-1", Some("pro")),
        )?;
        fs::write(codex_root.join("cap_sid"), "sid-1")?;
        let env = AppEnv {
            kind: EnvironmentKind::Linux,
            home_dir: temp.path().to_path_buf(),
            codex_root: codex_root.clone(),
            app_data_dir: temp.path().join("data"),
        };
        let bundle = read_live_auth_bundle(&env)?;
        fs::write(
            codex_root.join("auth.json"),
            auth_json_fixture("other@example.com", "sub-2", Some("plus")),
        )?;
        fs::write(codex_root.join("cap_sid"), "sid-2")?;
        restore_snapshot(&env, &bundle.snapshot, &bundle.identity, false)?;
        let restored = read_live_auth_bundle(&env)?;
        assert_eq!(restored.identity.email, "person@example.com");
        Ok(())
    }

    #[test]
    fn reads_bundle_when_cap_sid_is_absent() -> Result<()> {
        let temp = tempdir()?;
        let codex_root = temp.path().join(".codex");
        fs::create_dir_all(&codex_root)?;
        fs::write(
            codex_root.join("auth.json"),
            auth_json_fixture("person@example.com", "sub-1", Some("pro")),
        )?;
        let env = AppEnv {
            kind: EnvironmentKind::Linux,
            home_dir: temp.path().to_path_buf(),
            codex_root,
            app_data_dir: temp.path().join("data"),
        };

        let bundle = read_live_auth_bundle(&env)?;

        assert_eq!(bundle.identity.email, "person@example.com");
        let empty_cap_sid = STANDARD.encode(b"");
        assert_eq!(
            snapshot_files(&bundle.snapshot, "cap_sid"),
            vec![empty_cap_sid.as_str()]
        );
        Ok(())
    }

    #[test]
    fn snapshot_from_auth_json_builds_a_valid_managed_snapshot() -> Result<()> {
        let auth = auth_json_fixture("import@example.com", "sub-import", Some("plus"));
        let (identity, snapshot) = snapshot_from_auth_json(auth.as_bytes())?;
        assert_eq!(identity.email, "import@example.com");
        assert_eq!(identity.subject.as_deref(), Some("sub-import"));
        validate_snapshot(&snapshot)?;
        assert_eq!(identity_from_snapshot(&snapshot)?.email, "import@example.com");
        Ok(())
    }

    #[test]
    fn snapshot_from_auth_json_requires_refresh_token() {
        let auth = r#"{"tokens":{"id_token":"x.y.z","access_token":"access","account_id":"acct"},"auth_mode":"chatgpt"}"#;
        let error = snapshot_from_auth_json(auth.as_bytes()).expect_err("missing refresh");
        assert!(format!("{error:#}").contains("refresh_token"));
    }

    #[test]
    fn cancelling_add_account_restores_the_previous_live_session() -> Result<()> {
        let temp = tempdir()?;
        let codex_root = temp.path().join(".codex");
        fs::create_dir_all(&codex_root)?;
        let original_auth = auth_json_fixture("original@example.com", "sub-original", Some("pro"));
        fs::write(codex_root.join("auth.json"), &original_auth)?;
        fs::write(codex_root.join("cap_sid"), "sid-original")?;
        let env = AppEnv {
            kind: EnvironmentKind::Linux,
            home_dir: temp.path().to_path_buf(),
            codex_root: codex_root.clone(),
            app_data_dir: temp.path().join("data"),
        };

        begin_add_account_session(&env)?;
        assert_eq!(fs::read_to_string(codex_root.join("auth.json"))?, original_auth);
        assert_eq!(fs::read_to_string(codex_root.join("cap_sid"))?, "sid-original");
        assert!(add_account_session_active(&env));
        fs::write(
            codex_root.join("auth.json"),
            auth_json_fixture("new@example.com", "sub-new", Some("plus")),
        )?;
        cancel_add_account_session(&env)?;

        assert_eq!(
            fs::read_to_string(codex_root.join("auth.json"))?,
            original_auth
        );
        assert_eq!(
            fs::read_to_string(codex_root.join("cap_sid"))?,
            "sid-original"
        );
        assert!(!add_account_session_active(&env));
        Ok(())
    }

    #[test]
    fn rejects_snapshot_with_unmanaged_or_duplicate_files() {
        let snapshot = SnapshotBlob {
            schema_version: SNAPSHOT_SCHEMA_VERSION,
            files: vec![
                SnapshotFile {
                    name: "auth.json".to_owned(),
                    bytes_base64: STANDARD.encode(b"{}"),
                },
                SnapshotFile {
                    name: "cap_sid".to_owned(),
                    bytes_base64: STANDARD.encode(b"sid"),
                },
                SnapshotFile {
                    name: "../../.zshrc".to_owned(),
                    bytes_base64: STANDARD.encode(b"malicious"),
                },
            ],
        };

        let error = validate_snapshot(&snapshot).expect_err("unmanaged file must be rejected");

        assert!(format!("{error:#}").contains("exactly the managed auth files"));
    }

    #[test]
    fn accepts_exact_managed_snapshot_files() {
        let snapshot = SnapshotBlob {
            schema_version: SNAPSHOT_SCHEMA_VERSION,
            files: vec![
                SnapshotFile {
                    name: "auth.json".to_owned(),
                    bytes_base64: STANDARD.encode(b"{}"),
                },
                SnapshotFile {
                    name: "cap_sid".to_owned(),
                    bytes_base64: STANDARD.encode(b"sid"),
                },
            ],
        };

        validate_snapshot(&snapshot).expect("managed snapshot remains supported");
    }

    #[test]
    fn restore_verification_uses_case_insensitive_email_when_subject_missing() -> Result<()> {
        let temp = tempdir()?;
        let codex_root = temp.path().join(".codex");
        fs::create_dir_all(&codex_root)?;
        fs::write(
            codex_root.join("auth.json"),
            auth_json_fixture("Person@Example.com", "sub-1", Some("pro")),
        )?;
        fs::write(codex_root.join("cap_sid"), "sid-1")?;
        let env = AppEnv {
            kind: EnvironmentKind::Linux,
            home_dir: temp.path().to_path_buf(),
            codex_root: codex_root.clone(),
            app_data_dir: temp.path().join("data"),
        };
        let bundle = read_live_auth_bundle(&env)?;
        let expected = DisplayIdentity {
            email: "person@example.com".to_owned(),
            subject: None,
            name: bundle.identity.name.clone(),
            plan_label: bundle.identity.plan_label.clone(),
        };
        restore_snapshot(&env, &bundle.snapshot, &expected, false)?;
        Ok(())
    }

    #[test]
    fn rollback_removes_auth_files_that_were_absent_before_restore() -> Result<()> {
        let temp = tempdir()?;
        let codex_root = temp.path().join(".codex");
        fs::create_dir_all(&codex_root)?;
        let before_auth = auth_json_fixture("before@example.com", "sub-before", Some("plus"));
        fs::write(codex_root.join("auth.json"), &before_auth)?;
        let env = AppEnv {
            kind: EnvironmentKind::Linux,
            home_dir: temp.path().to_path_buf(),
            codex_root: codex_root.clone(),
            app_data_dir: temp.path().join("data"),
        };
        let snapshot = SnapshotBlob {
            schema_version: SNAPSHOT_SCHEMA_VERSION,
            files: vec![
                SnapshotFile {
                    name: "auth.json".to_owned(),
                    bytes_base64: STANDARD.encode(auth_json_fixture(
                        "after@example.com",
                        "sub-after",
                        Some("pro"),
                    )),
                },
                SnapshotFile {
                    name: "cap_sid".to_owned(),
                    bytes_base64: STANDARD.encode(b"sid-after"),
                },
            ],
        };
        let expected = DisplayIdentity {
            email: "before@example.com".to_owned(),
            subject: Some("sub-before".to_owned()),
            name: None,
            plan_label: None,
        };

        restore_snapshot(&env, &snapshot, &expected, false).expect_err("identity mismatch");

        assert!(!codex_root.join("cap_sid").exists());
        assert_eq!(
            fs::read_to_string(codex_root.join("auth.json"))?,
            before_auth
        );
        Ok(())
    }

    #[cfg(unix)]
    #[test]
    fn staging_helpers_keep_auth_material_private() -> Result<()> {
        use std::os::unix::fs::PermissionsExt;

        let temp = tempdir()?;
        let directory = temp.path().join(".cas-restore-test");
        create_private_directory(&directory)?;
        let file = directory.join("auth.json");
        write_private_staged_file(&file, b"secret")?;

        assert_eq!(
            fs::metadata(&directory)?.permissions().mode() & 0o777,
            0o700
        );
        assert_eq!(fs::metadata(&file)?.permissions().mode() & 0o777, 0o600);
        Ok(())
    }

    #[test]
    fn stable_verification_fails_when_auth_reverts() -> Result<()> {
        let temp = tempdir()?;
        let codex_root = temp.path().join(".codex");
        fs::create_dir_all(&codex_root)?;
        fs::write(
            codex_root.join("auth.json"),
            auth_json_fixture("after@example.com", "sub-2", Some("plus")),
        )?;
        fs::write(codex_root.join("cap_sid"), "sid-2")?;
        let env = AppEnv {
            kind: EnvironmentKind::Linux,
            home_dir: temp.path().to_path_buf(),
            codex_root: codex_root.clone(),
            app_data_dir: temp.path().join("data"),
        };
        let expected = DisplayIdentity {
            email: "after@example.com".to_owned(),
            subject: Some("sub-2".to_owned()),
            name: Some("Tester".to_owned()),
            plan_label: Some("Plus".to_owned()),
        };
        let expected_snapshot = read_live_auth_bundle(&env)?.snapshot;
        let auth_path = codex_root.join("auth.json");
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(25));
            fs::write(
                auth_path,
                auth_json_fixture("before@example.com", "sub-1", Some("pro")),
            )
            .expect("rewrite auth");
        });

        let error = verify_live_snapshot_stable_with_retry(
            &env,
            &expected_snapshot,
            &expected,
            10,
            Duration::from_millis(10),
        )
        .expect_err("verification should fail after revert");
        assert!(format!("{error:#}").contains("changed again after activation"));
        Ok(())
    }

    #[test]
    fn stable_verification_fails_when_cap_sid_reverts() -> Result<()> {
        let temp = tempdir()?;
        let codex_root = temp.path().join(".codex");
        fs::create_dir_all(&codex_root)?;
        fs::write(
            codex_root.join("auth.json"),
            auth_json_fixture("after@example.com", "sub-2", Some("plus")),
        )?;
        fs::write(codex_root.join("cap_sid"), "sid-2")?;
        let env = AppEnv {
            kind: EnvironmentKind::Linux,
            home_dir: temp.path().to_path_buf(),
            codex_root: codex_root.clone(),
            app_data_dir: temp.path().join("data"),
        };
        let expected = DisplayIdentity {
            email: "after@example.com".to_owned(),
            subject: Some("sub-2".to_owned()),
            name: Some("Tester".to_owned()),
            plan_label: Some("Plus".to_owned()),
        };
        let expected_snapshot = read_live_auth_bundle(&env)?.snapshot;
        let cap_sid_path = codex_root.join("cap_sid");
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(25));
            fs::write(cap_sid_path, "sid-1").expect("rewrite cap sid");
        });

        let error = verify_live_snapshot_stable_with_retry(
            &env,
            &expected_snapshot,
            &expected,
            10,
            Duration::from_millis(10),
        )
        .expect_err("verification should fail after cap_sid drift");
        assert!(format!("{error:#}").contains("changed again after activation"));
        Ok(())
    }

    #[test]
    fn snapshot_match_rejects_duplicate_managed_files() {
        let left = SnapshotBlob {
            schema_version: 1,
            files: vec![
                SnapshotFile {
                    name: "auth.json".to_owned(),
                    bytes_base64: "auth-a".to_owned(),
                },
                SnapshotFile {
                    name: "cap_sid".to_owned(),
                    bytes_base64: "sid-a".to_owned(),
                },
            ],
        };
        let right = SnapshotBlob {
            schema_version: 1,
            files: vec![
                SnapshotFile {
                    name: "auth.json".to_owned(),
                    bytes_base64: "auth-a".to_owned(),
                },
                SnapshotFile {
                    name: "auth.json".to_owned(),
                    bytes_base64: "auth-b".to_owned(),
                },
                SnapshotFile {
                    name: "cap_sid".to_owned(),
                    bytes_base64: "sid-a".to_owned(),
                },
            ],
        };

        assert!(!snapshot_matches(&left, &right));
        assert!(!snapshot_matches(&right, &left));
    }
}
