use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use anyhow::{Context, Result, bail};
use base64::Engine;
use serde_json::Value;
use time::OffsetDateTime;

use super::{
    ProviderAdapter, ProviderAuthBundle, SnapshotRefresh, find_string, parse_datetime,
    percent_window,
};
use crate::env::AppEnv;
use crate::model::{
    AiProvider, DisplayIdentity, ProviderCapability, ProviderUsageStatus, ProviderUsageView,
    SNAPSHOT_SCHEMA_VERSION, SnapshotBlob, SnapshotFile, UsageFidelity,
};

pub struct ClaudeAdapter;
pub static CLAUDE: ClaudeAdapter = ClaudeAdapter;

pub(crate) const UNKNOWN_EMAIL: &str = "claude-user@unknown.local";
const OAUTH_USAGE_URL: &str = "https://api.anthropic.com/api/oauth/usage";
const SHARED_CREDENTIAL_KEYS: [&str; 5] = [
    "mcpOAuth",
    "mcpOAuthClientConfig",
    "mcpXaaIdp",
    "mcpXaaIdpConfig",
    "pluginSecrets",
];
/// Anthropic expects a `claude-code/<version>` agent on the OAuth usage API.
const FALLBACK_CLAUDE_CODE_VERSION: &str = "2.1.0";
const CAPABILITIES: &[ProviderCapability] = &[
    ProviderCapability::ReadIdentity,
    ProviderCapability::MonitorUsage,
    ProviderCapability::SnapshotAuth,
    ProviderCapability::SwitchAccount,
];

fn claude_dir(env: &AppEnv) -> PathBuf {
    env.home_dir.join(".claude")
}

fn credentials_path(env: &AppEnv) -> PathBuf {
    claude_dir(env).join(".credentials.json")
}

fn config_path(env: &AppEnv) -> PathBuf {
    env.home_dir.join(".claude.json")
}

fn read_keychain_password() -> Option<String> {
    if !cfg!(target_os = "macos") {
        return None;
    }
    super::claude_keychain::get_password(
        super::claude_keychain::SERVICE,
        &super::claude_keychain::account_name(),
    )
    .ok()
    .flatten()
}

fn oauth_object(value: &Value) -> &Value {
    value.get("claudeAiOauth").unwrap_or(value)
}

#[cfg(test)]
fn identity_from_json(raw: &str) -> Option<DisplayIdentity> {
    let value: Value = serde_json::from_str(raw).ok()?;
    identity_from_bundle_parts(None, Some(&value))
}

fn identity_from_bundle_parts(
    config: Option<&Value>,
    credentials: Option<&Value>,
) -> Option<DisplayIdentity> {
    if config.is_none() && credentials.is_none() {
        return None;
    }
    let oauth_account = config.and_then(|value| value.get("oauthAccount"));
    let oauth = credentials.map(oauth_object);
    let email = oauth_account
        .and_then(|value| find_string(value, &["emailAddress"]))
        .or_else(|| oauth.and_then(|oauth| find_string(oauth, &["email"])))
        .or_else(|| credentials.and_then(|value| find_string(value, &["email"])))
        .unwrap_or_else(|| UNKNOWN_EMAIL.to_owned());
    let subject = oauth_account
        .and_then(|value| find_string(value, &["accountUuid"]))
        .or_else(|| {
            oauth.and_then(|oauth| {
                find_string(
                    oauth,
                    &["accountUuid", "account_uuid", "userId", "user_id", "sub"],
                )
            })
        })
        .or_else(|| {
            credentials
                .and_then(access_token_from_value)
                .and_then(|token| super::decode_jwt_claims(&token))
                .and_then(|claims| find_string(&claims, &["sub"]))
        });
    let plan_label = oauth
        .and_then(|oauth| find_string(oauth, &["subscriptionType", "subscription_type"]))
        .or_else(|| {
            credentials
                .and_then(|value| find_string(value, &["subscriptionType", "subscription_type"]))
        })
        .map(|value| normalize_plan(&value));
    let name = oauth_account
        .and_then(|value| find_string(value, &["organizationName"]))
        .or_else(|| oauth.and_then(|oauth| find_string(oauth, &["name", "displayName"])))
        .or_else(|| credentials.and_then(|value| find_string(value, &["name", "displayName"])));
    Some(DisplayIdentity {
        email,
        subject,
        name,
        plan_label,
    })
}

fn normalize_plan(value: &str) -> String {
    match value.to_ascii_lowercase().as_str() {
        "pro" => "Pro".to_owned(),
        "max" => "Max".to_owned(),
        "free" => "Free".to_owned(),
        _ => value.to_owned(),
    }
}

fn access_token_from_value(value: &Value) -> Option<String> {
    let oauth = oauth_object(value);
    find_string(oauth, &["accessToken", "access_token"])
        .or_else(|| find_string(value, &["accessToken", "access_token"]))
}

fn oauth_account_snapshot(config: &Value) -> Option<Value> {
    let account = config.get("oauthAccount")?;
    if !account.is_object() {
        return None;
    }
    Some(serde_json::json!({"oauthAccount": account}))
}

fn read_config_value(path: &Path) -> Option<Value> {
    let raw = fs::read_to_string(path).ok()?;
    serde_json::from_str(&raw).ok()
}

fn shared_credential_fields(live: Option<&Value>) -> Option<serde_json::Map<String, Value>> {
    let object = live?.as_object()?;
    Some(
        object
            .iter()
            .filter(|(key, _)| SHARED_CREDENTIAL_KEYS.contains(&key.as_str()))
            .map(|(key, value)| (key.clone(), value.clone()))
            .collect(),
    )
}

