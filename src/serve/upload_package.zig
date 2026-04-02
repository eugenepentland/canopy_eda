const std = @import("std");
const httpz = @import("httpz");
const serve_root = @import("../serve.zig");
const Handler = serve_root.Handler;
const upload = @import("upload.zig");

pub fn uploadPackageApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const body = req.body() orelse {
        res.status = 400;
        res.body = "No data";
        return;
    };

    // Parse multipart form data
    const content_type = req.header("content-type") orelse "";
    const boundary = blk: {
        if (std.mem.indexOf(u8, content_type, "boundary=")) |idx| {
            break :blk content_type[idx + 9 ..];
        }
        res.status = 400;
        res.body = "Missing multipart boundary";
        return;
    };

    var sym_data: ?[]const u8 = null;
    var sym_filename: []const u8 = "unknown.kicad_sym";
    var fp_data: ?[]const u8 = null;
    var fp_filename: []const u8 = "unknown.kicad_mod";
    var step_data: ?[]const u8 = null;
    var step_filename: []const u8 = "unknown.step";

    const delim = std.fmt.allocPrint(ctx.allocator, "--{s}", .{boundary}) catch {
        res.status = 500;
        return;
    };

    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, body, pos, delim)) |start| {
        const part_start = start + delim.len;
        if (part_start >= body.len) break;
        var hdr_start = part_start;
        if (hdr_start < body.len and body[hdr_start] == '\r') hdr_start += 1;
        if (hdr_start < body.len and body[hdr_start] == '\n') hdr_start += 1;

        const hdr_end = std.mem.indexOf(u8, body[hdr_start..], "\r\n\r\n") orelse break;
        const headers = body[hdr_start .. hdr_start + hdr_end];
        const data_start = hdr_start + hdr_end + 4;

        const next_boundary = std.mem.indexOfPos(u8, body, data_start, delim) orelse body.len;
        var data_end = next_boundary;
        if (data_end >= 2 and body[data_end - 1] == '\n' and body[data_end - 2] == '\r') data_end -= 2;
        const data = body[data_start..data_end];

        const headers_lower = std.ascii.allocLowerString(ctx.allocator, headers) catch continue;
        if (std.mem.indexOf(u8, headers_lower, "name=\"symbol\"")) |_| {
            sym_data = data;
            if (std.mem.indexOf(u8, headers, "filename=\"")) |fi| {
                const fn_start = fi + 10;
                if (std.mem.indexOfPos(u8, headers, fn_start, "\"")) |fn_end| {
                    sym_filename = headers[fn_start..fn_end];
                }
            }
        } else if (std.mem.indexOf(u8, headers_lower, "name=\"footprint\"")) |_| {
            fp_data = data;
            if (std.mem.indexOf(u8, headers, "filename=\"")) |fi| {
                const fn_start = fi + 10;
                if (std.mem.indexOfPos(u8, headers, fn_start, "\"")) |fn_end| {
                    fp_filename = headers[fn_start..fn_end];
                }
            }
        } else if (std.mem.indexOf(u8, headers_lower, "name=\"step\"")) |_| {
            step_data = data;
            if (std.mem.indexOf(u8, headers, "filename=\"")) |fi| {
                const fn_start = fi + 10;
                if (std.mem.indexOfPos(u8, headers, fn_start, "\"")) |fn_end| {
                    step_filename = headers[fn_start..fn_end];
                }
            }
        }

        pos = next_boundary;
    }

    if (sym_data == null or fp_data == null) {
        res.status = 400;
        res.body = "Both symbol and footprint files are required";
        return;
    }

    const pkg_name = upload.extractPackageName(sym_data.?);

    // Save raw source files
    upload.saveSourceFile(ctx.allocator, ctx.project_dir, sym_filename, sym_data.?);
    upload.saveSourceFile(ctx.allocator, ctx.project_dir, fp_filename, fp_data.?);
    if (step_data) |sd| {
        upload.saveSourceFile(ctx.allocator, ctx.project_dir, step_filename, sd);
    }

    const safe_name = upload.sanitizeName(ctx.allocator, pkg_name);

    // Generate pinout from symbol
    const symbol_conv = @import("../convert/symbol.zig");
    const pinout = symbol_conv.generatePinout(ctx.allocator, sym_data.?, null) catch {
        res.status = 500;
        res.body = "Pinout generation failed — check symbol file format";
        return;
    };
    if (pinout.len == 0) {
        res.status = 400;
        res.body = "No pins found in symbol file";
        return;
    }

    // Generate footprint
    const footprint_conv = @import("../convert/footprint.zig");
    const footprint = footprint_conv.convertFootprint(ctx.allocator, fp_data.?) catch {
        res.status = 500;
        res.body = "Footprint conversion failed — check footprint file format";
        return;
    };

    // Write pinout to lib/pinouts/
    {
        const dir = std.fmt.allocPrint(ctx.allocator, "{s}/lib/pinouts", .{ctx.project_dir}) catch {
            res.status = 500;
            return;
        };
        defer ctx.allocator.free(dir);
        std.fs.cwd().makePath(dir) catch {};
        const path = std.fmt.allocPrint(ctx.allocator, "{s}/{s}.sexp", .{ dir, safe_name }) catch {
            res.status = 500;
            return;
        };
        defer ctx.allocator.free(path);
        const f = std.fs.cwd().createFile(path, .{}) catch {
            res.status = 500;
            res.body = "Cannot write pinout";
            return;
        };
        defer f.close();
        f.writeAll(pinout) catch {
            res.status = 500;
            return;
        };
    }

    // Write footprint to lib/footprints/
    {
        const fp_name = upload.extractFootprintName(ctx.allocator, footprint) orelse safe_name;
        const dir = std.fmt.allocPrint(ctx.allocator, "{s}/lib/footprints", .{ctx.project_dir}) catch {
            res.status = 500;
            return;
        };
        defer ctx.allocator.free(dir);
        std.fs.cwd().makePath(dir) catch {};
        const path = std.fmt.allocPrint(ctx.allocator, "{s}/{s}.sexp", .{ dir, fp_name }) catch {
            res.status = 500;
            return;
        };
        defer ctx.allocator.free(path);
        const f = std.fs.cwd().createFile(path, .{}) catch {
            res.status = 500;
            res.body = "Cannot write footprint";
            return;
        };
        defer f.close();
        f.writeAll(footprint) catch {
            res.status = 500;
            return;
        };
    }

    // Save STEP model to lib/models/ if provided
    if (step_data) |sd| {
        const model_dir = std.fmt.allocPrint(ctx.allocator, "{s}/lib/models", .{ctx.project_dir}) catch "";
        if (model_dir.len > 0) {
            std.fs.cwd().makePath(model_dir) catch {};
            const model_path = std.fmt.allocPrint(ctx.allocator, "{s}/{s}.step", .{ model_dir, safe_name }) catch "";
            if (model_path.len > 0) {
                const mf = std.fs.cwd().createFile(model_path, .{}) catch null;
                if (mf) |f| {
                    defer f.close();
                    f.writeAll(sd) catch {};
                }
            }
        }
    }

    const msg = std.fmt.allocPrint(ctx.allocator, "Created lib/pinouts/{s}.sexp + lib/footprints/... (sources saved to lib/sources/)", .{safe_name}) catch {
        res.body = "OK";
        return;
    };
    std.debug.print("Upload: {s}\n", .{msg});
    res.body = msg;
}

