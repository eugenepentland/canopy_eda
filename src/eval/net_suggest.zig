//! Did-you-mean suggestions for net names. A mistyped net (`"GNND"`) never
//! joins the net it was meant to reach, so it surfaces as a dead-end/floating
//! net with one connection and no hint about the cause. This module ranks the
//! block's ESTABLISHED nets — the ones with a real connection count or a
//! declared port — against the suspect name and returns the nearest within
//! Levenshtein distance 2, reusing `suggest.editDistance` so component-name
//! and net-name suggestions share one distance metric.
//!
//! Used by both the ERC `floating_net` finding (`erc.zig`) and the
//! evaluator's `Dead-end net` lint (`eval/validate.zig`).

const std = @import("std");
const env_mod = @import("env.zig");
const na = @import("net_analysis.zig");
const suggest = @import("suggest.zig");

/// A net needs at least this many pin connections before it is credible as
/// the thing a one-connection net was *meant* to be. One connection each
/// would make two typos suggest each other.
const min_established_pins: u32 = 2;

/// Base names of the nets a mistyped net was plausibly meant to reach: every
/// base net name in `block` carrying at least `min_established_pins`
/// connections, plus every declared port name and port net (a port connects
/// externally, so it is established however few local pins it has).
///
/// Returns an allocated slice of borrowed name slices; the caller frees the
/// slice, never the names.
pub fn establishedNets(
    allocator: std.mem.Allocator,
    block: *const env_mod.DesignBlock,
) std.mem.Allocator.Error![]const []const u8 {
    var counts: std.StringHashMapUnmanaged(u32) = .empty;
    defer counts.deinit(allocator);
    for (block.nets) |net| {
        const gop = try counts.getOrPut(allocator, na.baseNetName(net.name));
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* +|= @as(u32, @intCast(net.pins.len));
    }

    var names: std.ArrayList([]const u8) = .empty;
    errdefer names.deinit(allocator);
    var it = counts.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* >= min_established_pins) try names.append(allocator, entry.key_ptr.*);
    }
    for (block.ports) |port| {
        try names.append(allocator, port.name);
        try names.append(allocator, port.net);
    }
    return names.toOwnedSlice(allocator);
}

/// The closest name in `candidates` within `suggest.max_edit_distance` of
/// `name`, or null when nothing is close enough. Ties resolve to the smallest
/// distance, first seen. Names longer than `suggest.max_name_len` are skipped
/// (the distance routine's row buffers are sized from that cap).
pub fn didYouMean(name: []const u8, candidates: []const []const u8) ?[]const u8 {
    if (name.len == 0 or name.len > suggest.max_name_len) return null;
    var best: ?[]const u8 = null;
    var best_dist: usize = suggest.max_edit_distance + 1;
    for (candidates) |candidate| {
        if (candidate.len == 0 or candidate.len > suggest.max_name_len) continue;
        if (std.mem.eql(u8, name, candidate)) return null;
        const len_diff = if (name.len > candidate.len) name.len - candidate.len else candidate.len - name.len;
        if (len_diff > suggest.max_edit_distance) continue;
        if (indexDiffers(name, candidate)) continue;
        const d = suggest.editDistance(name, candidate);
        if (d < best_dist) {
            best_dist = d;
            best = candidate;
        }
    }
    return best;
}

/// True when the two names' digit sequences are not identical —
/// `ADF_CH4N` vs `ADF_CH9N`, `ADF_CH1P` vs `ADF_CH10P`, `REFBUF_Y3` vs
/// `REFBUF_Y5`. A bus or channel index is authored deliberately, so a
/// neighbour carrying a different index is a SIBLING lane, never a
/// misspelling of this one. Without this every unconnected lane of a numbered
/// family suggests some other lane — measured on `board-b-analog`, that was
/// nine of fourteen hints, which is how a did-you-mean earns being ignored.
/// The trade is that a typo inside a digit (`V_3V4` for `V_3V3`) gets no
/// suggestion; a differing digit far more often means a different rail.
fn indexDiffers(a: []const u8, b: []const u8) bool {
    var ai: usize = 0;
    var bi: usize = 0;
    while (true) {
        while (ai < a.len and !std.ascii.isDigit(a[ai])) ai += 1;
        while (bi < b.len and !std.ascii.isDigit(b[bi])) bi += 1;
        if (ai == a.len or bi == b.len) return ai != a.len or bi != b.len;
        if (a[ai] != b[bi]) return true;
        ai += 1;
        bi += 1;
    }
}

