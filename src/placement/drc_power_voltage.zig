//! DRC presentation of the shared source-to-load voltage solve.
const std = @import("std");
const drc = @import("drc.zig");
const optimizer = @import("optimizer.zig");
const power_voltage = @import("power_voltage.zig");

pub fn report(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(drc.Violation),
    placement: optimizer.Placement,
    assessments: []const power_voltage.Assessment,
) std.mem.Allocator.Error!void {
    var unknown_net: ?usize = null;
    for (assessments) |a| {
        if (a.exceeded()) try append(alloc, out, placement, a, .power_voltage_drop);
        if (a.reason.len > 0 and unknown_net != a.net) {
            try append(alloc, out, placement, a, .power_voltage_unverified);
            unknown_net = a.net;
        }
    }
}

fn append(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(drc.Violation),
    placement: optimizer.Placement,
    a: power_voltage.Assessment,
    kind: drc.Kind,
) std.mem.Allocator.Error!void {
    var x: f64 = 0;
    var y: f64 = 0;
    var part_i: i32 = -1;
    for (placement.parts, 0..) |part, i| {
        if (!std.mem.eql(u8, part.ref_des, a.load)) continue;
        x = part.x;
        y = part.y;
        part_i = @intCast(i);
        break;
    }
    const note = if (kind == .power_voltage_unverified)
        try std.fmt.allocPrint(alloc, "unable to verify source-to-load loop: {s}", .{a.reason})
    else
        try std.fmt.allocPrint(alloc, "{s}: modeled copper loss {d:.3} mV exceeds {d:.3} mV budget at {d} C{s}", .{
            a.load,                                                                                   a.knownDrop() * 1000, a.budget.limit_v * 1000, a.budget.copper_temperature_c,
            if (a.return_drop_v == null) "; return path remains unverified" else " including return",
        });
    try out.append(alloc, .{
        .x = x,
        .y = y,
        .gap = a.knownDrop(),
        .clearance = a.budget.limit_v,
        .kind = kind,
        .severity = drc.defaultSeverity(kind),
        .who = .{ .net_a = @intCast(a.net), .part_a = part_i, .extra = .{ .note = note } },
    });
}
