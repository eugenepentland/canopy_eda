const std = @import("std");
const httpz = @import("httpz");
const Sha256 = std.crypto.hash.sha2.Sha256;
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const export_kicad = @import("../export_kicad.zig");
const netlist_mod = @import("../export_kicad_netlist.zig");
const fp_mod = @import("../export_kicad_footprint.zig");
const model_mod = @import("../export_kicad_model.zig");
const pcb_mod = @import("../export_kicad_pcb.zig");
const layout_mod = @import("../layout.zig");
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
///
/// Uses content-addressed caching to skip unchanged artifacts: each click only
/// rewrites the netlist / footprints / STEP files whose hashes (or mtime+size
/// for big STEP blobs) differ from the last sync. When nothing has changed we
/// short-circuit before invoking Python at all — the common "click to confirm"
/// case returns in under 100ms instead of rewriting tens of MB of model files.
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

    // ── Compute desired state (everything we might need to write) ─────

    const netlist = export_kicad.exportNetlistOnly(ctx.allocator, block, ctx.project_dir, name) catch {
        res.status = 500;
        res.body = "{\"ok\":false,\"error\":\"Netlist export error\"}";
        res.content_type = .JSON;
        return;
    };
    const netlist_sha = try sha256Hex(ctx.allocator, netlist);

    const sections_json = export_kicad.exportSectionLayout(ctx.allocator, block) catch "";
    const sections_sha = try sha256Hex(ctx.allocator, sections_json);

    const modules_json = export_kicad.buildModulesJson(ctx.allocator, block) catch "";
    const modules_sha = try sha256Hex(ctx.allocator, modules_json);

    var desired = try collectDesiredFootprintsAndModels(ctx.allocator, block, ctx.project_dir);
    defer desired.deinit(ctx.allocator);

    // ── Load prior cache, compute diff ─────────────────────────────────

    const cache_path = try std.fmt.allocPrint(ctx.allocator, "{s}/.canopy-sync-cache.json", .{cfg.output_dir});
    defer ctx.allocator.free(cache_path);
    var cache = loadCache(ctx.allocator, cache_path);
    defer cache.deinit(ctx.allocator);

    const net_path = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}.net", .{ cfg.output_dir, name });
    defer ctx.allocator.free(net_path);
    const pretty_dir = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}.pretty", .{ cfg.output_dir, name });
    defer ctx.allocator.free(pretty_dir);
    const sections_path = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}.sections.json", .{ cfg.output_dir, name });
    defer ctx.allocator.free(sections_path);
    const modules_path = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}.modules.json", .{ cfg.output_dir, name });
    defer ctx.allocator.free(modules_path);
    const model_dir = try std.fmt.allocPrint(ctx.allocator, "{s}/models", .{cfg.output_dir});
    defer ctx.allocator.free(model_dir);

    // Each flag controls writing one artifact. "File missing on disk"
    // counts as changed — we can't trust the cache if the output isn't there.
    const netlist_changed = !std.mem.eql(u8, cache.netlist_sha, netlist_sha) or !fileExists(net_path);
    const sections_changed = !std.mem.eql(u8, cache.sections_sha, sections_sha) or (sections_json.len > 0 and !fileExists(sections_path));
    const modules_changed = !std.mem.eql(u8, cache.modules_sha, modules_sha) or (modules_json.len > 0 and !fileExists(modules_path));

    var fps_to_write: std.ArrayListUnmanaged(usize) = .empty; // indices into desired.footprints
    defer fps_to_write.deinit(ctx.allocator);
    for (desired.footprints.items, 0..) |fp, i| {
        const cached = cache.footprints.get(fp.kicad_name);
        const mod_path_i = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}.kicad_mod", .{ pretty_dir, fp.kicad_name });
        defer ctx.allocator.free(mod_path_i);
        const exists = fileExists(mod_path_i);
        if (cached == null or !std.mem.eql(u8, cached.?, fp.sha) or !exists) {
            try fps_to_write.append(ctx.allocator, i);
        }
    }

    var models_to_copy: std.ArrayListUnmanaged(usize) = .empty;
    defer models_to_copy.deinit(ctx.allocator);
    for (desired.models.items, 0..) |m, i| {
        const dst = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ model_dir, m.name });
        defer ctx.allocator.free(dst);
        const cached = cache.models.get(m.name);
        const unchanged = cached != null and cached.?.size == m.size and cached.?.mtime_ns == m.mtime_ns and fileExists(dst);
        if (!unchanged) try models_to_copy.append(ctx.allocator, i);
    }

    // Resolve PCB path up front.
    const pcb_path = if (cfg.pcb_file.len > 0)
        try ctx.allocator.dupe(u8, cfg.pcb_file)
    else
        try std.fmt.allocPrint(ctx.allocator, "{s}/{s}.kicad_pcb", .{ cfg.output_dir, name });
    defer ctx.allocator.free(pcb_path);

    // ── Always rewrite the artifacts that actually changed and invoke
    //    pcb_update.py. The cache still skips unchanged .kicad_mod / STEP
    //    writes, but the sync button never short-circuits — the user wants
    //    every click to refresh the PCB even when nothing upstream changed.

    std.fs.cwd().makePath(cfg.output_dir) catch {};
    std.fs.cwd().makePath(pretty_dir) catch {};
    std.fs.cwd().makePath(model_dir) catch {};

    if (netlist_changed) {
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
        cache.setNetlistSha(ctx.allocator, netlist_sha);
    }

    if (sections_changed and sections_json.len > 0) {
        if (std.fs.cwd().createFile(sections_path, .{})) |sf| {
            defer sf.close();
            sf.writeAll(sections_json) catch {};
        } else |_| {}
        cache.setSectionsSha(ctx.allocator, sections_sha);
    }

    if (modules_changed and modules_json.len > 0) {
        if (std.fs.cwd().createFile(modules_path, .{})) |mf| {
            defer mf.close();
            mf.writeAll(modules_json) catch {};
        } else |_| {}
        cache.setModulesSha(ctx.allocator, modules_sha);
    }

    for (fps_to_write.items) |i| {
        const fp = desired.footprints.items[i];
        const mod_path = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}.kicad_mod", .{ pretty_dir, fp.kicad_name });
        defer ctx.allocator.free(mod_path);
        const f = std.fs.cwd().createFile(mod_path, .{}) catch continue;
        defer f.close();
        f.writeAll(fp.bytes) catch continue;
        try cache.putFootprint(ctx.allocator, fp.kicad_name, fp.sha);
    }

    for (models_to_copy.items) |i| {
        const m = desired.models.items[i];
        const src = try std.fmt.allocPrint(ctx.allocator, "{s}/lib/models/{s}", .{ ctx.project_dir, m.name });
        defer ctx.allocator.free(src);
        const dst = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ model_dir, m.name });
        defer ctx.allocator.free(dst);
        std.fs.cwd().copyFile(src, std.fs.cwd(), dst, .{}) catch continue;
        try cache.putModel(ctx.allocator, m.name, .{ .size = m.size, .mtime_ns = m.mtime_ns });
    }

    // Always run pcb_update.py — even when only models (or nothing) changed,
    // the user may have edited the .kicad_pcb externally and expects the
    // sync button to repush.

    // Run pcb_update.py
    var argv_buf: [11][]const u8 = undefined;
    var argc: usize = 0;
    argv_buf[argc] = "python3";
    argc += 1;
    argv_buf[argc] = "src/pcb_update.py";
    argc += 1;
    if (short_nets) {
        argv_buf[argc] = "--short-nets";
        argc += 1;
    }
    if (modules_json.len > 0) {
        argv_buf[argc] = "--modules";
        argc += 1;
        argv_buf[argc] = modules_path;
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
        // Python failed — invalidate cache so the next sync rewrites everything.
        std.fs.cwd().deleteFile(cache_path) catch {};
        try respondScriptFailure(ctx, res, py.stdout, py.stderr);
        return;
    }

    // Persist cache now that the full pipeline succeeded.
    saveCache(ctx.allocator, cache_path, &cache);

    const summary = parseSummaryLine(py.stdout);

    // Refresh the project's .layout file from the updated .kicad_pcb so the
    // canvas viewer picks up both adopted follower placements and any other
    // positions the user changed in KiCad since the last sync.
    syncLayoutFromPcb(ctx.allocator, block, ctx.project_dir, name, pcb_path);

    var esc_backup: std.ArrayListUnmanaged(u8) = .empty;
    defer esc_backup.deinit(ctx.allocator);
    try writeJsonEscaped(esc_backup.writer(ctx.allocator), summary.backup);

    const body = try std.fmt.allocPrint(
        ctx.allocator,
        "{{\"ok\":true,\"skipped\":false,\"pcb\":\"{s}\",\"backup\":\"{s}\",\"mismatches\":{d},\"missing\":{d},\"seeded\":{d},\"wrote_footprints\":{d},\"wrote_models\":{d}}}",
        .{ pcb_path, esc_backup.items, summary.mismatches, summary.missing, summary.seeded, fps_to_write.items.len, models_to_copy.items.len },
    );
    res.content_type = .JSON;
    res.header("access-control-allow-origin", "*");
    res.body = body;
}

