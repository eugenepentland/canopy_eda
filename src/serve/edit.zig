const std = @import("std");
const httpz = @import("httpz");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const render_json = @import("../render_json.zig");
const bom = @import("../bom.zig");
const env_mod = @import("../eval/env.zig");
const serve_root = @import("../serve.zig");
const Handler = serve_root.Handler;
const bom_html = @import("bom_html.zig");
const history = @import("history.zig");
const sexpr_parser = @import("../sexpr/parser.zig");

pub fn editValueApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    const body = req.body() orelse {
        res.status = 400;
        res.body = "no body";
        return;
    };

    // Parse JSON: {"ref": "C3", "value": "0.5pF"}
    const ref_start = std.mem.indexOf(u8, body, "\"ref\":\"") orelse {
        res.status = 400;
        res.body = "missing ref";
        return;
    };
    const ref_val_start = ref_start + 7;
    const ref_end = std.mem.indexOfPos(u8, body, ref_val_start, "\"") orelse {
        res.status = 400;
        return;
    };
    const ref_des = body[ref_val_start..ref_end];

    const val_start_marker = std.mem.indexOf(u8, body, "\"value\":\"") orelse {
        res.status = 400;
        res.body = "missing value";
        return;
    };
    const val_start = val_start_marker + 9;
    const val_end = std.mem.indexOfPos(u8, body, val_start, "\"") orelse {
        res.status = 400;
        return;
    };
    const new_value = body[val_start..val_end];

    // Read the .sexp file
    const file_path = std.fmt.allocPrint(ctx.allocator, "{s}/src/{s}.sexp", .{ ctx.project_dir, name }) catch {
        res.status = 500;
        return;
    };
    defer ctx.allocator.free(file_path);

    const source = std.fs.cwd().readFileAlloc(ctx.allocator, file_path, 10 * 1024 * 1024) catch {
        res.status = 500;
        res.body = "cannot read file";
        return;
    };
    defer ctx.allocator.free(source);

    // Find the instance line and replace the value
    const needle = std.fmt.allocPrint(ctx.allocator, "(instance \"{s}\" (", .{ref_des}) catch {
        res.status = 500;
        return;
    };
    defer ctx.allocator.free(needle);

    const inst_pos = std.mem.indexOf(u8, source, needle) orelse {
        res.status = 404;
        res.body = "instance not found";
        return;
    };

    const after_inst = inst_pos + needle.len;
    var pos = after_inst;
    while (pos < source.len and source[pos] != '"' and source[pos] != ')') : (pos += 1) {}

    if (pos >= source.len or source[pos] != '"') {
        res.status = 400;
        res.body = "cannot find value in instance";
        return;
    }

    const old_val_start = pos + 1;
    const old_val_end_pos = std.mem.indexOfPos(u8, source, old_val_start, "\"") orelse {
        res.status = 400;
        return;
    };

    var new_source: std.ArrayListUnmanaged(u8) = .empty;
    const nw = new_source.writer(ctx.allocator);
    try nw.writeAll(source[0..old_val_start]);
    try nw.writeAll(new_value);
    try nw.writeAll(source[old_val_end_pos..]);

    const file = std.fs.cwd().createFile(file_path, .{}) catch {
        res.status = 500;
        res.body = "cannot write file";
        return;
    };
    defer file.close();
    file.writeAll(new_source.items) catch {
        res.status = 500;
        return;
    };

    std.debug.print("Edited {s} {s} -> \"{s}\"\n", .{ name, ref_des, new_value });

    // Rebuild and push live update
    const board_path = std.fmt.allocPrint(ctx.allocator, "{s}/src/{s}.sexp", .{ ctx.project_dir, name }) catch {
        res.status = 500;
        return;
    };
    defer ctx.allocator.free(board_path);

    var eval = Evaluator.init(ctx.allocator, ctx.project_dir);
    defer eval.deinit();
    const result = eval.evalFile(board_path) catch {
        res.status = 500;
        res.body = "rebuild failed";
        return;
    };
    const block = switch (result) {
        .design_block => |b| b,
        else => {
            res.status = 500;
            return;
        },
    };

    const bom_path = std.fmt.allocPrint(ctx.allocator, "{s}/src/{s}.bom", .{ ctx.project_dir, name }) catch {
        res.status = 500;
        return;
    };
    defer ctx.allocator.free(bom_path);
    bom.resolveIdentities(ctx.allocator, block, bom_path, ctx.project_dir) catch {};

    const new_layout = render_json.renderSceneGraph(ctx.allocator, block) catch null;

    serve_root.live_mutex.lock();
    serve_root.live_layout_json = new_layout;
    serve_root.live_mutex.unlock();
    _ = serve_root.bumpLiveVersion(name);

    res.header("access-control-allow-origin", "*");
    res.content_type = .JSON;
    res.body = "{\"ok\":true}";
}

