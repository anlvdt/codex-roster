use std::collections::HashSet;
use std::fs;
use std::path::Path;

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use time::OffsetDateTime;

/// Public Codex reset outlook / commitment API (codex-resets.com).
const RESETS_STATUS_ENDPOINT: &str = "https://codex-resets.com/api/v1/status";
const RESETS_LIST_ENDPOINT: &str = "https://codex-resets.com/api/v1/resets?limit=40";

const SITE_HOME: &str = "https://codex-resets.com/";
const USER_AGENT: &str =
    "Mozilla/5.0 (compatible; CodexRoster/0.2; +https://github.com/anlvdt/codex-roster)";

const NOTIFICATION_STATE_FILE: &str = "reset-notifications.json";
const INITIAL_REPLAY_WINDOW: time::Duration = time::Duration::hours(6);
const NOTIFICATION_SOURCE: &str = "codex-resets:v1";
const MAX_SEEN_EVENT_IDS: usize = 512;
const MAX_NOTIFICATIONS_PER_HOUR: usize = 8;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ResetOutlook {
    pub updated_at: String,
    pub last_reset_at: String,
    pub next_reset_at: Option<String>,
    pub last_reset_is_confirmed: bool,
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
// Outlook: Codex Resets public status only
// ---------------------------------------------------------------------------

pub fn fetch_reset_outlook() -> Result<ResetOutlook> {
    let status = fetch_resets_status()?;
    Ok(outlook_from_status(&status))
}

fn outlook_from_status(status: &ResetsStatusResponse) -> ResetOutlook {
    let signal = resolve_outlook_signal(Some(status));
    ResetOutlook {
        updated_at: status
            .meta
            .as_ref()
            .and_then(|m| m.generated_at.clone())
            .unwrap_or_default(),
        last_reset_at: status
            .data
            .stats
            .as_ref()
            .and_then(|s| s.last_reset_at.clone())
            .or_else(|| {
                status
                    .data
                    .latest_reset
                    .as_ref()
                    .and_then(|r| r.announced_at.clone())
            })
            .unwrap_or_default(),
        next_reset_at: signal.next_reset_at,
        last_reset_is_confirmed: signal.last_reset_is_confirmed,
        window_label: signal.window_label.unwrap_or_default(),
        window_timezone: signal.window_timezone,
        window_start_hour: None,
        window_end_hour: None,
        signal_kind: signal.signal_kind,
        signal_summary: signal.signal_summary,
        source_url: signal.source_url,
        source_freshness: "codex_resets_api".to_owned(),
        cadence_days: status.data.stats.as_ref().and_then(|s| s.avg_interval_days),
        cadence_accelerating: None,
    }
}

struct ResolvedOutlookSignal {
    signal_kind: String,
    signal_summary: String,
    source_url: String,
    last_reset_is_confirmed: bool,
    next_reset_at: Option<String>,
    window_label: Option<String>,
    window_timezone: Option<String>,
}

fn resolve_outlook_signal(status: Option<&ResetsStatusResponse>) -> ResolvedOutlookSignal {
    if let Some(scheduled) = status.and_then(|s| s.data.scheduled_reset.as_ref()) {
        return resolve_scheduled_status_signal(scheduled);
    }
    if let Some(watch) = status.and_then(|s| s.data.active_watch.as_ref()) {
        return resolve_active_watch_signal(watch);
    }
    if let Some(latest) = status.and_then(|s| s.data.latest_reset.as_ref()) {
        return ResolvedOutlookSignal {
            signal_kind: map_completed_reset_kind(latest.reset_type.as_deref()).to_owned(),
            signal_summary: latest.text.clone().unwrap_or_default(),
            source_url: source_url_from(latest.source.as_ref(), latest.id.as_deref()),
            last_reset_is_confirmed: true,
            next_reset_at: None,
            window_label: None,
            window_timezone: None,
        };
    }
    ResolvedOutlookSignal {
        signal_kind: "none".to_owned(),
        signal_summary: "No actionable Codex reset signal from the public API.".to_owned(),
        source_url: SITE_HOME.to_owned(),
        last_reset_is_confirmed: false,
        next_reset_at: None,
        window_label: None,
        window_timezone: None,
    }
}

fn resolve_scheduled_status_signal(scheduled: &ResetsScheduledReset) -> ResolvedOutlookSignal {
    ResolvedOutlookSignal {
        signal_kind: map_scheduled_reset_kind(scheduled.reset_type.as_deref()).to_owned(),
        signal_summary: scheduled.text.clone().unwrap_or_default(),
        source_url: source_url_from(scheduled.source.as_ref(), scheduled.id.as_deref()),
        last_reset_is_confirmed: false,
        next_reset_at: scheduled.scheduled_for.clone(),
        window_label: None,
        window_timezone: None,
    }
}

fn resolve_active_watch_signal(watch: &ResetsWatch) -> ResolvedOutlookSignal {
    ResolvedOutlookSignal {
        signal_kind: "reset_hint".to_owned(),
        signal_summary: watch
            .text
            .clone()
            .or_else(|| watch.summary.clone())
            .unwrap_or_default(),
        source_url: source_url_from(watch.source.as_ref(), watch.id.as_deref()),
        last_reset_is_confirmed: false,
        next_reset_at: watch
            .scheduled_for
            .clone()
            .or_else(|| watch.target_at.clone()),
        window_label: watch.label.clone(),
        window_timezone: None,
    }
}

fn map_scheduled_reset_kind(reset_type: Option<&str>) -> &'static str {
    match reset_type {
        Some("banked") => "scheduled_banked_reset",
        _ => "scheduled_global_reset",
    }
}

