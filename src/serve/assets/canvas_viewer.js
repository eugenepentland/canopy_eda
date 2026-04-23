(async function(){
try{

/* ── Init Pixi ─────────────────────────────────────────────── */
console.log('[SCHEM] Starting init');
var container=document.getElementById('pixi-container');
console.log('[SCHEM] Container:', container ? container.clientWidth+'x'+container.clientHeight : 'NULL');
var app=new PIXI.Application();
console.log('[SCHEM] Calling app.init...');
await app.init({
  background:'#0d1117',
  resizeTo:container,
  antialias:true,
  resolution:Math.max(window.devicePixelRatio||1,2),
  autoDensity:true,
  preference:'webgl',
  preferWebGLVersion:2
});
console.log('[SCHEM] app.init done');
container.appendChild(app.canvas);
PIXI.TextStyle.defaultResolution=Math.max(window.devicePixelRatio||1,2);

var world=new PIXI.Container();
app.stage.addChild(world);

/* ── Colors ───────────────────────────────────────────────── */
var C={
  bg:0x0d1117,secBox:0x0d1117,secStroke:0x21262d,
  hubFill:0x16213e,hubStroke:0x4a9eff,hubText:0x4a9eff,
  wire:0x44aa99,wireHit:0x44aa99,
  pinStub:0x666666,pinText:0xaaaaaa,pinNum:0x666666,
  passiveFill:0x2a2a4a,passiveStroke:0x8888cc,passiveText:0x888888,
  labelNet:0xe8c547,labelPort:0x4a9eff,
  gnd:0xe8c547,
  portFill:0x1a2e1a,portStroke:0x44aa99,portText:0x44aa99,
  sectionTitle:0x8b949e,sectionDesc:0x6e7681,
  noteText:0x6e7681,
  highlight:0x58a6ff
};

/* ── State ────────────────────────────────────────────────── */
var sceneData=null;
var liveVersion=0;
var selectedRef=null;
var selectedNet=null;
var selectedSection=null;
var justSelected=false;
var refContainers={};
var refRects={};
var netGraphics={};
var sectionRects={};
var PIN_NAMES={};

/* ── Pin-function hover tooltip ──────────────────────────── */
var _pinTooltip=document.createElement('div');
_pinTooltip.style.cssText='position:fixed;display:none;z-index:9999;background:#161b22;border:1px solid #30363d;border-radius:4px;padding:6px 10px;font-family:system-ui,sans-serif;font-size:12px;color:#c9d1d9;pointer-events:none;max-width:260px;box-shadow:0 4px 12px rgba(0,0,0,0.5)';
document.body.appendChild(_pinTooltip);
function showPinTooltip(pd,ev){
  if((!pd.alts||!pd.alts.length)&&!pd.activeFn)return;
  var html='<div style="font-weight:bold;color:#e6edf3">'+pd.name+' ('+pd.pins+')</div>';
  if(pd.activeFn)html+='<div style="margin-top:3px;color:#58a6ff">active: '+pd.activeFn+'</div>';
  if(pd.alts&&pd.alts.length){
    html+='<div style="margin-top:4px;color:#8b949e;font-size:11px">alternates:</div>';
    for(var a of pd.alts){
      var isActive=pd.activeFn===a;
      html+='<div style="color:'+(isActive?'#58a6ff':'#c9d1d9')+';font-weight:'+(isActive?'bold':'normal')+'">'+a+'</div>';
    }
  }
  _pinTooltip.innerHTML=html;
  _pinTooltip.style.display='block';
  movePinTooltip(ev);
}
function movePinTooltip(ev){
  var x=ev.clientX||(ev.data&&ev.data.global?ev.data.global.x:0);
  var y=ev.clientY||(ev.data&&ev.data.global?ev.data.global.y:0);
  _pinTooltip.style.left=(x+14)+'px';
  _pinTooltip.style.top=(y+14)+'px';
}
function hidePinTooltip(){_pinTooltip.style.display='none';}

/* ── Fetch scene graph ────────────────────────────────────── */
async function loadScene(){
  var r=await fetch('/api/scene-graph/'+DESIGN_NAME);
  sceneData=await r.json();
  buildScene();
}

/* ── Build Pixi scene from JSON ─────────────────────────── */
function buildScene(){
  world.removeChildren();
  refContainers={};
  refRects={};
  netGraphics={};
  sectionRects={};
  PIN_NAMES={};
  if(!sceneData||sceneData.error)return;

  /* Sections */
  for(var s of sceneData.sections){
    var g=new PIXI.Graphics();
    g.roundRect(s.x,s.y,s.w,s.h,8);
    g.fill({color:C.secBox});
    g.stroke({color:C.secStroke,width:1.5});
    world.addChild(g);
    sectionRects[s.name]={x:s.x,y:s.y,w:s.w,h:s.h,gfx:g};
    var cx=s.x+s.w/2;
    var t=new PIXI.Text({text:s.name,style:{fontFamily:'system-ui,sans-serif',fontSize:24,fontWeight:'bold',fill:C.sectionTitle}});
    t.anchor.set(0.5,0);t.x=cx;t.y=s.y+6;
    world.addChild(t);
    if(s.description){
      var d=new PIXI.Text({text:s.description,style:{fontFamily:'system-ui,sans-serif',fontSize:15,fontStyle:'italic',fill:C.sectionDesc}});
      d.anchor.set(0.5,0);d.x=cx;d.y=s.y+36;
      world.addChild(d);
    }
    if(s.notes&&s.notes.length){
      var ny=s.y+s.h-s.notes.length*15-8;
      var line=new PIXI.Graphics();
      line.moveTo(s.x+12,ny);line.lineTo(s.x+s.w-12,ny);
      line.stroke({color:C.secStroke,width:1});
      world.addChild(line);
      for(var ni=0;ni<s.notes.length;ni++){
        var nt=new PIXI.Text({text:s.notes[ni],style:{fontFamily:'system-ui,sans-serif',fontSize:11,fontStyle:'italic',fill:C.noteText}});
        nt.x=s.x+16;nt.y=ny+4+ni*15;
        world.addChild(nt);
      }
    }
  }

  /* Wires (draw before hubs so hubs are on top) */
  for(var w2 of sceneData.wires){
    var wg=new PIXI.Graphics();
    var pts=w2.points;
    if(pts.length>=2){
      /* Hit area - transparent wide line */
      wg.moveTo(pts[0][0],pts[0][1]);
      for(var pi=1;pi<pts.length;pi++)wg.lineTo(pts[pi][0],pts[pi][1]);
      wg.stroke({color:C.wire,width:1.5});
    }
    wg.eventMode='static';
    wg.cursor='pointer';
    wg.hitArea=makeWireHitArea(pts);
    wg._netName=w2.net;
    wg.on('pointerdown',function(e){e.stopPropagation();highlightNet(this._netName);});
    world.addChild(wg);
    if(w2.net){
      if(!netGraphics[w2.net])netGraphics[w2.net]=[];
      netGraphics[w2.net].push(wg);
    }
  }

  /* Passives */
  for(var p of sceneData.passives){
    var pc=new PIXI.Container();
    pc.x=0;pc.y=0;
    var pg=new PIXI.Graphics();
    drawPassiveSymbol(pg,p);
    pc.addChild(pg);
    /* Hit area - larger invisible rect for easier clicking */
    var hitPad=8;
    var hit=new PIXI.Graphics();
    hit.rect(p.x-hitPad,p.y-p.h/2-hitPad-12,p.w+hitPad*2,p.h+hitPad*2+12);
    hit.fill({color:0x000000,alpha:0.001});
    pc.addChild(hit);
    var pval=(p.value&&p.value.length)?p.value:p.component;
    var plbl=(p.count>1)?(p.count+'x '+pval):(p.ref+' '+pval);
    var pt=new PIXI.Text({text:plbl,style:{fontFamily:'system-ui,sans-serif',fontSize:9,fill:C.passiveText}});
    pt.anchor.set(0.5,1);pt.x=p.x+p.w/2;pt.y=p.y-p.h/2-4;
    pc.addChild(pt);
    pc.eventMode='static';pc.cursor='pointer';
    pc._ref=p.ref;
    pc.on('pointerdown',function(e){e.stopPropagation();selectComponent(this._ref);});
    world.addChild(pc);
    refContainers[p.ref]=pc;
    refRects[p.ref]={x:p.x,y:p.y-p.h,w:p.w,h:p.h*2};
  }

  /* Hubs */
  for(var h of sceneData.hubs){
    var hc=new PIXI.Container();
    /* Box */
    var hg=new PIXI.Graphics();
    hg.roundRect(h.x,h.y,h.w,h.h,6);
    hg.fill({color:C.hubFill});
    hg.stroke({color:C.hubStroke,width:2});
    hc.addChild(hg);
    /* Label */
    var ht=new PIXI.Text({text:h.label,style:{fontFamily:'system-ui,sans-serif',fontSize:12,fontWeight:'bold',fill:C.hubText}});
    ht.anchor.set(0.5,0);ht.x=h.x+h.w/2;ht.y=h.y+6;
    hc.addChild(ht);
    /* Left pins */
    var stubLen=40;
    function pinLabel(ps){var n=ps.split(',').length;return n>2?n+'x pins':ps;}
    function attachPinHover(hit,pd){
      if((!pd.alts||!pd.alts.length)&&!pd.activeFn)return;
      hit.eventMode='static';hit.cursor='help';hit._pinData=pd;
      hit.on('pointerover',function(e){showPinTooltip(this._pinData,e);});
      hit.on('pointermove',function(e){movePinTooltip(e);});
      hit.on('pointerout',function(){hidePinTooltip();});
    }
    for(var lp of h.leftPins){
      var lg=new PIXI.Graphics();
      lg.moveTo(h.x-stubLen,lp.y);lg.lineTo(h.x,lp.y);
      lg.stroke({color:C.pinStub,width:1.5});
      hc.addChild(lg);
      var lnColor=lp.activeFn?C.labelPort:C.pinText;
      var lnText=lp.activeFn?lp.activeFn:lp.name;
      var ln=new PIXI.Text({text:lnText,style:{fontFamily:'system-ui,sans-serif',fontSize:12,fontWeight:lp.activeFn?'bold':'normal',fill:lnColor}});
      ln.x=h.x+8;ln.y=lp.y-6;
      hc.addChild(ln);
      var lpn=new PIXI.Text({text:pinLabel(lp.pins),style:{fontFamily:'system-ui,sans-serif',fontSize:10,fill:C.pinNum}});
      lpn.anchor.set(1,1);lpn.x=h.x-stubLen+38;lpn.y=lp.y-1;
      hc.addChild(lpn);
      var lhit=new PIXI.Graphics();
      lhit.rect(h.x-stubLen,lp.y-9,stubLen+60,18);
      lhit.fill({color:0x000000,alpha:0.001});
      hc.addChild(lhit);
      attachPinHover(lhit,lp);
    }
    /* Right pins */
    for(var rp of h.rightPins){
      var rg=new PIXI.Graphics();
      rg.moveTo(h.x+h.w,rp.y);rg.lineTo(h.x+h.w+stubLen,rp.y);
      rg.stroke({color:C.pinStub,width:1.5});
      hc.addChild(rg);
      var rnColor=rp.activeFn?C.labelPort:C.pinText;
      var rnText=rp.activeFn?rp.activeFn:rp.name;
      var rn=new PIXI.Text({text:rnText,style:{fontFamily:'system-ui,sans-serif',fontSize:12,fontWeight:rp.activeFn?'bold':'normal',fill:rnColor}});
      rn.anchor.set(1,0);rn.x=h.x+h.w-8;rn.y=rp.y-6;
      hc.addChild(rn);
      var rpn=new PIXI.Text({text:pinLabel(rp.pins),style:{fontFamily:'system-ui,sans-serif',fontSize:10,fill:C.pinNum}});
      rpn.x=h.x+h.w+stubLen-36;rpn.y=rp.y-1;
      hc.addChild(rpn);
      var rhit=new PIXI.Graphics();
      rhit.rect(h.x+h.w-60,rp.y-9,stubLen+60,18);
      rhit.fill({color:0x000000,alpha:0.001});
      hc.addChild(rhit);
      attachPinHover(rhit,rp);
    }
    hc.eventMode='static';hc.cursor='pointer';
    var shortRef=h.ref;
    if(shortRef.indexOf('/')>=0)shortRef=shortRef.substring(shortRef.lastIndexOf('/')+1);
    hc._ref=shortRef;
    hc.on('pointerdown',function(e){e.stopPropagation();selectComponent(this._ref);});
    world.addChild(hc);
    refContainers[shortRef]=hc;
    refRects[shortRef]={x:h.x-stubLen,y:h.y,w:h.w+stubLen*2,h:h.h};
  }

  /* Labels */
  for(var lb of sceneData.labels){
    if(lb.ground){
      drawGndSymbol(world,lb.x,lb.y);
    }else{
      var color=lb.port?C.labelPort:C.labelNet;
      var lt=new PIXI.Text({text:lb.text,style:{fontFamily:'system-ui,sans-serif',fontSize:11,fontWeight:'bold',fill:color}});
      if(lb.anchor==='end')lt.anchor.set(1,0.5);
      else lt.anchor.set(0,0.5);
      lt.x=lb.x;lt.y=lb.y;
      lt.eventMode='static';lt.cursor='pointer';
      lt._netName=lb.text;
      lt.on('pointerdown',function(e){e.stopPropagation();highlightNet(this._netName);});
      world.addChild(lt);
      if(!netGraphics[lb.text])netGraphics[lb.text]=[];
      netGraphics[lb.text].push(lt);
    }
  }

  /* Port blocks */
  for(var pb of sceneData.portBlocks){
    var pbg=new PIXI.Graphics();
    pbg.roundRect(pb.x,pb.y,pb.w,pb.h,6);
    pbg.fill({color:C.portFill});
    pbg.stroke({color:C.portStroke,width:2,dash:[8,4]});
    world.addChild(pbg);
    var pbt=new PIXI.Text({text:pb.name,style:{fontFamily:'system-ui,sans-serif',fontSize:12,fontWeight:'bold',fill:C.portText}});
    pbt.anchor.set(0.5,0);pbt.x=pb.x+pb.w/2;pbt.y=pb.y+6;
    world.addChild(pbt);
    for(var port of pb.ports){
      var isOut=(port.direction==='out');
      var edgeX=isOut?pb.x+pb.w:pb.x;
      var stubX=isOut?edgeX+40:edgeX-40;
      var plg=new PIXI.Graphics();
      plg.moveTo(edgeX,port.y);plg.lineTo(stubX,port.y);
      plg.stroke({color:C.wire,width:1.5});
      world.addChild(plg);
      var dir=isOut?'\u2190 OUT':((port.direction==='in')?'\u2192 ':'\u2194 ');
      var pnt=new PIXI.Text({text:port.name+' '+dir,style:{fontFamily:'system-ui,sans-serif',fontSize:12,fill:C.portText}});
      if(isOut){pnt.anchor.set(1,0.5);pnt.x=edgeX-8;}
      else{pnt.anchor.set(0,0.5);pnt.x=edgeX+8;}
      pnt.y=port.y;
      world.addChild(pnt);
      var pnl=new PIXI.Text({text:port.net,style:{fontFamily:'system-ui,sans-serif',fontSize:11,fontWeight:'bold',fill:C.labelPort}});
      if(isOut){pnl.anchor.set(0,0.5);pnl.x=stubX+18;}
      else{pnl.anchor.set(1,0.5);pnl.x=stubX-18;}
      pnl.y=port.y;
      world.addChild(pnl);
    }
  }

  /* Fit to view */
  fitView();
}

/* ── Drawing helpers ──────────────────────────────────────── */
function drawPassiveSymbol(g,p){
  var cx=p.x+p.w/2,cy=p.y;
  if(p.symbol==='generic-res'){
    var bw=24,bh=10;
    g.moveTo(p.x,cy);g.lineTo(cx-bw/2,cy);g.stroke({color:C.passiveStroke,width:1.5});
    g.rect(cx-bw/2,cy-bh/2,bw,bh);g.stroke({color:C.passiveStroke,width:1.5});
    g.moveTo(cx+bw/2,cy);g.lineTo(p.x+p.w,cy);g.stroke({color:C.passiveStroke,width:1.5});
  }else if(p.symbol==='generic-cap'){
    var gap=6,ph=12;
    g.moveTo(p.x,cy);g.lineTo(cx-gap/2,cy);g.stroke({color:C.passiveStroke,width:1.5});
    g.moveTo(cx-gap/2,cy-ph/2);g.lineTo(cx-gap/2,cy+ph/2);g.stroke({color:C.passiveStroke,width:2});
    g.moveTo(cx+gap/2,cy-ph/2);g.lineTo(cx+gap/2,cy+ph/2);g.stroke({color:C.passiveStroke,width:2});
    g.moveTo(cx+gap/2,cy);g.lineTo(p.x+p.w,cy);g.stroke({color:C.passiveStroke,width:1.5});
  }else if(p.symbol==='generic-ind'){
    var aw=6,na=3,ta=aw*na,sx=cx-ta/2;
    g.moveTo(p.x,cy);g.lineTo(sx,cy);g.stroke({color:C.passiveStroke,width:1.5});
    for(var ai=0;ai<na;ai++){
      var ax=sx+ai*aw;
      g.arc(ax+aw/2,cy,aw/2,Math.PI,0);g.stroke({color:C.passiveStroke,width:1.5});
    }
    g.moveTo(sx+ta,cy);g.lineTo(p.x+p.w,cy);g.stroke({color:C.passiveStroke,width:1.5});
  }else{
    g.roundRect(p.x,cy-8,p.w,16,3);
    g.fill({color:C.passiveFill});g.stroke({color:C.passiveStroke,width:1});
  }
}

function drawGndSymbol(parent,x,y){
  var g=new PIXI.Graphics();
  g.moveTo(x,y);g.lineTo(x,y+6);g.stroke({color:C.gnd,width:1.5});
  g.moveTo(x-7,y+6);g.lineTo(x+7,y+6);g.stroke({color:C.gnd,width:1.5});
  g.moveTo(x-4.5,y+9);g.lineTo(x+4.5,y+9);g.stroke({color:C.gnd,width:1.5});
  g.moveTo(x-2,y+12);g.lineTo(x+2,y+12);g.stroke({color:C.gnd,width:1.5});
  parent.addChild(g);
}

function makeWireHitArea(pts){
  if(pts.length<2)return new PIXI.Rectangle(0,0,1,1);
  var pad=8;
  var minX=pts[0][0],minY=pts[0][1],maxX=minX,maxY=minY;
  for(var i=1;i<pts.length;i++){
    if(pts[i][0]<minX)minX=pts[i][0];
    if(pts[i][0]>maxX)maxX=pts[i][0];
    if(pts[i][1]<minY)minY=pts[i][1];
    if(pts[i][1]>maxY)maxY=pts[i][1];
  }
  return new PIXI.Rectangle(minX-pad,minY-pad,maxX-minX+pad*2,maxY-minY+pad*2);
}

/* ── Pan / Zoom ───────────────────────────────────────────── */
var isPanning=false,panStart={x:0,y:0},worldStart={x:0,y:0},didPan=false;

app.canvas.addEventListener('mousedown',function(e){
  if(e.button===0){isPanning=true;didPan=false;panStart={x:e.clientX,y:e.clientY};worldStart={x:world.x,y:world.y};}
});
window.addEventListener('mousemove',function(e){
  if(!isPanning)return;
  var dx=e.clientX-panStart.x,dy=e.clientY-panStart.y;
  if(Math.abs(dx)>3||Math.abs(dy)>3)didPan=true;
  world.x=worldStart.x+dx;world.y=worldStart.y+dy;
});
window.addEventListener('mouseup',function(){isPanning=false;});

function minZoomScale(){
  if(!sceneData)return 0.05;
  var vb=sceneData.viewBox;
  var cw=container.clientWidth,ch=container.clientHeight;
  return Math.min(cw/(vb.w+80),ch/(vb.h+80))*0.95;
}
function clampZoom(rect,mx,my,factor){
  var wx=(mx-world.x)/world.scale.x;
  var wy=(my-world.y)/world.scale.y;
  var ns=Math.max(minZoomScale(),Math.min(20,world.scale.x*factor));
  world.scale.set(ns);
  world.x=mx-wx*ns;
  world.y=my-wy*ns;
}
/* ── Touch: single-finger pan + two-finger pinch-to-zoom ── */
var touchState={active:false,lastDist:0,lastMid:{x:0,y:0},startWorld:{x:0,y:0},fingers:0};
function touchDist(t){var dx=t[0].clientX-t[1].clientX,dy=t[0].clientY-t[1].clientY;return Math.sqrt(dx*dx+dy*dy);}
function touchMid(t){return{x:(t[0].clientX+t[1].clientX)/2,y:(t[0].clientY+t[1].clientY)/2};}
app.canvas.addEventListener('touchstart',function(e){
  e.preventDefault();
  touchState.active=true;touchState.fingers=e.touches.length;
  if(e.touches.length===1){
    panStart={x:e.touches[0].clientX,y:e.touches[0].clientY};
    worldStart={x:world.x,y:world.y};didPan=false;
  }else if(e.touches.length>=2){
    didPan=true;
    touchState.lastDist=touchDist(e.touches);
    touchState.lastMid=touchMid(e.touches);
    touchState.startWorld={x:world.x,y:world.y};
  }
},{passive:false});
app.canvas.addEventListener('touchmove',function(e){
  e.preventDefault();
  if(!touchState.active)return;
  if(e.touches.length===1&&touchState.fingers===1){
    var dx=e.touches[0].clientX-panStart.x,dy=e.touches[0].clientY-panStart.y;
    if(Math.abs(dx)>3||Math.abs(dy)>3)didPan=true;
    world.x=worldStart.x+dx;world.y=worldStart.y+dy;
  }else if(e.touches.length>=2){
    var dist=touchDist(e.touches);
    var mid=touchMid(e.touches);
    var rect=app.canvas.getBoundingClientRect();
    var mx=mid.x-rect.left,my=mid.y-rect.top;
    var factor=dist/touchState.lastDist;
    clampZoom(rect,mx,my,factor);
    touchState.lastDist=dist;touchState.lastMid=mid;
  }
},{passive:false});
app.canvas.addEventListener('touchend',function(e){
  if(e.touches.length===0){touchState.active=false;touchState.fingers=0;}
  else{touchState.fingers=e.touches.length;if(e.touches.length===1){panStart={x:e.touches[0].clientX,y:e.touches[0].clientY};worldStart={x:world.x,y:world.y};}}
},{passive:false});

app.canvas.addEventListener('wheel',function(e){
  e.preventDefault();
  if(e.ctrlKey){
    /* Pinch-to-zoom (trackpad) or Ctrl+scroll (mouse) */
    var rect=app.canvas.getBoundingClientRect();
    var mx=e.clientX-rect.left,my=e.clientY-rect.top;
    var factor=e.deltaY<0?1.04:1/1.04;
    clampZoom(rect,mx,my,factor);
  }else{
    /* Two-finger pan (trackpad) or regular scroll (mouse zooms) */
    if(e.deltaMode===0&&Math.abs(e.deltaX)+Math.abs(e.deltaY)<100){
      /* Likely trackpad — pan */
      world.x-=e.deltaX;
      world.y-=e.deltaY;
    }else{
      /* Likely mouse wheel — zoom */
      var rect2=app.canvas.getBoundingClientRect();
      var mx2=e.clientX-rect2.left,my2=e.clientY-rect2.top;
      var factor2=e.deltaY<0?1.04:1/1.04;
      clampZoom(rect2,mx2,my2,factor2);
    }
  }
},{passive:false});

function fitView(){
  if(!sceneData)return;
  var vb=sceneData.viewBox;
  var cw=container.clientWidth,ch=container.clientHeight;
  var scale=Math.min(cw/vb.w,ch/vb.h)*0.95;
  world.scale.set(scale);
  world.x=(cw-vb.w*scale)/2;
  world.y=(ch-vb.h*scale)/2;
}

/* ── Click background to deselect ─────────────────────────── */
app.canvas.addEventListener('click',function(e){
  if(justSelected){justSelected=false;return;}
  if(!didPan){clearSelection();}
});

/* ── Context Menu ─────────────────────────────────────────── */
var ctxMenu=document.createElement('div');
ctxMenu.style.cssText='display:none;position:fixed;background:#1c2128;border:1px solid #30363d;border-radius:6px;padding:4px 0;z-index:200;min-width:160px;box-shadow:0 4px 12px rgba(0,0,0,0.4)';
document.body.appendChild(ctxMenu);
function ctxItem(label,fn){
  var d=document.createElement('div');
  d.textContent=label;
  d.style.cssText='padding:6px 12px;color:#c9d1d9;font-size:12px;cursor:pointer';
  d.onmouseenter=function(){d.style.background='#30363d';};
  d.onmouseleave=function(){d.style.background='none';};
  d.onclick=function(){ctxMenu.style.display='none';fn();};
  return d;
}
function ctxSep(){
  var d=document.createElement('div');
  d.style.cssText='height:1px;background:#30363d;margin:4px 0';
  return d;
}
document.addEventListener('click',function(){ctxMenu.style.display='none';});
app.canvas.addEventListener('contextmenu',function(e){
  e.preventDefault();
  ctxMenu.innerHTML='';
  var mx=e.clientX,my=e.clientY;
  if(selectedRef){
    var comp=COMPONENTS[selectedRef];
    ctxMenu.appendChild(ctxItem('Edit Value...', function(){
      var cur=comp?comp.value:'';
      var nv=prompt('New value for '+selectedRef+':',cur);
      if(nv!==null&&nv!==cur){
        fetch('/api/edit-value/'+DESIGN_NAME,{method:'POST',body:JSON.stringify({ref:selectedRef,value:nv})})
          .then(function(r){return r.json();})
          .then(function(){location.reload();});
      }
    }));
    if(comp){
      ctxMenu.appendChild(ctxItem('Change Footprint...', function(){
        var cur=comp.component||'';
        var nf=prompt('New component family for '+selectedRef+':',cur);
        if(nf&&nf!==cur){
          fetch('/api/edit-footprint/'+DESIGN_NAME,{method:'POST',body:JSON.stringify({component:nf,oldComponent:cur,srcOff:comp.srcOff||0})})
            .then(function(r){return r.json();})
            .then(function(d){if(d.ok)location.reload();else alert('Error: component not found');});
        }
      }));
    }
    ctxMenu.appendChild(ctxSep());
    ctxMenu.appendChild(ctxItem('Remove Instance', function(){
      if(confirm('Remove '+selectedRef+'?')){
        fetch('/api/remove-instance/'+DESIGN_NAME,{method:'POST',body:JSON.stringify({ref:selectedRef})})
          .then(function(r){return r.json();})
          .then(function(){location.reload();});
      }
    }));
  }else if(selectedNet){
    ctxMenu.appendChild(ctxItem('Show Net: '+selectedNet,function(){highlightNet(selectedNet);}));
  }else{
    ctxMenu.appendChild(ctxItem('Add Instance...', function(){
      var comp=prompt('Component family (e.g. cap-0402):');
      if(!comp)return;
      var val=prompt('Value (e.g. 100nF):','');
      var sec=prompt('Section (leave empty for top-level):','');
      fetch('/api/add-instance/'+DESIGN_NAME,{method:'POST',body:JSON.stringify({component:comp,value:val||'',section:sec||'',pins:{}})})
        .then(function(r){return r.json();})
        .then(function(d){if(d.ok)location.reload();else alert('Error adding instance');});
    }));
    ctxMenu.appendChild(ctxItem('Run ERC',function(){runErc();}));
  }
  ctxMenu.style.left=mx+'px';ctxMenu.style.top=my+'px';ctxMenu.style.display='block';
});

/* ── Selection / Highlight ────────────────────────────────── */
function selectComponent(ref){
  clearSelection();
  justSelected=true;
  selectedRef=ref;
  var c=refContainers[ref];
  if(c){c.alpha=1;c.tint=C.highlight;}
  showComponentSidebar(ref);
}

function highlightNet(net){
  clearSelection();
  justSelected=true;
  if(!net)return;
  selectedNet=net;
  var items=netGraphics[net];
  if(items){for(var i=0;i<items.length;i++){items[i].tint=C.highlight;}}
  showNetSidebar(net);
}

function clearSelection(){
  if(selectedRef&&refContainers[selectedRef]){refContainers[selectedRef].tint=0xFFFFFF;}
  if(selectedNet&&netGraphics[selectedNet]){
    var items=netGraphics[selectedNet];
    for(var i=0;i<items.length;i++)items[i].tint=0xFFFFFF;
  }
  if(selectedSection&&sectionRects[selectedSection]){
    var sr=sectionRects[selectedSection];
    sr.gfx.clear();sr.gfx.roundRect(sr.x,sr.y,sr.w,sr.h,8);
    sr.gfx.fill({color:C.secBox});sr.gfx.stroke({color:C.secStroke,width:1.5});
  }
  selectedRef=null;selectedNet=null;selectedSection=null;
  closeSidebar();
}

/* ── Sidebar ──────────────────────────────────────────────── */
var sidebarContent=document.getElementById('sidebar-content');

function openSidebar(html){
  sidebarContent.innerHTML=html;
}
function closeSidebar(){showSectionList();}

function showSectionList(){
  var html='<h3 style="color:#fff;margin:0 0 12px;font-size:14px">Sections</h3>';
  if(!sceneData||!sceneData.sections||!sceneData.sections.length){
    html+='<div class="sidebar-empty">No sections</div>';
    sidebarContent.innerHTML=html;return;
  }
  for(var si=0;si<sceneData.sections.length;si++){
    var sec=sceneData.sections[si];
    html+='<div class="sec-item" onclick="showSectionDetail(\''+sec.name.replace(/'/g,"\\'")+'\')">';
    html+='<div class="sec-item-name">'+sec.name+'</div>';
    if(sec.description)html+='<div class="sec-item-desc">'+sec.description+'</div>';
    html+='</div>';
  }
  sidebarContent.innerHTML=html;
}

function showSectionDetail(name){
  var sr=sectionRects[name];
  if(sr)zoomToRect(sr.x,sr.y,sr.w,sr.h);
  /* Find components in this section */
  var comps=[];
  for(var ref5 in refRects){
    var rr=refRects[ref5];
    var cx=rr.x+rr.w/2,cy=rr.y+rr.h/2;
    if(sr&&cx>=sr.x&&cx<=sr.x+sr.w&&cy>=sr.y&&cy<=sr.y+sr.h)comps.push(ref5);
  }
  var html='<div style="margin-bottom:8px"><a href="#" onclick="showSectionList();event.preventDefault();" style="color:#58a6ff;font-size:12px">&larr; All Sections</a></div>';
  html+='<h3 style="color:#3fb950;margin:0 0 4px;font-size:14px">'+name+'</h3>';
  var sec2=null;
  for(var si2=0;si2<sceneData.sections.length;si2++){if(sceneData.sections[si2].name===name){sec2=sceneData.sections[si2];break;}}
  if(sec2&&sec2.description)html+='<div style="color:#8b949e;font-size:12px;margin-bottom:12px;font-style:italic">'+sec2.description+'</div>';
  if(comps.length){
    html+='<div style="font-size:12px;color:#666;margin-bottom:6px">'+comps.length+' components</div>';
    html+='<table style="width:100%;font-size:12px;border-collapse:collapse">';
    html+='<tr style="border-bottom:1px solid #30363d"><th style="text-align:left;padding:4px;color:#666">Ref</th><th style="text-align:left;padding:4px;color:#666">Value</th></tr>';
    for(var ci=0;ci<comps.length;ci++){
      var cref=comps[ci],cdata=COMPONENTS[cref];
      var cval=cdata?((cdata.value&&cdata.value.length)?cdata.value:cdata.component):'';
      html+='<tr style="border-bottom:1px solid #21262d;cursor:pointer" onclick="selectComponent(\''+cref+'\')">';
      html+='<td style="padding:4px;color:#4a9eff">'+cref+'</td><td style="padding:4px">'+cval+'</td></tr>';
    }
    html+='</table>';
  }else{
    html+='<div style="color:#666;font-size:12px">No components</div>';
  }
  if(sec2&&sec2.notes&&sec2.notes.length){
    html+='<div style="margin-top:12px;padding-top:8px;border-top:1px solid #21262d">';
    for(var ni=0;ni<sec2.notes.length;ni++){
      html+='<div style="color:#6e7681;font-size:11px;font-style:italic;margin-bottom:4px">'+sec2.notes[ni]+'</div>';
    }
    html+='</div>';
  }
  openSidebar(html);
}
window.showSectionList=showSectionList;
window.showSectionDetail=showSectionDetail;

function pinNetLookup(ref,pinNum){
  var key=ref+'.'+pinNum;
  for(var net in NETS){var pp=NETS[net];for(var i=0;i<pp.length;i++){if(pp[i]===key)return net;}}
  return '';
}
function pinNameLookup(ref,pinNum){
  var comp=COMPONENTS[ref];
  if(!comp)return '';
  if(comp.pins){for(var i=0;i<comp.pins.length;i++){if(comp.pins[i].num===pinNum)return comp.pins[i].pinName||'';}}
  if(comp.symbolPins){for(var j=0;j<comp.symbolPins.length;j++){if(comp.symbolPins[j].num===pinNum)return comp.symbolPins[j].name||'';}}
  return '';
}
function showComponentSidebar(ref){
  var comp=COMPONENTS[ref];
  if(!comp){openSidebar('<h3>'+ref+'</h3><p>No data</p>');return;}
  var html='<h3 style="color:#4a9eff;margin:0 0 8px">'+ref+'</h3>';
  html+='<div style="font-size:13px;color:#8b949e;margin-bottom:12px">'+comp.component+'</div>';
  if(comp.value)html+='<div style="margin-bottom:8px"><b>Value:</b> '+comp.value+'</div>';
  if(comp.footprint)html+='<div style="margin-bottom:8px"><b>Footprint:</b> '+comp.footprint+'</div>';
  if(comp.properties){
    var ds=comp.properties['datasheet']||comp.properties['Datasheet'];
    if(ds){
      var dsLabel=ds.length>40?ds.substring(0,37)+'...':ds;
      html+='<div style="margin-bottom:8px"><b>Datasheet:</b> <a href="'+ds+'" target="_blank" style="color:#58a6ff;text-decoration:underline">'+dsLabel+'</a></div>';
    }
    for(var pk in comp.properties){
      if(pk==='datasheet'||pk==='Datasheet')continue;
      html+='<div style="margin-bottom:4px;font-size:12px;color:#8b949e"><b>'+pk+':</b> '+comp.properties[pk]+'</div>';
    }
  }
  /* Use pins if available (active parts), else symbolPins (passives), else build from NETS */
  var pinList=comp.pins&&comp.pins.length?comp.pins:null;
  var useSym=!pinList&&comp.symbolPins&&comp.symbolPins.length;
  if(useSym)pinList=comp.symbolPins;
  if(!pinList||!pinList.length){
    /* Build pin list from NETS reverse lookup */
    var netPins=[];
    var prefix=ref+'.';
    for(var net in NETS){var pp=NETS[net];for(var ni=0;ni<pp.length;ni++){
      if(pp[ni].indexOf(prefix)===0){netPins.push({num:pp[ni].substring(prefix.length),pinName:'',net:net});}
    }}
    if(netPins.length)pinList=netPins;
  }
  if(pinList&&pinList.length){
    /* Group pins by section(part), then by net within each section */
    var sections={},secOrder=[];
    for(var i=0;i<pinList.length;i++){
      var p=pinList[i];
      var pNum=p.num||'';
      var pName=p.pinName||p.name||'';
      var pNet=p.net||pinNetLookup(ref,pNum);
      var pPart=p.part||'';
      var entry={num:pNum,name:pName,net:pNet};
      if(!sections[pPart]){sections[pPart]={nets:{},netOrder:[],ungrouped:[]};secOrder.push(pPart);}
      var sec=sections[pPart];
      if(pNet){
        if(!sec.nets[pNet]){sec.nets[pNet]=[];sec.netOrder.push(pNet);}
        sec.nets[pNet].push(entry);
      }else{sec.ungrouped.push(entry);}
    }
    var hasSections=secOrder.length>1||(secOrder.length===1&&secOrder[0]!=='');
    html+='<div style="margin-top:12px;display:flex;align-items:center;justify-content:space-between;gap:8px"><div><b>Pins:</b> <span style="color:#666;font-size:11px">'+pinList.length+' total</span></div></div>';
    html+='<input type="text" id="pin-search" placeholder="Filter by net, pin number, or name…" oninput="filterPinTable()" style="width:100%;margin-top:6px;padding:4px 6px;background:#0d1117;color:#e0e0e0;border:1px solid #30363d;border-radius:3px;font-size:12px;box-sizing:border-box"/>';
    var gid=0;
    for(var si=0;si<secOrder.length;si++){
      var secName=secOrder[si];
      var sec=sections[secName];
      if(hasSections&&secName){
        html+='<div style="margin-top:10px;padding:4px 0;border-bottom:1px solid #30363d;color:#3fb950;font-size:12px;font-weight:600">'+secName+'</div>';
      }
      html+='<table style="width:100%;font-size:12px;border-collapse:collapse;margin-top:2px">';
      for(var gi=0;gi<sec.netOrder.length;gi++){
        var gNet=sec.netOrder[gi];
        var grp=sec.nets[gNet];
        var eNet=gNet.replace(/'/g,"\\'");
        if(grp.length>1){
          var gidStr='pg'+gid++;
          var grpSearch=(grp[0].name+' '+gNet+' '+grp.map(function(p){return p.num;}).join(' ')).toLowerCase();
          html+='<tr data-summary="1" data-srch="'+grpSearch.replace(/"/g,"&quot;")+'" style="border-bottom:1px solid #21262d;cursor:pointer" onclick="var el=document.getElementById(\''+gidStr+'\');var ar=document.getElementById(\''+gidStr+'a\');if(el.style.display===\'none\'){el.style.display=\'\';ar.textContent=\'\u25BC\';}else{el.style.display=\'none\';ar.textContent=\'\u25B6\';}">';
          html+='<td style="padding:4px;color:#666"><span id="'+gidStr+'a" data-arrow="1" style="font-size:10px;margin-right:2px">\u25B6</span>'+grp.length+' pins</td>';
          html+='<td style="padding:4px;color:#888">'+grp[0].name+'</td>';
          html+='<td style="padding:4px;color:#e8c547;cursor:pointer" onclick="event.stopPropagation();highlightNet(\''+eNet+'\')">'+gNet+'</td></tr>';
          html+='<tbody id="'+gidStr+'" data-group="'+gidStr+'" style="display:none">';
          for(var pi=0;pi<grp.length;pi++){
            var innerSrch=(grp[pi].num+' '+grp[pi].name+' '+gNet).toLowerCase().replace(/"/g,"&quot;");
            html+='<tr data-srch="'+innerSrch+'" style="border-bottom:1px solid #1a1a2e"><td style="padding:2px 4px 2px 20px;color:#555;font-size:11px">'+grp[pi].num+'</td>';
            html+='<td style="padding:2px 4px;color:#777;font-size:11px">'+grp[pi].name+'</td>';
            html+='<td style="padding:2px 4px;font-size:11px"></td></tr>';
          }
          html+='</tbody>';
        }else{
          var mvId='mv'+gid++;
          var ePin=grp[0].num.replace(/'/g,"\\'");
          var eRef=ref.replace(/'/g,"\\'");
          var singleSrch=(grp[0].num+' '+grp[0].name+' '+gNet).toLowerCase().replace(/"/g,"&quot;");
          html+='<tr id="'+mvId+'" data-srch="'+singleSrch+'" style="border-bottom:1px solid #21262d"><td style="padding:4px;color:#666">'+grp[0].num+'</td><td style="padding:4px">'+grp[0].name+'</td>';
          html+='<td style="padding:4px;color:#e8c547;cursor:pointer" onclick="highlightNet(\''+eNet+'\')">'+gNet+'</td>';
          html+='<td class="move-cell" style="padding:4px;text-align:right"><a href="#" style="color:#58a6ff;font-size:11px;text-decoration:none" onclick="event.preventDefault();startMovePin(\''+eRef+'\',\''+ePin+'\',\''+mvId+'\');">Move</a></td></tr>';
        }
      }
      for(var ui=0;ui<sec.ungrouped.length;ui++){
        var ugSrch=(sec.ungrouped[ui].num+' '+sec.ungrouped[ui].name).toLowerCase().replace(/"/g,"&quot;");
        html+='<tr data-srch="'+ugSrch+'" style="border-bottom:1px solid #21262d"><td style="padding:4px;color:#666">'+sec.ungrouped[ui].num+'</td><td style="padding:4px">'+sec.ungrouped[ui].name+'</td>';
        html+='<td style="padding:4px;color:#444">-</td></tr>';
      }
      html+='</table>';
    }
  }
  openSidebar(html);
}

function showNetSidebar(net){
  var pins=NETS[net];
  var eNet2=net.replace(/'/g,"\\'");
  var html='<h3 style="color:#e8c547;margin:0 0 8px">'+net+'</h3>';
  if(pins&&pins.length){
    html+='<div style="margin-bottom:8px"><b>Connections:</b> '+pins.length+'</div>';
    html+='<table style="width:100%;font-size:12px;border-collapse:collapse">';
    for(var i=0;i<pins.length;i++){
      var parts=pins[i].split('.');
      var ref2=parts[0],pin2=parts[1]||'';
      var eRef2=ref2.replace(/'/g,"\\'");
      var ePin2=pin2.replace(/'/g,"\\'");
      var rowId2='nv'+i;
      var pName2=pinNameLookup(ref2,pin2);
      html+='<tr id="'+rowId2+'" style="border-bottom:1px solid #21262d"><td style="padding:4px;color:#4a9eff;cursor:pointer" onclick="selectComponent(\''+eRef2+'\')">'+ref2+'</td>';
      html+='<td style="padding:4px;color:#666">pin '+pin2+(pName2?' <span style="color:#8b949e">'+pName2+'</span>':'')+'</td>';
      html+='<td class="move-cell" style="padding:4px;text-align:right"><a href="#" style="color:#58a6ff;font-size:11px;text-decoration:none" onclick="event.preventDefault();startMovePin(\''+eRef2+'\',\''+ePin2+'\',\''+rowId2+'\');">Move</a></td></tr>';
    }
    html+='</table>';
  }else{
    html+='<div style="color:#666">No connections found</div>';
  }
  openSidebar(html);
}

/* ── Pin table search ─────────────────────────────────────── */
function filterPinTable(){
  var input=document.getElementById('pin-search');
  if(!input)return;
  var q=input.value.trim().toLowerCase();
  var rows=sidebarContent.querySelectorAll('[data-srch]');
  var summaries=sidebarContent.querySelectorAll('[data-summary]');
  var tbodies=sidebarContent.querySelectorAll('tbody[data-group]');
  var arrows=sidebarContent.querySelectorAll('[data-arrow]');
  if(!q){
    for(var a=0;a<summaries.length;a++)summaries[a].style.display='';
    for(var b=0;b<tbodies.length;b++)tbodies[b].style.display='none';
    for(var c=0;c<rows.length;c++)rows[c].style.display='';
    for(var d=0;d<arrows.length;d++)arrows[d].textContent='\u25B6';
    return;
  }
  for(var e=0;e<summaries.length;e++)summaries[e].style.display='none';
  for(var f=0;f<tbodies.length;f++)tbodies[f].style.display='';
  for(var g=0;g<rows.length;g++){
    var r=rows[g];
    if(r.hasAttribute('data-summary'))continue;
    r.style.display=(r.getAttribute('data-srch')||'').indexOf(q)>=0?'':'none';
  }
}
window.filterPinTable=filterPinTable;

/* ── Pin reassignment ─────────────────────────────────────── */
function moveActionCell(rowId){
  var row=document.getElementById(rowId);
  if(!row)return null;
  return row.querySelector('.move-cell');
}
function renderMoveLink(ref,oldPin,rowId){
  var er=ref.replace(/\x27/g,"\\x27"),op=oldPin.replace(/\x27/g,"\\x27");
  return '<a href="#" style="color:#58a6ff;font-size:11px;text-decoration:none" onclick="event.preventDefault();startMovePin(\''+er+'\',\''+op+'\',\''+rowId+'\');">Move</a>';
}
function startMovePin(ref,oldPin,rowId){
  var actionTd=moveActionCell(rowId);
  if(!actionTd)return;
  actionTd.innerHTML='<span style="color:#666;font-size:11px">loading…</span>';
  fetch('/api/free-pins/'+DESIGN_NAME+'?ref='+encodeURIComponent(ref))
    .then(function(r){return r.json();})
    .then(function(d){
      var freePins=(d&&d.free_pins)||[];
      var assignedPins=((d&&d.assigned_pins)||[]).filter(function(p){return p.pin!==oldPin;});
      if(!freePins.length&&!assignedPins.length){
        actionTd.innerHTML='<span style="color:#f85149;font-size:11px">no candidates</span>';
        setTimeout(function(){var c=moveActionCell(rowId);if(c)c.innerHTML=renderMoveLink(ref,oldPin,rowId);},2000);
        return;
      }
      var oldNet=pinNetLookup(ref,oldPin)||'';
      var inpId=rowId+'-inp',listId=rowId+'-list';
      var html='<div style="position:relative;display:inline-block;vertical-align:middle">';
      html+='<input id="'+inpId+'" placeholder="pin, func, or net…" autocomplete="off" style="background:#0d1117;color:#e8c547;border:1px solid #30363d;font-size:11px;padding:1px 4px;width:150px;box-sizing:border-box"/>';
      html+='<div id="'+listId+'" style="display:none;position:absolute;top:100%;right:0;z-index:100;background:#0d1117;border:1px solid #30363d;max-height:260px;overflow-y:auto;min-width:220px;font-size:11px"></div>';
      html+='</div> <a href="#" style="color:#8b949e;font-size:11px;vertical-align:middle" onclick="event.preventDefault();cancelMovePin(\''+ref.replace(/\x27/g,"\\x27")+'\',\''+oldPin.replace(/\x27/g,"\\x27")+'\',\''+rowId+'\');">✕</a>';
      actionTd.innerHTML=html;
      var inp=document.getElementById(inpId);
      var list=document.getElementById(listId);
      var highlighted=-1;
      var visible=[];
      var all=freePins.map(function(p){return{kind:'free',pin:p.pin,func:p.function||'',category:p.category||''};}).concat(
        assignedPins.map(function(p){return{kind:'swap',pin:p.pin,func:p.function||'',category:p.category||'',net:p.net||''};})
      );
      function renderList(){
        var q=inp.value.trim().toLowerCase();
        visible=[];
        for(var i=0;i<all.length;i++){
          var p=all[i];
          var hay=(p.pin+' '+p.func+' '+p.category+' '+(p.net||'')).toLowerCase();
          if(!q||hay.indexOf(q)>=0)visible.push(p);
          if(visible.length>=60)break;
        }
        var h='';
        if(oldNet){h+='<div style="padding:4px 6px;color:#8b949e;background:#161b22;border-bottom:1px solid #30363d">pin '+oldPin+' currently on <span style="color:#e6edf3">'+oldNet+'</span></div>';}
        if(!visible.length){h+='<div style="padding:4px 6px;color:#666">no matches</div>';list.innerHTML=h;list.style.display='block';highlighted=-1;return;}
        for(var j=0;j<visible.length;j++){
          var v=visible[j];
          var isHi=j===highlighted;
          var bg=isHi?(v.kind==='swap'?'background:#4c2889;':'background:#1f6feb;'):'';
          var fg=isHi?'color:#fff':'color:#e8c547';
          h+='<div data-idx="'+j+'" style="padding:3px 6px;cursor:pointer;'+fg+';'+bg+'"><span style="font-weight:600">'+v.pin+'</span>';
          if(v.func)h+=' <span style="color:'+(isHi?'#cfe':'#8b949e')+'">'+v.func+'</span>';
          if(v.kind==='swap')h+=' <span style="color:'+(isHi?'#e9d5ff':'#b392f0')+'">\u21C4 '+v.net+'</span>';
          h+='</div>';
        }
        list.innerHTML=h;
        list.style.display='block';
        var children=list.querySelectorAll('[data-idx]');
        for(var k=0;k<children.length;k++){
          children[k].onmousedown=(function(idx){return function(e){e.preventDefault();pickMoveTarget(ref,oldPin,oldNet,visible[idx],rowId);};})(k);
          children[k].onmouseenter=(function(idx){return function(){highlighted=idx;renderList();};})(k);
        }
      }
      inp.addEventListener('input',function(){highlighted=visible.length?0:-1;renderList();});
      inp.addEventListener('focus',renderList);
      inp.addEventListener('blur',function(){setTimeout(function(){list.style.display='none';},120);});
      inp.addEventListener('keydown',function(e){
        if(e.key==='ArrowDown'){e.preventDefault();if(visible.length){highlighted=(highlighted+1)%visible.length;renderList();}}
        else if(e.key==='ArrowUp'){e.preventDefault();if(visible.length){highlighted=(highlighted-1+visible.length)%visible.length;renderList();}}
        else if(e.key==='Enter'){e.preventDefault();if(highlighted>=0&&visible[highlighted])pickMoveTarget(ref,oldPin,oldNet,visible[highlighted],rowId);else{inp.style.borderColor='#f85149';setTimeout(function(){inp.style.borderColor='#30363d';},800);}}
        else if(e.key==='Escape'){e.preventDefault();cancelMovePin(ref,oldPin,rowId);}
      });
      inp.focus();
      renderList();
    })
    .catch(function(){actionTd.innerHTML='<span style="color:#f85149;font-size:11px">error</span>';});
}
function pickMoveTarget(ref,oldPin,oldNet,target,rowId){
  if(target.kind==='swap')applySwapPin(ref,oldPin,oldNet,target.pin,target.net,rowId);
  else applyMovePin(ref,oldPin,target.pin,rowId);
}
function cancelMovePin(ref,oldPin,rowId){
  var c=moveActionCell(rowId);if(!c)return;
  c.innerHTML=renderMoveLink(ref,oldPin,rowId);
}
function refreshDesignState(){
  return fetch('/api/design-state/'+DESIGN_NAME)
    .then(function(r){return r.json();})
    .then(function(d){
      if(d&&d.components)window.COMPONENTS=d.components;
      if(d&&d.nets)window.NETS=d.nets;
      if(selectedRef&&window.COMPONENTS[selectedRef])showComponentSidebar(selectedRef);
      else if(selectedNet&&window.NETS[selectedNet])showNetSidebar(selectedNet);
    });
}
function applyMovePin(ref,oldPin,newPin,rowId){
  var c=moveActionCell(rowId);if(!c)return;
  c.innerHTML='<span style="color:#666;font-size:11px">saving…</span>';
  fetch('/api/move-pin/'+DESIGN_NAME,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({ref:ref,old_pin:oldPin,new_pin:newPin})})
    .then(function(r){return r.json().then(function(d){return{status:r.status,body:d};});})
    .then(function(x){
      if(x.status===200&&x.body.ok){refreshDesignState();return;}
      var msg=x.body&&x.body.error?x.body.error:('http '+x.status);
      var cc=moveActionCell(rowId);if(!cc)return;
      cc.innerHTML='<span style="color:#f85149;font-size:11px" title="'+msg+'">'+msg+'</span>';
      setTimeout(function(){cancelMovePin(ref,oldPin,rowId);},2500);
    })
    .catch(function(){var cc=moveActionCell(rowId);if(cc)cc.innerHTML='<span style="color:#f85149;font-size:11px">network error</span>';});
}
function applySwapPin(ref,oldPin,oldNet,newPin,newNet,rowId){
  var c=moveActionCell(rowId);if(!c)return;
  var label='swap '+(oldNet||oldPin)+' \u21C4 '+(newNet||newPin);
  c.innerHTML='<span style="color:#666;font-size:11px">'+label+'…</span>';
  fetch('/api/swap-pins/'+DESIGN_NAME,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({ref:ref,pin_a:oldPin,pin_b:newPin})})
    .then(function(r){return r.json().then(function(d){return{status:r.status,body:d};});})
    .then(function(x){
      if(x.status===200&&x.body.ok){refreshDesignState();return;}
      var msg=x.body&&x.body.error?x.body.error:('http '+x.status);
      var cc=moveActionCell(rowId);if(!cc)return;
      cc.innerHTML='<span style="color:#f85149;font-size:11px" title="'+msg+'">'+msg+'</span>';
      setTimeout(function(){cancelMovePin(ref,oldPin,rowId);},2500);
    })
    .catch(function(){var cc=moveActionCell(rowId);if(cc)cc.innerHTML='<span style="color:#f85149;font-size:11px">network error</span>';});
}
window.startMovePin=startMovePin;
window.cancelMovePin=cancelMovePin;
window.applyMovePin=applyMovePin;
window.applySwapPin=applySwapPin;
window.pickMoveTarget=pickMoveTarget;

/* Make sidebar functions global for onclick handlers */
window.highlightNet=highlightNet;
window.selectComponent=selectComponent;

/* ── Build pin name search index ─────────────────────────── */
function buildPinIndex(){
  PIN_NAMES={};
  for(var ref4 in COMPONENTS){var info=COMPONENTS[ref4];if(info.pins)info.pins.forEach(function(p){
    if(p.pinName){var pn=p.pinName;if(!PIN_NAMES[pn])PIN_NAMES[pn]=[];PIN_NAMES[pn].push({ref:ref4,pin:p.num});}
  });}
}
buildPinIndex();

/* ── Zoom to world-space rect ─────────────────────────────── */
function zoomToRect(rx,ry,rw,rh){
  var pad=80;
  var cw=container.clientWidth,ch=container.clientHeight;
  var cx2=rx+rw/2,cy2=ry+rh/2;
  var nw=rw+pad*2,nh=rh+pad*2;
  var canvasR=cw/ch,bbR=nw/nh;
  if(bbR>canvasR){nh=nw/canvasR;}else{nw=nh*canvasR;}
  var ns=cw/nw;
  ns=Math.max(0.05,Math.min(20,ns));
  world.scale.set(ns);
  world.x=cw/2-cx2*ns;
  world.y=ch/2-cy2*ns;
}

/* ── Find containing section for a world-space rect ─────── */
function findSectionFor(rx,ry,rw,rh){
  var cx=rx+rw/2,cy=ry+rh/2;
  for(var sn in sectionRects){
    var sr=sectionRects[sn];
    if(cx>=sr.x&&cx<=sr.x+sr.w&&cy>=sr.y&&cy<=sr.y+sr.h)return sn;
  }
  return null;
}

/* ── Search ───────────────────────────────────────────────── */
var searchInput=document.getElementById('search-input');
var searchResults=document.getElementById('search-results');
var searchIdx=-1;
var searchItems=[];

searchInput.addEventListener('input',function(){
  var q=this.value.toLowerCase().trim();
  searchResults.innerHTML='';searchIdx=-1;searchItems=[];
  if(!q){searchResults.classList.remove('open');return;}
  var results=[];
  /* Sections */
  for(var sn in sectionRects){if(sn.toLowerCase().indexOf(q)>=0)results.push({name:sn,type:'section'});}
  /* Components */
  for(var ref3 in COMPONENTS){
    var c2=COMPONENTS[ref3];
    if(ref3.toLowerCase().indexOf(q)>=0)results.push({name:ref3,type:'comp',ref:ref3});
    else if(c2.value&&c2.value.toLowerCase().indexOf(q)>=0)results.push({name:ref3+' ('+c2.value+')',type:'comp',ref:ref3});
    else if(c2.component.toLowerCase().indexOf(q)>=0)results.push({name:ref3+' ('+c2.component+')',type:'comp',ref:ref3});
  }
  /* Pins */
  for(var pname in PIN_NAMES){if(pname.toLowerCase().indexOf(q)>=0){var pp=PIN_NAMES[pname];results.push({name:pp[0].ref+'.'+pp[0].pin+' ('+pname+')',type:'pin',ref:pp[0].ref,pin:pp[0].pin});}}
  /* Nets */
  for(var net2 in NETS){
    if(net2.toLowerCase().indexOf(q)>=0){
      results.push({name:net2+' ('+NETS[net2].length+' pins)',type:'net',net:net2});
    }
  }
  results=results.slice(0,20);
  if(!results.length){searchResults.classList.remove('open');return;}
  searchResults.classList.add('open');
  results.forEach(function(r){
    var div=document.createElement('div');div.className='search-result';
    div.innerHTML='<span>'+r.name+'</span><span class="search-result-type '+r.type+'">'+r.type+'</span>';
    div._data=r;
    div.addEventListener('click',function(){selectSearchResult(this._data);});
    searchResults.appendChild(div);searchItems.push(div);
  });
});
function selectSearchResult(r){
  searchResults.classList.remove('open');searchInput.value='';
  if(r.type==='section'){
    clearSelection();
    justSelected=true;
    selectedSection=r.name;
    var sr=sectionRects[r.name];
    if(sr){
      sr.gfx.clear();sr.gfx.roundRect(sr.x,sr.y,sr.w,sr.h,8);
      sr.gfx.fill({color:C.secBox});sr.gfx.stroke({color:C.highlight,width:2.5});
      zoomToRect(sr.x,sr.y,sr.w,sr.h);
    }
  }else if(r.type==='comp'||r.type==='pin'){
    var cref=r.ref||r.name;
    selectComponent(cref);
    var rr=refRects[cref];
    if(rr){var sec=findSectionFor(rr.x,rr.y,rr.w,rr.h);
      if(sec&&sectionRects[sec])zoomToRect(sectionRects[sec].x,sectionRects[sec].y,sectionRects[sec].w,sectionRects[sec].h);
      else zoomToRect(rr.x,rr.y,rr.w,rr.h);}
  }else if(r.type==='net'){
    highlightNet(r.net);
    /* Zoom to section of first pin in net */
    var np=NETS[r.net];
    if(np&&np.length>0){var nr=refRects[np[0].ref];
      if(nr){var nsec=findSectionFor(nr.x,nr.y,nr.w,nr.h);
        if(nsec&&sectionRects[nsec])zoomToRect(sectionRects[nsec].x,sectionRects[nsec].y,sectionRects[nsec].w,sectionRects[nsec].h);}}
  }
}
searchInput.addEventListener('keydown',function(e){
  if(e.key==='ArrowDown'){e.preventDefault();searchIdx=Math.min(searchIdx+1,searchItems.length-1);updateSearchSel();}
  else if(e.key==='ArrowUp'){e.preventDefault();searchIdx=Math.max(searchIdx-1,0);updateSearchSel();}
  else if(e.key==='Enter'&&searchItems.length>0){e.preventDefault();selectSearchResult(searchItems[Math.max(searchIdx,0)]._data);}
  else if(e.key==='Escape'){searchResults.classList.remove('open');searchInput.blur();}
});
function updateSearchSel(){searchItems.forEach(function(el,i){el.classList.toggle('selected',i===searchIdx);});}
searchInput.addEventListener('blur',function(){setTimeout(function(){searchResults.classList.remove('open');},200);});
document.addEventListener('keydown',function(e){if((e.ctrlKey||e.metaKey)&&e.key==='f'){e.preventDefault();searchInput.focus();searchInput.select();}});

/* ── Rebuild ──────────────────────────────────────────────── */
document.getElementById('rebuild-btn').onclick=async function(){
  this.textContent='Building...';this.disabled=true;
  try{
    await fetch('/api/push/'+DESIGN_NAME,{method:'POST'});
    var r2=await fetch('/api/scene-graph/'+DESIGN_NAME);
    sceneData=await r2.json();
    var sx=world.x,sy=world.y,ss=world.scale.x;
    buildScene();buildPinIndex();
    world.x=sx;world.y=sy;world.scale.set(ss);
  }catch(err){console.error(err);}
  this.textContent='Rebuild';this.disabled=false;
};

/* ── Source editor ────────────────────────────────────────── */
(function(){
  var openBtn=document.getElementById('source-btn');
  var modal=document.getElementById('source-modal');
  var ta=document.getElementById('source-textarea');
  var errBox=document.getElementById('source-err');
  var saveBtn=document.getElementById('source-save');
  var cancelBtn=document.getElementById('source-cancel');
  var closeBtn=document.getElementById('source-close');
  function showErr(msg){errBox.textContent=msg;errBox.style.display='block';}
  function clearErr(){errBox.textContent='';errBox.style.display='none';}
  function closeModal(){modal.style.display='none';clearErr();}
  async function openModal(){
    clearErr();
    openBtn.disabled=true;openBtn.textContent='Loading...';
    try{
      var r=await fetch('/api/source/'+DESIGN_NAME);
      var d=await r.json();
      if(!r.ok||typeof d.source!=='string'){showErr('Failed to load source: '+(d.error||r.status));}
      else{ta.value=d.source;}
      modal.style.display='flex';
      setTimeout(function(){ta.focus();},0);
    }catch(e){alert('Failed to load source: '+e);}
    openBtn.disabled=false;openBtn.textContent='Source';
  }
  async function save(){
    clearErr();
    saveBtn.disabled=true;saveBtn.textContent='Saving...';
    try{
      var r=await fetch('/api/source/'+DESIGN_NAME,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({source:ta.value})});
      var d=await r.json();
      if(!r.ok||!d.ok){showErr(d.error||('HTTP '+r.status));}
      else{
        var r2=await fetch('/api/scene-graph/'+DESIGN_NAME);
        sceneData=await r2.json();
        var sx=world.x,sy=world.y,ss=world.scale.x;
        buildScene();buildPinIndex();
        world.x=sx;world.y=sy;world.scale.set(ss);
        if(typeof d.version==='number')liveVersion=d.version;
        closeModal();
      }
    }catch(e){showErr(String(e));}
    saveBtn.disabled=false;saveBtn.textContent='Save & Rebuild';
  }
  openBtn.onclick=openModal;
  cancelBtn.onclick=closeModal;
  closeBtn.onclick=closeModal;
  saveBtn.onclick=save;
  modal.addEventListener('click',function(e){if(e.target===modal)closeModal();});
  ta.addEventListener('keydown',function(e){
    if((e.ctrlKey||e.metaKey)&&e.key==='s'){e.preventDefault();save();}
    else if(e.key==='Escape'){e.preventDefault();closeModal();}
    else if(e.key==='Tab'){e.preventDefault();var s=ta.selectionStart,en=ta.selectionEnd;ta.value=ta.value.slice(0,s)+'  '+ta.value.slice(en);ta.selectionStart=ta.selectionEnd=s+2;}
  });
})();

/* ── Reset ────────────────────────────────────────────────── */
document.getElementById('canvas-reset').onclick=function(){fitView();};

/* ── Live polling ─────────────────────────────────────────── */
setInterval(async function(){
  try{
    var r3=await fetch('/api/version/'+DESIGN_NAME);
    var d3=await r3.json();
    if(d3.version>liveVersion){
      liveVersion=d3.version;
      var r4=await fetch('/api/scene-graph/'+DESIGN_NAME);
      sceneData=await r4.json();
      var sx2=world.x,sy2=world.y,ss2=world.scale.x;
      buildScene();buildPinIndex();
      world.x=sx2;world.y=sy2;world.scale.set(ss2);
    }
  }catch(e2){}
},500);

/* ── Keyboard shortcuts ───────────────────────────────────── */
document.addEventListener('keydown',function(e){
  if(e.key==='/'&&document.activeElement!==searchInput){e.preventDefault();searchInput.focus();}
  if(e.key==='Escape'){clearSelection();}
});

/* ── Block Diagram Toggle ─────────────────────────────────── */
var blockDiagramMode=false;
var blockDiagramData=null;
var bdBtn=document.getElementById('block-diagram-btn');

var catColors={mcu:'#1f6feb',power:'#da3633',memory:'#8957e5',peripheral:'#2ea043',connector:'#d29922',clock:'#44aa99',comms:'#2196f3',sensor:'#2ea043',analog:'#e040fb',protection:'#8b949e'};
var catLabels={mcu:'MCU / Hub',power:'Power',memory:'Memory',peripheral:'Peripheral',connector:'Connector',clock:'Clock',comms:'Communications',sensor:'Sensor',analog:'Analog',protection:'Protection'};
var sigColors={power:'#e06060',clock:'#44aa99',data:'#4a9eff',differential:'#4a9eff',signal:'#8b949e'};
var sigLabels={power:'Power',clock:'Clock',data:'Data / Protocol',signal:'Signal'};
var bidiProtocols=['SPI','I2C','UART','USB','USB2.0-HS','USB2.0-FS','OctoSPI','QuadSPI','QSPI','SWD','JTAG','SDIO','SDMMC','CAN'];
/* Legend overlay */
var legend=document.createElement('div');
legend.style.cssText='display:none;position:absolute;bottom:12px;left:12px;background:rgba(22,27,34,0.92);border:1px solid #30363d;border-radius:8px;padding:10px 14px;font:11px system-ui,sans-serif;color:#8b949e;pointer-events:none;z-index:10;';
var lhtml='<div style="font-weight:600;color:#e0e0e0;margin-bottom:6px;font-size:12px">Blocks</div>';
for(var ck in catColors){
  if(ck==='sensor')continue;/* same color as peripheral */
  lhtml+='<div style="display:flex;align-items:center;gap:6px;margin-bottom:3px"><span style="display:inline-block;width:10px;height:10px;border-radius:2px;background:'+catColors[ck]+'"></span>'+catLabels[ck]+'</div>';
}
lhtml+='<div style="font-weight:600;color:#e0e0e0;margin:8px 0 6px;font-size:12px">Lines</div>';
var sigDone={};
for(var sk in sigColors){
  if(sigDone[sigColors[sk]])continue;sigDone[sigColors[sk]]=1;
  lhtml+='<div style="display:flex;align-items:center;gap:6px;margin-bottom:3px"><span style="display:inline-block;width:16px;height:2px;background:'+sigColors[sk]+'"></span>'+sigLabels[sk]+'</div>';
}
legend.innerHTML=lhtml;
container.appendChild(legend);

function buildBlockDiagram(){
  world.removeChildren();
  if(!blockDiagramData)return;
  var bd=blockDiagramData;
  /* Draw blocks with port stubs (no wires between blocks) */
  for(var bi=0;bi<bd.blocks.length;bi++){
    var b=bd.blocks[bi];
    var cc=catColors[b.category]||'#2ea043';
    var fillCol=parseInt(cc.replace('#',''),16);
    /* Container for click handling */
    var bc=new PIXI.Container();
    bc.eventMode='static';bc.cursor='pointer';
    bc.hitArea=new PIXI.Rectangle(b.x,b.y,b.w,b.h);
    (function(title){bc.on('pointertap',function(){
      if(didPan)return;
      blockDiagramMode=false;
      bdBtn.textContent='Block Diagram';bdBtn.style.borderColor='';
      legend.style.display='none';
      buildScene();buildPinIndex();
      showSectionDetail(title);
    });})(b.title);
    var bg=new PIXI.Graphics();
    bg.roundRect(b.x,b.y,b.w,b.h,8);
    var isConcept=b.status==='concept';
    bg.fill({color:fillCol,alpha:isConcept?0.07:0.15});
    if(isConcept){bg.stroke({color:fillCol,width:2,cap:'round',join:'round'});}
    else{bg.stroke({color:fillCol,width:2});}
    bc.addChild(bg);
    /* Title */
    /* Component symbol — each shape uses a fresh Graphics to avoid path bleed */
    var sx=b.x+b.w/2,sy=b.y+10;
    var sc=fillCol;
    var tl=b.title.toLowerCase(),sl=b.subtitle.toLowerCase();
    function G(){return new PIXI.Graphics();}
    if(tl.indexOf('usb')>=0&&b.category==='connector'){
      var s1=G();s1.roundRect(sx-7,sy+1,14,10,3);s1.stroke({color:sc,width:1.5,alpha:0.7});bc.addChild(s1);
      var s2=G();s2.circle(sx,sy+6,1.5);s2.fill({color:sc,alpha:0.7});bc.addChild(s2);
      var s3=G();s3.moveTo(sx,sy+11);s3.lineTo(sx,sy+15);s3.moveTo(sx-3,sy+4);s3.lineTo(sx,sy+6);s3.lineTo(sx+3,sy+4);s3.stroke({color:sc,width:1,alpha:0.7});bc.addChild(s3);
    }else if(tl.indexOf('batt')>=0){
      var s1=G();s1.roundRect(sx-6,sy,12,10,1);s1.roundRect(sx-3,sy-2,6,3,1);s1.fill({color:sc,alpha:0.6});bc.addChild(s1);
      var s2=G();s2.moveTo(sx-2,sy+3);s2.lineTo(sx+2,sy+3);s2.moveTo(sx,sy+1);s2.lineTo(sx,sy+5);s2.moveTo(sx-2,sy+8);s2.lineTo(sx+2,sy+8);s2.stroke({color:0x0d1117,width:1.2});bc.addChild(s2);
    }else if(tl.indexOf('charger')>=0){
      var s1=G();s1.roundRect(sx-7,sy,14,11,1);s1.stroke({color:sc,width:1.2,alpha:0.7});bc.addChild(s1);
      var s2=G();s2.roundRect(sx-3,sy-2,6,3,1);s2.fill({color:sc,alpha:0.5});bc.addChild(s2);
      var s3=G();s3.moveTo(sx+1,sy+2);s3.lineTo(sx-2,sy+6);s3.lineTo(sx+1,sy+6);s3.lineTo(sx-1,sy+10);s3.lineTo(sx+2,sy+6);s3.lineTo(sx-1,sy+6);s3.closePath();s3.fill({color:sc,alpha:0.8});bc.addChild(s3);
    }else if(tl.indexOf('buck')>=0||sl.indexOf('buck')>=0){
      var s1=G();s1.moveTo(sx-6,sy+6);for(var ci2=0;ci2<4;ci2++){s1.arc(sx-4+ci2*3,sy+6,1.5,Math.PI,0);}s1.stroke({color:sc,width:1.5,alpha:0.7});bc.addChild(s1);
      var s2=G();s2.moveTo(sx,sy+9);s2.lineTo(sx,sy+14);s2.moveTo(sx,sy+14);s2.lineTo(sx-2,sy+12);s2.moveTo(sx,sy+14);s2.lineTo(sx+2,sy+12);s2.stroke({color:sc,width:1.2,alpha:0.7});bc.addChild(s2);
    }else if(tl.indexOf('ldo')>=0||sl.indexOf('ldo')>=0){
      var s1=G();s1.moveTo(sx-7,sy+1);s1.lineTo(sx+7,sy+7);s1.lineTo(sx-7,sy+13);s1.closePath();s1.stroke({color:sc,width:1.5,alpha:0.7});bc.addChild(s1);
      var s2=G();s2.moveTo(sx-10,sy+7);s2.lineTo(sx-7,sy+7);s2.moveTo(sx+7,sy+7);s2.lineTo(sx+10,sy+7);s2.moveTo(sx-2,sy+13);s2.lineTo(sx-2,sy+16);s2.stroke({color:sc,width:1.2,alpha:0.6});bc.addChild(s2);
    }else if(b.category==='mcu'||tl.indexOf('stm32')>=0||sl.indexOf('stm32')>=0){
      var s1=G();s1.roundRect(sx-7,sy,14,14,1);s1.fill({color:sc,alpha:0.6});bc.addChild(s1);
      var s2=G();s2.arc(sx,sy,3,0,Math.PI);s2.stroke({color:0x0d1117,width:1.2});bc.addChild(s2);
      var s3=G();for(var pi2=0;pi2<4;pi2++){var py2=sy+1+pi2*3.5;s3.moveTo(sx-7,py2);s3.lineTo(sx-10,py2);s3.moveTo(sx+7,py2);s3.lineTo(sx+10,py2);}s3.stroke({color:sc,width:0.8,alpha:0.6});bc.addChild(s3);
    }else if(sl.indexOf('mx66')>=0||sl.indexOf('aps256')>=0||b.category==='memory'){
      var s1=G();s1.roundRect(sx-6,sy,12,12,1);s1.fill({color:sc,alpha:0.6});bc.addChild(s1);
      var s2=G();for(var r2=0;r2<3;r2++)for(var c2=0;c2<3;c2++){s2.rect(sx-4+c2*3,sy+2+r2*3,2,2);}s2.fill({color:0x0d1117,alpha:0.5});bc.addChild(s2);
      var s3=G();s3.moveTo(sx-6,sy+6);s3.lineTo(sx-9,sy+6);s3.moveTo(sx+6,sy+6);s3.lineTo(sx+9,sy+6);s3.stroke({color:sc,width:0.8,alpha:0.6});bc.addChild(s3);
    }else if(tl.indexOf('imu')>=0||sl.indexOf('icm')>=0){
      var s1=G();s1.circle(sx,sy+7,6);s1.stroke({color:sc,width:1.2,alpha:0.7});bc.addChild(s1);
      var s2=G();s2.moveTo(sx,sy+3);s2.lineTo(sx,sy+11);s2.moveTo(sx-4,sy+7);s2.lineTo(sx+4,sy+7);s2.moveTo(sx-3,sy+4);s2.lineTo(sx+3,sy+10);s2.stroke({color:sc,width:0.8,alpha:0.6});bc.addChild(s2);
    }else if(tl.indexOf('adc')>=0||sl.indexOf('ltc2323')>=0||sl.indexOf('adc')>=0){
      var s1=G();s1.moveTo(sx-7,sy+7);s1.bezierCurveTo(sx-5,sy+2,sx-3,sy+12,sx-1,sy+7);s1.stroke({color:sc,width:1.2,alpha:0.7});bc.addChild(s1);
      var s2=G();s2.moveTo(sx+1,sy+10);s2.lineTo(sx+3,sy+10);s2.lineTo(sx+3,sy+7);s2.lineTo(sx+5,sy+7);s2.lineTo(sx+5,sy+4);s2.lineTo(sx+7,sy+4);s2.stroke({color:sc,width:1.2,alpha:0.7});bc.addChild(s2);
    }else if(tl.indexOf('swd')>=0||tl.indexOf('debug')>=0){
      var s1=G();s1.roundRect(sx-6,sy+1,12,10,2);s1.stroke({color:sc,width:1.2,alpha:0.7});bc.addChild(s1);
      var s2=G();for(var pi2=0;pi2<3;pi2++){s2.circle(sx-3+pi2*3,sy+4,1);s2.circle(sx-3+pi2*3,sy+8,1);}s2.fill({color:sc,alpha:0.6});bc.addChild(s2);
      var s3=G();s3.moveTo(sx,sy+11);s3.lineTo(sx,sy+15);s3.stroke({color:sc,width:1.2,alpha:0.6});bc.addChild(s3);
    }else{
      var s1=G();s1.roundRect(sx-6,sy,12,12,1);s1.fill({color:sc,alpha:0.6});bc.addChild(s1);
      var s2=G();s2.arc(sx,sy,2.5,0,Math.PI);s2.stroke({color:0x0d1117,width:1});bc.addChild(s2);
      var s3=G();for(var pi2=0;pi2<3;pi2++){var py2=sy+2+pi2*4;s3.moveTo(sx-6,py2);s3.lineTo(sx-9,py2);s3.moveTo(sx+6,py2);s3.lineTo(sx+9,py2);}s3.stroke({color:sc,width:0.8,alpha:0.6});bc.addChild(s3);
    }
    var ty=b.y+28;
    var tt=new PIXI.Text({text:b.title,style:{fontFamily:'system-ui,sans-serif',fontSize:13,fontWeight:'bold',fill:0xe0e0e0}});
    tt.anchor.set(0.5,0);tt.x=b.x+b.w/2;tt.y=ty;
    bc.addChild(tt);ty+=18;
    /* Subtitle */
    if(b.subtitle){
      var st=new PIXI.Text({text:b.subtitle,style:{fontFamily:'system-ui,sans-serif',fontSize:11,fill:0x8b949e}});
      st.anchor.set(0.5,0);st.x=b.x+b.w/2;st.y=ty;
      bc.addChild(st);ty+=16;
    }
    /* Detail */
    if(b.detail){
      var dt=new PIXI.Text({text:b.detail,style:{fontFamily:'system-ui,sans-serif',fontSize:10,fontStyle:'italic',fill:0x666666}});
      dt.anchor.set(0.5,0);dt.x=b.x+b.w/2;dt.y=ty;
      bc.addChild(dt);ty+=14;
    }
    /* Port stubs */
    ty+=6;
    var stubLen=20,portH=16;
    var inPorts=[],outPorts=[];
    var isPowerConsumer=b.section==='power'&&b.category!=='power';
    if(b.ports){for(var pi=0;pi<b.ports.length;pi++){var p=b.ports[pi];
      if(isPowerConsumer&&p.signal!=='power')continue;
      if(p.direction==='out')outPorts.push(p);else inPorts.push(p);}}
    if(!isPowerConsumer&&b.protocols){for(var pi=0;pi<b.protocols.length;pi++){outPorts.push({name:b.protocols[pi],net:b.protocols[pi],direction:'out',signal:'data'});}}
    var maxPorts=Math.max(inPorts.length,outPorts.length);
    for(var pi=0;pi<maxPorts;pi++){
      var py=ty+pi*portH;
      if(pi<inPorts.length){
        var ip=inPorts[pi];
        var pc=sigColors[ip.signal]||'#8b949e';
        var pcInt=parseInt(pc.replace('#',''),16);
        var pg=new PIXI.Graphics();
        pg.moveTo(b.x-stubLen,py);pg.lineTo(b.x,py);
        pg.stroke({color:pcInt,width:1.5,alpha:0.8});
        bc.addChild(pg);
        /* Port name inside block */
        var ipt=new PIXI.Text({text:ip.name,style:{fontFamily:'monospace',fontSize:9,fill:pcInt}});
        ipt.anchor.set(0,0.5);ipt.x=b.x+4;ipt.y=py;ipt.alpha=0.7;
        bc.addChild(ipt);
        /* Net name on stub */
        var netName=ip.net||ip.name;
        var lbl=netName;if(ip.voltage)lbl+=' '+ip.voltage+'V';
        var pt=new PIXI.Text({text:lbl,style:{fontFamily:'monospace',fontSize:10,fill:pcInt}});
        pt.anchor.set(1,0.5);pt.x=b.x-stubLen-4;pt.y=py;
        bc.addChild(pt);
      }
      if(pi<outPorts.length){
        var op=outPorts[pi];
        var oc=sigColors[op.signal]||'#8b949e';
        var ocInt=parseInt(oc.replace('#',''),16);
        var og=new PIXI.Graphics();
        og.moveTo(b.x+b.w,py);og.lineTo(b.x+b.w+stubLen,py);
        og.stroke({color:ocInt,width:1.5,alpha:0.8});
        bc.addChild(og);
        /* Port name inside block */
        var opt=new PIXI.Text({text:op.name,style:{fontFamily:'monospace',fontSize:9,fill:ocInt}});
        opt.anchor.set(1,0.5);opt.x=b.x+b.w-4;opt.y=py;opt.alpha=0.7;
        bc.addChild(opt);
        /* Net name on stub */
        var oNetName=op.net||op.name;
        var olbl=oNetName;if(op.voltage)olbl+=' '+op.voltage+'V';
        var ot=new PIXI.Text({text:olbl,style:{fontFamily:'monospace',fontSize:10,fill:ocInt}});
        ot.anchor.set(0,0.5);ot.x=b.x+b.w+stubLen+4;ot.y=py;
        bc.addChild(ot);
      }
    }
    /* Concept badge */
    if(isConcept){
      var badge=new PIXI.Text({text:'CONCEPT',style:{fontFamily:'system-ui,sans-serif',fontSize:8,fontWeight:'bold',fill:0x8b949e,letterSpacing:1}});
      badge.anchor.set(1,0);badge.x=b.x+b.w-8;badge.y=b.y+4;
      bc.addChild(badge);
    }
    world.addChild(bc);
  }

  /* Section boxes */
  if(bd.sections){
    var sectionNames=['power','signal'];
    for(var si=0;si<bd.sections.length;si++){
      var sec=bd.sections[si];
      var sn=sectionNames[si]||'';
      var sx1=9999,sy1=9999,sx2=0,sy2=0,found=false;
      for(var i=0;i<bd.blocks.length;i++){
        var bb=bd.blocks[i];
        if(bb.section!==sn)continue;
        found=true;
        if(bb.x<sx1)sx1=bb.x;if(bb.y<sy1)sy1=bb.y;
        if(bb.x+bb.w>sx2)sx2=bb.x+bb.w;if(bb.y+bb.h>sy2)sy2=bb.y+bb.h;
      }
      if(!found)continue;
      var spx=80,spy=50,titleH=30;
      /* Title above box */
      var sh=new PIXI.Text({text:sec.name,style:{fontFamily:'system-ui,sans-serif',fontSize:16,fontWeight:'bold',fill:0x8b949e}});
      sh.x=sx1-spx+14;sh.y=sy1-spy-titleH;sh.alpha=0.7;
      world.addChild(sh);
      /* Box */
      var sg=new PIXI.Graphics();
      sg.roundRect(sx1-spx,sy1-spy,sx2-sx1+spx*2,sy2-sy1+spy*2,12);
      sg.stroke({color:0x30363d,width:1.5,alpha:0.5});
      sg.fill({color:0x161b22,alpha:0.3});
      world.addChildAt(sg,0);
    }
  }
  /* Column labels */
  if(bd.columns){
    for(var ci=0;ci<bd.columns.length;ci++){
      var col=bd.columns[ci];
      var ct=new PIXI.Text({text:col.name,style:{fontFamily:'system-ui,sans-serif',fontSize:12,fontWeight:'600',fill:0x58a6ff,letterSpacing:0.5}});
      ct.anchor.set(0.5,1);ct.x=col.x+110;ct.y=col.y;ct.alpha=0.6;
      world.addChild(ct);
    }
  }
  /* Fit */
  if(bd.blocks.length){
    var minX=9999,minY=9999,maxX=0,maxY=0;
    for(var i=0;i<bd.blocks.length;i++){
      var bb=bd.blocks[i];
      if(bb.x<minX)minX=bb.x;if(bb.y<minY)minY=bb.y;
      if(bb.x+bb.w>maxX)maxX=bb.x+bb.w;if(bb.y+bb.h>maxY)maxY=bb.y+bb.h;
    }
    var pad=60,cw=container.clientWidth,ch=container.clientHeight;
    var bw=maxX-minX+pad*2,bh=maxY-minY+pad*2;
    var sc=Math.min(cw/bw,ch/bh)*0.9;
    world.scale.set(sc);
    world.x=(cw-bw*sc)/2-(minX-pad)*sc;
    world.y=(ch-bh*sc)/2-(minY-pad)*sc;
  }
}

bdBtn.onclick=async function(){
  blockDiagramMode=!blockDiagramMode;
  if(blockDiagramMode){
    bdBtn.textContent='Schematic';
    bdBtn.style.borderColor='#58a6ff';
    try{
      var r5=await fetch('/api/block-diagram-json/'+DESIGN_NAME);
      blockDiagramData=await r5.json();
    }catch(e3){console.error(e3);}
    buildBlockDiagram();
    sidebarContent.innerHTML='<div class="sidebar-empty">Block diagram view</div>';
    legend.style.display='block';
  }else{
    bdBtn.textContent='Block Diagram';
    bdBtn.style.borderColor='';
    legend.style.display='none';
    buildScene();buildPinIndex();
    fitView();
    showSectionList();
  }
};

/* ── ERC Panel ─────────────────────────────────────────────── */
var ercBtn=document.getElementById('erc-btn');
var ercViolations=[];
function updateErcButton(){
  var nErr=0,nWarn=0;
  for(var i=0;i<ercViolations.length;i++){
    if(ercViolations[i].severity==='error')nErr++;else nWarn++;
  }
  // Also count ASSERTIONS
  if(typeof ASSERTIONS!=='undefined'){
    for(var ai=0;ai<ASSERTIONS.length;ai++){
      if(!ASSERTIONS[ai].passed){if(ASSERTIONS[ai].isWarning)nWarn++;else nErr++;}
    }
  }
  if(nErr>0){ercBtn.style.borderColor='#da3633';ercBtn.textContent='ERC ('+nErr+')';}
  else if(nWarn>0){ercBtn.style.borderColor='#d29922';ercBtn.textContent='ERC ('+nWarn+')';}
  else{ercBtn.style.borderColor='#2ea043';ercBtn.textContent='ERC \u2713';}
}
async function runErc(){
  ercBtn.textContent='ERC ...';ercBtn.style.borderColor='#888';
  try{
    var r=await fetch('/api/erc/'+DESIGN_NAME);
    ercViolations=await r.json();
  }catch(e){ercViolations=[];console.error('ERC fetch error',e);}
  updateErcButton();
  showErcPanel();
}
function showErcPanel(){
  var html='<h3 style="color:#e0e0e0;margin:0 0 12px;font-size:14px">Electrical Rule Checks</h3>';
  // Server-side ERC violations
  var errs=ercViolations.filter(function(v){return v.severity==='error';});
  var warns=ercViolations.filter(function(v){return v.severity==='warning';});
  // Also include ASSERTIONS
  if(typeof ASSERTIONS!=='undefined'){
    var aFails=ASSERTIONS.filter(function(a){return !a.passed&&!a.isWarning;});
    var aWarns=ASSERTIONS.filter(function(a){return !a.passed&&a.isWarning;});
    for(var i=0;i<aFails.length;i++)errs.push({message:aFails[i].message,kind:'assertion'});
    for(var j=0;j<aWarns.length;j++)warns.push({message:aWarns[j].message,kind:'assertion'});
  }
  if(errs.length===0&&warns.length===0){
    html+='<div style="color:#2ea043;font-size:13px;padding:8px 0">\u2713 No issues found</div>';
  }
  if(errs.length){
    html+='<div style="margin-bottom:8px;font-weight:600;color:#da3633">Errors ('+errs.length+')</div>';
    for(var ei=0;ei<errs.length;ei++){
      var ev=errs[ei];
      var clickAttr=ev.ref?' onclick="window._ercNav(\''+ev.ref+'\')" style="cursor:pointer;color:#f85149;font-size:12px;margin-bottom:4px;padding:4px 6px;background:#1a0000;border-radius:4px;border-left:3px solid #da3633"':' style="color:#f85149;font-size:12px;margin-bottom:4px;padding:4px 6px;background:#1a0000;border-radius:4px"';
      html+='<div'+clickAttr+'>'+ev.message;
      if(ev.ref)html+=' <span style="color:#666;font-size:10px">['+ev.ref+']</span>';
      html+='</div>';
    }
  }
  if(warns.length){
    html+='<div style="margin:8px 0;font-weight:600;color:#d29922">Warnings ('+warns.length+')</div>';
    for(var wi=0;wi<warns.length;wi++){
      var wv=warns[wi];
      var wClickAttr=wv.ref?' onclick="window._ercNav(\''+wv.ref+'\')" style="cursor:pointer;color:#d29922;font-size:12px;margin-bottom:4px;padding:4px 6px;background:#1a1500;border-radius:4px;border-left:3px solid #d29922"':wv.net?' onclick="window._ercNavNet(\''+wv.net+'\')" style="cursor:pointer;color:#d29922;font-size:12px;margin-bottom:4px;padding:4px 6px;background:#1a1500;border-radius:4px;border-left:3px solid #d29922"':' style="color:#d29922;font-size:12px;margin-bottom:4px;padding:4px 6px;background:#1a1500;border-radius:4px"';
      html+='<div'+wClickAttr+'>'+wv.message;
      if(wv.ref)html+=' <span style="color:#666;font-size:10px">['+wv.ref+']</span>';
      if(wv.net&&!wv.ref)html+=' <span style="color:#666;font-size:10px">['+wv.net+']</span>';
      html+='</div>';
    }
  }
  // Passed assertions
  if(typeof ASSERTIONS!=='undefined'){
    var passes=ASSERTIONS.filter(function(a){return a.passed;});
    if(passes.length){
      html+='<div style="margin:8px 0;font-weight:600;color:#2ea043">Passed ('+passes.length+')</div>';
      for(var pi2=0;pi2<passes.length;pi2++)html+='<div style="color:#3fb950;font-size:12px;margin-bottom:4px;padding:4px 6px;background:#001a00;border-radius:4px">'+passes[pi2].message+'</div>';
    }
  }
  html+='<button style="margin-top:12px;padding:6px 16px;background:#21262d;color:#c9d1d9;border:1px solid #30363d;border-radius:4px;cursor:pointer;font-size:12px" onclick="window._runErc()">Re-run ERC</button>';
  openSidebar(html);
}
window._ercNav=function(ref){selectComponent(ref);};
window._ercNavNet=function(net){highlightNet(net);};
window._runErc=function(){runErc();};
ercBtn.onclick=function(){runErc();};
updateErcButton();

/* ── Start ────────────────────────────────────────────────── */
await loadScene();
showSectionList();
if(typeof CONCEPT_MODE!=='undefined'&&CONCEPT_MODE){
  blockDiagramMode=true;
  bdBtn.textContent='Schematic';bdBtn.style.borderColor='#58a6ff';
  try{var r5=await fetch('/api/block-diagram-json/'+DESIGN_NAME);blockDiagramData=await r5.json();}catch(e3){}
  buildBlockDiagram();sidebarContent.innerHTML='<div class="sidebar-empty">Block diagram view</div>';legend.style.display='block';
}

}catch(err){console.error('Canvas viewer error:',err);}
})();
