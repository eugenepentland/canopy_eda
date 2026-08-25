//! Physical port frames for point-to-point routed nets.
//!
//! A frame is derived from the actual placed pad, not its axis-aligned routing
//! box: centre at the land centre, tangent on the land's long axis after pad +
//! part rotation (and bottom-side mirror), and sign chosen in the direction of
//! propagation through the routed chain. Two-pin series elements therefore
//! inherit their through-body pad axis automatically.

const std = @import("std");
const optimizer = @import("optimizer.zig");
const geometry = @import("geometry.zig");
const pose_math = @import("pose_math.zig");
const rf_path_solver = @import("rf_path_solver.zig");
const flat_netlist = @import("../flat_netlist.zig");

/// Ordered physical frames and end discontinuities for one two-pad net.
pub const Pair = struct {
    start: rf_path_solver.PortFrame,
    end: rf_path_solver.PortFrame,
    layer: u8,
    start_section: rf_path_solver.EndSection,
    end_section: rf_path_solver.EndSection,
    start_width_mm: f64,
    end_width_mm: f64,
};

const Located = struct {
    part: optimizer.Part,
    pad: geometry.Pad,
    centre: [2]f64,
    axis: [2]f64,
    layer: u8,
};

/// Resolve a two-pad net into ordered source/destination frames. `near_start`
/// and `near_end` are the existing guide chain's endpoints and make the result
/// independent of netlist pin order. Branched nets and cross-layer SMD pairs
/// are deliberately refused.
pub fn forNet(
    placement: optimizer.Placement,
    net_i: usize,
    near_start: [2]f64,
    near_end: [2]f64,
    nominal_width: f64,
    target_z: f64,
) ?Pair {
    if (net_i >= placement.nets.len) return null;
    const net = placement.nets[net_i];
    if (net.pins.len != 2) return null;
    const a = locate(placement, net.pins[0].ref_des, net.pins[0].pin) orelse return null;
    const b = locate(placement, net.pins[1].ref_des, net.pins[1].pin) orelse return null;
    const both_smd = !a.pad.thru and !b.pad.thru;
    if (both_smd and a.layer != b.layer) return null;
    const direct = dist2(a.centre, near_start) + dist2(b.centre, near_end);
    const reverse = dist2(b.centre, near_start) + dist2(a.centre, near_end);
    const start = if (direct <= reverse) a else b;
    const end = if (direct <= reverse) b else a;
    const direction = unit(.{ end.centre[0] - start.centre[0], end.centre[1] - start.centre[1] }) orelse return null;
    return .{
        .start = .{ .at = start.centre, .tangent = signedAxis(start.axis, direction) },
        .end = .{ .at = end.centre, .tangent = signedAxis(end.axis, direction) },
        .layer = if (start.pad.thru) end.layer else start.layer,
        .start_section = padSection(start.pad, nominal_width, target_z),
        .end_section = padSection(end.pad, nominal_width, target_z),
        // Match the actual land cross-section at both ends. This deliberately
        // preserves wider lands as physical flares as well as narrower lands
        // as neck-downs; the solver and final clearance probe judge the whole
        // transition rather than silently leaving a width step at the pad.
        .start_width_mm = @min(start.pad.w, start.pad.h),
        .end_width_mm = @min(end.pad.w, end.pad.h),
    };
}

fn locate(placement: optimizer.Placement, ref_des: []const u8, pad_name: []const u8) ?Located {
    for (placement.parts) |part| {
        if (!std.mem.eql(u8, part.ref_des, ref_des)) continue;
        for (part.pads) |pad| {
            if (!std.mem.eql(u8, pad.number, pad_name)) continue;
            const local = if (pad.w >= pad.h) [2]f64{ 1, 0 } else [2]f64{ 0, 1 };
            const mirrored = [2]f64{ if (part.side == .bottom) -local[0] else local[0], local[1] };
            return .{
                .part = part,
                .pad = pad,
                .centre = optimizer.worldPadCenter(&part, pad.x, pad.y),
                .axis = pose_math.rotate(mirrored[0], mirrored[1], part.rot + pad.rot),
                .layer = if (part.side == .bottom) 1 else 0,
            };
        }
    }
    return null;
}

