//! Saved-pose identity: binds a saved layout's poses onto the current
//! flatten's parts — sub-block-scoped origin key first, exact ref string as
//! the legacy fallback, each live part claimed once — and flags the stale
//! poses a re-key must drop rather than pass through. Pure over `LiveRef` +
//! `PartPose`, so the rule is testable without a design block; the page's
//! `rekeyPosesByOrigin` / `rekeyRowsToLive` apply the result.

const std = @import("std");
const PartPose = @import("../layout_sidecar_types.zig").PartPose;
const net_name = @import("../net_name.zig");

/// Composite key "<sub-block prefix>\0<origin>": the NUL separator cannot
/// occur in either part, so distinct (scope, origin) pairs never collide.
const scoped_key_fmt = "{s}\x00{s}";

/// The sub-block scope of a hierarchical ref-des: everything before the last
/// `/` ("hmc733/U14" → "hmc733", "U5" → ""). Origin keys are module-LOCAL, so
/// they only identify a part within one sub-block's scope.
pub fn refPrefix(ref: []const u8) []const u8 {
    return net_name.parent(ref) orelse "";
}

/// One live part's identity for pose resolution: its current flatten ref-des
/// and (possibly empty) module-local origin key.
pub const LiveRef = struct { ref: []const u8, origin: []const u8 };

/// A `resolve` result: pose i's resolved current ref (its stored
/// ref when nothing matched), whether it bound to a live part at all, and
/// whether its STORED ref names some live part (`shadowed`). An unbound pose
/// that is shadowed is stale: the part it was saved for is gone, yet its ref
/// string now belongs to a different live part that another pose already
/// claimed — passing it through would put two poses on one ref.
pub const ResolvedPoses = struct {
    refs: [][]const u8,
    bound: []bool,
    shadowed: []bool,

    /// True when pose `i` must be dropped rather than passed through: it bound
    /// to nothing, and its stored ref would collide with a live part that is
    /// really someone else's (board-e: the parked pose of a deleted "C16"
    /// shadowed the renumbered C_HPF1_IN → C16 and dragged four parts off the
    /// board). An unbound pose whose ref names NO live part is harmless and is
    /// kept, as before — the caller ignores refs it cannot place.
    pub fn dropped(self: ResolvedPoses, i: usize) bool {
        return !self.bound[i] and self.shadowed[i];
    }

    /// How many poses of this resolution are stale and dropped.
    pub fn droppedCount(self: ResolvedPoses) usize {
        var n: usize = 0;
        for (0..self.bound.len) |i| {
            if (self.dropped(i)) n += 1;
        }
        return n;
    }
};

/// Resolve saved poses onto the current flatten's identity, in two passes: the
/// sub-block-scoped origin key binds FIRST — it is the renumber-stable
/// identity, while a ref-des *string* can survive a renumber naming a
/// DIFFERENT part (the recycled-ref mis-bind that scattered board-e's
/// sub-circuits after a netlist edit). Still-unresolved poses then claim their
/// exact ref string (legacy entries saved without an origin). The origin map
/// is scoped by the ref's sub-block prefix, because origin keys are
/// module-local ("U1" names the main IC of EVERY sub-block; an unscoped map
/// would let 13 sub-blocks clobber each other), and each live ref is claimed
/// at most once, so a stale pose can never shadow a genuine one. A pose left
/// unbound whose stored ref names a live part is flagged `shadowed` (see
/// `ResolvedPoses.dropped`) so re-keying can drop it instead of emitting a
/// second, stale pose under a genuine part's ref. Null only on allocation
/// failure.
pub fn resolve(
    alloc: std.mem.Allocator,
    live: []const LiveRef,
    parts: []const PartPose,
) ?ResolvedPoses {
    var by_ref = std.StringHashMapUnmanaged(usize).empty;
    var by_origin = std.StringHashMapUnmanaged(usize).empty;
    for (live, 0..) |lr, i| {
        by_ref.put(alloc, lr.ref, i) catch return null;
        if (lr.origin.len == 0) continue;
        const key = std.fmt.allocPrint(alloc, scoped_key_fmt, .{ refPrefix(lr.ref), lr.origin }) catch return null;
        by_origin.put(alloc, key, i) catch return null;
    }
    const claimed = alloc.alloc(bool, live.len) catch return null;
    @memset(claimed, false);
    const refs = alloc.alloc([]const u8, parts.len) catch return null;
    const bound = alloc.alloc(bool, parts.len) catch return null;
    @memset(bound, false);
    const shadowed = alloc.alloc(bool, parts.len) catch return null;
    @memset(shadowed, false);
    for (parts, 0..) |pp, i| {
        refs[i] = pp.ref;
        if (pp.origin.len == 0) continue;
        const key = std.fmt.allocPrint(alloc, scoped_key_fmt, .{ refPrefix(pp.ref), pp.origin }) catch return null;
        const li = by_origin.get(key) orelse continue;
        if (claimed[li]) continue;
        claimed[li] = true;
        refs[i] = live[li].ref;
        bound[i] = true;
    }
    for (parts, 0..) |pp, i| {
        if (bound[i]) continue;
        const li = by_ref.get(pp.ref) orelse continue;
        shadowed[i] = true;
        if (claimed[li]) continue;
        claimed[li] = true;
        bound[i] = true;
    }
    return .{ .refs = refs, .bound = bound, .shadowed = shadowed };
}

// spec: Web Server - A saved pose binds by sub-block-scoped origin key before its ref string, each live part claimed once, so a renumber-recycled ref cannot mis-bind a pose
test "pose identity binds scoped origin first and refuses a recycled ref" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    // Two sub-blocks share the module-local origin "U1"; at top level the row's
    // "C13" (origin C_ID) renumbered to "C14" while a DIFFERENT part recycled
    // the string "C13".
    const live = [_]LiveRef{
        .{ .ref = "amp1/U7", .origin = "U1" },
        .{ .ref = "dsa/U8", .origin = "U1" },
        .{ .ref = "C13", .origin = "C_NEW" },
        .{ .ref = "C14", .origin = "C_ID" },
    };
    const row = [_]PartPose{
        .{ .ref = "amp1/U7", .origin = "U1", .x = 1, .y = 1, .rot = 0 },
        .{ .ref = "dsa/U8", .origin = "U1", .x = 2, .y = 2, .rot = 0 },
        .{ .ref = "C13", .origin = "C_ID", .x = 3, .y = 3, .rot = 0 },
    };
    const res = resolve(alloc, &live, &row) orelse return error.TestResolveFailed;
    // Scoped origin map: each sub-block's "U1" binds within its own scope —
    // the unscoped last-wins map collapsed all of them onto one pose.
    try std.testing.expectEqualStrings("amp1/U7", res.refs[0]);
    try std.testing.expectEqualStrings("dsa/U8", res.refs[1]);
    // Origin outranks the recycled ref string: the pose follows C_ID to C14
    // instead of landing on whatever part now answers to "C13".
    try std.testing.expectEqualStrings("C14", res.refs[2]);
    try std.testing.expect(res.bound[0] and res.bound[1] and res.bound[2]);
}
