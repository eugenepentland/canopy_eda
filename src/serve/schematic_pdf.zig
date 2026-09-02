//! `GET /api/schematic-pdf/:name` — the review-document PDF (WP-D of
//! `docs/pdf-export-plan.md`). The HTTP twin of `netlisp export-pdf`: it
//! assembles the exact same triple the CLI does — the evaluated block, the
//! `review.ReviewDoc`, and an `export_pdf.Options` — so the downloaded file and
//! the CLI's output are the same document. The one deliberate difference is the
//! `/CreationDate`: a served PDF is stamped with the request's wall clock (the
//! CLI leaves it off to stay byte-reproducible), derived from the review doc's
//! own ISO stamp so the visible cover date and the metadata date can never
//! disagree.
//!
//! Read-only: nothing here writes to the project dir.
//!
//! Composed bytes ARE retained (`serve/read_cache.zig`), keyed by design and
//! `?theme=`. The old rationale here — "a compose is well under a second" —
//! was measured before the largest board in this project existed: `barracuda`
//! costs 4.2 s cold and 4.4 s on the identical repeat, essentially all of it
//! the fresh design evaluation this handler opens with. The invalidation
//! signal it claimed not to have is the ordinary one every other read surface
//! uses: the evaluator read-set the compose itself walked, plus the placement
//! sidecars the cooling ladder on the power page is solved from, plus the
//! design's live-edit version.
//!
//! A served cached document keeps the `/CreationDate` (and the matching visible
//! cover date) of the compose that produced it, so a re-download of an
//! unchanged design is stamped when its content was actually generated rather
//! than when it was fetched. That is the honest reading of the field, and it is
//! what makes two downloads of one unchanged design byte-identical.

