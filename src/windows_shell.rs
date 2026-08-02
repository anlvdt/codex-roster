use std::path::PathBuf;
use std::process::Command;

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
    use super::SHELL_FILE_NAME;

    #[test]
    fn desktop_shell_has_a_stable_bundle_name() {
        assert_eq!(SHELL_FILE_NAME, "CodexRoster.Windows.exe");
    }
}
