use std::io::{IsTerminal, Read};
use std::path::PathBuf;
use std::process::Command as ProcessCommand;

use anyhow::{Context, Result, bail};
use clap::{Parser, Subcommand};
use time::OffsetDateTime;
use uuid::Uuid;

use crate::app::{App, InteractiveExit, InteractiveMode};
use crate::env;
use crate::model::{
    AccountUsageView, AccountView, AutoStartUsageWindowsRunOutput,
    AutoStartUsageWindowsStatusOutput, RunningCodexProcess, TokenUsageSummaryOutput, UsageOutput,
};
#[cfg(feature = "external-providers")]
use crate::model::{
    AiProvider, ClaudeAutoSwitchStrategy, ProviderAccountView, ProviderStatusOutput,
    ProviderUsageOutput, ProviderUsageStatus, ProviderUsageView,
};
use crate::openai_status::fetch_openai_status;
use crate::process::format_process_table;
use crate::repository::SnapshotRepository;
use crate::secrets::MigratingSecretStore;
use crate::usage::{usage_error_label, usage_error_requires_login};

#[derive(Parser)]
#[command(
    name = crate::CLI_NAME,
    author,
    version,
    about = "Manage Codex accounts across the CLI and IDE",
    after_help = "EXAMPLES:\n  codex-roster list --json\n  codex-roster activate <ACCOUNT_ID>\n  codex-roster tui\n\nAll commands accept --json for machine-readable output; the macOS app consumes it."
)]
struct Cli {
    #[command(subcommand)]
    command: Option<Command>,
}

#[derive(Subcommand)]
enum Command {
    /// Show environment, the live account, saved-account count and process warnings.
    Status {
        #[arg(long, help = "Print machine-readable JSON")]
        json: bool,
    },
    /// List saved accounts with cached quota (archived rows hidden unless --all).
    List {
        #[arg(long, help = "Print machine-readable JSON")]
        json: bool,
        #[arg(long, help = "Include archived accounts")]
        all: bool,
    },
    #[cfg(feature = "external-providers")]
    /// Inspect and manage external provider accounts.
    Providers {
        #[command(subcommand)]
        command: Option<ProviderCommand>,
    },
    /// Save the current live Codex session as a roster account.
    Save {
        #[arg(long, help = "Print machine-readable JSON")]
        json: bool,
    },
    /// Start an isolated login for a new account without touching the live session.
    BeginAddAccount {
        #[arg(long, help = "Print machine-readable JSON")]
        json: bool,
    },
    /// Import the account created by `begin-add-account` into the roster.
    SaveAddedAccount {
        #[arg(long, help = "Print machine-readable JSON")]
        json: bool,
    },
    /// Discard a pending add-account login and its temporary CODEX_HOME.
    CancelAddAccount {
        #[arg(long, help = "Print machine-readable JSON")]
        json: bool,
    },
    /// Report whether the pending add-account login produced credentials.
    AddAccountStatus {
        #[arg(long, help = "Print machine-readable JSON")]
        json: bool,
    },
    /// Show quota for one account, or for the active account when no id is given.
    Usage {
        account_id: Option<Uuid>,
        #[arg(long, help = "Print machine-readable JSON")]
        json: bool,
    },
    /// Re-query the active account plus any stale saved accounts (staleness-aware).
    RefreshUsage {
        #[arg(long, help = "Print machine-readable JSON")]
        json: bool,
    },
    /// Switch the live Codex session to a saved account.
    Activate {
        account_id: Option<Uuid>,
        #[arg(long, help = "Print machine-readable JSON")]
        json: bool,
        #[arg(
            long,
            help = "Ignore ChatGPT/Codex Desktop leftovers (never a live Codex CLI session)"
        )]
        force: bool,
    },
    /// Enable Luna Reserve (gpt-5.6-luna) for the active account or a specific account.
    EnableLunaReserve {
        account_id: Option<Uuid>,
        #[arg(long, help = "Print machine-readable JSON")]
        json: bool,
    },
    /// Delete a saved account and its encrypted snapshot.
    Delete {
        account_id: Option<Uuid>,
        #[arg(long, help = "Print machine-readable JSON")]
        json: bool,
    },
    /// Hide an account from the roster, or restore it with --restore.
    Archive {
        account_id: Uuid,
        #[arg(long, help = "Restore the account instead of archiving it")]
        restore: bool,
        #[arg(long, help = "Print machine-readable JSON")]
        json: bool,
    },
    /// Write an encrypted backup bundle to OUTPUT.
    Export {
        output: PathBuf,
        #[arg(long, help = "Read the backup password from stdin (max 4 KiB)")]
        password_stdin: bool,
        #[arg(long, help = "Print machine-readable JSON")]
        json: bool,
    },
    /// Restore accounts from an encrypted backup bundle.
    Import {
        input: PathBuf,
        #[arg(long, help = "Read the backup password from stdin (max 4 KiB)")]
        password_stdin: bool,
        #[arg(long, help = "Print machine-readable JSON")]
        json: bool,
    },
    /// Import account(s) from Codex auth.json, a Roster snapshot JSON, or a plaintext backup bundle.
    ImportJson {
        input: PathBuf,
        /// Optional display label (single-account auth.json / snapshot only).
        #[arg(long)]
        label: Option<String>,
        #[arg(long, help = "Print machine-readable JSON")]
        json: bool,
    },
    /// Restore roster metadata from the newest automatic account-list backup.
    RestoreAccountListBackup {
        #[arg(long, help = "Print machine-readable JSON")]
        json: bool,
    },
    /// Restore the full encrypted backup over the current roster.
    RestoreFullBackup {
        #[arg(long, help = "Print machine-readable JSON")]
        json: bool,
    },
    /// Write an automatic full backup now instead of waiting for the next schedule.
    CreateAutomaticFullBackup {
        #[arg(long, help = "Print machine-readable JSON")]
        json: bool,
    },
    /// Keep Codex usage windows fresh in the background.
    AutoStartUsageWindows {
        #[arg(long, conflicts_with = "disable")]
        enable: bool,
        #[arg(long)]
        disable: bool,
        #[arg(long)]
        run: bool,
        #[arg(long, help = "Print machine-readable JSON")]
        json: bool,
    },
    /// Remember Codex rollout cwd/session on switch; reopen thread after activate.
    AutoResumeSession {
        #[arg(long, conflicts_with_all = ["disable", "continue_interrupted"])]
        enable: bool,
        #[arg(long, conflicts_with_all = ["enable", "continue_interrupted"])]
        disable: bool,
        /// Discover interrupted / quota-blocked threads (same-account recovery).
        #[arg(long, conflicts_with_all = ["enable", "disable"])]
        continue_interrupted: bool,
        #[arg(long, help = "Print machine-readable JSON")]
        json: bool,
    },
    /// Inspect or change automatic switching when quota is exhausted.
    AutoSwitch {
        #[arg(long, conflicts_with_all = ["disable", "apply", "status"])]
        enable: bool,
        #[arg(long, conflicts_with_all = ["enable", "apply", "status"])]
        disable: bool,
        #[arg(long, conflicts_with = "status")]
        apply: bool,
        /// Optional candidate chosen by a prior `auto-switch` decision (skips re-fan-out).
        #[arg(long, requires = "apply")]
        account_id: Option<Uuid>,
        /// Apply even when Codex/ChatGPT processes are still detected (caller must close them).
        #[arg(long, requires = "apply")]
        force: bool,
        #[arg(long)]
        status: bool,
        #[arg(long, help = "Print machine-readable JSON")]
        json: bool,
    },
    /// Recover accounts from legacy snapshot formats.
    RecoverLegacySnapshots {
        #[arg(long, help = "Print machine-readable JSON")]
        json: bool,
    },
    /// Summarise local Codex token usage and estimated cost.
    TokenUsage {
        #[arg(long, help = "Print machine-readable JSON")]
        json: bool,
    },
    /// Official rate-limit remaining % samples for the last ~7 days.
    QuotaHistory {
        account_id: Option<Uuid>,
        #[arg(long, help = "Print machine-readable JSON")]
        json: bool,
    },
    /// Run the optional VibeCafe usage collector for Codex and other AI tools.
    VibeUsage {
        #[command(subcommand)]
        command: Option<VibeUsageCommand>,
    },
    /// Global Codex Reset outlook (codex-resets.com status).
    ResetOutlook {
        #[arg(long, help = "Print machine-readable JSON")]
        json: bool,
    },
    /// Return newly published Codex reset events once, for desktop notifications
    /// (codex-resets.com status/list + forecast official_signal).
    ResetEvents {
        #[arg(long, help = "Print machine-readable JSON")]
        json: bool,
    },
    /// Return recent reset announcements from codex-resets.com.
    ResetTimeline {
        #[arg(long, help = "Print machine-readable JSON")]
        json: bool,
    },
    /// Deprecated: Codex Resets does not publish service status history.
    #[command(hide = true)]
    ResetStatusHistory {
        #[arg(long, help = "Print machine-readable JSON")]
        json: bool,
    },
    /// Deprecated: Codex Resets does not publish effort tiers.
    #[command(hide = true)]
    ResetJuice {
        #[arg(long, help = "Print machine-readable JSON")]
        json: bool,
    },
    /// Show the public OpenAI Status summary.
    OpenAiStatus {
        #[arg(long, help = "Print machine-readable JSON")]
        json: bool,
    },
    /// Estimate when each quota window runs out, from recorded samples.
    QuotaForecast {
        account_id: Option<Uuid>,
        #[arg(long, help = "Print machine-readable JSON")]
        json: bool,
    },
    /// Report local diagnostics (paths, keys, locks, ports) for support.
    Doctor {
        #[arg(long, help = "Print machine-readable JSON")]
        json: bool,
        #[arg(long, help = "Write a redacted report to doctor-report.txt")]
        bundle: bool,
    },
    /// Describe the `--json` contract, optionally for one command.
    Schema {
        command: Option<String>,
        #[arg(long, help = "Print machine-readable JSON")]
        json: bool,
    },
    /// Set or clear the custom label of a saved account.
    SetLabel {
        account_id: Uuid,
        label: String,
        #[arg(long, help = "Print machine-readable JSON")]
        json: bool,
    },
}

