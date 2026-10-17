//! Lightweight live Codex activity summary for the notch / Status strip.
//!
//! Classifies running Codex processes plus recent rollout writers:
//! - **working** — CLI/session roles that look actively busy, or a rollout
//!   file written within the recent window
//! - **waiting** — interrupted / usage-limit threads that still need the user
//! - **idle** — Desktop (or helpers) running without recent rollout writes

use std::fs;
use std::path::Path;
use std::time::{Duration, SystemTime};

use serde::Serialize;

use crate::model::RunningCodexProcess;
use crate::session_resume;

const RECENT_ROLLOUT_SECS: u64 = 45;

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ActivityKind {
    Working,
    Waiting,
    Idle,
}

#[derive(Clone, Debug, Serialize)]
pub struct ActivityEntry {
    pub kind: ActivityKind,
    pub label: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
pub struct CodexActivitySummary {
    pub working: usize,
    pub waiting: usize,
    pub idle: usize,
    pub desktop_running: bool,
    pub entries: Vec<ActivityEntry>,
}

pub fn summarize(
    codex_root: &Path,
    processes: &[RunningCodexProcess],
) -> CodexActivitySummary {
    let desktop_running = processes.iter().any(|p| {
        matches!(p.origin.as_deref(), Some("desktop") | Some("plugin"))
            || p.role.eq_ignore_ascii_case("desktop")
            || p.executable.to_ascii_lowercase().contains("chatgpt")
            || p.executable.to_ascii_lowercase().contains("codex")
                && matches!(p.origin.as_deref(), Some("desktop"))
    });

    let recent_write = recent_rollout_activity(codex_root);
    let mut entries = Vec::new();
    let mut working = 0usize;
    let mut idle = 0usize;

    for process in processes {
        let is_cli = process.origin.as_deref() == Some("cli")
            || matches!(
                process.role.as_str(),
                "cli" | "exec" | "review" | "apply" | "main"
            );
        let is_desktopish = matches!(process.origin.as_deref(), Some("desktop") | Some("plugin"))
            || matches!(process.role.as_str(), "app-server" | "mcp" | "mcp-server");

        if is_cli {
            working += 1;
            entries.push(ActivityEntry {
                kind: ActivityKind::Working,
                label: process
                    .summary
                    .clone()
                    .unwrap_or_else(|| format!("{} · pid {}", process.role, process.pid)),
                detail: Some(format!("pid {}", process.pid)),
            });
        } else if is_desktopish {
            // Count Desktop once via desktop_running; skip per-helper noise.
            continue;
        } else {
            idle += 1;
            entries.push(ActivityEntry {
                kind: ActivityKind::Idle,
                label: format!("{} · pid {}", process.role, process.pid),
                detail: None,
            });
        }
    }

    if desktop_running && working == 0 {
        if recent_write {
            working += 1;
            entries.push(ActivityEntry {
                kind: ActivityKind::Working,
                label: "Desktop session".to_owned(),
                detail: Some("recent rollout write".to_owned()),
            });
        } else {
            idle += 1;
            entries.push(ActivityEntry {
                kind: ActivityKind::Idle,
                label: "Desktop".to_owned(),
                detail: Some("no recent rollout write".to_owned()),
            });
        }
    } else if desktop_running && recent_write && working == 0 {
        working += 1;
    }

    let waiting_hints = waiting_interrupted(codex_root);
    let waiting = waiting_hints.len();
    for (idx, hint) in waiting_hints.iter().enumerate() {
        entries.push(ActivityEntry {
            kind: ActivityKind::Waiting,
            label: hint
                .cwd
                .as_deref()
                .and_then(|cwd| Path::new(cwd).file_name())
                .map(|name| name.to_string_lossy().into_owned())
                .unwrap_or_else(|| format!("interrupted {}", idx + 1)),
            detail: hint.session_id.clone(),
        });
    }

    CodexActivitySummary {
        working,
        waiting,
        idle,
        desktop_running,
        entries,
    }
}

fn recent_rollout_activity(codex_root: &Path) -> bool {
    let sessions = codex_root.join("sessions");
    let cutoff = SystemTime::now()
        .checked_sub(Duration::from_secs(RECENT_ROLLOUT_SECS))
        .unwrap_or(SystemTime::UNIX_EPOCH);
    walk_recent_jsonl(&sessions, cutoff)
}

fn walk_recent_jsonl(dir: &Path, cutoff: SystemTime) -> bool {
    let Ok(entries) = fs::read_dir(dir) else {
        return false;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            if walk_recent_jsonl(&path, cutoff) {
                return true;
            }
            continue;
        }
        if path.extension().and_then(|e| e.to_str()) != Some("jsonl") {
            continue;
        }
        if let Ok(meta) = entry.metadata()
            && let Ok(modified) = meta.modified()
            && modified >= cutoff
        {
            return true;
        }
    }
    false
}

fn waiting_interrupted(codex_root: &Path) -> Vec<crate::model::SessionResumeHint> {
    match session_resume::hint_for_interrupted_sessions(codex_root, true, None) {
        Ok(hint) if hint.status == "ready" || hint.status == "ready_cli" => {
            let mut all = vec![hint.clone()];
            all.extend(hint.additional_sessions);
            all
        }
        Ok(hint) => hint.additional_sessions,
        Err(_) => Vec::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn empty_when_nothing_running() {
        let dir = tempdir().unwrap();
        let summary = summarize(dir.path(), &[]);
        assert_eq!(summary.working, 0);
        assert_eq!(summary.waiting, 0);
        assert!(!summary.desktop_running);
    }

    #[test]
    fn counts_cli_as_working() {
        let dir = tempdir().unwrap();
        let processes = vec![RunningCodexProcess {
            pid: 42,
            executable: "codex".into(),
            role: "exec".into(),
            summary: Some("review".into()),
            origin: Some("cli".into()),
        }];
        let summary = summarize(dir.path(), &processes);
        assert_eq!(summary.working, 1);
        assert_eq!(summary.entries[0].kind, ActivityKind::Working);
    }
}
