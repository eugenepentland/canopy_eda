//! `GET /api/kicad-sch/:name` — the exported KiCad schematic as one store-only
//! ZIP. The HTTP twin of `netlisp export-kicad-sch`: it drives the same
//! `export_kicad_sch.exportSch`, so the download and the CLI's output directory
//! hold the same bytes.
//!
//! Everything lands at the archive root, flat. That is a correctness
//! requirement, not a style choice: the root sheet's `Sheetfile` properties
//! name bare siblings, and the project sidecars (`sym-lib-table`,
//! `fp-lib-table`, `<design>.kicad_pro`, `netlisp.kicad_sym`) only resolve
//! from the directory holding the `.kicad_pro`.
//!
//! Read-only — nothing here writes to the project dir. `exportSch` re-parses
//! and structurally checks every sheet before it returns, so a schematic that
//! fails its own self-check is answered as a 500 rather than served as a broken
//! download.
//!
//! The finished archive is retained (`serve/read_cache.zig`), keyed by design
//! and the `?vendor=` / `?flat=` pair. Its dependency set is the evaluator
//! read-set plus every `lib/sources/*.kicad_sym` — filename listing AND per-file
//! mtime — because the vendor symbol index is the one input the evaluator never
//! reads, and `lib/sources/` is writable through the CLI VFS and the library
//! upload page. That is the invalidation signal this module previously said it
//! did not have; `page_cache.appendDirFiles` is exactly it, and a vendor symbol
//! edited, added or removed retires the archive on the next lookup.
//!
//! A cached body is served without re-running the export's structural
//! self-check: these exact bytes passed it when they were built, and nothing
//! has touched them since.
//!
//! Footprint links are the one reference this archive cannot resolve on its
//! own: `footprints.pretty/` is written by `export-kicad`, so KiCad reports
//! `footprint_link_issues` until that bundle sits beside these files. The
//! `/api/export-kicad/:name` zip carries both and opens clean.

