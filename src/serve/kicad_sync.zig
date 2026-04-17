const std = @import("std");
const httpz = @import("httpz");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const export_kicad = @import("../export_kicad.zig");
const bom = @import("../bom.zig");
const serve_root = @import("../serve.zig");
const Handler = serve_root.Handler;

const Config = struct {
    output_dir: []const u8 = "",
    pcb_file: []const u8 = "",
};

fn configPath(allocator: std.mem.Allocator, project_dir: []const u8, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/src/{s}.kicad.json", .{ project_dir, name });
}

fn loadConfig(allocator: std.mem.Allocator, project_dir: []const u8, name: []const u8) Config {
    const path = configPath(allocator, project_dir, name) catch return .{};
    defer allocator.free(path);
    const content = std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024) catch return .{};
    defer allocator.free(content);
    return .{
        .output_dir = extractJsonString(allocator, content, "\"output_dir\"") orelse "",
        .pcb_file = extractJsonString(allocator, content, "\"pcb_file\"") orelse "",
    };
}

fn extractJsonString(allocator: std.mem.Allocator, json: []const u8, key: []const u8) ?[]const u8 {
    const key_pos = std.mem.indexOf(u8, json, key) orelse return null;
    var i = key_pos + key.len;
    while (i < json.len and (json[i] == ' ' or json[i] == ':' or json[i] == '\t')) i += 1;
    if (i >= json.len or json[i] != '"') return null;
    i += 1;
    const end = std.mem.indexOfPos(u8, json, i, "\"") orelse return null;
    return allocator.dupe(u8, json[i..end]) catch null;
}

pub fn getConfigApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    res.content_type = .JSON;
    res.header("access-control-allow-origin", "*");

    const cfg = loadConfig(ctx.allocator, ctx.project_dir, name);
    defer {
        if (cfg.output_dir.len > 0) ctx.allocator.free(cfg.output_dir);
        if (cfg.pcb_file.len > 0) ctx.allocator.free(cfg.pcb_file);
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(ctx.allocator);
    try w.writeAll("{\"output_dir\":\"");
    try writeJsonEscaped(w, cfg.output_dir);
    try w.writeAll("\",\"pcb_file\":\"");
    try writeJsonEscaped(w, cfg.pcb_file);
    try w.writeAll("\"}");
    res.body = buf.items;
}

pub fn setConfigApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    const body = req.body() orelse {
        res.status = 400;
        res.body = "{\"ok\":false,\"error\":\"no body\"}";
        res.content_type = .JSON;
        return;
    };

    const dir = extractJsonString(ctx.allocator, body, "\"output_dir\"") orelse {
        res.status = 400;
        res.body = "{\"ok\":false,\"error\":\"missing output_dir\"}";
        res.content_type = .JSON;
        return;
    };
    defer ctx.allocator.free(dir);
    const pcb = extractJsonString(ctx.allocator, body, "\"pcb_file\"") orelse ctx.allocator.dupe(u8, "") catch {
        res.status = 500;
        return;
    };
    defer ctx.allocator.free(pcb);

    const path = try configPath(ctx.allocator, ctx.project_dir, name);
    defer ctx.allocator.free(path);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(ctx.allocator);
    const w = out.writer(ctx.allocator);
    try w.writeAll("{\"output_dir\":\"");
    try writeJsonEscaped(w, dir);
    try w.writeAll("\",\"pcb_file\":\"");
    try writeJsonEscaped(w, pcb);
    try w.writeAll("\"}\n");

    const f = std.fs.cwd().createFile(path, .{}) catch {
        res.status = 500;
        res.body = "{\"ok\":false,\"error\":\"cannot write config\"}";
        res.content_type = .JSON;
        return;
    };
    defer f.close();
    f.writeAll(out.items) catch {
        res.status = 500;
        res.body = "{\"ok\":false,\"error\":\"write failed\"}";
        res.content_type = .JSON;
        return;
    };

    res.content_type = .JSON;
    res.header("access-control-allow-origin", "*");
    res.body = "{\"ok\":true}";
}

