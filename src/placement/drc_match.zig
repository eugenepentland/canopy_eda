//! `(net-class … (match-group …))` post-route measurement + its one WARNING,
//! factored out of `drc.zig` (at its guardian file-size cap) and shaped exactly
//! like its two-net sibling `drc_diffpair.zig`.
//!
//! This is the router-facing half of length matching: it converts `router`'s
//! tracks and vias into the plain geometry `match_group.zig` measures, and turns
//! the result into either a `length_mismatch` violation (for DRC) or a `Report`
//! (for the facts endpoint). Both surfaces call `measure`, so the number a
//! warning quotes and the number `/api/pcb-describe` prints are the same
//! number by construction rather than by agreement.
//!
//! `length_mismatch` is a WARNING for the reason `drc_keepout` and `diff_skew`
//! are: the copper is legal and the board builds — what is at risk is a timing
//! margin the author declared, which is a judgement, not a fab rule.
//!
//! A group needs at least TWO ROUTED members before anything is reported. A
//! half-routed board is unfinished, not mismatched, and reporting an unrouted
//! member as length zero would flag every board mid-route.

const std = @import("std");
const optimizer = @import("optimizer.zig");
const router = @import("router.zig");
const drc = @import("drc.zig");
const match_group = @import("match_group.zig");
const net_copper = @import("net_copper.zig");

/// The routed copper the measure reads. Vias are needed as well as tracks: a
/// net's electrical path crosses layers only through a barrel, so a track-only
/// view cannot tell joined copper from stacked copper — and the barrel is itself
/// part of the length here (see `match_group.viaLengthMm`).
pub const Copper = net_copper.Copper;

/// Measure every declared `(match-group …)` on this placement. Empty — and free
/// — when the design declares none, which is every board in the corpus today.
pub fn measure(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    copper: Copper,
) std.mem.Allocator.Error![]const match_group.Report {
    if (placement.match_groups.len == 0) return &.{};
    const via_len = match_group.viaLengthMm(placement.rules.physical.board_thickness);
    var out: std.ArrayList(match_group.Report) = .empty;
    for (placement.match_groups) |g| {
        var members: std.ArrayList(match_group.Member) = .empty;
        for (g.members) |net_i| try members.append(arena, try measureNet(arena, copper, net_i, via_len));
        try out.append(arena, match_group.summarize(g, try members.toOwnedSlice(arena)));
    }
    return out.toOwnedSlice(arena);
}

/// Measure one member: its effective routed length (vias charged) and its via
/// count. Copper that does not join the net's own extremes reports `routed =
/// false` — there is no single length to quote for two islands, and the segment
/// sum would over-report every one of them.
fn measureNet(
    arena: std.mem.Allocator,
    copper: Copper,
    net_i: usize,
    via_len: f64,
) std.mem.Allocator.Error!match_group.Member {
    const own = try net_copper.collect(arena, copper, @intCast(net_i));
    const len = try match_group.netLengthMm(arena, own.segs, own.vias, via_len);
    return .{
        .net_i = net_i,
        .length_mm = len orelse 0,
        .vias = own.vias.len,
        .routed = len != null,
    };
}

/// Append a `length_mismatch` warning for every group whose routed members
/// spread wider than its tolerance. A no-op when the design declares no group,
/// so the DRC output is byte-identical for every board without one.
pub fn check(
    arena: std.mem.Allocator,
    out: *std.ArrayList(drc.Violation),
    placement: optimizer.Placement,
    copper: Copper,
) std.mem.Allocator.Error!void {
    for (try measure(arena, placement, copper)) |rep| {
        if (rep.withinTolerance()) continue;
        const ends = rep.extremes orelse continue;
        const at = anySegMid(copper.tracks, @intCast(ends.longest));
        try out.append(arena, .{
            .x = at[0],
            .y = at[1],
            .gap = rep.span.spread_mm,
            .clearance = rep.group.tolerance_mm,
            .kind = .length_mismatch,
            .severity = drc.defaultSeverity(.length_mismatch),
            // The two nets bracketing the spread, so the report names who is
            // long and who is short instead of quoting a bare millimetre count.
            .who = .{ .net_a = @intCast(ends.longest), .net_b = @intCast(ends.shortest) },
        });
    }
}

/// Midpoint of the first track on net `ni` — where the marker lands. The caller
/// only reaches here for a net `measure` found copper on, so a segment exists;
/// the origin fallback is unreachable belt-and-braces.
fn anySegMid(tracks: []const router.Track, ni: i32) [2]f64 {
    for (tracks) |t| {
        if (t.net == ni) return .{ (t.x1 + t.x2) / 2, (t.y1 + t.y2) / 2 };
    }
    return .{ 0, 0 };
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// A straight track on `net` running `len` mm to the right at height `y`.
fn straight(net: i32, y: f64, len: f64) router.Track {
    return .{ .x1 = 0, .y1 = y, .x2 = len, .y2 = y, .layer = 0, .width = 0.127, .net = net };
}

/// A three-net placement carrying the caller's `groups`. The groups are passed
/// in rather than built here on purpose: a group array built from a runtime
/// tolerance would live in THIS frame, and the returned `Placement` would point
/// at it after the frame died.
fn grouped(groups: []const match_group.Group) optimizer.Placement {
    const nets = &[_]optimizer.FlatNet{
        .{ .name = "A0", .pins = &.{} },
        .{ .name = "A1", .pins = &.{} },
        .{ .name = "A2", .pins = &.{} },
    };
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
        .maxx = 0,
        .maxy = 0,
        .generated = false,
        .match_groups = groups,
    };
}

