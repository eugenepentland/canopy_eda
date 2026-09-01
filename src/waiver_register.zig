//! The DRC waiver register a system release carries (`docs/drc-waivers.md`)
//! is only evidence while its counts are the counts of the release run. This
//! module reads the register's per-board category tables and compares them
//! with the warning-severity DRC kinds the fabrication gate actually
//! reported, so a register written against last week's copper cannot vouch
//! for today's. Parsing is deliberately narrow: a table counts only under a
//! heading that names the board in backticks, and only when its second
//! column is literally `Count` — the shape the package template prescribes —
//! so the delta tables an engineer appends during review are never mistaken
//! for the register itself.

const std = @import("std");
const drc = @import("placement/drc.zig");
const drc_json = @import("serve/drc_json.zig");

/// One register row: the category label as written, the DRC kind it names
/// (null when unrecognised), and the count it claims.
pub const Entry = struct {
    label: []const u8,
    kind: ?drc.Kind,
    count: usize,
};

/// One disagreement between the register and the release run.
pub const Drift = struct {
    label: []const u8,
    register: usize,
    actual: usize,
};

/// Lower-case `text` with separators folded to single spaces, so
/// "single-layer via", "single layer via" and "single_layer_via" agree.
fn normalizeInto(text: []const u8, buf: []u8) []const u8 {
    var n: usize = 0;
    var pending_space = false;
    for (text) |c| {
        const sep = c == ' ' or c == '-' or c == '_' or c == '\t';
        if (sep) {
            pending_space = n > 0;
            continue;
        }
        if (pending_space and n < buf.len) {
            buf[n] = ' ';
            n += 1;
            pending_space = false;
        }
        if (n == buf.len) break;
        buf[n] = std.ascii.toLower(c);
        n += 1;
    }
    return buf[0..n];
}

/// The DRC kind a register label names. A backticked token is read as the
/// kind's enum tag first; otherwise the label (with any parenthesised
/// backtick tag removed) is matched against every kind's display word and
/// tag under the same normalisation.
pub fn kindForLabel(label: []const u8) ?drc.Kind {
    if (std.mem.indexOfScalar(u8, label, '`')) |open| {
        if (std.mem.indexOfScalarPos(u8, label, open + 1, '`')) |close| {
            const token = std.mem.trim(u8, label[open + 1 .. close], " ");
            if (std.meta.stringToEnum(drc.Kind, token)) |kind| return kind;
        }
    }
    var plain_buf: [128]u8 = undefined;
    var plain_len: usize = 0;
    var in_tag = false;
    for (label) |c| {
        if (c == '`') {
            in_tag = !in_tag;
            continue;
        }
        if (in_tag or c == '(' or c == ')') continue;
        if (plain_len == plain_buf.len) break;
        plain_buf[plain_len] = c;
        plain_len += 1;
    }
    var want_buf: [128]u8 = undefined;
    const want = normalizeInto(std.mem.trim(u8, plain_buf[0..plain_len], " "), &want_buf);
    if (want.len == 0) return null;
    for (std.enums.values(drc.Kind)) |kind| {
        var word_buf: [64]u8 = undefined;
        if (std.mem.eql(u8, want, normalizeInto(drc_json.kindStr(kind), &word_buf))) return kind;
        var tag_buf: [64]u8 = undefined;
        if (std.mem.eql(u8, want, normalizeInto(@tagName(kind), &tag_buf))) return kind;
    }
    return null;
}

fn headingNamesBoard(line: []const u8, board: []const u8) bool {
    var search: usize = 0;
    while (std.mem.indexOfScalarPos(u8, line, search, '`')) |open| {
        const close = std.mem.indexOfScalarPos(u8, line, open + 1, '`') orelse return false;
        if (std.mem.eql(u8, line[open + 1 .. close], board)) return true;
        search = close + 1;
    }
    return false;
}

