use std::cmp::Ordering;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, anyhow, bail};
use base64::Engine;
use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use serde::Serialize;
use serde_json::{Map, Value};
use time::OffsetDateTime;
use time::format_description::well_known::Rfc3339;

use crate::file_store::replace_file_with_recovery;
use crate::model::{SavedAccountMetadata, SnapshotBlob};

const CORE_TOKEN_KEYS: [&str; 4] = ["access_token", "account_id", "id_token", "refresh_token"];

#[derive(Clone, Debug, Default, Serialize)]
pub struct CcsSyncOutput {
    pub accounts: usize,
    pub linked: usize,
    pub ccs_updated: usize,
    pub roster_updated: usize,
    pub unchanged: usize,
    pub skipped: usize,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub warnings: Vec<String>,
}

pub enum SyncDecision {
    WroteCcs { created: bool },
    UpdatedRoster(SnapshotBlob),
    Unchanged,
}

struct CcsCandidate {
    path: PathBuf,
    value: Value,
}

pub fn sync_snapshot(
    metadata: &SavedAccountMetadata,
    snapshot: &SnapshotBlob,
    auth_dir: &Path,
) -> Result<SyncDecision> {
    let roster_auth = auth_json_from_snapshot(snapshot)?;
    let roster_tokens = token_object(&roster_auth)?;
    let account_id = required_string(roster_tokens, "account_id")?;
    let candidate = find_ccs_candidate(auth_dir, &metadata.email, account_id)?;

    if let Some(candidate) = candidate {
        match credential_version(&candidate.value).cmp(&credential_version(&roster_auth)) {
            Ordering::Greater => {
                let updated_auth = merge_ccs_into_roster(&roster_auth, &candidate.value)?;
                let updated_snapshot = replace_snapshot_auth(snapshot, &updated_auth)?;
                Ok(SyncDecision::UpdatedRoster(updated_snapshot))
            }
            Ordering::Less => {
                let updated =
                    merge_roster_into_ccs(Some(candidate.value), &roster_auth, &metadata.email)?;
                write_secret_json(&candidate.path, &updated)?;
                Ok(SyncDecision::WroteCcs { created: false })
            }
            Ordering::Equal => Ok(SyncDecision::Unchanged),
        }
    } else {
        fs::create_dir_all(auth_dir).with_context(|| {
            format!("failed to create CCS auth directory {}", auth_dir.display())
        })?;
        set_directory_permissions(auth_dir)?;
        let path = auth_dir.join(format!("codex-roster-{account_id}.json"));
        if path.exists() {
            bail!(
                "refusing to replace unrecognized CCS credential file {}",
                path.display()
            );
        }
        let value = merge_roster_into_ccs(None, &roster_auth, &metadata.email)?;
        write_secret_json(&path, &value)?;
        Ok(SyncDecision::WroteCcs { created: true })
    }
}

/// Create a missing CCS credential from a saved Roster snapshot without
/// modifying either an existing CCS account or the live Codex session.
pub fn link_snapshot(
    metadata: &SavedAccountMetadata,
    snapshot: &SnapshotBlob,
    auth_dir: &Path,
) -> Result<bool> {
    let roster_auth = auth_json_from_snapshot(snapshot)?;
    let roster_tokens = token_object(&roster_auth)?;
    let account_id = required_string(roster_tokens, "account_id")?;
    if find_ccs_candidate(auth_dir, &metadata.email, account_id)?.is_some() {
        return Ok(false);
    }
    fs::create_dir_all(auth_dir)
        .with_context(|| format!("failed to create CCS auth directory {}", auth_dir.display()))?;
    set_directory_permissions(auth_dir)?;
    let path = auth_dir.join(format!("codex-roster-{account_id}.json"));
    if path.exists() {
        bail!(
            "refusing to replace unrecognized CCS credential file {}",
            path.display()
        );
    }
    let value = merge_roster_into_ccs(None, &roster_auth, &metadata.email)?;
    write_secret_json(&path, &value)?;
    Ok(true)
}

fn auth_json_from_snapshot(snapshot: &SnapshotBlob) -> Result<Value> {
    let file = snapshot
        .files
        .iter()
        .find(|file| file.name == "auth.json")
        .context("snapshot missing auth.json")?;
    let bytes = STANDARD
        .decode(&file.bytes_base64)
        .context("failed to decode snapshot auth.json")?;
    serde_json::from_slice(&bytes).context("failed to parse snapshot auth.json")
}

