// pcb_dxf.js — client-side ASCII DXF board-outline importer for the PCB
// editor (the ⤒ DXF button next to ▭ Outline / ⬡ Poly).
//
// The picked .dxf is parsed entirely in the browser (the file never leaves
// the machine) and its closed loops are offered as the board outline — the
// same saved override the ▭/⬡ tools produce, so the result is drawn by every
// renderer, checked by the board-edge DRC, emitted on the Edge.Cuts Gerber,
// and persisted by the ordinary Save/Update path (PCB.outline → layout
// sidecar). No server endpoint is involved.
//
// Loaded AFTER pcb_board.js. It must stay a classic script (it reads the
// page's lexical `const PCB` binding), but pcb_board.js is an IIFE — its
// functions are not globals — so the board-mutation apply path is reached
// through its exported window.PCBDxfSeams seam, the same way the replay /
// session / stuck clients reach theirs.
(function () {
  "use strict";

  // ── Constants ─────────────────────────────────────────────────────────
  // $INSUNITS → mm. Unitless (0) and unknown codes assume mm — the dialog
  // still lets the user force a unit, because units are the classic DXF trap.
  var INSUNITS = {
    0:  { name: "unitless", to_mm: 1 },
    1:  { name: "inches", to_mm: 25.4 },
    2:  { name: "feet", to_mm: 304.8 },
    3:  { name: "miles", to_mm: 1609344 },
    4:  { name: "mm", to_mm: 1 },
    5:  { name: "cm", to_mm: 10 },
    6:  { name: "m", to_mm: 1000 },
    7:  { name: "km", to_mm: 1000000 },
    8:  { name: "microinches", to_mm: 0.0000254 },
    9:  { name: "mils", to_mm: 0.0254 },
    10: { name: "yards", to_mm: 914.4 },
    11: { name: "angstroms", to_mm: 1e-7 },
    12: { name: "nanometers", to_mm: 1e-6 },
    13: { name: "microns", to_mm: 0.001 },
  };
  var MAX_BYTES = 20 * 1024 * 1024;
  var SAG = 0.01;        // arc tessellation sagitta (mm) — under fab tolerance
  var MAX_VERTS = 2000;  // per-loop vertex cap; sagitta rises to stay under it
  // Endpoint-snap tolerance when assembling a contour from LINE/ARC entities.
  // Real-world outline exports (AutoCAD/Fusion/…) leave sub-µm seams where a
  // contour was drawn in pieces, so coincident endpoints are merged into one
  // vertex at 10 µm — far under fab tolerance, but enough to heal the join.
  var MERGE_TOL = 0.01;
  var DUP_TOL = 1e-7;    // mm — consecutive-duplicate vertex tolerance
  var INF = 1e18;

  function num(v) {
    var n = parseFloat(v);
    return isFinite(n) ? n : NaN;
  }

  // ── ASCII DXF tokenizer ───────────────────────────────────────────────
  // A DXF is a flat list of (group code, value) line pairs; codes always sit
  // on their own line. A stray non-numeric code line is read as a 0 (entity
  // boundary) so a damaged file degrades instead of silently misreading
  // coordinates.
  function dxfTokens(text) {
    var lines = text.split(/\r\n|\r|\n/);
    var out = [];
    for (var i = 0; i < lines.length; i++) {
      var c = parseInt(lines[i].trim(), 10);
      if (!isFinite(c)) { out.push({ c: 0, v: lines[i].trim() }); continue; }
      var v = (i + 1 < lines.length) ? lines[i + 1].trim() : "";
      out.push({ c: c, v: v });
      i++; // the value consumed the next line
    }
    return out;
  }

  // ── Arc tessellation ──────────────────────────────────────────────────
  // Points along the arc from A→B with DXF bulge b (positive = CCW, Y-up),
  // A and B excluded (the caller owns the vertices) and every chord within
  // `sag` mm of the true arc. Degenerate bulges — zero chord, flat, or a
  // full circle (which cannot form a loop edge) — return [].
  function bulgeArcPts(ax, ay, bx, by, bulge, sag) {
    var out = [];
    var dx = bx - ax, dy = by - ay;
    var chord = Math.hypot(dx, dy);
    if (Math.abs(bulge) < 1e-12 || chord < 1e-9) return out;
    var theta = 4 * Math.atan(bulge); // signed included angle
    if (Math.abs(theta) > Math.PI * 2 - 1e-9) return out; // full circle
    var radius = Math.abs(chord / (2 * Math.sin(theta / 2)));
    if (!isFinite(radius) || radius < 1e-9) return out;
    // Center on the normal the bulge points toward, at the distance the
    // chord/radius/angle identities fix (negative for major arcs).
    var mx = (ax + bx) / 2, my = (ay + by) / 2;
    var ux = -dy / chord, uy = dx / chord;
    var h = radius * Math.cos(theta / 2) * Math.sign(bulge);
    var cx = mx + ux * h, cy = my + uy * h;
    var a0 = Math.atan2(ay - cy, ax - cx);
    var step = 2 * Math.acos(Math.max(-1, Math.min(1, 1 - sag / radius)));
    var n = Math.max(1, Math.ceil(Math.abs(theta) / step));
    for (var k = 1; k < n; k++) {
      var a = a0 + theta * (k / n);
      out.push([cx + radius * Math.cos(a), cy + radius * Math.sin(a)]);
    }
    return out;
  }

  // Intermediate points of a DXF ARC entity (center, radius, start/end in
  // degrees, CCW in Y-up), endpoints excluded, chord error ≤ `sag` mm.
  function arcEntityPts(cx, cy, r, a0deg, a1deg, sag) {
    var out = [];
    if (!(isFinite(cx) && isFinite(cy) && isFinite(r) && r > 1e-9)) return out;
    var a0 = a0deg * Math.PI / 180, a1 = a1deg * Math.PI / 180;
    var sweep = ((a1 - a0) % (2 * Math.PI) + 2 * Math.PI) % (2 * Math.PI);
    if (sweep < 1e-9) return out;
    var step = 2 * Math.acos(Math.max(-1, Math.min(1, 1 - sag / r)));
    var n = Math.max(1, Math.ceil(sweep / step));
    for (var k = 1; k < n; k++) {
      var a = a0 + sweep * (k / n);
      out.push([cx + r * Math.cos(a), cy + r * Math.sin(a)]);
    }
    return out;
  }

  // ── Loop hygiene ──────────────────────────────────────────────────────
  // Drop consecutive duplicate vertices (and a trailing copy of the first),
  // then prune vertices exactly collinear with both neighbours — redundant
  // points DXF exporters love to emit. The shape is unchanged.
  function cleanPts(pts) {
    if (!pts.length) return [];
    var out = [];
    for (var i = 0; i < pts.length; i++) {
      var p = pts[i], prev = out[out.length - 1];
      if (prev && Math.hypot(p[0] - prev[0], p[1] - prev[1]) <= DUP_TOL) continue;
      out.push(p);
    }
    if (out.length > 1 &&
        Math.hypot(out[0][0] - out[out.length - 1][0], out[0][1] - out[out.length - 1][1]) <= DUP_TOL)
      out.pop();
    if (out.length < 3) return out;
    var pruned = [];
    for (var j = 0; j < out.length; j++) {
      var a = out[(j + out.length - 1) % out.length], b = out[j], c = out[(j + 1) % out.length];
      var cross = (b[0] - a[0]) * (c[1] - b[1]) - (b[1] - a[1]) * (c[0] - b[0]);
      var len = Math.max(Math.hypot(b[0] - a[0], b[1] - a[1]), Math.hypot(c[0] - b[0], c[1] - b[1]), 1e-9);
      if (Math.abs(cross) / len > DUP_TOL * 4) pruned.push(b);
    }
    return pruned.length >= 3 ? pruned : out;
  }

  function twiceArea(pts) {
    var s = 0, n = pts.length;
    for (var i = 0; i < n; i++) {
      var a = pts[i], b = pts[(i + 1) % n];
      s += a[0] * b[1] - b[0] * a[1];
    }
    return s;
  }

  function loopBBox(pts) {
    var minx = INF, miny = INF, maxx = -INF, maxy = -INF;
    for (var i = 0; i < pts.length; i++) {
      if (pts[i][0] < minx) minx = pts[i][0];
      if (pts[i][0] > maxx) maxx = pts[i][0];
      if (pts[i][1] < miny) miny = pts[i][1];
      if (pts[i][1] > maxy) maxy = pts[i][1];
    }
    return { x: minx, y: miny, w: maxx - minx, h: maxy - miny };
  }

  // A candidate board outline: raw DXF-unit points (Y already flipped to the
  // board's y-down frame), its layer, and derived stats for the picker.
  // Degenerate loops (no area / zero bbox) are rejected here.
  function makeLoop(pts, layer, closed, extra) {
    var bb = loopBBox(pts);
    var area = Math.abs(twiceArea(pts)) / 2;
    if (!isFinite(area) || area < 1e-6 || bb.w <= 0 || bb.h <= 0) return null;
    var l = (layer || "").toLowerCase();
    var edgeish = /edge|outline|profile|board|contour|cut/i.test(l) ? 1 : 0;
    return {
      pts: pts,
      layer: layer || "",
      closed: !!closed,
      edgeish: edgeish,
      area: area,
      w: bb.w, h: bb.h,
      n: pts.length,
      arcs: (extra && extra.arcs) || 0,
      chained: !!(extra && extra.chained),
    };
  }

  // Build one loop from a polyline's vertices (each with optional bulge).
  // `closedFlag` is the 70-bit; a polyline whose last vertex repeats the
  // first is treated as closed either way. Arc edges are tessellated, and a
  // per-loop vertex cap is enforced by raising the sagitta when needed.
  function polylineLoop(verts, closedFlag, layer) {
    var n = verts.length;
    if (n < 2) return null;
    var first = verts[0], last = verts[n - 1];
    var repeats = Math.hypot(first.x - last.x, first.y - last.y) <= DUP_TOL;
    var closed = !!(closedFlag & 1) || repeats;
    var count = closed ? n - (repeats ? 1 : 0) : n;
    if (count < 3) return null;
    var pts = [];
    var sag = SAG;
    var guard = 0;
    for (;;) {
      pts.length = 0;
      var arcs = 0;
      for (var i = 0; i < count; i++) {
        var a = verts[i], b = verts[(i + 1) % count];
        pts.push([a.x, a.y]);
        if (a.bulge) {
          var mid = bulgeArcPts(a.x, a.y, b.x, b.y, a.bulge, sag);
          arcs += mid.length;
          for (var k = 0; k < mid.length; k++) pts.push(mid[k]);
        }
      }
      // Coarsen arc chords only while that actually shrinks the loop; a
      // straight-only polyline (no arcs) or the 10-doubling guard terminates
      // the loop even if a file ships thousands of exact vertices.
      if (arcs === 0 || pts.length <= MAX_VERTS || guard >= 10) break;
      sag *= 2;
      guard += 1;
    }
    var clean = cleanPts(pts);
    if (clean.length < 3) return null;
    return makeLoop(clean, layer, closed, { arcs: arcs });
  }

  // Chain LINE + ARC entities into closed loops. A real outline DXF is often a
  // loose string of LINE/ARC entities rather than a polyline, and the string is
  // rarely clean: exports leave sub-µm endpoint seams and part of the contour
  // comes back with the opposite winding. So this builds an undirected segment
  // graph (near-coincident endpoints snapped into shared vertices) and walks it
  // in either direction — a winding mismatch cannot strand the walk, and a
  // snapped seam still joins. Only walks that return to their start are kept.
  function chainLoops(segs) {
    if (!segs.length) return [];
    // ── Snap endpoints into vertices ──
    var clusters = []; // {x,y} — first-seen coordinate wins
    var live = [];     // {seg, a, b} — cluster indices, zero-length dropped
    function clusterFor(x, y) {
      for (var i = 0; i < clusters.length; i++) {
        if (Math.hypot(clusters[i].x - x, clusters[i].y - y) <= MERGE_TOL) return i;
      }
      clusters.push({ x: x, y: y });
      return clusters.length - 1;
    }
    for (var i = 0; i < segs.length; i++) {
      var s = segs[i];
      var a = clusterFor(s.ax, s.ay);
      var b = clusterFor(s.bx, s.by);
      if (a === b) continue; // zero-length after snapping
      live.push({ seg: s, a: a, b: b });
    }
    if (!live.length) return [];
    var adj = [];
    for (var v = 0; v < clusters.length; v++) adj.push([]);
    for (var j = 0; j < live.length; j++) {
      adj[live[j].a].push(j);
      adj[live[j].b].push(j);
    }
    var used = [];
    for (var k = 0; k < live.length; k++) used.push(false);
    var loops = [];
    for (var start = 0; start < live.length; start++) {
      if (used[start]) continue;
      used[start] = true;
      // Walk from live[start], traversable in either direction. Never step
      // straight back onto the edge just traversed: duplicate contours (a
      // profile drawn twice over itself) otherwise make the walk retrace the
      // duplicate and produce a zero-area out-and-back instead of the loop.
      var chain = [{ idx: start, from: live[start].a, to: live[start].b }];
      var origin = live[start].a, cur = live[start].b, prev = live[start].a;
      var closed = false;
      while (cur !== origin) {
        var next = -1, nextFrom = -1;
        var cands = adj[cur];
        for (var c = 0; c < cands.length; c++) {
          var li = cands[c];
          if (used[li]) continue;
          var other = (live[li].a === cur) ? live[li].b : live[li].a;
          if (other === prev) continue; // backtracking
          next = li;
          nextFrom = cur;
          break;
        }
        if (next < 0) break; // dead end
        used[next] = true;
        var nl = live[next];
        var to = (nl.a === cur) ? nl.b : nl.a;
        chain.push({ idx: next, from: cur, to: to });
        prev = cur;
        cur = to;
        if (cur === origin) { closed = true; break; }
      }
      if (!closed) continue;
      // Emit loop points in traversal order, tessellating arcs along the way.
      // An arc traversed opposite its authored direction still describes the
      // same curve — its chord points are emitted in reverse.
      var pts = [], arcs = 0;
      for (var c2 = 0; c2 < chain.length; c2++) {
        var item = chain[c2], s2 = live[item.idx].seg;
        pts.push([clusters[item.from].x, clusters[item.from].y]);
        if (s2.arc) {
          var mid = arcEntityPts(s2.cx, s2.cy, s2.r, s2.a0, s2.a1, SAG);
          arcs += mid.length;
          var fwd = Math.hypot(clusters[item.from].x - s2.ax, clusters[item.from].y - s2.ay) <= MERGE_TOL;
          for (var m = 0; m < mid.length; m++)
            pts.push(fwd ? mid[m] : mid[mid.length - 1 - m]);
        }
      }
      if (pts.length > MAX_VERTS) continue;
      var clean = cleanPts(pts);
      if (clean.length < 3) continue;
      var loop = makeLoop(clean, live[chain[0].idx].seg.layer, true, { arcs: arcs, chained: true });
      if (loop) loops.push(loop);
    }
    return loops;
  }

  // ── Parse ─────────────────────────────────────────────────────────────
  // window.PCBDxfParse(text) → {error} | {units:{code,name,to_mm,known},
  // loops:[…sorted best-first…], warnings:[…]}. Loops are in RAW DXF units
  // with Y flipped to the board's y-down frame; the caller applies the unit
  // scale when committing.
  function parseDxf(text) {
    var warnings = [];
    if (text.length > MAX_BYTES)
      return { error: "file too large (" + Math.ceil(text.length / 1048576) + " MB — DXF outlines are usually a few KB)" };
    if (text.charCodeAt(0) === 0x1a || text.indexOf("AutoCAD Binary DXF") === 0)
      return { error: "binary DXF is not supported — re-export the drawing as ASCII DXF" };
    var toks = dxfTokens(text);

    // Pass 1: $INSUNITS / $MEASUREMENT from the HEADER (degrees of freedom
    // only — the values themselves are read in the entity pass).
    var units = { code: 0, name: "unitless", to_mm: 1, known: false };
    for (var t = 0; t + 1 < toks.length; t++) {
      if (toks[t].c === 9) {
        var is_units = toks[t].v === "$INSUNITS", is_meas = toks[t].v === "$MEASUREMENT";
        if (is_units || is_meas) {
          var val = parseInt(toks[t + 1].v, 10);
          if (isFinite(val)) {
            // 0 = "unitless" tells us nothing — let $MEASUREMENT (or the mm
            // default) answer instead of claiming a unit we do not have.
            if (is_units && val !== 0 && INSUNITS[val]) {
              units = { code: val, name: INSUNITS[val].name, to_mm: INSUNITS[val].to_mm, known: true };
            } else if (is_meas && !units.known) {
              // English (0) / metric (1) only — a weaker hint than $INSUNITS.
              units = val === 0
                ? { code: 1, name: "inches", to_mm: 25.4, known: true }
                : { code: 4, name: "mm", to_mm: 1, known: true };
            }
          }
        }
      }
    }

    // Pass 2: walk the ENTITIES section collecting polylines and segments.
    var polys = [], segs = [];
    var in_entities = false, ent = null;

    function flushPolyline() {
      if (!ent || ent.type !== "POLYLINE") return;
      var verts = ent.verts.filter(function (v) { return !v.skip && isFinite(v.x) && isFinite(v.y); });
      var loop = polylineLoop(verts, ent.closed, ent.layer);
      if (loop) polys.push(loop);
    }
    function closeEntity() {
      if (!ent) return;
      if (ent.type === "LWPOLYLINE") {
        var loop = polylineLoop(ent.verts, ent.closed, ent.layer);
        if (loop) polys.push(loop);
      } else if (ent.type === "POLYLINE") {
        flushPolyline();
      } else if (ent.type === "LINE") {
        if (isFinite(ent.x1) && isFinite(ent.y1) && isFinite(ent.x2) && isFinite(ent.y2))
          segs.push({ ax: ent.x1, ay: ent.y1, bx: ent.x2, by: ent.y2, layer: ent.layer });
      } else if (ent.type === "ARC") {
        if (isFinite(ent.cx) && isFinite(ent.cy) && isFinite(ent.r))
          segs.push({ ax: ent.cx + ent.r * Math.cos(ent.a0 * Math.PI / 180), ay: ent.cy + ent.r * Math.sin(ent.a0 * Math.PI / 180),
                      bx: ent.cx + ent.r * Math.cos(ent.a1 * Math.PI / 180), by: ent.cy + ent.r * Math.sin(ent.a1 * Math.PI / 180),
                      arc: true, cx: ent.cx, cy: ent.cy, r: ent.r, a0: ent.a0, a1: ent.a1, layer: ent.layer });
      } else if (ent.type === "CIRCLE") {
        if (isFinite(ent.cx) && isFinite(ent.cy) && isFinite(ent.r) && ent.r > 1e-9) {
          // A full circle: split into one smooth closed loop.
          var pts = [];
          var step = 2 * Math.acos(Math.max(-1, Math.min(1, 1 - SAG / ent.r)));
          var n = Math.max(3, Math.ceil((2 * Math.PI) / step));
          for (var k = 0; k < n; k++) {
            var a = 2 * Math.PI * (k / n);
            pts.push([ent.cx + ent.r * Math.cos(a), ent.cy + ent.r * Math.sin(a)]);
          }
          var loop = makeLoop(pts, ent.layer, true, { arcs: n });
          if (loop) polys.push(loop);
        }
      }
      ent = null;
    }

    for (var i = 0; i < toks.length; i++) {
      var tok = toks[i];
      // Section name travels as the value of group code 2 (0/SECTION then
      // 2/HEADER or 2/ENTITIES) — it gates the entity walk below.
      if (tok.c === 2) {
        if (tok.v === "ENTITIES") in_entities = true;
        else if (tok.v === "HEADER") in_entities = false;
        continue;
      }
      if (tok.c !== 0) {
        if (ent) {
          var c = tok.c, v = tok.v;
          if (ent.type === "LWPOLYLINE") {
            if (c === 10) ent.verts.push({ x: num(v), y: 0, bulge: 0 });
            else if (c === 20 && ent.verts.length) ent.verts[ent.verts.length - 1].y = num(v);
            else if (c === 42 && ent.verts.length) ent.verts[ent.verts.length - 1].bulge = num(v) || 0;
            else if (c === 70) ent.closed = parseInt(v, 10) || 0;
            else if (c === 8) ent.layer = v;
          } else if (ent.type === "POLYLINE") {
            // A VERTEX sub-entity was pushed onto ent.verts; its group codes
            // (10/20/42/70) mutate the LAST vertex, while the polyline's own
            // 70/8 (before any vertex) set the closed flag / layer.
            var lv = ent.verts.length ? ent.verts[ent.verts.length - 1] : null;
            if (lv) {
              if (c === 10) lv.x = num(v);
              else if (c === 20) lv.y = num(v);
              else if (c === 42) lv.bulge = num(v) || 0;
              else if (c === 70) lv.skip = (parseInt(v, 10) & 128) !== 0; // curve-fit extras
              else if (c === 8) ent.layer = v;
            } else {
              if (c === 70) ent.closed = parseInt(v, 10) || 0;
              else if (c === 8) ent.layer = v;
            }
          } else if (ent.type === "VERTEX") {
            // Belongs to the enclosing POLYLINE (started below); the 128 bit
            // marks curve-fit extra vertices, which we must not emit.
            if (c === 10) ent.verts.push({ x: num(v), y: 0, bulge: 0, skip: false });
            else if (c === 20 && ent.verts.length) ent.verts[ent.verts.length - 1].y = num(v);
            else if (c === 42 && ent.verts.length) ent.verts[ent.verts.length - 1].bulge = num(v) || 0;
            else if (c === 70 && ent.verts.length) ent.verts[ent.verts.length - 1].skip = (parseInt(v, 10) & 128) !== 0;
            else if (c === 8) ent.layer = v;
          } else if (ent.type === "LINE") {
            if (c === 10) ent.x1 = num(v); else if (c === 20) ent.y1 = num(v);
            else if (c === 11) ent.x2 = num(v); else if (c === 21) ent.y2 = num(v);
            else if (c === 8) ent.layer = v;
          } else if (ent.type === "ARC") {
            if (c === 10) ent.cx = num(v); else if (c === 20) ent.cy = num(v);
            else if (c === 40) ent.r = num(v);
            else if (c === 50) ent.a0 = num(v); else if (c === 51) ent.a1 = num(v);
            else if (c === 8) ent.layer = v;
          } else if (ent.type === "CIRCLE") {
            if (c === 10) ent.cx = num(v); else if (c === 20) ent.cy = num(v);
            else if (c === 40) ent.r = num(v); else if (c === 8) ent.layer = v;
          }
        }
        continue;
      }
      var name = tok.v;
      if (name === "ENDSEC" || name === "EOF") { in_entities = false; closeEntity(); continue; }
      if (!in_entities) continue;
      // VERTEX / SEQEND are sub-entities of an open POLYLINE — reaching one
      // must NOT close the polyline (its vertices are still coming).
      if (!(ent && ent.type === "POLYLINE" && (name === "VERTEX" || name === "SEQEND")))
        closeEntity(); // a new 0-code closes the previous entity
      if (name === "LWPOLYLINE") ent = { type: "LWPOLYLINE", verts: [], closed: 0, layer: "" };
      else if (name === "POLYLINE") ent = { type: "POLYLINE", verts: [], closed: 0, layer: "" };
      else if (name === "VERTEX") {
        if (ent && ent.type === "POLYLINE") ent.verts.push({ x: NaN, y: 0, bulge: 0, skip: false });
        else ent = { type: "VERTEX", verts: [], layer: "" }; // orphaned — ignored
      } else if (name === "SEQEND") { flushPolyline(); ent = null; }
      else if (name === "LINE") ent = { type: "LINE", x1: NaN, y1: NaN, x2: NaN, y2: NaN, layer: "" };
      else if (name === "ARC") ent = { type: "ARC", cx: NaN, cy: NaN, r: NaN, a0: 0, a1: 0, layer: "" };
      else if (name === "CIRCLE") ent = { type: "CIRCLE", cx: NaN, cy: NaN, r: NaN, layer: "" };
      else ent = null; // unknown entity — swallow its group codes
    }
    closeEntity();

    // LINE/ARC/CIRCLE entities only chain when no polyline produced a loop —
    // in a normal export they are annotations (dimensions, notes), not the
    // outline, and chaining them would only fabricate junk candidates.
    if (!polys.length && segs.length) {
      var chained = chainLoops(segs);
      if (chained.length) {
        polys = chained;
        warnings.push("outline assembled from " + segs.length + " line/arc segments");
      }
    }
    // An open polyline is still a candidate (the model closes it implicitly,
    // like the ⬡ Poly tool) but ranked below closed loops.
    var open_polys = polys.filter(function (p) { return !p.closed; });
    var closed_polys = polys.filter(function (p) { return p.closed; });
    function rank(a, b) { return (b.edgeish - a.edgeish) || (b.closed - a.closed) || (b.area - a.area); }
    var loops = closed_polys.concat(open_polys).sort(rank);
    if (polys.length && !closed_polys.length)
      warnings.push("no explicitly closed polyline found — the largest open one is treated as the outline");
    if (loops.length > 1)
      warnings.push(loops.length + " loops found — pick the board outline below");
    var total_arcs = 0;
    for (var q = 0; q < loops.length; q++) total_arcs += loops[q].arcs;
    if (total_arcs)
      warnings.push("arcs tessellated to straight chords (≤ " + SAG + " mm sagitta)");

    // Flip Y: DXF is y-up, the board frame is y-down. A pure mirror keeps
    // the drawing's appearance identical; winding is irrelevant to the model.
    for (var f = 0; f < loops.length; f++) {
      var pts = loops[f].pts;
      for (var g = 0; g < pts.length; g++) pts[g][1] = -pts[g][1];
    }
    return { units: units, loops: loops, warnings: warnings };
  }

  window.PCBDxfParse = function (text) {
    try { return parseDxf(text); } catch (e) { return { error: String((e && e.message) || e) }; }
  };

  // ── Editor integration ────────────────────────────────────────────────
  // One hidden file input for the whole page lifetime; the button just opens
  // it. Reading the file never touches the network — the parse above is local.
  // The page emits its board blob as a lexical `const PCB=…` (never a
  // window property — see static_assets' contract test), so gate on the
  // binding the same way pcb_board.js does.
  var RO = typeof PCB !== "undefined" && !!PCB.ro;
  var fileInput = null;

  function dxfFileInput() {
    if (fileInput) return fileInput;
    fileInput = document.createElement("input");
    fileInput.type = "file";
    fileInput.accept = ".dxf,.DXF,application/dxf";
    fileInput.style.display = "none";
    document.body.appendChild(fileInput);
    fileInput.addEventListener("change", function () {
      var f = fileInput.files && fileInput.files[0];
      fileInput.value = ""; // allow re-picking the same file
      if (!f) return;
      var rd = new FileReader();
      rd.onerror = function () { dxfMsg("could not read " + f.name); };
      rd.onload = function () { dxfParsed(rd.result, f.name); };
      rd.readAsText(f);
    });
    return fileInput;
  }

  function dxfMsg(txt, color) {
    var msg = document.getElementById("pcb-savemsg");
    if (!msg) return;
    msg.style.color = color || "#8b949e";
    msg.textContent = txt;
  }

  function dxfParsed(text, fileName) {
    var parsed = window.PCBDxfParse(text);
    if (!parsed || parsed.error) { dxfMsg("DXF import failed: " + (parsed && parsed.error || "unreadable file"), "#f85149"); return; }
    if (!parsed.loops || !parsed.loops.length) {
      dxfMsg("DXF import failed: no closed outline found in " + fileName, "#f85149");
      return;
    }
    dxfDialog(parsed, fileName);
  }

  // The picker: units (Auto = the file's $INSUNITS, or forced mm/inch) and —
  // when the file carries several loops — which one becomes the outline.
  // Enter applies, Esc cancels; keystrokes never leak to the board shortcuts.
  function dxfDialog(parsed, fileName) {
    var svg = document.getElementById("pcb-svg");
    var host = svg ? svg.parentNode : null;
    if (!host) return;
    var dlg = document.createElement("div");
    dlg.className = "dxf-dlg";
    dlg.style.cssText = "position:absolute;z-index:60;background:#161b22;border:1px solid #30363d;" +
      "border-radius:6px;padding:12px;font:12px system-ui;color:#c9d1d9;box-shadow:0 6px 22px rgba(0,0,0,.6);min-width:320px;max-width:420px";
    var hr = host.getBoundingClientRect(), sr = svg.getBoundingClientRect();
    dlg.style.left = Math.max(8, (sr.left - hr.left) + (sr.width / 2) - 170) + "px";
    dlg.style.top = Math.max(8, (sr.top - hr.top) + (sr.height / 2) - 90) + "px";

    var title = document.createElement("div");
    title.textContent = "Import DXF — board outline";
    title.style.cssText = "font-weight:600;margin-bottom:8px;color:#7ee787";
    dlg.appendChild(title);
    var src = document.createElement("div");
    src.textContent = fileName;
    src.style.cssText = "color:#8b949e;font-size:11px;margin-bottom:8px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap";
    dlg.appendChild(src);

    function row(label, node) {
      var r = document.createElement("label");
      r.style.cssText = "display:flex;align-items:center;gap:8px;margin:5px 0";
      var s = document.createElement("span");
      s.textContent = label;
      s.style.cssText = "width:46px;color:#8b949e;flex:none";
      r.appendChild(s); r.appendChild(node); return r;
    }
    var selStyle = "flex:1;min-width:150px;background:#0d1117;border:1px solid #30363d;color:#c9d1d9;border-radius:4px;padding:3px";

    // Units — Auto names the file's own declaration so the default is honest.
    var usel = document.createElement("select");
    usel.style.cssText = selStyle;
    var autoLabel = parsed.units.known
      ? ("Auto — " + parsed.units.name + " (from file)")
      : "Auto — mm (file has no units)";
    var uo = document.createElement("option"); uo.value = "auto"; uo.textContent = autoLabel; usel.appendChild(uo);
    var uomm = document.createElement("option"); uomm.value = "4"; uomm.textContent = "mm"; usel.appendChild(uomm);
    var uoin = document.createElement("option"); uoin.value = "1"; uoin.textContent = "inch (×25.4)"; usel.appendChild(uoin);

    // Loop picker (hidden when there is exactly one candidate).
    var lsel = null;
    if (parsed.loops.length > 1) {
      lsel = document.createElement("select");
      lsel.style.cssText = selStyle;
      for (var i = 0; i < parsed.loops.length; i++) {
        var lp = parsed.loops[i];
        var o = document.createElement("option");
        o.value = String(i);
        o.textContent = (lp.layer || "(no layer)") + " · " +
          (lp.closed ? "closed" : "open") + " · " +
          lp.w.toFixed(2) + "×" + lp.h.toFixed(2) + " mm · " + lp.n + " verts";
        lsel.appendChild(o);
      }
      lsel.value = "0";
    }

    // Preview + warnings.
    var prev = document.createElement("div");
    prev.style.cssText = "margin:8px 2px 2px;color:#e6edf3;font-size:12px";
    var warn = document.createElement("div");
    warn.style.cssText = "margin:2px 2px 4px;color:#d8a03c;font-size:11px;line-height:1.4";

    function unitScale() {
      var v = usel.value;
      if (v === "auto") return parsed.units.to_mm;
      var u = INSUNITS[parseInt(v, 10)];
      return u ? u.to_mm : parsed.units.to_mm; // unknown → file units
    }
    function chosenLoop() {
      var idx = lsel ? parseInt(lsel.value, 10) : 0;
      return parsed.loops[idx];
    }
    function updatePreview() {
      var lp = chosenLoop(), s = unitScale();
      var w = lp.w * s, h = lp.h * s;
      prev.textContent = "→ " + w.toFixed(2) + " × " + h.toFixed(2) + " mm · " + lp.n + " vertices" +
        (lp.arcs ? " · " + lp.arcs + " arc points" : "");
      warn.textContent = parsed.warnings.join(" · ");
      var btn = document.getElementById("dxf-apply");
      if (btn) btn.disabled = w < 2 || h < 2;
    }

    dlg.appendChild(row("Units", usel));
    if (lsel) dlg.appendChild(row("Loop", lsel));
    dlg.appendChild(prev);
    dlg.appendChild(warn);
    // Inline error line — validation failures keep the dialog open so another
    // loop / unit can be tried instead of forcing a re-import.
    var err = document.createElement("div");
    err.style.cssText = "margin:4px 2px 0;color:#f85149;font-size:11px;line-height:1.35;display:none";
    dlg.appendChild(err);

    var ba = document.createElement("div");
    ba.style.cssText = "margin-top:10px;display:flex;gap:6px;justify-content:flex-end";
    var cancel = document.createElement("button"); cancel.textContent = "Cancel"; cancel.className = "btn";
    var ok = document.createElement("button"); ok.id = "dxf-apply"; ok.textContent = "Apply outline"; ok.className = "btn";
    ok.style.cssText = "border-color:#2ea043;color:#7ee787";

    function close() { if (dlg.parentNode) dlg.parentNode.removeChild(dlg); }
    function commit() {
      var lp = chosenLoop(), s = unitScale();
      var pts = [];
      for (var k = 0; k < lp.pts.length; k++) pts.push([lp.pts[k][0] * s, lp.pts[k][1] * s]);
      var bb = loopBBox(pts);
      err.style.display = "none";
      if (bb.w < 2 || bb.h < 2) {
        err.textContent = "This outline is too small to save — a board needs at least 2 mm each side.";
        err.style.display = "block";
        return;
      }
      if (window.PCBDxfSeams.selfIntersects(pts)) {
        err.textContent = "This outline self-intersects — pick another loop or fix the drawing, then Apply again.";
        err.style.display = "block";
        return;
      }
      close();
      var seams = window.PCBDxfSeams;
      var pre = seams.snapAll();
      // Disarm the drawing tools so none of their armed state fights the new
      // outline on the next click.
      seams.disarmTools();
      PCB.outline = { x: 0, y: 0, w: 0, h: 0, pts: pts };
      seams.outlineBboxSync();
      seams.recordUndo(pre);
      seams.markDirty();
      seams.drawBoardRect();
      seams.scheduleDrc();
      dxfMsg("DXF outline imported (" + bb.w.toFixed(2) + " × " + bb.h.toFixed(2) + " mm, " + pts.length + " vertices) — Save/Update to keep", "#7ee787");
    }
    cancel.addEventListener("click", close);
    ok.addEventListener("click", commit);
    ba.appendChild(cancel); ba.appendChild(ok); dlg.appendChild(ba);
    dlg.addEventListener("keydown", function (ev) {
      ev.stopPropagation();
      if (ev.key === "Enter") { ev.preventDefault(); commit(); }
      else if (ev.key === "Escape") { ev.preventDefault(); close(); }
    });
    usel.addEventListener("change", updatePreview);
    if (lsel) lsel.addEventListener("change", updatePreview);
    host.appendChild(dlg);
    updatePreview();
    ok.focus();
  }

  // Wire the ⤒ DXF button wherever it exists: the full-page tool strip and
  // the embed action bar share the id (only one is ever rendered).
  var btn = document.getElementById("pcb-outline-dxf");
  if (btn) btn.addEventListener("click", function () {
    if (RO) return;
    dxfFileInput().click();
  });
})();
