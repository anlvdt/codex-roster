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
    let home_dir = base_dirs.home_dir().to_path_buf();
    let kind = detect_environment_kind()?;
    let legacy_data_dirs = legacy_data_dirs()?;
    let app_data_dir = migrate_legacy_data_dir(project_dirs.data_local_dir(), &legacy_data_dirs)?;
    Ok(AppEnv {
        kind,
        codex_root: home_dir.join(".codex"),
        home_dir,
        app_data_dir,
    })
}

/// Previous product names used separate app-data locations. Keep these visible
/// after the first new launch so each platform can import old snapshots safely.
pub fn legacy_data_dirs() -> Result<Vec<PathBuf>> {
    Ok(vec![
        ProjectDirs::from("com", "accounthub", "account-hub")
            .context("could not resolve Account Hub app data directory")?
            .data_local_dir()
            .to_path_buf(),
        ProjectDirs::from("com", "nextaccount", "next-account")
            .context("could not resolve Next Account app data directory")?
            .data_local_dir()
            .to_path_buf(),
        ProjectDirs::from("com", "nextide", "codex-account-switcher")
            .context("could not resolve legacy app data directory")?
            .data_local_dir()
            .to_path_buf(),
    ])
}

fn migrate_legacy_data_dir(current: &Path, legacy_candidates: &[PathBuf]) -> Result<PathBuf> {
    if current.exists() {
        return Ok(current.to_path_buf());
    }
    let parent = current
        .parent()
        .context("new app data directory has no parent")?;
    if !legacy_candidates
        .iter()
        .any(|path| path.symlink_metadata().is_ok())
    {
        return Ok(current.to_path_buf());
    }
    fs::create_dir_all(parent).with_context(|| format!("failed to create {}", parent.display()))?;
    let Some(legacy) = legacy_candidates
        .iter()
        .find(|path| is_trusted_legacy_dir(path, parent))
    else {
        return Ok(current.to_path_buf());
    };
    fs::rename(legacy, current).with_context(|| {
        format!(
            "failed to migrate saved Next IDE account data from {} to {}",
            legacy.display(),
            current.display()
        )
    })?;
    Ok(current.to_path_buf())
}

/// A legacy directory is adopted as the app's data dir only if it is a real
/// directory (not a symlink or file) owned by the same user as the directory
/// it is moved into, and not writable by group/others. Anything else could be
/// attacker-planted content that would be read back as "saved accounts".
fn is_trusted_legacy_dir(candidate: &Path, destination_parent: &Path) -> bool {
    let Ok(metadata) = candidate.symlink_metadata() else {
        return false;
    };
    if !metadata.file_type().is_dir() {
        return false;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        let Ok(parent) = fs::metadata(destination_parent) else {
            return false;
        };
        if metadata.uid() != parent.uid() || metadata.mode() & 0o022 != 0 {
            return false;
        }
    }
    #[cfg(not(unix))]
    let _ = destination_parent;
    true
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

        let migrated =
            migrate_legacy_data_dir(&current, std::slice::from_ref(&legacy)).expect("migrate");

        assert_eq!(migrated, current);
        assert!(current.join("metadata.json").exists());
        assert!(!legacy.exists());
    }

    #[cfg(unix)]
    #[test]
    fn does_not_adopt_a_symlinked_legacy_dir() {
        let temp = tempfile::tempdir().expect("temp dir");
        let planted = temp.path().join("attacker");
        let legacy = temp.path().join("nextide");
        let current = temp.path().join("next-account");
        fs::create_dir_all(&planted).expect("planted dir");
        fs::write(planted.join("metadata.json"), "forged").expect("metadata");
        std::os::unix::fs::symlink(&planted, &legacy).expect("symlink");

        migrate_legacy_data_dir(&current, std::slice::from_ref(&legacy)).expect("migrate");

        assert!(
            !current.exists(),
            "symlinked legacy dir must not be adopted"
        );
        assert!(legacy.symlink_metadata().is_ok());
        assert!(planted.join("metadata.json").exists());
    }

    #[cfg(unix)]
    #[test]
    fn does_not_adopt_a_world_writable_legacy_dir() {
        use std::os::unix::fs::PermissionsExt;
        let temp = tempfile::tempdir().expect("temp dir");
        let legacy = temp.path().join("nextide");
        let current = temp.path().join("next-account");
        fs::create_dir_all(&legacy).expect("legacy dir");
        fs::set_permissions(&legacy, fs::Permissions::from_mode(0o777)).expect("chmod");

        migrate_legacy_data_dir(&current, std::slice::from_ref(&legacy)).expect("migrate");

        assert!(!current.exists());
    }

    #[cfg(unix)]
    #[test]
    fn skips_an_untrusted_candidate_and_adopts_the_next_trusted_one() {
        let temp = tempfile::tempdir().expect("temp dir");
        let planted = temp.path().join("attacker");
        let bad = temp.path().join("accounthub");
        let good = temp.path().join("nextide");
        let current = temp.path().join("next-account");
        fs::create_dir_all(&planted).expect("planted dir");
        std::os::unix::fs::symlink(&planted, &bad).expect("symlink");
        fs::create_dir_all(&good).expect("good dir");
        fs::write(good.join("metadata.json"), "saved").expect("metadata");

        migrate_legacy_data_dir(&current, &[bad, good]).expect("migrate");

        assert!(current.join("metadata.json").exists());
    }
}
