use anyhow::Result;

use crate::env::AppEnv;
use crate::model::{
    AiProvider, DisplayIdentity, ProviderCapability, ProviderUsageView, SnapshotBlob,
};

mod claude;
mod cursor;
mod grok;
mod openai;

pub struct ProviderAuthBundle {
    pub identity: DisplayIdentity,
    pub snapshot: SnapshotBlob,
}

pub trait ProviderAdapter: Sync {
    fn provider(&self) -> AiProvider;
    fn capabilities(&self) -> &'static [ProviderCapability];
    fn try_read_live_auth(&self, env: &AppEnv) -> Result<Option<ProviderAuthBundle>>;
    fn read_live_auth(&self, env: &AppEnv) -> Result<ProviderAuthBundle>;
    fn identity_from_snapshot(&self, snapshot: &SnapshotBlob) -> Result<DisplayIdentity>;
    fn restore_snapshot(&self, env: &AppEnv, snapshot: &SnapshotBlob) -> Result<()>;
    fn fetch_usage(&self, snapshot: &SnapshotBlob) -> Result<ProviderUsageView>;

    fn requires_relaunch_after_switch(&self) -> bool {
        false
    }
}

pub fn adapter(provider: AiProvider) -> &'static dyn ProviderAdapter {
    match provider {
        AiProvider::OpenAi => &openai::OPENAI,
        AiProvider::Claude => &claude::CLAUDE,
        AiProvider::Cursor => &cursor::CURSOR,
        AiProvider::Grok => &grok::GROK,
    }
}

pub fn all() -> impl Iterator<Item = &'static dyn ProviderAdapter> {
    AiProvider::ALL.into_iter().map(adapter)
}

pub(crate) fn percent_window(
    key: impl Into<String>,
    label: impl Into<String>,
    used_percent: f64,
    reset_at: Option<time::OffsetDateTime>,
) -> crate::model::ProviderUsageWindowView {
    let used = used_percent.clamp(0.0, 100.0).round() as u8;
    crate::model::ProviderUsageWindowView {
        key: key.into(),
        label: label.into(),
        used_percent: Some(used),
        remaining_percent: Some(100u8.saturating_sub(used)),
        reset_at,
        used: None,
        limit: None,
        unit: None,
    }
}

pub(crate) fn parse_datetime(value: &serde_json::Value) -> Option<time::OffsetDateTime> {
    use time::format_description::well_known::Rfc3339;

    if let Some(text) = value.as_str() {
        if let Ok(parsed) = time::OffsetDateTime::parse(text, &Rfc3339) {
            return Some(parsed);
        }
        if let Ok(epoch) = text.parse::<i64>() {
            return timestamp_from_number(epoch);
        }
    }
    value.as_i64().and_then(timestamp_from_number)
}

fn timestamp_from_number(value: i64) -> Option<time::OffsetDateTime> {
    if value.abs() > 10_000_000_000 {
        time::OffsetDateTime::from_unix_timestamp_nanos(i128::from(value) * 1_000_000).ok()
    } else {
        time::OffsetDateTime::from_unix_timestamp(value).ok()
    }
}

pub(crate) fn find_value<'a>(
    value: &'a serde_json::Value,
    keys: &[&str],
) -> Option<&'a serde_json::Value> {
    match value {
        serde_json::Value::Object(map) => {
            for key in keys {
                if let Some(found) = map.get(*key) {
                    return Some(found);
                }
            }
            map.values().find_map(|child| find_value(child, keys))
        }
        serde_json::Value::Array(items) => items.iter().find_map(|child| find_value(child, keys)),
        _ => None,
    }
}

pub(crate) fn find_string(value: &serde_json::Value, keys: &[&str]) -> Option<String> {
    find_value(value, keys)
        .and_then(serde_json::Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .map(str::to_owned)
}

pub(crate) fn find_number(value: &serde_json::Value, keys: &[&str]) -> Option<f64> {
    let value = find_value(value, keys)?;
    value
        .as_f64()
        .or_else(|| value.as_str()?.parse::<f64>().ok())
}

pub(crate) fn decode_jwt_claims(token: &str) -> Option<serde_json::Value> {
    use base64::Engine;
    let payload = token.split('.').nth(1)?;
    let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(payload)
        .or_else(|_| base64::engine::general_purpose::URL_SAFE.decode(payload))
        .ok()?;
    serde_json::from_slice(&bytes).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn provider_capabilities_match_v1_implementation() {
        assert_eq!(
            adapter(AiProvider::Claude).capabilities(),
            &[
                ProviderCapability::ReadIdentity,
                ProviderCapability::MonitorUsage,
                ProviderCapability::SnapshotAuth,
                ProviderCapability::SwitchAccount,
            ]
        );
        assert_eq!(
            adapter(AiProvider::Cursor).capabilities(),
            &[
                ProviderCapability::ReadIdentity,
                ProviderCapability::MonitorUsage,
                ProviderCapability::SnapshotAuth,
                ProviderCapability::SwitchAccount,
                ProviderCapability::RelaunchApp,
            ]
        );
        assert_eq!(
            adapter(AiProvider::Grok).capabilities(),
            &[
                ProviderCapability::ReadIdentity,
                ProviderCapability::MonitorUsage,
                ProviderCapability::SnapshotAuth,
                ProviderCapability::SwitchAccount,
                ProviderCapability::ApiBilling,
            ]
        );
    }
}
