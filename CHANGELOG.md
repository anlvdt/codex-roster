# Changelog

## v0.2.14 - 2026-08-02

### Fixed

- Fixed the Windows startup diagnostics build so the patched desktop bundle can ship.

## v0.2.13 - 2026-08-02

### Fixed

- Renamed the bundled Windows CLI helper so it is not mistaken for the desktop app, and added visible startup diagnostics with a local log if WinUI cannot launch.

## v0.2.12 - 2026-08-02

### Fixed

- Synced macOS bundle metadata with the release version so verified self-updates accept the downloaded app bundle.

## v0.2.11 - 2026-08-02

### Fixed

- Fixed the Windows desktop build so the native bundle can be packaged and attached to the release.

## v0.2.10 - 2026-08-02

### Windows

- Promoted the WinUI desktop app to the default bundled entry point and package it as a self-contained release ZIP.
- Added account-label editing, verified re-login, encrypted backup import/export, account sort choices, local token activity, OpenAI/reset service information, launch-at-login, and a notification-area companion with quick switching.
- Added Windows CI/release packaging for the native desktop bundle.
- Added six-hour GitHub Release checks and a verified in-app Windows updater that validates the published SHA-256 digest, stages the ZIP safely, rolls back on installation failure, and relaunches the desktop app.

## v0.2.9 - 2026-08-02

### Changed

- Reworked Add Account into a detected-session flow: preserve the current session, wait for the new device-login identity, and save only after it is verified.

### Fixed

- Prevented saving the prior account while device login is still pending, and keep the Add Account sheet open until saving succeeds or fails.

## v0.2.8 - 2026-08-02

### Fixed

- Do not treat usage endpoint access-denied responses as an expired login or rotate refresh tokens for them.
- Prevent auto-switch from selecting duplicate records that represent the same exhausted OpenAI account.
- Give ChatGPT Desktop a longer graceful termination window, then terminate its process directly before switching.

## v0.2.7 - 2026-08-02

### Fixed

- Restored the Rust formatting and clippy release gates with a pinned toolchain.
- Bounded stalled macOS CLI operations instead of allowing output-pipe waits to hang indefinitely.

### Changed

- Made quota and auto-switch polling adaptive near exhaustion.
- Hardened macOS self-update downloads and replacement with size limits, staged replacement, rollback, and local updater logs.
- Added ad-hoc signing by default plus optional Developer ID signing and notarization hooks for distributable builds.

## v0.2.6 - 2026-08-02

### Changed

- Shortened the macOS menu bar popup by showing only attention-worthy OpenAI and updater statuses, moving update checks to the footer, and limiting quick switch to three accounts.

## v0.2.5 - 2026-08-02

### Fixed

- Fixed GitHub Release decoding for the browser_download_url asset field, restoring automatic update checks in the macOS menu bar.

## v0.2.4 - 2026-08-02

### Added

- Added GitHub Release update checks in the macOS menu bar at launch and every six hours, with a verified one-click update flow that relaunches the app.
- Added a compact community reset forecast to the macOS menu bar, including 24-hour and 48-hour likelihoods plus the expected reset window.

### Security

- Verify GitHub's published SHA-256 digest, macOS bundle identifier, and release version before installing a downloaded update.

## v0.2.3 - 2026-08-02

### Fixed

- Made account switching complete immediately after auth restoration while Desktop relaunch and verification continue in the background.
- Made auto-switch respect its disabled setting, refresh exhausted quota caches once their reset time passes, and fall back to another usable cached account when the chosen candidate changes.
- Kept auto-switch from forcing an auth swap through a live Codex CLI process; it now performs only a short safe retry for process-table lag.
- Surface a clear recovery action when ChatGPT Desktop cannot be relaunched after switching.

### Changed

- Removed the macOS switch confirmation dialog and use immediate Desktop termination for explicit direct switches.
- Reduced local snapshot write latency by avoiding adaptive scrypt calibration for Keychain-protected generated keys; existing snapshots remain readable.

## v0.2.0 - 2026-07-30

### Added

- Added the native macOS Codex Roster app, including a menu-bar companion, account dashboard, usage cards, and safe activation confirmation.
- Added provider-oriented dashboard rows, reset countdowns, neutral unavailable-usage states, and a compact five-account quick-switch menu.
- Added project attribution and license boundaries in `CREDITS.md` for UI/UX research sources.
- Added a native About & Support page plus `AUTHORS.md`, with local-first privacy boundaries, authorship, contact guidance, and original-foundation acknowledgement.
- Added a Vietnamese-first bilingual interface with an in-app Vietnamese/English language switch that persists across launches.
- Added local Codex session-token statistics for today, 7 days, 30 days, and 12 months, with duplicate token snapshots excluded.
- Added native Add Account and Edit Account flows, including persistent custom display names and a live weekly-quota percentage in the menu bar.
- Added encrypted password-protected export/import, full local Keychain-encrypted automatic session backups, persistent archive state, and native Launch at Login.
- Added opt-in automatic switching only when the active account is exhausted and a freshly checked saved account has usable quota.

### Changed

