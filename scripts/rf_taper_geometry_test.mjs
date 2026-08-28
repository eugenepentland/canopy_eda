#!/usr/bin/env node
// Behavioral probes for the browser's variable-width RF and power geometry.
// These use the Barracuda launches/corridor that exposed a folded sweep, an
// off-centre pad exit, and a power trace that could not pass its neighbour.

import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const boardPath = fileURLToPath(new URL("../src/serve/assets/pcb_board.js", import.meta.url));
const source = fs.readFileSync(boardPath, "utf8");
const require = createRequire(import.meta.url);

function functionSource(name) {
  const start = source.indexOf(`function ${name}(`);
  assert.notEqual(start, -1, `missing ${name}`);
  let i = source.indexOf("{", start);
  let depth = 0;
  for (; i < source.length; i++) {
    if (source[i] === "{") depth++;
    else if (source[i] === "}" && --depth === 0) return source.slice(start, i + 1);
  }
  throw new Error(`unterminated ${name}`);
}

function load(names, globals = {}) {
  const context = vm.createContext({ console, Math, ...globals });
  vm.runInContext(names.map(functionSource).join("\n"), context);
  return context;
}

{
  const document = { getElementById() { return { value: "net" }; } };
  const PCB = { rules: { track_width: 0.127, min_width: 0.1 }, zones: [] };
  const g = load(["trackW", "drawPowerTarget", "drawNetGeometry"], {
    PCB,
    document,
    netClassInfo() { return { width: 0.4, adaptive_power_width: 0.4 }; },
    baseTrackW() { return 0.127; },
  });
  assert.deepEqual({ ...g.drawNetGeometry("V_12V_RAW") }, { width: 0.127, target: 0.4 },
    "a current-rated rail must steer at ordinary routing width while retaining its electrical target");

  PCB.zones = [{ net: "V_12V_RAW", keepout: false }];
  assert.deepEqual({ ...g.drawNetGeometry("V_12V_RAW") }, { width: 0.127, target: 0.4 },
    "a local eFuse zone must not disable adaptive widening on the rest of the rail");
}

{
  const g = load(["drawTaperProfile"], {
    PCB: { rules: { track_width: 0.127, min_width: 0.1 } },
    netClassInfo() { return {
      width: 0.4,
      adaptive_power_width: 0.4,
      pad_neck_width: 0.1524,
      pad_neck_max_length: 0.75,
      pad_neck_taper_length: 0.35,
    }; },
    baseTrackW() { return 0.127; },
  });
  const pad = { pd: { w: 0.3, h: 2.4 } };
  const profile = g.drawTaperProfile("V_12V_RAW", pad, 0.4, { land: 1.2, span: 0.3 });
  assert.equal(profile.kind, "power");
  assert.notEqual(profile.width, 0.1524, "a generic authored escape must not override the adaptive pad-sized launch");
  assert(Math.abs(profile.width - 0.3) < 1e-12,
    "the power launch must use the pad's smaller physical dimension, independent of route angle");
  assert(Math.abs(profile.land - 1.2) < 1e-12, "the power taper must begin at the measured pad boundary");
  assert(Math.abs(profile.taper - 0.05) < 1e-12,
    "a 0.3-to-0.4 mm launch needs only 0.05 mm for 45-degree copper flanks");
}

