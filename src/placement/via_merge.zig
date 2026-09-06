//! Same-net via REUSE — folding a redundant drill onto the one already there.
//!
//! A finishing pass that needs to change layer picks its via site off its own
//! search lattice, which nothing obliges to land on the via a previous pass
//! already dropped for the same net a few hundred microns away. The result is
//! two barrels where one would do: measured on board-a's from-zero board,
//! five same-net pairs with copper gaps of 0.002 … 0.038 mm — near-stacked, but
//! invisible to every rule the board had, because copper clearance exempts a
//! same-net pair (electrically they ARE one node) and the drill rule is
//! net-blind and satisfied at the board's declared 0.2 mm hole-to-hole.
//! `drc.Kind.via_spacing` is the rule that sees them; this is the repair.
//!
//! "Reuse the existing via" is exactly what folding says: the later barrel is
//! deleted and every track end that sat on it is re-anchored onto the survivor,
//! so the layer change happens at the drill that was already paid for. The plan
//! here is pure and deterministic (lower index survives — on a saved layout
//! that is the copper that was there first); the caller owns the copper and
//! applies it, so this works for either representation and the DRC gate stays
//! where the caller's board is.

const std = @import("std");

/// Floating-point slack, matching `drc.eps`: a pair resting exactly on its rule
/// is legal, so only a gap measurably below it is a duplicate.
const eps: f64 = 1e-6;

/// One via as the merge sees it: centre, copper radius, its net's key, the
/// spacing it owes another via of that net, and whether it may be touched.
///
/// `net` is compared by BYTES, so the caller may pass names or interned keys;
/// an empty key never merges (unknown-net copper is nobody's duplicate).
/// `pinned` is copper whose position is somebody else's statement — an RF
/// via-fence site (its pitch is derived from the fenced net's wavelength) or
/// stamped module copper (it is carried and cleared as a unit) — and is left
/// exactly where it is, on both sides of a pair.
pub const ViaPt = struct {
    x: f64,
    y: f64,
    r: f64,
    net: []const u8,
    rule: f64,
    pinned: bool = false,
};

/// One fold: `drop`'s barrel goes and everything anchored on it moves to
/// `keep`'s centre.
pub const Merge = struct { keep: usize, drop: usize };

/// True when `b` crowds `a`'s copper closer than either's spacing rule.
fn crowds(a: ViaPt, b: ViaPt) bool {
    const rule = @max(a.rule, b.rule);
    return std.math.hypot(a.x - b.x, a.y - b.y) - a.r - b.r < rule - eps;
}

/// Every fold the board needs, in a fixed order.
///
/// Pairs are considered lowest-index-first, so the survivor of a cluster is
/// always its earliest member and a chain (c crowds b crowds a) folds onto that
/// one via rather than into a pair of half-merges. A via already folded away is
/// never a survivor and never crowds anything again — its copper is gone.
pub fn plan(arena: std.mem.Allocator, vias: []const ViaPt) std.mem.Allocator.Error![]const Merge {
    var out: std.ArrayList(Merge) = .empty;
    const dropped = try arena.alloc(bool, vias.len);
    @memset(dropped, false);
    for (vias, 0..) |a, i| {
        if (dropped[i] or a.pinned or a.net.len == 0) continue;
        for (vias[i + 1 ..], i + 1..) |b, j| {
            if (dropped[j] or b.pinned) continue;
            if (!std.mem.eql(u8, a.net, b.net)) continue;
            if (!crowds(a, b)) continue;
            dropped[j] = true;
            try out.append(arena, .{ .keep = i, .drop = j });
        }
    }
    return out.toOwnedSlice(arena);
}

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

