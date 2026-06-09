//! GET /api/pcb-describe/:name — structured spatial facts about the solved
//! placement, the textual twin of `/api/pcb-png`. An agent reads relations
//! ("C_BOOT1 sits on U1's top edge, its power pad 1.46 mm from the BOOT1
//! pad") far more reliably than it estimates them from pixels, so the two
//! endpoints are meant to be consumed together: same placement-selection
//! logic (`solveForRequest`), same parameter set (`pngRequestFromQuery`) —
//! the facts always describe the board the image shows.
//!
//! Facts emitted: board bbox + axes convention, objective summary, anchor
//! (largest hub), per-part side-of-anchor / gap / nets / spec coverage,
//! per-decoupling-loop power-leg length + inductance + net, each hub's
//! net→package-edge pad map, and (with `?route=1`) the routed-copper summary.

const std = @import("std");
const httpz = @import("httpz");
const optimizer = @import("../placement/optimizer.zig");
const router = @import("../placement/router.zig");
const drc = @import("../placement/drc.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const modules_mod = @import("modules.zig");
const pcb_layout_page = @import("pcb_layout_page.zig");
const render_pcb_png = @import("../render_pcb_png.zig");
const serve_root = @import("../serve.zig");
const Handler = serve_root.Handler;

/// Which side of the anchor (or of a loop's hub) something sits on, in board
/// coordinates: x grows right, y grows DOWN, so `top` means smaller y. The
/// same words the `(placement …)` spec uses.
pub const Side = enum { left, right, top, bottom, center };

/// GET /api/pcb-describe/:name — accepts the same query parameters as
/// /api/pcb-png (layout=, regen=, sub=, placement=off, route=1, tuning knobs)
/// so the facts match whichever board variant the caller is looking at.
pub fn pcbDescribeApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) pcb_layout_page.HandlerError!void {
    const arena = req.arena;
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    const opts = pcb_layout_page.pngRequestFromQuery(arena, req);
    const body = describeDesign(arena, ctx.project_dir, name, opts) catch |e| {
        res.status = if (e == error.BlockNotFound or e == error.SubNotFound) 404 else 500;
        res.body = "{\"error\":\"describe failed\"}";
        return;
    };
    res.content_type = .JSON;
    res.body = body;
}

/// Solve (or load) the placement exactly as the PNG endpoint would and return
/// the facts JSON. Bytes are owned by `alloc` (callers pass an arena).
pub fn describeDesign(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    opts: pcb_layout_page.PngRequest,
) pcb_layout_page.PngError![]u8 {
    var eval = Evaluator.init(alloc, project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        alloc.destroy(mr.eval);
    };
    const solved = try pcb_layout_page.solveForRequest(alloc, project_dir, name, opts, &eval, &module_res);

    const route_params = router.RouteParams{};
    const routed: ?RoutedSummary = if (opts.route) blk: {
        const r = router.route(alloc, solved.placement, route_params) catch break :blk null;
        const v = drc.check(alloc, solved.placement, r, route_params.clearance) catch &.{};
        var trace: f64 = 0;
        for (r.tracks) |t| trace += std.math.hypot(t.x2 - t.x1, t.y2 - t.y1);
        break :blk .{ .trace_mm = trace, .tracks = r.tracks.len, .vias = r.vias.len, .drc = v.len };
    } else null;

    var aw: std.Io.Writer.Allocating = .init(alloc);
    writeDescribeJson(&aw.writer, alloc, solved.placement, solved.spec_status, routed, name, solved.title) catch
        return error.BuildFailed;
    return aw.written();
}

const RoutedSummary = struct { trace_mm: f64, tracks: usize, vias: usize, drc: usize };

/// Errors the facts writer can hit: allocation (scratch maps/lists) + writer.
pub const DescribeError = std.mem.Allocator.Error || std.Io.Writer.Error;

/// `"origin"` JSON key — the stable module-local name, emitted beside every ref.
const ORIGIN_KEY = ",\"origin\":";

