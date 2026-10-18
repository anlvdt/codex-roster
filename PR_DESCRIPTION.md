Hardens Codex Roster across the activation guard, quota decisions, auto-resume, storage durability, the CLI contract and the macOS surface, following the audit in `docs/audit-2026-10-18/`. The reported symptom — a raw English "Codex CLI is still running" dialog that `--force` could not override — was a real guard with an unhelpful error path, and is fixed together with the correctness gaps found behind it.

Per-item status, commits and evidence: `docs/audit-2026-10-18/IMPLEMENTATION-STATUS.md`.
Auto-resume review: `docs/audit-2026-10-18/AUTO-RESUME-AUDIT.md`.

## Changes

**Activation safety and messaging**
- Classify blocking processes (`BlockKind`: interactive CLI / background CLI / Desktop / unrelated) and report pid, executable and role; `lsof`-based holder detection now fails closed instead of allowing a switch when the scan cannot be trusted.
- `auto-switch --apply` and `activate` return `waiting_for_processes` (and an `activation_blocked_by_cli:` payload) instead of `ready` while a live Codex CLI session runs. `--force` still only skips ChatGPT/Codex Desktop leftovers.
- The macOS app maps those payloads to localized messages that keep the process list, with a "Copy details" action; the same alert is wired into the Roster Console window, not just the notch.

**Quota decisions**
- An expired or missing 5-hour window is treated as unknown rather than reusing stale percentages; an ineligible account can no longer outrank an eligible one.
- Probe backoff no longer hides a natural window reset, and expired banked reset credits are not counted as redeemable.
- A successful credential swap is no longer turned into an error by a failed cooldown write or resume-hint read; the switch is reported with `warnings`.

**Auto-resume**
- Session-resume index writes are serialized across processes with an `fs2` lock.
- Rollout discovery is bounded: SQL recency filter with `LIMIT`, 128 KiB tail read, 1 MiB scan cap, cache keyed by path/size/mtime, and a local+UTC date ladder.
- A disabled resume setting preserves the pending queue, and `ready` requires a rollout that still exists.

**Storage and network**
- Atomic, durable writes everywhere (temp file + `sync_all` + rename + directory `fsync`); metadata and account-list backups are mode `0600`; quota-history writes are serialized with a lock and read paths no longer write.
- Public status/reset feeds are read with a 2 MiB body cap; reset announcements are ordered by parsed instant, not by RFC3339 string.

**CLI contract and discoverability**
- Every `--json` output carries `"contract_version": 1`, view timestamps are RFC3339, and failures print a machine-readable error object with a class-specific exit code (2 usage, 3 login/blocked, 4 lock timeout, 5 no account, 6 network, 7 keychain).
- New `doctor` (local diagnostics, `--json`, redacted `--bundle`) and `schema` commands.
- `--help` describes all commands; deprecated commands are hidden; the interactive menu refuses a non-TTY stdin and handles Ctrl-C.

**macOS UX and release**
- Menu-bar item (`CR`) with Open notch / Console / Settings / About / Quit, plus `⌘,` Settings and About.
- Delete now asks for confirmation and names the account; the active account cannot be deleted.
- Hovering the notch no longer steals keyboard focus; appear-driven public refreshes share a 60-second cooldown.
- Release builds use thin LTO and stripped symbols (CLI 8.6 MB → 6.9 MB, bundle 16 MB → 14 MB); CI pins actions by SHA, runs `--locked`, and a tag-triggered release workflow fails closed unless signing/notarization secrets exist.

## Validation

- `cargo fmt --check` — pass.
- `cargo clippy --locked --all-targets -- -D warnings` — pass, zero warnings.
- `cargo test --locked` — **423 passed, 0 failed, 1 ignored**.
- `swift build --package-path macos/NextAccount` — pass.
- `bash scripts/build-macos-app.sh` — pass; bundle built and signed (ad-hoc) locally.
- Manual checks: `printf '' | codex-roster` exits 1 with a hint instead of spinning; `list --json` shows `contract_version` and RFC3339 timestamps; a failing `--json` command prints the error envelope and exits non-zero; `doctor` reports paths, key modes, lock state and ports.
- Workflows parse as YAML; `scripts/clean-local-artifacts.sh` verified in dry-run mode.

**Validation limits:** the GUI was not driven end-to-end (UI claims rest on `swift build` plus code review); `swift test` needs a full Xcode toolchain and was not run here (CI runs it on `macos-latest`); the cross-process `session-resume.json` lock was exercised with threads, not two real processes; no test touches Keychain, live OAuth, or `~/.codex`.

## Not included

Remaining audit items (storage warnings in JSON, TUI search, Light Mode tokens and accessibility pass, forecast/scoring v2, independent verification) are tracked in `IMPLEMENTATION-STATUS.md` and are not part of this change.
