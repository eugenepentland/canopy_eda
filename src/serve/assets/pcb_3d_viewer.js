/* 3D PCB-layout viewer.
 *
 * Renders the whole placed board in WebGL from the same `window.PCB` blob the
 * 2D BOARD_JS reads: the exact physical board outline and thickness, every
 * part's copper pads on its mounted face, and — for any footprint with a
 * resolved STEP model (PCB.models) — the 3D part body, oriented exactly as
 * KiCad would place it. Bottom-side parts are mirrored through the board in
 * the same local-X-first transform used by the 2D editor and optimizer.
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

  var THREE, occt, surface; // resolved at init() — scripts load lazily
  // The page emits `const PCB = {...}` — a lexical global, NOT a window
  // property — so we read the bare binding (via typeof to stay strict-safe),
  // resolved at init() time when it's guaranteed defined.
  var DATA = {};
  var renderer, scene, camera, controls;
  var boardGroup, partsGroup, heatsinkGroup, axes;
  // One pose Group per PCB.parts entry, in the same index order — so a Load /
  // drag / reset / side flip that mutated PCB.parts can be re-applied by
  // walking both arrays. Each pose group owns a nested `mount` group whose
  // local Y rotation moves a top-side footprint onto the bottom face.
  var partGroups = [];
  var built = false, looping = false;
  var center = { x: 0, y: 0 }, span = 20;
  // Signature of the poses 3D last rendered; lets onShow() detect a layout that
  // changed in 2D (Load/reset/drag) and re-fit the camera only when it did.
  var lastSig = "";
  var statusEl, canvas;

  var DEFAULT_BOARD_T = 1.6;
  var boardCapMat, boardEdgeMat;
  var layerVisible = { models: true, surfaces: true, heatsink: true };

  function deg2rad(d) { return d * Math.PI / 180; }
  function boardThickness() {
    var t = DATA.rules && +DATA.rules.board_thickness;
    return t > 0 ? t : DEFAULT_BOARD_T;
  }
  function setStatus(msg, isErr) {
    if (!statusEl) return;
    if (!msg) { statusEl.style.display = "none"; return; }
    statusEl.style.display = "block";
    statusEl.textContent = msg;
    statusEl.className = isErr ? "err" : "";
  }

  // ── Geometry helpers ─────────────────────────────────────────────
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
    // depthTest off so the label is never buried inside board/part geometry.
    return new THREE.Sprite(new THREE.SpriteMaterial({ map: tex, transparent: true, depthTest: false, depthWrite: false }));
  }
  // Origin gizmo: R/G/B arrows for +X/+Y/+Z (arrowheads point the positive way),
  // an X/Y/Z label at each tip, and a white dot marking (0,0,0) — the board's
  // placement origin, so it's clear which way parts move/rotate.
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
  function rectPoints(r) {
    if (!r || !(r.w > 0) || !(r.h > 0)) return null;
    return [[r.x, r.y], [r.x + r.w, r.y], [r.x + r.w, r.y + r.h], [r.x, r.y + r.h]];
  }

  // Resolve the same physical outline the 2D editor paints. A live layout
  // override wins; PCBOutlinePoly expands its native corner radii using the
  // editor's cached fillet geometry. Otherwise board_poly is already the
  // server's exact sagitta-bounded profile, with board as the rectangle
  // fallback. Re-reading this on every sync means an edited outline appears
  // when the user returns to 3D without a page reload.
  function outlinePoints() {
    var pts = null;
    if (DATA.outline) {
      if (typeof window.PCBOutlinePoly === "function") pts = window.PCBOutlinePoly(DATA.outline);
      else pts = DATA.outline.pts;
      if (!pts || pts.length < 3) pts = rectPoints(DATA.outline);
    }
    if (!pts || pts.length < 3) pts = DATA.board_poly;
    if (!pts || pts.length < 3) pts = rectPoints(DATA.board);
    if (!pts || pts.length < 3) return null;

    // A few importers repeat the first point at the end. Shape closes the path
    // itself, so strip only that redundant endpoint and leave all real outline
    // vertices (including concave ones) untouched.
    var out = pts.slice();
    if (out.length > 3) {
      var a = out[0], b = out[out.length - 1];
      if (Math.abs(a[0] - b[0]) < 1e-9 && Math.abs(a[1] - b[1]) < 1e-9) out.pop();
    }
    return out.length >= 3 ? out : null;
  }

  function boundsOfPoints(pts) {
    var bb = { minx: Infinity, miny: Infinity, maxx: -Infinity, maxy: -Infinity };
    pts.forEach(function (p) {
      var x = +p[0], y = -p[1];
      if (x < bb.minx) bb.minx = x; if (x > bb.maxx) bb.maxx = x;
      if (y < bb.miny) bb.miny = y; if (y > bb.maxy) bb.maxy = y;
    });
    return bb;
  }

  function shapeOfPoints(pts, holes) {
    var shape = new THREE.Shape();
    shape.moveTo(pts[0][0], -pts[0][1]);
    for (var i = 1; i < pts.length; i++) shape.lineTo(pts[i][0], -pts[i][1]);
    shape.closePath();
    if (surface && holes) surface.addShapeHoles(THREE, shape, holes);
    return shape;
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

  var _occtPromise, modelTemplates = {}, modelGenerations = {}, pendingModels = 0;
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
    var generation = modelGenerations[fp] || 0;
    pendingModels++;
    setStatus("Loading 3D models…");
    getModelTemplate(fp).then(function (tmpl) {
      // An upload can replace this footprint while its old STEP is still being
      // parsed. Only the current generation may enter the scene.
      if (tmpl && (modelGenerations[fp] || 0) === generation) {
        var inst = tmpl.clone();
        var M = DATA.models[fp];
        var mv = kicadView(M.r || [0, 0, 0], M.o || [0, 0, 0]);
        inst.rotation.set(deg2rad(-mv.rot[0]), deg2rad(-mv.rot[1]), deg2rad(-mv.rot[2]), "ZYX");
        inst.position.set(mv.off[0], mv.off[1], mv.off[2]);
        inst.userData.pcb3dKind = "models";
        inst.userData.pcb3dFootprint = fp;
        inst.visible = layerVisible.models;
        partGroup.add(inst);
      }
    }).catch(function () {}).then(function () {
      if (--pendingModels <= 0) setStatus(null);
    });
  }

  // Register an uploaded/replaced model without rebuilding the PCB scene or
  // disturbing the user's camera. Before 3D init, pcb_board.js updates the
  // shared DATA.models map and init naturally picks it up; after init, this
  // removes any old body, invalidates its parsed template, and reloads every
  // matching placed instance.
  function refreshModel(fp, transform) {
    DATA.models = DATA.models || {};
    DATA.models[fp] = transform || { o: [0, 0, 0], r: [0, 0, 0] };
    if (!built) return;
    modelGenerations[fp] = (modelGenerations[fp] || 0) + 1;
    delete modelTemplates[fp];
    (DATA.parts || []).forEach(function (part, i) {
      if (part.fp !== fp || !partGroups[i]) return;
      var mount = partGroups[i].userData.mount;
      mount.children.slice().forEach(function (child) {
        if (child.userData.pcb3dKind === "models" && child.userData.pcb3dFootprint === fp) mount.remove(child);
      });
      placeModel(mount, part);
    });
  }

  // ── Bounds / substrate / pose sync ───────────────────────────────
  // Fallback bounds from rotated courtyards (encompass the pads) of the
  // *current* poses. Used only for legacy/module scenes with no board outline.
  function computePartBounds() {
    var bb = { minx: Infinity, miny: Infinity, maxx: -Infinity, maxy: -Infinity };
    (DATA.parts || []).forEach(function (p) { growByCourtyard(bb, p); });
    if (!isFinite(bb.minx)) bb = { minx: -10, miny: -10, maxx: 10, maxy: 10 };
    return bb;
  }

  function disposeBoardObject(obj) {
    if (obj.geometry) obj.geometry.dispose();
    if (obj.userData && obj.userData.disposeMaterial) {
      var mats = Array.isArray(obj.material) ? obj.material : [obj.material];
      mats.forEach(function (m) { if (m) { if (m.map) m.map.dispose(); m.dispose(); } });
    }
  }

  function disposeGroup(group) {
    var materials = [];
    group.traverse(function (obj) {
      if (obj.geometry) obj.geometry.dispose();
      var mats = Array.isArray(obj.material) ? obj.material : (obj.material ? [obj.material] : []);
      mats.forEach(function (mat) { if (materials.indexOf(mat) < 0) materials.push(mat); });
    });
    materials.forEach(function (mat) { if (mat.map) mat.map.dispose(); mat.dispose(); });
    while (group.children.length) group.remove(group.children[group.children.length - 1]);
  }

  function heatsinkColor(material) {
    if (material === "copper_c110") return 0xc87941;
    if (material === "steel") return 0x7d8790;
    if (material === "aluminum_6061") return 0xb0b7bd;
    return 0xc4cbd0;
  }

  function addHeatsinkBox(group, material, sx, sy, sz, x, y, z) {
    if (!(sx > 0) || !(sy > 0) || !(sz > 0)) return;
    var mesh = new THREE.Mesh(new THREE.BoxGeometry(sx, sy, sz), material);
    mesh.position.set(x, y, z);
    group.add(mesh);
  }

  // Build the saved physical assembly rather than a generic thermal marker.
  // The pad, base and every straight fin use millimetres in the same coordinate
  // frame as the PCB. Bottom assemblies extend toward -Z, away from the board.
  function rebuildHeatsink() {
    disposeGroup(heatsinkGroup);
    var s = DATA.heatsink;
    if (!s || !(s.w > 0) || !(s.h > 0)) return;

    var sign = s.side === "bottom" ? -1 : 1;
    var faceZ = sign < 0 ? -boardThickness() : 0;
    var padT = Math.max(0, +s.pad_thickness_mm || 0);
    var baseT = Math.max(0, +s.base_mm || 0);
    var finH = Math.max(0, +s.fin_height_mm || 0);
    var finT = Math.max(0, +s.fin_thickness_mm || 0);
    var finGap = Math.max(0, +s.fin_gap_mm || 0);
    var cx = +s.x + +s.w / 2, cy = -(+s.y + +s.h / 2);
    var metal = new THREE.MeshStandardMaterial({
      color: heatsinkColor(s.material), metalness: 0.78, roughness: 0.27
    });
    var pad = padT > 0 ? new THREE.MeshStandardMaterial({
      color: 0x6aa9d8, transparent: true, opacity: 0.62, metalness: 0.05, roughness: 0.8
    }) : null;

    if (pad) addHeatsinkBox(heatsinkGroup, pad, +s.w, +s.h, padT, cx, cy,
      faceZ + sign * padT / 2);
    addHeatsinkBox(heatsinkGroup, metal, +s.w, +s.h, baseT, cx, cy,
      faceZ + sign * (padT + baseT / 2));

    if (finH > 0 && finT > 0) {
      var lengthAxis = (s.fin_axis || "length") === "length";
      var across = lengthAxis ? +s.w : +s.h;
      var along = lengthAxis ? +s.h : +s.w;
      var pitch = finT + finGap;
      var count = Math.min(512, Math.max(1, Math.floor((across + finGap) / pitch)));
      var first = -(count - 1) * pitch / 2;
      var finZ = faceZ + sign * (padT + baseT + finH / 2);
      for (var i = 0; i < count; i++) {
        var offset = first + i * pitch;
        addHeatsinkBox(heatsinkGroup, metal,
          lengthAxis ? finT : along, lengthAxis ? along : finT, finH,
          cx + (lengthAxis ? offset : 0), cy + (lengthAxis ? 0 : offset), finZ);
      }
    }
    heatsinkGroup.visible = layerVisible.heatsink;
    span = Math.max(span, 2 * (padT + baseT + finH), 8);
  }

  // This face mesh is the board's only visible cap and carries the one
  // composited manufacturing texture for that side. The substrate extrusion
  // beneath it renders sidewalls only, so there is no nearly-coplanar duplicate
  // surface to depth-fight as the camera orbits.
  function addBoardFace(shape, pts, side, z) {
    var painted = surface.makeTexture(THREE, DATA, pts, side);
    var geometry = new THREE.ShapeGeometry(shape);
    surface.mapUvs(geometry, painted.bounds);
    var material = new THREE.MeshStandardMaterial({
      map: painted.texture, metalness: 0.04, roughness: 0.68, side: THREE.DoubleSide
    });
    var mesh = new THREE.Mesh(geometry, material);
    mesh.position.z = z; mesh.renderOrder = 2;
    mesh.visible = layerVisible.surfaces;
    mesh.userData.pcb3dKind = "surfaces";
    mesh.userData.disposeMaterial = true;
    boardGroup.add(mesh);
  }

  // (Re)build the substrate from the exact physical outline and real drill
  // list, then lay one copper/mask/silk canvas texture over each face. Concave
  // outlines, slots and circular holes are all triangulated into the same
  // extrusion. Legacy scenes with no outline retain the courtyard rectangle.
  function rebuildBoard() {
    var pts = outlinePoints();
    if (!pts) {
      var partBB = computePartBounds(), mg = 2.0;
      pts = [[partBB.minx - mg, -(partBB.miny - mg)],
        [partBB.maxx + mg, -(partBB.miny - mg)],
        [partBB.maxx + mg, -(partBB.maxy + mg)],
        [partBB.minx - mg, -(partBB.maxy + mg)]];
    }
    var bb = boundsOfPoints(pts);
    while (boardGroup.children.length) {
      var old = boardGroup.children[boardGroup.children.length - 1];
      disposeBoardObject(old);
      boardGroup.remove(old);
    }
    var thickness = boardThickness(), holes = surface.collectHoles(DATA, pts);
    var shape = shapeOfPoints(pts, holes);
    var geometry = new THREE.ExtrudeGeometry(shape, {
      depth: thickness, bevelEnabled: false, curveSegments: 1
    });
    // ExtrudeGeometry grows toward +Z; translate it down so the top copper
    // plane remains z=0 and the bottom component plane is z=-thickness.
    var board = new THREE.Mesh(geometry, [boardCapMat, boardEdgeMat]);
    board.position.z = -thickness;
    boardGroup.add(board);
    addBoardFace(shape, pts, "top", 0);
    addBoardFace(shape, pts, "bottom", -thickness);
    center.x = (bb.minx + bb.maxx) / 2; center.y = (bb.miny + bb.maxy) / 2;
    span = Math.max(bb.maxx - bb.minx, bb.maxy - bb.miny, 8);
  }

  // A cheap fingerprint of every part's pose — used to skip re-fitting when the
  // layout hasn't changed between two onShow() calls.
  function poseSig() {
    return (DATA.parts || []).map(function (p) {
      return p.x + "," + p.y + "," + (p.rot || 0) + "," + (p.side || "top");
    }).join(";");
  }

  // Copper, mask, silk and drills can all change while the 2D editor owns the
  // screen. Include their live arrays so returning to 3D repaints both face
  // canvases even when no component pose moved.
  function artworkSig() {
    try {
      return JSON.stringify([
        DATA.parts, DATA.tracks, DATA.vias, DATA.pours, DATA.zone_fills,
        DATA.mask_relief, DATA.texts, DATA.fab_text, DATA.heatsink
      ]);
    } catch (_) { return "artwork"; }
  }

  function sceneSig() {
    var pts = outlinePoints();
    return poseSig() + "|" + boardThickness() + "|" + (pts ? pts.map(function (p) {
      return p[0] + "," + p[1];
    }).join(";") : "auto") + "|" + artworkSig();
  }

  // Re-apply current poses to STEP bodies and rebuild the textured/drilled
  // substrate. Surface copper and pads live in the face canvases, so this one
  // sync also catches routing, mask, silk and drill edits made in 2D.
  function applyPoses() {
    var parts = DATA.parts || [];
    var thickness = boardThickness();
    for (var i = 0; i < partGroups.length; i++) {
      var p = parts[i]; if (!p) continue;
      var pose = partGroups[i], mount = pose.userData.mount;
      pose.position.set(p.x, -p.y, 0);
      pose.rotation.z = deg2rad(-(p.rot || 0)); // Y flip reverses rotation sense
      var bottom = p.side === "bottom";
      // Rotate the footprint frame 180 degrees about local Y. This mirrors
      // local X exactly like the optimizer's bottom-side transform and also
      // turns +Z outward beneath the board. Translation selects the physical
      // bottom copper plane; top parts remain rooted at z=0.
      mount.rotation.y = bottom ? Math.PI : 0;
      mount.position.z = bottom ? -thickness : 0;
    }
    rebuildBoard();
    rebuildHeatsink();
    lastSig = sceneSig();
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
    axes = buildAxisGizmo(8); scene.add(axes); // labeled +X/+Y/+Z arrows + origin dot

    // ExtrudeGeometry assigns material 0 to its front/back caps and material 1
    // to every outer and drill wall. The textured ShapeGeometry meshes are the
    // real visible caps, so suppress material 0 completely instead of stacking
    // two surfaces a few microns apart. Brown FR-4 sidewalls also make bores
    // legible through the green mask and copper annulus.
    boardCapMat = new THREE.MeshBasicMaterial({ visible: false });
    boardEdgeMat = new THREE.MeshStandardMaterial({ color: surface.maskColor, metalness: 0.03, roughness: 0.95 });

    boardGroup = new THREE.Group();
    partsGroup = new THREE.Group();
    heatsinkGroup = new THREE.Group();
    scene.add(boardGroup); scene.add(partsGroup); scene.add(heatsinkGroup);

    // One group per part, in PCB.parts order. Only STEP bodies need individual
    // 3D objects now; pads are painted into the board's two face textures.
    partGroups = [];
    (PCB.parts || []).forEach(function (p) {
      var pose = new THREE.Group(), mount = new THREE.Group();
      pose.add(mount); partsGroup.add(pose);
      pose.userData.mount = mount;
      partGroups.push(pose);
      placeModel(mount, p);
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
    on("pcb3d-bottom", function () { frame(0, 0, -1); });
    on("pcb3d-iso", viewIso);
    on("pcb3d-front", function () { frame(0, -1, 0.03); });
    on("pcb3d-side", function () { frame(1, 0, 0.03); });
    var chk = function (id, fn) { var e = document.getElementById(id); if (e) e.onchange = function (ev) { fn(ev.target.checked); }; };
    chk("pcb3d-t-models", function (v) {
      layerVisible.models = v;
      partsGroup.traverse(function (ch) { if (ch.userData.pcb3dKind === "models") ch.visible = v; });
    });
    chk("pcb3d-t-surface", function (v) {
      layerVisible.surfaces = v;
      boardGroup.traverse(function (ch) { if (ch.userData.pcb3dKind === "surfaces") ch.visible = v; });
    });
    chk("pcb3d-t-board", function (v) { boardGroup.visible = v; });
    chk("pcb3d-t-heatsink", function (v) { layerVisible.heatsink = v; heatsinkGroup.visible = v; });
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
      THREE = window.THREE; occt = window.occtimportjs; surface = window.PCB3DSurface;
      // `const PCB` is a lexical global (not on window); read it strict-safely.
      DATA = (typeof window !== "undefined" && window.PCB) ? window.PCB
        : (typeof PCB !== "undefined" ? PCB : {});
      if (!THREE || !surface) { setStatus && setStatus("3D assets failed to load", true); return; }
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
    modelAdded: function (fp, transform) { if (fp) refreshModel(fp, transform); },
    onShow: function () {
      if (!built) return;
      // Reflect any layout change made in 2D since 3D was last shown, but keep
      // the user's current camera (the "Iso" button re-fits on demand).
      if (sceneSig() !== lastSig) applyPoses();
      resize();
    }
  };
})();
