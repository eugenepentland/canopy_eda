(function(){
  "use strict";
  const STATUS_LABELS={open:"Use generated",pass:"Pass override",fail:"Fail override",na:"N/A override",needs_info:"Needs info"};
  const $=s=>document.querySelector(s);
  const all=(s,r=document)=>Array.from(r.querySelectorAll(s));
  let state=new Map(),generated=new Map(),sections=[],activeFilter="all",assessmentReady=false;

  function plain(text){
    return text.replace(/\*\*/g,"").replace(/\*/g,"").replace(/\x60/g,"").replace(/\[(.*?)\]\((.*?)\)/g,"$1").trim();
  }
  function severity(text){
    const lower=text.toLowerCase();
    if(lower.includes("critical"))return "critical";
    if(lower.includes("major"))return "major";
    if(lower.includes("minor"))return "minor";
    if(lower.includes("informational"))return "info";
    return "";
  }
  function parseCatalog(source){
    const out=[];let section=null,sub="";
    source.split(/\r?\n/).forEach(line=>{
      let m=/^## Section (\d+)\s+—\s+(.+)$/.exec(line);
      if(m){section={number:m[1],title:plain(m[2]),items:[]};out.push(section);sub="";return}
      m=/^### (.+)$/.exec(line);
      if(m){sub=plain(m[1]);return}
      m=/^- \[ \] \*\*([0-9]+(?:\.[0-9]+)*)\*\*\s+(.+)$/.exec(line);
      if(m&&section)section.items.push({id:m[1],text:plain(m[2]),subgroup:sub,severity:severity(m[2])});
    });
    return out;
  }
  function el(tag,cls,text){
    const node=document.createElement(tag);if(cls)node.className=cls;if(text!==undefined)node.textContent=text;return node;
  }
  function saved(id){return state.get(id)||{id,status:"open",evidence:"",note:"",attempted:"",updated_by:"",updated_at:"",origin:"human"}}
  function machine(id){return generated.get(id)||{id,verdict:"open",method:"agent",applicability:"applies",confidence:0,summary:assessmentReady?"Queued for agent review":"Generated analysis is running…",evidence:"",source:""}}
  function effective(id){
    const review=saved(id),auto=machine(id);
    if(review.status!=="open")return {status:review.status,queue:"none",source:review.origin||"human"};
    if(auto.verdict!=="open")return {status:auto.verdict,queue:"none",source:auto.method};
    return {status:"open",queue:auto.method==="manual"?"manual":"agent",source:auto.method};
  }
  function option(value,label){const o=document.createElement("option");o.value=value;o.textContent=label;return o}
  function machineBadge(auto){
    if(auto.verdict==="pass")return ["static-pass","Static pass"];
    if(auto.verdict==="fail")return ["static-fail","Static fail"];
    if(auto.verdict==="na")return ["static-na","Not applicable"];
    if(auto.method==="manual")return ["manual","Human / measurement"];
    return ["agent","Agent review"];
  }
  function renderItem(item){
    const review=saved(item.id),auto=machine(item.id),eff=effective(item.id),row=el("article","review-item");
    row.dataset.id=item.id;row.dataset.status=eff.status;row.dataset.queue=eff.queue;row.dataset.method=auto.method;
    const main=el("div","item-main"),id=el("span","item-id",item.id),copy=el("div","item-copy"),text=el("div","item-text",item.text);
    copy.append(text);
    const meta=el("div","item-meta");
    if(item.severity)meta.append(el("span","severity "+item.severity,item.severity));
    const [badgeClass,badgeText]=machineBadge(auto);meta.append(el("span","machine-badge "+badgeClass,badgeText));
    if(auto.confidence)meta.append(el("span","confidence",auto.confidence+"% confidence"));
    copy.append(meta);
    const select=el("select","status-select");select.setAttribute("aria-label","Reviewer override for "+item.id);
    Object.entries(STATUS_LABELS).forEach(([value,label])=>select.append(option(value,label)));select.value=review.status;select.disabled=!CAN_WRITE;
    main.append(id,copy,select);row.append(main);

    const generatedBox=el("div","generated-evidence");
    generatedBox.append(el("strong",null,auto.summary));
    if(auto.evidence)generatedBox.append(el("span",null,auto.evidence));
    if(auto.source)generatedBox.append(el("small",null,"Evidence source: "+auto.source));
    row.append(generatedBox);

    const detail=el("details","item-detail"),detailSummary=el("summary",null,"Reviewer / agent override"),editor=el("div","override-editor"),evidence=el("input"),note=el("textarea"),save=el("button",null,"Save override");
    evidence.type="text";evidence.placeholder="Additional evidence: refdes, net, layer, datasheet §/page, or report";evidence.value=review.evidence;evidence.disabled=!CAN_WRITE;
    note.placeholder="Reviewer or agent interpretation";note.value=review.note;note.disabled=!CAN_WRITE;save.disabled=!CAN_WRITE;
    editor.append(evidence,note,save);
    if(review.attempted)editor.append(el("small","attempt-ledger","Agent attempts: "+review.attempted));
    detail.append(detailSummary,editor);row.append(detail);
    const stamp=el("div","item-stamp",review.updated_at?((review.origin==="agent"?"Agent":"Reviewer")+" · "+review.updated_by+" · "+review.updated_at):"No saved override — generated result is authoritative");row.append(stamp);
    const markDirty=()=>{save.textContent="Save override";setSaveState("Unsaved changes")};
    select.addEventListener("change",markDirty);evidence.addEventListener("input",markDirty);note.addEventListener("input",markDirty);
    save.addEventListener("click",async()=>{
      save.disabled=true;save.textContent="Saving…";setSaveState("Saving…");
      try{
        const payload={id:item.id,status:select.value,evidence:evidence.value.trim(),note:note.value.trim()};
        const response=await fetch("/api/board-review/"+encodeURIComponent(DESIGN_NAME),{method:"POST",headers:{"content-type":"application/json","x-netlisp-review":"1"},body:JSON.stringify(payload)});
        const value=await response.json();if(!response.ok)throw new Error(value.error||("HTTP "+response.status));
        state.set(item.id,value.entry);setSaveState("Saved");render();
      }catch(error){save.textContent="Retry";setSaveState("Save failed");alert(error.message)}
    });
    return row;
  }
  function render(){
    const host=$("#checklist");host.replaceChildren();
    sections.forEach(section=>{
      const box=el("details","section-card");box.open=section.number==="1";box.dataset.section=section.number;
      const summary=el("summary"),title=el("h2",null,"Section "+section.number+" — "+section.title),progress=el("span","section-progress");
      summary.append(title,progress);box.append(summary);
      let subgroup="";
      section.items.forEach(item=>{
        if(item.subgroup&&item.subgroup!==subgroup){subgroup=item.subgroup;box.append(el("div","subhead",subgroup))}
        box.append(renderItem(item));
      });
      host.append(box);
    });
    updateProgress();applyFilters();
  }
  function counts(items){
    const c={total:0,open:0,pass:0,fail:0,na:0,needs_info:0,agent:0,manual:0,staticClosed:0};
    items.forEach(item=>{const row=document.querySelector('.review-item[data-id="'+CSS.escape(item.id)+'"]');if(!row)return;c.total++;const status=row.dataset.status||"open";c[status]++;if(row.dataset.queue==="agent")c.agent++;if(row.dataset.queue==="manual")c.manual++;const auto=machine(item.id);if(auto.verdict!=="open")c.staticClosed++});
    return c;
  }
  function updateProgress(){
    const items=sections.flatMap(s=>s.items),c=counts(items),ready=c.pass+c.na,blocked=c.fail+c.needs_info;
    $("#metric-ready").textContent=ready+" / "+c.total;$("#metric-static").textContent=String(c.staticClosed);
    $("#metric-agent").textContent=String(c.agent);$("#metric-manual").textContent=String(c.manual);
    $("#metric-blocked").textContent=String(blocked);$("#metric-open").textContent=String(c.open);
    $("#progress-bar").style.width=(c.total?ready*100/c.total:0)+"%";
    sections.forEach(section=>{const sc=counts(section.items);let label=(sc.pass+sc.na)+" / "+sc.total+" ready";
      if(sc.agent)label+=" · "+sc.agent+" agent";if(sc.manual)label+=" · "+sc.manual+" human";const bad=sc.fail+sc.needs_info;if(bad)label+=" · "+bad+" blocked";
      const node=document.querySelector('.section-card[data-section="'+section.number+'"] .section-progress');if(node)node.textContent=label;
    });
  }
  function searchable(row){return (row.dataset.id+" "+Array.from(row.querySelectorAll(".item-text,.generated-evidence")).map(x=>x.textContent).join(" ")).toLowerCase()}
  function applyFilters(){
    const term=$("#review-search").value.trim().toLowerCase();let visible=0;
    all(".review-item").forEach(row=>{
      const status=row.dataset.status||"open",queue=row.dataset.queue||"none";
      const filter=activeFilter==="all"||(activeFilter==="remaining"?(status!=="pass"&&status!=="na"):activeFilter==="agent"?queue==="agent":activeFilter==="manual"?queue==="manual":activeFilter==="na"?status==="na":status===activeFilter);
      const match=!term||searchable(row).includes(term);row.hidden=!(filter&&match);if(!row.hidden)visible++;
    });
    all(".section-card").forEach(section=>{section.hidden=!all(".review-item",section).some(row=>!row.hidden);if(term&&!section.hidden)section.open=true});
    $("#empty").hidden=visible!==0;
  }
  function setSaveState(text){$("#save-state").textContent=text}
  async function loadState(){
    const response=await fetch("/api/board-review/"+encodeURIComponent(DESIGN_NAME),{headers:{accept:"application/json"}});
    const value=await response.json();if(!response.ok)throw new Error(value.error||("HTTP "+response.status));
    (value.entries||[]).forEach(entry=>state.set(entry.id,entry));
  }
  async function loadAudit(){
    const query=new URLSearchParams(location.search),layout=query.get("layout");
    let url="/api/board-review-audit/"+encodeURIComponent(DESIGN_NAME);if(layout)url+="?layout="+encodeURIComponent(layout);
    try{
      const response=await fetch(url,{headers:{accept:"application/json"}}),value=await response.json();if(!response.ok)throw new Error(value.error||("HTTP "+response.status));
      (value.assessment&&value.assessment.items||[]).forEach(item=>generated.set(item.id,item));
      const d=value.datasheets&&value.datasheets.summary,status=$("#datasheet-status");
      if(d&&status)status.textContent="Exact fitted-part datasheets: "+d.local+" local · "+d.remote_only+" ready to fetch · "+d.missing+" missing · "+d.missing_mpn+" missing exact MPN";
      assessmentReady=true;setSaveState("Generated analysis current");render();
    }catch(error){console.error(error);setSaveState("Generated analysis unavailable")}
  }
  async function boot(){
    sections=parseCatalog(CHECKLIST_MARKDOWN);
    try{await loadState()}catch(error){setSaveState("Saved state unavailable");console.error(error)}
    render();
    $("#review-search").addEventListener("input",applyFilters);
    all(".filter").forEach(button=>button.addEventListener("click",()=>{all(".filter").forEach(b=>b.classList.remove("active"));button.classList.add("active");activeFilter=button.dataset.filter;applyFilters()}));
    $("#expand-all").addEventListener("click",()=>all(".section-card").forEach(x=>x.open=true));
    $("#collapse-all").addEventListener("click",()=>all(".section-card").forEach(x=>x.open=false));
    loadAudit();
  }
  boot();
})();
