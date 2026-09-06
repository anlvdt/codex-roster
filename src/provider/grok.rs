use std::fs;
use std::path::PathBuf;
use std::time::Duration;

use anyhow::{Context, Result, bail};
use base64::Engine;
use serde_json::Value;
use time::OffsetDateTime;

use super::{
    ProviderAdapter, ProviderAuthBundle, decode_jwt_claims, find_number, find_string, find_value,
    parse_datetime, percent_window,
};
use crate::env::AppEnv;
use crate::model::{
    AiProvider, DisplayIdentity, ProviderCapability, ProviderUsageStatus, ProviderUsageView,
    SNAPSHOT_SCHEMA_VERSION, SnapshotBlob, SnapshotFile, UsageFidelity,
};

pub struct GrokAdapter;
pub static GROK: GrokAdapter = GrokAdapter;

const BILLING_URL: &str = "https://cli-chat-proxy.grok.com/v1/billing?format=credits";
const CAPABILITIES: &[ProviderCapability] = &[
    ProviderCapability::ReadIdentity,
    ProviderCapability::MonitorUsage,
    ProviderCapability::SnapshotAuth,
    ProviderCapability::SwitchAccount,
    ProviderCapability::ApiBilling,
];

fn grok_home(env: &AppEnv) -> PathBuf {
    std::env::var_os("GROK_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| env.home_dir.join(".grok"))
}

fn auth_path(env: &AppEnv) -> PathBuf {
    grok_home(env).join("auth.json")
}

fn grok_auth_entry(value: &Value) -> Option<&Value> {
    let entries = value.as_object()?;
    entries.iter().find_map(|(scope, entry)| {
        let object = entry.as_object()?;
        let issuer = object.get("oidc_issuer").and_then(Value::as_str);
        let is_xai_scope = scope.starts_with("https://auth.x.ai::")
            || issuer.is_some_and(|issuer| issuer.trim_end_matches('/') == "https://auth.x.ai");
        let has_key = object
            .get("key")
            .and_then(Value::as_str)
            .is_some_and(|key| !key.trim().is_empty());
        (is_xai_scope && has_key).then_some(entry)
    })
}

fn access_token(value: &Value) -> Option<String> {
    if let Some(entry) = grok_auth_entry(value) {
        return entry
            .get("key")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|key| !key.is_empty())
            .map(str::to_owned);
    }
    find_string(
        value,
        &[
            "access_token",
            "accessToken",
            "id_token",
            "idToken",
            "token",
        ],
    )
}

fn identity_from_value(value: &Value) -> DisplayIdentity {
    let identity_value = grok_auth_entry(value).unwrap_or(value);
    let token_claims = access_token(value).and_then(|token| decode_jwt_claims(&token));
    let email = find_string(identity_value, &["email"])
        .or_else(|| {
            token_claims
                .as_ref()
                .and_then(|claims| find_string(claims, &["email"]))
        })
        .unwrap_or_else(|| "grok-user@unknown.local".to_owned());
    let subject = find_string(identity_value, &["user_id", "userId", "sub"]).or_else(|| {
        token_claims
            .as_ref()
            .and_then(|claims| find_string(claims, &["sub"]))
    });
    let name = find_string(identity_value, &["name", "display_name", "displayName"])
        .or_else(|| {
            let first = find_string(identity_value, &["first_name"]);
            let last = find_string(identity_value, &["last_name"]);
            match (first, last) {
                (Some(first), Some(last)) => Some(format!("{first} {last}")),
                (Some(name), None) | (None, Some(name)) => Some(name),
                (None, None) => None,
            }
        })
        .or_else(|| {
            token_claims
                .as_ref()
                .and_then(|claims| find_string(claims, &["name"]))
        });
    let plan_label = find_string(identity_value, &["plan", "plan_name", "subscription"]);
    DisplayIdentity {
        email,
        subject,
        name,
        plan_label,
    }
}

