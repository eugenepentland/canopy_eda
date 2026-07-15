/* footprint_svg.js — the single footprint-drawing engine.
 *
 * One renderer shared by the library footprint preview, the schematic sidebar's
 * component view, and the PCB-layout page. It draws KiCad-imported footprint
 * geometry (pads incl. custom polygons, silkscreen, fabrication outline,
 * courtyard) into an SVG, in millimetre coordinates (Y-down, matching KiCad and
 * the footprint .sexp). A pad-shape change lands here once and every page
 * follows.
 *
 * Data shape (from GET /api/footprint/:name):
 *   { bbox:{x,y,w,h}, bounds:{x,y,w,h},
 *     pads:[{id,x,y,w,h,shape,poly?,drill?,npth?}],
 *     silk:{lines:[[x1,y1,x2,y2]…],circles:[[cx,cy,r]…],rects:[[x0,y0,x1,y1]…],polys:[[[x,y]…]…]},
 *     fab:{ …same… },
 *     courtyard:{rects:[[x0,y0,x1,y1]…],circles:[[cx,cy,r]…]} }
 * `bbox` is the padded SVG viewport; `bounds` is the exact geometry union.
 *
 * API:
 *   FP.drawFootprint(svgEl, data, opts) — draw a whole footprint (library/schematic).
 *   FP.padShape(pad, opts)              — one pad as an SVG element (PCB layout per-part).
 *   FP.padLabel(pad, scale)            — the pad-id text element (or null).
 */