fn replace_snapshot_auth(snapshot: &SnapshotBlob, auth: &Value) -> Result<SnapshotBlob> {
    let bytes = serde_json::to_vec_pretty(auth).context("failed to serialize Codex auth.json")?;
    let mut updated = snapshot.clone();
    let file = updated
        .files
        .iter_mut()
        .find(|file| file.name == "auth.json")
        .context("snapshot missing auth.json")?;
    file.bytes_base64 = STANDARD.encode(bytes);
    Ok(updated)
}

fn find_ccs_candidate(
    auth_dir: &Path,
    email: &str,
    account_id: &str,
) -> Result<Option<CcsCandidate>> {
    let mut email_match = None;
    let paused_dir = auth_dir.parent().map(|parent| parent.join("auth-paused"));
    for directory in std::iter::once(auth_dir).chain(paused_dir.as_deref()) {
        if !directory.exists() {
            continue;
        }
        for entry in fs::read_dir(directory)
            .with_context(|| format!("failed to read CCS auth directory {}", directory.display()))?
        {
            let entry = entry?;
            let path = entry.path();
            if path.extension().and_then(|value| value.to_str()) != Some("json") {
                continue;
            }
            let bytes = match fs::read(&path) {
                Ok(bytes) => bytes,
                Err(_) => continue,
            };
            let value: Value = match serde_json::from_slice(&bytes) {
                Ok(value) => value,
                Err(_) => continue,
            };
            if value.get("type").and_then(Value::as_str) != Some("codex") {
                continue;
            }
            let candidate_id = value.get("account_id").and_then(Value::as_str);
            if candidate_id == Some(account_id) {
                return Ok(Some(CcsCandidate { path, value }));
            }
            let candidate_email = value.get("email").and_then(Value::as_str);
            if candidate_email.is_some_and(|value| value.eq_ignore_ascii_case(email))
                && candidate_id.is_none()
            {
                email_match = Some(CcsCandidate { path, value });
            }
        }
    }
    Ok(email_match)
}

fn merge_roster_into_ccs(
    existing: Option<Value>,
    roster_auth: &Value,
    email: &str,
) -> Result<Value> {
    let tokens = token_object(roster_auth)?;
    let mut output = existing
        .and_then(|value| value.as_object().cloned())
        .unwrap_or_default();
    for key in CORE_TOKEN_KEYS {
        output.insert(key.to_owned(), required_value(tokens, key)?.clone());
    }
    output.insert("type".to_owned(), Value::String("codex".to_owned()));
    output.insert("email".to_owned(), Value::String(email.to_owned()));
    output
        .entry("disabled".to_owned())
        .or_insert(Value::Bool(false));
    if let Some(last_refresh) = roster_auth.get("last_refresh") {
        output.insert("last_refresh".to_owned(), last_refresh.clone());
    }
    if let Some(expired) = access_token_expiry(tokens.get("access_token"))? {
        output.insert("expired".to_owned(), Value::String(expired));
    }
    Ok(Value::Object(output))
}

fn merge_ccs_into_roster(roster_auth: &Value, ccs: &Value) -> Result<Value> {
    let mut root = roster_auth
        .as_object()
        .cloned()
        .context("Codex auth.json root must be an object")?;
    let mut tokens = root
        .get("tokens")
        .and_then(Value::as_object)
        .cloned()
        .context("Codex auth.json must contain a tokens object")?;
    let ccs_object = ccs
        .as_object()
        .context("CCS credential root must be an object")?;
    for key in CORE_TOKEN_KEYS {
        tokens.insert(key.to_owned(), required_value(ccs_object, key)?.clone());
    }
    root.insert("tokens".to_owned(), Value::Object(tokens));
    root.insert("auth_mode".to_owned(), Value::String("chatgpt".to_owned()));
    if let Some(last_refresh) = ccs.get("last_refresh") {
        root.insert("last_refresh".to_owned(), last_refresh.clone());
    }
    Ok(Value::Object(root))
}

fn credential_version(value: &Value) -> (i128, i64) {
    let last_refresh = value
        .get("last_refresh")
        .and_then(Value::as_str)
        .and_then(|value| OffsetDateTime::parse(value, &Rfc3339).ok())
        .map(OffsetDateTime::unix_timestamp_nanos)
        .unwrap_or(i128::MIN);
    let access_token = value
        .get("tokens")
        .and_then(Value::as_object)
        .or_else(|| value.as_object())
        .and_then(|tokens| tokens.get("access_token"));
    let expires = jwt_expiry(access_token).unwrap_or(i64::MIN);
    (last_refresh, expires)
}

