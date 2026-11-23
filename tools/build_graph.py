#!/usr/bin/env python3
"""Build the offline routing graph (bike + car) for the Kindle router.

Output build/data/graph.json, flat arrays read by Lua cjson on the KT4:

  nodes:   n_lat[i], n_lon[i]                 (int, degrees * 1e6), n_deg[i] incident edges
  edges:   e_u, e_v, e_len (m), e_name (index into names, 0 = unnamed),
           e_cls (index into classes), e_flags (bits below),
           e_cost_bike, e_cost_car            (seconds * 10, 0 = forbidden)
           e_g0, e_gn                         (offset/count into g_lat/g_lon: points between u and v)
  adj:     adj_start[i]..adj_start[i+1]-1 -> adj_edge (signed: +e = u->v, -e = v->u; edges 1-based)
  grid:    "ix:iy" -> [edge ids]  (cell = GRID_DEG degrees) for snapping
Flags: 1 bike fwd, 2 bike back, 4 car fwd, 8 car back, 16 roundabout.
"""

from __future__ import annotations

import argparse
import heapq
import json
import math
import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from osm_extract import PROJECT_ROOT, haversine_m, load_extract  # noqa: E402

DEFAULT_OUT = PROJECT_ROOT / "build" / "data" / "graph.json"
GRID_DEG = 0.002  # ~220 m
MIN_COMPONENT = 150

# m/s and cost factor (>1 = avoid) per class
BIKE = {
    "primary": (5.0, 1.6), "primary_link": (5.0, 1.6), "secondary": (5.0, 1.25), "secondary_link": (5.0, 1.25),
    "tertiary": (5.0, 1.05), "tertiary_link": (5.0, 1.05), "unclassified": (5.0, 1.0), "residential": (5.0, 1.0),
    "living_street": (4.5, 1.0), "service": (4.5, 1.2), "track": (3.5, 1.4), "cycleway": (5.5, 0.75),
    "path": (4.0, 1.4), "footway": (2.5, 2.5), "pedestrian": (2.5, 2.0), "bridleway": (3.0, 2.0),
}
CAR = {
    "motorway": (25.0, 1.0), "motorway_link": (15.0, 1.0), "trunk": (19.0, 1.0), "trunk_link": (12.0, 1.0),
    "primary": (14.0, 1.0), "primary_link": (11.0, 1.0), "secondary": (12.0, 1.0), "secondary_link": (10.0, 1.0),
    "tertiary": (10.0, 1.05), "tertiary_link": (9.0, 1.05), "unclassified": (8.0, 1.15), "residential": (7.0, 1.2),
    "living_street": (4.0, 1.6), "service": (4.0, 2.0),
}
BIKE_MAX, CAR_MAX = 5.5, 25.0
YES = ("yes", "true", "1", "designated", "permissive")


def oneway_dir(tags):
    """+1 forward only, -1 backward only, 0 both (for motor traffic)."""
    v = tags.get("oneway", "")
    if v in ("yes", "true", "1"):
        return 1
    if v == "-1" or v == "reverse":
        return -1
    if tags.get("junction") in ("roundabout", "circular"):
        return 1
    if tags.get("highway") in ("motorway", "motorway_link") and v != "no":
        return 1
    return 0


def bike_ok(tags):
    cls = tags.get("highway")
    if cls not in BIKE:
        return False
    if tags.get("bicycle") == "no" or tags.get("bicycle") == "dismount" and cls != "footway":
        return False
    if tags.get("access") in ("no", "private") and tags.get("bicycle") not in YES:
        return False
    return True


def bike_contraflow(tags):
    if tags.get("oneway:bicycle") == "no":
        return True
    return any(k.startswith("cycleway") and str(v).startswith("opposite") for k, v in tags.items())


def car_ok(tags):
    cls = tags.get("highway")
    if cls not in CAR:
        return False
    if tags.get("motor_vehicle") == "no" or tags.get("motorcar") == "no":
        return False
    if tags.get("access") in ("no", "private") and tags.get("motor_vehicle") not in YES:
        return False
    if cls == "service" and tags.get("service") in ("parking_aisle", "driveway", "drive-through"):
        return False
    return True


