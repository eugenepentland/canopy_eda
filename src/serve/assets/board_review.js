(function(){
  "use strict";
  const STATUS_LABELS={open:"Open",pass:"Pass",fail:"Fail",na:"N/A",needs_info:"Needs info"};
  const $=s=>document.querySelector(s);
  const all=(s,r=document)=>Array.from(r.querySelectorAll(s));
  let state=new Map(),sections=[],activeFilter="all";

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
  function current(id){
    return state.get(id)||{id,status:"open",evidence:"",note:"",updated_by:"",updated_at:""};
  }
  function option(value,label){
    const o=document.createElement("option");o.value=value;o.textContent=label;return o;
  }
  function renderItem(item){
    const saved=current(item.id),row=el("article","review-item");row.dataset.id=item.id;row.dataset.status=saved.status;
    const main=el("div","item-main"),id=el("span","item-id",item.id),copy=el("div","item-copy"),text=el("div","item-text",item.text);
    copy.append(text);
    if(item.severity){const meta=el("div","item-meta"),badge=el("span","severity "+item.severity,item.severity);meta.append(badge);copy.append(meta)}
    const select=el("select","status-select");select.setAttribute("aria-label","Status for "+item.id);
    Object.entries(STATUS_LABELS).forEach(([value,label])=>select.append(option(value,label)));select.value=saved.status;select.disabled=!CAN_WRITE;
    main.append(id,copy,select);row.append(main);
    const detail=el("div","item-detail"),evidence=el("input"),note=el("textarea"),save=el("button",null,"Save");
    evidence.type="text";evidence.placeholder="Evidence: refdes, net, layer, datasheet §/page, or report";evidence.value=saved.evidence;evidence.disabled=!CAN_WRITE;
    note.placeholder="One-line reviewer note";note.value=saved.note;note.disabled=!CAN_WRITE;save.disabled=!CAN_WRITE;
    detail.append(evidence,note,save);row.append(detail);
    const stamp=el("div","item-stamp",saved.updated_at?(saved.updated_by+" · "+saved.updated_at):"Not reviewed yet");row.append(stamp);
    const markDirty=()=>{save.textContent="Save";setSaveState("Unsaved changes")};
    select.addEventListener("change",markDirty);evidence.addEventListener("input",markDirty);note.addEventListener("input",markDirty);
    save.addEventListener("click",async()=>{
      save.disabled=true;save.textContent="Saving…";setSaveState("Saving…");
      try{
        const payload={id:item.id,status:select.value,evidence:evidence.value.trim(),note:note.value.trim()};
        const response=await fetch("/api/board-review/"+encodeURIComponent(DESIGN_NAME),{method:"POST",headers:{"content-type":"application/json","x-netlisp-review":"1"},body:JSON.stringify(payload)});
        const value=await response.json();if(!response.ok)throw new Error(value.error||("HTTP "+response.status));
        state.set(item.id,value.entry);row.dataset.status=value.entry.status;stamp.textContent=value.entry.updated_by+" · "+value.entry.updated_at;
        save.textContent="Saved";setTimeout(()=>save.textContent="Save",1200);setSaveState("Saved");updateProgress();applyFilters();
      }catch(error){save.textContent="Retry";setSaveState("Save failed");alert(error.message)}
      finally{save.disabled=!CAN_WRITE}
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
    const c={total:0,open:0,pass:0,fail:0,na:0,needs_info:0};
    items.forEach(item=>{const row=document.querySelector('.review-item[data-id="'+CSS.escape(item.id)+'"]');if(!row)return;c.total++;c[row.dataset.status||"open"]++});
    return c;
  }
  function updateProgress(){
    const items=sections.flatMap(s=>s.items),c=counts(items),ready=c.pass+c.na,blocked=c.fail+c.needs_info;
    $("#metric-ready").textContent=ready+" / "+c.total;$("#metric-reviewed").textContent=(c.total-c.open)+" / "+c.total;
    $("#metric-blocked").textContent=String(blocked);$("#metric-open").textContent=String(c.open);
    $("#progress-bar").style.width=(c.total?ready*100/c.total:0)+"%";
    sections.forEach(section=>{const sc=counts(section.items);let label=(sc.pass+sc.na)+" / "+sc.total+" ready";
      const bad=sc.fail+sc.needs_info;if(bad)label+=" · "+bad+" blocked";
      const node=document.querySelector('.section-card[data-section="'+section.number+'"] .section-progress');if(node)node.textContent=label;
    });
  }
  function searchable(row){
    const copy=row.querySelector(".item-text");return (row.dataset.id+" "+(copy?copy.textContent:"")).toLowerCase();
  }
  function applyFilters(){
    const term=$("#review-search").value.trim().toLowerCase();let visible=0;
    all(".review-item").forEach(row=>{
      const status=row.dataset.status||"open";
      const filter=activeFilter==="all"||(activeFilter==="remaining"?(status!=="pass"&&status!=="na"):status===activeFilter);
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
    const host=$("#audit"),query=new URLSearchParams(location.search),layout=query.get("layout");
    let url="/api/board-review-audit/"+encodeURIComponent(DESIGN_NAME);if(layout)url+="?layout="+encodeURIComponent(layout);
    try{const response=await fetch(url,{headers:{accept:"application/json"}});const value=await response.json();if(!response.ok)throw new Error(value.error||("HTTP "+response.status));host.innerHTML=value.html}
    catch(error){host.className="audit-error";host.textContent="Automated audit could not be generated: "+error.message}
  }
  async function boot(){
    sections=parseCatalog(CHECKLIST_MARKDOWN);
    try{await loadState()}catch(error){setSaveState("State unavailable");console.error(error)}
    render();
    $("#review-search").addEventListener("input",applyFilters);
    all(".filter").forEach(button=>button.addEventListener("click",()=>{all(".filter").forEach(b=>b.classList.remove("active"));button.classList.add("active");activeFilter=button.dataset.filter;applyFilters()}));
    $("#expand-all").addEventListener("click",()=>all(".section-card").forEach(x=>x.open=true));
    $("#collapse-all").addEventListener("click",()=>all(".section-card").forEach(x=>x.open=false));
    loadAudit();
  }
  boot();
})();