#[derive(Subcommand)]
enum VibeUsageCommand {
    /// Authenticate and configure the VibeCafe collector.
    Init,
    /// Upload newly discovered local usage.
    Sync,
    /// Print an aggregated usage report.
    Summary {
        #[arg(long, default_value_t = 7)]
        days: u16,
    },
    /// Show collector configuration and detected tools.
    Status,
}

#[cfg(feature = "external-providers")]
#[derive(Subcommand)]
enum ProviderCommand {
    /// Synchronize an already signed-in Claude CLI account verified by the caller.
    SyncClaude {
        #[arg(long)]
        email: String,
        #[arg(long, help = "Print machine-readable JSON")]
        json: bool,
    },
    /// Save or restore a matching Claude Desktop login while Desktop is closed.
    ClaudeDesktop {
        account_id: Uuid,
        #[arg(long, conflicts_with = "restore")]
        save: bool,
        #[arg(long, help = "Restore the account instead of archiving it")]
        restore: bool,
        #[arg(long, help = "Print machine-readable JSON")]
        json: bool,
    },
    /// Show live availability, identity, capabilities, and saved-account counts.
    Status {
        #[arg(long, help = "Print machine-readable JSON")]
        json: bool,
    },
    /// List saved accounts, optionally scoped to one provider.
    List {
        #[arg(long, value_parser = parse_ai_provider)]
        provider: Option<AiProvider>,
        #[arg(long, help = "Print machine-readable JSON")]
        json: bool,
    },
    /// Save the provider's currently authenticated account.
    Save {
        #[arg(value_parser = parse_ai_provider)]
        provider: AiProvider,
        #[arg(long, help = "Print machine-readable JSON")]
        json: bool,
    },
    /// Activate a saved account. The provider is inferred from the account ID.
    Activate {
        account_id: Uuid,
        #[arg(long, help = "Print machine-readable JSON")]
        json: bool,
    },
    /// Delete a saved external-provider account and its stored snapshot.
    Delete {
        account_id: Uuid,
        #[arg(
            long,
            help = "Ignore ChatGPT/Codex Desktop leftovers (never a live Codex CLI session)"
        )]
        force: bool,
        #[arg(long, help = "Print machine-readable JSON")]
        json: bool,
    },
    /// Set or clear a saved external-provider account's custom label.
    SetLabel {
        account_id: Uuid,
        label: Option<String>,
        #[arg(long, help = "Print machine-readable JSON")]
        json: bool,
    },
    /// Refresh cached usage for all saved accounts of one provider.
    RefreshUsage {
        #[arg(value_parser = parse_ai_provider)]
        provider: AiProvider,
        #[arg(long, conflicts_with = "local_only")]
        force: bool,
        /// Read Claude Code local quota only; never contact the usage API.
        #[arg(long)]
        local_only: bool,
        #[arg(long, help = "Print machine-readable JSON")]
        json: bool,
    },
    /// Fetch provider usage for the live account or a saved account ID.
    Usage {
        #[arg(value_parser = parse_ai_provider)]
        provider: AiProvider,
        account_id: Option<Uuid>,
        #[arg(long, help = "Print machine-readable JSON")]
        json: bool,
    },
    /// Decide or apply a Claude account auto-switch, and manage its policy.
    AutoSwitch {
        #[arg(value_parser = parse_ai_provider)]
        provider: AiProvider,
        #[arg(long, conflicts_with = "disable")]
        enable: bool,
        #[arg(long)]
        disable: bool,
        #[arg(long)]
        status: bool,
        #[arg(long)]
        apply: bool,
        /// Apply only if this preflighted account is still the selected candidate.
        #[arg(
            long,
            requires = "apply",
            conflicts_with_all = ["enable", "disable", "status", "threshold", "hysteresis", "cooldown", "strategy"]
        )]
        preferred_account_id: Option<Uuid>,
        #[arg(long)]
        threshold: Option<u8>,
        #[arg(long)]
        hysteresis: Option<u8>,
        #[arg(long)]
        cooldown: Option<u64>,
        #[arg(long, value_parser = parse_claude_auto_switch_strategy)]
        strategy: Option<ClaudeAutoSwitchStrategy>,
        #[arg(long, help = "Print machine-readable JSON")]
        json: bool,
    },
}

/// Version of the `--json` contract. Additive: new fields may appear, existing
/// keys and their meaning do not change without a bump (audit E1).
pub const CONTRACT_VERSION: u32 = 1;

/// Map an error to a stable exit code and machine-readable kind, so scripts can
/// branch on the failure class instead of parsing prose (audit OUT-03).
pub fn classify_error(error: &anyhow::Error) -> (u8, &'static str, Option<String>) {
    let message = format!("{error:#}");
    let lowered = message.to_ascii_lowercase();
    if lowered.contains("invalid value")
        || lowered.contains("unexpected argument")
        || lowered.contains("unrecognized subcommand")
        || lowered.contains("invalid subcommand")
        || lowered.contains("a value is required")
    {
        return (2, "usage", None);
    }
    if lowered.contains("requires account_id")
        || lowered.contains("is required when stdin")
        || lowered.contains("no command given and stdin is not a terminal")
        || lowered.contains("unknown command")
    {
        return (2, "usage", None);
    }
    if lowered.contains("login") && lowered.contains("required") {
        return (
            3,
            "login_required",
            Some("Run `codex login` and retry.".to_owned()),
        );
    }
    if lowered.contains("keychain")
        || lowered.contains("credential store")
        || lowered.contains("decrypt")
    {
        return (
            7,
            "keychain",
            Some("Unlock the login keychain or restore the missing key.".to_owned()),
        );
    }
    if lowered.contains("lock") && (lowered.contains("timed out") || lowered.contains("timeout")) {
        return (
            4,
            "lock_timeout",
            Some("Another Roster process holds the lock; retry shortly.".to_owned()),
        );
    }
    if lowered.contains("no active account") || lowered.contains("no saved account") {
        return (
            5,
            "no_account",
            Some("Run `codex-roster list` and pick an account id.".to_owned()),
        );
    }
    if lowered.contains("http")
        || lowered.contains("contact")
        || lowered.contains("usage request failed")
        || lowered.contains("network")
    {
        return (
            6,
            "network",
            Some("Check connectivity and retry.".to_owned()),
        );
    }
    if lowered.contains("activation_blocked_by_cli") {
        return (3, "activation_blocked_by_cli", None);
    }
    if lowered.contains("activation_blocked_by_desktop") {
        return (3, "activation_blocked_by_desktop", None);
    }
    (1, "error", None)
}

