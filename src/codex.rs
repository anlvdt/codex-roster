use std::fs;
use std::path::Path;
use std::time::Duration;

use anyhow::{Context, Result, bail};
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
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

/// Opt-in switch diagnostics. Enabled by setting `CODEX_ROSTER_AUTH_DEBUG` or by
/// creating a `.roster-auth-debug` marker in the Codex root (`touch
/// ~/.codex/.roster-auth-debug`). Writes non-secret token fingerprints to
/// `<app_data_dir>/auth-debug.log` so a re-login-on-switch report can be traced
/// to the exact point a saved refresh token went stale.
fn auth_debug_enabled(env: &AppEnv) -> bool {
    std::env::var_os("CODEX_ROSTER_AUTH_DEBUG").is_some()
        || env.codex_root.join(".roster-auth-debug").exists()
}

pub fn auth_debug(env: &AppEnv, line: &str) {
    if !auth_debug_enabled(env) {
        return;
    }
    let stamp = time::OffsetDateTime::now_utc()
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap_or_else(|_| "?".to_owned());
    if fs::create_dir_all(&env.app_data_dir).is_err() {
        return;
    }
    let path = env.app_data_dir.join("auth-debug.log");
    append_private_log(&path, &format!("{stamp} {line}"), AUTH_DEBUG_LOG_MAX_BYTES);
}

const AUTH_DEBUG_LOG_MAX_BYTES: u64 = 1024 * 1024;

