use std::io::Read;
use std::path::PathBuf;
use std::process::Command as ProcessCommand;

use anyhow::{Context, Result, bail};
use clap::{Parser, Subcommand};
use time::OffsetDateTime;
use uuid::Uuid;

use crate::app::{App, InteractiveExit, InteractiveMode};
use crate::env;
use crate::model::{
    AccountUsageView, AccountView, AiProvider, AutoStartUsageWindowsRunOutput,
    AutoStartUsageWindowsStatusOutput, ProviderAccountView, ProviderStatusOutput,
    ProviderUsageOutput, ProviderUsageStatus, ProviderUsageView, RunningCodexProcess,
    TokenUsageSummaryOutput, UsageOutput,
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
    about = "Manage Codex accounts across the CLI and IDE"
)]
struct Cli {
    #[command(subcommand)]
    command: Option<Command>,
}

#[derive(Subcommand)]
enum Command {
    Status {
        #[arg(long)]
        json: bool,
    },
    List {
        #[arg(long)]
        json: bool,
    },
    /// Inspect and manage accounts for Codex, Claude Code, Cursor, and Grok Build.
    Providers {
        #[command(subcommand)]
        command: Option<ProviderCommand>,
    },
    Save {
        #[arg(long)]
        json: bool,
    },
    BeginAddAccount {
        #[arg(long)]
        json: bool,
    },
    SaveAddedAccount {
        #[arg(long)]
        json: bool,
    },
    CancelAddAccount {
        #[arg(long)]
        json: bool,
    },
    AddAccountStatus {
        #[arg(long)]
        json: bool,
    },
    Usage {
        account_id: Option<Uuid>,
        #[arg(long)]
        json: bool,
    },
    /// Re-query the active account plus any stale saved accounts (staleness-aware).
    RefreshUsage {
        #[arg(long)]
        json: bool,
    },
    Activate {
        account_id: Option<Uuid>,
        #[arg(long)]
        json: bool,
        #[arg(long)]
        force: bool,
    },
    Delete {
        account_id: Option<Uuid>,
        #[arg(long)]
        json: bool,
    },
    Archive {
        account_id: Uuid,
        #[arg(long)]
        restore: bool,
        #[arg(long)]
        json: bool,
    },
    Export {
        output: PathBuf,
        #[arg(long)]
        password_stdin: bool,
        #[arg(long)]
        json: bool,
    },
    Import {
        input: PathBuf,
        #[arg(long)]
        password_stdin: bool,
        #[arg(long)]
        json: bool,
    },
    /// Import account(s) from Codex auth.json, a Roster snapshot JSON, or a plaintext backup bundle.
    ImportJson {
        input: PathBuf,
        /// Optional display label (single-account auth.json / snapshot only).
        #[arg(long)]
        label: Option<String>,
        #[arg(long)]
        json: bool,
    },
    RestoreAccountListBackup {
        #[arg(long)]
        json: bool,
    },
    RestoreFullBackup {
        #[arg(long)]
        json: bool,
    },
    CreateAutomaticFullBackup {
        #[arg(long)]
        json: bool,
    },
    AutoStartUsageWindows {
        #[arg(long, conflicts_with = "disable")]
        enable: bool,
        #[arg(long)]
        disable: bool,
        #[arg(long)]
        run: bool,
        #[arg(long)]
        json: bool,
    },
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
        #[arg(long)]
        json: bool,
    },
    RecoverLegacySnapshots {
        #[arg(long)]
        json: bool,
    },
    TokenUsage {
        #[arg(long)]
        json: bool,
    },
    /// Run the optional VibeCafe usage collector for Codex and other AI tools.
    VibeUsage {
        #[command(subcommand)]
        command: Option<VibeUsageCommand>,
    },
    ResetOutlook {
        #[arg(long)]
        json: bool,
    },
    /// Return newly verified global reset events once, for desktop notifications.
    ResetEvents {
        #[arg(long)]
        json: bool,
    },
    /// Return the full reset timeline from codex-reset.com.
    ResetTimeline {
        #[arg(long)]
        json: bool,
    },
    /// Return OpenAI status history from codex-reset.com (Codex-specific incidents).
    ResetStatusHistory {
        #[arg(long)]
        json: bool,
    },
    /// Return quota effort tiers ("juice") from codex-reset.com.
    ResetJuice {
        #[arg(long)]
        json: bool,
    },
    OpenAiStatus {
        #[arg(long)]
        json: bool,
    },
    SetLabel {
        account_id: Uuid,
        label: String,
        #[arg(long)]
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

#[derive(Subcommand)]
enum ProviderCommand {
    /// Show live availability, identity, capabilities, and saved-account counts.
    Status {
        #[arg(long)]
        json: bool,
    },
    /// List saved accounts, optionally scoped to one provider.
    List {
        #[arg(long, value_parser = parse_ai_provider)]
        provider: Option<AiProvider>,
        #[arg(long)]
        json: bool,
    },
    /// Save the provider's currently authenticated account.
    Save {
        #[arg(value_parser = parse_ai_provider)]
        provider: AiProvider,
        #[arg(long)]
        json: bool,
    },
    /// Activate a saved account. The provider is inferred from the account ID.
    Activate {
        account_id: Uuid,
        #[arg(long)]
        json: bool,
    },
    /// Fetch provider usage for the live account or a saved account ID.
    Usage {
        #[arg(value_parser = parse_ai_provider)]
        provider: AiProvider,
        account_id: Option<Uuid>,
        #[arg(long)]
        json: bool,
    },
}

pub fn run() -> Result<()> {
    let cli = Cli::parse();
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
        Some(Command::List { json }) => {
            let list = app.list()?;
            if json {
                print_json(&list)?;
            } else if list.accounts.is_empty() {
                println!("No saved accounts in {}.", list.environment);
            } else {
                for account in list.accounts {
                    println!("{}", render_account_summary(&account));
                }
            }
            Ok(())
        }
        Some(Command::Providers { command }) => {
            match command.unwrap_or(ProviderCommand::Status { json: false }) {
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
                        if output.requires_relaunch {
                            println!(
                                "Relaunch the provider app for the new session to take effect."
                            );
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
            let output = serde_json::json!({
                "active": app.add_account_session_active(),
                "auth_changed": app.add_account_session_auth_changed()?,
            });
            if json {
                print_json(&output)?;
            } else {
                println!("Add account session: {}", output["active"]);
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
                            bail!(
                                "Codex CLI is still running. Close those processes first; `--force` cannot override a live CLI session."
                            );
                        }
                        if !force {
                            bail!(
                                "ChatGPT/Codex Desktop is still running. Close it first or rerun `activate` with `--force` after quitting Desktop."
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
            }
            Ok(())
        }
        Some(Command::RestoreAccountListBackup { json }) => {
            let accounts = app.restore_latest_account_list_backup()?;
            if json {
                print_json(&serde_json::json!({ "accounts": accounts }))?;
            } else {
                println!("Restored account list with {accounts} accounts");
            }
            Ok(())
        }
        Some(Command::RestoreFullBackup { json }) => {
            let accounts = app.restore_latest_full_backup()?;
            if json {
                print_json(&serde_json::json!({ "accounts": accounts }))?;
            } else {
                println!("Restored full backup with {accounts} accounts");
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
                println!(
                    "Global reset outlook: {}% in 24h, {}% in 48h",
                    outlook.chance_24_hours, outlook.chance_48_hours
                );
                println!("Last reset: {}", outlook.last_reset_at);
            }
            Ok(())
        }
        Some(Command::ResetEvents { json }) => {
            let events = crate::reset_tracker::fetch_new_reset_events(&app.env().app_data_dir)?;
            if json {
                print_json(&events)?;
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

fn run_interactive_app<S>(app: &App<S>) -> Result<()>
where
    S: crate::secrets::SecretStore,
{
    crate::app::spawn_auto_start_usage_windows_worker(app.env().clone());
    crate::app::spawn_auto_switch_worker(app.env().clone());
    crate::app::spawn_usage_refresh_worker(app.env().clone());
    crate::app::spawn_vibe_usage_worker(app.env().clone());
    match app.interactive(InteractiveMode::Persistent, false)? {
        InteractiveExit::Quit => Ok(()),
    }
}

fn print_json<T>(value: &T) -> Result<()>
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
    let mut line = format!(
        "{} {}{}",
        account.id,
        account.email,
        if account.is_active { " [active]" } else { "" }
    );
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
                    line.push_str(&format!(
                        " [{label} remaining: {}%, reset {}]",
                        window.remaining_percent,
                        window.reset_at.date()
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
            line.push_str(&format!(" [{} remaining: {remaining}%]", window.label));
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
    let mut args = vec!["--yes".to_owned(), "@vibe-cafe/vibe-usage".to_owned()];
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
            five_hour.remaining_percent, five_hour.reset_at
        );
    }
    if let Some(weekly) = &usage.weekly {
        println!(
            "Weekly remaining: {}% (reset {})",
            weekly.remaining_percent, weekly.reset_at
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
