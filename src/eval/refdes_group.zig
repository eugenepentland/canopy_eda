//! Value/footprint-grouped ref-des allocation — the persistent core behind
//! `(grouped-refdes)`.
//!
//! The default ref-des scheme is a per-prefix counter walked in source order
//! (`ids.nextRefDes`): insert or delete a part mid-file and everything
//! downstream renumbers. The 8-char `(id …)` hex keeps the *PCB* identity
//! stable through that drift, but the human-facing ref-des still churns the
//! BOM, git diffs, and traceability sign-offs.
//!
//! This module pins the human-facing number too. A **class** is the tuple
//! `(prefix, value, footprint)` — e.g. every 100 nF cap-0402 is one class — and
//! gets a stable 1-based per-prefix **index**. Each part is pinned to a 0-based
//! **member offset** inside its class, keyed by the part's stable `id`. So:
//!   • adding a part of an existing class appends the next free member offset,
//!     touching nothing else;
//!   • deleting a class never renumbers another (class indices are pinned);
//!   • only a *value/footprint* edit moves a part between classes — the one
//!     case its ref-des intentionally changes (the `id` keeps the footprint
//!     anchored through it).
//!
//! The (class index, member offset) pair is rendered to a ref-des string by one
//! of two **formats**, chosen on the `(grouped-refdes …)` form (the DSL default
//! is `.two_level`):
//!   • `.two_level` — `C<class>_<member>` (`C2_5`): class 2, member 5. The most
//!     literal "these are all the same part" reading.
//!   • `.block_range` — class N owns a contiguous block of numbers
//!     (`C100…C199`, `C200…`, with `block_size = 100`), spilling into a fresh
//!     block past `block_size` members. Stays canonical `[A-Z]+[0-9]+` (`C205`),
//!     so KiCad/the netlist exporter/assembly tooling accept it unchanged.
//!
//! Because storage is logical (class+offset, not the rendered string), switching
//! formats is a pure re-render that preserves every part's class/member slot.
//! The class table + member map persist to a `<design>.refdes.json` sidecar.
//! This module is pure (std-only): the Evaluator-coupled tree walk + rename
//! propagation lives in `ids.zig`.

const std = @import("std");

/// Conventional block width for `.block_range`: class N occupies `[N*bs, N*bs+bs)`.
pub const DEFAULT_BLOCK_SIZE: u32 = 100;

/// How a (class index, member offset) pair renders to a ref-des string.
pub const Format = enum { block_range, two_level };

/// A ref-des split into its alphabetic prefix and numeric tail, e.g.
/// "C205" → {"C", 205}. Null for non-standard strings (no prefix, no digits, or
/// any non-digit in the tail — `parseInt` would otherwise treat `_` as a
/// separator, so "C2_5" must be rejected here, not parsed as C25).
pub const ParsedRef = struct { prefix: []const u8, number: u32 };

/// Split a ref-des into prefix + number. Slices into `ref` (no allocation).
pub fn parseRef(ref: []const u8) ?ParsedRef {
    var i: usize = 0;
    while (i < ref.len and std.ascii.isAlphabetic(ref[i])) : (i += 1) {}
    if (i == 0 or i == ref.len) return null;
    for (ref[i..]) |c| {
        if (!std.ascii.isDigit(c)) return null;
    }
    const number = std.fmt.parseInt(u32, ref[i..], 10) catch return null;
    return .{ .prefix = ref[0..i], .number = number };
}

/// One value/footprint class: its stable per-prefix `index` (1-based) and the
/// block range(s) it owns for `.block_range` rendering. `bases` lists each
/// block's first number (a 2nd is appended only when a class exceeds
/// `block_size` members). `count` is the member high-water, reconstructed on
/// load, never serialized.
pub const ClassDef = struct {
    prefix: []const u8,
    value: []const u8,
    footprint: []const u8,
    index: u32,
    bases: []u32,
    count: u32 = 0,
};

