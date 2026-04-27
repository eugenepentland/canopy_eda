var canvas=document.getElementById('schematic-canvas');
var sidebar=document.getElementById('sidebar');
var sidebarContent=document.getElementById('sidebar-content');
var sidebarClose=document.getElementById('sidebar-close');
var page=document.getElementById('page');
var editToggle=document.getElementById('edit-toggle');
var resetBtn=document.getElementById('canvas-reset');
var nodesToggle=document.getElementById('nodes-toggle');
var searchInput=document.getElementById('search-input');
var searchResults=document.getElementById('search-results');

function getSvg(){return canvas.querySelector('svg');}
function getVb(){var s=getSvg();return s?s.viewBox.baseVal:null;}

/* Pan/Zoom state */
var initVb=getVb();
var origVB=initVb?{x:initVb.x,y:initVb.y,w:initVb.width,h:initVb.height}:{x:0,y:0,w:850,h:600};
var isPanning=false,panStart={x:0,y:0},vbStart={x:0,y:0},didPan=false;
var editMode=false;
/* Pan */
canvas.addEventListener('mousedown',function(e){
  if(editMode&&e.target.closest('.hub-group'))return;
  var vb=getVb();if(!vb)return;
  isPanning=true;didPan=false;panStart={x:e.clientX,y:e.clientY};
  vbStart={x:vb.x,y:vb.y};
});
function screenToSvgDelta(dx,dy){var svg=getSvg();if(!svg)return{x:dx,y:dy};var ctm=svg.getScreenCTM();if(!ctm)return{x:dx,y:dy};return{x:dx/ctm.a,y:dy/ctm.d};}
window.addEventListener('mousemove',function(e){
  if(!isPanning)return;var vb=getVb();if(!vb)return;
  var d=screenToSvgDelta(e.clientX-panStart.x,e.clientY-panStart.y);
  var dx=d.x,dy=d.y;
  if(Math.abs(e.clientX-panStart.x)>3||Math.abs(e.clientY-panStart.y)>3)didPan=true;
  vb.x=vbStart.x-dx;vb.y=vbStart.y-dy;
});
window.addEventListener('mouseup',function(){isPanning=false;});

/* Zoom */
canvas.addEventListener('wheel',function(e){
  e.preventDefault();var vb=getVb();if(!vb)return;
  var scale=e.deltaY>0?1.1:0.9;
  var rect=canvas.getBoundingClientRect();
  var mx=(e.clientX-rect.left)/rect.width;
  var my=(e.clientY-rect.top)/rect.height;
  var px=vb.x+mx*vb.width;
  var py=vb.y+my*vb.height;
  var nw=vb.width*scale,nh=vb.height*scale;
  vb.x=px-mx*nw;vb.y=py-my*nh;
  vb.width=nw;vb.height=nh;
},{passive:false});

/* Reset */
resetBtn.addEventListener('click',function(){
  var vb=getVb();if(!vb)return;
  vb.x=origVB.x;vb.y=origVB.y;vb.width=origVB.w;vb.height=origVB.h;
});

/* Clear active highlights */
function clearActive(){
  var s=getSvg();if(!s)return;
  s.querySelectorAll('.comp-active').forEach(function(el){el.classList.remove('comp-active');});
  s.querySelectorAll('.net-active').forEach(function(el){el.classList.remove('net-active');});
}

/* Sidebar open/close */
function openSidebar(html){
  sidebarContent.innerHTML=html;sidebar.classList.add('open');page.classList.add('sidebar-open');
}
function closeSidebar(){
  sidebar.classList.remove('open');page.classList.remove('sidebar-open');clearActive();
}
sidebarClose.addEventListener('click',closeSidebar);

