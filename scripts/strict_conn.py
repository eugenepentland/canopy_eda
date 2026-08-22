#!/usr/bin/env python3
"""Strict, layer-honest connectivity audit for a saved PCB layout row."""

import json
import math
import sys
from collections import defaultdict


TIERS = (1e-6, 1e-3, 0.02)


def pad_layers(pad):
    if pad["thru"]:
        return None
    return {0} if pad["side"] == "top" else {1}


def segment_point(x1, y1, x2, y2, px, py):
    dx, dy = x2 - x1, y2 - y1
    length_squared = dx * dx + dy * dy
    if length_squared <= 0:
        return math.hypot(px - x1, py - y1)
    t = max(0.0, min(1.0, ((px - x1) * dx + (py - y1) * dy) / length_squared))
    return math.hypot(px - (x1 + t * dx), py - (y1 + t * dy))


def segment_segment(a, b):
    ax1, ay1, ax2, ay2 = a
    bx1, by1, bx2, by2 = b
    d1 = (bx2 - bx1) * (ay1 - by1) - (by2 - by1) * (ax1 - bx1)
    d2 = (bx2 - bx1) * (ay2 - by1) - (by2 - by1) * (ax2 - bx1)
    d3 = (ax2 - ax1) * (by1 - ay1) - (ay2 - ay1) * (bx1 - ax1)
    d4 = (ax2 - ax1) * (by2 - ay1) - (ay2 - ay1) * (bx2 - ax1)
    if ((d1 > 0) != (d2 > 0)) and ((d3 > 0) != (d4 > 0)) and (d1 != 0 or d2 != 0):
        return 0.0
    return min(
        segment_point(ax1, ay1, ax2, ay2, bx1, by1),
        segment_point(ax1, ay1, ax2, ay2, bx2, by2),
        segment_point(bx1, by1, bx2, by2, ax1, ay1),
        segment_point(bx1, by1, bx2, by2, ax2, ay2),
    )


def segment_rect(x1, y1, x2, y2, pad):
    cx, cy, hw, hh = pad["x"], pad["y"], pad["hw"], pad["hh"]
    for px, py in ((x1, y1), (x2, y2)):
        if abs(px - cx) <= hw and abs(py - cy) <= hh:
            return 0.0
    edges = (
        (cx - hw, cy - hh, cx + hw, cy - hh),
        (cx + hw, cy - hh, cx + hw, cy + hh),
        (cx + hw, cy + hh, cx - hw, cy + hh),
        (cx - hw, cy + hh, cx - hw, cy - hh),
    )
    return min(segment_segment((x1, y1, x2, y2), edge) for edge in edges)


def segment_rect_full_width(x1, y1, x2, y2, width, pad, tolerance):
    """True when a complete transverse trace-width chord fits on the land."""
    dx, dy = x2 - x1, y2 - y1
    length = math.hypot(dx, dy)
    if length <= 1e-12 or width <= 0:
        return False
    nx, ny = -dy / length, dx / length
    radius = width / 2
    xmin = pad["x"] - pad["hw"] + abs(nx) * radius - tolerance
    xmax = pad["x"] + pad["hw"] - abs(nx) * radius + tolerance
    ymin = pad["y"] - pad["hh"] + abs(ny) * radius - tolerance
    ymax = pad["y"] + pad["hh"] - abs(ny) * radius + tolerance
    if xmin > xmax or ymin > ymax:
        return False
    lo, hi = 0.0, 1.0
    for start, delta, lower, upper in ((x1, dx, xmin, xmax), (y1, dy, ymin, ymax)):
        if abs(delta) <= 1e-12:
            if start < lower or start > upper:
                return False
            continue
        a, b = (lower - start) / delta, (upper - start) / delta
        lo, hi = max(lo, min(a, b)), min(hi, max(a, b))
        if lo > hi:
            return False
    return True


