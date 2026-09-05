//! Post-route geometry cleanup (E1/E7/E8/E9/E10/E11) — the router's "gloss" over
//! FINISHED copper, around `straighten`.
//!
//! Every pass here only simplifies or COMPLETES a net's own metal: each
//! replacement segment and each bridge is probed at DRC clearance against the
//! whole board (same-net copper is free to the probe), so none can add a
//! foreign-clearance violation, and connectivity only ever improves. The order
//! `router.finishRoute` runs them in is redundant-layer-hop removal (E10,
//! bracketed by `straighten` and ahead of return-path stitching, so no GND via
//! is spent guarding a signal via about to be deleted — see the measured
//! rationale at the call site) → collinear-collapse → terminal-via snap →
//! net-open closure → pad-centre weld → degenerate-segment drop (last, so it
//! also sweeps any tail an earlier pass leaves behind).
//!
//! Split out of `router.zig`: these passes read the finished track/via lists and
//! the live routing `Ctx` but take part in no search, so they are the router's
//! cleanest module seam. The geometry core (`collinearExtremes`,
//! `terminalTailPadSide`, `countCopperIslands`, `bridgeCopperOpen`) is pure over
//! plain data and unit-tests with an all-clear probe; only the five
//! `pass`-level entry points touch `Ctx`.
//!
//! Every pass that REMOVES copper (`removeNetTracks` / `removeNetVias` pack the
//! survivors down in place) must tell the router so, because the router's
//! spatial copper index addresses tracks and vias BY LIST INDEX: after a
//! pack-down a surviving index names a different track — in range and wrong —
//! and a clearance probe resolved through it can return a false "clear" against
//! copper that is really in the way. A pass therefore either restamps the index
//! (`router.rebuildCopperIndex`, when it probes again straight after) or
//! invalidates it (`router.copperCompacted`, which makes the probes fall back
//! to their linear scan until someone rebuilds). Never leave a compaction
//! unannounced.

const std = @import("std");
const bypass_intent = @import("bypass_intent.zig");
const router = @import("router.zig");
const optimizer = @import("optimizer.zig");
const pad_shape = @import("pad_shape.zig");
const pad_neck = @import("pad_neck.zig");
const octilinear = @import("octilinear.zig");
const dive_elide = @import("dive_elide.zig");
const copper_support = @import("copper_support.zig");
const copper_topology = @import("copper_topology.zig");
const pad_project = @import("pad_project.zig");
const via_hop_scan = @import("via_hop_scan.zig");
const net_rewrite_pass = @import("net_rewrite_pass.zig");
const plane_stitch = @import("plane_stitch.zig");
const copper_contact = @import("copper_contact.zig");
const land_transit = @import("land_transit.zig");
const via_rules = @import("router_via_rules.zig");
const route_policy = @import("route_policy.zig");

const Track = router.Track;
const Via = router.Via;
const PadObs = router.PadObs;
/// The live board these passes rewrite. `router.Ctx` itself is deliberately
/// unexported, so the routing state arrives behind this handle and is only
/// ever read through its fields.
const Board = router.CleanupBoard;
const segPointDist = pad_shape.segPointDist; // one home for the segment
const segSegDist = pad_shape.segSegDist; // geometry both files need

/// A track shorter than this (1 µm) is degenerate: both ends coincide, so it is
/// electrically inert (anything touching one end touches the other), but it
/// pollutes the fab output and the sharp-bend geometry probes. Arc-chord
/// tessellation and join stubs can emit them.
const min_emit_seg_mm: f64 = 1e-3;
/// Exact-coordinate tolerance for vias that represent one physical drill.
const coincident_via_eps_mm: f64 = 1e-9;
/// Electrical contact tolerance shared with the fab graph. The former 20 µm
/// band is reported as a hairline defect and never proves connectivity.
const net_open_slack_mm = copper_contact.join_slack_mm;
/// Intentional endpoint-on-centreline equality, kept in lock-step with
/// `copper_topology` without widening that module's public surface.
const junction_eps_mm: f64 = 1e-6;
/// Longest same-net gap the closure will bridge. Real routed-but-open gaps are
/// sub-millimetre weld near-misses; a larger separation is a genuine unrouted
/// leg the ratsnest owns, not something to paper over with a straight jumper.
const max_bridge_mm: f64 = 1.5;
/// A collinear-collapse needs at least this many pads — a 2-pad hop is already
/// the straighten pass's direct-collapse case.
const collinear_min_pads: usize = 3;
/// Adjacent-run fusion is deliberately local. The router's ordinary adjacent
/// lane is one track width plus clearance away; a farther pair is two routes
/// that merely happen to share a heading, not the doubled-up trunk this pass
/// is meant to clean.
const parallel_sin_tol: f64 = 0.02;
const parallel_separation_drift_widths: f64 = 0.05;
const parallel_min_overlap_widths: f64 = 2;
const parallel_min_separation_widths: f64 = 0.5;
/// A shared branch may be separated by one intervening routing lane. Dense
/// fan-outs frequently stagger a second pad escape two pitches over before the
/// legs meet; treating that as an unrelated route leaves the doubled trunk the
/// pass exists to remove.
const parallel_max_separation_pitches: f64 = 2;
const parallel_max_connector_pitches: f64 = 6;
const max_parallel_fusions_per_net: usize = 16;
const max_parallel_candidates_per_fusion: usize = 32;
const max_adjacent_pad_fusions_per_net: usize = 16;
/// Net sentinel used to tag tracks for in-place removal by `removeNetTracks`.
const cleanup_removed_net: i32 = std.math.minInt(i32);

/// Drop every track of `net` from `list`, packing the survivors down in place.
pub fn removeNetTracks(list: *std.ArrayList(Track), net: i32) void {
    var w: usize = 0;
    for (list.items) |item| {
        if (item.net != net) {
            list.items[w] = item;
            w += 1;
        }
    }
    list.shrinkRetainingCapacity(w);
}

/// Drop every via of `net` from `list`, packing the survivors down in place.
pub fn removeNetVias(list: *std.ArrayList(Via), net: i32) void {
    var w: usize = 0;
    for (list.items) |item| {
        if (item.net != net) {
            list.items[w] = item;
            w += 1;
        }
    }
    list.shrinkRetainingCapacity(w);
}

/// May a cleanup pass rewrite `net`'s copper? The scope guard every such pass
/// shares — see `net_rewrite_pass.mayRewrite`.
const mayRewrite = net_rewrite_pass.mayRewrite;

/// Is this net one leg of a declared differential pair? Also the shared guard:
/// every pass that edits copper per net owes the pair the same answer.
const netIsDiffPairLeg = net_rewrite_pass.netIsDiffPairLeg;

/// Drop every degenerate (sub-micron) track from the finished copper. See
/// `min_emit_seg_mm`. Compacts the list in place. `selected_nets` is the run's
/// routing scope: an unselected net's copper is echoed verbatim, degenerate or
/// not (see `mayRewrite`); empty means whole-board (everything sweepable).
pub fn dropDegenerateTracks(tracks: *std.ArrayList(Track), selected_nets: []const bool) void {
    var w: usize = 0;
    for (tracks.items) |t| {
        if (!mayRewrite(selected_nets, t.net) or
            std.math.hypot(t.x2 - t.x1, t.y2 - t.y1) >= min_emit_seg_mm)
        {
            tracks.items[w] = t;
            w += 1;
        }
    }
    tracks.shrinkRetainingCapacity(w);
}

/// Collapse same-net barrels at one coordinate to the first occurrence. They
/// are one physical drill even when two route phases stamped different
/// diameter metadata there, and every incident track already terminates at the
/// surviving point, so unlike a near-via fold this needs no re-anchoring.
/// Scoped routing leaves retained nets byte-for-byte unchanged.
pub fn dropCoincidentVias(vias: *std.ArrayList(Via), selected_nets: []const bool) void {
    var write: usize = 0;
    for (vias.items) |via| {
        var duplicate = false;
        if (mayRewrite(selected_nets, via.net)) for (vias.items[0..write]) |prior| {
            if (!samePhysicalVia(prior, via)) continue;
            duplicate = true;
            break;
        };
        if (duplicate) continue;
        vias.items[write] = via;
        write += 1;
    }
    vias.shrinkRetainingCapacity(write);
}

/// Counts from one own-land re-anchoring cleanup pass.
pub const LandTransitRepair = struct {
    segments_reanchored: usize = 0,
    passes: usize = 0,
};

/// Generated route contacts rewritten into explicit centreline topology.
/// `bridges` close cap-to-cap / cap-to-side gaps; `splits` name true mid-span
/// X intersections by giving one generated section an endpoint there.
const JunctionRepair = struct {
    bridges: usize = 0,
    splits: usize = 0,
    remaining: usize = 0,
};

fn topologyTrack(track: Track) copper_topology.Track {
    return .{
        .a = .{ track.x1, track.y1 },
        .b = .{ track.x2, track.y2 },
        .layer = track.layer,
        .width = track.width,
        .net = track.net,
    };
}

fn topologyTracks(arena: std.mem.Allocator, tracks: []const Track) std.mem.Allocator.Error![]const copper_topology.Track {
    const out = try arena.alloc(copper_topology.Track, tracks.len);
    for (tracks, out) |track, *topology| topology.* = topologyTrack(track);
    return out;
}

fn cross2(a: [2]f64, b: [2]f64) f64 {
    return a[0] * b[1] - a[1] * b[0];
}

/// Proper interior intersection of two centrelines. Endpoint and collinear
/// contacts are handled by the explicit endpoint-on-centreline rule already.
fn interiorIntersection(a: Track, b: Track) ?[2]f64 {
    const p = [2]f64{ a.x1, a.y1 };
    const q = [2]f64{ b.x1, b.y1 };
    const r = [2]f64{ a.x2 - a.x1, a.y2 - a.y1 };
    const s = [2]f64{ b.x2 - b.x1, b.y2 - b.y1 };
    const den = cross2(r, s);
    if (@abs(den) <= junction_eps_mm * junction_eps_mm) return null;
    const qp = [2]f64{ q[0] - p[0], q[1] - p[1] };
    const t = cross2(qp, s) / den;
    const u = cross2(qp, r) / den;
    const eps = junction_eps_mm;
    if (t <= eps or t >= 1 - eps or u <= eps or u >= 1 - eps) return null;
    return .{ p[0] + t * r[0], p[1] + t * r[1] };
}

const GapWitness = struct {
    from: [2]f64,
    to: [2]f64,
    distance: f64,
};

fn considerWitness(best: *GapWitness, from: [2]f64, target: Track) void {
    const closest = pad_shape.closestOnSeg(target.x1, target.y1, target.x2, target.y2, from[0], from[1]);
    if (closest.d >= best.distance) return;
    best.* = .{ .from = from, .to = .{ closest.x, closest.y }, .distance = closest.d };
}

fn closestGap(a: Track, b: Track) GapWitness {
    var best = GapWitness{ .from = .{ a.x1, a.y1 }, .to = .{ b.x1, b.y1 }, .distance = std.math.inf(f64) };
    considerWitness(&best, .{ a.x1, a.y1 }, b);
    considerWitness(&best, .{ a.x2, a.y2 }, b);
    considerWitness(&best, .{ b.x1, b.y1 }, a);
    considerWitness(&best, .{ b.x2, b.y2 }, a);
    return best;
}

fn splitTrackAt(
    arena: std.mem.Allocator,
    tracks: *std.ArrayList(Track),
    mutable: *std.ArrayList(bool),
    index: usize,
    at: [2]f64,
) std.mem.Allocator.Error!void {
    const original = tracks.items[index];
    tracks.items[index].x2 = at[0];
    tracks.items[index].y2 = at[1];
    var tail = original;
    tail.x1 = at[0];
    tail.y1 = at[1];
    try tracks.append(arena, tail);
    try mutable.append(arena, true);
}

/// Canonicalize every implicit trace/trace or trace/via join involving
/// generated/mutable copper. `mutable` parallels `tracks`; false entries are
/// caller-retained and remain byte-for-byte unchanged. Trace gaps close with a
/// segment between both centrelines; weak via contacts get a short weld from
/// the trace centreline to the via centre. A true X splits one mutable section
/// at the exact intersection.
pub fn canonicalizeTraceJunctions(
    arena: std.mem.Allocator,
    tracks: *std.ArrayList(Track),
    mutable: *std.ArrayList(bool),
    vias: []const Via,
) std.mem.Allocator.Error!void {
    _ = try canonicalizeTraceJunctionsStats(arena, tracks, mutable, vias);
}

fn canonicalizeTraceOnlyStats(
    arena: std.mem.Allocator,
    tracks: *std.ArrayList(Track),
    mutable: *std.ArrayList(bool),
) std.mem.Allocator.Error!JunctionRepair {
    std.debug.assert(mutable.items.len == tracks.items.len);
    var result = JunctionRepair{};
    const repair_cap = tracks.items.len + 1;
    var repairs: usize = 0;
    while (repairs < repair_cap) : (repairs += 1) {
        const topology = try topologyTracks(arena, tracks.items);
        const joins = try copper_topology.repairableJoins(arena, topology);
        var repaired = false;
        for (joins) |join| {
            const a_mutable = mutable.items[join.a];
            const b_mutable = mutable.items[join.b];
            if (!a_mutable and !b_mutable) continue;
            const a = tracks.items[join.a];
            const b = tracks.items[join.b];
            if (interiorIntersection(a, b)) |at| {
                try splitTrackAt(arena, tracks, mutable, if (a_mutable) join.a else join.b, at);
                result.splits += 1;
            } else {
                const gap = closestGap(a, b);
                if (gap.distance <= junction_eps_mm) continue;
                try tracks.append(arena, .{
                    .x1 = gap.from[0],
                    .y1 = gap.from[1],
                    .x2 = gap.to[0],
                    .y2 = gap.to[1],
                    .layer = a.layer,
                    .width = @min(a.width, b.width),
                    .net = a.net,
                });
                try mutable.append(arena, true);
                result.bridges += 1;
            }
            repaired = true;
            break;
        }
        if (!repaired) break;
    }
    const final_topology = try topologyTracks(arena, tracks.items);
    for (try copper_topology.repairableJoins(arena, final_topology)) |join| {
        if (mutable.items[join.a] or mutable.items[join.b]) result.remaining += 1;
    }
    return result;
}

fn repairWeakViaContacts(
    arena: std.mem.Allocator,
    tracks: *std.ArrayList(Track),
    mutable: *std.ArrayList(bool),
    vias: []const Via,
) std.mem.Allocator.Error!usize {
    const initial_tracks = tracks.items.len;
    const via_base = initial_tracks * 2 + vias.len;
    const parent = try arena.alloc(usize, via_base + vias.len);
    for (parent, 0..) |*node, i| node.* = i;

    // Seed the robust components once. New welds below explicitly merge their
    // source trace and via nodes, so no expensive whole-graph rebuild is needed
    // after each repair.
    for (tracks.items, 0..) |track, track_i| {
        const contact_track = copper_contact.Trace{
            .a = .{ track.x1, track.y1 },
            .b = .{ track.x2, track.y2 },
            .width = track.width,
        };
        for (tracks.items[track_i + 1 ..], track_i + 1..) |other, other_i| {
            if (track.net != other.net or track.layer != other.layer) continue;
            if (copper_contact.trackTrackConnects(contact_track, .{
                .a = .{ other.x1, other.y1 },
                .b = .{ other.x2, other.y2 },
                .width = other.width,
            })) ufUnite(parent, track_i, other_i);
        }
        for (vias, 0..) |via, via_i| {
            if (via.net != track.net) continue;
            if (copper_contact.trackViaConnects(contact_track, .{
                .at = .{ via.x, via.y },
                .dia = via.dia,
            })) ufUnite(parent, track_i, via_base + via_i);
        }
    }
    for (vias, 0..) |via, via_i| {
        for (vias[via_i + 1 ..], via_i + 1..) |other, other_i| {
            if (via.net != other.net) continue;
            if (std.math.hypot(via.x - other.x, via.y - other.y) <=
                via.dia / 2 + other.dia / 2 + copper_contact.join_slack_mm)
                ufUnite(parent, via_base + via_i, via_base + other_i);
        }
    }

    var added: usize = 0;
    while (tracks.items.len < via_base) {
        var repaired = false;
        scan: for (tracks.items, 0..) |track, track_i| {
            if (!mutable.items[track_i]) continue;
            const contact_track = copper_contact.Trace{
                .a = .{ track.x1, track.y1 },
                .b = .{ track.x2, track.y2 },
                .width = track.width,
            };
            for (vias, 0..) |via, via_i| {
                if (via.net != track.net or ufFind(parent, track_i) == ufFind(parent, via_base + via_i)) continue;
                const contact_via = copper_contact.Via{ .at = .{ via.x, via.y }, .dia = via.dia };
                if (!copper_contact.trackViaCopperOverlaps(contact_track, contact_via) or
                    copper_contact.trackViaConnects(contact_track, contact_via)) continue;
                const closest = pad_shape.closestOnSeg(track.x1, track.y1, track.x2, track.y2, via.x, via.y);
                if (std.math.hypot(closest.x - via.x, closest.y - via.y) <= junction_eps_mm) continue;
                const weld_i = tracks.items.len;
                try tracks.append(arena, .{
                    .x1 = closest.x,
                    .y1 = closest.y,
                    .x2 = via.x,
                    .y2 = via.y,
                    .layer = track.layer,
                    .width = track.width,
                    .net = track.net,
                });
                try mutable.append(arena, true);
                ufUnite(parent, weld_i, track_i);
                ufUnite(parent, weld_i, via_base + via_i);
                added += 1;
                repaired = true;
                break :scan;
            }
        }
        if (!repaired) break;
    }
    return added;
}

fn canonicalizeTraceJunctionsStats(
    arena: std.mem.Allocator,
    tracks: *std.ArrayList(Track),
    mutable: *std.ArrayList(bool),
    vias: []const Via,
) std.mem.Allocator.Error!JunctionRepair {
    var result = try canonicalizeTraceOnlyStats(arena, tracks, mutable);
    const via_bridges = try repairWeakViaContacts(arena, tracks, mutable, vias);
    result.bridges += via_bridges;
    if (via_bridges == 0) return result;
    const followup = try canonicalizeTraceOnlyStats(arena, tracks, mutable);
    result.bridges += followup.bridges;
    result.splits += followup.splits;
    result.remaining = followup.remaining;
    return result;
}

// spec: placement/router - generated same-net cap overlap is closed by an explicit endpoint-on-centreline bridge
test "trace junction canonicalization bridges a physical endpoint gap" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var tracks: std.ArrayList(Track) = .empty;
    try tracks.appendSlice(arena, &.{
        .{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 1.05, .y1 = 0, .x2 = 2, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
    });
    var mutable: std.ArrayList(bool) = .empty;
    try mutable.appendSlice(arena, &.{ true, true });
    const repaired = try canonicalizeTraceJunctionsStats(arena, &tracks, &mutable, &.{});
    try std.testing.expectEqual(@as(usize, 1), repaired.bridges);
    try std.testing.expectEqual(@as(usize, 0), repaired.splits);
    try std.testing.expectEqual(@as(usize, 0), repaired.remaining);
    try std.testing.expectEqual(@as(usize, 3), tracks.items.len);
    try std.testing.expectEqual(@as(f64, 1), tracks.items[2].x1);
    try std.testing.expectEqual(@as(f64, 1.05), tracks.items[2].x2);
    try std.testing.expectEqual(@as(usize, 0), (try copper_topology.implicitJoins(arena, try topologyTracks(arena, tracks.items))).len);
}

// spec: placement/router - a generated mid-span X is split at one exact coordinate while retained copper stays byte-identical
test "trace junction canonicalization names an X without rewriting retained copper" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const retained = Track{ .x1 = -2, .y1 = 0, .x2 = 2, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 };
    var tracks: std.ArrayList(Track) = .empty;
    try tracks.appendSlice(arena, &.{
        retained,
        .{ .x1 = 0, .y1 = -2, .x2 = 0, .y2 = 2, .layer = 0, .width = 0.2, .net = 0 },
    });
    var mutable: std.ArrayList(bool) = .empty;
    try mutable.appendSlice(arena, &.{ false, true });
    const repaired = try canonicalizeTraceJunctionsStats(arena, &tracks, &mutable, &.{});
    try std.testing.expectEqual(@as(usize, 0), repaired.bridges);
    try std.testing.expectEqual(@as(usize, 1), repaired.splits);
    try std.testing.expectEqual(@as(usize, 0), repaired.remaining);
    try std.testing.expect(std.meta.eql(retained, tracks.items[0]));
    try std.testing.expectEqual(@as(f64, 0), tracks.items[1].x2);
    try std.testing.expectEqual(@as(f64, 0), tracks.items[1].y2);
    try std.testing.expectEqual(@as(f64, 0), tracks.items[2].x1);
    try std.testing.expectEqual(@as(f64, 0), tracks.items[2].y1);
}

// spec: placement/router - canonical junction repair never rewrites or augments caller-retained copper
test "trace junction canonicalization leaves a retained implicit join visible" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var tracks: std.ArrayList(Track) = .empty;
    try tracks.appendSlice(arena, &.{
        .{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 1.05, .y1 = 0, .x2 = 2, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
    });
    var mutable: std.ArrayList(bool) = .empty;
    try mutable.appendSlice(arena, &.{ false, false });
    const repaired = try canonicalizeTraceJunctionsStats(arena, &tracks, &mutable, &.{});
    try std.testing.expectEqual(@as(usize, 0), repaired.bridges + repaired.splits);
    try std.testing.expectEqual(@as(usize, 0), repaired.remaining);
    try std.testing.expectEqual(@as(usize, 2), tracks.items.len);
}