fn access_token_expiry(value: Option<&Value>) -> Result<Option<String>> {
    let Some(timestamp) = jwt_expiry(value) else {
        return Ok(None);
    };
    let expiry = OffsetDateTime::from_unix_timestamp(timestamp)
        .context("Codex access token has an invalid expiry timestamp")?;
    Ok(Some(expiry.format(&Rfc3339)?))
}

fn jwt_expiry(value: Option<&Value>) -> Option<i64> {
    let token = value?.as_str()?;
    let payload = token.split('.').nth(1)?;
    let decoded = URL_SAFE_NO_PAD.decode(payload).ok()?;
    let json: Value = serde_json::from_slice(&decoded).ok()?;
    json.get("exp").and_then(Value::as_i64)
}

fn token_object(value: &Value) -> Result<&Map<String, Value>> {
    value
        .get("tokens")
        .and_then(Value::as_object)
        .context("Codex auth.json must contain a tokens object")
}

fn required_value<'a>(object: &'a Map<String, Value>, key: &str) -> Result<&'a Value> {
    let value = object
        .get(key)
        .ok_or_else(|| anyhow!("credential is missing {key}"))?;
    if value.as_str().is_none_or(str::is_empty) {
        bail!("credential has an invalid {key}");
    }
    Ok(value)
}

fn required_string<'a>(object: &'a Map<String, Value>, key: &str) -> Result<&'a str> {
    required_value(object, key)?
        .as_str()
        .ok_or_else(|| anyhow!("credential has an invalid {key}"))
}

fn write_secret_json(path: &Path, value: &Value) -> Result<()> {
    let bytes = serde_json::to_vec_pretty(value).context("failed to serialize CCS credential")?;
    replace_file_with_recovery(path, None, |temporary| {
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options
            .open(temporary)
            .with_context(|| format!("failed to create {}", temporary.display()))?;
        file.write_all(&bytes)
            .with_context(|| format!("failed to write {}", temporary.display()))?;
        file.sync_all()
            .with_context(|| format!("failed to sync {}", temporary.display()))?;
        Ok(())
    })?;
    set_file_permissions(path)
}

#[cfg(unix)]
fn set_directory_permissions(path: &Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))
        .with_context(|| format!("failed to secure {}", path.display()))
}

#[cfg(not(unix))]
fn set_directory_permissions(_path: &Path) -> Result<()> {
    Ok(())
}

#[cfg(unix)]
fn set_file_permissions(path: &Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))
        .with_context(|| format!("failed to secure {}", path.display()))
}