const std = @import("std");
const httpz = @import("httpz");
const log = @import("../infra/log.zig");
const paths = @import("../paths.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const bom = @import("../bom.zig");
const export_kicad_sch = @import("../export_kicad_sch.zig");
const sym_library = @import("../kicad_sym/library.zig");
const zipfile = @import("../zipfile.zig");
const mcp_tools = @import("mcp_tools.zig");
const page_cache = @import("page_cache.zig");
const handler_probe = @import("handler_probe.zig");
const cached_download = @import("cached_download.zig");
const serve_root = @import("../serve.zig");
const Server = serve_root.Server;

/// Only allocation escapes; every other failure becomes a status code with a
/// plain-text body, as on the schematic-PDF endpoint.
pub const HandlerError = std.mem.Allocator.Error;

const http_not_found: u16 = 404;
const http_internal_error: u16 = 500;

const header_content_type = "Content-Type";
const header_content_disposition = "Content-Disposition";
const header_cors_allow_origin = "access-control-allow-origin";
const content_type_zip = "application/zip";

/// Bodies for the failure paths. Plain text, and neither can be mistaken for
/// an archive by a browser that ignored the status.
const err_not_found = "No design or module by that name\n";
const err_export = "KiCad schematic export failed\n";

/// Everything `zipFor` can fail with: resolving and evaluating the named block
/// (`ToolError`, which carries the `FileNotFound` / `NotADesign` /
/// `InvalidName` the handler maps onto a 404) plus every way the schematic
/// writer can fail its own self-check.
pub const ExportZipError = mcp_tools.ToolError || export_kicad_sch.SchError;

/// Resolve `name` as a design or a bare `lib/modules` module — the same
/// resolution the read-only CLI tools and the review PDF use — and export its
/// schematic. The caller owns the result and calls `deinit`.
///
/// The vendor `.kicad_sym` index is still rebuilt per call: its symbols borrow
/// the export's arena, so retaining the index alone would need a second
/// long-lived one. What the HTTP endpoint retains instead is the finished
/// ARCHIVE, against `deps` — the evaluator read-set plus the `lib/sources/`
/// listing and every vendor file's mtime, so a symbol edited through the CLI
/// VFS or the library upload page can never be served from a stale entry.
pub fn exportFor(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    opts: export_kicad_sch.Options,
    deps: ?*?page_cache.FileSet,
) ExportZipError!export_kicad_sch.Output {
    // `eval` owns the arena the block borrows, so it outlives the export.
    var eval = Evaluator.init(allocator, project_dir);
    defer eval.deinit();
    // Captured before the deferred `deinit` above and before any early error
    // return, so a caller's cache never keys on a half-built read-set.
    defer if (deps) |out| {
        out.* = captureDeps(allocator, &eval, project_dir, name);
    };
    const nb = try mcp_tools.evalNamedBlock(allocator, project_dir, name, &eval);

    // Merge the persisted BOM identities so each symbol's UUID is the one the
    // netlist and the board already carry. A standalone module has no sidecar.
    if (!nb.is_module) {
        if (paths.designSiblingPath(allocator, project_dir, name, ".bom")) |bom_path| {
            defer allocator.free(bom_path);
            bom.resolveIdentities(allocator, nb.block, bom_path, project_dir) catch |e| {
                log.warn("kicad-sch resolveIdentities {s} failed: {s}", .{ name, @errorName(e) });
            };
        } else |_| {}
    }
    return export_kicad_sch.exportSch(allocator, nb.block, project_dir, name, opts);
}

/// The dependency set of one export: everything the evaluator read, plus the
/// vendor symbol library — the `lib/sources/` `.kicad_sym` listing (so an added
/// or removed file counts) and each of their mtimes (so an edit in place
/// counts). The index is the one input the evaluator never touches, and it
/// decides which components are drawn from a real vendor body.
fn captureDeps(
    scratch: std.mem.Allocator,
    eval: *const Evaluator,
    project_dir: []const u8,
    name: []const u8,
) ?page_cache.FileSet {
    var files = page_cache.capture(scratch, eval, project_dir, name) catch return null;
    const sources = std.fmt.allocPrint(scratch, "{s}/{s}", .{ project_dir, sym_library.sources_subdir }) catch {
        files.deinit();
        return null;
    };
    defer scratch.free(sources);
    page_cache.appendDirFiles(&files, scratch, sources, sym_library.suffix) catch {
        files.deinit();
        return null;
    };
    return files;
}

/// The exported sheets plus their sidecars, in the order they belong in the
/// archive: root sheet, child sheets in page order, then the project files.
/// `deps` is forwarded to `exportFor`.
pub fn zipFor(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    opts: export_kicad_sch.Options,
    deps: ?*?page_cache.FileSet,
) ExportZipError![]const u8 {
    const out = try exportFor(allocator, project_dir, name, opts, deps);
    defer out.deinit(allocator);

    var entries: std.ArrayList(zipfile.Entry) = .empty;
    defer entries.deinit(allocator);
    for (out.files) |f| try entries.append(allocator, .{ .name = f.name, .data = f.bytes });
    for (out.sidecars) |f| try entries.append(allocator, .{ .name = f.name, .data = f.bytes });

    var buf: std.Io.Writer.Allocating = .init(allocator);
    errdefer buf.deinit();
    try zipfile.write(&buf.writer, entries.items);
    return buf.toOwnedSlice();
}

/// `?vendor=0` forces the synthesised box symbols (the `--no-vendor-symbols`
/// twin); `?flat=1` forces one sheet (`--flat`). Absent or unparsed query →
/// the CLI defaults.
fn optionsFromQuery(req: *httpz.Request) export_kicad_sch.Options {
    const q = req.query() catch return .{};
    return .{
        .flat = if (q.get("flat")) |v| isOn(v) else false,
        .vendor = if (q.get("vendor")) |v| isOn(v) else true,
    };
}

fn isOn(v: []const u8) bool {
    return !(v.len == 0 or std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "false"));
}

/// GET /api/kicad-sch/:name[?vendor=0][?flat=1] — the schematic hierarchy plus
/// its project sidecars as a `<name>-kicad-sch.zip` attachment. `:name` is a
/// design or a bare `lib/modules/<name>` module and is percent-decoded before
/// any lookup (httpz hands path params over verbatim). Unknown name → 404 with
/// a plain-text body.
pub fn kicadSchApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const endpoint = cached_download.endpointFor(ctx, req, res, err_not_found, frameZip);
    const cache = &ctx.state.caches.reads.kicad_sch;
    const miss = try cached_download.begin(endpoint, cache) orelse return;

    var deps: ?page_cache.FileSet = null;
    const zip = zipFor(ctx.allocator, ctx.project_dir, miss.name, optionsFromQuery(req), &deps) catch |e| {
        if (deps) |d| d.deinit();
        if (!cached_download.answeredNotFound(endpoint, e)) {
            log.warn("kicad-sch export {s} failed: {s}", .{ miss.name, @errorName(e) });
            cached_download.fail(endpoint, err_export);
        }
        return;
    };

    try cached_download.finish(endpoint, cache, miss, zip, deps);
}

