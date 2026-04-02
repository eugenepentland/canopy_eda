const std = @import("std");
const httpz = @import("httpz");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const render_svg = @import("../render_svg.zig");
const render_json = @import("../render_json.zig");
const render_block = @import("../render_block.zig");
const export_kicad = @import("../export_kicad.zig");
const bom = @import("../bom.zig");
const serve_root = @import("../serve.zig");
const Handler = serve_root.Handler;

pub fn pushApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
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

    const new_svg = render_svg.renderSchematic(ctx.allocator, block) catch {
        res.status = 500;
        res.body = "Render error";
        return;
    };

    const new_layout = render_json.renderSceneGraph(ctx.allocator, block) catch null;

    serve_root.live_mutex.lock();
    serve_root.live_svg = new_svg;
    serve_root.live_layout_json = new_layout;
    serve_root.live_version += 1;
    const v = serve_root.live_version;
    serve_root.live_mutex.unlock();

    std.debug.print("Pushed {s} (v{d})\n", .{ name, v });
    res.body = "ok";
}

pub fn versionApi(_: *Handler, _: *httpz.Request, res: *httpz.Response) !void {
    serve_root.live_mutex.lock();
    const v = serve_root.live_version;
    serve_root.live_mutex.unlock();

    res.content_type = .JSON;
    res.header("access-control-allow-origin", "*");
    const w = res.writer();
    try w.print("{{\"version\":{d}}}", .{v});
}

pub fn svgApi(_: *Handler, _: *httpz.Request, res: *httpz.Response) !void {
    serve_root.live_mutex.lock();
    const new_svg = serve_root.live_svg;
    serve_root.live_mutex.unlock();

    res.content_type = .SVG;
    res.header("access-control-allow-origin", "*");
    res.body = new_svg orelse "<!-- no svg -->";
}

pub fn sceneGraphApi(_: *Handler, _: *httpz.Request, res: *httpz.Response) !void {
    serve_root.live_mutex.lock();
    const data = serve_root.live_layout_json;
    serve_root.live_mutex.unlock();

    res.content_type = .JSON;
    res.header("access-control-allow-origin", "*");
    res.body = data orelse "{\"error\":\"no layout\"}";
}

pub fn blockDiagramApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
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

    const svg = render_block.renderBlockDiagram(ctx.allocator, block) catch {
        res.status = 500;
        res.body = "Render error";
        return;
    };

    res.content_type = .SVG;
    res.header("access-control-allow-origin", "*");
    res.body = svg;
}

pub fn layoutGetApi(_: *Handler, _: *httpz.Request, res: *httpz.Response) !void {
    serve_root.layout_mutex.lock();
    const data = serve_root.layout_data;
    serve_root.layout_mutex.unlock();

    res.content_type = .JSON;
    res.header("access-control-allow-origin", "*");
    res.body = data orelse "{}";
}

pub fn layoutPostApi(_: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const body = req.body() orelse "{}";

    serve_root.layout_mutex.lock();
    serve_root.layout_data = body;
    serve_root.layout_mutex.unlock();

    res.content_type = .JSON;
    res.header("access-control-allow-origin", "*");
    res.body = "{\"ok\":true}";
}

pub fn exportKicadApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
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

    const bom_path = std.fmt.allocPrint(ctx.allocator, "{s}/src/{s}.bom", .{ ctx.project_dir, name }) catch {
        res.status = 500;
        return;
    };
    bom.resolveIdentities(ctx.allocator, block, bom_path, ctx.project_dir) catch {};

    const zip_data = export_kicad.exportKicadZip(ctx.allocator, block, ctx.project_dir, name) catch {
        res.status = 500;
        res.body = "Export error";
        return;
    };

    const disposition = std.fmt.allocPrint(ctx.allocator, "attachment; filename=\"{s}-kicad.zip\"", .{name}) catch {
        res.status = 500;
        return;
    };

    res.header("Content-Type", "application/zip");
    res.header("Content-Disposition", disposition);
    res.body = zip_data;
}