pub fn run() -> Result<()> {
    // `parse()` exits the process on bad input, which would bypass the JSON
    // error envelope that `--json` callers rely on. Help/version still print
    // normally and exit 0.
    let cli = match Cli::try_parse() {
        Ok(cli) => cli,
        Err(error) => {
            use clap::error::ErrorKind;
            if matches!(
                error.kind(),
                ErrorKind::DisplayHelp | ErrorKind::DisplayVersion
            ) {
                error.exit();
            }
            return Err(anyhow::anyhow!(error.render().to_string()));
        }
    };
    let env = env::detect()?;
    let repository = SnapshotRepository::new(
        &env.app_data_dir,
        MigratingSecretStore::new(&env.app_data_dir.join("snapshots")),
    );
    let app = App::new(env, repository);
    match cli.command {
        None => run_interactive_app(&app),
        Some(Command::Status { json }) => {
            let status = app.status()?;
            if json {
                print_json(&status)?;
            } else {
                println!("Environment: {}", status.environment);
                println!("Codex root: {}", status.codex_root);
                match status.current_account {
                    Some(account) => println!("Current account: {}", account.email),
                    None => println!("Current account: not logged in"),
                }
                if let Some(model) = &status.codex_model {
                    println!("Codex model: {model}");
                }
                println!("Saved accounts: {}", status.saved_accounts);
                if let Some(usage) = status.vibe_usage {
                    println!(
                        "VibeCafe ({}d): {} tokens, ${:.2} estimated, {} sessions, {:.1}h active",
                        usage.days,
                        usage.total_tokens,
                        usage.estimated_cost_usd,
                        usage.sessions,
                        usage.active_seconds as f64 / 3600.0
                    );
                }
                if !status.process_warnings.is_empty() {
                    print_process_summary("Codex processes", &status.process_warnings);
                }
            }
            Ok(())
        }
        Some(Command::List { json, all }) => {
            let list = app.list()?;
            if json {
                print_json(&list)?;
                return Ok(());
            }
            let total = list.accounts.len();
            let archived = list
                .accounts
                .iter()
                .filter(|account| account.archived)
                .count();
            let accounts = list
                .accounts
                .iter()
                .filter(|account| all || !account.archived)
                .collect::<Vec<_>>();
            if accounts.is_empty() {
                if total == 0 {
                    println!("No saved accounts in {}.", list.environment);
                } else {
                    println!(
                        "No active accounts in {}; {archived} archived (use --all to list them).",
                        list.environment
                    );
                }
            } else {
                for account in &accounts {
                    println!("{}", render_account_summary(account));
                }
                if !all && archived > 0 {
                    println!("({archived} archived hidden; use --all to include them.)");
                }
            }
            Ok(())
        }
        #[cfg(feature = "external-providers")]
        Some(Command::Providers { command }) => {
            match command.unwrap_or(ProviderCommand::Status { json: false }) {
                ProviderCommand::SyncClaude { email, json } => {
                    let output = app.provider_sync_claude(&email)?;
                    if json {
                        print_json(&output)?;
                    } else {
                        for account in &output.accounts {
                            println!("{}", render_provider_account_summary(account));
                        }
                    }
                }
                ProviderCommand::ClaudeDesktop {
                    account_id,
                    save,
                    restore,
                    json,
                } => {
                    let action = if save {
                        "save"
                    } else if restore {
                        "restore"
                    } else {
                        "status"
                    };
                    let output = app.claude_desktop_login(account_id, action)?;
                    if json {
                        print_json(&output)?;
                    } else {
                        println!(
                            "Desktop login saved: {}; current account matches: {}",
                            output.saved, output.live_account_matches
                        );
                    }
                }
                ProviderCommand::Status { json } => {
                    let output = app.providers_status()?;
                    if json {
                        print_json(&output)?;
                    } else {
                        print_provider_status(&output);
                    }
                }
                ProviderCommand::List { provider, json } => {
                    let output = app.provider_list(provider)?;
                    if json {
                        print_json(&output)?;
                    } else if output.accounts.is_empty() {
                        match provider {
                            Some(provider) => {
                                println!("No saved {provider} accounts in {}.", output.environment)
                            }
                            None => {
                                println!("No saved provider accounts in {}.", output.environment)
                            }
                        }
                    } else {
                        for account in &output.accounts {
                            println!("{}", render_provider_account_summary(account));
                        }
                    }
                }
                ProviderCommand::Save { provider, json } => {
                    let output = app.provider_save_current(provider)?;
                    if json {
                        print_json(&output)?;
                    } else {
                        println!(
                            "Saved {} account {} ({})",
                            output.account.provider, output.account.email, output.account.id
                        );
                    }
                }
                ProviderCommand::Activate { account_id, json } => {
                    let output = app.provider_activate(account_id)?;
                    if json {
                        print_json(&output)?;
                    } else {
                        println!(
                            "Activated {} account {} ({})",
                            output.account.provider, output.account.email, output.account.id
                        );
                        for warning in &output.warnings {
                            eprintln!("Warning: {warning}");
                        }
                        if output.requires_relaunch {
                            println!(
                                "Relaunch the provider app for the new session to take effect."
                            );
                        }
                    }
                }
                ProviderCommand::Delete {
                    account_id,
                    force,
                    json,
                } => {
                    let output = app.provider_delete(account_id, force)?;
                    if json {
                        print_json(&output)?;
                    } else {
                        println!("Deleted {} ({})", output.email, output.id);
                    }
                }
                ProviderCommand::SetLabel {
                    account_id,
                    label,
                    json,
                } => {
                    let account = app.provider_set_label(account_id, label)?;
                    if json {
                        print_json(&serde_json::json!({
                            "account_id": account.id,
                            "custom_label": account.custom_label,
                        }))?;
                    } else {
                        match &account.custom_label {
                            Some(label) => {
                                println!("Label for {} set to \"{label}\"", account.email)
                            }
                            None => println!("Label for {} cleared", account.email),
                        }
                    }
                }
                ProviderCommand::RefreshUsage {
                    provider,
                    force,
                    local_only,
                    json,
                } => {
                    let output = if local_only {
                        if provider != AiProvider::Claude {
                            bail!("--local-only requires Claude");
                        }
                        app.provider_local_claude_usage()?
                    } else {
                        app.provider_refresh_usage(provider, force)?
                    };
                    if json {
                        print_json(&output)?;
                    } else {
                        for account in &output.accounts {
                            println!("{}", render_provider_account_summary(account));
                        }
                    }
                }
                ProviderCommand::Usage {
                    provider,
                    account_id,
                    json,
                } => {
                    let output = app.provider_usage(provider, account_id)?;
                    if json {
                        print_json(&output)?;
                    } else {
                        print_provider_usage_output(&output);
                    }
                }
                ProviderCommand::AutoSwitch {
                    provider,
                    enable,
                    disable,
                    status: _,
                    apply,
                    preferred_account_id,
                    threshold,
                    hysteresis,
                    cooldown,
                    strategy,
                    json,
                } => {
                    if provider != AiProvider::Claude {
                        bail!("auto-switch is only supported for claude");
                    }
                    let configuring = enable
                        || disable
                        || threshold.is_some()
                        || hysteresis.is_some()
                        || cooldown.is_some()
                        || strategy.is_some();
                    let enabled = if enable {
                        Some(true)
                    } else if disable {
                        Some(false)
                    } else {
                        None
                    };
                    let output = if configuring {
                        app.set_claude_auto_switch(
                            enabled, threshold, hysteresis, cooldown, strategy,
                        )?
                    } else if apply {
                        app.claude_auto_switch_apply(preferred_account_id)?
                    } else {
                        app.claude_auto_switch_decide()?
                    };
                    if json {
                        print_json(&output)?;
                    } else {
                        println!("Auto-switch: {}", output.status);
                        if let Some(candidate) = &output.candidate_display_name {
                            println!("Candidate: {candidate}");
                        }
                        if let Some(detail) = &output.detail {
                            println!("Detail: {detail}");
                        }
                    }
                }
            }
            Ok(())
        }
        Some(Command::Save { json }) => {
            let output = app.save_current()?;
            if json {
                print_json(&output)?;
            } else {
                println!("Saved {} ({})", output.account.email, output.account.id);
            }
            Ok(())
        }
        Some(Command::BeginAddAccount { json }) => {
            app.begin_add_account_session()?;
            if json {
                print_json(&serde_json::json!({ "status": "ready_for_login" }))?;
            } else {
                println!(
                    "Current session is saved. Complete the Codex browser sign-in for the new account."
                );
            }
            Ok(())
        }
        Some(Command::SaveAddedAccount { json }) => {
            let output = app.save_added_account_session()?;
            if json {
                print_json(&output)?;
            } else {
                println!("Saved {} ({})", output.account.email, output.account.id);
            }
            Ok(())
        }
        Some(Command::CancelAddAccount { json }) => {
            app.cancel_add_account_session()?;
            if json {
                print_json(&serde_json::json!({ "status": "cancelled" }))?;
            } else {
                println!("Restored the previous Codex session.");
            }
            Ok(())
        }
        Some(Command::AddAccountStatus { json }) => {
            let active = app.add_account_session_active();
            let auth_changed = app.add_account_session_auth_changed()?;
            // Say what to do next, not just whether a marker file exists
            // (audit A3).
            let output = serde_json::json!({
                "active": active,
                "auth_changed": auth_changed,
                "state": if active { "pending" } else { "none" },
                "codex_root": app.env().codex_root.display().to_string(),
                "hint": if active {
                    "Finish the browser login, then run `codex-roster save-added-account`."
                } else {
                    "Start one with `codex-roster begin-add-account`."
                },
            });
            if json {
                print_json(&output)?;
            } else if active {
                println!(
                    "Add account session: pending login in {}",
                    app.env().codex_root.display()
                );
                println!(
                    "Credentials changed: {}",
                    if auth_changed {
                        "yes (ready to save)"
                    } else {
                        "not yet"
                    }
                );
                println!("Finish the browser login, then run `codex-roster save-added-account`.");
            } else {
                println!("Add account session: none");
                println!("Start one with `codex-roster begin-add-account`.");
            }
            Ok(())
        }
        Some(Command::Usage { account_id, json }) => {
            let output = app.usage(account_id)?;
            if json {
                print_json(&output)?;
            } else {
                print_usage_output(&output);
            }
            Ok(())
        }
        Some(Command::RefreshUsage { json }) => {
            app.refresh_usage_for_display()?;
            if json {
                print_json(&serde_json::json!({ "status": "refreshed" }))?;
            } else {
                println!("Refreshed active and stale saved account usage.");
            }
            Ok(())
        }
        Some(Command::Activate {
            account_id,
            json,
            force,
        }) => {
            let mut showed_preflight = false;
            let output = match account_id {
                Some(account_id) => {
                    app.validate_activation_target(account_id)?;
                    let warnings = app.activation_preflight_warnings();
                    let blocking = app.activation_blocking_warnings(force);
                    if !blocking.is_empty() {
                        if !json {
                            print_process_summary("Codex processes", &blocking);
                        }
                        if blocking
                            .iter()
                            .any(|process| !crate::process::is_force_skippable_process(process))
                        {
                            let report = app.activation_blocking_report(force);
                            let mut message = String::from(
                                "activation_blocked_by_cli: a live Codex CLI session is running and `--force` cannot override it",
                            );
                            for line in crate::process::format_blocking_report(&report) {
                                message.push('\n');
                                message.push_str(&line);
                            }
                            message.push_str(
                                "\nClose the listed Codex CLI session(s) (Ctrl-C in the terminal running `codex`) and retry.",
                            );
                            bail!(message);
                        }
                        if !force {
                            bail!(
                                "activation_blocked_by_desktop: ChatGPT/Codex Desktop is still running. Quit it first, or rerun `activate --force` to let Roster close and relaunch it."
                            );
                        }
                    } else if !warnings.is_empty() && force && !json {
                        showed_preflight = true;
                        print_process_summary(
                            "Desktop leftovers (ignored with --force)",
                            &warnings,
                        );
                    }
                    app.activate_with_running_policy(account_id, force)?
                }
                None => {
                    if json {
                        bail!(
                            "--json requires ACCOUNT_ID; run `codex-roster list --json` to find ids"
                        );
                    }
                    if !std::io::stdin().is_terminal() {
                        bail!("ACCOUNT_ID is required when stdin is not a terminal");
                    }
                    let _ = app.interactive(InteractiveMode::ActivateOnce, force)?;
                    return Ok(());
                }
            };
            if json {
                print_json(&output)?;
            } else {
                println!("Activated {} ({})", output.account.email, output.account.id);
                if !showed_preflight {
                    print_process_summary("Codex processes", &output.warnings);
                }
            }
            Ok(())
        }
        Some(Command::EnableLunaReserve { account_id, json }) => {
            let output = app.enable_luna_reserve(account_id)?;
            if json {
                print_json(&output)?;
            } else {
                println!(
                    "Luna Reserve enabled for {} (model: {})",
                    output.account_email, output.model
                );
                if let Some(prev) = output.previous_model {
                    println!("Previous model: {prev}");
                }
            }
            Ok(())
        }
        Some(Command::Delete { account_id, json }) => {
            let output = match account_id {
                Some(account_id) => app.delete(account_id)?,
                None => {
                    let _ = app.interactive(InteractiveMode::DeleteOnce, false)?;
                    return Ok(());
                }
            };
            if json {
                print_json(&output)?;
            } else {
                println!("Deleted saved snapshot {}", output.deleted_account_id);
            }
            Ok(())
        }
        Some(Command::Archive {
            account_id,
            restore,
            json,
        }) => {
            app.set_account_archived(account_id, !restore)?;
            if json {
                print_json(&serde_json::json!({ "account_id": account_id, "archived": !restore }))?;
            } else {
                println!(
                    "{} {account_id}",
                    if restore { "Restored" } else { "Archived" }
                );
            }
            Ok(())
        }
        Some(Command::Export {
            output,
            password_stdin,
            json,
        }) => {
            let password = backup_password(password_stdin)?;
            let accounts = app.export_backup(&output, &password)?;
            if json {
                print_json(&serde_json::json!({ "output": output, "accounts": accounts }))?;
            } else {
                println!("Exported {accounts} accounts to {}", output.display());
            }
            Ok(())
        }
        Some(Command::Import {
            input,
            password_stdin,
            json,
        }) => {
            let password = backup_password(password_stdin)?;
            let (created, updated) = app.import_backup(&input, &password)?;
            if json {
                print_json(&serde_json::json!({ "created": created, "updated": updated }))?;
            } else {
                println!("Imported {created} new and updated {updated} saved accounts");
                eprintln!(
                    "Warning: restored snapshots may hold stale refresh tokens vs live Codex. Save the current session first; do not activate restored rows blindly (that can force re-login)."
                );
            }
            Ok(())
        }
        Some(Command::ImportJson { input, label, json }) => {
            let output = app.import_accounts_from_json(&input, label)?;
            if json {
                print_json(&output)?;
            } else {
                println!(
                    "Imported {} ({}/{} created/updated) from {}",
                    output.format,
                    output.created,
                    output.updated,
                    input.display()
                );
                for account in &output.accounts {
                    println!("  {} <{}>", account.email, account.id);
                }
                eprintln!(
                    "Warning: restored snapshots may hold stale refresh tokens vs live Codex. Save the current session first; do not activate restored rows blindly (that can force re-login)."
                );
            }
            Ok(())
        }
        Some(Command::RestoreAccountListBackup { json }) => {
            let accounts = app.restore_latest_account_list_backup()?;
            if json {
                print_json(&serde_json::json!({ "accounts": accounts }))?;
            } else {
                println!("Restored account list with {accounts} accounts");
                eprintln!(
                    "Warning: restored snapshots may hold stale refresh tokens vs live Codex. Save the current session first; do not activate restored rows blindly (that can force re-login)."
                );
            }
            Ok(())
        }
        Some(Command::RestoreFullBackup { json }) => {
            let accounts = app.restore_latest_full_backup()?;
            if json {
                print_json(&serde_json::json!({ "accounts": accounts }))?;
            } else {
                println!("Restored full backup with {accounts} accounts");
                eprintln!(
                    "Warning: restored snapshots may hold stale refresh tokens vs live Codex. Save the current session first; do not activate restored rows blindly (that can force re-login)."
                );
            }
            Ok(())
        }
        Some(Command::CreateAutomaticFullBackup { json }) => {
            let accounts = app.create_automatic_full_backup()?;
            if json {
                print_json(&serde_json::json!({ "accounts": accounts }))?;
            } else {
                println!("Created automatic full backup with {accounts} accounts");
            }
            Ok(())
        }
        Some(Command::AutoStartUsageWindows {
            enable,
            disable,
            run,
            json,
        }) => {
            let status = if enable {
                app.set_auto_start_usage_windows(true)?
            } else if disable {
                app.set_auto_start_usage_windows(false)?
            } else {
                app.auto_start_usage_windows_status()?
            };
            if run && !disable {
                let output = app.auto_start_usage_windows_once(false)?;
                if json {
                    print_json(&output)?;
                } else {
                    print_auto_start_usage_windows_run(&output);
                }
            } else if json {
                print_json(&status)?;
            } else {
                print_auto_start_usage_windows_status(&status);
            }
            Ok(())
        }
        Some(Command::AutoResumeSession {
            enable,
            disable,
            continue_interrupted,
            json,
        }) => {
            if continue_interrupted {
                let hint = app.continue_interrupted_sessions()?;
                if json {
                    print_json(&hint)?;
                } else {
                    println!(
                        "Continue interrupted: status={} session={}",
                        hint.status,
                        hint.session_id.as_deref().unwrap_or("-")
                    );
                }
                return Ok(());
            }
            let status = if enable {
                app.set_auto_resume_session(true)?
            } else if disable {
                app.set_auto_resume_session(false)?
            } else {
                app.auto_resume_session_status()?
            };
            if json {
                print_json(&status)?;
            } else {
                println!(
                    "Auto-resume session: {}",
                    if status.enabled {
                        "enabled"
                    } else {
                        "disabled"
                    }
                );
            }
            Ok(())
        }
        Some(Command::AutoSwitch {
            enable,
            disable,
            apply,
            account_id,
            force,
            status,
            json,
        }) => {
            let output = if enable {
                app.set_auto_switch_when_exhausted(true)?
            } else if disable {
                app.set_auto_switch_when_exhausted(false)?
            } else if status {
                let enabled = app.auto_switch_enabled()?;
                crate::model::AutoSwitchOutput {
                    enabled,
                    status: if enabled { "enabled" } else { "disabled" }.to_owned(),
                    active_account_id: None,
                    candidate_account_id: None,
                    candidate_display_name: None,
                    detail: None,
                    banked_reset_count: 0,
                    session_resume: None,
                    usage_unknown: false,
                    warnings: Vec::new(),
                    candidate_switch_score: None,
                    next_probe_seconds: None,
                }
            } else {
                app.auto_switch_with_candidate(apply, account_id, force)?
            };
            if json {
                print_json(&output)?;
            } else {
                println!("Auto-switch: {}", output.status);
                if let Some(candidate) = output.candidate_display_name {
                    println!("Candidate: {candidate}");
                }
                if let Some(detail) = output.detail {
                    println!("Detail: {detail}");
                }
            }
            Ok(())
        }
        Some(Command::RecoverLegacySnapshots { json }) => {
            let output = app.recover_legacy_snapshots()?;
            if json {
                print_json(&output)?;
            } else {
                println!("Recovered snapshots: {}", output.recovered_accounts);
                println!("Imported snapshots: {}", output.imported_accounts);
                println!("Skipped snapshots: {}", output.skipped_accounts);
            }
            Ok(())
        }
        Some(Command::TokenUsage { json }) => {
            let output = app.token_usage_summary()?;
            if json {
                print_json(&output)?;
            } else {
                print_token_usage_summary(&output);
            }
            Ok(())
        }
        Some(Command::QuotaHistory { account_id, json }) => {
            let output = app.quota_history(account_id)?;
            if json {
                print_json(&output)?;
            } else {
                println!(
                    "Quota history samples: {} (account {:?})",
                    output.samples.len(),
                    output.account_id
                );
                for sample in output.samples.iter().rev().take(12) {
                    println!(
                        "  minute={} 5h={} wk={}",
                        sample.minute, sample.five_remaining, sample.week_remaining
                    );
                }
            }
            Ok(())
        }
        Some(Command::VibeUsage { command }) => {
            let command = command.unwrap_or(VibeUsageCommand::Sync);
            let should_refresh_cache = matches!(command, VibeUsageCommand::Sync);
            run_vibe_usage(command)?;
            if should_refresh_cache {
                crate::vibe_usage::fetch_and_cache(&app.env().home_dir, &app.env().app_data_dir)?;
            }
            Ok(())
        }
        Some(Command::ResetOutlook { json }) => {
            let outlook = crate::reset_tracker::fetch_reset_outlook()?;
            if json {
                print_json(&outlook)?;
            } else {
                println!("Global reset status: {}", outlook.signal_kind);
                if let Some(next) = &outlook.next_reset_at {
                    println!("Scheduled: {next}");
                }
                println!("{}", outlook.signal_summary);
                println!("Data from Codex Resets — https://codex-resets.com/");
                println!("Last reset: {}", outlook.last_reset_at);
            }
            Ok(())
        }
        Some(Command::ResetEvents { json }) => {
            let events = crate::reset_tracker::fetch_new_reset_events(&app.env().app_data_dir)?;
            if json {
                // Wrapped in an object: `print_json` can only attach
                // `contract_version` to an object, and a bare array left this
                // one command unversioned (contract v2).
                print_json(&serde_json::json!({ "events": events }))?;
            } else if events.is_empty() {
                println!("No new verified global resets.");
            } else {
                for event in events {
                    println!("Global reset {}: {}", event.announced_at, event.summary);
                }
            }
            Ok(())
        }
        Some(Command::ResetTimeline { json }) => {
            let timeline = crate::reset_tracker::fetch_reset_timeline()?;
            if json {
                print_json(&timeline)?;
            } else {
                println!("Reset Timeline ({} events):", timeline.events.len());
                for event in timeline.events.iter().take(10) {
                    println!(
                        "  {} [{}] {}",
                        event.date,
                        event.event_type,
                        event.summary.chars().take(60).collect::<String>()
                    );
                }
            }
            Ok(())
        }
        Some(Command::ResetStatusHistory { json }) => {
            let status = crate::reset_tracker::fetch_reset_status_history()?;
            if json {
                print_json(&status)?;
            } else {
                println!("Codex Status: {}", status.current.description);
                for surface in &status.surfaces {
                    println!("  {}: {}", surface.label, surface.status);
                }
                if !status.incidents.is_empty() {
                    println!("Recent incidents:");
                    for incident in status.incidents.iter().take(3) {
                        println!("  {} [{}]", incident.name, incident.status);
                    }
                }
            }
            Ok(())
        }
        Some(Command::ResetJuice { json }) => {
            let juice = crate::reset_tracker::fetch_reset_juice()?;
            if json {
                print_json(&juice)?;
            } else {
                println!("Quota Juice ({} tiers):", juice.efforts.len());
                for effort in &juice.efforts {
                    println!(
                        "  {}: {} (delta: {})",
                        effort.effort, effort.current, effort.delta
                    );
                }
            }
            Ok(())
        }
        Some(Command::OpenAiStatus { json }) => {
            let status = fetch_openai_status()?;
            if json {
                print_json(&status)?;
            } else {
                println!("OpenAI: {}", status.description);
                for component in status.codex_components {
                    println!("{}: {}", component.name, component.status);
                }
            }
            Ok(())
        }
        Some(Command::QuotaForecast { account_id, json }) => {
            let output = app.quota_forecast(account_id)?;
            if json {
                print_json(&output)?;
            } else {
                let windows = [output.five_hour.as_ref(), output.weekly.as_ref()];
                if windows.iter().all(|window| window.is_none()) {
                    println!(
                        "No cached quota for that account yet; run `codex-roster refresh-usage` first."
                    );
                } else {
                    for window in windows.into_iter().flatten() {
                        println!("{}", crate::forecast::describe_window(window, true));
                    }
                }
            }
            Ok(())
        }
        Some(Command::Doctor { json, bundle }) => {
            let output = collect_doctor_output(&app)?;
            if bundle {
                let path = std::env::current_dir()
                    .unwrap_or_else(|_| PathBuf::from("."))
                    .join("doctor-report.txt");
                let mut text = String::new();
                text.push_str(&format!("codex-roster {}\n", output.version));
                for check in &output.checks {
                    text.push_str(&format!(
                        "[{}] {}: {}{}\n",
                        check.status,
                        check.id,
                        check.detail,
                        check
                            .hint
                            .as_deref()
                            .map(|hint| format!(" (hint: {hint})"))
                            .unwrap_or_default()
                    ));
                }
                std::fs::write(&path, text)
                    .with_context(|| format!("failed to write {}", path.display()))?;
                if !json {
                    println!("Wrote {}", path.display());
                }
            }
            if json {
                print_json(&output)?;
            } else {
                println!("codex-roster {}", output.version);
                for check in &output.checks {
                    println!("  [{:>4}] {:<16} {}", check.status, check.id, check.detail);
                    if let Some(hint) = &check.hint {
                        println!("         hint: {hint}");
                    }
                }
            }
            Ok(())
        }
        Some(Command::Schema { command, json }) => {
            let schema = schema_document(command.as_deref());
            if json {
                print_json(&schema)?;
            } else {
                println!("{schema}");
            }
            Ok(())
        }
        Some(Command::SetLabel {
            account_id,
            label,
            json,
        }) => {
            let label = (!label.trim().is_empty()).then_some(label);
            app.set_account_label(account_id, label.clone())?;
            if json {
                print_json(
                    &serde_json::json!({ "account_id": account_id, "custom_label": label }),
                )?;
            } else {
                println!("Updated {account_id} label");
            }
            Ok(())
        }
    }
}

