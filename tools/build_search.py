#!/usr/bin/env python3
"""Offline destination search index for the Kindle receiver.

build/data/search.json: {"items": [[key, label, kind, lat_e6, lon_e6, rank], ...]}
  key   normalised text (lowercase, no accents) used for matching on the Kindle
  label what the phone shows: "Rua X — Bairro", "Shopping Y — Bairro", "Pituba (bairro)"
  kind  "street" | "place" | "poi"
Streets are grouped per (name, neighbourhood); the point is the middle node of
the longest way in that group.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
import unicodedata
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from osm_extract import BBOX, PROJECT_ROOT, haversine_m, load_extract, road_points  # noqa: E402

DEFAULT_OUT = PROJECT_ROOT / "build" / "data" / "search.json"
PLACE_RANK = {"city": 9, "town": 8, "suburb": 7, "quarter": 6, "neighbourhood": 5}
POI_KEYS = ("amenity", "shop", "tourism", "leisure")
POI_LABEL = {
    "hospital": "hospital", "clinic": "clínica", "school": "escola", "university": "universidade",
    "college": "faculdade", "bus_station": "rodoviária", "fuel": "posto", "pharmacy": "farmácia",
    "mall": "shopping", "supermarket": "supermercado", "park": "parque", "beach_resort": "praia",
    "restaurant": "restaurante", "bank": "banco", "police": "polícia", "place_of_worship": "igreja",
    "museum": "museu", "hotel": "hotel", "attraction": "atração", "stadium": "estádio",
}


def normalise(text: str) -> str:
    text = unicodedata.normalize("NFKD", text.lower())
    text = "".join(c for c in text if not unicodedata.combining(c))
    return " ".join("".join(c if c.isalnum() else " " for c in text).split())


def in_bbox(lat, lon):
    w, s, e, n = BBOX
    return s <= lat <= n and w <= lon <= e


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--output", type=Path, default=DEFAULT_OUT)
    args = p.parse_args()
    ex = load_extract()

    places = [(t.get("name"), t.get("place"), lat, lon) for t, lat, lon in ex.pois
              if t.get("place") in PLACE_RANK and t.get("name") and in_bbox(lat, lon)]
    hoods = [pl for pl in places if pl[1] in ("suburb", "quarter", "neighbourhood")]
    cell = 0.02
    grid = defaultdict(list)
    for pl in hoods:
        grid[(int(math.floor(pl[3] / cell)), int(math.floor(pl[2] / cell)))].append(pl)

    def hood(lat, lon):
        best, bn = 1e18, ""
        cx, cy = int(math.floor(lon / cell)), int(math.floor(lat / cell))
        for x in range(cx - 2, cx + 3):
            for y in range(cy - 2, cy + 3):
                for name, _, plat, plon in grid.get((x, y), []):
                    d = haversine_m((lat, lon), (plat, plon))
                    if d < best:
                        best, bn = d, name
        return bn if best < 3000 else ""

    items = []
    for name, kind, lat, lon in places:
        label = "{} ({})".format(name, "bairro" if kind != "city" and kind != "town" else "cidade")
        items.append([normalise(name), label, "place", int(round(lat * 1e6)), int(round(lon * 1e6)), PLACE_RANK[kind]])

    groups = defaultdict(list)  # (name, hood) -> [(length, mid point)]
    for road in ex.roads:
        name = road.tags.get("name")
        if not name:
            continue
        pts = road_points(ex, road)
        if len(pts) < 2:
            continue
        mid = pts[len(pts) // 2]
        if not in_bbox(*mid):
            continue
        length = sum(haversine_m(pts[i], pts[i + 1]) for i in range(len(pts) - 1))
        groups[(name, hood(*mid))].append((length, mid))
    for (name, hd), segs in groups.items():
        segs.sort(reverse=True)
        total = sum(s[0] for s in segs)
        lat, lon = segs[0][1]
        label = "{} — {}".format(name, hd) if hd else name
        rank = 4 if total > 1500 else (3 if total > 400 else 2)
        items.append([normalise(name), label, "street", int(round(lat * 1e6)), int(round(lon * 1e6)), rank])

    seen = set()
    for tags, lat, lon in ex.pois:
        name = tags.get("name")
        if not name or tags.get("place") or not in_bbox(lat, lon):
            continue
        kind_val = next((tags[k] for k in POI_KEYS if k in tags), "")
        key = (normalise(name), round(lat, 3), round(lon, 3))
        if key in seen:
            continue
        seen.add(key)
        what = POI_LABEL.get(kind_val, "")
        hd = hood(lat, lon)
        label = name + (" · " + what if what else "") + (" — " + hd if hd else "")
        rank = 5 if kind_val in ("mall", "hospital", "university", "bus_station", "stadium") else 3
        items.append([normalise(name), label, "poi", int(round(lat * 1e6)), int(round(lon * 1e6)), rank])

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8") as h:
        json.dump({"version": 1, "items": items}, h, ensure_ascii=False, separators=(",", ":"))
    kinds = defaultdict(int)
    for it in items:
        kinds[it[2]] += 1
    print("search: {} items ({}), {:.1f} MiB".format(len(items), dict(kinds), args.output.stat().st_size / 1048576.0))
    return 0


if __name__ == "__main__":
    sys.exit(main())