fn merge_shared_credential_fields(
    target_raw: &str,
    shared: Option<&serde_json::Map<String, Value>>,
) -> String {
    let Some(shared) = shared else {
        return target_raw.to_owned();
    };
    let Ok(mut target) = serde_json::from_str::<Value>(target_raw) else {
        return target_raw.to_owned();
    };
    let Some(object) = target.as_object_mut() else {
        return target_raw.to_owned();
    };
    if !object.contains_key("claudeAiOauth") {
        return target_raw.to_owned();
    }
    for key in SHARED_CREDENTIAL_KEYS {
        object.remove(key);
    }
    for (key, value) in shared {
        object.insert(key.clone(), value.clone());
    }
    serde_json::to_string(&target).unwrap_or_else(|_| target_raw.to_owned())
}

fn write_atomic(path: &Path, contents: &str, mode_0600: bool) -> Result<()> {
    let name = path
        .file_name()
        .with_context(|| format!("{} has no file name", path.display()))?;
    let tmp = path.with_file_name(format!(
        ".{}.tmp-{}",
        name.to_string_lossy(),
        uuid::Uuid::new_v4().simple()
    ));
    #[cfg(unix)]
    {
        use std::fs::OpenOptions;
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        // Create privately before writing any credential bytes.
        let effective_mode = if mode_0600 { 0o600 } else { 0o644 };
        let mut f = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(effective_mode)
            .open(&tmp)
            .with_context(|| format!("failed to write {}", tmp.display()))?;
        f.write_all(contents.as_bytes())
            .with_context(|| format!("failed to write {}", tmp.display()))?;
    }
    #[cfg(not(unix))]
    {
        fs::write(&tmp, contents.as_bytes())
            .with_context(|| format!("failed to write {}", tmp.display()))?;
    }
    let _ = mode_0600;
    fs::rename(&tmp, path).with_context(|| {
        format!(
            "failed to move {} into place at {}",
            tmp.display(),
            path.display()
        )
    })
}

fn snapshot_text(snapshot: &SnapshotBlob, name: &str) -> Result<Option<String>> {
    let Some(file) = snapshot.files.iter().find(|file| file.name == name) else {
        return Ok(None);
    };
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(&file.bytes_base64)
        .with_context(|| format!("failed to decode {name}"))?;
    Ok(Some(
        String::from_utf8(bytes).with_context(|| format!("{name} is not UTF-8"))?,
    ))
}

fn credential_text(snapshot: &SnapshotBlob) -> Result<Option<(String, String)>> {
    for name in ["claude_keychain.txt", "claude_credentials.json"] {
        if let Some(raw) = snapshot_text(snapshot, name)? {
            return Ok(Some((name.to_owned(), raw)));
        }
    }
    Ok(None)
}

fn access_token_from_snapshot(snapshot: &SnapshotBlob) -> Result<String> {
    for name in ["claude_keychain.txt", "claude_credentials.json"] {
        if let Some(raw) = snapshot_text(snapshot, name)? {
            let value: Value = serde_json::from_str(&raw)
                .with_context(|| format!("failed to parse {name} as Claude credentials"))?;
            if let Some(token) = access_token_from_value(&value) {
                return Ok(token);
            }
        }
    }
    bail!("Claude OAuth access token not found in snapshot")
}

const OAUTH_TOKEN_URL: &str = "https://platform.claude.com/v1/oauth/token";
const OAUTH_CLIENT_ID: &str = "9d1c250a-e61b-44d9-88ed-5944d1962f5e";
const ACCESS_TOKEN_EXPIRY_BUFFER_MS: i64 = 5 * 60 * 1000;

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_millis() as i64)
        .unwrap_or_default()
}

fn snapshot_access_token_expires_within(snapshot: &SnapshotBlob, within: Duration) -> bool {
    let Ok(Some((_name, raw))) = credential_text(snapshot) else {
        return false;
    };
    let Ok(value) = serde_json::from_str::<Value>(&raw) else {
        return false;
    };
    let Some(expires_at) = value
        .get("claudeAiOauth")
        .and_then(|oauth| oauth.get("expiresAt"))
        .and_then(Value::as_f64)
    else {
        return false;
    };
    now_ms() + within.as_millis() as i64 >= expires_at as i64
}

enum RefreshClass {
    Success(Value),
    Dead(String),
    Transient(String),
}

fn classify_refresh_response(status: u16, body: &str) -> RefreshClass {
    if (200..300).contains(&status) {
        return match serde_json::from_str::<Value>(body) {
            Ok(value) if value.get("access_token").and_then(Value::as_str).is_some() => {
                RefreshClass::Success(value)
            }
            _ => RefreshClass::Transient(format!(
                "token endpoint returned HTTP {status} with an unparseable body"
            )),
        };
    }
    if matches!(status, 400 | 401 | 403) {
        let error = serde_json::from_str::<Value>(body).ok().and_then(|value| {
            value
                .get("error")
                .and_then(Value::as_str)
                .map(str::to_owned)
        });
        if error.as_deref() == Some("invalid_grant") {
            return RefreshClass::Dead("invalid_grant".to_owned());
        }
        return RefreshClass::Transient(format!(
            "token endpoint returned HTTP {status} ({})",
            error.unwrap_or_else(|| "unparseable body".to_owned())
        ));
    }
    RefreshClass::Transient(format!("token endpoint returned HTTP {status}"))
}

fn rotated_credential(raw: &str, response: &Value) -> Result<String> {
    let mut data: Value =
        serde_json::from_str(raw).context("stored Claude credential is not valid JSON")?;
    let oauth = data
        .get_mut("claudeAiOauth")
        .and_then(Value::as_object_mut)
        .context("stored Claude credential has no claudeAiOauth object")?;
    let access_token = response
        .get("access_token")
        .cloned()
        .context("token response has no access_token")?;
    let expires_in = response
        .get("expires_in")
        .and_then(Value::as_f64)
        .unwrap_or(3600.0);
    oauth.insert("accessToken".to_owned(), access_token);
    oauth.insert(
        "expiresAt".to_owned(),
        Value::from(now_ms() + (expires_in * 1000.0) as i64),
    );
    if let Some(refresh_token) = response.get("refresh_token").and_then(Value::as_str) {
        oauth.insert("refreshToken".to_owned(), refresh_token.into());
    }
    if let Some(scope) = response.get("scope").and_then(Value::as_str) {
        let scopes: Vec<&str> = scope.split_whitespace().collect();
        oauth.insert("scopes".to_owned(), Value::from(scopes));
    }
    serde_json::to_string(&data).context("failed to encode rotated Claude credential")
}