// spec: placement/router - a generated trace that only grazes a via receives an explicit centreline-to-via-centre weld
test "trace junction canonicalization welds a weak via contact" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var tracks: std.ArrayList(Track) = .empty;
    try tracks.append(arena, .{
        .x1 = 139.8234,
        .y1 = 96.65,
        .x2 = 140.45,
        .y2 = 97.4,
        .layer = 0,
        .width = 0.2532,
        .net = 0,
    });
    const vias = [_]Via{.{
        .x = 140.41680036354114,
        .y = 97.72507713281217,
        .dia = 0.4,
        .net = 0,
    }};
    var mutable: std.ArrayList(bool) = .empty;
    try mutable.append(arena, true);
    const repaired = try canonicalizeTraceJunctionsStats(arena, &tracks, &mutable, &vias);
    try std.testing.expectEqual(@as(usize, 1), repaired.bridges);
    try std.testing.expectEqual(@as(usize, 2), tracks.items.len);
    const weld = tracks.items[1];
    try std.testing.expectApproxEqAbs(vias[0].x, weld.x2, 1e-12);
    try std.testing.expectApproxEqAbs(vias[0].y, weld.y2, 1e-12);
    try std.testing.expect(copper_contact.trackViaConnects(
        .{ .a = .{ weld.x1, weld.y1 }, .b = .{ weld.x2, weld.y2 }, .width = weld.width },
        .{ .at = .{ vias[0].x, vias[0].y }, .dia = vias[0].dia },
    ));
    const fixed = try canonicalizeTraceJunctionsStats(arena, &tracks, &mutable, &vias);
    try std.testing.expectEqual(@as(usize, 0), fixed.bridges + fixed.splits);
    try std.testing.expectEqual(@as(usize, 2), tracks.items.len);
}

fn repairNetSelected(selected: []const bool, net: i32) bool {
    if (net < 0) return false;
    return selected.len == 0 or (@as(usize, @intCast(net)) < selected.len and selected[@intCast(net)]);
}

fn appendAnchoredTracks(
    arena: std.mem.Allocator,
    out: *std.ArrayList(Track),
    track: Track,
    anchored: land_transit.AnchoredSegment,
) std.mem.Allocator.Error!void {
    for (1..anchored.len) |i| {
        const a = anchored.points[i - 1];
        const b = anchored.points[i];
        if (std.math.hypot(b[0] - a[0], b[1] - a[1]) <= 1e-9) continue;
        var piece = track;
        piece.x1 = a[0];
        piece.y1 = a[1];
        piece.x2 = b[0];
        piece.y2 = b[1];
        try out.append(arena, piece);
    }
}

/// Re-anchor every selected same-net segment that laps an SMD land.
///
/// Each pass repairs at most one land per segment; a replacement ray can cross
/// a second same-net land, so passes continue to a fixed point. The cap is a
/// corruption guard only: a clean repair permanently removes the chosen
/// segment/land offence, and therefore converges after at most the number of
/// lands crossed by the original copper graph.
pub fn reanchorLandTransit(
    arena: std.mem.Allocator,
    pads: []const router.PadObs,
    tracks: *std.ArrayList(Track),
    selected_nets: []const bool,
) std.mem.Allocator.Error!LandTransitRepair {
    var stats = LandTransitRepair{};
    const pass_cap = pads.len + 1;
    while (stats.passes < pass_cap) : (stats.passes += 1) {
        var changed = false;
        var rebuilt: std.ArrayList(Track) = .empty;
        for (tracks.items) |track| {
            var anchored: ?land_transit.AnchoredSegment = null;
            if (repairNetSelected(selected_nets, track.net)) {
                for (pads) |pad| {
                    if (pad.thru or pad.net != track.net or pad.layer != track.layer) continue;
                    const land = land_transit.Land{
                        .x0 = pad.x0,
                        .y0 = pad.y0,
                        .x1 = pad.x1,
                        .y1 = pad.y1,
                        .poly = pad.poly,
                    };
                    anchored = land_transit.anchorSegment(
                        land,
                        .{ track.x1, track.y1 },
                        .{ track.x2, track.y2 },
                        track.width / 2,
                    );
                    if (anchored != null) break;
                }
            }
            if (anchored) |fixed| {
                try appendAnchoredTracks(arena, &rebuilt, track, fixed);
                stats.segments_reanchored += 1;
                changed = true;
            } else {
                try rebuilt.append(arena, track);
            }
        }
        if (!changed) break;
        tracks.* = rebuilt;
    }
    return stats;
}

fn pointInPad(pad: router.PadObs, x: f64, y: f64) bool {
    return x >= pad.x0 - 1e-9 and x <= pad.x1 + 1e-9 and
        y >= pad.y0 - 1e-9 and y <= pad.y1 + 1e-9;
}

/// Snap every selected track endpoint lying on an offending own land to that
/// land's centre. All branches at the on-land junction move together, so the
/// operation cannot tear a T-junction apart. Returns the number of endpoints
/// moved; callers still run their normal DRC/connectivity ratchet.
pub fn snapLandTransitEndpoints(
    pads: []const router.PadObs,
    tracks: *std.ArrayList(Track),
    selected_nets: []const bool,
) LandTransitRepair {
    var stats = LandTransitRepair{ .passes = 1 };
    for (pads) |pad| {
        if (pad.thru or !repairNetSelected(selected_nets, pad.net)) continue;
        var offending_endpoint = false;
        for (tracks.items) |track| {
            if (track.net != pad.net or track.layer != pad.layer) continue;
            if (land_transit.segmentOffence(
                padLand(pad),
                .{ track.x1, track.y1 },
                .{ track.x2, track.y2 },
                track.width / 2,
            ) == null) continue;
            if (pointInPad(pad, track.x1, track.y1) or pointInPad(pad, track.x2, track.y2)) {
                offending_endpoint = true;
                break;
            }
        }
        if (!offending_endpoint) continue;
        const centre = padLand(pad).centre();
        for (tracks.items) |*track| {
            if (track.net != pad.net or track.layer != pad.layer) continue;
            if (pointInPad(pad, track.x1, track.y1)) {
                track.x1 = centre[0];
                track.y1 = centre[1];
                stats.segments_reanchored += 1;
            }
            if (pointInPad(pad, track.x2, track.y2)) {
                track.x2 = centre[0];
                track.y2 = centre[1];
                stats.segments_reanchored += 1;
            }
        }
    }
    dropDegenerateTracks(tracks, selected_nets);
    return stats;
}

fn padLand(pad: router.PadObs) land_transit.Land {
    return .{ .x0 = pad.x0, .y0 = pad.y0, .x1 = pad.x1, .y1 = pad.y1, .poly = pad.poly };
}

/// Re-anchor selected copper through both centres of an adjacent same-net land
/// pair. This resolves the otherwise cyclic case where centring a ray on land A
/// makes it lap neighbouring land B and centring B sends it back across A.
pub fn reanchorLandPair(
    arena: std.mem.Allocator,
    pair: [2]router.PadObs,
    tracks: *std.ArrayList(Track),
    selected_nets: []const bool,
) std.mem.Allocator.Error!LandTransitRepair {
    var stats = LandTransitRepair{ .passes = 1 };
    const lands = [2]land_transit.Land{ padLand(pair[0]), padLand(pair[1]) };
    const centres = [2][2]f64{ lands[0].centre(), lands[1].centre() };
    const pair_compatible = pair[0].net == pair[1].net and pair[0].layer == pair[1].layer;
    var rebuilt: std.ArrayList(Track) = .empty;
    for (tracks.items) |track| {
        var offending = false;
        const track_on_pair = repairNetSelected(selected_nets, track.net) and
            track.net == pair[0].net and track.layer == pair[0].layer;
        if (pair_compatible and track_on_pair) {
            for (lands) |land| {
                if (land_transit.segmentOffence(
                    land,
                    .{ track.x1, track.y1 },
                    .{ track.x2, track.y2 },
                    track.width / 2,
                ) != null) {
                    offending = true;
                    break;
                }
            }
        }
        if (!offending) {
            try rebuilt.append(arena, track);
            continue;
        }
        const a = [2]f64{ track.x1, track.y1 };
        const b = [2]f64{ track.x2, track.y2 };
        const forward = std.math.hypot(a[0] - centres[0][0], a[1] - centres[0][1]) +
            std.math.hypot(b[0] - centres[1][0], b[1] - centres[1][1]);
        const reverse = std.math.hypot(a[0] - centres[1][0], a[1] - centres[1][1]) +
            std.math.hypot(b[0] - centres[0][0], b[1] - centres[0][1]);
        const first = if (forward <= reverse) centres[0] else centres[1];
        const second = if (forward <= reverse) centres[1] else centres[0];
        const fixed = land_transit.AnchoredSegment{
            .points = .{ a, first, second, b, .{ 0, 0 } },
            .len = 4,
        };
        try appendAnchoredTracks(arena, &rebuilt, track, fixed);
        stats.segments_reanchored += 1;
    }
    if (stats.segments_reanchored > 0) tracks.* = rebuilt;
    return stats;
}

fn expectNoLandTransit(pads: []const router.PadObs, tracks: []const Track, net: i32) !void {
    for (pads) |pad| for (tracks) |track| {
        if (track.net != net) continue;
        try std.testing.expect(land_transit.segmentOffence(
            padLand(pad),
            .{ track.x1, track.y1 },
            .{ track.x2, track.y2 },
            track.width / 2,
        ) == null);
    };
}

// spec: placement/land-transit - board cleanup reaches a fixed point with every selected same-net land crossing centre-anchored
test "land-transit cleanup reanchors a selected crossing and leaves retained copper untouched" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const pads = [_]router.PadObs{.{ .x0 = -0.2, .y0 = -0.4, .x1 = 0.2, .y1 = 0.4, .net = 0, .layer = 0 }};
    var tracks: std.ArrayList(Track) = .empty;
    try tracks.append(arena, .{ .x1 = -1, .y1 = 0.3, .x2 = 1, .y2 = 0.3, .layer = 0, .width = 0.12, .net = 0 });
    try tracks.append(arena, .{ .x1 = -1, .y1 = 0.3, .x2 = 1, .y2 = 0.3, .layer = 0, .width = 0.12, .net = 1 });
    const selected = [_]bool{ true, false };
    const repaired = try reanchorLandTransit(arena, &pads, &tracks, &selected);
    try std.testing.expectEqual(@as(usize, 1), repaired.segments_reanchored);
    try std.testing.expect(tracks.items.len > 2);
    const retained = tracks.items[tracks.items.len - 1];
    try std.testing.expectEqual(@as(i32, 1), retained.net);
    try std.testing.expectEqual(@as(f64, 0.3), retained.y1);
    try expectNoLandTransit(&pads, tracks.items, 0);
}

// spec: placement/land-transit - an offending on-land junction snaps all of its same-net branches to the land centre together, preserving the junction
test "an offending on-land junction snaps every same-net branch together" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const pads = [_]router.PadObs{.{ .x0 = -0.2, .y0 = -0.4, .x1 = 0.2, .y1 = 0.4, .net = 0, .layer = 0 }};
    var tracks: std.ArrayList(Track) = .empty;
    try tracks.append(arena, .{ .x1 = 0.15, .y1 = 0.3, .x2 = 1, .y2 = 0.3, .layer = 0, .width = 0.12, .net = 0 });
    try tracks.append(arena, .{ .x1 = 0.15, .y1 = 0.3, .x2 = -1, .y2 = 0.1, .layer = 0, .width = 0.12, .net = 0 });
    const repaired = snapLandTransitEndpoints(&pads, &tracks, &.{true});
    try std.testing.expectEqual(@as(usize, 2), repaired.segments_reanchored);
    try std.testing.expectEqual(@as(f64, 0), tracks.items[0].x1);
    try std.testing.expectEqual(@as(f64, 0), tracks.items[0].y1);
    try std.testing.expectEqual(@as(f64, 0), tracks.items[1].x1);
    try std.testing.expectEqual(@as(f64, 0), tracks.items[1].y1);
}

// spec: placement/land-transit - adjacent same-net lands are repaired as one centre-to-centre cluster so their individual anchoring cannot oscillate
test "adjacent own lands reanchor through both centres" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const pair = [2]router.PadObs{
        .{ .x0 = -0.4, .y0 = -0.2, .x1 = 0, .y1 = 0.2, .net = 0, .layer = 0 },
        .{ .x0 = 0.2, .y0 = -0.2, .x1 = 0.6, .y1 = 0.2, .net = 0, .layer = 0 },
    };
    var tracks: std.ArrayList(Track) = .empty;
    try tracks.append(arena, .{ .x1 = -1, .y1 = 0.15, .x2 = 1, .y2 = 0.15, .layer = 0, .width = 0.12, .net = 0 });
    const repaired = try reanchorLandPair(arena, pair, &tracks, &.{});
    try std.testing.expectEqual(@as(usize, 1), repaired.segments_reanchored);
    try expectNoLandTransit(&pair, tracks.items, 0);
}

/// The board's pad obstacles as connectivity terminals. Exact identity (no
/// `net_identity` fold): this pass rewrites the copper it is reading, and two
/// nets it may not merge must stay two — the DRC's own audit passes an identity
/// through the same projection because its question is different.
fn topologyTerminals(board: Board) std.mem.Allocator.Error![]const copper_topology.Terminal {
    return pad_project.topologyTerminals(board.ctx.arena, board.ctx.obs, .{});
}

fn fillTopologyTracks(out: []copper_topology.Track, tracks: []const Track) []const copper_topology.Track {
    for (tracks, out[0..tracks.len]) |track, *topology| topology.* = .{
        .a = .{ track.x1, track.y1 },
        .b = .{ track.x2, track.y2 },
        .layer = track.layer,
        .width = track.width,
        .net = track.net,
    };
    return out[0..tracks.len];
}

fn fillTopologyVias(out: []copper_topology.Via, vias: []const Via) []const copper_topology.Via {
    for (vias, out[0..vias.len]) |via, *topology| topology.* = .{ .at = .{ via.x, via.y }, .dia = via.dia, .net = via.net };
    return out[0..vias.len];
}

fn topologyPlaneContacts(placement: optimizer.Placement, net: i32) u8 {
    _ = placement;
    _ = net;
    // Dedicated-plane declarations are not contact evidence. Without the fill
    // raster this pass cannot know whether a barrel sits in copper or an
    // antipad, so retain the via and let the full gate classify it.
    return 0;
}

fn mayTouchUnobservedFill(board: Board, net: i32) bool {
    if (net < 0) return false;
    const net_i: usize = @intCast(net);
    if (net_i >= board.placement.nets.len) return false;
    if (router.netHasPlane(board.placement, board.placement.nets[net_i].name)) return true;
    for (board.ctx.zones) |zone| {
        if (zone.copper and zone.net == net) return true;
    }
    return false;
}

fn topologyPourLayers(board: Board, net: i32, x: f64, y: f64) u64 {
    _ = board;
    _ = net;
    _ = x;
    _ = y;
    // This hot router-local pass has drawn zone outlines but no fabricated-fill
    // raster. An outline cannot prove conductivity (clearance can split it), so
    // omit pour credit here; the composed DRC/fab gate supplies exact fill
    // components before any persisted cleanup is accepted.
    return 0;
}

fn dropLooseTracks(
    board: Board,
    terminals: []const copper_topology.Terminal,
    tracks: []const copper_topology.Track,
    vias: []const copper_topology.Via,
) bool {
    var write: usize = 0;
    var removed = false;
    for (board.tracks.items, 0..) |track, track_i| {
        const loose = if (mayRewrite(board.ctx.selected_nets, track.net))
            copper_topology.looseEnd(
                terminals,
                tracks,
                vias,
                track_i,
                .{
                    topologyPourLayers(board, track.net, track.x1, track.y1),
                    topologyPourLayers(board, track.net, track.x2, track.y2),
                },
            )
        else
            null;
        if (loose != null) {
            removed = true;
            continue;
        }
        board.tracks.items[write] = track;
        write += 1;
    }
    board.tracks.shrinkRetainingCapacity(write);
    return removed;
}

fn dropSingleLayerVias(
    board: Board,
    terminals: []const copper_topology.Terminal,
    tracks: []const copper_topology.Track,
    vias: []const copper_topology.Via,
) bool {
    if (board.preserve_vias) return false;
    var write: usize = 0;
    var removed = false;
    for (board.vias.items, vias) |via, topology_via| {
        const use_count = copper_topology.viaUseCount(
            terminals,
            tracks,
            topology_via,
            topologyPourLayers(board, via.net, via.x, via.y),
            topologyPlaneContacts(board.placement, via.net),
        );
        // With no fabricated-fill raster, a declared plane/pour is uncertainty,
        // not proof either way. Keep its possible contact for the exact
        // composed DRC/fab gate; deleting it here would amputate every
        // end-of-route ground stitch merely because this hot pass cannot see
        // the fill that the stitcher deliberately landed in.
        const possible_fill_contact = use_count >= 1 and mayTouchUnobservedFill(board, via.net);
        var protected = false;
        for (board.protected_vias) |intentional| {
            if (!samePhysicalVia(intentional, via)) continue;
            protected = true;
            break;
        }
        const removable = mayRewrite(board.ctx.selected_nets, via.net) and use_count < 2;
        if (removable) {
            if (!possible_fill_contact) {
                if (!protected) {
                    removed = true;
                    continue;
                }
            }
        }
        board.vias.items[write] = via;
        write += 1;
    }
    board.vias.shrinkRetainingCapacity(write);
    return removed;
}

/// The barrels this seam may treat as connectivity destinations — the
/// `live_vias` of the section-deletion oracle, and the ONLY support source the
/// finish credits beyond pads and traces.
///
/// It is deliberately narrower than what `drc` and the route gate assemble
/// (`copper_support.assemble`), and the difference is the whole reason this
/// function still exists. Those two read the board through its FABRICATED
/// FILL; the router has drawn outlines and no raster, and an outline is not a
/// conductor — clearance can split it, a minimum-width filter can erase a neck
/// of it, an antipad can hole it under the very barrel being judged. Crediting
/// outlines here was measured on board-a: the finish deleted 380 sections
/// that the fabrication graph needed and opened about a hundred nets, silently,
/// because this seam has no rollback. Aggressive deletion belongs at the gate,
/// where every removal is verified against `fab_readiness` and a net that
/// suffers gets its copper back.
///
/// A declared plane IS credited, because it is a stackup fact rather than a
/// geometry guess, and crediting it RETAINS copper: it is what stops a plane
/// drop's own pad stub from reading as a run to nowhere.
fn planeSupportContacts(board: Board, net: i32) u8 {
    if (net < 0) return 0;
    const net_i: usize = @intCast(net);
    if (net_i >= board.placement.nets.len) return 0;
    return plane_stitch.declaredPlaneContacts(board.placement, board.placement.nets[net_i].name);
}

fn liveSupportVias(
    board: Board,
    terminals: []const copper_topology.Terminal,
    tracks: []const copper_topology.Track,
    vias: []const copper_topology.Via,
) std.mem.Allocator.Error![]const copper_topology.Via {
    var live: std.ArrayList(copper_topology.Via) = .empty;
    for (board.vias.items, vias) |via, topology_via| {
        const uses = copper_topology.viaUseCount(
            terminals,
            tracks,
            topology_via,
            topologyPourLayers(board, via.net, via.x, via.y),
            planeSupportContacts(board, via.net),
        );
        if (uses >= 2) try live.append(board.ctx.arena, topology_via);
    }
    return live.items;
}

/// Drop the copper that is attached at BOTH ends and still carries nothing: a
/// run that leaves a land and returns to it, an elbow whose first leg never
/// leaves the land it starts from, a loop two passes closed twice. `looseEnd`
/// is blind to all of it — every end IS supported — so this asks the oracle
/// DRC reports `dangling_copper` from, `copper_topology.analyzeRedundancy`, and
/// applies its ONE jointly safe plan rather than a per-section verdict: two
/// halves of a parallel path are each individually removable and deleting both
/// would open the net. Retained nets stay byte-identical through `mayRewrite`,
/// and skipping a planned deletion is always safe — the plan's guarantee holds
/// for every subset of it.
///
/// Only `spanning` sections are consumed: copper the board has an ALTERNATE
/// path around. A whole component that reaches at most one support is the same
/// warning to a reader but a different fact, and this fill-blind seam is the
/// wrong place to act on it — the support it cannot see may be a pour, and a
/// track wider than the land it aims at reaches no pad by the fabrication
/// oracle's reading while still being the net's only attempt at a route.
/// Deleting those is the transactional public gate's business, where a
/// connectivity check can roll the whole candidate back.
fn dropRedundantSections(
    arena: std.mem.Allocator,
    terminals: []const copper_topology.Terminal,
    support: copper_topology.BranchSupport,
    list: *std.ArrayList(Track),
    selected_nets: []const bool,
    legs: bypass_intent.Legs,
) std.mem.Allocator.Error!bool {
    const topology = try arena.alloc(copper_topology.Track, list.items.len);
    const analysis = try copper_topology.analyzeRedundancy(
        arena,
        terminals,
        fillTopologyTracks(topology, list.items),
        support,
    );
    var write: usize = 0;
    var removed = false;
    for (list.items, analysis.removal, analysis.spanning) |track, planned, spanning| {
        const deletable = mayRewrite(selected_nets, track.net) and !legFrozen(legs, track);
        if (planned and spanning and deletable) {
            removed = true;
            continue;
        }
        list.items[write] = track;
        write += 1;
    }
    list.shrinkRetainingCapacity(write);
    return removed;
}

