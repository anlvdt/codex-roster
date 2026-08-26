# Changelog

## v0.2.45 - 2026-08-26

### Changed

- Restore the rolling 5-hour Codex allowance as the primary quota and display it separately from the weekly allowance across the macOS app, menu bar, CLI, TUI, tray, and retained Windows source. Each window now has its own label and reset time instead of being collapsed into one ambiguous percentage.
- Rank account-switch candidates by their most constrained reported quota window while continuing to require every reported window to remain usable before an automatic switch.
- Show banked-reset counts in the macOS menu bar and keep reset forecasts anchored to explicitly stated delivery times.

### Fixed

- Keep the 5-hour (`primary_window`) and weekly (`secondary_window`) usage payloads distinct through decoding, cached status, and presentation, with regression coverage for both windows.
- Harden account switching, cached-quota refresh, subscription metadata, and reset tracking so stale or exhausted usage cannot be mistaken for immediately usable quota.
- Republish a stale Codex Router model catalog automatically after connecting a provider, and surface a restart instruction when the picker still lags.

## v0.2.44 - 2026-08-23

### Fixed

- Connecting a Codex Router provider now self-heals a stale model catalog: when a provider is enabled but its models are still missing from (or hidden in) the catalog Codex reads — because an earlier catalog rebuild failed, e.g. a network timeout — Roster republishes the catalog automatically and, if it still lags, says so and asks you to restart ChatGPT instead of silently leaving the models out of the picker.

## v0.2.43 - 2026-08-23

### Changed

- Roster now offers a Switch button for a quota-exhausted account that still holds a banked reset, so it can be activated and the reset redeemed inside Codex, instead of showing only a dead "Quota empty" label.
- Treat a quota window at 1% remaining (99% used) as empty in the roster too — matching the switching logic — so a window ChatGPT already blocks reads as out of quota and turns its meter red. Every quota surface — menu-bar percentage, the menu-bar popover session card, roster rows, provider summary, and account cards — now shows 0% (in red) for such a window instead of a misleading 1%.
- Add a GitHub link to the Codex Router card so the router's source is one click away from the main view; the pointer now switches to a hand on hover.
- Remove the account search field from the roster; the Hide-unavailable toggle remains.

### Fixed

- Auto-switch no longer interrupts a live Codex turn: it now reads the router's activity and holds the switch while a response is generating, and — when that turn runs on an external model via codex-router (whose quota is independent of the OpenAI account) — reports a distinct "using an external model" state instead of pointlessly closing ChatGPT and swapping accounts.
- Stop the Codex Router card from flashing "Auto-recovering" and triggering a heavy reinstall on every launch. Roster now gives the router's local service a short grace period to finish starting after a restart before escalating to recovery, so a healthy router is no longer disrupted.

## v0.2.42 - 2026-08-23

### Fixed

- Treat a quota window that reads back at 99% used (1% remaining) as exhausted for switching decisions. OpenAI floors `used_percent` server-side, so a window ChatGPT already blocks reported 1% remaining and kept auto-switch and banked-reset handling from ever running.
- Connect external-model providers that do not publish a machine-readable free catalog (such as Kilo Free and OpenCode Free) by falling back to the secure interactive model picker, so their models actually reach Codex instead of leaving the catalog empty.

## v0.2.41 - 2026-08-22

### Added

- macOS can install, configure, repair, and maintain Codex Router automatically from its checksum-verified official installer.
- Add, connect, enable, or hide external-model providers from Roster while Router remains the owner of credentials, routing, and model catalogs.
- Show banked-reset availability separately from immediately usable quota, with explicit account and reset counts.

### Changed

- Streamline the macOS dashboard, sidebar, menu bar, and About view around live quota, account health, reset monitoring, and frequent actions; remove duplicate account lists and passkey setup UI.
- Replace hard-coded 24h/48h reset percentages with recency-weighted forecast scores. Confirmed resets complete the future forecast at zero, and the latest reset time is shown as a live relative duration.
- Keep quota-exhausted accounts hidden from primary switching surfaces unless they have actionable banked resets or require attention.