def build(ex):
    usable = []
    for road in ex.roads:
        b, c = bike_ok(road.tags), car_ok(road.tags)
        if (b or c) and len(road.refs) >= 2:
            usable.append((road, b, c))

    use = defaultdict(int)
    for road, _, _ in usable:
        refs = [r for r in road.refs if r in ex.nodes]
        for i, r in enumerate(refs):
            use[r] += 2 if i in (0, len(refs) - 1) else 1

    names, name_idx = [""], {"": 0}
    classes, cls_idx = [], {}
    node_id, n_lat, n_lon = {}, [], []

    def nid(ref):
        if ref not in node_id:
            node_id[ref] = len(n_lat)
            lat, lon = ex.nodes[ref]
            n_lat.append(lat)
            n_lon.append(lon)
        return node_id[ref]

    edges = []  # dicts
    for road, b, c in usable:
        tags = road.tags
        refs = [r for r in road.refs if r in ex.nodes]
        if len(refs) < 2:
            continue
        name = tags.get("name") or tags.get("ref") or ""
        if name not in name_idx:
            name_idx[name] = len(names)
            names.append(name)
        cls = tags["highway"]
        if cls not in cls_idx:
            cls_idx[cls] = len(classes)
            classes.append(cls)
        ow = oneway_dir(tags)
        bike_ow = 0 if bike_contraflow(tags) else ow
        flags = 0
        if b:
            flags |= (1 if bike_ow >= 0 else 0) | (2 if bike_ow <= 0 else 0)
        if c:
            flags |= (4 if ow >= 0 else 0) | (8 if ow <= 0 else 0)
        if tags.get("junction") in ("roundabout", "circular"):
            flags |= 16
        start = 0
        for i in range(1, len(refs)):
            if use[refs[i]] >= 2 or i == len(refs) - 1:
                seg = refs[start:i + 1]
                length = sum(haversine_m(ex.nodes[seg[k]], ex.nodes[seg[k + 1]]) for k in range(len(seg) - 1))
                if length > 0.5:
                    def cost(table, ok):
                        if not ok:
                            return 0
                        speed, factor = table[cls]
                        return max(1, int(round(length / speed * factor * 10)))
                    edges.append({
                        "u": nid(seg[0]), "v": nid(seg[-1]), "len": length,
                        "name": name_idx[name], "cls": cls_idx[cls], "flags": flags,
                        "cb": cost(BIKE, b), "cc": cost(CAR, c),
                        "geom": [ex.nodes[r] for r in seg[1:-1]],
                    })
                start = i

    # Drop small disconnected fragments (snapping there would fail to route).
    parent = list(range(len(n_lat)))

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a
    for e in edges:
        ra, rb = find(e["u"]), find(e["v"])
        if ra != rb:
            parent[ra] = rb
    size = defaultdict(int)
    for i in range(len(n_lat)):
        size[find(i)] += 1
    keep_edges = [e for e in edges if size[find(e["u"])] >= MIN_COMPONENT]

    # Re-index nodes compactly.
    remap, f_lat, f_lon = {}, [], []
    for e in keep_edges:
        for k in ("u", "v"):
            if e[k] not in remap:
                remap[e[k]] = len(f_lat)
                f_lat.append(n_lat[e[k]])
                f_lon.append(n_lon[e[k]])
            e[k] = remap[e[k]]

    adj = defaultdict(list)
    g_lat, g_lon = [], []
    out = {k: [] for k in ("e_u", "e_v", "e_len", "e_name", "e_cls", "e_flags", "e_cost_bike", "e_cost_car", "e_g0", "e_gn")}
    grid = defaultdict(set)
    for i, e in enumerate(keep_edges):
        eid = i + 1
        out["e_u"].append(e["u"] + 1)
        out["e_v"].append(e["v"] + 1)
        out["e_len"].append(round(e["len"], 1))
        out["e_name"].append(e["name"])
        out["e_cls"].append(e["cls"] + 1)
        out["e_flags"].append(e["flags"])
        out["e_cost_bike"].append(e["cb"])
        out["e_cost_car"].append(e["cc"])
        out["e_g0"].append(len(g_lat) + 1)
        out["e_gn"].append(len(e["geom"]))
        for lat, lon in e["geom"]:
            g_lat.append(int(round(lat * 1e6)))
            g_lon.append(int(round(lon * 1e6)))
        if e["flags"] & (1 | 4):
            adj[e["u"]].append(eid)
        if e["flags"] & (2 | 8):
            adj[e["v"]].append(-eid)
        pts = [(f_lat[e["u"]], f_lon[e["u"]])] + e["geom"] + [(f_lat[e["v"]], f_lon[e["v"]])]
        for (a_lat, a_lon), (b_lat, b_lon) in zip(pts, pts[1:]):
            for ix in range(int(math.floor(min(a_lon, b_lon) / GRID_DEG)), int(math.floor(max(a_lon, b_lon) / GRID_DEG)) + 1):
                for iy in range(int(math.floor(min(a_lat, b_lat) / GRID_DEG)), int(math.floor(max(a_lat, b_lat) / GRID_DEG)) + 1):
                    grid["{}:{}".format(ix, iy)].add(eid)

    deg = [0] * len(f_lat)
    for e in keep_edges:
        deg[e["u"]] += 1
        deg[e["v"]] += 1

    adj_start, adj_edge = [], []
    for n in range(len(f_lat)):
        adj_start.append(len(adj_edge) + 1)
        adj_edge.extend(adj.get(n, []))
    adj_start.append(len(adj_edge) + 1)

    graph = {
        "version": 1, "grid_deg": GRID_DEG, "bike_max_mps": BIKE_MAX, "car_max_mps": CAR_MAX,
        "names": names, "classes": classes,
        "n_lat": [int(round(v * 1e6)) for v in f_lat], "n_lon": [int(round(v * 1e6)) for v in f_lon],
        "adj_start": adj_start, "adj_edge": adj_edge, "n_deg": deg,
        "g_lat": g_lat, "g_lon": g_lon,
        "grid": {k: sorted(v) for k, v in grid.items()},
    }
    graph.update(out)
    return graph


