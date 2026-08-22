(function(){"use strict";
// Layer spellings from the page's inline RRLayers object (emitted out of
// src/board_layers.zig) — this client names no KiCad layer of its own.
var LN=(typeof RRLayers!=="undefined")?RRLayers:{};
var data=null,frame=0,playing=false,timer=null;
var canvas=document.getElementById("rr-canvas"),wrap=document.getElementById("rr-canvas-wrap"),ctx=canvas.getContext("2d");
var view={scale:10,panX:0,panY:0},drag=null;
var $=function(id){return document.getElementById(id);};
var input=$("rr-files"),drop=$("rr-drop"),status=$("rr-status"),app=$("rr-app");
var selected=[];

function ends(name,suffix){return name.toLowerCase().endsWith(suffix);}
function setFiles(files){selected=Array.prototype.slice.call(files||[]).filter(function(f){return ends(f.name,".kicad_pcb")||ends(f.name,".kicad_pro");});
 $("rr-file-names").textContent=selected.length?selected.map(function(f){return f.name;}).join(" · "):"No files selected";}
input.addEventListener("change",function(){setFiles(input.files);});
["dragenter","dragover"].forEach(function(n){drop.addEventListener(n,function(e){e.preventDefault();drop.classList.add("drag");});});
["dragleave","drop"].forEach(function(n){drop.addEventListener(n,function(e){e.preventDefault();drop.classList.remove("drag");});});
drop.addEventListener("drop",function(e){setFiles(e.dataTransfer.files);});

function parseReview(r){return r.text().then(function(t){var j;try{j=JSON.parse(t);}catch(_){throw new Error("The server returned an invalid review response.");}if(!r.ok||!j.ok)throw new Error(j.error||("Review failed (HTTP "+r.status+")"));return j;});}

$("rr-upload").addEventListener("submit",function(e){e.preventDefault();
 var board=selected.find(function(f){return ends(f.name,".kicad_pcb");});
 if(!board){setStatus("Select a .kicad_pcb file first.","error");return;}
 var stem=board.name.toLowerCase().replace(/\.kicad_pcb$/,"");
 var project=selected.find(function(f){return ends(f.name,".kicad_pro")&&f.name.toLowerCase().replace(/\.kicad_pro$/,"")===stem;})||selected.find(function(f){return ends(f.name,".kicad_pro");});
 var form=new FormData();form.append("board",board,board.name);if(project)form.append("project",project,project.name);
 var run=$("rr-run");run.disabled=true;setStatus("Routing in memory. Dense boards can take a few minutes…","running");
 fetch("/api/kicad-route-review/run",{method:"POST",body:form}).then(parseReview)
 .then(function(j){loadReview(j);setStatus("Timeline ready"+(project?" with project rules":" (no .kicad_pro rules loaded)"),"");app.scrollIntoView({behavior:"smooth",block:"start"});})
 .catch(function(err){setStatus(err.message||"Route review failed","error");})
 .finally(function(){run.disabled=false;});
});

function ageText(ts){if(!ts)return "";var s=Math.max(0,Math.floor(Date.now()/1e3-ts));if(s<60)return "just now";if(s<3600)return Math.floor(s/60)+"m ago";if(s<86400)return Math.floor(s/3600)+"h ago";return Math.floor(s/86400)+"d ago";}
var designButtons=Array.prototype.slice.call(document.querySelectorAll(".rr-design,.rr-design-cached"));
designButtons.forEach(function(btn){btn.addEventListener("click",function(){
 var name=btn.dataset.design,cached=btn.classList.contains("rr-design-cached");
 designButtons.forEach(function(b){b.disabled=true;});
 setStatus(cached?"Loading the saved replay for "+name+"…":"Routing "+name+" from its design placement. Dense boards can take a few minutes…","running");
 fetch("/api/design-route-review/"+(cached?"cached/":"run/")+encodeURIComponent(name)).then(parseReview)
 .then(function(j){loadReview(j);var when=ageText(j.generated_at);
  setStatus(cached?"Saved replay loaded — "+name+(when?" (routed "+when+")":""):"Timeline ready — "+name+" routed fresh and saved for later","");
  app.scrollIntoView({behavior:"smooth",block:"start"});})
 .catch(function(err){setStatus(err.message||"Design replay failed","error");})
 .finally(function(){designButtons.forEach(function(b){b.disabled=false;});});
});});

function setStatus(message,kind){status.className="rr-status"+(kind?" "+kind:"");status.textContent=message;}
function loadReview(j){stop();data=j;
 if(!Array.isArray(data.timeline)||!data.timeline.length)data.timeline=[{seq:0,kind:"complete",net:null,related:[],round:0,routed:data.final.routed,total:data.final.total,trace_mm:0,tracks:[],vias:[]}];
 app.hidden=false;$("rr-board-name").textContent=data.name;
 var rules=data.mode==="design"?"design rules + authored plan":(data.project_loaded?"project rules loaded":"router defaults");
 $("rr-board-meta").textContent=data.parts.length+" parts · "+data.nets.length+" nets · "+(data.zones||[]).length+" zones · "+data.timeline.length+" decisions · "+rules;
 var errs=(data.final.drc||[]).filter(function(v){return v.severity==="err";}).length;
 var warns=(data.final.drc||[]).length-errs;$("rr-drc-count").textContent=errs+"E / "+warns+"W";
 $("rr-slider").max=String(data.timeline.length-1);buildList();fit();setFrame(0,false);
}

var labels={
 initial:["Setup","Reference copper removed","The fixed footprints, pads, zones, and outline are retained. The trace and via field starts empty."],
 plane_routed:["Plane pass","Plane connection added","A plane-backed net was connected by its pour or by a legal via drop."],
 plane_failed:["Plane pass","Plane connection failed","The router could not find a legal plane connection for this net."],
 net_routed:["Greedy pass","Net routed","This net claimed a legal path in priority order."],
 net_failed:["Greedy pass","Net failed","No legal path was found with the copper already on the board."],
 ripup:["Rip-up","Blocking copper removed","The failed net and its eligible blockers were removed for a bounded retry."],
 reroute_candidate:["Rip-up","Candidate reroute evaluated","The target was routed first, followed by the displaced nets. The next step records whether this board state was kept."],
 reroute_accepted:["Rip-up","Candidate accepted","The speculative route connected more nets or shortened copper without reducing the connected count."],
 reroute_rejected:["Rollback","Candidate rejected","The retry did not improve the board, so the exact pre-rip-up state was restored."],
 escape_stubs:["Post-pass","Escape stubs added","Authored pad escape stubs were added after the net routing passes."],
 return_stitching:["Post-pass","Return paths stitched","Ground stitching vias were added near signal layer changes where legal."],
 bend_smoothing:["RF discipline","RF bends smoothed","This max-freq net's corners were reshaped into tangent arcs the moment it routed — aiming for the largest radius that fits (minimum 3x the trace width), holding the straight pad-escape reserve, so later nets route around the real arc copper. Corners that missed the minimum radius are flagged by the sharp_bend DRC check."],
 complete:["Complete","Routing run complete","This is the final copper state produced by the run."]
};
function eventText(ev){var base=labels[ev.kind]||["Router",ev.kind.replace(/_/g," "),""];var title=base[1]+(ev.net?": "+ev.net:"");var detail=base[2];if(ev.kind==="net_failed"&&ev.net&&(data.final.search_limited||[]).indexOf(ev.net)>=0)detail="The route search reached its expansion budget. This is an algorithm/search-limit failure, not proof that no legal path exists.";if(ev.related&&ev.related.length)detail+=" Nets in this transaction: "+ev.related.join(", ")+".";if(ev.round)detail+=" Rip-up round "+ev.round+".";return [base[0],title,detail];}
function dotClass(kind){if(kind.indexOf("failed")>=0||kind==="reroute_rejected")return "fail";if(kind==="ripup"||kind==="reroute_candidate")return "rip";if(kind==="complete")return "end";if(kind.indexOf("routed")>=0||kind==="reroute_accepted")return "ok";return "";}
function groupKeyOf(ev){var phase=(labels[ev.kind]||["Router"])[0];
 if(phase==="Rip-up"||phase==="Rollback")return "Rip-up round "+(ev.round||1);
 if(ev.kind==="net_routed"||ev.kind==="net_failed"||(ev.kind==="bend_smoothing"&&ev.net)){
  if(data.net_class){var ni=data.nets.indexOf(ev.net),nc=ni>=0?data.net_class[ni]:null;
   return "Net routing — "+(nc&&nc.name?nc.name:"default")+" class";}
  return "Net routing";}
 return phase;}
var collapsed=new Set();
function applyCollapse(){document.querySelectorAll("#rr-list li").forEach(function(el){
 var g=+el.dataset.group;
 if(el.classList.contains("group-head"))el.classList.toggle("closed",collapsed.has(g));
 else el.classList.toggle("hidden",collapsed.has(g));});}
function expandGroupOf(el){var g=+el.dataset.group;if(collapsed.has(g)){collapsed.delete(g);applyCollapse();}}
function buildList(){var list=$("rr-list");list.textContent="";collapsed.clear();var frag=document.createDocumentFragment();
 var lastKey=null,gi=-1,headMeta=null,count=0,startRouted=0;
 data.timeline.forEach(function(ev,i){var key=groupKeyOf(ev);
  if(key!==lastKey){lastKey=key;gi++;count=0;startRouted=i?data.timeline[i-1].routed:0;
   var head=document.createElement("li");head.className="group-head";head.dataset.group=String(gi);
   var chev=document.createElement("span");chev.className="chev";
   var ttl=document.createElement("span");ttl.className="group-title";ttl.textContent=key;
   headMeta=document.createElement("span");headMeta.className="group-meta";
   head.append(chev,ttl,headMeta);
   head.addEventListener("click",function(){var g=+head.dataset.group;if(collapsed.has(g))collapsed.delete(g);else collapsed.add(g);applyCollapse();});
   frag.appendChild(head);}
  count++;var gained=ev.routed-startRouted;
  headMeta.textContent=count+(count===1?" step":" steps")+(gained>0?" · +"+gained+(gained===1?" net":" nets"):"");
  var li=document.createElement("li");li.dataset.step=String(i);li.dataset.group=String(gi);var t=eventText(ev);
  var seq=document.createElement("span");seq.className="seq";seq.textContent=String(i+1);
  var dotEl=document.createElement("span");dotEl.className="dot "+dotClass(ev.kind);
  var name=document.createElement("span");name.className="event-name";name.textContent=t[1];
  var meta=document.createElement("span");meta.className="event-meta";meta.textContent=ev.routed+"/"+ev.total;
  li.append(seq,dotEl,name,meta);li.addEventListener("click",function(){stop();setFrame(i,false);});frag.appendChild(li);
 });list.appendChild(frag);}

function setFrame(i,autoScroll){if(!data)return;frame=Math.max(0,Math.min(data.timeline.length-1,i));var ev=data.timeline[frame],prev=frame?data.timeline[frame-1]:null,t=eventText(ev);
 $("rr-slider").value=String(frame);$("rr-step-count").textContent=(frame+1)+" / "+data.timeline.length;
 $("rr-phase").textContent=t[0];$("rr-event-title").textContent=t[1];$("rr-event-detail").textContent=t[2];
 $("rr-routed").textContent=ev.routed+" / "+ev.total;$("rr-trace").textContent=(ev.trace_mm||0).toFixed(1)+" mm";$("rr-vias").textContent=(ev.vias||[]).length;
 renderDeltas(ev,prev);document.querySelectorAll("#rr-list li.active").forEach(function(el){el.classList.remove("active");});
 var active=$("rr-list").querySelector('[data-step="'+frame+'"]');if(active){expandGroupOf(active);active.classList.add("active");if(autoScroll)active.scrollIntoView({block:"nearest"});}
 draw();if(playing&&frame===data.timeline.length-1)stop();}
function signed(n,digits){if(Math.abs(n)<Math.pow(10,-digits))return "0";return (n>0?"+":"")+n.toFixed(digits);}
function renderDeltas(ev,prev){var box=$("rr-deltas");box.textContent="";var values=prev?[
 ["nets",ev.routed-prev.routed,0],["tracks",ev.tracks.length-prev.tracks.length,0],["vias",ev.vias.length-prev.vias.length,0],["trace mm",ev.trace_mm-prev.trace_mm,1]
 ]:[["tracks",ev.tracks.length,0],["vias",ev.vias.length,0],["trace mm",ev.trace_mm,1]];
 values.forEach(function(v){var s=document.createElement("span");s.textContent=v[0]+" "+signed(v[1],v[2]);if(v[1]>0)s.className="pos";if(v[1]<0)s.className="neg";box.appendChild(s);});}

$("rr-slider").addEventListener("input",function(){stop();setFrame(parseInt(this.value,10)||0,false);});
$("rr-prev").addEventListener("click",function(){stop();setFrame(frame-1,true);});
$("rr-next").addEventListener("click",function(){stop();setFrame(frame+1,true);});
$("rr-play").addEventListener("click",function(){if(playing)stop();else play();});
function play(){if(!data)return;if(frame>=data.timeline.length-1)setFrame(0,true);playing=true;$("rr-play").textContent="Pause";timer=setInterval(function(){setFrame(frame+1,true);},650);}
function stop(){playing=false;$("rr-play").textContent="Play";if(timer){clearInterval(timer);timer=null;}}
document.addEventListener("keydown",function(e){if(!data||app.hidden||/INPUT|TEXTAREA|SELECT/.test(e.target.tagName))return;if(e.key==="ArrowLeft"){e.preventDefault();stop();setFrame(frame-1,true);}else if(e.key==="ArrowRight"){e.preventDefault();stop();setFrame(frame+1,true);}else if(e.key===" "){e.preventDefault();playing?stop():play();}});

function resize(){var r=wrap.getBoundingClientRect(),dpr=window.devicePixelRatio||1,w=Math.max(1,Math.floor(r.width)),h=Math.max(1,Math.floor(r.height));if(canvas.width!==Math.floor(w*dpr)||canvas.height!==Math.floor(h*dpr)){canvas.width=Math.floor(w*dpr);canvas.height=Math.floor(h*dpr);}canvas.style.width=w+"px";canvas.style.height=h+"px";ctx.setTransform(dpr,0,0,dpr,0,0);draw();}
new ResizeObserver(resize).observe(wrap);
function fit(){if(!data)return;var b=data.bounds,r=wrap.getBoundingClientRect(),bw=Math.max(.1,b.max_x-b.min_x),bh=Math.max(.1,b.max_y-b.min_y);view.scale=Math.max(.1,Math.min((r.width-70)/bw,(r.height-70)/bh));view.panX=0;view.panY=0;draw();}
$("rr-fit").addEventListener("click",fit);["rr-pads","rr-labels","rr-drc"].forEach(function(id){$(id).addEventListener("change",draw);});
function center(){var b=data.bounds;return {x:(b.min_x+b.max_x)/2,y:(b.min_y+b.max_y)/2};}
function sx(x){var c=center();return canvas.clientWidth/2+view.panX+(x-c.x)*view.scale;}
function sy(y){var c=center();return canvas.clientHeight/2+view.panY+(y-c.y)*view.scale;}
function worldFromScreen(x,y){var c=center();return {x:c.x+(x-canvas.clientWidth/2-view.panX)/view.scale,y:c.y+(y-canvas.clientHeight/2-view.panY)/view.scale};}
canvas.addEventListener("pointerdown",function(e){drag={x:e.clientX,y:e.clientY,px:view.panX,py:view.panY};canvas.classList.add("dragging");canvas.setPointerCapture(e.pointerId);});
canvas.addEventListener("pointermove",function(e){if(!drag)return;view.panX=drag.px+e.clientX-drag.x;view.panY=drag.py+e.clientY-drag.y;draw();});
function endDrag(){drag=null;canvas.classList.remove("dragging");}canvas.addEventListener("pointerup",endDrag);canvas.addEventListener("pointercancel",endDrag);
canvas.addEventListener("wheel",function(e){if(!data)return;e.preventDefault();var rect=canvas.getBoundingClientRect(),mx=e.clientX-rect.left,my=e.clientY-rect.top,before=worldFromScreen(mx,my),factor=Math.exp(-e.deltaY*.0012),old=view.scale;view.scale=Math.max(.15,Math.min(500,view.scale*factor));var c=center();view.panX=mx-canvas.clientWidth/2-(before.x-c.x)*view.scale;view.panY=my-canvas.clientHeight/2-(before.y-c.y)*view.scale;if(view.scale===old)return;draw();},{passive:false});

function draw(){var dpr=window.devicePixelRatio||1;ctx.setTransform(dpr,0,0,dpr,0,0);ctx.clearRect(0,0,canvas.clientWidth,canvas.clientHeight);if(!data)return;var ev=data.timeline[frame],active=ev.net?data.nets.indexOf(ev.net):-99;
 drawZones();drawOutline();drawCourtyards();if($("rr-pads").checked)drawPads(active);drawTracks(ev.tracks,active,false);drawVias(ev.vias,active,false);drawTracks(ev.tracks,active,true);drawVias(ev.vias,active,true);if($("rr-labels").checked)drawLabels();if($("rr-drc").checked)drawDrc();}
function lineWidth(mm,min){return Math.max(min||1,mm*view.scale);}
function arcThrough(p){var ax=sx(p[0][0]),ay=sy(p[0][1]),bx=sx(p[1][0]),by=sy(p[1][1]),cx=sx(p[2][0]),cy=sy(p[2][1]);var d=2*(ax*(by-cy)+bx*(cy-ay)+cx*(ay-by));if(Math.abs(d)<1e-7){ctx.moveTo(ax,ay);ctx.lineTo(bx,by);ctx.lineTo(cx,cy);return;}var ux=((ax*ax+ay*ay)*(by-cy)+(bx*bx+by*by)*(cy-ay)+(cx*cx+cy*cy)*(ay-by))/d;var uy=((ax*ax+ay*ay)*(cx-bx)+(bx*bx+by*by)*(ax-cx)+(cx*cx+cy*cy)*(bx-ax))/d;var a0=Math.atan2(ay-uy,ax-ux),am=Math.atan2(by-uy,bx-ux),a1=Math.atan2(cy-uy,cx-ux),tau=Math.PI*2,norm=function(a){return (a%tau+tau)%tau;};var clockwiseMid=norm(am-a0),clockwiseEnd=norm(a1-a0);ctx.arc(ux,uy,Math.hypot(ax-ux,ay-uy),a0,a1,clockwiseMid>clockwiseEnd);}
function drawOutline(){ctx.save();ctx.strokeStyle="#d7e2ee";ctx.lineWidth=1.4;ctx.setLineDash([]);(data.outline||[]).forEach(function(o){var p=o.points||[];if(!p.length)return;ctx.beginPath();if(o.kind==="rect"&&p.length>=2){ctx.rect(sx(Math.min(p[0][0],p[1][0])),sy(Math.min(p[0][1],p[1][1])),Math.abs(p[1][0]-p[0][0])*view.scale,Math.abs(p[1][1]-p[0][1])*view.scale);}else if(o.kind==="arc"&&p.length>=3){arcThrough(p);}else{ctx.moveTo(sx(p[0][0]),sy(p[0][1]));for(var i=1;i<p.length;i++)ctx.lineTo(sx(p[i][0]),sy(p[i][1]));if(o.kind==="polygon")ctx.closePath();}ctx.stroke();});ctx.restore();}
function drawZones(){ctx.save();(data.zones||[]).forEach(function(z){var p=z.poly||[];if(p.length<3)return;var bottom=(z.layers||[]).some(function(l){return l===LN.b_cu;}),color=z.keepout?"255,101,93":(bottom?"77,145,255":"241,98,93");ctx.beginPath();ctx.moveTo(sx(p[0][0]),sy(p[0][1]));for(var i=1;i<p.length;i++)ctx.lineTo(sx(p[i][0]),sy(p[i][1]));ctx.closePath();ctx.fillStyle="rgba("+color+","+(z.keepout?.08:.055)+")";ctx.fill();ctx.strokeStyle="rgba("+color+","+(z.keepout?.5:.2)+")";ctx.lineWidth=1;ctx.setLineDash(z.keepout?[4,3]:[]);ctx.stroke();});ctx.restore();}
function drawCourtyards(){ctx.save();ctx.strokeStyle="#52617466";ctx.lineWidth=1;ctx.setLineDash([3,3]);data.parts.forEach(function(p){var c=p.court;ctx.strokeRect(sx(c[0]),sy(c[1]),(c[2]-c[0])*view.scale,(c[3]-c[1])*view.scale);});ctx.restore();}
function layerColor(layer,alpha){var colors=[[241,98,93],[77,145,255],[182,131,255],[75,205,170],[255,155,72],[79,199,218]];var c=colors[Math.abs(layer)%colors.length];return "rgba("+c[0]+","+c[1]+","+c[2]+","+alpha+")";}
function roundRectPath(x,y,w,h,r){r=Math.max(0,Math.min(r,w/2,h/2));ctx.beginPath();ctx.moveTo(x+r,y);ctx.arcTo(x+w,y,x+w,y+h,r);ctx.arcTo(x+w,y+h,x,y+h,r);ctx.arcTo(x,y+h,x,y,r);ctx.arcTo(x,y,x+w,y,r);ctx.closePath();}
function drawPads(active){data.parts.forEach(function(part){part.pads.forEach(function(p){var isActive=p.net===active,side=part.side==="bottom"?1:0;ctx.save();ctx.fillStyle=isActive?"#ffd166":layerColor(side,.58);ctx.strokeStyle=isActive?"#fff0aa":"#dce6f044";ctx.lineWidth=Math.max(.6,view.scale*.025);
  if(p.poly&&p.poly.length>=3){ctx.beginPath();ctx.moveTo(sx(p.poly[0][0]),sy(p.poly[0][1]));for(var i=1;i<p.poly.length;i++)ctx.lineTo(sx(p.poly[i][0]),sy(p.poly[i][1]));ctx.closePath();ctx.fill();ctx.stroke();}
  else{ctx.save();ctx.translate(sx(p.x),sy(p.y));ctx.rotate((p.rot||0)*Math.PI/180);var w=p.w*view.scale,h=p.h*view.scale,x=-w/2,y=-h/2;if(p.shape==="circle"){ctx.beginPath();ctx.ellipse(0,0,w/2,h/2,0,0,Math.PI*2);ctx.fill();ctx.stroke();}else if(p.shape==="oval"){roundRectPath(x,y,w,h,Math.min(w,h)/2);ctx.fill();ctx.stroke();}else if(p.shape==="roundrect"){var rr=(p.rratio>0?p.rratio:.25)*Math.min(w,h);roundRectPath(x,y,w,h,rr);ctx.fill();ctx.stroke();}else{ctx.fillRect(x,y,w,h);ctx.strokeRect(x,y,w,h);}ctx.restore();}
  ctx.restore();if(p.drill>0){ctx.save();ctx.globalCompositeOperation="destination-out";ctx.beginPath();ctx.arc(sx(p.x),sy(p.y),p.drill*view.scale/2,0,Math.PI*2);ctx.fill();ctx.globalCompositeOperation="source-over";ctx.strokeStyle="#02050a";ctx.beginPath();ctx.arc(sx(p.x),sy(p.y),p.drill*view.scale/2,0,Math.PI*2);ctx.stroke();ctx.restore();}});});}
function drawTracks(tracks,active,activePass){ctx.save();ctx.lineCap="round";ctx.lineJoin="round";(tracks||[]).forEach(function(t){var is=t[6]===active;if(is!==activePass)return;ctx.strokeStyle=is?"#ffd166":layerColor(t[4],.88);ctx.lineWidth=lineWidth(t[5],is?1.8:1);ctx.beginPath();ctx.moveTo(sx(t[0]),sy(t[1]));ctx.lineTo(sx(t[2]),sy(t[3]));ctx.stroke();});ctx.restore();}
function drawVias(vias,active,activePass){ctx.save();(vias||[]).forEach(function(v){var is=v[4]===active;if(is!==activePass)return;var r=Math.max(2,v[2]*view.scale/2),dr=Math.max(0,v[3]*view.scale/2);ctx.fillStyle=is?"#ffd166":"#c995ff";ctx.strokeStyle=is?"#fff3b7":"#ead8ff";ctx.lineWidth=1;ctx.beginPath();ctx.arc(sx(v[0]),sy(v[1]),r,0,Math.PI*2);ctx.fill();ctx.stroke();ctx.fillStyle="#080c12";ctx.beginPath();ctx.arc(sx(v[0]),sy(v[1]),dr,0,Math.PI*2);ctx.fill();});ctx.restore();}
function drawLabels(){ctx.save();ctx.font="10px ui-monospace,SFMono-Regular,Consolas,monospace";ctx.textAlign="center";ctx.textBaseline="middle";data.parts.forEach(function(p){ctx.lineWidth=3;ctx.strokeStyle="#080c12cc";ctx.strokeText(p.ref,sx(p.x),sy(p.y));ctx.fillStyle="#d9e3ee";ctx.fillText(p.ref,sx(p.x),sy(p.y));});ctx.restore();}
function drawDrc(){ctx.save();(data.final.drc||[]).forEach(function(v){var x=sx(v.x),y=sy(v.y),r=v.severity==="err"?6:5;ctx.strokeStyle=v.severity==="err"?"#ff4d9d":"#ffbd5c";ctx.lineWidth=2;ctx.beginPath();ctx.arc(x,y,r,0,Math.PI*2);ctx.stroke();ctx.beginPath();ctx.moveTo(x-r*1.5,y);ctx.lineTo(x+r*1.5,y);ctx.moveTo(x,y-r*1.5);ctx.lineTo(x,y+r*1.5);ctx.stroke();});ctx.restore();}

resize();
})();