/// Is this track copper that an authored exact bypass bond depends on?
///
/// The fill-blind deletion oracle reads a plane as making every pad of a rail
/// one connectivity component, so the local cap-to-pin surface leg an authored
/// `(decouples "IC" PIN)` binding requires looks redundant to it, and the
/// closing gloss fuses and clips runs with no view of the bond at all. Neither
/// seam can run the `bypass_open` graph after every tentative edit — they work
/// object by object, with no net-sized rollback — so both refuse the objects
/// the bond's own surface walk is made of. Only those: the REST of the rail — a
/// second cap's reservoir escape, a branch to a connector — is ordinary copper
/// and stays fair game (see `bypass_intent`).
fn legFrozen(legs: bypass_intent.Legs, track: Track) bool {
    return legs.trackFrozen(track.net, track.layer, .{ track.x1, track.y1 }, .{ track.x2, track.y2 });
}

/// Remove topology artifacts to a fixed point. A leaf trace is dropped first;
/// that may expose the preceding segment or leave a via used on only one layer,
/// so track and via pruning alternate until neither list changes. Retained nets
/// in a scoped route remain byte-for-byte untouched through `mayRewrite`.
///
/// This is the LEAF reading only. Copper attached at both ends that still
/// carries nothing needs the section-deletion oracle — see `pruneDeadCopper`,
/// which alternates the two.
pub fn pruneDanglingCopper(board: Board) std.mem.Allocator.Error!void {
    const terminals = try topologyTerminals(board);
    const topology_track_storage = try board.ctx.arena.alloc(copper_topology.Track, board.tracks.items.len);
    const topology_via_storage = try board.ctx.arena.alloc(copper_topology.Via, board.vias.items.len);
    const limit = board.tracks.items.len + board.vias.items.len + 1;
    var round: usize = 0;
    while (round < limit) : (round += 1) {
        const topology_vias = fillTopologyVias(topology_via_storage, board.vias.items);
        const tracks_removed = dropLooseTracks(board, terminals, fillTopologyTracks(topology_track_storage, board.tracks.items), topology_vias);
        const vias_removed = dropSingleLayerVias(
            board,
            terminals,
            fillTopologyTracks(topology_track_storage, board.tracks.items),
            topology_vias,
        );
        const changed = tracks_removed or vias_removed;
        if (!changed) break;
        router.copperCompacted(board.ctx);
    }
}

/// Every kind of dead copper the finished board can lose, to a fixed point:
/// loose leaves and one-layer barrels (`pruneDanglingCopper`) plus sections
/// whose deletion changes no pad/live-via connectivity (`dropRedundantSections`).
///
/// The two alternate because each can expose the other. Deleting a redundant
/// section can strand the endpoint of the section that WAS hanging off it —
/// support connectivity is preserved, but that end now touches nothing, which
/// is a `copper_stub` error rather than a warning — and dropping a leaf can
/// turn its neighbour into an equally useless spur. This is the same fixed
/// point `pruneDanglingCopper` runs internally, one rung further up.
///
/// Call it at the true end of the finish: it reads every barrel the stitchers
/// have placed as a real destination, so the copper reaching them survives.
///
/// The support context is deliberately the NARROW one — pads, traces, and
/// barrels a declared plane or a second routed layer makes live. `drc` and the
/// route gate assemble a wider reading through the fabricated fill
/// (`copper_support.assemble`), and they may: the gate verifies every removal
/// against `fab_readiness` and hands a damaged net its copper back. This seam
/// has no such rollback, so it acts only on what it can prove. See
/// `liveSupportVias` for what crediting outlines here cost when it was tried.
pub fn pruneDeadCopper(board: Board) std.mem.Allocator.Error!void {
    try pruneDanglingCopper(board);
    // Resolved once, over the copper the leaf prune left standing. The section
    // oracle refuses the walk's own tracks every round below, so the walk stays
    // whole however much of the rest of the rail goes with it.
    const legs = try bypass_intent.build(board.arena(), board.placement, Track, board.tracks.items);
    const limit = board.tracks.items.len + 1;
    var round: usize = 0;
    while (round < limit) : (round += 1) {
        const terminals = try topologyTerminals(board);
        const topology_tracks = try board.ctx.arena.alloc(copper_topology.Track, board.tracks.items.len);
        const topology_vias = try board.ctx.arena.alloc(copper_topology.Via, board.vias.items.len);
        const filled_tracks = fillTopologyTracks(topology_tracks, board.tracks.items);
        const live = try liveSupportVias(board, terminals, filled_tracks, fillTopologyVias(topology_vias, board.vias.items));
        // Pads, traces and live barrels — and no pour term at all. See
        // `liveSupportVias`: the fill this seam can see is an outline, and a
        // deletion licensed by an outline has no rollback here.
        if (!try dropRedundantSections(board.ctx.arena, terminals, .{ .live_vias = live }, board.tracks, board.ctx.selected_nets, legs))
            break;
        router.copperCompacted(board.ctx);
        try pruneDanglingCopper(board);
    }
    // No finish pass may rewrite centrelines after this oracle. Shape the
    // authored pad-local necks here so later DRC/export see the final copper.
    try pad_neck.passBoard(board);
}

fn samePhysicalVia(a: Via, b: Via) bool {
    if (a.net != b.net) return false;
    if (@abs(a.x - b.x) > coincident_via_eps_mm) return false;
    return @abs(a.y - b.y) <= coincident_via_eps_mm;
}

fn padObsCenter(o: PadObs) [2]f64 {
    return pad_shape.copperAnchor(.{ .x0 = o.x0, .y0 = o.y0, .x1 = o.x1, .y1 = o.y1, .poly = o.poly });
}

/// The closest same-net trace centreline whose copper already touches `pad`.
/// A trace that reaches the exact pad centre wins with `distance == 0`; the
/// caller then has nothing to add. SMD pads see only their own face, while a
/// through pad may be entered from any signal layer.
const PadCenterTarget = struct { at: [2]f64, layer: u8, width: f64, distance: f64 };

fn padCenterTarget(pad: PadObs, tracks: []const Track) ?PadCenterTarget {
    const center = padObsCenter(pad);
    const shape = pad_shape.Shape{ .x0 = pad.x0, .y0 = pad.y0, .x1 = pad.x1, .y1 = pad.y1, .poly = pad.poly };
    var best: ?PadCenterTarget = null;
    for (tracks) |t| {
        if (t.net != pad.net or (!pad.thru and t.layer != pad.layer)) continue;
        const touch = t.width / 2 + net_open_slack_mm;
        if (pad_shape.segmentDist(shape, .{ t.x1, t.y1 }, .{ t.x2, t.y2 }, touch) > touch) continue;
        const c = pad_shape.closestOnSeg(t.x1, t.y1, t.x2, t.y2, center[0], center[1]);
        if (best == null or c.d < best.?.distance) best = .{
            .at = .{ c.x, c.y },
            .layer = t.layer,
            .width = t.width,
            .distance = c.d,
        };
    }
    return best;
}

/// Does some same-net run already carry a FULL trace-width cross-section onto
/// `pad`? That is the connectivity oracle's own reading, so the weld below has
/// nothing left to close: a spoke added beside such a run leaves the land and
/// lands back on it, which is precisely the shape `dangling_copper` names.
fn padAlreadyEntered(pad: PadObs, tracks: []const Track) bool {
    const shape = pad_shape.Shape{ .x0 = pad.x0, .y0 = pad.y0, .x1 = pad.x1, .y1 = pad.y1, .poly = pad.poly };
    for (tracks) |t| {
        if (t.net != pad.net or (!pad.thru and t.layer != pad.layer)) continue;
        if (copper_contact.padTrackConnects(shape, .{ t.x1, t.y1 }, .{ t.x2, t.y2 }, t.width)) return true;
    }
    return false;
}

const CenterJoin = struct {
    board: Board,
    probe: router.TautProbe,
    net: i32,
    layer: u8,
    width: f64,
};

fn appendCenterSegment(join: CenterJoin, a: [2]f64, b: [2]f64) std.mem.Allocator.Error!void {
    if (std.math.hypot(b[0] - a[0], b[1] - a[1]) < octilinear.min_heading_mm) return;
    try join.board.tracks.append(join.board.ctx.arena, .{
        .x1 = a[0],
        .y1 = a[1],
        .x2 = b[0],
        .y2 = b[1],
        .layer = join.layer,
        .width = join.width,
        .net = join.net,
    });
}

/// Append one clearance-checked H/V-first join, falling back to a direct short
/// diagonal stub only when neither orthogonal bend clears. This is the concrete
/// twin of `octilinear.emitJoin`; keeping it here avoids adding a public callback
/// type solely for one finishing pass.
fn appendCenterJoin(
    join: CenterJoin,
    pad: PadObs,
    a: [2]f64,
    b: [2]f64,
) std.mem.Allocator.Error!void {
    if (octilinear.isAxisAligned(a, b)) {
        if (join.probe.clear(join.layer, a, b)) try appendCenterSegment(join, a, b);
        return;
    }
    if (octilinear.isOctilinear(a, b)) {
        const horizontal = [2]f64{ b[0], a[1] };
        const vertical = [2]f64{ a[0], b[1] };
        const bends = if (pad.x1 - pad.x0 >= pad.y1 - pad.y0)
            [2][2]f64{ horizontal, vertical }
        else
            [2][2]f64{ vertical, horizontal };
        for (bends) |mid| {
            if (!join.probe.clear(join.layer, a, mid) or !join.probe.clear(join.layer, mid, b)) continue;
            try appendCenterSegment(join, a, mid);
            try appendCenterSegment(join, mid, b);
            return;
        }
        if (join.probe.clear(join.layer, a, b)) try appendCenterSegment(join, a, b);
        return;
    }
    for (octilinear.elbows(a, b)) |mid| {
        const first = std.math.hypot(mid[0] - a[0], mid[1] - a[1]) < octilinear.min_heading_mm or
            join.probe.clear(join.layer, a, mid);
        const second = std.math.hypot(b[0] - mid[0], b[1] - mid[1]) < octilinear.min_heading_mm or
            join.probe.clear(join.layer, mid, b);
        if (!first or !second) continue;
        try appendCenterSegment(join, a, mid);
        try appendCenterSegment(join, mid, b);
        return;
    }
    if (join.probe.clear(join.layer, a, b)) try appendCenterSegment(join, a, b);
}

/// Weld one selected net's traced signal pads to their exact centres (E11).
///
/// A trace capsule can graze one corner of a large land without carrying a full
/// trace-width cross-section onto it. The connectivity oracle now keeps that
/// weak contact open; this repair seam still recognizes the physical graze and
/// appends the shortest centre→trace join. The witness is the closest point on
/// that trace, so the added copper stays local to the pad; the octilinear seam
/// keeps ordinary joins on H/V/45 headings and the board probe guards clearance.
/// Plane-only pads and genuinely remote pads have no touching trace and are left
/// alone — and so is a pad some run already enters at full width, because there
/// the spoke would join nothing the land does not already join and the finish
/// would have to delete it again as `dangling_copper`.
fn weldNetPadCenters(board: Board, net: i32, probe: router.TautProbe) std.mem.Allocator.Error!void {
    for (board.ctx.obs) |pad| {
        if (pad.net != net) continue;
        if (padAlreadyEntered(pad, board.tracks.items)) continue;
        const target = padCenterTarget(pad, board.tracks.items) orelse continue;
        if (target.distance <= octilinear.min_heading_mm) continue;
        try appendCenterJoin(.{
            .board = board,
            .probe = probe,
            .net = net,
            .layer = target.layer,
            .width = target.width,
        }, pad, padObsCenter(pad), target.at);
    }
}

/// True when `p` sits (within `tol`) on the centre of one of net `net`'s pads —
/// the terminal test for the via-tail snap.
fn isNetPadCenter(board: Board, p: [2]f64, net: i32, tol: f64) bool {
    for (board.ctx.obs) |o| {
        if (o.net != net) continue;
        const c = padObsCenter(o);
        if (std.math.hypot(c[0] - p[0], c[1] - p[1]) <= tol) return true;
    }
    return false;
}

/// The pad-side endpoint of `t` when `t` is a terminal via-tail: a stub shorter
/// than `snap_max` with EXACTLY one end on the via centre. Returns null when
/// `t` is not such a tail. (E8) A gate stub whose maze entry node sat a
/// fraction of a pitch off the pad emits this tiny cross-layer tail (pad→via);
/// it reads as a sharp corner and a sub-width stub. The caller bounds
/// `snap_max` at half the track width: a shorter tail is entirely covered by
/// the via land plus the track's end cap (pure junk), while a longer one is a
/// real leg — the net's only copper on that layer in the cross-side case —
/// which must survive.
fn terminalTailPadSide(t: Track, via_x: f64, via_y: f64, snap_max: f64) ?[2]f64 {
    const len = std.math.hypot(t.x2 - t.x1, t.y2 - t.y1);
    if (len < 1e-9 or len > snap_max) return null;
    const a = [2]f64{ t.x1, t.y1 };
    const b = [2]f64{ t.x2, t.y2 };
    const a_on = std.math.hypot(a[0] - via_x, a[1] - via_y) < 1e-6;
    const b_on = std.math.hypot(b[0] - via_x, b[1] - via_y) < 1e-6;
    if (a_on == b_on) return null; // need exactly one end on the via
    return if (a_on) b else a;
}

/// True when via `vias[self_i]`, moved to (x,y), keeps DRC clearance from every
/// via (including its own net), foreign track (a via spans all layers), and pad,
/// plus the hole-to-hole wall from every other drill. Guards every pass that
/// RE-SITES a barrel — the terminal-via snap here and `via_centre`'s in-pad
/// centring — because even a sub-0.1 mm recentring can close a gap that was
/// already near the rule. The caller sets the net's params first, so the
/// clearance read is the moving via's own `(net-class …)` geometry.
pub fn viaSiteClears(board: Board, tracks: []const Track, vias: []const Via, self_i: usize, x: f64, y: f64) bool {
    const v = vias[self_i];
    const clr = board.ctx.params.clearance;
    const rule = via_rules.CopperRule{ .via_to_via = board.ctx.via_to_via, .via_dia = v.dia, .ordinary = clr };
    for (vias, 0..) |o, oi| {
        if (oi == self_i) continue;
        const d = std.math.hypot(x - o.x, y - o.y);
        const scope: via_rules.Scope = if (o.net == v.net) .same_net else .all;
        if (d < via_rules.pairCenterNeed(rule, o.dia, scope) - router.clearance_eps) return false;
        if (o.drill > 0 and v.drill > 0 and d > 1e-6 and
            d < v.drill / 2 + o.drill / 2 + board.ctx.hole_to_hole - router.clearance_eps) return false;
    }
    for (tracks) |t| {
        if (t.net == v.net) continue;
        const gap = segPointDist(t.x1, t.y1, t.x2, t.y2, x, y);
        if (gap < v.dia / 2 + t.width / 2 + clr - router.clearance_eps) return false;
    }
    for (board.ctx.obs) |o| {
        if (o.net == v.net) continue;
        const gap = pad_shape.pointDist(o.x0, o.y0, o.x1, o.y1, o.poly, x, y, v.dia / 2 + clr);
        if (gap < v.dia / 2 + clr - router.clearance_eps) return false;
    }
    return true;
}

/// The earlier same-net barrel a terminal snap would crowd, if any. Only an
/// earlier via may survive: it is the copper the route had already established,
/// and keeping that deterministic ownership matches `via_merge.plan`.
fn sameNetSnapCrowd(
    vias: []const Via,
    self_i: usize,
    x: f64,
    y: f64,
    via_to_via: f64,
    clearance: f64,
) ?usize {
    const v = vias[self_i];
    const rule = via_rules.CopperRule{ .via_to_via = via_to_via, .via_dia = v.dia, .ordinary = clearance };
    for (vias[0..self_i], 0..) |o, oi| {
        if (o.net != v.net) continue;
        const need = via_rules.pairCenterNeed(rule, o.dia, .same_net);
        if (std.math.hypot(x - o.x, y - o.y) < need - router.clearance_eps) return oi;
    }
    return null;
}

/// `t` with every endpoint on `drop` moved onto `keep`, or null when the track
/// does not terminate at that barrel. A terminal tail therefore becomes a real
/// pad-to-surviving-via trace instead of being discarded with the duplicate.
fn reanchoredTrack(t: Track, drop: Via, keep: Via) ?Track {
    if (t.net != drop.net or keep.net != drop.net) return null;
    var out = t;
    var moved = false;
    if (std.math.hypot(t.x1 - drop.x, t.y1 - drop.y) <= hop_snap_mm) {
        out.x1 = keep.x;
        out.y1 = keep.y;
        moved = true;
    }
    if (std.math.hypot(t.x2 - drop.x, t.y2 - drop.y) <= hop_snap_mm) {
        out.x2 = keep.x;
        out.y2 = keep.y;
        moved = true;
    }
    return if (moved) out else null;
}

/// Replace `drop_i` with the already-established `keep_i` barrel. Every copper
/// leg incident on the dropped via is first re-probed at its re-anchored shape;
/// a blocked leg or a via that alone joins a pour refuses the fold.
fn foldViaOnto(board: Board, drop_i: usize, keep_i: usize) bool {
    if (keep_i >= drop_i or drop_i >= board.vias.items.len) return false;
    const drop = board.vias.items[drop_i];
    const keep = board.vias.items[keep_i];
    if (drop.net != keep.net or drop.net < 0) return false;
    if (router.netPourCovers(board.ctx, drop.net, drop.x, drop.y, null)) return false;
    const probe = router.TautProbe{ .run = .{
        .ctx = board.ctx,
        .net = drop.net,
        .tracks = board.tracks,
        .vias = board.vias,
    } };
    var moved: usize = 0;
    for (board.tracks.items) |t| {
        const candidate = reanchoredTrack(t, drop, keep) orelse continue;
        const a = [2]f64{ candidate.x1, candidate.y1 };
        const b = [2]f64{ candidate.x2, candidate.y2 };
        if (!probe.clear(candidate.layer, a, b)) return false;
        moved += 1;
    }
    if (moved == 0) return false;
    for (board.tracks.items) |*t| {
        if (reanchoredTrack(t.*, drop, keep)) |candidate| t.* = candidate;
    }
    board.vias.items[drop_i].net = cleanup_removed_net;
    removeNetVias(board.vias, cleanup_removed_net);
    return true;
}

/// Snap a terminal via that landed a sliver off its pad centre onto the pad and
/// drop the sub-epsilon tail joining them (E8). The via sits inside the pad's
/// own land, so recentring it and dropping the tail leaves the net connected
/// (the main trace end stays within the moved via's land) while removing the
/// junk sharp corner. A snap that would close a FOREIGN clearance below the
/// rule is refused (the tail stays — cosmetic beats a new DRC error).
pub fn snapTerminalVias(board: Board) void {
    const tracks = board.tracks;
    const vias = board.vias;
    while (true) {
        var changed = false;
        scan: for (tracks.items, 0..) |t, ti| {
            if (t.net == cleanup_removed_net or t.net < 0) continue;
            if (!mayRewrite(board.ctx.selected_nets, t.net)) continue;
            for (vias.items, 0..) |v, vi| {
                if (v.net != t.net) continue;
                const pad_side = terminalTailPadSide(t, v.x, v.y, @min(v.dia / 4, t.width / 2)) orelse continue;
                if (!isNetPadCenter(board, pad_side, t.net, net_open_slack_mm)) continue;
                router.setNetParams(board.ctx, board.placement, @intCast(t.net)); // per-net clearance for the guard
                if (viaSiteClears(board, tracks.items, vias.items, vi, pad_side[0], pad_side[1])) {
                    vias.items[vi].x = pad_side[0];
                    vias.items[vi].y = pad_side[1];
                    tracks.items[ti].net = cleanup_removed_net; // mark the tail for removal
                    removeNetTracks(tracks, cleanup_removed_net);
                    router.copperCompacted(board.ctx);
                    changed = true;
                    break :scan;
                }
                const keep_i = sameNetSnapCrowd(
                    vias.items,
                    vi,
                    pad_side[0],
                    pad_side[1],
                    board.ctx.via_to_via,
                    board.ctx.params.clearance,
                ) orelse continue;
                if (!foldViaOnto(board, vi, keep_i)) continue;
                router.copperCompacted(board.ctx);
                changed = true;
                break :scan;
            }
        }
        if (!changed) return;
    }
}