{
  const floor = 0.127;
  const target = 0.4;
  const g = load(["drawProfileWidth", "drawAdaptiveStations", "drawAdaptiveClearWidth", "drawAdaptivePowerRun"], {
    DRAW_ADAPTIVE_STEP: 0.05,
    trackLength(t) { return Math.hypot(t.x2 - t.x1, t.y2 - t.y1); },
    drawTrackPoint(t, f) { return { x: t.x1 + (t.x2 - t.x1) * f, y: t.y1 + (t.y2 - t.y1) * f }; },
    trackIdEnsure(t) { return t.id; },
    segViolation(x1, _y1, x2, _y2, _layer, _net, hw) {
      const x = (x1 + x2) / 2;
      const limit = x > 1.1 && x < 1.9 ? 0.22 : target;
      return 2 * hw > limit + 1e-9 ? { k: "clearance" } : null;
    },
  });
  const track = { id: "power-owner", net: "V_12V_RAW", l: 0, x1: 0, y1: 0, x2: 3, y2: 0 };
  const start = { kind: "power", width: 0.3, land: 0.3, taper: 0.05, step: 0.0125 };
  const plan = g.drawAdaptivePowerRun([track], start, null, floor, target);
  assert.equal(plan.paths.length, 1);
  const samples = plan.paths[0].samples;
  function widthAt(x) {
    const sample = samples.find((s) => Math.abs(s[0] - x) < 1e-8);
    assert(sample, `missing exact adaptive station at ${x}`);
    return sample[2];
  }
  assert(Math.abs(widthAt(0) - 0.3) < 1e-8, "the launch must start at the pad's 0.3 mm minimum dimension");
  assert(Math.abs(widthAt(0.3) - 0.3) < 1e-8, "the taper must not begin before the pad boundary");
  assert(Math.abs(widthAt(0.35) - 0.4) < 2e-4, "the compact taper must reach the 0.4 mm target after 0.05 mm");
  assert(samples.some((s) => s[0] > 1.2 && s[0] < 1.8 && s[2] <= 0.2202),
    "the physical path must neck down only where the neighbouring trace constrains it");
  assert(samples.some((s) => s[0] > 2.2 && s[2] > 0.399), "open copper must recover the full electrical target");
  samples.forEach((s, i) => {
    assert(s[2] >= floor - 1e-9, "adaptive copper must never fall below the routing floor");
    if (!i) return;
    const prior = samples[i - 1];
    const distance = Math.hypot(s[0] - prior[0], s[1] - prior[1]);
    assert(Math.abs(s[2] - prior[2]) <= 2 * distance + 1e-8,
      "adjacent adaptive widths must retain 45-degree-or-shallower flanks");
  });
}

{
  const g = load(["drawCompactTaperProfile"]);
  const wide = { kind: "rf", width: 0.6, land: 0.2, taper: 0.48, step: 0.08, portal: { id: 1 } };
  const compact = g.drawCompactTaperProfile(wide, 0.4, 0.25);
  assert.equal(compact.taper, 0.12, "a blocked wide-land flare must be shortened by the requested scale");
  assert.equal(compact.step, 0.02, "compaction must retain the taper's sampling density");
  assert.equal(compact.portal, wide.portal, "compaction must preserve the pad-contained portal collar");
  assert.notEqual(compact, wide, "compaction must not mutate the full-size preview profile");
  const narrow = { kind: "rf", width: 0.2, taper: 0.48, step: 0.08 };
  assert.equal(g.drawCompactTaperProfile(narrow, 0.4, 0.25), narrow,
    "a narrow-land taper must not be shortened toward a wider, less-clear trace");
}

{
  const PCB = { vias: [{ x: 0, y: 0, d: 0.6, net: "RF" }], rules: { min_width: 0.1, track_width: 0.2 } };
  const globals = {
    PCB,
    netClassInfo() { return { width: 0.2, impedance_ohms: 50, diff_impedance_ohms: 0 }; },
    baseTrackW() { return 0.2; },
  };
  const g = load(["drawSamePointXY", "drawEndpointVia", "drawPathPadLaunch", "drawTaperProfile"], globals);
  const via = g.drawEndpointVia("RF", 0, 0);
  assert(via?.via, "a through-via must resolve as an RF taper endpoint");
  assert.equal(g.drawEndpointVia("OTHER", 0, 0), null, "a foreign via must not become this net's endpoint");
  const launch = g.drawPathPadLaunch(null, via, true);
  assert.equal(launch.span, 0.6);
  assert.equal(launch.land, 0.3);
  const profile = g.drawTaperProfile("RF", via, 0.2, launch);
  assert.equal(profile.width, 0.6, "the flare must meet the through-via's actual copper diameter");
  assert.equal(profile.land, 0.3, "the via diameter must be held through the annulus edge");
  assert.equal(profile.taper, 0.24);
  assert.equal(profile.portal, null, "a circular via needs no rectangular pad collar");
}

