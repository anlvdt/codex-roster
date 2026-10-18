//! Durable record of an in-flight account switch.
//!
//! A switch mutates `~/.codex` and several local files. If the process dies
//! halfway the user can be left with an account that is neither the old one nor
//! the new one, and the next poll would happily try again. This module records
//! the intent on disk before the first mutation, advances it through explicit
//! phases, and lets the next run reconcile what actually happened instead of
//! switching twice.

use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use time::OffsetDateTime;
use uuid::Uuid;

pub const FILE_NAME: &str = "switch-txn.json";

/// A transaction older than this is treated as abandoned.
pub const STALE_MINUTES: i64 = 5;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SwitchPhase {
    /// Intent recorded, nothing mutated yet.
    Decided,
    /// The outgoing rollout hint was captured.
    Captured,
    /// Credentials were swapped; the live identity is not verified yet.
    AuthSwapped,
    /// The live identity matches the target.
    Verified,
    /// Finished and cleaned up.
    Done,
    /// The swap failed or was reverted to the source account.
    RolledBack,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SwitchTxn {
    pub txn_id: Uuid,
    pub phase: SwitchPhase,
    pub from_account: Uuid,
    pub to_account: Uuid,
    pub started_at: OffsetDateTime,
    #[serde(default)]
    pub attempt: u32,
}

pub fn path(app_data_dir: &Path) -> PathBuf {
    app_data_dir.join(FILE_NAME)
}

/// Read the recorded transaction, if any. A corrupt file is treated as absent
/// (and removed) rather than blocking every future switch.
pub fn load(app_data_dir: &Path) -> Result<Option<SwitchTxn>> {
    let path = path(app_data_dir);
    let bytes = match fs::read(&path) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => {
            return Err(error).with_context(|| format!("failed to read {}", path.display()));
        }
    };
    match serde_json::from_slice::<SwitchTxn>(&bytes) {
        Ok(txn) => Ok(Some(txn)),
        Err(error) => {
            eprintln!(
                "warning: discarding unreadable switch transaction at {}: {error}",
                path.display()
            );
            let _ = fs::remove_file(&path);
            Ok(None)
        }
    }
}

fn write(app_data_dir: &Path, txn: &SwitchTxn) -> Result<()> {
    let bytes = serde_json::to_vec_pretty(txn).context("encode switch transaction")?;
    crate::file_store::atomic_write(&path(app_data_dir), &bytes, 0o600)
}

/// Record the intent to switch. Existing transaction attempts are counted so a
/// crash loop is visible in the file.
pub fn begin(
    app_data_dir: &Path,
    from_account: Uuid,
    to_account: Uuid,
    now: OffsetDateTime,
) -> Result<SwitchTxn> {
    let attempt = load(app_data_dir)?
        .filter(|txn| txn.from_account == from_account && txn.to_account == to_account)
        .map(|txn| txn.attempt.saturating_add(1))
        .unwrap_or(1);
    let txn = SwitchTxn {
        txn_id: Uuid::new_v4(),
        phase: SwitchPhase::Decided,
        from_account,
        to_account,
        started_at: now,
        attempt,
    };
    write(app_data_dir, &txn)?;
    Ok(txn)
}

/// Advance the recorded phase. The caller keeps the returned value.
pub fn advance(app_data_dir: &Path, txn: &SwitchTxn, phase: SwitchPhase) -> Result<SwitchTxn> {
    let next = SwitchTxn {
        phase,
        ..txn.clone()
    };
    write(app_data_dir, &next)?;
    Ok(next)
}

pub fn clear(app_data_dir: &Path) -> Result<()> {
    let path = path(app_data_dir);
    match fs::remove_file(&path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error).with_context(|| format!("failed to remove {}", path.display())),
    }
}

pub fn is_stale(txn: &SwitchTxn, now: OffsetDateTime) -> bool {
    now - txn.started_at > time::Duration::minutes(STALE_MINUTES)
}

/// Outcome of reconciling a recorded transaction against the live session.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ReconcileOutcome {
    /// Nothing was recorded.
    None,
    /// The swap landed; the record was advanced to `Verified`.
    Completed(SwitchPhase),
    /// The source account is still live; the record was rolled back.
    RolledBack,
    /// The transaction was too old to trust and was discarded.
    StaleDiscarded,
}

/// Decide what a recorded transaction means now that the process restarted.
///
/// `live_account_id` is the account the live `~/.codex` session currently maps
/// to (from the roster). The function is idempotent: calling it twice with the
/// same inputs performs at most one state change.
pub fn reconcile(
    app_data_dir: &Path,
    now: OffsetDateTime,
    live_account_id: Option<Uuid>,
) -> Result<ReconcileOutcome> {
    let Some(txn) = load(app_data_dir)? else {
        return Ok(ReconcileOutcome::None);
    };
    if matches!(txn.phase, SwitchPhase::Done | SwitchPhase::RolledBack) {
        clear(app_data_dir)?;
        return Ok(ReconcileOutcome::None);
    }
    if is_stale(&txn, now) {
        clear(app_data_dir)?;
        return Ok(ReconcileOutcome::StaleDiscarded);
    }
    match live_account_id {
        Some(live) if live == txn.to_account => {
            // The swap landed before the crash: keep the record so the caller
            // can finish bookkeeping, but mark it verified.
            let txn = advance(app_data_dir, &txn, SwitchPhase::Verified)?;
            Ok(ReconcileOutcome::Completed(txn.phase))
        }
        Some(live) if live == txn.from_account => {
            advance(app_data_dir, &txn, SwitchPhase::RolledBack)?;
            clear(app_data_dir)?;
            Ok(ReconcileOutcome::RolledBack)
        }
        _ => {
            // The live session maps to neither side (manual change, logout, or
            // an unknown account): the record cannot be trusted.
            clear(app_data_dir)?;
            Ok(ReconcileOutcome::StaleDiscarded)
        }
    }
}