fn loadAndResolve(ctx: *Handler, name: []const u8, res: *httpz.Response) ?*const @import("../eval/env.zig").DesignBlock {
    const board_path = std.fmt.allocPrint(ctx.allocator, "{s}/src/{s}.sexp", .{ ctx.project_dir, name }) catch {
        res.status = 500;
        return null;
    };
    defer ctx.allocator.free(board_path);

    var eval = Evaluator.init(ctx.allocator, ctx.project_dir);
    // NOTE: eval arenas intentionally leaked; block slices reference them.
    // Matches the lifetime pattern used in src/serve/api.zig.

    const result = eval.evalFile(board_path) catch {
        res.status = 500;
        res.body = "{\"ok\":false,\"error\":\"Build error\"}";
        res.content_type = .JSON;
        return null;
    };

    const block = switch (result) {
        .design_block => |b| b,
        .board => |b| b.design,
        else => {
            res.status = 500;
            res.body = "{\"ok\":false,\"error\":\"Not a design block\"}";
            res.content_type = .JSON;
            return null;
        },
    };

    const bom_path = std.fmt.allocPrint(ctx.allocator, "{s}/src/{s}.bom", .{ ctx.project_dir, name }) catch {
        res.status = 500;
        return null;
    };
    bom.resolveIdentities(ctx.allocator, @constCast(block), bom_path, ctx.project_dir) catch {};
    return block;
}

pub fn writeNetlistApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };

    const cfg = loadConfig(ctx.allocator, ctx.project_dir, name);
    defer {
        if (cfg.output_dir.len > 0) ctx.allocator.free(cfg.output_dir);
        if (cfg.pcb_file.len > 0) ctx.allocator.free(cfg.pcb_file);
    }
    if (cfg.output_dir.len == 0) {
        res.status = 400;
        res.body = "{\"ok\":false,\"error\":\"No output path configured. Set one first.\"}";
        res.content_type = .JSON;
        return;
    }

    const block = loadAndResolve(ctx, name, res) orelse return;

    const netlist = export_kicad.exportNetlistOnly(ctx.allocator, block, ctx.project_dir, name) catch {
        res.status = 500;
        res.body = "{\"ok\":false,\"error\":\"Netlist export error\"}";
        res.content_type = .JSON;
        return;
    };

    const out_path = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}.net", .{ cfg.output_dir, name });
    defer ctx.allocator.free(out_path);

    std.fs.cwd().makePath(cfg.output_dir) catch {};
    const f = std.fs.cwd().createFile(out_path, .{}) catch {
        res.status = 500;
        const body = try std.fmt.allocPrint(ctx.allocator, "{{\"ok\":false,\"error\":\"Cannot write to {s}\"}}", .{out_path});
        res.body = body;
        res.content_type = .JSON;
        return;
    };
    defer f.close();
    f.writeAll(netlist) catch {
        res.status = 500;
        res.body = "{\"ok\":false,\"error\":\"write failed\"}";
        res.content_type = .JSON;
        return;
    };

    const body = try std.fmt.allocPrint(ctx.allocator, "{{\"ok\":true,\"path\":\"{s}\"}}", .{out_path});
    res.content_type = .JSON;
    res.header("access-control-allow-origin", "*");
    res.body = body;
}

