# Changelog

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

## Unreleased

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
