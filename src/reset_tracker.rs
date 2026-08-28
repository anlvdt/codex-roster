use std::collections::HashSet;
use std::fs;
use std::path::Path;

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use time::OffsetDateTime;

const X_PROFILE_ENDPOINT: &str = "https://x.com/thsottiaux?lang=en";
const RESET_FEED_ENDPOINT: &str = "https://codex-reset.com/api/feed";
const FORECAST_ENDPOINT: &str = "https://codex-reset.com/api/forecast";
const NOTIFICATION_STATE_FILE: &str = "reset-notifications.json";
const PROFILE_POST_MARKER: &str = "itemType=\"https://schema.org/SocialMediaPosting\"";
const INITIAL_REPLAY_WINDOW: time::Duration = time::Duration::hours(6);
const NOTIFICATION_SOURCE: &str = "x:thsottiaux";
const MAX_SEEN_EVENT_IDS: usize = 512;
const MAX_NOTIFICATIONS_PER_HOUR: usize = 8;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ResetOutlook {
    pub updated_at: String,
    pub last_reset_at: String,
    pub next_reset_at: Option<String>,
    pub last_reset_is_confirmed: bool,
    pub chance_24_hours: u8,
    pub chance_48_hours: u8,
    pub confidence: String,
    pub window_label: String,
    pub window_timezone: Option<String>,
    pub window_start_hour: Option<u32>,
    pub window_end_hour: Option<u32>,
    pub signal_kind: String,
    pub signal_summary: String,
    pub source_url: String,
    pub source_freshness: String,
    pub cadence_days: Option<f64>,
    pub cadence_accelerating: Option<bool>,
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

    #[allow(dead_code)]
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
    #[serde(default)]
    notification_window_started_at: Option<String>,
    #[serde(default)]
    notifications_in_window: usize,
}

// ---------------------------------------------------------------------------
// Outlook: delegate to the Codex Reset forecast API
// ---------------------------------------------------------------------------

pub fn fetch_reset_outlook() -> Result<ResetOutlook> {
    let now = OffsetDateTime::now_utc();
    let forecast = fetch_forecast()?;
    let feed_signal = fetch_feed_signal_metadata(now);

    let (signal_kind, signal_summary, source_url, last_reset_is_confirmed) = match feed_signal {
        Some(signal) => {
            let kind = signal
                .kind
                .as_deref()
                .map(map_feed_signal_kind)
                .unwrap_or("none");
            let confirmed = signal
                .reset_verification_status
                .as_deref()
                .is_some_and(|status| status == "confirmed")
                || signal.active == Some(true);
            (
                kind.to_owned(),
                signal.summary.clone().unwrap_or_default(),
                signal
                    .url
                    .clone()
                    .unwrap_or_else(|| X_PROFILE_ENDPOINT.to_owned()),
                confirmed,
            )
        }
        None => (
            "none".to_owned(),
            "No actionable reset signal in Tibo's latest public posts.".to_owned(),
            X_PROFILE_ENDPOINT.to_owned(),
            false,
        ),
    };

    Ok(ResetOutlook {
        updated_at: forecast.updated_at,
        last_reset_at: forecast.last_reset_at,
        next_reset_at: None,
        last_reset_is_confirmed,
        chance_24_hours: forecast.probabilities.rounded_24h,
        chance_48_hours: forecast.probabilities.rounded_48h,
        confidence: forecast.confidence,
        window_label: forecast.time_window.label,
        window_timezone: forecast.time_window.timezone,
        window_start_hour: forecast.time_window.start_hour,
        window_end_hour: forecast.time_window.end_hour,
        signal_kind,
        signal_summary,
        source_url,
        source_freshness: "codex_reset_forecast_api".to_owned(),
        cadence_days: forecast.cadence.as_ref().and_then(|c| c.recent_median_days),
        cadence_accelerating: forecast.cadence.as_ref().and_then(|c| c.accelerating),
    })
}

fn map_feed_signal_kind(kind: &str) -> &'static str {
    match kind {
        "confirmed" => "confirmed_global_reset",
        "scheduled" => "scheduled_global_reset",
        "candidate" => "reset_hint",
        _ => "none",
    }
}

