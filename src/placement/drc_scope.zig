//! What ONE copper edit can reach — the delta a scoped DRC recheck is scoped by.
//!
//! The editor's server reconcile re-checks a board after every routing edit, and
//! the client posts the WHOLE board each time. So the server's first job is to
//! recover the edit: given the board state it last accepted and the one it was
//! just handed, which tracks and vias actually differ, which nets they belong
//! to, and how far from them a rule can reach. Everything the scoped path is
//! allowed to skip is justified by that answer.
//!
//! The diff is over CONTENT, not position: the client renumbers its arrays
//! freely (an insert in the middle shifts every later index), so a positional
//! comparison would report the whole board as changed for a one-track edit.
//! Each feature is reduced to a 64-bit content key and the two multisets are
//! subtracted; what remains on either side is the edit. Both sides are kept —
//! a moved track is a removal AND an addition, and a rule that was broken at the
//! old position has to be re-judged there as much as at the new one.
//!
//! It lives beneath the server because everything it reads is a placement type,
//! and because the one predicate that is genuinely subtle — whether a fill's
//! content key can have moved — belongs next to the raster that defines that key
//! (`pour.fillKeyStable`), not in an HTTP handler.

const std = @import("std");
const router = @import("router.zig");
const drc = @import("drc.zig");

/// An axis-aligned region of the board, in mm.
pub const Box = struct {
    minx: f64,
    miny: f64,
    maxx: f64,
    maxy: f64,

    /// The region a track occupies, its own width included.
    pub fn ofTrack(t: router.Track) Box {
        const half = t.width / 2;
        return .{
            .minx = @min(t.x1, t.x2) - half,
            .miny = @min(t.y1, t.y2) - half,
            .maxx = @max(t.x1, t.x2) + half,
            .maxy = @max(t.y1, t.y2) + half,
        };
    }

    /// The region a via occupies — the wider of its land and its drill.
    pub fn ofVia(v: router.Via) Box {
        const half = @max(v.dia, v.drill) / 2;
        return .{ .minx = v.x - half, .miny = v.y - half, .maxx = v.x + half, .maxy = v.y + half };
    }

    /// Grow `a` to also contain `b`, seeding it when there was nothing yet.
    pub fn join(a: ?Box, b: Box) Box {
        const prior = a orelse return b;
        return .{
            .minx = @min(prior.minx, b.minx),
            .miny = @min(prior.miny, b.miny),
            .maxx = @max(prior.maxx, b.maxx),
            .maxy = @max(prior.maxy, b.maxy),
        };
    }

    /// This region pushed out by `radius` on every side.
    pub fn grown(self: Box, radius: f64) Box {
        return .{
            .minx = self.minx - radius,
            .miny = self.miny - radius,
            .maxx = self.maxx + radius,
            .maxy = self.maxy + radius,
        };
    }

    /// Do these two regions meet, edges counted as meeting?
    pub fn overlaps(a: Box, b: Box) bool {
        return a.maxx >= b.minx and b.maxx >= a.minx and a.maxy >= b.miny and b.maxy >= a.miny;
    }
};

/// A copper feature's identity for the ledger and for the multiset diff: the
/// exact bytes of its geometry, layer and net. Two features with the same key
/// are the same copper, wherever either sits in its array.
///
/// Coordinates are hashed as their IEEE bit patterns rather than rounded, so
/// "unchanged" here means literally unchanged. A rounding tolerance would make
/// the diff CHEAPER and the recheck WRONG: a sub-tolerance nudge still moves the
/// raster's stamped cells, and a fill borrowed on the strength of it would be
/// the wrong copper.
pub fn trackKey(t: router.Track) u64 {
    var h = std.hash.Wyhash.init(0x7261636b); // "rack"
    for ([_]f64{ t.x1, t.y1, t.x2, t.y2, t.width }) |v| h.update(std.mem.asBytes(&v));
    h.update(std.mem.asBytes(&t.layer));
    h.update(std.mem.asBytes(&t.net));
    return h.final();
}

/// A via's identity, on the same terms: position, land, drill and net.
pub fn viaKey(v: router.Via) u64 {
    var h = std.hash.Wyhash.init(0x76696173); // "vias"
    for ([_]f64{ v.x, v.y, v.dia, v.drill }) |value| h.update(std.mem.asBytes(&value));
    h.update(std.mem.asBytes(&v.net));
    return h.final();
}

