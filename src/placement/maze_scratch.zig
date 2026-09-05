//! Per-leg scratch for the router's maze searches: the `dist`/`prev` state a
//! Dijkstra leg needs before its first expansion, and the memo that keeps a
//! node's static-obstacle verdict from being re-derived once per sweep.
//!
//! Both exist to delete O(layers × nodes) work a leg used to pay
//! unconditionally against a search budget of ~10 000 expansions — two whole
//! -array `@memset`s per leg, and a fresh outline/zone/pad evaluation for every
//! node every sweep re-touched. Both are shaped so the routed output cannot
//! change: they replace whole-array resets with bookkeeping that restores
//! exactly the values the resets established, so every comparison the search
//! makes reads the same as before.
//!
//! One implementation, shared: `router.dijkstra` and the rip-up blocker probe
//! `router.softProbe` both take their key space from here rather than each
//! re-deriving the preamble (the probe used to allocate and memset a whole
//! `layers × nodes` space of its own per pad pair).

const std = @import("std");

/// `dist`/`prev` over a whole `layer*nodes + node` key space, with the dirty
/// list that restores it between legs.
///
/// The buffers are initialised ONCE, at allocation, and every first write to a
/// key is recorded, so the next leg restores only the keys this one touched (a
/// flood settles a contiguous region, so the restore is a short sequential
/// walk). The invariant is exact: a key no live leg has written still reads
/// (+inf, -1) — the state the `@memset`s established.
///
/// A dirty list rather than a generation stamp on purpose: a stamp adds a third
/// array to the hot relax loop, and at ~10 relaxations per expansion that extra
/// cache line costs more than the memsets it saves on a board whose legs search
/// wide (measured on black-canyon, 1.5 M expansions over 200 legs, where the
/// stamped variant made the maze phase slower, not faster).
pub const Search = struct {
    dist: []f64 = &.{},
    prev: []i64 = &.{},
    touched: std.ArrayList(usize) = .empty,

    /// Hand this scratch to one leg over `nodes` keys: grow the buffers when the
    /// lattice needs more (and initialise them whole), else undo exactly what
    /// the previous leg wrote.
    pub fn begin(
        self: *Search,
        arena: std.mem.Allocator,
        nodes: usize,
    ) std.mem.Allocator.Error!State {
        if (self.dist.len < nodes) {
            self.dist = try arena.alloc(f64, nodes);
            self.prev = try arena.alloc(i64, nodes);
            @memset(self.dist, std.math.inf(f64));
            @memset(self.prev, -1);
        } else for (self.touched.items) |k| {
            self.dist[k] = std.math.inf(f64);
            self.prev[k] = -1;
        }
        self.touched.clearRetainingCapacity();
        return .{
            .dist = self.dist[0..nodes],
            .prev = self.prev[0..nodes],
            .touched = &self.touched,
            .arena = arena,
        };
    }
};

/// One leg's view of a `Search`: the two arrays it reads directly plus the
/// dirty list `settle` files each first write in.
///
/// `prev` is read raw, never filtered, because it is only ever read at a key
/// this leg settled — the popped node, and the chain the path walk-back follows
/// from the goal — and `settle` writes it at every one of them, search sources
/// included (with -1, the value the `@memset` used to leave there).
pub const State = struct {
    dist: []f64,
    prev: []i64,
    touched: *std.ArrayList(usize),
    arena: std.mem.Allocator,

    /// Settle `k` at cost `d`, reached from key `from` (-1 at a search source).
    /// The first write to a key enters it in the dirty list; `dist[k]` is
    /// already in a register at every call site, so the test is free.
    pub inline fn settle(
        self: State,
        k: usize,
        d: f64,
        from: i64,
    ) std.mem.Allocator.Error!void {
        if (self.dist[k] == std.math.inf(f64)) try self.touched.append(self.arena, k);
        self.dist[k] = d;
        self.prev[k] = from;
    }
};

/// Largest generation a `Memo` entry can carry (its low bit holds the verdict),
/// past which the buffer is zeroed and the count restarts.
const gen_max: u32 = std.math.maxInt(u32) >> 1;