{
  const PCB = { vias: [{ x: 0, y: 0, d: 0.6, net: "RF" }], rules: { min_width: 0.1, track_width: 0.2 } };
  let nextId = 0;
  const globals = {
    PCB,
    netClassInfo() { return { width: 0.2, impedance_ohms: 50, diff_impedance_ohms: 0 }; },
    baseTrackW() { return 0.2; },
    trackArcGeom() { return null; },
    trackLength(t) { return Math.hypot(t.x2 - t.x1, t.y2 - t.y1); },
    trackChords(t) { return [t]; },
    trackIdEnsure(t) { return t.id || (t.id = `t${++nextId}`); },
    trackIdNew() { return `s${++nextId}`; },
  };
  const g = load([
    "drawSamePointXY", "drawEndpointVia", "drawPathPadLaunch", "drawTaperProfile",
    "drawProfileWidth", "drawTrackPoint", "drawTrackPiece", "drawTaperTracks", "drawTaperPath",
    "drawTaperPortalPath", "drawSamePortalPath", "drawTaperPathSet", "drawRfTaperPlan",
  ], globals);
  const plan = g.drawRfTaperPlan([
    { x1: -2, y1: 0, x2: 0, y2: 0, l: 0, w: 0.2, net: "RF" },
    { x1: 0, y1: 0, x2: 2, y2: 0, l: 1, w: 0.2, net: "RF" },
  ], null, null, 0.2);
  assert.equal(plan.paths.length, 2, "a layer transition must get one taper path on each connected face");
  assert.equal(plan.paths[0].samples.at(-1)[2], 0.6, "the incoming face must widen into the via");
  assert.equal(plan.paths[1].samples[0][2], 0.6, "the outgoing face must leave at the via diameter");
  assert(plan.paths.every((path) => new Set(path.samples.map((s) => s[2])).size > 1),
    "both via faces must carry a real variable-width transition");
}

{
  const track = { id: "via-run", x1: 0, y1: 0, x2: 2, y2: 0, l: 0, w: 0.2, net: "RF" };
  const PCB = { tracks: [track], vias: [{ x: 0, y: 0, d: 0.6, net: "RF" }] };
  let seededVia = null;
  const globals = {
    PCB,
    P: [],
    drawEndpointPad() { return null; },
    netClassInfo() { return { width: 0.2, impedance_ohms: 50, diff_impedance_ohms: 0 }; },
    baseTrackW() { return 0.2; },
    trackIdEnsure(t) { return t.id; },
    rfOwnsTrack() { return false; },
    drawTrackEndDirection() { return { x: 1, y: 0 }; },
    drawTaperProfile(_net, land) { return land?.via ? { width: land.via.d } : null; },
    drawRfRetrofitRun(_track, _reverse, _nominal, land) {
      seededVia = land;
      return [{ net: "RF", l: 0, samples: [[0, 0, 0.6], [1, 0, 0.2]] }];
    },
  };
  const g = load([
    "drawSamePointXY", "drawEndpointVia", "drawEndpointLand", "drawReverseTrack", "drawRfRetrofitGroups",
  ], globals);
  const groups = g.drawRfRetrofitGroups();
  assert.equal(groups.length, 1, "saved nominal-width copper must seed a retrofit from its through-via endpoint");
  assert.equal(seededVia?.via, PCB.vias[0]);
}

{
  const g = load(["segsCross", "polySelfIntersects", "polyContains", "rfRingFolded", "rfFallbackRegions"]);
  const points = [
    [143.96, 105.45],
    [144.22, 105.45],
    [144.22, 105.5],
  ];
  const widths = [0.56, 0.56, 0.56];
  const folded = [
    [143.96, 105.73],
    [143.94, 105.73],
    [143.94, 105.5],
    [144.5, 105.5],
    [144.5, 105.17],
    [143.96, 105.17],
  ];
  assert(g.polySelfIntersects(folded), "ADF terminal-jog fixture must fold");
  const regions = g.rfFallbackRegions(points, widths, folded);
  assert.equal(regions.length, 3);
  assert(!regions.some(g.polySelfIntersects), "fallback regions must stay simple");
  assert(regions.some((polygon) => g.polyContains(polygon, 144.0, 105.55)), "fallback clipped valid earlier copper");
  assert(g.rfRingFolded([[0, 0], [2, 0], [1, 0], [1, 1], [0, 1]]), "collinear retrace must lower through the fallback");
}

