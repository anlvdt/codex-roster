//! Codex working-session pointers for Auto-resume after account switch.
//!
//! Two modes:
//! 1. **Per-account history** (`capture_for_account` / `hint_for_account`) — last
//!    workspace remembered for a roster row (manual activate).
//! 2. **Continue-exhausted thread** (`capture_pending_continue` /
//!    `take_pending_continue_hint`) — when auto-switch fires because the live
//!    account hit usage limits, freeze the *current* Desktop/CLI thread and
//!    reopen that same thread after the new account is live. Session history
//!    lives under shared `~/.codex` (auth.json is what switches); new turns
//!    burn the replacement account's quota.
//!
//! Restore never exchanges refresh tokens.

use std::collections::HashMap;
use std::fs::{self, File};
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use anyhow::{Context, Result};
use rusqlite::{Connection, OpenFlags};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use time::OffsetDateTime;
use uuid::Uuid;

use crate::file_store::replace_file_with_recovery;
use crate::model::SessionResumeHint;

const INDEX_FILE: &str = "session-resume.json";
const LOOKBACK_DAYS: i64 = 14;
const MAX_META_LINES: usize = 8;
/// Tolerate small clock skew between activate timestamp and rollout mtime.
const ACTIVATED_GRACE: Duration = Duration::from_secs(5);

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct SessionResumePointer {
    pub account_id: Uuid,
    pub session_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    pub rollout_path: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub originator: Option<String>,
    pub captured_at: OffsetDateTime,
}

/// Thread that hit usage limits and should continue on the next account.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct PendingContinueThread {
    pub session_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rollout_path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub from_account_id: Option<Uuid>,
    /// e.g. `auto_switch_exhausted`
    pub reason: String,
    pub captured_at: OffsetDateTime,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
struct SessionResumeIndex {
    #[serde(default)]
    accounts: HashMap<Uuid, SessionResumePointer>,
    /// When this roster account last became live. Used so capture does not
    /// attribute another account's newer shared `~/.codex/sessions` rollout
    /// to an idle account on switch-away.
    #[serde(default)]
    activated_at: HashMap<Uuid, OffsetDateTime>,
    /// One-shot continue target for auto-switch after usage-limit exhaustion.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pending_continue: Option<PendingContinueThread>,
}

#[derive(Clone, Debug)]
struct DiscoveredSession {
    session_id: String,
    cwd: Option<String>,
    rollout_path: PathBuf,
    originator: Option<String>,
    modified: SystemTime,
}

/// Record that `account_id` is now the live Codex account (after successful activate).
pub fn mark_activated(app_data_dir: &Path, account_id: Uuid) -> Result<()> {
    let mut index = load_index(app_data_dir)?;
    index
        .activated_at
        .insert(account_id, OffsetDateTime::now_utc());
    save_index(app_data_dir, &index)
}

pub fn capture_for_account(app_data_dir: &Path, codex_root: &Path, account_id: Uuid) -> Result<()> {
    let mut index = load_index(app_data_dir)?;
    let Some(discovered) = discover_active_user_session(codex_root)? else {
        return Ok(());
    };
    if let Some(activated) = index.activated_at.get(&account_id).copied() {
        let floor = offset_to_system(activated)
            .checked_sub(ACTIVATED_GRACE)
            .unwrap_or(SystemTime::UNIX_EPOCH);
        if discovered.modified < floor {
            // Latest rollout predates this account's live tenure — keep any
            // prior pointer rather than stealing another account's session.
            return Ok(());
        }
    }
    let pointer = SessionResumePointer {
        account_id,
        session_id: discovered.session_id,
        cwd: discovered.cwd,
        rollout_path: discovered.rollout_path.display().to_string(),
        originator: discovered.originator,
        captured_at: OffsetDateTime::now_utc(),
    };
    index.accounts.insert(account_id, pointer);
    save_index(app_data_dir, &index)
}

