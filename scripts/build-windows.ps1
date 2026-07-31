$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$project = Join-Path $root "windows/CodexRoster.Windows/CodexRoster.Windows.csproj"
$output = Join-Path $root "build/windows/win-x64"

Push-Location $root
try {
    cargo build --release
    dotnet publish $project --configuration Release --runtime win-x64 --self-contained false --output $output
    Copy-Item (Join-Path $root "target/release/codex-roster.exe") (Join-Path $output "codex-roster.exe") -Force
    Write-Host "Built Windows Preview: $output"
}
finally {
    Pop-Location
}
