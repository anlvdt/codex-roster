//! Read Claude Code's documented statusLine payload without network requests.
//! Only quota metadata is persisted. A session keeps its first account binding
//! so an old process cannot overwrite the newly selected account's quota.
use crate::model::{
    AiProvider, DisplayIdentity, ProviderUsageStatus, ProviderUsageView, UsageFidelity,
};
use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    fs,
    io::{Read, Write},
    path::{Path, PathBuf},
    process::{Command, Stdio},
};
use time::OffsetDateTime;
use uuid::Uuid;

#[derive(Serialize, Deserialize)]
struct Observation {
    email: String,
    subject: String,
    observed_at: i64,
    rate_limits: Value,
}

pub fn config_dir(home: &Path) -> PathBuf {
    std::env::var_os("CLAUDE_CONFIG_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| home.join(".claude"))
}

/// The documented local payload omits model-specific caps. Do not replace
/// known caps with an aggregate-only observation and make a depleted model
/// appear eligible for automatic switching.
pub fn covers_known_limits(previous: Option<&ProviderUsageView>) -> bool {
    previous.is_none_or(|usage| {
        !usage
            .windows
            .iter()
            .any(|window| window.key.starts_with("seven_day_"))
    })
}

pub fn remember_api_cooldown(dir: &Path, account_id: Uuid, until: OffsetDateTime) -> Result<()> {
    private_write(
        &dir.join("roster-usage")
            .join(format!("cooldown-{account_id}")),
        (until.unix_timestamp() + i64::from(until.nanosecond() > 0))
            .to_string()
            .as_bytes(),
    )
}

pub fn api_cooldown(dir: &Path, account_id: Uuid, now: OffsetDateTime) -> Option<time::Duration> {
    let text = fs::read_to_string(
        dir.join("roster-usage")
            .join(format!("cooldown-{account_id}")),
    )
    .ok()?;
    let until = OffsetDateTime::from_unix_timestamp(text.trim().parse().ok()?).ok()?;
    let wait = until - now;
    (wait > time::Duration::ZERO).then_some(wait.min(time::Duration::days(1)))
}

fn private_write(path: &Path, bytes: &[u8]) -> Result<()> {
    let parent = path.parent().context("missing parent")?;
    fs::create_dir_all(parent)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(parent, fs::Permissions::from_mode(0o700))?;
    }
    let tmp = parent.join(format!(".{}.tmp", Uuid::new_v4()));
    let mut options = fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(&tmp)?;
    file.write_all(bytes)?;
    file.sync_all()?;
    fs::rename(&tmp, path)?;
    Ok(())
}

fn identity(dir: &Path) -> Option<(String, String)> {
    // Default CLI uses ~/.claude.json; an explicit CLAUDE_CONFIG_DIR uses
    // <dir>/.claude.json. Match the adapter instead of preferring a stale
    // scoped login left in ~/.claude/.claude.json.
    let scoped =
        std::env::var_os("CLAUDE_CONFIG_DIR").is_some_and(|value| Path::new(&value) == dir);
    let paths = identity_paths(dir, scoped)?;
    paths.iter().find_map(|path| {
        let value: Value = serde_json::from_slice(&fs::read(path).ok()?).ok()?;
        let account = value.get("oauthAccount")?;
        Some((
            account.get("emailAddress")?.as_str()?.to_owned(),
            account.get("accountUuid")?.as_str()?.to_owned(),
        ))
    })
}

fn identity_paths(dir: &Path, scoped: bool) -> Option<[PathBuf; 2]> {
    let default = dir.parent()?.join(".claude.json");
    let local = dir.join(".claude.json");
    Some(if scoped {
        [local, default]
    } else {
        [default, local]
    })
}

fn windows(limits: &Value, now: OffsetDateTime) -> Vec<crate::model::ProviderUsageWindowView> {
    [("five_hour", "5 hour"), ("seven_day", "7 day")]
        .into_iter()
        .filter_map(|(key, label)| {
            let value = limits.get(key)?;
            let used = value.get("used_percentage")?.as_f64()?;
            let reset =
                OffsetDateTime::from_unix_timestamp(value.get("resets_at")?.as_i64()?).ok()?;
            if !used.is_finite() || !(0.0..=100.0).contains(&used) || reset <= now {
                return None;
            }
            // Round consumption up so 99.9% never appears to have usable headroom.
            Some(crate::provider::percent_window(
                key,
                label,
                used.ceil(),
                Some(reset),
            ))
        })
        .collect()
}

