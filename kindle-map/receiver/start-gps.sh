#!/bin/sh
# Name: KindleMap GPS - Iniciar
# Author: Lucas
# DontUseFBInk
#
# Starts the local GPS receiver and opens the map app.
# Everything here is undone by stop-gps.sh or by a reboot:
#   - one iptables ACCEPT rule for TCP 8765 on wlan0 (runtime only)
#   - tcpsvd process + state in /tmp (RAM)
#   - preventScreenSaver=1 only if /mnt/us/kindlemap/keep-awake exists
# Run it AFTER connecting the Kindle to the phone hotspot / Wi-Fi.

# Detach from the library's scriptlet launcher, otherwise it can bring the
# home screen back over the map (same pattern Jobman uses).
if [ "${1:-}" != "--detached" ] && [ "${1:-}" != "--no-launch" ]; then
    if command -v setsid >/dev/null 2>&1; then
        setsid sh "$0" --detached >/dev/null 2>&1 </dev/null &
    else
        nohup sh "$0" --detached >/dev/null 2>&1 </dev/null &
    fi
    exit 0
fi

BASE=/mnt/us/kindlemap
RUN=/tmp/kindlemap
PORT=8765
APP_ID=com.lucaslima.kindlemap
APPDIR=/var/local/mesquite/kindlemap
PIDFILE="$RUN/tcpsvd.pid"

mkdir -p "$RUN"

if [ ! -f "$BASE/gpsd.lua" ]; then
    echo "Missing $BASE/gpsd.lua"
    exit 1
fi

# Pairing token: 6 hex chars, created once, shown on the Kindle screen.
# Delete $BASE/token to rotate it.
if [ ! -s "$BASE/token" ]; then
    head -c 3 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$BASE/token"
fi

# Firewall: KT4 drops inbound Wi-Fi by default (only SSH 22 is open).
if ! iptables -C INPUT -i wlan0 -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null; then
    iptables -A INPUT -i wlan0 -p tcp --dport "$PORT" -j ACCEPT
fi

running=0
if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    running=1
fi
if [ "$running" -eq 0 ]; then
    KINDLEMAP_BASE="$BASE" KINDLEMAP_RUN="$RUN" \
        nohup tcpsvd -c 8 0 "$PORT" lua "$BASE/gpsd.lua" >/dev/null 2>"$RUN/gpsd.err" &
    echo $! > "$PIDFILE"
fi

# Local fallback channel for the WAF (file:// <script>), in case Mesquite
# blocks XHR to 127.0.0.1.
KINDLEMAP_BASE="$BASE" KINDLEMAP_RUN="$RUN" lua "$BASE/gpsd.lua" --write-status
for f in location.js route.js; do
    if [ -d "$APPDIR" ] && [ ! -L "$APPDIR/$f" ]; then
        rm -f "$APPDIR/$f"
        ln -s "$RUN/$f" "$APPDIR/$f"
    fi
done

# Opt-in only: preventScreenSaver also disables the power button sleep, so it
# is never set by default. Create $BASE/keep-awake to keep the screen on.
if [ -f "$BASE/keep-awake" ]; then
    lipc-set-prop com.lab126.powerd preventScreenSaver 1 2>/dev/null
fi

IP=$(ip -4 -o addr show wlan0 2>/dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p')
echo "Receiver: http://${IP:-?}:$PORT  token: $(cat "$BASE/token")"

if [ "${1:-}" != "--no-launch" ]; then
    # Jobman stops the statusbar; without it Mesquite apps only repaint
    # dirty regions (screen looks "grouped"/half-drawn). Bring it back.
    if ! status statusbar 2>/dev/null | grep -q running; then
        start statusbar >/dev/null 2>&1
        sleep 2
    fi
    sleep 2
    lipc-set-prop com.lab126.appmgrd start "app://$APP_ID"
fi
