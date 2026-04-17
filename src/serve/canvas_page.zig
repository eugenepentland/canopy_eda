const std = @import("std");
const httpz = @import("httpz");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const render_json = @import("../render_json.zig");
const serve_root = @import("../serve.zig");
const Handler = serve_root.Handler;
const assets_css = @import("assets_css.zig");
const bom_html = @import("bom_html.zig");
const library = @import("library.zig");

pub fn canvasPage(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };

    const board_path = try std.fmt.allocPrint(ctx.allocator, "{s}/src/{s}.sexp", .{ ctx.project_dir, name });
    defer ctx.allocator.free(board_path);

    var eval = Evaluator.init(ctx.allocator, ctx.project_dir);
    defer eval.deinit();

    const result = eval.evalFile(board_path) catch {
        res.status = 500;
        res.body = "Build error";
        return;
    };

    const block = switch (result) {
        .design_block => |b| b,
        else => {
            res.status = 500;
            return;
        },
    };

    // Generate scene graph and seed live cache
    const layout_json = render_json.renderSceneGraph(ctx.allocator, block) catch null;
    serve_root.live_mutex.lock();
    serve_root.live_layout_json = layout_json;
    serve_root.live_mutex.unlock();

    var sym_cache = try bom_html.buildSymbolPinCache(ctx.allocator, ctx.project_dir);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(ctx.allocator);

    try w.print("<!DOCTYPE html><html><head><meta name=\"viewport\" content=\"width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no\"><title>{s} — Canvas</title>", .{block.name});
    try w.writeAll("<style>");
    try w.writeAll(assets_css.NAVBAR_CSS);
    try w.writeAll(CANVAS_CSS);
    try w.writeAll("</style></head><body>");
    try assets_css.writeNavbar(w, "designs");

    // Toolbar below navbar
    try w.writeAll("<div class=\"toolbar\">");
    try w.print("<span class=\"toolbar-title\">{s}</span>", .{block.name});
    try w.writeAll("<button class=\"canvas-btn\" id=\"block-diagram-btn\">Block Diagram</button>");
    try w.writeAll("<button class=\"canvas-btn\" id=\"erc-btn\">ERC</button>");
    try w.writeAll("<div class=\"search-container\">");
    try w.writeAll("<input type=\"text\" id=\"search-input\" class=\"search-input\" placeholder=\"Search...\" autocomplete=\"off\">");
    try w.writeAll("<div class=\"search-results\" id=\"search-results\"></div>");
    try w.writeAll("</div>");
    try w.writeAll("<button class=\"canvas-btn\" id=\"canvas-reset\">Reset</button>");
    try w.writeAll("<button class=\"canvas-btn\" id=\"rebuild-btn\">Rebuild</button>");
    try w.print("<a class=\"canvas-btn\" href=\"/pcb/{s}\">PCB</a>", .{name});
    try w.print("<button class=\"canvas-btn\" onclick=\"window.location='/api/export-bom/{s}'\">Export BOM</button>", .{name});
    try w.writeAll("<div class=\"kicad-menu\">");
    try w.writeAll("<button class=\"canvas-btn\" id=\"kicad-btn\">KiCad \u{25BE}</button>");
    try w.writeAll("<div class=\"kicad-panel\" id=\"kicad-panel\">");
    try w.print("<button class=\"kicad-row-btn\" onclick=\"window.location='/api/export-netlist/{s}'\">Download Netlist (.net)</button>", .{name});
    try w.print("<button class=\"kicad-row-btn\" onclick=\"window.location='/api/export-kicad/{s}'\">Download Netlist + Footprints (.zip)</button>", .{name});
    try w.writeAll("<div class=\"kicad-sep\"></div>");
    try w.writeAll("<label class=\"kicad-label\">Output directory</label>");
    try w.writeAll("<input type=\"text\" class=\"kicad-input\" id=\"kicad-path\" placeholder=\"/path/to/kicad/project\" />");
    try w.writeAll("<label class=\"kicad-label\">.kicad_pcb file (optional)</label>");
    try w.writeAll("<input type=\"text\" class=\"kicad-input\" id=\"kicad-pcb-file\" placeholder=\"defaults to {output_dir}/{name}.kicad_pcb\" />");
    try w.writeAll("<button class=\"kicad-row-btn\" id=\"kicad-save-path\">Save settings</button>");
    try w.writeAll("<div class=\"kicad-sep\"></div>");
    try w.writeAll("<button class=\"kicad-row-btn\" id=\"kicad-write-netlist\">Write netlist to path</button>");
    try w.writeAll("<button class=\"kicad-row-btn\" id=\"kicad-write-kicad\">Write netlist + footprints to path</button>");
    try w.writeAll("<label class=\"kicad-check\"><input type=\"checkbox\" id=\"kicad-short-nets\" /> Shorten net names (.kicad_pcb update)</label>");
    try w.writeAll("<button class=\"kicad-row-btn kicad-primary\" id=\"kicad-update-pcb\">Update KiCad PCB (pcb_update.py)</button>");
    try w.writeAll("<div class=\"kicad-status\" id=\"kicad-status\"></div>");
    try w.writeAll("</div></div>");
    try w.writeAll("</div>");

    // Main area: canvas + sidebar
    try w.writeAll("<div class=\"main-area\">");
    try w.writeAll("<div id=\"pixi-container\" class=\"canvas-fill\"></div>");
    try w.writeAll("<div class=\"sidebar\" id=\"sidebar\">");
    try w.writeAll("<div id=\"sidebar-content\"><div class=\"sidebar-empty\">Click a component or net to inspect</div></div>");
    try w.writeAll("</div>");
    try w.writeAll("</div>");

    // Inject data globals
    try w.print("<script>var SCHEMATIC_SLUG='{s}';var DESIGN_NAME='{s}';var COMPONENTS={{", .{ name, name });
    _ = try bom_html.writeComponentsJson(w, block, "", &sym_cache, ctx.allocator, ctx.project_dir);
    try w.writeAll("};var NETS={");
    _ = try bom_html.writeNetsJson(w, block, "");
    try w.writeAll("};var SECTIONS=[");
    var sec_written = false;
    var concept_count: usize = 0;
    var total_sections: usize = 0;
    for (block.sections) |sec| {
        if (sec_written) try w.writeAll(",");
        try w.print("{{\"name\":\"{s}\",\"status\":\"{s}\"}}", .{ sec.name, @tagName(sec.status) });
        sec_written = true;
        total_sections += 1;
        if (sec.status == .concept) concept_count += 1;
    }
    for (block.sub_blocks) |sb| {
        if (sec_written) try w.writeAll(",");
        try w.writeAll("{\"name\":\"");
        try bom_html.writeJsonEscaped(w, sb.block.name);
        try w.writeAll("\",\"status\":\"implemented\"}");
        sec_written = true;
    }
    try w.writeAll("];var ASSERTIONS=[");
    for (eval.assertions.items, 0..) |a, ai| {
        if (ai > 0) try w.writeAll(",");
        try w.writeAll("{\"passed\":");
        try w.writeAll(if (a.passed) "true" else "false");
        try w.writeAll(",\"message\":\"");
        try bom_html.writeJsonEscaped(w, a.message);
        try w.writeAll("\",\"isWarning\":");
        try w.writeAll(if (a.is_warning) "true" else "false");
        try w.writeAll("}");
    }
    try w.writeAll("];var FAMILIES={");
    try library.writeFamiliesJson(w, ctx.allocator, ctx.project_dir);
    try w.writeAll("};");
    // Default to block diagram view if majority of sections are concept
    const is_concept_mode = total_sections > 0 and concept_count * 2 > total_sections;
    try w.print("var CONCEPT_MODE={s};", .{if (is_concept_mode) "true" else "false"});
    try w.writeAll("</script>");

    // KiCad sync menu wiring
    try w.writeAll("<script>");
    try w.writeAll(KICAD_MENU_JS);
    try w.writeAll("</script>");

    // Pixi.js from CDN
    try w.writeAll("<script src=\"https://cdn.jsdelivr.net/npm/pixi.js@8.6.6/dist/pixi.min.js\"></script>");

    // Canvas viewer JS
    try w.writeAll("<script>");
    try w.writeAll(CANVAS_VIEWER_JS);
    try w.writeAll("</script>");

    try w.writeAll("</body></html>");
    res.body = buf.items;
    res.content_type = .HTML;
    res.header("connection", "close");
}