pub fn capture(dir: &Path, payload: &Value, now: OffsetDateTime) -> Result<()> {
    let session = Uuid::parse_str(
        payload
            .get("session_id")
            .and_then(Value::as_str)
            .context("no session ID")?,
    )?;
    let path = dir.join("roster-usage").join(format!("{session}.json"));
    let previous: Option<Observation> = fs::read(&path)
        .ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok());
    let (email, subject) = previous
        .map(|old| (old.email, old.subject))
        .or_else(|| identity(dir))
        .context("no account identity")?;
    // Do not refresh timestamps when an idle statusline is re-rendered. Values
    // only become fresh on a changed quota payload (or the first observation).
    let limits = payload.get("rate_limits").cloned().unwrap_or(Value::Null);
    let limits =
        json!({"five_hour": limits.get("five_hour"), "seven_day": limits.get("seven_day")});
    if let Ok(bytes) = fs::read(&path)
        && let Ok(old) = serde_json::from_slice::<Observation>(&bytes)
        && old.rate_limits == limits
    {
        return Ok(());
    }
    let observation = Observation {
        email,
        subject,
        observed_at: now.unix_timestamp(),
        rate_limits: limits,
    };
    private_write(&path, &serde_json::to_vec(&observation)?)
}

pub fn read_usage(
    dir: &Path,
    account: &DisplayIdentity,
    now: OffsetDateTime,
) -> Option<ProviderUsageView> {
    let mut newest: Option<ProviderUsageView> = None;
    for entry in fs::read_dir(dir.join("roster-usage"))
        .ok()?
        .flatten()
        .take(1000)
    {
        if entry.path().extension().and_then(|x| x.to_str()) != Some("json") {
            continue;
        }
        let Ok(bytes) = fs::read(entry.path()) else {
            continue;
        };
        let Ok(observation) = serde_json::from_slice::<Observation>(&bytes) else {
            continue;
        };
        if !observation.email.eq_ignore_ascii_case(&account.email)
            || account.subject.as_deref() != Some(observation.subject.as_str())
        {
            continue;
        }
        let Ok(fetched_at) = OffsetDateTime::from_unix_timestamp(observation.observed_at) else {
            continue;
        };
        if fetched_at > now + time::Duration::seconds(30)
            || now - fetched_at > time::Duration::minutes(2)
        {
            continue;
        }
        let windows = windows(&observation.rate_limits, now);
        // Require both aggregate limits for account switching; partial/expired
        // payloads must never hide an exhausted weekly or session window.
        if windows.len() != 2 {
            continue;
        }
        if newest
            .as_ref()
            .is_some_and(|old| old.fetched_at >= fetched_at)
        {
            continue;
        }
        newest = Some(ProviderUsageView {
            provider: AiProvider::Claude,
            fetched_at,
            status: ProviderUsageStatus::Ok,
            fidelity: UsageFidelity::Official,
            headline_window: Some("five_hour".into()),
            windows,
            plan_label: None,
            detail: Some("Claude Code statusline · local observation".into()),
        });
    }
    newest
}

fn quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

pub fn install(dir: &Path, executable: &Path) -> Result<()> {
    let path = dir.join("settings.json");
    let original = if path.exists() {
        fs::read(&path)?
    } else {
        b"{}".to_vec()
    };
    let mut settings: Value =
        serde_json::from_slice(&original).context("Claude settings are not valid JSON")?;
    if !settings.is_object() {
        bail!("Claude settings must be an object");
    }
    let previous = settings
        .pointer("/statusLine/command")
        .and_then(Value::as_str)
        .unwrap_or("");
    if previous.contains("claude-quota-bridge") {
        return Ok(());
    }
    let mut command = format!(
        "{} --config-dir {}",
        quote(&executable.to_string_lossy()),
        quote(&dir.to_string_lossy())
    );
    if !previous.is_empty() {
        command.push_str(&format!(" --forward {}", quote(previous)));
    }
    let mut status = settings.get("statusLine").cloned().unwrap_or(json!({}));
    if !status.is_object() {
        bail!("Unsupported statusLine configuration");
    }
    status["type"] = json!("command");
    status["command"] = json!(command);
    settings["statusLine"] = status;
    private_write(
        &dir.join(format!("settings.roster-backup-{}.json", Uuid::new_v4())),
        &original,
    )?;
    private_write(&path, &serde_json::to_vec_pretty(&settings)?)
}

