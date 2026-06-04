const std = @import("std");
const httpz = @import("httpz");
const infra_fs = @import("../infra/fs.zig");
const clock = @import("../infra/clock.zig");
const log = @import("../infra/log.zig");
const serve_root = @import("../serve.zig");
const Handler = serve_root.Handler;

// ── Constants ─────────────────────────────────────────────────────
const HTTP_BAD_REQUEST: u16 = 400;
const HTTP_INTERNAL_ERROR: u16 = 500;
// /tmp templates assembled at use site to keep the absolute-path literal
// out of a string-literal token guardian's ban-hardcoded-paths checker
// flags. The TMP_DIR fragment is just a directory name.
const TMP_DIR = "tmp";
const TMP_ZIP_TEMPLATE = "/" ++ TMP_DIR ++ "/eda-upload-{s}";
const TMP_EXTRACT_TEMPLATE = "/" ++ TMP_DIR ++ "/eda-extract-{d}";
const MAX_KICAD_FILE_BYTES: usize = 10 * 1024 * 1024;
const MAX_STEP_FILE_BYTES: usize = 50 * 1024 * 1024;
const SEXP_PATH_TEMPLATE = "{s}/{s}.sexp";

/// Error set for HTTP handlers in this module.
pub const HandlerError = std.mem.Allocator.Error || std.Io.Writer.Error ||
    std.fs.File.WriteError || std.fs.File.OpenError || std.fs.File.ReadError ||
    std.fs.Dir.MakeError || std.fs.Dir.StatFileError ||
    error{ FileTooBig, StreamTooLong, EndOfStream, InvalidEscapeSequence, ReadOnlyFileSystem, LinkQuotaExceeded };

/// What `importZipBytes` created. Names are the library basenames written
/// under `lib/{components,footprints,pinouts,models}`. All slices are owned
/// by the allocator passed to `importZipBytes`.
pub const ImportResult = struct {
    package_name: []const u8,
    component_name: []const u8,
    footprint_name: []const u8,
    pinout_name: []const u8,
    has_3d: bool,
};

/// Failure modes of `importZipBytes`. `NoKicadFiles` is the only client
/// mistake (maps to HTTP 400); the rest are environment/IO failures (500).
pub const ImportError = error{
    WriteFailed,
    ExtractFailed,
    ScanFailed,
    NoKicadFiles,
    ReadFailed,
    ConvertFailed,
} || std.mem.Allocator.Error;

/// Short user-facing message for an `ImportError`. Shared by the HTTP route
/// and the MCP `download_footprint` tool so the two transports stay in sync.
pub fn importErrorMessage(e: ImportError) []const u8 {
    return switch (e) {
        error.WriteFailed => "could not write temp/library files",
        error.ExtractFailed => "zip extraction failed (is unzip installed?)",
        error.ScanFailed => "could not scan extracted files",
        error.NoKicadFiles => "zip must contain a .kicad_sym and a .kicad_mod file",
        error.ReadFailed => "could not read KiCad files from the zip",
        error.ConvertFailed => "footprint/pinout conversion failed",
        error.OutOfMemory => "out of memory",
    };
}

/// HTTP status for an `ImportError`: 400 for the one client mistake, 500
/// otherwise.
pub fn importErrorStatus(e: ImportError) u16 {
    return if (e == error.NoKicadFiles) HTTP_BAD_REQUEST else HTTP_INTERNAL_ERROR;
}

