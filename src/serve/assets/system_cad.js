(function (root) {
  "use strict";

  var RHO_AIR_KG_M3 = 1.184;
  var CP_AIR_J_KGK = 1006;

  function finite(value, fallback) {
    return Number.isFinite(Number(value)) ? Number(value) : fallback;
  }

  function rotatedBounds(width, depth, pose, localX, localY) {
    var angle = finite(pose.rot, finite(pose.rotation, 0)) * Math.PI / 180;
    var c = Math.cos(angle), s = Math.sin(angle);
    var cx = finite(pose.x, 0) + finite(localX, 0) * c - finite(localY, 0) * s;
    var cy = finite(pose.y, 0) + finite(localX, 0) * s + finite(localY, 0) * c;
    var halfW = (Math.abs(width * c) + Math.abs(depth * s)) / 2;
    var halfD = (Math.abs(width * s) + Math.abs(depth * c)) / 2;
    return { minx: cx - halfW, maxx: cx + halfW, miny: cy - halfD, maxy: cy + halfD };
  }

  function overlapFraction(target, source) {
    var width = Math.max(0, Math.min(target.maxx, source.maxx) - Math.max(target.minx, source.minx));
    var depth = Math.max(0, Math.min(target.maxy, source.maxy) - Math.max(target.miny, source.miny));
    var area = Math.max(0, (target.maxx - target.minx) * (target.maxy - target.miny));
    return area > 0 ? width * depth / area : 0;
  }

  function totalBoardPower(thermal) {
    if (!thermal || !Array.isArray(thermal.parts)) return 0;
    return thermal.parts.reduce(function (sum, part) {
      var watts = part && part.power ? Number(part.power.watts) : NaN;
      return sum + (Number.isFinite(watts) && watts > 0 ? watts : 0);
    }, 0);
  }

  function boundedWheelStep(gesture, deltaY, deltaMode, now, pageHeight) {
    var delta = finite(deltaY, 0);
    if (deltaMode === 1) delta *= 16;
    else if (deltaMode === 2) delta *= Math.max(1, finite(pageHeight, 800));
    if (!delta) return 0;
    var direction = Math.sign(delta);
    if (!Number.isFinite(gesture.last) || now - gesture.last > 160 || direction !== Math.sign(gesture.total)) gesture.total = 0;
    gesture.last = now;
    var previous = gesture.total;
    gesture.total = Math.max(-480, Math.min(480, previous + delta));
    return gesture.total - previous;
  }

  var THERMAL_RAMP = [
    [0.00, 0x07, 0x14, 0x38], [0.28, 0x1a, 0x5f, 0xc8],
    [0.52, 0x2f, 0xc4, 0xd6], [0.76, 0xf2, 0xdc, 0x5a], [1.00, 0xe8, 0x40, 0x2a]
  ];

  function rampColor(tempC, minimumC, maximumC) {
    var t = (tempC - minimumC) / Math.max(1e-9, maximumC - minimumC);
    t = Math.max(0, Math.min(1, t));
    for (var i = 1; i < THERMAL_RAMP.length; i += 1) {
      if (t > THERMAL_RAMP[i][0]) continue;
      var a = THERMAL_RAMP[i - 1], b = THERMAL_RAMP[i], f = (t - a[0]) / (b[0] - a[0]);
      return [a[1] + (b[1] - a[1]) * f, a[2] + (b[2] - a[2]) * f, a[3] + (b[3] - a[3]) * f];
    }
    return THERMAL_RAMP[THERMAL_RAMP.length - 1].slice(1);
  }

  function fieldScenario(board, coverage, velocity) {
    var cooling = board.cooling || {};
    if (cooling.heatsink) return cooling.fan && coverage >= 0.25 ? "fan_heatsink" : "heatsink";
    if (velocity >= 1.5) return "airflow_2ms";
    if (velocity >= 0.25) return "airflow_1ms";
    return "natural";
  }

  function fieldTemperatureAt(field, board, row, localX, localY) {
    var grid = field && field.grid;
    if (!grid || !grid.cols || !grid.rows || !(grid.cell_mm > 0)) return null;
    var center = board.source_center || [0, 0];
    var gx = (localX + center[0] - grid.origin_x_mm) / grid.cell_mm - 0.5;
    var gy = (localY + center[1] - grid.origin_y_mm) / grid.cell_mm - 0.5;
    if (gx < -0.5 || gy < -0.5 || gx > grid.cols - 0.5 || gy > grid.rows - 0.5) return null;
    gx = Math.max(0, Math.min(grid.cols - 1, gx)); gy = Math.max(0, Math.min(grid.rows - 1, gy));
    var x0 = Math.floor(gx), y0 = Math.floor(gy), x1 = Math.min(x0 + 1, grid.cols - 1), y1 = Math.min(y0 + 1, grid.rows - 1);
    var fx = gx - x0, fy = gy - y0, weighted = 0, total = 0;
    [[x0, y0, (1 - fx) * (1 - fy)], [x1, y0, fx * (1 - fy)], [x0, y1, (1 - fx) * fy], [x1, y1, fx * fy]].forEach(function (sample) {
      var index = sample[1] * grid.cols + sample[0], rise = Number(grid.rise_c[index]);
      if ((grid.active && !grid.active[index]) || !Number.isFinite(rise)) return;
      weighted += rise * sample[2]; total += sample[2];
    });
    if (!total) return null;
    var peak = field.hotspot && finite(field.hotspot.c, NaN);
    var shift = row && row.temperature_c != null && Number.isFinite(peak) ? row.temperature_c - peak : 0;
    return finite(field.ambient_c, 25) + weighted / total + shift;
  }

  function scenario(thermal, name) {
    if (!thermal || !Array.isArray(thermal.scenarios)) return null;
    return thermal.scenarios.find(function (row) { return row.scenario === name && row.converged !== false; }) || null;
  }

  function riseForVelocity(thermal, velocity) {
    var ambient = finite(thermal && thermal.ambient_c, 25);
    var still = scenario(thermal, "natural");
    var one = scenario(thermal, "airflow_1ms") || still;
    var two = scenario(thermal, "airflow_2ms") || one;
    if (!still) return null;
    var r0 = finite(still.board_max_c, ambient) - ambient;
    var r1 = finite(one.board_max_c, ambient + r0) - ambient;
    var r2 = finite(two.board_max_c, ambient + r1) - ambient;
    if (velocity <= 1) return r0 + (r1 - r0) * Math.max(0, velocity);
    return r1 + (r2 - r1) * Math.min(1, velocity - 1);
  }

  function boardRise(board, coverage, velocity) {
    var thermal = board.thermal;
    if (!thermal) return null;
    var ambient = finite(thermal.ambient_c, 25);
    var sink = scenario(thermal, "heatsink");
    var combined = scenario(thermal, "fan_heatsink");
    if (board.cooling && board.cooling.heatsink && sink) {
      var sinkRise = finite(sink.board_max_c, ambient) - ambient;
      if (!combined) return sinkRise;
      var combinedRise = finite(combined.board_max_c, ambient + sinkRise) - ambient;
      return sinkRise + (combinedRise - sinkRise) * Math.min(1, coverage);
    }
    return riseForVelocity(thermal, velocity);
  }

  function solveSystem(boardDefinitions, instances, ambientC) {
    var boardByName = {};
    boardDefinitions.forEach(function (board) { boardByName[board.name] = board; });
    var active = instances.filter(function (instance) { return instance.on !== false && boardByName[instance.board]; });
    var fans = [];
    active.forEach(function (instance) {
      var board = boardByName[instance.board], fan = board.cooling && board.cooling.fan;
      if (!fan) return;
      var flow = Math.max(0, finite(fan.flow_m3_s, 0) * finite(fan.operating_fraction, 1));
      fans.push({
        owner: instance.id,
        bounds: rotatedBounds(fan.w, fan.d, instance, fan.x, fan.y),
        flow: flow,
        velocity: flow / Math.max(1e-9, fan.w * fan.d / 1e6)
      });
    });
    var totalFlow = fans.reduce(function (sum, fan) { return sum + fan.flow; }, 0);
    var totalWatts = active.reduce(function (sum, instance) { return sum + totalBoardPower(boardByName[instance.board].thermal); }, 0);
    var outletRise = totalFlow > 0 ? totalWatts / (RHO_AIR_KG_M3 * CP_AIR_J_KGK * totalFlow) : null;
    var results = active.map(function (instance) {
      var board = boardByName[instance.board];
      var bounds = rotatedBounds(board.width, board.depth, instance, 0, 0);
      var coverage = 0, velocity = 0;
      fans.forEach(function (fan) {
        var overlap = overlapFraction(bounds, fan.bounds);
        coverage = Math.min(1, coverage + overlap);
        velocity += overlap * fan.velocity;
      });
      var rise = boardRise(board, coverage, velocity);
      return {
        id: instance.id, board: instance.board, watts: totalBoardPower(board.thermal), coverage: coverage, velocity: velocity,
        field_scenario: fieldScenario(board, coverage, velocity),
        temperature_c: rise == null ? null : ambientC + rise + (outletRise == null ? 0 : outletRise / 2)
      };
    });
    var hottest = results.reduce(function (best, row) {
      if (row.temperature_c == null) return best;
      return !best || row.temperature_c > best.temperature_c ? row : best;
    }, null);
    return { total_watts: totalWatts, total_flow_m3_s: totalFlow, outlet_rise_c: outletRise, hottest: hottest, instances: results };
  }

  function enabledExtrusionCount(value) {
    return value && Array.isArray(value.extrusions) ? value.extrusions.filter(function (extrusion) { return extrusion && extrusion.enabled !== false; }).length : 0;
  }

  function sketchWorldPoint(plane, offset, u, v, normal) {
    offset = finite(offset, 0); normal = finite(normal, 0);
    if (plane === "xz") return [u, offset - normal, v];
    if (plane === "yz") return [offset + normal, u, v];
    return [u, v, offset + normal];
  }

  var API = { rotatedBounds: rotatedBounds, overlapFraction: overlapFraction, totalBoardPower: totalBoardPower, boundedWheelStep: boundedWheelStep, rampColor: rampColor, fieldScenario: fieldScenario, fieldTemperatureAt: fieldTemperatureAt, solveSystem: solveSystem, enabledExtrusionCount: enabledExtrusionCount, sketchWorldPoint: sketchWorldPoint };
  if (typeof module !== "undefined" && module.exports) module.exports = API;
  root.SystemThermal = API;
  if (!root.document || !root.CAD_DATA) return;

  var D = root.CAD_DATA, OS = root.PCBShapeSketch;
  var $ = function (selector) { return document.querySelector(selector); };
  var storeKey = "netlisp-system-cad-v2:" + D.system;
  var documentUrl = "/api/systems/" + encodeURIComponent(D.system) + "/cad/document";
  var usable = D.boards.filter(function (board) { return !board.error && board.outline && board.outline.length >= 3; });
  var boardByName = {};
  usable.forEach(function (board) { boardByName[board.name] = board; });

  $("#title").textContent = D.title + " · System Thermal";
  $("#identity").textContent = D.part_number + " · revision " + D.revision;
  $("#back").href = "/systems/" + encodeURIComponent(D.system);

  function defaultInstances() {
    if (D.assembly && Array.isArray(D.assembly.instances)) {
      return D.assembly.instances.filter(function (instance) { return boardByName[instance.board]; }).map(function (instance) {
        return { id: instance.id, board: instance.board, on: instance.on !== false, x: finite(instance.x, 0), y: finite(instance.y, 0), z: finite(instance.z, 5), rot: finite(instance.rot, 0) };
      });
    }
    return usable.map(function (board, index) { return { id: board.name, board: board.name, on: true, x: 0, y: 0, z: 5 + index * 14, rot: 0 }; });
  }

  var defaults = {
    version: 2,
    ambient: finite(D.assembly && D.assembly.ambient_c, 25),
    pitch: finite(D.assembly && D.assembly.pitch_mm, 22),
    scaleMin: 25, scaleMax: 125,
    snap: true,
    instances: defaultInstances(), sketches: [], extrusions: []
  };
  var saved = null;
  try { saved = JSON.parse(localStorage.getItem(storeKey) || "null"); } catch (_) {}
  var state = Object.assign({}, defaults, saved && saved.version === 2 ? saved : {});
  state.instances = defaults.instances.map(function (base) {
    var prior = saved && saved.version === 2 && Array.isArray(saved.instances) ? saved.instances.find(function (value) { return value.id === base.id && value.board === base.board; }) : null;
    return Object.assign({}, base, prior || {});
  });
  state.sketches = Array.isArray(state.sketches) ? state.sketches : [];
  state.extrusions = Array.isArray(state.extrusions) ? state.extrusions : [];
  state.sketches.forEach(function (sketch) { sketch.plane = sketch.plane || "xy"; });
  var dirty = !!(saved && saved.version === 2), activeSketchId = null, selectedPlane = "xy", editMode = false, sketchTool = "select";
  var sketchSelection = [], linePoints = [], lineCursor = null, rectangleStart = null, rectangleCurrent = null, sketchGesture = null;
  var undoBySketch = {}, redoBySketch = {}, orthoHalf = 50;

  function clone(value) { return JSON.parse(JSON.stringify(value)); }
  function status(message, isError) { var node = $("#save-status"); node.textContent = message || ""; node.className = isError ? "error" : ""; }
  function persist() { try { localStorage.setItem(storeKey, JSON.stringify(state)); } catch (_) {} }
  function setDirty() { dirty = true; status(D.can_write ? "Unsaved changes" : "Local draft"); persist(); }
  function nextId(prefix, rows) {
    var n = 1;
    while (rows.some(function (row) { return row.id === prefix + "-" + n; })) n += 1;
    return prefix + "-" + n;
  }
  function activeSketch() { return state.sketches.find(function (sketch) { return sketch.id === activeSketchId; }) || null; }
  function sketchPlane(value) { return value === "xz" || value === "yz" ? value : "xy"; }
  function hydrateSketch(geometry) {
    var result = clone(geometry);
    (result.constraints || []).forEach(function (constraint) {
      constraint.enabled = constraint.mode !== "disabled";
      constraint.driving = constraint.mode !== "reference" && constraint.mode !== "disabled";
      delete constraint.mode;
    });
    return result;
  }
  function serializeSketch(geometry) {
    return {
      version: geometry.version,
      points: (geometry.points || []).map(function (point) { var out = { id: point.id, x: point.x, y: point.y }; if (point.construction) out.construction = true; return out; }),
      curves: (geometry.curves || []).map(function (curve) { var out = { id: curve.id, kind: curve.kind, a: curve.a, b: curve.b }; if (curve.mid) out.mid = curve.mid.slice(); if (curve.construction) out.construction = true; return out; }),
      constraints: (geometry.constraints || []).map(function (constraint) {
        var out = { id: constraint.id, kind: constraint.kind, a: constraint.a, mode: constraint.enabled === false ? "disabled" : constraint.driving === false ? "reference" : "driving" };
        ["b", "c", "value"].forEach(function (key) { if (constraint[key] != null) out[key] = constraint[key]; });
        return out;
      })
    };
  }
  function mechanicalDocument() {
    return {
      schema: "netlisp-mechanical-v2",
      boards: state.instances.map(function (pose) { return { name: pose.id, enabled: pose.on, x: pose.x, y: pose.y, z: pose.z, rotation: pose.rot }; }),
      sketches: state.sketches.map(function (sketch) { return { id: sketch.id, name: sketch.name, plane: sketchPlane(sketch.plane), plane_z: sketch.plane_z, geometry: serializeSketch(sketch.geometry) }; }),
      extrusions: clone(state.extrusions)
    };
  }
  function applyMechanical(documentValue) {
    if (!documentValue || documentValue.schema !== "netlisp-mechanical-v2") return;
    state.instances.forEach(function (pose) {
      var stored = (documentValue.boards || []).find(function (board) { return board.name === pose.id; });
      if (!stored) return;
      pose.on = stored.enabled !== false; pose.x = finite(stored.x, pose.x); pose.y = finite(stored.y, pose.y); pose.z = finite(stored.z, pose.z); pose.rot = finite(stored.rotation, pose.rot);
    });
    state.sketches = (documentValue.sketches || []).map(function (sketch) { return { id: sketch.id, name: sketch.name, plane: sketchPlane(sketch.plane), plane_z: finite(sketch.plane_z, 0), geometry: hydrateSketch(sketch.geometry) }; });
    state.extrusions = clone(documentValue.extrusions || []);
  }

  ["ambient", "pitch"].forEach(function (key) { $("#" + key).value = state[key]; });
  $("#snap").checked = state.snap !== false;
  var cards = {}, boardHost = $("#boards");
  state.instances.forEach(function (pose) {
    var board = boardByName[pose.board], item = document.createElement("div");
    item.className = "board"; item.dataset.instance = pose.id;
    item.innerHTML = '<div class="board-head"><input class="enabled" type="checkbox"><strong></strong><span class="temp">—</span><a target="_blank" rel="noopener">Open PCB ↗</a></div><div class="board-meta"></div><div class="pose"></div>';
    item.querySelector("strong").textContent = pose.id;
    item.querySelector(".board-meta").textContent = board.name + " · " + board.role + " · " + board.width.toFixed(1) + " × " + board.depth.toFixed(1) + " mm";
    item.querySelector("a").href = "/pcb-layout/" + encodeURIComponent(board.name) + "?view=3d&layout=" + encodeURIComponent(board.layout);
    item.querySelector(".enabled").checked = pose.on;
    [["x", "X"], ["y", "Y"], ["z", "Z"], ["rot", "Rot°"]].forEach(function (pair) {
      var label = document.createElement("label"), input = document.createElement("input");
      label.textContent = pair[1]; input.type = "number"; input.step = pair[0] === "rot" ? "5" : "0.5"; input.value = pose[pair[0]]; input.dataset.key = pair[0];
      label.appendChild(input); item.querySelector(".pose").appendChild(label);
    });
    boardHost.appendChild(item); cards[pose.id] = item;
  });
  D.boards.filter(function (board) { return board.error; }).forEach(function (board) {
    var item = document.createElement("div"); item.className = "board board-error"; item.textContent = board.name + ": could not import " + board.layout + " (" + board.error + ")"; boardHost.appendChild(item);
  });
  if (!usable.length) { $("#empty").style.display = "block"; $("#empty").textContent = "No saved PCB layouts could be imported; the CAD work plane is still available."; }

  var canvas = $("#canvas"), thermalCanvas = $("#thermal-canvas"), thermalContext = thermalCanvas.getContext("2d");
  var renderer = new THREE.WebGLRenderer({ canvas: canvas, antialias: true, alpha: true });
  renderer.setPixelRatio(Math.min(devicePixelRatio || 1, 2)); renderer.outputEncoding = THREE.sRGBEncoding;
  var scene = new THREE.Scene(), camera = new THREE.PerspectiveCamera(38, 1, 0.1, 5000);
  var orthoCamera = new THREE.OrthographicCamera(-50, 50, 50, -50, 0.1, 5000), activeCamera = camera;
  camera.up.set(0, 0, 1); camera.position.set(180, -210, 150);
  var controls = new THREE.OrbitControls(camera, canvas); controls.enableDamping = true; controls.dampingFactor = 0.08; controls.target.set(0, 0, 10);
  var wheelGesture = { last: -Infinity, total: 0 };
  scene.add(new THREE.HemisphereLight(0xd8e9ff, 0x182338, 1.25));
  var sun = new THREE.DirectionalLight(0xffffff, 0.85); sun.position.set(-80, -100, 160); scene.add(sun);
  var grid = new THREE.GridHelper(500, 50, 0x35506f, 0x23354d); grid.rotation.x = Math.PI / 2; grid.position.z = -0.02; scene.add(grid);
  var boardsModel = new THREE.Group(), solidModel = new THREE.Group(), sketchModel = new THREE.Group(), originModel = new THREE.Group(), editGrid = new THREE.Group();
  scene.add(boardsModel); scene.add(solidModel); scene.add(sketchModel); scene.add(originModel); scene.add(editGrid);
  var lastBounds = { width: 80, depth: 60 }, thermalResult = null, thermalLoading = true, groupsById = {}, meshSequence = 0;
  var viewMode = "2d", twoView = { centerX: 0, centerY: 0, scale: 1 }, twoDirty = true;
  var thermalFields = {}, fieldPromises = {}, fieldRasters = {}, selected2d = null;

  var PLANE = {
    xy: { u: new THREE.Vector3(1, 0, 0), v: new THREE.Vector3(0, 1, 0), n: new THREE.Vector3(0, 0, 1), color: 0x4f8cff, label: "XY" },
    xz: { u: new THREE.Vector3(1, 0, 0), v: new THREE.Vector3(0, 0, 1), n: new THREE.Vector3(0, -1, 0), color: 0x59c878, label: "XZ" },
    yz: { u: new THREE.Vector3(0, 1, 0), v: new THREE.Vector3(0, 0, 1), n: new THREE.Vector3(1, 0, 0), color: 0xf16b6b, label: "YZ" }
  };
  var datumPlanes = [];

  function planeBasis(sketchOrName) { return PLANE[sketchPlane(typeof sketchOrName === "string" ? sketchOrName : sketchOrName && sketchOrName.plane)]; }
  function localToWorld(sketch, x, y, normal) {
    var point = sketchWorldPoint(sketchPlane(sketch && sketch.plane), sketch && sketch.plane_z, x, y, normal); return new THREE.Vector3(point[0], point[1], point[2]);
  }
  function worldToLocal(sketch, point) {
    var basis = planeBasis(sketch), origin = localToWorld(sketch, 0, 0, 0), delta = point.clone().sub(origin);
    return { x: delta.dot(basis.u), y: delta.dot(basis.v) };
  }
  function sketchPlane3(sketch) { var basis = planeBasis(sketch), origin = localToWorld(sketch, 0, 0, 0); return new THREE.Plane(basis.n, -basis.n.dot(origin)); }

  function material(color, opacity) { return new THREE.MeshStandardMaterial({ color: color, roughness: 0.72, metalness: 0.04, transparent: opacity < 1, opacity: opacity, side: THREE.DoubleSide, depthWrite: opacity > 0.7 }); }
  function box(group, width, depth, height, x, y, z, mat) { var mesh = new THREE.Mesh(new THREE.BoxGeometry(width, depth, height), mat); mesh.position.set(x, y, z); group.add(mesh); return mesh; }
  function clearGroup(group) {
    while (group.children.length) {
      var object = group.children[group.children.length - 1]; group.remove(object);
      object.traverse(function (child) { if (child.geometry) child.geometry.dispose(); if (child.material) (Array.isArray(child.material) ? child.material : [child.material]).forEach(function (mat) { mat.dispose(); }); });
    }
  }
  function lineObject(points, color, opacity) {
    return new THREE.Line(new THREE.BufferGeometry().setFromPoints(points), new THREE.LineBasicMaterial({ color: color, transparent: opacity < 1, opacity: opacity, depthTest: opacity >= 1 }));
  }
  function buildOriginMarker() {
    [[new THREE.Vector3(-32, 0, 0), new THREE.Vector3(32, 0, 0), 0xf16b6b], [new THREE.Vector3(0, -32, 0), new THREE.Vector3(0, 32, 0), 0x59c878], [new THREE.Vector3(0, 0, -32), new THREE.Vector3(0, 0, 32), 0x4f8cff]].forEach(function (axis) {
      var line = lineObject([axis[0], axis[1]], axis[2], 1); line.renderOrder = 8; originModel.add(line);
    });
    Object.keys(PLANE).forEach(function (name) {
      var sketch = { plane: name, plane_z: 0 }, corners = [[-12, -12], [12, -12], [12, 12], [-12, -12], [12, 12], [-12, 12]], positions = [];
      corners.forEach(function (point) { var world = localToWorld(sketch, point[0], point[1], 0); positions.push(world.x, world.y, world.z); });
      var geometry = new THREE.BufferGeometry(); geometry.setAttribute("position", new THREE.Float32BufferAttribute(positions, 3));
      var mesh = new THREE.Mesh(geometry, new THREE.MeshBasicMaterial({ color: PLANE[name].color, transparent: true, opacity: 0.11, side: THREE.DoubleSide, depthWrite: false }));
      mesh.userData.datumPlane = name; mesh.renderOrder = 2; originModel.add(mesh); datumPlanes.push(mesh);
    });
    var origin = new THREE.Mesh(new THREE.SphereGeometry(1.3, 16, 12), new THREE.MeshBasicMaterial({ color: 0xffffff, depthTest: false })); origin.renderOrder = 9; originModel.add(origin);
  }
  function selectPlane(name) {
    if (editMode) return;
    selectedPlane = sketchPlane(name);
    datumPlanes.forEach(function (mesh) { var active = mesh.userData.datumPlane === selectedPlane; mesh.material.opacity = active ? 0.34 : 0.11; mesh.material.color.setHex(active ? 0xffcf66 : PLANE[mesh.userData.datumPlane].color); });
    document.querySelectorAll("#plane-choices [data-plane]").forEach(function (button) { button.classList.toggle("on", button.dataset.plane === selectedPlane); });
    $("#plane-status").textContent = PLANE[selectedPlane].label + " plane selected · New sketch will use this plane";
  }
  buildOriginMarker(); selectPlane("xy");
  function poseFor(id) { return state.instances.find(function (pose) { return pose.id === id; }); }
  function resultFor(id) { return thermalResult && thermalResult.instances.find(function (row) { return row.id === id; }); }
  function temperatureColor(row) { if (!row || row.temperature_c == null) return 0x2f8f70; var rise = row.temperature_c - state.ambient; return rise < 18 ? 0x22a879 : rise < 40 ? 0xe0a93b : 0xdf5b57; }
  function attachCooling(group, board) {
    var sink = board.cooling && board.cooling.heatsink, fan = board.cooling && board.cooling.fan;
    if (sink) {
      var down = sink.side === "bottom" ? -1 : 1, sinkZ = down < 0 ? -sink.pad_mm - sink.base_mm / 2 : board.thickness + sink.pad_mm + sink.base_mm / 2;
      box(group, sink.w, sink.d, sink.base_mm, sink.x, sink.y, sinkZ, material(0x8e9ba9, 0.88));
      if (sink.shape === "stepped") {
        var lowerZ = down < 0 ? -sink.pad_mm - sink.base_mm - sink.lower_h / 2 : board.thickness + sink.pad_mm + sink.base_mm + sink.lower_h / 2;
        box(group, sink.lower_w, sink.lower_d, sink.lower_h, sink.x, sink.y, lowerZ, material(0x7f8b99, 0.72));
      }
    }
    if (fan) {
      var fanDown = fan.side === "bottom" ? -1 : 1, fanZ = fanDown < 0 ? -fan.distance_mm - 2 : board.thickness + fan.distance_mm + 2;
      var frame = material(0x313843, 0.95), flow = material(0x62a5ff, 0.18), rim = 5, thick = 4;
      box(group, fan.w, rim, thick, fan.x, fan.y - (fan.d - rim) / 2, fanZ, frame); box(group, fan.w, rim, thick, fan.x, fan.y + (fan.d - rim) / 2, fanZ, frame);
      box(group, rim, fan.d - 2 * rim, thick, fan.x - (fan.w - rim) / 2, fan.y, fanZ, frame); box(group, rim, fan.d - 2 * rim, thick, fan.x + (fan.w - rim) / 2, fan.y, fanZ, frame);
      box(group, Math.max(1, fan.w - 2 * rim), Math.max(1, fan.d - 2 * rim), 0.4, fan.x, fan.y, fanZ, flow);
    }
  }
  function drawBoard(board, pose) {
    var group = new THREE.Group(), shape = new THREE.Shape(), points = board.outline, row = resultFor(pose.id);
    shape.moveTo(points[0][0], points[0][1]); for (var i = 1; i < points.length; i++) shape.lineTo(points[i][0], points[i][1]); shape.closePath();
    var boardMesh = new THREE.Mesh(new THREE.ExtrudeGeometry(shape, { depth: board.thickness, bevelEnabled: false }), material(temperatureColor(row), 1));
    boardMesh.userData.instanceId = pose.id; boardMesh.userData.draggable = true; group.add(boardMesh);
    var compMat = material(0xbec6cf, 1);
    board.parts.forEach(function (part) { var height = part.bottom ? 1.2 : 2.2, z = part.bottom ? -height / 2 : board.thickness + height / 2; var mesh = box(group, part.w, part.d, height, part.x, part.y, z, compMat); mesh.rotation.z = part.rot * Math.PI / 180; });
    attachCooling(group, board); group.position.set(pose.x, pose.y, pose.z); group.rotation.z = pose.rot * Math.PI / 180; boardsModel.add(group); groupsById[pose.id] = group;
  }

  function fieldKey(board, scenarioName) { return board.name + "\n" + scenarioName; }
  function requestField(board, scenarioName) {
    var key = fieldKey(board, scenarioName);
    if (Object.prototype.hasOwnProperty.call(thermalFields, key) || fieldPromises[key]) return;
    var query = new URLSearchParams({ ambient: "25", scenario: scenarioName });
    if (board.layout !== "blessed") query.set("layout", board.layout);
    fieldPromises[key] = fetch("/api/thermal-field/" + encodeURIComponent(board.name) + "?" + query).then(function (response) {
      if (!response.ok) throw new Error("thermal field " + response.status);
      return response.json();
    }).then(function (field) {
      thermalFields[key] = field && field.available ? field : null;
    }).catch(function () { thermalFields[key] = null; }).finally(function () {
      delete fieldPromises[key]; twoDirty = true;
    });
  }
  function requestVisibleFields() {
    if (!thermalResult) return;
    thermalResult.instances.forEach(function (row) {
      var board = boardByName[row.board]; if (board) requestField(board, row.field_scenario);
    });
  }
  function rasterFor(board, row) {
    var key = fieldKey(board, row.field_scenario), field = thermalFields[key];
    if (!field || !field.grid) return null;
    var cacheKey = key + "\n" + Number(row.temperature_c).toFixed(3) + "\n" + state.scaleMin + "\n" + state.scaleMax;
    if (fieldRasters[cacheKey]) return { canvas: fieldRasters[cacheKey], field: field };
    var grid = field.grid, output = document.createElement("canvas"); output.width = grid.cols; output.height = grid.rows;
    var context = output.getContext("2d"), image = context.createImageData(grid.cols, grid.rows);
    var peak = field.hotspot && finite(field.hotspot.c, NaN);
    var shift = row.temperature_c != null && Number.isFinite(peak) ? row.temperature_c - peak : 0;
    for (var i = 0; i < grid.cols * grid.rows; i += 1) {
      var active = !grid.active || grid.active[i], rise = Number(grid.rise_c[i]);
      if (!active || !Number.isFinite(rise)) { image.data[i * 4 + 3] = 0; continue; }
      var color = rampColor(finite(field.ambient_c, 25) + rise + shift, state.scaleMin, state.scaleMax);
      image.data[i * 4] = color[0]; image.data[i * 4 + 1] = color[1]; image.data[i * 4 + 2] = color[2]; image.data[i * 4 + 3] = 245;
    }
    context.putImageData(image, 0, 0); fieldRasters[cacheKey] = output; return { canvas: output, field: field };
  }
  function localPoint(pose, x, y) {
    var angle = pose.rot * Math.PI / 180, c = Math.cos(angle), s = Math.sin(angle), dx = x - pose.x, dy = y - pose.y;
    return { x: dx * c + dy * s, y: -dx * s + dy * c };
  }
  function pointInOutline(points, x, y) {
    var inside = false;
    for (var i = 0, j = points.length - 1; i < points.length; j = i++) {
      var a = points[i], b = points[j];
      if ((a[1] > y) !== (b[1] > y) && x < (b[0] - a[0]) * (y - a[1]) / (b[1] - a[1]) + a[0]) inside = !inside;
    }
    return inside;
  }
  function instanceAt(x, y) {
    for (var i = state.instances.length - 1; i >= 0; i -= 1) {
      var pose = state.instances[i], board = boardByName[pose.board]; if (!pose.on || !board) continue;
      var local = localPoint(pose, x, y); if (pointInOutline(board.outline, local.x, local.y)) return { pose: pose, board: board, local: local };
    }
    return null;
  }
  function worldTransform(pose) {
    var angle = pose.rot * Math.PI / 180, c = Math.cos(angle), s = Math.sin(angle), scale = twoView.scale;
    thermalContext.setTransform(scale * c, scale * s, -scale * s, scale * c,
      thermalCanvas.width / 2 + (pose.x - twoView.centerX) * scale,
      thermalCanvas.height / 2 + (pose.y - twoView.centerY) * scale);
  }
  function outlinePath(points) {
    thermalContext.beginPath(); thermalContext.moveTo(points[0][0], points[0][1]);
    for (var i = 1; i < points.length; i += 1) thermalContext.lineTo(points[i][0], points[i][1]);
    thermalContext.closePath();
  }
  function drawCooling2d(board) {
    var cooling = board.cooling || {}, sink = cooling.heatsink, fan = cooling.fan;
    if (sink) {
      var sw = sink.shape === "stepped" ? sink.lower_w : sink.w, sd = sink.shape === "stepped" ? sink.lower_d : sink.d;
      thermalContext.fillStyle = "rgba(185,196,210,.10)"; thermalContext.strokeStyle = "rgba(210,220,232,.75)";
      thermalContext.setLineDash([3 / twoView.scale, 2 / twoView.scale]); thermalContext.fillRect(sink.x - sw / 2, sink.y - sd / 2, sw, sd); thermalContext.strokeRect(sink.x - sw / 2, sink.y - sd / 2, sw, sd); thermalContext.setLineDash([]);
    }
    if (fan) {
      thermalContext.fillStyle = "rgba(98,165,255,.12)"; thermalContext.strokeStyle = "rgba(98,165,255,.95)";
      thermalContext.fillRect(fan.x - fan.w / 2, fan.y - fan.d / 2, fan.w, fan.d); thermalContext.strokeRect(fan.x - fan.w / 2, fan.y - fan.d / 2, fan.w, fan.d);
    }
  }
  function drawBoard2d(board, pose) {
    var row = resultFor(pose.id), raster = row && rasterFor(board, row), center = board.source_center || [0, 0];
    thermalContext.save(); worldTransform(pose); thermalContext.lineWidth = (selected2d === pose.id ? 2.5 : 1.2) / twoView.scale;
    outlinePath(board.outline);
    var baseColor = row && row.temperature_c != null ? rampColor(row.temperature_c, state.scaleMin, state.scaleMax) : [36, 75, 91];
    thermalContext.fillStyle = "rgb(" + baseColor.map(Math.round).join(",") + ")"; thermalContext.fill();
    if (raster) {
      thermalContext.save(); outlinePath(board.outline); thermalContext.clip(); thermalContext.imageSmoothingEnabled = true;
      thermalContext.drawImage(raster.canvas, raster.field.grid.origin_x_mm - center[0], raster.field.grid.origin_y_mm - center[1], raster.field.grid.cols * raster.field.grid.cell_mm, raster.field.grid.rows * raster.field.grid.cell_mm); thermalContext.restore();
    }
    thermalContext.strokeStyle = selected2d === pose.id ? "#ffffff" : "rgba(225,236,249,.78)"; outlinePath(board.outline); thermalContext.stroke();
    thermalContext.strokeStyle = "rgba(255,255,255,.28)"; thermalContext.lineWidth = 0.65 / twoView.scale;
    board.parts.forEach(function (part) {
      thermalContext.save(); thermalContext.translate(part.x, part.y); thermalContext.rotate(part.rot * Math.PI / 180);
      thermalContext.strokeRect(-part.w / 2, -part.d / 2, part.w, part.d); thermalContext.restore();
    });
    drawCooling2d(board);
    if (raster && raster.field.hotspot) {
      var hx = raster.field.hotspot.x_mm - center[0], hy = raster.field.hotspot.y_mm - center[1];
      thermalContext.strokeStyle = "rgba(255,255,255,.9)"; thermalContext.lineWidth = 1 / twoView.scale;
      thermalContext.beginPath(); thermalContext.arc(hx, hy, 2.4 / twoView.scale, 0, Math.PI * 2); thermalContext.stroke();
    }
    thermalContext.restore();
    var sx = thermalCanvas.width / 2 + (pose.x - twoView.centerX) * twoView.scale;
    var sy = thermalCanvas.height / 2 + (pose.y - twoView.centerY) * twoView.scale;
    thermalContext.save(); thermalContext.font = "600 11px system-ui,sans-serif"; thermalContext.textAlign = "center"; thermalContext.textBaseline = "middle";
    var label = pose.id + (row && row.temperature_c != null ? "  " + row.temperature_c.toFixed(1) + " °C" : "");
    var labelWidth = thermalContext.measureText(label).width + 10; thermalContext.fillStyle = "rgba(5,10,18,.82)";
    thermalContext.fillRect(sx - labelWidth / 2, sy - 10, labelWidth, 20); thermalContext.fillStyle = "#f4f7fb"; thermalContext.fillText(label, sx, sy); thermalContext.restore();
  }
  function draw2d() {
    var width = thermalCanvas.width, height = thermalCanvas.height, scale = twoView.scale;
    thermalContext.setTransform(1, 0, 0, 1, 0, 0); thermalContext.clearRect(0, 0, width, height);
    thermalContext.fillStyle = "#0a101b"; thermalContext.fillRect(0, 0, width, height);
    var step = Math.max(1, state.pitch), minX = twoView.centerX - width / (2 * scale), maxX = twoView.centerX + width / (2 * scale);
    var minY = twoView.centerY - height / (2 * scale), maxY = twoView.centerY + height / (2 * scale);
    thermalContext.strokeStyle = "rgba(75,108,145,.20)"; thermalContext.lineWidth = 1; thermalContext.beginPath();
    for (var x = Math.ceil(minX / step) * step; x <= maxX; x += step) {
      var px = width / 2 + (x - twoView.centerX) * scale; thermalContext.moveTo(px, 0); thermalContext.lineTo(px, height);
    }
    for (var y = Math.ceil(minY / step) * step; y <= maxY; y += step) {
      var py = height / 2 + (y - twoView.centerY) * scale; thermalContext.moveTo(0, py); thermalContext.lineTo(width, py);
    }
    thermalContext.stroke();
    state.instances.forEach(function (pose) { var board = boardByName[pose.board]; if (board && pose.on) drawBoard2d(board, pose); });
    if (Object.keys(fieldPromises).length) {
      thermalContext.fillStyle = "rgba(8,12,18,.78)"; thermalContext.fillRect(14, 14, 148, 28);
      thermalContext.fillStyle = "#cbd6e5"; thermalContext.font = "12px system-ui,sans-serif"; thermalContext.fillText("Loading heat fields…", 25, 33);
    }
    twoDirty = false;
  }
  function occupied() {
    var minx = Infinity, miny = Infinity, maxx = -Infinity, maxy = -Infinity;
    state.instances.forEach(function (pose) { var board = boardByName[pose.board]; if (!board || !pose.on) return; var bounds = rotatedBounds(board.width, board.depth, pose, 0, 0); minx = Math.min(minx, bounds.minx); maxx = Math.max(maxx, bounds.maxx); miny = Math.min(miny, bounds.miny); maxy = Math.max(maxy, bounds.maxy); });
    state.sketches.forEach(function (sketch) { var compiled = OS && OS.compile(sketch.geometry); if (!compiled || !compiled.rect) return; minx = Math.min(minx, compiled.rect.x); maxx = Math.max(maxx, compiled.rect.x + compiled.rect.w); miny = Math.min(miny, compiled.rect.y); maxy = Math.max(maxy, compiled.rect.y + compiled.rect.h); });
    if (!isFinite(minx)) return { width: 80, depth: 60 };
    return { width: Math.max(1, 2 * Math.max(Math.abs(minx), Math.abs(maxx))), depth: Math.max(1, 2 * Math.max(Math.abs(miny), Math.abs(maxy))) };
  }
  function kernelMesh(recipe, mat) {
    var positions = [];
    recipe.triangles.forEach(function (triangle) { triangle.forEach(function (index) { var point = recipe.points[index]; positions.push(point[0], point[1], point[2]); }); });
    var geometry = new THREE.BufferGeometry(); geometry.setAttribute("position", new THREE.Float32BufferAttribute(positions, 3)); geometry.computeVertexNormals(); return new THREE.Mesh(geometry, mat);
  }
  function selectedEntity(type, id) { return sketchSelection.some(function (row) { return row.type === type && row.id === id; }); }
  function curveLocalPoints(sketch, curve) {
    var a = OS.point(sketch.geometry, curve.a), b = OS.point(sketch.geometry, curve.b); if (!a || !b) return [];
    if (curve.kind !== "arc") return [[a.x, a.y], [b.x, b.y]];
    var arc = OS.arcCircle(sketch.geometry, curve); if (!arc) return [[a.x, a.y], [b.x, b.y]];
    var count = Math.max(8, Math.min(96, Math.ceil(Math.abs(arc.sweep) * Math.sqrt(Math.max(arc.r, 1)) * 2))), points = [];
    for (var i = 0; i <= count; i += 1) { var angle = arc.start + arc.sweep * i / count; points.push([arc.cx + arc.r * Math.cos(angle), arc.cy + arc.r * Math.sin(angle)]); }
    return points;
  }
  function previewLine(sketch, points, color) {
    if (!points || points.length < 2) return;
    var world = points.map(function (point) { return localToWorld(sketch, point[0], point[1], 0.05); }), line = lineObject(world, color, 0.9); line.renderOrder = 8; sketchModel.add(line);
  }
  function drawSketches() {
    clearGroup(sketchModel);
    state.sketches.forEach(function (sketch) {
      var active = sketch.id === activeSketchId, color = active ? 0xffcf66 : 0x76b4e6;
      OS.physicalCurves(sketch.geometry).forEach(function (curve) {
        var points = curveLocalPoints(sketch, curve).map(function (point) { return localToWorld(sketch, point[0], point[1], 0.04); });
        var line = lineObject(points, selectedEntity("curve", curve.id) && active ? 0xffffff : color, active ? 1 : 0.75); if (editMode && active) line.material.depthTest = false; line.userData.sketchCurve = curve.id; line.renderOrder = 7; sketchModel.add(line);
      });
      OS.physicalPoints(sketch.geometry).forEach(function (point) {
        var selected = active && selectedEntity("point", point.id), radius = editMode && active ? orthoHalf * 0.012 : 0.7;
        var marker = new THREE.Mesh(new THREE.SphereGeometry(Math.max(0.35, radius), 12, 9), new THREE.MeshBasicMaterial({ color: selected ? 0xffffff : color, depthTest: false }));
        marker.position.copy(localToWorld(sketch, point.x, point.y, 0.08)); marker.userData.sketchPoint = point.id; marker.renderOrder = 9; sketchModel.add(marker);
      });
    });
    var sketch = activeSketch(); if (!editMode || !sketch) return;
    if (linePoints.length) { var chain = linePoints.slice(); if (lineCursor) chain.push([lineCursor.x, lineCursor.y]); previewLine(sketch, chain, 0x7ee787); }
    if (rectangleStart && rectangleCurrent) previewLine(sketch, [[rectangleStart.x, rectangleStart.y], [rectangleCurrent.x, rectangleStart.y], [rectangleCurrent.x, rectangleCurrent.y], [rectangleStart.x, rectangleCurrent.y], [rectangleStart.x, rectangleStart.y]], 0x7ee787);
    if (sketchGesture && sketchGesture.kind === "marquee" && sketchGesture.current) previewLine(sketch, [[sketchGesture.start.x, sketchGesture.start.y], [sketchGesture.current.x, sketchGesture.start.y], [sketchGesture.current.x, sketchGesture.current.y], [sketchGesture.start.x, sketchGesture.current.y], [sketchGesture.start.x, sketchGesture.start.y]], 0x62a5ff);
  }
  async function rebuildBodies() {
    var sequence = ++meshSequence; clearGroup(solidModel);
    var count = enabledExtrusionCount(state);
    if (!count) { $("#model-status").textContent = "Blank workspace · 0 solids"; syncExportButtons(); return; }
    var response = await fetch("/api/systems/" + encodeURIComponent(D.system) + "/cad/mesh", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(mechanicalDocument()) });
    if (!response.ok) throw new Error(await response.text());
    var result = await response.json(); if (sequence !== meshSequence) return;
    (result.bodies || []).forEach(function (body) { var mesh = kernelMesh(body.mesh, material(0x3478bd, 0.72)); mesh.userData.bodyId = body.id; solidModel.add(mesh); });
    $("#model-status").textContent = result.bodies.length + (result.bodies.length === 1 ? " authored solid" : " authored solids") + " · no generated enclosure";
    syncExportButtons();
  }
  function syncExportButtons() { var enabled = enabledExtrusionCount(state) > 0; $("#step").disabled = !enabled; $("#stl").disabled = !enabled; }
  async function download(format) {
    var response = await fetch("/api/systems/" + encodeURIComponent(D.system) + "/cad/export?format=" + format, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(mechanicalDocument()) });
    if (!response.ok) throw new Error(await response.text());
    var blob = await response.blob(), link = document.createElement("a"); link.href = URL.createObjectURL(blob); link.download = D.system + "-mechanical." + format; link.click(); setTimeout(function () { URL.revokeObjectURL(link.href); }, 1000);
  }

  function renderSketches() {
    var host = $("#sketches"); host.textContent = "";
    state.sketches.forEach(function (sketch) {
      var compiled = OS && OS.compile(sketch.geometry), sketchState = OS && OS.state(sketch.geometry), card = document.createElement("div");
      card.className = "feature sketch-card" + (sketch.id === activeSketchId ? " selected" : ""); card.dataset.id = sketch.id;
      card.innerHTML = '<div class="feature-title"><button class="select-sketch"></button><button class="remove" title="Delete sketch">×</button></div><div class="sketch-fields"><label>Name<input data-key="name"></label><label>Plane<select data-key="plane"><option value="xy">XY</option><option value="xz">XZ</option><option value="yz">YZ</option></select></label><label>Plane offset<input type="number" step="0.5" data-key="plane_z"></label></div><div class="sketch-state"></div><div class="point-grid"></div>';
      card.querySelector(".select-sketch").textContent = sketch.id === activeSketchId && editMode ? "Editing" : "Edit";
      card.querySelector('[data-key="name"]').value = sketch.name; card.querySelector('[data-key="plane"]').value = sketchPlane(sketch.plane); card.querySelector('[data-key="plane_z"]').value = sketch.plane_z;
      card.querySelector(".sketch-state").textContent = PLANE[sketchPlane(sketch.plane)].label + " · " + (compiled && compiled.closed ? "Closed profile" : "Open profile") + " · " + (sketchState ? sketchState.dof + " DOF" : "empty");
      var points = card.querySelector(".point-grid");
      (sketch.geometry.points || []).forEach(function (point) { var row = document.createElement("label"); row.textContent = "P" + point.id; row.dataset.point = point.id; row.innerHTML += '<input type="number" step="0.5" data-axis="x" value="' + point.x + '"><input type="number" step="0.5" data-axis="y" value="' + point.y + '">'; points.appendChild(row); });
      host.appendChild(card);
    });
  }
  function renderExtrusions() {
    var host = $("#extrusions"); host.textContent = "";
    state.extrusions.forEach(function (extrusion) {
      var card = document.createElement("div"); card.className = "feature"; card.dataset.id = extrusion.id;
      card.innerHTML = '<div class="feature-title"><label class="check"><input class="enabled" type="checkbox"> Enabled</label><button class="remove" title="Delete extrusion">×</button></div><div class="sketch-fields"><label>Name<input data-key="name"></label><label>Distance<input type="number" min="0.01" max="10000" step="0.5" data-key="distance"></label></div><div class="sketch-state"></div>';
      card.querySelector(".enabled").checked = extrusion.enabled !== false; card.querySelector('[data-key="name"]').value = extrusion.name; card.querySelector('[data-key="distance"]').value = extrusion.distance;
      card.querySelector(".sketch-state").textContent = "From " + extrusion.sketch;
      host.appendChild(card);
    });
  }
  function history(map, id) { return map[id] || (map[id] = []); }
  function disableOpenExtrusions(sketch) {
    var compiled = OS.compile(sketch.geometry), disabled = false;
    if (compiled && compiled.closed) return false;
    state.extrusions.forEach(function (extrusion) { if (extrusion.sketch === sketch.id && extrusion.enabled !== false) { extrusion.enabled = false; disabled = true; } });
    return disabled;
  }
  function afterSketchChange(label) {
    var sketch = activeSketch(), disabled = sketch && disableOpenExtrusions(sketch); setDirty(); renderSketches(); renderExtrusions(); drawSketches(); syncPalette(); rebuildBodies().catch(function (error) { status("Extrusion error: " + error.message, true); });
    status(label + (disabled ? " · dependent extrusion disabled while profile is open" : ""));
  }
  function sketchMutate(label, mutate) {
    var sketch = activeSketch(); if (!sketch) return false; var before = clone(sketch.geometry), ok = mutate(sketch.geometry), solved = ok === false ? null : OS.solve(sketch.geometry), compiled = solved && !solved.conflict ? OS.compile(sketch.geometry) : null;
    if (ok === false || !solved || solved.conflict || !compiled) { sketch.geometry = before; status("Sketch change conflicts with its constraints", true); drawSketches(); return false; }
    var stack = history(undoBySketch, sketch.id); stack.push(before); if (stack.length > 80) stack.shift(); redoBySketch[sketch.id] = []; afterSketchChange(label); return true;
  }
  function undoSketch() {
    var sketch = activeSketch(), stack = sketch && history(undoBySketch, sketch.id); if (!sketch || !stack.length) return;
    history(redoBySketch, sketch.id).push(clone(sketch.geometry)); sketch.geometry = stack.pop(); sketchSelection = []; afterSketchChange("Undo");
  }
  function redoSketch() {
    var sketch = activeSketch(), stack = sketch && history(redoBySketch, sketch.id); if (!sketch || !stack.length) return;
    history(undoBySketch, sketch.id).push(clone(sketch.geometry)); sketch.geometry = stack.pop(); sketchSelection = []; afterSketchChange("Redo");
  }
  function selectedIds(type) { return sketchSelection.filter(function (row) { return row.type === type; }).map(function (row) { return row.id; }); }
  function selectSketchEntity(type, id, extend) {
    var at = sketchSelection.findIndex(function (row) { return row.type === type && row.id === id; }); if (!extend) sketchSelection = [];
    if (at >= 0 && extend) sketchSelection.splice(at, 1); else sketchSelection.push({ type: type, id: id }); drawSketches(); syncPalette();
  }
  function sketchNumber(label, value) { var text = root.prompt(label, String(Math.round(finite(value, 0) * 1000) / 1000)); if (text == null) return null; var number = Number(text); return Number.isFinite(number) ? number : null; }
  function sketchConstraint(kind) {
    sketchMutate(kind + " constraint", function (geometry) {
      var curves = selectedIds("curve"), points = selectedIds("point"), result = null;
      if (kind === "horizontal" || kind === "vertical") result = curves.length && OS.addConstraint(geometry, kind, curves[0]);
      else if (kind === "coincident") result = points.length >= 2 && OS.addConstraint(geometry, kind, points[0], points[1]);
      else if (kind === "collinear" && curves.length >= 2) { var a = OS.curve(geometry, curves[0]), b = OS.curve(geometry, curves[1]); if (a && b && a.kind === "line" && b.kind === "line") result = OS.addConstraint(geometry, kind, curves[0], curves[1]); }
      else if (kind === "midpoint") result = points.length && curves.length && OS.addConstraint(geometry, kind, points[0], curves[0]);
      else if (kind === "symmetric") result = points.length >= 2 && curves.length && OS.addConstraint(geometry, kind, points[0], points[1], null, curves[0]);
      else if (kind === "fixed") { if (points.length) result = OS.addConstraint(geometry, kind, points[0]); else if (curves.length) { var curve = OS.curve(geometry, curves[0]); result = curve && OS.addConstraint(geometry, kind, curve.a); if (result) OS.addConstraint(geometry, kind, curve.b); } }
      else if (curves.length >= 2) result = OS.addConstraint(geometry, kind, curves[0], curves[1]);
      if (!result) status("Select compatible points or curves for " + kind, true); return !!result;
    });
  }
  function sketchDimension() {
    sketchMutate("Driving dimension added", function (geometry) {
      var curves = selectedIds("curve"), points = selectedIds("point"), kind, a, b, value, curve;
      if (curves.length) { curve = OS.curve(geometry, curves[0]); kind = curve.kind === "arc" ? "radius" : "length"; a = curve.id; value = sketchNumber(kind === "radius" ? "Arc radius (mm)" : "Line length (mm)", curve.kind === "arc" ? OS.arcCircle(geometry, curve).r : Math.hypot(OS.point(geometry, curve.b).x - OS.point(geometry, curve.a).x, OS.point(geometry, curve.b).y - OS.point(geometry, curve.a).y)); }
      else if (points.length >= 2) { kind = "distance"; a = points[0]; b = points[1]; value = sketchNumber("Point distance (mm)", Math.hypot(OS.point(geometry, b).x - OS.point(geometry, a).x, OS.point(geometry, b).y - OS.point(geometry, a).y)); }
      else { status("Select one curve or two points to dimension", true); return false; }
      return value != null && value > 0 && !!OS.addConstraint(geometry, kind, a, b, value);
    });
  }
  function extrudeActiveSketch() {
    var sketch = activeSketch(), compiled = sketch && OS.compile(sketch.geometry);
    if (!sketch || !compiled || !compiled.closed) { status("Close the active sketch profile before extruding", true); return false; }
    var distance = sketchNumber("Extrusion distance (mm)", 2);
    if (distance == null) return false;
    if (!(distance > 0)) { status("Extrusion distance must be greater than zero", true); return false; }
    if (editMode) finishSketch();
    var id = nextId("extrude", state.extrusions);
    state.extrusions.push({ id: id, name: sketch.name, sketch: sketch.id, distance: distance, enabled: true });
    renderExtrusions(); setDirty(); status("Building " + sketch.name + " extrusion…");
    rebuildBodies().then(function () { status("Extruded " + sketch.name + " by " + distance + " mm"); }).catch(function (error) {
      $("#model-status").textContent = "Extrusion error: " + error.message; status("Extrusion failed: " + error.message, true); syncExportButtons();
    });
    return true;
  }
  function removeSelectedFillet() {
    sketchMutate("Fillet removed", function (geometry) { var curves = selectedIds("curve"), points = selectedIds("point"), arcs = [], changed = false;
      curves.forEach(function (id) { var curve = OS.curve(geometry, id); if (curve && curve.kind === "arc") arcs.push(id); });
      OS.physicalCurves(geometry).forEach(function (curve) { if (curve.kind === "arc" && points.indexOf(curve.a) >= 0 && points.indexOf(curve.b) >= 0 && arcs.indexOf(curve.id) < 0) arcs.push(curve.id); });
      arcs.forEach(function (id) { if (OS.removeFillet(geometry, id)) changed = true; }); sketchSelection = []; return changed;
    });
  }
  function modifySketch(action) {
    if (action === "remove-fillet") return removeSelectedFillet();
    sketchMutate(action, function (geometry) {
      var curves = selectedIds("curve"), points = selectedIds("point"), curve, a, b, dx, dy, length, number, compiled, changed = false;
      if (action === "delete") { points.forEach(function (id) { changed = OS.deletePoint(geometry, id) || changed; }); curves.forEach(function (id) { changed = OS.deleteSegment(geometry, id) || changed; }); sketchSelection = []; return changed; }
      if (action === "arc") { if (!curves.length) return false; curve = OS.curve(geometry, curves[0]); a = OS.point(geometry, curve.a); b = OS.point(geometry, curve.b); dx = b.x - a.x; dy = b.y - a.y; length = Math.hypot(dx, dy); number = sketchNumber("Arc rise at midpoint (mm)", Math.max(0.5, length / 5)); return number != null && length > 0 && OS.toArc(geometry, curve.id, [(a.x + b.x) / 2 - dy / length * number, (a.y + b.y) / 2 + dx / length * number]); }
      if (action === "line") return curves.length && OS.toLine(geometry, curves[0]);
      if (action === "fillet" || action === "chamfer") { number = sketchNumber((action === "fillet" ? "Fillet radius" : "Chamfer distance") + " (mm)", 1); return points.length && number > 0 && !!(action === "fillet" ? OS.filletPoint(geometry, points[0], number) : OS.chamferPoint(geometry, points[0], number)); }
      if (action === "offset") { number = sketchNumber("Profile offset (mm, positive = outward)", 1); return number != null && OS.offset(geometry, number); }
      if (action === "mirror-x" || action === "mirror-y") { compiled = OS.compile(geometry); return compiled && OS.mirror(geometry, action.slice(-1), action === "mirror-x" ? compiled.rect.x + compiled.rect.w / 2 : compiled.rect.y + compiled.rect.h / 2); }
      return false;
    });
  }
  function updateOrthoFrustum() {
    var aspect = canvas.clientWidth / Math.max(canvas.clientHeight, 1); orthoCamera.left = -orthoHalf * aspect; orthoCamera.right = orthoHalf * aspect; orthoCamera.top = orthoHalf; orthoCamera.bottom = -orthoHalf; orthoCamera.updateProjectionMatrix();
  }
  function rebuildEditGrid() {
    clearGroup(editGrid); if (!editMode || !activeSketch()) return; var sketch = activeSketch(), span = orthoHalf * 2.5, step = orthoHalf > 160 ? 20 : orthoHalf > 70 ? 10 : orthoHalf > 28 ? 5 : 1;
    for (var value = -Math.ceil(span / step) * step; value <= span; value += step) {
      var strong = Math.abs(value) < 1e-9, color = strong ? 0x6f829d : 0x263b54, opacity = strong ? 0.8 : 0.45;
      editGrid.add(lineObject([localToWorld(sketch, value, -span, -0.03), localToWorld(sketch, value, span, -0.03)], color, opacity));
      editGrid.add(lineObject([localToWorld(sketch, -span, value, -0.03), localToWorld(sketch, span, value, -0.03)], color, opacity));
    }
  }
  function editFit() {
    var sketch = activeSketch(); if (!sketch) return; var compiled = OS.compile(sketch.geometry), width = compiled && compiled.rect ? compiled.rect.w : lastBounds.width, height = compiled && compiled.rect ? compiled.rect.h : lastBounds.depth;
    var centerX = compiled && compiled.rect ? compiled.rect.x + compiled.rect.w / 2 : 0, centerY = compiled && compiled.rect ? compiled.rect.y + compiled.rect.h / 2 : 0;
    orthoHalf = Math.max(15, width * 0.7, height * 0.7); var basis = planeBasis(sketch), target = localToWorld(sketch, centerX, centerY, 0), position = target.clone().add(basis.n.clone().multiplyScalar(1000));
    orthoCamera.up.copy(basis.v); orthoCamera.position.copy(position); orthoCamera.lookAt(target); orthoCamera.near = 0.1; orthoCamera.far = 2500; updateOrthoFrustum(); rebuildEditGrid();
  }
  function syncPalette() {
    var palette = $("#sketch-palette"), sketch = activeSketch(), stateValue = sketch && OS.state(sketch.geometry), compiled = sketch && OS.compile(sketch.geometry); palette.hidden = !editMode || !sketch;
    if (!sketch) return; $("#sketch-title").textContent = sketch.name + " · " + PLANE[sketchPlane(sketch.plane)].label; $("#sketch-dof").textContent = stateValue && stateValue.conflict ? "conflict" : ((compiled && !compiled.closed ? "open · " : "") + (stateValue ? stateValue.dof : 0) + " DOF"); $("#sketch-dof").classList.toggle("bad", !!(stateValue && stateValue.conflict));
    palette.querySelectorAll("[data-action]").forEach(function (button) { button.classList.toggle("on", button.dataset.action === sketchTool); });
    var close = palette.querySelector('[data-action="close-profile"]'); close.disabled = !(compiled && !compiled.closed && OS.canCloseProfile(sketch.geometry));
    palette.querySelector('[data-action="undo"]').disabled = !history(undoBySketch, sketch.id).length; palette.querySelector('[data-action="redo"]').disabled = !history(redoBySketch, sketch.id).length;
  }
  function enterSketch(sketch) {
    sketch = sketch || activeSketch(); if (!sketch) { status("Create or select a sketch first", true); return; }
    if (viewMode !== "3d") setView("3d");
    activeSketchId = sketch.id; selectedPlane = sketchPlane(sketch.plane); editMode = true; sketchTool = "select"; sketchSelection = []; linePoints = []; lineCursor = null; rectangleStart = null; rectangleCurrent = null; sketchGesture = null;
    activeCamera = orthoCamera; controls.enabled = false; grid.visible = false; solidModel.visible = false; datumPlanes.forEach(function (mesh) { mesh.visible = false; }); canvas.classList.add("sketching");
    document.querySelectorAll("#plane-choices button").forEach(function (button) { button.disabled = true; button.classList.toggle("on", button.dataset.plane === selectedPlane); });
    $("#plane-status").textContent = PLANE[selectedPlane].label + " sketch plane · view locked normal to plane"; $("#drag-help").textContent = "Flat 2D sketch · select and drag points/edges · Shift adds selection · wheel zooms";
    editFit(); renderSketches(); drawSketches(); syncPalette();
  }
  function finishSketch() {
    editMode = false; sketchTool = "select"; sketchSelection = []; linePoints = []; lineCursor = null; rectangleStart = null; rectangleCurrent = null; sketchGesture = null; activeCamera = camera; controls.enabled = true; grid.visible = true; solidModel.visible = true; clearGroup(editGrid); canvas.classList.remove("sketching"); datumPlanes.forEach(function (mesh) { mesh.visible = true; });
    document.querySelectorAll("#plane-choices button").forEach(function (button) { button.disabled = false; }); selectPlane(selectedPlane); $("#drag-help").textContent = "Orbit empty space · drag PCBs · click an origin plane to start a sketch"; renderSketches(); drawSketches(); syncPalette();
  }
  function syncInputs() {
    ["ambient", "pitch"].forEach(function (key) { $("#" + key).value = state[key]; }); $("#snap").checked = state.snap !== false;
    $("#scale-min").value = state.scaleMin; $("#scale-max").value = state.scaleMax;
    $("#legend-min").textContent = state.scaleMin + " °C"; $("#legend-max").textContent = state.scaleMax + " °C";
    state.instances.forEach(function (pose) { if (cards[pose.id]) cards[pose.id].querySelector(".enabled").checked = pose.on; });
    renderSketches(); renderExtrusions(); updateCardValues(); drawSketches(); syncExportButtons();
  }
  function updateCardValues() {
    state.instances.forEach(function (pose) {
      var card = cards[pose.id]; if (!card) return;
      ["x", "y", "z", "rot"].forEach(function (key) { var input = card.querySelector('[data-key="' + key + '"]'); if (document.activeElement !== input) input.value = Number(pose[key].toFixed(3)); });
      var row = resultFor(pose.id), temp = card.querySelector(".temp"); temp.textContent = row && row.temperature_c != null ? row.temperature_c.toFixed(1) + " °C" : "no thermal model";
      temp.className = "temp " + (!row || row.temperature_c == null ? "unknown" : row.temperature_c - state.ambient < 18 ? "cool" : row.temperature_c - state.ambient < 40 ? "warm" : "hot");
    });
  }
  function updateThermal() {
    thermalResult = solveSystem(usable, state.instances, state.ambient); fieldRasters = {};
    var summary = $("#thermal-summary"), hot = thermalResult.hottest;
    if (thermalLoading) summary.textContent = "Loading board thermal models…";
    else if (!hot) summary.textContent = "No solved board thermal scenarios are available.";
    else summary.innerHTML = '<strong>' + hot.temperature_c.toFixed(1) + ' °C</strong><span>hottest board hotspot · ' + hot.id + '</span><strong>' + thermalResult.total_watts.toFixed(2) + ' W</strong><span>annotated load</span><strong>' + (thermalResult.outlet_rise_c == null ? '—' : thermalResult.outlet_rise_c.toFixed(1) + ' °C') + '</strong><span>mixed outlet rise</span>';
    updateCardValues(); if (!thermalLoading) requestVisibleFields(); twoDirty = true;
  }
  function rebuild(fetchSolids) {
    updateThermal(); clearGroup(boardsModel); groupsById = {};
    state.instances.forEach(function (pose) { var board = boardByName[pose.board]; if (board && pose.on) drawBoard(board, pose); });
    drawSketches(); lastBounds = occupied(); twoDirty = true; if (dirty) persist();
    if (fetchSolids !== false) rebuildBodies().catch(function (error) { $("#model-status").textContent = "Extrusion error: " + error.message; syncExportButtons(); });
  }
  async function loadThermal() {
    await Promise.all(usable.map(async function (board) { try { var query = new URLSearchParams({ ambient: "25" }); if (board.layout !== "blessed") query.set("layout", board.layout); var response = await fetch("/api/thermal/" + encodeURIComponent(board.name) + "?" + query); if (response.ok) board.thermal = await response.json(); } catch (_) {} }));
    thermalLoading = false; rebuild(false);
  }
  function fit3d() {
    var top = state.sketches.reduce(function (value, sketch) { var extrusion = state.extrusions.find(function (row) { return row.sketch === sketch.id && row.enabled !== false; }); return Math.max(value, sketch.plane_z + (extrusion ? extrusion.distance : 0)); }, 10);
    var span = Math.max(lastBounds.width, lastBounds.depth, Math.abs(top), 30); controls.minDistance = Math.max(5, span * 0.18); controls.maxDistance = span * 8;
    camera.up.set(0, 0, 1); controls.target.set(0, 0, top / 2); camera.position.set(span * 0.95, -span * 1.15, span * 0.8); camera.near = Math.max(0.05, span / 1000); camera.far = span * 30; camera.updateProjectionMatrix(); wheelGesture.last = -Infinity; wheelGesture.total = 0; controls.update();
  }
  function topView() {
    if (editMode) editFit(); else enterSketch(activeSketch());
  }
  function resize2d() {
    var ratio = Math.min(devicePixelRatio || 1, 2), width = Math.max(1, Math.round(thermalCanvas.clientWidth * ratio)), height = Math.max(1, Math.round(thermalCanvas.clientHeight * ratio));
    if (thermalCanvas.width === width && thermalCanvas.height === height) return false;
    thermalCanvas.width = width; thermalCanvas.height = height; twoDirty = true; return true;
  }
  function fit2d() {
    resize2d(); var margin = 70 * Math.min(devicePixelRatio || 1, 2);
    var width = lastBounds.width, height = lastBounds.depth;
    twoView.centerX = 0; twoView.centerY = 0;
    twoView.scale = Math.max(0.25, Math.min((thermalCanvas.width - margin * 2) / Math.max(1, width), (thermalCanvas.height - margin * 2) / Math.max(1, height)));
    twoDirty = true;
  }
  function fit() { if (editMode) return editFit(); if (viewMode === "2d") fit2d(); else fit3d(); }
  function setView(mode) {
    if (mode !== "3d" && editMode) finishSketch();
    viewMode = mode === "3d" ? "3d" : "2d"; thermalCanvas.hidden = viewMode !== "2d"; canvas.hidden = viewMode !== "3d";
    $("#view-2d").classList.toggle("on", viewMode === "2d"); $("#view-3d").classList.toggle("on", viewMode === "3d");
    $("#view-2d").setAttribute("aria-pressed", viewMode === "2d" ? "true" : "false"); $("#view-3d").setAttribute("aria-pressed", viewMode === "3d" ? "true" : "false");
    document.querySelectorAll(".thermal-key").forEach(function (node) { node.hidden = viewMode !== "2d"; });
    document.querySelectorAll(".cad-key").forEach(function (node) { node.hidden = viewMode !== "3d"; });
    $("#top").hidden = viewMode !== "3d";
    $("#drag-help").textContent = viewMode === "2d" ? "Drag boards · drag empty space to pan · scroll to zoom" : "Orbit empty space · drag PCBs · click an origin plane to start a sketch";
    $("#thermal-probe").hidden = true; fit();
  }
  async function saveDesign() {
    if (!D.can_write) return; $("#save").disabled = true; status("Saving…");
    try {
      var response = await fetch(documentUrl, { method: "PUT", headers: { "content-type": "application/json", "x-netlisp-review": "1" }, body: JSON.stringify(mechanicalDocument()) });
      if (!response.ok) { var message = await response.text(); try { message = JSON.parse(message).error || message; } catch (_) {} throw new Error(message); }
      await response.json(); dirty = false; localStorage.removeItem(storeKey); status("Saved");
    } catch (error) { status("Save failed: " + error.message, true); } finally { $("#save").disabled = !D.can_write; }
  }
  async function boot() {
    var serverDocument = null, loadError = null, legacyIgnored = false;
    try { var response = await fetch(documentUrl, { headers: { accept: "application/json" } }); if (!response.ok) throw new Error(await response.text()); var value = await response.json(); serverDocument = value.document; legacyIgnored = value.legacy_enclosure_ignored === true; } catch (error) { loadError = error; }
    if (!dirty) applyMechanical(serverDocument); if (!activeSketchId && state.sketches.length) activeSketchId = state.sketches[0].id; syncInputs();
    if (loadError) status("Could not load saved design: " + loadError.message, true); else if (dirty) status("Recovered local draft"); else if (legacyIgnored) status("Old generated enclosure ignored · blank workspace"); else if (serverDocument) status("Saved"); else status("Blank design");
    $("#save").disabled = !D.can_write; rebuild(); setView("2d"); loadThermal();
  }

  boardHost.addEventListener("input", function (event) {
    var card = event.target.closest(".board"), pose = card && poseFor(card.dataset.instance); if (!pose) return;
    if (event.target.classList.contains("enabled")) pose.on = event.target.checked; else if (event.target.dataset.key) pose[event.target.dataset.key] = finite(event.target.value, 0); else return;
    setDirty(); rebuild(false);
  });
  function updateScale() {
    var minimum = finite($("#scale-min").value, state.scaleMin), maximum = finite($("#scale-max").value, state.scaleMax);
    if (!(maximum > minimum)) return;
    state.scaleMin = minimum; state.scaleMax = maximum; fieldRasters = {};
    $("#legend-min").textContent = minimum + " °C"; $("#legend-max").textContent = maximum + " °C"; setDirty(); twoDirty = true;
  }
  $("#scale-min").addEventListener("input", updateScale); $("#scale-max").addEventListener("input", updateScale);
  ["ambient", "pitch"].forEach(function (key) { $("#" + key).addEventListener("input", function () { state[key] = finite(this.value, defaults[key]); setDirty(); rebuild(false); }); });
  $("#snap").addEventListener("change", function () { state.snap = this.checked; setDirty(); });
  $("#plane-choices").addEventListener("click", function (event) { if (event.target.dataset.plane) selectPlane(event.target.dataset.plane); });
  $("#new-sketch").onclick = function () {
    var id = nextId("sketch", state.sketches), sketch = { id: id, name: "Sketch " + (state.sketches.length + 1), plane: selectedPlane, plane_z: 0, geometry: { version: 1, points: [], curves: [], constraints: [] } };
    state.sketches.push(sketch); activeSketchId = id; setDirty(); enterSketch(sketch); status("Empty " + PLANE[selectedPlane].label + " sketch created · choose Line or Rectangle");
  };
  $("#sketches").addEventListener("click", function (event) {
    var card = event.target.closest(".sketch-card"); if (!card) return;
    if (event.target.classList.contains("remove")) { if (editMode && activeSketchId === card.dataset.id) finishSketch(); state.sketches = state.sketches.filter(function (row) { return row.id !== card.dataset.id; }); state.extrusions = state.extrusions.filter(function (row) { return row.sketch !== card.dataset.id; }); if (activeSketchId === card.dataset.id) activeSketchId = state.sketches.length ? state.sketches[0].id : null; setDirty(); syncInputs(); rebuildBodies(); return; }
    if (event.target.classList.contains("select-sketch")) { var sketch = state.sketches.find(function (row) { return row.id === card.dataset.id; }); if (editMode && activeSketchId === card.dataset.id) finishSketch(); else enterSketch(sketch); }
  });
  $("#sketches").addEventListener("input", function (event) {
    var card = event.target.closest(".sketch-card"), sketch = card && state.sketches.find(function (row) { return row.id === card.dataset.id; }); if (!sketch) return;
    if (event.target.dataset.key === "name") sketch.name = event.target.value || sketch.id;
    else if (event.target.dataset.key === "plane") sketch.plane = sketchPlane(event.target.value);
    else if (event.target.dataset.key === "plane_z") sketch.plane_z = finite(event.target.value, 0);
    else if (event.target.dataset.axis) { var point = OS.point(sketch.geometry, Number(event.target.closest("label").dataset.point)); if (!point) return; var x = event.target.dataset.axis === "x" ? finite(event.target.value, point.x) : point.x, y = event.target.dataset.axis === "y" ? finite(event.target.value, point.y) : point.y; OS.movePoint(sketch.geometry, point.id, x, y); }
    else return;
    setDirty(); if (editMode && sketch.id === activeSketchId && (event.target.dataset.key === "plane" || event.target.dataset.key === "plane_z")) enterSketch(sketch); drawSketches(); renderExtrusions(); rebuildBodies();
  });
  $("#add-extrusion").onclick = extrudeActiveSketch;
  $("#extrusions").addEventListener("click", function (event) {
    var card = event.target.closest(".feature"); if (!card || !event.target.classList.contains("remove")) return; state.extrusions = state.extrusions.filter(function (row) { return row.id !== card.dataset.id; }); renderExtrusions(); setDirty(); rebuildBodies();
  });
  $("#extrusions").addEventListener("input", function (event) {
    var card = event.target.closest(".feature"), extrusion = card && state.extrusions.find(function (row) { return row.id === card.dataset.id; }); if (!extrusion) return;
    if (event.target.classList.contains("enabled")) extrusion.enabled = event.target.checked; else if (event.target.dataset.key === "name") extrusion.name = event.target.value || extrusion.id; else if (event.target.dataset.key === "distance") extrusion.distance = Math.max(0.01, finite(event.target.value, extrusion.distance)); else return;
    setDirty(); rebuildBodies();
  });
  $("#sketch-palette").addEventListener("click", function (event) {
    var action = event.target.dataset.action; if (!action || event.target.disabled) return;
    if (action === "finish") return finishSketch();
    if (action === "extrude") return extrudeActiveSketch();
    if (action === "undo") return undoSketch();
    if (action === "redo") return redoSketch();
    if (action === "close-profile") return sketchMutate("Profile closed · ready to extrude", function (geometry) { return OS.closeProfile(geometry); });
    if (action === "dimension") return sketchDimension();
    if (["horizontal", "vertical", "coincident", "collinear", "parallel", "perpendicular", "tangent", "equal", "midpoint", "symmetric", "fixed"].indexOf(action) >= 0) return sketchConstraint(action);
    if (["arc", "line", "fillet", "remove-fillet", "chamfer", "offset", "mirror-x", "mirror-y", "delete"].indexOf(action) >= 0) return modifySketch(action);
    sketchTool = action; linePoints = []; lineCursor = null; rectangleStart = null; rectangleCurrent = null; sketchGesture = null; $("#drag-help").textContent = action === "rectangle" ? "Flat 2D sketch · drag two corners" : action === "line-tool" ? "Flat 2D sketch · click connected endpoints · click the start to close · Enter stops" : "Flat 2D sketch · select and drag points/edges · Shift adds selection"; syncPalette(); drawSketches();
  });

  var raycaster = new THREE.Raycaster(), pointer = new THREE.Vector2(), drag = null;
  function pointerRay(event) { var rect = canvas.getBoundingClientRect(); pointer.x = (event.clientX - rect.left) / rect.width * 2 - 1; pointer.y = -(event.clientY - rect.top) / rect.height * 2 + 1; raycaster.setFromCamera(pointer, activeCamera); }
  function planePoint(z, target) { return raycaster.ray.intersectPlane(new THREE.Plane(new THREE.Vector3(0, 0, 1), -z), target); }
  function sketchPoint(event) { var sketch = activeSketch(); pointerRay(event); var world = sketch && raycaster.ray.intersectPlane(sketchPlane3(sketch), new THREE.Vector3()); return world && worldToLocal(sketch, world); }
  function sketchTolerance() { return Math.max(0.15, orthoHalf * 2 / Math.max(canvas.clientHeight, 1) * 11); }
  function snapSketchPoint(point, chain) { var sketch = activeSketch(), existing = OS.physicalPoints(sketch.geometry), tolerance = sketchTolerance(); return OS.snapLinePoint(chain || [], existing, point.x, point.y, state.snap ? 1 : 0, tolerance, tolerance); }
  function hitSketchPoint(point) { var sketch = activeSketch(), tolerance = sketchTolerance(), best = null; OS.physicalPoints(sketch.geometry).forEach(function (candidate) { var distance = Math.hypot(point.x - candidate.x, point.y - candidate.y); if (distance <= tolerance && (!best || distance < best.distance)) best = { id: candidate.id, distance: distance }; }); return best; }
  function segmentDistance(point, a, b) { var dx = b[0] - a[0], dy = b[1] - a[1], length = dx * dx + dy * dy, t = length ? Math.max(0, Math.min(1, ((point.x - a[0]) * dx + (point.y - a[1]) * dy) / length)) : 0; return Math.hypot(point.x - a[0] - t * dx, point.y - a[1] - t * dy); }
  function hitSketchCurve(point) { var sketch = activeSketch(), tolerance = sketchTolerance(), best = null; OS.physicalCurves(sketch.geometry).forEach(function (curve) { var points = curveLocalPoints(sketch, curve), distance = Infinity; for (var i = 1; i < points.length; i += 1) distance = Math.min(distance, segmentDistance(point, points[i - 1], points[i])); if (distance <= tolerance && (!best || distance < best.distance)) best = { id: curve.id, distance: distance }; }); return best; }
  canvas.addEventListener("pointerdown", function (event) {
    if (editMode) {
      var sketch = activeSketch(), local = sketchPoint(event); if (!sketch || !local) return;
      if (sketchTool === "rectangle") { var rectSnap = snapSketchPoint(local, []); rectangleStart = { x: rectSnap.x, y: rectSnap.y, pointer: event.pointerId }; rectangleCurrent = { x: rectSnap.x, y: rectSnap.y }; canvas.setPointerCapture(event.pointerId); event.preventDefault(); return; }
      if (sketchTool === "line-tool") {
        var lineSnap = snapSketchPoint(local, linePoints), next = [lineSnap.x, lineSnap.y];
        if (!linePoints.length) { linePoints.push(next); lineCursor = null; drawSketches(); }
        else { var previous = linePoints[linePoints.length - 1]; if (Math.hypot(previous[0] - next[0], previous[1] - next[1]) > 1e-7) { var added = sketchMutate("Line added", function (geometry) { return OS.addLinePath(geometry, [previous, next], 0.001); }); if (added) { linePoints.push(next); if (OS.closed(sketch.geometry)) { sketchTool = "select"; linePoints = []; status("Profile closed · ready to extrude"); syncPalette(); } } } }
        event.preventDefault(); return;
      }
      var hitPoint = hitSketchPoint(local), hitCurve = hitPoint ? null : hitSketchCurve(local);
      if (hitPoint) { selectSketchEntity("point", hitPoint.id, event.shiftKey); sketchGesture = { kind: "point", id: hitPoint.id, pointer: event.pointerId, start: local, before: clone(sketch.geometry), moved: false }; }
      else if (hitCurve) { selectSketchEntity("curve", hitCurve.id, event.shiftKey); sketchGesture = { kind: "curve", id: hitCurve.id, pointer: event.pointerId, start: local, before: clone(sketch.geometry), moved: false }; }
      else { if (!event.shiftKey) sketchSelection = []; sketchGesture = { kind: "marquee", pointer: event.pointerId, start: local, current: local, extend: event.shiftKey, moved: false }; drawSketches(); }
      canvas.setPointerCapture(event.pointerId); event.preventDefault(); return;
    }
    pointerRay(event); var datum = raycaster.intersectObjects(datumPlanes, false)[0], hit = raycaster.intersectObjects(boardsModel.children, true).find(function (candidate) { return candidate.object.userData.draggable; });
    if (datum && (!hit || datum.distance <= hit.distance)) { selectPlane(datum.object.userData.datumPlane); event.preventDefault(); return; }
    if (!hit) return;
    var id = hit.object.userData.instanceId, pose = poseFor(id), point3 = pose && planePoint(pose.z, new THREE.Vector3()); if (!pose || !point3) return;
    drag = { id: id, pointer: event.pointerId, startX: pose.x, startY: pose.y, pointX: point3.x, pointY: point3.y }; controls.enabled = false; canvas.classList.add("dragging"); canvas.setPointerCapture(event.pointerId);
    Object.keys(cards).forEach(function (key) { cards[key].classList.toggle("selected", key === id); }); event.preventDefault();
  });
  canvas.addEventListener("pointermove", function (event) {
    if (editMode) {
      var sketch = activeSketch(), local = sketchPoint(event); if (!sketch || !local) return;
      if (rectangleStart && rectangleStart.pointer === event.pointerId) { var rectSnap = snapSketchPoint(local, []); rectangleCurrent = { x: rectSnap.x, y: rectSnap.y }; drawSketches(); event.preventDefault(); return; }
      if (sketchTool === "line-tool" && linePoints.length && !sketchGesture) { lineCursor = snapSketchPoint(local, linePoints); drawSketches(); return; }
      if (!sketchGesture || sketchGesture.pointer !== event.pointerId) return;
      var gesture = sketchGesture; gesture.current = local; gesture.moved = gesture.moved || Math.hypot(local.x - gesture.start.x, local.y - gesture.start.y) > sketchTolerance() * 0.2;
      if (gesture.kind === "point" || gesture.kind === "curve") {
        sketch.geometry = clone(gesture.before); var dx = local.x - gesture.start.x, dy = local.y - gesture.start.y;
        if (state.snap) { dx = Math.round(dx); dy = Math.round(dy); }
        if (gesture.kind === "point") { var point = OS.point(sketch.geometry, gesture.id), targetX = point.x + dx, targetY = point.y + dy; OS.movePoint(sketch.geometry, gesture.id, targetX, targetY); }
        else OS.moveCurve(sketch.geometry, gesture.id, dx, dy);
      }
      drawSketches(); event.preventDefault(); return;
    }
    if (!drag || drag.pointer !== event.pointerId) return;
    pointerRay(event); var pose = poseFor(drag.id), point = planePoint(pose.z, new THREE.Vector3()); if (!point) return; var dx = point.x - drag.pointX, dy = point.y - drag.pointY;
    if (state.snap) { dx = Math.round(dx / state.pitch) * state.pitch; dy = Math.round(dy / state.pitch) * state.pitch; }
    pose.x = drag.startX + dx; pose.y = drag.startY + dy; var group = groupsById[pose.id]; if (group) group.position.set(pose.x, pose.y, pose.z); updateCardValues(); event.preventDefault();
  });
  function endPointer(event) {
    if (rectangleStart && rectangleStart.pointer === event.pointerId) {
      var sketch = activeSketch(), point = rectangleCurrent || sketchPoint(event), start = rectangleStart; rectangleStart = null; rectangleCurrent = null;
      if (sketch && point && Math.abs(point.x - start.x) > 0.01 && Math.abs(point.y - start.y) > 0.01) {
        var x0 = Math.min(start.x, point.x), x1 = Math.max(start.x, point.x), y0 = Math.min(start.y, point.y), y1 = Math.max(start.y, point.y);
        sketchMutate("Rectangle profile set · ready to extrude", function (geometry) { var replacement = OS.fromPolygon([[x0, y0], [x1, y0], [x1, y1], [x0, y1]]); geometry.version = replacement.version; geometry.points = replacement.points; geometry.curves = replacement.curves; geometry.constraints = replacement.constraints; return true; }); sketchTool = "select"; syncPalette();
      }
      event.preventDefault(); return;
    }
    if (editMode && sketchGesture && sketchGesture.pointer === event.pointerId) {
      var gesture = sketchGesture, active = activeSketch(); sketchGesture = null;
      if (gesture.kind === "marquee") { if (gesture.moved) { var ax = Math.min(gesture.start.x, gesture.current.x), ay = Math.min(gesture.start.y, gesture.current.y), bx = Math.max(gesture.start.x, gesture.current.x), by = Math.max(gesture.start.y, gesture.current.y), picked = [];
          OS.physicalPoints(active.geometry).forEach(function (point) { if (point.x >= ax && point.x <= bx && point.y >= ay && point.y <= by) picked.push({ type: "point", id: point.id }); }); if (!gesture.extend) sketchSelection = []; picked.forEach(function (row) { if (!selectedEntity(row.type, row.id)) sketchSelection.push(row); }); }
        drawSketches(); syncPalette(); event.preventDefault(); return; }
      if (gesture.moved) { var solved = OS.solve(active.geometry), compiled = solved && !solved.conflict && OS.compile(active.geometry); if (!compiled) { active.geometry = gesture.before; status("Move reverted: invalid or conflicted sketch", true); drawSketches(); } else { var stack = history(undoBySketch, active.id); stack.push(gesture.before); redoBySketch[active.id] = []; afterSketchChange(gesture.kind === "point" ? "Point moved" : "Edge moved"); } }
      event.preventDefault(); return;
    }
    if (!drag || drag.pointer !== event.pointerId) return; drag = null; controls.enabled = true; canvas.classList.remove("dragging"); setDirty(); rebuild(false);
  }
  canvas.addEventListener("pointerup", endPointer); canvas.addEventListener("pointercancel", endPointer);
  canvas.addEventListener("dblclick", function (event) { if (!editMode || sketchTool !== "select") return; var local = sketchPoint(event), curve = local && hitSketchCurve(local); if (!curve) return; event.preventDefault(); sketchMutate("Vertex inserted", function (geometry) { return !!OS.insertPoint(geometry, curve.id, Math.round(local.x), Math.round(local.y)); }); });
  canvas.addEventListener("contextmenu", function (event) { if (!editMode) return; var local = sketchPoint(event), point = local && hitSketchPoint(local), curve = point ? null : local && hitSketchCurve(local); if (!point && !curve) return; event.preventDefault(); sketchSelection = [{ type: point ? "point" : "curve", id: point ? point.id : curve.id }]; modifySketch("delete"); });
  window.addEventListener("keydown", function (event) {
    if (!editMode) return; var typing = /input|select|textarea/i.test(event.target.tagName || ""); if (typing) return;
    if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "z") { event.preventDefault(); return event.shiftKey ? redoSketch() : undoSketch(); }
    if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "y") { event.preventDefault(); return redoSketch(); }
    if (!event.ctrlKey && !event.metaKey && !event.altKey && event.key.toLowerCase() === "d") { event.preventDefault(); return sketchDimension(); }
    if (event.key === "Escape") { if (sketchTool !== "select") { sketchTool = "select"; linePoints = []; lineCursor = null; rectangleStart = null; rectangleCurrent = null; syncPalette(); drawSketches(); } else finishSketch(); }
    if (event.key === "Enter" && sketchTool === "line-tool") { sketchTool = "select"; linePoints = []; lineCursor = null; syncPalette(); drawSketches(); }
    if (event.key === "Delete" || event.key === "Backspace") { event.preventDefault(); modifySketch("delete"); }
  });
  canvas.addEventListener("wheel", function (event) {
    event.preventDefault(); event.stopImmediatePropagation();
    var step = boundedWheelStep(wheelGesture, event.deltaY, event.deltaMode, performance.now(), canvas.clientHeight); if (!step) return;
    if (editMode) { orthoHalf = Math.max(2, Math.min(2000, orthoHalf * Math.exp(step * 0.0008))); updateOrthoFrustum(); rebuildEditGrid(); drawSketches(); return; }
    if (!controls.enabled || drag) return;
    var offset = camera.position.clone().sub(controls.target), distance = offset.length(); if (!distance) return;
    var next = Math.max(controls.minDistance, Math.min(controls.maxDistance, distance * Math.exp(step * 0.00043))); camera.position.copy(controls.target).add(offset.multiplyScalar(next / distance)); controls.update();
  }, { capture: true, passive: false });

  $("#fit").onclick = fit;
  $("#top").onclick = topView;
  $("#view-2d").onclick = function () { setView("2d"); };
  $("#view-3d").onclick = function () { setView("3d"); };
  $("#save").onclick = saveDesign;
  $("#step").onclick = function () { download("step").catch(function (error) { status(error.message, true); }); };
  $("#stl").onclick = function () { download("stl").catch(function (error) { status(error.message, true); }); };
  $("#reset").onclick = function () { localStorage.removeItem(storeKey); location.reload(); };
  $("#assembly-json").onclick = function () {
    var output = { schema: "netlisp-system-assembly-v1", pitch_mm: state.pitch, ambient_c: state.ambient, instances: state.instances.map(function (pose) { return { id: pose.id, board: pose.board, x: pose.x, y: pose.y, z: pose.z, rotation: pose.rot, enabled: pose.on }; }) };
    var url = URL.createObjectURL(new Blob([JSON.stringify(output, null, 2) + "\n"], { type: "application/json" })); var link = document.createElement("a"); link.href = url; link.download = "assembly.json"; link.click(); setTimeout(function () { URL.revokeObjectURL(url); }, 0);
  };
  var twoDrag = null, twoWheelGesture = { last: -Infinity, total: 0 }, probe = $("#thermal-probe");
  function twoPoint(event) {
    var rect = thermalCanvas.getBoundingClientRect();
    var px = (event.clientX - rect.left) * thermalCanvas.width / Math.max(1, rect.width), py = (event.clientY - rect.top) * thermalCanvas.height / Math.max(1, rect.height);
    return { px: px, py: py, x: twoView.centerX + (px - thermalCanvas.width / 2) / twoView.scale, y: twoView.centerY + (py - thermalCanvas.height / 2) / twoView.scale };
  }
  function selectCard(id) {
    selected2d = id; Object.keys(cards).forEach(function (key) { cards[key].classList.toggle("selected", key === id); }); twoDirty = true;
  }
  function showProbe(event, point) {
    var hit = instanceAt(point.x, point.y); if (!hit) { probe.hidden = true; return; }
    var row = resultFor(hit.pose.id), field = row && thermalFields[fieldKey(hit.board, row.field_scenario)];
    var temperature = fieldTemperatureAt(field, hit.board, row, hit.local.x, hit.local.y);
    if (temperature == null && row) temperature = row.temperature_c;
    probe.textContent = hit.pose.id + (temperature == null ? " · no thermal field" : " · " + temperature.toFixed(1) + " °C");
    var rect = $("#viewport").getBoundingClientRect(); probe.style.left = event.clientX - rect.left + 12 + "px"; probe.style.top = event.clientY - rect.top + 12 + "px"; probe.hidden = false;
  }
  thermalCanvas.addEventListener("pointerdown", function (event) {
    var point = twoPoint(event), hit = instanceAt(point.x, point.y);
    if (hit) {
      twoDrag = { kind: "board", pointer: event.pointerId, id: hit.pose.id, startX: hit.pose.x, startY: hit.pose.y, pointX: point.x, pointY: point.y };
      selectCard(hit.pose.id);
    } else {
      twoDrag = { kind: "pan", pointer: event.pointerId, px: point.px, py: point.py, centerX: twoView.centerX, centerY: twoView.centerY };
    }
    probe.hidden = true; thermalCanvas.classList.add("dragging"); thermalCanvas.setPointerCapture(event.pointerId); event.preventDefault();
  });
  thermalCanvas.addEventListener("pointermove", function (event) {
    var point = twoPoint(event);
    if (!twoDrag || twoDrag.pointer !== event.pointerId) { showProbe(event, point); return; }
    if (twoDrag.kind === "pan") {
      twoView.centerX = twoDrag.centerX - (point.px - twoDrag.px) / twoView.scale; twoView.centerY = twoDrag.centerY - (point.py - twoDrag.py) / twoView.scale;
    } else {
      var pose = poseFor(twoDrag.id), dx = point.x - twoDrag.pointX, dy = point.y - twoDrag.pointY;
      if (state.snap) { dx = Math.round(dx / state.pitch) * state.pitch; dy = Math.round(dy / state.pitch) * state.pitch; }
      pose.x = twoDrag.startX + dx; pose.y = twoDrag.startY + dy; updateThermal(); updateCardValues();
    }
    twoDirty = true; event.preventDefault();
  });
  function endTwoDrag(event) {
    if (!twoDrag || twoDrag.pointer !== event.pointerId) return;
    var changedBoard = twoDrag.kind === "board"; twoDrag = null; thermalCanvas.classList.remove("dragging");
    if (changedBoard) { setDirty(); rebuild(false); } else twoDirty = true;
  }
  thermalCanvas.addEventListener("pointerup", endTwoDrag); thermalCanvas.addEventListener("pointercancel", endTwoDrag);
  thermalCanvas.addEventListener("pointerleave", function () { if (!twoDrag) probe.hidden = true; });
  thermalCanvas.addEventListener("wheel", function (event) {
    event.preventDefault(); var point = twoPoint(event);
    var step = boundedWheelStep(twoWheelGesture, event.deltaY, event.deltaMode, performance.now(), thermalCanvas.clientHeight); if (!step) return;
    var nextScale = Math.max(0.2, Math.min(40, twoView.scale * Math.exp(-step * 0.00043)));
    twoView.centerX = point.x - (point.px - thermalCanvas.width / 2) / nextScale; twoView.centerY = point.y - (point.py - thermalCanvas.height / 2) / nextScale;
    twoView.scale = nextScale; twoDirty = true;
  }, { passive: false });
  thermalCanvas.addEventListener("dblclick", fit2d);

  function resize3d() {
    var width = canvas.clientWidth, height = canvas.clientHeight, ratio = renderer.getPixelRatio();
    if (canvas.width !== Math.round(width * ratio) || canvas.height !== Math.round(height * ratio)) { renderer.setSize(width, height, false); camera.aspect = width / Math.max(height, 1); camera.updateProjectionMatrix(); updateOrthoFrustum(); }
  }
  function animate() {
    requestAnimationFrame(animate);
    if (viewMode === "3d") { resize3d(); if (!editMode) controls.update(); renderer.render(scene, activeCamera); }
    else if (resize2d() || twoDirty) draw2d();
  }

  if (!OS) status("Sketch engine failed to load", true); else { boot(); animate(); }
})(typeof window !== "undefined" ? window : globalThis);
