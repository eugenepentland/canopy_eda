//! The transactional safety layer of `clean_route_topology` — the plan
//! application and the gate that decides whether a deletion candidate may
//! land. It lives at the root tier, beside `fab_readiness`, because it is
//! pure decision logic over placement's data: the serve layer hands it
//! violation lists and tallies and persists only what the gate accepts.
//!
//! The topology's jointly-safe deletion plan is ADVISORY and the gate is the
//! authority: on real hand-edited boards the copper-topology contact graph
//! credits connections the fabricated-copper raster (`net_open`) does not, so
//! "deletion-invariant" sections can open their net when removed. The gate
//! catches that through the fab-readiness tally, `newlyOpenNets` /
//! `bypassRegressedNets` attribute the damage to exact nets, and the caller
//! retries the plan without them.

const std = @import("std");
const drc = @import("placement/drc.zig");
const fab_readiness = @import("fab_readiness.zig");
const optimizer = @import("placement/optimizer.zig");
const router = @import("placement/router.zig");

/// Remove deletion-invariant trace sections and non-ground vias from persisted
/// copper without rerouting it. The shared topology gate supplies a jointly
/// safe deletion plan; the edit is persisted only when error DRC and routed-net
/// connectivity do not regress.
fn netSelected(selected: []const bool, net: i32) bool {
    if (net < 0) return false;
    if (selected.len == 0) return true;
    const net_i: usize = @intCast(net);
    return net_i < selected.len and selected[net_i];
}

/// What applying a deletion plan produced: the surviving copper plus how
/// many of the dropped sections were recursively exposed stubs rather than
/// first-round dangling findings.
pub const Apply = struct {
    routed: router.RouteResult,
    stub_tracks_removed: usize = 0,
};

/// Drop every stored trace section the findings mark jointly deletable
/// (`dangling_copper` / `copper_stub` with a stored index), respecting the
/// net scope. Pure plan application: the gate decides whether it lands.
pub fn applyTrackPlan(
    alloc: std.mem.Allocator,
    routed: router.RouteResult,
    findings: []const drc.Violation,
    selected: []const bool,
) std.mem.Allocator.Error!Apply {
    const drop = try alloc.alloc(bool, routed.tracks.len);
    @memset(drop, false);
    var stub_tracks_removed: usize = 0;
    for (findings) |finding| {
        const removable = finding.kind == .dangling_copper or finding.kind == .copper_stub;
        if (!removable or finding.who.track_a < 0) continue;
        const track_i: usize = @intCast(finding.who.track_a);
        if (track_i >= routed.tracks.len) continue;
        const net = routed.tracks[track_i].net;
        if (!netSelected(selected, net)) continue;
        if (!drop[track_i] and finding.kind == .copper_stub) stub_tracks_removed += 1;
        drop[track_i] = true;
    }
    var tracks: std.ArrayList(router.Track) = .empty;
    for (routed.tracks, drop) |track, remove| if (!remove) try tracks.append(alloc, track);
    var out = routed;
    out.tracks = try tracks.toOwnedSlice(alloc);
    return .{ .routed = out, .stub_tracks_removed = stub_tracks_removed };
}

/// Drop every via the findings mark redundant (`single_layer_via` /
/// `redundant_via`), skipping ground nets, whose stitching is intentional.
pub fn applyViaPlan(
    alloc: std.mem.Allocator,
    nets: []const optimizer.FlatNet,
    routed: router.RouteResult,
    findings: []const drc.Violation,
    selected: []const bool,
) std.mem.Allocator.Error!router.RouteResult {
    const drop_vias = try alloc.alloc(bool, routed.vias.len);
    @memset(drop_vias, false);
    for (findings) |finding| {
        const removable = finding.kind == .single_layer_via or finding.kind == .redundant_via;
        if (!removable or finding.who.track_a < 0) continue;
        const via_i: usize = @intCast(finding.who.track_a);
        if (via_i >= routed.vias.len) continue;
        const via = routed.vias[via_i];
        if (!netSelected(selected, via.net) or via.net < 0) continue;
        const net_i: usize = @intCast(via.net);
        if (net_i >= nets.len or optimizer.isGroundName(router.shortName(nets[net_i].name))) continue;
        drop_vias[via_i] = true;
    }
    var vias: std.ArrayList(router.Via) = .empty;
    for (routed.vias, drop_vias) |via, remove| if (!remove) try vias.append(alloc, via);
    var out = routed;
    out.vias = try vias.toOwnedSlice(alloc);
    return out;
}

/// May this cleanup candidate land? Refuses error growth, any change to the
/// routable-net total, a net dropping out of the routed tally — and a grown
/// bypass_open count: an authored bypass relationship is connection INTENT,
/// and a section whose deletion severs a decoupling cap's same-face leg
/// "preserves connectivity" only in the net-graph sense. Cleanup must never
/// trade junk copper for a degraded bypass, even at warn severity.
pub fn gateSafe(
    before_violations: []const drc.Violation,
    before_tally: fab_readiness.Tally,
    after_violations: []const drc.Violation,
    after_tally: fab_readiness.Tally,
) bool {
    if (drc.errorCount(after_violations) > drc.errorCount(before_violations)) return false;
    if (drc.countKind(after_violations, .bypass_open) > drc.countKind(before_violations, .bypass_open)) return false;
    if (after_tally.total != before_tally.total) return false;
    return after_tally.routed >= before_tally.routed;
}

