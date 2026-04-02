pub const MODEL_VIEWER_JS =
    \\const wrap=document.getElementById('canvas-wrap');
    \\const renderer=new THREE.WebGLRenderer({antialias:true});
    \\renderer.setPixelRatio(window.devicePixelRatio);
    \\renderer.setClearColor(0x121212);
    \\wrap.appendChild(renderer.domElement);
    \\const scene=new THREE.Scene();
    \\const camera=new THREE.PerspectiveCamera(45,wrap.clientWidth/wrap.clientHeight,0.01,1000);
    \\camera.position.set(0,-5,8);
    \\camera.up.set(0,0,1);
    \\const controls=new OrbitControls(camera,renderer.domElement);
    \\controls.enableDamping=true;
    \\scene.add(new THREE.AmbientLight(0xffffff,0.6));
    \\const dl=new THREE.DirectionalLight(0xffffff,0.8);
    \\dl.position.set(5,-5,10);scene.add(dl);
    \\const dl2=new THREE.DirectionalLight(0xffffff,0.3);
    \\dl2.position.set(-5,5,5);scene.add(dl2);
    \\const grid=new THREE.GridHelper(20,40,0x333333,0x222222);
    \\grid.rotation.x=Math.PI/2;scene.add(grid);
    \\for(const p of PADS){
    \\  const g=new THREE.BoxGeometry(p.w,p.h,0.035);
    \\  const m=new THREE.MeshPhongMaterial({color:0xc4a000,transparent:true,opacity:0.85});
    \\  const mesh=new THREE.Mesh(g,m);
    \\  mesh.position.set(p.x,-p.y,0);
    \\  scene.add(mesh);
    \\}
    \\const silkMat=new THREE.LineBasicMaterial({color:0x888888});
    \\for(const l of SILK_LINES){
    \\  const pts=[new THREE.Vector3(l.x1,-l.y1,0.02),new THREE.Vector3(l.x2,-l.y2,0.02)];
    \\  const g=new THREE.BufferGeometry().setFromPoints(pts);
    \\  scene.add(new THREE.Line(g,silkMat));
    \\}
    \\for(const c of SILK_CIRCLES){
    \\  const curve=new THREE.EllipseCurve(c.cx,-c.cy,c.r,c.r,0,2*Math.PI,false,0);
    \\  const pts=curve.getPoints(32).map(p=>new THREE.Vector3(p.x,p.y,0.02));
    \\  const g=new THREE.BufferGeometry().setFromPoints(pts);
    \\  scene.add(new THREE.Line(g,silkMat));
    \\}
    \\const modelGroup=new THREE.Group();
    \\scene.add(modelGroup);
    \\const oi=id=>document.getElementById(id);
    \\oi('ox').value=CFG.offset[0];oi('oy').value=CFG.offset[1];oi('oz').value=CFG.offset[2];
    \\oi('rx').value=CFG.rotation[0];oi('ry').value=CFG.rotation[1];oi('rz').value=CFG.rotation[2];
    \\function applyTransform(){
    \\  modelGroup.position.set(+oi('ox').value,-(+oi('oy').value),+oi('oz').value);
    \\  modelGroup.rotation.set(+oi('rx').value*Math.PI/180,+oi('ry').value*Math.PI/180,+oi('rz').value*Math.PI/180);
    \\  oi('status').textContent='Unsaved changes';oi('status').style.color='#da6';
    \\}
    \\for(const id of['ox','oy','oz','rx','ry','rz'])oi(id).addEventListener('input',applyTransform);
    \\applyTransform();
    \\oi('reset-btn').onclick=()=>{
    \\  for(const id of['ox','oy','oz','rx','ry','rz'])oi(id).value=0;
    \\  applyTransform();
    \\};
    \\oi('save-btn').onclick=async()=>{
    \\  const body=JSON.stringify({footprint:FOOTPRINT_NAME,
    \\    offset:[+oi('ox').value,+oi('oy').value,+oi('oz').value],
    \\    rotation:[+oi('rx').value,+oi('ry').value,+oi('rz').value]});
    \\  const r=await fetch('/api/model-config',{method:'POST',headers:{'Content-Type':'application/json'},body});
    \\  if(r.ok){oi('status').textContent='Saved';oi('status').style.color='#3fb950';}
    \\  else{oi('status').textContent='Save failed';oi('status').style.color='#f85149';}
    \\};
    \\function onResize(){
    \\  const w=wrap.clientWidth,h=wrap.clientHeight;
    \\  renderer.setSize(w,h);camera.aspect=w/h;camera.updateProjectionMatrix();
    \\}
    \\window.addEventListener('resize',onResize);onResize();
    \\function animate(){requestAnimationFrame(animate);controls.update();renderer.render(scene,camera);}
    \\animate();
    \\async function loadModelFromBuffer(buf){
    \\  while(modelGroup.children.length)modelGroup.remove(modelGroup.children[0]);
    \\  const occt=await occtimportjs();
    \\  const result=occt.ReadStepFile(new Uint8Array(buf),null);
    \\  for(let i=0;i<result.meshes.length;i++){
    \\    const m=result.meshes[i];
    \\    const verts=new Float32Array(m.attributes.position.array);
    \\    const idx=new Uint32Array(m.index.array);
    \\    const g=new THREE.BufferGeometry();
    \\    g.setAttribute('position',new THREE.BufferAttribute(verts,3));
    \\    g.setIndex(new THREE.BufferAttribute(idx,1));
    \\    g.computeVertexNormals();
    \\    let color=0x6688aa;
    \\    if(m.color){color=new THREE.Color(m.color[0]/255,m.color[1]/255,m.color[2]/255);}
    \\    const mat=new THREE.MeshPhongMaterial({color,side:THREE.DoubleSide});
    \\    modelGroup.add(new THREE.Mesh(g,mat));
    \\  }
    \\  applyTransform();
    \\}
    \\async function loadModel(){
    \\  if(!MODEL_FILE){document.getElementById('loading').textContent='No 3D model — drop a .step file to add one';return;}
    \\  try{
    \\    const resp=await fetch('/api/model/'+MODEL_FILE);
    \\    if(!resp.ok)throw new Error('fetch failed');
    \\    await loadModelFromBuffer(await resp.arrayBuffer());
    \\    document.getElementById('loading').remove();
    \\  }catch(e){document.getElementById('loading').textContent='Failed to load model: '+e.message;}
    \\}
    \\loadModel();
    \\const uploadArea=document.getElementById('upload-area');
    \\const uploadStatus=document.getElementById('upload-status');
    \\uploadArea.onclick=()=>document.getElementById('model-file').click();
    \\document.getElementById('model-file').onchange=e=>{if(e.target.files[0])handleModelDrop(e.target.files[0]);};
    \\window.handleModelDrop=async function(file){
    \\  if(!file)return;
    \\  uploadStatus.textContent='Uploading...';uploadStatus.style.color='#888';
    \\  try{
    \\    const buf=await file.arrayBuffer();
    \\    const r=await fetch('/api/upload-model/'+FOOTPRINT_NAME,{method:'POST',headers:{'Content-Type':'application/octet-stream'},body:buf});
    \\    if(!r.ok)throw new Error('upload failed');
    \\    MODEL_FILE=FOOTPRINT_NAME+'.step';
    \\    const el=document.getElementById('loading');if(el)el.textContent='Loading...';
    \\    await loadModelFromBuffer(buf);
    \\    if(el)el.remove();
    \\    uploadStatus.textContent='Model uploaded';uploadStatus.style.color='#3fb950';
    \\  }catch(e){uploadStatus.textContent='Upload failed: '+e.message;uploadStatus.style.color='#f85149';}
    \\};
;