/// The extreme pad pair `{a,b}` of `pts` when EVERY pad sits within `tol` of the
/// segment through that pair — i.e. the whole net collapses to one straight
/// through-line covering every pad centre (E1). Null when the pads are not
/// collinear (or fewer than two). Because {a,b} is the max-distance pair, a pad
/// beyond an endpoint is caught by the segment (not infinite-line) distance.
fn collinearExtremes(pts: []const [2]f64, tol: f64) ?[2]usize {
    if (pts.len < 2) return null;
    var ai: usize = 0;
    var bi: usize = 1;
    var best: f64 = -1;
    for (pts, 0..) |pa, i| for (pts[i + 1 ..], i + 1..) |pb, j| {
        const d = std.math.hypot(pb[0] - pa[0], pb[1] - pa[1]);
        if (d > best) {
            best = d;
            ai = i;
            bi = j;
        }
    };
    if (best <= 1e-6) return null;
    const a = pts[ai];
    const b = pts[bi];
    for (pts) |p| {
        if (segPointDist(a[0], a[1], b[0], b[1], p[0], p[1]) > tol) return null;
    }
    return .{ ai, bi };
}

/// Collapse each collinear multi-pad net to ONE straight through-line (E1).
/// A join that visited its collinear pads out of geometric order leaves a
/// doubling-back hairball no local corner-cut can fix (the chain's endpoints do
/// not even span the middle pad). When the net's pads are collinear, its ideal
/// IS the single segment spanning the two extreme pads — it passes through every
/// middle pad, so it is connected by construction and, being an RF net's best
/// possible shape, has no bend to smooth. Gated to single-layer, via-free nets
/// whose straight line clears the finished board; a blocked line keeps the maze
/// copper.
pub fn collapseCollinearNets(board: Board) std.mem.Allocator.Error!void {
    const ctx = board.ctx;
    const placement = board.placement;
    const tracks = board.tracks;
    const vias = board.vias;
    var idx_of = std.StringHashMapUnmanaged(usize).empty;
    for (placement.parts, 0..) |p, i| try idx_of.put(ctx.arena, p.ref_des, i);
    for (0..placement.nets.len) |net_i| {
        const ni: i32 = @intCast(net_i);
        if (!mayRewrite(ctx.selected_nets, ni)) continue; // retained copper echoes verbatim
        if (netIsDiffPairLeg(placement, net_i)) continue; // pairs collapse in lock-step, not per-leg
        var has_via = false;
        for (vias.items) |v| if (v.net == ni) {
            has_via = true;
            break;
        };
        if (has_via) continue;
        // Every track on one layer L, and at least one track.
        var layer: ?u8 = null;
        var mixed = false;
        for (tracks.items) |t| {
            if (t.net != ni) continue;
            if (layer) |l| {
                if (t.layer != l) {
                    mixed = true;
                    break;
                }
            } else layer = t.layer;
        }
        if (mixed) continue;
        const l = layer orelse continue;
        const netpts = try router.netPoints(ctx.arena, placement, &idx_of, placement.nets[net_i]);
        if (netpts.len < collinear_min_pads) continue;
        // Every pad reachable on L (own-side, or a through-hole barrel).
        var reachable = true;
        const xy = try ctx.arena.alloc([2]f64, netpts.len);
        for (netpts, xy) |p, *q| {
            if (!p.thru and p.layer != l) reachable = false;
            q.* = .{ p.x, p.y };
        }
        if (!reachable) continue;
        router.setNetParams(ctx, placement, net_i); // the probe + track width read this net's rule
        // An earlier net's collapse packed the track list down, which aliases
        // every copper-index entry — restamp the index here, after
        // `setNetParams` (its insertion reach derives from this net's rule), so
        // this net's probe runs indexed instead of falling back to the scan.
        router.rebuildCopperIndex(ctx, tracks.items, vias.items);
        const ends = collinearExtremes(xy, ctx.params.track_width / 2) orelse continue;
        const a = xy[ends[0]];
        const b = xy[ends[1]];
        // This replaces a whole net's copper with ONE pad-to-pad line, the
        // highest-length-per-hit way to smuggle an arbitrary heading onto the
        // board: pads collinear to within half a track width can still sit on an
        // off-axis line. Keep the maze's disciplined copper in that case.
        if (!octilinear.isAxisAligned(a, b)) continue;
        const probe = router.TautProbe{ .run = .{ .ctx = ctx, .net = ni, .tracks = tracks, .vias = vias } };
        if (!probe.clear(l, a, b)) continue;
        removeNetTracks(tracks, ni);
        router.copperCompacted(ctx); // survivors packed down — the index is aliased until the next net rebuilds it
        try tracks.append(ctx.arena, .{ .x1 = a[0], .y1 = a[1], .x2 = b[0], .y2 = b[1], .layer = l, .width = ctx.params.track_width, .net = ni });
        _ = ctx.rf.net_smooth.remove(ni); // a straight line carries no arc/sharp metadata
    }
}

// ── Adjacent same-net branch fusion ─────────────────────────────────────────

const ParallelRun = struct { separation: f64, overlap: f64 };

/// The common longitudinal span and lane separation of two almost-parallel
/// tracks. Null excludes short coincidences and diverging runs: this cleanup is
/// for two real route legs occupying adjacent lanes, not arbitrary nearby
/// copper.
fn parallelRun(a: Track, b: Track) ?ParallelRun {
    const ad = [2]f64{ a.x2 - a.x1, a.y2 - a.y1 };
    const bd = [2]f64{ b.x2 - b.x1, b.y2 - b.y1 };
    const al = std.math.hypot(ad[0], ad[1]);
    const bl = std.math.hypot(bd[0], bd[1]);
    if (al <= min_emit_seg_mm or bl <= min_emit_seg_mm) return null;
    const au = [2]f64{ ad[0] / al, ad[1] / al };
    const bu = [2]f64{ bd[0] / bl, bd[1] / bl };
    if (@abs(au[0] * bu[1] - au[1] * bu[0]) > parallel_sin_tol) return null;

    const rel0 = [2]f64{ b.x1 - a.x1, b.y1 - a.y1 };
    const rel1 = [2]f64{ b.x2 - a.x1, b.y2 - a.y1 };
    const t0 = rel0[0] * au[0] + rel0[1] * au[1];
    const t1 = rel1[0] * au[0] + rel1[1] * au[1];
    const overlap = @max(@min(al, @max(t0, t1)) - @max(0, @min(t0, t1)), 0);
    const sep0 = @abs(rel0[0] * au[1] - rel0[1] * au[0]);
    const sep1 = @abs(rel1[0] * au[1] - rel1[1] * au[0]);
    if (@abs(sep0 - sep1) > @max(a.width, b.width) * parallel_separation_drift_widths) return null;
    return .{ .separation = (sep0 + sep1) / 2, .overlap = overlap };
}

const Fusion = struct {
    target: usize,
    replacement: [2]Track,
    replacement_len: usize,
};

const FusionConnector = struct { tracks: [2]Track, len: usize };

fn supportNode(np: usize, nt: usize, support_i: usize) usize {
    return if (support_i < np)
        support_i
    else
        np + nt + support_i - np;
}

/// A fusion may join formerly separate same-net islands, but it may never tear
/// apart pads or vias that the original copper joined. Compare the support
/// partition before and after the proposed rewrite; track-only leaves are not
/// supports and the ordinary dead-copper pass may remove them afterward.
fn preservesSupportConnectivity(
    arena: std.mem.Allocator,
    pads: []const PadObs,
    before: []const Track,
    after: []const Track,
    vias: []const Via,
) std.mem.Allocator.Error!bool {
    var before_parent: []usize = &.{};
    var after_parent: []usize = &.{};
    _ = try countCopperIslands(arena, pads, before, vias, &before_parent);
    _ = try countCopperIslands(arena, pads, after, vias, &after_parent);
    const support_count = pads.len + vias.len;
    for (0..support_count) |i| for (i + 1..support_count) |j| {
        const bi = supportNode(pads.len, before.len, i);
        const bj = supportNode(pads.len, before.len, j);
        if (ufFind(before_parent, bi) != ufFind(before_parent, bj)) continue;
        const ai = supportNode(pads.len, after.len, i);
        const aj = supportNode(pads.len, after.len, j);
        if (ufFind(after_parent, ai) != ufFind(after_parent, aj)) return false;
    };
    return true;
}

fn replacementLength(replacement: [2]Track, len: usize) f64 {
    var total: f64 = 0;
    for (replacement[0..len]) |track|
        total += std.math.hypot(track.x2 - track.x1, track.y2 - track.y1);
    return total;
}

/// The shortest clearing H/V/45 connection from `from` to `to`. A straight
/// octilinear pair degenerates to one emitted leg; an off-grid pair tries both
/// canonical elbows. The returned tracks inherit the branch's net/layer/width.
fn fusionConnector(comptime Probe: type, template: Track, from: [2]f64, to: [2]f64, probe: Probe) ?FusionConnector {
    var best: ?FusionConnector = null;
    for (octilinear.elbows(from, to)) |mid| {
        var candidate: [2]Track = @splat(template);
        var n: usize = 0;
        for ([_][2][2]f64{ .{ from, mid }, .{ mid, to } }) |leg| {
            if (std.math.hypot(leg[1][0] - leg[0][0], leg[1][1] - leg[0][1]) <= min_emit_seg_mm) continue;
            if (!probe.clear(template.layer, leg[0], leg[1])) {
                n = 0;
                break;
            }
            candidate[n] = .{
                .x1 = leg[0][0],
                .y1 = leg[0][1],
                .x2 = leg[1][0],
                .y2 = leg[1][1],
                .layer = template.layer,
                .width = template.width,
                .net = template.net,
            };
            n += 1;
        }
        if (n == 0) continue;
        if (best == null or replacementLength(candidate, n) < replacementLength(best.?.tracks, best.?.len))
            best = .{ .tracks = candidate, .len = n };
    }
    return best;
}

/// Candidate landing points on `trunk` for a nearby branch endpoint. The
/// perpendicular projection is shortest, but a dense pad row can block that
/// exact cross-lane hop while either neighbouring 45-degree landing remains
/// clear. Moving one lane separation along the trunk produces those two
/// canonical landings for horizontal, vertical, and 45-degree router runs.
fn fusionLandings(trunk: Track, from: [2]f64, separation: f64) [3]?[2]f64 {
    const closest = pad_shape.closestOnSeg(trunk.x1, trunk.y1, trunk.x2, trunk.y2, from[0], from[1]);
    var out: [3]?[2]f64 = .{ .{ closest.x, closest.y }, null, null };
    const dx = trunk.x2 - trunk.x1;
    const dy = trunk.y2 - trunk.y1;
    const len = std.math.hypot(dx, dy);
    if (len <= min_emit_seg_mm) return out;
    const ux = dx / len;
    const uy = dy / len;
    const along = (closest.x - trunk.x1) * ux + (closest.y - trunk.y1) * uy;
    for ([_]f64{ -separation, separation }, 1..) |delta, i| {
        const shifted = along + delta;
        if (shifted < -junction_eps_mm or shifted > len + junction_eps_mm) continue;
        const clamped = std.math.clamp(shifted, 0, len);
        out[i] = .{ trunk.x1 + clamped * ux, trunk.y1 + clamped * uy };
    }
    return out;
}

fn padPairCentres(a: PadObs, b: PadObs, pitch: f64) ?[2][2]f64 {
    if (a.net < 0 or a.net != b.net or a.layer != b.layer) return null;
    if (a.thru or b.thru) return null;
    const aw = a.x1 - a.x0;
    const ah = a.y1 - a.y0;
    const bw = b.x1 - b.x0;
    const bh = b.y1 - b.y0;
    if (@abs(aw - bw) > junction_eps_mm or @abs(ah - bh) > junction_eps_mm) return null;
    const ac = padObsCenter(a);
    const bc = padObsCenter(b);
    const same_column = @abs(ac[0] - bc[0]) <= junction_eps_mm and
        @abs(a.x0 - b.x0) <= junction_eps_mm and @abs(a.x1 - b.x1) <= junction_eps_mm;
    const same_row = @abs(ac[1] - bc[1]) <= junction_eps_mm and
        @abs(a.y0 - b.y0) <= junction_eps_mm and @abs(a.y1 - b.y1) <= junction_eps_mm;
    if (!same_column and !same_row) return null;
    const gap = pad_shape.shapeGap(
        .{ .x0 = a.x0, .y0 = a.y0, .x1 = a.x1, .y1 = a.y1, .poly = a.poly },
        .{ .x0 = b.x0, .y0 = b.y0, .x1 = b.x1, .y1 = b.y1, .poly = b.poly },
        std.math.inf(f64),
    );
    if (gap > pitch + junction_eps_mm) return null;
    return .{ ac, bc };
}

fn endpointInPad(track: Track, pad: PadObs, first: bool) bool {
    return if (first)
        pointInPad(pad, track.x1, track.y1)
    else
        pointInPad(pad, track.x2, track.y2);
}

fn trackLeavesOnlyPad(track: Track, pad: PadObs, other: PadObs) bool {
    const a_here = endpointInPad(track, pad, true);
    const b_here = endpointInPad(track, pad, false);
    if (a_here == b_here) return false;
    const outside = if (a_here) [2]f64{ track.x2, track.y2 } else [2]f64{ track.x1, track.y1 };
    return !pointInPad(other, outside[0], outside[1]);
}

/// Replace one independently-routed escape from an adjacent same-net land pair
/// with the direct land-to-land strap. The support-partition proof rejects a
/// candidate unless every pad/via relationship the old escape carried remains
/// reachable; the final dead-copper pass then removes the abandoned detour.
fn findAdjacentPadFusion(
    comptime Probe: type,
    arena: std.mem.Allocator,
    pads: []const PadObs,
    tracks: []const Track,
    vias: []const Via,
    pitch: f64,
    probe: Probe,
) std.mem.Allocator.Error!?Fusion {
    for (pads, 0..) |a, a_i| for (pads[a_i + 1 ..]) |b| {
        const centres = padPairCentres(a, b, pitch) orelse continue;
        var target_i = tracks.len;
        while (target_i > 0) {
            target_i -= 1;
            const target = tracks[target_i];
            if (target.net != a.net or target.layer != a.layer) continue;
            const leaves_a = trackLeavesOnlyPad(target, a, b);
            const leaves_b = trackLeavesOnlyPad(target, b, a);
            if (!leaves_a and !leaves_b) continue;
            if (!probe.clear(target.layer, centres[0], centres[1])) continue;
            const strap = Track{
                .x1 = centres[0][0],
                .y1 = centres[0][1],
                .x2 = centres[1][0],
                .y2 = centres[1][1],
                .layer = target.layer,
                .width = target.width,
                .net = target.net,
            };
            var after: std.ArrayList(Track) = .empty;
            try after.ensureTotalCapacity(arena, tracks.len);
            for (tracks, 0..) |track, i| after.appendAssumeCapacity(if (i == target_i) strap else track);
            if (!try preservesSupportConnectivity(arena, pads, tracks, after.items, vias)) continue;
            return .{ .target = target_i, .replacement = .{ strap, undefined }, .replacement_len = 1 };
        }
    };
    return null;
}

/// Find one newer adjacent branch that can fold into an older trunk. Storage
/// order is intentional: routing appends new terminal legs onto established
/// copper, and the redundancy oracle follows the same newest-first policy.
/// Replacing the newer leg also keeps stable geometry stable when several
/// equivalent trunks exist.
fn findParallelFusion(
    comptime Probe: type,
    arena: std.mem.Allocator,
    pads: []const PadObs,
    tracks: []const Track,
    vias: []const Via,
    clearance: f64,
    probe: Probe,
) std.mem.Allocator.Error!?Fusion {
    if (tracks.len < 2) return null;
    var tested: usize = 0;
    var target_i = tracks.len;
    while (target_i > 1) {
        target_i -= 1;
        const target = tracks[target_i];
        var trunk_i: usize = 0;
        while (trunk_i < target_i) : (trunk_i += 1) {
            const trunk = tracks[trunk_i];
            if (target.net != trunk.net or target.layer != trunk.layer) continue;
            if (@abs(target.width - trunk.width) > junction_eps_mm) continue;
            const run = parallelRun(trunk, target) orelse continue;
            const pitch = @max(target.width, trunk.width) + clearance;
            if (run.separation < @min(target.width, trunk.width) * parallel_min_separation_widths or
                run.separation > pitch * parallel_max_separation_pitches + junction_eps_mm or
                run.overlap < @max(target.width, trunk.width) * parallel_min_overlap_widths) continue;
            if (tested >= max_parallel_candidates_per_fusion) return null;
            tested += 1;

            const ends = [2][2]f64{ .{ target.x1, target.y1 }, .{ target.x2, target.y2 } };
            for (ends) |from| {
                for (fusionLandings(trunk, from, run.separation)) |landing| {
                    const to = landing orelse continue;
                    const connector = fusionConnector(Probe, target, from, to, probe) orelse continue;
                    const connector_len = replacementLength(connector.tracks, connector.len);
                    const target_len = std.math.hypot(target.x2 - target.x1, target.y2 - target.y1);
                    if (connector_len > pitch * parallel_max_connector_pitches or
                        target_len - connector_len < target.width) continue;

                    var after: std.ArrayList(Track) = .empty;
                    try after.ensureTotalCapacity(arena, tracks.len - 1 + connector.len);
                    for (tracks, 0..) |track, i| if (i != target_i) after.appendAssumeCapacity(track);
                    after.appendSliceAssumeCapacity(connector.tracks[0..connector.len]);
                    if (!try preservesSupportConnectivity(arena, pads, tracks, after.items, vias)) continue;
                    return .{ .target = target_i, .replacement = connector.tracks, .replacement_len = connector.len };
                }
            }
        }
    }
    return null;
}

/// Consolidate the repeated pin comb produced by adjacent same-net lands. This
/// is deliberately a geometry rule rather than a footprint/refdes exception,
/// so regulator, converter, and connector pad rows receive the same cleanup.
pub fn mergeAdjacentPadEscapes(board: Board) std.mem.Allocator.Error!void {
    for (0..board.placement.nets.len) |net_i| {
        const ni: i32 = @intCast(net_i);
        if (!mayRewrite(board.ctx.selected_nets, ni)) continue;
        if (netIsDiffPairLeg(board.placement, net_i)) continue;
        router.setNetParams(board.ctx, board.placement, net_i);
        var merges: usize = 0;
        while (merges < max_adjacent_pad_fusions_per_net) : (merges += 1) {
            router.rebuildCopperIndex(board.ctx, board.tracks.items, board.vias.items);
            var mine: std.ArrayList(Track) = .empty;
            var global: std.ArrayList(usize) = .empty;
            var pads: std.ArrayList(PadObs) = .empty;
            var vias: std.ArrayList(Via) = .empty;
            for (board.tracks.items, 0..) |track, i| if (track.net == ni) {
                try mine.append(board.ctx.arena, track);
                try global.append(board.ctx.arena, i);
            };
            for (board.ctx.obs) |pad| if (pad.net == ni) try pads.append(board.ctx.arena, pad);
            for (board.vias.items) |via| if (via.net == ni) try vias.append(board.ctx.arena, via);
            const probe = router.TautProbe{ .run = .{ .ctx = board.ctx, .net = ni, .tracks = board.tracks, .vias = board.vias } };
            const fusion = (try findAdjacentPadFusion(
                router.TautProbe,
                board.ctx.arena,
                pads.items,
                mine.items,
                vias.items,
                board.ctx.params.track_width + board.ctx.params.clearance,
                probe,
            )) orelse break;
            board.tracks.items[global.items[fusion.target]] = fusion.replacement[0];
            router.copperCompacted(board.ctx);
        }
    }
}

/// Fold adjacent same-net terminal legs into one shared trunk. A candidate is
/// accepted only when its replacement is DRC-clear and preserves the complete
/// pre-rewrite pad/via connectivity partition. Diff-pair legs stay coupled and
/// retained scoped copper remains byte-identical.
pub fn mergeParallelBranches(board: Board) std.mem.Allocator.Error!void {
    for (0..board.placement.nets.len) |net_i| {
        const ni: i32 = @intCast(net_i);
        if (!mayRewrite(board.ctx.selected_nets, ni)) continue;
        if (netIsDiffPairLeg(board.placement, net_i)) continue;
        router.setNetParams(board.ctx, board.placement, net_i);
        var merges: usize = 0;
        while (merges < max_parallel_fusions_per_net) : (merges += 1) {
            router.rebuildCopperIndex(board.ctx, board.tracks.items, board.vias.items);
            var mine: std.ArrayList(Track) = .empty;
            var global: std.ArrayList(usize) = .empty;
            var pads: std.ArrayList(PadObs) = .empty;
            var vias: std.ArrayList(Via) = .empty;
            for (board.tracks.items, 0..) |track, i| if (track.net == ni) {
                try mine.append(board.ctx.arena, track);
                try global.append(board.ctx.arena, i);
            };
            for (board.ctx.obs) |pad| if (pad.net == ni) try pads.append(board.ctx.arena, pad);
            for (board.vias.items) |via| if (via.net == ni) try vias.append(board.ctx.arena, via);
            const probe = router.TautProbe{ .run = .{ .ctx = board.ctx, .net = ni, .tracks = board.tracks, .vias = board.vias } };
            const fusion = (try findParallelFusion(
                router.TautProbe,
                board.ctx.arena,
                pads.items,
                mine.items,
                vias.items,
                board.ctx.params.clearance,
                probe,
            )) orelse break;
            const target_global = global.items[fusion.target];
            board.tracks.items[target_global] = fusion.replacement[0];
            if (fusion.replacement_len == 2)
                try board.tracks.append(board.ctx.arena, fusion.replacement[1]);
            router.copperCompacted(board.ctx);
        }
    }
}