/// Freeze the live thread that just hit usage limits so auto-switch can reopen
/// it on the replacement account (same session id under shared `~/.codex`).
pub fn capture_pending_continue(
    app_data_dir: &Path,
    codex_root: &Path,
    from_account_id: Uuid,
) -> Result<()> {
    let Some(discovered) = discover_active_user_session(codex_root)? else {
        return Ok(());
    };
    let mut index = load_index(app_data_dir)?;
    index.pending_continue = Some(PendingContinueThread {
        session_id: discovered.session_id,
        cwd: discovered.cwd,
        rollout_path: {
            let path = discovered.rollout_path.display().to_string();
            if path.is_empty() || discovered.rollout_path.as_os_str().is_empty() {
                None
            } else {
                Some(path)
            }
        },
        from_account_id: Some(from_account_id),
        reason: "auto_switch_exhausted".to_owned(),
        captured_at: OffsetDateTime::now_utc(),
    });
    save_index(app_data_dir, &index)
}

/// Consume the one-shot continue hint (clears pending). Used after auto-switch.
pub fn take_pending_continue_hint(
    app_data_dir: &Path,
    enabled: bool,
) -> Result<Option<SessionResumeHint>> {
    if !enabled {
        return Ok(None);
    }
    let mut index = load_index(app_data_dir)?;
    let Some(pending) = index.pending_continue.take() else {
        return Ok(None);
    };
    save_index(app_data_dir, &index)?;
    Ok(Some(hint_from_parts(
        enabled,
        pending.from_account_id,
        Some(pending.session_id),
        pending.cwd,
        pending.rollout_path,
    )))
}

pub fn hint_for_account(
    app_data_dir: &Path,
    account_id: Uuid,
    enabled: bool,
) -> Result<SessionResumeHint> {
    if !enabled {
        return Ok(SessionResumeHint {
            enabled: false,
            account_id: Some(account_id),
            session_id: None,
            cwd: None,
            rollout_path: None,
            status: "disabled".to_owned(),
        });
    }
    let index = load_index(app_data_dir)?;
    let Some(pointer) = index.accounts.get(&account_id) else {
        return Ok(SessionResumeHint {
            enabled: true,
            account_id: Some(account_id),
            session_id: None,
            cwd: None,
            rollout_path: None,
            status: "missing".to_owned(),
        });
    };
    if pointer.session_id.trim().is_empty() {
        return Ok(SessionResumeHint {
            enabled: true,
            account_id: Some(account_id),
            session_id: None,
            cwd: None,
            rollout_path: None,
            status: "missing".to_owned(),
        });
    }
    Ok(hint_from_parts(
        true,
        Some(account_id),
        Some(pointer.session_id.clone()),
        pointer.cwd.clone(),
        Some(pointer.rollout_path.clone()),
    ))
}

fn hint_from_parts(
    enabled: bool,
    account_id: Option<Uuid>,
    session_id: Option<String>,
    cwd: Option<String>,
    rollout_path: Option<String>,
) -> SessionResumeHint {
    let Some(session_id) = session_id.filter(|id| !id.trim().is_empty()) else {
        return SessionResumeHint {
            enabled,
            account_id,
            session_id: None,
            cwd: None,
            rollout_path: None,
            status: if enabled {
                "missing".to_owned()
            } else {
                "disabled".to_owned()
            },
        };
    };
    let rollout_exists = rollout_path
        .as_ref()
        .map(|path| Path::new(path).is_file())
        .unwrap_or(true);
    let cwd_ok = cwd
        .as_ref()
        .map(|cwd| Path::new(cwd).is_dir())
        .unwrap_or(false);
    let status = if !rollout_exists {
        "rollout_gone"
    } else if cwd.is_some() && !cwd_ok {
        // Still openable via thread id — Desktop resume does not need cwd.
        "ready_cli"
    } else if cwd_ok || rollout_exists {
        "ready"
    } else {
        "ready_cli"
    };
    SessionResumeHint {
        enabled,
        account_id,
        session_id: Some(session_id),
        cwd,
        rollout_path,
        status: status.to_owned(),
    }
}

fn load_index(app_data_dir: &Path) -> Result<SessionResumeIndex> {
    let path = index_path(app_data_dir);
    match fs::read(&path) {
        Ok(bytes) => Ok(serde_json::from_slice(&bytes).unwrap_or_default()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            Ok(SessionResumeIndex::default())
        }
        Err(error) => Err(error).with_context(|| format!("failed to read {}", path.display())),
    }
}

