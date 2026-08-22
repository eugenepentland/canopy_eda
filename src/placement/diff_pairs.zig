//! Differential-pair resolution + router-coupling helpers, factored out of
//! `optimizer.zig`/`router.zig` (both at their guardian file-size caps).
//!
//! A `(net-class … (diff-pair [GAP]))` form marks its member nets as a
//! differential pair. `resolve` groups the flagged nets by class and pairs
//! them (a two-member class directly, a larger class by the `_P`/`_N` and
//! `DP`/`DM` naming convention — the same rule `optimizer.diffMateOfP` uses
//! for placement), producing `DiffPair` records (net indices + target gap).
//! `reorder` sequences each pair's N net immediately after its P net, and
//! `buildCorridor` dilates the routed P copper into a bitset the maze cost
//! model discounts so the N net hugs its twin. An empty pair set makes every
//! helper a no-op, so routing stays byte-identical for boards with no pairs.

const std = @import("std");
const optimizer = @import("optimizer.zig");

const FlatNet = optimizer.FlatNet;
const NetRule = optimizer.NetRule;

/// One resolved differential pair: the P- and N-side net indices (into the
/// design's flattened `nets`) plus the target edge-to-edge coupling gap (mm).
pub const DiffPair = struct { p: usize, n: usize, gap: f64 };

/// A pending corridor build for the N net at index `.n` of some pair: the
/// already-routed P net's index and the pair gap the router turns into a
/// dilation radius (it also needs the live grid pitch + track width).
pub const CorridorReq = struct { p_net: i32, gap: f64 };

/// Fallback coupling gap (mm) when a diff-pair class sets neither an explicit
/// `(diff-pair GAP)` nor a `(clearance …)` — matches `RouteParams`' default
/// copper clearance so a bare `(diff-pair)` couples at the board minimum.
pub const default_gap_mm: f64 = 0.127;

/// Net name after the last '/' — mirrors `optimizer.shortName` so pair naming
/// compares module-local leaves, not hierarchy paths.
fn leaf(s: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, s, '/')) |i| return s[i + 1 ..];
    return s;
}