/// A VIOLATION's identity, on the same terms as the copper keys above: every
/// field a `drc-dump` line prints, hashed as exact bytes.
///
/// It exists for the background sweep (`drc_sweep.zig`), which has to decide
/// whether a full pass and a scoped answer produced the same findings. That is
/// the same question the copper diff asks about copper, so it gets the same
/// answer: content, not position, and no rounding tolerance. Two rules judging
/// the same board must agree on the bit, and a tolerance here would let a
/// scoped pass drift by a micron per edit without anything noticing.
///
/// `drc_json.violationId` is NOT this: it is a 16-bit UI locator, quantized to
/// 0.01 mm so a human can quote it, and collisions there are a feature. A
/// reconciliation keyed on it would call two different findings one.
pub fn violationKey(v: drc.Violation) u64 {
    var h = std.hash.Wyhash.init(0x76696f6c); // "viol"
    h.update(std.mem.asBytes(&@backingInt(v.kind)));
    h.update(std.mem.asBytes(&@backingInt(v.severity)));
    for ([_]f64{ v.x, v.y, v.gap, v.clearance }) |value| h.update(std.mem.asBytes(&value));
    // 255 for a finding with no single layer, the sentinel `drc_json` uses —
    // `board_layers.max_signal_layers` is 64, so no real index reaches it.
    const layer: u8 = if (v.layer) |l| l.int() else 255;
    h.update(std.mem.asBytes(&layer));
    for ([_]i32{ v.who.net_a, v.who.net_b, v.who.part_a, v.who.part_b, v.who.track_a }) |value| {
        h.update(std.mem.asBytes(&value));
    }
    h.update(v.who.pad_a);
    h.update("\x00");
    h.update(v.who.pad_b);
    h.update("\x00");
    if (v.who.bridgePoints()) |bridge| {
        h.update("\x01");
        for (bridge) |value| h.update(std.mem.asBytes(&value));
    } else h.update("\x00");
    return h.final();
}

/// The copper one edit touched: the features that left the board and the ones
/// that joined it, the nets they belong to, and the region they occupy.
///
/// `tracks` / `vias` hold BOTH sides of the edit (old geometry and new). A rule
/// is re-judged wherever the copper was as well as wherever it is now.
pub const Delta = struct {
    tracks: []const router.Track = &.{},
    vias: []const router.Via = &.{},
    /// One flag per `placement.nets` index: this net's own copper changed.
    /// Out-of-range net indices on a feature are ignored here — they can name
    /// no net's findings — but the feature still counts as changed copper.
    nets: []const bool = &.{},
    /// The union of every changed feature's box, or null when nothing changed.
    box: ?Box = null,
    /// How many features changed, both sides together.
    count: usize = 0,

    /// True when the two board states carry exactly the same copper.
    pub fn isEmpty(self: Delta) bool {
        return self.count == 0;
    }

    /// Did this net's own copper change? False for an unnamed or out-of-range
    /// net index, which names no net's findings.
    pub fn touchesNet(self: Delta, net: i32) bool {
        if (net < 0) return false;
        const i: usize = @intCast(net);
        if (i >= self.nets.len) return false;
        return self.nets[i];
    }
};

fn markNet(nets: []bool, net: i32) void {
    if (net < 0) return;
    const i: usize = @intCast(net);
    if (i < nets.len) nets[i] = true;
}