const CANVAS_CSS =
    \\html,body{margin:0;padding:0;height:100%;overflow:hidden;background:#0d1117;color:#e0e0e0;font-family:system-ui,sans-serif;touch-action:none}
    \\.toolbar{display:flex;gap:6px;padding:6px 12px;background:#161b22;border-bottom:1px solid #21262d;align-items:center;flex-wrap:wrap}
    \\.toolbar-title{font-size:15px;font-weight:600;color:#e0e0e0;margin-right:4px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:200px}
    \\.canvas-btn{padding:6px 14px;border:1px solid #30363d;background:#21262d;color:#c9d1d9;border-radius:4px;cursor:pointer;font-size:13px;text-decoration:none;white-space:nowrap;min-height:36px;display:inline-flex;align-items:center}
    \\.canvas-btn:hover{background:#30363d;border-color:#58a6ff}
    \\.search-container{position:relative;margin-left:auto;flex-shrink:1;min-width:0}
    \\.search-input{padding:6px 10px;border:1px solid #30363d;background:#0d1117;color:#c9d1d9;border-radius:4px;font-size:14px;width:100%;max-width:220px;min-height:36px;box-sizing:border-box}
    \\.search-input:focus{border-color:#4a9eff}
    \\.search-input::placeholder{color:#555}
    \\.search-results{position:absolute;top:100%;left:0;right:0;background:#161b22;border:1px solid #30363d;border-radius:0 0 4px 4px;max-height:300px;overflow-y:auto;display:none;z-index:100;min-width:220px}
    \\.search-results.open{display:block}
    \\.search-result{padding:8px 10px;cursor:pointer;font-size:13px;font-family:monospace;color:#c9d1d9;border-bottom:1px solid #21262d;display:flex;justify-content:space-between}
    \\.search-result:hover,.search-result.selected{background:#30363d}
    \\.search-result-type{font-size:11px;color:#888;text-transform:uppercase}
    \\.search-result-type.net{color:#e8c547}
    \\.search-result-type.comp{color:#4a9eff}
    \\.search-result-type.section{color:#3fb950}
    \\.search-result-type.pin{color:#c084fc}
    \\.main-area{display:flex;height:calc(100vh - 42px - 37px);overflow:hidden}
    \\.canvas-fill{flex:1;min-width:0;background:#0d1117}
    \\.sidebar{width:320px;min-width:320px;height:100%;background:#161b22;border-left:1px solid #30363d;padding:16px;overflow-y:auto;overflow-x:hidden;box-sizing:border-box}
    \\.sidebar::-webkit-scrollbar{width:6px}
    \\.sidebar::-webkit-scrollbar-track{background:#0d1117}
    \\.sidebar::-webkit-scrollbar-thumb{background:#30363d;border-radius:3px}
    \\.sidebar::-webkit-scrollbar-thumb:hover{background:#484f58}
    \\.sidebar-empty{color:#555;font-size:13px;font-style:italic;padding-top:8px}
    \\.sec-item{padding:10px 12px;border-bottom:1px solid #21262d;cursor:pointer;border-radius:4px;margin-bottom:2px}
    \\.sec-item:hover{background:#1a2e1a}
    \\.sec-item-name{font-size:14px;color:#3fb950;font-weight:500}
    \\.sec-item-desc{font-size:12px;color:#6e7681;margin-top:2px;font-style:italic}
    \\.kicad-menu{position:relative;display:inline-block}
    \\.kicad-panel{display:none;position:absolute;top:calc(100% + 4px);right:0;background:#161b22;border:1px solid #30363d;border-radius:6px;padding:10px;width:300px;z-index:200;box-shadow:0 4px 12px rgba(0,0,0,0.4)}
    \\.kicad-menu.open .kicad-panel{display:flex;flex-direction:column;gap:6px}
    \\.kicad-row-btn{padding:6px 10px;border:1px solid #30363d;background:#21262d;color:#c9d1d9;border-radius:4px;cursor:pointer;font-size:12px;text-align:left}
    \\.kicad-row-btn:hover{background:#30363d;border-color:#58a6ff}
    \\.kicad-sep{border-top:1px solid #30363d;margin:4px 0}
    \\.kicad-label{font-size:11px;color:#8b949e;text-transform:uppercase;letter-spacing:.5px}
    \\.kicad-input{padding:6px 8px;border:1px solid #30363d;background:#0d1117;color:#c9d1d9;border-radius:4px;font-size:12px;font-family:monospace}
    \\.kicad-input:focus{border-color:#4a9eff;outline:none}
    \\.kicad-status{font-size:11px;color:#8b949e;min-height:14px;word-break:break-all}
    \\.kicad-status.ok{color:#3fb950}
    \\.kicad-status.err{color:#f85149}
    \\.kicad-check{font-size:12px;color:#c9d1d9;display:flex;align-items:center;gap:6px;margin:2px 0}
    \\.kicad-primary{background:#1f6feb;border-color:#388bfd;color:#fff}
    \\.kicad-primary:hover{background:#388bfd;border-color:#58a6ff}
    \\#pixi-container canvas{display:block;touch-action:none}
    \\@media(max-width:768px){
    \\.toolbar{padding:4px 8px;gap:4px}
    \\.toolbar-title{max-width:120px;font-size:13px}
    \\.canvas-btn{padding:6px 10px;font-size:12px}
    \\.search-container{order:10;flex-basis:100%;margin-left:0}
    \\.search-input{max-width:100%}
    \\.sidebar{display:none}
    \\.main-area{height:calc(100vh - 42px - 37px)}
    \\}
;

const CANVAS_VIEWER_JS = @import("canvas_viewer_js.zig").CANVAS_VIEWER_JS;

const KICAD_MENU_JS =
    \\(function(){
    \\  var menu=document.querySelector('.kicad-menu');
    \\  var btn=document.getElementById('kicad-btn');
    \\  var panel=document.getElementById('kicad-panel');
    \\  var pathInput=document.getElementById('kicad-path');
    \\  var pcbFileInput=document.getElementById('kicad-pcb-file');
    \\  var shortNetsCb=document.getElementById('kicad-short-nets');
    \\  var status=document.getElementById('kicad-status');
    \\  var saveBtn=document.getElementById('kicad-save-path');
    \\  var writeNet=document.getElementById('kicad-write-netlist');
    \\  var writeKicad=document.getElementById('kicad-write-kicad');
    \\  var updatePcb=document.getElementById('kicad-update-pcb');
    \\  if(!menu) return;
    \\  function setStatus(msg,cls){status.textContent=msg||'';status.className='kicad-status'+(cls?' '+cls:'');}
    \\  btn.addEventListener('click',function(e){e.stopPropagation();menu.classList.toggle('open');});
    \\  panel.addEventListener('click',function(e){e.stopPropagation();});
    \\  document.addEventListener('click',function(){menu.classList.remove('open');});
    \\  fetch('/api/kicad-sync-config/'+SCHEMATIC_SLUG).then(function(r){return r.json();}).then(function(j){
    \\    if(j&&j.output_dir)pathInput.value=j.output_dir;
    \\    if(j&&j.pcb_file)pcbFileInput.value=j.pcb_file;
    \\  }).catch(function(){});
    \\  saveBtn.addEventListener('click',function(){
    \\    setStatus('Saving...');
    \\    fetch('/api/kicad-sync-config/'+SCHEMATIC_SLUG,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({output_dir:pathInput.value.trim(),pcb_file:pcbFileInput.value.trim()})})
    \\      .then(function(r){return r.json();}).then(function(j){setStatus(j.ok?'Settings saved':('Error: '+(j.error||'unknown')),j.ok?'ok':'err');})
    \\      .catch(function(e){setStatus('Error: '+e,'err');});
    \\  });
    \\  function doWrite(url,label){
    \\    if(!pathInput.value.trim()){setStatus('Enter an output path first','err');return;}
    \\    setStatus(label+'...');
    \\    fetch(url,{method:'POST'}).then(function(r){return r.json();}).then(function(j){
    \\      if(!j.ok){setStatus('Error: '+(j.error||'unknown'),'err');return;}
    \\      if(j.netlist&&j.pretty){setStatus('Wrote '+j.netlist+' and '+j.pretty,'ok');}
    \\      else if(j.pcb){setStatus('Updated '+j.pcb,'ok');}
    \\      else if(j.path){setStatus('Wrote '+j.path,'ok');}
    \\      else{setStatus('Done','ok');}
    \\    }).catch(function(e){setStatus('Error: '+e,'err');});
    \\  }
    \\  writeNet.addEventListener('click',function(){doWrite('/api/export-netlist-to-dir/'+SCHEMATIC_SLUG,'Writing netlist');});
    \\  writeKicad.addEventListener('click',function(){doWrite('/api/export-kicad-to-dir/'+SCHEMATIC_SLUG,'Writing netlist + footprints');});
    \\  updatePcb.addEventListener('click',function(){
    \\    var url='/api/update-kicad-pcb/'+SCHEMATIC_SLUG;
    \\    if(shortNetsCb.checked)url+='?short-nets=1';
    \\    doWrite(url,'Updating KiCad PCB');
    \\  });
    \\})();
;
