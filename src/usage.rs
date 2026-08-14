use std::sync::{LazyLock, Mutex};

use anyhow::{Context, Result, anyhow, bail};
use base64::Engine;
use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use serde::Deserialize;
use serde_json::{Map, Value};
use time::format_description::well_known::Rfc3339;
use time::{Duration, OffsetDateTime};

use crate::identity::parse_identity_from_auth_json;
use crate::model::{
    AccountUsageView, CreditsView, DisplayIdentity, EnvironmentKind, SnapshotBlob, UsageOutput,
    UsageSource, UsageWindowView,
};

static CHATGPT_CLIENT_ID: &str = "app_EMoamEEZ73f0CkXaXp7hrann";
static USAGE_ENDPOINT: &str = "https://chatgpt.com/backend-api/wham/usage";
static REFRESH_ENDPOINT: &str = "https://auth.openai.com/oauth/token";
/// Matches Codex CLI: treat ChatGPT-managed sessions as stale after ~8 days.
static TOKEN_REFRESH_INTERVAL: LazyLock<Duration> = LazyLock::new(|| Duration::days(8));
/// Matches ChatGPT web / Codex CLI: refresh access tokens inside the 5-minute near-expiry window.
static ACCESS_TOKEN_REFRESH_SKEW: LazyLock<Duration> = LazyLock::new(|| Duration::minutes(5));
/// Serialize OAuth refresh calls process-wide. Refresh tokens are single-use; concurrent
/// refreshes of the same session invalidate each other and force re-login.
static TOKEN_REFRESH_LOCK: Mutex<()> = Mutex::new(());

#[derive(Clone, Debug)]
pub struct UsageTarget {
    pub environment: EnvironmentKind,
    pub identity: DisplayIdentity,
    pub snapshot: SnapshotBlob,
    pub source: UsageSource,
    pub allow_refresh: bool,
}

/// Usage failed, but OAuth tokens may already have been rotated and must be persisted.
#[derive(Debug)]
pub struct FetchUsageError {
    error: anyhow::Error,
    pub refreshed_snapshot: Option<SnapshotBlob>,
}

impl FetchUsageError {
    fn new(error: anyhow::Error, refreshed_snapshot: Option<SnapshotBlob>) -> Self {
        Self {
            error,
            refreshed_snapshot,
        }
    }

    pub fn error(&self) -> &anyhow::Error {
        &self.error
    }

    pub fn into_error(self) -> anyhow::Error {
        self.error
    }
}

impl std::fmt::Display for FetchUsageError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{:#}", self.error)
    }
}

impl std::error::Error for FetchUsageError {}

pub fn fetch_usage(target: UsageTarget) -> Result<(UsageOutput, SnapshotBlob), FetchUsageError> {
    let mut auth =
        snapshot_auth(&target.snapshot).map_err(|error| FetchUsageError::new(error, None))?;
    let mut source = target.source;

    if target.allow_refresh && needs_proactive_refresh(&auth) {
        match refresh_auth(&auth) {
            Ok(refreshed) => {
                auth = refreshed;
                source = refresh_source(source);
            }
            Err(error) if is_transient_refresh_error(&error) => {
                // Keep the existing access token; a later 401 path can still retry.
            }
            Err(error) => {
                return Err(FetchUsageError::new(error, None));
            }
        }
    }

    let response = match fetch_usage_response(&auth.access_token, auth.account_id.as_deref()) {
        Ok(response) => response,
        Err(error)
            if target.allow_refresh
                && should_refresh_after_error(&error, &auth)
                && !auth.changed =>
        {
            auth = match refresh_auth(&auth) {
                Ok(refreshed) => refreshed,
                Err(refresh_error) => {
                    return Err(FetchUsageError::new(refresh_error, None));
                }
            };
            source = refresh_source(source);
            match fetch_usage_response(&auth.access_token, auth.account_id.as_deref()) {
                Ok(response) => response,
                Err(retry_error) => {
                    let snapshot = update_snapshot_auth(&target.snapshot, &auth)
                        .map_err(|error| FetchUsageError::new(error, None))?;
                    return Err(FetchUsageError::new(retry_error, Some(snapshot)));
                }
            }
        }
        Err(error) => {
            let snapshot = if auth.changed {
                Some(
                    update_snapshot_auth(&target.snapshot, &auth)
                        .map_err(|update_error| FetchUsageError::new(update_error, None))?,
                )
            } else {
                None
            };
            return Err(FetchUsageError::new(error, snapshot));
        }
    };

    let snapshot = if auth.changed {
        update_snapshot_auth(&target.snapshot, &auth)
            .map_err(|error| FetchUsageError::new(error, None))?
    } else {
        target.snapshot
    };

    let fetched_identity = merge_identity(
        &target.identity,
        response.identity().map_err(|error| {
            FetchUsageError::new(
                error,
                if auth.changed {
                    Some(snapshot.clone())
                } else {
                    None
                },
            )
        })?,
    );
    let usage = response.into_view(source).map_err(|error| {
        FetchUsageError::new(
            error,
            if auth.changed {
                Some(snapshot.clone())
            } else {
                None
            },
        )
    })?;
    Ok((
        UsageOutput {
            environment: target.environment,
            account: fetched_identity,
            usage,
        },
        snapshot,
    ))
}