/// Split a Markdown table row into trimmed cells (no escaped-pipe support:
/// register rows never need one).
fn cells(line: []const u8, out: *[16][]const u8) usize {
    var body = std.mem.trim(u8, line, " \t\r");
    if (body.len > 0 and body[0] == '|') body = body[1..];
    if (body.len > 0 and body[body.len - 1] == '|') body = body[0 .. body.len - 1];
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, body, '|');
    while (it.next()) |cell| {
        if (n == out.len) break;
        out[n] = std.mem.trim(u8, cell, " \t");
        n += 1;
    }
    return n;
}

/// Every counted category row the register carries for `board`. Rows are
/// returned in document order; a category repeated across tables appears
/// once per row, and `drift` sums them.
pub fn parseBoard(
    allocator: std.mem.Allocator,
    source: []const u8,
    board: []const u8,
) std.mem.Allocator.Error![]Entry {
    var entries: std.ArrayList(Entry) = .empty;
    errdefer entries.deinit(allocator);
    var in_board = false;
    var in_table = false;
    var expect_delimiter = false;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len > 0 and line[0] == '#') {
            in_board = headingNamesBoard(line, board);
            in_table = false;
            continue;
        }
        if (!in_board) continue;
        if (line.len == 0 or line[0] != '|') {
            in_table = false;
            continue;
        }
        var row: [16][]const u8 = undefined;
        const n = cells(line, &row);
        if (!in_table) {
            if (n >= 2 and std.ascii.eqlIgnoreCase(row[1], "count")) {
                in_table = true;
                expect_delimiter = true;
            }
            continue;
        }
        if (expect_delimiter) {
            expect_delimiter = false;
            continue;
        }
        if (n < 2 or row[0].len == 0) continue;
        const count = std.fmt.parseInt(usize, row[1], 10) catch continue;
        try entries.append(allocator, .{ .label = row[0], .kind = kindForLabel(row[0]), .count = count });
    }
    return try entries.toOwnedSlice(allocator);
}

/// Warning-severity DRC counts per kind from a fabrication-readiness JSON
/// document (its `raw_drc` array). Errors are never waivable, so they are
/// not counted here.
pub fn actualWarnings(
    allocator: std.mem.Allocator,
    readiness_json: []const u8,
) std.mem.Allocator.Error!std.enums.EnumArray(drc.Kind, usize) {
    var counts = std.enums.EnumArray(drc.Kind, usize).initFill(0);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, readiness_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return counts,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return counts;
    const raw = parsed.value.object.get("raw_drc") orelse return counts;
    if (raw != .array) return counts;
    for (raw.array.items) |item| {
        if (item != .object) continue;
        const severity = item.object.get("severity") orelse continue;
        if (severity != .string or !std.mem.eql(u8, severity.string, "warn")) continue;
        const kind_value = item.object.get("kind") orelse continue;
        if (kind_value != .string) continue;
        const kind = std.meta.stringToEnum(drc.Kind, kind_value.string) orelse continue;
        counts.set(kind, counts.get(kind) + 1);
    }
    return counts;
}

/// Every kind whose registered count differs from the run, plus every
/// unrecognised register category (it vouches for nothing). Labels for
/// recognised kinds are the tool's display words.
pub fn drift(
    allocator: std.mem.Allocator,
    register: []const Entry,
    actual: std.enums.EnumArray(drc.Kind, usize),
) std.mem.Allocator.Error![]Drift {
    var registered = std.enums.EnumArray(drc.Kind, usize).initFill(0);
    var claimed = std.enums.EnumArray(drc.Kind, bool).initFill(false);
    var out: std.ArrayList(Drift) = .empty;
    errdefer out.deinit(allocator);
    for (register) |entry| {
        const kind = entry.kind orelse {
            try out.append(allocator, .{ .label = entry.label, .register = entry.count, .actual = 0 });
            continue;
        };
        registered.set(kind, registered.get(kind) + entry.count);
        claimed.set(kind, true);
    }
    for (std.enums.values(drc.Kind)) |kind| {
        const want = registered.get(kind);
        const have = actual.get(kind);
        if (want != have and (claimed.get(kind) or have > 0)) {
            try out.append(allocator, .{ .label = drc_json.kindStr(kind), .register = want, .actual = have });
        }
    }
    return try out.toOwnedSlice(allocator);
}

