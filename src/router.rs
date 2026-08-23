use std::env;
#[cfg(target_os = "macos")]
use std::fs::{self, OpenOptions};
#[cfg(target_os = "macos")]
use std::io::Write;
#[cfg(target_os = "macos")]
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

pub const REPOSITORY_URL: &str = "https://github.com/duolahypercho/codex-router";
const INSTALLER_VERSION: &str = "v0.4.0-beta.4";
const INSTALLER_URL: &str =
    "https://raw.githubusercontent.com/duolahypercho/codex-router/v0.4.0-beta.4/install.sh";
const INSTALLER_SHA256: &str = "69bb3d07aab3f777ed52fc50663574e4f7a29741951c1c477a599a1a8567cf82";

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

#[derive(Debug, Clone, Serialize)]
pub struct RouterProviderOutput {
    pub id: String,
    pub name: String,
    pub visible: bool,
    pub configured: bool,
    pub connection_kind: &'static str,
    pub requires_explicit_consent: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct RouterProvidersOutput {
    pub providers: Vec<RouterProviderOutput>,
}

#[derive(Debug, Clone, Serialize)]
pub struct RouterProviderActionOutput {
    pub ok: bool,
    pub action: &'static str,
    pub provider_id: String,
    pub message: String,
    pub pending_user_action: bool,
}

#[derive(Debug, Deserialize)]
struct ExternalRouterProvidersOutput {
    providers: Vec<ExternalRouterProvider>,
}

#[derive(Debug, Deserialize)]
struct ExternalRouterProvider {
    id: String,
    name: String,
    visible: bool,
    configured: bool,
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
                "Use Roster's one-click installer, finish credential-safe setup in Terminal, then refresh Router status."
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

pub fn install() -> Result<RouterActionOutput> {
    #[cfg(not(target_os = "macos"))]
    bail!("One-click Codex Router installation is currently available only on macOS.");

    #[cfg(target_os = "macos")]
    {
        let initial = status();
        if initial.healthy && initial.configured {
            let installation = require_installation()?;
            let update = run_router_maintenance(&installation.executable, &["update"])
                .context("failed to run the automatic Codex Router update")?;
            let updated_status = status();
            if update.status.success() && updated_status.healthy && updated_status.configured {
                return Ok(RouterActionOutput {
                    ok: true,
                    action: "maintain",
                    message: "Codex Router is ready and up to date.".to_owned(),
                });
            }
        }

        let home = env::var_os("HOME")
            .map(PathBuf::from)
            .context("the home directory is unavailable; automatic Router setup cannot continue")?;
        let installer_dir = home
            .join("Library")
            .join("Caches")
            .join("Codex Roster")
            .join("router-installer")
            .join(INSTALLER_VERSION);
        fs::create_dir_all(&installer_dir)
            .context("failed to prepare the Codex Router installer cache")?;
        fs::set_permissions(&installer_dir, fs::Permissions::from_mode(0o700))
            .context("failed to secure the Codex Router installer cache")?;

        let mut response = ureq::get(INSTALLER_URL)
            .header("User-Agent", "codex-roster")
            .config()
            .timeout_global(Some(std::time::Duration::from_secs(20)))
            .build()
            .call()
            .context("failed to download the official Codex Router installer")?;
        if response.status().as_u16() >= 400 {
            bail!(
                "the official Codex Router installer returned HTTP {}",
                response.status()
            );
        }
        let installer = response
            .body_mut()
            .read_to_vec()
            .context("failed to read the official Codex Router installer")?;
        if installer.len() > 512 * 1024 {
            bail!("the Codex Router installer exceeded the expected size");
        }
        let digest = sha256_hex(&installer);
        if digest != INSTALLER_SHA256 {
            bail!(
                "the Codex Router installer did not match the verified {INSTALLER_VERSION} checksum"
            );
        }

        let installer_path = installer_dir.join("install.sh");
        write_executable(&installer_path, &installer)?;

        let prepare_result = run_installer_phase(
            &installer_path,
            "prepare Router dependencies",
            ["--target", "codex", "--prepare-only"],
        );
        let prepare_error = prepare_result.err();
        let installation = find_installation().ok_or_else(|| {
            prepare_error.unwrap_or_else(|| {
                anyhow::anyhow!("the Router installer did not create a runnable checkout")
            })
        })?;
        bootstrap_node_dependencies(&installation)?;
        if initial.configured && !provider_selection_is_empty() {
            let repair = run_router_maintenance(&installation.executable, &["doctor", "--fix"])
                .context("failed to repair the Codex Router service")?;
            if !repair.status.success() {
                bail!("Codex Router could not repair its local service automatically");
            }
        } else {
            configure_native_mode(&installation)?;
        }

        let final_status = status();
        if !final_status.healthy {
            let installation = require_installation()?;
            let repair = run_router_maintenance(&installation.executable, &["doctor", "--fix"])
                .context("failed to run the final Codex Router repair")?;
            if !repair.status.success() || !status().healthy {
                bail!("Codex Router was installed but its local service is not healthy yet");
            }
        }
        Ok(RouterActionOutput {
            ok: true,
            action: "install",
            message: format!("Codex Router {INSTALLER_VERSION} is ready in automatic native mode."),
        })
    }
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

pub fn providers() -> Result<RouterProvidersOutput> {
    let installation = require_installation()?;
    let output = run_router_dynamic(&installation.executable, &["providers", "list", "--json"])
        .context("failed to read Codex Router providers")?;
    if !output.status.success() {
        bail!(
            "Codex Router could not read its provider registry: {}",
            output_detail(&output)
        );
    }
    let external: ExternalRouterProvidersOutput = serde_json::from_slice(&output.stdout)
        .context("Codex Router returned an invalid provider registry")?;
    Ok(RouterProvidersOutput {
        providers: external
            .providers
            .into_iter()
            .map(|provider| RouterProviderOutput {
                connection_kind: provider_connection_kind(&provider.id),
                requires_explicit_consent: provider_requires_explicit_consent(&provider.id),
                id: provider.id,
                name: provider.name,
                visible: provider.visible,
                configured: provider.configured,
            })
            .collect(),
    })
}

pub fn connect_provider(
    provider_id: &str,
    allow_anonymous: bool,
) -> Result<RouterProviderActionOutput> {
    let installation = require_installation()?;
    let catalog = providers()?;
    let provider = catalog
        .providers
        .iter()
        .find(|provider| provider.id == provider_id)
        .with_context(|| format!("unknown Codex Router provider: {provider_id}"))?;
    if provider.requires_explicit_consent && !allow_anonymous {
        bail!(
            "{} is a remote anonymous provider. Explicit consent is required before prompts can be sent to it.",
            provider.name
        );
    }
    if provider.visible {
        return Ok(RouterProviderActionOutput {
            ok: true,
            action: "connect_provider",
            provider_id: provider.id.clone(),
            message: format!("{} is already available in Codex.", provider.name),
            pending_user_action: false,
        });
    }
    if provider.configured {
        let output = run_router_dynamic(
            &installation.executable,
            &["providers", "enable", provider.id.as_str()],
        )
        .context("failed to enable the Codex Router provider")?;
        if !output.status.success() {
            bail!(
                "Codex Router could not enable {}: {}",
                provider.name,
                output_detail(&output)
            );
        }
        // `mut` is only taken on macOS, where the consent fallback below flips it
        // after opening the Terminal curator; other targets read it unchanged.
        #[cfg_attr(not(target_os = "macos"), allow(unused_mut))]
        let mut needs_interactive_curation = !provider.requires_explicit_consent
            && String::from_utf8_lossy(&output.stdout).contains("curate-models");
        #[cfg(target_os = "macos")]
        if needs_interactive_curation {
            launch_model_curation(&installation.executable, provider.id.as_str())?;
        }
        let catalog_note = if provider.requires_explicit_consent {
            let curated = run_router_dynamic(
                &installation.executable,
                &[
                    "curate-models",
                    provider.id.as_str(),
                    "--free-only",
                    "--apply",
                ],
            )
            .context("failed to refresh the provider's free model catalog")?;
            if curated.status.success() {
                " Its current free model catalog was synchronized."
            } else {
                // Anonymous providers such as kilo-free/opencode-free do not
                // publish a machine-readable free-model catalog, so `--free-only`
                // adds nothing and Codex never sees their models. Their free
                // models are only enumerable through the interactive curator, so
                // fall back to the secure Terminal picker instead of silently
                // leaving the catalog empty.
                #[cfg(target_os = "macos")]
                {
                    launch_model_curation(&installation.executable, provider.id.as_str())?;
                    needs_interactive_curation = true;
                    " Its secure model picker opened in Terminal so you can choose which models reach Codex."
                }
                #[cfg(not(target_os = "macos"))]
                {
                    " The provider is enabled; run `codex-router curate-models <id> --apply` in Terminal to choose which models reach Codex."
                }
            }
        } else {
            #[cfg(target_os = "macos")]
            if needs_interactive_curation {
                " Its secure model picker opened in Terminal."
            } else {
                ""
            }
            #[cfg(not(target_os = "macos"))]
            if needs_interactive_curation {
                " Open Router's model curator to choose models for this catalog-only provider."
            } else {
                ""
            }
        };
        return Ok(RouterProviderActionOutput {
            ok: true,
            action: "connect_provider",
            provider_id: provider.id.clone(),
            message: format!(
                "{} is now available alongside native GPT models.{catalog_note}",
                provider.name
            ),
            pending_user_action: needs_interactive_curation,
        });
    }

    #[cfg(not(target_os = "macos"))]
    bail!("Secure guided provider setup from Roster is currently available only on macOS.");

    #[cfg(target_os = "macos")]
    {
        let mut selection = catalog
            .providers
            .iter()
            .filter(|candidate| candidate.visible)
            .map(|candidate| candidate.id.as_str())
            .collect::<Vec<_>>();
        selection.push(provider.id.as_str());
        selection.sort_unstable();
        selection.dedup();
        launch_provider_setup(
            &installation.executable,
            provider.id.as_str(),
            &selection.join(","),
        )?;
        Ok(RouterProviderActionOutput {
            ok: true,
            action: "connect_provider",
            provider_id: provider.id.clone(),
            message: format!(
                "Secure setup for {} opened in Terminal. Roster will detect it automatically when complete.",
                provider.name
            ),
            pending_user_action: true,
        })
    }
}

pub fn disable_provider(provider_id: &str) -> Result<RouterProviderActionOutput> {
    let installation = require_installation()?;
    let catalog = providers()?;
    let provider = catalog
        .providers
        .iter()
        .find(|provider| provider.id == provider_id)
        .with_context(|| format!("unknown Codex Router provider: {provider_id}"))?;
    if !provider.visible {
        return Ok(RouterProviderActionOutput {
            ok: true,
            action: "disable_provider",
            provider_id: provider.id.clone(),
            message: format!("{} is already hidden.", provider.name),
            pending_user_action: false,
        });
    }
    let output = run_router_dynamic(
        &installation.executable,
        &["providers", "disable", provider.id.as_str()],
    )
    .context("failed to hide the Codex Router provider")?;
    if !output.status.success() {
        bail!(
            "Codex Router could not hide {}: {}",
            provider.name,
            output_detail(&output)
        );
    }
    Ok(RouterProviderActionOutput {
        ok: true,
        action: "disable_provider",
        provider_id: provider.id.clone(),
        message: format!(
            "{} was hidden without deleting its credential or native GPT models.",
            provider.name
        ),
        pending_user_action: false,
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

#[cfg(target_os = "macos")]
fn provider_selection_is_empty() -> bool {
    let path = router_state_dir().join("enabled-providers.json");
    let Ok(contents) = fs::read(&path) else {
        return true;
    };
    serde_json::from_slice::<serde_json::Value>(&contents)
        .ok()
        .and_then(|value| value.get("providers")?.as_array().map(Vec::len))
        .is_none_or(|count| count == 0)
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

fn run_router_dynamic(path: &Path, arguments: &[&str]) -> Result<Output> {
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
    #[cfg(target_os = "macos")]
    command.env("PATH", augmented_router_path());
    command
        .output()
        .with_context(|| format!("failed to run {}", path.display()))
}

fn output_detail(output: &Output) -> String {
    last_line(&output.stderr)
        .or_else(|| last_line(&output.stdout))
        .unwrap_or_else(|| format!("command exited with {}", output.status))
}

fn provider_requires_explicit_consent(provider_id: &str) -> bool {
    matches!(provider_id, "kilo-free" | "opencode-free")
}

fn provider_connection_kind(provider_id: &str) -> &'static str {
    if provider_requires_explicit_consent(provider_id) {
        "anonymous"
    } else if matches!(provider_id, "lmstudio" | "local") {
        "local"
    } else if matches!(provider_id, "kimi-oauth" | "grok-oauth" | "devin-cli") {
        "oauth"
    } else if provider_id == "custom" {
        "custom"
    } else {
        "api_key"
    }
}

fn first_line(bytes: &[u8]) -> Option<String> {
    String::from_utf8_lossy(bytes)
        .lines()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .map(ToOwned::to_owned)
}

fn last_line(bytes: &[u8]) -> Option<String> {
    String::from_utf8_lossy(bytes)
        .lines()
        .map(str::trim)
        .rfind(|line| !line.is_empty())
        .map(ToOwned::to_owned)
}

fn sha256_hex(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

#[cfg(target_os = "macos")]
fn run_installer_phase<const N: usize>(
    installer: &Path,
    phase: &str,
    arguments: [&str; N],
) -> Result<()> {
    let output = Command::new("/bin/sh")
        .arg(installer)
        .args(arguments)
        .env("MODEL_ROUTER_TARGET", "codex")
        .env("PATH", augmented_router_path())
        .output()
        .with_context(|| format!("failed to {phase}"))?;
    if !output.status.success() {
        let detail = last_line(&output.stderr)
            .or_else(|| last_line(&output.stdout))
            .unwrap_or_else(|| format!("installer exited with {}", output.status));
        bail!("could not {phase}: {detail}");
    }
    Ok(())
}

#[cfg(target_os = "macos")]
fn bootstrap_node_dependencies(installation: &RouterInstallation) -> Result<()> {
    if installation.source != "managed_checkout" {
        return Ok(());
    }
    let checkout = installation
        .executable
        .parent()
        .and_then(Path::parent)
        .context("the managed Router checkout path is invalid")?;
    if checkout
        .join("node_modules/proper-lockfile/package.json")
        .is_file()
    {
        return Ok(());
    }
    let npm = find_on_path("npm")
        .or_else(|| {
            ["/opt/homebrew/bin/npm", "/usr/local/bin/npm"]
                .into_iter()
                .map(PathBuf::from)
                .find(|path| is_runnable(path))
        })
        .context("npm is required to prepare Codex Router dependencies")?;
    let output = Command::new(npm)
        .args(["ci", "--omit=dev"])
        .current_dir(checkout)
        .env("PATH", augmented_router_path())
        .output()
        .context("failed to install Codex Router's locked Node dependencies")?;
    if !output.status.success() {
        let detail = last_line(&output.stderr)
            .or_else(|| last_line(&output.stdout))
            .unwrap_or_else(|| format!("npm exited with {}", output.status));
        bail!("could not prepare Codex Router's Node dependencies: {detail}");
    }
    Ok(())
}

#[cfg(target_os = "macos")]
fn configure_native_mode(installation: &RouterInstallation) -> Result<()> {
    let mut arguments = vec!["setup", "--no-provider", "--no-tray"];
    let codex_home = env::var_os("CODEX_HOME")
        .map(PathBuf::from)
        .or_else(|| env::var_os("HOME").map(|home| PathBuf::from(home).join(".codex")));
    if codex_home.is_some_and(|home| {
        home.join("cockpit-local-access-model-catalog.json")
            .is_file()
    }) {
        arguments.push("--adopt-native-catalog");
    }
    let output = Command::new(&installation.executable)
        .args(arguments)
        .env("MODEL_ROUTER_TARGET", "codex")
        .env("PATH", augmented_router_path())
        .output()
        .context("failed to configure Codex Router's automatic native mode")?;
    if !output.status.success() {
        if provider_selection_is_empty() && status().healthy {
            return Ok(());
        }
        let detail = last_line(&output.stderr)
            .or_else(|| last_line(&output.stdout))
            .unwrap_or_else(|| format!("setup exited with {}", output.status));
        bail!("could not configure Codex Router's automatic native mode: {detail}");
    }
    Ok(())
}

#[cfg(target_os = "macos")]
fn augmented_router_path() -> std::ffi::OsString {
    let inherited = env::var("PATH").unwrap_or_default();
    format!("/opt/homebrew/bin:/usr/local/bin:{inherited}").into()
}

#[cfg(target_os = "macos")]
fn run_router_maintenance(path: &Path, arguments: &[&str]) -> Result<Output> {
    Command::new(path)
        .args(arguments)
        .env("MODEL_ROUTER_TARGET", "codex")
        .env("PATH", augmented_router_path())
        .output()
        .with_context(|| format!("failed to run {}", path.display()))
}

#[cfg(target_os = "macos")]
fn launch_provider_setup(executable: &Path, provider_id: &str, selection: &str) -> Result<()> {
    if !provider_id
        .bytes()
        .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
    {
        bail!("Codex Router returned an unsafe provider id");
    }
    let home = env::var_os("HOME")
        .map(PathBuf::from)
        .context("the home directory is unavailable; secure provider setup cannot continue")?;
    let launcher_dir = home
        .join("Library")
        .join("Caches")
        .join("Codex Roster")
        .join("router-provider-setup");
    fs::create_dir_all(&launcher_dir).context("failed to prepare secure provider setup")?;
    fs::set_permissions(&launcher_dir, fs::Permissions::from_mode(0o700))
        .context("failed to secure provider setup")?;
    let launcher = launcher_dir.join(format!("connect-{provider_id}.command"));
    let executable = shell_quote(&executable.to_string_lossy());
    let selection = shell_quote(selection);
    let provider_id = shell_quote(provider_id);
    let script = format!(
        "#!/bin/zsh\nset -e\nclear\nprintf '%s\\n' 'Codex Roster · Secure Router connection'\nprintf '%s\\n\\n' 'Credentials stay in Codex Router and are never stored by Roster.'\n{executable} setup --guided --providers {selection} --no-tray\nprintf '\\n%s\\n' 'Choose any additional live models for this provider (optional).'\n{executable} curate-models {provider_id} --apply || true\nprintf '\\n%s\\n' 'Setup complete. Roster will synchronize this provider automatically.'\nprintf '%s' 'Press any key to close…'\nread -k 1\nprintf '\\n'\n"
    );
    write_executable(&launcher, script.as_bytes())?;
    let opened = Command::new("/usr/bin/open")
        .args(["-a", "Terminal"])
        .arg(&launcher)
        .output()
        .context("failed to open secure provider setup in Terminal")?;
    if !opened.status.success() {
        bail!(
            "macOS could not open secure provider setup: {}",
            output_detail(&opened)
        );
    }
    Ok(())
}

#[cfg(target_os = "macos")]
fn launch_model_curation(executable: &Path, provider_id: &str) -> Result<()> {
    if !provider_id
        .bytes()
        .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
    {
        bail!("Codex Router returned an unsafe provider id");
    }
    let home = env::var_os("HOME")
        .map(PathBuf::from)
        .context("the home directory is unavailable; model selection cannot continue")?;
    let launcher_dir = home
        .join("Library")
        .join("Caches")
        .join("Codex Roster")
        .join("router-provider-setup");
    fs::create_dir_all(&launcher_dir).context("failed to prepare secure model selection")?;
    fs::set_permissions(&launcher_dir, fs::Permissions::from_mode(0o700))
        .context("failed to secure model selection")?;
    let launcher = launcher_dir.join(format!("models-{provider_id}.command"));
    let executable = shell_quote(&executable.to_string_lossy());
    let provider_id = shell_quote(provider_id);
    let script = format!(
        "#!/bin/zsh\nclear\nprintf '%s\\n\\n' 'Codex Roster · Choose Router models'\n{executable} curate-models {provider_id} --apply\nstatus=$?\nprintf '\\n'\nif [ $status -eq 0 ]; then printf '%s\\n' 'Model selection complete. Roster will synchronize automatically.'; else printf '%s\\n' 'Model selection did not finish. No native GPT model was changed.'; fi\nprintf '%s' 'Press any key to close…'\nread -k 1\nprintf '\\n'\nexit $status\n"
    );
    write_executable(&launcher, script.as_bytes())?;
    let opened = Command::new("/usr/bin/open")
        .args(["-a", "Terminal"])
        .arg(&launcher)
        .output()
        .context("failed to open Router model selection in Terminal")?;
    if !opened.status.success() {
        bail!(
            "macOS could not open Router model selection: {}",
            output_detail(&opened)
        );
    }
    Ok(())
}

#[cfg(target_os = "macos")]
fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\\"'\\\"'"))
}

#[cfg(target_os = "macos")]
fn write_executable(path: &Path, contents: &[u8]) -> Result<()> {
    let mut file = OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .mode(0o700)
        .open(path)
        .with_context(|| format!("failed to write {}", path.display()))?;
    file.write_all(contents)
        .with_context(|| format!("failed to write {}", path.display()))?;
    file.sync_all()
        .with_context(|| format!("failed to sync {}", path.display()))?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))
        .with_context(|| format!("failed to secure {}", path.display()))
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
    use super::{
        first_line, provider_connection_kind, provider_requires_explicit_consent, sha256_hex,
    };

    #[test]
    fn first_line_skips_leading_whitespace() {
        assert_eq!(first_line(b"\n  1.2.3  \nother"), Some("1.2.3".to_owned()));
    }

    #[test]
    fn sha256_hex_matches_known_vector() {
        assert_eq!(
            sha256_hex(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }

    #[test]
    fn anonymous_remote_providers_require_explicit_consent() {
        assert!(provider_requires_explicit_consent("kilo-free"));
        assert!(provider_requires_explicit_consent("opencode-free"));
        assert!(!provider_requires_explicit_consent("openrouter"));
        assert_eq!(provider_connection_kind("kilo-free"), "anonymous");
    }

    #[test]
    fn provider_connection_kinds_cover_local_oauth_and_api_key_routes() {
        assert_eq!(provider_connection_kind("local"), "local");
        assert_eq!(provider_connection_kind("grok-oauth"), "oauth");
        assert_eq!(provider_connection_kind("custom"), "custom");
        assert_eq!(provider_connection_kind("deepseek"), "api_key");
    }
}
