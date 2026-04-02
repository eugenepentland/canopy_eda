const std = @import("std");
const httpz = @import("httpz");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const render_svg = @import("../render_svg.zig");
const bom = @import("../bom.zig");
const serve_root = @import("../serve.zig");
const Handler = serve_root.Handler;
const bom_html = @import("bom_html.zig");

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

    const svg = render_svg.renderSchematic(ctx.allocator, block) catch {
        res.status = 500;
        return;
    };

    serve_root.live_mutex.lock();
    serve_root.live_svg = svg;
    serve_root.live_version += 1;
    serve_root.live_mutex.unlock();

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

    const svg = render_svg.renderSchematic(ctx.allocator, block) catch {
        res.status = 500;
        return;
    };

    serve_root.live_mutex.lock();
    serve_root.live_svg = svg;
    serve_root.live_version += 1;
    serve_root.live_mutex.unlock();

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