pub fn exportNetlistApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
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

    const bom_path = std.fmt.allocPrint(ctx.allocator, "{s}/src/{s}.bom", .{ ctx.project_dir, name }) catch {
        res.status = 500;
        return;
    };
    bom.resolveIdentities(ctx.allocator, block, bom_path, ctx.project_dir) catch {};

    const netlist = export_kicad.exportNetlistOnly(ctx.allocator, block, ctx.project_dir, name) catch {
        res.status = 500;
        res.body = "Export error";
        return;
    };

    const disposition = std.fmt.allocPrint(ctx.allocator, "attachment; filename=\"{s}.net\"", .{name}) catch {
        res.status = 500;
        return;
    };

    res.header("Content-Type", "text/plain");
    res.header("Content-Disposition", disposition);
    res.body = netlist;
}

pub fn updatePcbApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const qs = try req.query();
    const short_nets = if (qs.get("short-nets")) |v| std.mem.eql(u8, v, "1") else false;
    const name = "stm32n6"; // TODO: parameterize

    const board_path = std.fmt.allocPrint(ctx.allocator, "{s}/src/{s}.sexp", .{ ctx.project_dir, name }) catch {
        res.status = 500;
        return;
    };
    defer ctx.allocator.free(board_path);

    var eval = Evaluator.init(ctx.allocator, ctx.project_dir);
    defer eval.deinit();

    const result = eval.evalFile(board_path) catch {
        res.status = 500;
        res.body = "{\"ok\":false,\"error\":\"Build error\"}";
        res.content_type = .JSON;
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
    bom.resolveIdentities(ctx.allocator, block, bom_path, ctx.project_dir) catch {};

    const netlist = export_kicad.exportNetlistOnly(ctx.allocator, block, ctx.project_dir, name) catch {
        res.status = 500;
        res.body = "{\"ok\":false,\"error\":\"Export error\"}";
        res.content_type = .JSON;
        return;
    };

    export_kicad.exportFootprints(ctx.allocator, block, ctx.project_dir, "/mnt/nas/Cyclops/Cyclops Digital/footprints.pretty") catch {};

    const sections_json = export_kicad.exportSectionLayout(ctx.allocator, block) catch "";
    const sections_path = "/mnt/nas/Cyclops/Cyclops Digital/stm32n6.sections.json";

    const net_path = "/mnt/nas/Cyclops/Cyclops Digital/stm32n6.net";
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
            return;
        };
    }

    if (sections_json.len > 0) {
        const sf = std.fs.cwd().createFile(sections_path, .{}) catch null;
        if (sf) |f| {
            defer f.close();
            f.writeAll(sections_json) catch {};
        }
    }

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
    argv_buf[argc] = "/mnt/nas/Cyclops/Cyclops Digital/footprints.pretty";
    argc += 1;
    argv_buf[argc] = "/mnt/nas/Cyclops/Cyclops Digital/Cyclops Digital.kicad_pcb";
    argc += 1;
    argv_buf[argc] = sections_path;
    argc += 1;
    const py_result = std.process.Child.run(.{
        .allocator = ctx.allocator,
        .argv = argv_buf[0..argc],
    }) catch {
        res.status = 500;
        res.body = "{\"ok\":false,\"error\":\"Failed to run pcb_update.py\"}";
        res.content_type = .JSON;
        return;
    };
    defer ctx.allocator.free(py_result.stdout);
    defer ctx.allocator.free(py_result.stderr);

    if (py_result.term.Exited != 0) {
        const output = if (py_result.stderr.len > 0) py_result.stderr else py_result.stdout;
        var err_msg: []const u8 = "PCB update script failed";
        if (std.mem.lastIndexOf(u8, output, "RuntimeError: ")) |idx| {
            const line_end = std.mem.indexOfPos(u8, output, idx, "\n") orelse output.len;
            err_msg = output[idx + 14 .. line_end];
        } else if (std.mem.lastIndexOf(u8, output, "Error: ")) |idx| {
            const line_end = std.mem.indexOfPos(u8, output, idx, "\n") orelse output.len;
            err_msg = output[idx + 7 .. line_end];
        }
        const body = std.fmt.allocPrint(ctx.allocator, "{{\"ok\":false,\"error\":\"{s}\"}}", .{err_msg}) catch {
            res.body = "{\"ok\":false,\"error\":\"PCB update script failed\"}";
            res.content_type = .JSON;
            return;
        };
        res.body = body;
        res.content_type = .JSON;
        return;
    }

    res.body = "{\"ok\":true}";
    res.content_type = .JSON;
}