fn padSection(pad: geometry.Pad, nominal_width: f64, target_z: f64) rf_path_solver.EndSection {
    if (!(nominal_width > 0) or !(target_z > 0)) return .{};
    const along = @max(pad.w, pad.h);
    const across = @min(pad.w, pad.h);
    if (!(along > 0) or !(across > 0)) return .{};
    // First-order quasi-TEM width step. The detailed stackup model fixes the
    // nominal line; this local ratio only estimates the pad discontinuity for
    // candidate ranking and intentionally avoids pretending to be a 3-D field
    // solve.
    return .{
        .length_mm = along / 2,
        .z_ohm = target_z * @sqrt(nominal_width / across),
    };
}

fn signedAxis(axis: [2]f64, propagation: [2]f64) [2]f64 {
    return if (axis[0] * propagation[0] + axis[1] * propagation[1] >= 0)
        axis
    else
        .{ -axis[0], -axis[1] };
}

fn dist2(a: [2]f64, b: [2]f64) f64 {
    const dx = a[0] - b[0];
    const dy = a[1] - b[1];
    return dx * dx + dy * dy;
}

fn unit(v: [2]f64) ?[2]f64 {
    const d = std.math.hypot(v[0], v[1]);
    if (d <= 1e-9) return null;
    return .{ v[0] / d, v[1] / d };
}

test "port frame follows a rotated pad long axis in propagation order" {
    const testing = std.testing;
    const pads_a = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.8, .h = 0.2 }};
    const pads_b = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.8, .h = 0.2 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "A", .kind = .hub, .hw = 1, .hh = 1, .pads = &pads_a, .fallback = false, .x = 0, .y = 0, .rot = 45 },
        .{ .ref_des = "B", .kind = .hub, .hw = 1, .hh = 1, .pads = &pads_b, .fallback = false, .x = 5, .y = 5, .rot = 45 },
    };
    const pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "B", .pin = "1" }, .{ .ref_des = "A", .pin = "1" } };
    const nets = [_]optimizer.FlatNet{.{ .name = "RF", .pins = &pins }};
    const placement = fixture(&parts, &nets);
    const pair = forNet(placement, 0, .{ 0, 0 }, .{ 5, 5 }, 0.2, 50).?;
    const root = @sqrt(0.5);
    try testing.expectApproxEqAbs(root, pair.start.tangent[0], 1e-12);
    try testing.expectApproxEqAbs(root, pair.start.tangent[1], 1e-12);
    try testing.expectApproxEqAbs(root, pair.end.tangent[0], 1e-12);
    try testing.expectApproxEqAbs(root, pair.end.tangent[1], 1e-12);
}

test "series land frame uses the through-body pad axis" {
    const testing = std.testing;
    const pads_a = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.3, .h = 0.8 }};
    const pads_b = [_]geometry.Pad{.{ .number = "2", .x = 0, .y = 0, .w = 0.46, .h = 0.40 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &pads_a, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 1, .hh = 1, .pads = &pads_b, .fallback = false, .x = 4, .y = 0 },
    };
    const pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C1", .pin = "2" } };
    const nets = [_]optimizer.FlatNet{.{ .name = "RF_IC", .pins = &pins }};
    const pair = forNet(fixture(&parts, &nets), 0, .{ 0, 0 }, .{ 4, 0 }, 0.2, 50).?;
    try testing.expectEqual([2]f64{ 0, 1 }, pair.start.tangent); // QFN land long axis
    try testing.expectEqual([2]f64{ 1, 0 }, pair.end.tangent); // 0201 through-body axis
    try testing.expectApproxEqAbs(@as(f64, 0.3), pair.start_width_mm, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.4), pair.end_width_mm, 1e-12);
}

fn fixture(parts: []optimizer.Part, nets: []const optimizer.FlatNet) optimizer.Placement {
    return .{
        .parts = parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = nets,
        .priority = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 10,
        .maxy = 10,
        .generated = false,
    };
}
