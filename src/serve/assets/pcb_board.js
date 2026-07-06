(function(){
const NS="http://www.w3.org/2000/svg";
const S=PCB.scale,MX=PCB.minx,MY=PCB.miny,M=PCB.margin,G=PCB.grid;
const P=PCB.parts, orig=P.map(function(p){return {x:p.x,y:p.y,rot:p.rot||0,side:p.side||"top"};});
var RO=!!PCB.ro;
// ── Live view state (layers / grid / units) — audit 1.5 ─────────────────
// Persisted per design in localStorage alongside the existing "pcb-rigid-off:"
// key. `G` stays the footprint-editor grid constant; snap uses gridMM (0 = off).
var viewKey="pcb-view:"+PCB.name,viewSt={grid:G,units:"mm",vis:{top:1,bottom:1,silk:1,rats:1,drc:1}};
try{var _vs=JSON.parse(localStorage.getItem(viewKey)||"null");if(_vs){
 if(typeof _vs.grid==="number")viewSt.grid=_vs.grid;
 if(_vs.units)viewSt.units=_vs.units;
 if(_vs.vis)for(var _k in viewSt.vis)if(_vs.vis[_k]!==undefined)viewSt.vis[_k]=_vs.vis[_k];}}catch(e){}
function viewSave(){try{localStorage.setItem(viewKey,JSON.stringify(viewSt));}catch(e){}}
// Effective snap step (mm). grid "off" (0) → a tiny step so parts still move
// smoothly but aren't quantized.
function snapG(){return viewSt.grid>0?viewSt.grid:0.001;}
var activeLayer=0; // 0=top(F.Cu), 1=bottom(B.Cu) — draw layer for vias/free tracks
function syncActiveLayer(){var s=document.getElementById("pcb-actlayer");if(s)s.value=String(activeLayer);
 var b=document.getElementById("pcb-draw");/* drawBtnSync fills the label */ if(b&&typeof drawBtnSync==="function")drawBtnSync();}
// mm↔mil display formatting (display only — the model stays mm).
function fmtLen(mm){if(viewSt.units==="mil")return (mm/0.0254).toFixed(1)+" mil";return mm.toFixed(2)+" mm";}
function fmtLen2(mm){if(viewSt.units==="mil")return (mm/0.0254).toFixed(0)+" mil";return mm.toFixed(2)+" mm";}
// `?sub=` query for a sub-circuit page so layout save/delete/star/rescore POST
// to the per-sub sidecar (<design>.<sub>.layouts.json) instead of the design's.
// Empty on a normal design/module page.
function subq(){return (PCB.sub&&PCB.sub.length)?("?sub="+encodeURIComponent(PCB.sub)):"";}
const X=function(mm){return (mm-MX+M)*S;}, Y=function(mm){return (mm-MY+M)*S;};
const svg=document.getElementById("pcb-svg");
// ── Canvas scene + SVG interaction layer ────────────────────────────────
// Parts, pads, labels, airwires, copper and clearance render immediate-mode
// on ONE <canvas> underneath the SVG: on a big board the retained SVG DOM
// (tens of thousands of nodes) made every pan/zoom/drag style+paint slow no
// matter how little changed, while a full canvas repaint of the same scene
// is well under a frame. The transparent SVG on top keeps only what's cheap
// and genuinely benefits from DOM: pointer events (manual hit-testing below),
// decoupling-loop overlays (few, with tooltips), DRC markers (tooltips), the
// board outline, the staged-parts box, and the marquee/outline rubber bands.
const gR=document.createElementNS(NS,"g"), gD=document.createElementNS(NS,"g"), gU=document.createElementNS(NS,"g");
svg.appendChild(gR); svg.appendChild(gD); svg.appendChild(gU);
gR.style.pointerEvents="none"; gD.style.pointerEvents="none"; gU.style.pointerEvents="none";
function el(n,a){var e=document.createElementNS(NS,n);for(var k in a)e.setAttribute(k,a[k]);return e;}
const CV=document.createElement("canvas");CV.className="pcb-scene";
(function(){var par=svg.parentNode;if(!par)return;
 if(getComputedStyle(par).position==="static")par.style.position="relative";
 par.insertBefore(CV,svg);})();
// Physical outline, under everything: the layout's user-DRAWN outline when
// one exists (PCB.outline, editable via the ▭ Outline tool and saved with
// the layout), else the authored (board (size W H) …) rectangle.
var gB=document.createElementNS(NS,"g");
svg.insertBefore(gB,gR); gB.style.pointerEvents="none";
PCB.outline=(PCB.outline_drawn&&PCB.board)?{x:PCB.board.x,y:PCB.board.y,w:PCB.board.w,h:PCB.board.h,pts:(PCB.board_poly||null)}:null;
function drawBoardRect(tmp){
 while(gB.firstChild)gB.removeChild(gB.firstChild);
 if(polyPts&&polyPts.length){polySketch();return;} // ⬡ Poly in progress
 var br=tmp||PCB.outline||PCB.board;if(!br||!(br.w>0)||!(br.h>0))return;
 var drawn=!!(tmp||PCB.outline);
 // Exact polygon outline (drawn ⬡ Poly pts, or the authored corner-radius
 // shape the server sends as PCB.board_poly); rectangles keep the rect path.
 var pts=tmp?null:(PCB.outline?(PCB.outline.pts||null):(PCB.board_poly||null));
 if(pts&&pts.length>=3){
  var str=pts.map(function(p){return X(p[0]).toFixed(1)+","+Y(p[1]).toFixed(1);}).join(" ");
  gB.appendChild(el("polygon",{points:str,fill:"none",stroke:"#7ee787","stroke-width":1.6,opacity:0.85}));
  // A drawn polygon's vertices stay editable: square handles, dragged in the
  // pointer handlers (gB is pointer-events:none; hits are coordinate-tested).
  if(drawn&&!RO)pts.forEach(function(p){gB.appendChild(el("rect",{
    x:(X(p[0])-3.5).toFixed(1),y:(Y(p[1])-3.5).toFixed(1),width:7,height:7,
    fill:"#0d1117",stroke:"#7ee787","stroke-width":1.2,opacity:0.9}));});
 }else{
  gB.appendChild(el("rect",{x:X(br.x).toFixed(1),y:Y(br.y).toFixed(1),width:(br.w*S).toFixed(1),
    height:(br.h*S).toFixed(1),fill:"none",stroke:"#7ee787","stroke-width":1.6,opacity:0.85,
    "stroke-dasharray":tmp?"6 4":"0"}));
 }
 var bt=el("text",{x:(X(br.x)+6).toFixed(1),y:(Y(br.y)+14).toFixed(1),fill:"#7ee787","font-size":"11",opacity:0.85});
 bt.textContent=fmtLen2(br.w)+"×"+fmtLen2(br.h)+(drawn?" (drawn)":""); gB.appendChild(bt);
}
// The in-progress ⬡ Poly sketch: placed vertices as a dashed open path, a
// rubber segment to the cursor, and a ring marking the first vertex (the
// click-to-close target).
function polySketch(){
 var str=polyPts.map(function(p){return X(p[0]).toFixed(1)+","+Y(p[1]).toFixed(1);}).join(" ");
 gB.appendChild(el("polyline",{points:str,fill:"none",stroke:"#7ee787","stroke-width":1.6,
   opacity:0.85,"stroke-dasharray":"6 4"}));
 if(polyCur){var lp=polyPts[polyPts.length-1];
  gB.appendChild(el("line",{x1:X(lp[0]).toFixed(1),y1:Y(lp[1]).toFixed(1),
    x2:X(polyCur.x).toFixed(1),y2:Y(polyCur.y).toFixed(1),
    stroke:"#7ee787","stroke-width":1,opacity:0.6,"stroke-dasharray":"3 3"}));}
 var f=polyPts[0];
 gB.appendChild(el("circle",{cx:X(f[0]).toFixed(1),cy:Y(f[1]).toFixed(1),r:6,fill:"none",
   stroke:"#7ee787","stroke-width":1.4,opacity:0.9}));
 polyPts.forEach(function(p){gB.appendChild(el("rect",{
   x:(X(p[0])-3).toFixed(1),y:(Y(p[1])-3).toFixed(1),width:6,height:6,
   fill:"#7ee787",opacity:0.9}));});
}
drawBoardRect();
function wpt(i,lx,ly){var p=P[i],a=(p.rot||0)*Math.PI/180,c=Math.cos(a),s=Math.sin(a);
 if(p.side==="bottom")lx=-lx; // bottom parts mirror about their own axis (matches worldPt)
 return {x:p.x+lx*c-ly*s,y:p.y+lx*s+ly*c};}
function moved(i){return P[i].x!==orig[i].x||P[i].y!==orig[i].y||(P[i].rot||0)!==orig[i].rot||(P[i].side||"top")!==orig[i].side;}
function wrect(i,pad){var p=P[i],c=wpt(i,pad.x,pad.y),q=(((p.rot||0)%360)+360)%360;
 var hw=(q==90||q==270)?pad.h/2:pad.w/2, hh=(q==90||q==270)?pad.w/2:pad.h/2;
 return {x0:c.x-hw,y0:c.y-hh,x1:c.x+hw,y1:c.y+hh};}
// setT once wrote SVG transforms; parts are canvas-painted now, so every
// legacy call site simply schedules a repaint (the scene reads P[] fresh).
function setT(i){paintSoon();}
// Defined decoupling pads: each loop pins a cap to ONE hub pad (L.pp =
// hub_pwr_pin). Mark those hub pads so a net selection glows them red (the
// authored decoupling target) rather than gold. Keyed hubIndex:padX:padY.
var loopPin={};(PCB.loops||[]).forEach(function(L){if(L.pp)loopPin[L.hub+":"+L.pp.x.toFixed(2)+":"+L.pp.y.toFixed(2)]=1;});
// ── Scene paint state + hit-testing ─────────────────────────────────────
// What the old per-element class toggles carried is now plain state the
// painter reads: hover part / rigid-group glow / selection / net glow /
// heat / staging — one repaint applies all of it.
var cur=-1,hoverGrpName=null,hoverNet=null,flashIdx=-1,flashUntil=0;
// Part hit-test: courtyard box in part-local coords (un-rotate, un-mirror).
// Smallest hit wins so a cap sitting on a hub grabs before the hub.
function partAt(wx,wy){var best=-1,ba=1e18;
 for(var i=0;i<P.length;i++){var p=P[i];
  var a=-(p.rot||0)*Math.PI/180,c=Math.cos(a),sn=Math.sin(a);
  var lx=wx-p.x,ly=wy-p.y,rx=lx*c-ly*sn,ry=lx*sn+ly*c;
  if(p.side==="bottom")rx=-rx;
  if(Math.abs(rx-(p.ccx||0))<=p.hw&&Math.abs(ry-(p.ccy||0))<=p.hh){var ar=p.hw*p.hh;if(ar<ba){ba=ar;best=i;}}}
 return best;}
function padAt(i,wx,wy){var p=P[i],a=-(p.rot||0)*Math.PI/180,c=Math.cos(a),sn=Math.sin(a);
 var lx=wx-p.x,ly=wy-p.y,rx=lx*c-ly*sn,ry=lx*sn+ly*c;
 if(p.side==="bottom")rx=-rx;
 var best=null;(p.pads||[]).forEach(function(pd){
  if(Math.abs(rx-pd.x)<=pd.w/2&&Math.abs(ry-pd.y)<=pd.h/2)best=pd;});
 return best;}
// rAF-coalesced full scene repaint — the ONE redraw path for everything.
var paintQueued=false;
function paintSoon(){if(paintQueued)return;paintQueued=true;
 (window.requestAnimationFrame||setTimeout)(scenePaint);}
function scenePaint(){paintQueued=false;
 var r=svg.getBoundingClientRect();if(!r.width)return;
 var dpr=window.devicePixelRatio||1,w=Math.round(r.width*dpr),h=Math.round(r.height*dpr);
 if(CV.width!==w||CV.height!==h){CV.width=w;CV.height=h;
  CV.style.width=r.width+"px";CV.style.height=r.height+"px";}
 CV.style.left=svg.offsetLeft+"px";CV.style.top=svg.offsetTop+"px";
 var ctx=CV.getContext("2d");
 ctx.setTransform(1,0,0,1,0,0);
 ctx.fillStyle="#010409";ctx.fillRect(0,0,w,h);
 var k=(r.width/vb.w);            // CSS px per svg-unit (label gating)
 var kk=k*dpr;
 ctx.setTransform(kk,0,0,kk,-vb.x*kk,-vb.y*kk);   // draw in svg-unit coords
 paintPours(ctx,k);
 paintGroupBoxes(ctx,k);
 paintParts(ctx,k);
 paintLinks(ctx);
 paintClr(ctx);
 paintTracks(ctx);
 paintDraw(ctx);
 if(flashIdx>=0&&Date.now()<flashUntil){var fp=P[flashIdx];
  var fc=wpt(flashIdx,fp.ccx||0,fp.ccy||0);
  ctx.strokeStyle="#f0b72f";ctx.lineWidth=2.6;
  ctx.globalAlpha=0.4+0.6*Math.abs(Math.sin(Date.now()/180));
  ctx.strokeRect(X(fc.x)-fp.hw*S,Y(fc.y)-fp.hh*S,2*fp.hw*S,2*fp.hh*S);
  ctx.globalAlpha=1;setTimeout(paintSoon,60);}
 else if(flashIdx>=0){flashIdx=-1;}}
function partStroke(i,p){
 if(i===cur&&!RO)return {c:"#58a6ff",w:2};
 if(selRef&&p.ref===selRef)return {c:"#58a6ff",w:2.4};
 if(sel&&sel.indexOf&&sel.indexOf(i)>=0)return {c:"#d2a8ff",w:2};
 if(hoverGrpName&&grpOf(p.ref)===hoverGrpName)return {c:"#7ee787",w:2};
 return {c:p.kind=="hub"?"#58a6ff":"#8b949e",w:1.3};}
function paintParts(ctx,k){
 var labels=k>=1.15;      // pad numbers are sub-pixel noise below this
 for(var i=0;i<P.length;i++){var p=P[i];
  var bot=(p.side==="bottom"),unp=!!unplacedSet[p.ref];
  ctx.save();
  ctx.translate(X(p.x),Y(p.y));ctx.rotate((p.rot||0)*Math.PI/180);
  if(bot)ctx.scale(-1,1);
  // courtyard (box centre can be offset from the part origin — asymmetric
  // library rects; the local frame already carries rotation + mirror)
  var hw=p.hw*S,hh=p.hh*S,ccx=(p.ccx||0)*S,ccy=(p.ccy||0)*S;
  ctx.fillStyle=(heatOn&&p.ref!==anchorRef)?blameColor(heatScale>0?(p.blame||0)/heatScale:0)
    :(bot?"#122036":"#161b22");
  if(unp)ctx.fillStyle="rgba(248,81,73,.12)";
  ctx.fillRect(ccx-hw,ccy-hh,2*hw,2*hh);
  var st=partStroke(i,p);
  ctx.strokeStyle=unp?"#f85149":st.c;ctx.lineWidth=unp?1.6:st.w;
  if(unp)ctx.setLineDash([4,3]);
  else if(p.locked)ctx.setLineDash([2,2]);
  else if(p.fb)ctx.setLineDash([4,3]);
  else ctx.setLineDash([]);
  ctx.strokeRect(ccx-hw,ccy-hh,2*hw,2*hh);
  ctx.setLineDash([]);
  if(unp){ctx.strokeStyle="#f85149";ctx.lineWidth=1;
   ctx.beginPath();ctx.moveTo(ccx-hw,ccy-hh);ctx.lineTo(ccx+hw,ccy+hh);
   ctx.moveTo(ccx+hw,ccy-hh);ctx.lineTo(ccx-hw,ccy+hh);ctx.globalAlpha=0.8;ctx.stroke();ctx.globalAlpha=1;}
  // silk
  if(p.silk&&viewSt.vis.silk){ctx.strokeStyle="#8b949e";ctx.lineWidth=0.8;ctx.lineCap="round";
   ctx.beginPath();
   p.silk.l.forEach(function(sl){ctx.moveTo(sl[0]*S,sl[1]*S);ctx.lineTo(sl[2]*S,sl[3]*S);});
   ctx.stroke();
   p.silk.c.forEach(function(sc){ctx.beginPath();
    ctx.arc(sc[0]*S,sc[1]*S,Math.max(sc[2]*S,1),0,6.2832);ctx.stroke();});
   ctx.lineCap="butt";}
  // pads (in the same part frame)
  (p.pads||[]).forEach(function(pd){
   var fill=bot?"#5b8dd6":(netColOn?(pd.net?(netColorOf(pd.net)||"#b08d57"):"#ffffff"):"#b08d57");
   if(hoverNet&&pd.net===hoverNet)fill="#f85149";
   ctx.fillStyle=fill;
   padPath(ctx,pd);ctx.fill();
   // Drilled bore: board-coloured hole through thru/npth pads.
   if(pd.drill>0){ctx.fillStyle="#0d1117";ctx.beginPath();
    ctx.arc(pd.x*S,pd.y*S,Math.max(pd.drill/2*S,0.6),0,6.2832);ctx.fill();}
   if(selNetCur&&pd.net===selNetCur){
    var pin=!!loopPin[i+":"+pd.x.toFixed(2)+":"+pd.y.toFixed(2)];
    ctx.strokeStyle=pin?"#f85149":"#ffd33d";ctx.lineWidth=1.8;
    padPath(ctx,pd);ctx.stroke();}});
  ctx.restore();
  // upright labels (outside the rotated/mirrored frame)
  if(labels&&(p.pads||[]).length){ctx.fillStyle="#0d1117";
   ctx.textAlign="center";ctx.textBaseline="middle";
   p.pads.forEach(function(pd){if(!pd.num)return;
    var fs=Math.min(pd.w,pd.h)*S*0.55;if(fs*k<5.5)return;
    var c=wpt(i,pd.x,pd.y);
    ctx.font="600 "+fs.toFixed(1)+"px system-ui,sans-serif";
    ctx.fillText(pd.num,X(c.x),Y(c.y));});}
  // Ref labels only where they carry signal — the hovered part, the selected/
  // cross-probed part, and red-flagged staged parts. Sub-circuits are named by
  // their group box (paintGroupBoxes) instead of a per-part refdes cloud.
  if(i===cur||unp||(selRef&&p.ref===selRef)){
   ctx.font="600 9px system-ui,sans-serif";
   ctx.textAlign="center";ctx.textBaseline="alphabetic";
   ctx.fillStyle=unp?"#f85149":(p.kind=="hub"?"#58a6ff":"#8b949e");
   var lc=wpt(i,p.ccx||0,p.ccy||0);
   ctx.fillText(p.ref,X(lc.x),Y(lc.y)-p.hh*S-2);}}}
function padPath(ctx,pd){
 ctx.beginPath();
 if(pd.poly&&pd.poly.length>=3){
  ctx.moveTo(pd.poly[0][0]*S,pd.poly[0][1]*S);
  for(var j=1;j<pd.poly.length;j++)ctx.lineTo(pd.poly[j][0]*S,pd.poly[j][1]*S);
  ctx.closePath();return;}
 if(pd.shape==="circle"){ctx.arc(pd.x*S,pd.y*S,Math.min(pd.w,pd.h)/2*S,0,6.2832);return;}
 ctx.rect((pd.x-pd.w/2)*S,(pd.y-pd.h/2)*S,pd.w*S,pd.h*S);}
// Sub-circuit boxes: each ref-prefix group ("buck/…") draws as ONE named
// bounding box, so the board reads as sub-circuits rather than a refdes
// cloud. Solid while rigid (drags as a unit), dashed when exploded; the name
// label above the box stays a constant screen size across zoom. Staged
// (unplaced) members are excluded so the box doesn't stretch to the band.
// Declared outer-layer copper pours ((stackup …)/(pour …) on an outer face,
// PCB.pours from the server): a translucent wash + dashed rim + "NET pour ·
// F.Cu/B.Cu" label UNDER everything, in the layer's track colour (red top /
// blue bottom) — so a poured face reads as copper instead of being invisible.
function paintPours(ctx,k){
 var ik=1/Math.max(k||1,0.01),n=0;
 (PCB.pours||[]).forEach(function(q){
  if(!(q.w>0&&q.h>0))return;
  var top=(q.side==="top");
  ctx.fillStyle=top?"rgba(248,81,73,0.10)":"rgba(56,139,253,0.12)";
  ctx.fillRect(X(q.x),Y(q.y),q.w*S,q.h*S);
  ctx.strokeStyle=top?"rgba(248,81,73,0.45)":"rgba(56,139,253,0.5)";
  ctx.lineWidth=1;ctx.setLineDash([5,4]);
  ctx.strokeRect(X(q.x),Y(q.y),q.w*S,q.h*S);
  ctx.setLineDash([]);
  ctx.font="600 "+(11*ik).toFixed(2)+"px system-ui,sans-serif";
  ctx.textAlign="left";ctx.textBaseline="alphabetic";
  ctx.fillStyle=top?"rgba(248,81,73,0.9)":"rgba(56,139,253,0.9)";
  ctx.fillText(q.net+" pour · "+(top?"F.Cu":"B.Cu"),X(q.x)+5*ik,Y(q.y+q.h)-(5+n*14)*ik);
  n++;});}
function paintGroupBoxes(ctx,k){
 var ik=1/Math.max(k,0.01);
 for(var g in GRPS){var idxs=GRPS[g];if(idxs.length<2)continue;
  var x0=1/0,y0=1/0,x1=-1/0,y1=-1/0,n=0;
  idxs.forEach(function(i){var p=P[i];if(unplacedSet[p.ref])return;
   var a=(p.rot||0)*Math.PI/180,ca=Math.abs(Math.cos(a)),sa=Math.abs(Math.sin(a));
   var ehw=(p.hw*ca+p.hh*sa)*S,ehh=(p.hw*sa+p.hh*ca)*S;
   var cc=wpt(i,p.ccx||0,p.ccy||0);
   x0=Math.min(x0,X(cc.x)-ehw);x1=Math.max(x1,X(cc.x)+ehw);
   y0=Math.min(y0,Y(cc.y)-ehh);y1=Math.max(y1,Y(cc.y)+ehh);n++;});
  if(!n)continue;
  var pd=3;x0-=pd;y0-=pd;x1+=pd;y1+=pd;
  var hov=(hoverGrpName===g);
  ctx.strokeStyle=hov?"#7ee787":"rgba(126,231,135,0.4)";
  ctx.lineWidth=hov?1.6:1;
  ctx.setLineDash(grpRigid(g)?[]:[5,4]);
  ctx.strokeRect(x0,y0,x1-x0,y1-y0);
  ctx.setLineDash([]);
  ctx.font="600 "+(11*ik).toFixed(2)+"px system-ui,sans-serif";
  ctx.textAlign="left";ctx.textBaseline="alphabetic";
  ctx.fillStyle=hov?"#7ee787":"rgba(126,231,135,0.8)";
  ctx.fillText(g,x0,y0-4*ik);}}
// ── Unplaced (auto-staged) parts: the ones a (placement …) spec didn't list.
//    The optimizer drops them into a staging band; flag each one red and draw
//    a dashed red box around the cluster so a gap in the spec is obvious.
var unplacedSet={};
function markUnplaced(refs){
 unplacedSet={};(refs||[]).forEach(function(r){unplacedSet[r]=1;});
 refreshUnplaced();paintSoon();}
function refreshUnplaced(){
 // Nothing staged and nothing drawn — the common case — costs nothing.
 var have=false;for(var k in unplacedSet){have=true;break;}
 if(!have&&!gU.firstChild)return;
 while(gU.firstChild)gU.removeChild(gU.firstChild);
 var n=0,x0=1e9,y0=1e9,x1=-1e9,y1=-1e9;
 P.forEach(function(p,i){if(!unplacedSet[p.ref])return;n++;
  var q=(((p.rot||0)%360)+360)%360,sw=(q==90||q==270)?p.hh:p.hw,sh=(q==90||q==270)?p.hw:p.hh;
  var cx=X(p.x),cy=Y(p.y),hw=sw*S,hh=sh*S;
  if(cx-hw<x0)x0=cx-hw;if(cy-hh<y0)y0=cy-hh;if(cx+hw>x1)x1=cx+hw;if(cy+hh>y1)y1=cy+hh;});
 if(n===0)return;
 var pad=10;x0-=pad;y0-=pad;x1+=pad;y1+=pad;
 gU.appendChild(el("rect",{"class":"unplaced-box",x:x0.toFixed(1),y:y0.toFixed(1),
  width:(x1-x0).toFixed(1),height:(y1-y0).toFixed(1),rx:4}));
 var ly=(y0-5<12)?(y0+15):(y0-5);
 var lbl=el("text",{"class":"unplaced-lbl",x:(x0+6).toFixed(1),y:ly.toFixed(1)});
 lbl.textContent="⚠ "+n+" part"+(n==1?"":"s")+" not in placement spec";
 gU.appendChild(lbl);}
// ── Canvas overlay: the non-interactive bulk leaves the DOM ─────────────
// Airwires, routed copper, and clearance halos are pointer-events:none
// visuals; as retained SVG they were thousands of nodes that made every
// browser paint slow on a big board, no matter how little actually changed.
// They now render on ONE 2D canvas stacked over the SVG (KiCad-style —
// ratsnest/copper draw above the parts); repainting a few thousand canvas
// lines costs well under a frame, so drag/pan/zoom simply repaint it.
// Decoupling-loop overlays stay SVG (few of them, and they carry tooltips).
// (The former separate overlay canvas is merged into the scene canvas —
// paintLinks/paintClr/paintTracks below are called by scenePaint in order.)
function ovPaintSoon(){paintSoon();}
function paintLinks(ctx){if(!ratsOn||!viewSt.vis.rats)return;
 (PCB.links||[]).forEach(function(l){
  var a=wpt(l.a,l.ax,l.ay),b=wpt(l.b,l.bx,l.by);
  ctx.strokeStyle=linkCol(l);
  ctx.globalAlpha=(l.k=="signal")?0.55:0.9;
  ctx.lineWidth=(l.k=="signal")?0.7:1.3;
  ctx.beginPath();ctx.moveTo(X(a.x),Y(a.y));ctx.lineTo(X(b.x),Y(b.y));ctx.stroke();});
 ctx.globalAlpha=1;}
// Per-layer copper visibility + a dim of the INACTIVE copper layer while
// drawing, so the active layer reads clearly (audit 1.5). A layer hidden in
// the Layers panel isn't drawn at all.
function layerAlpha(layer){if(layer===0&&!viewSt.vis.top)return 0;if(layer===1&&!viewSt.vis.bottom)return 0;
 if(drawMode&&layer!==activeLayer)return 0.30;return 0.85;}
function paintTracks(ctx){
 ctx.lineCap="round";
 (PCB.tracks||[]).forEach(function(t){var a=layerAlpha(t.l||0);if(a<=0)return;ctx.globalAlpha=a;
  ctx.strokeStyle=(t.l==0)?"#f85149":"#388bfd";
  ctx.lineWidth=Math.max(t.w*S,1.2);
  ctx.beginPath();ctx.moveTo(X(t.x1),Y(t.y1));ctx.lineTo(X(t.x2),Y(t.y2));ctx.stroke();});
 ctx.globalAlpha=1;ctx.lineCap="butt";
 // Vias span both layers — hide only when BOTH copper layers are hidden.
 if(!viewSt.vis.top&&!viewSt.vis.bottom)return;
 (PCB.vias||[]).forEach(function(v){
  var rr=Math.max(v.d/2*S,2.5),dr=(v.drill>0)?v.drill:viaGeo().drill;
  var rh=Math.min(Math.max(dr/2*S,1),rr*0.7);
  ctx.fillStyle="#ca8a04";ctx.beginPath();ctx.arc(X(v.x),Y(v.y),rr,0,6.2832);ctx.fill();
  ctx.fillStyle="#fff";ctx.beginPath();ctx.arc(X(v.x),Y(v.y),rh,0,6.2832);ctx.fill();});}
function paintClr(ctx){
 var cb=document.getElementById("r-clr-show");if(!cb||!cb.checked)return;
 var clr=clrVal();
 ctx.strokeStyle="#d29922";ctx.lineWidth=0.8;ctx.fillStyle="rgba(210,153,34,0.13)";
 ctx.setLineDash([3,2]);
 P.forEach(function(p,i){p.pads.forEach(function(pad){var r=wrect(i,pad);
  ctx.beginPath();ctx.rect(X(r.x0-clr),Y(r.y0-clr),(r.x1-r.x0+2*clr)*S,(r.y1-r.y0+2*clr)*S);
  ctx.fill();ctx.stroke();});});
 (PCB.vias||[]).forEach(function(v){
  ctx.beginPath();ctx.arc(X(v.x),Y(v.y),(v.d/2+clr)*S,0,6.2832);ctx.fill();ctx.stroke();});
 ctx.setLineDash([]);ctx.globalAlpha=0.20;ctx.lineCap="round";
 (PCB.tracks||[]).forEach(function(t){
  ctx.lineWidth=(t.w+2*clr)*S;
  ctx.beginPath();ctx.moveTo(X(t.x1),Y(t.y1));ctx.lineTo(X(t.x2),Y(t.y2));ctx.stroke();});
 ctx.globalAlpha=1;ctx.lineCap="butt";}
window.addEventListener("resize",paintSoon);

// ── Ratsnest: airwires on the canvas; loop overlays stay SVG ────────────
var gRP=document.createElementNS(NS,"g");
gR.appendChild(gRP);
var loopGs=[],partLoops={};
(PCB.loops||[]).forEach(function(L,k){(partLoops[L.hub]=partLoops[L.hub]||[]).push(k);
 (partLoops[L.cap]=partLoops[L.cap]||[]).push(k);});
function linkCol(l){var col=l.k=="proximity"?"#ea580c":(l.k=="ground"?"#22b8cf":"#9aa7b4");
 if(netColOn){var nc=netColorOf(l.net);if(nc)col=nc;}return col;}
// Redraw ONE loop overlay group. Uses the server's DRC-safe GND-via drop
// (cgv/gpv) only while the cap/hub is at its emitted pose; once dragged that
// world point is stale (and cgv/gpv come back null when the router can't fan
// a via there at all), so draw the return *path* to the raw pad centre but
// DON'T invent a via dot — Route re-derives the exact DRC-safe fan.
function drawLoop(k){var L=PCB.loops[k],g=loopGs[k];if(!L||!g)return;
 while(g.firstChild)g.removeChild(g.firstChild);
 var routedNow=((PCB.tracks||[]).length>0);
 var cReal=(L.cgv&&!moved(L.cap)), dReal=(L.gpv&&!moved(L.hub));
 var A=wpt(L.hub,L.pp.x,L.pp.y), B=wpt(L.cap,L.cp.x,L.cp.y),
     C=cReal?L.cgv:wpt(L.cap,L.cg.x,L.cg.y),
     D=dReal?L.gpv:wpt(L.hub,L.gp.x,L.gp.y);
 g.appendChild(el("line",{x1:X(B.x).toFixed(1),y1:Y(B.y).toFixed(1),
  x2:X(A.x).toFixed(1),y2:Y(A.y).toFixed(1),stroke:"#ea580c","stroke-width":1.3,opacity:0.95}));
 var rp=[C,B,A,D].map(function(q){return X(q.x).toFixed(1)+","+Y(q.y).toFixed(1);}).join(" ");
 var pl=el("polyline",{points:rp,fill:"none",stroke:"#58a6ff","stroke-width":1.3,opacity:0.85,"stroke-dasharray":"4 2"});
 var gt=el("title",{}); gt.textContent="GND return images under the power trace on the L2 plane (drops at the DRC-safe GND vias)"; pl.appendChild(gt);
 g.appendChild(pl);
 if(!routedNow){ if(cReal)drawVia(g,C.x,C.y,viaGeo().dia,viaGeo().drill);
                 if(dReal)drawVia(g,D.x,D.y,viaGeo().dia,viaGeo().drill); }}
function rats(){
 while(gRP.firstChild)gRP.removeChild(gRP.firstChild);
 loopGs=[];
 ovPaintSoon();   // airwires live on the canvas overlay
 if(!ratsOn)return;
 (PCB.loops||[]).forEach(function(L,k){var g=document.createElementNS(NS,"g");
   gRP.appendChild(g);loopGs.push(g);drawLoop(k);});
}
// Update only the airwires + loop overlays touching the given part indices —
// the per-pointermove path. O(links-on-moved-parts), not O(board).
function ratsUpdate(idxs){
 if(!ratsOn)return;
 ovPaintSoon();   // airwires: one cheap full canvas repaint per frame
 var seenK={};
 idxs.forEach(function(i){
  (partLoops[i]||[]).forEach(function(k){if(seenK[k])return;seenK[k]=1;drawLoop(k);});});
}
function delta(id,cur,base){
 var e=document.getElementById(id);if(!e)return;var d=cur-base;
 // Blank (not "=") when unchanged so the score bar isn't a row of "=" on load.
 if(Math.abs(d)<0.05){e.textContent="";e.className="delta";}
 else{e.textContent=(d>0?"+":"")+d.toFixed(1);e.className="delta "+(d>0?"up":"down");}
}
function setSc(id,t){var e=document.getElementById(id);if(e)e.textContent=t;}
// Score view: recompute the headline from the breakdown's raw terms × the
// per-metric display weights/toggles, so re-weighing is instant and never
// re-places parts. Defaults equal the engine weights ⇒ matches the server.
var lastBreak=null;
function svGet(){
 function n(id,d){var e=document.getElementById(id);if(!e)return d;var v=parseFloat(e.value);return isFinite(v)?v:d;}
 function on(id){var e=document.getElementById(id);return e?e.checked:true;}
 return {wire:{on:on("sv-en-wire"),w:n("sv-w-wire",1)},loop:{on:on("sv-en-loop"),w:n("sv-w-loop",6)},
  align:{on:on("sv-en-align"),w:n("sv-w-align",0.5)},cong:{on:on("sv-en-cong"),w:n("sv-w-cong",2)}};
}
function svTerms(b){var s=svGet();
 var wire=s.wire.on?s.wire.w*(b.hpwl||0):0,loop=s.loop.on?s.loop.w*(b.loop_nh_weighted||0):0;
 var align=s.align.on?s.align.w*(b.alignment||0):0,cong=s.cong.on?s.cong.w*(b.congestion||0):0;
 return {wire:wire,loop:loop,align:align,cong:cong,obj:wire+loop+align+cong,s:s};
}
function svOff(id,off){var e=document.getElementById(id);if(e)e.classList.toggle("sc-off",off);}
function showScore(b){lastBreak=b;
 var t=svTerms(b),a=svTerms(PCB.auto);
 setSc("sc-obj","objective "+t.obj.toFixed(1));
 setSc("sc-hpwl","wire "+(b.hpwl||0).toFixed(1));
 setSc("sc-loop","loop "+t.loop.toFixed(1)+" · "+PCB.caps+" cap");
 setSc("sc-ind","loop "+(b.loop_nh||0).toFixed(2)+" nH");
 setSc("sc-align","area "+((b.footprint!=null?b.footprint:b.alignment)||0).toFixed(1)+" mm²");
 setSc("sc-cong","cong "+t.cong.toFixed(1));
 delta("sc-obj-d",t.obj,a.obj);
 delta("sc-hpwl-d",b.hpwl||0,PCB.auto.hpwl||0);
 delta("sc-loop-d",t.loop,a.loop);
 delta("sc-ind-d",b.loop_nh||0,PCB.auto.loop_nh||0);
 delta("sc-align-d",(b.footprint!=null?b.footprint:b.alignment)||0,(PCB.auto.footprint!=null?PCB.auto.footprint:PCB.auto.alignment)||0);
 delta("sc-cong-d",t.cong,a.cong);
 svOff("sc-hpwl",!t.s.wire.on);svOff("sc-hpwl-d",!t.s.wire.on);
 svOff("sc-loop",!t.s.loop.on);svOff("sc-loop-d",!t.s.loop.on);
 svOff("sc-ind",!t.s.loop.on);svOff("sc-ind-d",!t.s.loop.on);
 svOff("sc-align",!t.s.align.on);svOff("sc-align-d",!t.s.align.on);
 svOff("sc-cong",!t.s.cong.on);svOff("sc-cong-d",!t.s.cong.on);
}
// Each saved layout's raw breakdown (fetched once via pcb-score-batch), so
// the panel re-weighs under the Score-view weights with no per-row round-trip.
var layBreaks={};
function svApply(){if(lastBreak)showScore(lastBreak);reweighLayouts();}
function reweighLayouts(){var aobj=svTerms(PCB.auto).obj;
 document.querySelectorAll(".lay-row").forEach(function(row){
  var nm=row.getAttribute("data-lay-row"),b=layBreaks[nm];if(!b)return;var t=svTerms(b);
  var sc=row.querySelector(".lay-score");
  if(sc)sc.textContent="obj "+t.obj.toFixed(1)+" · loop "+(b.loop_raw||0).toFixed(1)+
   " · area "+((b.footprint!=null?b.footprint:b.alignment)||0).toFixed(0)+" mm²";
  var dd=row.querySelector(".lay-d");if(!dd)return;var d=t.obj-aobj;
  if(Math.abs(d)<0.05){dd.textContent="=";dd.className="lay-d";}
  else{dd.textContent=(d>0?"+":"")+d.toFixed(1);dd.className="lay-d "+(d>0?"up":"down");}});
}
var scoreReq=0;
function fetchScore(){
 // Keep the current number on screen until the new one arrives — blanking to
 // "…" resized the chip and made the toolbar (and the board below it) jump
 // on every drag/rotate/change.
 var seq=++scoreReq;
 // Ask for per-part blame only while the Heatmap view is on, so a finished
 // drag/rotate re-tints the board to the new cost distribution.
 var payload={parts:P.map(function(p){return {ref:p.ref,x:p.x,y:p.y,rot:p.rot||0,side:p.side||"top"};}),blame:heatOn};
 fetch("/api/pcb-score/"+encodeURIComponent(PCB.name),{method:"POST",
   headers:{"Content-Type":"application/json"},body:JSON.stringify(payload)})
  .then(function(r){return r.json();})
  .then(function(b){if(seq!==scoreReq)return;
   if(b.blame){P.forEach(function(p){var v=b.blame[p.ref];if(v!==undefined)p.blame=v;});if(heatOn)applyHeat();}
   showScore(b);})
  .catch(function(){if(seq===scoreReq)setSc("sc-obj","objective —");});
}
function mm(ev){var r=svg.getBoundingClientRect(),vb=svg.viewBox.baseVal;
 var sx=vb.x+(ev.clientX-r.left)*(vb.width/r.width);
 var sy=vb.y+(ev.clientY-r.top)*(vb.height/r.height);
 return {x:sx/S+MX-M,y:sy/S+MY-M};}
// ── KiCad-style properties panel ──────────────────────────────────────
// The sidebar shows ONE part at a time: clicking a part on the board fills it
// from PCB.parts (live x/y/rot), clicking empty board clears it back to the
// hint. No scrolling list. renderProps rebuilds the panel; updatePropLive is
// the cheap position/rotation refresh during a drag or rotate.
var selRef=null;
function pEsc(s){return String(s==null?"":s).replace(/[&<>"]/g,function(c){
 return c=="&"?"&amp;":(c=="<"?"&lt;":(c==">"?"&gt;":"&quot;"));});}
function pMm(v){return (Math.round(v*100)/100).toFixed(2);}
function nLeaf(s){var i=String(s).lastIndexOf("/");return i<0?s:s.slice(i+1);}
function pRow(k,v,id){return '<div class="prop-row"><span class="k">'+k+'</span><span class="v"'+
 (id?(' id="'+id+'"'):'')+'>'+pEsc(v)+'</span></div>';}
function renderProps(){var body=document.getElementById("prop-body");if(!body)return;
 var p=selRef?partByRef(selRef):null;
 if(!p){body.innerHTML='<div class="prop-empty">Click a part on the board to see its properties.'+
  '<br><span class="prop-empty-n">'+P.length+' components</span></div>';return;}
 var rot=(((p.rot||0)%360)+360)%360;
 var h='<div class="prop-head"><span class="prop-ref">'+pEsc(p.ref)+'</span>'+
  (p.val?'<span class="prop-val">'+pEsc(p.val)+'</span>':'')+'</div>';
 h+='<div class="prop-rows">'+pRow("X",fmtLen(p.x),"prop-x")+pRow("Y",fmtLen(p.y),"prop-y")+
  pRow("Rotation",rot+"°","prop-rot")+pRow("Side",(p.side==="bottom")?"Bottom (B.Cu)":"Top (F.Cu)","prop-side")+
  pRow("Type",(p.kind=="hub"?"Hub / IC":"Passive")+(p.locked?" · 🔒 locked":""))+'</div>';
 if(p.fp)h+='<button class="prop-fp" data-court-ref="'+pEsc(p.ref)+'" title="Edit footprint courtyard">▢ '+pEsc(p.fp)+'</button>';
 // Sub-circuit row: the part's group, and — when the module has a stampable
 // saved layout — the same Stamp the palette offers, so "pull the module's
 // layout" is reachable from the part itself.
 var pg=grpOf(p.ref);
 if(pg&&GRPS[pg]&&GRPS[pg].length>1){
  var pinf=(PCB.subseedinfo||{})[pg];
  var pmod=(PCB.submodules||{})[pg];
  var pname=pmod?'<a class="grp-name" href="/pcb-layout/'+encodeURIComponent(pmod)+'" target="_blank" rel="noopener" title="Open module ‘'+pEsc(pmod)+'’ on its own PCB-layout page.">'+pEsc(pg)+'</a>'
   :'<span class="grp-name">'+pEsc(pg)+'</span>';
  h+='<div class="prop-sec">Sub-circuit</div><div class="prop-grp">'+pname+
   '<span class="grp-n">'+GRPS[pg].length+' parts</span>'+
   (pinf&&!RO?'<button class="btn grp-stamp" data-grp-stamp="'+pEsc(pg)+'" title="'+stampTitle(pg,pinf)+'">Stamp module layout</button>':
    (pinf?'':'<span class="grp-noseed" title="No saved layout on the module matches its current parts — open the module’s own /pcb-layout page, lay it out and save (★ star it to pin the choice).">no saved module layout</span>'))+
   '</div>';
 }
 var pads=(p.pads||[]).slice().sort(function(a,b){var an=parseInt(a.num,10),bn=parseInt(b.num,10);
  if(!isNaN(an)&&!isNaN(bn))return an-bn;return String(a.num||"").localeCompare(String(b.num||""));});
 var pins="";pads.forEach(function(pd){if(!pd.num&&!pd.net)return;
  pins+='<span class="pn" data-net="'+pEsc(pd.net||"")+'"><b>'+pEsc(pd.num||"")+'</b>'+pEsc(nLeaf(pd.net||""))+'</span>';});
 if(pins)h+='<div class="prop-sec">Pins → nets</div><div class="prop-pins">'+pins+'</div>';
 var sb=body.getAttribute("data-schbase")||"/schematics/";
 h+='<a class="prop-sch" href="'+sb+encodeURIComponent(PCB.name)+'#comp-'+encodeURIComponent(p.ref)+'" '+
  'title="Open the schematic page scrolled to this part">Show in schematic →</a>';
 body.innerHTML=h;netIdxDrop();
 var cb=body.querySelector("[data-court-ref]");
 if(cb)cb.addEventListener("click",function(){openCourt(cb.getAttribute("data-court-ref"));});
 var gsb=body.querySelector("[data-grp-stamp]");
 if(gsb)gsb.addEventListener("click",function(){if(stampGroupFn)stampGroupFn(gsb.getAttribute("data-grp-stamp"));});
 body.querySelectorAll(".pn[data-net]").forEach(function(e){var nn=e.getAttribute("data-net");
  if(!nn)return;e.style.cursor="pointer";
  if(nn===selNetCur)e.classList.add("net-sel");
  e.addEventListener("mouseenter",function(){hlBy("data-net",nn,"net-hl",true);});
  e.addEventListener("mouseleave",function(){hlBy("data-net",nn,"net-hl",false);});
  e.addEventListener("click",function(){selNet(nn);});});}
function updatePropLive(){if(!selRef)return;var p=partByRef(selRef);if(!p)return;
 var ex=document.getElementById("prop-x"),ey=document.getElementById("prop-y"),er=document.getElementById("prop-rot");
 if(ex)ex.textContent=fmtLen(p.x);if(ey)ey.textContent=fmtLen(p.y);
 if(er)er.textContent=((((p.rot||0)%360)+360)%360)+"°";}
function markSelPart(){paintSoon();}
function selectComp(ref){selRef=ref;renderProps();markGrpRow();markSelPart();xpSend(ref);}
function clearSel(){if(!selRef)return;selRef=null;renderProps();markGrpRow();markSelPart();}
// ── Rigid sub-circuits (top-level: hover glow + paint read them in RO too) ─
// Each sub-block's parts share a ref prefix ("buck/C3" → group "buck").
// A rigid group drags/rotates as one unit — the pre-laid module keeps its
// internal layout while you slide the whole block around the board. "G"
// (or the palette scissors) explodes a group back to individual parts;
// the choice persists per design in localStorage.
function grpOf(ref){var i=String(ref).indexOf("/");return i<0?null:ref.slice(0,i);}
var GRPS={};P.forEach(function(p,i){var g=grpOf(p.ref);if(g)(GRPS[g]=GRPS[g]||[]).push(i);});
// stampGroup lives in the edit-only block below; the properties panel (shared
// with RO pages) reaches it through this indirection.
var stampGroupFn=null;
// Selecting a part lights its sub-circuit's row in the sidebar palette (and
// scrolls it into view), so board and palette stay cross-referenced.
function markGrpRow(){var g=selRef?grpOf(selRef):null,hit=null;
 document.querySelectorAll(".sub-row").forEach(function(r){
  var on=!!g&&r.getAttribute("data-grp")===g;r.classList.toggle("cur",on);if(on)hit=r;});
 if(hit&&hit.scrollIntoView)try{hit.scrollIntoView({block:"nearest"});}catch(e){}}
// Tooltip for a group's Stamp button: which module snapshot the seeds came
// from (PCB.subseedinfo), how much of the group it covers, and — when the ★
// has gone stale — the fuller snapshot to consider re-starring.
function stampTitle(g,inf){var tot=(GRPS[g]||[]).length;
 var t="Place this sub-circuit from its module layout ‘"+pEsc(inf.layout)+"’"+
  (inf.starred?" (★)":"")+" — "+inf.n+" of "+tot+" parts";
 if(!inf.starred)t+=" · no ★ on the module; best-coverage snapshot used (★ one on the module page to pin it)";
 if(inf.alt)t+=" · newer snapshot ‘"+pEsc(inf.alt)+"’ covers "+inf.alt_n+" module parts — ★ it on the module page to stamp from it instead";
 return t;}
var rigidOffKey="pcb-rigid-off:"+PCB.name, rigidOff={};
try{rigidOff=JSON.parse(localStorage.getItem(rigidOffKey)||"{}")||{};}catch(e){}
function rigidSave(){try{localStorage.setItem(rigidOffKey,JSON.stringify(rigidOff));}catch(e){}}
function grpRigid(g){return !!(g&&GRPS[g]&&GRPS[g].length>1&&!rigidOff[g]);}
function grpIdxs(i){var g=grpOf(P[i].ref);return grpRigid(g)?GRPS[g]:null;}
function grpToggle(g){if(!GRPS[g])return;rigidOff[g]=!rigidOff[g];if(!rigidOff[g])delete rigidOff[g];
 rigidSave();subPanelRefresh();}
function grpHl(g,on){hoverGrpName=on?g:null;paintSoon();}
if(!RO){
var drag=null, gdrag=null;
// Multi-select (marquee): sel = part indices currently box-selected; a drag
// on any selected part moves the whole set. Painted purple vs the blue .sel.
var sel=[];
function markSel(){paintSoon();}
function selSet(idxs){sel=idxs;markSel();}
function selClear(){if(!sel.length)return;sel=[];markSel();}
function gdragStart(m,down,idxs){var src=idxs||sel;
 // A RIGID-group drag (idxs given) carries the group's stamped copper along:
 // snapshot the tagged tracks/vias so pointermove can translate them by the
 // same grid-snapped delta as the parts. Marquee drags (idxs null) don't.
 var g=idxs?grpOf(P[down].ref):null,ct=[],cv=[];
 if(g){(PCB.tracks||[]).forEach(function(t){if(t.g===g)ct.push({t:t,x1:t.x1,y1:t.y1,x2:t.x2,y2:t.y2});});
  (PCB.vias||[]).forEach(function(v){if(v.g===g)cv.push({v:v,x:v.x,y:v.y});});}
 return {sx:m.x,sy:m.y,moved:false,down:down,snap:snapAll(),g:g,ct:ct,cv:cv,
 orig:src.filter(function(k){return !P[k].locked;}).map(function(k){return {i:k,x:P[k].x,y:P[k].y};})};}
// Rotate a rigid group 90° about its centroid (locked members stay put).
// keepG (the group's slug, when the whole rigid group rotates) carries the
// group's stamped copper through the same rigid transform, derived from one
// member's exact before→after pose so the copper stays attached to it even
// after the per-part grid snap.
function rotateGroup(idxs,sign,keepG){recordUndo();
 var mv=idxs.filter(function(i){return !P[i].locked;});if(!mv.length)return;
 var r0=mv[0],r0x=P[r0].x,r0y=P[r0].y;
 var cx=0,cy=0;mv.forEach(function(i){cx+=P[i].x;cy+=P[i].y;});cx/=mv.length;cy/=mv.length;
 mv.forEach(function(i){var dx=P[i].x-cx,dy=P[i].y-cy;
  if(sign>0){P[i].x=cx-dy;P[i].y=cy+dx;}else{P[i].x=cx+dy;P[i].y=cy-dx;}
  P[i].x=Math.round(P[i].x/G)*G;P[i].y=Math.round(P[i].y/G)*G;
  P[i].rot=((((P[i].rot||0)+(sign>0?90:-90))%360)+360)%360;setT(i);});
 if(keepG){var nx=P[r0].x,ny=P[r0].y;
  var rr=function(px,py){var dx=px-r0x,dy=py-r0y;
   return sign>0?{x:nx-dy,y:ny+dx}:{x:nx+dy,y:ny-dx};};
  (PCB.tracks||[]).forEach(function(t){if(t.g!==keepG)return;
   var a=rr(t.x1,t.y1),b=rr(t.x2,t.y2);t.x1=a.x;t.y1=a.y;t.x2=b.x;t.y2=b.y;});
  (PCB.vias||[]).forEach(function(v){if(v.g!==keepG)return;
   var a=rr(v.x,v.y);v.x=a.x;v.y=a.y;});}
 clearRouteFor(mv,keepG);ratsUpdate(mv);drawClr();fetchScore();refreshUnplaced();}
// Stamp a group from its module ★ layout (PCB.subseeds): normalize the seed
// cluster to its own bbox, drop it just right of everything currently placed.
function stampGroup(g){var seeds=PCB.subseeds||{},idxs=GRPS[g]||[],hit=[];
 idxs.forEach(function(i){var sd=seeds[P[i].ref];if(sd)hit.push({i:i,sd:sd});});
 if(!hit.length)return;
 recordUndo();
 // Anchor on the group's main IC: keep ITS current board position and form
 // the module layout around it — the IC is usually already roughly where you
 // want the block, so the stamp fills in the passives around it instead of
 // teleporting everything to the staging margin. Falls back to the largest
 // member when the group has no hub.
 var anc=null;hit.forEach(function(h){var p=P[h.i];
  if(!anc){anc=h;return;}
  var a=P[anc.i],pb=(p.kind=="hub")?1:0,ab=(a.kind=="hub")?1:0;
  if(pb>ab||(pb==ab&&(p.hw*p.hh)>(a.hw*a.hh)))anc=h;});
 var ox=P[anc.i].x-anc.sd.x, oy=P[anc.i].y-anc.sd.y;
 hit.forEach(function(h){var i=h.i;if(P[i].locked)return;
  var sg=snapG();P[i].x=Math.round((h.sd.x+ox)/sg)*sg;P[i].y=Math.round((h.sd.y+oy)/sg)*sg;
  P[i].rot=h.sd.rot||0;P[i].side=h.sd.side||"top";setT(i);});
 delete rigidOff[g];rigidSave();
 // Copper: replace this group's stamped copper with the module snapshot's
 // (PCB.subroutes — net names already mapped to this design), translated by
 // the same anchor offset as the poses and tagged with the group slug so
 // rigid drags/rotates carry it. Nets touching a locked (not-moved) member
 // are skipped — their copper would be geometrically wrong.
 clearRouteFor(idxs,g);
 PCB.tracks=(PCB.tracks||[]).filter(function(t){return t.g!==g;});
 PCB.vias=(PCB.vias||[]).filter(function(v){return v.g!==g;});
 var sr=(PCB.subroutes||{})[g];
 if(sr&&((sr.tracks||[]).length||(sr.vias||[]).length)){
  var lockedNets={};idxs.forEach(function(i){if(!P[i].locked)return;
   (P[i].pads||[]).forEach(function(pd){if(pd.net)lockedNets[pd.net]=1;});});
  (sr.tracks||[]).forEach(function(t){if(t.net&&lockedNets[t.net])return;
   PCB.tracks.push({x1:t.x1+ox,y1:t.y1+oy,x2:t.x2+ox,y2:t.y2+oy,l:t.l||0,w:t.w||0.25,net:t.net||"",g:g});});
  (sr.vias||[]).forEach(function(v){if(v.net&&lockedNets[v.net])return;
   PCB.vias.push({x:v.x+ox,y:v.y+oy,d:v.d||0.4,drill:v.drill||0,net:v.net||"",g:g});});}
 rats();drawClr();drawRoute();fetchScore();refreshUnplaced();subPanelRefresh();scheduleDrc();}
stampGroupFn=stampGroup;
// Iterative layout editing: curLayout is the saved layout the Update button
// writes back into (overwrite in place) instead of forcing a new one. Set by
// Load and after a Save as…. Save/Update persist in place (no page reload — see
// persistLayout), so the board, camera and view toggles never reset under you.
var curLayout=null;
function setActiveLayout(nm){curLayout=(nm&&nm.length)?nm:null;
 var ub=document.getElementById("pcb-update");if(ub)ub.disabled=!curLayout;
 var ind=document.getElementById("pcb-active");
 if(ind){if(curLayout){ind.textContent="editing \u{201c}"+curLayout+"\u{201d}";ind.style.display="";}
  else{ind.textContent="";ind.style.display="none";}}
 document.querySelectorAll(".lay-row").forEach(function(row){
  row.classList.toggle("active",curLayout!=null&&row.getAttribute("data-lay-row")===curLayout);});
 var chip=document.getElementById("pcb-srcchip");
 if(chip&&curLayout){chip.textContent="saved \u{00b7} "+curLayout;chip.className="src-chip src-snapshot";
  chip.title="Showing saved layout \u{201c}"+curLayout+"\u{201d} \u{2014} drag to edit, then Update to save progress.";}}
// (Per-part DOM listeners are gone — the svg-level handlers below hit-test
// partAt/padAt and drive the same drag/rigid-drag/select behaviors.)
// Keyboard: R / Shift+R rotates the hovered part; ? toggles the
// shortcut-help overlay (Esc or click closes it). The overlay's list
// mirrors exactly what this script binds.
var kbdOv=null;
function kbdClose(){if(kbdOv&&kbdOv.parentNode)kbdOv.parentNode.removeChild(kbdOv);kbdOv=null;}
function kbdToggle(){
 if(kbdOv){kbdClose();return;}
 kbdOv=document.createElement("div");kbdOv.className="kbd-overlay";
 kbdOv.innerHTML='<div class="kbd-box"><h3>Keyboard &amp; mouse</h3>'+
  '<div class="kbd-row"><span>Rotate hovered part +90°</span><kbd>R</kbd></div>'+
  '<div class="kbd-row"><span>Rotate hovered part −90°</span><kbd>Shift+R</kbd></div>'+
  '<div class="kbd-row"><span>Flip hovered part top/bottom</span><kbd>F</kbd></div>'+
  '<div class="kbd-row"><span>Lock / unlock hovered part</span><kbd>L</kbd></div>'+
  '<div class="kbd-row"><span>Explode / re-cohere hovered sub-circuit</span><kbd>G</kbd></div>'+
  '<div class="kbd-row"><span>Move whole sub-circuit</span><kbd>drag any of its parts</kbd></div>'+
  '<div class="kbd-row"><span>Draw board outline (click = clear)</span><kbd>▭ Outline, then drag</kbd></div>'+
  '<div class="kbd-row"><span>Polygon outline (Enter close &middot; Backspace undo &middot; Esc cancel)</span><kbd>⬡ Poly, then click vertices</kbd></div>'+
  '<div class="kbd-row"><span>Hand-route mode (click pad → trace)</span><kbd>X</kbd></div>'+
  '<div class="kbd-row"><span>Drop via + flip layer (while routing)</span><kbd>V</kbd></div>'+
  '<div class="kbd-row"><span>Step back / finish trace</span><kbd>Backspace / Enter &middot; dbl-click</kbd></div>'+
  '<div class="kbd-row"><span>Delete track or via (in route mode)</span><kbd>right-click</kbd></div>'+
  '<div class="kbd-row"><span>Move part (snaps to grid)</span><kbd>drag part</kbd></div>'+
  '<div class="kbd-row"><span>Select box (multi-select)</span><kbd>drag empty space</kbd></div>'+
  '<div class="kbd-row"><span>Move all selected together</span><kbd>drag a selected part</kbd></div>'+
  '<div class="kbd-row"><span>Clear selection</span><kbd>Esc / click empty</kbd></div>'+
  '<div class="kbd-row"><span>Undo / redo move</span><kbd>Ctrl+Z / Ctrl+Shift+Z</kbd></div>'+
  '<div class="kbd-row"><span>Pan</span><kbd>two-finger drag &middot; Space+drag &middot; middle-drag</kbd></div>'+
  '<div class="kbd-row"><span>Zoom</span><kbd>scroll wheel &middot; pinch &middot; +/&minus;</kbd></div>'+
  '<div class="kbd-row"><span>Toggle this help</span><kbd>?</kbd></div>'+
  '<div class="kbd-hint">Esc or click anywhere to close</div></div>';
 document.body.appendChild(kbdOv);kbdOv.addEventListener("click",kbdClose);
}
// "Typing" = focus is in a TEXT-entry field; only then do the single-key
// shortcuts (R rotate, ? help) yield to it. A focused checkbox/radio/button/
// range — e.g. the Net-colours or Heatmap toggle you just clicked — is NOT
// typing, so R keeps rotating the hovered part. (A bare `INPUT` test used to
// swallow R after any toggle click.)
function kbTyping(t){if(!t)return false;if(t.isContentEditable||t.tagName=="TEXTAREA")return true;
 return t.tagName=="INPUT"&&!/^(checkbox|radio|button|submit|reset|range|color|file)$/i.test(t.type||"text");}
// Space (held) switches an empty-space drag from marquee-select to pan; a
// keyup releases it. Guarded by kbTyping so Space still types in a field.
var SPACE=false;
document.addEventListener("keydown",function(ev){if((ev.key===" "||ev.code==="Space")&&!kbTyping(ev.target)){SPACE=true;ev.preventDefault();}});
document.addEventListener("keyup",function(ev){if(ev.key===" "||ev.code==="Space")SPACE=false;});
document.addEventListener("keydown",function(ev){
 if(ev.key=="Escape"){if(kbdOv){kbdClose();}else if(drawMode){if(dtrace)drawEnd();else drawModeSet(false);}else if(polyMode){if(polyPts){polyPts=null;polyCur=null;drawBoardRect();}else polyArm(false);}else if(outlineMode){outDraw=null;outlineArm(false);drawBoardRect();}else{selClear();clearSel();}return;}
 if(polyMode&&ev.key=="Enter"){ev.preventDefault();polyClose();return;}
 if(polyMode&&(ev.key=="Backspace"||ev.key=="Delete")){ev.preventDefault();polyPop();return;}
 var typing=kbTyping(ev.target);
 if(ev.key=="?"&&!typing){ev.preventDefault();kbdToggle();return;}
 if((ev.key=="r"||ev.key=="R")&&cur>=0&&!typing){ev.preventDefault();if(P[cur].locked)return;
   // Mirror the drag priority (pointerdown): a marquee multi-select that
   // includes the hovered part rotates as ONE rigid body about the
   // selection's centroid — not each part spinning in place — then a rigid
   // sub-circuit, then the lone hovered part.
   if(sel.length>1&&sel.indexOf(cur)>=0){rotateGroup(sel,ev.shiftKey?-1:1);return;}
   var rgi=grpIdxs(cur);
   if(rgi){rotateGroup(rgi,ev.shiftKey?-1:1,grpOf(P[cur].ref));return;}
   recordUndo();
   P[cur].rot=((((P[cur].rot||0)+(ev.shiftKey?-90:90))%360)+360)%360;
   setT(cur);clearRouteFor([cur]);ratsUpdate([cur]);fetchScore();refreshUnplaced();if(selRef===P[cur].ref)updatePropLive();return;}
 if((ev.key=="g"||ev.key=="G")&&cur>=0&&!typing){ev.preventDefault();
   var gg=grpOf(P[cur].ref);if(gg&&GRPS[gg]){grpToggle(gg);grpHl(gg,grpRigid(gg));}return;}
 if((ev.key=="f"||ev.key=="F")&&cur>=0&&!typing){ev.preventDefault();if(P[cur].locked)return;recordUndo();
   P[cur].side=(P[cur].side==="bottom")?"top":"bottom";
   setT(cur);clearRouteFor([cur]);ratsUpdate([cur]);drawClr();fetchScore();refreshUnplaced();
   if(selRef===P[cur].ref)renderProps();return;}
 if((ev.key=="l"||ev.key=="L")&&cur>=0&&!typing){ev.preventDefault();
   P[cur].locked=!P[cur].locked;setT(cur);if(selRef===P[cur].ref)renderProps();return;}});
function applyAll(){P.forEach(function(p,i){setT(i);});clearRoute();rats();fetchScore();refreshUnplaced();updatePropLive();
 if(window.PCB3D&&window.PCB3D.sync)window.PCB3D.sync();}
// ── Undo / redo ─────────────────────────────────────────────────────────
// Snapshot every part's pose before a mutating gesture; Ctrl+Z restores the
// last one (Ctrl+Shift+Z / Ctrl+Y redoes). Drags/group-moves capture their
// PRE state at pointerdown and commit it only if something actually moved;
// rotate / reset / load record just before they mutate. Snapshots are pose
// arrays indexed by P order (stable), so a restore is a write-back + applyAll.
// An undo entry snapshots BOTH the poses AND the copper ({tracks,vias}) so a
// hand-routed segment, a copper delete, a Stamp, and an autoroute apply are all
// undoable — not just part moves. snapPoses() stays the pose-only capture
// callers grab at a drag's pointerdown; recordUndo/restoreSnap wrap it with the
// copper of the moment so the whole edit rewinds atomically.
var undoStack=[],redoStack=[];
function snapPoses(){return P.map(function(p){return {x:p.x,y:p.y,rot:p.rot||0,side:p.side||"top",locked:!!p.locked};});}
function cloneCopper(){return {tracks:(PCB.tracks||[]).map(function(t){return {x1:t.x1,y1:t.y1,x2:t.x2,y2:t.y2,l:t.l||0,w:t.w,net:t.net||"",g:t.g};}),
 vias:(PCB.vias||[]).map(function(v){return {x:v.x,y:v.y,d:v.d,drill:v.drill,net:v.net||"",g:v.g};})};}
// Build a full snapshot. `poses` optionally overrides the current poses (a
// drag's captured pre-move state); copper is always the current copper.
function snapAll(poses){var c=cloneCopper();return {poses:poses||snapPoses(),tracks:c.tracks,vias:c.vias};}
function undoBtns(){var u=document.getElementById("pcb-undo"),r=document.getElementById("pcb-redo");
 if(u)u.disabled=!undoStack.length;if(r)r.disabled=!redoStack.length;}
// recordUndo accepts a full snapshot {poses,tracks,vias}, a bare pose array
// (legacy drag capture — copper filled from the current model), or nothing.
function recordUndo(snap){var e=(snap&&snap.poses)?snap:snapAll(Array.isArray(snap)?snap:null);
 undoStack.push(e);if(undoStack.length>200)undoStack.shift();
 redoStack.length=0;undoBtns();}
function restoreSnap(s){s.poses.forEach(function(q,i){if(P[i]){P[i].x=q.x;P[i].y=q.y;P[i].rot=q.rot;P[i].side=q.side||"top";P[i].locked=!!q.locked;}});
 // applyAll() clears copper (a moved part invalidates routing), so restore the
 // snapshot's copper AFTER it, then repaint + re-DRC.
 applyAll();
 PCB.tracks=(s.tracks||[]).map(function(t){return {x1:t.x1,y1:t.y1,x2:t.x2,y2:t.y2,l:t.l||0,w:t.w,net:t.net||"",g:t.g};});
 PCB.vias=(s.vias||[]).map(function(v){return {x:v.x,y:v.y,d:v.d,drill:v.drill,net:v.net||"",g:v.g};});
 PCB.drc=[];drawRoute();drawDrc();scheduleDrc();}
function doUndo(){if(!undoStack.length)return;redoStack.push(snapAll());restoreSnap(undoStack.pop());undoBtns();}
function doRedo(){if(!redoStack.length)return;undoStack.push(snapAll());restoreSnap(redoStack.pop());undoBtns();}
var undoBtn=document.getElementById("pcb-undo");if(undoBtn)undoBtn.addEventListener("click",doUndo);
var redoBtn=document.getElementById("pcb-redo");if(redoBtn)redoBtn.addEventListener("click",doRedo);
document.addEventListener("keydown",function(ev){if(!(ev.ctrlKey||ev.metaKey)||kbTyping(ev.target))return;
 var k=(ev.key||"").toLowerCase();
 if(k==="z"&&!ev.shiftKey){ev.preventDefault();doUndo();}
 else if((k==="z"&&ev.shiftKey)||k==="y"){ev.preventDefault();doRedo();}});
undoBtns();
var outBtn=document.getElementById("pcb-outline");
if(outBtn)outBtn.addEventListener("click",function(){outlineArm(!outlineMode);});
var polyBtn=document.getElementById("pcb-outline-poly");
if(polyBtn)polyBtn.addEventListener("click",function(){polyArm(!polyMode);});
document.getElementById("pcb-reset").addEventListener("click",function(){recordUndo();
 selClear();P.forEach(function(p,i){p.x=orig[i].x;p.y=orig[i].y;p.rot=orig[i].rot;p.side=orig[i].side;});applyAll();});
document.getElementById("pcb-score").addEventListener("click",fetchScore);
document.getElementById("t-apply").addEventListener("click",function(ev){ev.preventDefault();
 var v=function(id){return encodeURIComponent(document.getElementById(id).value);};
 var g=document.getElementById("t-grid").checked?1:0;
 liveRegen("?w_align="+v("t-align")+"&loop_w="+v("t-loop")+"&w_congest="+v("t-cong")+
  "&grid="+g);});
// Score-view weights persist per design in localStorage ("pcb-sv:<name>"):
// stored on every change, restored on load (before the first showScore so
// the headline respects them), and cleared by Reset along with the inputs.
(function(){var ids=["sv-en-wire","sv-w-wire","sv-en-loop","sv-w-loop","sv-en-align","sv-w-align","sv-en-cong","sv-w-cong"];
 var key="pcb-sv:"+PCB.name;
 var def={};ids.forEach(function(id){var e=document.getElementById(id);if(!e)return;
  def[id]=(e.type=="checkbox")?e.checked:e.value;});
 var stored=null;try{stored=JSON.parse(localStorage.getItem(key)||"null");}catch(e){}
 if(stored)ids.forEach(function(id){var e=document.getElementById(id);if(!e||!(id in stored))return;
  if(e.type=="checkbox")e.checked=!!stored[id];else e.value=stored[id];});
 function persist(){var o={};ids.forEach(function(id){var e=document.getElementById(id);if(!e)return;
  o[id]=(e.type=="checkbox")?e.checked:e.value;});
  try{localStorage.setItem(key,JSON.stringify(o));}catch(e){}}
 ids.forEach(function(id){var e=document.getElementById(id);if(!e)return;
  e.addEventListener("input",function(){persist();svApply();});});
 var rb=document.getElementById("sv-reset");
 if(rb)rb.addEventListener("click",function(){ids.forEach(function(id){var e=document.getElementById(id);
   if(e){if(e.type=="checkbox")e.checked=def[id];else e.value=def[id];}});
  try{localStorage.removeItem(key);}catch(e){}svApply();});})();
function pad2(n){return (n<10?"0":"")+n;}
function stamp(){var d=new Date();return pad2(d.getMonth()+1)+"-"+pad2(d.getDate())+" "+pad2(d.getHours())+":"+pad2(d.getMinutes());}
function layByName(nm){var Ls=PCB.layouts||[];for(var i=0;i<Ls.length;i++)if(Ls[i].name===nm)return Ls[i];return null;}
// ── Saved-layout panel rows are built/bound here too (not only server-side) so
//    a Save/Update can splice a row in place rather than reloading the page.
function mkEl(tag,cls,txt){var e=document.createElement(tag);if(cls)e.className=cls;
 if(txt!=null)e.textContent=txt;return e;}
function bindLayLoad(b){b.addEventListener("click",function(){var nm=b.getAttribute("data-lay-load");
 var L=layByName(nm);if(!L)return;recordUndo();
 // Match each on-screen part to its saved pose by the renumber-stable origin
 // key first (falls back to ref-des for legacy layouts saved without one), so
 // a Load still lands after the parts renumber (e.g. module standalone vs nested).
 var byOrigin={};for(var k in L.parts){var v=L.parts[k];if(v&&v.origin)byOrigin[v.origin]=v;}
 P.forEach(function(p){var s=(p.origin&&byOrigin[p.origin])||L.parts[p.ref];if(s){p.x=s.x;p.y=s.y;p.rot=s.rot||0;p.side=s.side||"top";if(s.locked!==undefined)p.locked=!!s.locked;}});applyAll();
 if(L.routes&&((L.routes.tracks||[]).length||(L.routes.vias||[]).length)){
  PCB.tracks=L.routes.tracks||[];PCB.vias=L.routes.vias||[];PCB.drc=[];drawRoute();drawDrc();}
 PCB.outline=L.outline||null;drawBoardRect();
 setActiveLayout(nm);});}
function bindLayDel(b){b.addEventListener("click",function(){var nm=b.getAttribute("data-lay-del");
 if(!window.confirm("Delete layout \""+nm+"\"?"))return;
 fetch("/api/pcb-layouts/"+encodeURIComponent(PCB.name)+"/delete"+subq(),{method:"POST",
   headers:{"Content-Type":"application/json"},body:JSON.stringify({name:nm})})
  .then(function(r){if(!r.ok)throw 0;window.location.reload();}).catch(function(){});});}
// ★ toggle: set this layout as the KiCad-sync default, or clear it if already
// default (send an empty name). The server seeds new parts' placement + GND
// vias from the default on the next sync.
function bindLayDefault(b){b.addEventListener("click",function(){var nm=b.getAttribute("data-lay-default");
 var send=b.classList.contains("on")?"":nm;
 fetch("/api/pcb-layouts/"+encodeURIComponent(PCB.name)+"/default"+subq(),{method:"POST",
   headers:{"Content-Type":"application/json"},body:JSON.stringify({name:send})})
  .then(function(r){if(!r.ok)throw 0;window.location.reload();}).catch(function(){});});}
function bindRescore(btn){btn.addEventListener("click",function(){
 btn.disabled=true;btn.textContent="Rescoring…";
 fetch("/api/pcb-rescore/"+encodeURIComponent(PCB.name)+subq(),{method:"POST"})
  .then(function(r){if(!r.ok)throw 0;return r.json();})
  .then(function(){window.location.reload();})
  .catch(function(){btn.disabled=false;btn.textContent="\u{21bb} Rescore all";});}); }
document.querySelectorAll("[data-lay-load]").forEach(bindLayLoad);
document.querySelectorAll("[data-lay-del]").forEach(bindLayDel);
document.querySelectorAll("[data-lay-default]").forEach(bindLayDefault);
var rescoreBtn0=document.getElementById("pcb-rescore");if(rescoreBtn0)bindRescore(rescoreBtn0);
// Build a fresh manual saved-layout row mirroring writeLayoutsPanel's markup, so
// reweighLayouts (keyed on .lay-row/.lay-score/.lay-d) and the panel buttons all
// work on it with no reload. score/delta fill in once loadLayoutScores returns.
function buildLayRow(nm){
 var row=mkEl("div","lay-row");row.setAttribute("data-lay-row",nm);
 var top=mkEl("div","lay-top");
 top.appendChild(mkEl("span","lay-kind k-man","manual"));
 top.appendChild(mkEl("span","lay-name",nm));
 top.appendChild(mkEl("span","lay-d",""));
 var bot=mkEl("div","lay-bot");bot.appendChild(mkEl("span","lay-score","\u{2014}"));
 var act=mkEl("span","lay-actions");
 var star=mkEl("button","btn lay-star","\u{2606}");star.setAttribute("data-lay-default",nm);
 star.title="Make this the KiCad-sync default (seeds new parts' placement + GND vias)";bindLayDefault(star);
 var go=mkEl("button","btn lay-go","Load");go.setAttribute("data-lay-load",nm);bindLayLoad(go);
 var del=mkEl("button","btn lay-del","\u{2715}");del.setAttribute("data-lay-del",nm);del.title="Delete";bindLayDel(del);
 act.appendChild(star);act.appendChild(go);act.appendChild(del);
 bot.appendChild(act);row.appendChild(top);row.appendChild(bot);return row;}
// Splice a row for nm into the panel if it isn't there yet (Save as…); the
// empty-state placeholder converts to a list + rescore button on the first save.
function upsertLayoutPanel(nm){var saved=document.querySelector(".pcb-saved");if(!saved)return;
 var list=saved.querySelector(".saved-list");
 if(!list){var emp=saved.querySelector(".saved-empty");if(emp&&emp.parentNode)emp.parentNode.removeChild(emp);
  list=mkEl("div","saved-list");saved.appendChild(list);
  var hd=saved.querySelector(".saved-h");
  if(hd&&!document.getElementById("pcb-rescore")){var rb=mkEl("button","saved-rescore","\u{21bb} Rescore all");
   rb.id="pcb-rescore";rb.title="Recompute every saved layout's objective with the current engine";
   hd.appendChild(rb);bindRescore(rb);}}
 var rows=list.querySelectorAll(".lay-row");
 for(var i=0;i<rows.length;i++)if(rows[i].getAttribute("data-lay-row")===nm)return;
 list.appendChild(buildLayRow(nm));
 var n=saved.querySelector(".saved-n");if(n)n.textContent=list.querySelectorAll(".lay-row").length;}
// Fetch each saved layout's raw breakdown, then re-weigh the panel so its
// scores/deltas track the Score-view weights alongside the live bar. Re-run
// after a Save/Update so the affected row's score refreshes in place.
function loadLayoutScores(){if(PCB.single)return;if(!((PCB.layouts||[]).length))return;
 fetch("/api/pcb-score-batch/"+encodeURIComponent(PCB.name)+subq(),{method:"POST"})
  .then(function(r){return r.json();})
  .then(function(j){(j.results||[]).forEach(function(it){layBreaks[it.name]=it.breakdown;});reweighLayouts();})
  .catch(function(){});}
// Persist the current poses to layout nm and update the panel IN PLACE — no
// page reload, so the camera and view toggles you set while editing stay put.
function persistLayout(nm,verb){var msg=document.getElementById("pcb-savemsg");
 var parts=P.map(function(p){return {ref:p.ref,x:p.x,y:p.y,rot:p.rot||0,origin:p.origin||"",side:p.side||"top",locked:!!p.locked};});
 // Persist the on-screen copper + drawn outline with the poses so both
 // survive reloads.
 var routes=((PCB.tracks||[]).length||(PCB.vias||[]).length)?{tracks:PCB.tracks||[],vias:PCB.vias||[]}:null;
 if(msg){msg.style.color="#8b949e";msg.textContent=verb+"\u{2026}";}
 return fetch("/api/pcb-layouts/"+encodeURIComponent(PCB.name)+subq(),{method:"POST",
   headers:{"Content-Type":"application/json"},body:JSON.stringify({name:nm,parts:parts,routes:routes,outline:PCB.outline||null})})
  .then(function(r){if(!r.ok)throw 0;return r.json();})
  .then(function(){
    var pmap={};parts.forEach(function(p){pmap[p.ref]={x:p.x,y:p.y,rot:p.rot,origin:p.origin||"",side:p.side,locked:p.locked};});
    var Ls=PCB.layouts||(PCB.layouts=[]),found=null;
    for(var i=0;i<Ls.length;i++)if(Ls[i].name===nm){found=Ls[i];break;}
    if(found){found.parts=pmap;found.kind="manual";found.routes=routes;found.outline=PCB.outline||null;}
    else Ls.push({name:nm,kind:"manual",parts:pmap,score:null,routes:routes,outline:PCB.outline||null});
    upsertLayoutPanel(nm);setActiveLayout(nm);loadLayoutScores();
    // The URL may still carry a layout-selection flag from an earlier Rough/
    // Regenerate (?show=cache, ?regen, tuning params) that outranks the starred
    // layout on reload. You just SAVED — a refresh must show the saved board,
    // so scrub those flags from the address bar.
    try{var u=new URL(window.location.href);
     ["show","refine","regen","rough","loop_w","w_align","w_congest","cap_w_max","grid",
      "court_overlap","route_gap","group_w","group_zone_w","group_loop_relief","zone_pack"]
      .forEach(function(kq){u.searchParams.delete(kq);});
     window.history.replaceState(null,"",u.pathname+(u.searchParams.toString()?"?"+u.searchParams.toString():"")+u.hash);}catch(e){}
    if(msg){msg.style.color="#3fb950";msg.textContent=(verb==="updating"?"updated":"saved")+" \u{2713}";}
    scheduleDrc();/* re-DRC the just-saved copper (audit 1.1d) */})
  .catch(function(){if(msg){msg.style.color="#f85149";
    msg.textContent=(verb==="updating"?"update":"save")+" failed";}});}
document.getElementById("pcb-saveas").addEventListener("click",function(){
 if(PCB.single){persistLayout("layout","saving");return;} // designs keep ONE layout
 var nm=window.prompt("Name this layout:","layout "+stamp());
 if(nm===null)return; nm=nm.trim(); if(!nm)return; persistLayout(nm,"saving");});
// Update: overwrite the loaded layout in place (no prompt) — save progress on
// the layout you're iterating without disturbing the view.
var updBtn=document.getElementById("pcb-update");
if(updBtn)updBtn.addEventListener("click",function(){if(!curLayout)return;persistLayout(curLayout,"updating");});
loadLayoutScores();
// ── Sub-circuits palette ─────────────────────────────────────────────
// One row per sub-block: member count, rigid/exploded toggle, and — when the
// module has a stampable saved layout (PCB.subseeds) — a Stamp button that
// drops the whole pre-laid cluster onto the board. The tooltip names the
// snapshot the seeds came from (PCB.subseedinfo: the ★ when starred, else
// best coverage); a coverage chip appears when it doesn't span the group, and
// a "—" placeholder marks groups with nothing to stamp.
function subPanelRefresh(){var box=document.getElementById("sub-panel");if(!box)return;
 var names=Object.keys(GRPS).sort();var h='<div class="side-h">Sub-circuits</div>';
 var seeds=PCB.subseeds||{},sinfo=PCB.subseedinfo||{};
 names.forEach(function(g){
  var hasSeed=GRPS[g].some(function(i){return !!seeds[P[i].ref];});
  var inf=sinfo[g],tot=GRPS[g].length;
  var cov=(inf&&inf.n<tot)?'<span class="sub-cov" title="The module snapshot covers '+inf.n+' of this group’s '+tot+' parts — the rest keep their positions on Stamp.">'+inf.n+'/'+tot+'</span>':'';
  var mod=(PCB.submodules||{})[g];
  var nameH=mod?'<a class="sub-name" href="/pcb-layout/'+encodeURIComponent(mod)+'" target="_blank" rel="noopener" title="Open module ‘'+pEsc(mod)+'’ on its own PCB-layout page — lay it out and save / ★ a layout there.">'+pEsc(g)+'</a>'
   :'<span class="sub-name">'+pEsc(g)+'</span>';
  h+='<div class="sub-row" data-grp="'+pEsc(g)+'">'+
   nameH+'<span class="sub-n">'+tot+'</span>'+
   '<button class="btn sub-rigid'+(grpRigid(g)?" on":"")+'" data-rigid="'+pEsc(g)+'" title="'+
    (grpRigid(g)?"Rigid — drags as one unit. Click to explode.":"Exploded — parts move individually. Click to re-cohere.")+'">'+
    (grpRigid(g)?"\u{1F517}":"\u{2702}")+'</button>'+cov+
   (hasSeed?'<button class="btn sub-stamp" data-stamp="'+pEsc(g)+'" title="'+
     (inf?stampTitle(g,inf):"Place this sub-circuit from its module layout")+'">Stamp</button>':
    '<span class="sub-noseed" title="No saved layout on the module matches its current parts \u2014 lay it out and save on the module\u2019s own page.">\u2014</span>')+
   '</div>';});
 box.innerHTML=h;
 box.querySelectorAll("[data-rigid]").forEach(function(b){b.addEventListener("click",function(){grpToggle(b.getAttribute("data-rigid"));});});
 box.querySelectorAll("[data-stamp]").forEach(function(b){b.addEventListener("click",function(){stampGroup(b.getAttribute("data-stamp"));});});
 box.querySelectorAll(".sub-row").forEach(function(r){var g=r.getAttribute("data-grp");
  r.addEventListener("mouseenter",function(){grpHl(g,true);});
  r.addEventListener("mouseleave",function(){grpHl(g,false);});});
 markGrpRow();}
(function(){
 if(!Object.keys(GRPS).length)return;
 var side=document.querySelector(".pcb-side");if(!side)return;
 var box=document.createElement("div");box.id="sub-panel";box.className="sub-panel";
 side.appendChild(box);subPanelRefresh();})();
}
// Net hover (sidebar pin-chip mouseenter): board pads glow via paint state.
function netIdxDrop(){}
function hlBy(at,v,cls,on){
 if(at==="data-net"){hoverNet=on?v:null;paintSoon();return;}
 document.querySelectorAll("["+at+"]").forEach(function(e){
 if(e.getAttribute(at)===v)e.classList.toggle(cls,on);});}
function wire(at,cls){document.querySelectorAll("["+at+"]").forEach(function(e){
 e.addEventListener("mouseenter",function(){hlBy(at,e.getAttribute(at),cls,true);});
 e.addEventListener("mouseleave",function(){hlBy(at,e.getAttribute(at),cls,false);});});}
wire("data-ref","hl"); wire("data-net","net-hl");
// Sticky net selection: click a pad (or a sidebar pin chip) and every pad on
// that net glows gold, so you can trace what's tied together with net colours
// on OR off. Re-click the same net, or click the empty board, to clear. The
// editor and the read-only preview both drive it from the svg-level
// pointer-up (clickPart hit-tests the pad under the cursor).
var selNetCur=null;
function selNet(net){if(net&&selNetCur===net)net=null;selNetCur=net;
 // Board pads glow via paint state; the sidebar pin chips are still DOM.
 document.querySelectorAll(".pn[data-net]").forEach(function(e){
  e.classList.toggle("net-sel",net!=null&&e.getAttribute("data-net")===net);});
 paintSoon();}
var VBW=PCB.w,VBH=PCB.h,vb={x:0,y:0,w:VBW,h:VBH};
function setVB(){svg.setAttribute("viewBox",vb.x.toFixed(1)+" "+vb.y.toFixed(1)+" "+vb.w.toFixed(1)+" "+vb.h.toFixed(1));
 // Pad-number labels are thousands of <text> nodes — unreadable when zoomed
 // out anyway, so drop them from rendering entirely below ~1.15 px/unit.
 var r=svg.getBoundingClientRect();
 svg.classList.toggle("zoomed-out",r.width>0&&(r.width/vb.w)<1.15);
 ovPaintSoon();}
function zoomAt(cx,cy,f){if((f<1&&vb.w<VBW*0.08)||(f>1&&vb.w>VBW*8))return;
 var r=svg.getBoundingClientRect();
 var px=vb.x+(cx-r.left)*(vb.w/r.width),py=vb.y+(cy-r.top)*(vb.h/r.height);
 vb.x=px-(px-vb.x)*f; vb.y=py-(py-vb.y)*f; vb.w*=f; vb.h*=f; setVB();}
// Figma-style wheel routing. A trackpad two-finger PINCH (or held Ctrl)
// arrives as a wheel event with ctrlKey set → zoom at the cursor. A plain
// MOUSE wheel (no horizontal delta, big discrete vertical notch, or a
// line/page deltaMode) → zoom too — that's what bench mouse users expect.
// Only a two-finger trackpad DRAG (pixel-precise, usually carrying deltaX,
// small per-event steps) → pan by its delta.
function wheelIsMouse(ev){
 if(ev.deltaMode!==0)return true;            // Firefox line/page mode = real wheel
 if(ev.deltaX!==0)return false;              // horizontal component = trackpad pan
 return Math.abs(ev.deltaY)>=24;}            // big pure-vertical notch = wheel
svg.addEventListener("wheel",function(ev){ev.preventDefault();
 if(ev.ctrlKey){zoomAt(ev.clientX,ev.clientY,Math.exp(ev.deltaY*0.01));return;}
 var r=svg.getBoundingClientRect(),dx=ev.deltaX,dy=ev.deltaY;
 if(ev.deltaMode===1){dx*=16;dy*=16;}else if(ev.deltaMode===2){dx*=r.width;dy*=r.height;}
 if(wheelIsMouse(ev)){zoomAt(ev.clientX,ev.clientY,dy<0?0.85:1.18);return;}
 vb.x+=dx*(vb.w/r.width);vb.y+=dy*(vb.h/r.height);setVB();},{passive:false});
function zc(f){var r=svg.getBoundingClientRect();zoomAt(r.left+r.width/2,r.top+r.height/2,f);}
var zi=document.getElementById("z-in");if(zi)zi.addEventListener("click",function(){zc(0.8);});
var zo=document.getElementById("z-out");if(zo)zo.addEventListener("click",function(){zc(1.25);});
var zf=document.getElementById("z-fit");if(zf)zf.addEventListener("click",function(){vb={x:0,y:0,w:VBW,h:VBH};setVB();});
// Empty-space drag = marquee select (pick every part whose centre lands in the
// box); Space-held or middle-button drag = pan instead. A no-move click clears
// the selection. The rubber-band rect lives in the top layer (pointer-events
// off) and is drawn in SVG coords via X()/Y() so it tracks pan/zoom.
var pan=null,marq=null,marqEl=null;
// ▭ Outline tool: while armed, a drag on empty board draws the PCB outline
// rectangle (grid-snapped); a plain click clears it. The rectangle is saved
// with the layout (SavedLayout.outline) and becomes the board edge every
// renderer draws and the board-edge DRC checks. RO pages never arm it.
var outlineMode=false,outDraw=null;
function outlineArm(on){
 if(on&&polyMode)polyArm(false);
 outlineMode=on;
 var b=document.getElementById("pcb-outline");if(b)b.classList.toggle("on",on);
 svg.classList.toggle("outline-mode",on||polyMode);
 var msg=document.getElementById("pcb-savemsg");
 if(msg&&on){msg.style.color="#7ee787";
  msg.textContent="outline: drag a rectangle on the board (plain click clears, Esc cancels)";}
 else if(msg&&!outDraw){msg.textContent="";}}
// ⬡ Poly tool: click to place polygon-outline vertices (grid-snapped); click
// the first vertex or press Enter to close, Backspace removes the last
// vertex, Esc cancels. The closed polygon becomes PCB.outline
// ({x,y,w,h}=bbox + pts) — persisted by Save/Update exactly like the
// rectangle — and its vertices stay draggable for editing afterwards.
var polyMode=false,polyPts=null,polyCur=null,vdrag=null;
function polyArm(on){if(RO&&on)return;
 if(on&&outlineMode)outlineArm(false);
 if(on&&drawMode)drawModeSet(false);
 polyMode=on;
 if(!on){polyPts=null;polyCur=null;}
 var b=document.getElementById("pcb-outline-poly");if(b)b.classList.toggle("on",on);
 svg.classList.toggle("outline-mode",on||outlineMode);
 var msg=document.getElementById("pcb-savemsg");
 if(msg&&on){msg.style.color="#7ee787";
  msg.textContent="polygon outline: click to place vertices — click the first vertex or Enter closes, Backspace undoes, Esc cancels";}
 else if(msg&&!on){msg.textContent="";}
 drawBoardRect();}
function outlineMsg(txt){var msg=document.getElementById("pcb-savemsg");
 if(msg){msg.style.color="#8b949e";msg.textContent=txt;}}
// Re-derive a polygon outline's rect fields from its vertex bbox (the server
// does the same on parse, so the pair can never disagree).
function outlineBboxSync(){var o=PCB.outline;if(!o||!o.pts)return;
 var ax=1e18,ay=1e18,bx=-1e18,by=-1e18;
 o.pts.forEach(function(p){ax=Math.min(ax,p[0]);ay=Math.min(ay,p[1]);bx=Math.max(bx,p[0]);by=Math.max(by,p[1]);});
 o.x=ax;o.y=ay;o.w=bx-ax;o.h=by-ay;}
function polyClose(){
 if(!polyPts||polyPts.length<3){polyArm(false);drawBoardRect();return;}
 var prev=PCB.outline,pts=polyPts.slice();polyPts=null;polyCur=null;
 PCB.outline={x:0,y:0,w:0,h:0,pts:pts};outlineBboxSync();
 var ok=PCB.outline.w>=2&&PCB.outline.h>=2;
 if(!ok)PCB.outline=prev;
 polyArm(false);drawBoardRect();
 outlineMsg(ok?"polygon outline set — Save/Update to keep":"polygon too small — outline unchanged");}
function polyPop(){if(polyPts&&polyPts.length){polyPts.pop();if(!polyPts.length)polyPts=null;drawBoardRect();}}
// The drawn-polygon vertex under a board point, or -1 (handle-sized hit box).
function vtxAt(m){var o=PCB.outline;if(!o||!o.pts)return -1;
 var bd=7/S,best=-1;
 o.pts.forEach(function(p,i){var d=Math.max(Math.abs(p[0]-m.x),Math.abs(p[1]-m.y));if(d<=bd){bd=d;best=i;}});
 return best;}
// Start a viewport pan from the current pointer. Shared by the empty-space
// handler below AND the part/pad pointerdown handlers (defined earlier, this is
// hoisted), so a middle-button or Space-held drag pans the board even when the
// cursor is over a component instead of grabbing the part. Capture on svg so its
// pointermove/up drive the pan regardless of which child was hit.
// Guarded pointer capture: capture only keeps events flowing when the cursor
// leaves the svg mid-drag — never worth aborting the whole gesture over (a
// synthetic/test pointer can't be captured and used to throw NotFoundError
// out of the pointerdown handler, killing the drag before it started).
function pcap(ev){try{svg.setPointerCapture(ev.pointerId);}catch(e){}}
function startPan(ev){pan={cx:ev.clientX,cy:ev.clientY,vx:vb.x,vy:vb.y,moved:false,
 slop:ev.pointerType==="touch"?8:3,tapi:-1};
 pcap(ev);svg.style.cursor="grabbing";}
var clickCand=null; // pressed a part but won't drag (RO page / locked part)
// Touch gestures (phones/tablets): one finger anywhere = pan the board, a tap
// (no movement) = select the part/pad under it, two fingers = pinch zoom.
// Part dragging and marquee select stay pointer-precise (mouse/pen) — a finger
// panning across a dense board must never yank components along with it.
var tpts={},pinch=null;
function touchCount(){return Object.keys(tpts).length;}
function touchDown(ev){
 tpts[ev.pointerId]={x:ev.clientX,y:ev.clientY};pcap(ev);
 if(touchCount()===2){ // second finger: whatever gesture ran becomes a pinch
  pan=null;
  if(marq){if(marqEl&&marqEl.parentNode)marqEl.parentNode.removeChild(marqEl);marqEl=null;marq=null;}
  var ids=Object.keys(tpts),a=tpts[ids[0]],b=tpts[ids[1]];
  pinch={d:Math.hypot(a.x-b.x,a.y-b.y),mx:(a.x+b.x)/2,my:(a.y+b.y)/2};
  svg.style.cursor="";return;}
 var m=mm(ev);startPan(ev);pan.tapi=partAt(m.x,m.y);}
function touchMove(ev){
 if(!tpts[ev.pointerId])return false;
 tpts[ev.pointerId]={x:ev.clientX,y:ev.clientY};
 if(!pinch||touchCount()<2)return false; // single finger: fall through to pan
 var ids=Object.keys(tpts),a=tpts[ids[0]],b=tpts[ids[1]];
 var d=Math.hypot(a.x-b.x,a.y-b.y),mx=(a.x+b.x)/2,my=(a.y+b.y)/2;
 if(d>1)zoomAt(mx,my,pinch.d/d);
 var r=svg.getBoundingClientRect();
 vb.x-=(mx-pinch.mx)*(vb.w/r.width);vb.y-=(my-pinch.my)*(vb.h/r.height);setVB();
 pinch.d=d;pinch.mx=mx;pinch.my=my;return true;}
function touchUp(ev){
 if(!tpts[ev.pointerId])return;
 delete tpts[ev.pointerId];
 if(pinch&&touchCount()<2)pinch=null;}
svg.addEventListener("pointercancel",function(ev){touchUp(ev);
 if(ev.pointerType==="touch"&&touchCount()===0){pan=null;pinch=null;svg.style.cursor="";}});
svg.addEventListener("pointerdown",function(ev){if(ev.target!==svg)return;ev.preventDefault();
 if((outlineMode||polyMode)&&ev.button===0&&!polyPts){var hv=vtxAt(mm(ev));
  if(hv>=0){vdrag={i:hv,moved:false};pcap(ev);return;}}
 if(polyMode){if(ev.button!==0)return;
  var pm=mm(ev);
  if(polyPts&&polyPts.length>=3){var pf=polyPts[0];
   if(Math.max(Math.abs(pm.x-pf[0]),Math.abs(pm.y-pf[1]))<=7/S){polyClose();return;}}
  polyPts=polyPts||[];
  var np=[Math.round(pm.x/G)*G,Math.round(pm.y/G)*G],lp2=polyPts[polyPts.length-1];
  if(!lp2||lp2[0]!==np[0]||lp2[1]!==np[1])polyPts.push(np);
  polyCur=null;drawBoardRect();return;}
 if(outlineMode){var om=mm(ev);outDraw={x0:om.x,y0:om.y,x1:om.x,y1:om.y};
  pcap(ev);return;}
 if(SPACE||ev.button===1){startPan(ev);return;}
 if(drawMode&&ev.button===0){drawClick(mm(ev),ev.shiftKey);return;}
 if(ev.pointerType==="touch"){touchDown(ev);return;}
 var m=mm(ev),hi=partAt(m.x,m.y);
 if(hi<0){
  if(!RO){var uv=vtxAt(m);if(uv>=0){vdrag={i:uv,moved:false};pcap(ev);return;}}
  marq={x0:m.x,y0:m.y,x1:m.x,y1:m.y,moved:false};pcap(ev);
  marqEl=el("rect",{"class":"marquee",x:0,y:0,width:0,height:0});gU.appendChild(marqEl);return;}
 // Part gesture (hit-tested — parts are canvas-painted, not DOM).
 pcap(ev);
 if(RO||P[hi].locked){clickCand={i:hi,m:m};return;}
 if(sel.length>1&&sel.indexOf(hi)>=0){gdrag=gdragStart(m,hi);svg.style.cursor="grabbing";return;}
 if(sel.length)selClear();
 var gi=grpIdxs(hi);
 if(gi){gdrag=gdragStart(m,hi,gi);svg.style.cursor="grabbing";return;}
 drag={i:hi,ox:P[hi].x-m.x,oy:P[hi].y-m.y,m0:m,snap:snapAll()};svg.style.cursor="grabbing";});
svg.addEventListener("pointermove",function(ev){
 if(ev.pointerType==="touch"&&touchMove(ev))return; // active pinch consumed it
 if(vdrag){var vv=mm(ev),vgx=Math.round(vv.x/G)*G,vgy=Math.round(vv.y/G)*G,vo=PCB.outline;
  if(vo&&vo.pts&&vdrag.i<vo.pts.length&&(vo.pts[vdrag.i][0]!==vgx||vo.pts[vdrag.i][1]!==vgy)){
   vo.pts[vdrag.i]=[vgx,vgy];vdrag.moved=true;outlineBboxSync();drawBoardRect();}
  return;}
 if(polyMode&&polyPts){polyCur=mm(ev);drawBoardRect();return;}
 if(outDraw){var om=mm(ev);outDraw.x1=om.x;outDraw.y1=om.y;
  drawBoardRect({x:Math.min(outDraw.x0,outDraw.x1),y:Math.min(outDraw.y0,outDraw.y1),
   w:Math.abs(outDraw.x1-outDraw.x0),h:Math.abs(outDraw.y1-outDraw.y0)});return;}
 if(pan){var r=svg.getBoundingClientRect(),slop=pan.slop||3;
  if(Math.abs(ev.clientX-pan.cx)>slop||Math.abs(ev.clientY-pan.cy)>slop)pan.moved=true;
  if(pan.moved){vb.x=pan.vx-(ev.clientX-pan.cx)*(vb.w/r.width);vb.y=pan.vy-(ev.clientY-pan.cy)*(vb.h/r.height);setVB();}return;}
 if(drawMode){drawShift=ev.shiftKey;drawCur=mm(ev);if(dtrace)ovPaintSoon();return;}
 if(marq){var m=mm(ev);marq.x1=m.x;marq.y1=m.y;
  if(Math.abs(m.x-marq.x0)>0.2||Math.abs(m.y-marq.y0)>0.2)marq.moved=true;
  var ax=Math.min(marq.x0,marq.x1),ay=Math.min(marq.y0,marq.y1),bx=Math.max(marq.x0,marq.x1),by=Math.max(marq.y0,marq.y1);
  marqEl.setAttribute("x",X(ax).toFixed(1));marqEl.setAttribute("y",Y(ay).toFixed(1));
  marqEl.setAttribute("width",((bx-ax)*S).toFixed(1));marqEl.setAttribute("height",((by-ay)*S).toFixed(1));return;}
 if(typeof gdrag!=="undefined"&&gdrag){var gg=snapG(),gm=mm(ev),gdx=Math.round((gm.x-gdrag.sx)/gg)*gg,gdy=Math.round((gm.y-gdrag.sy)/gg)*gg,any=false;
  gdrag.orig.forEach(function(o){var nx=o.x+gdx,ny=o.y+gdy;if(P[o.i].x!==nx||P[o.i].y!==ny){P[o.i].x=nx;P[o.i].y=ny;any=true;}});
  if(any){var gidx=gdrag.orig.map(function(o){return o.i;});
   if(!gdrag.moved){gdrag.moved=true;clearRouteFor(gidx,gdrag.g);}
   gdrag.ct.forEach(function(o){o.t.x1=o.x1+gdx;o.t.y1=o.y1+gdy;o.t.x2=o.x2+gdx;o.t.y2=o.y2+gdy;});
   gdrag.cv.forEach(function(o){o.v.x=o.x+gdx;o.v.y=o.y+gdy;});
   ratsUpdate(gidx);paintSoon();refreshUnplaced();}return;}
 if(typeof drag!=="undefined"&&drag){var dm=mm(ev),dg=snapG();
  var nx=Math.round((dm.x+drag.ox)/dg)*dg,ny=Math.round((dm.y+drag.oy)/dg)*dg,di=drag.i;
  if(nx!==P[di].x||ny!==P[di].y){P[di].x=nx;P[di].y=ny;
   if(!drag.moved){drag.moved=true;clearRouteFor([di]);}ratsUpdate([di]);paintSoon();refreshUnplaced();
   if(selRef===P[di].ref)updatePropLive();}return;}
 // No gesture: hover tracking for the keyboard targets + glow + cursor.
 var hm=mm(ev),hi=partAt(hm.x,hm.y);
 if(hi!==cur){cur=hi;
  var hg=(hi>=0)?grpOf(P[hi].ref):null;
  hoverGrpName=(hg&&grpRigid(hg))?hg:null;
  svg.style.cursor=(outlineMode||polyMode)?"":(hi<0?"":(P[hi].locked?"not-allowed":(RO?"":"grab")));
  paintSoon();}});
function clickPart(ev,i){var m=mm(ev),pd=padAt(i,m.x,m.y);
 if(pd&&pd.net)selNet(pd.net);
 if(!RO)selectComp(P[i].ref);}
svg.addEventListener("pointerup",function(ev){try{svg.releasePointerCapture(ev.pointerId);}catch(e){}
 if(ev.pointerType==="touch")touchUp(ev);
 if(vdrag){var vd=vdrag;vdrag=null;
  if(vd.moved)outlineMsg("outline edited — Save/Update to keep");
  return;}
 if(typeof gdrag!=="undefined"&&gdrag){var gmv=gdrag.moved,gsnap=gdrag.snap,gdn=gdrag.down;gdrag=null;svg.style.cursor="";
  // No movement = a plain click on a rigid-group / multi-selected part —
  // select it like any other part instead of swallowing the click.
  if(gmv){recordUndo(gsnap);fetchScore();}else if(gdn!=null&&gdn>=0)clickPart(ev,gdn);return;}
 if(typeof drag!=="undefined"&&drag){var dmv=drag.moved,dsnap=drag.snap,di2=drag.i;drag=null;svg.style.cursor="";
  if(dmv){recordUndo(dsnap);fetchScore();return;}
  clickPart(ev,di2);return;}
 if(clickCand){var cc=clickCand;clickCand=null;clickPart(ev,cc.i);return;}
 if(outDraw){var d=outDraw;outDraw=null;outlineArm(false);var og=snapG();
  var ax=Math.round(Math.min(d.x0,d.x1)/og)*og,ay=Math.round(Math.min(d.y0,d.y1)/og)*og;
  var bx=Math.round(Math.max(d.x0,d.x1)/og)*og,by=Math.round(Math.max(d.y0,d.y1)/og)*og;
  PCB.outline=(bx-ax>=2&&by-ay>=2)?{x:ax,y:ay,w:bx-ax,h:by-ay}:null;
  drawBoardRect();
  var msg=document.getElementById("pcb-savemsg");
  if(msg){msg.style.color="#8b949e";
   msg.textContent=PCB.outline?"outline set — Save/Update to keep":"outline cleared — Save/Update to keep";}
  return;}
 if(pan){var click=!pan.moved,tapi=pan.tapi;pan=null;svg.style.cursor="";
  if(click){if(tapi>=0)clickPart(ev,tapi);else{selClear();clearSel();selNet(null);}}return;}
 if(marq){var box=marq,mv=marq.moved;if(marqEl&&marqEl.parentNode)marqEl.parentNode.removeChild(marqEl);marqEl=null;marq=null;
  if(mv){var ax=Math.min(box.x0,box.x1),ay=Math.min(box.y0,box.y1),bx=Math.max(box.x0,box.x1),by=Math.max(box.y0,box.y1);
   var pick=[];P.forEach(function(p,i){if(p.x>=ax&&p.x<=bx&&p.y>=ay&&p.y<=by)pick.push(i);});
   clearSel();selSet(pick);}
  else{selClear();clearSel();selNet(null);}return;}});
function viaGeo(){var va=parseFloat((document.getElementById("r-va")||{}).value),
 vd=parseFloat((document.getElementById("r-vd")||{}).value);return {dia:va>0?va:0.4,drill:vd>0?vd:0.2};}
function drawVia(g,wx,wy,dia,drill){var r=Math.max(dia/2*S,2.5),rh=Math.min(Math.max(drill/2*S,1),r*0.7);
 g.appendChild(el("circle",{cx:X(wx).toFixed(1),cy:Y(wy).toFixed(1),r:r.toFixed(1),fill:"#ca8a04"}));
 g.appendChild(el("circle",{cx:X(wx).toFixed(1),cy:Y(wy).toFixed(1),r:rh.toFixed(1),fill:"#fff"}));}
// Drop only the copper belonging to the given parts' nets (a moved part
// invalidates its own routing, everything else stays drawn). Falls back to
// keeping legacy net-less copper ("" — old saves) untouched.
// Copper tagged with a stamp group (t.g — module copper carried in by Stamp)
// lives and dies with its group's RIGID moves instead: it survives net-based
// clearing (other parts of a shared rail moving far away don't invalidate
// it), rides along when its whole group drags/rotates (keepG names the group
// being rigidly moved — the caller transforms that copper itself), and is
// dropped only when its own group is broken apart (a member moved alone).
function clearRouteFor(idxs,keepG){
 if(!((PCB.tracks||[]).length)&&!((PCB.vias||[]).length))return;
 var nets={};idxs.forEach(function(i){(P[i].pads||[]).forEach(function(pd){if(pd.net)nets[pd.net]=1;});});
 var gs={};idxs.forEach(function(i){var g=grpOf(P[i].ref);if(g&&g!==keepG)gs[g]=1;});
 PCB.tracks=(PCB.tracks||[]).filter(function(t){
  if(t.g)return !gs[t.g];
  return !(t.net&&nets[t.net]);});
 PCB.vias=(PCB.vias||[]).filter(function(v){
  if(v.g)return !gs[v.g];
  return !(v.net&&nets[v.net]);});
 PCB.drc=[];drawRoute();drawDrc();}
function drawRoute(){ovPaintSoon();} // routed copper lives on the canvas overlay
function clrVal(){var ci=document.getElementById("r-cl"),c=ci?parseFloat(ci.value):NaN;
 return (c>0)?c:(PCB.clr||0.127);}
function drawClr(){ovPaintSoon();} // clearance halos live on the canvas overlay
var clrCb=document.getElementById("r-clr-show");
if(clrCb)clrCb.addEventListener("change",drawClr);
var clrIn=document.getElementById("r-cl");
if(clrIn)clrIn.addEventListener("input",drawClr);
// ── Hand routing: draw tracks + vias (X) ────────────────────────────────
// KiCad-style manual routing on the same PCB.tracks/PCB.vias model the
// autorouter fills: click a pad to start (net + layer come from the pad),
// click to fix 45°/grid-snapped corners (Shift = free angle), V drops a via
// and flips layer, click a same-net pad / double-click / Enter to finish,
// Backspace steps back, Esc ends (then exits the mode). Right-click deletes
// the track/via under the cursor. Copper persists through the normal layout
// Save/Update (routes ride the sidecar), so a module's hand routing saved on
// its own page is exactly what Stamp later carries onto a parent board.
var drawMode=false,dtrace=null,drawCur=null,drawShift=false;
function trackW(){var v=parseFloat((document.getElementById("r-tw")||{}).value);return v>0?v:0.25;}
function drawBtnSync(){var b=document.getElementById("pcb-draw");if(!b)return;
 b.classList.toggle("on",drawMode);
 var al=activeLayer?"B.Cu":"F.Cu";
 b.textContent=drawMode?(dtrace?("✎ "+nLeaf(dtrace.net)+" · "+(dtrace.l?"B.Cu":"F.Cu")):("✎ click a pad… ["+al+"]")):"✎ Draw";}
function drawModeSet(on){if(RO)return;drawMode=on;if(!on)dtrace=null;
 if(on&&outlineMode)outlineArm(false);
 if(on&&polyMode)polyArm(false);
 svg.style.cursor=on?"crosshair":"";drawBtnSync();ovPaintSoon();}
// 45°-family snap from the last vertex: H / V / diagonal by dominance, on
// the grid. Shift = free angle (grid only).
function drawSnap(m,free){var dg=snapG(),gx=Math.round(m.x/dg)*dg,gy=Math.round(m.y/dg)*dg;
 if(free||!dtrace)return {x:gx,y:gy};
 var ax=dtrace.lx,ay=dtrace.ly,dx=gx-ax,dy=gy-ay;
 if(Math.abs(dx)>2*Math.abs(dy))return {x:gx,y:ay};
 if(Math.abs(dy)>2*Math.abs(dx))return {x:ax,y:gy};
 var ml=Math.min(Math.abs(dx),Math.abs(dy));
 return {x:ax+(dx<0?-ml:ml),y:ay+(dy<0?-ml:ml)};}
function padTarget(m){var i=partAt(m.x,m.y);if(i<0)return null;
 var pd=padAt(i,m.x,m.y);if(!pd)return null;
 var c=wpt(i,pd.x,pd.y);
 return {i:i,pd:pd,x:c.x,y:c.y,net:pd.net||"",l:(P[i].side==="bottom")?1:0};}
function segDist(px,py,t){var dx=t.x2-t.x1,dy=t.y2-t.y1,L2=dx*dx+dy*dy;
 var u=L2>0?((px-t.x1)*dx+(py-t.y1)*dy)/L2:0;u=Math.max(0,Math.min(1,u));
 return Math.hypot(px-(t.x1+u*dx),py-(t.y1+u*dy));}
function drawHitTrack(m){var best=null,bd=1e9;(PCB.tracks||[]).forEach(function(t){
 var d=segDist(m.x,m.y,t),tol=Math.max((t.w||0.25)/2+0.15,0.3);
 if(d<tol&&d<bd){bd=d;best=t;}});return best;}
function drawHitVia(m){var best=null,bd=1e9;(PCB.vias||[]).forEach(function(v){
 var d=Math.hypot(m.x-v.x,m.y-v.y),tol=(v.d||0.4)/2+0.15;
 if(d<tol&&d<bd){bd=d;best=v;}});return best;}
function routeStatMsg(txt,err){var msg=document.getElementById("pcb-savemsg");
 if(msg){msg.style.color=err?"#f85149":"#8b949e";
  msg.textContent=txt||"copper edited — Save/Update to keep";}}
// ── Live DRC while hand-routing ─────────────────────────────────────────
// A drawn segment/via is validated against SAME-LAYER foreign-net copper
// (pads, tracks, vias) at the active net's clearance BEFORE it commits — a
// dead short can't be clicked in (KiCad-style). Geometry mirrors the server's
// drc.check (bbox pads, segment/point distance), kept O(nearby) by a coarse
// distance gate; the debounced /api/pcb-drc is the authoritative re-check.
// Nets collapse the same way pad tags do (netKey — cut at the first '.').
function netCollapse(s){var i=String(s).indexOf(".");return i<0?s:String(s).slice(0,i);}
function netClrFor(net){var m=PCB.netclr||{},c=m[netCollapse(net)];return (c>0)?c:(PCB.clr||0.127);}
function sameNet(a,b){return a&&b&&a===b;}
// Distance from point (px,py) to segment (t) — world mm.
function ptSegDist(px,py,x1,y1,x2,y2){var dx=x2-x1,dy=y2-y1,L2=dx*dx+dy*dy;
 var u=L2>0?((px-x1)*dx+(py-y1)*dy)/L2:0;u=Math.max(0,Math.min(1,u));
 return Math.hypot(px-(x1+u*dx),py-(y1+u*dy));}
// Closest distance between two segments (world mm). Sampled endpoints +
// point-to-segment on both — exact enough for a clearance gate at these sizes.
function segSegDist(ax1,ay1,ax2,ay2,bx1,by1,bx2,by2){
 return Math.min(ptSegDist(ax1,ay1,bx1,by1,bx2,by2),ptSegDist(ax2,ay2,bx1,by1,bx2,by2),
  ptSegDist(bx1,by1,ax1,ay1,ax2,ay2),ptSegDist(bx2,by2,ax1,ay1,ax2,ay2));}
// World-space pad boxes on a given signal layer (SMD pads only clash on their
// own side; thru/drilled pads on every layer). Cached per pointermove burst.
function padBoxesOn(layer){var out=[];
 P.forEach(function(p,i){var bot=(p.side==="bottom")?1:0;
  (p.pads||[]).forEach(function(pd){var thru=(pd.drill>0);
   if(!thru&&bot!==layer)return;
   var r=wrect(i,pd);out.push({x0:r.x0,y0:r.y0,x1:r.x1,y1:r.y1,net:pd.net||"",part:i});});});
 return out;}
// Does a proposed track (x1,y1)-(x2,y2) on `layer`/`net` (half-width hw) come
// closer than clearance to any FOREIGN copper on the same layer? Returns the
// nearest foreign feature's clearance breach, else null. `skip` tracks (the
// trace's own just-laid segments) are ignored so a bend never self-flags.
function segViolation(x1,y1,x2,y2,layer,net,hw,skip){var clr=netClrFor(net);
 var midx=(x1+x2)/2,midy=(y1+y2)/2,slen=Math.hypot(x2-x1,y2-y1);
 var reach=slen/2+hw+clr+1.5; // coarse cull radius
 // foreign pads
 var pads=padBoxesOn(layer);
 for(var i=0;i<pads.length;i++){var pb=pads[i];
  var pcx=(pb.x0+pb.x1)/2,pcy=(pb.y0+pb.y1)/2;
  if(Math.hypot(pcx-midx,pcy-midy)>reach+Math.hypot(pb.x1-pb.x0,pb.y1-pb.y0)/2)continue;
  if(sameNet(pb.net,net))continue;
  // distance from segment to the pad rect (edge-to-edge): sample pad corners +
  // centre against the segment, subtract nothing (box) then the trace half-width.
  var d=Math.min(
   ptSegDist(pb.x0,pb.y0,x1,y1,x2,y2),ptSegDist(pb.x1,pb.y0,x1,y1,x2,y2),
   ptSegDist(pb.x1,pb.y1,x1,y1,x2,y2),ptSegDist(pb.x0,pb.y1,x1,y1,x2,y2),
   ptSegDist(pcx,pcy,x1,y1,x2,y2));
  // If the segment passes through the box, distance is 0 → treat as overlap.
  if(segHitsBox(x1,y1,x2,y2,pb.x0,pb.y0,pb.x1,pb.y1))d=0;
  if(d-hw<clr-1e-6)return {x:midx,y:midy,k:"track↔pad"};}
 // foreign tracks (skip the trace's own segments)
 var ts=PCB.tracks||[];
 for(var j=0;j<ts.length;j++){var t=ts[j];if(t.l!==layer)continue;if(skip&&skip.indexOf(t)>=0)continue;
  if(sameNet(t.net,net))continue;
  var d2=segSegDist(x1,y1,x2,y2,t.x1,t.y1,t.x2,t.y2)-hw-(t.w||0.25)/2;
  if(d2<clr-1e-6)return {x:midx,y:midy,k:"track↔track"};}
 // foreign vias
 var vs=PCB.vias||[];
 for(var kk=0;kk<vs.length;kk++){var v=vs[kk];if(sameNet(v.net,net))continue;
  var d3=ptSegDist(v.x,v.y,x1,y1,x2,y2)-hw-(v.d||0.4)/2;
  if(d3<clr-1e-6)return {x:midx,y:midy,k:"via↔track"};}
 return null;}
// Segment-box intersection (world mm) — true if the segment enters the rect.
function segHitsBox(x1,y1,x2,y2,bx0,by0,bx1,by1){
 if((x1>=bx0&&x1<=bx1&&y1>=by0&&y1<=by1)||(x2>=bx0&&x2<=bx1&&y2>=by0&&y2<=by1))return true;
 // cheap: test the 4 box edges against the segment
 function segX(ax,ay,bx,by,cx,cy,dx,dy){var d1=(dy-cy)*(bx-ax)-(dx-cx)*(by-ay);if(Math.abs(d1)<1e-12)return false;
  var ua=((dx-cx)*(ay-cy)-(dy-cy)*(ax-cx))/d1,ub=((bx-ax)*(ay-cy)-(by-ay)*(ax-cx))/d1;
  return ua>=0&&ua<=1&&ub>=0&&ub<=1;}
 return segX(x1,y1,x2,y2,bx0,by0,bx1,by0)||segX(x1,y1,x2,y2,bx1,by0,bx1,by1)||
  segX(x1,y1,x2,y2,bx1,by1,bx0,by1)||segX(x1,y1,x2,y2,bx0,by1,bx0,by0);}
// A proposed via at (x,y) on `net`: check foreign copper on BOTH layers.
function viaViolation(x,y,net,dia){var clr=netClrFor(net),vr=(dia||0.4)/2;
 for(var L=0;L<2;L++){var pads=padBoxesOn(L);
  for(var i=0;i<pads.length;i++){var pb=pads[i];if(sameNet(pb.net,net))continue;
   var d=Math.hypot(Math.max(pb.x0-x,0,x-pb.x1),Math.max(pb.y0-y,0,y-pb.y1))-vr;
   if(d<clr-1e-6)return {x:x,y:y,k:"via↔pad"};}}
 var ts=PCB.tracks||[];
 for(var j=0;j<ts.length;j++){var t=ts[j];if(sameNet(t.net,net))continue;
  var d2=ptSegDist(x,y,t.x1,t.y1,t.x2,t.y2)-vr-(t.w||0.25)/2;
  if(d2<clr-1e-6)return {x:x,y:y,k:"via↔track"};}
 var vs=PCB.vias||[];
 for(var kk=0;kk<vs.length;kk++){var v=vs[kk];if(sameNet(v.net,net))continue;
  var d3=Math.hypot(v.x-x,v.y-y)-vr-(v.d||0.4)/2;
  if(d3<clr-1e-6)return {x:x,y:y,k:"via↔via"};}
 return null;}
// ── Magnetic snap while drawing (KiCad-style) ───────────────────────────
// Pad centres and same-net existing track endpoints within a small SCREEN
// radius override the grid snap so a trace lands exactly on copper. Shift
// (free angle) keeps grid-only. Returns {x,y,mag:true} on a magnet hit.
function magSnap(m,net){var pxr=9; // screen-px capture radius
 var wr=pxr/S*(vb.w/VBW); // convert px→world mm at current zoom
 var best=null,bd=wr;
 // pad centres (prefer same-net, but any pad is a useful anchor)
 P.forEach(function(p,i){(p.pads||[]).forEach(function(pd){var c=wpt(i,pd.x,pd.y);
  var d=Math.hypot(c.x-m.x,c.y-m.y);if(d<bd){bd=d;best={x:c.x,y:c.y,mag:true};}});});
 // same-net track endpoints
 (PCB.tracks||[]).forEach(function(t){if(net&&t.net&&t.net!==net)return;
  [[t.x1,t.y1],[t.x2,t.y2]].forEach(function(e){var d=Math.hypot(e[0]-m.x,e[1]-m.y);
   if(d<bd){bd=d;best={x:e[0],y:e[1],mag:true};}});});
 return best;}
function drawSeg(x2,y2){if(Math.abs(x2-dtrace.lx)<1e-9&&Math.abs(y2-dtrace.ly)<1e-9)return;
 PCB.tracks=PCB.tracks||[];
 var seg={x1:dtrace.lx,y1:dtrace.ly,x2:x2,y2:y2,l:dtrace.l,w:dtrace.w,net:dtrace.net};
 PCB.tracks.push(seg);(dtrace.laid=dtrace.laid||[]).push(seg);
 dtrace.lx=x2;dtrace.ly=y2;dtrace.n++;}
function drawEnd(){if(dtrace&&dtrace.n>0){recordUndo(dtrace.undo);scheduleDrc();}
 dtrace=null;drawBtnSync();ovPaintSoon();routeStatMsg();}
function drawStart(net,layer,x,y){return {net:net,l:layer,w:trackW(),lx:x,ly:y,n:0,undo:snapAll(),laid:[]};}
function drawClick(m,shift){
 if(!dtrace){var pt=padTarget(m);
  if(pt&&pt.net){dtrace=drawStart(pt.net,pt.l,pt.x,pt.y);drawBtnSync();ovPaintSoon();return;}
  var v=drawHitVia(m);
  if(v&&v.net){dtrace=drawStart(v.net,activeLayer,v.x,v.y);drawBtnSync();ovPaintSoon();return;}
  var t=drawHitTrack(m);
  if(t&&t.net){var d1=Math.hypot(m.x-t.x1,m.y-t.y1),d2=Math.hypot(m.x-t.x2,m.y-t.y2);
   dtrace=drawStart(t.net,t.l||0,d1<=d2?t.x1:t.x2,d1<=d2?t.y1:t.y2);
   drawBtnSync();ovPaintSoon();return;}
  routeStatMsg("start a trace on a pad (or existing copper)",true);return;}
 var pt2=padTarget(m);
 if(pt2&&pt2.net&&pt2.net===dtrace.net){
  if(drawTargetViolates(pt2.x,pt2.y)){routeStatMsg("that would violate clearance — reroute the last leg",true);return;}
  drawSeg(pt2.x,pt2.y);drawEnd();return;}
 if(pt2&&pt2.net&&pt2.net!==dtrace.net){
  routeStatMsg("that pad is on "+nLeaf(pt2.net)+" — trace is on "+nLeaf(dtrace.net),true);return;}
 var s=drawTarget(m,shift);
 if(drawTargetViolates(s.x,s.y)){routeStatMsg("that segment violates clearance (drawn red) — move the corner",true);return;}
 drawSeg(s.x,s.y);drawBtnSync();ovPaintSoon();}
// Resolve the committed target point for a click: magnet first (unless Shift),
// then the 45°/grid snap.
function drawTarget(m,shift){if(!shift){var mg=magSnap(m,dtrace&&dtrace.net);if(mg)return mg;}
 return drawSnap(m,shift);}
// Would a segment from the last vertex to (x,y) breach clearance?
function drawTargetViolates(x,y){if(!dtrace)return false;
 return !!segViolation(dtrace.lx,dtrace.ly,x,y,dtrace.l,dtrace.net,dtrace.w/2,dtrace.laid);}
function drawViaHere(){if(!dtrace)return;var vg=viaGeo();
 if(viaViolation(dtrace.lx,dtrace.ly,dtrace.net,vg.dia)){
  routeStatMsg("a via here violates clearance — move first",true);return;}
 PCB.vias=PCB.vias||[];
 PCB.vias.push({x:dtrace.lx,y:dtrace.ly,d:vg.dia,drill:vg.drill,net:dtrace.net});
 dtrace.l=dtrace.l?0:1;activeLayer=dtrace.l;syncActiveLayer();drawBtnSync();ovPaintSoon();}
function drawBack(){if(!dtrace)return;
 var ts=PCB.tracks||[],last=ts.length?ts[ts.length-1]:null;
 if(dtrace.n>0&&last&&last.x2===dtrace.lx&&last.y2===dtrace.ly&&last.net===dtrace.net){
  ts.pop();if(dtrace.laid)dtrace.laid.pop();dtrace.lx=last.x1;dtrace.ly=last.y1;dtrace.n--;ovPaintSoon();}
 else drawEnd();}
function drawDelAt(m){var v=drawHitVia(m);
 if(v){recordUndo();PCB.vias=PCB.vias.filter(function(q){return q!==v;});routeStatMsg();ovPaintSoon();scheduleDrc();return;}
 var t=drawHitTrack(m);
 if(t){recordUndo();PCB.tracks=PCB.tracks.filter(function(q){return q!==t;});routeStatMsg();ovPaintSoon();scheduleDrc();}}
// Rubber-band preview segment from the last vertex to the (snapped) cursor.
// A magnet hit snaps to a pad/track endpoint; a clearance-violating preview
// draws RED (dashed) so the user sees a dead short before committing it.
function paintDraw(ctx){if(!drawMode||!dtrace||!drawCur)return;
 var s=drawTarget(drawCur,drawShift);
 var bad=!!segViolation(dtrace.lx,dtrace.ly,s.x,s.y,dtrace.l,dtrace.net,dtrace.w/2,dtrace.laid);
 ctx.save();ctx.globalAlpha=bad?0.9:0.7;ctx.lineCap="round";ctx.setLineDash([4,3]);
 ctx.strokeStyle=bad?"#ff4d4d":((dtrace.l==0)?"#f85149":"#388bfd");
 ctx.lineWidth=Math.max(dtrace.w*S,1.2);
 ctx.beginPath();ctx.moveTo(X(dtrace.lx),Y(dtrace.ly));ctx.lineTo(X(s.x),Y(s.y));ctx.stroke();
 // magnet indicator: a small ring at a snapped target
 if(s.mag){ctx.setLineDash([]);ctx.globalAlpha=0.95;ctx.strokeStyle="#7ee787";ctx.lineWidth=1.4;
  ctx.beginPath();ctx.arc(X(s.x),Y(s.y),4,0,6.2832);ctx.stroke();}
 ctx.restore();}
var drawBtn=document.getElementById("pcb-draw");
if(drawBtn&&!RO)drawBtn.addEventListener("click",function(){drawModeSet(!drawMode);});
svg.addEventListener("dblclick",function(ev){if(drawMode&&dtrace){ev.preventDefault();drawEnd();}});
svg.addEventListener("contextmenu",function(ev){if(!drawMode)return;ev.preventDefault();
 if(dtrace){drawEnd();return;}
 drawDelAt(mm(ev));});
document.addEventListener("keydown",function(ev){if(RO||kbTyping(ev.target))return;
 if((ev.key=="x"||ev.key=="X")&&!ev.ctrlKey&&!ev.metaKey){ev.preventDefault();drawModeSet(!drawMode);return;}
 if(!drawMode)return;
 if(ev.key=="v"||ev.key=="V"){ev.preventDefault();drawViaHere();return;}
 if(ev.key=="Backspace"){ev.preventDefault();drawBack();return;}
 if(ev.key=="Enter"&&dtrace){ev.preventDefault();drawEnd();return;}});
function drawDrc(){while(gD.firstChild)gD.removeChild(gD.firstChild);
 if(!viewSt.vis.drc)return;
 var cb=document.getElementById("r-drc-show"); if(cb&&!cb.checked)return;
 (PCB.drc||[]).forEach(function(d){var cx=X(d.x),cy=Y(d.y);
   var t=el("title",{}); t.textContent=d.k+" — gap "+d.gap.toFixed(3)+" mm < "+d.clr+" mm";
   var c=el("circle",{cx:cx.toFixed(1),cy:cy.toFixed(1),r:8,fill:"none",stroke:"#ef4444","stroke-width":2}); c.appendChild(t);
   gD.appendChild(c);
   gD.appendChild(el("circle",{cx:cx.toFixed(1),cy:cy.toFixed(1),r:2.4,fill:"#ef4444"}));});}
var drcCb=document.getElementById("r-drc-show");
if(drcCb)drcCb.addEventListener("change",drawDrc);
// ── Auto-DRC after copper edits (debounced ~800 ms) ─────────────────────
// Every copper mutation (draw/delete/Stamp/route apply) and every Save
// schedules a server DRC of the CURRENT poses + copper via /api/pcb-drc, so
// the DRC markers + count chip stay honest without waiting for a Route click.
// The live client-side check blocks obvious shorts during drawing; this is the
// authoritative re-check (all 8 checks, incl. annular + board-edge).
var drcTimer=null,drcSeq=0;
function drcChip(n){var e=document.getElementById("r-drc");if(!e)return;
 if(n<0){e.className="route-stat";e.textContent="checking…";return;}
 e.className="route-stat "+(n?"err":"ok");e.textContent=n?(n+" DRC violation(s)"):"DRC clean ✓";}
function runDrcNow(){if(RO)return;var seq=++drcSeq;drcChip(-1);
 var payload={parts:P.map(function(p){return {ref:p.ref,x:p.x,y:p.y,rot:p.rot||0,side:p.side||"top"};}),
  tracks:PCB.tracks||[],vias:PCB.vias||[],clearance:clrVal(),outline:PCB.outline||null};
 fetch("/api/pcb-drc/"+encodeURIComponent(PCB.name)+subq(),{method:"POST",
   headers:{"Content-Type":"application/json"},body:JSON.stringify(payload)})
  .then(function(r){if(!r.ok)throw 0;return r.json();})
  .then(function(j){if(seq!==drcSeq)return; // a newer check superseded this one
    PCB.drc=j.drc||[];drawDrc();drcChip((j.drc||[]).length);})
  .catch(function(){if(seq===drcSeq)drcChip(0);});}
function scheduleDrc(){if(RO)return;if(drcTimer)clearTimeout(drcTimer);
 drcTimer=setTimeout(function(){drcTimer=null;runDrcNow();},800);}
function setStat(id,cls,txt){var e=document.getElementById(id);
 if(e){e.className="route-stat"+(cls?" "+cls:"");e.textContent=txt;}}
function clearRoute(){if(!(PCB.tracks&&PCB.tracks.length)&&!(PCB.vias&&PCB.vias.length)&&!(PCB.drc&&PCB.drc.length))return;
 PCB.tracks=[];PCB.vias=[];PCB.drc=[];drawRoute();drawClr();drawDrc();setStat("r-stat","","");setStat("r-drc","","");setStat("r-rp","","");}
var courtState=null;
function partByRef(ref){for(var i=0;i<P.length;i++)if(P[i].ref===ref)return P[i];return null;}
function gceil(v){return Math.ceil(v/G-1e-9)*G;}
function gfloor(v){return Math.floor(v/G+1e-9)*G;}
// Raw pad bounding box (footprint-local mm), or null for a padless part.
// The courtyard may never cut inside this box + the clearance margin.
function padBBox(p){if(!(p.pads||[]).length)return null;
 var x0=1/0,y0=1/0,x1=-1/0,y1=-1/0;
 p.pads.forEach(function(pd){x0=Math.min(x0,pd.x-pd.w/2);x1=Math.max(x1,pd.x+pd.w/2);
  y0=Math.min(y0,pd.y-pd.h/2);y1=Math.max(y1,pd.y+pd.h/2);});
 return {x0:x0,y0:y0,x1:x1,y1:y1};}
// The modal preview draws the REAL footprint — silk + fab + pads through the
// shared FP engine, fetched once per open from /api/footprint/:fp — in mm
// coordinates, with the editable courtyard box on top. The box is a free
// rectangle (courtState.box {x0,y0,x1,y1}, footprint-local): each edge drags
// independently, snapping to the G grid and clamped to the pads + margin, so
// an off-origin footprint (connector pads hanging off one side) gets a
// courtyard that hugs it instead of a forced origin-centred one. The viewBox
// freezes for the duration of a drag (courtState.vb) so the scale doesn't
// shift under the cursor, then refits on release.
function cn3(v){return (+v).toFixed(3);}
function courtDraw(p,box){var s=document.getElementById("court-svg");
 var c=courtState||{},d=c.fpdata||{pads:p.pads||[]};
 var mnx=box.x0,mny=box.y0,mxx=box.x1,mxy=box.y1;
 if(d.bbox){mnx=Math.min(mnx,d.bbox.x);mny=Math.min(mny,d.bbox.y);
  mxx=Math.max(mxx,d.bbox.x+d.bbox.w);mxy=Math.max(mxy,d.bbox.y+d.bbox.h);}
 (d.pads||[]).forEach(function(pd){mnx=Math.min(mnx,pd.x-pd.w/2);mxx=Math.max(mxx,pd.x+pd.w/2);
  mny=Math.min(mny,pd.y-pd.h/2);mxy=Math.max(mxy,pd.y+pd.h/2);});
 var padm=Math.max(mxx-mnx,mxy-mny)*0.09+0.3;
 var vbb=c.vb||{x:mnx-padm,y:mny-padm,w:(mxx-mnx)+2*padm,h:(mxy-mny)+2*padm};
 FP.drawFootprint(s,{bbox:vbb,pads:d.pads||[],silk:d.silk,fab:d.fab,courtyard:{}},{bg:false});
 var edit=!(p.fb||!p.fp);
 s.appendChild(FP.el("rect",{x:cn3(box.x0),y:cn3(box.y0),width:cn3(box.x1-box.x0),height:cn3(box.y1-box.y0),
  fill:"none",stroke:edit?"#58a6ff":"#8b949e","stroke-width":0.06,"stroke-dasharray":"0.25 0.15"}));
 // part-origin cross, so the box's offset from the origin stays readable
 var tt=Math.max(vbb.w,vbb.h)/40;
 s.appendChild(FP.el("line",{x1:cn3(-tt),y1:0,x2:cn3(tt),y2:0,stroke:"#6e7681","stroke-width":0.04}));
 s.appendChild(FP.el("line",{x1:0,y1:cn3(-tt),x2:0,y2:cn3(tt),stroke:"#6e7681","stroke-width":0.04}));
 if(edit)courtHandles(s,box,vbb);}
function courtHandles(s,box,vbb){
 var t=Math.max(vbb.w,vbb.h)/13;   // grab-strip thickness (mm) — ~constant on screen
 var w=box.x1-box.x0,h=box.y1-box.y0;
 function strip(x,y,sw,sh,cur,edge){var e=FP.el("rect",{x:cn3(x),y:cn3(y),width:cn3(Math.max(sw,0.01)),height:cn3(Math.max(sh,0.01)),
   fill:"none","pointer-events":"all","data-cedge":edge});e.style.cursor=cur;s.appendChild(e);}
 strip(box.x1-t/2,box.y0+t/2,t,h-t,"ew-resize","e");
 strip(box.x0-t/2,box.y0+t/2,t,h-t,"ew-resize","w");
 strip(box.x0+t/2,box.y1-t/2,w-t,t,"ns-resize","s");
 strip(box.x0+t/2,box.y0-t/2,w-t,t,"ns-resize","n");
 strip(box.x1-t/2,box.y1-t/2,t,t,"nwse-resize","se");
 strip(box.x0-t/2,box.y0-t/2,t,t,"nwse-resize","nw");
 strip(box.x1-t/2,box.y0-t/2,t,t,"nesw-resize","ne");
 strip(box.x0-t/2,box.y1-t/2,t,t,"nesw-resize","sw");
 var cx=(box.x0+box.x1)/2,cy=(box.y0+box.y1)/2;
 [[box.x1,box.y1],[box.x1,box.y0],[box.x0,box.y1],[box.x0,box.y0],
  [box.x1,cy],[box.x0,cy],[cx,box.y1],[cx,box.y0]].forEach(function(cp){
  s.appendChild(FP.el("rect",{x:cn3(cp[0]-t/6),y:cn3(cp[1]-t/6),width:cn3(t/3),height:cn3(t/3),
   fill:"#58a6ff","pointer-events":"none"}));});}
// Per-edge clamps: an edge snaps to the grid but can never cut inside the
// pads + margin, nor cross its opposite edge.
function courtClampX0(v){var c=courtState,lim=c.pb?gfloor(c.pb.x0-c.cm):c.box.x1-G;
 return Math.min(Math.round(v/G)*G,Math.min(lim,c.box.x1-G));}
function courtClampX1(v){var c=courtState,lim=c.pb?gceil(c.pb.x1+c.cm):c.box.x0+G;
 return Math.max(Math.round(v/G)*G,Math.max(lim,c.box.x0+G));}
function courtClampY0(v){var c=courtState,lim=c.pb?gfloor(c.pb.y0-c.cm):c.box.y1-G;
 return Math.min(Math.round(v/G)*G,Math.min(lim,c.box.y1-G));}
function courtClampY1(v){var c=courtState,lim=c.pb?gceil(c.pb.y1+c.cm):c.box.y0+G;
 return Math.max(Math.round(v/G)*G,Math.max(lim,c.box.y0+G));}
function courtBox(){var c=courtState;
 if(c.mode=="offset"&&c.pb)return {x0:gfloor(c.pb.x0-c.offset),y0:gfloor(c.pb.y0-c.offset),
  x1:gceil(c.pb.x1+c.offset),y1:gceil(c.pb.y1+c.offset)};
 return {x0:c.box.x0,y0:c.box.y0,x1:c.box.x1,y1:c.box.y1};}
function courtRefresh(){if(!courtState)return;var b=courtBox();courtDraw(courtState.p,b);
 var cx=(b.x0+b.x1)/2,cy=(b.y0+b.y1)/2;
 document.getElementById("court-full").textContent="full "+(b.x1-b.x0).toFixed(2)+" \u00d7 "+(b.y1-b.y0).toFixed(2)
  +" mm \u00b7 centre ("+cx.toFixed(2)+", "+cy.toFixed(2)+")";}
function courtSetMode(m){if(!courtState)return;courtState.mode=m;
 document.getElementById("court-fields-size").hidden=(m!="size");
 document.getElementById("court-fields-offset").hidden=(m!="offset");courtRefresh();}
var COURT_EDGE_IDS=["court-x0","court-y0","court-x1","court-y1"];
function courtSyncInputs(){var c=courtState;if(!c)return;
 var v=[c.box.x0,c.box.y0,c.box.x1,c.box.y1];
 COURT_EDGE_IDS.forEach(function(id,i){var e=document.getElementById(id);if(e)e.value=v[i].toFixed(2);});}
function openCourt(ref){var p=partByRef(ref);if(!p)return;var cm=PCB.cmargin||0.15;
 var pb=padBBox(p);
 courtState={p:p,fp:p.fp,mode:"size",offset:cm,cm:cm,pb:pb,fpdata:null,vb:null,
  box:{x0:(p.ccx||0)-p.hw,y0:(p.ccy||0)-p.hh,x1:(p.ccx||0)+p.hw,y1:(p.ccy||0)+p.hh}};
 document.getElementById("court-title").textContent=p.fp+"  \u00b7  "+p.ref;
 var offI=document.getElementById("court-off");
 var sv=document.getElementById("court-save"),note=document.getElementById("court-note"),msg=document.getElementById("court-msg");
 msg.textContent="";offI.value=cm.toFixed(2);
 var fab=p.fb||!p.fp,noPads=!pb;
 sv.disabled=fab;offI.disabled=fab||noPads;
 COURT_EDGE_IDS.forEach(function(id){var e=document.getElementById(id);if(e)e.disabled=fab;});
 courtSyncInputs();
 document.querySelectorAll("input[name=court-mode]").forEach(function(r){r.checked=(r.value=="size");r.disabled=fab||(r.value=="offset"&&noPads);});
 courtSetMode("size");
 note.textContent=fab?"Synthesized placeholder box (no footprint file) \u2014 courtyard can't be edited.":
  "Drag any edge or corner \u2014 each edge moves independently (the box needn't be centred on the part origin, marked +) "+
  "and snaps to the "+G.toFixed(2)+" mm grid, never cutting inside the pads. Pad offset instead holds that gap outside the pads on every side. "+
  "Saving rewrites lib/footprints/"+p.fp+".sexp and applies to every design using it.";
 document.getElementById("court-modal").hidden=false;
 // Real footprint art (silk + fab + true pad shapes) for the preview; the
 // placement pads already drawn are the fallback if this fetch fails.
 if(!fab)fetch("/api/footprint/"+encodeURIComponent(p.fp))
  .then(function(r){return r.ok?r.json():null;})
  .then(function(d){if(d&&courtState&&courtState.fp===p.fp){courtState.fpdata=d;courtRefresh();}})
  .catch(function(){});}
function courtClose(){document.getElementById("court-modal").hidden=true;courtState=null;}
document.querySelectorAll("[data-court-ref]").forEach(function(b){
 b.addEventListener("click",function(){openCourt(b.getAttribute("data-court-ref"));});});
var cxBtn=document.getElementById("court-x"),ccBtn=document.getElementById("court-cancel"),modalBg=document.getElementById("court-modal");
if(cxBtn)cxBtn.addEventListener("click",courtClose);
if(ccBtn)ccBtn.addEventListener("click",courtClose);
if(modalBg)modalBg.addEventListener("click",function(ev){if(ev.target===modalBg)courtClose();});
document.querySelectorAll("input[name=court-mode]").forEach(function(r){
 r.addEventListener("change",function(){if(r.checked)courtSetMode(r.value);});});
// Drag-resize: pointerdown on an edge/corner grab strip (data-cedge) starts a
// gesture; each move snaps that edge to the grid with the pad clamp. A drag in
// offset mode adopts the shown box then switches to size mode, so the rect
// never jumps under the cursor.
(function(){var s=document.getElementById("court-svg");if(!s)return;
 var cd=null;
 function courtMm(ev){var r=s.getBoundingClientRect(),vb=s.viewBox.baseVal;
  if(!vb||!vb.width||!r.width)return null;
  var sc=Math.min(r.width/vb.width,r.height/vb.height);
  var ox=(r.width-vb.width*sc)/2,oy=(r.height-vb.height*sc)/2;
  return {x:vb.x+(ev.clientX-r.left-ox)/sc,y:vb.y+(ev.clientY-r.top-oy)/sc};}
 s.addEventListener("pointerdown",function(ev){
  var edge=ev.target&&ev.target.getAttribute&&ev.target.getAttribute("data-cedge");
  if(!edge||!courtState)return;
  ev.preventDefault();
  if(courtState.mode!="size"){courtState.box=courtBox();
   document.querySelectorAll("input[name=court-mode]").forEach(function(r){r.checked=(r.value=="size");});
   courtSetMode("size");courtSyncInputs();}
  var vb=s.viewBox.baseVal;courtState.vb={x:vb.x,y:vb.y,w:vb.width,h:vb.height};
  cd={edge:edge};try{s.setPointerCapture(ev.pointerId);}catch(e){}});
 s.addEventListener("pointermove",function(ev){if(!cd||!courtState)return;
  var m=courtMm(ev);if(!m)return;var c=courtState;
  if(cd.edge.indexOf("e")>=0)c.box.x1=courtClampX1(m.x);
  if(cd.edge.indexOf("w")>=0)c.box.x0=courtClampX0(m.x);
  if(cd.edge.indexOf("n")>=0)c.box.y0=courtClampY0(m.y);
  if(cd.edge.indexOf("s")>=0)c.box.y1=courtClampY1(m.y);
  courtSyncInputs();courtRefresh();});
 function courtDragEnd(){if(!cd)return;cd=null;
  if(courtState){courtState.vb=null;courtRefresh();}}
 s.addEventListener("pointerup",courtDragEnd);
 s.addEventListener("pointercancel",courtDragEnd);})();
COURT_EDGE_IDS.forEach(function(id,idx){var e=document.getElementById(id);if(!e)return;
 e.addEventListener("change",function(){if(!courtState)return;var v=parseFloat(e.value);
  if(isNaN(v)){courtSyncInputs();return;}
  var c=courtState;
  if(idx===0)c.box.x0=courtClampX0(v);else if(idx===1)c.box.y0=courtClampY0(v);
  else if(idx===2)c.box.x1=courtClampX1(v);else c.box.y1=courtClampY1(v);
  courtSyncInputs();courtRefresh();});});
var offI2=document.getElementById("court-off");
if(offI2)offI2.addEventListener("change",function(){if(!courtState)return;var v=parseFloat(offI2.value);
 if(!(v>=0))v=0;v=Math.round(v/0.05)*0.05;courtState.offset=v;offI2.value=v.toFixed(2);courtRefresh();});
var csv=document.getElementById("court-save");
if(csv)csv.addEventListener("click",function(){if(!courtState||!courtState.fp)return;
 var msg=document.getElementById("court-msg");msg.style.color="#8b949e";msg.textContent="saving\u2026";
 var b=courtBox();
 var body=courtState.mode=="offset"?{fp:courtState.fp,mode:"offset",offset:courtState.offset}
   :{fp:courtState.fp,mode:"rect",x0:b.x0,y0:b.y0,x1:b.x1,y1:b.y1};
 fetch("/api/courtyard/"+encodeURIComponent(PCB.name),{method:"POST",headers:{"Content-Type":"application/json"},
   body:JSON.stringify(body)})
  .then(function(r){if(!r.ok)throw 0;return r.json();})
  .then(function(){msg.style.color="#3fb950";msg.textContent="saved \u2713 \u2014 rebuilding";
    window.location="/pcb-layout/"+encodeURIComponent(PCB.name)+"?regen=1";})
  .catch(function(){msg.style.color="#f85149";msg.textContent="save failed";});});
var rgo=document.getElementById("r-go");
if(rgo)rgo.addEventListener("click",function(){
 var nf=function(id){return parseFloat(document.getElementById(id).value);};
 var hint=document.getElementById("r-hint");if(hint)hint.style.display="none";
 setStat("r-stat","","routing…");setStat("r-drc","","");rgo.disabled=true;
 recordUndo();/* autoroute apply = one undo step (audit 1.1c) */
 var payload={parts:P.map(function(p){return {ref:p.ref,x:p.x,y:p.y,rot:p.rot||0,side:p.side||"top"};}),
   track_width:nf("r-tw"),clearance:nf("r-cl"),via_drill:nf("r-vd"),via_dia:nf("r-va")};
 fetch("/api/pcb-route/"+encodeURIComponent(PCB.name),{method:"POST",
   headers:{"Content-Type":"application/json"},body:JSON.stringify(payload)})
  .then(function(r){if(!r.ok)throw 0;return r.json();})
  .then(function(j){PCB.tracks=j.tracks||[];PCB.vias=j.vias||[];PCB.drc=j.drc||[];
    if(payload.clearance>0)PCB.clr=payload.clearance;drawRoute();drawClr();drawDrc();
    rats();/* re-run with tracks present: routedNow is now true, so the loop
           overlay drops its preview GND vias and only the router's real vias
           remain — no preview+routed via doubling on the bypass caps. */
    var ok=(j.routed===j.total);
    var miss=(j.unrouted&&j.unrouted.length)?(" · missing: "+j.unrouted.join(", ")):"";
    setStat("r-stat",ok?"ok":"warn","routed "+j.routed+"/"+j.total+" nets · "+((j.vias||[]).length)+" vias"+miss);
    setStat("r-drc",(j.drc||[]).length?"err":"ok",(j.drc||[]).length?(j.drc.length+" DRC violation(s)"):"DRC clean ✓");
    var rp=j.return_path||0; setStat("r-rp",rp?"warn":"ok",rp?(rp+" return-path warning(s)"):"return paths ✓");
    rgo.disabled=false;})
  .catch(function(){setStat("r-stat","err","route failed");rgo.disabled=false;});});
// ── Live regenerate: run the optimizer in the background and animate the
//    board converging on its best-so-far arrangement (poll-driven). The
//    Regenerate / Apply buttons start a background solve instead of a
//    blocking page nav; on any error we fall back to the old ?regen=1 path.
var byRef={}; P.forEach(function(p,i){byRef[p.ref]=i;});
// Anchor the main IC (the hub with the largest courtyard — falls back to the
// biggest part) so every tried arrangement is shown *relative* to it: each
// live frame is translated to pin this part at its on-screen spot, so the IC
// stays put in the centre and only the parts around it visibly rearrange.
var anchorRef=null,anchorTX=0,anchorTY=0;
(function(){var bi=-1,bs=-1;P.forEach(function(p,i){
  var s=(p.hw||0)*(p.hh||0)+(p.kind==="hub"?1e6:0);if(s>bs){bs=s;bi=i;}});
 if(bi>=0){anchorRef=P[bi].ref;anchorTX=orig[bi].x;anchorTY=orig[bi].y;}})();
var liveBox=null;
function liveCard(){
 if(liveBox)return liveBox;
 liveBox=document.createElement("div"); liveBox.className="pcb-live";
 liveBox.innerHTML='<div class="pcb-live-card"><div class="pcb-live-spin"></div>'+
   '<div><div class="pcb-live-msg" id="pcb-live-msg">Starting optimizer…</div>'+
   '<div class="pcb-live-sub" id="pcb-live-sub"></div></div></div>';
 document.body.appendChild(liveBox); return liveBox;
}
function liveMsg(m,s,cls){var box=liveCard();
 box.className="pcb-live"+(cls?" "+cls:"");
 var a=document.getElementById("pcb-live-msg");if(a&&m!==undefined)a.textContent=m;
 var b=document.getElementById("pcb-live-sub");if(b)b.textContent=(s===undefined?"":s);}
function liveHide(){if(liveBox&&liveBox.parentNode)liveBox.parentNode.removeChild(liveBox);liveBox=null;}
function liveApply(f){if(!f||!f.parts)return;
 // Translate the frame so the anchor IC lands on its fixed on-screen point.
 var dx=0,dy=0;
 if(anchorRef!==null){f.parts.forEach(function(q){
   if(q.ref===anchorRef){dx=anchorTX-q.x;dy=anchorTY-q.y;}});}
 f.parts.forEach(function(q){var i=byRef[q.ref];if(i===undefined)return;
   P[i].x=q.x+dx;P[i].y=q.y+dy;P[i].rot=q.rot||0;});
 P.forEach(function(p,i){setT(i);}); clearRoute(); rats(); refreshUnplaced();}
function liveFallback(query){window.location="/pcb-layout/"+encodeURIComponent(PCB.name)+
  "?regen=1"+(query?("&"+query.replace(/^\?/,"")):"");}
function liveRegen(query){
 liveMsg("Starting optimizer…","","");markUnplaced([]);
 fetch("/api/pcb-regen-start/"+encodeURIComponent(PCB.name)+(query||""),{method:"POST"})
  .then(function(r){return r.json();})
  .then(function(j){if(typeof j.gen!=="number"||!j.gen)throw 0;livePoll(j.gen,-1,0);})
  .catch(function(){liveFallback(query);});}
function livePoll(gen,lastSeq,misses){
 fetch("/api/pcb-progress/"+encodeURIComponent(PCB.name))
  .then(function(r){return r.json();})
  .then(function(j){
   if(j.gen!==gen){liveHide();return;}
   if(j.frame&&j.seq>lastSeq){liveApply(j.frame);lastSeq=j.seq;
     liveMsg("Optimizing — "+(j.frame.pass==="refine"?"refining best layout":"exploring layouts"),
       "candidate score "+(+j.frame.score).toFixed(1)+" · update "+j.seq,"");}
   if(j.done){if(j.err){liveMsg("Optimizer error — falling back…","","err");
       setTimeout(function(){liveFallback("");},700);}
     else{liveMsg("Converged — loading final layout…","","done");
       // Land on ?show=cache so the fresh result is what you SEE — a plain
       // reload would snap back to the starred/saved layout and make the run
       // look like a no-op. Save then commits it as the layout.
       setTimeout(function(){window.location="/pcb-layout/"+encodeURIComponent(PCB.name)+"?show=cache";},400);}
     return;}
   setTimeout(function(){livePoll(gen,lastSeq,0);},350);})
  .catch(function(){if(misses>20){liveHide();return;}
   setTimeout(function(){livePoll(gen,lastSeq,misses+1);},700);});}
// A sub-circuit page's background regen job is keyed by the parent design, so
// Rough/Regenerate re-solve via a plain reload (?regen=1 → a fresh, rough-seeded
// solve of just this sub) instead of the design-level live animation.
function subReload(){var u=window.location.href.split("#")[0];
 window.location=u+(u.indexOf("?")>=0?"&":"?")+"regen=1";}
var onSub=function(){return PCB.sub&&PCB.sub.length;};
var rgl=document.getElementById("pcb-regen");
if(rgl)rgl.addEventListener("click",function(ev){ev.preventDefault();if(onSub()){subReload();return;}liveRegen("");});
var rgh=document.getElementById("pcb-rough");
if(rgh)rgh.addEventListener("click",function(ev){ev.preventDefault();if(onSub()){subReload();return;}liveRegen("?remaining=1");});
// ★-match chip: when a starred layout exists, show how close a fresh rough
// seed lands to it (area-match %) so the seed's hand-likeness is visible
// without leaving the page. Skipped on sub previews and ★-less boards.
(function(){
 if(onSub())return;
 if(!document.querySelector(".lay-row.def"))return;
 var anchor=document.getElementById("sc-obj-d");if(!anchor)return;
 fetch("/api/layout-match/"+encodeURIComponent(PCB.name))
  .then(function(r){return r.ok?r.json():null;})
  .then(function(j){
   if(!j||j.starred==null||typeof j.area_match_pct!=="number")return;
   var el=document.createElement("span");el.className="score";el.id="sc-starm";
   var t="Rough-vs-★ area match: how much of a fresh rough seed lands in the same general area as the starred layout (\""+j.starred+"\")";
   if(j.coverage&&j.coverage.unmatched&&j.coverage.unmatched.length)t+=" — ★ covers "+j.coverage.covered+"/"+j.coverage.parts+" parts; unmatched parts are excluded";
   el.title=t;
   el.textContent="★match "+j.area_match_pct.toFixed(0)+"%";
   anchor.parentNode.insertBefore(el,anchor.nextSibling);
  }).catch(function(){});
})();
setVB(); // initial overlay paint + zoom-dependent label visibility
// ── Layers / grid / units / ruler controls (audit 1.5) ──────────────────
(function(){
 // Grid selector — feeds snapG(); persists per design.
 var gs=document.getElementById("pcb-grid-sel");
 if(gs){var opt=String(viewSt.grid);var has=false;
  for(var i=0;i<gs.options.length;i++)if(gs.options[i].value===opt)has=true;
  gs.value=has?opt:"0.1";if(!has){viewSt.grid=0.1;}
  gs.addEventListener("change",function(){viewSt.grid=parseFloat(gs.value)||0;viewSave();});}
 // Units toggle — mm ↔ mil (display only).
 var ub=document.getElementById("pcb-units-btn");
 function unitsSync(){if(ub)ub.textContent=viewSt.units==="mil"?"mil":"mm";
  updatePropLive&&updatePropLive();drawBoardRect();}
 if(ub)ub.addEventListener("click",function(){viewSt.units=(viewSt.units==="mil")?"mm":"mil";viewSave();unitsSync();});
 unitsSync();
 // Layers popover — visibility checkboxes + active-layer selector.
 var lb=document.getElementById("pcb-layers-btn"),pop=document.getElementById("pcb-layers-pop");
 function chk(id,lbl,sw){return '<label><input type="checkbox" id="'+id+'"'+(sw.on?" checked":"")+'>'+
  (sw.c?'<span class="lp-swatch" style="background:'+sw.c+'"></span>':'')+lbl+'</label>';}
 function buildPop(){if(!pop)return;var v=viewSt.vis;
  pop.innerHTML='<div class="lp-h">Layers</div>'+
   chk("lp-top","Top copper",{on:v.top,c:"#f85149"})+
   chk("lp-bottom","Bottom copper",{on:v.bottom,c:"#388bfd"})+
   chk("lp-silk","Silk / labels",{on:v.silk,c:"#8b949e"})+
   chk("lp-rats","Ratsnest",{on:v.rats,c:"#9aa7b4"})+
   chk("lp-drc","DRC markers",{on:v.drc,c:"#ef4444"})+
   '<div class="lp-sep"></div>'+
   '<label>Active <select id="pcb-actlayer"><option value="0">Top (F.Cu)</option>'+
   '<option value="1">Bottom (B.Cu)</option></select></label>';
  var map={"lp-top":"top","lp-bottom":"bottom","lp-silk":"silk","lp-rats":"rats","lp-drc":"drc"};
  Object.keys(map).forEach(function(id){var c=document.getElementById(id);
   c.addEventListener("change",function(){viewSt.vis[map[id]]=c.checked?1:0;viewSave();paintSoon();drawDrc();rats();});});
  var al=document.getElementById("pcb-actlayer");al.value=String(activeLayer);
  al.addEventListener("change",function(){activeLayer=al.value==="1"?1:0;if(dtrace)dtrace.l=activeLayer;paintSoon();drawBtnSync();});}
 function popOpen(){if(!pop||!lb)return;buildPop();
  var r=lb.getBoundingClientRect(),pr=(pop.offsetParent||document.body).getBoundingClientRect();
  pop.style.left=(r.left-pr.left)+"px";pop.style.top=(r.bottom-pr.top+4)+"px";pop.hidden=false;lb.classList.add("active");}
 function popClose(){if(pop)pop.hidden=true;if(lb)lb.classList.remove("active");}
 if(lb)lb.addEventListener("click",function(ev){ev.stopPropagation();if(pop.hidden)popOpen();else popClose();});
 document.addEventListener("click",function(ev){if(pop&&!pop.hidden&&ev.target!==lb&&!pop.contains(ev.target))popClose();});
 // Active-layer keys: ( / ) and PgUp/PgDn.
 document.addEventListener("keydown",function(ev){if(kbTyping(ev.target))return;
  if(ev.key==="("||ev.key==="PageUp"||ev.key===")"||ev.key==="PageDown"){
   ev.preventDefault();activeLayer=activeLayer?0:1;if(dtrace)dtrace.l=activeLayer;
   var al=document.getElementById("pcb-actlayer");if(al)al.value=String(activeLayer);
   paintSoon();drawBtnSync();routeStatMsg("active layer: "+(activeLayer?"B.Cu (bottom)":"F.Cu (top)"));}});
 // ── Ruler / measure tool (M) ──────────────────────────────────────────
 var rulerMode=false,rulerDraw=null,rgRuler=null;
 var rulerBtn=document.getElementById("pcb-ruler-btn");
 function rulerArm(on){rulerMode=on;svg.classList.toggle("ruler-mode",on);
  if(rulerBtn)rulerBtn.classList.toggle("active",on);
  if(!on){rulerClear();var msg=document.getElementById("pcb-savemsg");if(msg&&/measure/.test(msg.textContent))msg.textContent="";}
  else{var m2=document.getElementById("pcb-savemsg");if(m2){m2.style.color="#e3b341";m2.textContent="measure: drag to measure (Esc exits)";}}}
 function rulerClear(){if(rgRuler&&rgRuler.parentNode)rgRuler.parentNode.removeChild(rgRuler);rgRuler=null;rulerDraw=null;}
 function rulerDrawNow(a,b){rulerClear();rgRuler=el("g",{});gU.appendChild(rgRuler);
  var dx=b.x-a.x,dy=b.y-a.y,dist=Math.hypot(dx,dy);
  rgRuler.appendChild(el("line",{"class":"pcb-ruler-line",x1:X(a.x).toFixed(1),y1:Y(a.y).toFixed(1),x2:X(b.x).toFixed(1),y2:Y(b.y).toFixed(1)}));
  // dx / dy guide legs
  rgRuler.appendChild(el("line",{"class":"pcb-ruler-line",x1:X(a.x).toFixed(1),y1:Y(a.y).toFixed(1),x2:X(b.x).toFixed(1),y2:Y(a.y).toFixed(1),opacity:0.5}));
  rgRuler.appendChild(el("line",{"class":"pcb-ruler-line",x1:X(b.x).toFixed(1),y1:Y(a.y).toFixed(1),x2:X(b.x).toFixed(1),y2:Y(b.y).toFixed(1),opacity:0.5}));
  var lt=el("text",{"class":"pcb-ruler-lbl",x:(X(b.x)+8).toFixed(1),y:(Y(b.y)-6).toFixed(1)});
  lt.textContent="d="+fmtLen2(dist)+"  dx="+fmtLen2(Math.abs(dx))+"  dy="+fmtLen2(Math.abs(dy));
  rgRuler.appendChild(lt);}
 if(rulerBtn)rulerBtn.addEventListener("click",function(){rulerArm(!rulerMode);});
 document.addEventListener("keydown",function(ev){if(kbTyping(ev.target))return;
  if((ev.key==="m"||ev.key==="M")&&!ev.ctrlKey&&!ev.metaKey&&!RO){ev.preventDefault();rulerArm(!rulerMode);return;}
  if(ev.key==="Escape"&&rulerMode){rulerArm(false);}});
 // Ruler pointer capture — runs BEFORE the board's own handlers via capture
 // phase, and swallows the gesture only while in ruler mode.
 svg.addEventListener("pointerdown",function(ev){if(!rulerMode||ev.button!==0)return;
  ev.stopPropagation();ev.preventDefault();try{svg.setPointerCapture(ev.pointerId);}catch(e){}
  var m=mm(ev);rulerDraw={a:m,b:m};rulerDrawNow(m,m);},true);
 svg.addEventListener("pointermove",function(ev){if(!rulerMode||!rulerDraw)return;
  ev.stopPropagation();var m=mm(ev);rulerDraw.b=m;rulerDrawNow(rulerDraw.a,m);},true);
 svg.addEventListener("pointerup",function(ev){if(!rulerMode||!rulerDraw)return;
  ev.stopPropagation();try{svg.releasePointerCapture(ev.pointerId);}catch(e){}
  rulerDraw=null;/* keep the measurement drawn until next drag / Esc */},true);
})();
// ── Collapsible control deck (accordion) + board-view overlays ──────────
(function(){
 // Only chips that name a panel are accordion toggles — the layers/units/ruler
 // chips are plain buttons wired separately below.
 var chips=Array.prototype.slice.call(document.querySelectorAll(".tab-chip[data-panel]"));
 function panels(){return document.querySelectorAll(".pcb-panel");}
 function openPanel(id){panels().forEach(function(p){p.hidden=(p.id!==id);});
   chips.forEach(function(c){c.classList.toggle("active",c.getAttribute("data-panel")===id);});}
 function closeAll(){panels().forEach(function(p){p.hidden=true;});
   chips.forEach(function(c){c.classList.remove("active");});}
 chips.forEach(function(c){c.addEventListener("click",function(){
   if(c.classList.contains("active"))closeAll();else openPanel(c.getAttribute("data-panel"));});});
})();
// Cost/blame heatmap: tint each part's courtyard green→red by its share of the
// objective (PCB.parts[i].blame, raw — the live /api/pcb-score units).
function lerpHex(a,b,t){var ar=(a>>16)&255,ag=(a>>8)&255,ab=a&255;
 return "rgb("+Math.round(ar+(((b>>16)&255)-ar)*t)+","+Math.round(ag+(((b>>8)&255)-ag)*t)+
  ","+Math.round(ab+((b&255)-ab)*t)+")";}
function blameColor(t){if(!(t>0))t=0;if(t>1)t=1;
 return t<0.5?lerpHex(0x15302a,0xb8860b,t*2):lerpHex(0xb8860b,0xc0392b,(t-0.5)*2);}
var heatOn=false;
// Colour scale: the hottest *non-anchor* part's blame, captured when the
// heatmap is switched ON and held FIXED while it stays on — re-normalizing
// per drag made every OTHER part's tint shift when one part moved (moving a
// well-placed small cap read as "the big cap got worse"). With the scale
// pinned, a drag re-tints only the parts whose raw blame actually changed;
// values above the captured scale clamp to full red. The anchor IC is the
// fixed reference point everything is placed around, so it carries no tint
// and never sets the scale. Toggle the heatmap off/on to re-capture.
var heatScale=0;
function heatMax(){var mx=0;
 P.forEach(function(p){if(p.ref!==anchorRef){var b=p.blame||0;if(b>mx)mx=b;}});return mx;}
function applyHeat(){paintSoon();} // paint reads heatOn/heatScale/p.blame
var heatCb=document.getElementById("v-heat");
if(heatCb)heatCb.addEventListener("change",function(){heatOn=heatCb.checked;
 if(heatOn)heatScale=heatMax();
 var hl=document.getElementById("heat-legend");if(hl)hl.hidden=!heatOn;applyHeat();});
var legCb=document.getElementById("v-legend");
if(legCb)legCb.addEventListener("change",function(){var l=document.getElementById("pcb-legend");
 if(l)l.hidden=!legCb.checked;});
// ── Net colours: give every net its own colour so connectivity reads off
//    the board without the schematic. Per-net colour comes straight from
//    PCB.netcolor[net] (no-connect → white, GND → brown, power → warm,
//    each signal net → a distinct colour). A pad on NO net is a no-connect
//    pin → white; off, pads go back to copper. Orthogonal to the heatmap
//    (which tints courtyards). rats() honours the flag, so re-drawing the
//    ratsnest re-applies the airwire colours.
var netColOn=true;
// ── Ratsnest toggle: the airwires + decoupling-loop overlays live in gR;
//    rats() honours this flag (early-returns after clearing), so once off they
//    stay hidden through drags/rotations until toggled back on.
var ratsOn=true;
var ratsCb=document.getElementById("v-rats");
if(ratsCb)ratsCb.addEventListener("change",function(){ratsOn=ratsCb.checked;rats();});
function netColorOf(nk){if(!nk||!PCB.netcolor)return null;return PCB.netcolor[nk]||null;}
function applyNetColors(){paintSoon();} // paint reads netColOn/PCB.netcolor
var netColCb=document.getElementById("v-netcol");
if(netColCb)netColCb.addEventListener("change",function(){netColOn=netColCb.checked;
 var nl=document.getElementById("net-legend");if(nl)nl.hidden=!netColOn;
 applyNetColors();rats();});
applyNetColors(); rats(); showScore(PCB.auto); drawRoute(); drawClr(); drawDrc();
markUnplaced(PCB.placement&&PCB.placement.unplaced);
// Populate the DRC count chip on load when the board already carries copper
// (restored saved routes) — so the fab-readiness signal is honest immediately,
// not only after the first edit (audit 1.1d).
if(!RO&&((PCB.tracks||[]).length||(PCB.vias||[]).length))scheduleDrc();
// ── Cross-probe focus: ?focus=REF (or #REF) selects that part on load —
//    zoom/centre the view on it, flash its courtyard, and reveal it in the
//    component sidebar. Exact ref first, then the bare sub-block leaf
//    (focus=U2 matches ldo/U2), mirroring the PNG renderer's ?refs= rule.
function focusPart(want){
 function leaf(r){var i=r.lastIndexOf("/");return i<0?r:r.slice(i+1);}
 var idx=-1;
 P.forEach(function(p,i){if(idx<0&&p.ref===want)idx=i;});
 if(idx<0)P.forEach(function(p,i){if(idx<0&&leaf(p.ref)===want)idx=i;});
 if(idx<0)return false;
 var p=P[idx],cx=X(p.x),cy=Y(p.y);
 var fw=Math.min(VBW,Math.max(VBW*0.35,(2*p.hw+14)*S*4));
 vb={x:cx-fw/2,y:cy-fw*(VBH/VBW)/2,w:fw,h:fw*(VBH/VBW)};setVB();
 flashIdx=idx;flashUntil=Date.now()+2600;paintSoon();
 if(!RO)selectComp(p.ref);
 return true;}
// ── Fab-readiness gate (⤓ Gerbers) ──────────────────────────────────────
// The Gerbers button no longer downloads blindly: it first fetches the
// pre-fab readiness report (/api/fab-readiness) and, when there are errors
// or warnings, opens a modal listing them. Errors offer "Download anyway"
// (?force=1); warnings-only offer "Continue". A clean board downloads
// straight through, no modal.
function fabZipUrl(force){
 var q=subq();
 if(force)q=q?q+"&force=1":"?force=1";
 return "/api/pcb-gerbers/"+encodeURIComponent(PCB.name)+q;}
function fabDownload(force){
 var a=document.createElement("a");
 a.href=fabZipUrl(force);a.download="";
 document.body.appendChild(a);a.click();document.body.removeChild(a);}
function fabModalClose(){var m=document.getElementById("fab-modal");if(m)m.hidden=true;}
function fabRenderReport(rep){
 var h="";
 function list(cls,label,items){
  if(!items||!items.length)return "";
  var s='<div class="fab-sec '+cls+'">'+label+' ('+items.length+')</div><ul>';
  items.forEach(function(it){
   var extra="";
   if(it.net)extra=' <code>'+pEsc(it.net)+'</code>';
   else if(it.ref)extra=' <code>'+pEsc(it.ref)+'</code>';
   s+='<li>'+pEsc(it.message)+extra+'</li>';});
  return s+'</ul>';}
 h+=list("err","Errors — these block the fab package",rep.errors);
 h+=list("warn","Warnings",rep.warnings);
 if((!rep.errors||!rep.errors.length)&&(!rep.warnings||!rep.warnings.length))
  h+='<div class="fab-sec ok">Board is fab-ready.</div>';
 var s=rep.stats||{};
 h+='<div class="fab-stats">'+(s.parts||0)+' parts · '+
  (s.connected_nets||0)+'/'+(s.routable_nets||0)+' routable nets connected · '+
  (s.tracks||0)+' tracks · '+(s.vias||0)+' vias · '+
  (s.drc_violations||0)+' DRC · outline: '+(s.has_outline?"yes":"no")+'</div>';
 return h;}
function fabOpenModal(rep){
 var m=document.getElementById("fab-modal");if(!m)return;
 var body=document.getElementById("fab-body"),go=document.getElementById("fab-go"),
  title=document.getElementById("fab-title");
 body.innerHTML=fabRenderReport(rep);
 var hasErr=rep.errors&&rep.errors.length;
 title.textContent=hasErr?"Fab readiness — problems found":"Fab readiness — warnings";
 go.textContent=hasErr?"Download anyway":"Continue — download";
 go.className=hasErr?"btn fab-danger":"btn";
 go.onclick=function(){fabModalClose();fabDownload(!!hasErr);};
 m.hidden=false;}
(function(){
 var btn=document.getElementById("pcb-fab");if(!btn)return;
 btn.addEventListener("click",function(){
  btn.disabled=true;
  fetch("/api/fab-readiness/"+encodeURIComponent(PCB.name)+subq())
   .then(function(r){return r.ok?r.json():null;})
   .then(function(rep){
    if(!rep){fabDownload(false);return;} // no report (e.g. no saved layout) — let the ZIP endpoint answer
    var clean=rep.ok&&(!rep.warnings||!rep.warnings.length);
    if(clean)fabDownload(false);else fabOpenModal(rep);})
   .catch(function(){fabDownload(false);})
   .then(function(){btn.disabled=false;});});
 var fx=document.getElementById("fab-x"),fc=document.getElementById("fab-cancel"),
  fm=document.getElementById("fab-modal");
 if(fx)fx.addEventListener("click",fabModalClose);
 if(fc)fc.addEventListener("click",fabModalClose);
 if(fm)fm.addEventListener("click",function(ev){if(ev.target===fm)fabModalClose();});
})();
// ── Two-window live cross-probe ─────────────────────────────────────────
// The KiCad two-monitor workflow, browser-native: keep /schematics/<name>
// open in another tab/window and clicking a part here highlights it there;
// selecting a component there zooms/flashes it here. Pages of the SAME
// design in the SAME browser find each other over a BroadcastChannel — no
// server round-trip, nothing to configure. xpMuted stops a highlight we
// apply on behalf of a received message from echoing back as a new one.
var xpc=null,xpMuted=false;
try{xpc=new BroadcastChannel("netlisp-xprobe");}catch(e){}
if(xpc)xpc.onmessage=function(ev){var m=ev.data||{};
 if(m.from==="pcb"||m.design!==PCB.name||!m.ref)return;
 xpMuted=true;try{focusPart(m.ref);}finally{xpMuted=false;}};
function xpSend(ref){if(!xpc||xpMuted)return;
 try{xpc.postMessage({from:"pcb",design:PCB.name,ref:ref});}catch(e){}}
(function(){
 var want="";
 try{want=new URLSearchParams(location.search).get("focus")||"";}catch(e){}
 if(!want&&location.hash.length>1)want=decodeURIComponent(location.hash.slice(1));
 if(want)focusPart(want);
})();
})();