const AlwaysClearFusionProbe = struct {
    fn clear(_: @This(), _: u8, _: [2]f64, _: [2]f64) bool {
        return true;
    }
};

const BlockPerpendicularFusionProbe = struct {
    fn clear(_: @This(), _: u8, a: [2]f64, b: [2]f64) bool {
        return @abs(b[1] - a[1]) > junction_eps_mm;
    }
};

fn applyFusionFixture(arena: std.mem.Allocator, tracks: []const Track, fusion: Fusion) std.mem.Allocator.Error![]const Track {
    var after: std.ArrayList(Track) = .empty;
    for (tracks, 0..) |track, i| {
        if (i != fusion.target) try after.append(arena, track);
    }
    try after.appendSlice(arena, fusion.replacement[0..fusion.replacement_len]);
    return after.items;
}

// spec: placement/router - adjacent same-net branches merge into an established trunk without losing any terminal connection
test "parallel same-net terminal legs fold into one shared trunk" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const width = 0.2532;
    const a = [2]f64{ 159.20000000000005, 98.12000000000002 };
    const b = [2]f64{ 160.9032613427087, 96.40840018177056 };
    const c = [2]f64{ 158.10000000000002, 98.69166152447922 };
    const d = [2]f64{ 159.77492286718785, 97.01673865729137 };
    const closest = pad_shape.closestOnSeg(a[0], a[1], b[0], b[1], d[0], d[1]);
    const tracks = [_]Track{
        .{ .x1 = 159.2, .y1 = 98.72, .x2 = a[0], .y2 = a[1], .layer = 0, .width = width, .net = 0 },
        .{ .x1 = a[0], .y1 = a[1], .x2 = b[0], .y2 = b[1], .layer = 0, .width = width, .net = 0 },
        .{ .x1 = 158.1, .y1 = 99.3, .x2 = c[0], .y2 = c[1], .layer = 0, .width = width, .net = 0 },
        .{ .x1 = c[0], .y1 = c[1], .x2 = d[0], .y2 = d[1], .layer = 0, .width = width, .net = 0 },
        .{ .x1 = d[0], .y1 = d[1], .x2 = closest.x, .y2 = closest.y, .layer = 0, .width = width, .net = 0 },
    };
    const pads = [_]PadObs{
        .{ .x0 = 159.0, .y0 = 98.52, .x1 = 159.4, .y1 = 98.92, .net = 0, .layer = 0 },
        .{ .x0 = 157.9, .y0 = 99.1, .x1 = 158.3, .y1 = 99.5, .net = 0, .layer = 0 },
        .{ .x0 = b[0] - 0.2, .y0 = b[1] - 0.2, .x1 = b[0] + 0.2, .y1 = b[1] + 0.2, .net = 0, .layer = 0 },
    };
    const fusion = (try findParallelFusion(AlwaysClearFusionProbe, arena, &pads, &tracks, &.{}, 0.127, AlwaysClearFusionProbe{})).?;
    try std.testing.expectEqual(@as(usize, 3), fusion.target);
    try std.testing.expect(fusion.replacement_len >= 1);
    try std.testing.expect(replacementLength(fusion.replacement, fusion.replacement_len) + width <
        std.math.hypot(d[0] - c[0], d[1] - c[1]));

    const after = try applyFusionFixture(arena, &tracks, fusion);
    try std.testing.expect(try preservesSupportConnectivity(arena, &pads, &tracks, after, &.{}));
}

// spec: placement/router - a blocked perpendicular branch fusion tries the adjacent 45-degree trunk landings before retaining a parallel same-net run
test "parallel branch uses a clear diagonal trunk landing when the perpendicular hop is blocked" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const width = 0.2532;
    const trunk_top = [2]f64{ 167.45, 109.15 };
    const trunk_bottom = [2]f64{ 167.45, 111.535 };
    const branch_top = [2]f64{ 167.1439339828221, 109.456066017178 };
    const branch_bottom = [2]f64{ 167.1439339828221, 110.53227245834286 };
    const leaf = [2]f64{ 166.43, 110.53227245834286 };
    const tracks = [_]Track{
        .{ .x1 = trunk_top[0], .y1 = trunk_top[1], .x2 = trunk_bottom[0], .y2 = trunk_bottom[1], .layer = 0, .width = width, .net = 0 },
        .{ .x1 = trunk_top[0], .y1 = trunk_top[1], .x2 = branch_top[0], .y2 = branch_top[1], .layer = 0, .width = width, .net = 0 },
        .{ .x1 = branch_top[0], .y1 = branch_top[1], .x2 = branch_bottom[0], .y2 = branch_bottom[1], .layer = 0, .width = width, .net = 0 },
        .{ .x1 = branch_bottom[0], .y1 = branch_bottom[1], .x2 = leaf[0], .y2 = leaf[1], .layer = 0, .width = width, .net = 0 },
    };
    const pads = [_]PadObs{
        .{ .x0 = trunk_top[0] - 0.2, .y0 = trunk_top[1] - 0.2, .x1 = trunk_top[0] + 0.2, .y1 = trunk_top[1] + 0.2, .net = 0, .layer = 0 },
        .{ .x0 = trunk_bottom[0] - 0.2, .y0 = trunk_bottom[1] - 0.2, .x1 = trunk_bottom[0] + 0.2, .y1 = trunk_bottom[1] + 0.2, .net = 0, .layer = 0 },
        .{ .x0 = leaf[0] - 0.2, .y0 = leaf[1] - 0.2, .x1 = leaf[0] + 0.2, .y1 = leaf[1] + 0.2, .net = 0, .layer = 0 },
    };

    const fusion = (try findParallelFusion(BlockPerpendicularFusionProbe, arena, &pads, &tracks, &.{}, 0.127, BlockPerpendicularFusionProbe{})).?;
    try std.testing.expectEqual(@as(usize, 2), fusion.target);
    try std.testing.expectEqual(@as(usize, 1), fusion.replacement_len);
    const replacement = fusion.replacement[0];
    try std.testing.expectApproxEqAbs(@abs(replacement.x2 - replacement.x1), @abs(replacement.y2 - replacement.y1), 1e-9);
    const after = try applyFusionFixture(arena, &tracks, fusion);
    try std.testing.expect(try preservesSupportConnectivity(arena, &pads, &tracks, after, &.{}));
}

// spec: placement/router - adjacent same-net SMD lands share one escape instead of retaining a multi-leg pad comb
test "adjacent same-net lands replace a redundant independent escape with a strap" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const width = 0.2532;
    const pads = [_]PadObs{
        .{ .x0 = -0.4, .y0 = -0.15, .x1 = 0.4, .y1 = 0.15, .net = 0, .layer = 0 },
        .{ .x0 = -0.4, .y0 = 0.35, .x1 = 0.4, .y1 = 0.65, .net = 0, .layer = 0 },
        .{ .x0 = 1.8, .y0 = 0.3, .x1 = 2.2, .y1 = 0.7, .net = 0, .layer = 0 },
    };
    const tracks = [_]Track{
        .{ .x1 = 0, .y1 = 0.5, .x2 = 1, .y2 = 0.5, .layer = 0, .width = width, .net = 0 },
        .{ .x1 = 1, .y1 = 0.5, .x2 = 2, .y2 = 0.5, .layer = 0, .width = width, .net = 0 },
        .{ .x1 = 0.25, .y1 = 0.25, .x2 = 1, .y2 = 0.5, .layer = 0, .width = width, .net = 0 },
        .{ .x1 = 0, .y1 = 0, .x2 = 0.25, .y2 = 0.25, .layer = 0, .width = width, .net = 0 },
    };
    const fusion = (try findAdjacentPadFusion(AlwaysClearFusionProbe, arena, &pads, &tracks, &.{}, width + 0.127, AlwaysClearFusionProbe{})).?;
    try std.testing.expectEqual(@as(usize, 3), fusion.target);
    const strap = fusion.replacement[0];
    try std.testing.expectApproxEqAbs(@as(f64, 0), strap.x1, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0), strap.y1, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0), strap.x2, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), strap.y2, 1e-12);
    const after = try applyFusionFixture(arena, &tracks, fusion);
    try std.testing.expect(try preservesSupportConnectivity(arena, &pads, &tracks, after, &.{}));
}

// spec: placement/router - same-net runs separated by one intervening routing lane still consolidate into the shorter trunk
test "parallel branch across one intervening lane still fuses" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const width = 0.127;
    const tracks = [_]Track{
        .{ .x1 = 183.68, .y1 = 101.9, .x2 = 183.68, .y2 = 101.44, .layer = 0, .width = width, .net = 0 },
        .{ .x1 = 183.68, .y1 = 101.44, .x2 = 183.69, .y2 = 100.37, .layer = 0, .width = width, .net = 0 },
        .{ .x1 = 183.69, .y1 = 100.37, .x2 = 183.69, .y2 = 99.9, .layer = 0, .width = width, .net = 0 },
        .{ .x1 = 183.25, .y1 = 103.05, .x2 = 183.25, .y2 = 100.34, .layer = 0, .width = width, .net = 0 },
        .{ .x1 = 183.25, .y1 = 100.34, .x2 = 183.69, .y2 = 99.9, .layer = 0, .width = width, .net = 0 },
    };
    const pads = [_]PadObs{
        .{ .x0 = 183.05, .y0 = 102.85, .x1 = 183.45, .y1 = 103.25, .net = 0, .layer = 0 },
        .{ .x0 = 183.48, .y0 = 101.7, .x1 = 183.88, .y1 = 102.1, .net = 0, .layer = 0 },
        .{ .x0 = 183.49, .y0 = 99.7, .x1 = 183.89, .y1 = 100.1, .net = 0, .layer = 0 },
    };
    const fusion = (try findParallelFusion(AlwaysClearFusionProbe, arena, &pads, &tracks, &.{}, 0.127, AlwaysClearFusionProbe{})).?;
    try std.testing.expectEqual(@as(usize, 3), fusion.target);
    const after = try applyFusionFixture(arena, &tracks, fusion);
    try std.testing.expect(try preservesSupportConnectivity(arena, &pads, &tracks, after, &.{}));
}

// ── Redundant layer hops (E10) ───────────────────────────────────────────────

/// "This track end sits on that via" tolerance — the router emits both from the
/// same grid node, so this only absorbs float drift. The hop scan's own copy of
/// the tolerance, so the two never disagree about what "on" means.
const hop_snap_mm: f64 = via_hop_scan.snap_mm;
/// Removals attempted per net. Each success deletes two vias, so this is far
/// above any real net's via count.
const max_hops_per_net: usize = 64;
/// Below this the two vias are effectively the same point and there is no
/// replacement copper to draw.
const min_hop_span_mm: f64 = 1e-3;
/// Widest agreement (as a cosine) between the replacement elbow's leg and the
/// copper already leaving that via before the replacement counts as doubling
/// back over it. cos 45°, so a leg must turn at least one octilinear step away
/// from the existing chain.
const back_cos_max: f64 = 0.7071;

/// Do two points coincide within the hop tolerance? The scan's own predicate,
/// so this pass and the detector answer "same point" identically.
const ptEq = via_hop_scan.ptEq;

/// May this via be deleted by the hop pass, given the replacement will be drawn
/// on layer `outer`? Not when it lands on one of the net's pads (a terminal
/// via, the net's only reach onto that layer), and not when it taps the net's
/// OWN pour on any layer BUT `outer` — the island model does not carry pours,
/// so that connection is invisible here and deleting the via would silently
/// strand copper. A tap on `outer` itself is safe to drop: the outer chain's
/// endpoint stays exactly where the via was, still inside the pour, so it keeps
/// the connection by copper overlap while the replacement elbow joins the two
/// chains directly (see `router.netPourCovers`).
fn hopViaRemovable(board: Board, net: i32, v: Via, outer: u8) bool {
    if (isNetPadCenter(board, .{ v.x, v.y }, net, net_open_slack_mm)) return false;
    return !router.netPourCovers(board.ctx, net, v.x, v.y, outer);
}

/// The unit direction from `p` to `q`, or null when they coincide.
fn unitTo(p: [2]f64, q: [2]f64) ?[2]f64 {
    const len = std.math.hypot(q[0] - p[0], q[1] - p[1]);
    if (len <= hop_snap_mm) return null;
    return .{ (q[0] - p[0]) / len, (q[1] - p[1]) / len };
}

/// Would the replacement leave a via site heading the SAME way the copper
/// already there leaves it? Then the new elbow runs back over the outer chain
/// instead of replacing the hop — a doubling-back spur, which no later pass can
/// simplify away (the shortcut across it is off-axis). Keep the hop instead.
fn doublesBack(from: [2]f64, toward: [2]f64, away: [2]f64) bool {
    const a = unitTo(from, toward) orelse return false;
    const b = unitTo(from, away) orelse return false;
    return a[0] * b[0] + a[1] * b[1] > back_cos_max;
}

/// The clearing octilinear elbow between `a` and `b` on `layer`, or null. Both
/// legs must clear DRC, and neither end may double back over the copper already
/// leaving that end (`hop.away`).
fn clearingElbow(probe: anytype, layer: u8, a: [2]f64, b: [2]f64, away: [2][2]f64) ?[2]f64 {
    for (octilinear.elbows(a, b)) |mid| {
        const first = if (ptEq(a, mid)) b else mid;
        const last = if (ptEq(mid, b)) a else mid;
        if (doublesBack(a, first, away[0]) or doublesBack(b, last, away[1])) continue;
        if (!ptEq(a, mid) and !probe.clear(layer, a, mid)) continue;
        if (!ptEq(mid, b) and !probe.clear(layer, mid, b)) continue;
        return mid;
    }
    return null;
}

/// Swap a hop's two vias and its detour run for one elbow on the outer layer.
fn applyHop(board: Board, net: i32, hop: via_hop_scan.Hop, a: [2]f64, mid: [2]f64, b: [2]f64) std.mem.Allocator.Error!void {
    for (hop.run) |ti| board.tracks.items[ti].net = cleanup_removed_net;
    board.vias.items[hop.v1].net = cleanup_removed_net;
    board.vias.items[hop.v2].net = cleanup_removed_net;
    const w = board.ctx.params.track_width;
    for ([_][2][2]f64{ .{ a, mid }, .{ mid, b } }) |s| {
        if (ptEq(s[0], s[1])) continue;
        try board.tracks.append(board.ctx.arena, .{
            .x1 = s[0][0],
            .y1 = s[0][1],
            .x2 = s[1][0],
            .y2 = s[1][1],
            .layer = hop.outer,
            .width = w,
            .net = net,
        });
    }
    removeNetTracks(board.tracks, cleanup_removed_net);
    removeNetVias(board.vias, cleanup_removed_net);
    // Both packed survivors down, and `removeOneHop` is called again in a loop
    // whose `clearingElbow` probes read the copper index — so the index must be
    // restamped from the new lists before the next hop is judged, or those
    // probes would test a hop's elbow against copper that has since moved
    // slots (in range, wrong track) and could clear it against real metal.
    router.rebuildCopperIndex(board.ctx, board.tracks.items, board.vias.items);
}

/// Remove ONE redundant hop of `net`, or report that none is left.
fn removeOneHop(board: Board, net: i32) std.mem.Allocator.Error!bool {
    const ctx = board.ctx;
    const scan = via_hop_scan.Scan{ .arena = ctx.arena, .tracks = board.tracks.items, .vias = board.vias.items, .net = net };
    const probe = router.TautProbe{ .run = .{ .ctx = ctx, .net = net, .tracks = board.tracks, .vias = board.vias } };
    for (board.vias.items, 0..) |v, vi| {
        if (v.net != net) continue;
        const hop = (try scan.find(vi)) orelse continue;
        const far = board.vias.items[hop.v2];
        if (!hopViaRemovable(board, net, v, hop.outer)) continue;
        if (!hopViaRemovable(board, net, far, hop.outer)) continue;
        const a = [2]f64{ v.x, v.y };
        const b = [2]f64{ far.x, far.y };
        if (std.math.hypot(b[0] - a[0], b[1] - a[1]) < min_hop_span_mm) continue;
        const mid = clearingElbow(probe, hop.outer, a, b, hop.away) orelse continue;
        try applyHop(board, net, hop, a, mid, b);
        return true;
    }
    return false;
}

/// Delete every layer hop the board does not need (E10).
///
/// The maze search buys a layer change for a fixed `via_cost_mult` of grid
/// steps, so wherever the other layer is even slightly cheaper it dives, runs a
/// short way, and climbs back — leaving the "up through a via, across a
/// millimetre, down through a via" pattern with nothing in between to route
/// around. Each such pair costs two drills, two antipads through every plane it
/// crosses, and a reviewer's double-take.
///
/// A hop is redundant exactly when the copper it detours through can be redrawn
/// on the layer both its ends already use — so the test IS the probe: draw the
/// octilinear elbow between the two via sites on the outer layer and keep the
/// hop only if that elbow is blocked. The replacement is never longer than the
/// run it replaces (the elbow is the shortest octilinear path between its ends),
/// and both outer chains still terminate exactly where their via was, so the net
/// stays connected by construction.
///
/// `router.finishRoute` therefore brackets this pass with `straighten`: a
/// tautened run BEFORE, because the detector reads copper and a staircase run
/// hides hops it would otherwise recognise, and another sweep AFTER, because
/// the runs this pass merges are exactly what `straighten` then simplifies
/// across. Both sit ahead of `stitchReturnPaths` so no ground via is ever spent
/// guarding a signal via about to be deleted. See the measured rationale at the
/// call site — the ordering is empirical, not a preference.
///
/// The elbow is the whole of E10's reach, and it is a narrow one: a dive under
/// a fine-pitch pad column is rejoined by a corridor that lies where neither of
/// the two elbow corners can bend to. `dive_elide` finishes the job with a
/// swept three-segment corridor search, under its own (finer) policy gate — so
/// it runs on the nets the `netLayerAuthored` guard above skips wholesale.
pub fn dropRedundantViaPairs(board: Board) std.mem.Allocator.Error!void {
    // `skip_layer_authored`: a net whose policy authors its layers (a
    // preferred/allowed mask, or waypoints requesting an exact transition)
    // means its hops ON PURPOSE. `dive_elide` then revisits those nets under
    // its own finer per-dive policy test.
    const opts = net_rewrite_pass.Options{ .max_steps = max_hops_per_net, .skip_layer_authored = true };
    try net_rewrite_pass.run(board, opts, board, removeOneHop);
    try dive_elide.passBoard(board);
}

fn ufFind(parent: []usize, x: usize) usize {
    var r = x;
    while (parent[r] != r) r = parent[r];
    var c = x;
    while (parent[c] != r) {
        const nx = parent[c];
        parent[c] = r;
        c = nx;
    }
    return r;
}

fn ufUnite(parent: []usize, a: usize, b: usize) void {
    parent[ufFind(parent, a)] = ufFind(parent, b);
}

/// Build net-`net` copper's union-find (pads + tracks + vias) with the same
/// five touch rules `fab_readiness.buildNetGraph` uses, then count the roots
/// that hold copper. Node layout: pads `[0,np)`, tracks `[np,np+nt)`, vias
/// `[np+nt,…)`. `roots` (when non-null) receives one representative track/via
/// node index per copper island (arena-owned parent slice stays valid).
pub fn countCopperIslands(
    arena: std.mem.Allocator,
    pads: []const PadObs,
    tracks: []const Track,
    vias: []const Via,
    parent_out: *[]usize,
) std.mem.Allocator.Error!usize {
    const np = pads.len;
    const nt = tracks.len;
    const nv = vias.len;
    const n = np + nt + nv;
    const parent = try arena.alloc(usize, n);
    for (parent, 0..) |*p, i| p.* = i;
    const slack = net_open_slack_mm;
    for (pads, 0..) |o, pi| {
        for (tracks, 0..) |t, tj| {
            if (!copper_contact.padOnLayer(o.thru, o.layer, t.layer)) continue;
            const shape = pad_shape.Shape{ .x0 = o.x0, .y0 = o.y0, .x1 = o.x1, .y1 = o.y1, .poly = o.poly };
            if (copper_contact.padTrackConnects(shape, .{ t.x1, t.y1 }, .{ t.x2, t.y2 }, t.width))
                ufUnite(parent, pi, np + tj);
        }
        for (vias, 0..) |v, vj| {
            if (pad_shape.pointDist(o.x0, o.y0, o.x1, o.y1, o.poly, v.x, v.y, std.math.inf(f64)) <= v.dia / 2 + slack)
                ufUnite(parent, pi, np + nt + vj);
        }
    }
    for (tracks, 0..) |t, tj| {
        for (tracks[tj + 1 ..], tj + 1..) |b, tj2| {
            if (t.layer != b.layer) continue;
            if (copper_contact.trackTrackConnects(
                .{ .a = .{ t.x1, t.y1 }, .b = .{ t.x2, t.y2 }, .width = t.width },
                .{ .a = .{ b.x1, b.y1 }, .b = .{ b.x2, b.y2 }, .width = b.width },
            ))
                ufUnite(parent, np + tj, np + tj2);
        }
        for (vias, 0..) |v, vj| {
            if (copper_contact.trackViaConnects(
                .{ .a = .{ t.x1, t.y1 }, .b = .{ t.x2, t.y2 }, .width = t.width },
                .{ .at = .{ v.x, v.y }, .dia = v.dia },
            ))
                ufUnite(parent, np + tj, np + nt + vj);
        }
    }
    for (vias, 0..) |va, vj| {
        for (vias[vj + 1 ..], vj + 1..) |vb, vj2| {
            if (std.math.hypot(va.x - vb.x, va.y - vb.y) <= va.dia / 2 + vb.dia / 2 + slack)
                ufUnite(parent, np + nt + vj, np + nt + vj2);
        }
    }
    parent_out.* = parent;
    var roots: std.AutoHashMapUnmanaged(usize, void) = .empty;
    for (0..nt) |tj| try roots.put(arena, ufFind(parent, np + tj), {});
    for (0..nv) |vj| try roots.put(arena, ufFind(parent, np + nt + vj), {});
    return roots.count();
}