pub fn editFootprintApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    const body = req.body() orelse {
        res.status = 400;
        res.body = "no body";
        return;
    };

    // Parse JSON: {"ref": "C3", "component": "cap-0603", "oldComponent": "cap-0805", "srcOff": 1234}
    const comp_start_marker = std.mem.indexOf(u8, body, "\"component\":\"") orelse {
        res.status = 400;
        res.body = "missing component";
        return;
    };
    const comp_start = comp_start_marker + 13;
    const comp_end = std.mem.indexOfPos(u8, body, comp_start, "\"") orelse {
        res.status = 400;
        return;
    };
    const new_component = body[comp_start..comp_end];

    const old_comp_marker = std.mem.indexOf(u8, body, "\"oldComponent\":\"") orelse {
        res.status = 400;
        res.body = "missing oldComponent";
        return;
    };
    const old_comp_start = old_comp_marker + 16;
    const old_comp_end = std.mem.indexOfPos(u8, body, old_comp_start, "\"") orelse {
        res.status = 400;
        return;
    };
    const old_component = body[old_comp_start..old_comp_end];

    const src_off_marker = std.mem.indexOf(u8, body, "\"srcOff\":") orelse {
        res.status = 400;
        res.body = "missing srcOff";
        return;
    };
    const src_off_num_start = src_off_marker + 9;
    var src_off_num_end = src_off_num_start;
    while (src_off_num_end < body.len and body[src_off_num_end] >= '0' and body[src_off_num_end] <= '9') : (src_off_num_end += 1) {}
    const source_offset = std.fmt.parseInt(usize, body[src_off_num_start..src_off_num_end], 10) catch {
        res.status = 400;
        res.body = "invalid srcOff";
        return;
    };

    // Verify the new component family exists
    const comp_path = std.fmt.allocPrint(ctx.allocator, "{s}/lib/components/{s}.sexp", .{ ctx.project_dir, new_component }) catch {
        res.status = 500;
        return;
    };
    defer ctx.allocator.free(comp_path);
    std.fs.cwd().access(comp_path, .{}) catch {
        res.status = 400;
        res.body = "component family not found";
        return;
    };

    // Read the .sexp file
    const file_path = std.fmt.allocPrint(ctx.allocator, "{s}/src/{s}.sexp", .{ ctx.project_dir, name }) catch {
        res.status = 500;
        return;
    };
    defer ctx.allocator.free(file_path);

    const source = std.fs.cwd().readFileAlloc(ctx.allocator, file_path, 10 * 1024 * 1024) catch {
        res.status = 500;
        res.body = "cannot read file";
        return;
    };
    defer ctx.allocator.free(source);

    if (source_offset + old_component.len > source.len or
        !std.mem.eql(u8, source[source_offset .. source_offset + old_component.len], old_component))
    {
        res.status = 400;
        res.body = "source offset mismatch — file may have changed";
        return;
    }

    var new_source: std.ArrayListUnmanaged(u8) = .empty;
    const nw = new_source.writer(ctx.allocator);
    try nw.writeAll(source[0..source_offset]);
    try nw.writeAll(new_component);
    try nw.writeAll(source[source_offset + old_component.len ..]);

    // Ensure new component is in the import statement
    var final_source = new_source.items;
    if (std.mem.indexOf(u8, final_source, "(import ")) |import_start| {
        var depth: u32 = 0;
        var import_end: usize = import_start;
        for (final_source[import_start..], 0..) |ch, i| {
            if (ch == '(') depth += 1;
            if (ch == ')') {
                depth -= 1;
                if (depth == 0) {
                    import_end = import_start + i;
                    break;
                }
            }
        }
        const import_section = final_source[import_start..import_end];
        const found_in_import = blk: {
            var search_from: usize = 0;
            while (std.mem.indexOfPos(u8, import_section, search_from, new_component)) |ipos| {
                const before_ok = ipos == 0 or import_section[ipos - 1] == ' ' or import_section[ipos - 1] == '\n';
                const after_pos = ipos + new_component.len;
                const after_ok = after_pos >= import_section.len or import_section[after_pos] == ' ' or import_section[after_pos] == '\n' or import_section[after_pos] == ')';
                if (before_ok and after_ok) break :blk true;
                search_from = ipos + 1;
            }
            break :blk false;
        };
        if (!found_in_import) {
            var new_final: std.ArrayListUnmanaged(u8) = .empty;
            const nfw = new_final.writer(ctx.allocator);
            try nfw.writeAll(final_source[0..import_end]);
            try nfw.writeAll(" ");
            try nfw.writeAll(new_component);
            try nfw.writeAll(final_source[import_end..]);
            final_source = new_final.items;
        }
    }

    const file = std.fs.cwd().createFile(file_path, .{}) catch {
        res.status = 500;
        res.body = "cannot write file";
        return;
    };
    defer file.close();
    file.writeAll(final_source) catch {
        res.status = 500;
        return;
    };

    std.debug.print("Edited footprint {s} {s} -> \"{s}\"\n", .{ name, old_component, new_component });

    // Rebuild and push live update
    const board_path = std.fmt.allocPrint(ctx.allocator, "{s}/src/{s}.sexp", .{ ctx.project_dir, name }) catch {
        res.status = 500;
        return;
    };
    defer ctx.allocator.free(board_path);

    var eval = Evaluator.init(ctx.allocator, ctx.project_dir);
    defer eval.deinit();
    const result = eval.evalFile(board_path) catch {
        res.status = 500;
        res.body = "rebuild failed";
        return;
    };
    const block = switch (result) {
        .design_block => |b| b,
        else => {
            res.status = 500;
            return;
        },
    };

    const bom_path = std.fmt.allocPrint(ctx.allocator, "{s}/src/{s}.bom", .{ ctx.project_dir, name }) catch {
        res.status = 500;
        return;
    };
    defer ctx.allocator.free(bom_path);
    bom.resolveIdentities(ctx.allocator, block, bom_path, ctx.project_dir) catch {};

    var svg_sym_cache = try bom_html.buildSymbolPinCache(ctx.allocator, ctx.project_dir);

    const new_layout = render_json.renderSceneGraph(ctx.allocator, block) catch null;

    serve_root.live_mutex.lock();
    serve_root.live_layout_json = new_layout;
    serve_root.live_mutex.unlock();
    _ = serve_root.bumpLiveVersion(name);

    // Return updated COMPONENTS so the client can refresh srcOff values
    var comp_json: std.ArrayListUnmanaged(u8) = .empty;
    const cw = comp_json.writer(ctx.allocator);
    try cw.writeAll("{\"ok\":true,\"components\":{");
    _ = try bom_html.writeComponentsJson(cw, block, "", &svg_sym_cache, ctx.allocator, ctx.project_dir);
    try cw.writeAll("}}");

    res.header("access-control-allow-origin", "*");
    res.content_type = .JSON;
    res.body = comp_json.items;
}

