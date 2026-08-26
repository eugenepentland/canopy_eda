//! Process-lifetime memo of one board's reduced copper fill.
//!
//! Every reporting DRC pass begins by rastering the board twice over: each
//! net's declared plane/pour on each carrying layer plus each hand-drawn zone,
//! reduced to the kept fill components the Gerber cuts
//! (`drc_compose.filledTopology`), and then the connectivity layer's own
//! whole-board zone raster (`net_open.zoneFills`). Those two rasters ARE the
//! cost of the reporting seam, and both were paid from scratch on EVERY call —
//! the DRC endpoint, the page blob, the `?derived=1` payload, `describe` and
//! the fab gate each re-poured a board nobody had touched, and an editor
//! reconcile paid it several times per edit.
//!
//! Measured with `netlisp bench-page --reps 3` (2026-08-26, Debug, same
//! machine and same boards, memo forced off vs on): barracuda's reporting DRC
//! 3480 ms → 758 ms, barracuda-base 8140 ms → 542 ms, cyclops-interposer
//! 750 ms → 6 ms, with byte-identical DRC counts on every board in the corpus.
//! What is left is rule EVALUATION over the fill (`drc.checkWithZones` and the
//! return-path rule), which this does not touch.
//!
//! The fill is a pure function of the board, so this memo keys on the board
//! itself: a 128-bit fingerprint of the placement, the routed copper and the
//! user zones (`key`). Content, not identity — two requests that re-solve one
//! design from one sidecar build different `Placement` values at different
//! addresses and must share an entry, while a board that moved by a micron
//! must not. That also makes the memo safe to share process-wide: a key is
//! reachable only by a caller holding a byte-identical board, so two projects
//! in one process can never read each other's copper through it.
//!
//! Entries are pinned to the page allocator because every caller's allocator is
//! a per-request arena that outlives nothing. A hit therefore BORROWS — a
//! whole-board fill is tens of megabytes of label grid, so copying it back per
//! call would hand most of the saving straight back — and the borrow is
//! refcounted: eviction unlinks an entry and the last `release` frees it.
//!
//! Retention is not a memory cost in practice: with the four largest boards in
//! the corpus held at once, peak RSS MEASURED LOWER than without the memo
//! (523 MB vs 618 MB), because what it retains is smaller than the per-request
//! arenas the repeated pours were allocating and freeing.
//!
//! The borrow's rule, which every DRC layer beneath `drc_compose` already
//! obeys: NOTHING in a returned verdict may point into a fill. Violations carry
//! coordinates and indices, and their two strings (`Parties.pad_a`/`pad_b`) are
//! footprint pad numbers owned by the placement; the connectivity statuses name
//! `placement.nets`. A future rule that wants to report a fill CONTOUR must
//! copy it into the caller's arena, not hand out the borrowed one.

const std = @import("std");
const infra_fs = @import("../infra/fs.zig");
const drc = @import("drc.zig");
const optimizer = @import("optimizer.zig");
const pour = @import("pour.zig");
const router = @import("router.zig");

/// Two independent 64-bit hashes of every input the fill is derived from. Two
/// rather than one because a memo that answers with the WRONG board's copper is
/// a silently wrong DRC verdict, and 64 bits is not enough margin against that
/// failure mode — the route-space cache keys the same way for the same reason.
pub const Key = struct { lo: u64, hi: u64 };

/// One board's whole reduced fill: the topology zones (one node per kept fill
/// component, with its holes), the per-net carrying-layer rasters whose labels
/// the connectivity layer samples, and that layer's own user-zone rasters.
pub const Fills = struct {
    zones: []const drc.TopologyZone = &.{},
    plane_fills: []const pour.NetFills = &.{},
    /// The user-zone rasters the CONNECTIVITY layer samples
    /// (`net_open.zoneFills`). A different raster from the topology zones
    /// above — it is taken over the board's physical copper rather than the
    /// pour-priority model — and on a board with a handful of big drawn pours
    /// it is the larger half of the two.
    zone_fills: []const pour.Fill = &.{},
};