/// ` — did you mean "GND"?` for a close candidate, else `""`. Callers append
/// the result to their finding text, so a suggestion-free message is exactly
/// the message it always was.
pub fn hint(
    allocator: std.mem.Allocator,
    name: []const u8,
    candidates: []const []const u8,
) []const u8 {
    const candidate = didYouMean(name, candidates) orelse return "";
    return std.fmt.allocPrint(allocator, " — did you mean \"{s}\"?", .{candidate}) catch "";
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: eval/net_suggest - a one-off net name suggests the established net it is closest to
test "didYouMean finds the nearest established net" {
    const candidates = [_][]const u8{ "GND", "V_3V3", "SPI_SCK" };
    try testing.expectEqualStrings("GND", didYouMean("GNND", &candidates).?);
    try testing.expectEqualStrings("V_3V3", didYouMean("V_3v3", &candidates).?);
    try testing.expectEqualStrings("SPI_SCK", didYouMean("SPI_SCLK", &candidates).?);
}

// spec: eval/net_suggest - a net name beyond edit distance two or equal to a candidate yields no suggestion
test "didYouMean rejects distant and identical names" {
    const candidates = [_][]const u8{ "GND", "V_3V3" };
    try testing.expectEqual(@as(?[]const u8, null), didYouMean("MOSI", &candidates));
    try testing.expectEqual(@as(?[]const u8, null), didYouMean("GND", &candidates));
    try testing.expectEqual(@as(?[]const u8, null), didYouMean("", &candidates));
}

// spec: eval/net_suggest - a neighbour carrying a different index is a numbered sibling, not a suggestion
test "didYouMean skips numbered siblings of the same net family" {
    const candidates = [_][]const u8{ "ADF_CH9N", "ADF_CH10P", "REFBUF_Y5", "RX1_RFIN2-" };
    // Lanes of one bus carry different indices — never misspellings of each other.
    try testing.expectEqual(@as(?[]const u8, null), didYouMean("ADF_CH4N", &candidates));
    try testing.expectEqual(@as(?[]const u8, null), didYouMean("ADF_CH1P", &candidates));
    try testing.expectEqual(@as(?[]const u8, null), didYouMean("REFBUF_Y3", &candidates));
    // A suffix that failed to join its base net still reads as the near miss
    // it is — the two names carry the SAME index.
    try testing.expectEqualStrings("RX1_RFIN2-", didYouMean("RX1_RFIN2-_M", &candidates).?);
    // And a digit-free typo is untouched by the sibling rule.
    const rails = [_][]const u8{"GND"};
    try testing.expectEqualStrings("GND", didYouMean("GNND", &rails).?);
}

// spec: eval/net_suggest - established nets are those with two or more connections plus every declared port
test "establishedNets counts connections and includes ports" {
    const allocator = testing.allocator;
    const gnd_pins = [_]env_mod.PinRef{
        .{ .ref_des = "U1", .pin = "1" },
        .{ .ref_des = "C1", .pin = "2" },
    };
    const stub_pins = [_]env_mod.PinRef{.{ .ref_des = "U1", .pin = "9" }};
    const nets = [_]env_mod.Net{
        .{ .name = "GND", .pins = &gnd_pins },
        .{ .name = "GNND", .pins = &stub_pins },
    };
    const ports = [_]env_mod.Port{.{ .name = "VBUS", .net = "VBUS_IN", .direction = "input" }};
    const block = env_mod.DesignBlock{
        .name = "b",
        .instances = &.{},
        .nets = &nets,
        .ports = &ports,
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };

    const names = try establishedNets(allocator, &block);
    defer allocator.free(names);
    try testing.expectEqual(@as(usize, 3), names.len);
    try testing.expectEqualStrings("GND", didYouMean("GNND", names).?);
}

// spec: eval/net_suggest - the did-you-mean hint is an appendable suffix that is empty without a candidate
test "hint renders an appendable suffix only when a candidate is close" {
    const allocator = testing.allocator;
    const candidates = [_][]const u8{"GND"};
    const with = hint(allocator, "GNND", &candidates);
    defer allocator.free(with);
    try testing.expectEqualStrings(" — did you mean \"GND\"?", with);
    try testing.expectEqualStrings("", hint(allocator, "MOSI", &candidates));
}

// spec: eval/net_suggest - an oversized or malformed name is skipped or compared bytewise so the scan never panics and cannot overflow its fixed buffers
test "oversized names are skipped and malformed bytes compare bytewise" {
    var long: [suggest.max_name_len + 8]u8 = undefined;
    @memset(&long, 'A');
    const malformed = "\xff\xfe\x00";
    const candidates = [_][]const u8{ &long, "GND", malformed };

    // An oversized NAME never reaches the fixed-size distance rows.
    try testing.expectEqual(@as(?[]const u8, null), didYouMean(&long, &candidates));
    // An oversized CANDIDATE is skipped; the in-range one still wins.
    try testing.expectEqualStrings("GND", didYouMean("GNND", &candidates).?);
    // Invalid UTF-8 is ranked byte by byte rather than decoded, so a garbage
    // net name is diagnosed like any other instead of tripping a decoder.
    try testing.expectEqualStrings(malformed, didYouMean("\xff\xfe", &candidates).?);
}