/* Component/net click (on canvas so it survives SVG replacement) */
canvas.addEventListener('click',function(e){
  if(didPan){didPan=false;return;}
  var comp=e.target.closest('.component');
  if(comp){
    var ref=comp.getAttribute('data-ref');if(!ref)return;
    var clickedPart=comp.getAttribute('data-part')||null;
    clearActive();var s=getSvg();
    if(s)s.querySelectorAll('.component[data-ref="'+ref+'"]').forEach(function(el){el.classList.add('comp-active');});
    var info=COMPONENTS[ref]||{};
    var html='<h3>'+ref+(clickedPart?' — '+clickedPart:'')+'</h3>';
    html+='<div class="sidebar-section"><div class="sidebar-label">Symbol</div><div class="sidebar-value">'+(info.symbol||'-')+'</div></div>';
    var fpPrefix=info.component?(info.component.match(/^(cap|res|ind|led)-/)||[])[1]:null;
    if(fpPrefix&&FAMILIES[fpPrefix]){
      html+='<div class="sidebar-section"><div class="sidebar-label">Footprint</div><div style="display:flex;gap:0.5rem;align-items:center;"><select id="fp-edit" style="background:#161b22;border:1px solid #444;border-radius:4px;color:#e0e0e0;padding:0.3rem 0.5rem;font-family:monospace;font-size:0.85rem;outline:none;">';
      FAMILIES[fpPrefix].forEach(function(f){html+='<option value="'+f+'"'+(f===info.component?' selected':'')+'>'+f+'</option>';});
      html+='</select><button id="fp-save" style="background:#2a4a2a;color:#4a9;border:1px solid #4a9;border-radius:4px;padding:0.3rem 0.6rem;font-size:0.75rem;cursor:pointer;">Save</button></div><div id="fp-preview" style="margin-top:0.5rem;height:150px;"></div></div>';
    }else{
      html+='<div class="sidebar-section"><div class="sidebar-label">Footprint</div><div class="sidebar-value">'+(info.footprint||'-')+'</div><div id="fp-preview" style="margin-top:0.5rem;height:150px;"></div>';
      if(info.footprint)html+='<a href="/model-viewer/'+info.footprint+'" target="_blank" style="color:#58a6ff;font-size:0.75rem;text-decoration:none;margin-top:0.25rem;display:inline-block">View 3D Model</a>';
      html+='</div>';
    }
    if(info.value){html+='<div class="sidebar-section"><div class="sidebar-label">Value</div><div style="display:flex;gap:0.5rem;align-items:center;"><input id="value-edit" type="text" value="'+info.value+'" style="background:#161b22;border:1px solid #444;border-radius:4px;color:#e0e0e0;padding:0.3rem 0.5rem;font-family:monospace;font-size:0.85rem;width:120px;outline:none;" /><button id="value-save" style="background:#2a4a2a;color:#4a9;border:1px solid #4a9;border-radius:4px;padding:0.3rem 0.6rem;font-size:0.75rem;cursor:pointer;">Save</button></div></div>';}else{html+='<div class="sidebar-section"><div class="sidebar-label">Value</div><div class="sidebar-value">-</div></div>';}
    if(info.note)html+='<div class="sidebar-section"><div class="sidebar-label">Note</div><div class="sidebar-note">'+info.note+'</div></div>';
    if(info.properties){var pkeys=Object.keys(info.properties);if(pkeys.length>0){html+='<div class="sidebar-section"><div class="sidebar-label">Properties</div><table style="width:100%;font-size:0.8rem;font-family:monospace;">';pkeys.forEach(function(k){html+='<tr><td style="color:#888;padding:0.15rem 0.5rem 0.15rem 0;">'+k+'</td><td style="color:#e0e0e0;padding:0.15rem 0;">'+info.properties[k]+'</td></tr>';});html+='</table></div>';}}
    /* Build pin-to-net map for this component */
    var pinNets={};
    for(var net in NETS){var members=NETS[net];for(var i=0;i<members.length;i++){var m=members[i];if(m.indexOf(ref+'.')===0){var pn=m.substring(ref.length+1);if(!pinNets[pn])pinNets[pn]=[];pinNets[pn].push(net);}}}
    /* Build pin-to-part map from component data */
    var pinParts={};
    if(info.pins)info.pins.forEach(function(p){pinParts[p.num]={net:p.net,part:p.part};});
    /* Build symbol pin name map */
    var symPinNames={};
    if(info.symbolPins)info.symbolPins.forEach(function(sp){symPinNames[sp.num]=sp.name;});
    /* Filter pins by clicked part if applicable */
    var partPinSet=null;
    if(clickedPart){
      partPinSet={};
      if(info.pins)info.pins.forEach(function(p){if(p.part===clickedPart)partPinSet[p.num]=true;});
    }
    /* Group pins by (part, net) */
    var pinList=Object.keys(pinNets).sort(function(a,b){var na=parseInt(a),nb=parseInt(b);if(!isNaN(na)&&!isNaN(nb))return na-nb;return a.localeCompare(b);});
    if(partPinSet)pinList=pinList.filter(function(pn){return partPinSet[pn];});
    var hasAnyPins=pinList.length>0||(!partPinSet&&Object.keys(symPinNames).length>0);
    if(hasAnyPins){
      var groups=[];var gmap={};
      pinList.forEach(function(pn){
        var net=pinNets[pn].join(',');
        var pp=pinParts[pn];
        var part=pp?pp.part:'';
        var key=part+'|'+net;
        if(!gmap[key]){gmap[key]={part:part,nets:pinNets[pn],pins:[]};groups.push(gmap[key]);}
        gmap[key].pins.push(pn);
      });
      html+='<div class="sidebar-section"><div class="sidebar-label">Pins</div><ul class="sidebar-pins">';
      html+='<li class="pin-header"><span>Pin</span><span>Net</span></li>';
      var lastPart='';
      groups.forEach(function(g){
        if(!clickedPart&&g.part&&g.part!==lastPart){lastPart=g.part;html+='<li class="part-header" style="color:#58a6ff;font-weight:bold;border-bottom:1px solid #333;padding-top:0.5rem;">'+g.part+'</li>';}
        html+='<li><span class="pin-num">'+g.pins.join(', ')+'</span><span class="pin-net">';
        g.nets.forEach(function(n,i){
          if(i>0)html+=', ';
          html+='<a href="#" class="net-link" data-net="'+n+'" style="color:#e8c547;text-decoration:none;cursor:pointer;">'+n+'</a>';
        });
        html+='</span></li>';
      });
      /* Unconnected pins from symbol (only in all-pins view) */
      if(!partPinSet){
        var connectedNums={};pinList.forEach(function(pn){connectedNums[pn]=true;});
        var unconnected=[];
        if(info.symbolPins)info.symbolPins.forEach(function(sp){if(!connectedNums[sp.num])unconnected.push(sp);});
        if(unconnected.length>0){
          html+='<li class="part-header" style="color:#666;font-weight:bold;border-bottom:1px solid #333;padding-top:0.5rem;">Unconnected</li>';
          unconnected.forEach(function(sp){
            html+='<li><span class="pin-num">'+sp.num+'</span><span class="pin-net" style="color:#555;">'+sp.name+' (NC)</span></li>';
          });
        }
      }
      html+='</ul></div>';
      /* Show all pins / show part pins toggle */
      if(clickedPart){
        html+='<button id="show-all-pins" style="background:#2a2a4a;color:#4a9eff;border:1px solid #4a9eff;border-radius:4px;padding:0.4rem 0.8rem;font-size:0.75rem;cursor:pointer;width:100%;margin-top:0.5rem;">Show All '+ref+' Pins</button>';
      }
    }
    openSidebar(html);
    if(info.footprint){var fpEl=document.getElementById('fp-preview');if(fpEl){fetch('/api/footprint/'+info.footprint).then(function(r){if(r.ok)return r.text();throw '';}).then(function(svg){fpEl.innerHTML=svg;var s=fpEl.querySelector('svg');if(s){s.style.width='100%';s.style.height='100%';}}).catch(function(){fpEl.innerHTML=info.fpOk?'<span style="color:#555;font-size:0.75rem;">No preview</span>':'<div style="display:flex;align-items:center;gap:0.5rem;padding:0.5rem;background:#451a03;border:1px solid #f59e0b;border-radius:4px;margin-top:0.25rem;"><span style="color:#f59e0b;font-size:1.2rem;font-weight:bold;">&#9888;</span><span style="color:#fbbf24;font-size:0.8rem;">Footprint has no pad data — may be AI-generated or incomplete</span></div>';});}}
    var saveBtn=document.getElementById('value-save');
    if(saveBtn){
      var input=document.getElementById('value-edit');
      saveBtn.addEventListener('click',function(){
        var newVal=input.value.trim();if(!newVal)return;
        saveBtn.textContent='...';saveBtn.disabled=true;
        fetch('/api/edit-value/'+SCHEMATIC_SLUG,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({ref:ref,value:newVal})})
          .then(function(r){return r.json();})
          .then(function(d){if(d.ok){saveBtn.textContent='Saved';saveBtn.style.color='#3fb950';COMPONENTS[ref].value=newVal;}else{saveBtn.textContent='Error';saveBtn.style.color='#f85149';}})
          .catch(function(){saveBtn.textContent='Error';saveBtn.style.color='#f85149';});
      });
      input.addEventListener('keydown',function(ev){if(ev.key==='Enter'){ev.preventDefault();saveBtn.click();}});
    }
    var fpSaveBtn=document.getElementById('fp-save');
    if(fpSaveBtn){
      var fpSelect=document.getElementById('fp-edit');
      fpSaveBtn.addEventListener('click',function(){
        var newComp=fpSelect.value;if(!newComp)return;
        fpSaveBtn.textContent='...';fpSaveBtn.disabled=true;
        fetch('/api/edit-footprint/'+SCHEMATIC_SLUG,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({ref:ref,component:newComp,oldComponent:info.component,srcOff:info.srcOff})})
          .then(function(r){return r.json();})
          .then(function(d){if(d.ok){fpSaveBtn.textContent='Saved';fpSaveBtn.style.color='#3fb950';if(d.components){for(var k in d.components)COMPONENTS[k]=d.components[k];}}else{fpSaveBtn.textContent='Error';fpSaveBtn.style.color='#f85149';}})
          .catch(function(){fpSaveBtn.textContent='Error';fpSaveBtn.style.color='#f85149';});
      });
    }
    var allPinsBtn=document.getElementById('show-all-pins');
    if(allPinsBtn){
      allPinsBtn.addEventListener('click',function(){
        var fakeComp=getSvg().querySelector('.component[data-ref="'+ref+'"]');
        if(!fakeComp)return;
        var clone=fakeComp.cloneNode(false);
        clone.removeAttribute('data-part');
        var fakeEv={target:clone,stopPropagation:function(){},closest:function(s){return s==='.component'?clone:null;}};
        clone.getAttribute=function(a){if(a==='data-ref')return ref;if(a==='data-part')return null;return null;};
        /* Re-trigger sidebar without part filter by simulating click on component without data-part */
        clearActive();
        getSvg().querySelectorAll('.component[data-ref="'+ref+'"]').forEach(function(el){el.classList.add('comp-active');});
        var info2=COMPONENTS[ref]||{};
        var h2='<h3>'+ref+' — All Pins</h3>';
        h2+='<div class="sidebar-section"><div class="sidebar-label">Symbol</div><div class="sidebar-value">'+(info2.symbol||'-')+'</div></div>';
        h2+='<div class="sidebar-section"><div class="sidebar-label">Footprint</div><div class="sidebar-value">'+(info2.footprint||'-')+'</div></div>';
        var pn2={};for(var n2 in NETS){var mm=NETS[n2];for(var j=0;j<mm.length;j++){var m2=mm[j];if(m2.indexOf(ref+'.')===0){var pk=m2.substring(ref.length+1);if(!pn2[pk])pn2[pk]=[];pn2[pk].push(n2);}}}
        var pp2={};if(info2.pins)info2.pins.forEach(function(p){pp2[p.num]={net:p.net,part:p.part};});
        var pl2=Object.keys(pn2).sort(function(a,b){var na=parseInt(a),nb=parseInt(b);if(!isNaN(na)&&!isNaN(nb))return na-nb;return a.localeCompare(b);});
        if(pl2.length>0){
          var gr2=[];var gm2={};
          pl2.forEach(function(pn){var net=pn2[pn].join(',');var pp=pp2[pn];var part=pp?pp.part:'';var key=part+'|'+net;if(!gm2[key]){gm2[key]={part:part,nets:pn2[pn],pins:[]};gr2.push(gm2[key]);}gm2[key].pins.push(pn);});
          h2+='<div class="sidebar-section"><div class="sidebar-label">Pins</div><ul class="sidebar-pins">';
          h2+='<li class="pin-header"><span>Pin</span><span>Net</span></li>';
          var lp2='';gr2.forEach(function(g){if(g.part&&g.part!==lp2){lp2=g.part;h2+='<li class="part-header" style="color:#58a6ff;font-weight:bold;border-bottom:1px solid #333;padding-top:0.5rem;">'+g.part+'</li>';}h2+='<li><span class="pin-num">'+g.pins.join(', ')+'</span><span class="pin-net">';g.nets.forEach(function(n,i){if(i>0)h2+=', ';h2+='<a href="#" class="net-link" data-net="'+n+'" style="color:#e8c547;text-decoration:none;cursor:pointer;">'+n+'</a>';});h2+='</span></li>';});
          var cn2={};pl2.forEach(function(pn){cn2[pn]=true;});var uc2=[];
          if(info2.symbolPins)info2.symbolPins.forEach(function(sp){if(!cn2[sp.num])uc2.push(sp);});
          if(uc2.length>0){h2+='<li class="part-header" style="color:#666;font-weight:bold;border-bottom:1px solid #333;padding-top:0.5rem;">Unconnected</li>';uc2.forEach(function(sp){h2+='<li><span class="pin-num">'+sp.num+'</span><span class="pin-net" style="color:#555;">'+sp.name+' (NC)</span></li>';});}
          h2+='</ul></div>';
        }
        openSidebar(h2);
      });
    }
    document.querySelectorAll('.net-link').forEach(function(link){
      link.addEventListener('click',function(ev){
        ev.preventDefault();
        var netName=this.getAttribute('data-net');
        clearActive();
        getSvg().querySelectorAll('.net[data-net="'+netName+'"]').forEach(function(el){el.classList.add('net-active');});
        var pins=NETS[netName]||[];
        var h='<h3>Net: '+netName+'</h3>';
        h+='<div class="sidebar-section"><div class="sidebar-label">Connected Pins</div><ul class="sidebar-pins">';
        pins.forEach(function(p){var r=p.split('.')[0];h+='<li><a href="#" class="pin-link" data-ref="'+r+'" style="color:#4a9eff;text-decoration:none;cursor:pointer;">'+p+'</a></li>';});
        h+='</ul></div>';
        openSidebar(h);
        document.querySelectorAll('.pin-link').forEach(function(l){
          l.addEventListener('click',function(ev2){
            ev2.preventDefault();
            var r2=this.getAttribute('data-ref');
            var c2=getSvg().querySelector('.component[data-ref="'+r2+'"]');
            if(c2){c2.dispatchEvent(new MouseEvent('click',{bubbles:true}));}
          });
        });
      });
    });
    e.stopPropagation();return;
  }
  var net=e.target.closest('.net');
  if(net){
    var netName=net.getAttribute('data-net');if(!netName)return;
    clearActive();
    getSvg().querySelectorAll('.net[data-net="'+netName+'"]').forEach(function(el){el.classList.add('net-active');});
    var pins=NETS[netName]||[];
    var html='<h3>Net: '+netName+'</h3>';
    html+='<div class="sidebar-section"><div class="sidebar-label">Connected Pins</div><ul class="sidebar-pins">';
    pins.forEach(function(p){var ref=p.split('.')[0];html+='<li><a href="#" class="pin-link" data-ref="'+ref+'" style="color:#4a9eff;text-decoration:none;cursor:pointer;">'+p+'</a></li>';});
    html+='</ul></div>';
    openSidebar(html);
    document.querySelectorAll('.pin-link').forEach(function(link){
      link.addEventListener('click',function(ev){
        ev.preventDefault();
        var ref=this.getAttribute('data-ref');
        var comp=getSvg().querySelector('.component[data-ref="'+ref+'"]');
        if(comp){comp.dispatchEvent(new MouseEvent('click',{bubbles:true}));}
      });
    });
    e.stopPropagation();return;
  }
});

