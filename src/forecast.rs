//! Burn-rate forecast over recorded quota samples.
//!
//! The forecast answers "when does this window run out?" from the samples the
//! app already records (`quota_history`), so the answer needs no network call
//! and no extra state. It is deliberately conservative: a rate below
//! [`MIN_RATE_PER_MINUTE`] is treated as "not burning" (an infinite estimate is
//! not useful to show), and every estimate carries a confidence level so the UI
//! can avoid presenting a two-sample guess as fact.

use crate::model::WindowForecast;
use crate::quota_history::QuotaSample;

/// Weight of the newest rate sample in the EWMA.
pub const EWMA_ALPHA: f64 = 0.3;
/// Weight of the newest residual in the variance EWMA.
pub const EWMA_VARIANCE_ALPHA: f64 = 0.2;
/// Below this burn rate (%/minute) the window is not meaningfully draining.
pub const MIN_RATE_PER_MINUTE: f64 = 0.01;
/// Samples closer together than this cannot produce a trustworthy rate.
pub const MIN_SAMPLE_GAP_MINUTES: i64 = 1;
/// Window length in minutes, used to ignore samples from an earlier window.
pub const FIVE_HOUR_WINDOW_MINUTES: i64 = 5 * 60;
pub const WEEKLY_WINDOW_MINUTES: i64 = 7 * 24 * 60;
/// z for a 95% interval.
pub const Z_95: f64 = 1.96;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WindowKind {
    FiveHour,
    Weekly,
}

impl WindowKind {
    pub fn label(self) -> &'static str {
        match self {
            Self::FiveHour => "five_hour",
            Self::Weekly => "weekly",
        }
    }

    pub fn window_minutes(self) -> i64 {
        match self {
            Self::FiveHour => FIVE_HOUR_WINDOW_MINUTES,
            Self::Weekly => WEEKLY_WINDOW_MINUTES,
        }
    }

    fn remaining_of(self, sample: &QuotaSample) -> i8 {
        match self {
            Self::FiveHour => sample.five_remaining,
            Self::Weekly => sample.week_remaining,
        }
    }
}

/// One observed `(minute, used_percent)` point inside the current window.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct BurnPoint {
    pub minute: i64,
    pub used_percent: f64,
}

/// Keep only usable samples from the current window, oldest first.
///
/// `remaining < 0` marks an unknown sample, and anything older than one window
/// length predates a reset we cannot reason about.
pub fn burn_points(samples: &[QuotaSample], kind: WindowKind, now_minute: i64) -> Vec<BurnPoint> {
    let mut points = samples
        .iter()
        .filter(|sample| sample.minute <= now_minute)
        .filter(|sample| now_minute - sample.minute <= kind.window_minutes())
        .filter_map(|sample| {
            let remaining = kind.remaining_of(sample);
            (remaining >= 0).then_some(BurnPoint {
                minute: sample.minute,
                used_percent: 100.0 - f64::from(remaining),
            })
        })
        .collect::<Vec<_>>();
    points.sort_by_key(|point| point.minute);
    points.dedup_by_key(|point| point.minute);
    points
}

/// Rate samples in %/minute. Resets (a drop in used %) and too-close samples are
/// dropped: both would otherwise produce a negative or wildly inflated burn.
pub fn burn_rates(points: &[BurnPoint]) -> Vec<f64> {
    points
        .windows(2)
        .filter_map(|pair| {
            let (previous, current) = (pair[0], pair[1]);
            let delta_minutes = current.minute - previous.minute;
            if delta_minutes < MIN_SAMPLE_GAP_MINUTES {
                return None;
            }
            let delta_used = current.used_percent - previous.used_percent;
            if delta_used < 0.0 {
                return None;
            }
            Some(delta_used / delta_minutes as f64)
        })
        .collect()
}

/// EWMA burn rate plus the EWMA variance used for the confidence interval.
pub fn ewma_rate(rates: &[f64]) -> Option<(f64, f64)> {
    let (first, rest) = rates.split_first()?;
    let mut mean = *first;
    let mut variance = 0.0;
    for rate in rest {
        let residual = rate - mean;
        mean = EWMA_ALPHA * rate + (1.0 - EWMA_ALPHA) * mean;
        variance =
            EWMA_VARIANCE_ALPHA * residual * residual + (1.0 - EWMA_VARIANCE_ALPHA) * variance;
    }
    Some((mean, variance))
}

fn confidence_label(
    sample_count: usize,
    coefficient_of_variation: f64,
    age_minutes: i64,
) -> &'static str {
    if sample_count >= 4 && coefficient_of_variation <= 0.35 && age_minutes <= 10 {
        "high"
    } else if sample_count >= 2 && coefficient_of_variation <= 0.60 && age_minutes <= 30 {
        "medium"
    } else {
        "low"
    }
}