/// Boards retained at once. A design under edit mints a fresh key per change,
/// so this is a window over recent board states rather than a per-design table:
/// four leaves room for the board being edited plus the surfaces that trail it
/// by an edit (the page blob, the derived payload, describe).
const max_boards: usize = 4;
/// Byte ceiling over every retained fill together. One fill's label grid is
/// capped at `pour`'s three million cells (12 MB) and a dense board pours a
/// dozen of them, so a barracuda-class entry is tens of megabytes.
const max_fill_bytes: usize = 384 * 1024 * 1024;

/// One memoised board, its arena, and the readers currently borrowing it.
pub const Entry = struct {
    store: *Store,
    key: Key,
    arena: std.heap.ArenaAllocator,
    fills: Fills,
    bytes: usize,
    /// Live borrows. The entry is freed when this reaches zero AND it is no
    /// longer reachable — evicting under a reader must not free what it reads.
    refs: usize,
    /// Unlinked from its store already; the last `release` frees it.
    dropped: bool,
};

/// A live borrow of a memoised fill. The caller reads `fills` for as long as it
/// holds this and `release`s once its DRC pass is done.
pub const Held = struct {
    entry: ?*Entry = null,

    /// The borrowed fill, or the empty fill when nothing is held.
    pub fn fills(self: Held) Fills {
        const entry = self.entry orelse return .{};
        return entry.fills;
    }

    /// End the borrow. Idempotent, so a `defer` beside the acquisition covers
    /// every path out of the DRC pass.
    pub fn release(self: *Held) void {
        const entry = self.entry orelse return;
        self.entry = null;
        entry.store.releaseEntry(entry);
    }
};

/// A bounded set of memoised board fills, least-recently-used first. One
/// process-wide instance backs the DRC seam (`acquire`/`put` below); tests own
/// their own so they can bound it and watch eviction without touching that one.
pub const Store = struct {
    mutex: infra_fs.Mutex = .{},
    /// Long-lived backing for the entries — deliberately NOT any caller's
    /// allocator, every one of which is an arena freed with its request.
    backing: std.mem.Allocator = std.heap.page_allocator,
    /// Retained boards, oldest borrow first: the LRU order eviction reads.
    entries: std.ArrayList(*Entry) = .empty,
    bytes: usize = 0,
    max_boards: usize = max_boards,
    max_bytes: usize = max_fill_bytes,

    /// Borrow the memoised fill for `k`, or an empty hold on a miss.
    pub fn acquire(self: *Store, k: Key) Held {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.entries.items, 0..) |entry, i| {
            if (entry.key.lo != k.lo or entry.key.hi != k.hi) continue;
            entry.refs += 1;
            // Newest at the back: position IS the recency order eviction reads.
            self.entries.appendAssumeCapacity(self.entries.orderedRemove(i));
            return .{ .entry = entry };
        }
        return .{};
    }

    /// Retain a freshly poured fill for `k`, deep-copied out of the caller's
    /// arena. A memo failure is never a DRC failure: an allocation error, an
    /// oversized board, or a key another thread published first all leave the
    /// caller's own freshly poured fill standing.
    pub fn put(self: *Store, k: Key, fills: Fills) void {
        // Built OUTSIDE the lock: the copy walks every label grid, and holding
        // the mutex across it would serialize DRC passes on unrelated boards
        // behind one board's copy.
        const entry = self.build(k, fills) orelse return;
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.entries.items) |existing| {
            if (existing.key.lo == k.lo and existing.key.hi == k.hi) return destroy(entry);
        }
        self.entries.append(self.backing, entry) catch return destroy(entry);
        self.bytes += entry.bytes;
        self.trim();
    }

    /// Release every retained fill. Entries still borrowed are unlinked and
    /// freed by their last `release`, so a store may only be deinitialized once
    /// every pass reading it has ended.
    pub fn deinit(self: *Store) void {
        self.mutex.lock();
        for (self.entries.items) |entry| unlink(entry);
        self.entries.deinit(self.backing);
        self.entries = .empty;
        self.bytes = 0;
        self.mutex.unlock();
    }

    fn build(self: *Store, k: Key, fills: Fills) ?*Entry {
        const entry = self.backing.create(Entry) catch return null;
        entry.* = .{
            .store = self,
            .key = k,
            .arena = std.heap.ArenaAllocator.init(self.backing),
            .fills = .{},
            .bytes = 0,
            .refs = 0,
            .dropped = false,
        };
        entry.fills = dupeFills(entry.arena.allocator(), fills) catch {
            destroy(entry);
            return null;
        };
        entry.bytes = entry.arena.queryCapacity();
        if (entry.bytes > self.max_bytes) {
            destroy(entry);
            return null;
        }
        return entry;
    }

    /// Evict least-recently-borrowed boards until the store is inside both
    /// bounds. Called with the mutex held.
    fn trim(self: *Store) void {
        while (self.entries.items.len > self.max_boards or self.bytes > self.max_bytes) {
            const evicted = self.entries.orderedRemove(0);
            self.bytes -= evicted.bytes;
            unlink(evicted);
        }
    }

    fn releaseEntry(self: *Store, entry: *Entry) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        entry.refs -= 1;
        if (entry.dropped and entry.refs == 0) destroy(entry);
    }
};

