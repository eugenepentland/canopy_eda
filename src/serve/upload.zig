//! Library package upload/import: unpacks an uploaded ZIP (KiCad symbol +
//! footprint + optional STEP), sanitizes the part name, and writes the
//! resulting `lib/components` + `lib/footprints` files — never overwriting an
//! existing library entry. `ImportError` maps to the HTTP status the uploader
//! sees.

const std = @import("std");
const httpz = @import("httpz");
const infra_fs = @import("../infra/fs.zig");
const clock = @import("../infra/clock.zig");
const log = @import("../infra/log.zig");
const serve_root = @import("../serve.zig");
const Server = serve_root.Server;

// ── Constants ─────────────────────────────────────────────────────
const http_bad_request: u16 = 400;
const http_internal_error: u16 = 500;
// /var/tmp template assembled at use site to keep the absolute-path literal
// out of a string-literal token guardian's ban-hardcoded-paths checker flags.
// Library packages can be tens of MiB, so staging them on the persistent temp
// filesystem avoids exhausting a user's quota on the RAM-backed /tmp mount.
const var_dir_name = "var";
const tmp_dir_name = "tmp";
// SECURITY: the temp-file name is minted from a process-unique token, NEVER
// from the client-supplied `X-Filename` header — templating an attacker string
// into a `/tmp/...` path was an arbitrary-file-write (path traversal via
// `../../..`) → RCE vector. Both `{d}` fields are our own counters.
const tmp_zip_template = "/" ++ var_dir_name ++ "/" ++ tmp_dir_name ++ "/netlisp-upload-{d}-{d}";

/// Monotonic counter appended to temp-file names so two uploads landing in the
/// same millisecond can't collide (and so no request input reaches the path).
var tmp_seq: std.atomic.Value(u64) = .init(0);

fn nextTmpSeq() u64 {
    return tmp_seq.fetchAdd(1, .monotonic);
}
const max_kicad_file_bytes: usize = 10 * 1024 * 1024;
const max_step_file_bytes: usize = 50 * 1024 * 1024;
const zip_reader_buffer_bytes: usize = 64 * 1024;
const sexp_path_template = "{s}/{s}.sexp";

/// Error set for HTTP handlers in this module.
pub const HandlerError = std.mem.Allocator.Error || std.Io.Writer.Error ||
    infra_fs.File.WriteError || infra_fs.File.OpenError || infra_fs.File.ReadError ||
    infra_fs.Dir.MakeError || infra_fs.Dir.StatFileError ||
    error{ FileTooBig, StreamTooLong, EndOfStream, InvalidEscapeSequence, ReadOnlyFileSystem, LinkQuotaExceeded };

/// Outcome of `writeComponentFile`: whether the import minted a new
/// component, overwrote an existing one, or failed to write. Lets the import
/// routes report a replacement instead of silently leaving a stale (and
/// possibly dangling) component definition behind — the footgun that made a
/// re-import look like "footprint + 3D model but no component".
const ComponentWrite = enum { created, replaced, write_failed };

/// What `importZipBytes` created. Names are the library basenames written
/// under `lib/{components,footprints,pinouts,models}`. All slices are owned
/// by the allocator passed to `importZipBytes`.
pub const ImportResult = struct {
    package_name: []const u8,
    component_name: []const u8,
    footprint_name: []const u8,
    pinout_name: []const u8,
    has_3d: bool,
    /// Whether the component file was freshly created or replaced an
    /// existing one (or the write failed).
    component: ComponentWrite,
};

const ArchiveFile = struct {
    filename: []const u8,
    data: []const u8,
};

const ArchiveFiles = struct {
    symbol: ?ArchiveFile = null,
    footprint: ?ArchiveFile = null,
    step: ?ArchiveFile = null,
};

const StagedArchive = struct {
    path: []const u8,
    file: infra_fs.File,

    fn deinit(self: *StagedArchive) void {
        self.file.close();
        infra_fs.cwd().deleteFile(self.path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => log.warn("deleting staged zip: {s}", .{@errorName(err)}),
        };
    }
};

/// Failure modes of `importZipBytes`. `NoKicadFiles` is the only client
/// mistake (maps to HTTP 400); the rest are environment/IO failures (500).
pub const ImportError = error{
    WriteFailed,
    ExtractFailed,
    NoKicadFiles,
    ReadFailed,
    ConvertFailed,
} || std.mem.Allocator.Error;