/// Forecast one window.
///
/// `remaining_percent` is the live/cached remaining percentage (0..=100); the
/// samples only supply the burn rate. Returns `None` when the window has no
/// usable samples at all, so callers can omit the field instead of inventing one.
pub fn forecast_window(
    samples: &[QuotaSample],
    kind: WindowKind,
    remaining_percent: f64,
    now_minute: i64,
) -> Option<WindowForecast> {
    let points = burn_points(samples, kind, now_minute);
    if points.is_empty() {
        return None;
    }
    let rates = burn_rates(&points);
    let newest_age_minutes = now_minute
        - points
            .last()
            .map(|point| point.minute)
            .unwrap_or(now_minute);
    let remaining = remaining_percent.clamp(0.0, 100.0);

    let Some((rate, variance)) = ewma_rate(&rates) else {
        // One sample is enough to report "no trend yet", not enough for a time.
        return Some(WindowForecast {
            window: kind.label().to_owned(),
            remaining_percent: remaining,
            burn_per_minute: 0.0,
            time_to_empty_minutes: None,
            ci_low_minutes: None,
            ci_high_minutes: None,
            confidence: "low".to_owned(),
            sample_count: points.len(),
        });
    };

    let standard_deviation = variance.max(0.0).sqrt();
    let coefficient_of_variation = if rate > 0.0 {
        standard_deviation / rate
    } else {
        0.0
    };

    let (time_to_empty, ci_low, ci_high) = if rate < MIN_RATE_PER_MINUTE {
        (None, None, None)
    } else {
        let tte = remaining / rate;
        let spread = Z_95 * coefficient_of_variation * tte;
        (Some(tte), Some((tte - spread).max(0.0)), Some(tte + spread))
    };

    Some(WindowForecast {
        window: kind.label().to_owned(),
        remaining_percent: remaining,
        burn_per_minute: rate,
        time_to_empty_minutes: time_to_empty,
        ci_low_minutes: ci_low,
        ci_high_minutes: ci_high,
        confidence: confidence_label(rates.len(), coefficient_of_variation, newest_age_minutes)
            .to_owned(),
        sample_count: points.len(),
    })
}

/// Human line for one forecast, e.g.
/// `5h: còn 8% · cạn sau ~22 phút (CI 14–35) · confidence medium`.
pub fn describe_window(window: &WindowForecast, vietnamese: bool) -> String {
    let label = match window.window.as_str() {
        // Both languages use "5h"; only the weekly label differs.
        "five_hour" => "5h",
        _ => {
            if vietnamese {
                "tuần"
            } else {
                "week"
            }
        }
    };
    let remaining = format!("{:.0}%", window.remaining_percent);
    let head = if vietnamese {
        format!("{label}: còn {remaining}")
    } else {
        format!("{label}: {remaining} left")
    };
    let tail = match (
        window.time_to_empty_minutes,
        window.ci_low_minutes,
        window.ci_high_minutes,
    ) {
        (Some(tte), Some(low), Some(high)) => {
            if vietnamese {
                format!(
                    "cạn sau ~{} (CI {}–{})",
                    humanize_minutes(tte, true),
                    humanize_minutes(low, true),
                    humanize_minutes(high, true)
                )
            } else {
                format!(
                    "empty in ~{} (CI {}–{})",
                    humanize_minutes(tte, false),
                    humanize_minutes(low, false),
                    humanize_minutes(high, false)
                )
            }
        }
        _ => {
            if vietnamese {
                "chưa thấy tiêu hao".to_owned()
            } else {
                "no measurable burn".to_owned()
            }
        }
    };
    let burn = if window.burn_per_minute > 0.0 {
        format!(" · {:.2}%/phút", window.burn_per_minute)
    } else {
        String::new()
    };
    format!("{head} · {tail}{burn} · confidence {}", window.confidence)
}

