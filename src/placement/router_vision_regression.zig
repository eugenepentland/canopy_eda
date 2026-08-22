//! Route-vision regression fixtures kept outside the size-capped router core.

const std = @import("std");
const router = @import("router.zig");
const optimizer = @import("optimizer.zig");
const flat_netlist = @import("../flat_netlist.zig");
const geometry = @import("geometry.zig");

const testing = std.testing;

const vision_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
const vision_sig_pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } };
const vision_other_pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "R3", .pin = "1" }, .{ .ref_des = "R4", .pin = "1" } };
const VisionFixture = struct { parts: [4]optimizer.Part, nets: [2]flat_netlist.FlatNet };

/// Two nets on a small board: SIG (R1↔R2) and OTHER (R3↔R4), the latter's pads
/// sitting where a SIG vision mask must read them as foreign obstacles.
fn visionFixture() VisionFixture {
    return .{
        .parts = .{
            .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &vision_pad, .fallback = false, .x = 0, .y = 0 },
            .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &vision_pad, .fallback = false, .x = 6, .y = 0 },
            .{ .ref_des = "R3", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &vision_pad, .fallback = false, .x = 3, .y = 3 },
            .{ .ref_des = "R4", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &vision_pad, .fallback = false, .x = 6, .y = 3 },
        },
        .nets = .{
            .{ .name = "SIG", .pins = &vision_sig_pins },
            .{ .name = "OTHER", .pins = &vision_other_pins },
        },
    };
}

fn visionPlacement(fixture: *VisionFixture) optimizer.Placement {
    return .{
        .parts = &fixture.parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &fixture.nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -0.5,
        .miny = -0.5,
        .maxx = 6.5,
        .maxy = 3.5,
        .generated = true,
    };
}

// spec: placement/router - a route records the lattice it searched on, and the vision mask replays the maze's own blocked predicate against a timeline event's copper
test "the recorded pass context reconstructs the router's free-space view" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var fixture = visionFixture();
    const placement = visionPlacement(&fixture);
    const run = try router.routeWithTimeline(arena, placement, .{}, .{});
    // Every event carries the attempt's lattice, `.initial` included.
    try testing.expect(run.pass.recorded());
    for (run.timeline) |event| try testing.expect(event.pass.recorded());
    const grid = run.pass.grid.?;

    const final = run.timeline[run.timeline.len - 1];
    const mask = (try router.visionMask(arena, .{
        .placement = placement,
        .pass = run.pass,
        .net_i = 0, // SIG
        .tracks = final.state.tracks,
        .vias = final.state.vias,
    })).?;
    try testing.expectEqual(grid.nx, mask.grid.nx);
    try testing.expectEqual(grid.ny, mask.grid.ny);
    try testing.expectEqual(mask.n_signal * grid.nx * grid.ny, mask.free.len);

    // R3's pad belongs to OTHER, so SIG may not occupy it.
    const foreign = grid.nearest(3, 3);
    try testing.expectEqual(@as(u8, 0), mask.layer(0)[grid.node(foreign[0], foreign[1])]);
    // SIG's own pad is never an obstacle to SIG.
    const own = grid.nearest(0, 0);
    try testing.expectEqual(@as(u8, 1), mask.layer(0)[grid.node(own[0], own[1])]);
    // Open board between the two rows stays passable.
    const open = grid.nearest(1.5, 1.6);
    try testing.expectEqual(@as(u8, 1), mask.layer(0)[grid.node(open[0], open[1])]);
}

// spec: placement/router - a vision mask is refused rather than guessed when the timeline recorded no lattice or the design's layer count has since changed
test "vision refuses a run with no recorded lattice, an unknown net, or a changed stackup" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var fixture = visionFixture();
    const placement = visionPlacement(&fixture);
    const run = try router.routeWithTimeline(arena, placement, .{}, .{});

    // A timeline from before pass recording: no lattice to replay on.
    try testing.expectEqual(@as(?router.VisionMask, null), try router.visionMask(arena, .{
        .placement = placement,
        .pass = .{},
        .net_i = 0,
    }));
    // A net index past the netlist.
    try testing.expectEqual(@as(?router.VisionMask, null), try router.visionMask(arena, .{
        .placement = placement,
        .pass = run.pass,
        .net_i = placement.nets.len,
    }));
    // The design re-stacked since the run — the recorded grid no longer describes it.
    var stale = run.pass;
    stale.n_signal += 1;
    try testing.expectEqual(@as(?router.VisionMask, null), try router.visionMask(arena, .{
        .placement = placement,
        .pass = stale,
        .net_i = 0,
    }));
}

/// Passable nodes in a vision mask, across every signal layer.
fn countFree(mask: router.VisionMask) usize {
    var n: usize = 0;
    for (mask.free) |c| n += c;
    return n;
}

// spec: placement/router - a net's vision mask uses that net's own class clearance, so a wide net sees a tighter board than a thin one at the same instant
test "a wider net class sees strictly less free space than a thin one" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var fixture = visionFixture();
    const placement = visionPlacement(&fixture);
    const run = try router.routeWithTimeline(arena, placement, .{}, .{});

    const thin = (try router.visionMask(arena, .{ .placement = placement, .pass = run.pass, .net_i = 0 })).?;
    var wide_pass = run.pass;
    wide_pass.base.track_width = run.pass.base.track_width * 4;
    wide_pass.base.clearance = run.pass.base.clearance * 4;
    const wide = (try router.visionMask(arena, .{ .placement = placement, .pass = wide_pass, .net_i = 0 })).?;

    try testing.expect(countFree(wide) < countFree(thin));
}
