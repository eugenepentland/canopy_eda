//! Process-lifetime memo of controlled-impedance WIDTH SYNTHESIS.
//!
//! Solving `(impedance 50 (layer 1))` for a track width is an iterative inverse:
//! a closed-form seed, then up to five secant steps, each of which runs TWO
//! electrostatic field solves over the trapezoidal, mask-coated cross-section
//! (`impedance.analyzeOnLayer`). On the JLC coated-microstrip process model that
//! is 4–6 s per net class — and it was paid from scratch on every call.
//!
//! Which is every interaction with such a board, not an occasional one:
//! `optimizer.prepare` resolves the net rules on EVERY `solveForRequest`, so the
//! page render, the PNG, `/api/pcb-describe`, the thermal page and every
//! autosave's DRC re-resolve each re-synthesised widths nobody had changed.
//! Measured with `netlisp bench-page --reps 3` (2026-08-29, Debug): of
//! barracuda-base's 8245 ms solve, `net_rules.resolvedNetRules` was 8.1–12.4 s
//! and every other `prepare` step was under 10 ms.
//!
//! ## Why a memo is safe here
//!
//! The synthesised width is a pure function of its arguments — the buildup, the
//! layer, the target, the gap and whether the class's mask artwork coats the
//! trace. `impedance` reads no global state and the allocator it takes is
//! scratch for the field solve. So this memo may only ever skip work: a hit
//! returns the same f64 bits the model would have returned, which is what
//! `identical inputs answer identically without re-solving` exists to hold.
//!
//! ## The key is the argument list, and it cannot drift
//!
//! `content_key`'s reflective walk fingerprints every field of `impedance.Stack`
//! — every foil thickness and etch reduction, every dielectric height and εr,
//! every mask profile, the plane indices and the finished thickness — and it
//! fails the BUILD on a field it cannot reduce to bytes. A property added to the
//! buildup later therefore joins the key automatically instead of being silently
//! left out of it. That is the entire safety argument: a missed input would not
//! make this memo slow, it would make it answer with the wrong width.
//!
//! The board CLEARANCE is not keyed here and does not need to be. It reaches the
//! synthesis only through the gap `impedance_rules.deriveWidths` resolves before
//! calling in (`@max(ground_gap, clearance)`, `resolvedPairGap`), so two boards
//! whose clearances differ either arrive with different gaps — different key —
//! or arrive with the same gap, in which case the synthesis genuinely cannot
//! tell them apart. Keying the resolved gap rather than its inputs is what lets
//! a clearance edit that does not move the gap keep its widths.
//!
//! ## Ownership
//!
//! An entry is two u64 and an optional f64 — plain values, copied in, pointing
//! at nothing. That matters more than its size: every caller's allocator is a
//! per-request arena, so an entry that borrowed one would dangle the moment the
//! request ended. Nothing here is borrowed and nothing needs releasing.

const std = @import("std");
const content_key = @import("content_key.zig");
const impedance = @import("impedance.zig");
const infra_fs = @import("../infra/fs.zig");

/// A 128-bit content fingerprint of one synthesis query, shared with the copper
/// memos so there is one definition of what a fingerprint is.
pub const Key = content_key.Key;

/// Which inverse an entry answers. Folded into the key so a single-ended and a
/// differential query with the same numbers cannot alias.
pub const Mode = enum(u8) { single, diff };

/// The complete argument list of the synthesis, less the buildup and the
/// scratch allocator: everything else `impedance` reads to produce a width.
pub const Query = struct {
    mode: Mode,
    /// The AUTHORED layer, before `impedance.targetLayer` resolves it. Keying
    /// the authored value is the conservative direction: two authored layers
    /// that resolve to one physical layer simply miss each other.
    layer: u8,
    target_ohms: f64,
    /// The resolved ground gap (single-ended) or pair gap (differential).
    gap_mm: f64,
    coated: bool,
};

/// One solved query. `width` is null when the target is unreachable on that
/// layer — which is the model's answer, costs the same five field solves to
/// discover, and is therefore worth memoising exactly like a width.
const Entry = struct {
    key: Key,
    width: ?f64,
};

/// What the memo actually did. Counted rather than inferred, because a key that
/// quietly stops matching looks exactly like a memo that is working: correct
/// answers, full price. `misses` is the number of field syntheses run.
pub const Tally = struct {
    hits: usize = 0,
    misses: usize = 0,
};

