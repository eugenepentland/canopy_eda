//! Per-net on-demand route diagnosis on the surviving router surface — the
//! read-only twin of the retired Route Lab `analyze` endpoint. A caller names
//! ANY net; the handler runs the SAME plan-lowered diagnostic route the
//! `/pcb-layout` Route button runs (`route_plan.routePlannedDiagnostic`,
//! request-local, persists no copper) and answers for that one net:
//!
//!   - a net the router FAILED to complete → its full stuck diagnosis, tagged
//!     `"status":"failed"` and serialized through the shared `stuck_json` shape
//!     (byte-identical fields to the Route button's `routed.stuck[]` entries);
//!   - a net that ROUTED → `"status":"routed"` with the trace length, via count,
//!     and signal layers filtered out of the RouteResult for that net;
//!   - a name matching no net → 404 JSON.
//!
//! Unlike `routed.stuck[]` (only nets that failed a full-board route), this lets
//! an agent interrogate a net the board otherwise routed fine, or one buried
//! past the diagnostic cap.
//!
//! The same analysis is the `diagnose_net` CLI tool. Both surfaces run through
//! `analyzeNetJson` — one resolve-route-answer body, so the tool and the
//! endpoint can never diagnose different boards for the same request.

const std = @import("std");
const httpz = @import("httpz");
const serve_root = @import("../serve.zig");
const Server = serve_root.Server;
const optimizer = @import("../placement/optimizer.zig");
const router = @import("../placement/router.zig");
const route_diagnose = @import("../placement/route_diagnose.zig");
const plan_resolve = @import("../placement/plan_resolve.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const modules_mod = @import("modules.zig");
const pcb_layout_page = @import("pcb_layout_page.zig");
const route_plan = @import("route_plan.zig");
const route_review = @import("route_review.zig");
const stuck_json = @import("stuck_json.zig");

const HandlerError = route_review.HandlerError;
const jsonError = route_review.jsonError;

/// POST /api/pcb-route-analyze/:name — diagnose ONE named net (JSON body
/// `{"net":"NAME"}`). Read-only: it reads project files and the diagnostic
/// route persists nothing. Accepts the read-only PCB surfaces' `?layout=` /
/// `?sub=` selectors so it can probe the same board the page shows.
pub fn pcbRouteAnalyzeApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const arena = req.arena;
    const name = req.param("name") orelse return jsonError(arena, res, 404, "missing design name");
    const known = route_review.isListedDesign(arena, ctx.project_dir, name) orelse
        return jsonError(arena, res, 500, "could not list the project designs");
    if (!known) return jsonError(arena, res, 404, "no design by that name");

    const body = req.body() orelse return jsonError(arena, res, 400, "missing analyze request body");
    const want_net = parseNet(arena, body) orelse
        return jsonError(arena, res, 400, "analyze body must be a JSON object with a non-empty \"net\" string");

    // Follow ONLY the saved-layout / sub selectors — never ?regen/?rough — so
    // this probe diagnoses the board the /pcb-layout page shows, not a re-solve.
    const q = pcb_layout_page.pngRequestFromQuery(arena, req);

    const body_json = analyzeNetJson(arena, ctx.project_dir, name, want_net, .{
        .layout = q.layout,
        .sub = q.sub,
    }) catch |e| {
        // The two writer-side errors are the handler's own to propagate; every
        // other failure is a status + message for the caller.
        if (e == error.OutOfMemory) return error.OutOfMemory;
        if (e == error.WriteFailed) return error.WriteFailed;
        const failure = analyzeFailure(e);
        return jsonError(arena, res, failure.status, failure.msg);
    };
    res.content_type = .JSON;
    res.body = body_json;
}

/// The HTTP status + message one analyze failure deserves: this module's own two
/// errors spelled out, everything else deferred to `pngFailure` so a bad design
/// or sub-block name reads the same here as on every other PCB read surface.
fn analyzeFailure(e: AnalyzeError) pcb_layout_page.PngFail {
    return switch (e) {
        error.NetNotFound => .{
            .status = 404,
            .msg = "net is not present in this placement",
            .json = "{\"error\":\"net is not present in this placement\"}",
        },
        error.RouteFailed => .{
            .status = 500,
            .msg = "the diagnostic route failed",
            .json = "{\"error\":\"the diagnostic route failed\"}",
        },
        error.BlockNotFound => pcb_layout_page.pngFailure(error.BlockNotFound),
        error.SubNotFound => pcb_layout_page.pngFailure(error.SubNotFound),
        else => pcb_layout_page.pngFailure(error.BuildFailed),
    };
}

