//! `GET /api/part-review/:name` and `GET /api/part-review/:name/:ref` — the
//! per-part review as read-only JSON, and the `part_review` CLI tool that
//! answers with the same bytes.
//!
//! The composition itself lives in `part_review.zig`; this module is only the
//! resolve-and-answer seam, the pattern `serve/thermal_api.zig` uses. Both
//! surfaces run through one body per shape, so an agent reading the tool and
//! the BOM tab reading the endpoint can never be told different verdicts about
//! the same placement.
//!
//! Two shapes, one composition. The chip body (`/api/part-review/:name`) is the
//! whole BOM's Review column: one `{ref, class, pass, unproven, fail,
//! not_declared, verdict}` per placed part. The sheet body
//! (`/api/part-review/:name/:ref`) is one part's whole contract. Composing the
//! board costs the same either way — one evaluation, one preflight run, one
//! rating screen — so both are retained in `serve/read_cache.zig` against the
//! evaluator's read-set. The per-ref entry keys on the design name and the ref
//! together, NUL-separated, because the ref arrives as a path segment rather
//! than a query parameter.
//!
//! Read-only: nothing here writes to the project dir.

const std = @import("std");
const httpz = @import("httpz");
const json_writer = @import("../json_writer.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const mcp_tools = @import("mcp_tools.zig");
const page_cache = @import("page_cache.zig");
const page_cache_endpoint = @import("page_cache_endpoint.zig");
const part_review = @import("../part_review.zig");
const serve_root = @import("../serve.zig");
const urlcodec = @import("urlcodec.zig");
const Server = serve_root.Server;

/// Error set for the handlers. Only allocation escapes to httpz; every other
/// failure is answered as a status plus a JSON error body.
pub const HandlerError = std.mem.Allocator.Error;

const http_not_found: u16 = 404;

const err_not_found = "No design by that name\n";

/// Everything one composition can fail with. `PartNotFound` is the design
/// resolving but placing no part by that ref — a 404 that is NOT the same
/// answer as an unknown design, and a reader should be told which.
pub const ReviewError = part_review.CollectError || error{PartNotFound};

/// The byte separating a target's two halves. NUL, because no design name and
/// no ref-des can contain one, so no target can spell another's cache key.
const target_sep: u8 = 0;

/// A request target: the design, and optionally one placed part of it. Both
/// halves travel as ONE string — `design` for the whole BOM's chips,
/// `design\0ref` for one part's sheet — because the shared cached-endpoint
/// shape keys, versions and computes from a single `name`, and the ref arrives
/// as a PATH segment the store's query-parameter folding cannot see.
fn targetOf(
    scratch: std.mem.Allocator,
    design: []const u8,
    ref: ?[]const u8,
) std.mem.Allocator.Error![]const u8 {
    const want = ref orelse return design;
    return std.fmt.allocPrint(scratch, "{s}{c}{s}", .{ design, target_sep, want });
}

/// The design half of a target.
fn designOf(target: []const u8) []const u8 {
    const sep = std.mem.indexOfScalar(u8, target, target_sep) orelse return target;
    return target[0..sep];
}

/// The ref half of a target, or null when the target names a whole board.
fn refOf(target: []const u8) ?[]const u8 {
    const sep = std.mem.indexOfScalar(u8, target, target_sep) orelse return null;
    return target[sep + 1 ..];
}

/// The design's live-edit generation, read through the target's design half so
/// a part sheet retires on exactly the edits its board's chips retire on.
fn versionOf(target: []const u8) u32 {
    return serve_root.getLiveVersion(designOf(target));
}

/// Compose the whole board and serialize the shape `target` asks for.
///
/// This is the WHOLE body every surface below shares. `deps` receives the file
/// dependency set of the evaluation so the answer can be retained against it;
/// the capture happens while the evaluator is alive and before any early
/// return, so a cache never keys on a half-built read-set.
///
/// Composing the board costs the same either way — one evaluation, one
/// preflight run, one rating screen — so the chip body and one part's sheet are
/// two projections of one computation rather than two pipelines.
fn compose(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    target: []const u8,
    _: void,
    deps: *?page_cache.FileSet,
) ReviewError![]const u8 {
    const name = designOf(target);
    var eval = Evaluator.init(alloc, project_dir);
    defer eval.deinit();
    defer {
        deps.* = page_cache.capture(alloc, &eval, project_dir, name) catch null;
    }
    const board = try part_review.collectWith(alloc, &eval, project_dir, name, .{});
    var aw: std.Io.Writer.Allocating = .init(alloc);
    const want = refOf(target) orelse {
        part_review.writeChipsJson(&aw.writer, board) catch return error.OutOfMemory;
        return aw.written();
    };
    const part = board.find(want) orelse return error.PartNotFound;
    part_review.writePartJson(&aw.writer, board.design, part) catch return error.OutOfMemory;
    return aw.written();
}

/// This endpoint takes no query knobs at all: the ref is a path segment and the
/// ambient is not a per-request choice here.
fn noOptions(_: std.mem.Allocator, _: *httpz.Request) void {}

/// How a failed composition reaches the wire. An unknown design and a ref the
/// design does not place are both 404, with different sentences.
fn failure(e: ReviewError) struct { status: u16, msg: []const u8, json: []const u8 } {
    return switch (e) {
        error.PartNotFound => .{
            .status = http_not_found,
            .msg = "no placed part by that ref-des",
            .json = "{\"error\":\"no placed part by that ref-des\"}",
        },
        error.InvalidName, error.NotADesign, error.EvaluateFailed => .{
            .status = http_not_found,
            .msg = "no design by that name",
            .json = "{\"error\":\"no design by that name\"}",
        },
        else => .{
            .status = 500,
            .msg = "part review failed",
            .json = "{\"error\":\"part review failed\"}",
        },
    };
}

/// Both routes answer through the one dependency-cached GET shape: try the
/// store, compose on a miss, frame the JSON, retain against the read-set.
const review_endpoint = page_cache_endpoint.Endpoint(.{
    .compute = compose,
    .request_opts = noOptions,
    .failure = failure,
    .version_of = versionOf,
    .content_type = httpz.ContentType.JSON,
    .error_body = page_cache_endpoint.ErrorBody.json,
    .no_store = false,
});

fn plainError(res: *httpz.Response, status: u16, body: []const u8) void {
    res.status = status;
    res.body = body;
}

/// `GET /api/part-review/:name` — one chip per placed part, for the BOM tab's
/// Review column. Unknown design → 404.
pub fn chipsApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const raw = req.param("name") orelse return plainError(res, http_not_found, err_not_found);
    const name = try urlcodec.decodeAlloc(req.arena, raw);
    review_endpoint.answer(&ctx.state.caches.reads.part_review, ctx.project_dir, name, req, res);
}

