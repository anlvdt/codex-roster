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

use crate::model::{TokenUsageBreakdownOutput, TokenUsageDayOutput, TokenUsageSummaryOutput};

const CACHE_VERSION: u8 = 3;
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
    previous_usage: Option<CachedTokenUsage>,
    usage: CachedTokenUsage,
    by_day: BTreeMap<String, CachedTokenUsage>,
    by_model: BTreeMap<String, CachedTokenUsage>,
    by_project: BTreeMap<String, CachedTokenUsage>,
    model: String,
    project: String,
}

#[derive(Clone, Default, Serialize, Deserialize)]
struct CachedTokenUsage {
    tokens: u64,
    input_tokens: u64,
    output_tokens: u64,
    cached_input_tokens: u64,
    cache_write_input_tokens: u64,
    reasoning_output_tokens: u64,
    token_events: usize,
}

pub fn summarize_session_tokens(
    sessions_dir: &Path,
    now: OffsetDateTime,
) -> Result<TokenUsageSummaryOutput> {
    let mut files = Vec::new();
    collect_session_files(sessions_dir, &mut files)?;
    let codex_root = sessions_dir.parent().unwrap_or(sessions_dir);
    collect_session_files(&codex_root.join("archived_sessions"), &mut files)?;

    let offset = now.offset();
    let cache_path = codex_root.join(CACHE_FILE_NAME);
    let mut cache = load_cache(&cache_path, offset.whole_seconds());
    let mut active_keys = std::collections::HashSet::new();
    let today = now.date();
    let mut by_day = BTreeMap::new();
    let mut usage = CachedTokenUsage::default();
    let mut by_model = BTreeMap::new();
    let mut by_project = BTreeMap::new();

    for file in &files {
        let key = file
            .strip_prefix(codex_root)
            .unwrap_or(file)
            .to_string_lossy()
            .into_owned();
        active_keys.insert(key.clone());
        let previous = cache.files.remove(&key).unwrap_or_default();
        let current = refresh_cached_session(file, offset, previous)?;
        merge_cached_days(&current, &mut by_day);
        merge_usage(&mut usage, &current.usage);
        merge_cached_breakdowns(&current.by_model, &mut by_model);
        merge_cached_breakdowns(&current.by_project, &mut by_project);
        cache.files.insert(key, current);
    }
    cache.files.retain(|key, _| active_keys.contains(key));
    save_cache(&cache_path, &cache);

    let tokens_since = |days: i64| {
        by_day
            .iter()
            .filter(|(date, _)| **date >= today - Duration::days(days - 1) && **date <= today)
            .map(|(_, usage)| usage.tokens)
            .sum()
    };
    let daily = (0..7)
        .rev()
        .map(|days_ago| {
            let date = today - Duration::days(days_ago);
            TokenUsageDayOutput {
                date: date.to_string(),
                tokens: by_day
                    .get(&date)
                    .map(|usage| usage.tokens)
                    .unwrap_or_default(),
            }
        })
        .collect();

    Ok(TokenUsageSummaryOutput {
        today: by_day
            .get(&today)
            .map(|usage| usage.tokens)
            .unwrap_or_default(),
        last_7_days: tokens_since(7),
        last_30_days: tokens_since(30),
        last_365_days: tokens_since(365),
        all_time: usage.tokens,
        input_tokens: usage.input_tokens,
        output_tokens: usage.output_tokens,
        cached_input_tokens: usage.cached_input_tokens,
        cache_write_input_tokens: usage.cache_write_input_tokens,
        reasoning_output_tokens: usage.reasoning_output_tokens,
        cache_hit_percent: cache_hit_percent(&usage),
        daily,
        by_model: breakdown_outputs(by_model),
        by_project: breakdown_outputs(by_project),
        sessions_scanned: files.len(),
        token_events: usage.token_events,
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
        } else if file_type.is_file()
            && entry
                .file_name()
                .to_str()
                .is_some_and(|name| name.starts_with("rollout") && name.ends_with(".jsonl"))
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
        update_session_context(&value, &mut cached);
        if value.pointer("/payload/type").and_then(Value::as_str) != Some("token_count") {
            continue;
        }
        let last_usage = token_usage(value.pointer("/payload/info/last_token_usage"));
        let total_usage = token_usage(value.pointer("/payload/info/total_token_usage"));
        let Some(event_usage) = last_usage.as_ref().or(total_usage.as_ref()) else {
            continue;
        };
        let total_tokens = total_usage
            .as_ref()
            .map(|usage| usage.tokens)
            .unwrap_or(event_usage.tokens);
        let signature = (event_usage.tokens, total_tokens);
        if cached.previous_signature == Some(signature) {
            continue;
        }
        let token_usage = match (last_usage, total_usage.as_ref()) {
            (Some(last_usage), Some(total_usage)) => {
                let token_delta = match cached.previous_total {
                    Some(previous) if total_usage.tokens > previous => {
                        total_usage.tokens - previous
                    }
                    Some(previous) if total_usage.tokens < previous => last_usage.tokens,
                    Some(_) => 0,
                    None if total_usage.tokens > 0 => total_usage.tokens,
                    None => last_usage.tokens,
                };
                with_token_total(last_usage, token_delta)
            }
            (Some(last_usage), None) => {
                let tokens = last_usage.tokens;
                with_token_total(last_usage, tokens)
            }
            (None, Some(total_usage)) => {
                cumulative_delta(total_usage, cached.previous_usage.as_ref())
            }
            (None, None) => unreachable!("event usage was checked above"),
        };
        cached.previous_signature = Some(signature);
        cached.previous_total = total_usage.as_ref().map(|usage| usage.tokens);
        cached.previous_usage = total_usage;
        if token_usage.tokens == 0 {
            continue;
        }
        let Some(timestamp) = value.get("timestamp").and_then(Value::as_str) else {
            continue;
        };
        let Ok(timestamp) = OffsetDateTime::parse(timestamp, &Rfc3339) else {
            continue;
        };

        merge_usage(&mut cached.usage, &token_usage);
        let day = timestamp.to_offset(offset).date().to_string();
        merge_usage(cached.by_day.entry(day).or_default(), &token_usage);
        merge_usage(
            cached
                .by_model
                .entry(current_label(&cached.model, "Unknown model"))
                .or_default(),
            &token_usage,
        );
        merge_usage(
            cached
                .by_project
                .entry(current_label(&cached.project, "Unknown project"))
                .or_default(),
            &token_usage,
        );
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

fn update_session_context(value: &Value, cached: &mut CachedSession) {
    if let Some(model) = value.pointer("/payload/model").and_then(Value::as_str) {
        cached.model = model.to_owned();
    }
    if let Some(cwd) = value.pointer("/payload/cwd").and_then(Value::as_str) {
        cached.project = project_label(cwd);
    }
}

fn project_label(cwd: &str) -> String {
    Path::new(cwd)
        .file_name()
        .and_then(|name| name.to_str())
        .filter(|name| !name.is_empty())
        .unwrap_or(cwd)
        .to_owned()
}

fn current_label(value: &str, fallback: &str) -> String {
    if value.is_empty() {
        fallback.to_owned()
    } else {
        value.to_owned()
    }
}

fn token_usage(value: Option<&Value>) -> Option<CachedTokenUsage> {
    let value = value?;
    Some(CachedTokenUsage {
        tokens: value.get("total_tokens")?.as_u64()?,
        input_tokens: value
            .get("input_tokens")
            .and_then(Value::as_u64)
            .unwrap_or_default(),
        output_tokens: value
            .get("output_tokens")
            .and_then(Value::as_u64)
            .unwrap_or_default(),
        cached_input_tokens: value
            .get("cached_input_tokens")
            .and_then(Value::as_u64)
            .unwrap_or_default(),
        cache_write_input_tokens: value
            .get("cache_write_input_tokens")
            .and_then(Value::as_u64)
            .unwrap_or_default(),
        reasoning_output_tokens: value
            .get("reasoning_output_tokens")
            .and_then(Value::as_u64)
            .unwrap_or_default(),
        token_events: 0,
    })
}

fn with_token_total(mut usage: CachedTokenUsage, tokens: u64) -> CachedTokenUsage {
    usage.tokens = tokens;
    usage.token_events = usize::from(tokens > 0);
    usage
}

fn cumulative_delta(
    total: &CachedTokenUsage,
    previous: Option<&CachedTokenUsage>,
) -> CachedTokenUsage {
    let previous = previous.cloned().unwrap_or_default();
    CachedTokenUsage {
        tokens: total.tokens.saturating_sub(previous.tokens),
        input_tokens: total.input_tokens.saturating_sub(previous.input_tokens),
        output_tokens: total.output_tokens.saturating_sub(previous.output_tokens),
        cached_input_tokens: total
            .cached_input_tokens
            .saturating_sub(previous.cached_input_tokens),
        cache_write_input_tokens: total
            .cache_write_input_tokens
            .saturating_sub(previous.cache_write_input_tokens),
        reasoning_output_tokens: total
            .reasoning_output_tokens
            .saturating_sub(previous.reasoning_output_tokens),
        token_events: usize::from(total.tokens > previous.tokens),
    }
}

fn merge_usage(target: &mut CachedTokenUsage, source: &CachedTokenUsage) {
    target.tokens = target.tokens.saturating_add(source.tokens);
    target.input_tokens = target.input_tokens.saturating_add(source.input_tokens);
    target.output_tokens = target.output_tokens.saturating_add(source.output_tokens);
    target.cached_input_tokens = target
        .cached_input_tokens
        .saturating_add(source.cached_input_tokens);
    target.cache_write_input_tokens = target
        .cache_write_input_tokens
        .saturating_add(source.cache_write_input_tokens);
    target.reasoning_output_tokens = target
        .reasoning_output_tokens
        .saturating_add(source.reasoning_output_tokens);
    target.token_events = target.token_events.saturating_add(source.token_events);
}

fn cache_hit_percent(usage: &CachedTokenUsage) -> u8 {
    if usage.input_tokens == 0 {
        return 0;
    }
    ((usage.cached_input_tokens.saturating_mul(100) / usage.input_tokens).min(100)) as u8
}

fn merge_cached_days(cached: &CachedSession, by_day: &mut BTreeMap<time::Date, CachedTokenUsage>) {
    for (day, usage) in &cached.by_day {
        if let Ok(timestamp) = OffsetDateTime::parse(&format!("{day}T00:00:00Z"), &Rfc3339) {
            merge_usage(by_day.entry(timestamp.date()).or_default(), usage);
        }
    }
}

fn merge_cached_breakdowns(
    source: &BTreeMap<String, CachedTokenUsage>,
    target: &mut BTreeMap<String, CachedTokenUsage>,
) {
    for (label, usage) in source {
        merge_usage(target.entry(label.clone()).or_default(), usage);
    }
}

fn breakdown_outputs(
    by_label: BTreeMap<String, CachedTokenUsage>,
) -> Vec<TokenUsageBreakdownOutput> {
    let mut outputs = by_label
        .into_iter()
        .map(|(label, usage)| TokenUsageBreakdownOutput {
            label,
            tokens: usage.tokens,
            input_tokens: usage.input_tokens,
            output_tokens: usage.output_tokens,
            cached_input_tokens: usage.cached_input_tokens,
            cache_write_input_tokens: usage.cache_write_input_tokens,
            reasoning_output_tokens: usage.reasoning_output_tokens,
            token_events: usage.token_events,
        })
        .collect::<Vec<_>>();
    outputs.sort_by(|left, right| {
        right
            .tokens
            .cmp(&left.tokens)
            .then_with(|| left.label.cmp(&right.label))
    });
    outputs
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

    #[test]
    fn groups_detailed_usage_by_model_project_and_archived_sessions() {
        let temp = tempfile::tempdir().expect("temp dir");
        let sessions = temp.path().join("sessions/2026/08/30");
        let archived = temp.path().join("archived_sessions/2026/08/29");
        fs::create_dir_all(&sessions).expect("sessions");
        fs::create_dir_all(&archived).expect("archived sessions");
        fs::write(
            sessions.join("rollout-current.jsonl"),
            concat!(
                r#"{"type":"event_msg","payload":{"type":"session_meta","cwd":"/work/current-app"}}"#,
                "\n",
                r#"{"type":"turn_context","payload":{"cwd":"/work/current-app","model":"gpt-5.6"}}"#,
                "\n",
                r#"{"timestamp":"2026-08-30T01:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":50,"output_tokens":20,"cached_input_tokens":20,"reasoning_output_tokens":10,"total_tokens":100},"total_token_usage":{"input_tokens":50,"output_tokens":20,"cached_input_tokens":20,"reasoning_output_tokens":10,"total_tokens":100}}}}"#,
                "\n"
            ),
        )
        .expect("current session");
        fs::write(
            archived.join("rollout-archived.jsonl"),
            concat!(
                r#"{"type":"turn_context","payload":{"cwd":"/work/archived-app","model":"gpt-5-mini"}}"#,
                "\n",
                r#"{"timestamp":"2026-08-29T01:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":25,"output_tokens":10,"cached_input_tokens":10,"reasoning_output_tokens":5,"total_tokens":50},"total_token_usage":{"input_tokens":25,"output_tokens":10,"cached_input_tokens":10,"reasoning_output_tokens":5,"total_tokens":50}}}}"#,
                "\n"
            ),
        )
        .expect("archived session");
        let now = OffsetDateTime::parse("2026-08-30T10:00:00Z", &Rfc3339).expect("now");

        let summary =
            summarize_session_tokens(&temp.path().join("sessions"), now).expect("summary");

        assert_eq!(summary.all_time, 150);
        assert_eq!(summary.input_tokens, 75);
        assert_eq!(summary.output_tokens, 30);
        assert_eq!(summary.cached_input_tokens, 30);
        assert_eq!(summary.reasoning_output_tokens, 15);
        assert_eq!(summary.sessions_scanned, 2);
        assert_eq!(summary.by_model[0].label, "gpt-5.6");
        assert_eq!(summary.by_model[0].tokens, 100);
        assert_eq!(summary.by_project[0].label, "current-app");
        assert_eq!(summary.by_project[1].label, "archived-app");
    }

    #[test]
    fn falls_back_to_cumulative_usage_and_ignores_non_rollout_files() {
        let temp = tempfile::tempdir().expect("temp dir");
        let sessions = temp.path().join("sessions/2026/08/30");
        fs::create_dir_all(&sessions).expect("sessions");
        fs::write(
            sessions.join("rollout-cumulative.jsonl"),
            concat!(
                r#"{"timestamp":"2026-08-30T01:00:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":20,"cached_input_tokens":5,"cache_write_input_tokens":2,"output_tokens":10,"reasoning_output_tokens":5,"total_tokens":40}}}}"#,
                "\n",
                r#"{"timestamp":"2026-08-30T01:01:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":40,"cached_input_tokens":10,"cache_write_input_tokens":4,"output_tokens":20,"reasoning_output_tokens":10,"total_tokens":80}}}}"#,
                "\n"
            ),
        )
        .expect("cumulative session");
        fs::write(
            sessions.join("unrelated.jsonl"),
            r#"{"timestamp":"2026-08-30T01:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":999}}}}"#,
        )
        .expect("unrelated file");
        let now = OffsetDateTime::parse("2026-08-30T10:00:00Z", &Rfc3339).expect("now");

        let summary =
            summarize_session_tokens(&temp.path().join("sessions"), now).expect("summary");

        assert_eq!(summary.all_time, 80);
        assert_eq!(summary.input_tokens, 40);
        assert_eq!(summary.cached_input_tokens, 10);
        assert_eq!(summary.cache_write_input_tokens, 4);
        assert_eq!(summary.output_tokens, 20);
        assert_eq!(summary.reasoning_output_tokens, 10);
        assert_eq!(summary.cache_hit_percent, 25);
        assert_eq!(summary.token_events, 2);
        assert_eq!(summary.sessions_scanned, 1);
    }
}
