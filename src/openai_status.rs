use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;

const SUMMARY_ENDPOINT: &str = "https://status.openai.com/api/v2/summary.json";

#[derive(Clone, Debug, Serialize)]
pub struct OpenAiStatus {
    pub indicator: String,
    pub description: String,
    pub updated_at: String,
    pub codex_components: Vec<OpenAiComponent>,
}

#[derive(Clone, Debug, Serialize)]
pub struct OpenAiComponent {
    pub name: String,
    pub status: String,
}

#[derive(Deserialize)]
struct SummaryResponse {
    page: StatusPage,
    status: OverallStatus,
    components: Vec<Component>,
}

#[derive(Deserialize)]
struct StatusPage {
    updated_at: String,
}

#[derive(Deserialize)]
struct OverallStatus {
    indicator: String,
    description: String,
}

#[derive(Deserialize)]
struct Component {
    name: String,
    status: String,
}

pub fn fetch_openai_status() -> Result<OpenAiStatus> {
    let mut response = ureq::get(SUMMARY_ENDPOINT)
        .header("User-Agent", "codex-roster")
        .config()
        .timeout_global(Some(std::time::Duration::from_secs(5)))
        .build()
        .call()
        .context("failed to contact OpenAI Status")?;
    if response.status().as_u16() >= 400 {
        bail!("OpenAI Status returned HTTP {}", response.status());
    }
    let summary = response
        .body_mut()
        .read_json::<SummaryResponse>()
        .context("failed to decode OpenAI Status")?;
    let mut seen_components = HashSet::new();
    let codex_components = summary
        .components
        .into_iter()
        .filter(|component| is_codex_relevant(&component.name))
        .filter(|component| seen_components.insert(component.name.clone()))
        .map(|component| OpenAiComponent {
            name: component.name,
            status: component.status,
        })
        .collect();

    Ok(OpenAiStatus {
        indicator: summary.status.indicator,
        description: summary.status.description,
        updated_at: summary.page.updated_at,
        codex_components,
    })
}

fn is_codex_relevant(name: &str) -> bool {
    let name = name.to_ascii_lowercase();
    name.contains("codex") || name == "login"
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn selects_codex_and_login_components() {
        let payload = r#"{
          "page":{"updated_at":"2026-07-30T00:00:00Z"},
          "status":{"indicator":"none","description":"All Systems Operational"},
          "components":[
            {"name":"Codex API","status":"operational"},
            {"name":"Login","status":"degraded_performance"},
            {"name":"Images","status":"operational"}
          ]
        }"#;
        let summary: SummaryResponse = serde_json::from_str(payload).expect("summary payload");
        let selected: Vec<_> = summary
            .components
            .iter()
            .filter(|component| is_codex_relevant(&component.name))
            .collect();
        assert_eq!(selected.len(), 2);
        assert_eq!(selected[0].name, "Codex API");
    }
}
