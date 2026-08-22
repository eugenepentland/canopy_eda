#!/usr/bin/env node
// pcb_viewer_bench runner — concatenates prelude + the real viewer assets +
// bench tail into one Node script (everything shares module scope, exactly as
// the browser shares one page scope), injects the __B introspection hook just
// before pcb_board.js's final IIFE closer, and runs it.
//
//   node scripts/pcb_viewer_bench/run.js <pcb_blob.json|pcb_page.html> [assets_dir] [out.js]
//
// The input is either the page's inline `const PCB={...}` JSON or a saved
// /pcb-layout/<design> page containing it. Assets default to src/serve/assets next
// to this script's repo checkout, so the bench always measures the working
// tree's viewer code.
const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

const blob = process.argv[2];
if (!blob || !fs.existsSync(blob)) {
  console.error("usage: run.js <pcb_blob.json> [assets_dir] [out.js]");
  process.exit(2);
}
const here = __dirname;
const assets = process.argv[3] || path.join(here, "..", "..", "src", "serve", "assets");
const out = process.argv[4] || path.join(require("os").tmpdir(), "pcb_viewer_bench_combined.js");

const read = (p) => fs.readFileSync(p, "utf8");
let board = read(path.join(assets, "pcb_board.js"));

// Hook: expose the file-scope internals the bench drives. Injected before the
// LAST `})();` — the main IIFE's closer — so every name resolves in scope.
const HOOK = `
;globalThis.__B={
 scenePaint:function(){scenePaint();},
 dragSet:function(v){drag=v;},gdragSet:function(v){gdrag=v;},
 gdragGet:function(){return typeof gdrag!=="undefined"?gdrag:null;},
 XW:function(v){return X(v);},YW:function(v){return Y(v);},GGet:function(){return G;},
 snapAllFn:function(){return snapAll();},partLoopsGet:function(){return partLoops;},
 grpsGet:function(){return GRPS;},grpOfFn:function(r){return grpOf(r);},
 wptFn:function(i,x,y){return wpt(i,x,y);},
 gateSet:function(inst){drcGate.inst=inst;drcGate.mem=inst.exports.memory;drcGate.ready=true;drcGate.failed=false;},
 gateScopeFn:function(bt,bv,at,av){return drcGateScope(bt,bv,at,av);},
 gateDiffFn:function(bt,bv,at,av){return drcGateDiffBlocks(bt,bv,at,av);},
 gateFullDiffFn:function(bt,bv,at,av){var bc=drcBlockCounts(drcGateRun(bt,bv,P)),ac=drcBlockCounts(drcGateRun(at,av,P));
  for(var id in ac)if(ac[id]>(bc[id]||0))return true;return false;},
 setVB:function(){setVB();},
 zoomAt:function(x,y,f){zoomAt(x,y,f);},
 fitVB:function(){fitVB();},
 mm:function(ev){return mm(ev);},
 vbGet:function(){return vb;},
 quiet:function(){vbQuiet=0;},
 svg:svg,
 CTX:function(){return CTX;},
 viewSt:viewSt,
 keepoutDrop:function(){if(typeof keepoutGeomDrop==="function")keepoutGeomDrop();},
 outlineFilletBuildsGet:function(){return outlineFilletBuilds;},
 netClassInfo:function(n){return netClassInfo(n);},
 linksRecompute:function(){linksDirty=true;linksRecompute();},
 passes:{
  pours:function(c,k){paintPours(c,k);},
  tracks:function(c){paintTracks(c);},
  parts:function(c,k){paintParts(c,k);},
  links:function(c){paintLinks(c);},
  padLabels:function(c,k){paintPadLabels(c,k);},
  grid:function(c,k){paintGridDots(c,k);},
  texts:function(c){paintTexts(c);},
  keepout:function(c,k){paintKeepouts(c,k);}
 }
};
`;
const closer = board.lastIndexOf("})();");
if (closer < 0) { console.error("run.js: no IIFE closer found in pcb_board.js"); process.exit(2); }
board = board.slice(0, closer) + HOOK + board.slice(closer);

const combined = [
  read(path.join(here, "prelude.js")),
  read(path.join(assets, "footprint_svg.js")),
  read(path.join(assets, "drc_marshal.js")),
  board,
  read(path.join(here, "bench_tail.js")),
].join("\n;\n");

fs.writeFileSync(out, combined);
const r = spawnSync(process.execPath, [out], {
  env: Object.assign({}, process.env, { PCB_BLOB: blob }),
  encoding: "utf8", timeout: 300000,
});
if (r.stderr) process.stderr.write(r.stderr);
process.stdout.write(r.stdout || "");
process.exit(r.status === null ? 1 : r.status);
