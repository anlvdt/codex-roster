use sysinfo::{Pid, ProcessRefreshKind, ProcessesToUpdate, System, UpdateKind};

use crate::model::RunningCodexProcess;

const SUMMARY_LIMIT: usize = 72;
const EXECUTABLE_WIDTH: usize = 12;
const ROLE_WIDTH: usize = 14;
pub fn detect_running_codex_processes() -> Vec<RunningCodexProcess> {
    let mut system = System::new();
    system.refresh_processes_specifics(
        ProcessesToUpdate::All,
        true,
        ProcessRefreshKind::nothing()
            .with_cmd(UpdateKind::Always)
            .with_exe(UpdateKind::Always)
            .without_tasks(),
    );
    let current_pid = std::process::id();
    let mut processes = system
        .processes()
        .iter()
        .filter_map(|(pid, process)| {
            let pid_u32 = pid.as_u32();
            if pid_u32 == current_pid || is_ancestor_of(&system, current_pid, pid_u32) {
                return None;
            }
            let name = process.name().to_string_lossy().to_ascii_lowercase();
            let command = process
                .cmd()
                .iter()
                .map(|item| item.to_string_lossy().into_owned())
                .collect::<Vec<_>>();
            if matches_codex_process(&name, &command) {
                Some(format_process(*pid, &name, &command))
            } else {
                None
            }
        })
        .collect::<Vec<_>>();
    processes.sort_by(|left, right| {
        left.executable
            .cmp(&right.executable)
            .then_with(|| left.role.cmp(&right.role))
            .then_with(|| left.pid.cmp(&right.pid))
    });
    processes
}

/// ChatGPT / Codex Desktop owns `~/.codex/auth.json` refresh while running.
/// Roster must not rotate the same refresh token or Desktop will force a logout.
pub fn codex_desktop_likely_running() -> bool {
    detect_running_codex_processes()
        .iter()
        .any(is_desktop_like_process)
}

/// Processes that must stop before auth files are replaced.
///
/// `allow_desktop` is `--force` / GUI-after-quit: leftover ChatGPT/Codex.app
/// helpers are ignored. A live `codex` CLI session still blocks — forcing
/// through it can invalidate a single-use refresh token.
pub fn processes_blocking_activation(allow_desktop: bool) -> Vec<RunningCodexProcess> {
    detect_running_codex_processes()
        .into_iter()
        .filter(|process| !(allow_desktop && is_force_skippable_process(process)))
        .collect()
}

pub fn is_force_skippable_process(process: &RunningCodexProcess) -> bool {
    matches!(process.origin.as_deref(), Some("desktop") | Some("plugin"))
        || is_desktop_like_process(process)
        || is_desktop_main_process(process)
}

fn is_desktop_like_process(process: &RunningCodexProcess) -> bool {
    let exe = process.executable.to_ascii_lowercase();
    if is_roster_name(&exe) {
        return false;
    }
    if exe.contains("chatgpt") {
        return true;
    }
    if exe.starts_with("codex helper") {
        return true;
    }
    is_codex_bin_name(&exe)
        && matches!(
            process.role.as_str(),
            "renderer" | "gpu-process" | "utility" | "zygote" | "gpu" | "broker"
        )
}

fn is_desktop_main_process(process: &RunningCodexProcess) -> bool {
    let exe = process.executable.to_ascii_lowercase();
    is_codex_bin_name(&exe) && matches!(process.role.as_str(), "process" | "main")
}

pub fn format_process_table(processes: &[RunningCodexProcess]) -> Vec<String> {
    let mut lines = Vec::with_capacity(processes.len() + 1);
    lines.push(format!(
        "{:<6} {:<exe_width$} {:<role_width$} {}",
        "PID",
        "Exe",
        "Role",
        "Summary",
        exe_width = EXECUTABLE_WIDTH,
        role_width = ROLE_WIDTH
    ));
    for process in processes {
        lines.push(format!(
            "{:<6} {:<exe_width$} {:<role_width$} {}",
            process.pid,
            truncate_cell(&process.executable, EXECUTABLE_WIDTH),
            truncate_cell(&process.role, ROLE_WIDTH),
            process.summary.as_deref().unwrap_or("-"),
            exe_width = EXECUTABLE_WIDTH,
            role_width = ROLE_WIDTH
        ));
    }
    lines
}

fn matches_codex_process(name: &str, command: &[String]) -> bool {
    if is_roster_process(name, command) {
        return false;
    }
    if is_chatgpt_name(name) || is_codex_bin_name(name) {
        return true;
    }
    command
        .iter()
        .filter_map(|token| path_file_name(token))
        .map(|token| token.to_ascii_lowercase())
        .any(|token| {
            !is_roster_name(&token)
                && matches!(
                    token.as_str(),
                    "codex" | "codex.exe" | "codex.js" | "chatgpt" | "chatgpt.exe"
                )
        })
}

