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

fn warnResolveIdentities(name: []const u8, err: anyerror) void {
    std.debug.print("warning: resolveIdentities {s} failed: {s}\n", .{ name, @errorName(err) });
}

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
    bom.resolveIdentities(ctx.allocator, block, bom_path, ctx.project_dir) catch |e| warnResolveIdentities(name, e);

    const new_layout = render_json.renderSceneGraph(ctx.allocator, block, ctx.project_dir) catch null;
    serve_root.setLiveLayoutJson(new_layout);
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
    bom.resolveIdentities(ctx.allocator, block, bom_path, ctx.project_dir) catch |e| warnResolveIdentities(name, e);

    var svg_sym_cache = try bom_html.buildSymbolPinCache(ctx.allocator, ctx.project_dir);

    const new_layout = render_json.renderSceneGraph(ctx.allocator, block, ctx.project_dir) catch null;
    serve_root.setLiveLayoutJson(new_layout);
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

/// Move a single-pin form `(pin OLD "NET")` to `(pin NEW "NET")` within an
/// instance. Body: `{"ref":"U1","old_pin":"V11","new_pin":"V12"}`. Returns
/// HTTP 409 with a structured error if the destination pin is already used.
pub fn movePinApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = .JSON;
    res.header("access-control-allow-origin", "*");

    const name = req.param("name") orelse {
        res.status = 404;
        res.body = "{\"error\":\"missing name\"}";
        return;
    };
    const body = req.body() orelse {
        res.status = 400;
        res.body = "{\"error\":\"no body\"}";
        return;
    };

    const ref_des = parseJsonString(body, "\"ref\"") orelse {
        res.status = 400;
        res.body = "{\"error\":\"missing ref\"}";
        return;
    };
    const old_pin = parseJsonString(body, "\"old_pin\"") orelse {
        res.status = 400;
        res.body = "{\"error\":\"missing old_pin\"}";
        return;
    };
    const new_pin = parseJsonString(body, "\"new_pin\"") orelse {
        res.status = 400;
        res.body = "{\"error\":\"missing new_pin\"}";
        return;
    };

    // Resolve ref_des → source key. Source `.sexp` forms use the instance's
    // `label` (e.g. "stm32") when set, and the ref_des otherwise. The scene
    // graph/UI always speaks ref_des.
    const source_key = resolveSourceKey(ctx.allocator, ctx.project_dir, name, ref_des) catch ref_des;

    const result = movePinCore(ctx.allocator, ctx.project_dir, name, source_key, old_pin, new_pin) catch |err| {
        switch (err) {
            error.PinAlreadyAssigned => {
                res.status = 409;
                res.body = try std.fmt.allocPrint(ctx.allocator, "{{\"error\":\"pin_already_assigned\",\"pin\":\"{s}\"}}", .{new_pin});
                return;
            },
            error.PinNotFound => {
                res.status = 404;
                res.body = "{\"error\":\"pin_not_found\"}";
                return;
            },
            error.InstanceNotFound => {
                res.status = 404;
                res.body = "{\"error\":\"instance_not_found\"}";
                return;
            },
            error.InvalidSource => {
                res.status = 400;
                res.body = "{\"error\":\"invalid_pin_id\"}";
                return;
            },
            error.RebuildFailed => {
                res.status = 500;
                res.body = "{\"error\":\"rebuild_failed\"}";
                return;
            },
            else => {
                res.status = 500;
                res.body = try std.fmt.allocPrint(ctx.allocator, "{{\"error\":\"{s}\"}}", .{@errorName(err)});
                return;
            },
        }
    };

    res.body = try std.fmt.allocPrint(ctx.allocator, "{{\"ok\":true,\"version\":{d}}}", .{result.version});
}