pub fn editCourtyardApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const body = req.body() orelse {
        res.status = 400;
        res.body = "no body";
        return;
    };

    const footprint = parseJsonString(body, "\"footprint\"") orelse {
        res.status = 400;
        res.body = "missing footprint";
        return;
    };
    const x1 = parseJsonFloat(body, "\"x1\"") orelse {
        res.status = 400;
        res.body = "missing x1";
        return;
    };
    const y1 = parseJsonFloat(body, "\"y1\"") orelse {
        res.status = 400;
        res.body = "missing y1";
        return;
    };
    const x2 = parseJsonFloat(body, "\"x2\"") orelse {
        res.status = 400;
        res.body = "missing x2";
        return;
    };
    const y2 = parseJsonFloat(body, "\"y2\"") orelse {
        res.status = 400;
        res.body = "missing y2";
        return;
    };

    // Find footprint file
    const fp_path = try std.fmt.allocPrint(ctx.allocator, "{s}/lib/footprints/{s}.sexp", .{ ctx.project_dir, footprint });
    defer ctx.allocator.free(fp_path);

    const source = std.fs.cwd().readFileAlloc(ctx.allocator, fp_path, 1024 * 1024) catch {
        res.status = 404;
        res.body = "footprint file not found";
        return;
    };
    defer ctx.allocator.free(source);

    // Find and replace the courtyard line
    const cy_start = std.mem.indexOf(u8, source, "(courtyard") orelse {
        // No courtyard — insert before closing paren
        var out: std.ArrayListUnmanaged(u8) = .empty;
        const w = out.writer(ctx.allocator);
        // Find last ')'
        var last_paren: usize = source.len;
        while (last_paren > 0) {
            last_paren -= 1;
            if (source[last_paren] == ')') break;
        }
        try w.writeAll(source[0..last_paren]);
        try w.print("  (courtyard (rect {d:.2} {d:.2} {d:.2} {d:.2}))\n", .{ x1, y1, x2, y2 });
        try w.writeAll(source[last_paren..]);

        const file = std.fs.cwd().createFile(fp_path, .{}) catch {
            res.status = 500;
            return;
        };
        defer file.close();
        file.writeAll(out.items) catch {
            res.status = 500;
            return;
        };
        res.content_type = .JSON;
        res.body = "{\"ok\":true}";
        return;
    };

    // Find end of courtyard form
    var depth: u32 = 0;
    var cy_end: usize = cy_start;
    for (source[cy_start..], 0..) |ch, i| {
        if (ch == '(') depth += 1;
        if (ch == ')') {
            depth -= 1;
            if (depth == 0) {
                cy_end = cy_start + i + 1;
                break;
            }
        }
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    const w = out.writer(ctx.allocator);
    try w.writeAll(source[0..cy_start]);
    try w.print("(courtyard (rect {d:.2} {d:.2} {d:.2} {d:.2}))", .{ x1, y1, x2, y2 });
    try w.writeAll(source[cy_end..]);

    const file = std.fs.cwd().createFile(fp_path, .{}) catch {
        res.status = 500;
        return;
    };
    defer file.close();
    file.writeAll(out.items) catch {
        res.status = 500;
        return;
    };

    std.debug.print("Edited courtyard for {s}: ({d:.2}, {d:.2}, {d:.2}, {d:.2})\n", .{ footprint, x1, y1, x2, y2 });
    res.content_type = .JSON;
    res.body = "{\"ok\":true}";
}

/// POST /api/add-instance/:name
/// Body: {"section":"Power","component":"cap-0402","value":"100nF","pins":{"1":"VDD","2":"GND"}}
pub fn addInstanceApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    const body = req.body() orelse {
        res.status = 400;
        res.body = "no body";
        return;
    };

    const component = parseJsonString(body, "\"component\"") orelse {
        res.status = 400;
        res.body = "missing component";
        return;
    };
    const value = parseJsonString(body, "\"value\"") orelse "";
    const section = parseJsonString(body, "\"section\"") orelse "";

    // Read source file
    const file_path = try std.fmt.allocPrint(ctx.allocator, "{s}/src/{s}.sexp", .{ ctx.project_dir, name });
    defer ctx.allocator.free(file_path);

    const source = std.fs.cwd().readFileAlloc(ctx.allocator, file_path, 10 * 1024 * 1024) catch {
        res.status = 500;
        res.body = "cannot read file";
        return;
    };
    defer ctx.allocator.free(source);

    // Parse pin assignments from body: "pins":{"1":"VDD","2":"GND"}
    var pin_str: std.ArrayListUnmanaged(u8) = .empty;
    const pw = pin_str.writer(ctx.allocator);
    if (std.mem.indexOf(u8, body, "\"pins\"")) |pins_start| {
        // Find the opening brace
        var pos = pins_start + 6;
        while (pos < body.len and body[pos] != '{') : (pos += 1) {}
        if (pos < body.len) {
            pos += 1; // skip {
            while (pos < body.len and body[pos] != '}') {
                // Parse "pin_num":"net_name"
                while (pos < body.len and body[pos] != '"') : (pos += 1) {}
                if (pos >= body.len) break;
                pos += 1;
                const pin_start = pos;
                while (pos < body.len and body[pos] != '"') : (pos += 1) {}
                const pin_num = body[pin_start..pos];
                pos += 1; // skip closing "

                while (pos < body.len and body[pos] != '"') : (pos += 1) {}
                if (pos >= body.len) break;
                pos += 1;
                const net_start = pos;
                while (pos < body.len and body[pos] != '"') : (pos += 1) {}
                const net_name = body[net_start..pos];
                pos += 1;

                try pw.print("\n    (pin {s} \"{s}\")", .{ pin_num, net_name });

                while (pos < body.len and (body[pos] == ',' or body[pos] == ' ')) : (pos += 1) {}
            }
        }
    }

    // Build the instance form
    var inst_form: std.ArrayListUnmanaged(u8) = .empty;
    const iw = inst_form.writer(ctx.allocator);
    if (value.len > 0) {
        try iw.print("  (instance ({s} \"{s}\")", .{ component, value });
    } else {
        try iw.print("  (instance {s}", .{component});
    }
    try iw.writeAll(pin_str.items);
    try iw.writeAll(")\n");

    // Find insertion point: inside section if specified, otherwise before last closing paren
    var new_source: std.ArrayListUnmanaged(u8) = .empty;
    const nw = new_source.writer(ctx.allocator);

    if (section.len > 0) {
        // Find (section "Name" ...) and insert before its closing paren
        const sec_needle = try std.fmt.allocPrint(ctx.allocator, "(section \"{s}\"", .{section});
        defer ctx.allocator.free(sec_needle);

        if (std.mem.indexOf(u8, source, sec_needle)) |sec_start| {
            // Find matching closing paren
            var depth: u32 = 0;
            var sec_end: usize = sec_start;
            for (source[sec_start..], 0..) |ch, i| {
                if (ch == '(') depth += 1;
                if (ch == ')') {
                    depth -= 1;
                    if (depth == 0) {
                        sec_end = sec_start + i;
                        break;
                    }
                }
            }
            try nw.writeAll(source[0..sec_end]);
            try nw.writeAll("\n");
            try nw.writeAll(inst_form.items);
            try nw.writeAll(source[sec_end..]);
        } else {
            // Section not found, insert at end
            const last_paren = std.mem.lastIndexOfScalar(u8, source, ')') orelse source.len;
            try nw.writeAll(source[0..last_paren]);
            try nw.writeAll("\n");
            try nw.writeAll(inst_form.items);
            try nw.writeAll(source[last_paren..]);
        }
    } else {
        const last_paren = std.mem.lastIndexOfScalar(u8, source, ')') orelse source.len;
        try nw.writeAll(source[0..last_paren]);
        try nw.writeAll("\n");
        try nw.writeAll(inst_form.items);
        try nw.writeAll(source[last_paren..]);
    }

    // Write file
    const file = std.fs.cwd().createFile(file_path, .{}) catch {
        res.status = 500;
        res.body = "cannot write file";
        return;
    };
    defer file.close();
    file.writeAll(new_source.items) catch {
        res.status = 500;
        return;
    };

    // Rebuild + push live update
    rebuildAndPush(ctx, name, res) catch {
        res.status = 500;
        res.body = "rebuild failed";
        return;
    };
}