fn save_index(app_data_dir: &Path, index: &SessionResumeIndex) -> Result<()> {
    fs::create_dir_all(app_data_dir)
        .with_context(|| format!("failed to create {}", app_data_dir.display()))?;
    let path = index_path(app_data_dir);
    let bytes =
        serde_json::to_vec_pretty(index).context("failed to encode session resume index")?;
    replace_file_with_recovery(&path, Some(&bytes), |temp_path| {
        fs::write(temp_path, &bytes)
            .with_context(|| format!("failed to write {}", temp_path.display()))
    })?;
    Ok(())
}

fn index_path(app_data_dir: &Path) -> PathBuf {
    app_data_dir.join(INDEX_FILE)
}

fn offset_to_system(ts: OffsetDateTime) -> SystemTime {
    let secs = ts.unix_timestamp();
    if secs >= 0 {
        SystemTime::UNIX_EPOCH
            + Duration::from_secs(secs as u64)
            + Duration::from_nanos(u64::from(ts.nanosecond()))
    } else {
        SystemTime::UNIX_EPOCH
    }
}

/// Prefer Desktop's `state_5.sqlite` recency (the thread that just hit limits),
/// then fall back to newest rollout jsonl under `sessions/`.
fn discover_active_user_session(codex_root: &Path) -> Result<Option<DiscoveredSession>> {
    if let Some(from_db) = discover_from_state_db(codex_root)? {
        return Ok(Some(from_db));
    }
    discover_latest_user_session(codex_root)
}

fn discover_from_state_db(codex_root: &Path) -> Result<Option<DiscoveredSession>> {
    let db_path = codex_root.join("state_5.sqlite");
    if !db_path.is_file() {
        return Ok(None);
    }
    let conn = match Connection::open_with_flags(&db_path, OpenFlags::SQLITE_OPEN_READ_ONLY) {
        Ok(conn) => conn,
        Err(_) => return Ok(None),
    };
    let mut stmt = match conn.prepare(
        "SELECT id, cwd, rollout_path
         FROM threads
         WHERE COALESCE(archived, 0) = 0
           AND COALESCE(thread_source, 'user') = 'user'
         ORDER BY COALESCE(recency_at_ms, updated_at_ms, 0) DESC
         LIMIT 1",
    ) {
        Ok(stmt) => stmt,
        Err(_) => return Ok(None),
    };
    let row = stmt.query_row([], |row| {
        let session_id: String = row.get(0)?;
        let cwd: Option<String> = row.get(1)?;
        let rollout_path: Option<String> = row.get(2)?;
        Ok((session_id, cwd, rollout_path))
    });
    let Ok((session_id, cwd, rollout_path)) = row else {
        return Ok(None);
    };
    if session_id.trim().is_empty() {
        return Ok(None);
    }
    let rollout = rollout_path
        .filter(|path| !path.is_empty())
        .map(PathBuf::from)
        .filter(|path| path.is_file())
        .unwrap_or_default();
    let modified = if rollout.as_os_str().is_empty() {
        SystemTime::now()
    } else {
        fs::metadata(&rollout)
            .and_then(|meta| meta.modified())
            .unwrap_or(SystemTime::now())
    };
    Ok(Some(DiscoveredSession {
        session_id,
        cwd: cwd.filter(|value| !value.is_empty()),
        rollout_path: rollout,
        originator: Some("Codex Desktop".to_owned()),
        modified,
    }))
}

fn discover_latest_user_session(codex_root: &Path) -> Result<Option<DiscoveredSession>> {
    let sessions_root = codex_root.join("sessions");
    if !sessions_root.is_dir() {
        return Ok(None);
    }
    let mut best: Option<DiscoveredSession> = None;
    let today = OffsetDateTime::now_utc().date();
    for day_offset in 0..=LOOKBACK_DAYS {
        let Some(date) = today.checked_sub(time::Duration::days(day_offset)) else {
            continue;
        };
        let day_dir = sessions_root
            .join(format!("{:04}", date.year()))
            .join(format!("{:02}", date.month() as u8))
            .join(format!("{:02}", date.day()));
        let Ok(entries) = fs::read_dir(&day_dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            let name = entry.file_name();
            let Some(name) = name.to_str() else {
                continue;
            };
            if !(name.starts_with("rollout") && name.ends_with(".jsonl")) {
                continue;
            }
            let Ok(metadata) = entry.metadata() else {
                continue;
            };
            if !metadata.is_file() {
                continue;
            }
            let modified = metadata.modified().unwrap_or(SystemTime::UNIX_EPOCH);
            if best
                .as_ref()
                .is_some_and(|current| modified <= current.modified)
            {
                continue;
            }
            if let Some(discovered) = parse_user_session_meta(&path, modified)? {
                best = Some(discovered);
            }
        }
    }
    Ok(best)
}