/// The differential mate LEAF name for a P-side net, or null when `s` is not a
/// P-side name — a private copy of `optimizer.diffMateOfP`'s rule (`…_P`→`…_N`,
/// `…DP`→`…DM`) kept local so this module needs no new cross-file `pub` seam.
fn mate(arena: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error!?[]const u8 {
    if (s.len > 2 and std.mem.endsWith(u8, s, "_P")) {
        const m = try arena.dupe(u8, s);
        m[m.len - 1] = 'N';
        return m;
    }
    if (s.len > 2 and std.mem.endsWith(u8, s, "DP")) {
        const m = try arena.dupe(u8, s);
        m[m.len - 1] = 'M';
        return m;
    }
    return null;
}

/// The coupling gap for a pair whose P net carries `rule`: an explicit
/// `(diff-pair GAP)` wins, else the class `(clearance …)`, else the default.
fn gapOf(rule: NetRule) f64 {
    if (rule.diff_gap > 0) return rule.diff_gap;
    if (rule.clearance > 0) return rule.clearance;
    return default_gap_mm;
}

/// Resolve every diff-pair class into `DiffPair` records. A net is a diff-pair
/// member iff its resolved rule carries `diff_gap >= 0`; members are grouped by
/// class name, then paired (two members directly, more by P/N naming). Unmatched
/// leftovers are dropped — they route as ordinary nets. Empty when no class is
/// flagged, so callers stay on their legacy path.
pub fn resolve(
    arena: std.mem.Allocator,
    nets: []const FlatNet,
    rules: []const NetRule,
) std.mem.Allocator.Error![]const DiffPair {
    var pairs: std.ArrayList(DiffPair) = .empty;
    const used = try arena.alloc(bool, nets.len);
    @memset(used, false);
    for (rules, 0..) |ri, i| {
        if (i >= nets.len or ri.diff_gap < 0 or used[i]) continue;
        var members: std.ArrayList(usize) = .empty;
        for (rules, 0..) |rj, j| {
            if (j >= nets.len or rj.diff_gap < 0) continue;
            if (!std.ascii.eqlIgnoreCase(rj.class.name, ri.class.name)) continue;
            used[j] = true;
            try members.append(arena, j);
        }
        try pairClass(arena, nets, rules, members.items, &pairs);
    }
    return pairs.toOwnedSlice(arena);
}

/// Pair one class's member nets into `pairs`. Two members pair directly
/// (P/N oriented by naming when possible, else lowest index = P for
/// determinism); more members match P→N by the naming convention, leaving
/// unmatched nets out.
fn pairClass(
    arena: std.mem.Allocator,
    nets: []const FlatNet,
    rules: []const NetRule,
    members: []const usize,
    pairs: *std.ArrayList(DiffPair),
) std.mem.Allocator.Error!void {
    if (members.len < 2) return;
    if (members.len == 2) {
        const a = members[0];
        const b = members[1];
        const p_first = (try mate(arena, leaf(nets[a].name))) != null or
            (try mate(arena, leaf(nets[b].name))) == null;
        const p = if (p_first) a else b;
        const n = if (p_first) b else a;
        try pairs.append(arena, .{ .p = p, .n = n, .gap = gapOf(rules[p]) });
        return;
    }
    const matched = try arena.alloc(bool, members.len);
    @memset(matched, false);
    for (members, 0..) |p_i, ii| {
        if (matched[ii]) continue;
        const want = (try mate(arena, leaf(nets[p_i].name))) orelse continue;
        for (members, 0..) |n_i, jj| {
            if (jj == ii or matched[jj]) continue;
            if (!std.ascii.eqlIgnoreCase(leaf(nets[n_i].name), want)) continue;
            matched[ii] = true;
            matched[jj] = true;
            try pairs.append(arena, .{ .p = p_i, .n = n_i, .gap = gapOf(rules[p_i]) });
            break;
        }
    }
}

/// Reorder the router's priority-sorted `order` so each pair's N net routes
/// immediately after its P net (only when BOTH endpoints are in `order` — a
/// pair straddling a filtered plane net is left alone). Returns `order`
/// unchanged when there are no pairs, so the routed result is byte-identical.
pub fn reorder(
    arena: std.mem.Allocator,
    order: []const usize,
    pairs: []const DiffPair,
    n_nets: usize,
) std.mem.Allocator.Error![]const usize {
    if (pairs.len == 0) return order;
    const in_order = try arena.alloc(bool, n_nets);
    @memset(in_order, false);
    for (order) |x| if (x < n_nets) {
        in_order[x] = true;
    };
    const n_of_p = try arena.alloc(i64, n_nets);
    @memset(n_of_p, -1);
    const is_n = try arena.alloc(bool, n_nets);
    @memset(is_n, false);
    for (pairs) |dp| {
        if (dp.p < n_nets and dp.n < n_nets and in_order[dp.p] and in_order[dp.n]) {
            n_of_p[dp.p] = @intCast(dp.n);
            is_n[dp.n] = true;
        }
    }
    var out: std.ArrayList(usize) = .empty;
    for (order) |net_i| {
        if (net_i < n_nets and is_n[net_i]) continue;
        try out.append(arena, net_i);
        if (net_i < n_nets and n_of_p[net_i] >= 0) try out.append(arena, @intCast(n_of_p[net_i]));
    }
    return out.toOwnedSlice(arena);
}

/// Per-net corridor plan: index N → its `CorridorReq`, null for every net that
/// is not the N side of a pair. Empty when there are no pairs.
pub fn corridorPlan(
    arena: std.mem.Allocator,
    n_nets: usize,
    pairs: []const DiffPair,
) std.mem.Allocator.Error![]const ?CorridorReq {
    if (pairs.len == 0) return &.{};
    const out = try arena.alloc(?CorridorReq, n_nets);
    @memset(out, null);
    for (pairs) |dp| {
        if (dp.n < n_nets) out[dp.n] = .{ .p_net = @intCast(dp.p), .gap = dp.gap };
    }
    return out;
}

/// Which occupancy cells a dilation grows from.
const Seed = union(enum) {
    /// Cells carrying exactly this net's copper (the P twin's own trace).
    same: i32,
    /// Cells carrying copper of any net OTHER than `net`; `empty` is the
    /// occupancy grid's unoccupied sentinel.
    foreign: struct { net: i32, empty: i32 },
};

/// True when a cell value is one the dilation grows from.
fn seeded(seed: Seed, cell: i32) bool {
    return switch (seed) {
        .same => |owner| cell == owner,
        .foreign => |f| cell != f.empty and cell != f.net,
    };
}

/// The grid extent a dilation runs over.
const Extent = struct { nx: usize, ny: usize };

/// Paint the Chebyshev `radius` neighbourhood of node `n`, on layer `li` only.
fn paintDisc(out: []bool, ext: Extent, li: usize, n: usize, radius: usize) void {
    const nodes = ext.nx * ext.ny;
    const r: i64 = @intCast(radius);
    const nxi: i64 = @intCast(ext.nx);
    const nyi: i64 = @intCast(ext.ny);
    const cx: i64 = @intCast(n % ext.nx);
    const cy: i64 = @intCast(n / ext.nx);
    var dy: i64 = -r;
    while (dy <= r) : (dy += 1) {
        var dx: i64 = -r;
        while (dx <= r) : (dx += 1) {
            const ix = cx + dx;
            const iy = cy + dy;
            if (ix < 0 or iy < 0 or ix >= nxi or iy >= nyi) continue;
            out[li * nodes + @as(usize, @intCast(iy)) * ext.nx + @as(usize, @intCast(ix))] = true;
        }
    }
}

/// Dilate every seeded occupancy cell by Chebyshev `radius` into a
/// per-(layer·node) bitset, indexed `layer*nodes + node` exactly like the
/// caller's Dijkstra keys.
fn dilate(
    arena: std.mem.Allocator,
    occ: []const []i32,
    ext: Extent,
    radius: usize,
    seed: Seed,
) std.mem.Allocator.Error![]bool {
    const out = try arena.alloc(bool, occ.len * ext.nx * ext.ny);
    @memset(out, false);
    for (occ, 0..) |layer_grid, li| {
        for (layer_grid, 0..) |cell, n| {
            if (seeded(seed, cell)) paintDisc(out, ext, li, n, radius);
        }
    }
    return out;
}

/// Dilate the routed P copper into a per-(layer·node) corridor bitset: every
/// grid cell within Chebyshev `radius` of a cell the P net occupies is `true`,
/// on that cell's own layer. The maze cost model discounts a step landing in a
/// `true` cell so the N net hugs its twin. Sized `occ.len * nx*ny`, indexed
/// `layer*nodes + node` exactly like the caller's Dijkstra keys.
pub fn buildCorridor(
    arena: std.mem.Allocator,
    occ: []const []i32,
    nx: usize,
    ny: usize,
    pnet: i32,
    radius: usize,
) std.mem.Allocator.Error![]const bool {
    return dilate(arena, occ, .{ .nx = nx, .ny = ny }, radius, .{ .same = pnet });
}

/// A foreign-copper dilation request (see `buildBlock`).
pub const BlockReq = struct {
    nx: usize,
    ny: usize,
    /// The routing net, whose OWN copper is never an obstacle to itself.
    net: i32,
    /// The occupancy grid's unoccupied sentinel.
    empty: i32,
    /// Chebyshev dilation radius, in grid cells.
    radius: usize,
};

/// Dilate every FOREIGN net's copper by `req.radius` into an exclusion bitset —
/// the inverse of `buildCorridor`. A COUPLED pair searches one centreline whose
/// copper profile is the whole pair envelope (`2·width + gap`); the maze's grid
/// reserves one lane per net and cannot express a track that wide, so this mask
/// supplies the missing margin by pushing the search that much further off its
/// neighbours' lanes.
pub fn buildBlock(
    arena: std.mem.Allocator,
    occ: []const []i32,
    req: BlockReq,
) std.mem.Allocator.Error![]bool {
    return dilate(
        arena,
        occ,
        .{ .nx = req.nx, .ny = req.ny },
        req.radius,
        .{ .foreign = .{ .net = req.net, .empty = req.empty } },
    );
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn net(name: []const u8) FlatNet {
    return .{ .name = name, .pins = &.{} };
}

/// Assert every listed node of the corridor bitset equals `want` (kept out of
/// the test body so the corridor test stays within the one-top-level-loop rule).
fn expectCells(cor: []const bool, want: bool, idxs: []const usize) !void {
    for (idxs) |n| try testing.expectEqual(want, cor[n]);
}

// spec: placement/router - diff-pair resolution pairs a two-net class and matches a larger class by P/N naming
test "resolve pairs a two-net class directly, a larger class by naming, and drops leftovers" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Two-member class "clk" (no P/N naming) pairs directly by index.
    // Four-member class "usb": USB_DP↔USB_DM pair, USB2_DP with no mate is a
    // dropped leftover, and an unrelated ODD net stays unpaired.
    const nets = [_]FlatNet{
        net("CLKA"), // 0
        net("CLKB"), // 1
        net("USB_DP"), // 2
        net("USB_DM"), // 3
        net("USB2_DP"), // 4  (no USB2_DM present)
        net("SPARE"), // 5  (not in any diff class)
    };
    const rules = [_]NetRule{
        .{ .class = .{ .name = "clk" }, .diff_gap = 0.2 },
        .{ .class = .{ .name = "clk" }, .diff_gap = 0.2 },
        .{ .class = .{ .name = "usb" }, .diff_gap = 0 }, // 0 → default gap
        .{ .class = .{ .name = "usb" }, .diff_gap = 0 },
        .{ .class = .{ .name = "usb" }, .diff_gap = 0 },
        .{}, // diff_gap defaults to -1 → not a diff net
    };
    const pairs = try resolve(arena, &nets, &rules);
    try testing.expectEqual(@as(usize, 2), pairs.len);
    // Two-net class: lowest index is P, gap = explicit 0.2.
    try testing.expectEqual(@as(usize, 0), pairs[0].p);
    try testing.expectEqual(@as(usize, 1), pairs[0].n);
    try testing.expectEqual(@as(f64, 0.2), pairs[0].gap);
    // Named class: DP is P, DM is N, gap falls back to the default.
    try testing.expectEqual(@as(usize, 2), pairs[1].p);
    try testing.expectEqual(@as(usize, 3), pairs[1].n);
    try testing.expectEqual(default_gap_mm, pairs[1].gap);
}

// spec: placement/router - routes a diff pair's N net immediately after its P net
test "reorder sequences each pair's N net right after its P net" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Priority order interleaves the pair (P=1, N=3) with other nets; reorder
    // must pull net 3 to directly follow net 1 without disturbing the rest.
    const order = [_]usize{ 0, 1, 2, 3, 4 };
    const pairs = [_]DiffPair{.{ .p = 1, .n = 3, .gap = 0.15 }};
    const out = try reorder(arena, &order, &pairs, 5);
    try testing.expectEqualSlices(usize, &.{ 0, 1, 3, 2, 4 }, out);

    // No pairs → the exact same slice back (byte-identical routing order).
    const same = try reorder(arena, &order, &.{}, 5);
    try testing.expectEqual(order[0..].ptr, same.ptr);
}