fn fetch_forecast() -> Result<ForecastResponse> {
    let mut response = ureq::get(FORECAST_ENDPOINT)
        .header(
            "User-Agent",
            "Mozilla/5.0 (compatible; CodexRoster/0.2; +https://github.com/anlvdt/codex-roster)",
        )
        .config()
        .timeout_global(Some(std::time::Duration::from_secs(6)))
        .build()
        .call()
        .context("failed to contact the Codex Reset forecast API")?;
    if response.status().as_u16() >= 400 {
        bail!("Codex Reset forecast API returned HTTP {}", response.status());
    }
    let forecast = response
        .body_mut()
        .read_json::<ForecastResponse>()
        .context("failed to decode the Codex Reset forecast response")?;
    Ok(forecast)
}

fn fetch_feed_signal_metadata(now: OffsetDateTime) -> Option<ResetFeedSignal> {
    let mut response = ureq::get(RESET_FEED_ENDPOINT)
        .header(
            "User-Agent",
            "Mozilla/5.0 (compatible; CodexRoster/0.2; +https://github.com/anlvdt/codex-roster)",
        )
        .config()
        .timeout_global(Some(std::time::Duration::from_secs(6)))
        .build()
        .call()
        .ok()?;
    if response.status().as_u16() >= 400 {
        return None;
    }
    let feed = response.body_mut().read_json::<ResetFeed>().ok()?;
    if feed.stale {
        return None;
    }
    let fetched_at = parse_event_time(&feed.fetched_at)?;
    if (now - fetched_at).abs() > time::Duration::minutes(15) {
        return None;
    }
    feed.signal
}

// ---------------------------------------------------------------------------
// Reset events: feed / X profile scraping for desktop notifications
// ---------------------------------------------------------------------------

/// Return new reset or banked-reset signals published directly by Tibo on X.
/// A first poll replays only very recent actionable signals so an app started
/// after an announcement still tells the user, without replaying old history.
pub fn fetch_new_reset_events(app_data_dir: &Path) -> Result<Vec<ResetEvent>> {
    let now = OffsetDateTime::now_utc();
    let posts = fetch_reset_posts(now)?;
    process_reset_events(app_data_dir, reset_events(&posts), now)
}

#[derive(Deserialize)]
struct ResetFeed {
    tweets: Vec<ResetFeedTweet>,
    #[serde(default)]
    stale: bool,
    fetched_at: String,
    #[serde(default)]
    signal: Option<ResetFeedSignal>,
}

#[derive(Deserialize)]
struct ResetFeedSignal {
    #[allow(dead_code)]
    tweet_id: Option<String>,
    summary: Option<String>,
    url: Option<String>,
    kind: Option<String>,
    active: Option<bool>,
    #[serde(default)]
    reset_verification_status: Option<String>,
}

#[derive(Deserialize)]
struct ResetFeedTweet {
    id: Option<String>,
    text: Option<String>,
    at: Option<String>,
}

#[derive(Deserialize)]
struct ForecastResponse {
    updated_at: String,
    probabilities: ForecastProbabilities,
    confidence: String,
    last_reset_at: String,
    time_window: ForecastTimeWindow,
    #[serde(default)]
    cadence: Option<ForecastCadence>,
}

#[derive(Deserialize)]
struct ForecastProbabilities {
    rounded_24h: u8,
    rounded_48h: u8,
}

#[derive(Deserialize)]
struct ForecastTimeWindow {
    label: String,
    timezone: Option<String>,
    start_hour: Option<u32>,
    end_hour: Option<u32>,
}

#[derive(Deserialize)]
struct ForecastCadence {
    recent_median_days: Option<f64>,
    accelerating: Option<bool>,
}

// ---------------------------------------------------------------------------
// Reset Timeline
// ---------------------------------------------------------------------------

