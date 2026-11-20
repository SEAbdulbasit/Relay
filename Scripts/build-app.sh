#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Prefer Apple's git over an incompatible third-party binary on PATH. Skip SDK test-data
# LFS filters for dependency source checkout; the release framework has its own checksum.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
export GIT_CONFIG_COUNT=3
export GIT_CONFIG_KEY_0=filter.lfs.process GIT_CONFIG_VALUE_0=
export GIT_CONFIG_KEY_1=filter.lfs.smudge GIT_CONFIG_VALUE_1=cat
export GIT_CONFIG_KEY_2=filter.lfs.required GIT_CONFIG_VALUE_2=false
configuration="${1:-release}"
# Prefer an explicit identity; otherwise reuse a local Apple Development certificate so
# macOS Accessibility/Automation TCC grants remain valid across rebuilds (fallback to ad-hoc).
if [[ -n "${RELAY_CODESIGN_IDENTITY:-}" ]]; then
    relay_codesign_identity="$RELAY_CODESIGN_IDENTITY"
else
    detected_identity="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null | /usr/bin/awk '/"Apple Development:/ { print $2; exit }')"
    relay_codesign_identity="${detected_identity:--}"
fi
echo "Signing Relay with identity: $relay_codesign_identity"
swift build -c "$configuration"
binary_dir="$(swift build -c "$configuration" --show-bin-path)"
vendor_temp="$(mktemp -d)"
trap 'rm -rf "$vendor_temp"' EXIT
vendor_snapshot="$vendor_temp/agent-desktop"
python3 Scripts/agent-desktop-vendor.py snapshot "$PWD/Vendor/agent-desktop" "$vendor_snapshot"
app_dir="${RELAY_BUILD_APP_PATH:-$PWD/build/Relay.app}"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$app_dir/Contents/Frameworks"
cp "$binary_dir/Relay" "$app_dir/Contents/MacOS/Relay.new"
mv -f "$app_dir/Contents/MacOS/Relay.new" "$app_dir/Contents/MacOS/Relay"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
mkdir -p "$app_dir/Contents/Library/LaunchDaemons"
cp Resources/dev.relay.assistant.preparation-wake.plist "$app_dir/Contents/Library/LaunchDaemons/"
cp Resources/Relay.icns "$app_dir/Contents/Resources/Relay.icns"
cp Resources/ThirdPartyNotices.txt Resources/LiteRT-LM-LICENSE.txt "$app_dir/Contents/Resources/"
if [ -d "$vendor_snapshot" ]; then
    for helper_bin in agent-desktop agent-desktop-macos-helper; do
        cp "$vendor_snapshot/bin/$helper_bin" "$app_dir/Contents/MacOS/$helper_bin.new"
        chmod +x "$app_dir/Contents/MacOS/$helper_bin.new"
        /usr/bin/codesign --force --sign "$relay_codesign_identity" "$app_dir/Contents/MacOS/$helper_bin.new"
        mv -f "$app_dir/Contents/MacOS/$helper_bin.new" "$app_dir/Contents/MacOS/$helper_bin"
    done
    for ffi_file in libagent_desktop_ffi.dylib agent-desktop-macos-helper; do
        cp "$vendor_snapshot/lib/$ffi_file" "$app_dir/Contents/Frameworks/$ffi_file.new"
        chmod +x "$app_dir/Contents/Frameworks/$ffi_file.new"
        /usr/bin/codesign --force --sign "$relay_codesign_identity" "$app_dir/Contents/Frameworks/$ffi_file.new"
        mv -f "$app_dir/Contents/Frameworks/$ffi_file.new" "$app_dir/Contents/Frameworks/$ffi_file"
    done
    cp "$vendor_snapshot/VERSION" "$app_dir/Contents/Resources/agent-desktop-version.txt"
    cp "$vendor_snapshot/LICENSE" "$app_dir/Contents/Resources/agent-desktop-LICENSE.txt"
fi
fixture_dir="$app_dir/Contents/Resources/RelayAccessibilityFixture.app"
mkdir -p "$fixture_dir/Contents/MacOS"
cp "$binary_dir/RelayAccessibilityFixture" "$fixture_dir/Contents/MacOS/RelayAccessibilityFixture.new"
mv -f "$fixture_dir/Contents/MacOS/RelayAccessibilityFixture.new" "$fixture_dir/Contents/MacOS/RelayAccessibilityFixture"
cp Resources/FixtureInfo.plist "$fixture_dir/Contents/Info.plist"
/usr/bin/codesign --force --sign "$relay_codesign_identity" "$fixture_dir"
# SPM binary products may be dynamic; include dependencies beside the executable.
while IFS= read -r framework; do
    [ -d "$framework" ] || continue
    dest_framework="$app_dir/Contents/Frameworks/$(basename "$framework")"
    rm -rf "$dest_framework"
    cp -R "$framework" "$dest_framework"
    /usr/bin/codesign --force --sign "$relay_codesign_identity" "$dest_framework"
done < <(find "$binary_dir" -maxdepth 1 -type d -name '*.framework')
for library in "$binary_dir"/*.dylib; do
    [ -f "$library" ] || continue
    cp "$library" "$app_dir/Contents/Frameworks/$(basename "$library").new"
    /usr/bin/codesign --force --sign "$relay_codesign_identity" "$app_dir/Contents/Frameworks/$(basename "$library").new"
    mv -f "$app_dir/Contents/Frameworks/$(basename "$library").new" "$app_dir/Contents/Frameworks/$(basename "$library")"
done
/usr/bin/install_name_tool -add_rpath '@executable_path/../Frameworks' "$app_dir/Contents/MacOS/Relay" 2>/dev/null || true
for resource in "$binary_dir"/*.bundle; do
    [ -d "$resource" ] || continue
    rm -rf "$app_dir/Contents/Resources/$(basename "$resource")"
    cp -R "$resource" "$app_dir/Contents/Resources/"
done
/usr/bin/codesign --force --sign "$relay_codesign_identity" "$app_dir/Contents/MacOS/Relay"
/usr/bin/codesign --force --deep --sign "$relay_codesign_identity" "$app_dir"
/usr/bin/codesign --verify --deep --strict "$app_dir"
touch "$app_dir"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app_dir" >/dev/null 2>&1 || true
printf 'Built %s\n' "$app_dir"
