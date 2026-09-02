//! Every placed pad in WORLD coordinates: exact copper, the net it lands on,
//! the face it sits on, and its drilled bore.
//!
//! Rotating a footprint pad into board space, joining it to a net through the
//! flattened `refdes|pin` list, and resolving an oval slot's world half-vector
//! is one computation with one right answer, and the DRC and the client probe
//! session both need it. They each had their own copy (`drc.padBoxes` and
//! `drc_session.buildPadLites`) — the same join, the same `pad_shape.worldShape`
//! call, the same slot arithmetic, differing only in which struct they poured
//! the result into. A probe whose pad geometry disagrees with the checker's is
//! precisely the bug the session exists to avoid: it refuses copper the DRC
//! accepts, or admits copper the DRC flags, at the pixel level.
//!
//! This module owns the computation. Callers keep their own record types and
//! project this one into them — `WorldPad` carries the authored `geometry.Pad`
//! itself, so a caller reads `pad.number` / `pad.thru` / `pad.drill` straight
//! off it rather than having every field copied through a widening struct.
//!
//! The pad→net join keys on the ref-des slice directly (a per-ref pin list), so
//! a whole-board pass costs ZERO formatted allocations.

const std = @import("std");
const optimizer = @import("optimizer.zig");
const geometry = @import("geometry.zig");
const pad_shape = @import("pad_shape.zig");
const flat_netlist = @import("../flat_netlist.zig");

/// A pad's drilled hole in world space: the bore centre plus the half-vector to
/// an oval slot's two arc centres (`{0,0}` for a round bore, so the slot ends
/// are `(x,y) ± (shx,shy)` either way).
pub const Bore = struct {
    x: f64,
    y: f64,
    shx: f64 = 0,
    shy: f64 = 0,
};

/// One placed pad, world-resolved.
pub const WorldPad = struct {
    /// Index into `placement.parts` of the component this pad belongs to.
    part: usize,
    /// The footprint pad as authored — number, size, `thru`/`npth`, drill.
    pad: geometry.Pad,
    /// Flattened net index, or -1 when the pad lands on no net.
    net: i32,
    /// Signal layer of the pad's face: 0 top, 1 bottom. A `thru` pad is on
    /// every layer and its consumers read `pad.thru` rather than this.
    layer: u8,
    /// Exact world copper (bounding box plus the outline of a custom shape).
    shape: pad_shape.Shape,
    /// The drilled hole, `{0,0}`-centred when the pad has none.
    bore: Bore,
};

/// One (pin-name → net-index) entry in a ref-des's pin list.
const PinNet = struct { pin: []const u8, net: i32 };

/// The net a pad lands on: the last matching pin in `list` (last-wins,
/// mirroring the overwrite a flat `refdes|pin` map would have done), or -1.
fn lookupNet(list: []const PinNet, pin: []const u8) i32 {
    var net: i32 = -1;
    for (list) |e| {
        if (std.mem.eql(u8, e.pin, pin)) net = e.net;
    }
    return net;
}

/// Group the placement's flattened nets into a per-ref-des pin list, keyed on
/// the ref-des slice itself.
fn pinsByRef(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
) std.mem.Allocator.Error!std.StringHashMapUnmanaged(std.ArrayList(PinNet)) {
    var by_ref: std.StringHashMapUnmanaged(std.ArrayList(PinNet)) = .empty;
    for (placement.nets, 0..) |net, ni| {
        for (net.pins) |pin| {
            const gop = try by_ref.getOrPut(arena, pin.ref_des);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(arena, .{ .pin = pin.pin, .net = @intCast(ni) });
        }
    }
    return by_ref;
}

/// Every pad of every placed part, in placement order (part-major, then the
/// footprint's own pad order) — so a caller may index the result alongside its
/// own parallel arrays.
pub fn build(arena: std.mem.Allocator, placement: optimizer.Placement) std.mem.Allocator.Error![]const WorldPad {
    var by_ref = try pinsByRef(arena, placement);
    var list: std.ArrayList(WorldPad) = .empty;
    for (placement.parts, 0..) |part, pi| {
        const pins: []const PinNet = if (by_ref.get(part.ref_des)) |l| l.items else &.{};
        for (part.pads) |pad| {
            const centre = optimizer.worldPadCenter(&part, pad.x, pad.y);
            try list.append(arena, .{
                .part = pi,
                .pad = pad,
                .net = lookupNet(pins, pad.number),
                .layer = if (part.side == .bottom) 1 else 0,
                .shape = try pad_shape.worldShape(arena, part, pad),
                .bore = bore(part, pad, centre),
            });
        }
    }
    return list.toOwnedSlice(arena);
}

