const std = @import("std");
const httpz = @import("httpz");
const parser_mod = @import("../sexpr/parser.zig");
const footprint_mod = @import("../export_kicad_footprint.zig");
const serve_root = @import("../serve.zig");
const Handler = serve_root.Handler;
const assets_css = @import("assets_css.zig");

// ── Model config mutex ────────────────────────────────────────────────

pub var model_config_mutex: std.Thread.Mutex = .{};

// ── Model API endpoints ──────────────────────────────────────────────

pub fn modelFileApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    const path = std.fmt.allocPrint(ctx.allocator, "{s}/lib/models/{s}", .{ ctx.project_dir, name }) catch {
        res.status = 500;
        return;
    };
    defer ctx.allocator.free(path);
    const content = std.fs.cwd().readFileAlloc(ctx.allocator, path, 50 * 1024 * 1024) catch {
        res.status = 404;
        res.body = "Model not found";
        return;
    };
    res.body = content;
    res.content_type = .BINARY;
}

pub fn modelConfigGetApi(ctx: *Handler, _: *httpz.Request, res: *httpz.Response) !void {
    model_config_mutex.lock();
    defer model_config_mutex.unlock();
    const path = std.fmt.allocPrint(ctx.allocator, "{s}/lib/models/model-config.json", .{ctx.project_dir}) catch {
        res.status = 500;
        return;
    };
    defer ctx.allocator.free(path);
    const content = std.fs.cwd().readFileAlloc(ctx.allocator, path, 1024 * 1024) catch {
        res.body = "{}";
        res.content_type = .JSON;
        return;
    };
    res.body = content;
    res.content_type = .JSON;
}

pub fn modelConfigPostApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const body = req.body() orelse {
        res.status = 400;
        res.body = "no body";
        return;
    };

    const fp_start = std.mem.indexOf(u8, body, "\"footprint\":\"") orelse {
        res.status = 400;
        res.body = "missing footprint";
        return;
    };
    const fp_val_start = fp_start + 13;
    const fp_end = std.mem.indexOfPos(u8, body, fp_val_start, "\"") orelse {
        res.status = 400;
        return;
    };
    const footprint = body[fp_val_start..fp_end];

    const off_start = std.mem.indexOf(u8, body, "\"offset\":[") orelse {
        res.status = 400;
        res.body = "missing offset";
        return;
    };
    const off_arr_start = off_start + 10;
    const off_arr_end = std.mem.indexOfPos(u8, body, off_arr_start, "]") orelse {
        res.status = 400;
        return;
    };
    const off_str = body[off_arr_start..off_arr_end];

    const rot_start = std.mem.indexOf(u8, body, "\"rotation\":[") orelse {
        res.status = 400;
        res.body = "missing rotation";
        return;
    };
    const rot_arr_start = rot_start + 12;
    const rot_arr_end = std.mem.indexOfPos(u8, body, rot_arr_start, "]") orelse {
        res.status = 400;
        return;
    };
    const rot_str = body[rot_arr_start..rot_arr_end];

    model_config_mutex.lock();
    defer model_config_mutex.unlock();

    const config_path = std.fmt.allocPrint(ctx.allocator, "{s}/lib/models/model-config.json", .{ctx.project_dir}) catch {
        res.status = 500;
        return;
    };
    defer ctx.allocator.free(config_path);
    const existing = std.fs.cwd().readFileAlloc(ctx.allocator, config_path, 1024 * 1024) catch null;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(ctx.allocator);
    const entry_str = std.fmt.allocPrint(ctx.allocator, "\"{s}\":{{\"offset\":[{s}],\"rotation\":[{s}]}}", .{ footprint, off_str, rot_str }) catch {
        res.status = 500;
        return;
    };
    defer ctx.allocator.free(entry_str);

    if (existing) |ex| {
        defer ctx.allocator.free(ex);
        const key_marker = std.fmt.allocPrint(ctx.allocator, "\"{s}\":", .{footprint}) catch {
            res.status = 500;
            return;
        };
        defer ctx.allocator.free(key_marker);

        if (std.mem.indexOf(u8, ex, key_marker)) |key_pos| {
            var depth: u32 = 0;
            var entry_end: usize = key_pos;
            var found_obj = false;
            for (ex[key_pos..], 0..) |c, i| {
                if (c == '{') {
                    depth += 1;
                    found_obj = true;
                }
                if (c == '}') {
                    depth -= 1;
                    if (found_obj and depth == 0) {
                        entry_end = key_pos + i + 1;
                        break;
                    }
                }
            }
            try w.writeAll(ex[0..key_pos]);
            try w.writeAll(entry_str);
            try w.writeAll(ex[entry_end..]);
        } else {
            if (std.mem.lastIndexOf(u8, ex, "}")) |ci| {
                const before = std.mem.trimRight(u8, ex[0..ci], " \t\n\r");
                try w.writeAll(before);
                if (before.len > 1) try w.writeAll(",");
                try w.writeAll("\n  ");
                try w.writeAll(entry_str);
                try w.writeAll("\n}");
            } else {
                try w.writeAll("{\n  ");
                try w.writeAll(entry_str);
                try w.writeAll("\n}");
            }
        }
    } else {
        try w.writeAll("{\n  ");
        try w.writeAll(entry_str);
        try w.writeAll("\n}");
    }

    const f = std.fs.cwd().createFile(config_path, .{}) catch {
        res.status = 500;
        res.body = "cannot write config";
        return;
    };
    defer f.close();
    f.writeAll(buf.items) catch {
        res.status = 500;
        return;
    };

    res.body = "{\"ok\":true}";
    res.content_type = .JSON;
}

