//! The combined-package upload handler: takes an uploaded KiCad symbol +
//! footprint pair and writes a single named `lib/` component, delegating the
//! extraction and name sanitization to `upload.zig`.

const std = @import("std");
const httpz = @import("httpz");
const infra_fs = @import("../infra/fs.zig");
const log = @import("../infra/log.zig");
const serve_root = @import("../serve.zig");
const Server = serve_root.Server;
const upload = @import("upload.zig");

// ── Constants ─────────────────────────────────────────────────────
const http_bad_request: u16 = 400;
const http_internal_error: u16 = 500;
const boundary_prefix = "boundary=";
const filename_prefix = "filename=\"";
const upload_log_template = "Upload: {s}\n";
const sexp_path_template = "{s}/{s}.sexp";

/// Error set for HTTP handlers in this module.
pub const HandlerError = std.mem.Allocator.Error || std.Io.Writer.Error ||
    std.fs.File.WriteError || std.fs.File.OpenError || std.fs.File.ReadError ||
    std.fs.Dir.MakeError || std.fs.Dir.StatFileError ||
    error{ FileTooBig, StreamTooLong, EndOfStream, InvalidEscapeSequence, ReadOnlyFileSystem, LinkQuotaExceeded };

/// POST /api/upload-package — accept a multipart upload of a KiCad symbol
/// + footprint (+ optional STEP) bundle, convert each piece, and persist
/// the resulting `lib/components`, `lib/pinouts`, `lib/footprints`, and
/// `lib/models` files in one transaction.
pub fn uploadPackageApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const body = req.body() orelse {
        res.status = http_bad_request;
        res.body = "No data";
        return;
    };

    // Parse multipart form data
    const content_type = req.header("content-type") orelse "";
    const boundary = blk: {
        if (std.mem.indexOf(u8, content_type, boundary_prefix)) |idx| {
            break :blk content_type[idx + boundary_prefix.len ..];
        }
        res.status = http_bad_request;
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
        res.status = http_internal_error;
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
            if (std.mem.indexOf(u8, headers, filename_prefix)) |fi| {
                const fn_start = fi + filename_prefix.len;
                if (std.mem.indexOfPos(u8, headers, fn_start, "\"")) |fn_end| {
                    sym_filename = headers[fn_start..fn_end];
                }
            }
        } else if (std.mem.indexOf(u8, headers_lower, "name=\"footprint\"")) |_| {
            fp_data = data;
            if (std.mem.indexOf(u8, headers, filename_prefix)) |fi| {
                const fn_start = fi + filename_prefix.len;
                if (std.mem.indexOfPos(u8, headers, fn_start, "\"")) |fn_end| {
                    fp_filename = headers[fn_start..fn_end];
                }
            }
        } else if (std.mem.indexOf(u8, headers_lower, "name=\"step\"")) |_| {
            step_data = data;
            if (std.mem.indexOf(u8, headers, filename_prefix)) |fi| {
                const fn_start = fi + filename_prefix.len;
                if (std.mem.indexOfPos(u8, headers, fn_start, "\"")) |fn_end| {
                    step_filename = headers[fn_start..fn_end];
                }
            }
        }

        pos = next_boundary;
    }

    if (sym_data == null or fp_data == null) {
        res.status = http_bad_request;
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
        res.status = http_internal_error;
        res.body = "Pinout generation failed — check symbol file format";
        return;
    };
    if (pinout.len == 0) {
        res.status = http_bad_request;
        res.body = "No pins found in symbol file";
        return;
    }

    // Generate footprint
    const footprint_conv = @import("../convert/footprint.zig");
    const footprint = footprint_conv.convertFootprint(ctx.allocator, fp_data.?) catch {
        res.status = http_internal_error;
        res.body = "Footprint conversion failed — check footprint file format";
        return;
    };

    // Write pinout to lib/pinouts/
    {
        const dir = std.fmt.allocPrint(ctx.allocator, "{s}/lib/pinouts", .{ctx.project_dir}) catch {
            res.status = http_internal_error;
            return;
        };
        defer ctx.allocator.free(dir);
        try infra_fs.cwd().makePath(dir);
        const path = std.fmt.allocPrint(ctx.allocator, sexp_path_template, .{ dir, safe_name }) catch {
            res.status = http_internal_error;
            return;
        };
        defer ctx.allocator.free(path);
        const f = infra_fs.cwd().createFile(path, .{}) catch {
            res.status = http_internal_error;
            res.body = "Cannot write pinout";
            return;
        };
        defer f.close();
        f.writeAll(pinout) catch {
            res.status = http_internal_error;
            return;
        };
    }

    // Write footprint to lib/footprints/
    const fp_name_final = upload.extractFootprintName(ctx.allocator, footprint) orelse safe_name;
    {
        const dir = std.fmt.allocPrint(ctx.allocator, "{s}/lib/footprints", .{ctx.project_dir}) catch {
            res.status = http_internal_error;
            return;
        };
        defer ctx.allocator.free(dir);
        try infra_fs.cwd().makePath(dir);
        const path = std.fmt.allocPrint(ctx.allocator, sexp_path_template, .{ dir, fp_name_final }) catch {
            res.status = http_internal_error;
            return;
        };
        defer ctx.allocator.free(path);
        const f = infra_fs.cwd().createFile(path, .{}) catch {
            res.status = http_internal_error;
            res.body = "Cannot write footprint";
            return;
        };
        defer f.close();
        f.writeAll(footprint) catch {
            res.status = http_internal_error;
            return;
        };
    }

    // Write component definition (overwrites any existing one — see contract)
    _ = upload.writeComponentFile(ctx.allocator, ctx.project_dir, safe_name, safe_name, fp_name_final, sym_data.?);

    // Save STEP model to lib/models/ if provided
    if (step_data) |sd| {
        const model_dir = std.fmt.allocPrint(ctx.allocator, "{s}/lib/models", .{ctx.project_dir}) catch "";
        if (model_dir.len > 0) {
            infra_fs.cwd().makePath(model_dir) catch |e| {
                log.warn("makePath {s} failed: {s}", .{ model_dir, @errorName(e) });
            };
            const model_path = std.fmt.allocPrint(ctx.allocator, "{s}/{s}.step", .{ model_dir, safe_name }) catch "";
            if (model_path.len > 0) {
                const mf = infra_fs.cwd().createFile(model_path, .{}) catch null;
                if (mf) |f| {
                    defer f.close();
                    f.writeAll(sd) catch |e| {
                        log.warn("write model {s} failed: {s}", .{ model_path, @errorName(e) });
                    };
                }
            }
        }
    }

    const msg = std.fmt.allocPrint(ctx.allocator, "Created lib/pinouts/{s}.sexp + lib/footprints/... (sources saved to lib/sources/)", .{safe_name}) catch {
        res.body = "OK";
        return;
    };
    std.debug.print(upload_log_template, .{msg});
    res.body = msg;
}