/// POST /api/remove-instance/:name
/// Body: {"ref":"C3"}
pub fn removeInstanceApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    const body = req.body() orelse {
        res.status = 400;
        res.body = "no body";
        return;
    };

    const ref_des = parseJsonString(body, "\"ref\"") orelse {
        res.status = 400;
        res.body = "missing ref";
        return;
    };

    // Read source file
    const file_path = try std.fmt.allocPrint(ctx.allocator, "{s}/src/{s}.sexp", .{ ctx.project_dir, name });
    defer ctx.allocator.free(file_path);

    const source = std.fs.cwd().readFileAlloc(ctx.allocator, file_path, 10 * 1024 * 1024) catch {
        res.status = 500;
        res.body = "cannot read file";
        return;
    };
    defer ctx.allocator.free(source);

    // Find (instance "REF" ...) and remove the entire form
    const needle = try std.fmt.allocPrint(ctx.allocator, "(instance \"{s}\"", .{ref_des});
    defer ctx.allocator.free(needle);

    const inst_pos = std.mem.indexOf(u8, source, needle) orelse {
        res.status = 404;
        res.body = "instance not found";
        return;
    };

    // Find matching closing paren
    var depth: u32 = 0;
    var inst_end: usize = inst_pos;
    for (source[inst_pos..], 0..) |ch, i| {
        if (ch == '(') depth += 1;
        if (ch == ')') {
            depth -= 1;
            if (depth == 0) {
                inst_end = inst_pos + i + 1;
                break;
            }
        }
    }

    // Also eat trailing newline
    if (inst_end < source.len and source[inst_end] == '\n') inst_end += 1;

    // Also eat leading whitespace on the same line
    var inst_start = inst_pos;
    while (inst_start > 0 and (source[inst_start - 1] == ' ' or source[inst_start - 1] == '\t')) : (inst_start -= 1) {}

    var new_source: std.ArrayListUnmanaged(u8) = .empty;
    const nw = new_source.writer(ctx.allocator);
    try nw.writeAll(source[0..inst_start]);
    try nw.writeAll(source[inst_end..]);

    const file = std.fs.cwd().createFile(file_path, .{}) catch {
        res.status = 500;
        res.body = "cannot write file";
        return;
    };
    defer file.close();
    file.writeAll(new_source.items) catch {
        res.status = 500;
        return;
    };

    std.debug.print("Removed instance {s} from {s}\n", .{ ref_des, name });
    rebuildAndPush(ctx, name, res) catch {
        res.status = 500;
        res.body = "rebuild failed";
        return;
    };
}

