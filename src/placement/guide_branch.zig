//! Match an authored `(branches …)` guide TREE onto one net's router terminals.
//!
//! `route_policy.GuideBranch` is a POSITIONAL contract: branch `i` connects
//! terminal 0 to terminal `i + 1`. That order is the router's own `netPoints`
//! order, which falls out of netlist flattening — a design author cannot see it
//! and must not have to. So an authored tree names its terminals the only way a
//! human can, by where each limb's copper ENDS, and this module turns that
//! geometry into the positional contract the router already consumes.
//!
//! It REFUSES rather than guesses. A tree whose limbs do not land on distinct
//! terminals, or whose count cannot cover the net, yields no guidance at all;
//! the caller then routes the net through its ordinary multi-terminal path.
//! Mis-guiding a net is worse than not guiding it — a wrong root sends the
//! whole tree across the board — and a refusal costs only what the board
//! already did before the form existed.

const std = @import("std");
const route_policy = @import("route_policy.zig");

const Allocator = std.mem.Allocator;

/// One net terminal's board position, in the router's own terminal order. The
/// caller keeps the layer/pad payload; matching is planar because a branch's
/// authored corridor names the copper's path, not the pad's stackup position.
pub const Terminal = struct {
    x: f64,
    y: f64,
};

/// Two candidate terminals whose distances to one authored end differ by less
/// than this are not distinguished by the authored geometry, so the tree is
/// refused instead of resolved on floating-point noise. Board coordinates are
/// millimetres and a pad pitch here is never finer than 0.35 mm, so 1 µm is far
/// below anything an author can have meant to separate.
pub const tie_mm: f64 = 0.001;

/// A resolved tree. `order` permutes the caller's terminals into the positional
/// contract — root first, then the terminal each branch reaches, in authored
/// branch order — so `branches[i]` connects `order[0]` to `order[i + 1]`.
pub const Tree = struct {
    order: []const usize,
    branches: []const route_policy.GuideBranch,
};

/// Why a tree yielded no guidance. Every value leaves the net routing exactly
/// as it would with no `(branches …)` authored at all.
pub const Refusal = enum {
    /// The wave authored no branches for this net.
    none_authored,
    /// A `(branch …)` carried no waypoints, so it names no corridor.
    empty_branch,
    /// Fewer than two terminals resolved: there is no tree to guide.
    too_few_terminals,
    /// The branch count cannot cover the terminals exactly once. A tree is a
    /// COMPLETE specification here (see `resolve`).
    arity,
    /// Two limbs claim one terminal, a limb ends on the root, or an endpoint is
    /// equidistant from two terminals.
    ambiguous,
};

/// What one net's authored tree resolved to.
pub const Result = union(enum) {
    /// A full guide tree, ready for `route_policy.Options.net[i].branches`
    /// once the caller permutes its terminals by `order`.
    tree: Tree,
    /// A two-terminal net with one branch: a one-limb tree IS a waypoint chain,
    /// so it lowers to the ordinary `waypoints` path instead of the tree path
    /// (which needs three terminals to mean anything).
    chain: []const route_policy.Waypoint,
    refused: Refusal,
};

/// Resolve `branches` against `terminals`.
///
/// The root is the terminal minimising the total distance to the branches'
/// FIRST points — the shared point every limb leaves from. Each branch then
/// claims the terminal nearest its LAST point, with the root excluded, and the
/// claims must be distinct.
///
/// The cover must be exact: `branches.len + 1 == terminals.len`. A tree with
/// fewer limbs than the net has drops would leave the router holding a guided
/// subtree plus terminals it must reach some other way, and the positional
/// `GuideBranch` contract has no way to express that; a partial tree therefore
/// refuses and the net routes through the ordinary multi-terminal path, which
/// is the same thing it did before the form existed.
pub fn resolve(
    arena: Allocator,
    branches: []const route_policy.GuideBranch,
    terminals: []const Terminal,
) Allocator.Error!Result {
    if (branches.len == 0) return .{ .refused = .none_authored };
    for (branches) |branch| if (branch.waypoints.len == 0) return .{ .refused = .empty_branch };
    if (terminals.len < 2) return .{ .refused = .too_few_terminals };
    if (branches.len + 1 != terminals.len) return .{ .refused = .arity };

    const root = rootTerminal(branches, terminals) orelse return .{ .refused = .ambiguous };
    const order = try arena.alloc(usize, terminals.len);
    order[0] = root;
    for (branches, order[1..]) |branch, *slot| {
        const last = branch.waypoints[branch.waypoints.len - 1];
        const target = nearest(terminals, last.x, last.y) orelse return .{ .refused = .ambiguous };
        // A limb that ends on the root describes no drop, and would leave one
        // real terminal with no limb at all.
        if (target == root) return .{ .refused = .ambiguous };
        slot.* = target;
    }
    for (order[1..], 0..) |target, i| {
        for (order[1 .. i + 1]) |prior| if (prior == target) return .{ .refused = .ambiguous };
    }
    if (terminals.len == 2) return .{ .chain = branches[0].waypoints };
    return .{ .tree = .{ .order = order, .branches = branches } };
}