/// Swap the net assignments of two pins on the same instance.
/// Body: `{"ref":"U1","pin_a":"V11","pin_b":"V12"}`.
pub fn swapPinsApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = .JSON;
    res.header("access-control-allow-origin", "*");

    const name = req.param("name") orelse {
        res.status = 404;
        res.body = "{\"error\":\"missing name\"}";
        return;
    };
    const body = req.body() orelse {
        res.status = 400;
        res.body = "{\"error\":\"no body\"}";
        return;
    };

    const ref_des = parseJsonString(body, "\"ref\"") orelse {
        res.status = 400;
        res.body = "{\"error\":\"missing ref\"}";
        return;
    };
    const pin_a = parseJsonString(body, "\"pin_a\"") orelse {
        res.status = 400;
        res.body = "{\"error\":\"missing pin_a\"}";
        return;
    };
    const pin_b = parseJsonString(body, "\"pin_b\"") orelse {
        res.status = 400;
        res.body = "{\"error\":\"missing pin_b\"}";
        return;
    };

    const source_key = resolveSourceKey(ctx.allocator, ctx.project_dir, name, ref_des) catch ref_des;

    const result = swapPinsCore(ctx.allocator, ctx.project_dir, name, source_key, pin_a, pin_b) catch |err| {
        switch (err) {
            error.PinNotFound => {
                res.status = 404;
                res.body = "{\"error\":\"pin_not_found\"}";
                return;
            },
            error.InstanceNotFound => {
                res.status = 404;
                res.body = "{\"error\":\"instance_not_found\"}";
                return;
            },
            error.InvalidSource => {
                res.status = 400;
                res.body = "{\"error\":\"invalid_pin_id\"}";
                return;
            },
            error.RebuildFailed => {
                res.status = 500;
                res.body = "{\"error\":\"rebuild_failed\"}";
                return;
            },
            else => {
                res.status = 500;
                res.body = try std.fmt.allocPrint(ctx.allocator, "{{\"error\":\"{s}\"}}", .{@errorName(err)});
                return;
            },
        }
    };

    res.body = try std.fmt.allocPrint(ctx.allocator, "{{\"ok\":true,\"version\":{d}}}", .{result.version});
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
    bom.resolveIdentities(ctx.allocator, block, bom_path, ctx.project_dir) catch |e| warnResolveIdentities(name, e);

    const layout_json = render_json.renderSceneGraph(ctx.allocator, block, ctx.project_dir) catch null;
    serve_root.setLiveLayoutJson(layout_json);
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
    PinAlreadyAssigned,
    SectionNotFound,
    ComponentNotFound,
    NoteNotFound,
    ImportsFormMissing,
    DuplicateImport,
    DuplicateParameter,
    DuplicateRequirement,
    InvalidRequirement,
    MalformedSource,
    InvalidSource,
    CannotReadDesign,
    CannotWriteDesign,
    RebuildFailed,
    SnapshotNotFound,
    InvalidSnapshotId,
    AmbiguousMatch,
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
    description: ?[]const u8,
) EditError!MutationResult {
    const path = try designFilePath(allocator, project_dir, name);
    defer allocator.free(path);

    // Snapshot prior state before overwriting. Null means the design didn't
    // exist yet (brand-new create). Snapshot errors are logged but don't
    // block the write — undo is a nice-to-have, not a hard requirement.
    const snap_id: ?[]const u8 = history.snapshot(allocator, project_dir, name, description) catch |e| blk: {
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
    bom.resolveIdentities(allocator, block, bom_path, project_dir) catch |e| warnResolveIdentities(name, e);

    const layout_json = render_json.renderSceneGraph(allocator, block, project_dir) catch null;
    serve_root.setLiveLayoutJson(layout_json);
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

/// Find the index one past the closing paren of the form whose open paren
/// lives at `open_pos`. Respects strings and `;` line comments, so section
/// bodies (which commonly contain both) are handled correctly.
fn findFormEnd(source: []const u8, open_pos: usize) ?usize {
    var i: usize = open_pos;
    var depth: i32 = 0;
    while (i < source.len) : (i += 1) {
        const ch = source[i];
        if (ch == '"') {
            i += 1;
            while (i < source.len and source[i] != '"') : (i += 1) {
                if (source[i] == '\\' and i + 1 < source.len) i += 1;
            }
            continue;
        }
        if (ch == ';') {
            while (i < source.len and source[i] != '\n') : (i += 1) {}
            continue;
        }
        if (ch == '(') depth += 1;
        if (ch == ')') {
            depth -= 1;
            if (depth == 0) return i + 1;
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

    const desc = try std.fmt.allocPrint(allocator, "edit_value {s} → {s}", .{ ref_des, new_value });
    defer allocator.free(desc);
    return writeAndRebuild(allocator, project_dir, name, new_source.items, desc);
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

    const desc = try std.fmt.allocPrint(allocator, "remove_instance {s}", .{ref_des});
    defer allocator.free(desc);
    return writeAndRebuild(allocator, project_dir, name, new_source.items, desc);
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

    const desc = try std.fmt.allocPrint(allocator, "rewire_pin {s}.{s} → {s}", .{ ref_des, pin, new_net });
    defer allocator.free(desc);
    return writeAndRebuild(allocator, project_dir, name, new_source.items, desc);
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

    const desc = try std.fmt.allocPrint(allocator, "add_instance {s}", .{component});
    defer allocator.free(desc);
    return writeAndRebuild(allocator, project_dir, name, new_source.items, desc);
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

    const desc = try std.fmt.allocPrint(allocator, "swap_component {s} → {s}", .{ ref_des, new_component });
    defer allocator.free(desc);
    return writeAndRebuild(allocator, project_dir, name, final_bytes, desc);
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
    std.fs.cwd().makePath(src_dir) catch |e| {
        std.debug.print("warning: makePath {s} failed: {s}\n", .{ src_dir, @errorName(e) });
    };

    return writeAndRebuild(allocator, project_dir, name, new_source, "write_design");
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
    const pre_desc = try std.fmt.allocPrint(allocator, "pre-restore {s}", .{id});
    defer allocator.free(pre_desc);
    const pre_snap: ?[]const u8 = history.snapshot(allocator, project_dir, name, pre_desc) catch |e| blk: {
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
    bom.resolveIdentities(allocator, block, bom_path, project_dir) catch |e| warnResolveIdentities(name, e);

    const layout_json = render_json.renderSceneGraph(allocator, block, project_dir) catch null;
    serve_root.setLiveLayoutJson(layout_json);
    const version = serve_root.bumpLiveVersion(name);

    return .{ .version = version, .snapshot = pre_snap };
}

/// Replace an entire `(section "SECTION_NAME" ...)` form with `new_source`.
/// `new_source` must be the complete replacement form (including the outer
/// parens). Returns `SectionNotFound` if no match and `Ambiguous` if more
/// than one section with that name exists at the top level of the file.
pub fn editSectionCore(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    section_name: []const u8,
    new_source: []const u8,
) EditError!MutationResult {
    const source = try readDesignSource(allocator, project_dir, name);
    defer allocator.free(source);

    const needle = try std.fmt.allocPrint(allocator, "(section \"{s}\"", .{section_name});
    defer allocator.free(needle);

    const first = std.mem.indexOf(u8, source, needle) orelse return error.SectionNotFound;
    // Ambiguity check — if the same name shows up twice we bail so the caller
    // can disambiguate rather than edit the wrong one silently.
    if (std.mem.indexOfPos(u8, source, first + needle.len, needle) != null) {
        return error.AmbiguousMatch;
    }
    const end = findFormEnd(source, first) orelse return error.MalformedSource;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeAll(source[0..first]);
    try w.writeAll(new_source);
    try w.writeAll(source[end..]);

    const desc = try std.fmt.allocPrint(allocator, "edit_section {s}", .{section_name});
    defer allocator.free(desc);
    return writeAndRebuild(allocator, project_dir, name, buf.items, desc);
}

/// Replace the text of a `(note "...")` form. Identifies the target note by
/// a substring match against its current text — if `match` does not uniquely
/// identify one note, returns `AmbiguousMatch`. Use the full current text to
/// disambiguate; use a distinctive substring for light-weight edits.
pub fn editNoteCore(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    match: []const u8,
    new_text: []const u8,
) EditError!MutationResult {
    const source = try readDesignSource(allocator, project_dir, name);
    defer allocator.free(source);

    // Scan every `(note "` occurrence, extract its quoted text, and record
    // every form whose text contains `match`.
    var found_start: ?usize = 0;
    var found_text_start: usize = 0;
    var found_text_end: usize = 0;
    var count: usize = 0;
    found_start = null;

    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, source, cursor, "(note")) |note_start| {
        // Must be followed by whitespace + opening quote to be a single-arg note.
        var i: usize = note_start + "(note".len;
        while (i < source.len and (source[i] == ' ' or source[i] == '\t' or source[i] == '\n')) : (i += 1) {}
        if (i >= source.len or source[i] != '"') {
            cursor = note_start + 1;
            continue;
        }
        const text_start = i + 1;
        // Scan for the closing quote (honoring \\ escapes).
        var j: usize = text_start;
        while (j < source.len and source[j] != '"') : (j += 1) {
            if (source[j] == '\\' and j + 1 < source.len) j += 1;
        }
        if (j >= source.len) return error.MalformedSource;
        const text_end = j;
        if (std.mem.indexOf(u8, source[text_start..text_end], match) != null) {
            count += 1;
            if (count > 1) return error.AmbiguousMatch;
            found_start = note_start;
            found_text_start = text_start;
            found_text_end = text_end;
        }
        cursor = text_end + 1;
    }

    if (count == 0 or found_start == null) return error.NoteNotFound;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeAll(source[0..found_text_start]);
    // Emit escaped replacement text so quotes inside the new body don't break the form.
    for (new_text) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        else => try w.writeByte(c),
    };
    try w.writeAll(source[found_text_end..]);

    const desc = try std.fmt.allocPrint(allocator, "edit_note \"{s}\"", .{match});
    defer allocator.free(desc);
    return writeAndRebuild(allocator, project_dir, name, buf.items, desc);
}

/// Splice a new `(note "text" [(ref "file.pdf" (page N))])` into the body of
/// a `(section "NAME" ...)` form. Inserts immediately before the closing `)`
/// of the section. `pdf` is optional — when non-empty, emits the `(ref ...)`
/// sub-form; when the page is 0 it's omitted. This is the design-specific
/// half of the two-tier notes model (design notes live in the .sexp; library
/// requirements live in `lib/components/<...>.sexp`).
pub fn addSectionNoteCore(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    section_name: []const u8,
    text: []const u8,
    pdf: []const u8,
    page: u32,
) EditError!MutationResult {
    if (text.len == 0) return error.InvalidSource;
    const source = try readDesignSource(allocator, project_dir, name);
    defer allocator.free(source);

    const needle = try std.fmt.allocPrint(allocator, "(section \"{s}\"", .{section_name});
    defer allocator.free(needle);
    const sec_start = std.mem.indexOf(u8, source, needle) orelse return error.SectionNotFound;
    if (std.mem.indexOfPos(u8, source, sec_start + needle.len, needle) != null) return error.AmbiguousMatch;
    const sec_end = findFormEnd(source, sec_start) orelse return error.MalformedSource;
    const insert_at = sec_end - 1;

    // Indent heuristic: match the first non-whitespace sibling inside the
    // section body so new notes sit alongside existing forms.
    const indent = detectSectionIndent(source, sec_start);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeAll(source[0..insert_at]);
    try w.writeByte('\n');
    try w.writeAll(indent);
    try w.writeAll("(note \"");
    for (text) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        else => try w.writeByte(c),
    };
    try w.writeAll("\"");
    if (pdf.len > 0) {
        try w.writeAll(" (ref \"");
        for (pdf) |c| switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            else => try w.writeByte(c),
        };
        try w.writeAll("\"");
        if (page > 0) try w.print(" (page {d})", .{page});
        try w.writeAll(")");
    }
    try w.writeAll(")\n");
    try w.writeAll(source[insert_at..]);

    const desc = try std.fmt.allocPrint(allocator, "add_section_note {s}", .{section_name});
    defer allocator.free(desc);
    return writeAndRebuild(allocator, project_dir, name, buf.items, desc);
}