pub fn usage_error_message(error: &anyhow::Error) -> String {
    let rendered = format!("{error:#}");
    if usage_error_requires_login(&rendered) {
        match usage_error_reason_code(&rendered) {
            "server_session_revoked" => "Login required [server_session_revoked]: OpenAI ended this OAuth session. Log in with this account again, then refresh/save it.".to_owned(),
            "refresh_token_rejected" => "Login required [refresh_token_rejected]: OpenAI rejected the saved refresh token. Log in with this account again, then refresh/save it.".to_owned(),
            "refresh_token_missing" => "Login required [refresh_token_missing]: the saved Codex session has no refresh token. Log in with this account again, then refresh/save it.".to_owned(),
            _ => "Login required [authentication_required]: Codex auth expired or was logged out. Log in with this account again, then refresh/save it.".to_owned(),
        }
    } else if usage_error_requires_local_recovery(&rendered) {
        "Local recovery required [local_snapshot_unreadable]: the saved session could not be decrypted. Restore an automatic backup before signing in again.".to_owned()
    } else if usage_error_reason_code(&rendered) == "access_token_unauthorized" {
        "Usage unavailable [access_token_unauthorized]: OpenAI rejected the current access token, but the saved refresh token was not proven invalid.".to_owned()
    } else {
        let detail = rendered.lines().next().unwrap_or("unknown error");
        format!("Usage unavailable: {detail}")
    }
}

pub fn usage_error_label(error: &str) -> &'static str {
    if usage_error_requires_login(error) {
        "Login required"
    } else if usage_error_requires_local_recovery(error) {
        "Local recovery required"
    } else {
        "Usage unavailable"
    }
}

pub fn usage_error_requires_login(error: &str) -> bool {
    let error = error.to_ascii_lowercase();
    error.contains("login required")
        || error.contains("usage authorization failed")
        || error.contains("snapshot refresh token missing")
        || error.contains("refresh_token_invalidated")
        || error.contains("your session has ended")
        || (error.contains("token refresh failed")
            && (error.contains("invalid_grant")
                || error.contains("refresh token")
                || error.contains("log out")
                || error.contains("sign in")))
}

pub fn usage_error_requires_local_recovery(error: &str) -> bool {
    let error = error.to_ascii_lowercase();
    error.contains("local recovery required")
        || error.contains("decrypt")
        || error.contains("credential key")
        || error.contains("snapshot payload")
}

pub fn usage_error_blocks_activation(error: &str) -> bool {
    usage_error_requires_login(error) || usage_error_requires_local_recovery(error)
}

pub fn usage_error_is_deferred_access_token_refresh(error: &str) -> bool {
    error
        .to_ascii_lowercase()
        .contains("[access_token_unauthorized]")
        || usage_error_reason_code(error) == "access_token_unauthorized"
}

