use std::fs;
use std::path::PathBuf;
use std::sync::mpsc;
use std::thread;
use std::time::Duration;

use anyhow::{Context, Result, bail};
use base64::Engine;
use serde_json::Value;
use time::OffsetDateTime;

use super::{ProviderAdapter, ProviderAuthBundle, find_string, parse_datetime, percent_window};
use crate::env::AppEnv;
use crate::model::{
    AiProvider, DisplayIdentity, ProviderCapability, ProviderUsageStatus, ProviderUsageView,
    SNAPSHOT_SCHEMA_VERSION, SnapshotBlob, SnapshotFile, UsageFidelity,
};

pub struct ClaudeAdapter;
pub static CLAUDE: ClaudeAdapter = ClaudeAdapter;

const UNKNOWN_EMAIL: &str = "claude-user@unknown.local";
const OAUTH_USAGE_URL: &str = "https://api.anthropic.com/api/oauth/usage";
const KEYCHAIN_SERVICE: &str = "Claude Code-credentials";
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

fn local_username() -> Option<String> {
    std::env::var("USER")
        .or_else(|_| std::env::var("USERNAME"))
        .ok()
        .filter(|value| !value.is_empty())
}

fn read_keychain_password_blocking() -> Option<String> {
    let username = local_username()?;
    keyring::Entry::new(KEYCHAIN_SERVICE, &username)
        .ok()?
        .get_password()
        .ok()
}

fn read_keychain_password(timeout: Duration) -> Option<String> {
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || {
        let _ = tx.send(read_keychain_password_blocking());
    });
    rx.recv_timeout(timeout).ok().flatten()
}

fn oauth_object(value: &Value) -> &Value {
    value.get("claudeAiOauth").unwrap_or(value)
}

fn identity_from_json(raw: &str) -> Option<DisplayIdentity> {
    let value: Value = serde_json::from_str(raw).ok()?;
    let oauth = oauth_object(&value);
    let email = find_string(oauth, &["email"])
        .or_else(|| find_string(&value, &["email"]))
        .unwrap_or_else(|| UNKNOWN_EMAIL.to_owned());
    let subject = find_string(
        oauth,
        &["accountUuid", "account_uuid", "userId", "user_id", "sub"],
    )
    .or_else(|| {
        access_token_from_value(&value)
            .and_then(|token| super::decode_jwt_claims(&token))
            .and_then(|claims| find_string(&claims, &["sub"]))
    });
    let plan_label = find_string(oauth, &["subscriptionType", "subscription_type"])
        .or_else(|| find_string(&value, &["subscriptionType", "subscription_type"]))
        .map(|value| normalize_plan(&value));
    let name = find_string(oauth, &["name", "displayName"])
        .or_else(|| find_string(&value, &["name", "displayName"]));
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

fn access_token_from_snapshot(snapshot: &SnapshotBlob) -> Result<String> {
    for name in ["claude_credentials.json", "claude_keychain.txt"] {
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

fn usage_window(
    key: &str,
    label: &str,
    value: Option<&Value>,
) -> Option<crate::model::ProviderUsageWindowView> {
    let value = value?;
    let used = value
        .get("utilization")
        .and_then(Value::as_f64)
        .or_else(|| value.get("used_percent").and_then(Value::as_f64))?;
    let reset_at = value
        .get("resets_at")
        .or_else(|| value.get("reset_at"))
        .and_then(parse_datetime);
    Some(percent_window(key, label, used, reset_at))
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
            .and_then(Value::as_f64)
            .or_else(|| extra.get("used").and_then(Value::as_f64));
        let limit = extra
            .get("monthly_limit")
            .and_then(Value::as_f64)
            .or_else(|| extra.get("limit").and_then(Value::as_f64));
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
            });
        }
    }
    Ok(ProviderUsageView {
        provider: AiProvider::Claude,
        fetched_at: OffsetDateTime::now_utc(),
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
        if !credentials_path(env).exists()
            && read_keychain_password(Duration::from_millis(800)).is_none()
        {
            return Ok(None);
        }
        self.read_live_auth(env).map(Some)
    }

    fn read_live_auth(&self, env: &AppEnv) -> Result<ProviderAuthBundle> {
        let mut files = Vec::new();
        let mut identity = None;
        let path = credentials_path(env);
        if path.exists() {
            let bytes = fs::read(&path).with_context(|| {
                format!("failed to read Claude credentials at {}", path.display())
            })?;
            if let Ok(raw) = std::str::from_utf8(&bytes) {
                identity = identity_from_json(raw);
            }
            files.push(SnapshotFile {
                name: "claude_credentials.json".to_owned(),
                bytes_base64: base64::engine::general_purpose::STANDARD.encode(bytes),
            });
        }
        if let Some(password) = read_keychain_password(Duration::from_millis(800)) {
            if identity.is_none() {
                identity = identity_from_json(&password);
            }
            files.push(SnapshotFile {
                name: "claude_keychain.txt".to_owned(),
                bytes_base64: base64::engine::general_purpose::STANDARD.encode(password.as_bytes()),
            });
        }
        if files.is_empty() {
            bail!("Claude Code authentication was not found")
        }
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
        if !path.exists() {
            return Ok(None);
        }
        let raw = fs::read_to_string(&path)
            .with_context(|| format!("failed to read Claude credentials at {}", path.display()))?;
        Ok(identity_from_json(&raw))
    }

    fn identity_from_snapshot(&self, snapshot: &SnapshotBlob) -> Result<DisplayIdentity> {
        for name in ["claude_credentials.json", "claude_keychain.txt"] {
            if let Some(raw) = snapshot_text(snapshot, name)?
                && let Some(identity) = identity_from_json(&raw)
            {
                return Ok(identity);
            }
        }
        bail!("Claude snapshot does not contain readable identity data")
    }

    fn restore_snapshot(&self, env: &AppEnv, snapshot: &SnapshotBlob) -> Result<()> {
        if let Some(raw) = snapshot_text(snapshot, "claude_credentials.json")? {
            let dir = claude_dir(env);
            fs::create_dir_all(&dir)
                .with_context(|| format!("failed to create {}", dir.display()))?;
            let path = credentials_path(env);
            fs::write(&path, raw.as_bytes())
                .with_context(|| format!("failed to restore {}", path.display()))?;
        }
        if let Some(password) = snapshot_text(snapshot, "claude_keychain.txt")? {
            let username = local_username().context("could not determine local username")?;
            keyring::Entry::new(KEYCHAIN_SERVICE, &username)?
                .set_password(&password)
                .context("failed to restore Claude Code credentials in the system keychain")?;
        }
        Ok(())
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
}