/// Remove the `idx`-th `(note ...)` form inside a named section (0-based,
/// in source order). Used by the review UI when a reviewer clicks the
/// delete button on a design note.
pub fn removeSectionNoteCore(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    section_name: []const u8,
    idx: usize,
) EditError!MutationResult {
    const source = try readDesignSource(allocator, project_dir, name);
    defer allocator.free(source);

    const needle = try std.fmt.allocPrint(allocator, "(section \"{s}\"", .{section_name});
    defer allocator.free(needle);
    const sec_start = std.mem.indexOf(u8, source, needle) orelse return error.SectionNotFound;
    if (std.mem.indexOfPos(u8, source, sec_start + needle.len, needle) != null) return error.AmbiguousMatch;
    const sec_end = findFormEnd(source, sec_start) orelse return error.MalformedSource;

    // Walk `(note ` forms that are direct children of the section (depth 1
    // relative to the section). Skip anything nested in sub-sections or
    // instances so the caller's idx matches what the review UI shows.
    // String literals and `;` line comments are skipped so parens inside
    // them don't confuse depth tracking.
    var cursor: usize = sec_start + 1;
    var depth: usize = 1;
    var note_idx: usize = 0;
    while (cursor < sec_end) {
        const ch = source[cursor];
        if (ch == ';') {
            while (cursor < sec_end and source[cursor] != '\n') : (cursor += 1) {}
            continue;
        }
        if (ch == '(') {
            if (depth == 1 and std.mem.startsWith(u8, source[cursor..], "(note")) {
                const end = findFormEnd(source, cursor) orelse return error.MalformedSource;
                if (note_idx == idx) {
                    var trim_start: usize = cursor;
                    while (trim_start > 0 and (source[trim_start - 1] == ' ' or source[trim_start - 1] == '\t')) : (trim_start -= 1) {}
                    if (trim_start > 0 and source[trim_start - 1] == '\n') trim_start -= 1;
                    var trim_end: usize = end;
                    if (trim_end < source.len and source[trim_end] == '\n') trim_end += 1;

                    var buf: std.ArrayListUnmanaged(u8) = .empty;
                    defer buf.deinit(allocator);
                    const w = buf.writer(allocator);
                    try w.writeAll(source[0..trim_start]);
                    try w.writeAll(source[trim_end..]);

                    const desc = try std.fmt.allocPrint(allocator, "remove_section_note {s}[{d}]", .{ section_name, idx });
                    defer allocator.free(desc);
                    return writeAndRebuild(allocator, project_dir, name, buf.items, desc);
                }
                note_idx += 1;
                cursor = end;
                continue;
            }
            depth += 1;
        } else if (ch == ')') {
            depth -= 1;
            if (depth == 0) break;
        } else if (ch == '"') {
            var j: usize = cursor + 1;
            while (j < source.len and source[j] != '"') : (j += 1) {
                if (source[j] == '\\' and j + 1 < source.len) j += 1;
            }
            cursor = j + 1;
            continue;
        }
        cursor += 1;
    }

    return error.NoteNotFound;
}

