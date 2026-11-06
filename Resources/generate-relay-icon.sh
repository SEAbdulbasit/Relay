#!/bin/bash
set -euo pipefail

resources=$(cd -- "$(dirname -- "$0")" && pwd)
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
iconset="$scratch/Relay.iconset"
mkdir "$iconset"

/usr/bin/sips -s format png "$resources/Relay-icon.svg" --out "$scratch/Relay-icon.png" >/dev/null
for size in 16 32 128 256 512; do
    /usr/bin/sips -z "$size" "$size" "$scratch/Relay-icon.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    retina=$((size * 2))
    /usr/bin/sips -z "$retina" "$retina" "$scratch/Relay-icon.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/iconutil --convert icns --output "$scratch/Relay.icns" "$iconset"

cp "$scratch/Relay.icns" "$resources/Relay.icns"
