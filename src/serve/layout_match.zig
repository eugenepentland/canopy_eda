//! Compare a `?rough=1` auto-seed against the design's *starred* layout — the
//! saved layout marked `"default"` in the `.layouts.json` sidecar, which the
//! user blesses (★) as their hand-finished reference. The goal of the rough
//! seed is NOT to match the score; it's to put each part in the same GENERAL
//! AREA as the hand layout so the board is easy to finish by dragging.
//!
//! Bypass caps of the same value on the same rail are INTERCHANGEABLE — the
//! hand doesn't care which physical 100 nF sits on the left edge, only that one
//! does. So the metric is per-class, per-edge COUNT agreement, not a per-part
//! distance: for each interchangeable class (kind + value + footprint + net
//! set) we tally how many parts the rough and the starred layout each put on
//! every IC edge, and credit `min(rough, starred)` per edge. This is
//! order-independent (greedy nearest matching was not — it gave different
//! numbers depending on iteration order) and tolerant of the looseness the user
//! wants: a cap in the right region, spaced out, still counts; only the wrong
//! *edge* (or wrong *proportion* across edges) costs.
//!
//! `area_match_pct` = credited parts / total — "is the rough in the right
//! general area". The per-class `rough`/`starred` edge tallies show exactly
//! which subsystem the rough scattered differently.