/// `GET /api/part-review/:name/:ref` — one placed part's whole review contract.
/// `:ref` is the sub-block-qualified ref (`ldo_3v3_lmx%2FU21`), or the bare
/// leaf `U21`. Unknown design → 404; known design, unknown ref → 404.
pub fn partApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const raw = req.param("name") orelse return plainError(res, http_not_found, err_not_found);
    const raw_ref = req.param("ref") orelse return plainError(res, http_not_found, err_not_found);
    const name = try urlcodec.decodeAlloc(req.arena, raw);
    const ref = try urlcodec.decodeAlloc(req.arena, raw_ref);
    const target = try targetOf(req.arena, name, ref);
    review_endpoint.answer(&ctx.state.caches.reads.part_review, ctx.project_dir, target, req, res);
}

// ── CLI tool ──────────────────────────────────────────────────────────────

fn argStr(args_val: ?std.json.Value, key: []const u8) ?[]const u8 {
    const av = args_val orelse return null;
    if (av != .object) return null;
    const v = av.object.get(key) orelse return null;
    return if (v == .string and v.string.len > 0) v.string else null;
}

fn toolError(out: *std.ArrayList(u8), alloc: std.mem.Allocator, msg: []const u8) std.mem.Allocator.Error!bool {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    aw.writer.writeAll("{\"error\":") catch return error.OutOfMemory;
    json_writer.writeString(&aw.writer, msg) catch return error.OutOfMemory;
    aw.writer.writeAll("}") catch return error.OutOfMemory;
    try out.appendSlice(alloc, aw.written());
    return false;
}

