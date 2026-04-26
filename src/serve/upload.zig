const std = @import("std");
const httpz = @import("httpz");
const infra_fs = @import("../infra/fs.zig");
const clock = @import("../infra/clock.zig");
const log = @import("../infra/log.zig");
const serve_root = @import("../serve.zig");
const Handler = serve_root.Handler;

/// POST /api/upload-zip — accept a KiCad library zip (must contain a
/// `.kicad_sym` plus a `.kicad_mod`, optionally a STEP), unpack via the
/// system `unzip`, convert each part, and write `lib/components`,
/// `lib/footprints`, `lib/pinouts`, and `lib/models` entries for it.
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
        const f = infra_fs.cwd().createFile(tmp_zip, .{}) catch {
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

    const tmp_dir = std.fmt.allocPrint(ctx.allocator, "/tmp/eda-extract-{d}", .{clock.milliTimestamp()}) catch {
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

    const sym_data = infra_fs.cwd().readFileAlloc(ctx.allocator, sym_path.?, 10 * 1024 * 1024) catch {
        res.status = 500;
        res.body = "Cannot read symbol from zip";
        return;
    };
    const fp_data = infra_fs.cwd().readFileAlloc(ctx.allocator, fp_path.?, 10 * 1024 * 1024) catch {
        res.status = 500;
        res.body = "Cannot read footprint from zip";
        return;
    };
    const step_data: ?[]const u8 = if (step_path) |sp|
        (infra_fs.cwd().readFileAlloc(ctx.allocator, sp, 50 * 1024 * 1024) catch null)
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
        try infra_fs.cwd().makePath(dir);
        const path = std.fmt.allocPrint(ctx.allocator, "{s}/{s}.sexp", .{ dir, safe_name }) catch {
            res.status = 500;
            return;
        };
        const f = infra_fs.cwd().createFile(path, .{}) catch {
            res.status = 500;
            return;
        };
        defer f.close();
        try f.writeAll(pinout);
    }

    // Write footprint
    const fp_name_final = extractFootprintName(ctx.allocator, footprint) orelse safe_name;
    {
        const dir = std.fmt.allocPrint(ctx.allocator, "{s}/lib/footprints", .{ctx.project_dir}) catch {
            res.status = 500;
            return;
        };
        try infra_fs.cwd().makePath(dir);
        const path = std.fmt.allocPrint(ctx.allocator, "{s}/{s}.sexp", .{ dir, fp_name_final }) catch {
            res.status = 500;
            return;
        };
        const f = infra_fs.cwd().createFile(path, .{}) catch {
            res.status = 500;
            return;
        };
        defer f.close();
        try f.writeAll(footprint);
    }

    // Write component definition (links pinout + footprint + MPN/manufacturer)
    writeComponentFile(ctx.allocator, ctx.project_dir, safe_name, safe_name, fp_name_final, sym_data);

    // Write STEP model
    if (step_data) |sd| {
        const dir = std.fmt.allocPrint(ctx.allocator, "{s}/lib/models", .{ctx.project_dir}) catch "";
        if (dir.len > 0) {
            try infra_fs.cwd().makePath(dir);
            const path = std.fmt.allocPrint(ctx.allocator, "{s}/{s}.step", .{ dir, safe_name }) catch "";
            if (path.len > 0) {
                const f = infra_fs.cwd().createFile(path, .{}) catch null;
                if (f) |file| {
                    defer file.close();
                    try file.writeAll(sd);
                }
            }
        }
    }

    // Clean up temp files
    infra_fs.cwd().deleteFile(tmp_zip) catch |e| switch (e) {
        error.FileNotFound => {},
        else => log.warn("deleting {s}: {s}", .{ tmp_zip, @errorName(e) }),
    };
    _ = std.process.Child.run(.{
        .allocator = ctx.allocator,
        .argv = &.{ "rm", "-rf", tmp_dir },
    }) catch |e| log.warn("cleanup {s}: {s}", .{ tmp_dir, @errorName(e) });

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
    infra_fs.cwd().makePath(dir_path) catch return;

    const out_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, filename }) catch return;
    defer allocator.free(out_path);

    const file = infra_fs.cwd().createFile(out_path, .{}) catch return;
    defer file.close();
    file.writeAll(body_data) catch return;
    std.debug.print("Saved source: lib/sources/{s}\n", .{filename});
}

