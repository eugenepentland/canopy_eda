(function(){
  var input=document.getElementById('lib-search');
  var rows=Array.prototype.slice.call(document.querySelectorAll('#lib-table tbody tr.comp-row'));
  var info=document.getElementById('count-info');
  var pageInfo=document.getElementById('page-info');
  var prevBtn=document.getElementById('page-prev');
  var nextBtn=document.getElementById('page-next');
  var pager=document.getElementById('pagination');
  var PAGE_SIZE=50;
  var page=0;
  var filtered=rows.slice();
  function reqPanel(tr){var n=tr.nextElementSibling;return(n&&n.classList.contains('req-panel'))?n:null;}
  function render(){
    var total=filtered.length;
    var pages=Math.max(1,Math.ceil(total/PAGE_SIZE));
    if(page>=pages)page=pages-1;
    if(page<0)page=0;
    var start=page*PAGE_SIZE,end=start+PAGE_SIZE;
    for(var i=0;i<rows.length;i++){rows[i].style.display='none';var rp=reqPanel(rows[i]);if(rp)rp.style.display='none';}
    for(var j=start;j<end&&j<total;j++){
      filtered[j].style.display='';
      var rp=reqPanel(filtered[j]);
      if(rp&&filtered[j].classList.contains('open'))rp.style.display='table-row';
    }
    pageInfo.textContent='Page '+(page+1)+' of '+pages;
    prevBtn.disabled=page<=0;
    nextBtn.disabled=page>=pages-1;
    pager.style.display=total>PAGE_SIZE?'':'none';
  }
  function applyFilter(){
    var q=input.value.toLowerCase().trim();
    var terms=q.split(/\s+/);
    filtered=[];
    for(var i=0;i<rows.length;i++){
      var s=rows[i].getAttribute('data-search').toLowerCase();
      var match=true;
      for(var t=0;t<terms.length;t++){if(terms[t]&&s.indexOf(terms[t])<0){match=false;break;}}
      if(match)filtered.push(rows[i]);
    }
    info.textContent=q?(filtered.length+' of '+rows.length+' items'):(rows.length+' items');
    page=0;
    render();
  }
  input.addEventListener('input',applyFilter);
  prevBtn.addEventListener('click',function(){page--;render();});
  nextBtn.addEventListener('click',function(){page++;render();});
  applyFilter();
  // Toggle requirements panel on name click
  document.querySelectorAll('#lib-table .comp-name.has-reqs').forEach(function(td){
    td.addEventListener('click',function(){
      var tr=td.closest('tr');
      var rp=reqPanel(tr);
      if(!rp)return;
      var open=!tr.classList.contains('open');
      tr.classList.toggle('open',open);
      rp.style.display=open?'table-row':'none';
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
document.addEventListener('dragleave',function(e){
  dragDepth--;
  if(dragDepth<=0){dragDepth=0;overlay.classList.remove('active');}
});
document.addEventListener('dragover',function(e){e.preventDefault();});
document.addEventListener('drop',function(e){
  e.preventDefault();
  dragDepth=0;overlay.classList.remove('active');
  var files=e.dataTransfer?e.dataTransfer.files:null;
  if(!files||files.length===0)return;
  var f=files[0];
  if(f.name.toLowerCase().endsWith('.zip'))uploadZip(f,toast);
});