// spec: placement/router - a via crowding an existing same-net via is folded onto it instead of kept as a second drill
test "plan folds a near-stacked same-net via onto the one that was there first" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    // board-a's measured shape: two 0.4 mm vias 0.402 mm apart — a copper gap
    // of 0.002 mm, well inside the net's own 0.127 mm clearance.
    const near = [_]ViaPt{
        .{ .x = 0, .y = 0, .r = 0.2, .net = "V_5VA", .rule = 0.127 },
        .{ .x = 0.402, .y = 0, .r = 0.2, .net = "V_5VA", .rule = 0.127 },
    };
    const folds = try plan(arena, &near);
    try testing.expectEqual(@as(usize, 1), folds.len);
    try testing.expectEqual(@as(usize, 0), folds[0].keep); // the earlier copper survives
    try testing.expectEqual(@as(usize, 1), folds[0].drop);
    // A legitimate stitch-fence pitch (~1.2 mm) is nowhere near the rule.
    const fence = [_]ViaPt{
        .{ .x = 0, .y = 0, .r = 0.2, .net = "GND", .rule = 0.127 },
        .{ .x = 1.2, .y = 0, .r = 0.2, .net = "GND", .rule = 0.127 },
    };
    try testing.expectEqual(@as(usize, 0), (try plan(arena, &fence)).len);
    // …and a pair resting exactly ON the rule is legal, not a duplicate.
    const exact = [_]ViaPt{
        .{ .x = 0, .y = 0, .r = 0.2, .net = "GND", .rule = 0.127 },
        .{ .x = 0.527, .y = 0, .r = 0.2, .net = "GND", .rule = 0.127 },
    };
    try testing.expectEqual(@as(usize, 0), (try plan(arena, &exact)).len);
}

// spec: placement/router - a same-net via fold never moves fence or stamped copper and never crosses nets
test "plan leaves foreign nets, pinned copper and unknown copper alone" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const mixed = [_]ViaPt{
        // Two DIFFERENT nets at the same tiny gap — that is `via_via`'s job,
        // and folding them would short the board.
        .{ .x = 0, .y = 0, .r = 0.2, .net = "GND", .rule = 0.127 },
        .{ .x = 0.402, .y = 0, .r = 0.2, .net = "V_5VA", .rule = 0.127 },
        // A fence via and a routed via of its own net: the fence's pitch is a
        // statement about the net it shields, so neither side moves.
        .{ .x = 5, .y = 0, .r = 0.2, .net = "GND", .rule = 0.127, .pinned = true },
        .{ .x = 5.402, .y = 0, .r = 0.2, .net = "GND", .rule = 0.127 },
        // Copper with no net key is nobody's duplicate.
        .{ .x = 9, .y = 0, .r = 0.2, .net = "", .rule = 0.127 },
        .{ .x = 9.402, .y = 0, .r = 0.2, .net = "", .rule = 0.127 },
    };
    try testing.expectEqual(@as(usize, 0), (try plan(arena, &mixed)).len);
}

// spec: placement/router - a same-net via fold is never planned onto a via that is itself being folded away
test "a fold dissolves the crowding its neighbour caused, and never survives onto dropped copper" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    // Three barrels 0.402 mm apart: 1 crowds 0, and 2 crowds 1 — but ONLY 1.
    const chain = [_]ViaPt{
        .{ .x = 0, .y = 0, .r = 0.2, .net = "GND", .rule = 0.127 },
        .{ .x = 0.402, .y = 0, .r = 0.2, .net = "GND", .rule = 0.127 },
        .{ .x = 0.804, .y = 0, .r = 0.2, .net = "GND", .rule = 0.127 },
    };
    const folds = try plan(arena, &chain);
    // One fold, and it is enough: with 1 gone, 2 stands 0.404 mm of copper
    // clear of 0, so the board is legal and 2 keeps its own drill. A second
    // fold onto the departed 1 is exactly what must not be planned.
    try testing.expectEqual(@as(usize, 1), folds.len);
    try testing.expectEqual(@as(usize, 0), folds[0].keep);
    try testing.expectEqual(@as(usize, 1), folds[0].drop);
    // A tighter chain, where every member crowds the FIRST one, folds them all
    // onto it — one survivor, never a half-merge.
    const tight = [_]ViaPt{
        .{ .x = 0, .y = 0, .r = 0.2, .net = "GND", .rule = 0.127 },
        .{ .x = 0.402, .y = 0, .r = 0.2, .net = "GND", .rule = 0.127 },
        .{ .x = 0.45, .y = 0, .r = 0.2, .net = "GND", .rule = 0.127 },
    };
    const all = try plan(arena, &tight);
    try testing.expectEqual(@as(usize, 2), all.len);
    try testing.expectEqual(@as(usize, 0), all[0].keep);
    try testing.expectEqual(@as(usize, 0), all[1].keep);
}
