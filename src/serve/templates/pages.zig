//! Server-rendered markup for the home page: the navbar every page shares, one
//! card per system-review workspace, design and reusable module, and the page
//! that grids them.
//!
//! HAND-MAINTAINED. This file was first emitted by a template compiler that no
//! longer exists; it is ordinary Zig source now and the only source of truth
//! for this markup. To edit it safely, keep the shape the three template files
//! share: one `writer.writeAll(...)` per run of literal markup, every value
//! that comes from data through `html.writeEscaped` (text) or `html.writeAttr`
//! (a whole attribute), and `html.writeRaw` reserved for markup this repository
//! produced. Pages are asserted against exact substrings in tests, so
//! whitespace between tags is meaningful — `zig fmt` is safe, reflowing markup
//! is not. See `html.zig` for the sinks.

const std = @import("std");
const html = @import("html.zig");

const mcp_tools = @import("../mcp_tools.zig");
const DesignSummary = mcp_tools.DesignSummary;

/// One module card on the home page: lib/modules metadata joined with the
/// designs that instantiate it (computed by the index handler).
pub const ModuleHomeEntry = struct {
    name: []const u8,
    params: []const u8,
    doc: []const u8,
    used_by: []const []const u8,
    /// Module body declares placement-cohesion `(group …)` DSL — ready to rough.
    has_groups: bool = false,
    /// A layout in `<module>.layouts.json` is starred (a person approved it).
    has_starred: bool = false,
};

/// A design summary paired with the lowercase-friendly haystack the home
/// page's client-side filter AND-matches query terms against (the "design"
/// tag word + name + title + section names). Built by the index handler.
pub const DesignCardVM = struct {
    s: DesignSummary,
    search: []const u8,
    /// A layout in `<design>.layouts.json` is starred (a person approved it).
    has_starred: bool = false,
};

/// A module entry paired with its search haystack (the "module" tag word +
/// name + params + doc).
pub const ModuleCardVM = struct {
    m: ModuleHomeEntry,
    search: []const u8,
};

/// One system-review workspace on the home page: `src/systems/<name>/`
/// manifest identity plus its board and document counts.
pub const SystemHomeEntry = struct {
    name: []const u8,
    title: []const u8,
    part_number: []const u8,
    revision: []const u8,
    boards: usize,
    documents: usize,
    /// The manifest carries a current attestation over these exact inputs.
    attested: bool = false,
    /// Contract lifecycle word — concept, design, review or released.
    status: []const u8 = "design",
};

/// A system entry paired with its search haystack (the "system" tag word +
/// name + title + part number + revision).
pub const SystemCardVM = struct {
    sys: SystemHomeEntry,
    search: []const u8,
};

