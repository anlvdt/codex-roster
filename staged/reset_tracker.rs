use std::collections::HashSet;
use std::fs;
use std::path::Path;

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use time::OffsetDateTime;

const FORECAST_ENDPOINT: &str = "https://codex-reset.com/api/forecast";
const TIMELINE_ENDPOINT: &str = "https://codex-reset.com/api/timeline";
const NOTIFICATION_STATE_FILE: &str = "reset-notifications.json";

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ResetOutlook {
    pub updated_at: String,
    pub last_reset_at: String,
    pub chance_24_hours: u8,
    pub chance_48_hours: u8,
    pub confidence: String,
    pub window_label: String,
}

#[derive(Deserialize)]
struct ForecastResponse {
    updated_at: String,
    last_reset_at: String,
    probabilities: Probabilities,
    confidence: String,
    time_window: TimeWindow,
}

#[derive(Deserialize)]
struct Probabilities {
    rounded_24h: u8,
    rounded_48h: u8,
}

#[derive(Deserialize)]
struct TimeWindow {
    label: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ResetEvent {
    pub id: String,
    pub announced_at: String,
    pub summary: String,
    pub url: String,
}

#[derive(Deserialize)]
struct TimelineResponse {
    events: Vec<TimelineEvent>,
}

#[derive(Clone, Deserialize)]
struct TimelineEvent {
    id: String,
    #[serde(rename = "type")]
    event_type: String,
    group: String,
    summary: String,
    url: String,
    announced_at: String,
    #[serde(default)]
    preview: bool,
    scope: String,
}

#[derive(Default, Serialize, Deserialize)]
struct NotificationState {
    initialized_at: String,
    seen_ids: HashSet<String>,
}

pub fn fetch_reset_outlook() -> Result<ResetOutlook> {
    let mut response = ureq::get(FORECAST_ENDPOINT)
        .header("User-Agent", "codex-roster")
        .config()
        .timeout_global(Some(std::time::Duration::from_secs(5)))
        .build()
        .call()
        .context("failed to contact the Codex Reset forecast")?;
    if response.status().as_u16() >= 400 {
        bail!("Codex Reset forecast returned HTTP {}", response.status());
    }
    let forecast = response
        .body_mut()
        .read_json::<ForecastResponse>()
        .context("failed to decode the Codex Reset forecast")?;
    Ok(ResetOutlook {
        updated_at: forecast.updated_at,
        last_reset_at: forecast.last_reset_at,
        chance_24_hours: forecast.probabilities.rounded_24h,
        chance_48_hours: forecast.probabilities.rounded_48h,
        confidence: forecast.confidence,
        window_label: forecast.time_window.label,
    })
}

/// Return each verified global reset that appeared after notification tracking
/// was initialized. The first call establishes a baseline instead of replaying
/// the full historical timeline.
pub fn fetch_new_reset_events(app_data_dir: &Path) -> Result<Vec<ResetEvent>> {
    let mut response = ureq::get(TIMELINE_ENDPOINT)
        .header("User-Agent", "codex-roster")
        .config()
        .timeout_global(Some(std::time::Duration::from_secs(5)))
        .build()
        .call()
        .context("failed to contact the Codex Reset timeline")?;
    if response.status().as_u16() >= 400 {
        bail!("Codex Reset timeline returned HTTP {}", response.status());
    }
    let timeline = response
        .body_mut()
        .read_json::<TimelineResponse>()
        .context("failed to decode the Codex Reset timeline")?;
    process_reset_events(
        app_data_dir,
        canonical_reset_events(timeline.events),
        OffsetDateTime::now_utc(),
    )
}

fn canonical_reset_events(events: Vec<TimelineEvent>) -> Vec<ResetEvent> {
    let confirmed_times: Vec<OffsetDateTime> = events
        .iter()
        .filter(|event| {
            event.event_type == "reset"
                && event.group == "reset"
                && event.scope == "global"
                && !event.preview
        })
        .filter_map(|event| parse_event_time(&event.announced_at))
        .collect();

    events
        .into_iter()
        .filter(|event| {
            event.event_type == "reset"
                && event.group == "reset"
                && event.scope == "global"
                && (!event.preview || !preview_has_confirmation(event, confirmed_times.as_slice()))
        })
        .map(|event| ResetEvent {
            id: event.id,
            announced_at: event.announced_at,
            summary: event.summary,
            url: event.url,
        })
        .collect()
}

fn preview_has_confirmation(event: &TimelineEvent, confirmed_times: &[OffsetDateTime]) -> bool {
    let Some(preview_at) = parse_event_time(&event.announced_at) else {
        return false;
    };
    confirmed_times.iter().any(|confirmed_at| {
        *confirmed_at >= preview_at && *confirmed_at - preview_at <= time::Duration::hours(12)
    })
}

fn parse_event_time(value: &str) -> Option<OffsetDateTime> {
    OffsetDateTime::parse(value, &time::format_description::well_known::Rfc3339).ok()
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
        .and_then(|bytes| serde_json::from_slice::<NotificationState>(&bytes).ok());

    let Some(mut state) = existing else {
        let state = NotificationState {
            initialized_at: now.format(&time::format_description::well_known::Rfc3339)?,
            seen_ids: events.iter().map(|event| event.id.clone()).collect(),
        };
        write_notification_state(&state_path, &state)?;
        return Ok(Vec::new());
    };

    let initialized_at = OffsetDateTime::parse(
        &state.initialized_at,
        &time::format_description::well_known::Rfc3339,
    )
    .unwrap_or(now);
    let mut fresh = events
        .iter()
        .filter(|event| !state.seen_ids.contains(&event.id))
        .filter(|event| {
            OffsetDateTime::parse(
                &event.announced_at,
                &time::format_description::well_known::Rfc3339,
            )
            .is_ok_and(|announced_at| announced_at >= initialized_at)
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
    fn parses_public_forecast_payload() {
        let payload = r#"{"updated_at":"2026-07-30T06:13:41.070Z","last_reset_at":"2026-07-29T04:09:02.000Z","probabilities":{"rounded_24h":15,"rounded_48h":30},"confidence":"medium","time_window":{"label":"3 AM - 6 AM"}}"#;
        let parsed: ForecastResponse = serde_json::from_str(payload).expect("forecast payload");
        assert_eq!(parsed.probabilities.rounded_48h, 30);
        assert_eq!(parsed.time_window.label, "3 AM - 6 AM");
    }

    #[test]
    fn first_poll_baselines_then_returns_every_new_reset_once() {
        let temp = tempfile::tempdir().expect("temp dir");
        let started = OffsetDateTime::parse(
            "2026-08-01T00:00:00Z",
            &time::format_description::well_known::Rfc3339,
        )
        .expect("start time");
        let historical = reset_event("old", "2026-07-31T12:00:00Z");
        assert!(
            process_reset_events(temp.path(), vec![historical.clone()], started)
                .expect("baseline")
                .is_empty()
        );

        let first = reset_event("first", "2026-08-02T12:00:00Z");
        let second = reset_event("second", "2026-08-03T12:00:00Z");
        let fresh = process_reset_events(
            temp.path(),
            vec![second.clone(), historical, first.clone()],
            started,
        )
        .expect("new resets");
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

    #[test]
    fn canonical_timeline_avoids_preview_and_confirmation_double_notifications() {
        let events = vec![
            timeline_event("preview", "2026-08-08", true),
            timeline_event("confirmed", "2026-08-08", false),
            timeline_event("preview-only", "2026-08-09", true),
        ];
        let canonical = canonical_reset_events(events);
        assert_eq!(
            canonical
                .iter()
                .map(|event| event.id.as_str())
                .collect::<Vec<_>>(),
            vec!["confirmed", "preview-only"]
        );
    }

    fn reset_event(id: &str, announced_at: &str) -> ResetEvent {
        ResetEvent {
            id: id.to_owned(),
            announced_at: announced_at.to_owned(),
            summary: format!("Reset {id}"),
            url: format!("https://example.com/{id}"),
        }
    }

    fn timeline_event(id: &str, date: &str, preview: bool) -> TimelineEvent {
        TimelineEvent {
            id: id.to_owned(),
            event_type: "reset".to_owned(),
            group: "reset".to_owned(),
            summary: format!("Reset {id}"),
            url: format!("https://example.com/{id}"),
            announced_at: format!("{date}T12:00:00Z"),
            preview,
            scope: "global".to_owned(),
        }
    }
}