fn is_roster_process(name: &str, command: &[String]) -> bool {
    if is_roster_name(name) {
        return true;
    }
    command.iter().any(|token| {
        let token = token.to_ascii_lowercase();
        token.contains("codex roster.app")
            || token.contains("codex-roster")
            || token.contains("codexroster")
    })
}

fn is_roster_name(name: &str) -> bool {
    let name = name.to_ascii_lowercase();
    name.contains("codex-roster") || name.contains("codexroster") || name.contains("codex roster")
}

fn is_chatgpt_name(name: &str) -> bool {
    let name = name.to_ascii_lowercase();
    name == "chatgpt" || name == "chatgpt.exe" || name.starts_with("chatgpt")
}

fn is_codex_bin_name(name: &str) -> bool {
    let name = name.to_ascii_lowercase();
    if is_roster_name(&name) {
        return false;
    }
    name == "codex" || name == "codex.exe" || name.starts_with("codex helper")
}

fn is_ancestor_of(system: &System, descendant: u32, ancestor: u32) -> bool {
    if descendant == ancestor {
        return true;
    }
    let mut walk = descendant;
    for _ in 0..32 {
        let Some(process) = system.process(Pid::from_u32(walk)) else {
            return false;
        };
        let Some(parent) = process.parent() else {
            return false;
        };
        let parent = parent.as_u32();
        if parent == 0 || parent == walk {
            return false;
        }
        if parent == ancestor {
            return true;
        }
        walk = parent;
    }
    false
}

fn format_process(pid: Pid, name: &str, command: &[String]) -> RunningCodexProcess {
    let (role, summary) = classify_process(command);
    let origin = if is_desktop_owned_command(name, command, &role) {
        Some("desktop".to_owned())
    } else {
        Some("cli".to_owned())
    };
    RunningCodexProcess {
        pid: pid.as_u32(),
        executable: name.to_owned(),
        role,
        summary,
        origin,
    }
}

fn is_desktop_owned_command(name: &str, command: &[String], role: &str) -> bool {
    if is_chatgpt_name(name) || name.starts_with("codex helper") {
        return true;
    }
    let blob = command
        .iter()
        .map(|token| token.to_ascii_lowercase())
        .collect::<Vec<_>>()
        .join("\n");
    if blob.contains("chatgpt.app")
        || blob.contains("codex.app/")
        || blob.contains("codex.app\\")
        || blob.contains("codex framework.framework")
        || blob.contains(".codex/plugins/")
        || blob.contains(".codex\\plugins\\")
        || blob.contains(".plugin-appserver")
        || blob.contains("openai-bundled/chrome")
    {
        return true;
    }
    is_codex_bin_name(name)
        && matches!(
            role,
            "renderer"
                | "gpu-process"
                | "utility"
                | "zygote"
                | "gpu"
                | "broker"
                | "process"
                | "main"
        )
}

fn classify_process(command: &[String]) -> (String, Option<String>) {
    if command.is_empty() {
        return ("process".to_owned(), None);
    }

    if let Some(wrapper) = classify_wrapped_codex_command(command) {
        return wrapper;
    }

    if let Some(role) = detect_flag_value(command, "--utility-sub-type=") {
        return ("utility".to_owned(), Some(truncate_summary(&role)));
    }
    if let Some(role) = detect_flag_value(command, "--type=") {
        return (role, summarize_args(command));
    }

    let mut positional = command
        .iter()
        .skip(1)
        .filter(|token| !token.is_empty())
        .peekable();
    if let Some(token) = positional.next()
        && !token.starts_with('-')
    {
        return (
            token.to_ascii_lowercase(),
            summarize_tokens(positional.cloned()),
        );
    }

    (
        "process".to_owned(),
        summarize_tokens(
            command
                .iter()
                .skip(1)
                .filter(|token| !token.starts_with('-'))
                .cloned(),
        ),
    )
}

fn classify_wrapped_codex_command(command: &[String]) -> Option<(String, Option<String>)> {
    let script = command.get(1)?;
    let script_name = path_file_name(script)?.to_ascii_lowercase();
    if script_name != "codex.js" {
        return None;
    }
    let mut positional = command
        .iter()
        .skip(2)
        .filter(|token| !token.is_empty())
        .peekable();
    let token = positional.next()?;
    if token.starts_with('-') {
        return Some(("process".to_owned(), summarize_tokens(positional.cloned())));
    }
    Some((
        token.to_ascii_lowercase(),
        summarize_tokens(positional.cloned()),
    ))
}

