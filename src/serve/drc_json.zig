//! DRC violation JSON — the single serialization every DRC-carrying endpoint
//! shares (/api/pcb-drc, /api/pcb-route, the embedded page blob, and
//! /api/pcb-describe's drc_list), so a violation's short traceable `id` can
//! never drift between surfaces: a user quoting "#a3f2" from the viewer's
//! inspector resolves to the same record everywhere.

const std = @import("std");
const drc = @import("../placement/drc.zig");

/// The human-readable kind word for a violation, shared by the JSON writer
/// and the viewer's tooltips/panel rows.
fn kindStr(k: drc.Kind) []const u8 {
    return switch (k) {
        .via_pad => "via↔pad",
        .via_via => "via↔via",
        .via_track => "via↔track",
        .track_track => "track↔track",
        .track_pad => "track↔pad",
        .pad_pad => "pad↔pad",
        .annular => "annular ring",
        .pad_annular => "pad annular ring",
        .board_edge => "board edge",
        .courtyard => "courtyard overlap",
        .hole_hole => "hole↔hole",
        .min_drill => "min drill",
        .track_width => "track width",
        .mask_sliver => "mask sliver",
        .silk_over_pad => "silk over pad",
    };
}

/// The severity word, matching `drc.Violation.severity` — surfaced so the
/// viewer chip can split error / warning counts.
fn sevStr(sev: drc.Severity) []const u8 {
    return switch (sev) {
        .err => "err",
        .warn => "warn",
    };
}

/// A violation coordinate quantized for hashing: rounded at `scale`, then
/// biased positive so the u64 conversion never sees a negative value (board
/// coordinates are tens of mm — nowhere near the 4e9 bias).
fn quant(val: f64, scale: f64) u64 {
    return @intFromFloat(@round(val * scale) + 4_000_000_000);
}

/// Deterministic short id for a DRC violation: FNV-1a over the kind word, the
/// marker position quantized to 0.01 mm, and the broken rule (0.001 mm),
/// folded to 16 bits → 4 hex chars. Stable across re-checks of the same board
/// state — the same defect keeps the same id run to run.
fn violationId(v: drc.Violation) u16 {
    var h: u32 = 0x811c9dc5;
    for (kindStr(v.kind)) |c| {
        h = (h ^ c) *% 0x01000193;
    }
    const q = [3]u64{ quant(v.x, 100), quant(v.y, 100), quant(v.clearance, 1000) };
    for (q) |val| {
        var u: u64 = val;
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            h = (h ^ @as(u8, @truncate(u))) *% 0x01000193;
            u >>= 8;
        }
    }
    return @truncate(h ^ (h >> 16));
}

/// One violation as a JSON object, `id` first.
pub fn writeViolation(w: *std.Io.Writer, v: drc.Violation) std.Io.Writer.Error!void {
    try w.print("{{\"id\":\"{x:0>4}\",\"x\":{d},\"y\":{d},\"gap\":{d},\"clr\":{d},\"k\":\"{s}\",\"sev\":\"{s}\"}}", .{
        violationId(v), v.x, v.y, v.gap, v.clearance, kindStr(v.kind), sevStr(v.severity),
    });
}

// spec: Web Server - A DRC violation carries a stable 4-hex id emitted by the shared JSON writer
test "violation id is deterministic, position-sensitive, and 4 hex chars in the JSON" {
    const v = drc.Violation{ .x = 2.05, .y = -3.7, .gap = 0, .clearance = 0.25, .kind = .hole_hole };
    const same = drc.Violation{ .x = 2.05, .y = -3.7, .gap = 0, .clearance = 0.25, .kind = .hole_hole };
    try std.testing.expectEqual(violationId(v), violationId(same));
    const moved = drc.Violation{ .x = 2.06, .y = -3.7, .gap = 0, .clearance = 0.25, .kind = .hole_hole };
    try std.testing.expect(violationId(v) != violationId(moved));
    const other = drc.Violation{ .x = 2.05, .y = -3.7, .gap = 0, .clearance = 0.25, .kind = .via_via };
    try std.testing.expect(violationId(v) != violationId(other));
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeViolation(&aw.writer, v);
    const out = aw.written();
    try std.testing.expect(std.mem.startsWith(u8, out, "{\"id\":\""));
    try std.testing.expectEqual(@as(u8, '"'), out[11]); // exactly 4 hex chars
    try std.testing.expect(std.mem.indexOf(u8, out, "\"k\":\"hole↔hole\"") != null);
}
