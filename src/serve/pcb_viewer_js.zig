/// Pixi.js PCB viewer JavaScript.
/// Renders footprints, pads, silkscreen, courtyard, ratsnest, and board outline.
/// Supports zoom/pan, layer toggles, component selection, and drag placement.
pub const PCB_VIEWER_JS =
    \\(async function() {
    \\'use strict';
    \\try {
    \\console.log('[PCB] Starting init');
    \\var container = document.getElementById('pixi-container');
    \\console.log('[PCB] Container:', container ? container.clientWidth+'x'+container.clientHeight : 'NULL');
    \\var app = new PIXI.Application();
    \\console.log('[PCB] Calling app.init...');
    \\await app.init({
    \\  background: '#0d1117',
    \\  resizeTo: container,
    \\  antialias: true,
    \\  resolution: Math.max(window.devicePixelRatio || 1, 2),
    \\  autoDensity: true,
    \\  preference: 'webgl',
    \\  preferWebGLVersion: 2
    \\});
    \\console.log('[PCB] app.init done, appending canvas');
    \\container.appendChild(app.canvas);
    \\
    \\var world = new PIXI.Container();
    \\app.stage.addChild(world);
    \\
    \\// Scale: 1mm = SCALE pixels
    \\var SCALE = 10;
    \\
    \\// Colors (KiCad dark theme inspired)
    \\var C = {
    \\  bg: 0x0d1117,
    \\  fcu: 0xCC3333,
    \\  bcu: 0x3333CC,
    \\  silk: 0xC8C8C8,
    \\  courtyard: 0xFF00FF,
    \\  edge: 0xFFFF00,
    \\  ratsnest: 0x555555,
    \\  ref: 0x88CC88,
    \\  highlight: 0x58a6ff,
    \\  grid: 0x1a1a2a,
    \\  padHover: 0xFFFFFF
    \\};
    \\
    \\var data = typeof PCB_DATA !== 'undefined' ? PCB_DATA : null;
    \\var fpContainers = {};   // uuid -> PIXI.Container
    \\var fpData = {};         // uuid -> footprint data object
    \\var selectedUuid = null;
    \\var selectedNet = null;
    \\var isDragging = false;
    \\var dragTarget = null;
    \\var dragOffset = {x:0, y:0};
    \\var dirty = false;
    \\var draggingVia = null; // {index, startX, startY} when dragging a via
    \\var draggingTrace = null; // {index, segIndex, lastMx, lastMy} when dragging a trace segment
    \\var gridSnap = 0.5; // mm
    \\var layerVisibility = { fcu: true, bcu: true, silk: true, courtyard: true, ratsnest: true, refs: true, traces_fcu: true, traces_bcu: true, vias: true, zones: true };
    \\var layerContainers = {};
    \\var selectMode = 'component'; // 'component', 'net', 'section', or 'route'
    \\var undoStack = [];
    \\var GRID_OPTIONS = [0.5, 0.25, 0.1];
    \\var overlapGraphics = [];
    \\// Box selection state
    \\var boxSelecting = false;
    \\var boxStart = {x:0, y:0}; // in world mm
    \\var boxGfx = null;
    \\var multiSelection = null; // {uuids:[], traceIds:{}, viaIds:{}} when active
    \\
    \\var _uidCounter = 0;
    \\function uid() { return 'tv_' + (++_uidCounter) + '_' + Math.random().toString(36).substr(2,6); }
    \\
    \\// Ensure all traces and vias have unique IDs
    \\function ensureRouteIds() {
    \\  if (data.traces) { for (var i=0; i<data.traces.length; i++) { if (!data.traces[i].id) data.traces[i].id = uid(); } }
    \\  if (data.vias) { for (var i=0; i<data.vias.length; i++) { if (!data.vias[i].id) data.vias[i].id = uid(); } }
    \\}
    \\
    \\// Strip dot-notation pin suffix from net name: "VDD.U3.F7" -> "VDD"
    \\function baseNetName(name) {
    \\  if (!name) return '';
    \\  var dot = name.indexOf('.');
    \\  return dot >= 0 ? name.substring(0, dot) : name;
    \\}
    \\// Parse subnet target: "buck/VIN.U12.VIN_1" -> {base:"buck/VIN", ref:"U12", pin:"VIN_1"}
    \\function parseSubnetTarget(name) {
    \\  if (!name) return null;
    \\  var dot = name.indexOf('.');
    \\  if (dot < 0) return null;
    \\  var rest = name.substring(dot + 1);
    \\  var dot2 = rest.indexOf('.');
    \\  if (dot2 < 0) return null;
    \\  return {base: name.substring(0, dot), ref: rest.substring(0, dot2), pin: rest.substring(dot2 + 1)};
    \\}
    \\// Display name for a net: "VDD (U3.F7)" or just "VDD"
    \\function displayNetName(name) {
    \\  if (!name) return '';
    \\  var sub = parseSubnetTarget(name);
    \\  if (sub) return sub.base + ' (' + sub.ref + '.' + sub.pin + ')';
    \\  return name;
    \\}
    \\
    \\// Layer containers (render order)
    \\var gridLayer = new PIXI.Container(); world.addChild(gridLayer);
    \\var edgeLayer = new PIXI.Container(); world.addChild(edgeLayer);
    \\layerContainers.zones = new PIXI.Container(); world.addChild(layerContainers.zones);
    \\layerContainers.bcu = new PIXI.Container(); world.addChild(layerContainers.bcu);
    \\layerContainers.traces_bcu = new PIXI.Container(); layerContainers.traces_bcu.eventMode = 'static'; world.addChild(layerContainers.traces_bcu);
    \\layerContainers.fcu = new PIXI.Container(); world.addChild(layerContainers.fcu);
    \\layerContainers.traces_fcu = new PIXI.Container(); layerContainers.traces_fcu.eventMode = 'static'; world.addChild(layerContainers.traces_fcu);
    \\layerContainers.vias = new PIXI.Container(); layerContainers.vias.eventMode = 'static'; world.addChild(layerContainers.vias);
    \\layerContainers.silk = new PIXI.Container(); world.addChild(layerContainers.silk);
    \\layerContainers.courtyard = new PIXI.Container(); world.addChild(layerContainers.courtyard);
    \\layerContainers.ratsnest = new PIXI.Container(); world.addChild(layerContainers.ratsnest);
    \\layerContainers.refs = new PIXI.Container(); world.addChild(layerContainers.refs);
    \\var sectionLayer = new PIXI.Container(); world.addChild(sectionLayer);
    \\sectionLayer.eventMode = 'static';
    \\
    \\function updateSectionBoxes() {
    \\  sectionLayer.removeChildren();
    \\  if (!data || !data.sections) return;
    \\  var refMap = {};
    \\  for (var uuid in fpData) refMap[fpData[uuid].ref] = uuid;
    \\  var PAD = 0.5;
    \\  for (var si=0; si<data.sections.length; si++) {
    \\    var sec = data.sections[si];
    \\    if (!sec.refs || sec.refs.length === 0) continue;
    \\    var minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
    \\    var count = 0;
    \\    for (var ri=0; ri<sec.refs.length; ri++) {
    \\      var uuid = refMap[sec.refs[ri]];
    \\      if (!uuid) continue;
    \\      var fp = fpData[uuid];
    \\      if (!fp) continue;
    \\      var aabb = courtyardAABB(fp);
    \\      if (aabb) {
    \\        minX = Math.min(minX, aabb.x1);
    \\        minY = Math.min(minY, aabb.y1);
    \\        maxX = Math.max(maxX, aabb.x2);
    \\        maxY = Math.max(maxY, aabb.y2);
    \\      } else {
    \\        minX = Math.min(minX, fp.x - 1);
    \\        minY = Math.min(minY, fp.y - 1);
    \\        maxX = Math.max(maxX, fp.x + 1);
    \\        maxY = Math.max(maxY, fp.y + 1);
    \\      }
    \\      count++;
    \\    }
    \\    if (count === 0) continue;
    \\    var bx = (minX - PAD)*SCALE, by = (minY - PAD)*SCALE;
    \\    var bw = (maxX - minX + PAD*2)*SCALE, bh = (maxY - minY + PAD*2)*SCALE;
    \\    var sg = new PIXI.Graphics();
    \\    sg.rect(bx, by, bw, bh);
    \\    sg.stroke({color: 0x3fb950, width: 1, alpha: 0.4});
    \\    sg.fill({color: 0x3fb950, alpha: 0.01});
    \\    sg.eventMode = selectMode === 'section' ? 'static' : 'none';
    \\    sg.cursor = 'pointer';
    \\    sg._sectionIdx = si;
    \\    sg.on('pointerdown', function(e) {
    \\      var idx = this._sectionIdx;
    \\      pushUndo();
    \\      selectSection(idx);
    \\      // Start section drag
    \\      isDragging = true;
    \\      wasDrag = false;
    \\      var wp = e.getLocalPosition(world);
    \\      dragStartPos.x = wp.x; dragStartPos.y = wp.y;
    \\      // Use first component as drag anchor
    \\      if (sectionUuids.length > 0 && fpContainers[sectionUuids[0]]) {
    \\        dragTarget = fpContainers[sectionUuids[0]];
    \\        dragOffset.x = dragTarget.x - wp.x;
    \\        dragOffset.y = dragTarget.y - wp.y;
    \\      }
    \\      e.stopPropagation();
    \\    });
    \\    sectionLayer.addChild(sg);
    \\    var lt = new PIXI.Text({
    \\      text: sec.name,
    \\      style: {fontFamily:'system-ui',fontSize:20,fill:0x3fb950,fontWeight:'700'}
    \\    });
    \\    lt.eventMode = 'none';
    \\    lt.x = bx + 4; lt.y = by + 4;
    \\    lt.scale.set(1/SCALE * 2.0);
    \\    sectionLayer.addChild(lt);
    \\  }
    \\}
    \\
    \\var skipFitView = false;
    \\function buildScene() {
    \\  console.log('[PCB] buildScene: start, data=' + (data ? data.footprints.length + ' fps' : 'null'));
    \\  ensureRouteIds();
    \\  for (var k in layerContainers) layerContainers[k].removeChildren();
    \\  edgeLayer.removeChildren();
    \\  gridLayer.removeChildren();
    \\  fpContainers = {};
    \\  fpData = {};
    \\  if (!data) return;
    \\
    \\  // Board outline
    \\  if (data.board && data.board.outline && data.board.outline.length >= 3) {
    \\    var og = new PIXI.Graphics();
    \\    var pts = data.board.outline;
    \\    og.moveTo(pts[0][0]*SCALE, pts[0][1]*SCALE);
    \\    for (var i=1; i<pts.length; i++) og.lineTo(pts[i][0]*SCALE, pts[i][1]*SCALE);
    \\    og.lineTo(pts[0][0]*SCALE, pts[0][1]*SCALE);
    \\    og.fill({color: C.edge, alpha: 0.04});
    \\    og.stroke({color: C.edge, width: 3});
    \\    edgeLayer.addChild(og);
    \\  }
    \\
    \\  // Section boxes drawn dynamically via updateSectionBoxes()
    \\
    \\  // Zone fills
    \\  if (data.zone_fills) {
    \\    for (var zi=0; zi<data.zone_fills.length; zi++) {
    \\      var z = data.zone_fills[zi];
    \\      var zColor = z.layer === 'F.Cu' ? C.fcu : C.bcu;
    \\      for (var pi=0; pi<z.polygons.length; pi++) {
    \\        var zg = new PIXI.Graphics();
    \\        var poly = z.polygons[pi];
    \\        if (poly.length < 3) continue;
    \\        zg.moveTo(poly[0][0]*SCALE, poly[0][1]*SCALE);
    \\        for (var pp=1; pp<poly.length; pp++) zg.lineTo(poly[pp][0]*SCALE, poly[pp][1]*SCALE);
    \\        zg.closePath();
    \\        zg.fill({color: zColor, alpha: 0.15});
    \\        zg.stroke({color: zColor, width: 0.5, alpha: 0.4});
    \\        zg._zoneData = z;
    \\        layerContainers.zones.addChild(zg);
    \\      }
    \\    }
    \\  }
    \\
    \\  // Traces — visible layer (non-interactive)
    \\  if (data.traces) {
    \\    for (var ti=0; ti<data.traces.length; ti++) {
    \\      var t = data.traces[ti];
    \\      if (t.points.length < 2) continue;
    \\      var tg = new PIXI.Graphics();
    \\      tg.moveTo(t.points[0][0]*SCALE, t.points[0][1]*SCALE);
    \\      for (var tpi=1; tpi<t.points.length; tpi++) tg.lineTo(t.points[tpi][0]*SCALE, t.points[tpi][1]*SCALE);
    \\      tg.stroke({color: t.layer==='F.Cu' ? C.fcu : C.bcu, width: t.width*SCALE, cap:'round', join:'round'});
    \\      tg._traceIndex = ti;
    \\      tg._traceId = t.id;
    \\      var tLayer = t.layer === 'F.Cu' ? layerContainers.traces_fcu : layerContainers.traces_bcu;
    \\      tLayer.addChild(tg);
    \\    }
    \\  }
    \\
    \\  // Vias
    \\  if (data.vias) {
    \\    for (var vi=0; vi<data.vias.length; vi++) {
    \\      var v = data.vias[vi];
    \\      var vg = new PIXI.Graphics();
    \\      vg.circle(v.x*SCALE, v.y*SCALE, v.pad_size/2*SCALE);
    \\      vg.fill({color: 0xC0C0C0, alpha: 0.9});
    \\      vg.circle(v.x*SCALE, v.y*SCALE, v.drill/2*SCALE);
    \\      vg.fill({color: 0x0d1117});
    \\      vg._viaData = v;
    \\      vg._viaIndex = vi;
    \\      vg._viaId = v.id;
    \\      vg.eventMode = 'static';
    \\      vg.cursor = 'pointer';
    \\      vg.on('pointerdown', function(e) {
    \\        e.stopPropagation();
    \\        if (selectMode === 'route' && routingNet) return;
    \\        selectTraceOrVia('via', this._viaIndex, this._viaData, this);
    \\      });
    \\      layerContainers.vias.addChild(vg);
    \\    }
    \\  }
    \\
    \\  // Footprints
    \\  for (var fi=0; fi<data.footprints.length; fi++) {
    \\    var fp = data.footprints[fi];
    \\    var isFront = fp.layer === 'F.Cu';
    \\    var padColor = isFront ? C.fcu : C.bcu;
    \\    var targetLayer = isFront ? layerContainers.fcu : layerContainers.bcu;
    \\
    \\    var fc = new PIXI.Container();
    \\    fc.x = fp.x * SCALE;
    \\    fc.y = fp.y * SCALE;
    \\    if (fp.angle) fc.angle = fp.angle;
    \\    fc.eventMode = 'static';
    \\    fc.cursor = 'grab';
    \\
    \\    // Store data
    \\    fc._uuid = fp.uuid;
    \\    fc._ref = fp.ref;
    \\    fc._fpData = fp;
    \\    fpContainers[fp.uuid] = fc;
    \\    fpData[fp.uuid] = fp;
    \\
    \\    // Courtyard — visible outline + invisible fill as hit area
    \\    if (fp.courtyard) {
    \\      var cx1 = fp.courtyard.x1 * SCALE, cy1 = fp.courtyard.y1 * SCALE;
    \\      var cx2 = fp.courtyard.x2 * SCALE, cy2 = fp.courtyard.y2 * SCALE;
    \\      // Hit area (invisible fill)
    \\      var hg = new PIXI.Graphics();
    \\      hg.rect(cx1, cy1, cx2-cx1, cy2-cy1);
    \\      hg.fill({color: 0x000000, alpha: 0.001});
    \\      hg.eventMode = 'static';
    \\      hg.cursor = 'grab';
    \\      hg._isHitArea = true;
    \\      fc.addChildAt(hg, 0);
    \\      // Visible outline
    \\      var cg = new PIXI.Graphics();
    \\      cg.rect(cx1, cy1, cx2-cx1, cy2-cy1);
    \\      cg.stroke({color: C.courtyard, width: 0.5, alpha: 0.4});
    \\      fc.addChild(cg);
    \\    }
    \\
    \\    // Silkscreen lines
    \\    if (fp.silk_lines && fp.silk_lines.length) {
    \\      var sg = new PIXI.Graphics();
    \\      for (var si=0; si<fp.silk_lines.length; si++) {
    \\        var sl = fp.silk_lines[si];
    \\        sg.moveTo(sl[0]*SCALE, sl[1]*SCALE);
    \\        sg.lineTo(sl[2]*SCALE, sl[3]*SCALE);
    \\      }
    \\      sg.stroke({color: C.silk, width: 1});
    \\      fc.addChild(sg);
    \\    }
    \\
    \\    // Pads
    \\    for (var pi=0; pi<fp.pads.length; pi++) {
    \\      var pad = fp.pads[pi];
    \\      var pg = new PIXI.Graphics();
    \\      var px = pad.x*SCALE, py = pad.y*SCALE, pw = pad.w*SCALE, ph = pad.h*SCALE;
    \\      if (pad.shape === 'circle') {
    \\        pg.circle(px, py, pw/2);
    \\      } else if (pad.shape === 'roundrect') {
    \\        var rr = Math.min(pw, ph) * 0.25;
    \\        pg.roundRect(px-pw/2, py-ph/2, pw, ph, rr);
    \\      } else if (pad.shape === 'oval') {
    \\        var ro = Math.min(pw, ph) / 2;
    \\        pg.roundRect(px-pw/2, py-ph/2, pw, ph, ro);
    \\      } else {
    \\        pg.rect(px-pw/2, py-ph/2, pw, ph);
    \\      }
    \\      pg.fill({color: padColor, alpha: 0.85});
    \\      pg._padData = pad;
    \\      pg._fpUuid = fp.uuid;
    \\      pg.eventMode = 'static';
    \\      pg.cursor = 'pointer';
    \\      pg.on('pointerover', function() {
    \\        showTooltip(this._padData.name + (this._padData.net_name ? ' [' + displayNetName(this._padData.net_name) + ']' : ''));
    \\      });
    \\      pg.on('pointerout', function() { hideTooltip(); });
    \\      pg.on('pointerdown', function(e) {
    \\        if (selectMode === 'net') {
    \\          e.stopPropagation();
    \\          if (this._padData.net_name) highlightNet(baseNetName(this._padData.net_name));
    \\        } else if (selectMode === 'route') {
    \\          e.stopPropagation();
    \\          var pd = this._padData;
    \\          var fpu = this._fpUuid;
    \\          var fpd = fpData[fpu];
    \\          if (!pd.net_name) return;
    \\          if (viaPreviewMode && routingNet) {
    \\            // Place via on pad location
    \\            var fp2 = fpData[fpu], fc2 = fpContainers[fpu];
    \\            if (fp2 && fc2) {
    \\              var a2 = (fp2.angle||0)*Math.PI/180;
    \\              var pvx = pd.x*Math.cos(a2)-pd.y*Math.sin(a2)+fc2.x/SCALE;
    \\              var pvy = pd.x*Math.sin(a2)+pd.y*Math.cos(a2)+fc2.y/SCALE;
    \\              addRoutingViaAt(pvx, pvy);
    \\              viaPreviewMode = false;
    \\              if (viaPreviewGfx) { viaPreviewGfx.destroy(); viaPreviewGfx = null; }
    \\            }
    \\          } else if (routingNet) {
    \\            // Finishing a route: check if same base net
    \\            if (baseNetName(pd.net_name) === baseNetName(routingNet)) {
    \\              finishRouting(pd, fpu);
    \\            }
    \\          } else {
    \\            // Starting a new route
    \\            startRouting(pd, fpd ? fpd.ref : '', fpu, fpd ? fpd.layer : 'F.Cu');
    \\          }
    \\        }
    \\        // In component mode, let event bubble to container for drag/select
    \\      });
    \\      fc.addChild(pg);
    \\    }
    \\
    \\    // Ref des label
    \\    var rt = new PIXI.Text({
    \\      text: fp.ref,
    \\      style: {fontFamily:'monospace',fontSize:8,fill:C.ref,fontWeight:'bold'}
    \\    });
    \\    rt.anchor.set(0.5, 0.5);
    \\    rt.x = 0; rt.y = 0;
    \\    rt.scale.set(1/SCALE * 1.2);
    \\    var refC = new PIXI.Container();
    \\    refC.addChild(rt);
    \\    refC.x = fc.x; refC.y = fc.y - (fp.courtyard ? fp.courtyard.y1 * SCALE - 2 : 4);
    \\    layerContainers.refs.addChild(refC);
    \\    fc._refLabel = refC;
    \\
    \\    // Drag handlers
    \\    fc.on('pointerdown', onDragStart);
    \\    targetLayer.addChild(fc);
    \\  }
    \\
    \\  // Ratsnest + overlap check
    \\  console.log('[PCB] buildScene: footprints done, building ratsnest...');
    \\  rebuildRefMap();
    \\  buildRatsnest();
    \\  console.log('[PCB] buildScene: ratsnest done, checking overlaps...');
    \\  checkOverlaps();
    \\  updateSectionBoxes();
    \\  if (!skipFitView) { fitView(); }
    \\  skipFitView = false;
    \\}
    \\
    \\// Build connectivity from routed traces+vias for a given net
    \\function getTraceConnectivity(netName, positions) {
    \\  // Union-find over position indices
    \\  var parent = [];
    \\  for (var i=0; i<positions.length; i++) parent[i] = i;
    \\  function find(a) { while (parent[a]!==a) { parent[a]=parent[parent[a]]; a=parent[a]; } return a; }
    \\  function unite(a,b) { a=find(a); b=find(b); if(a!==b) parent[a]=b; }
    \\  var TOL = 1.0; // 1mm tolerance for matching trace endpoints to pads (in pixels = 1mm * SCALE)
    \\  var tolPx = TOL * SCALE;
    \\  if (!data.traces && !data.vias) return parent;
    \\  // Collect trace endpoints for this net
    \\  var traceEnds = [];
    \\  if (data.traces) {
    \\    for (var ti=0; ti<data.traces.length; ti++) {
    \\      var tr = data.traces[ti];
    \\      if (baseNetName(tr.net) !== netName || tr.points.length < 2) continue;
    \\      var p0 = tr.points[0], p1 = tr.points[tr.points.length-1];
    \\      traceEnds.push([p0[0]*SCALE, p0[1]*SCALE, p1[0]*SCALE, p1[1]*SCALE]);
    \\    }
    \\  }
    \\  // For each trace, find pads near start and end, unite them
    \\  for (var ti=0; ti<traceEnds.length; ti++) {
    \\    var startPads = [], endPads = [];
    \\    for (var pi=0; pi<positions.length; pi++) {
    \\      var dx0 = positions[pi].x - traceEnds[ti][0], dy0 = positions[pi].y - traceEnds[ti][1];
    \\      if (dx0*dx0+dy0*dy0 < tolPx*tolPx) startPads.push(pi);
    \\      var dx1 = positions[pi].x - traceEnds[ti][2], dy1 = positions[pi].y - traceEnds[ti][3];
    \\      if (dx1*dx1+dy1*dy1 < tolPx*tolPx) endPads.push(pi);
    \\    }
    \\    for (var si=0; si<startPads.length; si++)
    \\      for (var ei=0; ei<endPads.length; ei++)
    \\        unite(startPads[si], endPads[ei]);
    \\  }
    \\  // Also connect via vias: a via connects trace endpoints on different layers at the same point
    \\  if (data.vias) {
    \\    for (var vi=0; vi<data.vias.length; vi++) {
    \\      var v = data.vias[vi];
    \\      if (baseNetName(v.net) !== netName) continue;
    \\      var vx = v.x*SCALE, vy = v.y*SCALE;
    \\      var nearPads = [];
    \\      for (var pi=0; pi<positions.length; pi++) {
    \\        var dx = positions[pi].x - vx, dy = positions[pi].y - vy;
    \\        if (dx*dx+dy*dy < tolPx*tolPx) nearPads.push(pi);
    \\      }
    \\      for (var ni=1; ni<nearPads.length; ni++) unite(nearPads[0], nearPads[ni]);
    \\    }
    \\  }
    \\  return {find: find, parent: parent};
    \\}
    \\
    \\function buildRatsnest() {
    \\  layerContainers.ratsnest.removeChildren();
    \\  if (!data || !data.ratsnest) return;
    \\  var dragRef = null;
    \\  if (isDragging && dragTarget && dragTarget._ref) dragRef = dragTarget._ref;
    \\  else if (selectedUuid && fpData[selectedUuid]) dragRef = fpData[selectedUuid].ref;
    \\
    \\  // Track which ref+pin combos are covered by ratsnest entries
    \\  var covered = {};
    \\
    \\  // Pass 1: draw MST for each ratsnest entry, excluding trace-connected pairs
    \\  for (var ri=0; ri<data.ratsnest.length; ri++) {
    \\    var rn = data.ratsnest[ri];
    \\    if (rn.pins.length < 2) continue;
    \\    var positions = [], isDragPin = [];
    \\    for (var pi=0; pi<rn.pins.length; pi++) {
    \\      var ref = rn.pins[pi][0], pin = rn.pins[pi][1];
    \\      covered[ref + '\x00' + pin] = true;
    \\      var pos = findPadPosition(ref, pin);
    \\      if (pos) { positions.push(pos); isDragPin.push(dragRef && ref === dragRef); }
    \\    }
    \\    if (positions.length < 2) continue;
    \\    var conn = getTraceConnectivity(baseNetName(rn.name), positions);
    \\    drawMST(positions, isDragPin, baseNetName(rn.name), conn);
    \\  }
    \\
    \\  // Pass 2: orphan subnets — pads with dotted net names not in any ratsnest entry
    \\  var orphanNorm = new PIXI.Graphics();
    \\  var orphanHl = new PIXI.Graphics();
    \\  var orphanHlGnd = new PIXI.Graphics();
    \\  var hasOrphanNorm = false, hasOrphanHl = false, hasOrphanHlGnd = false;
    \\  for (var uuid in fpData) {
    \\    var fp = fpData[uuid];
    \\    var fc = fpContainers[uuid];
    \\    if (!fp || !fc) continue;
    \\    for (var pi=0; pi<fp.pads.length; pi++) {
    \\      var pad = fp.pads[pi];
    \\      if (!pad.net_name) continue;
    \\      var sub = parseSubnetTarget(pad.net_name);
    \\      if (!sub) continue;
    \\      // Check if this pad is already covered
    \\      if (covered[fp.ref + '\x00' + pad.name]) continue;
    \\      // Find this pad's world position
    \\      var angle = (fp.angle||0) * Math.PI/180;
    \\      var px = pad.x*SCALE, py = pad.y*SCALE;
    \\      var rx = px*Math.cos(angle) - py*Math.sin(angle);
    \\      var ry = px*Math.sin(angle) + py*Math.cos(angle);
    \\      var padPos = {x: fc.x + rx, y: fc.y + ry};
    \\      // Find closest pad on the target ref that shares the same base net
    \\      var targetRef = sub.ref;
    \\      var slash = fp.ref.lastIndexOf('/');
    \\      if (slash >= 0) targetRef = fp.ref.substring(0, slash + 1) + sub.ref;
    \\      // Try exact pin name first
    \\      var targetPos = findPadPosition(targetRef, sub.pin);
    \\      if (!targetPos) {
    \\        // Pin name doesn't match footprint pad numbers — find closest pad on target ref with same base net
    \\        var targetUuid = refToUuid[targetRef];
    \\        if (targetUuid) {
    \\          var tFp = fpData[targetUuid], tFc = fpContainers[targetUuid];
    \\          if (tFp && tFc) {
    \\            var bestDist = Infinity;
    \\            var tAngle = (tFp.angle||0) * Math.PI/180;
    \\            var tCos = Math.cos(tAngle), tSin = Math.sin(tAngle);
    \\            for (var tpi=0; tpi<tFp.pads.length; tpi++) {
    \\              var tp = tFp.pads[tpi];
    \\              if (baseNetName(tp.net_name) !== sub.base) continue;
    \\              var tpx = tp.x*SCALE, tpy = tp.y*SCALE;
    \\              var trx = tpx*tCos - tpy*tSin + tFc.x;
    \\              var try2 = tpx*tSin + tpy*tCos + tFc.y;
    \\              var ddx = trx - padPos.x, ddy = try2 - padPos.y;
    \\              var dist = ddx*ddx + ddy*ddy;
    \\              if (dist < bestDist) { bestDist = dist; targetPos = {x: trx, y: try2}; }
    \\            }
    \\          }
    \\        }
    \\      }
    \\      if (!targetPos) continue;
    \\      // Draw ratsnest line
    \\      var hl = dragRef && (fp.ref === dragRef || targetRef === dragRef);
    \\      var isGnd2 = sub.base.indexOf('GND') >= 0 || sub.base.indexOf('gnd') >= 0;
    \\      if (hl && isGnd2) {
    \\        orphanHlGnd.moveTo(padPos.x, padPos.y); orphanHlGnd.lineTo(targetPos.x, targetPos.y);
    \\        hasOrphanHlGnd = true;
    \\      } else if (hl) {
    \\        orphanHl.moveTo(padPos.x, padPos.y); orphanHl.lineTo(targetPos.x, targetPos.y);
    \\        hasOrphanHl = true;
    \\      } else {
    \\        orphanNorm.moveTo(padPos.x, padPos.y); orphanNorm.lineTo(targetPos.x, targetPos.y);
    \\        hasOrphanNorm = true;
    \\      }
    \\    }
    \\  }
    \\  if (hasOrphanNorm) {
    \\    orphanNorm.stroke({color: C.ratsnest, width: 0.25, alpha: 0.4});
    \\    orphanNorm._netName = '';
    \\    layerContainers.ratsnest.addChild(orphanNorm);
    \\  }
    \\  if (hasOrphanHl) {
    \\    orphanHl.stroke({color: 0xFFFFFF, width: 0.5, alpha: 0.9});
    \\    orphanHl._netName = '';
    \\    layerContainers.ratsnest.addChild(orphanHl);
    \\  }
    \\  if (hasOrphanHlGnd) {
    \\    orphanHlGnd.stroke({color: C.ratsnest, width: 0.25, alpha: 0.4});
    \\    orphanHlGnd._netName = 'GND';
    \\    layerContainers.ratsnest.addChild(orphanHlGnd);
    \\  }
    \\}
    \\
    \\function drawMST(positions, isDragPin, netName, conn) {
    \\  var n = positions.length;
    \\  var inTree = new Array(n); for (var ti=0;ti<n;ti++) inTree[ti]=false;
    \\  var minDist = new Array(n); for (var ti=0;ti<n;ti++) minDist[ti]=Infinity;
    \\  var minFrom = new Array(n); for (var ti=0;ti<n;ti++) minFrom[ti]=0;
    \\  inTree[0] = true;
    \\  for (var ti=1;ti<n;ti++) {
    \\    var dx=positions[ti].x-positions[0].x, dy=positions[ti].y-positions[0].y;
    \\    minDist[ti] = dx*dx+dy*dy;
    \\  }
    \\  var edges = [];
    \\  for (var added=1; added<n; added++) {
    \\    var best=-1, bestD=Infinity;
    \\    for (var ti=0;ti<n;ti++) { if (!inTree[ti] && minDist[ti]<bestD) { bestD=minDist[ti]; best=ti; } }
    \\    if (best<0) break;
    \\    inTree[best] = true;
    \\    var fromIdx = minFrom[best];
    \\    var hl = isDragPin[best] !== isDragPin[fromIdx];
    \\    // Skip edge if both pads are already connected by traces
    \\    var routed = conn && conn.find(best) === conn.find(fromIdx);
    \\    if (!routed) edges.push({x1:positions[fromIdx].x, y1:positions[fromIdx].y, x2:positions[best].x, y2:positions[best].y, hl:hl});
    \\    for (var ti=0;ti<n;ti++) {
    \\      if (inTree[ti]) continue;
    \\      var dx2=positions[ti].x-positions[best].x, dy2=positions[ti].y-positions[best].y;
    \\      var d2=dx2*dx2+dy2*dy2;
    \\      if (d2<minDist[ti]) { minDist[ti]=d2; minFrom[ti]=best; }
    \\    }
    \\  }
    \\  if (edges.length === 0) return;
    \\  var rg = new PIXI.Graphics();
    \\  for (var ei=0; ei<edges.length; ei++) {
    \\    if (!edges[ei].hl) { rg.moveTo(edges[ei].x1, edges[ei].y1); rg.lineTo(edges[ei].x2, edges[ei].y2); }
    \\  }
    \\  rg.stroke({color: C.ratsnest, width: 0.25, alpha: 0.4});
    \\  rg._netName = netName;
    \\  layerContainers.ratsnest.addChild(rg);
    \\  var hasHl = false;
    \\  for (var ei=0; ei<edges.length; ei++) { if (edges[ei].hl) { hasHl = true; break; } }
    \\  if (hasHl) {
    \\    var hg = new PIXI.Graphics();
    \\    for (var ei=0; ei<edges.length; ei++) {
    \\      if (edges[ei].hl) { hg.moveTo(edges[ei].x1, edges[ei].y1); hg.lineTo(edges[ei].x2, edges[ei].y2); }
    \\    }
    \\    var isGnd = netName.indexOf('GND') >= 0 || netName.indexOf('gnd') >= 0;
    \\    hg.stroke({color: isGnd ? C.ratsnest : 0xFFFFFF, width: isGnd ? 0.25 : 0.5, alpha: isGnd ? 0.4 : 0.9});
    \\    hg._netName = netName;
    \\    layerContainers.ratsnest.addChild(hg);
    \\  }
    \\}
    \\
    \\var refToUuid = {};
    \\function rebuildRefMap() {
    \\  refToUuid = {};
    \\  for (var uuid in fpData) refToUuid[fpData[uuid].ref] = uuid;
    \\}
    \\function findPadPosition(ref, padName) {
    \\  var uuid = refToUuid[ref];
    \\  if (!uuid) return null;
    \\  var fp = fpData[uuid];
    \\  var fc = fpContainers[uuid];
    \\  if (!fp || !fc) return null;
    \\  for (var i=0; i<fp.pads.length; i++) {
    \\    if (fp.pads[i].name === padName) {
    \\      var angle = (fp.angle||0) * Math.PI/180;
    \\      var px = fp.pads[i].x * SCALE;
    \\      var py = fp.pads[i].y * SCALE;
    \\      var rx = px*Math.cos(angle) - py*Math.sin(angle);
    \\      var ry = px*Math.sin(angle) + py*Math.cos(angle);
    \\      return {x: fc.x + rx, y: fc.y + ry};
    \\    }
    \\  }
    \\  return null;
    \\}
    \\
    \\// --- Courtyard Overlap Detection ---
    \\// Compute world-space AABB for a rotated courtyard
    \\function courtyardAABB(fp) {
    \\  var c = fp.courtyard;
    \\  if (!c) return null;
    \\  var corners = [[c.x1,c.y1],[c.x2,c.y1],[c.x2,c.y2],[c.x1,c.y2]];
    \\  var angle = (fp.angle||0) * Math.PI/180;
    \\  var cos = Math.cos(angle), sin = Math.sin(angle);
    \\  var minX=Infinity, minY=Infinity, maxX=-Infinity, maxY=-Infinity;
    \\  for (var ci=0; ci<4; ci++) {
    \\    var rx = corners[ci][0]*cos - corners[ci][1]*sin + fp.x;
    \\    var ry = corners[ci][0]*sin + corners[ci][1]*cos + fp.y;
    \\    if (rx < minX) minX = rx; if (rx > maxX) maxX = rx;
    \\    if (ry < minY) minY = ry; if (ry > maxY) maxY = ry;
    \\  }
    \\  return {x1:minX, y1:minY, x2:maxX, y2:maxY};
    \\}
    \\function checkOverlaps() {
    \\  for (var oi=0; oi<overlapGraphics.length; oi++) {
    \\    if (overlapGraphics[oi].parent) overlapGraphics[oi].parent.removeChild(overlapGraphics[oi]);
    \\  }
    \\  overlapGraphics = [];
    \\  if (!data) return;
    \\  // Collect world-space AABBs accounting for rotation
    \\  var rects = [];
    \\  for (var uuid in fpData) {
    \\    var fp = fpData[uuid];
    \\    if (!fp.courtyard) continue;
    \\    var fc = fpContainers[uuid];
    \\    if (!fc) continue;
    \\    var aabb = courtyardAABB(fp);
    \\    if (aabb) rects.push({uuid:uuid, layer:fp.layer, x1:aabb.x1, y1:aabb.y1, x2:aabb.x2, y2:aabb.y2});
    \\  }
    \\  var overlapping = {};
    \\  for (var a=0; a<rects.length; a++) {
    \\    for (var b=a+1; b<rects.length; b++) {
    \\      var ra = rects[a], rb = rects[b];
    \\      if (ra.layer !== rb.layer) continue;
    \\      if (ra.x1 < rb.x2 && ra.x2 > rb.x1 && ra.y1 < rb.y2 && ra.y2 > rb.y1) {
    \\        overlapping[ra.uuid] = true;
    \\        overlapping[rb.uuid] = true;
    \\      }
    \\    }
    \\  }
    \\  for (var uuid2 in overlapping) {
    \\    var fp2 = fpData[uuid2];
    \\    var fc2 = fpContainers[uuid2];
    \\    if (!fp2 || !fc2 || !fp2.courtyard) continue;
    \\    var og = new PIXI.Graphics();
    \\    var c = fp2.courtyard;
    \\    og.rect(c.x1*SCALE, c.y1*SCALE, (c.x2-c.x1)*SCALE, (c.y2-c.y1)*SCALE);
    \\    og.fill({color: 0xFF0000, alpha: 0.15});
    \\    og.stroke({color: 0xFF0000, width: 1.5, alpha: 0.7});
    \\    og.eventMode = 'none';
    \\    fc2.addChild(og);
    \\    overlapGraphics.push(og);
    \\  }
    \\}
    \\
    \\// --- Undo Stack ---
    \\function pushUndo() {
    \\  var placements = [];
    \\  for (var uuid in fpData) {
    \\    var fp = fpData[uuid];
    \\    placements.push({uuid:uuid, x:fp.x, y:fp.y, angle:fp.angle||0, layer:fp.layer});
    \\  }
    \\  undoStack.push({
    \\    placements: placements,
    \\    traces: JSON.parse(JSON.stringify(data.traces || [])),
    \\    vias: JSON.parse(JSON.stringify(data.vias || []))
    \\  });
    \\  if (undoStack.length > 50) undoStack.shift();
    \\}
    \\function popUndo() {
    \\  if (undoStack.length === 0) return;
    \\  var state = undoStack.pop();
    \\  for (var si=0; si<state.placements.length; si++) {
    \\    var s = state.placements[si];
    \\    var fp = fpData[s.uuid];
    \\    if (!fp) continue;
    \\    fp.x = s.x; fp.y = s.y; fp.angle = s.angle; fp.layer = s.layer;
    \\  }
    \\  data.traces = state.traces;
    \\  data.vias = state.vias;
    \\  skipFitView = true;
    \\  buildScene();
    \\  dirty = true; scheduleSave();
    \\}
    \\
    \\// --- Drag and Drop ---
    \\var dragStartPos = {x:0, y:0};
    \\var wasDrag = false;
    \\function findComponentsAtPoint(mx, my) {
    \\  var hits = [];
    \\  for (var uuid in fpData) {
    \\    var fp = fpData[uuid];
    \\    var aabb = courtyardAABB(fp);
    \\    if (aabb && mx >= aabb.x1 && mx <= aabb.x2 && my >= aabb.y1 && my <= aabb.y2) {
    \\      hits.push({uuid: uuid, layer: fp.layer});
    \\    }
    \\  }
    \\  // Sort: F.Cu first, then B.Cu
    \\  hits.sort(function(a,b) { return a.layer === 'F.Cu' ? -1 : b.layer === 'F.Cu' ? 1 : 0; });
    \\  return hits;
    \\}
    \\function onDragStart(e) {
    \\  if (isDragging) return;
    \\  // In route/trace mode, don't start component dragging
    \\  if (selectMode === 'route' || selectMode === 'trace') return;
    \\  // If multi-selection active and this component is in it, start multi drag
    \\  if (multiSelection && multiSelection.uuids.indexOf(this._uuid) >= 0) {
    \\    e.stopPropagation();
    \\    pushUndo();
    \\    var wpm3 = e.getLocalPosition(world);
    \\    var mx3 = wpm3.x / SCALE, my3 = wpm3.y / SCALE;
    \\    if (gridSnap > 0) { mx3 = Math.round(mx3/gridSnap)*gridSnap; my3 = Math.round(my3/gridSnap)*gridSnap; }
    \\    multiSelection._dragging = true;
    \\    multiSelection._lastMx = mx3;
    \\    multiSelection._lastMy = my3;
    \\    return;
    \\  }
    \\  pushUndo();
    \\  var target = this;
    \\  var wp = e.getLocalPosition(world);
    \\  var mx = wp.x / SCALE, my = wp.y / SCALE;
    \\  dragStartPos.x = wp.x; dragStartPos.y = wp.y;
    \\  wasDrag = false;
    \\  // If in section mode and a section is selected, keep section mode
    \\  var keepSection = false;
    \\  if (selectMode === 'section' && selectedSection !== null && sectionUuids.indexOf(target._uuid) >= 0) {
    \\    keepSection = true;
    \\  }
    \\  // If a component is already selected and the click overlaps it, prefer the selected one
    \\  if (!keepSection && selectedUuid && selectedUuid !== target._uuid && fpContainers[selectedUuid]) {
    \\    var selFp = fpData[selectedUuid];
    \\    if (selFp) {
    \\      var aabb = courtyardAABB(selFp);
    \\      if (aabb && mx >= aabb.x1 && mx <= aabb.x2 && my >= aabb.y1 && my <= aabb.y2) {
    \\        target = fpContainers[selectedUuid];
    \\      }
    \\    }
    \\  }
    \\  isDragging = true;
    \\  dragTarget = target;
    \\  dragTarget.cursor = 'grabbing';
    \\  dragTarget.alpha = 0.8;
    \\  dragOffset.x = target.x - wp.x;
    \\  dragOffset.y = target.y - wp.y;
    \\  if (!keepSection) selectComponent(target._uuid);
    \\  e.stopPropagation();
    \\}
    \\
    \\// --- Trace/Via proximity hit test ---
    \\function findTraceOrViaAt(mx, my) {
    \\  var bestDist = 1.5; // max 1.5mm click distance
    \\  var bestHit = null;
    \\  // Check traces — also track which segment is closest
    \\  if (data.traces) {
    \\    for (var ti=0; ti<data.traces.length; ti++) {
    \\      var t = data.traces[ti];
    \\      for (var si=0; si<t.points.length-1; si++) {
    \\        var d = distPtSeg(mx, my, t.points[si][0], t.points[si][1], t.points[si+1][0], t.points[si+1][1]);
    \\        var hitDist = d - t.width/2;
    \\        if (hitDist < bestDist) { bestDist = hitDist; bestHit = {type:'trace', index:ti, segIndex:si, data:t}; }
    \\      }
    \\    }
    \\  }
    \\  // Check vias
    \\  if (data.vias) {
    \\    for (var vi=0; vi<data.vias.length; vi++) {
    \\      var v = data.vias[vi];
    \\      var dx = mx-v.x, dy = my-v.y;
    \\      var d2 = Math.sqrt(dx*dx+dy*dy) - v.pad_size/2;
    \\      if (d2 < bestDist) { bestDist = d2; bestHit = {type:'via', index:vi, data:v}; }
    \\    }
    \\  }
    \\  return bestHit;
    \\}
    \\function findTraceGfx(traceIndex) {
    \\  // Find the Graphics for a trace by its _traceIndex in the trace layers
    \\  var layers = [layerContainers.traces_fcu, layerContainers.traces_bcu];
    \\  for (var li=0; li<layers.length; li++) {
    \\    for (var ci=0; ci<layers[li].children.length; ci++) {
    \\      if (layers[li].children[ci]._traceIndex === traceIndex) return layers[li].children[ci];
    \\    }
    \\  }
    \\  return null;
    \\}
    \\function findViaGfx(viaIndex) {
    \\  for (var ci=0; ci<layerContainers.vias.children.length; ci++) {
    \\    if (layerContainers.vias.children[ci]._viaIndex === viaIndex) return layerContainers.vias.children[ci];
    \\  }
    \\  return null;
    \\}
    \\
    \\app.stage.eventMode = 'static';
    \\app.stage.hitArea = app.screen;
    \\app.stage.on('pointermove', function(e) {
    \\  // Routing preview
    \\  if (selectMode === 'route' && routingNet && routingPoints.length > 0) {
    \\    var wp2 = e.getLocalPosition(world);
    \\    var mx = wp2.x / SCALE, my = wp2.y / SCALE;
    \\    if (gridSnap > 0) { mx = Math.round(mx/gridSnap)*gridSnap; my = Math.round(my/gridSnap)*gridSnap; }
    \\    routingCursorMm = [mx, my];
    \\    drawRoutingPreview(mx, my);
    \\    // Via preview ghost with DRC
    \\    if (viaPreviewGfx) { viaPreviewGfx.destroy(); viaPreviewGfx = null; }
    \\    if (viaPreviewMode) {
    \\      var vs = getViaSize();
    \\      var viaViolations = checkViaDrc(mx, my, vs.pad_size, baseNetName(routingNet));
    \\      var viaColor = viaViolations.length > 0 ? 0xFF0000 : 0xC0C0C0;
    \\      viaPreviewGfx = new PIXI.Graphics();
    \\      viaPreviewGfx.circle(mx*SCALE, my*SCALE, vs.pad_size/2*SCALE);
    \\      viaPreviewGfx.fill({color: viaColor, alpha: 0.5});
    \\      viaPreviewGfx.circle(mx*SCALE, my*SCALE, vs.drill/2*SCALE);
    \\      viaPreviewGfx.fill({color: 0x0d1117, alpha: 0.5});
    \\      // Draw violation circles
    \\      for (var dvi=0; dvi<viaViolations.length; dvi++) {
    \\        viaPreviewGfx.circle(viaViolations[dvi].x*SCALE, viaViolations[dvi].y*SCALE, getDrcClearance()*SCALE);
    \\        viaPreviewGfx.stroke({color: 0xFF0000, width: 0.3*SCALE, alpha: 0.8});
    \\      }
    \\      layerContainers.vias.addChild(viaPreviewGfx);
    \\    }
    \\  }
    \\  // Box selection drawing
    \\  if (boxSelecting) {
    \\    var wpb2 = e.getLocalPosition(world);
    \\    var bx = wpb2.x / SCALE, by = wpb2.y / SCALE;
    \\    if (boxGfx) { boxGfx.destroy(); boxGfx = null; }
    \\    boxGfx = new PIXI.Graphics();
    \\    var x1 = Math.min(boxStart.x, bx)*SCALE, y1 = Math.min(boxStart.y, by)*SCALE;
    \\    var bw = Math.abs(bx - boxStart.x)*SCALE, bh = Math.abs(by - boxStart.y)*SCALE;
    \\    boxGfx.rect(x1, y1, bw, bh);
    \\    boxGfx.stroke({color: 0x58a6ff, width: 1, alpha: 0.8});
    \\    boxGfx.fill({color: 0x58a6ff, alpha: 0.1});
    \\    world.addChild(boxGfx);
    \\    return;
    \\  }
    \\  // Multi-selection dragging
    \\  if (multiSelection && multiSelection._dragging) {
    \\    var wpm = e.getLocalPosition(world);
    \\    var mmx = wpm.x / SCALE, mmy = wpm.y / SCALE;
    \\    if (gridSnap > 0) { mmx = Math.round(mmx/gridSnap)*gridSnap; mmy = Math.round(mmy/gridSnap)*gridSnap; }
    \\    var mdx = mmx - multiSelection._lastMx, mdy = mmy - multiSelection._lastMy;
    \\    if (Math.abs(mdx) < 0.001 && Math.abs(mdy) < 0.001) return;
    \\    // Move components
    \\    for (var mi=0; mi<multiSelection.uuids.length; mi++) {
    \\      var mu = multiSelection.uuids[mi];
    \\      var mfc = fpContainers[mu], mfp = fpData[mu];
    \\      if (!mfc || !mfp) continue;
    \\      mfc.x += mdx*SCALE; mfc.y += mdy*SCALE;
    \\      mfp.x = mfc.x/SCALE; mfp.y = mfc.y/SCALE;
    \\      if (mfc._refLabel) { mfc._refLabel.x = mfc.x; mfc._refLabel.y = mfc.y - (mfp.courtyard ? mfp.courtyard.y1*SCALE-2:4); }
    \\    }
    \\    // Move traces
    \\    for (var ti=0; ti<data.traces.length; ti++) {
    \\      if (!multiSelection.traceIds[data.traces[ti].id]) continue;
    \\      var mt = data.traces[ti];
    \\      for (var pi=0; pi<mt.points.length; pi++) mt.points[pi] = [mt.points[pi][0]+mdx, mt.points[pi][1]+mdy];
    \\      var mtg = findTraceGfx(ti);
    \\      if (mtg) {
    \\        mtg.clear();
    \\        mtg.moveTo(mt.points[0][0]*SCALE, mt.points[0][1]*SCALE);
    \\        for (var tpi=1; tpi<mt.points.length; tpi++) mtg.lineTo(mt.points[tpi][0]*SCALE, mt.points[tpi][1]*SCALE);
    \\        mtg.stroke({color: mt.layer==='F.Cu'?C.fcu:C.bcu, width: mt.width*SCALE, cap:'round', join:'round'});
    \\      }
    \\    }
    \\    // Move vias
    \\    for (var vi=0; vi<data.vias.length; vi++) {
    \\      if (!multiSelection.viaIds[data.vias[vi].id]) continue;
    \\      var mv = data.vias[vi];
    \\      mv.x += mdx; mv.y += mdy;
    \\      var mvg = findViaGfx(vi);
    \\      if (mvg) { mvg.clear(); mvg.circle(mv.x*SCALE,mv.y*SCALE,mv.pad_size/2*SCALE); mvg.fill({color:0xC0C0C0,alpha:0.9}); mvg.circle(mv.x*SCALE,mv.y*SCALE,mv.drill/2*SCALE); mvg.fill({color:0x0d1117}); }
    \\    }
    \\    multiSelection._lastMx = mmx;
    \\    multiSelection._lastMy = mmy;
    \\    buildRatsnest();
    \\    return;
    \\  }
    \\  // Via dragging
    \\  if (draggingVia) {
    \\    var wpv = e.getLocalPosition(world);
    \\    var vmx = wpv.x / SCALE, vmy = wpv.y / SCALE;
    \\    if (gridSnap > 0) { vmx = Math.round(vmx/gridSnap)*gridSnap; vmy = Math.round(vmy/gridSnap)*gridSnap; }
    \\    data.vias[draggingVia.index].x = vmx;
    \\    data.vias[draggingVia.index].y = vmy;
    \\    // Update the via graphics directly
    \\    var vgfx = findViaGfx(draggingVia.index);
    \\    if (vgfx) {
    \\      var v = data.vias[draggingVia.index];
    \\      vgfx.clear();
    \\      vgfx.circle(v.x*SCALE, v.y*SCALE, v.pad_size/2*SCALE);
    \\      vgfx.fill({color: 0xC0C0C0, alpha: 0.9});
    \\      vgfx.circle(v.x*SCALE, v.y*SCALE, v.drill/2*SCALE);
    \\      vgfx.fill({color: 0x0d1117});
    \\    }
    \\    return;
    \\  }
    \\  // Trace segment dragging — KiCad-style: segment slides perpendicular, neighbors adjust to maintain 45°
    \\  if (draggingTrace) {
    \\    var wpt = e.getLocalPosition(world);
    \\    var tmx = wpt.x / SCALE, tmy = wpt.y / SCALE;
    \\    if (gridSnap > 0) { tmx = Math.round(tmx/gridSnap)*gridSnap; tmy = Math.round(tmy/gridSnap)*gridSnap; }
    \\    var totalDx = tmx - draggingTrace.startMx, totalDy = tmy - draggingTrace.startMy;
    \\    var t = data.traces[draggingTrace.index];
    \\    var si = draggingTrace.segIndex;
    \\    var orig = draggingTrace.origPts;
    \\    // Determine segment type from original points
    \\    var segDx = orig[si+1][0] - orig[si][0], segDy = orig[si+1][1] - orig[si][1];
    \\    var aSegDx = Math.abs(segDx), aSegDy = Math.abs(segDy);
    \\    // Perpendicular offset: project mouse delta onto perpendicular direction
    \\    var perpD = 0;
    \\    if (aSegDy < aSegDx * 0.2) {
    \\      // Horizontal segment — moves vertically
    \\      perpD = totalDy;
    \\      // Shift segment vertically
    \\      t.points[si] = [orig[si][0], orig[si][1] + perpD];
    \\      t.points[si+1] = [orig[si+1][0], orig[si+1][1] + perpD];
    \\      // Adjust previous neighbor to maintain angle
    \\      if (si > 0) {
    \\        var prevDx = orig[si][0] - orig[si-1][0], prevDy = orig[si][1] - orig[si-1][1];
    \\        if (Math.abs(prevDx) < 0.001) { // prev was vertical: just update y
    \\          t.points[si] = [orig[si-1][0], orig[si][1] + perpD];
    \\        } else if (Math.abs(Math.abs(prevDx) - Math.abs(prevDy)) < 0.1) { // prev was 45°
    \\          t.points[si] = [orig[si][0] + perpD * (prevDx > 0 ? 1 : -1) * (prevDy > 0 ? 1 : -1), orig[si][1] + perpD];
    \\        }
    \\      }
    \\      // Adjust next neighbor
    \\      if (si+2 < orig.length) {
    \\        var nextDx = orig[si+2][0] - orig[si+1][0], nextDy = orig[si+2][1] - orig[si+1][1];
    \\        if (Math.abs(nextDx) < 0.001) { // next was vertical
    \\          t.points[si+1] = [orig[si+2][0], orig[si+1][1] + perpD];
    \\        } else if (Math.abs(Math.abs(nextDx) - Math.abs(nextDy)) < 0.1) { // next was 45°
    \\          t.points[si+1] = [orig[si+1][0] + perpD * (nextDx > 0 ? -1 : 1) * (nextDy > 0 ? 1 : -1), orig[si+1][1] + perpD];
    \\        }
    \\      }
    \\    } else if (aSegDx < aSegDy * 0.2) {
    \\      // Vertical segment — moves horizontally
    \\      perpD = totalDx;
    \\      t.points[si] = [orig[si][0] + perpD, orig[si][1]];
    \\      t.points[si+1] = [orig[si+1][0] + perpD, orig[si+1][1]];
    \\      if (si > 0) {
    \\        var prevDy2 = orig[si][1] - orig[si-1][1];
    \\        if (Math.abs(prevDy2) < 0.001) {
    \\          t.points[si] = [orig[si][0] + perpD, orig[si-1][1]];
    \\        } else if (Math.abs(Math.abs(orig[si][0]-orig[si-1][0]) - Math.abs(prevDy2)) < 0.1) {
    \\          t.points[si] = [orig[si][0] + perpD, orig[si][1] + perpD * (prevDy2 > 0 ? (orig[si][0] > orig[si-1][0] ? 1 : -1) : (orig[si][0] > orig[si-1][0] ? -1 : 1))];
    \\        }
    \\      }
    \\      if (si+2 < orig.length) {
    \\        var nextDy2 = orig[si+2][1] - orig[si+1][1];
    \\        if (Math.abs(nextDy2) < 0.001) {
    \\          t.points[si+1] = [orig[si+1][0] + perpD, orig[si+2][1]];
    \\        } else if (Math.abs(Math.abs(orig[si+2][0]-orig[si+1][0]) - Math.abs(nextDy2)) < 0.1) {
    \\          t.points[si+1] = [orig[si+1][0] + perpD, orig[si+1][1] + perpD * (nextDy2 > 0 ? (orig[si+1][0] > orig[si+2][0] ? 1 : -1) : (orig[si+1][0] > orig[si+2][0] ? -1 : 1))];
    \\        }
    \\      }
    \\    } else {
    \\      // 45° segment — moves perpendicular (the other 45° direction)
    \\      // Perpendicular to (1,1) is (1,-1) and vice versa
    \\      var sgnX = segDx > 0 ? 1 : -1, sgnY = segDy > 0 ? 1 : -1;
    \\      // Project delta onto perpendicular: perp direction is (sgnX, -sgnY)/sqrt(2)
    \\      perpD = (totalDx * sgnX - totalDy * sgnY) / 2;
    \\      var dpx = perpD * sgnX, dpy = -perpD * sgnY;
    \\      t.points[si] = [orig[si][0] + dpx, orig[si][1] + dpy];
    \\      t.points[si+1] = [orig[si+1][0] + dpx, orig[si+1][1] + dpy];
    \\      // Adjust neighbors for 45° segment drag
    \\      if (si > 0) {
    \\        var pDx = orig[si][0] - orig[si-1][0], pDy = orig[si][1] - orig[si-1][1];
    \\        if (Math.abs(pDy) < 0.001) { // prev horizontal
    \\          t.points[si] = [t.points[si][0], orig[si-1][1]]; // keep y at prev level
    \\          t.points[si][0] = orig[si][0] + (t.points[si][1] - orig[si][1]) * sgnX * sgnY;
    \\        } else if (Math.abs(pDx) < 0.001) { // prev vertical
    \\          t.points[si] = [orig[si-1][0], t.points[si][1]]; // keep x at prev level
    \\        }
    \\      }
    \\      if (si+2 < orig.length) {
    \\        var nDx = orig[si+2][0] - orig[si+1][0], nDy = orig[si+2][1] - orig[si+1][1];
    \\        if (Math.abs(nDy) < 0.001) {
    \\          t.points[si+1] = [t.points[si+1][0], orig[si+2][1]];
    \\          t.points[si+1][0] = orig[si+1][0] + (t.points[si+1][1] - orig[si+1][1]) * sgnX * sgnY;
    \\        } else if (Math.abs(nDx) < 0.001) {
    \\          t.points[si+1] = [orig[si+2][0], t.points[si+1][1]];
    \\        }
    \\      }
    \\    }
    \\    // Snap all modified points to grid
    \\    if (gridSnap > 0) {
    \\      t.points[si] = [Math.round(t.points[si][0]/gridSnap)*gridSnap, Math.round(t.points[si][1]/gridSnap)*gridSnap];
    \\      t.points[si+1] = [Math.round(t.points[si+1][0]/gridSnap)*gridSnap, Math.round(t.points[si+1][1]/gridSnap)*gridSnap];
    \\    }
    \\    // Redraw trace
    \\    var tgfx = findTraceGfx(draggingTrace.index);
    \\    if (tgfx) {
    \\      tgfx.clear();
    \\      tgfx.moveTo(t.points[0][0]*SCALE, t.points[0][1]*SCALE);
    \\      for (var tpi=1; tpi<t.points.length; tpi++) tgfx.lineTo(t.points[tpi][0]*SCALE, t.points[tpi][1]*SCALE);
    \\      tgfx.stroke({color: t.layer==='F.Cu' ? C.fcu : C.bcu, width: t.width*SCALE, cap:'round', join:'round'});
    \\    }
    \\    return;
    \\  }
    \\  if (!isDragging || !dragTarget) return;
    \\  var wp = e.getLocalPosition(world);
    \\  var dist = Math.abs(wp.x - dragStartPos.x) + Math.abs(wp.y - dragStartPos.y);
    \\  if (dist > 2) wasDrag = true;
    \\  var nx = wp.x + dragOffset.x;
    \\  var ny = wp.y + dragOffset.y;
    \\  // Grid snap
    \\  if (gridSnap > 0) {
    \\    var gs = gridSnap * SCALE;
    \\    nx = Math.round(nx / gs) * gs;
    \\    ny = Math.round(ny / gs) * gs;
    \\  }
    \\  var dx = nx - dragTarget.x, dy = ny - dragTarget.y;
    \\  dragTarget.x = nx;
    \\  dragTarget.y = ny;
    \\  // Update ref label position
    \\  if (dragTarget._refLabel) {
    \\    var fp = dragTarget._fpData;
    \\    dragTarget._refLabel.x = nx;
    \\    dragTarget._refLabel.y = ny - (fp.courtyard ? fp.courtyard.y1 * SCALE - 2 : 4);
    \\  }
    \\  // Update ratsnest live
    \\  var fpd = dragTarget._fpData;
    \\  if (fpd) {
    \\    fpd.x = nx / SCALE;
    \\    fpd.y = ny / SCALE;
    \\  }
    \\  // Group drag: move all section components + traces + vias by the same delta
    \\  if (selectedSection !== null && sectionUuids.length > 0) {
    \\    for (var gi=0; gi<sectionUuids.length; gi++) {
    \\      var gu = sectionUuids[gi];
    \\      if (gu === dragTarget._uuid) continue;
    \\      var gfc = fpContainers[gu];
    \\      if (!gfc) continue;
    \\      gfc.x += dx; gfc.y += dy;
    \\      var gfp = fpData[gu];
    \\      if (gfp) { gfp.x = gfc.x / SCALE; gfp.y = gfc.y / SCALE; }
    \\      if (gfc._refLabel) {
    \\        gfc._refLabel.x = gfc.x;
    \\        gfc._refLabel.y = gfc.y - (gfp && gfp.courtyard ? gfp.courtyard.y1*SCALE-2 : 4);
    \\      }
    \\    }
    \\    // Move section traces (identified by ID, already split)
    \\    var dxMm = dx / SCALE, dyMm = dy / SCALE;
    \\    for (var sti=0; sti<data.traces.length; sti++) {
    \\      var st = data.traces[sti];
    \\      if (!sectionTraceIds[st.id]) continue;
    \\      for (var spi=0; spi<st.points.length; spi++) {
    \\        st.points[spi] = [st.points[spi][0]+dxMm, st.points[spi][1]+dyMm];
    \\      }
    \\      var stgfx = findTraceGfx(sti);
    \\      if (stgfx) {
    \\        stgfx.clear();
    \\        stgfx.moveTo(st.points[0][0]*SCALE, st.points[0][1]*SCALE);
    \\        for (var tpi=1; tpi<st.points.length; tpi++) stgfx.lineTo(st.points[tpi][0]*SCALE, st.points[tpi][1]*SCALE);
    \\        stgfx.stroke({color: st.layer==='F.Cu' ? C.fcu : C.bcu, width: st.width*SCALE, cap:'round', join:'round'});
    \\      }
    \\    }
    \\    // Move section vias (identified by ID)
    \\    for (var svi=0; svi<data.vias.length; svi++) {
    \\      var sv = data.vias[svi];
    \\      if (!sectionViaIds[sv.id]) continue;
    \\      sv.x += dxMm; sv.y += dyMm;
    \\      var svgfx = findViaGfx(svi);
    \\      if (svgfx) {
    \\        svgfx.clear();
    \\        svgfx.circle(sv.x*SCALE, sv.y*SCALE, sv.pad_size/2*SCALE);
    \\        svgfx.fill({color: 0xC0C0C0, alpha: 0.9});
    \\        svgfx.circle(sv.x*SCALE, sv.y*SCALE, sv.drill/2*SCALE);
    \\        svgfx.fill({color: 0x0d1117});
    \\      }
    \\    }
    \\  }
    \\  // Sync sidebar position inputs
    \\  var px = document.getElementById('pos-x'), py = document.getElementById('pos-y');
    \\  if (px && fpd) { px.value = fpd.x.toFixed(2); }
    \\  if (py && fpd) { py.value = fpd.y.toFixed(2); }
    \\  buildRatsnest();
    \\  updateSectionBoxes();
    \\});
    \\
    \\app.stage.on('pointerup', function(e) {
    \\  // Finish box selection
    \\  if (boxSelecting) {
    \\    boxSelecting = false;
    \\    var wpb3 = e.getLocalPosition(world);
    \\    var bx2 = wpb3.x / SCALE, by2 = wpb3.y / SCALE;
    \\    if (boxGfx) { boxGfx.destroy(); boxGfx = null; }
    \\    var rx1 = Math.min(boxStart.x, bx2), ry1 = Math.min(boxStart.y, by2);
    \\    var rx2 = Math.max(boxStart.x, bx2), ry2 = Math.max(boxStart.y, by2);
    \\    if (rx2-rx1 < 0.5 && ry2-ry1 < 0.5) return; // too small, ignore
    \\    finalizeBoxSelection(rx1, ry1, rx2, ry2);
    \\    return;
    \\  }
    \\  // Finish multi-selection drag
    \\  if (multiSelection && multiSelection._dragging) {
    \\    multiSelection._dragging = false;
    \\    skipFitView = true;
    \\    buildScene();
    \\    buildRatsnest();
    \\    dirty = true; scheduleSave();
    \\    // Re-highlight
    \\    highlightMultiSelection();
    \\    return;
    \\  }
    \\  if (draggingVia) {
    \\    var moved = data.vias[draggingVia.index].x !== draggingVia.startX || data.vias[draggingVia.index].y !== draggingVia.startY;
    \\    if (moved) {
    \\      skipFitView = true;
    \\      buildScene();
    \\      buildRatsnest();
    \\      dirty = true; scheduleSave();
    \\    }
    \\    draggingVia = null;
    \\  }
    \\  if (draggingTrace) {
    \\    skipFitView = true;
    \\    buildScene();
    \\    buildRatsnest();
    \\    dirty = true; scheduleSave();
    \\    draggingTrace = null;
    \\  }
    \\  if (isDragging && dragTarget) {
    \\    dragTarget.cursor = 'grab';
    \\    dragTarget.alpha = 1;
    \\    // Click without drag: cycle to next overlapping component
    \\    if (!wasDrag && selectedUuid) {
    \\      var mx = dragStartPos.x / SCALE, my = dragStartPos.y / SCALE;
    \\      var hits = findComponentsAtPoint(mx, my);
    \\      if (hits.length > 1) {
    \\        var curIdx = -1;
    \\        for (var hi=0; hi<hits.length; hi++) {
    \\          if (hits[hi].uuid === selectedUuid) { curIdx = hi; break; }
    \\        }
    \\        var nextIdx = (curIdx + 1) % hits.length;
    \\        selectComponent(hits[nextIdx].uuid);
    \\      }
    \\    }
    \\    buildRatsnest();
    \\    checkOverlaps();
    \\    if (wasDrag) { dirty = true; scheduleSave(); }
    \\  }
    \\  isDragging = false;
    \\  dragTarget = null;
    \\});
    \\
    \\app.stage.on('pointerdown', function(e) {
    \\  // Routing waypoint on empty space click
    \\  if (selectMode === 'route' && routingNet && routingPoints.length > 0) {
    \\    var wp = e.getLocalPosition(world);
    \\    var mx = wp.x / SCALE, my = wp.y / SCALE;
    \\    if (gridSnap > 0) { mx = Math.round(mx/gridSnap)*gridSnap; my = Math.round(my/gridSnap)*gridSnap; }
    \\    if (viaPreviewMode) {
    \\      // Place via at click position
    \\      addRoutingViaAt(mx, my);
    \\      viaPreviewMode = false;
    \\      if (viaPreviewGfx) { viaPreviewGfx.destroy(); viaPreviewGfx = null; }
    \\      return;
    \\    }
    \\    var last = routingPoints[routingPoints.length - 1];
    \\    var nudged = nudgeForClearance(last, [mx, my], routingWidth, routingLayer, baseNetName(routingNet));
    \\    var segs = constrainRoute(last, nudged);
    \\    for (var si=0; si<segs.length; si++) routingPoints.push(segs[si]);
    \\    return;
    \\  }
    \\  if (!isDragging) {
    \\    // Check if click is near a trace or via (for selection/drag)
    \\    // In 'trace' mode: only traces/vias. In 'component' mode: skip traces/vias.
    \\    if (selectMode === 'trace') {
    \\      var wp3 = e.getLocalPosition(world);
    \\      var cmx = wp3.x / SCALE, cmy = wp3.y / SCALE;
    \\      var hit = findTraceOrViaAt(cmx, cmy);
    \\      if (hit) {
    \\        if (hit.type === 'trace') {
    \\          selectTraceOrVia('trace', hit.index, hit.data, findTraceGfx(hit.index));
    \\          pushUndo();
    \\          // Store original points for constrained drag
    \\          var origPts = [];
    \\          var dt = data.traces[hit.index];
    \\          for (var opi=0; opi<dt.points.length; opi++) origPts.push([dt.points[opi][0], dt.points[opi][1]]);
    \\          draggingTrace = {index: hit.index, segIndex: hit.segIndex, startMx: cmx, startMy: cmy, origPts: origPts};
    \\        } else {
    \\          selectTraceOrVia('via', hit.index, hit.data, findViaGfx(hit.index));
    \\          pushUndo();
    \\          draggingVia = {index: hit.index, startX: hit.data.x, startY: hit.data.y};
    \\        }
    \\        return;
    \\      }
    \\    }
    \\    // Shift+click on empty space: start box selection
    \\    if (e.data && e.data.originalEvent && e.data.originalEvent.shiftKey) {
    \\      var wpb = e.getLocalPosition(world);
    \\      boxStart = {x: wpb.x / SCALE, y: wpb.y / SCALE};
    \\      boxSelecting = true;
    \\      if (boxGfx) { boxGfx.destroy(); boxGfx = null; }
    \\      return;
    \\    }
    \\    if (multiSelection) {
    \\      // Check if click is inside multi-selection (on a selected item) — start drag
    \\      var wpm2 = e.getLocalPosition(world);
    \\      var mmx2 = wpm2.x / SCALE, mmy2 = wpm2.y / SCALE;
    \\      var inSel = false;
    \\      for (var mi=0; mi<multiSelection.uuids.length; mi++) {
    \\        var fp = fpData[multiSelection.uuids[mi]];
    \\        if (fp) {
    \\          var aabb = courtyardAABB(fp);
    \\          if (aabb && mmx2>=aabb.x1 && mmx2<=aabb.x2 && mmy2>=aabb.y1 && mmy2<=aabb.y2) { inSel = true; break; }
    \\        }
    \\      }
    \\      if (!inSel) {
    \\        var hit2 = findTraceOrViaAt(mmx2, mmy2);
    \\        if (hit2 && ((hit2.type==='trace' && multiSelection.traceIds[hit2.data.id]) || (hit2.type==='via' && multiSelection.viaIds[hit2.data.id]))) inSel = true;
    \\      }
    \\      if (inSel) {
    \\        pushUndo();
    \\        if (gridSnap > 0) { mmx2 = Math.round(mmx2/gridSnap)*gridSnap; mmy2 = Math.round(mmy2/gridSnap)*gridSnap; }
    \\        multiSelection._dragging = true;
    \\        multiSelection._lastMx = mmx2;
    \\        multiSelection._lastMy = mmy2;
    \\        return;
    \\      }
    \\      clearMultiSelection(); return;
    \\    }
    \\    clearSelection();
    \\  }
    \\});
    \\
    \\// --- Box / Multi Selection ---
    \\function finalizeBoxSelection(rx1, ry1, rx2, ry2) {
    \\  clearSelection();
    \\  multiSelection = {uuids:[], traceIds:{}, viaIds:{}, _dragging:false, _lastMx:0, _lastMy:0};
    \\  // Components whose center is in the box
    \\  for (var uuid in fpData) {
    \\    var fp = fpData[uuid];
    \\    if (fp.x >= rx1 && fp.x <= rx2 && fp.y >= ry1 && fp.y <= ry2) {
    \\      multiSelection.uuids.push(uuid);
    \\    }
    \\  }
    \\  // Traces where all points are in the box
    \\  if (data.traces) {
    \\    for (var ti=0; ti<data.traces.length; ti++) {
    \\      var t = data.traces[ti];
    \\      var allIn = true;
    \\      for (var pi=0; pi<t.points.length; pi++) {
    \\        if (t.points[pi][0] < rx1 || t.points[pi][0] > rx2 || t.points[pi][1] < ry1 || t.points[pi][1] > ry2) { allIn = false; break; }
    \\      }
    \\      if (allIn && t.id) multiSelection.traceIds[t.id] = true;
    \\    }
    \\  }
    \\  // Vias in the box
    \\  if (data.vias) {
    \\    for (var vi=0; vi<data.vias.length; vi++) {
    \\      var v = data.vias[vi];
    \\      if (v.x >= rx1 && v.x <= rx2 && v.y >= ry1 && v.y <= ry2 && v.id) {
    \\        multiSelection.viaIds[v.id] = true;
    \\      }
    \\    }
    \\  }
    \\  var total = multiSelection.uuids.length + Object.keys(multiSelection.traceIds).length + Object.keys(multiSelection.viaIds).length;
    \\  if (total === 0) { multiSelection = null; return; }
    \\  highlightMultiSelection();
    \\  showMultiSelectionSidebar();
    \\}
    \\
    \\var multiHighlightGfx = null;
    \\
    \\function highlightMultiSelection() {
    \\  if (!multiSelection) return;
    \\  for (var mi=0; mi<multiSelection.uuids.length; mi++) {
    \\    var fc = fpContainers[multiSelection.uuids[mi]];
    \\    if (fc) fc.tint = C.highlight;
    \\  }
    \\  // Draw bright outlines for traces and vias
    \\  if (multiHighlightGfx) { multiHighlightGfx.destroy(); multiHighlightGfx = null; }
    \\  multiHighlightGfx = new PIXI.Graphics();
    \\  if (data.traces) {
    \\    for (var ti=0; ti<data.traces.length; ti++) {
    \\      var t = data.traces[ti];
    \\      if (!t.id || !multiSelection.traceIds[t.id]) continue;
    \\      multiHighlightGfx.moveTo(t.points[0][0]*SCALE, t.points[0][1]*SCALE);
    \\      for (var pi=1; pi<t.points.length; pi++) multiHighlightGfx.lineTo(t.points[pi][0]*SCALE, t.points[pi][1]*SCALE);
    \\      multiHighlightGfx.stroke({color: 0x58a6ff, width: (t.width+0.3)*SCALE, alpha: 0.5, cap:'round', join:'round'});
    \\    }
    \\  }
    \\  if (data.vias) {
    \\    for (var vi=0; vi<data.vias.length; vi++) {
    \\      var v = data.vias[vi];
    \\      if (!v.id || !multiSelection.viaIds[v.id]) continue;
    \\      multiHighlightGfx.circle(v.x*SCALE, v.y*SCALE, (v.pad_size/2+0.2)*SCALE);
    \\      multiHighlightGfx.stroke({color: 0x58a6ff, width: 0.3*SCALE, alpha: 0.7});
    \\    }
    \\  }
    \\  world.addChild(multiHighlightGfx);
    \\}
    \\
    \\function clearMultiSelection() {
    \\  if (!multiSelection) return;
    \\  for (var mi=0; mi<multiSelection.uuids.length; mi++) {
    \\    var fc = fpContainers[multiSelection.uuids[mi]];
    \\    if (fc) fc.tint = 0xFFFFFF;
    \\  }
    \\  if (multiHighlightGfx) { multiHighlightGfx.destroy(); multiHighlightGfx = null; }
    \\  multiSelection = null;
    \\  showDefaultSidebar();
    \\}
    \\
    \\function showMultiSelectionSidebar() {
    \\  if (!multiSelection) return;
    \\  var nc = multiSelection.uuids.length, nt = Object.keys(multiSelection.traceIds).length, nv = Object.keys(multiSelection.viaIds).length;
    \\  sidebar.innerHTML = '<h3 style="color:#58a6ff;margin:0 0 12px">Multi-Selection</h3>'
    \\    + '<div style="margin-bottom:6px"><b>' + nc + '</b> components, <b>' + nt + '</b> traces, <b>' + nv + '</b> vias</div>'
    \\    + '<div style="color:#666;font-size:11px;margin-bottom:12px">Drag to move all. Delete to remove traces/vias.</div>'
    \\    + '<button id="multi-delete" style="background:#da3633;color:#fff;border:none;border-radius:6px;padding:6px 16px;cursor:pointer;font-size:12px">Delete Traces/Vias</button>';
    \\  document.getElementById('multi-delete').onclick = function() { deleteMultiSelection(); };
    \\}
    \\
    \\function deleteMultiSelection() {
    \\  if (!multiSelection) return;
    \\  pushUndo();
    \\  // Delete traces
    \\  if (data.traces) {
    \\    data.traces = data.traces.filter(function(t) { return !multiSelection.traceIds[t.id]; });
    \\  }
    \\  // Delete vias
    \\  if (data.vias) {
    \\    data.vias = data.vias.filter(function(v) { return !multiSelection.viaIds[v.id]; });
    \\  }
    \\  multiSelection = null;
    \\  skipFitView = true;
    \\  buildScene();
    \\  dirty = true; scheduleSave();
    \\  showDefaultSidebar();
    \\}
    \\
    \\// --- Keyboard Shortcuts ---
    \\document.addEventListener('keydown', function(e) {
    \\  if (e.key === 'z' && (e.ctrlKey || e.metaKey) && !e.shiftKey) {
    \\    e.preventDefault();
    \\    popUndo();
    \\    return;
    \\  }
    \\  if (e.key === 'r' || e.key === 'R') {
    \\    if (selectedSection !== null && sectionUuids.length > 0) {
    \\      pushUndo();
    \\      var step = e.shiftKey ? 45 : 90;
    \\      var rad = step * Math.PI / 180;
    \\      var cos = Math.cos(rad), sin = Math.sin(rad);
    \\      // Find section center
    \\      var cx = 0, cy = 0;
    \\      for (var si=0; si<sectionUuids.length; si++) {
    \\        var sfp = fpData[sectionUuids[si]];
    \\        if (sfp) { cx += sfp.x; cy += sfp.y; }
    \\      }
    \\      cx /= sectionUuids.length; cy /= sectionUuids.length;
    \\      for (var si=0; si<sectionUuids.length; si++) {
    \\        var sfp = fpData[sectionUuids[si]];
    \\        var sfc = fpContainers[sectionUuids[si]];
    \\        if (!sfp || !sfc) continue;
    \\        var dx = sfp.x - cx, dy = sfp.y - cy;
    \\        sfp.x = cx + dx*cos - dy*sin;
    \\        sfp.y = cy + dx*sin + dy*cos;
    \\        sfp.angle = ((sfp.angle||0) + step) % 360;
    \\        sfc.x = sfp.x * SCALE; sfc.y = sfp.y * SCALE;
    \\        sfc.angle = sfp.angle;
    \\        if (sfc._refLabel) { sfc._refLabel.x = sfc.x; sfc._refLabel.y = sfc.y - (sfp.courtyard ? sfp.courtyard.y1*SCALE-2 : 4); }
    \\      }
    \\      buildRatsnest(); checkOverlaps(); updateSectionBoxes();
    \\      dirty = true; scheduleSave();
    \\    } else if (selectedUuid && fpContainers[selectedUuid]) {
    \\      pushUndo();
    \\      var fc = fpContainers[selectedUuid];
    \\      var step = e.shiftKey ? 45 : 90;
    \\      fc.angle = (fc.angle + step) % 360;
    \\      var fpd = fpData[selectedUuid];
    \\      if (fpd) fpd.angle = fc.angle;
    \\      buildRatsnest(); checkOverlaps();
    \\      dirty = true;
    \\      scheduleSave();
    \\    }
    \\  }
    \\  if (e.key === 'f' && !e.ctrlKey && !e.metaKey) {
    \\    if (selectedSection !== null && sectionUuids.length > 0) {
    \\      pushUndo();
    \\      // Find section center
    \\      var cx2 = 0, cy2 = 0;
    \\      for (var si=0; si<sectionUuids.length; si++) {
    \\        var sfp = fpData[sectionUuids[si]];
    \\        if (sfp) { cx2 += sfp.x; cy2 += sfp.y; }
    \\      }
    \\      cx2 /= sectionUuids.length; cy2 /= sectionUuids.length;
    \\      for (var si=0; si<sectionUuids.length; si++) {
    \\        var sfp = fpData[sectionUuids[si]];
    \\        if (!sfp) continue;
    \\        // Mirror X around center, flip layer
    \\        sfp.x = cx2 - (sfp.x - cx2);
    \\        sfp.layer = sfp.layer === 'F.Cu' ? 'B.Cu' : 'F.Cu';
    \\      }
    \\      var savedSection = selectedSection;
    \\      skipFitView = true;
    \\      buildScene();
    \\      selectSection(savedSection);
    \\      dirty = true; scheduleSave();
    \\    } else if (selectedUuid && fpContainers[selectedUuid]) {
    \\      pushUndo();
    \\      var fpd2 = fpData[selectedUuid];
    \\      if (fpd2) {
    \\        fpd2.layer = fpd2.layer === 'F.Cu' ? 'B.Cu' : 'F.Cu';
    \\        var wasDragging = isDragging;
    \\        skipFitView = true;
    \\        buildScene();
    \\        selectComponent(selectedUuid);
    \\        if (wasDragging && selectedUuid && fpContainers[selectedUuid]) {
    \\          dragTarget = fpContainers[selectedUuid];
    \\          dragTarget.cursor = 'grabbing';
    \\          dragTarget.alpha = 0.8;
    \\        }
    \\        dirty = true;
    \\        scheduleSave();
    \\      }
    \\    }
    \\  }
    \\  if (e.key === 'Escape') {
    \\    if (routingNet) { cancelRouting(); showDefaultSidebar(); }
    \\    else clearSelection();
    \\  }
    \\  if (e.key === 'Delete' || e.key === 'Backspace') {
    \\    if (multiSelection) { e.preventDefault(); deleteMultiSelection(); }
    \\    else if (selectedRouteType !== null) { e.preventDefault(); deleteSelectedRoute(); }
    \\  }
    \\  if (e.key === 'g' && !e.ctrlKey && !e.metaKey) {
    \\    var idx = GRID_OPTIONS.indexOf(gridSnap);
    \\    gridSnap = GRID_OPTIONS[(idx + 1) % GRID_OPTIONS.length];
    \\    updateGridBtn();
    \\  }
    \\  if (e.key === 'x' && !e.ctrlKey && !e.metaKey && selectMode !== 'route') {
    \\    setSelectMode('route');
    \\  }
    \\  if (e.key === 't' && !e.ctrlKey && !e.metaKey && !routingNet) {
    \\    setSelectMode('trace');
    \\  }
    \\  if (e.key === 'v' && !e.ctrlKey && !e.metaKey && routingNet) {
    \\    viaPreviewMode = !viaPreviewMode;
    \\    if (!viaPreviewMode && viaPreviewGfx) { viaPreviewGfx.destroy(); viaPreviewGfx = null; }
    \\  }
    \\  if (e.key === '/' && routingNet) {
    \\    routingBendHV = !routingBendHV;
    \\  }
    \\  if (e.key === 'Enter' && routingNet) {
    \\    if (routingPoints.length >= 2) {
    \\      // Save trace at last clicked waypoint
    \\      if (!data.traces) data.traces = [];
    \\      data.traces.push({id: uid(), net: baseNetName(routingNet), layer: routingLayer, width: routingWidth, points: routingPoints.slice()});
    \\      dirty = true; scheduleSave();
    \\    }
    \\    // End routing (works even with 1 point, e.g. right after a via)
    \\    cancelRouting();
    \\    skipFitView = true;
    \\    buildScene();
    \\    showDefaultSidebar();
    \\  }
    \\});
    \\
    \\// --- Selection ---
    \\function selectComponent(uuid) {
    \\  clearSelection();
    \\  selectedUuid = uuid;
    \\  var fc = fpContainers[uuid];
    \\  if (fc) fc.tint = C.highlight;
    \\  showComponentSidebar(uuid);
    \\}
    \\
    \\function highlightNet(netName) {
    \\  clearSelection();
    \\  selectedNet = netName;
    \\  // Highlight all pads whose base net matches
    \\  for (var uuid in fpData) {
    \\    var fp = fpData[uuid];
    \\    var fc = fpContainers[uuid];
    \\    if (!fc) continue;
    \\    for (var i=0; i<fc.children.length; i++) {
    \\      var child = fc.children[i];
    \\      if (child._padData && baseNetName(child._padData.net_name) === netName) {
    \\        child.tint = C.highlight;
    \\      }
    \\    }
    \\  }
    \\  // Highlight ratsnest lines whose base net matches
    \\  for (var i=0; i<layerContainers.ratsnest.children.length; i++) {
    \\    var rg = layerContainers.ratsnest.children[i];
    \\    if (baseNetName(rg._netName) === netName) rg.tint = C.highlight;
    \\  }
    \\  showNetSidebar(netName);
    \\}
    \\
    \\function clearSelection() {
    \\  if (selectedUuid && fpContainers[selectedUuid]) {
    \\    fpContainers[selectedUuid].tint = 0xFFFFFF;
    \\  }
    \\  if (selectedNet || selectedSection !== null) {
    \\    for (var uuid in fpContainers) {
    \\      var fc = fpContainers[uuid];
    \\      fc.tint = 0xFFFFFF;
    \\      for (var i=0; i<fc.children.length; i++) {
    \\        fc.children[i].tint = 0xFFFFFF;
    \\      }
    \\    }
    \\    for (var i=0; i<layerContainers.ratsnest.children.length; i++) {
    \\      layerContainers.ratsnest.children[i].tint = 0xFFFFFF;
    \\    }
    \\  }
    \\  selectedUuid = null;
    \\  selectedNet = null;
    \\  selectedSection = null;
    \\  sectionUuids = [];
    \\  selectedRouteType = null;
    \\  selectedRouteIndex = -1;
    \\  if (selectedRouteGfx) { selectedRouteGfx.tint = 0xFFFFFF; selectedRouteGfx = null; }
    \\  if (selectionHighlightGfx) { selectionHighlightGfx.destroy(); selectionHighlightGfx = null; }
    \\  sectionTraceIds = {};
    \\  sectionViaIds = {};
    \\  buildRatsnest();
    \\  showDefaultSidebar();
    \\}
    \\
    \\// --- Trace/Via Selection ---
    \\var selectedRouteType = null; // 'trace' or 'via'
    \\var selectedRouteIndex = -1;
    \\var selectedRouteGfx = null;
    \\var selectionHighlightGfx = null; // bright outline drawn on top of selected trace/via
    \\
    \\function drawSelectionHighlight(type, itemData) {
    \\  if (selectionHighlightGfx) { selectionHighlightGfx.destroy(); selectionHighlightGfx = null; }
    \\  selectionHighlightGfx = new PIXI.Graphics();
    \\  if (type === 'trace') {
    \\    selectionHighlightGfx.moveTo(itemData.points[0][0]*SCALE, itemData.points[0][1]*SCALE);
    \\    for (var i=1; i<itemData.points.length; i++) selectionHighlightGfx.lineTo(itemData.points[i][0]*SCALE, itemData.points[i][1]*SCALE);
    \\    selectionHighlightGfx.stroke({color: 0x58a6ff, width: (itemData.width+0.3)*SCALE, alpha: 0.6, cap:'round', join:'round'});
    \\    selectionHighlightGfx.moveTo(itemData.points[0][0]*SCALE, itemData.points[0][1]*SCALE);
    \\    for (var i2=1; i2<itemData.points.length; i2++) selectionHighlightGfx.lineTo(itemData.points[i2][0]*SCALE, itemData.points[i2][1]*SCALE);
    \\    selectionHighlightGfx.stroke({color: 0xFFFFFF, width: itemData.width*SCALE*0.3, alpha: 0.4, cap:'round', join:'round'});
    \\  } else {
    \\    selectionHighlightGfx.circle(itemData.x*SCALE, itemData.y*SCALE, (itemData.pad_size/2+0.2)*SCALE);
    \\    selectionHighlightGfx.stroke({color: 0x58a6ff, width: 0.3*SCALE, alpha: 0.8});
    \\    selectionHighlightGfx.circle(itemData.x*SCALE, itemData.y*SCALE, (itemData.pad_size/2+0.1)*SCALE);
    \\    selectionHighlightGfx.fill({color: 0x58a6ff, alpha: 0.2});
    \\  }
    \\  world.addChild(selectionHighlightGfx);
    \\}
    \\
    \\function selectTraceOrVia(type, idx, itemData, gfx) {
    \\  clearSelection();
    \\  selectedRouteType = type;
    \\  selectedRouteIndex = idx;
    \\  selectedRouteGfx = gfx;
    \\  drawSelectionHighlight(type, itemData);
    \\  if (type === 'trace') {
    \\    var td = itemData;
    \\    var ptsStr = '';
    \\    for (var pi=0; pi<td.points.length; pi++) ptsStr += '<div style="color:#8b949e;font-size:11px;margin-left:8px">' + td.points[pi][0].toFixed(2) + ', ' + td.points[pi][1].toFixed(2) + '</div>';
    \\    sidebar.innerHTML = '<h3 style="color:' + (td.layer==='F.Cu'?'#CC3333':'#3333CC') + ';margin:0 0 12px">Trace</h3>'
    \\      + '<div style="margin-bottom:6px"><span style="color:#8b949e">Net:</span> <span style="color:#e8c547">' + (td.net||'none') + '</span></div>'
    \\      + '<div style="margin-bottom:6px"><span style="color:#8b949e">Layer:</span> ' + td.layer + '</div>'
    \\      + '<div style="margin-bottom:6px"><span style="color:#8b949e">Width:</span> ' + td.width.toFixed(2) + ' mm</div>'
    \\      + '<div style="margin-bottom:6px"><span style="color:#8b949e">Points:</span> ' + td.points.length + '</div>'
    \\      + ptsStr
    \\      + '<div style="color:#666;font-size:11px;margin-top:12px">Press Delete to remove</div>';
    \\  } else {
    \\    var vd = itemData;
    \\    sidebar.innerHTML = '<h3 style="color:#C0C0C0;margin:0 0 12px">Via</h3>'
    \\      + '<div style="margin-bottom:6px"><span style="color:#8b949e">Net:</span> <span style="color:#e8c547">' + (vd.net||'none') + '</span></div>'
    \\      + '<div style="margin-bottom:6px"><span style="color:#8b949e">Position:</span> ' + vd.x.toFixed(2) + ', ' + vd.y.toFixed(2) + ' mm</div>'
    \\      + '<div style="margin-bottom:6px"><span style="color:#8b949e">Drill:</span> ' + vd.drill.toFixed(2) + ' mm</div>'
    \\      + '<div style="margin-bottom:6px"><span style="color:#8b949e">Pad size:</span> ' + vd.pad_size.toFixed(2) + ' mm</div>'
    \\      + '<div style="margin-bottom:6px"><span style="color:#8b949e">Layers:</span> ' + (vd.from||'F.Cu') + ' \u2192 ' + (vd.to||'B.Cu') + '</div>'
    \\      + '<div style="color:#666;font-size:11px;margin-top:12px">Press Delete to remove</div>';
    \\  }
    \\}
    \\function deleteSelectedRoute() {
    \\  if (selectedRouteType === null || selectedRouteIndex < 0) return;
    \\  pushUndo();
    \\  if (selectedRouteType === 'trace') data.traces.splice(selectedRouteIndex, 1);
    \\  else data.vias.splice(selectedRouteIndex, 1);
    \\  selectedRouteType = null;
    \\  selectedRouteIndex = -1;
    \\  selectedRouteGfx = null;
    \\  skipFitView = true;
    \\  buildScene();
    \\  dirty = true; scheduleSave();
    \\  showDefaultSidebar();
    \\}
    \\
    \\// --- Sidebar ---
    \\var sidebar = document.getElementById('sidebar-content');
    \\
    \\function showDefaultSidebar() {
    \\  if (!data) { sidebar.innerHTML = ''; return; }
    \\  var html = '<h3 style="color:#fff;margin:0 0 12px;font-size:14px">PCB Layout</h3>';
    \\  html += '<div style="color:#8b949e;font-size:12px;margin-bottom:8px">' + data.footprints.length + ' components, ' + data.nets.length + ' nets</div>';
    \\  html += '<div style="color:#666;font-size:11px;margin-bottom:16px">Drag to place. R=rotate, F=flip, Ctrl+Z=undo</div>';
    \\  // Sections
    \\  if (data.sections && data.sections.length) {
    \\    html += '<h4 style="color:#8b949e;margin:0 0 8px;font-size:12px">Sections</h4>';
    \\    for (var si=0; si<data.sections.length; si++) {
    \\      var sec = data.sections[si];
    \\      html += '<div class="sec-item" style="cursor:pointer" onclick="window._pcbSelectSection('+si+')">';
    \\      html += '<span style="color:#3fb950;font-weight:600">' + sec.name + '</span>';
    \\      html += ' <span style="color:#666;font-size:11px">(' + sec.refs.length + ')</span>';
    \\      html += '</div>';
    \\    }
    \\  }
    \\  // DRC Rules
    \\  var rules = data.rules || {clearance:0.15, track_width:0.2, via_drill:0.3, via_size:0.6};
    \\  html += '<h4 style="color:#8b949e;margin:8px 0 8px;font-size:12px">DRC Rules</h4>';
    \\  html += '<div style="display:grid;grid-template-columns:auto 1fr;gap:4px 8px;font-size:11px;margin-bottom:12px">';
    \\  html += '<span style="color:#8b949e">Clearance</span><input id="drc-clearance" type="number" step="0.01" min="0.05" value="'+rules.clearance.toFixed(2)+'" style="width:60px;background:#21262d;color:#c9d1d9;border:1px solid #30363d;border-radius:3px;padding:2px 4px;font-size:11px">';
    \\  html += '<span style="color:#8b949e">Track width</span><input id="drc-track-width" type="number" step="0.05" min="0.05" value="'+rules.track_width.toFixed(2)+'" style="width:60px;background:#21262d;color:#c9d1d9;border:1px solid #30363d;border-radius:3px;padding:2px 4px;font-size:11px">';
    \\  html += '<span style="color:#8b949e">Via drill</span><input id="drc-via-drill" type="number" step="0.05" min="0.1" value="'+rules.via_drill.toFixed(2)+'" style="width:60px;background:#21262d;color:#c9d1d9;border:1px solid #30363d;border-radius:3px;padding:2px 4px;font-size:11px">';
    \\  html += '<span style="color:#8b949e">Via size</span><input id="drc-via-size" type="number" step="0.05" min="0.2" value="'+rules.via_size.toFixed(2)+'" style="width:60px;background:#21262d;color:#c9d1d9;border:1px solid #30363d;border-radius:3px;padding:2px 4px;font-size:11px">';
    \\  html += '</div>';
    \\
    \\  html += '<h4 style="color:#8b949e;margin:8px 0 8px;font-size:12px">Components</h4>';
    \\  for (var i=0; i<data.footprints.length; i++) {
    \\    var fp = data.footprints[i];
    \\    var eid = fp.uuid.replace(/[^a-z0-9]/g,'');
    \\    html += '<div class="sec-item" style="cursor:pointer" onclick="window._pcbSelect(\''+fp.uuid+'\')">';
    \\    html += '<span style="color:#4a9eff;font-weight:600">' + fp.ref + '</span>';
    \\    html += ' <span style="color:#666">' + (fp.value || fp.component) + '</span>';
    \\    html += '</div>';
    \\  }
    \\  sidebar.innerHTML = html;
    \\  // Bind DRC rule inputs
    \\  function bindDrc(id, key) {
    \\    var el = document.getElementById(id);
    \\    if (!el) return;
    \\    el.onchange = function() {
    \\      var v = parseFloat(this.value);
    \\      if (isNaN(v) || v <= 0) return;
    \\      if (!data.rules) data.rules = {clearance:0.15, track_width:0.2, via_drill:0.3, via_size:0.6};
    \\      data.rules[key] = v;
    \\      // Save rules to server
    \\      fetch('/api/pcb-rules/' + DESIGN_NAME, {
    \\        method: 'POST',
    \\        headers: {'Content-Type':'application/json'},
    \\        body: JSON.stringify(data.rules)
    \\      });
    \\    };
    \\  }
    \\  bindDrc('drc-clearance', 'clearance');
    \\  bindDrc('drc-track-width', 'track_width');
    \\  bindDrc('drc-via-drill', 'via_drill');
    \\  bindDrc('drc-via-size', 'via_size');
    \\}
    \\
    \\function showComponentSidebar(uuid) {
    \\  var fp = fpData[uuid];
    \\  if (!fp) return;
    \\  var html = '<h3 style="color:#4a9eff;margin:0 0 8px">' + fp.ref + '</h3>';
    \\  html += '<div style="font-size:13px;color:#8b949e;margin-bottom:8px">' + fp.component + '</div>';
    \\  var secName = null;
    \\  if (data.sections) { for (var si=0; si<data.sections.length; si++) { if (data.sections[si].refs.indexOf(fp.ref) >= 0) { secName = data.sections[si].name; break; } } }
    \\  if (secName) html += '<div style="margin-bottom:8px;font-size:12px"><span style="color:#3fb950;cursor:pointer" onclick="window._pcbSelectSection('+data.sections.findIndex(function(s){return s.name===secName;})+')">' + secName + '</span></div>';
    \\  if (fp.value) html += '<div style="margin-bottom:8px;color:#c9d1d9"><b>Value:</b> ' + fp.value + '</div>';
    \\  // Editable position
    \\  var ist = 'style="width:70px;background:#0d1117;border:1px solid #30363d;color:#c9d1d9;padding:2px 6px;border-radius:3px;font-size:12px;font-family:monospace"';
    \\  html += '<div style="margin-bottom:6px;display:flex;align-items:center;gap:6px"><b style="width:24px">X:</b>';
    \\  html += '<input id="pos-x" type="number" step="0.05" value="'+fp.x.toFixed(2)+'" '+ist+'><span style="color:#666;font-size:11px">mm</span></div>';
    \\  html += '<div style="margin-bottom:10px;display:flex;align-items:center;gap:6px"><b style="width:24px">Y:</b>';
    \\  html += '<input id="pos-y" type="number" step="0.05" value="'+fp.y.toFixed(2)+'" '+ist+'><span style="color:#666;font-size:11px">mm</span></div>';
    \\  // Rotation
    \\  var bst = 'style="background:#21262d;color:#c9d1d9;border:1px solid #30363d;border-radius:4px;padding:4px 10px;cursor:pointer;font-size:12px"';
    \\  html += '<div style="margin-bottom:6px;display:flex;align-items:center;gap:6px"><b style="width:55px">Angle:</b>';
    \\  html += '<span id="angle-val" style="font-family:monospace;min-width:32px">' + (fp.angle||0) + '°</span>';
    \\  html += '<button id="rot-ccw" '+bst+' title="Rotate -90°">↶</button>';
    \\  html += '<button id="rot-cw" '+bst+' title="Rotate +90°">↷</button>';
    \\  html += '<button id="rot-45" '+bst+' title="Rotate +45°">45°</button></div>';
    \\  // Layer/flip
    \\  html += '<div style="margin-bottom:12px;display:flex;align-items:center;gap:6px"><b style="width:55px">Layer:</b>';
    \\  html += '<span id="layer-val" style="color:'+(fp.layer==='F.Cu'?'#CC3333':'#3333CC')+'">' + fp.layer + '</span>';
    \\  html += '<button id="flip-btn" '+bst+'>Flip</button></div>';
    \\  // Courtyard
    \\  if (fp.footprint) {
    \\    html += '<div style="margin-bottom:8px;border-top:1px solid #21262d;padding-top:8px;display:flex;align-items:center;justify-content:space-between">';
    \\    html += '<span style="font-size:12px;color:#8b949e">' + fp.footprint + '</span>';
    \\    html += '<button id="cy-edit-btn" '+bst+' style="font-size:11px">Edit Courtyard</button>';
    \\    html += '</div>';
    \\  }
    \\  // Pads table
    \\  html += '<div style="margin-top:8px;border-top:1px solid #21262d;padding-top:8px"><b>Pads:</b> ' + fp.pads.length + '</div>';
    \\  html += '<table style="width:100%;font-size:11px;border-collapse:collapse;margin-top:4px">';
    \\  for (var i=0; i<fp.pads.length; i++) {
    \\    var p = fp.pads[i];
    \\    var bn = baseNetName(p.net_name);
    \\    var dn = displayNetName(p.net_name);
    \\    var nc = bn ? 'style="color:#e8c547;cursor:pointer" onclick="window._pcbHighlightNet(\''+bn+'\')"' : 'style="color:#444"';
    \\    html += '<tr style="border-bottom:1px solid #21262d"><td style="padding:2px 4px;color:#666">' + p.name + '</td>';
    \\    html += '<td ' + nc + '>' + (dn || '-') + '</td></tr>';
    \\  }
    \\  html += '</table>';
    \\  sidebar.innerHTML = html;
    \\  // Wire up controls
    \\  var posX = document.getElementById('pos-x');
    \\  var posY = document.getElementById('pos-y');
    \\  function applyPos() {
    \\    var nx = parseFloat(posX.value), ny = parseFloat(posY.value);
    \\    if (isNaN(nx) || isNaN(ny)) return;
    \\    pushUndo();
    \\    if (gridSnap > 0) { nx = Math.round(nx/gridSnap)*gridSnap; ny = Math.round(ny/gridSnap)*gridSnap; }
    \\    fp.x = nx; fp.y = ny;
    \\    var fc = fpContainers[uuid]; if (!fc) return;
    \\    fc.x = nx * SCALE; fc.y = ny * SCALE;
    \\    if (fc._refLabel) { fc._refLabel.x = fc.x; fc._refLabel.y = fc.y - (fp.courtyard ? fp.courtyard.y1*SCALE-2 : 4); }
    \\    posX.value = nx.toFixed(2); posY.value = ny.toFixed(2);
    \\    buildRatsnest(); checkOverlaps(); dirty = true; scheduleSave();
    \\  }
    \\  posX.addEventListener('change', applyPos);
    \\  posY.addEventListener('change', applyPos);
    \\  function doRotate(step) {
    \\    pushUndo();
    \\    var fc = fpContainers[uuid]; if (!fc) return;
    \\    fc.angle = ((fc.angle||0) + step) % 360;
    \\    if (fc.angle < 0) fc.angle += 360;
    \\    fp.angle = fc.angle;
    \\    document.getElementById('angle-val').textContent = fp.angle + '°';
    \\    buildRatsnest(); checkOverlaps(); dirty = true; scheduleSave();
    \\  }
    \\  document.getElementById('rot-cw').onclick = function(){ doRotate(90); };
    \\  document.getElementById('rot-ccw').onclick = function(){ doRotate(-90); };
    \\  document.getElementById('rot-45').onclick = function(){ doRotate(45); };
    \\  document.getElementById('flip-btn').onclick = function() {
    \\    pushUndo();
    \\    fp.layer = fp.layer === 'F.Cu' ? 'B.Cu' : 'F.Cu';
    \\    skipFitView = true;
    \\    buildScene(); selectComponent(uuid);
    \\    dirty = true; scheduleSave();
    \\  };
    \\  var cyBtn = document.getElementById('cy-edit-btn');
    \\  if (cyBtn) cyBtn.onclick = function() { openCourtyardDialog(uuid); };
    \\}
    \\
    \\function padBoundingBox(pads) {
    \\  var minX=Infinity, minY=Infinity, maxX=-Infinity, maxY=-Infinity;
    \\  for (var i=0; i<pads.length; i++) {
    \\    var p = pads[i];
    \\    var hw = p.w/2, hh = p.h/2;
    \\    if (p.x - hw < minX) minX = p.x - hw;
    \\    if (p.y - hh < minY) minY = p.y - hh;
    \\    if (p.x + hw > maxX) maxX = p.x + hw;
    \\    if (p.y + hh > maxY) maxY = p.y + hh;
    \\  }
    \\  return {x1:minX, y1:minY, x2:maxX, y2:maxY};
    \\}
    \\
    \\function openCourtyardDialog(uuid) {
    \\  var fp = fpData[uuid];
    \\  if (!fp || !fp.footprint) return;
    \\  var bbox = padBoundingBox(fp.pads);
    \\  // Compute current offsets from pad bbox
    \\  var cy = fp.courtyard || {x1: bbox.x1 - 0.25, y1: bbox.y1 - 0.25, x2: bbox.x2 + 0.25, y2: bbox.y2 + 0.25};
    \\  var offX = Math.round(Math.min(cy.x1 - bbox.x1, bbox.x2 - cy.x2) * -100) / 100;
    \\  var offY = Math.round(Math.min(cy.y1 - bbox.y1, bbox.y2 - cy.y2) * -100) / 100;
    \\  if (offX < 0) offX = 0.25;
    \\  if (offY < 0) offY = 0.25;
    \\
    \\  // Remove existing dialog if any
    \\  var old = document.getElementById('cy-dialog');
    \\  if (old) old.remove();
    \\
    \\  // Create overlay
    \\  var overlay = document.createElement('div');
    \\  overlay.id = 'cy-dialog';
    \\  overlay.style.cssText = 'position:fixed;top:0;left:0;width:100%;height:100%;background:rgba(0,0,0,0.6);z-index:200;display:flex;align-items:center;justify-content:center';
    \\
    \\  var dialog = document.createElement('div');
    \\  dialog.style.cssText = 'background:#161b22;border:1px solid #30363d;border-radius:8px;padding:20px;width:420px;color:#c9d1d9;font-family:system-ui,sans-serif';
    \\
    \\  var ist = 'style="width:70px;background:#0d1117;border:1px solid #30363d;color:#c9d1d9;padding:4px 6px;border-radius:4px;font-size:13px;font-family:monospace"';
    \\  var bst = 'style="background:#21262d;color:#c9d1d9;border:1px solid #30363d;border-radius:4px;padding:6px 14px;cursor:pointer;font-size:12px"';
    \\
    \\  dialog.innerHTML = '<h3 style="margin:0 0 4px;color:#fff;font-size:15px">Edit Courtyard</h3>'
    \\    + '<div style="color:#8b949e;font-size:12px;margin-bottom:12px">' + fp.footprint + ' — ' + fp.ref + '</div>'
    \\    + '<canvas id="cy-preview" width="300" height="200" style="background:#0d1117;border:1px solid #30363d;border-radius:4px;display:block;margin:0 auto 12px"></canvas>'
    \\    + '<div style="display:flex;gap:16px;justify-content:center;margin-bottom:12px">'
    \\    + '<div style="display:flex;align-items:center;gap:6px"><b style="font-size:12px">X offset:</b><input id="cy-off-x" type="number" step="0.05" value="'+offX.toFixed(2)+'" '+ist+'><span style="color:#666;font-size:11px">mm</span></div>'
    \\    + '<div style="display:flex;align-items:center;gap:6px"><b style="font-size:12px">Y offset:</b><input id="cy-off-y" type="number" step="0.05" value="'+offY.toFixed(2)+'" '+ist+'><span style="color:#666;font-size:11px">mm</span></div>'
    \\    + '</div>'
    \\    + '<div style="display:flex;gap:8px;justify-content:flex-end">'
    \\    + '<button id="cy-cancel" '+bst+'>Cancel</button>'
    \\    + '<button id="cy-save" style="background:#238636;color:#fff;border:1px solid #2ea043;border-radius:4px;padding:6px 14px;cursor:pointer;font-size:12px">Save</button>'
    \\    + '</div>';
    \\
    \\  overlay.appendChild(dialog);
    \\  document.body.appendChild(overlay);
    \\
    \\  function drawPreview() {
    \\    var ox = parseFloat(document.getElementById('cy-off-x').value) || 0.25;
    \\    var oy = parseFloat(document.getElementById('cy-off-y').value) || 0.25;
    \\    var newCy = {x1: bbox.x1 - ox, y1: bbox.y1 - oy, x2: bbox.x2 + ox, y2: bbox.y2 + oy};
    \\    var canvas = document.getElementById('cy-preview');
    \\    var ctx = canvas.getContext('2d');
    \\    var cw = canvas.width, ch = canvas.height;
    \\    ctx.clearRect(0,0,cw,ch);
    \\    // Compute scale to fit
    \\    var totalW = newCy.x2 - newCy.x1 + 1;
    \\    var totalH = newCy.y2 - newCy.y1 + 1;
    \\    var scale = Math.min((cw - 40) / totalW, (ch - 40) / totalH);
    \\    var cenX = cw/2, cenY = ch/2;
    \\    var offCx = (newCy.x1 + newCy.x2) / 2;
    \\    var offCy = (newCy.y1 + newCy.y2) / 2;
    \\    function tx(x) { return cenX + (x - offCx) * scale; }
    \\    function ty(y) { return cenY + (y - offCy) * scale; }
    \\    // Draw courtyard
    \\    ctx.strokeStyle = '#FF00FF';
    \\    ctx.lineWidth = 1.5;
    \\    ctx.setLineDash([4,3]);
    \\    ctx.strokeRect(tx(newCy.x1), ty(newCy.y1), (newCy.x2-newCy.x1)*scale, (newCy.y2-newCy.y1)*scale);
    \\    ctx.setLineDash([]);
    \\    // Draw pads
    \\    for (var i=0; i<fp.pads.length; i++) {
    \\      var p = fp.pads[i];
    \\      ctx.fillStyle = '#CC3333';
    \\      ctx.fillRect(tx(p.x - p.w/2), ty(p.y - p.h/2), p.w*scale, p.h*scale);
    \\      // Pad label
    \\      ctx.fillStyle = '#fff';
    \\      ctx.font = Math.max(8, Math.min(11, scale*0.15))+'px monospace';
    \\      ctx.textAlign = 'center';
    \\      ctx.textBaseline = 'middle';
    \\      ctx.fillText(p.name, tx(p.x), ty(p.y));
    \\    }
    \\    // Draw silkscreen if available
    \\    if (fp.silk_lines) {
    \\      ctx.strokeStyle = '#C8C8C8';
    \\      ctx.lineWidth = 1;
    \\      for (var si=0; si<fp.silk_lines.length; si++) {
    \\        var sl = fp.silk_lines[si];
    \\        ctx.beginPath();
    \\        ctx.moveTo(tx(sl[0]), ty(sl[1]));
    \\        ctx.lineTo(tx(sl[2]), ty(sl[3]));
    \\        ctx.stroke();
    \\      }
    \\    }
    \\    // Dimension labels
    \\    ctx.fillStyle = '#8b949e';
    \\    ctx.font = '10px system-ui';
    \\    ctx.textAlign = 'center';
    \\    ctx.fillText((newCy.x2 - newCy.x1).toFixed(2) + 'mm', cenX, ty(newCy.y2) + 14);
    \\    ctx.save();
    \\    ctx.translate(tx(newCy.x1) - 14, cenY);
    \\    ctx.rotate(-Math.PI/2);
    \\    ctx.fillText((newCy.y2 - newCy.y1).toFixed(2) + 'mm', 0, 0);
    \\    ctx.restore();
    \\  }
    \\  drawPreview();
    \\
    \\  document.getElementById('cy-off-x').addEventListener('input', drawPreview);
    \\  document.getElementById('cy-off-y').addEventListener('input', drawPreview);
    \\
    \\  document.getElementById('cy-cancel').onclick = function() { overlay.remove(); };
    \\  overlay.onclick = function(e) { if (e.target === overlay) overlay.remove(); };
    \\
    \\  document.getElementById('cy-save').onclick = function() {
    \\    var ox2 = parseFloat(document.getElementById('cy-off-x').value) || 0.25;
    \\    var oy2 = parseFloat(document.getElementById('cy-off-y').value) || 0.25;
    \\    var newCy = {x1: bbox.x1 - ox2, y1: bbox.y1 - oy2, x2: bbox.x2 + ox2, y2: bbox.y2 + oy2};
    \\    fetch('/api/edit-courtyard', {method:'POST', headers:{'Content-Type':'application/json'},
    \\      body: JSON.stringify({footprint:fp.footprint, x1:newCy.x1, y1:newCy.y1, x2:newCy.x2, y2:newCy.y2})
    \\    }).then(function(r){return r.json();}).then(function(d){
    \\      if (d.ok) {
    \\        for (var u in fpData) { if (fpData[u].footprint === fp.footprint) fpData[u].courtyard = {x1:newCy.x1,y1:newCy.y1,x2:newCy.x2,y2:newCy.y2}; }
    \\        skipFitView = true;
    \\        buildScene(); selectComponent(uuid);
    \\      }
    \\      overlay.remove();
    \\    });
    \\  };
    \\}
    \\
    \\function showNetSidebar(netName) {
    \\  var html = '<h3 style="color:#e8c547;margin:0 0 8px">' + netName + '</h3>';
    \\  var pins = [];
    \\  for (var uuid in fpData) {
    \\    var fp = fpData[uuid];
    \\    for (var i=0; i<fp.pads.length; i++) {
    \\      if (baseNetName(fp.pads[i].net_name) === netName) pins.push({ref:fp.ref, pin:fp.pads[i].name, uuid:uuid});
    \\    }
    \\  }
    \\  html += '<div style="margin-bottom:8px"><b>Connections:</b> ' + pins.length + '</div>';
    \\  html += '<table style="width:100%;font-size:12px;border-collapse:collapse">';
    \\  for (var i=0; i<pins.length; i++) {
    \\    html += '<tr style="border-bottom:1px solid #21262d"><td style="padding:4px;color:#4a9eff;cursor:pointer" onclick="window._pcbSelect(\''+pins[i].uuid+'\')">' + pins[i].ref + '</td>';
    \\    html += '<td style="padding:4px;color:#666">pad ' + pins[i].pin + '</td></tr>';
    \\  }
    \\  html += '</table>';
    \\  sidebar.innerHTML = html;
    \\}
    \\
    \\// --- Section Group Selection ---
    \\var selectedSection = null;
    \\var sectionUuids = []; // uuids in selected section
    \\var sectionTraceIds = {};  // id→true for traces that belong to section
    \\var sectionViaIds = {};    // id→true for vias that belong to section
    \\
    \\function collectSectionRouting() {
    \\  sectionTraceIds = {};
    \\  sectionViaIds = {};
    \\  if (selectedSection === null || !sectionUuids.length) return;
    \\  // Collect all nets used by pads in this section
    \\  var sectionNets = {};
    \\  for (var si=0; si<sectionUuids.length; si++) {
    \\    var fp = fpData[sectionUuids[si]];
    \\    if (!fp) continue;
    \\    for (var pi=0; pi<fp.pads.length; pi++) {
    \\      var nn = fp.pads[pi].net_name;
    \\      if (nn) sectionNets[baseNetName(nn)] = true;
    \\    }
    \\  }
    \\  if (!data.traces) data.traces = [];
    \\  // For each trace on a section net, split into section/external parts
    \\  var newTraces = [];
    \\  for (var ti = data.traces.length - 1; ti >= 0; ti--) {
    \\    var t = data.traces[ti];
    \\    if (!sectionNets[baseNetName(t.net)]) continue;
    \\    // Mark each point
    \\    var mask = [];
    \\    var anyIn = false, allIn = true;
    \\    for (var pi=0; pi<t.points.length; pi++) {
    \\      var near = isPointNearSectionPad(t.points[pi][0], t.points[pi][1]);
    \\      mask.push(near);
    \\      if (near) anyIn = true; else allIn = false;
    \\    }
    \\    if (!anyIn) continue;
    \\    if (allIn) {
    \\      // Whole trace is in section, will be tracked below
    \\      continue;
    \\    }
    \\    // Split: find contiguous runs of in/out points, create separate traces
    \\    var runs = []; // [{start, end, inSection}]
    \\    var runStart = 0;
    \\    for (var pi=1; pi<=mask.length; pi++) {
    \\      if (pi === mask.length || mask[pi] !== mask[runStart]) {
    \\        runs.push({start: runStart, end: pi-1, inSection: mask[runStart]});
    \\        runStart = pi;
    \\      }
    \\    }
    \\    // Need at least 2 points per trace segment. Extend runs to overlap by 1 point at boundaries.
    \\    var splitTraces = [];
    \\    for (var ri=0; ri<runs.length; ri++) {
    \\      var r = runs[ri];
    \\      var s = r.start, e = r.end;
    \\      // Include one point from adjacent run for connectivity
    \\      if (s > 0) s = s; // keep as-is, overlap handled below
    \\      var pts = [];
    \\      // Add overlap point from previous run (shared boundary point)
    \\      if (r.start > 0) pts.push(t.points[r.start - 1].slice ? t.points[r.start-1].slice() : [t.points[r.start-1][0], t.points[r.start-1][1]]);
    \\      for (var pi=r.start; pi<=r.end; pi++) pts.push([t.points[pi][0], t.points[pi][1]]);
    \\      // Add overlap point from next run
    \\      if (r.end < t.points.length - 1) pts.push([t.points[r.end+1][0], t.points[r.end+1][1]]);
    \\      if (pts.length >= 2) {
    \\        splitTraces.push({net: t.net, layer: t.layer, width: t.width, points: pts, _inSection: r.inSection});
    \\      }
    \\    }
    \\    // Replace original trace with split traces
    \\    data.traces.splice(ti, 1);
    \\    for (var si2=0; si2<splitTraces.length; si2++) {
    \\      var st = splitTraces[si2];
    \\      var newId = uid();
    \\      data.traces.push({id: newId, net: st.net, layer: st.layer, width: st.width, points: st.points});
    \\      if (st._inSection) sectionTraceIds[newId] = true;
    \\    }
    \\  }
    \\  // Now find all traces fully in section
    \\  ensureRouteIds();
    \\  for (var ti=0; ti<data.traces.length; ti++) {
    \\    var t = data.traces[ti];
    \\    if (sectionTraceIds[t.id]) continue; // already marked from split
    \\    if (!sectionNets[baseNetName(t.net)]) continue;
    \\    var allIn2 = true;
    \\    for (var pi=0; pi<t.points.length; pi++) {
    \\      if (!isPointNearSectionPad(t.points[pi][0], t.points[pi][1])) { allIn2 = false; break; }
    \\    }
    \\    if (allIn2) sectionTraceIds[t.id] = true;
    \\  }
    \\  // Find vias on section nets near section pads or section trace points
    \\  if (data.vias) {
    \\    ensureRouteIds();
    \\    for (var vi=0; vi<data.vias.length; vi++) {
    \\      var v = data.vias[vi];
    \\      if (!sectionNets[baseNetName(v.net)]) continue;
    \\      if (isPointNearSectionPad(v.x, v.y)) { sectionViaIds[v.id] = true; continue; }
    \\      // Check near section traces
    \\      for (var ti=0; ti<data.traces.length; ti++) {
    \\        if (!sectionTraceIds[data.traces[ti].id]) continue;
    \\        var st = data.traces[ti];
    \\        var found = false;
    \\        for (var pi=0; pi<st.points.length; pi++) {
    \\          var ddx = v.x-st.points[pi][0], ddy = v.y-st.points[pi][1];
    \\          if (ddx*ddx+ddy*ddy < 1.0) { found = true; break; }
    \\        }
    \\        if (found) { sectionViaIds[v.id] = true; break; }
    \\      }
    \\    }
    \\  }
    \\  // Rebuild scene to show split traces
    \\  skipFitView = true;
    \\  buildScene();
    \\}
    \\
    \\function isPointNearSectionPad(px, py) {
    \\  var tol = 1.5; // mm
    \\  for (var si=0; si<sectionUuids.length; si++) {
    \\    var fp = fpData[sectionUuids[si]];
    \\    var fc = fpContainers[sectionUuids[si]];
    \\    if (!fp || !fc) continue;
    \\    var a = (fp.angle||0)*Math.PI/180;
    \\    var cos = Math.cos(a), sin = Math.sin(a);
    \\    for (var pi=0; pi<fp.pads.length; pi++) {
    \\      var pad = fp.pads[pi];
    \\      var ppx = pad.x*cos - pad.y*sin + fc.x/SCALE;
    \\      var ppy = pad.x*sin + pad.y*cos + fc.y/SCALE;
    \\      var dx = px-ppx, dy = py-ppy;
    \\      if (dx*dx+dy*dy < tol*tol) return true;
    \\    }
    \\  }
    \\  return false;
    \\}
    \\
    \\function selectSection(idx) {
    \\  clearSelection();
    \\  if (!data || !data.sections || !data.sections[idx]) return;
    \\  var sec = data.sections[idx];
    \\  selectedSection = idx;
    \\  sectionUuids = [];
    \\  // Build ref→uuid map
    \\  var refMap = {};
    \\  for (var uuid in fpData) refMap[fpData[uuid].ref] = uuid;
    \\  for (var ri=0; ri<sec.refs.length; ri++) {
    \\    var uuid2 = refMap[sec.refs[ri]];
    \\    if (uuid2 && fpContainers[uuid2]) {
    \\      sectionUuids.push(uuid2);
    \\      fpContainers[uuid2].tint = 0x3fb950;
    \\    }
    \\  }
    \\  collectSectionRouting();
    \\  // Show section sidebar
    \\  var bst = 'style="background:#21262d;color:#c9d1d9;border:1px solid #30363d;border-radius:4px;padding:4px 10px;cursor:pointer;font-size:12px"';
    \\  var html = '<h3 style="color:#3fb950;margin:0 0 8px">' + sec.name + '</h3>';
    \\  html += '<div style="margin-bottom:4px"><b>' + sectionUuids.length + '</b> components</div>';
    \\  var stCount = Object.keys(sectionTraceIds).length, svCount = Object.keys(sectionViaIds).length;
    \\  if (stCount || svCount) {
    \\    html += '<div style="margin-bottom:8px;color:#8b949e;font-size:11px">' + stCount + ' traces, ' + svCount + ' vias will move with section</div>';
    \\  }
    \\  html += '<div style="margin-bottom:12px"><button id="reset-section" '+bst+'>Reset Layout</button></div>';
    \\  html += '<div style="color:#666;font-size:11px;margin-bottom:12px">Drag any highlighted component to move the group</div>';
    \\  for (var si=0; si<sectionUuids.length; si++) {
    \\    var fp = fpData[sectionUuids[si]];
    \\    if (!fp) continue;
    \\    html += '<div class="sec-item" style="cursor:pointer" onclick="window._pcbSelect(\''+sectionUuids[si]+'\')">';
    \\    html += '<span style="color:#4a9eff;font-weight:600">' + fp.ref + '</span>';
    \\    html += ' <span style="color:#666">' + (fp.value || fp.component) + '</span></div>';
    \\  }
    \\  sidebar.innerHTML = html;
    \\  document.getElementById('reset-section').onclick = function() { resetSectionLayout(idx); };
    \\}
    \\
    \\function resetSectionLayout(idx) {
    \\  if (!data || !data.sections || !data.sections[idx]) return;
    \\  var sec = data.sections[idx];
    \\  if (!sec.box || sec.box.w === 0) return;
    \\  pushUndo();
    \\  var box = sec.box;
    \\  // Build ref→uuid map
    \\  var refMap = {};
    \\  for (var uuid in fpData) refMap[fpData[uuid].ref] = uuid;
    \\  // Collect components with courtyard sizes, hubs first
    \\  var items = [];
    \\  for (var ri=0; ri<sec.refs.length; ri++) {
    \\    var uuid = refMap[sec.refs[ri]];
    \\    if (!uuid) continue;
    \\    var fp = fpData[uuid];
    \\    if (!fp) continue;
    \\    var cw = 2, ch = 2;
    \\    if (fp.courtyard) { cw = fp.courtyard.x2 - fp.courtyard.x1 + 1; ch = fp.courtyard.y2 - fp.courtyard.y1 + 1; }
    \\    var isHub = fp.pads.length > 4;
    \\    items.push({uuid:uuid, cw:cw, ch:ch, isHub:isHub});
    \\  }
    \\  // Sort: hubs first (by pad count desc), then passives
    \\  items.sort(function(a,b) { return (b.isHub?1:0) - (a.isHub?1:0) || b.cw*b.ch - a.cw*a.ch; });
    \\  // Row-pack into the box
    \\  var cx = box.x + 2, cy = box.y + 2, rowH = 0;
    \\  for (var i=0; i<items.length; i++) {
    \\    var it = items[i];
    \\    if (cx + it.cw > box.x + box.w) { cx = box.x + 2; cy += rowH + 1; rowH = 0; }
    \\    var px = cx + it.cw/2, py = cy + it.ch/2;
    \\    var fp2 = fpData[it.uuid];
    \\    if (fp2) { fp2.x = px; fp2.y = py; fp2.angle = 0; }
    \\    var fc = fpContainers[it.uuid];
    \\    if (fc) { fc.x = px*SCALE; fc.y = py*SCALE; fc.angle = 0; }
    \\    cx += it.cw;
    \\    if (it.ch > rowH) rowH = it.ch;
    \\  }
    \\  skipFitView = true;
    \\  buildScene();
    \\  selectSection(idx);
    \\  dirty = true; scheduleSave();
    \\}
    \\
    \\// Global hooks for sidebar onclick
    \\window._pcbSelect = function(uuid) { selectComponent(uuid); };
    \\window._pcbHighlightNet = function(net) { highlightNet(net); };
    \\window._pcbSelectSection = function(idx) { selectSection(idx); };
    \\
    \\// --- Tooltip ---
    \\var tooltip = document.getElementById('tooltip');
    \\function showTooltip(text) {
    \\  if (!tooltip) return;
    \\  tooltip.textContent = text;
    \\  tooltip.style.display = 'block';
    \\}
    \\function hideTooltip() {
    \\  if (tooltip) tooltip.style.display = 'none';
    \\}
    \\container.addEventListener('pointermove', function(e) {
    \\  if (tooltip && tooltip.style.display === 'block') {
    \\    tooltip.style.left = (e.clientX + 12) + 'px';
    \\    tooltip.style.top = (e.clientY + 12) + 'px';
    \\  }
    \\});
    \\
    \\// --- Pan/Zoom ---
    \\var isPanning = false, panStart = {x:0,y:0}, worldStart = {x:0,y:0}, didPan = false;
    \\
    \\app.canvas.addEventListener('mousedown', function(e) {
    \\  if (e.button === 1 || (e.button === 0 && e.altKey)) {
    \\    isPanning = true; didPan = false;
    \\    panStart = {x:e.clientX, y:e.clientY};
    \\    worldStart = {x:world.x, y:world.y};
    \\    e.preventDefault();
    \\  }
    \\});
    \\window.addEventListener('mousemove', function(e) {
    \\  if (!isPanning) return;
    \\  var dx = e.clientX - panStart.x, dy = e.clientY - panStart.y;
    \\  if (Math.abs(dx)>3||Math.abs(dy)>3) didPan = true;
    \\  world.x = worldStart.x + dx;
    \\  world.y = worldStart.y + dy;
    \\});
    \\window.addEventListener('mouseup', function() { isPanning = false; });
    \\
    \\function clampZoom(mx, my, factor) {
    \\  var wx = (mx - world.x) / world.scale.x;
    \\  var wy = (my - world.y) / world.scale.y;
    \\  var ns = Math.max(0.1, Math.min(50, world.scale.x * factor));
    \\  world.scale.set(ns);
    \\  world.x = mx - wx * ns;
    \\  world.y = my - wy * ns;
    \\}
    \\
    \\app.canvas.addEventListener('wheel', function(e) {
    \\  e.preventDefault();
    \\  var rect = app.canvas.getBoundingClientRect();
    \\  var mx = e.clientX - rect.left, my = e.clientY - rect.top;
    \\  if (e.ctrlKey) {
    \\    clampZoom(mx, my, e.deltaY < 0 ? 1.04 : 1/1.04);
    \\  } else {
    \\    if (e.deltaMode === 0 && Math.abs(e.deltaX)+Math.abs(e.deltaY) < 100) {
    \\      world.x -= e.deltaX; world.y -= e.deltaY;
    \\    } else {
    \\      clampZoom(mx, my, e.deltaY < 0 ? 1.1 : 1/1.1);
    \\    }
    \\  }
    \\}, {passive:false});
    \\
    \\function fitView() {
    \\  if (!data || !data.footprints.length) return;
    \\  var minX=Infinity,minY=Infinity,maxX=-Infinity,maxY=-Infinity;
    \\  // Include board outline
    \\  if (data.board && data.board.outline) {
    \\    for (var oi=0; oi<data.board.outline.length; oi++) {
    \\      var pt = data.board.outline[oi];
    \\      if (pt[0] < minX) minX = pt[0];
    \\      if (pt[1] < minY) minY = pt[1];
    \\      if (pt[0] > maxX) maxX = pt[0];
    \\      if (pt[1] > maxY) maxY = pt[1];
    \\    }
    \\  }
    \\  for (var i=0; i<data.footprints.length; i++) {
    \\    var fp = data.footprints[i];
    \\    var s = 5;
    \\    if (fp.courtyard) s = Math.max(fp.courtyard.x2 - fp.courtyard.x1, fp.courtyard.y2 - fp.courtyard.y1);
    \\    if (fp.x-s < minX) minX = fp.x-s;
    \\    if (fp.y-s < minY) minY = fp.y-s;
    \\    if (fp.x+s > maxX) maxX = fp.x+s;
    \\    if (fp.y+s > maxY) maxY = fp.y+s;
    \\  }
    \\  var cw = container.clientWidth, ch = container.clientHeight;
    \\  var w2 = (maxX-minX)*SCALE, h2 = (maxY-minY)*SCALE;
    \\  var scale = Math.min(cw/(w2+40), ch/(h2+40)) * 0.9;
    \\  world.scale.set(scale);
    \\  world.x = (cw - w2*scale)/2 - minX*SCALE*scale;
    \\  world.y = (ch - h2*scale)/2 - minY*SCALE*scale;
    \\}
    \\
    \\// --- Layer Toggles ---
    \\document.querySelectorAll('.layer-toggle').forEach(function(btn) {
    \\  btn.addEventListener('click', function() {
    \\    var layer = this.dataset.layer;
    \\    layerVisibility[layer] = !layerVisibility[layer];
    \\    this.classList.toggle('off', !layerVisibility[layer]);
    \\    if (layerContainers[layer]) layerContainers[layer].visible = layerVisibility[layer];
    \\  });
    \\});
    \\
    \\// --- Save Placements ---
    \\var saveTimer = null;
    \\function scheduleSave() {
    \\  if (saveTimer) clearTimeout(saveTimer);
    \\  saveTimer = setTimeout(doSave, 500);
    \\}
    \\function doSave() {
    \\  if (!dirty || !data) return;
    \\  var placements = [];
    \\  for (var uuid in fpContainers) {
    \\    var fc = fpContainers[uuid];
    \\    var fpd = fpData[uuid];
    \\    placements.push({
    \\      uuid: uuid,
    \\      ref: fpd ? fpd.ref : '',
    \\      x: fc.x / SCALE,
    \\      y: fc.y / SCALE,
    \\      angle: fc.angle || 0,
    \\      layer: fpd ? fpd.layer : 'F.Cu'
    \\    });
    \\  }
    \\  fetch('/api/pcb-placement/' + DESIGN_NAME, {
    \\    method: 'POST',
    \\    headers: {'Content-Type':'application/json'},
    \\    body: JSON.stringify({placements: placements})
    \\  });
    \\  // Save routing data separately
    \\  if (data.traces || data.vias) {
    \\    fetch('/api/pcb-routing/' + DESIGN_NAME, {
    \\      method: 'POST',
    \\      headers: {'Content-Type':'application/json'},
    \\      body: JSON.stringify({traces: data.traces || [], vias: data.vias || [], zone_fills: data.zone_fills || []})
    \\    });
    \\  }
    \\  dirty = false;
    \\}
    \\
    \\// --- Reset View Button ---
    \\var resetBtn = document.getElementById('pcb-reset');
    \\if (resetBtn) resetBtn.onclick = function() { fitView(); };
    \\
    \\// --- Zone Fill Button ---
    \\var zoneFillBtn = document.getElementById('zone-fill-btn');
    \\if (zoneFillBtn) zoneFillBtn.onclick = function() {
    \\  zoneFillBtn.textContent = 'Filling...';
    \\  fetch('/api/zone-fill/' + DESIGN_NAME, {method:'POST'}).then(function(r){return r.json();}).then(function(d) {
    \\    if (d.zone_fills) {
    \\      data.zone_fills = d.zone_fills;
    \\      skipFitView = true;
    \\      buildScene();
    \\    }
    \\    zoneFillBtn.textContent = 'Fill Zones';
    \\  }).catch(function() { zoneFillBtn.textContent = 'Fill Zones'; });
    \\};
    \\
    \\// --- DRC Button ---
    \\var drcBtn = document.getElementById('drc-btn');
    \\var drcMarkers = [];
    \\if (drcBtn) drcBtn.onclick = function() {
    \\  drcBtn.textContent = 'Checking...';
    \\  // Clear old markers
    \\  for (var di=0; di<drcMarkers.length; di++) { if (drcMarkers[di].parent) drcMarkers[di].destroy(); }
    \\  drcMarkers = [];
    \\  fetch('/api/drc/' + DESIGN_NAME).then(function(r){return r.json();}).then(function(d) {
    \\    drcBtn.textContent = 'Run DRC (' + d.count + ')';
    \\    if (!d.violations || d.violations.length === 0) {
    \\      sidebar.innerHTML = '<h3 style="color:#3fb950;margin:0 0 12px">DRC: No violations</h3>';
    \\      return;
    \\    }
    \\    // Draw markers
    \\    for (var vi=0; vi<d.violations.length; vi++) {
    \\      var v = d.violations[vi];
    \\      var mg = new PIXI.Graphics();
    \\      mg.circle(v.x*SCALE, v.y*SCALE, 1.0*SCALE);
    \\      mg.stroke({color: v.severity==='error' ? 0xFF0000 : 0xFFAA00, width: 0.2*SCALE, alpha: 0.8});
    \\      mg.moveTo((v.x-0.7)*SCALE, (v.y-0.7)*SCALE); mg.lineTo((v.x+0.7)*SCALE, (v.y+0.7)*SCALE);
    \\      mg.moveTo((v.x+0.7)*SCALE, (v.y-0.7)*SCALE); mg.lineTo((v.x-0.7)*SCALE, (v.y+0.7)*SCALE);
    \\      mg.stroke({color: v.severity==='error' ? 0xFF0000 : 0xFFAA00, width: 0.15*SCALE, alpha: 0.8});
    \\      world.addChild(mg);
    \\      drcMarkers.push(mg);
    \\    }
    \\    // Show in sidebar
    \\    var html = '<h3 style="color:#da3633;margin:0 0 12px">DRC: ' + d.count + ' violations</h3>';
    \\    for (var vi2=0; vi2<d.violations.length; vi2++) {
    \\      var vv = d.violations[vi2];
    \\      var col = vv.severity === 'error' ? '#da3633' : '#d29922';
    \\      html += '<div class="sec-item" style="cursor:pointer;font-size:11px" onclick="window._pcbPanTo('+vv.x+','+vv.y+')">';
    \\      html += '<span style="color:'+col+';font-weight:600">' + vv.kind + '</span> ';
    \\      html += '<span style="color:#8b949e">' + vv.message + '</span></div>';
    \\    }
    \\    html += '<button id="drc-clear" style="margin-top:8px;background:#21262d;color:#c9d1d9;border:1px solid #30363d;border-radius:4px;padding:4px 10px;cursor:pointer;font-size:12px">Clear Markers</button>';
    \\    sidebar.innerHTML = html;
    \\    document.getElementById('drc-clear').onclick = function() {
    \\      for (var ci=0; ci<drcMarkers.length; ci++) { if (drcMarkers[ci].parent) drcMarkers[ci].destroy(); }
    \\      drcMarkers = [];
    \\      drcBtn.textContent = 'Run DRC';
    \\      showDefaultSidebar();
    \\    };
    \\  }).catch(function() { drcBtn.textContent = 'Run DRC'; });
    \\};
    \\window._pcbPanTo = function(x, y) {
    \\  world.x = app.screen.width/2 - x*SCALE*world.scale.x;
    \\  world.y = app.screen.height/2 - y*SCALE*world.scale.y;
    \\};
    \\
    \\// --- Grid Snap Toggle ---
    \\var gridBtn = document.getElementById('grid-snap');
    \\function updateGridBtn() {
    \\  if (gridBtn) gridBtn.textContent = 'Grid: ' + gridSnap + 'mm';
    \\}
    \\updateGridBtn();
    \\if (gridBtn) gridBtn.onclick = function() {
    \\  var idx = GRID_OPTIONS.indexOf(gridSnap);
    \\  gridSnap = GRID_OPTIONS[(idx + 1) % GRID_OPTIONS.length];
    \\  updateGridBtn();
    \\};
    \\
    \\// --- Routing ---
    \\var routingNet = null;
    \\var routingLayer = 'F.Cu';
    \\var routingPoints = []; // [x,y] in mm
    \\var routingWidth = 0.2;
    \\var routingGraphics = null;
    \\var routingStartPad = null; // {ref, pin, uuid}
    \\var routingBendHV = true; // true=horizontal-first, false=vertical-first
    \\var routingCursorMm = [0, 0]; // current cursor position in mm (for via placement)
    \\var viaPreviewMode = false; // true when V pressed, waiting for click to place
    \\var viaPreviewGfx = null;
    \\
    \\function getTraceWidth(netName) {
    \\  var base = baseNetName(netName);
    \\  if (data.net_classes) {
    \\    for (var i=0; i<data.net_classes.length; i++) {
    \\      var nc = data.net_classes[i];
    \\      if (nc.nets && nc.nets.indexOf(base) >= 0) return nc.track_width || (data.rules ? data.rules.track_width : 0.2);
    \\    }
    \\  }
    \\  return data.rules ? data.rules.track_width : 0.2;
    \\}
    \\
    \\function getViaSize() {
    \\  return data.rules ? {drill: data.rules.via_drill, pad_size: data.rules.via_size} : {drill: 0.3, pad_size: 0.6};
    \\}
    \\
    \\// Returns [midpoint, endpoint] for a two-segment route where each segment
    \\// is exactly horizontal, vertical, or 45 degrees.
    \\// routingBendHV: true = straight first then 45, false = 45 first then straight
    \\function constrainRoute(from, to) {
    \\  var dx = to[0]-from[0], dy = to[1]-from[1];
    \\  var adx = Math.abs(dx), ady = Math.abs(dy);
    \\  if (adx < 0.001 && ady < 0.001) return [];
    \\  // Pure horizontal, vertical, or exact 45 — single segment
    \\  if (ady < 0.001) return [[to[0], from[1]]];
    \\  if (adx < 0.001) return [[from[0], to[1]]];
    \\  if (Math.abs(adx - ady) < 0.001) return [[to[0], to[1]]];
    \\  if (routingBendHV) {
    \\    // Straight (H or V) first, then 45 to target
    \\    if (adx > ady) {
    \\      // Horizontal first, then 45 diagonal to reach target
    \\      var diag = ady; // diagonal covers the shorter axis
    \\      var mx = to[0] - diag * Math.sign(dx);
    \\      return [[mx, from[1]], [to[0], to[1]]];
    \\    } else {
    \\      // Vertical first, then 45 diagonal
    \\      var diag2 = adx;
    \\      var my = to[1] - diag2 * Math.sign(dy);
    \\      return [[from[0], my], [to[0], to[1]]];
    \\    }
    \\  } else {
    \\    // 45 diagonal first, then straight to target
    \\    if (adx > ady) {
    \\      // 45 diagonal first, then horizontal
    \\      var diag3 = ady;
    \\      var mx2 = from[0] + diag3 * Math.sign(dx);
    \\      return [[mx2, to[1]], [to[0], to[1]]];
    \\    } else {
    \\      // 45 diagonal first, then vertical
    \\      var diag4 = adx;
    \\      var my2 = from[1] + diag4 * Math.sign(dy);
    \\      return [[to[0], my2], [to[0], to[1]]];
    \\    }
    \\  }
    \\}
    \\
    \\function routingPreviewPoints(mx, my) {
    \\  if (routingPoints.length === 0) return [];
    \\  var last = routingPoints[routingPoints.length - 1];
    \\  // Nudge target to satisfy clearance, then constrain
    \\  var nudged = nudgeForClearance(last, [mx, my], routingWidth, routingLayer, baseNetName(routingNet));
    \\  var segs = constrainRoute(last, nudged);
    \\  var pts = routingPoints.slice();
    \\  for (var si=0; si<segs.length; si++) pts.push(segs[si]);
    \\  return pts;
    \\}
    \\
    \\// --- DRC: clearance checking ---
    \\function getDrcClearance() {
    \\  return data.rules ? data.rules.clearance : 0.15;
    \\}
    \\
    \\function distPtSeg(px, py, x1, y1, x2, y2) {
    \\  var dx = x2-x1, dy = y2-y1;
    \\  var len2 = dx*dx + dy*dy;
    \\  if (len2 < 0.0001) { var ddx=px-x1, ddy=py-y1; return Math.sqrt(ddx*ddx+ddy*ddy); }
    \\  var t = ((px-x1)*dx + (py-y1)*dy) / len2;
    \\  t = Math.max(0, Math.min(1, t));
    \\  var cx = x1+t*dx, cy = y1+t*dy;
    \\  var ex = px-cx, ey = py-cy;
    \\  return Math.sqrt(ex*ex+ey*ey);
    \\}
    \\
    \\function distSegSeg(ax1,ay1,ax2,ay2, bx1,by1,bx2,by2) {
    \\  // Approximate: sample endpoints + closest approach
    \\  var d = Math.min(
    \\    distPtSeg(ax1,ay1,bx1,by1,bx2,by2), distPtSeg(ax2,ay2,bx1,by1,bx2,by2),
    \\    distPtSeg(bx1,by1,ax1,ay1,ax2,ay2), distPtSeg(bx2,by2,ax1,ay1,ax2,ay2)
    \\  );
    \\  return d;
    \\}
    \\
    \\// Collect obstacles: returns [{x, y, radius}] for pads/vias on different nets, same layer
    \\function collectObstacles(layer, netName) {
    \\  var obs = [];
    \\  // Pads — only on same layer (or through-hole pads which are on all layers)
    \\  for (var uuid in fpData) {
    \\    var fpd = fpData[uuid];
    \\    var fpc = fpContainers[uuid];
    \\    if (!fpd || !fpc) continue;
    \\    // Check if footprint is on the same layer
    \\    var fpLayer = fpd.layer || 'F.Cu';
    \\    var fpAngle = (fpd.angle||0) * Math.PI/180;
    \\    var cos = Math.cos(fpAngle), sin = Math.sin(fpAngle);
    \\    for (var pi=0; pi<fpd.pads.length; pi++) {
    \\      var pad = fpd.pads[pi];
    \\      if (pad.net_name && baseNetName(pad.net_name) === netName) continue;
    \\      // SMD pads only on their footprint's layer; through-hole on all layers
    \\      var isThrough = pad.type === 'thru_hole' || pad.drill;
    \\      if (!isThrough && fpLayer !== layer) continue;
    \\      var ppx = pad.x*cos - pad.y*sin + fpc.x/SCALE;
    \\      var ppy = pad.x*sin + pad.y*cos + fpc.y/SCALE;
    \\      obs.push({x: ppx, y: ppy, r: Math.max(pad.w, pad.h)/2});
    \\    }
    \\  }
    \\  // Vias on different nets — vias span all layers so always relevant
    \\  if (data.vias) {
    \\    for (var vi=0; vi<data.vias.length; vi++) {
    \\      var v = data.vias[vi];
    \\      if (baseNetName(v.net) === netName) continue;
    \\      obs.push({x: v.x, y: v.y, r: v.pad_size/2});
    \\    }
    \\  }
    \\  return obs;
    \\}
    \\
    \\// Nudge a target point so the route from 'from' to 'to' maintains clearance.
    \\// Iteratively pushes 'to' away from the closest obstacle.
    \\function nudgeForClearance(from, to, width, layer, netName) {
    \\  var clearance = getDrcClearance();
    \\  var halfW = width / 2;
    \\  var obs = collectObstacles(layer, netName);
    \\  // Also collect trace segments as obstacles
    \\  var traceSegs = [];
    \\  if (data.traces) {
    \\    for (var ti=0; ti<data.traces.length; ti++) {
    \\      var ot = data.traces[ti];
    \\      if (ot.layer !== layer || baseNetName(ot.net) === netName) continue;
    \\      for (var si=0; si<ot.points.length-1; si++) {
    \\        traceSegs.push({x1:ot.points[si][0], y1:ot.points[si][1], x2:ot.points[si+1][0], y2:ot.points[si+1][1], hw:ot.width/2});
    \\      }
    \\    }
    \\  }
    \\  var tx = to[0], ty = to[1];
    \\  // Up to 5 nudge iterations
    \\  for (var iter=0; iter<5; iter++) {
    \\    var segs = constrainRoute(from, [tx, ty]);
    \\    var testPts = [from];
    \\    for (var si=0; si<segs.length; si++) testPts.push(segs[si]);
    \\    var worstPush = null, worstAmount = 0;
    \\    // Check point obstacles (pads, vias)
    \\    for (var oi=0; oi<obs.length; oi++) {
    \\      var o = obs[oi];
    \\      var minGap = clearance + halfW + o.r;
    \\      for (var si=0; si<testPts.length-1; si++) {
    \\        var d = distPtSeg(o.x, o.y, testPts[si][0], testPts[si][1], testPts[si+1][0], testPts[si+1][1]);
    \\        if (d < minGap && (minGap - d) > worstAmount) {
    \\          worstAmount = minGap - d;
    \\          // Push direction: from obstacle toward the target point
    \\          var pdx = tx - o.x, pdy = ty - o.y;
    \\          var plen = Math.sqrt(pdx*pdx + pdy*pdy);
    \\          if (plen < 0.001) { pdx = 1; pdy = 0; plen = 1; }
    \\          worstPush = {dx: pdx/plen, dy: pdy/plen, amount: worstAmount};
    \\        }
    \\      }
    \\    }
    \\    // Check trace segment obstacles
    \\    for (var ti=0; ti<traceSegs.length; ti++) {
    \\      var ts = traceSegs[ti];
    \\      var minGap2 = clearance + halfW + ts.hw;
    \\      for (var si=0; si<testPts.length-1; si++) {
    \\        var d2 = distSegSeg(testPts[si][0],testPts[si][1],testPts[si+1][0],testPts[si+1][1], ts.x1,ts.y1,ts.x2,ts.y2);
    \\        if (d2 < minGap2 && (minGap2 - d2) > worstAmount) {
    \\          worstAmount = minGap2 - d2;
    \\          var smx = (ts.x1+ts.x2)/2, smy = (ts.y1+ts.y2)/2;
    \\          var pdx2 = tx - smx, pdy2 = ty - smy;
    \\          var plen2 = Math.sqrt(pdx2*pdx2 + pdy2*pdy2);
    \\          if (plen2 < 0.001) { pdx2 = 1; pdy2 = 0; plen2 = 1; }
    \\          worstPush = {dx: pdx2/plen2, dy: pdy2/plen2, amount: worstAmount};
    \\        }
    \\      }
    \\    }
    \\    if (!worstPush || worstAmount < 0.01) break;
    \\    tx += worstPush.dx * (worstPush.amount + 0.01);
    \\    ty += worstPush.dy * (worstPush.amount + 0.01);
    \\    // Snap to grid after nudge
    \\    if (gridSnap > 0) { tx = Math.round(tx/gridSnap)*gridSnap; ty = Math.round(ty/gridSnap)*gridSnap; }
    \\  }
    \\  return [tx, ty];
    \\}
    \\
    \\// Check DRC for a set of trace points against existing geometry.
    \\// Returns array of {x, y, msg} violations.
    \\function checkRouteDrc(pts, width, layer, netName) {
    \\  var clearance = getDrcClearance();
    \\  var violations = [];
    \\  var halfW = width / 2;
    \\  // Check against other traces on same layer, different net
    \\  if (data.traces) {
    \\    for (var ti=0; ti<data.traces.length; ti++) {
    \\      var ot = data.traces[ti];
    \\      if (ot.layer !== layer || baseNetName(ot.net) === netName) continue;
    \\      var otHalf = ot.width / 2;
    \\      var minGap = clearance + halfW + otHalf;
    \\      for (var si=0; si<pts.length-1; si++) {
    \\        for (var sj=0; sj<ot.points.length-1; sj++) {
    \\          var d = distSegSeg(pts[si][0],pts[si][1],pts[si+1][0],pts[si+1][1],
    \\                             ot.points[sj][0],ot.points[sj][1],ot.points[sj+1][0],ot.points[sj+1][1]);
    \\          if (d < minGap) {
    \\            var mx = (pts[si][0]+pts[si+1][0])/2, my = (pts[si][1]+pts[si+1][1])/2;
    \\            violations.push({x:mx, y:my, msg:'Trace clearance: '+d.toFixed(2)+'mm < '+minGap.toFixed(2)+'mm'});
    \\          }
    \\        }
    \\      }
    \\    }
    \\  }
    \\  // Check against pads on same layer, different net
    \\  for (var uuid in fpData) {
    \\    var fpd = fpData[uuid];
    \\    var fpc = fpContainers[uuid];
    \\    if (!fpd || !fpc) continue;
    \\    var fpLayer = fpd.layer || 'F.Cu';
    \\    var fpAngle = (fpd.angle||0) * Math.PI/180;
    \\    var cos = Math.cos(fpAngle), sin = Math.sin(fpAngle);
    \\    for (var pi=0; pi<fpd.pads.length; pi++) {
    \\      var pad = fpd.pads[pi];
    \\      if (pad.net_name && baseNetName(pad.net_name) === netName) continue;
    \\      var isThrough = pad.type === 'thru_hole' || pad.drill;
    \\      if (!isThrough && fpLayer !== layer) continue;
    \\      var ppx = pad.x*cos - pad.y*sin + fpc.x/SCALE;
    \\      var ppy = pad.x*sin + pad.y*cos + fpc.y/SCALE;
    \\      var padR = Math.max(pad.w, pad.h) / 2;
    \\      var minGap2 = clearance + halfW + padR;
    \\      for (var si=0; si<pts.length-1; si++) {
    \\        var dp = distPtSeg(ppx, ppy, pts[si][0], pts[si][1], pts[si+1][0], pts[si+1][1]);
    \\        if (dp < minGap2) {
    \\          violations.push({x:ppx, y:ppy, msg:'Pad clearance: '+dp.toFixed(2)+'mm < '+minGap2.toFixed(2)+'mm'});
    \\        }
    \\      }
    \\    }
    \\  }
    \\  // Check against vias, different net
    \\  if (data.vias) {
    \\    for (var vi=0; vi<data.vias.length; vi++) {
    \\      var v = data.vias[vi];
    \\      if (baseNetName(v.net) === netName) continue;
    \\      var viaR = v.pad_size / 2;
    \\      var minGap3 = clearance + halfW + viaR;
    \\      for (var si=0; si<pts.length-1; si++) {
    \\        var dv = distPtSeg(v.x, v.y, pts[si][0], pts[si][1], pts[si+1][0], pts[si+1][1]);
    \\        if (dv < minGap3) {
    \\          violations.push({x:v.x, y:v.y, msg:'Via clearance: '+dv.toFixed(2)+'mm < '+minGap3.toFixed(2)+'mm'});
    \\        }
    \\      }
    \\    }
    \\  }
    \\  return violations;
    \\}
    \\
    \\// Check DRC for a via placement. Vias span both layers.
    \\function checkViaDrc(vx, vy, padSize, netName) {
    \\  var clearance = getDrcClearance();
    \\  var viaR = padSize / 2;
    \\  var violations = [];
    \\  var bothLayers = ['F.Cu', 'B.Cu'];
    \\  // Check against pads on both layers
    \\  for (var uuid in fpData) {
    \\    var fpd = fpData[uuid];
    \\    var fpc = fpContainers[uuid];
    \\    if (!fpd || !fpc) continue;
    \\    var fpLayer = fpd.layer || 'F.Cu';
    \\    var fpAngle = (fpd.angle||0) * Math.PI/180;
    \\    var cos = Math.cos(fpAngle), sin = Math.sin(fpAngle);
    \\    for (var pi=0; pi<fpd.pads.length; pi++) {
    \\      var pad = fpd.pads[pi];
    \\      if (pad.net_name && baseNetName(pad.net_name) === netName) continue;
    \\      var isThrough = pad.type === 'thru_hole' || pad.drill;
    \\      if (!isThrough && bothLayers.indexOf(fpLayer) < 0) continue;
    \\      var ppx = pad.x*cos - pad.y*sin + fpc.x/SCALE;
    \\      var ppy = pad.x*sin + pad.y*cos + fpc.y/SCALE;
    \\      var padR = Math.max(pad.w, pad.h) / 2;
    \\      var dx = vx-ppx, dy = vy-ppy;
    \\      var dist = Math.sqrt(dx*dx+dy*dy);
    \\      var minGap = clearance + viaR + padR;
    \\      if (dist < minGap) {
    \\        violations.push({x: ppx, y: ppy});
    \\      }
    \\    }
    \\  }
    \\  // Check against traces on both layers
    \\  if (data.traces) {
    \\    for (var ti=0; ti<data.traces.length; ti++) {
    \\      var ot = data.traces[ti];
    \\      if (baseNetName(ot.net) === netName) continue;
    \\      var otHalf = ot.width / 2;
    \\      var minGap2 = clearance + viaR + otHalf;
    \\      for (var si=0; si<ot.points.length-1; si++) {
    \\        var d = distPtSeg(vx, vy, ot.points[si][0], ot.points[si][1], ot.points[si+1][0], ot.points[si+1][1]);
    \\        if (d < minGap2) {
    \\          var mx = (ot.points[si][0]+ot.points[si+1][0])/2, my = (ot.points[si][1]+ot.points[si+1][1])/2;
    \\          violations.push({x: mx, y: my});
    \\          break;
    \\        }
    \\      }
    \\    }
    \\  }
    \\  // Check against other vias, different net
    \\  if (data.vias) {
    \\    for (var vi=0; vi<data.vias.length; vi++) {
    \\      var v = data.vias[vi];
    \\      if (baseNetName(v.net) === netName) continue;
    \\      var dx2 = vx-v.x, dy2 = vy-v.y;
    \\      var dist2 = Math.sqrt(dx2*dx2+dy2*dy2);
    \\      var minGap3 = clearance + viaR + v.pad_size/2;
    \\      if (dist2 < minGap3) {
    \\        violations.push({x: v.x, y: v.y});
    \\      }
    \\    }
    \\  }
    \\  return violations;
    \\}
    \\
    \\function drawRoutingPreview(mx, my) {
    \\  if (routingGraphics) { routingGraphics.destroy(); routingGraphics = null; }
    \\  if (routingPoints.length === 0) return;
    \\  var pts = routingPreviewPoints(mx, my);
    \\  if (pts.length < 2) return;
    \\  // DRC check
    \\  var violations = checkRouteDrc(pts, routingWidth, routingLayer, baseNetName(routingNet));
    \\  var traceColor = violations.length > 0 ? 0xFF0000 : (routingLayer==='F.Cu' ? C.fcu : C.bcu);
    \\  routingGraphics = new PIXI.Graphics();
    \\  routingGraphics.moveTo(pts[0][0]*SCALE, pts[0][1]*SCALE);
    \\  for (var i=1; i<pts.length; i++) routingGraphics.lineTo(pts[i][0]*SCALE, pts[i][1]*SCALE);
    \\  routingGraphics.stroke({color: traceColor, width: routingWidth*SCALE, alpha: 0.6, cap:'round', join:'round'});
    \\  // Show a dot at each placed waypoint
    \\  for (var wi=0; wi<routingPoints.length; wi++) {
    \\    routingGraphics.circle(routingPoints[wi][0]*SCALE, routingPoints[wi][1]*SCALE, routingWidth*SCALE*0.6);
    \\    routingGraphics.fill({color: 0xFFFFFF, alpha: 0.5});
    \\  }
    \\  // Draw DRC violation markers
    \\  for (var vi=0; vi<violations.length; vi++) {
    \\    var vx = violations[vi].x*SCALE, vy = violations[vi].y*SCALE;
    \\    routingGraphics.circle(vx, vy, getDrcClearance()*SCALE);
    \\    routingGraphics.stroke({color: 0xFF0000, width: 0.3*SCALE, alpha: 0.8});
    \\  }
    \\  var tLayer = routingLayer === 'F.Cu' ? layerContainers.traces_fcu : layerContainers.traces_bcu;
    \\  tLayer.addChild(routingGraphics);
    \\}
    \\
    \\function startRouting(padData, fpRef, fpUuid, fpLayer) {
    \\  if (!padData.net_name) return;
    \\  routingNet = padData.net_name;
    \\  routingLayer = fpLayer || 'F.Cu';
    \\  routingWidth = getTraceWidth(routingNet);
    \\  // Compute exact pad world position (no grid snap — must be centered on pad)
    \\  var fp = fpData[fpUuid];
    \\  var fc = fpContainers[fpUuid];
    \\  if (!fp || !fc) return;
    \\  var angle = (fp.angle||0) * Math.PI/180;
    \\  var px = padData.x*SCALE, py = padData.y*SCALE;
    \\  var rx = px*Math.cos(angle) - py*Math.sin(angle);
    \\  var ry = px*Math.sin(angle) + py*Math.cos(angle);
    \\  var wx = (fc.x + rx) / SCALE, wy = (fc.y + ry) / SCALE;
    \\  routingPoints = [[wx, wy]];
    \\  routingStartPad = {ref: fpRef, pin: padData.name, uuid: fpUuid};
    \\  // Highlight the net so user can see all pads to connect to
    \\  highlightNet(baseNetName(routingNet));
    \\  // Show routing status in sidebar (after highlightNet which sets net sidebar)
    \\  updateRoutingSidebar();
    \\}
    \\function updateRoutingSidebar() {
    \\  if (!routingNet) return;
    \\  sidebar.innerHTML = '<h3 style="color:#e8c547;margin:0 0 8px">Routing: ' + baseNetName(routingNet) + '</h3>'
    \\    + '<div style="color:#8b949e;font-size:12px;margin-bottom:8px">Layer: <span style="color:' + (routingLayer==='F.Cu'?'#CC3333':'#3333CC') + '">' + routingLayer + '</span></div>'
    \\    + '<div style="color:#8b949e;font-size:12px;margin-bottom:8px">Width: ' + routingWidth.toFixed(2) + 'mm</div>'
    \\    + '<div style="color:#666;font-size:11px">Click pads/waypoints to route.<br>V=via, /=toggle bend, Esc=cancel</div>';
    \\}
    \\
    \\function finishRouting(endPadData, endFpUuid) {
    \\  if (routingPoints.length < 1) return;
    \\  // Compute end pad position
    \\  var fp = fpData[endFpUuid];
    \\  var fc = fpContainers[endFpUuid];
    \\  if (!fp || !fc) return;
    \\  var angle = (fp.angle||0) * Math.PI/180;
    \\  var px = endPadData.x*SCALE, py = endPadData.y*SCALE;
    \\  var rx = px*Math.cos(angle) - py*Math.sin(angle);
    \\  var ry = px*Math.sin(angle) + py*Math.cos(angle);
    \\  var wx = (fc.x + rx) / SCALE, wy = (fc.y + ry) / SCALE;
    \\  // No grid snap on pad endpoints — must be exact pad center
    \\  // Add constrained final segments (45° only)
    \\  var last = routingPoints[routingPoints.length - 1];
    \\  var segs = constrainRoute(last, [wx, wy]);
    \\  for (var si=0; si<segs.length; si++) routingPoints.push(segs[si]);
    \\  // Ensure we end exactly at the pad
    \\  var rl = routingPoints[routingPoints.length-1];
    \\  if (!rl || Math.abs(rl[0]-wx)>0.001 || Math.abs(rl[1]-wy)>0.001) routingPoints.push([wx, wy]);
    \\  // Create trace
    \\  if (!data.traces) data.traces = [];
    \\  data.traces.push({net: baseNetName(routingNet), layer: routingLayer, width: routingWidth, points: routingPoints.slice()});
    \\  cancelRouting();
    \\  skipFitView = true;
    \\  buildScene();
    \\  dirty = true; scheduleSave();
    \\  showDefaultSidebar();
    \\}
    \\
    \\function addRoutingViaAt(mx, my) {
    \\  if (routingPoints.length === 0) return;
    \\  var last = routingPoints[routingPoints.length - 1];
    \\  var segs = constrainRoute(last, [mx, my]);
    \\  for (var si=0; si<segs.length; si++) routingPoints.push(segs[si]);
    \\  var viaPos = routingPoints[routingPoints.length - 1];
    \\  // Save the trace segment on the CURRENT layer up to the via
    \\  if (routingPoints.length >= 2) {
    \\    if (!data.traces) data.traces = [];
    \\    data.traces.push({net: baseNetName(routingNet), layer: routingLayer, width: routingWidth, points: routingPoints.slice()});
    \\  }
    \\  // Place the via
    \\  var vs = getViaSize();
    \\  if (!data.vias) data.vias = [];
    \\  var newLayer = routingLayer === 'F.Cu' ? 'B.Cu' : 'F.Cu';
    \\  data.vias.push({id: uid(), x: viaPos[0], y: viaPos[1], net: baseNetName(routingNet), drill: vs.drill, pad_size: vs.pad_size, from: routingLayer, to: newLayer});
    \\  // Start new segment on the other layer from the via position
    \\  routingLayer = newLayer;
    \\  routingPoints = [[viaPos[0], viaPos[1]]];
    \\  // Rebuild to show the via + saved trace, then re-highlight net
    \\  skipFitView = true;
    \\  buildScene();
    \\  highlightNet(baseNetName(routingNet));
    \\  updateRoutingSidebar();
    \\  dirty = true; scheduleSave();
    \\}
    \\
    \\function cancelRouting() {
    \\  routingPoints = [];
    \\  routingNet = null;
    \\  routingStartPad = null;
    \\  viaPreviewMode = false;
    \\  if (viaPreviewGfx) { viaPreviewGfx.destroy(); viaPreviewGfx = null; }
    \\  if (routingGraphics) { routingGraphics.destroy(); routingGraphics = null; }
    \\}
    \\
    \\// --- Select Mode Toggle ---
    \\var selComp = document.getElementById('sel-comp');
    \\var selNet = document.getElementById('sel-net');
    \\var selSec = document.getElementById('sel-sec');
    \\var selTrace = document.getElementById('sel-trace');
    \\var selRoute = document.getElementById('sel-route');
    \\function setSelectMode(mode) {
    \\  selectMode = mode;
    \\  if (selComp) selComp.classList.toggle('active', mode==='component');
    \\  if (selNet) selNet.classList.toggle('active', mode==='net');
    \\  if (selSec) selSec.classList.toggle('active', mode==='section');
    \\  if (selTrace) selTrace.classList.toggle('active', mode==='trace');
    \\  if (selRoute) selRoute.classList.toggle('active', mode==='route');
    \\  // Disable trace/via click interception in route mode so pads are reachable
    \\  layerContainers.traces_fcu.interactiveChildren = (mode !== 'route');
    \\  layerContainers.traces_bcu.interactiveChildren = (mode !== 'route');
    \\  layerContainers.vias.interactiveChildren = (mode !== 'route');
    \\  cancelRouting();
    \\  clearSelection();
    \\  updateSectionBoxes();
    \\}
    \\if (selComp) selComp.onclick = function() { setSelectMode('component'); };
    \\if (selNet) selNet.onclick = function() { setSelectMode('net'); };
    \\if (selSec) selSec.onclick = function() { setSelectMode('section'); };
    \\if (selTrace) selTrace.onclick = function() { setSelectMode('trace'); };
    \\if (selRoute) selRoute.onclick = function() { setSelectMode('route'); };
    \\
    \\// --- Init ---
    \\console.log('[PCB] Calling buildScene...');
    \\buildScene();
    \\console.log('[PCB] buildScene done, calling showDefaultSidebar...');
    \\showDefaultSidebar();
    \\console.log('[PCB] Init complete');
    \\
    \\} catch(err) { document.getElementById('pixi-container').innerHTML = '<pre style="color:red;padding:20px">'+err.stack+'</pre>'; }
    \\})();
;