/// Per-node memo of a boolean predicate that is pure only while some ambient
/// state holds — for the router, `staticBlocked` is pure only while the routing
/// net (hence its clearance, keepout admissions and pad-outline mode) is fixed.
///
/// Each entry is `generation << 1 | verdict` and is live only at `gen`, so
/// invalidating the whole memo is a counter bump rather than a `@memset`. That
/// is what lets the owner invalidate per net at a choke point called as often
/// as once per track, instead of only where a full clear could be afforded.
/// An unarmed memo (the default) answers `null` to everything, so a caller on a
/// differently-sized lattice simply recomputes.
pub const Memo = struct {
    entries: []u32 = &.{},
    gen: u32 = 0,

    /// Allocate + arm the memo over `nodes` keys, at generation 1 with every
    /// entry reading "not computed".
    pub fn arm(
        self: *Memo,
        arena: std.mem.Allocator,
        nodes: usize,
    ) std.mem.Allocator.Error!void {
        self.entries = try arena.alloc(u32, nodes);
        @memset(self.entries, 0);
        self.gen = 1;
    }

    /// Orphan every entry. O(1) except on the (unreachable in practice)
    /// generation wrap, which zeroes and restarts.
    pub fn reset(self: *Memo) void {
        if (self.gen >= gen_max) {
            @memset(self.entries, 0);
            self.gen = 1;
            return;
        }
        self.gen += 1;
    }

    /// The memoized verdict for `k`, or null when it has not been computed for
    /// the current generation (which includes every key of an unarmed memo).
    pub inline fn get(self: Memo, k: usize) ?bool {
        if (k >= self.entries.len) return null;
        const entry = self.entries[k];
        if (entry >> 1 != self.gen) return null;
        return (entry & 1) != 0;
    }

    /// Record `hit` for `k` at the current generation. A no-op off the end of
    /// an unarmed (or short) buffer, matching `get`.
    pub inline fn put(self: Memo, k: usize, hit: bool) void {
        if (k >= self.entries.len) return;
        self.entries[k] = (self.gen << 1) | @intFromBool(hit);
    }
};

/// A queued soft-probe state, ordered on cost alone. `key = layer*nodes + node`.
pub const QItem = struct { d: f64, key: usize };

/// Order two soft-probe states by cost.
pub fn qLess(_: void, a: QItem, b: QItem) std.math.Order {
    return std.math.order(a.d, b.d);
}

/// The soft-probe queue (`router.softProbe`, the fine local searches).
fn Managed(comptime T: type, comptime Context: type, comptime lessFn: fn (Context, T, T) std.math.Order) type {
    return struct {
        inner: std.PriorityQueue(T, Context, lessFn),
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, context: Context) Self {
            return .{ .inner = .initContext(context), .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.inner.deinit(self.allocator);
        }

        pub fn add(self: *Self, elem: T) !void {
            return self.inner.push(self.allocator, elem);
        }

        pub fn removeOrNull(self: *Self) ?T {
            return self.inner.pop();
        }

        pub fn peek(self: *const Self) ?T {
            return self.inner.peek();
        }

        pub fn count(self: *const Self) usize {
            return self.inner.count();
        }

        pub fn clearRetainingCapacity(self: *Self) void {
            self.inner.clearRetainingCapacity();
        }
    };
}

pub const Pq = Managed(QItem, void, qLess);

/// A queued maze state: `f` is the A* priority, `d` the cost already paid.
pub const RouteQItem = struct { f: f64, d: f64, key: usize };

/// Order by A* priority, then by cost paid.
///
/// This used to carry a third field — a per-path bend count, ranked between the
/// two — because on the 8-neighbour lattice every interleaving of the same
/// diagonal and orthogonal steps has *exactly* equal length, so a plain queue
/// kept whichever micro-staircase it popped first where a human draws one axis
/// run plus one 45° run. Its own doc called it "deliberately a tie-break, NOT a
/// cost term", on the measurement that a 0.6-pitch bend PRICE took board-a
/// from 81/90 nets and 19 DRC findings to 61/90 and 257.
///
/// The router now prices a corner directly (`router.bend_cost_mult`, a quarter
/// of that measured ceiling), so the quantity this ordered is in `f` and `d`
/// already — and there it composes: it is comparable against real length, it is
/// discounted by the same corridor multipliers as the step it rides on, and A*
/// can reason about it. A second, weaker copy of the same preference in the heap
/// could only ever restate what `f` has already said, so it is gone rather than
/// left contradicting its own justification.
pub fn routeQLess(_: void, a: RouteQItem, b: RouteQItem) std.math.Order {
    const by_f = std.math.order(a.f, b.f);
    return if (by_f == .eq) std.math.order(a.d, b.d) else by_f;
}

/// The maze queue (`router.dijkstra`).
pub const RoutePq = Managed(RouteQItem, void, routeQLess);

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

/// The property every maze leg depends on: whatever the previous leg wrote,
/// the next one opens on a pristine key space.
fn allPristine(search: *const Search) bool {
    for (search.dist) |d| {
        if (d != std.math.inf(f64)) return false;
    }
    for (search.prev) |p| {
        if (p != -1) return false;
    }
    return true;
}