/// Queries retained at once. A board contributes one entry per net class, and
/// `pcb-describe` one per class per signal layer, so a few dozen covers every
/// board the process has opened; the bound only exists so an editor session that
/// sweeps target values cannot grow the table without limit.
const max_entries: usize = 256;

/// Separates this memo's key space from the copper memos' keys, so a
/// fingerprint minted here can never be read as one of theirs.
const key_domain: u8 = 0x19;

/// A bounded set of memoised syntheses, least-recently-answered first. One
/// process-wide instance backs the free functions below; tests own their own so
/// they can count hits exactly without depending on what else ran first.
pub const Store = struct {
    mutex: infra_fs.Mutex = .{},
    /// Long-lived backing, deliberately NOT any caller's allocator — every one
    /// of which is an arena freed with its request.
    backing: std.mem.Allocator = std.heap.page_allocator,
    /// Retained queries, oldest answered first: the LRU order eviction reads.
    entries: std.ArrayList(Entry) = .empty,
    limit: usize = max_entries,
    tally: Tally = .{},

    /// The width `q` synthesises against `stack`: from the memo when these
    /// exact inputs have been solved before, and from the model otherwise.
    pub fn widthMm(
        self: *Store,
        scratch: std.mem.Allocator,
        stack: impedance.Stack,
        q: Query,
    ) ?f64 {
        const k = keyOf(stack, q);
        if (self.lookup(k)) |hit| return hit.width;
        // Solved OUTSIDE the lock: this is the multi-second field solve the memo
        // exists to skip, and holding a process-wide mutex across it would
        // serialize every other board behind one board's synthesis. Two threads
        // racing one key both solve it and agree on the answer, because the
        // synthesis is pure; `retain` keeps whichever arrives first.
        const width = switch (q.mode) {
            .single => impedance.resolvedWidthMmOnLayerWithProcess(
                scratch,
                stack,
                q.layer,
                q.target_ohms,
                q.gap_mm,
                q.coated,
            ),
            .diff => impedance.resolvedDiffWidthMmOnLayerWithProcess(
                scratch,
                stack,
                q.layer,
                q.target_ohms,
                q.gap_mm,
                q.coated,
            ),
        };
        self.retain(k, width);
        return width;
    }

    /// What this store has done so far.
    pub fn stats(self: *Store) Tally {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.tally;
    }

    /// Release every retained entry. Nothing is borrowed, so this needs no
    /// agreement with a reader: an in-flight `widthMm` holds only its own copy.
    pub fn deinit(self: *Store) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.entries.deinit(self.backing);
        self.entries = .empty;
    }

    fn lookup(self: *Store, k: Key) ?Entry {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.entries.items, 0..) |e, i| {
            if (!Key.eql(e.key, k)) continue;
            self.tally.hits += 1;
            // Newest at the back: position IS the recency order eviction reads.
            self.entries.appendAssumeCapacity(self.entries.orderedRemove(i));
            return e;
        }
        self.tally.misses += 1;
        return null;
    }

    fn retain(self: *Store, k: Key, width: ?f64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        // Another thread published this query while we were solving it. Its
        // answer is our answer, so there is nothing to reconcile.
        for (self.entries.items) |e| if (Key.eql(e.key, k)) return;
        // A memo failure is never a wrong width: an entry that cannot be
        // retained simply leaves the next identical query paying for itself.
        self.entries.append(self.backing, .{ .key = k, .width = width }) catch return;
        while (self.entries.items.len > self.limit) _ = self.entries.orderedRemove(0);
    }
};

/// The content fingerprint of everything the synthesis reads.
pub fn keyOf(stack: impedance.Stack, q: Query) Key {
    var fp: content_key.Fingerprint = .{};
    fp.tag(key_domain);
    fp.put(impedance.Stack, stack);
    fp.put(Query, q);
    return fp.final();
}

var process_store: Store = .{};

/// `impedance.resolvedWidthMmOnLayerWithProcess` through the process-wide memo.
pub fn resolvedWidthMm(
    scratch: std.mem.Allocator,
    stack: impedance.Stack,
    layer: u8,
    target_ohms: f64,
    ground_gap_mm: f64,
    coated: bool,
) ?f64 {
    return process_store.widthMm(scratch, stack, .{
        .mode = .single,
        .layer = layer,
        .target_ohms = target_ohms,
        .gap_mm = ground_gap_mm,
        .coated = coated,
    });
}