fn usage_error_reason_code(error: &str) -> &'static str {
    let error = error.to_ascii_lowercase();
    if error.contains("refresh_token_invalidated") || error.contains("your session has ended") {
        "server_session_revoked"
    } else if error.contains("invalid_grant")
        || error.contains("refresh token was already used")
        || error.contains("refresh_token_reused")
    {
        "refresh_token_rejected"
    } else if error.contains("snapshot refresh token missing") {
        "refresh_token_missing"
    } else if error.contains("usage authentication failed (401)") {
        "access_token_unauthorized"
    } else {
        "unclassified"
    }
}

#[derive(Clone, Debug)]
struct SnapshotAuth {
    access_token: String,
    refresh_token: Option<String>,
    id_token: Option<String>,
    account_id: Option<String>,
    last_refresh: Option<OffsetDateTime>,
    changed: bool,
}

#[derive(Debug, Deserialize)]
struct UsageResponse {
    email: Option<String>,
    plan_type: Option<String>,
    rate_limit: Option<UsageRateLimit>,
    credits: Option<UsageCredits>,
}

#[derive(Debug, Deserialize)]
struct UsageRateLimit {
    primary_window: Option<UsageWindow>,
    secondary_window: Option<UsageWindow>,
}

#[derive(Debug, Deserialize)]
struct UsageWindow {
    used_percent: u8,
    reset_at: i64,
}

#[derive(Debug, Deserialize)]
struct UsageCredits {
    has_credits: bool,
    unlimited: bool,
    balance: serde_json::Value,
}

#[derive(Debug, Deserialize)]
struct RefreshResponse {
    access_token: String,
    #[serde(default)]
    refresh_token: Option<String>,
    #[serde(default)]
    id_token: Option<String>,
}

impl UsageResponse {
    fn identity(&self) -> Result<Option<DisplayIdentity>> {
        let Some(email) = &self.email else {
            return Ok(None);
        };
        Ok(Some(DisplayIdentity {
            email: email.clone(),
            subject: None,
            name: None,
            plan_label: normalize_plan_label(self.plan_type.as_deref()),
        }))
    }

    fn into_view(self, source: UsageSource) -> Result<AccountUsageView> {
        let now = OffsetDateTime::now_utc();
        let plan_label = normalize_plan_label(self.plan_type.as_deref());
        Ok(AccountUsageView {
            source,
            fetched_at: now,
            five_hour: self
                .rate_limit
                .as_ref()
                .and_then(|limits| limits.primary_window.as_ref())
                .map(window_view)
                .transpose()?,
            weekly: self
                .rate_limit
                .as_ref()
                .and_then(|limits| limits.secondary_window.as_ref())
                .map(window_view)
                .transpose()?,
            credits: self.credits.map(credits_view),
            plan_label,
        })
    }
}

fn snapshot_auth(snapshot: &SnapshotBlob) -> Result<SnapshotAuth> {
    let auth_file = snapshot
        .files
        .iter()
        .find(|file| file.name == "auth.json")
        .context("snapshot missing auth.json")?;
    let auth_json = STANDARD
        .decode(&auth_file.bytes_base64)
        .context("failed to decode snapshot auth.json")?;
    let root: Value =
        serde_json::from_slice(&auth_json).context("failed to parse snapshot auth.json")?;
    let tokens = root
        .get("tokens")
        .and_then(Value::as_object)
        .context("auth.json did not contain tokens")?;
    let access_token = tokens
        .get("access_token")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .context("auth.json did not contain tokens.access_token")?
        .to_owned();
    Ok(SnapshotAuth {
        access_token,
        refresh_token: tokens
            .get("refresh_token")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .map(str::to_owned),
        id_token: tokens
            .get("id_token")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .map(str::to_owned),
        account_id: tokens
            .get("account_id")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .map(str::to_owned),
        last_refresh: parse_last_refresh(root.get("last_refresh").and_then(Value::as_str))?,
        changed: false,
    })
}