/// Splice a `(datasheet "file.pdf")` entry into the component definition at
/// `lib/components/<component>.sexp`. Dedupes — a duplicate filename returns
/// `DuplicateImport` rather than re-adding. Lets the schematic sidebar link
/// a PDF to a part with one click instead of editing the library by hand.
///
/// The library file isn't rebuilt into a design (it's a library, not a
/// design), so this path bypasses the usual writeAndRebuild flow: we do a
/// quick parse-check of the result, snapshot if possible, and bump a
/// server-wide version the pinout cache reads off.
pub fn addComponentDatasheetCore(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    component_name: []const u8,
    pdf: []const u8,
) EditError!MutationResult {
    if (pdf.len == 0) return error.InvalidSource;
    if (!safeLibName(component_name)) return error.InvalidSource;
    if (!safePdfName(pdf)) return error.InvalidSource;

    const path = try libComponentPath(allocator, project_dir, component_name);
    defer allocator.free(path);
    const source = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch return error.CannotReadDesign;
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "(component") == null) return error.MalformedSource;
    const form_start = std.mem.indexOf(u8, source, "(component").?;
    const form_end = findFormEnd(source, form_start) orelse return error.MalformedSource;

    // Dedupe: already linked?
    const needle = try std.fmt.allocPrint(allocator, "(datasheet \"{s}\")", .{pdf});
    defer allocator.free(needle);
    if (std.mem.indexOf(u8, source[form_start..form_end], needle) != null) return error.DuplicateImport;

    // Insert before the closing `)` with matching indent.
    const insert_at = form_end - 1;
    const indent = detectComponentIndent(source, form_start);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeAll(source[0..insert_at]);
    try w.writeByte('\n');
    try w.writeAll(indent);
    try w.writeAll("(datasheet \"");
    for (pdf) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        else => try w.writeByte(c),
    };
    try w.writeAll("\")");
    try w.writeAll(source[insert_at..]);

    try writeLibComponent(path, buf.items);
    const version = @import("../serve.zig").bumpLiveVersion(component_name);
    return .{ .version = version, .snapshot = null };
}

/// Remove a single `(datasheet "file.pdf")` line from
/// `lib/components/<component>.sexp`. Silently succeeds when the link
/// didn't exist so UI double-clicks don't 500.
pub fn removeComponentDatasheetCore(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    component_name: []const u8,
    pdf: []const u8,
) EditError!MutationResult {
    if (pdf.len == 0) return error.InvalidSource;
    if (!safeLibName(component_name)) return error.InvalidSource;
    if (!safePdfName(pdf)) return error.InvalidSource;

    const path = try libComponentPath(allocator, project_dir, component_name);
    defer allocator.free(path);
    const source = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch return error.CannotReadDesign;
    defer allocator.free(source);

    const needle = try std.fmt.allocPrint(allocator, "(datasheet \"{s}\")", .{pdf});
    defer allocator.free(needle);
    const pos = std.mem.indexOf(u8, source, needle) orelse return error.NoteNotFound;
    const end = pos + needle.len;

    // Trim preceding whitespace + newline so we don't leave a blank line.
    var trim_start: usize = pos;
    while (trim_start > 0 and (source[trim_start - 1] == ' ' or source[trim_start - 1] == '\t')) : (trim_start -= 1) {}
    if (trim_start > 0 and source[trim_start - 1] == '\n') trim_start -= 1;
    var trim_end: usize = end;
    if (trim_end < source.len and source[trim_end] == '\n') trim_end += 1;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeAll(source[0..trim_start]);
    try w.writeAll(source[trim_end..]);

    try writeLibComponent(path, buf.items);
    const version = @import("../serve.zig").bumpLiveVersion(component_name);
    return .{ .version = version, .snapshot = null };
}

fn libComponentPath(allocator: std.mem.Allocator, project_dir: []const u8, component_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/lib/components/{s}.sexp", .{ project_dir, component_name });
}

fn writeLibComponent(path: []const u8, new_source: []const u8) EditError!void {
    const file = std.fs.cwd().createFile(path, .{}) catch return error.CannotWriteDesign;
    defer file.close();
    file.writeAll(new_source) catch return error.CannotWriteDesign;
}

fn safeLibName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.indexOf(u8, name, "..") != null) return false;
    if (std.mem.indexOfAny(u8, name, "/\\") != null) return false;
    return true;
}

fn safePdfName(name: []const u8) bool {
    if (name.len == 0 or name.len > 255) return false;
    if (std.mem.indexOf(u8, name, "..") != null) return false;
    if (std.mem.indexOfAny(u8, name, "/\\\"") != null) return false;
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c == '-' or c == '.';
        if (!ok) return false;
    }
    return true;
}

/// Indent prefix for the first child inside a `(component ...)` form —
/// library files are typically indented with two spaces, but follow the
/// file's existing style when possible.
fn detectComponentIndent(source: []const u8, form_start: usize) []const u8 {
    var i: usize = form_start;
    while (i < source.len and source[i] != '\n') : (i += 1) {}
    if (i >= source.len) return "  ";
    i += 1;
    const indent_start = i;
    while (i < source.len and (source[i] == ' ' or source[i] == '\t')) : (i += 1) {}
    if (i == indent_start) return "  ";
    return source[indent_start..i];
}

/// Return the indentation prefix (leading whitespace) of the first child
/// form inside a `(section ...)` body, so splice points match the file's
/// existing indent style. Falls back to two spaces when the section is
/// empty.
fn detectSectionIndent(source: []const u8, sec_start: usize) []const u8 {
    // Skip past `(section "NAME"` opening — find the first newline after it.
    var i: usize = sec_start;
    while (i < source.len and source[i] != '\n') : (i += 1) {}
    if (i >= source.len) return "  ";
    i += 1;
    const indent_start = i;
    while (i < source.len and (source[i] == ' ' or source[i] == '\t')) : (i += 1) {}
    if (i == indent_start) return "  ";
    return source[indent_start..i];
}