fn parse_usage(body: &str) -> Result<ProviderUsageView> {
    let value: Value = serde_json::from_str(body).context("failed to parse Grok billing JSON")?;
    let reset_at = find_value(
        &value,
        &[
            "billingPeriodEnd",
            "billing_period_end",
            "resetAt",
            "reset_at",
        ],
    )
    .and_then(parse_datetime);
    let used_percent = find_number(
        &value,
        &[
            "usagePercent",
            "usage_percentage",
            "percentUsed",
            "usedPercent",
        ],
    );
    let remaining_percent = find_number(
        &value,
        &[
            "remainingPercent",
            "remaining_percentage",
            "percentRemaining",
        ],
    );
    let percent = used_percent.or_else(|| remaining_percent.map(|remaining| 100.0 - remaining));
    let mut windows = Vec::new();
    if let Some(percent) = percent {
        windows.push(percent_window("credits", "Credits", percent, reset_at));
    } else {
        let used = find_number(&value, &["usedCredits", "used_credits", "creditsUsed"]);
        let limit = find_number(&value, &["totalCredits", "creditLimit", "limit"]);
        if used.is_some() || limit.is_some() {
            let used_percent = match (used, limit) {
                (Some(used), Some(limit)) if limit > 0.0 => {
                    Some(((used / limit) * 100.0).clamp(0.0, 100.0).round() as u8)
                }
                _ => None,
            };
            windows.push(crate::model::ProviderUsageWindowView {
                key: "credits".to_owned(),
                label: "Credits".to_owned(),
                used_percent,
                remaining_percent: used_percent.map(|value| 100u8.saturating_sub(value)),
                reset_at,
                used,
                limit,
                unit: Some("credits".to_owned()),
            });
        }
    }
    Ok(ProviderUsageView {
        provider: AiProvider::Grok,
        fetched_at: OffsetDateTime::now_utc(),
        status: ProviderUsageStatus::Ok,
        fidelity: UsageFidelity::Official,
        headline_window: windows.first().map(|window| window.key.clone()),
        windows,
        plan_label: find_string(&value, &["plan", "planName", "subscription"]),
        detail: None,
    })
}

impl ProviderAdapter for GrokAdapter {
    fn provider(&self) -> AiProvider {
        AiProvider::Grok
    }