fn map_completed_reset_kind(reset_type: Option<&str>) -> &'static str {
    match reset_type {
        Some("banked") => "confirmed_banked_reset",
        _ => "confirmed_global_reset",
    }
}

fn source_url_from(source: Option<&ResetsSource>, id: Option<&str>) -> String {
    if let Some(url) = source.and_then(|s| s.url.clone())
        && trusted_https_url(&url).is_some()
    {
        return url;
    }
    id.and_then(trusted_status_post_url)
        .unwrap_or_else(|| SITE_HOME.to_owned())
}

fn trusted_status_post_url(id: &str) -> Option<String> {
    let digits = id.strip_prefix("observed-").unwrap_or(id);
    (!digits.is_empty() && digits.chars().all(|character| character.is_ascii_digit()))
        .then(|| format!("https://x.com/thsottiaux/status/{digits}"))
}

fn trusted_https_url(value: &str) -> Option<&str> {
    let lower = value.to_ascii_lowercase();
    if !(lower.starts_with("https://x.com/") || lower.starts_with("https://codex-resets.com/")) {
        return None;
    }
    if value.contains([' ', '\n', '\r', '\t']) {
        return None;
    }
    Some(value)
}

fn fetch_resets_status() -> Result<ResetsStatusResponse> {
    get_json(RESETS_STATUS_ENDPOINT, "Codex Resets status API")
}

fn fetch_resets_list() -> Result<ResetsListResponse> {
    get_json(RESETS_LIST_ENDPOINT, "Codex Resets list API")
}

fn get_json<T: for<'de> Deserialize<'de>>(url: &str, label: &str) -> Result<T> {
    let mut response = ureq::get(url)
        .header("User-Agent", USER_AGENT)
        .header("Accept", "application/json")
        .config()
        .timeout_global(Some(std::time::Duration::from_secs(8)))
        .build()
        .call()
        .with_context(|| format!("failed to contact the {label}"))?;
    if response.status().as_u16() >= 400 {
        bail!("{label} returned HTTP {}", response.status());
    }
    response
        .body_mut()
        .read_json::<T>()
        .with_context(|| format!("failed to decode the {label} response"))
}

#[derive(Deserialize)]
struct ResetsStatusResponse {
    data: ResetsStatusData,
    #[serde(default)]
    meta: Option<ResetsMeta>,
}

#[derive(Deserialize)]
struct ResetsStatusData {
    #[serde(default)]
    latest_reset: Option<ResetsAnnouncement>,
    #[serde(default)]
    scheduled_reset: Option<ResetsScheduledReset>,
    #[serde(default)]
    active_watch: Option<ResetsWatch>,
    #[serde(default)]
    stats: Option<ResetsStats>,
}