pub fn uploadModelApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    const body = req.body() orelse {
        res.status = 400;
        res.body = "no body";
        return;
    };
    if (body.len == 0) {
        res.status = 400;
        res.body = "empty file";
        return;
    }

    const models_dir = std.fmt.allocPrint(ctx.allocator, "{s}/lib/models", .{ctx.project_dir}) catch {
        res.status = 500;
        return;
    };
    defer ctx.allocator.free(models_dir);
    std.fs.cwd().makePath(models_dir) catch {};

    const model_path = std.fmt.allocPrint(ctx.allocator, "{s}/{s}.step", .{ models_dir, name }) catch {
        res.status = 500;
        return;
    };
    defer ctx.allocator.free(model_path);

    const f = std.fs.cwd().createFile(model_path, .{}) catch {
        res.status = 500;
        res.body = "cannot write model";
        return;
    };
    defer f.close();
    f.writeAll(body) catch {
        res.status = 500;
        return;
    };

    std.debug.print("Saved model: lib/models/{s}.step ({d} bytes)\n", .{ name, body.len });
    res.body = "{\"ok\":true}";
    res.content_type = .JSON;
}

// ── 3D Model Viewer Page ─────────────────────────────────────────────

pub fn modelViewerPage(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };

    const fp_path = std.fmt.allocPrint(ctx.allocator, "{s}/lib/footprints/{s}.sexp", .{ ctx.project_dir, name }) catch {
        res.status = 500;
        return;
    };
    defer ctx.allocator.free(fp_path);
    const fp_content = std.fs.cwd().readFileAlloc(ctx.allocator, fp_path, 256 * 1024) catch {
        res.status = 404;
        res.body = "Footprint not found";
        return;
    };
    defer ctx.allocator.free(fp_content);

    const nodes = parser_mod.parse(ctx.allocator, fp_content) catch {
        res.status = 500;
        res.body = "Parse error";
        return;
    };
    if (nodes.len == 0) {
        res.status = 500;
        return;
    }
    const top = nodes[0].asList() orelse {
        res.status = 500;
        return;
    };

    const model_name = footprint_mod.findModelFile(ctx.allocator, ctx.project_dir, name, name);

    const config_path = std.fmt.allocPrint(ctx.allocator, "{s}/lib/models/model-config.json", .{ctx.project_dir}) catch {
        res.status = 500;
        return;
    };
    defer ctx.allocator.free(config_path);
    const config_content = std.fs.cwd().readFileAlloc(ctx.allocator, config_path, 1024 * 1024) catch null;

    var cfg_offset: [3]f64 = .{ 0, 0, 0 };
    var cfg_rotation: [3]f64 = .{ 0, 0, 0 };
    if (config_content) |cc| {
        defer ctx.allocator.free(cc);
        const key_marker = std.fmt.allocPrint(ctx.allocator, "\"{s}\":", .{name}) catch null;
        if (key_marker) |km| {
            defer ctx.allocator.free(km);
            if (std.mem.indexOf(u8, cc, km)) |_| {
                if (std.mem.indexOf(u8, cc, km)) |kp| {
                    const after_key = cc[kp..];
                    if (std.mem.indexOf(u8, after_key, "\"offset\":[")) |os| {
                        const arr_start = os + 10;
                        if (std.mem.indexOfPos(u8, after_key, arr_start, "]")) |arr_end| {
                            cfg_offset = parseFloat3(after_key[arr_start..arr_end]);
                        }
                    }
                    if (std.mem.indexOf(u8, after_key, "\"rotation\":[")) |rs| {
                        const arr_start = rs + 12;
                        if (std.mem.indexOfPos(u8, after_key, arr_start, "]")) |arr_end| {
                            cfg_rotation = parseFloat3(after_key[arr_start..arr_end]);
                        }
                    }
                }
            }
        }
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(ctx.allocator);

    try w.writeAll(
        \\<!DOCTYPE html><html><head><meta charset="utf-8">
        \\<title>3D Model Viewer</title>
        \\<style>
        \\*{margin:0;padding:0;box-sizing:border-box}
        \\body{background:#121212;color:#e0e0e0;font-family:system-ui,sans-serif;display:flex;flex-direction:column;height:100vh;overflow:hidden}
    );
    try w.writeAll(assets_css.NAVBAR_CSS);
    try w.writeAll(
        \\#viewer-main{display:flex;flex:1;overflow:hidden}
        \\#canvas-wrap{flex:1;position:relative}
        \\canvas{display:block;width:100%;height:100%}
        \\#controls{width:280px;padding:20px;background:#1a1a2e;border-left:1px solid #333;overflow-y:auto;display:flex;flex-direction:column;gap:12px}
        \\#controls h1{font-size:16px;color:#7ab}
        \\#controls h2{font-size:13px;color:#999;margin-top:8px}
        \\.field{display:flex;align-items:center;gap:8px}
        \\.field label{width:24px;font-size:12px;color:#888;text-align:right;flex-shrink:0}
        \\.field input{flex:1;background:#0d1117;border:1px solid #333;color:#e0e0e0;padding:4px 6px;border-radius:3px;font-size:13px;font-family:monospace}
        \\#controls button{padding:6px 14px;border:none;border-radius:4px;cursor:pointer;font-size:13px}
        \\#save-btn{background:#238636;color:#fff}
        \\#save-btn:hover{background:#2ea043}
        \\#reset-btn{background:#333;color:#ccc}
        \\#reset-btn:hover{background:#444}
        \\#status{font-size:12px;color:#666;min-height:18px}
        \\.btn-row{display:flex;gap:8px}
        \\#loading{position:absolute;top:50%;left:50%;transform:translate(-50%,-50%);color:#888;font-size:14px}
        \\</style>
        \\</head><body>
    );
    try assets_css.writeNavbar(w, "library");
    try w.writeAll(
        \\<div id="viewer-main">
        \\<div id="canvas-wrap"><div id="loading">Loading 3D model...</div></div>
        \\<div id="controls">
    );
    try w.print("<h1>{s}</h1>", .{name});
    try w.writeAll(
        \\<h2>Offset (mm)</h2>
        \\<div class="field"><label>X</label><input type="number" id="ox" step="0.01" min="-10" max="10"></div>
        \\<div class="field"><label>Y</label><input type="number" id="oy" step="0.01" min="-10" max="10"></div>
        \\<div class="field"><label>Z</label><input type="number" id="oz" step="0.01" min="-10" max="10"></div>
        \\<h2>Rotation (deg)</h2>
        \\<div class="field"><label>X</label><input type="number" id="rx" step="1" min="-180" max="180"></div>
        \\<div class="field"><label>Y</label><input type="number" id="ry" step="1" min="-180" max="180"></div>
        \\<div class="field"><label>Z</label><input type="number" id="rz" step="1" min="-180" max="180"></div>
        \\<div class="btn-row">
        \\<button id="save-btn">Save</button>
        \\<button id="reset-btn">Reset</button>
        \\</div>
        \\<div id="status"></div>
        \\<h2 style="margin-top:16px">3D Model</h2>
        \\<div id="upload-area" style="border:1px dashed #444;border-radius:4px;padding:12px;text-align:center;cursor:pointer" ondragover="event.preventDefault();this.style.borderColor='#58a6ff'" ondragleave="this.style.borderColor='#444'" ondrop="event.preventDefault();this.style.borderColor='#444';handleModelDrop(event.dataTransfer.files[0])">
        \\<div style="font-size:12px;color:#888">Drop .step file or click</div>
        \\<input type="file" id="model-file" accept=".step,.stp" style="display:none">
        \\</div>
        \\<div id="upload-status" style="font-size:12px;min-height:18px"></div>
        \\</div>
        \\<script src="https://cdn.jsdelivr.net/npm/occt-import-js@0.0.23/dist/occt-import-js.js"></script>
        \\<script type="importmap">{"imports":{"three":"https://cdn.jsdelivr.net/npm/three@0.170.0/build/three.module.js","three/addons/":"https://cdn.jsdelivr.net/npm/three@0.170.0/examples/jsm/"}}</script>
        \\<script type="module">
        \\import*as THREE from'three';
        \\import{OrbitControls}from'three/addons/controls/OrbitControls.js';
    );

    try w.print("var FOOTPRINT_NAME='{s}';", .{name});
    if (model_name) |mn| {
        try w.print("var MODEL_FILE='{s}';", .{mn});
    } else {
        try w.writeAll("var MODEL_FILE=null;");
    }

    // Write pad data as JS array
    try w.writeAll("var PADS=[");
    var first_pad = true;
    for (top[1..]) |child| {
        if (child.isForm("pad")) {
            const cl = child.asList() orelse continue;
            if (cl.len < 4) continue;
            const pid: ?[]const u8 = cl[1].asAtom() orelse if (cl[1].asNumber()) |n| (std.fmt.allocPrint(ctx.allocator, "{d}", .{@as(i64, @intFromFloat(n))}) catch null) else null;
            if (pid == null) continue;
            var px: f64 = 0;
            var py: f64 = 0;
            var pw: f64 = 0;
            var ph: f64 = 0;
            const shape: []const u8 = cl[3].asAtom() orelse "rect";
            for (cl[4..]) |sub| {
                if (sub.isForm("pos")) {
                    const sl = sub.asList().?;
                    if (sl.len >= 3) {
                        px = sl[1].asNumber() orelse 0;
                        py = sl[2].asNumber() orelse 0;
                    }
                }
                if (sub.isForm("size")) {
                    const sl = sub.asList().?;
                    if (sl.len >= 3) {
                        pw = sl[1].asNumber() orelse 0;
                        ph = sl[2].asNumber() orelse 0;
                    }
                }
            }
            if (!first_pad) try w.writeAll(",");
            first_pad = false;
            try w.print("{{x:{d:.4},y:{d:.4},w:{d:.4},h:{d:.4},s:\"{s}\"}}", .{ px, py, pw, ph, shape });
        }
    }
    try w.writeAll("];");

    // Write silkscreen data
    try w.writeAll("var SILK_LINES=[");
    var first_line = true;
    for (top[1..]) |child| {
        if (child.isForm("silkscreen")) {
            const cl = child.asList() orelse continue;
            for (cl[1..]) |sub| {
                if (sub.isForm("line")) {
                    const sl = sub.asList() orelse continue;
                    if (sl.len >= 3) {
                        const p1 = sl[1].asList() orelse continue;
                        const p2 = sl[2].asList() orelse continue;
                        if (p1.len >= 2 and p2.len >= 2) {
                            if (!first_line) try w.writeAll(",");
                            first_line = false;
                            try w.print("{{x1:{d:.4},y1:{d:.4},x2:{d:.4},y2:{d:.4}}}", .{
                                p1[0].asNumber() orelse 0, p1[1].asNumber() orelse 0,
                                p2[0].asNumber() orelse 0, p2[1].asNumber() orelse 0,
                            });
                        }
                    }
                }
            }
        }
    }
    try w.writeAll("];");
    try w.writeAll("var SILK_CIRCLES=[");
    var first_circle = true;
    for (top[1..]) |child| {
        if (child.isForm("silkscreen")) {
            const cl = child.asList() orelse continue;
            for (cl[1..]) |sub| {
                if (sub.isForm("circle")) {
                    const sl = sub.asList() orelse continue;
                    if (sl.len >= 3) {
                        const center = sl[1].asList() orelse continue;
                        const radius = sl[2].asNumber() orelse 0;
                        if (center.len >= 2) {
                            if (!first_circle) try w.writeAll(",");
                            first_circle = false;
                            try w.print("{{cx:{d:.4},cy:{d:.4},r:{d:.4}}}", .{
                                center[0].asNumber() orelse 0, center[1].asNumber() orelse 0, radius,
                            });
                        }
                    }
                }
            }
        }
    }
    try w.writeAll("];");

    try w.print("var CFG={{offset:[{d:.4},{d:.4},{d:.4}],rotation:[{d:.4},{d:.4},{d:.4}]}};", .{
        cfg_offset[0],   cfg_offset[1],   cfg_offset[2],
        cfg_rotation[0], cfg_rotation[1], cfg_rotation[2],
    });

    try w.writeAll(MODEL_VIEWER_JS);
    try w.writeAll("</script></div></body></html>");

    res.body = buf.toOwnedSlice(ctx.allocator) catch "";
    res.content_type = .HTML;
}

fn parseFloat3(s: []const u8) [3]f64 {
    var result: [3]f64 = .{ 0, 0, 0 };
    var idx: usize = 0;
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |part| {
        if (idx >= 3) break;
        const trimmed = std.mem.trim(u8, part, " \t\n\r");
        result[idx] = std.fmt.parseFloat(f64, trimmed) catch 0;
        idx += 1;
    }
    return result;
}

const MODEL_VIEWER_JS = @import("model_viewer_js.zig").MODEL_VIEWER_JS;