fn toolErrorFmt(
    out: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    comptime fmt: []const u8,
    args: anytype,
) std.mem.Allocator.Error!bool {
    const msg = try std.fmt.allocPrint(alloc, fmt, args);
    return toolError(out, alloc, msg);
}

/// `part_review` — the CLI twin of both endpoints. Args `name` (a design) and
/// an optional `ref`: with a ref it answers that part's whole review contract,
/// without one the compact chip per placed part. Read-only.
pub fn mcpPartReview(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) std.mem.Allocator.Error!bool {
    const name = argStr(args_val, "name") orelse
        return toolError(out, alloc, "missing required arg: name");
    const ref = argStr(args_val, "ref");
    const target = try targetOf(alloc, name, ref);
    // The read-set is captured and dropped: the CLI answers one
    // process-lifetime request and has no store to retain the body in.
    var deps: ?page_cache.FileSet = null;
    defer if (deps) |d| d.deinit();
    const body = compose(alloc, project_dir, target, {}, &deps) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.PartNotFound => return toolErrorFmt(
            out,
            alloc,
            "design \"{s}\" places no part with ref \"{s}\"",
            .{ name, ref orelse "" },
        ),
        error.InvalidName, error.NotADesign, error.EvaluateFailed => return toolErrorFmt(
            out,
            alloc,
            "no design named \"{s}\"",
            .{name},
        ),
    };
    try out.appendSlice(alloc, body);
    return true;
}

// ── Tests ─────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Write a two-part fixture project: one active IC with a class, a cited
/// requirement per check kind and a thermal envelope, plus one passive inside a
/// sub-block so the qualified-ref path is exercised.
fn writeFixture(dir: std.Io.Dir) !void {
    try dir.createDirPath(std.testing.io, "lib/components");
    try dir.createDirPath(std.testing.io, "lib/pinouts");
    try dir.createDirPath(std.testing.io, "lib/modules");
    try dir.createDirPath(std.testing.io, "src");
    try dir.writeFile(std.testing.io, .{ .sub_path = "lib/components/tiny-ldo.sexp", .data =
        \\(component "tiny-ldo"
        \\  (description "test LDO with a cited datasheet contract")
        \\  (footprint "SOT-23-5")
        \\  (class ldo)
        \\  (thermal (theta-ja 60) (tj-max 125) (operating -40 85))
        \\  (requirement "VIN must sit between 2 and 20 V"
        \\    (ref "tiny-ldo.pdf" (page 5))
        \\    (check (voltage-range (pin "VIN") (min 2) (max 20))))
        \\  (requirement "EN must not float"
        \\    (ref "tiny-ldo.pdf" (page 9))
        \\    (check (pin-not-floating (pin "EN")))))
    });
    try dir.writeFile(std.testing.io, .{ .sub_path = "lib/pinouts/tiny-ldo.sexp", .data =
        \\(pinout "tiny-ldo"
        \\  (pin 1 "VIN")
        \\  (pin 2 "GND")
        \\  (pin 3 "EN"))
    });
    try dir.writeFile(std.testing.io, .{ .sub_path = "lib/components/cap-test.sexp", .data =
        \\(component "cap-test"
        \\  (description "test bypass capacitor")
        \\  (footprint "C0402"))
    });
    try dir.writeFile(std.testing.io, .{ .sub_path = "src/rig.sexp", .data =
        \\(import tiny-ldo)
        \\(import cap-test)
        \\
        \\(design-block "Part Review Rig"
        \\  (revision "A1")
        \\  (rail "V_5V" (nominal 5.0))
        \\  (instance "U1" tiny-ldo
        \\    (pin 1 "VIN" "V_5V" (i-typ 0.010) (i-max 0.050))
        \\    (pin 2 "GND" "GND")
        \\    (pin 3 "EN" "V_5V")
        \\    (power 0.15))
        \\  (instance "C1" cap-test
        \\    (pin 1 "V_5V")
        \\    (pin 2 "GND")))
    });
}

