//! End-to-end router regression for pad-terminated joins — the picture a hand
//! router draws for a three-pad net whose two passives stack on one edge.

const std = @import("std");
const router = @import("router.zig");
const optimizer = @import("optimizer.zig");
const flat_netlist = @import("../flat_netlist.zig");
const geometry = @import("geometry.zig");

/// Slack in board millimetres on the shared x band: a sample this far outside
/// it is still on the band, so a track riding the boundary is not miscounted.
const band_eps_mm: f64 = 1e-6;

const testing = std.testing;

/// How the copper crosses the gap between two stacked lands: on the band the
/// two lands share (pad to pad, the hand shape) or beside it (the escape-lane
/// trunk this regression exists to stop).
const Crossing = struct { on_band: usize = 0, beside: usize = 0 };

/// Walk every segment through the y band between the two lands and record, for
/// each sample inside it, whether the copper is within the lands' shared x
/// band. Sampling is enough: a segment is straight, so a run down the lane
/// registers on every one of its samples.
fn gapCrossing(tracks: []const router.Track, gap: [2]f64, band: [2]f64) Crossing {
    var seen = Crossing{};
    const steps: usize = 200;
    for (tracks) |t| {
        var i: usize = 0;
        while (i <= steps) : (i += 1) {
            const f = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps));
            const y = t.y1 + f * (t.y2 - t.y1);
            if (y < gap[0] or y > gap[1]) continue;
            const x = t.x1 + f * (t.x2 - t.x1);
            if (x >= band[0] - band_eps_mm and x <= band[1] + band_eps_mm) seen.on_band += 1 else seen.beside += 1;
        }
    }
    return seen;
}

const hub_pads = [_]geometry.Pad{.{ .number = "1", .x = 0.9, .y = 0, .w = 0.9, .h = 0.3 }};
const passive_pads = [_]geometry.Pad{
    .{ .number = "1", .x = -0.51, .y = 0, .w = 0.54, .h = 0.64 },
    .{ .number = "2", .x = 0.51, .y = 0, .w = 0.54, .h = 0.64 },
};
const chain_pins = [_]flat_netlist.FlatPin{
    .{ .ref_des = "U1", .pin = "1" },
    .{ .ref_des = "R1", .pin = "1" },
    .{ .ref_des = "R2", .pin = "1" },
};

// spec: placement/net-topology - a three-pad net whose two passives stack on one edge crosses the gap between their lands on the lands' own band, not down the escape lane in front of both faces
test "a stacked passive pair is chained pad to pad" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // board-d-synth-lmx2595's LMX_RFOUTAM in miniature: a hub pad facing east and
    // two passives stacked east of it, each presenting its WEST pad to the net,
    // so both pads' outward escape axis points away from their shared run.
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 0.9, .hh = 0.9, .pads = &hub_pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.8, .hh = 0.4, .pads = &passive_pads, .fallback = false, .x = 2.5, .y = 1.1 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.8, .hh = 0.4, .pads = &passive_pads, .fallback = false, .x = 2.5, .y = 2.2 },
    };
    const nets = [_]flat_netlist.FlatNet{.{ .name = "SIG", .pins = &chain_pins }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -1,
        .miny = -1,
        .maxx = 4.5,
        .maxy = 3.5,
        .generated = true,
        .rules = .{ .plane_nets = &.{}, .copper_layers = 2 },
    };

    const routed = try router.routeWithOptions(arena, placement, .{}, .{});
    try testing.expectEqual(@as(usize, 1), routed.routed);

    // R1 pad 1 and R2 pad 1 sit at x = 1.99, their lands 1.72..2.26 wide and
    // 1.42..1.88 apart. The hand shape crosses that gap on the lands' own band;
    // the escape join crossed it at x = 1.6565, in the lane in front of both
    // faces, and tapped each land with a stub.
    const crossing = gapCrossing(routed.tracks, .{ 1.42, 1.88 }, .{ 1.72, 2.26 });
    try testing.expect(crossing.on_band > 0);
    try testing.expectEqual(@as(usize, 0), crossing.beside);
}