/// Drop the store's own claim on an unlinked entry: free it now when nothing
/// reads it, otherwise leave it to the last reader's `release`.
fn unlink(entry: *Entry) void {
    if (entry.refs == 0) return destroy(entry);
    entry.dropped = true;
}

fn destroy(entry: *Entry) void {
    const backing = entry.arena.child_allocator;
    entry.arena.deinit();
    backing.destroy(entry);
}

/// The one store the DRC seam reads. Process-wide rather than owned by the web
/// server because the surfaces that pour the same board include several that
/// never see a `Server` — the fab gate, `describe`, `bench-page`, the route
/// CLIs — and a content key makes sharing between them exact.
var process_store: Store = .{};

/// Borrow the process-wide memo of `k`. Release the hold when the DRC pass
/// reading it ends.
pub fn acquire(k: Key) Held {
    return process_store.acquire(k);
}

/// Retain a freshly poured fill in the process-wide memo.
pub fn put(k: Key, fills: Fills) void {
    process_store.put(k, fills);
}

// ── Deep copy out of the caller's arena ───────────────────────────────────
// Every slice AND every string is duplicated: the source fill was poured into
// the request arena that computed it, and the net names inside it point into
// the evaluator's design buffers. A retained entry must outlive both.

fn dupeFills(a: std.mem.Allocator, src: Fills) std.mem.Allocator.Error!Fills {
    const zones = try a.alloc(drc.TopologyZone, src.zones.len);
    for (src.zones, zones) |s, *d| {
        d.* = s;
        d.net = try a.dupe(u8, s.net);
        d.poly = try a.dupe([2]f64, s.poly);
        d.holes = try dupePolys(a, s.holes);
    }
    const plane_fills = try a.alloc(pour.NetFills, src.plane_fills.len);
    for (src.plane_fills, plane_fills) |s, *d| d.* = .{
        .net_name = try a.dupe(u8, s.net_name),
        .layers = try dupeLayers(a, s.layers),
        .fills = try dupeGrids(a, s.fills),
    };
    return .{ .zones = zones, .plane_fills = plane_fills, .zone_fills = try dupeGrids(a, src.zone_fills) };
}

fn dupePolys(a: std.mem.Allocator, polys: []const []const [2]f64) std.mem.Allocator.Error![]const []const [2]f64 {
    const out = try a.alloc([]const [2]f64, polys.len);
    for (polys, out) |s, *d| d.* = try a.dupe([2]f64, s);
    return out;
}

fn dupeLayers(a: std.mem.Allocator, specs: []const pour.LayerSpec) std.mem.Allocator.Error![]const pour.LayerSpec {
    const out = try a.alloc(pour.LayerSpec, specs.len);
    for (specs, out) |s, *d| {
        d.* = s;
        d.net = switch (s.net) {
            .named => |name| .{ .named = try a.dupe(u8, name) },
            .ground => .ground,
        };
        d.clip = try a.dupe([2]f64, s.clip);
        d.higher = try dupePolys(a, s.higher);
    }
    return out;
}