/* Nodes toggle */
nodesToggle.addEventListener('click',function(){
  this.classList.toggle('active');
  var show=this.classList.contains('active');
  getSvg().querySelectorAll('.debug-pin').forEach(function(el){el.style.display=show?'':'none';});
});

/* Edit mode toggle */
editToggle.addEventListener('click',function(){
  editMode=!editMode;
  this.classList.toggle('active',editMode);
  canvas.classList.toggle('edit-mode',editMode);
});

/* Rebuild */
var rebuildBtn=document.getElementById('rebuild-btn');
rebuildBtn.addEventListener('click',function(){
  rebuildBtn.textContent='Building...';rebuildBtn.disabled=true;
  fetch('/api/push/'+SCHEMATIC_SLUG,{method:'POST'}).then(function(r){
    if(!r.ok)throw new Error('Build failed');
    rebuildBtn.textContent='Rebuild';rebuildBtn.disabled=false;
  }).catch(function(e){
    rebuildBtn.textContent='Rebuild';rebuildBtn.disabled=false;
    alert('Build failed: '+e.message);
  });
});

/* Update PCB */
var pcbBtn=document.getElementById('update-pcb');
var shortNetsCb=document.getElementById('short-nets-cb');
pcbBtn.addEventListener('click',function(){
  pcbBtn.textContent='Updating...';pcbBtn.disabled=true;
  var url='/api/update-pcb/'+SCHEMATIC_SLUG;
  if(shortNetsCb.checked)url+='?short-nets=1';
  fetch(url,{method:'POST'}).then(function(r){
    return r.json();
  }).then(function(d){
    if(d.ok){pcbBtn.textContent='PCB Updated';pcbBtn.style.color='#3fb950';setTimeout(function(){pcbBtn.textContent='Update PCB';pcbBtn.style.color='';pcbBtn.disabled=false;},2000);}
    else{pcbBtn.textContent='Update PCB';pcbBtn.disabled=false;alert('PCB update failed: '+(d.error||'unknown'));}
  }).catch(function(e){
    pcbBtn.textContent='Update PCB';pcbBtn.disabled=false;
    alert('PCB update failed: '+e.message);
  });
});