/// `impedance.resolvedDiffWidthMmOnLayerWithProcess` through the same memo.
pub fn resolvedDiffWidthMm(
    scratch: std.mem.Allocator,
    stack: impedance.Stack,
    layer: u8,
    target_ohms: f64,
    pair_gap_mm: f64,
    coated: bool,
) ?f64 {
    return process_store.widthMm(scratch, stack, .{
        .mode = .diff,
        .layer = layer,
        .target_ohms = target_ohms,
        .gap_mm = pair_gap_mm,
        .coated = coated,
    });
}

/// What the process-wide memo has done so far. `misses` counts the syntheses
/// actually run, which is what a test asserting "this did not re-solve" reads.
pub fn stats() Tally {
    return process_store.stats();
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Barracuda's four-layer JLC buildup with the coated-microstrip process
/// profile — the stack whose synthesis costs seconds, and therefore the one
/// worth proving is answered once.
const coated_fixture = struct {
    const copper = [_]impedance.Foil{
        .{ .index = 1, .thickness_mm = 0.035, .width_reduction_mm = 0.0175 },
        .{ .index = 2, .thickness_mm = 0.0152 },
        .{ .index = 3, .thickness_mm = 0.0152 },
        .{ .index = 4, .thickness_mm = 0.035, .width_reduction_mm = 0.0175, .narrow_up = false },
    };
    const dielectrics = [_]impedance.Dielectric{
        .{ .after_layer = 1, .thickness_mm = 0.2104, .er = 4.4 },
        .{ .after_layer = 2, .thickness_mm = 1.065, .er = 4.4 },
        .{ .after_layer = 3, .thickness_mm = 0.2104, .er = 4.4 },
    };
    const planes = [_]u8{2};
    const masks = [_]impedance.Mask{
        .{ .top = true, .er = 3.6, .substrate_mm = 0.02, .copper_mm = 0.012 },
    };

    fn stack() impedance.Stack {
        return .{
            .layers = 4,
            .planes = &planes,
            .dielectrics = &dielectrics,
            .foils = &copper,
            .masks = &masks,
            .board_mm = 1.6,
        };
    }

    /// The same buildup with no coating and no etch taper, so `needsField` is
    /// false and every query on it is a closed form. What the memo does with a
    /// key does not depend on what the key cost to answer, so the tests that
    /// vary inputs use this one and leave the seconds-long field solve to the
    /// single test that is actually about the expensive path.
    fn bare() impedance.Stack {
        return .{
            .layers = 4,
            .planes = &planes,
            .dielectrics = &dielectrics,
            .foils = &plain_copper,
            .board_mm = 1.6,
        };
    }

    const plain_copper = [_]impedance.Foil{
        .{ .index = 1, .thickness_mm = 0.035 },
        .{ .index = 2, .thickness_mm = 0.0152 },
        .{ .index = 3, .thickness_mm = 0.0152 },
        .{ .index = 4, .thickness_mm = 0.035 },
    };
};

// spec: placement/impedance-cache - an identical synthesis query is answered from the memo, with the same bits the model would have returned
test "a repeated width synthesis is answered without re-solving" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var store: Store = .{ .backing = testing.allocator };
    defer store.deinit();

    const stack = coated_fixture.stack();
    const q = Query{ .mode = .single, .layer = 1, .target_ohms = 50, .gap_mm = 0, .coated = true };

    const first = store.widthMm(arena, stack, q).?;
    try testing.expectEqual(Tally{ .hits = 0, .misses = 1 }, store.stats());

    // Every repeat is a hit, and NONE of them runs a second synthesis.
    for (0..4) |_| try testing.expectEqual(first, store.widthMm(arena, stack, q).?);
    try testing.expectEqual(Tally{ .hits = 4, .misses = 1 }, store.stats());

    // And the memoised answer is the model's answer, bit for bit: this memo may
    // only ever skip work, never change what the work would have said.
    const direct = impedance.resolvedWidthMmOnLayerWithProcess(arena, stack, 1, 50, 0, true).?;
    try testing.expectEqual(direct, first);

    // A stack rebuilt in different storage is the same CONTENT, so it hits the
    // entry the first one minted — which is what makes this useful at all, since
    // every request builds its own stack in its own arena.
    const rebuilt = impedance.Stack{
        .layers = 4,
        .planes = try arena.dupe(u8, &coated_fixture.planes),
        .dielectrics = try arena.dupe(impedance.Dielectric, &coated_fixture.dielectrics),
        .foils = try arena.dupe(impedance.Foil, &coated_fixture.copper),
        .masks = try arena.dupe(impedance.Mask, &coated_fixture.masks),
        .board_mm = 1.6,
    };
    try testing.expectEqual(first, store.widthMm(arena, rebuilt, q).?);
    try testing.expectEqual(@as(usize, 1), store.stats().misses);
}