// The whole `<style>…</style>` block, assembled once at compile time and
// spliced into the head with a single `html.writeRaw`. Keeping it out of the
// markup body means the CSS is never scanned for anything to escape.
const home_style_block: []const u8 = "<style>" ++ @embedFile("../assets/navbar.css") ++
    \\body{margin:0;background:#0d1117;color:#c9d1d9;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
    \\.designs-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(300px,1fr));gap:14px;padding:16px}
    \\.design-card{min-width:0;background:#161b22;border:1px solid #21262d;
    \\border-radius:10px;padding:18px 20px;display:flex;flex-direction:column;
    \\gap:10px;transition:border-color 0.15s}
    \\.design-card:hover{border-color:#58a6ff}
    \\.design-card-header{display:flex;flex-direction:column;gap:2px}
    \\.design-card-title{color:#f0f6fc;font-size:1.05rem;font-weight:600;line-height:1.3}
    \\.design-card-name{color:#6e7681;font-size:12px;font-family:monospace}
    \\.design-card-stats{display:flex;gap:8px;font-size:12px;color:#8b949e;align-items:center;flex-wrap:wrap}
    \\.design-card-stats .sep{color:#30363d}
    \\.design-card-stats .warn{color:#d29922}
    \\.layout-progress{display:flex;flex-direction:column;gap:5px;padding:8px 10px;
    \\border:1px solid #30363d;border-radius:7px;background:#0d1117;text-decoration:none;color:#8b949e}
    \\.layout-progress:hover{border-color:#58a6ff;text-decoration:none}
    \\.layout-progress-head{display:flex;align-items:center;gap:7px;font-size:12px;font-weight:600;color:#c9d1d9}
    \\.layout-progress.loading .layout-progress-head{color:#6e7681}
    \\.layout-progress.done .layout-progress-head{color:#3fb950}
    \\.layout-progress.error .layout-progress-head{color:#d29922}
    \\.layout-progress-steps{display:grid;grid-template-columns:repeat(6,1fr);gap:3px;height:4px}
    \\.layout-progress-step{border-radius:2px;background:#30363d}
    \\.layout-progress-step.done{background:#238636}
    \\.layout-progress-step.current{background:#58a6ff}
    \\.layout-progress-next{font-size:11px;color:#6e7681;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
    \\.design-card-sections{display:flex;flex-wrap:wrap;gap:4px}
    \\.section-chip{background:#1a1a2e;color:#8b949e;font-size:11px;padding:2px 8px;border-radius:10px;border:1px solid #21262d;text-decoration:none}
    \\a.section-chip:hover{border-color:#58a6ff;color:#c9d1d9}
    \\.section-chip-more{color:#6e7681;font-size:11px;padding:2px 4px}
    \\.mod-params{color:#6e7681;font-size:12px;font-family:monospace;font-weight:400}
    \\.mod-sub-note{padding:0 16px;margin:4px 0 0;color:#8b949e;font-size:0.85rem}
    \\.design-card-links{display:flex;gap:8px;margin-top:auto;padding-top:4px}
    \\.design-card-link{color:#8b949e;font-size:13px;padding:6px 14px;
    \\border:1px solid #30363d;border-radius:6px;text-decoration:none;
    \\text-align:center;flex:1}
    \\.design-card-link:hover{border-color:#58a6ff;color:#c9d1d9}
    \\.empty-hint{color:#6e7681;font-size:13px;padding:24px;text-align:center}
    \\.type-row{display:flex;align-items:center;gap:6px;flex-wrap:wrap}
    \\.type-tag{font-size:10px;font-weight:600;text-transform:uppercase;letter-spacing:.04em;
    \\padding:1px 8px;border-radius:10px;border:1px solid #30363d;color:#8b949e}
    \\.type-tag.board{color:#58a6ff;border-color:#1f6feb}
    \\.type-tag.subcircuit{color:#bc8cff;border-color:#8957e5}
    \\.type-tag.system{color:#f0883e;border-color:#bd561d}
    \\.tag-chip{font-size:10px;font-weight:600;text-transform:uppercase;letter-spacing:.04em;
    \\padding:1px 8px;border-radius:10px;border:1px solid #30363d;color:#8b949e}
    \\.tag-chip.grouping{color:#3fb950;border-color:#238636}
    \\.tag-chip.starred{color:#d29922;border-color:#9e6a03}
    \\.home-filters{display:flex;gap:6px;padding:0 16px 4px;flex-wrap:wrap}
    \\.home-filter{background:#161b22;border:1px solid #30363d;border-radius:6px;color:#8b949e;
    \\font-size:12px;padding:.3rem .7rem;cursor:pointer;font-family:inherit}
    \\.home-filter:hover{border-color:#58a6ff;color:#c9d1d9}
    \\.home-filter.active{color:#f0f6fc;border-color:#58a6ff;background:#1f2937}
    \\.home-search{display:block;box-sizing:border-box;width:calc(100% - 32px);margin:8px 16px 4px;
    \\background:#161b22;border:1px solid #30363d;border-radius:6px;color:#c9d1d9;
    \\padding:.55rem .75rem;font-size:.95rem;font-family:inherit}
    \\.home-search:focus{outline:none;border-color:#58a6ff}
    \\.home-search::placeholder{color:#555}
    \\.home-count{color:#6e7681;font-size:12px;margin:0 16px 4px}
    \\.home-newrow{display:flex;gap:8px;align-items:center;margin:8px 16px 4px}
    \\.home-newrow .home-search{width:auto;flex:1 1 auto;margin:0}
    \\.home-new{flex:0 0 auto;background:#238636;border:1px solid #2ea043;border-radius:6px;
    \\color:#fff;font-size:13px;padding:.55rem .9rem;cursor:pointer;font-family:inherit;white-space:nowrap}
    \\.home-new:hover{filter:brightness(1.1)}
    \\@media(max-width:600px){
    \\.home-shell{width:100%;overflow:hidden}
    \\.home-title{margin:0;padding:18px 12px 2px!important;font-size:1.45rem}
    \\.mod-sub-note{padding:0 12px;margin-top:4px;line-height:1.45}
    \\.home-newrow{flex-direction:column;align-items:stretch;margin:12px 12px 6px}
    \\.home-newrow .home-search{width:100%;min-height:44px;font-size:16px}
    \\.home-new{width:100%;min-height:44px;font-size:14px}
    \\.home-filters{padding:2px 12px 5px;flex-wrap:nowrap;overflow-x:auto;scrollbar-width:none}
    \\.home-filters::-webkit-scrollbar{display:none}
    \\.home-filter{min-height:40px;padding:.45rem .9rem;flex:none;touch-action:manipulation}
    \\.home-count{margin:0 12px 4px}
    \\.designs-grid{grid-template-columns:minmax(0,1fr);padding:10px 12px 20px;gap:10px}
    \\.design-card{padding:14px}
    \\.design-card-link{display:flex;align-items:center;justify-content:center;min-height:44px;padding:6px 10px}
    \\.layout-progress{padding:10px}}
++ "</style>";

// Client-side filter for the unified Designs + Modules grid. Mirrors the
// library / former /modules search: split the query on whitespace and
// AND-match each term against the card's `data-search` attribute (name +
// title/params + sections/doc + the type-tag word). One compile-time constant
// spliced in with `html.writeRaw`, so nothing here is escaped or interpolated.
const home_search_script: []const u8 =
    \\<script>
    \\(function(){
    \\ var input=document.getElementById('home-search');
    \\ if(!input)return;
    \\ var grid=document.getElementById('home-grid');
    \\ var cards=Array.prototype.slice.call(grid.querySelectorAll('.design-card'));
    \\ var count=document.getElementById('home-count');
    \\ var empty=document.getElementById('home-empty');
    \\ var btns=Array.prototype.slice.call(document.querySelectorAll('.home-filter'));
    \\ var total=cards.length;
    \\ var kind='all';
    \\ function apply(){
    \\  var q=input.value.toLowerCase().trim();
    \\  var terms=q?q.split(/\s+/):[];
    \\  var shown=0;
    \\  for(var i=0;i<cards.length;i++){
    \\   var c=cards[i];
    \\   var s=(c.getAttribute('data-search')||'').toLowerCase();
    \\   var match=(kind==='all')||(c.getAttribute('data-kind')===kind);
    \\   for(var t=0;match&&t<terms.length;t++){if(s.indexOf(terms[t])<0)match=false;}
    \\   c.style.display=match?'':'none';
    \\   if(match)shown++;
    \\  }
    \\  var filtered=q||kind!=='all';
    \\  count.textContent=filtered?(shown+' of '+total+' items'):(total+(total===1?' item':' items'));
    \\  if(empty)empty.style.display=shown===0?'':'none';
    \\ }
    \\ input.addEventListener('input',apply);
    \\ btns.forEach(function(b){b.addEventListener('click',function(){
    \\  kind=b.getAttribute('data-filter')||'all';
    \\  btns.forEach(function(x){x.classList.toggle('active',x===b);});
    \\  apply();
    \\ });});
    \\ apply();
    \\})();
    \\</script>
;

// Lazily hydrate the six-stage PCB completion tracker on each design card.
// A small concurrency cap keeps a large project from launching every placement
// solve at once; cards fill in as their compact progress response arrives.
const home_progress_script: []const u8 =
    \\<script>
    \\(function(){
    \\ var cards=[];
    \\ Array.prototype.slice.call(document.querySelectorAll('.design-card[data-progress-name]')).forEach(function(card){
    \\  var name=card.getAttribute('data-progress-name')||'';if(!name)return;
    \\  var link=card.querySelector('a[href^="/pcb-layout/"]');if(!link)return;
    \\  var boardHref=link.getAttribute('href');var el=document.createElement('a');
    \\  el.className='layout-progress loading';el.href=boardHref;el.setAttribute('data-board-href',boardHref);
    \\  el.setAttribute('data-layout-progress',name);el.title='Loading PCB design progress';
    \\  el.innerHTML='<span class="layout-progress-head"><span class="layout-progress-label">Loading layout progress\u2026</span></span>'+
    \\   '<span class="layout-progress-steps" aria-hidden="true"></span>'+
    \\   '<span class="layout-progress-next">Checking the six design stages\u2026</span>';
    \\  card.querySelector('.design-card-stats').insertAdjacentElement('afterend',el);cards.push(el);
    \\ });
    \\ if(!cards.length)return;
    \\ var labels={schematic:'Schematic',sub_circuits:'Sub-circuits',board_setup:'Board setup',
    \\  placement:'Placement',routing:'Routing',fab_ready:'Fab-ready'};
    \\ function stageName(id){return labels[id]||String(id||'').replace(/_/g,' ').replace(/^./,function(c){return c.toUpperCase();});}
    \\ function setError(el){el.classList.remove('loading');el.classList.add('error');
    \\  el.querySelector('.layout-progress-label').textContent='Layout progress unavailable';
    \\  el.querySelector('.layout-progress-next').textContent='Open the PCB layout to inspect this design';}
    \\ function schematicCounts(el){var fields=[
    \\  ['data-erc-errors','ERC error','ERC errors'],['data-erc-warnings','ERC warning','ERC warnings'],
    \\  ['data-assert-fails','failed assertion','failed assertions'],['data-open-notes','open note','open notes']];
    \\  var parts=[];fields.forEach(function(f){var n=parseInt(el.getAttribute(f[0])||'0',10);
    \\   parts.push(n+' '+(n===1?f[1]:f[2]));});return parts.join(' \u00b7 ');}
    \\ function render(el,d){var stages=(d&&d.stages)||[];if(!stages.length){setError(el);return;}
    \\  var allDone=stages.every(function(s){return s.status==='done';});var idx=-1,cur=null;
    \\  for(var i=0;i<stages.length;i++)if(stages[i].status==='current'){idx=i;cur=stages[i];break;}
    \\  if(idx<0)for(var j=0;j<stages.length;j++)if(stages[j].status!=='done'){idx=j;cur=stages[j];break;}
    \\  if(idx<0){idx=stages.length-1;cur=stages[idx];}
    \\  var label=allDone?'Fab-ready \u2713':('Stage '+(idx+1)+'/'+stages.length+' \u00b7 '+stageName(cur.id));
    \\  var wave=null;if(cur.waves&&cur.waves.length){
    \\   for(var k=0;k<cur.waves.length;k++)if(cur.waves[k].name===d.current_wave||cur.waves[k].status==='current'){wave=cur.waves[k];break;}}
    \\  if(!allDone){if(wave)label+=' \u2014 '+wave.name+' '+(wave.done||0)+'/'+(wave.total||0);
    \\   else if(cur.total!=null)label+=' '+(cur.done||0)+'/'+cur.total;}
    \\  el.classList.remove('loading','error');el.classList.toggle('done',allDone);
    \\  el.querySelector('.layout-progress-label').textContent=label;
    \\  var steps=el.querySelector('.layout-progress-steps');steps.textContent='';
    \\  stages.forEach(function(s){var x=document.createElement('span');x.className='layout-progress-step '+(s.status||'pending');steps.appendChild(x);});
    \\  var items=(cur&&cur.items)||[],next=el.querySelector('.layout-progress-next');
    \\  var summary=cur&&cur.id==='schematic'?schematicCounts(el):'';
    \\  next.textContent=allDone?'All six PCB design stages complete':(summary||(items.length?('Next: '+(items[0].message||items[0].kind)):'Open the PCB layout for details'));
    \\  var first=items.length?items[0]:null,name=el.getAttribute('data-layout-progress')||'';
    \\  el.href=first&&first.pcb_target?('/pcb-layout/'+encodeURIComponent(first.pcb_target)):
    \\   (first&&first.kind==='erc-errors'?('/schematics/'+encodeURIComponent(name)):el.getAttribute('data-board-href'));
    \\  var tips=[];items.slice(0,3).forEach(function(it){if(it.message)tips.push(it.message);});el.title=tips.length?tips.join('\n'):label;}
    \\ var next=0,active=0,max=3;
    \\ function pump(){while(active<max&&next<cards.length){(function(el){active++;
    \\   var name=el.getAttribute('data-layout-progress')||'';
    \\   fetch('/api/layout-progress/'+encodeURIComponent(name)).then(function(r){if(!r.ok)throw new Error('HTTP '+r.status);return r.json();})
    \\    .then(function(d){render(el,d);},function(){setError(el);}).then(function(){active--;pump();});
    \\  })(cards[next++]);}}
    \\ pump();
    \\})();
    \\</script>
;

// "+ New design" → prompt for a name/title, POST /api/new-design, then open the
// schematic page for the fresh stub. Spliced in raw, like the other scripts.
const home_new_script: []const u8 =
    \\<script>
    \\(function(){
    \\ var b=document.getElementById('home-new');
    \\ if(!b)return;
    \\ b.addEventListener('click',async function(){
    \\  var name=prompt('New design name (letters, digits, - and _):');
    \\  if(name===null)return; name=name.trim(); if(!name)return;
    \\  var title=prompt('Title (optional):',name); if(title===null)return; title=title.trim()||name;
    \\  try{
    \\   var r=await fetch('/api/new-design',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({name:name,title:title})});
    \\   if(!r.ok){var t=await r.text().catch(function(){return '';});alert(t||('HTTP '+r.status));return;}
    \\   var d=await r.json().catch(function(){return {};});
    \\   location.href=d.url||('/schematics/'+name);
    \\  }catch(e){alert('Failed: '+e.message);}
    \\ });
    \\})();
    \\</script>
;

const seconds_per_minute: i64 = 60;
const seconds_per_hour: i64 = 3600;
const seconds_per_day: i64 = 86400;
const days_per_month_approx: i64 = 30;

// Route prefix for the schematic viewer. Interpolated into every "open the
// schematic" href so the generated template emits one shared const reference
// instead of repeating the literal path (keeps it off the repeated-string
// guardian check). `/schematics/<name>` renders both designs and modules.
const schematic_prefix: []const u8 = "/schematics/";

/// One type-filter button on the home grid. `id` matches each card's
/// `data-kind` (or "all"); the client script in HOME_SEARCH_SCRIPT toggles
/// the active button and AND-combines the chosen kind with the text search.
const HomeFilter = struct { id: []const u8, label: []const u8 };
const home_filters = [_]HomeFilter{
    .{ .id = "all", .label = "All" },
    .{ .id = "board", .label = "Boards" },
    .{ .id = "subcircuit", .label = "Subcircuits" },
    .{ .id = "system", .label = "Systems" },
};

fn filterClass(id: []const u8) []const u8 {
    return if (std.mem.eql(u8, id, "all")) "home-filter active" else "home-filter";
}

const RelTime = struct {
    age_sec: i64,

    pub fn formatHtml(self: RelTime, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const a = self.age_sec;
        if (a < seconds_per_minute) {
            try w.writeAll("just now");
            return;
        }
        if (a < seconds_per_hour) {
            try w.print("{d}m ago", .{@divTrunc(a, seconds_per_minute)});
            return;
        }
        if (a < seconds_per_day) {
            try w.print("{d}h ago", .{@divTrunc(a, seconds_per_hour)});
            return;
        }
        if (a < days_per_month_approx * seconds_per_day) {
            try w.print("{d}d ago", .{@divTrunc(a, seconds_per_day)});
            return;
        }
        try w.print("{d}mo ago", .{@divTrunc(a, days_per_month_approx * seconds_per_day)});
    }
};

fn relTime(age_sec: i64) RelTime {
    return .{ .age_sec = if (age_sec < 0) 0 else age_sec };
}

fn pluralS(n: usize) []const u8 {
    return if (n == 1) "" else "s";
}

fn hasOwnTitle(s: DesignSummary) bool {
    return s.title.len > 0 and !std.mem.eql(u8, s.title, s.name);
}

/// The navigation bar every server-rendered page starts with. `active` names
/// the current tab so exactly one link carries the current-page marking.
pub const Navbar = struct {
    /// Write this template's markup to `writer`.
    fn write(active: []const u8, writer: *std.Io.Writer) html.Error!void {
        try writer.writeAll("<nav class=\"navbar\" aria-label=\"Primary\">");
        try writer.writeAll("<a");
        try writer.writeAll(" href=\"/\"");
        try html.writeAttr(writer, "class", if (std.mem.eql(u8, active, "designs")) "brand active" else "brand");
        try html.writeAttr(writer, "aria-current", if (std.mem.eql(u8, active, "designs")) "page" else null);
        try writer.writeAll(">");
        try writer.writeAll("Netlisp");
        try writer.writeAll("</a>");
        try writer.writeAll("<a");
        try writer.writeAll(" href=\"/library\"");
        try html.writeAttr(writer, "class", if (std.mem.eql(u8, active, "library")) "active" else null);
        try html.writeAttr(writer, "aria-current", if (std.mem.eql(u8, active, "library")) "page" else null);
        try writer.writeAll(">");
        try writer.writeAll("Library");
        try writer.writeAll("</a>");
        try writer.writeAll("</nav>");
    }

    /// `write`'s parameter list, spelled as a function so `std.meta.ArgsTuple`
    /// can lift it into the tuple type `render` and `bind` accept.
    fn argList(_: []const u8) void {}

    /// The positional arguments this template renders from.
    pub const Args = std.meta.ArgsTuple(@TypeOf(argList));

    /// Render the template to `writer`.
    pub fn render(args: Args, writer: *std.Io.Writer) html.Error!void {
        return @call(.always_inline, write, args ++ .{writer});
    }

    /// Capture this template together with `args` as a type-erased component,
    /// so another template can render it without naming its type. `args` is
    /// borrowed and has to outlive every render of the returned component.
    pub fn bind(args: *const Args) html.Component {
        return .{ .ptr = @ptrCast(args), .renderFn = &renderErased };
    }

    fn renderErased(ptr: *const anyopaque, writer: *std.Io.Writer) html.Error!void {
        return render(@as(*const Args, @ptrCast(@alignCast(ptr))).*, writer);
    }
};

/// One design as a home card: identity, counts, the six-stage layout
/// progress tracker, and the links into its schematic and layout pages.
pub const DesignCard = struct {
    /// Write this template's markup to `writer`.
    fn write(s: DesignSummary, search: []const u8, has_starred: bool, now_sec: i64, writer: *std.Io.Writer) html.Error!void {
        try writer.writeAll("<div");
        try writer.writeAll(" class=\"design-card\"");
        try html.writeAttr(writer, "data-kind", if (s.is_board) "board" else "subcircuit");
        try html.writeAttr(writer, "data-search", search);
        try html.writeAttr(writer, "data-progress-name", if (s.build_ok) s.name else null);
        try html.writeAttr(writer, "data-erc-errors", s.erc_errors);
        try html.writeAttr(writer, "data-erc-warnings", s.erc_warnings);
        try html.writeAttr(writer, "data-assert-fails", s.assert_fails);
        try html.writeAttr(writer, "data-open-notes", s.open_notes);
        try writer.writeAll(">");
        try writer.writeAll("<div class=\"type-row\">");
        if (s.is_board) {
            try writer.writeAll("<span class=\"type-tag board\">");
            try writer.writeAll("Board");
            try writer.writeAll("</span>");
        } else {
            try writer.writeAll("<span class=\"type-tag subcircuit\">");
            try writer.writeAll("Subcircuit");
            try writer.writeAll("</span>");
        }
        if (s.has_groups) {
            try writer.writeAll("<span class=\"tag-chip grouping\" title=\"Declares placement (group …) DSL — ready for a rough placement\">");
            try writer.writeAll("grouping");
            try writer.writeAll("</span>");
        }
        if (has_starred) {
            try writer.writeAll("<span class=\"tag-chip starred\" title=\"A layout has been starred — approved by a person\">");
            try writer.writeAll("★ starred");
            try writer.writeAll("</span>");
        }
        try writer.writeAll("</div>");
        try writer.writeAll("<div class=\"design-card-header\">");
        if (hasOwnTitle(s)) {
            try writer.writeAll("<div class=\"design-card-title\">");
            try html.writeEscaped(writer, s.title);
            try writer.writeAll("</div>");
            try writer.writeAll("<div class=\"design-card-name\">");
            try html.writeEscaped(writer, s.name);
            try writer.writeAll(".sexp");
            try writer.writeAll("</div>");
        } else {
            try writer.writeAll("<div class=\"design-card-title\">");
            try html.writeEscaped(writer, s.name);
            try writer.writeAll("</div>");
        }
        try writer.writeAll("</div>");
        try writer.writeAll("<div class=\"design-card-stats\">");
        if (s.build_ok) {
            try writer.writeAll("<span>");
            try html.writeEscaped(writer, s.instance_count);
            try writer.writeAll(" part");
            try html.writeEscaped(writer, pluralS(s.instance_count));
            try writer.writeAll("</span>");
            try writer.writeAll("<span class=\"sep\">");
            try writer.writeAll("·");
            try writer.writeAll("</span>");
            try writer.writeAll("<span>");
            try html.writeEscaped(writer, s.net_count);
            try writer.writeAll(" net");
            try html.writeEscaped(writer, pluralS(s.net_count));
            try writer.writeAll("</span>");
        } else {
            try writer.writeAll("<span class=\"warn\">");
            try writer.writeAll("build failed");
            try writer.writeAll("</span>");
        }
        if (s.mtime_sec > 0) {
            try writer.writeAll("<span class=\"sep\">");
            try writer.writeAll("·");
            try writer.writeAll("</span>");
            try writer.writeAll("<span>");
            try html.writeEscaped(writer, relTime(now_sec - s.mtime_sec));
            try writer.writeAll("</span>");
        }
        try writer.writeAll("</div>");
        try writer.writeAll("<div class=\"design-card-links\">");
        try writer.writeAll("<a");
        try writer.writeAll(" class=\"design-card-link\"");
        try writer.writeAll(" href=\"");
        try html.writeEscaped(writer, schematic_prefix);
        try html.writeEscaped(writer, s.name);
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll("Schematic");
        try writer.writeAll("</a>");
        try writer.writeAll("<a");
        try writer.writeAll(" class=\"design-card-link\"");
        try writer.writeAll(" href=\"");
        try writer.writeAll("/pcb-layout/");
        try html.writeEscaped(writer, s.name);
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll("PCB layout");
        try writer.writeAll("</a>");
        try writer.writeAll("</div>");
        try writer.writeAll("</div>");
    }

    /// `write`'s parameter list, spelled as a function so `std.meta.ArgsTuple`
    /// can lift it into the tuple type `render` and `bind` accept.
    fn argList(_: DesignSummary, _: []const u8, _: bool, _: i64) void {}

    /// The positional arguments this template renders from.
    pub const Args = std.meta.ArgsTuple(@TypeOf(argList));

    /// Render the template to `writer`.
    pub fn render(args: Args, writer: *std.Io.Writer) html.Error!void {
        return @call(.always_inline, write, args ++ .{writer});
    }

    /// Capture this template together with `args` as a type-erased component,
    /// so another template can render it without naming its type. `args` is
    /// borrowed and has to outlive every render of the returned component.
    pub fn bind(args: *const Args) html.Component {
        return .{ .ptr = @ptrCast(args), .renderFn = &renderErased };
    }

    fn renderErased(ptr: *const anyopaque, writer: *std.Io.Writer) html.Error!void {
        return render(@as(*const Args, @ptrCast(@alignCast(ptr))).*, writer);
    }
};

/// One system-review workspace as a home card: identity, board and document
/// counts, and the link into `/systems/<name>`.
pub const SystemCard = struct {
    /// Write this template's markup to `writer`.
    fn write(sys: SystemHomeEntry, search: []const u8, writer: *std.Io.Writer) html.Error!void {
        try writer.writeAll("<div");
        try writer.writeAll(" class=\"design-card\"");
        try writer.writeAll(" data-kind=\"system\"");
        try html.writeAttr(writer, "data-search", search);
        try writer.writeAll(">");
        try writer.writeAll("<div class=\"type-row\">");
        try writer.writeAll("<span class=\"type-tag system\">");
        try writer.writeAll("System");
        try writer.writeAll("</span>");
        try writer.writeAll("<span class=\"tag-chip\" title=\"Contract lifecycle declared by (status …)\">");
        try html.writeEscaped(writer, sys.status);
        try writer.writeAll("</span>");
        if (sys.attested) {
            try writer.writeAll("<span class=\"tag-chip starred\" title=\"Review inputs have been approved and the attestation is current\">");
            try writer.writeAll("attested");
            try writer.writeAll("</span>");
        }
        try writer.writeAll("</div>");
        try writer.writeAll("<div class=\"design-card-header\">");
        try writer.writeAll("<div class=\"design-card-title\">");
        try html.writeEscaped(writer, sys.title);
        try writer.writeAll("</div>");
        try writer.writeAll("<div class=\"design-card-name\">");
        try html.writeEscaped(writer, sys.part_number);
        try writer.writeAll(" rev ");
        try html.writeEscaped(writer, sys.revision);
        try writer.writeAll("</div>");
        try writer.writeAll("</div>");
        try writer.writeAll("<div class=\"design-card-stats\">");
        // A concept system may carry no boards at all; it says what it is
        // instead of claiming zero of them.
        if (sys.boards > 0) {
            try writer.writeAll("<span>");
            try html.writeEscaped(writer, sys.boards);
            try writer.writeAll(" boards");
            try writer.writeAll("</span>");
            try writer.writeAll("<span class=\"sep\">");
            try writer.writeAll("·");
            try writer.writeAll("</span>");
        }
        try writer.writeAll("<span>");
        try html.writeEscaped(writer, sys.documents);
        try writer.writeAll(" documents");
        try writer.writeAll("</span>");
        try writer.writeAll("</div>");
        try writer.writeAll("<div class=\"design-card-links\">");
        try writer.writeAll("<a");
        try writer.writeAll(" class=\"design-card-link\"");
        try writer.writeAll(" href=\"");
        try writer.writeAll("/systems/");
        try html.writeEscaped(writer, sys.name);
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll("Review workspace");
        try writer.writeAll("</a>");
        try writer.writeAll("</div>");
        try writer.writeAll("</div>");
    }

    /// `write`'s parameter list, spelled as a function so `std.meta.ArgsTuple`
    /// can lift it into the tuple type `render` and `bind` accept.
    fn argList(_: SystemHomeEntry, _: []const u8) void {}

    /// The positional arguments this template renders from.
    pub const Args = std.meta.ArgsTuple(@TypeOf(argList));

    /// Render the template to `writer`.
    pub fn render(args: Args, writer: *std.Io.Writer) html.Error!void {
        return @call(.always_inline, write, args ++ .{writer});
    }

    /// Capture this template together with `args` as a type-erased component,
    /// so another template can render it without naming its type. `args` is
    /// borrowed and has to outlive every render of the returned component.
    pub fn bind(args: *const Args) html.Component {
        return .{ .ptr = @ptrCast(args), .renderFn = &renderErased };
    }

    fn renderErased(ptr: *const anyopaque, writer: *std.Io.Writer) html.Error!void {
        return render(@as(*const Args, @ptrCast(@alignCast(ptr))).*, writer);
    }
};

/// One reusable `lib/modules` entry as a home card: signature, doc line and
/// the designs that instantiate it.
pub const ModuleCard = struct {
    /// Write this template's markup to `writer`.
    fn write(m: ModuleHomeEntry, search: []const u8, writer: *std.Io.Writer) html.Error!void {
        try writer.writeAll("<div");
        try writer.writeAll(" class=\"design-card\"");
        try writer.writeAll(" data-kind=\"subcircuit\"");
        try html.writeAttr(writer, "data-search", search);
        try writer.writeAll(">");
        try writer.writeAll("<div class=\"type-row\">");
        try writer.writeAll("<span class=\"type-tag subcircuit\">");
        try writer.writeAll("Subcircuit");
        try writer.writeAll("</span>");
        if (m.has_groups) {
            try writer.writeAll("<span class=\"tag-chip grouping\" title=\"Declares placement (group …) DSL — ready for a rough placement\">");
            try writer.writeAll("grouping");
            try writer.writeAll("</span>");
        }
        if (m.has_starred) {
            try writer.writeAll("<span class=\"tag-chip starred\" title=\"A layout has been starred — approved by a person\">");
            try writer.writeAll("★ starred");
            try writer.writeAll("</span>");
        }
        try writer.writeAll("</div>");
        try writer.writeAll("<div class=\"design-card-header\">");
        try writer.writeAll("<div class=\"design-card-title\">");
        try html.writeEscaped(writer, m.name);
        try writer.writeAll("<span class=\"mod-params\">");
        try html.writeEscaped(writer, m.params);
        try writer.writeAll("</span>");
        try writer.writeAll("</div>");
        try writer.writeAll("</div>");
        if (m.doc.len > 0) {
            try writer.writeAll("<div class=\"design-card-stats\">");
            try writer.writeAll("<span>");
            try html.writeEscaped(writer, m.doc);
            try writer.writeAll("</span>");
            try writer.writeAll("</div>");
        }
        try writer.writeAll("<div class=\"design-card-sections\">");
        if (m.used_by.len > 0) {
            try writer.writeAll("<span class=\"section-chip-more\">");
            try writer.writeAll("used by");
            try writer.writeAll("</span>");
            for (m.used_by) |d| {
                try writer.writeAll("<a");
                try writer.writeAll(" class=\"section-chip\"");
                try writer.writeAll(" href=\"");
                try html.writeEscaped(writer, schematic_prefix);
                try html.writeEscaped(writer, d);
                try writer.writeAll("\"");
                try writer.writeAll(">");
                try html.writeEscaped(writer, d);
                try writer.writeAll("</a>");
            }
        } else {
            try writer.writeAll("<span class=\"section-chip-more\">");
            try writer.writeAll("not used by any design yet");
            try writer.writeAll("</span>");
        }
        try writer.writeAll("</div>");
        try writer.writeAll("<div class=\"design-card-links\">");
        try writer.writeAll("<a");
        try writer.writeAll(" class=\"design-card-link\"");
        try writer.writeAll(" href=\"");
        try html.writeEscaped(writer, schematic_prefix);
        try html.writeEscaped(writer, m.name);
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll("Schematic");
        try writer.writeAll("</a>");
        try writer.writeAll("<a");
        try writer.writeAll(" class=\"design-card-link\"");
        try writer.writeAll(" href=\"");
        try writer.writeAll("/pcb-layout/");
        try html.writeEscaped(writer, m.name);
        try writer.writeAll("\"");
        try writer.writeAll(">");
        try writer.writeAll("PCB layout");
        try writer.writeAll("</a>");
        try writer.writeAll("</div>");
        try writer.writeAll("</div>");
    }

    /// `write`'s parameter list, spelled as a function so `std.meta.ArgsTuple`
    /// can lift it into the tuple type `render` and `bind` accept.
    fn argList(_: ModuleHomeEntry, _: []const u8) void {}

    /// The positional arguments this template renders from.
    pub const Args = std.meta.ArgsTuple(@TypeOf(argList));

    /// Render the template to `writer`.
    pub fn render(args: Args, writer: *std.Io.Writer) html.Error!void {
        return @call(.always_inline, write, args ++ .{writer});
    }

    /// Capture this template together with `args` as a type-erased component,
    /// so another template can render it without naming its type. `args` is
    /// borrowed and has to outlive every render of the returned component.
    pub fn bind(args: *const Args) html.Component {
        return .{ .ptr = @ptrCast(args), .renderFn = &renderErased };
    }

    fn renderErased(ptr: *const anyopaque, writer: *std.Io.Writer) html.Error!void {
        return render(@as(*const Args, @ptrCast(@alignCast(ptr))).*, writer);
    }
};

/// The home page: the navbar, the search and filter controls, and the single
/// grid that holds every system, design and module card.
pub const Home = struct {
    /// Write this template's markup to `writer`.
    fn write(system_cards: []const SystemCardVM, design_cards: []const DesignCardVM, module_cards: []const ModuleCardVM, now_sec: i64, writer: *std.Io.Writer) html.Error!void {
        try writer.writeAll("<!DOCTYPE html>");
        try writer.writeAll("<html>");
        try writer.writeAll("<head>");
        try writer.writeAll("<meta name=\"viewport\" content=\"width=device-width,initial-scale=1,viewport-fit=cover\">");
        try writer.writeAll("<title>");
        try writer.writeAll("Netlisp — Systems, Designs &amp; Modules");
        try writer.writeAll("</title>");
        try html.writeRaw(writer, home_style_block);
        try writer.writeAll("</head>");
        try writer.writeAll("<body>");
        try html.renderComponent(Navbar, .{"designs"}, writer);
        try writer.writeAll("<div class=\"home-shell\" style=\"max-width:960px;margin:0 auto\">");
        try writer.writeAll("<h1 class=\"home-title\" style=\"padding:16px 16px 0;color:#f0f6fc\">");
        try writer.writeAll("Systems, Designs &amp; Modules");
        try writer.writeAll("</h1>");
        try writer.writeAll("<p class=\"mod-sub-note\">");
        try writer.writeAll("Every system-review workspace, ");
        try writer.writeAll("<code>");
        try writer.writeAll(".sexp");
        try writer.writeAll("</code>");
        try writer.writeAll(" design, and reusable ");
        try writer.writeAll("<code>");
        try writer.writeAll("lib/modules/");
        try writer.writeAll("</code>");
        try writer.writeAll(" block — tagged and searchable.");
        try writer.writeAll("</p>");
        try writer.writeAll("<div class=\"home-newrow\">");
        try writer.writeAll("<input type=\"text\" id=\"home-search\" class=\"home-search\" placeholder=\"Search systems, designs and modules…\">");
        try writer.writeAll("<button type=\"button\" id=\"home-new\" class=\"home-new\">");
        try writer.writeAll("+ New design");
        try writer.writeAll("</button>");
        try writer.writeAll("</div>");
        try writer.writeAll("<div class=\"home-filters\" id=\"home-filters\">");
        for (home_filters) |f| {
            try writer.writeAll("<button");
            try writer.writeAll(" type=\"button\"");
            try html.writeAttr(writer, "class", filterClass(f.id));
            try writer.writeAll(" data-filter=\"");
            try html.writeEscaped(writer, f.id);
            try writer.writeAll("\"");
            try writer.writeAll(">");
            try html.writeEscaped(writer, f.label);
            try writer.writeAll("</button>");
        }
        try writer.writeAll("</div>");
        try writer.writeAll("<div class=\"home-count\" id=\"home-count\">");
        try writer.writeAll("</div>");
        try writer.writeAll("<div class=\"designs-grid\" id=\"home-grid\">");
        for (system_cards) |c| {
            try html.renderComponent(SystemCard, .{ c.sys, c.search }, writer);
        }
        for (design_cards) |c| {
            try html.renderComponent(DesignCard, .{ c.s, c.search, c.has_starred, now_sec }, writer);
        }
        for (module_cards) |c| {
            try html.renderComponent(ModuleCard, .{ c.m, c.search }, writer);
        }
        if (system_cards.len == 0 and design_cards.len == 0 and module_cards.len == 0) {
            try writer.writeAll("<div class=\"empty-hint\">");
            try writer.writeAll("Nothing found.");
            try writer.writeAll("</div>");
        }
        try writer.writeAll("</div>");
        try writer.writeAll("<div class=\"empty-hint\" id=\"home-empty\" style=\"display:none\">");
        try writer.writeAll("Nothing matches your search.");
        try writer.writeAll("</div>");
        try writer.writeAll("</div>");
        try html.writeRaw(writer, home_search_script);
        try html.writeRaw(writer, home_progress_script);
        try html.writeRaw(writer, home_new_script);
        try writer.writeAll("</body>");
        try writer.writeAll("</html>");
    }

    /// `write`'s parameter list, spelled as a function so `std.meta.ArgsTuple`
    /// can lift it into the tuple type `render` and `bind` accept.
    fn argList(_: []const SystemCardVM, _: []const DesignCardVM, _: []const ModuleCardVM, _: i64) void {}

    /// The positional arguments this template renders from.
    pub const Args = std.meta.ArgsTuple(@TypeOf(argList));

    /// Render the template to `writer`.
    pub fn render(args: Args, writer: *std.Io.Writer) html.Error!void {
        return @call(.always_inline, write, args ++ .{writer});
    }

    /// Capture this template together with `args` as a type-erased component,
    /// so another template can render it without naming its type. `args` is
    /// borrowed and has to outlive every render of the returned component.
    pub fn bind(args: *const Args) html.Component {
        return .{ .ptr = @ptrCast(args), .renderFn = &renderErased };
    }

    fn renderErased(ptr: *const anyopaque, writer: *std.Io.Writer) html.Error!void {
        return render(@as(*const Args, @ptrCast(@alignCast(ptr))).*, writer);
    }
};
