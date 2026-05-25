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
  // "show preview" chip (standalone footprint cards) to expand an inline SVG
  // drawn by /api/footprint/:name from lib/footprints/<fp>.sexp. The SVG is
  // fetched once per tag, then cached in the panel for subsequent toggles.
  function loadFootprint(box,fp){
    if(box.dataset.loaded==='1')return;
    box.dataset.loaded='1';
    box.innerHTML='<span class="fp-empty">Loading preview…</span>';
    fetch('/api/footprint/'+encodeURIComponent(fp)).then(function(r){
      if(!r.ok)throw new Error('no preview');
      return r.text();
    }).then(function(svg){
      if(svg.indexOf('<svg')===-1)throw new Error('not svg');
      box.innerHTML=svg;
      var s=box.querySelector('svg');
      if(s){s.style.width='100%';s.style.height='auto';s.style.maxHeight='240px';s.style.display='block';}
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
  var card=(e.target&&e.target.closest)?e.target.closest('.comp-card[data-component]'):null;
  if(card!==dragCard){clearDragCard();dragCard=card;if(card)card.classList.add('drag-over');}
});
document.addEventListener('drop',function(e){
  e.preventDefault();
  dragDepth=0;overlay.classList.remove('active');
  var card=(e.target&&e.target.closest)?e.target.closest('.comp-card[data-component]'):null;
  clearDragCard();
  var files=e.dataTransfer?e.dataTransfer.files:null;
  if(!files||files.length===0)return;
  var f=files[0];
  var n=f.name.toLowerCase();
  // Dropping a PDF on a component card links it to that component.
  if(n.endsWith('.pdf')&&card){linkDatasheet(f,card.getAttribute('data-component'));return;}
  if(n.endsWith('.zip'))uploadZip(f,toast);
  else if(n.endsWith('.pdf'))uploadDatasheet(f);
  else showToast('err','Unsupported file: drop a .zip (component) or .pdf (datasheet)',6000);
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