pub fn writeKicadApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };

    const cfg = loadConfig(ctx.allocator, ctx.project_dir, name);
    defer {
        if (cfg.output_dir.len > 0) ctx.allocator.free(cfg.output_dir);
        if (cfg.pcb_file.len > 0) ctx.allocator.free(cfg.pcb_file);
    }
    if (cfg.output_dir.len == 0) {
        res.status = 400;
        res.body = "{\"ok\":false,\"error\":\"No output path configured. Set one first.\"}";
        res.content_type = .JSON;
        return;
    }

    const block = loadAndResolve(ctx, name, res) orelse return;

    const netlist = export_kicad.exportNetlistOnly(ctx.allocator, block, ctx.project_dir, name) catch {
        res.status = 500;
        res.body = "{\"ok\":false,\"error\":\"Netlist export error\"}";
        res.content_type = .JSON;
        return;
    };

    std.fs.cwd().makePath(cfg.output_dir) catch {};

    const net_path = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}.net", .{ cfg.output_dir, name });
    defer ctx.allocator.free(net_path);
    {
        const f = std.fs.cwd().createFile(net_path, .{}) catch {
            res.status = 500;
            const body = try std.fmt.allocPrint(ctx.allocator, "{{\"ok\":false,\"error\":\"Cannot write to {s}\"}}", .{net_path});
            res.body = body;
            res.content_type = .JSON;
            return;
        };
        defer f.close();
        f.writeAll(netlist) catch {
            res.status = 500;
            res.body = "{\"ok\":false,\"error\":\"netlist write failed\"}";
            res.content_type = .JSON;
            return;
        };
    }

    const pretty_dir = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}.pretty", .{ cfg.output_dir, name });
    defer ctx.allocator.free(pretty_dir);
    std.fs.cwd().makePath(pretty_dir) catch {};

    export_kicad.exportFootprints(ctx.allocator, block, ctx.project_dir, pretty_dir) catch {
        res.status = 500;
        res.body = "{\"ok\":false,\"error\":\"footprint export failed\"}";
        res.content_type = .JSON;
        return;
    };

    const body = try std.fmt.allocPrint(
        ctx.allocator,
        "{{\"ok\":true,\"netlist\":\"{s}\",\"pretty\":\"{s}\"}}",
        .{ net_path, pretty_dir },
    );
    res.content_type = .JSON;
    res.header("access-control-allow-origin", "*");
    res.body = body;
}

