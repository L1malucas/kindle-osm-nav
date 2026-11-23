#!/bin/sh
# Name: Install Kindle Map Preview
# Author: Lucas
# DontUseFBInk

set -eu

APP_ID="com.lucaslima.kindlemap"
SOURCE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TARGET_DIR="/var/local/mesquite/kindlemap"
DB="/var/local/appreg.db"
BACKUP_DIR="/mnt/us/kindlemap_backups"

if [ ! -d "/var/local/mesquite" ] || [ ! -f "$DB" ]; then
    echo "Mesquite/appreg database not found; stopping without changes."
    exit 1
fi

if sqlite3 -readonly "$DB" "SELECT 1 FROM handlerIds WHERE handlerId='$APP_ID' LIMIT 1;" | grep -q 1; then
    echo "$APP_ID is already registered; use uninstall-waf.sh first or update deliberately."
    exit 1
fi

if [ -e "$TARGET_DIR" ]; then
    echo "$TARGET_DIR already exists; refusing to overwrite it."
    exit 1
fi

for f in config.xml index.html app-dom.js; do
    if [ ! -f "$SOURCE_DIR/$f" ]; then
        echo "Missing required file: $SOURCE_DIR/$f"
        exit 1
    fi
done

mkdir -p "$BACKUP_DIR"
BACKUP_FILE="$BACKUP_DIR/appreg.db.before-kindlemap-$(date +%Y%m%d-%H%M%S)"
cp -p "$DB" "$BACKUP_FILE"

mkdir -p "$TARGET_DIR"
cp -p "$SOURCE_DIR/config.xml" "$SOURCE_DIR/index.html" "$SOURCE_DIR/app-dom.js" "$TARGET_DIR/"
if [ -d "$SOURCE_DIR/map-pack" ]; then
    cp -R "$SOURCE_DIR/map-pack" "$TARGET_DIR/map-pack"
fi

sqlite3 -bail "$DB" <<SQL
BEGIN;
INSERT OR IGNORE INTO interfaces(interface) VALUES('application');
INSERT OR IGNORE INTO handlerIds(handlerId) VALUES('$APP_ID');
INSERT OR REPLACE INTO properties(handlerId,name,value) VALUES('$APP_ID','lipcId','$APP_ID');
INSERT OR REPLACE INTO properties(handlerId,name,value) VALUES('$APP_ID','command','/usr/bin/mesquite -l $APP_ID -c file://$TARGET_DIR/');
INSERT OR REPLACE INTO properties(handlerId,name,value) VALUES('$APP_ID','framework','');
INSERT OR REPLACE INTO properties(handlerId,name,value) VALUES('$APP_ID','unloadPolicy','unloadOnPause');
COMMIT;
SQL

echo "Registered $APP_ID. appreg backup: $BACKUP_FILE"
echo "Launching preview..."
sleep 2
lipc-set-prop com.lab126.appmgrd start "app://$APP_ID"
