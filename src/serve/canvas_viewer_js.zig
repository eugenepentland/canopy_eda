pub const CANVAS_VIEWER_JS =
    \\(async function(){
    \\try{
    \\
    \\/* ── Init Pixi ─────────────────────────────────────────────── */
    \\var container=document.getElementById('pixi-container');
    \\var app=new PIXI.Application();
    \\await app.init({
    \\  background:'#0d1117',
    \\  resizeTo:container,
    \\  antialias:true,
    \\  resolution:window.devicePixelRatio||1,
    \\  autoDensity:true
    \\});
    \\container.appendChild(app.canvas);
    \\
    \\var world=new PIXI.Container();
    \\app.stage.addChild(world);
    \\
    \\/* ── Colors ───────────────────────────────────────────────── */
    \\var C={
    \\  bg:0x0d1117,secBox:0x0d1117,secStroke:0x21262d,
    \\  hubFill:0x16213e,hubStroke:0x4a9eff,hubText:0x4a9eff,
    \\  wire:0x44aa99,wireHit:0x44aa99,
    \\  pinStub:0x666666,pinText:0xaaaaaa,pinNum:0x666666,
    \\  passiveFill:0x2a2a4a,passiveStroke:0x8888cc,passiveText:0x888888,
    \\  labelNet:0xe8c547,labelPort:0x4a9eff,
    \\  gnd:0xe8c547,
    \\  portFill:0x1a2e1a,portStroke:0x44aa99,portText:0x44aa99,
    \\  sectionTitle:0x8b949e,sectionDesc:0x6e7681,
    \\  noteText:0x6e7681,
    \\  highlight:0x58a6ff
    \\};
    \\
    \\/* ── State ────────────────────────────────────────────────── */
    \\var sceneData=null;
    \\var liveVersion=0;
    \\var selectedRef=null;
    \\var selectedNet=null;
    \\var refContainers={};
    \\var netGraphics={};
    \\
    \\/* ── Fetch scene graph ────────────────────────────────────── */
    \\async function loadScene(){
    \\  var r=await fetch('/api/scene-graph/'+DESIGN_NAME);
    \\  sceneData=await r.json();
    \\  buildScene();
    \\}
    \\
    \\/* ── Build Pixi scene from JSON ─────────────────────────── */
    \\function buildScene(){
    \\  world.removeChildren();
    \\  refContainers={};
    \\  netGraphics={};
    \\  if(!sceneData||sceneData.error)return;
    \\
    \\  /* Sections */
    \\  for(var s of sceneData.sections){
    \\    var g=new PIXI.Graphics();
    \\    g.roundRect(s.x,s.y,s.w,s.h,8);
    \\    g.fill({color:C.secBox});
    \\    g.stroke({color:C.secStroke,width:1.5});
    \\    world.addChild(g);
    \\    var cx=s.x+s.w/2;
    \\    var t=new PIXI.Text({text:s.name,style:{fontFamily:'system-ui,sans-serif',fontSize:24,fontWeight:'bold',fill:C.sectionTitle}});
    \\    t.anchor.set(0.5,0);t.x=cx;t.y=s.y+6;
    \\    world.addChild(t);
    \\    if(s.description){
    \\      var d=new PIXI.Text({text:s.description,style:{fontFamily:'system-ui,sans-serif',fontSize:15,fontStyle:'italic',fill:C.sectionDesc}});
    \\      d.anchor.set(0.5,0);d.x=cx;d.y=s.y+36;
    \\      world.addChild(d);
    \\    }
    \\    if(s.notes&&s.notes.length){
    \\      var ny=s.y+s.h-s.notes.length*15-8;
    \\      var line=new PIXI.Graphics();
    \\      line.moveTo(s.x+12,ny);line.lineTo(s.x+s.w-12,ny);
    \\      line.stroke({color:C.secStroke,width:1});
    \\      world.addChild(line);
    \\      for(var ni=0;ni<s.notes.length;ni++){
    \\        var nt=new PIXI.Text({text:s.notes[ni],style:{fontFamily:'system-ui,sans-serif',fontSize:11,fontStyle:'italic',fill:C.noteText}});
    \\        nt.x=s.x+16;nt.y=ny+4+ni*15;
    \\        world.addChild(nt);
    \\      }
    \\    }
    \\  }
    \\
    \\  /* Wires (draw before hubs so hubs are on top) */
    \\  for(var w2 of sceneData.wires){
    \\    var wg=new PIXI.Graphics();
    \\    var pts=w2.points;
    \\    if(pts.length>=2){
    \\      /* Hit area - transparent wide line */
    \\      wg.moveTo(pts[0][0],pts[0][1]);
    \\      for(var pi=1;pi<pts.length;pi++)wg.lineTo(pts[pi][0],pts[pi][1]);
    \\      wg.stroke({color:C.wire,width:1.5});
    \\    }
    \\    wg.eventMode='static';
    \\    wg.cursor='pointer';
    \\    wg.hitArea=makeWireHitArea(pts);
    \\    wg._netName=w2.net;
    \\    wg.on('pointerdown',function(e){e.stopPropagation();highlightNet(this._netName);});
    \\    world.addChild(wg);
    \\    if(w2.net){
    \\      if(!netGraphics[w2.net])netGraphics[w2.net]=[];
    \\      netGraphics[w2.net].push(wg);
    \\    }
    \\  }
    \\
    \\  /* Passives */
    \\  for(var p of sceneData.passives){
    \\    var pc=new PIXI.Container();
    \\    pc.x=0;pc.y=0;
    \\    var pg=new PIXI.Graphics();
    \\    drawPassiveSymbol(pg,p);
    \\    pc.addChild(pg);
    \\    var pt=new PIXI.Text({text:p.ref+' '+((p.value&&p.value.length)?p.value:p.component),style:{fontFamily:'system-ui,sans-serif',fontSize:9,fill:C.passiveText}});
    \\    pt.anchor.set(0.5,1);pt.x=p.x+p.w/2;pt.y=p.y-p.h/2-4;
    \\    pc.addChild(pt);
    \\    pc.eventMode='static';pc.cursor='pointer';
    \\    pc._ref=p.ref;
    \\    pc.on('pointerdown',function(e){e.stopPropagation();selectComponent(this._ref);});
    \\    world.addChild(pc);
    \\    refContainers[p.ref]=pc;
    \\  }
    \\
    \\  /* Hubs */
    \\  for(var h of sceneData.hubs){
    \\    var hc=new PIXI.Container();
    \\    /* Box */
    \\    var hg=new PIXI.Graphics();
    \\    hg.roundRect(h.x,h.y,h.w,h.h,6);
    \\    hg.fill({color:C.hubFill});
    \\    hg.stroke({color:C.hubStroke,width:2});
    \\    hc.addChild(hg);
    \\    /* Label */
    \\    var ht=new PIXI.Text({text:h.label,style:{fontFamily:'system-ui,sans-serif',fontSize:12,fontWeight:'bold',fill:C.hubText}});
    \\    ht.anchor.set(0.5,0);ht.x=h.x+h.w/2;ht.y=h.y+6;
    \\    hc.addChild(ht);
    \\    /* Left pins */
    \\    var stubLen=40;
    \\    for(var lp of h.leftPins){
    \\      var lg=new PIXI.Graphics();
    \\      lg.moveTo(h.x-stubLen,lp.y);lg.lineTo(h.x,lp.y);
    \\      lg.stroke({color:C.pinStub,width:1.5});
    \\      hc.addChild(lg);
    \\      var ln=new PIXI.Text({text:lp.name,style:{fontFamily:'system-ui,sans-serif',fontSize:12,fill:C.pinText}});
    \\      ln.x=h.x+8;ln.y=lp.y-6;
    \\      hc.addChild(ln);
    \\      var lpn=new PIXI.Text({text:lp.pins,style:{fontFamily:'system-ui,sans-serif',fontSize:10,fill:C.pinNum}});
    \\      lpn.anchor.set(1,1);lpn.x=h.x-stubLen+38;lpn.y=lp.y-1;
    \\      hc.addChild(lpn);
    \\    }
    \\    /* Right pins */
    \\    for(var rp of h.rightPins){
    \\      var rg=new PIXI.Graphics();
    \\      rg.moveTo(h.x+h.w,rp.y);rg.lineTo(h.x+h.w+stubLen,rp.y);
    \\      rg.stroke({color:C.pinStub,width:1.5});
    \\      hc.addChild(rg);
    \\      var rn=new PIXI.Text({text:rp.name,style:{fontFamily:'system-ui,sans-serif',fontSize:12,fill:C.pinText}});
    \\      rn.anchor.set(1,0);rn.x=h.x+h.w-8;rn.y=rp.y-6;
    \\      hc.addChild(rn);
    \\      var rpn=new PIXI.Text({text:rp.pins,style:{fontFamily:'system-ui,sans-serif',fontSize:10,fill:C.pinNum}});
    \\      rpn.x=h.x+h.w+stubLen-36;rpn.y=rp.y-1;
    \\      hc.addChild(rpn);
    \\    }
    \\    hc.eventMode='static';hc.cursor='pointer';
    \\    var shortRef=h.ref;
    \\    if(shortRef.indexOf('/')>=0)shortRef=shortRef.substring(shortRef.lastIndexOf('/')+1);
    \\    hc._ref=shortRef;
    \\    hc.on('pointerdown',function(e){e.stopPropagation();selectComponent(this._ref);});
    \\    world.addChild(hc);
    \\    refContainers[shortRef]=hc;
    \\  }
    \\
    \\  /* Labels */
    \\  for(var lb of sceneData.labels){
    \\    if(lb.ground){
    \\      drawGndSymbol(world,lb.x,lb.y);
    \\    }else{
    \\      var color=lb.port?C.labelPort:C.labelNet;
    \\      var lt=new PIXI.Text({text:lb.text,style:{fontFamily:'system-ui,sans-serif',fontSize:11,fontWeight:'bold',fill:color}});
    \\      if(lb.anchor==='end')lt.anchor.set(1,0.5);
    \\      else lt.anchor.set(0,0.5);
    \\      lt.x=lb.x;lt.y=lb.y;
    \\      lt.eventMode='static';lt.cursor='pointer';
    \\      lt._netName=lb.text;
    \\      lt.on('pointerdown',function(e){e.stopPropagation();highlightNet(this._netName);});
    \\      world.addChild(lt);
    \\      if(!netGraphics[lb.text])netGraphics[lb.text]=[];
    \\      netGraphics[lb.text].push(lt);
    \\    }
    \\  }
    \\
    \\  /* Port blocks */
    \\  for(var pb of sceneData.portBlocks){
    \\    var pbg=new PIXI.Graphics();
    \\    pbg.roundRect(pb.x,pb.y,pb.w,pb.h,6);
    \\    pbg.fill({color:C.portFill});
    \\    pbg.stroke({color:C.portStroke,width:2,dash:[8,4]});
    \\    world.addChild(pbg);
    \\    var pbt=new PIXI.Text({text:pb.name,style:{fontFamily:'system-ui,sans-serif',fontSize:12,fontWeight:'bold',fill:C.portText}});
    \\    pbt.anchor.set(0.5,0);pbt.x=pb.x+pb.w/2;pbt.y=pb.y+6;
    \\    world.addChild(pbt);
    \\    for(var port of pb.ports){
    \\      var isOut=(port.direction==='out');
    \\      var edgeX=isOut?pb.x+pb.w:pb.x;
    \\      var stubX=isOut?edgeX+40:edgeX-40;
    \\      var plg=new PIXI.Graphics();
    \\      plg.moveTo(edgeX,port.y);plg.lineTo(stubX,port.y);
    \\      plg.stroke({color:C.wire,width:1.5});
    \\      world.addChild(plg);
    \\      var dir=isOut?'\u2190 OUT':((port.direction==='in')?'\u2192 ':'\u2194 ');
    \\      var pnt=new PIXI.Text({text:port.name+' '+dir,style:{fontFamily:'system-ui,sans-serif',fontSize:12,fill:C.portText}});
    \\      if(isOut){pnt.anchor.set(1,0.5);pnt.x=edgeX-8;}
    \\      else{pnt.anchor.set(0,0.5);pnt.x=edgeX+8;}
    \\      pnt.y=port.y;
    \\      world.addChild(pnt);
    \\      var pnl=new PIXI.Text({text:port.net,style:{fontFamily:'system-ui,sans-serif',fontSize:11,fontWeight:'bold',fill:C.labelPort}});
    \\      if(isOut){pnl.anchor.set(0,0.5);pnl.x=stubX+18;}
    \\      else{pnl.anchor.set(1,0.5);pnl.x=stubX-18;}
    \\      pnl.y=port.y;
    \\      world.addChild(pnl);
    \\    }
    \\  }
    \\
    \\  /* Fit to view */
    \\  fitView();
    \\}
    \\
    \\/* ── Drawing helpers ──────────────────────────────────────── */
    \\function drawPassiveSymbol(g,p){
    \\  var cx=p.x+p.w/2,cy=p.y;
    \\  if(p.symbol==='generic-res'){
    \\    var bw=24,bh=10;
    \\    g.moveTo(p.x,cy);g.lineTo(cx-bw/2,cy);g.stroke({color:C.passiveStroke,width:1.5});
    \\    g.rect(cx-bw/2,cy-bh/2,bw,bh);g.stroke({color:C.passiveStroke,width:1.5});
    \\    g.moveTo(cx+bw/2,cy);g.lineTo(p.x+p.w,cy);g.stroke({color:C.passiveStroke,width:1.5});
    \\  }else if(p.symbol==='generic-cap'){
    \\    var gap=6,ph=12;
    \\    g.moveTo(p.x,cy);g.lineTo(cx-gap/2,cy);g.stroke({color:C.passiveStroke,width:1.5});
    \\    g.moveTo(cx-gap/2,cy-ph/2);g.lineTo(cx-gap/2,cy+ph/2);g.stroke({color:C.passiveStroke,width:2});
    \\    g.moveTo(cx+gap/2,cy-ph/2);g.lineTo(cx+gap/2,cy+ph/2);g.stroke({color:C.passiveStroke,width:2});
    \\    g.moveTo(cx+gap/2,cy);g.lineTo(p.x+p.w,cy);g.stroke({color:C.passiveStroke,width:1.5});
    \\  }else if(p.symbol==='generic-ind'){
    \\    var aw=6,na=3,ta=aw*na,sx=cx-ta/2;
    \\    g.moveTo(p.x,cy);g.lineTo(sx,cy);g.stroke({color:C.passiveStroke,width:1.5});
    \\    for(var ai=0;ai<na;ai++){
    \\      var ax=sx+ai*aw;
    \\      g.arc(ax+aw/2,cy,aw/2,Math.PI,0);g.stroke({color:C.passiveStroke,width:1.5});
    \\    }
    \\    g.moveTo(sx+ta,cy);g.lineTo(p.x+p.w,cy);g.stroke({color:C.passiveStroke,width:1.5});
    \\  }else{
    \\    g.roundRect(p.x,cy-8,p.w,16,3);
    \\    g.fill({color:C.passiveFill});g.stroke({color:C.passiveStroke,width:1});
    \\  }
    \\}
    \\
    \\function drawGndSymbol(parent,x,y){
    \\  var g=new PIXI.Graphics();
    \\  g.moveTo(x,y);g.lineTo(x,y+6);g.stroke({color:C.gnd,width:1.5});
    \\  g.moveTo(x-7,y+6);g.lineTo(x+7,y+6);g.stroke({color:C.gnd,width:1.5});
    \\  g.moveTo(x-4.5,y+9);g.lineTo(x+4.5,y+9);g.stroke({color:C.gnd,width:1.5});
    \\  g.moveTo(x-2,y+12);g.lineTo(x+2,y+12);g.stroke({color:C.gnd,width:1.5});
    \\  parent.addChild(g);
    \\}
    \\
    \\function makeWireHitArea(pts){
    \\  if(pts.length<2)return new PIXI.Rectangle(0,0,1,1);
    \\  var pad=8;
    \\  var minX=pts[0][0],minY=pts[0][1],maxX=minX,maxY=minY;
    \\  for(var i=1;i<pts.length;i++){
    \\    if(pts[i][0]<minX)minX=pts[i][0];
    \\    if(pts[i][0]>maxX)maxX=pts[i][0];
    \\    if(pts[i][1]<minY)minY=pts[i][1];
    \\    if(pts[i][1]>maxY)maxY=pts[i][1];
    \\  }
    \\  return new PIXI.Rectangle(minX-pad,minY-pad,maxX-minX+pad*2,maxY-minY+pad*2);
    \\}
    \\
    \\/* ── Pan / Zoom ───────────────────────────────────────────── */
    \\var isPanning=false,panStart={x:0,y:0},worldStart={x:0,y:0},didPan=false;
    \\
    \\app.canvas.addEventListener('mousedown',function(e){
    \\  if(e.button===0){isPanning=true;didPan=false;panStart={x:e.clientX,y:e.clientY};worldStart={x:world.x,y:world.y};}
    \\});
    \\window.addEventListener('mousemove',function(e){
    \\  if(!isPanning)return;
    \\  var dx=e.clientX-panStart.x,dy=e.clientY-panStart.y;
    \\  if(Math.abs(dx)>3||Math.abs(dy)>3)didPan=true;
    \\  world.x=worldStart.x+dx;world.y=worldStart.y+dy;
    \\});
    \\window.addEventListener('mouseup',function(){isPanning=false;});
    \\
    \\app.canvas.addEventListener('wheel',function(e){
    \\  e.preventDefault();
    \\  var rect=app.canvas.getBoundingClientRect();
    \\  var mx=e.clientX-rect.left,my=e.clientY-rect.top;
    \\  var factor=e.deltaY<0?1.1:1/1.1;
    \\  var wx=(mx-world.x)/world.scale.x;
    \\  var wy=(my-world.y)/world.scale.y;
    \\  var ns=Math.max(0.05,Math.min(20,world.scale.x*factor));
    \\  world.scale.set(ns);
    \\  world.x=mx-wx*ns;
    \\  world.y=my-wy*ns;
    \\},{passive:false});
    \\
    \\function fitView(){
    \\  if(!sceneData)return;
    \\  var vb=sceneData.viewBox;
    \\  var cw=container.clientWidth,ch=container.clientHeight;
    \\  var scale=Math.min(cw/vb.w,ch/vb.h)*0.95;
    \\  world.scale.set(scale);
    \\  world.x=(cw-vb.w*scale)/2;
    \\  world.y=(ch-vb.h*scale)/2;
    \\}
    \\
    \\/* ── Click background to deselect ─────────────────────────── */
    \\app.canvas.addEventListener('click',function(e){
    \\  if(!didPan){clearSelection();}
    \\});
    \\
    \\/* ── Selection / Highlight ────────────────────────────────── */
    \\function selectComponent(ref){
    \\  clearSelection();
    \\  selectedRef=ref;
    \\  var c=refContainers[ref];
    \\  if(c){c.alpha=1;c.tint=C.highlight;}
    \\  showComponentSidebar(ref);
    \\}
    \\
    \\function highlightNet(net){
    \\  clearSelection();
    \\  if(!net)return;
    \\  selectedNet=net;
    \\  var items=netGraphics[net];
    \\  if(items){for(var i=0;i<items.length;i++){items[i].tint=C.highlight;}}
    \\  showNetSidebar(net);
    \\}
    \\
    \\function clearSelection(){
    \\  if(selectedRef&&refContainers[selectedRef]){refContainers[selectedRef].tint=0xFFFFFF;}
    \\  if(selectedNet&&netGraphics[selectedNet]){
    \\    var items=netGraphics[selectedNet];
    \\    for(var i=0;i<items.length;i++)items[i].tint=0xFFFFFF;
    \\  }
    \\  selectedRef=null;selectedNet=null;
    \\  closeSidebar();
    \\}
    \\
    \\/* ── Sidebar ──────────────────────────────────────────────── */
    \\var sidebar=document.getElementById('sidebar');
    \\var sidebarContent=document.getElementById('sidebar-content');
    \\var sidebarClose=document.getElementById('sidebar-close');
    \\sidebarClose.onclick=function(){closeSidebar();};
    \\
    \\function openSidebar(html){
    \\  sidebarContent.innerHTML=html;
    \\  sidebar.classList.add('open');
    \\}
    \\function closeSidebar(){sidebar.classList.remove('open');}
    \\
    \\function showComponentSidebar(ref){
    \\  var comp=COMPONENTS[ref];
    \\  if(!comp){openSidebar('<h3>'+ref+'</h3><p>No data</p>');return;}
    \\  var html='<h3 style="color:#4a9eff;margin:0 0 8px">'+ref+'</h3>';
    \\  html+='<div style="font-size:13px;color:#8b949e;margin-bottom:12px">'+comp.component+'</div>';
    \\  if(comp.value)html+='<div style="margin-bottom:8px"><b>Value:</b> '+comp.value+'</div>';
    \\  if(comp.footprint)html+='<div style="margin-bottom:8px"><b>Footprint:</b> '+comp.footprint+'</div>';
    \\  if(comp.pins&&comp.pins.length){
    \\    html+='<div style="margin-top:12px"><b>Pins:</b></div><table style="width:100%;font-size:12px;border-collapse:collapse;margin-top:4px">';
    \\    html+='<tr style="border-bottom:1px solid #30363d"><th style="text-align:left;padding:4px">Pin</th><th style="text-align:left;padding:4px">Name</th><th style="text-align:left;padding:4px">Net</th></tr>';
    \\    for(var i=0;i<comp.pins.length;i++){
    \\      var p=comp.pins[i];
    \\      html+='<tr style="border-bottom:1px solid #21262d"><td style="padding:4px;color:#666">'+p.pin+'</td><td style="padding:4px">'+p.name+'</td><td style="padding:4px;color:#e8c547;cursor:pointer" onclick="highlightNet(\''+p.net+'\')">'+p.net+'</td></tr>';
    \\    }
    \\    html+='</table>';
    \\  }
    \\  openSidebar(html);
    \\}
    \\
    \\function showNetSidebar(net){
    \\  var pins=NETS[net];
    \\  var html='<h3 style="color:#e8c547;margin:0 0 8px">'+net+'</h3>';
    \\  if(pins&&pins.length){
    \\    html+='<div style="margin-bottom:8px"><b>Connections:</b> '+pins.length+'</div>';
    \\    html+='<table style="width:100%;font-size:12px;border-collapse:collapse">';
    \\    for(var i=0;i<pins.length;i++){
    \\      var parts=pins[i].split('.');
    \\      var ref2=parts[0],pin2=parts[1]||'';
    \\      html+='<tr style="border-bottom:1px solid #21262d"><td style="padding:4px;color:#4a9eff;cursor:pointer" onclick="selectComponent(\''+ref2+'\')">'+ref2+'</td><td style="padding:4px;color:#666">pin '+pin2+'</td></tr>';
    \\    }
    \\    html+='</table>';
    \\  }else{
    \\    html+='<div style="color:#666">No connections found</div>';
    \\  }
    \\  openSidebar(html);
    \\}
    \\
    \\/* Make sidebar functions global for onclick handlers */
    \\window.highlightNet=highlightNet;
    \\window.selectComponent=selectComponent;
    \\
    \\/* ── Search ───────────────────────────────────────────────── */
    \\var searchInput=document.getElementById('search-input');
    \\var searchResults=document.getElementById('search-results');
    \\var searchIdx=-1;
    \\
    \\searchInput.addEventListener('input',function(){
    \\  var q=this.value.toLowerCase().trim();
    \\  searchResults.innerHTML='';searchIdx=-1;
    \\  if(!q){searchResults.style.display='none';return;}
    \\  var results=[];
    \\  for(var ref3 in COMPONENTS){
    \\    var c2=COMPONENTS[ref3];
    \\    if(ref3.toLowerCase().indexOf(q)>=0||
    \\       (c2.value&&c2.value.toLowerCase().indexOf(q)>=0)||
    \\       c2.component.toLowerCase().indexOf(q)>=0){
    \\      results.push({type:'component',label:ref3+' '+((c2.value&&c2.value.length)?c2.value:c2.component),ref:ref3});
    \\    }
    \\  }
    \\  for(var net2 in NETS){
    \\    if(net2.toLowerCase().indexOf(q)>=0){
    \\      results.push({type:'net',label:net2+' ('+NETS[net2].length+' pins)',net:net2});
    \\    }
    \\  }
    \\  if(!results.length){searchResults.style.display='none';return;}
    \\  searchResults.style.display='block';
    \\  for(var ri=0;ri<Math.min(results.length,15);ri++){
    \\    var div=document.createElement('div');
    \\    div.textContent=results[ri].label;
    \\    div._data=results[ri];
    \\    div.onclick=function(){
    \\      var d2=this._data;
    \\      if(d2.type==='component')selectComponent(d2.ref);
    \\      else highlightNet(d2.net);
    \\      searchResults.style.display='none';searchInput.value='';
    \\    };
    \\    searchResults.appendChild(div);
    \\  }
    \\});
    \\searchInput.addEventListener('keydown',function(e){
    \\  var items2=searchResults.querySelectorAll('div');
    \\  if(e.key==='ArrowDown'){e.preventDefault();searchIdx=Math.min(searchIdx+1,items2.length-1);updateSearchActive(items2);}
    \\  else if(e.key==='ArrowUp'){e.preventDefault();searchIdx=Math.max(searchIdx-1,0);updateSearchActive(items2);}
    \\  else if(e.key==='Enter'&&searchIdx>=0&&items2[searchIdx]){items2[searchIdx].click();}
    \\  else if(e.key==='Escape'){searchResults.style.display='none';searchInput.blur();}
    \\});
    \\function updateSearchActive(items3){
    \\  for(var i2=0;i2<items3.length;i2++)items3[i2].classList.toggle('active',i2===searchIdx);
    \\}
    \\
    \\/* ── Rebuild ──────────────────────────────────────────────── */
    \\document.getElementById('rebuild-btn').onclick=async function(){
    \\  this.textContent='Building...';this.disabled=true;
    \\  try{
    \\    await fetch('/api/push/'+DESIGN_NAME,{method:'POST'});
    \\    var r2=await fetch('/api/scene-graph/'+DESIGN_NAME);
    \\    sceneData=await r2.json();
    \\    var sx=world.x,sy=world.y,ss=world.scale.x;
    \\    buildScene();
    \\    world.x=sx;world.y=sy;world.scale.set(ss);
    \\  }catch(err){console.error(err);}
    \\  this.textContent='Rebuild';this.disabled=false;
    \\};
    \\
    \\/* ── Reset ────────────────────────────────────────────────── */
    \\document.getElementById('canvas-reset').onclick=function(){fitView();};
    \\
    \\/* ── Live polling ─────────────────────────────────────────── */
    \\setInterval(async function(){
    \\  try{
    \\    var r3=await fetch('/api/version/'+DESIGN_NAME);
    \\    var d3=await r3.json();
    \\    if(d3.version>liveVersion){
    \\      liveVersion=d3.version;
    \\      var r4=await fetch('/api/scene-graph/'+DESIGN_NAME);
    \\      sceneData=await r4.json();
    \\      var sx2=world.x,sy2=world.y,ss2=world.scale.x;
    \\      buildScene();
    \\      world.x=sx2;world.y=sy2;world.scale.set(ss2);
    \\    }
    \\  }catch(e2){}
    \\},500);
    \\
    \\/* ── Keyboard shortcuts ───────────────────────────────────── */
    \\document.addEventListener('keydown',function(e){
    \\  if(e.key==='/'&&document.activeElement!==searchInput){e.preventDefault();searchInput.focus();}
    \\  if(e.key==='Escape'){clearSelection();}
    \\});
    \\
    \\/* ── Start ────────────────────────────────────────────────── */
    \\await loadScene();
    \\
    \\}catch(err){console.error('Canvas viewer error:',err);}
    \\})();
;
