#!/usr/bin/env python3
"""Rasterize a design's block-diagram view to PNG for visual review.

The schematic page renders the diagram as inline SVG styled by the page's
CSS classes. This pulls one tab's panel out of a running `eda serve`, inlines a
self-contained copy of the `.dg-*` rules (so colors/fonts resolve without the
page), draws the class legend natively (the page legend is HTML), and renders
with cairosvg.

Usage:
    # start a server first:  eda serve --project-dir projects/designs --port 7060
    python3 scripts/diagram_png.py labstation                 # System view -> /tmp/labstation_system.png
    python3 scripts/diagram_png.py labstation out.png 2.0     # out path + scale
    python3 scripts/diagram_png.py stm32n6 --view power       # a specific tab
    python3 scripts/diagram_png.py labstation --port 7050     # a specific server

Dependencies: cairosvg (`pip install --user cairosvg`; needs libcairo, present
on most Linux). Use the system python if a venv shadows the user site-packages:
`/usr/bin/python3 scripts/diagram_png.py ...`.
"""
import argparse
import re
import sys
import urllib.request

import cairosvg

# A self-contained copy of the diagram's element CSS (kept close to
# src/diagram/render.zig's `CSS`). Scraping the page stylesheet is fragile —
# cairosvg's cssselect2 rejects pseudo rules and `font:` shorthand — so inline
# plain properties for exactly the classes the SVG bodies use.
DG_CSS = (
    ".dg-rect{fill:#0d1117;stroke-width:1.5;}"
    ".dg-boundary{stroke-dasharray:5 4;}"
    ".dg-edge{fill:none;stroke-width:2;stroke-linejoin:round;stroke-linecap:round;}"
    ".dg-label{fill:#c9d1d9;font-weight:600;font-size:18px;font-family:sans-serif;}"
    ".dg-sub{fill:#8b949e;font-size:15px;font-family:sans-serif;}"
    ".dg-pill{fill:#161b22;stroke-width:1;}"
    ".dg-edge-label{fill:#8b949e;font-weight:600;font-size:15px;font-family:monospace;text-anchor:middle;}"
    ".dg-band-label{font-weight:700;font-size:17px;font-family:monospace;}"
    ".dg-pcard{fill:#0d1117;stroke-width:1.8;}"
    ".dg-pinfo{font-weight:600;font-size:16px;font-family:monospace;}"
    ".dg-bucket{stroke-width:1.8;}"
    ".dg-pilltext{fill:#c9d1d9;font-weight:500;font-size:15px;font-family:monospace;}"
)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("design")
    ap.add_argument("out", nargs="?", default=None, help="output PNG path")
    ap.add_argument("scale", nargs="?", type=float, default=1.6, help="raster scale factor")
    ap.add_argument("--view", default="system", help="tab key: system|power|clocks|control|rf|...")
    ap.add_argument("--port", type=int, default=7060)
    ap.add_argument("--host", default="localhost")
    args = ap.parse_args()
    out = args.out or f"/tmp/{args.design}_{args.view}.png"

    url = f"http://{args.host}:{args.port}/schematics/{args.design}"
    html = urllib.request.urlopen(url, timeout=30).read().decode("utf-8", "replace")

    i = html.rfind(f'class="dg-panel dg-panel-{args.view}"')
    if i < 0:
        sys.exit(f"no '{args.view}' panel for {args.design} (is it a non-empty view on this design?)")
    seg = html[i:]
    m = re.search(r'<svg viewBox="0 0 (\d+) (\d+)" class="dg-svg".*?</svg>', seg, re.S)
    if not m:
        sys.exit(f"no diagram SVG in the '{args.view}' panel for {args.design}")
    svg, w, h = m.group(0), int(m.group(1)), int(m.group(2))

    # Class legend (color -> label) lives in the HTML just before the <svg>.
    legend = re.findall(
        r'rect width="12" height="12" rx="2" fill="(#[0-9a-fA-F]+)"/></svg>([^<]+)</span>',
        seg[: seg.index(svg)],
    )
    leg_h = 46 if legend else 0
    strip = []
    if legend:
        x = 16
        for color, label in legend:
            strip.append(f'<rect x="{x}" y="16" width="16" height="16" rx="3" fill="{color}"/>')
            strip.append(f'<text x="{x + 22}" y="29" fill="#c9d1d9" font-family="monospace" '
                         f'font-size="15" font-weight="700">{label}</text>')
            x += 22 + 16 + len(label) * 10 + 28

    inner = re.sub(r"</svg>$", "", re.sub(r"^<svg[^>]*>", "", svg))
    doc = (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h + leg_h}">'
        f"<style>{DG_CSS}</style>"
        f'<rect x="0" y="0" width="{w}" height="{h + leg_h}" fill="#0d1117"/>'
        + "".join(strip)
        + f'<g transform="translate(0,{leg_h})">{inner}</g></svg>'
    )
    cairosvg.svg2png(
        bytestring=doc.encode(), write_to=out,
        output_width=int(w * args.scale), output_height=int((h + leg_h) * args.scale),
        background_color="#0d1117",
    )
    print(f"{args.design} [{args.view}]: {w}x{h} -> {out} "
          f"({int(w * args.scale)}x{int((h + leg_h) * args.scale)}px) classes={[l for _, l in legend]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