const BridgeCand = struct { gap: f64, p1: [2]f64, p2: [2]f64, layer: u8 };

/// One net's copper + bridge geometry for a net-open closure step: its own
/// pads/tracks/vias, net index, jumper width, and the bridge length cap.
const BridgeScan = struct {
    pads: []const PadObs,
    tracks: []const Track,
    vias: []const Via,
    net: i32,
    width: f64,
    max_bridge: f64,
};

/// The shortest single-track bridge between two DISJOINT copper features (one
/// on each island) that share a routable layer. Disjoint segments attain their
/// closest approach at an endpoint, so the endpoint↔segment probes are exact.
fn featureBridge(tracks: []const Track, vias: []const Via, i: usize, j: usize, nt: usize) ?BridgeCand {
    const is_track_i = i < nt;
    const is_track_j = j < nt;
    if (is_track_i and is_track_j) {
        const a = tracks[i];
        const b = tracks[j];
        if (a.layer != b.layer) return null; // one straight track cannot join two layers
        var best: ?BridgeCand = null;
        considerEndpoint(&best, .{ a.x1, a.y1 }, b, a.layer);
        considerEndpoint(&best, .{ a.x2, a.y2 }, b, a.layer);
        considerEndpoint(&best, .{ b.x1, b.y1 }, a, a.layer);
        considerEndpoint(&best, .{ b.x2, b.y2 }, a, a.layer);
        return best;
    }
    if (is_track_i != is_track_j) {
        const t = if (is_track_i) tracks[i] else tracks[j];
        const v = if (is_track_i) vias[j - nt] else vias[i - nt];
        const c = pad_shape.closestOnSeg(t.x1, t.y1, t.x2, t.y2, v.x, v.y);
        return .{ .gap = std.math.hypot(c.x - v.x, c.y - v.y), .p1 = .{ c.x, c.y }, .p2 = .{ v.x, v.y }, .layer = t.layer };
    }
    // via ↔ via: both span every layer, so bridge on the top signal layer.
    const va = vias[i - nt];
    const vb = vias[j - nt];
    return .{ .gap = std.math.hypot(va.x - vb.x, va.y - vb.y), .p1 = .{ va.x, va.y }, .p2 = .{ vb.x, vb.y }, .layer = 0 };
}

/// Fold the endpoint `p`'s closest approach to track `t` into `best`.
fn considerEndpoint(best: *?BridgeCand, p: [2]f64, t: Track, layer: u8) void {
    const c = pad_shape.closestOnSeg(t.x1, t.y1, t.x2, t.y2, p[0], p[1]);
    const gap = std.math.hypot(c.x - p[0], c.y - p[1]);
    if (best.* == null or gap < best.*.?.gap)
        best.* = .{ .gap = gap, .p1 = p, .p2 = .{ c.x, c.y }, .layer = layer };
}

/// One net-open closure step (E9): when the scan net's copper splits into more
/// than one island, add the shortest DRC-clean same-layer jumper joining two of
/// them and return it; null when the copper is already one island or no clean
/// bridge within `scan.max_bridge` exists. `scan.tracks`/`scan.vias` are THIS
/// net's copper only; the probe answers `clear(layer,a,b)` against the whole
/// board (same-net copper is free). Pure over its inputs so it unit-tests with
/// an all-clear probe.
fn bridgeCopperOpen(
    arena: std.mem.Allocator,
    scan: BridgeScan,
    probe: anytype,
) std.mem.Allocator.Error!?Track {
    const nt = scan.tracks.len;
    if (nt + scan.vias.len < 2) return null;
    var parent: []usize = &.{};
    const islands = try countCopperIslands(arena, scan.pads, scan.tracks, scan.vias, &parent);
    if (islands <= 1) return null;
    const np = scan.pads.len;
    // Gather every cross-island copper-feature bridge, shortest first.
    var cands: std.ArrayList(BridgeCand) = .empty;
    const nfeat = nt + scan.vias.len;
    for (0..nfeat) |i| {
        for (i + 1..nfeat) |j| {
            if (ufFind(parent, np + i) == ufFind(parent, np + j)) continue;
            const cand = featureBridge(scan.tracks, scan.vias, i, j, nt) orelse continue;
            if (cand.gap > scan.max_bridge) continue;
            try cands.append(arena, cand);
        }
    }
    std.mem.sort(BridgeCand, cands.items, {}, struct {
        fn lt(_: void, a: BridgeCand, b: BridgeCand) bool {
            return a.gap < b.gap;
        }
    }.lt);
    for (cands.items) |c| {
        if (!probe.clear(c.layer, c.p1, c.p2)) continue;
        return .{ .x1 = c.p1[0], .y1 = c.p1[1], .x2 = c.p2[0], .y2 = c.p2[1], .layer = c.layer, .width = scan.width, .net = scan.net };
    }
    return null;
}

/// Close every routed-but-open net so "routed" means connected by construction
/// (E9). Skips plane-carried nets — their islands fuse through the pour, which
/// `net_open` exempts. For each other net, bridges its copper islands with
/// short DRC-clean same-net jumpers until it is one island (or no clean bridge
/// remains).
pub fn closeNetOpens(board: Board) std.mem.Allocator.Error!void {
    const ctx = board.ctx;
    const placement = board.placement;
    const tracks = board.tracks;
    const vias = board.vias;
    for (0..placement.nets.len) |net_i| {
        const ni: i32 = @intCast(net_i);
        if (!mayRewrite(ctx.selected_nets, ni)) continue; // retained copper echoes verbatim
        if (router.netHasPlane(placement, placement.nets[net_i].name)) continue;
        router.setNetParams(ctx, placement, net_i);
        // Restamp the copper index for this net: the passes before this one
        // packed the lists down (aliasing every entry), each earlier net's
        // bridges appended copper this net's probe must see, and the insertion
        // reach derives from the params just set.
        router.rebuildCopperIndex(ctx, tracks.items, vias.items);
        var pads: std.ArrayList(PadObs) = .empty;
        for (ctx.obs) |o| if (o.net == ni) try pads.append(ctx.arena, o);
        const probe = router.TautProbe{ .run = .{ .ctx = ctx, .net = ni, .tracks = tracks, .vias = vias } };
        var guard: usize = 0;
        while (guard < 32) : (guard += 1) {
            var mine: std.ArrayList(Track) = .empty;
            for (tracks.items) |t| if (t.net == ni) try mine.append(ctx.arena, t);
            var myvias: std.ArrayList(Via) = .empty;
            for (vias.items) |v| if (v.net == ni) try myvias.append(ctx.arena, v);
            const bridge = try bridgeCopperOpen(ctx.arena, .{
                .pads = pads.items,
                .tracks = mine.items,
                .vias = myvias.items,
                .net = ni,
                .width = ctx.params.track_width,
                .max_bridge = max_bridge_mm,
            }, probe) orelse break;
            try tracks.append(ctx.arena, bridge);
        }
        try weldNetPadCenters(board, ni, probe);
    }
    try pruneDanglingCopper(board);
}

// ── Final gloss ──────────────────────────────────────────────────────────────
//
// Everything above runs BEFORE the finish's last copper-emitting passes (pad
// escape rays, adjacent-comb consolidation, the RF finisher, ground stitching,
// the pad-local necks) and before the route gate's junction canonicalization,
// which SPLITS sections at interior intersections and WELDS near-miss contacts.
// Those passes leave three shapes nothing downstream ever revisits: a section
// emitted twice by two passes that each rebuilt the same run, a pair of
// perfectly collinear halves left over from a split whose partner later went
// away, and a tail so short it is swallowed by the round cap of the copper it
// hangs off. The gloss below is the closing sweep for exactly those three, and
// it is deliberately the WEAKEST pass in this file: it removes copper the board
// cannot tell apart from what stays, and it moves nothing except a stub end
// onto its own land's centre (`snapPadStubs`, which probes). Nothing here
// re-straightens, so the escape rays `pad_escape` draws last survive it.

/// Endpoint identity for the gloss (mm). The passes that create the shapes it
/// removes all copy coordinates rather than recomputing them (a split reuses
/// the intersection point, a re-emitted section reuses its own endpoints), so
/// the survivors agree to the last bits of the float rather than to a routing
/// tolerance. Matching wider would start fusing two runs that genuinely meet at
/// a shallow angle.
const gloss_join_eps_mm: f64 = 1e-6;
/// Width delta two sections may differ by and still count as ONE run (mm).
///
/// The collinear merge this gates used to demand EXACT float equality, which a
/// split cannot break but a rebuild can: a per-net width resolved twice through
/// `setNetParams` differs in its last bit, and two halves of one straight run
/// then stayed two sections forever. A micron of width is under any fab's
/// resolution, so a pair inside it is one run as far as the output is concerned.
const gloss_width_eps_mm: f64 = 1e-6;
/// Bound on the gloss's fixed-point sweeps. Each sweep applies every DISJOINT
/// merge it finds, so a chain of `n` collinear sections needs `log2(n)` sweeps;
/// eight covers 256-section runs, far past anything the router emits.
const max_gloss_sweeps: usize = 8;

/// What one final-gloss sweep removed.
pub const GlossStats = struct {
    /// Sections dropped as exact duplicates of a survivor.
    duplicates: usize = 0,
    /// Collinear pairs fused into one section.
    merges: usize = 0,
    /// Sub-half-width dangling tails dropped.
    stubs: usize = 0,

    /// Did this sweep change the copper at all?
    pub fn changed(self: GlossStats) bool {
        return self.duplicates + self.merges + self.stubs > 0;
    }
};

fn glossPointEq(a: [2]f64, b: [2]f64) bool {
    return @abs(a[0] - b[0]) <= gloss_join_eps_mm and @abs(a[1] - b[1]) <= gloss_join_eps_mm;
}

fn trackEnd(t: Track, which: usize) [2]f64 {
    return if (which == 0) .{ t.x1, t.y1 } else .{ t.x2, t.y2 };
}

/// Are these two sections the same piece of copper — same net, same layer, same
/// pair of endpoints in either order? Width is compared by the caller, which
/// keeps the widest of a duplicate group.
fn sameSection(a: Track, b: Track) bool {
    if (a.net != b.net or a.layer != b.layer) return false;
    const a0 = trackEnd(a, 0);
    const a1 = trackEnd(a, 1);
    const b0 = trackEnd(b, 0);
    const b1 = trackEnd(b, 1);
    return (glossPointEq(a0, b0) and glossPointEq(a1, b1)) or
        (glossPointEq(a0, b1) and glossPointEq(a1, b0));
}

/// Drop every mutable section that repeats another one. The survivor of a group
/// is its WIDEST member, and among equal widths the earliest — so the choice is
/// independent of which pass emitted which copy, and a retained (immutable)
/// copy always outlives the generated twin that shadows it.
fn dropDuplicateSections(tracks: *std.ArrayList(Track), mutable: *std.ArrayList(bool)) usize {
    var write: usize = 0;
    var dropped: usize = 0;
    for (tracks.items, 0..) |t, i| {
        var shadowed = false;
        if (mutable.items[i]) for (tracks.items, 0..) |other, j| {
            if (j == i or !sameSection(t, other)) continue;
            if (other.width > t.width + gloss_width_eps_mm or
                (@abs(other.width - t.width) <= gloss_width_eps_mm and j < i))
            {
                shadowed = true;
                break;
            }
        };
        if (shadowed) {
            dropped += 1;
            continue;
        }
        tracks.items[write] = t;
        mutable.items[write] = mutable.items[i];
        write += 1;
    }
    tracks.shrinkRetainingCapacity(write);
    mutable.shrinkRetainingCapacity(write);
    return dropped;
}

/// Everything the finished board attaches to one point on one layer.
const NodeUse = struct {
    /// Same-net section ENDS meeting here, and the last one's index.
    ends: usize = 0,
    partner: usize = 0,
    /// A same-net section whose INTERIOR passes through the point — the point
    /// is a T even though no second end sits on it.
    interior: bool = false,
    /// A barrel or an own land anchors the point; copper may not be fused
    /// across it, because the anchor is what a later reader identifies it by.
    anchored: bool = false,
};

fn interiorHit(t: Track, at: [2]f64) bool {
    const closest = pad_shape.closestOnSeg(t.x1, t.y1, t.x2, t.y2, at[0], at[1]);
    if (closest.d > gloss_join_eps_mm) return false;
    return !glossPointEq(.{ t.x1, t.y1 }, at) and !glossPointEq(.{ t.x2, t.y2 }, at);
}

fn glossPadAnchor(pads: []const PadObs, at: [2]f64, layer: u8, net: i32) bool {
    for (pads) |pad| {
        if (pad.net != net) continue;
        if (!pad.thru and pad.layer != layer) continue;
        if (pointInPad(pad, at[0], at[1])) return true;
    }
    return false;
}

/// The finished board the gloss reads: sections, barrels, and own lands.
const GlossCopper = struct {
    tracks: []const Track,
    vias: []const Via,
    pads: []const PadObs,
};

/// Everything incident on `at` for `net` on `layer`, skipping section `self_i`.
fn nodeUse(copper: GlossCopper, self_i: usize, at: [2]f64, layer: u8, net: i32) NodeUse {
    var use = NodeUse{};
    for (copper.tracks, 0..) |t, i| {
        if (i == self_i or t.net != net or t.layer != layer) continue;
        if (glossPointEq(trackEnd(t, 0), at) or glossPointEq(trackEnd(t, 1), at)) {
            use.ends += 1;
            use.partner = i;
        } else if (interiorHit(t, at)) {
            use.interior = true;
        }
    }
    for (copper.vias) |v| if (glossPointEq(.{ v.x, v.y }, at)) {
        use.anchored = true;
    };
    if (glossPadAnchor(copper.pads, at, layer, net)) use.anchored = true;
    return use;
}

/// Is the vertex where `a` and `b` meet at `at` a straight-through join?
fn glossCollinear(a: Track, b: Track, at: [2]f64) bool {
    const far_a = if (glossPointEq(trackEnd(a, 0), at)) trackEnd(a, 1) else trackEnd(a, 0);
    const far_b = if (glossPointEq(trackEnd(b, 0), at)) trackEnd(b, 1) else trackEnd(b, 0);
    const u = [2]f64{ far_a[0] - at[0], far_a[1] - at[1] };
    const v = [2]f64{ far_b[0] - at[0], far_b[1] - at[1] };
    const lu = std.math.hypot(u[0], u[1]);
    const lv = std.math.hypot(v[0], v[1]);
    if (lu <= gloss_join_eps_mm or lv <= gloss_join_eps_mm) return false;
    // Opposed headings, and the vertex within a micron of the chord they span.
    if (u[0] * v[0] + u[1] * v[1] >= 0) return false;
    const off = @abs(cross2(u, v)) / (lu + lv);
    return off <= gloss_join_eps_mm;
}

/// Fuse every straight-through same-width join between two mutable sections
/// whose vertex holds nothing else. Junction-aware in both directions: a vertex
/// with a third end, an interior crossing, a barrel, or an own land on it is
/// left alone, because each of those is something a later reader identifies the
/// board by. Returns the number of pairs fused.
fn mergeCollinearRuns(
    tracks: *std.ArrayList(Track),
    mutable: *std.ArrayList(bool),
    vias: []const Via,
    pads: []const PadObs,
) usize {
    var fused: usize = 0;
    var sweep: usize = 0;
    while (sweep < max_gloss_sweeps) : (sweep += 1) {
        var merged_this_sweep: usize = 0;
        var i: usize = 0;
        while (i < tracks.items.len) : (i += 1) {
            if (!mutable.items[i]) continue;
            const a = tracks.items[i];
            for (0..2) |which| {
                const at = trackEnd(a, which);
                const use = nodeUse(.{ .tracks = tracks.items, .vias = vias, .pads = pads }, i, at, a.layer, a.net);
                if (use.ends != 1 or use.interior or use.anchored) continue;
                const j = use.partner;
                if (!mutable.items[j]) continue;
                const b = tracks.items[j];
                if (@abs(a.width - b.width) > gloss_width_eps_mm) continue;
                if (!glossCollinear(a, b, at)) continue;
                const far_a = if (which == 0) trackEnd(a, 1) else trackEnd(a, 0);
                const far_b = if (glossPointEq(trackEnd(b, 0), at)) trackEnd(b, 1) else trackEnd(b, 0);
                tracks.items[i] = .{
                    .x1 = far_a[0],
                    .y1 = far_a[1],
                    .x2 = far_b[0],
                    .y2 = far_b[1],
                    .layer = a.layer,
                    .width = @max(a.width, b.width),
                    .net = a.net,
                };
                _ = tracks.orderedRemove(j);
                _ = mutable.orderedRemove(j);
                if (j < i) i -= 1;
                fused += 1;
                merged_this_sweep += 1;
                break;
            }
        }
        if (merged_this_sweep == 0) break;
    }
    return fused;
}

/// Is `at` covered, after `t` goes away, by same-net copper at least as wide as
/// `t`'s own? Any such section whose CENTRELINE passes through `at` sweeps every
/// point within its own half width of `at`, which is more than `t`'s whole
/// length; an own land covers it outright.
fn glossCapCovers(
    tracks: []const Track,
    pads: []const PadObs,
    self_i: usize,
    at: [2]f64,
    t: Track,
) bool {
    for (tracks, 0..) |other, i| {
        if (i == self_i or other.net != t.net or other.layer != t.layer) continue;
        if (other.width + gloss_width_eps_mm < t.width) continue;
        if (pad_shape.closestOnSeg(other.x1, other.y1, other.x2, other.y2, at[0], at[1]).d <= gloss_join_eps_mm) return true;
    }
    return glossPadAnchor(pads, at, t.layer, t.net);
}

/// Drop every mutable tail shorter than half its own width whose free end holds
/// nothing and whose attached end keeps a cap at least as wide.
///
/// No clearance probe is needed and none is taken, because such a tail adds no
/// copper the board loses: every point of it lies within `width/2` of the
/// attached end, and the round cap that survives there is at least `width/2`
/// across, so the swept metal is unchanged. Anything the free end reached —
/// foreign copper, a pour, a land — that cap reaches too, which is why this can
/// neither open a net nor move a clearance verdict, and why the covering test is
/// a precondition rather than a nicety. This is the 1 µm–0.1 mm dead zone
/// `dropDegenerateTracks` (1 µm) and the chamfer floor (0.1 mm) leave between
/// them.
fn dropMicroStubs(
    tracks: *std.ArrayList(Track),
    mutable: *std.ArrayList(bool),
    vias: []const Via,
    pads: []const PadObs,
) usize {
    var write: usize = 0;
    var dropped: usize = 0;
    for (tracks.items, 0..) |t, i| {
        var drop = false;
        if (mutable.items[i] and
            std.math.hypot(t.x2 - t.x1, t.y2 - t.y1) < t.width / 2)
        {
            for (0..2) |which| {
                const free = trackEnd(t, which);
                const use = nodeUse(.{ .tracks = tracks.items, .vias = vias, .pads = pads }, i, free, t.layer, t.net);
                if (use.ends != 0 or use.interior or use.anchored) continue;
                const kept = trackEnd(t, 1 - which);
                if (!glossCapCovers(tracks.items, pads, i, kept, t)) continue;
                drop = true;
                break;
            }
        }
        if (drop) {
            dropped += 1;
            continue;
        }
        tracks.items[write] = t;
        mutable.items[write] = mutable.items[i];
        write += 1;
    }
    tracks.shrinkRetainingCapacity(write);
    mutable.shrinkRetainingCapacity(write);
    return dropped;
}

/// The closing gloss over FINISHED copper: duplicate drop, collinear fuse,
/// micro-tail drop, run to a fixed point.
///
/// Pure geometry over the two lists plus read-only vias and lands — no `Ctx`,
/// no clearance probe, no clock — so the router's finish, the route gate, and
/// the cancel tail can all run the same sweep and get the same answer. `mutable`
/// parallels `tracks` and is compacted with it; a false entry is caller-retained
/// copper that stays byte-for-byte identical, exactly as in
/// `canonicalizeTraceJunctions`.
pub fn glossFinishedTracks(
    tracks: *std.ArrayList(Track),
    mutable: *std.ArrayList(bool),
    vias: []const Via,
    pads: []const PadObs,
) GlossStats {
    std.debug.assert(mutable.items.len == tracks.items.len);
    var stats = GlossStats{};
    var round: usize = 0;
    while (round < max_gloss_sweeps) : (round += 1) {
        var pass = GlossStats{};
        pass.duplicates = dropDuplicateSections(tracks, mutable);
        pass.merges = mergeCollinearRuns(tracks, mutable, vias, pads);
        pass.stubs = dropMicroStubs(tracks, mutable, vias, pads);
        stats.duplicates += pass.duplicates;
        stats.merges += pass.merges;
        stats.stubs += pass.stubs;
        if (!pass.changed()) break;
    }
    return stats;
}

