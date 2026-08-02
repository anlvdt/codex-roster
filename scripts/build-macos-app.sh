#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_root="$root_dir/build/Codex Roster.app"
target_dir="$root_dir/build/cargo-target"
swift_package="$root_dir/macos/NextAccount"
mkdir -p "$root_dir/build"
iconset_root="$(mktemp -d "$root_dir/build/CodexRoster.XXXXXX")"
iconset="$iconset_root/CodexRoster.iconset"

cd "$root_dir"
cargo build --release --target-dir "$target_dir"
swift build --package-path "$swift_package" -c release

rm -rf "$app_root"
mkdir -p "$app_root/Contents/MacOS" "$app_root/Contents/Resources"
cp "$swift_package/Resources/Info.plist" "$app_root/Contents/Info.plist"
cp "$swift_package/.build/release/CodexRoster" "$app_root/Contents/MacOS/CodexRoster"
cp "$target_dir/release/codex-roster" "$app_root/Contents/MacOS/codex-roster"

swift "$root_dir/scripts/generate-macos-icon.swift" "$root_dir/assets/codex-roster.png"
mkdir -p "$iconset"
for icon in \
    "16 icon_16x16.png" \
    "32 icon_16x16@2x.png" \
    "32 icon_32x32.png" \
    "64 icon_32x32@2x.png" \
    "128 icon_128x128.png" \
    "256 icon_128x128@2x.png" \
    "256 icon_256x256.png" \
    "512 icon_256x256@2x.png" \
    "512 icon_512x512.png" \
    "1024 icon_512x512@2x.png"; do
    size="${icon%% *}"
    filename="${icon#* }"
    sips -z "$size" "$size" "$root_dir/assets/codex-roster.png" --out "$iconset/$filename" >/dev/null
done
iconutil -c icns "$iconset" -o "$app_root/Contents/Resources/CodexRoster.icns"

signing_identity="${CODE_SIGN_IDENTITY-}"
if [[ -z "$signing_identity" ]]; then
    signing_identity="-"
fi
if [[ "$signing_identity" != "-" ]]; then
    codesign --force --deep --options runtime --sign "$signing_identity" "$app_root"
else
    codesign --force --deep --sign - "$app_root"
fi
if ! codesign --verify --deep --strict "$app_root"; then
    # SwiftPM's linker signature can survive the first bundle pass on some
    # Xcode versions; a second pass seals both nested executables.
    if [[ "$signing_identity" != "-" ]]; then
        codesign --force --deep --options runtime --sign "$signing_identity" "$app_root"
    else
        codesign --force --deep --sign - "$app_root"
    fi
    codesign --verify --deep --strict "$app_root"
fi

if [[ -n "${NOTARYTOOL_PROFILE-}" ]]; then
    archive="$root_dir/build/Codex-Roster-notarization.zip"
    ditto -c -k --sequesterRsrc --keepParent "$app_root" "$archive"
    xcrun notarytool submit "$archive" --keychain-profile "$NOTARYTOOL_PROFILE" --wait
    xcrun stapler staple "$app_root"
fi

echo "Built $app_root"
