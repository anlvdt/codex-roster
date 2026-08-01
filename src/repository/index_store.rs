use std::fs;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use crate::file_store::{RecoveryFileKind, list_recovery_files, replace_file_with_recovery};
use crate::model::{METADATA_SCHEMA_VERSION, MetadataIndex};
use anyhow::{Context, Result, anyhow};
use serde_json::Value;
use time::{Date, OffsetDateTime, UtcOffset, format_description::well_known::Rfc3339};

pub(super) struct MetadataIndexStore {
    metadata_path: PathBuf,
}

const AUTOMATIC_BACKUP_LIMIT: usize = 20;

impl MetadataIndexStore {
    pub(super) fn new(data_dir: &Path) -> Self {
        Self {
            metadata_path: data_dir.join("metadata.json"),
        }
    }

    pub(super) fn load_index(&self) -> Result<MetadataIndex> {
        match self.best_available_index()? {
            Some(index) => Ok(index),
            None => {
                // Prefer a non-empty automatic list backup over silently starting empty.
                // An empty index followed by any save permanently orphans snapshot files.
                if let Some((path, index)) = self.best_non_empty_automatic_backup()? {
                    eprintln!(
                        "recovered account list ({} accounts) from {}",
                        index.accounts.len(),
                        path.display()
                    );
                    return Ok(index);
                }
                if self.snapshots_dir_has_files() {
                    return Err(anyhow!(
                        "account metadata is missing or unreadable, but encrypted snapshots still exist under {}. Restore with `codex-roster restore-account-list-backup` or `codex-roster restore-full-backup` before saving again.",
                        self.snapshots_dir().display()
                    ));
                }
                Ok(MetadataIndex {
                    schema_version: METADATA_SCHEMA_VERSION,
                    write_generation: 0,
                    accounts: Vec::new(),
                })
            }
        }
    }

    pub(super) fn save_index(&self, index: &MetadataIndex) -> Result<()> {
        if let Some(existing) = self.best_available_index()?
            && existing.accounts.len() >= 2
            && index.accounts.is_empty()
        {
            return Err(anyhow!(
                "refusing to overwrite {} saved accounts with an empty account list",
                existing.accounts.len()
            ));
        }
        let mut persisted = index.clone();
        persisted.write_generation = index.write_generation.saturating_add(1);
        let json =
            serde_json::to_string_pretty(&persisted).context("failed to serialize metadata")?;
        replace_file_with_recovery(&self.metadata_path, Some(json.as_bytes()), |temp_path| {
            fs::write(temp_path, &json)
                .with_context(|| format!("failed to write {}", temp_path.display()))
        })?;
        let _ = self.write_automatic_backup(&persisted, &json);
        Ok(())
    }

    pub(super) fn restore_latest_automatic_backup(&self) -> Result<usize> {
        // Prefer the backup with the most accounts; tie-break on newest generation.
        // Restoring "latest gen" after a wipe would otherwise re-apply the damaged list.
        let (path, index) = self
            .best_non_empty_automatic_backup()?
            .or_else(|| {
                self.automatic_backup_candidates()
                    .ok()
                    .and_then(|mut backups| backups.drain(..).next())
            })
            .ok_or_else(|| anyhow!("no automatic account-list backup is available"))?;
        let count = index.accounts.len();
        self.save_index(&index)?;
        eprintln!("restored account-list backup from {}", path.display());
        Ok(count)
    }

    fn automatic_backup_dir(&self) -> PathBuf {
        self.metadata_path
            .parent()
            .unwrap_or_else(|| Path::new("."))
            .join("account-list-backups")
    }

    fn snapshots_dir(&self) -> PathBuf {
        self.metadata_path
            .parent()
            .unwrap_or_else(|| Path::new("."))
            .join("snapshots")
    }

    fn snapshots_dir_has_files(&self) -> bool {
        let directory = self.snapshots_dir();
        fs::read_dir(&directory)
            .ok()
            .map(|entries| {
                entries
                    .filter_map(|entry| entry.ok())
                    .any(|entry| entry.path().extension().and_then(|ext| ext.to_str()) == Some("snapshot"))
            })
            .unwrap_or(false)
    }