### Fixed

- Auto-switch distinguishes unredeemed banked resets from usable quota and never silently consumes an irreversible reset or switches to an account still at 0%.
- Reject future-dated and stale public reset signals, select the latest actionable post by timestamp, and decay confidence at the 12h, 24h, and 48h boundaries.

## v0.2.40 - 2026-08-15

### Fixed

- macOS re-login now closes ChatGPT Desktop before running `codex login`, freeing the fixed loopback port its bundled app-server holds. Previously the sign-in browser never opened because the port was already in use, leaving the re-login sheet stuck waiting. Desktop is reopened automatically after login finishes, is cancelled, or fails.

## v0.2.39 - 2026-08-14

### Fixed

- Auto-switch never lands on a Free/Go account, an unlabeled plan, or a 0% quota window.
- Apply revalidates live usage before activating and walks every remaining candidate instead of trusting a stale roster cache.
- Stale Plus/Pro roster labels are ignored unless the latest usage fetch confirms a paid plan.
- Decide no longer aborts the whole tick when the live usage probe fails; cached 0% still rotates.
- GUI, tray, and TUI serialize auto-switch through a cross-process lock so two monitors cannot apply at once.

### Added

- Unlimited or remaining ChatGPT credits count as usable quota for both the active account and auto-switch targets.
- Windows app version is synced to the release (was still 0.2.36).

## v0.2.38 - 2026-08-13

- CCS removal verified: account-switch behavior matches pre-CCS v0.2.36 baseline
- Free-plan guard now recognizes Go and 'Free *' plan labels
- Settings UI cleanup after CCS removal

## v0.2.37 - 2026-08-13

- Remove CCS/CLIProxy and cmux integration entirely
- Restore standard account-switch flow (no CCS session guard)

## v0.2.36 - 2026-08-10

### Fixed

- Automatic switching never downgrades onto a Free-plan account. When the active account is exhausted it now rotates only between paid plans; if no paid account has usable quota it stops and reports "all exhausted" instead of silently landing on a Free account.

### Added

- Opt-in switch auth diagnostics. Setting `CODEX_ROSTER_AUTH_DEBUG` or creating `~/.codex/.roster-auth-debug` records non-secret token fingerprints (account id, `last_refresh`, access-token expiry, and a one-way refresh-token fingerprint — never the tokens themselves) for save/restore/probe steps to `<app_data_dir>/auth-debug.log`, so a "re-login on switch" report can be traced to the exact point a saved token went stale. Disabled by default.

### Notes

- Investigation confirmed the switch mechanism itself is sound: a freshly signed-in account survives a full switch-away-and-back cycle with its token intact. Repeated re-login prompts come from saved tokens that OpenAI has already revoked server-side (they age out when an account is left unused); recover each affected account with a one-time re-login.

## v0.2.35 - 2026-08-09

### Changed

- Redesign the menu bar popover action bar into two rows so the primary "Thêm tài khoản" and "Mở Codex Roster" buttons share the full width and no longer truncate; secondary utilities (refresh, update, about, quit) move to their own row with the destructive Quit set apart.
- Show a per-filter account count on each Bulk account manager tab (e.g. "Tất cả · 12", "Cần xử lý · 0") so it is obvious which groups contain accounts, and give the empty state a clearer message plus a one-tap shortcut to view all accounts.

## v0.2.34 - 2026-08-09

### Fixed

- Stop switching accounts from falsely requiring a fresh login. The post-switch acceptance check no longer treats a routine expired access token (a read-only 401) as a rejected target; it accepts the switch and lets the official Codex/ChatGPT Desktop refresh the still-valid refresh token lazily on first use, exactly like the legacy flow. A rollback now happens only when the session is proven signed out (revoked/reused/invalid refresh token) or Desktop fails to relaunch, for both manual and automatic switches.

