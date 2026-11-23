#!/bin/sh
# Name: KindleMap GPS - Parar
# Author: Lucas
# DontUseFBInk
#
# Stops the receiver and reverts everything start-gps.sh changed at runtime.

RUN=/tmp/kindlemap
PORT=8765
PIDFILE="$RUN/tcpsvd.pid"

if [ -f "$PIDFILE" ]; then
    kill "$(cat "$PIDFILE")" 2>/dev/null
    rm -f "$PIDFILE"
fi
# Catch a receiver started by hand.
for pid in $(pgrep -f "tcpsvd .* $PORT lua"); do
    kill "$pid" 2>/dev/null
done

while iptables -C INPUT -i wlan0 -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null; do
    iptables -D INPUT -i wlan0 -p tcp --dport "$PORT" -j ACCEPT
done

lipc-set-prop com.lab126.powerd preventScreenSaver 0 2>/dev/null

# Last position stays only in RAM; drop it.
rm -f "$RUN/location.json" "$RUN/location.js" "$RUN/nav.json" "$RUN/route.json" "$RUN/route.js" "$RUN/route.lock"

echo "KindleMap GPS stopped; port $PORT closed, screensaver restored."