/// Patch tokens/last_refresh in place so Codex fields like `auth_mode` survive write-back.
fn update_snapshot_auth(snapshot: &SnapshotBlob, auth: &SnapshotAuth) -> Result<SnapshotBlob> {
    let mut updated = snapshot.clone();
    let auth_index = updated
        .files
        .iter()
        .position(|file| file.name == "auth.json")
        .context("snapshot missing auth.json")?;
    let auth_json = STANDARD
        .decode(&updated.files[auth_index].bytes_base64)
        .context("failed to decode snapshot auth.json")?;
    let mut root: Value =
        serde_json::from_slice(&auth_json).context("failed to parse snapshot auth.json")?;
    let tokens = root
        .as_object_mut()
        .context("auth.json root must be an object")?
        .entry("tokens")
        .or_insert_with(|| Value::Object(Map::new()));
    let tokens = tokens
        .as_object_mut()
        .context("auth.json tokens must be an object")?;
    tokens.insert(
        "access_token".to_owned(),
        Value::String(auth.access_token.clone()),
    );
    if let Some(refresh_token) = &auth.refresh_token {
        tokens.insert(
            "refresh_token".to_owned(),
            Value::String(refresh_token.clone()),
        );
    }
    if let Some(id_token) = &auth.id_token {
        tokens.insert("id_token".to_owned(), Value::String(id_token.clone()));
    }
    if let Some(account_id) = &auth.account_id {
        tokens.insert("account_id".to_owned(), Value::String(account_id.clone()));
    }
    if let Some(last_refresh) = auth.last_refresh {
        root.as_object_mut()
            .context("auth.json root must be an object")?
            .insert(
                "last_refresh".to_owned(),
                Value::String(format_last_refresh(last_refresh)),
            );
    }
    updated.files[auth_index].bytes_base64 = STANDARD
        .encode(serde_json::to_vec_pretty(&root).context("failed to encode refreshed auth.json")?);
    Ok(updated)
}

fn fetch_usage_response(access_token: &str, account_id: Option<&str>) -> Result<UsageResponse> {
    let mut request = ureq::get(USAGE_ENDPOINT)
        .header("Authorization", &format!("Bearer {access_token}"))
        .header("User-Agent", "codex-roster")
        .config()
        .http_status_as_error(false)
        .timeout_global(Some(std::time::Duration::from_secs(5)))
        .build();
    if let Some(account_id) = account_id {
        request = request.header("ChatGPT-Account-Id", account_id);
    }
    let mut response = request.call().context("failed to query Codex usage")?;
    let status = response.status();
    if status == 401 {
        bail!("usage authentication failed (401)");
    }
    if status == 403 {
        let body = response.body_mut().read_to_string().unwrap_or_default();
        bail!("usage access forbidden (403): {body}");
    }
    if status.as_u16() >= 400 {
        let body = response.body_mut().read_to_string().unwrap_or_default();
        bail!("usage request failed with {status}: {body}");
    }
    response
        .body_mut()
        .read_json::<UsageResponse>()
        .context("failed to decode Codex usage response")
}

fn needs_proactive_refresh(auth: &SnapshotAuth) -> bool {
    if auth.refresh_token.as_deref().is_none_or(str::is_empty) {
        return false;
    }
    let now = OffsetDateTime::now_utc();
    if let Some(expires_at) = access_token_expires_at(&auth.access_token) {
        return expires_at <= now + *ACCESS_TOKEN_REFRESH_SKEW;
    }
    match auth.last_refresh {
        Some(last_refresh) => now - last_refresh >= *TOKEN_REFRESH_INTERVAL,
        // Mirror Codex: without JWT exp and without last_refresh, do not force a refresh.
        None => false,
    }
}

fn should_refresh_after_error(error: &anyhow::Error, auth: &SnapshotAuth) -> bool {
    if auth.refresh_token.as_deref().is_none_or(str::is_empty) {
        return false;
    }
    format!("{error:#}").contains("authentication failed (401)")
}

fn is_transient_refresh_error(error: &anyhow::Error) -> bool {
    let rendered = format!("{error:#}").to_ascii_lowercase();
    !usage_error_requires_login(&rendered)
        && (rendered.contains("timed out")
            || rendered.contains("timeout")
            || rendered.contains("connection")
            || rendered.contains("dns")
            || rendered.contains("temporarily")
            || rendered.contains("503")
            || rendered.contains("502")
            || rendered.contains("429"))
}

