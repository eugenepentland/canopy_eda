(function(){
const NS="http://www.w3.org/2000/svg";
const S=PCB.scale,MX=PCB.minx,MY=PCB.miny,M=PCB.margin,G=PCB.grid;
const P=PCB.parts, orig=P.map(function(p){return {x:p.x,y:p.y,rot:p.rot||0};});
var RO=!!PCB.ro;
// `?sub=` query for a sub-circuit page so layout save/delete/star/rescore POST
// to the per-sub sidecar (<design>.<sub>.layouts.json) instead of the design's.
// Empty on a normal design/module page.
function subq(){return (PCB.sub&&PCB.sub.length)?("?sub="+encodeURIComponent(PCB.sub)):"";}
const X=function(mm){return (mm-MX+M)*S;}, Y=function(mm){return (mm-MY+M)*S;};
const svg=document.getElementById("pcb-svg");
const gP=document.createElementNS(NS,"g"), gR=document.createElementNS(NS,"g");
const gT=document.createElementNS(NS,"g"), gC=document.createElementNS(NS,"g"), gD=document.createElementNS(NS,"g");
const gU=document.createElementNS(NS,"g"), gPads=document.createElementNS(NS,"g");
// Layer stack (bottom→top): part bodies (courtyard + silk + ref) < ratsnest <
// pads < clearance < tracks < DRC < unplaced. The ratsnest (gR) sits ABOVE each
// part's dark courtyard so airwires read across the body, but BELOW the copper
// pads (gPads, drawn after gR) so no airwire ever paints over a pad. Pads ride
// in their own top layer; each part's gPads subgroup is kept in lock-step with
// the body transform by setT (translate+rotate), and a pointerdown forwarder
// (see the drag block) keeps a part draggable even when grabbed by a pad.
svg.appendChild(gP); svg.appendChild(gR); svg.appendChild(gPads); svg.appendChild(gC); svg.appendChild(gT); svg.appendChild(gD); svg.appendChild(gU);
gT.style.pointerEvents="none"; gR.style.pointerEvents="none"; gC.style.pointerEvents="none"; gD.style.pointerEvents="none"; gU.style.pointerEvents="none";
const els=[], bodies=[], padEls=[];
function el(n,a){var e=document.createElementNS(NS,n);for(var k in a)e.setAttribute(k,a[k]);return e;}
// (board (size W H) …) physical outline, under everything (read-only).
if(PCB.board){
 var br=PCB.board,gB=document.createElementNS(NS,"g");
 svg.insertBefore(gB,gP); gB.style.pointerEvents="none";
 gB.appendChild(el("rect",{x:X(br.x).toFixed(1),y:Y(br.y).toFixed(1),width:(br.w*S).toFixed(1),
   height:(br.h*S).toFixed(1),fill:"none",stroke:"#7ee787","stroke-width":1.6,opacity:0.85}));
 var bt=el("text",{x:(X(br.x)+6).toFixed(1),y:(Y(br.y)+14).toFixed(1),fill:"#7ee787","font-size":"11",opacity:0.85});
 bt.textContent=br.w.toFixed(0)+"×"+br.h.toFixed(0)+" mm"; gB.appendChild(bt);
}
function wpt(i,lx,ly){var p=P[i],a=(p.rot||0)*Math.PI/180,c=Math.cos(a),s=Math.sin(a);
 return {x:p.x+lx*c-ly*s,y:p.y+lx*s+ly*c};}
function moved(i){return P[i].x!==orig[i].x||P[i].y!==orig[i].y||(P[i].rot||0)!==orig[i].rot;}
function wrect(i,pad){var p=P[i],c=wpt(i,pad.x,pad.y),q=(((p.rot||0)%360)+360)%360;
 var hw=(q==90||q==270)?pad.h/2:pad.w/2, hh=(q==90||q==270)?pad.w/2:pad.h/2;
 return {x0:c.x-hw,y0:c.y-hh,x1:c.x+hw,y1:c.y+hh};}
function setT(i){var p=P[i],tx=X(p.x).toFixed(1),ty=Y(p.y).toFixed(1),rot=(p.rot||0);
 els[i].setAttribute("transform","translate("+tx+","+ty+")");
 bodies[i].setAttribute("transform","rotate("+rot+")");
 // Pads live in the top gPads layer (above the ratsnest), so they carry the
 // part's full translate+rotate themselves rather than inheriting it.
 if(padEls[i]){padEls[i].setAttribute("transform","translate("+tx+","+ty+") rotate("+rot+")");
  // Keep pad numbers reading horizontally at any part orientation: counter-
  // rotate each label by -rot about its own centre (its x/y attrs ARE the pad
  // centre), cancelling the padset's rotation so the digit never flips.
  padEls[i].querySelectorAll("text").forEach(function(t){
   t.setAttribute("transform","rotate("+(-rot)+" "+t.getAttribute("x")+" "+t.getAttribute("y")+")");});}}
// Defined decoupling pads: each loop pins a cap to ONE hub pad (L.pp =
// hub_pwr_pin). Mark those hub pads so a net selection glows them red (the
// authored decoupling target) rather than gold. Keyed hubIndex:padX:padY.
var loopPin={};(PCB.loops||[]).forEach(function(L){if(L.pp)loopPin[L.hub+":"+L.pp.x.toFixed(2)+":"+L.pp.y.toFixed(2)]=1;});
P.forEach(function(p,i){
 var g=el("g",{"class":"part","data-ref":p.ref});
 var body=el("g",{"class":"body"});
 body.appendChild(el("rect",{"class":"court",x:(-p.hw*S).toFixed(1),y:(-p.hh*S).toFixed(1),
   width:(2*p.hw*S).toFixed(1),height:(2*p.hh*S).toFixed(1),rx:2,fill:"#161b22",
   stroke:p.kind=="hub"?"#58a6ff":"#8b949e","stroke-width":1.3,
   "stroke-dasharray":p.fb?"4 3":"0"}));
 if(p.silk){
  p.silk.l.forEach(function(s){body.appendChild(el("line",{x1:(s[0]*S).toFixed(1),y1:(s[1]*S).toFixed(1),
    x2:(s[2]*S).toFixed(1),y2:(s[3]*S).toFixed(1),stroke:"#8b949e","stroke-width":0.8,"stroke-linecap":"round"}));});
  p.silk.c.forEach(function(c){body.appendChild(el("circle",{cx:(c[0]*S).toFixed(1),cy:(c[1]*S).toFixed(1),
    r:Math.max(c[2]*S,1).toFixed(1),fill:"none",stroke:"#8b949e","stroke-width":0.8}));});}
 // Pads go into their own gPads subgroup (drawn above the ratsnest), not into
 // the body — so airwires pass behind the copper. data-ref lets the drag
 // forwarder map a pad back to its part.
 var pg=el("g",{"class":"padset","data-ref":p.ref});
 p.pads.forEach(function(pad){
   var at={fill:"#b08d57"}; if(pad.net)at["data-net"]=pad.net;
   var pe=FP.padShape(pad,{scale:S,minPx:1.5,cls:"pad",attrs:at});
   if(loopPin[i+":"+pad.x.toFixed(2)+":"+pad.y.toFixed(2)])pe.classList.add("looppin");
   pg.appendChild(pe);
   // Pad number, centred inside the copper. pointer-events off so a click on
   // the digit still falls through to the pad (net glow / drag) underneath.
   var lbl=FP.padLabel(pad,S);if(lbl){lbl.style.pointerEvents="none";pg.appendChild(lbl);}});
 g.appendChild(body);
 var t=el("text",{"class":"pcb-ref",x:0,y:(-p.hh*S-2).toFixed(1),fill:p.kind=="hub"?"#58a6ff":"#8b949e"});
 t.textContent=p.ref; g.appendChild(t);
 gP.appendChild(g); gPads.appendChild(pg); els.push(g); bodies.push(body); padEls.push(pg);
 setT(i);
});
// ── Unplaced (auto-staged) parts: the ones a (placement …) spec didn't list.
//    The optimizer drops them into a staging band; flag each one red and draw
//    a dashed red box around the cluster so a gap in the spec is obvious.
var unplacedSet={};
function markUnplaced(refs){
 unplacedSet={};(refs||[]).forEach(function(r){unplacedSet[r]=1;});
 P.forEach(function(p,i){if(els[i])els[i].classList.toggle("unplaced",!!unplacedSet[p.ref]);});
 refreshUnplaced();}
function refreshUnplaced(){
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
function aw(a,b,col,sw,op){gR.appendChild(el("line",{x1:X(a.x).toFixed(1),y1:Y(a.y).toFixed(1),
 x2:X(b.x).toFixed(1),y2:Y(b.y).toFixed(1),stroke:col,"stroke-width":sw,opacity:op}));}
function rats(){
 while(gR.firstChild)gR.removeChild(gR.firstChild);
 if(!ratsOn)return;
 PCB.links.forEach(function(l){
   var a=wpt(l.a,l.ax,l.ay),b=wpt(l.b,l.bx,l.by);
   var col=l.k=="proximity"?"#ea580c":(l.k=="ground"?"#22b8cf":"#9aa7b4");
   if(netColOn){var nc=netColorOf(l.net);if(nc)col=nc;}
   aw(a,b,col,l.k=="signal"?0.7:1.3,l.k=="signal"?0.55:0.9);});
 var routedNow=((PCB.tracks||[]).length>0);
 // Use the server's DRC-safe GND-via drop (cgv/gpv) only while the cap/hub is
 // at its emitted pose; once dragged that world point is stale, so recompute
 // the via at the live GND pad centre so it follows the part (the prior via is
 // already cleared with gR above; Route re-derives the exact DRC-safe fan).
 PCB.loops.forEach(function(L){
   // cgv/gpv are the server's DRC-safe via drops, valid only at the emitted
   // pose. Once a part is dragged that point is stale, and cgv/gpv come back
   // null when the router can't fan a via there at all (a fat thermal/EP GND
   // pad next to a small pad). In both cases draw the return *path* to the raw
   // pad centre but DON'T draw a via dot — an invented dot would land on the
   // neighbouring pad (the FB tap) and never match what Route actually drops.
   var cReal=(L.cgv&&!moved(L.cap)), dReal=(L.gpv&&!moved(L.hub));
   var A=wpt(L.hub,L.pp.x,L.pp.y), B=wpt(L.cap,L.cp.x,L.cp.y),
       C=cReal?L.cgv:wpt(L.cap,L.cg.x,L.cg.y),
       D=dReal?L.gpv:wpt(L.hub,L.gp.x,L.gp.y);
   aw(B,A,"#ea580c",1.3,0.95);
   var rp=[C,B,A,D].map(function(q){return X(q.x).toFixed(1)+","+Y(q.y).toFixed(1);}).join(" ");
   var pl=el("polyline",{points:rp,fill:"none",stroke:"#58a6ff","stroke-width":1.3,opacity:0.85,"stroke-dasharray":"4 2"});
   var gt=el("title",{}); gt.textContent="GND return images under the power trace on the L2 plane (drops at the DRC-safe GND vias)"; pl.appendChild(gt);
   gR.appendChild(pl);
   if(!routedNow){ if(cReal)drawVia(gR,C.x,C.y,viaGeo().dia,viaGeo().drill);
                   if(dReal)drawVia(gR,D.x,D.y,viaGeo().dia,viaGeo().drill); }});
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
 setSc("sc-obj","objective …");var seq=++scoreReq;
 // Ask for per-part blame only while the Heatmap view is on, so a finished
 // drag/rotate re-tints the board to the new cost distribution.
 var payload={parts:P.map(function(p){return {ref:p.ref,x:p.x,y:p.y,rot:p.rot||0};}),blame:heatOn};
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
function pEsc(s){return String(s==null?"":s).replace(/[&<>]/g,function(c){
 return c=="&"?"&amp;":(c=="<"?"&lt;":"&gt;");});}
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
 h+='<div class="prop-rows">'+pRow("X",pMm(p.x)+" mm","prop-x")+pRow("Y",pMm(p.y)+" mm","prop-y")+
  pRow("Rotation",rot+"°","prop-rot")+pRow("Type",p.kind=="hub"?"Hub / IC":"Passive")+'</div>';
 if(p.fp)h+='<button class="prop-fp" data-court-ref="'+pEsc(p.ref)+'" title="Edit footprint courtyard">▢ '+pEsc(p.fp)+'</button>';
 var pads=(p.pads||[]).slice().sort(function(a,b){var an=parseInt(a.num,10),bn=parseInt(b.num,10);
  if(!isNaN(an)&&!isNaN(bn))return an-bn;return String(a.num||"").localeCompare(String(b.num||""));});
 var pins="";pads.forEach(function(pd){if(!pd.num&&!pd.net)return;
  pins+='<span class="pn" data-net="'+pEsc(pd.net||"")+'"><b>'+pEsc(pd.num||"")+'</b>'+pEsc(nLeaf(pd.net||""))+'</span>';});
 if(pins)h+='<div class="prop-sec">Pins → nets</div><div class="prop-pins">'+pins+'</div>';
 var sb=body.getAttribute("data-schbase")||"/schematics/";
 h+='<a class="prop-sch" href="'+sb+encodeURIComponent(PCB.name)+'#comp-'+encodeURIComponent(p.ref)+'" '+
  'title="Open the schematic page scrolled to this part">Show in schematic →</a>';
 body.innerHTML=h;
 var cb=body.querySelector("[data-court-ref]");
 if(cb)cb.addEventListener("click",function(){openCourt(cb.getAttribute("data-court-ref"));});
 body.querySelectorAll(".pn[data-net]").forEach(function(e){var nn=e.getAttribute("data-net");
  if(!nn)return;e.style.cursor="pointer";
  if(nn===selNetCur)e.classList.add("net-sel");
  e.addEventListener("mouseenter",function(){hlBy("data-net",nn,"net-hl",true);});
  e.addEventListener("mouseleave",function(){hlBy("data-net",nn,"net-hl",false);});
  e.addEventListener("click",function(){selNet(nn);});});}
function updatePropLive(){if(!selRef)return;var p=partByRef(selRef);if(!p)return;
 var ex=document.getElementById("prop-x"),ey=document.getElementById("prop-y"),er=document.getElementById("prop-rot");
 if(ex)ex.textContent=pMm(p.x)+" mm";if(ey)ey.textContent=pMm(p.y)+" mm";
 if(er)er.textContent=((((p.rot||0)%360)+360)%360)+"°";}
function markSelPart(){document.querySelectorAll(".part.sel").forEach(function(e){e.classList.remove("sel");});
 if(!selRef)return;var s=(window.CSS&&CSS.escape)?CSS.escape(selRef):selRef;
 var g=document.querySelector('.part[data-ref="'+s+'"]');if(g)g.classList.add("sel");}
function selectComp(ref){selRef=ref;renderProps();markSelPart();}
function clearSel(){if(!selRef)return;selRef=null;renderProps();markSelPart();}
if(!RO){
var drag=null, cur=-1;
// Multi-select (marquee): sel = part indices currently box-selected; gdrag
// = an in-progress group move (every selected part shifts by the same grid-
// snapped delta). Highlighted with .msel (purple) vs the single .sel (blue).
var sel=[], gdrag=null;
function markSel(){els.forEach(function(g,i){g.classList.toggle("msel",sel.indexOf(i)>=0);});}
function selSet(idxs){sel=idxs;markSel();}
function selClear(){if(!sel.length)return;sel=[];markSel();}
function gdragStart(m,down){return {sx:m.x,sy:m.y,moved:false,down:down,snap:snapPoses(),
 orig:sel.map(function(k){return {i:k,x:P[k].x,y:P[k].y};})};}
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
els.forEach(function(g,i){
 g.addEventListener("mouseenter",function(){cur=i;});
 g.addEventListener("mouseleave",function(){if(cur===i)cur=-1;});
 g.addEventListener("pointerdown",function(ev){ev.preventDefault();var m=mm(ev);
   if(sel.length>1&&sel.indexOf(i)>=0){gdrag=gdragStart(m,ev.target);g.setPointerCapture(ev.pointerId);g.style.cursor="grabbing";return;}
   if(sel.length)selClear();
   drag={i:i,ox:P[i].x-m.x,oy:P[i].y-m.y,down:ev.target,snap:snapPoses()};g.setPointerCapture(ev.pointerId);g.style.cursor="grabbing";});
 g.addEventListener("pointermove",function(ev){
   if(gdrag){var gm=mm(ev),dx=Math.round((gm.x-gdrag.sx)/G)*G,dy=Math.round((gm.y-gdrag.sy)/G)*G,any=false;
     gdrag.orig.forEach(function(o){var nx=o.x+dx,ny=o.y+dy;if(P[o.i].x!==nx||P[o.i].y!==ny){P[o.i].x=nx;P[o.i].y=ny;setT(o.i);any=true;}});
     if(any){if(!gdrag.moved){gdrag.moved=true;clearRoute();}rats();drawClr();refreshUnplaced();}return;}
   if(!drag||drag.i!==i)return;var m=mm(ev);
   var nx=Math.round((m.x+drag.ox)/G)*G,ny=Math.round((m.y+drag.oy)/G)*G;
   if(nx===P[i].x&&ny===P[i].y)return;P[i].x=nx;P[i].y=ny;
   if(!drag.moved){drag.moved=true;clearRoute();}setT(i);rats();drawClr();refreshUnplaced();
   if(selRef===P[i].ref)updatePropLive();});
 g.addEventListener("pointerup",function(ev){
   if(gdrag){var gmv=gdrag.moved,gsnap=gdrag.snap;gdrag=null;g.style.cursor="grab";
    try{g.releasePointerCapture(ev.pointerId);}catch(e){}if(gmv){recordUndo(gsnap);fetchScore();}return;}
   var mv=drag&&drag.moved,dn=drag&&drag.down,dsnap=drag&&drag.snap;drag=null;g.style.cursor="grab";
   try{g.releasePointerCapture(ev.pointerId);}catch(e){}if(mv){recordUndo(dsnap);fetchScore();return;}
   var net=netAt(dn);if(net)selNet(net);selectComp(P[i].ref);});
 // Pads now sit in the top gPads layer, so a pointerdown on a pad no longer
 // bubbles to the part group. Forward it: capture on g (the court group, which
 // owns pointermove/up) so the part still drags when grabbed by a pad, and keep
 // `cur` (the R-rotate target) tracking pad hover too.
 var pg=padEls[i];
 if(pg){
  pg.addEventListener("mouseenter",function(){cur=i;});
  pg.addEventListener("mouseleave",function(){if(cur===i)cur=-1;});
  pg.addEventListener("pointerdown",function(ev){ev.preventDefault();var m=mm(ev);
    if(sel.length>1&&sel.indexOf(i)>=0){gdrag=gdragStart(m,ev.target);g.setPointerCapture(ev.pointerId);g.style.cursor="grabbing";return;}
    if(sel.length)selClear();
    drag={i:i,ox:P[i].x-m.x,oy:P[i].y-m.y,down:ev.target,snap:snapPoses()};g.setPointerCapture(ev.pointerId);g.style.cursor="grabbing";});}
});
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
 if(ev.key=="Escape"){if(kbdOv){kbdClose();}else{selClear();clearSel();}return;}
 var typing=kbTyping(ev.target);
 if(ev.key=="?"&&!typing){ev.preventDefault();kbdToggle();return;}
 if((ev.key=="r"||ev.key=="R")&&cur>=0&&!typing){ev.preventDefault();recordUndo();
   P[cur].rot=((((P[cur].rot||0)+(ev.shiftKey?-90:90))%360)+360)%360;
   setT(cur);clearRoute();rats();fetchScore();refreshUnplaced();if(selRef===P[cur].ref)updatePropLive();}});
function applyAll(){P.forEach(function(p,i){setT(i);});clearRoute();rats();fetchScore();refreshUnplaced();updatePropLive();
 if(window.PCB3D&&window.PCB3D.sync)window.PCB3D.sync();}
// ── Undo / redo ─────────────────────────────────────────────────────────
// Snapshot every part's pose before a mutating gesture; Ctrl+Z restores the
// last one (Ctrl+Shift+Z / Ctrl+Y redoes). Drags/group-moves capture their
// PRE state at pointerdown and commit it only if something actually moved;
// rotate / reset / load record just before they mutate. Snapshots are pose
// arrays indexed by P order (stable), so a restore is a write-back + applyAll.
var undoStack=[],redoStack=[];
function snapPoses(){return P.map(function(p){return {x:p.x,y:p.y,rot:p.rot||0};});}
function undoBtns(){var u=document.getElementById("pcb-undo"),r=document.getElementById("pcb-redo");
 if(u)u.disabled=!undoStack.length;if(r)r.disabled=!redoStack.length;}
function recordUndo(snap){undoStack.push(snap||snapPoses());if(undoStack.length>200)undoStack.shift();
 redoStack.length=0;undoBtns();}
function restorePoses(s){s.forEach(function(q,i){if(P[i]){P[i].x=q.x;P[i].y=q.y;P[i].rot=q.rot;}});applyAll();}
function doUndo(){if(!undoStack.length)return;redoStack.push(snapPoses());restorePoses(undoStack.pop());undoBtns();}
function doRedo(){if(!redoStack.length)return;undoStack.push(snapPoses());restorePoses(redoStack.pop());undoBtns();}
var undoBtn=document.getElementById("pcb-undo");if(undoBtn)undoBtn.addEventListener("click",doUndo);
var redoBtn=document.getElementById("pcb-redo");if(redoBtn)redoBtn.addEventListener("click",doRedo);
document.addEventListener("keydown",function(ev){if(!(ev.ctrlKey||ev.metaKey)||kbTyping(ev.target))return;
 var k=(ev.key||"").toLowerCase();
 if(k==="z"&&!ev.shiftKey){ev.preventDefault();doUndo();}
 else if((k==="z"&&ev.shiftKey)||k==="y"){ev.preventDefault();doRedo();}});
undoBtns();
document.getElementById("pcb-reset").addEventListener("click",function(){recordUndo();
 selClear();P.forEach(function(p,i){p.x=orig[i].x;p.y=orig[i].y;p.rot=orig[i].rot;});applyAll();});
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
 P.forEach(function(p){var s=(p.origin&&byOrigin[p.origin])||L.parts[p.ref];if(s){p.x=s.x;p.y=s.y;p.rot=s.rot||0;}});applyAll();
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
function loadLayoutScores(){if(!((PCB.layouts||[]).length))return;
 fetch("/api/pcb-score-batch/"+encodeURIComponent(PCB.name)+subq(),{method:"POST"})
  .then(function(r){return r.json();})
  .then(function(j){(j.results||[]).forEach(function(it){layBreaks[it.name]=it.breakdown;});reweighLayouts();})
  .catch(function(){});}
// Persist the current poses to layout nm and update the panel IN PLACE — no
// page reload, so the camera and view toggles you set while editing stay put.
function persistLayout(nm,verb){var msg=document.getElementById("pcb-savemsg");
 var parts=P.map(function(p){return {ref:p.ref,x:p.x,y:p.y,rot:p.rot||0,origin:p.origin||""};});
 if(msg){msg.style.color="#8b949e";msg.textContent=verb+"\u{2026}";}
 return fetch("/api/pcb-layouts/"+encodeURIComponent(PCB.name)+subq(),{method:"POST",
   headers:{"Content-Type":"application/json"},body:JSON.stringify({name:nm,parts:parts})})
  .then(function(r){if(!r.ok)throw 0;return r.json();})
  .then(function(){
    var pmap={};parts.forEach(function(p){pmap[p.ref]={x:p.x,y:p.y,rot:p.rot,origin:p.origin||""};});
    var Ls=PCB.layouts||(PCB.layouts=[]),found=null;
    for(var i=0;i<Ls.length;i++)if(Ls[i].name===nm){found=Ls[i];break;}
    if(found){found.parts=pmap;found.kind="manual";}
    else Ls.push({name:nm,kind:"manual",parts:pmap,score:null});
    upsertLayoutPanel(nm);setActiveLayout(nm);loadLayoutScores();
    if(msg){msg.style.color="#3fb950";msg.textContent=(verb==="updating"?"updated":"saved")+" \u{2713}";}})
  .catch(function(){if(msg){msg.style.color="#f85149";
    msg.textContent=(verb==="updating"?"update":"save")+" failed";}});}
document.getElementById("pcb-saveas").addEventListener("click",function(){
 var nm=window.prompt("Name this layout:","layout "+stamp());
 if(nm===null)return; nm=nm.trim(); if(!nm)return; persistLayout(nm,"saving");});
// Update: overwrite the loaded layout in place (no prompt) — save progress on
// the layout you're iterating without disturbing the view.
var updBtn=document.getElementById("pcb-update");
if(updBtn)updBtn.addEventListener("click",function(){if(!curLayout)return;persistLayout(curLayout,"updating");});
loadLayoutScores();
}
function hlBy(at,v,cls,on){document.querySelectorAll("["+at+"]").forEach(function(e){
 if(e.getAttribute(at)===v)e.classList.toggle(cls,on);});}
function wire(at,cls){document.querySelectorAll("["+at+"]").forEach(function(e){
 e.addEventListener("mouseenter",function(){hlBy(at,e.getAttribute(at),cls,true);});
 e.addEventListener("mouseleave",function(){hlBy(at,e.getAttribute(at),cls,false);});});}
wire("data-ref","hl"); wire("data-net","net-hl");
// Sticky net selection: click a pad (or a sidebar pin chip) and every pad on
// that net glows gold, so you can trace what's tied together with net colours
// on OR off. Re-click the same net, or click the empty board, to clear. The
// editor drives it from the part POINTER-UP (a no-move click — the drag
// handlers preventDefault pointerdown, which suppresses a plain click); the
// read-only preview has no drag handlers, so a delegated click on gPads works.
var selNetCur=null;
function netAt(e){while(e&&e.getAttribute){var n=e.getAttribute("data-net");if(n)return n;if(e===svg)break;e=e.parentNode;}return null;}
function selNet(net){if(net&&selNetCur===net)net=null;selNetCur=net;
 document.querySelectorAll("[data-net]").forEach(function(e){
  var on=net!=null&&e.getAttribute("data-net")===net,pin=e.classList.contains("looppin");
  e.classList.toggle("net-sel-pin",on&&pin);
  e.classList.toggle("net-sel",on&&!pin);});}
if(RO)gPads.addEventListener("click",function(ev){var net=netAt(ev.target);if(net){ev.stopPropagation();selNet(net);}});
var VBW=PCB.w,VBH=PCB.h,vb={x:0,y:0,w:VBW,h:VBH};
function setVB(){svg.setAttribute("viewBox",vb.x.toFixed(1)+" "+vb.y.toFixed(1)+" "+vb.w.toFixed(1)+" "+vb.h.toFixed(1));}
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
svg.addEventListener("pointerdown",function(ev){if(ev.target!==svg)return;ev.preventDefault();
 if(SPACE||ev.button===1){pan={cx:ev.clientX,cy:ev.clientY,vx:vb.x,vy:vb.y,moved:false};
  svg.setPointerCapture(ev.pointerId);svg.style.cursor="grabbing";return;}
 var m=mm(ev);marq={x0:m.x,y0:m.y,x1:m.x,y1:m.y,moved:false};svg.setPointerCapture(ev.pointerId);
 marqEl=el("rect",{"class":"marquee",x:0,y:0,width:0,height:0});gU.appendChild(marqEl);});
svg.addEventListener("pointermove",function(ev){
 if(pan){var r=svg.getBoundingClientRect();
  if(Math.abs(ev.clientX-pan.cx)>3||Math.abs(ev.clientY-pan.cy)>3)pan.moved=true;
  vb.x=pan.vx-(ev.clientX-pan.cx)*(vb.w/r.width);vb.y=pan.vy-(ev.clientY-pan.cy)*(vb.h/r.height);setVB();return;}
 if(marq){var m=mm(ev);marq.x1=m.x;marq.y1=m.y;
  if(Math.abs(m.x-marq.x0)>0.2||Math.abs(m.y-marq.y0)>0.2)marq.moved=true;
  var ax=Math.min(marq.x0,marq.x1),ay=Math.min(marq.y0,marq.y1),bx=Math.max(marq.x0,marq.x1),by=Math.max(marq.y0,marq.y1);
  marqEl.setAttribute("x",X(ax).toFixed(1));marqEl.setAttribute("y",Y(ay).toFixed(1));
  marqEl.setAttribute("width",((bx-ax)*S).toFixed(1));marqEl.setAttribute("height",((by-ay)*S).toFixed(1));return;}});
svg.addEventListener("pointerup",function(ev){try{svg.releasePointerCapture(ev.pointerId);}catch(e){}
 if(pan){var click=!pan.moved;pan=null;svg.style.cursor="";if(click){selClear();clearSel();selNet(null);}return;}
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
function drawRoute(){while(gT.firstChild)gT.removeChild(gT.firstChild);
 (PCB.tracks||[]).forEach(function(t){gT.appendChild(el("line",{x1:X(t.x1).toFixed(1),y1:Y(t.y1).toFixed(1),
   x2:X(t.x2).toFixed(1),y2:Y(t.y2).toFixed(1),stroke:t.l==0?"#f85149":"#388bfd",
   "stroke-width":Math.max(t.w*S,1.2).toFixed(1),"stroke-linecap":"round","stroke-linejoin":"round",opacity:0.85}));});
 (PCB.vias||[]).forEach(function(v){drawVia(gT,v.x,v.y,v.d,viaGeo().drill);});}
function clrVal(){var ci=document.getElementById("r-cl"),c=ci?parseFloat(ci.value):NaN;
 return (c>0)?c:(PCB.clr||0.127);}
function drawClr(){while(gC.firstChild)gC.removeChild(gC.firstChild);
 var cb=document.getElementById("r-clr-show"); if(!cb||!cb.checked)return;
 var clr=clrVal();
 P.forEach(function(p,i){p.pads.forEach(function(pad){var r=wrect(i,pad);
   gC.appendChild(el("rect",{x:X(r.x0-clr).toFixed(1),y:Y(r.y0-clr).toFixed(1),
     width:((r.x1-r.x0+2*clr)*S).toFixed(1),height:((r.y1-r.y0+2*clr)*S).toFixed(1),
     rx:(clr*S).toFixed(1),fill:"rgba(210,153,34,0.13)",stroke:"#d29922","stroke-width":0.8,"stroke-dasharray":"3 2"}));});});
 (PCB.vias||[]).forEach(function(v){gC.appendChild(el("circle",{cx:X(v.x).toFixed(1),cy:Y(v.y).toFixed(1),
   r:((v.d/2+clr)*S).toFixed(1),fill:"rgba(210,153,34,0.13)",stroke:"#d29922","stroke-width":0.8,"stroke-dasharray":"3 2"}));});
 (PCB.tracks||[]).forEach(function(t){gC.appendChild(el("line",{x1:X(t.x1).toFixed(1),y1:Y(t.y1).toFixed(1),
   x2:X(t.x2).toFixed(1),y2:Y(t.y2).toFixed(1),stroke:"#d29922","stroke-opacity":0.20,
   "stroke-width":((t.w+2*clr)*S).toFixed(1),"stroke-linecap":"round"}));});}
var clrCb=document.getElementById("r-clr-show");
if(clrCb)clrCb.addEventListener("change",drawClr);
var clrIn=document.getElementById("r-cl");
if(clrIn)clrIn.addEventListener("input",drawClr);
function drawDrc(){while(gD.firstChild)gD.removeChild(gD.firstChild);
 var cb=document.getElementById("r-drc-show"); if(cb&&!cb.checked)return;
 (PCB.drc||[]).forEach(function(d){var cx=X(d.x),cy=Y(d.y);
   var t=el("title",{}); t.textContent=d.k+" — gap "+d.gap.toFixed(3)+" mm < "+d.clr+" mm";
   var c=el("circle",{cx:cx.toFixed(1),cy:cy.toFixed(1),r:8,fill:"none",stroke:"#ef4444","stroke-width":2}); c.appendChild(t);
   gD.appendChild(c);
   gD.appendChild(el("circle",{cx:cx.toFixed(1),cy:cy.toFixed(1),r:2.4,fill:"#ef4444"}));});}
var drcCb=document.getElementById("r-drc-show");
if(drcCb)drcCb.addEventListener("change",drawDrc);
function setStat(id,cls,txt){var e=document.getElementById(id);
 if(e){e.className="route-stat"+(cls?" "+cls:"");e.textContent=txt;}}
function clearRoute(){if(!(PCB.tracks&&PCB.tracks.length)&&!(PCB.vias&&PCB.vias.length)&&!(PCB.drc&&PCB.drc.length))return;
 PCB.tracks=[];PCB.vias=[];PCB.drc=[];drawRoute();drawClr();drawDrc();setStat("r-stat","","");setStat("r-drc","","");setStat("r-rp","","");}
var courtState=null;
function partByRef(ref){for(var i=0;i<P.length;i++)if(P[i].ref===ref)return P[i];return null;}
function gceil(v){return Math.ceil(v/G-1e-9)*G;}
function padExt(p){var hw=0,hh=0;p.pads.forEach(function(pd){
 hw=Math.max(hw,Math.abs(pd.x)+pd.w/2);hh=Math.max(hh,Math.abs(pd.y)+pd.h/2);});return {hw:hw,hh:hh};}
function courtDraw(p,hw,hh){var s=document.getElementById("court-svg");while(s.firstChild)s.removeChild(s.firstChild);
 var VB=260,VH=220,pd=28,sc=Math.min((VB-pd)/(2*hw),(VH-pd)/(2*hh)),cx=VB/2,cy=VH/2;
 var g=el("g",{transform:"translate("+cx+","+cy+")"});s.appendChild(g);
 g.appendChild(el("rect",{x:(-hw*sc).toFixed(1),y:(-hh*sc).toFixed(1),width:(2*hw*sc).toFixed(1),height:(2*hh*sc).toFixed(1),
   rx:3,fill:"none",stroke:p.kind=="hub"?"#58a6ff":"#8b949e","stroke-width":1.4,"stroke-dasharray":"5 3"}));
 p.pads.forEach(function(pad){g.appendChild(FP.padShape(pad,{scale:sc,minPx:2,attrs:{fill:"#b08d57"}}));});}
function courtBox(){var c=courtState;return c.mode=="offset"?{hw:gceil(c.ext.hw+c.offset),hh:gceil(c.ext.hh+c.offset)}:{hw:c.hw,hh:c.hh};}
function courtRefresh(){if(!courtState)return;var b=courtBox();courtDraw(courtState.p,b.hw,b.hh);
 document.getElementById("court-full").textContent="full "+(2*b.hw).toFixed(2)+" × "+(2*b.hh).toFixed(2)+" mm";}
function courtSetMode(m){if(!courtState)return;courtState.mode=m;
 document.getElementById("court-fields-size").hidden=(m!="size");
 document.getElementById("court-fields-offset").hidden=(m!="offset");courtRefresh();}
function openCourt(ref){var p=partByRef(ref);if(!p)return;var ext=padExt(p),cm=PCB.cmargin||0.15;
 var min={hw:gceil(ext.hw+cm),hh:gceil(ext.hh+cm)};
 courtState={p:p,fp:p.fp,mode:"size",hw:p.hw,hh:p.hh,offset:0.2,ext:ext,min:min};
 document.getElementById("court-title").textContent=p.fp+"  ·  "+p.ref;
 var hwI=document.getElementById("court-hw"),hhI=document.getElementById("court-hh"),offI=document.getElementById("court-off");
 var sv=document.getElementById("court-save"),note=document.getElementById("court-note"),msg=document.getElementById("court-msg");
 msg.textContent="";hwI.value=p.hw.toFixed(1);hhI.value=p.hh.toFixed(1);hwI.min=min.hw;hhI.min=min.hh;offI.value=(0.2).toFixed(2);
 var fab=p.fb||!p.fp,noPads=!(ext.hw>0||ext.hh>0);
 sv.disabled=fab;hwI.disabled=fab;hhI.disabled=fab;offI.disabled=fab||noPads;
 document.querySelectorAll("input[name=court-mode]").forEach(function(r){r.checked=(r.value=="size");r.disabled=fab||(r.value=="offset"&&noPads);});
 courtSetMode("size");
 note.textContent=fab?"Synthesized placeholder box (no footprint file) — courtyard can't be edited.":
  "Overall size sets the half-extents directly; Pad offset puts the courtyard edge that gap "+
  "outside the pad bounding box, snapped to the 0.2 mm grid. "+
  "Saving rewrites lib/footprints/"+p.fp+".sexp and applies to every design using it.";
 document.getElementById("court-modal").hidden=false;}
function courtClose(){document.getElementById("court-modal").hidden=true;courtState=null;}
document.querySelectorAll("[data-court-ref]").forEach(function(b){
 b.addEventListener("click",function(){openCourt(b.getAttribute("data-court-ref"));});});
var cxBtn=document.getElementById("court-x"),ccBtn=document.getElementById("court-cancel"),modalBg=document.getElementById("court-modal");
if(cxBtn)cxBtn.addEventListener("click",courtClose);
if(ccBtn)ccBtn.addEventListener("click",courtClose);
if(modalBg)modalBg.addEventListener("click",function(ev){if(ev.target===modalBg)courtClose();});
document.querySelectorAll("input[name=court-mode]").forEach(function(r){
 r.addEventListener("change",function(){if(r.checked)courtSetMode(r.value);});});
function courtInput(which){if(!courtState)return;var inp=document.getElementById(which=="hw"?"court-hw":"court-hh");
 var v=Math.round(parseFloat(inp.value)/G)*G;if(!(v>0))v=courtState.min[which];
 v=Math.max(v,courtState.min[which]);courtState[which]=v;inp.value=v.toFixed(1);courtRefresh();}
var hwI2=document.getElementById("court-hw"),hhI2=document.getElementById("court-hh");
if(hwI2)hwI2.addEventListener("change",function(){courtInput("hw");});
if(hhI2)hhI2.addEventListener("change",function(){courtInput("hh");});
var offI2=document.getElementById("court-off");
if(offI2)offI2.addEventListener("change",function(){if(!courtState)return;var v=parseFloat(offI2.value);
 if(!(v>=0))v=0;v=Math.round(v/0.05)*0.05;courtState.offset=v;offI2.value=v.toFixed(2);courtRefresh();});
var csv=document.getElementById("court-save");
if(csv)csv.addEventListener("click",function(){if(!courtState||!courtState.fp)return;
 var msg=document.getElementById("court-msg");msg.style.color="#8b949e";msg.textContent="saving…";
 var body=courtState.mode=="offset"?{fp:courtState.fp,mode:"offset",offset:courtState.offset}
   :{fp:courtState.fp,mode:"size",hw:courtState.hw,hh:courtState.hh};
 fetch("/api/courtyard/"+encodeURIComponent(PCB.name),{method:"POST",headers:{"Content-Type":"application/json"},
   body:JSON.stringify(body)})
  .then(function(r){if(!r.ok)throw 0;return r.json();})
  .then(function(){msg.style.color="#3fb950";msg.textContent="saved ✓ — rebuilding";
    window.location="/pcb-layout/"+encodeURIComponent(PCB.name)+"?regen=1";})
  .catch(function(){msg.style.color="#f85149";msg.textContent="save failed";});});
var rgo=document.getElementById("r-go");
if(rgo)rgo.addEventListener("click",function(){
 var nf=function(id){return parseFloat(document.getElementById(id).value);};
 var hint=document.getElementById("r-hint");if(hint)hint.style.display="none";
 setStat("r-stat","","routing…");setStat("r-drc","","");rgo.disabled=true;
 var payload={parts:P.map(function(p){return {ref:p.ref,x:p.x,y:p.y,rot:p.rot||0};}),
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
    setStat("r-stat",ok?"ok":"warn","routed "+j.routed+"/"+j.total+" nets · "+((j.vias||[]).length)+" vias");
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
       setTimeout(function(){window.location.reload();},400);}
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
if(rgh)rgh.addEventListener("click",function(ev){ev.preventDefault();if(onSub()){subReload();return;}liveRegen("?rough=1");});
// ── Collapsible control deck (accordion) + board-view overlays ──────────
(function(){
 var chips=Array.prototype.slice.call(document.querySelectorAll(".tab-chip"));
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
function applyHeat(){
 P.forEach(function(p,i){var g=els[i];if(!g)return;var ct=g.querySelector(".court");if(!ct)return;
  var tt=g.querySelector("title");
  if(!heatOn||p.ref===anchorRef){ct.setAttribute("fill","#161b22");if(tt)tt.remove();return;}
  var b=p.blame||0,t=heatScale>0?b/heatScale:0;
  ct.setAttribute("fill",blameColor(t));
  if(!tt){tt=document.createElementNS(NS,"title");g.appendChild(tt);}
  tt.textContent=p.ref+" \u{00b7} blame "+b.toFixed(1)+" ("+Math.round(Math.min(t,1)*100)+"% of scale "+heatScale.toFixed(1)+")";});}
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
function applyNetColors(){var pads=gPads.querySelectorAll(".pad");
 for(var i=0;i<pads.length;i++){var pe=pads[i];
  if(!netColOn){pe.setAttribute("fill","#b08d57");continue;}
  var nk=pe.getAttribute("data-net");
  pe.setAttribute("fill",nk?(netColorOf(nk)||"#b08d57"):"#ffffff");}}
var netColCb=document.getElementById("v-netcol");
if(netColCb)netColCb.addEventListener("change",function(){netColOn=netColCb.checked;
 var nl=document.getElementById("net-legend");if(nl)nl.hidden=!netColOn;
 applyNetColors();rats();});
applyNetColors(); rats(); showScore(PCB.auto); drawRoute(); drawClr(); drawDrc();
markUnplaced(PCB.placement&&PCB.placement.unplaced);
// ── Cross-probe focus: ?focus=REF (or #REF) selects that part on load —
//    zoom/centre the view on it, flash its courtyard, and reveal it in the
//    component sidebar. Exact ref first, then the bare sub-block leaf
//    (focus=U2 matches ldo/U2), mirroring the PNG renderer's ?refs= rule.
(function(){
 var want="";
 try{want=new URLSearchParams(location.search).get("focus")||"";}catch(e){}
 if(!want&&location.hash.length>1)want=decodeURIComponent(location.hash.slice(1));
 if(!want)return;
 function leaf(r){var i=r.lastIndexOf("/");return i<0?r:r.slice(i+1);}
 var idx=-1;
 P.forEach(function(p,i){if(idx<0&&p.ref===want)idx=i;});
 if(idx<0)P.forEach(function(p,i){if(idx<0&&leaf(p.ref)===want)idx=i;});
 if(idx<0)return;
 var p=P[idx],cx=X(p.x),cy=Y(p.y);
 var fw=Math.min(VBW,Math.max(VBW*0.35,(2*p.hw+14)*S*4));
 vb={x:cx-fw/2,y:cy-fw*(VBH/VBW)/2,w:fw,h:fw*(VBH/VBW)};setVB();
 els[idx].classList.add("focus-flash");
 setTimeout(function(){els[idx].classList.remove("focus-flash");},2600);
 selectComp(p.ref);
})();
})();