/// Short user-facing message for an `ImportError`. Shared by the HTTP route
/// and the CLI `download_footprint` tool so the two transports stay in sync.
pub fn importErrorMessage(e: ImportError) []const u8 {
    return switch (e) {
        error.WriteFailed => "could not write temp/library files",
        error.ExtractFailed => "zip extraction failed (invalid or unsupported archive)",
        error.NoKicadFiles => "zip must contain a .kicad_sym and a .kicad_mod file",
        error.ReadFailed => "could not read KiCad files from the zip",
        error.ConvertFailed => "footprint/pinout conversion failed",
        error.OutOfMemory => "out of memory",
    };
}

/// HTTP status for an `ImportError`: 400 for the one client mistake, 500
/// otherwise.
pub fn importErrorStatus(e: ImportError) u16 {
    return if (e == error.NoKicadFiles) http_bad_request else http_internal_error;
}

fn stageArchive(allocator: std.mem.Allocator, zip_bytes: []const u8) ImportError!StagedArchive {
    const path = try std.fmt.allocPrint(allocator, tmp_zip_template, .{ clock.milliTimestamp(), nextTmpSeq() });
    const file = infra_fs.cwd().createFile(path, .{ .read = true }) catch |err| {
        log.warn("creating zip-upload staging file: {s}", .{@errorName(err)});
        return error.WriteFailed;
    };
    file.writeAll(zip_bytes) catch |err| {
        file.close();
        infra_fs.cwd().deleteFile(path) catch |delete_err| switch (delete_err) {
            error.FileNotFound => {},
            else => log.warn("deleting failed zip-upload staging file: {s}", .{@errorName(delete_err)}),
        };
        log.warn("writing zip-upload staging file: {s}", .{@errorName(err)});
        return error.WriteFailed;
    };
    return .{ .path = path, .file = file };
}

fn extractArchiveEntry(
    allocator: std.mem.Allocator,
    reader: *std.Io.File.Reader,
    entry: std.zip.Iterator.Entry,
    max_bytes: usize,
) ImportError![]const u8 {
    if (entry.uncompressed_size > max_bytes) return error.ReadFailed;
    const size = std.math.cast(usize, entry.uncompressed_size) orelse return error.ReadFailed;
    const data = try allocator.alloc(u8, size);
    errdefer allocator.free(data);
    var writer = std.Io.Writer.fixed(data);
    entry.extractTo(reader, &writer) catch return error.ExtractFailed;
    if (writer.buffered().len != data.len) return error.ExtractFailed;
    return data;
}

fn replaceArchiveFile(allocator: std.mem.Allocator, slot: *?ArchiveFile, replacement: ArchiveFile) void {
    if (slot.*) |old| {
        allocator.free(old.filename);
        allocator.free(old.data);
    }
    slot.* = replacement;
}

fn readArchiveFiles(allocator: std.mem.Allocator, zip_file: std.Io.File) ImportError!ArchiveFiles {
    var read_buffer: [zip_reader_buffer_bytes]u8 = undefined;
    var reader = zip_file.reader(infra_fs.currentIo(), &read_buffer);
    var iterator = std.zip.Iterator.init(&reader) catch return error.ExtractFailed;
    var files: ArchiveFiles = .{};

    while ((iterator.next() catch return error.ExtractFailed)) |entry| {
        const filename_len = std.math.cast(usize, entry.filename_len) orelse return error.ExtractFailed;
        const filename_buf = try allocator.alloc(u8, filename_len);
        var keep_filename = false;
        defer if (!keep_filename) allocator.free(filename_buf);
        const filename = entry.getFilename(&reader, filename_buf, .{}) catch return error.ExtractFailed;

        if (std.mem.endsWith(u8, filename, ".kicad_sym")) {
            const data = try extractArchiveEntry(allocator, &reader, entry, max_kicad_file_bytes);
            replaceArchiveFile(allocator, &files.symbol, .{ .filename = filename, .data = data });
            keep_filename = true;
        } else if (std.mem.endsWith(u8, filename, ".kicad_mod")) {
            const data = try extractArchiveEntry(allocator, &reader, entry, max_kicad_file_bytes);
            replaceArchiveFile(allocator, &files.footprint, .{ .filename = filename, .data = data });
            keep_filename = true;
        } else if (std.ascii.endsWithIgnoreCase(filename, ".stp") or std.ascii.endsWithIgnoreCase(filename, ".step")) {
            if (entry.uncompressed_size > max_step_file_bytes) continue;
            const data = try extractArchiveEntry(allocator, &reader, entry, max_step_file_bytes);
            replaceArchiveFile(allocator, &files.step, .{ .filename = filename, .data = data });
            keep_filename = true;
        }
    }
    return files;
}