fn detect_flag_value(command: &[String], prefix: &str) -> Option<String> {
    command
        .iter()
        .find_map(|token| token.strip_prefix(prefix))
        .map(|value| value.to_ascii_lowercase())
}

fn summarize_args(command: &[String]) -> Option<String> {
    summarize_tokens(
        command
            .iter()
            .skip(1)
            .filter(|token| {
                !token.starts_with("--type=") && !token.starts_with("--utility-sub-type=")
            })
            .filter(|token| !token.starts_with("--user-data-dir="))
            .filter(|token| !token.starts_with("--field-trial-handle="))
            .filter(|token| !token.starts_with("--trace-process-track-uuid="))
            .filter(|token| !token.starts_with("--variations-seed-version"))
            .filter(|token| !token.starts_with("--mojo-platform-channel-handle="))
            .cloned(),
    )
}

fn summarize_tokens(tokens: impl Iterator<Item = String>) -> Option<String> {
    let filtered = tokens
        .filter_map(|token| clean_token(&token))
        .collect::<Vec<_>>();
    if filtered.is_empty() {
        None
    } else {
        Some(truncate_summary(&filtered.join(" ")))
    }
}

fn clean_token(token: &str) -> Option<String> {
    let trimmed = token.trim();
    if trimmed.is_empty() {
        return None;
    }
    if trimmed.starts_with("--") {
        return flag_value_preview(trimmed);
    }
    if trimmed.starts_with("/prefetch:") {
        return None;
    }
    let value = path_file_name(trimmed).unwrap_or(trimmed).to_owned();
    if value.is_empty() { None } else { Some(value) }
}

fn path_file_name(value: &str) -> Option<&str> {
    value
        .trim_end_matches(['/', '\\'])
        .rsplit(['/', '\\'])
        .find(|segment| !segment.is_empty())
}

fn flag_value_preview(token: &str) -> Option<String> {
    let (key, value) = token.split_once('=')?;
    match key {
        "--app-path" | "--title" | "--base" => clean_token(value),
        _ => None,
    }
}

fn truncate_summary(value: &str) -> String {
    let mut chars = value.chars();
    let preview = chars.by_ref().take(SUMMARY_LIMIT).collect::<String>();
    if chars.next().is_some() {
        format!("{preview}...")
    } else {
        preview
    }
}

fn truncate_cell(value: &str, width: usize) -> String {
    let mut chars = value.chars();
    let preview = chars.by_ref().take(width).collect::<String>();
    if chars.next().is_some() && width > 1 {
        format!("{}...", preview.chars().take(width - 3).collect::<String>())
    } else {
        preview
    }
}

#[cfg(test)]
mod tests {
    use super::{
        classify_process, clean_token, detect_flag_value, format_process_table,
        is_desktop_like_process, is_desktop_owned_command, is_force_skippable_process,
        matches_codex_process, truncate_summary,
    };
    use crate::model::RunningCodexProcess;

    #[test]
    fn matches_codex_process_ignores_roster_binaries() {
        assert!(!matches_codex_process("codexroster", &[]));
        assert!(!matches_codex_process(
            "codex-roster",
            &[
                "/Applications/Codex Roster.app/Contents/MacOS/codex-roster".to_owned(),
                "activate".to_owned(),
            ]
        ));
        assert!(!matches_codex_process(
            "nextaccount",
            &["/Applications/Codex Roster.app/Contents/MacOS/CodexRoster".to_owned()]
        ));
    }

    #[test]
    fn plugin_appserver_is_desktop_owned() {
        assert!(is_desktop_owned_command(
            "codex",
            &[
                "/Users/x/.codex/plugins/.plugin-appserver/codex".to_owned(),
                "app-server".to_owned(),
            ],
            "app-server",
        ));
        assert!(!is_desktop_owned_command(
            "codex",
            &[
                "/opt/homebrew/bin/codex".to_owned(),
                "app-server".to_owned(),
            ],
            "app-server",
        ));
    }

    #[test]
    fn matches_codex_process_detects_chatgpt_helpers() {
        assert!(matches_codex_process("chatgpt helper (gpu)", &[]));
        assert!(matches_codex_process("chatgpt", &[]));
    }