/// Emit the full facts document. Split from `describeDesign` so tests can run
/// it on a hand-built `Placement` without a project on disk.
pub fn writeDescribeJson(
    w: *std.Io.Writer,
    alloc: std.mem.Allocator,
    p: optimizer.Placement,
    spec: ?render_pcb_png.SpecStatus,
    routed: ?RoutedSummary,
    name: []const u8,
    title: []const u8,
) DescribeError!void {
    // ref|pad → net name, the same resolution the PNG renderer uses.
    var pad_net = std.StringHashMap([]const u8).init(alloc);
    defer pad_net.deinit();
    for (p.nets) |net| {
        for (net.pins) |pin| {
            const key = try std.fmt.allocPrint(alloc, "{s}|{s}", .{ pin.ref_des, pin.pin });
            try pad_net.put(key, net.name);
        }
    }
    var unplaced = std.StringHashMap(void).init(alloc);
    defer unplaced.deinit();
    var auto_filled = std.StringHashMap(void).init(alloc);
    defer auto_filled.deinit();
    if (spec) |sp| {
        for (sp.unplaced) |ref| try unplaced.put(ref, {});
        for (sp.auto_filled) |ref| try auto_filled.put(ref, {});
    }

    const anchor = anchorIndex(p.parts);

    try w.writeAll("{\"name\":");
    try pcb_layout_page.writeJsonStr(w, name);
    try w.writeAll(",\"title\":");
    try pcb_layout_page.writeJsonStr(w, title);
    // Spell the coordinate convention out so an agent never misreads "top".
    try w.writeAll(",\"axes\":\"x grows right, y grows down; side/edge words match the (placement ...) spec: top = toward -y\"");
    if (anchor) |ai| {
        try w.writeAll(",\"anchor\":{\"ref\":");
        try pcb_layout_page.writeJsonStr(w, p.parts[ai].ref_des);
        try w.writeAll(ORIGIN_KEY);
        try pcb_layout_page.writeJsonStr(w, originOf(p, ai));
        try w.writeAll("}");
    }
    try w.print(",\"board\":{{\"w_mm\":{d:.2},\"h_mm\":{d:.2}}}", .{ p.maxx - p.minx, p.maxy - p.miny });
    const b = p.breakdown;
    try w.print(",\"score\":{{\"objective\":{d:.1},\"hpwl\":{d:.1},\"loop_nh\":{d:.1}}}", .{ b.objective, b.hpwl, b.loop_nh });
    if (spec) |sp| {
        try w.print(",\"placement\":{{\"source\":\"{s}\",\"unplaced\":[", .{if (sp.used_spec) "spec" else "force"});
        for (sp.unplaced, 0..) |ref, i| {
            if (i > 0) try w.writeAll(",");
            try pcb_layout_page.writeJsonStr(w, ref);
        }
        try w.writeAll("],\"auto_filled\":[");
        for (sp.auto_filled, 0..) |ref, i| {
            if (i > 0) try w.writeAll(",");
            try pcb_layout_page.writeJsonStr(w, ref);
        }
        try w.writeAll("]}");
    }

    try w.writeAll(",\"parts\":[");
    for (p.parts, 0..) |part, pi| {
        if (pi > 0) try w.writeAll(",");
        try w.writeAll("{\"ref\":");
        try pcb_layout_page.writeJsonStr(w, part.ref_des);
        try w.writeAll(ORIGIN_KEY);
        try pcb_layout_page.writeJsonStr(w, originOf(p, pi));
        try w.print(",\"kind\":\"{s}\",\"x\":{d:.2},\"y\":{d:.2},\"rot\":{d:.0},\"w_mm\":{d:.2},\"h_mm\":{d:.2}", .{
            if (part.kind == .hub) "hub" else "passive",
            part.x,
            part.y,
            part.rot,
            part.hw * 2,
            part.hh * 2,
        });
        if (anchor) |ai| {
            if (pi == ai) {
                try w.writeAll(",\"side\":\"anchor\"");
            } else {
                const a = p.parts[ai];
                try w.print(",\"side\":\"{s}\",\"gap_mm\":{d:.2}", .{
                    @tagName(sideOf(part.x - a.x, part.y - a.y, aabbHalf(a), aabbHalf(part))),
                    rectGap(a, part),
                });
            }
        }
        if (unplaced.contains(part.ref_des)) try w.writeAll(",\"unplaced\":true");
        if (auto_filled.contains(part.ref_des)) try w.writeAll(",\"auto_filled\":true");
        try writePartNets(w, alloc, &pad_net, part);
        try w.writeAll("}");
    }
    try w.writeAll("]");

    try w.writeAll(",\"loops\":[");
    for (p.loops, 0..) |L, i| {
        if (i > 0) try w.writeAll(",");
        const cap = p.parts[L.cap];
        const hub = p.parts[L.hub];
        const cw = world(cap, L.cap_pwr.x, L.cap_pwr.y);
        const hw_ = world(hub, L.hub_pwr_pin.x, L.hub_pwr_pin.y);
        try w.writeAll("{\"cap\":");
        try pcb_layout_page.writeJsonStr(w, cap.ref_des);
        try w.writeAll(ORIGIN_KEY);
        try pcb_layout_page.writeJsonStr(w, originOf(p, L.cap));
        try w.writeAll(",\"hub\":");
        try pcb_layout_page.writeJsonStr(w, hub.ref_des);
        if (netAtLocal(&pad_net, cap, L.cap_pwr.x, L.cap_pwr.y)) |net| {
            try w.writeAll(",\"net\":");
            try pcb_layout_page.writeJsonStr(w, net);
        }
        try w.print(",\"leg_mm\":{d:.2},\"nh\":{d:.2},\"side\":\"{s}\"}}", .{
            std.math.hypot(cw[0] - hw_[0], cw[1] - hw_[1]),
            optimizer.loopNh(p.parts, L),
            @tagName(sideOf(cap.x - hub.x, cap.y - hub.y, aabbHalf(hub), aabbHalf(cap))),
        });
    }
    try w.writeAll("]");

    try writeHubPads(w, alloc, p, &pad_net);

    if (routed) |r| {
        try w.print(",\"routed\":{{\"trace_mm\":{d:.1},\"tracks\":{d},\"vias\":{d},\"drc\":{d}}}", .{ r.trace_mm, r.tracks, r.vias, r.drc });
    }
    try w.writeAll("}");
}

