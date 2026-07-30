use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};

const FORECAST_ENDPOINT: &str = "https://codex-reset.com/api/forecast";

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
}