fn rewrite_credential_files(snapshot: &SnapshotBlob, rotated: &str) -> SnapshotBlob {
    let encoded = base64::engine::general_purpose::STANDARD.encode(rotated);
    let files = snapshot
        .files
        .iter()
        .map(|file| {
            if matches!(
                file.name.as_str(),
                "claude_keychain.txt" | "claude_credentials.json"
            ) {
                SnapshotFile {
                    name: file.name.clone(),
                    bytes_base64: encoded.clone(),
                }
            } else {
                file.clone()
            }
        })
        .collect();
    SnapshotBlob {
        schema_version: snapshot.schema_version,
        files,
    }
}

fn oauth_values_share_credential(a: &Value, b: &Value) -> bool {
    let (Some(left), Some(right)) = (a.get("claudeAiOauth"), b.get("claudeAiOauth")) else {
        return false;
    };
    ["refreshToken", "accessToken"].iter().any(|key| {
        let a = left.get(*key).and_then(Value::as_str);
        let b = right.get(*key).and_then(Value::as_str);
        matches!((a, b), (Some(a), Some(b)) if !a.is_empty() && a == b)
    })
}

fn snapshots_share_credential(a: &SnapshotBlob, b: &SnapshotBlob) -> bool {
    let (Ok(Some((_na, raw_a))), Ok(Some((_nb, raw_b)))) = (credential_text(a), credential_text(b))
    else {
        return false;
    };
    let (Ok(va), Ok(vb)) = (
        serde_json::from_str::<Value>(&raw_a),
        serde_json::from_str::<Value>(&raw_b),
    ) else {
        return false;
    };
    oauth_values_share_credential(&va, &vb)
}

fn live_credential_text(env: &AppEnv, keychain_backed: bool) -> Option<String> {
    if keychain_backed {
        read_keychain_password().or_else(|| fs::read_to_string(credentials_path(env)).ok())
    } else {
        fs::read_to_string(credentials_path(env)).ok()
    }
}

fn snapshot_shares_live_credential(env: &AppEnv, snapshot: &SnapshotBlob) -> bool {
    let keychain_backed = cfg!(target_os = "macos")
        && snapshot
            .files
            .iter()
            .any(|file| file.name == "claude_keychain.txt");
    let Some(live_raw) = live_credential_text(env, keychain_backed) else {
        return true;
    };
    let Ok(Some((_name, snapshot_raw))) = credential_text(snapshot) else {
        return true;
    };
    let (Ok(live_value), Ok(snapshot_value)) = (
        serde_json::from_str::<Value>(&live_raw),
        serde_json::from_str::<Value>(&snapshot_raw),
    ) else {
        return true;
    };
    oauth_values_share_credential(&live_value, &snapshot_value)
}

fn post_token_refresh(request: &Value) -> Result<(u16, String)> {
    let payload = serde_json::to_string(request).context("failed to encode refresh payload")?;
    let mut response = ureq::post(OAUTH_TOKEN_URL)
        .header("Content-Type", "application/json")
        .header("User-Agent", claude_code_user_agent())
        .config()
        .http_status_as_error(false)
        .timeout_global(Some(Duration::from_secs(10)))
        .build()
        .send(&payload)
        .context("Claude token refresh request failed")?;
    let status = response.status().as_u16();
    let body = response
        .body_mut()
        .read_to_string()
        .context("failed to read Claude token refresh response")?;
    Ok((status, body))
}

fn usage_window(
    key: &str,
    label: &str,
    value: Option<&Value>,
) -> Option<crate::model::ProviderUsageWindowView> {
    let value = value?;
    let used = value
        .get("utilization")
        .and_then(usage_number)
        .or_else(|| value.get("used_percent").and_then(usage_number))?;
    let reset_at = value
        .get("resets_at")
        .or_else(|| value.get("reset_at"))
        .and_then(parse_datetime);
    Some(percent_window(key, label, used, reset_at))
}

fn usage_number(value: &Value) -> Option<f64> {
    value
        .as_f64()
        .or_else(|| value.as_str().and_then(|raw| raw.parse::<f64>().ok()))
        .filter(|number| number.is_finite() && *number >= 0.0)
}