fn dupeGrids(a: std.mem.Allocator, fills: []const pour.Fill) std.mem.Allocator.Error![]const pour.Fill {
    const out = try a.alloc(pour.Fill, fills.len);
    for (fills, out) |s, *d| {
        d.* = s;
        d.labels = try a.dupe(i32, s.labels);
        d.contours = try dupePolys(a, s.contours);
        const holes = try a.alloc([]const []const [2]f64, s.holes.len);
        for (s.holes, holes) |src_holes, *dst_holes| dst_holes.* = try dupePolys(a, src_holes);
        d.holes = holes;
    }
    return out;
}

// ── Fingerprint ───────────────────────────────────────────────────────────

/// The board fingerprint the memo is keyed on: every field of the placement
/// except the three that record how the arrangement was ARRIVED at, plus the
/// routed copper and the user zones.
///
/// The walk is reflective on purpose. A hand-picked field list is exactly how a
/// memo goes stale — someone adds a rule that changes what a pour clears, and
/// the key never notices — so every field of every input is folded in unless it
/// is named below, and a new one is covered the day it is declared.
pub fn key(
    placement: optimizer.Placement,
    routed: router.RouteResult,
    zones: []const pour.UserZone,
) Key {
    var fp: Fingerprint = .{};
    const info = @typeInfo(optimizer.Placement).@"struct";
    inline for (info.field_names, info.field_types) |name, Field| {
        if (comptime !skipped(name)) hashValue(&fp, Field, @field(placement, name));
    }
    hashValue(&fp, router.RouteResult, routed);
    hashValue(&fp, []const pour.UserZone, zones);
    return fp.final();
}

/// The only `Placement` fields left out of the fingerprint, and why each one is
/// safe to leave out:
///
///   `score`, `breakdown`, `generated` describe the SEARCH, not the board — the
///   objective, its decomposition, and whether the optimizer ran or the poses
///   came back from the layout cache. Two surfaces that resolve one saved board
///   legitimately disagree on all three while its copper is identical, so
///   folding them in would miss on every such pair and memoise nothing.
///
///   `pin_roles` is a per-component pad→class map the ROUTER and the pad-annular
///   rule read; no pour or fill consults it (grep `pin_roles` under
///   `placement/`: `drc.zig` only). It is also a `StringHashMap`, whose bucket
///   order is not a stable fingerprint of its contents.
///
/// Everything else is folded in, including every field added after this was
/// written — which is the point of walking the type rather than a list. A field
/// the walk cannot fingerprint (a hash map, a raw many-pointer) fails the BUILD
/// rather than going quietly unkeyed, so the next such field is a decision
/// somebody makes here on purpose.
fn skipped(comptime name: []const u8) bool {
    const out = [_][]const u8{ "score", "breakdown", "generated", "pin_roles" };
    for (out) |field| {
        if (std.mem.eql(u8, name, field)) return true;
    }
    return false;
}