/// Add a single item to the top-level `(import ...)` list. If the item is
/// already present (word-boundary match), returns `DuplicateImport` without
/// modifying the file. Fails with `ImportsFormMissing` if the design has no
/// `(import ...)` form at all.
pub fn addImportCore(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    import_item: []const u8,
) EditError!MutationResult {
    if (import_item.len == 0) return error.InvalidSource;
    // Reject items with whitespace or quotes — they must be atom-like.
    for (import_item) |c| if (c == ' ' or c == '\n' or c == '\t' or c == '"' or c == '(' or c == ')') return error.InvalidSource;

    const source = try readDesignSource(allocator, project_dir, name);
    defer allocator.free(source);

    const import_start = std.mem.indexOf(u8, source, "(import") orelse return error.ImportsFormMissing;
    const import_end = findFormEnd(source, import_start) orelse return error.MalformedSource;
    const import_body = source[import_start..import_end];

    // Word-boundary dedup check: match import_item only when surrounded by
    // whitespace, `(`, or `)`.
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, import_body, search_from, import_item)) |ipos| {
        const before_ok = ipos == 0 or import_body[ipos - 1] == ' ' or import_body[ipos - 1] == '\n' or import_body[ipos - 1] == '\t';
        const after_pos = ipos + import_item.len;
        const after_ok = after_pos >= import_body.len or
            import_body[after_pos] == ' ' or
            import_body[after_pos] == '\n' or
            import_body[after_pos] == '\t' or
            import_body[after_pos] == ')';
        if (before_ok and after_ok) return error.DuplicateImport;
        search_from = ipos + 1;
    }

    // Insert before the closing paren of the import form.
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeAll(source[0 .. import_end - 1]);
    try w.writeAll(" ");
    try w.writeAll(import_item);
    try w.writeAll(source[import_end - 1 ..]);

    const desc = try std.fmt.allocPrint(allocator, "add_import {s}", .{import_item});
    defer allocator.free(desc);
    return writeAndRebuild(allocator, project_dir, name, buf.items, desc);
}

/// Set a single pin on an instance to a new net. Thin wrapper over
/// `rewirePinCore`; exposed separately so MCP callers can phrase a one-pin
/// change without building a full `replace_instance` payload.
pub fn setInstancePinCore(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    ref_des: []const u8,
    pin: []const u8,
    new_net: []const u8,
) EditError!MutationResult {
    return rewirePinCore(allocator, project_dir, name, ref_des, pin, new_net);
}

const PinTokenLoc = struct { start: usize, end: usize };

/// Scan the interior of a single `(pin ...)` form — starting just after
/// `(pin ` and bounded by `limit` — for the first top-level bareword token
/// equal to `pin`. Stops at the first `"` (net string) or the form's
/// closing `)`. Nested sub-forms like `(as "AF")` are skipped as opaque,
/// so pin IDs declared as `(pin W12 (as "TIM2_CH2") "CNV_MASTER")` are
/// recognised just like plain `(pin W12 "CNV_MASTER")` forms.
fn findPinInForm(source: []const u8, start: usize, limit: usize, pin: []const u8) ?PinTokenLoc {
    var i: usize = start;
    while (i < limit) {
        const c = source[i];
        if (c == ')' or c == '"') return null;
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            i += 1;
            continue;
        }
        if (c == '(') {
            var depth: usize = 1;
            i += 1;
            while (i < limit and depth > 0) : (i += 1) {
                if (source[i] == '(') depth += 1 else if (source[i] == ')') depth -= 1;
            }
            continue;
        }
        const tok_start = i;
        while (i < limit) : (i += 1) {
            const cc = source[i];
            if (cc == ' ' or cc == '\t' or cc == '\n' or cc == '\r' or cc == '"' or cc == '(' or cc == ')') break;
        }
        if (std.mem.eql(u8, source[tok_start..i], pin)) return .{ .start = tok_start, .end = i };
    }
    return null;
}

/// Locate the byte range of the first pin-ID token equal to `pin` across
/// every `(pin ...)` form inside `regions`. Works for both single-pin
/// `(pin X "NET")` and multi-pin shorthand `(pin 1 2 3 "NET")` — in the
/// shorthand case the returned range covers just the matching numeric
/// token, so callers can rename it in place and leave the rest of the
/// list intact.
fn findPinTokenInRegions(source: []const u8, regions: []const PinRegion, pin: []const u8) ?PinTokenLoc {
    for (regions) |r| {
        var search: usize = r.start;
        while (std.mem.indexOfPos(u8, source, search, "(pin ")) |p| {
            if (p >= r.end) break;
            if (findPinInForm(source, p + "(pin ".len, r.end, pin)) |loc| return loc;
            search = p + "(pin ".len;
        }
    }
    return null;
}

/// Map a ref_des (e.g. "U3") to the string used in the `.sexp` source for
/// that instance's `(instance "X" ...)` and `(pins "X" ...)` forms. Returns
/// the instance's `label` if set, otherwise the ref_des itself. Falls back
/// to the ref_des on any evaluation error.
fn resolveSourceKey(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    ref_des: []const u8,
) ![]const u8 {
    const path = try designFilePath(allocator, project_dir, name);
    defer allocator.free(path);
    var eval = Evaluator.init(allocator, project_dir);
    defer eval.deinit();
    const result = eval.evalFile(path) catch return ref_des;
    const block = switch (result) {
        .design_block => |b| b,
        .board => |b| b.design,
        else => return ref_des,
    };
    for (block.instances) |inst| {
        if (std.mem.eql(u8, inst.ref_des, ref_des)) {
            return if (inst.label.len > 0) try allocator.dupe(u8, inst.label) else ref_des;
        }
    }
    return ref_des;
}

const PinRegion = struct { start: usize, end: usize };

/// Collect the byte ranges of every form that may contain pin assignments
/// for `ref_des`: inline `(instance "REF" ...)` forms, and section-level
/// `(pins "REF" ...)` routing groups.
fn collectPinRegions(
    allocator: std.mem.Allocator,
    source: []const u8,
    ref_des: []const u8,
    out: *std.ArrayListUnmanaged(PinRegion),
) EditError!void {
    const heads = [_][]const u8{ "(instance \"", "(pins \"" };
    inline for (heads) |head| {
        const needle = try std.fmt.allocPrint(allocator, "{s}{s}\"", .{ head, ref_des });
        defer allocator.free(needle);
        var search: usize = 0;
        while (std.mem.indexOfPos(u8, source, search, needle)) |p| {
            const end = findInstanceEnd(source, p) orelse return error.MalformedSource;
            try out.append(allocator, .{ .start = p, .end = end });
            search = end;
        }
    }
}