/// A part's pinned slot: its class `index` (under `prefix`) and 0-based member
/// `offset` within that class. The rendered ref-des is derived from this.
pub const Member = struct {
    prefix: []const u8,
    class: u32,
    offset: u32,
};

/// The persistent grouped-ref-des state for one design. Owns an arena that
/// backs every stored string + slice; `deinit` frees it all at once.
pub const Registry = struct {
    arena: std.heap.ArenaAllocator,
    format: Format,
    block_size: u32,
    classes: std.ArrayListUnmanaged(ClassDef) = .empty,
    /// stable part id → pinned class/offset slot.
    members: std.StringHashMapUnmanaged(Member) = .empty,
    /// prefix → next class index (1-based).
    next_index: std.StringHashMapUnmanaged(u32) = .empty,
    /// prefix → next free block base (high-water), so a new class never
    /// collides with an existing one regardless of allocation order.
    next_base: std.StringHashMapUnmanaged(u32) = .empty,
    /// Set whenever a class/member is minted, reclassed, or the format/block
    /// changed, so the caller only rewrites the sidecar when it actually moved.
    dirty: bool = false,

    pub fn initEmpty(child: std.mem.Allocator, format: Format, block_size: u32) Registry {
        return .{
            .arena = std.heap.ArenaAllocator.init(child),
            .format = format,
            .block_size = if (block_size == 0) DEFAULT_BLOCK_SIZE else block_size,
        };
    }

    pub fn deinit(self: *Registry) void {
        self.arena.deinit();
    }

    /// Resolve `id` (the part's stable identity) to its grouped ref-des,
    /// allocating a fresh member (and class, if new) when the part is unseen or
    /// its value/footprint changed. The returned string is owned by `out` (use
    /// it as `inst.ref_des`). Marks `dirty` when anything is minted.
    pub fn resolve(
        self: *Registry,
        out: std.mem.Allocator,
        id: []const u8,
        prefix: []const u8,
        value: []const u8,
        footprint: []const u8,
    ) std.mem.Allocator.Error![]const u8 {
        // 1. Pinned, and still in a matching class → render its existing slot.
        if (self.members.get(id)) |m| {
            if (std.mem.eql(u8, m.prefix, prefix)) {
                if (self.findByIndex(prefix, m.class)) |ci| {
                    const cd = self.classes.items[ci];
                    if (std.mem.eql(u8, cd.value, value) and std.mem.eql(u8, cd.footprint, footprint)) {
                        return self.refFor(out, ci, m.offset);
                    }
                }
            }
            // Else value/footprint (or prefix) changed → reclass below.
        }

        // 2. Find or mint the class, take the next member offset.
        const ci = self.classSlot(prefix, value, footprint) orelse try self.createClass(prefix, value, footprint);
        const offset = try self.allocOffset(ci);

        // 3. Pin the slot for the sidecar.
        const arena = self.arena.allocator();
        const gop = try self.members.getOrPut(arena, id);
        if (!gop.found_existing) gop.key_ptr.* = try arena.dupe(u8, id);
        gop.value_ptr.* = .{ .prefix = self.classes.items[ci].prefix, .class = self.classes.items[ci].index, .offset = offset };
        self.dirty = true;
        return self.refFor(out, ci, offset);
    }

    /// Render class `ci`'s member `offset` to a ref-des string owned by `out`.
    fn refFor(self: *Registry, out: std.mem.Allocator, ci: usize, offset: u32) std.mem.Allocator.Error![]const u8 {
        const cd = self.classes.items[ci];
        return switch (self.format) {
            .two_level => std.fmt.allocPrint(out, "{s}{d}_{d}", .{ cd.prefix, cd.index, offset + 1 }),
            .block_range => blk: {
                const bs = self.block_size;
                const number = cd.bases[offset / bs] + (offset % bs);
                break :blk std.fmt.allocPrint(out, "{s}{d}", .{ cd.prefix, number });
            },
        };
    }

    fn findByIndex(self: *Registry, prefix: []const u8, index: u32) ?usize {
        for (self.classes.items, 0..) |cd, i| {
            if (cd.index == index and std.mem.eql(u8, cd.prefix, prefix)) return i;
        }
        return null;
    }

    fn classSlot(self: *Registry, prefix: []const u8, value: []const u8, footprint: []const u8) ?usize {
        for (self.classes.items, 0..) |cd, i| {
            if (std.mem.eql(u8, cd.prefix, prefix) and
                std.mem.eql(u8, cd.value, value) and
                std.mem.eql(u8, cd.footprint, footprint)) return i;
        }
        return null;
    }

    fn nextIndex(self: *Registry, prefix: []const u8) std.mem.Allocator.Error!u32 {
        const arena = self.arena.allocator();
        const gop = try self.next_index.getOrPut(arena, prefix);
        if (!gop.found_existing) {
            gop.key_ptr.* = try arena.dupe(u8, prefix);
            gop.value_ptr.* = 1;
        }
        const idx = gop.value_ptr.*;
        gop.value_ptr.* = idx + 1;
        return idx;
    }

    /// Reserve the next block base for `prefix` (high-water; first base is one
    /// block in, so block-range refs start at `C100` not `C0`).
    fn takeBase(self: *Registry, prefix: []const u8) std.mem.Allocator.Error!u32 {
        const arena = self.arena.allocator();
        const gop = try self.next_base.getOrPut(arena, prefix);
        if (!gop.found_existing) {
            gop.key_ptr.* = try arena.dupe(u8, prefix);
            gop.value_ptr.* = self.block_size;
        }
        const base = gop.value_ptr.*;
        gop.value_ptr.* = base + self.block_size;
        return base;
    }

    fn createClass(self: *Registry, prefix: []const u8, value: []const u8, footprint: []const u8) std.mem.Allocator.Error!usize {
        const arena = self.arena.allocator();
        const index = try self.nextIndex(prefix);
        // Always reserve a block base (even in two-level) so the bases array stays
        // valid and switching to block_range later is a pure, safe re-render.
        const bases = try arena.alloc(u32, 1);
        bases[0] = try self.takeBase(prefix);
        try self.classes.append(arena, .{
            .prefix = try arena.dupe(u8, prefix),
            .value = try arena.dupe(u8, value),
            .footprint = try arena.dupe(u8, footprint),
            .index = index,
            .bases = bases,
        });
        self.dirty = true;
        return self.classes.items.len - 1;
    }

    /// Allocate the next member offset in class `ci`, growing the block list
    /// (collision-free, via the per-prefix high-water) whenever the offset
    /// crosses a `block_size` boundary — so `bases` always covers `count`
    /// regardless of format.
    fn allocOffset(self: *Registry, ci: usize) std.mem.Allocator.Error!u32 {
        const arena = self.arena.allocator();
        const bs = self.block_size;
        var cd = &self.classes.items[ci];
        const off = cd.count;
        const block_index = off / bs;
        if (block_index >= cd.bases.len) {
            const nb = try self.takeBase(cd.prefix);
            var grown = try arena.alloc(u32, cd.bases.len + 1);
            @memcpy(grown[0..cd.bases.len], cd.bases);
            grown[cd.bases.len] = nb;
            cd.bases = grown;
            self.dirty = true;
        }
        cd.count = off + 1;
        return off;
    }

    /// Serialize the class table + member map to the sidecar JSON, deterministically
    /// ordered (classes by prefix then index, members by id) for clean diffs.
    pub fn toJson(self: *Registry, a: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        const class_order = try a.alloc(usize, self.classes.items.len);
        defer a.free(class_order);
        for (class_order, 0..) |*v, i| v.* = i;
        std.mem.sortUnstable(usize, class_order, self, classLess);

        const member_keys = try a.alloc([]const u8, self.members.count());
        defer a.free(member_keys);
        {
            var it = self.members.keyIterator();
            var i: usize = 0;
            while (it.next()) |k| : (i += 1) member_keys[i] = k.*;
            std.mem.sortUnstable([]const u8, member_keys, {}, strLess);
        }

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(a);
        const w = buf.writer(a);
        try w.print("{{\"format\":\"{s}\",\"block_size\":{d},\"classes\":[", .{ formatName(self.format), self.block_size });
        for (class_order, 0..) |ci, n| {
            const cd = self.classes.items[ci];
            if (n > 0) try w.writeAll(",");
            try w.writeAll("{\"prefix\":");
            try writeJsonStr(w, cd.prefix);
            try w.print(",\"index\":{d},\"value\":", .{cd.index});
            try writeJsonStr(w, cd.value);
            try w.writeAll(",\"footprint\":");
            try writeJsonStr(w, cd.footprint);
            try w.writeAll(",\"bases\":[");
            for (cd.bases, 0..) |b, bi| {
                if (bi > 0) try w.writeAll(",");
                try w.print("{d}", .{b});
            }
            try w.writeAll("]}");
        }
        try w.writeAll("],\"members\":[");
        for (member_keys, 0..) |id, n| {
            const m = self.members.get(id).?;
            if (n > 0) try w.writeAll(",");
            try w.writeAll("{\"id\":");
            try writeJsonStr(w, id);
            try w.writeAll(",\"prefix\":");
            try writeJsonStr(w, m.prefix);
            try w.print(",\"class\":{d},\"offset\":{d}}}", .{ m.class, m.offset });
        }
        try w.writeAll("]}");
        return buf.toOwnedSlice(a);
    }

    fn classLess(self: *Registry, a: usize, b: usize) bool {
        const ca = self.classes.items[a];
        const cb = self.classes.items[b];
        const po = std.mem.order(u8, ca.prefix, cb.prefix);
        if (po != .eq) return po == .lt;
        return ca.index < cb.index;
    }
};