fn parse_usage(body: &str) -> Result<ProviderUsageView> {
    let value: Value = serde_json::from_str(body).context("failed to parse Claude usage JSON")?;
    let mut windows = Vec::new();
    if let Some(window) = usage_window("five_hour", "5 hour", value.get("five_hour")) {
        windows.push(window);
    }
    if let Some(window) = usage_window("seven_day", "7 day", value.get("seven_day")) {
        windows.push(window);
    }
    if let Some(window) = usage_window(
        "seven_day_sonnet",
        "7 day Sonnet",
        value.get("seven_day_sonnet"),
    ) {
        windows.push(window);
    }
    if let Some(window) = usage_window("seven_day_opus", "7 day Opus", value.get("seven_day_opus"))
    {
        windows.push(window);
    }
    if let Some(extra) = value.get("extra_usage") {
        let used = extra
            .get("used_credits")
            .and_then(usage_number)
            .or_else(|| extra.get("used").and_then(usage_number));
        let limit = extra
            .get("monthly_limit")
            .and_then(usage_number)
            .or_else(|| extra.get("limit").and_then(usage_number));
        if used.is_some() || limit.is_some() {
            let used_percent = match (used, limit) {
                (Some(used), Some(limit)) if limit > 0.0 => {
                    Some(((used / limit) * 100.0).clamp(0.0, 100.0).round() as u8)
                }
                _ => None,
            };
            windows.push(crate::model::ProviderUsageWindowView {
                key: "extra_usage".to_owned(),
                label: "Extra usage".to_owned(),
                used_percent,
                remaining_percent: used_percent.map(|value| 100u8.saturating_sub(value)),
                reset_at: extra
                    .get("resets_at")
                    .or_else(|| extra.get("reset_at"))
                    .and_then(parse_datetime),
                used,
                limit,
                unit: Some("credits".to_owned()),
                ..Default::default()
            });
        }
    }
    let fetched_at = OffsetDateTime::now_utc();
    for window in &mut windows {
        if matches!(
            window.key.as_str(),
            "seven_day" | "seven_day_sonnet" | "seven_day_opus"
        ) && let (Some(used_percent), Some(reset_at)) = (window.used_percent, window.reset_at)
            && let Some(pace) = super::pace::compute_pace(
                used_percent,
                reset_at,
                fetched_at,
                super::pace::WEEKLY_PERIOD,
            )
        {
            window.expected_used_percent = Some(pace.expected_percent);
            window.ahead_of_pace = Some(pace.ahead);
            window.projected_exhaustion_at = pace.projected_exhaustion_at;
            window.will_last_to_reset = Some(pace.will_last_to_reset);
        }
    }
    Ok(ProviderUsageView {
        provider: AiProvider::Claude,
        fetched_at,
        status: ProviderUsageStatus::Ok,
        fidelity: UsageFidelity::Official,
        headline_window: windows.first().map(|window| window.key.clone()),
        windows,
        plan_label: None,
        detail: None,
    })
}

impl ProviderAdapter for ClaudeAdapter {
    fn provider(&self) -> AiProvider {
        AiProvider::Claude
    }

