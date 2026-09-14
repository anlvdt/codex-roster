use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::Duration;

use anyhow::{Context, Result, bail};
use base64::Engine;
use rusqlite::types::ValueRef;
use rusqlite::{Connection, OpenFlags};
use serde_json::Value;
use time::OffsetDateTime;

use super::{
    ProviderAdapter, ProviderAuthBundle, decode_jwt_claims, find_number, find_string, find_value,
    parse_datetime, percent_window,
};
use crate::env::AppEnv;
use crate::model::{
    AiProvider, DisplayIdentity, ProviderCapability, ProviderUsageStatus, ProviderUsageView,
    ProviderUsageWindowView, SNAPSHOT_SCHEMA_VERSION, SnapshotBlob, SnapshotFile, UsageFidelity,
};

pub struct CursorAdapter;
pub static CURSOR: CursorAdapter = CursorAdapter;

const USAGE_URL: &str = "https://cursor.com/api/usage-summary";
const CAPABILITIES: &[ProviderCapability] = &[
    ProviderCapability::ReadIdentity,
    ProviderCapability::MonitorUsage,
    ProviderCapability::SnapshotAuth,
    ProviderCapability::SwitchAccount,
    ProviderCapability::RelaunchApp,
];

fn cursor_db_path(env: &AppEnv) -> PathBuf {
    let relative = match env.kind {
        crate::model::EnvironmentKind::Macos => {
            "Library/Application Support/Cursor/User/globalStorage/state.vscdb"
        }
        crate::model::EnvironmentKind::Windows => {
            "AppData/Roaming/Cursor/User/globalStorage/state.vscdb"
        }
        crate::model::EnvironmentKind::Linux | crate::model::EnvironmentKind::Wsl => {
            ".config/Cursor/User/globalStorage/state.vscdb"
        }
    };
    env.home_dir.join(relative)
}

fn open_readonly(path: &Path) -> Result<Connection> {
    let flags = OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_URI;
    let encoded = path.to_string_lossy().replace(' ', "%20");
    let uri = format!("file:{encoded}?mode=ro");
    let conn = Connection::open_with_flags(uri, flags)
        .with_context(|| format!("failed to open Cursor database at {}", path.display()))?;
    conn.busy_timeout(Duration::from_millis(500))?;
    let _ = conn
        .execute_batch("PRAGMA query_only = ON; PRAGMA mmap_size = 0; PRAGMA cache_size = -2000;");
    Ok(conn)
}

fn value_bytes(value: ValueRef<'_>) -> Vec<u8> {
    match value {
        ValueRef::Blob(bytes) | ValueRef::Text(bytes) => bytes.to_vec(),
        ValueRef::Null => Vec::new(),
        ValueRef::Integer(value) => value.to_string().into_bytes(),
        ValueRef::Real(value) => value.to_string().into_bytes(),
    }
}

fn read_auth_map(path: &Path) -> Result<HashMap<String, Vec<u8>>> {
    let conn = open_readonly(path)?;
    let mut stmt = conn.prepare(
        "SELECT key, value FROM ItemTable WHERE key LIKE 'cursorAuth/%' OR key LIKE 'secret://cursorAuth/%'",
    )?;
    let rows = stmt.query_map([], |row| {
        let key: String = row.get(0)?;
        let value = value_bytes(row.get_ref(1)?);
        Ok((key, value))
    })?;
    let mut map = HashMap::new();
    for row in rows {
        let (key, value) = row?;
        map.insert(key, value);
    }
    Ok(map)
}

fn string_value(map: &HashMap<String, Vec<u8>>, key: &str) -> Option<String> {
    map.get(key)
        .and_then(|bytes| String::from_utf8(bytes.clone()).ok())
        .filter(|value| !value.is_empty())
}

fn access_token(map: &HashMap<String, Vec<u8>>) -> Option<String> {
    string_value(map, "cursorAuth/accessToken")
}