// Legacy upload endpoints (kept for backwards compatibility)
pub fn uploadSymbolApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const body = req.body() orelse {
        res.status = 400;
        res.body = "No file data";
        return;
    };

    const filename = req.header("x-filename") orelse "unknown.kicad_sym";

    upload.saveSourceFile(ctx.allocator, ctx.project_dir, filename, body);

    const symbol_conv = @import("../convert/symbol.zig");
    const converted = symbol_conv.convertSymbol(ctx.allocator, body, null) catch {
        res.status = 500;
        res.body = "Conversion failed — check file format";
        return;
    };

    if (converted.len == 0) {
        res.status = 400;
        res.body = "No symbols found in file";
        return;
    }

    const basename = blk: {
        var name = filename;
        if (std.mem.lastIndexOfScalar(u8, name, '/')) |i| name = name[i + 1 ..];
        if (std.mem.lastIndexOfScalar(u8, name, '\\')) |i| name = name[i + 1 ..];
        if (std.mem.endsWith(u8, name, ".kicad_sym")) name = name[0 .. name.len - 10];
        break :blk name;
    };

    const safe_name = upload.sanitizeName(ctx.allocator, basename);

    const dir_path = std.fmt.allocPrint(ctx.allocator, "{s}/lib/pinouts", .{ctx.project_dir}) catch {
        res.status = 500;
        return;
    };
    defer ctx.allocator.free(dir_path);
    std.fs.cwd().makePath(dir_path) catch {};

    const out_path = std.fmt.allocPrint(ctx.allocator, "{s}/{s}.sexp", .{ dir_path, safe_name }) catch {
        res.status = 500;
        return;
    };
    defer ctx.allocator.free(out_path);

    const file = std.fs.cwd().createFile(out_path, .{}) catch {
        res.status = 500;
        res.body = "Cannot write file";
        return;
    };
    defer file.close();
    file.writeAll(converted) catch {
        res.status = 500;
        return;
    };

    const msg = std.fmt.allocPrint(ctx.allocator, "Converted {s} -> lib/pinouts/{s}.sexp", .{ filename, safe_name }) catch {
        res.body = "OK";
        return;
    };
    std.debug.print("Upload: {s}\n", .{msg});
    res.body = msg;
}

