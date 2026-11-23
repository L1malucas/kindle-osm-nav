#!/usr/bin/env python3
"""Render the KindleMap raster pack (z9-17) for E Ink from the shared OSM extract.

z9-14: the original thin-line overview style.
z15-17: roads with black casing + white/grey fill and street names rotated
along the road, with a white halo and global collision checks.

    python3 tools/build_tiles.py                 # -> build/pack
    python3 tools/build_tiles.py --max-zoom 16   # quicker test
"""

from __future__ import annotations

import argparse
import json
import math
import multiprocessing as mp
import shutil
import sys
import time
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional, Tuple

from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, str(Path(__file__).resolve().parent))
from osm_extract import BBOX, PROJECT_ROOT, TILE_SIZE, load_extract, project, road_points  # noqa: E402

DEFAULT_OUT = PROJECT_ROOT / "build" / "pack"
FONT_PATH = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"
OVERVIEW_ZOOM = 10
DETAIL_ZOOM = 17

# Rank decides draw order (low first) and label priority (high first).
CLASS_RANK = {
    "motorway": 9, "trunk": 9, "primary": 8, "secondary": 7, "tertiary": 6,
    "motorway_link": 6, "trunk_link": 6, "primary_link": 6, "secondary_link": 5, "tertiary_link": 5,
    "unclassified": 4, "residential": 4, "living_street": 4,
    "service": 2, "track": 2, "cycleway": 3, "pedestrian": 3,
    "footway": 1, "path": 1, "steps": 1, "bridleway": 1,
}
MAJOR = {"motorway", "trunk", "primary", "motorway_link", "trunk_link", "primary_link"}
FOOT = {"footway", "path", "steps", "bridleway"}

# Fill width at z15/16/17 for the casing style.
WIDTHS = {
    9: (8, 11, 15), 8: (7, 10, 14), 7: (6, 9, 12), 6: (5, 8, 11), 5: (4, 7, 9),
    4: (4, 6, 9), 3: (2, 3, 4), 2: (2, 3, 5), 1: (0, 2, 3),
}

ABBREV = (("Avenida ", "Av. "), ("Travessa ", "Tv. "), ("Ladeira ", "Ld. "), ("Alameda ", "Al. "),
          ("Rodovia ", "Rod. "), ("Estrada ", "Estr. "), ("Praça ", "Pç. "), ("Viaduto ", "Vd. "),
          ("Professor ", "Prof. "), ("Doutor ", "Dr. "), ("General ", "Gen. "))


def label_text(name: str) -> str:
    for long, short in ABBREV:
        if name.startswith(long):
            name = short + name[len(long):]
    return name


def classic_style(cls: str, zoom: int) -> Optional[Tuple[int, int]]:
    """(width, shade) for z<=14, same look as the first pack."""
    rank = CLASS_RANK.get(cls, 0)
    if zoom <= 10 and rank < 6:
        return None
    if zoom <= 12 and rank < 4:
        return None
    if zoom <= 13 and rank < 2:
        return None
    width = 1 if zoom <= 11 else (3 if rank >= 8 else 2)
    shade = 0 if rank >= 8 else 45
    if cls in FOOT:
        shade = 90
    return width, shade


def casing_style(cls: str, zoom: int) -> Optional[Tuple[int, int, int]]:
    """(fill width, fill shade, casing extra px) for z>=15; extra 0 = no casing."""
    rank = CLASS_RANK.get(cls, 0)
    w = WIDTHS.get(rank, (0, 0, 0))[min(2, zoom - 15)]
    if w <= 0:
        return None
    if cls in FOOT:
        return w, 110, 0
    if cls == "cycleway":
        return w, 0, 0
    if cls == "track":
        return w, 120, 0
    fill = 205 if cls in MAJOR else 255
    return w, fill, 2


# ---------------------------------------------------------------- per-zoom data

G = {}  # shared with forked workers