fn parse_user_session_meta(path: &Path, modified: SystemTime) -> Result<Option<DiscoveredSession>> {
    let file = match File::open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => {
            return Err(error).with_context(|| format!("failed to read {}", path.display()));
        }
    };
    let reader = BufReader::new(file);
    for (index, line) in reader.lines().enumerate() {
        if index >= MAX_META_LINES {
            break;
        }
        let Ok(line) = line else {
            continue;
        };
        let Ok(value) = serde_json::from_str::<Value>(line.trim()) else {
            continue;
        };
        if value.get("type").and_then(Value::as_str) != Some("session_meta") {
            continue;
        }
        let Some(payload) = value.get("payload") else {
            continue;
        };
        // Prefer main user threads; skip subagent / guardian rollouts.
        if payload
            .get("thread_source")
            .and_then(Value::as_str)
            .is_some_and(|source| source != "user")
        {
            return Ok(None);
        }
        if payload.pointer("/source/subagent").is_some() {
            return Ok(None);
        }
        let session_id = payload
            .get("session_id")
            .or_else(|| payload.get("id"))
            .and_then(Value::as_str)
            .filter(|id| !id.is_empty());
        let Some(session_id) = session_id else {
            continue;
        };
        let cwd = payload
            .get("cwd")
            .and_then(Value::as_str)
            .filter(|cwd| !cwd.is_empty())
            .map(str::to_owned);
        let originator = payload
            .get("originator")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .map(str::to_owned);
        return Ok(Some(DiscoveredSession {
            session_id: session_id.to_owned(),
            cwd,
            rollout_path: path.to_path_buf(),
            originator,
            modified,
        }));
    }
    Ok(None)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    fn write_rollout(path: &Path, session_id: &str, cwd: &str, thread_source: &str) {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).expect("mkdir");
        }
        let line = format!(
            r#"{{"timestamp":"2026-09-20T01:00:00.000Z","type":"session_meta","payload":{{"session_id":"{session_id}","id":"{session_id}","cwd":"{cwd}","originator":"Codex Desktop","thread_source":"{thread_source}"}}}}"#
        );
        fs::write(path, line + "\n").expect("write rollout");
    }

    fn day_dir(codex_root: &Path) -> PathBuf {
        let today = OffsetDateTime::now_utc().date();
        codex_root
            .join("sessions")
            .join(format!("{:04}", today.year()))
            .join(format!("{:02}", today.month() as u8))
            .join(format!("{:02}", today.day()))
    }

    #[test]
    fn captures_latest_user_thread_and_builds_ready_hint() {
        let temp = tempdir().expect("tempdir");
        let codex_root = temp.path().join("codex");
        let app_data = temp.path().join("app");
        let day_dir = day_dir(&codex_root);
        let cwd = temp.path().join("project");
        fs::create_dir_all(&cwd).expect("cwd");
        write_rollout(
            &day_dir.join("rollout-old.jsonl"),
            "11111111-1111-1111-1111-111111111111",
            cwd.to_str().unwrap(),
            "user",
        );
        std::thread::sleep(std::time::Duration::from_millis(20));
        write_rollout(
            &day_dir.join("rollout-new.jsonl"),
            "22222222-2222-2222-2222-222222222222",
            cwd.to_str().unwrap(),
            "user",
        );
        write_rollout(
            &day_dir.join("rollout-sub.jsonl"),
            "33333333-3333-3333-3333-333333333333",
            cwd.to_str().unwrap(),
            "subagent",
        );

        let account_id = Uuid::new_v4();
        capture_for_account(&app_data, &codex_root, account_id).expect("capture");
        let hint = hint_for_account(&app_data, account_id, true).expect("hint");
        assert_eq!(hint.status, "ready");
        assert_eq!(
            hint.session_id.as_deref(),
            Some("22222222-2222-2222-2222-222222222222")
        );
        assert_eq!(hint.cwd.as_deref(), cwd.to_str());
    }

    #[test]
    fn disabled_hint_does_not_expose_pointer() {
        let temp = tempdir().expect("tempdir");
        let hint = hint_for_account(temp.path(), Uuid::new_v4(), false).expect("hint");
        assert_eq!(hint.status, "disabled");
        assert!(hint.session_id.is_none());
    }

    #[test]
    fn capture_skips_rollouts_from_before_activation() {
        let temp = tempdir().expect("tempdir");
        let codex_root = temp.path().join("codex");
        let app_data = temp.path().join("app");
        let day_dir = day_dir(&codex_root);
        let cwd = temp.path().join("project");
        fs::create_dir_all(&cwd).expect("cwd");
        let old_path = day_dir.join("rollout-old.jsonl");
        write_rollout(
            &old_path,
            "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            cwd.to_str().unwrap(),
            "user",
        );
        // Make mtime clearly in the past relative to activation.
        let past = SystemTime::now() - Duration::from_secs(3600);
        filetime_set(&old_path, past);

        let idle = Uuid::new_v4();
        mark_activated(&app_data, idle).expect("mark");
        capture_for_account(&app_data, &codex_root, idle).expect("capture");
        let hint = hint_for_account(&app_data, idle, true).expect("hint");
        assert_eq!(hint.status, "missing");
        assert!(hint.session_id.is_none());
    }

    #[test]
    fn capture_keeps_prior_pointer_when_latest_rollout_predates_reactivation() {
        let temp = tempdir().expect("tempdir");
        let codex_root = temp.path().join("codex");
        let app_data = temp.path().join("app");
        let day_dir = day_dir(&codex_root);
        let cwd = temp.path().join("project");
        fs::create_dir_all(&cwd).expect("cwd");

        let account = Uuid::new_v4();
        let own = day_dir.join("rollout-own.jsonl");
        write_rollout(
            &own,
            "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
            cwd.to_str().unwrap(),
            "user",
        );
        mark_activated(&app_data, account).expect("mark");
        capture_for_account(&app_data, &codex_root, account).expect("first capture");

        // Re-activate later without new work: latest rollout still the old one.
        filetime_set(&own, SystemTime::now() - Duration::from_secs(120));
        mark_activated(&app_data, account).expect("remark");
        capture_for_account(&app_data, &codex_root, account).expect("second capture");
        let hint = hint_for_account(&app_data, account, true).expect("hint");
        assert_eq!(
            hint.session_id.as_deref(),
            Some("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
        );
    }

    #[test]
    fn pending_continue_captures_and_consumes_exhausted_thread() {
        let temp = tempdir().expect("tempdir");
        let codex_root = temp.path().join("codex");
        let app_data = temp.path().join("app");
        let day_dir = day_dir(&codex_root);
        let cwd = temp.path().join("project");
        fs::create_dir_all(&cwd).expect("cwd");
        write_rollout(
            &day_dir.join("rollout-hit-limit.jsonl"),
            "dddddddd-dddd-dddd-dddd-dddddddddddd",
            cwd.to_str().unwrap(),
            "user",
        );
        let from = Uuid::new_v4();
        capture_pending_continue(&app_data, &codex_root, from).expect("pending");
        let hint = take_pending_continue_hint(&app_data, true)
            .expect("take")
            .expect("pending present");
        assert_eq!(
            hint.session_id.as_deref(),
            Some("dddddddd-dddd-dddd-dddd-dddddddddddd")
        );
        assert_eq!(hint.status, "ready");
        assert!(
            take_pending_continue_hint(&app_data, true)
                .expect("second take")
                .is_none()
        );
    }

    fn filetime_set(path: &Path, when: SystemTime) {
        let file = fs::File::options()
            .write(true)
            .open(path)
            .expect("open for touch");
        file.set_modified(when).expect("set_modified");
    }
}
