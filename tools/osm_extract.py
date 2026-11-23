#!/usr/bin/env python3
"""Shared OSM extract for the KindleMap pack, routing graph and search index.

One bounded Overpass request for Salvador + Lauro de Freitas (raw OSM data,
never rendered tiles from tile.openstreetmap.org), cached gzip'd in .cache/.

    from osm_extract import load_extract
    data = load_extract()          # downloads once, then reads the cache
    data.nodes[id] -> (lat, lon)
    data.roads   -> [Road(id, tags, refs)]
    data.areas   -> [(kind, tags, [(lat, lon), ...])]
    data.pois    -> [(tags, lat, lon)]
"""

from __future__ import annotations

import argparse
import gzip
import json
import math
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional, Tuple

PROJECT_ROOT = Path(__file__).resolve().parents[1]
CACHE_DIR = PROJECT_ROOT / ".cache"

# west, south, east, north
BBOX = (-38.68, -13.05, -38.22, -12.70)
TILE_SIZE = 256

OVERPASS_ENDPOINTS = (
    "https://overpass-api.de/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
    "https://overpass.private.coffee/api/interpreter",
)
USER_AGENT = "KindleEInkMapPrototype/0.4 (personal offline map pack)"

ROAD_CLASSES = (
    "motorway|motorway_link|trunk|trunk_link|primary|primary_link|secondary|secondary_link|"
    "tertiary|tertiary_link|unclassified|residential|living_street|service|cycleway|path|"
    "footway|pedestrian|steps|bridleway|track"
)


def _box(west, south, east, north) -> str:
    return "({},{},{},{})".format(south, west, north, east)


def sub_queries() -> List[Tuple[str, str]]:
    """Small Overpass requests (the public servers reject one big query)."""
    west, south, east, north = BBOX
    mid_lon, mid_lat = (west + east) / 2.0, (south + north) / 2.0
    quads = [
        ("roads-nw", (west, mid_lat, mid_lon, north)), ("roads-ne", (mid_lon, mid_lat, east, north)),
        ("roads-sw", (west, south, mid_lon, mid_lat)), ("roads-se", (mid_lon, south, east, mid_lat)),
    ]
    out = []
    for name, q in quads:
        out.append((name, """[out:json][timeout:300];
way["highway"~"^({roads})$"]{box}->.r;
.r out body;
.r >;
out skel qt;""".format(roads=ROAD_CLASSES, box=_box(*q))))
    box = _box(*BBOX)
    out.append(("areas", """[out:json][timeout:300];
(
  way["natural"~"^(water|coastline|beach|wood|scrub)$"]{box};
  way["waterway"~"^(river|canal|stream|riverbank)$"]{box};
  way["leisure"~"^(park|garden|nature_reserve|pitch|stadium)$"]{box};
  way["landuse"~"^(reservoir|forest|grass|recreation_ground|cemetery)$"]{box};
);
out tags geom;""".format(box=box)))
    out.append(("places", """[out:json][timeout:120];
node["place"~"^(suburb|neighbourhood|quarter|city|town)$"]{box};
out body;""".format(box=box)))
    out.append(("pois-nodes", """[out:json][timeout:240];
(
  node["name"]["amenity"~"^(hospital|clinic|school|university|college|bus_station|fuel|pharmacy|police|bank|place_of_worship|marketplace|townhall|library|theatre|cinema)$"]{box};
  node["name"]["shop"~"^(mall|supermarket|department_store)$"]{box};
  node["name"]["tourism"]{box};
  node["name"]["leisure"~"^(park|stadium|sports_centre)$"]{box};
);
out body;""".format(box=box)))
    out.append(("pois-ways", """[out:json][timeout:240];
(
  way["name"]["amenity"~"^(hospital|clinic|school|university|college|bus_station|fuel|police|marketplace|townhall)$"]{box};
  way["name"]["shop"~"^(mall|supermarket|department_store)$"]{box};
  way["name"]["tourism"]{box};
  way["name"]["leisure"~"^(park|stadium|sports_centre)$"]{box};
);
out tags center;""".format(box=box)))
    return out


@dataclass
class Road:
    id: int
    tags: Dict[str, str]
    refs: List[int]


@dataclass
class Extract:
    nodes: Dict[int, Tuple[float, float]] = field(default_factory=dict)
    roads: List[Road] = field(default_factory=list)
    areas: List[tuple] = field(default_factory=list)
    pois: List[tuple] = field(default_factory=list)


