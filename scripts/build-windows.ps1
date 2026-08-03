$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$project = Join-Path $root "windows/CodexRoster.Windows/CodexRoster.Windows.csproj"
$output = Join-Path $root "build/windows/win-x64"
$cargoManifest = Join-Path $root "Cargo.toml"
$versionMatch = Select-String -Path $cargoManifest -Pattern '^version\s*=\s*"([0-9]+\.[0-9]+\.[0-9]+)"' | Select-Object -First 1
if ($null -eq $versionMatch) { throw "Unable to read the release version from Cargo.toml." }
$version = $versionMatch.Matches[0].Groups[1].Value

Push-Location $root
try {
    cargo build --release
    Remove-Item $output -Recurse -Force -ErrorAction SilentlyContinue
    dotnet publish $project --configuration Release --runtime win-x64 --self-contained true --output $output "-p:Version=$version" "-p:AssemblyVersion=$version.0" "-p:FileVersion=$version.0" "-p:WindowsPackageType=None" "-p:WindowsAppSDKSelfContained=true" "-p:WindowsAppSdkUndockedRegFreeWinRTInitialize=true"
    New-Item -ItemType Directory -Force -Path $output | Out-Null
    Copy-Item (Join-Path $root "target/release/codex-roster.exe") (Join-Path $output "CodexRoster.CLI.exe") -Force
    @"
Codex Roster for Windows

Start CodexRoster.Windows.exe for the desktop app.
CodexRoster.CLI.exe remains available for scripting and CLI commands; double-clicking
it from this folder also opens the desktop app automatically.
"@ | Set-Content -Path (Join-Path $output "README.txt") -Encoding utf8
    $requiredFiles = @(
        "CodexRoster.Windows.exe",
        "CodexRoster.Windows.dll",
        "CodexRoster.CLI.exe",
        "Microsoft.UI.Xaml.dll",
        "resources.pri"
    )
    foreach ($file in $requiredFiles) {
        if (-not (Test-Path (Join-Path $output $file))) {
            throw "Windows bundle is incomplete: missing $file"
        }
    }
    Write-Host "Built self-contained Windows desktop app: $output"
}
finally {
    Pop-Location
}