pub fn uploadFootprintApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const body = req.body() orelse {
        res.status = 400;
        res.body = "No file data";
        return;
    };

    const filename = req.header("x-filename") orelse "unknown.kicad_mod";

    upload.saveSourceFile(ctx.allocator, ctx.project_dir, filename, body);

    const footprint_conv = @import("../convert/footprint.zig");
    const converted = footprint_conv.convertFootprint(ctx.allocator, body) catch {
        res.status = 500;
        res.body = "Conversion failed — check file format";
        return;
    };

    const basename = blk: {
        var name = filename;
        if (std.mem.lastIndexOfScalar(u8, name, '/')) |i| name = name[i + 1 ..];
        if (std.mem.lastIndexOfScalar(u8, name, '\\')) |i| name = name[i + 1 ..];
        if (std.mem.endsWith(u8, name, ".kicad_mod")) name = name[0 .. name.len - 10];
        break :blk name;
    };

    const safe_name = upload.sanitizeName(ctx.allocator, basename);

    const dir_path = std.fmt.allocPrint(ctx.allocator, "{s}/lib/footprints", .{ctx.project_dir}) catch {
        res.status = 500;
        return;
    };
    defer ctx.allocator.free(dir_path);
    std.fs.cwd().makePath(dir_path) catch {};

    const out_path = std.fmt.allocPrint(ctx.allocator, "{s}/{s}.sexp", .{ dir_path, safe_name }) catch {
        res.status = 500;
        return;
    };
    defer ctx.allocator.free(out_path);

    const file = std.fs.cwd().createFile(out_path, .{}) catch {
        res.status = 500;
        res.body = "Cannot write file";
        return;
    };
    defer file.close();
    file.writeAll(converted) catch {
        res.status = 500;
        return;
    };

    const msg = std.fmt.allocPrint(ctx.allocator, "Converted {s} -> lib/footprints/{s}.sexp", .{ filename, safe_name }) catch {
        res.body = "OK";
        return;
    };
    std.debug.print("Upload: {s}\n", .{msg});
    res.body = msg;
}
