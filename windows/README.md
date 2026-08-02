# Codex Roster for Windows

This folder contains the native **WinUI 3** Windows desktop app. It is deliberately separate from the Swift macOS app and calls the shared Rust `codex-roster.exe` through JSON commands.

## Desktop experience

- Native Fluent dashboard, sidebar and account quota list.
- Device sign-in launcher, save current session, activate and archive/restore saved accounts.
- One-minute polling for the active account when automatic quota refresh is enabled.
- Opt-in automatic quota switching through the shared Rust policy, deferred while Codex is running.
- `CodexRoster.Windows.exe` is the desktop entry point. `CodexRoster.CLI.exe` is the separately named helper for scripts and advanced terminal commands.
- The release bundle is self-contained: users do not need to install the .NET runtime or the Windows App SDK first.
- Sending the app to the notification area keeps quota monitoring and quick account switching available; the tray action reopens the WinUI dashboard.
- The dashboard checks stable GitHub Releases at launch and every six hours. Installing an update verifies GitHub's SHA-256 digest before the app replaces its bundle and relaunches.
- Local Credential Manager, encrypted backup, CLI, quota and snapshot logic remain in Rust.

The Preview intentionally does **not** close/relaunch the Windows Codex desktop app automatically. Auto-switch is therefore deferred until Codex is closed. That integration needs verification against the actual Windows app package and lifecycle before it is safe to enable.

## Build on Windows

Requirements: Windows 11 (Windows 10 1809+ target), Visual Studio 2022 with the Windows App SDK/WinUI workload, .NET 8 SDK, and Rust stable.

```powershell
pwsh -File scripts/build-windows.ps1
Start-Process build/windows/win-x64/CodexRoster.Windows.exe
```

Create the distributable ZIP with:

```powershell
pwsh -File scripts/package-windows.ps1
```

The ZIP contains `CodexRoster.Windows.exe`, its self-contained WinUI runtime,
and the helper CLI. It is the asset attached to GitHub releases.

For development with a different CLI binary, set `CODEX_ROSTER_CLI_PATH` to its full path. Do not point it to a shared or cloud-synced directory containing account snapshots.

## Release path

The first public Windows release will be an `x64` MSIX after real-device validation. `ARM64`, automatic app relaunch, signed MSIX, Microsoft Store submission, and update delivery follow after Preview acceptance.