{
  const g = load(["rfCleanSamples", "rfRingFolded", "rfFallbackRegions", "rfCompactRing"]);
  const cleaned = g.rfCleanSamples([
    [0, 0, 0.2],
    [0, 0, 0.4],
    [1, 0, 0.3],
    [1, 0, 0.1],
  ]);
  assert.equal(cleaned.pts.length, 2, "consecutive duplicate stations must collapse");
  assert.equal(cleaned.ws[0], 0.4, "a collapsed station must retain its widest copper");
  assert.equal(cleaned.ws[1], 0.3, "the max-width merge must apply at every station");
  const ring = g.rfCompactRing(cleaned.pts, cleaned.ws);
  assert.equal(ring.length, 4, "a cleaned straight run must retain a compact ring");
  assert(ring.every((point) => point.every(Number.isFinite)), "cleaned compact geometry must stay finite");
  assert.equal(g.rfFallbackRegions(cleaned.pts, cleaned.ws, ring).length, 1);

  const coincident = g.rfCleanSamples([
    [2, 3, 0.1],
    [2, 3, 0.5],
    [2, 3, 0.25],
  ]);
  assert.equal(coincident.pts.length, 1, "an all-coincident path must collapse to one station");
  assert.equal(coincident.ws[0], 0.5, "all-coincident cleaning must retain the maximum width");
  assert.equal(g.rfCompactRing(coincident.pts, coincident.ws).length, 0, "an all-coincident path must not emit a ring");
  assert.equal(g.rfFallbackRegions(coincident.pts, coincident.ws, []).length, 0, "an all-coincident path must not emit fallback copper");
}

{
  // Barracuda F4.1 is 0.55 mm wide across the route but only 0.25 mm long.
  // Its adjacent F4.2 ground land begins 0.375 mm behind the RF pad centre.
  // The old max-width capsule invented a 0.275 mm round cap and saw only a
  // 0.100 mm gap; the actual butt-ended taper is comfortably clear at 0.127 mm.
  const P = [{ side: "top", pads: [{ net: "GND" }] }];
  const g = load([
    "polyContains", "ptSegDist", "segSegDist", "rfCleanSamples", "rfRingFolded",
    "rfFallbackRegions", "rfCompactRing", "drawPolyRectGap", "drawTaperPathsPadViolation",
  ], {
    P,
    netClrFor() { return 0.127; },
    sameNet(a, b) { return a && b && a === b; },
    wrect() { return { x0: -0.625, y0: -0.275, x1: -0.375, y1: 0.275 }; },
  });
  const path = [{ net: "LO1_DRIVE", l: 0, samples: [
    [0, 0, 0.55], [0.125, 0, 0.55], [0.353, 0, 0.19], [1, 0, 0.19],
  ] }];
  assert(!g.drawTaperPathsPadViolation(path, 0, "LO1_DRIVE"),
    "F4.1's exact butt-ended taper must clear the adjacent F4.2 ground land");
}

{
  const { buildDrcInput } = require("../src/serve/assets/drc_marshal.js");
  const PCB = {
    tracks: [{ id: "old", x1: 0, y1: 0, x2: 1, y2: 0, l: 0, w: 0.2, net: "RF" }],
    rf_paths: [{ net: "RF", l: 0, track_ids: ["old"], samples: [[0, 0, 0.3], [1, 0, 0.2]] }],
  };
  const candidateTrack = { id: "new", x1: 2, y1: 0, x2: 3, y2: 0, l: 0, w: 0.2, net: "RF" };
  const candidatePath = { net: "RF", l: 0, track_ids: ["new"], samples: [[2, 0, 0.4], [3, 0, 0.2]] };
  const input = buildDrcInput(PCB, { tracks: [candidateTrack], rf_paths: [candidatePath] });
  assert.equal(input.tracks.length, 1, "an explicit trial RF path must replace its own compact handle");
  assert.equal(input.tracks[0].x1, 2);
  assert.equal(input.tracks[0].w, 0.4);
}