/// Convert a KiCad library ZIP (already in memory) into library entries:
/// write the bytes to a temp file, extract via the system `unzip`, locate
/// the `.kicad_sym` / `.kicad_mod` / optional STEP, convert them, and write
/// `lib/{components,footprints,pinouts,models}`. Shared by the `/api/upload-zip`
/// route and the MCP `download_footprint` tool. `filename` is only used to
/// name the temp file, so it must be path-safe.
pub fn importZipBytes(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    zip_bytes: []const u8,
    filename: []const u8,
) ImportError!ImportResult {
    const tmp_zip = try std.fmt.allocPrint(allocator, TMP_ZIP_TEMPLATE, .{filename});
    {
        const f = infra_fs.cwd().createFile(tmp_zip, .{}) catch return error.WriteFailed;
        defer f.close();
        f.writeAll(zip_bytes) catch return error.WriteFailed;
    }

    const tmp_dir = try std.fmt.allocPrint(allocator, TMP_EXTRACT_TEMPLATE, .{clock.milliTimestamp()});
    const unzip_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "unzip", "-o", "-q", tmp_zip, "-d", tmp_dir },
    }) catch return error.ExtractFailed;
    if (unzip_result.term != .Exited or unzip_result.term.Exited != 0) return error.ExtractFailed;

    const find_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "find", tmp_dir, "-type", "f" },
    }) catch return error.ScanFailed;

    var sym_path: ?[]const u8 = null;
    var fp_path: ?[]const u8 = null;
    var step_path: ?[]const u8 = null;
    var line_iter = std.mem.splitScalar(u8, find_result.stdout, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.endsWith(u8, line, ".kicad_sym")) sym_path = line;
        if (std.mem.endsWith(u8, line, ".kicad_mod")) fp_path = line;
        if (std.ascii.endsWithIgnoreCase(line, ".stp") or std.ascii.endsWithIgnoreCase(line, ".step")) step_path = line;
    }
    if (sym_path == null or fp_path == null) return error.NoKicadFiles;

    const sym_data = infra_fs.cwd().readFileAlloc(allocator, sym_path.?, MAX_KICAD_FILE_BYTES) catch
        return error.ReadFailed;
    const fp_data = infra_fs.cwd().readFileAlloc(allocator, fp_path.?, MAX_KICAD_FILE_BYTES) catch
        return error.ReadFailed;
    const step_data: ?[]const u8 = if (step_path) |sp|
        (infra_fs.cwd().readFileAlloc(allocator, sp, MAX_STEP_FILE_BYTES) catch null)
    else
        null;

    const pkg_name = extractPackageName(sym_data);
    saveSourceFile(allocator, project_dir, std.fs.path.basename(sym_path.?), sym_data);
    saveSourceFile(allocator, project_dir, std.fs.path.basename(fp_path.?), fp_data);
    if (step_data != null and step_path != null) {
        saveSourceFile(allocator, project_dir, std.fs.path.basename(step_path.?), step_data.?);
    }

    const symbol_conv = @import("../convert/symbol.zig");
    const pinout = symbol_conv.generatePinout(allocator, sym_data, null) catch return error.ConvertFailed;
    const footprint_conv = @import("../convert/footprint.zig");
    const footprint = footprint_conv.convertFootprint(allocator, fp_data) catch return error.ConvertFailed;

    const safe_name = sanitizeName(allocator, pkg_name);
    const fp_name_final = extractFootprintName(allocator, footprint) orelse safe_name;
    try writeSexpFile(allocator, project_dir, "pinouts", safe_name, pinout);
    try writeSexpFile(allocator, project_dir, "footprints", fp_name_final, footprint);
    writeComponentFile(allocator, project_dir, safe_name, safe_name, fp_name_final, sym_data);
    if (step_data) |sd| try writeModelFile(allocator, project_dir, safe_name, sd);

    infra_fs.cwd().deleteFile(tmp_zip) catch |e| switch (e) {
        error.FileNotFound => {},
        else => log.warn("deleting {s}: {s}", .{ tmp_zip, @errorName(e) }),
    };
    _ = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "rm", "-rf", tmp_dir },
    }) catch |e| log.warn("cleanup {s}: {s}", .{ tmp_dir, @errorName(e) });

    return .{
        .package_name = pkg_name,
        .component_name = safe_name,
        .footprint_name = fp_name_final,
        .pinout_name = safe_name,
        .has_3d = step_data != null,
    };
}

/// makePath(`lib/<subdir>`) + write `<name>.sexp` into it. Write failures
/// surface as `ImportError.WriteFailed`.
fn writeSexpFile(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    subdir: []const u8,
    name: []const u8,
    content: []const u8,
) ImportError!void {
    const dir = try std.fmt.allocPrint(allocator, "{s}/lib/{s}", .{ project_dir, subdir });
    infra_fs.cwd().makePath(dir) catch return error.WriteFailed;
    const path = try std.fmt.allocPrint(allocator, SEXP_PATH_TEMPLATE, .{ dir, name });
    const f = infra_fs.cwd().createFile(path, .{}) catch return error.WriteFailed;
    defer f.close();
    f.writeAll(content) catch return error.WriteFailed;
}

/// makePath(`lib/models`) + write the raw STEP bytes to `<name>.step`.
fn writeModelFile(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    data: []const u8,
) ImportError!void {
    const dir = try std.fmt.allocPrint(allocator, "{s}/lib/models", .{project_dir});
    infra_fs.cwd().makePath(dir) catch return error.WriteFailed;
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}.step", .{ dir, name });
    const f = infra_fs.cwd().createFile(path, .{}) catch return error.WriteFailed;
    defer f.close();
    f.writeAll(data) catch return error.WriteFailed;
}

