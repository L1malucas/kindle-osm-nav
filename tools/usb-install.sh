#!/bin/sh
# Copies the KindleMap app, map pack and receiver to a Kindle mounted over USB
# as a USB drive (macOS: /Volumes/Kindle). Then eject, and on the Kindle tap
# "KindleMap - Atualizar" in the library. No SSH required.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SRC="$ROOT/kindle-map"
VOL="${1:-/Volumes/Kindle}"

[ -d "$VOL/documents" ] || { echo "Kindle not mounted at $VOL"; exit 1; }

DEST="$VOL/kindlemap_staging"
rm -rf "$DEST"
mkdir -p "$DEST"
COPYFILE_DISABLE=1 tar -C "$SRC" -cf - --exclude='._*' --exclude='.DS_Store' \
    index.html app-dom.js config.xml update-waf.sh receiver icons | tar -C "$DEST" -xf -
# Generated data (tools/build_*.py or the release zip), if present.
for d in pack data; do
    if [ -d "$ROOT/build/$d" ]; then
        COPYFILE_DISABLE=1 tar -C "$ROOT/build" -cf - --exclude='._*' "$d" | tar -C "$DEST" -xf -
    fi
done
cp "$SRC/receiver/update-from-usb.sh" "$VOL/documents/kindlemap-atualizar.sh"

# Show the last diagnostics written on the Kindle, if any.
if [ -f "$VOL/kindlemap_diag/diag.txt" ]; then
    echo "--- previous diagnostics: $VOL/kindlemap_diag/diag.txt"
fi
find "$VOL" -name '._*' -path '*kindlemap*' -delete 2>/dev/null || true
sync
echo "Copied to $DEST. Eject the Kindle, then tap 'KindleMap - Atualizar' in the library."