    #[test]
    fn force_skips_desktop_leftovers_but_not_cli() {
        assert!(is_force_skippable_process(&RunningCodexProcess {
            pid: 1,
            executable: "chatgpt".to_owned(),
            role: "process".to_owned(),
            summary: None,
            origin: Some("desktop".to_owned()),
        }));
        assert!(is_force_skippable_process(&RunningCodexProcess {
            pid: 2,
            executable: "codex".to_owned(),
            role: "renderer".to_owned(),
            summary: Some("app.asar".to_owned()),
            origin: Some("desktop".to_owned()),
        }));
        assert!(is_force_skippable_process(&RunningCodexProcess {
            pid: 3,
            executable: "codex".to_owned(),
            role: "process".to_owned(),
            summary: None,
            origin: Some("desktop".to_owned()),
        }));
        assert!(!is_force_skippable_process(&RunningCodexProcess {
            pid: 4,
            executable: "codex".to_owned(),
            role: "app-server".to_owned(),
            summary: None,
            origin: Some("cli".to_owned()),
        }));
        assert!(is_force_skippable_process(&RunningCodexProcess {
            pid: 5,
            executable: "codex".to_owned(),
            role: "app-server".to_owned(),
            summary: None,
            origin: Some("desktop".to_owned()),
        }));
    }

    #[test]
    fn matches_codex_process_detects_wrapped_cli() {
        assert!(matches_codex_process(
            "node.exe",
            &[
                "node".to_owned(),
                "C:\\Users\\tester\\AppData\\Roaming\\npm\\node_modules\\@openai\\codex\\bin\\codex.js"
                    .to_owned(),
                "review".to_owned()
            ]
        ));
    }

    #[test]
    fn desktop_like_process_detects_chatgpt_and_electron_helpers() {
        assert!(is_desktop_like_process(&RunningCodexProcess {
            pid: 1,
            executable: "chatgpt.exe".to_owned(),
            role: "process".to_owned(),
            summary: None,
            origin: None,
        }));
        assert!(is_desktop_like_process(&RunningCodexProcess {
            pid: 2,
            executable: "codex.exe".to_owned(),
            role: "renderer".to_owned(),
            summary: Some("app.asar".to_owned()),
            origin: None,
        }));
        assert!(!is_desktop_like_process(&RunningCodexProcess {
            pid: 3,
            executable: "codex.exe".to_owned(),
            role: "login".to_owned(),
            summary: Some("--device-auth".to_owned()),
            origin: None,
        }));
    }

    #[test]
    fn classify_process_prefers_known_process_type() {
        let (role, summary) = classify_process(&[
            "codex.exe".to_owned(),
            "--type=renderer".to_owned(),
            "--lang=en-gb".to_owned(),
            "--user-data-dir=C:\\Users\\tester\\AppData\\Roaming\\codex".to_owned(),
            "--app-path=C:\\Program Files\\Codex\\app.asar".to_owned(),
        ]);
        assert_eq!(role, "renderer");
        assert_eq!(summary.as_deref(), Some("app.asar"));
    }

    #[test]
    fn classify_process_uses_first_subcommand_for_cli_processes() {
        let (role, summary) = classify_process(&[
            "codex.exe".to_owned(),
            "review".to_owned(),
            "--title".to_owned(),
            "benchmark".to_owned(),
            "--base".to_owned(),
            "main".to_owned(),
        ]);
        assert_eq!(role, "review");
        assert_eq!(summary.as_deref(), Some("benchmark main"));
    }

    #[test]
    fn classify_process_uses_wrapped_codex_script_subcommand() {
        let (role, summary) = classify_process(&[
            "node.exe".to_owned(),
            "C:\\Users\\tester\\AppData\\Roaming\\npm\\node_modules\\@openai\\codex\\bin\\codex.js"
                .to_owned(),
            "resume".to_owned(),
            "jjagentskills".to_owned(),
        ]);
        assert_eq!(role, "resume");
        assert_eq!(summary.as_deref(), Some("jjagentskills"));
    }

    #[test]
    fn clean_token_compacts_paths_and_skips_flags() {
        assert_eq!(
            clean_token("C:\\Program Files\\Codex\\codex.exe").as_deref(),
            Some("codex.exe")
        );
        assert_eq!(clean_token("--lang=en-gb"), None);
        assert_eq!(clean_token("/prefetch:11"), None);
    }

    #[test]
    fn detect_flag_value_reads_inline_flags() {
        assert_eq!(
            detect_flag_value(
                &["codex.exe".to_owned(), "--type=gpu-process".to_owned()],
                "--type="
            )
            .as_deref(),
            Some("gpu-process")
        );
    }

    #[test]
    fn truncate_summary_adds_ellipsis_for_long_values() {
        let long = "x".repeat(90);
        assert!(truncate_summary(&long).ends_with("..."));
    }

    #[test]
    fn format_process_table_renders_compact_rows() {
        let lines = format_process_table(&[RunningCodexProcess {
            pid: 12,
            executable: "codex.exe".to_owned(),
            role: "renderer".to_owned(),
            summary: Some("app.asar".to_owned()),
            origin: None,
        }]);
        assert_eq!(lines[0], "PID    Exe          Role           Summary");
        assert!(lines[1].contains("12"));
        assert!(lines[1].contains("renderer"));
        assert!(lines[1].contains("app.asar"));
    }
}
