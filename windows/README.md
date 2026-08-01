# Codex Roster for Windows

This folder contains the native **WinUI 3** Windows Preview. It is deliberately separate from the Swift macOS app and calls the shared Rust `codex-roster.exe` through JSON commands.

## Current preview scope

- Native Fluent dashboard, sidebar and account quota list.
- Device sign-in launcher, save current session, activate and archive/restore saved accounts.
- One-minute polling for the active account when automatic quota refresh is enabled.
- Opt-in automatic quota switching through the shared Rust policy, deferred while Codex is running.
- Existing Rust system tray remains the temporary tray implementation for Windows.
- Local Credential Manager, encrypted backup, CLI, quota and snapshot logic remain in Rust.

The Preview intentionally does **not** close/relaunch the Windows Codex desktop app automatically. Auto-switch is therefore deferred until Codex is closed. That integration needs verification against the actual Windows app package and lifecycle before it is safe to enable.

## Build on Windows

Requirements: Windows 11 (Windows 10 1809+ target), Visual Studio 2022 with the Windows App SDK/WinUI workload, .NET 8 SDK, and Rust stable.

```powershell
pwsh -File scripts/build-windows.ps1
Start-Process build/windows/win-x64/CodexRoster.Windows.exe
```

For development with a different CLI binary, set `CODEX_ROSTER_CLI_PATH` to its full path. Do not point it to a shared or cloud-synced directory containing account snapshots.

## Release path

The first public Windows release will be an `x64` MSIX after real-device validation. `ARM64`, automatic app relaunch, signed MSIX, Microsoft Store submission, and update delivery follow after Preview acceptance.