#[derive(Deserialize)]
struct ResetsListResponse {
    #[serde(default)]
    data: Vec<ResetsAnnouncement>,
}

#[derive(Clone, Debug, Deserialize)]
struct ResetsAnnouncement {
    id: Option<String>,
    reset_type: Option<String>,
    announced_at: Option<String>,
    text: Option<String>,
    #[serde(default)]
    source: Option<ResetsSource>,
}

#[derive(Clone, Debug, Deserialize)]
struct ResetsScheduledReset {
    id: Option<String>,
    reset_type: Option<String>,
    announced_at: Option<String>,
    scheduled_for: Option<String>,
    text: Option<String>,
    #[serde(default)]
    source: Option<ResetsSource>,
}

#[derive(Clone, Debug, Deserialize)]
struct ResetsWatch {
    id: Option<String>,
    text: Option<String>,
    summary: Option<String>,
    label: Option<String>,
    scheduled_for: Option<String>,
    target_at: Option<String>,
    #[serde(default)]
    source: Option<ResetsSource>,
}

#[derive(Clone, Debug, Deserialize)]
struct ResetsSource {
    url: Option<String>,
}

#[derive(Deserialize)]
struct ResetsStats {
    last_reset_at: Option<String>,
    avg_interval_days: Option<f64>,
}

#[derive(Deserialize)]
struct ResetsMeta {
    generated_at: Option<String>,
}

// ---------------------------------------------------------------------------
// Reset events: public API only (no local classifier / X scrape)
// ---------------------------------------------------------------------------

/// Return new Codex reset signals from the public Codex Resets API.
/// A first poll replays only very recent actionable signals so an app started
/// after an announcement still tells the user, without replaying old history.
pub fn fetch_new_reset_events(app_data_dir: &Path) -> Result<Vec<ResetEvent>> {
    let now = OffsetDateTime::now_utc();
    let mut events = Vec::new();

    match fetch_resets_status() {
        Ok(status) => {
            if let Some(event) = scheduled_status_event(status.data.scheduled_reset.as_ref()) {
                push_unique_event(&mut events, event);
            }
            if let Some(event) =
                announcement_event(status.data.latest_reset.as_ref(), map_completed_reset_kind)
            {
                push_unique_event(&mut events, event);
            }
            if let Some(event) = watch_event(status.data.active_watch.as_ref()) {
                push_unique_event(&mut events, event);
            }
        }
        Err(error) => {
            // The list endpoint can still supply confirmed events when status is unavailable.
            let _ = error;
        }
    }

    if let Ok(list) = fetch_resets_list() {
        for announcement in list.data {
            if let Some(event) = announcement_event(Some(&announcement), map_completed_reset_kind) {
                push_unique_event(&mut events, event);
            }
        }
    }

    process_reset_events(app_data_dir, events, now)
}

fn push_unique_event(events: &mut Vec<ResetEvent>, event: ResetEvent) {
    if !events.iter().any(|existing| existing.id == event.id) {
        events.push(event);
    }
}

fn scheduled_status_event(scheduled: Option<&ResetsScheduledReset>) -> Option<ResetEvent> {
    let scheduled = scheduled?;
    let id = scheduled.id.clone()?;
    let announced_at = scheduled.announced_at.clone()?;
    let summary = scheduled.text.clone().unwrap_or_default();
    if summary.trim().is_empty() {
        return None;
    }
    Some(ResetEvent {
        id: id.clone(),
        announced_at,
        summary,
        url: source_url_from(scheduled.source.as_ref(), Some(&id)),
        kind: map_scheduled_reset_kind(scheduled.reset_type.as_deref()).to_owned(),
    })
}