# ------------------------------------------------- reference router (validation)

def route(graph, profile, a, b):
    """Plain A* on the graph (node->node), used only to validate the build."""
    cost_key = "e_cost_bike" if profile == "bike" else "e_cost_car"
    vmax = graph["bike_max_mps"] if profile == "bike" else graph["car_max_mps"]
    fwd, back = (1, 2) if profile == "bike" else (4, 8)
    lat, lon = graph["n_lat"], graph["n_lon"]

    def nearest(p):
        best, bi = 1e18, None
        for i in range(len(lat)):
            d = (lat[i] / 1e6 - p[0]) ** 2 + (lon[i] / 1e6 - p[1]) ** 2
            if d < best:
                ok = any(graph[cost_key][abs(e) - 1] > 0 for e in graph["adj_edge"][graph["adj_start"][i] - 1:graph["adj_start"][i + 1] - 1])
                if ok:
                    best, bi = d, i
        return bi
    s, t = nearest(a), nearest(b)
    tp = (lat[t] / 1e6, lon[t] / 1e6)
    g = {s: 0}
    prev = {}
    heap = [(0, s)]
    while heap:
        f, n = heapq.heappop(heap)
        if n == t:
            break
        for se in graph["adj_edge"][graph["adj_start"][n] - 1:graph["adj_start"][n + 1] - 1]:
            e = abs(se) - 1
            flags = graph["e_flags"][e]
            if (se > 0 and not flags & fwd) or (se < 0 and not flags & back):
                continue
            c = graph[cost_key][e]
            if c <= 0:
                continue
            m = (graph["e_v"][e] if se > 0 else graph["e_u"][e]) - 1
            ng = g[n] + c
            if ng < g.get(m, 1e18):
                g[m] = ng
                prev[m] = (n, e)
                h = haversine_m((lat[m] / 1e6, lon[m] / 1e6), tp) / vmax * 10
                heapq.heappush(heap, (ng + h, m))
    if t not in g:
        return None
    dist, n, streets = 0.0, t, []
    while n != s:
        n, e = prev[n]
        dist += graph["e_len"][e]
        streets.append(graph["names"][graph["e_name"][e]])
    seen = []
    for name in reversed(streets):
        if name and (not seen or seen[-1] != name):
            seen.append(name)
    return dist, g[t] / 10.0, seen


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--output", type=Path, default=DEFAULT_OUT)
    args = p.parse_args()
    ex = load_extract(pois=False)
    graph = build(ex)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8") as h:
        json.dump(graph, h, ensure_ascii=False, separators=(",", ":"))
    print("graph: {} nodes, {} edges, {} geom pts, {} grid cells, {:.1f} MiB".format(
        len(graph["n_lat"]), len(graph["e_u"]), len(graph["g_lat"]), len(graph["grid"]),
        args.output.stat().st_size / 1048576.0))
    farol, shopping = (-13.0104, -38.5324), (-12.9783, -38.4553)
    for prof in ("bike", "car"):
        r = route(graph, prof, farol, shopping)
        if r:
            print("{}: Farol da Barra -> Shopping da Bahia {:.1f} km, {:.0f} min via {}".format(
                prof, r[0] / 1000, r[1] / 60, " > ".join(r[2][:8])))
        else:
            print("{}: no route".format(prof))
    return 0


if __name__ == "__main__":
    sys.exit(main())
