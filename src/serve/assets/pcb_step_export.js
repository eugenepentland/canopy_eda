/* Fusion-compatible STEP writer for the PCB 3D viewer.
 *
 * Three.js gives the assembled scene to the browser as indexed triangle
 * buffers.  AP242 can store those buffers as tessellated presentation data,
 * but mechanical CAD translators commonly ignore mesh-only STEP geometry.
 * This writer instead promotes the triangles to the oldest interoperable
 * geometric subset: planar FACE_SURFACEs in CLOSED_SHELL / FACETED_BREP
 * bodies. Open surface fragments are omitted because POLY_LOOP is valid in a
 * faceted B-rep but not in AP242's manifold-surface representation; one
 * imperfect vendor fragment therefore cannot invalidate or hide every solid.
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

  function colorValue(color) {
    if (!color || color.length < 3) return null;
    var out = [Math.max(0, Math.min(1, +color[0])), Math.max(0, Math.min(1, +color[1])), Math.max(0, Math.min(1, +color[2]))];
    return out.every(isFinite) ? out : null;
  }

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

    var triangles = [], triangleColors = [];
    (body.triangles || []).forEach(function (source, sourceIndex) {
      if (!source || source.length < 3) return;
      var a = remap[source[0]], b = remap[source[1]], c = remap[source[2]];
      if (a === undefined || b === undefined || c === undefined || a < 0 || b < 0 || c < 0) return;
      var t = [a, b, c];
      if (a !== b && b !== c && c !== a && nonzeroTriangle(points, t)) {
        triangles.push(t);
        triangleColors.push(colorValue((body.triangleColors || [])[sourceIndex]));
      }
    });
    return {
      name: body.name || "Body", points: points, pointStrings: pointStrings,
      triangles: triangles, triangleColors: triangleColors, color: colorValue(body.color)
    };
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
      group.push(ti);
    });
    return Array.from(groups.values()).map(function (indices) {
      return {
        triangles: indices.map(function (i) { return triangles[i]; }),
        triangleColors: indices.map(function (i) { return body.triangleColors[i]; })
      };
    });
  }

  // Three.js ExtrudeGeometry can describe a closed manifold with inconsistent
  // local winding at cap/wall seams.  Closure is an incidence property first:
  // every undirected edge must have two faces.  Then propagate flip parity
  // across the adjacency graph so each shared edge is traversed in opposite
  // directions.  A parity contradiction is genuinely non-orientable.
  function orientClosedComponent(points, triangles) {
    if (triangles.length < 4) return { closed: false, triangles: triangles };
    var edges = new Map();
    triangles.forEach(function (t, ti) {
      [[t[0], t[1]], [t[1], t[2]], [t[2], t[0]]].forEach(function (e) {
        var key = edgeKey(e[0], e[1]), state = edges.get(key);
        if (!state) { state = []; edges.set(key, state); }
        state.push({ triangle: ti, direction: e[0] < e[1] ? 1 : -1 });
      });
    });
    var manifold = true;
    edges.forEach(function (edge) { if (edge.length !== 2) manifold = false; });
    if (!manifold) return { closed: false, triangles: triangles };

    var neighbours = triangles.map(function () { return []; });
    edges.forEach(function (edge) {
      var a = edge[0], b = edge[1];
      var differ = a.direction === b.direction ? 1 : 0;
      neighbours[a.triangle].push([b.triangle, differ]);
      neighbours[b.triangle].push([a.triangle, differ]);
    });
    var flips = new Array(triangles.length).fill(-1), orientable = true;
    for (var seed = 0; seed < triangles.length && orientable; seed++) {
      if (flips[seed] !== -1) continue;
      flips[seed] = 0;
      var queue = [seed];
      for (var q = 0; q < queue.length && orientable; q++) {
        var here = queue[q];
        neighbours[here].forEach(function (link) {
          var expected = flips[here] ^ link[1];
          if (flips[link[0]] === -1) { flips[link[0]] = expected; queue.push(link[0]); }
          else if (flips[link[0]] !== expected) orientable = false;
        });
      }
    }
    if (!orientable) return { closed: false, triangles: triangles };
    var oriented = triangles.map(function (t, i) { return flips[i] ? [t[0], t[2], t[1]] : t.slice(); });
    var volume = signedVolume(points, oriented), min = [Infinity, Infinity, Infinity], max = [-Infinity, -Infinity, -Infinity];
    oriented.forEach(function (t) { t.forEach(function (pointIndex) {
      var point = points[pointIndex];
      for (var axis = 0; axis < 3; axis++) {
        min[axis] = Math.min(min[axis], point[axis]); max[axis] = Math.max(max[axis], point[axis]);
      }
    }); });
    var dx = max[0] - min[0], dy = max[1] - min[1], dz = max[2] - min[2];
    var scale = Math.max(dx, dy, dz), volumeTolerance = Math.max(1e-15, scale * scale * scale * 1e-12);
    if (Math.abs(volume) <= volumeTolerance) return { closed: false, triangles: oriented };
    if (volume < 0) oriented = oriented.map(function (t) { return [t[0], t[2], t[1]]; });
    return { closed: true, triangles: oriented };
  }

  function signedVolume(points, triangles) {
    var volume = 0, origin = points[triangles[0][0]];
    triangles.forEach(function (t) {
      var sourceA = points[t[0]], sourceB = points[t[1]], sourceC = points[t[2]];
      var a = [sourceA[0] - origin[0], sourceA[1] - origin[1], sourceA[2] - origin[2]];
      var b = [sourceB[0] - origin[0], sourceB[1] - origin[1], sourceB[2] - origin[2]];
      var c = [sourceC[0] - origin[0], sourceC[1] - origin[1], sourceC[2] - origin[2]];
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
      components.forEach(function (component, index) {
        var oriented = orientClosedComponent(body.points, component.triangles);
        out.push({
          name: body.name + (components.length > 1 ? " " + (index + 1) : ""),
          points: body.points,
          pointStrings: body.pointStrings,
          triangles: oriented.triangles,
          triangleColors: component.triangleColors,
          color: body.color,
          closed: oriented.closed
        });
      });
    });
    return out;
  }

  function fileName(name, fabricationId) {
    var base = String(name || "pcb").replace(/[^A-Za-z0-9._-]+/g, "-");
    base = base.replace(/^-+|-+$/g, "") || "pcb";
    var id = String(fabricationId || "").trim().replace(/^ID[\s_-]*/i, "");
    if (/^[0-9a-f]{8}$/i.test(id)) base += "_ID_" + id.toUpperCase();
    return base + ".step";
  }

  function chunkItems(items, faceBudget) {
    var chunks = [], current = [], faces = 0;
    (items || []).forEach(function (item) {
      var itemFaces = Math.max(0, +item.faces || 0);
      if (current.length && faces + itemFaces > faceBudget) {
        chunks.push(current); current = []; faces = 0;
      }
      current.push(item); faces += itemFaces;
      if (faces >= faceBudget) { chunks.push(current); current = []; faces = 0; }
    });
    if (current.length) chunks.push(current);
    return chunks;
  }

  function build(name, rawBodies, timestamp, faceBudget) {
    // This serializer intentionally implements the compact faceted-B-rep
    // subset only. An open shell needs full edge topology to be conformant, so
    // omit damaged/open vendor fragments rather than mislabeling them.
    var bodies = prepareBodies(rawBodies).filter(function (body) { return body.closed; });
    var productFaceBudget = +faceBudget > 0 ? +faceBudget : 20000;
    if (!bodies.length) throw new Error("no closed 3D geometry");
    var lines = [
      "ISO-10303-21;", "HEADER;",
      "FILE_DESCRIPTION(('Netlisp PCB 3D conformant faceted B-rep export'),'2;1');",
      "FILE_NAME(" + stepText(fileName(name)) + "," + stepText(timestamp || new Date().toISOString().slice(0, 19)) + ",('Netlisp'),('Netlisp'),'Netlisp','','');",
      "FILE_SCHEMA(('AP242_MANAGED_MODEL_BASED_3D_ENGINEERING_MIM_LF { 1 0 10303 442 1 1 4 }'));",
      "ENDSEC;", "DATA;",
      "#1=APPLICATION_CONTEXT('managed model based 3d engineering');",
      "#2=APPLICATION_PROTOCOL_DEFINITION('international standard','ap242_managed_model_based_3d_engineering',2014,#1);",
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
    var next = 18, closedItems = [], styledItemIds = [], styleIds = new Map();

    function styleAssignment(color) {
      color = colorValue(color);
      if (!color) return null;
      var key = color.map(stepReal).join(","), found = styleIds.get(key);
      if (found) return found;
      var rgb = next++, fillColor = next++, fill = next++, surfaceFill = next++;
      var side = next++, usage = next++, assignment = next++;
      lines.push("#" + rgb + "=COLOUR_RGB(''," + key + ");");
      lines.push("#" + fillColor + "=FILL_AREA_STYLE_COLOUR('',#" + rgb + ");");
      lines.push("#" + fill + "=FILL_AREA_STYLE('',(#" + fillColor + "));");
      lines.push("#" + surfaceFill + "=SURFACE_STYLE_FILL_AREA(#" + fill + ");");
      lines.push("#" + side + "=SURFACE_SIDE_STYLE('',(#" + surfaceFill + "));");
      lines.push("#" + usage + "=SURFACE_STYLE_USAGE(.BOTH.,#" + side + ");");
      lines.push("#" + assignment + "=PRESENTATION_STYLE_ASSIGNMENT((#" + usage + "));");
      styleIds.set(key, assignment);
      return assignment;
    }

    function styleItem(item, color) {
      var style = styleAssignment(color);
      if (!style) return;
      var styled = next++;
      lines.push("#" + styled + "=STYLED_ITEM('',(#" + style + "),#" + item + ");");
      styledItemIds.push(styled);
    }

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
      body.triangles.forEach(function (t, triangleIndex) {
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
        // POLY_LOOP is legal on FACE_SURFACE.  ADVANCED_FACE explicitly
        // requires EDGE_LOOP or VERTEX_LOOP and makes an otherwise readable
        // file schema-invalid in stricter importers such as Fusion.
        lines.push("#" + face + "=FACE_SURFACE('',(#" + bound + "),#" + plane + ",.T.);");
        if (body.triangleColors && body.triangleColors[triangleIndex]) styleItem(face, body.triangleColors[triangleIndex]);
        faceIds.push(face);
      });
      var shell = next++;
      lines.push("#" + shell + "=CLOSED_SHELL(" + stepText(body.name) + ",(\n#" + faceIds.join(",\n#") + "));");
      var item = next++;
      lines.push("#" + item + "=FACETED_BREP(" + stepText(body.name) + ",#" + shell + ");");
      closedItems.push({ id: item, faces: faceIds.length });
      if (body.color) styleItem(item, body.color);
    });

    // OCCT 7.6 and some desktop translators mesh each top-level product as one
    // compound. Bound that scratch work by making independent product roots;
    // merely adding representations to the same product does not isolate it.
    var chunks = chunkItems(closedItems, productFaceBudget);
    chunks.forEach(function (chunk, chunkIndex) {
      var chunkName = chunks.length > 1 ? (name || "PCB assembly") + " " + (chunkIndex + 1) + "/" + chunks.length : (name || "PCB assembly");
      var productShape = 8;
      if (chunkIndex > 0) {
        var product = next++, formation = next++, definition = next++;
        productShape = next++;
        lines.push("#" + product + "=PRODUCT(" + stepText(chunkName) + "," + stepText(chunkName) + ",'',(#3));");
        lines.push("#" + formation + "=PRODUCT_DEFINITION_FORMATION('','',#" + product + ");");
        lines.push("#" + definition + "=PRODUCT_DEFINITION('design','',#" + formation + ",#6);");
        lines.push("#" + productShape + "=PRODUCT_DEFINITION_SHAPE('','',#" + definition + ");");
      }
      var solidRepresentation = next++;
      var itemIds = chunk.map(function (item) { return item.id; });
      lines.push("#" + solidRepresentation + "=FACETED_BREP_SHAPE_REPRESENTATION(" + stepText(chunkName) + ",(#17,\n#" + itemIds.join(",\n#") + "),#13);");
      lines.push("#" + next++ + "=SHAPE_DEFINITION_REPRESENTATION(#" + productShape + ",#" + solidRepresentation + ");");
    });
    if (styledItemIds.length) {
      lines.push("#" + next++ + "=MECHANICAL_DESIGN_GEOMETRIC_PRESENTATION_REPRESENTATION('',(#" + styledItemIds.join(",#") + "),#13);");
    }
    lines.push("ENDSEC;", "END-ISO-10303-21;", "");
    return lines.join("\n");
  }

  return { build: build, chunkItems: chunkItems, fileName: fileName, prepareBodies: prepareBodies, stepReal: stepReal };
});