const std = @import("std");
const build_id = @import("../build_id.zig");
const httpz = @import("httpz");
const log = @import("../infra/log.zig");
const paths = @import("../paths.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const bom = @import("../bom.zig");
const erc_mod = @import("../erc.zig");
const req_checks = @import("../req_checks.zig");
const review_mod = @import("../review.zig");
const export_pdf = @import("../export_pdf.zig");
const pdf_mod = @import("../pdf.zig");
const svg2pdf = @import("../svg2pdf.zig");
const mcp_tools = @import("mcp_tools.zig");
const notes = @import("notes.zig");
const page_cache = @import("page_cache.zig");
const handler_probe = @import("handler_probe.zig");
const cached_download = @import("cached_download.zig");
const thermal_api = @import("thermal_api.zig");
const serve_root = @import("../serve.zig");
const Server = serve_root.Server;

/// Error set for handlers in this module. Only allocation escapes: every other
/// failure (unknown name, compose rejection, failed self-check) is answered as
/// a status code with a plain-text body rather than propagated to httpz.
pub const HandlerError = std.mem.Allocator.Error;

const http_not_found: u16 = 404;
const http_internal_error: u16 = 500;

const header_content_disposition = "Content-Disposition";
const header_cors_allow_origin = "access-control-allow-origin";

/// Body for a `:name` that resolves to neither a design nor a module. Plain
/// text, and it never reads as success — the download is a file, so a browser
/// that ignored the status would otherwise save an error page as `<name>.pdf`.
const err_not_found = "No design or module by that name\n";
const err_compose = "PDF compose error\n";
const err_self_check = "PDF self-check failed\n";

/// Translate the review doc's ISO-8601 UTC stamp (`YYYY-MM-DDTHH:MM:SSZ`) into
/// the PDF date syntax (`D:YYYYMMDDHHMMSSZ`) — the two are the same instant in
/// different spellings, so the cover's visible stamp and the file's
/// `/CreationDate` come from one clock read. Returns null for anything that
/// isn't that exact shape, which simply omits `/CreationDate` rather than
/// emitting a malformed date.
fn pdfDateFromIso(allocator: std.mem.Allocator, iso: []const u8) std.mem.Allocator.Error!?[]const u8 {
    // "2026-07-30T12:34:56Z" — 20 bytes, separators at fixed offsets.
    if (iso.len != 20) return null;
    if (iso[4] != '-' or iso[7] != '-' or iso[10] != 'T') return null;
    if (iso[13] != ':' or iso[16] != ':' or iso[19] != 'Z') return null;
    for ([_]usize{ 0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18 }) |i| {
        if (!std.ascii.isDigit(iso[i])) return null;
    }
    const out = try std.fmt.allocPrint(allocator, "D:{s}{s}{s}{s}{s}{s}Z", .{
        iso[0..4], iso[5..7], iso[8..10], iso[11..13], iso[14..16], iso[17..19],
    });
    return out;
}

/// The `?theme=` palette selector: `light` selects the print palette a
/// reviewer prints, anything else (including no query at all) is the dark
/// screen theme matching the web viewer.
fn themeFromQuery(req: *httpz.Request) svg2pdf.Theme {
    const q = req.query() catch return .screen;
    const v = q.get("theme") orelse return .screen;
    return if (std.mem.eql(u8, v, "light")) .print else .screen;
}

/// Count still-open entries in the design's `<design>.notes.md` sidecar — the
/// same figure the CLI puts on the cover. A missing sidecar is zero, not an
/// error.
fn openNoteCount(allocator: std.mem.Allocator, project_dir: []const u8, name: []const u8) usize {
    var raw: ?[]u8 = null;
    const parsed = notes.loadNotes(allocator, project_dir, name, &raw) catch return 0;
    var open: usize = 0;
    for (parsed.tasks) |t| {
        if (t.completed == null) open += 1;
    }
    return open;
}

/// Compose the review PDF for `name`, resolving it as a design or (failing
/// that) as a standalone module — the same `evalNamedBlock` resolution the
/// read-only CLI tools and the export-review package use. The caller owns the
/// returned slice; on any failure the error is returned for the handler to map
/// onto a status.
/// `deps`, when non-null, receives the file dependency set of this compose —
/// the evaluator read-set plus the placement sidecars the embedded cooling
/// ladder is solved from — so the caller can retain the document against it.
/// Captured before the deferred `deinit` below and before any early error
/// return, so a cache never keys on a half-built read-set.
fn composeFor(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    theme: svg2pdf.Theme,
    deps: ?*?page_cache.FileSet,
) ![]u8 {
    // `eval` must outlive the block it returns (the block borrows its arena),
    // so it lives for the whole compose.
    var eval = Evaluator.init(allocator, project_dir);
    defer eval.deinit();
    defer if (deps) |out| {
        out.* = thermal_api.captureDeps(allocator, &eval, project_dir, name);
    };
    const nb = try mcp_tools.evalNamedBlock(allocator, project_dir, name, &eval);

    // Merge the persisted BOM identities so the PDF's parts agree with the
    // schematic page's. A standalone module has no `.bom` sidecar.
    if (!nb.is_module) {
        if (paths.designSiblingPath(allocator, project_dir, name, ".bom")) |bom_path| {
            defer allocator.free(bom_path);
            bom.resolveIdentities(allocator, nb.block, bom_path, project_dir) catch |e| {
                log.warn("schematic-pdf resolveIdentities {s} failed: {s}", .{ name, @errorName(e) });
            };
        } else |_| {}
    }

    const violations = mcp_tools.runErcForNamedBlock(allocator, nb, project_dir) catch
        &[_]erc_mod.Violation{};
    var check_results = req_checks.runChecks(allocator, &eval, nb.block) catch
        std.StringHashMapUnmanaged([]req_checks.Result).empty;
    req_checks.applyVerifications(&check_results, nb.block, nb.block.instances);

    var doc = try review_mod.buildReview(
        allocator,
        name,
        nb.block,
        eval.assertions.items,
        violations,
        &check_results,
    );
    // `buildReview` reads the block alone; the cooling-scenario ladder needs the
    // project directory and the design's saved layouts, which this handler has.
    doc.power.scenarios = thermal_api.scenariosFor(
        allocator,
        project_dir,
        name,
        doc.power.thermal,
        doc.power.thermal.ambient_c,
        // The review document describes the design's DEFAULT board, the one the
        // rest of it reports on; comparing named layouts is the thermal page's job.
        null,
    ) catch .{};

    // One clock read for the whole document: `buildReview` stamped
    // `generated_at`, and the `/CreationDate` is that same instant re-spelled,
    // so the visible cover date and the file metadata can never disagree.
    const bytes = try export_pdf.compose(allocator, nb.block, project_dir, name, doc, .{
        .theme = theme,
        .generated_at = doc.generated_at,
        .build_id = build_id.current(),
        .timestamp = try pdfDateFromIso(allocator, doc.generated_at),
        .open_notes = openNoteCount(allocator, project_dir, name),
    });

    // The writer's own structural self-check (xref offsets, stream lengths,
    // q/Q + BT/ET balance) — the same gate the CLI runs before writing to
    // disk, so a structurally broken file can never leave the server either.
    try pdf_mod.validate(bytes);
    return bytes;
}

/// GET /api/schematic-pdf/:name[?theme=light] — the design-review PDF as an
/// attachment. `:name` is a design or a bare `lib/modules/<name>` module, and
/// is percent-decoded before any lookup (httpz hands path params over
/// verbatim). Unknown name → 404 with a plain-text body.
pub fn schematicPdfApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const endpoint = cached_download.endpointFor(ctx, req, res, err_not_found, framePdf);
    const cache = &ctx.state.caches.reads.schematic_pdf;
    const miss = try cached_download.begin(endpoint, cache) orelse return;

    var deps: ?page_cache.FileSet = null;
    const bytes = composeFor(ctx.allocator, ctx.project_dir, miss.name, themeFromQuery(req), &deps) catch |e| {
        if (deps) |d| d.deinit();
        if (cached_download.answeredNotFound(endpoint, e)) return;
        switch (e) {
            error.BadHeader,
            error.MissingStartxref,
            error.BadXrefOffset,
            error.BadXrefTable,
            error.ObjectOffsetMismatch,
            error.BadTrailerSize,
            error.StreamLengthMismatch,
            error.UnbalancedGraphicsState,
            error.UnbalancedTextObject,
            => {
                log.warn("schematic-pdf self-check {s} failed: {s}", .{ miss.name, @errorName(e) });
                cached_download.fail(endpoint, err_self_check);
            },
            else => {
                log.warn("schematic-pdf compose {s} failed: {s}", .{ miss.name, @errorName(e) });
                cached_download.fail(endpoint, err_compose);
            },
        }
        return;
    };

    try cached_download.finish(endpoint, cache, miss, bytes, deps);
}

