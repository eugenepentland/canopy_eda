/* Manufacturing-style PCB face textures + drill geometry for pcb_3d_viewer.
 *
 * One canvas per physical face composites copper, soldermask and silkscreen.
 * The result is a single texture (rather than thousands of thin 3D meshes),
 * while drills are returned separately so the viewer can cut real holes from
 * the substrate extrusion and both face polygons.
 */
(function () {
  "use strict";

  var COPPER = "#c7923e";
  var SUBSTRATE = "#6f5529";
  var MASK_COLOR = "#0c6734", MASK = "rgba(12, 103, 52, 0.84)";
  var SILK = "#f5f3e8";
  var MAX_TEXTURE = 2048, PX_PER_MM = 32, ROUND_HOLE_SEGMENTS = 16;
  var MECHANICAL_HOLE_MIN_DIAMETER = 1.0;

  function deg(d) { return (+d || 0) * Math.PI / 180; }

  // Footprint local → board coordinates. Bottom footprints mirror local X
  // before their saved board rotation, matching the optimizer and 3D models.
  function worldPoint(part, x, y) {
    if (part.side === "bottom") x = -x;
    var a = deg(part.rot), c = Math.cos(a), s = Math.sin(a);
    return [part.x + x * c - y * s, part.y + x * s + y * c];
  }

  // Pad-local offsets first take the pad's own rotation, then the footprint
  // transform. This is also the physical direction of an oval drill slot.
  function padPoint(part, pad, dx, dy) {
    var a = deg(pad.rot), c = Math.cos(a), s = Math.sin(a);
    return worldPoint(part, pad.x + dx * c - dy * s, pad.y + dx * s + dy * c);
  }

  function bounds(pts) {
    var b = { minx: Infinity, miny: Infinity, maxx: -Infinity, maxy: -Infinity };
    pts.forEach(function (p) {
      b.minx = Math.min(b.minx, +p[0]); b.maxx = Math.max(b.maxx, +p[0]);
      b.miny = Math.min(b.miny, +p[1]); b.maxy = Math.max(b.maxy, +p[1]);
    });
    b.w = Math.max(0.01, b.maxx - b.minx); b.h = Math.max(0.01, b.maxy - b.miny);
    return b;
  }

  function tracePoly(ctx, pts) {
    if (!pts || pts.length < 3) return false;
    ctx.moveTo(+pts[0][0], +pts[0][1]);
    for (var i = 1; i < pts.length; i++) ctx.lineTo(+pts[i][0], +pts[i][1]);
    ctx.closePath(); return true;
  }

  function boardPath(ctx, pts) { ctx.beginPath(); return tracePoly(ctx, pts); }

  function pointInPoly(pts, x, y) {
    var inside = false;
    for (var i = 0, j = pts.length - 1; i < pts.length; j = i++) {
      var a = pts[i], b = pts[j];
      if (((a[1] > y) !== (b[1] > y)) &&
          x < (b[0] - a[0]) * (y - a[1]) / ((b[1] - a[1]) || 1e-20) + a[0]) inside = !inside;
    }
    return inside;
  }

  function faceOfArea(q) {
    if (!q) return null;
    if (q.side === "top" || q.side === "bottom") return q.side;
    var layer = String(q.layer || "").toLowerCase();
    if (layer === "f.cu") return "top";
    if (layer === "b.cu") return "bottom";
    return null;
  }

  function areaPolys(q) {
    var raw = q && (q.filled_polygons || q.filledPolygons || q.filled || q.polys), out = [];
    if (Array.isArray(raw)) {
      if (raw.length && Array.isArray(raw[0]) && typeof raw[0][0] === "number") out.push(raw);
      else raw.forEach(function (p) { if (p && p.length >= 3) out.push(p); });
    }
    if (!out.length) {
      var one = q && (q.poly || q.polygon || q.points || q.boundary);
      if (one && one.length >= 3) out.push(one);
    }
    return out;
  }

  function drawAreas(ctx, data, side) {
    [data.pours, data.zone_fills].forEach(function (list) {
      (list || []).forEach(function (q) {
        if (q.keepout || faceOfArea(q) !== side) return;
        areaPolys(q).forEach(function (poly) {
          ctx.beginPath(); if (!tracePoly(ctx, poly)) return;
          (q.holes || []).forEach(function (h) { tracePoly(ctx, h); });
          ctx.fill("evenodd");
        });
      });
    });
  }

  function trackArc(t) {
    if (t.xm == null || t.ym == null) return null;
    var ax = +t.x1, ay = +t.y1, bx = +t.xm, by = +t.ym, cx = +t.x2, cy = +t.y2;
    var d = 2 * (ax * (by - cy) + bx * (cy - ay) + cx * (ay - by));
    if (Math.abs(d) < 1e-10) return null;
    var aa = ax * ax + ay * ay, bb = bx * bx + by * by, cc = cx * cx + cy * cy;
    var ox = (aa * (by - cy) + bb * (cy - ay) + cc * (ay - by)) / d;
    var oy = (aa * (cx - bx) + bb * (ax - cx) + cc * (bx - ax)) / d;
    var a0 = Math.atan2(ay - oy, ax - ox), am = Math.atan2(by - oy, bx - ox);
    var a1 = Math.atan2(cy - oy, cx - ox), tau = Math.PI * 2;
    function ccwDelta(a, b) { var v = (b - a) % tau; return v < 0 ? v + tau : v; }
    var ccw = ccwDelta(a0, am) <= ccwDelta(a0, a1) + 1e-9;
    return { x: ox, y: oy, r: Math.hypot(ax - ox, ay - oy), a0: a0, a1: a1, clockwise: !ccw };
  }

  function drawTracks(ctx, data, side) {
    var layer = side === "bottom" ? 1 : 0;
    ctx.lineCap = "round"; ctx.lineJoin = "round";
    (data.tracks || []).forEach(function (t) {
      if ((+t.l || 0) !== layer) return;
      ctx.lineWidth = Math.max(+t.w || 0.127, 0.02); ctx.beginPath();
      var arc = trackArc(t);
      if (arc) ctx.arc(arc.x, arc.y, arc.r, arc.a0, arc.a1, arc.clockwise);
      else { ctx.moveTo(+t.x1, +t.y1); ctx.lineTo(+t.x2, +t.y2); }
      ctx.stroke();
    });
  }

  // Saved RF routes are centreline chords plus one swept, variable-width
  // copper surface. Assembly paints that surface (including pad tapers); use
  // the same lowered world-space rings here so a bottom mask opening reveals
  // copper instead of substrate around the narrower centreline fallback.
  function drawRfPaths(ctx, data, side) {
    var layer = side === "bottom" ? 1 : 0, paths = [];
    try {
      if (window.PCBRfSurfacePolys) paths = window.PCBRfSurfacePolys(data) || [];
    } catch (_) {}
    paths.forEach(function (path) {
      if ((+path.l || 0) !== layer) return;
      (path.polys || []).forEach(function (poly) {
        ctx.beginPath(); if (!tracePoly(ctx, poly)) return; ctx.fill();
      });
    });
  }

  function withPartTransform(ctx, part, fn) {
    ctx.save(); ctx.translate(+part.x, +part.y); ctx.rotate(deg(part.rot));
    if (part.side === "bottom") ctx.scale(-1, 1);
    fn(); ctx.restore();
  }

  function roundedRect(ctx, x, y, w, h, r) {
    var x0 = x - w / 2, y0 = y - h / 2, x1 = x + w / 2, y1 = y + h / 2;
    r = Math.max(0, Math.min(r, w / 2, h / 2));
    ctx.moveTo(x0 + r, y0); ctx.lineTo(x1 - r, y0); ctx.arcTo(x1, y0, x1, y0 + r, r);
    ctx.lineTo(x1, y1 - r); ctx.arcTo(x1, y1, x1 - r, y1, r);
    ctx.lineTo(x0 + r, y1); ctx.arcTo(x0, y1, x0, y1 - r, r);
    ctx.lineTo(x0, y0 + r); ctx.arcTo(x0, y0, x0 + r, y0, r); ctx.closePath();
  }

  function tracePad(ctx, pad) {
    ctx.beginPath();
    if (pad.poly && pad.poly.length >= 3) return tracePoly(ctx, pad.poly);
    ctx.save(); ctx.translate(+pad.x, +pad.y); ctx.rotate(deg(pad.rot));
    var w = Math.max(+pad.w || 0.05, 0.05), h = Math.max(+pad.h || 0.05, 0.05);
    if (pad.shape === "circle") ctx.arc(0, 0, Math.min(w, h) / 2, 0, Math.PI * 2);
    else if (pad.shape === "oval") {
      if (ctx.ellipse) ctx.ellipse(0, 0, w / 2, h / 2, 0, 0, Math.PI * 2);
      else roundedRect(ctx, 0, 0, w, h, Math.min(w, h) / 2);
    } else if (pad.shape === "roundrect") {
      roundedRect(ctx, 0, 0, w, h, Math.min(w, h) * (+pad.rratio || 0.25));
    } else ctx.rect(-w / 2, -h / 2, w, h);
    ctx.restore(); return true;
  }

  function padOnFace(part, pad, side) {
    return +pad.drill > 0 || (part.side || "top") === side;
  }

  function drawPads(ctx, data, side, openings) {
    var margin = Math.max(0, +(data.rules && data.rules.mask_margin) || 0);
    (data.parts || []).forEach(function (part) {
      withPartTransform(ctx, part, function () {
        (part.pads || []).forEach(function (pad) {
          if (!padOnFace(part, pad, side)) return;
          tracePad(ctx, pad);
          if (openings) {
            ctx.fill();
            if (margin > 0) { ctx.lineWidth = 2 * margin; ctx.lineJoin = "round"; ctx.stroke(); }
          } else if (!pad.npth) ctx.fill();
        });
      });
    });
  }

  function drawPadIslands(ctx, data, side) {
    var margin = Math.max(0, +(data.rules && data.rules.mask_margin) || 0);
    var grow = window.PCBMaskPadIslandGrow ? window.PCBMaskPadIslandGrow() : margin;
    (data.parts || []).forEach(function (part) {
      withPartTransform(ctx, part, function () {
        (part.pads || []).forEach(function (pad) {
          if (!padOnFace(part, pad, side)) return;
          tracePad(ctx, pad); ctx.fill();
          if (grow > 0) { ctx.lineWidth = 2 * grow; ctx.lineJoin = "round"; ctx.stroke(); }
        });
      });
    });
  }

  function drawVias(ctx, data) {
    (data.vias || []).forEach(function (v) {
      ctx.beginPath(); ctx.arc(+v.x, +v.y, Math.max(+v.d || 0.4, 0.05) / 2, 0, Math.PI * 2); ctx.fill();
    });
  }

  function drawCopper(ctx, data, side) {
    ctx.fillStyle = COPPER; ctx.strokeStyle = COPPER;
    drawAreas(ctx, data, side); drawTracks(ctx, data, side); drawRfPaths(ctx, data, side);
    drawPads(ctx, data, side, false); drawVias(ctx, data);
  }

  function punchRelief(ctx, data, side) {
    var relief = data.mask_relief || {}, layer = side === "bottom" ? 1 : 0;
    (relief.openings || []).forEach(function (o) {
      if ((+o.l || 0) !== layer || !o.p || o.p.length < 3) return;
      ctx.beginPath(); tracePoly(ctx, o.p); ctx.fill();
    });
    ctx.lineCap = "round"; ctx.lineJoin = "round";
    (relief.strokes || []).forEach(function (s) {
      if ((+s.l || 0) !== layer) return;
      ctx.lineWidth = Math.max(+s.w || 0, 0.01); ctx.beginPath();
      ctx.moveTo(+s.x1, +s.y1); ctx.lineTo(+s.x2, +s.y2); ctx.stroke();
    });
    (relief.joints || []).forEach(function (j) {
      if ((+j.l || 0) !== layer) return;
      ctx.beginPath(); ctx.arc(+j.x, +j.y, Math.max(+j.d || 0, 0.01) / 2, 0, Math.PI * 2); ctx.fill();
    });
  }

  function punchMaskMerges(ctx, data, side) {
    var layer = side === "bottom" ? 1 : 0;
    ctx.lineCap = "round"; ctx.lineJoin = "round";
    (data.mask_merges || []).forEach(function (m) {
      if ((+m.l || 0) !== layer) return;
      ctx.lineWidth = Math.max(+m.w || 0, 0.01); ctx.beginPath();
      ctx.moveTo(+m.x1, +m.y1); ctx.lineTo(+m.x2, +m.y2); ctx.stroke();
    });
  }

  function maskCanvas(data, pts, b, width, height, scale, side) {
    var cv = document.createElement("canvas"); cv.width = width; cv.height = height;
    var ctx = cv.getContext("2d");
    ctx.setTransform(scale, 0, 0, scale, -b.minx * scale, -b.miny * scale);
    ctx.fillStyle = MASK; boardPath(ctx, pts); ctx.fill();
    ctx.globalCompositeOperation = "destination-out"; ctx.fillStyle = "#000"; ctx.strokeStyle = "#000";
    punchRelief(ctx, data, side);
    // Restore only a local pad-shaped web over a wider RF relief, then reopen
    // the pad aperture. The relief itself remains continuous around the island.
    ctx.globalCompositeOperation = "source-over"; ctx.fillStyle = MASK; ctx.strokeStyle = MASK;
    drawPadIslands(ctx, data, side);
    ctx.globalCompositeOperation = "destination-out"; ctx.fillStyle = "#000"; ctx.strokeStyle = "#000";
    drawPads(ctx, data, side, true); punchMaskMerges(ctx, data, side);
    var edge = Math.max(0, +(data.rules && data.rules.perimeter_mask_width) || 0);
    if (edge > 0) { boardPath(ctx, pts); ctx.lineWidth = 2 * edge; ctx.lineJoin = "round"; ctx.stroke(); }
    return cv;
  }

  function drawFootprintSilk(ctx, data, side) {
    ctx.strokeStyle = SILK; ctx.lineWidth = 0.15; ctx.lineCap = "round"; ctx.lineJoin = "round";
    (data.parts || []).forEach(function (part) {
      if ((part.side || "top") !== side) return;
      withPartTransform(ctx, part, function () {
        var silk = part.silk || {};
        (silk.l || []).forEach(function (s) {
          ctx.beginPath(); ctx.moveTo(+s[0], +s[1]); ctx.lineTo(+s[2], +s[3]); ctx.stroke();
        });
        (silk.c || []).forEach(function (c) {
          ctx.beginPath(); ctx.arc(+c[0], +c[1], Math.max(+c[2] || 0, 0.02), 0, Math.PI * 2); ctx.stroke();
        });
      });
    });
  }

  function drawText(ctx, text, side) {
    if (!text || !text.text || (text.side || "top") !== side) return;
    ctx.save(); ctx.translate(+text.x, +text.y); ctx.rotate(deg(text.rot));
    if (side === "bottom") ctx.scale(-1, 1);
    var size = Math.max(+text.size || 1, 0.2);
    ctx.font = "600 " + size + "px sans-serif"; ctx.textAlign = "center"; ctx.textBaseline = "middle";
    ctx.lineWidth = 0.04; ctx.strokeStyle = SILK; ctx.fillStyle = SILK;
    ctx.strokeText(String(text.text), 0, 0); ctx.fillText(String(text.text), 0, 0); ctx.restore();
  }

  function generatedLabel(label, side) {
    if (!label) return null;
    return { x: label.x, y: label.y, rot: label.rot, size: label.size, text: label.text, side: side };
  }

  // pcb_board.js owns placement and clipping for generated fabrication silk.
  // Consume its resolved geometry so the 3D texture includes the same corner
  // brackets, automatic labels, test-point labels and pin-1 dots as the 2D
  // editor and Gerber-oriented preview.
  function drawGeneratedSilk(ctx, side) {
    var all = null;
    try { if (window.PCBGeneratedSilk) all = window.PCBGeneratedSilk(); } catch (_) {}
    if (!all) return;
    ctx.strokeStyle = SILK; ctx.fillStyle = SILK; ctx.lineWidth = 0.15;
    ctx.lineCap = "round"; ctx.lineJoin = "round";
    (all.subs || []).forEach(function (q) {
      if ((q.side || "top") !== side) return;
      ctx.beginPath();
      (q.segs || []).forEach(function (s) {
        ctx.moveTo(+s.x1, +s.y1); ctx.lineTo(+s.x2, +s.y2);
      });
      ctx.stroke(); drawText(ctx, generatedLabel(q.label, side), side);
    });
    (all.tps || []).forEach(function (tp) {
      if ((tp.side || "top") === side) drawText(ctx, generatedLabel(tp.label, side), side);
    });
    (all.pin1 || []).forEach(function (marker) {
      if ((marker.side || "top") !== side) return;
      ctx.beginPath(); ctx.arc(+marker.x, +marker.y, 0.15, 0, Math.PI * 2); ctx.fill();
    });
  }

  function drawSilk(ctx, data, side) {
    drawFootprintSilk(ctx, data, side);
    drawGeneratedSilk(ctx, side);
    (data.texts || []).forEach(function (t) { drawText(ctx, t, side); });
    var overridden = (data.texts || []).some(function (t) { return t && t.fabrication_id; });
    if (!overridden) drawText(ctx, data.fab_text, side);
  }

  function makeTexture(THREE, data, pts, side) {
    var b = bounds(pts), scale = Math.min(PX_PER_MM, MAX_TEXTURE / Math.max(b.w, b.h));
    scale = Math.max(0.05, scale);
    var width = Math.max(2, Math.ceil(b.w * scale)), height = Math.max(2, Math.ceil(b.h * scale));
    var cv = document.createElement("canvas"); cv.width = width; cv.height = height;
    var ctx = cv.getContext("2d");
    ctx.setTransform(scale, 0, 0, scale, -b.minx * scale, -b.miny * scale);
    boardPath(ctx, pts); ctx.clip(); ctx.fillStyle = SUBSTRATE; ctx.fillRect(b.minx, b.miny, b.w, b.h);
    drawCopper(ctx, data, side);
    ctx.save(); ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.drawImage(maskCanvas(data, pts, b, width, height, scale, side), 0, 0); ctx.restore();
    drawSilk(ctx, data, side);
    var texture = new THREE.CanvasTexture(cv);
    if (THREE.sRGBEncoding) texture.encoding = THREE.sRGBEncoding;
    texture.needsUpdate = true;
    return { texture: texture, bounds: b };
  }

  function collectHoles(data, pts) {
    var holes = [], seen = Object.create(null);
    function add(h) {
      if (!(h.r > 0) || !pointInPoly(pts, h.x, h.y)) return;
      var key = [h.x, h.y, h.x2 == null ? "" : h.x2, h.y2 == null ? "" : h.y2, h.r]
        .map(function (v) { return typeof v === "number" ? v.toFixed(5) : v; }).join("|");
      if (!seen[key]) { seen[key] = true; holes.push(h); }
    }
    (data.parts || []).forEach(function (part) {
      (part.pads || []).forEach(function (pad) {
        var drill = +pad.drill;
        // STEP is a mechanical-fit export. Tiny plated drills and stitch vias
        // explode the faceted board topology without helping enclosure work;
        // retain only holes strictly larger than 1 mm (normally mounting).
        if (!(drill > MECHANICAL_HOLE_MIN_DIAMETER)) return;
        var c = padPoint(part, pad, 0, 0), h = { x: c[0], y: c[1], r: drill / 2, plated: !pad.npth };
        if (pad.slot_half && (+pad.slot_half[0] || +pad.slot_half[1])) {
          var e = padPoint(part, pad, +pad.slot_half[0], +pad.slot_half[1]);
          var f = padPoint(part, pad, -pad.slot_half[0], -pad.slot_half[1]);
          h.x = e[0]; h.y = e[1]; h.x2 = f[0]; h.y2 = f[1];
        }
        add(h);
      });
    });
    var fallback = +(data.rules && data.rules.via_drill) || 0.2;
    (data.vias || []).forEach(function (v) {
      var drill = +v.drill || fallback;
      if (!(drill > MECHANICAL_HOLE_MIN_DIAMETER)) return;
      add({ x: +v.x, y: +v.y, r: drill / 2, plated: true });
    });
    return holes;
  }

  function addShapeHoles(THREE, shape, holes) {
    holes.forEach(function (h) {
      var path = new THREE.Path(), ax = h.x, ay = -h.y;
      if (h.x2 == null) {
        // Explicit line segments keep drills intact even though the board's
        // already-tessellated outline is extruded with curveSegments=1. A
        // THREE absarc would collapse to too few points at that setting and
        // let the solid substrate cap fill every circular bore.
        path.moveTo(ax + h.r, ay);
        for (var k = 1; k <= ROUND_HOLE_SEGMENTS; k++) {
          var ca = -Math.PI * 2 * k / ROUND_HOLE_SEGMENTS;
          path.lineTo(ax + h.r * Math.cos(ca), ay + h.r * Math.sin(ca));
        }
        path.closePath();
      } else {
        var bx = h.x2, by = -h.y2, angle = Math.atan2(by - ay, bx - ax), n = 10;
        path.moveTo(ax + h.r * Math.cos(angle + Math.PI / 2), ay + h.r * Math.sin(angle + Math.PI / 2));
        path.lineTo(bx + h.r * Math.cos(angle + Math.PI / 2), by + h.r * Math.sin(angle + Math.PI / 2));
        for (var i = 1; i <= n; i++) {
          var a = angle + Math.PI / 2 - Math.PI * i / n;
          path.lineTo(bx + h.r * Math.cos(a), by + h.r * Math.sin(a));
        }
        path.lineTo(ax + h.r * Math.cos(angle - Math.PI / 2), ay + h.r * Math.sin(angle - Math.PI / 2));
        for (var j = 1; j <= n; j++) {
          var a2 = angle - Math.PI / 2 - Math.PI * j / n;
          path.lineTo(ax + h.r * Math.cos(a2), ay + h.r * Math.sin(a2));
        }
        path.closePath();
      }
      shape.holes.push(path);
    });
  }

  function mapUvs(geometry, b) {
    var pos = geometry.getAttribute("position"), uv = geometry.getAttribute("uv");
    if (!pos || !uv) return;
    for (var i = 0; i < pos.count; i++) {
      uv.setXY(i, (pos.getX(i) - b.minx) / b.w, (pos.getY(i) + b.maxy) / b.h);
    }
    uv.needsUpdate = true;
  }

  window.PCB3DSurface = {
    addShapeHoles: addShapeHoles,
    collectHoles: collectHoles,
    makeTexture: makeTexture,
    maskColor: MASK_COLOR,
    mapUvs: mapUvs
  };
})();
