/* 3D model alignment viewer.
 *
 * Renders a footprint's copper pads (flat, from the .sexp) plus its STEP 3D
 * model, and lets the user dial in the rotation/offset that gets saved to
 * lib/models/model-config.json. The KiCad sync's writeModelBlock applies the
 * same offset/rotation to every instance, so what you align here is what lands
 * on the board.
 *
 * Coordinate frame matches KiCad's 3D viewer: X right, Y "north" (= -footprint
 * Y), Z up out of the board. Footprint pad coords are flipped in Y on the way
 * in. The model is loaded in its native STEP coordinates (identity at zero
 * transform), so the controls below are exactly the (offset, rotation) the
 * board will use.
 */
(function () {
  "use strict";

  var D = window.VIEWER_DATA || {};
  var THREE = window.THREE;

  var statusEl = document.getElementById("status");
  function setStatus(msg, isErr) {
    if (!msg) { statusEl.style.display = "none"; return; }
    statusEl.style.display = "block";
    statusEl.textContent = msg;
    statusEl.className = isErr ? "err" : "";
  }

  // ── Scene ────────────────────────────────────────────────────────
  var canvas = document.getElementById("view");
  var renderer = new THREE.WebGLRenderer({ canvas: canvas, antialias: true });
  renderer.setPixelRatio(window.devicePixelRatio || 1);

  var scene = new THREE.Scene();
  scene.background = new THREE.Color(0x0d1117);

  var camera = new THREE.PerspectiveCamera(45, 1, 0.01, 5000);
  camera.up.set(0, 0, 1); // Z up

  var controls = new THREE.OrbitControls(camera, renderer.domElement);
  controls.enableDamping = true;
  controls.dampingFactor = 0.12;

  scene.add(new THREE.AmbientLight(0xffffff, 0.55));
  var key = new THREE.DirectionalLight(0xffffff, 0.85); key.position.set(8, -6, 14); scene.add(key);
  var fill = new THREE.DirectionalLight(0xffffff, 0.4); fill.position.set(-10, 8, 6); scene.add(fill);
  var rim = new THREE.DirectionalLight(0xffffff, 0.3); rim.position.set(0, 0, -10); scene.add(rim);

  // A single letter drawn to a canvas texture, used as a camera-facing axis
  // label (Sprites always face the camera, so X/Y/Z stay readable at any orbit).
  function makeAxisLabel(text, cssColor) {
    var s = 128;
    var cv = document.createElement("canvas"); cv.width = cv.height = s;
    var ctx = cv.getContext("2d");
    ctx.fillStyle = cssColor;
    ctx.font = "bold 92px sans-serif";
    ctx.textAlign = "center"; ctx.textBaseline = "middle";
    ctx.fillText(text, s / 2, s / 2 + 6);
    var tex = new THREE.CanvasTexture(cv);
    // Draw over everything (depthTest off) so the label is never hidden inside
    // the part body sitting at the origin.
    return new THREE.Sprite(new THREE.SpriteMaterial({ map: tex, transparent: true, depthTest: false, depthWrite: false }));
  }
  // Origin gizmo: R/G/B arrows for +X/+Y/+Z (arrowheads point the positive way),
  // an X/Y/Z label at each tip, and a white dot marking (0,0,0). Makes it obvious
  // which way a rotation/offset will move the part.
  function buildAxisGizmo(len) {
    var g = new THREE.Group();
    var O = new THREE.Vector3(0, 0, 0);
    var head = len * 0.16, headW = len * 0.09, lscale = len * 0.32;
    [
      { dir: [1, 0, 0], col: 0xff5a5a, css: "#ff8a8a", lab: "X" },
      { dir: [0, 1, 0], col: 0x5ad65a, css: "#8aff8a", lab: "Y" },
      { dir: [0, 0, 1], col: 0x5a9dff, css: "#8ab8ff", lab: "Z" }
    ].forEach(function (d) {
      var v = new THREE.Vector3(d.dir[0], d.dir[1], d.dir[2]);
      g.add(new THREE.ArrowHelper(v, O, len, d.col, head, headW));
      var lb = makeAxisLabel(d.lab, d.css);
      lb.position.copy(v.clone().multiplyScalar(len + head));
      lb.scale.set(lscale, lscale, lscale);
      g.add(lb);
    });
    g.add(new THREE.Mesh(new THREE.SphereGeometry(len * 0.05, 16, 12), new THREE.MeshBasicMaterial({ color: 0xffffff })));
    return g;
  }
  var axes = buildAxisGizmo(3); scene.add(axes); // labeled +X/+Y/+Z arrows + origin dot

  // ── Board + pads ─────────────────────────────────────────────────
  var BOARD_T = 0.6, PAD_T = 0.06;
  var boardGroup = new THREE.Group();
  var padGroup = new THREE.Group();
  var modelGroup = new THREE.Group();
  scene.add(boardGroup); scene.add(padGroup); scene.add(modelGroup);

  var pads = D.pads || [];
  // Bounding box of the footprint (pads ∪ courtyard) in scene XY.
  var bb = { minx: Infinity, miny: Infinity, maxx: -Infinity, maxy: -Infinity };
  function grow(x, y) { if (x < bb.minx) bb.minx = x; if (x > bb.maxx) bb.maxx = x; if (y < bb.miny) bb.miny = y; if (y > bb.maxy) bb.maxy = y; }

  var padMat = new THREE.MeshStandardMaterial({ color: 0xd9a441, metalness: 0.85, roughness: 0.35 });
  // Copper plating barrel (PTH) vs bare dark wall (NPTH) lining a drilled bore.
  var barrelMat = new THREE.MeshStandardMaterial({ color: 0xd9a441, metalness: 0.9, roughness: 0.3, side: THREE.DoubleSide });
  var npthMat = new THREE.MeshStandardMaterial({ color: 0x0b0e11, metalness: 0.1, roughness: 1.0, side: THREE.DoubleSide });
  var boardMat = new THREE.MeshStandardMaterial({ color: 0x1c5c33, metalness: 0.1, roughness: 0.8 });

  function isNpth(p) { return p.type === "npth" || p.type === "np_thru" || p.type === "np_thru_hole"; }
  // Pad copper outline as a THREE.Shape (rect or circle) centred at (sx,sy).
  function padOutline(p, sx, sy) {
    var s = new THREE.Shape();
    if (p.shape === "circle") { s.absarc(sx, sy, Math.max(p.w, p.h) / 2, 0, Math.PI * 2, false); return s; }
    var hw = p.w / 2, hh = p.h / 2;
    s.moveTo(sx - hw, sy - hh); s.lineTo(sx + hw, sy - hh); s.lineTo(sx + hw, sy + hh); s.lineTo(sx - hw, sy + hh); s.lineTo(sx - hw, sy - hh);
    return s;
  }

  // Pass 1: footprint bounds + collect drilled bores (for cutting the board).
  var drills = [];
  pads.forEach(function (p) {
    var sx = p.x, sy = -p.y; // flip Y to scene frame
    grow(sx - p.w / 2, sy - p.h / 2); grow(sx + p.w / 2, sy + p.h / 2);
    if (p.drill > 0) drills.push({ sx: sx, sy: sy, r: p.drill / 2 });
  });
  if (D.courtyard) { var c = D.courtyard; grow(c.x1, -c.y1); grow(c.x2, -c.y2); }
  if (!isFinite(bb.minx)) { bb = { minx: -2, miny: -2, maxx: 2, maxy: 2 }; }

  var bw = Math.max(bb.maxx - bb.minx, 1), bh = Math.max(bb.maxy - bb.miny, 1);
  var margin = 0.6;
  // Board as an extruded outline with a real hole punched per drilled bore.
  var x0 = bb.minx - margin, y0 = bb.miny - margin, x1 = bb.maxx + margin, y1 = bb.maxy + margin;
  var boardShape = new THREE.Shape();
  boardShape.moveTo(x0, y0); boardShape.lineTo(x1, y0); boardShape.lineTo(x1, y1); boardShape.lineTo(x0, y1); boardShape.lineTo(x0, y0);
  drills.forEach(function (d) {
    var h = new THREE.Path(); h.absarc(d.sx, d.sy, d.r, 0, Math.PI * 2, true); boardShape.holes.push(h);
  });
  var boardGeo = new THREE.ExtrudeGeometry(boardShape, { depth: BOARD_T, bevelEnabled: false, curveSegments: 24 });
  var boardMesh = new THREE.Mesh(boardGeo, boardMat);
  boardMesh.position.z = -BOARD_T; // extrude spans 0..BOARD_T → drop so the top sits at z=0
  boardGroup.add(boardMesh);

  // Tag a pad mesh with its DECLARED copper centre + top surface z, then add it
  // to padGroup. The align-by-points tool reads userData.padCenter so it always
  // snaps a target to (p.x,-p.y) — the exact pad centre — never the raw ray hit
  // somewhere out on the copper. ztop is the copper top (PAD_T) for plated pads,
  // 0 for a bare NPTH bore that has no copper cap.
  function addPad(mesh, sx, sy, ztop) {
    mesh.userData.padCenter = [sx, sy, ztop];
    padGroup.add(mesh);
    return mesh;
  }
  // Pass 2: pad copper. SMD = flat disc/box; through-hole = annular ring (with
  // the bore punched out) + a plating barrel lining the hole through the board.
  pads.forEach(function (p) {
    var sx = p.x, sy = -p.y;
    if (p.drill > 0) {
      if (!isNpth(p)) { // plated: copper ring on top + copper barrel
        var ring = padOutline(p, sx, sy);
        var rh = new THREE.Path(); rh.absarc(sx, sy, p.drill / 2, 0, Math.PI * 2, true); ring.holes.push(rh);
        addPad(new THREE.Mesh(new THREE.ExtrudeGeometry(ring, { depth: PAD_T, bevelEnabled: false, curveSegments: 24 }), padMat), sx, sy, PAD_T);
      }
      var wall = new THREE.Mesh(new THREE.CylinderGeometry(p.drill / 2, p.drill / 2, BOARD_T, 24, 1, true), isNpth(p) ? npthMat : barrelMat);
      wall.rotation.x = Math.PI / 2; wall.position.set(sx, sy, -BOARD_T / 2);
      addPad(wall, sx, sy, isNpth(p) ? 0 : PAD_T);
    } else if (p.poly && p.poly.length >= 3) {
      // Custom pad: extrude the real copper polygon, not its bounding box.
      // Points are footprint-absolute; flip Y into the scene frame.
      var ps = new THREE.Shape();
      ps.moveTo(p.poly[0][0], -p.poly[0][1]);
      for (var i = 1; i < p.poly.length; i++) ps.lineTo(p.poly[i][0], -p.poly[i][1]);
      ps.lineTo(p.poly[0][0], -p.poly[0][1]);
      addPad(new THREE.Mesh(new THREE.ExtrudeGeometry(ps, { depth: PAD_T, bevelEnabled: false }), padMat), sx, sy, PAD_T);
    } else if (p.shape === "circle") {
      var cm = new THREE.Mesh(new THREE.CylinderGeometry(Math.max(p.w, p.h) / 2, Math.max(p.w, p.h) / 2, PAD_T, 24), padMat);
      cm.rotation.x = Math.PI / 2; cm.position.set(sx, sy, PAD_T / 2); addPad(cm, sx, sy, PAD_T);
    } else {
      var bm = new THREE.Mesh(new THREE.BoxGeometry(p.w, p.h, PAD_T), padMat);
      bm.position.set(sx, sy, PAD_T / 2); addPad(bm, sx, sy, PAD_T);
    }
  });

  var center = new THREE.Vector3((bb.minx + bb.maxx) / 2, (bb.miny + bb.maxy) / 2, 0);
  var span = Math.max(bw, bh, 4);

  // ── Camera presets ───────────────────────────────────────────────
  function frame(dir) {
    var d = span * 1.8;
    camera.position.copy(center).add(dir.clone().multiplyScalar(d));
    controls.target.copy(center);
    controls.update();
  }
  function viewIso() { frame(new THREE.Vector3(0.7, -0.9, 0.8).normalize()); }
  document.getElementById("view-top").onclick = function () { frame(new THREE.Vector3(0, 0, 1)); };
  document.getElementById("view-iso").onclick = viewIso;
  document.getElementById("view-front").onclick = function () { frame(new THREE.Vector3(0, -1, 0.02).normalize()); };
  document.getElementById("view-side").onclick = function () { frame(new THREE.Vector3(1, 0, 0.02).normalize()); };
  viewIso();

  // ── Transform state + controls ───────────────────────────────────
  // The viewer works in KiCad's *rendered* frame so it's a true WYSIWYG preview.
  // The stored model-config values are writeModelBlock's INPUT; KiCad renders its
  // negated output (offset → -offset; rotation X → -X, Y/Z unchanged), applied in
  // the same Rx·Ry·Rz order this viewer uses. So we map config → viewer on load
  // and viewer → config on save. The negation is an involution, so one function
  // serves both directions — what you align here is exactly what KiCad shows.
  function kicadView(r, o) {
    return { rot: [-r[0], r[1], r[2]], off: [-o[0], -o[1], -o[2]] };
  }
  var _v = kicadView(D.rotation || [0, 0, 0], D.offset || [0, 0, 0]);
  var rot = _v.rot.slice();
  var off = _v.off.slice();
  var saved = JSON.stringify([rot, off]);

  function deg2rad(d) { return d * Math.PI / 180; }
  function applyTransform() {
    // KiCad renders the model rotation as the INVERSE of Three.js' XYZ order —
    // it applies the (xyz) values in Z·Y·X order with the angles negated, which
    // equals tjsXYZ(rot)ᵀ. Match it so the preview is faithful for EVERY
    // rotation, not just the ones whose matrix happens to be symmetric (a 90°
    // Y-flip like the barrel jack exposed the difference; a 180° one didn't).
    modelGroup.rotation.set(deg2rad(-rot[0]), deg2rad(-rot[1]), deg2rad(-rot[2]), "ZYX");
    modelGroup.position.set(off[0], off[1], off[2]);
    markDirty();
  }

  var AXES = ["x", "y", "z"];
  function bindTriple(prefix, arr, onChange) {
    AXES.forEach(function (ax, i) {
      var r = document.getElementById(prefix + "-" + ax + "-r");
      var n = document.getElementById(prefix + "-" + ax + "-n");
      r.value = arr[i]; n.value = round(arr[i]);
      r.addEventListener("input", function () { arr[i] = parseFloat(r.value) || 0; n.value = round(arr[i]); onChange(); });
      n.addEventListener("input", function () { arr[i] = parseFloat(n.value) || 0; r.value = arr[i]; onChange(); });
    });
  }
  function round(v) { return Math.round(v * 1000) / 1000; }
  function syncInputs() {
    AXES.forEach(function (ax, i) {
      document.getElementById("rot-" + ax + "-r").value = rot[i];
      document.getElementById("rot-" + ax + "-n").value = round(rot[i]);
      document.getElementById("off-" + ax + "-r").value = off[i];
      document.getElementById("off-" + ax + "-n").value = round(off[i]);
    });
  }
  bindTriple("rot", rot, applyTransform);
  bindTriple("off", off, applyTransform);

  // Quick ±90/180 rotation buttons (accumulate, wrap to ±180).
  Array.prototype.forEach.call(document.querySelectorAll(".quick button[data-rot]"), function (b) {
    b.onclick = function () {
      var i = AXES.indexOf(b.getAttribute("data-rot"));
      var d = parseFloat(b.getAttribute("data-deg"));
      rot[i] = wrap180(rot[i] + d);
      syncInputs(); applyTransform();
    };
  });
  function wrap180(v) { v = ((v + 180) % 360 + 360) % 360 - 180; return v; }

  document.getElementById("reset").onclick = function () {
    rot[0] = rot[1] = rot[2] = 0; off[0] = off[1] = off[2] = 0;
    syncInputs(); applyTransform();
  };

  // Visibility toggles.
  document.getElementById("t-model").onchange = function (e) { modelGroup.visible = e.target.checked; };
  document.getElementById("t-pads").onchange = function (e) { padGroup.visible = e.target.checked; };
  document.getElementById("t-board").onchange = function (e) { boardGroup.visible = e.target.checked; };
  document.getElementById("t-axes").onchange = function (e) { axes.visible = e.target.checked; };

  // ── Align by points (Fusion-style Seat / Move) ───────────────────
  // One pin→pad pick pair poses the part without touching a slider. Two modes:
  //   Seat — reads the CLICKED FACE's plane: rotates the model (minimal arc) so
  //          that face lies flat on the board (its outward normal → −Z), then
  //          translates the picked point onto the pad centre. One pair does the
  //          whole pose; only a leftover yaw (Z spin) may need a quick ±90.
  //   Move — translation only: picked point → pad centre.
  // Everything works in the same rendered frame the sliders show, so the result
  // is exactly the (rot,off) the config stores.
  var modelLoaded = false;           // set true once the STEP model is built
  var alignMode = null;              // null · "seat" · "move"
  var alignStep = 0;                 // 0 off · 1 pick model point · 2 pick pad
  var srcPt = null;                  // picked model point, world coords at its pose
  var srcNrm = null;                 // picked face's outward normal (world) — Seat only
  var alignRay = new THREE.Raycaster();
  var seatBtn = document.getElementById("align-seat");
  var moveBtn = document.getElementById("align-move");

  function rad2deg(r) { return r * 180 / Math.PI; }
  function round2(v) { return Math.round(v * 100) / 100; } // 0.01° for rotation

  // Pointer (canvas CSS px) → normalized device coords for the raycaster.
  function pointerNDC(px, py) {
    return new THREE.Vector2((px / canvas.clientWidth) * 2 - 1, -(py / canvas.clientHeight) * 2 + 1);
  }
  // World point → canvas CSS px, so we can measure a snap candidate's on-screen
  // distance from the cursor (that's how "close enough to snap" is judged).
  function worldToPixels(world) {
    var v = world.clone().project(camera);
    return { x: (v.x * 0.5 + 0.5) * canvas.clientWidth, y: (-v.y * 0.5 + 0.5) * canvas.clientHeight };
  }
  function screenDist(world, px, py) {
    var s = worldToPixels(world);
    var dx = s.x - px, dy = s.y - py;
    return Math.sqrt(dx * dx + dy * dy);
  }

  // Centre of the hit mesh's LOCAL bbox (cached), transformed to world at the
  // mesh's current pose. occt emits one mesh per solid, so this is the solid's
  // (pin's) own centre regardless of how the part is currently oriented.
  function meshCenterWorld(mesh) {
    if (!mesh.geometry) return null;
    var bb = mesh.userData.localBBox;
    if (!bb) {
      mesh.geometry.computeBoundingBox();
      if (!mesh.geometry.boundingBox) return null;
      bb = mesh.geometry.boundingBox.clone();
      mesh.userData.localBBox = bb;
    }
    var local = new THREE.Vector3((bb.min.x + bb.max.x) / 2, (bb.min.y + bb.max.y) / 2, (bb.min.z + bb.max.z) / 2);
    return mesh.localToWorld(local); // uses matrixWorld → correct after the model moves
  }
  // The hit face's outward normal in world space (null if the hit has no face).
  function hitNormalWorld(hit) {
    if (!hit.face || !hit.face.normal) return null;
    return hit.face.normal.clone().transformDirection(hit.object.matrixWorld);
  }
  // Nearest of the hit face's three vertices to the hit point (O(1), no scan).
  function nearestFaceVertexWorld(mesh, hit) {
    var face = hit.face, geo = mesh.geometry;
    if (!face || !geo || !geo.attributes || !geo.attributes.position) return null;
    var pos = geo.attributes.position;
    var idxs = [face.a, face.b, face.c];
    var best = null, bestD = Infinity, i, world, d;
    for (i = 0; i < idxs.length; i++) {
      world = mesh.localToWorld(new THREE.Vector3(pos.getX(idxs[i]), pos.getY(idxs[i]), pos.getZ(idxs[i])));
      d = world.distanceTo(hit.point);
      if (d < bestD) { bestD = d; best = world; }
    }
    return best;
  }
  // Raycast the model; return the best snap + the clicked face's world normal.
  // "pin centre" = the solid's bbox centre PROJECTED ONTO the clicked face's
  // plane (the centre of this face of the pin — orientation-proof, unlike a
  // local bbox "bottom"), ≤20px; else nearest face vertex ≤10px; else the raw
  // surface hit. Among qualifying snaps the one closest to the cursor wins.
  function snapModel(px, py) {
    alignRay.setFromCamera(pointerNDC(px, py), camera);
    var hits = alignRay.intersectObjects(modelGroup.children, true);
    if (!hits.length) return null;
    var hit = hits[0], mesh = hit.object;
    var n = hitNormalWorld(hit);
    var chosen = { kind: "surface", point: hit.point.clone(), normal: n, mesh: mesh };
    var chosenDist = Infinity;
    var c = meshCenterWorld(mesh);
    if (c && n) {
      var pc = c.clone().sub(n.clone().multiplyScalar(n.dot(c.clone().sub(hit.point))));
      var dp = screenDist(pc, px, py);
      if (dp < 20 && dp < chosenDist) { chosen = { kind: "pin", point: pc, normal: n, mesh: mesh }; chosenDist = dp; }
    }
    var vtx = nearestFaceVertexWorld(mesh, hit);
    if (vtx) { var dv = screenDist(vtx, px, py); if (dv < 10 && dv < chosenDist) { chosen = { kind: "vertex", point: vtx, normal: n, mesh: mesh }; chosenDist = dv; } }
    return chosen;
  }
  // Raycast the pads; snap to the hit pad's DECLARED centre (userData.padCenter),
  // never the raw hit point.
  function snapPad(px, py) {
    alignRay.setFromCamera(pointerNDC(px, py), camera);
    var hits = alignRay.intersectObjects(padGroup.children, true);
    var i, pc;
    for (i = 0; i < hits.length; i++) {
      pc = hits[i].object.userData.padCenter;
      if (pc) return { kind: "pad", point: new THREE.Vector3(pc[0], pc[1], pc[2]), mesh: hits[i].object };
    }
    return null;
  }

  // ── Hover highlight + snap dot ───────────────────────────────────
  // What's under the cursor is shown by HIGHLIGHTING the solid itself (a
  // material swap — pads share one material, so an emissive tweak would light
  // them all) plus a small fixed-screen-size dot at the exact snap point. No
  // big ball occluding the target. Fixed click markers stay small spheres.
  var modelHoverMat = new THREE.MeshStandardMaterial({ color: 0x2f81f7, emissive: 0x123a66, metalness: 0.3, roughness: 0.5 });
  var padHoverMat = new THREE.MeshStandardMaterial({ color: 0xf0b25a, emissive: 0x5a3200, metalness: 0.85, roughness: 0.35, side: THREE.DoubleSide });
  var hoverMesh = null, hoverOrigMat = null;
  function highlight(mesh, mat) {
    if (hoverMesh === mesh) return;
    unhighlight();
    if (!mesh) return;
    hoverMesh = mesh; hoverOrigMat = mesh.material;
    mesh.material = mat;
  }
  function unhighlight() {
    if (hoverMesh) { hoverMesh.material = hoverOrigMat; hoverMesh = null; hoverOrigMat = null; }
  }
  // Pixel-constant snap dot (Points with sizeAttenuation off → always ~7 px on
  // screen, whatever the zoom) marking exactly where the pick will grab.
  var snapDot = null;
  function makeSnapDot() {
    var g = new THREE.BufferGeometry();
    g.setAttribute("position", new THREE.Float32BufferAttribute([0, 0, 0], 3));
    var d = new THREE.Points(g, new THREE.PointsMaterial({ size: 7, sizeAttenuation: false, color: 0xffffff, depthTest: false, transparent: true }));
    d.renderOrder = 1000; d.visible = false;
    return d;
  }
  var alignMarkers = [];
  function placeFixedMarker(world, color) {
    var m = new THREE.Mesh(
      new THREE.SphereGeometry(Math.max(span * 0.012, 0.03), 12, 8),
      new THREE.MeshBasicMaterial({ color: color, depthTest: false, transparent: true, opacity: 0.95 })
    );
    m.renderOrder = 999;
    m.position.copy(world);
    scene.add(m); alignMarkers.push(m);
  }
  function clearAlignMarkers() {
    var i;
    for (i = 0; i < alignMarkers.length; i++) scene.remove(alignMarkers[i]);
    alignMarkers = [];
    if (snapDot) { scene.remove(snapDot); snapDot = null; }
    unhighlight();
  }
  function snapColor(kind) {
    if (kind === "pin") return 0x5ad65a;   // green — pin seat
    if (kind === "vertex") return 0x5a9dff; // blue — mesh vertex
    if (kind === "pad") return 0xf0883e;    // amber — pad centre
    return 0x9aa4ad;                        // grey — raw surface
  }
  function snapSuffix(kind) {
    if (kind === "pin") return "  (pin center)";
    if (kind === "vertex") return "  (vertex)";
    if (kind === "pad") return "  (pad center)";
    return "  (surface)";
  }

  // ── Mode machine ─────────────────────────────────────────────────
  function stepBaseMsg() {
    if (alignMode === "seat") {
      return alignStep === 1 ? "⊥ Seat: click the model face that should sit on the board"
        : "⊥ Seat: click the target pad";
    }
    return alignStep === 1 ? "⌖ Move: click a point on the model"
      : "⌖ Move: click the target pad";
  }
  function alignStatus(suffix) { setStatus(stepBaseMsg() + (suffix || ""), false); }

  function enterAlign(mode) {
    if (!modelLoaded) { setStatus("Load a 3D model before aligning.", true); return; }
    exitAlign(); // switching modes mid-flight resets cleanly
    alignMode = mode; alignStep = 1;
    srcPt = srcNrm = null;
    (mode === "seat" ? seatBtn : moveBtn).classList.add("active");
    snapDot = makeSnapDot(); scene.add(snapDot);
    alignStatus("");
  }
  function exitAlign() {
    alignMode = null; alignStep = 0;
    srcPt = srcNrm = null;
    seatBtn.classList.remove("active");
    moveBtn.classList.remove("active");
    clearAlignMarkers();
    setStatus(null);
  }
  seatBtn.onclick = function () { if (alignMode === "seat") exitAlign(); else enterAlign("seat"); };
  moveBtn.onclick = function () { if (alignMode === "move") exitAlign(); else enterAlign("move"); };
  document.addEventListener("keydown", function (e) { if (e.key === "Escape" && alignMode) exitAlign(); });

  // Snap a world direction to the nearest coordinate axis when within 5° of it.
  // STEP bodies are axis-aligned, so a snapped face normal yields exact 90°
  // multiples and clean offsets instead of 89.97-style residue from the mesh.
  function axisSnap(n) {
    var axes = [[1, 0, 0], [-1, 0, 0], [0, 1, 0], [0, -1, 0], [0, 0, 1], [0, 0, -1]];
    var i, d, best = null, bestDot = 0;
    for (i = 0; i < axes.length; i++) {
      d = n.x * axes[i][0] + n.y * axes[i][1] + n.z * axes[i][2];
      if (d > bestDot) { bestDot = d; best = axes[i]; }
    }
    if (bestDot > 0.9962) return new THREE.Vector3(best[0], best[1], best[2]); // within 5°
    return n.clone().normalize();
  }
  // Seat the clicked face onto the board: rotate the model (minimal arc) so the
  // face's outward normal points −Z, then translate the picked point A onto the
  // pad centre t. With M = T(off)·R and the world-frame op X' = Rq·(X − A) + t:
  //   off' = t + Rq·(off − A)
  //   R'   = Rq·R
  // Recover the stored Euler triple from R' (applyTransform negates on the way
  // in, so store the negated degrees). A face already lying flat (n ≈ −Z) gives
  // Rq = I ⇒ pure translation, rot unchanged (setFromRotationMatrix round-trips
  // makeRotationFromEuler for the same order). The minimal arc adds no yaw for
  // axis-aligned normals, so any leftover spin is a quick Z ±90 afterwards.
  function applySeat(A, nWorld, t) {
    var q = new THREE.Quaternion().setFromUnitVectors(axisSnap(nWorld), new THREE.Vector3(0, 0, -1));
    var o = new THREE.Vector3(off[0] - A.x, off[1] - A.y, off[2] - A.z).applyQuaternion(q);
    off[0] = round(t.x + o.x); off[1] = round(t.y + o.y); off[2] = round(t.z + o.z);
    var mR = new THREE.Matrix4().makeRotationFromEuler(modelGroup.rotation); // = current R
    var m = new THREE.Matrix4().makeRotationFromQuaternion(q).multiply(mR); // Rq·R
    var e = new THREE.Euler().setFromRotationMatrix(m, "ZYX");
    rot[0] = round2(wrap180(-rad2deg(e.x)));
    rot[1] = round2(wrap180(-rad2deg(e.y)));
    rot[2] = round2(wrap180(-rad2deg(e.z)));
  }

  // ── Pointer handling ─────────────────────────────────────────────
  // A pointerup counts as a "click" (a pick) only if it barely moved and was
  // quick — otherwise it was an OrbitControls drag and we leave it alone.
  var downX = 0, downY = 0, downT = 0, downBtn = -1;
  canvas.addEventListener("pointerdown", function (e) {
    downX = e.clientX; downY = e.clientY; downT = Date.now(); downBtn = e.button;
  });
  canvas.addEventListener("pointerup", function (e) {
    if (!alignMode || alignStep === 0 || e.button !== 0 || downBtn !== 0) return;
    var dx = e.clientX - downX, dy = e.clientY - downY;
    if (Math.sqrt(dx * dx + dy * dy) >= 5) return;   // moved too far → a drag
    if (Date.now() - downT >= 400) return;           // too slow → not a click
    handlePick(e.offsetX, e.offsetY);
  });
  canvas.addEventListener("pointermove", function (e) {
    if (!alignMode || alignStep === 0) return;
    if (e.buttons !== 0) { unhighlight(); if (snapDot) snapDot.visible = false; return; } // orbiting
    handleHover(e.offsetX, e.offsetY);
  });
  canvas.addEventListener("pointerleave", function () {
    if (!alignMode) return;
    unhighlight(); if (snapDot) snapDot.visible = false;
  });

  function handleHover(px, py) {
    scene.updateMatrixWorld();
    var snap = alignStep === 1 ? snapModel(px, py) : snapPad(px, py);
    if (!snap) {
      unhighlight();
      if (snapDot) snapDot.visible = false;
      alignStatus("");
      return;
    }
    highlight(snap.mesh, alignStep === 1 ? modelHoverMat : padHoverMat);
    if (snapDot) {
      snapDot.position.copy(snap.point);
      snapDot.material.color.set(snapColor(snap.kind));
      snapDot.visible = true;
    }
    alignStatus(snapSuffix(snap.kind));
  }

  function handlePick(px, py) {
    scene.updateMatrixWorld(); // bake the current pose before reading world coords
    if (alignStep === 1) {
      var s1 = snapModel(px, py);
      if (!s1) return;
      if (alignMode === "seat" && !s1.normal) {
        setStatus("Couldn't read that face's orientation — click a flat face.", true);
        return;
      }
      srcPt = s1.point.clone();
      srcNrm = s1.normal ? s1.normal.clone() : null;
      placeFixedMarker(srcPt, 0x5ad65a);
      unhighlight();
      alignStep = 2; alignStatus("");
    } else if (alignStep === 2) {
      var s2 = snapPad(px, py);
      if (!s2) return;
      var t = s2.point;
      if (alignMode === "seat") {
        applySeat(srcPt, srcNrm, t);
      } else {
        off[0] = round(off[0] + (t.x - srcPt.x));
        off[1] = round(off[1] + (t.y - srcPt.y));
        off[2] = round(off[2] + (t.z - srcPt.z));
      }
      syncInputs(); applyTransform();
      exitAlign();
    }
  }

  // ── Save ─────────────────────────────────────────────────────────
  var saveBtn = document.getElementById("save");
  var saveState = document.getElementById("save-state");
  function markDirty() {
    var dirty = JSON.stringify([rot, off]) !== saved;
    saveBtn.disabled = !dirty;
    if (dirty) { saveState.textContent = "unsaved changes"; saveState.className = ""; }
  }
  saveBtn.onclick = function () {
    saveBtn.disabled = true; saveState.textContent = "saving…"; saveState.className = "";
    // Map the on-screen (KiCad-rendered) values back to writeModelBlock's input.
    var cfg = kicadView(rot, off);
    fetch("/api/model-transform/" + encodeURIComponent(D.footprint), {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ offset: cfg.off.map(Number), rotation: cfg.rot.map(Number) })
    }).then(function (r) { return r.json(); }).then(function (j) {
      if (j && j.ok) { saved = JSON.stringify([rot, off]); saveState.textContent = "saved ✓"; saveState.className = "ok"; markDirty(); }
      else { saveState.textContent = "save failed"; saveState.className = "err"; saveBtn.disabled = false; }
    }).catch(function () { saveState.textContent = "save failed"; saveState.className = "err"; saveBtn.disabled = false; });
  };

  // ── Resize + render loop ─────────────────────────────────────────
  function resize() {
    var w = canvas.clientWidth, h = canvas.clientHeight;
    if (w === 0 || h === 0) return;
    renderer.setSize(w, h, false);
    camera.aspect = w / h; camera.updateProjectionMatrix();
  }
  window.addEventListener("resize", resize);
  resize();
  (function loop() { requestAnimationFrame(loop); controls.update(); renderer.render(scene, camera); })();

  // ── Load the STEP model via occt-import-js (OpenCASCADE WASM) ─────
  if (!D.modelUrl) { setStatus("No STEP model for this footprint.", true); applyTransform(); return; }

  occtimportjs({ locateFile: function (f) { return "/static/" + f; } }).then(function (occt) {
    return fetch(D.modelUrl).then(function (r) {
      if (!r.ok) throw new Error("model fetch " + r.status);
      return r.arrayBuffer();
    }).then(function (buf) {
      var result = occt.ReadStepFile(new Uint8Array(buf), null);
      if (!result || !result.success || !result.meshes || !result.meshes.length) throw new Error("STEP parse produced no geometry");
      buildModel(result.meshes);
      setStatus(null);
      applyTransform();
    });
  }).catch(function (err) {
    console.error(err);
    setStatus("Could not load 3D model: " + err.message, true);
    applyTransform();
  });

  function buildModel(meshes) {
    meshes.forEach(function (m) {
      var g = new THREE.BufferGeometry();
      var pos = m.attributes && m.attributes.position && m.attributes.position.array;
      if (!pos) return;
      g.setAttribute("position", new THREE.Float32BufferAttribute(pos, 3));
      if (m.attributes.normal && m.attributes.normal.array) {
        g.setAttribute("normal", new THREE.Float32BufferAttribute(m.attributes.normal.array, 3));
      }
      if (m.index && m.index.array) g.setIndex(m.index.array);
      if (!m.attributes.normal) g.computeVertexNormals();
      var col = (m.color && m.color.length >= 3) ? new THREE.Color(m.color[0], m.color[1], m.color[2]) : new THREE.Color(0x9aa4ad);
      var mat = new THREE.MeshStandardMaterial({ color: col, metalness: 0.45, roughness: 0.55 });
      modelGroup.add(new THREE.Mesh(g, mat));
    });
    modelLoaded = true; // arm the align-by-points tool now the model exists
    // Reframe to include the model's extent so it isn't off-screen.
    var box = new THREE.Box3().setFromObject(modelGroup);
    if (!box.isEmpty()) {
      box.getCenter(center);
      center.z = 0;
      var size = box.getSize(new THREE.Vector3());
      span = Math.max(span, size.x, size.y, size.z * 2);
      viewIso();
    }
  }
})();