/// May the gloss rewrite this TRACK at all? Scope selection is the same
/// question `mayRewrite` answers; leg copper (`bypass_intent.Legs`) is
/// additionally off limits, because its shape is authored cap-to-pin intent and
/// this sweep has no net-sized rollback with which to take the question back.
/// Track by track is the granularity the gloss already works at, so the rest of
/// an exact rail glosses like any other copper.
fn glossMayRewrite(board: Board, legs: bypass_intent.Legs, t: Track) bool {
    if (!mayRewrite(board.ctx.selected_nets, t.net)) return false;
    return !legFrozen(legs, t);
}

fn glossMutableMask(board: Board, legs: bypass_intent.Legs) std.mem.Allocator.Error!std.ArrayList(bool) {
    var mutable: std.ArrayList(bool) = .empty;
    for (board.tracks.items) |t| try mutable.append(board.arena(), glossMayRewrite(board, legs, t));
    return mutable;
}

/// The router finish's closing sweep: the pure gloss, then the probed pad-stub
/// snap. Runs after EVERY copper-emitting pass, so nothing re-creates what it
/// removes; it re-straightens nothing, so the escape rays drawn last survive.
pub fn finalGloss(board: Board) std.mem.Allocator.Error!void {
    const legs = try bypass_intent.build(board.arena(), board.placement, Track, board.tracks.items);
    var mutable = try glossMutableMask(board, legs);
    const stats = glossFinishedTracks(board.tracks, &mutable, board.vias.items, board.ctx.obs);
    if (stats.changed()) router.copperCompacted(board.ctx);
    try snapPadStubs(board, legs);
}

/// The deadline tail: the deterministic, probe-free half of the finish.
///
/// A cancelled route used to ship raw maze copper — a sliced sub-circuit hits
/// this path routinely — which meant duplicate sections, micron slivers and
/// loose leaves went out under the caller's own DRC. None of the three needs a
/// clearance probe, a straighten, or a clock to remove, so all three run even
/// when the caller has stopped waiting: this is bounded by the copper already
/// on the board and takes no new decision.
pub fn cancelGloss(board: Board) std.mem.Allocator.Error!void {
    const legs = try bypass_intent.build(board.arena(), board.placement, Track, board.tracks.items);
    var mutable = try glossMutableMask(board, legs);
    _ = glossFinishedTracks(board.tracks, &mutable, board.vias.items, board.ctx.obs);
    dropDegenerateTracks(board.tracks, board.ctx.selected_nets);
    router.copperCompacted(board.ctx);
    try pruneDanglingCopper(board);
}

/// How many of `net`'s own lands `tracks` laps rather than terminates on.
fn landOffences(pads: []const PadObs, tracks: []const Track, net: i32) usize {
    var n: usize = 0;
    for (tracks) |t| {
        if (t.net != net) continue;
        for (pads) |pad| {
            if (pad.net != net or pad.thru or pad.layer != t.layer) continue;
            if (land_transit.segmentOffence(
                padLand(pad),
                .{ t.x1, t.y1 },
                .{ t.x2, t.y2 },
                t.width / 2,
            ) != null) n += 1;
        }
    }
    return n;
}

/// Snap a stub end that LANDS ON its own land onto that land's centre.
///
/// The containment test is the point. `snapTerminalVias` already pulls a tail
/// whose end sits within `net_open_slack_mm` (1 µm) of a pad CENTRE, which is
/// the case that was never really broken; the shape that survives every pass is
/// an end parked somewhere ELSE on the land — 0.02–0.4 mm off the middle, on the
/// ray or beside it — which is electrically the same node and manufacturably the
/// `land_transit` finding the board owner asked for. Snapping it costs one
/// coordinate and removes the lap.
///
/// Every end at the snapped point moves together, so a junction on the land
/// cannot be torn apart, and the rewrite is taken only when the probe clears
/// each moved section at its real width AND the land tally strictly improves —
/// a snap that merely re-parks the lap somewhere else is refused.
pub fn snapPadStubs(board: Board, legs: bypass_intent.Legs) std.mem.Allocator.Error!void {
    const ctx = board.ctx;
    for (ctx.obs) |pad| {
        if (pad.thru or pad.net < 0 or !mayRewrite(ctx.selected_nets, pad.net)) continue;
        const land = padLand(pad);
        if (land.paddle()) continue;
        const net_i: usize = @intCast(pad.net);
        if (!board.enabled(net_i)) continue;
        // The snap is a per-PAD transaction over every end parked on this land,
        // so it is refused whole when one of those ends belongs to an authored
        // bypass leg. The rest of an exact rail — the reservoir cap's escape,
        // the branch to a connector — still gets its laps removed.
        if (padHoldsLeg(board, legs, pad)) continue;
        var offending = false;
        for (board.tracks.items) |t| {
            if (t.net != pad.net or t.layer != pad.layer) continue;
            if (!pointInPad(pad, t.x1, t.y1) and !pointInPad(pad, t.x2, t.y2)) continue;
            if (land_transit.segmentOffence(land, .{ t.x1, t.y1 }, .{ t.x2, t.y2 }, t.width / 2) == null) continue;
            offending = true;
            break;
        }
        if (!offending) continue;
        router.setNetParams(ctx, board.placement, net_i);
        router.rebuildCopperIndex(ctx, board.tracks.items, board.vias.items);
        const before = landOffences(ctx.obs, board.tracks.items, pad.net);
        const centre = land.centre();
        const snapped = try board.arena().dupe(Track, board.tracks.items);
        for (snapped) |*t| {
            if (t.net != pad.net or t.layer != pad.layer) continue;
            if (pointInPad(pad, t.x1, t.y1)) {
                t.x1 = centre[0];
                t.y1 = centre[1];
            }
            if (pointInPad(pad, t.x2, t.y2)) {
                t.x2 = centre[0];
                t.y2 = centre[1];
            }
        }
        if (landOffences(ctx.obs, snapped, pad.net) >= before) continue;
        const probe = router.TautProbe{ .run = .{ .ctx = ctx, .net = pad.net, .tracks = board.tracks, .vias = board.vias } };
        var clear = true;
        for (snapped, board.tracks.items) |after, was| {
            if (std.meta.eql(after, was)) continue;
            const len = std.math.hypot(after.x2 - after.x1, after.y2 - after.y1);
            if (len < min_emit_seg_mm) continue; // the snap swallowed it whole
            if (probe.clearWidth(after.layer, .{ after.x1, after.y1 }, .{ after.x2, after.y2 }, after.width)) continue;
            clear = false;
            break;
        }
        if (!clear) continue;
        @memcpy(board.tracks.items, snapped);
        dropDegenerateTracks(board.tracks, ctx.selected_nets);
        router.copperCompacted(ctx);
    }
}

/// Does any authored bypass-leg track park an end on this land? Consulted
/// before `snapPadStubs` re-sites every end it finds there.
fn padHoldsLeg(board: Board, legs: bypass_intent.Legs, pad: PadObs) bool {
    if (!legs.any()) return false;
    for (board.tracks.items) |t| {
        if (t.net != pad.net or t.layer != pad.layer) continue;
        if (!pointInPad(pad, t.x1, t.y1) and !pointInPad(pad, t.x2, t.y2)) continue;
        if (legFrozen(legs, t)) return true;
    }
    return false;
}

/// One net's accumulated copper, handed to the branch fold.
pub const NetFold = struct {
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    params: router.RouteParams,
    /// The board this net's copper must keep clearance from. Only
    /// `existing_tracks` / `existing_vias` (the FOREIGN copper) and the routing
    /// knobs are read; `selected_nets` is replaced by `net` alone. That copper
    /// must NOT carry `net` itself — the caller's own accumulated copper arrives
    /// through `tracks`/`vias`, and is what comes back.
    options: route_policy.Options,
    /// Flattened index of the net being folded.
    net: usize,
    /// Every section and barrel this net has accumulated, in emission order.
    tracks: []const Track,
    vias: []const Via,
};

/// The folded copper, plus whether anything actually folded.
pub const FoldedNet = struct { tracks: []const Track, vias: []const Via, changed: bool };

fn sameCopper(comptime T: type, a: []const T, b: []const T) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.meta.eql(x, y)) return false;
    return true;
}

/// Fold one net's accumulated legs into shared trunks — see the doc on the
/// public seam, `router.foldNetBranches`, for why this cannot be done inside
/// the routing calls that drew them.
pub fn foldNetBranches(run: NetFold) std.mem.Allocator.Error!FoldedNet {
    const arena = run.arena;
    const verbatim = FoldedNet{ .tracks = run.tracks, .vias = run.vias, .changed = false };
    if (run.net >= run.placement.nets.len) return verbatim;
    const only = try arena.alloc(bool, run.placement.nets.len);
    @memset(only, false);
    only[run.net] = true;
    var options = run.options;
    options.selected_nets = only;
    const tracks = try arena.create(std.ArrayList(Track));
    tracks.* = .empty;
    try tracks.appendSlice(arena, run.tracks);
    const vias = try arena.create(std.ArrayList(Via));
    vias.* = .empty;
    try vias.appendSlice(arena, run.vias);
    const board = (try router.cleanupBoard(arena, run.placement, run.params, options, .{
        .tracks = tracks,
        .vias = vias,
    })) orelse return verbatim;
    try mergeParallelBranches(board);
    try mergeAdjacentPadEscapes(board);
    // The foreign copper `cleanupBoard` appended is the caller's board, not this
    // net's answer: hand back only what belongs to `net`, and only when the fold
    // really moved it — an unchanged group returns the caller's own slices, so a
    // no-op fold cannot perturb emission order.
    const want: i32 = @intCast(run.net);
    var folded: std.ArrayList(Track) = .empty;
    for (tracks.items) |t| if (t.net == want) try folded.append(arena, t);
    var barrels: std.ArrayList(Via) = .empty;
    for (vias.items) |v| if (v.net == want) try barrels.append(arena, v);
    if (sameCopper(Track, folded.items, run.tracks) and sameCopper(Via, barrels.items, run.vias)) return verbatim;
    return .{ .tracks = folded.items, .vias = barrels.items, .changed = true };
}

// ── Unit tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

/// A clearance probe that accepts every candidate — exercises the bridge/collapse
/// geometry without a full routing Ctx.
const AllClearProbe = struct {
    fn clear(_: AllClearProbe, _: u8, _: [2]f64, _: [2]f64) bool {
        return true;
    }
};

/// The gloss over a plain track list with everything rewritable.
fn glossFixture(
    arena: std.mem.Allocator,
    seed: []const Track,
    vias: []const Via,
    pads: []const PadObs,
) std.mem.Allocator.Error!struct { tracks: std.ArrayList(Track), stats: GlossStats } {
    var tracks: std.ArrayList(Track) = .empty;
    try tracks.appendSlice(arena, seed);
    var mutable: std.ArrayList(bool) = .empty;
    for (seed) |_| try mutable.append(arena, true);
    const stats = glossFinishedTracks(&tracks, &mutable, vias, pads);
    std.debug.assert(tracks.items.len == mutable.items.len);
    return .{ .tracks = tracks, .stats = stats };
}

// spec: placement/router - the closing gloss drops every repeat of one finished section, keeping the widest copy once
test "repeated emissions of one section collapse to a single widest survivor" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    // The VIN shape the finish measured four times over: two passes rebuilt the
    // same run, one of them at the rail width, one reversed end-for-end.
    const seed = [_]Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 2, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 0, .y1 = 0, .x2 = 2, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 2, .y1 = 0, .x2 = 0, .y2 = 0, .layer = 0, .width = 0.35, .net = 0 },
        .{ .x1 = 0, .y1 = 0, .x2 = 2, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        // Same geometry, other layer and other net: not the same copper.
        .{ .x1 = 0, .y1 = 0, .x2 = 2, .y2 = 0, .layer = 1, .width = 0.2, .net = 0 },
        .{ .x1 = 0, .y1 = 0, .x2 = 2, .y2 = 0, .layer = 0, .width = 0.2, .net = 1 },
    };
    const out = try glossFixture(arena, &seed, &.{}, &.{});
    try testing.expectEqual(@as(usize, 3), out.tracks.items.len);
    try testing.expectEqual(@as(usize, 3), out.stats.duplicates);
    // The widest copy is the one that survives, so no swept copper is lost.
    try testing.expectEqual(@as(f64, 0.35), out.tracks.items[0].width);
    try testing.expectEqual(@as(u8, 1), out.tracks.items[1].layer);
    try testing.expectEqual(@as(i32, 1), out.tracks.items[2].net);
}

// spec: placement/router - the closing gloss drops a dangling tail shorter than half its own width and keeps one its copper does not cover
test "a sub-half-width dangling tail is glossed away and a longer one survives" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const seed = [_]Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 2, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        // 0.05 mm off the run's own end — inside the 0.1 mm cap that stays.
        .{ .x1 = 2, .y1 = 0, .x2 = 2, .y2 = 0.05, .layer = 0, .width = 0.2, .net = 0 },
        // 0.05 mm off its MIDDLE — covered by the run's own swept width.
        .{ .x1 = 1, .y1 = 0, .x2 = 1, .y2 = -0.05, .layer = 0, .width = 0.2, .net = 0 },
        // Real copper: 0.4 mm is well past half a track width.
        .{ .x1 = 0, .y1 = 0, .x2 = 0, .y2 = 0.4, .layer = 0, .width = 0.2, .net = 0 },
    };
    const out = try glossFixture(arena, &seed, &.{}, &.{});
    try testing.expectEqual(@as(usize, 2), out.tracks.items.len);
    try testing.expectEqual(@as(usize, 2), out.stats.stubs);
    try testing.expectEqual(@as(f64, 0.4), out.tracks.items[1].y2);

    // A tail whose free end is anchored is a connection, not an artifact: a
    // barrel there keeps it, and so does its own land.
    const barrel = [_]Via{.{ .x = 2, .y = 0.05, .dia = 0.4, .net = 0 }};
    const kept = try glossFixture(arena, &seed, &barrel, &.{});
    try testing.expectEqual(@as(usize, 3), kept.tracks.items.len);
    const land = [_]PadObs{.{ .x0 = 0.9, .y0 = -0.15, .x1 = 1.1, .y1 = 0.05, .net = 0, .layer = 0 }};
    const landed = try glossFixture(arena, &seed, &.{}, &land);
    try testing.expectEqual(@as(usize, 3), landed.tracks.items.len);
}

// spec: placement/router - the closing gloss fuses a collinear pair at a bare vertex and refuses one carrying a junction, a barrel, or a land
test "collinear halves fuse only where the vertex holds nothing else" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    // The shape a junction split leaves once its partner is gone. The widths
    // differ in their last bit — the exact-equality merge this replaces left
    // such a pair apart forever.
    const split = [_]Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 1.5, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 1.5, .y1 = 0, .x2 = 3, .y2 = 0, .layer = 0, .width = 0.2 + 1e-9, .net = 0 },
    };
    const fused = try glossFixture(arena, &split, &.{}, &.{});
    try testing.expectEqual(@as(usize, 1), fused.tracks.items.len);
    try testing.expectEqual(@as(usize, 1), fused.stats.merges);
    try testing.expectEqual(@as(f64, 0), @min(fused.tracks.items[0].x1, fused.tracks.items[0].x2));
    try testing.expectEqual(@as(f64, 3), @max(fused.tracks.items[0].x1, fused.tracks.items[0].x2));

    // A third branch at the vertex makes it a T: the split is the topology.
    var tee: std.ArrayList(Track) = .empty;
    try tee.appendSlice(arena, &split);
    try tee.append(arena, .{ .x1 = 1.5, .y1 = 0, .x2 = 1.5, .y2 = 2, .layer = 0, .width = 0.2, .net = 0 });
    const kept_tee = try glossFixture(arena, tee.items, &.{}, &.{});
    try testing.expectEqual(@as(usize, 3), kept_tee.tracks.items.len);

    // A barrel and an own land are each an anchor a later reader identifies
    // the board by, so neither vertex is fused away either.
    const barrel = [_]Via{.{ .x = 1.5, .y = 0, .dia = 0.4, .net = 0 }};
    const on_via = try glossFixture(arena, &split, &barrel, &.{});
    try testing.expectEqual(@as(usize, 2), on_via.tracks.items.len);
    const land = [_]PadObs{.{ .x0 = 1.4, .y0 = -0.1, .x1 = 1.6, .y1 = 0.1, .net = 0, .layer = 0 }};
    const on_land = try glossFixture(arena, &split, &.{}, &land);
    try testing.expectEqual(@as(usize, 2), on_land.tracks.items.len);

    // A real corner is not collinear and never fuses.
    const corner = [_]Track{
        split[0],
        .{ .x1 = 1.5, .y1 = 0, .x2 = 1.5, .y2 = 1, .layer = 0, .width = 0.2, .net = 0 },
    };
    const bent = try glossFixture(arena, &corner, &.{}, &.{});
    try testing.expectEqual(@as(usize, 2), bent.tracks.items.len);
}

// spec: placement/router - the closing gloss leaves immutable caller copper byte-identical
test "the closing gloss never rewrites a section the caller retained" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const retained = Track{ .x1 = 0, .y1 = 0, .x2 = 1.5, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 };
    var tracks: std.ArrayList(Track) = .empty;
    try tracks.appendSlice(arena, &.{
        retained,
        .{ .x1 = 1.5, .y1 = 0, .x2 = 3, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        retained, // a generated duplicate of retained copper
    });
    var mutable: std.ArrayList(bool) = .empty;
    try mutable.appendSlice(arena, &.{ false, false, true });
    const stats = glossFinishedTracks(&tracks, &mutable, &.{}, &.{});
    // Only the generated copy goes; the two retained sections stay apart and
    // byte-identical even though they are a collinear pair at a bare vertex.
    try testing.expectEqual(@as(usize, 1), stats.duplicates);
    try testing.expectEqual(@as(usize, 0), stats.merges);
    try testing.expectEqual(@as(usize, 2), tracks.items.len);
    try testing.expect(std.meta.eql(retained, tracks.items[0]));
}

// spec: placement/router - exact same-net vias at one coordinate collapse to one physical drill before final DRC
test "coincident same-net vias collapse before final DRC" {
    var list: std.ArrayList(Via) = .empty;
    defer list.deinit(testing.allocator);
    const first = Via{ .x = 2, .y = 3, .dia = 0.4, .drill = 0.2, .net = 7 };
    try list.appendSlice(testing.allocator, &.{
        first,
        // Different metadata at the exact point is still one physical barrel.
        .{ .x = 2, .y = 3, .dia = 0.6, .drill = 0.3, .net = 7 },
        .{ .x = 2, .y = 3, .dia = 0.4, .drill = 0.2, .net = 8 },
        .{ .x = 2.01, .y = 3, .dia = 0.4, .drill = 0.2, .net = 7 },
    });
    dropCoincidentVias(&list, &.{});
    try testing.expectEqual(@as(usize, 3), list.items.len);
    try testing.expectEqual(first, list.items[0]);

    // A scoped run may not rewrite the caller's retained net 7 copper.
    var selected: [9]bool = @splat(false);
    selected[8] = true;
    try list.insert(testing.allocator, 1, first);
    dropCoincidentVias(&list, &selected);
    try testing.expectEqual(@as(usize, 4), list.items.len);
}

// spec: placement/router - drops sub-micron degenerate track segments from the finished copper
test "dropDegenerateTracks removes zero-length segments and keeps real ones" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var tracks: std.ArrayList(Track) = .empty;
    try tracks.append(arena, .{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 });
    // A ~0.07 µm arc-chord endpoint — well under the 1 µm floor.
    try tracks.append(arena, .{ .x1 = 5, .y1 = 5, .x2 = 5.00005, .y2 = 5.00005, .layer = 0, .width = 0.2, .net = 0 });
    try tracks.append(arena, .{ .x1 = 2, .y1 = 0, .x2 = 2, .y2 = 2, .layer = 0, .width = 0.2, .net = 0 });
    dropDegenerateTracks(&tracks, &.{});
    try testing.expectEqual(@as(usize, 2), tracks.items.len);
    for (tracks.items) |t| try testing.expect(std.math.hypot(t.x2 - t.x1, t.y2 - t.y1) >= min_emit_seg_mm);

    // In a scoped run an UNSELECTED net's degenerate segment is retained caller
    // copper and survives the sweep verbatim; a selected net's is still swept.
    try tracks.append(arena, .{ .x1 = 3, .y1 = 3, .x2 = 3.00005, .y2 = 3.00005, .layer = 0, .width = 0.2, .net = 1 });
    try tracks.append(arena, .{ .x1 = 4, .y1 = 4, .x2 = 4.00005, .y2 = 4.00005, .layer = 0, .width = 0.2, .net = 0 });
    dropDegenerateTracks(&tracks, &.{ true, false });
    try testing.expectEqual(@as(usize, 3), tracks.items.len);
    try testing.expectEqual(@as(i32, 1), tracks.items[2].net);
}