window.FP = (function () {
  var NS = "http://www.w3.org/2000/svg";
  // Layer palette — mirrors KiCad so a preview reads like the board editor.
  var C = { pad: "#c4a000", silk: "#888", fab: "#5b7089", court: "#9d5fb0", label: "#161b22", bg: "#161b22" };

  function el(name, attrs) {
    var e = document.createElementNS(NS, name);
    for (var k in attrs) if (attrs[k] !== undefined && attrs[k] !== null) e.setAttribute(k, attrs[k]);
    return e;
  }
  function n3(v) { return (+v).toFixed(3); }

  // One pad as an SVG element. opts:
  //   scale (px per mm, default 1), minPx (min rect side in px, default 0),
  //   cls (CSS class — when set, fill is left to CSS; else copper-gold fill),
  //   attrs (extra attributes, e.g. {"data-net": …}).
  // Custom pads with a polygon draw the real outline; everything else is a
  // circle (round) or rect (rect/roundrect/oval/custom-without-poly).
  function padShape(pad, opts) {
    opts = opts || {};
    var sc = opts.scale || 1, minPx = opts.minPx || 0;
    var a = {}, k;
    if (opts.attrs) for (k in opts.attrs) a[k] = opts.attrs[k];
    if (opts.cls) a["class"] = opts.cls;
    // Default copper fill only when the caller hasn't supplied a class (CSS
    // drives fill) or an explicit fill in attrs.
    if (a.fill === undefined && a["class"] === undefined) a.fill = C.pad;

    if (pad.poly && pad.poly.length >= 3) {
      a.points = pad.poly.map(function (p) { return n3(p[0] * sc) + "," + n3(p[1] * sc); }).join(" ");
      return el("polygon", a);
    }
    if (pad.shape === "circle") {
      a.cx = n3(pad.x * sc); a.cy = n3(pad.y * sc); a.r = n3(Math.max(pad.w, pad.h) / 2 * sc);
      return el("circle", a);
    }
    var pw = Math.max(pad.w * sc, minPx), ph = Math.max(pad.h * sc, minPx);
    a.x = n3(pad.x * sc - pw / 2); a.y = n3(pad.y * sc - ph / 2);
    a.width = n3(pw); a.height = n3(ph);
    a.rx = pad.shape === "oval" ? n3(Math.min(pw, ph) / 2) : n3(0.03 * sc);
    return el("rect", a);
  }

  // The drilled bore of a through-hole / NPTH pad: a board-coloured disc (with a
  // faint outline so it reads as a hole, not missing copper) centred on the pad.
  // Returns null for SMD pads (no drill). Honours the same `scale` as padShape.
  function padHole(pad, opts) {
    opts = opts || {};
    var sc = opts.scale || 1;
    if (!(pad.drill > 0)) return null;
    return el("circle", {
      cx: n3(pad.x * sc), cy: n3(pad.y * sc), r: n3(pad.drill / 2 * sc),
      fill: opts.holeFill || C.bg, stroke: "#0a0d12", "stroke-width": n3(0.05 * sc),
    });
  }

  // The pad-id label, centred on the pad and scaled to its short side (multi-
  // char ids shrink so they stay inside the copper). The library preview keys
  // off `pad.id`; the PCB-layout blob uses `pad.num` — accept either. Null when
  // the pad has no identifier or no area.
  function padLabel(pad, scale) {
    var sc = scale || 1;
    var id = pad.id || pad.num;
    if (!id) return null;
    var base = Math.min(pad.w, pad.h);
    if (base <= 0) return null;
    var fs = base * 0.62;
    if (id.length > 1) fs = fs * 1.5 / id.length;
    var t = el("text", {
      x: n3(pad.x * sc), y: n3(pad.y * sc), "font-size": n3(fs * sc), fill: C.label,
      "text-anchor": "middle", "dominant-baseline": "central", "font-family": "sans-serif",
    });
    t.textContent = id;
    return t;
  }

  function drawLayer(svg, d, color) {
    if (!d) return;
    (d.polys || []).forEach(function (poly) {
      svg.appendChild(el("polygon", {
        points: poly.map(function (p) { return n3(p[0]) + "," + n3(p[1]); }).join(" "),
        fill: color, "fill-opacity": "0.55", stroke: color, "stroke-width": "0.04",
      }));
    });
    (d.rects || []).forEach(function (r) {
      svg.appendChild(el("rect", {
        x: n3(Math.min(r[0], r[2])), y: n3(Math.min(r[1], r[3])),
        width: n3(Math.abs(r[2] - r[0])), height: n3(Math.abs(r[3] - r[1])),
        fill: "none", stroke: color, "stroke-width": "0.08",
      }));
    });
    (d.circles || []).forEach(function (c) {
      svg.appendChild(el("circle", { cx: n3(c[0]), cy: n3(c[1]), r: n3(c[2]), fill: "none", stroke: color, "stroke-width": "0.08" }));
    });
    (d.lines || []).forEach(function (s) {
      svg.appendChild(el("line", { x1: n3(s[0]), y1: n3(s[1]), x2: n3(s[2]), y2: n3(s[3]), stroke: color, "stroke-width": "0.08", "stroke-linecap": "round" }));
    });
  }

  // Draw a whole footprint into `svg` (cleared first): courtyard (dashed) behind
  // fab + silkscreen, pads + id labels on top. opts.bg=false skips the bg style.
  function drawFootprint(svg, data, opts) {
    opts = opts || {};
    while (svg.firstChild) svg.removeChild(svg.firstChild);
    var b = data.bbox || { x: -2, y: -2, w: 4, h: 4 };
    svg.setAttribute("viewBox", n3(b.x) + " " + n3(b.y) + " " + n3(b.w) + " " + n3(b.h));
    if (opts.bg !== false) svg.style.background = C.bg;

    var ct = data.courtyard || {};
    (ct.rects || []).forEach(function (r) {
      svg.appendChild(el("rect", {
        x: n3(Math.min(r[0], r[2])), y: n3(Math.min(r[1], r[3])),
        width: n3(Math.abs(r[2] - r[0])), height: n3(Math.abs(r[3] - r[1])),
        fill: "none", stroke: C.court, "stroke-width": "0.05", "stroke-dasharray": "0.2 0.12",
      }));
    });
    (ct.circles || []).forEach(function (c) {
      svg.appendChild(el("circle", { cx: n3(c[0]), cy: n3(c[1]), r: n3(c[2]), fill: "none", stroke: C.court, "stroke-width": "0.05", "stroke-dasharray": "0.2 0.12" }));
    });

    drawLayer(svg, data.fab, C.fab);
    drawLayer(svg, data.silk, C.silk);

    (data.pads || []).forEach(function (p) {
      svg.appendChild(padShape(p, { scale: 1 }));
      var hole = padHole(p, { scale: 1 });
      if (hole) svg.appendChild(hole);
      var lbl = padLabel(p, 1);
      if (lbl) svg.appendChild(lbl);
    });
  }

  return { drawFootprint: drawFootprint, padShape: padShape, padHole: padHole, padLabel: padLabel, el: el, colors: C, NS: NS };
})();
