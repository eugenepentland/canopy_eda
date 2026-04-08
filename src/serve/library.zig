const std = @import("std");
const httpz = @import("httpz");
const export_kicad = @import("../export_kicad.zig");
const footprint_mod = @import("../export_kicad_footprint.zig");
const serve_root = @import("../serve.zig");
const Handler = serve_root.Handler;
const assets_css = @import("assets_css.zig");
const footprint_preview = @import("footprint_preview.zig");

/// Scan lib/components/ for passive families and write a JSON object
/// mapping type prefixes (cap, res, ind, led) to arrays of family names.
pub fn writeFamiliesJson(w: anytype, allocator: std.mem.Allocator, project_dir: []const u8) !void {
    const comp_dir_path = try std.fmt.allocPrint(allocator, "{s}/lib/components", .{project_dir});
    defer allocator.free(comp_dir_path);

    var dir = std.fs.cwd().openDir(comp_dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    const prefixes = [_][]const u8{ "cap", "res", "ind", "led" };
    var lists: [4]std.ArrayListUnmanaged([]const u8) = .{ .empty, .empty, .empty, .empty };

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        const fname = entry.name;
        if (!std.mem.endsWith(u8, fname, ".sexp")) continue;
        const base = fname[0 .. fname.len - 5];
        for (prefixes, 0..) |pfx, pi| {
            if (std.mem.startsWith(u8, base, pfx) and base.len > pfx.len and base[pfx.len] == '-') {
                try lists[pi].append(allocator, try allocator.dupe(u8, base));
                break;
            }
        }
    }

    var first_prefix = true;
    for (prefixes, 0..) |pfx, pi| {
        if (lists[pi].items.len == 0) continue;
        if (!first_prefix) try w.writeAll(",");
        first_prefix = false;
        try w.writeAll("\"");
        try w.writeAll(pfx);
        try w.writeAll("\":[");
        std.mem.sort([]const u8, lists[pi].items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);
        for (lists[pi].items, 0..) |fam, fi| {
            if (fi > 0) try w.writeAll(",");
            try w.writeAll("\"");
            try w.writeAll(fam);
            try w.writeAll("\"");
        }
        try w.writeAll("]");
    }
}