/* Hub dragging in edit mode */
var dragHub=null,dragStart={x:0,y:0},hubOrigTx=0,hubOrigTy=0;
canvas.addEventListener('mousedown',function(e){
  if(!editMode)return;var svg=getSvg();if(!svg)return;
  var hub=e.target.closest('.hub-group');
  if(!hub||hub===svg.querySelector('.hub-group'))return;
  dragHub=hub;hub.classList.add('dragging');
  var t=hub.transform.baseVal;
  if(t.numberOfItems===0){var s=svg.createSVGTransform();s.setTranslate(0,0);t.appendItem(s);}
  hubOrigTx=t.getItem(0).matrix.e;hubOrigTy=t.getItem(0).matrix.f;
  var pt=svg.createSVGPoint();pt.x=e.clientX;pt.y=e.clientY;
  var svgP=pt.matrixTransform(svg.getScreenCTM().inverse());
  dragStart={x:svgP.x,y:svgP.y};
  isPanning=false;e.stopPropagation();e.preventDefault();
});
window.addEventListener('mousemove',function(e){
  if(!dragHub)return;var svg=getSvg();if(!svg)return;
  var pt=svg.createSVGPoint();pt.x=e.clientX;pt.y=e.clientY;
  var svgP=pt.matrixTransform(svg.getScreenCTM().inverse());
  var dx=svgP.x-dragStart.x,dy=svgP.y-dragStart.y;
  var snap=10;
  var nx=Math.round((hubOrigTx+dx)/snap)*snap;
  var ny=Math.round((hubOrigTy+dy)/snap)*snap;
  dragHub.transform.baseVal.getItem(0).setTranslate(nx,ny);
});
window.addEventListener('mouseup',function(){
  if(dragHub){dragHub.classList.remove('dragging');dragHub=null;}
});