fn refresh_auth(auth: &SnapshotAuth) -> Result<SnapshotAuth> {
    let _guard = TOKEN_REFRESH_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let refresh_token = auth
        .refresh_token
        .as_deref()
        .filter(|value| !value.is_empty())
        .context("snapshot refresh token missing")?;
    let payload = serde_json::json!({
        "client_id": CHATGPT_CLIENT_ID,
        "grant_type": "refresh_token",
        "refresh_token": refresh_token,
        "scope": "openid profile email"
    });
    let payload_json =
        serde_json::to_string(&payload).context("failed to encode refresh payload")?;
    let mut response = ureq::post(REFRESH_ENDPOINT)
        .header("Content-Type", "application/json")
        .config()
        .http_status_as_error(false)
        .timeout_global(Some(std::time::Duration::from_secs(5)))
        .build()
        .send(&payload_json)
        .context("failed to refresh Codex auth tokens")?;
    let status = response.status();
    if status.as_u16() >= 400 {
        let body = response.body_mut().read_to_string().unwrap_or_default();
        bail!("token refresh failed with {status}: {body}");
    }
    let refreshed = response
        .body_mut()
        .read_json::<RefreshResponse>()
        .context("failed to decode refreshed Codex tokens")?;
    Ok(SnapshotAuth {
        access_token: refreshed.access_token,
        refresh_token: refreshed
            .refresh_token
            .or_else(|| auth.refresh_token.clone()),
        id_token: refreshed.id_token.or_else(|| auth.id_token.clone()),
        account_id: auth.account_id.clone(),
        last_refresh: Some(OffsetDateTime::now_utc()),
        changed: true,
    })
}

fn refresh_source(source: UsageSource) -> UsageSource {
    match source {
        UsageSource::LiveAccessToken | UsageSource::LiveRefreshToken => {
            UsageSource::LiveRefreshToken
        }
        UsageSource::SavedAccessToken | UsageSource::SavedRefreshToken => {
            UsageSource::SavedRefreshToken
        }
    }
}

fn access_token_expires_at(access_token: &str) -> Option<OffsetDateTime> {
    let mut parts = access_token.split('.');
    let _header = parts.next()?;
    let payload = parts.next()?;
    if payload.is_empty() {
        return None;
    }
    let payload_bytes = URL_SAFE_NO_PAD
        .decode(payload)
        .or_else(|_| {
            let padding = "=".repeat((4 - payload.len() % 4) % 4);
            URL_SAFE_NO_PAD.decode(format!("{payload}{padding}"))
        })
        .ok()?;
    let claims: Value = serde_json::from_slice(&payload_bytes).ok()?;
    let exp = claims.get("exp")?.as_i64()?;
    OffsetDateTime::from_unix_timestamp(exp).ok()
}

fn window_view(window: &UsageWindow) -> Result<UsageWindowView> {
    let reset_at = OffsetDateTime::from_unix_timestamp(window.reset_at)
        .map_err(|error| anyhow!("invalid reset timestamp {}: {error}", window.reset_at))?;
    Ok(UsageWindowView {
        used_percent: window.used_percent,
        remaining_percent: 100u8.saturating_sub(window.used_percent),
        reset_at,
    })
}

fn credits_view(credits: UsageCredits) -> CreditsView {
    CreditsView {
        has_credits: credits.has_credits,
        unlimited: credits.unlimited,
        balance: match credits.balance {
            serde_json::Value::String(value) => value,
            other => other.to_string(),
        },
    }
}

fn normalize_plan_label(raw: Option<&str>) -> Option<String> {
    let normalized = raw?.replace(['-', '_'], " ");
    let normalized = normalized.trim().to_ascii_lowercase();
    if normalized.is_empty() {
        return None;
    }
    Some(match normalized.as_str() {
        "go" => "Go".to_owned(),
        "plus" => "Plus".to_owned(),
        "pro" => "Pro".to_owned(),
        "pro lite" => "Pro Lite".to_owned(),
        "free" => "Free".to_owned(),
        other => other
            .split_whitespace()
            .map(|word| {
                let mut chars = word.chars();
                match chars.next() {
                    Some(first) => {
                        let mut result = first.to_uppercase().collect::<String>();
                        result.push_str(chars.as_str());
                        result
                    }
                    None => String::new(),
                }
            })
            .collect::<Vec<_>>()
            .join(" "),
    })
}