fn identity_from_map(map: &HashMap<String, Vec<u8>>) -> Result<DisplayIdentity> {
    let email =
        string_value(map, "cursorAuth/cachedEmail").context("Cursor cached email is missing")?;
    let profile = string_value(map, "cursorAuth/cachedScopedProfile")
        .and_then(|raw| serde_json::from_str::<Value>(&raw).ok());
    let name = profile
        .as_ref()
        .and_then(|value| find_string(value, &["displayName", "name"]));
    let plan_label = string_value(map, "cursorAuth/stripeMembershipType").map(|value| match value
        .to_ascii_lowercase()
        .as_str()
    {
        "pro" => "Pro".to_owned(),
        "free" => "Free".to_owned(),
        _ => value,
    });
    let claims = access_token(map).and_then(|token| decode_jwt_claims(&token));
    let subject = claims
        .as_ref()
        .and_then(|claims| find_string(claims, &["sub", "user_id", "userId"]));
    Ok(DisplayIdentity {
        email,
        subject,
        name,
        plan_label,
    })
}

fn snapshot_from_map(map: &HashMap<String, Vec<u8>>) -> Result<SnapshotBlob> {
    let encoded = map
        .iter()
        .map(|(key, value)| {
            (
                key.clone(),
                base64::engine::general_purpose::STANDARD.encode(value),
            )
        })
        .collect::<HashMap<_, _>>();
    let bytes = serde_json::to_vec(&encoded).context("failed to encode Cursor auth snapshot")?;
    Ok(SnapshotBlob {
        schema_version: SNAPSHOT_SCHEMA_VERSION,
        files: vec![SnapshotFile {
            name: "cursor_auth.json".to_owned(),
            bytes_base64: base64::engine::general_purpose::STANDARD.encode(bytes),
        }],
    })
}

fn map_from_snapshot(snapshot: &SnapshotBlob) -> Result<HashMap<String, Vec<u8>>> {
    let file = snapshot
        .files
        .iter()
        .find(|file| file.name == "cursor_auth.json")
        .context("snapshot missing cursor_auth.json")?;
    let json = base64::engine::general_purpose::STANDARD
        .decode(&file.bytes_base64)
        .context("failed to decode cursor_auth.json")?;
    let encoded: HashMap<String, String> =
        serde_json::from_slice(&json).context("failed to parse cursor_auth.json")?;
    encoded
        .into_iter()
        .map(|(key, value)| {
            Ok((
                key,
                base64::engine::general_purpose::STANDARD
                    .decode(value)
                    .context("failed to decode Cursor auth value")?,
            ))
        })
        .collect()
}

fn ratio_window(
    key: &str,
    label: &str,
    used: Option<f64>,
    limit: Option<f64>,
    reset_at: Option<OffsetDateTime>,
    unit: &str,
) -> Option<ProviderUsageWindowView> {
    if used.is_none() && limit.is_none() {
        return None;
    }
    let used_percent = match (used, limit) {
        (Some(used), Some(limit)) if limit > 0.0 => {
            Some(((used / limit) * 100.0).clamp(0.0, 100.0).round() as u8)
        }
        _ => None,
    };
    Some(ProviderUsageWindowView {
        key: key.to_owned(),
        label: label.to_owned(),
        used_percent,
        remaining_percent: used_percent.map(|value| 100u8.saturating_sub(value)),
        reset_at,
        used,
        limit,
        unit: Some(unit.to_owned()),
    })
}

fn usage_amount(block: Option<&Value>, key: &str) -> Option<f64> {
    block.and_then(|block| find_number(block, &[key]))
}

/// `individualUsage`/`teamUsage` amounts are cents-based; convert to USD.
fn cents_to_usd(value: Option<f64>) -> Option<f64> {
    value.map(|cents| cents / 100.0)
}