fn humanize_minutes(minutes: f64, vietnamese: bool) -> String {
    let rounded = minutes.max(0.0).round() as i64;
    if rounded >= 120 {
        let hours = rounded / 60;
        let rest = rounded % 60;
        if rest == 0 {
            if vietnamese {
                format!("{hours} giờ")
            } else {
                format!("{hours}h")
            }
        } else if vietnamese {
            format!("{hours} giờ {rest} phút")
        } else {
            format!("{hours}h {rest}m")
        }
    } else if vietnamese {
        format!("{rounded} phút")
    } else {
        format!("{rounded}m")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample(minute: i64, five: i8, week: i8) -> QuotaSample {
        QuotaSample {
            minute,
            five_remaining: five,
            week_remaining: week,
        }
    }

    /// Drain 1% every 5 minutes and finish at `remaining`: rate 0.2%/min.
    fn steady_series(now: i64, remaining: i8) -> Vec<QuotaSample> {
        let steps = 8i64;
        (0..steps)
            .map(|step| {
                let value = i64::from(remaining) + (steps - 1 - step);
                sample(now - (steps - 1 - step) * 5, value.clamp(0, 100) as i8, 90)
            })
            .collect()
    }

    #[test]
    fn steady_burn_produces_a_tight_estimate() {
        let now = 30_000_000;
        let samples = steady_series(now, 20);
        let forecast =
            forecast_window(&samples, WindowKind::FiveHour, 20.0, now).expect("forecast");
        assert_eq!(forecast.sample_count, 8);
        let rate = forecast.burn_per_minute;
        assert!((rate - 0.2).abs() < 0.02, "rate {rate} should be ~0.2%/min");
        let tte = forecast.time_to_empty_minutes.expect("tte");
        assert!(
            (tte - 100.0).abs() < 20.0,
            "tte {tte} should be ~100 minutes"
        );
        let low = forecast.ci_low_minutes.expect("ci low");
        let high = forecast.ci_high_minutes.expect("ci high");
        assert!(low <= tte && tte <= high, "CI must bracket the estimate");
        assert_eq!(forecast.confidence, "high");
    }

    #[test]
    fn burst_burn_widens_the_interval_and_lowers_confidence() {
        let now = 30_000_000;
        let samples = vec![
            sample(now - 40, 90, 90),
            sample(now - 35, 88, 90),
            sample(now - 30, 70, 90),
            sample(now - 25, 69, 90),
            sample(now - 20, 30, 90),
            sample(now - 15, 29, 90),
            sample(now - 10, 5, 90),
        ];
        let forecast = forecast_window(&samples, WindowKind::FiveHour, 5.0, now).expect("forecast");
        let tte = forecast.time_to_empty_minutes.expect("tte");
        let low = forecast.ci_low_minutes.expect("ci low");
        let high = forecast.ci_high_minutes.expect("ci high");
        assert!(
            high - low > tte,
            "an erratic series must widen the interval"
        );
        assert_ne!(forecast.confidence, "high");
    }

    #[test]
    fn a_reset_inside_the_series_is_ignored() {
        let now = 30_000_000;
        let samples = vec![
            sample(now - 30, 80, 90),
            sample(now - 25, 75, 90),
            // Window reset: remaining jumps back up.
            sample(now - 20, 100, 90),
            sample(now - 15, 95, 90),
        ];
        let forecast =
            forecast_window(&samples, WindowKind::FiveHour, 95.0, now).expect("forecast");
        // Only the two post-reset points count; the drop contributes no rate.
        assert_eq!(forecast.sample_count, 4);
        let rate = forecast.burn_per_minute;
        assert!(rate > 0.0, "post-reset burn must still be positive: {rate}");
        assert!(
            rate < 1.5,
            "the reset drop must not inflate the rate: {rate}"
        );
    }

    #[test]
    fn a_single_sample_reports_low_confidence_without_a_time() {
        let now = 30_000_000;
        let samples = vec![sample(now - 5, 60, 60)];
        let forecast =
            forecast_window(&samples, WindowKind::FiveHour, 60.0, now).expect("forecast");
        assert_eq!(forecast.sample_count, 1);
        assert_eq!(forecast.confidence, "low");
        assert!(forecast.time_to_empty_minutes.is_none());
    }

    #[test]
    fn zero_burn_has_no_time_to_empty() {
        let now = 30_000_000;
        let samples = vec![
            sample(now - 20, 100, 90),
            sample(now - 15, 100, 90),
            sample(now - 10, 100, 90),
        ];
        let forecast =
            forecast_window(&samples, WindowKind::FiveHour, 100.0, now).expect("forecast");
        assert!(forecast.burn_per_minute < MIN_RATE_PER_MINUTE);
        assert!(forecast.time_to_empty_minutes.is_none());
        assert!(describe_window(&forecast, true).contains("chưa thấy tiêu hao"));
    }

    #[test]
    fn samples_from_an_earlier_window_are_ignored() {
        let now = 30_000_000;
        let samples = vec![
            // Older than one 5h window.
            sample(now - FIVE_HOUR_WINDOW_MINUTES - 60, 10, 10),
            sample(now - 10, 80, 80),
        ];
        let forecast =
            forecast_window(&samples, WindowKind::FiveHour, 80.0, now).expect("forecast");
        assert_eq!(forecast.sample_count, 1, "only the in-window sample counts");
    }

    #[test]
    fn regression_fixture_has_a_stable_estimate() {
        let now = 1_000_000;
        // 2% used per 10 minutes => 0.2%/min; 40% left => ~200 minutes.
        let samples: Vec<QuotaSample> = (0..=6)
            .map(|step| sample(now - (6 - step) * 10, (60 - step * 2) as i8, 80))
            .collect();
        let forecast =
            forecast_window(&samples, WindowKind::FiveHour, 40.0, now).expect("forecast");
        let tte = forecast.time_to_empty_minutes.expect("tte");
        assert!(
            (tte - 200.0).abs() < 5.0,
            "expected ~200 minutes, got {tte} (rate {})",
            forecast.burn_per_minute
        );
    }

    #[test]
    fn description_mentions_window_remaining_and_confidence() {
        let now = 30_000_000;
        let samples = steady_series(now, 20);
        let forecast =
            forecast_window(&samples, WindowKind::FiveHour, 20.0, now).expect("forecast");
        let text = describe_window(&forecast, true);
        assert!(text.contains("5h"));
        assert!(text.contains("20%"));
        assert!(text.contains("confidence"));
    }
}