/// Rename the pin-ID token `old_pin` to `new_pin` inside any `(pin ...)`
/// form that declares pins for `ref_des` — works whether the old token
/// sits in a single-pin form `(pin OLD "NET")` or inside a multi-pin
/// shorthand `(pin 1 OLD 3 "NET")`. Multi-pin shorthand stays shorthand:
/// only the numeric token changes. Fails with `PinAlreadyAssigned` if
/// `new_pin` is already used anywhere across those regions.
pub fn movePinCore(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    ref_des: []const u8,
    old_pin: []const u8,
    new_pin: []const u8,
) EditError!MutationResult {
    if (old_pin.len == 0 or new_pin.len == 0) return error.InvalidSource;
    for (new_pin) |c| if (c == ' ' or c == '\t' or c == '\n' or c == '"' or c == '(' or c == ')') return error.InvalidSource;
    if (std.mem.eql(u8, old_pin, new_pin)) return error.InvalidSource;

    const source = try readDesignSource(allocator, project_dir, name);
    defer allocator.free(source);

    var regions: std.ArrayListUnmanaged(PinRegion) = .empty;
    defer regions.deinit(allocator);
    try collectPinRegions(allocator, source, ref_des, &regions);
    if (regions.items.len == 0) return error.InstanceNotFound;

    if (findPinTokenInRegions(source, regions.items, new_pin) != null) return error.PinAlreadyAssigned;
    const old_loc = findPinTokenInRegions(source, regions.items, old_pin) orelse return error.PinNotFound;

    var new_source: std.ArrayListUnmanaged(u8) = .empty;
    defer new_source.deinit(allocator);
    const nw = new_source.writer(allocator);
    try nw.writeAll(source[0..old_loc.start]);
    try nw.writeAll(new_pin);
    try nw.writeAll(source[old_loc.end..]);

    const desc = try std.fmt.allocPrint(allocator, "move_pin {s}.{s} → {s}", .{ ref_des, old_pin, new_pin });
    defer allocator.free(desc);
    return writeAndRebuild(allocator, project_dir, name, new_source.items, desc);
}

/// Swap the pin-ID tokens of two pins on the same instance so the nets
/// attached to `pin_a` and `pin_b` trade places. Each pin may live in a
/// single-pin `(pin X "NET")` form or inside a multi-pin shorthand
/// `(pin A B C "NET")` — the numeric/ID token is renamed wherever it
/// sits, so shorthand forms stay shorthand.
pub fn swapPinsCore(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    ref_des: []const u8,
    pin_a: []const u8,
    pin_b: []const u8,
) EditError!MutationResult {
    if (pin_a.len == 0 or pin_b.len == 0) return error.InvalidSource;
    for (pin_a) |c| if (c == ' ' or c == '\t' or c == '\n' or c == '"' or c == '(' or c == ')') return error.InvalidSource;
    for (pin_b) |c| if (c == ' ' or c == '\t' or c == '\n' or c == '"' or c == '(' or c == ')') return error.InvalidSource;
    if (std.mem.eql(u8, pin_a, pin_b)) return error.InvalidSource;

    const source = try readDesignSource(allocator, project_dir, name);
    defer allocator.free(source);

    var regions: std.ArrayListUnmanaged(PinRegion) = .empty;
    defer regions.deinit(allocator);
    try collectPinRegions(allocator, source, ref_des, &regions);
    if (regions.items.len == 0) return error.InstanceNotFound;

    const a_loc = findPinTokenInRegions(source, regions.items, pin_a) orelse return error.PinNotFound;
    const b_loc = findPinTokenInRegions(source, regions.items, pin_b) orelse return error.PinNotFound;

    const a_first = a_loc.start < b_loc.start;
    const first_start = if (a_first) a_loc.start else b_loc.start;
    const first_end = if (a_first) a_loc.end else b_loc.end;
    const first_replace: []const u8 = if (a_first) pin_b else pin_a;
    const second_start = if (a_first) b_loc.start else a_loc.start;
    const second_end = if (a_first) b_loc.end else a_loc.end;
    const second_replace: []const u8 = if (a_first) pin_a else pin_b;

    var new_source: std.ArrayListUnmanaged(u8) = .empty;
    defer new_source.deinit(allocator);
    const nw = new_source.writer(allocator);
    try nw.writeAll(source[0..first_start]);
    try nw.writeAll(first_replace);
    try nw.writeAll(source[first_end..second_start]);
    try nw.writeAll(second_replace);
    try nw.writeAll(source[second_end..]);

    const desc = try std.fmt.allocPrint(allocator, "swap_pins {s}.{s} <-> {s}", .{ ref_des, pin_a, pin_b });
    defer allocator.free(desc);
    return writeAndRebuild(allocator, project_dir, name, new_source.items, desc);
}

/// Add a `(parameter "name" type)` declaration to the top-level
/// `(component ...)` or `(component-family ...)` form in
/// `lib/components/{component}.sexp`. Snapshots the prior library file under
/// `history/_lib/components/...` so the edit is undoable. Does not rebuild
/// any design — callers must re-run a design build to pick up the change.
pub fn addComponentParameterCore(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    component: []const u8,
    param_name: []const u8,
    param_type: []const u8,
) EditError!struct { snapshot: ?[]const u8 } {
    // Path-traversal guard.
    if (component.len == 0 or std.mem.indexOf(u8, component, "..") != null or std.mem.indexOfAny(u8, component, "/\\") != null) {
        return error.InvalidSource;
    }
    if (param_name.len == 0) return error.InvalidSource;
    for (param_name) |c| if (c == '"' or c == '\\' or c == '\n') return error.InvalidSource;
    if (param_type.len == 0) return error.InvalidSource;
    for (param_type) |c| if (c == ' ' or c == '(' or c == ')' or c == '"') return error.InvalidSource;

    const path = try std.fmt.allocPrint(allocator, "{s}/lib/components/{s}.sexp", .{ project_dir, component });
    defer allocator.free(path);
    const source = std.fs.cwd().readFileAlloc(allocator, path, 1 * 1024 * 1024) catch return error.ComponentNotFound;
    defer allocator.free(source);

    // Locate the outer (component ...) or (component-family ...) form.
    const comp_open = findOuterComponentOpen(source) orelse return error.MalformedSource;
    const comp_end = findFormEnd(source, comp_open) orelse return error.MalformedSource;
    const body = source[comp_open..comp_end];

    // Duplicate check — look for `(parameter "name"` (word-boundary on open paren).
    const dup_needle = try std.fmt.allocPrint(allocator, "(parameter \"{s}\"", .{param_name});
    defer allocator.free(dup_needle);
    if (std.mem.indexOf(u8, body, dup_needle) != null) return error.DuplicateParameter;

    // Snapshot the library file before modifying it.
    const desc = try std.fmt.allocPrint(allocator, "add_component_parameter {s}.{s}", .{ component, param_name });
    defer allocator.free(desc);
    const snap_id: ?[]const u8 = history.snapshotLibraryFile(allocator, project_dir, "components", component, desc) catch null;

    // Splice the new parameter line just before the final `)` of the outer
    // form. Preserve the final newline by inserting before `comp_end - 1`.
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeAll(source[0 .. comp_end - 1]);
    try w.print("\n  (parameter \"{s}\" {s})", .{ param_name, param_type });
    try w.writeAll(source[comp_end - 1 ..]);

    const file = std.fs.cwd().createFile(path, .{}) catch return error.CannotWriteDesign;
    defer file.close();
    file.writeAll(buf.items) catch return error.CannotWriteDesign;

    return .{ .snapshot = snap_id };
}