    fn best_non_empty_automatic_backup(&self) -> Result<Option<(PathBuf, MetadataIndex)>> {
        let mut backups = self.automatic_backup_candidates()?;
        backups.retain(|(_, index)| !index.accounts.is_empty());
        backups.sort_by(|left, right| {
            right
                .1
                .accounts
                .len()
                .cmp(&left.1.accounts.len())
                .then_with(|| right.1.write_generation.cmp(&left.1.write_generation))
        });
        Ok(backups.into_iter().next())
    }

    fn write_automatic_backup(&self, index: &MetadataIndex, json: &str) -> Result<()> {
        let directory = self.automatic_backup_dir();
        fs::create_dir_all(&directory)
            .with_context(|| format!("failed to create {}", directory.display()))?;
        let path = directory.join(format!("metadata-{:020}.json", index.write_generation));
        fs::write(&path, json).with_context(|| format!("failed to write {}", path.display()))?;
        let backups = self.automatic_backup_candidates()?;
        for (path, _) in backups.into_iter().skip(AUTOMATIC_BACKUP_LIMIT) {
            let _ = fs::remove_file(path);
        }
        Ok(())
    }

    fn automatic_backup_candidates(&self) -> Result<Vec<(PathBuf, MetadataIndex)>> {
        let directory = self.automatic_backup_dir();
        if !directory.exists() {
            return Ok(Vec::new());
        }
        let mut backups = fs::read_dir(&directory)
            .with_context(|| format!("failed to read {}", directory.display()))?
            .filter_map(|entry| entry.ok())
            .filter_map(|entry| {
                let path = entry.path();
                let raw = fs::read_to_string(&path).ok()?;
                let index = parse_metadata_index(&raw).ok()?;
                (index.schema_version == METADATA_SCHEMA_VERSION).then_some((path, index))
            })
            .collect::<Vec<_>>();
        backups.sort_by_key(|entry| std::cmp::Reverse(entry.1.write_generation));
        Ok(backups)
    }

    pub(super) fn best_available_index(&self) -> Result<Option<MetadataIndex>> {
        let Some(parent) = self.metadata_path.parent() else {
            return Ok(None);
        };
        if !parent.exists() {
            return Ok(None);
        }
        let pending_path = self.metadata_path.with_extension("json.pending");
        let entries = list_recovery_files(&self.metadata_path, Some(&pending_path))?;
        let mut invalid_kinds = Vec::new();
        let mut candidates = entries
            .into_iter()
            .filter_map(|entry| {
                let raw = match fs::read_to_string(&entry.path) {
                    Ok(raw) => raw,
                    Err(_) => {
                        invalid_kinds.push(entry.kind);
                        return None;
                    }
                };
                let mut index: MetadataIndex = match parse_metadata_index(&raw) {
                    Ok(index) => index,
                    Err(error) => {
                        eprintln!("failed to parse {}: {error}", entry.path.display());
                        invalid_kinds.push(entry.kind);
                        return None;
                    }
                };
                if index.schema_version == 0 {
                    index.schema_version = METADATA_SCHEMA_VERSION;
                }
                if index.schema_version != METADATA_SCHEMA_VERSION {
                    invalid_kinds.push(entry.kind);
                    return None;
                }
                Some(RecoveryCandidate {
                    kind: entry.kind,
                    write_generation: index.write_generation,
                    modified: entry.modified,
                    index,
                })
            })
            .collect::<Vec<_>>();
        if candidates.is_empty() && !invalid_kinds.is_empty() {
            if invalid_kinds
                .iter()
                .all(|kind| matches!(kind, RecoveryFileKind::Pending))
            {
                return Ok(None);
            }
            return Err(anyhow!(
                "failed to parse metadata recovery state under {}",
                parent.display()
            ));
        }
        if let Some(canonical) = candidates
            .iter()
            .find(|entry| matches!(entry.kind, RecoveryFileKind::Canonical))
        {
            if let Some(pending) = candidates.iter().find(|entry| {
                matches!(entry.kind, RecoveryFileKind::Pending)
                    && entry.write_generation > canonical.write_generation
            }) {
                return Ok(Some(pending.index.clone()));
            }
            return Ok(Some(canonical.index.clone()));
        }
        candidates.sort_by(|left, right| {
            right
                .write_generation
                .cmp(&left.write_generation)
                .then_with(|| right.modified.cmp(&left.modified))
                .then_with(|| recovery_priority(right.kind).cmp(&recovery_priority(left.kind)))
        });
        Ok(candidates.first().map(|entry| entry.index.clone()))
    }
}

