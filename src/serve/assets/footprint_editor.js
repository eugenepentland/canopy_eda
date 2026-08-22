(function () {
  'use strict';
  var NS = 'http://www.w3.org/2000/svg';
  var name = document.body.dataset.footprint;
  var svg = document.getElementById('editor-svg');
  var geom = document.getElementById('geometry');
  var dimLayer = document.getElementById('dimensions');
  var interaction = document.getElementById('interaction');
  var wrap = document.getElementById('canvas-wrap');
  var state = {
    data: null, revision: '', originals: [], pads: [], court: null, originalCourt: null,
    selected: [], tool: 'select', grid: .1, units: 'mm', snap: true,
    view: {x: -5, y: -5, w: 10, h: 10}, history: [], future: [],
    dragging: null, marquee: null, panning: null, space: false, dimDraft: null, constructDraft: null, hover: null,
    dimensions: [], constructions: [], nextKey: 1, layers: {pads: true, silk: true, fab: true, courtyard: true}
  };

  function E(tag, attrs, text) {
    var node = document.createElementNS(NS, tag);
    Object.keys(attrs || {}).forEach(function (key) { node.setAttribute(key, attrs[key]); });
    if (text != null) node.textContent = text;
    return node;
  }
  function clone(value) { return JSON.parse(JSON.stringify(value)); }
  function round(v, n) { var p = Math.pow(10, n == null ? 4 : n); return Math.round(v * p) / p; }
  function finite(v) { return Number.isFinite(Number(v)); }
  function evaluateExpression(source) {
    var text=String(source == null?'':source).replace(/×/g,'*').replace(/÷/g,'/'),index=0;
    function whitespace(){while(/\s/.test(text.charAt(index)))index++;}
    function number(){whitespace();var match=text.slice(index).match(/^(?:(?:\d+(?:\.\d*)?)|(?:\.\d+))(?:[eE][+-]?\d+)?/);if(!match)return NaN;index+=match[0].length;return Number(match[0]);}
    function factor(){whitespace();var ch=text.charAt(index);if(ch==='+'||ch==='-'){index++;var unary=factor();return ch==='-'?-unary:unary;}if(ch==='('){index++;var nested=sum();whitespace();if(text.charAt(index)!==')')return NaN;index++;return nested;}return number();}
    function product(){var value=factor();while(true){whitespace();var op=text.charAt(index);if(op!=='*'&&op!=='/')break;index++;var rhs=factor();value=op==='*'?value*rhs:value/rhs;}return value;}
    function sum(){var value=product();while(true){whitespace();var op=text.charAt(index);if(op!=='+'&&op!=='-')break;index++;var rhs=product();value=op==='+'?value+rhs:value-rhs;}return value;}
    whitespace();if(index>=text.length)return NaN;var result=sum();whitespace();return index===text.length&&Number.isFinite(result)?result:NaN;
  }
  function toast(message, error) {
    var el = document.getElementById('toast');
    el.textContent = message; el.className = 'show' + (error ? ' error' : '');
    clearTimeout(el._timer); el._timer = setTimeout(function () { el.className = ''; }, 3000);
  }
  function padComparable(p) {
    return {id:p.id, type:p.type, shape:p.shape, x:round(p.x), y:round(p.y), w:round(p.w), h:round(p.h),
      drillX:round(p.drillX || 0), drillY:round(p.drillY || 0), roundrectRatio:p.roundrectRatio == null ? null : round(p.roundrectRatio),
      maskMargin:p.maskMargin == null ? null : round(p.maskMargin), noPaste:!!p.noPaste, poly:p.poly || null};
  }
  function same(a, b) { return JSON.stringify(a) === JSON.stringify(b); }
  function sourceChanges() {
    if (!state.data) return {changes:[], additions:[], courtyard:null};
    var byIndex = {};
    state.pads.forEach(function (p) { if (p._sourceIndex != null) byIndex[p._sourceIndex] = p; });
    var changes = [];
    state.originals.forEach(function (original, i) {
      var current = byIndex[i];
      if (!current) changes.push({index:i, remove:true});
      else if (!same(padComparable(original), padComparable(current))) changes.push({index:i, pad:serializePad(current)});
    });
    var additions = state.pads.filter(function (p) { return p._sourceIndex == null; }).map(serializePad);
    var courtyard = same(state.court, state.originalCourt) ? null : clone(state.court);
    return {changes:changes, additions:additions, courtyard:courtyard};
  }
  function isDirty() {
    var c = sourceChanges(); return c.changes.length > 0 || c.additions.length > 0 || c.courtyard != null;
  }
  function refreshDirty() {
    var dirty = isDirty(), label = document.getElementById('dirty-label');
    label.textContent = dirty ? 'Unsaved changes' : 'Saved'; label.classList.toggle('dirty', dirty);
    document.getElementById('save').disabled = !dirty;
    document.getElementById('undo').disabled = state.history.length === 0;
    document.getElementById('redo').disabled = state.future.length === 0;
  }
  function snapshot() { return {pads:clone(state.pads), court:clone(state.court), selected:clone(state.selected), constructions:clone(state.constructions)}; }
  function restore(s) { state.pads=clone(s.pads); state.court=clone(s.court); state.selected=clone(s.selected);if(s.constructions)state.constructions=clone(s.constructions);persistConstructions();render();syncInspector(); }
  function checkpoint() { state.history.push(snapshot()); if (state.history.length > 100) state.history.shift(); state.future=[]; }
  function undo() { if (!state.history.length) return; state.future.push(snapshot()); restore(state.history.pop()); }
  function redo() { if (!state.future.length) return; state.history.push(snapshot()); restore(state.future.pop()); }

  function normalizePad(p, key) {
    return { _key:key, _sourceIndex:p.index == null ? null : p.index, id:String(p.id || ''), type:p.type || (p.npth?'npth':'smd'),
      shape:p.shape || 'rect', x:Number(p.x)||0, y:Number(p.y)||0, w:Number(p.w)||1, h:Number(p.h)||1,
      drillX:Number(p.drillX != null ? p.drillX : p.drill)||0, drillY:Number(p.drillY != null ? p.drillY : p.drill)||0,
      roundrectRatio:p.roundrectRatio == null ? null : Number(p.roundrectRatio), maskMargin:p.maskMargin == null ? null : Number(p.maskMargin),
      noPaste:!!p.noPaste, poly:p.poly ? clone(p.poly) : null };
  }
  function serializePad(p) {
    var result = {id:String(p.id), type:p.type, shape:p.shape, x:round(p.x), y:round(p.y), w:round(p.w), h:round(p.h),
      drill_x:round(p.drillX||0), drill_y:round(p.drillY||0), no_paste:!!p.noPaste};
    if (p.roundrectRatio != null) result.roundrect_ratio=round(p.roundrectRatio);
    if (p.maskMargin != null) result.mask_margin=round(p.maskMargin);
    if (p.poly) result.poly=clone(p.poly);
    return result;
  }
  function initialCourt(data) {
    var rects=(data.courtyard&&data.courtyard.rects)||[];
    if (rects.length) { var r=rects[0]; return {x0:Math.min(r[0],r[2]),y0:Math.min(r[1],r[3]),x1:Math.max(r[0],r[2]),y1:Math.max(r[1],r[3])}; }
    return fitCourt(.25);
  }
  function fitCourt(clearance) {
    if (!state.pads.length) return {x0:-1,y0:-1,x1:1,y1:1};
    var b=padBounds(), g=state.grid;
    return {x0:Math.floor((b.x0-clearance)/g+1e-8)*g, y0:Math.floor((b.y0-clearance)/g+1e-8)*g,
      x1:Math.ceil((b.x1+clearance)/g-1e-8)*g, y1:Math.ceil((b.y1+clearance)/g-1e-8)*g};
  }
  function padBounds() {
    var b={x0:Infinity,y0:Infinity,x1:-Infinity,y1:-Infinity};
    state.pads.forEach(function(p){
      if(p.poly&&p.poly.length){p.poly.forEach(function(q){b.x0=Math.min(b.x0,q[0]);b.y0=Math.min(b.y0,q[1]);b.x1=Math.max(b.x1,q[0]);b.y1=Math.max(b.y1,q[1]);});}
      else {b.x0=Math.min(b.x0,p.x-p.w/2);b.y0=Math.min(b.y0,p.y-p.h/2);b.x1=Math.max(b.x1,p.x+p.w/2);b.y1=Math.max(b.y1,p.y+p.h/2);}
    }); return b;
  }
  function padBox(p) {
    if(p.poly&&p.poly.length){var b={x0:Infinity,y0:Infinity,x1:-Infinity,y1:-Infinity};p.poly.forEach(function(q){b.x0=Math.min(b.x0,q[0]);b.y0=Math.min(b.y0,q[1]);b.x1=Math.max(b.x1,q[0]);b.y1=Math.max(b.y1,q[1]);});return b;}
    return {x0:p.x-p.w/2,y0:p.y-p.h/2,x1:p.x+p.w/2,y1:p.y+p.h/2};
  }
  function isSelected(key) { return state.selected.indexOf(key)>=0; }
  function selectedPads() { return state.pads.filter(function(p){return isSelected(p._key);}); }
  function selectionCenter(pads) {
    if(!pads.length)return{x:0,y:0};var sum=pads.reduce(function(a,p){a.x+=p.x;a.y+=p.y;return a;},{x:0,y:0});
    return{x:sum.x/pads.length,y:sum.y/pads.length};
  }

  function setView(view) {
    state.view=view; svg.setAttribute('viewBox',[view.x,view.y,view.w,view.h].join(' ')); updateGrid();
  }
  function updateGrid() {
    var pattern=document.getElementById('minor-grid'), plane=document.getElementById('grid-plane');
    pattern.setAttribute('width',state.grid);pattern.setAttribute('height',state.grid);
    pattern.firstElementChild.setAttribute('d','M '+state.grid+' 0 L 0 0 0 '+state.grid);
    plane.setAttribute('x',state.view.x-state.view.w);plane.setAttribute('y',state.view.y-state.view.h);
    plane.setAttribute('width',state.view.w*3);plane.setAttribute('height',state.view.h*3);
  }
  function fitView() {
    var pts=[];
    state.pads.forEach(function(p){if(p.poly)p.poly.forEach(function(q){pts.push(q);});else {pts.push([p.x-p.w/2,p.y-p.h/2],[p.x+p.w/2,p.y+p.h/2]);}});
    if(state.court)pts.push([state.court.x0,state.court.y0],[state.court.x1,state.court.y1]);
    ['silk','fab'].forEach(function(k){var d=state.data[k]||{};(d.lines||[]).forEach(function(s){pts.push([s[0],s[1]],[s[2],s[3]]);});(d.rects||[]).forEach(function(r){pts.push([r[0],r[1]],[r[2],r[3]]);});(d.circles||[]).forEach(function(c){pts.push([c[0]-c[2],c[1]-c[2]],[c[0]+c[2],c[1]+c[2]]);});});
    if(!pts.length)pts=[[-2,-2],[2,2]];
    var x0=Infinity,y0=Infinity,x1=-Infinity,y1=-Infinity;pts.forEach(function(p){x0=Math.min(x0,p[0]);y0=Math.min(y0,p[1]);x1=Math.max(x1,p[0]);y1=Math.max(y1,p[1]);});
    var pad=Math.max(x1-x0,y1-y0)*.14+.5,w=Math.max(.5,x1-x0+2*pad),h=Math.max(.5,y1-y0+2*pad),aspect=wrap.clientWidth/Math.max(1,wrap.clientHeight);
    if(w/h<aspect)w=h*aspect;else h=w/aspect;
    setView({x:(x0+x1-w)/2,y:(y0+y1-h)/2,w:w,h:h});
  }
  function worldPoint(event) {
    var pt=svg.createSVGPoint();pt.x=event.clientX;pt.y=event.clientY;var m=svg.getScreenCTM();if(!m)return{x:0,y:0};return pt.matrixTransform(m.inverse());
  }
  function display(v) { return state.units==='mil' ? (v/0.0254).toFixed(2)+' mil' : v.toFixed(3)+' mm'; }
  function updateReadout(p) { document.getElementById('cursor-readout').textContent='X '+display(p.x)+' · Y '+display(p.y); }

  function drawLayer(parent, data, cls) {
    (data.polys||[]).forEach(function(poly){parent.appendChild(E('polygon',{points:poly.map(function(p){return p.join(',');}).join(' '),'class':cls}));});
    (data.rects||[]).forEach(function(r){parent.appendChild(E('rect',{x:Math.min(r[0],r[2]),y:Math.min(r[1],r[3]),width:Math.abs(r[2]-r[0]),height:Math.abs(r[3]-r[1]),'class':cls}));});
    (data.circles||[]).forEach(function(c){parent.appendChild(E('circle',{cx:c[0],cy:c[1],r:c[2],'class':cls}));});
    (data.lines||[]).forEach(function(s){parent.appendChild(E('line',{x1:s[0],y1:s[1],x2:s[2],y2:s[3],'class':cls}));});
  }
  function renderPad(parent,p) {
    var node=FP.padShape(p,{scale:1,cls:'fp-pad'+(p.type==='npth'?' npth':'')+(isSelected(p._key)?' selected':'')});
    node.setAttribute('data-pad-key',p._key);parent.appendChild(node);
    if(p.drillX>0){var hole=E(p.drillX===p.drillY?'circle':'ellipse',{cx:p.x,cy:p.y,'class':'fp-hole','pointer-events':'none'});if(hole.tagName==='circle')hole.setAttribute('r',p.drillX/2);else{hole.setAttribute('rx',p.drillX/2);hole.setAttribute('ry',p.drillY/2);}parent.appendChild(hole);}
    var label=FP.padLabel(p,1);if(label){label.setAttribute('class','fp-label');parent.appendChild(label);}
  }
  function render() {
    if(!state.data)return;geom.replaceChildren();dimLayer.replaceChildren();interaction.replaceChildren();
    if(state.layers.courtyard&&state.court)geom.appendChild(E('rect',{x:state.court.x0,y:state.court.y0,width:state.court.x1-state.court.x0,height:state.court.y1-state.court.y0,'class':'fp-court'}));
    if(state.layers.fab)drawLayer(geom,state.data.fab||{},'fp-fab');if(state.layers.silk)drawLayer(geom,state.data.silk||{},'fp-silk');
    var tick=Math.max(state.view.w,state.view.h)/60;geom.appendChild(E('line',{x1:-tick,y1:0,x2:tick,y2:0,'class':'origin-mark'}));geom.appendChild(E('line',{x1:0,y1:-tick,x2:0,y2:tick,'class':'origin-mark'}));
    if(state.layers.pads)state.pads.forEach(function(p){renderPad(geom,p);});
    state.constructions.forEach(function(c){drawConstruction(dimLayer,c,false);});
    state.dimensions.forEach(function(d){drawDimension(dimLayer,d,false);});
    if(state.constructDraft)drawConstructionDraft();if(state.dimDraft)drawDraft();if(state.hover&&!state.marquee)drawSnap(state.hover);if(state.marquee)drawMarquee();
    refreshDirty();renderConstructionList();renderDimensionList();
  }
  function drawSnap(s) {
    var r=Math.max(state.view.w,state.view.h)/110;interaction.appendChild(E('circle',{cx:s.x,cy:s.y,r:r,'class':'snap-mark'}));
  }
  function drawMarquee() {
    var m=state.marquee,x=Math.min(m.start.x,m.current.x),y=Math.min(m.start.y,m.current.y);
    interaction.appendChild(E('rect',{x:x,y:y,width:Math.abs(m.current.x-m.start.x),height:Math.abs(m.current.y-m.start.y),'class':'selection-box'}));
  }
  function dimensionGeometry(d) {
    var p1=d.p1,p2=d.p2,q1,q2;
    if(d.kind==='dim-horizontal'){q1={x:p1.x,y:d.offset};q2={x:p2.x,y:d.offset};}
    else if(d.kind==='dim-vertical'){q1={x:d.offset,y:p1.y};q2={x:d.offset,y:p2.y};}
    else {var dx=p2.x-p1.x,dy=p2.y-p1.y,len=Math.hypot(dx,dy)||1,nx=-dy/len,ny=dx/len;q1={x:p1.x+nx*d.offset,y:p1.y+ny*d.offset};q2={x:p2.x+nx*d.offset,y:p2.y+ny*d.offset};}
    return {q1:q1,q2:q2};
  }
  function dimensionValue(d) { return d.kind==='dim-horizontal'?Math.abs(d.p2.x-d.p1.x):d.kind==='dim-vertical'?Math.abs(d.p2.y-d.p1.y):Math.hypot(d.p2.x-d.p1.x,d.p2.y-d.p1.y); }
  function drawDimension(parent,d,preview) {
    var g=dimensionGeometry(d),q1=g.q1,q2=g.q2,cls=preview?' dim-preview':'';
    parent.appendChild(E('line',{x1:d.p1.x,y1:d.p1.y,x2:q1.x,y2:q1.y,'class':'dim-ext'+cls}));parent.appendChild(E('line',{x1:d.p2.x,y1:d.p2.y,x2:q2.x,y2:q2.y,'class':'dim-ext'+cls}));
    parent.appendChild(E('line',{x1:q1.x,y1:q1.y,x2:q2.x,y2:q2.y,'class':'dim-line'+cls}));
    var dx=q2.x-q1.x,dy=q2.y-q1.y,len=Math.hypot(dx,dy)||1,nx=-dy/len,ny=dx/len,t=Math.max(state.view.w,state.view.h)/100;
    [q1,q2].forEach(function(q){parent.appendChild(E('line',{x1:q.x-nx*t,y1:q.y-ny*t,x2:q.x+nx*t,y2:q.y+ny*t,'class':'dim-line'+cls}));});
    var mx=(q1.x+q2.x)/2,my=(q1.y+q2.y)/2,ang=Math.atan2(dy,dx)*180/Math.PI;if(ang>90||ang<-90)ang+=180;
    var text=E('text',{x:mx+nx*t*1.5,y:my+ny*t*1.5,'text-anchor':'middle','dominant-baseline':'central','class':'dim-text'+cls,'font-size':t*2.2,'stroke-width':t*.45,transform:'rotate('+ang+' '+(mx+nx*t*1.5)+' '+(my+ny*t*1.5)+')'},display(dimensionValue(d)));parent.appendChild(text);
  }
  function draftDimension(cursor) {
    var d=state.dimDraft;if(!d)return null;
    if(d.step===1)return {kind:d.kind,p1:d.p1,p2:cursor,offset:d.kind==='dim-horizontal'?cursor.y:d.kind==='dim-vertical'?cursor.x:0};
    var result={kind:d.kind,p1:d.p1,p2:d.p2,offset:0};
    if(d.kind==='dim-horizontal')result.offset=cursor.y;else if(d.kind==='dim-vertical')result.offset=cursor.x;else{var dx=d.p2.x-d.p1.x,dy=d.p2.y-d.p1.y,len=Math.hypot(dx,dy)||1;result.offset=((cursor.x-d.p1.x)*(-dy)+(cursor.y-d.p1.y)*dx)/len;}return result;
  }
  function drawDraft() { var d=draftDimension(state.hover||state.dimDraft.p1);if(d)drawDimension(interaction,d,true); }

  function padOccurrence(pad) {
    var occurrence=0;
    for(var i=0;i<state.pads.length;i++){if(state.pads[i]===pad)return occurrence;if(state.pads[i].id===pad.id)occurrence++;}
    return occurrence;
  }
  function padAnchor(pad,edgeX,edgeY) {
    return {type:'pad',key:pad._key,sourceIndex:pad._sourceIndex,padId:pad.id,occurrence:padOccurrence(pad),edgeX:edgeX,edgeY:edgeY};
  }
  function resolveAnchorPad(anchor) {
    if(!anchor||anchor.type!=='pad')return null;
    var pad=null;
    if(anchor.sourceIndex!=null)pad=state.pads.find(function(p){return p._sourceIndex===anchor.sourceIndex;});
    if(!pad&&anchor.key)pad=state.pads.find(function(p){return p._key===anchor.key;});
    if(!pad&&anchor.padId!=null){var matches=state.pads.filter(function(p){return p.id===anchor.padId;});pad=matches[anchor.occurrence||0]||null;}
    return pad;
  }
  function anchorPoint(anchor,fallback) {
    if(!anchor)return clone(fallback);
    if(anchor.type==='origin')return{x:0,y:0};
    if(anchor.type==='point')return{x:anchor.x,y:anchor.y};
    var pad=resolveAnchorPad(anchor);if(!pad||pad.poly)return clone(fallback);
    return{x:pad.x+(anchor.edgeX||0)*pad.w/2,y:pad.y+(anchor.edgeY||0)*pad.h/2};
  }
  function anchorLabel(anchor,label) {
    if(!anchor)return label||'point';if(anchor.type==='origin')return'Origin';if(anchor.type==='point')return label||'Construction point';
    var pad=resolveAnchorPad(anchor),id=pad?pad.id:anchor.padId,parts=[];
    if(anchor.edgeY<0)parts.push('top');else if(anchor.edgeY>0)parts.push('bottom');
    if(anchor.edgeX<0)parts.push('left');else if(anchor.edgeX>0)parts.push('right');
    if(!parts.length)parts.push('center');return'Pad '+id+' '+parts.join('-');
  }
  function constructionPoints(c) { return{p1:anchorPoint(c.a1,c.fallback1),p2:anchorPoint(c.a2,c.fallback2)}; }
  function constructionLength(c) { var p=constructionPoints(c);return Math.hypot(p.p2.x-p.p1.x,p.p2.y-p.p1.y); }
  function constructionUnit(p1,p2) {
    var dx=p2.x-p1.x,dy=p2.y-p1.y,len=Math.hypot(dx,dy)||1;
    if(Math.abs(dx)<1e-8)return{x:0,y:dy<0?-1:1};if(Math.abs(dy)<1e-8)return{x:dx<0?-1:1,y:0};return{x:dx/len,y:dy/len};
  }
  function drawConstruction(parent,c,preview) {
    var p=constructionPoints(c),p1=p.p1,p2=p.p2,t=Math.max(state.view.w,state.view.h)/105,cls=preview?' construction-preview':'';
    parent.appendChild(E('line',{x1:p1.x,y1:p1.y,x2:p2.x,y2:p2.y,'class':'construction-line'+cls}));
    parent.appendChild(E('circle',{cx:p1.x,cy:p1.y,r:t*.48,'class':'construction-end'+cls}));parent.appendChild(E('circle',{cx:p2.x,cy:p2.y,r:t*.48,'class':'construction-end'+cls}));
    var mx=(p1.x+p2.x)/2,my=(p1.y+p2.y)/2,unit=constructionUnit(p1,p2),nx=-unit.y,ny=unit.x;
    if(c.centered){var s=t*.65;parent.appendChild(E('path',{d:'M '+mx+' '+(my-s)+' L '+(mx+s)+' '+my+' L '+mx+' '+(my+s)+' L '+(mx-s)+' '+my+' Z','class':'construction-center'+cls}));}
    if(!preview){var text=E('text',{x:mx+nx*t*1.25,y:my+ny*t*1.25,'text-anchor':'middle','dominant-baseline':'central','class':'construction-text','font-size':t*1.75},display(Math.hypot(p2.x-p1.x,p2.y-p1.y)));parent.appendChild(text);}
  }
  function drawConstructionDraft() {
    var first=state.constructDraft,snap=state.hover||first.snap,c={a1:first.anchor,a2:snap&&snap.anchor?snap.anchor:{type:'point',x:snap.x,y:snap.y},fallback1:first.point,fallback2:{x:snap.x,y:snap.y},centered:false};drawConstruction(interaction,c,true);
  }
  function anchorCanMove(anchor) { return !!anchor&&(anchor.type==='point'||(anchor.type==='pad'&&resolveAnchorPad(anchor)&&!resolveAnchorPad(anchor).poly)); }
  function driveConstruction(c,length,centered) {
    var points=constructionPoints(c),unit=constructionUnit(points.p1,points.p2),targets;
    if(centered)targets=[{x:-unit.x*length/2,y:-unit.y*length/2},{x:unit.x*length/2,y:unit.y*length/2}];
    else if(anchorCanMove(c.a2))targets=[points.p1,{x:points.p1.x+unit.x*length,y:points.p1.y+unit.y*length}];
    else if(anchorCanMove(c.a1))targets=[{x:points.p2.x-unit.x*length,y:points.p2.y-unit.y*length},points.p2];
    else{toast('Attach at least one construction endpoint to a movable pad edge',true);return false;}
    var anchors=[c.a1,c.a2],fallbacks=[c.fallback1,c.fallback2],moves={},pointUpdates=[];
    for(var i=0;i<2;i++){
      var anchor=anchors[i],current=anchorPoint(anchor,fallbacks[i]),target=targets[i],dx=target.x-current.x,dy=target.y-current.y;
      if(anchor.type==='origin'){
        if(Math.hypot(dx,dy)>1e-5){toast('The origin endpoint cannot move; bind both ends to pad edges before centering',true);return false;}
      }else if(anchor.type==='point')pointUpdates.push({anchor:anchor,target:target});
      else if(anchor.type==='pad'){
        var pad=resolveAnchorPad(anchor);if(!pad||pad.poly){toast('A construction endpoint is no longer attached to a movable pad',true);return false;}
        var prior=moves[pad._key];if(prior&&Math.hypot(prior.dx-dx,prior.dy-dy)>1e-5){toast('Both endpoints cannot drive different edges of the same pad',true);return false;}
        moves[pad._key]={pad:pad,dx:dx,dy:dy};
      }
    }
    checkpoint();
    Object.keys(moves).forEach(function(key){var move=moves[key];move.pad.x=round(move.pad.x+move.dx);move.pad.y=round(move.pad.y+move.dy);});
    pointUpdates.forEach(function(update){update.anchor.x=round(update.target.x);update.anchor.y=round(update.target.y);});
    c.fallback1=clone(targets[0]);c.fallback2=clone(targets[1]);c.centered=!!centered;persistConstructions();render();syncInspector();return true;
  }

  function candidates(excludeKeys) {
    var c=[{x:0,y:0,label:'origin',anchor:{type:'origin'}}];
    state.pads.forEach(function(p){
      if(excludeKeys&&excludeKeys.indexOf(p._key)>=0)return;
      if(p.poly){p.poly.forEach(function(q){c.push({x:q[0],y:q[1],label:'pad '+p.id+' vertex'});});return;}
      [-1,0,1].forEach(function(edgeX){[-1,0,1].forEach(function(edgeY){var centre=edgeX===0&&edgeY===0;c.push({x:p.x+edgeX*p.w/2,y:p.y+edgeY*p.h/2,label:'pad '+p.id+(centre?' centre':' edge'),anchor:padAnchor(p,edgeX,edgeY)});});});
    });
    ['silk','fab'].forEach(function(k){var d=state.data[k]||{};(d.lines||[]).forEach(function(s){c.push({x:s[0],y:s[1],label:k+' endpoint'},{x:s[2],y:s[3],label:k+' endpoint'});});(d.rects||[]).forEach(function(r){c.push({x:r[0],y:r[1],label:k+' corner'},{x:r[2],y:r[1],label:k+' corner'},{x:r[2],y:r[3],label:k+' corner'},{x:r[0],y:r[3],label:k+' corner'});});(d.circles||[]).forEach(function(q){c.push({x:q[0],y:q[1],label:k+' centre'},{x:q[0]+q[2],y:q[1],label:k+' edge'},{x:q[0]-q[2],y:q[1],label:k+' edge'},{x:q[0],y:q[1]+q[2],label:k+' edge'},{x:q[0],y:q[1]-q[2],label:k+' edge'});});});
    if(state.court){var r=state.court;c.push({x:r.x0,y:r.y0,label:'courtyard corner'},{x:r.x1,y:r.y0,label:'courtyard corner'},{x:r.x1,y:r.y1,label:'courtyard corner'},{x:r.x0,y:r.y1,label:'courtyard corner'});}
    return c;
  }
  function snapPoint(p,excludeKeys) {
    var grid={x:round(Math.round(p.x/state.grid)*state.grid),y:round(Math.round(p.y/state.grid)*state.grid),label:'grid'};
    if(!state.snap)return grid;var threshold=11*state.view.w/Math.max(1,wrap.clientWidth),best=null,bestD=threshold;
    candidates(excludeKeys).forEach(function(q){var d=Math.hypot(q.x-p.x,q.y-p.y);if(d<bestD){best=q;bestD=d;}});return best||grid;
  }

  function setTool(tool) {
    state.tool=tool;state.dimDraft=null;state.constructDraft=null;document.querySelectorAll('.tool').forEach(function(b){b.classList.toggle('active',b.dataset.tool===tool);});
    var hints={select:'Click, Shift-click, or marquee pads · drag a selected pad to move the group','dim-aligned':'Aligned dimension: click the first point','dim-horizontal':'X dimension: click the first point','dim-vertical':'Y dimension: click the first point',construction:'Construction: click the first pad edge'};
    document.getElementById('tool-hint').textContent=hints[tool]||'';render();
  }
  function dimensionClick(p) {
    var snapped=snapPoint(p);
    if(!state.dimDraft){state.dimDraft={kind:state.tool,step:1,p1:{x:snapped.x,y:snapped.y}};document.getElementById('tool-hint').textContent='Click the second measurement point';}
    else if(state.dimDraft.step===1){if(Math.hypot(snapped.x-state.dimDraft.p1.x,snapped.y-state.dimDraft.p1.y)<1e-8)return;state.dimDraft.p2={x:snapped.x,y:snapped.y};state.dimDraft.step=2;document.getElementById('tool-hint').textContent='Click to place the dimension line';}
    else {var d=draftDimension(snapped);d.id=Date.now()+'-'+Math.random().toString(16).slice(2);state.dimensions.push(d);persistDimensions();state.dimDraft=null;document.getElementById('tool-hint').textContent='Dimension added · click another first point';}
    render();
  }
  function constructionClick(p) {
    var snapped=snapPoint(p),anchor=snapped.anchor?clone(snapped.anchor):{type:'point',x:snapped.x,y:snapped.y};
    if(!state.constructDraft){state.constructDraft={anchor:anchor,point:{x:snapped.x,y:snapped.y},label:snapped.label,snap:snapped};document.getElementById('tool-hint').textContent='Construction: click the second pad edge';render();return;}
    if(Math.hypot(snapped.x-state.constructDraft.point.x,snapped.y-state.constructDraft.point.y)<1e-8)return;
    var midpoint={x:(snapped.x+state.constructDraft.point.x)/2,y:(snapped.y+state.constructDraft.point.y)/2};
    checkpoint();state.constructions.push({id:Date.now()+'-'+Math.random().toString(16).slice(2),a1:state.constructDraft.anchor,a2:anchor,fallback1:state.constructDraft.point,fallback2:{x:snapped.x,y:snapped.y},label1:state.constructDraft.label,label2:snapped.label,centered:Math.hypot(midpoint.x,midpoint.y)<1e-7});
    state.constructDraft=null;persistConstructions();document.getElementById('tool-hint').textContent='Construction added · edit its length in the sidebar';render();
  }
  function renderConstructionList() {
    var box=document.getElementById('construction-list');box.replaceChildren();if(!state.constructions.length){var empty=document.createElement('p');empty.className='muted';empty.textContent='No construction lines yet.';box.appendChild(empty);return;}
    state.constructions.forEach(function(c){
      var row=document.createElement('div'),head=document.createElement('div'),info=document.createElement('div'),strong=document.createElement('strong'),meta=document.createElement('span'),del=document.createElement('button'),controls=document.createElement('div'),lengthLabel=document.createElement('label'),lengthInput=document.createElement('input'),centerLabel=document.createElement('label'),centerInput=document.createElement('input');
      row.className='construction-row';head.className='construction-head';controls.className='construction-controls';strong.textContent=anchorLabel(c.a1,c.label1)+' ↔ '+anchorLabel(c.a2,c.label2);var attached=[c.a1,c.a2].filter(function(a){return a.type==='pad'&&resolveAnchorPad(a);}).length;meta.textContent=(c.centered?'Centered at origin · ':'')+(attached?('drives '+attached+' pad'+(attached===1?'':'s')):'reference geometry');
      del.textContent='×';del.title='Remove construction';del.onclick=function(){checkpoint();state.constructions=state.constructions.filter(function(item){return item.id!==c.id;});persistConstructions();render();};info.append(strong,meta);head.append(info,del);
      lengthInput.type='text';lengthInput.inputMode='decimal';lengthInput.className='expression-input';lengthInput.value=round(constructionLength(c));lengthInput.title='Arithmetic is accepted, for example 2.54/2';lengthInput.oninput=function(){this.classList.remove('invalid');};lengthInput.onchange=function(){var value=evaluateExpression(this.value);if(!Number.isFinite(value)||value<=0){this.classList.add('invalid');toast('Enter a positive length or arithmetic expression',true);return;}if(!driveConstruction(c,value,c.centered)){this.value=round(constructionLength(c));return;}this.classList.remove('invalid');};lengthLabel.textContent='Driving length';lengthLabel.appendChild(lengthInput);
      centerInput.type='checkbox';centerInput.checked=!!c.centered;centerInput.onchange=function(){if(this.checked){if(!driveConstruction(c,constructionLength(c),true)){this.checked=false;return;}}else{checkpoint();c.centered=false;persistConstructions();render();}};centerLabel.className='center-check';centerLabel.append(centerInput,document.createTextNode(' Center on origin'));
      controls.append(lengthLabel,centerLabel);row.append(head,controls);box.appendChild(row);
    });
  }
  function persistConstructions(){try{localStorage.setItem('footprint-constructions:'+name,JSON.stringify(state.constructions));}catch(ignore){}}
  function loadConstructions(){try{var c=JSON.parse(localStorage.getItem('footprint-constructions:'+name)||'[]');state.constructions=Array.isArray(c)?c:[];}catch(ignore){state.constructions=[];}}
  function renderDimensionList() {
    var box=document.getElementById('dimension-list');box.replaceChildren();if(!state.dimensions.length){var p=document.createElement('p');p.className='muted';p.textContent='No dimensions yet.';box.appendChild(p);return;}
    state.dimensions.forEach(function(d){var row=document.createElement('div');row.className='dimension-row';var info=document.createElement('div'),strong=document.createElement('strong'),meta=document.createElement('span'),del=document.createElement('button');strong.textContent=display(dimensionValue(d));meta.textContent=(d.kind==='dim-horizontal'?'X':d.kind==='dim-vertical'?'Y':'Aligned')+' · ΔX '+display(Math.abs(d.p2.x-d.p1.x))+' · ΔY '+display(Math.abs(d.p2.y-d.p1.y));del.textContent='×';del.title='Remove dimension';del.onclick=function(){state.dimensions=state.dimensions.filter(function(x){return x.id!==d.id;});persistDimensions();render();};info.append(strong,meta);row.append(info,del);box.appendChild(row);});
  }
  function persistDimensions(){try{localStorage.setItem('footprint-dimensions:'+name,JSON.stringify(state.dimensions));}catch(ignore){}}
  function loadDimensions(){try{var d=JSON.parse(localStorage.getItem('footprint-dimensions:'+name)||'[]');state.dimensions=Array.isArray(d)?d:[];}catch(ignore){state.dimensions=[];}}

  function selectedPad(){var pads=selectedPads();return pads.length===1?pads[0]:null;}
  function commonValue(pads,prop){if(!pads.length)return null;var value=pads[0][prop];return pads.every(function(p){return p[prop]===value;})?value:null;}
  function setInspectorValue(id,value,mixed){var el=document.getElementById(id);el.value=value==null?'':value;el.placeholder=mixed?'Mixed':'';el.classList.remove('invalid');}
  function syncInspector() {
    var pads=selectedPads(),one=pads.length===1,p=one?pads[0]:null,none=document.getElementById('nothing-selected'),panel=document.getElementById('pad-inspector');none.hidden=!!pads.length;panel.hidden=!pads.length;syncCourtInputs();if(!pads.length)return;
    document.getElementById('pad-inspector-title').textContent=one?'Pad '+p.id:pads.length+' pads';
    setInspectorValue('pad-id',one?p.id:null,!one);setInspectorValue('pad-type',one?p.type:null,!one);setInspectorValue('pad-shape',one?p.shape:null,!one);
    var center=selectionCenter(pads);setInspectorValue('pad-x',round(center.x),false);setInspectorValue('pad-y',round(center.y),false);
    setInspectorValue('pad-w',commonValue(pads,'w'),!one&&commonValue(pads,'w')==null);setInspectorValue('pad-h',commonValue(pads,'h'),!one&&commonValue(pads,'h')==null);
    setInspectorValue('pad-drill-x',one?p.drillX:null,!one);setInspectorValue('pad-drill-y',one?p.drillY:null,!one);
    var custom=pads.some(function(item){return !!item.poly;});document.getElementById('custom-note').hidden=!custom;document.getElementById('multi-note').hidden=one||custom;
    ['pad-id','pad-type','pad-shape','pad-drill-x','pad-drill-y'].forEach(function(id){document.getElementById(id).disabled=!one;});
    document.getElementById('pad-shape').disabled=!one||custom;
    ['pad-x','pad-y','pad-w','pad-h'].forEach(function(id){document.getElementById(id).disabled=custom;});
    document.getElementById('pad-x-label').textContent=one?'X':'Group center X';document.getElementById('pad-y-label').textContent=one?'Y':'Group center Y';
  }
  function syncCourtInputs(){if(!state.court)return;['x0','y0','x1','y1'].forEach(function(k){var input=document.getElementById('court-'+k);input.value=round(state.court[k]);input.classList.remove('invalid');});}
  function addPad() {
    checkpoint();var base={id:String(nextPadNumber()),type:'smd',shape:'rect',x:0,y:0,w:1,h:1,drillX:0,drillY:0,roundrectRatio:null,maskMargin:null,noPaste:false,poly:null};
    base._sourceIndex=null;base._key='new-'+(state.nextKey++);state.pads.push(base);state.selected=[base._key];setTool('select');render();syncInspector();
  }
  function nextPadNumber(){var nums=state.pads.map(function(p){return /^\d+$/.test(p.id)?Number(p.id):0;});return Math.max.apply(Math,[0].concat(nums))+1;}
  function duplicateSelected(){var pads=selectedPads();if(!pads.length)return;checkpoint();var next=nextPadNumber(),keys=[];pads.forEach(function(source){var copy=clone(source);copy._sourceIndex=null;copy._key='new-'+(state.nextKey++);copy.id=String(next++);if(!copy.poly){copy.x=round(copy.x+state.grid);copy.y=round(copy.y+state.grid);}state.pads.push(copy);keys.push(copy._key);});state.selected=keys;setTool('select');render();syncInspector();}
  function deleteSelected(){if(!state.selected.length)return;checkpoint();state.pads=state.pads.filter(function(x){return !isSelected(x._key);});state.selected=[];render();syncInspector();}

  function bindInspector() {
    var fields={
      'pad-id':function(v){return v;},'pad-type':function(v){return v;},'pad-shape':function(v){return v;},
      'pad-x':evaluateExpression,'pad-y':evaluateExpression,'pad-w':evaluateExpression,'pad-h':evaluateExpression,'pad-drill-x':evaluateExpression,'pad-drill-y':evaluateExpression
    },props={'pad-id':'id','pad-type':'type','pad-shape':'shape','pad-x':'x','pad-y':'y','pad-w':'w','pad-h':'h','pad-drill-x':'drillX','pad-drill-y':'drillY'};
    Object.keys(fields).forEach(function(id){document.getElementById(id).addEventListener('change',function(){var pads=selectedPads(),single=selectedPad();if(!pads.length)return;var value=fields[id](this.value);if((id!=='pad-id'&&!finite(value))||((id==='pad-w'||id==='pad-h')&&value<=0)||((id==='pad-drill-x'||id==='pad-drill-y')&&value<0)){this.classList.add('invalid');toast('Enter a valid arithmetic expression'+((id==='pad-w'||id==='pad-h')?' greater than zero':''),true);return;}this.classList.remove('invalid');checkpoint();if(id==='pad-x'||id==='pad-y'){var prop=props[id],center=selectionCenter(pads),delta=value-center[prop];pads.forEach(function(p){p[prop]=round(p[prop]+delta);});}else if(id==='pad-w'||id==='pad-h'){var sizeProp=props[id];pads.forEach(function(p){p[sizeProp]=value;if(p.shape==='circle'){p.w=value;p.h=value;}});}else if(single){single[props[id]]=value;if(id==='pad-type'&&value==='smd'){single.drillX=0;single.drillY=0;}if(id==='pad-shape'&&value==='circle')single.h=single.w;}render();syncInspector();});});
    ['x0','y0','x1','y1'].forEach(function(k){document.getElementById('court-'+k).addEventListener('change',function(){var v=evaluateExpression(this.value);if(!finite(v)){this.classList.add('invalid');toast('Enter a valid arithmetic expression',true);return;}var next=clone(state.court);next[k]=v;if(next.x1<=next.x0||next.y1<=next.y0){this.classList.add('invalid');toast('Courtyard right/bottom must be greater than left/top',true);return;}this.classList.remove('invalid');checkpoint();state.court=next;render();syncCourtInputs();});});
    document.querySelectorAll('.expression-input').forEach(function(input){input.title=input.title||'Arithmetic is accepted, for example 2.54/2';input.addEventListener('input',function(){this.classList.remove('invalid');});});
  }

  svg.addEventListener('pointerdown',function(e){
    var p=worldPoint(e);if(e.button===1||state.space){state.panning={clientX:e.clientX,clientY:e.clientY,view:clone(state.view)};svg.setPointerCapture(e.pointerId);e.preventDefault();return;}
    if(e.button!==0)return;
    if(state.tool.indexOf('dim-')===0){dimensionClick(p);e.preventDefault();return;}
    if(state.tool==='construction'){constructionClick(p);e.preventDefault();return;}
    var target=e.target.closest&&e.target.closest('[data-pad-key]');
    if(target){var key=target.getAttribute('data-pad-key'),pad=state.pads.find(function(x){return x._key===key;});if(e.shiftKey){if(isSelected(key))state.selected=state.selected.filter(function(k){return k!==key;});else state.selected.push(key);}else if(!isSelected(key))state.selected=[key];syncInspector();render();var group=selectedPads();if(isSelected(key)&&group.length&&!group.some(function(item){return !!item.poly;})){var origins={};group.forEach(function(item){origins[item._key]={x:item.x,y:item.y};});state.dragging={key:key,start:p,anchor:{x:pad.x,y:pad.y},origins:origins,checkpointed:false};svg.setPointerCapture(e.pointerId);}e.preventDefault();}
    else {state.marquee={start:p,current:p,before:e.shiftKey?clone(state.selected):[]};svg.setPointerCapture(e.pointerId);render();e.preventDefault();}
  });
  svg.addEventListener('pointermove',function(e){
    var p=worldPoint(e);updateReadout(p);
    if(state.panning){var dx=(e.clientX-state.panning.clientX)*state.panning.view.w/wrap.clientWidth,dy=(e.clientY-state.panning.clientY)*state.panning.view.h/wrap.clientHeight;setView({x:state.panning.view.x-dx,y:state.panning.view.y-dy,w:state.panning.view.w,h:state.panning.view.h});return;}
    if(state.marquee){state.marquee.current=p;render();return;}
    var snap=snapPoint(p);state.hover=snap;
    if(state.dragging){var desired={x:state.dragging.anchor.x+(p.x-state.dragging.start.x),y:state.dragging.anchor.y+(p.y-state.dragging.start.y)},padSnap=snapPoint(desired,state.selected),dx=padSnap.x-state.dragging.anchor.x,dy=padSnap.y-state.dragging.anchor.y;if(!state.dragging.checkpointed){checkpoint();state.dragging.checkpointed=true;}selectedPads().forEach(function(item){var origin=state.dragging.origins[item._key];item.x=round(origin.x+dx);item.y=round(origin.y+dy);});syncInspector();render();return;}
    if(state.dimDraft||state.constructDraft||state.tool.indexOf('dim-')===0||state.tool==='construction')render();
  });
  function finishMarquee(){if(!state.marquee)return;var m=state.marquee,x0=Math.min(m.start.x,m.current.x),y0=Math.min(m.start.y,m.current.y),x1=Math.max(m.start.x,m.current.x),y1=Math.max(m.start.y,m.current.y),threshold=3*state.view.w/Math.max(1,wrap.clientWidth),keys=clone(m.before);if(Math.hypot(x1-x0,y1-y0)>=threshold)state.pads.forEach(function(p){var b=padBox(p),hit=b.x1>=x0&&b.x0<=x1&&b.y1>=y0&&b.y0<=y1;if(hit&&keys.indexOf(p._key)<0)keys.push(p._key);});state.selected=keys;state.marquee=null;syncInspector();render();}
  function endPointer(e){if(state.dragging){state.dragging=null;render();}finishMarquee();state.panning=null;try{svg.releasePointerCapture(e.pointerId);}catch(ignore){}}
  svg.addEventListener('pointerup',endPointer);svg.addEventListener('pointercancel',endPointer);
  svg.addEventListener('pointerleave',function(){if(!state.dragging&&!state.marquee&&!state.dimDraft&&!state.constructDraft){state.hover=null;render();}});
  svg.addEventListener('wheel',function(e){e.preventDefault();var p=worldPoint(e),factor=Math.exp(e.deltaY*.0012),nw=Math.max(.2,Math.min(500,state.view.w*factor)),nh=nw*wrap.clientHeight/wrap.clientWidth,fx=(p.x-state.view.x)/state.view.w,fy=(p.y-state.view.y)/state.view.h;setView({x:p.x-fx*nw,y:p.y-fy*nh,w:nw,h:nh});render();},{passive:false});

  document.querySelectorAll('.tool').forEach(function(b){b.onclick=function(){setTool(b.dataset.tool);};});
  document.getElementById('add-pad').onclick=addPad;document.getElementById('duplicate-pad').onclick=duplicateSelected;document.getElementById('delete-pad').onclick=deleteSelected;
  document.getElementById('fit-view').onclick=function(){fitView();render();};document.getElementById('undo').onclick=undo;document.getElementById('redo').onclick=redo;
  document.getElementById('grid').onchange=function(){state.grid=Number(this.value);updateGrid();render();};document.getElementById('units').onchange=function(){state.units=this.value;render();};document.getElementById('snap').onchange=function(){state.snap=this.checked;};
  document.querySelectorAll('[data-layer]').forEach(function(input){input.onchange=function(){state.layers[input.dataset.layer]=input.checked;render();};});
  document.getElementById('court-from-pads').onclick=function(){var input=document.getElementById('court-clearance'),clearance=evaluateExpression(input.value);if(!Number.isFinite(clearance)||clearance<0){input.classList.add('invalid');toast('Enter a non-negative clearance expression',true);return;}checkpoint();state.court=fitCourt(clearance);render();syncCourtInputs();};
  document.getElementById('clear-constructions').onclick=function(){if(!state.constructions.length)return;checkpoint();state.constructions=[];persistConstructions();render();};
  document.getElementById('clear-dims').onclick=function(){state.dimensions=[];persistDimensions();render();};
  document.getElementById('save').onclick=save;
  bindInspector();

  window.addEventListener('keydown',function(e){
    if(e.code==='Space'&&!isInput(e.target)){state.space=true;e.preventDefault();}
    if(isInput(e.target))return;
    if((e.ctrlKey||e.metaKey)&&e.key.toLowerCase()==='s'){e.preventDefault();save();}else if((e.ctrlKey||e.metaKey)&&e.shiftKey&&e.key.toLowerCase()==='z'){e.preventDefault();redo();}else if((e.ctrlKey||e.metaKey)&&e.key.toLowerCase()==='z'){e.preventDefault();undo();}else if((e.ctrlKey||e.metaKey)&&e.key.toLowerCase()==='d'){e.preventDefault();duplicateSelected();}else if((e.ctrlKey||e.metaKey)&&e.key.toLowerCase()==='a'){e.preventDefault();state.selected=state.pads.map(function(p){return p._key;});syncInspector();render();}else if(e.key==='Delete'||e.key==='Backspace')deleteSelected();else if(e.key==='Escape'){state.dimDraft=null;state.constructDraft=null;state.marquee=null;setTool('select');}else if(e.key.toLowerCase()==='s')setTool('select');else if(e.key.toLowerCase()==='d')setTool('dim-aligned');else if(e.key.toLowerCase()==='h')setTool('dim-horizontal');else if(e.key.toLowerCase()==='v')setTool('dim-vertical');else if(e.key.toLowerCase()==='c')setTool('construction');else if(e.key.toLowerCase()==='a')addPad();else if(e.key.toLowerCase()==='f'){fitView();render();}
  });
  window.addEventListener('keyup',function(e){if(e.code==='Space')state.space=false;});
  window.addEventListener('beforeunload',function(e){if(isDirty()){e.preventDefault();e.returnValue='';}});
  window.addEventListener('resize',function(){var center={x:state.view.x+state.view.w/2,y:state.view.y+state.view.h/2},h=state.view.w*wrap.clientHeight/wrap.clientWidth;setView({x:center.x-state.view.w/2,y:center.y-h/2,w:state.view.w,h:h});render();});
  function isInput(el){return el&&(/INPUT|SELECT|TEXTAREA/.test(el.tagName));}

  function save(){
    if(!state.data||!isDirty())return;var changes=sourceChanges(),button=document.getElementById('save');button.disabled=true;button.textContent='Saving…';
    fetch('/api/footprint/'+encodeURIComponent(name),{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({revision:state.revision,changes:changes.changes,additions:changes.additions,courtyard:changes.courtyard})})
      .then(function(r){return r.text().then(function(t){if(!r.ok)throw new Error(t||'Save failed');return JSON.parse(t);});})
      .then(function(){toast('Footprint saved');return load(true);}).catch(function(err){toast(err.message,true);button.disabled=false;}).finally(function(){button.textContent='Save footprint';refreshDirty();});
  }
  function load(preserveView){
    return fetch('/api/footprint/'+encodeURIComponent(name),{cache:'no-store'}).then(function(r){if(!r.ok)throw new Error('Could not load footprint');return r.json();}).then(function(data){
      state.data=data;state.revision=data.revision||'';state.nextKey=1;state.pads=(data.pads||[]).map(function(p){return normalizePad(p,'pad-'+(state.nextKey++));});state.originals=clone(state.pads);
      state.court=initialCourt(data);state.originalCourt=clone(state.court);state.selected=[];state.history=[];state.future=[];syncInspector();if(!preserveView)fitView();render();
    }).catch(function(err){toast(err.message,true);document.getElementById('tool-hint').textContent=err.message;});
  }
  loadDimensions();loadConstructions();load(false);
})();
