use std::io::Read;
use std::path::PathBuf;

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
    ResetOutlook {
        #[arg(long)]
        json: bool,
    },
    /// Return newly verified global reset events once, for desktop notifications.
    ResetEvents {
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
    #[cfg(windows)]
    /// Run the lightweight notification-area companion.
    Tray,
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
        #[cfg(windows)]
        Some(Command::Tray) => {
            crate::app::spawn_auto_start_usage_windows_worker(app.env().clone());
            crate::app::spawn_auto_switch_worker(app.env().clone());
            crate::app::spawn_usage_refresh_worker(app.env().clone());
            crate::tray::hide_console_window();
            let _ = crate::tray::run(&app)?;
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
    #[cfg(windows)]
    if crate::windows_shell::launch_if_bundled() {
        return Ok(());
    }

    crate::app::spawn_auto_start_usage_windows_worker(app.env().clone());
    crate::app::spawn_auto_switch_worker(app.env().clone());
    crate::app::spawn_usage_refresh_worker(app.env().clone());
    #[cfg(windows)]
    {
        loop {
            match app.interactive(InteractiveMode::Persistent, false)? {
                InteractiveExit::Quit => return Ok(()),
                InteractiveExit::SendToTray => {
                    crate::tray::hide_console_window();
                    match crate::tray::run(app)? {
                        crate::tray::TrayExit::ShowTui => crate::tray::show_console_window(),
                        crate::tray::TrayExit::Quit => return Ok(()),
                    }
                }
            }
        }
    }
    #[cfg(not(windows))]
    {
        match app.interactive(InteractiveMode::Persistent, false)? {
            InteractiveExit::Quit => Ok(()),
        }
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
    } else if let Some(usage) = &account.usage
        && let Some(weekly) = &usage.weekly
    {
        if weekly.reset_at <= OffsetDateTime::now_utc() {
            line.push_str(" [weekly reset passed]");
        } else {
            line.push_str(&format!(
                " [weekly remaining: {}%, reset {}]",
                weekly.remaining_percent,
                weekly.reset_at.date()
            ));
        }
    } else if let Some(error) = &account.usage_error {
        line.push_str(&format!(" [{}]", usage_error_label(error).to_lowercase()));
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
    println!("Today: {}", output.today);
    println!("Last 7 days: {}", output.last_7_days);
    println!("Last 30 days: {}", output.last_30_days);
    println!("Last 365 days: {}", output.last_365_days);
    println!("All time: {}", output.all_time);
    println!(
        "Scanned {} sessions / {} token events",
        output.sessions_scanned, output.token_events
    );
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
}
