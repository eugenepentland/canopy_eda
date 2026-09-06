//! `GET /api/review-card/:name[?layout=]` — the Board Review Card as read-only
//! JSON, and the `review_card` CLI tool that answers with the same bytes.
//!
//! The composition lives in `review_card.zig`; this module is only the
//! resolve-and-answer seam, the pattern `serve/part_review_api.zig` uses. Both
//! surfaces run through one body, so an agent reading the tool, a reviewer
//! reading the page and the committed audit Markdown can never be told
//! different verdicts about the same board.
//!
//! `?layout=` reviews one NAMED saved layout instead of the starred one: two
//! layouts of one design are two different boards to the DRC, the ladder and
//! the fabrication gate, so they are two different cards. The parameter is
//! keyed into the cache rather than bypassing it.
//!
//! Read-only: nothing here writes to the project dir.

const std = @import("std");
const httpz = @import("httpz");
const json_writer = @import("../json_writer.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const page_cache = @import("page_cache.zig");
const page_cache_endpoint = @import("page_cache_endpoint.zig");
const review_card = @import("../review_card.zig");
const serve_root = @import("../serve.zig");
const mcp_tools = @import("mcp_tools.zig");
const urlcodec = @import("urlcodec.zig");
const Server = serve_root.Server;

/// Error set for the handler. Only allocation escapes to httpz; every other
/// failure is answered as a status plus a JSON error body.
pub const HandlerError = std.mem.Allocator.Error;

const http_not_found: u16 = 404;

const err_not_found = "No design by that name\n";

/// Everything one composition can fail with.
pub const CardError = review_card.CollectError;

/// The query knobs the endpoint takes: which saved layout to review.
const Request = struct {
    layout: ?[]const u8 = null,
};

fn requestFromQuery(_: std.mem.Allocator, req: *httpz.Request) Request {
    const query = req.query() catch return .{};
    const layout = query.get("layout") orelse return .{};
    return .{ .layout = if (layout.len == 0) null else layout };
}

/// Compose the card and serialize it. This is the WHOLE body both surfaces
/// share. `deps` receives the file dependency set of the evaluation so the
/// answer can be retained against it; the capture happens while the evaluator
/// is alive and before any early return, so a cache never keys on a half-built
/// read-set.
fn compose(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    opts: Request,
    deps: *?page_cache.FileSet,
) CardError![]const u8 {
    var eval = Evaluator.init(alloc, project_dir);
    defer eval.deinit();
    defer {
        deps.* = page_cache.capture(alloc, &eval, project_dir, name) catch null;
    }
    const card = try review_card.collectWith(alloc, &eval, project_dir, name, .{ .layout = opts.layout });
    var aw: std.Io.Writer.Allocating = .init(alloc);
    review_card.writeCardJson(&aw.writer, card) catch return error.OutOfMemory;
    return aw.written();
}

/// How a failed composition reaches the wire.
//
// twin-drift-ok: `serve/part_review_api.zig` classifies the SAME error set for
// its own surface and has one case this one cannot have — a ref the design does
// not place — so the two switches answer different questions with different
// sentences. What they share is the four words httpz needs, not a rule.
fn failure(e: CardError) struct { status: u16, msg: []const u8, json: []const u8 } {
    return switch (e) {
        error.InvalidName, error.NotADesign, error.EvaluateFailed => .{
            .status = http_not_found,
            .msg = "no design by that name",
            .json = "{\"error\":\"no design by that name\"}",
        },
        else => .{
            .status = 500,
            .msg = "review card failed",
            .json = "{\"error\":\"review card failed\"}",
        },
    };
}

/// The design's live-edit generation, so a card retires on the edits its
/// board's other read surfaces retire on.
fn versionOf(name: []const u8) u32 {
    return serve_root.getLiveVersion(name);
}

/// The route answers through the one dependency-cached GET shape: try the
/// store, compose on a miss, frame the JSON, retain against the read-set.
const card_endpoint = page_cache_endpoint.Endpoint(.{
    .compute = compose,
    .request_opts = requestFromQuery,
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

/// `GET /api/review-card/:name` — one board's whole unit review. Unknown
/// design → 404.
pub fn cardApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const raw = req.param("name") orelse return plainError(res, http_not_found, err_not_found);
    const name = try urlcodec.decodeAlloc(req.arena, raw);
    card_endpoint.answer(&ctx.state.caches.reads.review_card, ctx.project_dir, name, req, res);
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

/// `review_card` — the CLI twin of the endpoint. Args `name` (a design) and an
/// optional `layout`. Read-only, and byte-identical to what the endpoint
/// returns for the same request.
pub fn mcpReviewCard(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) std.mem.Allocator.Error!bool {
    const name = argStr(args_val, "name") orelse
        return toolError(out, alloc, "missing required arg: name");
    // The read-set is captured and dropped: the CLI answers one
    // process-lifetime request and has no store to retain the body in.
    var deps: ?page_cache.FileSet = null;
    defer if (deps) |d| d.deinit();
    const body = compose(alloc, project_dir, name, .{ .layout = argStr(args_val, "layout") }, &deps) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidName, error.NotADesign, error.EvaluateFailed => {
            const msg = try std.fmt.allocPrint(alloc, "no design named \"{s}\"", .{name});
            return toolError(out, alloc, msg);
        },
    };
    try out.appendSlice(alloc, body);
    return true;
}

// ── Tests ─────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Write the smallest project that still exercises every card surface: one
/// active IC with a cited requirement, one rail, one passive.
fn writeFixture(dir: std.Io.Dir) !void {
    try dir.createDirPath(std.testing.io, "lib/components");
    try dir.createDirPath(std.testing.io, "lib/pinouts");
    try dir.createDirPath(std.testing.io, "src");
    try dir.writeFile(std.testing.io, .{ .sub_path = "lib/components/card-ldo.sexp", .data =
        \\(component "card-ldo"
        \\  (description "test LDO for the review card")
        \\  (footprint "SOT-23-5")
        \\  (class ldo)
        \\  (requirement "VIN must sit between 2 and 20 V"
        \\    (ref "card-ldo.pdf" (page 5))
        \\    (check (voltage-range (pin "VIN") (min 2) (max 20)))))
    });
    try dir.writeFile(std.testing.io, .{ .sub_path = "lib/pinouts/card-ldo.sexp", .data =
        \\(pinout "card-ldo"
        \\  (pin 1 "VIN")
        \\  (pin 2 "GND")
        \\  (pin 3 "EN"))
    });
    try dir.writeFile(std.testing.io, .{ .sub_path = "lib/components/card-cap.sexp", .data =
        \\(component "card-cap"
        \\  (description "test bypass capacitor")
        \\  (footprint "C0402"))
    });
    try dir.writeFile(std.testing.io, .{ .sub_path = "src/rig.sexp", .data =
        \\(import card-ldo)
        \\(import card-cap)
        \\
        \\(design-block "Review Card Rig"
        \\  (revision "A1")
        \\  (rail "V_5V" (nominal 5.0))
        \\  (instance "U1" card-ldo
        \\    (pin 1 "VIN" "V_5V" (i-typ 0.010))
        \\    (pin 2 "GND" "GND")
        \\    (pin 3 "EN" "V_5V"))
        \\  (instance "C1" card-cap
        \\    (pin 1 "V_5V")
        \\    (pin 2 "GND")))
    });
}

/// The card stamps the moment it was composed, so two compositions differ
/// there and nowhere else. Blank the stamp so a comparison is about the review.
fn withoutStamp(alloc: std.mem.Allocator, body: []const u8) ![]const u8 {
    const key = "\"generated_at\":\"";
    const at = std.mem.indexOf(u8, body, key) orelse return body;
    const start = at + key.len;
    const end = std.mem.indexOfScalarPos(u8, body, start, '"') orelse return body;
    return std.mem.concat(alloc, u8, &.{ body[0..start], body[end..] });
}

fn serveCard(alloc: std.mem.Allocator, project: []const u8, name: []const u8) !struct { status: u16, body: []const u8 } {
    var state = serve_root.ServerState{};
    var srv = Server{ .allocator = alloc, .project_dir = project, .auth_dir = project, .state = &state };
    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.param("name", name);
    try cardApi(&srv, ht.req, ht.res);
    return .{ .status = ht.res.status, .body = try alloc.dupe(u8, ht.res.body) };
}

// spec: Web Server - GET /api/review-card/:name answers the composed Board Review Card and 404s an unknown design
test "the review-card endpoint answers the card and 404s an unknown design" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(tmp.dir);
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);

    const answer = try serveCard(alloc, project, "rig");
    try testing.expectEqual(@as(u16, 200), answer.status);
    const root = try std.json.parseFromSliceLeaky(std.json.Value, alloc, answer.body, .{});
    try testing.expectEqualStrings("rig", root.object.get("design").?.string);
    try testing.expectEqual(@as(usize, 12), root.object.get("categories").?.array.items.len);
    try testing.expect(root.object.get("overall").?.object.get("stripe").?.object.get("total").?.integer > 0);

    const missing = try serveCard(alloc, project, "nope");
    try testing.expectEqual(@as(u16, 404), missing.status);
}

// spec: review-card - review_card is a registered read-only CLI tool answering with the endpoint's own bytes
test "review_card is registered read-only and shares the endpoint body" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    try testing.expect(mcp_tools.isKnownTool("review_card"));
    try testing.expect(!mcp_tools.isMutationTool("review_card"));

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(tmp.dir);
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);

    var out: std.ArrayList(u8) = .empty;
    const args = try std.json.parseFromSliceLeaky(std.json.Value, alloc, "{\"name\":\"rig\"}", .{});
    try testing.expect(try mcpReviewCard(alloc, project, args, &out));
    const answer = try serveCard(alloc, project, "rig");
    try testing.expectEqualStrings(try withoutStamp(alloc, answer.body), try withoutStamp(alloc, out.items));

    var bad: std.ArrayList(u8) = .empty;
    const bad_args = try std.json.parseFromSliceLeaky(std.json.Value, alloc, "{\"name\":\"nope\"}", .{});
    try testing.expect(!try mcpReviewCard(alloc, project, bad_args, &bad));
    try testing.expect(std.mem.indexOf(u8, bad.items, "no design named") != null);
}