/// The unique nets on `part`'s pads, in pad order — `"nets":["VIN","GND"]`.
fn writePartNets(w: *std.Io.Writer, alloc: std.mem.Allocator, pad_net: *std.StringHashMap([]const u8), part: optimizer.Part) !void {
    var seen: std.ArrayListUnmanaged([]const u8) = .empty;
    defer seen.deinit(alloc);
    try w.writeAll(",\"nets\":[");
    for (part.pads) |pad| {
        const net = netOf(pad_net, part.ref_des, pad.number) orelse continue;
        var dup = false;
        for (seen.items) |s| {
            if (std.mem.eql(u8, s, net)) {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        if (seen.items.len > 0) try w.writeAll(",");
        try pcb_layout_page.writeJsonStr(w, net);
        try seen.append(alloc, net);
    }
    try w.writeAll("]");
}

/// Each hub's net → package-edge map: which edge(s) of the IC a net's pads sit
/// on, and how many. This is what lets an agent reason "the VIN pads are on the
/// left edge, so the input bank belongs left" without reading the footprint.
fn writeHubPads(w: *std.Io.Writer, alloc: std.mem.Allocator, p: optimizer.Placement, pad_net: *std.StringHashMap([]const u8)) !void {
    try w.writeAll(",\"hub_pads\":[");
    var first_hub = true;
    for (p.parts, 0..) |part, pi| {
        if (part.kind != .hub) continue;
        if (!first_hub) try w.writeAll(",");
        first_hub = false;
        try w.writeAll("{\"ref\":");
        try pcb_layout_page.writeJsonStr(w, part.ref_des);
        try w.writeAll(ORIGIN_KEY);
        try pcb_layout_page.writeJsonStr(w, originOf(p, pi));
        try w.writeAll(",\"nets\":[");

        // Aggregate per net (ordered by first appearance): edge set + pad count.
        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        defer names.deinit(alloc);
        var edges: std.ArrayListUnmanaged([5]bool) = .empty;
        defer edges.deinit(alloc);
        var counts: std.ArrayListUnmanaged(usize) = .empty;
        defer counts.deinit(alloc);
        for (part.pads) |pad| {
            const net = netOf(pad_net, part.ref_des, pad.number) orelse continue;
            var idx: ?usize = null;
            for (names.items, 0..) |s, i| {
                if (std.mem.eql(u8, s, net)) {
                    idx = i;
                    break;
                }
            }
            if (idx == null) {
                try names.append(alloc, net);
                try edges.append(alloc, .{ false, false, false, false, false });
                try counts.append(alloc, 0);
                idx = names.items.len - 1;
            }
            const e = padEdge(part, pad.x, pad.y);
            edges.items[idx.?][@intFromEnum(e)] = true;
            counts.items[idx.?] += 1;
        }
        for (names.items, 0..) |net, i| {
            if (i > 0) try w.writeAll(",");
            try w.writeAll("{\"net\":");
            try pcb_layout_page.writeJsonStr(w, net);
            try w.writeAll(",\"edges\":[");
            var first_edge = true;
            for (edges.items[i], 0..) |on, ei| {
                if (!on) continue;
                if (!first_edge) try w.writeAll(",");
                first_edge = false;
                try w.print("\"{s}\"", .{@tagName(@as(Side, @enumFromInt(ei)))});
            }
            try w.print("],\"pads\":{d}}}", .{counts.items[i]});
        }
        try w.writeAll("]}");
    }
    try w.writeAll("]");
}

// ── Geometry helpers (pure; unit-tested below) ──────────────────────────────

/// World offset of a footprint-local point on `part` (rotation applied).
fn world(part: optimizer.Part, lx: f64, ly: f64) [2]f64 {
    const a = part.rot * std.math.pi / 180.0;
    const c = @cos(a);
    const s = @sin(a);
    return .{ part.x + lx * c - ly * s, part.y + lx * s + ly * c };
}

/// World-axis-aligned half-extents of `part`'s rotated courtyard (AABB).
pub fn aabbHalf(part: optimizer.Part) [2]f64 {
    const a = part.rot * std.math.pi / 180.0;
    const c = @abs(@cos(a));
    const s = @abs(@sin(a));
    return .{ part.hw * c + part.hh * s, part.hw * s + part.hh * c };
}

/// Which side of a reference box a point offset (dx,dy) falls on, normalized
/// by the combined half-extents so a wide flat board doesn't read everything
/// as left/right. `center` only when well inside the combined box.
pub fn sideOf(dx: f64, dy: f64, a_half: [2]f64, b_half: [2]f64) Side {
    const nx = dx / @max(a_half[0] + b_half[0], 0.001);
    const ny = dy / @max(a_half[1] + b_half[1], 0.001);
    if (@max(@abs(nx), @abs(ny)) < 0.45) return .center;
    if (@abs(nx) >= @abs(ny)) return if (nx < 0) .left else .right;
    return if (ny < 0) .top else .bottom;
}

/// Edge of `part`'s package a footprint-local pad sits on (world-rotated, so
/// the answer matches what the image shows).
fn padEdge(part: optimizer.Part, px: f64, py: f64) Side {
    const wp = world(part, px, py);
    const half = aabbHalf(part);
    return sideOf(wp[0] - part.x, wp[1] - part.y, .{ 0, 0 }, half);
}

/// Clearance between two parts' world AABBs in mm; 0 = touching/overlapping.
fn rectGap(a: optimizer.Part, b: optimizer.Part) f64 {
    const ah = aabbHalf(a);
    const bh = aabbHalf(b);
    const gx = @max(0.0, @abs(b.x - a.x) - (ah[0] + bh[0]));
    const gy = @max(0.0, @abs(b.y - a.y) - (ah[1] + bh[1]));
    return std.math.hypot(gx, gy);
}

/// Index of the anchor part facts are oriented around: the largest hub by
/// courtyard area (the IC the live-regen view pins), else null.
pub fn anchorIndex(parts: []const optimizer.Part) ?usize {
    var best: ?usize = null;
    var best_area: f64 = 0;
    for (parts, 0..) |part, i| {
        if (part.kind != .hub) continue;
        const area = part.hw * part.hh;
        if (area > best_area) {
            best_area = area;
            best = i;
        }
    }
    return best;
}

/// The part's stable module-local origin name (what a `(placement …)` spec
/// calls it), falling back to the ref-des when none was recorded.
pub fn originOf(p: optimizer.Placement, pi: usize) []const u8 {
    if (pi < p.instances.len and p.instances[pi].origin_key.len > 0) return p.instances[pi].origin_key;
    return p.parts[pi].ref_des;
}

fn netOf(pad_net: *std.StringHashMap([]const u8), ref: []const u8, pad: []const u8) ?[]const u8 {
    var buf: [128]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "{s}|{s}", .{ ref, pad }) catch return null;
    return pad_net.get(key);
}

/// Net on the pad of `part` nearest the footprint-local point (lx,ly) — loops
/// carry pad rectangles, not pad numbers, so recover the net by proximity.
fn netAtLocal(pad_net: *std.StringHashMap([]const u8), part: optimizer.Part, lx: f64, ly: f64) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_d: f64 = std.math.floatMax(f64);
    for (part.pads) |pad| {
        const dx = pad.x - lx;
        const dy = pad.y - ly;
        const d = dx * dx + dy * dy;
        if (d < best_d) {
            best_d = d;
            best = pad.number;
        }
    }
    const number = best orelse return null;
    return netOf(pad_net, part.ref_des, number);
}