/// Which board the probe diagnoses. Deliberately only the saved-layout / sub
/// selectors: a `?regen`/`?rough` re-solve would answer about a board nobody has.
pub const AnalyzeOpts = struct {
    layout: ?[]const u8 = null,
    sub: ?[]const u8 = null,
};

/// Failures of one `analyzeNetJson` call. `NetNotFound` is the caller naming a
/// net this placement does not carry (404 / a CLI error line); `RouteFailed` is
/// the diagnostic route itself giving up. The rest are `solveForRequest`'s own.
pub const AnalyzeError = error{ NetNotFound, RouteFailed } ||
    pcb_layout_page.PngError || std.mem.Allocator.Error || std.Io.Writer.Error;

/// Resolve `name`'s shown board, run the plan-lowered diagnostic route over it,
/// and return `net`'s analysis object as JSON bytes owned by `alloc`.
///
/// This is the WHOLE body both surfaces share — the HTTP endpoint above and the
/// `diagnose_net` CLI tool below — so neither can drift into diagnosing a
/// different board than the other for the same design/layout/net.
pub fn analyzeNetJson(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    want_net: []const u8,
    opts: AnalyzeOpts,
) AnalyzeError![]const u8 {
    var eval = Evaluator.init(alloc, project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        alloc.destroy(mr.eval);
    };
    const solved = try pcb_layout_page.solveForRequest(alloc, project_dir, name, .{
        .layout = opts.layout,
        .sub = opts.sub,
    }, &eval, &module_res);

    // The SAME plan-lowered diagnostic route the Route button pays for once —
    // its RouteResult decides routed-vs-failed and its captured stuck set
    // supplies the failed net's diagnosis.
    const route_params = solved.placement.rules.design.routeParams();
    var route_options = route_plan.lowerOrEmpty(alloc, solved.block, solved.placement);
    route_options.existing_zones = solved.shown_zones.sources;
    const seeded = pcb_layout_page.diagnoseWithSubcircuitSeeds(
        alloc,
        project_dir,
        solved.block,
        solved.placement,
        route_params,
        route_options,
    ) catch return error.RouteFailed;
    const diag = seeded.diagnostic;

    var aw: std.Io.Writer.Allocating = .init(alloc);
    if (!try writeAnalysis(&aw.writer, solved.placement, diag, want_net)) return error.NetNotFound;
    return aw.written();
}

/// `diagnose_net` — the CLI twin of `POST /api/pcb-route-analyze/:name`. Args
/// `name` (design or module) + `net`, with the read tools' `layout` / `sub`
/// board selectors. Read-only: it persists no copper and touches no sidecar.
///
/// It exists because the whole-board answers cannot cover one net on demand:
/// `route_experiment`'s `stuck[]` is capped and only ever describes nets that
/// FAILED, so a net the board routed — or one buried past the cap — had no
/// answer short of re-routing the board and re-reading everything.
pub fn mcpDiagnoseNet(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) std.mem.Allocator.Error!bool {
    const name = argStr(args_val, "name") orelse return toolError(out, alloc, "missing required arg: name");
    const net = argStr(args_val, "net") orelse return toolError(out, alloc, "missing required arg: net");
    const body_json = analyzeNetJson(alloc, project_dir, name, net, .{
        .layout = argStr(args_val, "layout"),
        .sub = argStr(args_val, "sub"),
    }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NetNotFound => return toolErrorFmt(out, alloc, "no net named \"{s}\" on this board", .{net}),
        else => return toolErrorFmt(out, alloc, "could not diagnose the net: {s}", .{@errorName(e)}),
    };
    try out.appendSlice(alloc, body_json);
    return true;
}

/// `args.key` as a non-empty string (absent / non-object / non-string ⇒ null).
fn argStr(args_val: ?std.json.Value, key: []const u8) ?[]const u8 {
    const av = args_val orelse return null;
    if (av != .object) return null;
    const v = av.object.get(key) orelse return null;
    return if (v == .string and v.string.len > 0) v.string else null;
}