/// One element of an `addComponentRequirementsCore` batch after validation.
/// `trimmed` slices into the caller-supplied input (no copy); `text` is the
/// extracted requirement text used for dedup.
const ParsedRequirement = struct {
    trimmed: []const u8,
    text: []const u8,
};

/// Validate a single `(requirement "text" ...)` form: must start with
/// `(requirement`, then whitespace + a double-quoted text literal, and the
/// parens must balance to exactly one top-level form. We do not require the
/// full body to pass `parseCheck` / `parseNoteRef` — the evaluator will
/// surface those errors the next time a design that imports this component
/// is built. Returns the trimmed view + extracted text on success.
fn validateRequirementForm(requirement_sexp: []const u8) EditError!ParsedRequirement {
    const trimmed = std.mem.trim(u8, requirement_sexp, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidRequirement;
    if (!std.mem.startsWith(u8, trimmed, "(requirement")) return error.InvalidRequirement;
    const after_head = trimmed["(requirement".len..];
    var k: usize = 0;
    while (k < after_head.len and (after_head[k] == ' ' or after_head[k] == '\t' or after_head[k] == '\n' or after_head[k] == '\r')) : (k += 1) {}
    if (k >= after_head.len or after_head[k] != '"') return error.InvalidRequirement;
    const text_start_rel = k + 1;
    var text_end_rel: ?usize = null;
    var esc = false;
    var j: usize = text_start_rel;
    while (j < after_head.len) : (j += 1) {
        const ch = after_head[j];
        if (esc) {
            esc = false;
            continue;
        }
        if (ch == '\\') {
            esc = true;
            continue;
        }
        if (ch == '"') {
            text_end_rel = j;
            break;
        }
    }
    const end_off = text_end_rel orelse return error.InvalidRequirement;
    const req_text = after_head[text_start_rel..end_off];

    // Paren-balance check on the full form. Skip over comments (;...\n) and
    // string literals (" with escape). The form must close at exactly the
    // last character of `trimmed`.
    if (trimmed[trimmed.len - 1] != ')') return error.InvalidRequirement;
    var depth: i32 = 0;
    var i: usize = 0;
    var in_string = false;
    var str_esc = false;
    while (i < trimmed.len) : (i += 1) {
        const ch = trimmed[i];
        if (in_string) {
            if (str_esc) {
                str_esc = false;
            } else if (ch == '\\') {
                str_esc = true;
            } else if (ch == '"') {
                in_string = false;
            }
            continue;
        }
        switch (ch) {
            '"' => in_string = true,
            ';' => while (i < trimmed.len and trimmed[i] != '\n') : (i += 1) {},
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0 and i != trimmed.len - 1) return error.InvalidRequirement;
                if (depth < 0) return error.InvalidRequirement;
            },
            else => {},
        }
    }
    if (depth != 0) return error.InvalidRequirement;
    return .{ .trimmed = trimmed, .text = req_text };
}

/// Append one or more full `(requirement "text" ...)` forms to the top-level
/// `(component ...)` form in `lib/components/{component}.sexp`. The caller
/// supplies each requirement as a complete s-expression so arbitrarily
/// structured bodies (with `(ref ...)` and/or `(check ...)` children) can be
/// authored without this function needing to know the schema.
///
/// Atomic semantics: every requirement is validated and dedup-checked first,
/// against both the existing file and earlier items in the same batch. If
/// any one fails, the file is not touched at all — `out_failed_index` is
/// set to the offending element so the caller can surface "requirement #N
/// invalid" without a partial write to roll back.
///
/// On success, snapshots the library file once under
/// `history/_lib/components/...` and writes once. Does not rebuild any
/// design — callers must re-run a build to pick up the change.
pub fn addComponentRequirementsCore(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    component: []const u8,
    requirements: []const []const u8,
    out_failed_index: *usize,
) EditError!struct { snapshot: ?[]const u8, count: usize } {
    out_failed_index.* = 0;
    if (component.len == 0 or std.mem.indexOf(u8, component, "..") != null or std.mem.indexOfAny(u8, component, "/\\") != null) {
        return error.InvalidSource;
    }
    if (requirements.len == 0) return error.InvalidRequirement;

    const path = try std.fmt.allocPrint(allocator, "{s}/lib/components/{s}.sexp", .{ project_dir, component });
    defer allocator.free(path);
    const source = std.fs.cwd().readFileAlloc(allocator, path, 1 * 1024 * 1024) catch return error.ComponentNotFound;
    defer allocator.free(source);

    const comp_open = findOuterComponentOpen(source) orelse return error.MalformedSource;
    const comp_end = findFormEnd(source, comp_open) orelse return error.MalformedSource;
    const body = source[comp_open..comp_end];

    // Pass 1: validate every form. On failure, surface the offending index
    // and bail without touching the file. Allocate the parsed slice up front
    // so we can also dedup later items against earlier ones in the batch
    // without re-parsing.
    var parsed = try allocator.alloc(ParsedRequirement, requirements.len);
    defer allocator.free(parsed);
    for (requirements, 0..) |raw, idx| {
        out_failed_index.* = idx;
        parsed[idx] = try validateRequirementForm(raw);
    }

    // Pass 2: dedup. Each new requirement's text must not match (a) any
    // existing `(requirement "<text>"` in the file, nor (b) any earlier
    // item in the same batch. Same-batch dedup catches the case where the
    // agent accidentally generated the same rule twice — without it, the
    // file would gain two byte-identical rules in one call.
    for (parsed, 0..) |p, idx| {
        const dup_needle = try std.fmt.allocPrint(allocator, "(requirement \"{s}\"", .{p.text});
        defer allocator.free(dup_needle);
        if (std.mem.indexOf(u8, body, dup_needle) != null) {
            out_failed_index.* = idx;
            return error.DuplicateRequirement;
        }
        for (parsed[0..idx]) |earlier| {
            if (std.mem.eql(u8, earlier.text, p.text)) {
                out_failed_index.* = idx;
                return error.DuplicateRequirement;
            }
        }
    }

    // All clear — single snapshot, single splice.
    const desc = try std.fmt.allocPrint(allocator, "add_component_requirements {s} (+{d})", .{ component, parsed.len });
    defer allocator.free(desc);
    const snap_id: ?[]const u8 = history.snapshotLibraryFile(allocator, project_dir, "components", component, desc) catch null;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeAll(source[0 .. comp_end - 1]);
    for (parsed) |p| {
        try w.writeAll("\n  ");
        try w.writeAll(p.trimmed);
    }
    try w.writeAll(source[comp_end - 1 ..]);

    const file = std.fs.cwd().createFile(path, .{}) catch return error.CannotWriteDesign;
    defer file.close();
    file.writeAll(buf.items) catch return error.CannotWriteDesign;

    return .{ .snapshot = snap_id, .count = parsed.len };
}