// spec: placement/drc - a match group spreading wider than its tolerance warns once, naming the longest and shortest nets
test "length_mismatch fires on an over-budget group and is quiet inside budget" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // 20 / 23 / 21 mm legs: a 3 mm spread against a 0.5 mm budget.
    const tracks = [_]router.Track{ straight(0, 0, 20), straight(1, 1, 23), straight(2, 2, 21) };
    const tight = [_]match_group.Group{.{ .name = "addr", .tolerance_mm = 0.5, .members = &.{ 0, 1, 2 } }};
    const loose = [_]match_group.Group{.{ .name = "addr", .tolerance_mm = 4.0, .members = &.{ 0, 1, 2 } }};
    var out: std.ArrayList(drc.Violation) = .empty;
    try check(arena, &out, grouped(&tight), .{ .tracks = &tracks, .vias = &.{} });
    try testing.expectEqual(@as(usize, 1), out.items.len);
    const v = out.items[0];
    try testing.expectEqual(drc.Kind.length_mismatch, v.kind);
    try testing.expectEqual(drc.Severity.warn, v.severity); // never fab-blocking
    try testing.expectApproxEqAbs(@as(f64, 3), v.gap, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.5), v.clearance, 1e-9);
    try testing.expectEqual(@as(i32, 1), v.who.net_a); // longest
    try testing.expectEqual(@as(i32, 0), v.who.net_b); // shortest
    try testing.expectApproxEqAbs(@as(f64, 1), v.y, 1e-9); // marker on the long net

    // The same copper against a budget that accommodates it says nothing.
    out.clearRetainingCapacity();
    try check(arena, &out, grouped(&loose), .{ .tracks = &tracks, .vias = &.{} });
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

// spec: placement/drc - a match group with fewer than two routed members is reported as unfinished, never as mismatched
test "length_mismatch stays silent while a group is still being routed" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Only net 0 has copper. Nets 1 and 2 would read as length 0 — a 20 mm
    // "spread" — if unrouted members counted.
    const tracks = [_]router.Track{straight(0, 0, 20)};
    var out: std.ArrayList(drc.Violation) = .empty;
    const groups = [_]match_group.Group{.{ .name = "addr", .tolerance_mm = 0.5, .members = &.{ 0, 1, 2 } }};
    const p = grouped(&groups);
    try check(arena, &out, p, .{ .tracks = &tracks, .vias = &.{} });
    try testing.expectEqual(@as(usize, 0), out.items.len);

    const reps = try measure(arena, p, .{ .tracks = &tracks, .vias = &.{} });
    try testing.expectEqual(@as(usize, 1), reps.len);
    try testing.expectEqual(@as(usize, 1), reps[0].routed_members);
    try testing.expect(!reps[0].comparable());
    try testing.expect(!reps[0].members[1].routed);
}

// spec: placement/drc - a design declaring no match group produces no measurement and no violation
test "match-group measurement is empty on a board that declares none" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const groups = [_]match_group.Group{.{ .name = "addr", .tolerance_mm = 0.5, .members = &.{ 0, 1, 2 } }};
    var p = grouped(&groups);
    p.match_groups = &.{};
    const tracks = [_]router.Track{ straight(0, 0, 20), straight(1, 1, 90) };
    try testing.expectEqual(@as(usize, 0), (try measure(arena, p, .{ .tracks = &tracks, .vias = &.{} })).len);
    var out: std.ArrayList(drc.Violation) = .empty;
    try check(arena, &out, p, .{ .tracks = &tracks, .vias = &.{} });
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

// spec: placement/drc - two match-group members with equal trace length but different layer hops measure apart
test "measured length includes the via barrels a member crosses" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Net 0: 20 mm flat on layer 0. Net 1: 10 mm + barrel + 10 mm — the SAME
    // 20 mm of trace, so a 2D measure calls them matched. Net 2 matches net 0.
    const tracks = [_]router.Track{
        straight(0, 0, 20),
        .{ .x1 = 0, .y1 = 1, .x2 = 10, .y2 = 1, .layer = 0, .width = 0.127, .net = 1 },
        .{ .x1 = 10, .y1 = 1, .x2 = 20, .y2 = 1, .layer = 1, .width = 0.127, .net = 1 },
        straight(2, 2, 20),
    };
    const vias = [_]router.Via{.{ .x = 10, .y = 1, .dia = 0.4, .net = 1, .drill = 0.2 }};
    const groups = [_]match_group.Group{.{ .name = "addr", .tolerance_mm = 0.5, .members = &.{ 0, 1, 2 } }};
    const reps = try measure(arena, grouped(&groups), .{ .tracks = &tracks, .vias = &vias });
    try testing.expectEqual(@as(usize, 1), reps.len);
    try testing.expectEqual(@as(usize, 3), reps[0].routed_members);
    try testing.expectEqual(@as(usize, 1), reps[0].members[1].vias);
    // The barrel is a full (undeclared → fab-standard) board thickness of path.
    try testing.expectApproxEqAbs(20 + match_group.default_board_thickness_mm, reps[0].members[1].length_mm, 1e-9);
    try testing.expectApproxEqAbs(match_group.default_board_thickness_mm, reps[0].span.spread_mm, 1e-9);
    try testing.expect(!reps[0].withinTolerance()); // a 2D measure would have passed this
}