/// How every answer from this endpoint is framed, hit or miss alike.
fn frameZip(allocator: std.mem.Allocator, res: *httpz.Response, name: []const u8) std.mem.Allocator.Error!void {
    res.header(header_content_type, content_type_zip);
    res.header(header_content_disposition, try dispositionFor(allocator, name));
    res.header(header_cors_allow_origin, "*");
}

/// `Content-Disposition` naming the download `<name>-kicad-sch.zip`. Built per
/// request (it embeds the design name) whether the archive was exported or
/// recalled, so a cached answer is framed exactly as a fresh one.
fn dispositionFor(allocator: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "attachment; filename=\"{s}-kicad-sch.zip\"", .{name});
}

// ── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;

/// The vendor-symbol reader's own flat-library fixture, reused here as a
/// `lib/sources` entry so the `?vendor=0` query has something to switch off.
const vendor_sym = @embedFile("../kicad_sym/testdata/vendor-flat.kicad_sym");

/// A design small enough to export in milliseconds but real enough to exercise
/// the whole path: one hub IC and two bypass caps in a named section.
///
/// Every instance carries an explicit `(id …)`. That is what makes the export
/// byte-comparable at all: an instance without one is minted a RANDOM 8-char
/// id at evaluation (`eval/ids.generateId`), which becomes its symbol UUID, so
/// two evaluations of an un-stamped design differ by design. A real board is
/// stamped on its first build, which is the state these tests model.
fn writeSchFixture(dir: std.Io.Dir, file: []const u8) !void {
    try dir.createDirPath(std.testing.io, "lib/components");
    try dir.createDirPath(std.testing.io, "src");
    try dir.writeFile(std.testing.io, .{ .sub_path = "lib/components/sch-ic.sexp", .data =
        \\(component "sch-ic"
        \\  (description "minimal test regulator"))
    });
    try dir.writeFile(std.testing.io, .{ .sub_path = "lib/components/sch-cap.sexp", .data =
        \\(component-family "sch-cap"
        \\  (description "minimal test cap")
        \\  (parameter "value" capacitance))
    });
    var buf: [128]u8 = undefined;
    const sub_path = try std.fmt.bufPrint(&buf, "src/{s}.sexp", .{file});
    try dir.writeFile(std.testing.io, .{ .sub_path = sub_path, .data =
        \\(import sch-ic)
        \\(import sch-cap)
        \\
        \\(design-block "Sch Demo Board"
        \\  (section "Core Rail" "sch-ic 5V-to-3.3V test rail"
        \\    (row 0) (col 0)
        \\    (instance "U1" sch-ic
        \\      (id "aa000001")
        \\      (pin 1 "VIN")
        \\      (pin 2 "VOUT")
        \\      (pin 3 "GND"))
        \\    (instance "C1" (sch-cap "1uF")
        \\      (id "aa000002")
        \\      (pin 1 "VIN")
        \\      (pin 2 "GND"))
        \\    (instance "C2" (sch-cap "10uF")
        \\      (id "aa000003")
        \\      (pin 1 "VOUT")
        \\      (pin 2 "GND"))))
    });
}

/// Drive the real handler for `name` (percent-encoded as given) with an
/// optional query pair, and return the status plus a copy of the body.
fn serve(
    alloc: std.mem.Allocator,
    project: []const u8,
    name: []const u8,
    query: ?[2][]const u8,
) !handler_probe.Served {
    const pair = query orelse return handler_probe.drive(alloc, project, name, &.{}, kicadSchApi);
    return handler_probe.drive(alloc, project, name, &.{pair}, kicadSchApi);
}

/// The archive-internal names in central-directory order. A store-only ZIP
/// written by `zipfile` lists them once per local header, which is all this
/// needs to assert the member list.
fn zipNames(alloc: std.mem.Allocator, zip: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i + 30 <= zip.len and std.mem.eql(u8, zip[i .. i + 4], "PK\x03\x04")) {
        const size = std.mem.readInt(u32, zip[i + 18 ..][0..4], .little);
        const name_len = std.mem.readInt(u16, zip[i + 26 ..][0..2], .little);
        try out.append(alloc, zip[i + 30 ..][0..name_len]);
        i += 30 + name_len + size;
    }
    return out.items;
}

