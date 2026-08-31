use std::collections::{BTreeMap, HashMap};
use std::fs::{self, File};
use std::hash::{DefaultHasher, Hasher};
use std::io::{BufRead, BufReader, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use time::format_description::well_known::Rfc3339;
use time::{Duration, OffsetDateTime};

use crate::model::{TokenUsageDayOutput, TokenUsageSummaryOutput};

const CACHE_VERSION: u8 = 1;
const CACHE_FILE_NAME: &str = ".codex-roster-token-usage-v1.json";

#[derive(Default, Serialize, Deserialize)]
struct TokenUsageCache {
    version: u8,
    utc_offset_seconds: i32,
    files: HashMap<String, CachedSession>,
}

#[derive(Clone, Default, Serialize, Deserialize)]
struct CachedSession {
    cursor: u64,
    length: u64,
    modified_nanos: u128,
    prefix_length: u64,
    prefix_hash: u64,
    previous_signature: Option<(u64, u64)>,
    previous_total: Option<u64>,
    tokens: u64,
    events: usize,
    by_day: BTreeMap<String, u64>,
}

pub fn summarize_session_tokens(
    sessions_dir: &Path,
    now: OffsetDateTime,
) -> Result<TokenUsageSummaryOutput> {
    let mut files = Vec::new();
    collect_session_files(sessions_dir, &mut files)?;

    let offset = now.offset();
    let cache_path = sessions_dir
        .parent()
        .unwrap_or(sessions_dir)
        .join(CACHE_FILE_NAME);
    let mut cache = load_cache(&cache_path, offset.whole_seconds());
    let mut active_keys = std::collections::HashSet::new();
    let today = now.date();
    let mut by_day = BTreeMap::new();
    let mut all_time = 0_u64;
    let mut token_events = 0_usize;

    for file in &files {
        let key = file
            .strip_prefix(sessions_dir)
            .unwrap_or(file)
            .to_string_lossy()
            .into_owned();
        active_keys.insert(key.clone());
        let previous = cache.files.remove(&key).unwrap_or_default();
        let current = refresh_cached_session(file, offset, previous)?;
        merge_cached_days(&current, &mut by_day);
        all_time = all_time.saturating_add(current.tokens);
        token_events += current.events;
        cache.files.insert(key, current);
    }
    cache.files.retain(|key, _| active_keys.contains(key));
    save_cache(&cache_path, &cache);

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

fn load_cache(path: &Path, utc_offset_seconds: i32) -> TokenUsageCache {
    let cache = fs::read(path)
        .ok()
        .and_then(|data| serde_json::from_slice::<TokenUsageCache>(&data).ok());
    match cache {
        Some(cache)
            if cache.version == CACHE_VERSION && cache.utc_offset_seconds == utc_offset_seconds =>
        {
            cache
        }
        _ => TokenUsageCache {
            version: CACHE_VERSION,
            utc_offset_seconds,
            files: HashMap::new(),
        },
    }
}

fn save_cache(path: &Path, cache: &TokenUsageCache) {
    let Ok(data) = serde_json::to_vec(cache) else {
        return;
    };
    let temporary = path.with_extension("tmp");
    let result = (|| -> std::io::Result<()> {
        let mut file = File::create(&temporary)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            file.set_permissions(fs::Permissions::from_mode(0o600))?;
        }
        file.write_all(&data)?;
        file.sync_all()?;
        fs::rename(&temporary, path)
    })();
    if result.is_err() {
        let _ = fs::remove_file(temporary);
    }
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

fn refresh_cached_session(
    file: &Path,
    offset: time::UtcOffset,
    mut cached: CachedSession,
) -> Result<CachedSession> {
    let metadata = fs::metadata(file)
        .with_context(|| format!("failed to inspect session {}", file.display()))?;
    let length = metadata.len();
    let modified_nanos = metadata
        .modified()
        .ok()
        .and_then(|modified| modified.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|duration| duration.as_nanos())
        .unwrap_or_default();
    if cached.length == length && cached.modified_nanos == modified_nanos {
        return Ok(cached);
    }
    let prefix_changed = cached.prefix_length > 0
        && file_prefix_hash(file, cached.prefix_length)? != cached.prefix_hash;
    if length < cached.cursor || cached.cursor > cached.length || prefix_changed {
        cached = CachedSession::default();
    }

    let input =
        File::open(file).with_context(|| format!("failed to read session {}", file.display()))?;
    let mut reader = BufReader::new(input);
    reader
        .seek(SeekFrom::Start(cached.cursor))
        .with_context(|| format!("failed to seek session {}", file.display()))?;
    let mut line = String::new();
    loop {
        let line_start = reader.stream_position()?;
        line.clear();
        let bytes = reader.read_line(&mut line)?;
        if bytes == 0 {
            break;
        }
        if !line.ends_with('\n') {
            reader.seek(SeekFrom::Start(line_start))?;
            break;
        }
        let Ok(value) = serde_json::from_str::<Value>(line.trim_end()) else {
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
        if cached.previous_signature == Some(signature) {
            continue;
        }
        let token_delta = match cached.previous_total {
            Some(previous) if total_tokens > previous => total_tokens - previous,
            Some(previous) if total_tokens < previous => last_tokens,
            Some(_) => 0,
            None if total_tokens > 0 => total_tokens,
            None => last_tokens,
        };
        cached.previous_signature = Some(signature);
        cached.previous_total = Some(total_tokens);
        if token_delta == 0 {
            continue;
        }
        let Some(timestamp) = value.get("timestamp").and_then(Value::as_str) else {
            continue;
        };
        let Ok(timestamp) = OffsetDateTime::parse(timestamp, &Rfc3339) else {
            continue;
        };

        cached.tokens = cached.tokens.saturating_add(token_delta);
        cached.events += 1;
        let day = timestamp.to_offset(offset).date().to_string();
        *cached.by_day.entry(day).or_default() += token_delta;
    }
    cached.cursor = reader.stream_position()?;
    cached.length = length;
    cached.modified_nanos = modified_nanos;
    cached.prefix_length = length.min(4_096);
    cached.prefix_hash = file_prefix_hash(file, cached.prefix_length)?;
    Ok(cached)
}

fn file_prefix_hash(file: &Path, length: u64) -> Result<u64> {
    let input = File::open(file)
        .with_context(|| format!("failed to fingerprint session {}", file.display()))?;
    let mut bytes = Vec::with_capacity(length as usize);
    input
        .take(length)
        .read_to_end(&mut bytes)
        .with_context(|| format!("failed to fingerprint session {}", file.display()))?;
    let mut hasher = DefaultHasher::new();
    hasher.write(&bytes);
    Ok(hasher.finish())
}

fn merge_cached_days(cached: &CachedSession, by_day: &mut BTreeMap<time::Date, u64>) {
    for (day, tokens) in &cached.by_day {
        if let Ok(timestamp) = OffsetDateTime::parse(&format!("{day}T00:00:00Z"), &Rfc3339) {
            *by_day.entry(timestamp.date()).or_default() += tokens;
        }
    }
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

    #[test]
    fn incrementally_reads_only_appended_session_rows() {
        let temp = tempfile::tempdir().expect("temp dir");
        let sessions = temp.path().join("sessions/2026/08/30");
        fs::create_dir_all(&sessions).expect("sessions");
        let rollout = sessions.join("rollout.jsonl");
        fs::write(
            &rollout,
            "{\"timestamp\":\"2026-08-30T01:00:00Z\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"total_tokens\":100},\"total_token_usage\":{\"total_tokens\":100}}}}\n",
        )
        .expect("initial session");
        let now = OffsetDateTime::parse("2026-08-30T10:00:00Z", &Rfc3339).expect("now");

        let first = summarize_session_tokens(&temp.path().join("sessions"), now).expect("first");
        assert_eq!(first.all_time, 100);

        let mut file = fs::OpenOptions::new()
            .append(true)
            .open(&rollout)
            .expect("append session");
        writeln!(
            file,
            "{{\"timestamp\":\"2026-08-30T01:01:00Z\",\"payload\":{{\"type\":\"token_count\",\"info\":{{\"last_token_usage\":{{\"total_tokens\":40}},\"total_token_usage\":{{\"total_tokens\":140}}}}}}}}"
        )
        .expect("appended row");

        let second = summarize_session_tokens(&temp.path().join("sessions"), now).expect("second");
        assert_eq!(second.all_time, 140);
        assert_eq!(second.token_events, 2);
        assert!(temp.path().join(CACHE_FILE_NAME).exists());
    }

    #[test]
    fn rebuilds_a_cached_session_after_truncation() {
        let temp = tempfile::tempdir().expect("temp dir");
        let sessions = temp.path().join("sessions/2026/08/30");
        fs::create_dir_all(&sessions).expect("sessions");
        let rollout = sessions.join("rollout.jsonl");
        let now = OffsetDateTime::parse("2026-08-30T10:00:00Z", &Rfc3339).expect("now");
        fs::write(
            &rollout,
            "{\"timestamp\":\"2026-08-30T01:00:00Z\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"total_tokens\":900},\"total_token_usage\":{\"total_tokens\":900}}}}\n",
        )
        .expect("initial session");
        summarize_session_tokens(&temp.path().join("sessions"), now).expect("first");

        fs::write(
            &rollout,
            "{\"timestamp\":\"2026-08-30T02:00:00Z\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"total_tokens\":25},\"total_token_usage\":{\"total_tokens\":25}}}}\n",
        )
        .expect("replacement session");
        let rebuilt =
            summarize_session_tokens(&temp.path().join("sessions"), now).expect("rebuilt");
        assert_eq!(rebuilt.all_time, 25);
        assert_eq!(rebuilt.token_events, 1);
    }

    #[test]
    fn rebuilds_a_cached_session_after_same_length_replacement() {
        let temp = tempfile::tempdir().expect("temp dir");
        let sessions = temp.path().join("sessions/2026/08/30");
        fs::create_dir_all(&sessions).expect("sessions");
        let rollout = sessions.join("rollout.jsonl");
        let now = OffsetDateTime::parse("2026-08-30T10:00:00Z", &Rfc3339).expect("now");
        fs::write(
            &rollout,
            "{\"timestamp\":\"2026-08-30T01:00:00Z\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"total_tokens\":900},\"total_token_usage\":{\"total_tokens\":900}}}}\n",
        )
        .expect("initial session");
        summarize_session_tokens(&temp.path().join("sessions"), now).expect("first");

        fs::write(
            &rollout,
            "{\"timestamp\":\"2026-08-30T02:00:00Z\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"total_tokens\":125},\"total_token_usage\":{\"total_tokens\":125}}}}\n",
        )
        .expect("replacement session");
        let rebuilt =
            summarize_session_tokens(&temp.path().join("sessions"), now).expect("rebuilt");
        assert_eq!(rebuilt.all_time, 125);
        assert_eq!(rebuilt.token_events, 1);
    }
}
