use std::fs;
use std::path::Path;

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use time::OffsetDateTime;

const CACHE_FILE: &str = "vibe-usage-summary.json";

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Config {
    api_key: String,
    #[serde(default = "default_api_url")]
    api_url: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct UsageResponse {
    #[serde(default)]
    buckets: Vec<UsageBucket>,
    #[serde(default)]
    sessions: Vec<UsageSession>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct UsageBucket {
    #[serde(default)]
    total_tokens: u64,
    #[serde(default)]
    estimated_cost: Option<f64>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct UsageSession {
    #[serde(default)]
    active_seconds: u64,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct VibeUsageSummary {
    pub days: u8,
    pub total_tokens: u64,
    pub estimated_cost_usd: f64,
    pub sessions: usize,
    pub active_seconds: u64,
    pub fetched_at: OffsetDateTime,
}

pub fn is_configured(home_dir: &Path) -> bool {
    config_path(home_dir).is_file()
}

pub fn fetch_and_cache(home_dir: &Path, app_data_dir: &Path) -> Result<VibeUsageSummary> {
    let config: Config = serde_json::from_slice(
        &fs::read(config_path(home_dir)).context("failed to read VibeCafe config")?,
    )
    .context("failed to decode VibeCafe config")?;
    let url = format!("{}/api/usage?days=7", config.api_url.trim_end_matches('/'));
    let mut response = ureq::get(&url)
        .header("Authorization", &format!("Bearer {}", config.api_key))
        .header("User-Agent", "codex-roster")
        .config()
        .http_status_as_error(false)
        .timeout_global(Some(std::time::Duration::from_secs(15)))
        .build()
        .call()
        .context("failed to query VibeCafe usage")?;
    if response.status().as_u16() >= 400 {
        bail!("VibeCafe usage request failed with {}", response.status());
    }
    let data: UsageResponse = response
        .body_mut()
        .read_json()
        .context("failed to decode VibeCafe usage response")?;
    let summary = summarize(data);
    fs::create_dir_all(app_data_dir).context("failed to create app data directory")?;
    let cache_path = app_data_dir.join(CACHE_FILE);
    fs::write(&cache_path, serde_json::to_vec_pretty(&summary)?)
        .context("failed to cache VibeCafe usage summary")?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&cache_path, fs::Permissions::from_mode(0o600))
            .context("failed to protect VibeCafe usage cache")?;
    }
    Ok(summary)
}

fn summarize(data: UsageResponse) -> VibeUsageSummary {
    VibeUsageSummary {
        days: 7,
        total_tokens: data.buckets.iter().map(|bucket| bucket.total_tokens).sum(),
        estimated_cost_usd: data
            .buckets
            .iter()
            .filter_map(|bucket| bucket.estimated_cost)
            .sum(),
        sessions: data.sessions.len(),
        active_seconds: data
            .sessions
            .iter()
            .map(|session| session.active_seconds)
            .sum(),
        fetched_at: OffsetDateTime::now_utc(),
    }
}

pub fn load_cached(app_data_dir: &Path) -> Option<VibeUsageSummary> {
    fs::read(app_data_dir.join(CACHE_FILE))
        .ok()
        .and_then(|data| serde_json::from_slice(&data).ok())
}

fn config_path(home_dir: &Path) -> std::path::PathBuf {
    home_dir.join(".vibe-usage/config.json")
}

fn default_api_url() -> String {
    "https://vibecafe.ai".to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn summarizes_official_usage_response_fields() {
        let data: UsageResponse = serde_json::from_str(
            r#"{
                "buckets": [
                    {"totalTokens": 1200, "estimatedCost": 0.25},
                    {"totalTokens": 300, "estimatedCost": null}
                ],
                "sessions": [
                    {"activeSeconds": 60},
                    {"activeSeconds": 120}
                ],
                "hasAnyData": true
            }"#,
        )
        .expect("official response shape");
        let summary = summarize(data);
        assert_eq!(summary.total_tokens, 1500);
        assert_eq!(summary.estimated_cost_usd, 0.25);
        assert_eq!(summary.sessions, 2);
        assert_eq!(summary.active_seconds, 180);
    }

    #[test]
    fn configuration_requires_vibe_usage_config_file() {
        let home = tempdir().expect("temp home");
        assert!(!is_configured(home.path()));

        let config_dir = home.path().join(".vibe-usage");
        fs::create_dir_all(&config_dir).expect("config dir");
        fs::write(config_dir.join("config.json"), b"{}").expect("config file");
        assert!(is_configured(home.path()));
    }

    #[test]
    fn cached_summary_round_trips_and_malformed_cache_is_ignored() {
        let app_data = tempdir().expect("temp app data");
        let expected = VibeUsageSummary {
            days: 7,
            total_tokens: 42,
            estimated_cost_usd: 1.25,
            sessions: 3,
            active_seconds: 90,
            fetched_at: OffsetDateTime::UNIX_EPOCH,
        };
        let cache_path = app_data.path().join(CACHE_FILE);
        fs::write(
            &cache_path,
            serde_json::to_vec_pretty(&expected).expect("serialize summary"),
        )
        .expect("write cache");

        let loaded = load_cached(app_data.path()).expect("load valid cache");
        assert_eq!(loaded.days, expected.days);
        assert_eq!(loaded.total_tokens, expected.total_tokens);
        assert_eq!(loaded.estimated_cost_usd, expected.estimated_cost_usd);
        assert_eq!(loaded.sessions, expected.sessions);
        assert_eq!(loaded.active_seconds, expected.active_seconds);
        assert_eq!(loaded.fetched_at, expected.fetched_at);

        fs::write(&cache_path, b"not-json").expect("write malformed cache");
        assert!(load_cached(app_data.path()).is_none());
    }
}