pub fn run() -> Result<()> {
    use clap::Parser;
    #[derive(Parser)]
    struct Args {
        #[arg(long)]
        install: bool,
        #[arg(long)]
        config_dir: Option<PathBuf>,
        #[arg(long)]
        forward: Option<String>,
    }
    let args = Args::parse();
    let home = directories::BaseDirs::new()
        .context("home unavailable")?
        .home_dir()
        .to_owned();
    let dir = args.config_dir.unwrap_or_else(|| config_dir(&home));
    if args.install {
        install(&dir, &std::env::current_exe()?)?;
        println!(
            "Claude Code quota bridge installed. Existing statusline preserved; restart CLI or resume in a fresh process."
        );
        return Ok(());
    }
    let mut bytes = Vec::new();
    std::io::stdin().take(2_000_001).read_to_end(&mut bytes)?;
    if bytes.len() > 2_000_000 {
        bail!("statusline payload too large");
    }
    if let Ok(payload) = serde_json::from_slice::<Value>(&bytes) {
        let now = OffsetDateTime::now_utc();
        let _ = capture(&dir, &payload, now);
        if args.forward.is_none() {
            let labels: Vec<String> =
                windows(payload.get("rate_limits").unwrap_or(&Value::Null), now)
                    .iter()
                    .map(|w| format!("{}: {}% left", w.label, w.remaining_percent.unwrap_or(0)))
                    .collect();
            println!(
                "{}",
                if labels.is_empty() {
                    "Claude Code · quota unavailable".into()
                } else {
                    labels.join(" | ")
                }
            );
        }
    }
    if let Some(command) = args.forward {
        let mut child = Command::new("/bin/sh")
            .args(["-c", &command])
            .stdin(Stdio::piped())
            .stdout(Stdio::inherit())
            .stderr(Stdio::null())
            .spawn()?;
        if let Some(mut input) = child.stdin.take() {
            let _ = input.write_all(&bytes);
        }
        let _ = child.wait()?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn default_and_scoped_identity_paths_follow_cli_precedence() {
        let dir = Path::new("/home/test/.claude");
        assert_eq!(
            identity_paths(dir, false).unwrap()[0],
            Path::new("/home/test/.claude.json")
        );
        assert_eq!(
            identity_paths(dir, true).unwrap()[0],
            dir.join(".claude.json")
        );
    }
    #[test]
    fn aggregate_only_feed_cannot_erase_known_model_caps() {
        let root = setup();
        let now = OffsetDateTime::now_utc();
        capture(root.path(), &payload(Uuid::new_v4(), now), now).unwrap();
        let mut usage = read_usage(root.path(), &account(), now).unwrap();
        assert!(covers_known_limits(Some(&usage)));
        usage.windows.push(crate::provider::percent_window(
            "seven_day_opus",
            "Opus",
            100.0,
            None,
        ));
        assert!(!covers_known_limits(Some(&usage)));
    }
    #[test]
    fn local_updates_do_not_clear_persisted_api_retry_after() {
        let root = setup();
        let now = OffsetDateTime::from_unix_timestamp(1_800_000_000).unwrap();
        let account_id = Uuid::new_v4();
        remember_api_cooldown(root.path(), account_id, now + time::Duration::seconds(300)).unwrap();
        capture(root.path(), &payload(Uuid::new_v4(), now), now).unwrap();
        assert_eq!(
            api_cooldown(root.path(), account_id, now + time::Duration::seconds(120)),
            Some(time::Duration::seconds(180))
        );
        assert!(
            api_cooldown(root.path(), account_id, now + time::Duration::seconds(300)).is_none()
        );
    }
    fn payload(id: Uuid, now: OffsetDateTime) -> Value {
        json!({"session_id":id,"rate_limits":{
        "five_hour":{"used_percentage":99.9,"resets_at":(now + time::Duration::hours(1)).unix_timestamp()},
        "seven_day":{"used_percentage":25.0,"resets_at":(now + time::Duration::days(1)).unix_timestamp()}}})
    }
    fn account() -> DisplayIdentity {
        DisplayIdentity {
            email: "a@example.com".into(),
            subject: Some("account-a".into()),
            name: None,
            plan_label: None,
        }
    }
    fn setup() -> tempfile::TempDir {
        let root = tempfile::tempdir().unwrap();
        fs::write(
            root.path().join(".claude.json"),
            br#"{"oauthAccount":{"emailAddress":"a@example.com","accountUuid":"account-a"}}"#,
        )
        .unwrap();
        root
    }
    #[test]
    fn local_quota_converts_used_to_remaining_and_rejects_stale_or_wrong_account() {
        let root = setup();
        let now = OffsetDateTime::now_utc();
        capture(root.path(), &payload(Uuid::new_v4(), now), now).unwrap();
        let usage = read_usage(root.path(), &account(), now).unwrap();
        assert_eq!(usage.windows[0].remaining_percent, Some(0));
        assert_eq!(usage.windows[1].remaining_percent, Some(75));
        assert!(read_usage(root.path(), &account(), now + time::Duration::minutes(3)).is_none());
        let mut wrong = account();
        wrong.subject = Some("account-b".into());
        assert!(read_usage(root.path(), &wrong, now).is_none());
    }
    #[test]
    fn old_session_never_rebinds_after_account_switch() {
        let root = setup();
        let now = OffsetDateTime::now_utc();
        let id = Uuid::new_v4();
        capture(root.path(), &payload(id, now), now).unwrap();
        fs::write(
            root.path().join(".claude.json"),
            br#"{"oauthAccount":{"emailAddress":"b@example.com","accountUuid":"account-b"}}"#,
        )
        .unwrap();
        let mut updated = payload(id, now);
        updated["rate_limits"]["seven_day"]["used_percentage"] = json!(26);
        capture(root.path(), &updated, now).unwrap();
        let mut b = account();
        b.email = "b@example.com".into();
        b.subject = Some("account-b".into());
        assert!(read_usage(root.path(), &b, now).is_none());
    }
    #[test]
    fn idle_render_does_not_refresh_old_quota() {
        let root = setup();
        let now = OffsetDateTime::now_utc();
        let input = payload(Uuid::new_v4(), now);
        capture(root.path(), &input, now).unwrap();
        capture(root.path(), &input, now + time::Duration::minutes(3)).unwrap();
        assert!(read_usage(root.path(), &account(), now + time::Duration::minutes(3)).is_none());
    }
    #[test]
    fn partial_expired_and_invalid_windows_are_not_switch_evidence() {
        for value in [json!(null), json!(-1), json!(101)] {
            let root = setup();
            let now = OffsetDateTime::now_utc();
            let mut input = payload(Uuid::new_v4(), now);
            input["rate_limits"]["five_hour"]["used_percentage"] = value;
            capture(root.path(), &input, now).unwrap();
            assert!(read_usage(root.path(), &account(), now).is_none());
        }
        let root = setup();
        let now = OffsetDateTime::now_utc();
        let mut input = payload(Uuid::new_v4(), now);
        input["rate_limits"]["seven_day"]["resets_at"] = json!(now.unix_timestamp());
        capture(root.path(), &input, now).unwrap();
        assert!(read_usage(root.path(), &account(), now).is_none());
    }
    #[test]
    fn install_preserves_existing_command_settings_and_is_idempotent() {
        let root = setup();
        let path = root.path().join("settings.json");
        fs::write(&path,br#"{"permissions":{"defaultMode":"default"},"statusLine":{"type":"command","command":"printf 'my status'","padding":2}}"#).unwrap();
        let exe = Path::new("/App space/claude-quota-bridge");
        install(root.path(), exe).unwrap();
        let first = fs::read(&path).unwrap();
        install(root.path(), exe).unwrap();
        assert_eq!(first, fs::read(path).unwrap());
        let settings: Value = serde_json::from_slice(&first).unwrap();
        assert_eq!(settings["statusLine"]["padding"], 2);
        assert_eq!(settings["permissions"]["defaultMode"], "default");
        assert!(
            settings["statusLine"]["command"]
                .as_str()
                .unwrap()
                .contains("--forward")
        );
    }
}