fn parse_usage(body: &str) -> Result<ProviderUsageView> {
    let value: Value = serde_json::from_str(body).context("failed to parse Cursor usage JSON")?;
    let reset_at = find_value(
        &value,
        &[
            "billingCycleEnd",
            "billing_cycle_end",
            "cycleEnd",
            "resetAt",
        ],
    )
    .and_then(parse_datetime);
    let mut windows = Vec::new();

    // Nested usage-summary schema (CodexBar v0.60): plan/auto/api lane percents,
    // cents-based plan and team-pool amounts under `individualUsage`/`teamUsage`.
    let individual = value.get("individualUsage");
    let plan = individual.and_then(|usage| usage.get("plan"));
    let team = value.get("teamUsage");

    let plan_used_usd = cents_to_usd(usage_amount(plan, "used"));
    let plan_limit_usd = cents_to_usd(usage_amount(plan, "limit"));
    let auto_percent = usage_amount(plan, "autoPercentUsed");
    let api_percent = usage_amount(plan, "apiPercentUsed");
    let total_percent = usage_amount(plan, "totalPercentUsed");

    // Enterprise/team members report a personal cap under `individualUsage.overall`;
    // `teamUsage.pooled` is the shared pool and the last resort for a headline.
    let overall_used_usd = cents_to_usd(usage_amount(
        individual.and_then(|usage| usage.get("overall")),
        "used",
    ));
    let overall_limit_usd = cents_to_usd(usage_amount(
        individual.and_then(|usage| usage.get("overall")),
        "limit",
    ));
    let pooled_used_usd = cents_to_usd(usage_amount(
        team.and_then(|usage| usage.get("pooled")),
        "used",
    ));
    let pooled_limit_usd = cents_to_usd(usage_amount(
        team.and_then(|usage| usage.get("pooled")),
        "limit",
    ));

    let (used_usd, limit_usd) = if plan_used_usd.is_some() || plan_limit_usd.is_some() {
        (plan_used_usd, plan_limit_usd)
    } else if overall_used_usd.is_some() || overall_limit_usd.is_some() {
        (overall_used_usd, overall_limit_usd)
    } else {
        (pooled_used_usd, pooled_limit_usd)
    };

    // Headline percent precedence mirrors upstream: totalPercentUsed → lane
    // average → single lane → amount ratio → flat legacy percent fields.
    let percent = total_percent
        .or_else(|| match (auto_percent, api_percent) {
            (Some(auto), Some(api)) => Some((auto + api) / 2.0),
            (None, Some(api)) => Some(api),
            (Some(auto), None) => Some(auto),
            (None, None) => None,
        })
        .or_else(|| match (used_usd, limit_usd) {
            (Some(used), Some(limit)) if limit > 0.0 => Some(used / limit * 100.0),
            _ => None,
        })
        .or_else(|| {
            find_number(
                &value,
                &[
                    "planUsagePercent",
                    "plan_usage_percent",
                    "totalPercentUsed",
                    "percentUsed",
                ],
            )
        });

    match (percent, used_usd, limit_usd) {
        (Some(percent), used, limit) if used.is_some() || limit.is_some() => {
            let mut window = percent_window("plan", "Plan", percent, reset_at);
            window.used = used;
            window.limit = limit;
            window.unit = Some("USD".to_owned());
            windows.push(window);
        }
        (Some(percent), _, _) => {
            windows.push(percent_window("plan", "Plan", percent, reset_at));
        }
        (None, used, limit) => {
            if let Some(window) = ratio_window("plan", "Plan", used, limit, reset_at, "USD") {
                windows.push(window);
            } else {
                // Legacy flat request-based fields.
                let used = find_number(&value, &["planUsed", "plan_used", "used", "usage"]);
                let limit = find_number(&value, &["planLimit", "plan_limit", "limit", "included"]);
                if let Some(window) =
                    ratio_window("plan", "Plan", used, limit, reset_at, "requests")
                {
                    windows.push(window);
                }
            }
        }
    }

    let on_demand_used = cents_to_usd(usage_amount(
        individual.and_then(|usage| usage.get("onDemand")),
        "used",
    ))
    .or_else(|| {
        cents_to_usd(usage_amount(
            team.and_then(|usage| usage.get("onDemand")),
            "used",
        ))
    })
    .or_else(|| find_number(&value, &["onDemandUsed", "on_demand_used", "onDemand"]));
    let on_demand_limit = cents_to_usd(usage_amount(
        individual.and_then(|usage| usage.get("onDemand")),
        "limit",
    ))
    .or_else(|| {
        cents_to_usd(usage_amount(
            team.and_then(|usage| usage.get("onDemand")),
            "limit",
        ))
    })
    .or_else(|| find_number(&value, &["onDemandLimit", "on_demand_limit"]));
    if let Some(window) = ratio_window(
        "on_demand",
        "On-demand",
        on_demand_used,
        on_demand_limit,
        reset_at,
        "USD",
    ) {
        windows.push(window);
    }

    Ok(ProviderUsageView {
        provider: AiProvider::Cursor,
        fetched_at: OffsetDateTime::now_utc(),
        status: ProviderUsageStatus::Ok,
        fidelity: UsageFidelity::Official,
        headline_window: windows.first().map(|window| window.key.clone()),
        windows,
        plan_label: find_string(&value, &["membershipType", "plan", "planName"]),
        detail: None,
    })
}

