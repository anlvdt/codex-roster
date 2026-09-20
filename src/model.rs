use serde::{Deserialize, Serialize};
use time::OffsetDateTime;
use uuid::Uuid;

pub const SNAPSHOT_SCHEMA_VERSION: u32 = 1;
pub const METADATA_SCHEMA_VERSION: u32 = 1;
pub const AUTH_FILES: [&str; 2] = ["auth.json", "cap_sid"];

#[derive(Clone, Copy, Debug, Default, Serialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "snake_case")]
pub enum AiProvider {
    #[default]
    OpenAi,
    Claude,
    Cursor,
    Grok,
}

impl<'de> Deserialize<'de> for AiProvider {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let value = String::deserialize(deserializer)?;
        match value.trim().to_ascii_lowercase().as_str() {
            "open_ai" | "openai" | "codex" => Ok(Self::OpenAi),
            "claude" | "anthropic" => Ok(Self::Claude),
            "cursor" => Ok(Self::Cursor),
            "grok" | "grok_build" | "xai" => Ok(Self::Grok),
            _ => Err(serde::de::Error::unknown_variant(
                &value,
                &["open_ai", "claude", "cursor", "grok"],
            )),
        }
    }
}

impl std::fmt::Display for AiProvider {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Self::OpenAi => "OpenAI / Codex",
            Self::Claude => "Claude Code",
            Self::Cursor => "Cursor",
            Self::Grok => "Grok Build",
        })
    }
}

impl AiProvider {
    pub const ALL: [Self; 4] = [Self::OpenAi, Self::Claude, Self::Cursor, Self::Grok];

