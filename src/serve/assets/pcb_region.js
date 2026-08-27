// pcb_region.js — triangulate Gerber regions, including self-crossing contours.
//
// Gerber regions use the non-zero winding rule. Most emitted contours are
// simple rings and go straight through Earcut. Some clearance unions are a
// single self-crossing walk, though, and Earcut deliberately does not define a
// result for those. For that uncommon case, split the walk at every crossing,
// enumerate the bounded faces of the resulting planar graph, and retain the
// faces whose sample point has non-zero winding in the original walk.
(function () {
"use strict";
if (typeof window === "undefined") return;

var EPS = 1e-9, SNAP = 1e-8, MAX_CROSSINGS = 65536;

function clean(raw) {
  var out = [];
  for (var i = 0; i < (raw || []).length; i++) {
    var p = raw[i], x = +(p && p[0]), y = +(p && p[1]);
    if (!isFinite(x) || !isFinite(y)) continue;
    var q = out[out.length - 1];
    if (!q || Math.abs(q[0] - x) > EPS || Math.abs(q[1] - y) > EPS) out.push([x, y]);
  }
  if (out.length > 2) {
    var a = out[0], b = out[out.length - 1];
    if (Math.abs(a[0] - b[0]) <= EPS && Math.abs(a[1] - b[1]) <= EPS) out.pop();
  }
  return out;
}

function cross(ax, ay, bx, by) { return ax * by - ay * bx; }

// null = disjoint, { overlap:true } = a contour the arrangement cannot safely
// simplify, otherwise the two edge parameters of their one intersection.
function intersection(a, b, c, d) {
  var rx = b[0] - a[0], ry = b[1] - a[1], sx = d[0] - c[0], sy = d[1] - c[1];
  var den = cross(rx, ry, sx, sy), qx = c[0] - a[0], qy = c[1] - a[1];
  var scale = Math.max(1, Math.hypot(rx, ry) * Math.hypot(sx, sy));
  if (Math.abs(den) <= EPS * scale) {
    if (Math.abs(cross(qx, qy, rx, ry)) > EPS * Math.max(1, Math.hypot(rx, ry))) return null;
    var useX = Math.abs(rx) >= Math.abs(ry), rv = useX ? rx : ry;
    if (Math.abs(rv) <= EPS) return { overlap: true };
    var t0 = ((useX ? c[0] - a[0] : c[1] - a[1]) / rv);
    var t1 = ((useX ? d[0] - a[0] : d[1] - a[1]) / rv);
    var lo = Math.max(0, Math.min(t0, t1)), hi = Math.min(1, Math.max(t0, t1));
    if (hi < lo - EPS) return null;
    if (hi - lo > EPS) return { overlap: true };
    var t = Math.max(0, Math.min(1, (lo + hi) / 2));
    var x = a[0] + t * rx, y = a[1] + t * ry;
    var u = Math.abs(sx) >= Math.abs(sy) ? (x - c[0]) / sx : (y - c[1]) / sy;
    return { t: t, u: Math.max(0, Math.min(1, u)) };
  }
  var t2 = cross(qx, qy, sx, sy) / den, u2 = cross(qx, qy, rx, ry) / den;
  if (t2 < -EPS || t2 > 1 + EPS || u2 < -EPS || u2 > 1 + EPS) return null;
  return { t: Math.max(0, Math.min(1, t2)), u: Math.max(0, Math.min(1, u2)) };
}

function adjacent(i, j, n) { return i === j || (i + 1) % n === j || (j + 1) % n === i; }

function earcutRing(ring) {
  if (typeof window.PCBEarcut !== "function" || ring.length < 3) return null;
  var flat = [];
  for (var i = 0; i < ring.length; i++) flat.push(ring[i][0], ring[i][1]);
  var ids = window.PCBEarcut(flat, null, 2);
  if (!ids || ids.length < 3) return null;
  return ids;
}

function direct(ring) {
  var ids = earcutRing(ring), out = [];
  if (!ids) return null;
  for (var i = 0; i < ids.length; i++) out.push(ring[ids[i]]);
  return out;
}

function winding(ring, p) {
  var n = 0;
  for (var i = 0; i < ring.length; i++) {
    var a = ring[i], b = ring[(i + 1) % ring.length];
    var side = cross(b[0] - a[0], b[1] - a[1], p[0] - a[0], p[1] - a[1]);
    if (a[1] <= p[1]) { if (b[1] > p[1] && side > EPS) n++; }
    else if (b[1] <= p[1] && side < -EPS) n--;
  }
  return n;
}

function area2(ring) {
  var a = 0;
  for (var i = 0; i < ring.length; i++) {
    var p = ring[i], q = ring[(i + 1) % ring.length];
    a += p[0] * q[1] - q[0] * p[1];
  }
  return a;
}

function triangulate(raw) {
  var ring = clean(raw), n = ring.length;
  if (n < 3 || typeof window.PCBEarcut !== "function") return null;

  var edges = [], splits = [];
  for (var i = 0; i < n; i++) {
    var a = ring[i], b = ring[(i + 1) % n];
    if (Math.hypot(b[0] - a[0], b[1] - a[1]) <= EPS) return null;
    edges.push({ i: i, a: a, b: b, x0: Math.min(a[0], b[0]), x1: Math.max(a[0], b[0]),
      y0: Math.min(a[1], b[1]), y1: Math.max(a[1], b[1]) });
    splits.push([0, 1]);
  }
  var order = edges.slice().sort(function (x, y) { return x.x0 - y.x0 || x.y0 - y.y0; });
  var crossings = 0;
  for (i = 0; i < order.length; i++) {
    var e = order[i];
    for (var j = i + 1; j < order.length && order[j].x0 <= e.x1 + EPS; j++) {
      var f = order[j];
      if (f.y0 > e.y1 + EPS || f.y1 < e.y0 - EPS) continue;
      var hit = intersection(e.a, e.b, f.a, f.b);
      if (!hit) continue;
      if (hit.overlap) return null;
      if (adjacent(e.i, f.i, n)) continue;
      splits[e.i].push(hit.t); splits[f.i].push(hit.u);
      if (++crossings > MAX_CROSSINGS) return null;
    }
  }
  if (!crossings) return direct(ring);

  var nodes = [], byKey = Object.create(null), half = [], undirected = Object.create(null);
  function nodeAt(x, y) {
    var key = Math.round(x / SNAP) + "," + Math.round(y / SNAP);
    var id = byKey[key];
    if (id != null) return id;
    id = nodes.length; byKey[key] = id; nodes.push({ p: [x, y], out: [] }); return id;
  }
  function addEdge(u, v) {
    if (u === v) return true;
    var key = u < v ? u + ":" + v : v + ":" + u;
    if (undirected[key]) return false;
    undirected[key] = true;
    var h = half.length;
    half.push({ from: u, to: v, twin: h + 1, seen: false },
      { from: v, to: u, twin: h, seen: false });
    nodes[u].out.push(h); nodes[v].out.push(h + 1); return true;
  }
  for (i = 0; i < n; i++) {
    var ts = splits[i].sort(function (x, y) { return x - y; }), uniq = [ts[0]];
    for (j = 1; j < ts.length; j++) if (ts[j] - uniq[uniq.length - 1] > EPS) uniq.push(ts[j]);
    a = ring[i]; b = ring[(i + 1) % n];
    for (j = 0; j + 1 < uniq.length; j++) {
      var t0 = uniq[j], t1 = uniq[j + 1];
      var u = nodeAt(a[0] + (b[0] - a[0]) * t0, a[1] + (b[1] - a[1]) * t0);
      var v = nodeAt(a[0] + (b[0] - a[0]) * t1, a[1] + (b[1] - a[1]) * t1);
      if (!addEdge(u, v)) return null;
    }
  }
  for (i = 0; i < nodes.length; i++) {
    var node = nodes[i], origin = node.p;
    node.out.sort(function (h0, h1) {
      var p0 = nodes[half[h0].to].p, p1 = nodes[half[h1].to].p;
      return Math.atan2(p0[1] - origin[1], p0[0] - origin[0]) -
        Math.atan2(p1[1] - origin[1], p1[0] - origin[0]);
    });
  }

  var result = [];
  for (i = 0; i < half.length; i++) {
    if (half[i].seen) continue;
    var face = [], h = i, guard = 0;
    do {
      if (half[h].seen && h !== i) return null;
      half[h].seen = true; face.push(nodes[half[h].from].p);
      var at = nodes[half[h].to], k = at.out.indexOf(half[h].twin);
      if (k < 0) return null;
      h = at.out[(k + at.out.length - 1) % at.out.length];
      if (++guard > half.length) return null;
    } while (h !== i);
    if (face.length < 3 || area2(face) <= EPS) continue;
    var ids = earcutRing(face);
    if (!ids) return null;
    var p0 = face[ids[0]], p1 = face[ids[1]], p2 = face[ids[2]];
    var sample = [(p0[0] + p1[0] + p2[0]) / 3, (p0[1] + p1[1] + p2[1]) / 3];
    if (!winding(ring, sample)) continue;
    for (j = 0; j < ids.length; j++) result.push(face[ids[j]]);
  }
  return result.length ? result : null;
}

window.PCBRegionTriangles = triangulate;
})();