/// Write an `{"error":<msg>}` envelope and return false — the CLI layer flags
/// the result `isError`. One error spelling for this tool.
fn toolError(out: *std.ArrayList(u8), alloc: std.mem.Allocator, msg: []const u8) std.mem.Allocator.Error!bool {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    aw.writer.writeAll("{\"error\":") catch return error.OutOfMemory;
    pcb_layout_page.writeJsonStr(&aw.writer, msg) catch return error.OutOfMemory;
    aw.writer.writeAll("}") catch return error.OutOfMemory;
    try out.appendSlice(alloc, aw.written());
    return false;
}

/// `toolError` with a formatted message.
fn toolErrorFmt(
    out: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    comptime fmt: []const u8,
    args: anytype,
) std.mem.Allocator.Error!bool {
    const msg = std.fmt.allocPrint(alloc, fmt, args) catch "error";
    return toolError(out, alloc, msg);
}

/// Resolve `want_net` against the placement and write its analysis object.
/// Returns false (writing nothing) when no net matches — the handler maps that
/// to a 404. Pure over its inputs: no disk, no httpz, so it is unit-testable
/// without constructing a project placement.
pub fn writeAnalysis(
    w: *std.Io.Writer,
    placement: optimizer.Placement,
    diag: route_plan.PlannedDiagnostic,
    want_net: []const u8,
) std.Io.Writer.Error!bool {
    const net_i = plan_resolve.netIndexByName(placement, want_net) orelse return false;
    const net_name = placement.nets[net_i].name;
    if (netFailed(diag.result.failed, net_name)) {
        try stuck_json.writeFailedNet(w, diagnosisFor(diag.stuck, net_name) orelse fallbackDiagnosis(net_name));
    } else {
        try writeRoutedNet(w, placement, diag.result, net_i);
    }
    return true;
}

/// The routed-net answer: `"status":"routed"` plus the trace length (mm), via
/// count, and the signal layers the net's copper touches — all filtered out of
/// the shared RouteResult by net index.
fn writeRoutedNet(
    w: *std.Io.Writer,
    placement: optimizer.Placement,
    result: router.RouteResult,
    net_i: usize,
) std.Io.Writer.Error!void {
    const net: i32 = @intCast(net_i);
    const layer_count = placement.rules.signalLayerCount();
    var used: [64]bool = @splat(false);
    var trace_mm: f64 = 0;
    for (result.tracks) |t| {
        if (t.net != net) continue;
        trace_mm += std.math.hypot(t.x2 - t.x1, t.y2 - t.y1);
        if (t.layer < used.len) used[t.layer] = true;
    }
    var vias: usize = 0;
    for (result.vias) |v| {
        if (v.net == net) vias += 1;
    }
    try w.writeAll(stuck_json.net_key);
    try pcb_layout_page.writeJsonStr(w, placement.nets[net_i].name);
    try w.print(",\"status\":\"routed\",\"trace_mm\":{d:.3},\"vias\":{d},\"layers\":[", .{ trace_mm, vias });
    var buf: [12]u8 = undefined;
    var first = true;
    var li: u8 = 0;
    while (li < layer_count and li < used.len) : (li += 1) {
        if (!used[li]) continue;
        if (!first) try w.writeAll(",");
        first = false;
        try pcb_layout_page.writeJsonStr(w, placement.rules.signalLayerName(li, &buf));
    }
    try w.writeAll("]}");
}

/// True when `net_name` is in the router's residual failed set.
fn netFailed(failed: []const []const u8, net_name: []const u8) bool {
    for (failed) |f| {
        if (std.mem.eql(u8, f, net_name)) return true;
    }
    return false;
}

/// The captured diagnosis for `net_name`, or null when the failed net fell past
/// the diagnostic cap.
fn diagnosisFor(stuck: []const route_diagnose.Diagnosis, net_name: []const u8) ?route_diagnose.Diagnosis {
    for (stuck) |d| {
        if (std.mem.eql(u8, d.net, net_name)) return d;
    }
    return null;
}