    pub const fn slug(self) -> &'static str {
        match self {
            Self::OpenAi => "open_ai",
            Self::Claude => "claude",
            Self::Cursor => "cursor",
            Self::Grok => "grok",
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum EnvironmentKind {
    Windows,
    Wsl,
    Linux,
    Macos,
}

impl std::fmt::Display for EnvironmentKind {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let value = match self {
            Self::Windows => "windows",
            Self::Wsl => "wsl",
            Self::Linux => "linux",
            Self::Macos => "macos",
        };
        f.write_str(value)
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct SnapshotBlob {
    pub schema_version: u32,
    pub files: Vec<SnapshotFile>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct SnapshotFile {
    pub name: String,
    pub bytes_base64: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct DisplayIdentity {
    pub email: String,
    pub subject: Option<String>,
    pub name: Option<String>,
    pub plan_label: Option<String>,
}

impl DisplayIdentity {
    pub fn matches(&self, other: &Self) -> bool {
        match (&self.subject, &other.subject) {
            (Some(left), Some(right)) => left == right,
            _ => self.email.eq_ignore_ascii_case(&other.email),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{AiProvider, DisplayIdentity, EnvironmentKind, SavedAccountMetadata};

    fn identity(email: &str, subject: Option<&str>) -> DisplayIdentity {
        DisplayIdentity {
            email: email.to_owned(),
            subject: subject.map(str::to_owned),
            name: None,
            plan_label: None,
        }
    }

    #[test]
    fn matches_falls_back_to_email_when_either_subject_is_missing() {
        assert!(
            identity("person@example.com", Some("sub-1"))
                .matches(&identity("PERSON@example.com", None))
        );
        assert!(
            identity("person@example.com", None)
                .matches(&identity("PERSON@example.com", Some("sub-1")))
        );
        assert!(
            identity("person@example.com", None).matches(&identity("PERSON@example.com", None))
        );
        assert!(
            !identity("person@example.com", Some("sub-1"))
                .matches(&identity("other@example.com", None))
        );
    }

    #[test]
    fn provider_tags_decode_explicitly() {
        let provider: AiProvider = serde_json::from_str("\"cursor\"").expect("provider");
        assert_eq!(provider, AiProvider::Cursor);
        let legacy_openai: AiProvider = serde_json::from_str("\"codex\"").expect("legacy openai");
        assert_eq!(legacy_openai, AiProvider::OpenAi);
        let xai: AiProvider = serde_json::from_str("\"xai\"").expect("xai alias");
        assert_eq!(xai, AiProvider::Grok);
        assert_eq!(
            serde_json::to_string(&legacy_openai).expect("serialize provider"),
            "\"open_ai\""
        );
        assert!(serde_json::from_str::<AiProvider>("\"future_provider\"").is_err());
    }

    #[test]
    fn legacy_saved_account_provider_tags_normalize_to_openai() {
        let metadata = SavedAccountMetadata {
            id: uuid::Uuid::nil(),
            environment: EnvironmentKind::Macos,
            provider: AiProvider::OpenAi,
            email: "person@example.com".to_owned(),
            subject: Some("subject-1".to_owned()),
            name: None,
            custom_label: None,
            plan_label: None,
            secret_key: "secret-key".to_owned(),
            created_at: time::OffsetDateTime::UNIX_EPOCH,
            updated_at: time::OffsetDateTime::UNIX_EPOCH,
            last_activated_at: None,
            archived: false,
            cached_usage: None,
            cached_usage_error: None,
        };
        let mut value = serde_json::to_value(metadata).expect("serialize legacy metadata");
        value["provider"] = serde_json::Value::String("cursor".to_owned());

        let decoded: SavedAccountMetadata =
            serde_json::from_value(value).expect("deserialize legacy metadata");

        assert_eq!(decoded.provider, AiProvider::OpenAi);
    }
}

fn deserialize_legacy_openai_provider<'de, D>(deserializer: D) -> Result<AiProvider, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let _ = String::deserialize(deserializer)?;
    Ok(AiProvider::OpenAi)
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SavedAccountMetadata {
    pub id: Uuid,
    pub environment: EnvironmentKind,
    #[serde(default, deserialize_with = "deserialize_legacy_openai_provider")]
    pub provider: AiProvider,
    pub email: String,
    pub subject: Option<String>,
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub custom_label: Option<String>,
    pub plan_label: Option<String>,
    pub secret_key: String,
    pub created_at: OffsetDateTime,
    pub updated_at: OffsetDateTime,
    pub last_activated_at: Option<OffsetDateTime>,
    #[serde(default)]
    pub archived: bool,
    #[serde(default)]
    pub cached_usage: Option<AccountUsageView>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cached_usage_error: Option<String>,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct MetadataIndex {
    pub schema_version: u32,
    #[serde(default)]
    pub write_generation: u64,
    pub accounts: Vec<SavedAccountMetadata>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct AccountView {
    pub id: Uuid,
    pub provider: AiProvider,
    pub email: String,
    pub subject: Option<String>,
    pub name: Option<String>,
    pub custom_label: Option<String>,
    pub plan_label: Option<String>,
    pub environment: EnvironmentKind,
    pub is_active: bool,
    pub created_at: OffsetDateTime,
    pub updated_at: OffsetDateTime,
    pub last_activated_at: Option<OffsetDateTime>,
    pub archived: bool,
    pub usage: Option<AccountUsageView>,
    pub usage_error: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
pub struct StatusOutput {
    pub environment: EnvironmentKind,
    pub codex_root: String,
    pub current_account: Option<DisplayIdentity>,
    pub current_account_saved_id: Option<Uuid>,
    pub saved_accounts: usize,
    pub process_warnings: Vec<RunningCodexProcess>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub vibe_usage: Option<crate::vibe_usage::VibeUsageSummary>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub codex_model: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
pub struct ListOutput {
    pub environment: EnvironmentKind,
    pub accounts: Vec<AccountView>,
}

#[derive(Clone, Debug, Serialize)]
pub struct UsageOutput {
    pub environment: EnvironmentKind,
    pub account: DisplayIdentity,
    pub usage: AccountUsageView,
}

#[derive(Clone, Debug, Serialize)]
pub struct EnableLunaReserveOutput {
    pub status: String,
    pub account_email: String,
    pub model: String,
    pub previous_model: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
pub struct AutoStartUsageWindowsStatusOutput {
    pub enabled: bool,
    pub poll_seconds: u64,
}

#[derive(Clone, Debug, Serialize)]
pub struct AutoStartUsageWindowsRunOutput {
    pub enabled: bool,
    pub checked_accounts: usize,
    pub pinged_accounts: Vec<AutoStartUsageWindowAccountResult>,
    pub skipped: Vec<String>,
}

#[derive(Clone, Debug, Serialize)]
pub struct AutoSwitchOutput {
    pub enabled: bool,
    pub status: String,
    pub active_account_id: Option<Uuid>,
    pub candidate_account_id: Option<Uuid>,
    pub candidate_display_name: Option<String>,
    pub detail: Option<String>,
    /// A reset is available, but has not been redeemed into immediately usable quota.
    pub banked_reset_count: i64,
    /// Target-account resume hint after a successful switch (optional).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_resume: Option<SessionResumeHint>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct SessionResumeHint {
    pub enabled: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub account_id: Option<Uuid>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rollout_path: Option<String>,
    /// disabled | missing | ready | ready_cli | cwd_gone | rollout_gone
    pub status: String,
}

#[derive(Clone, Debug, Serialize)]
pub struct AutoResumeSessionStatusOutput {
    pub enabled: bool,
}

#[derive(Clone, Debug, Serialize)]
pub struct AutoStartUsageWindowAccountResult {
    pub account_id: Uuid,
    pub email: String,
    pub status: String,
    pub detail: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
pub struct SaveOutput {
    pub account: AccountView,
    pub action: SaveAction,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum SaveAction {
    Created,
    Refreshed,
}

#[derive(Clone, Debug, Serialize)]
pub struct ImportJsonOutput {
    pub format: String,
    pub created: usize,
    pub updated: usize,
    pub accounts: Vec<AccountView>,
}

#[derive(Clone, Debug, Serialize)]
pub struct ActivateOutput {
    pub account: AccountView,
    pub previous_account_id: Option<Uuid>,
    pub warnings: Vec<RunningCodexProcess>,
    /// Resume hint for the account just activated (when Auto-resume is on).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_resume: Option<SessionResumeHint>,
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
pub struct RunningCodexProcess {
    pub pid: u32,
    pub executable: String,
    pub role: String,
    pub summary: Option<String>,
    /// "desktop" (ChatGPT/Codex.app/plugin) or "cli". Optional for older tests.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub origin: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
pub struct DeleteOutput {
    pub deleted_account_id: Uuid,
}

#[derive(Clone, Debug, Serialize)]
pub struct LegacyRecoveryOutput {
    pub recovered_accounts: usize,
    pub imported_accounts: usize,
    pub skipped_accounts: usize,
}

#[derive(Clone, Debug, Serialize)]
pub struct TokenUsageSummaryOutput {
    pub today: u64,
    pub last_7_days: u64,
    pub last_30_days: u64,
    pub last_365_days: u64,
    pub all_time: u64,
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cached_input_tokens: u64,
    pub cache_write_input_tokens: u64,
    pub reasoning_output_tokens: u64,
    pub cache_hit_percent: u8,
    pub daily: Vec<TokenUsageDayOutput>,
    pub by_model: Vec<TokenUsageBreakdownOutput>,
    pub by_project: Vec<TokenUsageBreakdownOutput>,
    pub sessions_scanned: usize,
    pub token_events: usize,
    #[serde(default)]
    pub estimated_cost_usd: f64,
    #[serde(default)]
    pub today_cost_usd: f64,
    #[serde(default)]
    pub last_7_days_cost_usd: f64,
    #[serde(default)]
    pub last_30_days_cost_usd: f64,
    #[serde(default)]
    pub main_sessions: usize,
    #[serde(default)]
    pub subagent_sessions: usize,
}

#[derive(Clone, Debug, Serialize)]
pub struct TokenUsageDayOutput {
    pub date: String,
    pub tokens: u64,
    #[serde(default)]
    pub cost_usd: f64,
}

#[derive(Clone, Debug, Serialize)]
pub struct TokenUsageBreakdownOutput {
    pub label: String,
    pub tokens: u64,
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cached_input_tokens: u64,
    pub cache_write_input_tokens: u64,
    pub reasoning_output_tokens: u64,
    pub token_events: usize,
    #[serde(default)]
    pub estimated_cost_usd: f64,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct AccountUsageView {
    pub source: UsageSource,
    pub fetched_at: OffsetDateTime,
    pub five_hour: Option<UsageWindowView>,
    pub weekly: Option<UsageWindowView>,
    pub credits: Option<CreditsView>,
    /// Per-account Codex rate-limit reset credits. This is distinct from
    /// ChatGPT spend credits and from community-wide reset announcements.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub banked_resets: Option<BankedResetSummaryView>,
    /// Plan returned by this usage fetch. Distinct from roster metadata so
    /// auto-switch does not trust a stale Plus/Pro label when the API omitted it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub plan_label: Option<String>,
    /// End of the currently active ChatGPT subscription period reported by
    /// OpenAI's ID-token claim. This is separate from OAuth token expiry.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subscription_active_until: Option<OffsetDateTime>,
    /// Luna Reserve fallback status. Present when an account has access to the
    /// GPT-5.6 Luna reserve pool after primary model exhaustion.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub luna_reserve: Option<LunaReserveView>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct LunaReserveView {
    pub allowed: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub used_percent: Option<u8>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reset_at: Option<OffsetDateTime>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model_slug: Option<String>,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ProviderCapability {
    ReadIdentity,
    MonitorUsage,
    LocalActivity,
    TokenHistory,
    SnapshotAuth,
    SwitchAccount,
    AutoSwitch,
    RelaunchApp,
    ApiBilling,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ProviderUsageStatus {
    Ok,
    Stale,
    NeedsAuth,
    AccessDenied,
    CredentialExpired,
    RateLimited,
    Unsupported,
    Error,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum UsageFidelity {
    Official,
    Derived,
    Manual,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct ProviderUsageWindowView {
    pub key: String,
    pub label: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub used_percent: Option<u8>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub remaining_percent: Option<u8>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reset_at: Option<OffsetDateTime>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub used: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub limit: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub unit: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct ProviderUsageView {
    pub provider: AiProvider,
    pub fetched_at: OffsetDateTime,
    pub status: ProviderUsageStatus,
    pub fidelity: UsageFidelity,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub headline_window: Option<String>,
    #[serde(default)]
    pub windows: Vec<ProviderUsageWindowView>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub plan_label: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
pub struct ProviderStateView {
    pub provider: AiProvider,
    pub available: bool,
    pub capabilities: Vec<ProviderCapability>,
    pub identity: Option<DisplayIdentity>,
    pub saved_accounts: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub current_account_saved_id: Option<Uuid>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub usage: Option<ProviderUsageView>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub usage_error: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
pub struct ProviderStatusOutput {
    pub environment: EnvironmentKind,
    pub providers: Vec<ProviderStateView>,
}

#[derive(Clone, Debug, Serialize)]
pub struct ProviderUsageOutput {
    pub environment: EnvironmentKind,
    pub account: DisplayIdentity,
    pub usage: ProviderUsageView,
}

#[derive(Clone, Debug, Serialize)]
pub struct ProviderAccountView {
    pub id: Uuid,
    pub provider: AiProvider,
    pub email: String,
    pub subject: Option<String>,
    pub name: Option<String>,
    pub custom_label: Option<String>,
    pub plan_label: Option<String>,
    pub environment: EnvironmentKind,
    pub is_active: bool,
    pub created_at: OffsetDateTime,
    pub updated_at: OffsetDateTime,
    pub last_activated_at: Option<OffsetDateTime>,
    pub usage: Option<ProviderUsageView>,
    pub usage_error: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
pub struct ProviderListOutput {
    pub environment: EnvironmentKind,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub provider: Option<AiProvider>,
    pub accounts: Vec<ProviderAccountView>,
}

#[derive(Clone, Debug, Serialize)]
pub struct ProviderSaveOutput {
    pub account: ProviderAccountView,
    pub action: SaveAction,
}

#[derive(Clone, Debug, Serialize)]
pub struct ProviderActivateOutput {
    pub account: ProviderAccountView,
    pub previous_account_id: Option<Uuid>,
    pub requires_relaunch: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct UsageWindowView {
    pub used_percent: u8,
    pub remaining_percent: u8,
    pub reset_at: OffsetDateTime,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct CreditsView {
    pub has_credits: bool,
    pub unlimited: bool,
    /// Displayable spend balance. An empty string means the backend did not
    /// publish a readable balance for this fetch — it is not a real zero.
    pub balance: String,
    /// Monthly spend-control cap (team/enterprise workspaces report the credit
    /// pool here instead of a personal balance).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub credit_limit: Option<CreditLimitView>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct CreditLimitView {
    pub used: Option<f64>,
    pub limit: f64,
    pub remaining_percent: f64,
    pub resets_at: Option<OffsetDateTime>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct BankedResetSummaryView {
    pub available_count: i64,
    /// `None` means the authenticated usage response only exposed the count.
    /// The backend may cap this list below `available_count`.
    pub credits: Option<Vec<BankedResetCreditView>>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct BankedResetCreditView {
    pub id: String,
    pub reset_type: String,
    pub status: String,
    pub granted_at: OffsetDateTime,
    pub expires_at: Option<OffsetDateTime>,
    pub title: Option<String>,
    pub description: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum UsageSource {
    LiveAccessToken,
    LiveRefreshToken,
    SavedAccessToken,
    SavedRefreshToken,
}
