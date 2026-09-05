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
const upload_log_template = "Upload: {s}";
const sexp_path_template = "{s}/{s}.sexp";

/// Error set for HTTP handlers in this module.
pub const HandlerError = std.mem.Allocator.Error || std.Io.Writer.Error ||
    infra_fs.File.WriteError || infra_fs.File.OpenError || infra_fs.File.ReadError ||
    infra_fs.Dir.MakeError || infra_fs.Dir.StatFileError ||
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

    // Write component definition (overwrites any existing one — see contract).
    // The result is NOT discardable: `.write_failed` is the one failure that
    // loses the artifact this whole upload exists to produce, so it answers
    // like every other write failure above rather than reporting success.
    switch (upload.writeComponentFile(ctx.allocator, ctx.project_dir, safe_name, safe_name, fp_name_final, sym_data.?)) {
        .created, .replaced => {},
        .write_failed => {
            res.status = http_internal_error;
            res.body = "Cannot write component";
            return;
        },
    }

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
    log.progress(upload_log_template, .{msg});
    res.body = msg;
}

// ── Tests ─────────────────────────────────────────────────────────

const test_symbol =
    \\(kicad_symbol_lib (version 20211014) (generator test)
    \\  (symbol "PART-1"
    \\    (property "Reference" "U")
    \\    (property "Manufacturer_Part_Number" "PART-1")
    \\    (pin passive line (at 0 0 0) (length 1.27)
    \\      (name "PORT_1") (number "1"))
    \\  )
    \\)
;

// No `(layer …)` / `(layers …)` forms: the converter reads the name, the
// description and the pad geometry, and every KiCad layer spelling is owned by
// `board_layers` rather than restated in a fixture.
const test_footprint =
    \\(module "PART1"
    \\  (descr "test footprint")
    \\  (pad 1 smd rect (at 0 0) (size 1 1))
    \\)
;

const test_boundary = "netlispPackageBoundary";

/// The multipart body the upload form posts: one `symbol` part and one
/// `footprint` part, fenced by `test_boundary`.
fn packageForm(allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "--{s}\r\nContent-Disposition: form-data; name=\"symbol\"; filename=\"part.kicad_sym\"\r\n\r\n{s}\r\n" ++
            "--{s}\r\nContent-Disposition: form-data; name=\"footprint\"; filename=\"part.kicad_mod\"\r\n\r\n{s}\r\n" ++
            "--{s}--\r\n",
        .{ test_boundary, test_symbol, test_boundary, test_footprint, test_boundary },
    );
}

/// POST the fixture package into `project_dir` through the real route and
/// return the status the handler answered with.
fn postPackage(allocator: std.mem.Allocator, project_dir: []const u8) !u16 {
    var state = serve_root.ServerState{};
    var srv = Server{
        .allocator = allocator,
        .project_dir = project_dir,
        .auth_dir = project_dir,
        .state = &state,
    };
    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.header("content-type", "multipart/form-data; boundary=" ++ test_boundary);
    ht.body(try packageForm(allocator));
    try uploadPackageApi(&srv, ht.req, ht.res);
    return ht.res.status;
}

// spec: Web Server - A package upload whose component definition cannot be written answers a 500 instead of reporting the upload succeeded
test "a package upload that cannot write its component reports the failure" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Control: a writable project takes the same upload and mints the component.
    {
        var writable = std.testing.tmpDir(.{});
        defer writable.cleanup();
        const project_dir = try writable.dir.realPathFileAlloc(std.testing.io, ".", arena);
        try std.testing.expectEqual(@as(u16, 200), try postPackage(arena, project_dir));
        try writable.dir.access(std.testing.io, "lib/components/part-1.sexp", .{});
    }

    // Now the same upload into a project where `lib/components` is occupied by
    // a FILE, so `writeComponentFile` cannot create the directory and returns
    // `.write_failed`. Discarding that result answered 200 with a "Created …"
    // body while the component definition the upload exists to produce was
    // never written — the one failure in this handler that reported success.
    var blocked = std.testing.tmpDir(.{});
    defer blocked.cleanup();
    const project_dir = try blocked.dir.realPathFileAlloc(std.testing.io, ".", arena);
    const lib_dir = try std.fmt.allocPrint(arena, "{s}/lib", .{project_dir});
    try infra_fs.cwd().makePath(lib_dir);
    const occupied_path = try std.fmt.allocPrint(arena, "{s}/components", .{lib_dir});
    var occupied = try infra_fs.cwd().createFile(occupied_path, .{});
    occupied.close();

    try std.testing.expectEqual(@as(u16, 500), try postPackage(arena, project_dir));
    // The pinout still landed, so the run really did reach the component write.
    try blocked.dir.access(std.testing.io, "lib/pinouts/part-1.sexp", .{});
}