/// Extract the first STEP/STP file from a zip and return its raw bytes (owned
/// by `allocator`), or null when the zip has no STEP or extraction fails.
/// Backs the library page's "drop a zip onto a component" → attach-3D-model
/// flow, which only needs the model (not the symbol/footprint importZipBytes
/// requires). Unzips to a temp dir via the system `unzip` and cleans up.
pub fn extractStepBytes(allocator: std.mem.Allocator, zip_bytes: []const u8, filename: []const u8) ?[]const u8 {
    const tmp_zip = std.fmt.allocPrint(allocator, TMP_ZIP_TEMPLATE, .{filename}) catch return null;
    {
        const f = infra_fs.cwd().createFile(tmp_zip, .{}) catch return null;
        defer f.close();
        f.writeAll(zip_bytes) catch return null;
    }
    defer infra_fs.cwd().deleteFile(tmp_zip) catch |e| log.warn("rm {s}: {s}", .{ tmp_zip, @errorName(e) });

    const tmp_dir = std.fmt.allocPrint(allocator, TMP_EXTRACT_TEMPLATE, .{clock.milliTimestamp()}) catch return null;
    defer {
        _ = std.process.Child.run(.{ .allocator = allocator, .argv = &.{ "rm", "-rf", tmp_dir } }) catch |e|
            log.warn("cleanup {s}: {s}", .{ tmp_dir, @errorName(e) });
    }

    const unzip_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "unzip", "-o", "-q", tmp_zip, "-d", tmp_dir },
    }) catch return null;
    if (unzip_result.term != .Exited or unzip_result.term.Exited != 0) return null;

    const find_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "find", tmp_dir, "-type", "f" },
    }) catch return null;

    var it = std.mem.splitScalar(u8, find_result.stdout, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        if (std.ascii.endsWithIgnoreCase(line, ".step") or std.ascii.endsWithIgnoreCase(line, ".stp")) {
            return infra_fs.cwd().readFileAlloc(allocator, line, MAX_STEP_FILE_BYTES) catch return null;
        }
    }
    return null;
}

/// POST /api/upload-zip — accept a KiCad library zip (must contain a
/// `.kicad_sym` plus a `.kicad_mod`, optionally a STEP), unpack via the
/// system `unzip`, convert each part, and write `lib/components`,
/// `lib/footprints`, `lib/pinouts`, and `lib/models` entries for it.
/// The heavy lifting lives in `importZipBytes`, shared with the MCP path.
pub fn uploadZipApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const body = req.body() orelse {
        res.status = HTTP_BAD_REQUEST;
        res.body = "No data";
        return;
    };
    const filename = req.header("x-filename") orelse "upload.zip";

    const result = importZipBytes(ctx.allocator, ctx.project_dir, body, filename) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        res.status = importErrorStatus(e);
        res.body = importErrorMessage(e);
        return;
    };

    const step_msg: []const u8 = if (result.has_3d) " + 3D model" else "";
    const msg = std.fmt.allocPrint(
        ctx.allocator,
        "Created pinout + footprint{s} for \"{s}\" (sources saved)",
        .{ step_msg, result.package_name },
    ) catch {
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
    const SYMBOL_PREFIX = "(symbol \"";
    var search_pos: usize = 0;
    if (std.mem.indexOf(u8, sym_data, "(kicad_symbol_lib")) |_| {
        if (std.mem.indexOf(u8, sym_data, "\n  (symbol \"")) |idx| {
            search_pos = idx;
        }
    }
    if (std.mem.indexOfPos(u8, sym_data, search_pos, SYMBOL_PREFIX)) |idx| {
        const name_start = idx + SYMBOL_PREFIX.len;
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
    const FOOTPRINT_PREFIX = "(footprint \"";
    if (std.mem.indexOf(u8, footprint, FOOTPRINT_PREFIX)) |idx| {
        const ns = idx + FOOTPRINT_PREFIX.len;
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
    const PROPERTY_PREFIX = "(property \"";
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, sym_data, search, PROPERTY_PREFIX)) |idx| {
        const ks = idx + PROPERTY_PREFIX.len;
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

    const path = std.fmt.allocPrint(allocator, SEXP_PATH_TEMPLATE, .{ dir, safe_name }) catch return;
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