fn backup_password(password_stdin: bool) -> Result<String> {
    if password_stdin {
        let mut password = String::new();
        std::io::stdin().read_to_string(&mut password)?;
        let password = password.trim_end_matches(['\r', '\n']).to_owned();
        if password.is_empty() {
            bail!("a backup password is required");
        }
        Ok(password)
    } else {
        dialoguer::Password::new()
            .with_prompt("Backup password")
            .interact()
            .context("failed to read backup password")
    }
}

/// Collect local diagnostics. Never prints secrets: key files are reported by
/// count and mode only, and no account emails are included (audit E1/O2).
fn collect_doctor_output<S>(app: &App<S>) -> Result<crate::model::DoctorOutput>
where
    S: crate::secrets::SecretStore,
{
    use crate::model::DoctorCheck;
    let mut checks = Vec::new();
    let env = app.env();

    checks.push(DoctorCheck {
        id: "version".to_owned(),
        status: "ok".to_owned(),
        detail: format!(
            "codex-roster {} (json contract {})",
            env!("CARGO_PKG_VERSION"),
            CONTRACT_VERSION
        ),
        hint: None,
    });

    let data_dir = env.app_data_dir.clone();
    let data_status = if data_dir.is_dir() { "ok" } else { "warn" };
    checks.push(DoctorCheck {
        id: "app_data".to_owned(),
        status: data_status.to_owned(),
        detail: format!("{} ({})", data_dir.display(), data_status),
        hint: (data_status == "warn").then(|| "It is created on first save.".to_owned()),
    });

    let keys_dir = data_dir.join("keys");
    let mut key_count = 0usize;
    let mut loose_modes = 0usize;
    if let Ok(entries) = std::fs::read_dir(&keys_dir) {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if !name.ends_with(".key") {
                continue;
            }
            key_count += 1;
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                if let Ok(metadata) = entry.metadata()
                    && metadata.permissions().mode() & 0o777 != 0o600
                {
                    loose_modes += 1;
                }
            }
        }
    }
    let key_status = if loose_modes > 0 { "fail" } else { "ok" };
    checks.push(DoctorCheck {
        id: "keys".to_owned(),
        status: key_status.to_owned(),
        detail: format!("{key_count} key file(s), {loose_modes} with loose permissions"),
        hint: (loose_modes > 0).then(|| {
            "Run `chmod 600` on the key files; a same-user process could read them.".to_owned()
        }),
    });

    for (id, file_name) in [
        ("lock_operation", ".operation.lock"),
        ("lock_auth", ".auth-operation.lock"),
        ("lock_auto_switch", ".auto-switch.lock"),
    ] {
        let path = data_dir.join(file_name);
        let (status, detail) = match std::fs::OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(false)
            .open(&path)
        {
            Ok(file) => match fs2::FileExt::try_lock_exclusive(&file) {
                Ok(()) => {
                    let _ = fs2::FileExt::unlock(&file);
                    ("ok", "free".to_owned())
                }
                Err(_) => ("warn", "held by another process".to_owned()),
            },
            Err(error) => ("warn", format!("unreadable: {error}")),
        };
        checks.push(DoctorCheck {
            id: id.to_owned(),
            status: status.to_owned(),
            detail,
            hint: None,
        });
    }

    // Account-list backups are the last line of defence for metadata.json, so a
    // stalled or failing backup must be visible here (audit R2/A2).
    let backup_dir = data_dir.join("account-list-backups");
    let newest_backup = std::fs::read_dir(&backup_dir)
        .ok()
        .into_iter()
        .flatten()
        .filter_map(|entry| entry.ok())
        .filter(|entry| entry.file_name().to_string_lossy().starts_with("metadata-"))
        .filter_map(|entry| entry.metadata().ok()?.modified().ok())
        .max();
    let (backup_status, backup_detail) = match newest_backup {
        Some(modified) => {
            let age = std::time::SystemTime::now()
                .duration_since(modified)
                .unwrap_or_default();
            let hours = age.as_secs() / 3600;
            if hours > 24 {
                (
                    "warn",
                    format!("newest account-list backup is {hours}h old"),
                )
            } else {
                ("ok", format!("newest account-list backup is {hours}h old"))
            }
        }
        None => ("warn", "no account-list backup yet".to_owned()),
    };
    checks.push(DoctorCheck {
        id: "account_list_backup".to_owned(),
        status: backup_status.to_owned(),
        detail: backup_detail,
        hint: (backup_status == "warn").then(|| {
            "Save or edit an account to trigger a new backup; check disk space and permissions."
                .to_owned()
        }),
    });

    let auth_path = env.codex_root.join("auth.json");
    let auth_status = if auth_path.is_file() { "ok" } else { "warn" };
    checks.push(DoctorCheck {
        id: "codex_auth".to_owned(),
        status: auth_status.to_owned(),
        detail: if auth_path.is_file() {
            "~/.codex/auth.json present".to_owned()
        } else {
            "~/.codex/auth.json missing (not signed in?)".to_owned()
        },
        hint: None,
    });

    let mut leftover_dirs = 0usize;
    if let Ok(entries) = std::fs::read_dir(&env.codex_root) {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.starts_with(".cas-backup-") || name.starts_with(".cas-restore-") {
                leftover_dirs += 1;
            }
        }
    }
    checks.push(DoctorCheck {
        id: "leftover_recovery".to_owned(),
        status: if leftover_dirs > 0 { "warn" } else { "ok" }.to_owned(),
        detail: format!("{leftover_dirs} staged auth recovery dir(s)"),
        hint: (leftover_dirs > 0)
            .then(|| "Safe to delete once no switch is in progress.".to_owned()),
    });

    for port in [1455u16, 1457u16] {
        let address = std::net::SocketAddr::from(([127, 0, 0, 1], port));
        let busy =
            std::net::TcpStream::connect_timeout(&address, std::time::Duration::from_millis(200))
                .is_ok();
        checks.push(DoctorCheck {
            id: format!("port_{port}"),
            status: if busy { "warn" } else { "ok" }.to_owned(),
            detail: if busy { "in use" } else { "free" }.to_owned(),
            hint: busy.then(|| {
                "ChatGPT Desktop usually holds the Codex OAuth callback ports.".to_owned()
            }),
        });
    }

    let list = app.list()?;
    let archived = list
        .accounts
        .iter()
        .filter(|account| account.archived)
        .count();
    checks.push(DoctorCheck {
        id: "accounts".to_owned(),
        status: "ok".to_owned(),
        detail: format!("{} saved, {archived} archived", list.accounts.len()),
        hint: None,
    });

    let newest_cache = list
        .accounts
        .iter()
        .filter_map(|account| account.usage.as_ref().map(|usage| usage.fetched_at))
        .max();
    checks.push(DoctorCheck {
        id: "usage_cache".to_owned(),
        status: "ok".to_owned(),
        detail: match newest_cache {
            Some(fetched_at) => {
                let age = time::OffsetDateTime::now_utc() - fetched_at;
                format!(
                    "newest cached usage {} minute(s) old",
                    age.whole_minutes().max(0)
                )
            }
            None => "no cached usage".to_owned(),
        },
        hint: None,
    });

    checks.push(DoctorCheck {
        id: "add_account_session".to_owned(),
        status: "ok".to_owned(),
        detail: if crate::codex::add_account_session_active(env) {
            "pending add-account session".to_owned()
        } else {
            "none".to_owned()
        },
        hint: None,
    });

    Ok(crate::model::DoctorOutput {
        version: env!("CARGO_PKG_VERSION").to_owned(),
        checks,
    })
}