    fn capabilities(&self) -> &'static [ProviderCapability] {
        CAPABILITIES
    }

    fn try_read_live_auth(&self, env: &AppEnv) -> Result<Option<ProviderAuthBundle>> {
        if !auth_path(env).exists() {
            return Ok(None);
        }
        self.read_live_auth(env).map(Some)
    }

    fn read_live_auth(&self, env: &AppEnv) -> Result<ProviderAuthBundle> {
        let path = auth_path(env);
        let bytes = fs::read(&path)
            .with_context(|| format!("failed to read Grok auth at {}", path.display()))?;
        let value: Value =
            serde_json::from_slice(&bytes).context("failed to parse Grok auth.json")?;
        if access_token(&value).is_none() {
            bail!("Grok access token was not found in {}", path.display())
        }
        Ok(ProviderAuthBundle {
            identity: identity_from_value(&value),
            snapshot: SnapshotBlob {
                schema_version: SNAPSHOT_SCHEMA_VERSION,
                files: vec![SnapshotFile {
                    name: "grok_auth.json".to_owned(),
                    bytes_base64: base64::engine::general_purpose::STANDARD.encode(bytes),
                }],
            },
        })
    }

    fn identity_from_snapshot(&self, snapshot: &SnapshotBlob) -> Result<DisplayIdentity> {
        let value = value_from_snapshot(snapshot)?;
        Ok(identity_from_value(&value))
    }

    fn restore_snapshot(&self, env: &AppEnv, snapshot: &SnapshotBlob) -> Result<()> {
        let file = snapshot
            .files
            .iter()
            .find(|file| file.name == "grok_auth.json")
            .context("snapshot missing grok_auth.json")?;
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(&file.bytes_base64)
            .context("failed to decode grok_auth.json")?;
        let directory = grok_home(env);
        fs::create_dir_all(&directory)
            .with_context(|| format!("failed to create {}", directory.display()))?;
        let path = auth_path(env);
        let temp = path.with_extension("json.tmp");
        fs::write(&temp, &bytes).with_context(|| format!("failed to write {}", temp.display()))?;
        fs::rename(&temp, &path)
            .with_context(|| format!("failed to replace {}", path.display()))?;
        Ok(())
    }

    fn fetch_usage(&self, snapshot: &SnapshotBlob) -> Result<ProviderUsageView> {
        let value = value_from_snapshot(snapshot)?;
        let token = access_token(&value).context("Grok access token missing from snapshot")?;
        let mut response = ureq::get(BILLING_URL)
            .header("Authorization", &format!("Bearer {token}"))
            .header("x-xai-token-auth", "xai-grok-cli")
            .header("Accept", "application/json")
            .header("User-Agent", "grok")
            .config()
            .http_status_as_error(false)
            .timeout_global(Some(Duration::from_secs(15)))
            .build()
            .call()
            .context("Grok billing request failed")?;
        let status = response.status().as_u16();
        let body = response
            .body_mut()
            .read_to_string()
            .context("failed to read Grok billing response")?;
        let provider_status = match status {
            401 => Some(ProviderUsageStatus::CredentialExpired),
            403 => Some(ProviderUsageStatus::AccessDenied),
            429 => Some(ProviderUsageStatus::RateLimited),
            _ => None,
        };
        if let Some(provider_status) = provider_status {
            return Ok(ProviderUsageView {
                provider: AiProvider::Grok,
                fetched_at: OffsetDateTime::now_utc(),
                status: provider_status,
                fidelity: UsageFidelity::Official,
                headline_window: None,
                windows: Vec::new(),
                plan_label: None,
                detail: Some(format!("Grok billing endpoint returned HTTP {status}")),
            });
        }
        if !(200..300).contains(&status) {
            bail!("Grok billing endpoint returned HTTP {status}")
        }
        parse_usage(&body)
    }
}

fn value_from_snapshot(snapshot: &SnapshotBlob) -> Result<Value> {
    let file = snapshot
        .files
        .iter()
        .find(|file| file.name == "grok_auth.json")
        .context("snapshot missing grok_auth.json")?;
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(&file.bytes_base64)
        .context("failed to decode grok_auth.json")?;
    serde_json::from_slice(&bytes).context("failed to parse grok_auth.json")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_grok_identity_and_credit_usage() {
        let identity = identity_from_value(&serde_json::json!({
            "email": "ada@example.com",
            "userId": "user-1",
            "accessToken": "token"
        }));
        assert_eq!(identity.email, "ada@example.com");
        assert_eq!(identity.subject.as_deref(), Some("user-1"));

        let usage =
            parse_usage(r#"{"usagePercent":31.0,"billingPeriodEnd":"2026-10-01T00:00:00Z"}"#)
                .expect("usage");
        assert_eq!(usage.windows[0].remaining_percent, Some(69));
    }

    #[test]
    fn parses_scoped_grok_oidc_auth_entry() {
        let auth = serde_json::json!({
            "https://auth.x.ai::client-id": {
                "auth_mode": "Oidc",
                "email": "ada@example.com",
                "first_name": "Ada",
                "last_name": "Lovelace",
                "user_id": "user-1",
                "oidc_client_id": "client-id",
                "oidc_issuer": "https://auth.x.ai",
                "key": "session-token",
                "refresh_token": "refresh-token"
            }
        });

        assert_eq!(access_token(&auth).as_deref(), Some("session-token"));
        let identity = identity_from_value(&auth);
        assert_eq!(identity.email, "ada@example.com");
        assert_eq!(identity.subject.as_deref(), Some("user-1"));
        assert_eq!(identity.name.as_deref(), Some("Ada Lovelace"));
    }
}
