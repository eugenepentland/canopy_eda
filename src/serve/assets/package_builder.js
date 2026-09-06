/* Datasheet-driven package authoring. Geometry and persistence live in Zig. */
(function () {
  'use strict';
  const $ = id => document.getElementById(id);
  let recipe, baseline = '', undo = [], redo = [], timer, sequence = 0, lastPreview, worker, pendingModel = 0;
  let scene, camera, renderer, controls, modelGroup, padGroup, framed = false;
  const numeric = new Set();
  const fields = [
    ['Body', [['body.width','Width'],['body.length','Length'],['body.height','Overall height'],['body.standoff','Standoff']]],
    ['Terminals', [['leads.pitch','Pitch'],['leads.width','Width'],['leads.length','Contact length'],['leads.thickness','Thickness'],['leads.span_x','Outside span X'],['leads.span_y','Outside span Y']]],
    ['Numbering', [['pins_y','Pins per left/right side','count'],['pins_x','Pins per top/bottom side','count'],['rotation','Pin-1 orientation','rotation'],['clockwise','Clockwise numbering','check']]],
    ['PCB lands', [['lands.mode','Sizing','mode'],['lands.width','Land width'],['lands.length','Land length'],['lands.span_x','Center span X'],['lands.span_y','Center span Y'],['lands.toe','Toe allowance'],['lands.heel','Heel allowance'],['lands.side','Side allowance'],['courtyard','Courtyard clearance']]],
    ['Exposed pad', [['exposed.enabled','Include exposed pad','check'],['exposed.id','Pad number','text'],['exposed.width','Physical width'],['exposed.length','Physical length'],['exposed.land_width','Land width'],['exposed.land_length','Land length'],['exposed.paste_rows','Paste rows','count'],['exposed.paste_columns','Paste columns','count'],['exposed.paste_gap','Paste window gap'],['exposed.paste_margin','Paste edge margin']]]
  ];
  for (const [title, entries] of fields) {
    const section = document.createElement('section'), heading = document.createElement('h2'); heading.textContent = title; section.append(heading);
    for (const [key, label, type] of entries) {
      const row = document.createElement('label'), text = document.createElement('span'); text.textContent = label; row.append(text);
      const input = document.createElement(type === 'mode' || type === 'rotation' ? 'select' : 'input'); input.dataset.field = key;
      if (type === 'mode') for (const [value, title] of [['datasheet','Datasheet lands'],['allowances','Explicit allowances']]) input.add(new Option(title,value));
      else if (type === 'rotation') { for (const n of [0,90,180,270]) input.add(new Option(n+'°',n)); numeric.add(key); }
      else { input.type = type === 'check' ? 'checkbox' : type === 'text' ? 'text' : 'number'; if (input.type === 'number') { input.step = type === 'count' ? '1' : 'any'; numeric.add(key); if (type !== 'count') input.dataset.dimension = '1'; } }
      row.append(input); section.append(row);
    }
    $('pkg-fields').append(section);
  }
  numeric.add('datasheet_page');
  function get(key) { return key.split('.').reduce((v,k) => v[k],recipe); }
  function set(key,value) { const keys = key.split('.'), last = keys.pop(); keys.reduce((v,k) => v[k],recipe)[last] = value; }
  function snapshot() { return JSON.stringify(recipe); }
  function checkpoint() { undo.push(snapshot()); if (undo.length > 100) undo.shift(); redo = []; }
  function status(text,error) { $('pkg-status').textContent = text; $('pkg-status').className = error ? 'error' : ''; }
  function cleanState() { baseline = snapshot(); }
  function factor() { return $('pkg-units').value === 'mil' ? 0.0254 : 1; }
  function sync() {
    document.querySelectorAll('[data-field]').forEach(input => {
      let v = get(input.dataset.field); if (input.type === 'checkbox') input.checked = !!v;
      else { if (input.dataset.dimension) v = Math.round(v/factor()*1e6)/1e6; input.value = v; }
      const k = input.dataset.field;
      input.disabled = (k.startsWith('exposed.') && k !== 'exposed.enabled' && !recipe.exposed.enabled) ||
        (k.startsWith('lands.') && k !== 'lands.mode' && (recipe.lands.mode === 'allowances') !== ['lands.toe','lands.heel','lands.side'].includes(k));
    });
    $('pkg-undo').disabled = !undo.length; $('pkg-redo').disabled = !redo.length;
    const editor = $('pkg-editor'); editor.hidden = !recipe.revision; editor.href = '/library/footprint/'+encodeURIComponent(recipe.name);
    $('pkg-override-json').value = JSON.stringify({overrides:recipe.overrides,additions:recipe.additions,artwork:recipe.artwork},null,2);
    $('pkg-overrides').replaceChildren();
    recipe.overrides.forEach((o,index) => Object.keys(o).filter(k => k !== 'key' && o[k] !== null && o[k] !== false).forEach(key => {
      const row=document.createElement('div'), label=document.createElement('span'), button=document.createElement('button');
      label.textContent=o.key+' · '+key; button.textContent='Reset'; button.onclick=()=>{checkpoint();delete recipe.overrides[index][key];if(Object.keys(recipe.overrides[index]).every(k=>k==='key'||recipe.overrides[index][k]===null||recipe.overrides[index][k]===false))recipe.overrides.splice(index,1);sync();schedule();};row.append(label,button);$('pkg-overrides').append(row);
    }));
  }
  async function api(action,args={}) {
    const response = await fetch('/api/packages/'+action,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(args)});
    const data = await response.json(); if (!response.ok) throw new Error(data.error_message || data.error_code || 'Request failed'); return data;
  }
  function schedule() { sequence++; clearTimeout(timer); $('pkg-save').disabled=true; timer=setTimeout(preview,300); }
  function diagnostics(data) {
    $('pkg-diagnostics').replaceChildren(); document.querySelectorAll('.invalid').forEach(x=>x.classList.remove('invalid'));
    for (const d of data.diagnostics || []) {const p=document.createElement('p');p.className=d.severity;p.textContent=d.field+': '+d.message;$('pkg-diagnostics').append(p);document.querySelectorAll('[data-field]').forEach(x=>{if(x.dataset.field===d.field)x.classList.add('invalid');});}
  }
  async function preview() {
    const id=sequence;
    try {
      const result=await api('preview',{recipe}); if(id!==sequence)return;
      diagnostics(result); $('pkg-save').disabled=!result.ok;lastPreview=result;
      if(!result.ok){status('Resolve the highlighted dimensions before saving.',true);return;}
      const image=document.createElementNS('http://www.w3.org/2000/svg','svg');
      window.FP.drawFootprint(image,result.geometry,{});$('pkg-footprint').replaceChildren(image);
      $('pkg-count').textContent=result.pads.length+' pads';
      status(snapshot()===baseline ? 'Package loaded. Dimensions are in '+$('pkg-units').value+'.' : 'Unsaved changes · footprint and model updated.');
      if(worker){pendingModel=id;const bytes=new TextEncoder().encode(result.step);worker.postMessage({id,buffer:bytes.buffer},[bytes.buffer]);$('pkg-model-status').textContent='Updating STEP model…';}
    } catch(e){if(id===sequence)status(e.message,true);}
  }
  document.querySelectorAll('[data-field]').forEach(input=>input.addEventListener('change',async()=>{
    if(!recipe)return;checkpoint();const key=input.dataset.field;
    if(key==='family') {const old=recipe;recipe=await api('init',{family:input.value,name:old.name});recipe.revision=old.revision;recipe.footprint_hash=old.footprint_hash;recipe.model_hash=old.model_hash;recipe.overrides=old.overrides;recipe.additions=old.additions;recipe.artwork=old.artwork;recipe.datasheet=old.datasheet;recipe.datasheet_page=old.datasheet_page;}
    else {const value=input.type==='checkbox'?input.checked:numeric.has(key)?Number(input.value)*(input.dataset.dimension?factor():1):input.value;set(key,value);if(key!=='dimensions_verified'&&key!=='datasheet'&&key!=='datasheet_page'&&key!=='name')recipe.dimensions_verified=false;}
    sync();schedule();
  }));
  $('pkg-units').onchange=()=>{sync();schedule();};
  $('pkg-undo').onclick=()=>{if(!undo.length)return;redo.push(snapshot());recipe=JSON.parse(undo.pop());sync();schedule();};
  $('pkg-redo').onclick=()=>{if(!redo.length)return;undo.push(snapshot());recipe=JSON.parse(redo.pop());sync();schedule();};
  $('pkg-duplicate').onclick=()=>{checkpoint();recipe.name+='-copy';recipe.revision=null;recipe.footprint_hash='';recipe.model_hash='';sync();schedule();};
  $('pkg-reset').onclick=()=>{checkpoint();recipe.overrides=[];recipe.additions=[];recipe.artwork={courtyard:null,silk:null,fab:null};sync();schedule();};
  $('pkg-apply-overrides').onclick=()=>{try{const value=JSON.parse($('pkg-override-json').value);if(!Array.isArray(value.overrides)||!Array.isArray(value.additions)||!value.artwork)throw new Error('Provide overrides, additions, and artwork.');checkpoint();recipe.overrides=value.overrides;recipe.additions=value.additions;recipe.artwork=value.artwork;sync();schedule();}catch(e){status(e.message,true);}};
  $('pkg-save').onclick=async()=>{
    const sent=snapshot();$('pkg-save').disabled=true;
    try{const data=await api('save',{recipe:JSON.parse(sent),component:$('pkg-component').value.trim()||undefined});if(!data.ok){diagnostics(data);return;}if(snapshot()===sent){recipe=data.recipe;undo=[];redo=[];cleanState();sync();history.replaceState(null,'','?name='+encodeURIComponent(recipe.name));status('Saved footprint, STEP model, and editable recipe.');}else {recipe.revision=data.recipe.revision;status('Saved the previewed version; newer changes remain unsaved.');}}
    catch(e){status(e.message,true);}finally{$('pkg-save').disabled=false;}
  };
  function download(filename,content,type){const url=URL.createObjectURL(new Blob([content],{type})),a=document.createElement('a');a.href=url;a.download=filename;a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);}
  $('pkg-export-step').onclick=()=>{if(lastPreview&&lastPreview.ok)download(recipe.name+'.step',lastPreview.step,'application/step');};
  $('pkg-export-kicad').onclick=async()=>{try{if(!recipe.revision||snapshot()!==baseline)throw new Error('Save the package before exporting its KiCad footprint.');const result=await api('export',{name:recipe.name,format:'kicad'});download(recipe.name+'.kicad_mod',result.content,'text/plain');}catch(e){status(e.message,true);}};
  $('pkg-download').onclick=()=>download(recipe.name+'.json',JSON.stringify(recipe,null,2),'application/json');
  $('pkg-open').onchange=async e=>{try{const file=e.target.files[0];if(!file)return;const loaded=JSON.parse(await file.text());const result=await api('check',{recipe:loaded});if(!result.ok){diagnostics(result);return;}checkpoint();recipe=result.recipe;sync();schedule();}catch(e){status(e.message,true);}};
  $('pkg-pdf-show').onclick=()=>{
    const ref=recipe.datasheet.trim();if(!ref)return;
    let url;if(/^https?:\/\//i.test(ref))url=ref+'#page='+recipe.datasheet_page;else if(!/[\\/]/.test(ref))url='/pdf-view/'+encodeURIComponent(ref)+'?page='+recipe.datasheet_page;else{status('Use a local PDF basename or an HTTP(S) URL.',true);return;}
    $('pkg-pdf').src=url;$('pkg-datasheet-panel').open=true;
  };
  $('pkg-pdf-upload').onchange=async e=>{const file=e.target.files[0];if(!file)return;try{const response=await fetch('/api/upload-datasheet',{method:'POST',headers:{'x-filename':file.name,'Content-Type':'application/pdf'},body:file});const data=await response.json();if(!response.ok||!data.ok)throw new Error(data.error||'PDF upload failed');checkpoint();recipe.datasheet=data.filename||data.name;sync();$('pkg-pdf-show').click();}catch(e){status(e.message,true);}};
  function render(){if(renderer)renderer.render(scene,camera);}
  function clearGroup(group){while(group.children.length){const child=group.children[0];group.remove(child);child.geometry.dispose();child.material.dispose();}}
  function fit(){if(!lastPreview||!renderer)return;const span=Math.max(recipe.body.width,recipe.body.length,recipe.leads.span_x,recipe.leads.span_y);camera.position.set(span,-span,span*.9);controls.target.set(0,0,recipe.body.height/2);controls.update();render();}
  function init3d(){
    try{
      const THREE=window.THREE;scene=new THREE.Scene();scene.background=new THREE.Color(0x101820);camera=new THREE.PerspectiveCamera(40,1,.01,10000);camera.up.set(0,0,1);
      renderer=new THREE.WebGLRenderer({antialias:true});renderer.setPixelRatio(Math.min(devicePixelRatio,2));$('pkg-3d').append(renderer.domElement);
      controls=new THREE.OrbitControls(camera,renderer.domElement);controls.addEventListener('change',render);
      scene.add(new THREE.HemisphereLight(0xffffff,0x384047,2));const light=new THREE.DirectionalLight(0xffffff,2);light.position.set(5,-10,20);scene.add(light);
      modelGroup=new THREE.Group();padGroup=new THREE.Group();scene.add(modelGroup,padGroup);
      new ResizeObserver(()=>{const box=$('pkg-3d');renderer.setSize(box.clientWidth,box.clientHeight);camera.aspect=box.clientWidth/box.clientHeight;camera.updateProjectionMatrix();render();}).observe($('pkg-3d'));
      worker=new Worker('/static/pcb_step_worker.js');worker.onmessage=({data})=>{
        if(data.id!==pendingModel||data.id!==sequence)return;
        if(data.error||!data.result||!data.result.success){$('pkg-model-status').textContent=data.error||'STEP import failed';return;}
        clearGroup(modelGroup);clearGroup(padGroup);
        for(const m of data.result.meshes){const g=new THREE.BufferGeometry();g.setAttribute('position',new THREE.Float32BufferAttribute(m.attributes.position.array,3));if(m.index)g.setIndex(m.index.array);g.computeVertexNormals();const c=m.color||[.4,.4,.4];const isBody=m.name==='Body',transparent=isBody&&$('pkg-transparent').checked;const material=new THREE.MeshStandardMaterial({color:new THREE.Color(...c),metalness:.25,roughness:.6,transparent,opacity:transparent?.3:1});const mesh=new THREE.Mesh(g,material);mesh.userData.body=isBody;modelGroup.add(mesh);}
        for(const p of lastPreview.pads){const mesh=new THREE.Mesh(new THREE.BoxGeometry(p.w,p.h,.008),new THREE.MeshStandardMaterial({color:0xd8ad55}));mesh.position.set(p.x,-p.y,-.006);padGroup.add(mesh);}
        if(!framed){fit();framed=true;}render();$('pkg-model-status').textContent='STEP solid preview · drag to orbit · wheel to zoom';
      };
      worker.onerror=()=>{$('pkg-model-status').textContent='3D worker failed. Footprint and CLI STEP export remain available.';};
    }catch(e){$('pkg-model-status').textContent='3D preview unavailable: '+e.message;}
  }
  $('pkg-fit').onclick=fit;$('pkg-transparent').onchange=()=>{if(!modelGroup)return;modelGroup.children.forEach(m=>{const transparent=m.userData.body&&$('pkg-transparent').checked;m.material.transparent=transparent;m.material.opacity=transparent?.3:1;});render();};
  window.addEventListener('beforeunload',e=>{if(recipe&&snapshot()!==baseline){e.preventDefault();e.returnValue='';}});
  (async()=>{try{const name=new URLSearchParams(location.search).get('name');recipe=await api(name?'show':'init',name?{name}:{family:'qfn'});cleanState();sync();init3d();schedule();}catch(e){status(e.message,true);}})();
})();
