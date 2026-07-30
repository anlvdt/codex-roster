use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use serde_json::Value;
use time::format_description::well_known::Rfc3339;
use time::{Duration, OffsetDateTime};

use crate::model::{TokenUsageDayOutput, TokenUsageSummaryOutput};

pub fn summarize_session_tokens(
    sessions_dir: &Path,
    now: OffsetDateTime,
) -> Result<TokenUsageSummaryOutput> {
    let mut files = Vec::new();
    collect_session_files(sessions_dir, &mut files)?;

    let offset = now.offset();
    let today = now.date();
    let mut by_day = BTreeMap::new();
    let mut all_time = 0_u64;
    let mut token_events = 0_usize;

    for file in &files {
        let (tokens, events) = read_session_tokens(file, offset, &mut by_day)?;
        all_time = all_time.saturating_add(tokens);
        token_events += events;
    }

    let tokens_since = |days: i64| {
        by_day
            .iter()
            .filter(|(date, _)| **date >= today - Duration::days(days - 1) && **date <= today)
            .map(|(_, tokens)| *tokens)
            .sum()
    };
    let daily = (0..7)
        .rev()
        .map(|days_ago| {
            let date = today - Duration::days(days_ago);
            TokenUsageDayOutput {
                date: date.to_string(),
                tokens: by_day.get(&date).copied().unwrap_or_default(),
            }
        })
        .collect();

    Ok(TokenUsageSummaryOutput {
        today: by_day.get(&today).copied().unwrap_or_default(),
        last_7_days: tokens_since(7),
        last_30_days: tokens_since(30),
        last_365_days: tokens_since(365),
        all_time,
        daily,
        sessions_scanned: files.len(),
        token_events,
    })
}

fn collect_session_files(directory: &Path, files: &mut Vec<PathBuf>) -> Result<()> {
    let entries = match fs::read_dir(directory) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => {
            return Err(error).with_context(|| format!("failed to read {}", directory.display()));
        }
    };
    for entry in entries {
        let entry = entry.with_context(|| format!("failed to read {}", directory.display()))?;
        let file_type = entry
            .file_type()
            .with_context(|| format!("failed to inspect {}", entry.path().display()))?;
        if file_type.is_dir() {
            collect_session_files(&entry.path(), files)?;
        } else if file_type.is_file() && entry.path().extension().is_some_and(|ext| ext == "jsonl")
        {
            files.push(entry.path());
        }
    }
    Ok(())
}

fn read_session_tokens(
    file: &Path,
    offset: time::UtcOffset,
    by_day: &mut BTreeMap<time::Date, u64>,
) -> Result<(u64, usize)> {
    let contents = fs::read_to_string(file)
        .with_context(|| format!("failed to read session {}", file.display()))?;
    let mut previous_signature = None;
    let mut previous_total = None;
    let mut tokens = 0_u64;
    let mut events = 0_usize;

    for line in contents.lines() {
        let Ok(value) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        if value.pointer("/payload/type").and_then(Value::as_str) != Some("token_count") {
            continue;
        }
        let Some(last_tokens) = value
            .pointer("/payload/info/last_token_usage/total_tokens")
            .and_then(Value::as_u64)
        else {
            continue;
        };
        let total_tokens = value
            .pointer("/payload/info/total_token_usage/total_tokens")
            .and_then(Value::as_u64)
            .unwrap_or_default();
        let signature = (last_tokens, total_tokens);
        if previous_signature == Some(signature) {
            continue;
        }
        let token_delta = match previous_total {
            Some(previous) if total_tokens > previous => total_tokens - previous,
            Some(previous) if total_tokens < previous => last_tokens,
            Some(_) => 0,
            None if total_tokens > 0 => total_tokens,
            None => last_tokens,
        };
        previous_signature = Some(signature);
        previous_total = Some(total_tokens);
        if token_delta == 0 {
            continue;
        }
        let Some(timestamp) = value.get("timestamp").and_then(Value::as_str) else {
            continue;
        };
        let Ok(timestamp) = OffsetDateTime::parse(timestamp, &Rfc3339) else {
            continue;
        };

        tokens = tokens.saturating_add(token_delta);
        events += 1;
        *by_day
            .entry(timestamp.to_offset(offset).date())
            .or_default() += token_delta;
    }
    Ok((tokens, events))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn summarizes_token_events_without_counting_duplicate_snapshots() {
        let temp = tempfile::tempdir().expect("temp dir");
        let sessions = temp.path().join("sessions/2026/07/30");
        fs::create_dir_all(&sessions).expect("sessions");
        fs::write(
            sessions.join("rollout.jsonl"),
            concat!(
                "{\"timestamp\":\"2026-07-30T01:00:00Z\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"total_tokens\":100},\"total_token_usage\":{\"total_tokens\":100}}}}\n",
                "{\"timestamp\":\"2026-07-30T01:00:01Z\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"total_tokens\":100},\"total_token_usage\":{\"total_tokens\":100}}}}\n",
                "{\"timestamp\":\"2026-07-29T01:00:00Z\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"total_tokens\":40},\"total_token_usage\":{\"total_tokens\":140}}}}\n"
            ),
        )
        .expect("session");
        let now = OffsetDateTime::parse("2026-07-30T10:00:00Z", &Rfc3339).expect("now");

        let summary =
            summarize_session_tokens(&temp.path().join("sessions"), now).expect("summary");

        assert_eq!(summary.today, 100);
        assert_eq!(summary.last_7_days, 140);
        assert_eq!(summary.all_time, 140);
        assert_eq!(summary.token_events, 2);
    }
}