/* Build pin name search index: pinName → [{ref, pin_num}] */
var PIN_NAMES={};
for(var ref in COMPONENTS){var info=COMPONENTS[ref];if(info.pins)info.pins.forEach(function(p){
  if(p.pinName){var pn=p.pinName;if(!PIN_NAMES[pn])PIN_NAMES[pn]=[];PIN_NAMES[pn].push({ref:ref,pin:p.num});}
});}

/* Search */
var searchIdx=-1,searchItems=[];
searchInput.addEventListener('input',function(){
  var q=this.value.toLowerCase().trim();
  searchResults.innerHTML='';searchIdx=-1;searchItems=[];
  if(!q){searchResults.classList.remove('open');return;}
  var results=[];
  SECTIONS.forEach(function(s){var sn=typeof s==='string'?s:s.name;if(sn.toLowerCase().indexOf(q)>=0)results.push({name:sn,type:'section'});});
  for(var ref in COMPONENTS){var ci=COMPONENTS[ref];if(ref.toLowerCase().indexOf(q)>=0)results.push({name:ref,type:'comp'});
    else if(ci.value&&ci.value.toLowerCase().indexOf(q)>=0)results.push({name:ref+' ('+ci.value+')',type:'comp',ref:ref});}
  for(var pname in PIN_NAMES){if(pname.toLowerCase().indexOf(q)>=0){var pp=PIN_NAMES[pname];results.push({name:pp[0].ref+'.'+pp[0].pin+' ('+pname+')',type:'pin',ref:pp[0].ref,pin:pp[0].pin});}}
  for(var net in NETS){if(net.toLowerCase().indexOf(q)>=0)results.push({name:net,type:'net'});}
  results=results.slice(0,20);
  if(results.length===0){searchResults.classList.remove('open');return;}
  searchResults.classList.add('open');
  results.forEach(function(r,i){
    var div=document.createElement('div');div.className='search-result';
    div.innerHTML='<span>'+r.name+'</span><span class="search-result-type '+r.type+'">'+r.type+'</span>';
    div.addEventListener('click',function(){selectSearchResult(r);});
    searchResults.appendChild(div);searchItems.push(div);
  });
  searchItems._data=results;
});
searchInput.addEventListener('keydown',function(e){
  if(e.key==='ArrowDown'){e.preventDefault();searchIdx=Math.min(searchIdx+1,searchItems.length-1);updateSearchSel();}
  else if(e.key==='ArrowUp'){e.preventDefault();searchIdx=Math.max(searchIdx-1,0);updateSearchSel();}
  else if(e.key==='Enter'&&searchItems.length>0){e.preventDefault();selectSearchResult(searchItems._data[Math.max(searchIdx,0)]);}
  else if(e.key==='Escape'){searchResults.classList.remove('open');searchInput.blur();}
});
function updateSearchSel(){searchItems.forEach(function(el,i){el.classList.toggle('selected',i===searchIdx);});}
function zoomToElement(el){
  var svg=getSvg();if(!svg||!el)return;
  var vb=getVb();if(!vb)return;
  var bb=el.getBBox();if(!bb||bb.width===0)return;
  var pad=80;
  var cx=bb.x+bb.width/2,cy=bb.y+bb.height/2;
  var nw=bb.width+pad*2,nh=bb.height+pad*2;
  var canvasR=canvas.clientWidth/canvas.clientHeight;
  var bbR=nw/nh;
  if(bbR>canvasR){nh=nw/canvasR;}else{nw=nh*canvasR;}
  vb.x=cx-nw/2;vb.y=cy-nh/2;vb.width=nw;vb.height=nh;
}
function selectSearchResult(r){
  searchResults.classList.remove('open');searchInput.value='';clearActive();didPan=false;
  var svg=getSvg();if(!svg)return;
  if(r.type==='section'){
    var el=svg.querySelector('.section[data-section="'+r.name+'"]');
    if(el)zoomToElement(el);
  }else if(r.type==='comp'){
    var cref=r.ref||r.name;
    var el=svg.querySelector('.component[data-ref="'+cref+'"]');
    if(el){el.classList.add('comp-active');zoomToElement(el);el.dispatchEvent(new MouseEvent('click',{bubbles:true}));}
  }else if(r.type==='pin'){
    var el=svg.querySelector('.component[data-ref="'+r.ref+'"]');
    if(el){el.classList.add('comp-active');zoomToElement(el);el.dispatchEvent(new MouseEvent('click',{bubbles:true}));}
  }else{
    svg.querySelectorAll('.net[data-net="'+r.name+'"]').forEach(function(el){el.classList.add('net-active');});
    var first=svg.querySelector('.net[data-net="'+r.name+'"]');
    if(first){zoomToElement(first);first.dispatchEvent(new MouseEvent('click',{bubbles:true}));}
  }
}
searchInput.addEventListener('blur',function(){setTimeout(function(){searchResults.classList.remove('open');},200);});
document.addEventListener('keydown',function(e){if((e.ctrlKey||e.metaKey)&&e.key==='f'){e.preventDefault();searchInput.focus();searchInput.select();}});