/// POST /api/rewire-pin/:name
/// Body: {"ref":"U1","pin":"5","net":"VDD_NEW"}
pub fn rewirePinApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    const body = req.body() orelse {
        res.status = 400;
        res.body = "no body";
        return;
    };

    const ref_des = parseJsonString(body, "\"ref\"") orelse {
        res.status = 400;
        res.body = "missing ref";
        return;
    };
    const pin = parseJsonString(body, "\"pin\"") orelse {
        res.status = 400;
        res.body = "missing pin";
        return;
    };
    const new_net = parseJsonString(body, "\"net\"") orelse {
        res.status = 400;
        res.body = "missing net";
        return;
    };

    const file_path = try std.fmt.allocPrint(ctx.allocator, "{s}/src/{s}.sexp", .{ ctx.project_dir, name });
    defer ctx.allocator.free(file_path);

    const source = std.fs.cwd().readFileAlloc(ctx.allocator, file_path, 10 * 1024 * 1024) catch {
        res.status = 500;
        res.body = "cannot read file";
        return;
    };
    defer ctx.allocator.free(source);

    // Find the instance
    const inst_needle = try std.fmt.allocPrint(ctx.allocator, "(instance \"{s}\"", .{ref_des});
    defer ctx.allocator.free(inst_needle);

    const inst_pos = std.mem.indexOf(u8, source, inst_needle) orelse {
        res.status = 404;
        res.body = "instance not found";
        return;
    };

    // Find the pin form within this instance: (pin N "NET")
    // Search for (pin <pin_num> "...) within the instance
    const pin_needle = try std.fmt.allocPrint(ctx.allocator, "(pin {s} \"", .{pin});
    defer ctx.allocator.free(pin_needle);

    const search_start = inst_pos;
    // Find the end of the instance form
    var depth: u32 = 0;
    var inst_end: usize = inst_pos;
    for (source[inst_pos..], 0..) |ch, i| {
        if (ch == '(') depth += 1;
        if (ch == ')') {
            depth -= 1;
            if (depth == 0) {
                inst_end = inst_pos + i + 1;
                break;
            }
        }
    }

    const inst_region = source[search_start..inst_end];
    const pin_offset = std.mem.indexOf(u8, inst_region, pin_needle) orelse {
        res.status = 404;
        res.body = "pin not found in instance";
        return;
    };

    // Find the net string in this pin form
    const abs_pin = search_start + pin_offset + pin_needle.len;
    const net_end = std.mem.indexOfPos(u8, source, abs_pin, "\"") orelse {
        res.status = 400;
        res.body = "malformed pin form";
        return;
    };

    var new_source: std.ArrayListUnmanaged(u8) = .empty;
    const nw = new_source.writer(ctx.allocator);
    try nw.writeAll(source[0..abs_pin]);
    try nw.writeAll(new_net);
    try nw.writeAll(source[net_end..]);

    const file = std.fs.cwd().createFile(file_path, .{}) catch {
        res.status = 500;
        res.body = "cannot write file";
        return;
    };
    defer file.close();
    file.writeAll(new_source.items) catch {
        res.status = 500;
        return;
    };

    std.debug.print("Rewired {s} pin {s} -> \"{s}\" in {s}\n", .{ ref_des, pin, new_net, name });
    rebuildAndPush(ctx, name, res) catch {
        res.status = 500;
        res.body = "rebuild failed";
        return;
    };
}

/// Rebuild design, render SVG, and push live update.
fn rebuildAndPush(ctx: *Handler, name: []const u8, res: *httpz.Response) !void {
    const board_path = try std.fmt.allocPrint(ctx.allocator, "{s}/src/{s}.sexp", .{ ctx.project_dir, name });
    defer ctx.allocator.free(board_path);

    var eval = Evaluator.init(ctx.allocator, ctx.project_dir);
    defer eval.deinit();
    const result = eval.evalFile(board_path) catch return error.RebuildFailed;
    const block = switch (result) {
        .design_block => |b| b,
        else => return error.RebuildFailed,
    };

    const bom_path = try std.fmt.allocPrint(ctx.allocator, "{s}/src/{s}.bom", .{ ctx.project_dir, name });
    defer ctx.allocator.free(bom_path);
    bom.resolveIdentities(ctx.allocator, block, bom_path, ctx.project_dir) catch {};

    const layout_json = render_json.renderSceneGraph(ctx.allocator, block) catch null;

    serve_root.live_mutex.lock();
    serve_root.live_layout_json = layout_json;
    serve_root.live_mutex.unlock();
    _ = serve_root.bumpLiveVersion(name);

    res.header("access-control-allow-origin", "*");
    res.content_type = .JSON;
    res.body = "{\"ok\":true}";
}

fn parseJsonFloat(body: []const u8, key: []const u8) ?f64 {
    const marker = std.mem.indexOf(u8, body, key) orelse return null;
    var start = marker + key.len;
    // Skip whitespace
    while (start < body.len and (body[start] == ' ' or body[start] == ':')) : (start += 1) {}
    var end = start;
    while (end < body.len and (body[end] == '-' or body[end] == '.' or (body[end] >= '0' and body[end] <= '9'))) : (end += 1) {}
    return std.fmt.parseFloat(f64, body[start..end]) catch null;
}

fn parseJsonString(body: []const u8, key: []const u8) ?[]const u8 {
    const marker = std.mem.indexOf(u8, body, key) orelse return null;
    var start = marker + key.len;
    while (start < body.len and body[start] != '"') : (start += 1) {}
    start += 1; // skip opening quote
    const end = std.mem.indexOfPos(u8, body, start, "\"") orelse return null;
    return body[start..end];
}

// ── Board outline editing ───────────────────────────────────────────