/// Locate the opening paren of the first top-level `(component ...)` or
/// `(component-family ...)` form. Ignores comments and leading whitespace.
fn findOuterComponentOpen(source: []const u8) ?usize {
    var i: usize = 0;
    while (i < source.len) : (i += 1) {
        const ch = source[i];
        if (ch == ';') {
            while (i < source.len and source[i] != '\n') : (i += 1) {}
            continue;
        }
        if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') continue;
        if (ch != '(') return null;
        const tail = source[i + 1 ..];
        if (std.mem.startsWith(u8, tail, "component-family") or std.mem.startsWith(u8, tail, "component")) {
            return i;
        }
        return null;
    }
    return null;
}

/// Replace an entire `(instance "REF" ...)` form by reference designator
/// with `new_source` (which must be a complete replacement instance form).
pub fn replaceInstanceCore(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    ref_des: []const u8,
    new_source: []const u8,
) EditError!MutationResult {
    const source = try readDesignSource(allocator, project_dir, name);
    defer allocator.free(source);

    const needle = try std.fmt.allocPrint(allocator, "(instance \"{s}\"", .{ref_des});
    defer allocator.free(needle);

    const inst_start = std.mem.indexOf(u8, source, needle) orelse return error.InstanceNotFound;
    const end = findFormEnd(source, inst_start) orelse return error.MalformedSource;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeAll(source[0..inst_start]);
    try w.writeAll(new_source);
    try w.writeAll(source[end..]);

    const desc = try std.fmt.allocPrint(allocator, "replace_instance {s}", .{ref_des});
    defer allocator.free(desc);
    return writeAndRebuild(allocator, project_dir, name, buf.items, desc);
}

/// GET /api/source/:name — returns `{"source":"<raw .sexp text>"}`.
pub fn getSourceApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = .JSON;
    res.header("access-control-allow-origin", "*");

    const name = req.param("name") orelse {
        res.status = 404;
        res.body = "{\"error\":\"missing name\"}";
        return;
    };

    const source = readDesignSource(ctx.allocator, ctx.project_dir, name) catch {
        res.status = 404;
        res.body = "{\"error\":\"cannot read design\"}";
        return;
    };
    defer ctx.allocator.free(source);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(ctx.allocator);
    try w.writeAll("{\"source\":\"");
    try bom_html.writeJsonEscaped(w, source);
    try w.writeAll("\"}");
    res.body = buf.items;
}

/// POST /api/source/:name — body `{"source":"<raw .sexp text>"}`. Validates
/// syntax, writes the file, rebuilds, bumps version. Returns
/// `{"ok":true,"version":N,"snapshot":...}` on success or
/// `{"ok":false,"error":"..."}` with HTTP 400 on invalid source.
pub fn saveSourceApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = .JSON;
    res.header("access-control-allow-origin", "*");

    const name = req.param("name") orelse {
        res.status = 404;
        res.body = "{\"error\":\"missing name\"}";
        return;
    };
    const body = req.body() orelse {
        res.status = 400;
        res.body = "{\"error\":\"no body\"}";
        return;
    };

    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, body, .{}) catch {
        res.status = 400;
        res.body = "{\"ok\":false,\"error\":\"invalid json\"}";
        return;
    };
    defer parsed.deinit();
    const source_val = parsed.value.object.get("source") orelse {
        res.status = 400;
        res.body = "{\"ok\":false,\"error\":\"missing source\"}";
        return;
    };
    if (source_val != .string) {
        res.status = 400;
        res.body = "{\"ok\":false,\"error\":\"source must be a string\"}";
        return;
    }

    const result = writeDesignCore(ctx.allocator, ctx.project_dir, name, source_val.string) catch |err| {
        switch (err) {
            error.InvalidSource => {
                res.status = 400;
                res.body = "{\"ok\":false,\"error\":\"invalid sexp syntax\"}";
                return;
            },
            error.RebuildFailed => {
                res.status = 400;
                res.body = "{\"ok\":false,\"error\":\"rebuild failed: source wrote but evaluator rejected it\"}";
                return;
            },
            error.CannotWriteDesign => {
                res.status = 500;
                res.body = "{\"ok\":false,\"error\":\"cannot write file\"}";
                return;
            },
            else => {
                res.status = 500;
                res.body = try std.fmt.allocPrint(ctx.allocator, "{{\"ok\":false,\"error\":\"{s}\"}}", .{@errorName(err)});
                return;
            },
        }
    };

    var out: std.ArrayListUnmanaged(u8) = .empty;
    const w = out.writer(ctx.allocator);
    try w.print("{{\"ok\":true,\"version\":{d},\"snapshot\":", .{result.version});
    if (result.snapshot) |s| {
        try w.writeAll("\"");
        try bom_html.writeJsonEscaped(w, s);
        try w.writeAll("\"");
    } else {
        try w.writeAll("null");
    }
    try w.writeAll("}");
    res.body = out.items;
}