/* Footprint warnings */
function addFpWarnings(){
  var svg=getSvg();if(!svg)return;
  svg.querySelectorAll('.fp-warn').forEach(function(el){el.remove();});
  for(var ref in COMPONENTS){
    var info=COMPONENTS[ref];
    if(info.fpOk)continue;
    var els=svg.querySelectorAll('.component[data-ref="'+ref+'"]');
    els.forEach(function(el){
      var bb=el.getBBox();if(!bb||bb.width===0)return;
      var g=document.createElementNS('http://www.w3.org/2000/svg','g');
      g.setAttribute('class','fp-warn');
      var tx=bb.x+bb.width-4,ty=bb.y+2;
      g.setAttribute('transform','translate('+tx+','+ty+')');
      var tri=document.createElementNS('http://www.w3.org/2000/svg','polygon');
      tri.setAttribute('points','6,0 12,10 0,10');
      tri.setAttribute('fill','#f59e0b');tri.setAttribute('stroke','#92400e');tri.setAttribute('stroke-width','0.5');
      var txt=document.createElementNS('http://www.w3.org/2000/svg','text');
      txt.setAttribute('x','6');txt.setAttribute('y','9.5');
      txt.setAttribute('text-anchor','middle');txt.setAttribute('font-size','8');
      txt.setAttribute('font-weight','bold');txt.setAttribute('fill','#451a03');
      txt.textContent='!';
      var title=document.createElementNS('http://www.w3.org/2000/svg','title');
      title.textContent='Footprint "'+info.footprint+'" has no pad data';
      g.appendChild(title);g.appendChild(tri);g.appendChild(txt);
      el.appendChild(g);
    });
  }
}
addFpWarnings();

