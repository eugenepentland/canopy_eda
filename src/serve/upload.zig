const std = @import("std");
const httpz = @import("httpz");
const serve_root = @import("../serve.zig");
const Handler = serve_root.Handler;

pub fn uploadZipApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const body = req.body() orelse {
        res.status = 400;
        res.body = "No data";
        return;
    };
    const filename = req.header("x-filename") orelse "upload.zip";

    const tmp_zip = std.fmt.allocPrint(ctx.allocator, "/tmp/eda-upload-{s}", .{filename}) catch {
        res.status = 500;
        return;
    };
    defer ctx.allocator.free(tmp_zip);
    {
        const f = std.fs.cwd().createFile(tmp_zip, .{}) catch {
            res.status = 500;
            res.body = "Cannot write temp file";
            return;
        };
        defer f.close();
        f.writeAll(body) catch {
            res.status = 500;
            return;
        };
    }

    const tmp_dir = std.fmt.allocPrint(ctx.allocator, "/tmp/eda-extract-{d}", .{std.time.milliTimestamp()}) catch {
        res.status = 500;
        return;
    };
    defer ctx.allocator.free(tmp_dir);

    const unzip_result = std.process.Child.run(.{
        .allocator = ctx.allocator,
        .argv = &.{ "unzip", "-o", "-q", tmp_zip, "-d", tmp_dir },
    }) catch {
        res.status = 500;
        res.body = "Failed to extract zip (is unzip installed?)";
        return;
    };
    if (unzip_result.term.Exited != 0) {
        res.status = 500;
        res.body = "Zip extraction failed";
        return;
    }

    var sym_path: ?[]const u8 = null;
    var fp_path: ?[]const u8 = null;
    var step_path: ?[]const u8 = null;

    const find_result = std.process.Child.run(.{
        .allocator = ctx.allocator,
        .argv = &.{ "find", tmp_dir, "-type", "f" },
    }) catch {
        res.status = 500;
        res.body = "Failed to scan extracted files";
        return;
    };

    var line_iter = std.mem.splitScalar(u8, find_result.stdout, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.endsWith(u8, line, ".kicad_sym")) sym_path = line;
        if (std.mem.endsWith(u8, line, ".kicad_mod")) fp_path = line;
        if (std.mem.endsWith(u8, line, ".stp") or std.mem.endsWith(u8, line, ".step")) step_path = line;
    }

    if (sym_path == null or fp_path == null) {
        res.status = 400;
        const msg = std.fmt.allocPrint(ctx.allocator, "Zip must contain a .kicad_sym and .kicad_mod file (found sym={s}, fp={s})", .{
            if (sym_path) |s| s else "none",
            if (fp_path) |f| f else "none",
        }) catch "Missing KiCad files in zip";
        res.body = msg;
        return;
    }

    const sym_data = std.fs.cwd().readFileAlloc(ctx.allocator, sym_path.?, 10 * 1024 * 1024) catch {
        res.status = 500;
        res.body = "Cannot read symbol from zip";
        return;
    };
    const fp_data = std.fs.cwd().readFileAlloc(ctx.allocator, fp_path.?, 10 * 1024 * 1024) catch {
        res.status = 500;
        res.body = "Cannot read footprint from zip";
        return;
    };
    const step_data: ?[]const u8 = if (step_path) |sp|
        (std.fs.cwd().readFileAlloc(ctx.allocator, sp, 50 * 1024 * 1024) catch null)
    else
        null;

    const sym_basename = std.fs.path.basename(sym_path.?);
    const fp_basename = std.fs.path.basename(fp_path.?);

    const pkg_name = extractPackageName(sym_data);

    saveSourceFile(ctx.allocator, ctx.project_dir, sym_basename, sym_data);
    saveSourceFile(ctx.allocator, ctx.project_dir, fp_basename, fp_data);
    if (step_data != null and step_path != null) {
        saveSourceFile(ctx.allocator, ctx.project_dir, std.fs.path.basename(step_path.?), step_data.?);
    }

    const symbol_conv = @import("../convert/symbol.zig");
    const pinout = symbol_conv.generatePinout(ctx.allocator, sym_data, null) catch {
        res.status = 500;
        res.body = "Pinout generation failed";
        return;
    };

    const footprint_conv = @import("../convert/footprint.zig");
    const footprint = footprint_conv.convertFootprint(ctx.allocator, fp_data) catch {
        res.status = 500;
        res.body = "Footprint conversion failed";
        return;
    };

    const safe_name = sanitizeName(ctx.allocator, pkg_name);

    // Write pinout
    {
        const dir = std.fmt.allocPrint(ctx.allocator, "{s}/lib/pinouts", .{ctx.project_dir}) catch {
            res.status = 500;
            return;
        };
        std.fs.cwd().makePath(dir) catch {};
        const path = std.fmt.allocPrint(ctx.allocator, "{s}/{s}.sexp", .{ dir, safe_name }) catch {
            res.status = 500;
            return;
        };
        const f = std.fs.cwd().createFile(path, .{}) catch {
            res.status = 500;
            return;
        };
        defer f.close();
        f.writeAll(pinout) catch {};
    }

    // Write footprint
    {
        const fp_name = extractFootprintName(ctx.allocator, footprint) orelse safe_name;
        const dir = std.fmt.allocPrint(ctx.allocator, "{s}/lib/footprints", .{ctx.project_dir}) catch {
            res.status = 500;
            return;
        };
        std.fs.cwd().makePath(dir) catch {};
        const path = std.fmt.allocPrint(ctx.allocator, "{s}/{s}.sexp", .{ dir, fp_name }) catch {
            res.status = 500;
            return;
        };
        const f = std.fs.cwd().createFile(path, .{}) catch {
            res.status = 500;
            return;
        };
        defer f.close();
        f.writeAll(footprint) catch {};
    }

    // Write STEP model
    if (step_data) |sd| {
        const dir = std.fmt.allocPrint(ctx.allocator, "{s}/lib/models", .{ctx.project_dir}) catch "";
        if (dir.len > 0) {
            std.fs.cwd().makePath(dir) catch {};
            const path = std.fmt.allocPrint(ctx.allocator, "{s}/{s}.step", .{ dir, safe_name }) catch "";
            if (path.len > 0) {
                const f = std.fs.cwd().createFile(path, .{}) catch null;
                if (f) |file| {
                    defer file.close();
                    file.writeAll(sd) catch {};
                }
            }
        }
    }

    // Clean up temp files
    std.fs.cwd().deleteFile(tmp_zip) catch {};
    _ = std.process.Child.run(.{
        .allocator = ctx.allocator,
        .argv = &.{ "rm", "-rf", tmp_dir },
    }) catch {};

    const step_msg: []const u8 = if (step_data != null) " + 3D model" else "";
    const msg = std.fmt.allocPrint(ctx.allocator, "Created pinout + footprint{s} for \"{s}\" (sources saved)", .{ step_msg, pkg_name }) catch {
        res.body = "OK";
        return;
    };
    std.debug.print("Zip upload: {s}\n", .{msg});
    res.body = msg;
}

