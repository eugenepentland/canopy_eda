//! Sheet naming and intra-sheet clustering for the `.kicad_sch` exporter.
//!
//! Two small, testable decisions live here, both purely about *where things go*
//! — never about what they mean electrically:
//!
//!   * `slugify` / `uniqueName` turn a section or module title into the
//!     deterministic sibling filename its child sheet is written to.
//!   * `cluster` decides which IC each loose passive is drawn beside. A
//!     decoupling cap that declares `(decouples "IC" PIN)` goes to that IC
//!     outright; everything else follows the hub it shares the most *signal*
//!     nets with. Power rails and grounds are excluded from that count because
//!     every cap on the board shares them — they carry no locality at all.

const std = @import("std");
const net_name = @import("../net_name.zig");

/// The most characters a slug contributes to a filename, so a long section
/// title cannot produce an unwieldy sibling path.
pub const max_slug_len: usize = 40;

/// Passive ref-des prefixes draw as compact two-pin bodies and cluster beside a
/// hub rather than heading a cluster of their own — the `hub` flag below is its
/// negation. The leaf after the last `/` is what carries the prefix on a
/// sub-block-qualified ref.
pub fn isPassiveRef(ref: []const u8) bool {
    const leaf = net_name.leaf(ref);
    if (leaf.len == 0) return false;
    return switch (std.ascii.toUpper(leaf[0])) {
        'R', 'C', 'L', 'D', 'F' => true,
        else => false,
    };
}

/// One placeable competing for a home on the sheet.
pub const Member = struct {
    /// Hubs are cluster heads; everything else is drawn beside one.
    hub: bool,
    /// This placeable's ref-des, so a bound cap can be matched to its IC.
    ref: []const u8,
    /// `(decouples "IC" PIN)` target, already qualified with the sub-block
    /// path. "" when the placeable declares no binding.
    bound_ref: []const u8,
    /// Sort key inside a cluster — the bound pad, so a decoupling bank reads in
    /// pad order. "" sorts first.
    order: []const u8,
    /// Locality-bearing nets this placeable touches (rails already removed).
    nets: []const []const u8,
};

/// Draw order for one sheet: `order` lists member indices, `cluster` gives the
/// cluster each entry belongs to. Entries of one cluster are contiguous, so the
/// caller can pack each run into its own block.
pub const Placement = struct {
    order: []const u32,
    cluster: []const u32,
};

/// Assign every non-hub member to a hub and return the resulting draw order.
/// Members with no hub affinity at all land in a trailing bucket rather than
/// being scattered through the sheet.
pub fn cluster(arena: std.mem.Allocator, members: []const Member) std.mem.Allocator.Error!Placement {
    var heads: std.ArrayList(u32) = .empty;
    var head_of_ref: std.StringHashMapUnmanaged(u32) = .empty;
    defer head_of_ref.deinit(arena);
    for (members, 0..) |m, i| {
        if (!m.hub) continue;
        const gop = try head_of_ref.getOrPut(arena, m.ref);
        if (!gop.found_existing) gop.value_ptr.* = @intCast(heads.items.len);
        try heads.append(arena, @intCast(i));
    }

    const buckets = try arena.alloc(std.ArrayList(u32), heads.items.len + 1);
    for (buckets) |*b| b.* = .empty;
    for (members, 0..) |m, i| {
        if (m.hub) continue;
        const home = pick(m, members, heads.items, &head_of_ref) orelse heads.items.len;
        try buckets[home].append(arena, @intCast(i));
    }
    for (buckets) |*b| std.mem.sort(u32, b.items, members, lessMember);

    var order: std.ArrayList(u32) = .empty;
    var of: std.ArrayList(u32) = .empty;
    for (buckets, 0..) |b, c| {
        if (c < heads.items.len) {
            try order.append(arena, heads.items[c]);
            try of.append(arena, @intCast(c));
        }
        for (b.items) |i| {
            try order.append(arena, i);
            try of.append(arena, @intCast(c));
        }
    }
    return .{ .order = order.items, .cluster = of.items };
}

/// The cluster one loose member belongs to: its declared decoupling target when
/// it has one, else the hub it shares the most nets with. Null when it shares
/// nothing with any hub.
fn pick(
    m: Member,
    members: []const Member,
    heads: []const u32,
    head_of_ref: *const std.StringHashMapUnmanaged(u32),
) ?usize {
    if (m.bound_ref.len > 0) {
        if (head_of_ref.get(m.bound_ref)) |h| return h;
    }
    var best: usize = 0;
    var best_score: usize = 0;
    for (heads, 0..) |hi, c| {
        const score = shared(m.nets, members[hi].nets);
        if (score > best_score) {
            best_score = score;
            best = c;
        }
    }
    return if (best_score == 0) null else best;
}

/// How many net names two placeables have in common. Both lists are short (a
/// passive has two pins, a hub's list is de-duplicated), so a linear scan beats
/// building a map per comparison.
fn shared(a: []const []const u8, b: []const []const u8) usize {
    var n: usize = 0;
    for (a) |x| {
        for (b) |y| {
            if (std.mem.eql(u8, x, y)) {
                n += 1;
                break;
            }
        }
    }
    return n;
}