## v0.2.33 - 2026-08-09

### Fixed

- Restore the legacy OAuth ownership model: activation now copies saved auth unchanged and leaves refresh-token rotation exclusively to the official Codex/ChatGPT Desktop.
- Preserve every current live session before switching, including previously unsaved accounts, and return an exact rollback point without exposing token material.
- Verify manual and automatic switch targets after Desktop relaunch; if the official Desktop rejects a target, restore and relaunch the previous account automatically.
- Defer repeated inactive access-token probes until activation so a temporary access-token rejection is not mislabeled as a required login.

## v0.2.32 - 2026-08-09

### Added

- Enforce one Codex Roster process per user session on macOS and Windows, so launching a second app copy exits immediately instead of creating a duplicate menu-bar or notification-area instance.

### Fixed

- Refresh an inactive account's stale access token and persist the rotated snapshot before any manual or automatic switch; abort safely without changing the current session when refresh fails.
- Add a compact comparison dashboard, health summary, contextual recovery actions, and master-detail session diagnostics for managing large rosters quickly.

## v0.2.31 - 2026-08-09

### Fixed

- Keep ChatGPT/Codex Desktop running throughout add-account and re-login; these flows pause automatic switching and quota work without masquerading as an account switch or restarting Desktop.
- Streamline the native dashboards and menu bar around switching: direct access to every available account, compact session controls, collapsible bulk management, fewer duplicate panels, and overflow menus for secondary actions.

## v0.2.30 - 2026-08-09

### Fixed

- Block every manual, tray, and automatic account switch while any Codex helper or CLI process can still rewrite the live auth bundle; `--force` can no longer bypass the core safety guard.
- Wait briefly for Desktop helpers to drain without forcing, restore the previous Desktop session when a switch is blocked, and verify the restored auth remains stable for a full second.
- Preserve existing login-error markers when auth is merely saved locally; only a successful server usage/refresh check clears them.
- Distinguish explicit server session revocation, rejected refresh tokens, and an unproven access-token 401 without storing token material.
- Require Codex to persist a genuinely changed auth document before add/re-login can be saved, and require OpenAI to accept it before the UI reports success or advances a bulk-login queue.
- Stop and later restore Desktop around login, pin Codex login to file-backed credentials, and pause quota/auto-switch work for the entire login transaction.
- Restore legacy token ownership for inactive accounts: background quota checks and activation no longer consume saved rotating refresh tokens; Codex refreshes the active auth in place.
- Disable background Codex logins for inactive accounts so an interrupted usage-window ping can never consume a saved refresh token without persisting its replacement.
- Add cross-platform CI and regression gates that fail if forced account switching is reintroduced.

## v0.2.29 - 2026-08-09

### Fixed

- Made Codex the exclusive owner of the active refresh token; background quota checks never rotate the live session.
- Split hard sign-in failures, local snapshot recovery, and transient usage errors so only confirmed server-side session failures request login.
- Load the saved roster when the dashboard opens instead of waiting for the menu-bar panel to be opened first.
- Stop an old bundled macOS tray companion during self-update so pre-update token logic cannot remain alive after the bundle is replaced.

### Changed

- Added macOS health filters, last-verification details, scoped bulk refresh/archive/restore/delete, and selective batch re-login.
- Added Windows multi-select bulk actions, sequential batch re-login, session-health labels, passkey guidance, and live-session safety messaging.

## v0.2.28 - 2026-08-09

### Changed

- **macOS can repair every account that needs sign-in as one guided queue.** The dashboard's quick-repair action opens each required browser login in sequence, verifies the expected email, saves and checks the recovered session automatically, then advances to the next account without reopening the sheet manually.
- Cancelling batch re-login stops the remaining queue and safely restores the session that was active before the current login attempt.

