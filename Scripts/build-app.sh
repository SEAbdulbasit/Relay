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
# Explicit identity only. Default remains an ad-hoc development build.
relay_codesign_identity="${RELAY_CODESIGN_IDENTITY:--}"
swift build -c "$configuration" --product Relay
swift build -c "$configuration" --product RelayAccessibilityFixture
binary_dir="$(swift build -c "$configuration" --show-bin-path)"
app_dir="$PWD/build/Relay.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$app_dir/Contents/Frameworks"
cp "$binary_dir/Relay" "$app_dir/Contents/MacOS/Relay.new"
mv -f "$app_dir/Contents/MacOS/Relay.new" "$app_dir/Contents/MacOS/Relay"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
cp Resources/Relay.icns "$app_dir/Contents/Resources/Relay.icns"
cp Resources/ThirdPartyNotices.txt Resources/LiteRT-LM-LICENSE.txt "$app_dir/Contents/Resources/"
if [ -d "Vendor/agent-desktop" ]; then
    for helper_bin in Vendor/agent-desktop/bin/agent-desktop Vendor/agent-desktop/bin/agent-desktop-macos-helper; do
        if [ -f "$helper_bin" ]; then
            cp "$helper_bin" "$app_dir/Contents/MacOS/$(basename "$helper_bin").new"
            chmod +x "$app_dir/Contents/MacOS/$(basename "$helper_bin").new"
            /usr/bin/codesign --force --sign "$relay_codesign_identity" "$app_dir/Contents/MacOS/$(basename "$helper_bin").new"
            mv -f "$app_dir/Contents/MacOS/$(basename "$helper_bin").new" "$app_dir/Contents/MacOS/$(basename "$helper_bin")"
        fi
    done
    for ffi_file in Vendor/agent-desktop/lib/libagent_desktop_ffi.dylib Vendor/agent-desktop/lib/agent-desktop-macos-helper; do
        if [ -f "$ffi_file" ]; then
            cp "$ffi_file" "$app_dir/Contents/Frameworks/$(basename "$ffi_file").new"
            chmod +x "$app_dir/Contents/Frameworks/$(basename "$ffi_file").new"
            /usr/bin/codesign --force --sign "$relay_codesign_identity" "$app_dir/Contents/Frameworks/$(basename "$ffi_file").new"
            mv -f "$app_dir/Contents/Frameworks/$(basename "$ffi_file").new" "$app_dir/Contents/Frameworks/$(basename "$ffi_file")"
        fi
    done
    [ -f "Vendor/agent-desktop/VERSION" ] && cp "Vendor/agent-desktop/VERSION" "$app_dir/Contents/Resources/agent-desktop-version.txt"
    [ -f "Vendor/agent-desktop/LICENSE" ] && cp "Vendor/agent-desktop/LICENSE" "$app_dir/Contents/Resources/agent-desktop-LICENSE.txt"
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
    cp -R "$framework" "$app_dir/Contents/Frameworks/"
done < <(find "$binary_dir" -maxdepth 1 -type d -name '*.framework')
for library in "$binary_dir"/*.dylib; do
    [ -f "$library" ] || continue
    cp "$library" "$app_dir/Contents/Frameworks/$(basename "$library").new"
    /usr/bin/codesign --force --sign "$relay_codesign_identity" "$app_dir/Contents/Frameworks/$(basename "$library").new"
    mv -f "$app_dir/Contents/Frameworks/$(basename "$library").new" "$app_dir/Contents/Frameworks/$(basename "$library")"
done
/usr/bin/install_name_tool -add_rpath '@executable_path/../Frameworks' "$app_dir/Contents/MacOS/Relay" 2>/dev/null || true
for resource in "$binary_dir"/*.bundle; do
    [ -d "$resource" ] && cp -R "$resource" "$app_dir/Contents/Resources/"
done
/usr/bin/codesign --force --deep --sign "$relay_codesign_identity" "$app_dir"
/usr/bin/codesign --verify --deep --strict "$app_dir"
printf 'Built %s\n' "$app_dir"
