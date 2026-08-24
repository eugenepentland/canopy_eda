// Sub-circuit silkscreen JS parity check: validates that the pcb_board.js
// client-side port (no merging, 1 mm edge alignment, keepout shift) mirrors the
// Zig subcircuit_silkscreen behavior. Run manually with `node scripts/subcircuit_silk_js_parity.mjs`
// from the repo root; exits non-zero on any mismatch.
// Standalone validation of the pcb_board.js sub-circuit silk port against the
// Zig behavior (no merging, 1 mm edge alignment, keepout shift). Extracts the
// pure geometry functions from pcb_board.js and stubs the board-only helpers.
import fs from 'fs';
const src = fs.readFileSync('src/serve/assets/pcb_board.js', 'utf8');

const SUB_SILK_CLEAR = 0.2, SUB_SILK_STROKE = 0.15;
const SUB_SILK_INK_CLEAR = SUB_SILK_CLEAR + SUB_SILK_STROKE / 2;
const SUB_SILK_CORNER_INSET = 0.2;
const SUB_SILK_SNAP = 1, SUB_SILK_SHIFT_MAX = 2, SUB_SILK_SHIFT_STEP = 0.1;

// Axis-aligned rect keepout stubs for polyContains/polyDistEdge (the real ones
// handle arbitrary polygons; these match for rectangles, which tests use).
function polyContains(pts, x, y) {
  let inside = false;
  for (let i = 0, j = pts.length - 1; i < pts.length; j = i++) {
    const xi = pts[i][0], yi = pts[i][1], xj = pts[j][0], yj = pts[j][1];
    if (((yi > y) !== (yj > y)) && (x < (xj - xi) * (y - yi) / (yj - yi) + xi)) inside = !inside;
  }
  return inside;
}
function polyDistEdge(pts, x, y) {
  let best = Infinity;
  for (let i = 0, j = pts.length - 1; i < pts.length; j = i++) {
    const ax = pts[j][0], ay = pts[j][1], bx = pts[i][0], by = pts[i][1];
    const dx = bx - ax, dy = by - ay, len2 = dx * dx + dy * dy;
    const t = len2 > 0 ? Math.max(0, Math.min(1, ((x - ax) * dx + (y - ay) * dy) / len2)) : 0;
    best = Math.min(best, Math.hypot(x - (ax + t * dx), y - (ay + t * dy)));
  }
  return best;
}

// Pull the exact functions out of pcb_board.js by name, then eval them with
// the stubs in scope.
const wanted = [
  'subSilkRawSegments', 'subSilkClusterLeg', 'subSilkSnapEdges', 'subSilkSnapOne', 'subSilkSnapFacing',
  'subSilkSegPoint', 'subSilkSegHitsKeepout', 'subSilkBoxClearKeepouts',
  'subSilkShiftClearKeepouts', 'subSilkAssignArt',
];
let body = '';
for (const name of wanted) {
  const startRe = new RegExp('function\\s+' + name + '\\s*\\(');
  const m = src.match(startRe);
  if (!m) throw new Error('missing function ' + name);
  // Scan balanced braces from the opening `{` of the function body.
  const open = src.indexOf('{', m.index);
  let depth = 0, i = open;
  for (; i < src.length; i++) {
    if (src[i] === '{') depth++;
    else if (src[i] === '}') { depth--; if (depth === 0) { i++; break; } }
  }
  body += src.slice(m.index, i) + '\n';
}
const makeEnv = () => {
  const f = new Function(
    'SUB_SILK_INK_CLEAR', 'SUB_SILK_CORNER_INSET', 'SUB_SILK_SNAP', 'SUB_SILK_SHIFT_MAX', 'SUB_SILK_SHIFT_STEP', 'polyContains', 'polyDistEdge',
    body + '; return {subSilkRawSegments,subSilkClusterLeg,subSilkSnapEdges,subSilkSnapOne,subSilkSnapFacing,subSilkSegPoint,subSilkSegHitsKeepout,subSilkBoxClearKeepouts,subSilkShiftClearKeepouts,subSilkAssignArt};'
  );
  return f(SUB_SILK_INK_CLEAR, SUB_SILK_CORNER_INSET, SUB_SILK_SNAP, SUB_SILK_SHIFT_MAX, SUB_SILK_SHIFT_STEP, polyContains, polyDistEdge);
};

let failures = 0;
function check(label, got, want, tol = 1e-9) {
  const ok = typeof want === 'number' ? Math.abs(got - want) <= tol : got === want;
  if (!ok) { failures++; console.log('FAIL ' + label + ': got ' + got + ' want ' + want); }
  else console.log('ok   ' + label);
}
function approx(got, want, tol = 1e-9) { return typeof got === 'number' && Math.abs(got - want) <= tol; }
function segCount(q) { return q.raw.length; }

// ── Test A: overlapping same-face boxes keep independent envelopes (no merge)
{
  const env = makeEnv();
  const qs = [
    { g: 'alpha', x0: 1.5, y0: 3.5, x1: 6.5, y1: 6.5, l: 1, side: 'top' },
    { g: 'beta',  x0: 4.5, y0: 3.5, x1: 9.5, y1: 6.5, l: 1, side: 'top' },
  ];
  env.subSilkAssignArt(qs, []);
  check('A: alpha keeps own box', qs[0].x0 === 1.5 && qs[0].x1 === 6.5, true);
  check('A: beta keeps own box', qs[1].x0 === 4.5 && qs[1].x1 === 9.5, true);
  check('A: alpha has own 8 corners', segCount(qs[0]), 8);
  check('A: beta has own 8 corners', segCount(qs[1]), 8);
  const first = qs[0].raw[0];
  check('A: alpha first arm at minx+inset', first.x2, qs[0].x0 + SUB_SILK_CORNER_INSET);
}

