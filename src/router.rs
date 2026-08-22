use std::env;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

use anyhow::{Context, Result, bail};
use serde::Serialize;

pub const REPOSITORY_URL: &str = "https://github.com/duolahypercho/codex-router";

#[derive(Debug, Clone, Serialize)]
pub struct RouterStatusOutput {
    pub installed: bool,
    pub healthy: bool,
    pub configured: bool,
    pub state: &'static str,
    pub version: Option<String>,
    pub installation: Option<&'static str>,
    pub detail: Option<String>,
    pub repository_url: &'static str,
}

impl RouterStatusOutput {
    pub fn state_label(&self) -> &'static str {
        match self.state {
            "ready" => "ready",
            "offline" => "installed, service unavailable",
            _ => "not installed",
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct RouterActionOutput {
    pub ok: bool,
    pub action: &'static str,
    pub message: String,
}

#[derive(Debug, Clone)]
struct RouterInstallation {
    executable: PathBuf,
    source: &'static str,
}

pub fn status() -> RouterStatusOutput {
    let Some(installation) = find_installation() else {
        return RouterStatusOutput {
            installed: false,
            healthy: false,
            configured: false,
            state: "not_installed",
            version: None,
            installation: None,
            detail: Some(
                "Install Codex Router separately, then return here to manage it from Roster."
                    .to_owned(),
            ),
            repository_url: REPOSITORY_URL,
        };
    };

    let version = run_router(&installation.executable, ["--version"])
        .ok()
        .filter(Output::status_success)
        .and_then(|output| first_line(&output.stdout));
    let healthy = run_router(&installation.executable, ["status"])
        .is_ok_and(|output| output.status.success());

    RouterStatusOutput {
        installed: true,
        healthy,
        configured: router_state_dir().join("enabled-providers.json").is_file(),
        state: if healthy { "ready" } else { "offline" },
        version,
        installation: Some(installation.source),
        detail: Some(if healthy {
            "The local Router service and Codex integration are responding."
        } else {
            "Codex Router is installed, but its local service is not ready. Run Doctor before changing providers."
        }
        .to_owned()),
        repository_url: REPOSITORY_URL,
    }
}

pub fn open_control_center() -> Result<RouterActionOutput> {
    let installation = require_installation()?;
    let output = run_router(&installation.executable, ["panel"])
        .context("failed to open the Codex Router Control Center")?;
    if !output.status.success() {
        bail!("Codex Router could not open its Control Center. Run Router Doctor first.");
    }
    Ok(RouterActionOutput {
        ok: true,
        action: "open",
        message: "Opened the Codex Router Control Center.".to_owned(),
    })
}

pub fn doctor() -> Result<RouterActionOutput> {
    let installation = require_installation()?;
    let output = run_router(&installation.executable, ["doctor"])
        .context("failed to run Codex Router Doctor")?;
    Ok(RouterActionOutput {
        ok: output.status.success(),
        action: "doctor",
        message: if output.status.success() {
            "Codex Router Doctor completed without blocking issues."
        } else {
            "Codex Router Doctor found an issue. Open its Control Center or run `codex-router doctor --fix` in Terminal."
        }
        .to_owned(),
    })
}

fn require_installation() -> Result<RouterInstallation> {
    find_installation().context(
        "Codex Router is not installed. Install it from https://github.com/duolahypercho/codex-router first.",
    )
}

fn find_installation() -> Option<RouterInstallation> {
    for variable in ["CODEX_ROSTER_CODEX_ROUTER_PATH", "CODEX_ROUTER_BIN"] {
        if let Some(path) = env::var_os(variable).map(PathBuf::from)
            && is_runnable(&path)
        {
            return Some(RouterInstallation {
                executable: path,
                source: "environment",
            });
        }
    }

    for name in router_command_names() {
        if let Some(path) = find_on_path(name) {
            return Some(RouterInstallation {
                executable: path,
                source: "path",
            });
        }
    }

    for path in standard_install_paths() {
        if is_runnable(&path) {
            let source = if path.to_string_lossy().contains(".local/share") {
                "managed_checkout"
            } else if path.to_string_lossy().contains("homebrew")
                || path.to_string_lossy().contains("/usr/local/")
            {
                "homebrew"
            } else {
                "standard_location"
            };
            return Some(RouterInstallation {
                executable: path,
                source,
            });
        }
    }
    None
}

fn router_command_names() -> &'static [&'static str] {
    #[cfg(windows)]
    {
        &["codex-router.exe", "codex-router.cmd", "codex-router.ps1"]
    }
    #[cfg(not(windows))]
    {
        &["codex-router"]
    }
}

fn standard_install_paths() -> Vec<PathBuf> {
    let mut paths = Vec::new();
    if let Some(home) = env::var_os("HOME").map(PathBuf::from) {
        paths.push(
            home.join(".local")
                .join("share")
                .join("codex-router")
                .join("bin")
                .join("codex-router"),
        );
    }
    #[cfg(target_os = "macos")]
    {
        paths.push(PathBuf::from("/opt/homebrew/bin/codex-router"));
        paths.push(PathBuf::from("/usr/local/bin/codex-router"));
    }
    #[cfg(windows)]
    if let Some(local_app_data) = env::var_os("LOCALAPPDATA").map(PathBuf::from) {
        paths.push(local_app_data.join("codex-router").join("codex-router.ps1"));
    }
    paths
}

fn router_state_dir() -> PathBuf {
    if let Some(path) = env::var_os("MODEL_ROUTER_STATE_DIR").map(PathBuf::from) {
        return path;
    }
    if let Some(path) = env::var_os("CODEX_ROUTER_STATE_DIR").map(PathBuf::from) {
        return path;
    }
    let codex_home = env::var_os("CODEX_HOME")
        .map(PathBuf::from)
        .or_else(|| env::var_os("HOME").map(|home| PathBuf::from(home).join(".codex")))
        .unwrap_or_else(|| PathBuf::from(".codex"));
    codex_home.join("codex-router")
}

fn find_on_path(name: &str) -> Option<PathBuf> {
    env::var_os("PATH")?
        .to_string_lossy()
        .split(if cfg!(windows) { ';' } else { ':' })
        .filter(|segment| !segment.is_empty())
        .map(|segment| Path::new(segment).join(name))
        .find(|path| is_runnable(path))
}

fn is_runnable(path: &Path) -> bool {
    path.is_file()
}

fn run_router<const N: usize>(path: &Path, arguments: [&str; N]) -> Result<Output> {
    #[cfg(windows)]
    let mut command = if path.extension().is_some_and(|extension| extension == "ps1") {
        let mut command = Command::new("powershell.exe");
        command.args(["-NoProfile", "-ExecutionPolicy", "Bypass", "-File"]);
        command.arg(path);
        command
    } else {
        Command::new(path)
    };
    #[cfg(not(windows))]
    let mut command = Command::new(path);

    command.args(arguments).env("MODEL_ROUTER_TARGET", "codex");
    command
        .output()
        .with_context(|| format!("failed to run {}", path.display()))
}

fn first_line(bytes: &[u8]) -> Option<String> {
    String::from_utf8_lossy(bytes)
        .lines()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .map(ToOwned::to_owned)
}

trait OutputStatus {
    fn status_success(&self) -> bool;
}

impl OutputStatus for Output {
    fn status_success(&self) -> bool {
        self.status.success()
    }
}

#[cfg(test)]
mod tests {
    use super::first_line;

    #[test]
    fn first_line_skips_leading_whitespace() {
        assert_eq!(first_line(b"\n  1.2.3  \nother"), Some("1.2.3".to_owned()));
    }
}