fn strLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn formatName(f: Format) []const u8 {
    return switch (f) {
        .block_range => "block-range",
        .two_level => "two-level",
    };
}

fn parseFormatName(s: []const u8) ?Format {
    if (std.mem.eql(u8, s, "block-range")) return .block_range;
    if (std.mem.eql(u8, s, "two-level")) return .two_level;
    return null;
}

fn writeJsonStr(w: anytype, s: []const u8) std.mem.Allocator.Error!void {
    try w.writeAll("\"");
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => try w.writeByte(c),
        }
    }
    try w.writeAll("\"");
}

/// Parse a `<design>.refdes.json` sidecar into a working Registry. `format` and
/// `block_size` are AUTHORITATIVE (from the `(grouped-refdes …)` form): if the
/// sidecar was written under a different format/block, the registry is marked
/// dirty so the build re-stamps + rewrites it (storage is logical, so the
/// class/member slots survive a format switch — only the rendered strings move).
/// Any malformed or absent input yields an empty registry — a one-time re-stamp.
pub fn load(child: std.mem.Allocator, json_bytes: []const u8, format: Format, block_size: u32) Registry {
    var reg = Registry.initEmpty(child, format, block_size);
    const parsed = std.json.parseFromSlice(std.json.Value, child, json_bytes, .{}) catch return reg;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return reg;

    if (root.object.get("format")) |fv| {
        if (fv == .string) {
            if (parseFormatName(fv.string)) |stored| {
                if (stored != format) reg.dirty = true; // format switch ⇒ re-stamp
            }
        }
    }
    if (root.object.get("block_size")) |bs| {
        if (bs == .integer and bs.integer > 0 and block_size == 0) {
            reg.block_size = @intCast(bs.integer);
        } else if (bs == .integer and bs.integer > 0 and @as(u32, @intCast(bs.integer)) != reg.block_size) {
            reg.dirty = true; // block-size change ⇒ re-stamp
        }
    }

    const arena = reg.arena.allocator();
    if (root.object.get("classes")) |classes_v| {
        if (classes_v == .array) {
            for (classes_v.array.items) |cv| {
                if (cv != .object) continue;
                const prefix = jsonStr(cv.object.get("prefix")) orelse continue;
                const value = jsonStr(cv.object.get("value")) orelse "";
                const footprint = jsonStr(cv.object.get("footprint")) orelse "";
                const index_v = cv.object.get("index") orelse continue;
                if (index_v != .integer or index_v.integer <= 0) continue;
                const bases_v = cv.object.get("bases") orelse continue;
                if (bases_v != .array or bases_v.array.items.len == 0) continue;
                var bases = arena.alloc(u32, bases_v.array.items.len) catch continue;
                var ok = true;
                for (bases_v.array.items, 0..) |bn, i| {
                    if (bn != .integer or bn.integer < 0) {
                        ok = false;
                        break;
                    }
                    bases[i] = @intCast(bn.integer);
                }
                if (!ok) continue;
                reg.classes.append(arena, .{
                    .prefix = arena.dupe(u8, prefix) catch continue,
                    .value = arena.dupe(u8, value) catch continue,
                    .footprint = arena.dupe(u8, footprint) catch continue,
                    .index = @intCast(index_v.integer),
                    .bases = bases,
                }) catch continue;
            }
        }
    }

    if (root.object.get("members")) |members_v| {
        if (members_v == .array) {
            for (members_v.array.items) |mv| {
                if (mv != .object) continue;
                const id = jsonStr(mv.object.get("id")) orelse continue;
                const prefix = jsonStr(mv.object.get("prefix")) orelse continue;
                const class_v = mv.object.get("class") orelse continue;
                const offset_v = mv.object.get("offset") orelse continue;
                if (class_v != .integer or class_v.integer <= 0) continue;
                if (offset_v != .integer or offset_v.integer < 0) continue;
                reg.members.put(arena, arena.dupe(u8, id) catch continue, .{
                    .prefix = arena.dupe(u8, prefix) catch continue,
                    .class = @intCast(class_v.integer),
                    .offset = @intCast(offset_v.integer),
                }) catch continue;
            }
        }
    }

    rebuildDerived(&reg);
    return reg;
}