fn merge_identity(base: &DisplayIdentity, fetched: Option<DisplayIdentity>) -> DisplayIdentity {
    let Some(fetched) = fetched else {
        return base.clone();
    };
    DisplayIdentity {
        email: fetched.email,
        subject: base.subject.clone(),
        name: base.name.clone(),
        plan_label: fetched.plan_label.or_else(|| base.plan_label.clone()),
    }
}

fn parse_last_refresh(value: Option<&str>) -> Result<Option<OffsetDateTime>> {
    value
        .map(|value| {
            OffsetDateTime::parse(value, &Rfc3339)
                .map_err(|error| anyhow!("failed to parse last_refresh {value:?}: {error}"))
        })
        .transpose()
}

fn format_last_refresh(value: OffsetDateTime) -> String {
    value
        .format(&Rfc3339)
        .unwrap_or_else(|_| value.unix_timestamp().to_string())
}

/// Ensure a saved snapshot carries a usable (non-expired) access token before it
/// is restored into `~/.codex`. When the access token is near expiry and a
/// refresh token is present, rotate the tokens now and hand back the refreshed
/// snapshot so the caller can persist it and restore fresh auth.
///
/// This mirrors how Codex CLI and peer switchers (e.g. codex-router) refresh
/// during a switch: it lets Codex Desktop/CLI start from a valid access token
/// instead of running its own refresh, which can loop on `refresh_token_reused`
/// and force a login.
///
/// Returns `Ok(Some(refreshed))` only when a rotation happened and `Ok(None)`
/// when the snapshot is already fresh or has no refresh token. Any attempted
/// refresh failure aborts activation so neither a dead token nor a stale token
/// after a transient network failure can replace the working live session.
/// Never call this for the account that is currently live in `~/.codex`: Codex
/// owns that refresh token, and rotating it out from under a running session is
/// exactly the desync that forces re-login.
pub fn refresh_snapshot_if_access_token_stale(
    snapshot: &SnapshotBlob,
) -> Result<Option<SnapshotBlob>> {
    refresh_snapshot_if_access_token_stale_with(snapshot, refresh_auth)
}

fn refresh_snapshot_if_access_token_stale_with<F>(
    snapshot: &SnapshotBlob,
    refresh: F,
) -> Result<Option<SnapshotBlob>>
where
    F: FnOnce(&SnapshotAuth) -> Result<SnapshotAuth>,
{
    let auth = snapshot_auth(snapshot)?;
    if !needs_proactive_refresh(&auth) {
        return Ok(None);
    }
    match refresh(&auth) {
        Ok(refreshed) => Ok(Some(update_snapshot_auth(snapshot, &refreshed)?)),
        Err(error) => Err(error).context(
            "selected account could not be refreshed safely; the current session was left unchanged",
        ),
    }
}

pub fn usage_target_from_snapshot(
    environment: EnvironmentKind,
    snapshot: SnapshotBlob,
    source: UsageSource,
    allow_refresh: bool,
) -> Result<UsageTarget> {
    let auth_file = snapshot
        .files
        .iter()
        .find(|file| file.name == "auth.json")
        .context("snapshot missing auth.json")?;
    let auth_json = STANDARD
        .decode(&auth_file.bytes_base64)
        .context("failed to decode snapshot auth.json")?;
    let identity = parse_identity_from_auth_json(&auth_json)?;
    Ok(UsageTarget {
        environment,
        identity,
        snapshot,
        source,
        allow_refresh,
    })
}

#[cfg(test)]
mod tests {
    use anyhow::anyhow;
    use base64::engine::general_purpose::STANDARD;
    use serde_json::json;

    use super::*;
    use crate::model::{SNAPSHOT_SCHEMA_VERSION, SnapshotFile};