/// Static description of the JSON contract. Kept in code so `schema` can never
/// drift from the version constant it reports.
fn schema_document(command: Option<&str>) -> String {
    let envelope = "Every --json output includes \"contract_version\": 1 (additive).\n\
View timestamps are RFC3339 strings (older array-form values are still read).\n\
Errors print {\"contract_version\":1,\"error\":{\"code\",\"message\",\"hint\"}} to stdout.\n\
Exit codes: 0 ok, 2 usage, 3 login/blocked, 4 lock timeout, 5 no account, 6 network, 7 keychain, 8 unsupported.";
    match command {
        None => format!(
            "{envelope}\n\nCommands with typed JSON output: status, list, save, usage, refresh-usage, activate, delete, archive, export, import, import-json, restore-account-list-backup, restore-full-backup, create-automatic-full-backup, auto-switch, auto-start-usage-windows, auto-resume-session, token-usage, quota-history, quota-forecast, reset-outlook, reset-events, reset-timeline, open-ai-status, add-account-status, set-label, enable-luna-reserve, doctor."
        ),
        Some(name) => {
            let fields = match name {
                "status" => {
                    "environment, codex_root, current_account, current_account_saved_id, saved_accounts, process_warnings, vibe_usage?, codex_model?, activity?, warnings[]"
                }
                "list" => {
                    "environment, accounts[] (id, email, plan_label, is_active, created_at, updated_at, usage, archived)"
                }
                "usage" => "account, usage (five_hour, weekly, credits, banked_resets, plan_label)",
                "auto-switch" => {
                    "enabled, status, active_account_id, candidate_account_id, candidate_display_name, detail, banked_reset_count, session_resume?, usage_unknown, warnings[], candidate_switch_score?, next_probe_seconds?"
                }
                "reset-events" => "events[] (id, reset_type, announced_at, summary, audience?)",
                "reset-timeline" => "events[] (id, announced_at, summary, audience?)",
                "add-account-status" => "active, auth_changed, state, codex_root, hint",
                "open-ai-status" => "indicator, description, updated_at, codex_components[]",
                "auto-start-usage-windows" => "enabled, poll_seconds",
                "auto-resume-session" => "enabled, pending?, hint?",
                "doctor" => "version, checks[] (id, status, detail, hint?)",
                "token-usage" => "totals, by_day, by_project",
                "quota-history" => "account_id, samples[] (minute, five_remaining, week_remaining)",
                "quota-forecast" => {
                    "account_id, generated_at, five_hour?, weekly? (window, remaining_percent, burn_per_minute, time_to_empty_minutes, ci_low_minutes, ci_high_minutes, confidence, sample_count)"
                }
                _ => {
                    "unknown command; run `codex-roster schema` for the envelope and supported commands"
                }
            };
            format!("{envelope}\n\n{name}: {fields}")
        }
    }
}

