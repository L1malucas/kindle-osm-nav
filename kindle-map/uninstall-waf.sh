#!/bin/sh
# Name: Remove Kindle Map Preview
# Author: Lucas
# DontUseFBInk

set -eu
APP_ID="com.lucaslima.kindlemap"
TARGET_DIR="/var/local/mesquite/kindlemap"
DB="/var/local/appreg.db"

if [ ! -f "$DB" ]; then
    echo "appreg database not found; nothing changed."
    exit 1
fi

sqlite3 -bail "$DB" <<SQL
BEGIN;
DELETE FROM properties WHERE handlerId='$APP_ID';
DELETE FROM handlerIds WHERE handlerId='$APP_ID';
COMMIT;
SQL

if [ -d "$TARGET_DIR" ]; then
    rm -rf "$TARGET_DIR"
fi

echo "Removed only $APP_ID and $TARGET_DIR. OSM packs/backups under /mnt/us are untouched."