/// True when the profile evaluation reported an obligation under `code`.
fn hasCode(items: []const part_review.ProfileRow, code: []const u8) bool {
    for (items) |item| if (std.mem.eql(u8, item.code, code)) return true;
    return false;
}

/// Release a read-set a test's `compose` call stamped, whether or not it
/// produced one.
fn dropDeps(set: ?page_cache.FileSet) void {
    if (set) |s| s.deinit();
}

/// True when the fabrication gate reported `id` about this part.
fn hasRatingId(rows: []const part_review.RatingRow, id: []const u8) bool {
    for (rows) |row| if (std.mem.eql(u8, row.id, id)) return true;
    return false;
}

fn collectFixture(alloc: std.mem.Allocator, project: []const u8) !part_review.Board {
    return part_review.collect(alloc, project, "rig", .{});
}

// spec: part-review - the composer joins identity, requirements, ratings, power and thermal onto every placed part of a design
test "the composer reviews every placed part of a fixture design" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(tmp.dir);
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);

    const board = try collectFixture(alloc, project);
    try testing.expectEqual(@as(usize, 2), board.parts.len);

    const ldo = board.find("U1").?;
    try testing.expectEqualStrings("tiny-ldo", ldo.component);
    try testing.expectEqualStrings("ldo", ldo.class);
    try testing.expect(ldo.class_declared);
    try testing.expect(ldo.active);
    // Both cited requirements arrive, each with its page citation and status.
    try testing.expectEqual(@as(usize, 2), ldo.requirements.len);
    try testing.expectEqual(@as(u32, 5), ldo.requirements[0].citation.?.page);
    // The `voltage-range` rule is also lifted into the supply-window block.
    try testing.expectEqual(@as(usize, 1), ldo.supply_windows.len);
    try testing.expectEqualStrings("VIN", ldo.supply_windows[0].pin);
    try testing.expectEqual(@as(f64, 20), ldo.supply_windows[0].max_v);
    // No datasheet review was authored, so the block says so rather than staying silent.
    try testing.expectEqualStrings("missing", ldo.datasheet.status);
    try testing.expectEqual(part_review.Verdict.not_declared, ldo.datasheet.verdict);
    try testing.expect(!ldo.datasheet.record.present);
    // Annotated pin currents reach the power block with the rail they land on.
    try testing.expectEqual(@as(usize, 1), ldo.power.len);
    try testing.expectEqualStrings("V_5V", ldo.power[0].rail);
    try testing.expectEqual(@as(f64, 0.05), ldo.power[0].i_max.?);
    // The declared dissipation and theta reach the thermal row.
    try testing.expectEqualStrings("60.0", ldo.thermal.?.theta);
    try testing.expect(ldo.thermal.?.has_power);
    // The `ldo` profile wants a decoupling rule on every supply pin and this
    // part declares none, so the unmet obligation reaches the sheet by code.
    try testing.expect(ldo.profile_items.len > 0);
    try testing.expect(hasCode(ldo.profile_items, "supply-decoupling-check"));
    try testing.expect(ldo.counts.not_declared > 0);

    // The passive's name is parts-table shaped but no table backs it, so the
    // authored-spec screen reports it — the rating join, on a real finding.
    const cap = board.find("C1").?;
    try testing.expect(!cap.active);
    try testing.expect(hasRatingId(cap.ratings, "bom-spec-library-missing"));
    // …and the rail-aware rating screen judged its applied voltage, without a
    // layout ever being resolved.
    try testing.expect(hasRatingId(cap.ratings, "component-rating-missing"));
    try testing.expect(cap.counts.not_declared > 0);
}

fn serveChips(alloc: std.mem.Allocator, project: []const u8, name: []const u8) !struct { status: u16, body: []const u8 } {
    var state = serve_root.ServerState{};
    var srv = Server{ .allocator = alloc, .project_dir = project, .auth_dir = project, .state = &state };
    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.param("name", name);
    try chipsApi(&srv, ht.req, ht.res);
    return .{ .status = ht.res.status, .body = try alloc.dupe(u8, ht.res.body) };
}