pub fn boardOutlineApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    const body = req.body() orelse {
        res.status = 400;
        res.body = "{\"error\":\"missing body\"}";
        res.content_type = .JSON;
        return;
    };

    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, body, .{}) catch {
        res.status = 400;
        res.body = "{\"error\":\"invalid json\"}";
        res.content_type = .JSON;
        return;
    };
    const root = parsed.value;
    const x1 = if (root.object.get("x1")) |v| floatFromJson(v) else null;
    const y1 = if (root.object.get("y1")) |v| floatFromJson(v) else null;
    const x2 = if (root.object.get("x2")) |v| floatFromJson(v) else null;
    const y2 = if (root.object.get("y2")) |v| floatFromJson(v) else null;
    if (x1 == null or y1 == null or x2 == null or y2 == null) {
        res.status = 400;
        res.body = "{\"error\":\"missing x1/y1/x2/y2\"}";
        res.content_type = .JSON;
        return;
    }

    // Read the board file
    const board_file_path = try std.fmt.allocPrint(ctx.allocator, "{s}/src/{s}-board.sexp", .{ ctx.project_dir, name });
    defer ctx.allocator.free(board_file_path);
    const source = std.fs.cwd().readFileAlloc(ctx.allocator, board_file_path, 1024 * 1024) catch {
        res.status = 404;
        res.body = "{\"error\":\"board file not found\"}";
        res.content_type = .JSON;
        return;
    };

    // Find and replace the outline line
    const new_outline = try std.fmt.allocPrint(ctx.allocator, "(outline (rect {d:.1} {d:.1} {d:.1} {d:.1}))", .{ x1.?, y1.?, x2.?, y2.? });
    defer ctx.allocator.free(new_outline);

    var result_buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = result_buf.writer(ctx.allocator);

    // Replace the outline form in the source
    if (std.mem.indexOf(u8, source, "(outline ")) |start| {
        // Find matching close paren
        var depth: usize = 0;
        var end: usize = start;
        while (end < source.len) : (end += 1) {
            if (source[end] == '(') depth += 1;
            if (source[end] == ')') {
                depth -= 1;
                if (depth == 0) {
                    end += 1;
                    break;
                }
            }
        }
        try w.writeAll(source[0..start]);
        try w.writeAll(new_outline);
        try w.writeAll(source[end..]);
    } else {
        // No outline exists — insert after first line
        if (std.mem.indexOf(u8, source, "\n")) |nl| {
            try w.writeAll(source[0 .. nl + 1]);
            try w.print("  {s}\n", .{new_outline});
            try w.writeAll(source[nl + 1 ..]);
        } else {
            res.status = 500;
            res.body = "{\"error\":\"malformed board file\"}";
            res.content_type = .JSON;
            return;
        }
    }

    // Write back
    const file = std.fs.cwd().createFile(board_file_path, .{}) catch {
        res.status = 500;
        res.body = "{\"error\":\"failed to write\"}";
        res.content_type = .JSON;
        return;
    };
    defer file.close();
    file.writeAll(result_buf.items) catch {
        res.status = 500;
        res.body = "{\"error\":\"write error\"}";
        res.content_type = .JSON;
        return;
    };

    res.content_type = .JSON;
    res.body = "{\"ok\":true}";
}

fn floatFromJson(v: std.json.Value) ?f64 {
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => null,
    };
}

// ── Core mutation API (shared between HTTP handlers and MCP tools) ───────
//
// The `…Core` functions are pure-logic entry points: they take an allocator,
// project dir, design name, and edit args, and return a MutationResult with
// the post-edit live_version. HTTP handlers above still do their own parsing
// and response-shaping; these cores are called by the MCP tool dispatcher
// (see src/serve/mcp.zig). Later, the HTTP handlers can be converted to
// delegate here to remove duplication.

pub const EditError = error{
    InstanceNotFound,
    PinNotFound,
    SectionNotFound,
    ComponentNotFound,
    MalformedSource,
    InvalidSource,
    CannotReadDesign,
    CannotWriteDesign,
    RebuildFailed,
    SnapshotNotFound,
    InvalidSnapshotId,
} || std.mem.Allocator.Error;

pub const MutationResult = struct {
    version: u32,
    /// Snapshot id for the state immediately before this mutation, or null if
    /// the file did not exist yet (brand-new design). Caller owns the memory.
    snapshot: ?[]const u8 = null,
};

pub const PinAssignment = struct {
    pin: []const u8,
    net: []const u8,
};

fn designFilePath(allocator: std.mem.Allocator, project_dir: []const u8, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/src/{s}.sexp", .{ project_dir, name });
}

fn readDesignSource(allocator: std.mem.Allocator, project_dir: []const u8, name: []const u8) EditError![]u8 {
    const path = try designFilePath(allocator, project_dir, name);
    defer allocator.free(path);
    return std.fs.cwd().readFileAlloc(allocator, path, 10 * 1024 * 1024) catch return error.CannotReadDesign;
}

fn writeAndRebuild(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    new_source: []const u8,
) EditError!MutationResult {
    const path = try designFilePath(allocator, project_dir, name);
    defer allocator.free(path);

    // Snapshot prior state before overwriting. Null means the design didn't
    // exist yet (brand-new create). Snapshot errors are logged but don't
    // block the write — undo is a nice-to-have, not a hard requirement.
    const snap_id: ?[]const u8 = history.snapshot(allocator, project_dir, name) catch |e| blk: {
        std.debug.print("[snapshot] failed for {s}: {s}\n", .{ name, @errorName(e) });
        break :blk null;
    };

    {
        const file = std.fs.cwd().createFile(path, .{}) catch return error.CannotWriteDesign;
        defer file.close();
        file.writeAll(new_source) catch return error.CannotWriteDesign;
    }

    var eval = Evaluator.init(allocator, project_dir);
    defer eval.deinit();
    const result = eval.evalFile(path) catch return error.RebuildFailed;
    const block = switch (result) {
        .design_block => |b| b,
        else => return error.RebuildFailed,
    };

    const bom_path = std.fmt.allocPrint(allocator, "{s}/src/{s}.bom", .{ project_dir, name }) catch return error.OutOfMemory;
    defer allocator.free(bom_path);
    bom.resolveIdentities(allocator, block, bom_path, project_dir) catch {};

    const layout_json = render_json.renderSceneGraph(allocator, block) catch null;

    serve_root.live_mutex.lock();
    serve_root.live_layout_json = layout_json;
    serve_root.live_mutex.unlock();
    const version = serve_root.bumpLiveVersion(name);

    return .{ .version = version, .snapshot = snap_id };
}

fn findInstanceEnd(source: []const u8, inst_start: usize) ?usize {
    var depth: u32 = 0;
    for (source[inst_start..], 0..) |ch, i| {
        if (ch == '(') depth += 1;
        if (ch == ')') {
            depth -= 1;
            if (depth == 0) return inst_start + i + 1;
        }
    }
    return null;
}

