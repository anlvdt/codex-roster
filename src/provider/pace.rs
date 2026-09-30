use time::OffsetDateTime;

pub(crate) const WEEKLY_PERIOD: time::Duration = time::Duration::days(7);
pub(crate) const SUPPRESS_AFTER_RESET: time::Duration = time::Duration::hours(24);
pub(crate) const AHEAD_THRESHOLD_PERCENT: u8 = 15;

#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct Pace {
    pub expected_percent: u8,
    pub ahead: bool,
    pub projected_exhaustion_at: Option<OffsetDateTime>,
    pub will_last_to_reset: bool,
}

pub(crate) fn compute_pace(
    used_percent: u8,
    reset_at: OffsetDateTime,
    fetched_at: OffsetDateTime,
    period: time::Duration,
) -> Option<Pace> {
    let period_secs = period.whole_seconds();
    if period_secs <= 0 {
        return None;
    }
    let remaining = (reset_at - fetched_at)
        .whole_seconds()
        .rem_euclid(period_secs);
    let elapsed = if remaining == 0 {
        0
    } else {
        period_secs - remaining
    };
    if elapsed < SUPPRESS_AFTER_RESET.whole_seconds() {
        return None;
    }
    let expected = ((elapsed as f64 / period_secs as f64) * 100.0)
        .min(100.0)
        .round() as u8;
    let ahead = i32::from(used_percent) - i32::from(expected) >= i32::from(AHEAD_THRESHOLD_PERCENT);
    let (projected_exhaustion_at, will_last_to_reset) = if used_percent == 0 {
        (None, true)
    } else {
        let rate_per_second = f64::from(used_percent) / elapsed as f64;
        let projected = fetched_at
            + time::Duration::seconds_f64(
                (100.0 - f64::from(used_percent)).max(0.0) / rate_per_second,
            );
        (Some(projected), projected >= reset_at)
    };
    Some(Pace {
        expected_percent: expected,
        ahead,
        projected_exhaustion_at,
        will_last_to_reset,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const WEEK: time::Duration = WEEKLY_PERIOD;

    #[test]
    fn suppressed_inside_first_day_after_reset() {
        // reset in 6.5 days → elapsed 12h < 24h → None
        let fetched = OffsetDateTime::UNIX_EPOCH;
        let reset = fetched + time::Duration::hours(24 * 6 + 12);
        assert!(compute_pace(80, reset, fetched, WEEK).is_none());
    }

    #[test]
    fn ahead_when_used_far_above_expected() {
        // reset in 5.6 days → elapsed 1.4 days = 20% of the week
        let fetched = OffsetDateTime::UNIX_EPOCH;
        let reset = fetched + time::Duration::seconds_f64(24.0 * 5.6 * 3600.0);
        let pace = compute_pace(40, reset, fetched, WEEK).expect("pace");
        assert_eq!(pace.expected_percent, 20);
        assert!(pace.ahead);
    }

    #[test]
    fn on_pace_projects_past_reset() {
        // reset in 3.5 days → elapsed 50%; 20% used → projected hits 100 at 40% of
        // remaining cycle → will last.
        let fetched = OffsetDateTime::UNIX_EPOCH;
        let reset = fetched + time::Duration::seconds_f64(24.0 * 3.5 * 3600.0);
        let pace = compute_pace(20, reset, fetched, WEEK).expect("pace");
        assert!(!pace.ahead);
        let projected = pace.projected_exhaustion_at.expect("projection");
        assert!(projected >= reset);
        assert!(pace.will_last_to_reset);
    }

    #[test]
    fn heavy_usage_does_not_last_to_reset() {
        // elapsed 30% (2.1 days); 90% used → hits 100 at ~1/3 of the week
        let fetched = OffsetDateTime::UNIX_EPOCH;
        let reset = fetched + time::Duration::seconds_f64(24.0 * 4.9 * 3600.0);
        let pace = compute_pace(90, reset, fetched, WEEK).expect("pace");
        assert!(pace.ahead);
        assert!(!pace.will_last_to_reset);
    }

    #[test]
    fn stale_reset_folds_into_current_cycle() {
        // reset_at two whole weeks ago + 5.6 days back — remaining folds to 5.6d,
        // same as a fresh timestamp.
        let fetched = OffsetDateTime::UNIX_EPOCH;
        let stale_reset =
            fetched - time::Duration::days(14) + time::Duration::seconds_f64(24.0 * 5.6 * 3600.0);
        let pace = compute_pace(40, stale_reset, fetched, WEEK).expect("pace");
        assert_eq!(pace.expected_percent, 20);
    }

    #[test]
    fn zero_usage_never_exhausts() {
        let fetched = OffsetDateTime::UNIX_EPOCH;
        let reset = fetched + time::Duration::days(3);
        let pace = compute_pace(0, reset, fetched, WEEK).expect("pace");
        assert!(pace.projected_exhaustion_at.is_none());
        assert!(pace.will_last_to_reset);
    }
}