/// The terminal every limb leaves from: the one with the smallest total
/// distance to the branches' first authored points. Null when two terminals
/// tie, since the authored geometry then does not say which is the root.
fn rootTerminal(
    branches: []const route_policy.GuideBranch,
    terminals: []const Terminal,
) ?usize {
    var best: usize = 0;
    var best_cost = std.math.inf(f64);
    var tied = false;
    for (terminals, 0..) |terminal, i| {
        var cost: f64 = 0;
        for (branches) |branch| {
            const first = branch.waypoints[0];
            cost += std.math.hypot(terminal.x - first.x, terminal.y - first.y);
        }
        if (cost < best_cost - tie_mm) {
            best = i;
            best_cost = cost;
            tied = false;
            continue;
        }
        if (cost <= best_cost + tie_mm) tied = true;
    }
    if (tied or !std.math.isFinite(best_cost)) return null;
    return best;
}

/// The terminal nearest `(x, y)`, or null when two terminals are equally near
/// within `tie_mm`.
fn nearest(terminals: []const Terminal, x: f64, y: f64) ?usize {
    var best: usize = 0;
    var best_distance = std.math.inf(f64);
    var tied = false;
    for (terminals, 0..) |terminal, i| {
        const distance = std.math.hypot(terminal.x - x, terminal.y - y);
        if (distance < best_distance - tie_mm) {
            best = i;
            best_distance = distance;
            tied = false;
            continue;
        }
        if (distance <= best_distance + tie_mm) tied = true;
    }
    if (tied) return null;
    return best;
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

fn branchOf(points: []const route_policy.Waypoint) route_policy.GuideBranch {
    return .{ .waypoints = points };
}

/// The resolved tree, or null for any other outcome — so a test asserts on the
/// shape it expects without branching in its own body.
fn treeOf(result: Result) ?Tree {
    return switch (result) {
        .tree => |tree| tree,
        else => null,
    };
}

/// The lowered waypoint chain, or null for any other outcome.
fn chainOf(result: Result) ?[]const route_policy.Waypoint {
    return switch (result) {
        .chain => |points| points,
        else => null,
    };
}

// spec: placement/guide-branch - an authored branch tree binds each limb to the terminal nearest its last point and the root to the limbs' shared first point
test "an authored tree binds its limbs to terminals by geometry, not by authored order" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    // Terminals in an order no author can see: the ROOT is last.
    const terminals = [_]Terminal{
        .{ .x = 20, .y = 0 }, // east drop
        .{ .x = 0, .y = 20 }, // south drop
        .{ .x = -20, .y = 0 }, // west drop
        .{ .x = 0, .y = 0 }, // root
    };
    const east = [_]route_policy.Waypoint{
        .{ .x = 2, .y = 0, .layer = 0 },
        .{ .x = 18, .y = 0, .layer = 0 },
    };
    const south = [_]route_policy.Waypoint{
        .{ .x = 0, .y = 2, .layer = 0 },
        .{ .x = 0, .y = 18, .layer = 0 },
    };
    const west = [_]route_policy.Waypoint{
        .{ .x = -2, .y = 0, .layer = 1 },
        .{ .x = -18, .y = 0, .layer = 1 },
    };
    const branches = [_]route_policy.GuideBranch{
        branchOf(&east),
        branchOf(&south),
        branchOf(&west),
    };

    const tree = treeOf(try resolve(arena, &branches, &terminals)) orelse return error.TestExpectedTree;
    // Root first, then one terminal per limb in authored limb order.
    try testing.expectEqualSlices(usize, &.{ 3, 0, 1, 2 }, tree.order);
    try testing.expectEqual(@as(usize, 3), tree.branches.len);
    try testing.expectEqual(@as(f64, 18), tree.branches[0].waypoints[1].x);
}