def segment_tiles(p0, p1, pad):
    x0, x1 = sorted((p0[0], p1[0]))
    y0, y1 = sorted((p0[1], p1[1]))
    for tx in range(int((x0 - pad) // TILE_SIZE), int((x1 + pad) // TILE_SIZE) + 1):
        for ty in range(int((y0 - pad) // TILE_SIZE), int((y1 + pad) // TILE_SIZE) + 1):
            yield tx, ty


def prepare_zoom(ex, zoom, tile_range):
    """Project features and bucket segment runs per tile."""
    feats = []  # (kind, style, pts)
    for kind, tags, latlon in ex.areas:
        pts = [project(a, b, zoom) for a, b in latlon]
        feats.append((kind, None, pts))
    for road in ex.roads:
        cls = road.tags.get("highway", "")
        style = classic_style(cls, zoom) if zoom <= 14 else casing_style(cls, zoom)
        if style is None:
            continue
        latlon = road_points(ex, road)
        if len(latlon) < 2:
            continue
        pts = [project(a, b, zoom) for a, b in latlon]
        feats.append(("road", (CLASS_RANK.get(cls, 0), style), pts))

    (tx0, ty0, tx1, ty1) = tile_range
    buckets: Dict[Tuple[int, int], Dict[int, set]] = defaultdict(lambda: defaultdict(set))
    for fi, (kind, style, pts) in enumerate(feats):
        if kind in ("water_area", "park", "beach") and len(pts) > 2:
            xs = [p[0] for p in pts]
            ys = [p[1] for p in pts]
            for tx in range(max(tx0, int(min(xs) // TILE_SIZE)), min(tx1, int(max(xs) // TILE_SIZE)) + 1):
                for ty in range(max(ty0, int(min(ys) // TILE_SIZE)), min(ty1, int(max(ys) // TILE_SIZE)) + 1):
                    buckets[(tx, ty)][fi].add(-1)  # whole polygon
            continue
        pad = 12
        for si in range(len(pts) - 1):
            for t in segment_tiles(pts[si], pts[si + 1], pad):
                if tx0 <= t[0] <= tx1 and ty0 <= t[1] <= ty1:
                    buckets[t][fi].add(si)
    return feats, buckets


def runs(indices):
    s = sorted(indices)
    start = prev = s[0]
    for i in s[1:]:
        if i != prev + 1:
            yield start, prev
            start = i
        prev = i
    yield start, prev


# ---------------------------------------------------------------- labels

def place_labels(ex, zoom, font):
    """Return {tile: [(rgba_image, x, y)]} with labels placed in world pixels."""
    if zoom < 15:
        return {}
    min_rank = {15: 6, 16: 4, 17: 2}[zoom]
    spacing = {15: 700, 16: 520, 17: 380}[zoom]
    taken = defaultdict(list)  # grid cell -> boxes
    cell = 128
    by_name = defaultdict(list)  # name -> placed centres
    out = defaultdict(list)

    roads = []
    for road in ex.roads:
        name = road.tags.get("name")
        cls = road.tags.get("highway", "")
        rank = CLASS_RANK.get(cls, 0)
        if not name or rank < min_rank or cls in FOOT:
            continue
        latlon = road_points(ex, road)
        if len(latlon) < 2:
            continue
        roads.append((rank, name, [project(a, b, zoom) for a, b in latlon]))
    roads.sort(key=lambda r: -r[0])

    def collides(box):
        x0, y0, x1, y1 = box
        for cx in range(int(x0 // cell), int(x1 // cell) + 1):
            for cy in range(int(y0 // cell), int(y1 // cell) + 1):
                for b in taken[(cx, cy)]:
                    if not (x1 < b[0] or x0 > b[2] or y1 < b[1] or y0 > b[3]):
                        return True
        return False

    def take(box):
        x0, y0, x1, y1 = box
        for cx in range(int(x0 // cell), int(x1 // cell) + 1):
            for cy in range(int(y0 // cell), int(y1 // cell) + 1):
                taken[(cx, cy)].append(box)

    def point_at(pts, cum, s):
        for i in range(len(pts) - 1):
            if cum[i + 1] >= s:
                seg = cum[i + 1] - cum[i] or 1.0
                f = (s - cum[i]) / seg
                return (pts[i][0] + (pts[i + 1][0] - pts[i][0]) * f, pts[i][1] + (pts[i + 1][1] - pts[i][1]) * f), i
        return pts[-1], len(pts) - 2

    for rank, name, pts in roads:
        text = label_text(name)
        tw = font.getlength(text)
        cum = [0.0]
        for i in range(len(pts) - 1):
            cum.append(cum[-1] + math.hypot(pts[i + 1][0] - pts[i][0], pts[i + 1][1] - pts[i][1]))
        total = cum[-1]
        need = tw + 24
        if total < need:
            continue
        s = max(need / 2, min(spacing / 2, total / 2))
        while s + need / 2 <= total:
            a, ia = point_at(pts, cum, s - need / 2)
            b, ib = point_at(pts, cum, s + need / 2)
            chord = math.hypot(b[0] - a[0], b[1] - a[1])
            straight = chord > need * 0.92
            if straight:
                # max deviation of intermediate vertices from the chord
                for k in range(ia + 1, ib + 1):
                    px, py = pts[k]
                    d = abs((b[0] - a[0]) * (a[1] - py) - (a[0] - px) * (b[1] - a[1])) / (chord or 1)
                    if d > 4:
                        straight = False
                        break
            if straight:
                cx, cy = (a[0] + b[0]) / 2, (a[1] + b[1]) / 2
                near_same = any(math.hypot(cx - x, cy - y) < spacing * 0.8 for x, y in by_name[name])
                if not near_same:
                    angle = math.degrees(math.atan2(b[1] - a[1], b[0] - a[0]))
                    if angle > 90:
                        angle -= 180
                    elif angle < -90:
                        angle += 180
                    img = render_label(text, font, angle)
                    w, h = img.size
                    box = (cx - w / 2 - 3, cy - h / 2 - 3, cx + w / 2 + 3, cy + h / 2 + 3)
                    if not collides(box):
                        take(box)
                        by_name[name].append((cx, cy))
                        x, y = int(round(cx - w / 2)), int(round(cy - h / 2))
                        for tx in range(x // TILE_SIZE, (x + w) // TILE_SIZE + 1):
                            for ty in range(y // TILE_SIZE, (y + h) // TILE_SIZE + 1):
                                out[(tx, ty)].append((img, x - tx * TILE_SIZE, y - ty * TILE_SIZE))
                        s += spacing
                        continue
            s += 40
    return out


def render_label(text, font, angle):
    l, t, r, b = font.getbbox(text, stroke_width=3)
    img = Image.new("LA", (r - l + 4, b - t + 4), (255, 0))
    d = ImageDraw.Draw(img)
    d.text((2 - l, 2 - t), text, font=font, fill=(0, 255), stroke_width=3, stroke_fill=(255, 255))
    return img.rotate(-angle, resample=Image.BICUBIC, expand=True)


# ---------------------------------------------------------------- rendering

LUT = [min(255, int(round(v / 17.0)) * 17) for v in range(256)]  # 16 grey levels (E Ink)


def render_tile(key):
    zoom = G["zoom"]
    feats, buckets, labels, out_dir = G["feats"], G["buckets"], G["labels"], G["out"]
    tx, ty = key
    ox, oy = tx * TILE_SIZE, ty * TILE_SIZE
    img = Image.new("L", (TILE_SIZE, TILE_SIZE), 255)
    d = ImageDraw.Draw(img)
    items = buckets.get(key, {})

    def local(pts):
        return [(x - ox, y - oy) for x, y in pts]

    roads = []
    for fi, segs in items.items():
        kind, style, pts = feats[fi]
        if kind == "road":
            for a, b in runs(segs):
                roads.append((style, local(pts[a:b + 2])))
            continue
        if -1 in segs:
            poly = local(pts)
            if kind == "water_area":
                d.polygon(poly, fill=215, outline=150)
            elif kind == "beach":
                d.polygon(poly, fill=245, outline=200)
            else:
                d.polygon(poly, fill=238, outline=215)
        else:
            for a, b in runs(segs):
                line = local(pts[a:b + 2])
                if kind == "coastline":
                    d.line(line, fill=0, width=2 if zoom < 15 else 3)
                elif kind == "water_line":
                    d.line(line, fill=150, width=2 if zoom < 15 else 4)
                else:
                    d.line(line, fill=210, width=1)

    roads.sort(key=lambda r: r[0][0])
    if zoom <= 14:
        for (rank, (width, shade)), line in roads:
            d.line(line, fill=shade, width=width)
    else:
        for (rank, (w, fill, extra)), line in roads:  # casings first
            if extra:
                d.line(line, fill=0, width=w + 2 * extra, joint="curve")
        for (rank, (w, fill, extra)), line in roads:
            d.line(line, fill=fill, width=w, joint="curve" if extra else None)

    for limg, x, y in labels.get(key, []):
        img.paste(limg.getchannel("L"), (x, y), limg.getchannel("A"))

    img = img.point(LUT)
    path = out_dir / "tiles" / str(zoom) / str(tx)
    path.mkdir(parents=True, exist_ok=True)
    f = path / "{}.png".format(ty)
    img.save(str(f), format="PNG", optimize=True)
    return f.stat().st_size


def tile_range(zoom):
    west, south, east, north = BBOX
    x0, y0 = project(north, west, zoom)
    x1, y1 = project(south, east, zoom)
    return int(x0 // TILE_SIZE), int(y0 // TILE_SIZE), int(x1 // TILE_SIZE), int(y1 // TILE_SIZE)


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--output", type=Path, default=DEFAULT_OUT)
    p.add_argument("--min-zoom", type=int, default=9)
    p.add_argument("--max-zoom", type=int, default=17)
    p.add_argument("--jobs", type=int, default=max(1, mp.cpu_count() - 1))
    args = p.parse_args()

    ex = load_extract(pois=False)
    print("extract: {} roads, {} areas".format(len(ex.roads), len(ex.areas)), flush=True)
    if args.output.exists():
        shutil.rmtree(args.output)
    (args.output / "tiles").mkdir(parents=True)

    total_tiles = total_bytes = 0
    for zoom in range(args.min_zoom, args.max_zoom + 1):
        t0 = time.time()
        rng = tile_range(zoom)
        feats, buckets = prepare_zoom(ex, zoom, rng)
        font = ImageFont.truetype(FONT_PATH, {15: 13, 16: 14, 17: 16}.get(zoom, 13))
        labels = place_labels(ex, zoom, font)
        G.update(zoom=zoom, feats=feats, buckets=dict(buckets), labels=dict(labels), out=args.output)
        keys = sorted(set(buckets) | set(k for k in labels if rng[0] <= k[0] <= rng[2] and rng[1] <= k[1] <= rng[3]))
        ctx = mp.get_context("fork")
        with ctx.Pool(args.jobs) as pool:
            sizes = pool.map(render_tile, keys, chunksize=32)
        total_tiles += len(sizes)
        total_bytes += sum(sizes)
        print("z{}: {} tiles, {:.1f} MiB, {} labels-tiles, {:.0f}s".format(
            zoom, len(sizes), sum(sizes) / 1048576.0, len(labels), time.time() - t0), flush=True)

    west, south, east, north = BBOX
    manifest = {
        "schema_version": 2,
        "name": "Salvador + Lauro de Freitas",
        "attribution": "© OpenStreetMap contributors",
        "source": "OSM data via bounded Overpass extract; local raster rendering",
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "center": {"latitude": (south + north) / 2.0, "longitude": (west + east) / 2.0},
        "overview_zoom": OVERVIEW_ZOOM,
        "detail_zoom": min(DETAIL_ZOOM, args.max_zoom),
        "min_zoom": args.min_zoom,
        "max_zoom": args.max_zoom,
        "tile_size": TILE_SIZE,
        "tile_template": "tiles/{z}/{x}/{y}.png",
        "bounds": {"west": west, "south": south, "east": east, "north": north},
    }
    with (args.output / "manifest.json").open("w", encoding="utf-8") as h:
        json.dump(manifest, h, ensure_ascii=False, indent=2)
    with (args.output / "manifest.js").open("w", encoding="utf-8") as h:
        h.write("window.KINDLE_MAP_PACK = " + json.dumps(manifest, ensure_ascii=True, separators=(",", ":")) + ";\n")
    print("Done: {} tiles, {:.1f} MiB -> {}".format(total_tiles, total_bytes / 1048576.0, args.output))
    return 0


if __name__ == "__main__":
    sys.exit(main())