pub fn libraryPage(ctx: *Handler, _: *httpz.Request, res: *httpz.Response) !void {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(ctx.allocator);

    try w.writeAll(
        \\<!DOCTYPE html><html><head><title>Component Library</title><style>
    );
    try w.writeAll(assets_css.NAVBAR_CSS);
    try w.writeAll(
        \\body { font-family: system-ui, sans-serif; margin: 0; padding: 0; color: #e0e0e0; background: #121212; }
        \\.lib-content { max-width: 1000px; margin: 0 auto; padding: 2rem; }
        \\h1,h2,h3 { color: #fff; }
        \\a { color: #58a6ff; text-decoration: none; }
        \\.upload-box { background: #1a1a2e; border: 2px dashed #333; border-radius: 8px; padding: 2rem; margin: 1rem 0; text-align: center; }
        \\.upload-box.dragover { border-color: #4a9eff; background: #16213e; }
        \\.upload-box input[type=file] { display: none; }
        \\.upload-btn { background: #2a4a2a; color: #4a9; border: 1px solid #4a9; border-radius: 4px; padding: 0.5rem 1.5rem; font-size: 0.9rem; cursor: pointer; }
        \\.upload-btn:hover { background: #3a5a3a; }
        \\.result { margin: 1rem 0; padding: 1rem; border-radius: 6px; font-family: monospace; font-size: 0.85rem; white-space: pre-wrap; overflow-x: auto; }
        \\.result.ok { background: #1a2e1a; border: 1px solid #3fb950; color: #3fb950; }
        \\.result.err { background: #2e1a1a; border: 1px solid #f85149; color: #f85149; }
        \\table { width: 100%; border-collapse: collapse; margin: 1rem 0; }
        \\th,td { text-align: left; padding: 0.5rem 0.75rem; border-bottom: 1px solid #21262d; }
        \\th { background: #1a1a2e; color: #888; font-size: 0.85rem; text-transform: uppercase; }
        \\td { font-family: monospace; font-size: 0.9rem; }
        \\.search-box { width: 100%; padding: 0.75rem 1rem; font-size: 1.1rem; background: #1a1a2e; color: #e0e0e0; border: 1px solid #333; border-radius: 6px; margin-bottom: 1.5rem; box-sizing: border-box; font-family: monospace; }
        \\.search-box:focus { outline: none; border-color: #58a6ff; }
        \\.search-box::placeholder { color: #555; }
        \\.tag { display: inline-block; font-size: 0.75rem; padding: 0.15rem 0.5rem; border-radius: 3px; margin-right: 0.3rem; }
        \\.tag-component { background: #1a2e1a; color: #3fb950; }
        \\.tag-family { background: #2e2a1a; color: #d29922; }
        \\.tag-pinout { background: #1a1a2e; color: #58a6ff; }
        \\.tag-footprint { background: #2e1a2e; color: #bc8cff; }
        \\.meta { color: #666; font-size: 0.8rem; }
        \\.desc { color: #999; font-size: 0.85rem; font-family: system-ui, sans-serif; }
        \\.count-info { color: #666; font-size: 0.85rem; margin-bottom: 1rem; }
        \\</style></head><body>
    );
    try assets_css.writeNavbar(w, "library");
    try w.writeAll("<div class=\"lib-content\"><h1>Component Library</h1>");
    try w.writeAll("<input type=\"text\" class=\"search-box\" id=\"lib-search\" placeholder=\"Search components, footprints, pinouts...\" autofocus>");
    try w.writeAll("<div class=\"count-info\" id=\"count-info\"></div>");

    // Main results table
    try w.writeAll("<table id=\"lib-table\"><thead><tr><th>Name</th><th>Type</th><th>Details</th></tr></thead><tbody>");

    // Track which pinouts/footprints are referenced by components
    var referenced_pinouts = std.StringHashMap(void).init(ctx.allocator);
    var referenced_footprints = std.StringHashMap(void).init(ctx.allocator);

    // Load model config once for 3D model checks
    const model_cfg = export_kicad.loadModelConfig(ctx.allocator, ctx.project_dir);

    // Collect all component entries
    const comp_dir_path = try std.fmt.allocPrint(ctx.allocator, "{s}/lib/components", .{ctx.project_dir});
    defer ctx.allocator.free(comp_dir_path);
    if (std.fs.cwd().openDir(comp_dir_path, .{ .iterate = true })) |dir_val| {
        var dir = dir_val;
        defer dir.close();
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".sexp")) continue;
            const base = entry.name[0 .. entry.name.len - 5];
            const content = dir.readFileAlloc(ctx.allocator, entry.name, 256 * 1024) catch continue;

            // Parse fields from sexp content
            const description = extractField(content, "description");
            const footprint = extractField(content, "footprint");
            const pinout = extractField(content, "pinout");
            const manufacturer = extractField(content, "manufacturer");
            const mpn = extractField(content, "mpn");
            const is_family = std.mem.indexOf(u8, content, "(component-family ") != null;

            if (footprint) |fp| try referenced_footprints.put(fp, {});
            if (pinout) |po| try referenced_pinouts.put(po, {});

            // Write row with data attributes for search
            try w.print("<tr data-search=\"{s}", .{base});
            if (description) |d| try w.print(" {s}", .{d});
            if (footprint) |fp| try w.print(" {s}", .{fp});
            if (pinout) |po| try w.print(" {s}", .{po});
            if (manufacturer) |m| try w.print(" {s}", .{m});
            if (mpn) |m| try w.print(" {s}", .{m});
            try w.writeAll("\">");

            // Name column
            try w.print("<td>{s}</td>", .{base});

            // Type column
            if (is_family) {
                try w.writeAll("<td><span class=\"tag tag-family\">family</span></td>");
            } else {
                try w.writeAll("<td><span class=\"tag tag-component\">component</span></td>");
            }

            // Details column
            try w.writeAll("<td>");
            if (description) |d| try w.print("<span class=\"desc\">{s}</span><br>", .{d});
            if (footprint) |fp| {
                try w.print("<span class=\"meta\">footprint: </span><span class=\"tag tag-footprint\">{s}</span> ", .{fp});
                const has_model = blk: {
                    if (model_cfg.get(fp)) |c| {
                        if (c.model != null) break :blk true;
                    }
                    break :blk footprint_mod.findModelFile(ctx.allocator, ctx.project_dir, fp, fp) != null;
                };
                if (has_model) {
                    try w.print("<a href=\"/model-viewer/{s}\" style=\"color:#58a6ff;font-size:0.8rem;\">3D</a> ", .{fp});
                } else {
                    try w.print("<a href=\"/model-viewer/{s}\" style=\"color:#444;font-size:0.8rem;\" title=\"Upload 3D model\">+ 3D</a> ", .{fp});
                }
            }
            if (pinout) |po| try w.print("<span class=\"meta\">pinout: </span><span class=\"tag tag-pinout\">{s}</span> ", .{po});
            if (manufacturer) |m| {
                try w.print("<span class=\"meta\">mfr: {s}</span> ", .{m});
            }
            if (mpn) |m| {
                try w.print("<span class=\"meta\">mpn: {s}</span>", .{m});
            }
            try w.writeAll("</td></tr>");
        }
    } else |_| {}

    // Add standalone pinouts (not referenced by any component)
    {
        const pinout_path = try std.fmt.allocPrint(ctx.allocator, "{s}/lib/pinouts", .{ctx.project_dir});
        defer ctx.allocator.free(pinout_path);
        if (std.fs.cwd().openDir(pinout_path, .{ .iterate = true })) |dir_val| {
            var dir = dir_val;
            defer dir.close();
            var liter = dir.iterate();
            while (try liter.next()) |entry| {
                if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".sexp")) continue;
                const lname = entry.name[0 .. entry.name.len - 5];
                if (referenced_pinouts.contains(lname)) continue;
                const content = dir.readFileAlloc(ctx.allocator, entry.name, 256 * 1024) catch continue;
                var pin_count: usize = 0;
                var pos: usize = 0;
                while (std.mem.indexOfPos(u8, content, pos, "(pin ")) |idx| {
                    pin_count += 1;
                    pos = idx + 5;
                }
                try w.print("<tr data-search=\"{s} pinout\"><td>{s}</td>", .{ lname, lname });
                try w.writeAll("<td><span class=\"tag tag-pinout\">pinout</span></td>");
                try w.print("<td><span class=\"meta\">{d} pins</span></td></tr>", .{pin_count});
            }
        } else |_| {}
    }

    // Add standalone footprints (not referenced by any component)
    {
        const fp_path = try std.fmt.allocPrint(ctx.allocator, "{s}/lib/footprints", .{ctx.project_dir});
        defer ctx.allocator.free(fp_path);
        if (std.fs.cwd().openDir(fp_path, .{ .iterate = true })) |dir_val| {
            var dir = dir_val;
            defer dir.close();
            var fiter = dir.iterate();
            while (try fiter.next()) |entry| {
                if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".sexp")) continue;
                const fname = entry.name[0 .. entry.name.len - 5];
                if (referenced_footprints.contains(fname)) continue;
                try w.print("<tr data-search=\"{s} footprint\"><td>{s}</td>", .{ fname, fname });
                try w.writeAll("<td><span class=\"tag tag-footprint\">footprint</span></td>");
                try w.writeAll("<td></td></tr>");
            }
        } else |_| {}
    }

    try w.writeAll("</tbody></table>");

    // Upload section (collapsed by default)
    try w.writeAll(
        \\<details id="upload-section" style="margin-top:2rem;"><summary style="color:#58a6ff;font-size:0.95rem;cursor:pointer;">Upload New Component</summary>
        \\<div class="upload-box" id="zip-drop" style="margin:1rem 0;">
        \\<p style="font-size:0.85rem;">Drop a component .zip (auto-extracts KiCad symbol, footprint, and 3D model)</p>
        \\<label class="upload-btn">Choose .zip<input type="file" id="zip-file" accept=".zip"></label>
        \\<div id="zip-name" style="color:#4a9;font-size:0.8rem;margin-top:0.5rem;"></div>
        \\</div>
        \\<div id="zip-result"></div>
        \\<details style="margin-bottom:1rem;"><summary style="color:#666;font-size:0.85rem;cursor:pointer;">Or upload files individually</summary>
        \\<div style="display:flex;gap:1rem;margin:1rem 0;">
        \\<div class="upload-box" id="sym-drop" style="flex:1;">
        \\<p style="font-size:0.85rem;">Symbol (.kicad_sym)</p>
        \\<label class="upload-btn">Choose file<input type="file" id="sym-file" accept=".kicad_sym"></label>
        \\<div id="sym-name" style="color:#4a9;font-size:0.8rem;margin-top:0.5rem;"></div>
        \\</div>
        \\<div class="upload-box" id="fp-drop" style="flex:1;">
        \\<p style="font-size:0.85rem;">Footprint (.kicad_mod)</p>
        \\<label class="upload-btn">Choose file<input type="file" id="fp-file" accept=".kicad_mod"></label>
        \\<div id="fp-name" style="color:#4a9;font-size:0.8rem;margin-top:0.5rem;"></div>
        \\</div>
        \\<div class="upload-box" id="step-drop" style="flex:1;">
        \\<p style="font-size:0.85rem;">3D Model (.step) <span style="color:#666;">optional</span></p>
        \\<label class="upload-btn">Choose file<input type="file" id="step-file" accept=".step,.stp"></label>
        \\<div id="step-name" style="color:#4a9;font-size:0.8rem;margin-top:0.5rem;"></div>
        \\</div>
        \\</div>
        \\<div style="margin-bottom:1rem;">
        \\<button id="pkg-submit" class="upload-btn" disabled style="opacity:0.5;">Create Package</button>
        \\</div>
        \\<div id="pkg-result"></div>
        \\</details>
        \\</details>
    );

    // JS: search + upload
    try w.writeAll(
        \\<script>
        \\(function(){
        \\  var input=document.getElementById('lib-search');
        \\  var rows=document.querySelectorAll('#lib-table tbody tr');
        \\  var info=document.getElementById('count-info');
        \\  var upload=document.getElementById('upload-section');
        \\  info.textContent=rows.length+' items';
        \\  input.addEventListener('input',function(){
        \\    var q=this.value.toLowerCase().trim();
        \\    var terms=q.split(/\s+/);
        \\    var shown=0;
        \\    for(var i=0;i<rows.length;i++){
        \\      var s=rows[i].getAttribute('data-search').toLowerCase();
        \\      var match=true;
        \\      for(var t=0;t<terms.length;t++){if(terms[t]&&s.indexOf(terms[t])<0){match=false;break;}}
        \\      rows[i].style.display=match?'':'none';
        \\      if(match)shown++;
        \\    }
        \\    info.textContent=q?(shown+' of '+rows.length+' items'):(rows.length+' items');
        \\    upload.style.display=q?'none':'';
        \\  });
        \\})();
        \\var symData=null,fpData=null,stepData=null,symFilename='',fpFilename='',stepFilename='';
        \\function setupDrop(dropId,fileId,nameId,ext,onFile){
        \\  var drop=document.getElementById(dropId),fi=document.getElementById(fileId),nd=document.getElementById(nameId);
        \\  drop.addEventListener('dragover',function(e){e.preventDefault();drop.classList.add('dragover');});
        \\  drop.addEventListener('dragleave',function(){drop.classList.remove('dragover');});
        \\  drop.addEventListener('drop',function(e){e.preventDefault();drop.classList.remove('dragover');if(e.dataTransfer.files.length>0)loadFile(e.dataTransfer.files[0]);});
        \\  fi.addEventListener('change',function(){if(this.files.length>0)loadFile(this.files[0]);});
        \\  function loadFile(f){
        \\    nd.textContent=f.name;
        \\    var r=new FileReader();r.onload=function(){onFile(f.name,r.result);checkReady();};r.readAsArrayBuffer(f);
        \\  }
        \\}
        \\setupDrop('sym-drop','sym-file','sym-name','.kicad_sym',function(n,d){symFilename=n;symData=d;});
        \\setupDrop('fp-drop','fp-file','fp-name','.kicad_mod',function(n,d){fpFilename=n;fpData=d;});
        \\setupDrop('step-drop','step-file','step-name','.step',function(n,d){stepFilename=n;stepData=d;});
        \\var submitBtn=document.getElementById('pkg-submit'),pkgResult=document.getElementById('pkg-result');
        \\function checkReady(){
        \\  var ready=symData&&fpData;
        \\  submitBtn.disabled=!ready;submitBtn.style.opacity=ready?'1':'0.5';
        \\}
        \\submitBtn.addEventListener('click',function(){
        \\  if(!symData||!fpData)return;
        \\  submitBtn.disabled=true;submitBtn.textContent='Creating...';
        \\  pkgResult.className='result';pkgResult.textContent='Uploading and converting...';
        \\  var formData=new FormData();
        \\  formData.append('symbol',new Blob([symData]),symFilename);
        \\  formData.append('footprint',new Blob([fpData]),fpFilename);
        \\  if(stepData)formData.append('step',new Blob([stepData]),stepFilename);
        \\  fetch('/api/upload-package',{method:'POST',body:formData})
        \\    .then(function(r){return r.text().then(function(t){return{ok:r.ok,text:t};});})
        \\    .then(function(d){pkgResult.className=d.ok?'result ok':'result err';pkgResult.textContent=d.text;submitBtn.textContent='Create Package';submitBtn.disabled=false;if(d.ok)setTimeout(function(){location.reload();},1000);})
        \\    .catch(function(e){pkgResult.className='result err';pkgResult.textContent='Error: '+e;submitBtn.textContent='Create Package';submitBtn.disabled=false;});
        \\});
        \\var zipDrop=document.getElementById('zip-drop'),zipFile=document.getElementById('zip-file'),zipName=document.getElementById('zip-name'),zipResult=document.getElementById('zip-result');
        \\zipDrop.addEventListener('dragover',function(e){e.preventDefault();zipDrop.classList.add('dragover');});
        \\zipDrop.addEventListener('dragleave',function(){zipDrop.classList.remove('dragover');});
        \\zipDrop.addEventListener('drop',function(e){e.preventDefault();zipDrop.classList.remove('dragover');if(e.dataTransfer.files.length>0)uploadZip(e.dataTransfer.files[0]);});
        \\zipFile.addEventListener('change',function(){if(this.files.length>0)uploadZip(this.files[0]);});
        \\function uploadZip(file){
        \\  zipName.textContent=file.name;
        \\  zipResult.className='result';zipResult.textContent='Extracting and converting '+file.name+'...';
        \\  var r=new FileReader();r.onload=function(){
        \\    fetch('/api/upload-zip',{method:'POST',headers:{'Content-Type':'application/octet-stream','X-Filename':file.name},body:r.result})
        \\      .then(function(r){return r.text().then(function(t){return{ok:r.ok,text:t};});})
        \\      .then(function(d){zipResult.className=d.ok?'result ok':'result err';zipResult.textContent=d.text;if(d.ok)setTimeout(function(){location.reload();},1500);})
        \\      .catch(function(e){zipResult.className='result err';zipResult.textContent='Error: '+e;});
        \\  };r.readAsArrayBuffer(file);
        \\}
        \\</script>
    );

    try w.writeAll("</div></body></html>");
    res.body = buf.items;
    res.content_type = .HTML;
}

/// Extract a field value from sexp content, e.g. (footprint abc) -> "abc" or (description "foo bar") -> "foo bar"
fn extractField(content: []const u8, field: []const u8) ?[]const u8 {
    // Search for (field followed by space
    var pos: usize = 0;
    while (pos < content.len) {
        const needle_start = std.mem.indexOfPos(u8, content, pos, "(") orelse return null;
        const after_paren = needle_start + 1;
        if (after_paren >= content.len) return null;
        if (std.mem.startsWith(u8, content[after_paren..], field)) {
            const after_field = after_paren + field.len;
            if (after_field < content.len and content[after_field] == ' ') {
                const val_start = after_field + 1;
                if (val_start >= content.len) return null;
                if (content[val_start] == '"') {
                    // Quoted value
                    const quote_end = std.mem.indexOfPos(u8, content, val_start + 1, "\"") orelse return null;
                    return content[val_start + 1 .. quote_end];
                } else {
                    // Unquoted value - ends at ) or space
                    var end = val_start;
                    while (end < content.len and content[end] != ')' and content[end] != ' ' and content[end] != '\n') : (end += 1) {}
                    if (end > val_start) return content[val_start..end];
                }
            }
        }
        pos = needle_start + 1;
    }
    return null;
}