{
  const globals = {
    PCB: { rules: { min_width: 0.1 } },
    wpt(_i, x, y) {
      return { x, y };
    },
    drawReverseTrack(t) {
      return { x1: t.x2, y1: t.y2, x2: t.x1, y2: t.y1, l: t.l || 0, w: t.w, net: t.net || "" };
    },
    trackChords(t) {
      return [t];
    },
    trackLength(t) {
      return Math.hypot(t.x2 - t.x1, t.y2 - t.y1);
    },
    netClassInfo() {
      return { width: 0.18993671363271875, impedance_ohms: 50 };
    },
    baseTrackW() {
      return 0.18993671363271875;
    },
  };
  const g = load(["drawPadFrame", "drawPadPortal", "drawPathPadLaunch", "drawTaperProfile", "drawTaperPortalPath", "drawSamePortalPath"], globals);
  const points = [
    [149.70000000000002, 104.98],
    [149.70000000000002, 105],
    [149.66193976625587, 105.19134171618309],
    [149.63390958983942, 105.24844006892205],
    [149.6145384401762, 105.27956731142432],
    [149.59293848866537, 105.30919143604933],
    [149.56922586931807, 105.33715316612384],
    [149.55355339059363, 105.3535533905945],
    [149.5435280750872, 105.36330216298292],
    [149.51598327239037, 105.38749783427886],
    [149.48673955824634, 105.40961008988818],
    [149.39134171618286, 105.4619397662577],
    [149.20000000000002, 105.500000000003],
  ];
  const tracks = points.slice(1).map((point, i) => ({
    x1: points[i][0],
    y1: points[i][1],
    x2: point[0],
    y2: point[1],
    l: 0,
    w: 0.18335412052887323,
    net: "DIV_RAW",
  }));
  const pad = { i: 0, pd: { x: points[0][0], y: points[0][1], w: 0.56, h: 0.62, rot: 90, shape: "roundrect" } };
  const launch = g.drawPathPadLaunch(tracks, pad, true);
  assert(launch?.portal);
  assert(launch.land > 0.28 && launch.land < 0.31, `wrong path land ${launch.land}`);
  const collar = g.drawTaperPortalPath({ kind: "rf", portal: launch.portal }, tracks[0], tracks[0].w);
  const [a, b] = collar.samples;
  assert(Math.abs(Math.hypot(b[0] - a[0], b[1] - a[1]) - 0.24) < 1e-7, "collar capsule must fit inside the roundrect flat face");
  assert.equal(a[2], 0.1, "collar must meet the fabrication minimum width");
  const oldMid = { x: (launch.portal.a.x + launch.portal.b.x) / 2, y: (launch.portal.a.y + launch.portal.b.y) / 2 };
  const newMid = { x: (a[0] + b[0]) / 2, y: (a[1] + b[1]) / 2 };
  assert(Math.abs(newMid.x - (oldMid.x - launch.portal.out.x * 0.05)) < 1e-7);
  assert(Math.abs(newMid.y - (oldMid.y - launch.portal.out.y * 0.05)) < 1e-7,
    "collar centreline must move inward by its probe radius");
  assert(g.drawSamePortalPath(collar, { net: collar.net, l: collar.l, samples: [b, a] }), "reversed saved collar must be recognized after reload");
  assert(!g.drawSamePortalPath(collar, { net: "OTHER", l: 0, samples: [b, a] }), "another net must not suppress a collar");
  assert(!g.drawSamePortalPath(collar, { net: collar.net, l: 1, samples: [b, a] }), "another layer must not suppress a collar");

  for (const shape of ["rect", "roundrect", "oval"])
    assert(g.drawPadFrame({ i: 0, pd: { x: 0, y: 0, w: 1, h: 0.6, shape } }).portalOk, `${shape} must expose a flat portal`);
  for (const shape of ["circle", "custom"])
    assert(!g.drawPadFrame({ i: 0, pd: { x: 0, y: 0, w: 1, h: 0.6, shape } }).portalOk, `${shape} must not expose a flat portal`);
  assert(!g.drawPadFrame({ i: 0, pd: { x: 0, y: 0, w: 1, h: 0.6, shape: "rect", poly: [[0, 0], [1, 0], [0, 1]] } }).portalOk,
    "a custom polygon must not borrow the rectangular portal model");

  const square = { i: 0, pd: { x: 0, y: 0, w: 0.5, h: 0.5, shape: "roundrect" } };
  const diagonal = g.drawPathPadLaunch([{ x1: 0, y1: 0, x2: 1, y2: 1 }], square, true);
  assert.equal(diagonal.span, 0, "a 45-degree square-pad exit must not acquire the sqrt(2) centre-chord flare");
  const horizontal = g.drawPathPadLaunch([{ x1: 0, y1: 0, x2: 1, y2: 0 }], square, true);
  assert(Math.abs(horizontal.span - 0.5) < 1e-9, "an orthogonal square-pad exit must retain its full face width");

  const nominal = 0.18993671363271875;
  const c127 = { i: 0, pd: { w: 0.5, h: 0.3, shape: "roundrect" } };
  const c127Profile = g.drawTaperProfile("RF", c127, nominal,
    { land: 0.212, span: 0.02828427124745862, portal: null });
  assert(Math.abs(c127Profile.width - 0.3) < 1e-9,
    "C127's near-corner chord must taper from its 0.3 mm pad instead of pinching or disappearing");
  const narrow = { i: 0, pd: { w: 0.1, h: 0.3, shape: "roundrect" } };
  const narrowProfile = g.drawTaperProfile("RF", narrow, nominal,
    { land: 0.15, span: 0.028, portal: null });
  assert(Math.abs(narrowProfile.width - 0.1) < 1e-9,
    "a genuinely narrow land must still taper to its physical minimum dimension, not its corner chord");
}