const std = @import("std");
const httpz = @import("httpz");
const optimizer = @import("../placement/optimizer.zig");
const pcb_describe = @import("pcb_describe.zig");
const pcb_layout_page = @import("pcb_layout_page.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const modules_mod = @import("modules.zig");
const Handler = @import("../serve.zig").Handler;
const Side = pcb_describe.Side;

/// `Side` has 5 variants (left, right, top, bottom, center); index a per-edge
/// tally by `@intFromEnum`.
const N_SIDES = @typeInfo(Side).@"enum".fields.len;

/// Per-edge tally for one interchangeable class: how many parts the rough seed
/// and the starred layout each placed on each IC edge, and how many edges agree.
pub const ClassDist = struct {
    class: []const u8,
    /// Total parts of this class (rough count = starred count for one design).
    n: usize = 0,
    rough: [N_SIDES]usize = [_]usize{0} ** N_SIDES,
    starred: [N_SIDES]usize = [_]usize{0} ** N_SIDES,
    /// Sum over edges of `min(rough, starred)` — parts the rough put where the
    /// starred layout also wanted a same-class part.
    matched: usize = 0,
};

/// The verdict: how hand-like the rough seed is vs the starred layout.
pub const MatchResult = struct {
    n: usize,
    /// Fraction (0–100) of parts in the same general area (per-class, per-edge
    /// count agreement) — the headline "right area" signal.
    area_match_pct: f64,
    classes: []ClassDist,
};

/// One analyzed part: its IC edge and interchangeable-class key. Split out so the
/// matcher is unit-testable on hand-built infos without a whole `Placement`.
pub const PInfo = struct {
    side: Side,
    class: []const u8,
};

/// Build a part's interchangeable-class key: kind + value + footprint half-size
/// (0.1 mm buckets) + the sorted set of nets it touches. Two parts with the same
/// key serve the same role and are fungible when matching positions.
fn classKey(alloc: std.mem.Allocator, p: optimizer.Placement, idx: usize) std.mem.Allocator.Error![]const u8 {
    const part = p.parts[idx];
    var nets: std.ArrayListUnmanaged([]const u8) = .empty;
    defer nets.deinit(alloc);
    for (p.nets) |net| {
        for (net.pins) |pin| {
            if (std.mem.eql(u8, pin.ref_des, part.ref_des)) {
                try nets.append(alloc, net.name);
                break;
            }
        }
    }
    std.mem.sort([]const u8, nets.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    var joined: std.ArrayListUnmanaged(u8) = .empty;
    defer joined.deinit(alloc);
    for (nets.items) |n| {
        try joined.appendSlice(alloc, n);
        try joined.append(alloc, ',');
    }
    return std.fmt.allocPrint(alloc, "{s}|{s}|{d:.1}x{d:.1}|{s}", .{ @tagName(part.kind), part.value, part.hw, part.hh, joined.items });
}

/// Analyze every non-anchor part of `p` into a `PInfo` (edge + class). Returns an
/// empty slice if the placement has no anchor hub.
pub fn analyze(alloc: std.mem.Allocator, p: optimizer.Placement) std.mem.Allocator.Error![]PInfo {
    const ai = pcb_describe.anchorIndex(p.parts) orelse return &.{};
    const anchor = p.parts[ai];
    const a_half = pcb_describe.aabbHalf(anchor);
    var out: std.ArrayListUnmanaged(PInfo) = .empty;
    for (p.parts, 0..) |part, i| {
        if (i == ai) continue;
        const side = pcb_describe.sideOf(part.x - anchor.x, part.y - anchor.y, a_half, pcb_describe.aabbHalf(part));
        try out.append(alloc, .{ .side = side, .class = try classKey(alloc, p, i) });
    }
    return out.toOwnedSlice(alloc);
}

/// Tally rough + starred parts per interchangeable class per edge, credit
/// `min(rough, starred)` per edge, and report `area_match_pct = credited/total`.
/// Order-independent (no per-part pairing).
pub fn matchInfos(alloc: std.mem.Allocator, rough: []const PInfo, starred: []const PInfo) std.mem.Allocator.Error!MatchResult {
    var map = std.StringHashMap(ClassDist).init(alloc);
    defer map.deinit();
    for (rough) |r| {
        const gop = try map.getOrPut(r.class);
        if (!gop.found_existing) gop.value_ptr.* = .{ .class = r.class };
        gop.value_ptr.rough[@intFromEnum(r.side)] += 1;
    }
    for (starred) |s| {
        const gop = try map.getOrPut(s.class);
        if (!gop.found_existing) gop.value_ptr.* = .{ .class = s.class };
        gop.value_ptr.starred[@intFromEnum(s.side)] += 1;
    }
    var classes: std.ArrayListUnmanaged(ClassDist) = .empty;
    var total: usize = 0;
    var matched_total: usize = 0;
    var it = map.iterator();
    while (it.next()) |e| {
        var cd = e.value_ptr.*;
        var m: usize = 0;
        var n: usize = 0;
        for (0..N_SIDES) |k| {
            m += @min(cd.rough[k], cd.starred[k]);
            n += cd.rough[k];
        }
        cd.matched = m;
        cd.n = n;
        matched_total += m;
        total += n;
        try classes.append(alloc, cd);
    }
    return .{
        .n = total,
        .area_match_pct = if (total > 0) 100.0 * @as(f64, @floatFromInt(matched_total)) / @as(f64, @floatFromInt(total)) else 0,
        .classes = try classes.toOwnedSlice(alloc),
    };
}

/// Convenience: analyze both placements and match. `rough` is the `?rough=1`
/// seed; `starred` the blessed reference.
pub fn compare(alloc: std.mem.Allocator, rough: optimizer.Placement, starred: optimizer.Placement) std.mem.Allocator.Error!MatchResult {
    return matchInfos(alloc, try analyze(alloc, rough), try analyze(alloc, starred));
}

/// Build the `/api/layout-match/:name` JSON: score the `?rough=1` seed against
/// the starred (default) saved layout. `{name, starred, n, area_match_pct,
/// classes[]}`, or `{name, starred:null, message}` when nothing is starred yet.
/// Bytes owned by `alloc` (pass an arena).
pub fn layoutMatchJson(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8) pcb_layout_page.PngError![]u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;

    // The starred reference = the saved layout flagged "default" (the ★ a user
    // sets in /pcb-layout to bless their hand-finished layout).
    const layouts = pcb_layout_page.readLayouts(alloc, project_dir, name);
    var starred_name: ?[]const u8 = null;
    for (layouts) |L| {
        if (L.default) {
            starred_name = L.name;
            break;
        }
    }
    if (starred_name == null) {
        w.writeAll("{\"name\":") catch return error.BuildFailed;
        pcb_layout_page.writeJsonStr(w, name) catch return error.BuildFailed;
        w.writeAll(",\"starred\":null,\"message\":\"No starred layout — hand-arrange in /pcb-layout, Save, then Set default (★) to bless it as the reference, and re-run.\"}") catch return error.BuildFailed;
        return aw.written();
    }

    // Solve the rough seed and the starred layout independently — each its own
    // evaluator so block state can't bleed between the two solves.
    var eval1 = Evaluator.init(alloc, project_dir);
    defer eval1.deinit();
    var mr1: ?modules_mod.ResolvedBlock = null;
    defer if (mr1) |m| {
        m.eval.deinit();
        alloc.destroy(m.eval);
    };
    const rough = try pcb_layout_page.solveForRequest(alloc, project_dir, name, .{ .rough = true }, &eval1, &mr1);

    var eval2 = Evaluator.init(alloc, project_dir);
    defer eval2.deinit();
    var mr2: ?modules_mod.ResolvedBlock = null;
    defer if (mr2) |m| {
        m.eval.deinit();
        alloc.destroy(m.eval);
    };
    const star = try pcb_layout_page.solveForRequest(alloc, project_dir, name, .{ .layout = starred_name.? }, &eval2, &mr2);

    const res = compare(alloc, rough.placement, star.placement) catch return error.BuildFailed;

    w.writeAll("{\"name\":") catch return error.BuildFailed;
    pcb_layout_page.writeJsonStr(w, name) catch return error.BuildFailed;
    w.writeAll(",\"starred\":") catch return error.BuildFailed;
    pcb_layout_page.writeJsonStr(w, starred_name.?) catch return error.BuildFailed;
    w.print(",\"n\":{d},\"area_match_pct\":{d:.1},\"classes\":[", .{ res.n, res.area_match_pct }) catch return error.BuildFailed;
    for (res.classes, 0..) |cd, i| {
        if (i > 0) w.writeAll(",") catch return error.BuildFailed;
        w.writeAll("{\"class\":") catch return error.BuildFailed;
        pcb_layout_page.writeJsonStr(w, cd.class) catch return error.BuildFailed;
        w.print(",\"n\":{d},\"matched\":{d},\"rough\":{{", .{ cd.n, cd.matched }) catch return error.BuildFailed;
        try writeSideTally(w, cd.rough);
        w.writeAll("},\"starred\":{") catch return error.BuildFailed;
        try writeSideTally(w, cd.starred);
        w.writeAll("}}") catch return error.BuildFailed;
    }
    w.writeAll("]}") catch return error.BuildFailed;
    return aw.written();
}

/// Emit a `"left":n,"right":n,…` edge tally object body (no braces).
fn writeSideTally(w: *std.Io.Writer, counts: [N_SIDES]usize) pcb_layout_page.PngError!void {
    inline for (@typeInfo(Side).@"enum".fields, 0..) |f, k| {
        if (k > 0) w.writeAll(",") catch return error.BuildFailed;
        w.print("\"{s}\":{d}", .{ f.name, counts[k] }) catch return error.BuildFailed;
    }
}

/// GET /api/layout-match/:name — the rough-vs-starred area-match scoreboard.
pub fn layoutMatchApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) pcb_layout_page.HandlerError!void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    const body = layoutMatchJson(req.arena, ctx.project_dir, name) catch |e| {
        res.status = if (e == error.BlockNotFound or e == error.SubNotFound) 404 else 500;
        res.body = "{\"error\":\"layout-match failed\"}";
        return;
    };
    res.content_type = .JSON;
    res.body = body;
}