fn run_interactive_app<S>(app: &App<S>) -> Result<()>
where
    S: crate::secrets::SecretStore,
{
    // A non-TTY stdin makes `Term::read_key` return `Key::Unknown` forever, so
    // an unguarded menu would spin at 100% CPU in scripts/CI (audit SAF-01).
    if !std::io::stdin().is_terminal() {
        bail!(
            "no command given and stdin is not a terminal; use `codex-roster status --json` or run `codex-roster` in a terminal"
        );
    }
    crate::app::spawn_auto_start_usage_windows_worker(app.env().clone());
    crate::app::spawn_auto_switch_worker(app.env().clone());
    #[cfg(feature = "external-providers")]
    crate::app::spawn_claude_auto_switch_worker(app.env().clone());
    crate::app::spawn_usage_refresh_worker(app.env().clone());
    crate::app::spawn_vibe_usage_worker(app.env().clone());
    let result = app.interactive(InteractiveMode::Persistent, false);
    crate::app::stop_vibe_usage_worker();
    match result? {
        InteractiveExit::Quit => Ok(()),
    }
}

fn print_json<T>(value: &T) -> Result<()>
where
    T: serde::Serialize,
{
    // Every `--json` path goes through here, so the contract version is added
    // once instead of on each of the 30+ output types.
    let mut value = serde_json::to_value(value)?;
    if let Some(object) = value.as_object_mut() {
        object.insert(
            "contract_version".to_owned(),
            serde_json::Value::from(CONTRACT_VERSION),
        );
    }
    println!("{}", serde_json::to_string_pretty(&value)?);
    Ok(())
}

#[allow(dead_code)]
fn print_json_unversioned<T>(value: &T) -> Result<()>
where
    T: serde::Serialize,
{
    let json = serde_json::to_string_pretty(value).context("failed to encode JSON output")?;
    println!("{json}");
    Ok(())
}

fn print_process_summary(title: &str, processes: &[RunningCodexProcess]) {
    println!("{title}:");
    for line in format_process_table(processes) {
        println!("{line}");
    }
}