    fn capabilities(&self) -> &'static [ProviderCapability] {
        CAPABILITIES
    }

    fn try_read_live_auth(&self, env: &AppEnv) -> Result<Option<ProviderAuthBundle>> {
        if !credentials_path(env).exists() && read_keychain_password().is_none() {
            return Ok(None);
        }
        self.read_live_auth(env).map(Some)
    }

    fn read_live_auth(&self, env: &AppEnv) -> Result<ProviderAuthBundle> {
        let mut files = Vec::new();
        let mut credentials_value = None;
        let path = credentials_path(env);
        if path.exists() {
            let bytes = fs::read(&path).with_context(|| {
                format!("failed to read Claude credentials at {}", path.display())
            })?;
            if let Ok(raw) = std::str::from_utf8(&bytes) {
                credentials_value = serde_json::from_str(raw).ok();
            }
            files.push(SnapshotFile {
                name: "claude_credentials.json".to_owned(),
                bytes_base64: base64::engine::general_purpose::STANDARD.encode(bytes),
            });
        }
        if let Some(password) = read_keychain_password() {
            if credentials_value.is_none() {
                credentials_value = serde_json::from_str(&password).ok();
            }
            files.push(SnapshotFile {
                name: "claude_keychain.txt".to_owned(),
                bytes_base64: base64::engine::general_purpose::STANDARD.encode(password.as_bytes()),
            });
        }
        let config_oauth = read_config_value(&config_path(env))
            .as_ref()
            .and_then(oauth_account_snapshot);
        if let Some(config) = &config_oauth {
            files.push(SnapshotFile {
                name: "claude_config.json".to_owned(),
                bytes_base64: base64::engine::general_purpose::STANDARD
                    .encode(config.to_string().as_bytes()),
            });
        }
        if files.is_empty() {
            bail!("Claude Code authentication was not found")
        }
        let identity =
            identity_from_bundle_parts(config_oauth.as_ref(), credentials_value.as_ref());
        Ok(ProviderAuthBundle {
            identity: identity.unwrap_or(DisplayIdentity {
                email: UNKNOWN_EMAIL.to_owned(),
                subject: None,
                name: None,
                plan_label: None,
            }),
            snapshot: SnapshotBlob {
                schema_version: SNAPSHOT_SCHEMA_VERSION,
                files,
            },
        })
    }

    fn try_read_live_identity_noninteractive(
        &self,
        env: &AppEnv,
    ) -> Result<Option<DisplayIdentity>> {
        let path = credentials_path(env);
        let credentials = if path.exists() {
            let raw = fs::read_to_string(&path).with_context(|| {
                format!("failed to read Claude credentials at {}", path.display())
            })?;
            serde_json::from_str::<Value>(&raw).ok()
        } else {
            None
        };
        let config = read_config_value(&config_path(env))
            .as_ref()
            .and_then(oauth_account_snapshot);
        Ok(identity_from_bundle_parts(
            config.as_ref(),
            credentials.as_ref(),
        ))
    }

    fn identity_from_snapshot(&self, snapshot: &SnapshotBlob) -> Result<DisplayIdentity> {
        let config = snapshot_text(snapshot, "claude_config.json")?
            .and_then(|raw| serde_json::from_str::<Value>(&raw).ok());
        for name in ["claude_credentials.json", "claude_keychain.txt"] {
            if let Some(raw) = snapshot_text(snapshot, name)?
                && let Ok(credentials) = serde_json::from_str::<Value>(&raw)
                && let Some(identity) =
                    identity_from_bundle_parts(config.as_ref(), Some(&credentials))
            {
                return Ok(identity);
            }
        }
        if let Some(identity) = identity_from_bundle_parts(config.as_ref(), None) {
            return Ok(identity);
        }
        bail!("Claude snapshot does not contain readable identity data")
    }

    fn acquire_switch_guard(&self, env: &AppEnv) -> Result<Box<dyn std::any::Any>> {
        struct SwitchGuard {
            _credentials: [super::claude_locks::LockGuard; 2],
            _config: super::claude_locks::LockGuard,
        }
        let credentials = super::claude_locks::credentials_lock(env)?;
        let config = super::claude_locks::config_lock(env)?;
        Ok(Box::new(SwitchGuard {
            _credentials: credentials,
            _config: config,
        }))
    }

    fn restore_snapshot(&self, env: &AppEnv, snapshot: &SnapshotBlob) -> Result<()> {
        let keychain_backed = cfg!(target_os = "macos")
            && snapshot
                .files
                .iter()
                .any(|file| file.name == "claude_keychain.txt");
        let file_creds = fs::read_to_string(credentials_path(env))
            .ok()
            .and_then(|raw| serde_json::from_str::<Value>(&raw).ok());
        let keychain_creds =
            || read_keychain_password().and_then(|raw| serde_json::from_str::<Value>(&raw).ok());
        let live_creds = if keychain_backed {
            keychain_creds().or(file_creds)
        } else {
            file_creds.or_else(keychain_creds)
        };
        let shared = shared_credential_fields(live_creds.as_ref());

        if let Some(raw) = snapshot_text(snapshot, "claude_credentials.json")? {
            let dir = claude_dir(env);
            fs::create_dir_all(&dir)
                .with_context(|| format!("failed to create {}", dir.display()))?;
            let merged = merge_shared_credential_fields(&raw, shared.as_ref());
            let path = credentials_path(env);
            write_atomic(&path, &merged, true)
                .with_context(|| format!("failed to restore {}", path.display()))?;
            // The snapshot uses a credentials file; ensure no stale Keychain
            // entry from a previous Keychain-backed account remains.  Claude
            // Code prefers Keychain when both exist, so leaving the old entry
            // would cause it to authenticate as the previous account.
            #[cfg(target_os = "macos")]
            if !keychain_backed {
                super::claude_keychain::delete_password(
                    super::claude_keychain::SERVICE,
                    &super::claude_keychain::account_name(),
                )
                .context("failed to remove stale Claude Keychain credentials")?;
            }
        }
        if cfg!(target_os = "macos")
            && let Some(password) = snapshot_text(snapshot, "claude_keychain.txt")?
        {
            let merged = merge_shared_credential_fields(&password, shared.as_ref());
            super::claude_keychain::set_password(
                super::claude_keychain::SERVICE,
                &super::claude_keychain::account_name(),
                &merged,
            )
            .context("failed to restore Claude Code credentials in the system keychain")?;
            // The snapshot uses Keychain; ensure no stale credentials file
            // from a previous file-backed account remains.  Claude Code reads
            // the file when no Keychain entry exists, so leaving it around
            // would cause reads to merge the stale file token.
            if snapshot_text(snapshot, "claude_credentials.json")?.is_none() {
                match fs::remove_file(credentials_path(env)) {
                    Ok(()) => {}
                    Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                    Err(error) => {
                        return Err(error)
                            .context("failed to remove stale Claude credentials file");
                    }
                }
            }
        }
        if let Some(raw) = snapshot_text(snapshot, "claude_config.json")? {
            let stored: Value = serde_json::from_str(&raw)
                .context("claude_config.json in snapshot is not valid JSON")?;
            let oauth_account = stored
                .get("oauthAccount")
                .cloned()
                .context("claude_config.json in snapshot has no oauthAccount")?;
            let path = config_path(env);
            let merged = match fs::read_to_string(&path) {
                Ok(existing_raw) => {
                    let mut existing: Value =
                        serde_json::from_str(&existing_raw).with_context(|| {
                            format!(
                                "{} is not valid JSON; refusing to overwrite it",
                                path.display()
                            )
                        })?;
                    let object = existing
                        .as_object_mut()
                        .with_context(|| format!("{} is not a JSON object", path.display()))?;
                    object.insert("oauthAccount".to_owned(), oauth_account);
                    existing
                }
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                    serde_json::json!({"oauthAccount": oauth_account})
                }
                Err(error) => {
                    return Err(error)
                        .with_context(|| format!("failed to read {}", path.display()));
                }
            };
            write_atomic(&path, &serde_json::to_string_pretty(&merged)?, true)
                .with_context(|| format!("failed to restore {}", path.display()))?;
        }
        Ok(())
    }

    fn snapshot_access_token_expired(&self, snapshot: &SnapshotBlob) -> bool {
        snapshot_access_token_expires_within(
            snapshot,
            Duration::from_millis(ACCESS_TOKEN_EXPIRY_BUFFER_MS as u64),
        )
    }

    fn snapshot_access_token_expires_within(
        &self,
        snapshot: &SnapshotBlob,
        within: Duration,
    ) -> bool {
        snapshot_access_token_expires_within(snapshot, within)
    }

    fn snapshot_shares_live_credential(&self, env: &AppEnv, snapshot: &SnapshotBlob) -> bool {
        snapshot_shares_live_credential(env, snapshot)
    }

    fn snapshots_share_credential(&self, a: &SnapshotBlob, b: &SnapshotBlob) -> bool {
        snapshots_share_credential(a, b)
    }

    fn refresh_snapshot(&self, snapshot: &SnapshotBlob) -> SnapshotRefresh {
        let Ok(Some((_name, raw))) = credential_text(snapshot) else {
            return SnapshotRefresh::Transient("snapshot has no Claude credential".to_owned());
        };
        let Ok(value) = serde_json::from_str::<Value>(&raw) else {
            return SnapshotRefresh::Transient(
                "stored Claude credential is not valid JSON".to_owned(),
            );
        };
        let Some(refresh_token) = value
            .get("claudeAiOauth")
            .and_then(|oauth| oauth.get("refreshToken"))
            .and_then(Value::as_str)
        else {
            return SnapshotRefresh::Dead("no_refresh_token".to_owned());
        };
        let request = serde_json::json!({
            "grant_type": "refresh_token",
            "refresh_token": refresh_token,
            "client_id": OAUTH_CLIENT_ID,
        });
        let (status, body) = match post_token_refresh(&request) {
            Ok(pair) => pair,
            Err(error) => return SnapshotRefresh::Transient(error.to_string()),
        };
        match classify_refresh_response(status, &body) {
            RefreshClass::Success(response) => match rotated_credential(&raw, &response) {
                Ok(rotated) => {
                    SnapshotRefresh::Refreshed(rewrite_credential_files(snapshot, &rotated))
                }
                Err(error) => SnapshotRefresh::Transient(error.to_string()),
            },
            RefreshClass::Dead(reason) => SnapshotRefresh::Dead(reason),
            RefreshClass::Transient(reason) => SnapshotRefresh::Transient(reason),
        }
    }

    fn fetch_usage(&self, snapshot: &SnapshotBlob) -> Result<ProviderUsageView> {
        let token = access_token_from_snapshot(snapshot)?;
        let mut response = ureq::get(OAUTH_USAGE_URL)
            .header("Authorization", &format!("Bearer {token}"))
            .header("anthropic-beta", "oauth-2025-04-20")
            .header("Accept", "application/json")
            .header("Content-Type", "application/json")
            .header("User-Agent", claude_code_user_agent())
            .config()
            .http_status_as_error(false)
            .timeout_global(Some(Duration::from_secs(15)))
            .build()
            .call()
            .context("Claude usage request failed")?;
        let status = response.status().as_u16();
        let body = response
            .body_mut()
            .read_to_string()
            .context("failed to read Claude usage response")?;
        if status == 401 {
            return Ok(status_view(ProviderUsageStatus::CredentialExpired, status));
        }
        if status == 403 {
            return Ok(status_view(ProviderUsageStatus::AccessDenied, status));
        }
        if status == 429 {
            return Ok(status_view(ProviderUsageStatus::RateLimited, status));
        }
        if !(200..300).contains(&status) {
            bail!("Claude usage endpoint returned HTTP {status}")
        }
        parse_usage(&body)
    }
}