fn servePart(
    alloc: std.mem.Allocator,
    project: []const u8,
    name: []const u8,
    ref: []const u8,
) !struct { status: u16, body: []const u8 } {
    var state = serve_root.ServerState{};
    var srv = Server{ .allocator = alloc, .project_dir = project, .auth_dir = project, .state = &state };
    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.param("name", name);
    ht.param("ref", ref);
    try partApi(&srv, ht.req, ht.res);
    return .{ .status = ht.res.status, .body = try alloc.dupe(u8, ht.res.body) };
}

// spec: Web Server - GET /api/part-review/:name answers one chip per placed part and /:ref answers that part's sheet or 404
test "the part-review endpoints answer chips, one sheet, and 404 an unknown ref" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(tmp.dir);
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);

    const chips = try serveChips(alloc, project, "rig");
    try testing.expectEqual(@as(u16, 200), chips.status);
    const chip_root = try std.json.parseFromSliceLeaky(std.json.Value, alloc, chips.body, .{});
    try testing.expectEqual(@as(usize, 2), chip_root.object.get("parts").?.array.items.len);

    const sheet = try servePart(alloc, project, "rig", "U1");
    try testing.expectEqual(@as(u16, 200), sheet.status);
    const sheet_root = try std.json.parseFromSliceLeaky(std.json.Value, alloc, sheet.body, .{});
    try testing.expectEqualStrings("U1", sheet_root.object.get("ref").?.string);
    try testing.expectEqualStrings("ldo", sheet_root.object.get("class").?.string);
    try testing.expectEqual(@as(usize, 1), sheet_root.object.get("supply_windows").?.array.items.len);

    const missing = try servePart(alloc, project, "rig", "U99");
    try testing.expectEqual(@as(u16, 404), missing.status);
    const no_design = try serveChips(alloc, project, "nope");
    try testing.expectEqual(@as(u16, 404), no_design.status);
}

// spec: part-review - part_review is a registered read-only CLI tool answering with the endpoint's own bytes
test "part_review is registered read-only and shares the endpoint body" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    try testing.expect(mcp_tools.isKnownTool("part_review"));
    try testing.expect(!mcp_tools.isMutationTool("part_review"));

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(tmp.dir);
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);

    var out: std.ArrayList(u8) = .empty;
    const args = try std.json.parseFromSliceLeaky(std.json.Value, alloc, "{\"name\":\"rig\",\"ref\":\"U1\"}", .{});
    try testing.expect(try mcpPartReview(alloc, project, args, &out));
    const sheet = try servePart(alloc, project, "rig", "U1");
    try testing.expectEqualStrings(sheet.body, out.items);

    var bad: std.ArrayList(u8) = .empty;
    const bad_args = try std.json.parseFromSliceLeaky(std.json.Value, alloc, "{\"name\":\"rig\",\"ref\":\"U99\"}", .{});
    try testing.expect(!try mcpPartReview(alloc, project, bad_args, &bad));
    try testing.expect(std.mem.indexOf(u8, bad.items, "places no part") != null);
}

// spec: part-review - the composer names the reason it could not review instead of answering an empty board
test "the composer names why it could not review" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(tmp.dir);
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);

    // A name with no source file cannot be evaluated…
    try testing.expectError(error.EvaluateFailed, part_review.collect(alloc, project, "nope", .{}));
    // …a name that escapes the project directory is refused before any read…
    try testing.expectError(error.InvalidName, part_review.collect(alloc, project, "../etc/passwd", .{}));
    // …a source file that declares no design-block is not a board…
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/bare.sexp", .data = "42" });
    try testing.expectError(error.NotADesign, part_review.collect(alloc, project, "bare", .{}));
    // …and a ref the design does not place is named as such, not as a 404 on
    // the design itself.
    var deps: ?page_cache.FileSet = null;
    defer dropDeps(deps);
    const target = try targetOf(alloc, "rig", "U99");
    try testing.expectError(error.PartNotFound, compose(alloc, project, target, {}, &deps));
}
