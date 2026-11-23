#!/usr/bin/env python3
"""Simulate an Android phone (GPSLogger "Custom URL" mode) sending a moving
position to the Kindle receiver, to test the map updating without a phone.

Route: Salvador waterfront, Farol da Barra -> Ondina -> Rio Vermelho ->
Amaralina -> Pituba -> Jardim de Alah.

  python3 tools/simulate_android.py --host IP_DO_KINDLE --token TOKEN
"""

import argparse
import math
import sys
import time
import json
import urllib.error
import urllib.parse
import urllib.request

ROUTE = [
    (-13.0104, -38.5324),  # Farol da Barra
    (-13.0090, -38.5230),
    (-13.0085, -38.5135),  # Ondina
    (-13.0110, -38.5010),
    (-13.0119, -38.4905),  # Rio Vermelho
    (-13.0120, -38.4810),
    (-13.0107, -38.4720),  # Amaralina
    (-13.0050, -38.4630),
    (-13.0005, -38.4560),  # Pituba
    (-12.9965, -38.4400),  # Jardim de Alah
]


def distance_m(a, b):
    r = 6371000.0
    la1, lo1, la2, lo2 = map(math.radians, (a[0], a[1], b[0], b[1]))
    h = math.sin((la2 - la1) / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin((lo2 - lo1) / 2) ** 2
    return 2 * r * math.asin(min(1.0, math.sqrt(h)))


def bearing_deg(a, b):
    la1, lo1, la2, lo2 = map(math.radians, (a[0], a[1], b[0], b[1]))
    y = math.sin(lo2 - lo1) * math.cos(la2)
    x = math.cos(la1) * math.sin(la2) - math.sin(la1) * math.cos(la2) * math.cos(lo2 - lo1)
    return (math.degrees(math.atan2(y, x)) + 360.0) % 360.0


def positions(speed_mps, interval_s):
    """Yield (lat, lon, course) every `speed*interval` metres along ROUTE."""
    step = speed_mps * interval_s
    carry = 0.0
    for a, b in zip(ROUTE, ROUTE[1:]):
        seg = distance_m(a, b)
        course = bearing_deg(a, b)
        d = carry
        while d < seg:
            f = d / seg
            yield a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f, course
            d += step
        carry = d - seg
    yield ROUTE[-1][0], ROUTE[-1][1], bearing_deg(ROUTE[-2], ROUTE[-1])


def http_json(url, data=None, timeout=10):
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"} if data else {})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, json.loads(r.read().decode("utf-8") or "{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read().decode("utf-8") or "{}")


def route_positions(route, speed_mps, interval_s, deviate_at=0):
    """Walk the Kindle's own route geometry; optionally leave it for 4 fixes."""
    flat = route["pts"]
    pts = [(flat[i] / 1e6, flat[i + 1] / 1e6) for i in range(0, len(flat), 2)]
    step = speed_mps * interval_s
    out = []
    carry = 0.0
    for a, b in zip(pts, pts[1:]):
        seg = distance_m(a, b)
        course = bearing_deg(a, b)
        d = carry
        while d < seg:
            f = d / seg
            out.append((a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f, course))
            d += step
        carry = d - seg
    out.append((pts[-1][0], pts[-1][1], bearing_deg(pts[-2], pts[-1])))
    if deviate_at and deviate_at < len(out):
        lat, lon, course = out[deviate_at]
        side = math.radians(course + 90)
        for k in range(4):  # 90 m to the side, 4 fixes
            dlat = math.cos(side) * 90 / 111320
            dlon = math.sin(side) * 90 / (111320 * math.cos(math.radians(lat)))
            out.insert(deviate_at + k, (lat + dlat, lon + dlon, course))
    return out


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--host", required=True)
    p.add_argument("--port", type=int, default=8765)
    p.add_argument("--token", required=True)
    p.add_argument("--speed-kmh", type=float, default=40.0)
    p.add_argument("--interval", type=float, default=3.0, help="seconds between fixes")
    p.add_argument("--max-fixes", type=int, default=0, help="stop after N fixes (0 = whole route)")
    p.add_argument("--route-to", help="LAT,LON: ask the Kindle for a route there, then drive it")
    p.add_argument("--from", dest="from_", default="-13.0104,-38.5324", help="LAT,LON start (default Farol da Barra)")
    p.add_argument("--profile", choices=("bike", "car"), default="bike")
    p.add_argument("--label", default="Destino de teste")
    p.add_argument("--follow-route", action="store_true", help="drive the route already active on the Kindle")
    p.add_argument("--deviate-at", type=int, default=0, help="leave the route at fix N (tests rerouting)")
    args = p.parse_args()

    speed = args.speed_kmh / 3.6
    base = "http://%s:%d" % (args.host, args.port)
    tok = urllib.parse.quote(args.token)
    walk = positions(speed, args.interval)
    if args.route_to:
        flat, flon = map(float, args.from_.split(","))
        tlat, tlon = map(float, args.route_to.split(","))
        urllib.request.urlopen("%s/api/update?token=%s&lat=%.6f&lon=%.6f&spd=0&src=android-sim" % (base, tok, flat, flon), timeout=5)
        st, res = http_json("%s/api/route?token=%s" % (base, tok), json.dumps(
            {"lat": tlat, "lon": tlon, "label": args.label, "profile": args.profile}).encode())
        print("route request ->", st, res, flush=True)
        args.follow_route = True
        for _ in range(30):
            time.sleep(1)
            st, nav = http_json("%s/api/nav?token=%s" % (base, tok))
            if nav.get("state") in ("active", "error"):
                break
        print("nav:", nav.get("state"), nav.get("error", ""), flush=True)
        if nav.get("state") != "active":
            return 1
    if args.follow_route:
        st, route = http_json("%s/api/route?token=%s" % (base, tok))
        if st != 200:
            print("no route on the Kindle:", route)
            return 1
        print("route %s: %.1f km, %d maneuvers" % (route["profile"], route["dist_m"] / 1000.0, len(route["maneuvers"])), flush=True)
        walk = route_positions(route, speed, args.interval, args.deviate_at)
    sent = 0
    for lat, lon, course in walk:
        query = urllib.parse.urlencode({
            "token": args.token, "lat": "%.6f" % lat, "lon": "%.6f" % lon,
            "spd": "%.2f" % speed, "dir": "%.0f" % course, "acc": "6", "src": "android-sim",
        })
        url = "http://%s:%d/api/update?%s" % (args.host, args.port, query)
        started = time.time()
        try:
            with urllib.request.urlopen(url, timeout=5) as r:
                status = r.status
        except Exception as exc:  # keep going like a phone would
            status = "ERR %s" % exc
        sent += 1
        line = "%3d %s %.5f,%.5f %3.0f° -> %s" % (sent, time.strftime("%H:%M:%S"), lat, lon, course, status)
        if args.follow_route:
            _, nav = http_json("%s/api/nav?token=%s" % (base, tok))
            nx = nav.get("next") or {}
            line += " | %s %s %sm %s" % (nav.get("state"), nx.get("mod", ""), nx.get("dist_m", ""), nx.get("name", ""))
        print(line, flush=True)
        if args.max_fixes and sent >= args.max_fixes:
            break
        time.sleep(max(0.0, args.interval - (time.time() - started)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