// spec: placement/guide-branch - a branch tree whose limbs do not land on distinct terminals is refused whole rather than applied to the wrong drops
test "two limbs claiming one terminal refuse the whole tree" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const terminals = [_]Terminal{
        .{ .x = 0, .y = 0 },
        .{ .x = 20, .y = 0 },
        .{ .x = -20, .y = 0 },
    };
    // Both limbs end beside the SAME east drop; the west terminal is orphaned.
    const first = [_]route_policy.Waypoint{ .{ .x = 2, .y = 0, .layer = 0 }, .{ .x = 18, .y = 0, .layer = 0 } };
    const second = [_]route_policy.Waypoint{ .{ .x = 2, .y = 1, .layer = 0 }, .{ .x = 18, .y = 1, .layer = 0 } };
    const branches = [_]route_policy.GuideBranch{ branchOf(&first), branchOf(&second) };

    try testing.expectEqual(Refusal.ambiguous, (try resolve(arena, &branches, &terminals)).refused);
}

// spec: placement/guide-branch - a branch tree whose limb count cannot cover the net's terminals exactly once is refused so the ordinary multi-terminal router runs unchanged
test "an under- or over-specified tree is refused instead of partly applied" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const terminals = [_]Terminal{
        .{ .x = 0, .y = 0 },
        .{ .x = 20, .y = 0 },
        .{ .x = 0, .y = 20 },
        .{ .x = -20, .y = 0 },
    };
    const east = [_]route_policy.Waypoint{.{ .x = 18, .y = 0, .layer = 0 }};
    const south = [_]route_policy.Waypoint{.{ .x = 0, .y = 18, .layer = 0 }};
    const west = [_]route_policy.Waypoint{.{ .x = -18, .y = 0, .layer = 0 }};
    const north = [_]route_policy.Waypoint{.{ .x = 0, .y = -18, .layer = 0 }};

    // Four terminals, two limbs: a partial tree the positional contract cannot
    // express, so nothing is guided.
    const partial = [_]route_policy.GuideBranch{ branchOf(&east), branchOf(&south) };
    try testing.expectEqual(Refusal.arity, (try resolve(arena, &partial, &terminals)).refused);

    // Four terminals, four limbs: one limb too many.
    const over = [_]route_policy.GuideBranch{
        branchOf(&east), branchOf(&south), branchOf(&west), branchOf(&north),
    };
    try testing.expectEqual(Refusal.arity, (try resolve(arena, &over, &terminals)).refused);

    // Nothing authored, and a limb with no points, are the two other no-ops.
    try testing.expectEqual(Refusal.none_authored, (try resolve(arena, &.{}, &terminals)).refused);
    const blank = [_]route_policy.GuideBranch{ branchOf(&east), branchOf(&.{}), branchOf(&west) };
    try testing.expectEqual(Refusal.empty_branch, (try resolve(arena, &blank, &terminals)).refused);
}

// spec: placement/guide-branch - one branch on a two-terminal net lowers to the ordinary waypoint chain instead of a tree
test "a single limb on a two-terminal net becomes a waypoint chain" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const terminals = [_]Terminal{ .{ .x = 20, .y = 0 }, .{ .x = 0, .y = 0 } };
    const points = [_]route_policy.Waypoint{
        .{ .x = 2, .y = 0, .layer = 0 },
        .{ .x = 18, .y = 0, .layer = 1 },
    };
    const branches = [_]route_policy.GuideBranch{branchOf(&points)};

    const chain = chainOf(try resolve(arena, &branches, &terminals)) orelse return error.TestExpectedChain;
    try testing.expectEqual(@as(usize, 2), chain.len);
    try testing.expectEqual(@as(u8, 1), chain[1].layer);

    // One terminal is not a net.
    const lone = [_]Terminal{.{ .x = 0, .y = 0 }};
    try testing.expectEqual(Refusal.too_few_terminals, (try resolve(arena, &branches, &lone)).refused);
}

// spec: placement/guide-branch - a limb ending on the tree's own root terminal refuses the tree rather than leaving a real drop unguided
test "a limb ending on the root is refused" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const terminals = [_]Terminal{
        .{ .x = 0, .y = 0 },
        .{ .x = 20, .y = 0 },
        .{ .x = -20, .y = 0 },
    };
    const east = [_]route_policy.Waypoint{ .{ .x = 2, .y = 0, .layer = 0 }, .{ .x = 18, .y = 0, .layer = 0 } };
    // Doubles back and ends where it started, on the root pad.
    const stub = [_]route_policy.Waypoint{ .{ .x = -2, .y = 0, .layer = 0 }, .{ .x = 0.2, .y = 0, .layer = 0 } };
    const branches = [_]route_policy.GuideBranch{ branchOf(&east), branchOf(&stub) };

    try testing.expectEqual(Refusal.ambiguous, (try resolve(arena, &branches, &terminals)).refused);
}