/// `claude-code/<version>` like the real CLI, detected once per process.
/// Detection never blocks usage: any failure falls back to a pinned version.
fn claude_code_user_agent() -> &'static str {
    static USER_AGENT: std::sync::OnceLock<String> = std::sync::OnceLock::new();
    USER_AGENT.get_or_init(|| {
        let version =
            detect_claude_code_version().unwrap_or_else(|| FALLBACK_CLAUDE_CODE_VERSION.to_owned());
        format!("claude-code/{version}")
    })
}

fn detect_claude_code_version() -> Option<String> {
    let binary = claude_binary_path()?;
    let output = std::process::Command::new(binary)
        .arg("--version")
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    stdout
        .split_whitespace()
        .next()
        .filter(|token| !token.is_empty())
        .map(str::to_owned)
}

fn claude_binary_path() -> Option<PathBuf> {
    let mut candidates: Vec<PathBuf> = std::env::var_os("PATH")
        .map(|paths| {
            std::env::split_paths(&paths)
                .map(|dir| dir.join("claude"))
                .collect()
        })
        .unwrap_or_default();
    if let Some(home) = std::env::var_os("HOME").map(PathBuf::from) {
        candidates.push(home.join(".local/bin/claude"));
        candidates.push(home.join(".claude/local/claude"));
    }
    candidates.push(PathBuf::from("/usr/local/bin/claude"));
    candidates.push(PathBuf::from("/opt/homebrew/bin/claude"));
    candidates.into_iter().find(|path| path.is_file())
}