/// A minimal diagnosis for a net that failed but whose per-net analysis was not
/// captured (more failed nets than the diagnostic cap) — so the answer still
/// reads `"status":"failed"` rather than being misreported as routed.
fn fallbackDiagnosis(net_name: []const u8) route_diagnose.Diagnosis {
    return .{
        .net = net_name,
        .failure_mode = "unknown",
        .why = "the net did not route; no per-net diagnosis was captured within the board's diagnostic cap",
        .blockers = &.{},
        .remedies = &.{},
        .drc_related = &.{},
    };
}

/// Extract a non-empty `"net"` string from the request body, or null when the
/// body is not a JSON object with such a field.
fn parseNet(arena: std.mem.Allocator, body: []const u8) ?[]const u8 {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return null;
    if (root != .object) return null;
    const value = root.object.get("net") orelse return null;
    if (value != .string or value.string.len == 0) return null;
    return value.string;
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;
const mcp_tools = @import("mcp_tools.zig");

// spec: serve/route-analyze - diagnose_net is a registered read-only CLI tool
test "diagnose_net is registered read-only" {
    try testing.expect(mcp_tools.isKnownTool("diagnose_net"));
    try testing.expect(!mcp_tools.isMutationTool("diagnose_net"));
}

// spec: serve/route-analyze - diagnose_net names the argument a caller left out instead of diagnosing nothing
test "diagnose_net rejects a call missing name or net" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var no_args: std.ArrayList(u8) = .empty;
    try testing.expect(!try mcpDiagnoseNet(arena, "", null, &no_args));
    try testing.expect(std.mem.indexOf(u8, no_args.items, "missing required arg: name") != null);

    // `name` alone is not enough — the tool answers about ONE net, so the net
    // has to be named rather than defaulted to something.
    const args = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"name\":\"tiny\"}", .{});
    var no_net: std.ArrayList(u8) = .empty;
    try testing.expect(!try mcpDiagnoseNet(arena, "", args, &no_net));
    try testing.expect(std.mem.indexOf(u8, no_net.items, "missing required arg: net") != null);

    // An empty string is "absent" too, not a net named "".
    const blank = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"name\":\"tiny\",\"net\":\"\"}", .{});
    var empty_net: std.ArrayList(u8) = .empty;
    try testing.expect(!try mcpDiagnoseNet(arena, "", blank, &empty_net));
    try testing.expect(std.mem.indexOf(u8, empty_net.items, "missing required arg: net") != null);
}

// spec: serve/route-analyze - an unresolvable design reaches diagnose_net's caller as an error line, never as a partial answer
test "diagnose_net reports an unknown design as a tool error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const proj = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);

    const args = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        "{\"name\":\"ghost\",\"net\":\"GND\"}",
        .{},
    );
    var out: std.ArrayList(u8) = .empty;
    try testing.expect(!try mcpDiagnoseNet(arena, proj, args, &out));
    try testing.expect(std.mem.indexOf(u8, out.items, "BlockNotFound") != null);
}

// spec: serve/route-analyze - the analyze failure mapping keeps the shared PCB read status codes and adds this module's own two
test "analyzeFailure maps each failure to its status" {
    try testing.expectEqual(@as(u16, 404), analyzeFailure(error.NetNotFound).status);
    try testing.expectEqual(@as(u16, 500), analyzeFailure(error.RouteFailed).status);
    // Deferred to the shared PCB mapping, so a bad name reads the same here.
    try testing.expectEqual(@as(u16, 404), analyzeFailure(error.BlockNotFound).status);
    try testing.expectEqual(@as(u16, 404), analyzeFailure(error.SubNotFound).status);
    try testing.expectEqual(pcb_layout_page.pngFailure(error.BuildFailed).status, analyzeFailure(error.BuildFailed).status);
}

/// A placement carrying only the fields the analysis reads (nets + default
/// legacy 2-layer rules); everything else stays empty.
fn fixturePlacement(nets: []const optimizer.FlatNet) optimizer.Placement {
    return .{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 1,
        .maxy = 1,
        .generated = true,
    };
}