/// Recompute per-prefix next index/base and per-class member high-water after a
/// load, so freshly allocated classes/members extend the persisted state.
fn rebuildDerived(self: *Registry) void {
    const bs = self.block_size;
    const arena = self.arena.allocator();

    for (self.classes.items) |cd| {
        // next class index per prefix = max(index)+1
        const gi = self.next_index.getOrPut(arena, cd.prefix) catch continue;
        if (!gi.found_existing) {
            gi.key_ptr.* = arena.dupe(u8, cd.prefix) catch cd.prefix;
            gi.value_ptr.* = 1;
        }
        if (cd.index + 1 > gi.value_ptr.*) gi.value_ptr.* = cd.index + 1;

        // next block base per prefix = max(base)+bs
        var maxb: u32 = 0;
        for (cd.bases) |b| {
            if (b > maxb) maxb = b;
        }
        const gb = self.next_base.getOrPut(arena, cd.prefix) catch continue;
        if (!gb.found_existing) {
            gb.key_ptr.* = arena.dupe(u8, cd.prefix) catch cd.prefix;
            gb.value_ptr.* = bs;
        }
        if (maxb + bs > gb.value_ptr.*) gb.value_ptr.* = maxb + bs;
    }

    // Per-class member high-water = max(offset)+1 over its pinned members.
    var it = self.members.iterator();
    while (it.next()) |e| {
        const m = e.value_ptr.*;
        if (self.findByIndex(m.prefix, m.class)) |ci| {
            var cd = &self.classes.items[ci];
            if (m.offset + 1 > cd.count) cd.count = m.offset + 1;
        }
    }
}