fn render_account_summary(account: &AccountView) -> String {
    let mut line = format!("{} {}", account.id, account.email);
    if let Some(label) = account
        .custom_label
        .as_deref()
        .filter(|label| !label.trim().is_empty())
    {
        line.push_str(&format!(" ({label})"));
    }
    if account.is_active {
        line.push_str(" [active]");
    }
    if account.archived {
        line.push_str(" [archived]");
    }
    if let Some(plan) = account
        .plan_label
        .as_deref()
        .filter(|plan| !plan.is_empty())
    {
        line.push_str(&format!(" [{plan}]"));
    }
    if account
        .usage_error
        .as_deref()
        .is_some_and(usage_error_requires_login)
    {
        line.push_str(&format!(
            " [{}]",
            usage_error_label(account.usage_error.as_deref().unwrap_or_default()).to_lowercase()
        ));
    } else {
        let mut rendered_window = false;
        if let Some(usage) = &account.usage {
            for (label, window) in [
                ("5h", usage.five_hour.as_ref()),
                ("weekly", usage.weekly.as_ref()),
            ] {
                let Some(window) = window else { continue };
                rendered_window = true;
                if window.reset_at <= OffsetDateTime::now_utc() {
                    line.push_str(&format!(" [{label} reset passed]"));
                } else {
                    // Show the reset in the user's own time zone: a UTC date is
                    // off by up to a day for many users (audit CLI-04).
                    let local = window.reset_at.to_offset(
                        time::UtcOffset::current_local_offset().unwrap_or(time::UtcOffset::UTC),
                    );
                    line.push_str(&format!(
                        " [{label} remaining: {}%, reset {} {}]",
                        // Depleted windows read as 0% here, matching the app and
                        // the TUI instead of leaking the raw 1% sentinel
                        // (audit Q7/P0-4).
                        crate::model::display_remaining_percent(window),
                        local.date(),
                        local.time(),
                    ));
                }
            }
        }
        if !rendered_window && let Some(error) = &account.usage_error {
            line.push_str(&format!(" [{}]", usage_error_label(error).to_lowercase()));
        }
    }
    line
}

fn print_usage_output(output: &UsageOutput) {
    println!("Environment: {}", output.environment);
    println!("Account: {}", output.account.email);
    if let Some(plan) = &output.account.plan_label {
        println!("Plan: {plan}");
    }
    print_usage_summary(&output.usage);
}

#[cfg(feature = "external-providers")]
fn parse_ai_provider(value: &str) -> std::result::Result<AiProvider, String> {
    match value.trim().to_ascii_lowercase().replace('-', "_").as_str() {
        "openai" | "open_ai" | "codex" => Ok(AiProvider::OpenAi),
        "claude" | "claude_code" | "anthropic" => Ok(AiProvider::Claude),
        "cursor" => Ok(AiProvider::Cursor),
        "grok" | "grok_build" | "xai" => Ok(AiProvider::Grok),
        _ => Err(format!(
            "unknown provider {value:?}; expected one of: openai, claude, cursor, grok"
        )),
    }
}

#[cfg(feature = "external-providers")]
fn parse_claude_auto_switch_strategy(
    value: &str,
) -> std::result::Result<ClaudeAutoSwitchStrategy, String> {
    match value.trim().to_ascii_lowercase().as_str() {
        "best" => Ok(ClaudeAutoSwitchStrategy::Best),
        "consume-first" | "consume_first" => Ok(ClaudeAutoSwitchStrategy::ConsumeFirst),
        _ => Err(format!(
            "unknown strategy {value:?}; expected best or consume-first"
        )),
    }
}

#[cfg(feature = "external-providers")]
fn print_provider_status(output: &ProviderStatusOutput) {
    println!("Environment: {}", output.environment);
    for provider in &output.providers {
        let identity = provider
            .identity
            .as_ref()
            .map(|identity| identity.email.as_str())
            .unwrap_or("not logged in");
        let capabilities = provider
            .capabilities
            .iter()
            .map(|capability| format!("{:?}", capability).to_ascii_lowercase())
            .collect::<Vec<_>>()
            .join(", ");
        println!(
            "{}: {} · saved={} · identity={} · capabilities={}",
            provider.provider,
            if provider.available {
                "available"
            } else {
                "unavailable"
            },
            provider.saved_accounts,
            identity,
            capabilities
        );
    }
}

#[cfg(feature = "external-providers")]
fn render_provider_account_summary(account: &ProviderAccountView) -> String {
    let mut line = format!(
        "{} {} {}{}",
        account.id,
        account.provider,
        account.email,
        if account.is_active { " [active]" } else { "" }
    );
    if let Some(plan) = &account.plan_label {
        line.push_str(&format!(" [{plan}]"));
    }
    if let Some(usage) = &account.usage {
        append_provider_usage_summary(&mut line, usage);
    } else if let Some(error) = &account.usage_error {
        line.push_str(&format!(" [usage: {error}]"));
    }
    line
}

#[cfg(feature = "external-providers")]
fn append_provider_usage_summary(line: &mut String, usage: &ProviderUsageView) {
    if usage.status != ProviderUsageStatus::Ok {
        line.push_str(&format!(" [usage: {:?}]", usage.status).to_ascii_lowercase());
    }
    if let Some(window) = usage
        .headline_window
        .as_ref()
        .and_then(|key| usage.windows.iter().find(|window| &window.key == key))
        .or_else(|| usage.windows.first())
    {
        if let Some(remaining) = window.remaining_percent {
            line.push_str(&format!(
                " [{} remaining: {remaining}%{}]",
                window.label,
                if window.ahead_of_pace == Some(true) {
                    " (ahead of pace)"
                } else {
                    ""
                }
            ));
        } else if window.used.is_some() || window.limit.is_some() {
            line.push_str(&format!(
                " [{}: {} / {} {}]",
                window.label,
                window
                    .used
                    .map_or_else(|| "?".to_owned(), |value| value.to_string()),
                window
                    .limit
                    .map_or_else(|| "?".to_owned(), |value| value.to_string()),
                window.unit.as_deref().unwrap_or("")
            ));
        }
    }
}

#[cfg(feature = "external-providers")]
fn print_provider_usage_output(output: &ProviderUsageOutput) {
    println!("Environment: {}", output.environment);
    println!("Provider: {}", output.usage.provider);
    println!("Account: {}", output.account.email);
    if let Some(plan) = output
        .usage
        .plan_label
        .as_ref()
        .or(output.account.plan_label.as_ref())
    {
        println!("Plan: {plan}");
    }
    println!(
        "Status: {}",
        format!("{:?}", output.usage.status).to_ascii_lowercase()
    );
    println!(
        "Fidelity: {}",
        format!("{:?}", output.usage.fidelity).to_ascii_lowercase()
    );
    println!("Fetched at: {}", output.usage.fetched_at);
    for window in &output.usage.windows {
        match (window.remaining_percent, window.used, window.limit) {
            (Some(remaining), _, _) => {
                print!("{} remaining: {remaining}%", window.label);
            }
            (_, Some(used), Some(limit)) => {
                print!(
                    "{}: {used} / {limit} {}",
                    window.label,
                    window.unit.as_deref().unwrap_or("")
                );
            }
            (_, Some(used), None) => {
                print!(
                    "{}: {used} {}",
                    window.label,
                    window.unit.as_deref().unwrap_or("")
                );
            }
            _ => print!("{}", window.label),
        }
        if window.ahead_of_pace == Some(true) {
            print!(" (ahead of pace)");
        }
        if let Some(reset_at) = window.reset_at {
            print!(" (reset {reset_at})");
        }
        println!();
    }
    if let Some(detail) = &output.usage.detail {
        println!("Detail: {detail}");
    }
}

fn print_auto_start_usage_windows_status(output: &AutoStartUsageWindowsStatusOutput) {
    println!(
        "Auto-start usage windows: {}",
        if output.enabled {
            "enabled"
        } else {
            "disabled"
        }
    );
    println!("Poll interval: {}s", output.poll_seconds);
}

fn print_auto_start_usage_windows_run(output: &AutoStartUsageWindowsRunOutput) {
    println!(
        "Auto-start usage windows: {}",
        if output.enabled {
            "enabled"
        } else {
            "disabled"
        }
    );
    println!("Checked accounts: {}", output.checked_accounts);
    for account in &output.pinged_accounts {
        match &account.detail {
            Some(detail) => println!("{}: {} ({detail})", account.email, account.status),
            None => println!("{}: {}", account.email, account.status),
        }
    }
    for skipped in &output.skipped {
        println!("Skipped: {skipped}");
    }
}

fn print_token_usage_summary(output: &TokenUsageSummaryOutput) {
    println!("Local Codex session tokens:");
    println!(
        "Today: {} (est. ${:.2})",
        output.today, output.today_cost_usd
    );
    println!(
        "Last 7 days: {} (est. ${:.2})",
        output.last_7_days, output.last_7_days_cost_usd
    );
    println!(
        "Last 30 days: {} (est. ${:.2})",
        output.last_30_days, output.last_30_days_cost_usd
    );
    println!("Last 365 days: {}", output.last_365_days);
    println!(
        "All time: {} (est. ${:.2})",
        output.all_time, output.estimated_cost_usd
    );
    if output.subagent_sessions > 0 {
        println!(
            "Scanned {} sessions ({} main, {} subagents) / {} token events",
            output.sessions_scanned,
            output.main_sessions,
            output.subagent_sessions,
            output.token_events
        );
    } else {
        println!(
            "Scanned {} sessions / {} token events",
            output.sessions_scanned, output.token_events
        );
    }
}

fn run_vibe_usage(command: VibeUsageCommand) -> Result<()> {
    let mut args = vec![
        "--yes".to_owned(),
        crate::vibe_usage::VIBE_USAGE_NPM_SPEC.to_owned(),
    ];
    match command {
        VibeUsageCommand::Init => args.push("init".to_owned()),
        VibeUsageCommand::Sync => args.push("sync".to_owned()),
        VibeUsageCommand::Summary { days } => {
            args.extend(["summary".to_owned(), "--days".to_owned(), days.to_string()]);
        }
        VibeUsageCommand::Status => args.push("status".to_owned()),
    }
    let status = ProcessCommand::new("npx")
        .args(args)
        .status()
        .context("failed to launch npx; install Node.js 20+ to use `vibe-usage`")?;
    if !status.success() {
        bail!("vibe-usage exited with status {status}");
    }
    Ok(())
}