// spec: placement/impedance-cache - changing any keyed input mints a new key and re-solves rather than replaying a stale width
test "a changed input re-solves instead of replaying" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var store: Store = .{ .backing = testing.allocator };
    defer store.deinit();

    const stack = coated_fixture.bare();
    const base = Query{ .mode = .single, .layer = 1, .target_ohms = 50, .gap_mm = 0, .coated = false };
    const fifty = store.widthMm(arena, stack, base).?;

    // A different target: a different width, freshly solved.
    var target = base;
    target.target_ohms = 75;
    const seventy_five = store.widthMm(arena, stack, target).?;
    try testing.expect(seventy_five < fifty);
    try testing.expectEqual(@as(usize, 2), store.stats().misses);

    // A grounded-coplanar gap narrows the same 50 Ω trunk.
    var gapped = base;
    gapped.gap_mm = 0.1524;
    const cpwg = store.widthMm(arena, stack, gapped).?;
    try testing.expect(cpwg < fifty);
    try testing.expectEqual(@as(usize, 3), store.stats().misses);

    // The bottom face references the same plane from the far side of the core,
    // so the same target lands on a much wider trace.
    var bottom = base;
    bottom.layer = 4;
    const on_four = store.widthMm(arena, stack, bottom).?;
    try testing.expect(on_four > fifty);
    try testing.expectEqual(@as(usize, 4), store.stats().misses);

    // And the differential inverse never borrows the single-ended answer.
    var pair = base;
    pair.mode = .diff;
    pair.target_ohms = 100;
    pair.gap_mm = 0.1524;
    const differential = store.widthMm(arena, stack, pair).?;
    try testing.expectEqual(@as(usize, 5), store.stats().misses);
    try testing.expectEqual(
        impedance.resolvedDiffWidthMmOnLayerWithProcess(arena, stack, 1, 100, 0.1524, false).?,
        differential,
    );

    // A PROCESS parameter is keyed just as strictly as the query: thinning the
    // prepreg under the trace re-solves and lands somewhere else.
    const thinner = [_]impedance.Dielectric{
        .{ .after_layer = 1, .thickness_mm = 0.1, .er = 4.4 },
        .{ .after_layer = 2, .thickness_mm = 1.065, .er = 4.4 },
        .{ .after_layer = 3, .thickness_mm = 0.2104, .er = 4.4 },
    };
    var thin_stack = stack;
    thin_stack.dielectrics = &thinner;
    const thin = store.widthMm(arena, thin_stack, base).?;
    try testing.expect(thin < fifty);
    try testing.expectEqual(@as(usize, 6), store.stats().misses);

    // Nothing above disturbed the original entry.
    try testing.expectEqual(fifty, store.widthMm(arena, stack, base).?);
    try testing.expectEqual(@as(usize, 6), store.stats().misses);

    // The rest of the argument list is checked on the KEY rather than on a
    // width, because "these two inputs are the same input" is the only claim the
    // memo makes, and it is the claim a solve would be a slow proxy for. Each of
    // these DOES move the width on a process where it applies — the coating on a
    // masked stack, the etch taper on a tapered one — which is exactly why an
    // entry must never be shared across them.
    var coated = base;
    coated.coated = true;
    try testing.expect(!Key.eql(keyOf(stack, base), keyOf(stack, coated)));

    const tapered = [_]impedance.Foil{
        .{ .index = 1, .thickness_mm = 0.035, .width_reduction_mm = 0.0175 },
        .{ .index = 2, .thickness_mm = 0.0152 },
        .{ .index = 3, .thickness_mm = 0.0152 },
        .{ .index = 4, .thickness_mm = 0.035 },
    };
    var etched = stack;
    etched.foils = &tapered;
    try testing.expect(!Key.eql(keyOf(stack, base), keyOf(etched, base)));

    var masked = stack;
    masked.masks = &coated_fixture.masks;
    try testing.expect(!Key.eql(keyOf(stack, base), keyOf(masked, base)));

    const moved_plane = [_]u8{3};
    var replaned = stack;
    replaned.planes = &moved_plane;
    try testing.expect(!Key.eql(keyOf(stack, base), keyOf(replaned, base)));

    var thicker = stack;
    thicker.board_mm = 0.8;
    try testing.expect(!Key.eql(keyOf(stack, base), keyOf(thicker, base)));

    var six_layer = stack;
    six_layer.layers = 6;
    try testing.expect(!Key.eql(keyOf(stack, base), keyOf(six_layer, base)));

    // Permittivity is keyed alongside thickness: a Rogers core under the same
    // geometry is a different board.
    const rogers = [_]impedance.Dielectric{
        .{ .after_layer = 1, .thickness_mm = 0.2104, .er = 3.66 },
        .{ .after_layer = 2, .thickness_mm = 1.065, .er = 4.4 },
        .{ .after_layer = 3, .thickness_mm = 0.2104, .er = 4.4 },
    };
    var low_dk = stack;
    low_dk.dielectrics = &rogers;
    try testing.expect(!Key.eql(keyOf(stack, base), keyOf(low_dk, base)));
}