fn jsonStr(v: ?std.json.Value) ?[]const u8 {
    const val = v orelse return null;
    return if (val == .string) val.string else null;
}

// ── Tests ──────────────────────────────────────────────────────────────

// spec: eval/refdes_group - parseRef splits a ref-des into prefix and number
test "parseRef splits prefix and number" {
    try std.testing.expectEqualStrings("C", parseRef("C205").?.prefix);
    try std.testing.expectEqual(@as(u32, 205), parseRef("C205").?.number);
    try std.testing.expectEqualStrings("SW", parseRef("SW12").?.prefix);
    try std.testing.expectEqual(@as(u32, 12), parseRef("SW12").?.number);
    try std.testing.expect(parseRef("100") == null);
    try std.testing.expect(parseRef("C") == null);
    try std.testing.expect(parseRef("C2_5") == null);
}

// spec: eval/refdes_group - a fresh registry assigns block-range refs grouped by class
test "fresh registry groups by value/footprint into blocks" {
    const a = std.testing.allocator;
    var reg = Registry.initEmpty(a, .block_range, DEFAULT_BLOCK_SIZE);
    defer reg.deinit();

    const r1 = try reg.resolve(a, "id1", "C", "100nF", "cap-0402");
    defer a.free(r1);
    const r2 = try reg.resolve(a, "id2", "C", "100nF", "cap-0402");
    defer a.free(r2);
    const r3 = try reg.resolve(a, "id3", "C", "1uF", "cap-0603");
    defer a.free(r3);

    try std.testing.expectEqualStrings("C100", r1);
    try std.testing.expectEqualStrings("C101", r2);
    try std.testing.expectEqualStrings("C200", r3); // new class → next block
    try std.testing.expect(reg.dirty);
}

