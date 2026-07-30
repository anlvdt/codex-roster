use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};
use directories::{BaseDirs, ProjectDirs};

use crate::model::EnvironmentKind;

#[derive(Clone, Debug)]
pub struct AppEnv {
    pub kind: EnvironmentKind,
    pub home_dir: PathBuf,
    pub codex_root: PathBuf,
    pub app_data_dir: PathBuf,
}

pub fn detect() -> Result<AppEnv> {
    let base_dirs = BaseDirs::new().context("could not resolve home directory")?;
    let project_dirs = ProjectDirs::from("com", "codexroster", "codex-roster")
        .context("could not resolve app data directory")?;
    let account_hub_project_dirs = ProjectDirs::from("com", "accounthub", "account-hub")
        .context("could not resolve Account Hub app data directory")?;
    let next_account_project_dirs = ProjectDirs::from("com", "nextaccount", "next-account")
        .context("could not resolve Next Account app data directory")?;
    let legacy_project_dirs = ProjectDirs::from("com", "nextide", "codex-account-switcher")
        .context("could not resolve legacy app data directory")?;
    let home_dir = base_dirs.home_dir().to_path_buf();
    let kind = detect_environment_kind()?;
    let app_data_dir = migrate_legacy_data_dir(
        project_dirs.data_local_dir(),
        &[
            account_hub_project_dirs.data_local_dir(),
            next_account_project_dirs.data_local_dir(),
            legacy_project_dirs.data_local_dir(),
        ],
    )?;
    Ok(AppEnv {
        kind,
        codex_root: home_dir.join(".codex"),
        home_dir,
        app_data_dir,
    })
}

fn migrate_legacy_data_dir(current: &Path, legacy_candidates: &[&Path]) -> Result<PathBuf> {
    if current.exists() {
        return Ok(current.to_path_buf());
    }
    let Some(legacy) = legacy_candidates.iter().find(|path| path.exists()) else {
        return Ok(current.to_path_buf());
    };
    let parent = current
        .parent()
        .context("new app data directory has no parent")?;
    fs::create_dir_all(parent).with_context(|| format!("failed to create {}", parent.display()))?;
    fs::rename(legacy, current).with_context(|| {
        format!(
            "failed to migrate saved Next IDE account data from {} to {}",
            legacy.display(),
            current.display()
        )
    })?;
    Ok(current.to_path_buf())
}

fn detect_environment_kind() -> Result<EnvironmentKind> {
    if cfg!(target_os = "windows") {
        return Ok(EnvironmentKind::Windows);
    }
    if cfg!(target_os = "macos") {
        return Ok(EnvironmentKind::Macos);
    }
    if cfg!(target_os = "linux") {
        if std::env::var_os("WSL_DISTRO_NAME").is_some()
            || std::env::var_os("WSL_INTEROP").is_some()
        {
            return Ok(EnvironmentKind::Wsl);
        }
        if let Ok(contents) = std::fs::read_to_string("/proc/sys/kernel/osrelease")
            && contents.to_ascii_lowercase().contains("microsoft")
        {
            return Ok(EnvironmentKind::Wsl);
        }
        return Ok(EnvironmentKind::Linux);
    }
    bail!("unsupported operating system")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_runtime_environment() {
        let env = detect().expect("env");
        match env.kind {
            EnvironmentKind::Windows
            | EnvironmentKind::Wsl
            | EnvironmentKind::Linux
            | EnvironmentKind::Macos => {}
        }
        assert!(env.codex_root.ends_with(".codex"));
    }

    #[test]
    fn migrates_legacy_data_only_when_the_new_location_is_empty() {
        let temp = tempfile::tempdir().expect("temp dir");
        let legacy = temp.path().join("nextide");
        let current = temp.path().join("next-account");
        fs::create_dir_all(&legacy).expect("legacy dir");
        fs::write(legacy.join("metadata.json"), "saved").expect("metadata");

        let migrated = migrate_legacy_data_dir(&current, &[&legacy]).expect("migrate");

        assert_eq!(migrated, current);
        assert!(current.join("metadata.json").exists());
        assert!(!legacy.exists());
    }
}