/// How every answer from this endpoint is framed, hit or miss alike.
fn framePdf(allocator: std.mem.Allocator, res: *httpz.Response, name: []const u8) std.mem.Allocator.Error!void {
    res.content_type = .PDF;
    res.header(header_content_disposition, try dispositionFor(allocator, name));
    res.header(header_cors_allow_origin, "*");
}

/// `Content-Disposition` naming the download `<name>.pdf`. Built per request
/// (it embeds the design name) whether the document was composed or recalled,
/// so a cached answer is framed exactly as a fresh one.
fn dispositionFor(allocator: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "attachment; filename=\"{s}.pdf\"", .{name});
}

// ── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;

/// A design small enough to compose in milliseconds but real enough to exercise
/// the whole path: a hub IC in a named section, two bypass caps, and a note the
/// review doc reports. Written under `<dir>` as `src/<file>.sexp`.
fn writePdfFixture(dir: std.Io.Dir, file: []const u8) !void {
    try dir.createDirPath(std.testing.io, "lib/components");
    try dir.createDirPath(std.testing.io, "src");
    try dir.writeFile(std.testing.io, .{ .sub_path = "lib/components/pdf-ic.sexp", .data =
        \\(component "pdf-ic"
        \\  (description "minimal test regulator"))
    });
    try dir.writeFile(std.testing.io, .{ .sub_path = "lib/components/pdf-cap.sexp", .data =
        \\(component-family "pdf-cap"
        \\  (description "minimal test cap")
        \\  (parameter "value" capacitance))
    });
    var buf: [128]u8 = undefined;
    const sub_path = try std.fmt.bufPrint(&buf, "src/{s}.sexp", .{file});
    try dir.writeFile(std.testing.io, .{ .sub_path = sub_path, .data =
        \\(import pdf-ic)
        \\(import pdf-cap)
        \\
        \\(design-block "PDF Demo Board"
        \\  (section "Core Rail" "pdf-ic 5V-to-3.3V test rail"
        \\    (row 0) (col 0)
        \\    (instance "U1" pdf-ic
        \\      (pin 1 "VIN")
        \\      (pin 2 "VOUT")
        \\      (pin 3 "GND"))
        \\    (instance "C1" (pdf-cap "1uF")
        \\      (pin 1 "VIN")
        \\      (pin 2 "GND"))
        \\    (instance "C2" (pdf-cap "10uF")
        \\      (pin 1 "VOUT")
        \\      (pin 2 "GND"))))
    });
}

/// Drive the real handler for `name` (percent-encoded as given) and return the
/// status plus a copy of the body on `alloc`.
fn serve(alloc: std.mem.Allocator, project: []const u8, name: []const u8, theme: ?[]const u8) !handler_probe.Served {
    const t = theme orelse return handler_probe.drive(alloc, project, name, &.{}, schematicPdfApi);
    return handler_probe.drive(alloc, project, name, &.{.{ "theme", t }}, schematicPdfApi);
}

