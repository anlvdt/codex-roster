use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use time::OffsetDateTime;
use uuid::Uuid;

use crate::file_store::{RecoveryFileKind, list_recovery_files, replace_file_with_recovery};
use crate::model::ClaudeAutoSwitchStrategy;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct AppSettings {
    #[serde(default)]
    pub auto_start_usage_windows: bool,
    #[serde(default)]
    pub auto_switch_when_exhausted: bool,
    /// Remember the outgoing Codex rollout (session id + cwd) on switch and
    /// reopen that account's last thread via Desktop deep-link after activate.
    /// Default on.
    #[serde(default = "default_auto_resume_session")]
    pub auto_resume_session: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_auto_switch_at: Option<OffsetDateTime>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_auto_switch_target: Option<Uuid>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_auto_switch_from: Option<Uuid>,
    #[serde(default)]
    pub claude_auto_switch: bool,
    #[serde(default = "default_claude_auto_switch_threshold")]
    pub claude_auto_switch_threshold_percent: u8,
    #[serde(default = "default_claude_auto_switch_hysteresis")]
    pub claude_auto_switch_hysteresis_percent: u8,
    #[serde(default = "default_claude_auto_switch_cooldown")]
    pub claude_auto_switch_cooldown_seconds: u64,
    #[serde(default)]
    pub claude_auto_switch_strategy: ClaudeAutoSwitchStrategy,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub claude_last_auto_switch_at: Option<OffsetDateTime>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub claude_last_auto_switch_from: Option<Uuid>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub claude_last_auto_switch_target: Option<Uuid>,
}

impl Default for AppSettings {
    fn default() -> Self {
        Self {
            auto_start_usage_windows: false,
            auto_switch_when_exhausted: false,
            auto_resume_session: true,
            last_auto_switch_at: None,
            last_auto_switch_target: None,
            last_auto_switch_from: None,
            claude_auto_switch: false,
            claude_auto_switch_threshold_percent: default_claude_auto_switch_threshold(),
            claude_auto_switch_hysteresis_percent: default_claude_auto_switch_hysteresis(),
            claude_auto_switch_cooldown_seconds: default_claude_auto_switch_cooldown(),
            claude_auto_switch_strategy: ClaudeAutoSwitchStrategy::default(),
            claude_last_auto_switch_at: None,
            claude_last_auto_switch_from: None,
            claude_last_auto_switch_target: None,
        }
    }
}

fn default_claude_auto_switch_threshold() -> u8 {
    95
}

fn default_claude_auto_switch_hysteresis() -> u8 {
    10
}

fn default_claude_auto_switch_cooldown() -> u64 {
    300
}

fn default_auto_resume_session() -> bool {
    true
}

pub fn load_settings(app_data_dir: &Path) -> Result<AppSettings> {
    let path = settings_path(app_data_dir);
    let pending = path.with_extension("json.pending");
    let mut candidates = list_recovery_files(&path, Some(&pending))?;
    // A valid canonical file is committed state. Otherwise prefer the most
    // recent valid recovery file over defaults (which can enable auto-resume).
    candidates.sort_by_key(|entry| {
        (
            entry.kind != RecoveryFileKind::Canonical,
            std::cmp::Reverse(entry.modified),
        )
    });
    for entry in candidates {
        if let Ok(bytes) = fs::read(&entry.path)
            && let Ok(settings) = serde_json::from_slice(&bytes)
        {
            return Ok(settings);
        }
    }
    match fs::read(&path) {
        Ok(bytes) => Ok(serde_json::from_slice(&bytes).unwrap_or_default()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(AppSettings::default()),
        Err(error) => Err(error).with_context(|| format!("failed to read {}", path.display())),
    }
}

pub fn save_settings(app_data_dir: &Path, settings: &AppSettings) -> Result<()> {
    fs::create_dir_all(app_data_dir)
        .with_context(|| format!("failed to create {}", app_data_dir.display()))?;
    let path = settings_path(app_data_dir);
    let bytes = serde_json::to_vec_pretty(settings).context("failed to encode settings")?;
    replace_file_with_recovery(&path, Some(&bytes), |temp_path| {
        fs::write(temp_path, &bytes)
            .with_context(|| format!("failed to write {}", temp_path.display()))
    })?;
    Ok(())
}

fn settings_path(app_data_dir: &Path) -> PathBuf {
    app_data_dir.join("settings.json")
}

#[cfg(test)]
mod tests {
    use tempfile::tempdir;

    use super::*;

    #[test]
    fn review_regression_settings_recovery_preserves_disabled_auto_resume() {
        for canonical in [None, Some(b"{corrupt".as_slice())] {
            for recovery in [
                "settings.json.bak-old",
                "settings.json.tmp-new",
                "settings.json.pending",
            ] {
                let temp = tempdir().unwrap();
                let original = AppSettings {
                    auto_resume_session: false,
                    claude_auto_switch: true,
                    ..AppSettings::default()
                };
                fs::write(
                    temp.path().join(recovery),
                    serde_json::to_vec(&original).unwrap(),
                )
                .unwrap();
                if let Some(bytes) = canonical {
                    fs::write(settings_path(temp.path()), bytes).unwrap();
                }
                fs::write(temp.path().join("settings.json.tmp-invalid"), b"{").unwrap();
                assert_eq!(load_settings(temp.path()).unwrap(), original);
            }
        }
    }

    #[test]
    fn review_regression_settings_valid_canonical_wins_over_stale_recovery() {
        let temp = tempdir().unwrap();
        let canonical = AppSettings {
            auto_resume_session: false,
            ..AppSettings::default()
        };
        save_settings(temp.path(), &canonical).unwrap();
        fs::write(
            temp.path().join("settings.json.pending"),
            serde_json::to_vec(&AppSettings::default()).unwrap(),
        )
        .unwrap();
        assert_eq!(load_settings(temp.path()).unwrap(), canonical);
    }

    #[test]
    fn missing_settings_default_to_disabled() {
        let temp = tempdir().expect("tempdir");

        let settings = load_settings(temp.path()).expect("load settings");

        assert!(!settings.auto_start_usage_windows);
        assert!(settings.auto_resume_session);
    }

    #[test]
    fn saved_settings_round_trip() {
        let temp = tempdir().expect("tempdir");
        save_settings(
            temp.path(),
            &AppSettings {
                auto_start_usage_windows: true,
                ..AppSettings::default()
            },
        )
        .expect("save settings");

        let settings = load_settings(temp.path()).expect("load settings");

        assert!(settings.auto_start_usage_windows);
    }

    #[test]
    fn malformed_settings_default_to_disabled() {
        let temp = tempdir().expect("tempdir");
        std::fs::create_dir_all(temp.path()).expect("settings dir");
        std::fs::write(settings_path(temp.path()), "{").expect("settings file");

        let settings = load_settings(temp.path()).expect("load settings");

        assert!(!settings.auto_start_usage_windows);
    }
}
