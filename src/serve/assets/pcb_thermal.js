// pcb_thermal.js — the heat-field overlay for the thermal page's board pane.
//
// Loaded only by /pcb-layout/<name>?embed=1&review=1&thermal=1, the read-only
// physical board the assembly page also embeds. It claims the pcb_board.js
// overlay seam (window.PCBOverlay) in EXCLUSIVE mode, so the board keeps its
// substrate, pads, bodies and silk while its copper, clearance and DRC markers
// step aside — a heat map read through a routed board is not readable.
//
// It never solves anything and never touches board state. The field comes from
// GET /api/thermal-field/<name>, which is the same cached solve
// /api/thermal/<name> reports its numbers from, so the picture and the table
// can never disagree. Scenario and ambient arrive from the parent page by
// postMessage (and from this frame's own query on first load, so a directly
// opened URL still shows what it says it shows).
//
// Contract marker strings (grepped by tests): PCBOverlay PCBOverlay.exclusive
// api/thermal-field thermal:view thermal:state pcb-thermal
(function () {
  "use strict";

  if (typeof PCB === "undefined") return;
  if (!window.PCBOverlay) return;

  // ── World-coordinate helpers ──────────────────────────────────────────
  // Same reconstruction pcb_replay.js makes from the same blob: the overlay is
  // invoked under the canvas transform paintTracks uses, so X()/Y() map mm to
  // svg units and every width scales by S.
  var S = PCB.scale || 1, MX = PCB.minx || 0, MY = PCB.miny || 0, M = PCB.margin || 0;
  function X(mm) { return (mm - MX + M) * S; }
  function Y(mm) { return (mm - MY + M) * S; }

  // ── View state ────────────────────────────────────────────────────────
  var q = new URLSearchParams(location.search);
  var view = {
    scenario: q.get("scenario") || "natural",
    ambient: parseFloat(q.get("ambient")),
    // The saved layout this frame is showing — the board's own URL already
    // carries it, since the parent had to name it to get this placement drawn.
    layout: q.get("layout") || "",
    side: "top",
    opacity: 0.8,
    labels: true,
  };
  if (!isFinite(view.ambient)) view.ambient = 25;

  var field = null;      // last successful /api/thermal-field payload
  var raster = null;     // that field's cells as a cols x rows offscreen canvas
  var seq = 0;           // request generation; a stale reply is dropped

  // ── Colour ramp ───────────────────────────────────────────────────────
  // The stops render_thermal_png.zig paints with, so the PNG export and the
  // live board are the same picture of the same numbers.
  var RAMP = [
    [0.00, 0x07, 0x14, 0x38],
    [0.28, 0x1a, 0x5f, 0xc8],
    [0.52, 0x2f, 0xc4, 0xd6],
    [0.76, 0xf2, 0xdc, 0x5a],
    [1.00, 0xe8, 0x40, 0x2a]
  ];
  // One absolute reference across every board, scenario and ambient. A field
  // colder than the floor stays at the cold end; one hotter than the ceiling
  // stays red. In particular, a successful heatsink no longer stretches its
  // modest peak back up to the same red as an overheating bare board.
  var SCALE_MIN_C = 25;
  var SCALE_MAX_C = 125;
  function temperatureNorm(tempC) {
    return (tempC - SCALE_MIN_C) / (SCALE_MAX_C - SCALE_MIN_C);
  }
  function ramp(t) {
    if (!(t > 0)) t = 0; else if (t > 1) t = 1;
    for (var i = 1; i < RAMP.length; i++) {
      if (t <= RAMP[i][0]) {
        var a = RAMP[i - 1], b = RAMP[i];
        var span = b[0] - a[0], f = span > 0 ? (t - a[0]) / span : 0;
        return [a[1] + (b[1] - a[1]) * f, a[2] + (b[2] - a[2]) * f, a[3] + (b[3] - a[3]) * f];
      }
    }
    var last = RAMP[RAMP.length - 1];
    return [last[1], last[2], last[3]];
  }
  function rampCss(t) { var c = ramp(t); return "rgb(" + (c[0] | 0) + "," + (c[1] | 0) + "," + (c[2] | 0) + ")"; }

  // ── The field raster ──────────────────────────────────────────────────
  // One pixel per solved cell, scaled up at paint time. The browser's own
  // bilinear filter does what the PNG's interpolation does, for the cost of a
  // drawImage — repainting a few thousand pixels every frame instead of the
  // hundreds of thousands the board covers.
  function buildRaster(f) {
    var g = f.grid, cols = g.cols, rows = g.rows;
    if (!cols || !rows) return null;
    var cv = document.createElement("canvas");
    cv.width = cols; cv.height = rows;
    var c = cv.getContext("2d");
    var img = c.createImageData(cols, rows);
    var hi = g.max_rise_c || 0;
    for (var i = 0; i < g.rise_c.length; i++) if (g.rise_c[i] > hi) hi = g.rise_c[i];
    for (var p = 0; p < cols * rows; p++) {
      var col = ramp(temperatureNorm(f.ambient_c + g.rise_c[p]));
      img.data[p * 4] = col[0]; img.data[p * 4 + 1] = col[1];
      img.data[p * 4 + 2] = col[2]; img.data[p * 4 + 3] = 255;
    }
    c.putImageData(img, 0, 0);
    return { cv: cv, hi: hi };
  }

  // ── Isotherm contours ─────────────────────────────────────────────────
  // Marching squares over the cell centres at the fractions the PNG draws, so
  // a reader can see where a gradient is steep instead of guessing it out of a
  // smooth wash. Segments are computed once per field and per level, in mm.
  function contour(g, level) {
    var segs = [], cols = g.cols, rows = g.rows, cell = g.cell_mm;
    function at(cx, cy) { return g.rise_c[cy * cols + cx]; }
    // Cell CENTRES are the sample lattice: a cell spans [origin+i*cell,
    // origin+(i+1)*cell], so its centre sits half a cell in.
    function px(cx) { return g.origin_x_mm + (cx + 0.5) * cell; }
    function py(cy) { return g.origin_y_mm + (cy + 0.5) * cell; }
    function lerp(a, b, va, vb) { var d = vb - va; return d === 0 ? a : a + (b - a) * ((level - va) / d); }
    for (var y = 0; y + 1 < rows; y++) {
      for (var x = 0; x + 1 < cols; x++) {
        var v0 = at(x, y), v1 = at(x + 1, y), v2 = at(x + 1, y + 1), v3 = at(x, y + 1);
        var code = (v0 > level ? 1 : 0) | (v1 > level ? 2 : 0) | (v2 > level ? 4 : 0) | (v3 > level ? 8 : 0);
        if (code === 0 || code === 15) continue;
        var x0 = px(x), x1 = px(x + 1), y0 = py(y), y1 = py(y + 1);
        var top = { x: lerp(x0, x1, v0, v1), y: y0 };
        var right = { x: x1, y: lerp(y0, y1, v1, v2) };
        var bottom = { x: lerp(x0, x1, v3, v2), y: y1 };
        var left = { x: x0, y: lerp(y0, y1, v0, v3) };
        var pts = [top, right, bottom, left];
        var pairs = ISO_CASES[code];
        for (var k = 0; k < pairs.length; k += 2) segs.push([pts[pairs[k]], pts[pairs[k + 1]]]);
      }
    }
    return segs;
  }
  // Edge pairs per corner code (0=top 1=right 2=bottom 3=left). The two
  // saddles (5, 10) get both segments; which way they connect does not change
  // where the line runs, only which lobe it joins.
  var ISO_CASES = {
    1: [3, 0], 2: [0, 1], 3: [3, 1], 4: [1, 2], 5: [3, 0, 1, 2], 6: [0, 2], 7: [3, 2],
    8: [2, 3], 9: [2, 0], 10: [0, 1, 2, 3], 11: [2, 1], 12: [1, 3], 13: [1, 0], 14: [0, 3]
  };

  // ── Part poses ────────────────────────────────────────────────────────
  // The board's own blob already carries every part's pose; asking the server
  // for geometry it is drawing anyway would be a second copy to keep in step.
  var byRef = {};
  (PCB.parts || []).forEach(function (p, i) { byRef[p.ref] = i; });
  function courtyardCentre(i) {
    var p = (PCB.parts || [])[i];
    if (!p) return null;
    var lx = p.ccx || 0, ly = p.ccy || 0;
    if (p.side === "bottom") lx = -lx;   // matches wpt() in pcb_board.js
    var a = (p.rot || 0) * Math.PI / 180, c = Math.cos(a), s = Math.sin(a);
    return { x: p.x + lx * c - ly * s, y: p.y + lx * s + ly * c, hw: p.hw || 0, hh: p.hh || 0 };
  }

  // ── Paint ─────────────────────────────────────────────────────────────
  function paint(ctx) {
    if (!field || !raster) return;
    var g = field.grid;
    var w = g.cols * g.cell_mm * S, h = g.rows * g.cell_mm * S;
    ctx.save();
    ctx.globalAlpha = view.opacity;
    var smooth = ctx.imageSmoothingEnabled;
    ctx.imageSmoothingEnabled = true;
    ctx.drawImage(raster.cv, X(g.origin_x_mm), Y(g.origin_y_mm), w, h);
    ctx.imageSmoothingEnabled = smooth;
    ctx.globalAlpha = 1;

    // Isotherms, faint and thin — a reference grid over the wash, not a second
    // picture competing with it.
    if (raster.iso) {
      ctx.lineWidth = 1;
      ctx.strokeStyle = "rgba(255,255,255,0.30)";
      ctx.beginPath();
      raster.iso.forEach(function (seg) {
        ctx.moveTo(X(seg[0].x), Y(seg[0].y));
        ctx.lineTo(X(seg[1].x), Y(seg[1].y));
      });
      ctx.stroke();
    }

    // The hotspot: the single number a reader looks for first.
    if (field.hotspot) {
      var hx = X(field.hotspot.x_mm), hy = Y(field.hotspot.y_mm);
      ctx.strokeStyle = "#ffffff";
      ctx.lineWidth = 1.6;
      ctx.beginPath(); ctx.arc(hx, hy, 7, 0, 6.2832); ctx.stroke();
      ctx.beginPath();
      ctx.moveTo(hx - 11, hy); ctx.lineTo(hx - 3, hy);
      ctx.moveTo(hx + 3, hy); ctx.lineTo(hx + 11, hy);
      ctx.moveTo(hx, hy - 11); ctx.lineTo(hx, hy - 3);
      ctx.moveTo(hx, hy + 3); ctx.lineTo(hx, hy + 11);
      ctx.stroke();
    }

    if (view.labels) paintLabels(ctx);
    ctx.restore();
  }

  // One chip on each part the screen has a junction temperature for. Parts the
  // model said nothing about (most passives) get nothing — an empty label would
  // read as "measured, and cool".
  function paintLabels(ctx) {
    ctx.font = "600 11px ui-monospace,SFMono-Regular,Menlo,monospace";
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    (field.parts || []).forEach(function (row) {
      var i = byRef[row.ref];
      if (i === undefined) return;
      var part = (PCB.parts || [])[i];
      if (!part || (part.side === "bottom" ? "bottom" : "top") !== view.side) return;
      var c = courtyardCentre(i);
      if (!c) return;
      var t = row.tj_c != null ? row.tj_c : row.board_c;
      if (t == null) return;
      var over = row.max_ambient_c != null && row.max_ambient_c < field.ambient_c;
      var text = row.ref + "  " + t.toFixed(0) + "°";
      var tw = ctx.measureText(text).width + 10;
      var x = X(c.x), y = Y(c.y);
      ctx.save();
      // The board shell mirrors the whole canvas for a physical bottom view.
      // Pre-mirror each screen-space chip around its own centre so its final
      // position follows the board while the temperature text stays readable.
      if (view.side === "bottom") { ctx.translate(2 * x, 0); ctx.scale(-1, 1); }
      ctx.fillStyle = over ? "rgba(150,20,12,0.92)" : "rgba(12,14,20,0.78)";
      roundRect(ctx, x - tw / 2, y - 9, tw, 18, 4);
      ctx.fill();
      ctx.strokeStyle = over ? "#ff6b5a" : "rgba(255,255,255,0.30)";
      ctx.lineWidth = 1;
      ctx.stroke();
      ctx.fillStyle = "#f2f4f8";
      ctx.fillText(text, x, y + 0.5);
      ctx.restore();
    });
  }
  function roundRect(ctx, x, y, w, h, r) {
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.arcTo(x + w, y, x + w, y + h, r);
    ctx.arcTo(x + w, y + h, x, y + h, r);
    ctx.arcTo(x, y + h, x, y, r);
    ctx.arcTo(x, y, x + w, y, r);
    ctx.closePath();
  }

  // ── Load ──────────────────────────────────────────────────────────────
  function repaint() {
    if (window.PCBRepaint) window.PCBRepaint();
  }
  function tell(msg) {
    try { if (window.parent && window.parent !== window) window.parent.postMessage(msg, "*"); } catch (e) {}
  }
  function load() {
    var mine = ++seq;
    tell({ t: "thermal:state", loading: true });
    // `layout` rides along verbatim: this frame is embedded by a page that may
    // be screening a NAMED saved layout, and a field solved over a different
    // board would be painted over these pads as if it were theirs.
    var url = "/api/thermal-field/" + encodeURIComponent(PCB.name) +
      "?scenario=" + encodeURIComponent(view.scenario) +
      "&ambient=" + encodeURIComponent(String(view.ambient)) +
      (view.layout ? "&layout=" + encodeURIComponent(view.layout) : "");
    fetch(url, { credentials: "same-origin" })
      .then(function (r) { if (!r.ok) throw new Error("HTTP " + r.status); return r.json(); })
      .then(function (j) {
        if (mine !== seq) return;                 // a newer request already won
        if (!j.available) {
          field = null; raster = null;
          tell({ t: "thermal:state", loading: false, unavailable: j.unavailable || "" });
          repaint();
          return;
        }
        field = j;
        raster = buildRaster(j);
        if (raster) {
          raster.iso = [];
          [0.2, 0.4, 0.6, 0.8].forEach(function (frac) {
            var tempC = SCALE_MIN_C + (SCALE_MAX_C - SCALE_MIN_C) * frac;
            raster.iso = raster.iso.concat(contour(j.grid, tempC - j.ambient_c));
          });
        }
        // The parent panel's hotspot readout uses the SAME payload rather than
        // fetching its own, so the two halves cannot show different scenarios.
        tell({
          t: "thermal:state", loading: false, scenario: j.scenario, ambient_c: j.ambient_c,
          hotspot: j.hotspot, converged: j.converged, max_rise_c: raster ? raster.hi : 0,
          parts: j.parts, skipped: j.skipped
        });
        repaint();
      })
      .catch(function (e) {
        if (mine !== seq) return;
        field = null; raster = null;
        tell({ t: "thermal:state", loading: false, error: String(e && e.message || e) });
        repaint();
      });
  }

  window.addEventListener("message", function (ev) {
    var d = ev.data;
    if (!d || d.t !== "thermal:view") return;
    var refetch = false;
    if (d.scenario && d.scenario !== view.scenario) { view.scenario = d.scenario; refetch = true; }
    if (typeof d.ambient === "number" && isFinite(d.ambient) && d.ambient !== view.ambient) {
      view.ambient = d.ambient; refetch = true;
    }
    if (typeof d.opacity === "number") view.opacity = Math.max(0, Math.min(1, d.opacity));
    if (typeof d.labels === "boolean") view.labels = d.labels;
    if (d.side === "top" || d.side === "bottom") view.side = d.side;
    if (refetch) load(); else repaint();
  });

  window.PCBOverlay.paint = paint;
  window.PCBOverlay.exclusive = true;   // copper/clearance/DRC step aside
  window.PCBOverlay.ghost = false;
  // Exposed for diagnostics and tests so a direct board frame can state the
  // exact absolute range behind its colours.
  window.PCBThermal = {
    ramp: rampCss, reload: load, view: view,
    scaleMinC: SCALE_MIN_C, scaleMaxC: SCALE_MAX_C
  };
  load();
})();