/// Two Wyhash states fed identical bytes through one small buffer. The buffer
/// is what makes a reflective walk affordable: per-scalar `update` calls cost
/// more in call overhead than in hashing, and a dense board's fingerprint is
/// hundreds of thousands of scalars.
const Fingerprint = struct {
    lo: std.hash.Wyhash = std.hash.Wyhash.init(0x243f6a8885a308d3),
    hi: std.hash.Wyhash = std.hash.Wyhash.init(0x13198a2e03707344),
    buf: [512]u8 = @splat(0),
    len: usize = 0,

    fn add(self: *Fingerprint, bytes: []const u8) void {
        if (bytes.len > self.buf.len - self.len) self.flush();
        if (bytes.len > self.buf.len) {
            self.lo.update(bytes);
            self.hi.update(bytes);
            return;
        }
        @memcpy(self.buf[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    fn flush(self: *Fingerprint) void {
        self.lo.update(self.buf[0..self.len]);
        self.hi.update(self.buf[0..self.len]);
        self.len = 0;
    }

    fn final(self: *Fingerprint) Key {
        self.flush();
        return .{ .lo = self.lo.final(), .hi = self.hi.final() };
    }
};

/// A type whose in-memory bytes ARE its value — no pointer to follow, no
/// padding to read as garbage — so a slice of it folds in with one `add`
/// instead of one per element field. This is what keeps the polygon, label and
/// margin arrays, the overwhelming bulk of the input, cheap to fingerprint.
fn flatBytes(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int => @bitSizeOf(T) == @sizeOf(T) * 8,
        .float => true,
        .array => |a| flatBytes(a.child) and @sizeOf(T) == a.len * @sizeOf(a.child),
        else => false,
    };
}

fn hashValue(fp: *Fingerprint, comptime T: type, value: T) void {
    switch (@typeInfo(T)) {
        .void => {},
        .bool => fp.add(&[_]u8{@intFromBool(value)}),
        .int => |i| {
            // Widened to a whole power-of-two byte width first: the storage of
            // a `u3` (an enum tag, say) has undefined padding bits, and folding
            // those in would make one board fingerprint differently per call.
            const wide: @Int(i.signedness, storageBits(i.bits)) = value;
            fp.add(std.mem.asBytes(&wide));
        },
        .float => fp.add(std.mem.asBytes(&value)[0 .. @bitSizeOf(T) / 8]),
        .@"enum" => |e| hashValue(fp, e.tag_type, @backingInt(value)),
        .optional => |o| if (value) |payload| {
            fp.add(&[_]u8{1});
            hashValue(fp, o.child, payload);
        } else fp.add(&[_]u8{0}),
        .array => |a| hashSlice(fp, a.child, &value),
        .@"struct" => |s| inline for (s.field_names, s.field_types) |name, Field| {
            hashValue(fp, Field, @field(value, name));
        },
        .@"union" => |u| {
            const Tag = u.tag_type orelse
                @compileError("fill_cache: untagged union " ++ @typeName(T) ++ " has no fingerprint");
            hashValue(fp, Tag, std.meta.activeTag(value));
            switch (value) {
                inline else => |payload| hashValue(fp, @TypeOf(payload), payload),
            }
        },
        .pointer => |p| switch (p.size) {
            .slice => {
                hashValue(fp, usize, value.len);
                hashSlice(fp, p.child, value);
            },
            .one => hashValue(fp, p.child, value.*),
            else => @compileError(unkeyable(T)),
        },
        else => @compileError(unkeyable(T)),
    }
}

/// The smallest power-of-two byte width that holds `bits` — the widths for
/// which an integer's storage is exactly its value with no padding byte.
fn storageBits(comptime bits: u16) u16 {
    var whole: u16 = 8;
    while (whole < bits) whole *= 2;
    return whole;
}

/// The build-stopping message for a board field this walk cannot reduce to
/// bytes. Deliberately a hard error: silently skipping it is how the memo would
/// start answering with a stale fill.
fn unkeyable(comptime T: type) []const u8 {
    return "fill_cache: " ++ @typeName(T) ++ " has no fingerprint — give it one, or name its" ++
        " field in `skipped` with the reason it cannot change a fill";
}

fn hashSlice(fp: *Fingerprint, comptime Child: type, items: []const Child) void {
    if (comptime flatBytes(Child)) return fp.add(std.mem.sliceAsBytes(items));
    for (items) |item| hashValue(fp, Child, item);
}

// ── Tests ─────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Two pads on one net, poses given, sharing one footprint. Enough of a board
/// for the fingerprint to have something to disagree about.
fn twoPartBoard(parts: []optimizer.Part) optimizer.Placement {
    return .{
        .parts = parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -1,
        .miny = -1,
        .maxx = 5,
        .maxy = 1,
        .generated = false,
    };
}

const empty_route: router.RouteResult = .{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 0 };

// spec: placement/fill-cache - one board fingerprints identically from two independently built copies and differently after any change to its copper
test "the board fingerprint follows content, not identity" {
    const geometry = @import("geometry.zig");
    const pad_a = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    const pad_b = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts_a = [_]optimizer.Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad_a, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad_a, .fallback = false, .x = 3, .y = 0 },
    };
    // Separate arrays, separate strings, identical board.
    var parts_b = [_]optimizer.Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad_b, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad_b, .fallback = false, .x = 3, .y = 0 },
    };
    const one = key(twoPartBoard(&parts_a), empty_route, &.{});
    try testing.expectEqual(one, key(twoPartBoard(&parts_b), empty_route, &.{}));

    // A micron of movement is a different board.
    parts_b[1].x = 3.000001;
    try testing.expect(!std.meta.eql(one, key(twoPartBoard(&parts_b), empty_route, &.{})));
    parts_b[1].x = 3;
    try testing.expectEqual(one, key(twoPartBoard(&parts_b), empty_route, &.{}));

    // …and so is a track, a via or a drawn zone that was not there before.
    const tracks = [_]router.Track{.{ .x1 = 0, .y1 = 0, .x2 = 3, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 }};
    const routed: router.RouteResult = .{ .tracks = &tracks, .vias = &.{}, .routed = 1, .total = 1 };
    try testing.expect(!std.meta.eql(one, key(twoPartBoard(&parts_a), routed, &.{})));
    const square = [_][2]f64{ .{ 0, 0 }, .{ 3, 0 }, .{ 3, 3 }, .{ 0, 3 } };
    const zones = [_]pour.UserZone{.{ .net = "GND", .layer = 0, .poly = &square }};
    try testing.expect(!std.meta.eql(one, key(twoPartBoard(&parts_a), empty_route, &zones)));
}

