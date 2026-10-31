#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
VENDOR_DIR="$PWD/Vendor/agent-desktop"
mkdir -p "$VENDOR_DIR/bin" "$VENDOR_DIR/lib" "$VENDOR_DIR/include"

REQUESTED_TAG="${1:-latest}"
ARCH="$(uname -m)"
if [ "$ARCH" = "arm64" ] || [ "$ARCH" = "aarch64" ]; then
    TARGET="aarch64-apple-darwin"
else
    TARGET="x86_64-apple-darwin"
fi

echo "→ Resolving vercel-labs/agent-desktop ($REQUESTED_TAG) for $TARGET..."
if [ "$REQUESTED_TAG" = "latest" ]; then
    TAG="$(curl -fsSL https://api.github.com/repos/vercel-labs/agent-desktop/releases/latest | python3 -c 'import sys, json; print(json.load(sys.stdin)["tag_name"])')"
else
    TAG="$REQUESTED_TAG"
fi

CLI_ARCHIVE="agent-desktop-${TAG}-${TARGET}.tar.gz"
FFI_ARCHIVE="agent-desktop-ffi-${TAG}-${TARGET}.tar.gz"
BASE_URL="https://github.com/vercel-labs/agent-desktop/releases/download/${TAG}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "→ Downloading $CLI_ARCHIVE, $FFI_ARCHIVE, and checksums.txt..."
curl -fsSL "$BASE_URL/$CLI_ARCHIVE" -o "$TMP_DIR/$CLI_ARCHIVE"
curl -fsSL "$BASE_URL/$FFI_ARCHIVE" -o "$TMP_DIR/$FFI_ARCHIVE"
curl -fsSL "$BASE_URL/checksums.txt" -o "$TMP_DIR/checksums.txt"

echo "→ Verifying SHA-256 checksums..."
(
    cd "$TMP_DIR"
    EXPECTED_CLI="$(grep "  $CLI_ARCHIVE" checksums.txt | awk '{print $1}' | tr -d '\r')"
    ACTUAL_CLI="$(shasum -a 256 "$CLI_ARCHIVE" | awk '{print $1}')"
    if [ "$EXPECTED_CLI" != "$ACTUAL_CLI" ]; then
        echo "ERROR: SHA-256 mismatch for $CLI_ARCHIVE (expected $EXPECTED_CLI, got $ACTUAL_CLI)" >&2
        exit 1
    fi

    EXPECTED_FFI="$(grep "  $FFI_ARCHIVE" checksums.txt | awk '{print $1}' | tr -d '\r')"
    ACTUAL_FFI="$(shasum -a 256 "$FFI_ARCHIVE" | awk '{print $1}')"
    if [ "$EXPECTED_FFI" != "$ACTUAL_FFI" ]; then
        echo "ERROR: SHA-256 mismatch for $FFI_ARCHIVE (expected $EXPECTED_FFI, got $ACTUAL_FFI)" >&2
        exit 1
    fi
)
echo "✓ Checksums verified for $TAG."

tar -xzf "$TMP_DIR/$CLI_ARCHIVE" -C "$TMP_DIR"
tar -xzf "$TMP_DIR/$FFI_ARCHIVE" -C "$TMP_DIR"

FFI_EXTRACTED="$TMP_DIR/agent-desktop-ffi-${TAG}-${TARGET}"

cp "$TMP_DIR/agent-desktop" "$VENDOR_DIR/bin/agent-desktop"
cp "$TMP_DIR/agent-desktop-macos-helper" "$VENDOR_DIR/bin/agent-desktop-macos-helper"
chmod +x "$VENDOR_DIR/bin/agent-desktop" "$VENDOR_DIR/bin/agent-desktop-macos-helper"

cp "$FFI_EXTRACTED/lib/libagent_desktop_ffi.dylib" "$VENDOR_DIR/lib/libagent_desktop_ffi.dylib"
cp "$FFI_EXTRACTED/lib/agent-desktop-macos-helper" "$VENDOR_DIR/lib/agent-desktop-macos-helper"
cp "$FFI_EXTRACTED/include/agent_desktop.h" "$VENDOR_DIR/include/agent_desktop.h"
cp "$FFI_EXTRACTED/LICENSE" "$VENDOR_DIR/LICENSE"
chmod +x "$VENDOR_DIR/lib/libagent_desktop_ffi.dylib" "$VENDOR_DIR/lib/agent-desktop-macos-helper"

printf '%s\n' "${TAG#v}" > "$VENDOR_DIR/VERSION"

echo "✓ Installed vercel-labs/agent-desktop $TAG into $VENDOR_DIR"
"$VENDOR_DIR/bin/agent-desktop" version