pub fn editValueCore(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    ref_des: []const u8,
    new_value: []const u8,
) EditError!MutationResult {
    const source = try readDesignSource(allocator, project_dir, name);
    defer allocator.free(source);

    const needle = try std.fmt.allocPrint(allocator, "(instance \"{s}\" (", .{ref_des});
    defer allocator.free(needle);

    const inst_pos = std.mem.indexOf(u8, source, needle) orelse return error.InstanceNotFound;
    const after_inst = inst_pos + needle.len;

    var pos = after_inst;
    while (pos < source.len and source[pos] != '"' and source[pos] != ')') : (pos += 1) {}
    if (pos >= source.len or source[pos] != '"') return error.MalformedSource;

    const old_val_start = pos + 1;
    const old_val_end = std.mem.indexOfPos(u8, source, old_val_start, "\"") orelse return error.MalformedSource;

    var new_source: std.ArrayListUnmanaged(u8) = .empty;
    defer new_source.deinit(allocator);
    const nw = new_source.writer(allocator);
    try nw.writeAll(source[0..old_val_start]);
    try nw.writeAll(new_value);
    try nw.writeAll(source[old_val_end..]);

    return writeAndRebuild(allocator, project_dir, name, new_source.items);
}

pub fn removeInstanceCore(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    ref_des: []const u8,
) EditError!MutationResult {
    const source = try readDesignSource(allocator, project_dir, name);
    defer allocator.free(source);

    const needle = try std.fmt.allocPrint(allocator, "(instance \"{s}\"", .{ref_des});
    defer allocator.free(needle);

    const inst_pos = std.mem.indexOf(u8, source, needle) orelse return error.InstanceNotFound;
    var inst_end = findInstanceEnd(source, inst_pos) orelse return error.MalformedSource;
    if (inst_end < source.len and source[inst_end] == '\n') inst_end += 1;

    var inst_start = inst_pos;
    while (inst_start > 0 and (source[inst_start - 1] == ' ' or source[inst_start - 1] == '\t')) : (inst_start -= 1) {}

    var new_source: std.ArrayListUnmanaged(u8) = .empty;
    defer new_source.deinit(allocator);
    const nw = new_source.writer(allocator);
    try nw.writeAll(source[0..inst_start]);
    try nw.writeAll(source[inst_end..]);

    return writeAndRebuild(allocator, project_dir, name, new_source.items);
}

pub fn rewirePinCore(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    ref_des: []const u8,
    pin: []const u8,
    new_net: []const u8,
) EditError!MutationResult {
    const source = try readDesignSource(allocator, project_dir, name);
    defer allocator.free(source);

    const inst_needle = try std.fmt.allocPrint(allocator, "(instance \"{s}\"", .{ref_des});
    defer allocator.free(inst_needle);
    const inst_pos = std.mem.indexOf(u8, source, inst_needle) orelse return error.InstanceNotFound;
    const inst_end = findInstanceEnd(source, inst_pos) orelse return error.MalformedSource;

    const pin_needle = try std.fmt.allocPrint(allocator, "(pin {s} \"", .{pin});
    defer allocator.free(pin_needle);
    const pin_offset = std.mem.indexOf(u8, source[inst_pos..inst_end], pin_needle) orelse return error.PinNotFound;
    const abs_pin = inst_pos + pin_offset + pin_needle.len;
    const net_end = std.mem.indexOfPos(u8, source, abs_pin, "\"") orelse return error.MalformedSource;

    var new_source: std.ArrayListUnmanaged(u8) = .empty;
    defer new_source.deinit(allocator);
    const nw = new_source.writer(allocator);
    try nw.writeAll(source[0..abs_pin]);
    try nw.writeAll(new_net);
    try nw.writeAll(source[net_end..]);

    return writeAndRebuild(allocator, project_dir, name, new_source.items);
}

pub fn addInstanceCore(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    section: []const u8,
    component: []const u8,
    value: []const u8,
    pins: []const PinAssignment,
) EditError!MutationResult {
    const source = try readDesignSource(allocator, project_dir, name);
    defer allocator.free(source);

    var pin_body: std.ArrayListUnmanaged(u8) = .empty;
    defer pin_body.deinit(allocator);
    const pw = pin_body.writer(allocator);
    for (pins) |p| try pw.print("\n    (pin {s} \"{s}\")", .{ p.pin, p.net });

    var inst_form: std.ArrayListUnmanaged(u8) = .empty;
    defer inst_form.deinit(allocator);
    const iw = inst_form.writer(allocator);
    if (value.len > 0) {
        try iw.print("  (instance ({s} \"{s}\")", .{ component, value });
    } else {
        try iw.print("  (instance {s}", .{component});
    }
    try iw.writeAll(pin_body.items);
    try iw.writeAll(")\n");

    var new_source: std.ArrayListUnmanaged(u8) = .empty;
    defer new_source.deinit(allocator);
    const nw = new_source.writer(allocator);

    var insert_at: usize = std.mem.lastIndexOfScalar(u8, source, ')') orelse source.len;
    if (section.len > 0) {
        const sec_needle = try std.fmt.allocPrint(allocator, "(section \"{s}\"", .{section});
        defer allocator.free(sec_needle);
        if (std.mem.indexOf(u8, source, sec_needle)) |sec_start| {
            insert_at = (findInstanceEnd(source, sec_start) orelse return error.MalformedSource) - 1;
        } else {
            return error.SectionNotFound;
        }
    }

    try nw.writeAll(source[0..insert_at]);
    try nw.writeAll("\n");
    try nw.writeAll(inst_form.items);
    try nw.writeAll(source[insert_at..]);

    return writeAndRebuild(allocator, project_dir, name, new_source.items);
}

