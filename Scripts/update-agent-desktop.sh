#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
VENDOR_DIR="$PWD/Vendor/agent-desktop"

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
if [[ ! "$TAG" =~ ^[vV]?[0-9][A-Za-z0-9._+-]*$ ]]; then
    echo "ERROR: Invalid agent-desktop release tag." >&2
    exit 1
fi

CLI_ARCHIVE="agent-desktop-${TAG}-${TARGET}.tar.gz"
FFI_ARCHIVE="agent-desktop-ffi-${TAG}-${TARGET}.tar.gz"
BASE_URL="https://github.com/vercel-labs/agent-desktop/releases/download/${TAG}"

mkdir -p "$PWD/Vendor"
TMP_DIR="$(mktemp -d "$PWD/Vendor/.agent-desktop-update.XXXXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "→ Downloading $CLI_ARCHIVE, $FFI_ARCHIVE, and checksums.txt..."
curl -fsSL "$BASE_URL/$CLI_ARCHIVE" -o "$TMP_DIR/$CLI_ARCHIVE"
curl -fsSL "$BASE_URL/$FFI_ARCHIVE" -o "$TMP_DIR/$FFI_ARCHIVE"
curl -fsSL "$BASE_URL/checksums.txt" -o "$TMP_DIR/checksums.txt"

echo "→ Verifying SHA-256 checksums..."
(
    cd "$TMP_DIR"
    EXPECTED_CLI="$(awk -v archive="$CLI_ARCHIVE" '{sub(/\r$/, ""); if (NF == 2 && $2 == archive) print $1}' checksums.txt)"
    ACTUAL_CLI="$(shasum -a 256 "$CLI_ARCHIVE" | awk '{print $1}')"
    if [ "$EXPECTED_CLI" != "$ACTUAL_CLI" ]; then
        echo "ERROR: SHA-256 mismatch for $CLI_ARCHIVE (expected $EXPECTED_CLI, got $ACTUAL_CLI)" >&2
        exit 1
    fi

    EXPECTED_FFI="$(awk -v archive="$FFI_ARCHIVE" '{sub(/\r$/, ""); if (NF == 2 && $2 == archive) print $1}' checksums.txt)"
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
STAGED_DIR="$TMP_DIR/staged"
mkdir -p "$STAGED_DIR/bin" "$STAGED_DIR/lib" "$STAGED_DIR/include"

install -m 755 "$TMP_DIR/agent-desktop" "$STAGED_DIR/bin/agent-desktop"
install -m 755 "$TMP_DIR/agent-desktop-macos-helper" "$STAGED_DIR/bin/agent-desktop-macos-helper"

install -m 755 "$FFI_EXTRACTED/lib/libagent_desktop_ffi.dylib" "$STAGED_DIR/lib/libagent_desktop_ffi.dylib"
install -m 755 "$FFI_EXTRACTED/lib/agent-desktop-macos-helper" "$STAGED_DIR/lib/agent-desktop-macos-helper"
install -m 644 "$FFI_EXTRACTED/include/agent_desktop.h" "$STAGED_DIR/include/agent_desktop.h"
install -m 644 "$FFI_EXTRACTED/LICENSE" "$STAGED_DIR/LICENSE"

VERSION="${TAG#[vV]}"
"$STAGED_DIR/bin/agent-desktop" version | python3 -c '
import json, sys
result = json.load(sys.stdin)
if result.get("ok") is not True or result.get("data", {}).get("version") != sys.argv[1]:
    sys.exit("ERROR: The staged CLI did not report the expected release version.")
' "$VERSION"
printf '%s\n' "$VERSION" > "$STAGED_DIR/VERSION"

python3 Scripts/agent-desktop-vendor.py promote "$VENDOR_DIR" "$STAGED_DIR"
echo "✓ Installed vercel-labs/agent-desktop $TAG into $VENDOR_DIR"