/// Append one line to a diagnostics log that is created 0600, never written
/// through a symlink, and rotated to `<name>.1` once it passes `max_bytes`
/// (a single previous generation is kept).
fn append_private_log(path: &Path, line: &str, max_bytes: u64) {
    use std::io::Write;
    if let Ok(metadata) = fs::symlink_metadata(path) {
        if !metadata.file_type().is_file() {
            return;
        }
        if metadata.len() >= max_bytes {
            let mut rotated = path.as_os_str().to_owned();
            rotated.push(".1");
            let _ = fs::rename(path, std::path::PathBuf::from(rotated));
        }
    }
    let mut options = std::fs::OpenOptions::new();
    options.create(true).append(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    if let Ok(mut file) = options.open(path) {
        let _ = writeln!(file, "{line}");
        let _ = set_private_file_permissions(path);
    }
}

/// A non-secret, non-reversible summary of the auth material in a snapshot, for
/// diagnosing token staleness across a switch. Never emits token bytes: the
/// refresh token is reduced to a stable one-way fingerprint so two lines can be
/// compared to tell whether the token rotated, and only the access token's `exp`
/// claim and `last_refresh` timestamp are surfaced.
pub fn auth_fingerprint(snapshot: &SnapshotBlob) -> String {
    let Some(auth) = snapshot.files.iter().find(|file| file.name == "auth.json") else {
        return "auth.json-missing".to_owned();
    };
    match STANDARD.decode(&auth.bytes_base64) {
        Ok(bytes) => auth_fingerprint_from_bytes(&bytes),
        Err(_) => "auth.json-undecodable".to_owned(),
    }
}

pub fn auth_fingerprint_from_bytes(bytes: &[u8]) -> String {
    let Ok(root) = serde_json::from_slice::<serde_json::Value>(bytes) else {
        return "auth.json-unparsable".to_owned();
    };
    let tokens = root.get("tokens");
    let account_id = tokens
        .and_then(|tokens| tokens.get("account_id"))
        .and_then(serde_json::Value::as_str)
        .unwrap_or("?");
    let last_refresh = root
        .get("last_refresh")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("?");
    let refresh_fp = tokens
        .and_then(|tokens| tokens.get("refresh_token"))
        .and_then(serde_json::Value::as_str)
        .map_or_else(|| "none".to_owned(), one_way_fingerprint);
    let access_exp = tokens
        .and_then(|tokens| tokens.get("access_token"))
        .and_then(serde_json::Value::as_str)
        .and_then(jwt_exp_claim)
        .map_or_else(|| "?".to_owned(), |exp| exp.to_string());
    format!(
        "account_id={account_id} last_refresh={last_refresh} access_exp={access_exp} refresh_fp={refresh_fp}"
    )
}

/// Deterministic, non-cryptographic, one-way fingerprint. Enough to tell whether
/// a refresh token changed between two log lines; not reversible to the token.
fn one_way_fingerprint(value: &str) -> String {
    use std::hash::{Hash, Hasher};
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    value.hash(&mut hasher);
    format!("{:016x}", hasher.finish())
}

fn jwt_exp_claim(jwt: &str) -> Option<i64> {
    let payload = jwt.split('.').nth(1)?;
    let bytes = URL_SAFE_NO_PAD.decode(payload).ok()?;
    let claims = serde_json::from_slice::<serde_json::Value>(&bytes).ok()?;
    claims.get("exp")?.as_i64()
}

const ADD_ACCOUNT_AUTH_BACKUP: &str = "auth.json.roster-add-bak";
const ADD_ACCOUNT_CAP_BACKUP: &str = "cap_sid.roster-add-bak";
const ADD_ACCOUNT_MARKER: &str = ".roster-add-account";

pub fn add_account_session_active(env: &AppEnv) -> bool {
    env.codex_root.join(ADD_ACCOUNT_MARKER).exists()
}

/// A completed Codex login must replace the auth document that was present
/// when the add/re-login session began. Identity alone is not sufficient for a
/// same-account re-login, and an OAuth callback can succeed before Codex has
/// finished persisting its new credentials.
pub fn add_account_auth_changed(env: &AppEnv) -> Result<bool> {
    if !add_account_session_active(env) {
        return Ok(false);
    }
    let current = fs::read(env.codex_root.join("auth.json")).ok();
    let previous = fs::read(env.codex_root.join(ADD_ACCOUNT_AUTH_BACKUP)).ok();
    Ok(match (previous, current) {
        (Some(previous), Some(current)) => current != previous,
        (None, Some(current)) => !current.is_empty(),
        _ => false,
    })
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
    // Stale backups from a previously completed session must not stand in for
    // files that are absent at the start of this session.
    remove_file_if_exists(&backup_auth)?;
    remove_file_if_exists(&backup_sid)?;
    if auth.exists() {
        fs::copy(&auth, &backup_auth).with_context(|| {
            format!(
                "failed to back up {} to {}",
                auth.display(),
                backup_auth.display()
            )
        })?;
    }
    if cap_sid.exists() {
        fs::copy(&cap_sid, &backup_sid).with_context(|| {
            format!(
                "failed to back up {} to {}",
                cap_sid.display(),
                backup_sid.display()
            )
        })?;
    }
    let marker = serde_json::to_vec(&serde_json::json!({
        "auth_present": auth.exists(),
        "cap_present": cap_sid.exists(),
    }))?;
    fs::write(env.codex_root.join(ADD_ACCOUNT_MARKER), marker).with_context(|| {
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
    if !add_account_auth_changed(env)? {
        bail!(
            "Codex login has not written new credentials yet; finish the browser login and wait for it to complete before saving"
        );
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
    let marker = fs::read(env.codex_root.join(ADD_ACCOUNT_MARKER))?;
    // The legacy marker used the literal "pending". Every newer marker must
    // explicitly record both preimages before cancellation may remove live files.
    let initial: Option<serde_json::Value> = if marker == b"pending" {
        None
    } else {
        let value: serde_json::Value = serde_json::from_slice(&marker)
            .context("add-account marker is damaged; cannot safely cancel login")?;
        if value
            .get("auth_present")
            .and_then(serde_json::Value::as_bool)
            .is_none()
            || value
                .get("cap_present")
                .and_then(serde_json::Value::as_bool)
                .is_none()
        {
            bail!("add-account marker lacks original file state; cannot safely cancel login");
        }
        Some(value)
    };
    if initial
        .as_ref()
        .and_then(|value| value["auth_present"].as_bool())
        == Some(true)
        && !backup_auth.exists()
    {
        bail!("the previous auth backup is missing; cannot safely cancel login");
    }
    if initial
        .as_ref()
        .and_then(|value| value["cap_present"].as_bool())
        == Some(true)
        && !backup_sid.exists()
    {
        bail!("the previous cap_sid backup is missing; cannot safely cancel login");
    }
    if backup_auth.exists() {
        copy_atomic(&backup_auth, &auth).with_context(|| {
            format!(
                "failed to restore {} from {}",
                auth.display(),
                backup_auth.display()
            )
        })?;
    } else {
        remove_file_if_exists(&auth)?;
    }
    if backup_sid.exists() {
        copy_atomic(&backup_sid, &cap_sid).with_context(|| {
            format!(
                "failed to restore {} from {}",
                cap_sid.display(),
                backup_sid.display()
            )
        })?;
    } else {
        remove_file_if_exists(&cap_sid)?;
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
        let rollback = restore_from_backup(&env.codex_root, &backup_dir);
        let _ = fs::remove_dir_all(&temp_dir);
        if let Err(rollback_error) = rollback {
            return Err(error).context(format!(
                "rollback failed: {rollback_error:#}; recovery files retained at {}",
                backup_dir.display()
            ));
        }
        let _ = fs::remove_dir_all(&backup_dir);
        return Err(error);
    }

    if let Err(error) = verify_live_snapshot_once(env, snapshot, expected_identity) {
        let rollback = restore_from_backup(&env.codex_root, &backup_dir);
        let _ = fs::remove_dir_all(&temp_dir);
        if let Err(rollback_error) = rollback {
            return Err(error).context(format!(
                "rollback failed: {rollback_error:#}; recovery files retained at {}",
                backup_dir.display()
            ));
        }
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
        let rollback = restore_from_backup(&env.codex_root, &backup_dir);
        let _ = fs::remove_dir_all(&temp_dir);
        if let Err(rollback_error) = rollback {
            return Err(error).context(format!(
                "rollback failed: {rollback_error:#}; recovery files retained at {}",
                backup_dir.display()
            ));
        }
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
            let pending_backup = backup_dir.join(format!("{file_name}.pending"));
            fs::copy(&live_path, &pending_backup).with_context(|| {
                format!(
                    "failed to back up {} to {}",
                    live_path.display(),
                    backup_path.display()
                )
            })?;
            set_private_file_permissions(&pending_backup)?;
            fs::rename(&pending_backup, &backup_path)
                .with_context(|| format!("failed to commit backup {}", backup_path.display()))?;
        } else {
            fs::write(backup_dir.join(format!("{file_name}.absent")), b"")
                .with_context(|| format!("failed to record absent {}", live_path.display()))?;
        }
        let staged_path = temp_dir.join(file_name);
        // rename(2) atomically replaces `live_path` (including a symlink, without
        // following it); the staging dir lives under `codex_root`, so it is the
        // same filesystem. Readers never observe a missing or partial file.
        fs::rename(&staged_path, &live_path).with_context(|| {
            format!(
                "failed to restore {} from {}",
                live_path.display(),
                staged_path.display()
            )
        })?;
    }
    Ok(())
}

/// Copy `src` over `dest` atomically: write a private sibling temp file, then
/// rename it into place. Unlike `fs::copy`, never writes through a symlink at
/// `dest` and never leaves `dest` missing or truncated.
fn copy_atomic(src: &Path, dest: &Path) -> Result<()> {
    let bytes = fs::read(src).with_context(|| format!("failed to read {}", src.display()))?;
    let file_name = dest
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_default();
    let tmp = dest.with_file_name(format!(".{file_name}.cas-tmp-{}", Uuid::new_v4()));
    write_private_staged_file(&tmp, &bytes)?;
    if let Err(error) = fs::rename(&tmp, dest) {
        let _ = fs::remove_file(&tmp);
        return Err(error).with_context(|| format!("failed to replace {}", dest.display()));
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
            copy_atomic(&backup_path, &live_path).with_context(|| {
                format!(
                    "failed to restore backup {} to {}",
                    backup_path.display(),
                    live_path.display()
                )
            })?;
        } else if backup_dir.join(format!("{file_name}.absent")).exists() && live_path.exists() {
            fs::remove_file(&live_path)
                .with_context(|| format!("failed to remove {}", live_path.display()))?;
        }
        // No backup or absence marker means staging never reached this file.
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

pub fn read_configured_model(codex_root: &Path) -> Option<String> {
    let config_path = codex_root.join("config.toml");
    let content = fs::read_to_string(config_path).ok()?;
    let config: ModelConfig = toml::from_str(&content).ok()?;
    config.model.map(toml::Spanned::into_inner)
}

pub fn set_configured_model(codex_root: &Path, new_model: &str) -> Result<()> {
    let config_path = codex_root.join("config.toml");
    let content = match fs::read_to_string(&config_path) {
        Ok(content) => content,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => String::new(),
        Err(error) => {
            return Err(error).with_context(|| format!("failed to read {}", config_path.display()));
        }
    };
    let config: ModelConfig =
        toml::from_str(&content).context("cannot update model in invalid Codex config.toml")?;
    let encoded = serde_json::to_string(new_model)?;
    let result = if let Some(model) = config.model {
        let mut result = content.clone();
        result.replace_range(model.start()..model.end(), &encoded);
        result
    } else {
        let newline = if content.contains("\r\n") {
            "\r\n"
        } else {
            "\n"
        };
        format!("model = {encoded}{newline}{content}")
    };
    let _: ModelConfig =
        toml::from_str(&result).context("updated Codex model config is invalid")?;
    fs::write(&config_path, result)
        .with_context(|| format!("failed to write {}", config_path.display()))?;
    Ok(())
}

#[derive(serde::Deserialize)]
struct ModelConfig {
    model: Option<toml::Spanned<String>>,
}

#[cfg(test)]
mod tests {
    use anyhow::Result;
    use tempfile::tempdir;

    use super::*;
    use crate::model::EnvironmentKind;

    #[test]
    fn review_regression_cancel_damaged_marker_keeps_live_files_and_artifacts() -> Result<()> {
        for marker in [b"{".as_slice(), b"{}", b"null", b"{\"auth_present\":false}"] {
            let temp = tempdir()?;
            let env = AppEnv {
                kind: EnvironmentKind::Linux,
                home_dir: temp.path().to_path_buf(),
                codex_root: temp.path().join("codex"),
                app_data_dir: temp.path().join("data"),
            };
            fs::create_dir(&env.codex_root)?;
            fs::write(env.codex_root.join(ADD_ACCOUNT_MARKER), marker)?;
            fs::write(env.codex_root.join("auth.json"), b"live auth")?;
            fs::write(env.codex_root.join("cap_sid"), b"live sid")?;
            assert!(cancel_add_account_session(&env).is_err());
            assert_eq!(fs::read(env.codex_root.join("auth.json"))?, b"live auth");
            assert_eq!(fs::read(env.codex_root.join("cap_sid"))?, b"live sid");
            assert!(add_account_session_active(&env));
        }
        Ok(())
    }

    #[test]
    fn review_regression_cancel_restores_original_file_absence() -> Result<()> {
        for cap_present in [false, true] {
            let temp = tempdir()?;
            let env = AppEnv {
                kind: EnvironmentKind::Linux,
                home_dir: temp.path().to_path_buf(),
                codex_root: temp.path().join("codex"),
                app_data_dir: temp.path().join("data"),
            };
            fs::create_dir(&env.codex_root)?;
            fs::write(
                env.codex_root.join(ADD_ACCOUNT_AUTH_BACKUP),
                b"stale session",
            )?;
            fs::write(env.codex_root.join(ADD_ACCOUNT_CAP_BACKUP), b"stale sid")?;
            if cap_present {
                fs::write(env.codex_root.join("cap_sid"), b"original sid")?;
            }
            begin_add_account_session(&env)?;
            fs::write(env.codex_root.join("auth.json"), b"new auth")?;
            fs::write(env.codex_root.join("cap_sid"), b"new sid")?;
            cancel_add_account_session(&env)?;
            assert!(!env.codex_root.join("auth.json").exists());
            assert!(!add_account_session_active(&env));
            if cap_present {
                assert_eq!(fs::read(env.codex_root.join("cap_sid"))?, b"original sid");
            } else {
                assert!(!env.codex_root.join("cap_sid").exists());
            }
        }
        Ok(())
    }

    #[test]
    fn review_regression_cancel_missing_original_backup_keeps_session_recoverable() -> Result<()> {
        let temp = tempdir()?;
        let env = AppEnv {
            kind: EnvironmentKind::Linux,
            home_dir: temp.path().to_path_buf(),
            codex_root: temp.path().join("codex"),
            app_data_dir: temp.path().join("data"),
        };
        fs::create_dir(&env.codex_root)?;
        fs::write(env.codex_root.join("auth.json"), b"original auth")?;
        begin_add_account_session(&env)?;
        fs::remove_file(env.codex_root.join(ADD_ACCOUNT_AUTH_BACKUP))?;
        fs::write(env.codex_root.join("auth.json"), b"new auth")?;
        assert!(cancel_add_account_session(&env).is_err());
        assert!(add_account_session_active(&env));
        assert_eq!(fs::read(env.codex_root.join("auth.json"))?, b"new auth");
        Ok(())
    }

    #[test]
    fn review_regression_model_reads_and_edits_root_only_preserving_format() -> Result<()> {
        let temp = tempdir()?;
        let path = temp.path().join("config.toml");
        let original = "# Config\r\n  model = 'root-old' # keep comment\r\n[profiles.fast]\r\nmodel = \"profile-model\"\r\n[other]\r\nmodel = 'other-model'";
        fs::write(&path, original)?;
        assert_eq!(
            read_configured_model(temp.path()).as_deref(),
            Some("root-old")
        );
        set_configured_model(temp.path(), "root-new")?;
        assert_eq!(
            fs::read_to_string(&path)?,
            original.replacen("'root-old'", "\"root-new\"", 1)
        );
        assert_eq!(
            read_configured_model(temp.path()).as_deref(),
            Some("root-new")
        );
        Ok(())
    }

    #[test]
    fn review_regression_nested_model_only_gets_new_root_model() -> Result<()> {
        let temp = tempdir()?;
        let path = temp.path().join("config.toml");
        let original = "# Config\n[profiles.fast]\nmodel = \"profile-model\"\n";
        fs::write(&path, original)?;
        assert_eq!(read_configured_model(temp.path()), None);
        set_configured_model(temp.path(), "root-new")?;
        assert_eq!(
            fs::read_to_string(&path)?,
            format!("model = \"root-new\"\n{original}")
        );
        assert_eq!(
            read_configured_model(temp.path()).as_deref(),
            Some("root-new")
        );
        Ok(())
    }

    #[test]
    fn review_regression_model_scope_ignores_headers_and_assignments_in_multiline_text()
    -> Result<()> {
        let temp = tempdir()?;
        let path = temp.path().join("config.toml");
        let original = "instructions = '''\n[profiles.fake]\nmodel = 'text only'\n'''\n\"model\" = \"root\" # root value\n[profiles.real]\nmodel = 'profile'\n";
        fs::write(&path, original)?;
        assert_eq!(read_configured_model(temp.path()).as_deref(), Some("root"));
        set_configured_model(temp.path(), "new\"model")?;
        assert_eq!(
            read_configured_model(temp.path()).as_deref(),
            Some("new\"model")
        );
        assert!(fs::read_to_string(path)?.contains("model = 'text only'"));
        Ok(())
    }

    #[test]
    fn review_regression_model_supports_multiline_and_toml_unicode_escapes() -> Result<()> {
        let cases = [
            ("\"\"\"\ngpt-\\\n   model\"\"\"", "gpt-model"),
            ("'''\ngpt-model'''", "gpt-model"),
            (r#""gpt-\U0000006Dodel""#, "gpt-model"),
            (r#""gpt-\u006Dodel""#, "gpt-model"),
            ("'gpt-\\literal'", "gpt-\\literal"),
        ];
        for (value, expected) in cases {
            let temp = tempdir()?;
            let path = temp.path().join("config.toml");
            let original = format!(
                "# tiếng Việt\nmodel = {value} # keep\n[profiles.fast]\nmodel = 'nested'\n"
            );
            fs::write(&path, &original)?;
            assert_eq!(
                read_configured_model(temp.path()).as_deref(),
                Some(expected)
            );
            set_configured_model(temp.path(), "new-model")?;
            assert_eq!(
                fs::read_to_string(&path)?,
                original.replacen(value, "\"new-model\"", 1)
            );
            assert_eq!(
                read_configured_model(temp.path()).as_deref(),
                Some("new-model")
            );
            let _: toml::Value = toml::from_str(&fs::read_to_string(path)?)?;
        }
        Ok(())
    }

    #[test]
    fn review_regression_model_setter_fails_closed_for_invalid_config_or_root_type() -> Result<()> {
        for original in [
            "model = 123\n[profiles.fast]\nmodel = 'nested'\n",
            "model = 'one'\nmodel = 'duplicate'\n",
            "model = \"unterminated\n",
            "[model]\nname = 'table'\n",
        ] {
            let temp = tempdir()?;
            let path = temp.path().join("config.toml");
            fs::write(&path, original)?;
            assert!(set_configured_model(temp.path(), "new-model").is_err());
            assert_eq!(fs::read_to_string(path)?, original);
        }
        Ok(())
    }

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
        assert_eq!(
            identity_from_snapshot(&snapshot)?.email,
            "import@example.com"
        );
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
        assert_eq!(
            fs::read_to_string(codex_root.join("auth.json"))?,
            original_auth
        );
        assert_eq!(
            fs::read_to_string(codex_root.join("cap_sid"))?,
            "sid-original"
        );
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
    fn add_account_cannot_finish_until_codex_persists_new_auth() -> Result<()> {
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
            codex_root: codex_root.clone(),
            app_data_dir: temp.path().join("data"),
        };

        begin_add_account_session(&env)?;
        assert!(!add_account_auth_changed(&env)?);
        let error = finish_add_account_session(&env).expect_err("unchanged auth must be rejected");
        assert!(format!("{error:#}").contains("has not written new credentials"));

        fs::write(
            codex_root.join("auth.json"),
            auth_json_fixture("person@example.com", "sub-1", Some("plus")),
        )?;
        assert!(add_account_auth_changed(&env)?);
        finish_add_account_session(&env)?;
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
    fn copy_atomic_replaces_symlink_instead_of_writing_through() -> Result<()> {
        let temp = tempdir()?;
        let victim = temp.path().join("victim");
        let src = temp.path().join("src");
        let dest = temp.path().join("auth.json");
        fs::write(&victim, "untouched")?;
        fs::write(&src, "secret")?;
        #[cfg(unix)]
        std::os::unix::fs::symlink(&victim, &dest)?;
        super::copy_atomic(&src, &dest)?;
        assert_eq!(fs::read_to_string(&victim)?, "untouched");
        assert_eq!(fs::read_to_string(&dest)?, "secret");
        assert!(!fs::symlink_metadata(&dest)?.file_type().is_symlink());
        Ok(())
    }

    #[test]
    fn private_log_is_0600_rotated_and_never_follows_symlinks() -> Result<()> {
        let temp = tempdir()?;
        let log = temp.path().join("auth-debug.log");
        super::append_private_log(&log, "first line", 32);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(fs::metadata(&log)?.permissions().mode() & 0o777, 0o600);
        }
        super::append_private_log(&log, "a second, longer line", 32);
        super::append_private_log(&log, "third", 32);
        assert!(temp.path().join("auth-debug.log.1").exists());
        assert!(fs::read_to_string(&log)?.contains("third"));

        #[cfg(unix)]
        {
            let victim = temp.path().join("victim");
            let link = temp.path().join("linked.log");
            fs::write(&victim, "untouched")?;
            std::os::unix::fs::symlink(&victim, &link)?;
            super::append_private_log(&link, "secret", 32);
            assert_eq!(fs::read_to_string(&victim)?, "untouched");
        }
        Ok(())
    }

    #[test]
    fn rollback_leaves_untouched_files_when_staging_fails() -> Result<()> {
        let temp = tempdir()?;
        let root = temp.path().join("codex");
        let backup = temp.path().join("backup");
        let staged = temp.path().join("staged");
        for dir in [&root, &backup, &staged] {
            fs::create_dir(dir)?;
        }
        fs::write(root.join("auth.json"), "original-auth")?;
        fs::write(root.join("cap_sid"), "original-cap")?;
        fs::create_dir(staged.join("auth.json"))?;
        let snapshot = SnapshotBlob {
            schema_version: SNAPSHOT_SCHEMA_VERSION,
            files: vec![SnapshotFile {
                name: "auth.json".to_owned(),
                bytes_base64: STANDARD.encode(b"new-auth"),
            }],
        };
        assert!(super::stage_and_restore(&root, &backup, &staged, &snapshot).is_err());
        super::restore_from_backup(&root, &backup)?;
        assert_eq!(fs::read_to_string(root.join("auth.json"))?, "original-auth");
        assert_eq!(fs::read_to_string(root.join("cap_sid"))?, "original-cap");
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

    #[test]
    fn reads_and_updates_configured_model() -> Result<()> {
        let temp = tempdir()?;
        let codex_root = temp.path();

        assert_eq!(read_configured_model(codex_root), None);

        set_configured_model(codex_root, "gpt-5.6-luna")?;
        assert_eq!(
            read_configured_model(codex_root).as_deref(),
            Some("gpt-5.6-luna")
        );

        set_configured_model(codex_root, "gpt-6-astra")?;
        assert_eq!(
            read_configured_model(codex_root).as_deref(),
            Some("gpt-6-astra")
        );

        Ok(())
    }
}
