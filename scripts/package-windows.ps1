$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$output = Join-Path $root "build/windows/win-x64"
$archive = Join-Path $root "build/windows/Codex-Roster-Windows-x64.zip"

& (Join-Path $PSScriptRoot "build-windows.ps1")
Compress-Archive -Path (Join-Path $output "*") -DestinationPath $archive -Force
Write-Host "Packaged Windows desktop app: $archive"
