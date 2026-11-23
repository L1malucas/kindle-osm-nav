#!/bin/sh
# Name: KindleMap - Atualizar
# Author: Lucas
# DontUseFBInk
#
# Installs the files copied over USB to /mnt/us/kindlemap_staging (no SSH
# needed), restarts the GPS receiver, opens the map and saves diagnostics to
# /mnt/us/kindlemap_diag for the next USB connection.

if [ "${1:-}" != "--detached" ]; then
    if command -v setsid >/dev/null 2>&1; then
        setsid sh "$0" --detached >/dev/null 2>&1 </dev/null &
    else
        nohup sh "$0" --detached >/dev/null 2>&1 </dev/null &
    fi
    exit 0
fi

STAGING=/mnt/us/kindlemap_staging
DIAG=/mnt/us/kindlemap_diag
mkdir -p "$DIAG"
LOG="$DIAG/update.log"
{
    echo "=== update $(date)"
    if [ -f "$STAGING/update-waf.sh" ]; then
        sh "$STAGING/update-waf.sh" && echo "UPDATE_OK" || echo "UPDATE_FAILED"
    else
        echo "no staging folder"
    fi
} >>"$LOG" 2>&1

# Diagnostics (overwritten each run; RAM logs would be lost on reboot).
{
    echo "=== $(date)"
    echo "--- activeApp: $(lipc-get-prop com.lab126.appmgrd activeApp 2>&1)"
    echo "--- statusbar: $(status statusbar 2>&1)"
    echo "--- wlan0"; ip -4 -o addr show wlan0 2>&1
    echo "--- ssh processes"; ps | grep -E "dropbear|sshd|jobman" | grep -v grep
    echo "--- listening"; netstat -ltn 2>&1 | head -20
    echo "--- iptables"; iptables -S INPUT 2>&1 | grep -E "dport (22|8765)"
    echo "--- jobman ssh config"; cat /mnt/us/jobman/ssh/etc/config.toml 2>&1 | head -30
    echo "--- jobman files"; ls -la /mnt/us/jobman /mnt/us/jobman/ssh 2>&1 | head -40
    echo "--- messages (ssh/jobman)"; grep -iE "dropbear|jobman|ssh" /var/log/messages 2>/dev/null | tail -40
    echo "--- app events"; cat /tmp/kindlemap/events.log 2>&1 | tail -40
    echo "--- X touch events"; grep -E "^(ButtonPress|ButtonRelease|MotionNotify)" /tmp/kindlemap/xev.log 2>/dev/null | sort | uniq -c
} >"$DIAG/diag.txt" 2>&1

sh /mnt/us/kindlemap/stop-gps.sh >/dev/null 2>&1
rm -f /tmp/kindlemap/cmd.json
sh /mnt/us/kindlemap/start-gps.sh --detached >>"$LOG" 2>&1
