(function(){
const NS="http://www.w3.org/2000/svg";
const S=PCB.scale,MX=PCB.minx,MY=PCB.miny,M=PCB.margin,G=PCB.grid;
// One constraint/curve kernel serves every closed editable board shape.
const OS=window.PCBShapeSketch||window.PCBOutlineSketch||null;
const P=PCB.parts,PED=PCB.part_edits||{};
P.forEach(function(p){var e=PED[p.ref];if(e){p.src=e.src;p.srcName=e.srcName;p.srcRef=e.srcRef;}});
// A null generated fabrication mark is deliberate for reusable sub-circuits.
// Drop any older adopted copy from the live artwork too; ordinary authored
// board text remains untouched, and complete boards receive PCB.fab_text.
if(!PCB.fab_text)PCB.texts=(PCB.texts||[]).filter(function(t){return !t.fabrication_id;});
const orig=P.map(function(p){return {x:p.x,y:p.y,rot:p.rot||0,side:p.side||"top"};});
var RO=!!PCB.ro;
var MOBILE_MQ=window.matchMedia?window.matchMedia("(max-width: 920px)"):{matches:false};
var COMPACT_DOCK_MQ=window.matchMedia?window.matchMedia("(min-width: 921px) and (max-width: 1560px)"):{matches:false};
function mobileInspectMode(){
 var body=document.body;
 return !!body&&!body.classList.contains("embed")&&!!MOBILE_MQ.matches;
}
function compactDockMode(){
 var body=document.body;
 return !!body&&!body.classList.contains("embed")&&!!COMPACT_DOCK_MQ.matches;
}
// Assembly/debug embeds ask for a physical board presentation. Keep it scoped
// to the read-only `?review=1` surface so the PCB editor retains its authored
// KiCad layer colours and editing overlays.
var PHYSICAL_REVIEW=RO&&/(?:^|[?&])review=1(?:&|$)/.test(window.location.search);
// ── WebGPU renderer (default-on, ?gpu=0 opts out) + benchmark (?fbench=1) ──
// GPU_REQ is decided ONCE at load: on wherever the browser exposes WebGPU,
// unless ?gpu=0. A browser with no navigator.gpu (and the Node bench, whose
// stub has none) takes the 2D path with every seam a dead branch. It has to be
// a synchronous load-time read rather than an init result because it also
// picks the 2D context's alpha mode, which is fixed for the canvas' lifetime
// and must be decided before the async PCBGpu.init can answer. Alpha:true on
// a machine whose adapter then refuses is harmless: scenePaint still fills the
// full opaque background.
var QS=(window.location&&window.location.search)||"";
// The thermal review is a navigation-first read-only surface: an ordinary
// left drag moves the viewport instead of drawing the editor's selection box.
// Keep this narrower than PHYSICAL_REVIEW so assembly clicks retain their
// existing inspection gesture.
var THERMAL_REVIEW=PHYSICAL_REVIEW&&/(?:^|[?&])thermal=1(?:&|$)/.test(QS);
var GPU_REQ=!/(?:^|[?&])gpu=0(?:&|$)/.test(QS)&&!!(window.navigator&&window.navigator.gpu),
    FBENCH=/(?:^|[?&])fbench=1(?:&|$)/.test(QS);
// True only once PCBGpu.init has RESOLVED successfully (adapter + device +
// pipelines). Everything gated on it is therefore off for the whole page life
// unless the flag was passed AND the browser delivered a device.
var gpuOn=false,
    // Per-FRAME: does the GPU own copper+pads for the paint currently running?
    // scenePaint sets it around its static-branch paintScene call and clears it
    // after, so the drag-cache branch and the overscan bake (both of which must
    // render the whole scene in 2D) can never observe it set.
    gpuScene=false;
// ── Board layer table (the server blob's ONE layer wire format) ─────────
// PCB.layer_table = [{i,l,name,kind,net,c[,implicit]}, …] — one row per
// PHYSICAL copper layer, top→bottom. `i` is the 1-based stack position, `l`
// the ROUTABLE signal index tracks carry (null on a plane-claimed inner,
// which can hold no track), `kind` "signal"/"plane", `net` the poured net.
// Both registries below are DERIVED from it, so they can never disagree;
// nothing hard-codes the layer count and a blob without the key falls back to
// the classic two-layer board.
// PCB.layer_names = {f_cu,b_cu,f_silks,b_silks,edge_cuts,f_crtyd,b_crtyd} —
// the FIXED layer spellings, emitted next to the table above straight out of
// src/board_layers.zig. Every layer name below comes from here (including the
// two-layer fallback's), so the viewer never spells a KiCad layer of its own.
var LN=PCB.layer_names||{};
var LT=(PCB.layer_table&&PCB.layer_table.length)?PCB.layer_table:[
 {i:1,l:0,name:LN.f_cu,kind:"signal",net:null,c:"#C83434"},
 {i:2,l:1,name:LN.b_cu,kind:"signal",net:null,c:"#4D7FC4"}];
// The inspector's side labels ("Top (…)" / "Bottom (…)"), named once so the
// select, the read-only row and the pour dialog all print the same words.
function sideLabel(bottom){return bottom?("Bottom ("+LN.b_cu+")"):("Top ("+LN.f_cu+")");}
// The PHYSICAL stack. `plane` is the poured-net accessor every reader below
// uses (null on a signal row); plane rows keep l:null deliberately.
var STACK=LT.map(function(r){return {i:r.i,l:(typeof r.l==="number")?r.l:null,name:r.name,
 kind:r.kind||"signal",plane:(r.net!=null)?r.net:null,c:r.c,implicit:!!r.implicit};});
// The ROUTABLE layers only, in signal-index order: 0=top(F.Cu),
// 1=bottom(B.Cu), 2..=plane-free inner layers in stack order.
var LYR=STACK.filter(function(r){return typeof r.l==="number";})
 .sort(function(a,b){return a.l-b.l;}).map(function(r){return {l:r.l,name:r.name,c:r.c};});
var NSIG=LYR.length;
// ── KiCad pcbnew board theme ─────────────────────────────────────────────
// ONE palette for everything the canvas paints, shipped by the server as
// PCB.theme straight out of src/board_theme.zig — the same table the PNG
// renderer, the replay client and the page's :root custom properties read, so
// a colour can never mean two things across the four surfaces. The copper
// layer colours themselves ride the layer table above (same origin).
//
// The literals here are the NO-BLOB fallback (a fixture may load this script
// with no PCB at all) and are the identical values. The fallback fixes the
// object's shape, so every TH.xxx read site keeps working whatever a blob
// carries — and the SERVER's own keys are then laid over it, so a colour added
// to board_theme.zig reaches the canvas without a JS edit. (It used to iterate
// the fallback for that second pass, which silently dropped every key the
// fallback had not been taught yet.) Non-string members are skipped, which is
// what keeps TH from adopting the nested `review` palette object.
function themeFrom(base,src){var o={},k;for(k in base)o[k]=base[k];
 if(src)for(k in src)if(typeof src[k]==="string"&&src[k])o[k]=src[k];
 return o;}
var TH=themeFrom({bg:"#001023",  // canvas: KiCad dark navy
 gridDot:"#2a3a4a",              // grid-dot overlay
 court:"rgba(216,100,255,0.35)", // courtyard: dim KiCad magenta outline
 courtLine:"#D864FF",            // …the same magenta undimmed
 padTop:"#C83434",padBot:"#4D7FC4", // SMD pads in their face's copper colour
 pth:"#d0a028",                  // plated through-hole annulus gold
 npth:"#26323e",                 // non-plated hole rim (no copper)
 hole:"#001023",                 // drilled bore
 silk:"#F0F0F0",silkBot:"#E8B2C8", // F./B. silkscreen
 edge:"#D0D2CD",                 // committed board outline
 via:"#B2B27A",viaHole:"#001023",  // via annulus / hole
 rats:"rgba(255,255,255,0.35)",  // ratsnest: thin solid white
 ratsLine:"#ffffff",             // …the same white undimmed
 drc:"#f4432c",                  // DRC markers (red-orange)
 sel:"#d2a8ff",                  // selected copper / multi-selected courtyards
 accent:"#f5c542",               // focus-mode spotlight (matches the PNG)
 awProx:"#ea580c",               // hot decoupling loop / proximity hug
 awGnd:"#22b8cf",                // ground-return airwire
 awOther:"#9aa7b4",              // any other connection class
 loopRet:"#58a6ff"},             // L2 ground-return overlay
 PCB.theme);
// Physical review palette: green FR-4 solder mask, muted copper visible below
// it, and bare ENIG-like copper inside the generated solder-mask openings.
// Server-shared as PCB.theme.review, same fallback rule as TH.
var PH=themeFrom({bg:"#101815",mask:"#086b43",edge:"#786744",opening:"#a1854e",substrate:"#544b36",
 copper:"#cfaf62",copperUnder:"#c0aa62",viaMask:"#417b50",npth:"#313c35",
 hole:"#101815",silk:"#f4f3e9",pin1:"#ff3b30"},PCB.theme&&PCB.theme.review);
// Assembly's manufactured artwork comes from ordered operations parsed back
// from the exact generated Gerber/Excellon bytes. The ordinary PCB editor has
// no `PCB.cam` payload and keeps its semantic, editable paint pipeline.
var CAM_REVIEW=PHYSICAL_REVIEW&&PCB.cam&&PCB.cam.source==="generated-gerber"&&Array.isArray(PCB.cam.layers);
var camVisibility={copper:true,inner_copper:false,mask:true,paste:false,silk:true,drills:true,outline:true,components:true};
function camVisible(k){return camVisibility[k]!==false;}
// Exact manufacturing artwork is deliberately not in the page HTML. Paint the
// semantic board first, then fetch the dependency-cached Gerber/Excellon
// read-back after two frames so CAM generation and JSON parsing cannot delay
// the first useful assembly view.
function loadCamReview(){
 if(!PHYSICAL_REVIEW||!PCB.cam_url||CAM_REVIEW)return;
 var start=function(){fetch(PCB.cam_url).then(function(r){if(!r.ok)throw 0;return r.json();})
  .then(function(cam){if(!cam||cam.source!=="generated-gerber"||!Array.isArray(cam.layers))return;
   PCB.cam=cam;CAM_REVIEW=true;camLayerCache={};dragCacheDrop();paintSoon();})
  .catch(function(){});};
 requestAnimationFrame(function(){requestAnimationFrame(start);});}
// Persistent assembly sprites are registered by pcb_model_sprites.js after
// the bare board has painted. The map stays empty on every other PCB surface,
// so the normal editor pays only one failed property lookup per visible part.
var assemblySprites={};
window.PCBSetAssemblySprite=function(fp,sprite){
 if(!PHYSICAL_REVIEW||!fp||!sprite||!sprite.image)return;
 assemblySprites[fp]=sprite;dragCacheDrop();paintSoon();};
function layerName(l){for(var i=0;i<LYR.length;i++)if(LYR[i].l===l)return LYR[i].name;return "L"+l;}
function layerColor(l){for(var i=0;i<LYR.length;i++)if(LYR[i].l===l)return LYR[i].c;return "#8b949e";}
function stackForSignal(l){for(var i=0;i<STACK.length;i++)if(STACK[i].l===l)return STACK[i];return null;}
function stackByIndex(i){for(var j=0;j<STACK.length;j++)if(STACK[j].i===i)return STACK[j];return null;}
// A #RRGGBB (theme or layer-table) colour as an rgba wash at alpha `a`. The
// ONE hex→rgba decode on this page, so a pour tint is never a second hand-typed
// spelling of the copper colour it dims.
function hexRgba(c,a){var m=/^#([0-9a-f]{6})$/i.exec(c||"");if(!m)return "rgba(139,148,158,"+a+")";
 var n=parseInt(m[1],16);return "rgba("+((n>>16)&255)+","+((n>>8)&255)+","+(n&255)+","+a+")";}
function stackRgba(L,a){return hexRgba((L&&L.c)||"#8b949e",a);}
// The layer's copper colour as an rgba wash at alpha `a` — so an inner-layer
// pour fill/rim reads in its own In-layer hue (the outer faces keep their
// hand-tuned red/blue washes; this is the fallback for signal index ≥2).
function layerRgba(l,a){var c=layerColor(l),m=/^#([0-9a-f]{6})$/i.exec(c);if(!m)return "rgba(139,148,158,"+a+")";
 var n=parseInt(m[1],16);return "rgba("+((n>>16)&255)+","+((n>>8)&255)+","+(n&255)+","+a+")";}
// Selected copper keeps its layer identity: mix the authored layer colour
// toward white instead of painting a wider, unrelated yellow stripe.
function layerHighlightColor(l){var c=layerColor(l),m=/^#([0-9a-f]{6})$/i.exec(c);if(!m)return c;
 var n=parseInt(m[1],16),mix=function(v){return Math.round(v+(255-v)*0.48);};
 return "rgb("+mix((n>>16)&255)+","+mix((n>>8)&255)+","+mix(n&255)+")";}
// Visibility key for a copper layer — its own CANONICAL name ("F.Cu",
// "In2.Cu", "B.Cu"). One string is the panel row's label, the painter's gate
// and the localStorage flag, so a layer cannot be spelled three ways.
function visKey(l){return layerName(l);}
// ── Tech (non-copper) layer rows ────────────────────────────────────────
// The STATIC half of the layer table: the fabrication layers every board
// carries, keyed like the copper rows by their canonical name. Board text and
// generated annotations use the F./B.Silkscreen rows according to their side;
// they are artwork on those fabrication layers, not a third layer. There is no
// F.Mask/B.Mask row: solder mask is drawn ONLY by the physical-review page,
// which is always a chrome-free read-only embed with no Appearance container
// at all, so a mask row would be a control nothing could ever reach.
var TECH=[
 {key:LN.f_silks,name:LN.f_silks,desc:"Front silkscreen",c:TH.silk},
 {key:LN.b_silks,name:LN.b_silks,desc:"Back silkscreen",c:TH.silkBot},
 {key:LN.edge_cuts,name:LN.edge_cuts,desc:"Board outline",c:TH.edge},
 {key:LN.f_crtyd,name:LN.f_crtyd,desc:"Front courtyards",c:TH.court},
 {key:LN.b_crtyd,name:LN.b_crtyd,desc:"Back courtyards",c:TH.court}];
// ── Live view state (layers / grid / units) — audit 1.5 ─────────────────
// Persisted per design in localStorage alongside the existing "pcb-rigid-off:"
// key. `G` stays the footprint-editor grid constant; snap uses gridMM (0 = off).
// Legacy persisted schema began `vis:{refdes:0,padnum:1,rats:0,drc:0,netcol:1,guides:0,...}`;
// visMigrate fans that single DRC bit out to both severity-specific layers.
var viewKey="pcb-view:"+PCB.name,viewSt={grid:G,units:"mm",active:0,stack:null,pourOp:0,vis:{refdes:0,padnum:1,rats:0,drc_err:0,drc_warn:0,netcol:1,guides:0,keepouts:1,antipads:0,clr:0,heatsink:1},filt:{fp:1,sub:1,pad:1,track:1,via:1,zone:1,drc:1,outline:1}};
function outlineOnlyFilter(){if(!viewSt.filt.outline)return false;for(var k in viewSt.filt)if(k!=="outline"&&viewSt.filt[k])return false;return true;}
// Copper defaults: every ROUTABLE layer visible. A PLANE row starts HIDDEN, so
// a board opens exactly as it always did (a plane used to render only while it
// was the viewed stack row) and its new eye is an opt-in comparison tool.
STACK.forEach(function(_L){viewSt.vis[_L.name]=(_L.l==null)?0:1;});
TECH.forEach(function(_T){viewSt.vis[_T.key]=1;});
// One-time legacy→canonical migration of a stored visibility map. The old
// namespace named copper by POSITION ("top"/"bottom"/"l2") and hid BOTH
// silkscreens behind one "silk" flag. Returns null when nothing legacy was
// found, so an already-canonical store is never rewritten.
function visMigrate(v){var out={},hit=false,k;
 for(k in v){var val=v[k];
  if(k==="top"){hit=true;out[layerName(0)]=val;}
  else if(k==="bottom"){hit=true;out[layerName(1)]=val;}
  else if(/^l[0-9]+$/.test(k)){hit=true;out[layerName(parseInt(k.slice(1),10))]=val;}
  else if(k==="silk"){hit=true;out[LN.f_silks]=val;out[LN.b_silks]=val;}
  else if(k==="drc"){hit=true;out.drc_err=val;out.drc_warn=val;}
  else if(k==="edge"){hit=true;out[LN.edge_cuts]=val;}
  else out[k]=val;}
 return hit?out:null;}
var _vmig=false;
try{var _vs=JSON.parse(localStorage.getItem(viewKey)||"null");if(_vs){
 if(typeof _vs.grid==="number")viewSt.grid=_vs.grid;
 if(_vs.units)viewSt.units=_vs.units;
 if(typeof _vs.active==="number")viewSt.active=_vs.active;
 if(typeof _vs.stack==="number")viewSt.stack=_vs.stack;
 if(typeof _vs.pourOp==="number")viewSt.pourOp=Math.max(0,Math.min(1,_vs.pourOp));
 if(_vs.vis){var _mv=visMigrate(_vs.vis);if(_mv)_vmig=true;var _sv=_mv||_vs.vis;
  for(var _k in viewSt.vis)if(_sv[_k]!==undefined)viewSt.vis[_k]=_sv[_k];}
 // Selection filters are temporary editing context. In particular, reopening
 // a board after using Outline only must not make every component and copper
 // object appear unresponsive. Legacy persisted filters are intentionally
 // ignored; the defaults above restore normal selection on every page load.
 }}catch(e){}
// These are no longer user-selectable modes: connection colour is the board's
// normal presentation, while the old all-board ratsnest and placement guides
// stay retired even when an older localStorage record had enabled them.
if(viewSt.vis.netcol!==1||viewSt.vis.rats!==0||viewSt.vis.guides!==0)_vmig=true;
viewSt.vis.netcol=1;viewSt.vis.rats=0;viewSt.vis.guides=0;
if(_vmig)viewSave(); // rewrite the store once, in the canonical spelling
function viewSave(){try{localStorage.setItem(viewKey,JSON.stringify(viewSt,function(k,v){return k==="filt"?undefined:v;}));}catch(e){}}
// Effective snap step (mm). grid "off" (0) → a tiny step so parts still move
// smoothly but aren't quantized.
function snapG(){return viewSt.grid>0?viewSt.grid:0.001;}
var activeLayer=(viewSt.active>=0&&viewSt.active<NSIG)?viewSt.active:0; // persisted signal-layer index
var activeStack=stackByIndex(viewSt.stack)?viewSt.stack:(stackForSignal(activeLayer)||STACK[0]).i;
// The review/assembly surface shares this persisted state but face-tests
// `(bot?1:0)===activeLayer` in every painter, so an INNER layer left active in
// the editor opened review on a near-blank board. Clamp to an outer face for
// this page only — viewSt is deliberately NOT rewritten, so the editor keeps
// the layer it was left on unless the reader picks another one here.
if(PHYSICAL_REVIEW&&activeLayer>1){activeLayer=0;activeStack=(stackForSignal(0)||STACK[0]).i;}
function focusedStack(){return stackByIndex(activeStack)||stackForSignal(activeLayer)||STACK[0];}
function focusedSignal(){var L=focusedStack();return L&&typeof L.l==="number"?L.l:null;}
function syncActiveLayer(){var ast=stackForSignal(activeLayer);if(ast)activeStack=ast.i;
 var s=document.getElementById("pcb-actlayer");if(s)s.value=String(activeStack);
 viewSt.active=activeLayer;viewSt.stack=activeStack;viewSave();
 if(PCB.apSync)PCB.apSync(); // Appearance panel active-layer row (full page)
 statusLayer();
 var b=document.getElementById("pcb-draw");/* drawBtnSync fills the label */ if(b&&typeof drawBtnSync==="function")drawBtnSync();}
function selectActiveLayer(nl){if(!(nl>=0&&nl<NSIG))return;
 // Selecting copper implies showing it. This is especially important for inner
 // layers: a persisted hidden-eye setting otherwise makes a valid custom pour
 // look absent even while its layer row says ACTIVE.
 viewSt.vis[visKey(nl)]=1;
 activeLayer=nl;var st=stackForSignal(nl);if(st)activeStack=st.i;
 if(dtrace)dtrace.l=activeLayer;syncActiveLayer();keepoutGeomDrop();dragCacheDrop();paintSoon();}
function selectStackLayer(si){var st=stackByIndex(si);if(!st)return;
 activeStack=st.i;if(typeof st.l==="number"){selectActiveLayer(st.l);return;}
 // Viewing a PLANE implies showing it — the same rule selectActiveLayer applies
 // to routable copper, so clicking a row can never leave a blank board.
 viewSt.vis[st.name]=1;
 viewSt.stack=activeStack;viewSave();if(PCB.apSync)PCB.apSync();statusLayer();keepoutGeomDrop();dragCacheDrop();paintSoon();}
window.PCBSelectLayer=selectActiveLayer;
// ── KiCad status bar (full page only — the ids are absent on embeds) ────
function stSet(id,t){var e=document.getElementById(id);if(e)e.textContent=t;}
function statusLayer(){var sw=document.getElementById("st-layer-sw");
 var L=focusedStack();if(sw)sw.style.background=L.c||"#8b949e";
 stSet("st-layer-nm",L.name+(L.l==null&&L.plane?" · "+L.plane+" plane":""));}
// mm↔mil display formatting (display only — the model stays mm).
function fmtLen(mm){if(viewSt.units==="mil")return (mm/0.0254).toFixed(1)+" mil";return mm.toFixed(2)+" mm";}
function fmtLen2(mm){if(viewSt.units==="mil")return (mm/0.0254).toFixed(0)+" mil";return mm.toFixed(2)+" mm";}
// Status-bar live segments: cursor position, drag delta, zoom %, hovered part/net.
function statusXY(m){stSet("st-xy","x "+fmtLen(m.x)+"   y "+fmtLen(m.y));}
function statusZoom(){stSet("st-zoom","zoom "+Math.round(100*VBW/vb.w)+"%");}
function statusDelta(m){var t="";
 if(typeof drag!=="undefined"&&drag&&drag.active)t="dx "+fmtLen(m.x-drag.m0.x)+"  dy "+fmtLen(m.y-drag.m0.y);
 else if(typeof gdrag!=="undefined"&&gdrag&&gdrag.active)t="dx "+fmtLen(m.x-gdrag.sx)+"  dy "+fmtLen(m.y-gdrag.sy);
 stSet("st-dxdy",t);}
// Routed copper totals for one net, summed from the drawn tracks/vias (covers
// both freshly-routed and persisted copper — whatever is currently on the board).
function netCopperStats(net){var mm=0,vias=0;
 (PCB.tracks||[]).forEach(function(t){if(t.net===net)mm+=trackLength(t);});
 (PCB.vias||[]).forEach(function(v){if(v.net===net)vias++;});
 return {mm:mm,vias:vias};}
function statusHover(m,pointNet){var t="",net=hoverNet||pointNet;
 if(net){t=net;if(hoverNet){var s=netCopperStats(net);
  if(s.mm>0)t+=" · "+fmtLen(s.mm);
  if(s.vias>0)t+=" · "+s.vias+" via"+(s.vias>1?"s":"");}}
 else if(cur>=0&&P[cur]){t=refLabel(P[cur].ref);
  var pd=m?padAt(cur,m.x,m.y):null;
  if(pd&&pd.net)t+=" · "+pd.net;
  else if(P[cur].val)t+=" · "+P[cur].val;}
 stSet("st-hover",t);}
// `?sub=` query for a sub-circuit page so layout save/delete/star/rescore POST
// to the per-sub sidecar (<design>.<sub>.layouts.json) instead of the design's.
// Empty on a normal design/module page.
function subq(){return (PCB.sub&&PCB.sub.length)?("?sub="+encodeURIComponent(PCB.sub)):"";}
const X=function(mm){return (mm-MX+M)*S;}, Y=function(mm){return (mm-MY+M)*S;};
// Via copper and drill bores are fabrication geometry, so unlike interaction
// fringes they must never acquire a minimum display size. A screen-space floor
// changes the apparent diameter on wide boards where the fit scale is small.
function viaRenderRadius(mm){return mm*S/2;}
const svg=document.getElementById("pcb-svg");
const sceneHost=svg.parentNode,sceneShell=document.createElement("div");
sceneShell.className="pcb-scene-shell";
sceneHost.insertBefore(sceneShell,svg);sceneShell.appendChild(svg);
// ── Cached viewport geometry ────────────────────────────────────────────
// getBoundingClientRect / clientWidth / offsetLeft each force a synchronous
// layout, and the pointer and paint paths interleave them with the viewBox
// writes setVB makes — a layout flush per pointermove and per frame. The svg's
// box only moves when something reflows it, so measure once and drop the cache
// on every event that can move or resize it. Registered BEFORE the other
// resize/observer handlers so their re-derived viewports read fresh numbers.
var svgMetrics=null;
function svgMetricsGet(){if(!svgMetrics){var r=svg.getBoundingClientRect();
  svgMetrics={left:r.left,top:r.top,width:r.width,height:r.height,
   cw:svg.clientWidth,ch:svg.clientHeight,offsetLeft:svg.offsetLeft,offsetTop:svg.offsetTop};}
 return svgMetrics;}
function svgMetricsDrop(){svgMetrics=null;}
window.addEventListener("resize",svgMetricsDrop);
window.addEventListener("scroll",svgMetricsDrop,true); // a scrolled embed moves the rect without resizing it
if(typeof ResizeObserver!=="undefined"){try{
 new ResizeObserver(svgMetricsDrop).observe(sceneShell);}catch(e){}} // panel/accordion reflows carry no resize event
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
// One context for the canvas' lifetime. alpha:false — scenePaint always
// fills the full background, so opaque compositing is free speed. Under
// ?gpu=1 the background moves to the WebGPU canvas UNDERNEATH this one, so
// this surface must be able to clear to transparent instead.
const CTX=CV.getContext("2d",{alpha:GPU_REQ});
// Physical outline, under everything: the layout's user-DRAWN outline when
// one exists (PCB.outline, editable via the ▭ Outline tool and saved with
// the layout), else the authored (board (size W H) …) rectangle.
var gB=document.createElementNS(NS,"g");
svg.insertBefore(gB,gR); gB.style.pointerEvents="none";
PCB.outline=PCB.outline||((PCB.outline_drawn&&PCB.board)?{x:PCB.board.x,y:PCB.board.y,w:PCB.board.w,h:PCB.board.h,pts:(PCB.board_poly||null)}:null);
PCB.fabrication_layers=PCB.fabrication_layers||[];
PCB.heatsink=PCB.heatsink||null;
var fabricationDefaults=JSON.parse(JSON.stringify(PCB.fabrication_layers));
// Rounded-outline tessellation is world geometry, independent of viewport and
// paint state.  In particular, board-silkscreen clipping asks boardShape() for
// every sampled point along every generated group corner.  Re-filleting a
// rounded outline in that inner loop made one 20-corner board spend ~110 ms per
// drag frame.  Keep the exact geometry until an outline edit invalidates it.
var outlineGeomRev=0,outlineFilletCache=null,boardShapeCache=null,outlineFilletBuilds=0;
function outlineGeomDrop(){outlineGeomRev++;outlineFilletCache=null;boardShapeCache=null;}
// Return the exact native fillets plus a fine chord polygon used only by the
// browser DRC. The persisted outline remains nominal vertices + radii.
function outlineFilletGeom(o){var pts=outlinePtsOf(o),rs=o&&o.radii;
 if(OS&&o&&o.sketch){var sg=OS.compile(o.sketch);if(sg)return {points:sg.points,arcs:sg.arcs,sketch:sg,nominal:sg.nominal};}
 if(!pts||pts.length<3||!rs||rs.length!==pts.length)return {points:pts||[],arcs:[]};
 if(outlineFilletCache&&outlineFilletCache.o===o&&outlineFilletCache.rev===outlineGeomRev)return outlineFilletCache.geom;
 outlineFilletBuilds++;
 var fs=[],n=pts.length;
 for(var i=0;i<n;i++)fs.push(arcCorner({x:pts[(i+n-1)%n][0],y:pts[(i+n-1)%n][1]},
  {x:pts[i][0],y:pts[i][1]},{x:pts[(i+1)%n][0],y:pts[(i+1)%n][1]},Math.max(0,+rs[i]||0)));
 var out=[],arcs=[];function push(p){var q=out[out.length-1];if(!q||Math.hypot(q[0]-p.x,q[1]-p.y)>1e-7)out.push([p.x,p.y]);}
 for(var j=0;j<n;j++){var f=fs[j];if(!f){push({x:pts[j][0],y:pts[j][1]});continue;}
  push(f.p1);for(var k=1;k<f.points.length;k++)push(f.points[k]);arcs.push(f);}
 var geom={points:out,arcs:arcs,corners:fs};
 outlineFilletCache={o:o,rev:outlineGeomRev,geom:geom};return geom;}
window.PCBOutlinePoly=function(o){return outlineFilletGeom(o).points;};
function authoredOutlineSeed(){var b=PCB.board,as=PCB.board_arcs||[];if(!b||as.length!==4)return null;
 var rs=as.map(function(a){var g=trackArcGeom(a);return g?g.r:0;});
 return {x:b.x,y:b.y,w:b.w,h:b.h,pts:[[b.x,b.y],[b.x+b.w,b.y],[b.x+b.w,b.y+b.h],[b.x,b.y+b.h]],radii:rs};}
var backingMode=false,backingDrag=null,backingEdit=null;
function backingLayer(){return backingEdit&&backingEdit.layer||null;}
function backingPts(){return backingEdit&&backingEdit.poly||null;}
function backingAt(m){var ls=PCB.fabrication_layers||[];for(var li=ls.length-1;li>=0;li--){var rs=ls[li].regions||[];for(var ri=rs.length-1;ri>=0;ri--){var pts=rs[ri];if(pts&&pts.length>=3&&(polyContains(pts,m.x,m.y)||nearPolyEdge(pts,m.x,m.y,7/S)))return {layer:ls[li],index:ri,poly:pts,sketch:(ls[li].sketches||[])[ri]||null};}}return null;}
function backingBeginEdit(shape){if(!shape)return false;backingEdit=shape;outlineSelection=[];outlineRectArmed=false;outlineSketchPanelSync();drawBoardRect();outlineMsg("backing region sketch: select geometry or use Rectangle/Line, constraints and modify tools");return true;}
function backingRegionBad(pts){if(!pts||pts.length<3||polySelfIntersects(pts))return true;
 var area=0;for(var i=0;i<pts.length;i++){var a=pts[i],b=pts[(i+1)%pts.length];area+=a[0]*b[1]-b[0]*a[1];}
 return Math.abs(area)<1e-8;}
function backingBad(){return (PCB.fabrication_layers||[]).some(function(l){if(!(l.regions||[]).length||(l.regions||[]).some(backingRegionBad))return true;return (l.sketches||[]).some(function(sk){if(!sk)return false;var g=OS&&OS.compile(sk),st=OS&&OS.state(sk);return !g||!g.closed||(st&&st.conflict);});});}
function drawBacking(){(PCB.fabrication_layers||[]).forEach(function(l){(l.regions||[]).forEach(function(pts){
 if(!pts||pts.length<3)return;var col=backingRegionBad(pts)?"#f85149":(l.side==="bottom"?"#38bdf8":"#f472b6");
 var str=pts.map(function(p){return X(p[0]).toFixed(1)+","+Y(p[1]).toFixed(1);}).join(" ");
 gB.appendChild(el("polygon",{points:str,fill:col,stroke:col,"stroke-width":1.2,opacity:0.20,"pointer-events":"none"}));
 });});}
var heatsinkMode=false,heatsinkDraw=null,heatsinkDrag=null,heatsinkEditSnap=null;
function heatsinkRect(){if(heatsinkDraw)return {x:Math.min(heatsinkDraw.x0,heatsinkDraw.x1),y:Math.min(heatsinkDraw.y0,heatsinkDraw.y1),w:Math.abs(heatsinkDraw.x1-heatsinkDraw.x0),h:Math.abs(heatsinkDraw.y1-heatsinkDraw.y0),side:(PCB.heatsink&&PCB.heatsink.side)||"bottom"};return PCB.heatsink;}
function drawHeatsink(){var s=heatsinkRect();if(!viewSt.vis.heatsink&&!heatsinkMode&&!heatsinkDraw)return;if(!s||!(s.w>0)||!(s.h>0))return;
 var col=s.side==="top"?"#f59e0b":"#38bdf8",x=X(s.x),y=Y(s.y),w=s.w*S,h=s.h*S;
 gB.appendChild(el("rect",{x:x.toFixed(1),y:y.toFixed(1),width:w.toFixed(1),height:h.toFixed(1),fill:col,stroke:col,"stroke-width":1.7,opacity:0.24,"stroke-dasharray":heatsinkDraw?"6 4":"0",class:"heatsink-box"}));
 var axis=s.fin_axis||"length",pitch=(+s.fin_thickness_mm||1)+Math.max(+s.fin_gap_mm||0,0),across=axis==="length"?s.w:s.h,n=Math.min(512,Math.max(1,Math.floor((across+Math.max(+s.fin_gap_mm||0,0))/pitch)));
 for(var i=0;i<n;i++){var q=(i+.5)/n;if(axis==="length")gB.appendChild(el("line",{x1:(x+q*w).toFixed(1),y1:y.toFixed(1),x2:(x+q*w).toFixed(1),y2:(y+h).toFixed(1),stroke:col,"stroke-width":1,opacity:.7}));
  else gB.appendChild(el("line",{x1:x.toFixed(1),y1:(y+q*h).toFixed(1),x2:(x+w).toFixed(1),y2:(y+q*h).toFixed(1),stroke:col,"stroke-width":1,opacity:.7}));}
 var t=el("text",{x:(x+5).toFixed(1),y:(y+13).toFixed(1),fill:col,"font-size":"10","font-weight":"700"});t.textContent="HEATSINK · "+(s.side||"bottom").toUpperCase()+(s.target_ref?" · "+s.target_ref:"");gB.appendChild(t);
 if(heatsinkMode&&!heatsinkDraw&&!RO){[[x,y],[x+w,y],[x+w,y+h],[x,y+h]].forEach(function(p){gB.appendChild(el("rect",{x:(p[0]-4).toFixed(1),y:(p[1]-4).toFixed(1),width:8,height:8,fill:TH.bg,stroke:col,"stroke-width":1.5,class:"heatsink-handle"}));});}}
function drawBoardRect(tmp){
 while(gB.firstChild)gB.removeChild(gB.firstChild);
 drawBacking();
 drawHeatsink();
 // ▩ Pour polygon in progress — drawn over the outline (not instead of it), so
 // the board edge stays visible while placing a copper-pour boundary.
 if(pourPts&&pourPts.length)pourSketch();
 if((pourMode&&pourEdit)||(backingMode&&backingEdit))drawPourSketchEditor();
 var linePreview=polyPts&&polyPts.length,br=tmp||PCB.outline||PCB.board;
 if(!br||!(br.w>0)||!(br.h>0)){if(linePreview)polySketch();return;}
 if(!tmp&&!viewSt.vis[LN.edge_cuts]&&!linePreview)return; // outline hidden in the Appearance panel
 var drawn=!!(tmp||PCB.outline),editing=!tmp&&!RO&&outlineMode;
 // Committed outlines draw in KiCad's Edge.Cuts grey; the in-progress drag
 // rectangle keeps the green dashed tool feedback.
 var EC=tmp?"#7ee787":(PHYSICAL_REVIEW?PH.edge:TH.edge);
 // Exact polygon outline (drawn ⬡ Poly pts, or the authored corner-radius
 // shape the server sends as PCB.board_poly); rectangles keep the rect path.
 var authored=PCB.outline?null:authoredOutlineSeed();
 var nominal=tmp?null:(PCB.outline?(PCB.outline.pts||null):(authored?authored.pts:(editing?null:(PCB.board_poly||null))));
 var geom=PCB.outline?outlineFilletGeom(PCB.outline):(authored?outlineFilletGeom(authored):null);
 if(geom&&geom.nominal)nominal=geom.nominal;
 var pts=geom&&geom.points.length?geom.points:nominal;
 // A self-intersecting drawn polygon is invalid to save — draw it red so the
 // problem is obvious (Save also refuses it, see persistLayout/outlineBad).
 var open=!!(geom&&geom.sketch&&!geom.sketch.closed),bad=drawn&&pts&&pts.length>=3&&!open&&polySelfIntersects(pts);
 var SC=bad?"#f85149":(open?"#e3b341":EC);
 if(outlineMode&&geom&&geom.sketch){var ss=OS.state(PCB.outline.sketch);SC=ss.conflict?"#f85149":(open?"#e3b341":(ss.dof?"#58a6ff":"#d6d7db"));}
 if((geom&&geom.sketch)||(pts&&pts.length>=3)){
  var str=(pts||[]).map(function(p){return X(p[0]).toFixed(1)+","+Y(p[1]).toFixed(1);}).join(" ");
  if(geom&&geom.sketch){var d=outlineSketchPath(geom.sketch,PCB.outline.sketch);
   gB.appendChild(el("path",{d:d,fill:outlineMode&&geom.sketch.closed?"rgba(126,231,135,.055)":"none",stroke:SC,"stroke-width":1.4,opacity:0.95,"stroke-dasharray":open?"5 3":"0"}));}
  else if(geom&&geom.arcs.length){var cs=geom.corners,first=cs[0]?cs[0].p1:{x:nominal[0][0],y:nominal[0][1]};
   var d="M "+X(first.x).toFixed(3)+" "+Y(first.y).toFixed(3);
   for(var pi=0;pi<cs.length;pi++){var f=cs[pi],v=nominal[pi];
    if(!f){d+=" L "+X(v[0]).toFixed(3)+" "+Y(v[1]).toFixed(3);continue;}
    d+=" L "+X(f.p1.x).toFixed(3)+" "+Y(f.p1.y).toFixed(3);
    d+=" A "+(f.radius*S).toFixed(3)+" "+(f.radius*S).toFixed(3)+" 0 0 "+(f.sweep>0?1:0)+" "+X(f.p2.x).toFixed(3)+" "+Y(f.p2.y).toFixed(3);}
   d+=" Z";gB.appendChild(el("path",{d:d,fill:"none",stroke:SC,"stroke-width":1.4,opacity:0.9}));}
  else gB.appendChild(el("polygon",{points:str,fill:"none",stroke:SC,"stroke-width":1.4,opacity:0.9}));
  // A drawn polygon's vertices stay editable: square handles, dragged in the
  // pointer handlers (gB is pointer-events:none; hits are coordinate-tested).
  if((drawn||editing)&&!RO)(nominal||pts).forEach(function(p){gB.appendChild(el("rect",{
    x:(X(p[0])-3.5).toFixed(1),y:(Y(p[1])-3.5).toFixed(1),width:7,height:7,
    fill:TH.bg,stroke:SC,"stroke-width":1.2,opacity:0.9}));});
 if(geom&&geom.sketch){if(!activeSketchIsArea()&&(outlineMode||outlineOnlyFilter()))drawOutlineSketchSelection(geom.sketch,PCB.outline.sketch);if(outlineMode)drawOutlineSketchInfo(geom.sketch,SC,PCB.outline.sketch);}
 }else{
  gB.appendChild(el("rect",{x:X(br.x).toFixed(1),y:Y(br.y).toFixed(1),width:(br.w*S).toFixed(1),
    height:(br.h*S).toFixed(1),fill:"none",stroke:EC,"stroke-width":tmp?1.6:1.4,opacity:0.9,
    "stroke-dasharray":tmp?"6 4":"0"}));
  // A DRAWN rect outline also shows corner handles, so it's discoverably
  // vertex/edge-editable (the first edit promotes it to a real polygon).
  if((drawn||editing)&&!tmp&&!RO){var rc=outlinePtsOf(outlineEditable());
   if(rc)rc.forEach(function(p){gB.appendChild(el("rect",{
     x:(X(p[0])-3.5).toFixed(1),y:(Y(p[1])-3.5).toFixed(1),width:7,height:7,
     fill:TH.bg,stroke:EC,"stroke-width":1.2,opacity:0.9}));});}
 }
 if(linePreview)polySketch(); // connected Line preview stays over the outline it may snap to
 if(PHYSICAL_REVIEW)return; // fabrication dimensions are not printed on the board
 var bt=el("text",{x:(X(br.x)+6).toFixed(1),y:(Y(br.y)+14).toFixed(1),fill:EC,"font-size":"11",opacity:0.8});
 bt.textContent=fmtLen2(br.w)+"×"+fmtLen2(br.h)+(drawn?" (drawn)":(editing?" (edit)":"")); gB.appendChild(bt);
}
function outlineSketchPath(g,sk){sk=sk||(activeSketchShape()||{}).sketch;var cs=g.curves,d="",last=null;
 cs.forEach(function(c){var a=OS.point(sk,c.a),b=OS.point(sk,c.b);if(!a||!b)return;
  if(!last||last.id!==a.id)d+=" M "+X(a.x).toFixed(3)+" "+Y(a.y).toFixed(3);
  if(c.kind==="arc"){var ag=OS.arcCircle(sk,c);if(ag)d+=" A "+(ag.r*S).toFixed(3)+" "+(ag.r*S).toFixed(3)+" 0 "+(Math.abs(ag.sweep)>Math.PI?1:0)+" "+(ag.sweep>0?1:0)+" "+X(b.x).toFixed(3)+" "+Y(b.y).toFixed(3);
   else d+=" L "+X(b.x).toFixed(3)+" "+Y(b.y).toFixed(3);}
  else d+=" L "+X(b.x).toFixed(3)+" "+Y(b.y).toFixed(3);last=b;});return d+(g.closed?" Z":"");}
function outlineCurvePath(c,sk){sk=sk||(activeSketchShape()||{}).sketch;var a=sk&&OS.point(sk,c.a),b=sk&&OS.point(sk,c.b);if(!a||!b)return "";var d="M "+X(a.x).toFixed(3)+" "+Y(a.y).toFixed(3);
 if(c.kind!=="arc")return d+" L "+X(b.x).toFixed(3)+" "+Y(b.y).toFixed(3);var g=OS.arcCircle(sk,c);return g?d+" A "+(g.r*S).toFixed(3)+" "+(g.r*S).toFixed(3)+" 0 "+(Math.abs(g.sweep)>Math.PI?1:0)+" "+(g.sweep>0?1:0)+" "+X(b.x).toFixed(3)+" "+Y(b.y).toFixed(3):d+" L "+X(b.x).toFixed(3)+" "+Y(b.y).toFixed(3);}
function drawOutlineSketchSelection(g,sk){sk=sk||(activeSketchShape()||{}).sketch;outlineResolveSelection();outlineSelection.forEach(function(s){if(s.type==="curve"){var c=OS.curve(sk,s.id);if(c)gB.appendChild(el("path",{d:outlineCurvePath(c,sk),fill:"none",stroke:"#fff","stroke-width":3,opacity:.85}));}
 else{var p=OS.point(sk,s.id);if(p)gB.appendChild(el("circle",{cx:X(p.x).toFixed(1),cy:Y(p.y).toFixed(1),r:5.5,fill:"none",stroke:"#fff","stroke-width":1.6}));}});}
function drawOutlineSketchInfo(g,col,sk){sk=sk||(activeSketchShape()||{}).sketch;if(!OS||!sk)return;
 g.arcs.forEach(function(a){gB.appendChild(el("circle",{cx:X(a.pm[0]).toFixed(1),cy:Y(a.pm[1]).toFixed(1),r:3.2,
  fill:TH.bg,stroke:col,"stroke-width":1.1,transform:"rotate(45 "+X(a.pm[0]).toFixed(1)+" "+Y(a.pm[1]).toFixed(1)+")"}));});
 OS.annotations(sk).forEach(function(a){var t=el("text",{x:(X(a.x)+7).toFixed(1),y:(Y(a.y)-7).toFixed(1),fill:a.driving?"#8ab8f0":"#85868d","font-size":"10","font-family":"ui-monospace,monospace"});
  var unit=a.kind==="angle"?"°":" mm";t.textContent=(a.driving?"":"(")+((+a.value||0).toFixed(3))+unit+(a.driving?"":")");gB.appendChild(t);});
 var glyph={horizontal:"H",vertical:"V",parallel:"∥",perpendicular:"⟂",tangent:"T",equal:"=",fixed:"●",midpoint:"M",symmetric:"S"};
 (sk.constraints||[]).forEach(function(q){if(!glyph[q.kind]||q.enabled===false)return;var c=OS.curve(sk,q.a),p=OS.point(sk,q.a),x,y;if(c){var a=OS.point(sk,c.a),b=OS.point(sk,c.b);x=(a.x+b.x)/2;y=(a.y+b.y)/2;}else if(p){x=p.x;y=p.y;}else return;
  var t=el("text",{x:(X(x)+4).toFixed(1),y:(Y(y)+11).toFixed(1),fill:"#bc8cff","font-size":"9","font-weight":"700"});t.textContent=glyph[q.kind];gB.appendChild(t);});}
function drawPourSketchEditor(){var z=activeSketchShape(),sk=z&&z.sketch,g=sk&&OS.compile(sk),pts=g?g.points:(z&&z.poly)||[],nominal=g?OS.physicalPoints(sk).map(function(p){return [p.x,p.y];}):pts;
 if(!pts.length)return;var open=!!(g&&!g.closed),bad=!open&&polySelfIntersects(pts),st=sk&&OS.state(sk),base=backingMode?(z.layer.side==="bottom"?"#38bdf8":"#f472b6"):((z&&z.keepout)?"#9ca3af":POUR_COL),col=bad||(st&&st.conflict)?"#f85149":(open?"#e3b341":base),d;
 if(g)d=outlineSketchPath(g,sk);else d="M "+pts.map(function(p){return X(p[0]).toFixed(3)+" "+Y(p[1]).toFixed(3);}).join(" L ")+" Z";
 gB.appendChild(el("path",{d:d,fill:g&&g.closed?"rgba(240,198,116,.07)":"none",stroke:col,"stroke-width":1.7,opacity:.98,"stroke-dasharray":open?"5 3":"0"}));
 nominal.forEach(function(p){gB.appendChild(el("rect",{x:(X(p[0])-3.5).toFixed(1),y:(Y(p[1])-3.5).toFixed(1),width:7,height:7,fill:TH.bg,stroke:col,"stroke-width":1.3,opacity:.98}));});
 if(g){drawOutlineSketchSelection(g,sk);drawOutlineSketchInfo(g,col,sk);}}
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
 if(polyCur&&polyCur.axis){var lp2=polyPts[polyPts.length-1],guide=polyCur.axis==="horizontal"?{x1:X(lp2[0]),y1:Y(lp2[1]),x2:X(polyCur.x),y2:Y(lp2[1])}:{x1:X(lp2[0]),y1:Y(lp2[1]),x2:X(lp2[0]),y2:Y(polyCur.y)};
  gB.appendChild(el("line",{x1:guide.x1.toFixed(1),y1:guide.y1.toFixed(1),x2:guide.x2.toFixed(1),y2:guide.y2.toFixed(1),stroke:"#58a6ff","stroke-width":1,opacity:.8,"stroke-dasharray":"2 3"}));}
 if(polyCur&&polyCur.mag)gB.appendChild(el("circle",{cx:X(polyCur.x).toFixed(1),cy:Y(polyCur.y).toFixed(1),r:7,fill:"none",stroke:polyCur.close?"#f0b72f":"#58a6ff","stroke-width":1.6,opacity:.95}));
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
function wrect(i,pad){var p=P[i];
 if(pad.poly&&pad.poly.length>=3){var x0=1/0,y0=1/0,x1=-1/0,y1=-1/0;
  pad.poly.forEach(function(v){var q=wpt(i,v[0],v[1]);x0=Math.min(x0,q.x);y0=Math.min(y0,q.y);x1=Math.max(x1,q.x);y1=Math.max(y1,q.y);});
  return {x0:x0,y0:y0,x1:x1,y1:y1};}
 var c=wpt(i,pad.x,pad.y),q=((p.rot||0)+(pad.rot||0))*Math.PI/180;
 var ca=Math.abs(Math.cos(q)),sa=Math.abs(Math.sin(q));
 var hw=pad.w/2*ca+pad.h/2*sa,hh=pad.w/2*sa+pad.h/2*ca;
 return {x0:c.x-hw,y0:c.y-hh,x1:c.x+hw,y1:c.y+hh};}
// World-space axis-aligned bounding box of a part's courtyard box, accounting
// for its rotation + side mirror. Shared by the intersection-based marquee,
// align/distribute (edge references) and zoom-to-selection.
function partAABB(i){var p=P[i],c=wpt(i,p.ccx||0,p.ccy||0);
 var a=(p.rot||0)*Math.PI/180,ca=Math.abs(Math.cos(a)),sa=Math.abs(Math.sin(a));
 var hw=p.hw*ca+p.hh*sa, hh=p.hw*sa+p.hh*ca;
 return {x0:c.x-hw,y0:c.y-hh,x1:c.x+hw,y1:c.y+hh};}
// ── Viewport culling (parts + pad labels) ───────────────────────────────
// The part passes walk the WHOLE board every frame; zoomed in past the pin-
// number threshold most of it is off screen, yet each part still pays a
// save/translate/rotate and each pad a path build. cullRect is the visible
// window in WORLD mm (the space P[i].x/y live in) and is deliberately
// CALLER-SET — scenePaint fills it from vb, and a future overscan renderer
// must be able to widen it without the paint passes knowing.
// HIT-TESTING IS NOT CULLED: partAt/padAt still test every part.
var cullRect={x0:-1e9,y0:-1e9,x1:1e9,y1:1e9},cullBox=null,cullOff=true;
// Whole-board bound, built once from the EXACT partAABB (so the trig is paid
// once). A window containing it can cull NOTHING, so the zoomed-out case pays
// one comparison instead of a per-part scan. cullOff=true means "draw
// everything", so every way this box can be wrong — staleness after a drag or
// courtyard edit, or disagreeing with partCulled's looser radius — costs a few
// extra parts drawn, never a wrong frame.
function cullBoardBox(){if(cullBox)return cullBox;
 var x0=1e18,y0=1e18,x1=-1e18,y1=-1e18;
 for(var i=0;i<P.length;i++){var b=partAABB(i);
  if(b.x0<x0)x0=b.x0;if(b.x1>x1)x1=b.x1;if(b.y0<y0)y0=b.y0;if(b.y1>y1)y1=b.y1;}
 cullBox={x0:x0,y0:y0,x1:x1,y1:y1};return cullBox;}
function cullSet(x0,y0,x1,y1){cullRect.x0=x0;cullRect.y0=y0;cullRect.x1=x1;cullRect.y1=y1;
 var b=cullBoardBox();cullOff=(b.x0>=x0&&b.x1<=x1&&b.y0>=y0&&b.y1<=y1);}
// Margin = what a part draws OUTSIDE its courtyard box. Two terms: 24 CSS px
// (the ref-des label sits up to 11 px tall above the box and is centred, so it
// reaches ~24 px around it) converted to mm at the current zoom, plus a flat
// 3 mm for silk/pads that stick out of a tight courtyard. Conservative by
// construction — a part whose centre is off screen but whose body or label
// poked into view still draws.
function cullFromVB(k){if(!(k>0)){var sw=svgMetricsGet().cw;k=(sw>0)?sw/vb.w:1;}
 var m=3+24/Math.max(k*S,1e-6);
 cullSet(vb.x/S+MX-M-m,vb.y/S+MY-M-m,(vb.x+vb.w)/S+MX-M+m,(vb.y+vb.h)/S+MY-M+m);}
// Runs per part per frame, so it is trig-free and allocation-free: rotating the
// courtyard moves its centre by at most |ccx|+|ccy| and stretches its half-
// extents to at most hw+hh, so this box always CONTAINS partAABB(i) at any
// angle or side. Conservative on purpose — a part whose body or ref-des label
// pokes into view must still draw.
function partCulled(i){if(cullOff)return false;var p=P[i];
 var r=Math.abs(p.ccx||0)+Math.abs(p.ccy||0)+p.hw+p.hh;
 return p.x+r<cullRect.x0||p.x-r>cullRect.x1||p.y+r<cullRect.y0||p.y-r>cullRect.y1;}
// setT once wrote SVG transforms; parts are canvas-painted now, so every
// legacy call site simply schedules a repaint (the scene reads P[] fresh) and
// invalidates the overscan pan buffer — its callers (lock, rotate, side flip)
// all restyle a part the buffer already baked.
function setT(i){ovsRev++;keepoutGeomDrop();if(gpuOn)PCBGpu.rebuildParts();paintSoon();}
// Defined decoupling pads: each loop pins a cap to ONE hub pad (L.pp =
// hub_pwr_pin). Mark those hub pads so a net selection glows them red (the
// authored decoupling target) rather than gold. Keyed hubIndex:padX:padY.
var loopPin={};(PCB.loops||[]).forEach(function(L){if(L.pp)loopPin[L.hub+":"+L.pp.x.toFixed(2)+":"+L.pp.y.toFixed(2)]=1;});
// ── Scene paint state + hit-testing ─────────────────────────────────────
// What the old per-element class toggles carried is now plain state the
// painter reads: hover part / rigid-group glow / selection / net glow /
// heat / staging — one repaint applies all of it.
var cur=-1,hoverGrpName=null,hoverNet=null,flashIdx=-1,flashUntil=0,flashPt=null,flashPtUntil=0;
// Persistent read-only review focus. The assembly/debug shell drives this
// through window.PCBReviewFocus (or the same-origin message bridge below).
// null is deliberately the zero-cost/default state: every legacy paint path
// remains byte-for-byte equivalent when review focus is clear.
var reviewFocus=null,reviewPickedRefCur=null,reviewPickedRefSide=null;
var reviewSide="top",reviewRotation=0,reviewOriented=false;
function refLabel(ref){ref=String(ref||"");var slash=ref.lastIndexOf("/");return slash<0?ref:ref.slice(slash+1);}
function reviewPartSide(p){return p&&p.side==="bottom"?"bottom":"top";}
// Two-pad RF alignment mode. The first hit owns the moving component or whole
// sub-circuit; the second hit is a fixed reference. Kept in scene state so the
// canvas painter can mark both exact pads and preview the X/Y projections.
var padAlignMode=false,padAlignA=null,padAlignB=null;
// Assembly picks belong to the face the operator is actually looking at. The
// opposite face is still painted by the normal layer rules, but it must never
// win an overlapping courtyard or through-hole pad hit.
function reviewPartOnShownSide(p){return !PHYSICAL_REVIEW||reviewPartSide(p)===reviewSide;}
// Part hit-test: courtyard box in part-local coords (un-rotate, un-mirror).
// Smallest hit wins so a cap sitting on a hub grabs before the hub.
function partAt(wx,wy){var best=-1,ba=1e18;
 for(var i=0;i<P.length;i++){var p=P[i];
  if(!partOnVisibleFace(p)||!reviewPartOnShownSide(p))continue;
  var a=-(p.rot||0)*Math.PI/180,c=Math.cos(a),sn=Math.sin(a);
  var lx=wx-p.x,ly=wy-p.y,rx=lx*c-ly*sn,ry=lx*sn+ly*c;
  if(p.side==="bottom")rx=-rx;
  if(Math.abs(rx-(p.ccx||0))<=p.hw&&Math.abs(ry-(p.ccy||0))<=p.hh){var ar=p.hw*p.hh;if(ar<ba){ba=ar;best=i;}}}
 return best;}
function padAt(i,wx,wy){var p=P[i],a=-(p.rot||0)*Math.PI/180,c=Math.cos(a),sn=Math.sin(a);
 var lx=wx-p.x,ly=wy-p.y,rx=lx*c-ly*sn,ry=lx*sn+ly*c;
 if(p.side==="bottom")rx=-rx;
 var best=null;(p.pads||[]).forEach(function(pd){
  if(pd.poly&&pd.poly.length>=3){var hit=false;
   for(var j=0,k=pd.poly.length-1;j<pd.poly.length;k=j++){
    var u=pd.poly[j],v=pd.poly[k];if(((u[1]>ry)!==(v[1]>ry))&&(rx<(v[0]-u[0])*(ry-u[1])/(v[1]-u[1])+u[0]))hit=!hit;}
   if(hit)best=pd;return;}
  var pa=-(pd.rot||0)*Math.PI/180,pc=Math.cos(pa),ps=Math.sin(pa),dx=rx-pd.x,dy=ry-pd.y;
  var px=dx*pc-dy*ps,py=dx*ps+dy*pc;
 if(Math.abs(px)<=pd.w/2&&Math.abs(py)<=pd.h/2)best=pd;});
 return best;}
// Exact pad hit across the whole board, independent of courtyard overlap.
// Smallest visible pad wins when pads overlap. Assembly review additionally
// limits every pad, including through-holes, to its owning placement's face.
function padHitAt(wx,wy){if(!viewSt.filt.pad&&!PHYSICAL_REVIEW)return null;var best=null,ba=1e18;
 for(var i=0;i<P.length;i++){var p=P[i];
  if(!partOnVisibleFace(p)||!reviewPartOnShownSide(p))continue;
  var pd=padAt(i,wx,wy);if(!pd)continue;
  if(!(pd.drill>0)&&layerAlpha(p.side==="bottom"?1:0)<=0)continue;
  var b=wrect(i,pd),ar=Math.max((b.x1-b.x0)*(b.y1-b.y0),1e-12);
  if(ar<ba){ba=ar;best={i:i,pd:pd};}}
 return best;}
// rAF-coalesced full scene repaint — the ONE redraw path for everything.
var paintQueued=false;
function paintSoon(){if(paintQueued)return;paintQueued=true;
 (window.requestAnimationFrame||setTimeout)(scenePaint);}
// ── Replay overlay seam (design-route-review panel, pcb_replay.js) ───────
// A NON-persistent copper overlay drawn on top of the live scene each frame.
// It paints straight to the canvas under the same world transform paintTracks
// uses and must NEVER touch PCB.tracks/PCB.vias/PCB.drc (those autosave); the
// only path into board state is the explicit PCBAdoptCopper action below.
window.PCBOverlay={paint:null,exclusive:false,ghost:false};
// Exclusive replay view (pcb_replay.js sets the flags): while a replay frame
// owns the copper, the board's own tracks/vias/clearance/ratsnest are skipped
// in scenePaint and its DRC-marker SVG group (gD) is hidden, so ONLY the replay
// reads. `ghost` optionally paints the saved copper beneath as a faint flat
// grey reference for net-by-net comparison. These are dumb rendering switches —
// all the mode policy (when to flip them, tool gating, the chip) lives in
// pcb_replay.js.
window.PCBRepaint=function(){gDSync();dragCacheDrop();paintSoon();};
function ovExclusive(){return !!(PCBOverlay.paint&&PCBOverlay.exclusive);}
function ovGhost(){return ovExclusive()&&!!PCBOverlay.ghost;}
function paintGhost(ctx){ // saved copper as a faint flat-grey underlay (vias = thin rings)
 ctx.save();ctx.lineCap="round";ctx.globalAlpha=0.22;ctx.strokeStyle="#8a8a8a";
 (PCB.tracks||[]).forEach(function(t){ctx.lineWidth=Math.max(t.w*S,1.2);
  ctx.beginPath();trackPath(ctx,t);ctx.stroke();});
 ctx.lineCap="butt";ctx.lineWidth=1;
 (PCB.vias||[]).forEach(function(v){var rr=viaRenderRadius(v.d);
  ctx.beginPath();ctx.arc(X(v.x),Y(v.y),rr,0,6.2832);ctx.stroke();});
 ctx.globalAlpha=1;ctx.restore();}
// ── Drag-time static-scene cache ────────────────────────────────────────
// While a part/group drag is in flight the untouched rest of the board is
// repainted identically every frame — on a big board that's thousands of
// pads for a one-part move. So the first dragged frame renders the static
// remainder ONCE into an offscreen bitmap; each following frame blits it
// and repaints only the moving parts, their airwires, their group boxes
// and any copper the drag carries. Keyed on viewport+size+moving-set;
// dropped on pan/zoom (setVB), copper changes (drawRoute), heat re-tints
// (applyHeat) and gesture end — anything that can restyle a static part.
var dragCache=null,gpuDragCache=null,keepoutGeomRev=0;
// Keepout halos are geometry-derived, so unlike visual-only selection state
// their retained paths/bitmap must be dropped whenever copper or a pad pose
// changes. All mutation funnels converge here; rebuilding stays lazy.
function keepoutGeomDrop(){keepoutGeomRev++;keepoutBatch=null;keepoutMaskKey="";keepoutOverlayCache=null;}
// Also the ONE funnel the overscan pan buffer keys its staleness on: every
// call site here is exactly "a static part restyled", which is what both
// caches mean by stale. vbBusy() is the deliberate exception — see ovsRev.
// The GPU pad/bore buffers are WORLD-baked, so every pose commit invalidates
// them — and this is exactly the funnel those commits already share (drag end,
// group drag end, applyAll via setT, heat/zone/focus restyles). The rebuild is
// lazy, so hooking the broad seam rather than hunting every commit site costs
// at most one 607-pad rebake on the next frame.
function dragCacheDrop(){dragCache=null;gpuDragCache=null;dragSilk=null;ovsRev++;keepoutGeomDrop();if(gpuOn)PCBGpu.rebuildParts();}
function dragIdxSet(){ // moving part index set, or null when no drag is live
 if(typeof drag!=="undefined"&&drag&&drag.moved){var s={};s[drag.i]=1;return s;}
 if(typeof gdrag!=="undefined"&&gdrag&&gdrag.moved){var s2={};
  gdrag.orig.forEach(function(o){s2[o.i]=1;});return s2;}
 return null;}
// Viewport-busy window: pad-number labels (the most expensive paint pass —
// a font set + fillText per pad) are skipped while a drag is live or the
// viewport moved in the last 150 ms (wheel/trackpad pan+zoom, pinch); the
// trailing repaint brings them back once the gesture goes quiet.
var vbQuiet=0,vbTimer=0;
// ── Retained-SVG adornments during a viewport gesture ───────────────────
// gD (a DRC marker is 3 nodes with non-scaling-stroke) and gR (the loop
// overlays) are retained DOM the browser re-renders on EVERY viewBox write, so
// a pan/zoom burst pays them once per pointer event for content the canvas blit
// is not even redrawing. Hidden for the length of the gesture, restored by the
// full-quality repaint — the same deal pad labels already take.
// gD has two owners: this flag and the replay overlay's exclusive mode. gDSync
// is the ONE writer of its display, so they can never disagree.
var svgAdornHidden=false;
function gDSync(){gD.style.display=(svgAdornHidden||(window.PCBOverlay&&PCBOverlay.exclusive))?"none":"";}
function svgAdornHide(){if(svgAdornHidden)return; // once per gesture, never per event
 svgAdornHidden=true;gDSync();gR.style.display="none";}
function svgAdornShow(){if(!svgAdornHidden)return;
 svgAdornHidden=false;gDSync();gR.style.display="";}
function vbBusy(){vbQuiet=Date.now()+150;
 // dragCache is dropped DIRECTLY (not through dragCacheDrop) on purpose: this
 // fires on every viewport event, and bumping ovsRev here would invalidate the
 // overscan pan buffer on the very frames it exists to serve. The two caches
 // have deliberately different lifetimes — the drag cache is VIEWPORT-keyed, so
 // a pan kills it; the overscan buffer is WORLD-anchored, so a pan is exactly
 // what it survives.
 dragCache=null;svgAdornHide();
 clearTimeout(vbTimer);vbTimer=setTimeout(paintSoon,170);}
// ovsBuilding: the overscan bake runs DURING a gesture but must render at full
// quality, so it reports "not busy" to every gesture-gated pass (ref-des labels
// in paintParts, the whole of paintPadLabels). It is set and cleared inside
// ovsBuild's straight-line body, so it can never be observed by the deferred
// readers (draftGestureLive runs from a setTimeout, which cannot fire mid-build).
function gestureBusy(){if(ovsBuilding)return false;
 return dragIdxSet()!==null||!!heatsinkDraw||Date.now()<vbQuiet;}
// ── Overscan pan buffer ─────────────────────────────────────────────────
// Panning is smooth zoomed out and laggy zoomed in for one reason: the RASTER
// cost of the same scene climbs with zoom (fat strokes, pour washes, big pads)
// while the JS side barely moves. So a pan frame stops rasterizing the scene at
// all — the full-quality scene renders ONCE into an offscreen canvas LARGER
// than the viewport (world-anchored, at the SAME device scale), and every pan
// frame inside the margin copies its window out of it.
//
// The copy is 1:1 and integer-aligned — drawImage(buf, sx,sy,w,h, 0,0,w,h) with
// sx/sy rounded to whole device px — so pixels are MOVED, never resampled. This
// is not the scaled gesture blit that was tried and reverted: nothing is ever
// drawn at a scale other than the one it was rendered at. The only visible
// difference from a real repaint is up to half a device pixel of position
// quantization for the length of the gesture, which the existing 170 ms quiet
// repaint (vbTimer → paintSoon) corrects by drawing the exact frame.
//
// Pin numbers and ref-des labels are BAKED IN, so unlike today they stay
// visible through a pan instead of blinking out for the gesture and popping
// back on the quiet repaint.
//
// Zoom deliberately does NOT use it: a zoom frame changes kk, and rebuilding a
// 2.56x-area buffer per frame would cost far more than the full repaint that
// fixes B/D/E already made cheap. A build is allowed only when the PREVIOUS
// frame ran at the same kk — i.e. lazily on the next pan once the zoom settled.
var OVS_F=1.6,           // linear overscan factor (area 2.56x the viewport)
    OVS_F_MIN=1.2,       // below this the margin is too thin to pay for a buffer
    OVS_MAX_PX=24e6;     // device-pixel ceiling on the offscreen bitmap
var ovsCv=null,          // the offscreen bitmap (allocated once, resized in place)
    ovs=null,            // {x,y,kk,w,h,dw,dh,fp}: world origin, device scale/size, fingerprint
    ovsBuilding=false,   // true only inside ovsBuild — see gestureBusy above
    ovsKkPrev=0,         // kk of the previous frame; a zoom frame never builds
    ovsRev=0;            // monotonic content revision, folded into the fingerprint
function ovsCount(o){var n=0;for(var kc in o)n++;return n;}
// Everything the baked passes read that can change WITHOUT a copper edit,
// squeezed into one string; a mismatch rebuilds the buffer. Rebuilt once per
// blit-eligible frame (a few µs of string work against a whole scene raster).
// `cur` is deliberately ABSENT: the hovered part is neutralized in the bake and
// redrawn live over the blit, so moving the mouse never invalidates the buffer.
function ovsFp(){
 var s="",kx;
 for(kx in viewSt.vis)s+=viewSt.vis[kx]?"1":"0";
 s+=":";for(kx in viewSt.filt)s+=viewSt.filt[kx]?"1":"0";
 // paintClr's own gate rides the viewSt.vis loop above (viewSt.vis.clr) — the
 // DOM read this used to do never reached the fingerprint at all.
 return ovsRev+"|"+s+"|"+viewSt.grid+"|"+viewSt.units+"|"+viewSt.active+"|"+viewSt.pourOp+
  "|"+activeLayer+"|"+(netColOn?1:0)+"|"+(heatOn?1:0)+"|"+heatScale+"|"+(ratsOn?1:0)+
  "|"+(selRef||"")+"|"+(selGroup||"")+"|"+((sel&&sel.length)||0)+":"+((sel&&sel.join&&sel.join(","))||"")+
  "|"+(selNetCur||"")+"|"+(hoverNet||"")+"|"+(hoverGrpName||"")+
  "|"+(drawMode?1:0)+"|"+((drawMode&&dtrace&&dtrace.net)||"")+
  "|"+(ovExclusive()?1:0)+(ovGhost()?1:0)+
  "|"+selCu.t.length+","+selCu.v.length+
  "|"+ovsCount(unplacedSet)+"|"+(PCB.texts?PCB.texts.length:0)+"|"+(txSel===undefined?-1:txSel)+
  "|"+(padAlignMode?1:0)+(padAlignA?padAlignA.i:"")+"."+(padAlignB?padAlignB.i:"")+
  "|"+(clrOn()?1:0);}
// Buffer-INDEPENDENT gates. Conservative on purpose: falling through to the
// full render is always CORRECT, only slower.
function ovsOn(w,h,kk){
 if(gpuOn)return false;                 // GPU pan is a uniform write; a pixel buffer of a scene the GPU owns would only be stale
 if(PHYSICAL_REVIEW)return false;       // fab-preview embed: async sprites + postMessage focus, and not the surface this fixes
 if(!(Date.now()<vbQuiet))return false; // only inside the viewport-busy window — a quiet frame must render exactly
 if(!(w>0&&h>0&&kk>0))return false;
 if(window.PCBOverlay&&PCBOverlay.paint)return false; // the replay overlay repaints over the scene every frame
 if(drawMode&&dtrace)return false;      // a live hand-routed trace follows the cursor
 if(segdrag||viadrag)return false;      // copper moves per pointermove with no invalidation hook
 return true;}
// Is the viewport wholly inside the buffer, at the exact integer crop the blit
// will use? Tested on the ROUNDED offsets so the drawImage source rect can
// never leave the bitmap.
function ovsInside(w,h,kk){
 var sx=Math.round((vb.x-ovs.x)*kk),sy=Math.round((vb.y-ovs.y)*kk);
 return sx>=0&&sy>=0&&sx+w<=ovs.w&&sy+h<=ovs.h;}
// Render the baked layer stack into the offscreen bitmap, centred on the
// current view. One heavier frame (~2.5x a normal one), then every pan frame
// inside the margin is a single drawImage.
function ovsBuild(w,h,k,kk){
 var f=Math.min(OVS_F,Math.sqrt(OVS_MAX_PX/Math.max(w*h,1)));
 if(!(f>=OVS_F_MIN))return false;       // a huge canvas would leave too thin a margin for the bitmap it costs
 var bw=Math.round(w*f),bh=Math.round(h*f);
 if(!(bw>=w&&bh>=h))return false;
 if(!ovsCv)ovsCv=document.createElement("canvas");
 if(ovsCv.width!==bw)ovsCv.width=bw;
 if(ovsCv.height!==bh)ovsCv.height=bh;
 var c2=ovsCv.getContext("2d",{alpha:false});
 if(!c2)return false;
 var ox=vb.x-((bw-w)/2)/kk,oy=vb.y-((bh-h)/2)/kk; // world origin: viewport centred in the margin
 // The passes window on the module `vb` (paintGridDots' dot range, glyphDraw's
 // device-pixel snap, cullFromVB). Swap in the synthetic OVERSCAN viewport for
 // the bake, then put it back. `k` is passed through UNCHANGED — the zoom is
 // identical, only the covered area is larger.
 // Save → paint → restore is straight-line: nothing between them returns, and
 // the calls are the same ones the quiet frame makes, so `vb`, `cur`,
 // `ovsBuilding` and the cull rect are restored unconditionally.
 var sx=vb.x,sy=vb.y,sw=vb.w,sh=vb.h,scur=cur;
 vb.x=ox;vb.y=oy;vb.w=bw/kk;vb.h=bh/kk;
 cur=-1;            // hover must NOT bake — it changes far too often to key a buffer on
 ovsBuilding=true;  // labels + grid dots are gesture-gated; the bake is full quality
 cullFromVB(k);     // vb is already the overscan rect, so this IS the cullSet for it — one margin formula, no second copy to drift
 c2.setTransform(1,0,0,1,0,0);
 // The offscreen context outlives the build, so its alpha is whatever the last
 // bake's final pass left; both the base fill and the blit multiply by it.
 c2.globalAlpha=1;
 c2.fillStyle=PHYSICAL_REVIEW?PH.bg:TH.bg;c2.fillRect(0,0,bw,bh);
 c2.setTransform(kk,0,0,kk,-ox*kk,-oy*kk);
 paintScene(c2,k); // the whole stage order, board silk included
 ovsBuilding=false;
 cur=scur;
 vb.x=sx;vb.y=sy;vb.w=sw;vb.h=sh;
 cullFromVB(k);     // back to the frame's own visible window
 // Fingerprinted AFTER the bake, so anything a pass settled on its way through
 // (paintLinks' lazy connectivity recompute) is already folded in.
 ovs={x:ox,y:oy,kk:kk,w:bw,h:bh,dw:w,dh:h,fp:ovsFp()};
 return true;}
// One pan frame. Returns false having painted NOTHING whenever anything
// disagrees, so the caller's full render runs exactly as before.
function ovsFrame(ctx,w,h,k,kk,zoomHeld){
 if(!ovsOn(w,h,kk))return false;
 // Scale/geometry first, fingerprint second: a ZOOM frame fails `fit` and can
 // never blit, so it must not pay for a string it will throw away.
 var fit=!!ovs&&ovs.kk===kk&&ovs.dw===w&&ovs.dh===h&&ovsInside(w,h,kk);
 if(!fit&&!zoomHeld)return false;       // mid-zoom: render fully, build on the next settled frame
 if(!fit||ovs.fp!==ovsFp()){
  if(!zoomHeld)return false;
  if(!ovsBuild(w,h,k,kk))return false;}
 var sx=Math.round((vb.x-ovs.x)*kk),sy=Math.round((vb.y-ovs.y)*kk);
 if(sx<0||sy<0||sx+w>ovs.w||sy+h>ovs.h)return false;
 // 1:1 integer-offset source crop: source and destination rects are the SAME
 // size, so the copy moves pixels rather than resampling them. No background
 // fill — being wholly inside the buffer is an eligibility condition, so the
 // crop covers the canvas edge to edge.
 ctx.setTransform(1,0,0,1,0,0);
 ctx.globalAlpha=1;   // drawImage multiplies by it, and the passes leave it set
 ctx.drawImage(ovsCv,sx,sy,w,h,0,0,w,h);
 ctx.setTransform(kk,0,0,kk,-vb.x*kk,-vb.y*kk);
 // Live layers over the baked base. The hovered part rides paintParts' existing
 // moving-set split: its opaque pads/silk/sprite overdraw the identical baked
 // artwork (visually idempotent) and its white hover outline covers the dim
 // baked courtyard stroke — the only compounding is that translucent 0.35
 // magenta under an opaque white line, which is invisible.
 if(cur>=0){var hl={};hl[cur]=1;paintParts(ctx,k,hl,true);}
 paintInsp(ctx);
 paintPickPreview(ctx);
 paintDraw(ctx);
 paintPadAlign(ctx,k);
 return true;}
// ── WebGPU renderer gate (?gpu=1) ───────────────────────────────────────
// May the GPU own copper + pads for the frame about to render? Conservative by
// construction: EVERY no falls through to today's complete 2D scene, which is
// always correct and only slower. The list is spelled out rather than borrowed
// from cuBatchOn(null): that predicate also refuses the copper GESTURES, which
// the 2D batch genuinely cannot survive (it caches Path2D geometry) but the GPU
// can — its instance buffers are marked dirty by gpuCuEdit() at every gesture's
// mutation site and rebaked once on the next frame (M3).
//  · the fab-preview surface (?review=1) is a different palette and a per-object
//    mask/face rule; review focus is per-object dimming. Neither is expressible
//    as the per-draw alphas the renderer is handed.
//  · the exclusive replay overlay owns the copper for the frame.
//  · the pour-opacity ramp is GPU-side from M2 (stencil even-odd fills), but
//    its foreign-side PART fade is a per-part rule paintParts applies in 2D,
//    and an UNPLACED part is exempt from it — a distinction the pad/bore
//    grouping (by part side) cannot express. That pairing is rare enough to
//    refuse outright instead of approximating.
// A marquee copper selection (selCu) is NO LONGER a refusal: from M3 its fringe
// draws on the 2D canvas ABOVE the GPU copper instead of under it — see
// paintTracks.
function gpuLive(){
 return gpuOn&&window.PCBGpu&&PCBGpu.active
  &&!PHYSICAL_REVIEW&&!reviewFocusActive()&&!ovExclusive()
  // RF paths are swept variable-width polygons. Until the GPU owns polygon
  // copper too, use the exact 2D fill instead of rebaking their sample chords.
  &&!(PCB.rf_paths||[]).length
  &&!(viewSt.pourOp>0&&anyUnplaced());}
// A live gesture mutates PCB.tracks / PCB.vias IN PLACE, per pointermove, with
// no 2D cache to drop (the per-item painters read the model every frame). The
// GPU's copper instances are BAKED, so every such mutation has to mark them.
// Lazy, so a burst of pointermoves costs ONE rebake on the next rendered frame
// (~55 µs of Float32Array staging for a 522-track board — measured by
// scripts/pcb_gpu_check), and a call on the 2D build is a single dead branch.
function gpuCuEdit(){keepoutGeomDrop();if(gpuOn)PCBGpu.rebuildCopper();}
// The per-object colour rules the GPU bakes with, lifted verbatim from the 2D
// painters — paintTracks/cuBatchGet for copper, paintParts' pad fill for pads —
// so the opt-in Net-colours view cannot drift between the two renderers. Note
// the asymmetry, which is the 2D code's and is deliberately preserved: copper
// looks its net up through netCollapse (a bypass stub reads as its rail), a pad
// looks up its RAW net, and a pad on no net at all is the white no-connect.
function gpuTrackColor(t,L){return (netColOn&&netColorOf(netCollapse(t.net)))||layerColor(L);}
function gpuViaColor(v){return (netColOn&&netColorOf(netCollapse(v.net)))||TH.via;}
function gpuPadColor(pd,bot){
 if(netColOn)return pd.net?(netColorOf(pd.net)||TH.pth):"#ffffff";
 if(pd.drill>0)return pd.npth?TH.npth:TH.pth;
 return bot?TH.padBot:TH.padTop;}
// ── Pour fills on the GPU (stencil even-odd) ────────────────────────────
// The areas whose FILL the GPU owns on a gpuLive() frame: a real pour (declared
// or the carved fill of a user zone), never a keepout (its hatched grey wash
// and dashed rim stay 2D) and never a raw zone boundary (a dash, no fill at
// all). The list is state-INDEPENDENT — visibility and the opacity ramp are
// per-frame alphas, not membership — so the geometry bake and gpuPourAlphas()
// stay index-parallel by construction.
function gpuPourList(){var out=[];
 reviewCopperAreas().forEach(function(aq){
  if(!aq.poly||aq.poly.length<3||aq.q.keepout||aq.kind==="zone")return;out.push(aq);});
 return out;}
// Geometry + fill colour for the bake (board mm; pcb_gpu.js maps them through
// the same X()/Y()). The colour is exactly paintPours' — the theme's own
// TH.padTop for a top pour, TH.padBot for a bottom one AND for
// an area whose layer doesn't resolve, the layer's own hue for an inner pour.
function gpuPourGeom(){return gpuPourList().map(function(aq){
 var L=reviewAreaLayer(aq.q),st=reviewAreaStack(aq.q);
 return {poly:aq.poly,holes:aq.holes||[],
  col:st&&st.c?st.c:((L!=null&&L>=2)?layerColor(L):(L===0?TH.padTop:TH.padBot))};});}
// Each area's effective fill alpha this frame, in the same order — paintPours'
// editor-branch ladder verbatim, minus the review-focus terms: gpuLive() defers
// to cuBatchOn(), which refuses every frame with a focus active, so `hit` is
// always false here and the focus dim can never apply.
function gpuPourAlphas(){return gpuPourList().map(function(aq){
 var q=aq.q,L=reviewAreaLayer(q),st=reviewAreaStack(q),top=L===0,a=(st&&st.l==null?planeAlpha(st):(L==null?0.55:layerAlpha(L)));
 if(a<=0)return 0;
 var activeUserFill=reviewAreaFocused(q)&&typeof q.zone==="number";
 var baseA=activeUserFill?0.36:(top?0.10:0.12),baseEff=a*baseA;
 return (L==null||reviewAreaFocused(q))?Math.min(1,baseEff+(1-baseEff)*(viewSt.pourOp||0)):baseEff;});}
// The stage names the WebGPU canvas draws for itself, in canonical paint order
// — PAINT_STAGES filtered to the entries that claim GPU ownership. Resolved on
// first use (the table is declared below this point) and then reused: the order
// is a property of the table, never a per-frame decision.
var GPU_STAGES=null;
function gpuStageOrder(){
 if(!GPU_STAGES)GPU_STAGES=PAINT_STAGES.filter(function(s){return !!s.gpu;}).map(function(s){return s.n;});
 return GPU_STAGES;}
// The per-frame policy blob. Every ladder stays HERE — the renderer is handed
// resolved numbers, so active-layer emphasis, per-layer visibility, the
// solid-pour fades track their live state without
// pcb_gpu.js knowing any rule. SMD pads carry their owning part's side;
// through-hole annuli and every drilled bore stay opaque on every copper view,
// because neither a layer change nor an opaque pour can close a physical hole.
function gpuState(){
 // The frame's css-px-per-svg-unit scale, for the grid gates. Read from the
 // CACHED metrics scenePaint has already taken this frame — never a second
 // layout flush.
 var k=svgMetricsGet().cw/vb.w;
 var ls=[];
 trackLayerOrder().forEach(function(L){ls.push({l:L,a:layerAlpha(L)*pourLayerFade(L)});});
 var ft=pourForeignFade(false),fb=pourForeignFade(true),g=viewSt.grid;
 return {layers:ls,
  // The paint ORDER, handed over rather than implied: pcb_gpu.js dispatches its
  // passes by stage name in this sequence, so the GPU under-layer and this
  // canvas above it are two halves of ONE order instead of two hard-coded ones.
  // Only the stages it owns are worth sending; the rest it has no pass for.
  stages:gpuStageOrder(),
  padThruTop:1,padThruBot:1,
  padTop:layerAlpha(0)*ft,padBot:layerAlpha(1)*fb,
  boreTop:1,boreBot:1,
  via:anyCopperVisible()?1:0,
  pourA:gpuPourAlphas(),
  // paintGridDots' own gates: a pitch, and dots at least ~8 css px apart. The
  // quiet-window skip is NOT mirrored — that one dodges a 2D raster cost the
  // procedural pass doesn't have, so the GPU keeps its grid through a gesture.
  gridPitch:(g>0&&g*S*k>=8)?g*S:0,gridDot:1.4/Math.max(k,0.01),
  viaDrill:viaGeo().drill};}
// Antipads overlay (Layers/Appearance "Antipads"): every single-ended
// controlled-impedance via the server solved a plane antipad for draws its
// SOLVED opening (solid amber) and the minimum-clearance ring it is floored
// at (dashed grey), to scale — and prints both diameters, because on a thin
// buildup the two differ by tens of microns, which no zoom level can show.
// \u2500\u2500 Starved antipads \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
// The solved opening only buys the impedance it was solved for when the plane
// copper actually closes to that ring. Foreign pads, a higher-ranked pour, or a
// plane that never reached the transition all push the copper back, so the
// ACHIEVED opening comes out wider and the via is more inductive than designed.
// Nothing extra is fetched: the achieved opening is measured off the very fill
// polygons this viewer already draws.
var AP_REACH=3.0;  // copper further away than this never reached the transition
// Distance (world mm) from a point to the nearest copper of ONE fill entry: the
// hole's edge when the point sits inside an antipad hole, 0 when it stands on
// the fill itself, the contour's edge when it is outside the fill altogether.
function apDistToFill(f,x,y){var poly=f&&f.poly;if(!poly||poly.length<3)return 1e9;
 if(!polyContains(poly,x,y))return polyDistEdge(poly,x,y);
 var hs=f.holes||[];
 for(var i=0;i<hs.length;i++)if(hs[i]&&hs[i].length>=3&&polyContains(hs[i],x,y))return polyDistEdge(hs[i],x,y);
 return 0;}
// Nearest FOREIGN copper per layer \u2014 one layer arrives as several contours and
// only the closest of them bounds the opening.
function apNearest(list,x,y,net){var by={};
 (list||[]).forEach(function(f){if(!f||f.net===net)return;
  var key=f.layer||f.side||("stack"+f.stack),d=apDistToFill(f,x,y);
  if(!(key in by)||d<by[key])by[key]=d;});
 return by;}
function apLayerName(k){return String(k).replace(/\.Cu$/,"");}
// The worst reference-plane shortfall for one antipad record, or null when
// every plane closes to (near enough) the solved ring. INNER planes alone
// decide the verdict \u2014 they carry the capacitance via_antipad.solve models; an
// outer pour or user zone only ever colours the label.
function apStarved(a){
 var solved=(a.anti-a.dia)/2,tol=Math.max(0.05,0.5*solved),hit=null;
 var planes=apNearest(PCB.plane_fills,a.x,a.y,a.net);
 for(var k in planes){var d=planes[k],ex=d-a.dia/2-solved;
  if(d<=AP_REACH&&ex<=tol)continue;                 // this plane closes as solved
  if(!hit||ex>hit.excess)hit={plane:apLayerName(k),excess:ex,outer:null};}
 if(!hit)return null;
 var outer=apNearest(PCB.pours,a.x,a.y,a.net),zf=apNearest(PCB.zone_fills,a.x,a.y,a.net);
 for(var z in zf)if(!(z in outer)||zf[z]<outer[z])outer[z]=zf[z];
 for(var o in outer){var od=outer[o];if(od>AP_REACH)continue; // not this via's transition at all
  var oe=od-a.dia/2-solved;if(oe>tol&&(!hit.outer||oe>hit.outer.excess))hit.outer={plane:apLayerName(o),excess:oe};}
 return hit;}
function apExcessLabel(v){var s=" \u00b7 "+v.plane+" +"+v.excess.toFixed(3)+"mm";
 return v.outer?s+" \u00b7 "+v.outer.plane+" +"+v.outer.excess.toFixed(3)+"mm":s;}
// Per-via verdicts, cached until a source array is REPLACED (the pour-refill
// path reassigns PCB.pours/plane_fills/zone_fills wholesale, so array identity
// is the invalidation signal). A real board carries <10 antipad vias and a
// handful of fills, so the rebuild is trivial \u2014 it just must not run per frame.
var apCache=null;
function apVerdicts(){var A=PCB.antipads||[];
 if(apCache&&apCache.a===A&&apCache.pf===PCB.plane_fills&&apCache.po===PCB.pours&&apCache.zf===PCB.zone_fills)return apCache.v;
 apCache={a:A,pf:PCB.plane_fills,po:PCB.pours,zf:PCB.zone_fills,v:A.map(function(a){return apStarved(a);})};
 return apCache.v;}
function paintAntipads(ctx,k){var A=PCB.antipads||[];
 if(!viewSt.vis.antipads||!A.length)return;
 var ik=1/Math.max(k||1,0.01),V=apVerdicts();
 ctx.save();
 A.forEach(function(a,i){var x=X(a.x),y=Y(a.y),v=V[i],col=v?"#ef4444":"#f59e0b";
  ctx.globalAlpha=0.85;ctx.setLineDash([4*ik,3*ik]);
  ctx.strokeStyle="#9aa7b4";ctx.lineWidth=1*ik;
  ctx.beginPath();ctx.arc(x,y,a.min/2*S,0,2*Math.PI);ctx.stroke();
  ctx.setLineDash([]);ctx.strokeStyle=col;ctx.lineWidth=1.5*ik;
  ctx.beginPath();ctx.arc(x,y,a.anti/2*S,0,2*Math.PI);ctx.stroke();
  ctx.font="600 "+(10*ik).toFixed(2)+"px system-ui,sans-serif";
  ctx.textAlign="left";ctx.textBaseline="middle";ctx.fillStyle=col;
  var lbl=a.net+" \u2300"+a.anti.toFixed(3)+(a.limited?" (clearance-limited)":"")+" \u00b7 min \u2300"+a.min.toFixed(3)+" \u00b7 ~"+Math.round(a.ohms)+"\u03a9";
  if(v)lbl+=apExcessLabel(v);
  ctx.fillText(lbl,x+a.anti/2*S+5*ik,y);
  ctx.globalAlpha=1;});
 ctx.restore();}
// ── The canonical paint order ───────────────────────────────────────────
// ONE ordered stage table, mirrored from src/render_order.zig — which carries
// the reasoning, the GPU-ownership rules and the deliberate KiCad divergences.
// A Zig test re-reads this array out of the shipped asset text and fails when
// the two disagree, so the browser, the WebGPU under-layer and the server PNG
// cannot drift into three different pictures of one board again.
//
// Fields:
//   n     stage name — the join key with render_order.zig and the PNG's table
//   gpu   ""|"fill"|"all" — what the WebGPU canvas below draws for itself.
//         "all" skips the 2D pass whole; "fill" means the GPU drew the bulk and
//         this pass still runs for the adornments (read via gpuOwns, never a
//         remembered `if(gpuScene)`).
//   rv    rank in the ASSEMBLY REVIEW sequence: that mode draws opaque package
//         bodies, so copper and the silk above it pass UNDER the part bodies.
//   sp    takes the drag split — runs for the static cache AND for the movers
//   q     quiet frames only; never baked into a drag cache
//   m2    on a GPU frame the MOVERS of this stage are baked out of the GPU
//         buffers, so their pass draws in full 2D
//   f     the pass itself; null = this surface paints nothing for the stage
var PAINT_STAGES=[
 {n:"substrate",gpu:"all",rv:0,f:function(c,k,s){paintPhysicalBoard(c,k);paintGridDots(c,k);}},
 {n:"plane_fills",gpu:"fill",rv:1,f:function(c,k,s){paintPours(c,k);}},
 {n:"keepouts",gpu:"",rv:2,f:function(c,k,s){paintKeepouts(c,k);}},
 {n:"groups",gpu:"",rv:8,sp:1,f:function(c,k,s){paintGroupBoxes(c,k,s.movG,s.only);}},
 {n:"parts",gpu:"fill",rv:7,sp:1,m2:1,f:function(c,k,s){paintParts(c,k,s.mov,s.only);}},
 {n:"ratsnest",gpu:"",rv:3,sp:1,f:function(c,k,s){
  // An exclusive replay hides saved copper: the placement guides stay, over an
  // optional faint ghost underlay that belongs to the static half alone.
  if(ovExclusive()){if(ovGhost()&&!s.only)paintGhost(c);paintGuides(c,s.mov,s.only);}
  else paintLinks(c,s.mov,s.only);}},
 {n:"clearance",gpu:"",rv:4,sp:1,f:function(c,k,s){if(!ovExclusive())paintClr(c,s.mov,s.only,s.cop);}},
 {n:"copper",gpu:"fill",rv:5,sp:1,f:function(c,k,s){
  if(ovExclusive())return;
  if(s.only&&!s.cop)return;   // the movers own only the copper a rigid group drags
  paintTracks(c,s.cop,s.only);}},
 {n:"pad_labels",gpu:"",rv:9,q:1,f:function(c,k,s){paintPadLabels(c,k,s.mov,s.only);}},
 {n:"footprint_silk",gpu:"",rv:6,sp:1,f:function(c,k,s){paintFootprintSilk(c,k,s.mov,s.only);}},
 {n:"board_silk",gpu:"",rv:10,sp:1,f:function(c,k,s){paintBoardSilk(c,k,s.movG,s.mov,s.only);}},
 {n:"edge_cuts",gpu:"",rv:11,f:null},   // retained SVG ABOVE this canvas — drawBoardRect
 {n:"overlays",gpu:"",rv:12,q:1,f:function(c,k,s){paintAntipads(c,k);}}
];
// The review sequence is the same table under its own ranks — one list, two
// orders, no second call sequence to drift.
var REVIEW_STAGES=PAINT_STAGES.slice().sort(function(a,b){return a.rv-b.rv;});
// Stage → GPU ownership, resolved once. Every partial skip in the passes below
// asks this instead of testing gpuScene directly, so the policy has one home.
var GPU_OWN={};PAINT_STAGES.forEach(function(_s){GPU_OWN[_s.n]=_s.gpu;});
function gpuOwns(n){return gpuScene&&!!GPU_OWN[n];}
// The quiet frame's stage state: nothing is moving, so no split and no carried
// copper. Frozen shape (never mutated) so the hot path allocates nothing.
var QUIET_STATE={mov:null,only:false,cop:null,movG:null};
// Walk the order for one pass of the frame. `s` says which half of a drag this
// is; the table says which stages that half owns.
function paintStages(ctx,k,s){
 var seq=PHYSICAL_REVIEW?REVIEW_STAGES:PAINT_STAGES,g0=gpuScene;
 for(var i=0;i<seq.length;i++){var st=seq[i];
  if(!st.f)continue;                        // this surface draws nothing here
  if(gpuScene&&st.gpu==="all")continue;     // the WebGPU canvas below drew it
  if(s.mov){
   if(st.q)continue;                        // quiet-only overlays never bake
   if(s.only&&!st.sp)continue;}             // movers repaint only the split stages
  if(gpuScene&&s.only&&st.m2)gpuScene=false;
  st.f(ctx,k,s);
  gpuScene=g0;}}
// The BAKED layer stack: everything a quiet frame draws below the live
// overlays. Called verbatim by scenePaint's quiet path and by ovsBuild, so a
// blit can never disagree with the repaint that replaces it.
function paintScene(ctx,k){
 if(CAM_REVIEW){paintCamBoard(ctx,k);if(camVisible("components")){paintParts(ctx,k);paintGroupBoxes(ctx,k);}return;}
 paintStages(ctx,k,QUIET_STATE);}
// Zoom frames render the FULL scene — a SCALED gesture blit of the previous
// frame was tried (2026-08-06) and reverted by user preference: the soft zoom
// preview and background-filled pan edges read worse than the ~one-frame cost
// of a real repaint now that the geometry passes are Path2D-cached. PAN frames
// take the overscan buffer above instead, which is a different deal entirely —
// it is full-quality pixels at their own scale, never a resample.
function scenePaint(){paintQueued=false;
 if(loopDirty){for(var lk in loopDirty)drawLoop(+lk);loopDirty=null;}
 var sm=svgMetricsGet(),sw=sm.cw,sh=sm.ch;if(!sw||!sh)return;
 var dpr=window.devicePixelRatio||1,w=Math.round(sw*dpr),h=Math.round(sh*dpr);
 if(CV.width!==w||CV.height!==h){CV.width=w;CV.height=h;
  CV.style.width=sw+"px";CV.style.height=sh+"px";
  ovs=null;}                      // the overscan buffer is sized to the old canvas
 CV.style.left=sm.offsetLeft+"px";CV.style.top=sm.offsetTop+"px";
 var ctx=CTX;
 var k=(sw/vb.w);                 // CSS px per svg-unit (label gating)
 var kk=k*dpr;
 var zoomHeld=(ovsKkPrev===kk);ovsKkPrev=kk; // a zoom frame changes kk; only a settled zoom may build the pan buffer
 cullFromVB(k);                   // the frame's visible world window (parts + pad labels)
 var mov=dragIdxSet();
 if(!mov){dragCache=null;gpuDragCache=null;
  // Retained SVG overlays stay hidden while the viewport is in motion (their
  // per-viewBox-write re-render was gesture jank); the quiet trailing repaint
  // brings them back, same rhythm as pad labels and grid dots.
  if(Date.now()>=vbQuiet)svgAdornShow();
  // Pan inside the busy window: copy the visible window out of the overscan
  // buffer 1:1 instead of re-rasterizing the scene. Paints nothing and returns
  // false whenever anything at all disagrees, so the full render below is
  // reached exactly as before.
  if(ovsFrame(ctx,w,h,k,kk,zoomHeld)){paintFlash(ctx);return;}
  // ?gpu=1: copper + pads move to the WebGPU canvas under this one, which also
  // owns the background — so this surface clears to TRANSPARENT and the passes
  // that would double-draw skip themselves on the same per-frame flag. Set and
  // cleared around straight-line code with no return in between.
  gpuScene=gpuLive();
  if(gpuScene)PCBGpu.frame(vb,gpuState());
  ctx.setTransform(1,0,0,1,0,0);
  if(gpuScene)ctx.clearRect(0,0,w,h);
  else{ctx.fillStyle=PHYSICAL_REVIEW?PH.bg:TH.bg;ctx.fillRect(0,0,w,h);}
  ctx.setTransform(kk,0,0,kk,-vb.x*kk,-vb.y*kk);   // draw in svg-unit coords
  paintScene(ctx,k);
  if(window.PCBOverlay&&PCBOverlay.paint){try{PCBOverlay.paint(CTX);}catch(e){}} // replay overlay (never mutates PCB copper), above the board's own layers
  paintInsp(ctx);
  paintPickPreview(ctx);
  paintDraw(ctx);
  paintPadAlign(ctx,k);
  gpuScene=false;}
 else{
  // A 2D DRAG renders entirely in 2D — the static cache is an OPAQUE bitmap
  // blitted over the whole canvas, so it hides the GPU surface completely and
  // that branch is byte-identical to the 2D-only build (no stale GPU ghost can
  // show through). dragCacheDrop at drag end schedules the pose rebuild.
  svgAdornShow(); // a part drag leaves the viewBox alone, so the overlays cost nothing to keep up
  // Copper a rigid-group drag translates live (stamped tracks/vias) is
  // dynamic; everything else stays in the bitmap.
  var cop=null;
  if(typeof gdrag!=="undefined"&&gdrag&&gdrag.moved&&(gdrag.ct.length||gdrag.cv.length)){
   cop=new Set();
   gdrag.ct.forEach(function(o){cop.add(o.t);});
   gdrag.cv.forEach(function(o){cop.add(o.v);});}
  var movG={};for(var mi in mov){var mg=grpOf(P[mi].ref);if(mg)movG[mg]=1;}
  // ?gpu=1: the movers are baked OUT of the GPU pad/bore buffers and drawn in
  // 2D on top, so no opaque bitmap is needed at all — see gpuDragFrame.
  if(gpuLive())gpuDragFrame(ctx,w,h,k,kk,mov,movG,cop);
  else{
   var key=w+"|"+h+"|"+vb.x+"|"+vb.y+"|"+vb.w+"|"+Object.keys(mov).join(",");
   if(!dragCache||dragCache.key!==key){
    var oc=(dragCache&&dragCache.cv.width===w&&dragCache.cv.height===h)?dragCache.cv:document.createElement("canvas");
    if(oc.width!==w)oc.width=w;if(oc.height!==h)oc.height=h;
    var c2=oc.getContext("2d",{alpha:false});
    c2.setTransform(1,0,0,1,0,0);
    c2.fillStyle=PHYSICAL_REVIEW?PH.bg:TH.bg;c2.fillRect(0,0,w,h);
    c2.setTransform(kk,0,0,kk,-vb.x*kk,-vb.y*kk);
    // The static half of the drag: the same order, minus the quiet-only
    // overlays the table marks (they are gesture-gated anyway).
    paintStages(c2,k,{mov:mov,only:false,cop:cop,movG:movG});
    dragCache={cv:oc,key:key};}
   ctx.setTransform(1,0,0,1,0,0);
   ctx.drawImage(dragCache.cv,0,0);
   ctx.setTransform(kk,0,0,kk,-vb.x*kk,-vb.y*kk);
   // Moving content on top. Z-order differs from the static scene (the
   // dragged part paints over copper/texts for the drag's duration) —
   // acceptable, arguably better feedback while holding a part.
   paintStages(ctx,k,{mov:mov,only:true,cop:cop,movG:movG});
   if(window.PCBOverlay&&PCBOverlay.paint){try{PCBOverlay.paint(CTX);}catch(e){}}} // replay overlay stays visible mid-drag
  paintInsp(ctx);
  paintPickPreview(ctx);
  paintDraw(ctx);
  paintPadAlign(ctx,k);}
 paintFlash(ctx);}
// One DRAG frame with the GPU live. The movers are baked OUT of the GPU's
// pad/bore buffers once and drawn in 2D on top. The untouched 2D adornments use
// a transparent offscreen cache (an opaque bitmap would hide WebGPU), leaving
// each later frame with one alpha blit plus the moving overlay.
//
// Both 2D halves walk PAINT_STAGES exactly like the quiet frame — the table's
// `gpu` field skips the substrate the GPU owns and thins the passes whose bulk
// it drew, and its `m2` field is what drops gpuScene for the movers' own parts
// pass (their pads and bores are baked OUT of the GPU buffers, so that one call
// must draw them in full). Bottom to top the frame is therefore:
//   GPU   grid · pour fills · pads + bores (movers ABSENT) · tracks · vias
//   2D    the stage order, static half — pour rims/keepouts/labels, group
//         boxes, part courtyards + ref-des, airwires + clearance, marquee
//         copper fringe, footprint silk, silk text
//   2D    the split stages again, movers only
// then the caller's shared insp/draw/pad-align/flash tail.
function gpuDragFrame(ctx,w,h,k,kk,mov,movG,cop){
 // One rebake per drag, not per move — and re-stated whenever something else
 // cleared it (a live R press commits poses through setT, which rebuilds the
 // whole board), so a mover can never reappear baked into the GPU buffer.
 if(!PCBGpu.partsExclIs(mov))PCBGpu.rebuildParts(mov);
 gpuScene=true;
 PCBGpu.frame(vb,gpuState());
 ctx.setTransform(1,0,0,1,0,0);
 ctx.clearRect(0,0,w,h);          // the GPU surface below owns the background
 // The static 2D adornments must remain alpha-preserving because the WebGPU
 // surface below owns the background and copper. Bake them once per gesture,
 // then each drag frame is one transparent blit plus the moving overlay.
 var key=w+"|"+h+"|"+vb.x+"|"+vb.y+"|"+vb.w+"|"+vb.h+"|"+Object.keys(mov).join(",");
 if(!gpuDragCache||gpuDragCache.key!==key){
  var oc=(gpuDragCache&&gpuDragCache.cv.width===w&&gpuDragCache.cv.height===h)?gpuDragCache.cv:document.createElement("canvas");
  if(oc.width!==w)oc.width=w;if(oc.height!==h)oc.height=h;
  var c2=oc.getContext("2d",{alpha:true});
  c2.setTransform(1,0,0,1,0,0);c2.clearRect(0,0,w,h);
  c2.setTransform(kk,0,0,kk,-vb.x*kk,-vb.y*kk);
  paintStages(c2,k,{mov:mov,only:false,cop:cop,movG:movG});
  gpuDragCache={cv:oc,key:key};}
 ctx.setTransform(1,0,0,1,0,0);ctx.drawImage(gpuDragCache.cv,0,0);
 ctx.setTransform(kk,0,0,kk,-vb.x*kk,-vb.y*kk);
 paintStages(ctx,k,{mov:mov,only:true,cop:cop,movG:movG});
 if(window.PCBOverlay&&PCBOverlay.paint){try{PCBOverlay.paint(CTX);}catch(e){}} // replay overlay stays visible mid-drag
 gpuScene=false;}
// Flash markers close every frame — the full scene's and the gesture blit's
// alike, so DRC click-to-locate keeps pulsing through a pan. Both callers hand
// it the world transform.
function paintFlash(ctx){
 if(flashIdx>=0&&Date.now()<flashUntil){var fp=P[flashIdx];
  var fc=wpt(flashIdx,fp.ccx||0,fp.ccy||0);
  ctx.strokeStyle="#f0b72f";ctx.lineWidth=2.6;
  ctx.globalAlpha=0.4+0.6*Math.abs(Math.sin(Date.now()/180));
  ctx.strokeRect(X(fc.x)-fp.hw*S,Y(fc.y)-fp.hh*S,2*fp.hw*S,2*fp.hh*S);
  ctx.globalAlpha=1;setTimeout(paintSoon,60);}
 else if(flashIdx>=0){flashIdx=-1;}
 // Flash-point marker (DRC click-to-locate): a pulsing ring at a world point.
 if(flashPt&&Date.now()<flashPtUntil){
  ctx.strokeStyle=TH.drc;ctx.lineWidth=2.2;
  ctx.globalAlpha=0.35+0.65*Math.abs(Math.sin(Date.now()/180));
  ctx.beginPath();ctx.arc(X(flashPt.x),Y(flashPt.y),12,0,6.2832);ctx.stroke();
  ctx.beginPath();ctx.arc(X(flashPt.x),Y(flashPt.y),3.5,0,6.2832);ctx.stroke();
  ctx.globalAlpha=1;setTimeout(paintSoon,60);}
 else if(flashPt){flashPt=null;}}
// ── Grid dots as a repeating pattern ────────────────────────────────────
// One dot tile repeated over the viewport instead of a fillRect per dot: at a
// mid zoom this board puts ~21.5k dots on screen and the per-dot loop cost more
// than every other pass of the frame together.
//
// A pattern tile is a BITMAP, so it repeats at a whole number of tile pixels
// while the dot pitch p (device px) is fractional — a tile of round(p) px would
// drift ~0.14 px per column, ~7 px across a 1600 px screen, and the far edge
// would sit visibly off-grid. Two things remove that: the tile spans k grid
// cells (k∈1..8, the first/closest whose k*p is nearly whole), and the fill is
// painted through a scale s=k*p/T that stretches the T-px tile onto EXACTLY k*p
// device px. The scale is the exact correction, so the repeat is drift-free for
// any pitch; k only keeps s near 1 so the tile blits essentially 1:1 (k=7,
// s−1≈4e-5 at this board's mid-zoom pitch of 8.142 px). A pitch that tiles to
// nothing in range (>512 px, i.e. a handful of dots on screen) keeps the loop.
//
// Alignment invariant: dot CENTRES land on kk*(X(n*g)−vb.x) for integer n — the
// exact device positions the per-dot loop drew — because the tile's first dot
// sits half a cell in and the phase translate puts that half-cell offset on the
// first visible grid line.
//
// The tile is only "k×k dots on a T×T bitmap grid" — the exact stretch is
// recomputed per paint from the LIVE pitch, so reusing a cached tile across a
// pitch nudge can never reintroduce drift. The key quantises the pitch anyway
// (a zoom tick rebuilds, a pan never does); at 2 decimals a reused tile's only
// staleness is its dot's bitmap size, under 1% of a 1.4 px dot.
var gridTile=null; // {key,cv,T,k,q}
function gridDotTile(p,dd,col){
 var bk=0,be=1e9,T=0;
 for(var i=1;i<=8;i++){var t=Math.round(i*p);
  if(t<2||t>512)continue;
  var e=Math.abs(i*p-t)/t;              // relative stretch the scale has to undo
  if(e<be){be=e;bk=i;T=t;}
  if(e<1e-4)break;}                     // close enough — smallest such k wins
 if(!bk)return null;
 var key=T+"|"+bk+"|"+p.toFixed(2)+"|"+dd.toFixed(2)+"|"+col;
 if(gridTile&&gridTile.key===key)return gridTile;
 var cv=document.createElement("canvas");cv.width=T;cv.height=T;
 var c=cv.getContext("2d");if(!c)return null;
 var q=T/bk,db=dd*T/(bk*p);             // bitmap cell + dot size that scale to p / dd
 c.fillStyle=col;
 // Half a cell in, so a dot is wholly interior and the repeat has no seam
 // (dd is ~1.4 css px and q≳8, so it always fits).
 for(var ix=0;ix<bk;ix++)for(var iy=0;iy<bk;iy++)
  c.fillRect(ix*q+q/2-db/2,iy*q+q/2-db/2,db,db);
 gridTile={key:key,cv:cv,T:T,k:bk,q:q};
 return gridTile;}
// Paints the whole visible rect in one fillRect. gx0/gy0 = first visible grid
// line (world mm); p/dd are device px. false ⇒ caller runs the per-dot loop.
function gridDotPattern(ctx,kk,p,dd,gx0,gy0){
 if(typeof ctx.createPattern!=="function")return false;
 var tl=gridDotTile(p,dd,TH.gridDot);if(!tl)return false;
 var pat=ctx.createPattern(tl.cv,"repeat");if(!pat)return false;
 var s=tl.k*p/tl.T,rp=tl.k*p;           // one repeat = k cells = exactly k*p device px
 var d0x=kk*(X(gx0)-vb.x),d0y=kk*(Y(gy0)-vb.y);
 var tx=((d0x-p/2)%rp+rp)%rp,ty=((d0y-p/2)%rp+rp)%rp;
 var W=ctx.canvas.width,H=ctx.canvas.height;
 ctx.save();
 ctx.setTransform(s,0,0,s,tx,ty);       // pattern space: tile pixel → device px
 ctx.fillStyle=pat;
 ctx.fillRect(-tx/s,-ty/s,W/s,H/s);     // device (0,0)–(W,H)
 ctx.restore();
 return true;}
// Grid-dot overlay at the current snap pitch, only when the dots are at
// least ~8 screen px apart (KiCad shows dots, not a mesh, and hides them
// when they'd blur together).
function paintGridDots(ctx,k){
 // GPU frame: the grid is an UNDER-copper layer and this canvas is above the
 // GPU one, so drawing it here would speckle every trace. From M2 the GPU draws
 // it itself — one full-screen triangle that computes its own dots from the
 // camera uniform (gridPitch/gridDot in gpuState), phase-identical to the loop
 // below because both land on X(n*g).
 if(gpuOwns("substrate"))return;
 if(PHYSICAL_REVIEW)return;
 var g=viewSt.grid;if(!(g>0))return;
 if(g*S*k<8)return;
 // Pan/zoom bursts repaint every frame — skip the dot grid until quiet (the
 // trailing repaint restores it). Part drags keep it: it lives in the static
 // drag-cache bitmap, rendered once per gesture. The overscan bake keeps it
 // too, for the same reason — one render per buffer, not one per frame.
 if(!ovsBuilding&&Date.now()<vbQuiet)return;
 var wx0=vb.x/S+MX-M,wx1=(vb.x+vb.w)/S+MX-M;
 var wy0=vb.y/S+MY-M,wy1=(vb.y+vb.h)/S+MY-M;
 var gx0=Math.ceil(wx0/g)*g,gy0=Math.ceil(wy0/g)*g;
 var nx=Math.floor((wx1-gx0)/g)+1,ny=Math.floor((wy1-gy0)/g)+1;
 if(nx<=0||ny<=0)return;
 var dpr=window.devicePixelRatio||1,kk=k*dpr; // the world transform scenePaint set
 if(gridDotPattern(ctx,kk,g*S*kk,1.4*dpr,gx0,gy0))return;
 if(nx*ny>60000)return; // count cap guards the per-dot path only — the pattern is O(1)
 var d=1.4/k; // ~1.4 css px dot
 ctx.fillStyle=TH.gridDot;
 for(var ix=0;ix<nx;ix++){var px=X(gx0+ix*g)-d/2;
  for(var iy=0;iy<ny;iy++)ctx.fillRect(px,Y(gy0+iy*g)-d/2,d,d);}}
// Opaque substrate/mask base. All later physical-review artwork is confined
// visually to a real board instead of floating over the editor canvas.
function physicalBoardPath(ctx){var pts=reviewBoardPoints();if(pts.length<3)return false;
 ctx.beginPath();ctx.moveTo(X(pts[0][0]),Y(pts[0][1]));
 for(var i=1;i<pts.length;i++)ctx.lineTo(X(pts[i][0]),Y(pts[i][1]));ctx.closePath();return true;}
function paintPhysicalBoard(ctx,k){if(!PHYSICAL_REVIEW||!physicalBoardPath(ctx))return;
 var ik=1/Math.max(k||1,0.01),r=PCB.rules||{},mw=Number(r.perimeter_mask_width)||0;
 ctx.save();ctx.fillStyle=PH.mask;ctx.fill();
 // The Gerber mask layer strokes Edge.Cuts at 2*mask-width. Clip that same
 // stroke to the board so the physical review shows exactly WIDTH inward,
 // without painting an amber halo outside the finished edge.
 if(mw>0){ctx.clip();physicalBoardPath(ctx);ctx.strokeStyle=PH.opening;
  ctx.lineWidth=2*mw*S;ctx.lineJoin="round";ctx.stroke();}
 ctx.restore();ctx.save();physicalBoardPath(ctx);
 ctx.strokeStyle=PH.edge;ctx.lineWidth=Math.max(1.4*ik,0.16*S);ctx.lineJoin="round";ctx.stroke();
 ctx.globalAlpha=0.22;ctx.strokeStyle="#8bc49a";ctx.lineWidth=Math.max(0.7*ik,0.05*S);ctx.stroke();
 ctx.restore();}
// ── Gerber/Excellon read-back paint (Assembly only) ─────────────────────
// Each layer is composed on an isolated bitmap because Gerber polarity is
// ordered: clear operations erase earlier dark copper/opening shapes, and a
// later dark patch may repaint them. Mask files are negative, so their dark
// operations punch openings in an initially solid board-shaped mask bitmap.
var camLayerCache={};
function camLayerVisible(L){if(!L)return false;
 if(L.kind==="copper"){
  if(L.side==="inner")return camVisible("inner_copper");
  return camVisible("copper")&&L.side===(activeLayer===1?"bottom":"top");}
 if(L.kind==="mask"||L.kind==="paste"||L.kind==="silk")return camVisible(L.kind)&&L.side===(activeLayer===1?"bottom":"top");
 if(L.kind==="drill")return camVisible("drills");
 if(L.kind==="outline")return camVisible("outline");return false;}
function camRoundedRect(c,x,y,w,h){var r=Math.min(w,h)/2;c.beginPath();
 if(w>=h){c.moveTo(x-w/2+r,y-h/2);c.lineTo(x+w/2-r,y-h/2);c.arc(x+w/2-r,y,r,-Math.PI/2,Math.PI/2);c.lineTo(x-w/2+r,y+h/2);c.arc(x-w/2+r,y,r,Math.PI/2,3*Math.PI/2);}
 else{c.moveTo(x-w/2,y-h/2+r);c.arc(x,y-h/2+r,r,Math.PI,0);c.lineTo(x+w/2,y+h/2-r);c.arc(x,y+h/2-r,r,0,Math.PI);c.lineTo(x-w/2,y-h/2+r);}c.closePath();}
function camDrawOp(c,o,col){var t=o[0],dark=t==="r"?!!o[1]:!!o[o.length-1];
 c.globalCompositeOperation=dark?"source-over":"destination-out";c.fillStyle=col;c.strokeStyle=col;
 if(t==="f"){var x=X(o[1]),y=Y(o[2]),w=o[4]*S,h=o[5]*S;c.beginPath();
  if(o[3]===0)c.arc(x,y,w/2,0,6.2832);else if(o[3]===1)c.rect(x-w/2,y-h/2,w,h);else camRoundedRect(c,x,y,w,h);c.fill();return;}
 if(t==="l"){c.lineWidth=o[5]*S;c.lineCap="round";c.beginPath();c.moveTo(X(o[1]),Y(o[2]));c.lineTo(X(o[3]),Y(o[4]));c.stroke();return;}
 if(t==="a"){var cx=X(o[5]),cy=Y(o[6]),x1=X(o[1]),y1=Y(o[2]),x2=X(o[3]),y2=Y(o[4]);
  c.lineWidth=o[7]*S;c.lineCap="round";c.beginPath();c.arc(cx,cy,Math.hypot(x1-cx,y1-cy),Math.atan2(y1-cy,x1-cx),Math.atan2(y2-cy,x2-cx),!o[8]);c.stroke();return;}
 if(t==="r"){var ps=o[2];if(!ps||ps.length<3)return;c.beginPath();c.moveTo(X(ps[0][0]),Y(ps[0][1]));
  for(var i=1;i<ps.length;i++)c.lineTo(X(ps[i][0]),Y(ps[i][1]));c.closePath();c.fill();}}
function camLayerBitmap(target,L,col){var tr=target.getTransform(),key=[target.canvas.width,target.canvas.height,tr.a,tr.b,tr.c,tr.d,tr.e,tr.f,col].join("|"),hit=camLayerCache[L.id];
 if(hit&&hit.key===key)return hit.cv;var cv=hit&&hit.cv||document.createElement("canvas");cv.width=target.canvas.width;cv.height=target.canvas.height;
 var c=cv.getContext("2d",{alpha:true});c.setTransform(1,0,0,1,0,0);c.clearRect(0,0,cv.width,cv.height);c.setTransform(tr);
 // Finished-board clipping is shared by every artwork film. The visible edge
 // itself is still the parsed Profile Gerber drawn as its own layer below.
 if(physicalBoardPath(c))c.clip();
 if(L.negative){c.globalCompositeOperation="source-over";c.fillStyle=col;physicalBoardPath(c);c.fill();
  (L.ops||[]).forEach(function(o){var dark=o[0]==="r"?!!o[1]:!!o[o.length-1];
   var q=o.slice();if(q[0]==="r")q[1]=!dark;else q[q.length-1]=!dark;camDrawOp(c,q,col);});}
 else (L.ops||[]).forEach(function(o){camDrawOp(c,o,col);});
 camLayerCache[L.id]={key:key,cv:cv};return cv;}
function camPaintLayer(ctx,L,col,a){var cv=camLayerBitmap(ctx,L,col);ctx.save();ctx.setTransform(1,0,0,1,0,0);ctx.globalCompositeOperation="source-over";ctx.globalAlpha=a==null?1:a;ctx.drawImage(cv,0,0);ctx.restore();}
function paintCamBoard(ctx,k){if(!CAM_REVIEW)return;ctx.save();if(physicalBoardPath(ctx)){ctx.fillStyle=PH.substrate;ctx.fill();}ctx.restore();
 var layers=PCB.cam.layers||[];
 // Inner films are optional context; the selected outer copper is the face.
 layers.forEach(function(L){if(L.kind==="copper"&&L.side==="inner"&&camLayerVisible(L))camPaintLayer(ctx,L,"#b87333",0.24);});
 layers.forEach(function(L){if(L.kind==="copper"&&L.side!=="inner"&&camLayerVisible(L))camPaintLayer(ctx,L,PH.copper,1);});
 layers.forEach(function(L){if(L.kind==="mask"&&camLayerVisible(L))camPaintLayer(ctx,L,PH.mask,0.94);});
 layers.forEach(function(L){if(L.kind==="paste"&&camLayerVisible(L))camPaintLayer(ctx,L,"#b9c5d1",0.72);});
 layers.forEach(function(L){if(L.kind==="silk"&&camLayerVisible(L))camPaintLayer(ctx,L,PH.silk,1);});
 layers.forEach(function(L){if(L.kind==="drill"&&camLayerVisible(L))camPaintLayer(ctx,L,PH.hole,1);});
 layers.forEach(function(L){if(L.kind==="outline"&&camLayerVisible(L))camPaintLayer(ctx,L,PH.edge,1);});}
// KiCad-style highlight ladder: hover/selection brighten to white; marquee
// glows keep their accent; everything else is the dim courtyard magenta.
// A rigid sub-circuit's selected state belongs exclusively to its green group
// box (paintGroupBoxes), rather than repeating around every member courtyard.
function partStroke(i,p){
 if(!partOnVisibleFace(p))return null;
 if(reviewFocusActive()){
  if(reviewFocus.refIdx[i])return {c:"#ffd33d",w:2.8};
  if(reviewFocus.partIdx[i])return {c:"#58d6ff",w:2.5};}
 if(i===cur&&!RO)return {c:"#ffffff",w:2};
 if(selRef&&p.ref===selRef)return {c:"#ffffff",w:2.4};
 if(sel&&sel.indexOf&&sel.indexOf(i)>=0)return {c:TH.sel,w:2};
 if(hoverGrpName&&grpOf(p.ref)===hoverGrpName)return {c:"#7ee787",w:2};
 return {c:TH.court,w:0.25};}
// Per-part Path2D cache: silk strokes + drill bores are static geometry in
// part-local coords — build once, then each frame is a single stroke()/fill()
// under the part's transform instead of hundreds of path-segment calls.
// (Pad fills stay per-pad: their colour varies by net/side/hover. Courtyard
// edits touch p.hw/hh only, never pads/silk, so entries never go stale.)
var partPaths=[];
function partPath(i){var c=partPaths[i];if(c)return c;
 var p=P[i],silk=null,bore=null;
 if(p.silk&&((p.silk.l&&p.silk.l.length)||(p.silk.c&&p.silk.c.length))){silk=new Path2D();
  p.silk.l.forEach(function(sl){silk.moveTo(sl[0]*S,sl[1]*S);silk.lineTo(sl[2]*S,sl[3]*S);});
  p.silk.c.forEach(function(sc){if(pinOneAuthoredCircle(sc))return;var cr=Math.max(sc[2]*S,1);
   silk.moveTo(sc[0]*S+cr,sc[1]*S);silk.arc(sc[0]*S,sc[1]*S,cr,0,6.2832);});}
 (p.pads||[]).forEach(function(pd){if(pd.drill>0){var br=Math.max(pd.drill/2*S,0.6);
  if(!bore)bore=new Path2D();bore.moveTo(pd.x*S+br,pd.y*S);bore.arc(pd.x*S,pd.y*S,br,0,6.2832);}});
 c={silk:silk,bore:bore};partPaths[i]=c;return c;}
// ── Glyph sprite cache (pad numbers + ref-des) ──────────────────────────
// Canvas text raster is the slowest 2D path there is, and a quiet frame here
// asks for ~607 strokeText(halo)+fillText pairs and ~167 ref-des fillTexts with
// a font re-assignment on every size change — all of them the SAME few hundred
// rasters, only moved. Each (text, device-px size, style) is rendered ONCE into
// a device-resolution offscreen canvas; every later frame is one drawImage.
// Alpha stays OUT of the sprite (applied via ctx.globalAlpha at draw time) so
// one sprite serves every fade/dim. Colours live in the KEY, so a theme or
// state change can never show a stale raster.
// ACCEPTED DIFFERENCE vs direct text raster: the size key quantises to 0.1
// device px and the blit snaps to whole device pixels, so a label's subpixel
// phase and antialiasing detail can differ by under one device pixel. Size,
// colours, halo thickness, alpha and position are otherwise identical.
// A Map, not an object: keys are arbitrary label text, and a pad numbered
// "constructor" would read a prototype member out of an object literal.
// Cap sized for the OVERSCAN bake, not the viewport: the pan buffer renders
// 2.56x the visible area, so the live working set is ~2.5x what a viewport-only
// render needed (measured on barracuda at mid zoom: 355 entries viewport-only,
// 435 with the bake — pad numbers saturate on the distinct strings, ref-des
// entries scale with area). The cap is a hard clear(), so leaving it at the old
// viewport figure would turn the cache into a per-frame rebuild on a dense
// board. A sprite is a ~1 KB bitmap; the headroom is cheap.
var glyphs=new Map(),glyphMC=null,GLYPH_CAP=1600;
function glyphMeasureCtx(){if(glyphMC===null){var c=document.createElement("canvas");
  c.width=c.height=8;glyphMC=c.getContext("2d")||false;}
 return glyphMC;}
// fd/lw are DEVICE px; halo null = fill only; mid = textBaseline "middle"
// (pad numbers) vs "alphabetic" (ref-des). null ⇒ caller draws text directly.
function glyph(key,txt,fd,fill,halo,lw,mid){
 var g=glyphs.get(key);if(g!==undefined)return g;
 if(glyphs.size>=GLYPH_CAP)glyphs.clear(); // hard cap, full reset — simplest correct policy
 var mc=glyphMeasureCtx(),f="600 "+fd.toFixed(1)+"px system-ui,sans-serif",tw=0;
 if(mc){mc.font=f;tw=mc.measureText(txt).width;}
 if(!(tw>0))tw=txt.length*fd*0.6;
 var pad=Math.ceil(lw/2)+2,w=Math.ceil(tw)+2*pad,asc=Math.ceil(fd*0.8);
 var h=mid?2*Math.ceil(fd*0.62)+2*pad:asc+Math.ceil(fd*0.28)+2*pad;
 var cv=document.createElement("canvas");cv.width=w;cv.height=h;
 var c=cv.getContext("2d");if(!c){glyphs.set(key,null);return null;}
 var ax=w/2,ay=mid?h/2:pad+asc;
 c.font=f;c.textAlign="center";c.textBaseline=mid?"middle":"alphabetic";
 if(halo){c.lineJoin="round";c.lineWidth=lw;c.strokeStyle=halo;c.strokeText(txt,ax,ay);}
 c.fillStyle=fill;c.fillText(txt,ax,ay);
 g={cv:cv,w:w,h:h,ax:ax,ay:ay};glyphs.set(key,g);return g;}
// Blit so the sprite's anchor lands where fillText's would. xx/yy are svg units
// under the world transform (kk device px per unit); the device-pixel snap
// keeps the raster 1:1 instead of resampling it soft.
function glyphDraw(ctx,g,xx,yy,kk){
 var dx=Math.round(kk*(xx-vb.x)-g.ax),dy=Math.round(kk*(yy-vb.y)-g.ay);
 ctx.drawImage(g.cv,dx/kk+vb.x,dy/kk+vb.y,g.w/kk,g.h/kk);}
// Per-part ref-des memo: a part's label text never changes, so at a fixed zoom
// and state the key string need not be rebuilt at all — a pan does zero string
// work. Guarded on the two things that CAN change it (device size, colour); a
// GLYPH_CAP reset may leave a sprite here that the map dropped, which is
// harmless (the canvas stays valid) and bounds the extra to one per part.
var refG=[],refFd=[],refCol=[];
function testPointPart(p){var c=String((p&&p.component)||"");return c==="testpoint"||c.indexOf("testpoint-")===0;}
// mov/only: the drag-cache split — mov = moving part index set; only=false
// paints the static remainder, only=true just the movers. mov null = all.
function paintParts(ctx,k,mov,only){
 var kk=k*(window.devicePixelRatio||1); // sprite blits are device-resolution
 var cull=!cullOff;                     // hoisted: zoomed out, not even a call per part
 for(var i=0;i<P.length;i++){var p=P[i];
  if(mov&&(!!mov[i])!==only)continue;
  if(cull&&partCulled(i))continue; // off-screen: nothing it draws can reach the viewport
  var focusAlpha=reviewFocusPartAlpha(i),throughAlpha=focusAlpha;
  var bot=(p.side==="bottom"),unp=!!unplacedSet[p.ref];
  // A solid pour hides the far side: fade (and at 100% skip) foreign-side parts.
  // Drilled pads are physical stack-spanning features, so keep their annulus
  // and bore even when every face-specific feature of this part is hidden.
  if(!PHYSICAL_REVIEW&&!unp){var pfd=pourForeignFade(bot);
   if(pfd<=0&&!(p.pads||[]).some(function(pd){return pd.drill>0;}))continue;focusAlpha*=pfd;}
  ctx.save();
  ctx.globalAlpha=focusAlpha;
  ctx.translate(X(p.x),Y(p.y));ctx.rotate((p.rot||0)*Math.PI/180);
  if(bot)ctx.scale(-1,1);
  // courtyard (box centre can be offset from the part origin — asymmetric
  // library rects; the local frame already carries rotation + mirror).
  // KiCad-style: a thin dim magenta outline, NO body fill — parts read from
  // their pads + silk. The heatmap tint and the staged-part red wash are the
  // two deliberate exceptions.
  var hw=p.hw*S,hh=p.hh*S,ccx=(p.ccx||0)*S,ccy=(p.ccy||0)*S;
  if(!PHYSICAL_REVIEW&&heatOn&&p.ref!==anchorRef){
   ctx.fillStyle=blameColor(heatScale>0?(p.blame||0)/heatScale:0);
   ctx.fillRect(ccx-hw,ccy-hh,2*hw,2*hh);}
  if(unp){ctx.fillStyle="rgba(248,81,73,.12)";ctx.fillRect(ccx-hw,ccy-hh,2*hw,2*hh);}
  var showCourt=!PHYSICAL_REVIEW||unp||(reviewFocusActive()&&reviewFocus.partIdx[i]);
  var st=showCourt?partStroke(i,p):null;
  // F.CrtYd / B.CrtYd own the courtyard RING, per side. The eye never hides a
  // SELECTION though: partStroke returns the plain courtyard colour only when
  // the part is neither hovered, selected, grouped nor staged, so exactly that
  // case is what the hidden layer suppresses.
  if(st&&st.c===TH.court&&!unp&&!viewSt.vis[bot?LN.b_crtyd:LN.f_crtyd])st=null;
  if(st){
   ctx.strokeStyle=unp?"#f85149":st.c;ctx.lineWidth=unp?1.6:st.w;
   if(unp)ctx.setLineDash([4,3]);
   else if(p.locked)ctx.setLineDash([2,2]);
   else if(p.fb)ctx.setLineDash([4,3]);
   else ctx.setLineDash([]);
   ctx.strokeRect(ccx-hw,ccy-hh,2*hw,2*hh);
   ctx.setLineDash([]);}
  if(unp){ctx.strokeStyle="#f85149";ctx.lineWidth=1;
   ctx.beginPath();ctx.moveTo(ccx-hw,ccy-hh);ctx.lineTo(ccx+hw,ccy+hh);
   ctx.moveTo(ccx+hw,ccy-hh);ctx.lineTo(ccx-hw,ccy+hh);ctx.globalAlpha=0.8*focusAlpha;ctx.stroke();ctx.globalAlpha=focusAlpha;}
  var pp=partPath(i);
  // Footprint silk is NOT drawn here — it paints above the copper, in
  // paintFootprintSilk. See that pass for why.
  // pads (in the same part frame) — fillStyle set only when it changes.
  // Default: layer-coloured, KiCad-style — SMD pads in their face's copper
  // colour, plated through-holes gold, NPTH a copper-free rim. The opt-in
  // Net-colours view keeps per-net fills.
  // hlAny: did ANY pad of this part take a 2D overdraw this frame? On a GPU
  // frame the default pad fills are skipped (the GPU drew them), but a
  // highlighted or concave custom pad still fills here — and then needs its
  // drill bore punched in 2D as well, since the GPU bore sits UNDER that fill.
  var lastFill=null,hlAny=false;
  (p.pads||[]).forEach(function(pd){
   var focusPad=reviewFocusNet(pd.net),targetPad=reviewFocusPad(i,pd);
   var physicalFace=pd.drill>0||(bot?1:0)===activeLayer;
   if(PHYSICAL_REVIEW&&!physicalFace&&!focusPad&&!targetPad)return;
   // The quiet Assembly board already contains this pad as a parsed Gerber
   // operation. Retain only interactive focus overlays here.
   if(CAM_REVIEW&&!focusPad&&!targetPad)return;
   var padAlpha=PHYSICAL_REVIEW?1:((pd.drill>0)?1:layerAlpha(bot?1:0));if(padAlpha<=0)return;
   var fill;
   if(PHYSICAL_REVIEW)fill=pd.npth?PH.npth:PH.copper;
   else if(netColOn)fill=pd.net?(netColorOf(pd.net)||TH.pth):"#ffffff";
   else if(pd.drill>0)fill=pd.npth?TH.npth:TH.pth;
   else fill=bot?TH.padBot:TH.padTop;
   // Net highlight: hovered net, or the net being hand-routed right now —
   // the whole net lights up while a trace is live, same as a net click.
   var hlNet=hoverNet||(drawMode&&dtrace?dtrace.net:null),hl=false;
   if(hlNet&&pd.net===hlNet){fill="#f85149";padAlpha=1;hl=true;}
   if(focusPad){fill="#58d6ff";padAlpha=1;hl=true;}
   if(targetPad){fill="#ff7b72";padAlpha=1;hl=true;}
   if(hl)hlAny=true;
   ctx.globalAlpha=padAlpha*(pd.drill>0?throughAlpha:focusAlpha);
   // Gerber-equivalent mask relief: SMD pads open only on their face while
   // through/NPTH pads open on both. Vias remain tented in paintTracks.
   if(PHYSICAL_REVIEW&&physicalFace){var mm=PCB.rules&&typeof PCB.rules.mask_margin==="number"?PCB.rules.mask_margin:0.05;
    ctx.strokeStyle=PH.opening;ctx.lineWidth=Math.max(2*mm*S,0.8);ctx.lineJoin="round";
    padPath(ctx,pd);ctx.stroke();ctx.lineJoin="miter";}
   // The DEFAULT-coloured fill is the one thing the GPU pad pass replaces; the
   // highlight/selection/net-glow overdraws below stay 2D and paint over it.
   // Custom outlines stay on Canvas2D. The GPU uses a triangle fan, which can
   // corrupt imported concave/self-touching rings even when a cheap convexity
   // classifier happens to accept them.
   var exactPoly=!!(pd.poly&&pd.poly.length>=3);
   if(exactPoly)hlAny=true;
   if(!gpuOwns("parts")||hl||exactPoly){if(fill!==lastFill){ctx.fillStyle=fill;lastFill=fill;}
    padPath(ctx,pd);ctx.fill();}
   if(focusPad||targetPad){ctx.strokeStyle="#ffffff";ctx.lineWidth=targetPad?3:2.1;
    padPath(ctx,pd);ctx.stroke();}
   if(selNetCur&&pd.net===selNetCur){
    var pin=!!loopPin[i+":"+pd.x.toFixed(2)+":"+pd.y.toFixed(2)];
    ctx.strokeStyle=pin?"#f85149":"#ffd33d";ctx.lineWidth=1.8;
    padPath(ctx,pd);ctx.stroke();}
   var pa=(padAlignA&&padAlignA.i===i&&padAlignA.pd===pd),pb=(padAlignB&&padAlignB.i===i&&padAlignB.pd===pd);
   if(pa||pb){ctx.strokeStyle=pa?"#e3b341":"#7ee787";ctx.lineWidth=2.8;
    ctx.setLineDash(pa?[4,2]:[]);padPath(ctx,pd);ctx.stroke();ctx.setLineDash([]);}
   ctx.globalAlpha=focusAlpha;});
  // Drilled bores: board-coloured holes through thru/npth pads, one batched
  // fill per part (cached path) instead of a beginPath/arc per pad.
  if(!CAM_REVIEW&&pp.bore&&(!gpuOwns("parts")||hlAny)){ctx.globalAlpha=1;ctx.fillStyle=PHYSICAL_REVIEW?PH.hole:TH.hole;
   ctx.fill(pp.bore);ctx.globalAlpha=focusAlpha;}
  // A model body arrives later than the PCB itself. Draw it in the exact same
  // local footprint transform as pads/silk so placement rotation, bottom-side
  // mirroring, zoom, and review-focus fading all remain automatic. Only the
  // currently viewed face is populated; flipping the board reveals its parts.
  var sprite=PHYSICAL_REVIEW&&(!CAM_REVIEW||camVisible("components"))&&((bot?1:0)===activeLayer)?assemblySprites[p.fp]:null;
  if(sprite){ctx.globalAlpha=focusAlpha;
   ctx.drawImage(sprite.image,sprite.x*S,sprite.y*S,sprite.w*S,sprite.h*S);
   // The focused-part outline belongs above an opaque package body.
   if(reviewFocusActive()&&reviewFocus.partIdx[i]){var ss=partStroke(i,p);if(ss){
    ctx.strokeStyle=ss.c;ctx.lineWidth=ss.w;ctx.setLineDash([]);
    ctx.strokeRect(ccx-hw,ccy-hh,2*hw,2*hh);}}}
  // Placement orientation must remain visible even above an opaque model:
  // repaint authored pad 1 last in the same rotated/mirrored part frame.
  (p.pads||[]).forEach(function(pd){var targetPad=reviewFocusPad(i,pd);
   if(!reviewPinOne(i,pd)&&!targetPad)return;
   var physicalFace=pd.drill>0||(bot?1:0)===activeLayer;if(!physicalFace)return;
   ctx.globalAlpha=1;ctx.fillStyle=targetPad?"#ff7b72":PH.pin1;padPath(ctx,pd);ctx.fill();
   ctx.strokeStyle="#ffffff";ctx.lineWidth=(targetPad?3:2)/Math.max(k,0.01);
   ctx.setLineDash([]);padPath(ctx,pd);ctx.stroke();
   if(pd.drill>0){var br=Math.max(pd.drill/2*S,0.6);ctx.fillStyle=PH.hole;
    ctx.beginPath();ctx.arc(pd.x*S,pd.y*S,br,0,6.2832);ctx.fill();}});
  ctx.restore();
  // Pad-number labels are no longer drawn here — they render in paintPadLabels
  // AFTER the copper pass, so a trace routed across a pad never hides its pin
  // number. The pads themselves still paint here, under the tracks.
  // Ref-des labels, KiCad-style: always drawn in silk colour above the
  // courtyard once the part is big enough on screen to carry one (hovered /
  // selected / staged parts always label; the rest pause during drags/zooms
  // like the pad numbers, so gestures stay O(movers)). Size tracks zoom
  // within clamps so labels stay legible without blanketing the board.
  var wantRef=(i===cur)||unp||(selRef&&p.ref===selRef)||(reviewFocusActive()&&reviewFocus.partIdx[i]);
  if(!CAM_REVIEW&&!testPointPart(p)&&viewSt.vis.refdes&&(!PHYSICAL_REVIEW||(bot?1:0)===activeLayer)&&
   (wantRef||(!gestureBusy()&&p.hw*2*S*k>=14))){
   var rpx=Math.max(7,Math.min(11,p.hw*2*S*k*0.22)); // screen px, clamped
   var rcol=unp?"#f85149":(reviewFocusActive()&&reviewFocus.refIdx[i]?"#ffd33d":
    (reviewFocusActive()&&reviewFocus.partIdx[i]?"#58d6ff":
    ((i===cur||(selRef&&p.ref===selRef))?"#ffffff":(PHYSICAL_REVIEW?PH.silk:(bot?TH.silkBot:TH.silk)))));
   ctx.globalAlpha=wantRef?focusAlpha:0.85*focusAlpha;
   var lc=wpt(i,p.ccx||0,p.ccy||0),rx=X(lc.x),ry=Y(lc.y)-p.hh*S-2/k;
   // (rpx/k) svg units × kk device px per unit = rpx*dpr device px — the label
   // is a fixed screen size, so its sprite outlives every pan at this zoom.
   var rfd=Math.round((rpx/k)*kk*10)/10,rg,shownRef=refLabel(p.ref);
   if(refFd[i]===rfd&&refCol[i]===rcol)rg=refG[i];
   else{rg=glyph("R|"+rfd+"|"+rcol+"|"+shownRef,shownRef,rfd,rcol,null,0,false);
    refG[i]=rg;refFd[i]=rfd;refCol[i]=rcol;}
   if(rg)glyphDraw(ctx,rg,rx,ry,kk);
   else{ctx.font="600 "+(rpx/k).toFixed(2)+"px system-ui,sans-serif";
    ctx.textAlign="center";ctx.textBaseline="alphabetic";
    ctx.fillStyle=rcol;ctx.fillText(shownRef,rx,ry);}
   ctx.globalAlpha=1;}}}
// Footprint silk — F.Silk white / B.Silk pink (KiCad), one cached-Path2D
// stroke per part in the part's own rotated/mirrored frame.
//
// It is its OWN pass, drawn ABOVE the copper, because silkscreen ink is
// physically printed on top of the finished board: on a real PCB a trace never
// runs over the polarity mark or the outline of the part sitting on it. It used
// to be stroked inside paintParts, i.e. under paintTracks, so a route crossing
// a footprint erased that footprint's own artwork — and the WebGPU path already
// disagreed, because everything on this canvas composites ABOVE the GPU
// surface's copper. One pass above copper is what all three renderers now do.
//
// B.Silk paints before F.Silk: the board is seen from the top, so far-side ink
// belongs under near-side ink wherever two footprints overlap in X/Y.
// mov/only follow the drag-cache split exactly like paintParts.
function paintFootprintSilk(ctx,k,mov,only){
 var cull=!cullOff;
 for(var side=1;side>=0;side--){
  for(var i=0;i<P.length;i++){var p=P[i];
   if(mov&&(!!mov[i])!==only)continue;
   var bot=(p.side==="bottom");if((bot?1:0)!==side)continue;
   if(cull&&partCulled(i))continue;
   if(!viewSt.vis[bot?LN.b_silks:LN.f_silks])continue;
   if(PHYSICAL_REVIEW&&(bot?1:0)!==activeLayer)continue;
   var pp=partPath(i);if(!pp.silk)continue;
   // Same alpha ladder paintParts applies to the rest of the footprint: the
   // review-focus fade, then the solid-pour foreign-side fade.
   var a=reviewFocusPartAlpha(i);
   if(!PHYSICAL_REVIEW&&!unplacedSet[p.ref])a*=pourForeignFade(bot);
   if(a<=0)continue;
   ctx.save();
   ctx.globalAlpha=a;
   ctx.translate(X(p.x),Y(p.y));ctx.rotate((p.rot||0)*Math.PI/180);
   if(bot)ctx.scale(-1,1);
   ctx.strokeStyle=PHYSICAL_REVIEW?PH.silk:(bot?TH.silkBot:TH.silk);
   ctx.lineWidth=PHYSICAL_REVIEW?Math.max(0.12*S,1):0.8;ctx.lineCap="round";
   ctx.stroke(pp.silk);
   ctx.lineCap="butt";
   ctx.restore();}}}
// Pad-number labels — drawn AFTER the copper pass (paintTracks) so a trace
// routed over a pad never hides its pin number; the pads paint under the
// tracks in paintParts, the numbers go on top of everything. A thin
// contrasting halo keeps the digit legible over any pad OR trace colour.
// Gating mirrors the old in-paintParts block: not physical review, zoomed
// in enough (k>=1.15 and the glyph >=5.5 screen px), capped at 13 screen px
// so a physically large/custom pad cannot blanket the board, and paused
// during drags/zooms so gestures stay O(movers). mov/only follow the
// drag-cache split like paintParts.
var PAD_LABEL_MIN_PX=5.5,PAD_LABEL_MAX_PX=13;
function paintPadLabels(ctx,k,mov,only){
 if(PHYSICAL_REVIEW||!viewSt.vis.padnum||k<1.15||gestureBusy())return;
 ctx.textAlign="center";ctx.textBaseline="middle";ctx.lineJoin="round";
 var kk=k*(window.devicePixelRatio||1),cull=!cullOff;
 var textCol=netColOn?"#0d1117":"rgba(240,240,244,.96)",
     halo=netColOn?"rgba(240,240,244,.85)":"rgba(0,0,0,.72)",
     sb=netColOn?"P1|":"P0|",lastFont="",lastFs=-1,fd=0,lw=0,pfx="";
 for(var i=0;i<P.length;i++){var p=P[i];
  if(mov&&(!!mov[i])!==only)continue;
  if(!(p.pads||[]).length)continue;
  if(cull&&partCulled(i))continue; // one box test per PART, not per pad
  // Labels belong to the same face copper as their SMD pads. A Front/Back
  // preset must not leave the hidden face's numbers floating over an empty
  // board; drilled pads remain because their copper is visible on both faces.
  var padLayer=p.side==="bottom"?1:0;
  var focusAlpha=reviewFocusPartAlpha(i);if(focusAlpha<=0)continue;
  ctx.globalAlpha=focusAlpha;
  for(var j=0;j<p.pads.length;j++){var pd=p.pads[j];if(!pd.num)continue;
   if(!(pd.drill>0)&&layerAlpha(padLayer)<=0)continue;
   var labelPx=Math.min(PAD_LABEL_MAX_PX,Math.min(pd.w,pd.h)*S*0.55*k);
   if(labelPx<PAD_LABEL_MIN_PX)continue;
   // Convert the clamped CSS-pixel size back to world units for the canvas
   // transform. The glyph cache still stores device pixels through kk.
   var fs=labelPx/k,haloWorld=Math.max(labelPx*0.16,0.7)/k;
   var c=wpt(i,pd.x,pd.y),xx=X(c.x),yy=Y(c.y);
   // Both font and halo are screen-space bounded. Pads overwhelmingly share a
   // size (all 0402s alike), so the key PREFIX is rebuilt only when the size
   // changes — the same trick the old per-frame font set used.
   if(fs!==lastFs){lastFs=fs;fd=Math.round(fs*kk*10)/10;
    lw=Math.round(haloWorld*kk*10)/10;pfx=sb+fd+"|"+lw+"|";}
   var g=glyph(pfx+pd.num,pd.num,fd,textCol,halo,lw,true);
   if(g){glyphDraw(ctx,g,xx,yy,kk);continue;}
   // Fallback (no offscreen canvas): direct raster, font set only on a change.
   var f="600 "+fs.toFixed(1)+"px system-ui,sans-serif";
   if(f!==lastFont){ctx.font=f;lastFont=f;}ctx.lineWidth=haloWorld;
   ctx.strokeStyle=halo;ctx.strokeText(pd.num,xx,yy);
   ctx.fillStyle=textCol;ctx.fillText(pd.num,xx,yy);}}
 ctx.globalAlpha=1;ctx.lineJoin="miter";}
function padPath(ctx,pd){
 ctx.beginPath();
 if(pd.poly&&pd.poly.length>=3){
  ctx.moveTo(pd.poly[0][0]*S,pd.poly[0][1]*S);
  for(var j=1;j<pd.poly.length;j++)ctx.lineTo(pd.poly[j][0]*S,pd.poly[j][1]*S);
  ctx.closePath();return;}
 ctx.save();ctx.translate(pd.x*S,pd.y*S);ctx.rotate((pd.rot||0)*Math.PI/180);
 if(pd.shape==="circle")ctx.arc(0,0,Math.min(pd.w,pd.h)/2*S,0,6.2832);
 else ctx.rect(-pd.w/2*S,-pd.h/2*S,pd.w*S,pd.h*S);
 ctx.restore();}
// Sub-circuit boxes: each ref-prefix group ("buck/…") draws as ONE named
// bounding box, so the board reads as sub-circuits rather than a refdes
// cloud. Solid while rigid (drags as a unit), dashed when exploded; the name
// label above the box stays a constant screen size across zoom. Staged
// (unplaced) members are excluded so the box doesn't stretch to the band.
// Declared outer-layer copper pours ((stackup …)/(pour …) on an outer face,
// PCB.pours from the server): a translucent wash + dashed rim + "NET pour ·
// F.Cu/B.Cu" label UNDER everything, in the layer's track colour (red top /
// blue bottom) — so a poured face reads as copper instead of being invisible.
// An area's cached rimPath traces its outer polygon; its fillPath carries each
// interior hole loop as an extra subpath, so an even-odd fill reads as empty
// where a foreign via/pad/track sits fully inside.
// Copper-pour fill opacity belongs to the editor's layer-inspection view. The
// physical assembly review always uses its fixed, mask-readable copper wash;
// carrying the editor's 100% setting into that view paints solid copper over
// the soldermask and no longer resembles the manufactured board.
// Solid-pour occlusion (same slider). A pour is painted UNDER the parts/tracks,
// so on its own an opaque fill can't hide the far-side footprints / bottom &
// inner traces drawn on top of it. To make a solid pour read like real copper
// hiding the other side of the board, fade that foreign artwork as pourOp climbs
// — fully gone at 100%. The side you're viewing is the active layer's side
// (B.Cu → bottom; F.Cu / inner → top); foreign copper = any non-active layer.
function pourViewBottom(){return focusedSignal()===1;}
function pourForeignFade(isBottom){var t=viewSt.pourOp||0;return (t<=0||isBottom===pourViewBottom())?1:1-t;}
function pourLayerFade(L){var t=viewSt.pourOp||0;return (t<=0||L===focusedSignal())?1:1-t;}
// A PLANE row's fill alpha — the one ladder the 2D painter and the GPU state
// blob both read, so the two can never disagree about a plane. Its eye is the
// gate (plane rows default hidden, exactly the board that shipped before they
// had eyes at all), the VIEWED plane is brightest, and any other visible plane
// still reads — which is what makes two planes comparable at once.
function planeAlpha(st){if(!st||!viewSt.vis[st.name])return 0;
 return st.i===activeStack?0.95:0.30;}
// Pour GEOMETRY cache. X/Y are affine constants and the canvas transform carries
// pan/zoom, so a traced pour is valid at every viewport: each area keeps a
// fillPath (outline + hole subpaths, for the even-odd fill), a rimPath (outline
// alone, for the stroke) and its label anchor, built once instead of per frame.
// Only geometry is cached — colours, alphas, dashes and the label text stay
// per-frame. pourGeomDrop() is the explicit invalidation every pour/zone
// mutation calls; the source arrays' identity+length is the backstop.
var pourGeom=null;
// The single choke point every pour/zone mutation already funnels through — so
// it is also where the GPU's baked pour geometry is invalidated (lazily: the
// rebuild happens on the next frame that actually draws).
function pourGeomDrop(){pourGeom=null;if(gpuOn)PCBGpu.rebuildPours();}
function pourSrcs(){return [PCB.pours,PCB.plane_fills,PCB.zone_fills,PCB.zones,PCB.imported_zones,PCB.importedZones];}
function pourSrcFresh(g){var s=pourSrcs();
 for(var i=0;i<s.length;i++){if(s[i]!==g.src[i]||(s[i]?s[i].length:-1)!==g.len[i])return false;}
 return true;}
function pourGeomBuild(a){var poly=a.poly;if(!poly||poly.length<3)return;
 var rim=new Path2D(),fill=new Path2D(),mnx=poly[0][0],mxy=poly[0][1];
 var x0=X(poly[0][0]),y0=Y(poly[0][1]);rim.moveTo(x0,y0);fill.moveTo(x0,y0);
 for(var i=1;i<poly.length;i++){var px=poly[i][0],py=poly[i][1];
  if(px<mnx)mnx=px;if(py>mxy)mxy=py;
  rim.lineTo(X(px),Y(py));fill.lineTo(X(px),Y(py));}
 rim.closePath();fill.closePath();
 var hs=a.holes||[];
 for(var h=0;h<hs.length;h++){var hp=hs[h];if(!hp||hp.length<3)continue;
  fill.moveTo(X(hp[0][0]),Y(hp[0][1]));
  for(var v=1;v<hp.length;v++)fill.lineTo(X(hp[v][0]),Y(hp[v][1]));
  fill.closePath();}
 a.fillPath=fill;a.rimPath=rim;a.lx=X(mnx);a.ly=Y(mxy);}
function paintPours(ctx,k){
 var ik=1/Math.max(k||1,0.01),seen={};
 if(PHYSICAL_REVIEW){var netFocus=reviewFocusHasNets();reviewCopperAreas().forEach(function(aq){var q=aq.q,poly=aq.poly;
   // The fab-preview shows real copper only: a zone's solid area is painted by
   // its "pour" fill entry (PCB.zone_fills), never its raw boundary polygon.
   if(q.keepout||!poly||poly.length<3||aq.kind==="zone")return;
   var hit=reviewFocusNet(q.net),L=reviewAreaLayer(q);if(L!==activeLayer&&!hit)return;
   ctx.globalAlpha=netFocus?(hit?0.62:0.05):0.20;
   ctx.fillStyle=hit?"#58d6ff":PH.copperUnder;
   // Use the cached outline + antipad-hole path, just like the editor view.
   // Filling only the outer polygon floods clearances around foreign copper.
   ctx.fill(aq.fillPath,"evenodd");ctx.globalAlpha=1;});
  paintFocusedPlanes(ctx,k);return;}
 paintFocusedPlanes(ctx,k);
 reviewCopperAreas().forEach(function(aq){var q=aq.q,poly=aq.poly;
  if(!poly||poly.length<3)return;
  var hit=!q.keepout&&reviewFocusNet(q.net);
  var L=reviewAreaLayer(q),st=reviewAreaStack(q),planeOnly=st&&st.l==null,top=L===0,inner=(L!=null&&L>=2),
      a=planeOnly?planeAlpha(st):(L==null?0.55:layerAlpha(L));
  if(hit)a=Math.max(a,0.9);if(a<=0)return;
  if(reviewFocusActive())a*=hit?1:0.12;
  ctx.globalAlpha=a;
  // A raw PCB.zones polygon (kind "zone") is only ever the dashed boundary — the
  // solid copper is painted by its "pour" fill entry (declared pours + user
  // PCB.zone_fills). Keepouts keep their own hatched-fill treatment below.
  // An inner-layer pour (signal index ≥2, resolved from its In-layer name) paints
  // in that layer's hue via layerRgba; the outer faces keep their red/blue washes.
  var boundary=aq.kind==="zone"&&!q.keepout;
  // GPU frame: the pour FILLS are on the WebGPU canvas below (stencil-invert +
  // cover, the exact even-odd rule this fill uses), painted under the copper
  // instead of over it. Keepout washes, every rim, every dash and every label
  // stay here — and so does the whole ladder below, which gpuPourAlphas()
  // re-reads to hand the renderer one resolved alpha per area.
  if(!boundary){
   if(q.keepout){ctx.fillStyle="rgba(139,148,158,0.05)";ctx.fill(aq.fillPath,"evenodd");}
   else if(!gpuOwns("plane_fills")){
    // Pour-opacity slider (viewSt.pourOp). ONLY the layer you're looking at (the
    // active or selected layer) responds: its fill climbs from the faint default
    // (layer-emphasis a × the per-face base wash) to FULLY opaque — solid copper,
    // nothing showing through — at 100%. Foreign layers stay at their faint
    // contextual level so they never tint the solid top pour or fight it over
    // draw order. globalAlpha is forced to 1 for the fill so `a` no longer caps
    // it (it still governs the rim/label below).
    // User-drawn fills on the selected layer are the layer's primary artwork,
    // not a faint board-context wash. Barracuda's dense top-side placement can
    // otherwise bury its In2.Cu rail pours even though their fills are valid.
    // Keep declared pours and foreign custom pours at their existing contextual
    // opacity; the slider still ramps every selected fill up to solid copper.
    var activeUserFill=reviewAreaFocused(q)&&typeof q.zone==="number";
    var baseA=hit?0.30:(activeUserFill?0.36:(top?0.10:0.12)),baseEff=a*baseA;
    var effA=(hit||reviewAreaFocused(q))?Math.min(1,baseEff+(1-baseEff)*(viewSt.pourOp||0)):baseEff;
    ctx.globalAlpha=1;
    ctx.fillStyle=hit?"rgba(88,214,255,"+effA+")":(st?stackRgba(st,effA):(inner?layerRgba(L,effA):hexRgba(top?TH.padTop:TH.padBot,effA)));
    ctx.fill(aq.fillPath,"evenodd");ctx.globalAlpha=a;}}
  ctx.strokeStyle=q.keepout?"rgba(139,148,158,0.55)":(hit?"#8be9ff":
   (st?stackRgba(st,0.5):(inner?layerRgba(L,0.5):hexRgba(top?TH.padTop:TH.padBot,top?0.45:0.5))));
  ctx.lineWidth=hit?2:1;ctx.setLineDash(q.keepout?[2,3]:(boundary?[9,4]:[5,4]));ctx.stroke(aq.rimPath);ctx.setLineDash([]);
  var sk=(L==null?String(q.layers||q.layer||"zone"):String(L));
  if(!seen[sk]){seen[sk]=1;
   ctx.font="600 "+(11*ik).toFixed(2)+"px system-ui,sans-serif";
   ctx.textAlign="left";ctx.textBaseline="alphabetic";
   ctx.fillStyle=hit?"#8be9ff":(q.keepout?"rgba(180,185,190,0.8)":
    (st?stackRgba(st,0.9):(inner?layerRgba(L,0.9):(top?"rgba(220,90,90,0.9)":"rgba(110,155,215,0.9)"))));
   var ln=reviewAreaLayerName(q,L);
   ctx.fillText((q.keepout?"keepout":((q.net||"unassigned")+" "+(boundary?"zone boundary":aq.kind)))+" · "+ln,
    aq.lx+5*ik,aq.ly-5*ik);}
  ctx.globalAlpha=1;});}
// Generic Keepouts overlay. Fixed regions arrive in PCB.keepouts with their
// blocked feature families; net-class halos are derived from the active-layer
// copper below. Both share one toggle and one deliberately uniform paint pass.
// The RF mask is composed offscreen as opaque geometry and punched back out by
// its owning copper before being alpha-blended, so overlaps never stack into
// the dark/lumpy blobs the old per-pad translucent strokes produced.
function rfKeepoutWidth(c){return c?Math.max(0,+c.keepout_mm||0,+c.rf_corridor_mm||0):0;}
function rfKeepoutRule(net){var c=netClassInfo(net||"");return rfKeepoutWidth(c)>0?c:null;}
function rfKeepoutPadActive(p,pd){var L=focusedSignal();return L!=null&&(pd.thru||pd.drill>0||(p.side==="bottom"?1:0)===L);}
function keepoutExemptNet(net){var n=netCollapse(net||""),leaf=n.slice(n.lastIndexOf("/")+1).toUpperCase();
 var key=n.toUpperCase();if(PCB.implicit_rail&&netCollapse(PCB.implicit_rail).toUpperCase()===key)return true;
 if((PCB.plane_nets||[]).some(function(p){return netCollapse(p).toUpperCase()===key;}))return true;
 return isGroundNetName(leaf);}
// The ground-name test, structurally identical to the server's
// `placement/optimizer.isGroundName`: a token from PCB.ground_names
// (`eval/net_analysis.ground_tokens`, longest-first so GNDA is not
// shadowed by GND), bare or with an all-digit suffix after an optional
// single separator — so a real signal like GND_SENSE stays a signal. The
// token list is carried in the blob rather than respelled here, because a
// browser that disagrees with the server about what is ground exempts the
// wrong copper from the RF keepout.
function isGroundNetName(leaf){var t=(PCB&&PCB.ground_names)||[];
 for(var i=0;i<t.length;i++){if(leaf.slice(0,t[i].length)!==t[i])continue;
  var rest=leaf.slice(t[i].length);if(rest==="")return true;
  if(rest[0]==="_"||rest[0]==="-")rest=rest.slice(1);
  return rest!==""&&/^\d+$/.test(rest);}
 return false;}
// Retained net-class halo geometry. Barracuda has hundreds of RF copper
// primitives; painting every one twice (outer mask, then own-copper punch)
// made a keepouts-on frame issue hundreds of separate raster calls. Paths are
// now grouped by stroke width exactly like the normal copper batch, and the
// composed transparent bitmap is retained until geometry/view state changes.
var keepoutBatch=null,keepoutBatchSeq=0,keepoutMaskCv=null,keepoutMaskKey="";
var keepoutOverlayCv=null,keepoutOverlayCache=null;
function keepoutStrokeBucket(list,w){for(var i=0;i<list.length;i++)if(list[i].w===w)return list[i];
 var b={w:w,p:new Path2D()};list.push(b);return b;}
function keepoutCircle(path,x,y,r){path.moveTo(x+r,y);path.arc(x,y,r,0,6.2832);}
function keepoutPartPoint(p,lx,ly){var a=(p.rot||0)*Math.PI/180,c=Math.cos(a),s=Math.sin(a);
 if(p.side==="bottom")lx=-lx;
 return {x:X(p.x+lx*c-ly*s),y:Y(p.y+lx*s+ly*c)};}
// Build one pad outline directly in world SVG units. Part rotation/mirroring
// wraps the pad's own translation/rotation; custom polygons already carry
// footprint-local points. Shared by every exact pad-outline halo painter.
function worldPadPath(p,pd){var path=new Path2D(),q;
 if(pd.poly&&pd.poly.length>=3){q=keepoutPartPoint(p,pd.poly[0][0],pd.poly[0][1]);path.moveTo(q.x,q.y);
  for(var j=1;j<pd.poly.length;j++){q=keepoutPartPoint(p,pd.poly[j][0],pd.poly[j][1]);path.lineTo(q.x,q.y);}
  path.closePath();return path;}
 var pc=keepoutPartPoint(p,pd.x,pd.y);
 if(pd.shape==="circle"){keepoutCircle(path,pc.x,pc.y,Math.min(pd.w,pd.h)*S/2);return path;}
 var a=(pd.rot||0)*Math.PI/180,c=Math.cos(a),s=Math.sin(a),hw=pd.w/2,hh=pd.h/2;
 [[-hw,-hh],[hw,-hh],[hw,hh],[-hw,hh]].forEach(function(v,i){
  var lx=pd.x+v[0]*c-v[1]*s,ly=pd.y+v[0]*s+v[1]*c,pt=keepoutPartPoint(p,lx,ly);
  if(i)path.lineTo(pt.x,pt.y);else path.moveTo(pt.x,pt.y);});path.closePath();return path;}
function keepoutBatchGet(){var ts=PCB.tracks||[],vs=PCB.vias||[],nc=ncIndex(),focus=focusedSignal();
 if(keepoutBatch&&keepoutBatch.rev===keepoutGeomRev&&keepoutBatch.ts===ts&&keepoutBatch.tn===ts.length
  &&keepoutBatch.vs===vs&&keepoutBatch.vn===vs.length&&keepoutBatch.nc===nc&&keepoutBatch.l===focus)return keepoutBatch;
 var ot=[],it=[],op=[],of=new Path2D(),inf=new Path2D(),any=false;
 if(focus==null){keepoutBatch={id:++keepoutBatchSeq,rev:keepoutGeomRev,ts:ts,tn:ts.length,vs:vs,vn:vs.length,nc:nc,l:focus,
  any:false,ot:ot,it:it,op:op,of:of,inf:inf};return keepoutBatch;}
 ts.forEach(function(t){if((t.l||0)!==focus)return;if(keepoutExemptNet(t.net)){
   var xe=keepoutStrokeBucket(it,(t.w||0.25)*S).p;trackPath(xe,t);return;}
  var c=rfKeepoutRule(t.net);if(!c)return;any=true;
  var po=keepoutStrokeBucket(ot,((t.w||0.25)+2*rfKeepoutWidth(c))*S).p;
  trackPath(po,t);
  var pi=keepoutStrokeBucket(it,(t.w||0.25)*S).p;trackPath(pi,t);});
 vs.forEach(function(v){if(keepoutExemptNet(v.net)){keepoutCircle(inf,X(v.x),Y(v.y),(v.d||0.4)*S/2);return;}
  var c=rfKeepoutRule(v.net);if(!c)return;any=true;
  keepoutCircle(of,X(v.x),Y(v.y),((v.d||0.4)/2+rfKeepoutWidth(c))*S);
  keepoutCircle(inf,X(v.x),Y(v.y),(v.d||0.4)*S/2);});
 P.forEach(function(p){(p.pads||[]).forEach(function(pd){if(!rfKeepoutPadActive(p,pd))return;
  if(keepoutExemptNet(pd.net)){inf.addPath(worldPadPath(p,pd));return;}var c=rfKeepoutRule(pd.net);
  if(!c||pd.npth)return;any=true;
  var shape=worldPadPath(p,pd);of.addPath(shape);inf.addPath(shape);
  keepoutStrokeBucket(op,2*rfKeepoutWidth(c)*S).p.addPath(shape);});});
 keepoutBatch={id:++keepoutBatchSeq,rev:keepoutGeomRev,ts:ts,tn:ts.length,vs:vs,vn:vs.length,nc:nc,l:focus,
  any:any,ot:ot,it:it,op:op,of:of,inf:inf};return keepoutBatch;}
function keepoutTransformKey(tr){return [tr.a,tr.b,tr.c,tr.d,tr.e,tr.f].join(",");}
function paintNetKeepouts(ctx,b){if(!b||!b.any)return;
 var target=ctx.canvas,cv=keepoutMaskCv;if(!cv)cv=keepoutMaskCv=document.createElement("canvas");
 if(cv.width!==target.width){cv.width=target.width;keepoutMaskKey="";}
 if(cv.height!==target.height){cv.height=target.height;keepoutMaskKey="";}
 var tr=ctx.getTransform(),key=cv.width+"|"+cv.height+"|"+b.id+"|"+keepoutTransformKey(tr);
 if(keepoutMaskKey!==key){var mc=cv.getContext("2d");mc.setTransform(1,0,0,1,0,0);mc.clearRect(0,0,cv.width,cv.height);
  mc.setTransform(tr);mc.lineCap="round";mc.lineJoin="round";
  mc.strokeStyle="#f59e0b";mc.fillStyle="#f59e0b";mc.globalCompositeOperation="source-over";
  for(var oi=0;oi<b.ot.length;oi++){mc.lineWidth=b.ot[oi].w;mc.stroke(b.ot[oi].p);}
  mc.fill(b.of);for(var pi=0;pi<b.op.length;pi++){mc.lineWidth=b.op[pi].w;mc.stroke(b.op[pi].p);}
  // Subtract the keepout class's own copper, leaving only the actual forbidden band.
  mc.globalCompositeOperation="destination-out";mc.strokeStyle="#000";mc.fillStyle="#000";
  for(var ii=0;ii<b.it.length;ii++){mc.lineWidth=b.it[ii].w;mc.stroke(b.it[ii].p);}mc.fill(b.inf);
  mc.globalCompositeOperation="source-over";keepoutMaskKey=key;}
 ctx.save();ctx.setTransform(1,0,0,1,0,0);ctx.globalAlpha=0.19;ctx.drawImage(cv,0,0);ctx.restore();}
// ── Solder-mask relief (assembly view) ──────────────────────────────────
// PCB.mask_relief carries only the SERVED opening geometry of the shown
// copper — exposure runs merged across joints and widened over fence rows.
// Vias never carry mask state: the compositor clips every copper primitive,
// including via rings, through these polygons exactly as the Gerber does.
// Bare-copper trace relief, composed offscreen exactly like the fab geometry:
// opening outlines first, then actual copper clipped through them. The shared
// mask-relief solver has already stopped every terminal one web before its pad;
// subtracting the pad dam again here would square off the authored fillet.
var reliefCv=null,reliefKey="";
function reliefOutlinePath(ctx,o){var pts=o&&o.p||[];if(pts.length<3)return false;
 ctx.beginPath();ctx.moveTo(X(pts[0][0]),Y(pts[0][1]));
 for(var i=1;i<pts.length;i++)ctx.lineTo(X(pts[i][0]),Y(pts[i][1]));ctx.closePath();return true;}
function reliefPoint(s,u,v){var dx=s.x2-s.x1,dy=s.y2-s.y1,n=Math.hypot(dx,dy)||1,ux=dx/n,uy=dy/n;
 return [s.x1+ux*u-uy*v,s.y1+uy*u+ux*v];}
function reliefPathPoint(p,ctx,first){if(first)ctx.moveTo(X(p[0]),Y(p[1]));else ctx.lineTo(X(p[0]),Y(p[1]));}
function reliefPathArc(ctx,s,cx,cy,r,a0,a1,n){for(var i=1;i<=n;i++){var a=a0+(a1-a0)*i/n;
 reliefPathPoint(reliefPoint(s,cx+r*Math.cos(a),cy+r*Math.sin(a)),ctx,false);}}
// A pad-dam-clipped endpoint is a flat end with inward fillets. Ordinary
// copper endpoints retain the historical semicircular cap. This is the same
// compact stroke description placement/mask_relief hands the Gerber writer.
function reliefOpeningPath(ctx,s){var len=Math.hypot(s.x2-s.x1,s.y2-s.y1),h=s.w/2;if(!(len>0&&h>0))return false;
 var lim=s.ts&&s.te?len/2:len,req=Math.max(0,+s.r||0),rs=s.ts?Math.min(req,h,lim):h,re=s.te?Math.min(req,h,lim):h;
 ctx.beginPath();reliefPathPoint(reliefPoint(s,s.ts?rs:0,h),ctx,true);
 reliefPathPoint(reliefPoint(s,s.te?len-re:len,h),ctx,false);
 if(s.te){if(re>0)reliefPathArc(ctx,s,len-re,h-re,re,Math.PI/2,0,6);
  reliefPathPoint(reliefPoint(s,len,-h+re),ctx,false);if(re>0)reliefPathArc(ctx,s,len-re,-h+re,re,0,-Math.PI/2,6);}
 else reliefPathArc(ctx,s,len,0,h,Math.PI/2,-Math.PI/2,12);
 reliefPathPoint(reliefPoint(s,s.ts?rs:0,-h),ctx,false);
 if(s.ts){if(rs>0)reliefPathArc(ctx,s,rs,-h+rs,rs,-Math.PI/2,-Math.PI,6);
  reliefPathPoint(reliefPoint(s,0,h-rs),ctx,false);if(rs>0)reliefPathArc(ctx,s,rs,h-rs,rs,Math.PI,Math.PI/2,6);}
 else reliefPathArc(ctx,s,0,0,h,-Math.PI/2,-3*Math.PI/2,12);
 ctx.closePath();return true;}
// Remove the overlapping round caps of short route chords at one terminal,
// then repaint a single fillet whose radius is independent of chord length.
function reliefTerminalFinish(ctx,s,atStart,clear){if(!(atStart?s.ts:s.te))return;var dx=s.x2-s.x1,dy=s.y2-s.y1,len=Math.hypot(dx,dy),h=s.w/2;if(!(len>0&&h>0))return;
 var sign=atStart?1:-1,ux=sign*dx/len,uy=sign*dy/len,tx=atStart?s.x1:s.x2,ty=atStart?s.y1:s.y2,r=Math.min(Math.max(0,+s.r||0),h);
 function p(u,v,first){reliefPathPoint([tx+ux*u-uy*v,ty+uy*u+ux*v],ctx,first);}
 ctx.beginPath();if(clear){p(-h,h,true);p(r,h);p(r,-h);p(-h,-h);ctx.closePath();ctx.fill();return;}if(!(r>0))return;
 p(r,h,true);p(r,-h);for(var i=1;i<=6;i++){var a=-Math.PI/2-Math.PI*i/12;p(r+r*Math.cos(a),-h+r+r*Math.sin(a));}
 p(0,h-r);for(var j=1;j<=6;j++){var b=Math.PI-Math.PI*j/12;p(r+r*Math.cos(b),h-r+r*Math.sin(b));}ctx.closePath();ctx.fill();}
// A merge stroke ends inside both pad apertures, so its compositor must reveal
// the real lands under those ends. Kept outside paintMaskRelief deliberately:
// the RF terminal path itself still never subtracts/repaints a square pad dam.
function paintMaskMergePads(ctx,L){P.forEach(function(p){(p.pads||[]).forEach(function(pd){
 if(pd.npth||!(pd.thru||pd.drill>0||(p.side==="bottom"?1:0)===L))return;
 ctx.fill(worldPadPath(p,pd));});});}
function paintMaskRelief(ctx){if(!PHYSICAL_REVIEW||reviewFocusHasNets())return;
 var d=PCB.mask_relief,os=d&&d.openings||[],ss=d&&d.strokes||[],js=d&&d.joints||[],ms=PCB.mask_merges||[],L=activeLayer,
  mw=Number(PCB.rules&&PCB.rules.perimeter_mask_width)||0,any=mw>0,layerHasOutline=false;
 for(var oi=0;oi<os.length;oi++){if((os[oi].l||0)===L){any=true;layerHasOutline=true;break;}}
 if(!any)for(var i=0;i<ss.length;i++){if((ss[i].l||0)===L){any=true;break;}}
 if(!any)for(var j=0;j<js.length;j++){if((js[j].l||0)===L){any=true;break;}}
 if(!any)for(var mi=0;mi<ms.length;mi++){if((ms[mi].l||0)===L){any=true;break;}}
 if(!any)return;
 var target=ctx.canvas,cv=reliefCv;if(!cv)cv=reliefCv=document.createElement("canvas");
 if(cv.width!==target.width||cv.height!==target.height){cv.width=target.width;cv.height=target.height;reliefKey="";}
  var tr=ctx.getTransform(),corner=PCB.rules&&PCB.rules.mask_relief_corner_radius||0,
  key=[cv.width,cv.height,L,os.length,ss.length,js.length,ms.length,(PCB.vias||[]).length,mw,corner,keepoutGeomRev,keepoutTransformKey(tr)].join("|");
 if(reliefKey!==key){var mc=cv.getContext("2d");mc.setTransform(1,0,0,1,0,0);mc.clearRect(0,0,cv.width,cv.height);
  mc.setTransform(tr);mc.lineCap="round";mc.lineJoin="round";
  // Removing mask reveals substrate first. Repaint every real copper shape
  // through that opening below; in particular a GND pour remains copper-gold
  // instead of being replaced by the old amber opening silhouette.
  mc.strokeStyle=PH.substrate;mc.fillStyle=PH.substrate;
  if(mw>0){mc.save();physicalBoardPath(mc);mc.clip();physicalBoardPath(mc);
   mc.strokeStyle=PH.substrate;mc.lineWidth=2*mw*S;mc.lineJoin="round";mc.stroke();mc.restore();}
  if(layerHasOutline)os.forEach(function(o){if((o.l||0)!==L)return;if(reliefOutlinePath(mc,o))mc.fill();});
  else{
   ss.forEach(function(s){if((s.l||0)!==L)return;
    if(s.ts||s.te){if(reliefOpeningPath(mc,s))mc.fill();return;}
    mc.lineWidth=s.w*S;mc.beginPath();mc.moveTo(X(s.x1),Y(s.y1));mc.lineTo(X(s.x2),Y(s.y2));mc.stroke();});
   js.forEach(function(j){if((j.l||0)!==L)return;mc.beginPath();mc.arc(X(j.x),Y(j.y),j.d*S/2,0,6.2832);mc.fill();});
   mc.globalCompositeOperation="destination-out";mc.fillStyle="#000";
   ss.forEach(function(s){if((s.l||0)!==L)return;reliefTerminalFinish(mc,s,true,true);reliefTerminalFinish(mc,s,false,true);});
   mc.globalCompositeOperation="source-over";mc.fillStyle=PH.substrate;
   ss.forEach(function(s){if((s.l||0)!==L)return;reliefTerminalFinish(mc,s,true,false);reliefTerminalFinish(mc,s,false,false);});}
  // Automatic DFM pass: a positive web below mask-web is removed by this
  // exact Gerber stroke. It belongs in the same substrate/copper compositor as
  // RF relief, because the gap between two pads may expose bare substrate.
  mc.strokeStyle=PH.substrate;mc.lineCap="round";
  ms.forEach(function(m){if((m.l||0)!==L)return;mc.lineWidth=m.w*S;mc.beginPath();
   mc.moveTo(X(m.x1),Y(m.y1));mc.lineTo(X(m.x2),Y(m.y2));mc.stroke();});
  mc.globalCompositeOperation="source-atop";mc.fillStyle=PH.copper;mc.strokeStyle=PH.copper;
  reviewCopperAreas().forEach(function(aq){var q=aq.q;if(q.keepout||aq.kind==="zone"||reviewAreaLayer(q)!==L)return;mc.fill(aq.fillPath,"evenodd");});
  rfPathGeom().forEach(function(rf){if(rf.l===L)mc.fill(rf.path);});
  (PCB.tracks||[]).forEach(function(t){if((t.l||0)!==L)return;mc.lineWidth=Math.max(t.w*S,1.2);
   mc.beginPath();trackPath(mc,t);mc.stroke();});
  // Merge strokes terminate inside the two pad apertures. Repaint the actual
  // pad lands through those openings just like pours/tracks/vias below them.
  paintMaskMergePads(mc,L);
  // Via copper has no mask flag or aperture. Paint every ring, then let the
  // existing source-atop operation retain only the pixels under an opening.
  (PCB.vias||[]).forEach(function(v){var rr=viaRenderRadius(v.d);
   mc.beginPath();mc.arc(X(v.x),Y(v.y),rr,0,6.2832);mc.fill();});
  mc.globalCompositeOperation="destination-out";
  (PCB.vias||[]).forEach(function(v){var dr=(v.drill>0)?v.drill:viaGeo().drill,
   rh=viaRenderRadius(dr);mc.beginPath();mc.arc(X(v.x),Y(v.y),rh,0,6.2832);mc.fill();});
  mc.globalCompositeOperation="source-over";reliefKey=key;}
 // Blend OPAQUE: the track pass above leaves globalAlpha at the under-mask
 // fade (0.32, or 0 after a hidden layer), which would ghost the bare copper.
 ctx.save();ctx.setTransform(1,0,0,1,0,0);ctx.globalAlpha=1;ctx.drawImage(cv,0,0);ctx.restore();}
function keepoutPolyPath(ctx,pts){if(!pts||pts.length<3)return false;ctx.moveTo(X(pts[0][0]),Y(pts[0][1]));
 for(var i=1;i<pts.length;i++)ctx.lineTo(X(pts[i][0]),Y(pts[i][1]));ctx.closePath();return true;}
function paintFixedKeepouts(ctx,k){(PCB.keepouts||[]).forEach(function(q){if(!q.outer||!q.inner)return;
  ctx.save();ctx.beginPath();if(!keepoutPolyPath(ctx,q.outer)||!keepoutPolyPath(ctx,q.inner)){ctx.restore();return;}
  ctx.fillStyle="rgba(168,85,247,0.14)";ctx.fill("evenodd");ctx.clip("evenodd");
  var xs=q.outer.map(function(p){return X(p[0]);}),ys=q.outer.map(function(p){return Y(p[1]);});
  var x0=Math.min.apply(null,xs),x1=Math.max.apply(null,xs),y0=Math.min.apply(null,ys),y1=Math.max.apply(null,ys);
  var step=8/Math.max(k||1,0.01);ctx.strokeStyle="rgba(196,143,255,0.38)";ctx.lineWidth=Math.max(0.8/Math.max(k||1,0.01),0.03*S);
  ctx.beginPath();for(var d=x0-y1;d<x1-y0;d+=step){ctx.moveTo(d+y0,y0);ctx.lineTo(d+y1,y1);}ctx.stroke();ctx.restore();});}
function paintKeepouts(ctx,k){if(PHYSICAL_REVIEW||!viewSt.vis.keepouts)return;
 var target=ctx.canvas,b=keepoutBatchGet(),tr=ctx.getTransform(),fixed=PCB.keepouts||[],c=keepoutOverlayCache;
 var hit=c&&c.w===target.width&&c.h===target.height&&c.k===k&&c.bid===b.id&&c.fixed===fixed&&c.fn===fixed.length
  &&c.tr===keepoutTransformKey(tr);
 if(!hit){var cv=keepoutOverlayCv;if(!cv)cv=keepoutOverlayCv=document.createElement("canvas");
  if(cv.width!==target.width)cv.width=target.width;if(cv.height!==target.height)cv.height=target.height;
  var oc=cv.getContext("2d",{alpha:true});oc.setTransform(1,0,0,1,0,0);oc.clearRect(0,0,cv.width,cv.height);
  oc.setTransform(tr);paintFixedKeepouts(oc,k);paintNetKeepouts(oc,b);
  keepoutOverlayCache={w:target.width,h:target.height,k:k,bid:b.id,fixed:fixed,fn:fixed.length,tr:keepoutTransformKey(tr)};}
 ctx.save();ctx.setTransform(1,0,0,1,0,0);ctx.globalAlpha=1;ctx.globalCompositeOperation="source-over";
 ctx.drawImage(keepoutOverlayCv,0,0);ctx.restore();}
// movG/only: drag-cache split — a group box is dynamic when any member moves
// (its bounding box follows the drag).
function partOnVisibleFace(p){return layerAlpha(p&&p.side==="bottom"?1:0)>0;}
function visiblePartIdxs(idxs){return (idxs||[]).filter(function(i){return P[i]&&partOnVisibleFace(P[i]);});}
function paintGroupBoxes(ctx,k,movG,only){
 if(PHYSICAL_REVIEW&&(!reviewFocusActive()||!reviewFocusGroups()))return;
 var ik=1/Math.max(k,0.01);
 for(var g in GRPS){var idxs=GRPS[g];if(idxs.length<2)continue;
  if(movG&&(!!movG[g])!==only)continue;
  var x0=1/0,y0=1/0,x1=-1/0,y1=-1/0,n=0;
  idxs.forEach(function(i){var p=P[i];if(unplacedSet[p.ref]||!partOnVisibleFace(p))return;
   var a=(p.rot||0)*Math.PI/180,ca=Math.abs(Math.cos(a)),sa=Math.abs(Math.sin(a));
   var ehw=(p.hw*ca+p.hh*sa)*S,ehh=(p.hw*sa+p.hh*ca)*S;
   var cc=wpt(i,p.ccx||0,p.ccy||0);
   x0=Math.min(x0,X(cc.x)-ehw);x1=Math.max(x1,X(cc.x)+ehw);
   y0=Math.min(y0,Y(cc.y)-ehh);y1=Math.max(y1,Y(cc.y)+ehh);n++;});
  if(!n)continue;
  var fg=reviewFocusActive()&&idxs.some(function(i){return !!reviewFocus.partIdx[i];});
  if(reviewFocusActive())ctx.globalAlpha=fg?0.9:0.1;
  var pd=3;x0-=pd;y0-=pd;x1+=pd;y1+=pd;
  var picked=(selGroup===g),hov=(hoverGrpName===g);
  ctx.strokeStyle=(picked||hov)?"#7ee787":"rgba(126,231,135,0.4)";
  ctx.lineWidth=picked?2.2:(hov?1.6:1);
  ctx.setLineDash(grpRigid(g)?[]:[5,4]);
  ctx.strokeRect(x0,y0,x1-x0,y1-y0);
  ctx.setLineDash([]);
  ctx.font="600 "+(11*ik).toFixed(2)+"px system-ui,sans-serif";
  ctx.textAlign="left";ctx.textBaseline="alphabetic";
  ctx.fillStyle=(picked||hov)?"#7ee787":"rgba(126,231,135,0.8)";
  ctx.fillText(g,x0,y0-4*ik);ctx.globalAlpha=1;}}
// With both pads picked, preview the two exact alignment results: the X ghost
// sits at (target.x, source.y), the Y ghost at (source.x, target.y). Their
// guide legs show whether the resulting RF run will be vertical or horizontal.
function paintPadAlign(ctx,k){if(!padAlignMode||!padAlignA)return;
 var a=wpt(padAlignA.i,padAlignA.pd.x,padAlignA.pd.y),ik=1/Math.max(k,0.01);
 ctx.save();ctx.lineWidth=1.5*ik;ctx.setLineDash([5*ik,4*ik]);
 ctx.strokeStyle="#e3b341";ctx.beginPath();ctx.arc(X(a.x),Y(a.y),6*ik,0,6.2832);ctx.stroke();
 if(padAlignB){var b=wpt(padAlignB.i,padAlignB.pd.x,padAlignB.pd.y),gx={x:b.x,y:a.y},gy={x:a.x,y:b.y};
  ctx.strokeStyle="rgba(126,231,135,.8)";
  ctx.beginPath();ctx.moveTo(X(gx.x),Y(gx.y));ctx.lineTo(X(b.x),Y(b.y));
  ctx.moveTo(X(gy.x),Y(gy.y));ctx.lineTo(X(b.x),Y(b.y));ctx.stroke();
  ctx.setLineDash([]);ctx.font="700 "+(10*ik)+"px system-ui,sans-serif";ctx.textAlign="center";ctx.textBaseline="middle";
  [[gx,"X"],[gy,"Y"]].forEach(function(q){ctx.fillStyle=TH.bg;ctx.strokeStyle="#7ee787";ctx.lineWidth=1.4*ik;
   ctx.beginPath();ctx.arc(X(q[0].x),Y(q[0].y),7*ik,0,6.2832);ctx.fill();ctx.stroke();
   ctx.fillStyle="#7ee787";ctx.fillText(q[1],X(q[0].x),Y(q[0].y));});}
 ctx.restore();}
// ── Unplaced (auto-staged) parts: the ones a (placement …) spec didn't list.
//    The optimizer drops them into a staging band; flag each one red and draw
//    a dashed red box around the cluster so a gap in the spec is obvious.
var unplacedSet={};
function markUnplaced(refs){
 // Remember each part's STAGED pose: refreshUnplaced treats any later move
 // (by whatever path — drag, group drag, nudge, align, Stamp) as "placed".
 unplacedSet={};if(refs&&refs.length){var at={};P.forEach(function(p){at[p.ref]=p;});
  refs.forEach(function(r){var p=at[r];unplacedSet[r]=p?{x:p.x,y:p.y}:{x:0,y:0};});}
 refreshUnplaced();paintSoon();}
function anyUnplaced(){for(var k in unplacedSet)return true;return false;}
function refreshUnplaced(){
 // Self-maintaining: a part the user moved off its staged pose counts as
 // placed and drops out, so the idle-autosave gate lifts the moment the last
 // one is dealt with.
 var scrub=false;for(var k0 in unplacedSet){scrub=true;break;}
 if(scrub){var at2={};P.forEach(function(p){at2[p.ref]=p;});
  for(var r2 in unplacedSet){var pp=at2[r2],st=unplacedSet[r2];
   if(!pp||Math.abs(pp.x-st.x)>1e-6||Math.abs(pp.y-st.y)>1e-6)delete unplacedSet[r2];}}
 // Nothing staged and nothing drawn — the common case — costs nothing.
 var have=false;for(var k in unplacedSet){have=true;break;}
 if(!have&&!gU.firstChild)return;
 while(gU.firstChild)gU.removeChild(gU.firstChild);
 var n=0,x0=1e9,y0=1e9,x1=-1e9,y1=-1e9;
 P.forEach(function(p,i){if(!unplacedSet[p.ref])return;n++;
  var a=(p.rot||0)*Math.PI/180,ca=Math.abs(Math.cos(a)),sa=Math.abs(Math.sin(a));
  var sw=p.hw*ca+p.hh*sa,sh=p.hw*sa+p.hh*ca;
  var cx=X(p.x),cy=Y(p.y),hw=sw*S,hh=sh*S;
  if(cx-hw<x0)x0=cx-hw;if(cy-hh<y0)y0=cy-hh;if(cx+hw>x1)x1=cx+hw;if(cy+hh>y1)y1=cy+hh;});
 if(n===0)return;
 var pad=10;x0-=pad;y0-=pad;x1+=pad;y1+=pad;
 gU.appendChild(el("rect",{"class":"unplaced-box",x:x0.toFixed(1),y:y0.toFixed(1),
  width:(x1-x0).toFixed(1),height:(y1-y0).toFixed(1),rx:4}));
 var ly=(y0-5<12)?(y0+15):(y0-5);
 var lbl=el("text",{"class":"unplaced-lbl",x:(x0+6).toFixed(1),y:ly.toFixed(1)});
 lbl.textContent="⚠ "+n+" unplaced part"+(n==1?"":"s")+" — drag to place";
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
// Electrical ratsnest: KiCad's thin SOLID white at ~35% alpha when enabled;
// Net-colours restores per-net-coloured airwires. These disappear
// once real copper connects their pads. Placement-intent proximity links are a
// separate guide layer: they remain visible after routing because
// they answer "where should this passive sit?", not "is this net connected?".
// mov/only: drag-cache split — a link is dynamic when EITHER endpoint moves.
function paintLinks(ctx,mov,only,guidesOnly){
 if(PHYSICAL_REVIEW)return; // airwires and placement guides are not fabricated artwork
 var showRats=ratsOn&&viewSt.vis.rats,showGuides=!!viewSt.vis.guides;
 if(!showRats&&!showGuides)return;
 if(linksDirty&&!dragIdxSet())linksRecompute();
 (PCB.links||[]).forEach(function(l){
  var guide=l.k==="proximity";
  if(guidesOnly&&!guide)return;   // exclusive replay view: keep placement guides, drop airwires/ratsnest
  if(guide?!showGuides:(!showRats||l.done))return;
  if(mov&&(!!(mov[l.a]||mov[l.b]))!==only)return;
  var focusHit=reviewFocusActive()&&(reviewFocusNet(l.net)||reviewFocus.refIdx[l.a]||reviewFocus.refIdx[l.b]);
  var a=wpt(l.a,l.ax,l.ay),b=wpt(l.b,l.bx,l.by);
  if(focusHit){ctx.strokeStyle="#8be9ff";ctx.globalAlpha=0.95;ctx.lineWidth=1.7;}
  else if(netColOn){ctx.strokeStyle=linkCol(l);
   ctx.globalAlpha=(l.k=="signal")?0.55:0.9;
   ctx.lineWidth=(l.k=="signal")?0.7:1.3;}
  else{ctx.strokeStyle="#ffffff";
   ctx.globalAlpha=0.35;
   ctx.lineWidth=(l.k=="signal")?0.7:1.1;}
  if(reviewFocusActive()&&!focusHit)ctx.globalAlpha*=0.12;
  ctx.beginPath();ctx.moveTo(X(a.x),Y(a.y));ctx.lineTo(X(b.x),Y(b.y));ctx.stroke();});
 ctx.globalAlpha=1;}
// Placement guides only (the proximity link layer) — the exclusive replay view
// keeps these visible while every airwire/ratsnest link and all board copper
// are hidden. Guide visibility + net-colour tinting still come from paintLinks.
function paintGuides(ctx,mov,only){paintLinks(ctx,mov,only,true);}
// Per-layer copper visibility + a dim of the INACTIVE copper layer while
// drawing, so the active layer reads clearly (audit 1.5). A layer hidden in
// the Layers panel isn't drawn at all.
function layerAlpha(layer){if(!viewSt.vis[visKey(layer)])return 0;
 // KiCad-style active-layer emphasis: foreign copper remains visible/contextual
 // but the selected layer is unmistakable even before the Draw tool is armed.
 var focus=focusedSignal();if(focus==null)return drawMode?0.18:0.20;
 if(layer!==focus)return drawMode?0.18:0.28;return 0.95;}
// Any copper at all — PLANE rows included, since they carry their own eye now
// and a via must not vanish while a plane is the only copper on screen.
function anyCopperVisible(){for(var i=0;i<STACK.length;i++)if(viewSt.vis[STACK[i].name])return true;return false;}
// ── Copper multi-select ─────────────────────────────────────────────────
// selCu = the live track/via objects a marquee band caught, the copper twin
// of `sel` (parts). Which of the two a band collects is decided by the
// Objects tab's Tracks/Vias/Footprints filters, so "Footprints off" turns
// the marquee into a copper-only tool — band the board, press Del, and every
// trace/via in the area goes in ONE undo step (the bulk rip-up path used to
// clear routing before a placement pass). Membership is by object identity,
// matching how the single-item `insp` delete filters.
var selCu={t:[],v:[]},selCuIdx=null,SEL_CU=TH.sel;
function selCuCount(){return selCu.t.length+selCu.v.length;}
function selCuMembers(){if(!selCuIdx){selCuIdx=new Set();
  selCu.t.forEach(function(o){selCuIdx.add(o);});selCu.v.forEach(function(o){selCuIdx.add(o);});}
 return selCuIdx;}
function selCuHas(o){return selCuCount()>0&&selCuMembers().has(o);}
function selCuTo(ts,vs){selCu={t:ts,v:vs};selCuIdx=null;}
function selCuClear(){if(!selCuCount())return false;selCuTo([],[]);paintSoon();return true;}
// Segment ∩ axis-aligned rect (Liang–Barsky). A pure crossing counts, not just
// an endpoint inside, so a long track spanning the band is caught the same way
// partAABB gives parts KiCad's crossing-window behaviour.
function segHitsRect(x1,y1,x2,y2,ax,ay,bx,by){
 var dx=x2-x1,dy=y2-y1,t0=0,t1=1,p=[-dx,dx,-dy,dy],q=[x1-ax,bx-x1,y1-ay,by-y1];
 for(var i=0;i<4;i++){
  if(p[i]===0){if(q[i]<0)return false;continue;}
  var r=q[i]/p[i];
  if(p[i]<0){if(r>t1)return false;if(r>t0)t0=r;}
  else{if(r<t0)return false;if(r<t1)t1=r;}}
 return true;}
// Report a copper band pick on the toolbar message line. A parts-only band
// stays silent — the sidebar Align cluster already announces that count.
function marqReport(nt,nv){if(!(nt||nv))return;
 routeStatMsg(nt+" track"+(nt==1?"":"s")+" · "+nv+" via"+(nv==1?"":"s")+
  " selected — drag moves them with the parts, Del deletes, Esc clears");}
// Bulk rip-up: every marquee-selected track/via goes in ONE undo step.
function cuDeleteSelected(){var nt=selCu.t.length,nv=selCu.v.length;if(!(nt||nv))return;
 var dead=selCuMembers();recordUndo();
 rfDropForTracks(selCu.t);
 PCB.tracks=(PCB.tracks||[]).filter(function(q){return !dead.has(q);});
 PCB.vias=(PCB.vias||[]).filter(function(q){return !dead.has(q);});
 selCuTo([],[]);
 copperTouched(); // airwires come back, declared pours go stale
 routeStatMsg("deleted "+nt+" track"+(nt==1?"":"s")+" · "+nv+" via"+(nv==1?"":"s")+
  " — Save/Update to keep");
 scheduleDrc();paintSoon();}
// cop/only: drag-cache split — cop is the Set of tracks/vias a rigid-group
// drag translates live; only=false paints the rest, only=true just those.
// Copper paints per layer in KiCad's order — physical stack bottom-up
// (B.Cu, deepest inner … first inner, F.Cu) with the ACTIVE layer last, so
// the layer being routed always reads on top of foreign copper.
function trackLayerOrder(){var ord=[];
 if(NSIG>1)ord.push(1);
 for(var i=NSIG-1;i>=2;i--)ord.push(i);
 ord.push(0);
 ord=ord.filter(function(L){return L!==activeLayer;});ord.push(activeLayer);
 return ord;}
// Recover the unique circle through a persisted start/mid/end track arc.
function trackArcGeom(t){if(t.xm==null||t.ym==null)return null;
 var ax=t.x1,ay=t.y1,bx=t.xm,by=t.ym,cx=t.x2,cy=t.y2,
  d=2*(ax*(by-cy)+bx*(cy-ay)+cx*(ay-by));if(Math.abs(d)<1e-10)return null;
 var aa=ax*ax+ay*ay,bb=bx*bx+by*by,cc=cx*cx+cy*cy,
  ox=(aa*(by-cy)+bb*(cy-ay)+cc*(ay-by))/d,
  oy=(aa*(cx-bx)+bb*(ax-cx)+cc*(bx-ax))/d,r=Math.hypot(ax-ox,ay-oy),tau=Math.PI*2,
  a1=Math.atan2(ay-oy,ax-ox),am=Math.atan2(by-oy,bx-ox),a2=Math.atan2(cy-oy,cx-ox);
 function pos(a,b){var q=b-a;while(q<0)q+=tau;while(q>=tau)q-=tau;return q;}
 var pe=pos(a1,a2),pm=pos(a1,am),sw=pm<=pe+1e-8?pe:pe-tau;
 return {cx:ox,cy:oy,r:r,a1:a1,sweep:sw};}
function trackPath(path,t){var g=trackArcGeom(t);path.moveTo(X(t.x1),Y(t.y1));
 if(g)path.arc(X(g.cx),Y(g.cy),g.r*S,g.a1,g.a1+g.sweep,g.sweep<0);else path.lineTo(X(t.x2),Y(t.y2));}
var trackIdSeq=0;
function trackIdNew(){trackIdSeq++;
 try{if(window.crypto&&window.crypto.randomUUID)return "seg-"+window.crypto.randomUUID().replace(/-/g,"").slice(0,16);}catch(e){}
 return "seg-"+Date.now().toString(36)+"-"+trackIdSeq.toString(36);}
function trackIdEnsure(t){if(t&&!t.id)t.id=trackIdNew();return (t&&t.id)||"?";}
function trackIdsEnsureAll(){(PCB.tracks||[]).forEach(trackIdEnsure);}
var viaIdSeq=0;
function viaIdNew(){viaIdSeq++;
 try{if(window.crypto&&window.crypto.randomUUID)return "via-"+window.crypto.randomUUID().replace(/-/g,"").slice(0,16);}catch(e){}
 return "via-"+Date.now().toString(36)+"-"+viaIdSeq.toString(36);}
function viaIdEnsure(v){if(v&&!v.id)v.id=viaIdNew();return (v&&v.id)||"?";}
function copperIdsEnsureAll(){trackIdsEnsureAll();(PCB.vias||[]).forEach(viaIdEnsure);}
function trackChords(t){var g=trackArcGeom(t);if(!g)return [t];var tol=.01,
 maxStep=g.r>tol?2*Math.acos(Math.max(-1,1-tol/g.r)):Math.PI/8,
 n=Math.max(2,Math.min(128,Math.ceil(Math.abs(g.sweep)/Math.max(maxStep,.03)))),out=[];
 for(var i=0;i<n;i++){var a=g.a1+g.sweep*i/n,b=g.a1+g.sweep*(i+1)/n;
  out.push({x1:g.cx+g.r*Math.cos(a),y1:g.cy+g.r*Math.sin(a),x2:g.cx+g.r*Math.cos(b),y2:g.cy+g.r*Math.sin(b),l:t.l||0,w:t.w,net:t.net||"",g:t.g,source:t.source,id:t.id});}
 return out;}
window.PCBTrackChords=trackChords;
function trackLength(t){var g=trackArcGeom(t);return g?g.r*Math.abs(g.sweep):Math.hypot(t.x2-t.x1,t.y2-t.y1);}
// Static-copper batch cache. Tracks bucket by (layer, stroke width, colour) and
// vias by colour into Path2D objects in svg units (X/Y are affine constants and
// the canvas transform carries pan/zoom, so a bucket is valid at every
// viewport). A browse/pan frame then issues a handful of stroke/fill calls
// instead of one per object. Two accepted compositing changes:
//  · within a layer the buckets stroke in build order, so same-layer overlaps
//    between DIFFERENT widths/colours re-order — one width and one colour per
//    layer is the norm, where there is no difference at all. One stroke() per
//    bucket also paints each pixel once, so same-net junction overlaps stop
//    double-compositing at alpha<1: it reads closer to solid copper.
//  · via barrels batch ahead of the hole punches rather than interleaving
//    barrel+hole per via. Vias never overlap each other (DRC forbids it).
// cuBatchOn refuses the batch — today's per-item loop runs instead — wherever a
// per-object decision or a live coordinate mutation applies: the fab preview,
// review focus, a copper-carrying drag (its own `cop` split), and the segment /
// via / trace gestures, which move copper per pointermove with no invalidation
// hook of their own.
var cuBatch=null,rfGeom=null;
function cuGeomDrop(){cuBatch=null;rfGeom=null;}
// Solver-generated RF paths stay as short centreline chords for connectivity,
// editing and obstacle probes, but paint as ONE swept custom-copper polygon.
// Exact endpoint widths preserve the pad taper without exposing every solver
// sample as a separately stroked track.
function rfPathGeom(){var src=PCB.rf_paths||[];
 if(rfGeom&&rfGeom.src===src&&rfGeom.n===src.length)return rfGeom.p;
 var runs=[];
 src.forEach(function(cur){if(!cur.samples||cur.samples.length<2)return;
  var pts=cur.samples.map(function(s){return [+s[0],+s[1]];}),ws=cur.samples.map(function(s){return +s[2];});
  var left=[],right=[];
  function add(out,p){var q=out.length&&out[out.length-1];if(!q||Math.abs(q[0]-p[0])>1e-7||Math.abs(q[1]-p[1])>1e-7)out.push(p);}
  for(var i=0;i<pts.length;i++){var ax,ay,bx,by;
   if(i===0){ax=pts[1][0]-pts[0][0];ay=pts[1][1]-pts[0][1];bx=ax;by=ay;}
   else if(i===pts.length-1){ax=pts[i][0]-pts[i-1][0];ay=pts[i][1]-pts[i-1][1];bx=ax;by=ay;}
   else{ax=pts[i][0]-pts[i-1][0];ay=pts[i][1]-pts[i-1][1];bx=pts[i+1][0]-pts[i][0];by=pts[i+1][1]-pts[i][1];}
   var al=Math.hypot(ax,ay)||1,bl=Math.hypot(bx,by)||1,half=Math.max(ws[i],1e-9)/2;
   [1,-1].forEach(function(side,si){var out=si?right:left,nax=-ay/al*side,nay=ax/al*side,nbx=-by/bl*side,nby=bx/bl*side;
    if(i===0||i===pts.length-1){add(out,[pts[i][0]+nbx*half,pts[i][1]+nby*half]);return;}
    var mx=nax+nbx,my=nay+nby,ml=Math.hypot(mx,my);if(ml>1e-9){mx/=ml;my/=ml;var den=mx*nbx+my*nby;
     if(den>1e-9){var off=half/den;if(off<=half*2+1e-9){add(out,[pts[i][0]+mx*off,pts[i][1]+my*off]);return;}}}
    add(out,[pts[i][0]+nax*half,pts[i][1]+nay*half]);add(out,[pts[i][0]+nbx*half,pts[i][1]+nby*half]);});}
  var poly=left.concat(right.reverse()),path=new Path2D();path.moveTo(X(poly[0][0]),Y(poly[0][1]));
  for(var j=1;j<poly.length;j++)path.lineTo(X(poly[j][0]),Y(poly[j][1]));path.closePath();
  runs.push({l:cur.l||0,net:cur.net,poly:poly,path:path});});
 rfGeom={src:src,n:src.length,p:runs};return runs;}
function rfSamePoint(a,b){return Math.abs(a[0]-b[0])<=1e-7&&Math.abs(a[1]-b[1])<=1e-7;}
function rfPathCoversTrack(ss,t,a,b){for(var i=0;i<ss.length;i++){if(!rfSamePoint(ss[i],a))continue;
  for(var j=i+1;j<ss.length;j++){if(!rfSamePoint(ss[j],b))continue;var on=true;
   for(var k=i+1;k<j;k++)if(segDist(ss[k][0],ss[k][1],t)>.011){on=false;break;}
   if(on)return true;}}return false;}
function rfPathOwnsTrack(p,t){if(!p||!t||(p.l||0)!==(t.l||0)||p.net!==t.net)return false;
 var ids=p.track_ids||[];if(ids.length)return !!t.id&&ids.indexOf(t.id)>=0;
 var ss=p.samples||[];if(ss.length<2)return false;
 return rfPathCoversTrack(ss,t,[t.x1,t.y1],[t.x2,t.y2])||rfPathCoversTrack(ss,t,[t.x2,t.y2],[t.x1,t.y1]);}
function rfOwnsTrack(t){return (PCB.rf_paths||[]).some(function(p){return rfPathOwnsTrack(p,t);});}
window.PCBRfOwnsTrack=rfOwnsTrack;
// A generated RF polygon is exact only while its hidden centreline chords are
// untouched. Editing one drops its polygon proof; ordinary tracks become
// visible/editable and DRC judges them until Route creates a fresh RF path.
function rfDropForTracks(ts){if(!(PCB.rf_paths||[]).length||!ts||!ts.length)return;
 var before=PCB.rf_paths;PCB.rf_paths=before.filter(function(p){return !ts.some(function(t){return rfPathOwnsTrack(p,t);});});
 if(PCB.rf_paths.length!==before.length)cuGeomDrop();}
function rfDropNet(net){if(!net)return;var before=PCB.rf_paths;
 PCB.rf_paths=before.filter(function(p){return p.net!==net;});if(PCB.rf_paths.length!==before.length)cuGeomDrop();}
function cuBatchOn(cop){
 return !PHYSICAL_REVIEW&&!cop&&!reviewFocusActive()&&!segdrag&&!viadrag&&!dtrace
  &&!(gdrag&&gdrag.moved&&(gdrag.ct.length||gdrag.cv.length));}
function cuBucket(list,key,make){for(var i=0;i<list.length;i++)if(list[i].k===key)return list[i];
 var b=make();b.k=key;list.push(b);return b;}
function cuBatchGet(){
 var ts=PCB.tracks||[],vs=PCB.vias||[],vgd=viaGeo().drill;
 // Identity+length of the source arrays (plus every colour input) is the
 // backstop under the explicit cuGeomDrop() calls.
 if(cuBatch&&cuBatch.ts===ts&&cuBatch.tn===ts.length&&cuBatch.vs===vs&&cuBatch.vn===vs.length
  &&cuBatch.nc===netColOn&&cuBatch.ncm===PCB.netcolor&&cuBatch.vgd===vgd)return cuBatch;
 var byL={},barrel=[],holes=new Path2D(),nb=0;
 ts.forEach(function(t){if(rfOwnsTrack(t))return;var L=t.l||0;
  var c=(netColOn&&netColorOf(netCollapse(t.net)))||layerColor(L);
  var w=Math.max(t.w*S,1.2),m=byL[L]||(byL[L]=[]);
  var b=cuBucket(m,w+"|"+c,function(){return {w:w,c:c,p:new Path2D()};});
  trackPath(b.p,t);});
 vs.forEach(function(v){
  var rr=viaRenderRadius(v.d),dr=(v.drill>0)?v.drill:vgd;
  var rh=viaRenderRadius(dr);
  var c=(netColOn&&netColorOf(netCollapse(v.net)))||TH.via,x=X(v.x),y=Y(v.y);
  holes.moveTo(x+rh,y);holes.arc(x,y,rh,0,6.2832);nb++;
  var bb=cuBucket(barrel,c,function(){return {c:c,p:new Path2D()};});
  bb.p.moveTo(x+rr,y);bb.p.arc(x,y,rr,0,6.2832);});
 cuBatch={ts:ts,tn:ts.length,vs:vs,vn:vs.length,nc:netColOn,ncm:PCB.netcolor,vgd:vgd,
  t:byL,v:barrel,h:holes,nb:nb};
 return cuBatch;}
// Marquee-selected copper gets a purple fringe — the same hue selected parts
// use, so one selection colour reads across parts and copper. Split by the drag
// cache exactly like the copper itself, so each paints once. Lifted out of
// paintTracks because a GPU frame draws ONLY these two: the copper they fringe
// lives on the WebGPU canvas below, so the fringe lands above it there instead
// of under it (a deliberate, documented difference — the halo reads as clearer
// selection feedback when it is not being over-painted by its own track).
function selCuTrackFringe(ctx,cop,only){
 ctx.globalAlpha=1;ctx.strokeStyle=SEL_CU;
 selCu.t.forEach(function(t){
  if(cop&&cop.has(t)!==(only||false))return;
  if(layerAlpha(t.l||0)<=0)return;
  ctx.lineWidth=Math.max((t.w||0.25)*S,1.2)+4;
  ctx.beginPath();trackPath(ctx,t);ctx.stroke();});}
function selCuViaFringe(ctx,cop,only){
 ctx.globalAlpha=1;ctx.fillStyle=SEL_CU;
 selCu.v.forEach(function(v){
  if(cop&&cop.has(v)!==(only||false))return;
  ctx.beginPath();ctx.arc(X(v.x),Y(v.y),viaRenderRadius(v.d)+3,0,6.2832);ctx.fill();});}
function paintTracks(ctx,cop,only){
 ctx.lineCap="round";
 if(selCu.t.length)selCuTrackFringe(ctx,cop,only);
 // GPU frame: tracks, via barrels and hole punches are already on the
 // WebGPU canvas below, so the fringes above/below are all this pass still owns.
 // The via fringe keeps paintTracks' own all-copper-hidden gate (reviewFocus is
 // a gpuLive() refusal, so `focusVia` cannot be the reason it draws here).
 if(gpuOwns("copper")){ctx.globalAlpha=1;ctx.lineCap="butt";
  if(selCu.v.length&&anyCopperVisible())selCuViaFringe(ctx,cop,only);
  return;}
 var CB=cuBatchOn(cop)?cuBatchGet():null;
 trackLayerOrder().forEach(function(L){
  rfPathGeom().forEach(function(r){if(r.l!==L||cop&&only)return;
   var hit=reviewFocusNet(r.net),a=PHYSICAL_REVIEW?(reviewFocusHasNets()?(hit?.98:.07):(L===activeLayer?.32:0)):layerAlpha(L)*pourLayerFade(L);
   if(reviewFocusActive()&&!PHYSICAL_REVIEW)a*=hit?1:.1;if(a<=0)return;ctx.globalAlpha=a;
   ctx.fillStyle=hit?layerHighlightColor(L):(netColOn&&netColorOf(netCollapse(r.net))||layerColor(L));ctx.fill(r.path);});
  if(PHYSICAL_REVIEW){(PCB.tracks||[]).forEach(function(t){
    if(rfOwnsTrack(t))return;
    if((t.l||0)!==L)return;if(cop&&cop.has(t)!==(only||false))return;
    var hit=reviewFocusNet(t.net);if(L!==activeLayer&&!hit)return;
    ctx.globalAlpha=reviewFocusHasNets()?(hit?0.98:0.07):(L===activeLayer?0.32:0);
    if(ctx.globalAlpha<=0)return;ctx.strokeStyle=hit?"#58d6ff":PH.copperUnder;
    ctx.lineWidth=Math.max(t.w*S,1.2)+(hit?1.6:0);
    ctx.beginPath();trackPath(ctx,t);ctx.stroke();});return;}
  if(CB){var ba=layerAlpha(L)*pourLayerFade(L);if(ba<=0)return; // solid pour hides foreign-layer traces
   var bl=CB.t[L];if(!bl)return;ctx.globalAlpha=ba;
   for(var bi=0;bi<bl.length;bi++){var bk=bl[bi];ctx.strokeStyle=bk.c;ctx.lineWidth=bk.w;ctx.stroke(bk.p);}
   return;}
  var focusLayer=reviewFocusActive()&&(PCB.tracks||[]).some(function(t){return (t.l||0)===L&&reviewFocusNet(t.net);});
  var a=layerAlpha(L);if(focusLayer)a=0.95;a*=pourLayerFade(L);if(a<=0)return; // solid pour hides foreign-layer traces
  ctx.globalAlpha=a;ctx.strokeStyle=layerColor(L);
  (PCB.tracks||[]).forEach(function(t){
   if(rfOwnsTrack(t))return;
   if((t.l||0)!==L)return;
   if(cop&&cop.has(t)!==(only||false))return;
   var hit=reviewFocusNet(t.net);
   ctx.globalAlpha=a*(reviewFocusActive()?(hit?1:0.1):1);
   // Net-colours view: paint each track in its net's colour (same map the
   // pads/airwires use) so copper reads by connectivity; fall back to the
   // layer colour for un-netted copper or a net with no assigned colour.
   ctx.strokeStyle=hit?layerHighlightColor(L):(netColOn&&netColorOf(netCollapse(t.net))||layerColor(L));
   ctx.lineWidth=Math.max(t.w*S,1.2)+(hit?1.6:0);
   ctx.beginPath();trackPath(ctx,t);ctx.stroke();});});
 ctx.globalAlpha=1;ctx.lineCap="butt";
 // Vias span every copper layer — hide only when ALL of them are hidden.
 var focusVia=reviewFocusActive()&&(PCB.vias||[]).some(function(v){return reviewFocusNet(v.net);});
 if(!anyCopperVisible()&&!focusVia)return;
 // Selected vias: same purple fringe, drawn just under the barrel.
 if(selCu.v.length)selCuViaFringe(ctx,cop,only);
 if(CB){ctx.globalAlpha=1;
  for(var vi=0;vi<CB.v.length;vi++){ctx.fillStyle=CB.v[vi].c;ctx.fill(CB.v[vi].p);}
  if(CB.nb){ctx.fillStyle=TH.viaHole;ctx.fill(CB.h);}
  if(PHYSICAL_REVIEW)paintMaskRelief(ctx);
  ctx.globalAlpha=1;return;}
 (PCB.vias||[]).forEach(function(v){
  if(cop&&cop.has(v)!==(only||false))return;
  var hit=reviewFocusNet(v.net);
  ctx.globalAlpha=(PHYSICAL_REVIEW?reviewFocusHasNets():reviewFocusActive())?(hit?1:0.1):1;
  var rr=viaRenderRadius(v.d),dr=(v.drill>0)?v.drill:viaGeo().drill;
  var rh=viaRenderRadius(dr);
  var col=hit?"#8be9ff":(PHYSICAL_REVIEW?PH.viaMask:(netColOn&&netColorOf(netCollapse(v.net))||TH.via));
  ctx.fillStyle=col;ctx.beginPath();ctx.arc(X(v.x),Y(v.y),rr,0,6.2832);ctx.fill();
  ctx.globalAlpha=1;
  ctx.fillStyle=PHYSICAL_REVIEW?PH.hole:TH.viaHole;ctx.beginPath();ctx.arc(X(v.x),Y(v.y),rh,0,6.2832);ctx.fill();});
 if(PHYSICAL_REVIEW)paintMaskRelief(ctx);
 ctx.globalAlpha=1;}
// mov/only/cop: drag-cache split — moving parts' halos are dynamic; via/track
// halos follow the copper the drag carries (cop, a Set of live objects).
function paintClr(ctx,mov,only,cop){
 if(PHYSICAL_REVIEW)return;
 if(!clrOn())return;
 var clr=clrVal();
 ctx.lineJoin="round";ctx.lineCap="round";
 P.forEach(function(p,i){if(mov&&(!!mov[i])!==only)return;
  p.pads.forEach(function(pad){var shape=worldPadPath(p,pad);
   // The clearance is an exact outline dilation, not the world AABB. A wide
   // round-join stroke follows rotated rectangles and custom concave polygons;
   // filling the core completes the halo for pads wider than 2× clearance.
   ctx.setLineDash([]);ctx.strokeStyle="rgba(210,153,34,0.13)";ctx.fillStyle="rgba(210,153,34,0.13)";
   ctx.lineWidth=2*clr*S;ctx.stroke(shape);ctx.fill(shape);
   // Retain the thin dashed visual cue on the real copper boundary. The
   // translucent outer edge above is the actual clearance boundary.
   ctx.setLineDash([3,2]);ctx.strokeStyle="#d29922";ctx.lineWidth=0.8;ctx.stroke(shape);});});
 ctx.strokeStyle="#d29922";ctx.lineWidth=0.8;ctx.fillStyle="rgba(210,153,34,0.13)";
 (PCB.vias||[]).forEach(function(v){
  if(mov&&(!!(cop&&cop.has(v)))!==only)return;
  ctx.beginPath();ctx.arc(X(v.x),Y(v.y),(v.d/2+clr)*S,0,6.2832);ctx.fill();ctx.stroke();});
 ctx.setLineDash([]);ctx.globalAlpha=0.20;ctx.lineCap="round";
 (PCB.tracks||[]).forEach(function(t){
  if(mov&&(!!(cop&&cop.has(t)))!==only)return;
  ctx.lineWidth=(t.w+2*clr)*S;
  ctx.beginPath();trackPath(ctx,t);ctx.stroke();});
 ctx.globalAlpha=1;ctx.lineCap="butt";ctx.lineJoin="miter";}
window.addEventListener("resize",paintSoon);

// ── Ratsnest connectivity: hide airwires their copper already satisfies ──
// Union-find over quantized copper points, one pass per net that has links:
// a track joins its two endpoints on its layer, a via joins its point across
// every layer, and a pad adopts any point inside its rect on a compatible
// layer (thru pads on all layers). T-joints — an endpoint landing ON another
// same-net segment, which both hand routing and the router's welds produce —
// union through a point-on-segment tolerance. A link is `done` when its two
// pads land in one component. Recomputed lazily (copperTouched marks dirty;
// the first static paintLinks flushes), so drags never pay for it.
var linksDirty=true,linkConnCache={};
function copperTouched(){linksDirty=true;
 traceEmDirty=true; // the embedded sweep describes the last saved copper
 powerIntegrityDirty=true; // capacity facts describe the last saved copper too
 ovsRev++; // the overscan pan buffer baked the pre-edit copper (and its airwire doneness)
 keepoutGeomDrop(); // active-layer net-class halo paths were baked from the pre-edit geometry
 cuGeomDrop(); // the batched track/via paths were built from the pre-edit copper
 if(gpuOn)PCBGpu.rebuildCopper(); // GPU twin of cuGeomDrop — lazy, so a burst costs one rebuild
 markPoursStale(); // any copper/pose edit invalidates the declared pours
 selCuClear(); // a rip-up/drag can free the selected objects — drop the refs
 inspClear();} // inspected copper/marker facts are stale after any edit
function connKey(x,y,l){return Math.round(x*1000)+","+Math.round(y*1000)+","+l;}
function linksRecompute(){linksDirty=false;
 var links=PCB.links||[];if(!links.length)return;
 // Bucket the board once. Each net gets a compact geometry/pose signature, so
 // a part drop rebuilds only the handful of nets on that part and a copper edit
 // rebuilds only the edited nets. Unchanged union-find results are retained.
 var nets={};
 links.forEach(function(l){l.done=false;if(l.net)nets[netCollapse(l.net)]={ts:[],vs:[],ps:[],sig:[]};});
 (PCB.tracks||[]).forEach(function(t){var b=nets[netCollapse(t.net||"")];if(!b)return;
  b.ts.push(t);b.sig.push("t",t.x1,t.y1,t.xm,t.ym,t.x2,t.y2,t.l||0,t.w||0);});
 (PCB.vias||[]).forEach(function(v){var b=nets[netCollapse(v.net||"")];if(!b)return;
  b.vs.push(v);b.sig.push("v",v.x,v.y,v.d||0,v.drill||0);});
 P.forEach(function(p,i){var seen={};(p.pads||[]).forEach(function(pd){var net=netCollapse(pd.net||""),b=nets[net];
  if(!b)return;b.ps.push({i:i,pd:pd});if(!seen[net]){seen[net]=1;b.sig.push("p",i,p.x,p.y,p.rot||0,p.side||"top");}});});
 Object.keys(nets).forEach(function(net){var b=nets[net],sig=b.sig.join("|");
  if(!linkConnCache[net]||linkConnCache[net].sig!==sig)linkConnCache[net]={sig:sig,roots:linksBuildNet(b)};});
 var left=0;
 links.forEach(function(l){var c=linkConnCache[netCollapse(l.net||"")],pa=connPadNode(l.a,l.ax,l.ay),pb=connPadNode(l.b,l.bx,l.by);
  if(c&&pa&&pb&&c.roots[pa]!==undefined&&c.roots[pa]===c.roots[pb])l.done=true;
  if(!l.done)left++;});
 PCB.links_left=left;}
function linksBuildNet(b){
 var par={};
 function find(k){
  if(par[k]===undefined){par[k]=k;return k;}
  var r=k;while(par[r]!==r)r=par[r];
  while(par[k]!==r){var n=par[k];par[k]=r;k=n;}
  return r;}
 function union(a,b){par[find(a)]=find(b);}
 var ts=b.ts,vs=b.vs;
 if(!ts.length&&!vs.length)return {};
  var pts=[]; // every copper point: {x,y,l,key} (via layer -1 = all layers)
  ts.forEach(function(t){var L=t.l||0;
   union(connKey(t.x1,t.y1,L),connKey(t.x2,t.y2,L));
   pts.push({x:t.x1,y:t.y1,l:L},{x:t.x2,y:t.y2,l:L});});
  vs.forEach(function(v){for(var L=1;L<NSIG;L++)union(connKey(v.x,v.y,0),connKey(v.x,v.y,L));
   pts.push({x:v.x,y:v.y,l:-1});});
  // T-joints: endpoint (or via) sitting on another segment's body
  pts.forEach(function(q){ts.forEach(function(t){var L=t.l||0;
   if(q.l!==-1&&q.l!==L)return;
   var hit=trackChords(t).some(function(s){return ptSegDist(q.x,q.y,s.x1,s.y1,s.x2,s.y2)<=(t.w||0.25)/2+0.02;});
   if(hit)union(connKey(q.x,q.y,q.l===-1?L:q.l),connKey(t.x1,t.y1,L));});});
  // pads adopt contained copper points
  b.ps.forEach(function(qp){var i=qp.i,pd=qp.pd,i_p=P[i],bot=(i_p.side==="bottom")?1:0,j=(i_p.pads||[]).indexOf(pd);
    var r=wrect(i,pd),thru=(pd.drill>0),pk="pad:"+i+":"+j;
    pts.forEach(function(q){
     if(!thru&&q.l!==-1&&q.l!==bot)return;
     if(q.x<r.x0-0.02||q.x>r.x1+0.02||q.y<r.y0-0.02||q.y>r.y1+0.02)return;
     union(pk,connKey(q.x,q.y,q.l===-1?0:q.l));});});
 var roots={};for(var k in par)roots[k]=find(k);return roots;}
// The pad node id for a link endpoint (part index + the pad's LOCAL centre,
// which is exactly what writeLinks emitted — so match by local coords).
function connPadNode(i,lx,ly){var p=P[i];if(!p)return null;
 var pads=p.pads||[];
 for(var j=0;j<pads.length;j++)
  if(Math.abs(pads[j].x-lx)<1e-6&&Math.abs(pads[j].y-ly)<1e-6)return "pad:"+i+":"+j;
 return null;}
// ── Ratsnest: airwires on the canvas; loop overlays stay SVG ────────────
var gRP=document.createElementNS(NS,"g");
gR.appendChild(gRP);
var loopGs=[],loopDom=[],partLoops={};
(PCB.loops||[]).forEach(function(L,k){(partLoops[L.hub]=partLoops[L.hub]||[]).push(k);
 (partLoops[L.cap]=partLoops[L.cap]||[]).push(k);});
function linkCol(l){var col=l.k=="proximity"?TH.awProx:(l.k=="ground"?TH.awGnd:TH.awOther);
 if(netColOn){var nc=netColorOf(l.net);if(nc)col=nc;}return col;}
// Redraw ONE loop overlay group. Uses the server's DRC-safe GND-via drop
// (cgv/gpv) only while the cap/hub is at its emitted pose; once dragged that
// world point is stale (and cgv/gpv come back null when the router can't fan
// a via there at all), so draw the return *path* to the raw pad centre but
// DON'T invent a via dot — Route re-derives the exact DRC-safe fan.
function drawLoop(k){if(!viewSt.vis.guides)return;var L=PCB.loops[k],g=loopGs[k];if(!L||!g)return;
 var d=loopDom[k];if(!d){
  d={power:el("line",{stroke:TH.awProx,"stroke-width":1.3,opacity:0.95}),
   ret:el("polyline",{fill:"none",stroke:TH.loopRet,"stroke-width":1.3,opacity:0.85,"stroke-dasharray":"4 2"}),vias:[]};
  var gt=el("title",{});gt.textContent="GND return images under the power trace on the L2 plane (drops at the DRC-safe GND vias)";
  d.ret.appendChild(gt);
  // Say WHOSE choice this target pad is: `ep` is the pad the design declared
  // via `(decouples "IC" PIN)` (or a per-pin shorthand); absent means the
  // solver defaulted to the lowest-numbered supply pad.
  var pt=el("title",{});pt.textContent="Decoupling target: "+(P[L.hub]?refLabel(P[L.hub].ref):"hub")+
   (L.ep?(" pin "+L.ep+" (declared)"):" (defaulted)");
  d.power.appendChild(pt);
  g.appendChild(d.power);g.appendChild(d.ret);
  for(var vi=0;vi<4;vi++){var vc=el("circle",{});d.vias.push(vc);g.appendChild(vc);}loopDom[k]=d;}
 var routedNow=((PCB.tracks||[]).length>0);
 var cReal=(L.cgv&&!moved(L.cap)), dReal=(L.gpv&&!moved(L.hub));
 var A=wpt(L.hub,L.pp.x,L.pp.y), B=wpt(L.cap,L.cp.x,L.cp.y),
     C=cReal?L.cgv:wpt(L.cap,L.cg.x,L.cg.y),
     D=dReal?L.gpv:wpt(L.hub,L.gp.x,L.gp.y);
 var pwrCol=TH.awProx;if(netColOn){var nc=netColorOf(L.net);if(nc)pwrCol=nc;}
 d.power.setAttribute("x1",X(B.x).toFixed(1));d.power.setAttribute("y1",Y(B.y).toFixed(1));
 d.power.setAttribute("x2",X(A.x).toFixed(1));d.power.setAttribute("y2",Y(A.y).toFixed(1));d.power.setAttribute("stroke",pwrCol);
 // An AUTHORED target (`ep`) keeps the solid guide; a target the solver picked
 // for itself is dashed, so a defaulted pad is never read as a declared one.
 d.power.setAttribute("stroke-dasharray",L.ep?"none":"3 2");
 var rp=[C,B,A,D].map(function(q){return X(q.x).toFixed(1)+","+Y(q.y).toFixed(1);}).join(" ");
 d.ret.setAttribute("points",rp);
 loopViaPatch(d.vias,0,C,!routedNow&&cReal);loopViaPatch(d.vias,2,D,!routedNow&&dReal);}
function loopViaPatch(cs,at,p,on){var vg=viaGeo(),r=viaRenderRadius(vg.dia),rh=viaRenderRadius(vg.drill);
 [r,rh].forEach(function(rr,j){var c=cs[at+j];c.style.display=on?"":"none";if(!on)return;
  c.setAttribute("cx",X(p.x).toFixed(1));c.setAttribute("cy",Y(p.y).toFixed(1));c.setAttribute("r",rr.toFixed(1));c.setAttribute("fill",j?TH.viaHole:TH.via);});}
function rats(){
 while(gRP.firstChild)gRP.removeChild(gRP.firstChild);
 loopGs=[];loopDom=[];loopDirty=null; // full rebuild supersedes any pending per-loop redraws
 ovPaintSoon();   // airwires live on the canvas overlay
 if(!viewSt.vis.guides)return;
 (PCB.loops||[]).forEach(function(L,k){var g=document.createElementNS(NS,"g");
   gRP.appendChild(g);loopGs.push(g);drawLoop(k);});
}

// Update only the airwires + loop overlays touching the given part indices —
// the per-pointermove path. O(links-on-moved-parts), not O(board). SVG attribute
// patches are only MARKED here and flushed once per rAF frame by scenePaint:
// pointermove can fire far above the frame rate (high-poll-rate mice), and
// rebuilding DOM nodes per event was measurable churn on hub/group drags.
var loopDirty=null;
function ratsUpdate(idxs){
 if(!ratsOn&&!viewSt.vis.guides)return;
 ovPaintSoon();   // airwires: one cheap full canvas repaint per frame
 if(!viewSt.vis.guides)return;
 loopDirty=loopDirty||{};
 idxs.forEach(function(i){
  (partLoops[i]||[]).forEach(function(k){loopDirty[k]=1;});});
}
function delta(id,cur,base){
 var e=document.getElementById(id);if(!e)return;var d=cur-base;
 // Blank (not "=") when unchanged so the score bar isn't a row of "=" on load.
 if(Math.abs(d)<0.05){e.textContent="";e.className="delta";}
 else{e.textContent=(d>0?"+":"")+d.toFixed(1);e.className="delta "+(d>0?"up":"down");}
}
function setSc(id,t){var e=document.getElementById(id);if(e)e.textContent=t;}
// Headline objective: the server's own weighted total (breakdown.objective =
// hpwl + loop_w·loop_nh_weighted + w_align·alignment + w_congest·congestion).
// The browser-side re-weighing UI is gone, so there is nothing to re-derive —
// showing the server number keeps the chip and the saved-layout rows exactly
// consistent with the optimizer.
function svObj(b){return (b&&b.objective)||0;}
var currentScore=PCB.auto;
function showScore(b){
 if(b)currentScore=b;
 setSc("sc-obj","objective "+svObj(b).toFixed(1));
 delta("sc-obj-d",svObj(b),svObj(PCB.auto));
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
// screen→svg is arithmetic over the cached viewport rect and `vb` (setVB writes
// the viewBox FROM vb, so the two can never disagree) because getScreenCTM()
// forces a layout and mm(ev) runs on every pointermove. The matrix path
// survives for the review embed alone, whose shell carries a rotate/mirror
// transform that an axis-aligned rect cannot describe. A resolved map — like
// the inverse matrix it replaces — is FROZEN where it was taken: startPan holds
// one for the whole gesture, and every move of that gesture must be measured
// against the viewport the pan STARTED in, never the one it is dragging.
function svgShellXformed(){return !!(reviewOriented&&(reviewRotation%360!==0||reviewSide==="bottom"));}
function svgScreenMap(){var r=svgMetricsGet();
 return {vbmap:true,x:vb.x,y:vb.y,left:r.left,top:r.top,
  kx:vb.w/Math.max(r.width,1),ky:vb.h/Math.max(r.height,1)};}
function svgScreenInverse(){if(!svgShellXformed())return svgScreenMap();
 try{var m=svg.getScreenCTM();return m&&m.inverse();}catch(e){return null;}}
function svgScreenPoint(cx,cy,inv){inv=inv||svgScreenInverse();
 if(inv&&!inv.vbmap){try{var p=svg.createSVGPoint();
   p.x=cx;p.y=cy;p=p.matrixTransform(inv);return {x:p.x,y:p.y};}catch(e){}inv=null;}
 var m=inv||svgScreenMap();
 return {x:m.x+(cx-m.left)*m.kx,y:m.y+(cy-m.top)*m.ky};}
function svgScreenDelta(dx,dy){var inv=svgScreenInverse(),a=svgScreenPoint(0,0,inv),b=svgScreenPoint(dx,dy,inv);
 return {x:b.x-a.x,y:b.y-a.y};}
function mm(ev){var p=svgScreenPoint(ev.clientX,ev.clientY);
 return {x:p.x/S+MX-M,y:p.y/S+MY-M};}
// ── KiCad-style properties panel ──────────────────────────────────────
// The sidebar shows one selection at a time: a rigid sub-circuit first, then a
// component after drilling in. Clicking empty board clears it back to the hint.
// renderProps rebuilds the panel; updatePropLive is the cheap pose refresh.
// Hierarchical selection for rigid sub-circuits. The first click selects the
// group (`selGroup`, no `selRef`); a second click while that group is active
// drills into one component (`selGroup` + `selRef`). This state, rather than
// incidental hover, is the authority for move / rotate targeting.
var selRef=null,selGroup=null;
function pEsc(s){return String(s==null?"":s).replace(/[&<>"]/g,function(c){
 return c=="&"?"&amp;":(c=="<"?"&lt;":(c==">"?"&gt;":"&quot;"));});}
function pMm(v){return (Math.round(v*100)/100).toFixed(2);}
function nLeaf(s){var i=String(s).lastIndexOf("/");return i<0?s:s.slice(i+1);}
function pRow(k,v,id){return '<div class="prop-row"><span class="k">'+k+'</span><span class="v"'+
 (id?(' id="'+id+'"'):'')+'>'+pEsc(v)+'</span></div>';}
// Editable rows for the (edit-only) properties panel: a numeric mm input and a
// preset select. Committed on Enter/blur/change by wirePropInputs.
function pNumRow(k,id,val,locked){return '<div class="prop-row"><span class="k">'+k+'</span>'+
 '<input class="pv-in" id="'+id+'" type="number" step="0.001"'+(locked?' disabled':'')+
 ' value="'+(Math.round(val*1000)/1000)+'"></div>';}
function pSelRow(k,id,opts,cur,locked){var o='';opts.forEach(function(op){
  o+='<option value="'+pEsc(op[0])+'"'+(String(op[0])===String(cur)?' selected':'')+'>'+pEsc(op[1])+'</option>';});
 return '<div class="prop-row"><span class="k">'+k+'</span>'+
  '<select class="pv-in" id="'+id+'"'+(locked?' disabled':'')+'>'+o+'</select></div>';}
function passiveFamilyRoot(name){var s=String(name||"").toLowerCase(),i=s.indexOf("-");return i<0?s:s.slice(0,i);}
function passiveFpLabel(c){return c.name+(c.footprint?" · "+c.footprint:"");}
function passiveFpChoices(p,comps){var root=passiveFamilyRoot(p.component),seen={},out=[];
 (comps||[]).forEach(function(c){if(!c||!c.family||!c.name||!c.footprint)return;
  if(passiveFamilyRoot(c.name)!==root||seen[c.name])return;seen[c.name]=1;out.push(c);});
 if(!seen[p.component])out.push({name:p.component,footprint:p.fp||""});
 out.sort(function(a,b){return a.name.localeCompare(b.name,undefined,{numeric:true});});return out;}
var passiveLibPromise=null;
function passiveLibLoad(){if(!passiveLibPromise)passiveLibPromise=fetch("/api/lib-index")
 .then(function(r){if(!r.ok)throw new Error("library index failed");return r.json();})
 .then(function(j){return (j&&j.components)||[];});return passiveLibPromise;}
function passiveFpEditable(p){return !RO&&!mobileInspectMode()&&p.kind==="passive"&&p.component&&p.src&&p.srcName;}
function passiveFpMsg(text,bad){var e=document.getElementById("prop-fp-msg");if(!e)return;
 e.textContent=text;e.classList.toggle("bad",!!bad);}
function passiveRefreshLoops(){loopPin={};partLoops={};(PCB.loops||[]).forEach(function(L,k){
 if(L.pp)loopPin[L.hub+":"+L.pp.x.toFixed(2)+":"+L.pp.y.toFixed(2)]=1;
 (partLoops[L.hub]=partLoops[L.hub]||[]).push(k);
 (partLoops[L.cap]=partLoops[L.cap]||[]).push(k);});}
function passiveRefreshTopology(index,oldPads,newPads){var next={};newPads.forEach(function(pd){next[String(pd.num)]=pd;});
 function move(x,y){for(var i=0;i<oldPads.length;i++){var old=oldPads[i];
  if(Math.abs(old.x-x)<1e-6&&Math.abs(old.y-y)<1e-6){var pd=next[String(old.num)];if(pd)return {x:pd.x,y:pd.y};}}return {x:x,y:y};}
 (PCB.links||[]).forEach(function(l){var q;if(l.a===index){q=move(l.ax,l.ay);l.ax=q.x;l.ay=q.y;}
  if(l.b===index){q=move(l.bx,l.by);l.bx=q.x;l.by=q.y;}});
 (PCB.nets||[]).forEach(function(net){net.forEach(function(pin){if(pin.p!==index)return;var q=move(pin.x,pin.y);pin.x=q.x;pin.y=q.y;});});
 (PCB.loops||[]).forEach(function(L){var q;if(L.cap===index){q=move(L.cp.x,L.cp.y);L.cp=q;q=move(L.cg.x,L.cg.y);L.cg=q;L.cgv=null;}
  if(L.hub===index){q=move(L.pp.x,L.pp.y);L.pp=q;q=move(L.gp.x,L.gp.y);L.gp=q;L.gpv=null;}});}
function passiveRefreshApply(p,edit,score){var fresh=score&&score.refresh&&score.refresh.part;
 if(!fresh||fresh.ref!==p.ref)throw new Error("Updated footprint geometry was not returned.");
 var index=P.indexOf(p),oldPads=p.pads||[],oldFp=p.fp;passiveRefreshTopology(index,oldPads,fresh.pads||[]);
 var fields=["origin","hw","hh","ccx","ccy","kind","fb","fp","val","component","pads","silk"];
 fields.forEach(function(k){if(Object.prototype.hasOwnProperty.call(fresh,k))p[k]=fresh[k];else delete p[k];});
 var meta=edit&&edit.part_edits&&edit.part_edits[p.ref];
 if(meta){p.src=meta.src;p.srcName=meta.srcName;p.srcRef=meta.srcRef;}
 if(oldFp!==p.fp){PCB.models=PCB.models||{};Object.keys(score.refresh.models||{}).forEach(function(fp){PCB.models[fp]=score.refresh.models[fp];});}
 if(score.blame)P.forEach(function(q){if(score.blame[q.ref]!==undefined)q.blame=score.blame[q.ref];});
 linksDirty=true;linkConnCache={};cullBox=null;passiveRefreshLoops();PCB.drc=[];
 dragCacheDrop();rats();drawDrc();showScore(score);renderProps();scheduleDrc();
 if(heatOn)applyHeat();if(window.PCB3D&&window.PCB3D.sync)window.PCB3D.sync();}
function wirePassiveFootprint(p){var sel=document.getElementById("prop-footprint");if(!sel)return;
 sel.disabled=true;passiveLibLoad().then(function(comps){
  if(selRef!==p.ref||document.getElementById("prop-footprint")!==sel)return;
  var choices=passiveFpChoices(p,comps);sel.textContent="";choices.forEach(function(c){var op=document.createElement("option");
   op.value=c.name;op.textContent=passiveFpLabel(c);op.selected=c.name===p.component;sel.appendChild(op);});
  sel.disabled=choices.length<2;if(choices.length<2)passiveFpMsg("No compatible footprint families are available for this part.",false);
 }).catch(function(e){passiveFpMsg(e.message||"Could not load footprint choices.",true);});
 sel.addEventListener("change",function(){var next=sel.value;if(!next||next===p.component)return;
  var saved=false;sel.disabled=true;passiveFpMsg("Updating schematic source…",false);
  fetch("/api/edit-footprint/"+encodeURIComponent(PCB.name),{method:"POST",headers:{"Content-Type":"application/json"},
   body:JSON.stringify({ref:p.srcRef||p.ref,component:next,oldComponent:p.component,srcOff:p.src,sourceName:p.srcName})})
   .then(function(r){return r.text().then(function(t){if(!r.ok)throw new Error(t||"Footprint update failed.");
    try{var j=t?JSON.parse(t):null;if(j&&j.error)throw new Error(j.error);return j;}catch(e){if(e instanceof SyntaxError)return {};throw e;} });})
   .then(function(edit){saved=true;return fetch("/api/pcb-score/"+encodeURIComponent(PCB.name)+subq(),{method:"POST",headers:{"Content-Type":"application/json"},
    body:JSON.stringify({parts:P.map(function(q){return {ref:q.ref,x:q.x,y:q.y,rot:q.rot||0,side:q.side||"top",locked:!!q.locked};}),blame:true,refresh:p.ref})})
    .then(function(r){return r.json().then(function(j){if(!r.ok)throw new Error((j&&j.error)||"Could not refresh the board.");return {edit:edit,score:j};});});})
   .then(function(o){passiveRefreshApply(p,o.edit,o.score);}).catch(function(e){
    if(!saved){sel.value=p.component;sel.disabled=false;passiveFpMsg(e.message||"Footprint update failed.",true);}
    else passiveFpMsg("Source updated, but the live board refresh failed. Reload once to recover.",true);});});}
function outlineEntityRows(){if(!OS||!PCB.outline||!PCB.outline.sketch)return "";outlineResolveSelection();var sel=outlinePrimary();if(!sel||!sel.id)return "";
 var sk=PCB.outline.sketch,e=sel.type==="point"?OS.point(sk,sel.id):OS.curve(sk,sel.id),h='<div class="prop-head"><span class="prop-ref">'+(sel.type==="point"?'Sketch point':'Sketch '+(e&&e.kind||'curve'))+'</span><span class="prop-val">#'+sel.id+'</span></div><div class="prop-rows">';
 if(sel.type==="point"&&e)h+=pNumRow("X (mm)","prop-sketch-x",e.x,false)+pNumRow("Y (mm)","prop-sketch-y",e.y,false);
 else if(e){var a=OS.point(sk,e.a),b=OS.point(sk,e.b),len=Math.hypot(b.x-a.x,b.y-a.y);if(e.kind==="line")h+=pNumRow("Length (mm)","prop-sketch-length",len,false)+pNumRow("Angle (deg)","prop-sketch-angle",Math.atan2(b.y-a.y,b.x-a.x)*180/Math.PI,false);
  else{var g=OS.arcCircle(sk,e);h+=pNumRow("Radius (mm)","prop-sketch-radius",g?g.r:0,false)+pRow("Sweep",g?(g.sweep*180/Math.PI).toFixed(2)+"°":"invalid");}}
 h+='</div>';var qs=(sk.constraints||[]).filter(function(q){return q.a===sel.id||q.b===sel.id||q.c===sel.id;});if(qs.length)h+='<div class="prop-sketch-constraints">'+qs.map(function(q){return '<button type="button" data-rm-sk="'+q.id+'" title="Remove constraint">'+pEsc(q.kind)+(q.value!=null?' '+(+q.value).toFixed(3):'')+' ×</button>';}).join('')+'</div>';return h;}
function outlineDimSet(kind,id,value){return outlineSketchMutate(kind+" set to "+value,function(sk){var q=(sk.constraints||[]).find(function(x){return x.kind===kind&&x.a===id&&x.driving!==false;});if(q){q.value=value;return true;}return !!OS.addConstraint(sk,kind,id,null,value);});}
function wireOutlineEntityProps(body){if(!OS||!PCB.outline||!PCB.outline.sketch)return;outlineResolveSelection();var sel=outlinePrimary();if(!sel||!sel.id)return;var sk=PCB.outline.sketch,e=sel.type==="point"?OS.point(sk,sel.id):OS.curve(sk,sel.id);
 function enter(id,fn){var inp=document.getElementById(id);if(!inp)return;function go(){var n=parseFloat(inp.value);if(isFinite(n))fn(n);}inp.addEventListener("keydown",function(ev){if(ev.key==="Enter"){ev.preventDefault();go();inp.blur();}});inp.addEventListener("change",go);}
 if(sel.type==="point"&&e){enter("prop-sketch-x",function(n){outlineSketchMutate("point X set",function(s){var p=OS.point(s,sel.id);p.x=n;if(!(s.constraints||[]).some(function(q){return q.kind==="fixed"&&q.a===p.id;}))OS.addConstraint(s,"fixed",p.id);return true;});});
  enter("prop-sketch-y",function(n){outlineSketchMutate("point Y set",function(s){var p=OS.point(s,sel.id);p.y=n;if(!(s.constraints||[]).some(function(q){return q.kind==="fixed"&&q.a===p.id;}))OS.addConstraint(s,"fixed",p.id);return true;});});}
 else if(e){enter("prop-sketch-length",function(n){if(n>0)outlineDimSet("length",sel.id,n);});enter("prop-sketch-angle",function(n){outlineDimSet("angle",sel.id,n);});enter("prop-sketch-radius",function(n){if(n>0)outlineDimSet("radius",sel.id,n);});}
 body.querySelectorAll("[data-rm-sk]").forEach(function(b){b.addEventListener("click",function(){var id=+b.getAttribute("data-rm-sk");outlineSketchMutate("constraint removed",function(s){OS.removeConstraint(s,id);return true;});});});}
function renderProps(){var body=document.getElementById("prop-body");if(!body)return;
 if(insp){renderInspProps(body);return;}
 if(selGroup&&!selRef&&GRPS[selGroup]){var gn=GRPS[selGroup].length;
  var ginf=(PCB.subseedinfo||{})[selGroup],ghref=subLayoutHref(selGroup);
  body.innerHTML='<div class="prop-head"><span class="prop-ref">'+pEsc(selGroup)+'</span>'+
   '<span class="prop-val">'+gn+' parts</span></div>'+
   '<div class="prop-grp"><span class="grp-name">Sub-circuit selected</span>'+
   '<span class="grp-n">'+(mobileInspectMode()?'tap a component again to inspect it':
    'drag to move · R / Shift+R to rotate · click a component again to select it')+'</span></div>'+
   '<div class="prop-sec">Layout</div><div class="prop-grp">'+
   (ginf&&!RO?'<button class="btn grp-stamp" data-grp-stamp="'+pEsc(selGroup)+'" title="'+stampTitle(selGroup,ginf)+'">Stamp module layout</button>':'')+
   (!RO?'<button class="btn grp-save" data-grp-save="'+pEsc(selGroup)+'" title="Save this on-board arrangement as a new layout on the sub-circuit">Save to sub-circuit…</button>':'')+
   '<a class="btn grp-layout" href="'+ghref+'" target="_blank" rel="noopener" title="Open this sub-circuit on its own PCB-layout page">Open sub-circuit layout ↗</a>'+
   (!ginf?'<span class="grp-noseed" title="Open the sub-circuit layout, place its parts, then save a layout before stamping it here.">no saved layout to stamp</span>':'')+
   '</div>';
  var gsb=body.querySelector("[data-grp-stamp]");
  if(gsb)gsb.addEventListener("click",function(){if(stampGroupFn)stampGroupFn(gsb.getAttribute("data-grp-stamp"));});
  var gsv=body.querySelector("[data-grp-save]");
  if(gsv)gsv.addEventListener("click",function(){if(saveGroupFn)saveGroupFn(gsv.getAttribute("data-grp-save"));});
  return;}
 var p=selRef?partByRef(selRef):null;
 if(!p){var bo=PCB.outline||PCB.board,os=PCB.outline?'Layout override':'Design outline',aos=authoredOutlineSeed();
  var ors=PCB.outline&&PCB.outline.radii||aos&&aos.radii,orad=ors&&ors.length?Math.max.apply(null,ors):0;
  body.innerHTML='<div class="prop-head"><span class="prop-ref">Board outline</span></div>'+
   (bo?'<div class="prop-rows">'+(!RO&&!mobileInspectMode()?
    pNumRow("Width (mm)","prop-outline-width",bo.w,false)+pNumRow("Height (mm)","prop-outline-height",bo.h,false):
    pRow("Width",fmtLen(bo.w))+pRow("Height",fmtLen(bo.h)))+
    pRow("Source",os)+(!RO&&!mobileInspectMode()&&!((PCB.outline||{}).sketch)?pNumRow("Corner radius","prop-outline-radius",orad,false):"")+'</div>':'<div class="prop-empty">No board outline is defined.</div>')+
   (!RO&&!mobileInspectMode()?outlineEntityRows():"")+
   (!RO&&!mobileInspectMode()&&bo?'<button class="btn prop-outline-edit" type="button">Edit outline</button>'+
   '<div class="prop-edit-note">Type exact dimensions, drag geometry, or use Line to click connected segments; endpoints snap to corners, the start point, and horizontal/vertical inference. Box-select both ends of a fillet and press Delete to restore its sharp corner. Save or Update to keep the result.</div>':'')+
   '<div class="prop-empty-n">'+P.length+' components</div>';
  var oe=body.querySelector(".prop-outline-edit");if(oe)oe.addEventListener("click",function(){outlineArm(true);drawBoardRect();});
  var wi=document.getElementById("prop-outline-width"),hi=document.getElementById("prop-outline-height");
  function commitOutlineSize(){var w=parseFloat(wi&&wi.value),h=parseFloat(hi&&hi.value);
   if(!(w>=2)||!(h>=2)){if(wi)wi.value=Math.round(bo.w*1000)/1000;if(hi)hi.value=Math.round(bo.h*1000)/1000;
    outlineMsg("board width and height must each be at least 2 mm");return;}
   if(Math.abs(w-bo.w)<1e-9&&Math.abs(h-bo.h)<1e-9)return;
   outlineResize(w,h);renderProps();}
  [wi,hi].forEach(function(inp){if(!inp)return;
   inp.addEventListener("keydown",function(ev){if(ev.key==="Enter"){ev.preventDefault();commitOutlineSize();try{inp.blur();}catch(e){}}});
   inp.addEventListener("blur",commitOutlineSize);});
  var ri=document.getElementById("prop-outline-radius");if(ri)ri.addEventListener("change",function(){var radius=Math.max(0,parseFloat(ri.value)||0),pre=snapAll();
   outlineArm(true);outlinePromote();PCB.outline.sketch=null;PCB.outline.radii=PCB.outline.pts.map(function(){return radius;});if(OS)OS.ensure(PCB.outline);outlineGeomDrop();recordUndo(pre);drawBoardRect();scheduleDrc();
   outlineMsg("corner fillet set to "+fmtLen(radius)+" — Save/Update to keep");});wireOutlineEntityProps(body);return;}
 var rot=(((p.rot||0)%360)+360)%360,fpEdit=passiveFpEditable(p);
 var h='<div class="prop-head"><span class="prop-ref">'+pEsc(refLabel(p.ref))+'</span>'+
  (p.val?'<span class="prop-val">'+pEsc(p.val)+'</span>':'')+'</div>';
 if(!RO&&!mobileInspectMode()){
  h+='<div class="prop-rows">'+
   pNumRow("X (mm)","prop-x",p.x,p.locked)+
   pNumRow("Y (mm)","prop-y",p.y,p.locked)+
   pSelRow("Rotation","prop-rot",[["0","0°"],["45","45°"],["90","90°"],["135","135°"],["180","180°"],["225","225°"],["270","270°"],["315","315°"]],rot,p.locked)+
   pSelRow("Side","prop-side",[["top",sideLabel(false)],["bottom",sideLabel(true)]],(p.side==="bottom"?"bottom":"top"),p.locked)+
   (fpEdit?pSelRow("Footprint","prop-footprint",[[p.component,passiveFpLabel({name:p.component,footprint:p.fp})]],p.component,false):
    (p.kind==="passive"&&p.fp?pRow("Footprint",p.fp):""))+
   pRow("Type",(p.kind=="hub"?"Hub / IC":"Passive"))+'</div>';
  if(fpEdit)h+='<div class="prop-edit-note" id="prop-fp-msg">Changing this updates the schematic source and refreshes the part in place.</div>';
  if(p.locked)h+='<div class="prop-lock">🔒 Locked — press <kbd>L</kbd> over the part to unlock before editing.</div>';
 }else{
  h+='<div class="prop-rows">'+pRow("X",fmtLen(p.x),"prop-x")+pRow("Y",fmtLen(p.y),"prop-y")+
   pRow("Rotation",rot+"°","prop-rot")+pRow("Side",sideLabel(p.side==="bottom"),"prop-side")+
   pRow("Type",(p.kind=="hub"?"Hub / IC":"Passive")+(p.locked?" · 🔒 locked":""))+'</div>';
 }
 if(p.fp)h+='<button class="prop-fp" data-court-ref="'+pEsc(p.ref)+'" title="Open library card — datasheet, footprint editor, 3D model">▢ '+pEsc(p.fp)+'</button>';
 // Sub-circuit row: the part's group, and — when the module has a stampable
 // saved layout — the same Stamp the palette offers, so "pull the module's
 // layout" is reachable from the part itself.
 var pg=grpOf(p.ref);
 if(pg&&GRPS[pg]&&GRPS[pg].length>1){
  var pinf=(PCB.subseedinfo||{})[pg];
  var pname='<a class="grp-name" href="'+subLayoutHref(pg)+'" target="_blank" rel="noopener" title="Open this sub-circuit on its own PCB-layout page.">'+pEsc(pg)+'</a>';
  h+='<div class="prop-sec">Sub-circuit</div><div class="prop-grp">'+pname+
   '<span class="grp-n">'+GRPS[pg].length+' parts</span>'+
   (pinf&&!RO?'<button class="btn grp-stamp" data-grp-stamp="'+pEsc(pg)+'" title="'+stampTitle(pg,pinf)+'">Stamp module layout</button>':
    (pinf?'':'<span class="grp-noseed" title="No saved layout on the module matches its current parts — open the module’s own /pcb-layout page, lay it out and save (★ star it to pin the choice).">no saved module layout</span>'))+
   (!RO?'<button class="btn grp-save" data-grp-save="'+pEsc(pg)+'" title="Save this on-board arrangement as a new layout on the sub-circuit">Save to sub-circuit…</button>':'')+
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
 if(!RO&&!p.locked)wirePropInputs(p.ref);
 if(fpEdit)wirePassiveFootprint(p);
 var cb=body.querySelector("[data-court-ref]");
 if(cb)cb.addEventListener("click",function(){openFpCard(cb.getAttribute("data-court-ref"));});
 var gsb=body.querySelector("[data-grp-stamp]");
 if(gsb)gsb.addEventListener("click",function(){if(stampGroupFn)stampGroupFn(gsb.getAttribute("data-grp-stamp"));});
 var gsv=body.querySelector("[data-grp-save]");
 if(gsv)gsv.addEventListener("click",function(){if(saveGroupFn)saveGroupFn(gsv.getAttribute("data-grp-save"));});
 body.querySelectorAll(".pn[data-net]").forEach(function(e){var nn=e.getAttribute("data-net");
  if(!nn)return;e.style.cursor="pointer";
  if(nn===selNetCur)e.classList.add("net-sel");
  e.addEventListener("mouseenter",function(){hlBy("data-net",nn,"net-hl",true);});
  e.addEventListener("mouseleave",function(){hlBy("data-net",nn,"net-hl",false);});
  e.addEventListener("click",function(){selNet(nn);});});}
// Write a value into a prop-panel field whether it's an editable input/select
// (edit page) or a read-only span (RO preview). A focused field is left alone
// so a live drag never clobbers what the user is typing.
function setPropVal(id,v){var e=document.getElementById(id);if(!e)return;
 if(e.tagName==="INPUT"||e.tagName==="SELECT"){if(document.activeElement!==e)e.value=v;}
 else e.textContent=v;}
function updatePropLive(){if(!selRef)return;var p=partByRef(selRef);if(!p)return;
 var rot=((((p.rot||0)%360)+360)%360);
 setPropVal("prop-x",RO?fmtLen(p.x):(Math.round(p.x*1000)/1000));
 setPropVal("prop-y",RO?fmtLen(p.y):(Math.round(p.y*1000)/1000));
 setPropVal("prop-rot",RO?(rot+"°"):String(rot));
 setPropVal("prop-side",RO?sideLabel(p.side==="bottom"):(p.side==="bottom"?"bottom":"top"));}
// Commit numeric-position / rotation / side edits from the properties panel.
// X/Y set the EXACT pose (never grid-snapped — the whole point of typing a
// coordinate); rotation uses 45° increments; side mirrors the F-key path. Each edit records one
// undo and invalidates the part's copper the same way a drag does (commitMove).
function wirePropInputs(ref){
 var xi=document.getElementById("prop-x"),yi=document.getElementById("prop-y"),
  ri=document.getElementById("prop-rot"),si=document.getElementById("prop-side");
 function idxOf(){for(var i=0;i<P.length;i++)if(P[i].ref===ref)return i;return -1;}
 function commitXY(){var i=idxOf();if(i<0||P[i].locked)return;
  var nx=parseFloat(xi&&xi.value),ny=parseFloat(yi&&yi.value);
  if(isNaN(nx)||isNaN(ny)){updatePropLive();return;}
  if(nx===P[i].x&&ny===P[i].y)return;
  recordUndo();P[i].x=nx;P[i].y=ny;commitMove([i]);}
 [xi,yi].forEach(function(inp){if(!inp)return;
  inp.addEventListener("keydown",function(ev){if(ev.key==="Enter"){ev.preventDefault();commitXY();try{inp.blur();}catch(e){}}});
  inp.addEventListener("blur",commitXY);});
 if(ri)ri.addEventListener("change",function(){var i=idxOf();if(i<0||P[i].locked)return;
  recordUndo();P[i].rot=(((parseInt(ri.value,10)||0)%360)+360)%360;commitMove([i]);});
 if(si)si.addEventListener("change",function(){var i=idxOf();if(i<0||P[i].locked)return;
  recordUndo();P[i].side=(si.value==="bottom")?"bottom":"top";commitMove([i]);});}
function markSelPart(){paintSoon();}
// ── Left dock tabs (Properties / Autorouter / Sub-circuits) ─────────────
// One pane visible at a time. Selecting anything on the board raises the
// Properties tab and opening an accordion panel raises the Autorouter tab,
// so a click always lands on the pane that answers it. Every call is a no-op
// on surfaces without the dock (the read-only / editable embeds).
function pcbSideTab(id){var tabs=document.querySelectorAll(".side-tab[data-sidetab]");
 if(!tabs.length)return;
 if(id!=="side-find"&&window.PCBFindTabLeave)window.PCBFindTabLeave();
 tabs.forEach(function(t){var on=t.getAttribute("data-sidetab")===id;
  t.classList.toggle("active",on);t.setAttribute("aria-selected",on?"true":"false");});
 document.querySelectorAll(".side-pane").forEach(function(p){p.hidden=(p.id!==id);});
 if(compactDockMode())compactDockSet("side",true,id);
 if(mobileInspectMode())mobilePanelSet("info",true);}
(function(){document.querySelectorAll(".side-tab[data-sidetab]").forEach(function(t){
 t.addEventListener("click",function(){pcbSideTab(t.getAttribute("data-sidetab"));});});})();
function selectGroup(g,keepPane){if(!grpRigid(g))return false;selGroup=g;selRef=null;
 if(!keepPane)pcbSideTab("side-props");renderProps();markGrpRow();markSelPart();return true;}
function selectComp(ref,keepPane){var g=grpOf(ref);if(selGroup!==g)selGroup=null;selRef=ref;
 if(!keepPane)pcbSideTab("side-props");renderProps();markGrpRow();markSelPart();xpSend(ref);}
function clearSel(){if(!selRef&&!selGroup)return;selRef=null;selGroup=null;
 renderProps();markGrpRow();markSelPart();}
// A stationary press on the board outline itself — an edge or a corner
// handle — selects the board: clear every part/copper/inspector selection
// and raise the Board outline panel (Width/Height/Source/Corner radius +
// Edit outline). The edge/vertex drag the press armed never moved, so the
// pointerup handlers route the click here instead of swallowing it.
function showOutlineProps(){inspClear();selCuClear();selClear();selNet(null);
 selRef=null;selGroup=null;
 pcbSideTab("side-props");renderProps();markGrpRow();markSelPart();}
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
var stampGroupFn=null,saveGroupFn=null;
// Selecting a part lights its sub-circuit's row in the sidebar palette (and
// scrolls it into view), so board and palette stay cross-referenced.
function markGrpRow(){var g=selGroup||(selRef?grpOf(selRef):null),hit=null;
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
// A reusable module owns its own PCB-layout page. Path/inline sub-circuits do
// not, so their editor is the parent design's ?sub= slice instead. Keep this
// decision shared by every sub-circuit link in the board editor.
function subLayoutHref(g){var mod=(PCB.submodules||{})[g]||"";
 if(mod&&mod.indexOf("/")<0&&!/\.sexp$/i.test(mod))return "/pcb-layout/"+encodeURIComponent(mod);
 return "/pcb-layout/"+encodeURIComponent(PCB.name)+"?sub="+encodeURIComponent(g);}
var rigidOffKey="pcb-rigid-off:"+PCB.name, rigidOff={};
try{rigidOff=JSON.parse(localStorage.getItem(rigidOffKey)||"{}")||{};}catch(e){}
function rigidSave(){try{localStorage.setItem(rigidOffKey,JSON.stringify(rigidOff));}catch(e){}}
function grpRigid(g){return !!(g&&GRPS[g]&&GRPS[g].length>1&&!rigidOff[g]);}
function grpIdxs(i){var g=grpOf(P[i].ref);return grpRigid(g)?GRPS[g]:null;}
// Rigid-group box hit-test, including the empty space between its components.
// Smallest box wins if two groups overlap, matching partAt's nested-hit rule.
function grpAt(wx,wy){var best=null,ba=1e18,pad=3/S;
 for(var g in GRPS){if(!grpRigid(g))continue;var x0=1e18,y0=1e18,x1=-1e18,y1=-1e18,n=0;
  GRPS[g].forEach(function(i){if(unplacedSet[P[i].ref]||!partOnVisibleFace(P[i]))return;var b=partAABB(i);
   x0=Math.min(x0,b.x0);y0=Math.min(y0,b.y0);x1=Math.max(x1,b.x1);y1=Math.max(y1,b.y1);n++;});
  if(!n||wx<x0-pad||wx>x1+pad||wy<y0-pad||wy>y1+pad)continue;
  var ar=(x1-x0)*(y1-y0);if(ar<ba){ba=ar;best=g;}}
 return best;}
function grpToggle(g){if(!GRPS[g])return;rigidOff[g]=!rigidOff[g];if(!rigidOff[g])delete rigidOff[g];
 ovsRev++; // rigid/exploded changes the group box's dash — baked artwork
 if(rigidOff[g]&&selGroup===g){selGroup=null;renderProps();markGrpRow();markSelPart();}
 rigidSave();subPanelRefresh();}
function grpHl(g,on){hoverGrpName=on?g:null;paintSoon();}
// These helpers also serve read-only board gestures. Keep them outside the
// editor-only block below: a block-scoped function declaration is `undefined`
// when `RO` skips that block, which used to abort every assembly click and
// middle-button pan at pointerdown.
function kbTyping(t){if(!t)return false;if(t.isContentEditable||t.tagName=="TEXTAREA")return true;
 return t.tagName=="INPUT"&&!/^(checkbox|radio|button|submit|reset|range|color|file)$/i.test(t.type||"text");}
function focusBoardShortcuts(){var a=document.activeElement;
 if(a&&kbTyping(a)){try{a.blur();}catch(e){}}}
if(!RO){
var drag=null, gdrag=null;
var PART_DRAG_SLOP_PX=5;
function dragStart(i,m){return {i:i,x0:P[i].x,y0:P[i].y,m0:m,active:false,snap:snapAll()};}
// A part press remains a click until it travels a visible screen distance.
// This filters mouse/touchpad jitter before any placement coordinate changes.
function partDragReady(d,m){if(d.active)return true;var a=d.m0||{x:d.sx,y:d.sy};
 if(Math.hypot(m.x-a.x,m.y-a.y)<pxTolMm(PART_DRAG_SLOP_PX))return false;
 d.active=true;svg.style.cursor="grabbing";return true;}
function dragSnapPose(d,m,g){return {x:d.x0+Math.round((m.x-d.m0.x)/g)*g,
 y:d.y0+Math.round((m.y-d.m0.y)/g)*g};}
// Multi-select (marquee): sel = part indices currently box-selected; a drag
// on any selected part moves the whole set. Painted purple vs the blue .sel.
var sel=[];
function markSel(){paintSoon();}
function selSet(idxs){sel=visiblePartIdxs(idxs);markSel();refreshAlignBar();}
function selClear(){if(!sel.length)return;sel=[];markSel();refreshAlignBar();}
// A face/layer visibility change also retires interaction state that points at
// the face which just disappeared. This keeps an old selection from remaining
// keyboard-movable after the user switches from Front to Back (or vice versa).
function partInteractionVisibilitySync(){if(RO)return;var changed=false;
 if(cur>=0&&!partOnVisibleFace(P[cur])){cur=-1;changed=true;}
 if(hoverGrpName&&!visiblePartIdxs(GRPS[hoverGrpName]).length){hoverGrpName=null;changed=true;}
 var next=visiblePartIdxs(sel);if(next.length!==sel.length){sel=next;changed=true;}
 if(selRef){var si=P.findIndex(function(p){return p.ref===selRef;});
  if(si<0||!partOnVisibleFace(P[si])){selRef=null;changed=true;}}
 if(selGroup&&!visiblePartIdxs(GRPS[selGroup]).length){selGroup=null;changed=true;}
 if(typeof padAlignA!=="undefined"&&padAlignA&&!partOnVisibleFace(P[padAlignA.i])){padAlignA=null;padAlignB=null;changed=true;}
 if(changed){renderProps();markGrpRow();refreshAlignBar();padAlignRefresh();markSelPart();}}
function selectionMod(ev){return !!(ev&&(ev.ctrlKey||ev.metaKey));}
// A plain click uses the richer Properties selection (`selRef` / `selGroup` /
// `insp`), while a modifier click uses the marquee arrays below. Promote that
// first plain-click selection before toggling so the familiar workflow — click
// one item, hold Ctrl/Cmd, click more — does not silently drop the first item.
function selectionSeed(){var ps=sel.slice(),ts=selCu.t.slice(),vs=selCu.v.slice();
 if(selRef){var pi=P.findIndex(function(p){return p.ref===selRef;});
  if(pi>=0&&ps.indexOf(pi)<0)ps.push(pi);}
 else if(selGroup&&GRPS[selGroup])GRPS[selGroup].forEach(function(i){if(ps.indexOf(i)<0)ps.push(i);});
 if(insp&&insp.t==="track"&&ts.indexOf(insp.o)<0)ts.push(insp.o);
 if(insp&&insp.t==="via"&&vs.indexOf(insp.o)<0)vs.push(insp.o);
 return {p:ps,t:ts,v:vs};}
function selectionCommit(seed){inspClear();clearSel();selSet(seed.p);selCuTo(seed.t,seed.v);paintSoon();selNet(null);
 if(seed.t.length===2&&!seed.v.length&&!seed.p.length)routeStatMsg("2 tracks selected — right-click for Fillet…");}
// Ctrl/Cmd-click shares the marquee's selection state instead of growing a
// second kind of multi-selection. A rigid sub-circuit toggles as one item: if
// every member is already selected the click removes all of them, otherwise it
// adds every missing member. Standalone footprints pass a one-index list.
function selectionToggleParts(idxs){var seed=selectionSeed(),all=true,next=seed.p;
 idxs=visiblePartIdxs(idxs);
 idxs.forEach(function(i){if(next.indexOf(i)<0)all=false;});
 if(all)next=next.filter(function(i){return idxs.indexOf(i)<0;});
 else idxs.forEach(function(i){if(next.indexOf(i)<0)next.push(i);});
 seed.p=next;selectionCommit(seed);}
// Tracks and vias join the same mixed selection, so a later group drag carries
// them and Del can rip up all selected copper just as if a marquee caught it.
function selectionToggleCopper(hit){var seed=selectionSeed(),ts=seed.t,vs=seed.v;
 var arr=hit.t==="track"?ts:vs,at=arr.indexOf(hit.o);
 if(at>=0)arr.splice(at,1);else arr.push(hit.o);
 selectionCommit(seed);}
// Resolve a modifier click with the normal hit precedence. Intact rigid groups
// beat coincident copper; standalone pads beat copper; bare tracks/vias remain
// individually selectable. Empty Ctrl/Cmd-click deliberately preserves the
// accumulated selection.
function selectionToggleAt(ev,m){
 var hi=viewSt.filt.fp?partAt(m.x,m.y):-1,cg=hi>=0?grpOf(P[hi].ref):null;
 if(hi>=0&&viewSt.filt.sub&&cg&&grpRigid(cg)){selectionToggleParts(GRPS[cg]);return;}
 if(hi<0&&viewSt.filt.sub){var gh=grpAt(m.x,m.y);
  if(gh){selectionToggleParts(GRPS[gh]);return;}}
 var hit=hi>=0?inspHitForPart(m,hi):inspHit(m);
 if(hit&&(hit.t==="track"||hit.t==="via")){selectionToggleCopper(hit);return;}
 if(hit){inspShow(hit,ev);return;}
 if(hi>=0)selectionToggleParts([hi]);}
// ── Copper clipboard ───────────────────────────────────────────────────
// Ctrl/Cmd+C copies only the copper in the shared selection: a lone inspected
// track/via is promoted by selectionSeed(), while a marquee/modifier selection
// contributes all of its tracks and vias. The text form lets another board tab
// receive it through the system clipboard; cuClipboard is the permission-free
// fallback browsers need when navigator.clipboard is unavailable or denied.
var CU_CLIP_PREFIX="netlisp-pcb-copper-v1:",cuClipboard=null,cuClipboardText="",cuPasteCount=0;
function copperClipTrack(t){return {x1:+t.x1,y1:+t.y1,xm:t.xm==null?null:+t.xm,ym:t.ym==null?null:+t.ym,
 x2:+t.x2,y2:+t.y2,l:+(t.l||0),w:+(t.w||0.25),net:String(t.net||"")};}
function copperClipVia(v){var q={x:+v.x,y:+v.y,d:+(v.d||0.4),drill:+(v.drill||0),net:String(v.net||"")};
 if(Array.isArray(v.s)&&v.s.length===2)q.s=[+v.s[0],+v.s[1]];return q;}
function copperClipboardSelection(){var seed=selectionSeed(),seen=new Set(),ts=[],vs=[];
 seed.t.forEach(function(t){if(!seen.has(t)&&(PCB.tracks||[]).indexOf(t)>=0){seen.add(t);ts.push(copperClipTrack(t));}});
 seed.v.forEach(function(v){if(!seen.has(v)&&(PCB.vias||[]).indexOf(v)>=0){seen.add(v);vs.push(copperClipVia(v));}});
 return {tracks:ts,vias:vs};}
function copperClipboardEncode(cu){return CU_CLIP_PREFIX+JSON.stringify({tracks:cu.tracks,vias:cu.vias});}
function copperClipboardDecode(text){if(typeof text!=="string"||text.indexOf(CU_CLIP_PREFIX)!==0||text.length>1000000)return null;
 var q;try{q=JSON.parse(text.slice(CU_CLIP_PREFIX.length));}catch(e){return null;}
 if(!q||!Array.isArray(q.tracks)||!Array.isArray(q.vias)||q.tracks.length+q.vias.length<1||q.tracks.length+q.vias.length>10000)return null;
 function num(n){return typeof n==="number"&&isFinite(n);}
 var ts=[],vs=[];
 for(var i=0;i<q.tracks.length;i++){var t=q.tracks[i];
  if(!t||!num(t.x1)||!num(t.y1)||!num(t.x2)||!num(t.y2)||!num(t.l)||t.l<0||t.l>=NSIG||Math.floor(t.l)!==t.l||!num(t.w)||t.w<=0||t.w>100||typeof t.net!=="string"||t.net.length>512)return null;
  if((t.xm==null)!==(t.ym==null)||(t.xm!=null&&(!num(t.xm)||!num(t.ym))))return null;ts.push(copperClipTrack(t));}
 for(var j=0;j<q.vias.length;j++){var v=q.vias[j];
  if(!v||!num(v.x)||!num(v.y)||!num(v.d)||v.d<=0||v.d>100||!num(v.drill)||v.drill<0||v.drill>v.d||typeof v.net!=="string"||v.net.length>512)return null;
  if(v.s!=null&&(!Array.isArray(v.s)||v.s.length!==2||!num(v.s[0])||!num(v.s[1])||Math.floor(v.s[0])!==v.s[0]||Math.floor(v.s[1])!==v.s[1]||v.s[0]<0||v.s[1]>=NSIG||v.s[0]>=v.s[1]))return null;vs.push(copperClipVia(v));}
 return {tracks:ts,vias:vs};}
function copperCopy(){var cu=copperClipboardSelection(),n=cu.tracks.length+cu.vias.length;if(!n){routeStatMsg("select a trace or via to copy",true);return false;}
 cuClipboard=cu;cuClipboardText=copperClipboardEncode(cu);cuPasteCount=0;
 if(navigator.clipboard&&navigator.clipboard.writeText)navigator.clipboard.writeText(cuClipboardText).catch(function(){});
 routeStatMsg("copied "+cu.tracks.length+" track"+(cu.tracks.length===1?"":"s")+" · "+cu.vias.length+" via"+(cu.vias.length===1?"":"s"));return true;}
function copperPaste(text){var cu=copperClipboardDecode(text);
 if(cu){if(text!==cuClipboardText)cuPasteCount=0;cuClipboard=cu;cuClipboardText=copperClipboardEncode(cu);}
 else cu=cuClipboard;
 if(!cu){routeStatMsg("copy a trace or via before pasting",true);return false;}
 // Each paste steps one current grid interval down/right. Exact in-place
 // duplication is visually indistinguishable and leaves overlapping records;
 // the offset makes the new, still-selected copper immediately draggable.
 var d=Math.max(snapG(),0.01)*(++cuPasteCount),nt=cu.tracks.map(function(t){return {x1:t.x1+d,y1:t.y1+d,xm:t.xm==null?undefined:t.xm+d,ym:t.ym==null?undefined:t.ym+d,
  x2:t.x2+d,y2:t.y2+d,l:t.l,w:t.w,net:t.net,source:"human",id:trackIdNew()};}),
 nv=cu.vias.map(function(v){var q={x:v.x+d,y:v.y+d,d:v.d,drill:v.drill,net:v.net,source:"human",id:viaIdNew()};if(v.s)q.s=v.s.slice();return q;}),
 bt=PCB.tracks||[],bv=PCB.vias||[],at=bt.concat(nt),av=bv.concat(nv);
 if(drcGateDiffBlocks(bt,bv,at,av)){cuPasteCount--;routeStatMsg("paste would create a DRC error",true);return false;}
 recordUndo();PCB.tracks=at;PCB.vias=av;copperTouched();selClear();clearSel();selCuTo(nt,nv);drawRoute();scheduleDrc();paintSoon();
 routeStatMsg("pasted "+nt.length+" track"+(nt.length===1?"":"s")+" · "+nv.length+" via"+(nv.length===1?"":"s")+" — selected and ready to move");return true;}
function copperPasteShortcut(){function use(text){copperPaste(text);}
 if(navigator.clipboard&&navigator.clipboard.readText)navigator.clipboard.readText().then(use,function(){use("");});else use("");}
// Capture ahead of the document's tool shortcuts: Ctrl/Cmd+V must never also
// become the bare V via/layer/outline command. Text controls retain the native
// operating-system clipboard, and read-only review pages never intercept it.
window.addEventListener("keydown",function(ev){if(RO||kbTyping(ev.target)||!(ev.ctrlKey||ev.metaKey)||ev.altKey)return;
 var k=(ev.key||"").toLowerCase();if(k!=="c"&&k!=="v")return;if(anyDrawTool())return;
 ev.preventDefault();ev.stopImmediatePropagation();if(k==="c")copperCopy();else copperPasteShortcut();},true);
// Pad-to-pad RF alignment.
// Dedicated mode avoids the normal hierarchical group/copper click priority:
// the click names an exact pad. Source ownership is stronger than the current
// rigid/exploded display choice — a pad under a sub-circuit always moves that
// whole sub-circuit, which is the invariant this tool promises.
function padAlignOwner(hit){var g=grpOf(P[hit.i].ref),idxs=visiblePartIdxs((g&&GRPS[g])?GRPS[g]:[hit.i]);
 return {g:g,idxs:idxs,label:g?("sub-circuit "+g+" ("+idxs.length+" parts)"):refLabel(P[hit.i].ref)};}
function padAlignLabel(hit){if(!hit)return "not selected";var pd=hit.pd,p=P[hit.i];
 return refLabel(p.ref)+" · pad "+(pd.num||"?")+(pd.net?(" · "+nLeaf(pd.net)):"");}
function padAlignStatus(text,bad){var e=document.getElementById("pad-align-note");
 if(e){e.textContent=text;e.classList.toggle("bad",!!bad);}toolSync();}
function padAlignRefresh(){var bar=document.getElementById("pad-align-bar");if(!bar)return;
 bar.hidden=!padAlignMode;
 var a=document.getElementById("pad-align-source"),b=document.getElementById("pad-align-target");
 if(a)a.textContent=padAlignLabel(padAlignA);if(b)b.textContent=padAlignLabel(padAlignB);
 bar.querySelectorAll("[data-pad-axis]").forEach(function(x){x.disabled=!(padAlignA&&padAlignB);});
 if(padAlignMode&&!padAlignA)padAlignStatus("1. Click the pad whose owner should move.");
 else if(padAlignMode&&!padAlignB)padAlignStatus("2. Click the fixed target pad.");
 else if(padAlignMode)padAlignStatus("Choose Same X for a vertical run or Same Y for a horizontal run.");}
function padAlignArm(on){if(RO&&on)return;
 if(on&&heatsinkMode)heatsinkArm(false);
 if(on){if(drawMode)drawModeSet(false);if(textMode)txArm(false);if(polyMode)polyArm(false);
  if(outlineMode)outlineArm(false);if(pourMode)pourArm(false);if(backingMode)backingArm(false);if(PCB.rulerOff)PCB.rulerOff();}
 padAlignMode=!!on;padAlignA=null;padAlignB=null;
 var btn=document.getElementById("pcb-pad-align");if(btn)btn.classList.toggle("on",padAlignMode);
 svg.classList.toggle("pad-align-mode",padAlignMode);svg.style.cursor=padAlignMode?"crosshair":"";
 padAlignRefresh();dragCacheDrop();paintSoon();toolSync();}
function padAlignPick(m){var hit=padHitAt(m.x,m.y);
 if(!hit){padAlignStatus(viewSt.filt.pad?"No visible pad under the cursor.":"Pad selection is disabled in Objects.",true);return;}
 if(!padAlignA){var owner=padAlignOwner(hit),locked=owner.idxs.some(function(i){return P[i].locked;});
  if(locked){padAlignStatus("Unlock "+owner.label+" before aligning it.",true);return;}
  padAlignA=hit;padAlignB=null;padAlignRefresh();paintSoon();return;}
 var moving=padAlignOwner(padAlignA);
 if(moving.idxs.indexOf(hit.i)>=0){padAlignStatus("Choose a target outside "+moving.label+".",true);return;}
 padAlignB=hit;padAlignRefresh();paintSoon();}
function padAlignApply(axis){if(!padAlignA||!padAlignB)return;
 var owner=padAlignOwner(padAlignA),source=wpt(padAlignA.i,padAlignA.pd.x,padAlignA.pd.y),
  target=wpt(padAlignB.i,padAlignB.pd.x,padAlignB.pd.y),dx=axis==="x"?target.x-source.x:0,
  dy=axis==="y"?target.y-source.y:0;
 if(owner.idxs.some(function(i){return P[i].locked;})){padAlignStatus("Unlock "+owner.label+" before aligning it.",true);return;}
 if(Math.abs(dx)+Math.abs(dy)<1e-9){padAlignStatus("Those pads already share the same "+axis.toUpperCase()+" coordinate.");return;}
 var srcLabel=padAlignLabel(padAlignA),targetLabel=padAlignLabel(padAlignB),snap=snapAll();
 // One rigid translation of the whole owner, copper included — the same carry
 // rule a drag uses (stamped group copper + the nets private to the owner).
 var moved=moveEntities([{idxs:owner.idxs,g:owner.g}],[{dx:dx,dy:dy}]);
 recordUndo(snap);commitMove(moved);padAlignArm(false);
 var msg=document.getElementById("pcb-savemsg");if(msg){msg.style.color="#7ee787";
  msg.textContent="aligned "+srcLabel+" to "+targetLabel+" · same "+axis.toUpperCase();}}
var padAlignBtn=document.getElementById("pcb-pad-align");if(padAlignBtn)padAlignBtn.addEventListener("click",function(){padAlignArm(!padAlignMode);});
var padAlignCancel=document.getElementById("pad-align-cancel");if(padAlignCancel)padAlignCancel.addEventListener("click",function(){padAlignArm(false);});
var padAlignRestart=document.getElementById("pad-align-restart");if(padAlignRestart)padAlignRestart.addEventListener("click",function(){padAlignA=null;padAlignB=null;padAlignRefresh();paintSoon();});
document.querySelectorAll("[data-pad-axis]").forEach(function(b){b.addEventListener("click",function(){padAlignApply(b.getAttribute("data-pad-axis"));});});
// ── Multi-select align / distribute ─────────────────────────────────────
// With ≥2 parts marquee-selected the sidebar Align cluster lights up. Each
// button records ONE undo and moves the selection, treating a rigid sub-circuit
// as a single unit (its whole member set translates together) and skipping
// locked parts. Align uses courtyard-box edges; distribute evens out origin
// spacing between the two extremes.
function selEntities(){var claimed={},ents=[];
 sel.forEach(function(i){if(P[i].locked||!partOnVisibleFace(P[i]))return;
  var g=grpIdxs(i); // rigid-group member indices, or null for a lone part
  if(g){var key=grpOf(P[i].ref);if(claimed[key])return;claimed[key]=1;
   var idxs=g.filter(function(k){return !P[k].locked&&partOnVisibleFace(P[k]);});
   if(idxs.length)ents.push({idxs:idxs,g:key});} // g: whose stamped copper rides
  else ents.push({idxs:[i],g:null});});
 return ents;}
function entBox(e){var x0=1e18,y0=1e18,x1=-1e18,y1=-1e18,sx=0,sy=0;
 e.idxs.forEach(function(i){var b=partAABB(i);
  x0=Math.min(x0,b.x0);y0=Math.min(y0,b.y0);x1=Math.max(x1,b.x1);y1=Math.max(y1,b.y1);
  sx+=P[i].x;sy+=P[i].y;});
 return {x0:x0,y0:y0,x1:x1,y1:y1,cx:(x0+x1)/2,cy:(y0+y1)/2,ox:sx/e.idxs.length,oy:sy/e.idxs.length};}
// After any panel-driven move: refresh ratsnest / clearance / score / staging,
// repaint, re-DRC. Copper the move CARRIED has already been translated by
// moveEntities; copper left behind (a rail, a bus leaving the block) shows up
// as an airwire/DRC finding instead of being destructively deleted.
function commitMove(idxs){if(!idxs.length)return;
 ratsUpdate(idxs);drawClr();fetchScore();refreshUnplaced();
 dragCacheDrop();paintSoon();scheduleDrc();updatePropLive();
 if(window.PCB3D&&window.PCB3D.sync)window.PCB3D.sync();}
// Translate a carried-copper set in place — the panel-move twin of the drag's
// per-frame translate.
function shiftCopper(cu,dx,dy){
 cu.t.forEach(function(t){t.x1+=dx;t.y1+=dy;if(t.xm!=null){t.xm+=dx;t.ym+=dy;}t.x2+=dx;t.y2+=dy;});
 cu.v.forEach(function(v){v.x+=dx;v.y+=dy;});
 (cu.z||[]).forEach(function(z){(z.poly||[]).forEach(function(p){p[0]+=dx;p[1]+=dy;});});
 if((cu.z||[]).length){pourGeomDrop();dragCacheDrop();markPoursStale();}}
// Move entities, each by its OWN delta, carrying each one's copper (its stamped
// group copper + the nets private to it). A band selection is deliberately not
// consulted here: align/distribute reflows entities independently, so a banded
// track spanning two of them has no single delta to follow — only copper with
// an unambiguous owner rides. `banded` opts the marquee band INTO the carry:
// the move-by-distance command translates every entity by ONE shared delta, so
// a banded track spanning two of them follows the group rigidly — the case
// align/distribute refuse. The claim set spans the whole operation, so no
// object is ever translated twice when two entities could both claim it.
function moveEntities(ents,deltas,banded){var claimed=new Set(),moved=[],ncu=0;
 var band=banded?selCuCopper():null;
 ents.forEach(function(e,k){var d=deltas[k];if(!d||(!d.dx&&!d.dy))return;
  var cu=carriedCopper(e.idxs,e.g,false),t=[],v=[],z=[];
  if(band){band.t.forEach(function(o){if(!claimed.has(o)){claimed.add(o);t.push(o);}});
   band.v.forEach(function(o){if(!claimed.has(o)){claimed.add(o);v.push(o);}});}
  cu.t.forEach(function(o){if(!claimed.has(o)){claimed.add(o);t.push(o);}});
  cu.v.forEach(function(o){if(!claimed.has(o)){claimed.add(o);v.push(o);}});
  cu.z.forEach(function(o){if(!claimed.has(o)){claimed.add(o);z.push(o);}});
  e.idxs.forEach(function(i){P[i].x+=d.dx;P[i].y+=d.dy;moved.push(i);});
  shiftCopper({t:t,v:v,z:z},d.dx,d.dy);ncu+=t.length+v.length+z.length;});
 if(ncu)copperMoved();
 return moved;}
function alignSel(mode){var ents=selEntities();if(ents.length<2)return;
 var boxes=ents.map(entBox),uL=1e18,uR=-1e18,uT=1e18,uB=-1e18;
 boxes.forEach(function(b){uL=Math.min(uL,b.x0);uR=Math.max(uR,b.x1);uT=Math.min(uT,b.y0);uB=Math.max(uB,b.y1);});
 var midX=(uL+uR)/2,midY=(uT+uB)/2;
 recordUndo();
 var deltas=ents.map(function(e,k){var b=boxes[k],dx=0,dy=0;
  if(mode==="left")dx=uL-b.x0;else if(mode==="right")dx=uR-b.x1;
  else if(mode==="top")dy=uT-b.y0;else if(mode==="bottom")dy=uB-b.y1;
  else if(mode==="cx")dx=midX-b.cx;else if(mode==="cy")dy=midY-b.cy;
  return {dx:dx,dy:dy};});
 commitMove(moveEntities(ents,deltas));}
function distributeSel(axis){var ents=selEntities();if(ents.length<3)return;
 var boxes=ents.map(entBox);
 var order=ents.map(function(e,k){return k;}).sort(function(a,b){
  return axis==="h"?(boxes[a].ox-boxes[b].ox):(boxes[a].oy-boxes[b].oy);});
 var n=order.length,c0=axis==="h"?boxes[order[0]].ox:boxes[order[0]].oy,
  c1=axis==="h"?boxes[order[n-1]].ox:boxes[order[n-1]].oy;
 recordUndo();
 var deltas=ents.map(function(){return {dx:0,dy:0};});
 order.forEach(function(ei,rank){if(rank===0||rank===n-1)return;
  var target=c0+(c1-c0)*rank/(n-1),cur=axis==="h"?boxes[ei].ox:boxes[ei].oy,d=target-cur;
  if(axis==="h")deltas[ei].dx=d;else deltas[ei].dy=d;});
 commitMove(moveEntities(ents,deltas));}
// Show the Align cluster (and its live count) only when a multi-selection can
// use it; distribute needs three movable entities.
function refreshAlignBar(){var bar=document.getElementById("align-bar");if(!bar)return;
 if(sel.length>=2){bar.hidden=false;
  var ents=selEntities();
  var n=document.getElementById("align-n");if(n)n.textContent=sel.length+" parts selected";
  bar.querySelectorAll("[data-distribute]").forEach(function(b){b.disabled=ents.length<3;});
  bar.querySelectorAll("[data-align]").forEach(function(b){b.disabled=ents.length<2;});}
 else bar.hidden=true;}
// Zoom the viewport to frame the current selection (Shift+F). Falls back to a
// full Fit when nothing is selected. Plain Fit (button) is unchanged.
function zoomToSel(){var idxs=sel.slice();
 if(!idxs.length&&selRef){var si=-1;for(var i=0;i<P.length;i++)if(P[i].ref===selRef){si=i;break;}if(si>=0)idxs=[si];}
 if(!idxs.length){fitVB();return;}
 var x0=1e18,y0=1e18,x1=-1e18,y1=-1e18;
 idxs.forEach(function(i){var b=partAABB(i);x0=Math.min(x0,b.x0);y0=Math.min(y0,b.y0);x1=Math.max(x1,b.x1);y1=Math.max(y1,b.y1);});
 var sx0=X(x0),sy0=Y(y0),sx1=X(x1),sy1=Y(y1);
 var w=Math.max(sx1-sx0,VBW*0.02),h=Math.max(sy1-sy0,VBW*0.02);
 w*=1.36;h*=1.36; // ~18% margin each side
 var cx=(sx0+sx1)/2,cy=(sy0+sy1)/2,far=hostAspect();
 if(h/w<far)h=w*far;else w=h/far; // match the stage aspect
 vb={x:cx-w/2,y:cy-h/2,w:w,h:h};setVB();paintSoon();}
// Frame one world-space polygon. Save errors use this to take the user to the
// exact malformed copper area instead of leaving them to hunt across the board.
function zoomToPoly(pts){if(!pts||!pts.length)return;var x0=1e18,y0=1e18,x1=-1e18,y1=-1e18;
 pts.forEach(function(p){x0=Math.min(x0,+p[0]);y0=Math.min(y0,+p[1]);x1=Math.max(x1,+p[0]);y1=Math.max(y1,+p[1]);});
 var sx0=X(x0),sy0=Y(y0),sx1=X(x1),sy1=Y(y1),w=Math.max(Math.abs(sx1-sx0),VBW*.02),h=Math.max(Math.abs(sy1-sy0),VBW*.02);
 w*=1.8;h*=1.8;var cx=(sx0+sx1)/2,cy=(sy0+sy1)/2,far=hostAspect();if(h/w<far)h=w*far;else w=h/far;
 vb={x:cx-w/2,y:cy-h/2,w:w,h:h};setVB();paintSoon();}
// Wire the Align cluster buttons + select-all / zoom-to-selection keys.
(function(){
 document.querySelectorAll("#align-bar [data-align]").forEach(function(b){
  b.addEventListener("click",function(){alignSel(b.getAttribute("data-align"));});});
 document.querySelectorAll("#align-bar [data-distribute]").forEach(function(b){
  b.addEventListener("click",function(){distributeSel(b.getAttribute("data-distribute"));});});
 refreshAlignBar();})();
document.addEventListener("keydown",function(ev){if(kbTyping(ev.target))return;
 if((ev.ctrlKey||ev.metaKey)&&(ev.key==="a"||ev.key==="A")){ev.preventDefault();
  // Select-all honours the Objects tab exactly like the marquee, so
  // "Footprints off" + Ctrl+A + Del is the whole-board copper rip-up.
  var all=[];if(viewSt.filt.fp)P.forEach(function(p,i){if(!p.locked&&partOnVisibleFace(p))all.push(i);});
  var at=[],av=[];
  if(!RO&&!anyDrawTool()){
   if(viewSt.filt.track)(PCB.tracks||[]).forEach(function(t){if(layerAlpha(t.l||0)>0)at.push(t);});
   if(viewSt.filt.via&&anyCopperVisible())(PCB.vias||[]).forEach(function(v){av.push(v);});}
  clearSel();selSet(all);selCuTo(at,av);marqReport(at.length,av.length);selNet(null);return;}
 if(ev.key==="F"&&ev.shiftKey&&!ev.ctrlKey&&!ev.metaKey){ev.preventDefault();zoomToSel();return;}});
// ── Copper a multi-part gesture carries ─────────────────────────────────
// Moving several parts at once and leaving their routing behind strands the
// copper at coordinates that no longer mean anything. Three sources decide
// what travels with the set:
//  · a rigid sub-circuit's stamped copper (tagged t.g by Stamp),
//  · the tracks/vias a marquee band explicitly selected,
//  · copper on any net PRIVATE to the moving parts — every pad of that net is
//    moving, so nothing stationary is attached and the copper can travel
//    rigidly and stay electrically intact. This is what carries autorouted /
//    hand-drawn copper, which has no group tag at all.
// Copper on a net that also lands on a part staying put (a rail, GND, a bus
// leaving the block) is left where it is: moving it would tear the far end.
// Ratsnest + DRC then show exactly what still needs rerouting.
function selCuCopper(){return {t:selCu.t.slice(),v:selCu.v.slice(),z:[]};}
function grpCopper(g){return {t:(PCB.tracks||[]).filter(function(t){return t.g===g;}),
 v:(PCB.vias||[]).filter(function(v){return v.g===g;}),
 z:(PCB.zones||[]).filter(function(z){return z.g===g;})};}
// A user-zone's visible solid copper lives in zone_fills, keyed back to the
// raw PCB.zones boundary by numeric index. Carry both during a rigid drag: the
// boundary is the saved authority, while the fill is what the user actually
// sees under the pointer until drop-time refill re-carves it around the board.
function zoneFillsFor(zones){var own={},all=PCB.zones||[];
 (zones||[]).forEach(function(z){var i=all.indexOf(z);if(i>=0)own[i]=1;});
 return (PCB.zone_fills||[]).filter(function(f){return !!own[f.zone];});}
function privateNets(idxs){var mv={};idxs.forEach(function(i){mv[i]=1;});
 var all={},mine={};
 P.forEach(function(p,i){(p.pads||[]).forEach(function(pd){if(!pd.net)return;
  all[pd.net]=(all[pd.net]||0)+1;if(mv[i])mine[pd.net]=(mine[pd.net]||0)+1;});});
 var priv={},n=0;for(var k in mine)if(mine[k]===all[k]){priv[k]=1;n++;}
 return n?priv:null;}
function privateCopper(idxs){var priv=idxs.length?privateNets(idxs):null;
 if(!priv)return {t:[],v:[],z:[]};
 return {t:(PCB.tracks||[]).filter(function(t){return t.net&&priv[t.net];}),
  v:(PCB.vias||[]).filter(function(v){return v.net&&priv[v.net];}),z:[]};}
// Union of the applicable sources, deduped — one object never translates twice.
function carriedCopper(idxs,g,banded){var seen=new Set(),t=[],v=[],z=[];
 idxs=visiblePartIdxs(idxs);
 var add=function(cu){cu.t.forEach(function(o){if(!seen.has(o)){seen.add(o);t.push(o);}});
  cu.v.forEach(function(o){if(!seen.has(o)){seen.add(o);v.push(o);}});
  (cu.z||[]).forEach(function(o){if(!seen.has(o)){seen.add(o);z.push(o);}});};
 if(g&&visiblePartIdxs(GRPS[g]).length===(GRPS[g]||[]).length)add(grpCopper(g));
 if(banded)add(selCuCopper());
 add(privateCopper(idxs));
 return {t:t,v:v,z:z};}
// A gesture MOVED copper (as opposed to ripping it up): connectivity, pours and
// inspected facts go stale like any copper edit — but copperTouched also drops
// the copper selection, because a rip-up can free those objects. Here every one
// of them is still alive, just somewhere else, so put the band straight back:
// it stays highlighted and a second drag/rotate of it carries the same copper.
function copperMoved(){var band=selCuCopper();copperTouched();
 if(band.t.length||band.v.length)selCuTo(band.t,band.v);
 drawRoute();}
function gdragStart(m,down,idxs){var src=idxs||sel;
 var g=idxs?grpOf(P[down].ref):null;
 var mv=src.filter(function(k){return !P[k].locked&&partOnVisibleFace(P[k]);}); // locked / hidden-face members stay put
 var cu=carriedCopper(mv,g,!g);
 var fills=zoneFillsFor(cu.z);
 return {sx:m.x,sy:m.y,lx:m.x,ly:m.y,adx:0,ady:0,moved:false,active:false,down:down,
 snap:snapAll(),g:g,
 ct:cu.t.map(function(t){return {t:t,x1:t.x1,y1:t.y1,xm:t.xm,ym:t.ym,x2:t.x2,y2:t.y2};}),
 cv:cu.v.map(function(v){return {v:v,x:v.x,y:v.y};}),
 cz:cu.z.map(function(z){return {z:z,poly:(z.poly||[]).map(function(p){return [p[0],p[1]];})};}),
 cf:fills.map(function(f){return {f:f,poly:(f.poly||[]).map(function(p){return [p[0],p[1]];}),
  holes:(f.holes||[]).map(function(h){return h.map(function(p){return [p[0],p[1]];});})};}),
 orig:mv.map(function(k){return {i:k,x:P[k].x,y:P[k].y};})};}
// The copper a live drag carries, as a plain {t,v} object list (a live R press
// rotates it through the same rigid transform as the parts).
function gdragCopper(d){return (d.ct.length||d.cv.length||d.cz.length)?
 {t:d.ct.map(function(o){return o.t;}),v:d.cv.map(function(o){return o.v;}),z:d.cz.map(function(o){return o.z;})}:null;}
// A live R press changes the drag's geometry in place. Rebase every drag
// baseline at the current pointer so the next pointermove adds only the NEW
// delta instead of restoring the stale pre-rotation positions/copper.
function gdragRebase(d){d.sx=d.lx;d.sy=d.ly;d.active=true;d.adx=0;d.ady=0;
 d.orig=d.orig.map(function(o){return {i:o.i,x:P[o.i].x,y:P[o.i].y};});
 d.ct=d.ct.map(function(o){return {t:o.t,x1:o.t.x1,y1:o.t.y1,xm:o.t.xm,ym:o.t.ym,x2:o.t.x2,y2:o.t.y2};});
 d.cv=d.cv.map(function(o){return {v:o.v,x:o.v.x,y:o.v.y};});
 d.cz=d.cz.map(function(o){return {z:o.z,poly:(o.z.poly||[]).map(function(p){return [p[0],p[1]];})};});}
// Rotate a rigid group 45° about its centroid (locked members stay put).
// keepG (the group's slug, when the whole rigid group rotates) carries the
// group's stamped copper through the same rigid transform, derived from one
// member's exact before→after pose so the copper stays attached to it even
// after the per-part grid snap. `cu` ({t,v} object lists) overrides that tag
// lookup with an explicit set — how a marquee selection rotates the copper it
// caught, which carries no group tag.
function rotateGroup(idxs,sign,keepG,live,cu){
 var mv=idxs.filter(function(i){return !P[i].locked&&partOnVisibleFace(P[i]);});if(!mv.length)return false;
 if(!live)recordUndo();
 var r0=mv[0],r0x=P[r0].x,r0y=P[r0].y;
 var cx=0,cy=0;mv.forEach(function(i){cx+=P[i].x;cy+=P[i].y;});cx/=mv.length;cy/=mv.length;
 var da=(sign>0?45:-45)*Math.PI/180,dc=Math.cos(da),ds=Math.sin(da);
 var rdx=r0x-cx,rdy=r0y-cy,rix=cx+rdx*dc-rdy*ds,riy=cy+rdx*ds+rdy*dc;
 var tx=Math.round(rix/G)*G-rix,ty=Math.round(riy/G)*G-riy;
 mv.forEach(function(i){var dx=P[i].x-cx,dy=P[i].y-cy;
  P[i].x=cx+dx*dc-dy*ds+tx;P[i].y=cy+dx*ds+dy*dc+ty;
  P[i].rot=((((P[i].rot||0)+(sign>0?45:-45))%360)+360)%360;setT(i);});
 var cop=cu||(keepG?grpCopper(keepG):null);
 if(cop){var nx=P[r0].x,ny=P[r0].y;
  rfDropForTracks(cop.t);
  var rr=function(px,py){var dx=px-r0x,dy=py-r0y;
   return {x:nx+dx*dc-dy*ds,y:ny+dx*ds+dy*dc};};
  cop.t.forEach(function(t){
   var a=rr(t.x1,t.y1),b=rr(t.x2,t.y2),m=t.xm!=null?rr(t.xm,t.ym):null;
   t.x1=a.x;t.y1=a.y;if(m){t.xm=m.x;t.ym=m.y;}t.x2=b.x;t.y2=b.y;});
  cop.v.forEach(function(v){
   var a=rr(v.x,v.y);v.x=a.x;v.y=a.y;});
  (cop.z||[]).forEach(function(z){z.poly=(z.poly||[]).map(function(p){var a=rr(p[0],p[1]);return [a.x,a.y];});});
  if((cop.z||[]).length){pourGeomDrop();dragCacheDrop();markPoursStale();}}
 // Carried copper (group-tagged or selected) follows the rigid transform above.
 // Every other track stays where it was so rotating never destroys routing;
 // ratsnest + DRC expose any endpoints that now need reconnecting.
 ratsUpdate(mv);drawRoute();drawClr();refreshUnplaced();
 if(live){paintSoon();return true;}
 fetchScore();scheduleDrc();updatePropLive();
 if(window.PCB3D&&window.PCB3D.sync)window.PCB3D.sync();return true;}
function rotatePart(i,sign,live){if(i<0||P[i].locked||!partOnVisibleFace(P[i]))return false;if(!live)recordUndo();
 P[i].rot=((((P[i].rot||0)+(sign>0?45:-45))%360)+360)%360;setT(i);
 ratsUpdate([i]);drawClr();refreshUnplaced();
 if(live){paintSoon();return true;}
 fetchScore();scheduleDrc();
 if(selRef===P[i].ref)updatePropLive();
 if(window.PCB3D&&window.PCB3D.sync)window.PCB3D.sync();return true;}
// Pick the same kind of stable module anchor that Stamp uses: a hub wins, then
// the largest footprint. A marquee caller may override this with the selected
// part under the cursor, matching the keyboard action's existing hover gate.
function flipAnchor(mv,want){if(want!=null&&mv.indexOf(want)>=0)return want;
 var best=mv[0];mv.forEach(function(i){var p=P[i],b=P[best],ph=p.kind==="hub"?1:0,bh=b.kind==="hub"?1:0;
  if(ph>bh||(ph===bh&&p.hw*p.hh>b.hw*b.hh))best=i;});return best;}
// Flip one resolved transform target to the opposite board face. One shared
// pose transform mirrors every member around a stable anchor; independently
// toggling each footprint would mirror each around its OWN origin, leaving the
// group's positions and relative rotations inside-out. Keeping the anchor's
// x/y/rotation fixed makes a single-part flip byte-compatible with the old
// behavior and makes a double group flip exactly reversible.
function flipParts(idxs,wantAnchor){var mv=idxs.filter(function(i){return !P[i].locked&&partOnVisibleFace(P[i]);});
 if(!mv.length)return false;var anchor=flipAnchor(mv,wantAnchor);recordUndo();
 var before=stampPoseOf(P[anchor]);
 var after={x:before.x,y:before.y,rot:before.rot,back:!before.back};
 var xf=stampPoseCompose(after,stampPoseInverse(before));
 mv.forEach(function(i){var np=stampPoseCompose(xf,stampPoseOf(P[i]));
  P[i].x=np.x;P[i].y=np.y;P[i].rot=np.rot;P[i].side=np.back?"bottom":"top";setT(i);});
 // A side change mirrors each footprint's pads, so its old routing is no
 // longer geometrically valid. Remove all affected nets once for the target.
 clearRouteFor(mv);markPoursStale();ratsUpdate(mv);drawClr();fetchScore();refreshUnplaced();
 scheduleDrc();updatePropLive();
 if(window.PCB3D&&window.PCB3D.sync)window.PCB3D.sync();return true;}
// The pose algebra used when a module snapshot is re-anchored on the board.
// It matches worldPt: mirror local X first, then rotate in the y-down board
// frame. Composition lets Stamp preserve the live anchor's position, rotation
// and side instead of resetting a bottom-side group to its top-side snapshot.
function stampPoseNorm(r){return ((Math.round(r||0)%360)+360)%360;}
function stampPoseOf(p){return {x:p.x,y:p.y,rot:stampPoseNorm(p.rot),back:p.side==="bottom"};}
function stampPoseLin(p,x,y){if(p.back)x=-x;
 var a=stampPoseNorm(p.rot)*Math.PI/180,c=Math.cos(a),s=Math.sin(a);
 return {x:x*c-y*s,y:x*s+y*c};}
function stampPoseApply(p,x,y){var q=stampPoseLin(p,x,y);return {x:q.x+p.x,y:q.y+p.y};}
function stampPoseCompose(a,b){var t=stampPoseLin(a,b.x,b.y);return {x:t.x+a.x,y:t.y+a.y,
 rot:stampPoseNorm(a.rot+(a.back?-b.rot:b.rot)),back:a.back!==b.back};}
function stampPoseInverse(p){var q={x:0,y:0,rot:stampPoseNorm(p.back?p.rot:-p.rot),back:p.back};
 var t=stampPoseLin(q,p.x,p.y);q.x=-t.x;q.y=-t.y;return q;}
function stampLayer(l,mirror){return !mirror?l:(l===0?1:(l===1?0:l));}
function stampZoneLayer(l,mirror){if(!mirror)return l;
 return l===LN.f_cu?LN.b_cu:(l===LN.b_cu?LN.f_cu:l);}
// Refresh Stamp's small seed payload at click time. A module layout is commonly
// edited in another tab while this board stays open with unsaved work, so the
// page-load PCB.subseeds snapshot is only an initial palette preview, never the
// authority for the actual Stamp.
function stampBusy(g,on){document.querySelectorAll("[data-stamp],[data-grp-stamp],[data-save-sub],[data-grp-save]").forEach(function(b){
 if(b.getAttribute("data-stamp")!==g&&b.getAttribute("data-grp-stamp")!==g&&
    b.getAttribute("data-save-sub")!==g&&b.getAttribute("data-grp-save")!==g)return;
 b.disabled=on;if(on)b.setAttribute("aria-busy","true");else b.removeAttribute("aria-busy");});}
function refreshSubcircuitData(){
 return fetch("/api/pcb-subseeds/"+encodeURIComponent(PCB.name),{cache:"no-store"})
  .then(function(r){if(!r.ok)throw new Error("server returned "+r.status);return r.json();})
  .then(function(j){PCB.subseeds=j.subseeds||{};PCB.subseedorigins=j.subseedorigins||{};PCB.subseedinfo=j.subseedinfo||{};
   PCB.submodules=j.submodules||PCB.submodules||{};PCB.subroutes=j.subroutes||{};
   PCB.subsaveinfo=j.subsaveinfo||{};
  });}
function refreshStampSeeds(g){stampBusy(g,true);
 return refreshSubcircuitData().then(function(){
   var idxs=GRPS[g]||[];
   if(!idxs.some(function(i){return !!stampSeedFor(g,P[i]);})){subPanelRefresh();
    throw new Error("the module has no saved layout matching its current parts");}
  });}
function stampSeedFor(g,p){var stableSeeds=(PCB.subseedorigins||{})[g]||{};
 return (p.origin&&stableSeeds[p.origin])||(PCB.subseeds||{})[p.ref];}
// Stamp a group from its freshly fetched module layout. The module anchor's
// LIVE board pose is invariant; every saved part and copper primitive follows
// the rigid module-anchor → board-anchor transform around it.
function stampGroup(g){return refreshStampSeeds(g).then(function(){var idxs=GRPS[g]||[],hit=[];
 idxs.forEach(function(i){var sd=stampSeedFor(g,P[i]);if(sd)hit.push({i:i,sd:sd});});
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
 var xf=stampPoseCompose(stampPoseOf(P[anc.i]),stampPoseInverse(stampPoseOf(anc.sd)));
 hit.forEach(function(h){var i=h.i;if(P[i].locked)return;
  var sg=snapG(),np=stampPoseCompose(xf,stampPoseOf(h.sd));
  P[i].x=Math.round(np.x/sg)*sg;P[i].y=Math.round(np.y/sg)*sg;
  P[i].rot=np.rot;P[i].side=np.back?"bottom":"top";setT(i);});
 delete rigidOff[g];rigidSave();
 // Copper: replace this group's stamped copper with the module snapshot's
 // (PCB.subroutes — net names already mapped to this design), transformed by
 // the same rigid pose as the parts and tagged with the group slug so rigid
 // drags/rotates carry it. A side flip mirrors endpoints and swaps F.Cu/B.Cu.
 // Nets touching a locked (not-moved) member are skipped — their copper would
 // be geometrically wrong.
 clearRouteFor(idxs,g);
 PCB.tracks=(PCB.tracks||[]).filter(function(t){return t.g!==g;});
 PCB.vias=(PCB.vias||[]).filter(function(v){return v.g!==g;});
 var oldZoneCount=(PCB.zones||[]).length;
 PCB.zones=(PCB.zones||[]).filter(function(z){return z.g!==g;});
 var sr=(PCB.subroutes||{})[g];
 var stampedZones=PCB.zones.length!==oldZoneCount;
 if(sr&&((sr.tracks||[]).length||(sr.vias||[]).length||(sr.zones||[]).length)){
  var lockedNets={};idxs.forEach(function(i){if(!P[i].locked)return;
   (P[i].pads||[]).forEach(function(pd){if(pd.net)lockedNets[pd.net]=1;});});
  (sr.tracks||[]).forEach(function(t){if(t.net&&lockedNets[t.net])return;
   var a=stampPoseApply(xf,t.x1,t.y1),b=stampPoseApply(xf,t.x2,t.y2),m=t.xm!=null?stampPoseApply(xf,t.xm,t.ym):null;
   PCB.tracks.push({x1:a.x,y1:a.y,xm:m&&m.x,ym:m&&m.y,x2:b.x,y2:b.y,l:stampLayer(t.l||0,xf.back),w:t.w||0.25,net:t.net||"",g:g,source:t.source,id:trackIdNew()});});
  (sr.vias||[]).forEach(function(v){if(v.net&&lockedNets[v.net])return;
   var a=stampPoseApply(xf,v.x,v.y);
   PCB.vias.push({x:a.x,y:a.y,d:v.d||0.4,drill:v.drill||0,net:v.net||"",g:g,source:v.source,id:viaIdNew()});});
  (sr.zones||[]).forEach(function(z){if(!z.net||z.keepout||lockedNets[z.net])return;
   var poly=(z.poly||[]).map(function(p){var a=stampPoseApply(xf,+p[0],+p[1]);return [a.x,a.y];});
   if(poly.length<3)return;PCB.zones.push({net:z.net,layer:stampZoneLayer(z.layer,xf.back),poly:poly,
    filled:true,keepout:false,priority:+z.priority||0,g:g});stampedZones=true;});}
 if(stampedZones)onZonesChanged();
 rats();drawClr();drawRoute();fetchScore();refreshUnplaced();subPanelRefresh();scheduleDrc();progressRefresh();
 }).catch(function(e){window.alert("Stamp failed: "+(e&&e.message?e.message:e));
 }).finally(function(){stampBusy(g,false);});}
stampGroupFn=stampGroup;
// Inverse of Stamp: send only this rigid group's live poses and explicitly
// group-owned copper. The server re-keys by origin, reverses the board pose,
// maps parent nets back to module nets, and writes a NEW module layout behind
// the freshly fetched target revision.
function saveGroupLayout(g){var idxs=GRPS[g]||[];if(!idxs.length)return Promise.resolve();
 var suggested=((PCB.name||"board")+" "+stamp()).slice(0,80);
 var nm=window.prompt("Save this board arrangement as a new sub-circuit layout:",suggested);
 if(nm===null)return Promise.resolve();nm=nm.trim();if(!nm)return Promise.resolve();
 if(nm.length>80){window.alert("Layout names are limited to 80 characters.");return Promise.resolve();}
 stampBusy(g,true);
 return refreshSubcircuitData().then(function(){var info=(PCB.subsaveinfo||{})[g];
  if(!info||typeof info.rev!=="number")throw new Error("the sub-circuit save target is unavailable");
  var parts=idxs.map(function(i){var p=P[i];return {ref:p.ref,x:p.x,y:p.y,rot:p.rot||0,origin:p.origin||"",side:p.side||"top",locked:!!p.locked};});
  var tracks=(PCB.tracks||[]).filter(function(t){return t.g===g;});
  var vias=(PCB.vias||[]).filter(function(v){return v.g===g;});
  var zones=(PCB.zones||[]).filter(function(z){return z.g===g;});
  var routes=(tracks.length||vias.length||zones.length)?{tracks:tracks,vias:vias,zones:zones}:null;
  return fetch("/api/pcb-subcircuit-layout/"+encodeURIComponent(PCB.name),{method:"POST",headers:{"Content-Type":"application/json"},
   body:JSON.stringify({group:g,name:nm,parts:parts,routes:routes,rev:info.rev})});
 }).then(function(r){return r.text().then(function(t){var j={};try{j=t?JSON.parse(t):{};}catch(ignore){}
   if(!r.ok)throw new Error((j&&j.error)||t||("server returned "+r.status));return j;});})
  .then(function(j){var info=(PCB.subsaveinfo||{})[g];if(info&&typeof j.rev==="number")info.rev=j.rev;
   var msg=document.getElementById("pcb-savemsg");if(msg){msg.style.color="#3fb950";
    msg.textContent="saved ‘"+nm+"’ to "+g+" ✓";}
   return refreshSubcircuitData().catch(function(){});})
  .catch(function(e){window.alert("Save to sub-circuit failed: "+(e&&e.message?e.message:e));})
  .finally(function(){stampBusy(g,false);});}
saveGroupFn=saveGroupLayout;
// Iterative layout editing: curLayout is the saved layout the Update button
// writes back into (overwrite in place) instead of forcing a new one. Set by
// Load and after a Save as…. Save/Update persist in place (no page reload — see
// persistLayout), so the board, camera and view toggles never reset under you.
var curLayout=null;
// Point the address bar at the active layout's permalink (?layout=<name>), and
// drop the solve flags that would outrank it on a reload (?show=cache, ?regen,
// tuning weights). Do this on every Load/Save so the URL in the bar is always
// the link that reproduces what's on screen — copy it and it opens here.
var SOLVE_QS=["show","refine","regen","rough","remaining","loop_w","w_align","w_congest",
 "cap_w_max","grid","court_overlap","route_gap","group_w","group_zone_w","group_loop_relief","zone_pack"];
function syncLayoutUrl(nm){
 try{var u=new URL(window.location.href);
  SOLVE_QS.forEach(function(k){u.searchParams.delete(k);});
  if(nm&&nm.length)u.searchParams.set("layout",nm);else u.searchParams.delete("layout");
  window.history.replaceState(null,"",u.pathname+(u.searchParams.toString()?"?"+u.searchParams.toString():"")+u.hash);
  var assembly=document.querySelector('a[href^="/assembly-debug/"]');
  if(assembly){var target="/assembly-debug/"+encodeURIComponent(PCB.name);
   if(nm&&nm.length)target+="?layout="+encodeURIComponent(nm);
   assembly.href=target;}
 }catch(e){}}
function setActiveLayout(nm){curLayout=(nm&&nm.length)?nm:null;
 var ub=document.getElementById("pcb-update");if(ub)ub.disabled=!curLayout;
 var ind=document.getElementById("pcb-active");
 if(ind){if(curLayout){ind.textContent="editing \u{201c}"+curLayout+"\u{201d}";ind.style.display="";}
  else{ind.textContent="";ind.style.display="none";}}
 document.querySelectorAll(".lay-row").forEach(function(row){
  row.classList.toggle("active",curLayout!=null&&row.getAttribute("data-lay-row")===curLayout);});
 var chip=document.getElementById("pcb-srcchip");
 if(chip&&curLayout){chip.textContent="saved \u{00b7} "+curLayout;chip.className="src-chip src-snapshot";
  chip.title="Showing saved layout \u{201c}"+curLayout+"\u{201d} \u{2014} drag to edit, then Update to save progress.";}
 if(typeof layoutNavSync==="function")layoutNavSync(false);}
// (Per-part DOM listeners are gone — the svg-level handlers below hit-test
// partAt/padAt and drive the same drag/rigid-drag/select behaviors.)
// Keyboard: R / Shift+R rotates the explicit selection (hover is the fallback);
// ? toggles the
// shortcut-help overlay (Esc or click closes it). The overlay's list
// mirrors exactly what this script binds.
var kbdOv=null;
function kbdClose(){if(kbdOv&&kbdOv.parentNode)kbdOv.parentNode.removeChild(kbdOv);kbdOv=null;}
function kbdToggle(){
 if(kbdOv){kbdClose();return;}
 kbdOv=document.createElement("div");kbdOv.className="kbd-overlay";
 kbdOv.innerHTML='<div class="kbd-box"><h3>Keyboard &amp; mouse</h3>'+
  '<div class="kbd-row"><span>Rotate selected group / component +45°</span><kbd>R</kbd></div>'+
  '<div class="kbd-row"><span>Move selected parts by an X/Y distance (dialog)</span><kbd>M</kbd></div>'+
  '<div class="kbd-row"><span>Measure dx / dy / distance (drag on the board)</span><kbd>D</kbd></div>'+
  '<div class="kbd-row"><span>Rotate selected group / component −45°</span><kbd>Shift+R</kbd></div>'+
  '<div class="kbd-row"><span>Flip selected group / component top/bottom</span><kbd>F</kbd></div>'+
  '<div class="kbd-row"><span>Lock / unlock selected parts (hovered part fallback)</span><kbd>L</kbd></div>'+
  '<div class="kbd-row"><span>Explode / re-cohere hovered sub-circuit</span><kbd>G</kbd></div>'+
  '<div class="kbd-row"><span>Move whole sub-circuit</span><kbd>drag any of its parts</kbd></div>'+
  '<div class="kbd-row"><span>Edit the current board outline; drag empty space to box-select vertices</span><kbd>▭ Outline</kbd></div>'+
  '<div class="kbd-row"><span>Connected outline lines (corner + H/V snap &middot; Enter keeps open &middot; Backspace undo)</span><kbd>Line, then click endpoints</kbd></div>'+
  '<div class="kbd-row"><span>Edit outline: select vertices or segments + Delete leaves an open sketch &middot; Line reconnects loose endpoints &middot; Remove fillet restores a sharp corner</span><kbd>in outline sketch</kbd></div>'+
  '<div class="kbd-row"><span>Dimension selected outline geometry</span><kbd>D in outline sketch</kbd></div>'+
  '<div class="kbd-row"><span>Constrain selected outline line</span><kbd>H / V</kbd></div>'+
  '<div class="kbd-row"><span>Draw/edit a custom pour (near H/V snaps; Ctrl bypasses) with the shared sketch palette</span><kbd>Z, then click board/pour</kbd></div>'+
  '<div class="kbd-row"><span>Hand-route mode (click pad → trace; head stops at clearance obstacles)</span><kbd>X</kbd></div>'+
  '<div class="kbd-row"><span>Open the View sidebar (when no trace or outline sketch is active)</span><kbd>V</kbd></div>'+
  '<div class="kbd-row"><span>Drop via + flip layer (while actively routing)</span><kbd>V</kbd></div>'+
  '<div class="kbd-row"><span>Focus / select top or bottom copper</span><kbd>B</kbd></div>'+
  '<div class="kbd-row"><span>Cycle the selected routable layer</span><kbd>PgUp / PgDn</kbd></div>'+
  '<div class="kbd-row"><span>Toggle 45&deg; / 90&deg; trace bends (while routing)</span><kbd>E</kbd></div>'+
  '<div class="kbd-row"><span>Switch corner posture (while routing)</span><kbd>/</kbd></div>'+
  '<div class="kbd-row"><span>Toggle sharp / rounded tangent-arc bends</span><kbd>A</kbd></div>'+
  '<div class="kbd-row"><span>Step back / finish trace</span><kbd>Backspace / Enter &middot; dbl-click</kbd></div>'+
  '<div class="kbd-row"><span>Delete track or via (in route mode)</span><kbd>right-click</kbd></div>'+
  '<div class="kbd-row"><span>Inspect copper / DRC marker (Select mode)</span><kbd>click it</kbd></div>'+
  '<div class="kbd-row"><span>Choose an exact object where selectable items overlap</span><kbd>click / tap and hold</kbd></div>'+
  '<div class="kbd-row"><span>Slide selected track (Shift = free) &middot; delete</span><kbd>drag &middot; Del</kbd></div>'+
  '<div class="kbd-row"><span>Fillet two connected selected tracks</span><kbd>right-click &middot; Fillet…</kbd></div>'+
  '<div class="kbd-row"><span>Delete every box-selected track / via</span><kbd>Del</kbd></div>'+
  '<div class="kbd-row"><span>Move part or board silkscreen text (R rotates while held)</span><kbd>drag item</kbd></div>'+
  '<div class="kbd-row"><span>Align exact pads (moves first pad’s component / sub-circuit)</span><kbd>●↔● tool</kbd></div>'+
  '<div class="kbd-row"><span>Add / remove an item from the selection</span><kbd>Ctrl / Cmd + click</kbd></div>'+
  '<div class="kbd-row"><span>Select box &mdash; parts + copper (Shift adds; Objects tab picks what it catches)</span><kbd>drag empty space</kbd></div>'+
  '<div class="kbd-row"><span>Move all selected together &mdash; parts and the copper in the band</span><kbd>drag any selected part or track</kbd></div>'+
  '<div class="kbd-row"><span>Copy / paste selected traces and vias</span><kbd>Ctrl / Cmd + C / V</kbd></div>'+
  '<div class="kbd-row"><span>Find parts, nets, DRC, sub-circuits, or board text</span><kbd>Ctrl / Cmd + F</kbd></div>'+
  '<div class="kbd-row"><span>Clear selection</span><kbd>Esc / click empty</kbd></div>'+
  '<div class="kbd-row"><span>Undo / redo move</span><kbd>Ctrl+Z / Ctrl+Shift+Z</kbd></div>'+
  '<div class="kbd-row"><span>Pan</span><kbd>two-finger drag &middot; Space+drag &middot; middle-drag</kbd></div>'+
  '<div class="kbd-row"><span>Zoom</span><kbd>scroll wheel &middot; pinch &middot; +/&minus;</kbd></div>'+
  '<div class="kbd-row"><span>Toggle this help</span><kbd>?</kbd></div>'+
  '<div class="kbd-hint">Esc or click anywhere to close</div></div>';
 document.body.appendChild(kbdOv);kbdOv.addEventListener("click",kbdClose);
}
// Space (held) switches an empty-space drag from marquee-select to pan; a
// keyup releases it. Guarded by kbTyping so Space still types in a field.
var SPACE=false;
document.addEventListener("keydown",function(ev){if((ev.key===" "||ev.code==="Space")&&!kbTyping(ev.target)){SPACE=true;ev.preventDefault();}});
document.addEventListener("keyup",function(ev){if(ev.key===" "||ev.code==="Space")SPACE=false;});
document.addEventListener("keydown",function(ev){
 if(ev.key=="Escape"){if(pickMenu){ev.preventDefault();pickMenuClose();try{svg.focus();}catch(e){}return;}if(window.PCBFindIsOpen&&window.PCBFindIsOpen()){ev.preventDefault();window.PCBFindClose();return;}if(PHYSICAL_REVIEW){ev.preventDefault();selNet(null);return;}if(kbdOv){kbdClose();}else if(PCB.moveDlgOpen&&PCB.moveDlgOpen()){PCB.moveDlgClose();}else if(hsModalShown()){hsModalClose();}else if(heatsinkMode){heatsinkArm(false);}else if(padAlignMode){padAlignArm(false);}else if(drawMode){if(dtrace)drawEnd();else drawModeSet(false);}else if(textMode){if(txSel>=0){txSelect(-1);}else txArm(false);}else if(backingMode){backingArm(false);}else if(polyMode){if(polyPts){polyPts=null;polyCur=null;drawBoardRect();}else polyArm(false);}else if(pourMode){if(pourDlg){closePourDialog();}else if(pourPts){pourPts=null;pourCur=null;drawBoardRect();}else pourArm(false);}else if(outlineMode){outDraw=null;outlineArm(false);drawBoardRect();}else if(selCuClear()){}else if(insp){inspClear();}else{selClear();clearSel();}return;}
 if((outlineMode||activeSketchIsArea())&&!kbTyping(ev.target)&&(ev.key==="d"||ev.key==="D")){ev.preventDefault();outlineSketchDimension();return;}
 if((outlineMode||activeSketchIsArea())&&!kbTyping(ev.target)&&(ev.key==="h"||ev.key==="H")){ev.preventDefault();outlineSketchConstraint("horizontal");return;}
 if((outlineMode||activeSketchIsArea())&&!kbTyping(ev.target)&&(ev.key==="v"||ev.key==="V")){ev.preventDefault();outlineSketchConstraint("vertical");return;}
 if(outlineDeleteKeyActive(ev.target)&&(ev.key==="Backspace"||ev.key==="Delete")){ev.preventDefault();outlineDeleteSelected();return;}
 if(polyMode&&ev.key=="Enter"){ev.preventDefault();polyFinish(false);return;}
 if(polyMode&&(ev.key=="Backspace"||ev.key=="Delete")){ev.preventDefault();polyPop();return;}
 if(pourMode&&pourPts&&ev.key=="Enter"){ev.preventDefault();pourClose();return;}
 if(pourMode&&pourPts&&(ev.key=="Backspace"||ev.key=="Delete")){ev.preventDefault();pourPop();return;}
 // Match component dragging: R/Shift+R rotates the held label live and the
 // pointer-up commits movement + every rotation as one undoable gesture. This
 // deliberately precedes the typing guard because selecting a label opens and
 // focuses its inline text input at pointer-down.
 if(txDrag&&(ev.key=="r"||ev.key=="R")){ev.preventDefault();
  txRotate(txDrag.i,ev.shiftKey?-90:90);txDrag.moved=true;paintSoon();return;}
 var typing=kbTyping(ev.target);
 if(ev.key=="?"&&!typing){ev.preventDefault();kbdToggle();return;}
 // T toggles the silkscreen-text tool (not while typing in the inline editor).
 if((ev.key=="t"||ev.key=="T")&&!ev.ctrlKey&&!ev.metaKey&&!typing){ev.preventDefault();txArm(!textMode);return;}
 // Z toggles the ▩ custom copper-pour tool (Ctrl/Cmd+Z stays undo).
 if((ev.key=="z"||ev.key=="Z")&&!ev.ctrlKey&&!ev.metaKey&&!ev.altKey&&!typing){ev.preventDefault();pourArm(!pourMode);return;}
 // A selected text label rotates (R) / deletes (Del/Backspace) before parts.
 if(txSel>=0&&!typing){
  if(ev.key=="r"||ev.key=="R"){ev.preventDefault();recordUndo();txRotate(txSel,ev.shiftKey?-90:90);
   paintSoon();txPopReposition(txSel);txDirty();return;}
  if(ev.key=="Delete"||ev.key=="Backspace"){ev.preventDefault();txDelete(txSel);return;}}
 // Marquee-selected copper outranks the single inspected item: Del/Backspace
 // rips up the whole band at once.
 if((ev.key=="Delete"||ev.key=="Backspace")&&!typing&&!RO&&selCuCount()&&!anyDrawTool()){
  ev.preventDefault();cuDeleteSelected();return;}
 // Selected copper (docked inspector): Del/Backspace removes the track/via.
 if((ev.key=="Delete"||ev.key=="Backspace")&&!typing&&!RO&&insp&&!anyDrawTool()){
  if(insp.t=="track"||insp.t=="via"){ev.preventDefault();recordUndo();
   if(insp.t=="track"){rfDropForTracks([insp.o]);PCB.tracks=(PCB.tracks||[]).filter(function(q){return q!==insp.o;});}
   else PCB.vias=(PCB.vias||[]).filter(function(q){return q!==insp.o;});
   gpuCuEdit(); // this delete has no 2D cache to drop, so the GPU bake is the one thing that would go stale
   routeStatMsg();scheduleDrc();paintSoon();return;}}
 if((ev.key=="r"||ev.key=="R")&&!typing){var rsign=ev.shiftKey?-1:1;
   // R during a pointer gesture belongs to that gesture. Rotate live without
   // recording a second undo entry, then rebase the drag so subsequent motion
   // continues from the rotated group/copper instead of stale pointerdown data.
   if(gdrag){ev.preventDefault();var gidx=gdrag.orig.map(function(o){return o.i;});
    if(rotateGroup(gidx,rsign,gdrag.g,true,gdragCopper(gdrag))){gdrag.moved=true;copperMoved();gdragRebase(gdrag);}return;}
   if(drag){ev.preventDefault();if(rotatePart(drag.i,rsign,true)){drag.active=true;drag.moved=true;copperTouched();}return;}
   // Mirror the drag priority (pointerdown): a marquee multi-select that
   // includes the hovered part rotates as ONE rigid body about the selection's
   // centroid. Explicit hierarchical selection comes next: group first-click,
   // drilled-in component second-click. Hover is only the no-selection fallback.
   // The selection's copper rotates with it, exactly as it translates on a drag.
   if(cur>=0&&sel.length>1&&sel.indexOf(cur)>=0){ev.preventDefault();
    rotateGroup(sel,rsign,null,false,carriedCopper(sel.filter(function(k){return !P[k].locked;}),null,true));return;}
   if(selGroup&&!selRef){ev.preventDefault();var rg=GRPS[selGroup]||[];
    rotateGroup(rg,rsign,selGroup,false,carriedCopper(rg.filter(function(k){return !P[k].locked;}),selGroup,false));return;}
   var ri=selRef?P.findIndex(function(p){return p.ref===selRef;}):cur;
   if(ri<0)return;ev.preventDefault();
   if(!selRef){var rgi=grpIdxs(ri),rgg=grpOf(P[ri].ref);
    if(rgi){rotateGroup(rgi,rsign,rgg,false,carriedCopper(rgi.filter(function(k){return !P[k].locked;}),rgg,false));return;}}
   rotatePart(ri,rsign);return;}
 if((ev.key=="g"||ev.key=="G")&&cur>=0&&!typing){ev.preventDefault();
   var gg=grpOf(P[cur].ref);if(gg&&GRPS[gg]){grpToggle(gg);grpHl(gg,grpRigid(gg));}return;}
 if((ev.key=="f"||ev.key=="F")&&!ev.shiftKey&&!typing){
   // Match R and drag targeting: the explicit selection wins when the hover
   // belongs to it; an explicit hierarchical group wins next; a drilled-in
   // component overrides its parent; hover is only the final fallback.
   if(cur>=0&&sel.length>1&&sel.indexOf(cur)>=0){ev.preventDefault();flipParts(sel,cur);return;}
   if(selGroup&&!selRef){ev.preventDefault();flipParts(GRPS[selGroup]||[]);return;}
   var fi=selRef?P.findIndex(function(p){return p.ref===selRef;}):cur;
   if(fi<0)return;ev.preventDefault();
   if(!selRef){var fgi=grpIdxs(fi);if(fgi){flipParts(fgi,fi);return;}}
   flipParts([fi],fi);return;}
 if((ev.key=="l"||ev.key=="L")&&!typing){
   // An explicit multi-selection owns L even when the pointer has left it.
   // A mixed selection converges to locked; once every member is locked, the
   // next press unlocks the whole selection. This makes the command a stable
   // lock/unlock toggle without depending on which selected part is hovered.
   if(sel.length>1){ev.preventDefault();var sl=!sel.every(function(k){return P[k].locked;});
    sel.forEach(function(k){P[k].locked=sl;setT(k);});
    refreshAlignBar();progressRefresh();return;}
   if(cur<0)return;ev.preventDefault();
   // A part inside an INTACT rigid sub-circuit locks/unlocks the WHOLE group at
   // once — one L signs off a stamped module's place wave (place-wave done ⇔
   // all members locked). Ungrouped / exploded parts keep single-part locking.
   var gli=visiblePartIdxs(grpIdxs(cur));
   if(gli&&gli.length>1){var nl=!P[cur].locked;
    gli.forEach(function(k){P[k].locked=nl;setT(k);});
    if(selRef&&gli.some(function(k){return P[k].ref===selRef;}))renderProps();}
   else{P[cur].locked=!P[cur].locked;setT(cur);
    if(selRef===P[cur].ref)renderProps();}
   progressRefresh();return;}});
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
function cloneCopper(){return {tracks:(PCB.tracks||[]).map(function(t){return {x1:t.x1,y1:t.y1,xm:t.xm,ym:t.ym,x2:t.x2,y2:t.y2,l:t.l||0,w:t.w,net:t.net||"",g:t.g,source:t.source,id:trackIdEnsure(t)};}),
 vias:(PCB.vias||[]).map(function(v){return {x:v.x,y:v.y,d:v.d,drill:v.drill,net:v.net||"",g:v.g,f:v.f,source:v.source,s:Array.isArray(v.s)?v.s.slice():undefined,id:viaIdEnsure(v)};}),
 rf_paths:(PCB.rf_paths||[]).map(function(p){return {net:p.net,l:p.l||0,
  track_ids:(p.track_ids||[]).slice(),samples:(p.samples||[]).map(function(s){return [+s[0],+s[1],+s[2]];})};})};}
function cloneText(t){return {x:t.x,y:t.y,rot:t.rot||0,side:t.side||"top",size:t.size||1,text:t.text,subcircuit:t.subcircuit||undefined,testpoint:t.testpoint||undefined,fabrication_id:!!t.fabrication_id};}
function cloneTexts(){return (PCB.texts||[]).map(cloneText);}
function cloneFabricationLayers(){return JSON.parse(JSON.stringify(PCB.fabrication_layers||[]));}
function cloneHeatsink(){return PCB.heatsink?JSON.parse(JSON.stringify(PCB.heatsink)):null;}
function cloneZones(){return (PCB.zones||[]).map(function(z){return {net:z.net||"",layer:z.layer||"",poly:(z.poly||[]).map(function(p){return [+p[0],+p[1]];}),filled:!!z.filled,keepout:!!z.keepout,priority:+z.priority||0,g:z.g,
 sketch:z.sketch?(OS?OS.clone(z.sketch):JSON.parse(JSON.stringify(z.sketch))):null};});}
// Deep-copy the drawn board outline ({x,y,w,h,pts?}) so a snapshot holds its
// own vertex array — an in-place vertex drag must not mutate a stored undo step.
function cloneOutline(){var o=PCB.outline;if(!o)return null;
 return {x:o.x,y:o.y,w:o.w,h:o.h,pts:o.pts?o.pts.map(function(p){return [p[0],p[1]];}):null,
  radii:o.radii?o.radii.slice():null,sketch:o.sketch?(OS?OS.clone(o.sketch):JSON.parse(JSON.stringify(o.sketch))):null};}
// Build a full snapshot. `poses` optionally overrides the current poses (a
// drag's captured pre-move state); copper + texts + outline are always current.
function snapAll(poses){var c=cloneCopper();return {poses:poses||snapPoses(),tracks:c.tracks,vias:c.vias,rf_paths:c.rf_paths,zones:cloneZones(),texts:cloneTexts(),outline:cloneOutline(),fabrication_layers:cloneFabricationLayers(),heatsink:cloneHeatsink()};}
function undoBtns(){var u=document.getElementById("pcb-undo"),r=document.getElementById("pcb-redo");
 if(u)u.disabled=!undoStack.length;if(r)r.disabled=!redoStack.length;}
// recordUndo accepts a full snapshot {poses,tracks,vias}, a bare pose array
// (legacy drag capture — copper filled from the current model), or nothing.
function recordUndo(snap){var e=(snap&&snap.poses)?snap:snapAll(Array.isArray(snap)?snap:null);
 undoStack.push(e);if(undoStack.length>200)undoStack.shift();
 redoStack.length=0;undoBtns();markDirty();}
function restoreSnap(s){s.poses.forEach(function(q,i){if(P[i]){P[i].x=q.x;P[i].y=q.y;P[i].rot=q.rot;P[i].side=q.side||"top";P[i].locked=!!q.locked;}});
 // applyAll() clears copper (a moved part invalidates routing), so restore the
 // snapshot's copper AFTER it, then repaint + re-DRC.
 applyAll();
 PCB.tracks=(s.tracks||[]).map(function(t){return {x1:t.x1,y1:t.y1,xm:t.xm,ym:t.ym,x2:t.x2,y2:t.y2,l:t.l||0,w:t.w,net:t.net||"",g:t.g,source:t.source,id:t.id||trackIdNew()};});
 PCB.vias=(s.vias||[]).map(function(v){return {x:v.x,y:v.y,d:v.d,drill:v.drill,net:v.net||"",g:v.g,f:v.f,source:v.source,s:Array.isArray(v.s)?v.s.slice():undefined,id:v.id||viaIdNew()};});
 PCB.rf_paths=(s.rf_paths||[]).map(function(p){return {net:p.net,l:p.l||0,
  track_ids:(p.track_ids||[]).slice(),samples:(p.samples||[]).map(function(q){return [+q[0],+q[1],+q[2]];})};});
 var editZoneIndex=typeof pourEdit!=="undefined"&&pourEdit?(PCB.zones||[]).indexOf(pourEdit):-1;
 PCB.zones=(s.zones||[]).map(function(z){return {net:z.net||"",layer:z.layer||"",poly:(z.poly||[]).map(function(p){return [+p[0],+p[1]];}),filled:!!z.filled,keepout:!!z.keepout,priority:+z.priority||0,g:z.g,
  sketch:z.sketch?(OS?OS.clone(z.sketch):JSON.parse(JSON.stringify(z.sketch))):null};});
 if(typeof pourEdit!=="undefined")pourEdit=editZoneIndex>=0&&editZoneIndex<PCB.zones.length?PCB.zones[editZoneIndex]:null;
 pourGeomDrop();markPoursStale();
 // Board texts rewind with the same snapshot; drop any selection/popover
 // pointing at a label the restored state no longer has.
 PCB.texts=(s.texts||[]).map(cloneText);
 if(typeof txSel!=="undefined"&&txSel>=0){txSel=-1;txPopClose();}
 // The board outline rewinds too (undo/redo of an outline draw/poly/vertex
 // edit / clear); repaint it and mark the board dirty like any restored edit.
 PCB.outline=s.outline?{x:s.outline.x,y:s.outline.y,w:s.outline.w,h:s.outline.h,
  pts:s.outline.pts?s.outline.pts.map(function(p){return [p[0],p[1]];}):null,
  radii:s.outline.radii?s.outline.radii.slice():null,
  sketch:s.outline.sketch?(OS?OS.clone(s.outline.sketch):JSON.parse(JSON.stringify(s.outline.sketch))):null}:null;
 var backingLayerIndex=typeof backingEdit!=="undefined"&&backingEdit?(PCB.fabrication_layers||[]).indexOf(backingEdit.layer):-1,backingRegionIndex=typeof backingEdit!=="undefined"&&backingEdit?backingEdit.index:-1;
 PCB.fabrication_layers=JSON.parse(JSON.stringify(s.fabrication_layers||fabricationDefaults));
 if(typeof backingEdit!=="undefined"){var restoredBacking=backingLayerIndex>=0&&PCB.fabrication_layers[backingLayerIndex];backingEdit=restoredBacking&&backingRegionIndex>=0?{layer:restoredBacking,index:backingRegionIndex,poly:restoredBacking.regions[backingRegionIndex],sketch:(restoredBacking.sketches||[])[backingRegionIndex]||null}:null;}
 PCB.heatsink=s.heatsink?JSON.parse(JSON.stringify(s.heatsink)):null;
 outlineGeomDrop();
 drawBoardRect();
 outlineSketchPanelSync();
 PCB.drc=[];drawRoute();drawDrc();scheduleDrc();markDirty();}
function doUndo(){if(!undoStack.length)return;redoStack.push(snapAll());restoreSnap(undoStack.pop());undoBtns();}
function doRedo(){if(!redoStack.length)return;undoStack.push(snapAll());restoreSnap(redoStack.pop());undoBtns();}
var undoBtn=document.getElementById("pcb-undo");if(undoBtn)undoBtn.addEventListener("click",doUndo);
var redoBtn=document.getElementById("pcb-redo");if(redoBtn)redoBtn.addEventListener("click",doRedo);
// Capture undo at the window boundary so a dock/popup handler cannot consume
// it before the board history sees it. Text-entry controls still retain their
// native undo while they are actively being edited.
window.addEventListener("keydown",function(ev){if(!(ev.ctrlKey||ev.metaKey)||kbTyping(ev.target))return;
 var k=(ev.key||"").toLowerCase();
 if(k==="z"&&!ev.shiftKey){ev.preventDefault();doUndo();}
 else if((k==="z"&&ev.shiftKey)||k==="y"){ev.preventDefault();doRedo();}},true);
undoBtns();
// ── Unsaved-work protection ─────────────────────────────────────────────
// A dirty flag tracks edits since the last successful Save/Update. It arms a
// beforeunload prompt, a quick localStorage crash draft, and a server autosave
// after editing goes idle. Top-level designs always autosave their one "layout";
// module/sub-circuit pages start autosaving once a named layout is loaded/saved.
// RO pages never edit, so they opt out entirely.
var DRAFT_KEY="pcb-draft:"+PCB.name+(PCB.sub?(":"+PCB.sub):"");
var pcbDirty=false,draftTimer=null,draftIdle=null,autosaveTimer=null,dirtyGeneration=0;
var autosaveQueued=false,saveQueue=Promise.resolve();
var autosaveRetryMs=2000;
function autosaveName(){return curLayout;}
function markDirty(){if(RO)return;pcbDirty=true;dirtyGeneration++;scheduleDraft();scheduleAutosave();}
function clearDirty(){pcbDirty=false;
 if(draftTimer){clearTimeout(draftTimer);draftTimer=null;}
 if(draftIdle){if(window.cancelIdleCallback)window.cancelIdleCallback(draftIdle);else clearTimeout(draftIdle);draftIdle=null;}
 if(autosaveTimer){clearTimeout(autosaveTimer);autosaveTimer=null;}
 clearDraft();}
// saveDraft stringifies every pose plus all copper into SYNCHRONOUS
// localStorage, so it must never land mid-gesture — a pointer-held drag would
// hitch for the write. The timer re-arms while a gesture is live and the actual
// serialization/write runs in an idle callback
// (part/group drag or a viewport still inside its busy window via gestureBusy,
// plus the pointer-held copper/pan/draw states); beforeunload calls saveDraft
// directly, so a draft is never lost to the wait.
function draftGestureLive(){
 return gestureBusy()||!!pan||!!segdrag||!!viadrag||!!backingDrag||!!(drawMode&&dtrace);}
function scheduleDraft(ms){if(RO)return;if(draftTimer)clearTimeout(draftTimer);
 if(draftIdle){if(window.cancelIdleCallback)window.cancelIdleCallback(draftIdle);else clearTimeout(draftIdle);draftIdle=null;}
 draftTimer=setTimeout(function(){draftTimer=null;
  if(draftGestureLive()){scheduleDraft(500);return;}
  saveDraft();},ms||1000);}
function scheduleAutosave(ms){if(RO||!autosaveName())return;
 // Unplaced parts = poses the SERVER staged, not ones the user authored. The
 // idle autosave must never write them into the saved row; place them (any
 // move counts) or Save/Update explicitly to accept the staging.
 if(anyUnplaced()){var m=document.getElementById("pcb-savemsg");
  if(m)m.textContent="autosave paused — place the unplaced parts (or Save as…)";return;}
 if(autosaveTimer)clearTimeout(autosaveTimer);
 autosaveTimer=setTimeout(runAutosave,ms||2500);}
function runAutosave(){autosaveTimer=null;if(!pcbDirty||autosaveQueued||anyUnplaced())return;
 if(draftGestureLive()){scheduleAutosave(500);return;}
 var nm=autosaveName();if(!nm)return;var attemptGeneration=dirtyGeneration;autosaveQueued=true;
 persistLayout(nm,"autosaving",true).then(function(result){autosaveQueued=false;
  // A successful request only leaves pcbDirty set when the user made a newer
  // edit while its older payload was in flight. Coalesce that edit into one
  // follow-up save; failures/conflicts keep the draft without request-spamming.
  if(result==="saved"&&pcbDirty)scheduleAutosave();
  else if(result==="retry"&&pcbDirty){var ms=autosaveRetryMs;autosaveRetryMs=Math.min(30000,autosaveRetryMs*2);scheduleAutosave(ms);}
  // A newer edit may have repaired a hard validation failure while the large
  // board's previous request was still being checked. Give that generation
  // its own attempt without retry-spamming the unchanged invalid payload.
  else if(result==="failed"&&pcbDirty&&dirtyGeneration!==attemptGeneration)scheduleAutosave();});}
function draftPoses(){return P.map(function(p){return {ref:p.ref,x:p.x,y:p.y,rot:p.rot||0,
 side:p.side||"top",locked:!!p.locked,origin:p.origin||""};});}
// Persist the working state to localStorage. On a quota error (large boards)
// retry a poses-only draft, then give up with a console warning.
function saveDraft(sync){if(RO)return;
 if(!sync){var run=function(){draftIdle=null;if(draftGestureLive()){scheduleDraft(500);return;}saveDraft(true);};
  draftIdle=window.requestIdleCallback?window.requestIdleCallback(run,{timeout:1000}):setTimeout(run,0);return;}
 copperIdsEnsureAll();var ts=Math.floor(Date.now()/1000);
 try{localStorage.setItem(DRAFT_KEY,JSON.stringify({poses:draftPoses(),
   tracks:PCB.tracks||[],vias:PCB.vias||[],zones:PCB.zones||[],rf_paths:PCB.rf_paths||[],texts:PCB.texts||[],outline:PCB.outline||null,fabrication_layers:PCB.fabrication_layers||[],
   rev:PCB.rev||0,ts:ts}));}
 catch(e){
  try{localStorage.setItem(DRAFT_KEY,JSON.stringify({poses:draftPoses(),rev:PCB.rev||0,ts:ts,partial:true}));}
  catch(e2){console.warn("pcb: could not save layout draft (localStorage full)");}}}
function clearDraft(){try{localStorage.removeItem(DRAFT_KEY);}catch(e){}}
// Standard unsaved-changes prompt. Returning a string arms the browser dialog.
window.addEventListener("beforeunload",function(e){if(!pcbDirty)return;saveDraft(true);
 e.preventDefault();e.returnValue="";return "";});
// Apply a restored draft to the board (undoable), then re-mark dirty so the
// user can Save it. Matches poses by ref (drafts are same-design, refs stable).
function applyDraft(d){recordUndo();
 (d.poses||[]).forEach(function(q){for(var i=0;i<P.length;i++){if(P[i].ref===q.ref){
   P[i].x=q.x;P[i].y=q.y;P[i].rot=q.rot||0;P[i].side=q.side||"top";P[i].locked=!!q.locked;break;}}});
 applyAll();
 if(!d.partial){
  if((d.tracks&&d.tracks.length)||(d.vias&&d.vias.length)||(d.rf_paths&&d.rf_paths.length)){PCB.tracks=d.tracks||[];PCB.vias=d.vias||[];PCB.rf_paths=d.rf_paths||[];PCB.drc=[];drawRoute();drawDrc();}
  // Old drafts predate zone capture; leave the server-rendered pours alone for
  // those, while a new draft can deliberately restore an empty zone list.
  if(d.zones){PCB.zones=d.zones;PCB.zone_fills=[];pourGeomDrop();}
  PCB.texts=(d.texts||[]).map(cloneText);
  PCB.outline=d.outline||null;PCB.fabrication_layers=JSON.parse(JSON.stringify(d.fabrication_layers||fabricationDefaults));outlineGeomDrop();drawBoardRect();}
 copperTouched();paintSoon();markDirty();scheduleDrc();}
// Banner offering Restore/Discard of a found draft (fixed bar at top of page).
function showDraftBanner(d,stale){if(document.getElementById("pcb-draft-banner"))return;
 var bar=mkEl("div");bar.id="pcb-draft-banner";
 bar.style.cssText="position:fixed;top:0;left:0;right:0;z-index:10000;background:#1f6feb;color:#fff;"+
  "padding:8px 14px;display:flex;gap:12px;align-items:center;font:13px/1.4 system-ui,sans-serif;box-shadow:0 2px 10px rgba(0,0,0,.35)";
 var when="";try{when=new Date((d.ts||0)*1000).toLocaleString();}catch(e){}
 var lbl=mkEl("span",null,(stale?"Unsaved layout work (the board changed in another window) ":"Unsaved layout work ")+(when?("from "+when+" "):"")+"was found.");
 lbl.style.flex="1";
 var rb=mkEl("button",null,"Restore"),db=mkEl("button",null,"Discard");
 [rb,db].forEach(function(b){b.style.cssText="border:0;border-radius:4px;padding:5px 12px;cursor:pointer;font:inherit;font-weight:600";});
 rb.style.background="#fff";rb.style.color="#0d1117";
 db.style.background="transparent";db.style.color="#fff";db.style.border="1px solid rgba(255,255,255,.6)";
 function close(){if(bar.parentNode)bar.parentNode.removeChild(bar);}
 rb.addEventListener("click",function(){applyDraft(d);close();});
 db.addEventListener("click",function(){clearDraft();close();});
 bar.appendChild(lbl);bar.appendChild(rb);bar.appendChild(db);document.body.appendChild(bar);}
var outBtn=document.getElementById("pcb-outline");
if(outBtn)outBtn.addEventListener("click",function(){outlineArm(!outlineMode);});
var polyBtn=document.getElementById("pcb-outline-poly");
if(polyBtn)polyBtn.addEventListener("click",function(){polyArm(!polyMode);});
var pourZoneBtn=document.getElementById("pcb-pour-zone");
if(pourZoneBtn)pourZoneBtn.addEventListener("click",function(){pourArm(!pourMode);});
document.getElementById("pcb-reset").addEventListener("click",function(){recordUndo();
 selClear();P.forEach(function(p,i){p.x=orig[i].x;p.y=orig[i].y;p.rot=orig[i].rot;p.side=orig[i].side;});applyAll();});
function pad2(n){return (n<10?"0":"")+n;}
function stamp(){var d=new Date();return pad2(d.getMonth()+1)+"-"+pad2(d.getDate())+" "+pad2(d.getHours())+":"+pad2(d.getMinutes());}
// Query string for a permalink, carrying the ?sub= scope when the page has one.
function subq2(k,v){var q=PCB.sub?("?sub="+encodeURIComponent(PCB.sub)+"&"):"?";
 return q+k+"="+encodeURIComponent(v);}
function layByName(nm){var Ls=PCB.layouts||[];for(var i=0;i<Ls.length;i++)if(Ls[i].name===nm)return Ls[i];return null;}
// ── Saved-layout panel rows are built/bound here too (not only server-side) so
//    a Save/Update can splice a row in place rather than reloading the page.
function mkEl(tag,cls,txt){var e=document.createElement(tag);if(cls)e.className=cls;
 if(txt!=null)e.textContent=txt;return e;}
function loadLayoutName(nm){
 var L=layByName(nm);if(!L)return;
 // routes===null means "this layout HAS copper, but the page didn't inline it"
 // (only the shown layout's copper rides in the blob — see writeLayoutsJson).
 // Follow the row's permalink so the server renders it, copper and all.
 if(L.routes===null){window.location="/pcb-layout/"+encodeURIComponent(PCB.name)+subq2("layout",nm);return;}
 recordUndo();
 // Rows arrive re-keyed onto the CURRENT flatten server-side (rekeyRowsToLive:
 // origin bridged per sub-block scope), so a Load applies by EXACT ref only.
 // No origin map here: a client-side one was unscoped ("U1" names every
 // sub-block's IC) and last-wins, which collapsed whole sub-circuits onto one
 // pose on Load — the black-canyon layout corruption.
 P.forEach(function(p){var s=L.parts[p.ref];if(s){p.x=s.x;p.y=s.y;p.rot=s.rot||0;p.side=s.side||"top";if(s.locked!==undefined)p.locked=!!s.locked;}});applyAll();
 if(L.routes&&((L.routes.tracks||[]).length||(L.routes.vias||[]).length||(L.routes.rf_paths||[]).length)){
  PCB.tracks=L.routes.tracks||[];PCB.vias=L.routes.vias||[];PCB.rf_paths=L.routes.rf_paths||[];PCB.drc=[];drawRoute();drawDrc();}
 // Restore this layout's custom copper pours; the carved fills recompute below.
 PCB.zones=(L.routes&&L.routes.zones)?L.routes.zones:[];PCB.zone_fills=[];pourGeomDrop();
 PCB.outline=L.outline||null;PCB.fabrication_layers=JSON.parse(JSON.stringify((L.fabrication_layers&&L.fabrication_layers.length)?L.fabrication_layers:fabricationDefaults));outlineGeomDrop();
 PCB.heatsink=L.heatsink?JSON.parse(JSON.stringify(L.heatsink)):null;drawBoardRect();
 PCB.texts=(L.texts||[]).map(cloneText);
 txSel=-1;txPopClose();copperTouched();paintSoon();
 setActiveLayout(nm);syncLayoutUrl(nm);clearDirty();
 if((PCB.zones||[]).length)refillPours();else scheduleDrc();}
function bindLayLoad(b){b.addEventListener("click",function(){loadLayoutName(b.getAttribute("data-lay-load"));});}
function bindLayDel(b){b.addEventListener("click",function(){var nm=b.getAttribute("data-lay-del");
 if(!nm)return;
 if(!window.confirm("Delete layout \""+nm+"\"?"))return;
 fetch("/api/pcb-layouts/"+encodeURIComponent(PCB.name)+"/delete"+subq(),{method:"POST",
   headers:{"Content-Type":"application/json"},body:JSON.stringify({name:nm,rev:PCB.rev||0})})
  .then(function(r){if(!r.ok)throw r;return r.json();}).then(function(j){
   if(j&&typeof j.rev==="number")PCB.rev=j.rev;
   var Ls=PCB.layouts||[],at=Ls.findIndex(function(L){return L.name===nm;});if(at>=0)Ls.splice(at,1);
   var row=document.querySelector('.lay-row[data-lay-row="'+CSS.escape(nm)+'"]');if(row)row.remove();
   var count=document.querySelector(".saved-n");if(count)count.textContent=Ls.length;
   if(curLayout===nm||PCB.shown_layout===nm){setActiveLayout(null);syncLayoutUrl("");
    if(Ls.length)loadLayoutName(Ls[Math.min(Math.max(at,0),Ls.length-1)].name);else window.location.reload();}
   else layoutNavSync(true);})
  .catch(function(r){window.alert(r&&r.status===409?"Layouts changed in another window. Reload before deleting.":"Could not delete that layout.");});});}
function bindLayRename(b){b.addEventListener("click",function(){var old=b.getAttribute("data-lay-rename");
 if(!old)return;var nm=window.prompt("Rename layout:",old);if(nm===null)return;nm=nm.trim();
 if(!nm||nm===old)return;if(nm.length>80){window.alert("Layout names must be 80 characters or fewer.");return;}
 fetch("/api/pcb-layouts/"+encodeURIComponent(PCB.name)+"/rename"+subq(),{method:"POST",
  headers:{"Content-Type":"application/json"},body:JSON.stringify({name:old,new_name:nm,rev:PCB.rev||0})})
 .then(function(r){if(!r.ok)throw r;return r.json();}).then(function(j){
  if(j&&typeof j.rev==="number")PCB.rev=j.rev;
  var L=layByName(old);if(L)L.name=nm;
  document.querySelectorAll(".lay-row").forEach(function(row){if(row.getAttribute("data-lay-row")!==old)return;
   row.setAttribute("data-lay-row",nm);var name=row.querySelector(".lay-name");if(name){name.textContent=nm;
    if(name.tagName==="A")name.href="/pcb-layout/"+encodeURIComponent(PCB.name)+"?layout="+encodeURIComponent(nm);}
   ["load","rename","del","default"].forEach(function(k){var a=row.querySelector("[data-lay-"+k+"]");if(a)a.setAttribute("data-lay-"+k,nm);});});
  if(PCB.shown_layout===old)PCB.shown_layout=nm;
  if(curLayout===old){setActiveLayout(nm);syncLayoutUrl(nm);}layoutNavSync(true);})
 .catch(function(r){window.alert(r&&r.status===409?"That name is already used, or the layouts changed in another window.":"Could not rename that layout.");});});}
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
document.querySelectorAll("[data-lay-rename]").forEach(bindLayRename);
document.querySelectorAll("[data-lay-default]").forEach(bindLayDefault);
var rescoreBtn0=document.getElementById("pcb-rescore");if(rescoreBtn0)bindRescore(rescoreBtn0);
// Compact saved-version navigator. Layout rows remain in the All versions
// disclosure for management; ordinary comparison needs only previous/current/
// next. The sidecar is newest-first, so ‹ walks older and › walks newer.
function layoutNavSync(rebuild){var sel=document.getElementById("pcb-lay-select"),
 prev=document.getElementById("pcb-lay-prev"),next=document.getElementById("pcb-lay-next"),
 meta=document.getElementById("pcb-lay-meta"),ren=document.getElementById("pcb-lay-rename"),
 del=document.getElementById("pcb-lay-delete"),Ls=PCB.layouts||[];if(!sel)return;
 var sig=Ls.map(function(L){return L.name;}).join("\n");
 if(rebuild||sel.getAttribute("data-layout-sig")!==sig){sel.textContent="";
  Ls.forEach(function(L){var op=document.createElement("option");op.value=L.name;op.textContent=L.name;sel.appendChild(op);});
  sel.setAttribute("data-layout-sig",sig);}
 var nm=curLayout||PCB.shown_layout||(Ls[0]&&Ls[0].name)||"",idx=-1;
 for(var i=0;i<Ls.length;i++)if(Ls[i].name===nm){idx=i;break;}
 if(idx<0&&Ls.length){idx=0;nm=Ls[0].name;}if(nm)sel.value=nm;
 sel.disabled=!Ls.length;if(prev)prev.disabled=idx<0||idx>=Ls.length-1;
 if(next)next.disabled=idx<=0;
 if(ren){ren.disabled=idx<0;ren.setAttribute("data-lay-rename",idx<0?"":nm);}
 if(del){del.disabled=idx<0;del.setAttribute("data-lay-del",idx<0?"":nm);}
 if(meta){var L=idx>=0?Ls[idx]:null,bits=[];
  if(L){if(L.default)bits.push("★ default");bits.push(L.kind||"saved");
   if(L.score&&L.score.objective>0)bits.push("objective "+L.score.objective.toFixed(1));
   if(L.routes&&L.routes.tracks)bits.push(L.routes.tracks.length+" tracks");
   if(L.routes&&L.routes.vias)bits.push(L.routes.vias.length+" vias");}
  meta.textContent=bits.join(" · ");}}
function layoutNavStep(delta){var Ls=PCB.layouts||[],nm=curLayout||PCB.shown_layout,
 i=Ls.findIndex(function(L){return L.name===nm;});if(i<0)i=0;
 var j=i+delta;if(j>=0&&j<Ls.length)loadLayoutName(Ls[j].name);}
var laySel=document.getElementById("pcb-lay-select");if(laySel)laySel.addEventListener("change",function(){loadLayoutName(laySel.value);});
var layPrev=document.getElementById("pcb-lay-prev");if(layPrev)layPrev.addEventListener("click",function(){layoutNavStep(1);});
var layNext=document.getElementById("pcb-lay-next");if(layNext)layNext.addEventListener("click",function(){layoutNavStep(-1);});
layoutNavSync(true);
// Build a fresh manual saved-layout row mirroring writeLayoutsPanel's markup.
// The Save response carries the score the server already computed, so the row
// can update without rescoring every saved layout in a second request.
function buildLayRow(nm){
 var row=mkEl("div","lay-row");row.setAttribute("data-lay-row",nm);
 var top=mkEl("div","lay-top");
 top.appendChild(mkEl("span","lay-kind k-man","manual"));
 // Mirror writeLayoutName: the name is this layout's permalink on a design /
 // module page, a plain span on a ?sub sub circuit (?layout= isn't read there).
 if(PCB.sub){top.appendChild(mkEl("span","lay-name",nm));}
 else{var a=mkEl("a","lay-name",nm);
  a.href="/pcb-layout/"+encodeURIComponent(PCB.name)+"?layout="+encodeURIComponent(nm);
  a.title="Direct link to this layout \u{2014} opens the board exactly as saved";
  top.appendChild(a);}
 top.appendChild(mkEl("span","lay-d",""));
 var bot=mkEl("div","lay-bot");bot.appendChild(mkEl("span","lay-score","\u{2014}"));
 var act=mkEl("span","lay-actions");
 var star=mkEl("button","btn lay-star","\u{2606}");star.setAttribute("data-lay-default",nm);
 star.title="Make this the KiCad-sync default (seeds new parts' placement + GND vias)";bindLayDefault(star);
 var go=mkEl("button","btn lay-go","Load");go.setAttribute("data-lay-load",nm);bindLayLoad(go);
 var ren=mkEl("button","btn lay-rename","Rename");ren.setAttribute("data-lay-rename",nm);ren.title="Rename";bindLayRename(ren);
 var del=mkEl("button","btn lay-del","\u{2715}");del.setAttribute("data-lay-del",nm);del.title="Delete";bindLayDel(del);
 act.appendChild(star);act.appendChild(go);act.appendChild(ren);act.appendChild(del);
 bot.appendChild(act);row.appendChild(top);row.appendChild(bot);return row;}
// Splice a row for nm into the panel if it isn't there yet (Save as…), then
// move it to the top because this save just made it the most recently edited.
// The empty-state placeholder converts to a list + rescore button on first save.
function upsertLayoutPanel(nm){var saved=document.querySelector(".pcb-saved");if(!saved)return;
 var list=saved.querySelector(".saved-list");
 if(!list){var emp=saved.querySelector(".saved-empty");if(emp&&emp.parentNode)emp.parentNode.removeChild(emp);
  var all=document.createElement("details");all.className="saved-all";
  var sum=document.createElement("summary");sum.textContent="All versions";all.appendChild(sum);
  var tools=mkEl("div","lay-tools");all.appendChild(tools);
  list=mkEl("div","saved-list");all.appendChild(list);saved.appendChild(all);
  if(!document.getElementById("pcb-rescore")){var rb=mkEl("button","saved-rescore","\u{21bb} Rescore all");
   rb.id="pcb-rescore";rb.title="Recompute every saved layout's objective with the current engine";
   tools.appendChild(rb);bindRescore(rb);}}
 var rows=list.querySelectorAll(".lay-row"),row=null;
 for(var i=0;i<rows.length;i++)if(rows[i].getAttribute("data-lay-row")===nm){row=rows[i];break;}
 if(!row)row=buildLayRow(nm);
 if(list.firstChild!==row)list.insertBefore(row,list.firstChild);
 var n=saved.querySelector(".saved-n");if(n)n.textContent=list.querySelectorAll(".lay-row").length;}
function updateLayoutRowScore(nm,s){var rows=document.querySelectorAll(".lay-row"),row=null;
 for(var i=0;i<rows.length;i++)if(rows[i].getAttribute("data-lay-row")===nm){row=rows[i];break;}
 if(!row)return;var sc=row.querySelector(".lay-score"),dd=row.querySelector(".lay-d");
 if(sc)sc.textContent=s?((s.objective>0?("obj "+s.objective.toFixed(1)+" · "):"")+
  "HPWL "+(s.hpwl||0).toFixed(1)+" · loop "+(s.loop||0).toFixed(1)):"—";
 if(!dd)return;if(!s){dd.textContent="";dd.className="lay-d";return;}
 var base=svObj(PCB.auto),cur=s.objective>0?s.objective:((s.hpwl||0)+(s.loop||0));
 var d=cur-base;if(Math.abs(d)<0.05){dd.textContent="=";dd.className="lay-d";}
 else{dd.textContent=(d>0?"+":"")+d.toFixed(1);dd.className="lay-d "+(d>0?"up":"down");}}
// Serialize manual + automatic saves so two requests from this tab cannot race
// with the same optimistic-concurrency rev. Payload capture happens when the
// queued save starts, so a manual Save behind an autosave still gets the newest
// board state.
function persistLayout(nm,verb,automatic){var task=saveQueue.then(function(){
 return persistLayoutNow(nm,verb,!!automatic);});
 saveQueue=task.then(function(result){return result;},function(){return "failed";});
 return saveQueue;}
function saveResponse(r){return r.text().then(function(t){
 var body=(t||"").trim();
 if(r.status===409){var j={};try{j=body?JSON.parse(body):{};}catch(ignore){}
  var conflict=new Error("conflict");conflict.conflict=true;if(typeof j.rev==="number")conflict.rev=j.rev;throw conflict;}
 if(!r.ok){var detail=body&&!/^\s*</.test(body)?body:("save failed ("+r.status+")");
  var httpError=new Error(detail.slice(0,240));httpError.status=r.status;
  httpError.retryable=r.status===408||r.status===425||r.status===429||r.status>=500;throw httpError;}
 try{return body?JSON.parse(body):{};}catch(ignore){var badReply=new Error("invalid save response");badReply.retryable=true;throw badReply;}});}
function pourIssueFromError(e){var text=e&&e.message||"",m=text.match(/invalid custom copper-area sketch in zone #(\d+) \((.*?) on (.*?)\):\s*([A-Za-z]+)/);if(!m)return null;
 var i=parseInt(m[1],10)-1,z=(PCB.zones||[])[i];return z?{zone:z,index:i,open:m[4]==="OpenProfile",detail:text}:null;}
function focusPourIssue(issue){var z=issue&&issue.zone;if(!z||(PCB.zones||[]).indexOf(z)<0)return;
 pourArm(true);pourBeginEdit(z);var g=OS&&z.sketch&&OS.compile(z.sketch),pts=g&&g.points&&g.points.length?g.points:z.poly;zoomToPoly(pts||[]);
 var repair=issue.open?(OS&&z.sketch&&OS.canCloseProfile&&OS.canCloseProfile(z.sketch)?" Use Close profile, then Update.":" Reconnect the amber loose endpoints, then Update."):" Inspect the red geometry for a crossing, branch, or zero-length edge.";
 outlineMsg("Zone #"+(issue.index+1)+" · "+(z.net||"keepout")+" on "+(z.layer||"")+(issue.open?" is open.":" is invalid.")+repair);}
function showPourIssue(msg,issue,detail){if(!msg||!issue)return false;msg.style.color="#f85149";msg.textContent="";
 var b=document.createElement("button");b.type="button";b.className="savemsg-action";b.textContent=detail||("Zone #"+(issue.index+1)+" · "+(issue.zone.net||"keepout")+" on "+(issue.zone.layer||"")+" is invalid — inspect and repair");
 b.title="Open and frame this copper-area sketch";b.addEventListener("click",function(){focusPourIssue(issue);});msg.appendChild(b);return true;}
// Persist the current poses to layout nm and update the panel IN PLACE — no
// page reload, so the camera and view toggles you set while editing stay put.
function persistLayoutNow(nm,verb,automatic){var msg=document.getElementById("pcb-savemsg");
 if(automatic&&!pcbDirty)return Promise.resolve("clean");
 // Refuse to persist a self-intersecting / degenerate outline (the server would
 // 400 it anyway); the editing state is preserved so the user can fix it.
 if(outlineBad()){if(msg){msg.style.color="#f85149";var og=OS&&PCB.outline&&PCB.outline.sketch&&OS.compile(PCB.outline.sketch);
   msg.textContent=og&&!og.closed?"outline is open — reconnect its loose endpoints before saving":"outline self-intersects — fix it before saving";}return Promise.resolve("invalid");}
 recoverOpenPourSketches();
 var pbad=pourSketchBad();if(pbad){if(msg)showPourIssue(msg,pbad,pbad.open?("Zone #"+(pbad.index+1)+" · "+(pbad.zone.net||"keepout")+" on "+(pbad.zone.layer||"")+" is open — click to repair"):("Zone #"+(pbad.index+1)+" · "+(pbad.zone.net||"keepout")+" on "+(pbad.zone.layer||"")+" is invalid — click to inspect"));return Promise.resolve("invalid");}
 if(backingBad()){if(msg){msg.style.color="#f85149";
   msg.textContent="backing region sketch is open, conflicted, self-intersecting, or has zero area — fix it before saving";}return Promise.resolve("invalid");}
 copperIdsEnsureAll();var saveGeneration=dirtyGeneration;
 var parts=P.map(function(p){return {ref:p.ref,x:p.x,y:p.y,rot:p.rot||0,origin:p.origin||"",side:p.side||"top",locked:!!p.locked};});
 // Persist the on-screen copper (tracks/vias + user copper-pour zones) + drawn
 // outline with the poses so all survive reloads. Zones alone make `routes`
 // non-null so a board with only pours still round-trips them.
 var routes=((PCB.tracks||[]).length||(PCB.vias||[]).length||(PCB.zones||[]).length||(PCB.rf_paths||[]).length)?{tracks:PCB.tracks||[],vias:PCB.vias||[],zones:PCB.zones||[],rf_paths:PCB.rf_paths||[]}:null;
 var texts=(PCB.texts||[]).filter(function(t){return t&&t.text;});
 if(msg){msg.style.color="#8b949e";msg.textContent=verb+"\u{2026}";}
 // Echo the sidecar rev the page loaded so the server can 409 a stale write
 // (another window saved since) instead of silently clobbering it.
 return fetch("/api/pcb-layouts/"+encodeURIComponent(PCB.name)+subq(),{method:"POST",
   headers:{"Content-Type":"application/json"},body:JSON.stringify({name:nm,parts:parts,routes:routes,outline:PCB.outline||null,fabrication_layers:PCB.fabrication_layers||[],heatsink:PCB.heatsink||null,texts:texts,rev:PCB.rev||0})})
  .then(saveResponse)
  .then(function(j){
    // Adopt the server's bumped rev so the next Save from this window matches.
    if(j&&typeof j.rev==="number")PCB.rev=j.rev;
    autosaveRetryMs=2000;
    var pmap={};parts.forEach(function(p){pmap[p.ref]={x:p.x,y:p.y,rot:p.rot,origin:p.origin||"",side:p.side,locked:p.locked};});
    var Ls=PCB.layouts||(PCB.layouts=[]),found=null,foundAt=-1;
    for(var i=0;i<Ls.length;i++)if(Ls[i].name===nm){found=Ls[i];foundAt=i;break;}
    var sb=currentScore;
    var savedScore=sb?{hpwl:sb.hpwl||0,loop:sb.loop_raw||sb.loop||0,caps:sb.caps||0,objective:sb.objective||0}:null;
    if(found){found.parts=pmap;found.kind="manual";found.score=savedScore;found.routes=routes;found.outline=PCB.outline||null;found.fabrication_layers=cloneFabricationLayers();found.heatsink=cloneHeatsink();found.texts=texts;found.ts=Math.floor(Date.now()/1000);
     if(foundAt>0){Ls.splice(foundAt,1);Ls.unshift(found);}}
    else Ls.unshift({name:nm,kind:"manual",parts:pmap,score:savedScore,routes:routes,outline:PCB.outline||null,fabrication_layers:cloneFabricationLayers(),heatsink:cloneHeatsink(),texts:texts,ts:Math.floor(Date.now()/1000)});
    upsertLayoutPanel(nm);updateLayoutRowScore(nm,savedScore);setActiveLayout(nm);layoutNavSync(true);
    // An EXPLICIT save accepts the board as shown — staged parts included
    // (they are covered by the row now), so the autosave gate lifts.
    markUnplaced([]);
    // Never clear a draft that contains an edit made after this request's
    // payload snapshot. The autosave completion schedules that generation next.
    if(dirtyGeneration===saveGeneration)clearDirty();
    // Point the bar at THIS layout's permalink. The URL may still carry a
    // selection flag from an earlier Rough/Regenerate (?show=cache, ?regen,
    // tuning params) that would outrank a saved layout on reload — you just
    // SAVED, so a refresh must show the board you saved, under its own name.
    syncLayoutUrl(nm);
    if(msg){msg.style.color="#3fb950";
     msg.textContent=(automatic?"saved automatically":(verb==="updating"?"updated":"saved"))+" \u{2713}";}
    scheduleDrc();/* fast local re-DRC of the just-saved copper (audit 1.1d) */
    if(serverReconcileTimer){clearTimeout(serverReconcileTimer);serverReconcileTimer=null;}
    runDrcNow();/* Save fires the server DRC now — the authority of record */
    progressRefresh();/* poses/locks just persisted — re-pull the stage ladder */
    return "saved";})
  .catch(function(e){
    if(e&&e.conflict){
     // The board changed under us — keep the dirty state + draft so nothing is
     // lost, and do NOT adopt the server rev; the user reloads to pick up the
     // other window's version, then re-saves.
     if(msg){msg.style.color="#d29922";msg.textContent="layout changed in another window \u{2014} reload to continue";}
     return "conflict";}
    var retryable=!e||e.retryable||typeof e.status!=="number";
    if(automatic&&retryable){if(msg){msg.style.color="#8b949e";msg.textContent="autosave interrupted \u{2014} retrying\u{2026}";}return "retry";}
    var issue=pourIssueFromError(e);if(msg&&!showPourIssue(msg,issue,e&&e.message)){msg.style.color="#f85149";msg.textContent=e&&e.message?e.message:
     ((verb==="updating"?"update":"save")+" failed");}
    return "failed";});}
// Let external PCB-editor actions serialize behind autosave. Inbound KiCad
// import uses this before preview and again before apply, so it cannot race an
// idle autosave that would otherwise overwrite the freshly imported sidecar.
window.PCBFlushLayout=function(){
 if(autosaveTimer){clearTimeout(autosaveTimer);autosaveTimer=null;}
 if(pcbDirty){if(anyUnplaced())return Promise.resolve("skipped");
  var nm=autosaveName();if(!nm)return Promise.resolve("failed");
  return persistLayout(nm,"saving",false);}
 return saveQueue;
};
// The KiCad handoff must name the exact row currently being edited. Keeping
// this as a getter (instead of copying PCB.shown_layout) means Save as… and Load
// immediately change what the push button exports without a page reload.
window.PCBActiveLayoutName=function(){return curLayout;};
document.getElementById("pcb-saveas").addEventListener("click",function(){
 var nm=window.prompt("Name this layout:",curLayout?(curLayout+" copy"):("layout "+stamp()));
 if(nm===null)return; nm=nm.trim(); if(!nm)return; persistLayout(nm,"saving");});
// Update: overwrite the loaded layout in place (no prompt) — save progress on
// the layout you're iterating without disturbing the view.
var updBtn=document.getElementById("pcb-update");
if(updBtn)updBtn.addEventListener("click",function(){if(!curLayout)return;persistLayout(curLayout,"updating");});
// The server already rendered a named saved layout (?layout=, ?refine=, or the
// ★ default) — adopt it as the edit target, so Update and the idle autosave
// write back into the layout you opened instead of asking for a new name. A
// cache / fresh-solve / grid page leaves this null: nothing is loaded yet, so
// the first save must be a deliberate "Save as…".
if(!RO&&PCB.shown_layout)setActiveLayout(PCB.shown_layout);
// ── Sub-circuits palette ─────────────────────────────────────────────
// One row per sub-block: member count, rigid/exploded toggle, and — when the
// module has a stampable saved layout (PCB.subseeds) — a Stamp button that
// drops the whole pre-laid cluster onto the board. The tooltip names the
// snapshot the seeds came from (PCB.subseedinfo: the ★ when starred, else
// best coverage); a coverage chip appears when it doesn't span the group, and
// a "—" placeholder marks groups with nothing to stamp.
function subPanelRefresh(){var box=document.getElementById("sub-panel");if(!box)return;
 // No heading: the pane's own tab names it.
 var names=Object.keys(GRPS).sort();var h='';
 var sinfo=PCB.subseedinfo||{};
 names.forEach(function(g){
  // A click-time refresh is keyed by stable module origin because its fresh
  // grid ref-des can differ from the already-open board. Keep the button's
  // visibility on that same bridge; otherwise the refresh that makes Stamp
  // current can immediately hide Stamp for groups with renumbered refs.
  var hasSeed=GRPS[g].some(function(i){return !!stampSeedFor(g,P[i]);});
  var inf=sinfo[g],tot=GRPS[g].length;
  var cov=(inf&&inf.n<tot)?'<span class="sub-cov" title="The module snapshot covers '+inf.n+' of this group’s '+tot+' parts — the rest keep their positions on Stamp.">'+inf.n+'/'+tot+'</span>':'';
  var nameH='<a class="sub-name" href="'+subLayoutHref(g)+'" target="_blank" rel="noopener" title="Open this sub-circuit on its own PCB-layout page — lay it out and save / ★ a layout there.">'+pEsc(g)+'</a>';
  h+='<div class="sub-row" data-grp="'+pEsc(g)+'">'+
   nameH+'<span class="sub-n">'+tot+'</span>'+
   '<button class="btn sub-rigid'+(grpRigid(g)?" on":"")+'" data-rigid="'+pEsc(g)+'" title="'+
    (grpRigid(g)?"Rigid — drags as one unit. Click to explode.":"Exploded — parts move individually. Click to re-cohere.")+'">'+
    (grpRigid(g)?"\u{1F517}":"\u{2702}")+'</button>'+cov+
   (hasSeed?'<button class="btn sub-stamp" data-stamp="'+pEsc(g)+'" title="'+
     (inf?stampTitle(g,inf):"Place this sub-circuit from its module layout")+'">Stamp</button>':
    '<span class="sub-noseed" title="No saved layout on the module matches its current parts \u2014 lay it out and save on the module\u2019s own page.">\u2014</span>')+
   '<button class="btn sub-save" data-save-sub="'+pEsc(g)+'" title="Save the current on-board arrangement as a new layout on this sub-circuit">Save\u2026</button>'+
   '</div>';});
 box.innerHTML=h;
 box.querySelectorAll("[data-rigid]").forEach(function(b){b.addEventListener("click",function(){grpToggle(b.getAttribute("data-rigid"));});});
 box.querySelectorAll("[data-stamp]").forEach(function(b){b.addEventListener("click",function(){stampGroup(b.getAttribute("data-stamp"));});});
 box.querySelectorAll("[data-save-sub]").forEach(function(b){b.addEventListener("click",function(){saveGroupLayout(b.getAttribute("data-save-sub"));});});
 box.querySelectorAll(".sub-row").forEach(function(r){var g=r.getAttribute("data-grp");
  r.addEventListener("mouseenter",function(){grpHl(g,true);});
  r.addEventListener("mouseleave",function(){grpHl(g,false);});});
 markGrpRow();}
(function(){
 var n=Object.keys(GRPS).length;
 // The full page pre-renders #sub-panel inside the Sub-circuits tab; the
 // editable embed has no side tabs, so the palette still appends itself to
 // whatever left dock exists. No groups → leave the pane's empty state up.
 var host=document.getElementById("side-subs")||document.querySelector(".pcb-side");
 if(!host||!n)return;
 var empty=document.getElementById("sub-empty");if(empty)empty.hidden=true;
 var box=document.getElementById("sub-panel");
 if(!box){box=document.createElement("div");box.id="sub-panel";box.className="sub-panel";
  host.appendChild(box);}
 var tab=document.querySelector('.side-tab[data-sidetab="side-subs"]');
 if(tab)tab.innerHTML='Sub-circuits <span class="side-tab-n">'+n+'</span>';
 subPanelRefresh();})();
}
// Net hover (sidebar pin-chip mouseenter): board pads glow via paint state.
function netIdxDrop(){}
function hlBy(at,v,cls,on){
 if(at==="data-net"){hoverNet=on?v:null;statusHover(null);paintSoon();return;}
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
function stickyNetSet(net){selNetCur=net;
 // Board pads glow via paint state; the sidebar pin chips are still DOM.
 document.querySelectorAll(".pn[data-net]").forEach(function(e){
  e.classList.toggle("net-sel",net!=null&&e.getAttribute("data-net")===net);});
 paintSoon();}
function reviewPickedNet(net){var stats=net?reviewSet({nets:[net],fit:false}):reviewClear();
 if(window.parent===window)return;
 var matched=(stats.matchedNets||stats.matched_nets||[])[0]||net||"";
 try{window.parent.postMessage({type:"eda-pcb-net-picked",design:PCB.name,
  net:matched,clear:!net,stats:stats},window.location.origin);}catch(e){}}
function reviewClearOutside(m){var pts=reviewBoardPoints();
 if(!PHYSICAL_REVIEW||pts.length<3||polyContains(pts,m.x,m.y))return false;
 selNet(null);return true;}
// A pad is also an unambiguous component pick. Keep the exact owning part
// highlighted on the board and let the assembly shell reveal its BOM row.
function reviewPickedRef(i,pd){var p=P[i],side=reviewPartSide(p);
 if(reviewPickedRefCur===reviewText(p.ref)&&pd&&pd.net&&reviewPickedRefSide===side){reviewPickedRefSide=null;reviewPickedRefCur=null;selNet(pd.net);return;}
 var stats=reviewSet({refs:[p.ref],side:side,fit:false});
 if(window.parent===window)return;
 try{window.parent.postMessage({type:"eda-pcb-ref-picked",design:PCB.name,
  ref:p.ref,side:side,pad:(pd&&pd.num)||"",net:(pd&&pd.net)||"",stats:stats},window.location.origin);}catch(e){}}
function reviewPostParts(target,origin){if(!PHYSICAL_REVIEW||!target||!target.postMessage)return;
 try{target.postMessage({type:"eda-pcb-parts",design:PCB.name,parts:P.map(function(p){
  return {ref:p.ref,side:p.side==="bottom"?"bottom":"top"};})},origin);}catch(e){}}
function reviewCamVisibility(next){if(!next||typeof next!=="object")return;
 Object.keys(camVisibility).forEach(function(k){if(typeof next[k]==="boolean")camVisibility[k]=next[k];});
 dragCacheDrop();paintSoon();}
function selNet(net){if(net&&selNetCur===net)net=null;
 if(RO)reviewPickedNet(net);
 stickyNetSet(net);}
window.PCBSelectNet=selNet;
// Idempotent net-select seam for the replay panel: selNet() TOGGLES, but the
// replay log wants a plain "select this net / clear on null" — never a
// toggle-off when the same net recurs across consecutive replay frames.
window.PCBSelNet=function(net){
 if(net==null){if(selNetCur!==null)selNet(null);return;}
 if(selNetCur!==net)selNet(net);};
// The CURRENT on-screen arrangement as a server request body — the poses, the
// drawn outline and the pours. Exposed so a panel that must ask the server
// about *this* board (pcb_replay.js's router-vision overlay) posts the same
// context the Route button does, instead of a copy that drifts from it.
window.PCBBoardBody=function(){
 return {parts:P.map(function(p){return {ref:p.ref,x:p.x,y:p.y,rot:p.rot||0,side:p.side||"top"};}),
   outline:PCB.outline||null,zones:PCB.zones||[]};};
// The signal layer the viewer is currently working on. The router-vision
// overlay draws one layer at a time: free space differs per layer, and washing
// both at once blends into a picture that is true of neither.
window.PCBActiveLayer=function(){return activeLayer;};
var VBW=PCB.w,VBH=PCB.h,vb={x:0,y:0,w:VBW,h:VBH};
var REVIEW_CONTEXT_FRACTION=0.42;
function setVB(){svg.setAttribute("viewBox",vb.x.toFixed(1)+" "+vb.y.toFixed(1)+" "+vb.w.toFixed(1)+" "+vb.h.toFixed(1));
 // Pad-number labels are thousands of <text> nodes — unreadable when zoomed
 // out anyway, so drop them from rendering entirely below ~1.15 px/unit.
 var sw=svgMetricsGet().cw;
 svg.classList.toggle("zoomed-out",sw>0&&(sw/vb.w)<1.15);
 cullFromVB(sw>0?sw/vb.w:0); // cull window tracks the viewport even when no paint follows
 vbBusy(); // viewport moved: drop the drag cache + defer pad labels briefly
 statusZoom();
 ovPaintSoon();}
// The SVG now fills its flex container (app-frame layout), so the viewBox
// must always MATCH the container's aspect ratio — mm(ev) maps x and y
// through vb.w/r.width and vb.h/r.height independently, and a mismatched
// pair would skew picking. fitVB frames the whole board centred; vbResize
// re-derives vb.h about the current centre when the window reflows.
function hostAspect(){var m=svgMetricsGet(),sw=m.cw,sh=m.ch;
 return (sw>0&&sh>0)?(sh/sw):(VBH/VBW);}
function fitVB(){svgMetricsDrop();var ar=hostAspect(),w=VBW,h=VBW*ar;
 if(h<VBH){h=VBH;w=VBH/ar;}
 vb={x:(VBW-w)/2,y:(VBH-h)/2,w:w,h:h};setVB();}
// ── Assembly / debugging review focus ───────────────────────────────────
// The parent page sends refs and/or nets. Resolve them against the board once,
// then let the normal immediate-mode painter read the persistent state. Refdes
// matching is case-insensitive (full path first, hierarchy leaf second). Nets
// use the editor's existing dot-collapse semantics; a hierarchy-leaf fallback
// is accepted only when it identifies one unambiguous collapsed net.
function reviewText(v){return String(v==null?"":v).trim().toLowerCase();}
function reviewLeaf(v){var s=reviewText(v),i=s.lastIndexOf("/");return i<0?s:s.slice(i+1);}
function reviewNetKey(v){return reviewText(netCollapse(String(v==null?"":v)));}
function reviewList(v){if(v==null)return [];if(!Array.isArray(v))v=[v];var out=[],seen={};
 v.forEach(function(x){x=String(x==null?"":x).trim();var k=reviewText(x);if(k&&!seen[k]){seen[k]=1;out.push(x);}});return out;}
function reviewFocusActive(){return !!(reviewFocus&&reviewFocus.active);}
function reviewFocusHasNets(){if(!reviewFocusActive())return false;
 for(var k in reviewFocus.netKeys)if(reviewFocus.netKeys[k])return true;return false;}
function reviewFocusGroups(){return !!(reviewFocus&&(reviewFocus.kind==="section"||reviewFocus.kind==="subcircuit"));}
function reviewFocusNet(net){return !!(reviewFocusActive()&&net&&reviewFocus.netKeys[reviewNetKey(net)]);}
function reviewFocusPad(i,pd){var pins=reviewFocus&&reviewFocus.pinIdx&&reviewFocus.pinIdx[i];
 return !!(reviewFocusActive()&&pins&&pins[reviewText(pd.num)]);}
function reviewFocusPartAlpha(i){
 // A ref-only assembly pick is an outline/highlight, not an X-ray mode: keep
 // every package, pad, and mask opening at its normal loaded appearance.
 if(PHYSICAL_REVIEW&&!reviewFocusHasNets())return 1;
 return !reviewFocusActive()||reviewFocus.partIdx[i]?1:0.13;}
function reviewPinOne(i,pd){var k=reviewFocus&&reviewFocus.kind;
 return !!(PHYSICAL_REVIEW&&reviewFocusActive()&&reviewFocus.refIdx[i]&&!pd.npth&&
  String(pd.num||"").trim()==="1"&&(!k||k==="bom"||k==="ref"||k==="component"||k==="value"||k==="mpn"));}

function reviewResolveRefs(wants,side){var idx={},matched=[];
 wants.forEach(function(w){var k=reviewText(w),hits=[];
  P.forEach(function(p,i){if(reviewText(p.ref)===k&&(!side||reviewPartSide(p)===side))hits.push(i);});
  if(!hits.length)P.forEach(function(p,i){if(reviewLeaf(p.ref)===k&&(!side||reviewPartSide(p)===side))hits.push(i);});
  hits.forEach(function(i){if(!idx[i])matched.push(P[i].ref);idx[i]=1;});});
 return {idx:idx,refs:matched};}
function reviewPins(v){if(v==null)return [];if(!Array.isArray(v))v=[v];var out=[],seen={};
 v.forEach(function(pin){if(!pin||typeof pin!=="object")return;
  var ref=String(pin.ref==null?"":pin.ref).trim(),pad=String(pin.pad==null?"":pin.pad).trim();
  var k=reviewText(ref)+"."+reviewText(pad);if(ref&&pad&&!seen[k]){seen[k]=1;out.push({ref:ref,pad:pad});}});
 return out;}
function reviewResolvePins(wants,side){var idx={},matched=[];
 wants.forEach(function(pin){var rr=reviewResolveRefs([pin.ref],side);
  Object.keys(rr.idx).forEach(function(i){var pads={};
   (P[i].pads||[]).forEach(function(pd){if(reviewText(pd.num)===reviewText(pin.pad))pads[reviewText(pd.num)]=1;});
   if(!Object.keys(pads).length)return;idx[i]=idx[i]||{};
   Object.keys(pads).forEach(function(k){idx[i][k]=1;});
   matched.push({ref:P[i].ref,pad:pin.pad});});});
 return {idx:idx,pins:matched};}
function reviewAddNet(out,net){net=String(net==null?"":net).trim();var k=reviewText(net);if(k&&!out.seen[k]){out.seen[k]=1;out.names.push(net);}}
function reviewAvailableNets(){var out={seen:{},names:[]};
 P.forEach(function(p){(p.pads||[]).forEach(function(pd){reviewAddNet(out,pd.net);});});
 (PCB.tracks||[]).forEach(function(t){reviewAddNet(out,t.net);});
 (PCB.vias||[]).forEach(function(v){reviewAddNet(out,v.net);});
 (PCB.links||[]).forEach(function(l){reviewAddNet(out,l.net);});
 reviewCopperAreas().forEach(function(a){if(!a.q.keepout)reviewAddNet(out,a.q.net);});
 STACK.forEach(function(L){reviewAddNet(out,L.plane);});return out.names;}
function reviewResolveNets(wants){var avail=reviewAvailableNets(),keys={},names=[];
 wants.forEach(function(w){var wk=reviewText(w),wb=reviewNetKey(w),hits=[];
  avail.forEach(function(n){if(reviewText(n)===wk||reviewNetKey(n)===wb)hits.push(n);});
  if(!hits.length){var leaf=reviewLeaf(wb),groups={};
   avail.forEach(function(n){var nk=reviewNetKey(n);if(reviewLeaf(nk)===leaf)groups[nk]=1;});
   var gs=Object.keys(groups);if(gs.length===1)avail.forEach(function(n){if(reviewNetKey(n)===gs[0])hits.push(n);});}
  hits.forEach(function(n){var nk=reviewNetKey(n);if(!keys[nk]){keys[nk]=1;names.push(netCollapse(n));}});});
 return {keys:keys,nets:names};}

// Normalize both authored pours and optional KiCad-import zone payloads. The
// latter may use poly/polygon/points or filled polygon arrays; keeping this
// adapter here lets the Zig schema evolve without coupling the paint engine to
// one serialization spelling.
function reviewPoint(p){if(Array.isArray(p)&&p.length>=2)return [+p[0],+p[1]];
 if(p&&typeof p==="object"&&isFinite(+p.x)&&isFinite(+p.y))return [+p.x,+p.y];return null;}
function reviewPoly(raw){if(!Array.isArray(raw))return null;var out=[];
 raw.forEach(function(p){p=reviewPoint(p);if(p)out.push(p);});return out.length>=3?out:null;}
// Interior antipad hole loops of a pour entry ("holes" omitted server-side when
// none): always an array, [] for zones/imports that carry no such field.
function reviewHoles(q){var out=[];((q&&q.holes)||[]).forEach(function(h){h=reviewPoly(h);if(h)out.push(h);});return out;}
function reviewAreaPolys(q){var raw=q&&(q.filled_polygons||q.filledPolygons||q.filled||q.polys),out=[];
 if(raw&&Array.isArray(raw)){
  if(raw.length&&reviewPoint(raw[0])){var one=reviewPoly(raw);if(one)out.push(one);}
  else raw.forEach(function(p){p=reviewPoly(p);if(p)out.push(p);});}
 if(!out.length){var one2=reviewPoly(q&&(q.poly||q.polygon||q.points||q.boundary));if(one2)out.push(one2);}
 return out;}
function reviewCopperAreas(){
 if(pourGeom&&pourSrcFresh(pourGeom))return pourGeom.areas;
 var out=[],seen=new Set();
 function add(list,kind){(list||[]).forEach(function(q){if(!q||seen.has(q))return;seen.add(q);
   var hs=reviewHoles(q);
   reviewAreaPolys(q).forEach(function(poly){out.push({q:q,poly:poly,kind:kind,holes:hs});});});}
 // Declared-stackup pours AND the carved fills for user-drawn copper pours
 // (PCB.zone_fills, keyed to PCB.zones by index) paint identically — a solid
 // net-coloured wash with even-odd antipad holes. The raw PCB.zones polygons
 // then add an always-visible dashed boundary (see paintPours), so an unfilled
 // or not-yet-filled zone is still selectable.
 add(PCB.pours,"pour");add(PCB.plane_fills,"plane");add(PCB.zone_fills,"pour");add(PCB.zones,"zone");add(PCB.imported_zones,"zone");add(PCB.importedZones,"zone");
 out.forEach(pourGeomBuild);
 var s=pourSrcs();
 pourGeom={areas:out,src:s,len:s.map(function(l){return l?l.length:-1;})};
 return out;}
function reviewCopperAt(x,y,L){return reviewCopperAreas().some(function(a){var q=a.q;
 return !q.keepout&&a.kind!=="zone"&&reviewAreaLayer(q)===L&&polyContains(a.poly,x,y)&&
  !a.holes.some(function(h){return polyContains(h,x,y);});});}
function reviewSurfaceNetAt(m){var net="";
 reviewCopperAreas().forEach(function(a){var q=a.q;if(net||q.keepout||!q.net)return;
  var L=reviewAreaLayer(q),st=reviewAreaStack(q);if(st&&st.l==null&&st.i!==activeStack)return;
  if(L!=null&&layerAlpha(L)<=0)return;
  // A point inside an antipad hole is bare board, not the pour's copper.
  if(polyContains(a.poly,m.x,m.y)&&!a.holes.some(function(h){return polyContains(h,m.x,m.y);}))net=q.net;});
 if(net)return net;
 var plane="";STACK.some(function(L){if(L.i!==activeStack||!L.plane)return false;
  var pts=reviewBoardPoints();if(pts.length>=3&&polyContains(pts,m.x,m.y)){plane=L.plane;return true;}return false;});
 return plane;}
function reviewLayerByName(name){var k=reviewText(name),hit=null;
 STACK.some(function(L){if(reviewText(L.name)===k){hit=L;return true;}return false;});return hit;}
// ONE layer key per blob geometry, resolved through the layer table: a KiCad
// layer NAME in `layer` (declared pours, plane fills, zone fills), a name ARRAY
// in `layers` (keepouts), or the 1-based physical `stack` index (plane fills
// also carry it). `side` survives on outer-face geometry for cheap per-frame
// face tests and is never the layer authority.
function reviewAreaStack(q){if(!q)return null;
 if(typeof q.stack==="number"){var byIdx=stackByIndex(q.stack);if(byIdx)return byIdx;}
 var name=(typeof q.layer==="string")?q.layer:(Array.isArray(q.layers)?q.layers[0]:null);
 return name?reviewLayerByName(name):null;}
function reviewAreaLayer(q){var st=reviewAreaStack(q);return st&&typeof st.l==="number"?st.l:null;}
function reviewAreaFocused(q){var st=reviewAreaStack(q);return !!st&&st.i===activeStack;}
function reviewAreaLayerNames(q,L){var out=[];
 if(Array.isArray(q.layers))q.layers.forEach(function(n){if(n!=null&&out.indexOf(String(n))<0)out.push(String(n));});
 else if(typeof q.layer==="string")out.push(q.layer);
 if(!out.length)out.push(L==null?"copper zone":layerName(L));return out;}
// A region covering the whole copper stack reads as "All layers" rather than
// listing every row — the display rule the old magic `layers:"all"` string was.
function reviewAreaSpansStack(q){return !!q&&Array.isArray(q.layers)&&q.layers.length>=STACK.length;}
function reviewAreaLayerName(q,L){
 return reviewAreaSpansStack(q)?"All layers":reviewAreaLayerNames(q,L).join(", ");}
function reviewBoardPoints(){var o=PCB.outline,pts=o&&o.pts&&o.pts.length?o.pts:(PCB.board_poly||null),out=[];
 if(CAM_REVIEW&&PCB.cam.profile&&PCB.cam.profile.length>=3)return PCB.cam.profile;
 if(pts&&pts.length>=3)pts.forEach(function(p){var q=reviewPoint(p);if(q)out.push(q);});
 if(out.length>=3)return out;var b=o||PCB.board;if(!b||!(b.w>0)||!(b.h>0))return [];
 return [[b.x,b.y],[b.x+b.w,b.y],[b.x+b.w,b.y+b.h],[b.x,b.y+b.h]];}
function reviewPlaneLayers(){var out=[];if(!reviewFocusActive())return out;
 STACK.forEach(function(L){if(L.plane&&reviewFocusNet(L.plane))out.push(L);});return out;}
function paintFocusedPlanes(ctx,k){var planes=reviewPlaneLayers();if(!planes.length||(PCB.plane_fills||[]).length)return;
 var pts=reviewBoardPoints();if(pts.length<3)return;var ik=1/Math.max(k||1,0.01);
 planes.forEach(function(L,pi){ctx.beginPath();ctx.moveTo(X(pts[0][0]),Y(pts[0][1]));
  for(var i=1;i<pts.length;i++)ctx.lineTo(X(pts[i][0]),Y(pts[i][1]));ctx.closePath();
  ctx.globalAlpha=0.13;ctx.fillStyle=L.c||"#58d6ff";ctx.fill();ctx.globalAlpha=0.8;
  ctx.strokeStyle="#8be9ff";ctx.lineWidth=1.5;ctx.setLineDash([8,5]);ctx.stroke();ctx.setLineDash([]);
  ctx.font="700 "+(11*ik).toFixed(2)+"px system-ui,sans-serif";ctx.textAlign="left";ctx.textBaseline="top";
  ctx.fillStyle="#8be9ff";ctx.fillText(L.plane+" plane · "+L.name,X(pts[0][0])+6*ik,Y(pts[0][1])+(6+pi*14)*ik);
  ctx.globalAlpha=1;});}

function reviewBoundsAdd(b,x,y){if(!isFinite(x)||!isFinite(y))return;b.x0=Math.min(b.x0,x);b.y0=Math.min(b.y0,y);b.x1=Math.max(b.x1,x);b.y1=Math.max(b.y1,y);b.n++;}
function reviewBoundsBox(b,q){reviewBoundsAdd(b,q.x0,q.y0);reviewBoundsAdd(b,q.x1,q.y1);}
function reviewFocusBounds(){var b={x0:1e18,y0:1e18,x1:-1e18,y1:-1e18,n:0};if(!reviewFocusActive())return b;
 P.forEach(function(p,i){var pins=reviewFocus.pinIdx&&reviewFocus.pinIdx[i];
  if(pins)(p.pads||[]).forEach(function(pd){if(pins[reviewText(pd.num)])reviewBoundsBox(b,wrect(i,pd));});
  else if(reviewFocus.partIdx[i])reviewBoundsBox(b,partAABB(i));});
 (PCB.tracks||[]).forEach(function(t){if(reviewFocusNet(t.net))trackChords(t).forEach(function(s){reviewBoundsAdd(b,s.x1,s.y1);reviewBoundsAdd(b,s.x2,s.y2);});});
 (PCB.vias||[]).forEach(function(v){if(reviewFocusNet(v.net)){var r=(v.d||0.4)/2;reviewBoundsAdd(b,v.x-r,v.y-r);reviewBoundsAdd(b,v.x+r,v.y+r);}});
 reviewCopperAreas().forEach(function(a){if(!a.q.keepout&&reviewFocusNet(a.q.net))a.poly.forEach(function(p){reviewBoundsAdd(b,p[0],p[1]);});});
 if(reviewPlaneLayers().length)reviewBoardPoints().forEach(function(p){reviewBoundsAdd(b,p[0],p[1]);});return b;}
function reviewFit(context){var b=reviewFocusBounds();if(!b.n)return;var sx0=X(b.x0),sy0=Y(b.y0),sx1=X(b.x1),sy1=Y(b.y1);
 var w=Math.max(sx1-sx0,VBW*0.025),h=Math.max(sy1-sy0,VBW*0.025);w*=1.28;h*=1.28;
 var cx=(sx0+sx1)/2,cy=(sy0+sy1)/2,ar=hostAspect();
 if(context){var frameW=VBW,frameH=VBW*ar;if(frameH<VBH){frameH=VBH;frameW=VBH/ar;}
  w=Math.max(w,frameW*REVIEW_CONTEXT_FRACTION);h=Math.max(h,frameH*REVIEW_CONTEXT_FRACTION);}
 if(h/w<ar)h=w*ar;else w=h/ar;
 vb={x:cx-w/2,y:cy-h/2,w:w,h:h};setVB();}

function reviewStats(){var f=reviewFocus||{refIdx:{},partIdx:{},pinIdx:{},netKeys:{},refs:[],pins:[],nets:[],wantRefs:[],wantPins:[],wantNets:[]};
 var refs=[],endpoints=[],tracks=0,vias=0,pours=[],zones=[],length=0,layers={},planes=[];
 P.forEach(function(p,i){if(f.partIdx[i])refs.push(p.ref);(p.pads||[]).forEach(function(pd){
  if(!(f.refIdx[i]||reviewFocusNet(pd.net)))return;endpoints.push({ref:p.ref,pad:pd.num||"",net:pd.net||""});
  if(pd.drill>0){layers[layerName(0)]=1;layers[layerName(1)]=1;}else layers[layerName(p.side==="bottom"?1:0)]=1;});});
 (PCB.tracks||[]).forEach(function(t){if(!reviewFocusNet(t.net))return;tracks++;length+=trackLength(t);layers[layerName(t.l||0)]=1;});
 (PCB.vias||[]).forEach(function(v){if(!reviewFocusNet(v.net))return;vias++;STACK.forEach(function(L){layers[L.name]=1;});});
 reviewCopperAreas().forEach(function(a){if(a.q.keepout||!reviewFocusNet(a.q.net))return;var bag=a.kind==="pour"?pours:zones;
  if(bag.indexOf(a.q)<0)bag.push(a.q);reviewAreaLayerNames(a.q,reviewAreaLayer(a.q)).forEach(function(n){layers[n]=1;});});
 reviewPlaneLayers().forEach(function(L){planes.push(L.name);layers[L.name]=1;});
 refs.sort();var copper=tracks+vias+pours.length+zones.length+planes.length;
 return {requestedRefs:f.wantRefs||[],requestedPins:f.wantPins||[],requestedNets:f.wantNets||[],
  selectedRefs:f.refs||[],selectedPins:f.pins||[],refs:refs,refCount:refs.length,
  matchedNets:f.nets||[],endpoints:endpoints,pads:endpoints.length,tracks:tracks,vias:vias,pours:pours.length,zones:zones.length,
  traceLengthMm:length,layers:Object.keys(layers),planeLayers:planes,noCopper:!!((f.nets||[]).length&&!copper),
  // Compact snake-case aliases are the stable parent-page summary contract;
  // keep the detailed camel-case fields above for direct API consumers.
  parts:refs.length,endpoint_count:endpoints.length,track_count:tracks,track_length_mm:length,
  matched_nets:f.nets||[],plane_layers:planes,no_copper:!!((f.nets||[]).length&&!copper)};}
function reviewSet(spec){stickyNetSet(null);spec=spec||{};
 var wantRefs=reviewList(spec.refs),wantPins=reviewPins(spec.pins),wantNets=reviewList(spec.nets);
 var side=spec.side==="bottom"?"bottom":spec.side==="top"?"top":null;
 var rr=reviewResolveRefs(wantRefs,side),rp=reviewResolvePins(wantPins,side),rn=reviewResolveNets(wantNets);
 reviewPickedRefCur=wantRefs.length===1&&!wantNets.length?reviewText(rr.refs[0]||wantRefs[0]):null;
 reviewPickedRefSide=side;
 var partIdx={};Object.keys(rr.idx).forEach(function(i){partIdx[i]=1;});
 Object.keys(rp.idx).forEach(function(i){partIdx[i]=1;});
 P.forEach(function(p,i){if((p.pads||[]).some(function(pd){return !!rn.keys[reviewNetKey(pd.net)];}))partIdx[i]=1;});
 reviewFocus={kind:reviewText(spec.kind),wantRefs:wantRefs,wantPins:wantPins,wantNets:wantNets,
  refIdx:rr.idx,partIdx:partIdx,pinIdx:rp.idx,netKeys:rn.keys,refs:rr.refs,pins:rp.pins,nets:rn.nets,
  active:Object.keys(partIdx).length>0||Object.keys(rn.keys).length>0};
 dragCacheDrop();if(spec.fit&&reviewFocus.active)reviewFit(!!spec.context);paintSoon();return reviewStats();}
function reviewClear(){reviewFocus=null;reviewPickedRefCur=null;reviewPickedRefSide=null;stickyNetSet(null);
 dragCacheDrop();paintSoon();return reviewStats();}
function reviewViewportSwap(){var cx=vb.x+vb.w/2,cy=vb.y+vb.h/2,w=vb.h;
 vb.h=vb.w;vb.w=w;vb.x=cx-vb.w/2;vb.y=cy-vb.h/2;}
function reviewApplyOrientation(){if(!reviewOriented)return;
 var w=sceneHost.clientWidth,h=sceneHost.clientHeight;if(!w||!h)return;
 var quarter=reviewRotation%180!==0;
 sceneShell.style.position="absolute";sceneShell.style.flex="none";
 sceneShell.style.left="50%";sceneShell.style.top="50%";
 sceneShell.style.width=(quarter?h:w)+"px";sceneShell.style.height=(quarter?w:h)+"px";
 sceneShell.style.transform="translate(-50%, -50%) rotate("+reviewRotation+"deg) scaleX("+
  (reviewSide==="bottom"?-1:1)+")";
 vbResize();}
function reviewOrient(side,rotation){var nextSide=side==="bottom"?"bottom":"top";
 var raw=parseInt(rotation,10),nextRotation=isFinite(raw)?((Math.round(raw/90)*90)%360+360)%360:0;
 if((reviewRotation%180!==0)!==(nextRotation%180!==0))reviewViewportSwap();
 reviewSide=nextSide;reviewRotation=nextRotation;reviewOriented=true;
 var next=reviewSide==="bottom"&&NSIG>1?1:0;activeLayer=next;var st=stackForSignal(next);if(st)activeStack=st.i;
 var s=document.getElementById("pcb-actlayer");if(s)s.value=String(activeStack);
 if(PCB.apSync)PCB.apSync();statusLayer();reviewApplyOrientation();}
window.PCBReviewFocus={set:reviewSet,clear:reviewClear};
window.addEventListener("message",function(ev){var msg=ev.data;
 if(!msg||ev.origin!==window.location.origin)return;
 if(msg.type==="eda-pcb-parts-request"){reviewPostParts(ev.source,ev.origin);return;}
 if(msg.type==="eda-pcb-orientation"){if(RO)reviewOrient(msg.side,msg.rotation);return;}
 if(msg.type==="eda-pcb-cam-visibility"){reviewCamVisibility(msg.layers);return;}
 if(msg.type!=="eda-pcb-focus")return;
 if(msg.design!=null&&String(msg.design)!==String(PCB.name))return;
 var stats=msg.clear?reviewClear():reviewSet(msg),reply={type:"eda-pcb-focus-result",design:PCB.name};
 Object.keys(stats).forEach(function(k){reply[k]=stats[k];});
 if(msg.requestId!=null)reply.requestId=msg.requestId;
 try{if(ev.source&&ev.source.postMessage)ev.source.postMessage(reply,ev.origin);}catch(e){};});
function vbResize(){svgMetricsDrop();var ar=hostAspect(),cy=vb.y+vb.h/2,h=vb.w*ar;
 vb.y=cy-h/2;vb.h=h;setVB();}
window.addEventListener("resize",function(){if(reviewOriented)reviewApplyOrientation();else vbResize();paintSoon();});
// The stage also reflows WITHOUT a window resize (legend toggles, panels
// opening) — observe the host so the oriented shell and viewport stay aligned.
if(window.ResizeObserver){try{
 new ResizeObserver(function(){if(reviewOriented)reviewApplyOrientation();else vbResize();paintSoon();}).observe(sceneHost);}catch(e){}}
function zoomAt(cx,cy,f){if((f<1&&vb.w<VBW*0.08)||(f>1&&vb.w>VBW*8))return;
 var p=svgScreenPoint(cx,cy),px=p.x,py=p.y;
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
 var r=svgMetricsGet(),dx=ev.deltaX,dy=ev.deltaY;
 if(ev.deltaMode===1){dx*=16;dy*=16;}else if(ev.deltaMode===2){dx*=r.width;dy*=r.height;}
 if(wheelIsMouse(ev)){zoomAt(ev.clientX,ev.clientY,dy<0?0.85:1.18);return;}
 var d=svgScreenDelta(dx,dy);vb.x+=d.x;vb.y+=d.y;setVB();},{passive:false});
function zc(f){var r=svgMetricsGet();zoomAt(r.left+r.width/2,r.top+r.height/2,f);}
var zi=document.getElementById("z-in");if(zi)zi.addEventListener("click",function(){zc(0.8);});
var zo=document.getElementById("z-out");if(zo)zo.addEventListener("click",function(){zc(1.25);});
var zf=document.getElementById("z-fit");if(zf)zf.addEventListener("click",function(){fitVB();});
// Compact desktop chrome: the activity rail opens one overlay dock at a time,
// leaving the full editing tool strip and keyboard workflow intact.
function compactDockSet(which,open,pane){
 var side=document.getElementById("pcb-side"),appearance=document.getElementById("pcb-appear");
 if(!compactDockMode())open=false;
 var sideOn=!!open&&which==="side",appearanceOn=!!open&&which==="appearance";
 if(side)side.classList.toggle("compact-open",sideOn);
 if(appearance)appearance.classList.toggle("compact-open",appearanceOn);
 document.querySelectorAll(".pcb-activity [data-dock-pane]").forEach(function(b){
  b.classList.toggle("active",sideOn&&b.getAttribute("data-dock-pane")===pane);});
 var apBtn=document.querySelector(".pcb-activity [data-dock-appearance]");
 if(apBtn)apBtn.classList.toggle("active",appearanceOn);
 if(open)setTimeout(function(){vbResize();paintSoon();},150);
}
function compactDocksClose(){compactDockSet("",false,"");}
(function(){
 document.querySelectorAll(".pcb-activity [data-dock-pane]").forEach(function(b){
  b.addEventListener("click",function(){var pane=b.getAttribute("data-dock-pane");
   var side=document.getElementById("pcb-side");
   var close=side&&side.classList.contains("compact-open")&&b.classList.contains("active");
   if(close){compactDocksClose();return;}
   pcbSideTab(pane);
   if(pane==="side-find"){var input=document.getElementById("pcb-find-input");if(input){input.focus();input.select();}}
  });});
 var apBtn=document.querySelector(".pcb-activity [data-dock-appearance]");
 if(apBtn)apBtn.addEventListener("click",function(){var ap=document.getElementById("pcb-appear");
  compactDockSet("appearance",!(ap&&ap.classList.contains("compact-open")),"");});
 document.querySelectorAll("[data-dock-close]").forEach(function(b){b.addEventListener("click",compactDocksClose);});
 var changed=function(){compactDocksClose();vbResize();paintSoon();};
 if(COMPACT_DOCK_MQ.addEventListener)COMPACT_DOCK_MQ.addEventListener("change",changed);
 else if(COMPACT_DOCK_MQ.addListener)COMPACT_DOCK_MQ.addListener(changed);
})();
// Phone inspection chrome: the desktop docks become mutually-exclusive bottom
// sheets, while the compact zoom controls proxy the already-wired viewport
// actions. Keeping one zoom path prevents touch and desktop behavior drifting.
function mobilePanelSet(which,open){
 var side=document.querySelector(".pcb-side"),layers=document.getElementById("pcb-appear");
 var infoBtn=document.getElementById("mobile-info"),layersBtn=document.getElementById("mobile-layers");
 if(!mobileInspectMode())open=false;
 var infoOn=!!open&&which==="info",layersOn=!!open&&which==="layers";
 if(side)side.classList.toggle("mobile-open",infoOn);
 if(layers)layers.classList.toggle("mobile-open",layersOn);
 if(infoBtn){infoBtn.classList.toggle("on",infoOn);infoBtn.setAttribute("aria-expanded",infoOn?"true":"false");}
 if(layersBtn){layersBtn.classList.toggle("on",layersOn);layersBtn.setAttribute("aria-expanded",layersOn?"true":"false");}
}
function mobilePanelsClose(){mobilePanelSet("",false);}
function mobileProxy(id,target){
 var b=document.getElementById(id),t=document.getElementById(target);
 if(b&&t)b.addEventListener("click",function(){t.click();});
}
(function(){
 var infoBtn=document.getElementById("mobile-info"),layersBtn=document.getElementById("mobile-layers");
 if(infoBtn)infoBtn.addEventListener("click",function(){
  var side=document.querySelector(".pcb-side"),open=!(side&&side.classList.contains("mobile-open"));
  if(open)pcbSideTab("side-props");else mobilePanelsClose();
 });
 if(layersBtn)layersBtn.addEventListener("click",function(){
  var layers=document.getElementById("pcb-appear"),open=!(layers&&layers.classList.contains("mobile-open"));
  mobilePanelSet("layers",open);
 });
 mobileProxy("mobile-z-out","z-out");
 mobileProxy("mobile-z-in","z-in");
 mobileProxy("mobile-z-fit","z-fit");
 var mqChanged=function(){mobilePanelsClose();renderProps();vbResize();paintSoon();};
 if(MOBILE_MQ.addEventListener)MOBILE_MQ.addEventListener("change",mqChanged);
 else if(MOBILE_MQ.addListener)MOBILE_MQ.addListener(mqChanged);
})();
// Empty-space drag = marquee select (pick every part whose centre lands in the
// box); Space-held or middle-button drag = pan instead. A no-move click clears
// the selection. The rubber-band rect lives in the top layer (pointer-events
// off) and is drawn in SVG coords via X()/Y() so it tracks pan/zoom.
var pan=null,marq=null,marqEl=null;
// ▭ Outline tool: while armed, the visible board outline — including an
// authored `(board …)` shape with no saved override yet — exposes editable
// vertices and edges. A drag on empty board replaces it with a grid-snapped
// rectangle. The resulting override is saved
// with the layout (SavedLayout.outline) and becomes the board edge every
// renderer draws and the board-edge DRC checks. RO pages never arm it.
var outlineMode=false,outDraw=null,outlineSelection=[],outlineRectArmed=false;
function outlineArm(on){
 if(!on&&polyMode&&polySketchOwned)polyArm(false);
 if(on&&heatsinkMode)heatsinkArm(false);
 if(on&&backingMode)backingArm(false);
 if(on&&padAlignMode)padAlignArm(false);
 if(on&&polyMode)polyArm(false);
 if(on&&pourMode)pourArm(false);
 if(on&&drawMode)drawModeSet(false);
 if(on&&textMode)txArm(false);
 if(on&&PCB.rulerOff)PCB.rulerOff();
 outlineMode=on;if(!on)outlineRectArmed=false;
 var b=document.getElementById("pcb-outline");if(b)b.classList.toggle("on",on);
 svg.classList.toggle("outline-mode",on||polyMode);
 var msg=document.getElementById("pcb-savemsg");
 if(msg&&on){msg.style.color="#7ee787";
  msg.textContent="outline sketch: click a segment or box-select vertices, then Delete/Backspace; Esc finishes";}
 else if(msg&&!outDraw){msg.textContent="";}
 outlineSketchPanelSync();toolSync();drawBoardRect();}
function outlinePrimary(){return outlineSelection.length?outlineSelection[outlineSelection.length-1]:null;}
function outlineSelect(type,index,id,ev){if(OS){var sh=activeSketchPromote(),entities=type==="point"?OS.physicalPoints(sh.sketch):OS.physicalCurves(sh.sketch);if(entities[index])id=entities[index].id;}var add=!!(ev&&(ev.ctrlKey||ev.metaKey||ev.shiftKey)),key=type+":"+(id||index),at=-1;
 outlineSelection.forEach(function(s,i){if(s.key===key)at=i;});if(!add)outlineSelection=[];
 if(at>=0&&add)outlineSelection.splice(at,1);else outlineSelection.push({type:type,index:index,id:id||null,key:key});
 outlineSketchPanelSync();if(!activeSketchIsArea())showOutlineProps();drawBoardRect();}
function outlineResolveSelection(){var sh=activeSketchShape();if(!OS||!sh||!sh.sketch)return;var ps=OS.physicalPoints(sh.sketch),cs=OS.physicalCurves(sh.sketch);
 outlineSelection.forEach(function(s){var e=s.type==="point"?ps[s.index]:cs[s.index];if(e)s.id=e.id;});}
function outlineSelected(type){outlineResolveSelection();return outlineSelection.filter(function(s){return s.type===type&&s.id;}).map(function(s){return s.id;});}
function outlineDeleteKeyActive(target){if(polyMode||kbTyping(target))return false;if(outlineMode||activeSketchIsArea())return true;return outlineOnlyFilter()&&outlineSelection.length;}
function outlineDeleteSelected(){if(!OS||!outlineSelection.length)return false;return outlineSketchMutate("selected "+activeSketchName()+" geometry deleted",function(sk){var cs=outlineSelected("curve"),ps=outlineSelected("point"),changed=false;
  // Points go first: each selected vertex and every curve touching it disappear,
  // just as sketch geometry does in Fusion. Explicitly selected curves then
  // disappear on their own; neither operation heals or recloses the profile.
  ps.forEach(function(id){if(OS.deletePoint(sk,id))changed=true;});cs.forEach(function(id){if(OS.deleteSegment(sk,id))changed=true;});
  if(!changed){outlineMsg("select an outline segment or vertex to delete");return false;}outlineSelection=[];return true;});}
function outlineRemoveFilletSelected(){if(!OS||!outlineSelection.length)return false;return outlineSketchMutate("fillet removed and sharp corner restored",function(sk){var cs=outlineSelected("curve"),ps=outlineSelected("point"),arcs=[];
  cs.forEach(function(id){var c=OS.curve(sk,id);if(c&&c.kind==="arc")arcs.push(id);});OS.physicalCurves(sk).forEach(function(c){if(c.kind==="arc"&&ps.indexOf(c.a)>=0&&ps.indexOf(c.b)>=0&&arcs.indexOf(c.id)<0)arcs.push(c.id);});
  var changed=false;arcs.forEach(function(id){if(OS.removeFillet(sk,id))changed=true;});if(!changed){outlineMsg("select a fillet arc, or both of its endpoints");return false;}outlineSelection=[];return true;});}
function outlineSketchMutate(label,fn){if(!OS)return false;var pre=snapAll(),kind=backingMode?"backing":(pourMode?"zone":"outline"),zi=kind==="zone"?(PCB.zones||[]).indexOf(pourEdit):-1,bi=kind==="backing"&&backingEdit?backingEdit.index:-1,bl=kind==="backing"&&backingEdit?(PCB.fabrication_layers||[]).indexOf(backingEdit.layer):-1,shape=activeSketchPromote();outlineResolveSelection();var ok=fn(shape.sketch);
 if(ok===false){restoreSketchSnapshot(pre,kind,zi,bl,bi);drawBoardRect();outlineSketchPanelSync();return false;}
 var solved=OS.solve(shape.sketch),compiled=!solved.conflict&&activeSketchSync(shape);if(!compiled){restoreSketchSnapshot(pre,kind,zi,bl,bi);drawBoardRect();renderProps();outlineSketchPanelSync();outlineMsg("constraint conflict — "+label+" was not applied");return false;}
 activeSketchChanged(compiled);recordUndo(pre);drawBoardRect();renderProps();
 outlineMsg(label+(compiled.closed?" — profile closed; Save/Update to keep":" — profile open; draw lines between loose endpoints"));outlineSketchPanelSync();return true;}
function restoreSketchSnapshot(pre,kind,zi,bl,bi){if(kind==="zone"){PCB.zones=pre.zones;pourEdit=zi>=0&&zi<PCB.zones.length?PCB.zones[zi]:null;pourGeomDrop();}
 else if(kind==="backing"){PCB.fabrication_layers=pre.fabrication_layers;var l=bl>=0&&PCB.fabrication_layers[bl];backingEdit=l&&bi>=0?{layer:l,index:bi,poly:l.regions[bi],sketch:(l.sketches||[])[bi]||null}:null;}
 else{PCB.outline=pre.outline;outlineGeomDrop();}}
function outlineSketchNumber(label,value){var text=window.prompt(label,String(Math.round((+value||0)*1000)/1000));if(text==null)return null;var n=parseFloat(text);return isFinite(n)?n:null;}
function outlineSketchConstraint(kind){return outlineSketchMutate(kind+" constraint",function(sk){var cs=outlineSelected("curve"),ps=outlineSelected("point"),q=null;
  if(kind==="horizontal"||kind==="vertical")q=cs.length&&OS.addConstraint(sk,kind,cs[0]);
  else if(kind==="coincident")q=ps.length>=2&&OS.addConstraint(sk,kind,ps[0],ps[1]);
  else if(kind==="midpoint")q=ps.length&&cs.length&&OS.addConstraint(sk,kind,ps[0],cs[0]);
  else if(kind==="symmetric")q=ps.length>=2&&cs.length&&OS.addConstraint(sk,kind,ps[0],ps[1],null,cs[0]);
  else if(kind==="fixed"){if(ps.length)q=OS.addConstraint(sk,kind,ps[0]);else if(cs.length){var c=OS.curve(sk,cs[0]);q=OS.addConstraint(sk,kind,c.a);if(q)OS.addConstraint(sk,kind,c.b);}}
  else if(cs.length>=2)q=OS.addConstraint(sk,kind,cs[0],cs[1]);
  if(!q){outlineMsg("select compatible points/curves for "+kind);return false;}return true;});}
function outlineSketchDimension(){return outlineSketchMutate("driving dimension added",function(sk){var cs=outlineSelected("curve"),ps=outlineSelected("point"),kind,a,b,val,c;
  if(cs.length){c=OS.curve(sk,cs[0]);kind=c.kind==="arc"?"radius":"length";a=c.id;val=outlineSketchNumber(kind==="radius"?"Arc radius (mm)":"Line length (mm)",c.kind==="arc"?OS.arcCircle(sk,c).r:Math.hypot(OS.point(sk,c.b).x-OS.point(sk,c.a).x,OS.point(sk,c.b).y-OS.point(sk,c.a).y));}
  else if(ps.length>=2){kind="distance";a=ps[0];b=ps[1];val=outlineSketchNumber("Point distance (mm)",Math.hypot(OS.point(sk,b).x-OS.point(sk,a).x,OS.point(sk,b).y-OS.point(sk,a).y));}
  else{outlineMsg("select one curve or two points to dimension");return false;}if(val==null||!(val>0))return false;return !!OS.addConstraint(sk,kind,a,b,val);});}
function outlineSketchModify(action){return outlineSketchMutate(action,function(sk){var cs=outlineSelected("curve"),ps=outlineSelected("point"),c,p,n,g;
  if(action==="arc"){if(!cs.length)return false;c=OS.curve(sk,cs[0]);p=OS.point(sk,c.a);var z=OS.point(sk,c.b),dx=z.x-p.x,dy=z.y-p.y,L=Math.hypot(dx,dy);n=outlineSketchNumber("Arc rise at midpoint (mm)",Math.max(.5,L/5));if(n==null)return false;if(!activeSketchIsArea())PCB.outline.radii=null;return OS.toArc(sk,c.id,[(p.x+z.x)/2-dy/L*n,(p.y+z.y)/2+dx/L*n]);}
  if(action==="line")return cs.length&&OS.toLine(sk,cs[0]);
  if(action==="fillet"||action==="chamfer"){if(!ps.length)return false;n=outlineSketchNumber((action==="fillet"?"Fillet radius":"Chamfer distance")+" (mm)",1);if(n==null||!(n>0))return false;if(!activeSketchIsArea())PCB.outline.radii=null;return !!(action==="fillet"?OS.filletPoint(sk,ps[0],n):OS.chamferPoint(sk,ps[0],n));}
  if(action==="offset"){n=outlineSketchNumber("Profile offset (mm, positive = outward)",1);return n!=null&&OS.offset(sk,n);}
  if(action==="mirror-x"||action==="mirror-y"){g=OS.compile(sk);return g&&OS.mirror(sk,action==="mirror-x"?"x":"y",action==="mirror-x"?g.rect.x+g.rect.w/2:g.rect.y+g.rect.h/2);}return false;});}
function outlineSketchPanelSync(){var host=svg&&svg.parentNode,p=document.getElementById("outline-sketch-palette"),active=outlineMode||activeSketchIsArea();if(!active||RO||!OS){if(p)p.remove();return;}if(!p){p=document.createElement("div");p.id="outline-sketch-palette";p.className="outline-sketch-palette";host.appendChild(p);}
 var sh=activeSketchShape(),sk=sh&&sh.sketch,st=sk?OS.state(sk):null,sg=sk&&OS.compile(sk),title=activeSketchName()+" sketch",closable=!!(sg&&!sg.closed&&OS.canCloseProfile&&OS.canCloseProfile(sk));p.innerHTML='<div class="osp-head"><b>'+title.charAt(0).toUpperCase()+title.slice(1)+'</b><span class="osp-dof '+(st&&st.conflict?'bad':'')+'">'+(st?(st.conflict?'conflict':((sg&&!sg.closed?'open · ':'')+st.dof+' DOF')):'select or create a shape')+'</span></div>'+
  '<div class="osp-group"><span>Create</span><button data-sk="new-rect"'+(outlineRectArmed?' class="on"':'')+'>Rectangle</button><button data-sk="new-poly"'+(polyMode&&polySketchOwned?' class="on"':'')+'>Line</button><button data-sk="dimension">Dimension</button></div>'+
  (closable?'<button class="osp-finish osp-repair" data-sk="close-profile">Close profile</button>':'')+
  '<div class="osp-group"><span>Constrain</span><button data-sk="horizontal">H</button><button data-sk="vertical">V</button><button data-sk="coincident">Coincident</button><button data-sk="parallel">∥</button><button data-sk="perpendicular">⟂</button><button data-sk="tangent">Tangent</button><button data-sk="equal">Equal</button><button data-sk="midpoint">Midpoint</button><button data-sk="symmetric">Symmetry</button><button data-sk="fixed">Fix</button></div>'+
  '<div class="osp-group"><span>Modify</span><button data-sk="arc">Arc</button><button data-sk="line">Line</button><button data-sk="fillet">Fillet</button><button data-sk="remove-fillet">Remove fillet</button><button data-sk="chamfer">Chamfer</button><button data-sk="offset">Offset</button><button data-sk="mirror-x">Mirror X</button><button data-sk="mirror-y">Mirror Y</button></div>'+
  (pourMode&&pourEdit?'<button class="osp-finish" data-sk="properties">Type / net / layer…</button>':'')+
  '<button class="osp-finish" data-sk="finish">Finish sketch</button>';
 p.querySelectorAll("[data-sk]").forEach(function(b){b.addEventListener("click",function(){var a=b.getAttribute("data-sk");if(a==="finish"){if(polyMode)polyArm(false);if(backingMode)backingArm(false);else if(pourMode)pourArm(false);else outlineArm(false);}else if(a==="close-profile")outlineSketchMutate("profile closed",function(sk){return OS.closeProfile(sk);});else if(a==="properties"&&pourEdit)openPourDialog(pourEdit.poly,pourEdit);else if(a==="new-poly")polyArm(!(polyMode&&polySketchOwned),true);else if(a==="new-rect"){if(polyMode)polyArm(false);outlineRectArmed=!outlineRectArmed;outlineSketchPanelSync();outlineMsg(outlineRectArmed?"rectangle armed: drag empty board space to replace the "+activeSketchName():"rectangle cancelled: empty drag box-selects sketch vertices");}else if(a==="remove-fillet")outlineRemoveFilletSelected();else if(a==="dimension")outlineSketchDimension();else if(["horizontal","vertical","coincident","parallel","perpendicular","tangent","equal","midpoint","symmetric","fixed"].indexOf(a)>=0)outlineSketchConstraint(a);else outlineSketchModify(a);});});}
// ⬡ Poly / in-sketch Line tool: click connected outline segments freely.
// Endpoints magnetize to existing corners and the chain start, infer horizontal
// or vertical alignment, and otherwise use the grid. Enter finishes an open
// chain; clicking its first point closes it. Inside Outline sketch, finished
// lines join the existing native sketch instead of replacing the whole board.
var polyMode=false,polyPts=null,polyCur=null,polySketchOwned=false,vdrag=null;
// ▩ Pour tool state (user-drawn custom copper pours): an in-progress polygon
// (pourPts + rubber pourCur), an open net/layer dialog (pourDlg). Separate from
// the ⬡ Poly outline tool — a closed pour becomes a PCB.zones entry (copper
// region filled server-side), not the board edge.
var pourMode=false,pourPts=null,pourCur=null,pourDlg=null,pourEdit=null,pourDialogSnap=null;
function activeSketchIsArea(){return !!((pourMode&&pourEdit)||(backingMode&&backingEdit));}
function activeSketchShape(){return backingMode&&backingEdit?backingEdit:(pourMode&&pourEdit?pourEdit:PCB.outline);}
function activeSketchName(){if(backingMode&&backingEdit)return "backing region";if(pourMode&&pourEdit)return pourEdit.keepout?"copper keepout":"copper pour";return "outline";}
function activeSketchPromote(){var shape=activeSketchShape();if(activeSketchIsArea()){if(OS)OS.ensurePolygon(shape);return shape;}outlinePromote();return PCB.outline;}
function activeSketchSync(shape){if(!activeSketchIsArea())return OS.syncOutline(shape);var compiled=OS.syncPolygon(shape);if(backingMode&&backingEdit){backingEdit.layer.regions[backingEdit.index]=shape.poly;(backingEdit.layer.sketches=backingEdit.layer.sketches||[])[backingEdit.index]=shape.sketch;}return compiled;}
function activeSketchChanged(compiled){if(backingMode&&backingEdit){markDirty();paintSoon();}
 else if(activeSketchIsArea()){pourGeomDrop();dragCacheDrop();paintSoon();markPoursStale();if(compiled&&compiled.closed)refillPours();}
 else{outlineGeomDrop();if(compiled&&compiled.closed)scheduleDrc();}}
function polyArm(on,withinOutline){if(RO&&on)return;
 if(on&&heatsinkMode)heatsinkArm(false);
 if(on&&backingMode&&!withinOutline)backingArm(false);
 if(on&&padAlignMode)padAlignArm(false);
 if(on&&outlineMode&&!withinOutline)outlineArm(false);
 if(on&&pourMode&&!withinOutline)pourArm(false);
 if(on&&drawMode)drawModeSet(false);
 if(on&&textMode)txArm(false);
 if(on&&PCB.rulerOff)PCB.rulerOff();
 if(on&&withinOutline)outlineRectArmed=false;
 polyMode=on;polySketchOwned=!!(on&&withinOutline);
 if(!on){polyPts=null;polyCur=null;polySketchOwned=false;}
 var b=document.getElementById("pcb-outline-poly");if(b)b.classList.toggle("on",on);
 svg.classList.toggle("outline-mode",on||outlineMode);
 var msg=document.getElementById("pcb-savemsg");
 if(msg&&on){msg.style.color="#7ee787";
  msg.textContent=activeSketchName()+" line: click endpoints — corners and H/V snap; Enter keeps the chain open, or click its first point to close";}
 else if(msg&&!on){msg.textContent="";}
 toolSync();outlineSketchPanelSync();
 drawBoardRect();}
function polySnap(m){var existing=outlinePtsOf(activeSketchIsArea()?activeSketchShape():outlineEditable())||[],tol=9/S,g=viewSt.grid;return OS&&OS.snapLinePoint?OS.snapLinePoint(polyPts||[],existing,m.x,m.y,g,tol,6/S):{x:g>0?Math.round(m.x/g)*g:m.x,y:g>0?Math.round(m.y/g)*g:m.y};}
// New copper-area vertices share the Line tool's screen-space H/V inference.
// Shift still bypasses the drawing grid; Ctrl bypasses only axis inference so
// a deliberately shallow diagonal remains available without changing grids.
function pourSnap(m,ev){var g=ev&&ev.shiftKey?0:G,axis=!(ev&&ev.ctrlKey);
 return axis&&OS&&OS.snapLinePoint?OS.snapLinePoint(pourPts||[],[],m.x,m.y,g,0,6/S):{x:g>0?Math.round(m.x/g)*g:m.x,y:g>0?Math.round(m.y/g)*g:m.y,axis:null};}
function outlineMsg(txt){var msg=document.getElementById("pcb-savemsg");
 if(msg){msg.style.color="#8b949e";msg.textContent=txt;}}
function heatsinkArm(on){if(RO&&on)return;
 if(on){if(backingMode)backingArm(false);if(padAlignMode)padAlignArm(false);if(outlineMode)outlineArm(false);if(polyMode)polyArm(false);if(pourMode)pourArm(false);if(drawMode)drawModeSet(false);if(textMode)txArm(false);if(PCB.rulerOff)PCB.rulerOff();}
 if(on&&!viewSt.vis.heatsink){viewSt.vis.heatsink=1;viewSave();if(PCB.apSync)PCB.apSync();drawBoardRect();}
 heatsinkMode=!!on;if(!on){heatsinkDraw=null;if(heatsinkDrag&&heatsinkDrag.snap)restoreSnap(heatsinkDrag.snap);heatsinkDrag=null;}var b=document.getElementById("pcb-heatsink");if(b)b.classList.toggle("on",heatsinkMode);
 svg.style.cursor=heatsinkMode?"crosshair":"";if(heatsinkMode)outlineMsg(PCB.heatsink?"heatsink: drag the body to move, drag a corner to resize, or click it to edit parameters":"heatsink: drag its base rectangle on the board; Esc exits");
 toolSync();drawBoardRect();}
function hsHit(m){var s=PCB.heatsink;return !!s&&m.x>=s.x&&m.x<=s.x+s.w&&m.y>=s.y&&m.y<=s.y+s.h;}
function hsHandleAt(m){var s=PCB.heatsink;if(!s)return null;var d=8/S,pts=[["nw",s.x,s.y],["ne",s.x+s.w,s.y],["se",s.x+s.w,s.y+s.h],["sw",s.x,s.y+s.h]];
 for(var i=0;i<pts.length;i++)if(Math.max(Math.abs(m.x-pts[i][1]),Math.abs(m.y-pts[i][2]))<=d)return pts[i][0];return hsHit(m)?"move":null;}
function hsCursor(kind){return kind==="move"?"move":((kind==="nw"||kind==="se")?"nwse-resize":"nesw-resize");}
function hsDragStart(kind,m){return {kind:kind,sx:m.x,sy:m.y,orig:cloneHeatsink(),snap:snapAll(),moved:false};}
function hsDragMove(m){var d=heatsinkDrag,o=d&&d.orig,s=PCB.heatsink;if(!d||!o||!s)return;var g=snapG(),x0=o.x,y0=o.y,x1=o.x+o.w,y1=o.y+o.h;
 if(d.kind==="move"){var dx=Math.round((m.x-d.sx)/g)*g,dy=Math.round((m.y-d.sy)/g)*g;x0=o.x+dx;x1=x0+o.w;y0=o.y+dy;y1=y0+o.h;}
 else{var mx=Math.round(m.x/g)*g,my=Math.round(m.y/g)*g;if(d.kind.indexOf("w")>=0)x0=Math.min(mx,x1-2);else x1=Math.max(mx,x0+2);if(d.kind.indexOf("n")>=0)y0=Math.min(my,y1-2);else y1=Math.max(my,y0+2);}
 if(s.x===x0&&s.y===y0&&s.w===x1-x0&&s.h===y1-y0)return;s.x=x0;s.y=y0;s.w=x1-x0;s.h=y1-y0;d.moved=true;drawBoardRect();}
function hsBestTarget(r){var cx=r.x+r.w/2,cy=r.y+r.h/2,best="",score=Infinity;
 P.forEach(function(p){var dx=p.x-cx,dy=p.y-cy,d=dx*dx+dy*dy,inside=p.x>=r.x&&p.x<=r.x+r.w&&p.y>=r.y&&p.y<=r.y+r.h;
  var s=(inside?0:1e6)+d;if(s<score){score=s;best=p.ref;}});return best;}
function hsNum(id,fallback){var e=document.getElementById(id),n=parseFloat(e&&e.value);return isFinite(n)?n:fallback;}
function hsMaterialK(name){return {aluminum_6063:201,aluminum_6061:167,copper_c110:391,steel:50}[name]||201;}
function hsEstimate(s){var axis=s.fin_axis||"length",across=(axis==="length"?s.w:s.h),along=(axis==="length"?s.h:s.w),pitch=s.fin_thickness_mm+s.fin_gap_mm;
 var n=Math.min(512,Math.max(1,Math.floor((across+s.fin_gap_mm)/pitch))),k=hsMaterialK(s.material),hm=s.fin_height_mm/1000,tm=s.fin_thickness_mm/1000,lm=along/1000,am=across/1000;
 var ml=hm*Math.sqrt(20/(k*tm)),eta=ml>1e-9?Math.tanh(ml)/ml:1,fa=n*lm*(2*hm+tm),ba=lm*Math.max(am-n*tm,0),ae=ba+eta*fa;
 var theta=1/(10*ae)+(s.base_mm/1000)/(k*(s.w/1000)*(s.h/1000));return {count:n,theta:theta,eta:eta};}
function hsFromForm(){var s={x:hsNum("hs-x-mm",0),y:hsNum("hs-y-mm",0),w:hsNum("hs-w",0),h:hsNum("hs-h",0),side:(document.getElementById("hs-side")||{}).value||"bottom",target_ref:(document.getElementById("hs-target")||{}).value||"",material:(document.getElementById("hs-material")||{}).value||"aluminum_6063",base_mm:hsNum("hs-base",2),fin_height_mm:hsNum("hs-fin-h",10),fin_thickness_mm:hsNum("hs-fin-t",1),fin_gap_mm:hsNum("hs-fin-g",1.5),fin_axis:(document.getElementById("hs-axis")||{}).value||"length",pad_thickness_mm:hsNum("hs-pad-t",.5),pad_k_w_mk:hsNum("hs-pad-k",6)};return s;}
function hsFormValid(s){return s.w>0&&s.h>0&&s.base_mm>0&&s.fin_height_mm>=0&&s.fin_thickness_mm>0&&s.fin_gap_mm>=0&&s.pad_thickness_mm>=0&&s.pad_k_w_mk>0&&!!s.target_ref;}
function hsRequestedCount(){return hsNum("hs-fin-count",0);}
function hsCountFits(s){var n=hsRequestedCount(),across=(s.fin_axis==="length"?s.w:s.h);return Number.isInteger(n)&&n>=1&&n<=512&&n*s.fin_thickness_mm<=across+1e-9;}
function hsCountToGap(){var s=hsFromForm(),n=hsRequestedCount(),across=(s.fin_axis==="length"?s.w:s.h),gap=document.getElementById("hs-fin-g");
 if(!gap||!hsCountFits(s)){hsResult();return;}var v=n===1?across-s.fin_thickness_mm:(across-n*s.fin_thickness_mm)/(n-1);gap.value=Math.max(0,v-(v>0?1e-6:0)).toFixed(6);hsResult();}
function hsCountFromGap(){var count=document.getElementById("hs-fin-count");if(count)count.value=hsEstimate(hsFromForm()).count;hsResult();}
function hsResult(){var out=document.getElementById("hs-result"),s=hsFromForm();if(!out)return;
 if(!hsFormValid(s)){out.textContent="Enter positive physical dimensions and select a target package.";return;}
 if(!hsCountFits(s)){out.textContent="Fin count must be 1–512 and the fins must fit across the selected base direction.";return;}
 var e=hsEstimate(s);out.textContent=e.count+" fins · estimated θSA "+e.theta.toFixed(2)+" °C/W · fin efficiency "+(100*e.eta).toFixed(1)+"% · total height "+(s.base_mm+s.fin_height_mm).toFixed(1)+" mm";}
function hsModalClose(){var m=document.getElementById("heatsink-modal");if(m)m.hidden=true;heatsinkEditSnap=null;}
function hsModalShown(){var m=document.getElementById("heatsink-modal");return !!m&&!m.hidden;}
function hsModalOpen(rect){var m=document.getElementById("heatsink-modal");if(!m)return;var old=PCB.heatsink||{},side=old.side||(activeLayer===0?"top":"bottom"),target=old.target_ref||hsBestTarget(rect);
 var vals={"hs-x-mm":rect.x,"hs-y-mm":rect.y,"hs-w":rect.w,"hs-h":rect.h,"hs-side":side,"hs-material":old.material||"aluminum_6063","hs-base":old.base_mm==null ? 2 : old.base_mm,"hs-fin-h":old.fin_height_mm==null ? 10 : old.fin_height_mm,"hs-fin-t":old.fin_thickness_mm==null ? 1 : old.fin_thickness_mm,"hs-fin-g":old.fin_gap_mm==null ? 1.5 : old.fin_gap_mm,"hs-axis":old.fin_axis||"length","hs-pad-t":old.pad_thickness_mm==null ? .5 : old.pad_thickness_mm,"hs-pad-k":old.pad_k_w_mk==null ? 6 : old.pad_k_w_mk};
 Object.keys(vals).forEach(function(id){var e=document.getElementById(id);if(e)e.value=vals[id];});var sel=document.getElementById("hs-target");sel.textContent="";P.forEach(function(p){var o=document.createElement("option");o.value=p.ref;o.textContent=p.ref+" · "+(p.side||"top");sel.appendChild(o);});if(target)sel.value=target;
 var count=document.getElementById("hs-fin-count");if(count)count.value=hsEstimate(hsFromForm()).count;var title=document.getElementById("hs-title"),save=document.getElementById("hs-save");if(title)title.textContent=PCB.heatsink?"Edit physical heatsink":"Physical heatsink";if(save)save.textContent=PCB.heatsink?"Update heatsink":"Use heatsink";
 heatsinkEditSnap=snapAll();m.hidden=false;hsResult();}
var hsBtn=document.getElementById("pcb-heatsink");if(hsBtn)hsBtn.addEventListener("click",function(){heatsinkArm(!heatsinkMode);});
(function(){var ids=["hs-x-mm","hs-y-mm","hs-side","hs-target","hs-material","hs-base","hs-fin-h","hs-pad-t","hs-pad-k"];ids.forEach(function(id){var e=document.getElementById(id);if(e){e.addEventListener("input",hsResult);e.addEventListener("change",hsResult);}});
 ["hs-w","hs-h","hs-fin-t","hs-axis"].forEach(function(id){var e=document.getElementById(id);if(e){e.addEventListener("input",hsCountToGap);e.addEventListener("change",hsCountToGap);}});var count=document.getElementById("hs-fin-count"),gap=document.getElementById("hs-fin-g");if(count){count.addEventListener("input",hsCountToGap);count.addEventListener("change",hsCountToGap);}if(gap){gap.addEventListener("input",hsCountFromGap);gap.addEventListener("change",hsCountFromGap);}
 var close=function(){hsModalClose();};["hs-x","hs-cancel"].forEach(function(id){var e=document.getElementById(id);if(e)e.addEventListener("click",close);});
 var save=document.getElementById("hs-save");if(save)save.addEventListener("click",function(){var s=hsFromForm();if(!hsFormValid(s)||!hsCountFits(s)){hsResult();return;}recordUndo(heatsinkEditSnap||snapAll());PCB.heatsink=s;hsModalClose();heatsinkArm(false);drawBoardRect();if(window.PCB3D&&window.PCB3D.sync)window.PCB3D.sync();outlineMsg("heatsink updated — Save/Update to keep and refresh Thermal");});
 var del=document.getElementById("hs-delete");if(del)del.addEventListener("click",function(){if(PCB.heatsink){recordUndo(heatsinkEditSnap||snapAll());PCB.heatsink=null;}hsModalClose();heatsinkArm(false);drawBoardRect();if(window.PCB3D&&window.PCB3D.sync)window.PCB3D.sync();outlineMsg("heatsink removed — Save/Update to keep");});})();
function backingArm(on){if(RO&&on)return;
 if(on&&heatsinkMode)heatsinkArm(false);
 if(on&&padAlignMode)padAlignArm(false);
 if(on&&outlineMode)outlineArm(false);if(on&&polyMode)polyArm(false);if(on&&pourMode)pourArm(false);
 if(on&&drawMode)drawModeSet(false);if(on&&textMode)txArm(false);if(on&&PCB.rulerOff)PCB.rulerOff();
 backingMode=!!on;if(!on){backingEdit=null;outlineSelection=[];outlineRectArmed=false;}else if(!backingEdit){var l=(PCB.fabrication_layers||[])[0],p=l&&(l.regions||[])[0];if(p)backingEdit={layer:l,index:0,poly:p,sketch:(l.sketches||[])[0]||null};}var b=document.getElementById("pcb-backing");if(b)b.classList.toggle("on",backingMode);
 svg.classList.toggle("outline-mode",backingMode||outlineMode||polyMode);
 if(backingMode)outlineMsg("backing region sketch: click a region to edit it with the shared constraints and modify tools");
 outlineSketchPanelSync();toolSync();drawBoardRect();}
function backingVtxAt(m){var pts=backingPts();if(!pts)return -1;var d=7/S;
 for(var i=0;i<pts.length;i++)if(Math.max(Math.abs(m.x-pts[i][0]),Math.abs(m.y-pts[i][1]))<=d)return i;return -1;}
function backingEdgeAt(m){var pts=backingPts();if(!pts||pts.length<2)return null;
 var bd=7/S,best=null;for(var i=0;i<pts.length;i++){var a=pts[i],b=pts[(i+1)%pts.length],dx=b[0]-a[0],dy=b[1]-a[1],q=dx*dx+dy*dy;if(q<1e-12)continue;
  var t=Math.max(0,Math.min(1,((m.x-a[0])*dx+(m.y-a[1])*dy)/q)),x=a[0]+t*dx,y=a[1]+t*dy,d=Math.hypot(m.x-x,m.y-y);
  if(d<=bd){bd=d;best={i:i,x:x,y:y};}}return best;}
function backingInsert(e){var pts=backingPts();if(!pts)return;var pre=snapAll(),g=snapG();
 pts.splice(e.i+1,0,[Math.round(e.x/g)*g,Math.round(e.y/g)*g]);recordUndo(pre);drawBoardRect();outlineMsg("backing vertex added — Save/Update to keep");}
function backingDelete(i){var pts=backingPts();if(!pts||pts.length<=3){outlineMsg("backing region needs at least 3 vertices");return;}
 var pre=snapAll();pts.splice(i,1);recordUndo(pre);drawBoardRect();outlineMsg("backing vertex removed — Save/Update to keep");}
var backingBtn=document.getElementById("pcb-backing");if(backingBtn){backingBtn.hidden=!(PCB.fabrication_layers||[]).length;
 backingBtn.addEventListener("click",function(){backingArm(!backingMode);});}
// DXF board-outline import seam (pcb_dxf.js): the outline-override apply path
// the ▭ Outline / ⬡ Poly tools use lives inside this closure, so the importer
// reaches it through one exported object instead of duplicating the mutation
// (snapshot → disarm tools → PCB.outline → bbox sync → dirty → redraw → DRC).
window.PCBDxfSeams={
 selfIntersects: polySelfIntersects,
 snapAll: snapAll,
 recordUndo: recordUndo,
 markDirty: markDirty,
 outlineBboxSync: outlineBboxSync,
 drawBoardRect: drawBoardRect,
 scheduleDrc: scheduleDrc,
 outlineMsg: outlineMsg,
 // Disarm every drawing tool so none of their armed state fights the new
 // outline on the next click.
 disarmTools: function(){
  if(outlineMode)outlineArm(false);
  if(polyMode)polyArm(false);
  if(pourMode)pourArm(false);
  if(drawMode)drawModeSet(false);
  if(textMode)txArm(false);
  if(backingMode)backingArm(false);}
};
// Re-derive a polygon outline's rect fields from its vertex bbox (the server
// does the same on parse, so the pair can never disagree).
function outlineBboxSync(){var o=PCB.outline;if(!o||!o.pts)return;
 if(OS&&o.sketch){OS.syncOutline(o);outlineGeomDrop();return;}
 var ax=1e18,ay=1e18,bx=-1e18,by=-1e18;
 o.pts.forEach(function(p){ax=Math.min(ax,p[0]);ay=Math.min(ay,p[1]);bx=Math.max(bx,p[0]);by=Math.max(by,p[1]);});
 o.x=ax;o.y=ay;o.w=bx-ax;o.h=by-ay;outlineGeomDrop();}
// ── Freeform outline segment editing ─────────────────────────────────────
// A drawn outline is reshapeable into any polygon: drag a vertex, drag an edge
// to slide the whole segment, double-click an edge to insert a vertex, or
// right-click a vertex to delete it. A rectangle outline (no pts) is promoted
// to an explicit 4-vertex polygon on the first such edit. Every mutation
// grid-snaps, re-derives the bbox, records one undo step, marks dirty, redraws,
// and re-runs the DRC (whose board-edge geometry then tracks the new shape).
var osdrag=null; // active outline-edge (whole-segment) drag
// The outline currently offered for editing. A saved/drawn override wins; the
// authored shape remains a read-only seed until the first actual mutation
// materializes it as PCB.outline. This also lets a plain click on an authored
// edge open its editable Width/Height properties without first arming a tool.
function outlineEditable(){if(PCB.outline)return PCB.outline;
 if(!PCB.board)return null;
 return authoredOutlineSeed()||{x:PCB.board.x,y:PCB.board.y,w:PCB.board.w,h:PCB.board.h,pts:null,radii:null};}
// The editable vertex list: polygon pts, or four synthesized rect corners.
function outlinePtsOf(o){if(!o)return null;
 if(OS&&o.sketch){var ps=OS.physicalPoints(o.sketch);if(ps.length)return ps.map(function(p){return [p.x,p.y];});}
 if(o.pts&&o.pts.length)return o.pts;
 if(o.w>0&&o.h>0)return [[o.x,o.y],[o.x+o.w,o.y],[o.x+o.w,o.y+o.h],[o.x,o.y+o.h]];
 return null;}
// Materialize the authored seed, then promote a rect to four explicit corners.
// The caller captures undo before this, so undo returns to the authored source.
function outlinePromote(){if(!PCB.outline){var a=outlineEditable();if(!a)return;
  PCB.outline={x:a.x,y:a.y,w:a.w,h:a.h,pts:a.pts?a.pts.map(function(p){return [p[0],p[1]];}):null,
   radii:a.radii?a.radii.slice():null};outlineGeomDrop();}
 var o=PCB.outline;
 if(o&&!(o.pts&&o.pts.length)&&o.w>0&&o.h>0){o.pts=[[o.x,o.y],[o.x+o.w,o.y],[o.x+o.w,o.y+o.h],[o.x,o.y+o.h]];outlineGeomDrop();}
 if(OS&&o&&!o.sketch){OS.ensure(o);outlineGeomDrop();}}
// Set the finished board dimensions from the properties panel. The lower-left
// bbox corner remains anchored; a polygon scales about that corner while its
// fillet radii remain physical mm values. An authored outline materializes as
// a layout override only when the user commits a changed dimension.
function outlineResize(w,h){var src=PCB.outline||authoredOutlineSeed()||PCB.board;if(!src)return false;
 var pre=snapAll(),ow=src.w,oh=src.h;if(!(ow>0)||!(oh>0))return false;
 if(!PCB.outline)PCB.outline={x:src.x,y:src.y,w:src.w,h:src.h,
  pts:src.pts?src.pts.map(function(p){return [p[0],p[1]];}):null,radii:src.radii?src.radii.slice():null};
 var o=PCB.outline,sx=w/ow,sy=h/oh;
 if(OS&&o.sketch){o.sketch.points.forEach(function(p){p.x=src.x+(p.x-src.x)*sx;p.y=src.y+(p.y-src.y)*sy;});
  o.sketch.curves.forEach(function(c){if(c.mid)c.mid=[src.x+(c.mid[0]-src.x)*sx,src.y+(c.mid[1]-src.y)*sy];});
  (o.sketch.constraints||[]).forEach(function(q){if(q.value!=null&&q.kind!=="angle")q.value=OS.dimensionValue(o.sketch,q);});OS.syncOutline(o);}
 else if(o.pts&&o.pts.length)o.pts=o.pts.map(function(p){return [src.x+(p[0]-src.x)*sx,src.y+(p[1]-src.y)*sy];});
 o.x=src.x;o.y=src.y;o.w=w;o.h=h;if(o.pts)outlineBboxSync();else outlineGeomDrop();
 recordUndo(pre);drawBoardRect();outlineDrc();outlineMsg("board resized to "+fmtLen(w)+" × "+fmtLen(h)+" — Save/Update to keep");return true;}
// The outline edge (segment vtx i → i+1) whose nearest point is within a handle
// of board point m, or null. `px,py` is that (unsnapped) closest point.
function edgeAt(m){var eo=activeSketchIsArea()?activeSketchShape():outlineEditable(),pts=outlinePtsOf(eo);if(!pts||pts.length<2)return null;
 var sk=OS&&eo&&eo.sketch,ecs=sk&&OS.physicalCurves(sk);
 var bd=7/S,best=null,n=pts.length;
 var count=ecs?ecs.length:n;
 for(var i=0;i<count;i++){var c=ecs&&ecs[i],ap=c&&OS.point(sk,c.a),bp=c&&OS.point(sk,c.b),a=c?[ap.x,ap.y]:pts[i],b=c?[bp.x,bp.y]:pts[(i+1)%n],samples=[a];
  if(ecs&&ecs[i]&&ecs[i].kind==="arc"){var ag=OS.arcCircle(sk,ecs[i]);if(ag)for(var ak=1;ak<20;ak++){var aa=ag.start+ag.sweep*ak/20;samples.push([ag.cx+ag.r*Math.cos(aa),ag.cy+ag.r*Math.sin(aa)]);}}samples.push(b);
  for(var si=0;si+1<samples.length;si++){a=samples[si];b=samples[si+1];
  var dx=b[0]-a[0],dy=b[1]-a[1],L2=dx*dx+dy*dy;if(L2<1e-12)continue;
  var t=((m.x-a[0])*dx+(m.y-a[1])*dy)/L2;if(t<0)t=0;else if(t>1)t=1;
  var px=a[0]+t*dx,py=a[1]+t*dy,d=Math.hypot(m.x-px,m.y-py);
  if(d<=bd){bd=d;best={i:i,px:px,py:py,id:ecs&&ecs[i]?ecs[i].id:null};}}}
 return best;}
// Proper segment-segment crossing (strictly interior) — JS twin of the Zig
// outline.segIntersect that polySelfIntersects walks.
function segsCross(a,b,c,d){
 var r0=b[0]-a[0],r1=b[1]-a[1],s0=d[0]-c[0],s1=d[1]-c[1],den=r0*s1-r1*s0;
 if(Math.abs(den)<1e-12)return false;
 var t=((c[0]-a[0])*s1-(c[1]-a[1])*s0)/den,u=((c[0]-a[0])*r1-(c[1]-a[1])*r0)/den;
 return t>1e-9&&t<1-1e-9&&u>1e-9&&u<1-1e-9;}
// JS twin of outline.selfIntersects (Zig): any NON-adjacent edge pair crosses —
// a bow-tie the fab can't cut. Adjacent (shared-vertex) edges are skipped.
function polySelfIntersects(pts){if(!pts||pts.length<4)return false;var n=pts.length;
 for(var i=0;i<n;i++){var a=pts[i],b=pts[(i+1)%n];
  for(var j=i+1;j<n;j++){if((i+1)%n===j||(j+1)%n===i)continue;
   if(segsCross(a,b,pts[j],pts[(j+1)%n]))return true;}}
 return false;}
// True when the drawn outline is not fab-legal to save: a self-crossing polygon
// or a degenerate (<2 mm) bbox. Mirrors the server's outline_mod.valid gate so
// the viewer flags it (drawn red) and Save refuses it before the round-trip.
function outlineBad(){var o=PCB.outline;if(!o)return false;
 if(!(o.w>=2&&o.h>=2))return true;
 if(OS&&o.sketch){var g=OS.compile(o.sketch);return !g||!g.closed||polySelfIntersects(g.points)||OS.state(o.sketch).conflict;}
 return !!(o.pts&&o.pts.length>=3&&polySelfIntersects(o.pts));}
function pourSketchBad(){if(!OS)return null;var bad=null;(PCB.zones||[]).some(function(z,i){if(!z.sketch)return false;var g=OS.compile(z.sketch),st=g?OS.state(z.sketch):null;
 if(!g||!g.closed||(st&&st.conflict)||polySelfIntersects(g.points)){bad={zone:z,index:i,open:!!(g&&!g.closed)};return true;}return false;});return bad;}
// Saving must not strand unrelated component/route edits behind stale hidden
// authoring topology. Preserve the exact visible copper polygon: first close a
// simple gap without losing intent, otherwise rebuild a clean line sketch.
function recoverOpenPourSketches(){if(!OS)return 0;var count=0;(PCB.zones||[]).forEach(function(z){if(!z.sketch)return;var g=OS.compile(z.sketch),st=g?OS.state(z.sketch):null;if(g&&g.closed&&!(st&&st.conflict)&&!polySelfIntersects(g.points))return;
 var replacement=g&&!g.closed?OS.clone(z.sketch):null;if(!replacement||!OS.closeProfile(replacement)){var pts=z.poly;if(!pts||pts.length<3||polySelfIntersects(pts))return;var area=0;
  for(var i=0;i<pts.length;i++){var a=pts[i],b=pts[(i+1)%pts.length];area+=a[0]*b[1]-b[0]*a[1];}if(!Number.isFinite(area)||Math.abs(area)<1e-9)return;replacement=OS.fromPolygon(pts);}
 var closed=OS.compile(replacement);if(!closed||!closed.closed||polySelfIntersects(closed.points))return;z.sketch=replacement;z.poly=closed.points;count++;});return count;}
function outlineDrc(){var o=PCB.outline,g=OS&&o&&o.sketch&&OS.compile(o.sketch);if(!g||g.closed)scheduleDrc();}
// Delete a vertex (right-click a handle) and every incident curve. The sketch
// may remain open; no replacement edge is synthesized behind the user's back.
function outlineVertexDelete(i){var o=activeSketchIsArea()?activeSketchShape():outlineEditable();if(!o)return;
 if(!OS)return;outlineSketchMutate(activeSketchName()+" vertex deleted",function(sk){var ps=OS.physicalPoints(sk);return !!(ps[i]&&OS.deletePoint(sk,ps[i].id));});}
// Insert a vertex splitting edge `e.i` at its grid-snapped projection point
// (double-click an edge); the new vertex is immediately draggable.
function outlineInsertVertex(e){var pre=snapAll(),shape=activeSketchPromote();
 var gx=Math.round(e.px/G)*G,gy=Math.round(e.py/G)*G;
 if(OS&&shape.sketch){var cs=OS.physicalCurves(shape.sketch),c=cs[e.i];if(!c||!OS.insertPoint(shape.sketch,c.id,gx,gy))return;var compiled=activeSketchSync(shape);activeSketchChanged(compiled);}
 else if(shape.pts)shape.pts.splice(e.i+1,0,[gx,gy]);
 if(!activeSketchIsArea()&&shape.radii)shape.radii.splice(e.i+1,0,0);
 if(!activeSketchIsArea())outlineBboxSync();recordUndo(pre);drawBoardRect();
 outlineMsg(activeSketchName()+" vertex added — Save/Update to keep");}
// Begin sliding outline edge `e.i`: both endpoints translate by one snapped
// delta. Captures the pre-drag snapshot (a rect is promoted lazily on the first
// actual move, so a bare click never rewrites a rect into a polygon).
function osegStart(e,m){var shape=activeSketchIsArea()?activeSketchShape():outlineEditable(),pts=outlinePtsOf(shape),i=e.i,j=(i+1)%pts.length;
 var sk=OS&&shape.sketch,cs=sk&&OS.physicalCurves(sk),c=cs&&cs[i],ap=c&&OS.point(sk,c.a),bp=c&&OS.point(sk,c.b);
 return {i:i,j:j,id:c&&c.id,aid:c&&c.a,bid:c&&c.b,mid0:c&&c.mid&&c.mid.slice(),m0:m,a0:c?[ap.x,ap.y]:pts[i].slice(),b0:c?[bp.x,bp.y]:pts[j].slice(),moved:false,snap:snapAll()};}
function osegMove(m,square){var sd=osdrag,shape=activeSketchIsArea()?activeSketchShape():outlineEditable(),cur=outlinePtsOf(shape);
 var dx=Math.round((m.x-sd.m0.x)/G)*G,dy=Math.round((m.y-sd.m0.y)/G)*G;
 var ex=sd.b0[0]-sd.a0[0],ey=sd.b0[1]-sd.a0[1],axisTol=1e-6;
 // Axis-aligned sides always slide perpendicular to themselves: horizontal
 // edges move only in Y and vertical edges only in X. Shift extends the same
 // normal-only behavior to a non-axis-aligned edge using its dominant axis.
 if(Math.abs(ey)<=axisTol)dx=0;else if(Math.abs(ex)<=axisTol)dy=0;
 else if(square){if(Math.abs(ex)>=Math.abs(ey))dx=0;else dy=0;}
 var na=[sd.a0[0]+dx,sd.a0[1]+dy],nb=[sd.b0[0]+dx,sd.b0[1]+dy];
 var liveSk=OS&&shape.sketch,liveA=liveSk&&OS.point(liveSk,sd.aid),liveB=liveSk&&OS.point(liveSk,sd.bid);
 if(liveA&&liveB){if(liveA.x===na[0]&&liveA.y===na[1]&&liveB.x===nb[0]&&liveB.y===nb[1])return;}
 else if(cur[sd.i][0]===na[0]&&cur[sd.i][1]===na[1]&&cur[sd.j][0]===nb[0]&&cur[sd.j][1]===nb[1])return;
 shape=activeSketchPromote();
 if(OS&&shape.sketch){if(!sd.id){var sc=OS.physicalCurves(shape.sketch)[sd.i];sd.id=sc&&sc.id;sd.aid=sc&&sc.a;sd.bid=sc&&sc.b;}
  var ap=OS.point(shape.sketch,sd.aid),bp=OS.point(shape.sketch,sd.bid),scur=OS.curve(shape.sketch,sd.id);ap.x=sd.a0[0];ap.y=sd.a0[1];bp.x=sd.b0[0];bp.y=sd.b0[1];if(scur&&sd.mid0)scur.mid=[sd.mid0[0]+dx,sd.mid0[1]+dy];OS.moveCurve(shape.sketch,sd.id,dx,dy);activeSketchSync(shape);}
 else{var pts=shape.pts;pts[sd.i]=na;pts[sd.j]=nb;}
 sd.moved=true;if(!activeSketchIsArea())outlineBboxSync();drawBoardRect();}
function polyFinish(closeChain){
 if(!polyPts||polyPts.length<2){polyPts=null;polyCur=null;drawBoardRect();return false;}
 var pts=polyPts.slice();if(closeChain&&pts.length>=3){var a=pts[0],b=pts[pts.length-1];if(a[0]!==b[0]||a[1]!==b[1])pts.push(a.slice());}
 if(polySketchOwned){var wasClosed=false,ok=outlineSketchMutate("line chain added",function(sk){if(!OS.addLinePath(sk,pts))return false;wasClosed=OS.closed(sk);if(wasClosed)OS.normalize(sk);return true;});
  polyPts=null;polyCur=null;drawBoardRect();if(ok)outlineMsg(wasClosed?"line chain joined — "+activeSketchName()+" profile closed; Save/Update to keep":"line chain added — profile remains open; continue drawing freely");return ok;}
 // The standalone Poly outline command still replaces the board with a full
 // closed contour. Open sketch editing is provided by Line inside Outline.
 if(!closeChain||pts.length<4){outlineMsg("use Outline > Line to keep open geometry; this Poly outline command requires a closed loop");return false;}
 var pre=snapAll(),prev=PCB.outline;pts.pop();polyPts=null;polyCur=null;PCB.outline={x:0,y:0,w:0,h:0,pts:pts};outlineBboxSync();
 var valid=PCB.outline.w>=2&&PCB.outline.h>=2&&!polySelfIntersects(pts);if(!valid)PCB.outline=prev;else{if(OS)OS.ensure(PCB.outline);recordUndo(pre);}polyArm(false);drawBoardRect();
 outlineMsg(valid?"connected outline profile closed — Save/Update to keep":"profile is too small or crosses itself — outline unchanged");return valid;}
function polyClose(){return polyFinish(true);}
function polyPop(){if(polyPts&&polyPts.length){polyPts.pop();if(!polyPts.length)polyPts=null;drawBoardRect();}}
// ── ▩ Custom copper pours ────────────────────────────────────────────────
// Draw a polygon (grid-snapped clicks, Shift = free grid, Ctrl = no H/V snap),
// close it, then a small
// dialog picks the net + layer; the closed region becomes a PCB.zones entry the
// server fills (PCB.zone_fills). Zones are board-anchored (never move with a
// part), persisted with the layout, and deletable (right-click while armed).
var POUR_COL="#f0c674"; // amber — distinct from the ⬡ Poly outline's green
function pourArm(on){if(RO&&on)return;
 if(on&&heatsinkMode)heatsinkArm(false);
 if(on&&backingMode)backingArm(false);
 if(on&&padAlignMode)padAlignArm(false);
 if(on&&outlineMode)outlineArm(false);
 if(on&&polyMode)polyArm(false);
 if(on&&drawMode)drawModeSet(false);
 if(on&&textMode)txArm(false);
 if(on&&PCB.rulerOff)PCB.rulerOff();
 pourMode=on;
 if(!on){pourPts=null;pourCur=null;pourEdit=null;outlineSelection=[];outlineRectArmed=false;closePourDialog();}
 var b=document.getElementById("pcb-pour-zone");if(b)b.classList.toggle("on",on);
 svg.classList.toggle("outline-mode",on||outlineMode||polyMode);
 var msg=document.getElementById("pcb-savemsg");
 if(msg&&on){msg.style.color=POUR_COL;
  msg.textContent="copper area: click an existing area to edit, or draw a new one — near H/V segments snap; hold Ctrl to disable";}
 else if(msg&&!on){msg.textContent="";}
 outlineSketchPanelSync();toolSync();
 drawBoardRect();}
function pourAt(m){var zs=PCB.zones||[];for(var i=zs.length-1;i>=0;i--){var z=zs[i],poly=z&&z.poly;if(!poly||poly.length<3)continue;
 if(polyContains(poly,m.x,m.y)||nearPolyEdge(poly,m.x,m.y,7/S))return z;}return null;}
function pourBeginEdit(z){if(!z)return false;pourEdit=z;pourPts=null;pourCur=null;outlineSelection=[];outlineRectArmed=false;
 outlineSketchPanelSync();drawBoardRect();outlineMsg((z.keepout?"copper keepout":"copper pour")+" sketch: select geometry or use Rectangle/Line, constraints and modify tools; click empty space to box-select vertices");return true;}
// The in-progress pour sketch: placed vertices as an amber dashed open path, a
// rubber segment to the cursor, and a ring marking the first (close) vertex.
function pourSketch(){
 var str=pourPts.map(function(p){return X(p[0]).toFixed(1)+","+Y(p[1]).toFixed(1);}).join(" ");
 gB.appendChild(el("polyline",{points:str,fill:"none",stroke:POUR_COL,"stroke-width":1.6,
   opacity:0.9,"stroke-dasharray":"6 4"}));
 if(pourCur){var lp=pourPts[pourPts.length-1];
  gB.appendChild(el("line",{x1:X(lp[0]).toFixed(1),y1:Y(lp[1]).toFixed(1),
    x2:X(pourCur.x).toFixed(1),y2:Y(pourCur.y).toFixed(1),
    stroke:POUR_COL,"stroke-width":1,opacity:0.6,"stroke-dasharray":"3 3"}));}
 var f=pourPts[0];
 gB.appendChild(el("circle",{cx:X(f[0]).toFixed(1),cy:Y(f[1]).toFixed(1),r:6,fill:"none",
   stroke:POUR_COL,"stroke-width":1.4,opacity:0.9}));
 pourPts.forEach(function(p){gB.appendChild(el("rect",{
   x:(X(p[0])-3).toFixed(1),y:(Y(p[1])-3).toFixed(1),width:6,height:6,
   fill:POUR_COL,opacity:0.9}));});
}
function pourFlashBad(txt){var msg=document.getElementById("pcb-savemsg");
 if(msg){msg.style.color="#f85149";msg.textContent=txt;}}
// Close the in-progress pour → validate, then open the net/layer dialog. Refuses
// (keeping the polygon so it can be fixed) a <3-vertex or self-intersecting shape.
function pourClose(){
 if(!pourPts||pourPts.length<3){pourFlashBad("a copper pour needs at least 3 vertices");return;}
 if(polySelfIntersects(pourPts)){pourFlashBad("copper pour self-intersects — adjust the polygon");return;}
 var pts=pourPts.slice();pourPts=null;pourCur=null;drawBoardRect();
 openPourDialog(pts);}
function pourPop(){if(pourPts&&pourPts.length){pourPts.pop();if(!pourPts.length)pourPts=null;drawBoardRect();}}
// Point-to-polygon-edge proximity (world mm) — a right-click near a pour's dashed
// rim deletes it even when the cursor is just outside the filled interior.
function nearPolyEdge(pts,x,y,tol){for(var i=0;i<pts.length;i++){var a=pts[i],b=pts[(i+1)%pts.length];
  var dx=b[0]-a[0],dy=b[1]-a[1],L2=dx*dx+dy*dy;if(L2<1e-12)continue;
  var t=((x-a[0])*dx+(y-a[1])*dy)/L2;if(t<0)t=0;else if(t>1)t=1;
  var px=a[0]+t*dx,py=a[1]+t*dy;if(Math.hypot(x-px,y-py)<=tol)return true;}
 return false;}
// Delete the topmost custom copper area whose polygon contains (or whose rim is
// near) the cursor. Generated rule keepouts live in PCB.keepouts, not this list.
function pourDeleteAt(m){var zs=PCB.zones||[];
 for(var i=zs.length-1;i>=0;i--){var z=zs[i];
  var poly=z.poly;if(!poly||poly.length<3)continue;
  if(polyContains(poly,m.x,m.y)||nearPolyEdge(poly,m.x,m.y,6/S)){
   var pre=snapAll();zs.splice(i,1);if(pourEdit===z){pourEdit=null;outlineSelection=[];outlineSketchPanelSync();}recordUndo(pre);onZonesChanged();
   var msg=document.getElementById("pcb-savemsg");
   if(msg){msg.style.color="#8b949e";msg.textContent=(z.keepout?"copper keepout":"copper pour")+" deleted — Save/Update to keep";}
   return;}}
}
// The default net for a new pour: the most common net among pads whose CENTRE
// falls inside the drawn polygon (a ground pour lands on GND automatically);
// else a ground-ish net name; else the first known net.
function pourDefaultNet(pts){var tally={},best="",bestN=0;
 for(var i=0;i<P.length;i++){var p=P[i];(p.pads||[]).forEach(function(pd){
   if(!pd.net)return;var c=wpt(i,pd.x,pd.y);
   if(polyContains(pts,c.x,c.y)){var n=pd.net;tally[n]=(tally[n]||0)+1;
    if(tally[n]>bestN){bestN=tally[n];best=n;}}});}
 if(best)return best;
 var names=PCB.netnames||[];
 for(var j=0;j<names.length;j++)if(/gnd|ground/i.test(names[j]))return names[j];
 return names.length?names[0]:"";}
function closePourDialog(){if(pourDlg&&pourDlg.parentNode)pourDlg.parentNode.removeChild(pourDlg);pourDlg=null;pourDialogSnap=null;}
// The floating net + layer + priority picker. Opened after a pour polygon
// closes (create) OR by clicking an existing pour's rim in Select mode (edit,
// `existing` = its PCB.zones entry). Enter = commit, Esc = cancel; keystrokes
// never leak to the board shortcuts while open.
function openPourDialog(pts,existing){
 closePourDialog();
 pourDialogSnap=snapAll();
 var host=svg.parentNode;
 var def=existing?existing.net:pourDefaultNet(pts),defKeepout=!!(existing&&existing.keepout);
 // A NEW pour lands on the layer being worked, whatever it is — drawing one
 // while an inner layer was active used to silently create it on F.Cu.
 var defLayer=existing?(existing.layer||LN.f_cu):layerName(activeLayer);
 if(!host){if(!existing)createZone(pts,def,defLayer,0);return;}
 var dlg=document.createElement("div");pourDlg=dlg;dlg.className="pour-dlg";
 dlg.style.cssText="position:absolute;z-index:60;background:#161b22;border:1px solid #30363d;"+
  "border-radius:6px;padding:10px;font:12px system-ui;color:#c9d1d9;box-shadow:0 6px 22px rgba(0,0,0,.6);min-width:210px";
 var minx=1e18,miny=1e18;pts.forEach(function(p){minx=Math.min(minx,p[0]);miny=Math.min(miny,p[1]);});
 var sx=svg.getBoundingClientRect(),vb2=svg.viewBox.baseVal,kx=sx.width/vb2.w,ky=sx.height/vb2.h;
 dlg.style.left=(svg.offsetLeft+(X(minx)-vb2.x)*kx)+"px";
 dlg.style.top=(svg.offsetTop+(Y(miny)-vb2.y)*ky)+"px";
 var title=document.createElement("div");title.textContent=existing?"Edit copper area":"New copper area";
 title.style.cssText="font-weight:600;margin-bottom:6px;color:"+POUR_COL;dlg.appendChild(title);
 function row(label,node){var r=document.createElement("label");
  r.style.cssText="display:flex;align-items:center;gap:6px;margin:4px 0";
  var s=document.createElement("span");s.textContent=label;s.style.cssText="width:52px;color:#8b949e";
  r.appendChild(s);r.appendChild(node);return r;}
 var tsel=document.createElement("select");
 tsel.style.cssText="background:#0d1117;border:1px solid #30363d;color:#c9d1d9;border-radius:4px;padding:3px";
 [{v:"pour",t:"Copper pour"},{v:"keepout",t:"Copper keepout"}].forEach(function(q){var o=document.createElement("option");o.value=q.v;o.textContent=q.t;tsel.appendChild(o);});tsel.value=defKeepout?"keepout":"pour";
 var nsel=document.createElement("select");
 nsel.style.cssText="flex:1;min-width:130px;background:#0d1117;border:1px solid #30363d;color:#c9d1d9;border-radius:4px;padding:3px";
 var names=PCB.netnames||[];
 if(!names.length){var o0=document.createElement("option");o0.value="";o0.textContent="(no nets)";nsel.appendChild(o0);}
 names.forEach(function(n){var o=document.createElement("option");o.value=n;o.textContent=n;if(n===def)o.selected=true;nsel.appendChild(o);});
 // Layer options: every ROUTABLE copper layer this board has (LYR — the same
 // table the painters key off), plus any layer already used by a pour on this
 // board (so editing an imported In3.Cu / F&B.Cu pour keeps its layer).
 var lsel=document.createElement("select");
 lsel.style.cssText="background:#0d1117;border:1px solid #30363d;color:#c9d1d9;border-radius:4px;padding:3px";
 var lopts=LYR.map(function(L){return L.name;});
 (PCB.zones||[]).forEach(function(z){if(z.layer&&lopts.indexOf(z.layer)<0)lopts.push(z.layer);});
 if(defLayer&&lopts.indexOf(defLayer)<0)lopts.push(defLayer);
 var lname={};lname[LN.f_cu]=sideLabel(false);lname[LN.b_cu]=sideLabel(true);
 lopts.forEach(function(ln){var o=document.createElement("option");o.value=ln;o.textContent=lname[ln]||ln;lsel.appendChild(o);});
 lsel.value=defLayer;
 var pin=document.createElement("input");pin.type="number";pin.min="0";pin.step="1";pin.inputMode="numeric";
 pin.value=String(existing?(existing.priority||0):0);
 pin.style.cssText="width:70px;background:#0d1117;border:1px solid #30363d;color:#c9d1d9;border-radius:4px;padding:3px";
 dlg.appendChild(row("Type",tsel));dlg.appendChild(row("Net",nsel));dlg.appendChild(row("Layer",lsel));dlg.appendChild(row("Priority",pin));
 function typeSync(){var ko=tsel.value==="keepout";nsel.disabled=ko;pin.disabled=ko;hint.textContent=ko?"Keepouts block routed copper on the selected layer and carry the same editable native sketch as pours.":"Higher priority wins where pours overlap on a layer; the lower one is pushed back by the clearance gap so they can't short.";}
 var hint=document.createElement("div");
 hint.style.cssText="margin:4px 2px 0;color:#8b949e;font-size:11px;line-height:1.35;max-width:230px";
 dlg.appendChild(hint);
 var ba=document.createElement("div");ba.style.cssText="margin-top:8px;display:flex;gap:6px;justify-content:flex-end";
 var cancel=document.createElement("button");cancel.textContent="Cancel";cancel.className="btn";
 var ok=document.createElement("button");ok.textContent=existing?"Update area":"Create area";ok.className="btn";
 ok.style.cssText="border-color:#2ea043;color:#7ee787";
 function commit(){var keepout=tsel.value==="keepout",net=keepout?"":(nsel.value||""),layer=lsel.value||LN.f_cu,prio=keepout?0:parseInt(pin.value,10);if(!(prio>0))prio=0;
  var pre=pourDialogSnap;closePourDialog();
  if(existing){existing.net=net;existing.layer=layer;existing.priority=prio;existing.keepout=keepout;existing.filled=!keepout;recordUndo(pre);onZonesChanged();
   var m=document.getElementById("pcb-savemsg");if(m){m.style.color="#7ee787";
    m.textContent=(keepout?"copper keepout":"copper pour")+" updated ("+(keepout?layer:((net||"no net")+" · "+layer+" · priority "+prio))+")";}}
  else createZone(pts,net,layer,prio,keepout);}
 cancel.addEventListener("click",function(){closePourDialog();});
 ok.addEventListener("click",commit);
 ba.appendChild(cancel);ba.appendChild(ok);dlg.appendChild(ba);
 dlg.addEventListener("keydown",function(ev){ev.stopPropagation();
  if(ev.key==="Enter"){ev.preventDefault();commit();}
  else if(ev.key==="Escape"){ev.preventDefault();closePourDialog();}});
 tsel.addEventListener("change",typeSync);typeSync();host.appendChild(dlg);tsel.focus();}
// Push a new pour onto PCB.zones and refresh (dirty + stale + auto-refill).
function createZone(pts,net,layer,prio,keepout){
 var pre=snapAll(),sk=OS?OS.fromPolygon(pts):null;
 PCB.zones=PCB.zones||[];
 var zone={net:keepout?"":(net||""),layer:layer||LN.f_cu,poly:pts,filled:!keepout,keepout:!!keepout,priority:keepout?0:(prio>0?prio:0)};if(sk)zone.sketch=sk;
 PCB.zones.push(zone);recordUndo(pre);
 onZonesChanged();
 var msg=document.getElementById("pcb-savemsg");
 if(msg){msg.style.color="#7ee787";
  msg.textContent=(keepout?"copper keepout":"copper pour")+" added ("+(keepout?layer:((net||"no net")+" · "+layer+((prio>0)?(" · priority "+prio):"")))+")";}}
// A zone create/delete: mark the layout dirty (Save/Update), invalidate pours,
// and kick a refill so the carved fill appears right after drawing.
function onZonesChanged(){markDirty();pourGeomDrop();dragCacheDrop();paintSoon();markPoursStale();refillPours();}
// The outline vertex under a board point, or -1 (handle-sized hit box). Works
// on a rect's synthesized corners too, so a rect is grabbable before promotion.
function vtxAt(m){var pts=outlinePtsOf(activeSketchIsArea()?activeSketchShape():outlineEditable());if(!pts)return -1;
 var bd=7/S,best=-1;
 pts.forEach(function(p,i){var d=Math.max(Math.abs(p[0]-m.x),Math.abs(p[1]-m.y));if(d<=bd){bd=d;best=i;}});
 return best;}
function outlineVdrag(i){var o=activeSketchIsArea()?activeSketchShape():outlineEditable(),pts=outlinePtsOf(o),sk=OS&&o&&o.sketch,ps=sk&&OS.physicalPoints(sk),p=ps&&ps[i],q=pts&&pts[i];
 return {i:i,id:p&&p.id,moved:false,snap:snapAll(),x0:p?p.x:q&&q[0],y0:p?p.y:q&&q[1],axis:undefined};}
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
function startPan(ev){var inv=svgScreenInverse(),p=inv?svgScreenPoint(ev.clientX,ev.clientY,inv):null;
 pan={cx:ev.clientX,cy:ev.clientY,vx:vb.x,vy:vb.y,sx:p&&p.x,sy:p&&p.y,inv:inv,moved:false,
  slop:ev.pointerType==="touch"?8:3,tapi:-1,button:ev.button};
 pcap(ev);svg.style.cursor="grabbing";}
function panMove(ev){if(!pan)return false;var slop=pan.slop||3;
 if(Math.abs(ev.clientX-pan.cx)>slop||Math.abs(ev.clientY-pan.cy)>slop)pan.moved=true;
 if(!pan.moved)return true;
 if(pan.inv){var p=svgScreenPoint(ev.clientX,ev.clientY,pan.inv);
  vb.x=pan.vx-(p.x-pan.sx);vb.y=pan.vy-(p.y-pan.sy);}
 else{var pm=svgMetricsGet(),sw=pm.cw,sh=pm.ch;
  vb.x=pan.vx-(ev.clientX-pan.cx)*(vb.w/Math.max(sw,1));
  vb.y=pan.vy-(ev.clientY-pan.cy)*(vb.h/Math.max(sh,1));}
 setVB();return true;}
var clickCand=null; // pressed a part but won't drag (RO page / locked part)
// ── Track-segment editing (Select mode) ─────────────────────────────────
// KiCad's drag45: the grabbed segment slides along its own normal and keeps
// its direction; each neighbour keeps ITS angle too — corners re-solve as the
// intersection of the two fixed direction lines, so neighbours only extend or
// shorten. Parallel neighbours through one node (including a via) share that
// fixed line. A collinear run, bare/pad end, arc, or ambiguous branch stays
// anchored and gets a perpendicular connector instead of repositioning its
// existing copper. Shift = explicit free move (whole node follows).
var segdrag=null;
function segAttached(t,x,y){var eps=2e-3,out=[],anyVia=false,net=t.net||"";
 (PCB.vias||[]).forEach(function(v){if((v.net||"")===net&&Math.abs(v.x-x)<eps&&Math.abs(v.y-y)<eps){out.push({v:v});anyVia=true;}});
 (PCB.tracks||[]).forEach(function(q){if(q===t)return;
  if((q.net||"")!==net)return; // touching foreign copper is not attached to this route
  if(!anyVia&&(q.l||0)!==(t.l||0))return; // cross-layer joins only through a via
  if(Math.abs(q.x1-x)<eps&&Math.abs(q.y1-y)<eps)out.push({q:q,e:1});
  else if(Math.abs(q.x2-x)<eps&&Math.abs(q.y2-y)<eps)out.push({q:q,e:2});});
 return out;}
// How one end of the dragged segment behaves while it slides (see above):
// corner (angle-preserving intersection) / anchor (perpendicular connector,
// with old copper untouched). A free rigid-node translation is Shift-only.
function segPlan(t,x,y,d){var at=segAttached(t,x,y);
 var trs=at.filter(function(w){return w.q;});
 if(trs.length){var first=trs[0],q=first.q;
  var fx=(first.e===1)?q.x2:q.x1,fy=(first.e===1)?q.y2:q.y1;
  var ex=x-fx,ey=y-fy,eL=Math.hypot(ex,ey),sameLine=q.xm==null&&q.ym==null&&eL>1e-9;
  if(sameLine){ex/=eL;ey/=eL;
   // Several serialized segments may meet at one visually continuous node.
   // They can all stretch without moving when their support lines agree.
   trs.forEach(function(w){var r=w.q,rx=x-((w.e===1)?r.x2:r.x1),ry=y-((w.e===1)?r.y2:r.y1),rL=Math.hypot(rx,ry);
    if(r.xm!=null||r.ym!=null||rL<1e-9||Math.abs(ex*ry/rL-ey*rx/rL)>1e-6)sameLine=false;});
   if(sameLine&&Math.abs(d.x*ey-d.y*ex)>1e-6)return {mode:"corner",fx:fx,fy:fy,ex:ex,ey:ey,at:at};}}
 // No unique fixed support line: keep every existing neighbour/via exactly
 // where it was and bridge from that anchored junction to the moved segment.
 return {mode:"anchor",sx:x,sy:y,jog:null,at:at};}
function segStart(t,m){drcGateSessionEnsure();var dx=t.x2-t.x1,dy=t.y2-t.y1,L=Math.hypot(dx,dy)||1;
 var d={x:dx/L,y:dy/L};
 return {t:t,m0:m,moved:false,snap:snapAll(),o:{x1:t.x1,y1:t.y1,xm:t.xm,ym:t.ym,x2:t.x2,y2:t.y2},
  d:d,px:-d.y,py:d.x,a:segPlan(t,t.x1,t.y1,d),b:segPlan(t,t.x2,t.y2,d)};}
function segFollow(list,nx,ny){list.forEach(function(w){
 if(w.v){w.v.x=nx;w.v.y=ny;}
 else if(w.e===1){w.q.x1=nx;w.q.y1=ny;}
 else{w.q.x2=nx;w.q.y2=ny;}});}
function segJogDrop(pl){if(pl.jog){PCB.tracks=PCB.tracks.filter(function(q){return q!==pl.jog;});pl.jog=null;}}
// New position for one endpoint whose original was `o`, slid by (mx,my).
function segEnd(sd,pl,o,mx,my,free){var ax=o.x+mx,ay=o.y+my;
 // Every pointermove is absolute from the drag snapshot. This also makes a
 // mid-gesture Shift press reversible: releasing Shift restores the fixed
 // neighbours before applying the constrained slide again.
 segFollow(pl.at,o.x,o.y);
 if(free){if(pl.jog)segJogDrop(pl);segFollow(pl.at,ax,ay);return {x:ax,y:ay};}
 if(pl.mode==="corner"){
  var cr=sd.d.x*pl.ey-sd.d.y*pl.ex;
  var tp=((pl.fx-ax)*pl.ey-(pl.fy-ay)*pl.ex)/cr;
  var cx=ax+tp*sd.d.x,cy=ay+tp*sd.d.y;
  segFollow(pl.at,cx,cy); // far ends and every supporting line remain fixed
  return {x:cx,y:cy};}
 // anchor: the old junction stays put (collinear run / pad / branch); a
 // perpendicular connector carries the moved endpoint.
 if(!pl.jog){pl.jog={x1:pl.sx,y1:pl.sy,x2:ax,y2:ay,l:sd.t.l||0,w:sd.t.w,net:sd.t.net||"",g:sd.t.g,source:sd.t.source,id:trackIdNew()};
  (PCB.tracks=PCB.tracks||[]).push(pl.jog);}
 else{pl.jog.x2=ax;pl.jog.y2=ay;}
 return {x:ax,y:ay};}
function segMove(m,free){var sd=segdrag,g=snapG();
 var dx=m.x-sd.m0.x,dy=m.y-sd.m0.y,mx,my;
 if(free){mx=Math.round(dx/g)*g;my=Math.round(dy/g)*g;}
 else{var k=Math.round((dx*sd.px+dy*sd.py)/g)*g;mx=sd.px*k;my=sd.py*k;}
 var e1=segEnd(sd,sd.a,{x:sd.o.x1,y:sd.o.y1},mx,my,free);
 var e2=segEnd(sd,sd.b,{x:sd.o.x2,y:sd.o.y2},mx,my,free);
 if(e1.x===sd.t.x1&&e1.y===sd.t.y1&&e2.x===sd.t.x2&&e2.y===sd.t.y2)return;
 if(!sd.moved){sd.moved=true;rfDropForTracks([sd.t]);svg.style.cursor="grabbing";}
 sd.t.x1=e1.x;sd.t.y1=e1.y;sd.t.x2=e2.x;sd.t.y2=e2.y;
 if(sd.o.xm!=null){sd.t.xm=sd.o.xm+((e1.x-sd.o.x1)+(e2.x-sd.o.x2))/2;
  sd.t.ym=sd.o.ym+((e1.y-sd.o.y1)+(e2.y-sd.o.y2))/2;}
 if(insp&&insp.o===sd.t)renderProps();
 gpuCuEdit(); // segEnd/segFollow just moved copper (and may have laid a jog) in place
 paintSoon();}
// Drop jogs that ended zero-length (slid back home / never left).
function segJogClean(sd){[sd.a,sd.b].forEach(function(pl){var j=pl&&pl.jog;
 if(j&&Math.hypot(j.x2-j.x1,j.y2-j.y1)<1e-6){PCB.tracks=PCB.tracks.filter(function(q){return q!==j;});pl.jog=null;gpuCuEdit();}});}
// ── Via dragging (Select mode) ──────────────────────────────────────────
// A grabbed via translates as a rigid node: every track endpoint sitting on
// its center rides along — on EVERY layer, since the barrel joins them all —
// so the joint stays electrically intact. Grid-snapped delta like a part
// drag; the release gate below reverts a drop that would add a DRC error.
var viadrag=null;
function viaAttached(v){var eps=2e-3,out=[];
 (PCB.tracks||[]).forEach(function(q){
  if(Math.abs(q.x1-v.x)<eps&&Math.abs(q.y1-v.y)<eps)out.push({q:q,e:1});
  else if(Math.abs(q.x2-v.x)<eps&&Math.abs(q.y2-v.y)<eps)out.push({q:q,e:2});});
 return out;}
function viaStart(v,m){drcGateSessionEnsure();return {v:v,m0:m,ox:v.x,oy:v.y,moved:false,snap:snapAll(),at:viaAttached(v)};}
function viaMove(m){var vd=viadrag,g=snapG();
 var mx=Math.round((m.x-vd.m0.x)/g)*g,my=Math.round((m.y-vd.m0.y)/g)*g;
 var nx=vd.ox+mx,ny=vd.oy+my;
 if(nx===vd.v.x&&ny===vd.v.y)return;
 if(!vd.moved){vd.moved=true;rfDropForTracks(vd.at.map(function(w){return w.q;}));svg.style.cursor="grabbing";}
 vd.v.x=nx;vd.v.y=ny;segFollow(vd.at,nx,ny);
 if(insp&&insp.o===vd.v)renderProps();
 gpuCuEdit(); // the via and every track endpoint riding it moved in place
 paintSoon();}
// Touch gestures (phones/tablets): one finger anywhere = pan the board, a tap
// (no movement) = select the part/pad under it, two fingers = pinch zoom.
// Part dragging and marquee select stay pointer-precise (mouse/pen) — a finger
// panning across a dense board must never yank components along with it.
var tpts={},pinch=null;
function touchCount(){return Object.keys(tpts).length;}
function touchDown(ev){
 mobilePanelsClose();
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
 var delta=svgScreenDelta(mx-pinch.mx,my-pinch.my);
 vb.x-=delta.x;vb.y-=delta.y;setVB();
 pinch.d=d;pinch.mx=mx;pinch.my=my;return true;}
function touchUp(ev){
 if(!tpts[ev.pointerId])return;
 delete tpts[ev.pointerId];
 if(pinch&&touchCount()<2)pinch=null;}
// Handle middle-drag at the iframe window's capture boundary. This keeps the
// gesture alive across SVG overlay children and prevents browser autoscroll;
// pointer capture carries it until release when the cursor leaves the scene.
window.addEventListener("pointerdown",function(ev){if(ev.button!==1||!sceneShell.contains(ev.target))return;
 // Do not cancel pointerdown here: browsers may suppress the compatibility
 // mousedown when it is cancelled, which removes the reliable middle-button
 // fallback below. The mousedown handler prevents native autoscroll instead.
 focusBoardShortcuts();ev.stopPropagation();startPan(ev);},true);
window.addEventListener("pointermove",function(ev){if(!pan||pan.button!==1)return;
 ev.preventDefault();ev.stopPropagation();panMove(ev);},true);
window.addEventListener("pointerup",function(ev){if(!pan||pan.button!==1)return;
 try{svg.releasePointerCapture(ev.pointerId);}catch(e){}pan=null;svg.style.cursor="";
 ev.preventDefault();ev.stopPropagation();},true);
window.addEventListener("pointercancel",function(ev){if(!pan||pan.button!==1)return;
 pan=null;svg.style.cursor="";ev.stopPropagation();},true);
window.addEventListener("mousedown",function(ev){if(ev.button!==1||!sceneShell.contains(ev.target))return;
 ev.preventDefault();ev.stopPropagation();
 // Some Linux/browser combinations do not continue emitting pointermove for
 // a middle-button press inside an iframe. Mouse events remain available, so
 // restart from their coordinates and drive the same pan state.
 startPan(ev);},true);
window.addEventListener("mousemove",function(ev){if(!pan||pan.button!==1||(ev.buttons&4)===0)return;
 ev.preventDefault();ev.stopPropagation();panMove(ev);},true);
window.addEventListener("mouseup",function(ev){if(ev.button!==1||!pan||pan.button!==1)return;
 pan=null;svg.style.cursor="";ev.preventDefault();ev.stopPropagation();},true);
window.addEventListener("auxclick",function(ev){if(ev.button===1&&sceneShell.contains(ev.target))ev.preventDefault();},true);
svg.addEventListener("pointercancel",function(ev){touchUp(ev);
 pickHoldCancel(ev.pointerId);pickMenuClose();
 if(heatsinkDraw){heatsinkDraw=null;drawBoardRect();}
 if(heatsinkDrag){restoreSnap(heatsinkDrag.snap);heatsinkDrag=null;drawBoardRect();}
 if(backingDrag){restoreSnap(backingDrag.snap);backingDrag=null;}
 if(ev.pointerType==="touch"&&touchCount()===0){pan=null;pinch=null;svg.style.cursor="";}});
svg.addEventListener("pointerdown",function(ev){
 if(SPACE||ev.button===1){focusBoardShortcuts();ev.preventDefault();startPan(ev);return;}
 if(ev.target!==svg)return;
 focusBoardShortcuts();ev.preventDefault();
 if(ev.button===2)return; // context-menu commands own secondary clicks
 if(PCB.rulerOn)return; // ruler overlay owns the gesture (its capture handlers measure)
 if(heatsinkMode){if(ev.button!==0)return;var hm0=mm(ev),hh=hsHandleAt(hm0);if(hh){heatsinkDrag=hsDragStart(hh,hm0);pcap(ev);svg.style.cursor=hsCursor(hh);return;}
  heatsinkDraw={x0:hm0.x,y0:hm0.y,x1:hm0.x,y1:hm0.y};pcap(ev);return;}
 if(padAlignMode){if(ev.button===0)padAlignPick(mm(ev));return;}
 if(textMode&&ev.button===0){var tm=mm(ev),ti=txAt(tm.x,tm.y);
  if(ti>=0)txDragStart(ti,tm,ev);
  else{var tq=subSilkAt(tm.x,tm.y);if(tq){var tpre=snapAll();ti=subSilkAdopt(tq);txDragStart(ti,tm,ev,tpre,true);}
   else{var ttp=testPointSilkAt(tm.x,tm.y);if(ttp){var tppre=snapAll();ti=testPointSilkAdopt(ttp);txDragStart(ti,tm,ev,tppre,true);}
   else if(fabTextAt(tm.x,tm.y)){var fpre=snapAll();ti=fabTextAdopt();txDragStart(ti,tm,ev,fpre,true);}
   else{txSelect(-1);txPlace(tm);}}}return;}
 if(backingMode){if(ev.button!==0)return;var bm=mm(ev);
  if(backingEdit){var bv=vtxAt(bm);if(bv>=0){vdrag=outlineVdrag(bv);pcap(ev);return;}var be=edgeAt(bm);if(be){osdrag=osegStart(be,bm);pcap(ev);svg.style.cursor="grabbing";return;}var bother=backingAt(bm);if(bother&&(bother.layer!==backingEdit.layer||bother.index!==backingEdit.index)){backingBeginEdit(bother);return;}if(outlineRectArmed)outDraw={x0:bm.x,y0:bm.y,x1:bm.x,y1:bm.y,area:true};else{marq={x0:bm.x,y0:bm.y,x1:bm.x,y1:bm.y,moved:false,outline:true};marqEl=el("rect",{"class":"marquee",x:0,y:0,width:0,height:0});gU.appendChild(marqEl);}pcap(ev);return;}
  var bh=backingAt(bm);if(bh)backingBeginEdit(bh);return;}
 if(outlineMode&&!polyMode&&ev.button===0&&!polyPts){var hv=vtxAt(mm(ev));
  if(hv>=0){vdrag=outlineVdrag(hv);pcap(ev);return;}}
 if(polyMode){if(ev.button!==0)return;
  var pm=mm(ev),sn=polySnap(pm);
  if(polyPts&&polyPts.length>=3&&sn.close){polyClose();return;}
  polyPts=polyPts||[];
  var np=[sn.x,sn.y],lp2=polyPts[polyPts.length-1];
  if(!lp2||lp2[0]!==np[0]||lp2[1]!==np[1])polyPts.push(np);
  polyCur=null;
  // Reaching any pre-existing sketch endpoint commits this chain immediately;
  // the kernel reuses that exact point ID, producing a real joined corner.
  if(polySketchOwned&&sn.kind==="vertex"&&polyPts.length>=2){polyFinish(false);return;}
  drawBoardRect();return;}
 if(pourMode){if(ev.button!==0||pourDlg)return; // the net/layer dialog owns clicks while open
  var qm=mm(ev);
  if(pourEdit){var qv=vtxAt(qm);if(qv>=0){vdrag=outlineVdrag(qv);pcap(ev);return;}
   var qe=edgeAt(qm);if(qe){osdrag=osegStart(qe,qm);pcap(ev);svg.style.cursor="grabbing";return;}
   var qother=pourAt(qm);if(qother&&qother!==pourEdit){pourBeginEdit(qother);return;}
   if(outlineRectArmed)outDraw={x0:qm.x,y0:qm.y,x1:qm.x,y1:qm.y,area:true};
   else{marq={x0:qm.x,y0:qm.y,x1:qm.x,y1:qm.y,moved:false,outline:true};marqEl=el("rect",{"class":"marquee",x:0,y:0,width:0,height:0});gU.appendChild(marqEl);}
   pcap(ev);return;}
  var qhit=pourAt(qm);if(qhit){pourBeginEdit(qhit);return;}
  if(pourPts&&pourPts.length>=3){var qf=pourPts[0];
   if(Math.max(Math.abs(qm.x-qf[0]),Math.abs(qm.y-qf[1]))<=7/S){pourClose();return;}}
  pourPts=pourPts||[];
  var qsn=pourSnap(qm,ev),qnp=[qsn.x,qsn.y],qlp=pourPts[pourPts.length-1];
  if(!qlp||qlp[0]!==qnp[0]||qlp[1]!==qnp[1])pourPts.push(qnp);
  pourCur=null;drawBoardRect();return;}
 if(outlineMode){var om=mm(ev),oe0=edgeAt(om);
  if(oe0){osdrag=osegStart(oe0,om);pcap(ev);svg.style.cursor="grabbing";return;}
  if(outlineRectArmed)outDraw={x0:om.x,y0:om.y,x1:om.x,y1:om.y};
  else{marq={x0:om.x,y0:om.y,x1:om.x,y1:om.y,moved:false,outline:true};
   marqEl=el("rect",{"class":"marquee",x:0,y:0,width:0,height:0});gU.appendChild(marqEl);}
  pcap(ev);return;}
 if(drawMode&&ev.button===0){drawClick(mm(ev),ev.shiftKey);return;}
 if(ev.pointerType==="touch"){
  if(!RO&&!anyDrawTool()&&ev.button===0&&touchCount()===0)pickHoldArm(ev,mm(ev));else pickHoldCancel();
  touchDown(ev);return;}
 if(THERMAL_REVIEW&&ev.button===0){var tm=mm(ev),tph=padHitAt(tm.x,tm.y);
  startPan(ev);pan.tapi=tph?tph.i:partAt(tm.x,tm.y);return;}
 var m=mm(ev);
 // A modifier click is a selection gesture, never the start of a part/copper
 // drag. Resolve it before selected-copper and footprint drag priority so
 // clicking an existing member reliably toggles it back out of the set.
 if(!RO&&!anyDrawTool()&&ev.button===0&&selectionMod(ev)){selectionToggleAt(ev,m);return;}
 // Board text is directly movable in Select mode. It wins over underlying
 // copper and footprints because its visible glyph box is the precise target;
 // the Text tool remains responsible only for placing new labels.
 var directText=ev.button===0?txDirectAt(m):-1,directSnap=null,directAdopt=false;
 if(outlineOnlyFilter())directText=-1;
 var directSub=(directText<0&&ev.button===0)?subSilkAt(m.x,m.y):null;
 if(directSub){directSnap=snapAll();directText=subSilkAdopt(directSub);directAdopt=true;}
 var directTp=(directText<0&&ev.button===0)?testPointSilkAt(m.x,m.y):null;
 if(directTp){directSnap=snapAll();directText=testPointSilkAdopt(directTp);directAdopt=true;}
 if(directText<0&&ev.button===0&&fabTextAt(m.x,m.y)){directSnap=snapAll();directText=fabTextAdopt();directAdopt=true;}
 if(directText>=0){inspClear();selCuClear();selClear();clearSel();selNet(null);txDragStart(directText,m,ev,directSnap,directAdopt);return;}
 if(txSel>=0)txSelect(-1);
 // Keep the ordinary click/drag live while a stationary press counts down.
 // Movement cancels the timer; only a true hold with multiple filtered hits
 // replaces the armed gesture with the exact-object picker.
 if(!RO&&!anyDrawTool()&&ev.button===0)pickHoldArm(ev,m);
 // An explicit copper selection owns a drag that starts on it, even when a
 // footprint courtyard also covers the pointer. Selection is the user's
 // disambiguation: do not let the broader, implicit part hit below steal it.
 if(!RO&&!anyDrawTool()){var selectedHit=selectedCopperHit(m);
  if(selectedHit){
   if(selCuHas(selectedHit.o)&&(selCuCount()+sel.length)>1){
    gdrag=gdragStart(m,null);gdrag.cuDown=selectedHit;pcap(ev);svg.style.cursor="grab";return;}
   if(selectedHit.t==="track"){segdrag=segStart(selectedHit.o,m);pcap(ev);return;}
   if(selectedHit.t==="via"){viadrag=viaStart(selectedHit.o,m);pcap(ev);return;}}}
 var reviewPad=RO?padHitAt(m.x,m.y):null;
 var hi=reviewPad?reviewPad.i:((PHYSICAL_REVIEW||viewSt.filt.fp)?partAt(m.x,m.y):-1);
 if(hi<0){
  if(!RO&&viewSt.filt.outline){var uv=vtxAt(m);if(uv>=0){vdrag=outlineVdrag(uv);pcap(ev);return;}}
  // The visible sub-circuit box is itself selectable, including its empty
  // interior. This always returns to group scope; drilling into a component
  // still requires clicking an actual component below.
  var gh=(!RO&&viewSt.filt.sub)?grpAt(m.x,m.y):null;
  if(gh){var ga=GRPS[gh];pcap(ev);selectGroup(gh);
   gdrag=gdragStart(m,ga[0],ga);gdrag.boxGroup=gh;svg.style.cursor="grab";return;}
  // A track under the press arms a segment drag, a via arms a rigid node
  // drag (a stationary click just selects either); DRC-marker presses keep
  // today's click-to-inspect.
  if(!RO&&!anyDrawTool()){var sh=inspHit(m);
   if(sh&&sh.t==="track"){segdrag=segStart(sh.o,m);pcap(ev);return;}
   if(sh&&sh.t==="via"){viadrag=viaStart(sh.o,m);pcap(ev);return;}}
  // An outline EDGE away from its vertices arms a whole-segment slide (copper
  // above wins — this is reached only for empty perimeter space).
  if(!RO&&!anyDrawTool()&&viewSt.filt.outline){var oe=edgeAt(m);
   if(oe){osdrag=osegStart(oe,m);pcap(ev);svg.style.cursor="grabbing";return;}}
  marq={x0:m.x,y0:m.y,x1:m.x,y1:m.y,moved:false,outline:outlineOnlyFilter()};pcap(ev);
  marqEl=el("rect",{"class":"marquee",x:0,y:0,width:0,height:0});gU.appendChild(marqEl);return;}
 // Part gesture (hit-tested — parts are canvas-painted, not DOM).
 pcap(ev);
 if(RO||P[hi].locked){clickCand={i:hi,m:m};return;}
 // A press on a marquee-selected part drags the whole selection — the other
 // parts AND the copper the band caught. A lone selected part with no selected
 // copper is nothing to move as a set, so it falls through to a plain drag.
 if(sel.indexOf(hi)>=0&&(sel.length>1||selCuCount())){gdrag=gdragStart(m,hi);svg.style.cursor="grab";return;}
 if(sel.length)selClear();
 // Once the user has drilled into this exact component, subsequent drags are
 // leaf edits. Before that, a press anywhere in a rigid sub-circuit moves the
 // group; a stationary first/second click is resolved by clickPart below.
 if(selRef===P[hi].ref){drag=dragStart(hi,m);svg.style.cursor="grab";return;}
 var gi=viewSt.filt.sub?grpIdxs(hi):null;
 if(gi){gdrag=gdragStart(m,hi,gi);svg.style.cursor="grab";return;}
 drag=dragStart(hi,m);svg.style.cursor="grab";});
svg.addEventListener("pointermove",function(ev){
 pickHoldMove(ev);
 if(ev.pointerType==="touch"&&touchMove(ev))return; // active pinch consumed it
 // Status bar: live cursor position, drag delta, hovered part/net.
 var stm=mm(ev);statusXY(stm);statusDelta(stm);statusHover(stm);
 if(heatsinkDrag){hsDragMove(mm(ev));return;}
 if(heatsinkDraw){var hsm=mm(ev);heatsinkDraw.x1=hsm.x;heatsinkDraw.y1=hsm.y;drawBoardRect();return;}
 if(vdrag){var vv=mm(ev),vgx=Math.round(vv.x/G)*G,vgy=Math.round(vv.y/G)*G,shape=activeSketchIsArea()?activeSketchShape():outlineEditable(),vc=outlinePtsOf(shape);
  if(vc&&vdrag.i<vc.length&&(vc[vdrag.i][0]!==vgx||vc[vdrag.i][1]!==vgy)){
   shape=activeSketchPromote();if(OS&&shape.sketch){if(!vdrag.id){var vps=OS.physicalPoints(shape.sketch);vdrag.id=vps[vdrag.i]&&vps[vdrag.i].id;}
    if(vdrag.axis===undefined)vdrag.axis=OS.pointDragAxis(shape.sketch,vdrag.id,vgx,vgy,{x:vdrag.x0,y:vdrag.y0});
    OS.movePoint(shape.sketch,vdrag.id,vgx,vgy,vdrag.axis);activeSketchSync(shape);}
   else shape.pts[vdrag.i]=[vgx,vgy];vdrag.moved=true;if(!activeSketchIsArea())outlineBboxSync();drawBoardRect();}
  return;}
 if(osdrag){osegMove(mm(ev),ev.shiftKey);return;}
 if(segdrag){segMove(mm(ev),ev.shiftKey);return;}
 if(viadrag){viaMove(mm(ev));return;}
 if(polyMode&&polyPts){polyCur=polySnap(mm(ev));drawBoardRect();return;}
 if(pourMode&&pourPts){pourCur=pourSnap(mm(ev),ev);drawBoardRect();return;}
 if(txDrag){var tm=mm(ev),t=PCB.texts[txDrag.i];if(t){
   var nx=Math.round((tm.x+txDrag.ox)/G)*G,ny=Math.round((tm.y+txDrag.oy)/G)*G;
   if(nx!==t.x||ny!==t.y){t.x=nx;t.y=ny;txDrag.moved=true;paintSoon();}}return;}
 if(outDraw){var om=mm(ev);outDraw.x1=om.x;outDraw.y1=om.y;
  var opr={x:Math.min(outDraw.x0,outDraw.x1),y:Math.min(outDraw.y0,outDraw.y1),w:Math.abs(outDraw.x1-outDraw.x0),h:Math.abs(outDraw.y1-outDraw.y0)};
  if(outDraw.area){drawBoardRect();gB.appendChild(el("rect",{x:X(opr.x).toFixed(1),y:Y(opr.y).toFixed(1),width:(opr.w*S).toFixed(1),height:(opr.h*S).toFixed(1),fill:"rgba(240,198,116,.07)",stroke:POUR_COL,"stroke-width":1.6,"stroke-dasharray":"6 4"}));}
  else drawBoardRect(opr);return;}
 if(panMove(ev))return;
 if(drawMode){drawShift=ev.shiftKey;drawCur=mm(ev);if(dtrace)ovPaintSoon();return;}
 if(marq){var m=mm(ev);marq.x1=m.x;marq.y1=m.y;
  if(Math.abs(m.x-marq.x0)>0.2||Math.abs(m.y-marq.y0)>0.2)marq.moved=true;
  var ax=Math.min(marq.x0,marq.x1),ay=Math.min(marq.y0,marq.y1),bx=Math.max(marq.x0,marq.x1),by=Math.max(marq.y0,marq.y1);
  marqEl.setAttribute("x",X(ax).toFixed(1));marqEl.setAttribute("y",Y(ay).toFixed(1));
  marqEl.setAttribute("width",((bx-ax)*S).toFixed(1));marqEl.setAttribute("height",((by-ay)*S).toFixed(1));return;}
 if(typeof gdrag!=="undefined"&&gdrag){var gg=snapG(),gm=mm(ev);gdrag.lx=gm.x;gdrag.ly=gm.y;
  if(!partDragReady(gdrag,gm))return;
  var gdx=Math.round((gm.x-gdrag.sx)/gg)*gg,gdy=Math.round((gm.y-gdrag.sy)/gg)*gg;
  // Gate on the SNAPPED delta, not on a part actually moving: a selection can
  // be copper-only (a band with Footprints off), and that still has to travel.
  if(gdx===gdrag.adx&&gdy===gdrag.ady)return;
  gdrag.adx=gdx;gdrag.ady=gdy;
  var gidx=gdrag.orig.map(function(o){return o.i;});
  gdrag.orig.forEach(function(o){P[o.i].x=o.x+gdx;P[o.i].y=o.y+gdy;});
  if(!gdrag.moved){gdrag.moved=true;if(gdrag.g)subSilkRelease(gdrag.g);for(var gri=0;gri<gidx.length;gri++)testPointSilkRelease(P[gidx[gri]].ref);rfDropForTracks(gdrag.ct.map(function(o){return o.t;}));copperMoved();}
  gdrag.ct.forEach(function(o){o.t.x1=o.x1+gdx;o.t.y1=o.y1+gdy;
   if(o.xm!=null){o.t.xm=o.xm+gdx;o.t.ym=o.ym+gdy;}o.t.x2=o.x2+gdx;o.t.y2=o.y2+gdy;});
  gdrag.cv.forEach(function(o){o.v.x=o.x+gdx;o.v.y=o.y+gdy;});
  gdrag.cz.forEach(function(o){o.z.poly=o.poly.map(function(p){return [p[0]+gdx,p[1]+gdy];});});
  gdrag.cf.forEach(function(o){o.f.poly=o.poly.map(function(p){return [p[0]+gdx,p[1]+gdy];});
   o.f.holes=o.holes.map(function(h){return h.map(function(p){return [p[0]+gdx,p[1]+gdy];});});});
  if(gdrag.ct.length||gdrag.cv.length)gpuCuEdit(); // the carried copper translated in place
  if(gdrag.cz.length||gdrag.cf.length){pourGeomDrop();dragCacheDrop();}
  ratsUpdate(gidx);paintSoon();refreshUnplaced();return;}
 if(typeof drag!=="undefined"&&drag){var dm=mm(ev),dg=snapG();
  if(!partDragReady(drag,dm))return;
  var dp=dragSnapPose(drag,dm,dg),nx=dp.x,ny=dp.y,di=drag.i;
  if(nx!==P[di].x||ny!==P[di].y){P[di].x=nx;P[di].y=ny;
   if(!drag.moved){drag.moved=true;testPointSilkRelease(P[di].ref);copperTouched();}ratsUpdate([di]);paintSoon();refreshUnplaced();
   if(selRef===P[di].ref)updatePropLive();}return;}
 // No gesture: hover tracking for the keyboard targets + glow + cursor.
 var hm=mm(ev),hi=partAt(hm.x,hm.y);
 if(hi!==cur){cur=hi;
  var hg=(hi>=0)?grpOf(P[hi].ref):null;
  hoverGrpName=(viewSt.filt.sub&&hg&&grpRigid(hg))?hg:null;
  paintSoon();}
 statusHover(hm,statusFeatureNet(hm,hi));
 var hhc=heatsinkMode?hsHandleAt(hm):null;
 var hoverCursor=THERMAL_REVIEW?"grab":(heatsinkMode?(hhc?hsCursor(hhc):"crosshair"):(padAlignMode?"crosshair":((backingMode||outlineMode||polyMode)?"":(hi<0?"":(P[hi].locked?"not-allowed":(RO?"":"grab"))))));
 if(!RO&&!anyDrawTool()&&!SPACE){
  if(txDirectAt(hm)>=0||subSilkAt(hm.x,hm.y)||testPointSilkAt(hm.x,hm.y)||fabTextAt(hm.x,hm.y))hoverCursor="move";
  else if(hi<0&&(inspHitTrack(hm)||inspHitVia(hm)))hoverCursor="move";}
 if(svg.style.cursor!==hoverCursor)svg.style.cursor=hoverCursor;});
function clickPart(ev,i){var m=mm(ev),pd=padAt(i,m.x,m.y),cg=grpOf(P[i].ref);
 if(RO){if(reviewClearOutside(m))return;var ph=padHitAt(m.x,m.y);reviewPickedRef(ph?ph.i:i,ph?ph.pd:pd);return;}
 // Hierarchical sub-circuit selection owns clicks inside a rigid group's
 // components. This precedence is deliberate: otherwise a coincident trace or
 // via can intermittently swallow the first/second click and make selection
 // depend on exactly which pixel of the component the user happened to hit.
 if(!RO&&viewSt.filt.sub&&cg&&grpRigid(cg)){inspClear();
  if(pd&&pd.net&&viewSt.filt.pad)selNet(pd.net);
  if(selGroup!==cg){selectGroup(cg);return;}selectComp(P[i].ref);return;}
 // Standalone-part clicks keep the copper-inspection precedence rule:
 // marker > pad > via/track > the part itself.
 if(!anyDrawTool()){var ihp=inspHitForPart(m,i);
  if(ihp){inspShow(ihp,ev);return;}
  inspClear();}
 if(pd&&pd.net&&viewSt.filt.pad)selNet(pd.net);
 if(!RO)selectComp(P[i].ref);}
svg.addEventListener("pointerup",function(ev){try{svg.releasePointerCapture(ev.pointerId);}catch(e){}
 if(ev.pointerType==="touch")touchUp(ev);
 if(pickHoldRelease(ev)){ev.preventDefault();return;}
 if(heatsinkDrag){var hsd=heatsinkDrag;heatsinkDrag=null;svg.style.cursor="";if(hsd.moved){recordUndo(hsd.snap);drawBoardRect();if(window.PCB3D&&window.PCB3D.sync)window.PCB3D.sync();outlineMsg("heatsink moved/resized — Save/Update to keep and refresh Thermal");}else hsModalOpen(PCB.heatsink);return;}
 if(heatsinkDraw){var hd=heatsinkDraw,gg=snapG();heatsinkDraw=null;
  var hx0=Math.round(Math.min(hd.x0,hd.x1)/gg)*gg,hy0=Math.round(Math.min(hd.y0,hd.y1)/gg)*gg,hx1=Math.round(Math.max(hd.x0,hd.x1)/gg)*gg,hy1=Math.round(Math.max(hd.y0,hd.y1)/gg)*gg;
  drawBoardRect();if(hx1-hx0<2||hy1-hy0<2){outlineMsg("heatsink unchanged — drag a rectangle at least 2 mm wide");return;}
  hsModalOpen({x:hx0,y:hy0,w:hx1-hx0,h:hy1-hy0});return;}
 if(vdrag){var vd=vdrag;vdrag=null;
  // The vertex moved in place during the drag; commit the pre-drag snapshot as
  // one undo step (Ctrl+Z reverts the whole vertex move) and re-run the DRC so
  // the board-edge geometry the mid-drag session probes tracks the new shape.
  // A stationary press is a plain click: select the board outline itself.
  if(vd.moved){if(vd.snap)recordUndo(vd.snap);else markDirty();if(activeSketchIsArea()){var avs=activeSketchShape();activeSketchChanged(OS&&avs&&avs.sketch&&OS.compile(avs.sketch));}else outlineDrc();outlineMsg(activeSketchName()+" edited — Save/Update to keep");}
  else outlineSelect("point",vd.i,vd.id,ev);
  return;}
 if(osdrag){var od=osdrag;osdrag=null;svg.style.cursor="";
  // A whole-edge slide is one undo step; re-DRC so the board edge follows it.
  // A stationary press is a plain click: select the board outline itself.
  if(od.moved){recordUndo(od.snap);if(activeSketchIsArea()){var aos=activeSketchShape();activeSketchChanged(OS&&aos&&aos.sketch&&OS.compile(aos.sketch));}else outlineDrc();outlineMsg(activeSketchName()+" edited — Save/Update to keep");}
  else outlineSelect("curve",od.i,od.id,ev);
  return;}
 if(segdrag){var sgd=segdrag;segdrag=null;svg.style.cursor="";
  segJogClean(sgd);
  if(sgd.moved){
   // The drag already mutated PCB.tracks in place; gate PRE-drag vs. now, and
   // if the engine flags a new routing-class violation, revert the whole move
   // (a segment drag must not be a back door to violating copper).
   if(drcGateDiffBlocks(sgd.snap.tracks||[],sgd.snap.vias||[],PCB.tracks||[],PCB.vias||[])){
    restoreSnap(sgd.snap);inspClear();
    routeStatMsg("move reverted — it would create a DRC error",true);return;}
   recordUndo(sgd.snap);routeStatMsg();scheduleDrc();}
  inspSet({t:"track",o:sgd.t});return;}
 if(viadrag){var vgd=viadrag;viadrag=null;svg.style.cursor="";
  if(vgd.moved){
   // Same contract as a segment drag: gate PRE-drag vs. now; a move that
   // introduces a new routing-class violation reverts atomically.
   if(drcGateDiffBlocks(vgd.snap.tracks||[],vgd.snap.vias||[],PCB.tracks||[],PCB.vias||[])){
    restoreSnap(vgd.snap);inspClear();
    routeStatMsg("move reverted — it would create a DRC error",true);return;}
   recordUndo(vgd.snap);routeStatMsg();scheduleDrc();
   inspSet({t:"via",o:vgd.v});return;}
  // No movement — the press was a plain click: today's click-to-inspect.
  inspShow({t:"via",o:vgd.v},ev);return;}
 if(txDrag){var moved=txDrag.moved,adopted=txDrag.adopted,ti=txDrag.i,tsnap=txDrag.snap;txDrag=null;svg.style.cursor="";
  if(moved||adopted){recordUndo(tsnap);txDirty();txPopReposition(ti);scheduleDrc();}return;}
 if(typeof gdrag!=="undefined"&&gdrag){var gmv=gdrag.moved,gsnap=gdrag.snap,gdn=gdrag.down,gbg=gdrag.boxGroup,gcu=gdrag.cuDown,gzones=gdrag.cz.length;gdrag=null;svg.style.cursor="";
  // No movement = a plain click on a rigid-group / multi-selected part (or on
  // selected copper) — select or inspect it like any other click instead of
  // swallowing it. Post-drag repaint drops the drag cache and restores pad labels.
  if(gmv){recordUndo(gsnap);fetchScore();dragCacheDrop();paintSoon();if(gzones)refillPours();if(anyCopper())scheduleDrc();}
  else if(gcu)inspShow(gcu,ev);
  else if(gbg)selectGroup(gbg);
  else if(gdn!=null&&gdn>=0)clickPart(ev,gdn);return;}
 if(typeof drag!=="undefined"&&drag){var dmv=drag.moved,dsnap=drag.snap,di2=drag.i;drag=null;svg.style.cursor="";
  if(dmv){recordUndo(dsnap);fetchScore();dragCacheDrop();paintSoon();if(anyCopper())scheduleDrc();return;}
  clickPart(ev,di2);return;}
 if(clickCand){var cc=clickCand;clickCand=null;clickPart(ev,cc.i);return;}
 if(outDraw){var d=outDraw;outDraw=null;if(!d.area)outlineArm(false);var og=snapG();
  var ax=Math.round(Math.min(d.x0,d.x1)/og)*og,ay=Math.round(Math.min(d.y0,d.y1)/og)*og;
  var bx=Math.round(Math.max(d.x0,d.x1)/og)*og,by=Math.round(Math.max(d.y0,d.y1)/og)*og;
  // A plain click is harmless; only a real rectangle drag replaces the shape.
  if(bx-ax<2||by-ay<2){drawBoardRect();outlineMsg(activeSketchName()+" unchanged — drag to draw a new rectangle");return;}
  // Undo the outline set as one step — snapshot the pre-commit outline
  // (the drag only previewed it via drawBoardRect, so PCB.outline is unchanged).
  var rectPre=snapAll();
  if(d.area&&activeSketchIsArea()){var rectShape=activeSketchShape(),rectPts=[[ax,ay],[bx,ay],[bx,by],[ax,by]];rectShape.poly=rectPts;rectShape.sketch=OS?OS.fromPolygon(rectPts):null;activeSketchSync(rectShape);outlineSelection=[];outlineRectArmed=false;recordUndo(rectPre);activeSketchChanged(OS&&OS.compile(rectShape.sketch));outlineSketchPanelSync();drawBoardRect();
   outlineMsg(activeSketchName()+" rectangle set — use the shared sketch tools or Save/Update to keep");return;}
  recordUndo(rectPre);
  PCB.outline={x:ax,y:ay,w:bx-ax,h:by-ay};
  outlineGeomDrop();
  drawBoardRect();
  var msg=document.getElementById("pcb-savemsg");
  if(msg){msg.style.color="#8b949e";
   msg.textContent="outline set — Save/Update to keep";}
  return;}
 if(pan){var click=!pan.moved&&pan.button!==1,tapi=pan.tapi;pan=null;svg.style.cursor="";
  if(click){
   // Part clicks route through clickPart (which owns the marker/pad/copper
   // precedence); empty-space clicks inspect bare copper before deselecting.
   if(tapi>=0)clickPart(ev,tapi);
   else{var pm=mm(ev);if(reviewClearOutside(pm))return;
    var ih=anyDrawTool()?null:inspHit(pm);
    if(ih){inspShow(ih,ev);}
    else{var rn=RO?reviewSurfaceNetAt(pm):"";
     if(rn)selNet(rn);else{inspClear();selCuClear();selClear();clearSel();selNet(null);}}}}return;}
 if(marq){var box=marq,mv=marq.moved;if(marqEl&&marqEl.parentNode)marqEl.parentNode.removeChild(marqEl);marqEl=null;marq=null;
  if(box.outline){if(mv&&OS){var oax=Math.min(box.x0,box.x1),oay=Math.min(box.y0,box.y1),obx=Math.max(box.x0,box.x1),oby=Math.max(box.y0,box.y1),osh=activeSketchPromote(),ops=OS.physicalPoints(osh.sketch),picked=[];
    ops.forEach(function(p,i){if(p.x>=oax&&p.x<=obx&&p.y>=oay&&p.y<=oby)picked.push({type:"point",index:i,id:p.id,key:"point:"+p.id});});
    if(!ev.shiftKey)outlineSelection=[];picked.forEach(function(s){if(!outlineSelection.some(function(q){return q.key===s.key;}))outlineSelection.push(s);});
    outlineSketchPanelSync();if(!activeSketchIsArea())showOutlineProps();drawBoardRect();outlineMsg(outlineSelection.length+" "+activeSketchName()+" sketch "+(outlineSelection.length===1?"vertex":"vertices")+" selected — Delete leaves loose endpoints; Line reconnects them");}
   else{outlineSelection=[];if(!activeSketchIsArea())showOutlineProps();drawBoardRect();}return;}
  if(mv){var ax=Math.min(box.x0,box.x1),ay=Math.min(box.y0,box.y1),bx=Math.max(box.x0,box.x1),by=Math.max(box.y0,box.y1);
   // Intersection test: a part is caught when its courtyard box overlaps the
   // band — so a large IC whose origin sits outside the rubber-band still
   // selects (KiCad's crossing-window behaviour).
   var pick=[];if(viewSt.filt.fp)P.forEach(function(p,i){if(!partOnVisibleFace(p))return;var b=partAABB(i);
    if(!(b.x1<ax||b.x0>bx||b.y1<ay||b.y0>by))pick.push(i);});
   // Copper rides the same band. The Objects tab's Tracks/Vias toggles decide
   // whether it joins the pick, so unchecking Footprints turns the marquee into
   // a copper-only tool; copper on a hidden layer stays unselectable, matching
   // the click hit-testers. Shift extends the previous selection.
   var ct=[],cv=[];
   if(!RO&&!anyDrawTool()){
    if(viewSt.filt.track)(PCB.tracks||[]).forEach(function(t){
     if(layerAlpha(t.l||0)<=0)return;
    if(trackChords(t).some(function(s){return segHitsRect(s.x1,s.y1,s.x2,s.y2,ax,ay,bx,by);}))ct.push(t);});
    if(viewSt.filt.via&&anyCopperVisible())(PCB.vias||[]).forEach(function(v){
     var r=(v.d||0.4)/2;
     if(!(v.x+r<ax||v.x-r>bx||v.y+r<ay||v.y-r>by))cv.push(v);});}
   if(ev.shiftKey&&!RO){
    ct=selCu.t.concat(ct.filter(function(o){return !selCuHas(o);}));
    cv=selCu.v.concat(cv.filter(function(o){return !selCuHas(o);}));
    pick=sel.concat(pick.filter(function(i){return sel.indexOf(i)<0;}));}
   clearSel();selSet(pick);selCuTo(ct,cv);marqReport(ct.length,cv.length);}
  else{
   // A stationary click on empty board: copper / DRC-marker inspection
   // before falling through to plain deselect.
   var anyTool2=drawMode||textMode||polyMode||pourMode||outlineMode||PCB.rulerOn;
   var mm2=mm(ev);if(reviewClearOutside(mm2))return;
   var ih2=anyTool2?null:inspHit(mm2);
   if(ih2){inspShow(ih2,ev);}
   else{var rn2=RO?reviewSurfaceNetAt(mm2):"";
    if(rn2)selNet(rn2);else{inspClear();selCuClear();selClear();clearSel();selNet(null);}}}return;}});
svg.addEventListener("mousedown",function(ev){if(ev.button===1)ev.preventDefault();});
svg.addEventListener("auxclick",function(ev){if(ev.button===1)ev.preventDefault();});
// ── T Text tool: board-level silkscreen labels ──────────────────────────
// Each entry {x,y,rot,side,size,text} is world-mm, drawn in a silk colour
// (distinct from ref-des) with the same compact vector metrics the PNG/Gerber
// use for hit-testing. Armed by the T button / key: a click on empty board places a new
// label (grid-snapped, on the hovered part's side else top). In either Text
// or ordinary Select mode, clicking an existing label selects it (edit its
// content/size/rot/side in the inline popover) and dragging moves it. R rotates
// 90°, Del / right-click deletes. Saved with the layout (PCB.texts →
// persistLayout) and emitted on the silk Gerber.
PCB.texts=PCB.texts||[];
var textMode=false,txSel=-1,txDrag=null;
var TX_COL=TH.silk; // board text is silkscreen — F.Silk white / B.Silk pink
// Hershey Simplex, the same glyph table src/silk_font.zig fabricates (y-down,
// 0 = cap top, SILK_CAP = baseline; -1,-1 pairs lift the pen; entry[0] is the
// glyph's own advance — the face is proportional). A Zig test proves this JSON
// stays glyph-for-glyph identical to the fabricated table.
var SILK_CAP=21,SILK_EM=SILK_CAP/0.9,SILK_FALLBACK_ADV=16;
var SILK_FONT=/*silk-font-table*/{" ":[16],"!":[10,5,0,5,14,-1,-1,5,19,4,20,5,21,6,20,5,19],"\"":[16,4,0,4,7,-1,-1,12,0,12,7],"#":[21,11,-4,4,28,-1,-1,17,-4,10,28,-1,-1,4,9,18,9,-1,-1,3,15,17,15],"$":[20,8,-4,8,25,-1,-1,12,-4,12,25,-1,-1,17,3,15,1,12,0,8,0,5,1,3,3,3,5,4,7,5,8,7,9,13,11,15,12,16,13,17,15,17,18,15,20,12,21,8,21,5,20,3,18],"%":[24,21,0,3,21,-1,-1,8,0,10,2,10,4,9,6,7,7,5,7,3,5,3,3,4,1,6,0,8,0,10,1,13,2,16,2,19,1,21,0,-1,-1,17,14,15,15,14,17,14,19,16,21,18,21,20,20,21,18,21,16,19,14,17,14],"&":[26,23,9,23,8,22,7,21,7,20,8,19,10,17,15,15,18,13,20,11,21,7,21,5,20,4,19,3,17,3,15,4,13,5,12,12,8,13,7,14,5,14,3,13,1,11,0,9,1,8,3,8,5,9,8,11,11,16,18,18,20,20,21,22,21,23,20,23,19],"'":[10,5,2,4,1,5,0,6,1,6,3,5,5,4,6],"(":[14,11,-4,9,-2,7,1,5,5,4,10,4,14,5,19,7,23,9,26,11,28],")":[14,3,-4,5,-2,7,1,9,5,10,10,10,14,9,19,7,23,5,26,3,28],"*":[16,8,0,8,12,-1,-1,3,3,13,9,-1,-1,13,3,3,9],"+":[26,13,3,13,21,-1,-1,4,12,22,12],",":[10,6,20,5,21,4,20,5,19,6,20,6,22,5,24,4,25],"-":[26,4,12,22,12],".":[10,5,19,4,20,5,21,6,20,5,19],"/":[22,20,-4,2,28],"0":[20,9,0,6,1,4,4,3,9,3,12,4,17,6,20,9,21,11,21,14,20,16,17,17,12,17,9,16,4,14,1,11,0,9,0],"1":[20,6,4,8,3,11,0,11,21],"2":[20,4,5,4,4,5,2,6,1,8,0,12,0,14,1,15,2,16,4,16,6,15,8,13,11,3,21,17,21],"3":[20,5,0,16,0,10,8,13,8,15,9,16,10,17,13,17,15,16,18,14,20,11,21,8,21,5,20,4,19,3,17],"4":[20,13,0,3,14,18,14,-1,-1,13,0,13,21],"5":[20,15,0,5,0,4,9,5,8,8,7,11,7,14,8,16,10,17,13,17,15,16,18,14,20,11,21,8,21,5,20,4,19,3,17],"6":[20,16,3,15,1,12,0,10,0,7,1,5,4,4,9,4,14,5,18,7,20,10,21,11,21,14,20,16,18,17,15,17,14,16,11,14,9,11,8,10,8,7,9,5,11,4,14],"7":[20,17,0,7,21,-1,-1,3,0,17,0],"8":[20,8,0,5,1,4,3,4,5,5,7,7,8,11,9,14,10,16,12,17,14,17,17,16,19,15,20,12,21,8,21,5,20,4,19,3,17,3,14,4,12,6,10,9,9,13,8,15,7,16,5,16,3,15,1,12,0,8,0],"9":[20,16,7,15,10,13,12,10,13,9,13,6,12,4,10,3,7,3,6,4,3,6,1,9,0,10,0,13,1,15,3,16,7,16,12,15,17,13,20,10,21,8,21,5,20,4,18],":":[10,5,7,4,8,5,9,6,8,5,7,-1,-1,5,19,4,20,5,21,6,20,5,19],";":[10,5,7,4,8,5,9,6,8,5,7,-1,-1,6,20,5,21,4,20,5,19,6,20,6,22,5,24,4,25],"<":[24,20,3,4,12,20,21],"=":[26,4,9,22,9,-1,-1,4,15,22,15],">":[24,4,3,20,12,4,21],"?":[18,3,5,3,4,4,2,5,1,7,0,11,0,13,1,14,2,15,4,15,6,14,8,13,9,9,11,9,14,-1,-1,9,19,8,20,9,21,10,20,9,19],"@":[27,18,8,17,6,15,5,12,5,10,6,9,7,8,10,8,13,9,15,11,16,14,16,16,15,17,13,-1,-1,12,5,10,7,9,10,9,13,10,15,11,16,-1,-1,18,5,17,13,17,15,19,16,21,16,23,14,24,11,24,9,23,6,22,4,20,2,18,1,15,0,12,0,9,1,7,2,5,4,4,6,3,9,3,12,4,15,5,17,7,19,9,20,12,21,15,21,18,20,20,19,21,18,-1,-1,19,5,18,13,18,15,19,16],"A":[18,9,0,1,21,-1,-1,9,0,17,21,-1,-1,4,14,14,14],"B":[21,4,0,4,21,-1,-1,4,0,13,0,16,1,17,2,18,4,18,6,17,8,16,9,13,10,-1,-1,4,10,13,10,16,11,17,12,18,14,18,17,17,19,16,20,13,21,4,21],"C":[21,18,5,17,3,15,1,13,0,9,0,7,1,5,3,4,5,3,8,3,13,4,16,5,18,7,20,9,21,13,21,15,20,17,18,18,16],"D":[21,4,0,4,21,-1,-1,4,0,11,0,14,1,16,3,17,5,18,8,18,13,17,16,16,18,14,20,11,21,4,21],"E":[19,4,0,4,21,-1,-1,4,0,17,0,-1,-1,4,10,12,10,-1,-1,4,21,17,21],"F":[18,4,0,4,21,-1,-1,4,0,17,0,-1,-1,4,10,12,10],"G":[21,18,5,17,3,15,1,13,0,9,0,7,1,5,3,4,5,3,8,3,13,4,16,5,18,7,20,9,21,13,21,15,20,17,18,18,16,18,13,-1,-1,13,13,18,13],"H":[22,4,0,4,21,-1,-1,18,0,18,21,-1,-1,4,10,18,10],"I":[8,4,0,4,21],"J":[16,12,0,12,16,11,19,10,20,8,21,6,21,4,20,3,19,2,16,2,14],"K":[21,4,0,4,21,-1,-1,18,0,4,14,-1,-1,9,9,18,21],"L":[17,4,0,4,21,-1,-1,4,21,16,21],"M":[24,4,0,4,21,-1,-1,4,0,12,21,-1,-1,20,0,12,21,-1,-1,20,0,20,21],"N":[22,4,0,4,21,-1,-1,4,0,18,21,-1,-1,18,0,18,21],"O":[22,9,0,7,1,5,3,4,5,3,8,3,13,4,16,5,18,7,20,9,21,13,21,15,20,17,18,18,16,19,13,19,8,18,5,17,3,15,1,13,0,9,0],"P":[21,4,0,4,21,-1,-1,4,0,13,0,16,1,17,2,18,4,18,7,17,9,16,10,13,11,4,11],"Q":[22,9,0,7,1,5,3,4,5,3,8,3,13,4,16,5,18,7,20,9,21,13,21,15,20,17,18,18,16,19,13,19,8,18,5,17,3,15,1,13,0,9,0,-1,-1,12,17,18,23],"R":[21,4,0,4,21,-1,-1,4,0,13,0,16,1,17,2,18,4,18,6,17,8,16,9,13,10,4,10,-1,-1,11,10,18,21],"S":[20,17,3,15,1,12,0,8,0,5,1,3,3,3,5,4,7,5,8,7,9,13,11,15,12,16,13,17,15,17,18,15,20,12,21,8,21,5,20,3,18],"T":[16,8,0,8,21,-1,-1,1,0,15,0],"U":[22,4,0,4,15,5,18,7,20,10,21,12,21,15,20,17,18,18,15,18,0],"V":[18,1,0,9,21,-1,-1,17,0,9,21],"W":[24,2,0,7,21,-1,-1,12,0,7,21,-1,-1,12,0,17,21,-1,-1,22,0,17,21],"X":[20,3,0,17,21,-1,-1,17,0,3,21],"Y":[18,1,0,9,10,9,21,-1,-1,17,0,9,10],"Z":[20,17,0,3,21,-1,-1,3,0,17,0,-1,-1,3,21,17,21],"[":[14,4,-4,4,28,-1,-1,5,-4,5,28,-1,-1,4,-4,11,-4,-1,-1,4,28,11,28],"\\":[14,0,0,14,24],"]":[14,9,-4,9,28,-1,-1,10,-4,10,28,-1,-1,3,-4,10,-4,-1,-1,3,28,10,28],"^":[16,6,6,8,3,10,6,-1,-1,3,9,8,4,13,9,-1,-1,8,4,8,21],"_":[16,0,23,16,23],"`":[10,6,0,5,1,4,3,4,5,5,6,6,5,5,4],"a":[19,15,7,15,21,-1,-1,15,10,13,8,11,7,8,7,6,8,4,10,3,13,3,15,4,18,6,20,8,21,11,21,13,20,15,18],"b":[19,4,0,4,21,-1,-1,4,10,6,8,8,7,11,7,13,8,15,10,16,13,16,15,15,18,13,20,11,21,8,21,6,20,4,18],"c":[18,15,10,13,8,11,7,8,7,6,8,4,10,3,13,3,15,4,18,6,20,8,21,11,21,13,20,15,18],"d":[19,15,0,15,21,-1,-1,15,10,13,8,11,7,8,7,6,8,4,10,3,13,3,15,4,18,6,20,8,21,11,21,13,20,15,18],"e":[18,3,13,15,13,15,11,14,9,13,8,11,7,8,7,6,8,4,10,3,13,3,15,4,18,6,20,8,21,11,21,13,20,15,18],"f":[12,10,0,8,0,6,1,5,4,5,21,-1,-1,2,7,9,7],"g":[19,15,7,15,23,14,26,13,27,11,28,8,28,6,27,-1,-1,15,10,13,8,11,7,8,7,6,8,4,10,3,13,3,15,4,18,6,20,8,21,11,21,13,20,15,18],"h":[19,4,0,4,21,-1,-1,4,11,7,8,9,7,12,7,14,8,15,11,15,21],"i":[8,3,0,4,1,5,0,4,-1,3,0,-1,-1,4,7,4,21],"j":[10,5,0,6,1,7,0,6,-1,5,0,-1,-1,6,7,6,24,5,27,3,28,1,28],"k":[17,4,0,4,21,-1,-1,14,7,4,17,-1,-1,8,13,15,21],"l":[8,4,0,4,21],"m":[30,4,7,4,21,-1,-1,4,11,7,8,9,7,12,7,14,8,15,11,15,21,-1,-1,15,11,18,8,20,7,23,7,25,8,26,11,26,21],"n":[19,4,7,4,21,-1,-1,4,11,7,8,9,7,12,7,14,8,15,11,15,21],"o":[19,8,7,6,8,4,10,3,13,3,15,4,18,6,20,8,21,11,21,13,20,15,18,16,15,16,13,15,10,13,8,11,7,8,7],"p":[19,4,7,4,28,-1,-1,4,10,6,8,8,7,11,7,13,8,15,10,16,13,16,15,15,18,13,20,11,21,8,21,6,20,4,18],"q":[19,15,7,15,28,-1,-1,15,10,13,8,11,7,8,7,6,8,4,10,3,13,3,15,4,18,6,20,8,21,11,21,13,20,15,18],"r":[13,4,7,4,21,-1,-1,4,13,5,10,7,8,9,7,12,7],"s":[17,14,10,13,8,10,7,7,7,4,8,3,10,4,12,6,13,11,14,13,15,14,17,14,18,13,20,10,21,7,21,4,20,3,18],"t":[12,5,0,5,17,6,20,8,21,10,21,-1,-1,2,7,9,7],"u":[19,4,7,4,17,5,20,7,21,10,21,12,20,15,17,-1,-1,15,7,15,21],"v":[16,2,7,8,21,-1,-1,14,7,8,21],"w":[22,3,7,7,21,-1,-1,11,7,7,21,-1,-1,11,7,15,21,-1,-1,19,7,15,21],"x":[17,3,7,14,21,-1,-1,14,7,3,21],"y":[16,2,7,8,21,-1,-1,14,7,8,21,6,25,4,27,2,28,1,28],"z":[17,14,7,3,21,-1,-1,3,7,14,7,-1,-1,3,21,14,21],"{":[14,9,-4,7,-3,6,-2,5,0,5,2,6,4,7,5,8,7,8,9,6,11,-1,-1,7,-3,6,-1,6,1,7,3,8,4,9,6,9,8,8,10,4,12,8,14,9,16,9,18,8,20,7,21,6,23,6,25,7,27,-1,-1,6,13,8,15,8,17,7,19,6,20,5,22,5,24,6,26,7,27,9,28],"|":[8,4,-4,4,28],"}":[14,5,-4,7,-3,8,-2,9,0,9,2,8,4,7,5,6,7,6,9,8,11,-1,-1,7,-3,8,-1,8,1,7,3,6,4,5,6,5,8,6,10,10,12,6,14,5,16,5,18,6,20,7,21,8,23,8,25,7,27,-1,-1,8,13,6,15,6,17,7,19,8,20,9,22,9,24,8,26,7,27,5,28],"~":[24,3,15,3,13,4,10,6,9,8,9,10,10,14,13,16,14,18,14,20,13,21,11,-1,-1,3,13,4,11,6,10,8,10,10,11,14,14,16,15,18,15,20,14,21,11,21,9]}/*end-silk-font-table*/;
function silkAdv(ch){var g=SILK_FONT[ch];return g?g[0]:SILK_FALLBACK_ADV;}
function silkTextHeight(size){return size*SILK_CAP/SILK_EM;}
function silkTextWidth(text,size){var s=String(text),u=0;for(var i=0;i<s.length;i++)u+=silkAdv(s.charAt(i));return u*size/SILK_EM;}
// Stroke `text` centred on the current transform origin (svg units), matching
// the Gerber writer: per-glyph pen advance, fixed 0.15 mm line width.
function silkStrokeText(ctx,text,size,col){var s=String(text),sc=(size>0?size:1.0)*S/SILK_EM,u=0,i;
 for(i=0;i<s.length;i++)u+=silkAdv(s.charAt(i));
 var pen=-u/2;
 ctx.strokeStyle=col;ctx.lineWidth=Math.max(0.15*S,1);ctx.lineCap="round";ctx.lineJoin="round";
 ctx.beginPath();
 for(i=0;i<s.length;i++){var ch=s.charAt(i),g=SILK_FONT[ch];
  if(g){var down=true;
   for(var k=1;k+1<g.length;k+=2){var x=g[k],y=g[k+1];
    if(x<0){down=true;continue;}
    var px=(pen+x)*sc,py=(y-SILK_CAP/2)*sc;
    if(down){ctx.moveTo(px,py);down=false;}else ctx.lineTo(px,py);}}
  pen+=silkAdv(ch);}
 ctx.stroke();}
function silkVisible(side){return !!viewSt.vis[side==="bottom"?LN.b_silks:LN.f_silks];}
function anySilkVisible(){return silkVisible("top")||silkVisible("bottom");}
function txArm(on){textMode=on;if(RO)textMode=false;
 if(on&&heatsinkMode)heatsinkArm(false);
 var b=document.getElementById("pcb-text");if(b)b.classList.toggle("on",textMode);
 svg.classList.toggle("text-mode",textMode);
 if(textMode&&padAlignMode)padAlignArm(false);
 if(textMode&&drawMode)drawModeSet(false);
 if(textMode&&outlineMode)outlineArm(false);
 if(textMode&&polyMode)polyArm(false);
 if(textMode&&pourMode)pourArm(false);
 if(textMode&&backingMode)backingArm(false);
 if(textMode&&PCB.rulerOff)PCB.rulerOff();
 var msg=document.getElementById("pcb-savemsg");
 if(msg&&textMode){msg.style.color=TX_COL;
  msg.textContent="text: click the board to place a label (click a label to edit, R rotates, Del deletes, Esc ends)";}
 else if(msg&&!textMode&&txSel<0){msg.textContent="";}
 if(!textMode)txPopClose();
 toolSync();
 paintSoon();}
// The rendered box of a text label in world mm (axis-aligned bbox after its
// quarter-turn), used for hit-testing and the selection outline.
function txBox(t){
 var size=t.size>0?t.size:1.0,w=silkTextWidth(t.text,size),h=silkTextHeight(size);
 var q=(((t.rot||0)%360)+360)%360,vert=(q===90||q===270);
 var bw=vert?h:w,bh=vert?w:h;
 return {x0:t.x-bw/2,y0:t.y-bh/2,x1:t.x+bw/2,y1:t.y+bh/2};}
function txAt(wx,wy){for(var i=PCB.texts.length-1;i>=0;i--){var t=PCB.texts[i];if(!silkVisible(t.side))continue;var b=txBox(t);
 if(wx>=b.x0&&wx<=b.x1&&wy>=b.y0&&wy<=b.y1)return i;}return -1;}
function fabTextOverridden(){for(var i=0;i<PCB.texts.length;i++)if(PCB.texts[i]&&PCB.texts[i].fabrication_id)return true;return false;}
function fabTextAt(wx,wy){var t=PCB.fab_text;if(RO||fabTextOverridden()||!t||!t.text||!silkVisible(t.side))return false;
 var b=txBox(t);return wx>=b.x0&&wx<=b.x1&&wy>=b.y0&&wy<=b.y1;}
function fabTextAdopt(){var t=PCB.fab_text;if(!t)return -1;
 PCB.texts.push({x:t.x,y:t.y,rot:t.rot||0,side:t.side||"top",size:t.size||1,text:t.text,fabrication_id:true});
 return PCB.texts.length-1;}
function txRotate(i,delta){var t=PCB.texts[i];if(!t)return;
 t.rot=((((t.rot||0)+delta)%360)+360)%360;}
// Text hit-testing follows the label's physical silk layer and stays
// disabled while another drawing tool owns the pointer.
function txDirectAt(m){return (!RO&&!anyDrawTool())?txAt(m.x,m.y):-1;}
function txDragStart(i,m,ev,snap,adopted){txSelect(i);
 txDrag={i:i,ox:PCB.texts[i].x-m.x,oy:PCB.texts[i].y-m.y,moved:false,snap:snap||snapAll(),adopted:!!adopted};
 pcap(ev);svg.style.cursor="grab";}
// Generated silkscreen artwork. It shares the owning side's F./B.Silkscreen
// fabrication layer with footprint art: each flattened top-level sub-circuit
// gets four short L corners around its live courtyard union, and overlapping
// boxes no longer merge into one shared envelope. Same-face box edges whose
// X or Y coordinates come within 1 mm snap to the shared midpoint so nearby
// envelopes line up cleanly, and a box whose corner marks a keepout would clip
// shifts itself a little so the marks still draw whole. Every sub-circuit
// keeps its fixed-size horizontal name, which searches corner-near top/bottom
// slots, then ±1 mm offsets, then the box interior. Names avoid
// pads/keepouts/generated art; each stroke is clipped into every printable
// fragment around same-face pads, keepouts, and the exact board edge.
// Courtyards may overlap the artwork. Prefer a U... hub as the main IC (then
// any hub, largest first); that part's side owns the artwork.
var SUB_SILK_MAX=1.0,SUB_SILK_GAP=0.15,SUB_SILK_CLEAR=0.2,SUB_SILK_EDGE=0.2,SUB_SILK_STROKE=0.15,SUB_SILK_INK_CLEAR=SUB_SILK_CLEAR+SUB_SILK_STROKE/2,SUB_SILK_CORNER_INSET=0.2,SUB_SILK_LABEL_OFFSET=1;
var SUB_SILK_SNAP=1,SUB_SILK_SHIFT_MAX=2,SUB_SILK_SHIFT_STEP=0.1;
var PIN_ONE_LIMIT=0.5,PIN_ONE_DIA=0.3,PIN_ONE_R=PIN_ONE_DIA/2,PIN_ONE_STEP=0.1,PIN_ONE_SEARCH=4;
var SUB_SILK_CORNER_FRACS=[0,1,0.125,0.875,0.25,0.75,0.375,0.625,0.5];
function subSilkTextWidth(g,size){return silkTextWidth(g,size);}
function subSilkLabelBox(t){var w=subSilkTextWidth(t.text,t.size),v=t.rot===90||t.rot===270;
 var h=silkTextHeight(t.size),bw=v?h:w,bh=v?w:h;return {x0:t.x-bw/2,y0:t.y-bh/2,x1:t.x+bw/2,y1:t.y+bh/2};}
function subSilkOverlap(a,b,c){return !(a.x1+c<=b.x0||b.x1+c<=a.x0||a.y1+c<=b.y0||b.y1+c<=a.y0);}
function subSilkBoxInsidePoly(b,pts,inset){var cx=(b.x0+b.x1)/2,cy=(b.y0+b.y1)/2;
 var ps=[[b.x0,b.y0],[cx,b.y0],[b.x1,b.y0],[b.x0,cy],[cx,cy],[b.x1,cy],[b.x0,b.y1],[cx,b.y1],[b.x1,b.y1]];
 for(var i=0;i<ps.length;i++)if(!polyContains(pts,ps[i][0],ps[i][1])||polyEdgeWithin(pts,ps[i][0],ps[i][1],inset))return false;
 var cs=[[b.x0,b.y0],[b.x1,b.y0],[b.x1,b.y1],[b.x0,b.y1]];
 for(var j=0;j<4;j++)for(var k=0;k<pts.length;k++)if(segsCross(cs[j],cs[(j+1)%4],pts[k],pts[(k+1)%pts.length]))return false;
 return true;}
function subSilkBoxHitsPoly(b,pts,clear){var r={x0:b.x0-clear,y0:b.y0-clear,x1:b.x1+clear,y1:b.y1+clear};
 var cs=[[r.x0,r.y0],[r.x1,r.y0],[r.x1,r.y1],[r.x0,r.y1]];
 for(var i=0;i<4;i++)if(polyContains(pts,cs[i][0],cs[i][1]))return true;
 for(var p=0;p<pts.length;p++)if(pts[p][0]>=r.x0&&pts[p][0]<=r.x1&&pts[p][1]>=r.y0&&pts[p][1]<=r.y1)return true;
 for(var j=0;j<4;j++)for(var k=0;k<pts.length;k++)if(segsCross(cs[j],cs[(j+1)%4],pts[k],pts[(k+1)%pts.length]))return true;
 return false;}
function subSilkBoardFit(b){var s=boardShape();if(s){
  if(b.x0<s.x+SUB_SILK_EDGE||b.x1>s.x+s.w-SUB_SILK_EDGE||b.y0<s.y+SUB_SILK_EDGE||b.y1>s.y+s.h-SUB_SILK_EDGE)return false;
  if(s.pts&&!subSilkBoxInsidePoly(b,s.pts,SUB_SILK_EDGE))return false;}
 var fixed=PCB.keepouts||[];for(var i=0;i<fixed.length;i++)if(fixed[i].inner&&fixed[i].inner.length>=3&&!subSilkBoxInsidePoly(b,fixed[i].inner,SUB_SILK_CLEAR))return false;
 return true;}
function subSilkClear(q,b,used,pads,keepouts){if(!subSilkBoardFit(b))return false;
 var ps=pads[q.side]||[];for(var i=0;i<ps.length;i++)if(subSilkOverlap(b,ps[i],SUB_SILK_CLEAR))return false;
 for(var z=0;z<keepouts.length;z++)if(subSilkBoxHitsPoly(b,keepouts[z],SUB_SILK_CLEAR))return false;
 for(var u=0;u<used.length;u++)if(used[u].side===q.side&&subSilkOverlap(b,used[u].box,SUB_SILK_CLEAR))return false;
 return true;}
function subSilkEdgeCandidate(q,edge,fraction,shift){var extent=subSilkTextWidth(q.g,SUB_SILK_MAX);
 var lo=q.x0+q.l+SUB_SILK_GAP+SUB_SILK_CORNER_INSET+extent/2,hi=q.x1-q.l-SUB_SILK_GAP-SUB_SILK_CORNER_INSET-extent/2;if(lo>hi+1e-9)return null;
 return {x:lo+fraction*(hi-lo),y:(edge==="top"?q.y0:q.y1)+shift,rot:0,size:SUB_SILK_MAX,text:q.g};}
function subSilkLabelHitsCorners(q,b){var clear=SUB_SILK_CLEAR+SUB_SILK_STROKE/2,segs=q.labelArt||subSilkRawSegments(q);
 for(var i=0;i<segs.length;i++){var s=segs[i],r={x0:Math.min(s.x1,s.x2)-clear,y0:Math.min(s.y1,s.y2)-clear,x1:Math.max(s.x1,s.x2)+clear,y1:Math.max(s.y1,s.y2)+clear};
  if(subSilkOverlap(b,r,0))return true;}return false;}
function subSilkCornerScore(x,y){return Math.min(x+y,(1-x)+y,x+(1-y),(1-x)+(1-y));}
function subSilkPlaceInside(q,used,pads,keepouts){var w=subSilkTextWidth(q.g,SUB_SILK_MAX),hh=silkTextHeight(SUB_SILK_MAX)/2,xlo=q.x0+w/2,xhi=q.x1-w/2,ylo=q.y0+hh,yhi=q.y1-hh;
 if(xlo>xhi||ylo>yhi)return null;var best=null;
 for(var yi=0;yi<SUB_SILK_CORNER_FRACS.length;yi++)for(var xi=0;xi<SUB_SILK_CORNER_FRACS.length;xi++){
  var yf=SUB_SILK_CORNER_FRACS[yi],xf=SUB_SILK_CORNER_FRACS[xi],t={x:xlo+xf*(xhi-xlo),y:ylo+yf*(yhi-ylo),rot:0,size:SUB_SILK_MAX,text:q.g},b=subSilkLabelBox(t);
  if(subSilkLabelHitsCorners(q,b)||!subSilkClear(q,b,used,pads,keepouts))continue;
  var score=subSilkCornerScore(xf,yf);if(!best||score<best.score)best={text:t,score:score};}
 return best?best.text:null;}
function subSilkIntervalDist(v,lo,hi){return v<lo?lo-v:(v>hi?v-hi:0);}
function subSilkPlaceNearby(q,used,pads,keepouts){var shape=boardShape();if(!shape)return null;
 var w=subSilkTextWidth(q.g,SUB_SILK_MAX),step=0.5,xlo=shape.x+SUB_SILK_EDGE+w/2,xhi=shape.x+shape.w-SUB_SILK_EDGE-w/2;
 var hh=silkTextHeight(SUB_SILK_MAX)/2,ylo=shape.y+SUB_SILK_EDGE+hh,yhi=shape.y+shape.h-SUB_SILK_EDGE-hh;
 if(xlo>xhi||ylo>yhi)return null;var nx=Math.max(1,Math.ceil((xhi-xlo)/step)),ny=Math.max(1,Math.ceil((yhi-ylo)/step)),best=null;
 for(var yi=0;yi<=ny;yi++){var y=yi===ny?yhi:ylo+yi*step;
  for(var xi=0;xi<=nx;xi++){var x=xi===nx?xhi:xlo+xi*step,t={x:x,y:y,rot:0,size:SUB_SILK_MAX,text:q.g},b=subSilkLabelBox(t);
   if(subSilkLabelHitsCorners(q,b)||!subSilkClear(q,b,used,pads,keepouts))continue;
   var dx=subSilkIntervalDist(x,q.x0,q.x1),dy=subSilkIntervalDist(y,q.y0,q.y1),score=dx*dx+dy*dy;
   if(!best||score<best.score)best={text:t,score:score};}}
 return best?best.text:null;}
function subSilkPlace(q,used,pads,keepouts){var edges=["top","bottom"],i,e,cand,edge,inward,shifts,si;
 // Tier 1: fixed-size horizontal text inline, nearest-corner slots first.
 for(i=0;i<SUB_SILK_CORNER_FRACS.length;i++)for(e=0;e<edges.length;e++){
  cand=subSilkEdgeCandidate(q,edges[e],SUB_SILK_CORNER_FRACS[i],0);
  if(cand&&subSilkClear(q,subSilkLabelBox(cand),used,pads,keepouts))return cand;}
 // Tier 2: the same X slots shifted 1 mm inward first, then outward.
 for(i=0;i<SUB_SILK_CORNER_FRACS.length;i++)for(e=0;e<edges.length;e++){edge=edges[e];inward=edge==="top"?SUB_SILK_LABEL_OFFSET:-SUB_SILK_LABEL_OFFSET;shifts=[inward,-inward];
  for(si=0;si<shifts.length;si++){cand=subSilkEdgeCandidate(q,edge,SUB_SILK_CORNER_FRACS[i],shifts[si]);
   if(cand&&subSilkClear(q,subSilkLabelBox(cand),used,pads,keepouts))return cand;}}
 // Tier 3: anywhere inside the box, still preferring positions by a corner.
 cand=subSilkPlaceInside(q,used,pads,keepouts);if(cand)return cand;
 // Tier 4: search all valid board space and take the nearest remaining slot.
 return subSilkPlaceNearby(q,used,pads,keepouts);}
function subSilkRawSegments(q){var d=SUB_SILK_CORNER_INSET;return [
 {x1:q.x0+d+q.l,y1:q.y0+d,x2:q.x0+d,y2:q.y0+d},{x1:q.x0+d,y1:q.y0+d,x2:q.x0+d,y2:q.y0+d+q.l},
 {x1:q.x1-d-q.l,y1:q.y0+d,x2:q.x1-d,y2:q.y0+d},{x1:q.x1-d,y1:q.y0+d,x2:q.x1-d,y2:q.y0+d+q.l},
 {x1:q.x0+d+q.l,y1:q.y1-d,x2:q.x0+d,y2:q.y1-d},{x1:q.x0+d,y1:q.y1-d,x2:q.x0+d,y2:q.y1-d-q.l},
 {x1:q.x1-d-q.l,y1:q.y1-d,x2:q.x1-d,y2:q.y1-d},{x1:q.x1-d,y1:q.y1-d,x2:q.x1-d,y2:q.y1-d-q.l}];}
function subSilkClusterLeg(r){return Math.max(0.75,Math.min(2,Math.min(r.x1-r.x0,r.y1-r.y0)*0.22));}
// Align any X/Y edges of same-face annotation boxes that come within
// SUB_SILK_SNAP of each other. Perpendicular overlap is irrelevant: parallel
// edges should line up even when their boxes sit next to one another.
function subSilkSnapEdges(qs){
 var changed=true,passes=0;
 while(changed&&passes<=qs.length){changed=false;passes++;
  for(var i=0;i<qs.length;i++)for(var j=i+1;j<qs.length;j++){
   var a=qs[i],b=qs[j];if(a.side!==b.side)continue;
   if(subSilkSnapOne(a,"x0",b,"x0"))changed=true;
   if(subSilkSnapOne(a,"x1",b,"x1"))changed=true;
   if(subSilkSnapFacing(a,"x1",b,"x0",a.y0,a.y1,b.y0,b.y1))changed=true;
   if(subSilkSnapFacing(b,"x1",a,"x0",b.y0,b.y1,a.y0,a.y1))changed=true;
   if(subSilkSnapOne(a,"y0",b,"y0"))changed=true;
   if(subSilkSnapOne(a,"y1",b,"y1"))changed=true;
   if(subSilkSnapFacing(a,"y1",b,"y0",a.x0,a.x1,b.x0,b.x1))changed=true;
   if(subSilkSnapFacing(b,"y1",a,"y0",b.x0,b.x1,a.x0,a.x1))changed=true;}}
}
// Move two distinct edge coordinates to their shared midpoint when their
// absolute difference is within the inclusive tolerance.
function subSilkSnapOne(qa,ka,qb,kb){
 var gap=Math.abs(qb[kb]-qa[ka]);
 if(gap===0||gap>SUB_SILK_SNAP)return false;
 var mid=(qa[ka]+qb[kb])/2;qa[ka]=mid;qb[kb]=mid;return true;}
// Opposite edges align only across a real gap with overlapping perpendicular
// spans, never through an overlap or between diagonally separated boxes.
function subSilkSnapFacing(qa,ka,qb,kb,p0lo,p0hi,p1lo,p1hi){
 var gap=qb[kb]-qa[ka];
 if(gap<=0||gap>SUB_SILK_SNAP)return false;
 if(Math.max(p0lo,p1lo)>=Math.min(p0hi,p1hi))return false;
 var mid=(qa[ka]+qb[kb])/2;qa[ka]=mid;qb[kb]=mid;return true;}
// True if any point of `s` comes within the finished-stroke clearance of a
// keepout, meaning the clipping pass would cut the stroke there.
function subSilkSegHitsKeepout(s,keepouts){var len=Math.hypot(s.x2-s.x1,s.y2-s.y1),steps=Math.max(1,Math.ceil(len/0.025));
 for(var i=0;i<=steps;i++){var p=subSilkSegPoint(s,i/steps);
  for(var z=0;z<keepouts.length;z++)if(polyContains(keepouts[z],p[0],p[1])||polyDistEdge(keepouts[z],p[0],p[1])<=SUB_SILK_INK_CLEAR)return true;}
 return false;}
// True when none of the annotation's eight corner strokes would be clipped by
// a keepout.
function subSilkBoxClearKeepouts(q,keepouts){var segs=subSilkRawSegments(q);
 for(var i=0;i<segs.length;i++)if(subSilkSegHitsKeepout(segs[i],keepouts))return false;
 return true;}
// A keepout that would clip a sub-circuit box's corner marks translates the
// whole box by the smallest step that lets every mark draw whole; pads and the
// board edge still clip afterwards as a safety net.
function subSilkShiftClearKeepouts(qs,keepouts){
 if(!keepouts||!keepouts.length)return;
 var maxI=Math.floor(SUB_SILK_SHIFT_MAX/SUB_SILK_SHIFT_STEP);
 for(var qi=0;qi<qs.length;qi++){var q=qs[qi];
  if(subSilkBoxClearKeepouts(q,keepouts))continue;
  var best=null,bestScore=1/0;
  for(var dxi=-maxI;dxi<=maxI;dxi++){var dx=dxi*SUB_SILK_SHIFT_STEP;
   for(var dyi=-maxI;dyi<=maxI;dyi++){var dy=dyi*SUB_SILK_SHIFT_STEP,score=Math.abs(dx)+Math.abs(dy);
    if(score>=bestScore)continue;
    var t={g:q.g,x0:q.x0+dx,y0:q.y0+dy,x1:q.x1+dx,y1:q.y1+dy,l:q.l,side:q.side};
    if(subSilkBoxClearKeepouts(t,keepouts)){best=[dx,dy];bestScore=score;}}}
  if(best){q.x0+=best[0];q.y0+=best[1];q.x1+=best[0];q.y1+=best[1];}}}
// Assign printable geometry to every annotation: snap nearby edges, shift a
// box whose marks a keepout would clip, then give each box its own four
// corner L marks (no shared envelope, no edge-T dividers). `labelArt` holds
// every same-side raw stroke so later labels avoid the whole artwork set.
function subSilkAssignArt(qs,keepouts){
 var i;
 subSilkSnapEdges(qs);
 for(i=0;i<qs.length;i++){var q=qs[i];
  q.l=subSilkClusterLeg({x0:q.x0,y0:q.y0,x1:q.x1,y1:q.y1});
  q.raw=[];q.labelArt=[];}
 subSilkShiftClearKeepouts(qs,keepouts);
 var art={top:[],bottom:[]};
 for(i=0;i<qs.length;i++){var q2=qs[i];
  q2.raw=subSilkRawSegments(q2);
  art[q2.side]=art[q2.side].concat(q2.raw);}
 for(i=0;i<qs.length;i++)qs[i].labelArt=art[qs[i].side];}
function subSilkPointBoardFit(p){var shape=boardShape(),r=SUB_SILK_INK_CLEAR;if(shape){
  if(p[0]<shape.x+r||p[0]>shape.x+shape.w-r||p[1]<shape.y+r||p[1]>shape.y+shape.h-r)return false;
  if(shape.pts&&(!polyContains(shape.pts,p[0],p[1])||polyEdgeWithin(shape.pts,p[0],p[1],r)))return false;}
 var fixed=PCB.keepouts||[];for(var i=0;i<fixed.length;i++)if(fixed[i].inner&&fixed[i].inner.length>=3&&
  (!polyContains(fixed[i].inner,p[0],p[1])||polyDistEdge(fixed[i].inner,p[0],p[1])<r))return false;
 return true;}
function subSilkPointClear(q,p,pads,keepouts){if(!subSilkPointBoardFit(p))return false;var r=SUB_SILK_INK_CLEAR,ps=pads[q.side]||[];
 for(var i=0;i<ps.length;i++)if(p[0]>=ps[i].x0-r&&p[0]<=ps[i].x1+r&&p[1]>=ps[i].y0-r&&p[1]<=ps[i].y1+r)return false;
 for(var z=0;z<keepouts.length;z++)if(polyContains(keepouts[z],p[0],p[1])||polyDistEdge(keepouts[z],p[0],p[1])<=r)return false;
 return true;}
function subSilkSegPoint(s,t){return [s.x1+(s.x2-s.x1)*t,s.y1+(s.y2-s.y1)*t];}
function subSilkSegEdge(q,s,pads,keepouts,a,b,state){for(var n=0;n<14;n++){var m=(a+b)/2;
 if(subSilkPointClear(q,subSilkSegPoint(s,m),pads,keepouts)===state)a=m;else b=m;}return (a+b)/2;}
function subSilkClipSeg(q,s,pads,keepouts){var out=[],len=Math.hypot(s.x2-s.x1,s.y2-s.y1),steps=Math.max(1,Math.ceil(len/0.025));
 var pt=0,prev=subSilkPointClear(q,subSilkSegPoint(s,0),pads,keepouts),start=prev?0:null;
 for(var i=1;i<=steps;i++){var t=i/steps,ok=subSilkPointClear(q,subSilkSegPoint(s,t),pads,keepouts);
  if(ok!==prev){var edge=subSilkSegEdge(q,s,pads,keepouts,pt,t,prev);
   if(prev){if(len*(edge-start)>=0.01){var a=subSilkSegPoint(s,start),b=subSilkSegPoint(s,edge);out.push({x1:a[0],y1:a[1],x2:b[0],y2:b[1]});}}
   else start=edge;}
  pt=t;prev=ok;}
 if(prev&&len*(1-start)>=0.01){var a=subSilkSegPoint(s,start),b=subSilkSegPoint(s,1);out.push({x1:a[0],y1:a[1],x2:b[0],y2:b[1]});}
 return out;}
function subSilkGeom(g){var idxs=GRPS[g]||[],x0=1/0,y0=1/0,x1=-1/0,y1=-1/0,side="top",rank=-1,area=-1,n=0;
 for(var j=0;j<idxs.length;j++){var i=idxs[j],p=P[i];if(unplacedSet[p.ref])continue;var b=partAABB(i);n++;
  x0=Math.min(x0,b.x0);y0=Math.min(y0,b.y0);x1=Math.max(x1,b.x1);y1=Math.max(y1,b.y1);
  var leaf=String(p.ref).slice(String(p.ref).lastIndexOf("/")+1),r=p.kind==="hub"?(/^U/i.test(leaf)?2:1):0,a=4*p.hw*p.hh;
  if(r>rank||(r===rank&&a>area)){rank=r;area=a;side=p.side||"top";}}
 if(!n)return null;
 x0-=0.5;y0-=0.5;x1+=0.5;y1+=0.5;
 var l=Math.max(0.75,Math.min(2,Math.min(x1-x0,y1-y0)*0.22));
 return {g:g,x0:x0,y0:y0,x1:x1,y1:y1,l:l,side:side};}
function subSilkObstaclesPart(i,pads,silk){var p=P[i];if(unplacedSet[p.ref])return;var pp=p.pads||[];
 for(var pi=0;pi<pp.length;pi++){var b=wrect(i,pp[pi]),both=pp[pi].thru||pp[pi].npth;
  if(both||(p.side||"top")==="top")pads.top.push(b);if(both||(p.side||"top")==="bottom")pads.bottom.push(b);}
 var side=p.side||"top",art=p.silk||{},ls=art.l||[],cs=art.c||[];
 for(var li=0;li<ls.length;li++){var a=wpt(i,ls[li][0],ls[li][1]),z=wpt(i,ls[li][2],ls[li][3]);silk[side].push({line:true,x1:a.x,y1:a.y,x2:z.x,y2:z.y});}
 for(var ci=0;ci<cs.length;ci++){if(pinOneAuthoredCircle(cs[ci]))continue;var c=wpt(i,cs[ci][0],cs[ci][1]);silk[side].push({line:false,x:c.x,y:c.y,r:cs[ci][2]});}}
// Obstacles for every part (set null) or only the indices in `set` (an object
// keyed by part index) — the drag-time silk split re-derives just the movers'
// pads/silk each frame and freezes the rest, so this never walks the whole
// board on a hot path it can avoid.
function subSilkObstaclesRange(set){var pads={top:[],bottom:[]},silk={top:[],bottom:[]};
 for(var i=0;i<P.length;i++){if(set&&!set[i])continue;subSilkObstaclesPart(i,pads,silk);}
 var keepouts=[],zones=PCB.zones||[];for(var zi=0;zi<zones.length;zi++)if(zones[zi].keepout&&zones[zi].poly&&zones[zi].poly.length>=3)keepouts.push(zones[zi].poly);
 return {pads:pads,silk:silk,keepouts:keepouts};}
function subSilkObstacles(){return subSilkObstaclesRange(null);}
function subSilkAllGeom(obstacles){var out=[],used=[],overrides={},o=obstacles||subSilkObstacles(),pads=o.pads,keepouts=o.keepouts;
 var texts=PCB.texts||[];for(var ti=0;ti<texts.length;ti++){var t=texts[ti];if(!t||!t.text)continue;
  used.push({side:t.side||"top",box:txBox(t)});if(t.subcircuit)overrides[t.subcircuit]=true;}
 var qs=[];for(var g in GRPS){if(!Object.prototype.hasOwnProperty.call(GRPS,g))continue;var q=subSilkGeom(g);if(q)qs.push(q);}
 subSilkAssignArt(qs,keepouts);
 for(var qi=0;qi<qs.length;qi++){q=qs[qi];q.label=overrides[q.g]?null:subSilkPlace(q,used,pads,keepouts);q.segs=[];var raw=q.raw;
  for(var si=0;si<raw.length;si++)q.segs=q.segs.concat(subSilkClipSeg(q,raw[si],pads,keepouts));
  if(q.label)used.push({side:q.side,box:subSilkLabelBox(q.label)});out.push(q);}return out;}
function subSilkAt(wx,wy){if(RO||(anyDrawTool()&&!textMode)||!anySilkVisible())return null;
 var all=boardSilkCurrentGeom().subs;
 for(var i=all.length-1;i>=0;i--){var q=all[i];if(!q.label||!silkVisible(q.side))continue;var b=subSilkLabelBox(q.label);
  if(wx>=b.x0&&wx<=b.x1&&wy>=b.y0&&wy<=b.y1)return q;}return null;}
function subSilkAdopt(q){var t=q.label;
 PCB.texts.push({x:t.x,y:t.y,rot:t.rot||0,side:q.side||"top",size:t.size||SUB_SILK_MAX,text:t.text,subcircuit:q.g});
 return PCB.texts.length-1;}
// Dragging a rigid sub-circuit releases any adopted name override: the name
// returns to automatic placement and follows the moving group again.
function subSilkRelease(g){if(!g)return;
 for(var i=PCB.texts.length-1;i>=0;i--){var t=PCB.texts[i];
  if(t&&t.subcircuit===g)PCB.texts.splice(i,1);}
 ovsRev++;}
// JLCPCB high-precision minimum: 0.8 mm character height. Fabrication uses
// the shared 0.15 mm Gerber stroke, so the smaller labels retain robust ink.
var TP_SILK_SIZE=0.8*SILK_EM/SILK_CAP,TP_SILK_GAP=0.2,TP_SILK_RINGS=[0,0.5,1,1.5,2,2.5,3,3.5,4,4.5,5,5.5,6];
function testPointSilkPlace(i,used,pads,keepouts){var p=P[i],b=partAABB(i),side=p.side||"top",cx=(b.x0+b.x1)/2,cy=(b.y0+b.y1)/2,shownRef=refLabel(p.ref),w=subSilkTextWidth(shownRef,TP_SILK_SIZE);
 for(var ri=0;ri<TP_SILK_RINGS.length;ri++){var ring=TP_SILK_RINGS[ri],hh=silkTextHeight(TP_SILK_SIZE)/2,top=b.y0-TP_SILK_GAP-ring-hh,bottom=b.y1+TP_SILK_GAP+ring+hh;
  var left=b.x0-TP_SILK_GAP-ring-w/2,right=b.x1+TP_SILK_GAP+ring+w/2,diag=w/2+TP_SILK_GAP+ring;
  var pos=[[cx,top],[cx-diag,top],[cx+diag,top],[cx,bottom],[cx-diag,bottom],[cx+diag,bottom],[left,cy],[right,cy]];
  for(var j=0;j<pos.length;j++){var t={x:pos[j][0],y:pos[j][1],rot:0,size:TP_SILK_SIZE,text:shownRef};
   if(subSilkClear({side:side},subSilkLabelBox(t),used,pads,keepouts))return t;}}
 return null;}
function testPointSilkAt(wx,wy){if(RO||(anyDrawTool()&&!textMode)||!anySilkVisible())return null;
 var all=boardSilkCurrentGeom().tps;
 for(var i=all.length-1;i>=0;i--){var tp=all[i];if(!silkVisible(tp.side))continue;var b=subSilkLabelBox(tp.label);
  if(wx>=b.x0&&wx<=b.x1&&wy>=b.y0&&wy<=b.y1)return tp;}return null;}
function testPointSilkAdopt(tp){var t=tp.label,p=P[tp.i];if(!p)return -1;
 PCB.texts.push({x:t.x,y:t.y,rot:t.rot||0,side:tp.side||"top",size:t.size||TP_SILK_SIZE,text:t.text,testpoint:p.ref});
 return PCB.texts.length-1;}
// Moving the physical test point releases its adopted label so automatic
// placement follows the pad again. Dragging the label itself keeps it manual.
function testPointSilkRelease(ref){if(!ref)return;
 var changed=false;
 for(var i=PCB.texts.length-1;i>=0;i--){var t=PCB.texts[i];
  if(t&&t.testpoint===ref){PCB.texts.splice(i,1);changed=true;}}
 if(changed)ovsRev++;}
function pinOneAuthoredCircle(sc){return !!(sc&&sc[2]>0&&2*sc[2]<PIN_ONE_LIMIT);}
function pinOnePad(p){var pads=p.pads||[],i;for(i=0;i<pads.length;i++)if(String(pads[i].num||"")==="1")return pads[i];
 for(i=0;i<pads.length;i++)if(String(pads[i].num||"").toUpperCase()==="A1")return pads[i];return null;}
function pinOneAuthored(p){var cs=p.silk&&p.silk.c||[];for(var i=0;i<cs.length;i++)if(pinOneAuthoredCircle(cs[i]))return cs[i];return null;}
function pinOneDirectional(p){if(pinOneAuthored(p))return true;var pads=p.pads||[],leaf=refLabel(p.ref),lead=(leaf.charAt(0)||"").toUpperCase();
 return (p.kind==="hub"&&pads.length>1)||(pads.length===2&&(lead==="D"||lead==="Q"));}
function pinOneEligible(p){return !!(pinOnePad(p)&&pinOneDirectional(p));}
function pinOneBox(x,y){return {x0:x-PIN_ONE_R,y0:y-PIN_ONE_R,x1:x+PIN_ONE_R,y1:y+PIN_ONE_R};}
function pinOneHitsFootprintSilk(side,x,y,silk){var art=silk[side]||[],gap=PIN_ONE_R+SUB_SILK_STROKE/2+SUB_SILK_CLEAR;
 for(var i=0;i<art.length;i++){var a=art[i],d=a.line?ptSegDist(x,y,a.x1,a.y1,a.x2,a.y2):Math.abs(Math.hypot(x-a.x,y-a.y)-a.r);if(d<gap)return true;}return false;}
function pinOneClear(side,x,y,used,pads,keepouts,silk){return !pinOneHitsFootprintSilk(side,x,y,silk)&&subSilkClear({side:side},pinOneBox(x,y),used,pads,keepouts);}
function pinOneSilkPlace(i,used,pads,keepouts,silk){var p=P[i],pd=pinOnePad(p),sc=pinOneAuthored(p);if(!pd||!pinOneDirectional(p))return null;
 var side=p.side||"top",pin=wpt(i,pd.x,pd.y),old=sc?wpt(i,sc[0],sc[1]):pin,dx=sc?old.x-pin.x:pin.x-p.x,dy=sc?old.y-pin.y:pin.y-p.y,len=Math.hypot(dx,dy);
 if(len<1e-9){dx=pin.x-p.x;dy=pin.y-p.y;len=Math.hypot(dx,dy);}if(len<1e-9){dx=-1;dy=-1;len=Math.SQRT2;}
 var base=Math.atan2(dy/len,dx/len);if(sc&&pinOneClear(side,old.x,old.y,used,pads,keepouts,silk))return {i:i,side:side,x:old.x,y:old.y};
 var first=Math.max(pd.w||0,pd.h||0)/2+SUB_SILK_CLEAR+PIN_ONE_R,offs=[0,-1,1,-2,2,-3,3,4],steps=Math.ceil(PIN_ONE_SEARCH/PIN_ONE_STEP);
 for(var ri=0;ri<=steps;ri++){var radius=first+ri*PIN_ONE_STEP;for(var oi=0;oi<offs.length;oi++){var a=base+offs[oi]*Math.PI/4,x=pin.x+radius*Math.cos(a),y=pin.y+radius*Math.sin(a);
   if(pinOneClear(side,x,y,used,pads,keepouts,silk))return {i:i,side:side,x:x,y:y};}}return null;}
// The last painted geometry doubles as the annotation hit map. Pointer hover
// used to rerun the collision search (including its whole-board fallback grid)
// on every event, making the editor crawl whenever annotations were visible.
// ovsRev/outlineGeomRev reject a map made stale while the silk was hidden;
// ordinary visible edits repaint and refresh this map before the next hover.
var boardSilkHitGeom=null,boardSilkHitRev=-1,boardSilkHitOutline=-1;
function boardSilkAllGeom(){var obstacles=subSilkObstacles(),subs=subSilkAllGeom(obstacles),used=[],texts=PCB.texts||[],testpointOverrides={};
 for(var ti=0;ti<texts.length;ti++)if(texts[ti]&&texts[ti].text){used.push({side:texts[ti].side||"top",box:txBox(texts[ti])});if(texts[ti].testpoint)testpointOverrides[texts[ti].testpoint]=true;}
 for(var qi=0;qi<subs.length;qi++){var q=subs[qi];if(q.label)used.push({side:q.side,box:subSilkLabelBox(q.label)});
  for(var si=0;si<q.segs.length;si++){var s=q.segs[si],r=SUB_SILK_STROKE/2;used.push({side:q.side,box:{x0:Math.min(s.x1,s.x2)-r,y0:Math.min(s.y1,s.y2)-r,x1:Math.max(s.x1,s.x2)+r,y1:Math.max(s.y1,s.y2)+r}});}}
 var tps=[];for(var i=0;i<P.length;i++){var p=P[i];if(!testPointPart(p)||unplacedSet[p.ref]||testpointOverrides[p.ref])continue;
  var label=testPointSilkPlace(i,used,obstacles.pads,obstacles.keepouts);if(!label)continue;
 var side=p.side||"top";used.push({side:side,box:subSilkLabelBox(label)});tps.push({i:i,side:side,label:label});}
 var pin1=[];for(var pi=0;pi<P.length;pi++){var pp=P[pi];if(unplacedSet[pp.ref])continue;var marker=pinOneSilkPlace(pi,used,obstacles.pads,obstacles.keepouts,obstacles.silk);if(!marker)continue;
  used.push({side:marker.side,box:pinOneBox(marker.x,marker.y)});pin1.push(marker);}
 var out={subs:subs,tps:tps,pin1:pin1};boardSilkHitGeom=out;boardSilkHitRev=ovsRev;boardSilkHitOutline=outlineGeomRev;return out;}
function boardSilkCurrentGeom(){return boardSilkHitGeom&&boardSilkHitRev===ovsRev&&boardSilkHitOutline===outlineGeomRev?boardSilkHitGeom:boardSilkAllGeom();}
// The 3D face compositor is loaded lazily after this editor. Give it the exact
// generated fabrication geometry already resolved here (clipped sub-circuit
// brackets/labels, test-point labels and pin-1 dots) so both views paint one
// result instead of maintaining two placement algorithms.
window.PCBGeneratedSilk=function(){return boardSilkCurrentGeom();};
// ── Drag-time generated-silk geometry ───────────────────────────────────
// A part drag repaints the moving half on every pointermove. Re-deriving the
// WHOLE generated-silk set each frame — every subcircuit's label search + ink
// clipping, every test-point ring sweep, every pin-1 spiral — is what made
// dragging crawl once the F./B.Silkscreen eyes were on. Only the owners in the
// moving set actually change, so the mover-free half (artwork, used boxes,
// obstacles) is derived once per gesture and each frame re-derives just the
// movers' labels/ink against those frozen boxes; movers still track the
// pointer live. dragCacheDrop clears the split, and the quiet repaint's full
// boardSilkAllGeom settles every label at its final position again.
var dragSilk=null; // {key,rev,subs,tps,pin1,used,ink,pads,silk,keepouts,overrides,testpointOverrides,movSet}
function dragSilkMovKey(mov){var out=[],i;for(i=0;i<P.length;i++)if(mov[i])out.push(i);return out.join(",");}
function boardSilkDragGeom(movG,mov){
 var mk=dragSilkMovKey(mov),i,si;
 if(!dragSilk||dragSilk.key!==mk||dragSilk.rev!==ovsRev){
  // First frame with this moving set: full geometry once, split into the
  // frozen mover-free half and the per-frame movers (re-derived below). The
  // poses were already updated before the first drag paint, so this is the
  // same input the old per-frame recompute would have used.
  var full=boardSilkAllGeom();
  var ss=[],st=[],sp=[],used=[],ink={top:[],bottom:[]},texts=PCB.texts||[];
  for(i=0;i<full.subs.length;i++){var q=full.subs[i];if(!movG[q.g])ss.push(q);}
  for(i=0;i<full.tps.length;i++){var t=full.tps[i];if(!mov[t.i])st.push(t);}
  for(i=0;i<full.pin1.length;i++){var p=full.pin1[i];if(!mov[p.i])sp.push(p);}
  // Frozen box set (texts + every static artwork box) plus the static ink
  // (unclipped raw legs) the movers' label search must also steer clear of.
  for(i=0;i<texts.length;i++)if(texts[i]&&texts[i].text)used.push({side:texts[i].side||"top",box:txBox(texts[i])});
  for(i=0;i<ss.length;i++){q=ss[i];
   for(si=0;si<q.raw.length;si++)ink[q.side].push(q.raw[si]);
   if(q.label)used.push({side:q.side,box:subSilkLabelBox(q.label)});
   for(si=0;si<q.segs.length;si++){var s=q.segs[si],r=SUB_SILK_STROKE/2;used.push({side:q.side,box:{x0:Math.min(s.x1,s.x2)-r,y0:Math.min(s.y1,s.y2)-r,x1:Math.max(s.x1,s.x2)+r,y1:Math.max(s.y1,s.y2)+r}});}}
  for(i=0;i<st.length;i++)used.push({side:st[i].side,box:subSilkLabelBox(st[i].label)});
  for(i=0;i<sp.length;i++)used.push({side:sp[i].side,box:pinOneBox(sp[i].x,sp[i].y)});
  var overrides={},testpointOverrides={};
  for(i=0;i<texts.length;i++){var t2=texts[i];if(t2&&t2.subcircuit)overrides[t2.subcircuit]=true;if(t2&&t2.testpoint)testpointOverrides[t2.testpoint]=true;}
  var ob=subSilkObstacles(),movSet={};
  for(i=0;i<P.length;i++)if(mov[i])movSet[i]=true;
  dragSilk={key:mk,rev:ovsRev,subs:ss,tps:st,pin1:sp,used:used,ink:ink,pads:ob.pads,silk:ob.silk,keepouts:ob.keepouts,overrides:overrides,testpointOverrides:testpointOverrides,movSet:movSet};
 }
 var o=dragSilk;
 // Live obstacles: the frozen static pads/silk plus the movers' current
 // pads/silk (their poses change every pointermove).
 var movOb=subSilkObstaclesRange(o.movSet);
 var pads={top:o.pads.top.concat(movOb.pads.top),bottom:o.pads.bottom.concat(movOb.pads.bottom)};
 var silk={top:o.silk.top.concat(movOb.silk.top),bottom:o.silk.bottom.concat(movOb.silk.bottom)};
 // Moving subcircuit artwork: labels placed against the frozen static boxes
 // and each other (same GRPS order the full pass uses), ink clipped against
 // the live obstacles, leader legs re-derived among the movers only.
 var used=o.used.concat([]),qs=[],msubs=[],g;
 for(g in GRPS){if(!Object.prototype.hasOwnProperty.call(GRPS,g)||!movG[g])continue;
  var q=subSilkGeom(g);if(q)qs.push(q);}
 subSilkAssignArt(qs,o.keepouts);
 for(i=0;i<qs.length;i++){q=qs[i];
  q.labelArt=(o.ink[q.side]||[]).concat(q.labelArt||[]);
  q.label=o.overrides[q.g]?null:subSilkPlace(q,used,pads,o.keepouts);q.segs=[];
  var raw=q.raw;
  for(si=0;si<raw.length;si++)q.segs=q.segs.concat(subSilkClipSeg(q,raw[si],pads,o.keepouts));
  if(q.label)used.push({side:q.side,box:subSilkLabelBox(q.label)});
  msubs.push(q);}
 // The movers' clipped ink joins the frozen boxes before the ring/spiral
 // searches, exactly as boardSilkAllGeom seeds `used` with every sub's segs.
 for(i=0;i<msubs.length;i++){q=msubs[i];
  for(si=0;si<q.segs.length;si++){var s=q.segs[si],r=SUB_SILK_STROKE/2;used.push({side:q.side,box:{x0:Math.min(s.x1,s.x2)-r,y0:Math.min(s.y1,s.y2)-r,x1:Math.max(s.x1,s.x2)+r,y1:Math.max(s.y1,s.y2)+r}});}}
 // Moving test-point labels and pin-1 markers: the ring/spiral re-searched
 // against the live pads/silk, still clear of the frozen boxes above.
 var mtps=[];
 for(i=0;i<P.length;i++){if(!mov[i])continue;var p2=P[i];if(!testPointPart(p2)||unplacedSet[p2.ref]||o.testpointOverrides[p2.ref])continue;
  var label=testPointSilkPlace(i,used,pads,o.keepouts);if(!label)continue;
  var side=p2.side||"top";used.push({side:side,box:subSilkLabelBox(label)});mtps.push({i:i,side:side,label:label});}
 var mpin1=[];
 for(i=0;i<P.length;i++){if(!mov[i])continue;var pp=P[i];if(unplacedSet[pp.ref])continue;
  var marker=pinOneSilkPlace(i,used,pads,o.keepouts,silk);if(!marker)continue;
  used.push({side:marker.side,box:pinOneBox(marker.x,marker.y)});mpin1.push(marker);}
 return {subs:o.subs.concat(msubs),tps:o.tps.concat(mtps),pin1:o.pin1.concat(mpin1)};}
function paintSilkLabel(ctx,t,side){var bot=side==="bottom";ctx.save();ctx.translate(X(t.x),Y(t.y));ctx.rotate((t.rot||0)*Math.PI/180);if(bot)ctx.scale(-1,1);
 silkStrokeText(ctx,t.text,t.size,PHYSICAL_REVIEW?PH.silk:(bot?TH.silkBot:TH.silk));ctx.restore();}
function paintSubcircuitSilk(ctx,movG,only,all){
 all=all||subSilkAllGeom();for(var qi=0;qi<all.length;qi++){var q=all[qi];if(movG&&(!!movG[q.g])!==only)continue;
  if(!silkVisible(q.side))continue;var bot=q.side==="bottom";if(PHYSICAL_REVIEW&&(bot?1:0)!==activeLayer)continue;
  ctx.save();ctx.strokeStyle=PHYSICAL_REVIEW?PH.silk:(bot?TH.silkBot:TH.silk);
  ctx.lineWidth=Math.max(0.15*S,1);ctx.lineCap="round";ctx.lineJoin="round";ctx.beginPath();
  for(var si=0;si<q.segs.length;si++){var sg=q.segs[si];ctx.moveTo(X(sg.x1),Y(sg.y1));ctx.lineTo(X(sg.x2),Y(sg.y2));}ctx.stroke();ctx.restore();
  if(q.label)paintSilkLabel(ctx,q.label,q.side);}}
function paintTestPointSilk(ctx,mov,only,all){for(var i=0;i<all.length;i++){var tp=all[i];if(mov&&(!!mov[tp.i])!==only)continue;
 if(!silkVisible(tp.side))continue;var bot=tp.side==="bottom";if(PHYSICAL_REVIEW&&(bot?1:0)!==activeLayer)continue;paintSilkLabel(ctx,tp.label,tp.side);}}
function paintPinOneSilk(ctx,mov,only,all){for(var i=0;i<all.length;i++){var marker=all[i];if(mov&&(!!mov[marker.i])!==only)continue;
 if(!silkVisible(marker.side))continue;var bot=marker.side==="bottom";if(PHYSICAL_REVIEW&&(bot?1:0)!==activeLayer)continue;
 ctx.save();ctx.fillStyle=PHYSICAL_REVIEW?PH.silk:(bot?TH.silkBot:TH.silk);ctx.beginPath();ctx.arc(X(marker.x),Y(marker.y),PIN_ONE_R*S,0,6.2832);ctx.fill();ctx.restore();}}
// Board text and generated annotations are ordinary side-specific silk ink,
// controlled by the same F./B.Silkscreen eyes as footprint artwork.
function paintBoardSilk(ctx,k,movG,mov,only){if(!anySilkVisible())return;
 // A text drag re-runs the whole search (one label moved can free or block
 // every auto label); a part drag re-derives only the movers' artwork, because
 // the mover-free half is frozen in the static drag-cache bitmap anyway.
 var all=txDrag?boardSilkAllGeom():((!movG&&!mov)?boardSilkCurrentGeom():boardSilkDragGeom(movG,mov));
 paintSubcircuitSilk(ctx,movG,only,all.subs);paintTestPointSilk(ctx,mov,only,all.tps);paintPinOneSilk(ctx,mov,only,all.pin1);if(only!==true){paintTexts(ctx);
  if(!fabTextOverridden()&&PCB.fab_text)paintSilkLabel(ctx,PCB.fab_text,PCB.fab_text.side||"top");}}
function paintTexts(ctx){
 for(var i=0;i<PCB.texts.length;i++){var t=PCB.texts[i];if(!t.text)continue;
  if(!silkVisible(t.side))continue;var bot=(t.side==="bottom");
  if(PHYSICAL_REVIEW&&(bot?1:0)!==activeLayer)continue;
  ctx.save();
  ctx.translate(X(t.x),Y(t.y));ctx.rotate((t.rot||0)*Math.PI/180);
  if(bot)ctx.scale(-1,1);
  silkStrokeText(ctx,t.text,t.size,PHYSICAL_REVIEW?PH.silk:(bot?TH.silkBot:TX_COL));
  ctx.restore();
  if(i===txSel){var b=txBox(t);
   ctx.strokeStyle="#f0b72f";ctx.lineWidth=1.4;ctx.setLineDash([4,3]);
   ctx.strokeRect(X(b.x0),Y(b.y0),(b.x1-b.x0)*S,(b.y1-b.y0)*S);ctx.setLineDash([]);}}}
// Inline editor popover for the selected label (content / size / rot / side).
var txPop=null;
function txPopClose(){if(txPop&&txPop.parentNode)txPop.parentNode.removeChild(txPop);txPop=null;}
function txPopOpen(i){txPopClose();var t=PCB.texts[i];if(!t)return;
 var host=svg.parentNode;if(!host)return;
 // One undo entry per edit burst: the pre-edit snapshot is captured now and
 // pushed on the FIRST mutating control event (typing more keeps amending).
 var pre=snapAll();function txOnce(){if(pre){recordUndo(pre);pre=null;}}
 txPop=document.createElement("div");txPop.className="tx-pop";
 txPop.style.cssText="position:absolute;z-index:20;background:#232428;border:1px solid #3a3b40;"+
  "border-radius:6px;padding:8px;font:12px system-ui;color:#d6d7db;box-shadow:0 4px 16px rgba(0,0,0,.5);min-width:190px";
 var b=txBox(t),sx=svg.getBoundingClientRect(),vb2=svg.viewBox.baseVal;
 var kx=sx.width/vb2.w,ky=sx.height/vb2.h;
 txPop.style.left=(svg.offsetLeft+(X(b.x0)-vb2.x)*kx)+"px";
 txPop.style.top=(svg.offsetTop+(Y(b.y1)-vb2.y)*ky+6)+"px";
 function row(label,node){var r=document.createElement("label");
  r.style.cssText="display:flex;align-items:center;gap:6px;margin:3px 0";
  var s=document.createElement("span");s.textContent=label;s.style.cssText="width:44px;color:#9b9ca3";
  r.appendChild(s);r.appendChild(node);return r;}
 var ti=document.createElement("input");ti.type="text";ti.value=t.text;ti.disabled=!!t.fabrication_id;
 ti.style.cssText="flex:1;background:#1a1b1e;border:1px solid #3a3b40;color:#d6d7db;border-radius:4px;padding:2px 4px";
 // Each control bumps ovsRev: a live edit restyles baked silk text, and unlike
 // the other text paths it never reaches txDirty until the burst ends.
 ti.addEventListener("input",function(){txOnce();t.text=ti.value;ovsRev++;paintSoon();});
 var si=document.createElement("input");si.type="number";si.step="0.1";si.min="0.3";si.value=(t.size||1).toString();
 si.style.cssText="width:64px;background:#1a1b1e;border:1px solid #3a3b40;color:#d6d7db;border-radius:4px;padding:2px 4px";
 si.addEventListener("input",function(){var v=parseFloat(si.value);if(v>0){txOnce();t.size=v;ovsRev++;paintSoon();txPopReposition(i);}});
 var ro=document.createElement("select");["0","90","180","270"].forEach(function(v){var o=document.createElement("option");o.value=v;o.textContent=v+"°";ro.appendChild(o);});
 ro.value=String(((t.rot||0)%360+360)%360);ro.style.cssText="background:#1a1b1e;border:1px solid #3a3b40;color:#d6d7db;border-radius:4px;padding:2px";
 ro.addEventListener("change",function(){txOnce();t.rot=parseInt(ro.value,10)||0;ovsRev++;paintSoon();txPopReposition(i);});
 var sd=document.createElement("select");[["top","Top"],["bottom","Bottom"]].forEach(function(p){var o=document.createElement("option");o.value=p[0];o.textContent=p[1];sd.appendChild(o);});
 sd.value=(t.side==="bottom")?"bottom":"top";sd.style.cssText="background:#1a1b1e;border:1px solid #3a3b40;color:#d6d7db;border-radius:4px;padding:2px";
 sd.addEventListener("change",function(){txOnce();t.side=sd.value;ovsRev++;paintSoon();});
 var del=document.createElement("button");del.textContent="Delete";del.className="btn";
 del.addEventListener("click",function(){txDelete(i);});
 txPop.appendChild(row("Text",ti));txPop.appendChild(row("Size",si));
 txPop.appendChild(row("Rot",ro));txPop.appendChild(row("Side",sd));
 var da=document.createElement("div");da.style.cssText="margin-top:6px;text-align:right";da.appendChild(del);txPop.appendChild(da);
 host.appendChild(txPop);ti.focus();ti.select();}
function txPopReposition(i){if(txPop&&txSel===i)txPopOpen(i);}
function txSelect(i){txSel=i;paintSoon();if(i>=0)txPopOpen(i);else txPopClose();}
function txDelete(i){if(i<0||i>=PCB.texts.length)return;recordUndo();PCB.texts.splice(i,1);
 txSel=-1;txPopClose();paintSoon();txDirty();}
function txDirty(){ovsRev++; // silk labels are baked into the overscan pan buffer
 var msg=document.getElementById("pcb-savemsg");
 if(msg){msg.style.color="#8b949e";msg.textContent="text changed — Save/Update to keep";}
 if(window.PCBFindRefresh)window.PCBFindRefresh();}
function txPlace(m){var gx=Math.round(m.x/G)*G,gy=Math.round(m.y/G)*G;
 var s=window.prompt("Silkscreen text:","");if(s==null)return;s=s.trim();if(!s)return;
 var side=(cur>=0&&P[cur].side==="bottom")?"bottom":"top";
 recordUndo();
 PCB.texts.push({x:gx,y:gy,rot:0,side:side,size:1.0,text:s});
 txSelect(PCB.texts.length-1);txDirty();}
var textBtn=document.getElementById("pcb-text");
if(textBtn&&!RO)textBtn.addEventListener("click",function(){txArm(!textMode);});
function viaGeo(){var va=parseFloat((document.getElementById("r-va")||{}).value),
 vd=parseFloat((document.getElementById("r-vd")||{}).value);return {dia:va>0?va:0.4,drill:vd>0?vd:0.2};}
function drawVia(g,wx,wy,dia,drill){var r=viaRenderRadius(dia),rh=viaRenderRadius(drill);
 g.appendChild(el("circle",{cx:X(wx).toFixed(1),cy:Y(wy).toFixed(1),r:r.toFixed(1),fill:TH.via}));
 g.appendChild(el("circle",{cx:X(wx).toFixed(1),cy:Y(wy).toFixed(1),r:rh.toFixed(1),fill:TH.viaHole}));}
// Drop only the copper belonging to the given parts' nets (a moved part
// invalidates its own routing, everything else stays drawn). Falls back to
// keeping legacy net-less copper ("" — old saves) untouched.
// Copper tagged with a stamp group (t.g — module copper carried in by Stamp)
// survives net-based clearing and rides along when its whole group drags or
// rotates (keepG names the group; the caller transforms that copper itself).
// clearRouteFor is reserved for deliberately copper-invalidating operations
// such as flipping a component or replacing a group's module-layout stamp;
// ordinary pose edits retain copper and let ratsnest/DRC show disconnections.
function anyCopper(){return (PCB.tracks||[]).length>0||(PCB.vias||[]).length>0||(PCB.rf_paths||[]).length>0;}
function clearRouteFor(idxs,keepG){
 if(!((PCB.tracks||[]).length)&&!((PCB.vias||[]).length)&&!((PCB.rf_paths||[]).length))return;
 var nets={};idxs.forEach(function(i){(P[i].pads||[]).forEach(function(pd){if(pd.net)nets[pd.net]=1;});});
 var gs={};idxs.forEach(function(i){var g=grpOf(P[i].ref);if(g&&g!==keepG)gs[g]=1;});
 PCB.tracks=(PCB.tracks||[]).filter(function(t){
  if(t.g)return !gs[t.g];
  return !(t.net&&nets[t.net]);});
 PCB.vias=(PCB.vias||[]).filter(function(v){
  // Fence provenance is checked FIRST: a fence via's own net is GND (which a
  // moved RF part never invalidates) while v.f names the RF trace it hugs, and
  // it carries no group tag, so the v.g branch below would never see it.
  if(v.f)return !nets[v.f];
  if(v.g)return !gs[v.g];
  return !(v.net&&nets[v.net]);});
 PCB.rf_paths=(PCB.rf_paths||[]).filter(function(p){return !(p.net&&nets[p.net]);});
 PCB.drc=[];selCuClear();drawRoute();drawDrc();}
function drawRoute(){cuGeomDrop();if(gpuOn)PCBGpu.rebuildCopper();dragCacheDrop();ovPaintSoon();} // routed copper lives on the canvas overlay
// (every wholesale PCB.tracks/PCB.vias replacement — Load, draft, undo, route
//  apply, clearRouteFor — funnels through here, so the batch drops with it)
function clrVal(){var ci=document.getElementById("r-cl"),c=ci?parseFloat(ci.value):NaN;
 return (c>0)?c:(PCB.clr||0.127);}
function drawClr(){ovPaintSoon();} // clearance halos live on the canvas overlay
// The clearance-halo toggle is ordinary Appearance state (viewSt.vis.clr), so
// it survives a reload like every neighbouring row instead of living only in
// its checkbox. Both surfaces that own that checkbox — the full page's
// Appearance dock and an embed's Route panel — read and write it through here,
// so they cannot disagree.
function clrOn(){return !!viewSt.vis.clr;}
function clrSync(){var els=document.querySelectorAll("#r-clr-show");
 for(var i=0;i<els.length;i++)els[i].checked=clrOn();
 if(PCB.apSync)PCB.apSync();} // …and the Objects row that drives the same flag
function clrSet(on){viewSt.vis.clr=on?1:0;viewSave();clrSync();drawClr();}
var clrCb=document.getElementById("r-clr-show");
if(clrCb){
 if(clrCb.checked)viewSt.vis.clr=1; // an embed's ?clr=1 seeds the state (no save)
 clrCb.checked=clrOn();
 clrCb.addEventListener("change",function(){clrSet(clrCb.checked);});}
var clrIn=document.getElementById("r-cl");
if(clrIn)clrIn.addEventListener("input",drawClr);
// ── Hand routing: draw tracks + vias (X) ────────────────────────────────
// KiCad-style manual routing on the same PCB.tracks/PCB.vias model the
// autorouter fills: click a pad to start (net + layer come from the pad),
// click to fix 45° or 90° grid-snapped corners (Shift = free angle), V drops a via
// and flips layer, click a same-net pad / double-click / Enter to finish,
// Backspace steps back, Esc ends (then exits the mode). Right-click deletes
// the track/via under the cursor. Copper persists through the normal layout
// Save/Update (routes ride the sidecar), so a module's hand routing saved on
// its own page is exactly what Stamp later carries onto a parent board.
var drawMode=false,dtrace=null,drawCur=null,drawShift=false;
// Transient red flash of a commit the engine gate refused (see drcGateBlocks):
// the draw head stays live, and paintDraw pulses these world-space legs red so
// the user sees the click didn't take instead of silently getting nothing.
var drawFlash=null; // {legs:[{x1,y1,x2,y2}],until:ms}
function drawFlashSet(segs){drawFlash={legs:segs,until:Date.now()+520};ovPaintSoon();}
var DRAW_W_KEY="pcb-draw-width:"+(PCB.name||"");
function baseTrackW(){var v=parseFloat((document.getElementById("r-tw")||{}).value);return v>0?v:0.25;}
function trackW(net){var s=document.getElementById("r-dw"),mode=s?s.value:"net",v;
 if(mode==="net"){var c=netClassInfo(net||"");v=c&&parseFloat(c.width);return v>0?v:baseTrackW();}
 if(mode==="custom")return baseTrackW();v=parseFloat(mode);return v>0?v:baseTrackW();}
function drawWidthInit(){var s=document.getElementById("r-dw");if(!s)return;
 try{var saved=localStorage.getItem(DRAW_W_KEY);if(saved&&s.querySelector('option[value="'+saved+'"]'))s.value=saved;}catch(e){}
 s.addEventListener("change",function(){try{localStorage.setItem(DRAW_W_KEY,s.value);}catch(e){}
  if(dtrace&&dtrace.n===0)dtrace.w=trackW(dtrace.net);drawArcControlSync();drawBtnSync();ovPaintSoon();});}
drawWidthInit();
// Manual route angle is an interaction preference, independent of the
// sharp/rounded corner treatment below. The status-bar selector is visible
// while Draw is armed; E toggles the same setting for editable embeds, which
// do not carry the full-page status bar.
var DRAW_ANGLE_KEY="pcb-draw-angle",drawAngle="45";
function drawAngleControlSync(){var wrap=document.getElementById("st-bend"),s=document.getElementById("pcb-bend-angle");
 if(s)s.value=drawAngle;if(wrap)wrap.hidden=!drawMode;}
function drawAngleSet(value,announce){drawAngle=value==="90"?"90":"45";
 try{localStorage.setItem(DRAW_ANGLE_KEY,drawAngle);}catch(e){}
 drawAngleControlSync();drawBtnSync();ovPaintSoon();
 if(announce)routeStatMsg(drawAngle+"° trace bends");}
function drawAngleInit(){var s=document.getElementById("pcb-bend-angle");
 try{if(localStorage.getItem(DRAW_ANGLE_KEY)==="90")drawAngle="90";}catch(e){}
 if(s)s.addEventListener("change",function(){drawAngleSet(s.value,true);});drawAngleControlSync();}
drawAngleInit();
// Manual bend style. Rounded mode uses the same representation as the RF
// autorouter: true tangent-circle geometry tessellated into copper chords with
// <=0.01 mm sagitta, so save/export/DRC need no second trace format. A zero
// radius means the RF rule of thumb, 3x the active trace width.
var DRAW_BEND_KEY="pcb-draw-bend",DRAW_RADIUS_KEY="pcb-draw-arc-radius";
function drawArcOn(){var s=document.getElementById("r-bend");return !!s&&s.value==="arc";}
function drawArcRadius(){var i=document.getElementById("r-br"),v=parseFloat(i?i.value:0);
 return v>0?v:3*(dtrace?dtrace.w:baseTrackW());}
function drawArcControlSync(msg){var s=document.getElementById("r-bend"),i=document.getElementById("r-br"),o=document.getElementById("r-arc-stat");
 if(!s)return;var on=s.value==="arc";if(i)i.disabled=!on;
 if(o){var v=parseFloat(i?i.value:0),r=drawArcRadius();
  o.textContent=msg||(on?(dtrace&&dtrace.pair?"rounded bends pause while the differential pair is coupled":
   (!dtrace&&!(v>0)?"automatic 3× active trace width":((v>0?"requested ":"automatic 3× width · ")+r.toFixed(3)+" mm"))):(drawAngle+"° posture corners"));}}
function drawArcInit(){var s=document.getElementById("r-bend"),i=document.getElementById("r-br");if(!s||!i)return;
 try{var bs=localStorage.getItem(DRAW_BEND_KEY),rs=localStorage.getItem(DRAW_RADIUS_KEY);
  if(bs==="arc"||bs==="sharp")s.value=bs;if(rs!=null&&parseFloat(rs)>=0)i.value=rs;}catch(e){}
 s.addEventListener("change",function(){try{localStorage.setItem(DRAW_BEND_KEY,s.value);}catch(e){}
  drawArcControlSync();drawBtnSync();ovPaintSoon();});
 i.addEventListener("input",function(){try{localStorage.setItem(DRAW_RADIUS_KEY,i.value);}catch(e){}
  drawArcControlSync();drawBtnSync();ovPaintSoon();});drawArcControlSync();}
drawArcInit();
// Tool-strip radio state + the status bar's tool segment. The Select tool
// lights up whenever no drawing mode is armed.
function toolSync(){
 var ruler=!!PCB.rulerOn;
 var any=drawMode||textMode||polyMode||pourMode||outlineMode||backingMode||heatsinkMode||ruler||padAlignMode;
 var sb=document.getElementById("tool-select");if(sb)sb.classList.toggle("on",!any);
 stSet("st-tool",drawMode?(dtrace?("route "+nLeaf(dtrace.net)+(dtrace.pair?" ⇄ "+nLeaf(dtrace.pair.net):"")+" · "+layerName(dtrace.l)+" · "+dtrace.w+" mm · "+drawAngle+"°"+(drawArcOn()&&!dtrace.pair?(" · arc R"+drawArcRadius().toFixed(3)):"")):("route · "+layerName(activeLayer)+" · "+drawAngle+"°"+(drawArcOn()?" · arcs":"")))
  :(padAlignMode?(padAlignA?(padAlignB?"align pads · choose X or Y":"align pads · target pad"):"align pads · moving pad"):(textMode?"text":(heatsinkMode?"heatsink":(backingMode?"backing":(polyMode?"poly outline":(pourMode?"copper pour":(outlineMode?"outline":(ruler?"measure":""))))))))); }
function drawBtnSync(){var b=document.getElementById("pcb-draw");if(!b)return;
 b.classList.toggle("on",drawMode);
 var al=layerName(activeLayer);
 var lbl=drawMode?(dtrace?("✎ "+nLeaf(dtrace.net)+(dtrace.pair?" ⇄ "+nLeaf(dtrace.pair.net):"")+" · "+layerName(dtrace.l)):("✎ click a pad… ["+al+"]")):"✎ Draw";
 // Icon button (tool strip): fixed glyph, live state in the tooltip + status
 // bar. Text button (embed action bar): the classic swapping label.
 if(b.classList.contains("ts-btn")){
  if(!b.getAttribute("data-tip"))b.setAttribute("data-tip",b.title||"");
  b.title=drawMode?lbl:b.getAttribute("data-tip");}
 else b.textContent=lbl;
 drawArcControlSync();drawAngleControlSync();toolSync();}
function drawModeSet(on){if(RO)return;drawMode=on;if(!on)dtrace=null;
 if(on&&heatsinkMode)heatsinkArm(false);
 if(on){drcGateInit();drcGateSessionEnsure();} // warm/reload only when copper is about to need it
 // Arming Draw surfaces the Route panel's track-width / layer controls. The
 // chip may already be active while the dock shows another tab, so raise the
 // Autorouter tab either way.
 if(on){pcbSideTab("side-route");
  var rc=document.querySelector('.tab-chip[data-panel="panel-route"]');
  if(rc&&!rc.classList.contains("active"))rc.click();}
 if(on&&padAlignMode)padAlignArm(false);
 if(on&&outlineMode)outlineArm(false);
 if(on&&polyMode)polyArm(false);
 if(on&&pourMode)pourArm(false);
 if(on&&backingMode)backingArm(false);
 if(on&&textMode)txArm(false);
 if(on&&PCB.rulerOff)PCB.rulerOff();
 svg.style.cursor=on?"crosshair":"";drawBtnSync();ovPaintSoon();}
// Grid snap for the draw tool. A click reaches the exact snapped point through
// drawPath's selected 45° octilinear or 90° Manhattan leg pair, so nothing is
// projected away.
function drawSnap(m){var dg=snapG();
 return {x:Math.round(m.x/dg)*dg,y:Math.round(m.y/dg)*dg};}
// KiCad-style corner posture: the route from the last vertex to the target is
// up to two constrained legs. In 45° mode that is one axis-aligned and one
// diagonal leg; in 90° mode it is one of the two Manhattan elbows. '/'
// switches the first/second-leg posture in either mode. Returns [target] when
// one constrained leg already reaches it.
var drawPosture=0;
function drawPath(ax,ay,t,posture){
 var po=(posture==null)?drawPosture:posture;
 var dx=t.x-ax,dy=t.y-ay,adx=Math.abs(dx),ady=Math.abs(dy);
 if(adx<1e-9||ady<1e-9)return [t];
 if(drawAngle==="90")return [po===0?{x:t.x,y:ay}:{x:ax,y:t.y},t];
 if(Math.abs(adx-ady)<1e-9)return [t];
 var m=Math.min(adx,ady),sx=dx<0?-1:1,sy=dy<0?-1:1,mid;
 if(po===0)mid=(adx>ady)?{x:t.x-sx*m,y:ay}:{x:ax,y:t.y-sy*m};
 else mid={x:ax+sx*m,y:ay+sy*m};
 return [mid,t];}
// Tangent fillet for polyline corner a→b→c. The requested radius shrinks only
// when the adjacent legs cannot fit it; each trim is capped at 45% of both
// legs so two neighboring arcs never cross on their shared leg.
function arcCorner(a,b,c,want){var x1=b.x-a.x,y1=b.y-a.y,x2=c.x-b.x,y2=c.y-b.y,
 l1=Math.hypot(x1,y1),l2=Math.hypot(x2,y2);if(l1<1e-6||l2<1e-6||!(want>0))return null;
 var u={x:x1/l1,y:y1/l1},v={x:x2/l2,y:y2/l2},dot=Math.max(-1,Math.min(1,u.x*v.x+u.y*v.y)),cross=u.x*v.y-u.y*v.x;
 if(Math.abs(cross)<1e-6||dot< -0.995)return null;
 var half=Math.acos(dot)/2,tan=Math.tan(half);if(!(tan>1e-6))return null;
 var trim=Math.min(want*tan,l1*0.45,l2*0.45);if(trim<0.01)return null;
 var r=trim/tan,sgn=cross<0?-1:1,p1={x:b.x-u.x*trim,y:b.y-u.y*trim},p2={x:b.x+v.x*trim,y:b.y+v.y*trim};
 var cx=p1.x-u.y*sgn*r,cy=p1.y+u.x*sgn*r,a1=Math.atan2(p1.y-cy,p1.x-cx),a2=Math.atan2(p2.y-cy,p2.x-cx),tau=Math.PI*2,sw=a2-a1;
 if(sgn>0){while(sw<0)sw+=tau;while(sw>tau)sw-=tau;}else{while(sw>0)sw-=tau;while(sw< -tau)sw+=tau;}
 if(Math.abs(sw)>Math.PI+1e-6)return null;
 var tol=0.01,maxStep=r>tol?2*Math.acos(Math.max(-1,1-tol/r)):Math.PI/8;
 var n=Math.max(2,Math.min(128,Math.ceil(Math.abs(sw)/Math.max(maxStep,0.03)))),pts=[p1];
 for(var i=1;i<n;i++){var q=a1+sw*i/n;pts.push({x:cx+r*Math.cos(q),y:cy+r*Math.sin(q)});}pts.push(p2);
 var am=a1+sw/2,pm={x:cx+r*Math.cos(am),y:cy+r*Math.sin(am)};
 return {points:pts,radius:r,p1:p1,pm:pm,p2:p2,cx:cx,cy:cy,sweep:sw,a1:a1};}
function arcRoundedPolyline(points,want){var out=[],bends=0,minR=1e18;
 function push(p){var q=out.length?out[out.length-1]:null;if(!q||Math.hypot(q.x-p.x,q.y-p.y)>1e-7)out.push({x:p.x,y:p.y});}
 if(!points.length)return {points:out,bends:0,minRadius:0};push(points[0]);
 for(var i=1;i+1<points.length;i++){var f=arcCorner(points[i-1],points[i],points[i+1],want);
  if(!f){push(points[i]);continue;}bends++;minR=Math.min(minR,f.radius);f.points.forEach(push);}
 push(points[points.length-1]);return {points:out,bends:bends,minRadius:bends?minR:0};}
function arcRoundedTracks(points,want,l,w,net){var out=[],bends=0,minR=1e18,cur=points[0];
 function line(a,b){if(Math.hypot(a.x-b.x,a.y-b.y)>1e-7)out.push({x1:a.x,y1:a.y,x2:b.x,y2:b.y,l:l,w:w,net:net,source:"human"});}
 for(var i=1;i+1<points.length;i++){var f=arcCorner(points[i-1],points[i],points[i+1],want);
  if(!f){line(cur,points[i]);cur=points[i];continue;}line(cur,f.p1);
  out.push({x1:f.p1.x,y1:f.p1.y,xm:f.pm.x,ym:f.pm.y,x2:f.p2.x,y2:f.p2.y,l:l,w:w,net:net,source:"human"});
  cur=f.p2;bends++;minR=Math.min(minR,f.radius);}
 line(cur,points[points.length-1]);return {tracks:out,bends:bends,minRadius:bends?minR:0};}
// Exact two-segment fillet used by the Select tool's context menu. Unlike the
// hand-router's multi-corner pass, this command never silently shrinks the
// requested radius: a radius that cannot leave a short straight remnant on
// both selected legs is rejected with the largest value that fits.
function traceFilletContext(t1,t2){var eps=2e-3;
 if(!t1||!t2||t1===t2)return {ok:false,error:"Select two different trace segments."};
 if(t1.xm!=null||t2.xm!=null)return {ok:false,error:"Select two straight segments; an existing arc cannot be filleted again."};
 if((t1.l||0)!==(t2.l||0))return {ok:false,error:"The segments must be on the same copper layer."};
 if((t1.net||"")!==(t2.net||""))return {ok:false,error:"The segments must carry the same net."};
 if(Math.abs((t1.w||.25)-(t2.w||.25))>1e-7)return {ok:false,error:"The segments must have the same width."};
 var e1=[{x:t1.x1,y:t1.y1,e:1},{x:t1.x2,y:t1.y2,e:2}],e2=[{x:t2.x1,y:t2.y1,e:1},{x:t2.x2,y:t2.y2,e:2}],hits=[];
 e1.forEach(function(a){e2.forEach(function(c){if(Math.hypot(a.x-c.x,a.y-c.y)<=eps)hits.push({u:a,v:c});});});
 if(hits.length!==1)return {ok:false,error:hits.length?"The selected segments overlap ambiguously.":"The selected segments must share one endpoint."};
 var h=hits[0],a=h.u.e===1?e1[1]:e1[0],c=h.v.e===1?e2[1]:e2[0],b={x:(h.u.x+h.v.x)/2,y:(h.u.y+h.v.y)/2},
  x1=b.x-a.x,y1=b.y-a.y,x2=c.x-b.x,y2=c.y-b.y,l1=Math.hypot(x1,y1),l2=Math.hypot(x2,y2);
 if(l1<.02||l2<.02)return {ok:false,error:"Both segments must be at least 0.02 mm long."};
 var u={x:x1/l1,y:y1/l1},v={x:x2/l2,y:y2/l2},dot=Math.max(-1,Math.min(1,u.x*v.x+u.y*v.y)),cross=u.x*v.y-u.y*v.x;
 if(Math.abs(cross)<1e-7)return {ok:false,error:dot<0?"A 180° reversal cannot be filleted.":"Collinear segments do not form a corner."};
 var tan=Math.tan(Math.acos(dot)/2),maxRadius=(Math.min(l1,l2)-.01)/tan;
 if(!(tan>1e-8)||!(maxRadius>.001))return {ok:false,error:"This corner is too short to fillet."};
 return {ok:true,t1:t1,t2:t2,a:a,b:b,c:c,u:u,v:v,cross:cross,l1:l1,l2:l2,tan:tan,maxRadius:maxRadius,e1:h.u.e,e2:h.v.e};}
function traceFilletLine(t,end,p){return {x1:end===1?p.x:t.x1,y1:end===1?p.y:t.y1,x2:end===2?p.x:t.x2,y2:end===2?p.y:t.y2,
 l:t.l||0,w:t.w||.25,net:t.net||"",g:t.g,source:t.source,id:trackIdEnsure(t)};}
function traceFilletRadiusLimit(maxRadius){return Math.floor((maxRadius+1e-10)*1000)/1000;}
function traceFilletPlan(t1,t2,radius){var c=traceFilletContext(t1,t2);if(!c.ok)return c;
 radius=+radius;if(!(radius>0))return {ok:false,error:"Enter a radius greater than zero.",maxRadius:c.maxRadius};
 if(radius>c.maxRadius+1e-9)return {ok:false,error:"Radius is too large; maximum is "+traceFilletRadiusLimit(c.maxRadius).toFixed(3)+" mm.",maxRadius:c.maxRadius};
 var trim=radius*c.tan,p1={x:c.b.x-c.u.x*trim,y:c.b.y-c.u.y*trim},p2={x:c.b.x+c.v.x*trim,y:c.b.y+c.v.y*trim},sgn=c.cross<0?-1:1,
  cx=p1.x-c.u.y*sgn*radius,cy=p1.y+c.u.x*sgn*radius,a1=Math.atan2(p1.y-cy,p1.x-cx),a2=Math.atan2(p2.y-cy,p2.x-cx),tau=Math.PI*2,sw=a2-a1;
 if(sgn>0){while(sw<0)sw+=tau;while(sw>tau)sw-=tau;}else{while(sw>0)sw-=tau;while(sw< -tau)sw+=tau;}
 var am=a1+sw/2,arc={x1:p1.x,y1:p1.y,xm:cx+radius*Math.cos(am),ym:cy+radius*Math.sin(am),x2:p2.x,y2:p2.y,
  l:t1.l||0,w:t1.w||.25,net:t1.net||"",g:t1.g&&t1.g===t2.g?t1.g:undefined,source:"human"};
 return {ok:true,radius:radius,maxRadius:c.maxRadius,first:traceFilletLine(t1,c.e1,p1),arc:arc,second:traceFilletLine(t2,c.e2,p2)};}
window.PCBTraceFilletPlan=traceFilletPlan;
// Automatic land tapers for completed hand routes. Two policies share this
// lowering seam:
//  · an authored pad neck stays at pad_neck_width for max_length, then grows
//    over taper_length (the ordinary autorouter pad_neck pass);
//  · a single-ended controlled-impedance RF route starts at the ACTUAL SMD
//    land width, holds through half the land length, then reaches nominal over
//    1.2 trace widths (the G2 RF port finisher's exact width profile).
// The completed route keeps its compact centreline as edit handles and stores
// one swept custom-copper polygon as the physical width authority. DRC lowers
// that path privately when it needs capsule probes; the object list never
// fills with 25 um trace fragments.
function drawEndpointPad(net,l,x,y){var hit=null,key=net||"";
 P.some(function(p,i){return (p.pads||[]).some(function(pd){if(pd.thru||!pd.net||pd.net!==key)return false;
   var pl=p.side==="bottom"?1:0,c=wpt(i,pd.x,pd.y);if(pl!==l||Math.hypot(c.x-x,c.y-y)>1e-7)return false;
   hit={i:i,pd:pd,l:pl};return true;});});return hit;}
function drawRfTaperAllowed(net){var key=net||"",pads=[];
 if((PCB.vias||[]).some(function(v){return (v.net||"")===key;}))return false;
 P.forEach(function(p){(p.pads||[]).forEach(function(pd){if(pd.net===key)pads.push({thru:!!pd.thru,l:p.side==="bottom"?1:0});});});
 return pads.length===2&&(pads[0].thru||pads[1].thru||pads[0].l===pads[1].l);}
function drawPadLaunch(pad,dir){if(!pad||!pad.pd||!dir)return null;
 var dl=Math.hypot(dir.x,dir.y);if(dl<1e-10)return null;dir={x:dir.x/dl,y:dir.y/dl};
 var pd=pad.pd,a=(+pd.rot||0)*Math.PI/180,c=wpt(pad.i,pd.x,pd.y),
  q=wpt(pad.i,pd.x+Math.cos(a),pd.y+Math.sin(a)),ux=q.x-c.x,uy=q.y-c.y,ul=Math.hypot(ux,uy)||1;
 ux/=ul;uy/=ul;var vx=-uy,vy=ux,hw=(+pd.w||0)/2,hh=(+pd.h||0)/2;
 function half(dx,dy){var lx=dx*ux+dy*uy,ly=dx*vx+dy*vy,e=1/0;
  if(Math.abs(lx)>1e-10)e=Math.min(e,hw/Math.abs(lx));if(Math.abs(ly)>1e-10)e=Math.min(e,hh/Math.abs(ly));
  return isFinite(e)?e:0;}
 return {land:half(dir.x,dir.y),span:2*half(-dir.y,dir.x)};}
window.PCBDrawPadLaunch=drawPadLaunch;
function drawTaperProfile(net,pad,nominal,rfAllowed,dir){if(!pad||!pad.pd)return null;
 var c=netClassInfo(net||"");if(!c)return null;
 var classW=+c.width||+((PCB.rules||{}).track_width)||baseTrackW();
 if(!(classW>0)||Math.abs(nominal-classW)>1e-7)return null;
 var launch=drawPadLaunch(pad,dir),span=launch?launch.span:Math.min(+pad.pd.w||0,+pad.pd.h||0);
 var neck=+c.pad_neck_width||0;
 if(neck>0){neck=Math.max(neck,+((PCB.rules||{}).min_width)||0);
  if(neck>=nominal-1e-9||span>=nominal-1e-9)return null;
  return {kind:"neck",width:neck,land:(+c.pad_neck_max_length||.75),taper:(+c.pad_neck_taper_length||.35),step:.025};}
 if(!rfAllowed||!(+c.max_freq_hz>0)||!(+c.impedance_ohms>0)||(+c.diff_impedance_ohms>0))return null;
 if(!(span>0)||span>=nominal-1e-9)return null;
 return {kind:"rf",width:span,land:launch?launch.land:Math.max(+pad.pd.w||0,+pad.pd.h||0)/2,
  taper:nominal*1.2,step:nominal*1.2/6};}
function drawTrackPoint(t,f){var g=trackArcGeom(t);if(g){var a=g.a1+g.sweep*f;return {x:g.cx+g.r*Math.cos(a),y:g.cy+g.r*Math.sin(a)};}
 return {x:t.x1+(t.x2-t.x1)*f,y:t.y1+(t.y2-t.y1)*f};}
function drawTrackEndDirection(t,start){var a=drawTrackPoint(t,start?0:1),b=drawTrackPoint(t,start ? .001 : .999);
 return {x:b.x-a.x,y:b.y-a.y};}
function drawTrackPiece(t,f0,f1,w){var a=drawTrackPoint(t,f0),b=drawTrackPoint(t,f1),q={x1:a.x,y1:a.y,x2:b.x,y2:b.y,l:t.l||0,w:w,net:t.net||"",source:"human",id:trackIdNew()};
 if(t.xm!=null&&t.ym!=null){var m=drawTrackPoint(t,(f0+f1)/2);q.xm=m.x;q.ym=m.y;}return q;}
function drawProfileWidth(s,total,start,end,nominal){
 function local(d,p){if(!p)return nominal;if(d<=p.land)return p.width;if(d>=p.land+p.taper)return nominal;
  return p.width+(nominal-p.width)*(d-p.land)/p.taper;}
 var sa=!!start&&s<start.land+start.taper,ea=!!end&&total-s<end.land+end.taper;
 if(sa&&ea)return Math.min(local(s,start),local(total-s,end));
 if(sa)return local(s,start);if(ea)return local(total-s,end);return nominal;}
// Pure centreline lowering: split at every profile sample and use the wider
// endpoint for each constant-width piece (a conservative outer approximation
// of the linear taper). `tracks` must be in gesture order.
function drawTaperTracks(tracks,start,end,nominal){if(!tracks.length||(!start&&!end))return tracks.slice();
 var lens=tracks.map(trackLength),total=lens.reduce(function(a,b){return a+b;},0),targets=[0,total];
 function cuts(p,rev){if(!p)return;var d=0;targets.push(rev?total-p.land:p.land);
  for(d=p.land+p.step;d<p.land+p.taper-1e-9;d+=p.step)targets.push(rev?total-d:d);
  targets.push(rev?total-p.land-p.taper:p.land+p.taper);}
 cuts(start,false);cuts(end,true);targets=targets.filter(function(s){return s>1e-9&&s<total-1e-9;});
 targets.push(0,total);targets.sort(function(a,b){return a-b;});
 var unique=[];targets.forEach(function(s){if(!unique.length||Math.abs(s-unique[unique.length-1])>1e-8)unique.push(s);});
 var out=[],base=0,ci=1;
 tracks.forEach(function(t,ti){var len=lens[ti],stop=base+len,loc=[base];
  while(ci<unique.length&&unique[ci]<stop-1e-8){if(unique[ci]>base+1e-8)loc.push(unique[ci]);ci++;}loc.push(stop);
  for(var j=1;j<loc.length;j++){var s0=loc[j-1],s1=loc[j],w=Math.max(drawProfileWidth(s0,total,start,end,nominal),drawProfileWidth(s1,total,start,end,nominal));
   out.push(drawTrackPiece(t,len>1e-12?(s0-base)/len:0,len>1e-12?(s1-base)/len:1,w));}base=stop;
  while(ci<unique.length&&unique[ci]<=base+1e-8)ci++;});return out;}
window.PCBDrawTaperTracks=drawTaperTracks;
function drawTaperPath(tracks,start,end,nominal){if(!tracks.length||(!start&&!end))return null;
 var lens=tracks.map(trackLength),total=lens.reduce(function(a,b){return a+b;},0),targets=[0,total],base=0;
 function cuts(p,rev){if(!p)return;targets.push(rev?total-p.land:p.land);
  for(var d=p.land+p.step;d<p.land+p.taper-1e-9;d+=p.step)targets.push(rev?total-d:d);
  targets.push(rev?total-p.land-p.taper:p.land+p.taper);}
 cuts(start,false);cuts(end,true);
 tracks.forEach(function(t,i){var len=lens[i];targets.push(base,base+len);var chords=trackChords(t);
  if(chords.length>1)for(var j=1;j<chords.length;j++)targets.push(base+len*j/chords.length);base+=len;});
 targets=targets.filter(function(s){return s>=-1e-9&&s<=total+1e-9;}).map(function(s){return Math.max(0,Math.min(total,s));});
 targets.sort(function(a,b){return a-b;});var unique=[];
 targets.forEach(function(s){if(!unique.length||Math.abs(s-unique[unique.length-1])>1e-8)unique.push(s);});
 var samples=[],ti=0,begin=0;
 unique.forEach(function(s){while(ti+1<tracks.length&&s>begin+lens[ti]-1e-8){begin+=lens[ti];ti++;}
  var len=lens[ti],f=len>1e-12?(s-begin)/len:0,p=drawTrackPoint(tracks[ti],Math.max(0,Math.min(1,f)));
  samples.push([p.x,p.y,drawProfileWidth(s,total,start,end,nominal)]);});
 return {net:tracks[0].net||"",l:tracks[0].l||0,
  track_ids:tracks.map(trackIdEnsure),samples:samples};}
function drawApplyAutomaticTapers(){if(!dtrace||dtrace.pair||!dtrace.laid||!dtrace.laid.length)return {ok:true,changed:false};
 var old=dtrace.laid.slice(),nominal=dtrace.w,rfAllowed=drawRfTaperAllowed(dtrace.net);
 var sp=dtrace.startPad,ep=drawEndpointPad(dtrace.net,dtrace.l,dtrace.lx,dtrace.ly),
  sr=drawTaperProfile(dtrace.net,sp,nominal,rfAllowed,drawTrackEndDirection(old[0],true)),
  er=drawTaperProfile(dtrace.net,ep,nominal,rfAllowed,drawTrackEndDirection(old[old.length-1],false));
 if(!sr&&!er)return {ok:true,changed:false};var shaped;
 // Authored pad_neck shapes only the pad-ended segment. RF port tapering is a
 // path-length profile and may continue over several short gesture pieces.
 if((sr&&sr.kind==="neck")||(er&&er.kind==="neck")){
  if(old.length===1)shaped=drawTaperTracks(old,sr,er,nominal);
  else{shaped=old.slice();if(sr)shaped.splice.apply(shaped,[0,1].concat(drawTaperTracks([old[0]],sr,null,nominal)));
   if(er){var last=shaped.length-1,tail=drawTaperTracks([shaped[last]],null,er,nominal);shaped.splice.apply(shaped,[last,1].concat(tail));}}
 }else shaped=drawTaperTracks(old,sr,er,nominal);
 var board=PCB.tracks||[],after=board.filter(function(t){return old.indexOf(t)<0;}).concat(shaped),base=dtrace.undo||{};
 if(drcGateDiffBlocks(base.tracks||[],base.vias||[],after,PCB.vias||[])){
  routeStatMsg("automatic pad taper would violate DRC — adjust the launch before finishing",true);return {ok:false,changed:false};}
 var paths=[];
 if((sr&&sr.kind==="neck")||(er&&er.kind==="neck")){
  if(old.length===1){var both=drawTaperPath(old,sr,er,nominal);if(both)paths.push(both);}
  else{if(sr){var head=drawTaperPath([old[0]],sr,null,nominal);if(head)paths.push(head);}
   if(er){var tail=drawTaperPath([old[old.length-1]],null,er,nominal);if(tail)paths.push(tail);}}
 }else{var whole=drawTaperPath(old,sr,er,nominal);if(whole)paths.push(whole);}
 if(!paths.length)return {ok:true,changed:false};PCB.rf_paths=PCB.rf_paths||[];
 Array.prototype.push.apply(PCB.rf_paths,paths);cuGeomDrop();gpuCuEdit();return {ok:true,changed:true};}
// Exact candidate copper for the current click. Including the last committed
// segment lets the next click round the corner at the current route head; the
// old segment is atomically replaced on commit. Internal posture corners are
// rounded in the same pass.
function drawRoutePlan(legs){var straight=legsToTracks(dtrace.lx,dtrace.ly,legs,dtrace.l,dtrace.w,dtrace.net);
 if(!drawArcOn()||dtrace.pair)return {tracks:straight,remove:null,end:legs[legs.length-1],bends:0,minRadius:0};
 var prev=dtrace.laid&&dtrace.laid.length?dtrace.laid[dtrace.laid.length-1]:null,pts=[],remove=null;
 if(prev&&prev.xm==null&&prev.net===dtrace.net&&prev.l===dtrace.l&&Math.hypot(prev.x2-dtrace.lx,prev.y2-dtrace.ly)<1e-7){
  pts.push({x:prev.x1,y:prev.y1});remove=prev;}pts.push({x:dtrace.lx,y:dtrace.ly});
 legs.forEach(function(q){var p=pts[pts.length-1];if(Math.hypot(q.x-p.x,q.y-p.y)>1e-7)pts.push({x:q.x,y:q.y});});
 var rounded=arcRoundedTracks(pts,drawArcRadius(),dtrace.l,dtrace.w,dtrace.net);if(!rounded.bends)return {tracks:straight,remove:null,end:legs[legs.length-1],bends:0,minRadius:0};
 return {tracks:rounded.tracks,remove:remove,end:legs[legs.length-1],bends:rounded.bends,minRadius:rounded.minRadius};}
// ── Obstacle pushback while drawing ─────────────────────────────────────
// KiCad-style: the route head never advances into a clearance violation.
// When the posture legs collide, the OTHER posture is tried first (the
// router's auto-posture dodge); if both collide the chain is clipped at the
// last legal grid point toward the cursor, so the head visibly sticks at the
// obstacle instead of laying violating copper.
// Session-exact clip: ONE drc_clip_seg per leg (vs. the JS binary search of
// probes below). Walks legs from the head; a leg that clips short ends the chain
// at the last whole grid step under the clip fraction (keeps the head on-grid).
// null ⇒ no session → the JS binary search runs unchanged.
function clipLegsSession(legs){
 if(!drcGate.sLoaded||!dtrace)return null;
 var g=snapG(),out=[],fx=dtrace.lx,fy=dtrace.ly;
 for(var i=0;i<legs.length;i++){var bx=legs[i].x,by=legs[i].y;
  var t=drcSessClipSeg(fx,fy,bx,by,dtrace.l,dtrace.net,dtrace.w/2);
  if(t===null)return null;                                     // session dropped → JS fallback
  if(t>=1){out.push({x:bx,y:by});fx=bx;fy=by;continue;}        // leg fully clean
  var L=Math.hypot(bx-fx,by-fy);
  var diag=Math.abs(Math.abs(bx-fx)-Math.abs(by-fy))<1e-9&&Math.abs(bx-fx)>1e-9;
  var step=diag?g*Math.SQRT2:g,k=Math.floor(L*t/step+1e-9);    // whole grid steps under the clip
  if(k>=1){var f=k*step/L;out.push({x:fx+(bx-fx)*f,y:fy+(by-fy)*f});}
  return out;}                                                 // clipped here — rest is blocked
 return out;}
function clipLegs(legs){
 var sc=clipLegsSession(legs);if(sc!==null)return sc;
 var pts=[{x:dtrace.lx,y:dtrace.ly}],g=snapG(),cand=[],i,k;
 legs.forEach(function(q){pts.push({x:q.x,y:q.y});});
 for(i=1;i<pts.length;i++){var a=pts[i-1],b=pts[i];
  var L=Math.hypot(b.x-a.x,b.y-a.y);if(L<1e-9)continue;
  var diag=Math.abs(Math.abs(b.x-a.x)-Math.abs(b.y-a.y))<1e-9&&Math.abs(b.x-a.x)>1e-9;
  var q1=diag?g*Math.SQRT2:g,n=Math.max(1,Math.floor(L/q1+1e-9));
  for(k=1;k<n;k++)cand.push({i:i,x:a.x+(b.x-a.x)*(k*q1/L),y:a.y+(b.y-a.y)*(k*q1/L)});
  cand.push({i:i,x:b.x,y:b.y});}
 if(!cand.length)return [];
 function legsAt(ci){var c=cand[ci],out=[];
  for(var j=1;j<c.i;j++)out.push(pts[j]);
  out.push({x:c.x,y:c.y});return out;}
 // Prefix legality is monotone (a violating sub-segment stays inside every
 // longer prefix), so binary-search the longest legal candidate.
 var lo=-1,hi=cand.length-1;
 if(!drawLegsViolate(legsAt(hi)))return legsAt(hi);
 while(hi-lo>1){var mid2=(lo+hi)>>1;
  if(drawLegsViolate(legsAt(mid2)))hi=mid2;else lo=mid2;}
 return lo<0?[]:legsAt(lo);}
// Target point + the leg chain that reaches it. Shift = free angle: one
// direct grid-snapped segment, no posture legs.
function drawLegs(m,shift){var t=drawTarget(m,shift);
 if(!dtrace)return {t:t,legs:[t]};
 var legs=shift?[t]:drawPath(dtrace.lx,dtrace.ly,t);
 if(!drawLegsViolate(legs))return {t:t,legs:legs};
 if(!shift){var alt=drawPath(dtrace.lx,dtrace.ly,t,drawPosture^1);
  if(!drawLegsViolate(alt))return {t:t,legs:alt,dodged:true};}
 return {t:t,legs:clipLegs(legs),clipped:true};}
// Route-pad selection is deliberately independent of courtyard selection.
// Overlapping footprints may put a top and bottom SMD pad under the same
// cursor; partAt() knows only courtyard size, so using its winner here could
// make an F.Cu trace inspect the B.Cu pad and report a false wrong-net/invalid
// connection. A route START is strict too: with B.Cu active, clicking through
// a top-only exposed pad must reach B.Cu copper beneath it instead of silently
// starting a top trace. Rank compatible hits by trace net, then physical area.
// Through pads span all layers.
function drawPadLayer(p,pd){return (pd.thru||pd.drill>0)?-1:(p.side==="bottom"?1:0);}
function drawPadHitsAt(wx,wy){var out=[];
 P.forEach(function(p,i){var pd=padAt(i,wx,wy);if(!pd)return;
  var b=wrect(i,pd);out.push({i:i,pd:pd,area:Math.max((b.x1-b.x0)*(b.y1-b.y0),1e-12)});});
 return out;}
function drawPadPick(hits,layer,nets,strictLayer){var best=null,bt=1e9,ba=1e18;
 hits.forEach(function(h){var pl=drawPadLayer(P[h.i],h.pd),compatible=(pl<0||pl===layer);
  if(strictLayer&&!compatible)return;
  var preferred=false;if(nets&&nets.length)for(var k=0;k<nets.length;k++)if(h.pd.net===nets[k]){preferred=true;break;}
  var tier=(compatible?0:2)+((nets&&nets.length&&!preferred)?1:0);
  if(tier<bt||(tier===bt&&h.area<ba)){best=h;bt=tier;ba=h.area;}});
 return best;}
function padTarget(m){var layer=dtrace?dtrace.l:activeLayer,nets=dtrace?[dtrace.net]:[];
 if(dtrace&&dtrace.pair)nets.push(dtrace.pair.net);
 var h=drawPadPick(drawPadHitsAt(m.x,m.y),layer,nets,true);if(!h)return null;
 var p=P[h.i],pd=h.pd,c=wpt(h.i,pd.x,pd.y),pl=drawPadLayer(p,pd);
 return {i:h.i,pd:pd,x:c.x,y:c.y,net:pd.net||"",l:pl<0?layer:pl};}
function segDist(px,py,t){var best=1e18;trackChords(t).forEach(function(s){var dx=s.x2-s.x1,dy=s.y2-s.y1,L2=dx*dx+dy*dy;
 var u=L2>0?((px-s.x1)*dx+(py-s.y1)*dy)/L2:0;u=Math.max(0,Math.min(1,u));
 best=Math.min(best,Math.hypot(px-(s.x1+u*dx),py-(s.y1+u*dy)));});return best;}
function drawHitTrack(m,layer){var best=null,bd=1e9;(PCB.tracks||[]).forEach(function(t){
 if(layer!=null&&Number(t.l||0)!==layer)return;
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
// ── Board-edge clearance (mirrors placement/drc.zig checkBoardEdge) ──────
// Copper must stay `edgeClrVal()` inside the outline. The engine's edge rule is
// edgeClearance() = copper_edge (when set) else the design base clearance; copper
// staged further than staging_exempt_mm off-board is skipped. Adding this to the
// JS draw gate makes the route head push back off the board edge, not just past
// foreign copper — closing the leak where a trace could be drawn over the edge.
var DRC_EDGE_STAGE=10.0; // staging_exempt_mm — copper this far off-board is "staging"
function edgeClrVal(){var r=PCB.rules||{};
 return (r.copper_edge>0)?r.copper_edge:((r.clearance>0)?r.clearance:clrVal());}
// The active outline: a live drawn/authored rect (+ optional polygon vertices),
// resolved the same way drc_marshal.js buildDrcInput picks board vs board_poly.
function boardShape(){
 var o=PCB.outline;
 if(boardShapeCache&&boardShapeCache.rev===outlineGeomRev&&boardShapeCache.o===o&&
   boardShapeCache.b===PCB.board&&boardShapeCache.bp===PCB.board_poly)return boardShapeCache.shape;
 var shape=null;
 if(o&&o.w>0&&o.h>0)shape={x:o.x,y:o.y,w:o.w,h:o.h,pts:(o.pts&&o.pts.length>=3)?outlineFilletGeom(o).points:null};
 var b=PCB.board;
 if(!shape&&b&&b.w>0&&b.h>0)shape={x:b.x,y:b.y,w:b.w,h:b.h,pts:(PCB.board_poly&&PCB.board_poly.length>=3)?PCB.board_poly:null};
 boardShapeCache={rev:outlineGeomRev,o:o,b:b,bp:PCB.board_poly,shape:shape};return shape;}
// Even-odd point-in-polygon (mirrors outline.zig contains).
function polyContains(pts,x,y){var inside=false,j=pts.length-1;
 for(var i=0;i<pts.length;i++){var p=pts[i],q=pts[j];
  if((p[1]>y)!==(q[1]>y)){var t=(y-p[1])/(q[1]-p[1]);if(x<p[0]+t*(q[0]-p[0]))inside=!inside;}
  j=i;}
 return inside;}
// Min distance to the polygon boundary (mirrors outline.zig distToEdge).
function polyDistEdge(pts,x,y){var best=1e9,j=pts.length-1;
 for(var i=0;i<pts.length;i++){best=Math.min(best,ptSegDist(x,y,pts[j][0],pts[j][1],pts[i][0],pts[i][1]));j=i;}
 return best;}
// Threshold-only edge query for the generated-silkscreen clearance loops.
// Their answer is boolean, so avoid a sqrt for every edge of a tessellated
// rounded outline.  The expanded edge bbox rejects almost every segment before
// the exact squared point/segment distance is evaluated.
function polyEdgeWithin(pts,x,y,d){if(!(d>0))return false;var d2=d*d,j=pts.length-1;
 for(var i=0;i<pts.length;i++){var a=pts[j],b=pts[i],minx=Math.min(a[0],b[0])-d,maxx=Math.max(a[0],b[0])+d,
   miny=Math.min(a[1],b[1])-d,maxy=Math.max(a[1],b[1])+d;j=i;
  if(x<minx||x>maxx||y<miny||y>maxy)continue;
  var dx=b[0]-a[0],dy=b[1]-a[1],l2=dx*dx+dy*dy,t=l2>0?((x-a[0])*dx+(y-a[1])*dy)/l2:0;
  if(t<0)t=0;else if(t>1)t=1;
  var qx=x-(a[0]+t*dx),qy=y-(a[1]+t*dy);if(qx*qx+qy*qy<d2)return true;}
 return false;}
// Signed inset of (x,y) from the outline (positive = inside); null = no outline.
function boardInsetJS(x,y){var s=boardShape();if(!s)return null;
 if(s.pts)return (polyContains(s.pts,x,y)?1:-1)*polyDistEdge(s.pts,x,y);
 return Math.min(Math.min(x-s.x,s.x+s.w-x),Math.min(y-s.y,s.y+s.h-y));}
// Does copper of half-width `hw` at (x,y) break the board-edge clearance? Staged
// copper (inset < -(hw+stage)) is exempt, exactly like the engine's staging band.
function edgePointViol(x,y,hw){var ins=boardInsetJS(x,y);if(ins==null)return false;
 if(ins< -(hw+DRC_EDGE_STAGE))return false; // staging band
 return (ins-hw)<edgeClrVal()-1e-6;}
// A proposed segment breaches the board edge if either endpoint does (the
// rectangle inset is minimised at an endpoint; clipLegs samples finely enough
// that a concave-polygon mid-cut is caught at the next sample point).
function segEdgeViol(x1,y1,x2,y2,hw){return edgePointViol(x1,y1,hw)||edgePointViol(x2,y2,hw);}
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
 // Engine-exact session probe when live (agrees with the commit gate); the JS
 // bbox approximation below is the fallback. Same-net copper never violates, so
 // the trace's own just-laid legs need no `skip` on this path.
 var sp=drcSessProbeSeg(x1,y1,x2,y2,layer,net,hw);
 if(sp!==null)return sp?{x:midx,y:midy,k:"clearance"}:null;
 var reach=slen/2+hw+clr+1.5; // coarse cull radius
 if(segEdgeViol(x1,y1,x2,y2,hw))return {x:midx,y:midy,k:"board edge"};
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
  var d2=1e18;trackChords(t).forEach(function(s){d2=Math.min(d2,segSegDist(x1,y1,x2,y2,s.x1,s.y1,s.x2,s.y2));});d2-=hw+(t.w||0.25)/2;
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
// A proposed via at (x,y) on `net`: a via is through-only, so it must clear
// foreign copper on EVERY layer. Pads exist only on the two outer faces
// (SMD) or on all layers (thru — padBoxesOn includes those for either face),
// so checking the two faces covers every pad; tracks and vias below are
// checked without a layer filter, which covers inner-layer copper too.
function viaViolation(x,y,net,dia,drill){var clr=netClrFor(net),vr=(dia||0.4)/2;
 var vp=drcSessProbeVia(x,y,net,dia,drill); // engine-exact when live (adds hole/annular the JS gate can't)
 if(vp!==null)return vp?{x:x,y:y,k:"clearance"}:null;
 if(edgePointViol(x,y,vr))return {x:x,y:y,k:"board edge"};
 for(var L=0;L<2;L++){var pads=padBoxesOn(L);
  for(var i=0;i<pads.length;i++){var pb=pads[i];if(sameNet(pb.net,net))continue;
   var d=Math.hypot(Math.max(pb.x0-x,0,x-pb.x1),Math.max(pb.y0-y,0,y-pb.y1))-vr;
   if(d<clr-1e-6)return {x:x,y:y,k:"via↔pad"};}}
 var ts=PCB.tracks||[];
 for(var j=0;j<ts.length;j++){var t=ts[j];if(sameNet(t.net,net))continue;
  var d2=segDist(x,y,t)-vr-(t.w||0.25)/2;
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
 var wr=pxr*(vb.w/Math.max(svgMetricsGet().cw,1))/S; // convert px→world mm at current zoom
 var best=null,bd=wr;
 // exact point snaps — land the endpoint ON copper (current-layer pad centres,
 // any net; same-net track endpoints). These win right on a target.
 P.forEach(function(p,i){(p.pads||[]).forEach(function(pd){if(dtrace&&drawPadLayer(p,pd)>=0&&drawPadLayer(p,pd)!==dtrace.l)return;var c=wpt(i,pd.x,pd.y);
  var d=Math.hypot(c.x-m.x,c.y-m.y);if(d<bd){bd=d;best={x:c.x,y:c.y,mag:true};}});});
 (PCB.tracks||[]).forEach(function(t){if(net&&t.net&&t.net!==net)return;
  [[t.x1,t.y1],[t.x2,t.y2]].forEach(function(e){var d=Math.hypot(e[0]-m.x,e[1]-m.y);
   if(d<bd){bd=d;best={x:e[0],y:e[1],mag:true};}});});
 if(best)return best;
 // Centre-line snap: while routing roughly along an axis toward a same-net pad
 // AHEAD, lock the cross-axis onto that pad's centre so the WHOLE approach sits
 // on its centreline (KiCad behaviour) — not just the last point pulled in. The
 // along-axis stays on the cursor's grid so you slide freely down the line.
 if(dtrace){
  var dx=m.x-dtrace.lx,dy=m.y-dtrace.ly,adx=Math.abs(dx),ady=Math.abs(dy);
  if(adx>1e-4||ady>1e-4){
   var horiz=adx>=ady,sx=dx<0?-1:1,sy=dy<0?-1:1;
   var corr=wr*2.0,dg=snapG(),cb=corr,cbest=null;
   P.forEach(function(p,i){(p.pads||[]).forEach(function(pd){
    if(drawPadLayer(p,pd)>=0&&drawPadLayer(p,pd)!==dtrace.l)return;
    if(!pd.net||!net||netCollapse(pd.net)!==netCollapse(net))return;
    var c=wpt(i,pd.x,pd.y);
    if(horiz){if((c.x-dtrace.lx)*sx<=0)return;var d=Math.abs(m.y-c.y);
     if(d<cb){cb=d;cbest={x:Math.round(m.x/dg)*dg,y:c.y,mag:true};}}
    else{if((c.y-dtrace.ly)*sy<=0)return;var d=Math.abs(m.x-c.x);
     if(d<cb){cb=d;cbest={x:c.x,y:Math.round(m.y/dg)*dg,mag:true};}}});});
   if(cbest)return cbest;
  }
 }
 return null;}
function drawSeg(x2,y2){if(Math.abs(x2-dtrace.lx)<1e-9&&Math.abs(y2-dtrace.ly)<1e-9)return;
 rfDropNet(dtrace.net);
 PCB.tracks=PCB.tracks||[];
 var seg={x1:dtrace.lx,y1:dtrace.ly,x2:x2,y2:y2,l:dtrace.l,w:dtrace.w,net:dtrace.net,source:"human"};
 PCB.tracks.push(seg);(dtrace.laid=dtrace.laid||[]).push(seg);
 dtrace.lx=x2;dtrace.ly=y2;dtrace.n++;}
// Commit one single-ended routing click as a unit. Rounded plans may replace
// the last segment with its trimmed tail + arc chords; the step record makes
// Backspace restore that exact segment and head instead of peeling one chord.
function drawCommitPlan(plan){if(!plan||!plan.tracks.length)return false;
 var board=PCB.tracks=PCB.tracks||[],oldLaid=dtrace.laid.slice(),ri=-1;
 var st={kind:"single",hx:dtrace.lx,hy:dtrace.ly,n:dtrace.n,laid:oldLaid,remove:plan.remove,removeIndex:-1,added:plan.tracks.slice()};
 if(plan.remove){ri=board.lastIndexOf(plan.remove);if(ri>=0){st.removeIndex=ri;board.splice(ri,1);}
  var li=dtrace.laid.lastIndexOf(plan.remove);if(li>=0)dtrace.laid.splice(li,1);}
 plan.tracks.forEach(function(t){board.push(t);dtrace.laid.push(t);});
 gpuCuEdit(); // committed copper mid-trace: the baked instances gained/lost a track
 dtrace.lx=plan.end.x;dtrace.ly=plan.end.y;dtrace.n=dtrace.laid.length;dtrace.steps.push(st);
 if(plan.bends){var want=drawArcRadius(),shrunk=plan.minRadius+1e-6<want;
  routeStatMsg((shrunk?"fit-limited arc · R":"tangent arc · R")+plan.minRadius.toFixed(3)+" mm");}
 return true;}
function drawEnd(){var tapered={ok:true,changed:false};if(dtrace&&dtrace.n>0){tapered=drawApplyAutomaticTapers();if(!tapered.ok)return false;
  recordUndo(dtrace.undo);scheduleDrc();}
 dtrace=null;drawBtnSync();ovPaintSoon();routeStatMsg(tapered.changed?"automatic pad tapers added":null);return true;}
// Destination pads for a trace started on pad (pi,pd): the far end of every
// still-unrouted airwire touching that pad — where this trace is *supposed*
// to land. paintDraw pulses them amber (the click-highlight treatment), and
// the whole net lights up hoverNet-style while the trace is live.
function drawDests(pi,pd){var out=[];
 if(pi==null||!pd)return out;
 if(linksDirty)linksRecompute();
 (PCB.links||[]).forEach(function(l){if(l.done)return;
  var oi=-1,ox=0,oy=0;
  if(l.a===pi&&Math.abs(l.ax-pd.x)<1e-6&&Math.abs(l.ay-pd.y)<1e-6){oi=l.b;ox=l.bx;oy=l.by;}
  else if(l.b===pi&&Math.abs(l.bx-pd.x)<1e-6&&Math.abs(l.by-pd.y)<1e-6){oi=l.a;ox=l.ax;oy=l.ay;}
  if(oi<0||!P[oi])return;
  var opd=null;
  (P[oi].pads||[]).forEach(function(q){if(Math.abs(q.x-ox)<1e-6&&Math.abs(q.y-oy)<1e-6)opd=q;});
  out.push({i:oi,pd:opd,x:ox,y:oy});});
 return out;}
// ── Coupled differential-pair drawing ───────────────────────────────────
// Starting a trace on a pad whose net belongs to a `(net-class … (diff-pair))`
// pair auto-couples the ✎ Draw tool (P uncouples): every click lays BOTH legs,
// the partner track offset perpendicular by (track width + pair gap) with
// mitered corners (the miter point sits on both legs' offset lines, so the
// coupled spacing holds through every bend). V drops a via pair — spread along
// the pair normal when two barrels + clearance don't fit the coupling gap —
// and finishing on either far pad fans each leg into its own pad. Commits are
// all-or-nothing: the drcGateBlocks commit gate sees BOTH candidate track sets
// in one call, so a click never lands only half a pair.
function dpPartnerPad(px,py,net,onlyPart){var key=netCollapse(net||""),best=null,bd=1e18;
 P.forEach(function(p,i){if(onlyPart!=null&&i!==onlyPart)return;
  (p.pads||[]).forEach(function(pd){if(!pd.net||netCollapse(pd.net)!==key)return;
   var c=wpt(i,pd.x,pd.y),d=Math.hypot(c.x-px,c.y-py);
   if(d<bd){bd=d;best={i:i,pd:pd,x:c.x,y:c.y,net:pd.net};}});});
 return best;}
// Mitered offset of corner c between unit leg directions d1→d2 on side s: the
// intersection of the two offset lines — exact coupled spacing through the
// bend. A near-reversal (den→0) falls back to the plain endpoint offset.
function dpMiter(c,d1,d2,off,s){
 var n1x=-d1.y*s,n1y=d1.x*s,n2x=-d2.y*s,n2y=d2.x*s,den=1+n1x*n2x+n1y*n2y;
 if(den<0.3)return {x:c.x+n2x*off,y:c.y+n2y*off};
 return {x:c.x+(n1x+n2x)*off/den,y:c.y+(n1y+n2y)*off/den};}
// Which side of the first leg the partner head sits on. Locked into pair.s at
// the first commit so the offset side never flips mid-trace.
function dpSide(legs){var pr=dtrace.pair;if(pr.s)return pr.s;
 var q=legs&&legs.length?legs[0]:null;if(!q)return 1;
 var dx=q.x-dtrace.lx,dy=q.y-dtrace.ly,L=Math.hypot(dx,dy);if(L<1e-9)return 1;
 return ((-dy*(pr.lx-dtrace.lx)+dx*(pr.ly-dtrace.ly))<0)?-1:1;}
// The partner leg chain for new P legs from the current heads: one mitered
// vertex per P corner and a perpendicular offset at the head; fanEnd (a pad
// centre) replaces the final vertex so the last leg fans out of the coupled
// run into its own pad. The junction miter with the last committed leg sits on
// that leg's offset line, so an OUTSIDE corner splices with a collinear
// extension; an INSIDE corner (turning toward the partner) instead returns
// `trim` — the last partner seg must be SHORTENED back to the miter, or its
// overhanging stub would jut inside the new leg's clearance (touching it at 90°).
function dpChainFor(legs,fanEnd){var pr=dtrace.pair,off=dtrace.w+pr.gap,s=pr.s||dpSide(legs);
 var res={legs:[],trim:null};
 var pts=[{x:dtrace.lx,y:dtrace.ly}];
 legs.forEach(function(q){var lp=pts[pts.length-1];
  if(Math.hypot(q.x-lp.x,q.y-lp.y)>1e-9)pts.push({x:q.x,y:q.y});});
 if(pts.length<2)return res;
 var dirs=[],i;
 for(i=1;i<pts.length;i++){var dx=pts[i].x-pts[i-1].x,dy=pts[i].y-pts[i-1].y,L=Math.hypot(dx,dy);
  dirs.push({x:dx/L,y:dy/L});}
 if(dtrace.pdir){var jm=dpMiter(pts[0],dtrace.pdir,dirs[0],off,s);
  var jx=jm.x-pr.lx,jy=jm.y-pr.ly;
  if(Math.hypot(jx,jy)>1e-9){
   if(jx*dtrace.pdir.x+jy*dtrace.pdir.y<-1e-9)res.trim=dpTrimTo(jm);
   if(!res.trim)res.legs.push(jm);}}
 for(i=1;i<pts.length;i++){
  res.legs.push(i<pts.length-1?dpMiter(pts[i],dirs[i-1],dirs[i],off,s)
   :{x:pts[i].x-dirs[i-1].y*off*s,y:pts[i].y+dirs[i-1].x*off*s});}
 if(fanEnd&&res.legs.length)res.legs[res.legs.length-1]={x:fanEnd.x,y:fanEnd.y};
 return res;}
// Validate an inside-corner trim target: it must land ON the last partner seg
// (collinear, between its endpoints) — after every normal commit that seg is
// parallel to the last P leg so the miter sits on its line; odd states (a
// fan-in only, a via jog) fail the test and the miter is kept as a backtrack
// leg instead (the gate then has the final word).
function dpTrimTo(jm){var pr=dtrace.pair,sg=pr.laid.length?pr.laid[pr.laid.length-1]:null;
 if(!sg)return null;
 var dx=sg.x2-sg.x1,dy=sg.y2-sg.y1,L=Math.hypot(dx,dy);
 if(L<1e-9)return null;
 if(Math.abs((jm.x-sg.x1)*dy-(jm.y-sg.y1)*dx)/L>1e-6)return null;   // off the seg's line
 var t=((jm.x-sg.x1)*dx+(jm.y-sg.y1)*dy)/(L*L);
 if(t<1e-6||t>1+1e-6)return null;                                   // outside the seg
 return {x:jm.x,y:jm.y,seg:sg};}
// Would the partner chain breach clearance? Mirrors drawLegsViolate with the
// partner head/net; BOTH traces' just-laid copper is skipped on the JS path
// (the session probe needs no skip — the gesture's copper isn't in the session
// until the end-of-trace reload). The twin legs themselves stay checked against
// each other only by the commit gate, where they appear together.
function dpLegsViolate(nl){var pr=dtrace.pair;if(!pr)return false;
 var fx=nl.trim?nl.trim.x:pr.lx,fy=nl.trim?nl.trim.y:pr.ly;
 var skip=(dtrace.laid||[]).concat(pr.laid||[]);
 for(var i=0;i<nl.legs.length;i++){
  if(segViolation(fx,fy,nl.legs[i].x,nl.legs[i].y,dtrace.l,pr.net,dtrace.w/2,skip))return true;
  fx=nl.legs[i].x;fy=nl.legs[i].y;}
 return false;}
// Pair-mode leg resolution: both postures are tried against BOTH legs; there
// is no clearance clip in pair mode (a half-clipped pair would decouple), so a
// fully blocked click is refused whole — base geometry kept for the red preview.
function dpLegs(m,shift){var t=drawTarget(m,shift);
 var cands=shift?[[{x:t.x,y:t.y}]]:[drawPath(dtrace.lx,dtrace.ly,t),drawPath(dtrace.lx,dtrace.ly,t,drawPosture^1)];
 for(var i=0;i<cands.length;i++){
  if(drawLegsViolate(cands[i]))continue;
  var nl=dpChainFor(cands[i],null);
  if(dpLegsViolate(nl))continue;
  return {t:t,legs:cands[i],nl:nl,dodged:i>0};}
 return {t:t,legs:cands[0],nl:dpChainFor(cands[0],null),blocked:true};}
// Lay the partner chain as copper — the twin of drawSeg's P legs.
function dpLay(nlegs){var pr=dtrace.pair;PCB.tracks=PCB.tracks||[];
 rfDropNet(pr.net);
 nlegs.forEach(function(q){if(Math.hypot(q.x-pr.lx,q.y-pr.ly)<1e-9)return;
  var seg={x1:pr.lx,y1:pr.ly,x2:q.x,y2:q.y,l:dtrace.l,w:dtrace.w,net:pr.net,source:"human"};
  PCB.tracks.push(seg);pr.laid.push(seg);pr.lx=q.x;pr.ly=q.y;});}
// Commit one coupled click: ONE engine-gate call over the union of both
// candidate track sets (all-or-nothing) via drcGateDiffBlocks — the `after`
// board carries an inside-corner trim of the last partner seg, so the gate
// judges exactly the copper the commit will leave. Then both legs lay and the
// step is recorded so Backspace can unwind the click as a unit.
function dpCommit(legs,nl){var pr=dtrace.pair;
 var candP=legsToTracks(dtrace.lx,dtrace.ly,legs,dtrace.l,dtrace.w,dtrace.net);
 var candN=legsToTracks(nl.trim?nl.trim.x:pr.lx,nl.trim?nl.trim.y:pr.ly,nl.legs,dtrace.l,dtrace.w,pr.net);
 var bt=PCB.tracks||[],bv=PCB.vias||[],after=bt.slice();
 if(nl.trim){var li=after.lastIndexOf(nl.trim.seg);
  if(li>=0)after[li]={x1:nl.trim.seg.x1,y1:nl.trim.seg.y1,x2:nl.trim.x,y2:nl.trim.y,
   l:nl.trim.seg.l,w:nl.trim.seg.w,net:nl.trim.seg.net};}
 after=after.concat(candP,candN);
 if(drcGateDiffBlocks(bt,bv,after,bv)){
  routeStatMsg("that would create a DRC error — route the pair around it",true);
  drawFlashSet(candP.concat(candN));return false;}
 pr.s=pr.s||dpSide(legs); // same formula dpChainFor used for these legs
 var st={np:0,nn:0,plx:dtrace.lx,ply:dtrace.ly,nlx:pr.lx,nly:pr.ly,pdir:dtrace.pdir,tr:null};
 if(nl.trim){st.tr={seg:nl.trim.seg,ox:nl.trim.seg.x2,oy:nl.trim.seg.y2};
  nl.trim.seg.x2=nl.trim.x;nl.trim.seg.y2=nl.trim.y;pr.lx=nl.trim.x;pr.ly=nl.trim.y;}
 var p0=dtrace.laid.length,n0=pr.laid.length;
 legs.forEach(function(q){drawSeg(q.x,q.y);});dpLay(nl.legs);
 gpuCuEdit(); // both legs (and any inside-corner trim above) landed on the board
 st.np=dtrace.laid.length-p0;st.nn=pr.laid.length-n0;
 if(st.np+st.nn>0||st.tr)dtrace.steps.push(st);
 var lt=dtrace.laid.length?dtrace.laid[dtrace.laid.length-1]:null;
 if(lt){var L=Math.hypot(lt.x2-lt.x1,lt.y2-lt.y1);
  if(L>1e-9)dtrace.pdir={x:(lt.x2-lt.x1)/L,y:(lt.y2-lt.y1)/L};}
 return true;}
// Finish the pair on a far pad (either member's): each leg fans into its own
// pad — the clicked one plus its same-part twin. The P leg must land (it is
// the primary trace); a missing partner pad (an AC-coupling cap carrying only
// one member) leaves that leg coupled, with a note to finish it by hand.
function dpFinish(pt2){var pr=dtrace.pair,isP=(pt2.net===dtrace.net);
 var pEnd=isP?{x:pt2.x,y:pt2.y}:dpPartnerPad(pt2.x,pt2.y,dtrace.net,pt2.i);
 if(!pEnd){routeStatMsg("no "+nLeaf(dtrace.net)+" pad on that part — finish on the pair's far pads",true);return;}
 var nEnd=isP?dpPartnerPad(pt2.x,pt2.y,pr.net,pt2.i):{x:pt2.x,y:pt2.y};
 var pl=null,nl=null;
 [drawPath(dtrace.lx,dtrace.ly,pEnd),drawPath(dtrace.lx,dtrace.ly,pEnd,drawPosture^1)].some(function(c){
  if(drawLegsViolate(c))return false;
  var nn=dpChainFor(c,nEnd);
  if(dpLegsViolate(nn))return false;
  pl=c;nl=nn;return true;});
 if(!pl){routeStatMsg("that would violate clearance — reroute the last leg",true);return;}
 if(!dpCommit(pl,nl))return;
 var miss=!nEnd?nLeaf(pr.net):null;
 drawEnd();
 if(miss)routeStatMsg(miss+" has no pad there — its leg ends coupled; finish it by hand",true);}
// V in pair mode: a via on each head, side by side. When two barrels plus
// clearance need more centre spacing than the coupling gap gives, the pair
// spreads symmetrically along its own normal first (short jog legs, gated
// together with the vias); the junction direction resets so the next click
// fans back into the coupled run.
function dpViaPair(){var pr=dtrace.pair,vg=viaGeo();
 var need=vg.dia+netClrFor(dtrace.net);
 var px=dtrace.lx,py=dtrace.ly,nx=pr.lx,ny=pr.ly;
 var ux=nx-px,uy=ny-py,L=Math.hypot(ux,uy),jog=0;
 if(L<1e-9){routeStatMsg("via pair needs the heads apart — draw a leg first",true);return;}
 if(need>L+1e-9){jog=(need-L)/2;ux/=L;uy/=L;px-=ux*jog;py-=uy*jog;nx+=ux*jog;ny+=uy*jog;}
 if(viaViolation(px,py,dtrace.net,vg.dia,vg.drill)||viaViolation(nx,ny,pr.net,vg.dia,vg.drill)){
  routeStatMsg("a via pair here violates clearance — move first",true);return;}
 var candT=jog>0?[{x1:dtrace.lx,y1:dtrace.ly,x2:px,y2:py,l:dtrace.l,w:dtrace.w,net:dtrace.net,source:"human"},
  {x1:pr.lx,y1:pr.ly,x2:nx,y2:ny,l:dtrace.l,w:dtrace.w,net:pr.net,source:"human"}]:[];
 var candV=[{x:px,y:py,d:vg.dia,drill:vg.drill,net:dtrace.net,source:"human",id:viaIdNew()},{x:nx,y:ny,d:vg.dia,drill:vg.drill,net:pr.net,source:"human",id:viaIdNew()}];
 if(drcGateBlocks(candT,candV)){routeStatMsg("a via pair here would create a DRC error — move first",true);return;}
 if(jog>0){var st={np:0,nn:0,plx:dtrace.lx,ply:dtrace.ly,nlx:pr.lx,nly:pr.ly,pdir:dtrace.pdir};
  var p0=dtrace.laid.length;drawSeg(px,py);dpLay([{x:nx,y:ny}]);
  st.np=dtrace.laid.length-p0;st.nn=pr.laid.length?1:0;dtrace.steps.push(st);dtrace.pdir=null;}
 rfDropNet(dtrace.net);rfDropNet(pr.net);
 PCB.vias=PCB.vias||[];PCB.vias.push(candV[0]);PCB.vias.push(candV[1]);
 gpuCuEdit();
 dtrace.l=nextDrawLayer(dtrace.l);activeLayer=dtrace.l;syncActiveLayer();drawBtnSync();ovPaintSoon();}
// Backspace in pair mode unwinds the last CLICK as a unit — both legs' segs
// popped by identity, an inside-corner trim restored, both heads and the
// junction direction put back.
function dpBack(){var pr=dtrace.pair,st=dtrace.steps.pop();
 if(!st){drawEnd();return;}
 var ts=PCB.tracks||[],k;
 for(k=0;k<st.nn;k++){var i1=ts.lastIndexOf(pr.laid.pop());if(i1>=0)ts.splice(i1,1);}
 for(k=0;k<st.np;k++){var i2=ts.lastIndexOf(dtrace.laid.pop());if(i2>=0)ts.splice(i2,1);}
 if(st.tr){st.tr.seg.x2=st.tr.ox;st.tr.seg.y2=st.tr.oy;}
 dtrace.n-=st.np;dtrace.lx=st.plx;dtrace.ly=st.ply;pr.lx=st.nlx;pr.ly=st.nly;dtrace.pdir=st.pdir;
 gpuCuEdit();ovPaintSoon();}
function drawStart(net,layer,x,y,pi,pd){
 var dests=drawDests(pi,pd);
 if(dests.length)routeStatMsg("route "+nLeaf(net)+" → "+
  dests.map(function(d){return refLabel(P[d.i].ref);}).join(", "));
 var tr={net:net,l:layer,w:trackW(net),lx:x,ly:y,n:0,undo:snapAll(),laid:[],dest:dests,pdir:null,steps:[],
  startPad:(pi!=null&&pd&&!pd.thru)?{i:pi,pd:pd,l:layer}:null};
 // Auto-couple: a pad start on a declared diff-pair net grabs the partner
 // net's nearest pad as the twin trace's start — within 5 mm only (farther
 // apart the pads aren't a launch pair, so the trace stays single-ended).
 if(pi!=null&&pd){var dp=diffPairInfo(net);
  if(dp){var ns=dpPartnerPad(x,y,dp.partner,null);
   if(ns&&Math.hypot(ns.x-x,ns.y-y)<=5){
    tr.pair={net:ns.net,lx:ns.x,ly:ns.y,laid:[],s:0,gap:dp.gap>0?dp.gap:(PCB.clr||0.127),start:ns};
    routeStatMsg("coupled pair "+nLeaf(net)+" ⇄ "+nLeaf(ns.net)+" — press P to uncouple");}}}
 return tr;}
function drawClick(m,shift){
 if(!dtrace){var pt=padTarget(m);
  if(pt&&pt.net){dtrace=drawStart(pt.net,pt.l,pt.x,pt.y,pt.i,pt.pd);drawBtnSync();ovPaintSoon();return;}
  var v=drawHitVia(m);
  if(v&&v.net){dtrace=drawStart(v.net,activeLayer,v.x,v.y);drawBtnSync();ovPaintSoon();return;}
  var t=drawHitTrack(m,activeLayer);
  if(t&&t.net){var d1=Math.hypot(m.x-t.x1,m.y-t.y1),d2=Math.hypot(m.x-t.x2,m.y-t.y2);
   dtrace=drawStart(t.net,t.l||0,d1<=d2?t.x1:t.x2,d1<=d2?t.y1:t.y2);
   drawBtnSync();ovPaintSoon();return;}
  routeStatMsg("start a trace on a pad (or existing copper)",true);return;}
 var pt2=padTarget(m);
 // Coupled pair: clicking EITHER member's far pad finishes both legs (each
 // fans into its own pad); mid clicks lay both legs through dpCommit.
 if(dtrace.pair&&pt2&&pt2.net&&(pt2.net===dtrace.net||netCollapse(pt2.net)===netCollapse(dtrace.pair.net))){
  dpFinish(pt2);return;}
 if(pt2&&pt2.net&&pt2.net===dtrace.net){
  // Finish on a pad through the SAME posture legs the preview showed (the
  // committed copper is exactly the previewed path), dodging to the other
  // posture when the shown one collides.
  var pl=drawPath(dtrace.lx,dtrace.ly,{x:pt2.x,y:pt2.y});
  if(drawLegsViolate(pl)){
   var pa=drawPath(dtrace.lx,dtrace.ly,{x:pt2.x,y:pt2.y},drawPosture^1);
   if(drawLegsViolate(pa)){routeStatMsg("that would violate clearance — reroute the last leg",true);return;}
   pl=pa;}
  var planF=drawRoutePlan(pl),candF=planF.tracks;
  if(drcGateBlocks(candF,null)){routeStatMsg("that would create a DRC error — reroute the last leg",true);drawFlashSet(candF);return;}
  drawCommitPlan(planF);drawEnd();return;}
 if(pt2&&pt2.net&&pt2.net!==dtrace.net){
  routeStatMsg("that pad is on "+nLeaf(pt2.net)+" — trace is on "+nLeaf(dtrace.net),true);return;}
 if(dtrace.pair){var pd2=dpLegs(m,shift);
  if(pd2.blocked){routeStatMsg("blocked by clearance — route the pair around it",true);return;}
  if(dpCommit(pd2.legs,pd2.nl)){drawBtnSync();ovPaintSoon();}
  return;}
 var dl=drawLegs(m,shift);
 if(!dl.legs.length){routeStatMsg("blocked by clearance — no room toward that point",true);return;}
 var planC=drawRoutePlan(dl.legs),candC=planC.tracks;
 if(drcGateBlocks(candC,null)){routeStatMsg("that would create a DRC error — route around it",true);drawFlashSet(candC);return;}
 if(dl.clipped)routeStatMsg("head clipped at the clearance boundary — route around the obstacle",true);
 drawCommitPlan(planC);drawBtnSync();ovPaintSoon();}
// Resolve the committed target point for a click: magnet first (unless Shift),
// then the grid snap.
function drawTarget(m,shift){if(!shift){var mg=magSnap(m,dtrace&&dtrace.net);if(mg)return mg;}
 return drawSnap(m);}
// Would the leg chain from the last vertex breach clearance on any leg?
// In pair mode the partner's gesture copper is skipped too: the mid-drag gate
// mirrors the session view (gesture copper absent until the end-of-trace
// reload), and an inside-corner stub about to be trimmed must not false-block
// the P leg — the trim-aware commit gate stays the final word on both nets.
function drawLegsViolate(legs){if(!dtrace)return false;
 var fx=dtrace.lx,fy=dtrace.ly,skip=dtrace.pair?dtrace.laid.concat(dtrace.pair.laid):dtrace.laid;
 if(drawArcOn()&&!dtrace.pair){var ap=drawRoutePlan(legs);
  for(var k=0;k<ap.tracks.length;k++){var t=ap.tracks[k];
   if(segViolation(t.x1,t.y1,t.x2,t.y2,t.l,t.net,t.w/2,skip))return true;}return false;}
 for(var i=0;i<legs.length;i++){
  if(segViolation(fx,fy,legs[i].x,legs[i].y,dtrace.l,dtrace.net,dtrace.w/2,skip))return true;
  fx=legs[i].x;fy=legs[i].y;}
 return false;}
// The signal layer a via drop lands the trace on: the ACTIVE layer when the
// user parked it somewhere other than the trace's current layer (explicit
// intent), else the next VISIBLE signal layer in cycle order — so V on a
// 2-layer board still flips top↔bottom, and on a 4/6-layer board it walks
// the routable stack (skipping layers hidden in the Layers panel).
function nextDrawLayer(cur){if(activeLayer!==cur)return activeLayer;
 for(var k=1;k<=NSIG;k++){var c=(cur+k)%NSIG;if(viewSt.vis[visKey(c)])return c;}
 return (cur+1)%NSIG;}
function drawViaHere(){if(!dtrace)return;
 if(dtrace.pair){dpViaPair();return;}
 var vg=viaGeo();
 if(viaViolation(dtrace.lx,dtrace.ly,dtrace.net,vg.dia,vg.drill)){
  routeStatMsg("a via here violates clearance — move first",true);return;}
 var candV=[{x:dtrace.lx,y:dtrace.ly,d:vg.dia,drill:vg.drill,net:dtrace.net,source:"human",id:viaIdNew()}];
 if(drcGateBlocks(null,candV)){routeStatMsg("a via here would create a DRC error — move first",true);return;}
 PCB.vias=PCB.vias||[];
 rfDropNet(dtrace.net);
 PCB.vias.push(candV[0]);
 gpuCuEdit();
 dtrace.l=nextDrawLayer(dtrace.l);activeLayer=dtrace.l;syncActiveLayer();drawBtnSync();ovPaintSoon();}
function drawBack(){if(!dtrace)return;
 if(dtrace.pair){dpBack();return;}
 var st=dtrace.steps.length?dtrace.steps[dtrace.steps.length-1]:null;
 if(st&&st.kind==="single"){dtrace.steps.pop();var board=PCB.tracks||[];
  st.added.forEach(function(t){var ai=board.lastIndexOf(t);if(ai>=0)board.splice(ai,1);});
  if(st.remove&&st.removeIndex>=0)board.splice(Math.min(st.removeIndex,board.length),0,st.remove);
  dtrace.laid=st.laid;dtrace.lx=st.hx;dtrace.ly=st.hy;dtrace.n=st.n;gpuCuEdit();drawArcControlSync();ovPaintSoon();return;}
 var ts=PCB.tracks||[],last=ts.length?ts[ts.length-1]:null;
 if(dtrace.n>0&&last&&last.x2===dtrace.lx&&last.y2===dtrace.ly&&last.net===dtrace.net){
  ts.pop();if(dtrace.laid)dtrace.laid.pop();dtrace.lx=last.x1;dtrace.ly=last.y1;dtrace.n--;gpuCuEdit();ovPaintSoon();}
 else drawEnd();}
function drawDelAt(m){var v=drawHitVia(m);
 if(v){recordUndo();PCB.vias=PCB.vias.filter(function(q){return q!==v;});gpuCuEdit();routeStatMsg();ovPaintSoon();scheduleDrc();return;}
 var t=drawHitTrack(m);
 if(t){recordUndo();rfDropForTracks([t]);PCB.tracks=PCB.tracks.filter(function(q){return q!==t;});gpuCuEdit();routeStatMsg();ovPaintSoon();scheduleDrc();}}
// Route-head preview: the exact leg chain a click will commit (posture legs
// from drawPath), drawn SOLID at the real track width with round caps —
// KiCad-style, so what you see is precisely the copper you get. Only a
// clearance-violating head goes RED + dashed (the "won't commit" signal).
// The airwire's far pad(s) pulse amber the whole time the trace is live —
// the "connect me HERE" target.
function paintDraw(ctx){if(!drawMode||!dtrace)return;
 if(drawFlash){if(Date.now()<drawFlash.until){ // engine gate refused this click
   ctx.save();ctx.lineCap="round";ctx.lineJoin="round";ctx.setLineDash([]);
   ctx.strokeStyle="#ff4d4d";ctx.lineWidth=Math.max(dtrace.w*S,1.4);
   ctx.globalAlpha=0.4+0.5*Math.abs(Math.sin(Date.now()/120));
   ctx.beginPath();drawFlash.legs.forEach(function(g){ctx.moveTo(X(g.x1),Y(g.y1));ctx.lineTo(X(g.x2),Y(g.y2));});
   ctx.stroke();ctx.restore();setTimeout(paintSoon,60);}
  else drawFlash=null;}
 if(dtrace.dest&&dtrace.dest.length){
  ctx.save();ctx.setLineDash([]);
  var pu=0.55+0.45*Math.abs(Math.sin(Date.now()/240));
  dtrace.dest.forEach(function(d){
   var c=wpt(d.i,d.x,d.y);
   if(d.pd){var r=wrect(d.i,d.pd);
    ctx.globalAlpha=0.30*pu;ctx.fillStyle="#f0b72f";
    ctx.fillRect(X(r.x0),Y(r.y0),(r.x1-r.x0)*S,(r.y1-r.y0)*S);}
   ctx.globalAlpha=pu;ctx.strokeStyle="#f0b72f";ctx.lineWidth=1.6;
   var rr=Math.max(6,(d.pd?Math.max(d.pd.w,d.pd.h):0.8)*S*0.75);
   ctx.beginPath();ctx.arc(X(c.x),Y(c.y),rr,0,6.2832);ctx.stroke();});
  ctx.restore();
  setTimeout(paintSoon,60); // keep the target pulse alive while routing
 }
 if(!drawCur)return;
 var dl=dtrace.pair?dpLegs(drawCur,drawShift):drawLegs(drawCur,drawShift),s=dl.t;
 // Pair preview fans into the far pads while hovering a member pad — the exact
 // chains the finish click will commit.
 if(dtrace.pair&&!dl.blocked){var hp=padTarget(drawCur);
  if(hp&&hp.net===dtrace.net){var fq=dpPartnerPad(hp.x,hp.y,dtrace.pair.net,hp.i);
   if(fq)dl.nl=dpChainFor(dl.legs,fq);}}
 ctx.save();ctx.lineCap="round";ctx.lineJoin="round";
 ctx.lineWidth=Math.max(dtrace.w*S,1.2);
 if(dl.legs.length){ctx.globalAlpha=0.75;ctx.setLineDash(dl.blocked?[4,3]:[]);
  ctx.strokeStyle=dl.blocked?"#ff4d4d":layerColor(dtrace.l);
  ctx.beginPath();
  if(drawArcOn()&&!dtrace.pair){var ap=drawRoutePlan(dl.legs);
   ap.tracks.forEach(function(t){trackPath(ctx,t);});}
  else{ctx.moveTo(X(dtrace.lx),Y(dtrace.ly));dl.legs.forEach(function(q){ctx.lineTo(X(q.x),Y(q.y));});}
  ctx.stroke();}
 if(dtrace.pair&&dl.nl&&dl.nl.legs.length){var prv=dtrace.pair;
  var n0=dl.nl.trim||{x:prv.lx,y:prv.ly};
  ctx.globalAlpha=dl.blocked?0.75:0.55;ctx.setLineDash(dl.blocked?[4,3]:[]);
  ctx.strokeStyle=dl.blocked?"#ff4d4d":layerColor(dtrace.l);
  ctx.beginPath();ctx.moveTo(X(n0.x),Y(n0.y));
  dl.nl.legs.forEach(function(q){ctx.lineTo(X(q.x),Y(q.y));});
  ctx.stroke();ctx.setLineDash([]);}
 if(dl.clipped){ // blocked remainder: red dashed ghost to the cursor target
  var lp=dl.legs.length?dl.legs[dl.legs.length-1]:{x:dtrace.lx,y:dtrace.ly};
  ctx.globalAlpha=0.9;ctx.setLineDash([4,3]);ctx.strokeStyle="#ff4d4d";
  ctx.beginPath();ctx.moveTo(X(lp.x),Y(lp.y));ctx.lineTo(X(s.x),Y(s.y));ctx.stroke();}
 // magnet indicator: a small ring at a snapped target
 if(s.mag){ctx.setLineDash([]);ctx.globalAlpha=0.95;ctx.strokeStyle="#7ee787";ctx.lineWidth=1.4;
  ctx.beginPath();ctx.arc(X(s.x),Y(s.y),4,0,6.2832);ctx.stroke();}
 ctx.restore();}
var drawBtn=document.getElementById("pcb-draw");
if(drawBtn&&!RO)drawBtn.addEventListener("click",function(){drawModeSet(!drawMode);});
svg.addEventListener("dblclick",function(ev){if(drawMode&&dtrace){ev.preventDefault();drawEnd();return;}
 if(pourMode&&pourPts){ev.preventDefault();pourClose();return;}
 if(pourMode&&pourEdit&&!polyMode){var qm=mm(ev);if(vtxAt(qm)>=0)return;var qe=edgeAt(qm);if(qe){ev.preventDefault();outlineInsertVertex(qe);}return;}
 if(backingMode&&backingEdit&&!RO&&!polyMode){var bm=mm(ev);if(vtxAt(bm)>=0)return;var be=edgeAt(bm);
  if(be){ev.preventDefault();outlineInsertVertex(be);}return;}
 // Double-click an outline edge (not on a vertex) to insert a new vertex there.
 if(RO||textMode||polyPts||(!outlineMode&&!viewSt.filt.outline))return;
 var m=mm(ev);if(vtxAt(m)>=0)return;var e=edgeAt(m);
 if(e){ev.preventDefault();outlineInsertVertex(e);}});
svg.addEventListener("contextmenu",function(ev){
 if(pickMenu){ev.preventDefault();return;}
 if(!RO&&!anyDrawTool()&&traceFilletSelectionReady()){
  ev.preventDefault();traceFilletMenuOpen(ev);return;}
 if(backingMode&&backingEdit&&!RO){var bi=vtxAt(mm(ev));if(bi>=0){ev.preventDefault();outlineVertexDelete(bi);}return;}
 // Pour tool armed: right-click deletes the pour under (or near the rim of) the
 // cursor. Takes precedence over the outline/copper-delete paths below.
 if(pourMode&&!RO){var pm=mm(ev);if(pourEdit){var pvi=vtxAt(pm);if(pvi>=0){ev.preventDefault();outlineVertexDelete(pvi);return;}}
  ev.preventDefault();pourDeleteAt(pm);return;}
 // Right-click a drawn outline vertex to delete it (≥3 kept) — this precedes
 // the copper-delete path so a vertex handle wins over a track beneath it.
 if(!RO&&!drawMode&&!textMode&&(outlineMode||polyMode||viewSt.filt.outline)){var vm=mm(ev),vi=vtxAt(vm);
  if(vi>=0){ev.preventDefault();outlineVertexDelete(vi);return;}}
 if(textMode){var tm=mm(ev),ti=txAt(tm.x,tm.y);if(ti>=0){ev.preventDefault();txDelete(ti);}return;}
 if(!drawMode)return;ev.preventDefault();
 if(dtrace){drawEnd();return;}
 drawDelAt(mm(ev));});
document.addEventListener("keydown",function(ev){if(RO||kbTyping(ev.target))return;
 if((ev.key=="x"||ev.key=="X")&&!ev.ctrlKey&&!ev.metaKey){ev.preventDefault();drawModeSet(!drawMode);return;}
 if(!drawMode)return;
 if(dtrace&&(ev.key=="v"||ev.key=="V")){ev.preventDefault();drawViaHere();return;}
 if((ev.key=="p"||ev.key=="P")&&dtrace&&dtrace.pair){ev.preventDefault();
  dtrace.pair=null;routeStatMsg("pair uncoupled — routing "+nLeaf(dtrace.net)+" alone");drawBtnSync();ovPaintSoon();return;}
 if(ev.key=="/"){ev.preventDefault();drawPosture^=1;
  routeStatMsg("corner posture: "+(drawAngle==="90"?(drawPosture?"vertical then horizontal":"horizontal then vertical"):(drawPosture?"45° then line":"line then 45°")));ovPaintSoon();return;}
 if(ev.key=="e"||ev.key=="E"){ev.preventDefault();drawAngleSet(drawAngle==="45"?"90":"45",true);return;}
 if(ev.key=="a"||ev.key=="A"){ev.preventDefault();var bs=document.getElementById("r-bend");
  if(bs){bs.value=bs.value==="arc"?"sharp":"arc";bs.dispatchEvent(new Event("change"));
   routeStatMsg(bs.value==="arc"?"rounded tangent-arc bends":("sharp "+drawAngle+"° bends"));}return;}
 if(ev.key=="Backspace"){ev.preventDefault();drawBack();return;}
 if(ev.key=="Enter"&&dtrace){ev.preventDefault();drawEnd();return;}});
// ── Who a violation is between ──────────────────────────────────────────
// The server names the parties of every violation it can (drc_json.zig): `a`
// and `b` carry `net` / `ref` / `pad`, each absent when that rule has no such
// party — a courtyard clash has parts but no net, a net open has ONE net (its
// own) plus a pad from each island it failed to join. Everything below degrades
// to the old bare "kind + gap" text when a producer sends neither.
function drcMm(v){return v==null?"?":(+v).toFixed(3);}
// "U3.12" — a party's pad, or just its part when the pad wasn't named.
function drcPad(p){if(!p||!p.ref)return "";
 return nLeaf(p.ref)+(p.pad?"."+p.pad:"");}
// One party as text: "GND", "GND on U3.12", "U3.12", or "".
function drcSide(p){if(!p)return "";
 var net=p.net?nLeaf(p.net):"",pad=drcPad(p);
 return (net&&pad)?(net+" on "+pad):(net||pad);}
// Both parties: "SIG ↔ GND on U3.12", or the one side that is known.
function drcBetween(d){var a=drcSide(d.a),b=drcSide(d.b);
 return (a&&b)?(a+" ↔ "+b):(a||b);}
// Just the nets — the panel row's primary identity column.
function drcNets(d){var a=(d.a&&d.a.net)?nLeaf(d.a.net):"",b=(d.b&&d.b.net)?nLeaf(d.b.net):"";
 if(a&&b)return a===b?a:a+" ↔ "+b;return a||b;}
// Just the pads/parts — the row's secondary column.
function drcPads(d){var a=drcPad(d.a),b=drcPad(d.b);
 if(a&&b)return a+" ↔ "+b;return a||b;}
// Per-kind marker tooltip. Courtyard/silk have no clearance rule, so the
// generic "gap X < clr" form reads as nonsense ("< 0 mm") — give them their own.
// Every form names its parties, so a marker says WHICH nets/pads are at fault
// instead of leaving them to be reverse-engineered from the coordinates.
function drcMsg(d){
 var tag=d.id?("#"+d.id+" "):""; // the violation's short traceable id
 var who=drcBetween(d),on=who?(" — "+who):"";
 // A net open is one net in pieces, not two parties clashing — name the net,
 // then the island on each side of the gap.
 if(d.k=="net open"){var n=(d.a&&d.a.net)?nLeaf(d.a.net):"",ends=drcPads(d);
  return tag+d.k+(n?(" — "+n):"")+": "+(ends?("the "+ends+" copper islands"):"two copper islands")+
   " never join ("+drcMm(d.gap)+" mm apart)";}
 if(d.k=="courtyard overlap")return tag+d.k+on+" — parts overlap by "+drcMm(-d.gap)+" mm";
 if(d.k=="silkscreen overlap")return tag+d.k+on+" — silkscreen crosses a pad's solder-mask opening";
 if(d.k=="track width")return tag+d.k+on+" — "+drcMm(d.gap)+" mm < "+drcMm(d.clr)+" mm required";
 // The copper-topology findings carry no clearance pair at all (gap=clr=0), so
 // the generic form below would print "gap 0.000 mm < 0.000 mm" — say what the
 // copper is instead.
 if(d.k=="copper stub")return tag+d.k+on+" — a track end that reaches no pad, via or pour";
 if(d.k=="dangling copper")return tag+d.k+on+" — a copper fragment joined to nothing at either end";
 // gap/clr here are a USE COUNT, not millimetres.
 if(d.k=="single-layer via")return tag+d.k+on+" — the barrel is used on "+(+d.gap||0)+" layer(s); a via needs two";
 // Not a shortfall either: gap is how much copper lies on the land, clr how far
 // the run's aim misses the pad centre.
 if(d.k=="copper on own land")return tag+d.k+on+" — "+drcMm(d.gap)+" mm of copper laps this pad's own land, missing its centre by "+drcMm(d.clr)+" mm";
 // The diff-pair rules measure an EXCESS, not a shortfall — "gap X < Y" would
 // read backwards on them.
 if(d.k=="diff skew")return tag+d.k+on+" — legs differ by "+drcMm(d.gap)+" mm, over the "+drcMm(d.clr)+" mm match window";
 if(d.k=="diff uncoupled")return tag+d.k+on+" — legs separate to "+drcMm(d.gap)+" mm, over the "+drcMm(d.clr)+" mm coupling window";
 // A (match-group …) spread is the same excess across N nets instead of two.
 if(d.k=="length mismatch")return tag+d.k+on+" — group spreads "+drcMm(d.gap)+" mm, over the "+drcMm(d.clr)+" mm match budget";
 if(d.k=="reference plane gap")return tag+d.k+on+" — routed copper crosses a split, slot, or missing island in its fabricated reference plane";
 if(d.k=="reference transition")return tag+d.k+on+" — nearest return stitch is "+drcMm(d.gap)+" mm away, beyond the "+drcMm(d.clr)+" mm radius";
 if(d.k=="return loop area")return tag+d.k+on+" — estimated "+drcMm(d.gap)+" mm² exceeds the "+drcMm(d.clr)+" mm² budget";
 return tag+d.k+on+" — gap "+drcMm(d.gap)+" mm < "+drcMm(d.clr)+" mm";}
// Marker colour keeps the panel's err/warn split (warn markers read amber).
function drcMarkColor(d){return (d&&(d.sev==="warn"||d.sev==="warning"))?"#e3b341":TH.drc;}
// Connectivity remains actionable in the DRC sidebar, but its island-gap
// coordinates are not useful board annotations and can overwhelm the copper.
function drcOnBoard(d){return !!d&&d.k!=="net open";}
// A layer-scoped finding is an annotation of that copper, so the same eye or
// Front/Back preset hides both. Layerless findings describe physical features
// spanning the board (holes/vias/edge) or the whole assembly and stay visible.
function drcMarkerVisible(d){return drcOnBoard(d)&&!!viewSt.vis[drcSevClass(d)==="warn"?"drc_warn":"drc_err"]&&
 (d.l==null||layerAlpha(d.l)>0);}
function drawDrc(){while(gD.firstChild)gD.removeChild(gD.firstChild);
 renderDrcList(); // keep the violations panel in sync regardless of marker visibility
 if(PHYSICAL_REVIEW)return;
 // A thin, screen-space (non-scaling) translucent ring + small dot: it flags the
 // spot without the fat opaque disc smothering the copper you're trying to read.
 (PCB.drc||[]).forEach(function(d){if(!drcMarkerVisible(d))return;var cx=X(d.x),cy=Y(d.y),col=drcMarkColor(d);
   var t=el("title",{}); t.textContent=drcMsg(d);
   var c=el("circle",{cx:cx.toFixed(1),cy:cy.toFixed(1),r:6,fill:"none",stroke:col,
    "stroke-width":1.1,"vector-effect":"non-scaling-stroke",opacity:0.6}); c.appendChild(t);
   gD.appendChild(c);
   gD.appendChild(el("circle",{cx:cx.toFixed(1),cy:cy.toFixed(1),r:1.1,fill:col,opacity:0.6}));});}
var drcCb=document.getElementById("r-drc-show");
if(drcCb&&drcCb.checked){viewSt.vis.drc_err=1;viewSt.vis.drc_warn=1;}
function drcSync(){
 if(drcCb){drcCb.checked=!!viewSt.vis.drc_err&&!!viewSt.vis.drc_warn;drcCb.indeterminate=!!viewSt.vis.drc_err!==!!viewSt.vis.drc_warn;}
 if(PCB.apSync)PCB.apSync(); // every Appearance container's severity rows, both surfaces
 drawDrc();}
function drcSet(on){viewSt.vis.drc_err=on?1:0;viewSt.vis.drc_warn=on?1:0;viewSave();drcSync();}
if(drcCb)drcCb.addEventListener("change",function(){drcSet(drcCb.checked);});
// ── DRC violations panel ────────────────────────────────────────────────
// The full page docks this list in the left dock's DRC pane (#drc-list, emitted
// by writeSidebar) so locating a violation never closes the list it was clicked
// in; the embeds, which have no dock, keep the Route panel's fold-out toggled by
// its DRC count chip. Clicking a row pans/zooms to the marker and flashes it
// (focusPoint). Rebuilt on every DRC refresh; tolerant of an optional
// per-violation `severity` field (another agent owns the DRC severity model —
// render it when present, ignore it when absent).
function focusPoint(wx,wy){
 var cx=X(wx),cy=Y(wy),far=hostAspect();
 var fw=Math.min(VBW,vb.w,Math.max(24*S,VBW*0.12)); // zoom in to the marker, never past the board / never zoom out
 vb={x:cx-fw/2,y:cy-fw*far/2,w:fw,h:fw*far};setVB();
 flashPt={x:wx,y:wy};flashPtUntil=Date.now()+2600;paintSoon();}
function ensureDrcList(){var lst=document.getElementById("drc-list");if(lst)return lst;
 if(RO)return null;var rp=document.getElementById("panel-route");if(!rp)return null;
 lst=document.createElement("div");lst.id="drc-list";lst.className="drc-list";lst.hidden=true;
 rp.appendChild(lst);return lst;}
function drcSevClass(d){var s=String(d.severity||d.sev||"").toLowerCase();
 if(s==="warn"||s==="warning")return "warn";
 if(s==="err"||s==="error")return "err";return "";}
function drcLoc(d){
 var nets=drcNets(d);if(nets)return nets;
 if(d.nets&&d.nets.length)return [].concat(d.nets).join(" · ");
 if(d.refs&&d.refs.length)return [].concat(d.refs).map(refLabel).join(" · ");
 if(d.net)return d.net;if(d.ref)return refLabel(d.ref);return "";}
// Per-kind DRC rule settings — the \u2699 Rules menu in the violations panel.
// Each kind picks Error / Warning / Ignore; deviations from the built-in
// default POST to /api/pcb-drc-rules/<design> (persisted server-side, so the
// APIs, the fab gate, and this viewer all judge the board the same way).
var drcRulesOpen=false;
function drcRulesHtml(){var ks=PCB.drc_kinds||[];
 if(!ks.length)return '<div class="drc-empty">rule table unavailable</div>';
 var h='<div id="drc-rules" style="padding:2px 0 6px;border-bottom:1px solid #2c2d31">';
 ks.forEach(function(kk,i){var eff=kk.ov||kk.def;
  h+='<div class="drc-row" style="cursor:default"><span class="drc-k">'+pEsc(kk.label)+'</span>'+
   '<select class="pv-in" data-drck="'+i+'" style="width:118px">';
  [["err","Error"],["warn","Warning"],["ignore","Ignore"]].forEach(function(op){
   h+='<option value="'+op[0]+'"'+(op[0]===eff?' selected':'')+'>'+op[1]+(op[0]===kk.def?" (default)":"")+'</option>';});
  h+='</select></div>';});
 return h+'</div>';}
function drcRulesPost(){var ov={};
 (PCB.drc_kinds||[]).forEach(function(kk){if(kk.ov&&kk.ov!==kk.def)ov[kk.k]=kk.ov;});
 fetch("/api/pcb-drc-rules/"+encodeURIComponent(PCB.name),{method:"POST",
   headers:{"Content-Type":"application/json"},body:JSON.stringify(ov)})
  .then(function(r){if(!r.ok)throw 0;return r.json();})
  .then(function(j){if(j.kinds)PCB.drc_kinds=j.kinds;drcRefreshNow();})
  .catch(function(){routeStatMsg("saving DRC rules failed",true);});}
// Collapsed type-groups in the violations panel, keyed by kind label. Persists
// across re-renders so a group you fold stays folded through DRC refreshes.
var drcCollapsed={};
// Net-open emits one record per missing island-to-island join. Keep those gap
// records for inspection, but present one collapsed row per exact (unshortened)
// net name so an unrouted rail with 40 isolated pads reads as one open net, not
// 39 unrelated errors. A net row expands on demand to expose its individual
// gaps and their stable violation ids.
var drcOpenExpanded=Object.create(null);
function drcOpenNetName(d){return d&&d.k==="net open"&&d.a&&d.a.net?String(d.a.net):"";}
function drcOpenNetGroups(idxs){var v=PCB.drc||[],by=Object.create(null),out=[];
 idxs.forEach(function(i){var name=drcOpenNetName(v[i]),key="$"+name,g=by[key];
  if(!g){g=by[key]={name:name,idxs:[]};out.push(g);}g.idxs.push(i);});
 out.sort(function(a,b){return a.name<b.name?-1:a.name>b.name?1:0;});return out;}
// A type-group counts as an error (sorts first, red badge) unless every one of
// its violations is a warning — matching the on-board marker colour split.
function grpSev(idxs){var v=PCB.drc||[];
 for(var j=0;j<idxs.length;j++){if(drcSevClass(v[idxs[j]])!=="warn")return 0;}
 return 1;}
// Violations bucketed by kind (d.k) into render order: errors ahead of
// warnings, then the canonical drc_kinds sequence (same as the settings
// drawer), unrecognised kinds last. Each bucket holds original PCB.drc indices,
// so both the list rows and the ‹ › step-through address the same records.
function drcGroups(){var v=PCB.drc||[],groups={},order=[];
 v.forEach(function(d,i){var k=d.k||"violation";
  if(!groups[k]){groups[k]=[];order.push(k);}groups[k].push(i);});
 var rank={};(PCB.drc_kinds||[]).forEach(function(kk,idx){rank[kk.label]=idx;});
 order.sort(function(a,b){var sa=grpSev(groups[a]),sb=grpSev(groups[b]);
  if(sa!==sb)return sa-sb;
  var ra=rank[a]==null?999:rank[a],rb=rank[b]==null?999:rank[b];
  if(ra!==rb)return ra-rb;return a<b?-1:a>b?1:0;});
 return {groups:groups,order:order};}
// Counts for compact status surfaces. Ordinary violations still count one by
// one; net-open gaps count once per net, matching the rows the user can act on.
// The raw gap count remains available in the expanded list and its type header.
function drcSummary(){var v=PCB.drc||[],openIdx=[],otherErr=0,otherWarn=0;
 v.forEach(function(d,i){if(d.k==="net open")openIdx.push(i);
  else if(drcSevClass(d)==="warn")otherWarn++;else otherErr++;});
 var nets=drcOpenNetGroups(openIdx),openErr=0,openWarn=0;
 nets.forEach(function(g){if(grpSev(g.idxs))openWarn++;else openErr++;});
 return {open:nets.length,openGaps:openIdx.length,otherErr:otherErr,otherWarn:otherWarn,
  err:otherErr+openErr,warn:otherWarn+openWarn};}
// Grouped by type: each type gets a collapsible header row with a count badge,
// then its own violations underneath. Net-open gets one extra level by exact
// net name, collapsed by default; expanding a net reveals the original rows.
// Rows keep their original PCB.drc index so a click still locates the record.
function renderDrcList(){drcTabBadge();var lst=ensureDrcList();if(!lst)return;
 var v=PCB.drc||[];
 var g=drcGroups(),groups=g.groups,order=g.order;
 var nt=order.length,sum=drcSummary(),issues=sum.err+sum.warn,other=sum.otherErr+sum.otherWarn;
 var h='<div class="drc-row" style="cursor:default;font-weight:600"><span class="drc-k">'+
  (v.length?((sum.open?(sum.open+" open net"+(sum.open>1?"s":"")+(other?(" · "+other+" other issue"+(other>1?"s":"")):"")):
   (issues+" issue"+(issues>1?"s":"")))+(nt>1?" · "+nt+" types":"")):"No DRC violations")+'</span>'+
  '<button id="drc-cog" class="btn" style="font-size:11px" title="Choose which checks count as errors or warnings, or are ignored — saved with the design, honoured by the APIs and the fab gate too">\u2699 Rules</button></div>';
 if(drcRulesOpen)h+=drcRulesHtml();
 order.forEach(function(k){var idxs=groups[k],err=grpSev(idxs)===0,coll=!!drcCollapsed[k];
  var openNets=k==="net open"?drcOpenNetGroups(idxs):null;
  var countText=openNets?(openNets.length+" net"+(openNets.length>1?"s":"")):String(idxs.length);
  h+='<div class="drc-grp'+(err?" err":" warn")+(coll?" coll":"")+'" data-drcg="'+pEsc(k)+'" title="'+
    (coll?"Show":"Hide")+' these '+(openNets?(openNets.length+' open net'+(openNets.length>1?'s':'')+' / '+idxs.length+' missing connections'):(idxs.length+' violation'+(idxs.length>1?'s':'')))+'">'+
   '<span class="drc-tw">'+(coll?"▸":"▾")+'</span>'+
   '<span class="drc-k">'+pEsc(k)+'</span>'+
   '<span class="drc-gc '+(err?"err":"warn")+'">'+countText+'</span></div>';
  if(coll)return;
  if(openNets){openNets.forEach(function(ng){var expanded=!!drcOpenExpanded[ng.name],first=v[ng.idxs[0]],sc=drcSevClass(first);
   h+='<div class="drc-net'+(sc?' '+sc:'')+(expanded?'':' coll')+'" data-drcnet="'+pEsc(ng.name)+'" data-drcfirst="'+ng.idxs[0]+'" title="'+
    (expanded?'Hide':'Show')+' '+ng.idxs.length+' connection'+(ng.idxs.length>1?'s':'')+' needed for '+pEsc(ng.name||'unnamed net')+'">'+
    '<span class="drc-tw">'+(expanded?'▾':'▸')+'</span><span class="drc-loc">'+pEsc(ng.name||'(unnamed net)')+'</span>'+
    '<span class="drc-net-count">'+ng.idxs.length+' connection'+(ng.idxs.length>1?'s':'')+' needed</span></div>';
   if(!expanded)return;
   ng.idxs.forEach(function(i){h+=drcViolationRow(v[i],i);});});return;}
  idxs.forEach(function(i){h+=drcViolationRow(v[i],i);});});
 lst.innerHTML=h;
 var cog=document.getElementById("drc-cog");
 if(cog)cog.addEventListener("click",function(){drcRulesOpen=!drcRulesOpen;renderDrcList();});
 lst.querySelectorAll("[data-drck]").forEach(function(sl){
  sl.addEventListener("change",function(){var kk=(PCB.drc_kinds||[])[+sl.getAttribute("data-drck")];
   if(!kk)return;kk.ov=(sl.value===kk.def)?null:sl.value;drcRulesPost();});});
 lst.querySelectorAll("[data-drcg]").forEach(function(g){
  g.addEventListener("click",function(){var k=g.getAttribute("data-drcg");
   drcCollapsed[k]=!drcCollapsed[k];renderDrcList();});});
 lst.querySelectorAll("[data-drcnet]").forEach(function(g){
  g.addEventListener("click",function(){var name=g.getAttribute("data-drcnet");
   var first=+g.getAttribute("data-drcfirst");
   var expanding=!drcOpenExpanded[name];drcOpenExpanded[name]=expanding;
   if(!expanding&&drcOpenNetName((PCB.drc||[])[drcCur])===name){
    for(var i=0;i<(PCB.drc||[]).length;i++){if(drcOpenNetName(PCB.drc[i])===name){drcCur=i;break;}}}
   renderDrcList();drcGoto(first);});});
 lst.querySelectorAll("[data-drc]").forEach(function(row){
  row.addEventListener("click",function(){drcGoto(+row.getAttribute("data-drc"));});});
 drcMarkCur();if(window.PCBFindRefresh)window.PCBFindRefresh();}
function drcViolationRow(d,i){var loc=drcLoc(d),pads=drcPads(d),sc=drcSevClass(d);
 return '<div class="drc-row'+(sc?' '+sc:'')+'" data-drc="'+i+'" title="'+pEsc(drcMsg(d))+' — click to locate">'+
  (d.id?'<span class="drc-loc drc-id">#'+pEsc(d.id)+'</span>':'')+
  (loc?'<span class="drc-loc">'+pEsc(loc)+'</span>':'')+
  (pads?'<span class="drc-ref">'+pEsc(pads)+'</span>':'')+
  '<span class="drc-gap">'+(d.gap!=null?(Math.round(d.gap*1000)/1000):'?')+' / '+
   (d.clr!=null?(Math.round(d.clr*1000)/1000):'?')+' mm</span></div>';}
// ── DRC step-through ────────────────────────────────────────────────────
// The DRC pane's ‹ Prev / Next › walk the list in rendered order, wrapping at
// both ends. A collapsed type-group drops out; a collapsed net-open row counts
// once, while an expanded one exposes every gap. Locating a violation keeps the
// DRC tab up (inspSetHere), so a whole board's worth can be clicked through
// without the pane sliding away — the located violation's full message shows
// in the pane header.
var drcCur=-1;
function drcFlatOrder(){var g=drcGroups(),out=[];
 g.order.forEach(function(k){if(drcCollapsed[k])return;
  if(k==="net open"){drcOpenNetGroups(g.groups[k]).forEach(function(ng){
   if(drcOpenExpanded[ng.name])ng.idxs.forEach(function(i){out.push(i);});else out.push(ng.idxs[0]);});return;}
  g.groups[k].forEach(function(i){out.push(i);});});
 return out;}
function drcStep(dir){var fo=drcFlatOrder();if(!fo.length)return;
 var at=fo.indexOf(drcCur);
 drcGoto(fo[at<0?(dir>0?0:fo.length-1):((at+dir+fo.length)%fo.length)]);}
function drcGoto(i){var d=(PCB.drc||[])[i];if(!d)return;
 drcCur=i;drcMarkCur();inspSetHere({t:"drc",o:d});
 if(d.bridge&&d.bridge.length===4){zoomToPoly([[d.bridge[0],d.bridge[1]],[d.bridge[2],d.bridge[3]]]);paintSoon();}
 else if(drcOnBoard(d)&&d.x!=null&&d.y!=null)focusPoint(d.x,d.y);}
// Paint the located row, scroll it into view, and refresh the pane header's
// position readout + message. Safe on the embeds (no header, no-op lookups).
function drcMarkCur(){var lst=document.getElementById("drc-list");
 var d=(PCB.drc||[])[drcCur]||null,cur=null;
 if(lst)lst.querySelectorAll(".drc-row[data-drc]").forEach(function(r){
  var on=+r.getAttribute("data-drc")===drcCur;r.classList.toggle("cur",on);if(on)cur=r;});
 if(lst)lst.querySelectorAll(".drc-net[data-drcnet]").forEach(function(r){
  var on=!!d&&drcOpenNetName(d)===r.getAttribute("data-drcnet");r.classList.toggle("cur",on);if(on&&!cur)cur=r;});
 if(cur&&cur.scrollIntoView)cur.scrollIntoView({block:"nearest"});
 var fo=drcFlatOrder(),at=d?fo.indexOf(drcCur):-1;
 var pos=document.getElementById("drc-pos");
 if(pos)pos.textContent=fo.length?((at<0?"–":(at+1))+" / "+fo.length):"—";
 var msg=document.getElementById("drc-cur");
 if(msg){msg.className="drc-cur"+(d?" "+(drcSevClass(d)||"err"):"");
  msg.textContent=d?drcMsg(d):(fo.length?"Click a violation to locate it on the board.":"No DRC violations.");}}
// The Route panel's DRC chip raises the DRC tab (the list's home on the full
// page); on the embeds, which have no left dock, it folds the inline list open.
function drcListToggle(){var lst=ensureDrcList();if(!lst)return;
 if(document.getElementById("side-drc")){pcbSideTab("side-drc");renderDrcList();return;}
 lst.hidden=!lst.hidden;if(!lst.hidden)renderDrcList();}
(function(){var chip=document.getElementById("r-drc");
 if(chip&&!RO){chip.style.cursor="pointer";chip.title="Click to list / locate DRC violations";
  chip.addEventListener("click",drcListToggle);}
 var p=document.getElementById("drc-prev"),n=document.getElementById("drc-next");
 if(p)p.addEventListener("click",function(){drcStep(-1);});
 if(n)n.addEventListener("click",function(){drcStep(1);});})();
// Left-dock DRC tab badge: the actionable error count (red) when any check
// fails, else the warning count (amber), else bare. Net-open contributes one
// per net here, while other checks retain their per-violation counts.
function drcTabBadge(){var tab=document.querySelector('.side-tab[data-sidetab="side-drc"]');
 if(!tab)return;
 var sum=drcSummary(),err=sum.err,warn=sum.warn;
 tab.innerHTML="DRC"+(err?' <span class="side-tab-n err">'+err+"</span>":
  (warn?' <span class="side-tab-n warn">'+warn+"</span>":""));}
// The Design settings drawer's DRC policy section edits the same per-kind rule
// table. It hands the server's authoritative kinds array back through here so
// the Route panel's cog menu and the on-board markers re-judge immediately,
// instead of waiting for a page reload.
window.PCBDrcRulesApply=function(kinds){
 if(kinds)PCB.drc_kinds=kinds;
 if(!RO)renderDrcList();
 drcRefreshNow();};
// ── Copper / DRC inspector ────────────────────────────────────────────────
// Click a track, via, or DRC marker in Select mode to inspect it: the sidebar
// Properties panel shows its facts (segment ID, net, layer, geometry, or the
// violation's traceable #id) and Copy report puts a one-line description on the clipboard
// — made to be pasted verbatim into a bug report or an agent chat. Esc /
// empty click / any copper edit clears it.
var insp=null; // {t:"track"|"via"|"keepout"|"drc", o:<live object>}
function pxTolMm(px){return px*(vb.w/Math.max(svgMetricsGet().cw,1))/S;}
function inspHitDrc(m){if(!viewSt.filt.drc)return null;var best=null,bd=Math.max(pxTolMm(12),0.3);
 (PCB.drc||[]).forEach(function(d){if(!drcMarkerVisible(d)||d.x==null)return;
  var dd=Math.hypot(m.x-d.x,m.y-d.y);if(dd<bd){bd=dd;best=d;}});return best;}
function inspHitVia(m,strict){if(!viewSt.filt.via)return null;var best=null,bd=1e9,
  tol=strict?0:Math.max(pxTolMm(6),0.15); // strict = inside the barrel only
 (PCB.vias||[]).forEach(function(v){var d=Math.hypot(m.x-v.x,m.y-v.y)-(v.d||0.4)/2;
  if(d<tol&&d<bd){bd=d;best=v;}});return best;}
function inspHitTrack(m){if(!viewSt.filt.track)return null;var best=null,bd=1e9,tol=Math.max(pxTolMm(5),0.12);
 (PCB.tracks||[]).forEach(function(t){
  if(layerAlpha(t.l||0)<=0)return; // hidden layer — not clickable
  var d=segDist(m.x,m.y,t)-(t.w||0.25)/2;
  if(d<tol&&d<bd){bd=d;best=t;}});return best;}
// Hit-test only copper the user has already selected. The inspector's single
// selection wins over a marquee band when both contain coincident copper; vias
// retain the normal via-before-track tie-break inside the band. This is called
// before partAt(), so a footprint's much larger courtyard cannot steal the
// selected object's drag.
function selectedCopperHit(m){
 function viaHit(v){if(!viewSt.filt.via||(PCB.vias||[]).indexOf(v)<0)return false;
  return Math.hypot(m.x-v.x,m.y-v.y)-(v.d||0.4)/2<Math.max(pxTolMm(6),0.15);}
 function trackHit(t){if(!viewSt.filt.track||layerAlpha(t.l||0)<=0||(PCB.tracks||[]).indexOf(t)<0)return false;
  return segDist(m.x,m.y,t)-(t.w||0.25)/2<Math.max(pxTolMm(5),0.12);}
 if(insp&&insp.t==="via"&&viaHit(insp.o))return insp;
 if(insp&&insp.t==="track"&&trackHit(insp.o))return insp;
 var best=null,bd=1e9;
 selCu.v.forEach(function(v){if(!viaHit(v))return;var d=Math.hypot(m.x-v.x,m.y-v.y)-(v.d||0.4)/2;
  if(d<bd){bd=d;best={t:"via",o:v};}});
 if(best)return best;
 selCu.t.forEach(function(t){if(!trackHit(t))return;var d=segDist(m.x,m.y,t)-(t.w||0.25)/2;
  if(d<bd){bd=d;best={t:"track",o:t};}});return best;}
// Pours / keepouts are the final hit-test tier, behind components, groups,
// DRC, vias and tracks. Their whole visible area is clickable: the Objects
// filter can isolate them without forcing the user to catch a one-pixel dashed
// rim. Editable copper zones open their pour dialog; imported/fixed keepouts
// select into the read-only Properties inspector. A hidden layer/overlay never
// leaves invisible geometry clickable.
function inspHitZone(m){if(RO||!viewSt.filt.zone)return null;var zs=PCB.zones||[];var tol=Math.max(pxTolMm(6),0.2);
 for(var i=zs.length-1;i>=0;i--){var z=zs[i],poly=z.poly;if(!poly||poly.length<3)continue;
  var L=reviewAreaLayer(z);if(L!=null&&layerAlpha(L)<=0)continue;
  if(polyContains(poly,m.x,m.y)||nearPolyEdge(poly,m.x,m.y,tol))return {t:z.keepout?"keepout":"zone",o:z};}
 if(viewSt.vis.keepouts){var ks=PCB.keepouts||[];
  for(var j=ks.length-1;j>=0;j--){var q=ks[j],outer=q.outer,inner=q.inner;
   if(!outer||outer.length<3)continue;
   var band=polyContains(outer,m.x,m.y)&&(!inner||inner.length<3||!polyContains(inner,m.x,m.y));
   if(band||nearPolyEdge(outer,m.x,m.y,tol)||(inner&&inner.length>=3&&nearPolyEdge(inner,m.x,m.y,tol)))
    return {t:"keepout",o:q};}}
 return null;}
function inspHit(m){var d=inspHitDrc(m);if(d)return {t:"drc",o:d};
 var v=inspHitVia(m);if(v)return {t:"via",o:v};
 var t=inspHitTrack(m);if(t)return {t:"track",o:t};
 return inspHitZone(m);}
// Inspection hit for a click that is ALSO over part `pi`: a DRC marker wins
// outright (debugging beats selection); a click INSIDE a via barrel wins
// even on a pad (the stitch-via-in-ground-pad case — it's the smaller,
// precise target); any other pad click stays a part click; bare vias and
// tracks win only off-pad.
function inspHitForPart(m,pi){var d=inspHitDrc(m);if(d)return {t:"drc",o:d};
 var vs=inspHitVia(m,true);if(vs)return {t:"via",o:vs};
 if(viewSt.filt.pad&&pi>=0&&padAt(pi,m.x,m.y))return null;
 var v=inspHitVia(m);if(v)return {t:"via",o:v};
 var t=inspHitTrack(m);if(t)return {t:"track",o:t};return null;}

// Net identity under a resting pointer. Pads keep the richer existing
// "reference · net" status text; off-pad routed copper, vias, pours and visible
// unrouted airwires contribute their net name to that same bottom-right slot.
// Reuse the inspector hit rules so hidden/filter-disabled copper cannot report
// a net the user cannot see or select.
function statusFeatureNet(m,partIndex){
 if(partIndex>=0&&padAt(partIndex,m.x,m.y))return null;
 var v=inspHitVia(m);if(v&&v.net)return v.net;
 var t=inspHitTrack(m);if(t&&t.net)return t.net;
 var z=partIndex<0?inspHitZone(m):null;
 if(z&&z.t==="zone"&&z.o&&z.o.net)return z.o.net;
 if(PHYSICAL_REVIEW||ovExclusive()||!ratsOn||!viewSt.vis.rats)return null;
 if(linksDirty&&!dragIdxSet())linksRecompute();
 var best=null,bd=Math.max(pxTolMm(5),0.12);
 (PCB.links||[]).forEach(function(l){
  if(l.k==="proximity"||l.done||!l.net)return;
  var a=wpt(l.a,l.ax,l.ay),b=wpt(l.b,l.bx,l.by),d=ptSegDist(m.x,m.y,a.x,a.y,b.x,b.y);
  if(d<bd){bd=d;best=l.net;}});
 return best;}

// ── Click-and-hold exact-object picker ─────────────────────────────────
// Normal clicks deliberately keep their fast precedence ladder. A stationary
// primary press waits briefly, then enumerates EVERY visible, filter-enabled
// object under the pointer. If at least two are present, the still-unmoved
// drag/marquee is cancelled and a compact menu lets the user bypass hierarchy
// and priority to name the exact target. Candidate collection is deferred
// until the timer fires, so ordinary clicks and drags pay no dense-board scan.
var PICK_HOLD_MS=450,PICK_SLOP_PX=5,pickHold=null,pickMenu=null,pickPreview=null;
function pickPartHits(m){var out=[];
 P.forEach(function(p,i){if(!partOnVisibleFace(p)||!reviewPartOnShownSide(p))return;
  var a=-(p.rot||0)*Math.PI/180,c=Math.cos(a),sn=Math.sin(a),lx=m.x-p.x,ly=m.y-p.y;
  var rx=lx*c-ly*sn,ry=lx*sn+ly*c;if(p.side==="bottom")rx=-rx;
  if(Math.abs(rx-(p.ccx||0))<=p.hw&&Math.abs(ry-(p.ccy||0))<=p.hh)out.push(i);});
 return out;}
function pickPadHits(m){var out=[];
 P.forEach(function(p,i){if(!partOnVisibleFace(p)||!reviewPartOnShownSide(p))return;
  var a=-(p.rot||0)*Math.PI/180,c=Math.cos(a),sn=Math.sin(a),lx=m.x-p.x,ly=m.y-p.y;
  var rx=lx*c-ly*sn,ry=lx*sn+ly*c;if(p.side==="bottom")rx=-rx;
  (p.pads||[]).forEach(function(pd){var hit=false;
   if(pd.poly&&pd.poly.length>=3){for(var j=0,k=pd.poly.length-1;j<pd.poly.length;k=j++){
    var u=pd.poly[j],v=pd.poly[k];if(((u[1]>ry)!==(v[1]>ry))&&(rx<(v[0]-u[0])*(ry-u[1])/(v[1]-u[1])+u[0]))hit=!hit;}}
   else{var pa=-(pd.rot||0)*Math.PI/180,pc=Math.cos(pa),ps=Math.sin(pa),dx=rx-pd.x,dy=ry-pd.y;
    var px=dx*pc-dy*ps,py=dx*ps+dy*pc;hit=Math.abs(px)<=pd.w/2&&Math.abs(py)<=pd.h/2;}
   if(!hit)return;
   if(!(pd.drill>0)&&layerAlpha(p.side==="bottom"?1:0)<=0)return;
   out.push({i:i,pd:pd});});});return out;}
function pickGroupHits(m){var out=[],pad=3/S;
 for(var g in GRPS){if(!grpRigid(g))continue;var x0=1e18,y0=1e18,x1=-1e18,y1=-1e18,n=0;
  GRPS[g].forEach(function(i){if(unplacedSet[P[i].ref]||!partOnVisibleFace(P[i]))return;var b=partAABB(i);
   x0=Math.min(x0,b.x0);y0=Math.min(y0,b.y0);x1=Math.max(x1,b.x1);y1=Math.max(y1,b.y1);n++;});
  if(n&&m.x>=x0-pad&&m.x<=x1+pad&&m.y>=y0-pad&&m.y<=y1+pad)out.push(g);}
 return out;}
function pickCandidates(m){var out=[];
 function add(kind,title,meta,data){out.push({kind:kind,title:title,meta:meta||"",data:data});}
 if(viewSt.filt.sub)pickGroupHits(m).forEach(function(g){add("Sub-circuit",g,(GRPS[g]||[]).length+" footprints",{t:"sub",g:g});});
 if(viewSt.filt.fp)pickPartHits(m).forEach(function(i){var p=P[i],leaf=refLabel(p.ref),detail=p.val||p.fp||"";
  add("Footprint",leaf,(p.ref!==leaf?p.ref+(detail?" · ":""):"")+detail,{t:"fp",i:i});});
 if(viewSt.filt.pad)pickPadHits(m).forEach(function(h){var p=P[h.i],pd=h.pd;
  add("Pad",p.ref+" · "+(pd.num||"?"),pd.net?nLeaf(pd.net):"no net",{t:"pad",i:h.i,pd:pd});});
 if(viewSt.filt.via){var vt=Math.max(pxTolMm(6),0.15);(PCB.vias||[]).forEach(function(v){
  if(Math.hypot(m.x-v.x,m.y-v.y)-(v.d||0.4)/2<vt)add("Via",v.net?nLeaf(v.net):"no net",
   n2(v.d||0.4)+" mm · @("+n2(v.x)+", "+n2(v.y)+")",{t:"via",o:v});});}
 if(viewSt.filt.track){var tt=Math.max(pxTolMm(5),0.12);(PCB.tracks||[]).forEach(function(t){
  if(layerAlpha(t.l||0)<=0)return;var d=segDist(m.x,m.y,t)-(t.w||0.25)/2;
  if(d<tt)add("Track",t.net?nLeaf(t.net):"no net",layerName(t.l||0)+" · "+n2(t.w||0.25)+" mm · ("+
   n2(t.x1)+", "+n2(t.y1)+") → ("+n2(t.x2)+", "+n2(t.y2)+")",{t:"track",o:t});});}
 if(viewSt.filt.zone&&!RO){var zt=Math.max(pxTolMm(6),0.2);(PCB.zones||[]).forEach(function(z){var poly=z.poly;
  if(!poly||poly.length<3)return;var L=reviewAreaLayer(z);if(L!=null&&layerAlpha(L)<=0)return;
  if(polyContains(poly,m.x,m.y)||nearPolyEdge(poly,m.x,m.y,zt))add(z.keepout?"Keepout":"Pour",z.name||(z.net?nLeaf(z.net):"no net"),reviewAreaLayerName(z,L),{t:z.keepout?"keepout":"zone",o:z});});
  if(viewSt.vis.keepouts)(PCB.keepouts||[]).forEach(function(q){var outer=q.outer,inner=q.inner;if(!outer||outer.length<3)return;
   var band=polyContains(outer,m.x,m.y)&&(!inner||inner.length<3||!polyContains(inner,m.x,m.y));
   if(band||nearPolyEdge(outer,m.x,m.y,zt)||(inner&&inner.length>=3&&nearPolyEdge(inner,m.x,m.y,zt)))
    add("Keepout",q.name||"Keepout area",reviewAreaLayerName(q,reviewAreaLayer(q)),{t:"keepout",o:q});});}
 if(viewSt.filt.drc){var dt=Math.max(pxTolMm(12),0.3);(PCB.drc||[]).forEach(function(d){
  if(!drcMarkerVisible(d)||d.x==null||Math.hypot(m.x-d.x,m.y-d.y)>=dt)return;
  add("DRC",d.k||"violation","#"+(d.id||"?")+(drcBetween(d)?(" · "+drcBetween(d)):""),{t:"drc",o:d});});}
 return out;}
function pickGestureCancel(){
 drag=null;gdrag=null;clickCand=null;segdrag=null;viadrag=null;osdrag=null;pan=null;
 if(marqEl&&marqEl.parentNode)marqEl.parentNode.removeChild(marqEl);marqEl=null;marq=null;
 svg.style.cursor="";}
function pickPreviewSet(c){var next=c?c.data:null;if(pickPreview===next)return;pickPreview=next;paintSoon();}
function pickMenuClose(){pickPreviewSet(null);if(pickMenu&&pickMenu.parentNode)pickMenu.parentNode.removeChild(pickMenu);pickMenu=null;}
// ── Two-track fillet context menu ──────────────────────────────────────
// Ctrl/Cmd-click and marquee selection both land in selCu, so the command is
// available regardless of how the pair was selected. Right-click first shows
// the action menu; choosing Fillet reveals the radius field and explicit Apply.
function traceFilletSelectionReady(){return selCu.t.length===2&&!selCu.v.length&&!sel.length;}
function traceFilletDefault(c){var custom=parseFloat((document.getElementById("r-br")||{}).value),r=custom>0?custom:3*(c.t1.w||.25);
 return Math.max(.001,traceFilletRadiusLimit(Math.min(r,c.maxRadius)));}
function traceFilletReplace(pair,radius){var t1=pair[0],t2=pair[1],plan=traceFilletPlan(t1,t2,radius);
 if(!plan.ok)return plan;var base=PCB.tracks||[],after=base.filter(function(t){return t!==t1&&t!==t2;});
 plan.arc.id=trackIdNew();after=after.concat([plan.first,plan.arc,plan.second]);
 if(drcGateDiffBlocks(base,PCB.vias||[],after,PCB.vias||[]))return {ok:false,error:"Fillet would create a DRC error."};
 var snap=snapAll();recordUndo(snap);rfDropForTracks(pair);PCB.tracks=after;copperTouched();
 routeStatMsg("fillet applied · R"+plan.radius.toFixed(3)+" mm — Save/Update to keep");scheduleDrc();paintSoon();return plan;}
function traceFilletMenuPosition(menu,at){var hr=sceneShell.getBoundingClientRect(),x=at.clientX-hr.left+12,y=at.clientY-hr.top+12;
 x=Math.max(6,Math.min(x,Math.max(6,hr.width-menu.offsetWidth-6)));y=Math.max(6,Math.min(y,Math.max(6,hr.height-menu.offsetHeight-6)));
 menu.style.left=x+"px";menu.style.top=y+"px";}
function traceFilletMenuOpen(at){pickMenuClose();var pair=selCu.t.slice(),c=traceFilletContext(pair[0],pair[1]),limit=c.ok?traceFilletRadiusLimit(c.maxRadius):0,menu=document.createElement("div");
 menu.className="pcb-pick-menu pcb-trace-menu";menu.setAttribute("role","menu");menu.setAttribute("aria-label","Trace actions");
 menu.innerHTML='<div class="pcb-pick-head"><b>2 trace segments</b><span>'+pEsc((pair[0].net||"")?nLeaf(pair[0].net):"no net")+'</span></div>'+
  '<button type="button" class="pcb-pick-item pcb-trace-fillet" role="menuitem"'+(c.ok?'':' disabled')+'><span class="pcb-pick-kind">Modify</span><span class="pcb-pick-copy"><b>Fillet…</b><small>'+pEsc(c.ok?("tangent arc · max R"+limit.toFixed(3)+" mm"):c.error)+'</small></span></button>';
 sceneShell.appendChild(menu);pickMenu=menu;traceFilletMenuPosition(menu,at);var action=menu.querySelector(".pcb-trace-fillet");
 action.addEventListener("click",function(){if(!c.ok)return;var initial=traceFilletDefault(c);
  menu.innerHTML='<form class="pcb-trace-form"><div class="pcb-pick-head"><b>Fillet radius</b><span>mm</span></div><label>Radius <span><input name="radius" type="number" min="0.001" max="'+limit.toFixed(3)+'" step="0.001" value="'+initial.toFixed(3)+'" required> mm</span></label><small class="pcb-trace-limit">Maximum for these segments: '+limit.toFixed(3)+' mm</small><div class="pcb-trace-error" role="alert"></div><div class="pcb-trace-buttons"><button type="button" class="btn" data-fillet-cancel>Cancel</button><button type="submit" class="btn primary">Apply</button></div></form>';
  traceFilletMenuPosition(menu,at);var form=menu.querySelector("form"),input=form.elements.radius,err=menu.querySelector(".pcb-trace-error");
  menu.querySelector("[data-fillet-cancel]").addEventListener("click",pickMenuClose);
  form.addEventListener("submit",function(ev){ev.preventDefault();var result=traceFilletReplace(pair,parseFloat(input.value));
   if(!result.ok){err.textContent=result.error;input.focus();return;}pickMenuClose();});input.focus();input.select();});
 if(c.ok)action.focus();}
function pickSelect(c,at){var d=c.data;pickMenuClose();inspClear();selCuClear();selClear();clearSel();window.PCBSelNet(null);
 if(d.t==="sub"){selectGroup(d.g);return;}
 if(d.t==="fp"){selGroup=null;selectComp(P[d.i].ref);return;}
 if(d.t==="pad"){selGroup=null;selectComp(P[d.i].ref);if(d.pd.net)window.PCBSelNet(d.pd.net);return;}
 inspShow({t:d.t,o:d.o},at);}
function pickMenuOpen(items,at){pickMenuClose();var host=sceneShell;if(!host)return;
 var menu=document.createElement("div");menu.className="pcb-pick-menu";menu.setAttribute("role","menu");
 menu.setAttribute("aria-label","Select exact object");
 var h='<div class="pcb-pick-head"><b>Select exact object</b><span>'+items.length+' objects here</span></div>';
 items.forEach(function(c,i){h+='<button type="button" class="pcb-pick-item" role="menuitem" data-pick="'+i+
  '" title="'+pEsc(c.kind+": "+c.title+(c.meta?" — "+c.meta:""))+'">'+
  '<span class="pcb-pick-kind">'+pEsc(c.kind)+'</span><span class="pcb-pick-copy"><b>'+pEsc(c.title)+
  '</b>'+(c.meta?'<small>'+pEsc(c.meta)+'</small>':'')+'</span></button>';});
 menu.innerHTML=h;host.appendChild(menu);pickMenu=menu;
 var hr=host.getBoundingClientRect(),x=at.clientX-hr.left+12,y=at.clientY-hr.top+12;
 x=Math.max(6,Math.min(x,Math.max(6,hr.width-menu.offsetWidth-6)));
 y=Math.max(6,Math.min(y,Math.max(6,hr.height-menu.offsetHeight-6)));
 menu.style.left=x+"px";menu.style.top=y+"px";
 var buttons=[].slice.call(menu.querySelectorAll("[data-pick]"));buttons.forEach(function(b){var c=items[+b.getAttribute("data-pick")];
  b.addEventListener("pointerenter",function(){pickPreviewSet(c);});
  b.addEventListener("focus",function(){pickPreviewSet(c);});
  b.addEventListener("click",function(ev){ev.stopPropagation();pickSelect(c,at);});});
 menu.addEventListener("pointerleave",function(){pickPreviewSet(null);});
 menu.addEventListener("focusout",function(ev){if(!menu.contains(ev.relatedTarget))pickPreviewSet(null);});
 menu.addEventListener("keydown",function(ev){var i=buttons.indexOf(document.activeElement);
  if(ev.key==="Escape"){ev.preventDefault();ev.stopPropagation();pickMenuClose();try{svg.focus();}catch(e){}return;}
  if(ev.key!=="ArrowDown"&&ev.key!=="ArrowUp")return;ev.preventDefault();
  i=(i+(ev.key==="ArrowDown"?1:-1)+buttons.length)%buttons.length;buttons[i].focus();});
 if(buttons.length)buttons[0].focus();}
function pickHoldArm(ev,m){pickHoldCancel();var h={id:ev.pointerId,cx:ev.clientX,cy:ev.clientY,m:m,
  at:{clientX:ev.clientX,clientY:ev.clientY},open:false,timer:null};pickHold=h;
 h.timer=setTimeout(function(){if(pickHold!==h)return;h.timer=null;var items=pickCandidates(h.m);
  if(items.length<2)return;h.open=true;pickGestureCancel();pickMenuOpen(items,h.at);},PICK_HOLD_MS);}
function pickHoldMove(ev){var h=pickHold;if(!h||h.id!==ev.pointerId||h.open)return;
 if(Math.hypot(ev.clientX-h.cx,ev.clientY-h.cy)>PICK_SLOP_PX)pickHoldCancel(ev.pointerId);}
function pickHoldCancel(id){var h=pickHold;if(!h||(id!=null&&h.id!==id))return;
 if(h.timer!=null)clearTimeout(h.timer);pickHold=null;}
function pickHoldRelease(ev){var h=pickHold;if(!h||h.id!==ev.pointerId)return false;
 if(h.timer!=null)clearTimeout(h.timer);pickHold=null;return h.open;}
document.addEventListener("pointerdown",function(ev){if(pickMenu&&!pickMenu.contains(ev.target))pickMenuClose();});
document.addEventListener("keydown",function(ev){if(ev.key==="Escape"&&pickMenu)pickMenuClose();});
function anyDrawTool(){return drawMode||textMode||polyMode||pourMode||outlineMode||backingMode||heatsinkMode||padAlignMode||!!PCB.rulerOn;}
function n2(v){return (+v).toFixed(2);}
// Net→class resolution is per track, per via and per pad on every keepout
// frame, so the two linear passes are indexed instead. Priority is the pass
// order it replaces: an exact spelling ANYWHERE beats a dot-collapsed match
// anywhere, and within each pass the first declaring class wins. Null-prototype
// maps so a net named `constructor` cannot resolve to Object.prototype's.
// Keyed on the array reference, so replacing PCB.netclasses rebuilds by itself.
var ncIdx=null;
function ncIndex(){var L=PCB.netclasses||[];if(ncIdx&&ncIdx.src===L)return ncIdx;
 var ex=Object.create(null),co=Object.create(null),halo=false;
 for(var i=0;i<L.length;i++){var c=L[i],k=netCollapse(c.net);
  if(ex[c.net]===undefined)ex[c.net]=c;
  if(co[k]===undefined)co[k]=c;
  if(rfKeepoutWidth(c)>0)halo=true;}
 ncIdx={src:L,exact:ex,coll:co,halo:halo};return ncIdx;}
function netClassInfo(net){var ix=ncIndex();
 return ix.exact[net]||ix.coll[netCollapse(net)]||null;}
var traceEmIdx=null,traceEmDirty=false,powerIntegrityIdx=null,powerIntegrityDirty=false;
function traceEmInfo(net){if(!traceEmIdx){traceEmIdx={exact:{},coll:{}};
 ((PCB.trace_em&&PCB.trace_em.analyses)||[]).forEach(function(a){traceEmIdx.exact[a.net]=a;var k=netCollapse(a.net);if(traceEmIdx.coll[k]===undefined)traceEmIdx.coll[k]=a;});}
 return traceEmIdx.exact[net]||traceEmIdx.coll[netCollapse(net)]||null;}
function traceEmSection(a,o){var tol=1e-4,hit=null;if(!a)return null;
 (a.sections||[]).some(function(s){if(Number(s.l)!==Number(o.l||0))return false;
  var f=Math.abs(s.x1-o.x1)<=tol&&Math.abs(s.y1-o.y1)<=tol&&Math.abs(s.x2-o.x2)<=tol&&Math.abs(s.y2-o.y2)<=tol;
  var r=Math.abs(s.x1-o.x2)<=tol&&Math.abs(s.y1-o.y2)<=tol&&Math.abs(s.x2-o.x1)<=tol&&Math.abs(s.y2-o.y1)<=tol;
  if(f||r){hit=s;return true;}return false;});return hit;}
function emFreq(v){if(v>=1e9)return n2(v/1e9)+" GHz";if(v>=1e6)return n2(v/1e6)+" MHz";if(v>=1e3)return n2(v/1e3)+" kHz";return n2(v)+" Hz";}
function emChart(samples,key,max,label,color){if(!samples||samples.length<2)return "";var W=286,H=96,L=31,R=7,T=8,B=20,pts=[];
 samples.forEach(function(s,i){var x=L+(W-L-R)*i/(samples.length-1),v=Math.max(0,Math.min(max,Number(s[key])||0)),y=T+(H-T-B)*(1-v/max);pts.push(x.toFixed(1)+","+y.toFixed(1));});
 return '<div class="em-chart"><div class="em-chart-title"><span>'+pEsc(label)+'</span><b>0 – '+pEsc(n2(max))+' dB</b></div><svg viewBox="0 0 '+W+' '+H+'" role="img" aria-label="'+pEsc(label)+' across frequency"><path class="em-grid" d="M'+L+' '+T+'V'+(H-B)+'H'+(W-R)+'M'+L+' '+(T+(H-T-B)/2)+'H'+(W-R)+'"/><polyline fill="none" stroke="'+color+'" stroke-width="2" points="'+pts.join(" ")+'"/><text x="'+L+'" y="'+(H-5)+'">'+pEsc(emFreq(samples[0].frequency_hz))+'</text><text text-anchor="end" x="'+(W-R)+'" y="'+(H-5)+'">'+pEsc(emFreq(samples[samples.length-1].frequency_hz))+'</text></svg></div>';}
function traceEmPanel(o,tc){var a=traceEmInfo(o.net||"");
 if(traceEmDirty&&a)return '<section class="em-panel"><div class="em-head">2.5D trace analysis</div><div class="em-state bad">Copper changed after this sweep was computed. Save and reload the layout to analyze the edited route.</div></section>';
 if(!a){if(tc&&Number(tc.impedance_ohms)>0)return '<section class="em-panel"><div class="em-head">2.5D trace analysis</div><div class="em-state bad">No result is available for this copper. Save or reload the routed layout to analyze its current geometry.</div></section>';return "";}
 var s=traceEmSection(a,o),model=(PCB.trace_em&&PCB.trace_em.model)||"2.5D quasi-TEM";
 if(a.status!=="ok"){var why={"no-copper":"This net has no routed copper.","no-stackup":"A physical stackup and reference plane are required.","unsupported-geometry":"At least one section is outside the transmission-line model's supported geometry.","unsupported-topology":"The copper is branched, looped, or disconnected; a two-port sweep needs one continuous point-to-point path."}[a.status]||"The route could not be analyzed.";
  return '<section class="em-panel"><div class="em-head">'+pEsc(model)+' trace analysis</div>'+(s?'<div class="em-local"><span>Clicked section Z₀</span><strong>'+n2(s.z0_ohms)+' Ω</strong></div>':"")+'<div class="em-state bad">'+pEsc(why)+'</div></section>';}
 var sw=a.sweep||[],last=sw.length?sw[sw.length-1]:null,rlMax=Math.max(40,Math.ceil(Number(a.return_loss_target_db)||20)),ilMax=Math.max(1,Math.ceil(Number(a.worst_insertion_loss_db)||0)),capped=Number(a.ground_gap_capped_length_mm)>0;
 var pass=Number(a.worst_return_loss_db)>=Number(a.return_loss_target_db),local=s?n2(s.z0_ohms)+" Ω":"—",structure=s?String(s.structure||"").replace("grounded-coplanar","Grounded CPWG"):"—";
 var h='<section class="em-panel"><div class="em-head"><span>'+pEsc(model)+' trace analysis</span><span class="em-pill '+(pass?'pass':'fail')+'">'+(pass?'meets':'misses')+' RL target</span></div>'+
  '<div class="em-local"><span>Clicked section Z₀</span><strong>'+pEsc(local)+'</strong><small>'+pEsc(structure)+(s?' · GND gap '+n2(s.ground_gap_mm)+' mm'+(s.gap_capped?' (cap)':'')+' · εeff '+n2(s.er_eff):'')+'</small></div><div class="prop-rows">'+
  pRow("Target",n2(a.target_ohms)+" Ω")+pRow("Route Z₀",n2(a.z0_min_ohms)+" – "+n2(a.z0_max_ohms)+" Ω")+pRow("Length-weighted Z₀",n2(a.z0_weighted_ohms)+" Ω")+
  pRow("GND gap profile",Number(a.ground_gap_min_mm)>0?n2(a.ground_gap_min_mm)+" – "+n2(a.ground_gap_used_max_mm)+" mm":"none")+(capped?pRow("At gap cap",n2(a.ground_gap_capped_length_mm)+" mm of route"):"")+pRow("Path",n2(a.total_length_mm)+" mm · "+a.via_count+" via"+(a.via_count===1?"":"s"))+pRow("Delay",n2(a.delay_ps)+" ps")+
  pRow("Worst return loss",n2(a.worst_return_loss_db)+" dB (target "+n2(a.return_loss_target_db)+" dB)")+pRow("Worst insertion loss",n2(a.worst_insertion_loss_db)+" dB")+
  (last?pRow("Zin @ "+emFreq(last.frequency_hz),n2(last.zin_re_ohms)+(last.zin_im_ohms<0?" − j":" + j")+n2(Math.abs(last.zin_im_ohms))+" Ω"):"")+'</div>'+(capped?'<div class="em-state warn">The variable GND opening reaches its '+n2(a.ground_gap_max_mm)+' mm cap here. These wider sections remain below the impedance target without a backing-plane change.</div>':'')+
  emChart(sw,"return_loss_db",rlMax,"Return loss · higher is better","#6fb1ff")+emChart(sw,"insertion_loss_db",ilMax,"Insertion loss · lower is better","#e3b341")+
  '<div class="em-limit">Uses actual routed widths, stackup, locally synthesized CPWG gap, skin effect, dielectric loss, and lumped vias. The pour generator uses the same gap profile. Assumes FR-4 tanδ 0.02; excludes solder mask, copper roughness, radiation, connector launches, fixed ground pads, and nearby-copper coupling. Use 3D EM or measurement for sign-off.</div></section>';return h;}
function powerIntegrityInfo(net){if(!powerIntegrityIdx){powerIntegrityIdx={exact:Object.create(null),coll:Object.create(null)};
 ((PCB.power_integrity&&PCB.power_integrity.nets)||[]).forEach(function(a){powerIntegrityIdx.exact[a.net]=a;var k=netCollapse(a.net);if(powerIntegrityIdx.coll[k]===undefined)powerIntegrityIdx.coll[k]=a;});}
 return powerIntegrityIdx.exact[net]||powerIntegrityIdx.coll[netCollapse(net)]||null;}
function pdnInfo(net){var ac=(PCB.power_integrity&&PCB.power_integrity.ac)||{},rails=ac.rails||[],exact=null,collapsed=null,k=netCollapse(net||"");
 rails.some(function(r){if(r.net===net){exact=r;return true;}if(collapsed===null&&netCollapse(r.net)===k)collapsed=r;return false;});return exact||collapsed;}
function pdnOhms(v){v=Number(v);if(v>=1)return n2(v)+" Ω";if(v>=.001)return n2(v*1000)+" mΩ";return n2(v*1e6)+" µΩ";}
function pdnChart(a){var s=a.points||[];if(s.length<2)return "";var W=286,H=116,L=39,R=8,T=9,B=20,zs=s.map(function(p){return Math.max(1e-9,Number(p[1])||1e-9);}),target=a.target_ohm==null?null:Math.max(1e-9,Number(a.target_ohm)),lo=Math.min.apply(null,zs.concat(target==null?[]:[target])),hi=Math.max.apply(null,zs.concat(target==null?[]:[target]));
 lo=Math.pow(10,Math.floor(Math.log(lo)/Math.LN10));hi=Math.pow(10,Math.ceil(Math.log(hi)/Math.LN10));if(!(hi>lo))hi=lo*10;
 function yy(v){return T+(H-T-B)*(1-(Math.log(Math.max(lo,v)/lo)/Math.log(hi/lo)));}var pts=[];zs.forEach(function(z,i){pts.push((L+(W-L-R)*i/(zs.length-1)).toFixed(1)+","+yy(z).toFixed(1));});
 var targetLine=target==null?"":'<path d="M'+L+' '+yy(target).toFixed(1)+'H'+(W-R)+'" stroke="#e3b341" stroke-width="1.3" stroke-dasharray="4 3"/><text x="'+(L+3)+'" y="'+(yy(target)-3).toFixed(1)+'">target '+pEsc(pdnOhms(target))+'</text>',marks="";(a.peaks||[]).forEach(function(q){var fi=0,best=Infinity;s.forEach(function(p,i){var d=Math.abs(Math.log(Number(p[0])/Number(q.frequency_hz)));if(d<best){best=d;fi=i;}});var x=L+(W-L-R)*fi/(s.length-1),y=yy(Number(q.magnitude_ohm));marks+='<circle cx="'+x.toFixed(1)+'" cy="'+y.toFixed(1)+'" r="2.7" fill="'+(q.above_target?'#f08888':'#e3b341')+'"/>';});
 return '<div class="em-chart"><div class="em-chart-title"><span>Z(f) at load · log scale</span><b>'+pEsc(pdnOhms(lo))+' – '+pEsc(pdnOhms(hi))+'</b></div><svg viewBox="0 0 '+W+' '+H+'" role="img" aria-label="PDN impedance across frequency"><path class="em-grid" d="M'+L+' '+T+'V'+(H-B)+'H'+(W-R)+'M'+L+' '+yy(Math.sqrt(lo*hi)).toFixed(1)+'H'+(W-R)+'"/>'+targetLine+'<polyline fill="none" stroke="#6fb1ff" stroke-width="2" points="'+pts.join(" ")+'"/>'+marks+'<text x="'+L+'" y="'+(H-5)+'">'+pEsc(emFreq(s[0][0]))+'</text><text text-anchor="end" x="'+(W-R)+'" y="'+(H-5)+'">'+pEsc(emFreq(s[s.length-1][0]))+'</text></svg></div>';}
function pdnPanel(net){var a=pdnInfo(net);if(!a)return "";if(powerIntegrityDirty)return '<section class="em-panel"><div class="em-head">PDN impedance</div><div class="em-state bad">Copper changed after this sweep was computed. Save and reload to refresh mounting inductance and Z(f).</div></section>';
 var pass=a.passes===true,known=a.passes!==null,pill='<span class="em-pill'+(known?(pass?' pass':' fail'):'')+'">'+(known?(pass?'meets target':'exceeds target'):'target incomplete')+'</span>',rows=pRow("Ripple budget",n2(Number(a.ripple_v)*1000)+" mV")+pRow("Load step",a.step_current_a==null?"not declared":powerIntegrityAmps(a.step_current_a)+(a.step_assumed?" (inferred)":""))+pRow("Target Z",a.target_ohm==null?"—":pdnOhms(a.target_ohm))+pRow("Valid through",emFreq(a.verdict_max_hz))+pRow("Source model",pdnOhms(a.source_resistance_ohm)+" + "+n2(Number(a.source_inductance_h)*1e9)+" nH"+(a.source_assumed?" (estimated)":""));
 var state="";if(!known)state='<div class="em-state warn">Add a positive <code>step-current-a</code>, or annotate typical/maximum rail current, to obtain a target-impedance verdict.</div>';else if(!pass)state='<div class="em-state bad">The worst impedance exceeds ΔV/ΔI. Inspect the marked anti-resonances and low-impact capacitors below.</div>';
 var caps=(a.capacitors||[]).slice().sort(function(x,y){return Number(x.removal_impact_db)-Number(y.removal_impact_db);}),capRows="";caps.slice(0,12).forEach(function(c){var bad=c.ineffective?' class="pdn-cap-bad"':'',why=c.ineffective?' · mounting-limited':'',model=c.model_estimated?' · estimated model':'',pin=c.target_pin?(' pin '+c.target_pin):"";capRows+='<div'+bad+'><strong>'+pEsc(c.ref)+' · '+pEsc(c.value)+'</strong><span>'+n2(Number(c.mounting_inductance_h)*1e9)+' nH mount · SRF '+pEsc(emFreq(c.mounted_srf_hz))+' · removal '+n2(c.removal_impact_db)+' dB'+why+model+'</span><small>to '+pEsc(c.target_ref)+pEsc(pin)+' · power '+n2(c.power_path_mm)+' mm · ground '+n2(c.ground_path_mm)+' mm · '+pEsc(c.model_source)+'</small></div>';});
 var peak=(a.peaks||[]).filter(function(p){return p.above_target;}),peakText=peak.length?pRow("Above-target peaks",peak.map(function(p){return emFreq(p.frequency_hz)+" / "+pdnOhms(p.magnitude_ohm);}).join(", ")):"";
 return '<section class="em-panel"><div class="em-head"><span>PDN impedance · routed RLC</span>'+pill+'</div><div class="em-local"><span>Worst Z through edge bandwidth</span><strong>'+pEsc(pdnOhms(a.worst_magnitude_ohm))+'</strong><small>at '+pEsc(emFreq(a.worst_frequency_hz))+' · '+(a.capacitors||[]).length+' modeled capacitor'+((a.capacitors||[]).length===1?'':'s')+'</small></div><div class="prop-rows">'+rows+peakText+'</div>'+state+pdnChart(a)+(capRows?'<div class="pdn-cap-list">'+capRows+'</div>':'<div class="em-state warn">No bound decoupling capacitors were extracted on this physical domain.</div>')+'<div class="pdn-actions"><button id="pdn-spice" class="btn" data-pdn-net="'+pEsc(a.net)+'">Download SPICE subcircuit</button></div><div class="em-limit">Series RLC branches use selected-BOM C/ESR/ESL plus routed pad/trace/via and stackup-derived mounting inductance. This fast screen excludes regulator control-loop dynamics, package/on-die impedance, distributed plane-cavity modes and coupling; use the SPICE bridge, 3D EM, or VNA measurement for sign-off.</div></section>';}
function pdnDownload(net){var a=pdnInfo(net);if(!a||!a.spice)return;var blob=new Blob([a.spice],{type:"text/plain"}),url=URL.createObjectURL(blob),link=document.createElement("a");link.href=url;link.download="pdn-"+String(a.net||"rail").replace(/[^A-Za-z0-9_.-]+/g,"_")+".cir";document.body.appendChild(link);link.click();link.remove();setTimeout(function(){URL.revokeObjectURL(url);},0);}
function powerIntegrityTrack(a,o){var hit=null,tol=1e-4;if(!a)return null;(a.tracks||[]).some(function(s){if(Number(s.l)!==Number(o.l||0))return false;
  var f=Math.abs(s.x1-o.x1)<=tol&&Math.abs(s.y1-o.y1)<=tol&&Math.abs(s.x2-o.x2)<=tol&&Math.abs(s.y2-o.y2)<=tol;
  var r=Math.abs(s.x1-o.x2)<=tol&&Math.abs(s.y1-o.y2)<=tol&&Math.abs(s.x2-o.x1)<=tol&&Math.abs(s.y2-o.y1)<=tol;
  if(f||r){hit=s;return true;}return false;});return hit;}
function powerIntegrityVia(a,o){var hit=null,tol=1e-4;if(!a)return null;(a.vias||[]).some(function(v){if(Math.abs(v.x-o.x)<=tol&&Math.abs(v.y-o.y)<=tol){hit=v;return true;}return false;});return hit;}
function powerIntegrityLayer(i){var row=stackByIndex(Number(i));return row?row.name:"copper "+i;}
function powerIntegrityAmps(v){v=Number(v);if(Math.abs(v)>=1)return n2(v)+" A";if(Math.abs(v)>=0.001)return n2(v*1000)+" mA";return n2(v*1000000)+" µA";}
function powerIntegrityPanel(o,kind){var a=powerIntegrityInfo(o.net||"");if(!a)return "";
 if(powerIntegrityDirty)return '<section class="em-panel"><div class="em-head">Power handling</div><div class="em-state bad">Copper changed after this screen was computed. Save and reload the layout to refresh its capacity.</div></section>';
 var g=kind==="track"?powerIntegrityTrack(a,o):powerIntegrityVia(a,o);if(!g)return "";
 var useMax=a.demand_maximum_a!=null&&(a.demand_typical_a==null||Number(a.demand_maximum_a)>=Number(a.demand_typical_a)),status=useMax?a.flow_maximum_status:a.flow_typical_status;
 var demand=useMax?Number(a.demand_maximum_a):(a.demand_typical_a!=null?Number(a.demand_typical_a):null);
 var local=useMax?g.current_maximum_a:g.current_typical_a,solved=status==="solved"&&local!=null;
 var screened=solved?Number(local):demand,cap=Number(g.capacity_a)||0,known=screened!=null,pass=known&&cap>=screened;
 var pill=!known?'<span class="em-pill">load not declared</span>':'<span class="em-pill '+(pass?'pass':'fail')+'">'+(pass?'meets':'below')+' '+(solved?'branch current':'rail envelope')+'</span>';
 var title=kind==="track"?"Clicked trace capacity":"Clicked via capacity";
 var detail=kind==="track"?(n2(g.width_mm)+' mm wide · '+n2(g.foil_mm*1000)+' µm foil · '+powerIntegrityLayer(g.physical_layer)):(n2(g.drill_mm)+' mm drill · '+n2(g.plating_mm*1000)+' µm plating');
 var typ=a.demand_typical_a!=null?powerIntegrityAmps(a.demand_typical_a):"not declared",max=a.demand_maximum_a!=null?powerIntegrityAmps(a.demand_maximum_a):"not declared";
 var localTyp=g.current_typical_a!=null?powerIntegrityAmps(g.current_typical_a):"—",localMax=g.current_maximum_a!=null?powerIntegrityAmps(g.current_maximum_a):"—";
 var dropTyp=g.drop_typical_v!=null?n2(g.drop_typical_v*1000)+" mV":"—",dropMax=g.drop_maximum_v!=null?n2(g.drop_maximum_v*1000)+" mV":"—";
 var method=solved?"Solved resistive branch current":"Conservative whole-rail fallback ("+(status||"unresolved")+")";
 var rows=pRow("Typical rail load",typ)+pRow("Maximum rail load",max)+pRow("Local current · typical",localTyp)+pRow("Local current · maximum",localMax)+pRow("Local drop · typical",dropTyp)+pRow("Local drop · maximum",dropMax)+pRow("Current method",method)+((a.source_terminals||[]).length?pRow("Physical source",a.source_terminals.join(", ")):"")+(a.source?pRow("Rated rail source",a.source):"")+pRow("Conductor resistance",n2(g.resistance_mohm)+" mΩ");
 if(kind==="track")rows+=pRow("Required width · typical",g.required_width_typical_mm!=null?n2(g.required_width_typical_mm)+" mm":"—")+pRow("Required width · maximum",g.required_width_maximum_mm!=null?n2(g.required_width_maximum_mm)+" mm":"—");
 else rows+=pRow("Required vias · typical",g.required_count_typical!=null?String(g.required_count_typical):"—")+pRow("Required vias · maximum",g.required_count_maximum!=null?String(g.required_count_maximum):"—");
 var planes="",surfaceUnproven=false;(a.planes||[]).forEach(function(p){var neck=p.required_neck_typical_mm!=null?" · "+n2(p.required_neck_typical_mm)+" mm typ neck":"";if(p.required_neck_maximum_mm!=null)neck+=" · "+n2(p.required_neck_maximum_mm)+" mm max neck";var ps=useMax?p.maximum_status:p.typical_status;if(ps==="not-proven")surfaceUnproven=true;var label=(p.kind==="user-pour"?"User pour":p.kind==="pour"?"Pour":"Plane")+" "+powerIntegrityLayer(p.physical_layer);var rule=" · "+n2(p.design_min_width_mm)+" mm rule = "+powerIntegrityAmps(p.capacity_at_design_min_a);var proof=ps==="verified"?" · verified":ps==="not-proven"?" · not proven":"";planes+=pRow(label,n2(p.capacity_a_per_mm)+" A/mm"+neck+rule+proof);});
 var why={"no-source-terminal":"No physical source pad could be resolved.","incomplete-load-terminals":"At least one annotated load could not be mapped to pads on this routed net.","disconnected":"The computed trace, via, plane, and pour copper does not connect every load to the source.","singular":"The routed resistance graph could not be solved."}[status]||"";
 var state=!known?'<div class="em-state warn">Capacity is calculated, but this design declares no load current for the rail. Add <code>i-typ</code> / <code>i-max</code> annotations to obtain a meaningful pass/fail result.</div>':(!pass?'<div class="em-state bad">The '+(solved?'solved local branch current':'conservative full-rail envelope')+' exceeds this conductor’s screened capacity. Widen the trace or add parallel vias.</div>':(!solved&&why?'<div class="em-state warn">'+pEsc(why)+' The capacity check therefore uses the full rail load on this conductor.</div>':""));if(surfaceUnproven)state+='<div class="em-state warn">The generated plane/pour is included in connectivity, but its enforced minimum width is below the full-rail neck required at 10°C rise. Inspect the actual neck or increase <code>pour-min-width</code> before calling the whole rail verified.</div>';
 return '<section class="em-panel"><div class="em-head"><span>Power handling · 10°C rise</span>'+pill+'</div><div class="em-local"><span>'+title+'</span><strong>'+n2(cap)+' A</strong><small>'+pEsc(detail)+'</small></div><div class="prop-rows">'+rows+planes+'</div>'+state+
  '<div class="em-limit">IPC-2221 continuous-current screening with the board’s actual copper foil and '+n2(Number((((PCB.power_integrity||{}).assumptions)||{}).via_plating_mm))+' mm via plating thickness. Branch currents use a KCL solve over traces, vias, and the actual clearance-carved fill components. Short fanouts are checked at that solved local current; their length reduces resistance and voltage drop, but does not relax the cross-section screen. A plane/pour capacity is verified only when the enforced pour minimum width carries the full rail load; this is not a sheet current-density field solve. Verify ambient, airflow, transient duty cycle, and current sharing before fabrication sign-off.</div></section>';}
// Differential-pair partner + gap for a copper net, or null. Keys by the same
// dot-collapsed spelling as netclasses so a per-stub net still resolves.
function diffPairInfo(net){var key=netCollapse(net||""),hit=null;
 (PCB.diffpairs||[]).some(function(d){
  if(netCollapse(d.p)===key){hit={partner:d.n,gap:d.gap};return true;}
  if(netCollapse(d.n)===key){hit={partner:d.p,gap:d.gap};return true;}return false;});return hit;}
// A DRC violation's copper layer, when the checker set one (`l` on the wire).
// Per-layer rules — two tracks crossing, a track over a foreign land, two
// same-face pads — name their layer; a courtyard clash, a hole rule or a
// through-barrel pair have none and print nothing.
function drcLayerRow(o){return (o&&typeof o.l==="number")?pRow("Layer",layerName(o.l)):"";}
function drcLayerSuffix(o){return (o&&typeof o.l==="number")?(" on "+layerName(o.l)):"";}
function routeSourceLabel(source){return {human:"Human drawn",agent:"AI agent",autorouter:"Autorouter",imported:"KiCad import"}[source]||"Unknown (legacy)";}
function inspReport(){if(!insp)return "";var o=insp.o;
 if(insp.t=="track")return "track id="+trackIdEnsure(o)+" net="+(o.net||"?")+" "+layerName(o.l||0)+
  " w="+n2(o.w||0.25)+"mm ("+n2(o.x1)+","+n2(o.y1)+")→("+n2(o.x2)+","+n2(o.y2)+
  ") len="+n2(Math.hypot(o.x2-o.x1,o.y2-o.y1))+"mm source="+routeSourceLabel(o.source)+(o.g?" stamp="+o.g:"");
 if(insp.t=="via")return "via id="+viaIdEnsure(o)+" net="+(o.net||"?")+" @("+n2(o.x)+","+n2(o.y)+
  ") Ø"+n2(o.d||0.4)+"/"+n2((o.drill>0)?o.drill:viaGeo().drill)+"mm source="+routeSourceLabel(o.source);
 if(insp.t=="keepout"){var L=reviewAreaLayer(o),ln=reviewAreaLayerName(o,L);
  return "keepout "+(o.name||"area")+" "+ln+(o.clearance!=null?(" clearance="+n2(o.clearance)+"mm"):"");}
 var who=drcBetween(o);
 return "DRC #"+(o.id||"?")+" "+(o.k||"violation")+" ["+(o.sev||"err")+"]"+(who?(" "+who):"")+drcLayerSuffix(o)+
  " gap "+(o.gap!=null?o.gap.toFixed(3):"?")+"mm < "+o.clr+"mm @("+n2(o.x)+","+n2(o.y)+")";}
function inspPopClose(){var p=document.getElementById("insp-pop");
 if(p&&p.parentNode)p.parentNode.removeChild(p);}
function inspClear(){if(!insp)return;insp=null;inspPopClose();renderProps();paintSoon();}
// Docked inspection: selecting copper / a DRC marker fills the sidebar
// Properties panel (renderProps branches on `insp`); the floating popover
// survives only for pages without the sidebar (embedded previews).
function inspSet(hit){inspSetHere(hit);pcbSideTab("side-props");}
// Same, minus the tab raise: the DRC pane's own rows and ‹ › steps set the
// inspector (so the Properties tab has the violation ready) without yanking the
// list out from under the click. Picking a marker on the board keeps raising
// Properties via inspSet, and syncs the DRC pane's located row either way.
function inspSetHere(hit){insp=hit;inspPopClose();
 if(hit&&hit.t=="drc"){var i=(PCB.drc||[]).indexOf(hit.o);
  if(i>=0&&i!==drcCur){drcCur=i;drcMarkCur();}}
 renderProps();paintSoon();}
function renderInspProps(body){var o=insp.o,h="",hint='<div class="prop-lock">';
 if(insp.t=="track"){
  var tc=netClassInfo(o.net||""),dp=diffPairInfo(o.net||"");
  h='<div class="prop-head"><span class="prop-ref">Track</span>'+
   (o.net?'<span class="prop-val">'+pEsc(nLeaf(o.net))+'</span>':'')+'</div>'+
   '<div class="prop-rows">'+pRow("Segment ID",trackIdEnsure(o))+pRow("Net",o.net||"?")+pRow("Layer",layerName(o.l||0))+
   pRow("Source",routeSourceLabel(o.source))+pRow("Width",n2(o.w||0.25)+" mm")+(tc?pRow("Net class",tc.class)+
   pRow("Class gap",n2(tc.clearance||PCB.clr||0)+" mm")+(tc.conflict?pRow("Class status","conflict — assign on board"):""):"")+
   (dp?pRow("Diff pair","partner "+nLeaf(dp.partner)+", gap "+n2(dp.gap||0)+" mm"):"")+
   pRow("From","("+n2(o.x1)+", "+n2(o.y1)+")")+pRow("To","("+n2(o.x2)+", "+n2(o.y2)+")")+
   pRow("Length",n2(Math.hypot(o.x2-o.x1,o.y2-o.y1))+" mm")+(o.g?pRow("Stamp",o.g):"")+'</div>';
  h+=traceEmPanel(o,tc);
  h+=powerIntegrityPanel(o,"track");
  h+=pdnPanel(o.net||"");
  if(!RO&&!mobileInspectMode())h+=hint+'Drag slides the segment (Shift = free move) · <kbd>Del</kbd> deletes · <kbd>Esc</kbd> deselects</div>';
 }else if(insp.t=="via"){
  var vc=netClassInfo(o.net||"");
  h='<div class="prop-head"><span class="prop-ref">Via</span>'+
   (o.net?'<span class="prop-val">'+pEsc(nLeaf(o.net))+'</span>':'')+'</div>'+
   '<div class="prop-rows">'+pRow("Via ID",viaIdEnsure(o))+pRow("Net",o.net||"?")+pRow("Position","("+n2(o.x)+", "+n2(o.y)+")")+
   pRow("Source",routeSourceLabel(o.source))+pRow("Diameter",n2(o.d||0.4)+" mm")+pRow("Drill",n2((o.drill>0)?o.drill:viaGeo().drill)+" mm")+
   (vc?pRow("Net class",vc.class)+pRow("Class gap",n2(vc.clearance||PCB.clr||0)+" mm"):"")+
   (o.g?pRow("Stamp",o.g):"")+'</div>';
  h+=powerIntegrityPanel(o,"via");
  h+=pdnPanel(o.net||"");
  if(!RO&&!mobileInspectMode())h+=hint+'Drag moves the via (joined tracks follow) · <kbd>Del</kbd> deletes · <kbd>Esc</kbd> deselects</div>';
 }else if(insp.t=="keepout"){
  var kl=reviewAreaLayer(o),kn=o.name||"Keepout area",layers=reviewAreaLayerName(o,kl);
  var blocks=Array.isArray(o.blocks)?o.blocks.join(", "):"";
  h='<div class="prop-head"><span class="prop-ref">'+pEsc(kn)+'</span><span class="prop-val">Keepout</span></div>'+
   '<div class="prop-rows">'+pRow("Layers",layers)+(o.clearance!=null?pRow("Clearance",n2(o.clearance)+" mm"):"")+
   (o.edge_inset!=null?pRow("Edge inset",n2(o.edge_inset)+" mm"):"")+(blocks?pRow("Blocks",blocks):"")+
   (Array.isArray(o.allow_nets)&&o.allow_nets.length?pRow("Allowed nets",o.allow_nets.join(", ")):"")+
   (o.poly?pRow("Vertices",String(o.poly.length)):"")+'</div>'+hint+
   (o.kind==="perimeter"?"Generated by the board perimeter-fence rule.":"Imported keepout geometry is read-only in this editor.")+
   ' · <kbd>Esc</kbd> deselects</div>';
 }else{
  var dwho=drcBetween(o);
  h='<div class="prop-head"><span class="prop-ref">DRC #'+pEsc(o.id||"?")+'</span>'+
   '<span class="prop-val">'+pEsc(o.k||"violation")+'</span></div>'+
   '<div class="prop-rows">'+pRow("Severity",o.sev=="warn"?"warning":"error")+
   (dwho?pRow(o.k=="net open"?"Net":"Between",dwho):"")+drcLayerRow(o)+
   pRow("Measured",o.gap!=null?o.gap.toFixed(3)+(o.k==="return loop area"?" mm²":" mm"):"?")+
   pRow("Required",(o.clr!=null?o.clr:"?")+(o.k==="return loop area"?" mm²":" mm"))+pRow("At","("+n2(o.x)+", "+n2(o.y)+")")+'</div>'+
   hint+pEsc(drcMsg(o))+'</div>';
 }
 h+='<div style="display:flex;gap:8px;padding:8px 12px">'+
  '<button id="insp-copy" class="btn" style="font-size:11px">Copy report</button>'+
  '<button id="insp-goto" class="btn" style="font-size:11px" title="Pan/zoom to it">\u2316 Locate</button></div>';
 body.innerHTML=h;
 var cb=document.getElementById("insp-copy");
 if(cb)cb.addEventListener("click",function(){
  function done(ok){cb.textContent=ok?"copied \u2713":"copy failed";}
  if(navigator.clipboard&&navigator.clipboard.writeText)
   navigator.clipboard.writeText(inspReport()).then(function(){done(true);},function(){done(false);});
  else done(false);});
 var gb=document.getElementById("insp-goto");
 if(gb)gb.addEventListener("click",function(){var q=insp&&insp.o;if(!q)return;
  if(q.bridge&&q.bridge.length===4){zoomToPoly([[q.bridge[0],q.bridge[1]],[q.bridge[2],q.bridge[3]]]);paintSoon();return;}
  if(q.x!=null){focusPoint(q.x,q.y);return;}if(q.x1!=null){focusPoint((q.x1+q.x2)/2,(q.y1+q.y2)/2);return;}
  var pts=q.poly||q.outer;if(!pts||!pts.length)return;var x=0,y=0;pts.forEach(function(p){x+=p[0];y+=p[1];});
  focusPoint(x/pts.length,y/pts.length);});
 var ps=document.getElementById("pdn-spice");if(ps)ps.addEventListener("click",function(){pdnDownload(ps.getAttribute("data-pdn-net")||"");});}
function inspShow(hit,ev){
 // A copper-zone click opens its edit dialog (net/layer/priority) instead of
 // the read-only inspector; keepouts continue into the Properties panel.
 if(hit.t==="zone"){openPourDialog(hit.o.poly,hit.o);return;}
 if(PHYSICAL_REVIEW){
  if(hit.t!=="drc"&&hit.o&&hit.o.net)selNet(hit.o.net);
  insp=null;inspPopClose();paintSoon();return;}
 if(RO&&hit.t!=="drc"&&hit.o&&hit.o.net)selNet(hit.o.net);
 if(document.getElementById("prop-body")){inspSet(hit);return;}
 insp=hit;inspPopClose();
 var host=RO?sceneHost:svg.parentNode;if(!host)return;
 var pop=document.createElement("div");pop.id="insp-pop";
 pop.style.cssText="position:absolute;z-index:40;background:#161b22;border:1px solid #30363d;"+
  "border-radius:8px;padding:8px 10px;font-size:12px;color:#d6d7db;max-width:320px;"+
  "box-shadow:0 6px 18px rgba(0,0,0,.5)";
 var title=hit.t=="drc"?("DRC #"+(hit.o.id||"?")):hit.t;
 pop.innerHTML='<div style="font-weight:700;margin-bottom:4px;color:#f0f1f3">'+pEsc(title)+'</div>'+
  '<div style="white-space:pre-wrap;word-break:break-word">'+pEsc(inspReport())+'</div>'+
  '<button id="insp-copy" class="btn" style="margin-top:6px;font-size:11px">Copy report</button>';
 host.appendChild(pop);
 var hr=host.getBoundingClientRect();
 var px=ev.clientX-hr.left+14,py=ev.clientY-hr.top+10;
 px=Math.min(px,hr.width-330);py=Math.min(py,hr.height-100); // stay inside the stage
 pop.style.left=Math.max(4,px)+"px";pop.style.top=Math.max(4,py)+"px";
 var cb=document.getElementById("insp-copy");
 if(cb)cb.addEventListener("click",function(){
  function done(ok){cb.textContent=ok?"copied ✓":"copy failed";}
  if(navigator.clipboard&&navigator.clipboard.writeText)
   navigator.clipboard.writeText(inspReport()).then(function(){done(true);},function(){done(false);});
  else done(false);});
 paintSoon();}
// Selected copper / marker highlight, painted above the copper.
function paintInsp(ctx){if(!insp)return;var o=insp.o;
 ctx.save();ctx.setLineDash([]);
 if(insp.t=="track"){ctx.lineCap="round";ctx.globalAlpha=1;ctx.strokeStyle=layerHighlightColor(o.l||0);
  ctx.lineWidth=Math.max((o.w||0.25)*S,1.2);
  ctx.beginPath();trackPath(ctx,o);ctx.stroke();}
 else if(insp.t==="keepout"){
  ctx.strokeStyle="#ffd33d";ctx.fillStyle="rgba(255,211,61,0.10)";ctx.lineWidth=2;
  ctx.globalAlpha=0.55+0.45*Math.abs(Math.sin(Date.now()/240));ctx.beginPath();
  var outer=o.poly||o.outer,inner=o.inner;
  if(outer&&outer.length>=3)keepoutPolyPath(ctx,outer);if(inner&&inner.length>=3)keepoutPolyPath(ctx,inner);
  ctx.fill("evenodd");ctx.stroke();setTimeout(paintSoon,60);}
 else if(insp.t==="drc"&&o.bridge&&o.bridge.length===4){
  var b=o.bridge,n=o.a&&o.a.net?netCollapse(o.a.net):"";
  ctx.strokeStyle=netColorOf(n)||"#ffd33d";ctx.fillStyle=ctx.strokeStyle;ctx.lineWidth=2.2;
  ctx.globalAlpha=0.65+0.35*Math.abs(Math.sin(Date.now()/240));ctx.setLineDash([8,5]);
  ctx.beginPath();ctx.moveTo(X(b[0]),Y(b[1]));ctx.lineTo(X(b[2]),Y(b[3]));ctx.stroke();ctx.setLineDash([]);
  ctx.beginPath();ctx.moveTo(X(b[0])+4,Y(b[1]));ctx.arc(X(b[0]),Y(b[1]),4,0,6.2832);
  ctx.moveTo(X(b[2])+4,Y(b[3]));ctx.arc(X(b[2]),Y(b[3]),4,0,6.2832);ctx.fill();
  setTimeout(paintSoon,60);}
 else if(insp.t!=="drc"||drcOnBoard(o)){ctx.strokeStyle="#ffd33d";var rr=(insp.t=="via")?viaRenderRadius(o.d||0.4)+4:12;
  ctx.lineWidth=2;ctx.globalAlpha=0.5+0.5*Math.abs(Math.sin(Date.now()/240));
  ctx.beginPath();ctx.arc(X(o.x),Y(o.y),rr,0,6.2832);ctx.stroke();
  setTimeout(paintSoon,60);}
 ctx.restore();}
// The exact-object menu previews its focused/hovered row without borrowing
// any real selection state. That keeps the board unchanged until click while
// giving every candidate kind one bright, topmost outline — including pads,
// which deliberately select their owning footprint only after confirmation.
function paintPickPreviewPart(ctx,i){var p=P[i];if(!p||!partOnVisibleFace(p))return;
 ctx.save();ctx.translate(X(p.x),Y(p.y));ctx.rotate((p.rot||0)*Math.PI/180);if(p.side==="bottom")ctx.scale(-1,1);
 var hw=p.hw*S,hh=p.hh*S,ccx=(p.ccx||0)*S,ccy=(p.ccy||0)*S;
 ctx.strokeRect(ccx-hw,ccy-hh,2*hw,2*hh);ctx.restore();}
function paintPickPreview(ctx){var d=pickPreview;if(!d)return;
 ctx.save();ctx.setLineDash([]);ctx.lineJoin="round";ctx.lineCap="round";
 ctx.strokeStyle="#58a6ff";ctx.fillStyle="rgba(88,166,255,.16)";ctx.lineWidth=2.6;ctx.globalAlpha=1;
 if(d.t==="sub"){
  var x0=1/0,y0=1/0,x1=-1/0,y1=-1/0,n=0;(GRPS[d.g]||[]).forEach(function(i){var p=P[i];if(!p||unplacedSet[p.ref]||!partOnVisibleFace(p))return;
   paintPickPreviewPart(ctx,i);var b=partAABB(i);x0=Math.min(x0,b.x0);y0=Math.min(y0,b.y0);x1=Math.max(x1,b.x1);y1=Math.max(y1,b.y1);n++;});
  if(n){var pd=3;ctx.lineWidth=3.2;ctx.strokeRect(X(x0)-pd,Y(y0)-pd,(x1-x0)*S+2*pd,(y1-y0)*S+2*pd);}}
 else if(d.t==="fp")paintPickPreviewPart(ctx,d.i);
 else if(d.t==="pad"){
  var p=P[d.i];if(p){ctx.translate(X(p.x),Y(p.y));ctx.rotate((p.rot||0)*Math.PI/180);if(p.side==="bottom")ctx.scale(-1,1);
   padPath(ctx,d.pd);ctx.fill();ctx.stroke();}}
 else if(d.t==="track"){
  ctx.lineWidth=Math.max((d.o.w||.25)*S,1.2)+6;ctx.globalAlpha=.38;ctx.beginPath();trackPath(ctx,d.o);ctx.stroke();
  ctx.lineWidth=Math.max((d.o.w||.25)*S,1.2)+2;ctx.globalAlpha=1;ctx.beginPath();trackPath(ctx,d.o);ctx.stroke();}
 else if(d.t==="via"){
  ctx.beginPath();ctx.arc(X(d.o.x),Y(d.o.y),viaRenderRadius(d.o.d||.4)+5,0,6.2832);ctx.fill();ctx.stroke();}
 else if(d.t==="zone"||d.t==="keepout"){
  var outer=d.o.poly||d.o.outer,inner=d.o.inner;ctx.beginPath();
  if(outer&&keepoutPolyPath(ctx,outer)){if(inner)keepoutPolyPath(ctx,inner);ctx.fill("evenodd");ctx.stroke();}}
 else if(d.t==="drc"){
  ctx.beginPath();ctx.arc(X(d.o.x),Y(d.o.y),13,0,6.2832);ctx.fill();ctx.stroke();}
 ctx.restore();}
// ── Auto-DRC after copper edits (debounced ~800 ms) ─────────────────────
// Every copper mutation (draw/delete/Stamp/route apply) and every Save
// schedules a server DRC of the CURRENT poses + copper via /api/pcb-drc, so
// the DRC markers + count chip stay honest without waiting for a Route click.
// The live client-side check blocks obvious shorts during drawing; this is the
// authoritative re-check (all 8 checks, incl. annular + board-edge).
var drcTimer=null,drcSeq=0;
// Chip splits the count by severity while rolling a net's many open gaps into
// one actionable open-net count. The underlying raw violations still gate fab.
function drcChip(n){var e=document.getElementById("r-drc");if(!e)return;
 if(n<0){e.className="route-stat";e.textContent="checking…";return;}
 var sum=drcSummary(),err=sum.err,warn=sum.warn,bits=[];
 e.className="route-stat "+(err?"err":"ok");
 if(sum.open)bits.push(sum.open+" open net"+(sum.open>1?"s":""));
 if(sum.otherErr)bits.push(sum.otherErr+(sum.open?" other err":" err"));
 if(sum.otherWarn)bits.push(sum.otherWarn+" warn");
 e.textContent=bits.length?bits.join(" · "):"DRC clean ✓";}
function runDrcNow(){if(RO)return;var seq=++drcSeq;drcChip(-1);
 var payload=boardStatePayload();
 fetch("/api/pcb-drc/"+encodeURIComponent(PCB.name)+subq(),{method:"POST",
   headers:{"Content-Type":"application/json"},body:JSON.stringify(payload)})
  .then(function(r){if(!r.ok)throw 0;return r.json();})
  .then(function(j){if(seq!==drcSeq)return; // a newer check superseded this one
    var srv=j.drc||[];
    // Parity telemetry: the server is the authority-of-record. When its count
    // or id-set diverges from the most recent wasm result for this same state,
    // log both so wasm/server drift is visible (wave-2 audit).
    if(!wasmDrc.failed&&wasmDrc.lastN!=null&&(srv.length!==wasmDrc.lastN||!idSetEq(drcIdSet(srv),wasmDrc.lastIds)))
     console.warn("[drc] wasm/server mismatch",{wasm:wasmDrc.lastN,server:srv.length});
    var oldIds=drcIdSet(PCB.drc||[]),changed=srv.length!==(PCB.drc||[]).length||!idSetEq(drcIdSet(srv),oldIds);
    PCB.drc=srv;if(changed)drawDrc();drcChip(srv.length);routeSummaryFrom(j);}) // server wins
  .catch(function(){if(seq===drcSeq)drcChip(0);});}
function boardStatePayload(){var vg=viaGeo();return {
 parts:P.map(function(p){return {ref:p.ref,x:p.x,y:p.y,rot:p.rot||0,side:p.side||"top"};}),
 tracks:PCB.tracks||[],vias:PCB.vias||[],zones:PCB.zones||[],rf_paths:PCB.rf_paths||[],clearance:clrVal(),
 via_dia:vg.dia,via_drill:vg.drill,outline:PCB.outline||null};}
// ── Declared-pour refill + staleness ─────────────────────────────────────
// Pours delivered by the server (page load) or a refill reflect the board
// state at that instant; any later edit feeding boardStatePayload() (part
// pose/side, tracks, vias, clearance, outline) leaves them stale until the
// next refill. Both the Route-panel button (#r-pour) and the first-class
// toolbar button (#pcb-pour, hidden when the design declares no pours) run the
// same flow. poursArmed gates out the load-time DRC pass, which touches copper
// without changing board state; poursReqSeq lets an edit that lands mid-flight
// supersede the in-flight refill's "fresh" verdict.
var poursInFlight=false,poursArmed=false,poursReqSeq=0;
// A design "has pours" when the stackup declares one OR the user has drawn a
// custom copper-pour zone — either way the ⟳ Pours button is live and copper
// edits mark the fills stale.
function poursDeclared(){return !!PCB.pours_declared||((PCB.plane_fills||[]).length>0)||
 STACK.some(function(L){return L.l==null&&!!L.plane;})||((PCB.zones||[]).length>0);}
// ── RF ground via fence ───────────────────────────────────────────────────
// End-of-design action: POST the layout being edited to /api/pcb-fence and let
// the server lay (or regenerate) the RF ground fence along the board's RF
// traces — every net whose class declares (fence …) or carries (max-freq …).
// The server PERSISTS it into that row (like the KiCad-sync/autoroute-adopt
// paths), so the reply describes what is now on disk and the page reloads onto it.
var fenceInFlight=false;
function fenceDeclared(){return !!PCB.fence_declared;}
function fenceBtn(){return document.getElementById("pcb-fence");}
function fenceBtnSync(){var b=fenceBtn();if(b)b.style.display=fenceDeclared()?"":"none";}
function fenceSkipped(nets){var n=0;(nets||[]).forEach(function(r){var s=r.skipped||{};
 n+=(s.pad||0)+(s.track||0)+(s.via||0)+(s.keepout||0)+(s.outline||0)+(s.dedup||0);});return n;}
function fenceRun(){if(fenceInFlight)return;var b=fenceBtn();if(!b)return;
 fenceInFlight=true;b.disabled=true;routeStatMsg("fencing\u2026");
 var q="/api/pcb-fence/"+encodeURIComponent(PCB.name);
 if(curLayout)q+="?layout="+encodeURIComponent(curLayout);
 fetch(q,{method:"POST"})
  .then(function(r){return r.json().then(function(j){return {ok:r.ok,j:j};});})
  .then(function(o){
   fenceInFlight=false;b.disabled=false;
   if(!o.ok||!o.j||!o.j.ok){routeStatMsg((o.j&&o.j.error)||"fence failed",true);return;}
   var sk=fenceSkipped(o.j.nets);
   routeStatMsg("fence: "+o.j.placed+" via"+(o.j.placed===1?"":"s")+" placed, "+sk+" site"+
    (sk===1?"":"s")+" skipped"+(o.j.replaced?" ("+o.j.replaced+" replaced)":""));
   // The fence is already saved, so the row on disk is the authority: reload
   // onto it rather than trying to reconstruct the merged copper client-side.
   location.reload();})
  .catch(function(){fenceInFlight=false;b.disabled=false;routeStatMsg("fence failed",true);});}
function pourBtns(){var a=[],x=document.getElementById("r-pour"),y=document.getElementById("pcb-pour");
 if(x)a.push(x);if(y)a.push(y);return a;}
function pourBtnSync(){var b=document.getElementById("pcb-pour");if(!b)return;
 b.style.display=poursDeclared()?"":"none";if(!poursDeclared())return;
 var stale=!!PCB.poursStale;b.classList.toggle("stale",stale);
 b.title=stale
  ?"Copper changed since the last fill — click to refill declared pours around the current parts, tracks and vias"
  :"Recompute declared copper pours around the current parts, tracks and vias";}
function markPoursStale(){pourGeomDrop(); // every copper/pose edit funnels here — the cached pour paths go with it
 if(!poursArmed||!poursDeclared())return;
 poursReqSeq++; // an edit supersedes any in-flight refill's freshness
 if(PCB.poursStale)return;PCB.poursStale=true;pourBtnSync();}
function poursFresh(){PCB.poursStale=false;pourBtnSync();}
// Seed only via-in-pad ground barrels from the autorouter's plane pass: QFN
// exposed-pad arrays and exact GND-pad centres. The server judges each addition
// against the submitted hand copper; no trace or existing via is replaced.
var groundViasInFlight=false;
function groundViasBtnInstall(){if(RO||document.getElementById("pcb-ground-vias"))return;
 var anchor=document.getElementById("pcb-fence")||document.getElementById("pcb-pour");if(!anchor||!anchor.parentNode)return;
 var b=document.createElement("button");b.className="btn";b.id="pcb-ground-vias";b.textContent="⊙ GND vias";
 b.title="Seed exposed-pad thermal arrays and centred GND via-in-pad drops without autorouting";
 anchor.parentNode.insertBefore(b,anchor);}
function groundViasRun(){if(groundViasInFlight||RO)return;var b=document.getElementById("pcb-ground-vias");if(!b)return;
 groundViasInFlight=true;b.disabled=true;routeStatMsg("seeding GND vias…");
 var payload=boardStatePayload(),sent=JSON.stringify(payload),q=subq();
 fetch("/api/pcb-drc/"+encodeURIComponent(PCB.name)+"/ground-vias"+q,{method:"POST",
  headers:{"Content-Type":"application/json"},body:sent})
  .then(function(r){if(!r.ok)throw 0;return r.json();})
  .then(function(j){groundViasInFlight=false;b.disabled=false;
   if(JSON.stringify(boardStatePayload())!==sent){routeStatMsg("board changed — click GND vias again");return;}
   var g=j||{},added=g.added||[];
   if(added.length){recordUndo();PCB.vias=PCB.vias||[];added.forEach(function(v){PCB.vias.push({x:v.x,y:v.y,d:v.d,
     drill:v.drill,net:v.net||"",source:"autorouter",id:viaIdNew()});});
    copperIdsEnsureAll();drawRoute();scheduleDrc();}
   var msg="GND vias: "+added.length+" added";
   if(g.duplicates)msg+=" · "+g.duplicates+" already present";
   if(g.blocked)msg+=" · "+g.blocked+" blocked by DRC";
   routeStatMsg(msg,!!g.blocked&&!added.length);})
  .catch(function(){groundViasInFlight=false;b.disabled=false;routeStatMsg("GND via seed failed",true);});}
function refillPours(){if(poursInFlight)return;var bs=pourBtns();if(!bs.length)return;
 poursInFlight=true;var seq=++poursReqSeq;bs.forEach(function(b){b.disabled=true;});
 setStat("r-pour-stat","","refilling…");var q=subq();
 fetch("/api/pcb-drc/"+encodeURIComponent(PCB.name)+q+(q?"&":"?")+"pours=1",{method:"POST",
  headers:{"Content-Type":"application/json"},body:JSON.stringify(boardStatePayload())})
  .then(function(r){if(!r.ok)throw 0;return r.json();})
  .then(function(j){PCB.pours=j.pours||[];PCB.plane_fills=j.plane_fills||[];PCB.zone_fills=j.zone_fills||[];routeSummaryFrom(j);pourGeomDrop();dragCacheDrop();paintSoon();
   if(seq===poursReqSeq)poursFresh(); // no edit landed while in flight → fresh
   var nfill=PCB.pours.length+(PCB.plane_fills||[]).length+(PCB.zone_fills||[]).length;
   setStat("r-pour-stat",nfill?"ok":"warn",nfill?"pours refilled ✓":"no pours to fill");
   poursInFlight=false;bs.forEach(function(b){b.disabled=false;});})
  .catch(function(){setStat("r-pour-stat","err","refill failed");
   poursInFlight=false;bs.forEach(function(b){b.disabled=false;});});}
pourBtns().forEach(function(b){b.addEventListener("click",refillPours);});
(function(){groundViasBtnInstall();var b=document.getElementById("pcb-ground-vias");if(b&&!RO)b.addEventListener("click",groundViasRun);})();
(function(){var b=fenceBtn();if(b&&!RO)b.addEventListener("click",fenceRun);})();
function scheduleDrc(){if(RO)return;
 copperTouched(); // every copper/pose edit funnels here — refresh airwire doneness
 drcGateSessionDefer(); // mid-drag session back in step with the edit, off THIS frame
 wasmDrcInit();   // lazily spin up the worker on the first edit
 if(wasmDrc.failed){ // no worker/wasm → the original 800 ms server debounce, unchanged
  if(drcTimer)clearTimeout(drcTimer);
  drcTimer=setTimeout(function(){drcTimer=null;runDrcNow();},800);
  return;}
 wasmDrcCoalesce();        // near-instant local check (trailing ~50 ms coalesce)
 scheduleServerReconcile();} // server authority-of-record (incl. net_open) after ~300 ms idle
// ── Client-side WASM DRC (wave 2) ────────────────────────────────────────
// A Web Worker runs the SAME drc engine (compiled to wasm32, /static/drc.wasm)
// over the live board state, so DRC markers refresh in ~a frame after an edit
// instead of waiting on the 800 ms server round-trip. The server POST stays as
// the lower-frequency authority-of-record (fired on Save + ~2 s idle) and wins
// on arrival. If the worker or wasm can't init — old browser, blocked fetch,
// a check that throws — wasmDrc.failed latches and scheduleDrc silently reverts
// to the original 800 ms server-debounce path (no behaviour change there).
var wasmDrc={worker:null,ready:false,failed:false,seq:0,lastN:null,lastIds:{}};
var wasmCoalesceTimer=null,serverReconcileTimer=null;
var drcInputCache={gen:-1,clr:null,outline:null,json:null};
function drcInputJson(){var clr=clrVal(),outline=PCB.outline||null;
 if(drcInputCache.gen===dirtyGeneration&&drcInputCache.clr===clr&&drcInputCache.outline===outline&&drcInputCache.json)return drcInputCache.json;
 var json=JSON.stringify(buildDrcInput(PCB,{clearance:clr,outline:outline}));
 drcInputCache={gen:dirtyGeneration,clr:clr,outline:outline,json:json};return json;}
function wasmDrcInit(){
 if(RO||wasmDrc.worker||wasmDrc.failed)return;
 if(typeof Worker==="undefined"||typeof WebAssembly==="undefined"||typeof buildDrcInput!=="function"){wasmDrc.failed=true;return;}
 var wk;
 try{wk=new Worker("/static/drc_worker.js");}catch(e){wasmDrc.failed=true;return;}
 wk.onmessage=function(ev){var m=ev.data||{};
  if(m.type==="ready"){wasmDrc.ready=true;return;}
  if(m.type==="error"){wasmDrcFail();return;}          // wasm instantiate failed
  if(m.type==="result"){
   if(m.seq!==wasmDrc.seq)return;                       // a newer check superseded this one
   if(m.error)return;                                   // this check errored — let the server reconcile
   applyWasmDrc(m.resp);}};
 wk.onerror=function(){wasmDrcFail();};
 wasmDrc.worker=wk;}
function wasmDrcFail(){wasmDrc.failed=true;wasmDrc.ready=false;
 if(wasmDrc.worker){try{wasmDrc.worker.terminate();}catch(e){}wasmDrc.worker=null;}
 if(wasmCoalesceTimer){clearTimeout(wasmCoalesceTimer);wasmCoalesceTimer=null;}}
function wasmDrcCoalesce(){if(wasmCoalesceTimer)return; // trailing edge: one run per burst
 wasmCoalesceTimer=setTimeout(function(){wasmCoalesceTimer=null;runWasmDrc();},50);}
function runWasmDrc(){if(!wasmDrc.worker||wasmDrc.failed)return;
 var input;
 try{input=drcInputJson();}
 catch(e){return;}
 wasmDrc.worker.postMessage({type:"check",seq:++wasmDrc.seq,input:input});}
// Mirror src/serve/drc_rules.zig `apply` on the wasm result: the wasm runs the
// bare checker (built-in severities), so the per-design overrides in
// PCB.drc_kinds are applied here — drop `ignore` kinds, retag `warn`/`err`,
// leave unset kinds on their built-in `sev`. A wasm violation carries the kind
// WORD (`k`); the override map is keyed by kind ENUM, so we bridge through the
// drc_kinds `label` (the same kind word).
function drcOverrideByLabel(){var m={};
 (PCB.drc_kinds||[]).forEach(function(kk){m[kk.label]=kk.ov||null;});return m;}
function applyDrcOverrides(list){var ov=drcOverrideByLabel(),out=[];
 for(var i=0;i<list.length;i++){var v=list[i],a=ov[v.k];
  if(a==null){out.push(v);continue;}    // unset → keep the built-in severity
  if(a==="ignore")continue;             // dropped kind
  v.sev=(a==="warn")?"warn":"err";      // retagged severity
  out.push(v);}
 return out;}
function applyWasmDrc(resp){if(!resp||!resp.drc)return;
 var engine=applyDrcOverrides(resp.drc),list=engine.slice();
 // Connectivity (`net open`) is server-only. Keep the last authoritative rows
 // through the fast geometry refresh instead of tearing them down for 150 ms
 // and recreating them when the reconcile arrives.
 (PCB.drc||[]).forEach(function(d){if(d.k==="net open")list.push(d);});
 var changed=list.length!==(PCB.drc||[]).length||!idSetEq(drcIdSet(list),drcIdSet(PCB.drc||[]));
 PCB.drc=list;wasmDrc.lastN=engine.length;wasmDrc.lastIds=drcIdSet(engine);
 if(changed)drawDrc();drcChip(list.length);} // no "checking…" flicker — the wasm result is immediate
function drcIdSet(list){var s={};for(var i=0;i<list.length;i++){if(list[i].id)s[list[i].id]=1;}return s;}
function idSetEq(a,b){var k;for(k in a)if(!b[k])return false;for(k in b)if(!a[k])return false;return true;}
// The wasm engine runs drc.check only — the `net open` connectivity markers
// exist ONLY on the server, and on a board like barracuda they are most of the
// violations. So this reconcile is not a background formality: it is when the
// user first sees the errors they care about, and its delay IS the felt DRC
// latency. It was 2 s against a 150 ms server check. The check is now ~30 ms
// (net_open's pad sweeps prefiltered, its plane raster tracing-free and sharing
// one edge field), so the wait no longer has to hide the compute — 300 ms still
// coalesces a burst of edits into one request while putting the authoritative
// markers up in about a third of a second. scheduleDrc only fires on committed
// edits (drop, draw-end, delete, Save), never per pointermove, so this cannot
// turn a drag into a request storm; drcSeq drops any superseded reply.
var server_reconcile_ms=300;
function scheduleServerReconcile(){if(RO)return;
 if(serverReconcileTimer)clearTimeout(serverReconcileTimer);
 serverReconcileTimer=setTimeout(function(){serverReconcileTimer=null;runDrcNow();},server_reconcile_ms);}
// A rules/severity change re-checks immediately: re-run the wasm (which
// re-applies the fresh overrides on a full result) when it's up, else the server.
function drcRefreshNow(){if(!wasmDrc.failed&&wasmDrc.worker){runWasmDrc();scheduleServerReconcile();}else runDrcNow();}
// ── Engine-exact commit gate (tier 2) ───────────────────────────────────────
// The mid-drag JS gate (segViolation/edgePointViol) is a conservative bbox
// approximation — it can pass copper the real engine would flag (a via↔hole
// spacing, a polygon-edge cut, a shape-exact pad clearance). So on a COMMIT
// (fixing a corner, finishing on a pad, dropping a via, dropping a dragged
// segment) we run the SAME wasm engine synchronously over the changed copper's
// clearance neighbourhood and refuse the commit if the candidate introduces a
// new routing-class violation. A separate main-thread wasm instance backs this —
// the DRC worker is async and can't answer a click inline. When it isn't ready
// (or ever throws) the gate is a no-op and tier-1 clipping stands alone, so
// drawing never blocks on wasm availability.
// sLoaded/netIdx/sSeq back the persistent MID-DRAG session (drc_session.zig's
// drc_load + drc_probe_*), separate from the commit-gate scoped check below.
var drcGate={inst:null,mem:null,ready:false,failed:false,sLoaded:false,netIdx:null,sSeq:0};
// Only clearance/edge/hole-class violations block a commit: they are the ones a
// user fixes by rerouting. track-width / min-drill / annular are geometry the
// route can't dodge (blocking them would trap the pen), and silk/courtyard
// are warnings — none should ever make copper un-layable. "net open" and
// "copper stub" stay out for the same reason: a half-drawn route is the normal
// mid-session state, not a reason to refuse the segment that starts it.
// "via spacing" IS dodgeable — it is the same-net twin of "via↔via", fixed by
// putting the via somewhere else — so it blocks like every other via clearance.
var DRC_BLOCK={"via↔pad":1,"via↔via":1,"via spacing":1,"via↔track":1,"track↔track":1,"track↔pad":1,"pad↔pad":1,"board edge":1,"hole↔hole":1};
function drcGateInit(){
 if(RO||drcGate.inst||drcGate.failed)return;
 if(typeof WebAssembly==="undefined"||typeof buildDrcInput!=="function"){drcGate.failed=true;return;}
 fetch("/static/drc.wasm").then(function(r){if(!r.ok)throw 0;return r.arrayBuffer();})
  .then(function(buf){return WebAssembly.instantiate(buf,{});})
  .then(function(res){drcGate.inst=res.instance;drcGate.mem=res.instance.exports.memory;drcGate.ready=true;drcGateSessionDefer();})
  .catch(function(){drcGate.failed=true;});}
// ── Persistent mid-drag session ─────────────────────────────────────────────
// Load the CURRENT board once into the wasm session so each pointermove probe is
// microseconds (vs. the whole-board drc_check). A stale session refills only in
// browser idle time or when a copper gesture arms, never on a part-drop frame
// or per pointermove.
// A failed/absent load leaves sLoaded=false, so the JS geometry gate runs
// unchanged (drawing never blocks on wasm). The commit gate stays the final word.
function drcGateSessionReload(){
 if(!drcGate.ready||drcGate.failed)return;
 drcGate.sLoaded=false;
 try{
  var ex=drcGate.inst.exports;
  var input=drcInputJson();
  var bytes=new TextEncoder().encode(input);
  var p=ex.wasm_alloc(bytes.length);
  new Uint8Array(drcGate.mem.buffer).set(bytes,p);
  var outLen=ex.drc_load(p,bytes.length);
  var outPtr=ex.drc_session_output_ptr();
  var resp=JSON.parse(new TextDecoder().decode(new Uint8Array(drcGate.mem.buffer,outPtr,outLen)));
  if(!resp.ok||!resp.nets)return;                 // error json → stay unloaded (JS fallback)
  var m={};for(var i=0;i<resp.nets.length;i++)m[resp.nets[i]]=i;
  drcGate.netIdx=m;drcGate.sLoaded=true;drcGate.sSeq++;
 }catch(e){drcGate.failed=true;}}
// scheduleDrc runs inside the pointerup that ENDS a drag, and the reload above
// is a whole-board drc_load on the main thread. The edit frame only MARKS the
// session stale; an idle callback may refill it later, while a track/via/draw
// gesture explicitly ensures it before the first probe. One refill is pending
// at a time and always reads the latest live PCB state.
// Deferral is safe because sLoaded=false is the state every probe already
// handles: drcSessProbeSeg / drcSessProbeVia / drcSessClipSeg return null and
// segViolation / viaViolation / clipLegs fall back to their JS geometry gate.
// Clearing sLoaded is the load-bearing half — it must happen on the edit frame,
// or a probe in the gap would answer from PRE-edit copper. The synchronous
// commit gate (drcGateDiffBlocks, its own full check) is untouched and remains
// the final word on what copper may land.
var drcSessTimer=null;
function drcGateSessionDefer(){
 if(!drcGate.ready||drcGate.failed)return;
 drcGate.sLoaded=false;
 if(drcSessTimer)return;
 var run=function(){drcSessTimer=null;if(draftGestureLive())return;drcGateSessionReload();};
 drcSessTimer=window.requestIdleCallback?window.requestIdleCallback(run,{timeout:1000}):setTimeout(run,250);}
function drcGateSessionEnsure(){if(drcGate.ready&&!drcGate.failed&&!drcGate.sLoaded){
 if(drcSessTimer){if(window.cancelIdleCallback)window.cancelIdleCallback(drcSessTimer);else clearTimeout(drcSessTimer);drcSessTimer=null;}
 drcGateSessionReload();}}
// A probe net name → its session index (nets collapse the same way pads do); a
// name absent from the session is -1 (the engine then checks it against every
// net — conservative, never a missed clearance).
function drcSessNetIdx(net){if(!drcGate.netIdx)return -1;var v=drcGate.netIdx[netCollapse(net||"")];return (v==null)?-1:v;}
// Engine-exact probes: 0=clean, 1=violate, null=fall back to the JS gate (no
// session, or the export returned the no-session sentinel 2 / t<0).
function drcSessProbeSeg(x1,y1,x2,y2,layer,net,hw){
 if(!drcGate.sLoaded)return null;
 var ex=drcGate.inst.exports;ex.drc_probe_geom(layer,hw*2);
 var r=ex.drc_probe_seg(x1,y1,x2,y2,drcSessNetIdx(net));
 return (r===0)?0:(r===1)?1:null;}
function drcSessProbeVia(x,y,net,dia,drill){
 if(!drcGate.sLoaded)return null;
 var r=drcGate.inst.exports.drc_probe_via(x,y,dia,drill||0,drcSessNetIdx(net));
 return (r===0)?0:(r===1)?1:null;}
// Largest violation-free prefix fraction t∈[0,1] of a leg, or null (no session).
function drcSessClipSeg(x1,y1,x2,y2,layer,net,hw){
 if(!drcGate.sLoaded)return null;
 var ex=drcGate.inst.exports;ex.drc_probe_geom(layer,hw*2);
 var t=ex.drc_clip_seg(x1,y1,x2,y2,drcSessNetIdx(net));
 return (t<0)?null:t;}
// Run the wasm engine synchronously over explicit copper overrides → drc list
// (override-filtered, same as the worker path). Two-call ABI mirrors drc_worker.js.
function drcGateRun(tracks,vias,parts){
 var ex=drcGate.inst.exports;
 var input=JSON.stringify(buildDrcInput(PCB,{clearance:clrVal(),outline:PCB.outline||null,parts:parts||P,tracks:tracks,vias:vias}));
 var bytes=new TextEncoder().encode(input);
 var p=ex.wasm_alloc(bytes.length);
 new Uint8Array(drcGate.mem.buffer).set(bytes,p);
 var outLen=ex.drc_check(p,bytes.length);
 var outPtr=ex.drc_output_ptr();
 var json=new TextDecoder().decode(new Uint8Array(drcGate.mem.buffer,outPtr,outLen));
 return applyDrcOverrides((JSON.parse(json).drc)||[]);}
// Would appending candTracks/candVias introduce a NEW routing-class error?
// base and after differ ONLY by the candidate, so the id multiset difference is
// exactly the candidate's contribution — a board with pre-existing violations
// keeps drawing elsewhere (those ids appear in both, so never count as new).
function drcBlockCounts(list){var c={};
 for(var i=0;i<list.length;i++){var d=list[i];
  if(!d.id||d.sev==="warn"||d.sev==="warning"||!DRC_BLOCK[d.k])continue;
  c[d.id]=(c[d.id]||0)+1;}
 return c;}
function drcCuSig(o,via){return via?[o.x,o.y,o.d||0,o.drill||0,o.net||""].join("|"):
 [o.x1,o.y1,o.xm,o.ym,o.x2,o.y2,o.l||0,o.w||0,o.net||""].join("|");}
function drcChangedAfter(base,after,via){var counts={},out=[];
 base.forEach(function(o){var k=drcCuSig(o,via);counts[k]=(counts[k]||0)+1;});
 after.forEach(function(o){var k=drcCuSig(o,via);if(counts[k])counts[k]--;else out.push(o);});return out;}
function drcCuBox(o,via){var r=(via?(o.d||0.4):(o.w||0.25))/2;
 if(!via&&o.xm!=null){var cs=trackChords(o),x0=1e18,y0=1e18,x1=-1e18,y1=-1e18;
  cs.forEach(function(s){x0=Math.min(x0,s.x1,s.x2);y0=Math.min(y0,s.y1,s.y2);x1=Math.max(x1,s.x1,s.x2);y1=Math.max(y1,s.y1,s.y2);});
  return {x0:x0-r,y0:y0-r,x1:x1+r,y1:y1+r};}
 return via?{x0:o.x-r,y0:o.y-r,x1:o.x+r,y1:o.y+r}:
  {x0:Math.min(o.x1,o.x2)-r,y0:Math.min(o.y1,o.y2)-r,x1:Math.max(o.x1,o.x2)+r,y1:Math.max(o.y1,o.y2)+r};}
function drcBoxAdd(a,b){if(!a)return {x0:b.x0,y0:b.y0,x1:b.x1,y1:b.y1};
 a.x0=Math.min(a.x0,b.x0);a.y0=Math.min(a.y0,b.y0);a.x1=Math.max(a.x1,b.x1);a.y1=Math.max(a.y1,b.y1);return a;}
function drcBoxHit(a,b){return a.x0<=b.x1&&a.x1>=b.x0&&a.y0<=b.y1&&a.y1>=b.y0;}
function drcGateReach(){var m=clrVal(),rules=PCB.rules||{};
 function scan(o){if(!o||typeof o!=="object")return;for(var k in o){var v=o[k];
  if(typeof v==="number"&&/(clearance|via_to_via|hole_to_hole|min_annular)/.test(k))m=Math.max(m,v);
  else if(v&&typeof v==="object")scan(v);}}
 scan(rules);(PCB.netclasses||[]).forEach(function(n){if(n.clearance>m)m=n.clearance;});return m;}
function drcGateScope(baseTracks,baseVias,afterTracks,afterVias){
 var ct=drcChangedAfter(baseTracks,afterTracks,false),cv=drcChangedAfter(baseVias,afterVias,true),box=null;
 ct.forEach(function(o){box=drcBoxAdd(box,drcCuBox(o,false));});cv.forEach(function(o){box=drcBoxAdd(box,drcCuBox(o,true));});
 if(!box)return null;var reach=drcGateReach();box={x0:box.x0-reach,y0:box.y0-reach,x1:box.x1+reach,y1:box.y1+reach};
 function pick(a,via){return a.filter(function(o){return drcBoxHit(drcCuBox(o,via),box);});}
 var parts=P.filter(function(p,i){return (p.pads||[]).some(function(pd){return drcBoxHit(wrect(i,pd),box);});});
 return {bt:pick(baseTracks,false),bv:pick(baseVias,true),at:pick(afterTracks,false),av:pick(afterVias,true),parts:parts};}
function drcGateDiffBlocks(baseTracks,baseVias,afterTracks,afterVias){
 if(!drcGate.ready)return false; // wasm not up → tier-1 only
 var base,after,scope=drcGateScope(baseTracks,baseVias,afterTracks,afterVias);if(!scope)return false;
 try{base=drcGateRun(scope.bt,scope.bv,scope.parts);after=drcGateRun(scope.at,scope.av,scope.parts);}
 catch(e){drcGate.failed=true;return false;}
 var bc=drcBlockCounts(base),ac=drcBlockCounts(after);
 for(var id in ac){if(ac[id]>(bc[id]||0))return true;}
 return false;}
// Appending candidate copper to the CURRENT model (used by the draw-tool commits,
// where the candidate isn't in PCB.* yet).
function drcGateBlocks(candTracks,candVias){
 var bt=PCB.tracks||[],bv=PCB.vias||[];
 return drcGateDiffBlocks(bt,bv,bt.concat(candTracks||[]),bv.concat(candVias||[]));}
// A leg chain from (fx,fy) as candidate track records for the gate.
function legsToTracks(fx,fy,legs,layer,w,net){var out=[],px=fx,py=fy;
 legs.forEach(function(q){out.push({x1:px,y1:py,x2:q.x,y2:q.y,l:layer,w:w,net:net,source:"human"});px=q.x;py=q.y;});
 return out;}
function setStat(id,cls,txt){var e=document.getElementById(id);
 if(e){e.className="route-stat"+(cls?" "+cls:"");e.textContent=txt;}}
// Glanceable routing completion in the page header. The server owns the
// connectivity definition; this client renders its logical-net pair while the
// response retains connection-level routed/total for DRC and routing details.
function routeSummary(routed,total){var e=document.getElementById("pcb-route-summary");if(!e)return;
 if(typeof routed!=="number"||typeof total!=="number")return;
 routed=Math.max(0,Math.min(routed,total));e.className="pcb-route-summary"+(routed===total?" complete":"");
 e.setAttribute("data-total",String(total));var s=e.querySelector("strong");if(s)s.textContent=routed+" / "+total;
 e.title="Unique logical nets completed; per-pin connections are collapsed and single-pad or plane-carried nets are excluded";}
function uniqueRouteCounts(j){return {
 routed:typeof j.unique_routed==="number"?j.unique_routed:j.routed,
 total:typeof j.unique_total==="number"?j.unique_total:j.total};}
function routeSummaryFrom(j){if(j){var c=uniqueRouteCounts(j);routeSummary(c.routed,c.total);}}
function clearRoute(){planChip(null);
 if(!(PCB.tracks&&PCB.tracks.length)&&!(PCB.vias&&PCB.vias.length)&&!(PCB.rf_paths&&PCB.rf_paths.length)&&!(PCB.drc&&PCB.drc.length))return;
 PCB.tracks=[];PCB.vias=[];PCB.rf_paths=[];PCB.drc=[];copperTouched();
 drawRoute();drawClr();drawDrc();setStat("r-stat","","");setStat("r-drc","","");setStat("r-rp","","");}
// The scorebar's PLAN chip: what the "Route plan" action drew, and the standing
// reminder that this copper is NOT saved. `j` null hides it (any clearRoute —
// a re-solve, an Apply, a Reset — drops the copper, so the chip must go too).
// The headline counts unique logical nets; the response's routed/total remains
// the detailed micro-net connection tally used by the open ledger.
function planChip(j){var el=document.getElementById("pcb-planchip");if(!el)return;
 if(!j){el.style.display="none";el.textContent="";el.className="src-chip src-plan";return;}
 var open=(j.unrouted&&j.unrouted.length)?j.unrouted:[];
 var nd=(j.drc||[]).length;
 var c=uniqueRouteCounts(j);
 el.className="src-chip src-plan"+(open.length?" plan-open":"");
 el.textContent="plan · "+c.routed+"/"+c.total+" nets"+(open.length?(" · "+open.length+" open"):"")+
   (nd?(" · "+nd+" DRC"):"");
 el.title="A routing PLAN for the placement on screen — one-shot autoroute, nothing saved. "+
   "Save (or Update) persists these tracks with the poses; moving a part or re-solving drops them."+
   (open.length?("\nCould not close: "+open.join(", ")):"\nEvery routable net closed.")+
   // Per-pin micro-nets collapse to their logical rail; a rail closes only when
   // all of those required connections close.
   "\nCounts unique logical nets that need copper; per-pin connections are collapsed, and single-pad or plane-carried nets are excluded.";
 el.style.display="";}
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
 document.getElementById("court-title").textContent=p.fp+"  \u00b7  "+refLabel(p.ref);
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
 b.addEventListener("click",function(){openFpCard(b.getAttribute("data-court-ref"));});});
var cxBtn=document.getElementById("court-x"),ccBtn=document.getElementById("court-cancel"),modalBg=document.getElementById("court-modal");
if(cxBtn)cxBtn.addEventListener("click",courtClose);
if(ccBtn)ccBtn.addEventListener("click",courtClose);
if(modalBg)modalBg.addEventListener("click",function(ev){if(ev.target===modalBg)courtClose();});
document.querySelectorAll("input[name=court-mode]").forEach(function(r){
 r.addEventListener("change",function(){if(r.checked)courtSetMode(r.value);});});

// ── Library-card modal ────────────────────────────────────────────────
// The sidebar footprint button opens the part's library card (component
// preferred, else footprint) in a modal — the SAME card the /library page
// renders — so the datasheet, the full footprint editor, 3D-model drag-in
// and 3D alignment are all reachable straight from the layout. Courtyard
// editing stays available through the card's footprint preview, which
// reuses this page's courtyard modal.
var fpCardState=null; // {ref, fp, name} of the card currently shown
function openFpCard(ref){var p=partByRef(ref);if(!p)return;
 var name=p.component||p.fp||"";if(!name)return;
 fpCardState={ref:ref,fp:p.fp||"",name:name};
 var title=document.getElementById("fp-card-title");
 if(title)title.textContent=(p.component?p.component+" · ":"")+refLabel(ref);
 var body=document.getElementById("fp-card-body");
 if(body)body.innerHTML='<div class="fp-empty">Loading library card…</div>';
 document.getElementById("fp-card-modal").hidden=false;
 fetch("/api/library-card/"+encodeURIComponent(name))
  .then(function(r){if(!r.ok)throw new Error(r.status===404?"No library entry for “"+name+"”":"Card fetch failed");return r.text();})
  .then(function(html){
   if(!fpCardState||fpCardState.name!==name)return; // closed / reopened meanwhile
   if(body)body.innerHTML=html;
   wireFpCard();
  })
  .catch(function(e){
   if(!fpCardState||fpCardState.name!==name)return;
   if(body)body.innerHTML='<div class="fp-empty">'+pEsc(e.message||"Could not load the library card.")+'</div>';
  });}
function fpCardClose(){document.getElementById("fp-card-modal").hidden=true;fpCardState=null;}
function fpCardMsg(text){var body=document.getElementById("fp-card-body");if(!body)return;
 var m=body.querySelector(".fp-card-msg");
 if(!m){m=document.createElement("div");m.className="fp-card-msg";body.appendChild(m);}
 m.textContent=text;}
function wireFpCard(){var st=fpCardState;if(!st)return;
 var body=document.getElementById("fp-card-body");if(!body)return;
 var card=body.querySelector(".comp-card");if(!card)return;
 // Footprint preview: expand the inline SVG, same loader as the library
 // page — but its “Edit courtyard” opens THIS page's courtyard modal so
 // the part keeps its placement context.
 body.querySelectorAll(".fp-toggle").forEach(function(tag){
  tag.addEventListener("click",function(e){
   e.stopPropagation();
   var fp=tag.dataset.fp||st.fp;
   var box=card.querySelector(".fp-preview");
   if(!box||!fp)return;
   var open=!box.classList.contains("open");
   box.classList.toggle("open",open);
   tag.classList.toggle("fp-toggle-open",open);
   if(open)loadFpCardPreview(box,fp,st.ref);
  });
 });
 // Requirements expand/collapse.
 body.querySelectorAll(".req-toggle").forEach(function(t){
  t.addEventListener("click",function(){card.classList.toggle("open");});
 });
 // Attach-datasheet control (component cards): pick an uploaded PDF.
 var dsTog=body.querySelector(".ds-attach-toggle"),dsBtn=body.querySelector(".ds-attach-btn"),
  dsInput=body.querySelector(".ds-attach-input");
 if(dsTog)dsTog.addEventListener("click",function(){
  var row=dsTog.parentElement.querySelector(".ds-attach-row");
  if(row){row.hidden=!row.hidden;if(!row.hidden){loadFpCardDsOptions();if(dsInput)dsInput.focus();}}
 });
 if(dsBtn)dsBtn.addEventListener("click",function(){
  var comp=card.getAttribute("data-component");
  var file=dsInput?dsInput.value.trim():"";
  if(!comp){fpCardMsg("This card has no component definition to attach to");return;}
  if(!file){fpCardMsg("Pick an uploaded PDF first");return;}
  fetch("/api/attach-datasheet",{method:"POST",headers:{"Content-Type":"application/json"},
   body:JSON.stringify({component:comp,file:file})})
   .then(function(r){return r.json().then(function(j){return {ok:r.ok,j:j};});})
   .then(function(resp){
    if(!resp.ok||!resp.j.ok)throw new Error((resp.j&&resp.j.error)||"attach failed");
    fpCardMsg(resp.j.note==="already linked"?"Already linked to "+comp:"Attached to "+comp+" ✓");
   })
   .catch(function(e){fpCardMsg("Attach failed: "+e.message);});
 });
 // Delete the library entry (moved to .deleted/, recoverable).
 var del=body.querySelector(".card-del");
 if(del)del.addEventListener("click",function(){
  var kind=card.getAttribute("data-kind"),nm=card.getAttribute("data-name");
  if(!kind||!nm)return;
  if(!confirm('Delete '+kind+' "'+nm+'" from the library?\n\nIt is moved to a .deleted/ folder (recoverable), not erased.'))return;
  fetch("/api/library-delete/"+encodeURIComponent(kind)+"/"+encodeURIComponent(nm),{method:"POST"})
   .then(function(res){return res.json();})
   .then(function(j){
    if(!j.ok)throw new Error(j.error||"delete failed");
    fpCardMsg("Deleted "+nm+" — reloading…");
    setTimeout(function(){window.location.reload();},700);
   })
   .catch(function(e){fpCardMsg("Delete failed: "+e.message);});
 });
 // Drag a .step/.stp/.zip onto the card → that part's 3D model; a .pdf →
 // upload + link as the component's datasheet.
 card.addEventListener("dragover",function(e){e.preventDefault();card.classList.add("drag-over");});
 card.addEventListener("dragleave",function(){card.classList.remove("drag-over");});
 card.addEventListener("drop",function(e){
  e.preventDefault();card.classList.remove("drag-over");
  if(!e.dataTransfer||!e.dataTransfer.files||!e.dataTransfer.files.length)return;
  var f=e.dataTransfer.files[0],n=f.name.toLowerCase();
  if(n.endsWith(".zip")||n.endsWith(".step")||n.endsWith(".stp"))fpCardAttachModel(f,st.name);
  else if(n.endsWith(".pdf"))fpCardLinkDatasheet(f,card.getAttribute("data-component"));
  else fpCardMsg("Drop a .zip / .step (3D model) or .pdf (datasheet) onto the card");
 });}
// Inline footprint preview inside the card (mirrors the library page loader,
// minus the library courtyard modal: “Edit courtyard” calls openCourt here).
function loadFpCardPreview(box,fp,ref){
 if(box.dataset.loaded==="1")return;
 box.dataset.loaded="1";
 box.innerHTML='<span class="fp-empty">Loading preview…</span>';
 fetch("/api/footprint/"+encodeURIComponent(fp)).then(function(r){
  if(!r.ok)throw new Error("no preview");
  return r.json();
 }).then(function(data){
  if(!data||!data.pads)throw new Error("empty");
  box.innerHTML="";
  var size=document.createElement("div");
  size.className="fp-size";
  size.textContent="Bounding box: X "+Number(data.bounds.w).toFixed(3)+" mm × Y "+Number(data.bounds.h).toFixed(3)+" mm";
  box.appendChild(size);
  var edit=document.createElement("button");
  edit.type="button";edit.className="fp-court-edit";edit.textContent="Edit courtyard";
  edit.addEventListener("click",function(e){e.stopPropagation();fpCardClose();openCourt(ref);});
  box.appendChild(edit);
  var full=document.createElement("a");
  full.className="fp-full-edit";full.textContent="Open footprint editor ↗";
  full.href="/library/footprint/"+encodeURIComponent(fp);
  full.target="_blank";full.rel="noopener";
  full.addEventListener("click",function(e){e.stopPropagation();});
  box.appendChild(full);
  var s=FP.el("svg",{});
  FP.drawFootprint(s,data);
  s.style.width="100%";s.style.height="auto";s.style.maxHeight="240px";s.style.display="block";s.style.borderRadius="4px";
  box.appendChild(s);
 }).catch(function(){
  box.innerHTML='<span class="fp-empty">No footprint preview available.</span>';
 });}
function fpCardAttachModel(file,name){
 if(file.size>64*1024*1024){fpCardMsg("File too large (64MB limit)");return;}
 fpCardMsg("Adding 3D model to "+name+"…");
 var r=new FileReader();
 r.onload=function(){
  fetch("/api/upload-model/"+encodeURIComponent(name),
   {method:"POST",headers:{"Content-Type":"application/octet-stream","X-Filename":file.name},body:r.result})
   .then(function(res){return res.json();})
   .then(function(j){
    if(!j.ok)throw new Error(j.error||"failed");
    var fp=j.footprint||name;
    var tf={o:Array.isArray(j.offset)?j.offset:[0,0,0],r:Array.isArray(j.rotation)?j.rotation:[0,0,0]};
    // This page's board blob was rendered before the upload, so teach it about
    // the new model now. If 3D is already open, refresh matching bodies too;
    // otherwise PCB3D.init() will consume the updated map when first opened.
    PCB.models=PCB.models||{};PCB.models[fp]=tf;
    if(window.PCB3D&&window.PCB3D.modelAdded)window.PCB3D.modelAdded(fp,tf);
    fpCardMsg("3D model attached to "+fp+" ✓");
   })
   .catch(function(e){fpCardMsg("Model attach failed: "+e.message);});
 };
 r.readAsArrayBuffer(file);}
function fpCardLinkDatasheet(file,component){
 if(file.size>64*1024*1024){fpCardMsg("PDF too large (64MB limit)");return;}
 if(!component){fpCardMsg("This card has no component definition to attach to");return;}
 fpCardMsg("Linking "+file.name+" to "+component+"…");
 var r=new FileReader();
 r.onload=function(){
  fetch("/api/upload-datasheet",{method:"POST",headers:{"Content-Type":"application/pdf","X-Filename":file.name},body:r.result})
   .then(function(res){return res.json();})
   .then(function(j){
    if(!j.ok)throw new Error(j.error||"upload failed");
    return fetch("/api/component-datasheet/"+encodeURIComponent(component)+"/add",
     {method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({pdf:j.name})})
     .then(function(r2){return r2.json();});
   })
   .then(function(j){
    if(!j.ok&&j.error!=="DuplicateImport")throw new Error(j.error||"link failed");
    fpCardMsg((j.error==="DuplicateImport"?"Already linked to ":"Linked to ")+component+" ✓");
   })
   .catch(function(e){fpCardMsg("Link failed: "+e.message);});
 };
 r.readAsArrayBuffer(file);}
var fpCardDsLoaded=false;
function loadFpCardDsOptions(){
 if(fpCardDsLoaded)return;fpCardDsLoaded=true;
 fetch("/api/datasheets").then(function(r){return r.json();}).then(function(j){
  var body=document.getElementById("fp-card-body");if(!body)return;
  var input=body.querySelector(".ds-attach-input");if(!input)return;
  var dl=document.createElement("datalist");dl.id="fp-card-ds-options";
  (j.files||[]).forEach(function(f){var o=document.createElement("option");o.value=f.name;dl.appendChild(o);});
  body.appendChild(dl);input.setAttribute("list","fp-card-ds-options");
 }).catch(function(){fpCardDsLoaded=false;});}
var fcx=document.getElementById("fp-card-x"),fcm=document.getElementById("fp-card-modal");
if(fcx)fcx.addEventListener("click",fpCardClose);
if(fcm)fcm.addEventListener("click",function(ev){if(ev.target===fcm)fpCardClose();});

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
// Shared routed-copper application — the exact set + redraw + relink sequence
// the Route button and the replay-panel Adopt action both run, factored out so
// the two paths can't drift. Undo is recorded by each caller (the Route button
// snapshots synchronously on click; Adopt snapshots here in PCBAdoptCopper).
function applyRoutedCopper(tracks,vias,drc,rfPaths){
 PCB.tracks=tracks||[];PCB.vias=vias||[];PCB.rf_paths=rfPaths||[];PCB.drc=drc||[];
 copperIdsEnsureAll();
 copperTouched();drawRoute();drawClr();drawDrc();
 rats();/* re-run with tracks present: routedNow is now true, so the loop
        overlay drops its preview GND vias and only the real vias remain —
        no preview+routed via doubling on the bypass caps. */}
// Replay-panel Adopt seam: land the replayed final copper on the board exactly
// as the Route button lands the router response (one undo step; markDirty via
// recordUndo so Save/autosave persists it). PCB-native shapes in:
// tracks {x1,y1,x2,y2,l,w,net}, vias {x,y,d,drill,net}, drc {kind,severity,…}.
window.PCBAdoptCopper=function(tracks,vias,drc,rfPaths){
 recordUndo();applyRoutedCopper(tracks,vias,drc,rfPaths);scheduleDrc();};
// Shared route-result application — today's blocking-route response handling,
// factored so BOTH the live-route done path (pcb_replay.js's driver hands the
// finished job's `final` here) and the blocking fallback below run it identically.
// NO recordUndo — the Route click already recorded one undo step. Exposed on
// window so the live-route driver and the page-init reattach can land a finished
// job's copper exactly like a Route. opts: {scope, clr}. Hands the stuck-net
// diagnostics (route_diagnose.capture rode along on the route) to the Stuck-nets
// panel, and re-enables the Route button.
window.PCBApplyRouteResult=function(j,opts){
 opts=opts||{};var scope=opts.scope||"";
 var elapsed=(typeof opts.elapsedMs==="number")?(" · "+(opts.elapsedMs/1000).toFixed(1)+"s"):"";
 if(opts.clr>0)PCB.clr=opts.clr;
 applyRoutedCopper(j.tracks||[],j.vias||[],j.drc||[],j.rf_paths||[]); // shared with PCBAdoptCopper
 var counts=uniqueRouteCounts(j),ok=(counts.routed===counts.total);
 var miss=(j.unrouted&&j.unrouted.length)?(" · missing: "+j.unrouted.join(", ")):"";
 var unk=(j.scope_unknown&&j.scope_unknown.length)?(" · unknown scope: "+j.scope_unknown.join(", ")):"";
 if(j.grid_overflow)setStat("r-stat","err","board exceeds the routing grid cap — not routed");
 else if(j.stage==="subcircuits"){
  var ss=j.subcircuit_seeds||{};
  setStat("r-stat",ss.timed_out_subcircuits?"warn":"ok","subcircuits "+(ss.completed_subcircuits||0)+"/"+(ss.attempted_subcircuits||0)+
   " · "+(ss.accepted_tracks||0)+" tracks · "+(ss.accepted_vias||0)+" vias"+
   (ss.timed_out_subcircuits?(" · "+ss.timed_out_subcircuits+" timed out"):"")+elapsed);
 } else setStat("r-stat",ok?"ok":"warn","routed "+counts.routed+"/"+counts.total+(scope?" scoped":"")+" nets · "+((j.vias||[]).length)+" vias"+miss+unk+elapsed);
 routeSummaryFrom(j);
 setStat("r-drc",(j.drc||[]).length?"err":"ok",(j.drc||[]).length?(j.drc.length+" DRC violation(s)"):"DRC clean ✓");
 var rp=j.return_path||0; setStat("r-rp",rp?"warn":"ok",rp?(rp+" return-path warning(s)"):"return paths ✓");
 if(window.PCBStuckUpdate)window.PCBStuckUpdate(j.stuck||[]);
 // A plan run labels the scorebar so the copper reads as a proposal; a plain
 // Route leaves whatever chip was there (it did not change what "saved" means).
 if(opts.plan)planChip(j);
 routeBusy(false);
 // Route board is the commit action: persist its just-applied copper into the
 // active snapshot, or mint the conventional first "layout" snapshot. Marking
 // dirty HERE (after copper lands) makes this generation win over any autosave
 // that may have started while a long route was still running. Route plan stays
 // explicitly non-persistent.
 if(!opts.plan){markDirty();persistLayout(curLayout||"layout",curLayout?"updating":"saving",false);}
};
var rgo=document.getElementById("r-go");
// Hierarchy stage is a client-owned routing choice. Build it beside the one
// server-rendered Route action so the large PCB page stays a stable shell.
var rstage=null,rpower=null;
(function(){if(!rgo)return;var row=rgo.parentNode;if(!row)return;
 var label=document.createElement("label");label.className="route-stage";label.setAttribute("for","r-stage");
 var title=document.createElement("span");title.textContent="Stage";
 rstage=document.createElement("select");rstage.id="r-stage";rstage.title="Stop after local subcircuit routing, or continue through whole-board global routing";
 [{v:"full",t:"Subcircuits + whole board"},{v:"subcircuits",t:"Subcircuits only"}].forEach(function(o){var e=document.createElement("option");e.value=o.v;e.textContent=o.t;rstage.appendChild(e);});
 label.appendChild(title);label.appendChild(rstage);row.insertBefore(label,rgo);
 // Role + plane mode are source-level design settings. Fetching them keeps the
 // giant board blob free of another copy, and means exports and every router
 // entry point read the same setting after the update/reload.
 fetch("/api/board-role/"+encodeURIComponent(PCB.name)).then(function(r){if(!r.ok)throw 0;return r.json();}).then(function(meta){
  if(meta.role!=="subcircuit")return;
  var plabel=document.createElement("label");plabel.className="route-power-plane";plabel.title="Use supply planes from the implicit or authored stackup; turn off to route supply rails as ordinary copper (ground planes remain)";
  rpower=document.createElement("input");rpower.type="checkbox";rpower.id="r-power-plane";rpower.checked=meta.power_plane!==false;
  var ptext=document.createElement("span");ptext.textContent="Power plane";
  plabel.appendChild(rpower);plabel.appendChild(ptext);row.insertBefore(plabel,rgo);
  rpower.addEventListener("change",function(){var wanted=rpower.checked;routeBusy(true);
   fetch("/api/power-plane/"+encodeURIComponent(PCB.name),{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({enabled:wanted})})
    .then(function(r){if(!r.ok)throw 0;return r.json();}).then(function(){location.reload();})
    .catch(function(){rpower.checked=!wanted;routeBusy(false);setStat("r-stat","err","could not update power-plane setting");});});
 }).catch(function(){});})();
// The ONE autoroute-from-the-viewer flow: build the payload from the on-screen
// poses + the Route panel's geometry, stream it live when the driver is there,
// fall back to the blocking POST when it isn't. Both the Autorouter panel's
// Route button and the scorebar's "Route plan" action run it, so a plan preview
// and a committed route can never be routing different boards.
// opts: {effort:"one_shot"|…, plan:true} — `effort` picks the retry tier for
// this run only (absent keeps the design's authored `(route (effort …))`), and
// `plan` marks the result with the PLAN chip.
function runRoute(opts){
 opts=opts||{};
 var nf=function(id){return parseFloat(document.getElementById(id).value);};
 var hint=document.getElementById("r-hint");if(hint)hint.style.display="none";
 var stageEl=document.getElementById("r-stage"),stage=opts.plan?"full":(stageEl?stageEl.value:"full");
 setStat("r-stat","",opts.plan?"routing plan…":(stage==="subcircuits"?"routing subcircuits…":"routing…"));setStat("r-drc","","");
 routeBusy(true);
 recordUndo();/* autoroute apply = one undo step (audit 1.1c) */
 // outline: the on-screen drawn outline (saved or not), same as the DRC
 // payload — so an outline edit is honored by Route before it's saved; the
 // server falls back to the blessed saved outline when null.
 var payload={parts:P.map(function(p){return {ref:p.ref,x:p.x,y:p.y,rot:p.rot||0,side:p.side||"top"};}),
   track_width:nf("r-tw"),clearance:nf("r-cl"),via_drill:nf("r-vd"),via_dia:nf("r-va"),
   outline:PCB.outline||null,zones:PCB.zones||[],stage:stage};
 if(opts.effort)payload.effort=opts.effort;
 var applyOpts={clr:payload.clearance,plan:!!opts.plan};
 // Blocking fallback — the pre-live Route path, kept verbatim, used when the
 // live-route driver is absent or its /start can't be reached / is rejected.
 function blockingRoute(){
  if(stage==="subcircuits"){setStat("r-stat","err","subcircuits-only stage needs the live router — reload and try again");routeBusy(false);return;}
  fetch("/api/pcb-route/"+encodeURIComponent(PCB.name),{method:"POST",
    headers:{"Content-Type":"application/json"},body:JSON.stringify(payload)})
   .then(function(r){if(!r.ok)throw 0;return r.json();})
   .then(function(j){window.PCBApplyRouteResult(j,applyOpts);})
   .catch(function(){setStat("r-stat","err","route failed");routeBusy(false);});
 }
 // Live route: stream the autorouter net-by-net onto the board. The driver
 // (pcb_replay.js's window.PCBLiveRoute) owns the poll loop + growing scrubber
 // and calls applyFinal on an uncancelled finish; on a cancelled finish it
 // keeps the partial overlay and leaves the copper for the user to Adopt.
 function applyFinal(final,liveMeta){
  var finalOpts={clr:applyOpts.clr,plan:applyOpts.plan};
  if(liveMeta&&typeof liveMeta.elapsedMs==="number")finalOpts.elapsedMs=liveMeta.elapsedMs;
  window.PCBApplyRouteResult(final,finalOpts);
 }
 if(!window.PCBLiveRoute){blockingRoute();return;}
 fetch("/api/route-live/"+encodeURIComponent(PCB.name)+"/start",{method:"POST",
   headers:{"Content-Type":"application/json"},body:JSON.stringify(payload)})
  .then(function(r){return r.text().then(function(t){var j=null;try{j=JSON.parse(t);}catch(e){}return {status:r.status,j:j};});})
  .then(function(res){
    var j=res.j;
    // 409: a live route is already running for this design — attach to it (the
    // net-name table isn't in the 409 body, so paint without per-net emphasis).
    if(res.status===409&&j&&j.gen){window.PCBLiveRoute.begin(j.gen,null,{onFinal:applyFinal});return;}
    if(res.status>=200&&res.status<300&&j&&j.ok){window.PCBLiveRoute.begin(j.gen,j.nets||[],{onFinal:applyFinal});return;}
    // start rejected (4xx/5xx) — fall back to the blocking route path.
    blockingRoute();})
  .catch(function(){blockingRoute();});
}
// Every route entry point is disabled together for the duration of a run —
// they route the same board, so a second click on another one would fight the
// first. Re-enabled by PCBApplyRouteResult (and by the error paths here).
function routeBusy(on){["r-go","pcb-routeplan"].forEach(function(id){
 var b=document.getElementById(id);if(b)b.disabled=!!on;});
 if(rstage)rstage.disabled=!!on;if(rpower)rpower.disabled=!!on;}
// The primary editor action is deliberately bounded: an authored standard
// tier may consume minutes on a hard board.
if(rgo)rgo.addEventListener("click",function(){runRoute({effort:"one_shot"});});
function routeStageLabel(){if(!rgo||!rstage)return;var local=rstage.value==="subcircuits";rgo.textContent=local?"Route subcircuits":"Route board";rgo.title=local?"Route and save validated local copper only; skip whole-board global routing":"Route all subcircuits first, then globally route the whole board and save the result";}
if(rstage){rstage.addEventListener("change",routeStageLabel);routeStageLabel();}
// "Route plan" — offered only on an UNSAVED board (a Rough/Regenerate seed or a
// sub-block preview), where the placement on screen has no routing yet and no
// saved row to compare against. one_shot because this is a look, not a commit:
// it answers in seconds and reports what the SEED affords rather than what a
// full rescue ladder can eventually rescue. The Autorouter panel's Route button
// is still there for the standard tier.
(function(){var rpb=document.getElementById("pcb-routeplan");if(!rpb)return;
 var unsaved=(PCB.src==="cache"||PCB.src==="fresh");
 if(!unsaved)return;
 rpb.style.display="";
 rpb.addEventListener("click",function(){runRoute({effort:"one_shot",plan:true});});})();
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
// ★-match chip: generating a fresh rough seed is whole-board optimizer work,
// so expose it as an explicit diagnostic instead of doing it on every load.
// Skipped on sub previews and ★-less boards.
(function(){
 if(onSub())return;
 if(!document.querySelector(".lay-row.def"))return;
 var anchor=document.getElementById("sc-obj-d");if(!anchor)return;
 var el=document.createElement("span");el.className="score";el.id="sc-starm";
 el.textContent="★ match";el.style.cursor="pointer";
 el.title="Compare a fresh rough placement with the starred layout (runs the optimizer)";
 anchor.parentNode.insertBefore(el,anchor.nextSibling);
 var loading=false,loaded=false;
 function loadStarMatch(){if(loading||loaded)return;loading=true;el.textContent="★ match …";
  fetch("/api/layout-match/"+encodeURIComponent(PCB.name))
   .then(function(r){return r.ok?r.json():null;})
   .then(function(j){loading=false;
    if(!j||j.starred==null||typeof j.area_match_pct!=="number"){el.textContent="★ match";return;}
    loaded=true;
   var t="Rough-vs-★ area match: how much of a fresh rough seed lands in the same general area as the starred layout (\""+j.starred+"\")";
   if(j.coverage&&j.coverage.unmatched&&j.coverage.unmatched.length)t+=" — ★ covers "+j.coverage.covered+"/"+j.coverage.parts+" parts; unmatched parts are excluded";
   el.title=t;
   el.textContent="★match "+j.area_match_pct.toFixed(0)+"%";
   }).catch(function(){loading=false;el.textContent="★ match";});}
 el.addEventListener("click",loadStarMatch);
})();
fitVB(); // initial fit to the container + overlay paint + label visibility
loadCamReview();
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
 // ── Appearance: ONE builder, two containers ────────────────────────────
 // The full page's right dock and the editable embed's ▤ Layers popover are
 // rendered by the SAME row tables through the SAME markup and the SAME
 // wiring, so a layer cannot be present, named, ordered or behave differently
 // in one of them — the containers only style what they are handed. The panes
 // follow KiCad's Appearance dock: Layers (real fabrication layers, in
 // top→bottom physical order) and Objects (feature overlays + selection
 // filter). Net colouring is always on, so it needs no pane or row.
 var lb=document.getElementById("pcb-layers-btn"),pop=document.getElementById("pcb-layers-pop");
 function planeLabel(L){return L.plane+" "+(L.l==null?"plane":"pour")+(L.implicit?" (implicit)":"");}
 // The Layers rows: the copper stack straight off PCB.layer_table, then the
 // static TECH rows. A row's NAME is its canonical layer name (F.Cu, In2.Cu,
 // B.SilkS) — the friendlier description rides in the title attribute, exactly
 // as KiCad's own Layers tab reads. `stack` is the physical row a click
 // selects (null = not copper); `routable` whether that click also arms it for
 // drawing.
 function apLayerRows(){var rows=[];
  STACK.forEach(function(L){rows.push({key:L.name,name:L.name,stack:L.i,routable:L.l!=null,c:L.c,
   kind:L.plane?planeLabel(L):"",
   desc:L.l==null?("Computed "+planeLabel(L)+" — click to view its copper and antipads; routing is disabled"):
    ((L.l===0?"Front copper":(L.l===1?"Back copper":"Inner copper"))+
     " — click to route on it (B toggles "+LN.f_cu+"/"+LN.b_cu+"; PgUp/PgDn cycle)")});});
  TECH.forEach(function(T){rows.push({key:T.key,name:T.name,stack:null,routable:false,c:T.c,kind:"",desc:T.desc});});
  return rows;}
 // The Objects rows: every user-selectable overlay that is a FEATURE of the
 // view rather than a fabrication layer.
 function apObjectRows(){return [
  {key:"drc_err",name:"DRC errors",c:TH.drc,desc:"Error-severity design-rule violations on the shown board"},
  {key:"drc_warn",name:"DRC warnings",c:"#e3b341",desc:"Warning-severity design-rule violations on the shown board"},
  {key:"clr",name:"Clearance halos",c:"#7ee787",desc:"Clearance rings around pads, tracks and vias (the Route panel sets the mm)"},
  {key:"antipads",name:"Antipads",c:"#f59e0b",desc:"Solved plane antipads around controlled-impedance vias"},
  {key:"keepouts",name:"Keepouts",c:"linear-gradient(90deg,#a855f7,#f59e0b)",
   desc:"Purple = fixed board keepout; amber = active-layer net-class halo. Keepout escape policy remains enforced by DRC without decorative rings."},
  {key:"heatsink",name:"Heatsink",c:"linear-gradient(90deg,#f59e0b,#38bdf8)",desc:"Physical heatsink base and fins; hiding it does not remove it or change thermal simulations"},
  {key:"refdes",name:"Reference designators",c:TH.silk,desc:"Component reference labels over each courtyard"},
  {key:"padnum",name:"Pad numbers",c:"#d6d7db",desc:"Pad-number labels, drawn over the copper"}];}
 // Selection filter (Objects pane): each unchecked type is skipped by the
 // hit-testers, so "Tracks off" drags parts without grabbing copper,
 // "Footprints off" clicks the track under a part, and "Pours / keepouts"
 // makes filled areas an intentional target. Persists in viewSt.filt.
 function apFiltRows(){return [
  ["outline","Board outline","Select, drag, and delete board-outline vertices and edges"],
  ["fp","Footprints","Click a component to select or drag it"],
  ["sub","Sub-circuits","Select or drag rigid sub-circuit bounding boxes"],
  ["pad","Pads","Click a pad to select its net"],
  ["track","Tracks","Select, drag and delete tracks"],
  ["via","Vias","Select, drag and delete vias"],
  ["zone","Pours / keepouts","Click anywhere inside a copper-pour zone or keepout area"],
  ["drc","DRC markers","Click DRC markers to inspect them"]];}
 // KiCad's layer presets — a fixed set, each writing the whole LAYER half of
 // the visibility map in one click. Object rows are deliberately left alone:
 // a preset answers "which layers am I looking at", not "which tools".
 var AP_PRESETS=["All","Front","Back","Copper only"];
function apPresetApply(n){
  STACK.forEach(function(L){
   viewSt.vis[L.name]=(n==="All")?1:(n==="Front")?(L.l===0?1:0):(n==="Back")?(L.l===1?1:0):(L.l!=null?1:0);});
  TECH.forEach(function(T){var f=T.key.indexOf("F.")===0,b=T.key.indexOf("B.")===0;
   // "Copper only" keeps Edge.Cuts: the outline is the board's frame here, and
   // dropping it leaves parts floating in empty space rather than reading as a
   // stripped-back copper view.
   viewSt.vis[T.key]=(n==="All")?1:(n==="Copper only")?(T.key===LN.edge_cuts?1:0):
    (f||b)?((n==="Front")===f?1:0):1;});
  if(n==="Front"||n==="Back"){
   var selected=stackForSignal(n==="Back"?1:0);
   if(selected)selectActiveLayer(selected.l);
  }
  partInteractionVisibilitySync();
  viewSave();if(PCB.apSync)PCB.apSync();apRender();dragCacheDrop();paintSoon();drawBoardRect();drawDrc();rats();}
 // ── Markup. One row renderer for BOTH panes: a layer row and an object row
 // are the same thing — a swatch, a canonical name, an eye — and only a copper
 // row additionally carries the click-to-activate stack id.
 function apEye(k){return '<button class="ap-eye'+(viewSt.vis[k]?'':' off')+'" data-ap-eye="'+k+
  '" title="Show / hide">\u{1F441}</button>';}
 function apRow(r){var cur=(r.stack!=null&&r.stack===activeStack);
  return '<div class="ap-lrow'+(r.stack!=null&&!r.routable?' plane':'')+(cur?' cur':'')+'"'+
   (r.stack!=null?' data-ap-stack="'+r.stack+'"':'')+' title="'+pEsc(r.desc||r.name)+'">'+
   '<span class="ap-sw" style="background:'+r.c+'"></span><span class="ap-name">'+pEsc(r.name)+'</span>'+
   (r.stack!=null?'<span class="ap-active-tag">'+(r.routable?'ACTIVE':'VIEWING')+'</span>':'')+
   (r.kind?'<span class="ap-kind">'+pEsc(r.kind)+'</span>':'')+apEye(r.key)+'</div>';}
 function apPourSlider(){var v=Math.round((viewSt.pourOp||0)*100);
  return '<div class="ap-h">Copper pours</div>'+
   '<div class="ap-slider" title="Fade the copper-pour fills between the default translucent wash and solid copper">'+
   '<span class="ap-slh">Opacity <b data-ap-pourop-val="1">'+v+'%</b></span>'+
   '<input type="range" data-ap-pourop="1" min="0" max="100" step="5" value="'+v+'"></div>';}
 function apLayersHtml(){
  return '<div class="ap-presets">'+AP_PRESETS.map(function(n){
    return '<button type="button" class="ap-preset" data-ap-preset="'+n+'">'+n+'</button>';}).join("")+'</div>'+
   '<div class="ap-h">Layers · '+STACK.length+' copper</div>'+apLayerRows().map(apRow).join("");}
 function apObjectsHtml(compact){var h='<div class="ap-h">Objects</div>'+apObjectRows().map(apRow).join("");
  // The embed popover carries the object rows but not the selection filter —
  // the compact surface is a view switcher, and the filter belongs beside the
  // full editor's selection tools.
  if(!compact)h+='<div class="ap-h ap-h-row"><span>Selection filter</span><span class="ap-hbtns">'+
   '<button type="button" class="btn" data-ap-filt-only="outline">Outline only</button>'+
   '<button type="button" class="btn" data-ap-filt-all="1" title="Enable every selection type">All</button>'+
   '<button type="button" class="btn" data-ap-filt-all="0" title="Disable every selection type">None</button></span></div>'+
   apFiltRows().map(function(r){return '<label class="ap-row" title="'+pEsc(r[2])+
    '"><input type="checkbox" data-ap-filt="'+r[0]+'"'+(viewSt.filt[r[0]]!==0?' checked':'')+
    '><span>'+pEsc(r[1])+'</span></label>';}).join("");
  return h+apPourSlider();}
 function apPopHtml(){return apLayersHtml()+apObjectsHtml(true);}
 // ── State writes. Every control in every container lands here, so the two
 // surfaces cannot drive the same flag through different fan-outs.
 function apVisToggle(k){
  if(k==="clr"){clrSet(!clrOn());return;} // owns its own sync + overlay repaint
  viewSt.vis[k]=viewSt.vis[k]?0:1;viewSave();
  partInteractionVisibilitySync();
  if(k==="drc_err"||k==="drc_warn")drcSync();
  if(PCB.apSync)PCB.apSync();
  dragCacheDrop();paintSoon();drawDrc();rats();drawBoardRect();}
 function apFiltSet(k,on){viewSt.filt[k]=on?1:0;
  if(k==="sub"&&!on){hoverGrpName=null;if(selGroup)clearSel();}
  if(k==="outline"&&!on)outlineSelection=[];
  if(!on&&insp&&(insp.t===k||(k==="zone"&&(insp.t==="zone"||insp.t==="keepout"))))inspClear();}
 function apPourOp(v){viewSt.pourOp=Math.max(0,Math.min(1,(parseFloat(v)||0)/100));viewSave();
  var pct=Math.round(viewSt.pourOp*100);
  document.querySelectorAll("[data-ap-pourop]").forEach(function(s){s.value=String(pct);});
  document.querySelectorAll("[data-ap-pourop-val]").forEach(function(b){b.textContent=pct+"%";});
  dragCacheDrop();paintSoon();}
 // ── Wiring. Re-run after every fill, on whichever container was filled.
 function apWire(box){
  box.querySelectorAll("[data-ap-eye]").forEach(function(b){b.addEventListener("click",function(ev){
   ev.stopPropagation();apVisToggle(b.getAttribute("data-ap-eye"));});});
  box.querySelectorAll("[data-ap-stack]").forEach(function(r){r.addEventListener("click",function(ev){
   if(ev.target&&ev.target.getAttribute&&ev.target.getAttribute("data-ap-eye"))return;
   selectStackLayer(parseInt(r.getAttribute("data-ap-stack"),10));});});
  // stopPropagation because a preset REBUILDS its own container: the button the
  // click started on is detached by the time the document-level handler asks
  // whether the popover contains it, and the popover would close under itself.
  box.querySelectorAll("[data-ap-preset]").forEach(function(b){b.addEventListener("click",function(ev){
   ev.stopPropagation();apPresetApply(b.getAttribute("data-ap-preset"));});});
  box.querySelectorAll("[data-ap-filt]").forEach(function(c){c.addEventListener("change",function(){
   apFiltSet(c.getAttribute("data-ap-filt"),c.checked);viewSave();
   if(PCB.apSync)PCB.apSync();paintSoon();});});
  box.querySelectorAll("[data-ap-filt-all]").forEach(function(b){b.addEventListener("click",function(){
   var on=b.getAttribute("data-ap-filt-all")==="1";
   apFiltRows().forEach(function(r){apFiltSet(r[0],on);});viewSave();
   if(PCB.apSync)PCB.apSync();paintSoon();});});
  box.querySelectorAll("[data-ap-filt-only]").forEach(function(b){b.addEventListener("click",function(){
   var only=b.getAttribute("data-ap-filt-only");apFiltRows().forEach(function(r){apFiltSet(r[0],r[0]===only);});selClear();selCuClear();clearSel();inspClear();viewSave();
   if(PCB.apSync)PCB.apSync();paintSoon();drawBoardRect();});});
  box.querySelectorAll("[data-ap-pourop]").forEach(function(s){s.addEventListener("input",function(){
   apPourOp(s.value);});});}
 function apFill(box,html){if(!box)return;box.innerHTML=html;apWire(box);}
 function apRender(){
  apFill(document.getElementById("ap-layers"),apLayersHtml());
  apFill(document.getElementById("ap-objects"),apObjectsHtml(false));
  if(pop&&!pop.hidden)apFill(pop,apPopHtml());}
 // Every container's rows are re-marked from ONE state read, so a flag flipped
 // by a keyboard shortcut, the Route panel or the other container is reflected
 // everywhere without a rebuild.
 PCB.apSync=function(){
  document.querySelectorAll("[data-ap-stack]").forEach(function(r){
   r.classList.toggle("cur",parseInt(r.getAttribute("data-ap-stack"),10)===activeStack);});
  document.querySelectorAll("[data-ap-eye]").forEach(function(b){
   b.classList.toggle("off",!viewSt.vis[b.getAttribute("data-ap-eye")]);});
  document.querySelectorAll("[data-ap-filt]").forEach(function(c){
   c.checked=viewSt.filt[c.getAttribute("data-ap-filt")]!==0;});};
 function popOpen(){if(!pop||!lb)return;apFill(pop,apPopHtml());
  var r=lb.getBoundingClientRect(),pr=(pop.offsetParent||document.body).getBoundingClientRect();
  pop.style.left=(r.left-pr.left)+"px";pop.style.top=(r.bottom-pr.top+4)+"px";pop.hidden=false;lb.classList.add("active");}
 function popClose(){if(pop)pop.hidden=true;if(lb)lb.classList.remove("active");}
 function apOpen(){
  if(mobileInspectMode()){mobilePanelSet("layers",true);return true;}
  if(compactDockMode()){compactDockSet("appearance",true,"");return true;}
  if(pop&&lb){popOpen();return true;}
  return !!document.getElementById("pcb-appear");}
 if(lb)lb.addEventListener("click",function(ev){ev.stopPropagation();if(pop.hidden)popOpen();else popClose();});
 document.addEventListener("click",function(ev){if(pop&&!pop.hidden&&ev.target!==lb&&!pop.contains(ev.target))popClose();});
 document.addEventListener("keydown",function(ev){
  if((ev.key!=="v"&&ev.key!=="V")||ev.ctrlKey||ev.metaKey||ev.altKey||kbTyping(ev.target))return;
  if(dtrace||outlineMode||activeSketchIsArea())return;
  if(apOpen())ev.preventDefault();});
 apRender();
 document.querySelectorAll(".ap-tab").forEach(function(t){
  t.addEventListener("click",function(){
   document.querySelectorAll(".ap-tab").forEach(function(x){x.classList.toggle("active",x===t);});
   document.querySelectorAll(".ap-pane").forEach(function(pn){pn.hidden=(pn.id!==t.getAttribute("data-aptab"));});});});
 // Tool strip: Select disarms every drawing mode; ? opens the shortcut help.
 var selToolBtn=document.getElementById("tool-select");
 if(selToolBtn)selToolBtn.addEventListener("click",function(){
  if(padAlignMode)padAlignArm(false);
  if(drawMode)drawModeSet(false);
  if(textMode)txArm(false);
  if(polyMode)polyArm(false);
  if(outlineMode)outlineArm(false);
  if(pourMode)pourArm(false);
  if(backingMode)backingArm(false);
  if(heatsinkMode)heatsinkArm(false);
  if(PCB.rulerOff)PCB.rulerOff();
  toolSync();});
 var helpBtn=document.getElementById("pcb-help");
 if(helpBtn)helpBtn.addEventListener("click",function(){kbdToggle();});
 statusLayer(); // initial active-layer segment
 // B toggles the two outer faces. PgUp/PgDn (and parentheses) cycle every
 // routable draw layer; plane-only layers are selected directly in the stack.
 document.addEventListener("keydown",function(ev){if(kbTyping(ev.target))return;
  if((ev.key==="b"||ev.key==="B")&&!ev.ctrlKey&&!ev.metaKey&&!ev.altKey&&!anyDrawTool()){
   ev.preventDefault();selectActiveLayer(activeLayer===0?1:0);
   routeStatMsg("active side: "+layerName(activeLayer));return;}
  if(ev.key==="("||ev.key==="PageUp"||ev.key===")"||ev.key==="PageDown"){
   ev.preventDefault();
   var step=(ev.key===")"||ev.key==="PageDown")?1:(NSIG-1);
   selectActiveLayer((activeLayer+step)%NSIG);
   routeStatMsg("active layer: "+layerName(activeLayer));}});
 // ── Ruler / measure tool (D) ──────────────────────────────────────────
 // D drags out a live dx/dy/distance measurement; the drag state is a
 // {a,b} pair that SURVIVES the redraw — rulerClear only drops the drawn
 // overlay, so pointermove keeps measuring after the press.
 var rulerMode=false,rulerDraw=null,rgRuler=null;
 var rulerBtn=document.getElementById("pcb-ruler-btn");
 function rulerArm(on){rulerMode=on;PCB.rulerOn=on;svg.classList.toggle("ruler-mode",on);
  if(on&&heatsinkMode)heatsinkArm(false);
  if(on){if(padAlignMode)padAlignArm(false);if(drawMode)drawModeSet(false);if(textMode)txArm(false);
   if(polyMode)polyArm(false);if(outlineMode)outlineArm(false);if(pourMode)pourArm(false);closeMoveDialog();}
  if(rulerBtn)rulerBtn.classList.toggle("active",on);
  if(!on){rulerClear();rulerDraw=null;stSet("st-dxdy","");var msg=document.getElementById("pcb-savemsg");if(msg&&/measure/.test(msg.textContent))msg.textContent="";}
  else{var m2=document.getElementById("pcb-savemsg");if(m2){m2.style.color="#e3b341";m2.textContent="measure: drag to measure (Esc exits)";}}
  toolSync();}
 // Remove the drawn ruler overlay only — the live {a,b} drag state stays so
 // the pointermove handler can keep redrawing. rulerArm(false) is where the
 // whole gesture is retired.
 function rulerClear(){if(rgRuler&&rgRuler.parentNode)rgRuler.parentNode.removeChild(rgRuler);rgRuler=null;}
 function rulerDrawNow(a,b){rulerClear();rgRuler=el("g",{});gU.appendChild(rgRuler);
  var dx=b.x-a.x,dy=b.y-a.y,dist=Math.hypot(dx,dy);
  rgRuler.appendChild(el("line",{"class":"pcb-ruler-line",x1:X(a.x).toFixed(1),y1:Y(a.y).toFixed(1),x2:X(b.x).toFixed(1),y2:Y(b.y).toFixed(1)}));
  // dx / dy guide legs
  rgRuler.appendChild(el("line",{"class":"pcb-ruler-line",x1:X(a.x).toFixed(1),y1:Y(a.y).toFixed(1),x2:X(b.x).toFixed(1),y2:Y(a.y).toFixed(1),opacity:0.5}));
  rgRuler.appendChild(el("line",{"class":"pcb-ruler-line",x1:X(b.x).toFixed(1),y1:Y(a.y).toFixed(1),x2:X(b.x).toFixed(1),y2:Y(b.y).toFixed(1),opacity:0.5}));
  var lt=el("text",{"class":"pcb-ruler-lbl",x:(X(b.x)+8).toFixed(1),y:(Y(b.y)-6).toFixed(1)});
  lt.textContent="d="+fmtLen2(dist)+"  dx="+fmtLen2(Math.abs(dx))+"  dy="+fmtLen2(Math.abs(dy));
  rgRuler.appendChild(lt);
  // Mirror the measurement into the status bar's delta segment.
  stSet("st-dxdy","d "+fmtLen2(dist)+"  dx "+fmtLen2(Math.abs(dx))+"  dy "+fmtLen2(Math.abs(dy)));}
 PCB.rulerOff=function(){if(rulerMode)rulerArm(false);};
 if(rulerBtn)rulerBtn.addEventListener("click",function(){rulerArm(!rulerMode);});
 // ── Move selected parts by an X/Y distance (M) ────────────────────────
 // M with parts selected opens a small dialog for X and Y distances in the
 // current display units. One shared delta for every selected entity, so the
 // copper the drag would carry (stamped group copper, the marquee band, nets
 // private to the moving parts) rides the same way — and it records ONE undo
 // step, exactly like a group drag's release.
 var moveDlg=null;
 function closeMoveDialog(){if(moveDlg&&moveDlg.parentNode)moveDlg.parentNode.removeChild(moveDlg);moveDlg=null;}
 // The entity set M operates on: the marquee/Ctrl-click selection, falling
 // back to a clicked rigid sub-circuit (which selects via selGroup, not sel).
 function moveSelection(){var ents=selEntities();
  if(!ents.length&&selGroup&&grpRigid(selGroup)){
   var gi=GRPS[selGroup].filter(function(i){return !P[i].locked&&partOnVisibleFace(P[i]);});
   if(gi.length)ents=[{idxs:gi,g:selGroup}];}
  return ents;}
 function moveSelBy(dx,dy){if(RO)return;
  var ents=moveSelection();
  if(!ents.length){
   var mz=document.getElementById("pcb-savemsg");
   if(mz){mz.style.color="#e3b341";
    mz.textContent="move: nothing to move \u2014 select unlocked parts first (marquee or Ctrl/Cmd+click), then press M";}
   return;}
  if((!dx&&!dy)){
   var mw=document.getElementById("pcb-savemsg");
   if(mw){mw.style.color="#e3b341";mw.textContent="move: enter an X and/or Y distance first";}
   return;}
  recordUndo();
  var moved=moveEntities(ents,ents.map(function(){return {dx:dx,dy:dy};}),true);
  var n=moved.length,m=document.getElementById("pcb-savemsg");
  if(m){m.style.color="#7ee787";
   m.textContent="moved "+n+" part"+(n===1?"":"s")+" by "+fmtLen(dx)+" \u00d7 "+fmtLen(dy)+" \u2014 one undo step";}
  commitMove(moved);}
 function moveDialog(){
  if(RO)return;
  if(PCB.rulerOff)PCB.rulerOff();
  closeMoveDialog();
  var ents=moveSelection();
  var dlg=document.createElement("div");moveDlg=dlg;
  dlg.style.cssText="position:absolute;z-index:60;background:#161b22;border:1px solid #30363d;"+
   "border-radius:6px;padding:10px;font:12px system-ui;color:#c9d1d9;box-shadow:0 6px 22px rgba(0,0,0,.6);min-width:220px";
  var sx=svg.getBoundingClientRect(),vb2=svg.viewBox.baseVal,kx=sx.width/vb2.w,ky=sx.height/vb2.h;
  var bx={x0:1e18,y0:1e18,x1:-1e18,y1:-1e18};
  ents.forEach(function(e){var b=entBox(e);
   bx.x0=Math.min(bx.x0,b.x0);bx.y0=Math.min(bx.y0,b.y0);bx.x1=Math.max(bx.x1,b.x1);bx.y1=Math.max(bx.y1,b.y1);});
  var ax=ents.length?((bx.x0+bx.x1)/2):vb2.x+vb2.w/2,ay=ents.length?((bx.y0+bx.y1)/2):vb2.y+vb2.h/2;
  dlg.style.left=(svg.offsetLeft+(X(ax)-vb2.x)*kx)+"px";
  dlg.style.top=(svg.offsetTop+(Y(ay)-vb2.y)*ky)+"px";
  var title=document.createElement("div");title.textContent="Move selection";
  title.style.cssText="font-weight:600;margin-bottom:6px";dlg.appendChild(title);
  var hint=document.createElement("div");
  hint.style.cssText="margin:0 2px 8px;color:#8b949e;font-size:11px;line-height:1.35;max-width:250px";
  hint.textContent=ents.length?("Move "+ents.length+" selected part"+(ents.length===1?"":"s")+" by an X and/or Y distance ("+(viewSt.units==="mil"?"mil":"mm")+"). Copper that belongs to the selection rides along; one undo step.")
   :"Nothing selected \u2014 marquee-drag or Ctrl/Cmd+click parts first, then press M again.";
  dlg.appendChild(hint);
  var unit=viewSt.units==="mil"?0.0254:1;
  function row(label,node){var r=document.createElement("label");
   r.style.cssText="display:flex;align-items:center;gap:6px;margin:4px 0";
   var s=document.createElement("span");s.textContent=label;s.style.cssText="width:52px;color:#8b949e";
   r.appendChild(s);r.appendChild(node);return r;}
  function field(){var f=document.createElement("input");f.type="number";f.step="any";f.inputMode="decimal";
   f.style.cssText="flex:1;min-width:110px;background:#0d1117;border:1px solid #30363d;color:#c9d1d9;border-radius:4px;padding:3px";
   return f;}
  var xf=field(),yf=field();
  dlg.appendChild(row("X",xf));dlg.appendChild(row("Y",yf));
  function read(f){var v=parseFloat(f.value);return isNaN(v)?0:v;}
  function commit(){var dx=read(xf)*unit,dy=read(yf)*unit;
   closeMoveDialog();moveSelBy(dx,dy);}
  var ba=document.createElement("div");ba.style.cssText="margin-top:8px;display:flex;gap:6px;justify-content:flex-end";
  var cancel=document.createElement("button");cancel.textContent="Cancel";cancel.className="btn";
  var ok=document.createElement("button");ok.textContent="Move";ok.className="btn";
  ok.style.cssText="border-color:#2ea043;color:#7ee787";
  cancel.addEventListener("click",function(){closeMoveDialog();});
  ok.addEventListener("click",commit);
  ba.appendChild(cancel);ba.appendChild(ok);dlg.appendChild(ba);
  dlg.addEventListener("keydown",function(ev){ev.stopPropagation();
   if(ev.key==="Enter"){ev.preventDefault();commit();}
   else if(ev.key==="Escape"){ev.preventDefault();closeMoveDialog();}});
  svg.parentNode.appendChild(dlg);xf.focus();}
 var moveBtn=document.getElementById("pcb-move-btn");
 if(moveBtn)moveBtn.addEventListener("click",function(){moveDialog();});
 // The global Escape chain (a sibling scope) closes the dialog through PCB.
 PCB.moveDlgOpen=function(){return !!moveDlg;};
 PCB.moveDlgClose=function(){closeMoveDialog();};
 document.addEventListener("keydown",function(ev){if(kbTyping(ev.target))return;
  if((ev.key==="d"||ev.key==="D")&&!ev.ctrlKey&&!ev.metaKey&&!RO){ev.preventDefault();rulerArm(!rulerMode);return;}
  if((ev.key==="m"||ev.key==="M")&&!ev.ctrlKey&&!ev.metaKey&&!RO){ev.preventDefault();moveDialog();return;}
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
 // Every accordion panel lives inside the left dock's Autorouter tab, so
 // opening one must raise that tab — otherwise a Route run or the Stuck
 // client would open a panel inside a hidden pane. No-op in the embed
 // (its accordion sits above the board, with no side tabs).
 function openPanel(id){pcbSideTab("side-route");panels().forEach(function(p){p.hidden=(p.id!==id);});
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
function applyHeat(){dragCacheDrop();paintSoon();} // paint reads heatOn/heatScale/p.blame
var heatCb=document.getElementById("v-heat");
if(heatCb)heatCb.addEventListener("change",function(){heatOn=heatCb.checked;
 if(heatOn)heatScale=heatMax();
 var hl=document.getElementById("heat-legend");if(hl)hl.hidden=!heatOn;applyHeat();});
var legCb=document.getElementById("v-legend");
if(legCb)legCb.addEventListener("change",function(){var l=document.getElementById("pcb-legend");
 if(l)l.hidden=!legCb.checked;});
// ── Net colours: every net always gets its own colour so connectivity reads off
//    the board without the schematic. Per-net colour comes straight from
//    PCB.netcolor[net] (no-connect → white, GND → brown, power → warm,
//    each signal net → a distinct colour). A pad on NO net is a no-connect
//    pin → white. This is orthogonal to the heatmap (which tints courtyards).
var netColOn=true;
// Legacy all-board ratsnest/placement-guide rendering remains inert; a chosen
// open-net DRC finding owns the only focused connection line.
var ratsOn=false;
function netColorOf(nk){if(!nk||!PCB.netcolor)return null;return PCB.netcolor[nk]||null;}
drcSync();showScore(PCB.auto);drawRoute();drawClr();drawDrc();
markUnplaced(PCB.placement&&PCB.placement.unplaced);
// The page already embeds authoritative server DRC for this exact saved state.
// Show it immediately, but defer the worker/WASM download and reconciliation
// POST until the first real edit instead of checking an unchanged board twice.
if(!RO)drcChip((PCB.drc||[]).length);
// Arm pour-staleness only after boot so subsequent edits (not initial display)
// light the ⟳ Pours button, and sync its initial visibility + fresh tooltip.
pourBtnSync();fenceBtnSync();poursArmed=true;
// ── Cross-probe focus: ?focus=REF (or #REF) selects that part on load —
//    zoom/centre the view on it, flash its courtyard, and reveal it in the
//    component sidebar. Exact ref first, then the bare sub-block leaf
//    (focus=U2 matches ldo/U2), mirroring the PNG renderer's ?refs= rule.
function focusPart(want,keepPane){
 function leaf(r){var i=r.lastIndexOf("/");return i<0?r:r.slice(i+1);}
 var idx=-1;
 P.forEach(function(p,i){if(idx<0&&p.ref===want)idx=i;});
 if(idx<0)P.forEach(function(p,i){if(idx<0&&leaf(p.ref)===want)idx=i;});
 if(idx<0)return false;
 var p=P[idx],cx=X(p.x),cy=Y(p.y);
 var fw=Math.min(VBW,Math.max(VBW*0.35,(2*p.hw+14)*S*4));
 var far=hostAspect();
 vb={x:cx-fw/2,y:cy-fw*far/2,w:fw,h:fw*far};setVB();
 flashIdx=idx;flashUntil=Date.now()+2600;paintSoon();
 if(!RO)selectComp(p.ref,keepPane);
 return true;}
// ── Board-wide Find ────────────────────────────────────────────────────
// The full editor's dock owns the input; embeds have no matching markup and
// retain the browser's native Ctrl/Cmd+F. Results are derived from the live
// in-memory model so component moves, newly-routed copper, refreshed DRC, and
// edited silk labels are reflected without a server index or another request.
(function(){
 var findInput=document.getElementById("pcb-find-input");if(!findInput)return;
 var findResults=document.getElementById("pcb-find-results"),findMeta=document.getElementById("pcb-find-meta"),
  findClear=document.getElementById("pcb-find-clear");
 var findOpen=false,findPrev="side-props",findRows=[],findAt=-1,findPreviewNet=null,findPreviewGroup=null;
 var findKinds={part:["Components","PART"],net:["Nets","NET"],drc:["DRC violations","DRC"],
  group:["Sub-circuits","SUB"],text:["Board text","TEXT"]};
 var findOrder={part:0,net:1,drc:2,group:3,text:4};

 function findNorm(v){return String(v==null?"":v).trim().toLowerCase();}
 function findTokens(s){var out=[],re=/"([^"]+)"|'([^']+)'|(\S+)/g,m;
  while((m=re.exec(s)))out.push(findNorm(m[1]||m[2]||m[3]));return out;}
 function findParse(raw){var text=String(raw||"").trim(),scope=null,field=null,m=text.match(/^([a-z-]+)\s*:\s*(.*)$/i);
  if(m){var p=findNorm(m[1]),sc={ref:"part",part:"part",component:"part",net:"net",drc:"drc",violation:"drc",
    group:"group",sub:"group",subcircuit:"group",text:"text",label:"text"};
   if(sc[p]){scope=sc[p];text=m[2];}else if(p==="value"||p==="val"||p==="footprint"||p==="fp"){
    scope="part";field=(p==="val"?"value":p==="fp"?"footprint":p);text=m[2];}}
  return {text:text,scope:scope,field:field,tokens:findTokens(text)};}
 function findRegex(token){var s=token.replace(/[.+^${}()|[\]\\]/g,"\\$&").replace(/\*/g,".*").replace(/\?/g,".");
  try{return new RegExp(s,"i");}catch(e){return null;}}
 function findTextScore(value,token){var s=findNorm(value);if(!s)return null;
  if(token.indexOf("*")>=0||token.indexOf("?")>=0){var re=findRegex(token);if(!re||!re.test(s))return null;return 9;}
  if(s===token)return 0;if(s.indexOf(token)===0)return 3;
  var word=s.indexOf(" "+token);if(word>=0)return 6+Math.min(word,20)/100;
  var at=s.indexOf(token);return at<0?null:10+Math.min(at,40)/100;}
 function findScore(c,q){var fields=(q.field&&c.fieldMap&&c.fieldMap[q.field])||c.fields,total=0;
  for(var ti=0;ti<q.tokens.length;ti++){var best=null;
   for(var fi=0;fi<fields.length;fi++){var score=findTextScore(fields[fi],q.tokens[ti]);if(score!=null&&(best==null||score<best))best=score;}
   if(best==null)return null;total+=best;}
  var primary=findNorm(c.title),whole=findNorm(q.text);
  if(primary===whole)total-=8;else if(primary.indexOf(whole)===0)total-=3;
  return total;}
 function findCandidate(type,title,detail,fields,data,fieldMap){return {type:type,title:String(title||""),
  detail:String(detail||""),fields:fields.filter(function(v){return !!String(v||"").trim();}),data:data,fieldMap:fieldMap||{}};}
 function findPartDetail(p){var a=[];if(p.val)a.push(p.val);if(p.fp)a.push(p.fp);if(p.side)a.push(p.side);return a.join(" · ");}
 function findNetInfo(net){var key=reviewNetKey(net),parts={},pads=0,tracks=0,vias=0,mm=0;
  P.forEach(function(p){(p.pads||[]).forEach(function(pd){if(reviewNetKey(pd.net)!==key)return;pads++;parts[p.ref]=1;});});
  (PCB.tracks||[]).forEach(function(t){if(reviewNetKey(t.net)!==key)return;tracks++;mm+=trackLength(t);});
  (PCB.vias||[]).forEach(function(v){if(reviewNetKey(v.net)===key)vias++;});
  var a=[Object.keys(parts).length+" part"+(Object.keys(parts).length===1?"":"s"),pads+" pad"+(pads===1?"":"s")];
  if(tracks)a.push(tracks+" track"+(tracks===1?"":"s")+" · "+mm.toFixed(1)+" mm");if(vias)a.push(vias+" via"+(vias===1?"":"s"));
  return a.join(" · ");}
 function findBuild(q){var all=[];
  P.forEach(function(p,i){var leaf=reviewLeaf(p.ref),g=grpOf(p.ref),fields=[p.ref,leaf,p.val,p.fp,p.kind,p.side,g];
   all.push(findCandidate("part",refLabel(p.ref),findPartDetail(p),fields,{i:i,ref:p.ref},{
    ref:[p.ref,leaf],value:[p.val],footprint:[p.fp]}));});
  var nets={};[].concat(Array.isArray(PCB.netnames)?PCB.netnames:[],reviewAvailableNets()).forEach(function(n){
   n=String(n||"").trim();if(!n)return;var k=reviewNetKey(n);if(!nets[k])nets[k]={name:netCollapse(n),aliases:[]};
   if(nets[k].aliases.indexOf(n)<0)nets[k].aliases.push(n);});
  Object.keys(nets).forEach(function(k){var n=nets[k];all.push(findCandidate("net",n.name,findNetInfo(n.name),
   [n.name].concat(n.aliases),{net:n.aliases[0]||n.name}));});
  (PCB.drc||[]).forEach(function(d,i){var id=d.id?"#"+d.id:"",kind=d.k||"violation",who=drcBetween(d),msg=drcMsg(d);
   all.push(findCandidate("drc",(id?id+" · ":"")+kind,who||msg,[id,d.id,kind,who,drcNets(d),drcPads(d),msg,d.ref,d.net],{i:i}));});
  Object.keys(GRPS).sort().forEach(function(g){var idxs=GRPS[g]||[],refs=idxs.map(function(i){return P[i].ref;});
   all.push(findCandidate("group",g,idxs.length+" components · "+(grpRigid(g)?"rigid":"exploded"),[g].concat(refs),{g:g,refs:refs}));});
  (PCB.texts||[]).forEach(function(t,i){var title=String(t.text||"").trim();if(!title)return;
   all.push(findCandidate("text",title.length>58?title.slice(0,57)+"…":title,
    (t.side||"top")+" silk · "+(+t.x).toFixed(2)+", "+(+t.y).toFixed(2)+" mm",[title,t.side],{i:i,x:t.x,y:t.y}));});
  var matches=[];all.forEach(function(c){if(q.scope&&c.type!==q.scope)return;var score=findScore(c,q);if(score!=null){c.score=score;matches.push(c);}});
  matches.sort(function(a,b){var ao=findOrder[a.type],bo=findOrder[b.type];if(ao!==bo)return ao-bo;
   if(a.score!==b.score)return a.score-b.score;return a.title.localeCompare(b.title,undefined,{numeric:true,sensitivity:"base"});});return matches;}
 function findPreviewClear(){if(findPreviewNet&&hoverNet===findPreviewNet)hoverNet=null;
  if(findPreviewGroup&&hoverGrpName===findPreviewGroup)hoverGrpName=null;
  findPreviewNet=null;findPreviewGroup=null;paintSoon();}
 function findPreview(r){findPreviewClear();if(!r)return;
  if(r.type==="part"){flashIdx=r.data.i;flashUntil=Date.now()+900;}
  else if(r.type==="net"){findPreviewNet=r.data.net;hoverNet=findPreviewNet;}
  else if(r.type==="group"){findPreviewGroup=r.data.g;hoverGrpName=findPreviewGroup;}
  else if(r.type==="drc"){var d=(PCB.drc||[])[r.data.i];if(drcOnBoard(d)&&d.x!=null&&d.y!=null){flashPt={x:d.x,y:d.y};flashPtUntil=Date.now()+900;}}
  else if(r.type==="text"){flashPt={x:r.data.x,y:r.data.y};flashPtUntil=Date.now()+900;}paintSoon();}
 function findSetAt(at,scroll){if(!findRows.length){findAt=-1;findInput.removeAttribute("aria-activedescendant");return;}
  findAt=(at+findRows.length)%findRows.length;var active=null;
  findResults.querySelectorAll("[data-findrow]").forEach(function(el){var on=+el.getAttribute("data-findrow")===findAt;
   el.classList.toggle("active",on);el.setAttribute("aria-selected",on?"true":"false");if(on)active=el;});
  if(active){findInput.setAttribute("aria-activedescendant",active.id);if(scroll&&active.scrollIntoView)active.scrollIntoView({block:"nearest"});}
  findPreview(findRows[findAt]);}
 function findRender(){findPreviewClear();var q=findParse(findInput.value);findClear.hidden=!findInput.value;
  if(!q.tokens.length){findRows=[];findAt=-1;findInput.removeAttribute("aria-activedescendant");
   findMeta.textContent="Search components, nets, DRC violations, sub-circuits, and board text.";
   findResults.innerHTML='<div class="find-empty"><b>Try a reference, net, or rule</b><span>Use <code>ref:</code>, <code>net:</code>, <code>drc:</code>, <code>sub:</code>, <code>text:</code>, <code>value:</code>, or <code>fp:</code> to narrow it.</span><span><code>*</code> and <code>?</code> are wildcards.</span></div>';return;}
  var matched=findBuild(q),perKind={},shown=matched.filter(function(r){perKind[r.type]=(perKind[r.type]||0)+1;return perKind[r.type]<=20;});findRows=shown;findAt=-1;
  findMeta.textContent=matched.length+" result"+(matched.length===1?"":"s")+(matched.length>shown.length?" · first "+shown.length:"");
  if(!shown.length){findResults.innerHTML='<div class="find-empty"><b>No board items match</b><span>Check the spelling or remove the type prefix.</span></div>';return;}
  var h="",last=null;shown.forEach(function(r,i){if(r.type!==last){last=r.type;h+='<div class="find-group-h">'+findKinds[r.type][0]+'</div>';}
   h+='<button type="button" class="find-row" id="pcb-find-row-'+i+'" data-findrow="'+i+'" role="option" aria-selected="false">'+
    '<span class="find-kind '+r.type+'">'+findKinds[r.type][1]+'</span><span class="find-copy"><b>'+pEsc(r.title)+'</b>'+
    (r.detail?'<small>'+pEsc(r.detail)+'</small>':'')+'</span><span class="find-go" aria-hidden="true">›</span></button>';});
  findResults.innerHTML=h;findResults.querySelectorAll("[data-findrow]").forEach(function(el){var i=+el.getAttribute("data-findrow");
   el.addEventListener("mouseenter",function(){findSetAt(i,false);});el.addEventListener("click",function(){findSetAt(i,false);findActivate(findRows[i]);});});
  findSetAt(0,false);}
 function findActivate(r){if(!r)return;findPreviewClear();
  if(r.type==="part"){reviewClear();focusPart(r.data.ref,true);}
  else if(r.type==="net"){reviewSet({nets:[r.data.net],fit:true,context:false,kind:"net"});stickyNetSet(netCollapse(r.data.net));}
  else if(r.type==="drc"){reviewClear();drcGoto(r.data.i);}
  else if(r.type==="group"){reviewSet({refs:r.data.refs,fit:true,context:false,kind:"subcircuit"});if(!RO)selectGroup(r.data.g,true);}
  else if(r.type==="text"){reviewClear();focusPoint(r.data.x,r.data.y);}
  try{findInput.focus({preventScroll:true});}catch(e){findInput.focus();}}
 function findOpenPanel(){var fresh=!findOpen;if(fresh){var active=document.querySelector('.side-tab.active[data-sidetab]');
   if(active)findPrev=active.getAttribute("data-sidetab")||"side-props";}
  findOpen=true;pcbSideTab("side-find");findInput.setAttribute("aria-expanded","true");if(fresh)findRender();}
 function findTabLeave(){if(!findOpen)return;findOpen=false;findInput.setAttribute("aria-expanded","false");findPreviewClear();}
 function findClose(){if(!findOpen)return;var prev=findPrev;findTabLeave();try{findInput.blur();}catch(e){}pcbSideTab(prev||"side-props");}
 window.PCBFindIsOpen=function(){return findOpen;};window.PCBFindClose=findClose;window.PCBFindTabLeave=findTabLeave;
 window.PCBFindRefresh=function(){if(findOpen)findRender();};
 if(/Mac|iPhone|iPad/.test(navigator.platform||"")){var k=findInput.parentNode.querySelector("kbd");if(k)k.textContent="⌘ F";}
 findInput.addEventListener("focus",findOpenPanel);findInput.addEventListener("input",findRender);
 findInput.addEventListener("keydown",function(ev){
  if(ev.key==="ArrowDown"||ev.key==="ArrowUp"){ev.preventDefault();ev.stopPropagation();findSetAt(findAt+(ev.key==="ArrowDown"?1:-1),true);return;}
  if(ev.key==="Enter"){ev.preventDefault();ev.stopPropagation();if(findAt<0)findSetAt(0,true);findActivate(findRows[findAt]);return;}
  if(ev.key==="Escape"){ev.preventDefault();ev.stopPropagation();findClose();return;}
  if(ev.key==="F3"){ev.preventDefault();ev.stopPropagation();findSetAt(findAt+(ev.shiftKey?-1:1),true);findActivate(findRows[findAt]);}});
 findClear.addEventListener("click",function(){findInput.value="";findRender();findInput.focus();});
 document.addEventListener("keydown",function(ev){
  if((ev.ctrlKey||ev.metaKey)&&!ev.altKey&&findNorm(ev.key)==="f"){ev.preventDefault();ev.stopPropagation();findOpenPanel();findInput.focus();findInput.select();return;}
  if(ev.key==="F3"&&ev.target!==findInput&&findInput.value.trim()){ev.preventDefault();var wasOpen=findOpen;findOpenPanel();
   if(wasOpen)findSetAt(findAt+(ev.shiftKey?-1:1),true);findActivate(findRows[findAt]);}},true);
})();
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
// On load, offer to restore a localStorage draft when one exists that is newer
// than the served layout's save-time OR based on a different sidecar rev (the
// board changed in another window). Neither → the draft is obsolete; drop it.
(function(){if(RO)return;
 var raw=null;try{raw=localStorage.getItem(DRAFT_KEY);}catch(e){}
 if(!raw)return;
 var d=null;try{d=JSON.parse(raw);}catch(e){clearDraft();return;}
 if(!d||!d.poses||!d.poses.length){clearDraft();return;}
 var servedTs=0;(PCB.layouts||[]).forEach(function(L){if(L&&L.ts>servedTs)servedTs=L.ts;});
 var stale=(d.rev!==(PCB.rev||0));
 if(!((d.ts||0)>servedTs||stale)){clearDraft();return;}
 showDraftBanner(d,stale);
})();
// ── Layout-progress chip + punch-list panel ─────────────────────────────
// The scorebar carries a "Stage N/6 · <Stage> — <wave> d/t" chip built from
// the compact GET /api/layout-progress/<name> response (schematic → sub-
// circuits → board setup → placement → routing → fab-ready). Clicking it loads
// a read-only punch list: the six-stage ladder, the current stage's waves +
// open items, and any stale-plan warnings. Ref items focus/flash the part
// (shared cross-probe path); net items spotlight the net. Refreshed after
// Save / Update / Stamp / a lock toggle only while the panel is open — never
// per drag and never as page-load work.
var progData=null,progPanelEl=null,progOpen=false,progTimer=null,progSeq=0,progLoading=false,progDirty=true;
var PROG_LABELS={schematic:"Schematic",sub_circuits:"Sub-circuits",
 board_setup:"Board setup",placement:"Placement",routing:"Routing",fab_ready:"Fab-ready"};
function progStageLabel(id){if(PROG_LABELS[id])return PROG_LABELS[id];
 return String(id||"").replace(/_/g," ").replace(/^./,function(c){return c.toUpperCase();});}
(function(){if(document.getElementById("prog-css"))return;
 var st=document.createElement("style");st.id="prog-css";
 st.textContent=
  '#sc-progress{cursor:pointer;white-space:nowrap}'+
  '#sc-progress:hover{border-color:#5a8fd6;color:#f0f1f3}'+
  '#sc-progress.prog-done{color:#4cae54;border-color:#2f7d38}'+
  '#sc-progress.prog-open{border-color:#5a8fd6;color:#f0f1f3}'+
  '#pcb-progress-panel{position:fixed;z-index:60;background:#232428;border:1px solid #3a3b40;'+
   'border-radius:8px;box-shadow:0 10px 30px rgba(0,0,0,.5);padding:6px 0 8px;min-width:320px;'+
   'max-width:440px;max-height:72vh;overflow-y:auto;font-size:12px;color:#d6d7db}'+
  '#pcb-progress-panel[hidden]{display:none}'+
  '.prog-h{font-weight:700;color:#f0f1f3;padding:6px 12px 8px;border-bottom:1px solid #2c2d31;margin-bottom:4px}'+
  '.prog-stage{display:flex;align-items:center;gap:8px;padding:5px 12px}'+
  '.prog-stage .prog-glyph{width:14px;text-align:center;flex:none}'+
  '.prog-stage.cur{background:rgba(90,143,214,.14)}'+
  '.prog-stage.cur .prog-glyph{color:#6ba1e8}'+
  '.prog-stage.done .prog-glyph{color:#4cae54}'+
  '.prog-stage .prog-name{color:#e4e5e9;font-weight:600}'+
  '.prog-stage.done .prog-name,.prog-stage.pending .prog-name{color:#9b9ca3;font-weight:500}'+
  '.prog-stage.pending .prog-name{color:#85868d}'+
  '.prog-stage .prog-tally{margin-left:auto;color:#9b9ca3;font-variant-numeric:tabular-nums}'+
  '.prog-detail{padding:0 12px 6px 34px}'+
  '.prog-wave{display:flex;align-items:center;gap:6px;padding:2px 0;color:#9b9ca3;font-size:11.5px}'+
  '.prog-wave.cur{color:#cbd3dd;font-weight:600}'+
  '.prog-wave .prog-tally{margin-left:auto;font-variant-numeric:tabular-nums}'+
  '.prog-item{display:flex;align-items:center;gap:7px;padding:3px 6px;border-radius:5px;color:#c9cbd1}'+
  '.prog-item.clk{cursor:pointer}'+
  '.prog-item.clk:hover{background:#2c2d31}'+
  '.prog-item .prog-ref{font-family:ui-monospace,monospace;color:#8ab8f0;flex:none}'+
  '.prog-item .prog-msg{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}'+
  '.prog-item .prog-go{margin-left:auto;color:#6ba1e8;flex:none;font-size:10.5px}'+
  '.prog-warns{border-top:1px solid #2c2d31;margin-top:4px;padding:6px 12px 0}'+
  '.prog-warn{display:flex;gap:7px;padding:2px 0;color:#d8a03c;font-size:11.5px}'+
  '.prog-empty{padding:8px 12px;color:#85868d;font-size:11.5px}';
 (document.head||document.documentElement).appendChild(st);})();
function progItemHtml(it){var ref=it.ref||"",net=it.net||"",pcb=it.pcb_target||"";
 var schematic=it.kind==="erc-errors",clk=!!(pcb||schematic||ref||net);
 var chip=ref?('<span class="prog-ref">'+pEsc(ref)+'</span>')
  :(net?('<span class="prog-ref">'+pEsc(net)+'</span>'):'');
 var msg=it.message||it.kind||"";if(it.count&&it.count>1)msg+=" ("+it.count+")";
 return '<div class="prog-item'+(clk?' clk':'')+'"'+
  (pcb?(' data-prog-pcb="'+pEsc(pcb)+'"'):'')+
  (schematic?' data-prog-schematic="1"':'')+
  (ref&&!pcb?(' data-prog-ref="'+pEsc(ref)+'"'):'')+
  (net?(' data-prog-net="'+pEsc(net)+'"'):'')+
  ' title="'+pEsc(msg)+'">'+chip+'<span class="prog-msg">'+pEsc(msg)+'</span>'+
  ((pcb||schematic)?'<span class="prog-go">Open ↗</span>':'')+'</div>';}
// Spotlight a net item: reuse the existing gold-glow selection, then centre the
// view on the net's pad-bbox so it's actually on screen (else "focus the parts").
function progFocusNet(net){if(!net)return;selNet(net);
 var x0=1e18,y0=1e18,x1=-1e18,y1=-1e18,n=0;
 P.forEach(function(p,i){(p.pads||[]).forEach(function(pd){if(pd.net!==net)return;
  var c=wpt(i,pd.x,pd.y);if(c.x<x0)x0=c.x;if(c.x>x1)x1=c.x;if(c.y<y0)y0=c.y;if(c.y>y1)y1=c.y;n++;});});
 if(n)focusPoint((x0+x1)/2,(y0+y1)/2);}
function progEnsureChip(){var chip=document.getElementById("sc-progress");if(chip)return chip;
 if(PCB.sub&&PCB.sub.length)return null;var bar=document.querySelector(".pcb-placement")||document.querySelector(".pcb-bar");if(!bar)return null;
 chip=document.createElement("span");chip.className="score";chip.id="sc-progress";
 chip.textContent="Progress";chip.title="Load the layout progress punch list";
 chip.addEventListener("click",progPanelToggle);
 var host=bar.querySelector(".placement-h")||bar;
 var anchor=document.getElementById("pcb-srcchip");
 if(anchor&&anchor.parentNode===host)host.insertBefore(chip,anchor.nextSibling);
 else host.insertBefore(chip,host.firstChild);return chip;}
function progRenderChip(){var chip=progEnsureChip();if(!chip)return;
 var pr=progData;
 if(!pr||!pr.stages||!pr.stages.length){
  chip.textContent=progLoading?"Progress …":"Progress";
  chip.title=progLoading?"Loading layout progress…":"Load the layout progress punch list";return;}
 var stages=pr.stages,total=stages.length;
 var allDone=stages.every(function(s){return s.status==="done";});
 chip.classList.toggle("prog-done",allDone);
 if(allDone){chip.textContent="Fab-ready ✓";
  chip.title="All "+total+" layout stages complete — the board is fab-ready. Click for the punch list.";return;}
 var idx=-1,cur=null;
 for(var i=0;i<stages.length;i++)if(stages[i].status==="current"){idx=i;cur=stages[i];break;}
 if(idx<0)for(var j=0;j<stages.length;j++)if(stages[j].status!=="done"){idx=j;cur=stages[j];break;}
 if(idx<0){idx=0;cur=stages[0];}
 var label=progStageLabel(cur.id);
 var txt="Stage "+(idx+1)+"/"+total+" · "+label;
 var wtxt="",wv=null;
 if(cur.waves&&cur.waves.length){
  if(pr.current_wave)for(var k=0;k<cur.waves.length;k++)if(cur.waves[k].name===pr.current_wave){wv=cur.waves[k];break;}
  if(!wv)for(var k2=0;k2<cur.waves.length;k2++)if(cur.waves[k2].status==="current"){wv=cur.waves[k2];break;}
  if(wv)wtxt=" — "+wv.name+" "+((wv.done||0)+"/"+(wv.total||0));}
 if(!wtxt&&cur.total!=null)wtxt=" "+((cur.done||0)+"/"+cur.total);
 chip.textContent=txt+wtxt;
 chip.title="Layout progress — click for the punch list. Stage "+(idx+1)+" of "+total+": "+label+
  (pr.current_wave?(" (wave: "+pr.current_wave+")"):"");}
function progRenderPanel(){if(!progPanelEl)return;var pr=progData;
 if(!pr||!pr.stages||!pr.stages.length){progPanelEl.innerHTML='<div class="prog-empty">'+
  (progLoading?'Loading layout progress…':'No layout-progress data.')+'</div>';return;}
 var h='<div class="prog-h">Layout progress</div>';
 (pr.stages||[]).forEach(function(st){
  var status=st.status||"pending";
  var glyph=status==="done"?"✓":(status==="current"?"▶":"○");
  var cls=status==="done"?"done":(status==="current"?"cur":"pending");
  var tally=(st.total!=null)?((st.done||0)+"/"+st.total):"";
  h+='<div class="prog-stage '+cls+'"><span class="prog-glyph">'+glyph+'</span>'+
   '<span class="prog-name">'+pEsc(progStageLabel(st.id))+'</span>'+
   (tally?'<span class="prog-tally">'+tally+'</span>':'')+'</div>';
  // Only the current stage expands — its waves (tally) then its open items.
  if(status!=="current")return;
  var waves=(st.waves&&st.waves.length)?st.waves:null,items=(st.items&&st.items.length)?st.items:null;
  if(!waves&&!items)return;
  h+='<div class="prog-detail">';
  if(waves)waves.forEach(function(wv){
   var wcur=(wv.status==="current")||(pr.current_wave&&wv.name===pr.current_wave);
   h+='<div class="prog-wave'+(wcur?' cur':'')+'"><span>'+pEsc(wv.name||"")+'</span>'+
    '<span class="prog-tally">'+((wv.done||0)+"/"+(wv.total||0))+'</span></div>';});
  if(items)items.forEach(function(it){h+=progItemHtml(it);});
  h+='</div>';});
 var warns=pr.warnings||[];
 if(warns.length){h+='<div class="prog-warns">';
  warns.forEach(function(wn){h+='<div class="prog-warn">⚠ <span class="prog-msg">'+
   pEsc(wn.message||wn.kind||"")+'</span></div>';});
  h+='</div>';}
 progPanelEl.innerHTML=h;
 progPanelEl.querySelectorAll("[data-prog-pcb]").forEach(function(r){
  r.addEventListener("click",function(){location.href="/pcb-layout/"+
   encodeURIComponent(r.getAttribute("data-prog-pcb"));});});
 progPanelEl.querySelectorAll("[data-prog-schematic]").forEach(function(r){
  r.addEventListener("click",function(){location.href="/schematics/"+encodeURIComponent(PCB.name);});});
 progPanelEl.querySelectorAll("[data-prog-ref]").forEach(function(r){
  r.addEventListener("click",function(){focusPart(r.getAttribute("data-prog-ref"));});});
 progPanelEl.querySelectorAll("[data-prog-net]").forEach(function(r){
  r.addEventListener("click",function(){progFocusNet(r.getAttribute("data-prog-net"));});});}
function progEnsurePanel(){if(progPanelEl)return progPanelEl;
 progPanelEl=document.createElement("div");progPanelEl.id="pcb-progress-panel";progPanelEl.hidden=true;
 document.body.appendChild(progPanelEl);
 document.addEventListener("click",function(ev){if(!progOpen)return;
  var chip=document.getElementById("sc-progress");
  if(chip&&(ev.target===chip||chip.contains(ev.target)))return;
  if(progPanelEl.contains(ev.target))return;progPanelClose();});
 document.addEventListener("keydown",function(ev){if(ev.key==="Escape"&&progOpen)progPanelClose();});
 return progPanelEl;}
function progPanelPos(){var chip=document.getElementById("sc-progress");if(!chip||!progPanelEl)return;
 var r=chip.getBoundingClientRect();progPanelEl.style.top=(r.bottom+6)+"px";
 var w=progPanelEl.offsetWidth||340,left=r.left;
 if(left+w>window.innerWidth-8)left=Math.max(8,window.innerWidth-8-w);
 progPanelEl.style.left=left+"px";}
function progPanelOpen(){progEnsurePanel();progRenderPanel();progPanelEl.hidden=false;progOpen=true;
 progPanelPos();var chip=document.getElementById("sc-progress");if(chip)chip.classList.add("prog-open");
 if(progDirty||!progData)progFetch();}
function progPanelClose(){if(progPanelEl)progPanelEl.hidden=true;progOpen=false;
 var chip=document.getElementById("sc-progress");if(chip)chip.classList.remove("prog-open");}
function progPanelToggle(ev){if(ev)ev.stopPropagation();if(progOpen)progPanelClose();else progPanelOpen();}
function progFetch(){if(PCB.sub&&PCB.sub.length)return; // progress is design-level; skip sub previews
 if(progLoading)return;progLoading=true;progDirty=false;progRenderChip();if(progOpen)progRenderPanel();
 var seq=++progSeq,q=curLayout?("?layout="+encodeURIComponent(curLayout)):"";
 fetch("/api/layout-progress/"+encodeURIComponent(PCB.name)+q)
  .then(function(r){return r.ok?r.json():null;})
  .then(function(j){if(seq!==progSeq)return; // a newer refresh superseded us
   progLoading=false;progData=j;progRenderChip();if(progOpen)progRenderPanel();
   if(progDirty&&progOpen)progressRefresh();})
  .catch(function(){if(seq!==progSeq)return;progLoading=false;progDirty=true;progRenderChip();if(progOpen)progRenderPanel();});}
// Save / Update / Stamp / lock mark the punch list stale. Only an open panel
// refreshes, so a normal editing session does no completion-ladder work.
function progressRefresh(){progDirty=true;if(!progOpen)return;if(progTimer)clearTimeout(progTimer);
 progTimer=setTimeout(function(){progTimer=null;progFetch();},250);}
window.addEventListener("resize",function(){if(progOpen)progPanelPos();});
progEnsureChip(); // cheap placeholder; the first click performs the analysis

// ── Frame-time HUD + ?fbench=1 deterministic camera benchmark ───────────
// The A/B instrument for the WebGPU spike. The SAME harness runs on the 2D
// path and on ?gpu=1 — it drives the REAL setVB/zoomAt seams one step per
// requestAnimationFrame, so every step renders one genuine frame through
// whichever renderer is live, and the two runs are comparable by construction.
// Nothing here is reachable without a URL flag.
function fbPct(a,q){if(!a.length)return 0;
 var s=a.slice().sort(function(x,y){return x-y;});
 return s[Math.min(s.length-1,Math.max(0,Math.round(q*(s.length-1))))];}
// Rolling frame-time readout over the last 120 display frames. Deliberately a
// free-running rAF loop rather than a scenePaint hook: it measures what the
// user actually sees (compositor cadence), and an idle rAF that only pushes a
// number costs nothing measurable.
var hudEl=null,hudT=[],hudPrev=0,hudNext=0;
function hudStart(){
 hudEl=document.createElement("div");
 hudEl.style.cssText="position:fixed;left:10px;bottom:10px;z-index:9999;pointer-events:none;"+
  "font:11px/1.35 ui-monospace,SFMono-Regular,Menlo,monospace;background:rgba(0,10,22,.84);"+
  "color:#8be9ff;border:1px solid #21384f;border-radius:5px;padding:4px 8px;white-space:pre";
 hudEl.textContent="…";
 document.body.appendChild(hudEl);
 var tick=function(){
  var t=(window.performance&&performance.now)?performance.now():Date.now();
  if(hudPrev){hudT.push(t-hudPrev);if(hudT.length>120)hudT.shift();}
  hudPrev=t;
  if(t>=hudNext&&hudT.length>8){hudNext=t+250;
   var p50=fbPct(hudT,0.5);
   hudEl.textContent=(gpuOn?"GPU":"2D")+"  p50 "+p50.toFixed(1)+"  p95 "+
    fbPct(hudT,0.95).toFixed(1)+" ms  "+(1000/Math.max(p50,0.001)).toFixed(0)+" fps";}
  requestAnimationFrame(tick);};
 requestAnimationFrame(tick);}
// The camera path, as a flat list of one-frame steps. fit → zoom to 8x →
// 3 alternating pan sweeps each crossing ~60% of the board → zoom back out.
// Short, explicit dwell entries make the automated run readable to a human and
// expose delayed compositor/GPU stalls at the expensive endpoints. They record
// into their own `pause` phase, so they never contaminate movement percentiles.
// Every step goes through zoomAt/setVB, i.e. exactly the seams a wheel or a
// trackpad drag drives, so the harness cannot accidentally measure a path the
// real viewer never takes.
function fbProgram(){
 var st=[],i,n,ZN=60,PN=120;
 var dwell=function(label,ms){st.push({p:"pause",label:label,wait:ms,f:function(){}});};
 var ctr=function(){var m=svgMetricsGet();
  return {x:m.left+m.width/2,y:m.top+m.height/2};};
 var zin=Math.pow(1/8,1/ZN),zout=Math.pow(8,1/ZN);
 var zstep=function(f){return function(){var c=ctr();zoomAt(c.x,c.y,f);};};
 dwell("fit",300);
 for(i=0;i<ZN;i++)st.push({p:"zoom_in",f:zstep(zin)});
 dwell("max_zoom",550);
 // Park the viewport at the left end of the sweep so all three sweeps stay
 // over board content instead of running off the edge. Its own phase — the
 // jump is one big non-representative frame and must not pollute `pan`.
 st.push({p:"seek",f:function(){vb.x=0.2*VBW-vb.w/2;setVB();}});
 dwell("seek",250);
 var dx=0.6*VBW/PN;
 for(n=0;n<3;n++){
  var d=(n%2)?-dx:dx;
  var pstep=function(v){return function(){vb.x+=v;setVB();};}(d);
  for(i=0;i<PN;i++)st.push({p:"pan",f:pstep});
  dwell("turn_"+(n+1),350);}
 for(i=0;i<ZN;i++)st.push({p:"zoom_out",f:zstep(zout)});
 dwell("fit_end",300);
 return st;}
function fbStat(a){
 return {n:a.length,p50:+fbPct(a,0.5).toFixed(2),p95:+fbPct(a,0.95).toFixed(2),
  max:+Math.max.apply(null,a).toFixed(2)};}
function fbReport(rec,order){
 var out={mode:gpuOn?"gpu":"2d",design:PCB.name,dpr:window.devicePixelRatio||1};
 order.forEach(function(p){if(rec[p]&&rec[p].length)out[p]=fbStat(rec[p]);});
 window.__fbench=out;
 try{console.log("fbench "+JSON.stringify(out));}catch(e){}
 var d=document.createElement("div");
 d.style.cssText="position:fixed;right:12px;top:70px;z-index:10000;"+
  "font:12px/1.55 ui-monospace,SFMono-Regular,Menlo,monospace;background:rgba(0,10,22,.93);"+
  "color:#e6edf3;border:1px solid #2d4a63;border-radius:6px;padding:9px 12px;white-space:pre";
 var lines=["fbench · "+out.mode+" · "+out.design+" · dpr "+out.dpr];
 order.forEach(function(p){var s=out[p];if(!s)return;
  lines.push(p+"        ".slice(0,Math.max(1,9-p.length))+
   "n="+s.n+"  p50 "+s.p50.toFixed(2)+"  p95 "+s.p95.toFixed(2)+"  max "+s.max.toFixed(2));});
 d.textContent=lines.join("\n");
 document.body.appendChild(d);}
function fbRun(){
 var prog=fbProgram(),rec={},i=0,t0=0;
 var now=function(){return (window.performance&&performance.now)?performance.now():Date.now();};
 // One step per frame, and the next rAF is requested AFTER the step runs — so
 // the scenePaint that step queued (paintSoon → rAF) is already ahead of us in
 // the queue and executes FIRST on the next frame. Each entry-to-entry delta
 // therefore brackets exactly one full paint of the state the previous step set.
 var step=function(){
  var t=now();
  if(t0){var p=prog[i-1].p;(rec[p]||(rec[p]=[])).push(t-t0);}
  t0=t;
  if(i>=prog.length){fbReport(rec,["zoom_in","seek","pan","zoom_out"]);return;}
  var ent=prog[i++];ent.f();
  if(ent.wait)setTimeout(function(){requestAnimationFrame(step);},ent.wait);
  else requestAnimationFrame(step);};
 fitVB();paintSoon();
 setTimeout(function(){requestAnimationFrame(step);},60);}
// ── WebGPU renderer boot (default-on; ?gpu=0 opts out) ─────────────────
// Async and entirely optional: until it RESOLVES true, gpuOn is false and every
// seam above is a dead branch, so the page renders exactly as it does today.
// A refusal (no navigator.gpu, no adapter, any throw) or a later device loss
// simply leaves it that way — the one repaint below restores the full 2D scene.
// Status-bar renderer chip (full page only — the id is absent on embeds, so
// stSet no-ops there). Reflects the LIVE state: "2D" until init resolves,
// "GPU" after, back to "2D" on device loss.
function gpuStatusSync(){var e=document.getElementById("st-gpu");if(!e)return;
 e.textContent=gpuOn?"GPU":"2D";e.style.color=gpuOn?"#8be9ff":"";}
gpuStatusSync();
if(GPU_REQ&&window.PCBGpu&&navigator.gpu&&CV.parentNode){
 try{
  PCBGpu.init({PCB:PCB,S:S,MX:MX,MY:MY,M:M,nsig:NSIG,TH:TH,
   layerColor:layerColor,ref:CV,host:CV.parentNode,
   // Colour + pour GEOMETRY hooks: the rules stay in this file (one expression,
   // shared with the 2D painters), the renderer only bakes what they return.
   trackColor:gpuTrackColor,trackChords:trackChords,viaColor:gpuViaColor,padColor:gpuPadColor,
   pours:gpuPourGeom,
   onLost:function(){gpuOn=false;gpuStatusSync();dragCacheDrop();paintSoon();}})
  .then(function(ok){if(!ok)return;
   gpuOn=true;gpuStatusSync();
   dragCacheDrop();paintSoon();})
  .catch(function(){});
 }catch(e){}}
if(FBENCH)hudStart(); // HUD is a bench instrument now that GPU is the default
if(FBENCH)setTimeout(fbRun,1000); // let layout, the first paint and the async GPU init settle
})();