#[cfg(not(unix))]
fn set_file_permissions(_path: &Path) -> Result<()> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{AiProvider, EnvironmentKind, SnapshotFile};
    use uuid::Uuid;

    fn jwt(exp: i64) -> String {
        let payload = URL_SAFE_NO_PAD.encode(serde_json::json!({ "exp": exp }).to_string());
        format!("header.{payload}.signature")
    }

    fn auth(last_refresh: &str, account_id: &str, marker: &str) -> Value {
        serde_json::json!({
            "auth_mode": "chatgpt",
            "last_refresh": last_refresh,
            "tokens": {
                "access_token": jwt(2_000_000_000),
                "account_id": account_id,
                "id_token": format!("id-{marker}"),
                "refresh_token": format!("refresh-{marker}")
            }
        })
    }

    fn snapshot(value: &Value) -> SnapshotBlob {
        SnapshotBlob {
            schema_version: 1,
            files: vec![SnapshotFile {
                name: "auth.json".to_owned(),
                bytes_base64: STANDARD.encode(serde_json::to_vec(value).expect("auth json")),
            }],
        }
    }

    fn metadata() -> SavedAccountMetadata {
        let now = OffsetDateTime::now_utc();
        SavedAccountMetadata {
            id: Uuid::new_v4(),
            environment: EnvironmentKind::Macos,
            provider: AiProvider::OpenAi,
            email: "person@example.com".to_owned(),
            subject: Some("subject".to_owned()),
            name: None,
            custom_label: None,
            plan_label: None,
            secret_key: "secret".to_owned(),
            created_at: now,
            updated_at: now,
            last_activated_at: None,
            archived: false,
            cached_usage: None,
            cached_usage_error: None,
        }
    }

    #[test]
    fn creates_ccs_file_without_exposing_nested_roster_shape() {
        let temp = tempfile::tempdir().expect("tempdir");
        let roster = auth("2026-08-12T01:00:00Z", "account-1", "roster");
        let decision = sync_snapshot(&metadata(), &snapshot(&roster), temp.path()).expect("sync");
        assert!(matches!(decision, SyncDecision::WroteCcs { created: true }));
        let path = temp.path().join("codex-roster-account-1.json");
        let ccs: Value = serde_json::from_slice(&fs::read(path).expect("ccs file")).expect("json");
        assert_eq!(ccs["type"], "codex");
        assert_eq!(ccs["email"], "person@example.com");
        assert_eq!(ccs["refresh_token"], "refresh-roster");
        assert!(ccs.get("tokens").is_none());
    }

    #[test]
    fn newer_ccs_credential_updates_roster_snapshot() {
        let temp = tempfile::tempdir().expect("tempdir");
        let roster = auth("2026-08-12T01:00:00Z", "account-1", "roster");
        let newer = merge_roster_into_ccs(
            None,
            &auth("2026-08-12T02:00:00Z", "account-1", "ccs"),
            "person@example.com",
        )
        .expect("ccs");
        write_secret_json(&temp.path().join("codex-existing.json"), &newer).expect("write");
        let decision = sync_snapshot(&metadata(), &snapshot(&roster), temp.path()).expect("sync");
        let SyncDecision::UpdatedRoster(updated) = decision else {
            panic!("expected roster update");
        };
        let updated = auth_json_from_snapshot(&updated).expect("updated auth");
        assert_eq!(updated["tokens"]["refresh_token"], "refresh-ccs");
        assert_eq!(updated["last_refresh"], "2026-08-12T02:00:00Z");
    }

    #[test]
    fn different_account_id_with_same_email_does_not_get_overwritten() {
        let temp = tempfile::tempdir().expect("tempdir");
        let other = merge_roster_into_ccs(
            None,
            &auth("2026-08-12T02:00:00Z", "account-other", "other"),
            "person@example.com",
        )
        .expect("ccs");
        write_secret_json(&temp.path().join("codex-other.json"), &other).expect("write");
        let roster = auth("2026-08-12T01:00:00Z", "account-1", "roster");
        let decision = sync_snapshot(&metadata(), &snapshot(&roster), temp.path()).expect("sync");
        assert!(matches!(decision, SyncDecision::WroteCcs { created: true }));
        assert!(temp.path().join("codex-roster-account-1.json").exists());
    }

    #[test]
    fn link_only_preserves_existing_ccs_credential() {
        let temp = tempfile::tempdir().expect("tempdir");
        let ccs = merge_roster_into_ccs(
            None,
            &auth("2026-08-12T02:00:00Z", "account-1", "ccs"),
            "person@example.com",
        )
        .expect("ccs");
        let path = temp.path().join("codex-existing.json");
        write_secret_json(&path, &ccs).expect("write");
        let before = fs::read(&path).expect("before");
        let roster = auth("2026-08-12T03:00:00Z", "account-1", "roster");
        assert!(!link_snapshot(&metadata(), &snapshot(&roster), temp.path()).expect("link"));
        assert_eq!(fs::read(path).expect("after"), before);
    }

    #[test]
    fn link_only_finds_ccs_credential_in_paused_directory() {
        let temp = tempfile::tempdir().expect("tempdir");
        let auth_dir = temp.path().join("auth");
        let paused_dir = temp.path().join("auth-paused");
        fs::create_dir_all(&auth_dir).expect("auth dir");
        fs::create_dir_all(&paused_dir).expect("paused dir");
        let ccs = merge_roster_into_ccs(
            None,
            &auth("2026-08-12T02:00:00Z", "account-1", "ccs"),
            "person@example.com",
        )
        .expect("ccs");
        write_secret_json(&paused_dir.join("codex-paused.json"), &ccs).expect("write");
        let roster = auth("2026-08-12T03:00:00Z", "account-1", "roster");
        assert!(!link_snapshot(&metadata(), &snapshot(&roster), &auth_dir).expect("link"));
        assert_eq!(fs::read_dir(&auth_dir).expect("auth entries").count(), 0);
    }
}
