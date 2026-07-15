(function(){
  var input=document.getElementById('lib-search');
  var cards=Array.prototype.slice.call(document.querySelectorAll('#lib-grid .comp-card'));
  var info=document.getElementById('count-info');
  var pageInfo=document.getElementById('page-info');
  var prevBtn=document.getElementById('page-prev');
  var nextBtn=document.getElementById('page-next');
  var pager=document.getElementById('pagination');
  var PAGE_SIZE=60;
  var page=0;
  var filtered=cards.slice();
  function render(){
    var total=filtered.length;
    var pages=Math.max(1,Math.ceil(total/PAGE_SIZE));
    if(page>=pages)page=pages-1;
    if(page<0)page=0;
    var start=page*PAGE_SIZE,end=start+PAGE_SIZE;
    for(var i=0;i<cards.length;i++)cards[i].style.display='none';
    for(var j=start;j<end&&j<total;j++)filtered[j].style.display='';
    pageInfo.textContent='Page '+(page+1)+' of '+pages;
    prevBtn.disabled=page<=0;
    nextBtn.disabled=page>=pages-1;
    pager.style.display=total>PAGE_SIZE?'':'none';
  }
  function applyFilter(){
    var q=input.value.toLowerCase().trim();
    var terms=q.split(/\s+/);
    filtered=[];
    for(var i=0;i<cards.length;i++){
      var s=cards[i].getAttribute('data-search').toLowerCase();
      var match=true;
      for(var t=0;t<terms.length;t++){if(terms[t]&&s.indexOf(terms[t])<0){match=false;break;}}
      if(match)filtered.push(cards[i]);
    }
    info.textContent=q?(filtered.length+' of '+cards.length+' items'):(cards.length+' items');
    page=0;
    render();
  }
  input.addEventListener('input',applyFilter);
  prevBtn.addEventListener('click',function(){page--;render();});
  nextBtn.addEventListener('click',function(){page++;render();});
  applyFilter();

  // Expand/collapse a card's requirements list.
  document.querySelectorAll('#lib-grid .req-toggle').forEach(function(t){
    t.addEventListener('click',function(){
      var card=t.closest('.comp-card');
      if(card)card.classList.toggle('open');
    });
  });

  // Footprint preview: click the footprint tag (component cards) or the
  // "show preview" chip (standalone footprint cards) to expand an inline SVG.
  // /api/footprint/:name returns a JSON description (lib/footprints/<fp>.sexp);
  // the shared FP engine draws it. Fetched once per tag, cached in the panel.
  function formatMm(value){
    return Number(value).toFixed(3).replace(/\.0+$/,'').replace(/(\.\d*?)0+$/,'$1');
  }
  var courtState=null;
  var COURT_EDGE_IDS=['lib-court-x0','lib-court-y0','lib-court-x1','lib-court-y1'];
  function cn3(value){return Number(value).toFixed(3);}
  function padBBox(data){
    if(!data.pads||!data.pads.length)return null;
    var x0=Infinity,y0=Infinity,x1=-Infinity,y1=-Infinity;
    data.pads.forEach(function(p){
      x0=Math.min(x0,p.x-p.w/2);x1=Math.max(x1,p.x+p.w/2);
      y0=Math.min(y0,p.y-p.h/2);y1=Math.max(y1,p.y+p.h/2);
    });
    return {x0:x0,y0:y0,x1:x1,y1:y1};
  }
  function rawCourtyardBBox(data){
    var ct=data.courtyard||{},x0=Infinity,y0=Infinity,x1=-Infinity,y1=-Infinity;
    (ct.rects||[]).forEach(function(r){
      x0=Math.min(x0,r[0],r[2]);x1=Math.max(x1,r[0],r[2]);
      y0=Math.min(y0,r[1],r[3]);y1=Math.max(y1,r[1],r[3]);
    });
    (ct.circles||[]).forEach(function(c){
      x0=Math.min(x0,c[0]-c[2]);x1=Math.max(x1,c[0]+c[2]);
      y0=Math.min(y0,c[1]-c[2]);y1=Math.max(y1,c[1]+c[2]);
    });
    return Number.isFinite(x0)?{x0:x0,y0:y0,x1:x1,y1:y1}:null;
  }
  function initialCourtBox(data,margin){
    var ct=rawCourtyardBBox(data);
    if(ct)return {x0:ct.x0-margin,y0:ct.y0-margin,x1:ct.x1+margin,y1:ct.y1+margin};
    var pb=padBBox(data);
    if(pb){
      var hw=Math.max(Math.abs(pb.x0),Math.abs(pb.x1))+margin;
      var hh=Math.max(Math.abs(pb.y0),Math.abs(pb.y1))+margin;
      return {x0:-hw,y0:-hh,x1:hw,y1:hh};
    }
    var b=data.bounds||{x:-1,y:-1,w:2,h:2};
    return {x0:b.x-margin,y0:b.y-margin,x1:b.x+b.w+margin,y1:b.y+b.h+margin};
  }
  function gceil(value){var g=courtState.grid;return Math.ceil(value/g-1e-9)*g;}
  function gfloor(value){var g=courtState.grid;return Math.floor(value/g+1e-9)*g;}
  function courtClampX0(value){var c=courtState,lim=c.pb?gfloor(c.pb.x0-c.margin):c.box.x1-c.grid;
    return Math.min(Math.round(value/c.grid)*c.grid,Math.min(lim,c.box.x1-c.grid));}
  function courtClampX1(value){var c=courtState,lim=c.pb?gceil(c.pb.x1+c.margin):c.box.x0+c.grid;
    return Math.max(Math.round(value/c.grid)*c.grid,Math.max(lim,c.box.x0+c.grid));}
  function courtClampY0(value){var c=courtState,lim=c.pb?gfloor(c.pb.y0-c.margin):c.box.y1-c.grid;
    return Math.min(Math.round(value/c.grid)*c.grid,Math.min(lim,c.box.y1-c.grid));}
  function courtClampY1(value){var c=courtState,lim=c.pb?gceil(c.pb.y1+c.margin):c.box.y0+c.grid;
    return Math.max(Math.round(value/c.grid)*c.grid,Math.max(lim,c.box.y0+c.grid));}
  function courtBox(){var c=courtState;
    if(c.mode==='offset'&&c.pb)return {
      x0:gfloor(c.pb.x0-c.offset),y0:gfloor(c.pb.y0-c.offset),
      x1:gceil(c.pb.x1+c.offset),y1:gceil(c.pb.y1+c.offset)
    };
    return {x0:c.box.x0,y0:c.box.y0,x1:c.box.x1,y1:c.box.y1};
  }
  function courtHandles(svg,box,view){
    var t=Math.max(view.w,view.h)/13,w=box.x1-box.x0,h=box.y1-box.y0;
    function strip(x,y,sw,sh,cursor,edge){
      var el=FP.el('rect',{x:cn3(x),y:cn3(y),width:cn3(Math.max(sw,0.01)),height:cn3(Math.max(sh,0.01)),
        fill:'none','pointer-events':'all','data-cedge':edge});
      el.style.cursor=cursor;svg.appendChild(el);
    }
    strip(box.x1-t/2,box.y0+t/2,t,h-t,'ew-resize','e');
    strip(box.x0-t/2,box.y0+t/2,t,h-t,'ew-resize','w');
    strip(box.x0+t/2,box.y1-t/2,w-t,t,'ns-resize','s');
    strip(box.x0+t/2,box.y0-t/2,w-t,t,'ns-resize','n');
    strip(box.x1-t/2,box.y1-t/2,t,t,'nwse-resize','se');
    strip(box.x0-t/2,box.y0-t/2,t,t,'nwse-resize','nw');
    strip(box.x1-t/2,box.y0-t/2,t,t,'nesw-resize','ne');
    strip(box.x0-t/2,box.y1-t/2,t,t,'nesw-resize','sw');
    var cx=(box.x0+box.x1)/2,cy=(box.y0+box.y1)/2;
    [[box.x1,box.y1],[box.x1,box.y0],[box.x0,box.y1],[box.x0,box.y0],
      [box.x1,cy],[box.x0,cy],[cx,box.y1],[cx,box.y0]].forEach(function(p){
      svg.appendChild(FP.el('rect',{x:cn3(p[0]-t/6),y:cn3(p[1]-t/6),width:cn3(t/3),height:cn3(t/3),
        fill:'#58a6ff','pointer-events':'none'}));
    });
  }
  function courtDraw(box){
    var c=courtState,data=c.data,svg=document.getElementById('lib-court-svg');
    var x0=box.x0,y0=box.y0,x1=box.x1,y1=box.y1;
    if(data.bbox){x0=Math.min(x0,data.bbox.x);y0=Math.min(y0,data.bbox.y);
      x1=Math.max(x1,data.bbox.x+data.bbox.w);y1=Math.max(y1,data.bbox.y+data.bbox.h);}
    var pad=Math.max(x1-x0,y1-y0)*0.09+0.3;
    var view=c.view||{x:x0-pad,y:y0-pad,w:x1-x0+2*pad,h:y1-y0+2*pad};
    FP.drawFootprint(svg,{bbox:view,pads:data.pads||[],silk:data.silk,fab:data.fab,courtyard:{}},{bg:false});
    svg.appendChild(FP.el('rect',{x:cn3(box.x0),y:cn3(box.y0),width:cn3(box.x1-box.x0),height:cn3(box.y1-box.y0),
      fill:'none',stroke:'#58a6ff','stroke-width':0.06,'stroke-dasharray':'0.25 0.15'}));
    var tick=Math.max(view.w,view.h)/40;
    svg.appendChild(FP.el('line',{x1:cn3(-tick),y1:0,x2:cn3(tick),y2:0,stroke:'#6e7681','stroke-width':0.04}));
    svg.appendChild(FP.el('line',{x1:0,y1:cn3(-tick),x2:0,y2:cn3(tick),stroke:'#6e7681','stroke-width':0.04}));
    courtHandles(svg,box,view);
  }
  function courtSyncInputs(){
    if(!courtState)return;
    var values=[courtState.box.x0,courtState.box.y0,courtState.box.x1,courtState.box.y1];
    COURT_EDGE_IDS.forEach(function(id,index){document.getElementById(id).value=values[index].toFixed(2);});
  }
  function courtRefresh(){
    if(!courtState)return;
    var b=courtBox(),cx=(b.x0+b.x1)/2,cy=(b.y0+b.y1)/2;
    courtDraw(b);
    document.getElementById('lib-court-full').textContent='full '+(b.x1-b.x0).toFixed(2)+' × '+
      (b.y1-b.y0).toFixed(2)+' mm · centre ('+cx.toFixed(2)+', '+cy.toFixed(2)+')';
  }
  function courtSetMode(mode){
    if(!courtState)return;
    courtState.mode=mode;
    document.getElementById('lib-court-fields-size').hidden=mode!=='size';
    document.getElementById('lib-court-fields-offset').hidden=mode!=='offset';
    courtRefresh();
  }
  function openCourt(fp,data,preview){
    var editor=data.editor||{},margin=Number(editor.margin)||0.15,grid=Number(editor.grid)||0.1;
    courtState={fp:fp,data:data,preview:preview,margin:margin,grid:grid,mode:'size',offset:margin,
      pb:padBBox(data),box:initialCourtBox(data,margin),view:null};
    document.getElementById('lib-court-title').textContent=fp;
    document.getElementById('lib-court-msg').textContent='';
    document.getElementById('lib-court-off').value=margin.toFixed(2);
    document.getElementById('lib-court-save').disabled=false;
    document.querySelectorAll('input[name=lib-court-mode]').forEach(function(radio){
      radio.checked=radio.value==='size';radio.disabled=radio.value==='offset'&&!courtState.pb;
    });
    document.getElementById('lib-court-note').textContent='Drag any edge or corner; edges move independently, snap to the '+
      grid.toFixed(2)+' mm grid, and cannot cut inside the pads. Saving writes a rectangular courtyard to '+
      'lib/footprints/'+fp+'.sexp and affects every component that uses it.';
    courtSyncInputs();courtSetMode('size');
    document.getElementById('lib-court-modal').hidden=false;
  }
  function closeCourt(){document.getElementById('lib-court-modal').hidden=true;courtState=null;}
  function loadFootprint(box,fp){
    if(box.dataset.loaded==='1')return;
    box.dataset.loaded='1';
    box.innerHTML='<span class="fp-empty">Loading preview…</span>';
    fetch('/api/footprint/'+encodeURIComponent(fp)).then(function(r){
      if(!r.ok)throw new Error('no preview');
      return r.json();
    }).then(function(data){
      if(!data||!data.pads)throw new Error('empty');
      var s=FP.el('svg',{});
      FP.drawFootprint(s,data);
      s.style.width='100%';s.style.height='auto';s.style.maxHeight='240px';s.style.display='block';s.style.borderRadius='4px';
      box.innerHTML='';
      var b=data.bounds;
      if(b&&Number.isFinite(Number(b.w))&&Number.isFinite(Number(b.h))){
        var size=document.createElement('div');
        size.className='fp-size';
        size.textContent='Bounding box: X '+formatMm(b.w)+' mm × Y '+formatMm(b.h)+' mm';
        box.appendChild(size);
      }
      var edit=document.createElement('button');
      edit.type='button';edit.className='fp-court-edit';edit.textContent='Edit courtyard';
      edit.addEventListener('click',function(e){e.stopPropagation();openCourt(fp,data,box);});
      box.appendChild(edit);
      box.appendChild(s);
    }).catch(function(){
      box.innerHTML='<span class="fp-empty">No footprint preview available.</span>';
    });
  }
  document.querySelectorAll('#lib-grid .fp-toggle').forEach(function(tag){
    tag.addEventListener('click',function(e){
      e.stopPropagation();
      var fp=tag.dataset.fp;
      var card=tag.closest('.comp-card');
      var box=card&&card.querySelector('.fp-preview');
      if(!box||!fp)return;
      var open=!box.classList.contains('open');
      box.classList.toggle('open',open);
      tag.classList.toggle('fp-toggle-open',open);
      if(open)loadFootprint(box,fp);
    });
  });

  document.getElementById('lib-court-x').addEventListener('click',closeCourt);
  document.getElementById('lib-court-cancel').addEventListener('click',closeCourt);
  document.getElementById('lib-court-modal').addEventListener('click',function(e){if(e.target===this)closeCourt();});
  document.querySelectorAll('input[name=lib-court-mode]').forEach(function(radio){
    radio.addEventListener('change',function(){if(radio.checked)courtSetMode(radio.value);});
  });
  COURT_EDGE_IDS.forEach(function(id,index){
    document.getElementById(id).addEventListener('change',function(){
      if(!courtState)return;
      var value=parseFloat(this.value);
      if(Number.isNaN(value)){courtSyncInputs();return;}
      if(index===0)courtState.box.x0=courtClampX0(value);
      else if(index===1)courtState.box.y0=courtClampY0(value);
      else if(index===2)courtState.box.x1=courtClampX1(value);
      else courtState.box.y1=courtClampY1(value);
      courtSyncInputs();courtRefresh();
    });
  });
  document.getElementById('lib-court-off').addEventListener('change',function(){
    if(!courtState)return;
    var value=parseFloat(this.value);
    if(!(value>=0))value=0;
    value=Math.round(value/0.05)*0.05;courtState.offset=value;this.value=value.toFixed(2);courtRefresh();
  });
  (function(){
    var svg=document.getElementById('lib-court-svg'),drag=null;
    function pointerMm(e){
      var rect=svg.getBoundingClientRect(),view=svg.viewBox.baseVal;
      if(!view||!view.width||!rect.width)return null;
      var scale=Math.min(rect.width/view.width,rect.height/view.height);
      var ox=(rect.width-view.width*scale)/2,oy=(rect.height-view.height*scale)/2;
      return {x:view.x+(e.clientX-rect.left-ox)/scale,y:view.y+(e.clientY-rect.top-oy)/scale};
    }
    svg.addEventListener('pointerdown',function(e){
      var edge=e.target&&e.target.getAttribute&&e.target.getAttribute('data-cedge');
      if(!edge||!courtState)return;
      e.preventDefault();
      if(courtState.mode!=='size'){
        courtState.box=courtBox();
        document.querySelectorAll('input[name=lib-court-mode]').forEach(function(r){r.checked=r.value==='size';});
        courtSetMode('size');courtSyncInputs();
      }
      var view=svg.viewBox.baseVal;
      courtState.view={x:view.x,y:view.y,w:view.width,h:view.height};drag={edge:edge};
      try{svg.setPointerCapture(e.pointerId);}catch(ignore){}
    });
    svg.addEventListener('pointermove',function(e){
      if(!drag||!courtState)return;
      var p=pointerMm(e);if(!p)return;
      if(drag.edge.indexOf('e')>=0)courtState.box.x1=courtClampX1(p.x);
      if(drag.edge.indexOf('w')>=0)courtState.box.x0=courtClampX0(p.x);
      if(drag.edge.indexOf('n')>=0)courtState.box.y0=courtClampY0(p.y);
      if(drag.edge.indexOf('s')>=0)courtState.box.y1=courtClampY1(p.y);
      courtSyncInputs();courtRefresh();
    });
    function endDrag(){if(!drag)return;drag=null;if(courtState){courtState.view=null;courtRefresh();}}
    svg.addEventListener('pointerup',endDrag);svg.addEventListener('pointercancel',endDrag);
  })();
  document.getElementById('lib-court-save').addEventListener('click',function(){
    if(!courtState)return;
    var state=courtState,box=courtBox(),button=this,msg=document.getElementById('lib-court-msg');
    var body=state.mode==='offset'?{fp:state.fp,mode:'offset',offset:state.offset}:
      {fp:state.fp,mode:'rect',x0:box.x0,y0:box.y0,x1:box.x1,y1:box.y1};
    button.disabled=true;msg.style.color='#8b949e';msg.textContent='saving…';
    fetch('/api/library-courtyard/'+encodeURIComponent(state.fp),{method:'POST',
      headers:{'Content-Type':'application/json'},body:JSON.stringify(body)})
      .then(function(response){if(!response.ok)throw new Error('save failed');return response.json();})
      .then(function(){
        msg.style.color='#3fb950';msg.textContent='saved ✓';
        state.preview.dataset.loaded='';loadFootprint(state.preview,state.fp);
        if(typeof showToast==='function')showToast('ok','Courtyard saved for '+state.fp,3500);
        setTimeout(closeCourt,450);
      })
      .catch(function(){button.disabled=false;msg.style.color='#f85149';msg.textContent='save failed';});
  });
})();
var symData=null,fpData=null,stepData=null,symFilename='',fpFilename='',stepFilename='';
function setupDrop(dropId,fileId,nameId,ext,onFile){
  var drop=document.getElementById(dropId),fi=document.getElementById(fileId),nd=document.getElementById(nameId);
  drop.addEventListener('dragover',function(e){e.preventDefault();drop.classList.add('dragover');});
  drop.addEventListener('dragleave',function(){drop.classList.remove('dragover');});
  drop.addEventListener('drop',function(e){e.preventDefault();drop.classList.remove('dragover');if(e.dataTransfer.files.length>0)loadFile(e.dataTransfer.files[0]);});
  fi.addEventListener('change',function(){if(this.files.length>0)loadFile(this.files[0]);});
  function loadFile(f){
    nd.textContent=f.name;
    var r=new FileReader();r.onload=function(){onFile(f.name,r.result);checkReady();};r.readAsArrayBuffer(f);
  }
}
setupDrop('sym-drop','sym-file','sym-name','.kicad_sym',function(n,d){symFilename=n;symData=d;});
setupDrop('fp-drop','fp-file','fp-name','.kicad_mod',function(n,d){fpFilename=n;fpData=d;});
setupDrop('step-drop','step-file','step-name','.step',function(n,d){stepFilename=n;stepData=d;});
var submitBtn=document.getElementById('pkg-submit'),pkgResult=document.getElementById('pkg-result');
function checkReady(){
  var ready=symData&&fpData;
  submitBtn.disabled=!ready;submitBtn.style.opacity=ready?'1':'0.5';
}
submitBtn.addEventListener('click',function(){
  if(!symData||!fpData)return;
  submitBtn.disabled=true;submitBtn.textContent='Creating...';
  pkgResult.className='result';pkgResult.textContent='Uploading and converting...';
  var formData=new FormData();
  formData.append('symbol',new Blob([symData]),symFilename);
  formData.append('footprint',new Blob([fpData]),fpFilename);
  if(stepData)formData.append('step',new Blob([stepData]),stepFilename);
  fetch('/api/upload-package',{method:'POST',body:formData})
    .then(function(r){return r.text().then(function(t){return{ok:r.ok,text:t};});})
    .then(function(d){pkgResult.className=d.ok?'result ok':'result err';pkgResult.textContent=d.text;submitBtn.textContent='Create Package';submitBtn.disabled=false;if(d.ok)setTimeout(function(){location.reload();},1000);})
    .catch(function(e){pkgResult.className='result err';pkgResult.textContent='Error: '+e;submitBtn.textContent='Create Package';submitBtn.disabled=false;});
});
var zipDrop=document.getElementById('zip-drop'),zipFile=document.getElementById('zip-file'),zipName=document.getElementById('zip-name'),zipResult=document.getElementById('zip-result');
var toast=document.getElementById('upload-toast');
zipDrop.addEventListener('dragover',function(e){e.preventDefault();zipDrop.classList.add('dragover');});
zipDrop.addEventListener('dragleave',function(){zipDrop.classList.remove('dragover');});
zipDrop.addEventListener('drop',function(e){e.preventDefault();zipDrop.classList.remove('dragover');if(e.dataTransfer.files.length>0)uploadZip(e.dataTransfer.files[0],zipResult);});
zipFile.addEventListener('change',function(){if(this.files.length>0)uploadZip(this.files[0],zipResult);});
function showToast(cls,msg,autoDismiss){
  toast.className='show '+cls;toast.textContent=msg;
  if(autoDismiss){clearTimeout(toast._t);toast._t=setTimeout(function(){toast.className='';},autoDismiss);}
}
function uploadZip(file,resultEl){
  if(!resultEl)resultEl=zipResult;
  zipName.textContent=file.name;
  var msg='Extracting and converting '+file.name+'...';
  resultEl.className='result';resultEl.textContent=msg;
  if(resultEl!==zipResult)showToast('pending',msg);
  var r=new FileReader();r.onload=function(){
    fetch('/api/upload-zip',{method:'POST',headers:{'Content-Type':'application/octet-stream','X-Filename':file.name},body:r.result})
      .then(function(r){return r.text().then(function(t){return{ok:r.ok,text:t};});})
      .then(function(d){
        resultEl.className=d.ok?'result ok':'result err';resultEl.textContent=d.text;
        showToast(d.ok?'ok':'err',d.text,d.ok?4000:8000);
        if(d.ok)setTimeout(function(){location.reload();},1500);
      })
      .catch(function(e){resultEl.className='result err';resultEl.textContent='Error: '+e;showToast('err','Error: '+e,8000);});
  };r.readAsArrayBuffer(file);
}
function uploadDatasheet(file){
  showToast('pending','Uploading datasheet '+file.name+'...');
  var r=new FileReader();r.onload=function(){
    fetch('/api/upload-datasheet',{method:'POST',headers:{'Content-Type':'application/pdf','X-Filename':file.name},body:r.result})
      .then(function(r){return r.text().then(function(t){return{ok:r.ok,text:t};});})
      .then(function(d){
        var parsed=null;try{parsed=JSON.parse(d.text);}catch(e){}
        var m=d.ok?('Datasheet uploaded: '+((parsed&&parsed.name)||file.name)):((parsed&&parsed.error)||d.text);
        showToast(d.ok?'ok':'err',m,d.ok?4000:8000);
      })
      .catch(function(e){showToast('err','Error: '+e,8000);});
  };r.readAsArrayBuffer(file);
}
// Fetch a part's footprint + datasheet from Component Search Engine by part number.
var csePart=document.getElementById('cse-part'),cseMfr=document.getElementById('cse-mfr'),
    cseSubmit=document.getElementById('cse-submit'),cseResult=document.getElementById('cse-result');