// spec: Web Server - GET /api/schematic-pdf/:name returns the composed review PDF as an application/pdf attachment that passes the writer's structural self-check
test "the schematic-pdf endpoint serves a valid PDF attachment" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePdfFixture(tmp.dir, "pdfdemo");
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);

    const got = try serve(alloc, project, "pdfdemo", null);
    try testing.expectEqual(@as(u16, 200), got.status);
    try testing.expectEqual(httpz.ContentType.PDF, got.content_type.?);
    // A real PDF, not an error page a browser would save as pdfdemo.pdf.
    try testing.expect(std.mem.startsWith(u8, got.body, "%PDF"));
    // The writer's own invariants hold on the served bytes.
    try pdf_mod.validate(got.body);
    try testing.expect(export_pdf.pageCount(got.body) > 0);
    // The served file is stamped with a real clock read (the CLI's output
    // deliberately carries no /CreationDate).
    try testing.expect(std.mem.indexOf(u8, got.body, "/CreationDate (D:") != null);
}

// spec: Web Server - GET /api/schematic-pdf/:name answers an unknown design or module name with a 404 whose body never reads as a PDF
test "the schematic-pdf endpoint 404s a name that is neither design nor module" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePdfFixture(tmp.dir, "pdfdemo");
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);

    const got = try serve(alloc, project, "no-such-board", null);
    try testing.expectEqual(@as(u16, 404), got.status);
    // The body must not masquerade as a document: no %PDF header, and it says
    // what went wrong.
    try testing.expect(!std.mem.startsWith(u8, got.body, "%PDF"));
    try testing.expect(std.mem.indexOf(u8, got.body, "No design or module") != null);
}

// spec: Web Server - GET /api/schematic-pdf/:name?theme=light composes the print palette, yielding different bytes over the same pages as the default screen palette
test "the schematic-pdf endpoint's theme query selects the palette" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePdfFixture(tmp.dir, "pdfdemo");
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);

    const dark = try serve(alloc, project, "pdfdemo", null);
    const light = try serve(alloc, project, "pdfdemo", "light");
    try testing.expectEqual(@as(u16, 200), dark.status);
    try testing.expectEqual(@as(u16, 200), light.status);
    // Same document, different ink: the palettes must not produce equal bytes.
    try testing.expectEqual(export_pdf.pageCount(dark.body), export_pdf.pageCount(light.body));
    try testing.expect(!std.mem.eql(u8, dark.body, light.body));
    // An unrecognised theme word is the dark screen default, not an error.
    const bogus = try serve(alloc, project, "pdfdemo", "chartreuse");
    try testing.expectEqual(@as(u16, 200), bogus.status);
}

// spec: Web Server - GET /api/schematic-pdf/:name percent-decodes the path param, so an encoded design name resolves to the same design as its decoded form
test "the schematic-pdf endpoint percent-decodes the design name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // A design whose name needs encoding in a URL.
    try writePdfFixture(tmp.dir, "pdf demo");
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);

    const encoded = try serve(alloc, project, "pdf%20demo", null);
    try testing.expectEqual(@as(u16, 200), encoded.status);
    try testing.expect(std.mem.startsWith(u8, encoded.body, "%PDF"));

    // The decoded spelling resolves the same design — page counts match, and
    // (with the /CreationDate the only clock-dependent field) the documents are
    // otherwise the same size.
    const decoded = try serve(alloc, project, "pdf demo", null);
    try testing.expectEqual(@as(u16, 200), decoded.status);
    try testing.expectEqual(export_pdf.pageCount(decoded.body), export_pdf.pageCount(encoded.body));
    try testing.expectEqual(decoded.body.len, encoded.body.len);

    // The 200 above is itself the proof the decode happened: there is no
    // `src/pdf%20demo.sexp` on disk, so an undecoded lookup would have 404'd.
    const literal = try serve(alloc, project, "pdf%2520demo", null);
    try testing.expectEqual(@as(u16, 404), literal.status);
}

// spec: Web Server - The served PDF's /CreationDate is the review document's own generation instant, re-spelled in PDF date syntax
test "the ISO generation stamp maps onto PDF date syntax" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const ok = (try pdfDateFromIso(alloc, "2026-07-30T12:34:56Z")).?;
    try testing.expectEqualStrings("D:20260730123456Z", ok);

    // Anything not that exact shape omits /CreationDate rather than emitting a
    // malformed date: wrong length, wrong separators, non-digits.
    try testing.expect(try pdfDateFromIso(alloc, "") == null);
    try testing.expect(try pdfDateFromIso(alloc, "2026-07-30") == null);
    try testing.expect(try pdfDateFromIso(alloc, "2026/07/30T12:34:56Z") == null);
    try testing.expect(try pdfDateFromIso(alloc, "2026-07-30 12:34:56Z") == null);
    try testing.expect(try pdfDateFromIso(alloc, "20xx-07-30T12:34:56Z") == null);
}
