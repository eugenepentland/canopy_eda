// Shared DRC input marshaling — assembles the wasm DRC payload from the
// /pcb-layout page blob (`PCB`) plus live editor state, in the exact JSON schema
// src/wasm_drc.zig parses. Dependency-free and dual-target: it defines a plain
// global `buildDrcInput` (usable from a classic <script> or a worker
// `importScripts`) AND, under Node, exports it via `module.exports` so the
// parity harness can `require()` it.
//
// Net-name spelling matters. The blob emits PAD nets dot-collapsed to the rail
// (pcb_layout_page.zig `netKey`: the substring before the first '.'), while
// routed tracks/vias and net-classes carry the RAW net name. The wasm interns
// net strings verbatim and compares copper "same net" by string equality, so
// this module collapses track/via/net-class names the SAME way — keeping pads
// and copper on one key. On boards using the `<rail>.<ic>.<pad>` bypass-stub
// convention this merges the per-stub nets under their shared rail (the one
// place the wasm can diverge from the server, which keeps them distinct); the
// viewer's parity telemetry surfaces any such drift.

// Collapse a net name to its rail key, exactly as pcb_layout_page.zig netKey.
function collapseNet(s) {
  if (!s) return s;
  var i = s.indexOf(".");
  return i >= 0 ? s.slice(0, i) : s;
}

// Assemble the wasm DRC input object from the page blob + live state.
//   PCB  — the /pcb-layout page blob (source of geometry, rules, net-classes).
//   live — optional overrides captured from the live editor:
//            {parts, tracks, vias, outline, clearance}. Any field left out
//            falls back to the blob's own value. Parts already carry live poses
//            (the viewer mutates PCB.parts[i].x/y/rot/side in place), so passing
//            PCB.parts through captures the current placement.
function buildDrcInput(PCB, live) {
  PCB = PCB || {};
  live = live || {};
  var parts = live.parts || PCB.parts || [];
  var tracks = live.tracks || PCB.tracks || [];
  var vias = live.vias || PCB.vias || [];
  // A drawn / live outline overrides the authored `(board …)` rect, mirroring
  // the server's /api/pcb-drc handling of the POST `outline` field. A rectangle
  // outline has no `pts`; a polygon (⬠ Poly) outline carries its exact vertices.
  var outline = (live.outline !== undefined) ? live.outline : (PCB.outline || null);
  var clearance = (live.clearance != null) ? live.clearance : (PCB.clr || 0);
  var board = null, boardPoly = null;
  if (outline && outline.w > 0 && outline.h > 0) {
    board = { x: outline.x, y: outline.y, w: outline.w, h: outline.h };
    boardPoly = (outline.pts && outline.pts.length) ?
      ((typeof window !== "undefined" && window.PCBOutlinePoly) ? window.PCBOutlinePoly(outline) : outline.pts) : null;
  } else {
    board = PCB.board || null;
    boardPoly = (PCB.board_poly && PCB.board_poly.length) ? PCB.board_poly : null;
  }
  var out = {
    clearance: clearance,
    rules: PCB.rules || {},
    keepouts: PCB.keepouts || [],
    // Pass parts through: each already carries ref/x/y/rot/side/kind/hw/hh/
    // ccx/ccy/pads/silk in the wasm's schema; unknown extra keys are ignored.
    parts: parts,
    tracks: tracks.reduce(function (out, t) {
      var segs = (typeof window !== "undefined" && window.PCBTrackChords) ? window.PCBTrackChords(t) : [t];
      segs.forEach(function (s) { out.push({ x1: s.x1, y1: s.y1, x2: s.x2, y2: s.y2,
        l: t.l || 0, w: t.w, net: collapseNet(t.net) }); });
      return out;
    }, []),
    vias: vias.map(function (v) {
      return { x: v.x, y: v.y, d: v.d, drill: v.drill, net: collapseNet(v.net) };
    }),
    rf_paths: (live.rf_paths || PCB.rf_paths || []).map(function (p) {
      return { net: collapseNet(p.net), l: p.l || 0, samples: p.samples || [] };
    }),
    netclasses: (PCB.netclasses || []).map(function (c) {
      // keepout_mm / keepout_escape_mm ride along so the client engine can run
      // the RF same-layer keepout check; without them the browser would report
      // zero keepout violations on a board the server flags. `class` is the
      // other half of that: a class's own members owe each other no halo, so
      // without the identity the browser would flag every filter-chain neighbour
      // the server passes.
      return {
        net: collapseNet(c.net), class: c.class, width: c.width, clearance: c.clearance,
        via_dia: c.via_dia, via_drill: c.via_drill,
        max_freq_hz: c.max_freq_hz, impedance_ohms: c.impedance_ohms,
        diff_impedance_ohms: c.diff_impedance_ohms,
        pad_neck_width: c.pad_neck_width, pad_neck_max_length: c.pad_neck_max_length,
        pad_neck_taper_length: c.pad_neck_taper_length,
        keepout_mm: c.keepout_mm, keepout_escape_mm: c.keepout_escape_mm
      };
    }),
    // Differential pairs — net names dot-collapsed like every other copper key,
    // so a pair binds to the same interned net as its tracks in the wasm.
    diffpairs: (PCB.diffpairs || []).map(function (d) {
      return { p: collapseNet(d.p), n: collapseNet(d.n), gap: d.gap };
    })
  };
  if (board) out.board = board;
  if (boardPoly) out.board_poly = boardPoly;
  // The board's copper stack, straight off the blob's one layer table. Without
  // it the client engine had NO stackup at all: every board looked like the
  // legacy implicit four-layer model with two routable faces, so on a declared
  // six-layer board its layer arithmetic (and every layer name it could report)
  // disagreed with the server's. Rows are `{i,l,kind,net}` — physical stack
  // index, routable index or null, signal/plane, and the poured net collapsed
  // to the same rail key every other net name here is.
  if (PCB.layer_table && PCB.layer_table.length) {
    out.layer_table = PCB.layer_table.map(function (r) {
      return { i: r.i, l: (typeof r.l === "number") ? r.l : null,
        kind: r.kind || "signal", net: r.net ? collapseNet(r.net) : null };
    });
  }
  // Declared plane/pour nets, so the keepout check knows which copper is a
  // reference (never an RF aggressor). ABSENT is load-bearing: it means "no
  // (stackup …) form", under which the engine falls back to the ground-name
  // predicate. An empty array would claim a stackup that pours nothing.
  if (PCB.plane_nets) out.planes = PCB.plane_nets.map(collapseNet);
  // With no (stackup …) form the engine also plants an inner plane on the
  // block's dominant supply rail, so that net has to cross the bridge too —
  // otherwise the client calls its pads unplaned, the server calls them planed,
  // and every edit ends in a wasm/server mismatch reconcile.
  else if (PCB.implicit_rail) out.implicit_rail = collapseNet(PCB.implicit_rail);
  return out;
}

// Dual-target export: Node parity harness require() vs. browser/worker global.
if (typeof module !== "undefined" && module.exports) {
  module.exports = { buildDrcInput: buildDrcInput, collapseNet: collapseNet };
}
