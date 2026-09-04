//! Conservative saved-pose migration for an explicitly renamed rough anchor.

const std = @import("std");
const env = @import("../eval/env.zig");
const identity = @import("../placement/rough_identity.zig");
const net_name = @import("../net_name.zig");

fn prefix(ref: []const u8) []const u8 {
    return net_name.parent(ref) orelse "";
}

/// Bind one unambiguous legacy hub pose to one unbound explicit anchor. The
/// comptime types keep the page's private saved/live records private while this
/// identity rule stays independently testable.
pub fn bind(
    comptime Live: type,
    comptime Pose: type,
    comptime Result: type,
    live: []const Live,
    parts: []const Pose,
    rough: env.RoughSpec,
    res: Result,
) void {
    if (rough.anchor.len == 0) return;
    var ai: ?usize = null;
    for (live, 0..) |lr, i| {
        if (!identity.nameMatch(lr.ref, lr.origin, rough.anchor)) continue;
        if (ai != null) return;
        ai = i;
    }
    const anchor_i = ai orelse return;
    for (res.refs, res.bound) |ref, bound|
        if (bound and std.mem.eql(u8, ref, live[anchor_i].ref)) return;
    var stale_i: ?usize = null;
    for (parts, 0..) |pp, i| {
        if (res.bound[i] or !std.mem.eql(u8, prefix(pp.ref), prefix(live[anchor_i].ref))) continue;
        if (!identity.isHub(pp.ref) and !identity.isHub(pp.origin)) continue;
        if (stale_i != null) return;
        stale_i = i;
    }
    const si = stale_i orelse return;
    res.refs[si] = live[anchor_i].ref;
    res.bound[si] = true;
}

// spec: Web Server - A sole unmatched legacy hub pose migrates to a sole unmatched explicit rough anchor in the same sub-block scope
test "sole legacy hub pose follows an explicit renamed rough anchor" {
    const Live = struct { ref: []const u8, origin: []const u8 };
    const Pose = struct { ref: []const u8, origin: []const u8 };
    const Result = struct { refs: [][]const u8, bound: []bool };
    const live = [_]Live{ .{ .ref = "DIV1", .origin = "DIV1" }, .{ .ref = "C1", .origin = "C_VCC" } };
    const poses = [_]Pose{ .{ .ref = "U1", .origin = "U1" }, .{ .ref = "C1", .origin = "C_VCC" } };
    var refs = [_][]const u8{ "U1", "C1" };
    var bound = [_]bool{ false, true };
    bind(Live, Pose, Result, &live, &poses, .{ .anchor = "DIV1", .present = true }, .{ .refs = &refs, .bound = &bound });
    try std.testing.expect(bound[0]);
    try std.testing.expectEqualStrings("DIV1", refs[0]);
}