fn parse_metadata_index(raw: &str) -> serde_json::Result<MetadataIndex> {
    match serde_json::from_str(raw) {
        Ok(index) => Ok(index),
        Err(_) => {
            let mut value: Value = serde_json::from_str(raw)?;
            normalize_legacy_timestamps(&mut value);
            serde_json::from_value(value)
        }
    }
}

fn normalize_legacy_timestamps(value: &mut Value) {
    match value {
        Value::Array(values) => {
            for value in values {
                normalize_legacy_timestamps(value);
            }
        }
        Value::Object(values) => {
            for (key, value) in values.iter_mut() {
                if key.ends_with("_at")
                    && let Some(normalized) = legacy_timestamp_to_current_format(value)
                {
                    *value = normalized;
                } else {
                    normalize_legacy_timestamps(value);
                }
            }
        }
        _ => {}
    }
}

fn legacy_timestamp_to_current_format(value: &Value) -> Option<Value> {
    let timestamp = match value {
        Value::String(value) => OffsetDateTime::parse(value, &Rfc3339).ok()?,
        Value::Array(values) if values.len() == 9 => {
            let value_at = |index: usize| values[index].as_i64();
            let year = i32::try_from(value_at(0)?).ok()?;
            let ordinal = u16::try_from(value_at(1)?).ok()?;
            let hour = u8::try_from(value_at(2)?).ok()?;
            let minute = u8::try_from(value_at(3)?).ok()?;
            let second = u8::try_from(value_at(4)?).ok()?;
            let nanosecond = u32::try_from(value_at(5)?).ok()?;
            let offset_hour = i8::try_from(value_at(6)?).ok()?;
            let offset_minute = i8::try_from(value_at(7)?).ok()?;
            let offset_second = i8::try_from(value_at(8)?).ok()?;
            Date::from_ordinal_date(year, ordinal)
                .ok()?
                .with_hms_nano(hour, minute, second, nanosecond)
                .ok()?
                .assume_offset(UtcOffset::from_hms(offset_hour, offset_minute, offset_second).ok()?)
        }
        _ => return None,
    };
    serde_json::to_value(timestamp).ok()
}

struct RecoveryCandidate {
    kind: RecoveryFileKind,
    write_generation: u64,
    modified: SystemTime,
    index: MetadataIndex,
}

fn recovery_priority(kind: RecoveryFileKind) -> u8 {
    match kind {
        RecoveryFileKind::Canonical => 3,
        RecoveryFileKind::Pending => 2,
        RecoveryFileKind::Temp => 1,
        RecoveryFileKind::Backup => 0,
    }
}

#[cfg(test)]
mod tests {
    use super::parse_metadata_index;

    #[test]
    fn reads_mixed_legacy_timestamp_formats() {
        let index = parse_metadata_index(
            r#"{
                "schema_version": 1,
                "write_generation": 4,
                "accounts": [{
                    "id": "7501f28d-909b-410e-b6b2-0a89a2edb93d",
                    "environment": "macos",
                    "email": "person@example.com",
                    "subject": null,
                    "name": null,
                    "plan_label": null,
                    "secret_key": "snapshot:7501f28d-909b-410e-b6b2-0a89a2edb93d",
                    "created_at": [2026, 186, 3, 44, 33, 165334000, 0, 0, 0],
                    "updated_at": [2026, 186, 3, 44, 33, 165334000, 0, 0, 0],
                    "last_activated_at": null,
                    "cached_usage": {
                        "source": "saved_access_token",
                        "fetched_at": "2026-07-08T03:25:29.269473Z",
                        "five_hour": {
                            "used_percent": 25,
                            "remaining_percent": 75,
                            "reset_at": "2026-07-08T08:25:29Z"
                        },
                        "weekly": null,
                        "credits": null
                    },
                    "workspace_name": "Personal",
                    "is_archived": false
                }]
            }"#,
        )
        .expect("legacy index");

        assert_eq!(index.accounts.len(), 1);
        assert_eq!(index.accounts[0].email, "person@example.com");
        assert_eq!(index.accounts[0].created_at.year(), 2026);
        assert_eq!(
            index.accounts[0]
                .cached_usage
                .as_ref()
                .expect("usage")
                .fetched_at
                .year(),
            2026
        );
    }
}
