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

  var THREE, surface; // resolved at init() — scripts load lazily
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
  var built = false, renderQueued = false;
  var softwareRenderer = false, idlePixelRatio = 1, interactivePixelRatio = 1;
  var restoreQualityTimer = null;
  var center = { x: 0, y: 0, z: 0 }, span = 20;
  // Signature of the poses 3D last rendered; lets onShow() detect a layout that
  // changed in 2D (Load/reset/drag) and re-fit the camera only when it did.
  var lastSig = "";
  var statusEl, canvas;
  var exportButton;

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

  function updateExportButton() {
    if (exportButton) {
      exportButton.disabled = pendingModels > 0;
      exportButton.textContent = pendingModels > 0 ? "Loading models…" : "Export STEP";
    }
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
  // an X/Y/Z label at each tip, and a white dot marking the centered board
  // datum. Keep it visible through the substrate because its true Z origin is
  // the PCB thickness mid-plane rather than either outer copper face.
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
    g.traverse(function (obj) {
      if (!obj.material) return;
      obj.material.depthTest = false; obj.material.depthWrite = false;
      obj.renderOrder = 10;
    });
    return g;
  }
  function rectPoints(r) {
    if (!r || !(r.w > 0) || !(r.h > 0)) return null;
    return [[r.x, r.y], [r.x + r.w, r.y], [r.x + r.w, r.y + r.h], [r.x, r.y + r.h]];
  }

  function outlineArc(arc) {
    if (!arc) return null;
    if (Array.isArray(arc.p1) && Array.isArray(arc.pm) && Array.isArray(arc.p2)) {
      return { p1: [+arc.p1[0], +arc.p1[1]], pm: [+arc.pm[0], +arc.pm[1]], p2: [+arc.p2[0], +arc.p2[1]] };
    }
    if (arc.p1 && arc.pm && arc.p2) {
      return { p1: [+arc.p1.x, +arc.p1.y], pm: [+arc.pm.x, +arc.pm.y], p2: [+arc.p2.x, +arc.p2.y] };
    }
    return { p1: [+arc.x1, +arc.y1], pm: [+arc.xm, +arc.ym], p2: [+arc.x2, +arc.y2] };
  }

  // Resolve the same physical outline the 2D editor paints in both forms the
  // viewers need: a fine polygon for WebGL and the native circular arcs for
  // STEP. A live layout override wins; otherwise board_poly + board_arcs are
  // the server's fabrication contour, with board as the sharp rectangle
  // fallback. Re-reading this on every sync picks up unsaved fillet edits.
  function outlineGeometry() {
    var pts = null, arcs = [];
    if (DATA.outline) {
      if (typeof window.PCBOutlineGeometry === "function") {
        var live = window.PCBOutlineGeometry(DATA.outline);
        if (live) { pts = live.points; arcs = live.arcs || []; }
      } else if (typeof window.PCBOutlinePoly === "function") pts = window.PCBOutlinePoly(DATA.outline);
      else pts = DATA.outline.pts;
      if (!pts || pts.length < 3) { pts = rectPoints(DATA.outline); arcs = []; }
    }
    if (!pts || pts.length < 3) {
      pts = DATA.board_poly;
      arcs = pts && pts.length >= 3 ? (DATA.board_arcs || []) : [];
    }
    if (!pts || pts.length < 3) { pts = rectPoints(DATA.board); arcs = []; }
    if (!pts || pts.length < 3) return null;

    // A few importers repeat the first point at the end. Shape closes the path
    // itself, so strip only that redundant endpoint and leave all real outline
    // vertices (including concave ones) untouched.
    var out = pts.slice();
    if (out.length > 3) {
      var a = out[0], b = out[out.length - 1];
      if (Math.abs(a[0] - b[0]) < 1e-9 && Math.abs(a[1] - b[1]) < 1e-9) out.pop();
    }
    return out.length >= 3 ? { points: out, arcs: arcs.map(outlineArc).filter(Boolean) } : null;
  }

  function outlinePoints() {
    var geometry = outlineGeometry();
    return geometry && geometry.points;
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

  var modelWorker = null, modelWorkerSeq = 0, modelWorkerPending = {};
  var modelTemplates = {}, modelGenerations = {}, pendingModels = 0;

  function rejectModelWorker(error) {
    var message = error && error.message ? error.message : String(error || "STEP worker failed");
    Object.keys(modelWorkerPending).forEach(function (id) {
      modelWorkerPending[id].reject(new Error(message));
      delete modelWorkerPending[id];
    });
    if (modelWorker) modelWorker.terminate();
    modelWorker = null;
  }

  function ensureModelWorker() {
    if (modelWorker) return modelWorker;
    modelWorker = new Worker("/static/pcb_step_worker.js");
    modelWorker.onmessage = function (event) {
      var message = event.data || {}, pending = modelWorkerPending[message.id];
      if (!pending) return;
      delete modelWorkerPending[message.id];
      if (message.error) pending.reject(new Error(message.error));
      else pending.resolve(message.result);
    };
    modelWorker.onerror = rejectModelWorker;
    modelWorker.onmessageerror = rejectModelWorker;
    return modelWorker;
  }

  function parseStepFile(buffer) {
    return new Promise(function (resolve, reject) {
      var id = ++modelWorkerSeq;
      modelWorkerPending[id] = { resolve: resolve, reject: reject };
      try { ensureModelWorker().postMessage({ id: id, buffer: buffer }, [buffer]); }
      catch (error) {
        delete modelWorkerPending[id];
        reject(error);
      }
    });
  }

  // Parse a footprint's STEP once into a template Group (shared geometry is
  // cheap to .clone() per instance). Resolves null when there's no model.
  function getModelTemplate(fp) {
    if (modelTemplates[fp] !== undefined) return modelTemplates[fp];
    var M = (DATA.models || {})[fp];
    if (!M) return modelTemplates[fp] = Promise.resolve(null);
    var url = "/api/model-file/" + encodeURIComponent(fp);
    var pr = fetch(url).then(function (r) {
      if (!r.ok) throw new Error("model " + r.status);
      return r.arrayBuffer();
    }).then(parseStepFile).then(function (res) {
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
    }).catch(function (err) { console.warn("STEP load failed for " + fp, err); return null; });
    return modelTemplates[fp] = pr;
  }

  // Drop the placed body for one part (when its footprint has a model).
  function placeModel(partGroup, part) {
    var fp = part.fp;
    if (!fp || !((DATA.models || {})[fp])) return;
    var generation = modelGenerations[fp] || 0;
    pendingModels++;
    updateExportButton();
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
        requestRender();
      }
    }).catch(function () {}).then(function () {
      pendingModels--;
      updateExportButton();
    });
  }

  // ── Server-side exact AP242 STEP export ────────────────────────────
  // The WebGL scene is deliberately tessellated for display, but the board is
  // sent as its 2D profile + thickness so the server can build a native
  // analytic B-rep. Only optional heatsink boxes cross the wire as facets; the
  // server reads each untouched library STEP and instances its original B-rep.
  var STEP_PROXY_FACE_THRESHOLD = 32, STEP_PROXY_MAX_SIZE_MM = 10;

  function stepFabricationId() {
    // fab_text is the freshly derived mark that fabrication writes. An adopted
    // text supplies the same value while derived data is still loading.
    var mark = DATA.fab_text || null;
    if (!mark) (DATA.texts || []).some(function (text) {
      if (text && text.fabrication_id) { mark = text; return true; }
      return false;
    });
    var match = /^ID\s+([0-9a-f]{8})$/i.exec(String(mark && mark.text || "").trim());
    return match ? match[1].toUpperCase() : "";
  }

  function stepFileName() {
    return window.PCBStepExport.fileName(DATA.name, stepFabricationId());
  }

  function stepMaterialColor(material) {
    if (!material || !material.color) return null;
    return [material.color.r, material.color.g, material.color.b];
  }

  function sameStepColor(a, b) {
    if (!a || !b) return a === b;
    return Math.abs(a[0] - b[0]) < 1e-9 && Math.abs(a[1] - b[1]) < 1e-9 && Math.abs(a[2] - b[2]) < 1e-9;
  }

  function triangleStepColor(obj, offset) {
    var materialIndex = 0, groups = (obj.geometry && obj.geometry.groups) || [];
    for (var i = 0; i < groups.length; i++) {
      if (offset >= groups[i].start && offset < groups[i].start + groups[i].count) {
        materialIndex = groups[i].materialIndex || 0;
        break;
      }
    }
    var material = Array.isArray(obj.material) ? obj.material[materialIndex] : obj.material;
    return stepMaterialColor(material);
  }

  function stepProxyBox(obj, name, meshIndex, position, triangleCount) {
    if (triangleCount <= STEP_PROXY_FACE_THRESHOLD || /(^|\/)(?:J|MK)\d/.test(name)) return null;
    var min = [Infinity, Infinity, Infinity], max = [-Infinity, -Infinity, -Infinity], v = new THREE.Vector3();
    for (var i = 0; i < position.count; i++) {
      v.fromBufferAttribute(position, i).applyMatrix4(obj.matrixWorld);
      var values = [v.x, v.y, v.z];
      for (var axis = 0; axis < 3; axis++) {
        min[axis] = Math.min(min[axis], values[axis]); max[axis] = Math.max(max[axis], values[axis]);
      }
    }
    var largest = Math.max(max[0] - min[0], max[1] - min[1], max[2] - min[2]);
    if (!(largest < STEP_PROXY_MAX_SIZE_MM)) return null;
    var corners = [
      [min[0], min[1], min[2]], [max[0], min[1], min[2]],
      [max[0], max[1], min[2]], [min[0], max[1], min[2]],
      [min[0], min[1], max[2]], [max[0], min[1], max[2]],
      [max[0], max[1], max[2]], [min[0], max[1], max[2]]
    ];
    var points = corners.map(function (point) { return point.slice(); });
    return {
      name: name + " mesh " + meshIndex + " mechanical envelope", points: points,
      triangles: [
        [0, 2, 1], [0, 3, 2], [4, 5, 6], [4, 6, 7],
        [0, 1, 5], [0, 5, 4], [1, 2, 6], [1, 6, 5],
        [2, 3, 7], [2, 7, 6], [3, 0, 4], [3, 4, 7]
      ],
      color: stepMaterialColor(Array.isArray(obj.material) ? obj.material[0] : obj.material)
    };
  }

  // Preserve every source mesh as its own candidate solid.  Flattening all
  // children of a package into one vertex pool welds merely touching package,
  // lead and pad bodies together and turns valid vendor solids non-manifold.
  // The writer may still split disconnected islands inside one source mesh.
  function collectStepMeshes(group, name) {
    if (!group) return [];
    var out = [], v = new THREE.Vector3(), meshIndex = 0;
    group.traverse(function (obj) {
      if (!obj.isMesh || (obj.userData && obj.userData.pcb3dKind === "surfaces")) return;
      var geometry = obj.geometry;
      var position = geometry && geometry.getAttribute && geometry.getAttribute("position");
      if (!position || position.count < 3) return;
      var index = geometry.index, triangleCount = Math.floor((index ? index.count : position.count) / 3);
      var ordinal = ++meshIndex, proxy = stepProxyBox(obj, name, ordinal, position, triangleCount);
      if (proxy) { out.push(proxy); return; }
      var points = [], triangles = [], triangleColors = [];
      for (var i = 0; i < position.count; i++) {
        v.fromBufferAttribute(position, i).applyMatrix4(obj.matrixWorld);
        points.push([v.x, v.y, v.z]);
      }
      if (index) {
        for (var j = 0; j + 2 < index.count; j += 3) {
          triangles.push([index.getX(j), index.getX(j + 1), index.getX(j + 2)]);
          triangleColors.push(triangleStepColor(obj, j));
        }
      } else {
        for (var k = 0; k + 2 < position.count; k += 3) {
          triangles.push([k, k + 1, k + 2]);
          triangleColors.push(triangleStepColor(obj, k));
        }
      }
      if (!triangles.length) return;
      var uniform = triangleColors[0] || stepMaterialColor(Array.isArray(obj.material) ? obj.material[0] : obj.material);
      var mixed = triangleColors.some(function (color) { return !sameStepColor(color, uniform); });
      out.push({
        name: name + " mesh " + ordinal, points: points, triangles: triangles,
        color: mixed ? null : uniform, triangleColors: mixed ? triangleColors : null
      });
    });
    return out;
  }

  function collectGeneratedStepBodies() {
    var out = [];
    scene.updateMatrixWorld(true);
    // Unlike camera/view controls, the heatsink checkbox is an assembly
    // selection: an unchecked heatsink must not enter the exported STEP.
    if (layerVisible.heatsink) (heatsinkGroup.children || []).forEach(function (child, i) {
      out.push.apply(out, collectStepMeshes(child, "Heatsink " + (i + 1)));
    });
    var solids = window.PCBStepExport.prepareBodies(out).filter(function (body) { return body.closed; }).map(function (body) {
      return {
        name: body.name, points: body.points, triangles: body.triangles,
        color: body.color, triangleColors: body.triangleColors
      };
    });
    return solids;
  }

  function exactStepBoard() {
    var geometry = outlineGeometry();
    var pts = geometry && geometry.points;
    var arcs = geometry ? geometry.arcs : [];
    if (!pts) {
      var partBB = computePartBounds(), mg = 2.0;
      pts = [[partBB.minx - mg, -(partBB.miny - mg)],
        [partBB.maxx + mg, -(partBB.miny - mg)],
        [partBB.maxx + mg, -(partBB.maxy + mg)],
        [partBB.minx - mg, -(partBB.maxy + mg)]];
      arcs = [];
    }
    var holes = surface.collectHoles(DATA, pts).map(function (hole) {
      var out = { x: +hole.x, y: -(+hole.y), r: +hole.r };
      if (hole.x2 != null && hole.y2 != null) {
        out.x2 = +hole.x2; out.y2 = -(+hole.y2);
      }
      return out;
    });
    return {
      name: "PCB solid",
      outline: pts.map(function (point) { return [+point[0], -(+point[1])]; }),
      arcs: arcs.map(function (arc) {
        return {
          p1: [+arc.p1[0], -(+arc.p1[1])],
          pm: [+arc.pm[0], -(+arc.pm[1])],
          p2: [+arc.p2[0], -(+arc.p2[1])]
        };
      }),
      holes: holes,
      thickness: boardThickness(),
      color: stepMaterialColor(boardEdgeMat)
    };
  }

  function exactStepInstances() {
    var out = [];
    scene.updateMatrixWorld(true);
    partGroups.forEach(function (pose, i) {
      var part = (DATA.parts || [])[i] || {}, mount = pose.userData.mount, M = (DATA.models || {})[part.fp];
      if (!part.fp || !mount || !M) return;
      // Reconstruct the model root's local transform from metadata instead of
      // borrowing a parsed preview child. Exact export therefore still works
      // when WebGL/OpenCascade preview loading failed for a valid source STEP.
      var mv = kicadView(M.r || [0, 0, 0], M.o || [0, 0, 0]);
      var local = new THREE.Object3D();
      local.rotation.set(deg2rad(-mv.rot[0]), deg2rad(-mv.rot[1]), deg2rad(-mv.rot[2]), "ZYX");
      local.position.set(mv.off[0], mv.off[1], mv.off[2]);
      local.updateMatrix();
      mount.updateMatrixWorld(true);
      var world = new THREE.Matrix4().multiplyMatrices(mount.matrixWorld, local.matrix);
      out.push({
        name: part.ref || part.fp || ("Component " + (i + 1)),
        footprint: part.fp,
        matrix: Array.prototype.slice.call(world.elements)
      });
    });
    return out;
  }

  function stepPayload() {
    return {
      board: exactStepBoard(),
      bodies: collectGeneratedStepBodies(),
      instances: exactStepInstances()
    };
  }

  function requestStepBlob() {
    var payload = stepPayload();
    return fetch("/api/pcb-step/" + encodeURIComponent(DATA.name), {
      method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(payload)
    }).then(function (response) {
      if (!response.ok) return response.text().then(function (message) {
        throw new Error(message || ("server returned " + response.status));
      });
      return response.blob();
    });
  }

  function downloadBlob(blob, filename) {
    var url = URL.createObjectURL(blob), a = document.createElement("a");
    a.href = url; a.download = filename; a.style.display = "none";
    document.body.appendChild(a); a.click(); a.remove();
    setTimeout(function () { URL.revokeObjectURL(url); }, 1000);
  }

  function exportStep() {
    if (pendingModels > 0) return;
    exportButton.disabled = true;
    exportButton.textContent = "Exporting…";
    setStatus("Building exact STEP assembly on the server…");
    // Yield once so the busy state paints before generated heatsink bodies are
    // normalized and posted. Component triangle buffers never cross the wire.
    setTimeout(function () {
      Promise.resolve().then(requestStepBlob).then(function (blob) {
        downloadBlob(blob, stepFileName());
        setStatus(null);
      }).catch(function (err) {
        console.error(err);
        setStatus("STEP export failed: " + (err && err.message ? err.message : err), true);
      }).then(function () {
        updateExportButton();
      });
    }, 0);
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
      // The template cache entry for this footprint was just dropped, so the
      // instances detached here hold the LAST references to its geometry and
      // materials — remove them without disposing and the GPU buffers survive
      // every upload for the life of the page. Instances are `.clone()`s that
      // SHARE the template's buffers, which is why this is only safe where the
      // template is being retired and every instance of it goes in this same
      // synchronous pass (the filter keeps other footprints untouched).
      mount.children.slice().forEach(function (child) {
        if (child.userData.pcb3dKind === "models" && child.userData.pcb3dFootprint === fp) {
          mount.remove(child);
          disposeGroup(child);
        }
      });
      placeModel(mount, part);
    });
    requestRender();
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
    var previousCenter = { x: center.x, y: center.y, z: center.z };
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
    updateExportButton();
    center.x = (bb.minx + bb.maxx) / 2; center.y = (bb.miny + bb.maxy) / 2;
    center.z = -thickness / 2;
    if (axes) axes.position.set(center.x, center.y, center.z);
    if (controls && camera) {
      camera.position.x += center.x - previousCenter.x;
      camera.position.y += center.y - previousCenter.y;
      camera.position.z += center.z - previousCenter.z;
      controls.target.set(center.x, center.y, center.z); controls.update();
    }
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
        DATA.parts, DATA.tracks, DATA.vias, DATA.pours, DATA.zone_fills, DATA.rf_paths,
        DATA.mask_relief, DATA.mask_merges, DATA.texts, DATA.fab_text, DATA.heatsink
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
      if (pose.userData.footprint !== p.fp) {
        var previous = pose.userData.footprint;
        var detached = [];
        mount.children.slice().forEach(function (child) {
          if (child.userData.pcb3dKind === "models") { mount.remove(child); detached.push(child); }
        });
        pose.userData.footprint = p.fp;
        // Invalidate an old async STEP parse before it can land back on this
        // mount. Refresh any other instances that still use that package, then
        // load the replacement body when its refreshed model map has one.
        if (previous && (DATA.models || {})[previous]) {
          refreshModel(previous, DATA.models[previous]);
          // refreshModel retires that footprint's template and rebuilds every
          // remaining instance from a fresh parse, so the bodies detached above
          // are the last holders of the OLD shared buffers and are safe to free.
          // Without that guarantee they are left alone: a `.clone()` shares its
          // template's geometry with every other instance of the same package,
          // and disposing here would blank the parts still showing it.
          detached.forEach(disposeGroup);
        }
        if (p.fp && (DATA.models || {})[p.fp]) placeModel(mount, p);
      }
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
    requestRender();
  }

  // Software WebGL can spend more than 100 ms drawing the full assembly at
  // the CSS viewport's native resolution. Detect it before creating the real
  // renderer so hardware keeps antialiasing and full density, while a
  // software-only machine gets a deliberately lower-resolution interactive
  // preview. The CSS size is unchanged and the idle image returns to at least
  // one backing pixel per CSS pixel after a gesture.
  function hasSoftwareWebGL() {
    var probe = document.createElement("canvas"), gl = null, name = "";
    try {
      gl = probe.getContext("webgl2") || probe.getContext("webgl");
      var info = gl && gl.getExtension("WEBGL_debug_renderer_info");
      name = info ? gl.getParameter(info.UNMASKED_RENDERER_WEBGL) : "";
    } catch (_) {}
    if (gl) {
      var lose = gl.getExtension("WEBGL_lose_context");
      if (lose) lose.loseContext();
    }
    return /swiftshader|llvmpipe|software rasterizer|microsoft basic render/i.test(name);
  }

  // Render only when scene or camera state changes. The previous perpetual
  // loop saturated a software renderer even while the user was reading a
  // panel, delaying unrelated clicks by whole seconds. OrbitControls' change
  // event keeps scheduling frames until its damping tail settles.
  function requestRender() {
    if (!built || !renderer || renderQueued) return;
    renderQueued = true;
    requestAnimationFrame(function () {
      renderQueued = false;
      if (controls) controls.update();
      renderer.render(scene, camera);
    });
  }

  function setPixelRatio(ratio) {
    if (!renderer || renderer.getPixelRatio() === ratio) return;
    renderer.setPixelRatio(ratio);
    resize();
  }

  function beginInteraction() {
    if (restoreQualityTimer) clearTimeout(restoreQualityTimer);
    restoreQualityTimer = null;
    setPixelRatio(interactivePixelRatio);
  }

  function endInteraction() {
    if (restoreQualityTimer) clearTimeout(restoreQualityTimer);
    restoreQualityTimer = setTimeout(function () {
      restoreQualityTimer = null;
      setPixelRatio(idlePixelRatio);
    }, 160);
  }

  // ── Scene build ──────────────────────────────────────────────────
  function build() {
    var PCB = DATA;
    canvas = document.getElementById("pcb-3d-canvas");
    statusEl = document.getElementById("pcb-3d-status");

    softwareRenderer = hasSoftwareWebGL();
    var nativePixelRatio = Math.min(window.devicePixelRatio || 1, 2);
    // A software renderer may cap a high-DPI display at CSS-pixel density, but
    // the settled scene remains crisp. Only an active gesture uses the coarse
    // buffer that keeps orbit/zoom responsive; endInteraction restores 1x.
    idlePixelRatio = softwareRenderer ? Math.min(nativePixelRatio, 1) : nativePixelRatio;
    interactivePixelRatio = softwareRenderer ? Math.min(idlePixelRatio, 0.35) : idlePixelRatio;
    renderer = new THREE.WebGLRenderer({ canvas: canvas, antialias: !softwareRenderer });
    renderer.setPixelRatio(idlePixelRatio);
    scene = new THREE.Scene();
    scene.background = new THREE.Color(0x0d1117);

    camera = new THREE.PerspectiveCamera(45, 1, 0.05, 20000);
    camera.up.set(0, 0, 1);
    controls = new THREE.OrbitControls(camera, renderer.domElement);
    controls.enableDamping = true; controls.dampingFactor = 0.12;
    controls.addEventListener("change", requestRender);
    controls.addEventListener("start", beginInteraction);
    controls.addEventListener("end", endInteraction);

    scene.add(new THREE.AmbientLight(0xffffff, 0.6));
    var key = new THREE.DirectionalLight(0xffffff, 0.85); key.position.set(40, -30, 80); scene.add(key);
    var fill = new THREE.DirectionalLight(0xffffff, 0.4); fill.position.set(-50, 40, 30); scene.add(fill);
    var rim = new THREE.DirectionalLight(0xffffff, 0.3); rim.position.set(0, 0, -60); scene.add(rim);
    axes = buildAxisGizmo(8); scene.add(axes); // labeled +X/+Y/+Z arrows + origin dot

    // The physical board exports as one uniformly green closed body. Browser
    // canvas faces still paint the richer manufacturing appearance above it.
    boardCapMat = new THREE.MeshBasicMaterial({ color: surface.maskColor, visible: false });
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
      pose.userData.footprint = p.fp;
      partGroups.push(pose);
      placeModel(mount, p);
    });
    applyPoses();

    wireControls();
    viewIso();
    resize();
    // The textured board is ready now. Component previews continue to arrive
    // from the STEP worker; the disabled Export button reports that background
    // work without covering or blocking the usable scene.
    setStatus(null);
    requestRender();
  }

  // ── Camera presets + toolbar ─────────────────────────────────────
  function frame(dx, dy, dz) {
    var dir = new THREE.Vector3(dx, dy, dz).normalize();
    var d = span * 1.9;
    var c = new THREE.Vector3(center.x, center.y, center.z);
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
    exportButton = document.getElementById("pcb3d-export-step");
    if (exportButton) exportButton.onclick = exportStep;
    updateExportButton();
    var chk = function (id, fn) { var e = document.getElementById(id); if (e) e.onchange = function (ev) { fn(ev.target.checked); }; };
    chk("pcb3d-t-models", function (v) {
      layerVisible.models = v;
      partsGroup.traverse(function (ch) { if (ch.userData.pcb3dKind === "models") ch.visible = v; });
      requestRender();
    });
    chk("pcb3d-t-surface", function (v) {
      layerVisible.surfaces = v;
      boardGroup.traverse(function (ch) { if (ch.userData.pcb3dKind === "surfaces") ch.visible = v; });
      requestRender();
    });
    chk("pcb3d-t-board", function (v) { boardGroup.visible = v; requestRender(); });
    chk("pcb3d-t-heatsink", function (v) { layerVisible.heatsink = v; heatsinkGroup.visible = v; requestRender(); });
    chk("pcb3d-t-axes", function (v) { axes.visible = v; requestRender(); });
  }

  function resize() {
    if (!canvas) return;
    var w = canvas.clientWidth, h = canvas.clientHeight;
    if (w === 0 || h === 0) return;
    renderer.setSize(w, h, false);
    camera.aspect = w / h; camera.updateProjectionMatrix();
    requestRender();
  }
  window.addEventListener("resize", function () { if (built) resize(); });

  function modelProgress() {
    var models = (DATA && DATA.models) || {}, expected = 0, loaded = 0;
    (DATA && DATA.parts || []).forEach(function (part) { if (models[part.fp]) expected++; });
    if (partsGroup) partsGroup.traverse(function (child) {
      if (child.userData && child.userData.pcb3dKind === "models") loaded++;
    });
    return { expected: expected, loaded: loaded, pending: pendingModels };
  }

  function cameraState() {
    if (!camera || !controls) return null;
    return [camera.position.x, camera.position.y, camera.position.z,
      controls.target.x, controls.target.y, controls.target.z];
  }

  // ── Public entry points (called by the toggle wiring) ────────────
  window.PCB3D = {
    init: function () {
      if (built) return;
      THREE = window.THREE; surface = window.PCB3DSurface;
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
    // loading a specific saved layout updates the 3D preview live. The camera
    // is not re-fit — only the initial build() frames the board. If an outline
    // edit moves the centered datum, the camera translates with it so the
    // user's relative orbit is preserved across loads.
    sync: function () { if (built) applyPoses(); },
    modelAdded: function (fp, transform) { if (fp) refreshModel(fp, transform); },
    modelProgress: modelProgress,
    cameraState: cameraState,
    onShow: function () {
      if (!built) return;
      // Reflect any layout change made in 2D since 3D was last shown, but keep
      // the user's current camera (the "Iso" button re-fits on demand).
      if (sceneSig() !== lastSig) applyPoses();
      resize();
    }
  };
})();