def segment_segment_full_width(a, b, tolerance):
    """True when the narrower trace carries one full chord inside the other."""
    if a["w"] <= 0 or b["w"] <= 0:
        return False
    if segment_segment(
        (a["x1"], a["y1"], a["x2"], a["y2"]),
        (b["x1"], b["y1"], b["x2"], b["y2"]),
    ) > (a["w"] + b["w"]) / 2 + tolerance:
        return False
    def directed(narrow, wide):
        dx, dy = narrow["x2"] - narrow["x1"], narrow["y2"] - narrow["y1"]
        length = math.hypot(dx, dy)
        if length <= 1e-12:
            return False
        nx, ny = -dy / length, dx / length
        radius = narrow["w"] / 2

        def coverage(t):
            cx, cy = narrow["x1"] + t * dx, narrow["y1"] + t * dy
            return max(
                segment_point(wide["x1"], wide["y1"], wide["x2"], wide["y2"], cx - nx * radius, cy - ny * radius),
                segment_point(wide["x1"], wide["y1"], wide["x2"], wide["y2"], cx + nx * radius, cy + ny * radius),
            )

        lo, hi = 0.0, 1.0
        for _ in range(56):
            left, right = (2 * lo + hi) / 3, (lo + 2 * hi) / 3
            if coverage(left) <= coverage(right):
                hi = right
            else:
                lo = left
        need = min(coverage(0), coverage(1), coverage((lo + hi) / 2))
        return need <= wide["w"] / 2 + tolerance

    if a["w"] < b["w"]:
        return directed(a, b)
    if b["w"] < a["w"]:
        return directed(b, a)
    return directed(a, b) or directed(b, a)


def segment_via_full_width(track, via, tolerance):
    """True when the narrower trace/via feature carries one complete chord."""
    if track["w"] <= 0 or via["d"] <= 0:
        return False
    dx, dy = track["x2"] - track["x1"], track["y2"] - track["y1"]
    length_squared = dx * dx + dy * dy
    if length_squared <= 1e-24:
        return False
    t = max(0.0, min(1.0, ((via["x"] - track["x1"]) * dx + (via["y"] - track["y1"]) * dy) / length_squared))
    cx, cy = track["x1"] + t * dx, track["y1"] + t * dy
    center_gap = math.hypot(cx - via["x"], cy - via["y"])
    if center_gap > track["w"] / 2 + via["d"] / 2 + tolerance:
        return False
    length = math.sqrt(length_squared)

    if track["w"] <= via["d"]:
        nx, ny = -dy / length, dx / length
        radius = track["w"] / 2
        need = max(
            math.hypot(cx - nx * radius - via["x"], cy - ny * radius - via["y"]),
            math.hypot(cx + nx * radius - via["x"], cy + ny * radius - via["y"]),
        )
        return need <= via["d"] / 2 + tolerance

    rx, ry = via["x"] - cx, via["y"] - cy
    radial = math.hypot(rx, ry)
    ux, uy = (-ry / radial, rx / radial) if radial > 1e-12 else (dx / length, dy / length)
    radius = via["d"] / 2
    need = max(
        segment_point(track["x1"], track["y1"], track["x2"], track["y2"], via["x"] - ux * radius, via["y"] - uy * radius),
        segment_point(track["x1"], track["y1"], track["x2"], track["y2"], via["x"] + ux * radius, via["y"] + uy * radius),
    )
    return need <= track["w"] / 2 + tolerance


def point_rect(px, py, pad):
    dx = max(abs(px - pad["x"]) - pad["hw"], 0.0)
    dy = max(abs(py - pad["y"]) - pad["hh"], 0.0)
    return math.hypot(dx, dy)


class UnionFind:
    def __init__(self, count):
        self.parent = list(range(count))

    def find(self, node):
        while self.parent[node] != node:
            self.parent[node] = self.parent[self.parent[node]]
            node = self.parent[node]
        return node

    def union(self, a, b):
        self.parent[self.find(a)] = self.find(b)