// spec: Web Server - GET /api/kicad-sch/:name returns a store-only zip whose flat member list is the schematic sheets followed by the four project sidecars
test "the kicad-sch endpoint serves a flat zip of sheets plus sidecars" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeSchFixture(tmp.dir, "schdemo");
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);

    const got = try serve(alloc, project, "schdemo", null);
    try testing.expectEqual(@as(u16, 200), got.status);
    try testing.expect(std.mem.startsWith(u8, got.body, "PK\x03\x04"));

    const names = try zipNames(alloc, got.body);
    // Root sheet first, then the sidecars — and every member is a bare name,
    // because the root's Sheetfile links and the sidecars are all siblings.
    try testing.expectEqualStrings("schdemo.kicad_sch", names[0]);
    try testing.expect(allBareNames(names));
    try testing.expect(hasName(names, "schdemo.kicad_pro"));
    try testing.expect(hasName(names, "sym-lib-table"));
    try testing.expect(hasName(names, "fp-lib-table"));
    try testing.expect(hasName(names, "netlisp.kicad_sym"));
}

/// (test helper) True when `want` is one of the archive's member names.
fn hasName(names: []const []const u8, want: []const u8) bool {
    for (names) |n| {
        if (std.mem.eql(u8, n, want)) return true;
    }
    return false;
}

/// (test helper) True when no member name carries a directory component —
/// the property that keeps the whole export in one directory when unpacked.
fn allBareNames(names: []const []const u8) bool {
    for (names) |n| {
        if (std.mem.indexOfScalar(u8, n, '/') != null) return false;
    }
    return true;
}

// spec: Web Server - GET /api/kicad-sch/:name is byte-identical across repeated requests for an unchanged design
test "the kicad-sch endpoint is deterministic" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeSchFixture(tmp.dir, "schdemo");
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);

    const first = try serve(alloc, project, "schdemo", null);
    const second = try serve(alloc, project, "schdemo", null);
    try testing.expectEqualSlices(u8, first.body, second.body);
}

// spec: Web Server - GET /api/kicad-sch/:name answers an unknown design or module name with a 404 whose body is never an archive
test "the kicad-sch endpoint 404s a name that is neither design nor module" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeSchFixture(tmp.dir, "schdemo");
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);

    const got = try serve(alloc, project, "no-such-board", null);
    try testing.expectEqual(@as(u16, 404), got.status);
    try testing.expect(!std.mem.startsWith(u8, got.body, "PK"));
    try testing.expect(std.mem.indexOf(u8, got.body, "No design or module") != null);
}

// spec: Web Server - GET /api/kicad-sch/:name percent-decodes the path param, so an encoded design name resolves to the same design as its decoded form
test "the kicad-sch endpoint percent-decodes the design name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeSchFixture(tmp.dir, "sch demo");
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);

    const encoded = try serve(alloc, project, "sch%20demo", null);
    try testing.expectEqual(@as(u16, 200), encoded.status);
    const decoded = try serve(alloc, project, "sch demo", null);
    try testing.expectEqualSlices(u8, decoded.body, encoded.body);
    // The 200 is itself the proof: there is no `src/sch%20demo.sexp` on disk,
    // so an undecoded lookup would have 404'd.
    const literal = try serve(alloc, project, "sch%2520demo", null);
    try testing.expectEqual(@as(u16, 404), literal.status);
}

// spec: Web Server - GET /api/kicad-sch/:name?vendor=0 and ?flat=1 are the query twins of the --no-vendor-symbols and --flat CLI flags
test "the kicad-sch endpoint's query flags mirror the CLI flags" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeSchFixture(tmp.dir, "schdemo");
    // A vendor library filed under the IC's component name, so the default
    // export draws U1 from a real body and `?vendor=0` cannot silently agree
    // with it — that difference is the proof the query reached Options.
    try tmp.dir.createDirPath(std.testing.io, "lib/sources");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/sources/sch-ic.kicad_sym", .data = vendor_sym });
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);

    const plain = try serve(alloc, project, "schdemo", null);
    const no_vendor = try serve(alloc, project, "schdemo", [2][]const u8{ "vendor", "0" });
    try testing.expectEqual(@as(u16, 200), no_vendor.status);
    try testing.expect(!std.mem.eql(u8, plain.body, no_vendor.body));

    // `?flat=1` is accepted and returns the same design: this fixture is three
    // parts, well under `flat_max_parts`, so it was already on one sheet. What
    // the flag must not do is fail or resolve a different board.
    const flat = try serve(alloc, project, "schdemo", [2][]const u8{ "flat", "1" });
    try testing.expectEqual(@as(u16, 200), flat.status);
    try testing.expectEqualSlices(u8, plain.body, flat.body);
}
