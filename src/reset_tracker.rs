use std::collections::HashSet;
use std::fs;
use std::path::Path;

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use time::OffsetDateTime;

const X_PROFILE_ENDPOINT: &str = "https://x.com/thsottiaux?lang=en";
const NOTIFICATION_STATE_FILE: &str = "reset-notifications.json";
const PROFILE_POST_MARKER: &str = "itemType=\"https://schema.org/SocialMediaPosting\"";
const INITIAL_REPLAY_WINDOW: time::Duration = time::Duration::hours(6);
const NOTIFICATION_SOURCE: &str = "x:thsottiaux";

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ResetOutlook {
    pub updated_at: String,
    pub last_reset_at: String,
    pub chance_24_hours: u8,
    pub chance_48_hours: u8,
    pub confidence: String,
    pub window_label: String,
    pub signal_kind: String,
    pub signal_summary: String,
    pub source_url: String,
    pub source_freshness: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ResetEvent {
    pub id: String,
    pub announced_at: String,
    pub summary: String,
    pub url: String,
    pub kind: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct TiboPost {
    id: String,
    created_at: String,
    text: String,
    url: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum SignalKind {
    ConfirmedBanked,
    ScheduledBanked,
    ConfirmedReset,
    ScheduledReset,
    Hint,
}

impl SignalKind {
    fn as_str(self) -> &'static str {
        match self {
            Self::ConfirmedBanked => "confirmed_banked_reset",
            Self::ScheduledBanked => "scheduled_banked_reset",
            Self::ConfirmedReset => "confirmed_global_reset",
            Self::ScheduledReset => "scheduled_global_reset",
            Self::Hint => "reset_hint",
        }
    }

    fn is_confirmed(self) -> bool {
        matches!(self, Self::ConfirmedBanked | Self::ConfirmedReset)
    }
}

#[derive(Default, Serialize, Deserialize)]
struct NotificationState {
    initialized_at: String,
    seen_ids: HashSet<String>,
    #[serde(default)]
    source: String,
}

pub fn fetch_reset_outlook() -> Result<ResetOutlook> {
    let now = OffsetDateTime::now_utc();
    let posts = fetch_tibo_posts(now)?;
    Ok(build_reset_outlook(&posts, now))
}

/// Return new reset or banked-reset signals published directly by Tibo on X.
/// A first poll replays only very recent actionable signals so an app started
/// after an announcement still tells the user, without replaying old history.
pub fn fetch_new_reset_events(app_data_dir: &Path) -> Result<Vec<ResetEvent>> {
    let now = OffsetDateTime::now_utc();
    let posts = fetch_tibo_posts(now)?;
    process_reset_events(app_data_dir, reset_events(&posts), now)
}

fn fetch_tibo_posts(now: OffsetDateTime) -> Result<Vec<TiboPost>> {
    let mut response = ureq::get(X_PROFILE_ENDPOINT)
        .header(
            "User-Agent",
            "Mozilla/5.0 (compatible; CodexRoster/0.2; +https://github.com/anlvdt/codex-roster)",
        )
        .header("Accept-Language", "en-US,en;q=0.9")
        .header("Cache-Control", "no-cache")
        .config()
        .timeout_global(Some(std::time::Duration::from_secs(8)))
        .build()
        .call()
        .context("failed to contact Tibo's public X profile")?;
    if response.status().as_u16() >= 400 {
        bail!("Tibo's X profile returned HTTP {}", response.status());
    }
    let html = response
        .body_mut()
        .read_to_string()
        .context("failed to read Tibo's public X profile")?;
    validate_profile_freshness(&html, now)?;
    let posts = parse_profile_posts(&html);
    if posts.is_empty() {
        bail!("Tibo's X profile did not expose any public posts");
    }
    Ok(posts)
}

fn validate_profile_freshness(html: &str, now: OffsetDateTime) -> Result<()> {
    const MARKER: &str = "last_top_fetch_timestamp_ms:";
    let Some(start) = html.rfind(MARKER).map(|index| index + MARKER.len()) else {
        bail!("Tibo's X profile did not include a freshness timestamp");
    };
    let digits = html[start..]
        .chars()
        .take_while(char::is_ascii_digit)
        .collect::<String>();
    let milliseconds = digits
        .parse::<i128>()
        .context("invalid X profile freshness timestamp")?;
    let fetched_at = OffsetDateTime::from_unix_timestamp_nanos(milliseconds * 1_000_000)
        .context("X profile freshness timestamp is out of range")?;
    if (now - fetched_at).abs() > time::Duration::minutes(15) {
        bail!("Tibo's X profile returned stale timeline data");
    }
    Ok(())
}

fn parse_profile_posts(html: &str) -> Vec<TiboPost> {
    let mut posts = Vec::new();
    let mut seen = HashSet::new();
    let mut cursor = 0;

    while let Some(relative_marker) = html[cursor..].find(PROFILE_POST_MARKER) {
        let marker = cursor + relative_marker;
        let block_start = html[..marker].rfind("<article").unwrap_or(marker);
        let block_end = html[marker..]
            .find("</article>")
            .map(|offset| marker + offset)
            .unwrap_or(html.len());
        let block = &html[block_start..block_end];

        if let (Some(id), Some(created_at), Some(text), Some(url)) = (
            meta_content(block, "identifier"),
            meta_content(block, "datePublished"),
            meta_content(block, "text"),
            meta_content(block, "url"),
        ) && seen.insert(id.clone())
        {
            posts.push(TiboPost {
                id,
                created_at,
                text,
                url,
            });
        }
        cursor = marker + PROFILE_POST_MARKER.len();
    }

    posts.sort_by(|left, right| right.created_at.cmp(&left.created_at));
    posts
}

fn meta_content(block: &str, property: &str) -> Option<String> {
    let needle = format!("itemProp=\"{property}\"");
    let mut cursor = 0;
    while let Some(relative_start) = block[cursor..].find("<meta ") {
        let start = cursor + relative_start;
        let end = block[start..].find('>')? + start + 1;
        let tag = &block[start..end];
        if tag.contains(&needle) {
            return attribute(tag, "content").map(|value| decode_html_entities(&value));
        }
        cursor = end;
    }
    None
}

fn attribute(tag: &str, name: &str) -> Option<String> {
    let needle = format!("{name}=\"");
    let start = tag.find(&needle)? + needle.len();
    let end = tag[start..].find('"')? + start;
    Some(tag[start..end].to_owned())
}

fn decode_html_entities(value: &str) -> String {
    let mut decoded = String::with_capacity(value.len());
    let mut rest = value;
    while let Some(entity_start) = rest.find('&') {
        decoded.push_str(&rest[..entity_start]);
        rest = &rest[entity_start..];
        let Some(entity_end) = rest.find(';') else {
            decoded.push_str(rest);
            return decoded;
        };
        let entity = &rest[1..entity_end];
        let replacement = match entity {
            "amp" => Some('&'),
            "quot" => Some('"'),
            "apos" | "#x27" | "#39" => Some('\''),
            "lt" => Some('<'),
            "gt" => Some('>'),
            _ if entity.starts_with("#x") => u32::from_str_radix(&entity[2..], 16)
                .ok()
                .and_then(char::from_u32),
            _ if entity.starts_with('#') => {
                entity[1..].parse::<u32>().ok().and_then(char::from_u32)
            }
            _ => None,
        };
        if let Some(character) = replacement {
            decoded.push(character);
        } else {
            decoded.push_str(&rest[..=entity_end]);
        }
        rest = &rest[entity_end + 1..];
    }
    decoded.push_str(rest);
    decoded
}

fn classify_post(text: &str) -> Option<SignalKind> {
    let text = text.to_ascii_lowercase();
    let mentions_reset = text.contains("reset");
    let relevant_scope = text.contains("codex")
        || text.contains("chatgpt work")
        || text.contains("usage limit")
        || text.contains("rate limit")
        || text.contains("paid user")
        || text.contains("banked reset");
    if !mentions_reset || !relevant_scope {
        return None;
    }
    if [
        "no reset",
        "no codex reset",
        "don't say reset",
        "do not say reset",
        "not a reset",
    ]
    .iter()
    .any(|phrase| text.contains(phrase))
    {
        return None;
    }

    let banked = text.contains("banked reset");
    let confirmed = [
        "has landed",
        "have landed",
        "has been credited",
        "have been credited",
        "have reset",
        "has reset",
        "limits have been reset",
        "reset the rate limits",
        "reset usage limits",
    ]
    .iter()
    .any(|phrase| text.contains(phrase));
    if confirmed {
        return Some(if banked {
            SignalKind::ConfirmedBanked
        } else {
            SignalKind::ConfirmedReset
        });
    }

    let scheduled = [
        "will credit",
        "will reset",
        "will be there",
        "will land",
        "lands in",
        "later in the day",
        "later today",
        "tomorrow",
    ]
    .iter()
    .any(|phrase| text.contains(phrase));
    if scheduled {
        return Some(if banked {
            SignalKind::ScheduledBanked
        } else {
            SignalKind::ScheduledReset
        });
    }

    ["reset button", "there is still time", "little surprise"]
        .iter()
        .any(|phrase| text.contains(phrase))
        .then_some(SignalKind::Hint)
}

fn build_reset_outlook(posts: &[TiboPost], now: OffsetDateTime) -> ResetOutlook {
    let latest_signal = posts
        .iter()
        .filter_map(|post| {
            let kind = classify_post(&post.text)?;
            let announced_at = parse_event_time(&post.created_at)?;
            let age = now - announced_at;
            (age >= time::Duration::ZERO && age <= time::Duration::hours(48)).then_some((
                post,
                kind,
                announced_at,
            ))
        })
        .max_by_key(|(_, _, announced_at)| *announced_at);

    let (chance_24_hours, chance_48_hours, confidence, window_label) = match latest_signal {
        Some((_, SignalKind::ConfirmedBanked, _)) => (0, 0, "high", "Banked reset confirmed"),
        Some((_, SignalKind::ConfirmedReset, _)) => (0, 0, "high", "Global reset confirmed"),
        Some((_, kind @ SignalKind::ScheduledBanked, announced_at)) => {
            let age = now - announced_at;
            let (score_24, score_48) = forecast_scores(kind, age);
            (
                score_24,
                score_48,
                forecast_confidence(kind, age),
                "Banked reset scheduled",
            )
        }
        Some((_, kind @ SignalKind::ScheduledReset, announced_at)) => {
            let age = now - announced_at;
            let (score_24, score_48) = forecast_scores(kind, age);
            (
                score_24,
                score_48,
                forecast_confidence(kind, age),
                "Global reset scheduled",
            )
        }
        Some((_, kind @ SignalKind::Hint, announced_at)) => {
            let age = now - announced_at;
            let (score_24, score_48) = forecast_scores(kind, age);
            (
                score_24,
                score_48,
                forecast_confidence(kind, age),
                "Tibo hint detected",
            )
        }
        None => (0, 0, "low", "No current Tibo signal"),
    };
    let latest_confirmed = posts
        .iter()
        .find(|post| classify_post(&post.text).is_some_and(SignalKind::is_confirmed));
    let last_reset_at = latest_confirmed
        .or_else(|| latest_signal.map(|(post, _, _)| post))
        .or_else(|| posts.first())
        .map(|post| post.created_at.clone())
        .unwrap_or_else(|| format_time(now));
    let (signal_kind, signal_summary, source_url) = latest_signal.map_or_else(
        || {
            (
                "none".to_owned(),
                "No actionable reset signal in Tibo's latest public posts.".to_owned(),
                X_PROFILE_ENDPOINT.to_owned(),
            )
        },
        |(post, kind, _)| {
            (
                kind.as_str().to_owned(),
                post.text.clone(),
                post.url.clone(),
            )
        },
    );

    ResetOutlook {
        updated_at: format_time(now),
        last_reset_at,
        chance_24_hours,
        chance_48_hours,
        confidence: confidence.to_owned(),
        window_label: window_label.to_owned(),
        signal_kind,
        signal_summary,
        source_url,
        source_freshness: "live_x_profile".to_owned(),
    }
}

fn forecast_scores(kind: SignalKind, age: time::Duration) -> (u8, u8) {
    let (base_24, base_48) = match kind {
        SignalKind::ScheduledBanked => (95, 100),
        SignalKind::ScheduledReset => (90, 98),
        SignalKind::Hint => (55, 75),
        SignalKind::ConfirmedBanked | SignalKind::ConfirmedReset => return (0, 0),
    };
    (
        recency_weighted_score(base_24, age, time::Duration::hours(24)),
        recency_weighted_score(base_48, age, time::Duration::hours(48)),
    )
}

fn recency_weighted_score(base: u8, age: time::Duration, horizon: time::Duration) -> u8 {
    if age < time::Duration::ZERO || age >= horizon {
        return 0;
    }
    let total_seconds = horizon.whole_seconds();
    let remaining_seconds = (horizon - age).whole_seconds();
    ((i64::from(base) * remaining_seconds + total_seconds / 2) / total_seconds) as u8
}

fn forecast_confidence(kind: SignalKind, age: time::Duration) -> &'static str {
    match kind {
        SignalKind::ScheduledBanked | SignalKind::ScheduledReset
            if age <= time::Duration::hours(12) =>
        {
            "high"
        }
        SignalKind::Hint if age <= time::Duration::hours(12) => "medium",
        SignalKind::ScheduledBanked | SignalKind::ScheduledReset
            if age <= time::Duration::hours(24) =>
        {
            "medium"
        }
        _ => "low",
    }
}

fn reset_events(posts: &[TiboPost]) -> Vec<ResetEvent> {
    posts
        .iter()
        .filter_map(|post| {
            let kind = classify_post(&post.text)?;
            Some(ResetEvent {
                id: post.id.clone(),
                announced_at: post.created_at.clone(),
                summary: post.text.clone(),
                url: post.url.clone(),
                kind: kind.as_str().to_owned(),
            })
        })
        .collect()
}

fn parse_event_time(value: &str) -> Option<OffsetDateTime> {
    OffsetDateTime::parse(value, &time::format_description::well_known::Rfc3339).ok()
}

fn format_time(value: OffsetDateTime) -> String {
    value
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap_or_default()
}

fn process_reset_events(
    app_data_dir: &Path,
    mut events: Vec<ResetEvent>,
    now: OffsetDateTime,
) -> Result<Vec<ResetEvent>> {
    fs::create_dir_all(app_data_dir)
        .with_context(|| format!("failed to create {}", app_data_dir.display()))?;
    let state_path = app_data_dir.join(NOTIFICATION_STATE_FILE);
    let existing = fs::read(&state_path)
        .ok()
        .and_then(|bytes| serde_json::from_slice::<NotificationState>(&bytes).ok())
        .filter(|state| state.source == NOTIFICATION_SOURCE);

    let Some(mut state) = existing else {
        let fresh = events
            .iter()
            .filter(|event| {
                parse_event_time(&event.announced_at)
                    .is_some_and(|announced_at| now - announced_at <= INITIAL_REPLAY_WINDOW)
            })
            .max_by(|left, right| left.announced_at.cmp(&right.announced_at))
            .cloned()
            .into_iter()
            .collect::<Vec<_>>();
        let state = NotificationState {
            initialized_at: format_time(now),
            seen_ids: events.iter().map(|event| event.id.clone()).collect(),
            source: NOTIFICATION_SOURCE.to_owned(),
        };
        write_notification_state(&state_path, &state)?;
        return Ok(fresh);
    };

    let initialized_at = parse_event_time(&state.initialized_at).unwrap_or(now);
    let mut fresh = events
        .iter()
        .filter(|event| !state.seen_ids.contains(&event.id))
        .filter(|event| {
            parse_event_time(&event.announced_at)
                .is_some_and(|announced_at| announced_at >= initialized_at)
        })
        .cloned()
        .collect::<Vec<_>>();
    fresh.sort_by(|left, right| left.announced_at.cmp(&right.announced_at));
    state
        .seen_ids
        .extend(events.drain(..).map(|event| event.id));
    write_notification_state(&state_path, &state)?;
    Ok(fresh)
}

fn write_notification_state(path: &Path, state: &NotificationState) -> Result<()> {
    let bytes =
        serde_json::to_vec_pretty(state).context("failed to encode reset notification state")?;
    fs::write(path, bytes).with_context(|| format!("failed to write {}", path.display()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_current_x_profile_microdata_and_decodes_entities() {
        let html = r#"<main><article data-tweet-id="2090964822422949999" itemType="https://schema.org/SocialMediaPosting"><meta content="2090964822422949999" itemProp="identifier"/><meta content="2026-08-22T00:50:36.000Z" itemProp="datePublished"/><meta content="https://x.com/thsottiaux/status/2090964822422949999" itemProp="url"/><meta content="It&#x27;s landed &amp; ready: BANKED reset." itemProp="text"/></article></main>"#;
        let posts = parse_profile_posts(html);
        assert_eq!(posts.len(), 1);
        assert_eq!(posts[0].id, "2090964822422949999");
        assert_eq!(posts[0].text, "It's landed & ready: BANKED reset.");
    }

    #[test]
    fn classifies_banked_and_global_reset_signals_without_false_positives() {
        assert_eq!(
            classify_post("The banked reset has landed for ChatGPT Work and Codex."),
            Some(SignalKind::ConfirmedBanked)
        );
        assert_eq!(
            classify_post("The banked reset will be there by 8pm PST for all paid users of Codex."),
            Some(SignalKind::ScheduledBanked)
        );
        assert_eq!(
            classify_post("We have reset usage limits across Codex and ChatGPT Work."),
            Some(SignalKind::ConfirmedReset)
        );
        assert_eq!(
            classify_post("Why did you switch to Codex? Don't say reset."),
            None
        );
        assert_eq!(classify_post("You would break the reset button?"), None);
    }

    #[test]
    fn confirmed_reset_completes_the_future_forecast() {
        let now = parse_event_time("2026-08-22T02:00:00Z").unwrap();
        let posts = vec![post(
            "landed",
            "2026-08-22T00:50:36Z",
            "The banked reset has landed for ChatGPT Work and Codex.",
        )];
        let outlook = build_reset_outlook(&posts, now);
        assert_eq!(outlook.chance_24_hours, 0);
        assert_eq!(outlook.chance_48_hours, 0);
        assert_eq!(outlook.signal_kind, "confirmed_banked_reset");
        assert_eq!(outlook.source_url, "https://x.com/thsottiaux/status/landed");
    }

    #[test]
    fn scheduled_forecast_decays_at_24_and_48_hour_boundaries() {
        let announced_at = "2026-08-21T00:00:00Z";
        let posts = vec![post(
            "scheduled",
            announced_at,
            "The banked reset will land tomorrow for paid Codex users.",
        )];

        let fresh = build_reset_outlook(&posts, parse_event_time(announced_at).unwrap());
        assert_eq!((fresh.chance_24_hours, fresh.chance_48_hours), (95, 100));
        assert_eq!(fresh.confidence, "high");

        let at_24_hours =
            build_reset_outlook(&posts, parse_event_time("2026-08-22T00:00:00Z").unwrap());
        assert_eq!(
            (at_24_hours.chance_24_hours, at_24_hours.chance_48_hours),
            (0, 50)
        );
        assert_eq!(at_24_hours.confidence, "medium");

        let at_48_hours =
            build_reset_outlook(&posts, parse_event_time("2026-08-23T00:00:00Z").unwrap());
        assert_eq!(
            (at_48_hours.chance_24_hours, at_48_hours.chance_48_hours),
            (0, 0)
        );
        assert_eq!(at_48_hours.confidence, "low");
    }

    #[test]
    fn outlook_rejects_future_dated_and_stale_signals() {
        let now = parse_event_time("2026-08-22T00:00:00Z").unwrap();
        for created_at in ["2026-08-22T00:00:01Z", "2026-08-19T23:59:59Z"] {
            let posts = vec![post(
                "invalid-time",
                created_at,
                "The banked reset will land tomorrow for paid Codex users.",
            )];
            let outlook = build_reset_outlook(&posts, now);
            assert_eq!((outlook.chance_24_hours, outlook.chance_48_hours), (0, 0));
            assert_eq!(outlook.signal_kind, "none");
        }
    }

    #[test]
    fn first_poll_replays_only_recent_signals_then_deduplicates() {
        let temp = tempfile::tempdir().expect("temp dir");
        let now = parse_event_time("2026-08-22T02:00:00Z").unwrap();
        let old = reset_event("old", "2026-08-21T12:00:00Z", "confirmed_global_reset");
        let scheduled = reset_event(
            "scheduled",
            "2026-08-21T23:40:34Z",
            "scheduled_banked_reset",
        );
        let landed = reset_event("landed", "2026-08-22T00:50:36Z", "confirmed_banked_reset");
        let fresh = process_reset_events(
            temp.path(),
            vec![landed.clone(), old, scheduled.clone()],
            now,
        )
        .expect("initial recent replay");
        assert_eq!(
            fresh
                .iter()
                .map(|event| event.id.as_str())
                .collect::<Vec<_>>(),
            vec!["landed"]
        );
        assert!(
            process_reset_events(temp.path(), vec![scheduled, landed], now)
                .expect("deduplicated")
                .is_empty()
        );
    }

    #[test]
    fn subsequent_poll_returns_each_new_signal_once() {
        let temp = tempfile::tempdir().expect("temp dir");
        let started = parse_event_time("2026-08-01T00:00:00Z").unwrap();
        process_reset_events(
            temp.path(),
            vec![reset_event(
                "baseline",
                "2026-07-31T12:00:00Z",
                "confirmed_global_reset",
            )],
            started,
        )
        .expect("baseline");

        let first = reset_event("first", "2026-08-02T12:00:00Z", "scheduled_global_reset");
        let second = reset_event("second", "2026-08-03T12:00:00Z", "confirmed_global_reset");
        let fresh = process_reset_events(temp.path(), vec![second.clone(), first.clone()], started)
            .expect("new reset signals");
        assert_eq!(
            fresh
                .iter()
                .map(|event| event.id.as_str())
                .collect::<Vec<_>>(),
            vec!["first", "second"]
        );
        assert!(
            process_reset_events(temp.path(), vec![first, second], started)
                .expect("deduplicated")
                .is_empty()
        );
    }

    fn post(id: &str, created_at: &str, text: &str) -> TiboPost {
        TiboPost {
            id: id.to_owned(),
            created_at: created_at.to_owned(),
            text: text.to_owned(),
            url: format!("https://x.com/thsottiaux/status/{id}"),
        }
    }

    fn reset_event(id: &str, announced_at: &str, kind: &str) -> ResetEvent {
        ResetEvent {
            id: id.to_owned(),
            announced_at: announced_at.to_owned(),
            summary: format!("Reset {id}"),
            url: format!("https://x.com/thsottiaux/status/{id}"),
            kind: kind.to_owned(),
        }
    }
}