/// True when a live (non-stale) transaction covers exactly this pair, which
/// means the switch is already in flight and must not be started twice.
pub fn in_flight_for_pair(
    app_data_dir: &Path,
    from_account: Uuid,
    to_account: Uuid,
    now: OffsetDateTime,
) -> Result<bool> {
    Ok(load(app_data_dir)?.is_some_and(|txn| {
        !is_stale(&txn, now)
            && txn.from_account == from_account
            && txn.to_account == to_account
            && !matches!(txn.phase, SwitchPhase::Done | SwitchPhase::RolledBack)
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn phases_are_recorded_and_cleared() {
        let temp = tempdir().unwrap();
        let now = OffsetDateTime::now_utc();
        let (from, to) = (Uuid::new_v4(), Uuid::new_v4());
        let txn = begin(temp.path(), from, to, now).expect("begin");
        assert_eq!(txn.phase, SwitchPhase::Decided);
        assert_eq!(txn.attempt, 1);
        assert!(in_flight_for_pair(temp.path(), from, to, now).unwrap());

        let txn = advance(temp.path(), &txn, SwitchPhase::Captured).expect("captured");
        let txn = advance(temp.path(), &txn, SwitchPhase::AuthSwapped).expect("swapped");
        assert_eq!(
            load(temp.path()).unwrap().unwrap().phase,
            SwitchPhase::AuthSwapped
        );
        advance(temp.path(), &txn, SwitchPhase::Done).expect("done");
        clear(temp.path()).expect("clear");
        assert!(load(temp.path()).unwrap().is_none());
    }

    #[test]
    fn a_crash_at_any_phase_is_reconciled_without_double_switching() {
        let temp = tempdir().unwrap();
        let now = OffsetDateTime::now_utc();
        let (from, to) = (Uuid::new_v4(), Uuid::new_v4());

        for phase in [
            SwitchPhase::Decided,
            SwitchPhase::Captured,
            SwitchPhase::AuthSwapped,
        ] {
            let txn = begin(temp.path(), from, to, now).expect("begin");
            advance(temp.path(), &txn, phase).expect("phase");

            // The swap landed: reconcile marks it verified and keeps the record.
            let first = reconcile(temp.path(), now, Some(to)).expect("reconcile");
            assert_eq!(first, ReconcileOutcome::Completed(SwitchPhase::Verified));
            let second = reconcile(temp.path(), now, Some(to)).expect("reconcile twice");
            assert_eq!(second, ReconcileOutcome::Completed(SwitchPhase::Verified));
            assert_eq!(
                load(temp.path()).unwrap().unwrap().phase,
                SwitchPhase::Verified,
                "reconcile must be idempotent"
            );

            // The source is still live: roll back and clean up.
            clear(temp.path()).unwrap();
            let txn = begin(temp.path(), from, to, now).expect("begin");
            advance(temp.path(), &txn, phase).expect("phase");
            assert_eq!(
                reconcile(temp.path(), now, Some(from)).unwrap(),
                ReconcileOutcome::RolledBack
            );
            assert!(load(temp.path()).unwrap().is_none());
        }
    }

    #[test]
    fn a_stale_transaction_is_discarded_and_does_not_block() {
        let temp = tempdir().unwrap();
        let now = OffsetDateTime::now_utc();
        let (from, to) = (Uuid::new_v4(), Uuid::new_v4());
        let txn = begin(
            temp.path(),
            from,
            to,
            now - time::Duration::minutes(STALE_MINUTES + 1),
        )
        .expect("begin");
        assert!(is_stale(&txn, now));
        assert!(!in_flight_for_pair(temp.path(), from, to, now).unwrap());
        assert_eq!(
            reconcile(temp.path(), now, Some(from)).unwrap(),
            ReconcileOutcome::StaleDiscarded
        );
        assert!(load(temp.path()).unwrap().is_none());
    }

    #[test]
    fn an_unknown_live_account_discards_the_record() {
        let temp = tempdir().unwrap();
        let now = OffsetDateTime::now_utc();
        let (from, to) = (Uuid::new_v4(), Uuid::new_v4());
        begin(temp.path(), from, to, now).expect("begin");
        assert_eq!(
            reconcile(temp.path(), now, Some(Uuid::new_v4())).unwrap(),
            ReconcileOutcome::StaleDiscarded
        );
        assert_eq!(
            reconcile(temp.path(), now, None).unwrap(),
            ReconcileOutcome::None
        );
    }

    #[test]
    fn a_corrupt_record_is_ignored_rather_than_fatal() {
        let temp = tempdir().unwrap();
        std::fs::write(path(temp.path()), b"{not json").unwrap();
        assert!(load(temp.path()).unwrap().is_none());
        assert!(!path(temp.path()).exists(), "the bad file is removed");
    }
}