const ScriptSummary = struct {
    mismatches: u32 = 0,
    missing: u32 = 0,
    seeded: u32 = 0,
    backup: []const u8 = "",
};

/// Parse the last `SUMMARY mismatches=N missing=M backup=PATH` line written by
/// pcb_update.py. If the line is absent (older script or aborted early), all
/// fields are zero / empty — the caller treats that as "unknown, assume ok".
fn parseSummaryLine(stdout: []const u8) ScriptSummary {
    const tag = "\nSUMMARY ";
    const found = std.mem.lastIndexOf(u8, stdout, tag) orelse return .{};
    const start = found + 1;
    const end = std.mem.indexOfPos(u8, stdout, start, "\n") orelse stdout.len;
    const line = stdout[start..end];

    var result: ScriptSummary = .{};
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    _ = it.next(); // skip "SUMMARY"
    while (it.next()) |kv| {
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        const key = kv[0..eq];
        const val = kv[eq + 1 ..];
        if (std.mem.eql(u8, key, "mismatches")) {
            result.mismatches = std.fmt.parseInt(u32, val, 10) catch 0;
        } else if (std.mem.eql(u8, key, "missing")) {
            result.missing = std.fmt.parseInt(u32, val, 10) catch 0;
        } else if (std.mem.eql(u8, key, "seeded")) {
            result.seeded = std.fmt.parseInt(u32, val, 10) catch 0;
        } else if (std.mem.eql(u8, key, "backup")) {
            result.backup = if (std.mem.eql(u8, val, "-")) "" else val;
        }
    }
    return result;
}