pub fn swapComponentCore(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    ref_des: []const u8,
    new_component: []const u8,
) EditError!MutationResult {
    // Verify component family exists
    const comp_path = try std.fmt.allocPrint(allocator, "{s}/lib/components/{s}.sexp", .{ project_dir, new_component });
    defer allocator.free(comp_path);
    std.fs.cwd().access(comp_path, .{}) catch return error.ComponentNotFound;

    // Evaluate current design to look up source_offset for this ref_des
    const design_path = try designFilePath(allocator, project_dir, name);
    defer allocator.free(design_path);
    var eval = Evaluator.init(allocator, project_dir);
    defer eval.deinit();
    const result = eval.evalFile(design_path) catch return error.RebuildFailed;
    const block = switch (result) {
        .design_block => |b| b,
        else => return error.RebuildFailed,
    };

    var source_offset: usize = 0;
    var old_component: []const u8 = "";
    var found = false;
    for (block.instances) |inst| {
        if (std.mem.eql(u8, inst.ref_des, ref_des)) {
            source_offset = @intCast(inst.source_offset);
            old_component = inst.component;
            found = true;
            break;
        }
    }
    if (!found) return error.InstanceNotFound;

    const source = try readDesignSource(allocator, project_dir, name);
    defer allocator.free(source);

    if (source_offset + old_component.len > source.len or
        !std.mem.eql(u8, source[source_offset .. source_offset + old_component.len], old_component))
    {
        return error.MalformedSource;
    }

    var new_source: std.ArrayListUnmanaged(u8) = .empty;
    defer new_source.deinit(allocator);
    const nw = new_source.writer(allocator);
    try nw.writeAll(source[0..source_offset]);
    try nw.writeAll(new_component);
    try nw.writeAll(source[source_offset + old_component.len ..]);

    // Ensure new component is in the import list
    var final_bytes: []const u8 = new_source.items;
    var final_owned: ?std.ArrayListUnmanaged(u8) = null;
    defer if (final_owned) |*o| o.deinit(allocator);
    if (std.mem.indexOf(u8, final_bytes, "(import ")) |import_start| {
        const import_end = findInstanceEnd(final_bytes, import_start) orelse return error.MalformedSource;
        const import_section = final_bytes[import_start..import_end];
        const already_imported = blk: {
            var search_from: usize = 0;
            while (std.mem.indexOfPos(u8, import_section, search_from, new_component)) |ipos| {
                const before_ok = ipos == 0 or import_section[ipos - 1] == ' ' or import_section[ipos - 1] == '\n';
                const after_pos = ipos + new_component.len;
                const after_ok = after_pos >= import_section.len or import_section[after_pos] == ' ' or import_section[after_pos] == '\n' or import_section[after_pos] == ')';
                if (before_ok and after_ok) break :blk true;
                search_from = ipos + 1;
            }
            break :blk false;
        };
        if (!already_imported) {
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            const bw = buf.writer(allocator);
            // import_end points one past the closing paren; insert before it.
            try bw.writeAll(final_bytes[0 .. import_end - 1]);
            try bw.writeAll(" ");
            try bw.writeAll(new_component);
            try bw.writeAll(final_bytes[import_end - 1 ..]);
            final_owned = buf;
            final_bytes = buf.items;
        }
    }

    return writeAndRebuild(allocator, project_dir, name, final_bytes);
}

/// Read the full `.sexp` source text for a design. Caller owns the returned
/// buffer.
pub fn readDesignSourcePub(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
) EditError![]u8 {
    return readDesignSource(allocator, project_dir, name);
}

/// Overwrite (or create) the design's `.sexp` with `new_source`. Validates
/// syntax via the sexpr parser before writing, snapshots any prior state,
/// then rebuilds the design.
pub fn writeDesignCore(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    new_source: []const u8,
) EditError!MutationResult {
    // Pre-flight: reject obvious syntax errors so a broken file never hits
    // disk. Semantic errors (missing imports, assertion failures) still fall
    // through to the rebuild step — the auto-snapshot serves as undo there.
    _ = sexpr_parser.parse(allocator, new_source) catch return error.InvalidSource;

    // Ensure src/ exists so brand-new designs can be created.
    const src_dir = try std.fmt.allocPrint(allocator, "{s}/src", .{project_dir});
    defer allocator.free(src_dir);
    std.fs.cwd().makePath(src_dir) catch {};

    return writeAndRebuild(allocator, project_dir, name, new_source);
}

/// Restore a design from a history snapshot. First snapshots the current
/// state (so restore is itself undoable), then copies the snapshot files
/// back into `src/` and rebuilds.
pub fn restoreDesignCore(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    id: []const u8,
) EditError!MutationResult {
    // Snapshot current state first so the restore can be undone.
    const pre_snap: ?[]const u8 = history.snapshot(allocator, project_dir, name) catch |e| blk: {
        std.debug.print("[snapshot] pre-restore failed for {s}: {s}\n", .{ name, @errorName(e) });
        break :blk null;
    };

    history.restore(allocator, project_dir, name, id) catch |e| switch (e) {
        error.InvalidSnapshotId => return error.InvalidSnapshotId,
        error.SnapshotNotFound => return error.SnapshotNotFound,
        else => return error.CannotReadDesign,
    };

    // Rebuild from the restored source.
    const path = try designFilePath(allocator, project_dir, name);
    defer allocator.free(path);

    var eval = Evaluator.init(allocator, project_dir);
    defer eval.deinit();
    const result = eval.evalFile(path) catch return error.RebuildFailed;
    const block = switch (result) {
        .design_block => |b| b,
        else => return error.RebuildFailed,
    };

    const bom_path = std.fmt.allocPrint(allocator, "{s}/src/{s}.bom", .{ project_dir, name }) catch return error.OutOfMemory;
    defer allocator.free(bom_path);
    bom.resolveIdentities(allocator, block, bom_path, project_dir) catch {};

    const layout_json = render_json.renderSceneGraph(allocator, block) catch null;
    serve_root.live_mutex.lock();
    serve_root.live_layout_json = layout_json;
    serve_root.live_mutex.unlock();
    const version = serve_root.bumpLiveVersion(name);

    return .{ .version = version, .snapshot = pre_snap };
}
