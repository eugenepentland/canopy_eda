(function(){
"use strict";
var trigger=document.getElementById("pcb-settings");
if(!trigger||typeof PCB==="undefined")return;

var sections=[
 ["overview","Overview"],["stackup","Stackup"],["rules","Design rules"],
 ["net-classes","Net classes"],["diff-pairs","Differential pairs"],
 ["routing-plan","Placement & routing plan"],["drc-policy","DRC policy"],["source","Source & provenance"]
];
var overlay=null,body=null,subtitle=null,meta=null,loadPromise=null,current="overview",lastFocus=null;

function esc(v){return String(v==null?"":v).replace(/[&<>"']/g,function(c){return {"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c];});}
function mm(v){return typeof v==="number"&&isFinite(v)?(Math.round(v*10000)/10000)+" mm":"—";}
function hz(v){if(!(v>0))return "—";if(v>=1e9)return (v/1e9)+" GHz";if(v>=1e6)return (v/1e6)+" MHz";if(v>=1e3)return (v/1e3)+" kHz";return v+" Hz";}
function badge(label,kind){return '<span class="ds-origin '+esc(kind||"")+'">'+esc(label)+'</span>';}
// The board's PHYSICAL copper stack, derived from the blob's one layer table
// (pcb_layout_page.zig writeLayerTables). `net` on the wire is the poured net;
// `plane` is the accessor this page's stackup table reads.
function stackRows(){return (PCB.layer_table||[]).map(function(r){
 return {i:r.i,l:(typeof r.l==="number")?r.l:null,name:r.name,kind:r.kind||"signal",
  plane:(r.net!=null)?r.net:null,c:r.c,implicit:!!r.implicit};});}
// How many of those rows are ROUTABLE (carry a signal index tracks can use).
function signalRowCount(){var n=0;(PCB.layer_table||[]).forEach(function(r){if(typeof r.l==="number")n++;});return n;}
function card(k,v){return '<div class="ds-card"><span class="k">'+esc(k)+'</span><span class="v">'+esc(v)+'</span></div>';}
function title(name,note){return '<h3 class="ds-title">'+esc(name)+'</h3><p class="ds-note">'+esc(note)+'</p>';}
function hdim(x1,x2,y,label){return '<path class="ds-rg-dim" d="M'+x1+' '+y+'H'+x2+'M'+x1+' '+(y-4)+'V'+(y+4)+'M'+x2+' '+(y-4)+'V'+(y+4)+'"/><text class="ds-rg-label" x="'+((x1+x2)/2)+'" y="'+(y-3)+'">'+esc(label)+'</text>';}
function vdim(x,y1,y2,label){return '<path class="ds-rg-dim" d="M'+x+' '+y1+'V'+y2+'M'+(x-4)+' '+y1+'H'+(x+4)+'M'+(x-4)+' '+y2+'H'+(x+4)+'"/><text class="ds-rg-label ds-rg-label-v" transform="translate('+(x+8)+' '+((y1+y2)/2)+') rotate(-90)">'+esc(label)+'</text>';}
function ruleGraphic(key,name,value,description){var art="";
 if(key==="clearance")art='<rect class="ds-rg-copper" x="18" y="10" width="28" height="31" rx="3"/><rect class="ds-rg-copper" x="86" y="10" width="28" height="31" rx="3"/>'+hdim(46,86,51,value);
 else if(key==="track_width")art='<path class="ds-rg-track" d="M17 30H104"/>'+vdim(115,22,38,value);
 else if(key==="via_dia")art='<circle class="ds-rg-copper" cx="62" cy="27" r="20"/><circle class="ds-rg-hole" cx="62" cy="27" r="8"/>'+hdim(42,82,53,value);
 else if(key==="via_drill")art='<circle class="ds-rg-copper" cx="62" cy="27" r="20"/><circle class="ds-rg-hole" cx="62" cy="27" r="8"/>'+hdim(54,70,53,value);
 else if(key==="min_width")art='<path class="ds-rg-track ds-rg-track-min" d="M17 30H104"/>'+vdim(115,27,33,value);
 else if(key==="min_drill")art='<circle class="ds-rg-copper" cx="62" cy="27" r="19"/><circle class="ds-rg-hole" cx="62" cy="27" r="5"/>'+hdim(57,67,53,value);
 else if(key==="min_annular")art='<circle class="ds-rg-copper" cx="53" cy="28" r="21"/><circle class="ds-rg-hole" cx="53" cy="28" r="10"/><path class="ds-rg-dim" d="M63 28H74M63 24V32M74 24V32"/><text class="ds-rg-label" x="96" y="25">ring</text><text class="ds-rg-label" x="96" y="37">'+esc(value)+'</text>';
 else if(key==="hole_to_hole")art='<circle class="ds-rg-hole" cx="34" cy="26" r="10"/><circle class="ds-rg-hole" cx="90" cy="26" r="10"/>'+hdim(44,80,50,value);
 else if(key==="copper_edge")art='<rect class="ds-rg-board" x="12" y="9" width="108" height="35" rx="2"/><rect class="ds-rg-copper" x="22" y="16" width="69" height="21" rx="3"/>'+hdim(91,120,53,value);
 else if(key==="component_edge")art='<rect class="ds-rg-board" x="12" y="9" width="108" height="35" rx="2"/><rect class="ds-rg-mask" x="28" y="15" width="48" height="23" rx="3"/>'+hdim(12,28,53,value);
 else if(key==="pour_clearance"||key==="pour_clearance_outer")art='<rect class="ds-rg-board" x="12" y="9" width="108" height="35" rx="2"/><path class="ds-rg-pour" fill-rule="evenodd" d="M14 11H118V42H14Z M51 15H79V38H51Z"/><rect class="ds-rg-copper" x="59" y="20" width="12" height="13" rx="2"/>'+hdim(51,59,53,value);
 else if(key==="pour_min_width")art='<path class="ds-rg-pour" d="M18 18H114V42H18Z"/><path class="ds-rg-copper" d="M18 30H114"/><path class="ds-rg-dim" d="M62 24V36M58 24H66M58 36H66"/><text class="ds-rg-label" x="70" y="34">'+esc(value)+'</text>';
 else if(key==="pour_corner_radius")art='<path class="ds-rg-pour" d="M20 42V22Q20 16 26 16H112"/><path class="ds-rg-dim" d="M20 12H26M20 8V16M26 8V16"/><text class="ds-rg-label" x="31" y="12">'+esc(value)+'</text>';
 else if(key==="mask_margin")art='<rect class="ds-rg-board" x="12" y="9" width="108" height="35" rx="2"/><rect class="ds-rg-mask" x="37" y="13" width="58" height="31" rx="5"/><rect class="ds-rg-copper" x="44" y="19" width="44" height="19" rx="3"/>'+hdim(37,44,53,value);
 else if(key==="mask_relief_corner_radius")art='<path class="ds-rg-mask" d="M14 12H82V18Q82 24 88 24H118V42H14Z"/><path class="ds-rg-copper-line" d="M14 33H118"/><path class="ds-rg-dim" d="M82 9V18M82 9H91"/><text class="ds-rg-label" x="96" y="12">'+esc(value)+'</text>';
 else if(key==="mask_web")art='<rect class="ds-rg-board" x="10" y="8" width="112" height="37" rx="2"/><rect class="ds-rg-mask" x="16" y="13" width="39" height="29" rx="5"/><rect class="ds-rg-mask" x="77" y="13" width="39" height="29" rx="5"/><rect class="ds-rg-copper" x="22" y="19" width="27" height="17" rx="3"/><rect class="ds-rg-copper" x="83" y="19" width="27" height="17" rx="3"/>'+hdim(55,77,53,value);
 else art='<rect class="ds-rg-board" x="18" y="18" width="88" height="24" rx="2"/><path class="ds-rg-copper-line" d="M18 18H106M18 42H106"/>'+vdim(116,18,42,value);
 return '<svg class="ds-rule-svg" viewBox="0 0 132 60" role="img" aria-label="'+esc(description)+'"><title>'+esc(name+": "+description)+'</title>'+art+'</svg>';
}
function unique(a){var out=[],seen={};(a||[]).forEach(function(v){v=String(v);if(!seen[v]){seen[v]=1;out.push(v);}});return out;}
function boardNet(n){n=String(n||"");var i=n.indexOf(".");return i<0?n:n.slice(0,i);}
function effectiveOrigin(raw,key,custom){if(custom)return custom;if(raw&&raw[key]>0)return ["authored","authored"];return ["built-in default",""];}
function stackEntry(items,key,value){var found=null;(items||[]).some(function(item){if(item[key]===value){found=item;return true;}return false;});return found;}
function constructionLabel(spec,layers){var total=spec&&spec.construction_thickness;if(!(total>0))return "Not specified";var complete=(spec.copper||[]).length===layers&&(spec.dielectrics||[]).length===Math.max(0,layers-1);return mm(total)+(complete?"":" (partial)");}
function queryUrl(){var u="/api/pcb-settings/"+encodeURIComponent(PCB.name);if(PCB.sub)u+="?sub="+encodeURIComponent(PCB.sub);return u;}

function build(){
 overlay=document.createElement("div");overlay.className="ds-overlay";overlay.hidden=true;
 overlay.innerHTML='<section class="ds-dialog" role="dialog" aria-modal="true" aria-labelledby="ds-heading">'+
  '<header class="ds-head"><h2 id="ds-heading">Design settings</h2><span class="ds-sub"></span><button class="ds-close" aria-label="Close design settings">×</button></header>'+
  '<div class="ds-shell"><nav class="ds-nav" aria-label="Settings sections"></nav><main class="ds-body"></main></div></section>';
 document.body.appendChild(overlay);body=overlay.querySelector(".ds-body");subtitle=overlay.querySelector(".ds-sub");
 var nav=overlay.querySelector(".ds-nav");sections.forEach(function(s){var b=document.createElement("button");b.type="button";b.dataset.section=s[0];b.textContent=s[1];b.addEventListener("click",function(){show(s[0],true);});nav.appendChild(b);});
 overlay.querySelector(".ds-close").addEventListener("click",close);
 overlay.addEventListener("mousedown",function(e){if(e.target===overlay)close();});
 overlay.addEventListener("click",function(e){
  var nb=e.target.closest&&e.target.closest("[data-ds-net]");if(nb){var net=nb.getAttribute("data-ds-net");close();if(window.PCBSelectNet)window.PCBSelectNet(net);return;}
  var lb=e.target.closest&&e.target.closest("[data-ds-layer]");if(lb){var layer=Number(lb.getAttribute("data-ds-layer"));close();if(window.PCBSelectLayer)window.PCBSelectLayer(layer);}
 });
}
function setQuery(section){try{var u=new URL(location.href);u.searchParams.set("settings",section);history.replaceState(null,"",u.pathname+u.search+u.hash);}catch(e){}}
function clearQuery(){try{var u=new URL(location.href);u.searchParams.delete("settings");history.replaceState(null,"",u.pathname+u.search+u.hash);}catch(e){}}
function close(){if(!overlay)return;overlay.hidden=true;clearQuery();if(lastFocus)lastFocus.focus();}
function open(section){if(!overlay)build();lastFocus=document.activeElement;overlay.hidden=false;show(section||"overview",false);overlay.querySelector(".ds-close").focus();}
function load(){if(loadPromise)return loadPromise;body.innerHTML='<div class="ds-loading">Loading design configuration…</div>';
 loadPromise=fetch(queryUrl(),{headers:{accept:"application/json"}}).then(function(r){if(!r.ok)throw new Error("Settings request failed ("+r.status+")");return r.json();}).then(function(j){meta=j;subtitle.textContent=(j.source&&j.source.path)||PCB.name;return j;});
 return loadPromise;
}
function show(section,push){current=section;overlay.querySelectorAll(".ds-nav button").forEach(function(b){b.classList.toggle("active",b.dataset.section===section);});if(push)setQuery(section);
 if(meta){render();return;}load().then(render).catch(function(e){body.innerHTML='<div class="ds-error">'+esc(e.message||"Could not load design settings")+'</div>';});
}
function render(){var fn={overview:overview,stackup:stackup,rules:rules,"net-classes":netClasses,"diff-pairs":diffPairs,"routing-plan":routingPlan,"drc-policy":drcPolicy,source:source};body.innerHTML=(fn[current]||overview)();wireSearch();wireNetClassSync();wireStackupPreset();wirePlaneEditor();wireRuleEditor();wireDrcPolicy();body.scrollTop=0;}

function overview(){
 var board=PCB.board,stack=stackRows(),classes=classGroups();var dims=board?(mm(board.w)+" × "+mm(board.h)):"No board outline";
 var authored=[];if(meta.stackup&&meta.stackup.authored)authored.push("stackup");if(meta.design_rules&&meta.design_rules.authored)authored.push("design rules");if(meta.pcb_plan&&meta.pcb_plan.authored)authored.push("routing plan");if((meta.net_classes||[]).length)authored.push("net classes");
 var h=title("Overview","The effective configuration used by this PCB layout, with source declarations distinguished from inherited and built-in defaults.");
 h+='<div class="ds-cards">'+card("Board",dims)+card("Copper stack",stack.length+" physical / "+signalRowCount()+" routable")+card("Nominal finished",mm((PCB.rules||{}).board_thickness))+card("Construction total",constructionLabel(meta.stackup,stack.length))+card("Net classes",classes.length)+card("Differential pairs",(PCB.diffpairs||[]).length)+card("Layout revision",String(PCB.rev||0))+'</div>';
 h+='<div class="ds-section-h">Configuration coverage</div><table class="ds-table"><tbody>'+
  '<tr><td>Source declarations</td><td>'+(authored.length?esc(authored.join(", ")):"None — tool defaults are in effect")+'</td></tr>'+
  '<tr><td>Design source</td><td><code>'+esc(meta.source&&meta.source.path)+'</code></td></tr>'+
  '<tr><td>KiCad target</td><td><code>'+esc((meta.source&&meta.source.kicad_pcb)||"Not configured")+'</code></td></tr>'+
  '</tbody></table>';
 return h;
}
function planeAssignments(){var out=[];stackRows().forEach(function(l){if(l.plane)out.push({index:l.i,net:l.plane,implicit:l.implicit});});return out;}
function planeLayerOptions(selected){var rows=stackRows(),h="";rows.forEach(function(l){var outer=l.i===1||l.i===rows.length;h+='<option value="'+esc(l.i)+'"'+(l.i===selected?' selected':'')+'>L'+esc(l.i)+' · '+esc(l.name)+(outer?' · outer pour':' · solid inner plane')+'</option>';});return h;}
function planeNetOptions(selected){var names=unique((selected?[selected]:[]).concat(PCB.netnames||[])),h="";if(!names.length)return '<option value="">No board nets</option>';names.forEach(function(n){h+='<option value="'+esc(n)+'"'+(n===selected?' selected':'')+'>'+esc(n)+'</option>';});return h;}
function planeRow(p,editable){var dis=editable?'':' disabled';return '<tr class="ds-plane-row"><td><select class="ds-sel ds-plane-layer" aria-label="Whole-layer copper layer"'+dis+'>'+planeLayerOptions(p.index)+'</select></td><td><select class="ds-sel ds-plane-net" aria-label="Whole-layer copper net"'+dis+'>'+planeNetOptions(p.net)+'</select></td><td class="ds-plane-coverage">Whole board</td><td class="ds-plane-origin">'+badge(p.implicit?'implicit':'authored',p.implicit?'warn':'authored')+'</td><td><button class="ds-linkbtn ds-plane-delete" type="button" aria-label="Delete whole-layer copper assignment"'+dis+'>Delete</button></td></tr>';}
function stackup(){var st=stackRows(),spec=meta.stackup||{},auth=spec.authored,preset=spec.preset||"",editable=!(meta.source&&meta.source.sub)&&!PCB.ro,planes=planeAssignments();var h=title("Stackup","The complete physical construction is shown top-to-bottom. Copper electrical roles remain independent from foil and dielectric fabrication details.");
 h+='<div class="ds-cards">'+card("Copper layers",st.length)+card("Routable layers",signalRowCount())+card("Nominal finished",mm((PCB.rules||{}).board_thickness))+card("Construction total",constructionLabel(spec,st.length))+card("Definition",preset?preset:(auth?"Custom source":"Implicit legacy stack"))+'</div>';
 h+='<div class="ds-section-h">Whole-layer copper</div><p class="ds-note">These assignments fill an entire physical copper layer. Inner assignments become solid planes; outer assignments remain routable and receive a board-wide pour. Saving updates only the stackup electrical roles and keeps its fabrication construction. Existing tracks are retained for review.</p>';
 if(!editable)h+='<div class="ds-plan-banner">'+(PCB.ro?'This layout is read-only.':'Open the parent board to edit its whole-layer copper assignments.')+'</div>';
 h+='<table class="ds-table ds-plane-table"><thead><tr><th>Layer</th><th>Net</th><th>Coverage</th><th>Origin</th><th></th></tr></thead><tbody id="ds-plane-rows">';
 planes.forEach(function(p){h+=planeRow(p,editable);});h+='</tbody></table>';
 if(editable)h+='<div class="ds-plane-actions"><span class="ds-rule-status" id="ds-plane-status">No unsaved changes</span><button class="ds-linkbtn" id="ds-plane-add" type="button">Add whole-layer pour</button><button class="btn" id="ds-plane-save" type="button" disabled>Save plane changes</button></div>';
 h+='<div class="ds-section-h">Fabricator preset catalog</div><p class="ds-note">Choose a supplied construction to generate the source declaration, or keep Custom to author every copper and dielectric interval as before. Plane and pour assignments stay board-specific.</p><div class="ds-preset-controls"><label for="ds-stackup-preset">Construction</label><select id="ds-stackup-preset"><option value="">Custom</option>';
 (spec.presets||[]).forEach(function(p){h+='<option value="'+esc(p.name)+'"'+(p.name===preset?' selected':'')+'>'+esc(p.name)+' · '+esc(p.layers)+' layers · '+esc(mm(p.thickness))+'</option>';});
 h+='</select><button class="btn" id="ds-stackup-copy" type="button">Copy declaration</button></div><pre class="ds-source" id="ds-stackup-snippet"></pre>';
 h+='<table class="ds-table ds-stack-table"><thead><tr><th>Layer</th><th>Material type</th><th>Material / grade</th><th>Thickness</th><th>Electrical function</th><th>Net</th><th>Origin</th><th></th></tr></thead><tbody>';
 st.forEach(function(l){var routable=l.l!=null,outer=(l.i===1||l.i===st.length),kind=l.plane?(routable&&outer?"Routable + copper pour":"Solid plane"):(routable?"Routable signal":"Copper");var copper=stackEntry(spec.copper,"index",l.i);var org=copper?badge("authored","authored"):badge(l.implicit||!auth?"implicit":"not specified","");
  h+='<tr class="ds-copper"><td><span class="ds-layer-index">L'+esc(l.i)+'</span><span class="ds-swatch" style="background:'+esc(l.c)+'"></span><code>'+esc(l.name)+'</code></td><td>Copper</td><td>'+esc(copper&&copper.material||"Copper")+'</td><td>'+esc(copper?mm(copper.thickness):"Not specified")+'</td><td>'+esc(kind)+'</td><td>'+esc(l.plane||"—")+'</td><td>'+org+'</td><td>'+(routable?'<button class="ds-linkbtn" data-ds-layer="'+esc(l.l)+'">Select</button>':'')+'</td></tr>';
  if(l.i<st.length){var dielectric=stackEntry(spec.dielectrics,"after_layer",l.i);var dtype=dielectric?(dielectric.kind==="prepreg"?"Prepreg":"Core"):"Dielectric";h+='<tr class="ds-dielectric"><td><span class="ds-stack-gap">L'+esc(l.i)+' ↔ L'+esc(l.i+1)+'</span></td><td>'+esc(dtype)+'</td><td>'+esc(dielectric?dielectric.material:"Not specified")+'</td><td>'+esc(dielectric?mm(dielectric.thickness):"Not specified")+'</td><td>Dielectric</td><td>—</td><td>'+(dielectric?badge("authored","authored"):badge("not specified",""))+'</td><td></td></tr>';}
 });
 h+='</tbody></table><p class="ds-stack-footnote">Nominal finished thickness is the fabrication target. Construction total is the sum of the authored copper foils and dielectric layers, before fabrication tolerances.</p>';return h;}
function wirePlaneEditor(){var rows=document.getElementById("ds-plane-rows"),add=document.getElementById("ds-plane-add"),save=document.getElementById("ds-plane-save"),status=document.getElementById("ds-plane-status");if(!rows||!add||!save||!status)return;
 function values(){var out=[];rows.querySelectorAll(".ds-plane-row").forEach(function(row){out.push({index:Number(row.querySelector(".ds-plane-layer").value),net:row.querySelector(".ds-plane-net").value});});out.sort(function(a,b){return a.index-b.index;});return out;}
 var initial=JSON.stringify(values());
 function validate(){var vals=values(),used={},bad="";vals.forEach(function(p){if(!(p.index>=1&&p.index<=stackRows().length))bad="Choose a valid copper layer";else if(used[p.index])bad="Each copper layer can have only one whole-layer assignment";else if(!p.net)bad="Choose a net for every assignment";used[p.index]=1;});rows.querySelectorAll(".ds-plane-layer").forEach(function(sel){sel.classList.toggle("bad",vals.filter(function(p){return p.index===Number(sel.value);}).length>1);});var dirty=JSON.stringify(vals)!==initial;save.disabled=!!bad||!dirty;add.disabled=vals.length>=stackRows().length;status.className="ds-rule-status"+(bad?" bad":"");status.textContent=bad||(dirty?(vals.length+" assignment"+(vals.length===1?"":"s")+" ready to save"):"No unsaved changes");}
 rows.addEventListener("change",validate);rows.addEventListener("click",function(e){var del=e.target.closest&&e.target.closest(".ds-plane-delete");if(!del)return;del.closest(".ds-plane-row").remove();validate();});
 add.addEventListener("click",function(){var vals=values(),used={},layer=0;vals.forEach(function(p){used[p.index]=1;});stackRows().some(function(l){if(!used[l.i]){layer=l.i;return true;}return false;});if(!layer)return;var names=PCB.netnames||[],net="";names.some(function(n){if(/gnd|ground/i.test(n)){net=n;return true;}return false;});if(!net&&names.length)net=names[0];rows.insertAdjacentHTML("beforeend",planeRow({index:layer,net:net,implicit:false},true));validate();});
 save.addEventListener("click",function(){var vals=values();save.disabled=true;add.disabled=true;rows.querySelectorAll("select,button").forEach(function(el){el.disabled=true;});status.className="ds-rule-status";status.textContent="Saving and rebuilding…";fetch("/api/stackup-planes/"+encodeURIComponent(PCB.name),{method:"POST",headers:{"content-type":"application/json","accept":"application/json"},body:JSON.stringify({layers:stackRows().length,planes:vals})}).then(function(r){return r.json().catch(function(){return {};}).then(function(j){if(!r.ok)throw new Error(j.error||("Save failed ("+r.status+")"));return j;});}).then(function(){status.textContent="Saved — reloading layout…";location.reload();}).catch(function(e){rows.querySelectorAll("select,button").forEach(function(el){el.disabled=false;});validate();status.className="ds-rule-status bad";status.textContent=e.message||"Could not save whole-layer copper";});});validate();}
function wireStackupPreset(){var select=document.getElementById("ds-stackup-preset"),snippet=document.getElementById("ds-stackup-snippet"),copy=document.getElementById("ds-stackup-copy");if(!select||!snippet)return;function update(){var value=select.value;snippet.textContent=value?'(stackup "'+value+'"\n  (plane 2 "GND")\n  (plane 3 "GND")\n  (pour top "GND"))':'(stackup 4\n  (copper 1 (thickness 0.035))\n  (dielectric 1 prepreg (material "...") (thickness 0.2) (er 4.4))\n  ...)';}select.addEventListener("change",update);if(copy)copy.addEventListener("click",function(){if(navigator.clipboard)navigator.clipboard.writeText(snippet.textContent).then(function(){copy.textContent="Copied";setTimeout(function(){copy.textContent="Copy declaration";},1200);});});update();}
function rules(){var eff=PCB.rules||{},raw=meta.design_rules||{};var rows=[
 ["Copper clearance","clearance","Minimum edge-to-edge space between copper features on different nets."],
 ["Default track width","track_width","Width used for a routed track unless its net class overrides it."],
 ["Via diameter","via_dia","Outside copper diameter of a via pad."],
 ["Via drill","via_drill","Diameter of the drilled hole through a via."],
 ["Via wall copper","via_plating","Minimum finished copper thickness on each plated via barrel wall."],
 ["Minimum track width","min_width","Smallest copper track the fabrication rules permit."],
 ["Minimum drill","min_drill","Smallest finished drilled hole the fabrication rules permit."],
 ["Minimum annular ring","min_annular","Minimum copper left around the edge of a plated drill."],
 ["Hole-to-hole spacing","hole_to_hole","Minimum edge-to-edge space between drilled holes."],
 ["Same-net via spacing","via_to_via","Copper spacing between two vias on the same net; zero uses the net's copper clearance."],
 ["Copper-to-edge","copper_edge","Minimum space from any copper feature to the routed board outline."],
 ["Component-to-edge","component_edge","Minimum space from a component courtyard to the finished board outline; defaults to 0.2 mm. Author a wider value when the assembly process requires one."],
 ["Pour clearance","pour_clearance","Keepout gap an inner-layer plane or pour leaves around copper on another net."],
 ["Outer pour clearance","pour_clearance_outer","Keepout gap a pour on an outer copper face leaves around copper on another net; set together with the pour clearance when the board authors one."],
 ["Pour minimum width","pour_min_width","Remove pour necks narrower than this finished copper width."],
 ["Pour corner radius","pour_corner_radius","Round emitted copper-pour corners by this radius."],
 ["Ground via maximum","ground_via_max","Maximum centre distance from an SMD ground pad to a same-net via reaching a declared ground plane (default 1 mm)."],
 ["Solder-mask margin","mask_margin","Expansion from a copper pad edge to its solder-mask opening."],
 ["RF mask corner radius","mask_relief_corner_radius","Fillet radius where an RF trace's solder-mask opening terminates at a component pad dam."],
 ["Minimum mask web","mask_web","Minimum strip of solder mask left between adjacent openings."],
 ["Finished board thickness","board_thickness","Target overall board thickness after lamination and plating."]
 ];var editable=!(meta.source&&meta.source.sub),h=title("Design rules","Edit board-level values here; Save changes updates the source (design-rules …) form, rebuilds the design, and reloads this layout. A net class can still override copper geometry for its own members.");
 if(!editable)h+='<div class="ds-plan-banner">This is a sub-circuit view. Open the parent board to edit its board-level design rules.</div>';
 h+='<table class="ds-table ds-rule-table"><thead><tr><th>Rule</th><th>What it controls</th><th>Value</th><th>Provenance</th></tr></thead><tbody>';
 rows.forEach(function(r){var key=r[1],v=eff[key],org,canEdit=editable&&key!=="board_thickness"&&key!=="pour_clearance_outer";if(key==="board_thickness")org=(meta.stackup&&meta.stackup.thickness>0)?["authored","authored"]:["fab default",""];else if(key==="pour_clearance"&&!(raw[key]>0))org=["built-in fab default",""];else if(key==="pour_clearance_outer")org=(raw.pour_clearance>0)?["authored","authored"]:["built-in fab default",""];else if(key==="via_to_via"&&!(raw[key]>0)){v=0;org=["clearance fallback",""];}else if(key==="copper_edge"&&!(v>0)){v=eff.clearance;org=["clearance fallback",""];}else org=effectiveOrigin(raw,key);var value=mm(v),control=canEdit?'<label class="ds-rule-input-wrap"><input class="ds-rule-input" data-ds-rule="'+esc(key)+'" data-initial="'+esc(v)+'" type="number" min="0" max="1000" step="0.001" value="'+esc(v)+'"><span>mm</span></label>':esc(value);h+='<tr><td class="ds-rule-name">'+esc(r[0])+'</td><td><div class="ds-rule-meaning">'+ruleGraphic(key,r[0],value,r[2])+'<span class="ds-rule-copy">'+esc(r[2])+'</span></div></td><td class="ds-rule-value">'+control+'</td><td>'+badge(org[0],org[1])+'</td></tr>';});
 h+='</tbody></table>';if(editable)h+='<div class="ds-rule-actions"><span class="ds-rule-status" id="ds-rule-status">No unsaved changes</span><button class="btn" id="ds-rule-save" type="button" disabled>Save changes</button></div>';return h;}
function wireRuleEditor(){var save=document.getElementById("ds-rule-save"),status=document.getElementById("ds-rule-status");if(!save||!status)return;var inputs=[].slice.call(document.querySelectorAll("[data-ds-rule]"));function dirty(){var n=0;inputs.forEach(function(i){var v=Number(i.value),initial=Number(i.getAttribute("data-initial"));i.classList.toggle("bad",!isFinite(v)||v<0||v>1000);if(isFinite(v)&&v!==initial)n++;});var bad=inputs.some(function(i){return i.classList.contains("bad");});save.disabled=!n||bad;status.className="ds-rule-status"+(bad?" bad":"");status.textContent=bad?"Enter values from 0 to 1000 mm":(n?n+" unsaved change"+(n===1?"":"s"):"No unsaved changes");}inputs.forEach(function(i){i.addEventListener("input",dirty);});save.addEventListener("click",function(){var changed={};inputs.forEach(function(i){var v=Number(i.value),initial=Number(i.getAttribute("data-initial"));if(v!==initial)changed[i.getAttribute("data-ds-rule")]=v;});if(changed.via_dia!=null||changed.via_drill!=null){var dia=document.querySelector('[data-ds-rule="via_dia"]'),drill=document.querySelector('[data-ds-rule="via_drill"]');changed.via_dia=Number(dia.value);changed.via_drill=Number(drill.value);if(changed.via_drill>changed.via_dia){status.className="ds-rule-status bad";status.textContent="Via drill cannot exceed via diameter";return;}}save.disabled=true;inputs.forEach(function(i){i.disabled=true;});status.className="ds-rule-status";status.textContent="Saving and rebuilding…";fetch("/api/design-rules/"+encodeURIComponent(PCB.name),{method:"POST",headers:{"content-type":"application/json","accept":"application/json"},body:JSON.stringify({rules:changed})}).then(function(r){return r.json().catch(function(){return {};}).then(function(j){if(!r.ok)throw new Error(j.error||("Save failed ("+r.status+")"));return j;});}).then(function(){status.textContent="Saved — reloading layout…";location.reload();}).catch(function(e){inputs.forEach(function(i){i.disabled=false;});dirty();status.className="ds-rule-status bad";status.textContent=e.message||"Could not save design rules";});});dirty();}
function classGroups(){var map={},order=[];(meta.net_classes||[]).forEach(function(c){var k=c.name;if(!map[k]){map[k]={name:k,auth:c,rows:[],nets:[],sources:[],conflict:false};order.push(k);}});(PCB.netclasses||[]).forEach(function(r){var k=r.class||"Unclassified";if(!map[k]){map[k]={name:k,auth:null,rows:[],nets:[],sources:[],conflict:false};order.push(k);}var g=map[k];g.rows.push(r);g.nets.push(r.net);if(r.source)g.sources.push(r.source);if(r.conflict)g.conflict=true;});order.forEach(function(k){var g=map[k];if(!g.nets.length&&g.auth)g.nets=(g.auth.nets||[]).slice();g.nets=unique(g.nets);g.sources=unique(g.sources);});return order.map(function(k){return map[k];});}
function metric(k,v){return '<div class="ds-metric"><span class="k">'+esc(k)+'</span><span class="v">'+esc(v)+'</span></div>';}
function impedanceLayer(r){var rows=stackRows(),wanted=Number(r.impedance_layer)||0,hit=null;
 if(wanted>0)rows.some(function(x){if(x.i===wanted){hit=x;return true;}return false;});
 if(!hit)rows.some(function(x){if(x.l===0){hit=x;return true;}return false;});
 return hit?("L"+hit.i+" · "+hit.name):"—";}
function impedanceStructure(r){var rows=stackRows(),wanted=Number(r.impedance_layer)||0,hit=null;
 if(wanted>0)rows.some(function(x){if(x.i===wanted){hit=x;return true;}return false;});
 if(!hit)rows.some(function(x){if(x.l===0){hit=x;return true;}return false;});
 if(!hit)return "Unknown";var outer=hit.i===1||hit.i===rows.length;
 if(outer&&Number(r.ground_gap_mm)>0)return "Grounded CPWG";
 return outer?"Microstrip":"Stripline";}
function groundGap(r){var lo=Number(r.ground_gap_mm)||0,hi=Number(r.ground_gap_max_mm)||0;
 if(!(lo>0))return "—";return hi>lo?(mm(lo)+" – "+mm(hi)+" dynamic"):mm(lo);}
function netClassSyncSummary(s){if(!s)return "Copper synchronization is unavailable.";
 if(!s.changed)return "Every routed class member already matches its resolved track and via geometry.";
 return s.tracks+" track"+(s.tracks===1?"":"s")+" and "+s.vias+" via"+(s.vias===1?"":"s")+" differ across "+s.nets+" net"+(s.nets===1?"":"s")+".";}
function netClasses(){var groups=classGroups(),sync=window.PCBNetClassGeometryStatus&&window.PCBNetClassGeometryStatus(),h=title("Net classes","Search by class or net. Expand a class to inspect its effective geometry and click a member net to highlight it on the board.");
 h+='<div class="ds-class-sync"><div><strong>Routed copper</strong><span id="ds-class-sync-status">'+esc(netClassSyncSummary(sync))+'</span><small>Applies resolved widths and via sizes without moving centre lines, then refills current clearance / ground-pour gaps and reruns DRC. The edit is undoable.</small></div><button class="btn" id="ds-class-sync" type="button"'+(!sync||!sync.editable||!sync.changed?' disabled':'')+'>Apply classes to routed copper</button></div>';
 h+='<input class="ds-search" id="ds-class-search" type="search" placeholder="Filter classes or nets…" aria-label="Filter net classes"><div id="ds-class-list">';
 if(!groups.length)return h+'<div class="ds-empty">No authored or resolved net classes.</div></div>';
 groups.forEach(function(g){var r=g.rows[0]||g.auth||{},source=g.sources.length?(g.sources.join(", ")):"board root",origin=g.sources.some(function(s){return !!s;})?["inherited","inherited"]:[g.auth?"authored":"resolved",g.auth?"authored":""];var search=(g.name+" "+g.nets.join(" ")).toLowerCase();
  var target=Number(r.impedance_ohms)>0?(r.impedance_ohms+" Ω single-ended"):(Number(r.diff_impedance_ohms)>0?(r.diff_impedance_ohms+" Ω differential"):"—");
  var band=(Number(r.max_freq_hz)>0)?(hz(r.band_start_hz||r.max_freq_hz/100)+" – "+hz(r.max_freq_hz)):"—";
  var rl=Number(r.return_loss_target_db)>0?Number(r.return_loss_target_db):20;
  h+='<details class="ds-class" data-ds-search="'+esc(search)+'"><summary><span class="ds-class-name">'+esc(g.name)+'</span>'+badge(origin[0],origin[1])+(g.conflict?badge("conflict","warn"):"")+'<span class="ds-class-meta">'+g.nets.length+' nets · '+esc(source)+'</span></summary>';
  if(target!=="—")h+='<div class="ds-class-explain"><strong>'+esc(target)+'</strong><span>The shown width is '+(r.width_derived?'solved from this target':'authored and checked against this target')+' using the physical stackup, copper foil, reference plane, and '+(Number(r.ground_gap_mm)>0?(Number(r.ground_gap_max_mm)>Number(r.ground_gap_mm)?'a ground-pour gap that expands with wider routed sections up to its cap.':'same-layer ground-pour gap.'):'reference geometry.')+'</span></div>';
  h+='<div class="ds-metrics">'+metric("Target impedance",target)+metric("Resolved width",mm(r.width))+metric("Width source",r.width_derived?"derived from target":"authored / default")+metric("Structure",target!=="—"?impedanceStructure(r):"—")+metric("Analysis layer",target!=="—"?impedanceLayer(r):"—")+metric("Ground-pour gap",groundGap(r))+metric("Frequency band",band)+metric("Return-loss target",Number(r.max_freq_hz)>0?(rl+" dB"):"—")+metric("Clearance",mm(r.clearance))+metric("Via",mm(r.via_dia)+" / "+mm(r.via_drill))+metric("Priority",r.priority||0)+metric("Diff-pair gap",r.diff_gap>=0?mm(r.diff_gap):"—")+'</div><div class="ds-members">';
  if(g.nets.length)g.nets.forEach(function(n){h+='<button class="ds-net" data-ds-net="'+esc(boardNet(n))+'">'+esc(n)+'</button>';});else h+='<span class="ds-note">Profile only — no nets are assigned here.</span>';h+='</div></details>';});return h+'</div>';}
function wireSearch(){var q=document.getElementById("ds-class-search");if(!q)return;q.addEventListener("input",function(){var v=q.value.trim().toLowerCase();document.querySelectorAll("[data-ds-search]").forEach(function(e){e.hidden=v&&e.getAttribute("data-ds-search").indexOf(v)<0;});});}
function wireNetClassSync(){var b=document.getElementById("ds-class-sync"),status=document.getElementById("ds-class-sync-status");if(!b||!status||!window.PCBApplyNetClassGeometry)return;
 b.addEventListener("click",function(){var before=window.PCBNetClassGeometryStatus&&window.PCBNetClassGeometryStatus();if(!before||!before.changed)return;
  var after=window.PCBApplyNetClassGeometry();status.textContent="Applied "+before.tracks+" track"+(before.tracks===1?"":"s")+" and "+before.vias+" via"+(before.vias===1?"":"s")+" across "+before.nets+" net"+(before.nets===1?"":"s")+". DRC and pours are refreshing.";
  b.disabled=!after||!after.changed;b.textContent="Applied ✓";});}
function diffPairs(){var pairs=PCB.diffpairs||[],h=title("Differential pairs","Resolved positive/negative net pairs and their target edge-to-edge coupling gap.");if(!pairs.length)return h+'<div class="ds-empty">No differential pairs are configured.</div>';h+='<table class="ds-table"><thead><tr><th>Positive</th><th>Negative</th><th>Gap</th><th></th></tr></thead><tbody>';pairs.forEach(function(p){h+='<tr><td><code>'+esc(p.p)+'</code></td><td><code>'+esc(p.n)+'</code></td><td>'+esc(mm(p.gap))+'</td><td><button class="ds-net" data-ds-net="'+esc(boardNet(p.p))+'">Highlight pair</button></td></tr>';});return h+'</tbody></table>';}
function tags(label,values){var h="";(values||[]).forEach(function(v){h+='<span class="ds-tag">'+esc(label)+': '+esc(v)+'</span>';});return h;}
function wave(w,i,kind){var h='<article class="ds-wave"><div class="ds-wave-h">'+esc(w.name)+' <span class="ds-wave-n">'+esc(kind)+' wave '+(i+1)+(w.rest?' · rest':'')+'</span></div>';if(w.reason)h+='<p>'+esc(w.reason)+'</p>';h+='<div class="ds-tags">'+tags("ref",w.refs)+tags("section",w.sections)+tags("sub-circuit",w.sub_blocks)+tags("class",w.classes)+tags("net class",w.net_classes)+tags("net",w.nets)+tags("prefer",w.preferred_layers)+tags("allow",w.allowed_layers);(w.waypoints||[]).forEach(function(p){h+='<span class="ds-tag">waypoint: '+esc(p.x)+', '+esc(p.y)+' · '+esc(p.layer)+'</span>';});if(w.max_vias!=null)h+='<span class="ds-tag">max vias: '+esc(w.max_vias)+'</span>';if(w.rest)h+='<span class="ds-tag">remaining members</span>';h+='</div></article>';return h;}
function planNetClass(){var m={};(PCB.netclasses||[]).forEach(function(r){if(r&&r.net)m[r.net]=r.class;});return m;}
function slugOf(ref){ref=String(ref||"");var i=ref.indexOf("/");return i<0?null:ref.slice(0,i);}
function placeChips(members){var groups={},order=[],singles=[];(members||[]).forEach(function(ref){var s=slugOf(ref);if(s==null){singles.push(ref);return;}if(!groups[s]){groups[s]=[];order.push(s);}groups[s].push(ref);});var h="";order.forEach(function(s){h+='<span class="ds-tag" title="'+esc(groups[s].join(", "))+'">'+esc(s)+' × '+groups[s].length+'</span>';});singles.forEach(function(ref){h+='<span class="ds-tag">'+esc(ref)+'</span>';});return h;}
function netChips(members,cm){var h="";(members||[]).forEach(function(n){var cls=cm[n];h+='<button class="ds-net" data-ds-net="'+esc(boardNet(n))+'">'+esc(n)+(cls?' · '+esc(cls):"")+'</button>';});return h;}
function count(n,plural){return n+' '+(n===1?plural.slice(0,-1):plural);}
function planMembers(members,label,inner){var n=(members||[]).length;if(!n)return '<div class="ds-plan-empty">No '+esc(label)+' claimed.</div>';return '<details class="ds-plan-mem"><summary>'+esc(count(n,label))+'</summary><div class="ds-members">'+inner+'</div></details>';}
function planPlaceWave(w,i,authored){var h='<article class="ds-wave"><div class="ds-wave-h">'+esc(w.name)+' <span class="ds-wave-n">placement wave '+(i+1)+(w.rest?' · rest':'')+'</span></div>';if(w.reason)h+='<p>'+esc(w.reason)+'</p>';if(authored){var t=tags("ref",authored.refs)+tags("section",authored.sections)+tags("sub-circuit",authored.sub_blocks);if(t)h+='<div class="ds-tags">'+t+'</div>';}return h+planMembers(w.members,"parts",placeChips(w.members))+'</article>';}
function planRouteWave(w,i,authored,cm){var h='<article class="ds-wave"><div class="ds-wave-h">'+esc(w.name)+' <span class="ds-wave-n">routing wave '+(i+1)+(w.rest?' · rest':'')+'</span></div>';if(w.reason)h+='<p>'+esc(w.reason)+'</p>';var t='';if(authored)t+=tags("class",authored.classes)+tags("net class",authored.net_classes)+tags("net",authored.nets);t+=tags("prefer",w.preferred_layers)+tags("allow",w.allowed_layers);(w.waypoints||[]).forEach(function(p){t+='<span class="ds-tag">waypoint: '+esc(p.x)+', '+esc(p.y)+' · '+esc(p.layer)+'</span>';});if(w.max_vias!=null)t+='<span class="ds-tag">max vias: '+esc(w.max_vias)+'</span>';if(t)h+='<div class="ds-tags">'+t+'</div>';return h+planMembers(w.members,"nets",netChips(w.members,cm))+'</article>';}
function planFallback(h,authored){if(!authored.authored)return h+'<div class="ds-empty">No routing plan is available.</div>';h+='<div class="ds-section-h">Placement</div>';(authored.place||[]).forEach(function(w,i){h+=wave(w,i,"placement");});h+='<div class="ds-section-h">Routing</div>';(authored.route||[]).forEach(function(w,i){h+=wave(w,i,"routing");});return h;}
function planWarnings(warnings){if(!(warnings||[]).length)return "";var h='<div class="ds-section-h">Unresolved selectors</div>';warnings.forEach(function(wn){h+='<div class="ds-plan-warn">'+badge(wn.kind,"warn")+'<span>'+esc(wn.message)+'</span></div>';});return h;}
function routingPlan(){var rp=PCB.plan,authored=meta.pcb_plan||{},cm=planNetClass(),isAuth=!!authored.authored;
 var note=isAuth?"The effective placement and routing plan the tool follows, in execution order — your authored (pcb-plan …) waves with the concrete parts and nets they resolve to.":"The effective placement and routing plan the tool follows, in execution order. No (pcb-plan …) is authored, so this is the tool's deterministic default; add one to override the order or layer policy.";
 var h=title("Placement & routing plan",note);
 if(!rp||(!rp.place&&!rp.route))return planFallback(h,authored);
 if(rp.synthesized)h+='<div class="ds-plan-banner">Synthesized default — the tool derives this order from the design. Add a <code>(pcb-plan …)</code> form to control the waves and layer policy.</div>';
 h+=planWarnings(rp.warnings);
 var ap=isAuth?(authored.place||[]):[],ar=isAuth?(authored.route||[]):[];
 h+='<div class="ds-section-h">Placement · '+count((rp.place||[]).length,"waves")+'</div>';if(!(rp.place||[]).length)h+='<div class="ds-empty">No placement waves.</div>';(rp.place||[]).forEach(function(w,i){h+=planPlaceWave(w,i,ap[i]);});
 h+='<div class="ds-section-h">Routing · '+count((rp.route||[]).length,"waves")+'</div>';if(!(rp.route||[]).length)h+='<div class="ds-empty">No routing waves.</div>';(rp.route||[]).forEach(function(w,i){h+=planRouteWave(w,i,ar[i],cm);});
 return h;}
// ── DRC policy ────────────────────────────────────────────────────────────
// Every check is edited here: Error / Warning / Ignored per kind, grouped by
// what the check is about. A deviation from the built-in default POSTs the
// whole override map to /api/pcb-drc-rules/<design>, which persists it in the
// design's sidecar — so the APIs, the fab-readiness gate, and the board view
// all judge the board by the same policy. PCB.drc_kinds is the shared client
// mirror the Route panel's cog menu also reads, so both stay in step.
//
// The SECTIONS come from the server too — PCB.drc_groups, emitted from
// drc_json.drawer_groups, each entry {title, blurb, kinds[]} in display order.
// This file used to carry those six kind-id arrays itself, which meant a kind
// renamed in Zig quietly stopped being sectioned here while its check went on
// firing. Zig now proves that table total at compile time, so a new kind
// cannot reach the board without a section to sit in.
function drcGroups(){return PCB.drc_groups||[];}
var DRC_HELP={
 track_track:"Two tracks on different nets run closer than the clearance rule.",
 track_pad:"A track passes a foreign-net pad closer than the clearance rule.",
 pad_pad:"Two pads on different nets sit closer than the clearance rule.",
 via_track:"A via barrel encroaches on a foreign-net track.",
 via_pad:"A via barrel encroaches on a foreign-net pad.",
 via_via:"Two vias on different nets sit closer than the clearance rule.",
 via_spacing:"Two vias on the SAME net sit closer than the via-to-via rule — a redundant drill beside copper that already changes layer there. Defaults to the net's own clearance; set (design-rules (via-to-via MM)) to police it directly.",
 annular:"A via's copper ring is thinner than the minimum annular ring.",
 pad_annular:"A through-hole pad's copper ring is thinner than the minimum.",
 hole_hole:"Two drilled holes sit closer than the hole-to-hole rule; the drill can break out.",
 min_drill:"A hole is smaller than the smallest drill the fab rules permit.",
 track_width:"A track is narrower than the minimum width the fab rules permit.",
 board_edge:"Copper sits closer to the routed board outline than the edge rule.",
 component_edge:"A component courtyard sits closer to the finished board edge than the component-edge rule. The built-in fabrication minimum is 0.2 mm; assembly services may require a wider authored value.",
 courtyard:"Two component courtyards overlap — the parts collide on assembly.",
 silk_over_pad:"Footprint or board-level silkscreen crosses a pad or component courtyard.",
 diff_uncoupled:"A differential pair runs uncoupled for longer than its budget allows.",
 diff_skew:"The two legs of a differential pair differ in length beyond the skew budget.",
 length_mismatch:"A (match-group ...) bus's routed members differ in length beyond the group's tolerance.",
 sharp_bend:"An RF track turns sharper than its declared maximum frequency tolerates.",
 keepout_violation:"Foreign copper enters an RF net class's advisory same-layer isolation halo.",
 perimeter_keepout:"A component, track, or via enters the fixed perimeter-fence exclusion band. This is a fabrication error by default; only generated fence vias and explicitly allowed nets are admitted.",
 copper_stub:"A trace endpoint stops without reaching a same-net pad, via, trace, or pour.",
 implicit_junction:"Same-net trace copper touches only because its widths overlap; no stored endpoint lands on the other trace centreline. The board conducts, but the route has no explicit junction and must be canonicalized before generated copper is accepted.",
 hairline_gap:"Same-net copper stops 1–20 µm short. It is electrically open and must be bridged; fabrication must not decide whether it conducts.",
 dangling_copper:"A run of copper attached at both ends to one and the same pad — it joins nothing the land does not already join. A re-route deletes it; on a saved board delete it by hand.",
 single_layer_via:"A through-via touches copper on fewer than two layers and is probably a routing artifact.",
 redundant_via:"A non-ground via is bypassed by other same-net copper. The cleanup plan can remove it without splitting any pad, trace, or remaining via component.",
 land_transit:"A net's own copper lies on one of its pads without being aimed at the pad centre — it laps the land rather than terminating on it, and the copper that laps a land carries on into the corridor to the next pin.",
 ground_via_distance:"An SMD ground pad has no same-net through via to its ground plane within the authored (ground-via-max MM) return-path budget.",
 reference_plane_gap:"A fast or explicitly audited trace crosses a split, slot, antipad opening, or missing island in its exact fabricated reference-plane fill.",
 reference_transition:"A signal layer change switches physical reference planes without a nearby same-net stitching via, or a capacitor bridging two different reference nets.",
 loop_area:"Estimated trace length times physical trace-to-reference separation exceeds the net class's authored (return-path (max-loop-area MM2)) budget.",
 bypass_open:"A bypass capacitor's rail pad has no continuous same-face copper path to the exact IC supply pad it is authored to decouple. A remote pour or separate plane drops do not replace this local high-frequency connection.",
 net_open:"A net's copper splits into islands that never join — the connection is missing on the fabbed board."
};
var DRC_ACTIONS=[["err","Error"],["warn","Warning"],["ignore","Ignored"]];
function drcKindIndex(){var m={};(PCB.drc_kinds||[]).forEach(function(k,i){m[k.k]=i;});return m;}
function drcLiveCounts(){var m={};(PCB.drc||[]).forEach(function(d){var k=String(d.k||"");m[k]=(m[k]||0)+1;});return m;}
function drcEffective(k){return k.ov||k.def;}
function drcDirty(){return (PCB.drc_kinds||[]).some(function(k){return k.ov&&k.ov!==k.def;});}
function drcRow(k,i,counts){var eff=drcEffective(k),n=counts[k.label]||0,over=!!(k.ov&&k.ov!==k.def);
 var sel='<select class="ds-sel ds-sel-'+esc(eff)+'" data-ds-drc="'+i+'"'+(PCB.ro?" disabled":"")+' aria-label="Action for '+esc(k.label)+'">';
 DRC_ACTIONS.forEach(function(a){sel+='<option value="'+a[0]+'"'+(a[0]===eff?" selected":"")+'>'+a[1]+(a[0]===k.def?" (default)":"")+'</option>';});
 sel+='</select>';
 var live=eff==="ignore"?'<span class="ds-drc-muted">not reported</span>':(n?'<span class="ds-drc-count'+(eff==="err"?" err":" warn")+'">'+n+'</span>':'<span class="ds-drc-muted">clean</span>');
 return '<tr><td class="ds-rule-name">'+esc(k.label)+'</td><td><span class="ds-rule-copy">'+esc(DRC_HELP[k.k]||"")+'</span></td><td>'+sel+'</td><td>'+live+'</td><td>'+badge(over?"override":"default",over?"warn":"")+'</td></tr>';}
function drcPolicy(){
 var kinds=PCB.drc_kinds||[];
 var h=title("DRC policy","Set what each design-rule check means for this board: an Error blocks the fabrication gate, a Warning is reported but does not block, and Ignored drops the check entirely. Changes save immediately to this design and are honoured by the board view, the APIs, and the fab-readiness gate.");
 if(!kinds.length)return h+'<div class="ds-empty">The DRC rule table is unavailable for this layout.</div>';
 var idx=drcKindIndex(),counts=drcLiveCounts(),tally={err:0,warn:0,ignore:0};
 kinds.forEach(function(k){tally[drcEffective(k)]++;});
 h+='<div class="ds-drc-bar"><div class="ds-cards">'+card("Blocking errors",tally.err)+card("Warnings",tally.warn)+card("Ignored",tally.ignore)+'</div>'+
  '<div class="ds-drc-actions"><span class="ds-drc-status" id="ds-drc-status" role="status"></span>'+
  '<button class="ds-linkbtn" id="ds-drc-reset"'+((PCB.ro||!drcDirty())?" disabled":"")+'>Reset all to defaults</button></div></div>';
 if(PCB.ro)h+='<div class="ds-plan-banner">This layout is open read-only, so the policy cannot be edited here.</div>';
 drcGroups().forEach(function(g){
  var rows="";(g.kinds||[]).forEach(function(key){var i=idx[key];if(i!=null)rows+=drcRow(kinds[i],i,counts);});
  if(!rows)return;
  h+='<div class="ds-section-h">'+esc(g.title)+'</div><p class="ds-note">'+esc(g.blurb)+'</p>'+
   '<table class="ds-table ds-rule-table"><thead><tr><th>Check</th><th>What it catches</th><th>Action</th><th>On this board</th><th>Provenance</th></tr></thead><tbody>'+rows+'</tbody></table>';
 });
 // Any kind the group map does not mention still gets a row, so a newly added
 // check can never become silently uneditable here.
 var seen={};drcGroups().forEach(function(g){(g.kinds||[]).forEach(function(key){seen[key]=1;});});
 var rest="";kinds.forEach(function(k,i){if(!seen[k.k])rest+=drcRow(k,i,counts);});
 if(rest)h+='<div class="ds-section-h">Other checks</div><table class="ds-table ds-rule-table"><thead><tr><th>Check</th><th>What it catches</th><th>Action</th><th>On this board</th><th>Provenance</th></tr></thead><tbody>'+rest+'</tbody></table>';
 return h;
}
function drcStatus(msg,bad){var el=document.getElementById("ds-drc-status");if(!el)return;el.textContent=msg||"";el.classList.toggle("bad",!!bad);}
function drcPost(){
 var ov={};(PCB.drc_kinds||[]).forEach(function(k){if(k.ov&&k.ov!==k.def)ov[k.k]=k.ov;});
 drcStatus("Saving…",false);
 return fetch("/api/pcb-drc-rules/"+encodeURIComponent(PCB.name),{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(ov)})
  .then(function(r){if(!r.ok)throw new Error("save failed ("+r.status+")");return r.json();})
  .then(function(j){
   if(j.kinds)PCB.drc_kinds=j.kinds;
   // Hand the server's authoritative table back to the board so its Route-panel
   // cog menu and the on-board markers re-judge against the same policy.
   if(window.PCBDrcRulesApply)window.PCBDrcRulesApply(PCB.drc_kinds);
   render();drcStatus("Saved",false);
  })
  .catch(function(e){drcStatus(e.message||"Could not save DRC policy",true);});
}
function wireDrcPolicy(){
 var reset=document.getElementById("ds-drc-reset");if(!reset)return;
 body.querySelectorAll("[data-ds-drc]").forEach(function(sel){
  sel.addEventListener("change",function(){
   var k=(PCB.drc_kinds||[])[+sel.getAttribute("data-ds-drc")];if(!k)return;
   k.ov=(sel.value===k.def)?null:sel.value;drcPost();
  });
 });
 reset.addEventListener("click",function(){
  (PCB.drc_kinds||[]).forEach(function(k){k.ov=null;});drcPost();
 });
}
function source(){var s=meta.source||{},rev=meta.revision||{},h=title("Source & provenance","Board-level design rules can be edited in this drawer. Open the schematic for structural source edits, net classes, stackup construction, and routing-plan changes.");h+='<div class="ds-source-row"><span class="k">Design source</span><span class="ds-path">'+esc(s.path||"Unknown")+'</span></div><div class="ds-source-row"><span class="k">KiCad PCB target</span><span class="ds-path">'+esc(s.kicad_pcb||"Not configured")+'</span></div><div class="ds-source-row"><span class="k">Design revision</span><span>'+esc(rev.authored?((rev.id||"—")+(rev.date?" · "+rev.date:"")):"Not authored")+'</span></div><div class="ds-source-row"><span class="k">Layout state revision</span><span>'+esc(PCB.rev||0)+'</span></div><div class="ds-source-row"><span class="k">Scope</span><span>'+esc(s.sub?("sub-circuit "+s.sub):"whole design")+'</span></div><p style="margin-top:16px"><a class="ds-linkbtn" href="/schematics/'+encodeURIComponent(PCB.name)+'">Open schematic / source →</a></p>';return h;}

trigger.addEventListener("click",function(){open("overview");});
document.addEventListener("keydown",function(e){if(e.key==="Escape"&&overlay&&!overlay.hidden){e.preventDefault();close();}});
try{var initial=new URL(location.href).searchParams.get("settings");if(initial&&sections.some(function(s){return s[0]===initial;}))open(initial);}catch(e){}
})();