/// POST /api/update-kicad-pcb/:name[?short-nets=1]
/// Writes netlist + footprints + sections JSON, then invokes src/pcb_update.py
/// to merge the netlist into the configured .kicad_pcb file while preserving
/// placements and routing (matched by canopy_uuid).
pub fn writePcbApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };

    const qs = try req.query();
    const short_nets = if (qs.get("short-nets")) |v| std.mem.eql(u8, v, "1") else false;

    const cfg = loadConfig(ctx.allocator, ctx.project_dir, name);
    defer {
        if (cfg.output_dir.len > 0) ctx.allocator.free(cfg.output_dir);
        if (cfg.pcb_file.len > 0) ctx.allocator.free(cfg.pcb_file);
    }
    if (cfg.output_dir.len == 0) {
        res.status = 400;
        res.body = "{\"ok\":false,\"error\":\"No output path configured. Set one first.\"}";
        res.content_type = .JSON;
        return;
    }

    const block = loadAndResolve(ctx, name, res) orelse return;

    const netlist = export_kicad.exportNetlistOnly(ctx.allocator, block, ctx.project_dir, name) catch {
        res.status = 500;
        res.body = "{\"ok\":false,\"error\":\"Netlist export error\"}";
        res.content_type = .JSON;
        return;
    };

    std.fs.cwd().makePath(cfg.output_dir) catch {};

    // Write netlist
    const net_path = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}.net", .{ cfg.output_dir, name });
    defer ctx.allocator.free(net_path);
    {
        const f = std.fs.cwd().createFile(net_path, .{}) catch {
            res.status = 500;
            res.body = "{\"ok\":false,\"error\":\"Cannot write netlist\"}";
            res.content_type = .JSON;
            return;
        };
        defer f.close();
        f.writeAll(netlist) catch {
            res.status = 500;
            res.body = "{\"ok\":false,\"error\":\"netlist write failed\"}";
            res.content_type = .JSON;
            return;
        };
    }

    // Write footprints to {output_dir}/{name}.pretty
    const pretty_dir = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}.pretty", .{ cfg.output_dir, name });
    defer ctx.allocator.free(pretty_dir);
    std.fs.cwd().makePath(pretty_dir) catch {};
    export_kicad.exportFootprints(ctx.allocator, block, ctx.project_dir, pretty_dir) catch {
        res.status = 500;
        res.body = "{\"ok\":false,\"error\":\"footprint export failed\"}";
        res.content_type = .JSON;
        return;
    };

    // Write sections JSON
    const sections_path = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}.sections.json", .{ cfg.output_dir, name });
    defer ctx.allocator.free(sections_path);
    const sections_json = export_kicad.exportSectionLayout(ctx.allocator, block) catch "";
    if (sections_json.len > 0) {
        if (std.fs.cwd().createFile(sections_path, .{})) |sf| {
            defer sf.close();
            sf.writeAll(sections_json) catch {};
        } else |_| {}
    }

    // Resolve PCB path: use configured pcb_file if set, else {output_dir}/{name}.kicad_pcb
    const pcb_path = if (cfg.pcb_file.len > 0)
        try ctx.allocator.dupe(u8, cfg.pcb_file)
    else
        try std.fmt.allocPrint(ctx.allocator, "{s}/{s}.kicad_pcb", .{ cfg.output_dir, name });
    defer ctx.allocator.free(pcb_path);

    // Run pcb_update.py
    var argv_buf: [7][]const u8 = undefined;
    var argc: usize = 0;
    argv_buf[argc] = "python3";
    argc += 1;
    argv_buf[argc] = "src/pcb_update.py";
    argc += 1;
    if (short_nets) {
        argv_buf[argc] = "--short-nets";
        argc += 1;
    }
    argv_buf[argc] = net_path;
    argc += 1;
    argv_buf[argc] = pretty_dir;
    argc += 1;
    argv_buf[argc] = pcb_path;
    argc += 1;
    argv_buf[argc] = sections_path;
    argc += 1;

    const py = std.process.Child.run(.{
        .allocator = ctx.allocator,
        .argv = argv_buf[0..argc],
    }) catch {
        res.status = 500;
        res.body = "{\"ok\":false,\"error\":\"Failed to run pcb_update.py\"}";
        res.content_type = .JSON;
        return;
    };
    defer ctx.allocator.free(py.stdout);
    defer ctx.allocator.free(py.stderr);

    if (py.term.Exited != 0) {
        const output = if (py.stderr.len > 0) py.stderr else py.stdout;
        var err_msg: []const u8 = "PCB update script failed";
        if (std.mem.lastIndexOf(u8, output, "RuntimeError: ")) |idx| {
            const line_end = std.mem.indexOfPos(u8, output, idx, "\n") orelse output.len;
            err_msg = output[idx + 14 .. line_end];
        } else if (std.mem.lastIndexOf(u8, output, "Error: ")) |idx| {
            const line_end = std.mem.indexOfPos(u8, output, idx, "\n") orelse output.len;
            err_msg = output[idx + 7 .. line_end];
        }
        var esc: std.ArrayListUnmanaged(u8) = .empty;
        defer esc.deinit(ctx.allocator);
        const ew = esc.writer(ctx.allocator);
        try writeJsonEscaped(ew, err_msg);
        const body = try std.fmt.allocPrint(ctx.allocator, "{{\"ok\":false,\"error\":\"{s}\"}}", .{esc.items});
        res.status = 500;
        res.body = body;
        res.content_type = .JSON;
        return;
    }

    const body = try std.fmt.allocPrint(
        ctx.allocator,
        "{{\"ok\":true,\"pcb\":\"{s}\"}}",
        .{pcb_path},
    );
    res.content_type = .JSON;
    res.header("access-control-allow-origin", "*");
    res.body = body;
}

fn writeJsonEscaped(writer: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        }
    }
}