function cseFetch(){
  var pn=(csePart.value||'').trim();
  if(!pn){cseResult.className='result err';cseResult.textContent='Enter a part number.';return;}
  var mfr=(cseMfr.value||'').trim();
  var bodyObj={part_number:pn};if(mfr)bodyObj.manufacturer=mfr;
  var label=cseSubmit.textContent;
  cseSubmit.disabled=true;cseSubmit.textContent='Fetching...';
  cseResult.className='result';cseResult.textContent='Searching Component Search Engine for '+pn+'...';
  showToast('pending','Fetching '+pn+' from CSE...');
  fetch('/api/cse-fetch',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(bodyObj)})
    .then(function(r){return r.text();})
    .then(function(t){
      var d=null;try{d=JSON.parse(t);}catch(e){}
      if(!d){cseResult.className='result err';cseResult.textContent=t||'Empty response';showToast('err','CSE fetch failed',8000);return;}
      var fp=d.footprint,ds=d.datasheet,lines=[];
      if(fp&&fp.ok)lines.push('✓ Footprint: '+fp.component+' (footprint '+fp.footprint+(fp.has_3d_model?' + 3D':'')+')');
      else lines.push('✗ Footprint: '+((fp&&fp.error)||'failed'));
      if(ds&&ds.ok)lines.push('✓ Datasheet: '+ds.file+' (via '+ds.source+')');
      else lines.push('✗ Datasheet: '+((ds&&ds.error)||'failed'));
      if(d.linked)lines.push('✓ Linked datasheet to '+((fp&&fp.component)||'component'));
      else if(fp&&fp.ok&&ds&&ds.ok)lines.push('⚠ Datasheet downloaded but not linked to component');
      // CSE fuzzy-matches: warn loudly when it resolved a different part than asked.
      var resolved=(fp&&fp.part_name)||'';
      var mismatch=resolved&&pn&&resolved.toUpperCase()!==pn.toUpperCase().replace(/\s+/g,'');
      if(mismatch)
        lines.unshift('⚠ CSE had no exact match for "'+pn+'" — imported "'+resolved+'" instead. For the exact part, drag its PDF onto the card.');
      var anyOk=(fp&&fp.ok)||(ds&&ds.ok);
      cseResult.className='result '+(mismatch?'err':(anyOk?'ok':'err'));
      cseResult.textContent=lines.join('\n');
      showToast(mismatch?'err':(anyOk?'ok':'err'),lines.join('  |  '),anyOk?6000:9000);
      // Reload to surface the new card — but not on a mismatch, so the warning stays readable.
      if(anyOk&&!mismatch)setTimeout(function(){location.reload();},2000);
    })
    .catch(function(e){cseResult.className='result err';cseResult.textContent='Error: '+e;showToast('err','Error: '+e,8000);})
    .then(function(){cseSubmit.disabled=false;cseSubmit.textContent=label;});
}
if(cseSubmit){
  cseSubmit.addEventListener('click',cseFetch);
  csePart.addEventListener('keydown',function(e){if(e.key==='Enter')cseFetch();});
  cseMfr.addEventListener('keydown',function(e){if(e.key==='Enter')cseFetch();});
}
// Page-level drag-and-drop: works even when the upload section is collapsed
var overlay=document.getElementById('page-drop-overlay');
var dragDepth=0;
document.addEventListener('dragenter',function(e){
  if(!e.dataTransfer||!e.dataTransfer.types)return;
  var hasFile=Array.prototype.indexOf.call(e.dataTransfer.types,'Files')>=0;
  if(!hasFile)return;
  dragDepth++;
  overlay.classList.add('active');
  e.preventDefault();
});
// Track which component card the pointer is over so a dropped PDF links to it.
var dragCard=null;
function clearDragCard(){if(dragCard){dragCard.classList.remove('drag-over');dragCard=null;}}
document.addEventListener('dragleave',function(e){
  dragDepth--;
  if(dragDepth<=0){dragDepth=0;overlay.classList.remove('active');clearDragCard();}
});
document.addEventListener('dragover',function(e){
  e.preventDefault();
  var card=(e.target&&e.target.closest)?e.target.closest('.comp-card[data-name]'):null;
  if(card!==dragCard){clearDragCard();dragCard=card;if(card)card.classList.add('drag-over');}
});
document.addEventListener('drop',function(e){
  e.preventDefault();
  dragDepth=0;overlay.classList.remove('active');
  var card=(e.target&&e.target.closest)?e.target.closest('.comp-card[data-name]'):null;
  clearDragCard();
  var files=e.dataTransfer?e.dataTransfer.files:null;
  if(!files||files.length===0)return;
  var f=files[0];
  var n=f.name.toLowerCase();
  // Drop a .zip OR a raw .step/.stp on a card → use it as that part's 3D model.
  var isModel=n.endsWith('.zip')||n.endsWith('.step')||n.endsWith('.stp');
  if(isModel&&card){attachModel(f,card.getAttribute('data-name'));return;}
  // Drop a PDF on a component card → link it as that component's datasheet.
  if(n.endsWith('.pdf')&&card&&card.getAttribute('data-component')){linkDatasheet(f,card.getAttribute('data-component'));return;}
  if(n.endsWith('.zip'))uploadZip(f,toast);          // not over a card → import as a new component
  else if(n.endsWith('.pdf'))uploadDatasheet(f);
  else if(n.endsWith('.step')||n.endsWith('.stp'))showToast('err','Drop the .step onto a component or footprint card to use it as that part’s 3D model',6000);
  else showToast('err','Unsupported file: drop a .zip / .step (3D model) or .pdf (datasheet)',6000);
});
// Drop a zip onto a component/footprint card → add or replace its STEP 3D model.
function attachModel(file,name){
  if(file.size>64*1024*1024){showToast('err','Zip too large (64MB limit)',6000);return;}
  showToast('pending','Adding 3D model to '+name+'…');
  var r=new FileReader();
  r.onload=function(){
    fetch('/api/upload-model/'+encodeURIComponent(name),
      {method:'POST',headers:{'Content-Type':'application/octet-stream','X-Filename':file.name},body:r.result})
      .then(function(res){return res.json();})
      .then(function(j){
        if(!j.ok)throw new Error(j.error||'failed');
        showToast('ok','3D model attached to '+(j.footprint||name),3500);
        setTimeout(function(){location.reload();},1200);
      })
      .catch(function(e){showToast('err','Model attach failed: '+e.message,8000);});
  };
  r.readAsArrayBuffer(file);
}
// Delete (×) on a card → soft-delete the library entry (moved to .deleted/).
document.addEventListener('click',function(e){
  var del=(e.target&&e.target.closest)?e.target.closest('.card-del'):null;
  if(!del)return;
  e.stopPropagation();
  var card=del.closest('.comp-card[data-name]');
  if(!card)return;
  var kind=card.getAttribute('data-kind'),name=card.getAttribute('data-name');
  if(!confirm('Delete '+kind+' "'+name+'" from the library?\n\nIt is moved to a .deleted/ folder (recoverable), not erased.'))return;
  fetch('/api/library-delete/'+encodeURIComponent(kind)+'/'+encodeURIComponent(name),{method:'POST'})
    .then(function(res){return res.json();})
    .then(function(j){
      if(!j.ok)throw new Error(j.error||'delete failed');
      card.parentNode.removeChild(card);
      showToast('ok','Deleted '+name,3000);
    })
    .catch(function(e){showToast('err','Delete failed: '+e.message,8000);});
});
// Upload a PDF to lib/datasheets/ then splice (datasheet "...") into the
// component's lib/components/<name>.sexp, then reload to show the new link.
function linkDatasheet(file,component){
  if(file.size>64*1024*1024){showToast('err','PDF too large (64MB limit)',6000);return;}
  showToast('pending','Linking '+file.name+' to '+component+'…');
  var r=new FileReader();
  r.onload=function(){
    fetch('/api/upload-datasheet',{method:'POST',headers:{'Content-Type':'application/pdf','X-Filename':file.name},body:r.result})
      .then(function(res){return res.json();})
      .then(function(j){
        if(!j.ok)throw new Error(j.error||'upload failed');
        return fetch('/api/component-datasheet/'+encodeURIComponent(component)+'/add',
          {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({pdf:j.name})})
          .then(function(r2){return r2.json();});
      })
      .then(function(j){
        if(!j.ok&&j.error!=='DuplicateImport')throw new Error(j.error||'link failed');
        var dup=(j.error==='DuplicateImport');
        showToast('ok',(dup?'Already linked to ':'Linked to ')+component,3500);
        if(!dup)setTimeout(function(){location.reload();},1200);
      })
      .catch(function(e){showToast('err','Link failed: '+e.message,8000);});
  };
  r.readAsArrayBuffer(file);
}
// Attach-datasheet control on component cards: pick an already-uploaded PDF
// (datalist filled lazily from /api/datasheets) and POST /api/attach-datasheet
// to splice (datasheet "…") into the component's .sexp. Idempotent server-side
// — "already linked" comes back as ok with a note.
var dsOptionsLoaded=false;
function loadDsOptions(){
  if(dsOptionsLoaded)return;dsOptionsLoaded=true;
  fetch('/api/datasheets').then(function(r){return r.json();}).then(function(j){
    var dl=document.getElementById('lib-ds-options');if(!dl)return;
    dl.innerHTML=(j.files||[]).map(function(f){
      return '<option value="'+String(f.name).replace(/&/g,'&amp;').replace(/"/g,'&quot;')+'">';
    }).join('');
  }).catch(function(){dsOptionsLoaded=false;});
}
document.addEventListener('click',function(e){
  var tog=(e.target&&e.target.closest)?e.target.closest('.ds-attach-toggle'):null;
  if(tog){
    var row=tog.parentElement.querySelector('.ds-attach-row');
    if(row){row.hidden=!row.hidden;if(!row.hidden){loadDsOptions();var inp=row.querySelector('.ds-attach-input');if(inp)inp.focus();}}
    return;
  }
  var btn=(e.target&&e.target.closest)?e.target.closest('.ds-attach-btn'):null;
  if(!btn)return;
  var card=btn.closest('.comp-card[data-component]');
  var input=btn.parentElement.querySelector('.ds-attach-input');
  var comp=card&&card.getAttribute('data-component');
  var file=input?input.value.trim():'';
  if(!comp){showToast('err','This card has no component definition to attach to',5000);return;}
  if(!file){showToast('err','Pick an uploaded PDF first',4000);return;}
  showToast('pending','Attaching '+file+' to '+comp+'…');
  fetch('/api/attach-datasheet',{method:'POST',headers:{'Content-Type':'application/json'},
    body:JSON.stringify({component:comp,file:file})})
    .then(function(r){return r.json().then(function(j){return {ok:r.ok,j:j};});})
    .then(function(resp){
      if(!resp.ok||!resp.j.ok)throw new Error((resp.j&&resp.j.error)||'attach failed');
      var dup=resp.j.note==='already linked';
      showToast('ok',(dup?'Already linked to ':'Attached to ')+comp,3500);
      if(!dup)setTimeout(function(){location.reload();},1000);
    })
    .catch(function(err){showToast('err','Attach failed: '+err.message,8000);});
});