// ── Tests ──────────────────────────────────────────────────────────────

// spec: Web Server - layout-match credits interchangeable parts by per-edge count, ignoring which fungible part is where
test "matchInfos credits interchangeable parts by per-edge count" {
    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    const arena = astate.allocator();
    // Class C: starred puts one on left, one on right. Rough puts one on each too
    // (names irrelevant). Per-edge counts agree exactly → 100% area-match.
    const rough = [_]PInfo{ .{ .side = .right, .class = "C" }, .{ .side = .left, .class = "C" } };
    const starred = [_]PInfo{ .{ .side = .left, .class = "C" }, .{ .side = .right, .class = "C" } };
    const res = try matchInfos(arena, &rough, &starred);
    try std.testing.expectEqual(@as(usize, 2), res.n);
    try std.testing.expectApproxEqAbs(@as(f64, 100), res.area_match_pct, 1e-9);
}

// spec: Web Server - layout-match counts a wrong-edge proportion as a partial area mismatch
test "matchInfos scores a class spread differently than the starred layout" {
    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    const arena = astate.allocator();
    // Class C: starred = {left:2}. Rough = {left:1, right:1}. Only 1 of 2 lands
    // where the hand wanted a C (left) → 50% area-match.
    const rough = [_]PInfo{ .{ .side = .left, .class = "C" }, .{ .side = .right, .class = "C" } };
    const starred = [_]PInfo{ .{ .side = .left, .class = "C" }, .{ .side = .left, .class = "C" } };
    const res = try matchInfos(arena, &rough, &starred);
    try std.testing.expectEqual(@as(usize, 2), res.n);
    try std.testing.expectApproxEqAbs(@as(f64, 50), res.area_match_pct, 1e-9);
    try std.testing.expectEqual(@as(usize, 1), res.classes[0].matched);
}
