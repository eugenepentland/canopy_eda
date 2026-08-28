#!/usr/bin/env node
// Behavioral probes for the browser RF-taper geometry. These use the two
// Barracuda V2 launches that exposed a folded sweep and an off-centre pad exit.

import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";
import { fileURLToPath } from "node:url";

const boardPath = fileURLToPath(new URL("../src/serve/assets/pcb_board.js", import.meta.url));
const source = fs.readFileSync(boardPath, "utf8");

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
  };
  const g = load(["drawPadFrame", "drawPadPortal", "drawPathPadLaunch", "drawTaperPortalPath", "drawSamePortalPath"], globals);
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

console.log("RF taper geometry probes PASS");