// ── Tests ─────────────────────────────────────────────────────────────────

const fixture_register =
    \\# DRC waiver register
    \\
    \\## 1. Waived warning categories
    \\
    \\### RF board `alpha`, layout "A" — 3 warnings waived
    \\
    \\| Category | Count | Nature |
    \\| --- | ---: | --- |
    \\| copper on own land | 2 | cosmetic |
    \\| silkscreen overlap (`silk_over_pad`) | 1 | cosmetic |
    \\| mystery finding | 4 | unknown |
    \\
    \\### Base board `beta`, layout "B" — 5 warnings waived
    \\
    \\| Category | Count | Nature |
    \\| --- | ---: | --- |
    \\| dangling copper | 5 | stubs |
    \\
    \\## 1b. Post-review additions
    \\
    \\| Category | §1 count | Now | Δ |
    \\| --- | ---: | ---: | ---: |
    \\| copper on own land | 2 | 9 | +7 |
    \\
;

// spec: waiver-register - register tables are read only under a heading naming the board and only when the second column is Count
test "register rows are scoped to the named board and the Count table shape" {
    const allocator = std.testing.allocator;
    const alpha = try parseBoard(allocator, fixture_register, "alpha");
    defer allocator.free(alpha);
    try std.testing.expectEqual(@as(usize, 3), alpha.len);
    try std.testing.expectEqual(drc.Kind.land_transit, alpha[0].kind.?);
    try std.testing.expectEqual(@as(usize, 2), alpha[0].count);
    try std.testing.expectEqual(drc.Kind.silk_over_pad, alpha[1].kind.?);
    try std.testing.expect(alpha[2].kind == null);
    const beta = try parseBoard(allocator, fixture_register, "beta");
    defer allocator.free(beta);
    try std.testing.expectEqual(@as(usize, 1), beta.len);
    try std.testing.expectEqual(drc.Kind.dangling_copper, beta[0].kind.?);
    const gamma = try parseBoard(allocator, fixture_register, "gamma");
    defer allocator.free(gamma);
    try std.testing.expectEqual(@as(usize, 0), gamma.len);
    try std.testing.expectEqual(drc.Kind.single_layer_via, kindForLabel("single layer via").?);
    try std.testing.expectEqual(drc.Kind.ground_via_distance, kindForLabel("Ground via too far").?);
}

// spec: waiver-register - drift lists every kind whose registered count differs from the release run's warning count, unrecognised categories included
test "drift compares registered counts with the run's warning kinds" {
    const allocator = std.testing.allocator;
    const readiness =
        \\{"raw_drc":[{"kind":"land_transit","severity":"warn"},{"kind":"land_transit","severity":"warn"},
        \\{"kind":"silk_over_pad","severity":"warn"},{"kind":"net_open","severity":"err"},
        \\{"kind":"courtyard","severity":"warn"}]}
    ;
    const actual = try actualWarnings(allocator, readiness);
    try std.testing.expectEqual(@as(usize, 2), actual.get(.land_transit));
    try std.testing.expectEqual(@as(usize, 0), actual.get(.net_open));
    const register = try parseBoard(allocator, fixture_register, "alpha");
    defer allocator.free(register);
    const drifts = try drift(allocator, register, actual);
    defer allocator.free(drifts);
    // land_transit and silk_over_pad agree; the unrecognised row and the
    // unregistered courtyard warning are reported.
    try std.testing.expectEqual(@as(usize, 2), drifts.len);
    try std.testing.expectEqualStrings("mystery finding", drifts[0].label);
    try std.testing.expectEqualStrings("courtyard overlap", drifts[1].label);
    try std.testing.expectEqual(@as(usize, 0), drifts[1].register);
    try std.testing.expectEqual(@as(usize, 1), drifts[1].actual);
    const empty = try drift(allocator, &.{}, std.enums.EnumArray(drc.Kind, usize).initFill(0));
    defer allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}