def area_kind(tags: dict) -> Optional[str]:
    natural = tags.get("natural")
    if natural == "coastline":
        return "coastline"
    if natural == "water" or tags.get("waterway") == "riverbank" or tags.get("landuse") == "reservoir":
        return "water_area"
    if tags.get("waterway") in ("river", "canal", "stream"):
        return "water_line"
    if natural == "beach":
        return "beach"
    if tags.get("leisure") or tags.get("landuse") or natural in ("wood", "scrub"):
        return "park"
    return None


def fetch_part(name: str, query: str, cache_dir: Path, refresh: bool) -> dict:
    path = cache_dir / "osm-{}.json.gz".format(name)
    if path.exists() and not refresh:
        with gzip.open(str(path), "rt", encoding="utf-8") as handle:
            return json.load(handle)
    errors = []
    for attempt in range(2):
        for endpoint in OVERPASS_ENDPOINTS:
            print("Overpass [{}]: {}".format(name, endpoint), flush=True)
            result = subprocess.run(
                ["curl", "--fail", "--silent", "--show-error", "--location", "--compressed",
                 "--connect-timeout", "15", "--max-time", "420",
                 "--user-agent", USER_AGENT, "--data-urlencode", "data=" + query, endpoint],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
            )
            if result.returncode == 0 and result.stdout:
                data = json.loads(result.stdout.decode("utf-8"))
                if data.get("remark"):
                    errors.append("{}: {}".format(endpoint, data["remark"]))
                    continue
                path.parent.mkdir(parents=True, exist_ok=True)
                with gzip.open(str(path), "wb", compresslevel=6) as handle:
                    handle.write(result.stdout)
                print("  {} {:.1f} MiB".format(name, len(result.stdout) / 1048576.0), flush=True)
                return data
            errors.append("{}: {}".format(endpoint, result.stderr.decode("utf-8", "replace").strip()))
            time.sleep(10)
    raise RuntimeError("Overpass failed for {}: {}".format(name, " | ".join(errors)))


def load_extract(cache_dir: Path = CACHE_DIR, refresh: bool = False, pois: bool = True) -> Extract:
    """pois=False skips the (slow) points-of-interest request: tiles and graph don't need it."""
    ex = Extract()
    seen_roads = set()
    for name, query in sub_queries():
        if name.startswith(("pois", "places")) and not pois:
            continue
        data = fetch_part(name, query, cache_dir, refresh)
        for el in data.get("elements", []):
            t = el.get("type")
            tags = el.get("tags", {})
            if t == "node":
                if "lat" in el:
                    if tags:
                        ex.pois.append((tags, el["lat"], el["lon"]))
                    ex.nodes[el["id"]] = (el["lat"], el["lon"])
            elif t == "way":
                if "highway" in tags and "nodes" in el:
                    if el["id"] not in seen_roads:  # ways crossing quadrants appear twice
                        seen_roads.add(el["id"])
                        ex.roads.append(Road(el["id"], tags, el["nodes"]))
                elif "geometry" in el:
                    kind = area_kind(tags)
                    pts = [(p["lat"], p["lon"]) for p in el["geometry"] if p]
                    if kind and len(pts) >= 2:
                        ex.areas.append((kind, tags, pts))
                elif "center" in el and tags.get("name"):
                    ex.pois.append((tags, el["center"]["lat"], el["center"]["lon"]))
    return ex


def road_points(ex: Extract, road: Road) -> List[Tuple[float, float]]:
    return [ex.nodes[r] for r in road.refs if r in ex.nodes]


def project(lat: float, lon: float, zoom: int) -> Tuple[float, float]:
    lat = max(-85.05112878, min(85.05112878, lat))
    n = float(2 ** zoom) * TILE_SIZE
    x = (lon + 180.0) / 360.0 * n
    y = (1.0 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2.0 * n
    return x, y


def haversine_m(a: Tuple[float, float], b: Tuple[float, float]) -> float:
    la1, lo1, la2, lo2 = map(math.radians, (a[0], a[1], b[0], b[1]))
    h = math.sin((la2 - la1) / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin((lo2 - lo1) / 2) ** 2
    return 2 * 6371000.0 * math.asin(min(1.0, math.sqrt(h)))


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--refresh", action="store_true", help="download again even if cached")
    args = p.parse_args()
    ex = load_extract(refresh=args.refresh)
    named = sum(1 for r in ex.roads if r.tags.get("name"))
    print("nodes={} roads={} (named {}) areas={} pois={}".format(
        len(ex.nodes), len(ex.roads), named, len(ex.areas), len(ex.pois)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