impl ProviderAdapter for CursorAdapter {
    fn provider(&self) -> AiProvider {
        AiProvider::Cursor
    }

    fn capabilities(&self) -> &'static [ProviderCapability] {
        CAPABILITIES
    }

    fn try_read_live_auth(&self, env: &AppEnv) -> Result<Option<ProviderAuthBundle>> {
        let path = cursor_db_path(env);
        if !path.exists() {
            return Ok(None);
        }
        match self.read_live_auth(env) {
            Ok(bundle) => Ok(Some(bundle)),
            Err(_) => Ok(None),
        }
    }

    fn read_live_auth(&self, env: &AppEnv) -> Result<ProviderAuthBundle> {
        let path = cursor_db_path(env);
        if !path.exists() {
            bail!("Cursor state database not found at {}", path.display())
        }
        let map = read_auth_map(&path)?;
        if access_token(&map).is_none() {
            bail!("Cursor access token was not found; sign in to Cursor first")
        }
        Ok(ProviderAuthBundle {
            identity: identity_from_map(&map)?,
            snapshot: snapshot_from_map(&map)?,
        })
    }

    fn identity_from_snapshot(&self, snapshot: &SnapshotBlob) -> Result<DisplayIdentity> {
        identity_from_map(&map_from_snapshot(snapshot)?)
    }

    fn restore_snapshot(&self, env: &AppEnv, snapshot: &SnapshotBlob) -> Result<()> {
        let path = cursor_db_path(env);
        if !path.exists() {
            bail!("Cursor state database not found at {}", path.display())
        }
        let map = map_from_snapshot(snapshot)?;
        let mut conn = Connection::open(&path)
            .with_context(|| format!("failed to open Cursor database at {}", path.display()))?;
        conn.busy_timeout(Duration::from_secs(2))?;
        let tx = conn.transaction()?;
        tx.execute(
            "DELETE FROM ItemTable WHERE key LIKE 'cursorAuth/%' OR key LIKE 'secret://cursorAuth/%'",
            [],
        )?;
        {
            let mut stmt =
                tx.prepare("INSERT OR REPLACE INTO ItemTable (key, value) VALUES (?1, ?2)")?;
            for (key, value) in map {
                match String::from_utf8(value) {
                    Ok(text) => stmt.execute(rusqlite::params![key, text])?,
                    Err(error) => stmt.execute(rusqlite::params![key, error.into_bytes()])?,
                };
            }
        }
        tx.commit()?;
        Ok(())
    }

    fn fetch_usage(&self, snapshot: &SnapshotBlob) -> Result<ProviderUsageView> {
        let map = map_from_snapshot(snapshot)?;
        let token = access_token(&map).context("Cursor access token missing from snapshot")?;
        let subject = decode_jwt_claims(&token)
            .as_ref()
            .and_then(|claims| find_string(claims, &["sub"]))
            .context("Cursor access token does not contain a subject")?;
        let cookie = format!("WorkosCursorSessionToken={subject}::{token}");
        let mut response = ureq::get(USAGE_URL)
            .header("Cookie", &cookie)
            .header("Authorization", &format!("Bearer {token}"))
            .header("Accept", "application/json")
            .header("User-Agent", "codex-roster")
            .config()
            .http_status_as_error(false)
            .timeout_global(Some(Duration::from_secs(15)))
            .build()
            .call()
            .context("Cursor usage request failed")?;
        let status = response.status().as_u16();
        let body = response
            .body_mut()
            .read_to_string()
            .context("failed to read Cursor usage response")?;
        let provider_status = match status {
            401 => Some(ProviderUsageStatus::CredentialExpired),
            403 => Some(ProviderUsageStatus::AccessDenied),
            429 => Some(ProviderUsageStatus::RateLimited),
            _ => None,
        };
        if let Some(provider_status) = provider_status {
            return Ok(ProviderUsageView {
                provider: AiProvider::Cursor,
                fetched_at: OffsetDateTime::now_utc(),
                status: provider_status,
                fidelity: UsageFidelity::Official,
                headline_window: None,
                windows: Vec::new(),
                plan_label: None,
                detail: Some(format!("Cursor usage endpoint returned HTTP {status}")),
            });
        }
        if !(200..300).contains(&status) {
            bail!("Cursor usage endpoint returned HTTP {status}")
        }
        parse_usage(&body)
    }

    fn requires_relaunch_after_switch(&self) -> bool {
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn snapshot_round_trip_preserves_cursor_auth_values() {
        let mut map = HashMap::new();
        map.insert(
            "cursorAuth/cachedEmail".to_owned(),
            b"ada@example.com".to_vec(),
        );
        map.insert("cursorAuth/accessToken".to_owned(), b"a.b.c".to_vec());
        let snapshot = snapshot_from_map(&map).expect("snapshot");
        let restored = map_from_snapshot(&snapshot).expect("restore");
        assert_eq!(restored, map);
    }

    #[test]
    fn parses_cursor_usage_percent_and_cycle_end() {
        let usage = parse_usage(
            r#"{"planUsagePercent":42.5,"billingCycleEnd":"2026-10-01T00:00:00Z","membershipType":"pro"}"#,
        )
        .expect("usage");
        assert_eq!(usage.windows[0].used_percent, Some(43));
        assert_eq!(usage.plan_label.as_deref(), Some("pro"));
    }

    #[test]
    fn parses_nested_individual_usage_with_cents_amounts() {
        let usage = parse_usage(
            r#"{
                "billingCycleEnd": "2026-10-01T00:00:00Z",
                "membershipType": "pro",
                "individualUsage": {
                    "plan": {
                        "used": 2000,
                        "limit": 4000,
                        "totalPercentUsed": 51.2,
                        "autoPercentUsed": 48.0,
                        "apiPercentUsed": 54.4
                    },
                    "onDemand": { "used": 1250, "limit": 5000 }
                }
            }"#,
        )
        .expect("usage");

        let plan = &usage.windows[0];
        assert_eq!(plan.key, "plan");
        assert_eq!(plan.used_percent, Some(51));
        assert_eq!(plan.used, Some(20.0));
        assert_eq!(plan.limit, Some(40.0));
        assert_eq!(plan.unit.as_deref(), Some("USD"));

        let on_demand = &usage.windows[1];
        assert_eq!(on_demand.key, "on_demand");
        assert_eq!(on_demand.used, Some(12.5));
        assert_eq!(on_demand.limit, Some(50.0));
        assert_eq!(on_demand.used_percent, Some(25));
    }

    #[test]
    fn falls_back_to_overall_and_pooled_team_amounts() {
        let usage = parse_usage(
            r#"{
                "billingCycleEnd": "2026-10-01T00:00:00Z",
                "membershipType": "enterprise",
                "individualUsage": { "overall": { "used": 7384, "limit": 10000 } },
                "teamUsage": { "pooled": { "used": 50000, "limit": 100000 } }
            }"#,
        )
        .expect("usage");

        let plan = &usage.windows[0];
        assert_eq!(plan.used_percent, Some(74));
        assert_eq!(plan.used, Some(73.84));
        assert_eq!(plan.limit, Some(100.0));

        let pooled_only =
            parse_usage(r#"{"teamUsage": {"pooled": {"used": 25000, "limit": 100000}}}"#)
                .expect("pooled usage");
        assert_eq!(pooled_only.windows[0].used_percent, Some(25));
    }
}