fn print_usage_summary(usage: &AccountUsageView) {
    println!("Source: {}", format!("{:?}", usage.source).to_lowercase());
    println!("Fetched at: {}", usage.fetched_at);
    if let Some(five_hour) = &usage.five_hour {
        println!(
            "5h remaining: {}% (reset {})",
            crate::model::display_remaining_percent(five_hour),
            five_hour.reset_at
        );
    }
    if let Some(weekly) = &usage.weekly {
        println!(
            "Weekly remaining: {}% (reset {})",
            crate::model::display_remaining_percent(weekly),
            weekly.reset_at
        );
    }
    if let Some(credits) = &usage.credits {
        println!(
            "Credits: {} (has_credits={}, unlimited={})",
            credits.balance, credits.has_credits, credits.unlimited
        );
    }
    if let Some(resets) = &usage.banked_resets {
        println!("Banked resets: {} available", resets.available_count);
        if let Some(details) = &resets.credits {
            for credit in details {
                let title = credit.title.as_deref().unwrap_or("Codex rate-limit reset");
                match credit.expires_at {
                    Some(expires_at) => println!("  {title} · expires {expires_at}"),
                    None => println!("  {title} · no expiry reported"),
                }
            }
        }
    }
}

#[cfg(all(test, feature = "external-providers"))]
mod provider_apply_cli_tests {
    use super::*;

    #[test]
    fn sync_claude_requires_verified_email() {
        assert!(
            Cli::try_parse_from(["codex-roster", "providers", "sync-claude", "--json"]).is_err()
        );
        assert!(
            Cli::try_parse_from([
                "codex-roster",
                "providers",
                "sync-claude",
                "--email",
                "signed-in@example.com",
                "--json"
            ])
            .is_ok()
        );
    }

    #[test]
    fn claude_apply_preserves_preflighted_candidate() {
        let id = Uuid::new_v4();
        let cli = Cli::try_parse_from([
            "codex-roster",
            "providers",
            "auto-switch",
            "claude",
            "--apply",
            "--preferred-account-id",
            &id.to_string(),
            "--json",
        ])
        .unwrap();
        let Some(Command::Providers {
            command:
                Some(ProviderCommand::AutoSwitch {
                    apply,
                    preferred_account_id,
                    ..
                }),
        }) = cli.command
        else {
            panic!("unexpected command")
        };
        assert!(apply);
        assert_eq!(preferred_account_id, Some(id));
    }

    #[test]
    fn preflighted_candidate_requires_unambiguous_apply() {
        let id = Uuid::new_v4().to_string();
        for extra in [
            vec![],
            vec!["--apply", "--enable"],
            vec!["--apply", "--status"],
            vec!["--apply", "--threshold", "80"],
        ] {
            let mut args = vec![
                "codex-roster",
                "providers",
                "auto-switch",
                "claude",
                "--preferred-account-id",
                &id,
            ];
            args.extend(extra);
            assert!(Cli::try_parse_from(args).is_err());
        }
    }
}

#[cfg(all(test, not(feature = "external-providers")))]
mod codex_only_cli_tests {
    use super::*;

    #[test]
    fn default_cli_exposes_codex_without_external_provider_actions() {
        assert!(Cli::try_parse_from(["codex-roster", "list", "--json"]).is_ok());
        assert!(Cli::try_parse_from(["codex-roster", "providers", "status"]).is_err());
    }
}

#[cfg(test)]
mod tests {
    use super::{CONTRACT_VERSION, classify_error, render_account_summary, schema_document};
    use anyhow::anyhow;
    use time::OffsetDateTime;
    use uuid::Uuid;

    #[test]
    fn a_depleted_window_reads_as_zero_percent_everywhere() {
        let now = OffsetDateTime::now_utc();
        let account = crate::model::AccountView {
            id: Uuid::new_v4(),
            provider: crate::model::AiProvider::OpenAi,
            email: "dry@example.com".to_owned(),
            subject: None,
            name: None,
            custom_label: None,
            plan_label: Some("Plus".to_owned()),
            environment: crate::model::EnvironmentKind::Linux,
            is_active: true,
            created_at: now,
            updated_at: now,
            last_activated_at: None,
            archived: false,
            usage: Some(crate::model::AccountUsageView {
                source: crate::model::UsageSource::LiveAccessToken,
                fetched_at: now,
                // 1% is the "exhausted" sentinel; the CLI must not print it raw
                // while the app shows 0% (audit Q7/P0-4).
                five_hour: Some(crate::model::UsageWindowView {
                    used_percent: 99,
                    remaining_percent: 1,
                    reset_at: now + time::Duration::hours(1),
                }),
                weekly: None,
                credits: None,
                banked_resets: None,
                plan_label: None,
                subscription_active_until: None,
                luna_reserve: None,
                five_hour_known: true,
                weekly_known: false,
            }),
            usage_error: None,
        };
        let line = render_account_summary(&account);
        assert!(
            line.contains("5h remaining: 0%"),
            "depleted windows must read 0%, got: {line}"
        );
        assert!(
            !line.contains("remaining: 1%"),
            "raw sentinel leaked: {line}"
        );
    }

    #[test]
    fn account_summary_shows_label_plan_and_state() {
        let now = OffsetDateTime::now_utc();
        let account = crate::model::AccountView {
            id: Uuid::new_v4(),
            provider: crate::model::AiProvider::OpenAi,
            email: "person@example.com".to_owned(),
            subject: None,
            name: None,
            custom_label: Some("Work".to_owned()),
            plan_label: Some("Plus".to_owned()),
            environment: crate::model::EnvironmentKind::Linux,
            is_active: true,
            created_at: now,
            updated_at: now,
            last_activated_at: None,
            archived: true,
            usage: Some(crate::model::AccountUsageView {
                source: crate::model::UsageSource::LiveAccessToken,
                fetched_at: now,
                five_hour: Some(crate::model::UsageWindowView {
                    used_percent: 20,
                    remaining_percent: 80,
                    reset_at: now + time::Duration::hours(3),
                }),
                weekly: None,
                credits: None,
                banked_resets: None,
                plan_label: None,
                subscription_active_until: None,
                luna_reserve: None,
                five_hour_known: true,
                weekly_known: false,
            }),
            usage_error: None,
        };
        let line = render_account_summary(&account);
        assert!(line.contains("person@example.com"));
        assert!(
            line.contains("(Work)"),
            "custom label must be visible: {line}"
        );
        assert!(line.contains("[active]"));
        assert!(
            line.contains("[archived]"),
            "archived rows must be marked: {line}"
        );
        assert!(line.contains("[Plus]"));
        assert!(line.contains("5h remaining: 80%"));
        assert!(
            line.contains("reset "),
            "reset time must be rendered: {line}"
        );
    }

    #[test]
    fn classify_error_maps_known_failures_to_exit_codes() {
        assert_eq!(
            classify_error(&anyhow!("--json requires ACCOUNT_ID; run list")).0,
            2
        );
        assert_eq!(
            classify_error(&anyhow!("login required for this account")).0,
            3
        );
        assert_eq!(
            classify_error(&anyhow!("timed out locking .operation.lock")).0,
            4
        );
        assert_eq!(classify_error(&anyhow!("no saved account matches")).0, 5);
        assert_eq!(
            classify_error(&anyhow!("failed to contact OpenAI Status")).0,
            6
        );
        assert_eq!(classify_error(&anyhow!("the keychain key is missing")).0, 7);
        let (code, kind, _) = classify_error(&anyhow!("something unexpected"));
        assert_eq!((code, kind), (1, "error"));
    }

    #[test]
    fn clap_style_failures_classify_as_usage_errors() {
        // `try_parse` errors now flow through classify_error so `--json` callers
        // still get the envelope (contract v2).
        let invalid = anyhow!("error: invalid value 'not-a-uuid' for '[ACCOUNT_ID]'");
        assert_eq!(classify_error(&invalid).0, 2);
        let unknown = anyhow!("error: unrecognized subcommand 'nope'");
        assert_eq!(classify_error(&unknown).0, 2);
        let missing = anyhow!("error: a value is required for '--json <VALUE>'");
        assert_eq!(classify_error(&missing).0, 2);
    }

    #[test]
    fn schema_covers_the_newer_commands_and_fields() {
        assert!(schema_document(None).contains("quota-forecast"));
        assert!(schema_document(None).contains("reset-events"));
        assert!(schema_document(Some("reset-events")).contains("events[]"));
        assert!(schema_document(Some("status")).contains("warnings[]"));
        assert!(schema_document(Some("add-account-status")).contains("state"));
    }

    #[test]
    fn schema_document_describes_the_contract() {
        let envelope = schema_document(None);
        assert!(envelope.contains("contract_version"));
        assert!(envelope.contains("Exit codes"));
        let status = schema_document(Some("status"));
        assert!(status.contains("process_warnings"));
        // The version is a compile-time constant; assert it in a const block so
        // the check cannot be optimized away or flagged as a runtime assertion.
        const { assert!(CONTRACT_VERSION >= 1) };
    }
}