fn lessMember(members: []const Member, x: u32, y: u32) bool {
    const ord = std.mem.order(u8, members[x].order, members[y].order);
    if (ord != .eq) return ord == .lt;
    return x < y;
}

/// Filename-safe, lowercase form of a title: runs of anything but letters and
/// digits collapse to a single `-`, and the result never starts or ends with
/// one. Falls back to `fallback` when nothing survives (a title of punctuation).
pub fn slugify(
    arena: std.mem.Allocator,
    name: []const u8,
    fallback: []const u8,
) std.mem.Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (name) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            try out.append(arena, std.ascii.toLower(c));
        } else if (out.items.len > 0 and out.items[out.items.len - 1] != '-') {
            try out.append(arena, '-');
        }
        if (out.items.len >= max_slug_len) break;
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == '-') _ = out.pop();
    if (out.items.len == 0) return fallback;
    return out.items;
}

/// `base`, or `base-2`, `base-3`, … until it is not already in `seen`. Two
/// sections whose titles slugify alike must not share a filename — the second
/// would silently overwrite the first.
pub fn uniqueName(
    arena: std.mem.Allocator,
    base: []const u8,
    seen: *std.StringHashMapUnmanaged(void),
) std.mem.Allocator.Error![]const u8 {
    var candidate = base;
    var n: u32 = 2;
    while (seen.contains(candidate)) : (n += 1) {
        candidate = try std.fmt.allocPrint(arena, "{s}-{d}", .{ base, n });
    }
    try seen.put(arena, candidate, {});
    return candidate;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: export_kicad_sch - A sheet filename slug is lowercase, hyphen-separated, bounded, and never collides with a sibling
test "kicad-sch: slugify normalises a title and uniqueName disambiguates collisions" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try testing.expectEqualStrings("usb-2-0-hs", try slugify(a, "USB 2.0 HS", "x"));
    try testing.expectEqualStrings("3v3-buck", try slugify(a, "  3V3 Buck!  ", "x"));
    try testing.expectEqualStrings("sheet", try slugify(a, "***", "sheet"));
    const long_title: [200]u8 = @splat('a');
    try testing.expect((try slugify(a, &long_title, "x")).len <= max_slug_len);

    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(a);
    try testing.expectEqualStrings("core", try uniqueName(a, "core", &seen));
    try testing.expectEqualStrings("core-2", try uniqueName(a, "core", &seen));
    try testing.expectEqualStrings("core-3", try uniqueName(a, "core", &seen));
}

// spec: export_kicad_sch - A passive ref-des is recognised by its leaf prefix even under a sub-block path
test "kicad-sch: isPassiveRef reads the leaf of a hierarchical ref" {
    try testing.expect(isPassiveRef("C1"));
    try testing.expect(isPassiveRef("usb/C12"));
    try testing.expect(isPassiveRef("R_OPT"));
    try testing.expect(!isPassiveRef("U1"));
    try testing.expect(!isPassiveRef("lna1/U17"));
    try testing.expect(!isPassiveRef(""));
}

const vdd = [_][]const u8{ "VDD", "SDA" };
const vdd_only = [_][]const u8{"VDD"};
const other = [_][]const u8{"VBUS"};
const nothing = [_][]const u8{"PRIVATE"};

// spec: export_kicad_sch - A decoupling cap is drawn beside the IC it declares, and other passives beside the hub they share the most nets with
test "kicad-sch: cluster binds a declared decap to its IC and groups the rest by net affinity" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const members = [_]Member{
        .{ .hub = true, .ref = "U1", .bound_ref = "", .order = "", .nets = &vdd },
        .{ .hub = true, .ref = "U2", .bound_ref = "", .order = "", .nets = &other },
        // Shares VDD with U1 only.
        .{ .hub = false, .ref = "C1", .bound_ref = "", .order = "", .nets = &vdd_only },
        // Shares VDD with U1 too, but is declared against U2 — the declaration wins.
        .{ .hub = false, .ref = "C2", .bound_ref = "U2", .order = "7", .nets = &vdd_only },
        // Shares nothing with any hub: the trailing bucket.
        .{ .hub = false, .ref = "R9", .bound_ref = "", .order = "", .nets = &nothing },
    };
    const p = try cluster(a, &members);
    try testing.expectEqualSlices(u32, &.{ 0, 2, 1, 3, 4 }, p.order);
    try testing.expectEqualSlices(u32, &.{ 0, 0, 1, 1, 2 }, p.cluster);
}

// spec: export_kicad_sch - A sheet with no hub at all still draws every part, in a single trailing cluster
test "kicad-sch: cluster keeps hubless members in one bucket in declaration order" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const members = [_]Member{
        .{ .hub = false, .ref = "R1", .bound_ref = "", .order = "", .nets = &vdd_only },
        .{ .hub = false, .ref = "R2", .bound_ref = "", .order = "", .nets = &vdd_only },
    };
    const p = try cluster(a, &members);
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, p.order);
    try testing.expectEqualSlices(u32, &.{ 0, 0 }, p.cluster);
    try testing.expectEqual(@as(usize, 0), (try cluster(a, &.{})).order.len);
}