/* Live update polling */
var liveV=0;
setInterval(function(){
  fetch('/api/version/'+DESIGN_NAME).then(function(r){return r.json();}).then(function(d){
    if(d.version>liveV){liveV=d.version;
      fetch('/api/svg/'+DESIGN_NAME).then(function(r){return r.text();}).then(function(s){
        var oldSvg=getSvg();
        var tmp=document.createElement('div');tmp.innerHTML=s;
        var newSvg=tmp.querySelector('svg');
        if(newSvg&&oldSvg){
          var oldVb=oldSvg.viewBox.baseVal;
          var saved={x:oldVb.x,y:oldVb.y,w:oldVb.width,h:oldVb.height};
          oldSvg.parentNode.replaceChild(newSvg,oldSvg);
          var vb=newSvg.viewBox.baseVal;vb.x=saved.x;vb.y=saved.y;vb.width=saved.w;vb.height=saved.h;
          addFpWarnings();
        }
      });
    }
  }).catch(function(){});
},500);

/* Block Diagram toggle */
var blockBtn=document.getElementById('block-diagram-btn');
var blockMode=false;var savedSvg=null;
if(blockBtn)blockBtn.addEventListener('click',function(){
  if(blockMode){
    blockMode=false;blockBtn.textContent='Block Diagram';
    if(savedSvg){var c=document.getElementById('schematic-canvas');
    var old=c.querySelector('svg');if(old)c.removeChild(old);
    c.insertAdjacentHTML('beforeend',savedSvg);savedSvg=null;}
  }else{
    blockBtn.textContent='Loading...';blockBtn.disabled=true;
    fetch('/api/block-diagram/'+DESIGN_NAME).then(function(r){return r.text();}).then(function(svg){
      var c=document.getElementById('schematic-canvas');
      var old=c.querySelector('svg');
      if(old){savedSvg=old.outerHTML;c.removeChild(old);}
      c.insertAdjacentHTML('beforeend',svg);
      blockMode=true;blockBtn.textContent='Schematic';blockBtn.disabled=false;
    }).catch(function(e){
      alert('Block diagram failed: '+e.message);
      blockBtn.textContent='Block Diagram';blockBtn.disabled=false;
    });
  }
});

}catch(err){console.error('EDA JS error:',err);document.title='JS ERROR: '+err.message;}})();

