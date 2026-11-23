#!/bin/sh
# Updates an already-registered com.lucaslima.kindlemap WAF in place and
# installs the GPS receiver, router + library scriptlets. Does not touch
# appreg.db or the rootfs. Run on the Kindle from the unpacked kindle-map folder:
#   sh update-waf.sh
#
# Optional in the same folder (from build/): pack/ (tiles z9-17) and
# data/ (graph.json, search.json). They go to /mnt/us/kindlemap (user storage)
# and the app reaches the pack through a map-pack symlink.

set -eu

SRC=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APPDIR=/var/local/mesquite/kindlemap
BASE=/mnt/us/kindlemap
DOCS=/mnt/us/documents
BACKUP_DIR=/mnt/us/kindlemap_backups

for f in config.xml index.html app-dom.js receiver/gpsd.lua receiver/nav.lua receiver/router.lua \
         receiver/start-gps.sh receiver/stop-gps.sh; do
    [ -f "$SRC/$f" ] || { echo "Missing $SRC/$f"; exit 1; }
done
[ -d "$APPDIR" ] || { echo "$APPDIR not found; run install-waf.sh first."; exit 1; }

STAMP=$(date +%Y%m%d-%H%M%S)
mkdir -p "$BACKUP_DIR"
( cd "$APPDIR" && tar -cf "$BACKUP_DIR/kindlemap-waf-before-$STAMP.tar" --exclude=map-pack . ) || true

cp "$SRC/config.xml" "$SRC/index.html" "$SRC/app-dom.js" "$APPDIR/"
rm -f "$APPDIR/app.js" "$APPDIR/style.css"
if [ -d "$SRC/icons" ]; then
    rm -rf "$APPDIR/icons"
    cp -R "$SRC/icons" "$APPDIR/icons"
fi

mkdir -p "$BASE"
# Large pack (z9-17) lives in user storage; the app reads it via a symlink.
if [ -d "$SRC/pack" ]; then
    rm -rf "$BASE/pack.new"
    cp -R "$SRC/pack" "$BASE/pack.new"
    rm -rf "$BASE/pack"
    mv "$BASE/pack.new" "$BASE/pack"
fi
if [ -f "$BASE/pack/manifest.js" ]; then
    if [ ! -L "$APPDIR/map-pack" ]; then
        rm -rf "$APPDIR/map-pack"
    fi
    ln -sfn "$BASE/pack" "$APPDIR/map-pack"
elif [ -d "$SRC/map-pack" ]; then
    rm -rf "$APPDIR/map-pack"
    cp -R "$SRC/map-pack" "$APPDIR/map-pack"
fi

if [ -d "$SRC/data" ]; then
    mkdir -p "$BASE/data"
    cp "$SRC"/data/*.json "$BASE/data/"
fi

cp "$SRC/receiver/gpsd.lua" "$SRC/receiver/nav.lua" "$SRC/receiver/router.lua" \
   "$SRC/receiver/start-gps.sh" "$SRC/receiver/stop-gps.sh" "$BASE/"

# Library scriptlets (tap in the library to run).
cp "$SRC/receiver/start-gps.sh" "$DOCS/kindlemap-gps-iniciar.sh"
cp "$SRC/receiver/stop-gps.sh" "$DOCS/kindlemap-gps-parar.sh"
[ -f "$SRC/receiver/update-from-usb.sh" ] && cp "$SRC/receiver/update-from-usb.sh" "$DOCS/kindlemap-atualizar.sh"

# Runtime files written by the receiver/router in RAM, reached from the app.
mkdir -p /tmp/kindlemap
for f in location.js route.js; do
    [ -L "$APPDIR/$f" ] || { rm -f "$APPDIR/$f"; ln -s "/tmp/kindlemap/$f" "$APPDIR/$f"; }
done

echo "Updated $APPDIR and $BASE. Backup: $BACKUP_DIR/kindlemap-waf-before-$STAMP.tar"