// spec: serve/route-analyze - a failed net is answered with its stuck diagnosis tagged status failed
test "a failed net answers with a status-failed diagnosis" {
    const nets = [_]optimizer.FlatNet{.{ .name = "SPI_SCK", .pins = &.{} }};
    const blockers = [_]route_diagnose.Blocker{
        .{ .net = "GND", .layer = "F.Cu", .x = 1, .y = -2, .share = 0.5, .rippable = true },
    };
    const stuck = [_]route_diagnose.Diagnosis{.{
        .net = "SPI_SCK",
        .failure_mode = "order_congestion",
        .why = "the frontier is ringed by rippable copper",
        .blockers = &blockers,
        .remedies = &.{},
        .drc_related = &.{},
    }};
    const diag = route_plan.PlannedDiagnostic{
        .result = .{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 1, .failed = &.{"SPI_SCK"} },
        .stuck = &stuck,
    };
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    // A lowercase query name also proves the case-insensitive net lookup.
    const found = try writeAnalysis(&aw.writer, fixturePlacement(&nets), diag, "spi_sck");
    const out = aw.written();
    try testing.expect(found);
    try testing.expect(std.mem.startsWith(u8, out, "{\"net\":\"SPI_SCK\""));
    try testing.expect(std.mem.indexOf(u8, out, "\"status\":\"failed\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"failure_mode\":\"order_congestion\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"net\":\"GND\",\"layer\":\"F.Cu\"") != null);
}

// spec: serve/route-analyze - a routed net is answered with status routed and its trace length via count and layers
test "a routed net answers with routed facts" {
    const nets = [_]optimizer.FlatNet{
        .{ .name = "GND", .pins = &.{} },
        .{ .name = "pwr/VOUT", .pins = &.{} },
    };
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 3, .y2 = 0, .layer = 0, .width = 0.2, .net = 1 },
        .{ .x1 = 3, .y1 = 0, .x2 = 3, .y2 = 4, .layer = 1, .width = 0.2, .net = 1 },
        .{ .x1 = 0, .y1 = 0, .x2 = 9, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
    };
    const vias = [_]router.Via{.{ .x = 3, .y = 0, .dia = 0.4, .drill = 0.2, .net = 1 }};
    const diag = route_plan.PlannedDiagnostic{
        .result = .{ .tracks = &tracks, .vias = &vias, .routed = 2, .total = 2 },
        .stuck = &.{},
    };
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    // "VOUT" is the bare leaf of "pwr/VOUT" — exercises the leaf match too.
    const found = try writeAnalysis(&aw.writer, fixturePlacement(&nets), diag, "VOUT");
    const out = aw.written();
    try testing.expect(found);
    try testing.expect(std.mem.startsWith(u8, out, "{\"net\":\"pwr/VOUT\""));
    try testing.expect(std.mem.indexOf(u8, out, "\"status\":\"routed\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"trace_mm\":7.000") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"vias\":1") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"layers\":[\"F.Cu\",\"B.Cu\"]") != null);
}

// spec: serve/route-analyze - an unknown net name yields no answer so the endpoint replies not found
test "an unknown net name yields no answer" {
    const nets = [_]optimizer.FlatNet{.{ .name = "GND", .pins = &.{} }};
    const diag = route_plan.PlannedDiagnostic{
        .result = .{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 0 },
        .stuck = &.{},
    };
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const found = try writeAnalysis(&aw.writer, fixturePlacement(&nets), diag, "NOPE");
    try testing.expect(!found);
    try testing.expectEqual(@as(usize, 0), aw.written().len);
}

// spec: serve/route-analyze - a failed net past the diagnostic cap still answers status failed
test "a failed net without a captured diagnosis still answers failed" {
    const nets = [_]optimizer.FlatNet{.{ .name = "DDR_DQ7", .pins = &.{} }};
    const diag = route_plan.PlannedDiagnostic{
        .result = .{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 1, .failed = &.{"DDR_DQ7"} },
        .stuck = &.{},
    };
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const found = try writeAnalysis(&aw.writer, fixturePlacement(&nets), diag, "DDR_DQ7");
    const out = aw.written();
    try testing.expect(found);
    try testing.expect(std.mem.startsWith(u8, out, "{\"net\":\"DDR_DQ7\""));
    try testing.expect(std.mem.indexOf(u8, out, "\"status\":\"failed\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"failure_mode\":\"unknown\"") != null);
}