## v0.2.27 - 2026-08-09

### Added

- Desktop notifications for every newly verified ChatGPT mass-reset event, with persistent deduplication so each event is announced exactly once.

### Changed

- Account add and re-login now run quietly in the background and open only the required browser flow instead of an extra terminal window.
- Windows account switching no longer waits a fixed two seconds for Codex Desktop to close; it continues as soon as the process exits.

### Fixed

- **Account switching no longer invalidates sessions or repeatedly logs users out.** All Roster processes now serialize the complete read-refresh-write token transaction, preventing background quota refresh, auto-start pings, manual switching, and automatic switching from racing single-use OAuth refresh tokens.
- Switching always preserves the latest live session before restoring another account, and aborts safely without touching the current session when the selected account has an invalid refresh token.

## v0.2.26 - 2026-08-09

### Changed

- **Adding and re-signing accounts is now automatic.** Opening the flow launches OpenAI sign-in immediately; Roster detects the verified session, saves it, refreshes quota, and closes the sheet without requiring reload or save clicks.
- **Windows account switching is now one click.** Roster closes and relaunches Codex Desktop around the session swap without an extra confirmation dialog, while active CLI work remains protected.

### Fixed

- Pending sign-in sheets can no longer be dismissed accidentally before the previous Codex session is safely restored.
- Restored the formatting and lint release gates that had been failing on recent `main` builds.

## v0.2.25 - 2026-08-09

### Fixed

- **Snapshot key no longer orphaned by app updates.** The local-snapshot and automatic-backup keys lived only in the macOS Keychain, whose access is bound to the app's ad-hoc code signature. An app update changed the signature and silently orphaned every account snapshot encrypted under the previous key — those accounts could then never refresh quota or be switched into, and showed permanently stale quota. The key is now stored in a `0600` file in the app data directory (the current Keychain key is migrated into it on first read) so it survives updates.
- **Undecryptable snapshots are now flagged for re-login** instead of silently keeping a stale quota, so you can see exactly which accounts need to be signed in again.

### Note

- Accounts whose snapshot was encrypted under a key that is already lost cannot be recovered and must be signed in again; they now appear under "needs login".

## v0.2.24 - 2026-08-09

### Fixed

- **Quota now refreshes for the whole roster, not just the active account.** The macOS and Windows apps run short-lived CLI calls and never hosted the background worker added in 0.2.23, so saved accounts never picked up an off-schedule ChatGPT reset. The periodic quota poll now calls a new `refresh-usage` command that re-queries the active account plus every stale saved account. On macOS this runs regardless of the usage-window setting.

### Added

- `refresh-usage` CLI command: staleness-aware refresh of the active account and any stale saved accounts, for GUI frontends to poll.

## v0.2.23 - 2026-08-09

### Added

- Background usage sweep: every saved account's quota is re-queried on a 120s worker (independent of auto-switch/auto-start), so an off-schedule ChatGPT mass reset shows up on the whole roster without a manual refresh. Fresh-quota and login-required accounts are skipped.

### Changed

- Sign-in now uses the Codex browser flow (`codex login`) instead of `--device-auth`, so adding or re-logging an account no longer requires entering a device code.

### Fixed

- Switching accounts no longer forces a re-login: a saved account's near-expiry access token is refreshed and persisted during the switch, so Codex starts from a valid token instead of looping on `refresh_token_reused`.
- Quota no longer stays stale after an off-schedule reset: an exhausted window is re-queried instead of being trusted until its old scheduled `reset_at`.

## v0.2.22 - 2026-08-07

### Added

- Added an **Add account** button to the macOS menu-bar popup. It opens the dashboard directly to the existing protected add-account flow.

## v0.2.21 - 2026-08-07

### Fixed

- Restored legacy-compatible add-account behavior: retain the trusted local Codex session while device login begins, while keeping backup and cancel-to-restore protection.
- Show each saved account's expected quota reset time in the macOS sidebar.
- Refresh quota immediately after saving a newly added macOS account so its quota/reset state appears without a separate manual refresh.

