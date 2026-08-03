use std::path::PathBuf;
use std::process::Command;
use std::thread;
use std::time::Duration;

use sysinfo::{ProcessRefreshKind, ProcessesToUpdate, System, UpdateKind};

const SHELL_FILE_NAME: &str = "CodexRoster.Windows.exe";

/// Starts the bundled desktop shell when this executable is launched without a
/// CLI subcommand. A standalone CLI install intentionally falls back to the
/// TUI, so scripting and terminal-only workflows remain available.
pub(crate) fn launch_if_bundled() -> bool {
    let Some(shell) = shell_path() else {
        return false;
    };

    Command::new(shell).spawn().is_ok()
}

/// Closes ChatGPT / Codex Desktop processes before a tray-driven account swap.
/// Bare Codex CLI processes are left alone so in-flight terminal work is kept.
/// Returns executable paths that should be relaunched after the swap.
pub(crate) fn close_desktop_for_switch() -> Vec<PathBuf> {
    let mut system = System::new();
    system.refresh_processes_specifics(
        ProcessesToUpdate::All,
        true,
        ProcessRefreshKind::nothing()
            .with_exe(UpdateKind::Always)
            .without_tasks(),
    );
    let current_pid = std::process::id();
    let mut relaunch = Vec::new();
    for (pid, process) in system.processes() {
        if pid.as_u32() == current_pid {
            continue;
        }
        let name = process.name().to_string_lossy().to_ascii_lowercase();
        let path = process
            .exe()
            .map(|exe| exe.to_path_buf())
            .unwrap_or_default();
        let path_lower = path.to_string_lossy().to_ascii_lowercase();
        let is_chatgpt = name == "chatgpt.exe" || name == "chatgpt";
        let is_desktop_codex = (name == "codex.exe" || name == "codex")
            && (path_lower.contains("chatgpt")
                || path_lower.contains("openai")
                || path_lower.contains("\\codex\\")
                || (path_lower.ends_with("codex.exe") && path_lower.contains("\\programs\\")));
        if is_chatgpt || is_desktop_codex {
            if path.is_file() && !relaunch.iter().any(|existing: &PathBuf| existing == &path) {
                relaunch.push(path.clone());
            }
            process.kill();
        }
    }
    thread::sleep(Duration::from_millis(750));
    relaunch
}

pub(crate) fn relaunch_desktop(executables: &[PathBuf]) {
    for executable in executables {
        let _ = Command::new(executable).spawn();
    }
}

fn shell_path() -> Option<PathBuf> {
    if let Some(path) = std::env::var_os("CODEX_ROSTER_GUI_PATH") {
        let path = PathBuf::from(path);
        if path.is_file() {
            return Some(path);
        }
    }

    let executable = std::env::current_exe().ok()?;
    let bundled = executable.parent()?.join(SHELL_FILE_NAME);
    bundled.is_file().then_some(bundled)
}

#[cfg(test)]
mod tests {
    use super::{SHELL_FILE_NAME, close_desktop_for_switch, relaunch_desktop};

    #[test]
    fn desktop_shell_has_a_stable_bundle_name() {
        assert_eq!(SHELL_FILE_NAME, "CodexRoster.Windows.exe");
    }

    #[test]
    fn close_desktop_for_switch_is_available_on_windows_builds() {
        // Compile-only coverage: the helper must remain callable from tray activate.
        let _ = close_desktop_for_switch as fn() -> Vec<std::path::PathBuf>;
        let _ = relaunch_desktop as fn(&[std::path::PathBuf]);
    }
}