// spec: placement/fill-cache - the fingerprint ignores the objective score and whether the optimizer ran, so one saved board shares an entry across the surfaces that resolve it
test "the board fingerprint ignores how the arrangement was arrived at" {
    const geometry = @import("geometry.zig");
    const pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 0, .y = 0 },
    };
    var solved = twoPartBoard(&parts);
    const restored_key = key(solved, empty_route, &.{});
    // The same board, reported by the surface that just re-solved it.
    solved.generated = true;
    solved.score = .{ .hpwl_mm = 12.5, .loop_mm = 3, .loop_caps = 2 };
    solved.breakdown = .{ .hpwl = 12.5, .loop_raw = 3, .loop_weighted = 6, .alignment = 1, .objective = 19.5 };
    try testing.expectEqual(restored_key, key(solved, empty_route, &.{}));
}

/// A one-cell fill of one square contour on `net`, owned by `alloc`.
fn fakeFills(alloc: std.mem.Allocator, net: []const u8) std.mem.Allocator.Error!Fills {
    const square = try alloc.dupe([2]f64, &[_][2]f64{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } });
    const contours = try alloc.dupe([]const [2]f64, &[_][]const [2]f64{square});
    const zones = try alloc.dupe(drc.TopologyZone, &[_]drc.TopologyZone{.{
        .net = try alloc.dupe(u8, net),
        .layer = 0,
        .poly = square,
        .component = 1,
    }});
    const fills = try alloc.dupe(pour.Fill, &[_]pour.Fill{.{
        .frame = .{ .minx = 0, .miny = 0, .pitch = 1, .nx = 1, .ny = 1 },
        .labels = try alloc.dupe(i32, &[_]i32{0}),
        .n_comp = 1,
        .contours = contours,
        .holes = try alloc.dupe([]const []const [2]f64, &[_][]const []const [2]f64{&.{}}),
        .coarsened = false,
    }});
    const layers = try alloc.dupe(pour.LayerSpec, &[_]pour.LayerSpec{.{ .net = .{ .named = try alloc.dupe(u8, net) }, .track_layer = 0 }});
    const plane_fills = try alloc.dupe(pour.NetFills, &[_]pour.NetFills{.{
        .net_name = try alloc.dupe(u8, net),
        .layers = layers,
        .fills = fills,
    }});
    return .{ .zones = zones, .plane_fills = plane_fills };
}

// spec: placement/fill-cache - a retained fill is copied out of the request arena that poured it and stays readable after that arena is gone
test "a retained fill outlives the arena it was poured into" {
    var store: Store = .{ .backing = testing.allocator };
    defer store.deinit();

    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    const board: Key = .{ .lo = 1, .hi = 2 };
    store.put(board, try fakeFills(scratch.allocator(), "GND"));
    // Exactly what the server does to the request arena after it answers.
    scratch.deinit();

    var held = store.acquire(board);
    defer held.release();
    const fills = held.fills();
    try testing.expectEqual(@as(usize, 1), fills.zones.len);
    try testing.expectEqualStrings("GND", fills.zones[0].net);
    try testing.expectEqual(@as(usize, 4), fills.zones[0].poly.len);
    try testing.expectEqualStrings("GND", fills.plane_fills[0].net_name);
    try testing.expectEqualStrings("GND", fills.plane_fills[0].layers[0].net.named);
    try testing.expectEqual(@as(usize, 1), fills.plane_fills[0].fills[0].labels.len);
    try testing.expect(store.acquire(.{ .lo = 9, .hi = 9 }).entry == null);
}

