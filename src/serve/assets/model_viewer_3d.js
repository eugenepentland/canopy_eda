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

  var axes = new THREE.AxesHelper(3); scene.add(axes); // X=red Y=green Z=blue

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

  // Pass 2: pad copper. SMD = flat disc/box; through-hole = annular ring (with
  // the bore punched out) + a plating barrel lining the hole through the board.
  pads.forEach(function (p) {
    var sx = p.x, sy = -p.y;
    if (p.drill > 0) {
      if (!isNpth(p)) { // plated: copper ring on top + copper barrel
        var ring = padOutline(p, sx, sy);
        var rh = new THREE.Path(); rh.absarc(sx, sy, p.drill / 2, 0, Math.PI * 2, true); ring.holes.push(rh);
        padGroup.add(new THREE.Mesh(new THREE.ExtrudeGeometry(ring, { depth: PAD_T, bevelEnabled: false, curveSegments: 24 }), padMat));
      }
      var wall = new THREE.Mesh(new THREE.CylinderGeometry(p.drill / 2, p.drill / 2, BOARD_T, 24, 1, true), isNpth(p) ? npthMat : barrelMat);
      wall.rotation.x = Math.PI / 2; wall.position.set(sx, sy, -BOARD_T / 2);
      padGroup.add(wall);
    } else if (p.shape === "circle") {
      var cm = new THREE.Mesh(new THREE.CylinderGeometry(Math.max(p.w, p.h) / 2, Math.max(p.w, p.h) / 2, PAD_T, 24), padMat);
      cm.rotation.x = Math.PI / 2; cm.position.set(sx, sy, PAD_T / 2); padGroup.add(cm);
    } else {
      var bm = new THREE.Mesh(new THREE.BoxGeometry(p.w, p.h, PAD_T), padMat);
      bm.position.set(sx, sy, PAD_T / 2); padGroup.add(bm);
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
  var rot = (D.rotation || [0, 0, 0]).slice();
  var off = (D.offset || [0, 0, 0]).slice();
  var saved = JSON.stringify([rot, off]);

  function deg2rad(d) { return d * Math.PI / 180; }
  function applyTransform() {
    modelGroup.rotation.set(deg2rad(rot[0]), deg2rad(rot[1]), deg2rad(rot[2]), "XYZ");
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
    fetch("/api/model-transform/" + encodeURIComponent(D.footprint), {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ offset: off.map(Number), rotation: rot.map(Number) })
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
