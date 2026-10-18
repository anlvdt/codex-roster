//! Per-account samples of official rate-limit remaining % over time.
//!
//! Written best-effort after a successful usage fetch. Failures never affect
//! auth, activation, or the usage control path.

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use time::OffsetDateTime;
use uuid::Uuid;

use crate::model::AccountUsageView;

const FILE_NAME: &str = "quota-history-v1.json";
const KEEP_DAYS: i64 = 8;
/// Skip unchanged samples closer than this many minutes.
const STEP_MINUTES: i64 = 5;

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
struct HistoryFile {
    #[serde(default)]
    accounts: BTreeMap<String, Vec<QuotaSample>>,
}

/// One sample: unix minute + remaining percents (−1 = unknown).
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct QuotaSample {
    pub minute: i64,
    pub five_remaining: i8,
    pub week_remaining: i8,
}

#[derive(Clone, Debug, Serialize)]
pub struct QuotaHistoryOutput {
    pub account_id: Option<Uuid>,
    pub samples: Vec<QuotaSample>,
}

fn history_path(app_data_dir: &Path) -> PathBuf {
    app_data_dir.join(FILE_NAME)
}

fn load(path: &Path) -> HistoryFile {
    match fs::read(path) {
        Ok(bytes) => serde_json::from_slice(&bytes).unwrap_or_default(),
        Err(_) => HistoryFile::default(),
    }
}

fn save(path: &Path, file: &HistoryFile) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).ok();
    }
    let bytes = serde_json::to_vec_pretty(file).context("encode quota history")?;
    let tmp = path.with_extension("json.tmp");
    fs::write(&tmp, bytes).context("write quota history tmp")?;
    fs::rename(&tmp, path).context("commit quota history")?;
    Ok(())
}

fn minute_of(now: OffsetDateTime) -> i64 {
    now.unix_timestamp() / 60
}

fn remaining_or_unknown(window: Option<&crate::model::UsageWindowView>) -> i8 {
    window
        .map(|w| i8::try_from(w.remaining_percent).unwrap_or(0))
        .unwrap_or(-1)
}

fn prune(samples: &mut Vec<QuotaSample>, now_minute: i64) {
    let cut = now_minute - KEEP_DAYS * 24 * 60;
    samples.retain(|s| s.minute >= cut);
}

/// Best-effort append. Never panics; errors are ignored by callers.
pub fn record_sample(
    app_data_dir: &Path,
    account_id: Uuid,
    usage: &AccountUsageView,
    now: OffsetDateTime,
) -> Result<()> {
    let path = history_path(app_data_dir);
    let mut file = load(&path);
    let key = account_id.to_string();
    let now_minute = minute_of(now);
    let sample = QuotaSample {
        minute: now_minute,
        five_remaining: remaining_or_unknown(usage.five_hour.as_ref()),
        week_remaining: remaining_or_unknown(usage.weekly.as_ref()),
    };
    let entry = file.accounts.entry(key).or_default();
    if let Some(last) = entry.last()
        && last.five_remaining == sample.five_remaining
        && last.week_remaining == sample.week_remaining
        && now_minute - last.minute < STEP_MINUTES
    {
        return Ok(());
    }
    entry.push(sample);
    prune(entry, now_minute);
    save(&path, &file)
}

pub fn load_samples(
    app_data_dir: &Path,
    account_id: Uuid,
    now: OffsetDateTime,
) -> QuotaHistoryOutput {
    let path = history_path(app_data_dir);
    let mut file = load(&path);
    let key = account_id.to_string();
    let now_minute = minute_of(now);
    let samples = file
        .accounts
        .get_mut(&key)
        .map(|entry| {
            prune(entry, now_minute);
            entry.clone()
        })
        .unwrap_or_default();
    let _ = save(&path, &file);
    QuotaHistoryOutput {
        account_id: Some(account_id),
        samples,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{UsageSource, UsageWindowView};
    use tempfile::tempdir;
    use time::Duration;

    fn usage(five: u8, week: u8) -> AccountUsageView {
        AccountUsageView {
            source: UsageSource::LiveAccessToken,
            fetched_at: OffsetDateTime::now_utc(),
            five_hour: Some(UsageWindowView {
                used_percent: 100u8.saturating_sub(five),
                remaining_percent: five,
                reset_at: OffsetDateTime::now_utc() + Duration::hours(1),
            }),
            weekly: Some(UsageWindowView {
                used_percent: 100u8.saturating_sub(week),
                remaining_percent: week,
                reset_at: OffsetDateTime::now_utc() + Duration::days(2),
            }),
            credits: None,
            banked_resets: None,
            plan_label: None,
            subscription_active_until: None,
            luna_reserve: None,
            five_hour_known: false,
            weekly_known: false,
        }
    }

    #[test]
    fn records_and_dedupes_unchanged_samples() {
        let dir = tempdir().unwrap();
        let id = Uuid::new_v4();
        let now = OffsetDateTime::now_utc();
        record_sample(dir.path(), id, &usage(80, 60), now).unwrap();
        record_sample(dir.path(), id, &usage(80, 60), now + Duration::minutes(2)).unwrap();
        record_sample(dir.path(), id, &usage(70, 60), now + Duration::minutes(3)).unwrap();
        let out = load_samples(dir.path(), id, now + Duration::minutes(3));
        assert_eq!(out.samples.len(), 2);
        assert_eq!(out.samples[0].five_remaining, 80);
        assert_eq!(out.samples[1].five_remaining, 70);
    }

    #[test]
    fn prunes_older_than_keep_window() {
        let dir = tempdir().unwrap();
        let id = Uuid::new_v4();
        let now = OffsetDateTime::now_utc();
        record_sample(dir.path(), id, &usage(90, 90), now - Duration::days(10)).unwrap();
        record_sample(dir.path(), id, &usage(50, 40), now).unwrap();
        let out = load_samples(dir.path(), id, now);
        assert_eq!(out.samples.len(), 1);
        assert_eq!(out.samples[0].five_remaining, 50);
    }
}
