#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
version="$(sed -nE 's/^version = "([0-9]+\.[0-9]+\.[0-9]+)"/\1/p' "$root_dir/Cargo.toml" | head -n1)"
if [[ -z "$version" ]]; then
  echo "Unable to read version from Cargo.toml" >&2
  exit 1
fi

"$root_dir/scripts/build-macos-app.sh"

app_root="$root_dir/build/Codex Roster.app"
archive="$root_dir/build/Codex-Roster-${version}-macos.zip"
rm -f "$archive"
ditto -c -k --keepParent "$app_root" "$archive"

# Updater requires CFBundleShortVersionString == release tag version.
bundle_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_root/Contents/Info.plist")"
if [[ "$bundle_version" != "$version" ]]; then
  echo "Bundle version $bundle_version does not match Cargo.toml $version" >&2
  exit 1
fi
if [[ ! -x "$app_root/Contents/MacOS/codex-roster" ]]; then
  echo "Missing bundled CLI in app bundle" >&2
  exit 1
fi

echo "Packaged macOS app: $archive"
