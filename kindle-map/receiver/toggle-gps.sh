#!/bin/sh
# Name: KindleMap GPS
# Author: Lucas
# DontUseFBInk
#
# One library shortcut: starts the GPS receiver and opens the map when it is
# stopped; stops it (and reverts everything) when it is running.

BASE=/mnt/us/kindlemap
PIDFILE=/tmp/kindlemap/tcpsvd.pid

running=0
if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    running=1
fi

if [ "$running" -eq 1 ]; then
    sh "$BASE/stop-gps.sh" >/dev/null 2>&1
    # Short notice at the bottom of the screen (cleared on the next page refresh).
    eips 1 38 "KindleMap GPS desligado" >/dev/null 2>&1
else
    # start-gps.sh detaches itself from the library launcher and opens the map.
    sh "$BASE/start-gps.sh"
fi