/// Subtract two board states as multisets of copper features. Everything that
/// appears a different number of times on the two sides lands in the delta.
///
/// Multiset rather than set, deliberately: a board may legitimately carry two
/// identical tracks (a duplicated segment is exactly the kind of junk DRC is
/// asked about), and dropping one of them IS an edit.
pub fn diffCopper(
    arena: std.mem.Allocator,
    old: router.RouteResult,
    new: router.RouteResult,
    net_count: usize,
) std.mem.Allocator.Error!Delta {
    var tracks: std.ArrayList(router.Track) = .empty;
    var vias: std.ArrayList(router.Via) = .empty;
    const nets = try arena.alloc(bool, net_count);
    @memset(nets, false);
    var box: ?Box = null;

    // Balance each content key across the two states: negative means the old
    // board carried more of it, positive means the new one does. Emitting
    // `|balance|` features rather than every feature that carries a changed key
    // is what makes a DUPLICATED track behave: deleting one of two identical
    // segments is one changed feature, not two.
    var track_balance: std.AutoHashMapUnmanaged(u64, i32) = .empty;
    for (old.tracks) |t| {
        const gop = try track_balance.getOrPutValue(arena, trackKey(t), 0);
        gop.value_ptr.* -= 1;
    }
    for (new.tracks) |t| {
        const gop = try track_balance.getOrPutValue(arena, trackKey(t), 0);
        gop.value_ptr.* += 1;
    }
    for (old.tracks) |t| {
        const slot = track_balance.getPtr(trackKey(t)) orelse continue;
        if (slot.* >= 0) continue;
        slot.* += 1;
        try tracks.append(arena, t);
        markNet(nets, t.net);
        box = Box.join(box, Box.ofTrack(t));
    }
    for (new.tracks) |t| {
        const slot = track_balance.getPtr(trackKey(t)) orelse continue;
        if (slot.* <= 0) continue;
        slot.* -= 1;
        try tracks.append(arena, t);
        markNet(nets, t.net);
        box = Box.join(box, Box.ofTrack(t));
    }

    var via_balance: std.AutoHashMapUnmanaged(u64, i32) = .empty;
    for (old.vias) |v| {
        const gop = try via_balance.getOrPutValue(arena, viaKey(v), 0);
        gop.value_ptr.* -= 1;
    }
    for (new.vias) |v| {
        const gop = try via_balance.getOrPutValue(arena, viaKey(v), 0);
        gop.value_ptr.* += 1;
    }
    for (old.vias) |v| {
        const slot = via_balance.getPtr(viaKey(v)) orelse continue;
        if (slot.* >= 0) continue;
        slot.* += 1;
        try vias.append(arena, v);
        markNet(nets, v.net);
        box = Box.join(box, Box.ofVia(v));
    }
    for (new.vias) |v| {
        const slot = via_balance.getPtr(viaKey(v)) orelse continue;
        if (slot.* <= 0) continue;
        slot.* -= 1;
        try vias.append(arena, v);
        markNet(nets, v.net);
        box = Box.join(box, Box.ofVia(v));
    }

    return .{
        .tracks = tracks.items,
        .vias = vias.items,
        .nets = nets,
        .box = box,
        .count = tracks.items.len + vias.items.len,
    };
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

fn trackAt(x1: f64, y1: f64, x2: f64, y2: f64, layer: u8, net: i32) router.Track {
    return .{ .x1 = x1, .y1 = y1, .x2 = x2, .y2 = y2, .layer = layer, .width = 0.2, .net = net };
}

// spec: placement/drc - the copper diff reports only the features that changed, whichever position they hold in the posted arrays
test "the copper diff is a content multiset subtraction, not a positional one" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const a = trackAt(0, 0, 1, 0, 0, 0);
    const b = trackAt(2, 0, 3, 0, 0, 1);
    const c = trackAt(4, 0, 5, 0, 1, 2);
    const old_tracks = [_]router.Track{ a, b, c };
    // The SAME board, renumbered, plus one segment inserted at the front. A
    // positional diff would call every track changed.
    const inserted = trackAt(9, 9, 9.5, 9, 0, 1);
    const new_tracks = [_]router.Track{ inserted, c, a, b };
    const old = router.RouteResult{ .tracks = &old_tracks, .vias = &.{}, .routed = 0, .total = 0 };
    const new = router.RouteResult{ .tracks = &new_tracks, .vias = &.{}, .routed = 0, .total = 0 };

    const delta = try diffCopper(arena, old, new, 3);
    try testing.expectEqual(@as(usize, 1), delta.count);
    try testing.expectEqual(@as(f64, 9), delta.tracks[0].x1);
    try testing.expect(delta.touchesNet(1));
    try testing.expect(!delta.touchesNet(0));
    try testing.expect(!delta.touchesNet(2));

    // A move is BOTH sides: the old position must be re-judged too.
    var moved_tracks = old_tracks;
    moved_tracks[0].x1 += 0.05;
    const moved = try diffCopper(arena, old, .{ .tracks = &moved_tracks, .vias = &.{}, .routed = 0, .total = 0 }, 3);
    try testing.expectEqual(@as(usize, 2), moved.count);
    try testing.expect(moved.box.?.minx <= 0);
    try testing.expect(moved.box.?.maxx >= 1);

    // An identical repost is an empty delta, which is what lets a reconcile
    // skip everything.
    const same = try diffCopper(arena, old, old, 3);
    try testing.expect(same.isEmpty());
    try testing.expect(same.box == null);
}

// spec: placement/drc - two identical copper features are two features, so deleting one of them is an edit
test "the copper diff counts duplicates rather than de-duplicating them" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const a = trackAt(0, 0, 1, 0, 0, 0);
    const twice = [_]router.Track{ a, a };
    const once = [_]router.Track{a};
    const delta = try diffCopper(
        arena,
        .{ .tracks = &twice, .vias = &.{}, .routed = 0, .total = 0 },
        .{ .tracks = &once, .vias = &.{}, .routed = 0, .total = 0 },
        1,
    );
    try testing.expectEqual(@as(usize, 1), delta.count);
    try testing.expect(delta.touchesNet(0));
}

// spec: placement/drc - a via edit is reported with its own geometry so a scoped recheck can grow the region a drill rule reaches
test "the copper diff reports via edits with their drill footprint" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const v = router.Via{ .x = 5, .y = 5, .dia = 0.6, .net = 2, .drill = 0.3 };
    var moved = v;
    moved.x += 0.05;
    const delta = try diffCopper(
        arena,
        .{ .tracks = &.{}, .vias = &.{v}, .routed = 0, .total = 0 },
        .{ .tracks = &.{}, .vias = &.{moved}, .routed = 0, .total = 0 },
        3,
    );
    try testing.expectEqual(@as(usize, 2), delta.count);
    try testing.expect(delta.touchesNet(2));
    const box = delta.box.?;
    try testing.expect(box.minx <= 4.7);
    try testing.expect(box.maxx >= 5.35);
    try testing.expect(Box.grown(box, 0).overlaps(Box.ofVia(v)));
}