// ── Test B: same-face boxes 0.8 mm apart snap facing edges to the midpoint
{
  const env = makeEnv();
  const qs = [
    { g: 'left',  x0: 0.5, y0: 3.5, x1: 3.5, y1: 6.5, l: 1, side: 'top' },
    { g: 'right', x0: 4.3, y0: 3.5, x1: 7.3, y1: 6.5, l: 1, side: 'top' },
  ];
  env.subSilkAssignArt(qs, []);
  check('B: left.maxx snaps to 3.9', qs[0].x1, 3.9);
  check('B: right.minx snaps to 3.9', qs[1].x0, 3.9);
  check('B: y edges untouched', qs[0].y0 === 3.5 && qs[0].y1 === 6.5, true);
  check('B: both keep own 8 corners', segCount(qs[0]) === 8 && segCount(qs[1]) === 8, true);
}

// ── Test C: opposite-face boxes do not snap
{
  const env = makeEnv();
  const qs = [
    { g: 'top',    x0: 0.5, y0: 3.5, x1: 3.5, y1: 6.5, l: 1, side: 'top' },
    { g: 'bottom', x0: 4.3, y0: 3.5, x1: 7.3, y1: 6.5, l: 1, side: 'bottom' },
  ];
  env.subSilkAssignArt(qs, []);
  check('C: top.maxx stays 3.5', qs[0].x1, 3.5);
  check('C: bottom.minx stays 4.3', qs[1].x0, 4.3);
}

// ── Test D: near-parallel edges align without perpendicular overlap
{
  const env = makeEnv();
  const qs = [
    { g: 'origin', x0: 0, y0: 0, x1: 4, y1: 4, l: 1, side: 'top' },
    { g: 'above', x0: 0.8, y0: 8, x1: 4.8, y1: 12, l: 1, side: 'top' },
    { g: 'right', x0: 8, y0: 0.8, x1: 12, y1: 4.8, l: 1, side: 'top' },
  ];
  env.subSilkAssignArt(qs, []);
  check('D: separated boxes align left edges', qs[0].x0 === 0.4 && qs[1].x0 === 0.4, true);
  check('D: separated boxes align right edges', qs[0].x1 === 4.4 && qs[1].x1 === 4.4, true);
  check('D: separated boxes align top edges', qs[0].y0 === 0.4 && qs[2].y0 === 0.4, true);
  check('D: separated boxes align bottom edges', qs[0].y1 === 4.4 && qs[2].y1 === 4.4, true);
}

// ── Test E: the 1 mm threshold is inclusive, and a larger difference stays put
{
  const env = makeEnv();
  const a = { v: 2 }, b = { v: 3 };
  check('E: exactly 1 mm snaps', env.subSilkSnapOne(a, 'v', b, 'v'), true);
  check('E: exact-boundary midpoint', a.v === 2.5 && b.v === 2.5, true);
  const c = { v: 2 }, d = { v: 3.001 };
  check('E: more than 1 mm does not snap', env.subSilkSnapOne(c, 'v', d, 'v'), false);
  check('E: over-threshold coordinates stay put', c.v === 2 && d.v === 3.001, true);
}

// ── Test F: overlapping narrow boxes keep their widths
{
  const env = makeEnv();
  const qs = [
    { g: 'a', x0: 0, y0: 0, x1: 1, y1: 1, l: 0.75, side: 'top' },
    { g: 'b', x0: 0.5, y0: 0, x1: 1.5, y1: 1, l: 0.75, side: 'top' },
  ];
  env.subSilkSnapEdges(qs);
  check('F: first narrow box keeps width', qs[0].x1 - qs[0].x0, 1);
  check('F: second narrow box keeps width', qs[1].x1 - qs[1].x0, 1);
}

// ── Test G: keepout straddling the right edge shifts the box left 0.8 mm
{
  const env = makeEnv();
  const qs = [{ g: 'rf', x0: 2.5, y0: 3.5, x1: 7.5, y1: 6.5, l: 0.75, side: 'top' }];
  const keepouts = [[[6.8, 3.0], [8.6, 3.0], [8.6, 7.0], [6.8, 7.0]]];
  env.subSilkAssignArt(qs, keepouts);
  check('G: maxx shifts to 6.7', qs[0].x1, 6.7, 1e-6);
  check('G: box still clear of keepout', env.subSilkBoxClearKeepouts(qs[0], keepouts), true);
  check('G: all 8 marks survive', segCount(qs[0]), 8);
}

// ── Test H: a box fully inside a keepout stays put (no shift finds a clear spot)
{
  const env = makeEnv();
  const qs = [{ g: 'quiet', x0: 2.5, y0: 3.5, x1: 7.5, y1: 6.5, l: 0.75, side: 'top' }];
  const keepouts = [[[2.4, 3.4], [7.6, 3.4], [7.6, 6.6], [2.4, 6.6]]];
  env.subSilkAssignArt(qs, keepouts);
  check('H: box stays at 7.5', qs[0].x1, 7.5, 1e-6);
  check('H: marks still clipped (not clear)', !env.subSilkBoxClearKeepouts(qs[0], keepouts), true);
}

console.log(failures === 0 ? '\nALL JS SILK TESTS PASSED' : '\n' + failures + ' FAILURE(S)');
process.exit(failures === 0 ? 0 : 1);