- Refined the native dashboard hierarchy: semantic status-card labels, stronger numeric typography, clearer sidebar account rows, and unambiguous M/B local-token units.
- Focused Codex Roster exclusively on OpenAI / Codex after reviewing unsupported third-party account storage and quota surfaces; legacy provider tags are normalized to OpenAI / Codex on read.

- Renamed the product and CLI from codex-account-switcher to Codex Roster / `codex-roster` for the focused OpenAI / Codex workflow.
- Moved application data to the `codexroster/codex-roster` product directory, with a one-time migration of Account Hub, Next Account, and Next IDE data directories.

## v0.2.1 - 2026-08-01

### Security and reliability

- Hardened snapshot import and restore against unmanaged files, path traversal, oversized payloads, and identity mismatches.
- Encrypted local snapshots with a system credential-store key and protected temporary auth files with private permissions.
- Added cross-process operation locking, atomic backup import/restore, rollback, and active-account compare-and-swap checks.
- Made automatic switching defer safely while Codex or ChatGPT is running, with cooldowns and serialized Windows checks.
- Updated vulnerable Rust dependencies and added regression coverage for backup, rollback, and staging boundaries.

## v0.2.2 - 2026-08-01

### Added

- Sort saved accounts by ChatGPT plan (Pro → Plus → Free), remaining quota, display name, or email (macOS sidebar control; Windows list uses plan then quota).
- Windows Preview restore actions for automatic account-list and full-session backups, next to device login / save current session.
- Menu bar action to reopen ChatGPT Desktop against the current Roster session when the UI looks out of sync.

### Changed

- Quota toolbar refresh defaults to the active account; “refresh all” remains available from the menu / shortcut.
- Menu bar quick-switch shows up to five candidates using the selected sort order.
- Windows auto-switch apply now passes `--account-id` so the decided candidate is revalidated instead of re-ranking a stale cache.
- Re-login save verifies the live session email before writing, avoiding accidental upserts for the wrong account.
- macOS auto-switch closes ChatGPT Desktop when needed, switches `~/.codex`, and relaunches so Desktop matches Roster; `--force` is used only after Desktop was quit (a live Codex CLI still defers switching).
- ChatGPT Desktop lifecycle: soft-quit first, then force-quit; relaunch confirms the app is running; auto-switch status is bilingual step-by-step (closing → switching → relaunching).

### Notes

- **macOS Keychain prompt:** When Codex Roster (or its bundled `codex-roster` helper, or a local `cargo test` / `cargo run` binary named like `codex_roster-<hash>`) reads the local encryption key, macOS may ask for access to Keychain item **`com.codexroster.app`**. That key only encrypts saved snapshots and automatic backups on this Mac. Choose **Allow** / **Always Allow** if the item name matches; **Deny** leaves those sessions unreadable. This dialog is from macOS and is not an OpenAI password prompt. See the README “macOS Keychain prompt” section.
- Developer ID notarization is still a manual release step (not automated in the local build script).

## v0.1.5 - 2026-05-22

### Added

- Added saved-account stale-login detection for expired or reused refresh tokens. Failed saved-account usage refreshes now persist a `Login required` marker so the CLI, TUI, and Windows tray can show which account needs a fresh sign-in.

### Fixed

- Prefer the stale-login marker over older cached weekly usage so expired accounts do not look healthy just because a previous usage snapshot still exists.
- Refresh the Windows tray menu after background auto-start usage checks so tray rows reflect refreshed usage and login-required state without reopening the app.

## v0.1.4 - 2026-05-11

### Fixed

- Restored the Windows tray account table so active and saved accounts show plan, weekly remaining percentage, and weekly reset time again.
- Improved tray table alignment in native Windows menus by using the menu detail column plus fixed-width percentage formatting.
- Kept active-account display informational while saved-account rows remain clickable switch targets.

## v0.1.3 - 2026-05-10

### Added

- Added optional auto-start usage-window refreshes. When enabled, the app checks saved accounts every five minutes and starts overdue weekly Codex usage windows with a minimal isolated `codex exec` ping.
- Added controls for the new refresh behavior in the persistent TUI, the Windows tray menu, and the `auto-start-usage-windows` CLI command.
- Added a tray checkmark for `Auto-start usage windows`; enabling it from tray immediately kicks off a background check without blocking the tray menu.
- Added `AGENTS.md` with brief repo instructions and commit-message examples for future agent work.

### Changed

- TUI account rows now show weekly reset dates with 24-hour time, for example `Reset: 2026-05-12 13:56`.
- Auto-start pings now run in a temporary `CODEX_HOME` seeded from the saved snapshot, so active app/CLI sessions keep their cached auth and the live Codex auth home is not swapped.
- Auto-start refreshes now keep using the active app environment, serialize concurrent manual/tray/background checks, preserve cached usage metadata on write-back, and scrub temporary auth material after cleanup edge cases.
- The tray menu now uses simple `Active:` and `Saved:` sections with email-only account rows instead of dense plan/status/usage columns.
- Startup/status rendering is faster because process detection now refreshes only the process fields the app actually displays.

### Fixed

- Removed the awkward `Which account do you want to activate?` prompt from activation flows.
- Hardened `auto-start-usage-windows --disable --run` so disabling remains disable-only.
- Fixed newer Clippy warnings on Rust 1.95 across Windows, macOS, and Linux CI.