fn announcement_event(
    announcement: Option<&ResetsAnnouncement>,
    kind_for: fn(Option<&str>) -> &'static str,
) -> Option<ResetEvent> {
    let announcement = announcement?;
    let id = announcement.id.clone()?;
    let announced_at = announcement.announced_at.clone()?;
    let summary = announcement.text.clone().unwrap_or_default();
    if summary.trim().is_empty() {
        return None;
    }
    Some(ResetEvent {
        id: id.clone(),
        announced_at,
        summary,
        url: source_url_from(announcement.source.as_ref(), Some(&id)),
        kind: kind_for(announcement.reset_type.as_deref()).to_owned(),
    })
}

fn watch_event(watch: Option<&ResetsWatch>) -> Option<ResetEvent> {
    let watch = watch?;
    let id = watch.id.clone()?;
    let announced_at = watch
        .scheduled_for
        .clone()
        .or_else(|| watch.target_at.clone())?;
    let summary = watch
        .text
        .clone()
        .or_else(|| watch.summary.clone())
        .unwrap_or_default();
    if summary.trim().is_empty() {
        return None;
    }
    Some(ResetEvent {
        id: id.clone(),
        announced_at,
        summary,
        url: source_url_from(watch.source.as_ref(), Some(&id)),
        kind: "reset_hint".to_owned(),
    })
}

// ---------------------------------------------------------------------------
// Reset Timeline
// ---------------------------------------------------------------------------

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
    let list = fetch_resets_list()?;
    Ok(ResetTimeline {
        updated_at: format_time(OffsetDateTime::now_utc()),
        events: list
            .data
            .iter()
            .filter_map(|item| {
                let event = announcement_event(Some(item), map_completed_reset_kind)?;
                Some(ResetTimelineEvent {
                    id: event.id,
                    date: event.announced_at.chars().take(10).collect(),
                    event_type: event.kind,
                    summary: event.summary,
                    url: event.url,
                    announced_at: event.announced_at,
                    scope: None,
                    confidence: None,
                    reset_kind: item.reset_type.clone(),
                    audience: None,
                })
            })
            .collect(),
    })
}

// ---------------------------------------------------------------------------
// Reset Status History
// ---------------------------------------------------------------------------

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
    bail!("Codex Resets does not publish service status history; use the OpenAI status command.")
}

// ---------------------------------------------------------------------------
// Reset Juice (quota effort tiers)
// ---------------------------------------------------------------------------

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
    bail!("Codex Resets does not publish effort tiers.")
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
    fn status_only_outlook_preserves_schedule_without_probabilities() {
        let status: ResetsStatusResponse = serde_json::from_value(serde_json::json!({
            "data": {
                "scheduled_reset": {"id":"123", "reset_type":"banked", "scheduled_for":"2026-09-23T07:00:00Z", "text":"Banked reset scheduled"},
                "stats": {"last_reset_at":"2026-09-12T08:00:00Z", "avg_interval_days":6.9}
            },
            "meta": {"generated_at":"2026-09-22T12:00:00Z"}
        })).unwrap();
        let result = outlook_from_status(&status);
        assert_eq!(result.signal_kind, "scheduled_banked_reset");
        assert_eq!(
            result.next_reset_at.as_deref(),
            Some("2026-09-23T07:00:00Z")
        );
        let json = serde_json::to_value(result).unwrap();
        for key in [
            "chance_24_hours",
            "chance_48_hours",
            "signal_percent",
            "confidence",
        ] {
            assert!(json.get(key).is_none());
        }
    }

    #[test]
    fn absent_status_never_invents_a_schedule() {
        let signal = resolve_outlook_signal(None);
        assert_eq!(signal.signal_kind, "none");
        assert!(signal.next_reset_at.is_none());
    }

    #[test]
    fn maps_api_reset_types_without_local_classifier() {
        assert_eq!(
            map_scheduled_reset_kind(Some("banked")),
            "scheduled_banked_reset"
        );
        assert_eq!(
            map_completed_reset_kind(Some("banked")),
            "confirmed_banked_reset"
        );
        assert_eq!(
            map_completed_reset_kind(Some("regular")),
            "confirmed_global_reset"
        );
        assert!(trusted_status_post_url("../escape").is_none());
        assert_eq!(
            trusted_status_post_url("2090964822422949999").as_deref(),
            Some("https://x.com/thsottiaux/status/2090964822422949999")
        );
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