/// Save raw source file to lib/sources/ for future re-parsing.
pub fn saveSourceFile(allocator: std.mem.Allocator, project_dir: []const u8, filename: []const u8, body_data: []const u8) void {
    const dir_path = std.fmt.allocPrint(allocator, "{s}/lib/sources", .{project_dir}) catch return;
    defer allocator.free(dir_path);
    std.fs.cwd().makePath(dir_path) catch {};

    const out_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, filename }) catch return;
    defer allocator.free(out_path);

    const file = std.fs.cwd().createFile(out_path, .{}) catch return;
    defer file.close();
    file.writeAll(body_data) catch {};
    std.debug.print("Saved source: lib/sources/{s}\n", .{filename});
}

// ── Shared helpers ────────────────────────────────────────────────────

pub fn extractPackageName(sym_data: []const u8) []const u8 {
    var search_pos: usize = 0;
    if (std.mem.indexOf(u8, sym_data, "(kicad_symbol_lib")) |_| {
        if (std.mem.indexOf(u8, sym_data, "\n  (symbol \"")) |idx| {
            search_pos = idx;
        }
    }
    if (std.mem.indexOfPos(u8, sym_data, search_pos, "(symbol \"")) |idx| {
        const name_start = idx + 9;
        if (std.mem.indexOfPos(u8, sym_data, name_start, "\"")) |name_end| {
            return sym_data[name_start..name_end];
        }
    }
    return "package";
}

pub fn sanitizeName(allocator: std.mem.Allocator, name: []const u8) []const u8 {
    var safe_name: std.ArrayListUnmanaged(u8) = .empty;
    for (name) |c| {
        const sc: u8 = switch (c) {
            'A'...'Z' => c + 32,
            ' ', '.', '_' => '-',
            else => c,
        };
        safe_name.append(allocator, sc) catch continue;
    }
    return safe_name.items;
}

pub fn extractFootprintName(allocator: std.mem.Allocator, footprint: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, footprint, "(footprint \"")) |idx| {
        const ns = idx + 12;
        if (std.mem.indexOfPos(u8, footprint, ns, "\"")) |ne| {
            var fp_safe: std.ArrayListUnmanaged(u8) = .empty;
            for (footprint[ns..ne]) |fc| {
                const fsc: u8 = switch (fc) {
                    'A'...'Z' => fc + 32,
                    ' ', '.', '_' => '-',
                    else => fc,
                };
                fp_safe.append(allocator, fsc) catch continue;
            }
            if (fp_safe.items.len > 0) return fp_safe.items;
        }
    }
    return null;
}