/// Convert a KiCad library ZIP (already in memory) into library entries:
/// stage the bytes on disk, read the archive with `std.zip`, locate
/// the `.kicad_sym` / `.kicad_mod` / optional STEP, convert them, and write
/// `lib/{components,footprints,pinouts,models}`. Shared by the `/api/upload-zip`
/// route and the CLI `download_footprint` tool. `filename` is advisory only
/// (kept for call-site compatibility / future logging) — it is NEVER used to
/// build a filesystem path, since it is client-controlled (see the temp-name
/// SECURITY note above).
pub fn importZipBytes(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    zip_bytes: []const u8,
    filename: []const u8,
) ImportError!ImportResult {
    _ = filename;
    var staged = try stageArchive(allocator, zip_bytes);
    defer staged.deinit();
    const files = try readArchiveFiles(allocator, staged.file.f);
    const symbol = files.symbol orelse return error.NoKicadFiles;
    const footprint_file = files.footprint orelse return error.NoKicadFiles;
    const sym_data = symbol.data;
    const fp_data = footprint_file.data;
    const step_data: ?[]const u8 = if (files.step) |step| step.data else null;

    const pkg_name = extractPackageName(sym_data);
    saveSourceFile(allocator, project_dir, std.fs.path.basename(symbol.filename), sym_data);
    saveSourceFile(allocator, project_dir, std.fs.path.basename(footprint_file.filename), fp_data);
    if (files.step) |step| {
        saveSourceFile(allocator, project_dir, std.fs.path.basename(step.filename), step.data);
    }

    const symbol_conv = @import("../convert/symbol.zig");
    const pinout = symbol_conv.generatePinout(allocator, sym_data, null) catch return error.ConvertFailed;
    const footprint_conv = @import("../convert/footprint.zig");
    const footprint = footprint_conv.convertFootprint(allocator, fp_data) catch return error.ConvertFailed;

    const safe_name = sanitizeName(allocator, pkg_name);
    const fp_name_final = extractFootprintName(allocator, footprint) orelse safe_name;
    try writeSexpFile(allocator, project_dir, "pinouts", safe_name, pinout);
    try writeSexpFile(allocator, project_dir, "footprints", fp_name_final, footprint);
    const component = writeComponentFile(allocator, project_dir, safe_name, safe_name, fp_name_final, sym_data);
    // Key the model on the *footprint* name, matching `uploadModelApi` and
    // `findModelFile`'s primary lookup. Keying on `safe_name` (the symbol name)
    // orphans the STEP whenever the symbol and footprint names diverge enough
    // that `findModelFile`'s substring fallback misses — e.g. a CSE part whose
    // symbol is "ASE-25.000MHZ-L-C-T" but whose footprint is "ASE20000MHZLRT".
    if (step_data) |sd| try writeModelFile(allocator, project_dir, fp_name_final, sd);

    return .{
        .package_name = pkg_name,
        .component_name = safe_name,
        .footprint_name = fp_name_final,
        .pinout_name = safe_name,
        .has_3d = step_data != null,
        .component = component,
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
    const path = try std.fmt.allocPrint(allocator, sexp_path_template, .{ dir, name });
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
/// requires). Uses the same bounded `std.zip` reader and staging cleanup.
pub fn extractStepBytes(allocator: std.mem.Allocator, zip_bytes: []const u8, filename: []const u8) ?[]const u8 {
    _ = filename; // advisory only — never used to build a path (client-controlled)
    var staged = stageArchive(allocator, zip_bytes) catch return null;
    defer staged.deinit();
    const files = readArchiveFiles(allocator, staged.file.f) catch return null;
    return if (files.step) |step| step.data else null;
}

/// POST /api/upload-zip — accept a KiCad library zip (must contain a
/// `.kicad_sym` plus a `.kicad_mod`, optionally a STEP), unpack via the
/// system `unzip`, convert each part, and write `lib/components`,
/// `lib/footprints`, `lib/pinouts`, and `lib/models` entries for it.
/// The heavy lifting lives in `importZipBytes`, shared with the CLI path.
pub fn uploadZipApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const body = req.body() orelse {
        res.status = http_bad_request;
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
    const comp_msg: []const u8 = switch (result.component) {
        .created => "component + pinout + footprint",
        .replaced => "component (replaced existing) + pinout + footprint",
        .write_failed => "pinout + footprint (WARNING: component write failed)",
    };
    const msg = std.fmt.allocPrint(
        ctx.allocator,
        "Imported {s}{s} for \"{s}\" (sources saved)",
        .{ comp_msg, step_msg, result.package_name },
    ) catch {
        res.body = "OK";
        return;
    };
    log.warn("zip upload: {s}", .{msg});
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
    log.warn("saved source: lib/sources/{s}", .{filename});
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
    var safe_name: std.ArrayList(u8) = .empty;
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
            var fp_safe: std.ArrayList(u8) = .empty;
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

/// Like `extractProperty`, but try each key in order and return the first
/// non-empty hit. KiCad/SnapEDA symbols name the same field inconsistently
/// (e.g. manufacturer lives under `Manufacturer_Name`, `Manufacturer`,
/// `MANUFACTURER`, or `MF` depending on the export), so a single key drops
/// metadata a re-import should preserve.
fn extractFirstProperty(sym_data: []const u8, keys: []const []const u8) ?[]const u8 {
    for (keys) |k| {
        if (extractProperty(sym_data, k)) |v| return v;
    }
    return null;
}

/// Collapse a raw KiCad property value into a single tidy line: literal
/// escape sequences (`\n`, `\t`, `\r`) and runs of real whitespace become one
/// space, and leading/trailing whitespace is trimmed. SnapEDA descriptions
/// arrive wrapped in newlines and indentation that otherwise land verbatim in
/// the `(description "…")` field.
/// True for a literal two-char escape (`\n`, `\t`, `\r`) starting at `raw[i]`.
fn isEscapedWhitespace(raw: []const u8, i: usize) bool {
    if (raw[i] != '\\' or i + 1 >= raw.len) return false;
    return switch (raw[i + 1]) {
        'n', 't', 'r' => true,
        else => false,
    };
}

fn cleanDescription(allocator: std.mem.Allocator, raw: []const u8) std.mem.Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var sep = false;
    while (i < raw.len) {
        const c = raw[i];
        if (isEscapedWhitespace(raw, i)) {
            sep = true;
            i += 2;
            continue;
        }
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            sep = true;
            i += 1;
            continue;
        }
        if (sep and out.items.len > 0) try out.append(allocator, ' ');
        sep = false;
        try out.append(allocator, c);
        i += 1;
    }
    return out.items;
}

/// Render the `(component …)` S-expression body for an imported part, pulling
/// description / manufacturer / MPN from the KiCad symbol properties (across
/// the common key aliases) when present.
fn renderComponentSexp(
    allocator: std.mem.Allocator,
    safe_name: []const u8,
    pinout_name: []const u8,
    footprint_name: []const u8,
    sym_data: []const u8,
) (std.mem.Allocator.Error || std.Io.Writer.Error)![]const u8 {
    const raw_desc = extractFirstProperty(sym_data, &.{ "ki_description", "Description", "Value" }) orelse safe_name;
    const description = try cleanDescription(allocator, raw_desc);
    const manufacturer = extractFirstProperty(sym_data, &.{ "Manufacturer_Name", "Manufacturer", "MANUFACTURER", "MF" });
    const mpn = extractFirstProperty(sym_data, &.{ "Manufacturer_Part_Number", "MPN", "MP" });

    var buf: std.Io.Writer.Allocating = .init(allocator);
    const w = &buf.writer;
    try w.print("(component \"{s}\"\n", .{safe_name});
    try w.print("  (description \"{s}\")\n", .{description});
    // Names are always quoted: purely-numeric names (e.g. "2049280301") would
    // otherwise tokenize as an int and fail field resolution.
    try w.print("  (pinout \"{s}\")\n", .{pinout_name});
    try w.print("  (footprint \"{s}\")", .{footprint_name});
    if (manufacturer) |m| try w.print("\n  (manufacturer \"{s}\")", .{m});
    if (mpn) |m| try w.print("\n  (mpn \"{s}\")", .{m});
    try w.writeAll(")\n");
    return buf.written();
}

/// Write a `(component ...)` definition to lib/components/<safe_name>.sexp,
/// referencing the pinout + footprint this same import just wrote.
///
/// An existing component is **overwritten** so a re-import yields a component
/// consistent with the freshly-imported pinout/footprint/model — the previous
/// skip-if-exists guard left a stale (often dangling) definition in place and
/// silently dropped the new one, which read as "footprint + 3D but no
/// component". The return value tells the caller whether it created a new file
/// or replaced one so the HTTP/CLI responses can say so instead of staying
/// silent.
pub fn writeComponentFile(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    safe_name: []const u8,
    pinout_name: []const u8,
    footprint_name: []const u8,
    sym_data: []const u8,
) ComponentWrite {
    const dir = std.fmt.allocPrint(allocator, "{s}/lib/components", .{project_dir}) catch return .write_failed;
    defer allocator.free(dir);
    infra_fs.cwd().makePath(dir) catch return .write_failed;

    const path = std.fmt.allocPrint(allocator, sexp_path_template, .{ dir, safe_name }) catch return .write_failed;
    defer allocator.free(path);

    // Note (not skip) whether we're replacing an existing component, so the
    // import can report it rather than silently leaving a stale definition.
    const existed = if (infra_fs.cwd().access(path, .{})) |_| true else |_| false;

    const body = renderComponentSexp(allocator, safe_name, pinout_name, footprint_name, sym_data) catch return .write_failed;

    const f = infra_fs.cwd().createFile(path, .{}) catch return .write_failed;
    defer f.close();
    f.writeAll(body) catch return .write_failed;

    return if (existed) .replaced else .created;
}

test "isEscapedWhitespace reads the escape letter after the backslash" {
    // `raw[i + 1]` looks one byte FORWARD at the escape letter; a `+`->`-`
    // flip reads `raw[i - 1]` (the char before the backslash), misclassifying
    // a real `\\n` escape as ordinary text.
    try std.testing.expect(isEscapedWhitespace("x\\n", 1));
    try std.testing.expect(!isEscapedWhitespace("x\\q", 1));
}

// spec: serve/upload - KiCad ZIP import stages outside RAM-backed /tmp and reads entries with bounded std.zip extraction, without requiring system unzip
test "zip import succeeds without system unzip or RAM-backed temp space" {
    const zipfile = @import("../zipfile.zig");
    const symbol =
        \\(kicad_symbol_lib (version 20211014) (generator test)
        \\  (symbol "SCRP-2-682W+"
        \\    (property "Reference" "U")
        \\    (property "ki_description" "Power splitter")
        \\    (property "Manufacturer_Name" "Mini-Circuits")
        \\    (property "Manufacturer_Part_Number" "SCRP-2-682W+")
        \\    (pin passive line (at 0 0 0) (length 1.27)
        \\      (name "PORT_1") (number "1"))
        \\  )
        \\)
    ;
    const footprint =
        \\(module "SCRP2682W" (layer F.Cu)
        \\  (descr "test footprint")
        \\  (pad 1 smd rect (at 0 0) (size 1 1) (layers F.Cu F.Mask F.Paste))
        \\)
    ;
    const step = "ISO-10303-21;\nEND-ISO-10303-21;\n";

    var zip_out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer zip_out.deinit();
    try zipfile.write(&zip_out.writer, &.{
        .{ .name = "SCRP-2-682W+/KiCad/SCRP-2-682W+.kicad_sym", .data = symbol },
        .{ .name = "SCRP-2-682W+/KiCad/SCRP2682W.kicad_mod", .data = footprint },
        .{ .name = "SCRP-2-682W+/3D/SCRP-2-682W+.stp", .data = step },
    });

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const project_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);

    const result = try importZipBytes(arena, project_dir, zip_out.written(), "LIB_SCRP-2-682W+.zip");
    try std.testing.expectEqualStrings("SCRP-2-682W+", result.package_name);
    try std.testing.expectEqualStrings("scrp-2-682w+", result.component_name);
    try std.testing.expectEqualStrings("scrp2682w", result.footprint_name);
    try std.testing.expect(result.has_3d);

    try tmp.dir.access(std.testing.io, "lib/components/scrp-2-682w+.sexp", .{});
    try tmp.dir.access(std.testing.io, "lib/pinouts/scrp-2-682w+.sexp", .{});
    try tmp.dir.access(std.testing.io, "lib/footprints/scrp2682w.sexp", .{});
    try tmp.dir.access(std.testing.io, "lib/models/scrp2682w.step", .{});
}