// spec: placement/router - dilates the routed P copper into a per-layer coupling corridor bitset
test "buildCorridor marks the Chebyshev neighbourhood of the P copper" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // 5×5 single-layer grid; the P net (index 7) occupies only the centre
    // node (2,2)=12. A radius-1 dilation lights the 3×3 block around it.
    var grid0: [25]i32 = @splat(0);
    grid0[12] = 7;
    const occ = [_][]i32{grid0[0..]};
    const cor = try buildCorridor(arena, &occ, 5, 5, 7, 1);
    try testing.expectEqual(@as(usize, 25), cor.len);
    try expectCells(cor, true, &.{ 6, 7, 8, 11, 12, 13, 16, 17, 18 });
    // Corners and cells ≥2 away stay outside the corridor.
    try expectCells(cor, false, &.{ 0, 24, 2, 22, 10, 14 });
}

// spec: placement/router - dilates foreign copper into the coupled diff-pair envelope's exclusion mask
test "dp_coupled buildBlock dilates every foreign net and leaves the pair's own copper open" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // 5×5 grid: node 12 carries the routing net (7), node 0 a foreign net (3),
    // everything else empty (-1). Only the FOREIGN cell dilates.
    var grid0: [25]i32 = @splat(-1);
    grid0[12] = 7;
    grid0[0] = 3;
    const occ = [_][]i32{grid0[0..]};
    const block = try buildBlock(arena, &occ, .{ .nx = 5, .ny = 5, .net = 7, .empty = -1, .radius = 1 });
    try expectCells(block, true, &.{ 0, 1, 5, 6 });
    // The pair's own copper and the untouched interior stay routable.
    try expectCells(block, false, &.{ 12, 11, 13, 24, 2, 10 });
}
