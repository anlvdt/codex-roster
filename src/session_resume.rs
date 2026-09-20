//! Per-account Codex working-session pointers for Auto-resume after account switch.
//!
//! Captures rollout metadata (session id + cwd) from `~/.codex/sessions` — not auth
//! tokens. Restore never exchanges refresh tokens; Desktop thread UI cannot be moved
//! across ChatGPT accounts, so restore opens the remembered workspace via `codex app`.

use std::collections::HashMap;
use std::fs::{self, File};
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use time::OffsetDateTime;
use uuid::Uuid;

use crate::file_store::replace_file_with_recovery;
use crate::model::SessionResumeHint;

const INDEX_FILE: &str = "session-resume.json";
const LOOKBACK_DAYS: i64 = 14;
const MAX_META_LINES: usize = 8;

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

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
struct SessionResumeIndex {
    #[serde(default)]
    accounts: HashMap<Uuid, SessionResumePointer>,
}

#[derive(Clone, Debug)]
struct DiscoveredSession {
    session_id: String,
    cwd: Option<String>,
    rollout_path: PathBuf,
    originator: Option<String>,
    modified: SystemTime,
}

pub fn capture_for_account(app_data_dir: &Path, codex_root: &Path, account_id: Uuid) -> Result<()> {
    let Some(discovered) = discover_latest_user_session(codex_root)? else {
        return Ok(());
    };
    let pointer = SessionResumePointer {
        account_id,
        session_id: discovered.session_id,
        cwd: discovered.cwd,
        rollout_path: discovered.rollout_path.display().to_string(),
        originator: discovered.originator,
        captured_at: OffsetDateTime::now_utc(),
    };
    let mut index = load_index(app_data_dir)?;
    index.accounts.insert(account_id, pointer);
    save_index(app_data_dir, &index)
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
    let rollout_exists = Path::new(&pointer.rollout_path).is_file();
    let cwd_ok = pointer
        .cwd
        .as_ref()
        .map(|cwd| Path::new(cwd).is_dir())
        .unwrap_or(false);
    let status = if !rollout_exists {
        "rollout_gone"
    } else if pointer.cwd.is_some() && !cwd_ok {
        "cwd_gone"
    } else if cwd_ok {
        "ready"
    } else {
        // Session id still usable for `codex resume <id>` even without a cwd.
        "ready_cli"
    };
    Ok(SessionResumeHint {
        enabled: true,
        account_id: Some(account_id),
        session_id: Some(pointer.session_id.clone()),
        cwd: pointer.cwd.clone(),
        rollout_path: Some(pointer.rollout_path.clone()),
        status: status.to_owned(),
    })
}

fn load_index(app_data_dir: &Path) -> Result<SessionResumeIndex> {
    let path = index_path(app_data_dir);
    match fs::read(&path) {
        Ok(bytes) => Ok(serde_json::from_slice(&bytes).unwrap_or_default()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(SessionResumeIndex::default()),
        Err(error) => Err(error).with_context(|| format!("failed to read {}", path.display())),
    }
}

fn save_index(app_data_dir: &Path, index: &SessionResumeIndex) -> Result<()> {
    fs::create_dir_all(app_data_dir)
        .with_context(|| format!("failed to create {}", app_data_dir.display()))?;
    let path = index_path(app_data_dir);
    let bytes = serde_json::to_vec_pretty(index).context("failed to encode session resume index")?;
    replace_file_with_recovery(&path, Some(&bytes), |temp_path| {
        fs::write(temp_path, &bytes)
            .with_context(|| format!("failed to write {}", temp_path.display()))
    })?;
    Ok(())
}

fn index_path(app_data_dir: &Path) -> PathBuf {
    app_data_dir.join(INDEX_FILE)
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
            if best.as_ref().is_some_and(|current| modified <= current.modified) {
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
        if payload
            .pointer("/source/subagent")
            .is_some()
        {
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

    #[test]
    fn captures_latest_user_thread_and_builds_ready_hint() {
        let temp = tempdir().expect("tempdir");
        let codex_root = temp.path().join("codex");
        let app_data = temp.path().join("app");
        let today = OffsetDateTime::now_utc().date();
        let day_dir = codex_root
            .join("sessions")
            .join(format!("{:04}", today.year()))
            .join(format!("{:02}", today.month() as u8))
            .join(format!("{:02}", today.day()));
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
}