fn respondScriptFailure(
    ctx: *Handler,
    res: *httpz.Response,
    stdout: []const u8,
    stderr: []const u8,
) !void {
    var err_msg: []const u8 = "PCB update script failed";
    const err_source = if (stderr.len > 0) stderr else stdout;
    if (std.mem.lastIndexOf(u8, err_source, "RuntimeError: ")) |idx| {
        const line_end = std.mem.indexOfPos(u8, err_source, idx, "\n") orelse err_source.len;
        err_msg = err_source[idx + 14 .. line_end];
    } else if (std.mem.lastIndexOf(u8, err_source, "Error: ")) |idx| {
        const line_end = std.mem.indexOfPos(u8, err_source, idx, "\n") orelse err_source.len;
        err_msg = err_source[idx + 7 .. line_end];
    }

    // Extract preflight missing-footprint block from stdout, if present — it
    // lists which components blocked the run, not in the RuntimeError line.
    var preflight: []const u8 = "";
    if (std.mem.indexOf(u8, stdout, "Preflight: missing footprints")) |pf_idx| {
        // Block runs from pf_idx until the first line not starting with "  ".
        var scan = pf_idx;
        while (true) {
            const nl = std.mem.indexOfScalarPos(u8, stdout, scan, '\n') orelse break;
            const next_line_start = nl + 1;
            if (next_line_start >= stdout.len) {
                scan = stdout.len;
                break;
            }
            if (!std.mem.startsWith(u8, stdout[next_line_start..], "  ")) {
                scan = nl;
                break;
            }
            scan = next_line_start;
        }
        preflight = stdout[pf_idx..scan];
    }

    var esc_msg: std.ArrayListUnmanaged(u8) = .empty;
    defer esc_msg.deinit(ctx.allocator);
    try writeJsonEscaped(esc_msg.writer(ctx.allocator), err_msg);

    var esc_pre: std.ArrayListUnmanaged(u8) = .empty;
    defer esc_pre.deinit(ctx.allocator);
    try writeJsonEscaped(esc_pre.writer(ctx.allocator), preflight);

    const body = try std.fmt.allocPrint(
        ctx.allocator,
        "{{\"ok\":false,\"error\":\"{s}\",\"preflight\":\"{s}\"}}",
        .{ esc_msg.items, esc_pre.items },
    );
    res.status = 500;
    res.body = body;
    res.content_type = .JSON;
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

// ── Incremental-sync cache ──────────────────────────────────────────────
//
// Content-addressed state of the last successful sync so the button can
// short-circuit unchanged artifacts. Stored next to the output files as
// `{output_dir}/.canopy-sync-cache.json`.

const ModelMeta = struct {
    size: u64 = 0,
    // i64 nanoseconds since epoch — std.json can't round-trip i128 losslessly.
    // Ranges ~±292 years from 1970, comfortably covering file mtimes.
    mtime_ns: i64 = 0,
};

const DesiredFootprint = struct {
    kicad_name: []const u8, // basename that lands in .pretty/
    sha: []const u8, // sha of the generated .kicad_mod bytes
    bytes: []const u8, // generated .kicad_mod bytes (written if changed)
};

const DesiredModel = struct {
    name: []const u8,
    size: u64,
    mtime_ns: i64,
};

const DesiredState = struct {
    footprints: std.ArrayListUnmanaged(DesiredFootprint),
    models: std.ArrayListUnmanaged(DesiredModel),

    fn deinit(self: *DesiredState, allocator: std.mem.Allocator) void {
        self.footprints.deinit(allocator);
        self.models.deinit(allocator);
    }
};

/// Walk the design's instances once and produce the full list of footprint
/// .kicad_mod bytes (with content hashes) and referenced STEP models (with
/// their source mtime+size) that a full export would write. The diff between
/// this and the cache tells us exactly which files need to be touched on disk.
fn collectDesiredFootprintsAndModels(
    allocator: std.mem.Allocator,
    block: *const @import("../eval/env.zig").DesignBlock,
    project_dir: []const u8,
) !DesiredState {
    var instances: std.ArrayListUnmanaged(export_kicad.FlatInstance) = .empty;
    defer instances.deinit(allocator);
    try netlist_mod.collectInstances(allocator, block, "", &instances);

    var model_cfg = export_kicad.loadModelConfig(allocator, project_dir);
    defer model_cfg.deinit();

    var state = DesiredState{ .footprints = .empty, .models = .empty };

    var seen_fps = std.StringHashMap(void).init(allocator);
    defer seen_fps.deinit();
    var seen_models = std.StringHashMap(void).init(allocator);
    defer seen_models.deinit();

    for (instances.items) |inst| {
        if (inst.footprint.len == 0) continue;
        if (seen_fps.contains(inst.footprint)) continue;
        try seen_fps.put(inst.footprint, {});

        const fp_path = try std.fmt.allocPrint(allocator, "{s}/lib/footprints/{s}.sexp", .{ project_dir, inst.footprint });
        defer allocator.free(fp_path);
        const fp_source = std.fs.cwd().readFileAlloc(allocator, fp_path, 1024 * 1024) catch continue;
        defer allocator.free(fp_source);

        const kicad_name = netlist_mod.extractFootprintName(allocator, fp_source) catch try allocator.dupe(u8, inst.footprint);
        const mcfg = model_cfg.get(inst.footprint);
        const model_name = if (mcfg) |c| (c.model orelse fp_mod.findModelFile(allocator, project_dir, inst.footprint, inst.component)) else fp_mod.findModelFile(allocator, project_dir, inst.footprint, inst.component);

        const mod_bytes = model_mod.buildKicadMod(
            allocator,
            project_dir,
            inst.footprint,
            fp_source,
            model_name,
            if (mcfg) |c| c.offset else null,
            if (mcfg) |c| c.rotation else null,
        ) catch continue;

        const sha = try sha256Hex(allocator, mod_bytes);
        try state.footprints.append(allocator, .{
            .kicad_name = kicad_name,
            .sha = sha,
            .bytes = mod_bytes,
        });

        // Model: cheap stat, no hashing (50MB STEP files would be wasteful
        // to hash per click; mtime+size catches edits in practice).
        if (model_name) |mname| {
            const keep_mname = mcfg != null;
            if (seen_models.contains(mname)) {
                if (!keep_mname) allocator.free(mname);
                continue;
            }
            try seen_models.put(try allocator.dupe(u8, mname), {});
            const src_path = try std.fmt.allocPrint(allocator, "{s}/lib/models/{s}", .{ project_dir, mname });
            defer allocator.free(src_path);
            if (std.fs.cwd().statFile(src_path)) |st| {
                try state.models.append(allocator, .{
                    .name = try allocator.dupe(u8, mname),
                    .size = @intCast(st.size),
                    .mtime_ns = @truncate(st.mtime),
                });
            } else |_| {}
            if (!keep_mname) allocator.free(mname);
        }
    }

    return state;
}

const SyncCache = struct {
    netlist_sha: []const u8 = "",
    sections_sha: []const u8 = "",
    modules_sha: []const u8 = "",
    footprints: std.StringHashMapUnmanaged([]const u8) = .empty,
    models: std.StringHashMapUnmanaged(ModelMeta) = .empty,

    fn deinit(self: *SyncCache, allocator: std.mem.Allocator) void {
        self.footprints.deinit(allocator);
        self.models.deinit(allocator);
    }

    fn setNetlistSha(self: *SyncCache, allocator: std.mem.Allocator, sha: []const u8) void {
        _ = allocator;
        self.netlist_sha = sha;
    }
    fn setSectionsSha(self: *SyncCache, allocator: std.mem.Allocator, sha: []const u8) void {
        _ = allocator;
        self.sections_sha = sha;
    }
    fn setModulesSha(self: *SyncCache, allocator: std.mem.Allocator, sha: []const u8) void {
        _ = allocator;
        self.modules_sha = sha;
    }
    fn putFootprint(self: *SyncCache, allocator: std.mem.Allocator, name: []const u8, sha: []const u8) !void {
        try self.footprints.put(allocator, name, sha);
    }
    fn putModel(self: *SyncCache, allocator: std.mem.Allocator, name: []const u8, meta: ModelMeta) !void {
        try self.models.put(allocator, name, meta);
    }
};

fn loadCache(allocator: std.mem.Allocator, path: []const u8) SyncCache {
    const data = std.fs.cwd().readFileAlloc(allocator, path, 4 * 1024 * 1024) catch return .{};
    const Entry = struct {
        netlist_sha: []const u8 = "",
        sections_sha: []const u8 = "",
        modules_sha: []const u8 = "",
        footprints: []const struct { name: []const u8, sha: []const u8 } = &.{},
        models: []const struct { name: []const u8, size: u64 = 0, mtime_ns: i64 = 0 } = &.{},
    };
    const parsed = std.json.parseFromSlice(Entry, allocator, data, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch return .{};
    var out = SyncCache{
        .netlist_sha = allocator.dupe(u8, parsed.value.netlist_sha) catch "",
        .sections_sha = allocator.dupe(u8, parsed.value.sections_sha) catch "",
        .modules_sha = allocator.dupe(u8, parsed.value.modules_sha) catch "",
    };
    for (parsed.value.footprints) |e| {
        const k = allocator.dupe(u8, e.name) catch continue;
        const v = allocator.dupe(u8, e.sha) catch continue;
        out.footprints.put(allocator, k, v) catch {};
    }
    for (parsed.value.models) |e| {
        const k = allocator.dupe(u8, e.name) catch continue;
        out.models.put(allocator, k, .{ .size = e.size, .mtime_ns = e.mtime_ns }) catch {};
    }
    return out;
}

fn saveCache(allocator: std.mem.Allocator, path: []const u8, cache: *const SyncCache) void {
    const parent = std.fs.path.dirname(path) orelse ".";
    std.fs.cwd().makePath(parent) catch {};
    const f = std.fs.cwd().createFile(path, .{}) catch return;
    defer f.close();

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    w.print("{{\"netlist_sha\":\"{s}\",\"sections_sha\":\"{s}\",\"modules_sha\":\"{s}\",\"footprints\":[", .{ cache.netlist_sha, cache.sections_sha, cache.modules_sha }) catch return;
    var first = true;
    var it = cache.footprints.iterator();
    while (it.next()) |e| {
        if (!first) w.writeAll(",") catch return;
        first = false;
        w.writeAll("{\"name\":") catch return;
        writeJsonString(w, e.key_ptr.*) catch return;
        w.writeAll(",\"sha\":\"") catch return;
        w.writeAll(e.value_ptr.*) catch return;
        w.writeAll("\"}") catch return;
    }
    w.writeAll("],\"models\":[") catch return;
    first = true;
    var mit = cache.models.iterator();
    while (mit.next()) |e| {
        if (!first) w.writeAll(",") catch return;
        first = false;
        w.writeAll("{\"name\":") catch return;
        writeJsonString(w, e.key_ptr.*) catch return;
        w.print(",\"size\":{d},\"mtime_ns\":{d}}}", .{ e.value_ptr.size, e.value_ptr.mtime_ns }) catch return;
    }
    w.writeAll("]}") catch return;
    f.writeAll(buf.items) catch {};
}

fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

/// After `pcb_update.py` has written the updated .kicad_pcb, rebuild the
/// project's `.layout` file from the board's current footprint positions.
/// Placements are keyed by `canopy_uuid`; traces, vias, zone fills, and rules
/// are preserved from the pre-existing `.layout` (if any) so the canvas
/// viewer's routing state survives a sync.
///
/// Silent on failure: the sync has already succeeded, and the viewer can
/// always fall back to reading placements out of the .kicad_pcb directly.
fn syncLayoutFromPcb(
    allocator: std.mem.Allocator,
    block: *const @import("../eval/env.zig").DesignBlock,
    project_dir: []const u8,
    name: []const u8,
    pcb_path: []const u8,
) void {
    const pcb_content = std.fs.cwd().readFileAlloc(allocator, pcb_path, 100 * 1024 * 1024) catch return;
    defer allocator.free(pcb_content);

    var placed = std.StringHashMap(pcb_mod.PlacedFootprint).init(allocator);
    defer placed.deinit();
    pcb_mod.parseExistingPlacements(allocator, pcb_content, &placed);

    var instances: std.ArrayListUnmanaged(export_kicad.FlatInstance) = .empty;
    defer instances.deinit(allocator);
    netlist_mod.collectInstances(allocator, block, "", &instances) catch return;

    var placements: std.ArrayListUnmanaged(layout_mod.Placement) = .empty;
    defer placements.deinit(allocator);
    for (instances.items) |inst| {
        if (inst.uuid.len == 0) continue;
        const p = placed.get(inst.uuid) orelse continue;
        placements.append(allocator, .{
            .ref_des = inst.ref_des,
            .x = p.x,
            .y = p.y,
            .angle = p.angle,
            .side = if (p.flipped) .back else .front,
            .uuid = inst.uuid,
        }) catch return;
    }

    const layout_path = std.fmt.allocPrint(allocator, "{s}/src/{s}.layout", .{ project_dir, name }) catch return;
    defer allocator.free(layout_path);

    // Preserve routing data from the prior .layout.
    var existing_traces: []const layout_mod.Trace = &.{};
    var existing_vias: []const layout_mod.Via = &.{};
    var existing_zone_fills: []const layout_mod.ZoneFill = &.{};
    var existing_rules: ?layout_mod.Rules = null;
    if (layout_mod.loadLayout(allocator, layout_path)) |prev| {
        existing_traces = prev.traces;
        existing_vias = prev.vias;
        existing_zone_fills = prev.zone_fills;
        existing_rules = prev.rules;
    } else |_| {}

    const layout = layout_mod.Layout{
        .placements = placements.items,
        .traces = existing_traces,
        .vias = existing_vias,
        .zone_fills = existing_zone_fills,
        .rules = existing_rules,
    };
    layout_mod.saveLayout(allocator, &layout, layout_path) catch {};
}

fn sha256Hex(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    Sha256.hash(input, &digest, .{});
    const hex = "0123456789abcdef";
    var out = try allocator.alloc(u8, 64);
    for (digest, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0f];
    }
    return out;
}

fn writeJsonString(w: anytype, s: []const u8) !void {
    try w.writeAll("\"");
    for (s) |ch| switch (ch) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{ch}),
        else => try w.writeByte(ch),
    };
    try w.writeAll("\"");
}