## v0.2.20 - 2026-08-03

### Fixed

- Windows add-account no longer closes Codex/ChatGPT Desktop (which looked like the app “turning off”); a second Add resumes the pending session instead of failing with “already in progress”, and failed begins roll back via cancel-add-account.
- Pending add-account shows a top InfoBar with **Hủy và khôi phục phiên**; console `codex login` is no longer treated as Desktop and killed.
- Live `~/.codex` sessions are no longer force-logged-out by parallel OAuth refresh while Codex/ChatGPT is running: Roster skips live token rotation when those processes are present, and does not poison saved snapshots when live write-back loses a race.
- Auto-start usage-window pings skip the active live account (temp-home `codex exec` would rotate the same refresh token).
- Windows quota parsing accepts Rust `time` array timestamps for `reset_at`; JSON import and auto-switch/auto-quota UI hardening ship in this build.
- macOS add/re-login now uses `begin-add-account` / `save-added-account` / `cancel-add-account` with restore-on-cancel, resumes pending sessions on launch, and pauses auto-switch/quota while login is in progress. Release attaches `Codex-Roster-*-macos.zip` so in-app update checks succeed.

## v0.2.19 - 2026-08-03

### Fixed

- Windows desktop launch no longer crashes with `XamlParseException`: the command-bar "Dịch vụ" button used `Icon="Cloud"`, which is not a valid WinUI `Symbol` enum value. It now uses `Globe`.
- Startup diagnostics now log the full inner-exception chain and HRESULT so future XAML load failures are actionable; a failed window launch exits instead of leaving a zombie process.
- Windows unpackaged publish enables MSIX tooling and requires a `.pri` resource index in the release bundle so WinUI can resolve `ms-appx` XAML.
- Account activation/auto-switch now closes Codex/ChatGPT Desktop helpers (including windowless Electron processes), passes `--force` only after an explicit Desktop close, and relaunches Desktop so the new session is picked up.
- Device login resolves `codex.cmd` / PATH installs instead of assuming `codex.exe`, refuses add-account save until identity is detected, and re-arms the login watcher after a mid-session restart.
- In-app updater stops the notification-area CLI companion before replacing the install folder; packaging builds a forced `x86_64` CLI and smokes `status --json`.
- UI errors surface the real CLI message, identity matching prefers `subject`, and destructive restore/import actions ask for confirmation.

## v0.2.18 - 2026-08-03

### Fixed

- Windows device login now closes its command shell when complete instead of leaving `cmd.exe` running in the release folder.
- Closing the Windows dashboard now cancels its device-login shell, stops timers, and terminates any in-flight bundled CLI helper; helper and update processes run from the temporary directory so they do not keep the release folder as their working directory.
- Made notification-area background monitoring explicit with a confirmation that explains how to quit it before replacing or deleting the app folder.

## v0.2.17 - 2026-08-03

### Fixed

- Restored the legacy add-account flow: the current session is saved and backed up before device login, can be cancelled back to the prior session, and accepts Codex installations without `cap_sid`.
- Import saved OpenAI/Codex snapshots from all prior product data locations on every platform, including Windows after the new app directory already exists.
- On Windows, direct switching now offers to close and restart a visible Codex/ChatGPT Desktop window around the auth swap; running Codex CLI work remains a blocking safety check.

## v0.2.16 - 2026-08-03

### Fixed

- Ship the Windows WinUI app as explicitly unpackaged and self-contained, including registration-free WinRT initialization, so the bundled desktop executable can load its XAML UI without a separately installed Windows App SDK runtime.
- Fail the Windows packaging build when the executable or WinUI runtime is missing.
- Retry Windows file-lock violations while another account operation is finishing, allowing the Windows release build to complete its test gate.

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