// spec: eval/refdes_group - two-level format renders class_member refs
test "two-level format renders class_member refs" {
    const a = std.testing.allocator;
    var reg = Registry.initEmpty(a, .two_level, DEFAULT_BLOCK_SIZE);
    defer reg.deinit();

    const r1 = try reg.resolve(a, "id1", "C", "100nF", "cap-0402");
    defer a.free(r1);
    const r2 = try reg.resolve(a, "id2", "C", "100nF", "cap-0402");
    defer a.free(r2);
    const r3 = try reg.resolve(a, "id3", "C", "1uF", "cap-0603");
    defer a.free(r3);

    try std.testing.expectEqualStrings("C1_1", r1); // class 1, member 1
    try std.testing.expectEqualStrings("C1_2", r2); // same class, member 2
    try std.testing.expectEqualStrings("C2_1", r3); // new class
}

// spec: eval/refdes_group - resolve pins a part's ref by its id across builds
test "resolve is stable across reload and appends new members" {
    const a = std.testing.allocator;
    var reg = Registry.initEmpty(a, .block_range, DEFAULT_BLOCK_SIZE);
    const r1 = try reg.resolve(a, "id1", "C", "100nF", "cap-0402");
    a.free(r1);
    const r2 = try reg.resolve(a, "id2", "C", "1uF", "cap-0603");
    a.free(r2);
    const json = try reg.toJson(a);
    defer a.free(json);
    reg.deinit();

    var reg2 = load(a, json, .block_range, DEFAULT_BLOCK_SIZE);
    defer reg2.deinit();
    const k1 = try reg2.resolve(a, "id1", "C", "100nF", "cap-0402");
    defer a.free(k1);
    try std.testing.expectEqualStrings("C100", k1);
    try std.testing.expect(!reg2.dirty); // pure read-back mints nothing
    const k3 = try reg2.resolve(a, "id3", "C", "100nF", "cap-0402");
    defer a.free(k3);
    try std.testing.expectEqualStrings("C101", k3);
    try std.testing.expect(reg2.dirty);
}