/// Which nets does `after_open` name that `before_open` did not — as indices
/// into `nets`, matched by exact stored name? The tally's open list is the
/// gate's own connectivity verdict, so this is the per-net attribution of a
/// refused cleanup: the nets whose copper the candidate must not touch.
pub fn newlyOpenNets(
    alloc: std.mem.Allocator,
    nets: []const optimizer.FlatNet,
    before_open: []const []const u8,
    after_open: []const []const u8,
) std.mem.Allocator.Error![]const usize {
    var out: std.ArrayList(usize) = .empty;
    for (after_open) |opened| {
        var pre_existing = false;
        for (before_open) |was| {
            if (std.mem.eql(u8, was, opened)) {
                pre_existing = true;
                break;
            }
        }
        if (pre_existing) continue;
        for (nets, 0..) |net, net_i| {
            if (std.mem.eql(u8, net.name, opened)) {
                try out.append(alloc, net_i);
                break;
            }
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Which nets carry MORE bypass_open findings after the candidate than
/// before? The per-net attribution of a gate refusal on the bypass rule: the
/// finding's `net_a` is the bypass rail leg whose surface path the deleted
/// copper was carrying.
pub fn bypassRegressedNets(
    alloc: std.mem.Allocator,
    net_count: usize,
    before_violations: []const drc.Violation,
    after_violations: []const drc.Violation,
) std.mem.Allocator.Error![]const usize {
    const before_counts = try alloc.alloc(usize, net_count);
    const after_counts = try alloc.alloc(usize, net_count);
    @memset(before_counts, 0);
    @memset(after_counts, 0);
    for (before_violations) |v| {
        if (v.kind == .bypass_open and v.who.net_a >= 0 and @as(usize, @intCast(v.who.net_a)) < net_count)
            before_counts[@intCast(v.who.net_a)] += 1;
    }
    for (after_violations) |v| {
        if (v.kind == .bypass_open and v.who.net_a >= 0 and @as(usize, @intCast(v.who.net_a)) < net_count)
            after_counts[@intCast(v.who.net_a)] += 1;
    }
    var out: std.ArrayList(usize) = .empty;
    for (before_counts, after_counts, 0..) |was, now, net_i| {
        if (now > was) try out.append(alloc, net_i);
    }
    return out.toOwnedSlice(alloc);
}

const testing = std.testing;

// spec: route-cleanup-gate - a cleanup candidate is refused when it grows the error count, opens a routed net, or grows the bypass_open count, and accepted when nothing regresses
test "gateSafe refuses error growth, lost routing, and bypass_open growth" {
    const clean = [_]drc.Violation{};
    const bypass = [_]drc.Violation{.{
        .x = 0,
        .y = 0,
        .gap = 0,
        .clearance = 0,
        .kind = .bypass_open,
        .severity = .warn,
        .who = .{ .net_a = 3 },
    }};
    const t = fab_readiness.Tally{ .routed = 5, .total = 5 };
    try testing.expect(gateSafe(&clean, t, &clean, t));
    // A net dropping out of the routed tally refuses.
    try testing.expect(!gateSafe(&clean, t, &clean, .{ .routed = 4, .total = 5 }));
    // A changed net total refuses.
    try testing.expect(!gateSafe(&clean, t, &clean, .{ .routed = 5, .total = 6 }));
    // A NEW bypass_open refuses even though it is warn-severity…
    try testing.expect(!gateSafe(&clean, t, &bypass, t));
    // …while a PRE-EXISTING one does not hold cleanup hostage.
    try testing.expect(gateSafe(&bypass, t, &bypass, t));
}

// spec: route-cleanup-gate - a refused candidate is attributed to exact nets, by the tally names that are newly open and the nets whose bypass_open count grew
test "newlyOpenNets and bypassRegressedNets name the offending nets" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const nets = [_]optimizer.FlatNet{
        .{ .name = "GND", .pins = &.{} },
        .{ .name = "V_3V3D", .pins = &.{} },
        .{ .name = "V_3V3D.U23.60", .pins = &.{} },
    };
    // LNA-style pre-existing open stays exempt; only the newly open net is named.
    const before_open = [_][]const u8{"GND"};
    const after_open = [_][]const u8{ "GND", "V_3V3D" };
    const opened = try newlyOpenNets(arena, &nets, &before_open, &after_open);
    try testing.expectEqualSlices(usize, &.{1}, opened);
    // A bypass_open count that grew on the micro-net names exactly that net.
    const grew = [_]drc.Violation{.{
        .x = 0,
        .y = 0,
        .gap = 0,
        .clearance = 0,
        .kind = .bypass_open,
        .severity = .warn,
        .who = .{ .net_a = 2 },
    }};
    const hit = try bypassRegressedNets(arena, nets.len, &.{}, &grew);
    try testing.expectEqualSlices(usize, &.{2}, hit);
}