{
  const track = { id: "seg-owner", net: "RF", l: 0, x1: 0, y1: 0, x2: 1, y2: 0 };
  const PCB = { tracks: [], vias: [], rf_paths: [
    { net: "RF", l: 0, track_ids: ["seg-owner"], samples: [[0, 0, 0.2], [1, 0, 0.2]] },
    { net: "RF", l: 0, portal: true, track_ids: ["seg-owner"], samples: [[0.5, -0.2, 0.1], [0.5, 0.2, 0.1]] },
    { net: "RF", l: 0, track_ids: ["seg-other"], samples: [[2, 0, 0.2], [3, 0, 0.2]] },
  ] };
  const g = load(["rfPathOwnsTrack", "rfOwnsTrack", "rfPathBelongsToTrack", "rfDropForTracks", "cloneCopper"], {
    PCB,
    cuGeomDrop() {},
    trackIdEnsure(t) { return t.id; },
    viaIdEnsure(v) { return v.id; },
  });
  assert(g.rfPathOwnsTrack(PCB.rf_paths[0], track), "main path must own its editor handle");
  assert(!g.rfPathOwnsTrack(PCB.rf_paths[1], track), "collar alone must not hide an editor handle");
  assert(g.rfPathBelongsToTrack(PCB.rf_paths[1], track), "collar must retain lifecycle membership through its owner id");
  assert(g.rfOwnsTrack(track), "a main path must hide its owned editor handle even when a collar shares the id");
  assert(g.cloneCopper().rf_paths[1].portal, "undo snapshots must preserve collar identity");
  g.rfDropForTracks([track]);
  assert.equal(PCB.rf_paths.length, 1, "editing a main route must drop its collar atomically without touching unrelated RF copper");
  assert.equal(PCB.rf_paths[0].track_ids[0], "seg-other");
}

{
  const t1 = { id: "leg-a", net: "RF", l: 0, x1: 0, y1: 0, x2: 5, y2: 0 };
  const t2 = { id: "leg-b", net: "RF", l: 0, x1: 5, y1: 0, x2: 5, y2: 5 };
  const arc = { id: "fillet", net: "RF", l: 0, x1: 4, y1: 0,
    xm: 4 + Math.SQRT1_2, ym: 1 - Math.SQRT1_2, x2: 5, y2: 1 };
  const main = { net: "RF", l: 0, track_ids: [t1.id, t2.id], samples: [
    [0, 0, 0.6], [1, 0, 0.2], [5, 0, 0.2], [5, 4, 0.2], [5, 5, 0.5],
  ] };
  const collar = { net: "RF", l: 0, portal: true, track_ids: [t1.id, t2.id],
    samples: [[-0.1, -0.2, 0.1], [-0.1, 0.2, 0.1]] };
  const unrelated = { net: "RF", l: 0, track_ids: ["elsewhere"], samples: [[8, 0, 0.2], [9, 0, 0.2]] };
  const g = load([
    "trackArcGeom", "trackChords", "drawTrackPoint", "rfPathOwnsTrack", "rfPathBelongsToTrack",
    "traceFilletRfLocate", "traceFilletRfWidth", "traceFilletRfPush", "traceFilletRfCopy",
    "traceFilletRfPath", "traceFilletRfPaths",
  ]);
  const paths = g.traceFilletRfPaths([main, collar, unrelated], [t1, t2], {
    corner: { x: 5, y: 0 }, arc,
  });
  assert.equal(paths.length, 3, "a valid fillet must retain the main taper, its pad collar, and unrelated RF copper");
  assert.equal(paths[2], unrelated, "unrelated RF geometry must not be rewritten");
  assert.deepEqual(Array.from(paths[0].track_ids), [t1.id, t2.id, arc.id], "the new native arc must join the taper lifecycle");
  assert.equal(paths[0].samples[0][2], 0.6, "the first pad taper width must survive the fillet");
  assert.equal(paths[0].samples.at(-1)[2], 0.5, "the second pad taper width must survive the fillet");
  assert(!paths[0].samples.some((s) => Math.hypot(s[0] - 5, s[1]) < 1e-9), "the old sharp corner must leave the swept path");
  assert(paths[0].samples.some((s) => s[0] > 4.1 && s[0] < 4.9 && s[1] > 0.1 && s[1] < 0.9),
    "the transformed width profile must follow interior stations of the fillet arc");
  assert.deepEqual(Array.from(paths[1].track_ids), [t1.id, t2.id, arc.id], "the retained pad collar must share arc invalidation");
  assert.deepEqual(paths[1].samples, collar.samples, "filleting a remote corner must not move the pad-contained collar");

  const reverse = { ...main, samples: main.samples.slice().reverse().map((s) => s.slice()) };
  const reversed = g.traceFilletRfPaths([reverse], [t1, t2], { corner: { x: 5, y: 0 }, arc })[0];
  assert.equal(reversed.samples[0][2], 0.5, "reverse-authored routes must keep their first landing taper");
  assert.equal(reversed.samples.at(-1)[2], 0.6, "reverse-authored routes must keep their far landing taper");
  assert(!reversed.samples.some((s) => Math.hypot(s[0] - 5, s[1]) < 1e-9),
    "reverse-authored routes must also replace the sharp corner with the fillet");
}

