(function(){
  var menu=document.querySelector('.kicad-menu');
  var btn=document.getElementById('kicad-btn');
  var panel=document.getElementById('kicad-panel');
  var pathInput=document.getElementById('kicad-path');
  var pcbFileInput=document.getElementById('kicad-pcb-file');
  var shortNetsCb=document.getElementById('kicad-short-nets');
  var status=document.getElementById('kicad-status');
  var saveBtn=document.getElementById('kicad-save-path');
  var writeNet=document.getElementById('kicad-write-netlist');
  var writeKicad=document.getElementById('kicad-write-kicad');
  var updatePcb=document.getElementById('kicad-update-pcb');
  if(!menu) return;
  function setStatus(msg,cls){status.textContent=msg||'';status.className='kicad-status'+(cls?' '+cls:'');}
  btn.addEventListener('click',function(e){e.stopPropagation();menu.classList.toggle('open');});
  panel.addEventListener('click',function(e){e.stopPropagation();});
  document.addEventListener('click',function(){menu.classList.remove('open');});
  fetch('/api/kicad-sync-config/'+SCHEMATIC_SLUG).then(function(r){return r.json();}).then(function(j){
    if(j&&j.output_dir)pathInput.value=j.output_dir;
    if(j&&j.pcb_file)pcbFileInput.value=j.pcb_file;
  }).catch(function(){});
  saveBtn.addEventListener('click',function(){
    setStatus('Saving...');
    fetch('/api/kicad-sync-config/'+SCHEMATIC_SLUG,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({output_dir:pathInput.value.trim(),pcb_file:pcbFileInput.value.trim()})})
      .then(function(r){return r.json();}).then(function(j){setStatus(j.ok?'Settings saved':('Error: '+(j.error||'unknown')),j.ok?'ok':'err');})
      .catch(function(e){setStatus('Error: '+e,'err');});
  });
  function doWrite(url,label){
    if(!pathInput.value.trim()){setStatus('Enter an output path first','err');return;}
    setStatus(label+'...');
    fetch(url,{method:'POST'}).then(function(r){return r.json();}).then(function(j){
      if(!j.ok){setStatus('Error: '+(j.error||'unknown'),'err');return;}
      if(j.netlist&&j.pretty){setStatus('Wrote '+j.netlist+' and '+j.pretty,'ok');}
      else if(j.pcb){setStatus('Updated '+j.pcb,'ok');}
      else if(j.path){setStatus('Wrote '+j.path,'ok');}
      else{setStatus('Done','ok');}
    }).catch(function(e){setStatus('Error: '+e,'err');});
  }
  writeNet.addEventListener('click',function(){doWrite('/api/export-netlist-to-dir/'+SCHEMATIC_SLUG,'Writing netlist');});
  writeKicad.addEventListener('click',function(){doWrite('/api/export-kicad-to-dir/'+SCHEMATIC_SLUG,'Writing netlist + footprints');});
  updatePcb.addEventListener('click',function(){
    var url='/api/update-kicad-pcb/'+SCHEMATIC_SLUG;
    if(shortNetsCb.checked)url+='?short-nets=1';
    setStatus('Updating KiCad PCB...');
    fetch(url,{method:'POST'}).then(function(r){return r.json();}).then(function(j){
      if(!j.ok){
        var msg='Error: '+(j.error||'unknown');
        if(j.preflight)msg+='\n'+j.preflight;
        setStatus(msg,'err');
        return;
      }
      var lines=[];
      if(j.skipped){lines.push('No changes since last sync \u2014 '+j.pcb);}
      else{
        lines.push('Updated '+j.pcb);
        if(j.backup)lines.push('Backup: '+j.backup);
        else if(j.backup===null)lines.push('Backup: (new PCB, none needed)');
        var wf=j.wrote_footprints,wm=j.wrote_models;
        if(wf!==undefined||wm!==undefined){
          var parts=[];
          if(wf!==undefined)parts.push(wf+' footprint(s)');
          if(wm!==undefined)parts.push(wm+' model(s)');
          lines.push('Wrote: '+(parts.length?parts.join(', '):'netlist only'));
        }
      }
      var m=j.mismatches||0,miss=j.missing||0,seeded=j.seeded||0;
      if(seeded>0)lines.push('Replicated module layouts: '+seeded+' component(s) seeded from master instance(s).');
      if(m===0&&miss===0){if(!j.skipped)lines.push('Validation: all checks passed');}
      else lines.push('Validation: '+m+' mismatch(es), '+miss+' missing component(s) \u2014 see '+j.pcb.replace(/\.kicad_pcb$/,'.pcb_diff.json'));
      setStatus(lines.join('\n'),(m===0&&miss===0)?'ok':'warn');
    }).catch(function(e){setStatus('Error: '+e,'err');});
  });
})();