// ── Tests ───────────────────────────────────────────────────────────────────

test "sideOf classifies quadrants with top = -y" {
    const half = [2]f64{ 1, 1 };
    try std.testing.expectEqual(Side.left, sideOf(-3, 0.2, half, half));
    try std.testing.expectEqual(Side.right, sideOf(3, -0.2, half, half));
    try std.testing.expectEqual(Side.top, sideOf(0.2, -3, half, half));
    try std.testing.expectEqual(Side.bottom, sideOf(-0.2, 3, half, half));
    try std.testing.expectEqual(Side.center, sideOf(0.1, 0.1, half, half));
}

test "aabbHalf swaps extents at quarter rotation and rectGap touches at zero" {
    const part = optimizer.Part{ .ref_des = "C1", .kind = .passive, .hw = 2, .hh = 1, .pads = &.{}, .fallback = false, .rot = 90 };
    const half = aabbHalf(part);
    try std.testing.expectApproxEqAbs(@as(f64, 1), half[0], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 2), half[1], 1e-9);
    const a = optimizer.Part{ .ref_des = "A", .kind = .hub, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false, .x = 0, .y = 0 };
    const b = optimizer.Part{ .ref_des = "B", .kind = .passive, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false, .x = 2, .y = 0 };
    try std.testing.expectApproxEqAbs(@as(f64, 0), rectGap(a, b), 1e-9);
    const c = optimizer.Part{ .ref_des = "C", .kind = .passive, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false, .x = 2.5, .y = 0 };
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), rectGap(a, c), 1e-9);
}