// spec: placement/router - collapses a collinear multi-pad net to one straight through-line
test "collinearExtremes spans collinear pads and rejects an off-line one" {
    // VTUNE's three collinear pads: R60, C84 (middle), U14 — R60 is LEFT of both
    // others, so the extreme pair is R60↔U14 and the through-line covers C84.
    const collinear = [_][2]f64{
        .{ 140.270, 109.162 }, // R60
        .{ 141.060, 109.182 }, // C84 (on the R60↔U14 line to 0.001 mm)
        .{ 142.160, 109.212 }, // U14
    };
    const ends = collinearExtremes(&collinear, 0.156) orelse return testing.expect(false);
    try testing.expect((ends[0] == 0 and ends[1] == 2) or (ends[0] == 2 and ends[1] == 0));
    // Pull the middle pad 0.3 mm off the line → not collinear → null.
    const bent = [_][2]f64{
        .{ 140.270, 109.162 },
        .{ 141.060, 109.482 },
        .{ 142.160, 109.212 },
    };
    try testing.expect(collinearExtremes(&bent, 0.156) == null);
}

// spec: placement/router - snaps a terminal via onto its pad centre and drops the sliver tail
test "terminalTailPadSide finds a via-tail's pad end and ignores a real trace" {
    // REF_ADF's terminal tail: pad (186.675,103.585) → via (186.650,103.550),
    // 0.043 mm long; via_dia 0.4 ⇒ snap_max 0.1.
    const tail = Track{ .x1 = 186.675, .y1 = 103.585, .x2 = 186.650, .y2 = 103.550, .layer = 1, .width = 0.312, .net = 0 };
    const pad = terminalTailPadSide(tail, 186.650, 103.550, 0.1) orelse return testing.expect(false);
    try testing.expectApproxEqAbs(@as(f64, 186.675), pad[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 103.585), pad[1], 1e-9);
    // A full-length trace whose end merely sits on the via is NOT a tail.
    const trace = Track{ .x1 = 185.0, .y1 = 103.550, .x2 = 186.650, .y2 = 103.550, .layer = 0, .width = 0.312, .net = 0 };
    try testing.expect(terminalTailPadSide(trace, 186.650, 103.550, 0.1) == null);
    // Neither end on the via ⇒ null.
    try testing.expect(terminalTailPadSide(tail, 100, 100, 0.1) == null);
    // The caller bounds snap_max at width/2: a 0.07 mm cross-side leg on a
    // 0.127 mm trace (the net's ONLY copper on its layer) exceeds that bound
    // and survives — only a sub-half-width sliver is junk.
    const leg = Track{ .x1 = 0, .y1 = 0, .x2 = -0.05, .y2 = -0.05, .layer = 0, .width = 0.127, .net = 0 };
    try testing.expect(terminalTailPadSide(leg, -0.05, -0.05, @min(0.4 / 4.0, 0.127 / 2.0)) == null);
}

// spec: placement/router - a terminal-via snap reuses the earlier same-net barrel when recentering would create the board-a TXDATA via-spacing error
test "terminal snap folds the later TXDATA barrel onto the earlier one" {
    // #ddc3 measured a 0.0935626 mm copper gap after the later 0.4 mm via was
    // snapped toward the pad, below board-a's 0.127 mm rule. Before the snap
    // the pair sat legally 0.53 mm apart.
    const vias = [_]Via{
        .{ .x = 0.53, .y = 0, .dia = 0.4, .drill = 0.2, .net = 7 },
        .{ .x = 0, .y = 0, .dia = 0.4, .drill = 0.2, .net = 7 },
    };
    const snapped_x = 0.0364374406420343;
    try testing.expectEqual(@as(?usize, 0), sameNetSnapCrowd(&vias, 1, snapped_x, 0, 0, 0.127));

    // Folding retains the pad tail: its via-side endpoint moves to the survivor
    // instead of disappearing with the duplicate barrel.
    const tail = Track{ .x1 = -0.03, .y1 = 0, .x2 = 0, .y2 = 0, .layer = 1, .width = 0.127, .net = 7 };
    const anchored = reanchoredTrack(tail, vias[1], vias[0]) orelse return testing.expect(false);
    try testing.expectApproxEqAbs(@as(f64, 0.53), anchored.x2, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0), anchored.y2, 1e-12);
}

/// board-a's V_12V hop: two vias 45° apart joined by ONE F.Cu segment, with
/// B.Cu copper running away from each — the "up, across a millimetre, back
/// down" shape with nothing in between.
fn v12vHopFixture() struct { tracks: [3]Track, vias: [2]Via } {
    return .{
        .tracks = .{
            .{ .x1 = 160.5, .y1 = 97.0, .x2 = 162.731, .y2 = 99.146, .layer = 1, .width = 0.25, .net = 0 },
            .{ .x1 = 162.731, .y1 = 99.146, .x2 = 163.610, .y2 = 100.024, .layer = 0, .width = 0.25, .net = 0 },
            .{ .x1 = 163.610, .y1 = 100.024, .x2 = 165.807, .y2 = 99.585, .layer = 1, .width = 0.25, .net = 0 },
        },
        .vias = .{
            .{ .x = 162.731, .y = 99.146, .dia = 0.4, .drill = 0.2, .net = 0 },
            .{ .x = 163.610, .y = 100.024, .dia = 0.4, .drill = 0.2, .net = 0 },
        },
    };
}

// spec: placement/router - finds a redundant layer hop whose detour can be redrawn on the layer both its ends already use
test "findHop pairs two transition vias and names the layer their ends share" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const fx = v12vHopFixture();
    const scan = via_hop_scan.Scan{ .arena = arena, .tracks = &fx.tracks, .vias = &fx.vias, .net = 0 };
    const hop = (try scan.find(0)) orelse return testing.expect(false);
    try testing.expectEqual(@as(usize, 1), hop.v2);
    try testing.expectEqual(@as(u8, 1), hop.outer); // both ends continue on B.Cu
    try testing.expectEqual(@as(usize, 1), hop.run.len); // the single F.Cu detour
    try testing.expectEqual(@as(usize, 1), hop.run[0]);
    // The replacement is the octilinear elbow between the two via sites — the
    // vias sit 45° apart, so it is a single clean diagonal.
    const a = [2]f64{ fx.vias[0].x, fx.vias[0].y };
    const b = [2]f64{ fx.vias[1].x, fx.vias[1].y };
    for (octilinear.elbows(a, b)) |mid| {
        try testing.expect(octilinear.isOctilinear(a, mid));
        try testing.expect(octilinear.isOctilinear(mid, b));
    }
}

// spec: placement/router - refuses to delete a layer hop whose run branches or whose ends leave on different layers
test "findHop refuses a branching run and a hop whose ends leave on different layers" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var fx = v12vHopFixture();
    // Far end leaves on F.Cu instead of B.Cu: the two ends no longer share a
    // layer, so no single-layer redraw can replace the hop.
    fx.tracks[2].layer = 0;
    const split = via_hop_scan.Scan{ .arena = arena, .tracks = &fx.tracks, .vias = &fx.vias, .net = 0 };
    try testing.expect((try split.find(0)) == null);
    // A third track hanging off the first via makes it a junction, not a pure
    // transition — deleting it would strand that branch.
    const branched = [_]Track{
        fx.tracks[0],                                                                                        fx.tracks[1],
        .{ .x1 = 163.610, .y1 = 100.024, .x2 = 165.807, .y2 = 99.585, .layer = 1, .width = 0.25, .net = 0 }, .{ .x1 = 162.731, .y1 = 99.146, .x2 = 162.731, .y2 = 96.0, .layer = 1, .width = 0.25, .net = 0 },
    };
    const scan = via_hop_scan.Scan{ .arena = arena, .tracks = &branched, .vias = &fx.vias, .net = 0 };
    try testing.expect((try scan.find(0)) == null);
}

// spec: placement/router - keeps a layer hop whose replacement would double back over the copper already leaving a via
test "clearingElbow refuses a replacement that runs back over the outer chain" {
    const a = [2]f64{ 185.108, 98.739 };
    const b = [2]f64{ 186.350, 99.981 };
    // The outer chains leave BOTH vias heading toward the other one — the very
    // shape that produced board-a's V_12V spur. Every elbow between them runs
    // back over existing copper, so the hop must stand.
    const back = [2][2]f64{ .{ 186.000, 99.600 }, .{ 185.400, 99.000 } };
    try testing.expect(clearingElbow(AllClearProbe{}, 1, a, b, back) == null);
    // Outer chains leaving in the opposite direction leave the elbow free.
    const away = [2][2]f64{ .{ 184.000, 97.600 }, .{ 187.500, 101.100 } };
    const mid = clearingElbow(AllClearProbe{}, 1, a, b, away) orelse return testing.expect(false);
    try testing.expect(octilinear.isOctilinear(a, mid));
    try testing.expect(octilinear.isOctilinear(mid, b));
}

// spec: placement/router - bridges a same-net copper gap so a routed net is connected by construction
test "bridgeCopperOpen joins two disjoint same-net track islands into one" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    // Two collinear same-net stubs on layer 0 with a 0.3 mm centreline gap —
    // two copper islands, each carrying a pad.
    const pads = [_]PadObs{
        .{ .x0 = -0.1, .y0 = -0.1, .x1 = 0.1, .y1 = 0.1, .net = 0 },
        .{ .x0 = 1.9, .y0 = -0.1, .x1 = 2.1, .y1 = 0.1, .net = 0 },
    };
    const tracks = [_]Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 0.85, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 1.15, .y1 = 0, .x2 = 2, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
    };
    var parent: []usize = &.{};
    try testing.expectEqual(@as(usize, 2), try countCopperIslands(arena, &pads, &tracks, &.{}, &parent));
    const bridge = (try bridgeCopperOpen(arena, .{
        .pads = &pads,
        .tracks = &tracks,
        .vias = &.{},
        .net = 0,
        .width = 0.2,
        .max_bridge = max_bridge_mm,
    }, AllClearProbe{})) orelse
        return testing.expect(false);
    try testing.expectEqual(@as(u8, 0), bridge.layer);
    try testing.expectApproxEqAbs(@as(f64, 0.3), std.math.hypot(bridge.x2 - bridge.x1, bridge.y2 - bridge.y1), 1e-6);
    // Adding the jumper fuses the two islands into one.
    const joined = [_]Track{ tracks[0], tracks[1], bridge };
    try testing.expectEqual(@as(usize, 1), try countCopperIslands(arena, &pads, &joined, &.{}, &parent));
}

// spec: placement/router - a trace that only grazes a pad is welded from its centreline to the exact pad centre
test "board-a op-amp pin 6 pad-centre target rejects a grazing trace" {
    // The saved board-a auto-90 LF_OUT route: U21.6 is a 1.528 x 0.65 mm
    // land centred at (132.466,107.930). This 45-degree run misses its centre
    // by 0.434 mm, but its 0.2532 mm copper still grazes the pad closely enough
    // for the electrical connectivity oracle to accept it.
    const center = [2]f64{ 132.466, 107.930 };
    const pad = PadObs{
        .x0 = center[0] - 0.764,
        .y0 = center[1] - 0.325,
        .x1 = center[0] + 0.764,
        .y1 = center[1] + 0.325,
        .net = 0,
        .layer = 0,
    };
    const grazing = Track{
        .x1 = 130.787,
        .y1 = 106.865,
        .x2 = 132.452,
        .y2 = 108.530,
        .layer = 0,
        .width = 0.2532,
        .net = 0,
    };
    const shape = pad_shape.Shape{ .x0 = pad.x0, .y0 = pad.y0, .x1 = pad.x1, .y1 = pad.y1 };
    const touch = grazing.width / 2 + net_open_slack_mm;
    try testing.expect(pad_shape.segmentDist(
        shape,
        .{ grazing.x1, grazing.y1 },
        .{ grazing.x2, grazing.y2 },
        touch,
    ) <= touch);

    const target = padCenterTarget(pad, &.{grazing}) orelse return testing.expect(false);
    try testing.expectApproxEqAbs(@as(f64, 0.4341635636485), target.distance, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 132.159), target.at[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 108.237), target.at[1], 1e-9);
    // This tempting 45° spoke is why the repair seam now tries an H/V elbow first.
    try testing.expect(octilinear.isOctilinear(center, target.at));

    // Once that spoke exists, the same scan finds an exact centre hit and the
    // board-level pass becomes idempotent instead of appending another stub.
    const centred = Track{
        .x1 = center[0],
        .y1 = center[1],
        .x2 = target.at[0],
        .y2 = target.at[1],
        .layer = 0,
        .width = grazing.width,
        .net = 0,
    };
    const fixed = padCenterTarget(pad, &.{ grazing, centred }) orelse return testing.expect(false);
    try testing.expectApproxEqAbs(@as(f64, 0), fixed.distance, 1e-12);
}

// spec: placement/router - the finish deletes every stored section whose removal preserves all pad and live-via connectivity, keeping the run that carries the net
test "dropRedundantSections removes a hook drawn on one land and keeps the run leaving it" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const lands = [_]copper_topology.Terminal{
        .{ .shape = .{ .x0 = -0.3, .y0 = -0.3, .x1 = 0.3, .y1 = 0.3 }, .net = 0, .layer = 0 },
        .{ .shape = .{ .x0 = 4.7, .y0 = -0.3, .x1 = 5.3, .y1 = 0.3 }, .net = 0, .layer = 0 },
    };
    var list: std.ArrayList(Track) = .empty;
    // The run that carries the net, then a hook: out of the first land by less
    // than a half width and straight back onto it. Neither hook end is loose,
    // so the leaf pass keeps both and DRC warns about both.
    try list.appendSlice(arena, &.{
        .{ .x1 = 0, .y1 = 0, .x2 = 5, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 0.2, .y1 = 0, .x2 = 0.35, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 0.35, .y1 = 0, .x2 = 0.2, .y2 = 0.2, .layer = 0, .width = 0.2, .net = 0 },
    });
    try testing.expect(try dropRedundantSections(arena, &lands, .{}, &list, &.{}, .{}));
    try testing.expectEqual(@as(usize, 1), list.items.len);
    try testing.expectEqual(@as(f64, 5), list.items[0].x2);
    // The survivor is the only path to the second land, so this is a fixed point.
    try testing.expect(!try dropRedundantSections(arena, &lands, .{}, &list, &.{}, .{}));
}

// spec: placement/router - the finish's section-deletion plan never strips retained out-of-scope copper
test "dropRedundantSections leaves an unselected net's redundant copper alone" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const lands = [_]copper_topology.Terminal{
        .{ .shape = .{ .x0 = -0.3, .y0 = -0.3, .x1 = 0.3, .y1 = 0.3 }, .net = 0, .layer = 0 },
        .{ .shape = .{ .x0 = 4.7, .y0 = -0.3, .x1 = 5.3, .y1 = 0.3 }, .net = 0, .layer = 0 },
    };
    var list: std.ArrayList(Track) = .empty;
    // The same run-plus-hook the previous test strips, on a net this scoped
    // run did not select. It stays byte-identical, hook and all.
    try list.appendSlice(arena, &.{
        .{ .x1 = 0, .y1 = 0, .x2 = 5, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 0.2, .y1 = 0, .x2 = 0.35, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 0.35, .y1 = 0, .x2 = 0.2, .y2 = 0.2, .layer = 0, .width = 0.2, .net = 0 },
    });
    const retained = [_]bool{false};
    try testing.expect(!try dropRedundantSections(arena, &lands, .{}, &list, &retained, .{}));
    try testing.expectEqual(@as(usize, 3), list.items.len);
}

// spec: placement/router - the finish leaves copper that reaches at most one support to the leaf pass, since a fill-blind seam cannot tell dead metal from a pour connection
test "dropRedundantSections keeps a component that joins no second support" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    // A top-layer run beside bottom-only lands has no visible pad support, so
    // the fill-blind oracle calls every section of it redundant. It may still
    // be carried by an omitted pour, and this seam is not the place to decide
    // that the whole component is dead metal.
    const lands = [_]copper_topology.Terminal{
        .{ .shape = .{ .x0 = -0.2, .y0 = -0.2, .x1 = 0.2, .y1 = 0.2 }, .net = 0, .layer = 1 },
        .{ .shape = .{ .x0 = 2.8, .y0 = 0.8, .x1 = 3.2, .y1 = 1.2 }, .net = 0, .layer = 1 },
    };
    var list: std.ArrayList(Track) = .empty;
    try list.appendSlice(arena, &.{
        .{ .x1 = 0, .y1 = 0, .x2 = 2, .y2 = 0, .layer = 0, .width = 0.55, .net = 0 },
        .{ .x1 = 2, .y1 = 0, .x2 = 3, .y2 = 1, .layer = 0, .width = 0.55, .net = 0 },
    });
    const topology = try arena.alloc(copper_topology.Track, list.items.len);
    const analysis = try copper_topology.analyzeRedundancy(arena, &lands, fillTopologyTracks(topology, list.items), .{});
    try testing.expect(analysis.individual[0] and analysis.individual[1]);
    try testing.expect(!analysis.spanning[0] and !analysis.spanning[1]);
    try testing.expect(!try dropRedundantSections(arena, &lands, .{}, &list, &.{}, .{}));
    try testing.expectEqual(@as(usize, 2), list.items.len);
}

// spec: placement/router - a pad some run already enters at full trace width receives no centre weld
test "the pad-centre weld target is skipped once a run carries a full cross-section onto the land" {
    const pad = PadObs{ .x0 = -0.6, .y0 = -0.3, .x1 = 0.6, .y1 = 0.3, .net = 0, .layer = 0 };
    // A run straight through the land, off its centre line: connected already.
    const through = [_]Track{.{ .x1 = -2, .y1 = 0.15, .x2 = 2, .y2 = 0.15, .layer = 0, .width = 0.2, .net = 0 }};
    try testing.expect(padAlreadyEntered(pad, &through));
    // The weld would otherwise fire: a centre target exists and is not on centre.
    const target = padCenterTarget(pad, &through) orelse return testing.expect(false);
    try testing.expect(target.distance > octilinear.min_heading_mm);
    // A corner graze carries no full cross-section, so that weld still runs.
    const grazing = [_]Track{.{ .x1 = 0.65, .y1 = 0.34, .x2 = 3, .y2 = 2, .layer = 0, .width = 0.2, .net = 0 }};
    try testing.expect(!padAlreadyEntered(pad, &grazing));
}

// spec: placement/router - a section-deletion plan built over a filled region drops exactly one leg of a doubled pad stub
test "a fill-credited deletion plan consumes a doubled pad stub joined through its pour" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const nets = [_]optimizer.FlatNet{.{ .name = "V_3V3A", .pins = &.{} }};
    const placement = optimizer.Placement{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 10,
        .maxy = 10,
        .generated = true,
    };
    const lands = [_]copper_topology.Terminal{
        .{ .shape = .{ .x0 = -0.3, .y0 = -0.3, .x1 = 0.3, .y1 = 0.3 }, .net = 0, .layer = 0 },
    };
    // One land, two short legs out to two barrels 0.38 mm apart — the shape
    // board-a's power rails carry. Both barrels reach only this one routed
    // layer, so neither is a destination; the filled region under both far
    // ends is what actually joins them, and one leg is then enough.
    var list: std.ArrayList(Track) = .empty;
    try list.appendSlice(arena, &.{
        .{ .x1 = 0, .y1 = 0, .x2 = 1.2, .y2 = 0.19, .layer = 0, .width = 0.25, .net = 0 },
        .{ .x1 = 0, .y1 = 0, .x2 = 1.2, .y2 = -0.19, .layer = 0, .width = 0.25, .net = 0 },
    });
    const vias = [_]copper_topology.Via{
        .{ .at = .{ 1.2, 0.19 }, .dia = 0.4, .net = 0 },
        .{ .at = .{ 1.2, -0.19 }, .dia = 0.4, .net = 0 },
    };
    const region = [_][2]f64{ .{ 0.9, -1 }, .{ 3, -1 }, .{ 3, 1 }, .{ 0.9, 1 } };
    const zones = [_]copper_support.Zone{.{ .net = "V_3V3A", .layer = 0, .poly = &region, .component = 1 }};

    // The FINISH is handed the blind reading (see `liveSupportVias`): the two
    // legs are then the only copper reaching each barrel, the component holds
    // one support, and nothing here may be touched.
    const topology = try arena.alloc(copper_topology.Track, list.items.len);
    const filled_tracks = fillTopologyTracks(topology, list.items);
    const blind = try copper_support.assemble(arena, placement, &lands, filled_tracks, &vias, &.{});
    try testing.expect(!try dropRedundantSections(arena, &lands, blind.branch, &list, &.{}, .{}));
    try testing.expectEqual(@as(usize, 2), list.items.len);

    // The GATE is handed the fabricated fill, and there the second leg joins
    // nothing the first does not already join: exactly one survives.
    const poured = try copper_support.assemble(arena, placement, &lands, filled_tracks, &vias, &zones);
    try testing.expect(try dropRedundantSections(arena, &lands, poured.branch, &list, &.{}, .{}));
    try testing.expectEqual(@as(usize, 1), list.items.len);
    // …and the survivor is a fixed point rather than the next round's victim.
    const kept = try arena.alloc(copper_topology.Track, list.items.len);
    const after = try copper_support.assemble(arena, placement, &lands, fillTopologyTracks(kept, list.items), &vias, &zones);
    try testing.expect(!try dropRedundantSections(arena, &lands, after.branch, &list, &.{}, .{}));
}
