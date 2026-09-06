#!/usr/bin/env node
// Functional and latency gate. Point only at an isolated test-project server.
'use strict';
const assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path'),os=require('node:os');
const localLib=path.join(os.homedir(),'.local/lib/playwright-chromium/usr/lib/x86_64-linux-gnu');
if(fs.existsSync(localLib))process.env.LD_LIBRARY_PATH=[localLib,process.env.LD_LIBRARY_PATH].filter(Boolean).join(':');
const {chromium}=require('playwright');
async function run(){
  const base=process.argv[2];if(!base)throw new Error('Usage: node scripts/check_package_builder.cjs http://isolated-test-server:PORT');
  const browser=await chromium.launch({headless:true,args:['--use-gl=angle','--use-angle=swiftshader','--enable-unsafe-swiftshader']});
  try{
    const page=await browser.newPage({viewport:{width:1500,height:1000}}),errors=[];
    page.on('pageerror',e=>errors.push(e.message));
    const start=Date.now();await page.goto(base+'/library/package');await page.waitForSelector('#pkg-footprint svg');
    const initialMs=Date.now()-start;assert(initialMs<15000,'Package preview must appear within 15 s');
    const name='browser-package-'+Date.now();
    await page.locator('[data-field="name"]').fill(name);await page.locator('[data-field="name"]').press('Tab');
    await page.locator('[data-field="exposed.enabled"]').check();
    await page.waitForFunction(()=>document.querySelector('#pkg-count').textContent==='25 pads');
    await page.locator('[data-field="dimensions_verified"]').check();
    await page.waitForFunction(()=>!document.querySelector('#pkg-save').disabled);
    await page.locator('#pkg-save').click();await page.waitForFunction(()=>document.querySelector('#pkg-status').textContent.startsWith('Saved footprint'));
    const saved=await page.evaluate(async()=>{const name=document.querySelector('[data-field="name"]').value;return(await fetch('/api/packages/show',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({name})})).json();});
    assert.equal(saved.exposed.enabled,true);assert(saved.revision);
    await page.locator('[data-field="lands.length"]').fill('0.8');await page.locator('[data-field="lands.length"]').press('Tab');
    const editStart=Date.now();await page.waitForFunction(()=>!document.querySelector('#pkg-save').disabled);const editMs=Date.now()-editStart;assert(editMs<10000,'Dimension edits must update the preview within 10 s');
    await page.locator('#pkg-undo').click();assert.equal(await page.locator('[data-field="lands.length"]').inputValue(),'0.75');
    await page.locator('#pkg-units').selectOption('mil');assert(Math.abs(Number(await page.locator('[data-field="body.width"]').inputValue())-157.480315)<.001);
    await page.locator('#pkg-units').selectOption('mm');
    await page.waitForFunction(()=>document.querySelector('#pkg-model-status').textContent.startsWith('STEP solid preview'),{timeout:30000});
    await page.screenshot({path:'/tmp/ic-package-builder.png',fullPage:true});
    // Exercise the precise editor API on the saved package, then verify persistence as an override.
    const edit=await page.evaluate(async(name)=>{
      const data=await(await fetch('/api/footprint/'+name)).json();const p=data.pads[0];
      const response=await fetch('/api/footprint/'+name,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({revision:data.revision,changes:[{index:0,pad:{id:p.id,type:p.type,shape:p.shape,x:p.x,y:p.y,w:.81,h:p.h}}]})});
      return {status:response.status,body:await response.text()};
    },name);
    assert.equal(edit.status,200,edit.body);
    const updated=await page.evaluate(async(name)=>(await(await fetch('/api/packages/show',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({name})})).json()),name);
    assert.equal(updated.overrides.find(o=>o.key==='side-0-0').w,.81);
    assert.equal(updated.overrides.find(o=>o.key==='side-0-0').x,null);
    assert.deepEqual(errors,[]);
    console.log(JSON.stringify({ok:true,initial_ms:initialMs,edit_ms:editMs,name}));
  }finally{await browser.close();}
}
run().catch(e=>{console.error(e);process.exitCode=1;});