fn status_view(status: ProviderUsageStatus, http_status: u16) -> ProviderUsageView {
    ProviderUsageView {
        provider: AiProvider::Claude,
        fetched_at: OffsetDateTime::now_utc(),
        status,
        fidelity: UsageFidelity::Official,
        headline_window: None,
        windows: Vec::new(),
        plan_label: None,
        detail: Some(format!("Claude usage endpoint returned HTTP {http_status}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_claude_identity_and_usage_windows() {
        let identity = identity_from_json(
            r#"{"claudeAiOauth":{"email":"ada@example.com","accountUuid":"acct-1","subscriptionType":"pro","accessToken":"token"}}"#,
        )
        .expect("identity");
        assert_eq!(identity.email, "ada@example.com");
        assert_eq!(identity.subject.as_deref(), Some("acct-1"));
        assert_eq!(identity.plan_label.as_deref(), Some("Pro"));

        let usage = parse_usage(
            r#"{"five_hour":{"utilization":12.4,"resets_at":"2026-09-06T10:00:00Z"},"seven_day":{"utilization":55.0,"resets_at":"2026-09-12T00:00:00Z"}}"#,
        )
        .expect("usage");
        assert_eq!(usage.windows.len(), 2);
        assert_eq!(usage.windows[0].used_percent, Some(12));
    }

    #[test]
    fn weekly_windows_report_pace() {
        use time::format_description::well_known::Rfc3339;

        let reset = (OffsetDateTime::now_utc() + time::Duration::days(4))
            .format(&Rfc3339)
            .expect("format");
        let body = format!(
            r#"{{"five_hour":{{"utilization":50.0,"resets_at":"{reset}"}},"seven_day":{{"utilization":30.0,"resets_at":"{reset}"}}}}"#
        );
        let usage = parse_usage(&body).expect("usage");
        let weekly = usage
            .windows
            .iter()
            .find(|window| window.key == "seven_day")
            .expect("weekly window");
        assert_eq!(weekly.expected_used_percent, Some(43));
        assert_eq!(weekly.ahead_of_pace, Some(false));
        assert_eq!(weekly.will_last_to_reset, Some(true));
        assert!(weekly.projected_exhaustion_at.is_some());
        let five_hour = usage
            .windows
            .iter()
            .find(|window| window.key == "five_hour")
            .expect("five hour window");
        assert_eq!(five_hour.expected_used_percent, None);
        assert_eq!(five_hour.ahead_of_pace, None);
        assert_eq!(five_hour.projected_exhaustion_at, None);
        assert_eq!(five_hour.will_last_to_reset, None);
    }

    #[test]
    fn usage_accepts_numeric_strings_without_inventing_credit_balance() {
        let usage = parse_usage(
            r#"{"five_hour":{"utilization":"45"},"extra_usage":{"used_credits":"25","monthly_limit":"100"}}"#,
        )
        .expect("usage");
        assert_eq!(usage.windows[0].used_percent, Some(45));
        let extra = usage
            .windows
            .iter()
            .find(|window| window.key == "extra_usage")
            .unwrap();
        assert_eq!(extra.used, Some(25.0));
        assert_eq!(extra.limit, Some(100.0));
        assert_eq!(extra.remaining_percent, Some(75));
    }

    fn test_env() -> (tempfile::TempDir, AppEnv) {
        let temp = tempfile::tempdir().expect("temp dir");
        let env = AppEnv {
            kind: crate::model::EnvironmentKind::Macos,
            home_dir: temp.path().to_path_buf(),
            codex_root: temp.path().join(".codex"),
            app_data_dir: temp.path().join("data"),
        };
        (temp, env)
    }

    fn snapshot_with(files: &[(&str, &str)]) -> SnapshotBlob {
        SnapshotBlob {
            schema_version: SNAPSHOT_SCHEMA_VERSION,
            files: files
                .iter()
                .map(|(name, raw)| SnapshotFile {
                    name: (*name).to_owned(),
                    bytes_base64: base64::engine::general_purpose::STANDARD.encode(raw),
                })
                .collect(),
        }
    }

    #[test]
    fn identity_prefers_oauth_account_email_and_uuid() {
        let config: Value = serde_json::from_str(
            r#"{"oauthAccount":{"emailAddress":"ada@example.com","accountUuid":"acct-9","organizationName":"Acme"}}"#,
        )
        .expect("config");
        let credentials: Value = serde_json::from_str(
            r#"{"claudeAiOauth":{"accessToken":"token","subscriptionType":"max"}}"#,
        )
        .expect("credentials");
        let identity =
            identity_from_bundle_parts(Some(&config), Some(&credentials)).expect("identity");
        assert_eq!(identity.email, "ada@example.com");
        assert_eq!(identity.subject.as_deref(), Some("acct-9"));
        assert_eq!(identity.name.as_deref(), Some("Acme"));
        assert_eq!(identity.plan_label.as_deref(), Some("Max"));
    }

    #[test]
    fn restore_splices_oauth_account_preserving_other_keys() {
        let (_temp, env) = test_env();
        fs::write(
            config_path(&env),
            r#"{"projects":{"/a":{}},"mcpServers":{"s":{}},"oauthAccount":{"emailAddress":"old@x"}}"#,
        )
        .expect("config");
        let snapshot = snapshot_with(&[
            (
                "claude_credentials.json",
                r#"{"claudeAiOauth":{"accessToken":"new"}}"#,
            ),
            (
                "claude_config.json",
                r#"{"oauthAccount":{"emailAddress":"new@x","accountUuid":"u-1"}}"#,
            ),
        ]);

        CLAUDE.restore_snapshot(&env, &snapshot).expect("restore");

        let config: Value =
            serde_json::from_str(&fs::read_to_string(config_path(&env)).expect("config"))
                .expect("parse config");
        assert_eq!(config["oauthAccount"]["emailAddress"], "new@x");
        assert!(config["projects"].is_object());
        assert!(config["mcpServers"].is_object());
        let credentials: Value =
            serde_json::from_str(&fs::read_to_string(credentials_path(&env)).expect("credentials"))
                .expect("parse credentials");
        assert_eq!(credentials["claudeAiOauth"]["accessToken"], "new");
    }

    #[test]
    fn restore_refuses_unparseable_claude_json() {
        let (_temp, env) = test_env();
        fs::write(config_path(&env), "{not json").expect("config");
        let snapshot = snapshot_with(&[(
            "claude_config.json",
            r#"{"oauthAccount":{"emailAddress":"new@x"}}"#,
        )]);

        assert!(CLAUDE.restore_snapshot(&env, &snapshot).is_err());
        assert_eq!(
            fs::read_to_string(config_path(&env)).expect("config"),
            "{not json"
        );
    }

    #[test]
    fn restore_merges_live_shared_mcp_fields() {
        let (_temp, env) = test_env();
        let dir = claude_dir(&env);
        fs::create_dir_all(&dir).expect("claude dir");
        fs::write(
            credentials_path(&env),
            r#"{"claudeAiOauth":{"accessToken":"old"},"mcpOAuth":{"token":"live"},"pluginSecrets":null}"#,
        )
        .expect("live credentials");
        // Live has mcpOAuth but no pluginSecrets rewrite check below uses a
        // second fixture without pluginSecrets; first fixture asserts live wins.
        let snapshot = snapshot_with(&[(
            "claude_credentials.json",
            r#"{"claudeAiOauth":{"accessToken":"new"},"mcpOAuth":{"token":"stale"},"pluginSecrets":{"k":"v"}}"#,
        )]);

        CLAUDE.restore_snapshot(&env, &snapshot).expect("restore");

        let written: Value =
            serde_json::from_str(&fs::read_to_string(credentials_path(&env)).expect("credentials"))
                .expect("parse");
        assert_eq!(written["claudeAiOauth"]["accessToken"], "new");
        assert_eq!(written["mcpOAuth"]["token"], "live");

        // Live credential without pluginSecrets drops the slot's copy.
        fs::write(
            credentials_path(&env),
            r#"{"claudeAiOauth":{"accessToken":"old"},"mcpOAuth":{"token":"live2"}}"#,
        )
        .expect("live credentials");
        let snapshot = snapshot_with(&[(
            "claude_credentials.json",
            r#"{"claudeAiOauth":{"accessToken":"new2"},"pluginSecrets":{"k":"v"}}"#,
        )]);
        CLAUDE.restore_snapshot(&env, &snapshot).expect("restore");
        let written: Value =
            serde_json::from_str(&fs::read_to_string(credentials_path(&env)).expect("credentials"))
                .expect("parse");
        assert_eq!(written["mcpOAuth"]["token"], "live2");
        assert!(written.get("pluginSecrets").is_none());
    }

    #[test]
    fn snapshot_access_token_expired_checks_expires_at() {
        let expired = snapshot_with(&[(
            "claude_credentials.json",
            r#"{"claudeAiOauth":{"accessToken":"a","expiresAt":1}}"#,
        )]);
        assert!(CLAUDE.snapshot_access_token_expired(&expired));

        let fresh_until = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap()
            .as_millis() as i64
            + 3_600_000;
        let fresh = snapshot_with(&[(
            "claude_credentials.json",
            &format!(r#"{{"claudeAiOauth":{{"accessToken":"a","expiresAt":{fresh_until}}}}}"#),
        )]);
        assert!(!CLAUDE.snapshot_access_token_expired(&fresh));

        let missing = snapshot_with(&[(
            "claude_credentials.json",
            r#"{"claudeAiOauth":{"accessToken":"a"}}"#,
        )]);
        assert!(!CLAUDE.snapshot_access_token_expired(&missing));
    }

    #[test]
    fn refresh_missing_refresh_token_is_dead() {
        let snapshot = snapshot_with(&[(
            "claude_credentials.json",
            r#"{"claudeAiOauth":{"accessToken":"a","expiresAt":1}}"#,
        )]);
        match CLAUDE.refresh_snapshot(&snapshot) {
            SnapshotRefresh::Dead(reason) => assert_eq!(reason, "no_refresh_token"),
            _ => panic!("expected Dead"),
        }
    }

    #[test]
    fn classify_refresh_response_distinguishes_dead_and_transient() {
        match classify_refresh_response(400, r#"{"error":"invalid_grant"}"#) {
            RefreshClass::Dead(reason) => assert_eq!(reason, "invalid_grant"),
            _ => panic!("expected Dead"),
        }
        match classify_refresh_response(400, r#"{"error":"invalid_client"}"#) {
            RefreshClass::Transient(_) => {}
            _ => panic!("expected Transient"),
        }
        match classify_refresh_response(500, "oops") {
            RefreshClass::Transient(_) => {}
            _ => panic!("expected Transient"),
        }
    }

    #[cfg(unix)]
    #[test]
    fn atomic_write_creates_private_credentials_and_config() {
        use std::os::unix::fs::PermissionsExt;
        let temp = tempfile::tempdir().expect("tempdir");
        for name in [".credentials.json", ".claude.json"] {
            let path = temp.path().join(name);
            write_atomic(&path, "fixture-secret", true).expect("write");
            assert_eq!(
                fs::metadata(&path).unwrap().permissions().mode() & 0o777,
                0o600
            );
            assert_eq!(fs::read_to_string(path).unwrap(), "fixture-secret");
        }
    }

    #[test]
    fn refresh_success_rotates_both_credential_files() {
        let snapshot = snapshot_with(&[
            (
                "claude_credentials.json",
                r#"{"claudeAiOauth":{"accessToken":"old","refreshToken":"rt1","expiresAt":1}}"#,
            ),
            (
                "claude_keychain.txt",
                r#"{"claudeAiOauth":{"accessToken":"old","refreshToken":"rt1","expiresAt":1}}"#,
            ),
            (
                "claude_config.json",
                r#"{"oauthAccount":{"emailAddress":"a@x"}}"#,
            ),
        ]);
        let response: Value = serde_json::from_str(
            r#"{"access_token":"new-at","expires_in":3600,"refresh_token":"rt2","scope":"a b"}"#,
        )
        .expect("response");
        let rotated =
            rotated_credential("{\"claudeAiOauth\":{\"accessToken\":\"old\",\"refreshToken\":\"rt1\",\"expiresAt\":1}}", &response)
                .expect("rotate");
        let new_snapshot = rewrite_credential_files(&snapshot, &rotated);

        for name in ["claude_credentials.json", "claude_keychain.txt"] {
            let raw = snapshot_text(&new_snapshot, name)
                .expect("text")
                .expect("file");
            let value: Value = serde_json::from_str(&raw).expect("parse");
            let oauth = &value["claudeAiOauth"];
            assert_eq!(oauth["accessToken"], "new-at");
            assert_eq!(oauth["refreshToken"], "rt2");
            assert_eq!(oauth["scopes"], serde_json::json!(["a", "b"]));
            assert!(oauth["expiresAt"].as_i64().unwrap() > 1);
        }
        let config_raw = snapshot_text(&new_snapshot, "claude_config.json")
            .expect("text")
            .expect("file");
        assert_eq!(config_raw, r#"{"oauthAccount":{"emailAddress":"a@x"}}"#);
    }

    #[test]
    fn snapshot_shares_live_credential_compares_tokens() {
        let (_temp, env) = test_env();
        let dir = claude_dir(&env);
        fs::create_dir_all(&dir).expect("claude dir");
        fs::write(
            credentials_path(&env),
            r#"{"claudeAiOauth":{"accessToken":"live-at","refreshToken":"live-rt"}}"#,
        )
        .expect("live credentials");

        let same = snapshot_with(&[(
            "claude_credentials.json",
            r#"{"claudeAiOauth":{"accessToken":"other-at","refreshToken":"live-rt"}}"#,
        )]);
        assert!(CLAUDE.snapshot_shares_live_credential(&env, &same));

        let different = snapshot_with(&[(
            "claude_credentials.json",
            r#"{"claudeAiOauth":{"accessToken":"other-at","refreshToken":"other-rt"}}"#,
        )]);
        assert!(!CLAUDE.snapshot_shares_live_credential(&env, &different));
    }

    #[test]
    fn snapshot_shares_live_credential_fails_safe_when_live_missing() {
        let (_temp, env) = test_env();
        let snapshot = snapshot_with(&[(
            "claude_credentials.json",
            r#"{"claudeAiOauth":{"accessToken":"a","refreshToken":"r"}}"#,
        )]);
        assert!(CLAUDE.snapshot_shares_live_credential(&env, &snapshot));
    }
}