/// The world bore of `pad` on `part`, given its already-rotated `centre`. A
/// slot's half-vector is the offset from the centre to one arc centre, taken
/// through the SAME world transform as the centre itself so a rotated
/// footprint's slot points the way its copper does.
fn bore(part: optimizer.Part, pad: geometry.Pad, centre: [2]f64) Bore {
    if (!pad.isSlot()) return .{ .x = centre[0], .y = centre[1] };
    const end = optimizer.worldPadCenter(&part, pad.x + pad.slot_half[0], pad.y + pad.slot_half[1]);
    return .{ .x = centre[0], .y = centre[1], .shx = end[0] - centre[0], .shy = end[1] - centre[1] };
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: placement/router - one shared pass resolves every placed pad's world copper, net and bore, so the DRC and the client probe read identical pad geometry
test "world pads carry the joined net, the rotated copper and a rotated slot bore" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // R1 sits at (10, 5) rotated a quarter turn, with an oval slot whose half
    // vector points along the footprint's +x. U2 is unplaced at the origin and
    // its pad lands on no net at all.
    const r1_pads = [_]geometry.Pad{.{
        .number = "1",
        .x = 1,
        .y = 0,
        .w = 0.8,
        .h = 0.4,
        .thru = true,
        .drill = 0.3,
        .slot_half = .{ 0.2, 0 },
    }};
    const u2_pads = [_]geometry.Pad{.{ .number = "A1", .x = 0, .y = 0, .w = 0.5, .h = 0.5 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 1, .hh = 0.5, .pads = &r1_pads, .fallback = false, .x = 10, .y = 5, .rot = 90 },
        .{ .ref_des = "U2", .kind = .hub, .hw = 1, .hh = 1, .pads = &u2_pads, .fallback = false, .x = 0, .y = 0, .side = .bottom },
    };
    const pins = [_]flat_netlist.FlatPin{.{ .ref_des = "R1", .pin = "1" }};
    const nets = [_]optimizer.FlatNet{.{ .name = "SIG", .pins = &pins }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 0,
        .maxy = 0,
        .generated = true,
    };

    const world = try build(arena, placement);
    try testing.expectEqual(@as(usize, 2), world.len);

    // The joined net, the owning part, and the top face.
    try testing.expectEqual(@as(i32, 0), world[0].net);
    try testing.expectEqual(@as(usize, 0), world[0].part);
    try testing.expectEqual(@as(u8, 0), world[0].layer);
    try testing.expectEqualStrings("1", world[0].pad.number);

    // The quarter turn takes the pad's local +x offset onto the board's +y, so
    // the world bore is a millimetre ABOVE the part origin, not beside it …
    try testing.expectApproxEqAbs(@as(f64, 10), world[0].bore.x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 6), world[0].bore.y, 1e-9);
    // … and the slot half-vector turns with it: 0.2 mm along +y, not +x.
    try testing.expectApproxEqAbs(@as(f64, 0), world[0].bore.shx, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.2), world[0].bore.shy, 1e-9);
    // The copper box turns too — the 0.8 x 0.4 pad is 0.4 wide and 0.8 tall.
    try testing.expectApproxEqAbs(@as(f64, 0.4), world[0].shape.x1 - world[0].shape.x0, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.8), world[0].shape.y1 - world[0].shape.y0, 1e-9);

    // An unjoined pad on a bottom-side part: no net, and the far face.
    try testing.expectEqual(@as(i32, -1), world[1].net);
    try testing.expectEqual(@as(u8, 1), world[1].layer);
    // A round bore reports the pad centre with a zero half-vector.
    try testing.expectEqual(@as(f64, 0), world[1].bore.shx);
    try testing.expectEqual(@as(f64, 0), world[1].bore.shy);
}