// ── Shared helpers ────────────────────────────────────────────────────

/// Pull the first `(symbol "<name>" …)` identifier out of a KiCad
/// `.kicad_sym` payload to use as the package basename. Falls back to
/// `"package"` when the file shape is unexpected.
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

/// Lower-case `name` and replace spaces, dots, and underscores with `-`
/// so it's safe to use as a `lib/.../*.sexp` filename. Other characters
/// pass through unchanged.
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

/// Read the first `(footprint "<name>" …)` identifier out of a
/// `.kicad_mod` blob and return it sanitized for use as a library
/// filename. Returns null when no `(footprint …)` form is present.
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

/// Find a KiCad `(property "Key" "Value" ...)` inside `sym_data` and return
/// the value slice, or null if the property isn't present or is empty.
fn extractProperty(sym_data: []const u8, key: []const u8) ?[]const u8 {
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, sym_data, search, "(property \"")) |idx| {
        const ks = idx + 11;
        const ke = std.mem.indexOfPos(u8, sym_data, ks, "\"") orelse return null;
        if (std.mem.eql(u8, sym_data[ks..ke], key)) {
            const vs_start = std.mem.indexOfPos(u8, sym_data, ke + 1, "\"") orelse return null;
            const vs = vs_start + 1;
            const ve = std.mem.indexOfPos(u8, sym_data, vs, "\"") orelse return null;
            if (ve == vs) return null; // empty value
            return sym_data[vs..ve];
        }
        search = ke + 1;
    }
    return null;
}

/// Write a `(component ...)` definition to lib/components/<safe_name>.sexp.
/// Extracts description / manufacturer / MPN from the KiCad symbol properties
/// when present. `pinout_name` and `footprint_name` are bare atoms referenced
/// from the component; they must already have been written.
pub fn writeComponentFile(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    safe_name: []const u8,
    pinout_name: []const u8,
    footprint_name: []const u8,
    sym_data: []const u8,
) void {
    const dir = std.fmt.allocPrint(allocator, "{s}/lib/components", .{project_dir}) catch return;
    defer allocator.free(dir);
    infra_fs.cwd().makePath(dir) catch return;

    const path = std.fmt.allocPrint(allocator, "{s}/{s}.sexp", .{ dir, safe_name }) catch return;
    defer allocator.free(path);

    // Skip if a hand-authored component already exists.
    if (infra_fs.cwd().access(path, .{})) |_| {
        std.debug.print("Component exists, skipping: lib/components/{s}.sexp\n", .{safe_name});
        return;
    } else |_| {}

    const description = extractProperty(sym_data, "ki_description") orelse
        extractProperty(sym_data, "Description") orelse
        extractProperty(sym_data, "Value") orelse
        safe_name;
    const manufacturer = extractProperty(sym_data, "Manufacturer_Name");
    const mpn = extractProperty(sym_data, "Manufacturer_Part_Number");

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(allocator);
    w.print("(component \"{s}\"\n", .{safe_name}) catch return;
    w.print("  (description \"{s}\")\n", .{description}) catch return;
    // Names are always quoted: purely-numeric names (e.g. "2049280301") would
    // otherwise tokenize as an int and fail field resolution.
    w.print("  (pinout \"{s}\")\n", .{pinout_name}) catch return;
    w.print("  (footprint \"{s}\")", .{footprint_name}) catch return;
    if (manufacturer) |m| w.print("\n  (manufacturer \"{s}\")", .{m}) catch return;
    if (mpn) |m| w.print("\n  (mpn \"{s}\")", .{m}) catch return;
    w.writeAll(")\n") catch return;

    const f = infra_fs.cwd().createFile(path, .{}) catch return;
    defer f.close();
    f.writeAll(buf.items) catch return;
    std.debug.print("Wrote component: lib/components/{s}.sexp\n", .{safe_name});
}