{
  let acceptAnyPad = false;
  let ownsLegacyTrack = false;
  let launchCalls = 0;
  const PCB = { rules: { min_width: 0.1, track_width: 0.2 }, tracks: [], rf_paths: [] };
  const globals = {
    PCB,
    netClassInfo() { return { impedance_ohms: 50, diff_impedance_ohms: 0, width: 0.2 }; },
    baseTrackW() { return 0.2; },
    drawEndpointPad(_net, _layer, x, y) {
      return (acceptAnyPad || (Math.abs(x) < 1e-9 && Math.abs(y) < 1e-9)) ? { pd: {} } : null;
    },
    drawPathPadLaunch() {
      launchCalls++;
      return { portal: { a: { x: -0.2, y: 0 }, b: { x: 0.2, y: 0 } } };
    },
    rfPathOwnsTrack() { return ownsLegacyTrack; },
    trackIdEnsure(t) { return t.id; },
  };
  const g = load(["drawTaperPortalPath", "drawSamePortalPath", "drawRfMissingPortalGroups"], globals);

  const legacy = { net: "RF", l: 0, samples: [[0, 0, 0.4], [1, 0, 0.2]] };
  PCB.rf_paths = [legacy];
  let groups = g.drawRfMissingPortalGroups();
  assert.equal(groups.length, 1, "an RF-path-only legacy launch must receive a collar");
  assert.equal(groups[0].length, 1);
  assert(groups[0][0].portal, "a migrated collar must be tagged for lifecycle handling");
  PCB.rf_paths.push(groups[0][0]);
  assert.equal(g.drawRfMissingPortalGroups().length, 0, "migration must be idempotent after its collar is present");

  launchCalls = 0;
  acceptAnyPad = true;
  PCB.rf_paths = [{ net: "RF", l: 0, portal: true, samples: [[0, 0, 0.1], [0, 1, 0.1]] }];
  assert.equal(g.drawRfMissingPortalGroups().length, 0, "a portal path must never become a migration source");
  assert.equal(launchCalls, 0, "portal-source rejection must happen before launch reconstruction");

  acceptAnyPad = false;
  ownsLegacyTrack = true;
  const ownedTrack = { id: "legacy-owner", net: "RF", l: 0 };
  const ownedLegacy = { net: "RF", l: 0, samples: [[4, 0, 0.2], [5, 0, 0.2]] };
  PCB.tracks = [ownedTrack];
  PCB.rf_paths = [ownedLegacy];
  assert.equal(g.drawRfMissingPortalGroups().length, 0);
  assert.equal(ownedLegacy.track_ids.length, 1, "a geometrically owned legacy main path should acquire stable track ids");
  assert.equal(ownedLegacy.track_ids[0], "legacy-owner");
}

console.log("RF and power taper geometry probes PASS");
