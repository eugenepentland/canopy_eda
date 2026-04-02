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
        \\.lib-content { max-width: 900px; margin: 0 auto; padding: 2rem; }
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
        \\.lib-list { list-style: none; padding: 0; }
        \\.lib-list li { padding: 0.4rem 0.75rem; border-bottom: 1px solid #21262d; font-family: monospace; font-size: 0.9rem; }
        \\table { width: 100%; border-collapse: collapse; margin: 1rem 0; }
        \\th,td { text-align: left; padding: 0.4rem 0.75rem; border-bottom: 1px solid #21262d; }
        \\th { background: #1a1a2e; color: #888; font-size: 0.85rem; text-transform: uppercase; }
        \\td { font-family: monospace; font-size: 0.9rem; }
        \\</style></head><body>
    );
    try assets_css.writeNavbar(w, "library");
    try w.writeAll("<div class=\"lib-content\"><h1>Component Library</h1>");

    // Upload section
    try w.writeAll(
        \\<h2>Create Package</h2>
        \\<div class="upload-box" id="zip-drop" style="margin-bottom:1rem;">
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
    );

    // List existing pinouts
    try w.writeAll("<h2>Pinouts</h2><table><tr><th>Name</th><th>Pins</th></tr>");
    {
        const pinout_path = try std.fmt.allocPrint(ctx.allocator, "{s}/lib/pinouts", .{ctx.project_dir});
        defer ctx.allocator.free(pinout_path);
        var dir = std.fs.cwd().openDir(pinout_path, .{ .iterate = true }) catch {
            try w.writeAll("<tr><td colspan=\"2\">No pinouts yet</td></tr>");
            try w.writeAll("</table>");
            try footprint_preview.listFootprints(w, ctx);
            try w.writeAll("</div></body></html>");
            res.body = buf.items;
            res.content_type = .HTML;
            return;
        };
        defer dir.close();
        var liter = dir.iterate();
        while (try liter.next()) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".sexp")) {
                const lname = entry.name[0 .. entry.name.len - 5];
                const content = dir.readFileAlloc(ctx.allocator, entry.name, 256 * 1024) catch continue;
                var pin_count: usize = 0;
                var pos: usize = 0;
                while (std.mem.indexOfPos(u8, content, pos, "(pin ")) |idx| {
                    pin_count += 1;
                    pos = idx + 5;
                }
                try w.print("<tr><td>{s}</td><td>{d}</td></tr>", .{ lname, pin_count });
            }
        }
    }
    try w.writeAll("</table>");
    try footprint_preview.listFootprints(w, ctx);

    // Upload JS
    try w.writeAll(
        \\<script>
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
        \\/* Zip upload */
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
