/* 3D PCB-layout viewer.
 *
 * Renders the whole placed board in WebGL from the same `window.PCB` blob the
 * 2D BOARD_JS reads: a green substrate spanning the placement, every part's
 * copper pads laid on top, and — for any footprint with a resolved STEP model
 * (PCB.models) — the 3D part body, oriented exactly as KiCad would place it.
 *
 * It's the "3D View" tab on /pcb-layout/:name; scripts (Three.js, OrbitControls,
 * occt-import-js) are injected lazily the first time the tab is opened, then
 * PCB3D.init() builds the scene once and PCB3D.onShow() re-fits on each return.
 *
 * Coordinate frame matches the footprint viewer (model_viewer_3d.js): X right,
 * Y "north" (= -PCB Y, since PCB/SVG space is Y-down), Z up out of the board.
 * A part at (x, y, rot°) becomes a group at scene (x, -y) rotated -rot° about Z
 * (the Y flip reverses the rotation sense); pads/models hang off it in the
 * footprint's own frame, so the placement rotates the whole part as one.
 */
(function () {
  "use strict";

  var THREE, occt; // resolved at init() — scripts load lazily
  // The page emits `const PCB = {...}` — a lexical global, NOT a window
  // property — so we read the bare binding (via typeof to stay strict-safe),
  // resolved at init() time when it's guaranteed defined.
  var DATA = {};
  var renderer, scene, camera, controls;
  var boardGroup, partsGroup, axes;
  // One scene Group per PCB.parts entry, in the same index order — so a Load /
  // drag / reset that mutated PCB.parts can be re-applied by walking both arrays.
  var partGroups = [];
  var built = false, looping = false;
  var center = { x: 0, y: 0 }, span = 20;
  // Signature of the poses 3D last rendered; lets onShow() detect a layout that
  // changed in 2D (Load/reset/drag) and re-fit the camera only when it did.
  var lastSig = "";
  var statusEl, canvas;

  var BOARD_T = 0.6, PAD_T = 0.06;
  var boardMat, padMat;

  function deg2rad(d) { return d * Math.PI / 180; }
  function setStatus(msg, isErr) {
    if (!statusEl) return;
    if (!msg) { statusEl.style.display = "none"; return; }
    statusEl.style.display = "block";
    statusEl.textContent = msg;
    statusEl.className = isErr ? "err" : "";
  }

  // ── Geometry helpers ─────────────────────────────────────────────
  // Pad copper outline (footprint-local, Y already flipped) as a THREE.Shape.
  function padShape(p, sx, sy) {
    var s = new THREE.Shape();
    if (p.shape === "circle") { s.absarc(sx, sy, Math.max(p.w, p.h) / 2, 0, Math.PI * 2, false); return s; }
    var hw = p.w / 2, hh = p.h / 2;
    s.moveTo(sx - hw, sy - hh); s.lineTo(sx + hw, sy - hh);
    s.lineTo(sx + hw, sy + hh); s.lineTo(sx - hw, sy + hh); s.lineTo(sx - hw, sy - hh);
    return s;
  }

  // Add one part's pads to its group (footprint frame, Y flipped to scene).
  function addPads(group, part) {
    (part.pads || []).forEach(function (pad) {
      var sx = pad.x, sy = -pad.y;
      var mesh;
      if (pad.poly && pad.poly.length >= 3) {
        var ps = new THREE.Shape();
        ps.moveTo(pad.poly[0][0], -pad.poly[0][1]);
        for (var i = 1; i < pad.poly.length; i++) ps.lineTo(pad.poly[i][0], -pad.poly[i][1]);
        ps.lineTo(pad.poly[0][0], -pad.poly[0][1]);
        mesh = new THREE.Mesh(new THREE.ExtrudeGeometry(ps, { depth: PAD_T, bevelEnabled: false }), padMat);
      } else if (pad.shape === "circle") {
        mesh = new THREE.Mesh(new THREE.CylinderGeometry(Math.max(pad.w, pad.h) / 2, Math.max(pad.w, pad.h) / 2, PAD_T, 24), padMat);
        mesh.rotation.x = Math.PI / 2; mesh.position.set(sx, sy, PAD_T / 2);
        group.add(mesh); return;
      } else {
        mesh = new THREE.Mesh(new THREE.BoxGeometry(Math.max(pad.w, 0.05), Math.max(pad.h, 0.05), PAD_T), padMat);
        mesh.position.set(sx, sy, PAD_T / 2);
        group.add(mesh); return;
      }
      group.add(mesh); // poly/circle extrusions already sit at z 0..PAD_T
    });
  }

  // Grow a bounds box by a part's rotated courtyard corners (scene frame).
  function growByCourtyard(bb, p) {
    var a = deg2rad(p.rot || 0), c = Math.cos(a), s = Math.sin(a);
    var hw = p.hw || 1, hh = p.hh || 1;
    [[-hw, -hh], [hw, -hh], [hw, hh], [-hw, hh]].forEach(function (q) {
      var wx = p.x + q[0] * c - q[1] * s, wy = p.y + q[0] * s + q[1] * c;
      var X = wx, Y = -wy;
      if (X < bb.minx) bb.minx = X; if (X > bb.maxx) bb.maxx = X;
      if (Y < bb.miny) bb.miny = Y; if (Y > bb.maxy) bb.maxy = Y;
    });
  }

  // ── KiCad model orientation (same mapping as model_viewer_3d.js) ──
  // model-config stores writeModelBlock's INPUT; KiCad renders its negated
  // output. kicadView maps config → on-screen so the body sits as the board
  // shows it. Applied as a nested transform inside the part group, so the
  // placement rotation composes on top exactly like a KiCad footprint.
  function kicadView(r, o) {
    return { rot: [-r[0], r[1], r[2]], off: [-o[0], -o[1], -o[2]] };
  }

  var _occtPromise, modelTemplates = {}, pendingModels = 0;
  function ensureOcct() {
    if (_occtPromise) return _occtPromise;
    return _occtPromise = occt({ locateFile: function (f) { return "/static/" + f; } });
  }

  // Parse a footprint's STEP once into a template Group (shared geometry is
  // cheap to .clone() per instance). Resolves null when there's no model.
  function getModelTemplate(fp) {
    if (modelTemplates[fp] !== undefined) return modelTemplates[fp];
    var M = (DATA.models || {})[fp];
    if (!M) return modelTemplates[fp] = Promise.resolve(null);
    var url = "/api/model-file/" + encodeURIComponent(fp);
    var pr = ensureOcct().then(function (o) {
      return fetch(url).then(function (r) {
        if (!r.ok) throw new Error("model " + r.status);
        return r.arrayBuffer();
      }).then(function (buf) {
        var res = o.ReadStepFile(new Uint8Array(buf), null);
        if (!res || !res.success || !res.meshes || !res.meshes.length) return null;
        var g = new THREE.Group();
        res.meshes.forEach(function (m) {
          var geo = new THREE.BufferGeometry();
          var pos = m.attributes && m.attributes.position && m.attributes.position.array;
          if (!pos) return;
          geo.setAttribute("position", new THREE.Float32BufferAttribute(pos, 3));
          if (m.attributes.normal && m.attributes.normal.array) {
            geo.setAttribute("normal", new THREE.Float32BufferAttribute(m.attributes.normal.array, 3));
          }
          if (m.index && m.index.array) geo.setIndex(m.index.array);
          if (!m.attributes.normal) geo.computeVertexNormals();
          var col = (m.color && m.color.length >= 3) ? new THREE.Color(m.color[0], m.color[1], m.color[2]) : new THREE.Color(0x9aa4ad);
          g.add(new THREE.Mesh(geo, new THREE.MeshStandardMaterial({ color: col, metalness: 0.45, roughness: 0.55 })));
        });
        return g;
      });
    }).catch(function (err) { console.warn("STEP load failed for " + fp, err); return null; });
    return modelTemplates[fp] = pr;
  }

  // Drop the placed body for one part (when its footprint has a model).
  function placeModel(partGroup, part) {
    var fp = part.fp;
    if (!fp || !((DATA.models || {})[fp])) return;
    pendingModels++;
    setStatus("Loading 3D models…");
    getModelTemplate(fp).then(function (tmpl) {
      if (tmpl) {
        var inst = tmpl.clone();
        var M = DATA.models[fp];
        var mv = kicadView(M.r || [0, 0, 0], M.o || [0, 0, 0]);
        inst.rotation.set(deg2rad(-mv.rot[0]), deg2rad(-mv.rot[1]), deg2rad(-mv.rot[2]), "ZYX");
        inst.position.set(mv.off[0], mv.off[1], mv.off[2]);
        partGroup.add(inst);
      }
    }).catch(function () {}).then(function () {
      if (--pendingModels <= 0) setStatus(null);
    });
  }

  // ── Bounds / substrate / pose sync ───────────────────────────────
  // Bounds from rotated courtyards (encompass the pads) of the *current* poses.
  function computeBounds() {
    var bb = { minx: Infinity, miny: Infinity, maxx: -Infinity, maxy: -Infinity };
    (DATA.parts || []).forEach(function (p) { growByCourtyard(bb, p); });
    if (!isFinite(bb.minx)) bb = { minx: -10, miny: -10, maxx: 10, maxy: 10 };
    return bb;
  }

  // (Re)build the green substrate slab to span the current bounds, and refresh
  // center/span (camera framing). Safe to call repeatedly — disposes the old
  // slab geometry and preserves the Board toggle's visibility state.
  function rebuildBoard() {
    var bb = computeBounds();
    while (boardGroup.children.length) {
      var old = boardGroup.children[boardGroup.children.length - 1];
      if (old.geometry) old.geometry.dispose();
      boardGroup.remove(old);
    }
    var mg = 2.0;
    var x0 = bb.minx - mg, y0 = bb.miny - mg, x1 = bb.maxx + mg, y1 = bb.maxy + mg;
    var board = new THREE.Mesh(new THREE.BoxGeometry(x1 - x0, y1 - y0, BOARD_T), boardMat);
    board.position.set((x0 + x1) / 2, (y0 + y1) / 2, -BOARD_T / 2);
    boardGroup.add(board);
    center.x = (bb.minx + bb.maxx) / 2; center.y = (bb.miny + bb.maxy) / 2;
    span = Math.max(bb.maxx - bb.minx, bb.maxy - bb.miny, 8);
  }

  // A cheap fingerprint of every part's pose — used to skip re-fitting when the
  // layout hasn't changed between two onShow() calls.
  function poseSig() {
    return (DATA.parts || []).map(function (p) {
      return p.x + "," + p.y + "," + (p.rot || 0);
    }).join(";");
  }

  // Re-apply the current PCB.parts poses to the part groups + substrate. Pads
  // and STEP bodies hang off each group, so moving the group moves the whole
  // part. This is what makes "Load a saved layout" show up in 3D.
  function applyPoses() {
    var parts = DATA.parts || [];
    for (var i = 0; i < partGroups.length; i++) {
      var p = parts[i]; if (!p) continue;
      partGroups[i].position.set(p.x, -p.y, 0);
      partGroups[i].rotation.z = deg2rad(-(p.rot || 0)); // Y flip reverses rotation sense
    }
    rebuildBoard();
    lastSig = poseSig();
  }

  // ── Scene build ──────────────────────────────────────────────────
  function build() {
    var PCB = DATA;
    canvas = document.getElementById("pcb-3d-canvas");
    statusEl = document.getElementById("pcb-3d-status");

    renderer = new THREE.WebGLRenderer({ canvas: canvas, antialias: true });
    renderer.setPixelRatio(window.devicePixelRatio || 1);
    scene = new THREE.Scene();
    scene.background = new THREE.Color(0x0d1117);

    camera = new THREE.PerspectiveCamera(45, 1, 0.05, 20000);
    camera.up.set(0, 0, 1);
    controls = new THREE.OrbitControls(camera, renderer.domElement);
    controls.enableDamping = true; controls.dampingFactor = 0.12;

    scene.add(new THREE.AmbientLight(0xffffff, 0.6));
    var key = new THREE.DirectionalLight(0xffffff, 0.85); key.position.set(40, -30, 80); scene.add(key);
    var fill = new THREE.DirectionalLight(0xffffff, 0.4); fill.position.set(-50, 40, 30); scene.add(fill);
    var rim = new THREE.DirectionalLight(0xffffff, 0.3); rim.position.set(0, 0, -60); scene.add(rim);
    axes = new THREE.AxesHelper(8); scene.add(axes);

    boardMat = new THREE.MeshStandardMaterial({ color: 0x1c5c33, metalness: 0.1, roughness: 0.85 });
    padMat = new THREE.MeshStandardMaterial({ color: 0xb08d57, metalness: 0.85, roughness: 0.35 });

    boardGroup = new THREE.Group();
    partsGroup = new THREE.Group();
    scene.add(boardGroup); scene.add(partsGroup);

    // One group per part, in PCB.parts order; pads now (model loads async). Pose
    // (position + rotation) and the substrate are applied by applyPoses() below,
    // so a later Load just re-runs that against the same groups.
    partGroups = [];
    (PCB.parts || []).forEach(function (p) {
      var g = new THREE.Group();
      addPads(g, p);
      partsGroup.add(g);
      partGroups.push(g);
      placeModel(g, p);
    });
    applyPoses();

    wireControls();
    viewIso();
    resize();
    if (pendingModels === 0) setStatus(null);
    looping = true;
    (function loop() {
      if (!looping) return;
      requestAnimationFrame(loop);
      controls.update();
      renderer.render(scene, camera);
    })();
  }

  // ── Camera presets + toolbar ─────────────────────────────────────
  function frame(dx, dy, dz) {
    var dir = new THREE.Vector3(dx, dy, dz).normalize();
    var d = span * 1.9;
    var c = new THREE.Vector3(center.x, center.y, 0);
    camera.position.copy(c).add(dir.multiplyScalar(d));
    controls.target.copy(c); controls.update();
  }
  function viewIso() { frame(0.7, -0.9, 0.8); }

  function wireControls() {
    var on = function (id, fn) { var e = document.getElementById(id); if (e) e.onclick = fn; };
    on("pcb3d-top", function () { frame(0, 0, 1); });
    on("pcb3d-iso", viewIso);
    on("pcb3d-front", function () { frame(0, -1, 0.03); });
    on("pcb3d-side", function () { frame(1, 0, 0.03); });
    var chk = function (id, fn) { var e = document.getElementById(id); if (e) e.onchange = function (ev) { fn(ev.target.checked); }; };
    chk("pcb3d-t-models", function (v) {
      partsGroup.children.forEach(function (g) {
        g.children.forEach(function (ch) { if (ch.type === "Group") ch.visible = v; });
      });
    });
    chk("pcb3d-t-pads", function (v) {
      partsGroup.children.forEach(function (g) {
        g.children.forEach(function (ch) { if (ch.type === "Mesh") ch.visible = v; });
      });
    });
    chk("pcb3d-t-board", function (v) { boardGroup.visible = v; });
    chk("pcb3d-t-axes", function (v) { axes.visible = v; });
  }

  function resize() {
    if (!canvas) return;
    var w = canvas.clientWidth, h = canvas.clientHeight;
    if (w === 0 || h === 0) return;
    renderer.setSize(w, h, false);
    camera.aspect = w / h; camera.updateProjectionMatrix();
  }
  window.addEventListener("resize", function () { if (built) resize(); });

  // ── Public entry points (called by the toggle wiring) ────────────
  window.PCB3D = {
    init: function () {
      if (built) return;
      THREE = window.THREE; occt = window.occtimportjs;
      // `const PCB` is a lexical global (not on window); read it strict-safely.
      DATA = (typeof window !== "undefined" && window.PCB) ? window.PCB
        : (typeof PCB !== "undefined" ? PCB : {});
      if (!THREE) { setStatus && setStatus("Three.js failed to load", true); return; }
      built = true;
      try { build(); }
      catch (e) { console.error(e); setStatus("3D view failed: " + (e && e.message), true); }
    },
    // Re-read PCB.parts and re-pose the scene in place. Called from the 2D board
    // whenever a Load/reset changes the placement while 3D is already built, so
    // loading a specific saved layout updates the 3D preview live. The camera is
    // deliberately left untouched (no re-fit) — only the initial build() frames
    // the board; after that the user's current orbit is preserved across loads.
    sync: function () { if (built) applyPoses(); },
    onShow: function () {
      if (!built) return;
      // Reflect any layout change made in 2D since 3D was last shown, but keep
      // the user's current camera (the "Iso" button re-fits on demand).
      if (poseSig() !== lastSig) applyPoses();
      resize();
    }
  };
})();