def main(sidecar_path, row_name, pads_path):
    with open(sidecar_path, encoding="utf-8") as handle:
        sidecar = json.load(handle)
    row = next(layout for layout in sidecar["layouts"] if layout["name"] == row_name)
    routes = row.get("routes") or {}
    tracks = routes.get("tracks") or []
    vias = routes.get("vias") or []
    with open(pads_path, encoding="utf-8") as handle:
        pads = json.load(handle).get("pads", [])

    tracks_by_net = defaultdict(list)
    vias_by_net = defaultdict(list)
    pads_by_net = defaultdict(list)
    for track in tracks:
        tracks_by_net[track["net"]].append(track)
    for via in vias:
        vias_by_net[via["net"]].append(via)
    for pad in pads:
        pads_by_net[pad["net"]].append(pad)

    def audit(net, tolerance):
        net_tracks = tracks_by_net[net]
        net_vias = vias_by_net[net]
        net_pads = pads_by_net[net]
        count = len(net_tracks) + len(net_vias) + len(net_pads) + 1
        union_find = UnionFind(count)
        track_node = lambda i: i
        via_node = lambda i: len(net_tracks) + i
        pad_node = lambda i: len(net_tracks) + len(net_vias) + i
        plane_node = count - 1

        for i, track in enumerate(net_tracks):
            for j in range(i + 1, len(net_tracks)):
                other = net_tracks[j]
                if track["l"] != other["l"]:
                    continue
                if segment_segment_full_width(track, other, tolerance):
                    union_find.union(track_node(i), track_node(j))
            for j, via in enumerate(net_vias):
                if segment_via_full_width(track, via, tolerance):
                    union_find.union(track_node(i), via_node(j))
            for j, pad in enumerate(net_pads):
                layers = pad_layers(pad)
                if layers is not None and track["l"] not in layers:
                    continue
                if segment_rect_full_width(
                    track["x1"], track["y1"], track["x2"], track["y2"], track["w"], pad, tolerance
                ):
                    union_find.union(track_node(i), pad_node(j))

        for i, via in enumerate(net_vias):
            for j in range(i + 1, len(net_vias)):
                other = net_vias[j]
                if math.hypot(via["x"] - other["x"], via["y"] - other["y"]) <= (via["d"] + other["d"]) / 2 + tolerance:
                    union_find.union(via_node(i), via_node(j))
            for j, pad in enumerate(net_pads):
                if point_rect(via["x"], via["y"], pad) <= via["d"] / 2 + tolerance:
                    union_find.union(via_node(i), pad_node(j))
            if net == "GND":
                union_find.union(via_node(i), plane_node)

        for i, pad in enumerate(net_pads):
            if net == "GND" and pad["thru"]:
                union_find.union(pad_node(i), plane_node)
            for j in range(i + 1, len(net_pads)):
                other = net_pads[j]
                if (
                    abs(pad["x"] - other["x"]) <= pad["hw"] + other["hw"]
                    and abs(pad["y"] - other["y"]) <= pad["hh"] + other["hh"]
                ):
                    union_find.union(pad_node(i), pad_node(j))

        roots = {}
        for i, pad in enumerate(net_pads):
            roots.setdefault(union_find.find(pad_node(i)), []).append(f'{pad["ref"]}.{pad["pad"]}')
        return roots

    nets = sorted(net for net in pads_by_net if net and len(pads_by_net[net]) > 1)
    bad = []
    for net in nets:
        counts = []
        strict_roots = None
        for tolerance in TIERS:
            roots = audit(net, tolerance)
            if strict_roots is None:
                strict_roots = roots
            counts.append(len(roots))
        if max(counts) > 1:
            small = sorted(strict_roots.values(), key=len)[:-1]
            victims = "; ".join(",".join(group[:4]) for group in small[:3])
            bad.append((net, counts, victims))

    print(f"row={row_name}: nets with >1 pad-island at any tier: {len(bad)} of {len(nets)} multi-pad nets")
    print(f'{"net":30}{"isl@1e-6":>9}{"isl@1um":>9}{"isl@20um":>9}  smallest strict islands')
    for net, counts, victims in sorted(bad, key=lambda item: -item[1][0]):
        print(f"{net:30}{counts[0]:9d}{counts[1]:9d}{counts[2]:9d}  {victims}")


if __name__ == "__main__":
    if len(sys.argv) != 4:
        raise SystemExit(f"usage: {sys.argv[0]} <sidecar.json> <row-name> <describe-with-pads.json>")
    main(*sys.argv[1:])