// spec: eval/refdes_group - switching the format re-renders the same slots
test "format switch re-renders pinned slots" {
    const a = std.testing.allocator;
    var reg = Registry.initEmpty(a, .block_range, DEFAULT_BLOCK_SIZE);
    const r1 = try reg.resolve(a, "id1", "C", "100nF", "cap-0402");
    a.free(r1);
    const r2 = try reg.resolve(a, "id2", "C", "1uF", "cap-0603");
    a.free(r2);
    const json = try reg.toJson(a);
    defer a.free(json);
    reg.deinit();

    // Reload as two-level: same class/member slots, different rendering, dirty.
    var reg2 = load(a, json, .two_level, DEFAULT_BLOCK_SIZE);
    defer reg2.deinit();
    try std.testing.expect(reg2.dirty); // format changed ⇒ re-stamp
    const k1 = try reg2.resolve(a, "id1", "C", "100nF", "cap-0402");
    defer a.free(k1);
    const k2 = try reg2.resolve(a, "id2", "C", "1uF", "cap-0603");
    defer a.free(k2);
    try std.testing.expectEqualStrings("C1_1", k1); // was C100
    try std.testing.expectEqualStrings("C2_1", k2); // was C200
}

// spec: eval/refdes_group - changing a part's value re-classes it to a new block
test "value change reclasses the part" {
    const a = std.testing.allocator;
    var reg = Registry.initEmpty(a, .block_range, DEFAULT_BLOCK_SIZE);
    defer reg.deinit();
    const r1 = try reg.resolve(a, "id1", "C", "100nF", "cap-0402");
    a.free(r1);
    const r1b = try reg.resolve(a, "id1", "C", "10uF", "cap-0805");
    defer a.free(r1b);
    try std.testing.expectEqualStrings("C200", r1b);
}

// spec: eval/refdes_group - a class exceeding block_size spills into a fresh block
test "class spills into a new block past block_size" {
    const a = std.testing.allocator;
    var reg = Registry.initEmpty(a, .block_range, 4); // tiny block to force a spill
    defer reg.deinit();
    const r0 = try reg.resolve(a, "id0", "C", "100nF", "cap-0402");
    defer a.free(r0);
    const r1 = try reg.resolve(a, "id1", "C", "100nF", "cap-0402");
    defer a.free(r1);
    const r2 = try reg.resolve(a, "id2", "C", "100nF", "cap-0402");
    defer a.free(r2);
    const r3 = try reg.resolve(a, "id3", "C", "100nF", "cap-0402");
    defer a.free(r3);
    const r4 = try reg.resolve(a, "id4", "C", "100nF", "cap-0402");
    defer a.free(r4);
    // offsets 0..3 → C4..C7 (block base 4); offset 4 spills to a fresh block → C8.
    try std.testing.expectEqualStrings("C4", r0);
    try std.testing.expectEqualStrings("C7", r3);
    try std.testing.expectEqualStrings("C8", r4);
}

// spec: eval/refdes_group - toJson round-trips through load
test "toJson round-trips through load" {
    const a = std.testing.allocator;
    var reg = Registry.initEmpty(a, .block_range, DEFAULT_BLOCK_SIZE);
    const r1 = try reg.resolve(a, "aabbccdd", "R", "10k", "res-0402");
    a.free(r1);
    const json = try reg.toJson(a);
    defer a.free(json);
    reg.deinit();

    var reg2 = load(a, json, .block_range, DEFAULT_BLOCK_SIZE);
    defer reg2.deinit();
    try std.testing.expectEqual(@as(usize, 1), reg2.classes.items.len);
    const k = try reg2.resolve(a, "aabbccdd", "R", "10k", "res-0402");
    defer a.free(k);
    try std.testing.expectEqualStrings("R100", k);
    const json2 = try reg2.toJson(a);
    defer a.free(json2);
    try std.testing.expectEqualStrings(json, json2);
}