// spec: placement/impedance-cache - an unreachable target is memoised as the null the model returned, not re-attempted
test "an unreachable target is memoised too" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var store: Store = .{ .backing = testing.allocator };
    defer store.deinit();

    // 250 Ω on a 0.2104 mm prepreg microstrip is outside the formula's domain;
    // discovering that costs the same five field solves as a width does.
    const q = Query{ .mode = .single, .layer = 1, .target_ohms = 250, .gap_mm = 0, .coated = true };
    const stack = coated_fixture.stack();
    try testing.expectEqual(@as(?f64, null), store.widthMm(arena, stack, q));
    try testing.expectEqual(@as(?f64, null), store.widthMm(arena, stack, q));
    try testing.expectEqual(Tally{ .hits = 1, .misses = 1 }, store.stats());
}

// spec: placement/impedance-cache - an empty stackup is answered null without a field solve, and a board that declares no impedance never reaches the memo at all
test "an empty stackup is answered without solving anything" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var store: Store = .{ .backing = testing.allocator };
    defer store.deinit();

    // `layers = 0` is the evaluator's "no (stackup …) authored". There is no
    // reference plane to solve against, so the model answers null immediately —
    // and the memo keeps that answer like any other rather than re-asking.
    const empty = impedance.Stack{};
    const q = Query{ .mode = .single, .layer = 1, .target_ohms = 50, .gap_mm = 0, .coated = true };
    try testing.expectEqual(@as(?f64, null), store.widthMm(arena, empty, q));
    try testing.expectEqual(@as(?f64, null), store.widthMm(arena, empty, q));
    try testing.expectEqual(Tally{ .hits = 1, .misses = 1 }, store.stats());

    // An empty buildup is still a DISTINCT input: it must not be answered by,
    // nor answer for, a real one.
    try testing.expect(!Key.eql(keyOf(empty, q), keyOf(coated_fixture.stack(), q)));

    // And a board that declares no impedance never asks: `deriveWidths` returns
    // before the stack is even built, so an unimpedanced corpus pays nothing for
    // this memo existing. Nothing above added an entry for it.
    try testing.expectEqual(@as(usize, 1), store.entries.items.len);
}

// spec: placement/impedance-cache - the store is bounded and drops its least recently answered query first
test "the memo is bounded, least recently answered first" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A bare two-layer stack: no etch taper and no mask, so `needsField` is
    // false and each of these queries is a closed form rather than a field
    // solve. Eviction order is what is under test, not the model.
    const foils = [_]impedance.Foil{ .{ .index = 1, .thickness_mm = 0.035 }, .{ .index = 2, .thickness_mm = 0.035 } };
    const planes = [_]u8{2};
    const stack = impedance.Stack{ .layers = 2, .planes = &planes, .foils = &foils, .board_mm = 1.6 };

    var store: Store = .{ .backing = testing.allocator, .limit = 3 };
    defer store.deinit();

    const q = struct {
        fn at(ohms: f64) Query {
            return .{ .mode = .single, .layer = 1, .target_ohms = ohms, .gap_mm = 0, .coated = false };
        }
    };
    for ([_]f64{ 40, 45, 50 }) |ohms| _ = store.widthMm(arena, stack, q.at(ohms));
    try testing.expectEqual(@as(usize, 3), store.entries.items.len);

    // Touching 40 makes it the newest, so the fourth query drops 45.
    _ = store.widthMm(arena, stack, q.at(40));
    _ = store.widthMm(arena, stack, q.at(55));
    try testing.expectEqual(@as(usize, 3), store.entries.items.len);
    const before = store.stats();
    _ = store.widthMm(arena, stack, q.at(40));
    try testing.expectEqual(before.hits + 1, store.stats().hits);
    _ = store.widthMm(arena, stack, q.at(45));
    try testing.expectEqual(before.misses + 1, store.stats().misses);
}