const TIMELINE_ENDPOINT: &str = "https://codex-reset.com/api/timeline";

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ResetTimeline {
    pub updated_at: String,
    pub events: Vec<ResetTimelineEvent>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ResetTimelineEvent {
    pub id: String,
    pub date: String,
    pub event_type: String,
    pub summary: String,
    pub url: String,
    pub announced_at: String,
    pub scope: Option<String>,
    pub confidence: Option<String>,
    pub reset_kind: Option<String>,
    pub audience: Option<Vec<String>>,
}

pub fn fetch_reset_timeline() -> Result<ResetTimeline> {
    let mut response = ureq::get(TIMELINE_ENDPOINT)
        .header(
            "User-Agent",
            "Mozilla/5.0 (compatible; CodexRoster/0.2; +https://github.com/anlvdt/codex-roster)",
        )
        .config()
        .timeout_global(Some(std::time::Duration::from_secs(6)))
        .build()
        .call()
        .context("failed to contact the Codex Reset timeline API")?;
    if response.status().as_u16() >= 400 {
        bail!("Codex Reset timeline API returned HTTP {}", response.status());
    }
    let timeline = response
        .body_mut()
        .read_json::<ResetTimeline>()
        .context("failed to decode the Codex Reset timeline response")?;
    Ok(timeline)
}

// ---------------------------------------------------------------------------
// Reset Status History
// ---------------------------------------------------------------------------

const STATUS_HISTORY_ENDPOINT: &str = "https://codex-reset.com/api/status-history";

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ResetStatusHistory {
    pub current: ResetStatusCurrent,
    pub surfaces: Vec<ResetStatusSurface>,
    pub incidents: Vec<ResetStatusIncident>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ResetStatusCurrent {
    pub indicator: String,
    pub description: String,
    pub codex: String,
    pub degraded: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ResetStatusSurface {
    pub id: String,
    pub label: String,
    pub status: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ResetStatusIncident {
    pub id: String,
    pub name: String,
    pub status: String,
    pub impact: Option<String>,
    pub started_at: String,
    pub resolved_at: Option<String>,
    pub codex_related: bool,
}

pub fn fetch_reset_status_history() -> Result<ResetStatusHistory> {
    let mut response = ureq::get(STATUS_HISTORY_ENDPOINT)
        .header(
            "User-Agent",
            "Mozilla/5.0 (compatible; CodexRoster/0.2; +https://github.com/anlvdt/codex-roster)",
        )
        .config()
        .timeout_global(Some(std::time::Duration::from_secs(6)))
        .build()
        .call()
        .context("failed to contact the Codex Reset status-history API")?;
    if response.status().as_u16() >= 400 {
        bail!("Codex Reset status-history API returned HTTP {}", response.status());
    }
    let status = response
        .body_mut()
        .read_json::<ResetStatusHistory>()
        .context("failed to decode the Codex Reset status-history response")?;
    Ok(status)
}

// ---------------------------------------------------------------------------
// Reset Juice (quota effort tiers)
// ---------------------------------------------------------------------------

const JUICE_ENDPOINT: &str = "https://codex-reset.com/api/juice";

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ResetJuice {
    pub status: String,
    pub model: Option<String>,
    pub checked_at: Option<String>,
    pub verified_efforts: Option<u32>,
    pub efforts: Vec<ResetJuiceEffort>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ResetJuiceEffort {
    pub effort: String,
    pub current: u32,
    pub previous: u32,
    pub delta: i32,
    pub verified_at: Option<String>,
    pub verification_state: Option<String>,
}

pub fn fetch_reset_juice() -> Result<ResetJuice> {
    let mut response = ureq::get(JUICE_ENDPOINT)
        .header(
            "User-Agent",
            "Mozilla/5.0 (compatible; CodexRoster/0.2; +https://github.com/anlvdt/codex-roster)",
        )
        .config()
        .timeout_global(Some(std::time::Duration::from_secs(6)))
        .build()
        .call()
        .context("failed to contact the Codex Reset juice API")?;
    if response.status().as_u16() >= 400 {
        bail!("Codex Reset juice API returned HTTP {}", response.status());
    }
    let juice = response
        .body_mut()
        .read_json::<ResetJuice>()
        .context("failed to decode the Codex Reset juice response")?;
    Ok(juice)
}

fn fetch_reset_posts(now: OffsetDateTime) -> Result<Vec<TiboPost>> {
    match fetch_feed_posts(now) {
        Ok(posts) if !posts.is_empty() => Ok(posts),
        Ok(_) => fetch_tibo_posts(now),
        Err(feed_error) => {
            let posts = fetch_tibo_posts(now).with_context(|| {
                format!(
                    "failed to load both public reset sources; Codex Reset radar error: {feed_error:#}"
                )
            })?;
            Ok(posts)
        }
    }
}

fn fetch_feed_posts(now: OffsetDateTime) -> Result<Vec<TiboPost>> {
    let mut response = ureq::get(RESET_FEED_ENDPOINT)
        .header(
            "User-Agent",
            "Mozilla/5.0 (compatible; CodexRoster/0.2; +https://github.com/anlvdt/codex-roster)",
        )
        .config()
        .timeout_global(Some(std::time::Duration::from_secs(6)))
        .build()
        .call()
        .context("failed to contact the independent Codex Reset radar")?;
    if response.status().as_u16() >= 400 {
        bail!("Codex Reset radar returned HTTP {}", response.status());
    }
    let feed = response
        .body_mut()
        .read_json::<ResetFeed>()
        .context("failed to decode the Codex Reset radar feed")?;
    if feed.stale {
        bail!("Codex Reset radar returned stale data");
    }
    let fetched_at = parse_event_time(&feed.fetched_at)
        .context("Codex Reset radar returned an invalid freshness timestamp")?;
    if (now - fetched_at).abs() > time::Duration::minutes(15) {
        bail!("Codex Reset radar returned data older than 15 minutes");
    }

    let mut posts = feed
        .tweets
        .into_iter()
        .filter_map(|mut tweet| {
            let id = tweet.id.take()?;
            let created_at = tweet.at.take()?;
            let text = tweet.text.take()?;
            let url = trusted_tibo_post_url(&id)?;
            Some(TiboPost {
                id,
                created_at,
                text,
                url,
            })
        })
        .collect::<Vec<_>>();
    posts.sort_by(|left, right| right.created_at.cmp(&left.created_at));
    Ok(posts)
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

        if let (Some(id), Some(created_at), Some(text)) = (
            meta_content(block, "identifier"),
            meta_content(block, "datePublished"),
            meta_content(block, "text"),
        ) && seen.insert(id.clone())
            && let Some(url) = trusted_tibo_post_url(&id)
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

fn trusted_tibo_post_url(id: &str) -> Option<String> {
    (!id.is_empty() && id.chars().all(|character| character.is_ascii_digit()))
        .then(|| format!("https://x.com/thsottiaux/status/{id}"))
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
    let starts_with_reset_signal = [
        "reset will ",
        "reset should ",
        "reset lands ",
        "reset has ",
        "reset is ",
    ]
    .iter()
    .any(|prefix| text.trim_start().starts_with(prefix));
    let relevant_scope = text.contains("codex")
        || text.contains("chatgpt work")
        || text.contains("usage limit")
        || text.contains("rate limit")
        || text.contains("paid user")
        || text.contains("banked reset")
        || starts_with_reset_signal;
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
        "it's landed",
        "it is landed",
        "it is done",
        "it's done",
        "has been credited",
        "have been credited",
        "have reset",
        "has reset",
        "i've reset",
        "we've reset",
        "i have reset",
        "we have reset",
        "limits have been reset",
        "limit has been reset",
        "usage limits have been reset",
        "usage limits are reset",
        "usage limits reset",
        "usage limit reset",
        "rate limits reset",
        "rate limit reset",
        "reset the rate limits",
        "reset usage limits",
        "reset rate limits",
        "reset everyone's usage limits",
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
        "will do a full reset",
        "do a full reset",
        "will be there",
        "will land",
        "should land",
        "lands in",
        "land in",
        "propagating in the next hour",
        "in the next hour",
        "next 30 minutes",
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

    let contextual_scope = text.contains("codex")
        || text.contains("chatgpt work")
        || text.contains("usage limit")
        || text.contains("rate limit");
    let is_hint = ["reset button", "there is still time", "little surprise"]
        .iter()
        .any(|phrase| text.contains(phrase))
        && (contextual_scope || text.contains("little surprise"));
    is_hint.then_some(SignalKind::Hint)
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
    events: Vec<ResetEvent>,
    now: OffsetDateTime,
) -> Result<Vec<ResetEvent>> {
    fs::create_dir_all(app_data_dir)
        .with_context(|| format!("failed to create {}", app_data_dir.display()))?;
    let state_path = app_data_dir.join(NOTIFICATION_STATE_FILE);
    let existing = fs::read(&state_path)
        .ok()
        .and_then(|bytes| serde_json::from_slice::<NotificationState>(&bytes).ok())
        .filter(|state| state.source == NOTIFICATION_SOURCE);

    let mut eligible_events = events
        .iter()
        .filter(|event| {
            parse_event_time(&event.announced_at).is_some_and(|announced_at| announced_at <= now)
        })
        .collect::<Vec<_>>();
    eligible_events.sort_by(|left, right| {
        right
            .announced_at
            .cmp(&left.announced_at)
            .then_with(|| right.id.cmp(&left.id))
    });
    eligible_events.truncate(MAX_SEEN_EVENT_IDS);

    let Some(mut state) = existing else {
        let fresh = eligible_events
            .iter()
            .filter(|event| {
                parse_event_time(&event.announced_at).is_some_and(|announced_at| {
                    let age = now - announced_at;
                    age >= time::Duration::ZERO && age <= INITIAL_REPLAY_WINDOW
                })
            })
            .max_by(|left, right| left.announced_at.cmp(&right.announced_at))
            .map(|event| (*event).clone())
            .into_iter()
            .collect::<Vec<_>>();
        let mut state = NotificationState {
            initialized_at: format_time(now),
            seen_ids: HashSet::new(),
            source: NOTIFICATION_SOURCE.to_owned(),
            notification_window_started_at: Some(format_time(now)),
            notifications_in_window: fresh.len(),
        };
        record_seen_event_ids(&mut state, &eligible_events);
        write_notification_state(&state_path, &state)?;
        return Ok(fresh);
    };

    let initialized_at = parse_event_time(&state.initialized_at).unwrap_or(now);
    let mut fresh = eligible_events
        .iter()
        .filter(|event| !state.seen_ids.contains(&event.id))
        .filter(|event| {
            parse_event_time(&event.announced_at)
                .is_some_and(|announced_at| announced_at >= initialized_at && announced_at <= now)
        })
        .map(|event| (*event).clone())
        .collect::<Vec<_>>();
    fresh.sort_by(|left, right| left.announced_at.cmp(&right.announced_at));
    refresh_notification_window(&mut state, now);
    let remaining_notifications =
        MAX_NOTIFICATIONS_PER_HOUR.saturating_sub(state.notifications_in_window);
    if fresh.len() > remaining_notifications {
        fresh.drain(..fresh.len() - remaining_notifications);
    }
    state.notifications_in_window += fresh.len();
    record_seen_event_ids(&mut state, &eligible_events);
    write_notification_state(&state_path, &state)?;
    Ok(fresh)
}

fn refresh_notification_window(state: &mut NotificationState, now: OffsetDateTime) {
    let window_is_active = state
        .notification_window_started_at
        .as_deref()
        .and_then(parse_event_time)
        .is_some_and(|started_at| {
            let age = now - started_at;
            age >= time::Duration::ZERO && age < time::Duration::hours(1)
        });
    if !window_is_active {
        state.notification_window_started_at = Some(format_time(now));
        state.notifications_in_window = 0;
    }
}

fn record_seen_event_ids(state: &mut NotificationState, events: &[&ResetEvent]) {
    let mut current = events.to_vec();
    current.sort_by(|left, right| right.announced_at.cmp(&left.announced_at));

    let mut retained = current
        .into_iter()
        .map(|event| event.id.clone())
        .take(MAX_SEEN_EVENT_IDS)
        .collect::<HashSet<_>>();
    if retained.len() < MAX_SEEN_EVENT_IDS {
        let mut previous = state.seen_ids.iter().cloned().collect::<Vec<_>>();
        previous.sort_unstable_by(|left, right| right.cmp(left));
        for id in previous {
            if retained.len() == MAX_SEEN_EVENT_IDS {
                break;
            }
            retained.insert(id);
        }
    }
    state.seen_ids = retained;
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
        assert_eq!(
            posts[0].url,
            "https://x.com/thsottiaux/status/2090964822422949999"
        );
    }

    #[test]
    fn canonicalizes_profile_links_and_rejects_invalid_post_ids() {
        let html = r#"<main><article itemType="https://schema.org/SocialMediaPosting"><meta content="2090964822422949999" itemProp="identifier"/><meta content="2026-08-22T00:50:36.000Z" itemProp="datePublished"/><meta content="file:///etc/passwd" itemProp="url"/><meta content="Codex usage limits have reset." itemProp="text"/></article><article itemType="https://schema.org/SocialMediaPosting"><meta content="../escape" itemProp="identifier"/><meta content="2026-08-22T00:51:36.000Z" itemProp="datePublished"/><meta content="https://evil.example/phish" itemProp="url"/><meta content="Codex usage limits have reset." itemProp="text"/></article></main>"#;
        let posts = parse_profile_posts(html);
        assert_eq!(posts.len(), 1);
        assert_eq!(
            posts[0].url,
            "https://x.com/thsottiaux/status/2090964822422949999"
        );
        assert!(trusted_tibo_post_url("../escape").is_none());
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
        assert_eq!(classify_post("I've reset my password."), None);
        assert_eq!(classify_post("We have reset the staging database."), None);
        assert_eq!(classify_post("Reset my password tomorrow."), None);
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
        let polled_at = parse_event_time("2026-08-04T00:00:00Z").unwrap();
        let fresh =
            process_reset_events(temp.path(), vec![second.clone(), first.clone()], polled_at)
                .expect("new reset signals");
        assert_eq!(
            fresh
                .iter()
                .map(|event| event.id.as_str())
                .collect::<Vec<_>>(),
            vec!["first", "second"]
        );
        assert!(
            process_reset_events(temp.path(), vec![first, second], polled_at)
                .expect("deduplicated")
                .is_empty()
        );
    }

    #[test]
    fn future_signals_wait_until_their_announcement_time() {
        let temp = tempfile::tempdir().expect("temp dir");
        let started = parse_event_time("2026-08-01T00:00:00Z").unwrap();
        process_reset_events(temp.path(), Vec::new(), started).expect("initialize state");
        let future = reset_event("future", "2026-08-01T01:00:00Z", "scheduled_global_reset");

        assert!(
            process_reset_events(temp.path(), vec![future.clone()], started)
                .expect("future signal deferred")
                .is_empty()
        );
        assert_eq!(
            process_reset_events(
                temp.path(),
                vec![future],
                parse_event_time("2026-08-01T01:00:00Z").unwrap(),
            )
            .expect("signal announced")
            .len(),
            1
        );
    }

    #[test]
    fn notification_state_and_fanout_are_bounded() {
        let temp = tempfile::tempdir().expect("temp dir");
        let started = parse_event_time("2026-08-01T00:00:00Z").unwrap();
        process_reset_events(temp.path(), Vec::new(), started).expect("initialize state");
        let events = (0..600)
            .map(|index| {
                reset_event(
                    &format!("{index:04}"),
                    "2026-08-01T01:00:00Z",
                    "confirmed_global_reset",
                )
            })
            .collect::<Vec<_>>();
        let fresh = process_reset_events(
            temp.path(),
            events.clone(),
            parse_event_time("2026-08-01T02:00:00Z").unwrap(),
        )
        .expect("bounded poll");
        assert_eq!(fresh.len(), MAX_NOTIFICATIONS_PER_HOUR);

        let state: NotificationState = serde_json::from_slice(
            &fs::read(temp.path().join(NOTIFICATION_STATE_FILE)).expect("state file"),
        )
        .expect("state json");
        assert_eq!(state.seen_ids.len(), MAX_SEEN_EVENT_IDS);
        assert!(
            process_reset_events(
                temp.path(),
                events,
                parse_event_time("2026-08-01T02:01:00Z").unwrap(),
            )
            .expect("same oversized feed is deduplicated")
            .is_empty()
        );
        let alternate_events = (600..1_200)
            .map(|index| {
                reset_event(
                    &format!("{index:04}"),
                    "2026-08-01T02:01:30Z",
                    "confirmed_global_reset",
                )
            })
            .collect::<Vec<_>>();
        assert!(
            process_reset_events(
                temp.path(),
                alternate_events,
                parse_event_time("2026-08-01T02:02:00Z").unwrap(),
            )
            .expect("hourly notification budget is exhausted")
            .is_empty()
        );
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
