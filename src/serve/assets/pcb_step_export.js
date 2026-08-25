/* Fusion-compatible STEP writer for the PCB 3D viewer.
 *
 * Three.js gives the assembled scene to the browser as indexed triangle
 * buffers.  AP242 can store those buffers as tessellated presentation data,
 * but mechanical CAD translators commonly ignore mesh-only STEP geometry.
 * This writer instead promotes the triangles to the oldest interoperable
 * geometric subset: planar FACEs in CLOSED_SHELL / FACETED_BREP bodies.
 *
 * The module is dependency-free and CommonJS-compatible so its topology and
 * serialization behavior can also be exercised outside the browser.
 */
(function (root, factory) {
  var api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.PCBStepExport = api;
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";

  function stepText(s) {
    return "'" + String(s || "").replace(/[^\x20-\x7e]/g, "_").replace(/'/g, "''") + "'";
  }

  function stepReal(n) {
    n = +n;
    if (!isFinite(n) || Math.abs(n) < 5e-10) n = 0;
    var s = n.toFixed(6).replace(/0+$/, "").replace(/\.$/, "");
    return s.indexOf(".") < 0 ? s + "." : s;
  }

  function pointKey(point) {
    return stepReal(point[0]) + "," + stepReal(point[1]) + "," + stepReal(point[2]);
  }

  function edgeKey(a, b) { return a < b ? a + "," + b : b + "," + a; }

  function nonzeroTriangle(points, t) {
    var a = points[t[0]], b = points[t[1]], c = points[t[2]];
    var abx = b[0] - a[0], aby = b[1] - a[1], abz = b[2] - a[2];
    var acx = c[0] - a[0], acy = c[1] - a[1], acz = c[2] - a[2];
    var x = aby * acz - abz * acy;
    var y = abz * acx - abx * acz;
    var z = abx * acy - aby * acx;
    return x * x + y * y + z * z > 1e-20;
  }

  // Weld at the same six-decimal precision written to STEP.  This reconnects
  // the duplicated boundary vertices emitted by separate OCCT face meshes and
  // guarantees the topology refers to byte-identical Cartesian coordinates.
  function normalizeBody(body) {
    var points = [], pointStrings = [], pointMap = new Map(), remap = [];
    (body.points || []).forEach(function (p, i) {
      if (!p || p.length < 3 || !isFinite(+p[0]) || !isFinite(+p[1]) || !isFinite(+p[2])) {
        remap[i] = -1; return;
      }
      var key = pointKey(p), found = pointMap.get(key);
      if (found === undefined) {
        found = points.length;
        pointMap.set(key, found);
        var fields = key.split(",");
        points.push([+fields[0], +fields[1], +fields[2]]);
        pointStrings.push("(" + key + ")");
      }
      remap[i] = found;
    });

    var triangles = [];
    (body.triangles || []).forEach(function (source) {
      if (!source || source.length < 3) return;
      var a = remap[source[0]], b = remap[source[1]], c = remap[source[2]];
      if (a === undefined || b === undefined || c === undefined || a < 0 || b < 0 || c < 0) return;
      var t = [a, b, c];
      if (a !== b && b !== c && c !== a && nonzeroTriangle(points, t)) triangles.push(t);
    });
    return { name: body.name || "Body", points: points, pointStrings: pointStrings, triangles: triangles };
  }

  function find(parent, n) {
    while (parent[n] !== n) {
      parent[n] = parent[parent[n]];
      n = parent[n];
    }
    return n;
  }

  function unite(parent, a, b) {
    a = find(parent, a); b = find(parent, b);
    if (a !== b) parent[b] = a;
  }

  // Split one logical scene object into edge-connected shells.  Vendor STEP
  // models often contain several disjoint solids (package, pins, hardware),
  // and a FACETED_BREP must own exactly one connected outer shell.
  function splitComponents(body) {
    var triangles = body.triangles, parent = new Array(triangles.length), edges = new Map();
    for (var i = 0; i < triangles.length; i++) parent[i] = i;
    triangles.forEach(function (t, ti) {
      [[t[0], t[1]], [t[1], t[2]], [t[2], t[0]]].forEach(function (e) {
        var key = edgeKey(e[0], e[1]), first = edges.get(key);
        if (first === undefined) edges.set(key, ti);
        else unite(parent, ti, first);
      });
    });
    var groups = new Map();
    triangles.forEach(function (t, ti) {
      var root = find(parent, ti), group = groups.get(root);
      if (!group) { group = []; groups.set(root, group); }
      group.push(t);
    });
    return Array.from(groups.values());
  }

  function componentClosed(triangles) {
    if (triangles.length < 4) return false;
    var edges = new Map();
    triangles.forEach(function (t) {
      [[t[0], t[1]], [t[1], t[2]], [t[2], t[0]]].forEach(function (e) {
        var key = edgeKey(e[0], e[1]), state = edges.get(key);
        if (!state) { state = { count: 0, balance: 0 }; edges.set(key, state); }
        state.count++;
        state.balance += e[0] < e[1] ? 1 : -1;
      });
    });
    var closed = true;
    edges.forEach(function (e) { if (e.count !== 2 || e.balance !== 0) closed = false; });
    return closed;
  }

  function signedVolume(points, triangles) {
    var volume = 0;
    triangles.forEach(function (t) {
      var a = points[t[0]], b = points[t[1]], c = points[t[2]];
      volume += a[0] * (b[1] * c[2] - b[2] * c[1])
        + a[1] * (b[2] * c[0] - b[0] * c[2])
        + a[2] * (b[0] * c[1] - b[1] * c[0]);
    });
    return volume / 6;
  }

  function directionFields(x, y, z) {
    var length = Math.sqrt(x * x + y * y + z * z);
    return stepReal(x / length) + "," + stepReal(y / length) + "," + stepReal(z / length);
  }

  function prepareBodies(rawBodies) {
    var out = [];
    (rawBodies || []).forEach(function (raw) {
      var body = normalizeBody(raw);
      var components = splitComponents(body);
      components.forEach(function (triangles, index) {
        var closed = componentClosed(triangles);
        if (closed && signedVolume(body.points, triangles) < 0) {
          triangles = triangles.map(function (t) { return [t[0], t[2], t[1]]; });
        }
        out.push({
          name: body.name + (components.length > 1 ? " " + (index + 1) : ""),
          points: body.points,
          pointStrings: body.pointStrings,
          triangles: triangles,
          closed: closed
        });
      });
    });
    return out;
  }

  function fileName(name) {
    var base = String(name || "pcb").replace(/[^A-Za-z0-9._-]+/g, "-");
    base = base.replace(/^-+|-+$/g, "") || "pcb";
    return base + ".step";
  }

  function build(name, rawBodies, timestamp) {
    var bodies = prepareBodies(rawBodies);
    if (!bodies.length) throw new Error("no 3D geometry");
    var lines = [
      "ISO-10303-21;", "HEADER;",
      "FILE_DESCRIPTION(('Canopy PCB 3D faceted B-rep export'),'2;1');",
      "FILE_NAME(" + stepText(fileName(name)) + "," + stepText(timestamp || new Date().toISOString().slice(0, 19)) + ",('Canopy'),('Canopy'),'Canopy EDA','','');",
      "FILE_SCHEMA(('AP242_MANAGED_MODEL_BASED_3D_ENGINEERING_MIM_LF { 1 0 10303 442 1 1 4 }'));",
      "ENDSEC;", "DATA;",
      "#1=APPLICATION_CONTEXT('managed model based 3d engineering');",
      "#2=APPLICATION_PROTOCOL_DEFINITION('international standard','ap242_managed_model_based_3d_engineering',2016,#1);",
      "#3=PRODUCT_CONTEXT('',#1,'mechanical');",
      "#4=PRODUCT(" + stepText(name || "PCB assembly") + "," + stepText(name || "PCB assembly") + ",'',(#3));",
      "#5=PRODUCT_DEFINITION_FORMATION('','',#4);",
      "#6=PRODUCT_DEFINITION_CONTEXT('part definition',#1,'design');",
      "#7=PRODUCT_DEFINITION('design','',#5,#6);",
      "#8=PRODUCT_DEFINITION_SHAPE('','',#7);",
      "#9=(LENGTH_UNIT()NAMED_UNIT(*)SI_UNIT(.MILLI.,.METRE.));",
      "#10=(NAMED_UNIT(*)PLANE_ANGLE_UNIT()SI_UNIT($,.RADIAN.));",
      "#11=(NAMED_UNIT(*)SI_UNIT($,.STERADIAN.)SOLID_ANGLE_UNIT());",
      "#12=UNCERTAINTY_MEASURE_WITH_UNIT(LENGTH_MEASURE(1.E-6),#9,'distance_accuracy_value','confusion accuracy');",
      "#13=(GEOMETRIC_REPRESENTATION_CONTEXT(3)GLOBAL_UNCERTAINTY_ASSIGNED_CONTEXT((#12))GLOBAL_UNIT_ASSIGNED_CONTEXT((#9,#10,#11))REPRESENTATION_CONTEXT('','3D Context'));",
      "#14=CARTESIAN_POINT('',(0.,0.,0.));",
      "#15=DIRECTION('',(0.,0.,1.));",
      "#16=DIRECTION('',(1.,0.,0.));",
      "#17=AXIS2_PLACEMENT_3D('',#14,#15,#16);"
    ];
    var next = 18, itemIds = [], hasOpen = false;

    bodies.forEach(function (body) {
      var used = new Map();
      body.triangles.forEach(function (t) { t.forEach(function (p) { used.set(p, true); }); });
      var pointIds = new Map();
      used.forEach(function (_, p) {
        var id = next++;
        pointIds.set(p, id);
        lines.push("#" + id + "=CARTESIAN_POINT(''," + body.pointStrings[p] + ");");
      });
      var faceIds = [];
      body.triangles.forEach(function (t) {
        var a = body.points[t[0]], b = body.points[t[1]], c = body.points[t[2]];
        var abx = b[0] - a[0], aby = b[1] - a[1], abz = b[2] - a[2];
        var acx = c[0] - a[0], acy = c[1] - a[1], acz = c[2] - a[2];
        var nx = aby * acz - abz * acy;
        var ny = abz * acx - abx * acz;
        var nz = abx * acy - aby * acx;
        var loop = next++, bound = next++, normal = next++, reference = next++;
        var placement = next++, plane = next++, face = next++;
        lines.push("#" + loop + "=POLY_LOOP('',(#" + pointIds.get(t[0]) + ",#" + pointIds.get(t[1]) + ",#" + pointIds.get(t[2]) + "));");
        lines.push("#" + bound + "=FACE_OUTER_BOUND('',#" + loop + ",.T.);");
        lines.push("#" + normal + "=DIRECTION('',(" + directionFields(nx, ny, nz) + "));");
        lines.push("#" + reference + "=DIRECTION('',(" + directionFields(abx, aby, abz) + "));");
        lines.push("#" + placement + "=AXIS2_PLACEMENT_3D('',#" + pointIds.get(t[0]) + ",#" + normal + ",#" + reference + ");");
        lines.push("#" + plane + "=PLANE('',#" + placement + ");");
        lines.push("#" + face + "=ADVANCED_FACE('',(#" + bound + "),#" + plane + ",.T.);");
        faceIds.push(face);
      });
      var shell = next++;
      lines.push("#" + shell + "=" + (body.closed ? "CLOSED_SHELL" : "OPEN_SHELL") + "(" + stepText(body.name) + ",(\n#" + faceIds.join(",\n#") + "));");
      var item = next++;
      if (body.closed) lines.push("#" + item + "=FACETED_BREP(" + stepText(body.name) + ",#" + shell + ");");
      else {
        hasOpen = true;
        lines.push("#" + item + "=SHELL_BASED_SURFACE_MODEL(" + stepText(body.name) + ",(#" + shell + "));");
      }
      itemIds.push(item);
    });

    var representation = next++;
    lines.push("#" + representation + "=" + (hasOpen ? "SHAPE_REPRESENTATION" : "FACETED_BREP_SHAPE_REPRESENTATION") + "(" + stepText(name || "PCB assembly") + ",(#17,\n#" + itemIds.join(",\n#") + "),#13);");
    lines.push("#" + next + "=SHAPE_DEFINITION_REPRESENTATION(#8,#" + representation + ");", "ENDSEC;", "END-ISO-10303-21;", "");
    return lines.join("\n");
  }

  return { build: build, fileName: fileName, prepareBodies: prepareBodies, stepReal: stepReal };
});