test "writeDescribeJson emits parts with sides, nets and hub pad map" {
    const export_kicad = @import("../export_kicad.zig");
    const geometry = @import("../placement/geometry.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var hub_pads = [_]geometry.Pad{
        .{ .number = "1", .x = -1.8, .y = 0, .w = 0.6, .h = 0.6 },
        .{ .number = "2", .x = 1.8, .y = 0, .w = 0.6, .h = 0.6 },
    };
    var cap_pads = [_]geometry.Pad{
        .{ .number = "1", .x = -0.5, .y = 0, .w = 0.5, .h = 0.5 },
        .{ .number = "2", .x = 0.5, .y = 0, .w = 0.5, .h = 0.5 },
    };
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &hub_pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "C9", .kind = .passive, .hw = 1, .hh = 0.6, .pads = &cap_pads, .fallback = false, .x = -4, .y = 0 },
    };
    const instances = [_]export_kicad.FlatInstance{
        .{ .ref_des = "U1", .component = "ic", .value = "", .footprint = "", .properties = &.{}, .uuid = "", .origin_key = "U1" },
        .{ .ref_des = "C9", .component = "cap", .value = "1uF", .footprint = "", .properties = &.{}, .uuid = "", .origin_key = "C_IN" },
    };
    const vin_pins = [_]export_kicad.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C9", .pin = "1" } };
    const gnd_pins = [_]export_kicad.FlatPin{ .{ .ref_des = "U1", .pin = "2" }, .{ .ref_des = "C9", .pin = "2" } };
    const nets = [_]export_kicad.FlatNet{
        .{ .name = "VIN", .pins = &vin_pins },
        .{ .name = "GND", .pins = &gnd_pins },
    };
    const p = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &instances,
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -6,
        .miny = -2,
        .maxx = 2,
        .maxy = 2,
        .generated = true,
    };
    var aw: std.Io.Writer.Allocating = .init(alloc);
    try writeDescribeJson(&aw.writer, alloc, p, .{ .used_spec = true, .unplaced = &.{} }, null, "t", "Test");
    const out = aw.written();
    // The cap is left of the anchor IC, on VIN+GND, and the hub's VIN pad
    // resolves to the left package edge.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"ref\":\"C9\",\"origin\":\"C_IN\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"side\":\"left\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"nets\":[\"VIN\",\"GND\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"net\":\"VIN\",\"edges\":[\"left\"],\"pads\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"source\":\"spec\"") != null);
}
