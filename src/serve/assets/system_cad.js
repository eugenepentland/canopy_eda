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
    var totalWatts = active.reduce(function (sum, instance) {
      return sum + totalBoardPower(boardByName[instance.board].thermal);
    }, 0);
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
      var temperature = rise == null ? null : ambientC + rise + (outletRise == null ? 0 : outletRise / 2);
      return {
        id: instance.id,
        board: instance.board,
        watts: totalBoardPower(board.thermal),
        coverage: coverage,
        velocity: velocity,
        temperature_c: temperature
      };
    });
    var hottest = results.reduce(function (best, row) {
      if (row.temperature_c == null) return best;
      return !best || row.temperature_c > best.temperature_c ? row : best;
    }, null);
    return { total_watts: totalWatts, total_flow_m3_s: totalFlow, outlet_rise_c: outletRise, hottest: hottest, instances: results };
  }

  var API = { rotatedBounds: rotatedBounds, overlapFraction: overlapFraction, totalBoardPower: totalBoardPower, solveSystem: solveSystem };
  if (typeof module !== "undefined" && module.exports) module.exports = API;
  root.SystemThermal = API;
  if (!root.document || !root.CAD_DATA) return;

  var D = root.CAD_DATA;
  var $ = function (selector) { return document.querySelector(selector); };
  var storeKey = "netlisp-system-thermal-v1:" + D.system;
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
        return {
          id: instance.id, board: instance.board, on: instance.on !== false,
          x: finite(instance.x, 0), y: finite(instance.y, 0), z: finite(instance.z, 5), rot: finite(instance.rot, 0)
        };
      });
    }
    return usable.map(function (board, index) {
      return { id: board.name, board: board.name, on: true, x: 0, y: 0, z: 5 + index * 14, rot: 0 };
    });
  }

  var defaults = {
    version: 1,
    ambient: finite(D.assembly && D.assembly.ambient_c, 25),
    pitch: finite(D.assembly && D.assembly.pitch_mm, 22),
    snap: true,
    clearance: 2.5, wall: 2.4, floor: 2, height: 48, lid: 2.4, explode: 24,
    instances: defaultInstances(), bosses: [], cutouts: []
  };
  var saved = null;
  try { saved = JSON.parse(localStorage.getItem(storeKey) || "null"); } catch (_) {}
  var state = Object.assign({}, defaults, saved && saved.version === 1 ? saved : {});
  state.instances = defaults.instances.map(function (base) {
    var prior = saved && saved.version === 1 && Array.isArray(saved.instances) ? saved.instances.find(function (value) { return value.id === base.id && value.board === base.board; }) : null;
    return Object.assign({}, base, prior || {});
  });
  state.bosses = Array.isArray(state.bosses) ? state.bosses : [];
  state.cutouts = Array.isArray(state.cutouts) ? state.cutouts : [];
  var dirty = !!(saved && saved.version === 1);

  function clone(value) { return JSON.parse(JSON.stringify(value)); }
  function status(message, isError) {
    var node = $("#save-status"); node.textContent = message || ""; node.className = isError ? "error" : "";
  }
  function persist() { try { localStorage.setItem(storeKey, JSON.stringify(state)); } catch (_) {} }
  function setDirty() { dirty = true; status(D.can_write ? "Unsaved changes" : "Local draft"); persist(); }

  ["ambient", "pitch", "clearance", "wall", "floor", "height", "lid", "explode"].forEach(function (key) { $("#" + key).value = state[key]; });
  $("#snap").checked = state.snap !== false;

  var cards = {};
  var host = $("#boards");
  state.instances.forEach(function (pose) {
    var board = boardByName[pose.board];
    var item = document.createElement("div");
    item.className = "board";
    item.dataset.instance = pose.id;
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
    host.appendChild(item); cards[pose.id] = item;
  });
  D.boards.filter(function (board) { return board.error; }).forEach(function (board) {
    var item = document.createElement("div"); item.className = "board board-error"; item.textContent = board.name + ": could not import " + board.layout + " (" + board.error + ")"; host.appendChild(item);
  });
  if (!usable.length) { $("#empty").style.display = "block"; $("#empty").textContent = "No saved PCB layouts could be imported."; }

  function numberField(value, key, step) {
    return '<label>' + key.replace(/_/g, " ") + '<input type="number" data-key="' + key + '" step="' + (step || 0.5) + '" value="' + value + '"></label>';
  }
  function renderBosses() {
    var target = $("#bosses"); target.textContent = "";
    state.bosses.forEach(function (boss, index) {
      var row = document.createElement("div"); row.className = "feature"; row.dataset.index = index;
      row.innerHTML = '<div class="feature-title"><strong>Boss ' + (index + 1) + '</strong><button class="remove" title="Remove boss">×</button></div><div class="feature-grid">' + numberField(boss.x, "x") + numberField(boss.y, "y") + numberField(boss.outer_diameter, "outer_diameter", 0.1) + numberField(boss.hole_diameter, "hole_diameter", 0.1) + numberField(boss.height, "height", 0.1) + '</div>';
      target.appendChild(row);
    });
  }
  function renderCutouts() {
    var target = $("#cutouts"); target.textContent = "";
    state.cutouts.forEach(function (cutout, index) {
      var row = document.createElement("div"); row.className = "feature"; row.dataset.index = index;
      var options = ["front", "back", "left", "right"].map(function (wall) { return '<option' + (wall === cutout.wall ? ' selected' : '') + '>' + wall + '</option>'; }).join("");
      row.innerHTML = '<div class="feature-title"><strong>Cutout ' + (index + 1) + '</strong><button class="remove" title="Remove cutout">×</button></div><div class="feature-grid"><label>wall<select data-key="wall">' + options + '</select></label>' + numberField(cutout.center, "center") + numberField(cutout.width, "width") + numberField(cutout.bottom, "bottom") + numberField(cutout.height, "height") + '</div>';
      target.appendChild(row);
    });
  }
  function applyMechanical(savedDocument) {
    if (!savedDocument) return;
    var settings = savedDocument.settings || {};
    state.clearance = finite(settings.clearance, state.clearance); state.wall = finite(settings.wall, state.wall); state.floor = finite(settings.floor, state.floor);
    state.height = finite(settings.height, state.height); state.lid = finite(settings.lid_thickness, state.lid); state.explode = finite(settings.lid_explode, state.explode);
    state.instances.forEach(function (pose) {
      var stored = (savedDocument.boards || []).find(function (board) { return board.name === pose.id; });
      if (!stored && state.instances.filter(function (candidate) { return candidate.board === pose.board; }).length === 1) stored = (savedDocument.boards || []).find(function (board) { return board.name === pose.board; });
      if (!stored) return;
      pose.on = stored.enabled !== false; pose.x = finite(stored.x, pose.x); pose.y = finite(stored.y, pose.y); pose.z = finite(stored.z, pose.z); pose.rot = finite(stored.rotation, pose.rot);
    });
    state.bosses = Array.isArray(savedDocument.bosses) ? clone(savedDocument.bosses) : [];
    state.cutouts = Array.isArray(savedDocument.cutouts) ? clone(savedDocument.cutouts) : [];
  }
  function syncInputs() {
    ["ambient", "pitch", "clearance", "wall", "floor", "height", "lid", "explode"].forEach(function (key) { $("#" + key).value = state[key]; });
    $("#snap").checked = state.snap !== false;
    state.instances.forEach(function (pose) { if (cards[pose.id]) cards[pose.id].querySelector(".enabled").checked = pose.on; });
    renderBosses(); renderCutouts(); updateCardValues();
  }

  var canvas = $("#canvas");
  var renderer = new THREE.WebGLRenderer({ canvas: canvas, antialias: true, alpha: true });
  renderer.setPixelRatio(Math.min(devicePixelRatio || 1, 2));
  renderer.outputEncoding = THREE.sRGBEncoding;
  var scene = new THREE.Scene(), camera = new THREE.PerspectiveCamera(38, 1, 0.1, 5000);
  camera.up.set(0, 0, 1); camera.position.set(180, -210, 150);
  var controls = new THREE.OrbitControls(camera, canvas); controls.enableDamping = true; controls.dampingFactor = 0.08; controls.target.set(0, 0, 10);
  scene.add(new THREE.HemisphereLight(0xd8e9ff, 0x182338, 1.25));
  var sun = new THREE.DirectionalLight(0xffffff, 0.85); sun.position.set(-80, -100, 160); scene.add(sun);
  var grid = new THREE.GridHelper(500, 50, 0x35506f, 0x23354d); grid.rotation.x = Math.PI / 2; grid.position.z = -0.02; scene.add(grid);
  var boardsModel = new THREE.Group(), caseModel = new THREE.Group(), meshSequence = 0;
  scene.add(boardsModel); scene.add(caseModel);
  var lastBounds = { width: 80, depth: 60 }, thermalResult = null, thermalLoading = true, groupsById = {};

  function material(color, opacity) {
    return new THREE.MeshStandardMaterial({ color: color, roughness: 0.72, metalness: 0.04, transparent: opacity < 1, opacity: opacity, side: THREE.DoubleSide, depthWrite: opacity > 0.7 });
  }
  function box(group, width, depth, height, x, y, z, mat) {
    var mesh = new THREE.Mesh(new THREE.BoxGeometry(width, depth, height), mat); mesh.position.set(x, y, z); group.add(mesh); return mesh;
  }
  function clearGroup(group) {
    while (group.children.length) {
      var object = group.children[group.children.length - 1]; group.remove(object);
      object.traverse(function (child) {
        if (child.geometry) child.geometry.dispose();
        if (child.material) (Array.isArray(child.material) ? child.material : [child.material]).forEach(function (mat) { mat.dispose(); });
      });
    }
  }
  function poseFor(id) { return state.instances.find(function (pose) { return pose.id === id; }); }
  function resultFor(id) { return thermalResult && thermalResult.instances.find(function (row) { return row.id === id; }); }
  function temperatureColor(row) {
    if (!row || row.temperature_c == null) return 0x356276;
    var rise = row.temperature_c - state.ambient;
    if (rise < 18) return 0x22a879;
    if (rise < 40) return 0xe0a93b;
    return 0xdf5b57;
  }
  function attachCooling(group, board) {
    var cooling = board.cooling || {}, sink = cooling.heatsink, fan = cooling.fan;
    if (sink) {
      var down = sink.side === "bottom" ? -1 : 1;
      var contactZ = down < 0 ? -sink.pad_mm - sink.base_mm / 2 : board.thickness + sink.pad_mm + sink.base_mm / 2;
      box(group, sink.w, sink.d, sink.base_mm, sink.x, sink.y, contactZ, material(0xa9b1bb, 0.92));
      if (sink.shape === "stepped") {
        var lowerZ = down < 0 ? -sink.pad_mm - sink.base_mm - sink.lower_h / 2 : board.thickness + sink.pad_mm + sink.base_mm + sink.lower_h / 2;
        box(group, sink.lower_w, sink.lower_d, sink.lower_h, sink.x, sink.y, lowerZ, material(0x7f8b99, 0.72));
      }
    }
    if (fan) {
      var fanDown = fan.side === "bottom" ? -1 : 1;
      var fanZ = fanDown < 0 ? -fan.distance_mm - 2 : board.thickness + fan.distance_mm + 2;
      var frame = material(0x313843, 0.95), flow = material(0x62a5ff, 0.18), rim = 5, thick = 4;
      box(group, fan.w, rim, thick, fan.x, fan.y - (fan.d - rim) / 2, fanZ, frame);
      box(group, fan.w, rim, thick, fan.x, fan.y + (fan.d - rim) / 2, fanZ, frame);
      box(group, rim, fan.d - 2 * rim, thick, fan.x - (fan.w - rim) / 2, fan.y, fanZ, frame);
      box(group, rim, fan.d - 2 * rim, thick, fan.x + (fan.w - rim) / 2, fan.y, fanZ, frame);
      box(group, Math.max(1, fan.w - 2 * rim), Math.max(1, fan.d - 2 * rim), 0.4, fan.x, fan.y, fanZ, flow);
    }
  }
  function drawBoard(board, pose) {
    var group = new THREE.Group(), shape = new THREE.Shape(), points = board.outline, row = resultFor(pose.id);
    shape.moveTo(points[0][0], points[0][1]);
    for (var i = 1; i < points.length; i++) shape.lineTo(points[i][0], points[i][1]);
    shape.closePath();
    var boardMesh = new THREE.Mesh(new THREE.ExtrudeGeometry(shape, { depth: board.thickness, bevelEnabled: false }), material(temperatureColor(row), 1));
    boardMesh.userData.instanceId = pose.id; boardMesh.userData.draggable = true; group.add(boardMesh);
    var compMat = material(0xbec6cf, 1);
    board.parts.forEach(function (part) {
      var height = part.bottom ? 1.2 : 2.2, z = part.bottom ? -height / 2 : board.thickness + height / 2;
      var mesh = box(group, part.w, part.d, height, part.x, part.y, z, compMat); mesh.rotation.z = part.rot * Math.PI / 180;
    });
    attachCooling(group, board);
    group.position.set(pose.x, pose.y, pose.z); group.rotation.z = pose.rot * Math.PI / 180; boardsModel.add(group); groupsById[pose.id] = group;
  }
  function occupied() {
    var minx = Infinity, miny = Infinity, maxx = -Infinity, maxy = -Infinity;
    state.instances.forEach(function (pose) {
      var board = boardByName[pose.board]; if (!board || !pose.on) return;
      var bounds = rotatedBounds(board.width, board.depth, pose, 0, 0);
      minx = Math.min(minx, bounds.minx); maxx = Math.max(maxx, bounds.maxx); miny = Math.min(miny, bounds.miny); maxy = Math.max(maxy, bounds.maxy);
      var sink = board.cooling && board.cooling.heatsink;
      if (sink && sink.shape === "stepped") {
        bounds = rotatedBounds(sink.lower_w, sink.lower_d, pose, sink.x, sink.y);
        minx = Math.min(minx, bounds.minx); maxx = Math.max(maxx, bounds.maxx); miny = Math.min(miny, bounds.miny); maxy = Math.max(maxy, bounds.maxy);
      }
      var fan = board.cooling && board.cooling.fan;
      if (fan) {
        bounds = rotatedBounds(fan.w, fan.d, pose, fan.x, fan.y);
        minx = Math.min(minx, bounds.minx); maxx = Math.max(maxx, bounds.maxx); miny = Math.min(miny, bounds.miny); maxy = Math.max(maxy, bounds.maxy);
      }
    });
    if (!isFinite(minx)) return { width: 80, depth: 60 };
    return { width: Math.max(1, 2 * Math.max(Math.abs(minx), Math.abs(maxx))), depth: Math.max(1, 2 * Math.max(Math.abs(miny), Math.abs(maxy))) };
  }
  function mechanicalDocument() {
    return {
      schema: "netlisp-mechanical-v1",
      occupied: occupied(),
      settings: { clearance: state.clearance, wall: state.wall, floor: state.floor, height: state.height, lid_thickness: state.lid, lid_explode: state.explode },
      boards: state.instances.map(function (pose) { return { name: pose.id, enabled: pose.on, x: pose.x, y: pose.y, z: pose.z, rotation: pose.rot }; }),
      bosses: clone(state.bosses), cutouts: clone(state.cutouts)
    };
  }
  function kernelMesh(recipe, mat) {
    var positions = [];
    recipe.triangles.forEach(function (triangle) { triangle.forEach(function (index) { var point = recipe.points[index]; positions.push(point[0], point[1], point[2]); }); });
    var geometry = new THREE.BufferGeometry(); geometry.setAttribute("position", new THREE.Float32BufferAttribute(positions, 3)); geometry.computeVertexNormals(); return new THREE.Mesh(geometry, mat);
  }
  async function rebuildCase() {
    var sequence = ++meshSequence, response = await fetch("/api/systems/" + encodeURIComponent(D.system) + "/cad/mesh", {
      method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(mechanicalDocument())
    });
    if (!response.ok) throw new Error(await response.text());
    var recipe = await response.json(); if (sequence !== meshSequence) return;
    clearGroup(caseModel); caseModel.add(kernelMesh(recipe.base, material(0x3478bd, 0.32)));
    (recipe.bosses || []).forEach(function (boss) { caseModel.add(kernelMesh(boss, material(0x3478bd, 0.5))); });
    var lid = kernelMesh(recipe.lid, material(0x76b4e6, 0.38)); lid.position.z = state.explode; caseModel.add(lid);
    $("#dimensions").textContent = "Equipment envelope " + lastBounds.width.toFixed(1) + " × " + lastBounds.depth.toFixed(1) + " mm · case " + recipe.dimensions.outer_width.toFixed(1) + " × " + recipe.dimensions.outer_depth.toFixed(1) + " × " + (state.height + state.lid).toFixed(1) + " mm";
  }
  async function download(format) {
    var response = await fetch("/api/systems/" + encodeURIComponent(D.system) + "/cad/export?part=assembly&format=" + format, {
      method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(mechanicalDocument())
    });
    if (!response.ok) throw new Error(await response.text());
    var blob = await response.blob(), link = document.createElement("a"); link.href = URL.createObjectURL(blob); link.download = D.system + "-enclosure-assembly." + format; link.click(); setTimeout(function () { URL.revokeObjectURL(link.href); }, 1000);
  }
  function updateCardValues() {
    state.instances.forEach(function (pose) {
      var card = cards[pose.id]; if (!card) return;
      ["x", "y", "z", "rot"].forEach(function (key) { var input = card.querySelector('[data-key="' + key + '"]'); if (document.activeElement !== input) input.value = Number(pose[key].toFixed(3)); });
      var row = resultFor(pose.id), temp = card.querySelector(".temp");
      temp.textContent = row && row.temperature_c != null ? row.temperature_c.toFixed(1) + " °C" : "no thermal model";
      temp.className = "temp " + (!row || row.temperature_c == null ? "unknown" : row.temperature_c - state.ambient < 18 ? "cool" : row.temperature_c - state.ambient < 40 ? "warm" : "hot");
    });
  }
  function updateThermal() {
    thermalResult = solveSystem(usable, state.instances, state.ambient);
    var summary = $("#thermal-summary"), hot = thermalResult.hottest;
    if (thermalLoading) summary.textContent = "Loading board thermal models…";
    else if (!hot) summary.textContent = "No solved board thermal scenarios are available.";
    else summary.innerHTML = '<strong>' + hot.temperature_c.toFixed(1) + ' °C</strong><span>hottest board hotspot · ' + hot.id + '</span><strong>' + thermalResult.total_watts.toFixed(2) + ' W</strong><span>annotated load</span><strong>' + (thermalResult.outlet_rise_c == null ? '—' : thermalResult.outlet_rise_c.toFixed(1) + ' °C') + '</strong><span>mixed outlet rise</span>';
    updateCardValues();
  }
  function rebuild(fetchCase) {
    updateThermal(); clearGroup(boardsModel); groupsById = {};
    state.instances.forEach(function (pose) { var board = boardByName[pose.board]; if (board && pose.on) drawBoard(board, pose); });
    lastBounds = occupied(); if (dirty) persist();
    if (fetchCase !== false) rebuildCase().catch(function (error) { $("#dimensions").textContent = "Kernel error: " + error.message; });
  }
  async function loadThermal() {
    await Promise.all(usable.map(async function (board) {
      try {
        var query = new URLSearchParams({ ambient: "25" });
        if (board.layout !== "blessed") query.set("layout", board.layout);
        var response = await fetch("/api/thermal/" + encodeURIComponent(board.name) + "?" + query);
        if (response.ok) board.thermal = await response.json();
      } catch (_) {}
    }));
    thermalLoading = false; rebuild(false);
  }
  function fit() {
    var span = Math.max(lastBounds.width + 2 * state.clearance + 2 * state.wall, lastBounds.depth + 2 * state.clearance + 2 * state.wall, state.height + state.explode + state.lid, 30);
    controls.target.set(0, 0, state.height / 2); camera.position.set(span * 0.95, -span * 1.15, span * 0.8); camera.near = Math.max(0.05, span / 1000); camera.far = span * 30; camera.updateProjectionMatrix(); controls.update();
  }
  async function saveDesign() {
    if (!D.can_write) return;
    $("#save").disabled = true; status("Saving…");
    try {
      var response = await fetch(documentUrl, { method: "PUT", headers: { "content-type": "application/json", "x-netlisp-review": "1" }, body: JSON.stringify(mechanicalDocument()) });
      if (!response.ok) { var message = await response.text(); try { message = JSON.parse(message).error || message; } catch (_) {} throw new Error(message); }
      await response.json(); dirty = false; localStorage.removeItem(storeKey); status("Saved");
    } catch (error) { status("Save failed: " + error.message, true); }
    finally { $("#save").disabled = !D.can_write; }
  }
  function autoBosses() {
    var found = [];
    state.instances.forEach(function (pose) {
      var board = boardByName[pose.board]; if (!board || !pose.on) return;
      var angle = pose.rot * Math.PI / 180, c = Math.cos(angle), s = Math.sin(angle);
      (board.holes || []).filter(function (hole) { return hole.diameter >= 2; }).forEach(function (hole) {
        var x = pose.x + hole.x * c - hole.y * s, y = pose.y + hole.x * s + hole.y * c;
        if (found.some(function (boss) { return Math.hypot(boss.x - x, boss.y - y) < 0.25; })) return;
        found.push({ x: Number(x.toFixed(3)), y: Number(y.toFixed(3)), outer_diameter: Number(Math.max(5.2, hole.diameter + 2.4).toFixed(2)), hole_diameter: Number(Math.min(3.2, Math.max(1.6, hole.diameter - 0.2)).toFixed(2)), height: Number(Math.max(0.5, pose.z - state.floor).toFixed(2)) });
      });
    });
    state.bosses = found; renderBosses(); setDirty(); rebuild(); if (!found.length) status("No mounting-size NPTH holes found", true);
  }
  function featureInput(kind, event) {
    var row = event.target.closest(".feature"); if (!row) return;
    var list = state[kind], index = Number(row.dataset.index);
    if (event.target.classList.contains("remove")) { list.splice(index, 1); kind === "bosses" ? renderBosses() : renderCutouts(); }
    else if (event.target.dataset.key) list[index][event.target.dataset.key] = event.target.dataset.key === "wall" ? event.target.value : finite(event.target.value, 0);
    else return;
    setDirty(); rebuild();
  }
  async function boot() {
    var serverDocument = null, loadError = null;
    try {
      var response = await fetch(documentUrl, { headers: { accept: "application/json" } });
      if (!response.ok) throw new Error(await response.text());
      var value = await response.json(); serverDocument = value.document;
    } catch (error) { loadError = error; }
    if (!dirty) applyMechanical(serverDocument);
    syncInputs();
    if (loadError) status("Could not load saved design: " + loadError.message, true);
    else if (dirty) status("Recovered local draft"); else if (serverDocument) status("Saved"); else status("New design");
    $("#save").disabled = !D.can_write; rebuild(); fit(); loadThermal();
  }

  host.addEventListener("input", function (event) {
    var card = event.target.closest(".board"), pose = card && poseFor(card.dataset.instance); if (!pose) return;
    if (event.target.classList.contains("enabled")) pose.on = event.target.checked;
    else if (event.target.dataset.key) pose[event.target.dataset.key] = finite(event.target.value, 0);
    setDirty(); rebuild();
  });
  ["ambient", "pitch", "clearance", "wall", "floor", "height", "lid", "explode"].forEach(function (key) {
    $("#" + key).addEventListener("input", function () { state[key] = finite(this.value, defaults[key]); if (state.floor >= state.height) state.height = state.floor + 0.5; setDirty(); rebuild(); });
  });
  $("#snap").addEventListener("change", function () { state.snap = this.checked; setDirty(); });
  $("#fit").onclick = fit;
  $("#save").onclick = saveDesign;
  $("#step").onclick = function () { download("step").catch(function (error) { status(error.message, true); }); };
  $("#stl").onclick = function () { download("stl").catch(function (error) { status(error.message, true); }); };
  $("#reset").onclick = function () { localStorage.removeItem(storeKey); location.reload(); };
  $("#auto-bosses").onclick = autoBosses;
  $("#add-boss").onclick = function () { state.bosses.push({ x: 0, y: 0, outer_diameter: 6, hole_diameter: 2.8, height: Math.max(0.5, 5 - state.floor) }); renderBosses(); setDirty(); rebuild(); };
  $("#add-cutout").onclick = function () { state.cutouts.push({ wall: "front", center: 0, width: 12, bottom: Math.max(state.floor, 5), height: 8 }); renderCutouts(); setDirty(); rebuild(); };
  $("#bosses").addEventListener("input", function (event) { featureInput("bosses", event); });
  $("#bosses").addEventListener("click", function (event) { featureInput("bosses", event); });
  $("#cutouts").addEventListener("input", function (event) { featureInput("cutouts", event); });
  $("#cutouts").addEventListener("click", function (event) { featureInput("cutouts", event); });
  $("#assembly-json").onclick = function () {
    var output = { schema: "netlisp-system-assembly-v1", pitch_mm: state.pitch, ambient_c: state.ambient, instances: state.instances.map(function (pose) { return { id: pose.id, board: pose.board, x: pose.x, y: pose.y, z: pose.z, rotation: pose.rot, enabled: pose.on }; }) };
    var url = URL.createObjectURL(new Blob([JSON.stringify(output, null, 2) + "\n"], { type: "application/json" }));
    var link = document.createElement("a"); link.href = url; link.download = "assembly.json"; link.click(); setTimeout(function () { URL.revokeObjectURL(url); }, 0);
  };

  var raycaster = new THREE.Raycaster(), pointer = new THREE.Vector2(), drag = null;
  function pointerRay(event) {
    var rect = canvas.getBoundingClientRect(); pointer.x = (event.clientX - rect.left) / rect.width * 2 - 1; pointer.y = -(event.clientY - rect.top) / rect.height * 2 + 1; raycaster.setFromCamera(pointer, camera);
  }
  function planePoint(z, target) { return raycaster.ray.intersectPlane(new THREE.Plane(new THREE.Vector3(0, 0, 1), -z), target); }
  canvas.addEventListener("pointerdown", function (event) {
    pointerRay(event); var hit = raycaster.intersectObjects(boardsModel.children, true).find(function (candidate) { return candidate.object.userData.draggable; }); if (!hit) return;
    var id = hit.object.userData.instanceId, pose = poseFor(id); if (!pose) return;
    var point = planePoint(pose.z, new THREE.Vector3()); if (!point) return;
    drag = { id: id, pointer: event.pointerId, startX: pose.x, startY: pose.y, pointX: point.x, pointY: point.y };
    controls.enabled = false; canvas.classList.add("dragging"); canvas.setPointerCapture(event.pointerId);
    Object.keys(cards).forEach(function (key) { cards[key].classList.toggle("selected", key === id); });
    event.preventDefault();
  });
  canvas.addEventListener("pointermove", function (event) {
    if (!drag || drag.pointer !== event.pointerId) return;
    pointerRay(event); var pose = poseFor(drag.id), point = planePoint(pose.z, new THREE.Vector3()); if (!point) return;
    var dx = point.x - drag.pointX, dy = point.y - drag.pointY;
    if (state.snap) { dx = Math.round(dx / state.pitch) * state.pitch; dy = Math.round(dy / state.pitch) * state.pitch; }
    pose.x = drag.startX + dx; pose.y = drag.startY + dy;
    var group = groupsById[pose.id]; if (group) group.position.set(pose.x, pose.y, pose.z);
    updateCardValues(); event.preventDefault();
  });
  function endDrag(event) {
    if (!drag || drag.pointer !== event.pointerId) return;
    drag = null; controls.enabled = true; canvas.classList.remove("dragging"); setDirty(); rebuild(true);
  }
  canvas.addEventListener("pointerup", endDrag); canvas.addEventListener("pointercancel", endDrag);

  function resize() {
    var width = canvas.clientWidth, height = canvas.clientHeight, ratio = renderer.getPixelRatio();
    if (canvas.width !== Math.round(width * ratio) || canvas.height !== Math.round(height * ratio)) { renderer.setSize(width, height, false); camera.aspect = width / Math.max(height, 1); camera.updateProjectionMatrix(); }
  }
  function animate() { requestAnimationFrame(animate); resize(); controls.update(); renderer.render(scene, camera); }

  boot(); animate();
})(typeof window !== "undefined" ? window : globalThis);