test "begin restores exactly the keys the previous leg settled" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var search = Search{};
    const first = try search.begin(arena, 64);
    try testing.expect(allPristine(&search));
    try first.settle(3, 1.5, -1);
    try first.settle(40, 2.5, 3);
    try first.settle(40, 2.0, 3); // improved again: still one dirty entry
    try testing.expectEqual(@as(usize, 2), search.touched.items.len);

    // The next leg must not see a trace of the last one.
    _ = try search.begin(arena, 64);
    try testing.expect(allPristine(&search));
    try testing.expectEqual(@as(usize, 0), search.touched.items.len);
}

test "begin re-initialises the whole space when the lattice grows" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var search = Search{};
    const small = try search.begin(arena, 8);
    try small.settle(5, 4.0, -1);
    // A bigger key space reallocates; the stale dirty list must not be replayed
    // against the new buffer, and every key of it must read unsettled.
    const big = try search.begin(arena, 256);
    try testing.expectEqual(@as(usize, 256), big.dist.len);
    try testing.expect(allPristine(&search));
}

test "a settled key keeps its predecessor for the path walk-back" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();

    var search = Search{};
    const state = try search.begin(arena_inst.allocator(), 16);
    try state.settle(2, 0, -1); // a search source
    try state.settle(7, 1, 2);
    try testing.expectEqual(@as(i64, -1), state.prev[2]);
    try testing.expectEqual(@as(i64, 2), state.prev[7]);
    try testing.expectEqual(@as(f64, 1), state.dist[7]);
}

test "an unarmed memo answers null and swallows writes" {
    var memo = Memo{};
    memo.put(3, true);
    try testing.expect(memo.get(3) == null);
    memo.reset();
    try testing.expect(memo.get(0) == null);
}

test "a memo answers what it recorded until the generation moves" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();

    var memo = Memo{};
    try memo.arm(arena_inst.allocator(), 32);
    try testing.expect(memo.get(4) == null); // freshly armed: nothing computed
    memo.put(4, true);
    memo.put(5, false);
    try testing.expectEqual(@as(?bool, true), memo.get(4));
    try testing.expectEqual(@as(?bool, false), memo.get(5));
    // A reset orphans both verdicts rather than answering a stale one.
    memo.reset();
    try testing.expect(memo.get(4) == null);
    try testing.expect(memo.get(5) == null);
    try testing.expect(memo.get(31) == null);
}

test "qLess orders soft-probe states by cost" {
    try testing.expectEqual(std.math.Order.lt, qLess({}, .{ .d = 1, .key = 9 }, .{ .d = 2, .key = 0 }));
    try testing.expectEqual(std.math.Order.eq, qLess({}, .{ .d = 2, .key = 9 }, .{ .d = 2, .key = 0 }));
}

// spec: placement/router - the maze queue orders on A* priority alone, with corner count priced into the cost rather than ranked beside it
test "routeQLess orders on priority then on cost paid" {
    const near = RouteQItem{ .f = 5, .d = 5, .key = 1 };
    // Priority outranks everything: a cheaper state pops first whatever shape
    // reached it.
    try testing.expectEqual(std.math.Order.lt, routeQLess({}, .{ .f = 4, .d = 4, .key = 3 }, near));
    // Equal priority falls through to the cost already paid.
    try testing.expectEqual(std.math.Order.lt, routeQLess({}, near, .{ .f = 5, .d = 6, .key = 4 }));
    try testing.expectEqual(std.math.Order.eq, routeQLess({}, near, .{ .f = 5, .d = 5, .key = 9 }));
}

// spec: placement/router - vectorized maze-source discovery preserves ascending node order
test "vectorized maze source discovery preserves node order" {
    const lane = [_]i32{ -1, 7, 3, 7, 7, -1 };
    try testing.expectEqual(@as(?usize, 1), std.mem.findScalarPos(i32, &lane, 0, 7));
    try testing.expectEqual(@as(?usize, 3), std.mem.findScalarPos(i32, &lane, 2, 7));
    try testing.expectEqual(@as(?usize, 4), std.mem.findScalarPos(i32, &lane, 4, 7));
    try testing.expectEqual(@as(?usize, null), std.mem.findScalarPos(i32, &lane, 5, 7));
}

test "a memo generation wrap zeroes rather than aliasing an old verdict" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();

    var memo = Memo{};
    try memo.arm(arena_inst.allocator(), 4);
    memo.put(1, true);
    // Park the counter one bump below the wrap, then bump it: the entry written
    // at generation 1 must not be readable again once the count restarts at 1.
    memo.gen = gen_max;
    memo.reset();
    try testing.expectEqual(@as(u32, 1), memo.gen);
    try testing.expect(memo.get(1) == null);
}