    fn jwt_with_exp(exp: i64) -> String {
        let header = URL_SAFE_NO_PAD.encode(r#"{"alg":"none"}"#);
        let payload = URL_SAFE_NO_PAD.encode(format!(r#"{{"exp":{exp}}}"#));
        format!("{header}.{payload}.")
    }

    fn auth_snapshot(auth: Value) -> SnapshotBlob {
        SnapshotBlob {
            schema_version: SNAPSHOT_SCHEMA_VERSION,
            files: vec![SnapshotFile {
                name: "auth.json".to_owned(),
                bytes_base64: STANDARD.encode(auth.to_string()),
            }],
        }
    }

    #[test]
    fn reused_refresh_token_error_is_login_required() {
        let error = anyhow!(
            "token refresh failed with 400 Bad Request: {{\"error\":\"invalid_grant\",\"error_description\":\"Your access token could not be refreshed because your refresh token was already used. Please log out and sign in again.\"}}"
        );
        let message = usage_error_message(&error);

        assert_eq!(usage_error_label(&message), "Login required");
        assert!(message.contains("Log in with this account again"));
        assert!(usage_error_blocks_activation(&message));
    }

    #[test]
    fn invalidated_refresh_token_is_login_required() {
        let error = anyhow!(
            "{}",
            r#"token refresh failed with 401 Unauthorized: {"error":{"message":"Your session has ended. Please log in again.","code":"refresh_token_invalidated"}}"#
        );

        assert!(usage_error_requires_login(&format!("{error:#}")));
        assert_eq!(
            usage_error_label(&usage_error_message(&error)),
            "Login required"
        );
    }

    #[test]
    fn plain_usage_401_does_not_claim_the_saved_session_was_revoked() {
        let error = anyhow!("usage authentication failed (401)");
        let message = usage_error_message(&error);

        assert!(!usage_error_requires_login(&format!("{error:#}")));
        assert_eq!(usage_error_label(&message), "Usage unavailable");
        assert!(message.contains("[access_token_unauthorized]"));
        assert!(!usage_error_blocks_activation(&message));
        assert!(usage_error_is_deferred_access_token_refresh(&message));
    }

    #[test]
    fn undecryptable_snapshot_requires_local_recovery_not_login() {
        let error = anyhow!(
            "failed to decrypt snapshot /x/y.snapshot: could not decrypt local snapshot: Decryption failed"
        );

        assert!(!usage_error_requires_login(&format!("{error:#}")));
        assert!(usage_error_requires_local_recovery(&format!("{error:#}")));
        assert!(usage_error_blocks_activation(&format!("{error:#}")));
        assert_eq!(
            usage_error_label(&usage_error_message(&error)),
            "Local recovery required"
        );
    }

    #[test]
    fn non_auth_usage_error_stays_usage_unavailable() {
        let message = usage_error_message(&anyhow!("failed to query Codex usage"));

        assert_eq!(usage_error_label(&message), "Usage unavailable");
        assert_eq!(message, "Usage unavailable: failed to query Codex usage");
        assert!(!usage_error_blocks_activation(&message));
    }

    #[test]
    fn forbidden_usage_does_not_require_login_or_refresh() {
        let error = anyhow!("usage access forbidden (403): account is not eligible");
        let auth = SnapshotAuth {
            access_token: "access".to_owned(),
            refresh_token: Some("refresh".to_owned()),
            id_token: None,
            account_id: None,
            last_refresh: None,
            changed: false,
        };

        assert!(!usage_error_requires_login(&format!("{error:#}")));
        assert!(!should_refresh_after_error(&error, &auth));
        assert_eq!(
            usage_error_label(&usage_error_message(&error)),
            "Usage unavailable"
        );
    }

    #[test]
    fn refresh_write_back_preserves_auth_mode_and_extra_fields() {
        let snapshot = auth_snapshot(json!({
            "auth_mode": "chatgpt",
            "tokens": {
                "id_token": "id",
                "access_token": "old-access",
                "refresh_token": "old-refresh",
                "account_id": "acct"
            },
            "last_refresh": "2026-01-01T00:00:00Z",
            "custom_extension": {"keep": true}
        }));
        let updated = update_snapshot_auth(
            &snapshot,
            &SnapshotAuth {
                access_token: "new-access".to_owned(),
                refresh_token: Some("new-refresh".to_owned()),
                id_token: Some("new-id".to_owned()),
                account_id: Some("acct".to_owned()),
                last_refresh: Some(OffsetDateTime::UNIX_EPOCH),
                changed: true,
            },
        )
        .expect("update");
        let auth_json = STANDARD
            .decode(
                &updated
                    .files
                    .iter()
                    .find(|file| file.name == "auth.json")
                    .expect("auth")
                    .bytes_base64,
            )
            .expect("decode");
        let root: Value = serde_json::from_slice(&auth_json).expect("json");
        assert_eq!(root["auth_mode"], "chatgpt");
        assert_eq!(root["custom_extension"]["keep"], true);
        assert_eq!(root["tokens"]["access_token"], "new-access");
        assert_eq!(root["tokens"]["refresh_token"], "new-refresh");
        assert_eq!(root["tokens"]["id_token"], "new-id");
    }

    #[test]
    fn proactive_refresh_uses_access_token_near_expiry_window() {
        let soon = OffsetDateTime::now_utc() + Duration::minutes(2);
        let auth = SnapshotAuth {
            access_token: jwt_with_exp(soon.unix_timestamp()),
            refresh_token: Some("refresh".to_owned()),
            id_token: None,
            account_id: None,
            last_refresh: Some(OffsetDateTime::now_utc()),
            changed: false,
        };
        assert!(needs_proactive_refresh(&auth));
    }

    #[test]
    fn proactive_refresh_uses_eight_day_stale_last_refresh() {
        let auth = SnapshotAuth {
            access_token: "not-a-jwt".to_owned(),
            refresh_token: Some("refresh".to_owned()),
            id_token: None,
            account_id: None,
            last_refresh: Some(OffsetDateTime::now_utc() - Duration::days(9)),
            changed: false,
        };
        assert!(needs_proactive_refresh(&auth));
    }

    #[test]
    fn refresh_on_restore_skips_snapshot_with_valid_access_token() {
        let far = OffsetDateTime::now_utc() + Duration::days(1);
        let snapshot = auth_snapshot(json!({
            "tokens": {
                "access_token": jwt_with_exp(far.unix_timestamp()),
                "refresh_token": "refresh",
                "account_id": "acct"
            }
        }));

        assert!(
            refresh_snapshot_if_access_token_stale(&snapshot)
                .expect("refresh check")
                .is_none()
        );
    }

    #[test]
    fn refresh_on_restore_skips_snapshot_without_refresh_token() {
        let soon = OffsetDateTime::now_utc() + Duration::minutes(1);
        let snapshot = auth_snapshot(json!({
            "tokens": {
                "access_token": jwt_with_exp(soon.unix_timestamp())
            }
        }));

        assert!(
            refresh_snapshot_if_access_token_stale(&snapshot)
                .expect("refresh check")
                .is_none()
        );
    }

    #[test]
    fn refresh_on_restore_aborts_on_invalid_refresh_token() {
        let soon = OffsetDateTime::now_utc() + Duration::minutes(1);
        let snapshot = auth_snapshot(json!({
            "tokens": {
                "access_token": jwt_with_exp(soon.unix_timestamp()),
                "refresh_token": "already-consumed"
            }
        }));

        let error = refresh_snapshot_if_access_token_stale_with(&snapshot, |_| {
            Err(anyhow!(
                "token refresh failed: invalid_grant refresh token was already used"
            ))
        })
        .expect_err("hard auth failure must abort activation");

        assert!(format!("{error:#}").contains("current session was left unchanged"));
    }

    #[test]
    fn refresh_on_restore_aborts_on_transient_network_error() {
        let soon = OffsetDateTime::now_utc() + Duration::minutes(1);
        let snapshot = auth_snapshot(json!({
            "tokens": {
                "access_token": jwt_with_exp(soon.unix_timestamp()),
                "refresh_token": "refresh"
            }
        }));

        let error = refresh_snapshot_if_access_token_stale_with(&snapshot, |_| {
            Err(anyhow!("connection timed out while refreshing tokens"))
        })
        .expect_err("a stale token must never be restored after refresh failure");

        assert!(format!("{error:#}").contains("current session was left unchanged"));
    }

    #[test]
    fn fresh_session_without_jwt_exp_skips_proactive_refresh() {
        let auth = SnapshotAuth {
            access_token: "not-a-jwt".to_owned(),
            refresh_token: Some("refresh".to_owned()),
            id_token: None,
            account_id: None,
            last_refresh: Some(OffsetDateTime::now_utc() - Duration::days(1)),
            changed: false,
        };
        assert!(!needs_proactive_refresh(&auth));
    }
}