// spec: placement/fill-cache - an evicted board is freed only once its last reader releases it, so a DRC pass reading a fill is never overtaken by a newer board
test "eviction under a live borrow defers the free to the last reader" {
    var store: Store = .{ .backing = testing.allocator, .max_boards = 1 };
    defer store.deinit();

    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const first: Key = .{ .lo = 1, .hi = 1 };
    const second: Key = .{ .lo = 2, .hi = 2 };
    store.put(first, try fakeFills(scratch.allocator(), "GND"));

    // A pass takes the first board, and a second board arrives mid-pass.
    var held = store.acquire(first);
    try testing.expect(held.entry != null);
    store.put(second, try fakeFills(scratch.allocator(), "VCC"));

    // The reader still sees its own board — the store no longer offers it.
    try testing.expectEqualStrings("GND", held.fills().zones[0].net);
    try testing.expect(store.acquire(first).entry == null);
    held.release();

    var newer = store.acquire(second);
    defer newer.release();
    try testing.expectEqualStrings("VCC", newer.fills().zones[0].net);
}

// spec: placement/fill-cache - a board already retained is never duplicated, and the least recently borrowed board is the one eviction takes
test "re-putting a retained board keeps the first copy and refreshes recency" {
    var store: Store = .{ .backing = testing.allocator, .max_boards = 2 };
    defer store.deinit();

    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const first: Key = .{ .lo = 1, .hi = 1 };
    const second: Key = .{ .lo = 2, .hi = 2 };
    const third: Key = .{ .lo = 3, .hi = 3 };
    store.put(first, try fakeFills(scratch.allocator(), "GND"));
    store.put(second, try fakeFills(scratch.allocator(), "VCC"));
    // A racing pass that poured the same board again must not double the memo.
    store.put(first, try fakeFills(scratch.allocator(), "OTHER"));
    try testing.expectEqual(@as(usize, 2), store.entries.items.len);

    // Borrowing `first` makes `second` the least recently used, so the third
    // board evicts `second` rather than the board still being asked for.
    var held = store.acquire(first);
    held.release();
    store.put(third, try fakeFills(scratch.allocator(), "SIG"));
    try testing.expect(store.acquire(second).entry == null);
    var kept = store.acquire(first);
    defer kept.release();
    try testing.expectEqualStrings("GND", kept.fills().zones[0].net);
}

// spec: placement/fill-cache - a board with no planes, pours or zones retains its empty fill so the surfaces after it skip the pour attempt too
test "an empty fill is a retained answer, not a missing one" {
    var store: Store = .{ .backing = testing.allocator };
    defer store.deinit();
    const bare: Key = .{ .lo = 7, .hi = 7 };
    store.put(bare, .{});
    var held = store.acquire(bare);
    defer held.release();
    try testing.expect(held.entry != null);
    try testing.expectEqual(@as(usize, 0), held.fills().zones.len);
    try testing.expectEqual(@as(usize, 0), held.fills().plane_fills.len);
    try testing.expectEqual(@as(usize, 0), held.fills().zone_fills.len);
}

// spec: placement/fill-cache - a board whose fill alone exceeds the whole store's byte ceiling is declined rather than retained, and every later pass simply pours it again
test "a board too large for the whole budget is declined, not retained" {
    var store: Store = .{ .backing = testing.allocator, .max_bytes = 1 };
    defer store.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const board: Key = .{ .lo = 5, .hi = 5 };
    store.put(board, try fakeFills(scratch.allocator(), "GND"));
    try testing.expectEqual(@as(usize, 0), store.entries.items.len);
    try testing.expectEqual(@as(usize, 0), store.bytes);
    try testing.expect(store.acquire(board).entry == null);
}
