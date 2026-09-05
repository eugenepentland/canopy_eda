//! Single-line vector glyphs for fabricated silkscreen text.
//!
//! The face is Hershey Simplex — the single-stroke sans drawn by Dr. A. V.
//! Hershey (1967) and distributed as public-domain coordinate data; the table
//! below is transcribed from the classic 95-glyph ASCII array. It replaced a
//! hand-authored technical alphabet because a face designed for plotters and
//! engravers stays legible at silkscreen sizes where improvised letterforms
//! smear together.
//!
//! THIRD-PARTY FONT DATA. Copyright: 1967 Dr. A. V. Hershey, James Hurt. The
//! Hershey distribution permits any use, commercial or otherwise, provided
//! these acknowledgements travel with the font data:
//!
//!   - The Hershey Fonts were originally created by Dr. A. V. Hershey while
//!     working at the U. S. National Bureau of Standards.
//!   - The format of the Font data in this distribution was originally
//!     created by James Hurt, Cognition, Inc., 900 Technology Park Drive,
//!     Billerica, MA 01821.
//!
//! It also forbids redistributing the data in the U.S. NTIS format, which
//! this table is not. The full notice is in THIRD_PARTY_NOTICES.md; the same
//! data appears as `SILK_FONT` in `serve/assets/pcb_board.js`, which carries
//! the acknowledgement too.
//!
//! Like KiCad's default PCB face, glyphs are move/draw pen paths whose scale
//! is independent of line thickness, which Gerber preserves at 1 µm precision.
//! Coordinates are y-down: 0 is the cap top, `cap_units` (21) the baseline,
//! and lowercase descenders reach up to 7 units below the baseline. Advances
//! are proportional (per glyph). The browser viewer strokes the same table
//! from its `/*silk-font-table*/` JSON in `serve/assets/pcb_board.js`; a test
//! here proves the two copies stay glyph-for-glyph identical.

const std = @import("std");

/// Fabricated line thickness in millimetres, independent of cap height.
pub const stroke_width_mm: f64 = 0.15;
/// Normalized height from the top of a capital to its baseline.
pub const cap_units: f64 = 21;
/// Normalized em height. The visible cap occupies 90% of the nominal text size.
pub const em_units: f64 = cap_units / 0.9;
/// Advance for characters outside the table (the space advance).
pub const fallback_advance_units: f64 = 16;

/// Visible capital height for a nominal text size in millimetres.
pub fn heightMm(size: f64) f64 {
    return size * cap_units / em_units;
}

/// Origin-to-origin advance of one glyph in normalized font units.
pub fn advanceUnits(ch: u8) f64 {
    const glyph = glyphAt(ch) orelse return fallback_advance_units;
    return @floatFromInt(glyph.adv);
}

/// Total advance of a text run in normalized font units.
pub fn widthUnits(text: []const u8) f64 {
    var units: f64 = 0;
    for (text) |ch| units += advanceUnits(ch);
    return units;
}

/// Visible width of a text run for a nominal size in millimetres.
pub fn widthMm(text: []const u8, size: f64) f64 {
    return widthUnits(text) * size / em_units;
}

/// One pen-down line segment in normalized font coordinates.
pub const Stroke = struct { x1: f64, y1: f64, x2: f64, y2: f64 };

const Point = struct { x: i8, y: i8 };
const Glyph = struct { c: u8, adv: i8, points: []const Point };
const up = Point{ .x = -1, .y = -1 };
fn p(comptime x: i8, comptime y: i8) Point {
    return .{ .x = x, .y = y };
}

// Hershey Simplex, ASCII 32..126. `up` lifts the pen; real vertices never
// have negative x, so the sentinel cannot collide with glyph geometry
// (y may be negative — a few glyphs reach above the cap line).
const glyphs = blk: {
    @setEvalBranchQuota(100_000);
    break :blk [_]Glyph{
        .{ .c = ' ', .adv = 16, .points = &.{} },
        .{ .c = '!', .adv = 10, .points = &.{ p(5, 0), p(5, 14), up, p(5, 19), p(4, 20), p(5, 21), p(6, 20), p(5, 19) } },
        .{ .c = '"', .adv = 16, .points = &.{ p(4, 0), p(4, 7), up, p(12, 0), p(12, 7) } },
        .{ .c = '#', .adv = 21, .points = &.{ p(11, -4), p(4, 28), up, p(17, -4), p(10, 28), up, p(4, 9), p(18, 9), up, p(3, 15), p(17, 15) } },
        .{ .c = '$', .adv = 20, .points = &.{ p(8, -4), p(8, 25), up, p(12, -4), p(12, 25), up, p(17, 3), p(15, 1), p(12, 0), p(8, 0), p(5, 1), p(3, 3), p(3, 5), p(4, 7), p(5, 8), p(7, 9), p(13, 11), p(15, 12), p(16, 13), p(17, 15), p(17, 18), p(15, 20), p(12, 21), p(8, 21), p(5, 20), p(3, 18) } },
        .{ .c = '%', .adv = 24, .points = &.{ p(21, 0), p(3, 21), up, p(8, 0), p(10, 2), p(10, 4), p(9, 6), p(7, 7), p(5, 7), p(3, 5), p(3, 3), p(4, 1), p(6, 0), p(8, 0), p(10, 1), p(13, 2), p(16, 2), p(19, 1), p(21, 0), up, p(17, 14), p(15, 15), p(14, 17), p(14, 19), p(16, 21), p(18, 21), p(20, 20), p(21, 18), p(21, 16), p(19, 14), p(17, 14) } },
        .{ .c = '&', .adv = 26, .points = &.{ p(23, 9), p(23, 8), p(22, 7), p(21, 7), p(20, 8), p(19, 10), p(17, 15), p(15, 18), p(13, 20), p(11, 21), p(7, 21), p(5, 20), p(4, 19), p(3, 17), p(3, 15), p(4, 13), p(5, 12), p(12, 8), p(13, 7), p(14, 5), p(14, 3), p(13, 1), p(11, 0), p(9, 1), p(8, 3), p(8, 5), p(9, 8), p(11, 11), p(16, 18), p(18, 20), p(20, 21), p(22, 21), p(23, 20), p(23, 19) } },
        .{ .c = '\'', .adv = 10, .points = &.{ p(5, 2), p(4, 1), p(5, 0), p(6, 1), p(6, 3), p(5, 5), p(4, 6) } },
        .{ .c = '(', .adv = 14, .points = &.{ p(11, -4), p(9, -2), p(7, 1), p(5, 5), p(4, 10), p(4, 14), p(5, 19), p(7, 23), p(9, 26), p(11, 28) } },
        .{ .c = ')', .adv = 14, .points = &.{ p(3, -4), p(5, -2), p(7, 1), p(9, 5), p(10, 10), p(10, 14), p(9, 19), p(7, 23), p(5, 26), p(3, 28) } },
        .{ .c = '*', .adv = 16, .points = &.{ p(8, 0), p(8, 12), up, p(3, 3), p(13, 9), up, p(13, 3), p(3, 9) } },
        .{ .c = '+', .adv = 26, .points = &.{ p(13, 3), p(13, 21), up, p(4, 12), p(22, 12) } },
        .{ .c = ',', .adv = 10, .points = &.{ p(6, 20), p(5, 21), p(4, 20), p(5, 19), p(6, 20), p(6, 22), p(5, 24), p(4, 25) } },
        .{ .c = '-', .adv = 26, .points = &.{ p(4, 12), p(22, 12) } },
        .{ .c = '.', .adv = 10, .points = &.{ p(5, 19), p(4, 20), p(5, 21), p(6, 20), p(5, 19) } },
        .{ .c = '/', .adv = 22, .points = &.{ p(20, -4), p(2, 28) } },
        .{ .c = '0', .adv = 20, .points = &.{ p(9, 0), p(6, 1), p(4, 4), p(3, 9), p(3, 12), p(4, 17), p(6, 20), p(9, 21), p(11, 21), p(14, 20), p(16, 17), p(17, 12), p(17, 9), p(16, 4), p(14, 1), p(11, 0), p(9, 0) } },
        .{ .c = '1', .adv = 20, .points = &.{ p(6, 4), p(8, 3), p(11, 0), p(11, 21) } },
        .{ .c = '2', .adv = 20, .points = &.{ p(4, 5), p(4, 4), p(5, 2), p(6, 1), p(8, 0), p(12, 0), p(14, 1), p(15, 2), p(16, 4), p(16, 6), p(15, 8), p(13, 11), p(3, 21), p(17, 21) } },
        .{ .c = '3', .adv = 20, .points = &.{ p(5, 0), p(16, 0), p(10, 8), p(13, 8), p(15, 9), p(16, 10), p(17, 13), p(17, 15), p(16, 18), p(14, 20), p(11, 21), p(8, 21), p(5, 20), p(4, 19), p(3, 17) } },
        .{ .c = '4', .adv = 20, .points = &.{ p(13, 0), p(3, 14), p(18, 14), up, p(13, 0), p(13, 21) } },
        .{ .c = '5', .adv = 20, .points = &.{ p(15, 0), p(5, 0), p(4, 9), p(5, 8), p(8, 7), p(11, 7), p(14, 8), p(16, 10), p(17, 13), p(17, 15), p(16, 18), p(14, 20), p(11, 21), p(8, 21), p(5, 20), p(4, 19), p(3, 17) } },
        .{ .c = '6', .adv = 20, .points = &.{ p(16, 3), p(15, 1), p(12, 0), p(10, 0), p(7, 1), p(5, 4), p(4, 9), p(4, 14), p(5, 18), p(7, 20), p(10, 21), p(11, 21), p(14, 20), p(16, 18), p(17, 15), p(17, 14), p(16, 11), p(14, 9), p(11, 8), p(10, 8), p(7, 9), p(5, 11), p(4, 14) } },
        .{ .c = '7', .adv = 20, .points = &.{ p(17, 0), p(7, 21), up, p(3, 0), p(17, 0) } },
        .{ .c = '8', .adv = 20, .points = &.{ p(8, 0), p(5, 1), p(4, 3), p(4, 5), p(5, 7), p(7, 8), p(11, 9), p(14, 10), p(16, 12), p(17, 14), p(17, 17), p(16, 19), p(15, 20), p(12, 21), p(8, 21), p(5, 20), p(4, 19), p(3, 17), p(3, 14), p(4, 12), p(6, 10), p(9, 9), p(13, 8), p(15, 7), p(16, 5), p(16, 3), p(15, 1), p(12, 0), p(8, 0) } },
        .{ .c = '9', .adv = 20, .points = &.{ p(16, 7), p(15, 10), p(13, 12), p(10, 13), p(9, 13), p(6, 12), p(4, 10), p(3, 7), p(3, 6), p(4, 3), p(6, 1), p(9, 0), p(10, 0), p(13, 1), p(15, 3), p(16, 7), p(16, 12), p(15, 17), p(13, 20), p(10, 21), p(8, 21), p(5, 20), p(4, 18) } },
        .{ .c = ':', .adv = 10, .points = &.{ p(5, 7), p(4, 8), p(5, 9), p(6, 8), p(5, 7), up, p(5, 19), p(4, 20), p(5, 21), p(6, 20), p(5, 19) } },
        .{ .c = ';', .adv = 10, .points = &.{ p(5, 7), p(4, 8), p(5, 9), p(6, 8), p(5, 7), up, p(6, 20), p(5, 21), p(4, 20), p(5, 19), p(6, 20), p(6, 22), p(5, 24), p(4, 25) } },
        .{ .c = '<', .adv = 24, .points = &.{ p(20, 3), p(4, 12), p(20, 21) } },
        .{ .c = '=', .adv = 26, .points = &.{ p(4, 9), p(22, 9), up, p(4, 15), p(22, 15) } },
        .{ .c = '>', .adv = 24, .points = &.{ p(4, 3), p(20, 12), p(4, 21) } },
        .{ .c = '?', .adv = 18, .points = &.{ p(3, 5), p(3, 4), p(4, 2), p(5, 1), p(7, 0), p(11, 0), p(13, 1), p(14, 2), p(15, 4), p(15, 6), p(14, 8), p(13, 9), p(9, 11), p(9, 14), up, p(9, 19), p(8, 20), p(9, 21), p(10, 20), p(9, 19) } },
        .{ .c = '@', .adv = 27, .points = &.{ p(18, 8), p(17, 6), p(15, 5), p(12, 5), p(10, 6), p(9, 7), p(8, 10), p(8, 13), p(9, 15), p(11, 16), p(14, 16), p(16, 15), p(17, 13), up, p(12, 5), p(10, 7), p(9, 10), p(9, 13), p(10, 15), p(11, 16), up, p(18, 5), p(17, 13), p(17, 15), p(19, 16), p(21, 16), p(23, 14), p(24, 11), p(24, 9), p(23, 6), p(22, 4), p(20, 2), p(18, 1), p(15, 0), p(12, 0), p(9, 1), p(7, 2), p(5, 4), p(4, 6), p(3, 9), p(3, 12), p(4, 15), p(5, 17), p(7, 19), p(9, 20), p(12, 21), p(15, 21), p(18, 20), p(20, 19), p(21, 18), up, p(19, 5), p(18, 13), p(18, 15), p(19, 16) } },
        .{ .c = 'A', .adv = 18, .points = &.{ p(9, 0), p(1, 21), up, p(9, 0), p(17, 21), up, p(4, 14), p(14, 14) } },
        .{ .c = 'B', .adv = 21, .points = &.{ p(4, 0), p(4, 21), up, p(4, 0), p(13, 0), p(16, 1), p(17, 2), p(18, 4), p(18, 6), p(17, 8), p(16, 9), p(13, 10), up, p(4, 10), p(13, 10), p(16, 11), p(17, 12), p(18, 14), p(18, 17), p(17, 19), p(16, 20), p(13, 21), p(4, 21) } },
        .{ .c = 'C', .adv = 21, .points = &.{ p(18, 5), p(17, 3), p(15, 1), p(13, 0), p(9, 0), p(7, 1), p(5, 3), p(4, 5), p(3, 8), p(3, 13), p(4, 16), p(5, 18), p(7, 20), p(9, 21), p(13, 21), p(15, 20), p(17, 18), p(18, 16) } },
        .{ .c = 'D', .adv = 21, .points = &.{ p(4, 0), p(4, 21), up, p(4, 0), p(11, 0), p(14, 1), p(16, 3), p(17, 5), p(18, 8), p(18, 13), p(17, 16), p(16, 18), p(14, 20), p(11, 21), p(4, 21) } },
        .{ .c = 'E', .adv = 19, .points = &.{ p(4, 0), p(4, 21), up, p(4, 0), p(17, 0), up, p(4, 10), p(12, 10), up, p(4, 21), p(17, 21) } },
        .{ .c = 'F', .adv = 18, .points = &.{ p(4, 0), p(4, 21), up, p(4, 0), p(17, 0), up, p(4, 10), p(12, 10) } },
        .{ .c = 'G', .adv = 21, .points = &.{ p(18, 5), p(17, 3), p(15, 1), p(13, 0), p(9, 0), p(7, 1), p(5, 3), p(4, 5), p(3, 8), p(3, 13), p(4, 16), p(5, 18), p(7, 20), p(9, 21), p(13, 21), p(15, 20), p(17, 18), p(18, 16), p(18, 13), up, p(13, 13), p(18, 13) } },
        .{ .c = 'H', .adv = 22, .points = &.{ p(4, 0), p(4, 21), up, p(18, 0), p(18, 21), up, p(4, 10), p(18, 10) } },
        .{ .c = 'I', .adv = 8, .points = &.{ p(4, 0), p(4, 21) } },
        .{ .c = 'J', .adv = 16, .points = &.{ p(12, 0), p(12, 16), p(11, 19), p(10, 20), p(8, 21), p(6, 21), p(4, 20), p(3, 19), p(2, 16), p(2, 14) } },
        .{ .c = 'K', .adv = 21, .points = &.{ p(4, 0), p(4, 21), up, p(18, 0), p(4, 14), up, p(9, 9), p(18, 21) } },
        .{ .c = 'L', .adv = 17, .points = &.{ p(4, 0), p(4, 21), up, p(4, 21), p(16, 21) } },
        .{ .c = 'M', .adv = 24, .points = &.{ p(4, 0), p(4, 21), up, p(4, 0), p(12, 21), up, p(20, 0), p(12, 21), up, p(20, 0), p(20, 21) } },
        .{ .c = 'N', .adv = 22, .points = &.{ p(4, 0), p(4, 21), up, p(4, 0), p(18, 21), up, p(18, 0), p(18, 21) } },
        .{ .c = 'O', .adv = 22, .points = &.{ p(9, 0), p(7, 1), p(5, 3), p(4, 5), p(3, 8), p(3, 13), p(4, 16), p(5, 18), p(7, 20), p(9, 21), p(13, 21), p(15, 20), p(17, 18), p(18, 16), p(19, 13), p(19, 8), p(18, 5), p(17, 3), p(15, 1), p(13, 0), p(9, 0) } },
        .{ .c = 'P', .adv = 21, .points = &.{ p(4, 0), p(4, 21), up, p(4, 0), p(13, 0), p(16, 1), p(17, 2), p(18, 4), p(18, 7), p(17, 9), p(16, 10), p(13, 11), p(4, 11) } },
        .{ .c = 'Q', .adv = 22, .points = &.{ p(9, 0), p(7, 1), p(5, 3), p(4, 5), p(3, 8), p(3, 13), p(4, 16), p(5, 18), p(7, 20), p(9, 21), p(13, 21), p(15, 20), p(17, 18), p(18, 16), p(19, 13), p(19, 8), p(18, 5), p(17, 3), p(15, 1), p(13, 0), p(9, 0), up, p(12, 17), p(18, 23) } },
        .{ .c = 'R', .adv = 21, .points = &.{ p(4, 0), p(4, 21), up, p(4, 0), p(13, 0), p(16, 1), p(17, 2), p(18, 4), p(18, 6), p(17, 8), p(16, 9), p(13, 10), p(4, 10), up, p(11, 10), p(18, 21) } },
        .{ .c = 'S', .adv = 20, .points = &.{ p(17, 3), p(15, 1), p(12, 0), p(8, 0), p(5, 1), p(3, 3), p(3, 5), p(4, 7), p(5, 8), p(7, 9), p(13, 11), p(15, 12), p(16, 13), p(17, 15), p(17, 18), p(15, 20), p(12, 21), p(8, 21), p(5, 20), p(3, 18) } },
        .{ .c = 'T', .adv = 16, .points = &.{ p(8, 0), p(8, 21), up, p(1, 0), p(15, 0) } },
        .{ .c = 'U', .adv = 22, .points = &.{ p(4, 0), p(4, 15), p(5, 18), p(7, 20), p(10, 21), p(12, 21), p(15, 20), p(17, 18), p(18, 15), p(18, 0) } },
        .{ .c = 'V', .adv = 18, .points = &.{ p(1, 0), p(9, 21), up, p(17, 0), p(9, 21) } },
        .{ .c = 'W', .adv = 24, .points = &.{ p(2, 0), p(7, 21), up, p(12, 0), p(7, 21), up, p(12, 0), p(17, 21), up, p(22, 0), p(17, 21) } },
        .{ .c = 'X', .adv = 20, .points = &.{ p(3, 0), p(17, 21), up, p(17, 0), p(3, 21) } },
        .{ .c = 'Y', .adv = 18, .points = &.{ p(1, 0), p(9, 10), p(9, 21), up, p(17, 0), p(9, 10) } },
        .{ .c = 'Z', .adv = 20, .points = &.{ p(17, 0), p(3, 21), up, p(3, 0), p(17, 0), up, p(3, 21), p(17, 21) } },
        .{ .c = '[', .adv = 14, .points = &.{ p(4, -4), p(4, 28), up, p(5, -4), p(5, 28), up, p(4, -4), p(11, -4), up, p(4, 28), p(11, 28) } },
        .{ .c = '\\', .adv = 14, .points = &.{ p(0, 0), p(14, 24) } },
        .{ .c = ']', .adv = 14, .points = &.{ p(9, -4), p(9, 28), up, p(10, -4), p(10, 28), up, p(3, -4), p(10, -4), up, p(3, 28), p(10, 28) } },
        .{ .c = '^', .adv = 16, .points = &.{ p(6, 6), p(8, 3), p(10, 6), up, p(3, 9), p(8, 4), p(13, 9), up, p(8, 4), p(8, 21) } },
        .{ .c = '_', .adv = 16, .points = &.{ p(0, 23), p(16, 23) } },
        .{ .c = '`', .adv = 10, .points = &.{ p(6, 0), p(5, 1), p(4, 3), p(4, 5), p(5, 6), p(6, 5), p(5, 4) } },
        .{ .c = 'a', .adv = 19, .points = &.{ p(15, 7), p(15, 21), up, p(15, 10), p(13, 8), p(11, 7), p(8, 7), p(6, 8), p(4, 10), p(3, 13), p(3, 15), p(4, 18), p(6, 20), p(8, 21), p(11, 21), p(13, 20), p(15, 18) } },
        .{ .c = 'b', .adv = 19, .points = &.{ p(4, 0), p(4, 21), up, p(4, 10), p(6, 8), p(8, 7), p(11, 7), p(13, 8), p(15, 10), p(16, 13), p(16, 15), p(15, 18), p(13, 20), p(11, 21), p(8, 21), p(6, 20), p(4, 18) } },
        .{ .c = 'c', .adv = 18, .points = &.{ p(15, 10), p(13, 8), p(11, 7), p(8, 7), p(6, 8), p(4, 10), p(3, 13), p(3, 15), p(4, 18), p(6, 20), p(8, 21), p(11, 21), p(13, 20), p(15, 18) } },
        .{ .c = 'd', .adv = 19, .points = &.{ p(15, 0), p(15, 21), up, p(15, 10), p(13, 8), p(11, 7), p(8, 7), p(6, 8), p(4, 10), p(3, 13), p(3, 15), p(4, 18), p(6, 20), p(8, 21), p(11, 21), p(13, 20), p(15, 18) } },
        .{ .c = 'e', .adv = 18, .points = &.{ p(3, 13), p(15, 13), p(15, 11), p(14, 9), p(13, 8), p(11, 7), p(8, 7), p(6, 8), p(4, 10), p(3, 13), p(3, 15), p(4, 18), p(6, 20), p(8, 21), p(11, 21), p(13, 20), p(15, 18) } },
        .{ .c = 'f', .adv = 12, .points = &.{ p(10, 0), p(8, 0), p(6, 1), p(5, 4), p(5, 21), up, p(2, 7), p(9, 7) } },
        .{ .c = 'g', .adv = 19, .points = &.{ p(15, 7), p(15, 23), p(14, 26), p(13, 27), p(11, 28), p(8, 28), p(6, 27), up, p(15, 10), p(13, 8), p(11, 7), p(8, 7), p(6, 8), p(4, 10), p(3, 13), p(3, 15), p(4, 18), p(6, 20), p(8, 21), p(11, 21), p(13, 20), p(15, 18) } },
        .{ .c = 'h', .adv = 19, .points = &.{ p(4, 0), p(4, 21), up, p(4, 11), p(7, 8), p(9, 7), p(12, 7), p(14, 8), p(15, 11), p(15, 21) } },
        .{ .c = 'i', .adv = 8, .points = &.{ p(3, 0), p(4, 1), p(5, 0), p(4, -1), p(3, 0), up, p(4, 7), p(4, 21) } },
        .{ .c = 'j', .adv = 10, .points = &.{ p(5, 0), p(6, 1), p(7, 0), p(6, -1), p(5, 0), up, p(6, 7), p(6, 24), p(5, 27), p(3, 28), p(1, 28) } },
        .{ .c = 'k', .adv = 17, .points = &.{ p(4, 0), p(4, 21), up, p(14, 7), p(4, 17), up, p(8, 13), p(15, 21) } },
        .{ .c = 'l', .adv = 8, .points = &.{ p(4, 0), p(4, 21) } },
        .{ .c = 'm', .adv = 30, .points = &.{ p(4, 7), p(4, 21), up, p(4, 11), p(7, 8), p(9, 7), p(12, 7), p(14, 8), p(15, 11), p(15, 21), up, p(15, 11), p(18, 8), p(20, 7), p(23, 7), p(25, 8), p(26, 11), p(26, 21) } },
        .{ .c = 'n', .adv = 19, .points = &.{ p(4, 7), p(4, 21), up, p(4, 11), p(7, 8), p(9, 7), p(12, 7), p(14, 8), p(15, 11), p(15, 21) } },
        .{ .c = 'o', .adv = 19, .points = &.{ p(8, 7), p(6, 8), p(4, 10), p(3, 13), p(3, 15), p(4, 18), p(6, 20), p(8, 21), p(11, 21), p(13, 20), p(15, 18), p(16, 15), p(16, 13), p(15, 10), p(13, 8), p(11, 7), p(8, 7) } },
        .{ .c = 'p', .adv = 19, .points = &.{ p(4, 7), p(4, 28), up, p(4, 10), p(6, 8), p(8, 7), p(11, 7), p(13, 8), p(15, 10), p(16, 13), p(16, 15), p(15, 18), p(13, 20), p(11, 21), p(8, 21), p(6, 20), p(4, 18) } },
        .{ .c = 'q', .adv = 19, .points = &.{ p(15, 7), p(15, 28), up, p(15, 10), p(13, 8), p(11, 7), p(8, 7), p(6, 8), p(4, 10), p(3, 13), p(3, 15), p(4, 18), p(6, 20), p(8, 21), p(11, 21), p(13, 20), p(15, 18) } },
        .{ .c = 'r', .adv = 13, .points = &.{ p(4, 7), p(4, 21), up, p(4, 13), p(5, 10), p(7, 8), p(9, 7), p(12, 7) } },
        .{ .c = 's', .adv = 17, .points = &.{ p(14, 10), p(13, 8), p(10, 7), p(7, 7), p(4, 8), p(3, 10), p(4, 12), p(6, 13), p(11, 14), p(13, 15), p(14, 17), p(14, 18), p(13, 20), p(10, 21), p(7, 21), p(4, 20), p(3, 18) } },
        .{ .c = 't', .adv = 12, .points = &.{ p(5, 0), p(5, 17), p(6, 20), p(8, 21), p(10, 21), up, p(2, 7), p(9, 7) } },
        .{ .c = 'u', .adv = 19, .points = &.{ p(4, 7), p(4, 17), p(5, 20), p(7, 21), p(10, 21), p(12, 20), p(15, 17), up, p(15, 7), p(15, 21) } },
        .{ .c = 'v', .adv = 16, .points = &.{ p(2, 7), p(8, 21), up, p(14, 7), p(8, 21) } },
        .{ .c = 'w', .adv = 22, .points = &.{ p(3, 7), p(7, 21), up, p(11, 7), p(7, 21), up, p(11, 7), p(15, 21), up, p(19, 7), p(15, 21) } },
        .{ .c = 'x', .adv = 17, .points = &.{ p(3, 7), p(14, 21), up, p(14, 7), p(3, 21) } },
        .{ .c = 'y', .adv = 16, .points = &.{ p(2, 7), p(8, 21), up, p(14, 7), p(8, 21), p(6, 25), p(4, 27), p(2, 28), p(1, 28) } },
        .{ .c = 'z', .adv = 17, .points = &.{ p(14, 7), p(3, 21), up, p(3, 7), p(14, 7), up, p(3, 21), p(14, 21) } },
        .{ .c = '{', .adv = 14, .points = &.{ p(9, -4), p(7, -3), p(6, -2), p(5, 0), p(5, 2), p(6, 4), p(7, 5), p(8, 7), p(8, 9), p(6, 11), up, p(7, -3), p(6, -1), p(6, 1), p(7, 3), p(8, 4), p(9, 6), p(9, 8), p(8, 10), p(4, 12), p(8, 14), p(9, 16), p(9, 18), p(8, 20), p(7, 21), p(6, 23), p(6, 25), p(7, 27), up, p(6, 13), p(8, 15), p(8, 17), p(7, 19), p(6, 20), p(5, 22), p(5, 24), p(6, 26), p(7, 27), p(9, 28) } },
        .{ .c = '|', .adv = 8, .points = &.{ p(4, -4), p(4, 28) } },
        .{ .c = '}', .adv = 14, .points = &.{ p(5, -4), p(7, -3), p(8, -2), p(9, 0), p(9, 2), p(8, 4), p(7, 5), p(6, 7), p(6, 9), p(8, 11), up, p(7, -3), p(8, -1), p(8, 1), p(7, 3), p(6, 4), p(5, 6), p(5, 8), p(6, 10), p(10, 12), p(6, 14), p(5, 16), p(5, 18), p(6, 20), p(7, 21), p(8, 23), p(8, 25), p(7, 27), up, p(8, 13), p(6, 15), p(6, 17), p(7, 19), p(8, 20), p(9, 22), p(9, 24), p(8, 26), p(7, 27), p(5, 28) } },
        .{ .c = '~', .adv = 24, .points = &.{ p(3, 15), p(3, 13), p(4, 10), p(6, 9), p(8, 9), p(10, 10), p(14, 13), p(16, 14), p(18, 14), p(20, 13), p(21, 11), up, p(3, 13), p(4, 11), p(6, 10), p(8, 10), p(10, 11), p(14, 14), p(16, 15), p(18, 15), p(20, 14), p(21, 11), p(21, 9) } },
    };
};

fn glyphAt(ch: u8) ?*const Glyph {
    if (ch < 32 or ch > 126) return null;
    return &glyphs[ch - 32];
}

/// Emit each pen-down segment of one glyph in normalized font units.
/// Characters outside the table draw nothing (and advance by the fallback).
pub fn glyphStrokes(ch: u8, comptime E: type, ctx: anytype, emit: fn (@TypeOf(ctx), Stroke) E!void) E!void {
    const glyph = glyphAt(ch) orelse return;
    var previous: ?Point = null;
    for (glyph.points) |point| {
        if (point.x < 0) {
            previous = null;
            continue;
        }
        if (previous) |start| {
            try emit(ctx, .{
                .x1 = @floatFromInt(start.x),
                .y1 = @floatFromInt(start.y),
                .x2 = @floatFromInt(point.x),
                .y2 = @floatFromInt(point.y),
            });
        }
        previous = point;
    }
}

test "glyph table is in ASCII order with a safe pen-up sentinel" {
    // glyphAt indexes by `ch - 32`, so the table must stay in ASCII order,
    // and a real vertex must never collide with the (-1,-1) pen-up sentinel.
    for (glyphs, 0..) |glyph, i| {
        try std.testing.expectEqual(@as(u8, @intCast(i + 32)), glyph.c);
        for (glyph.points) |point| {
            if (point.x < 0) {
                try std.testing.expectEqual(@as(i8, -1), point.x);
                try std.testing.expectEqual(@as(i8, -1), point.y);
            }
        }
    }
}

test "vector glyphs are pen paths rather than bitmap rows" {
    const Counter = struct {
        n: usize = 0,
        diagonal: bool = false,
        fn emit(self: *@This(), stroke: Stroke) error{}!void {
            self.n += 1;
            self.diagonal = self.diagonal or (stroke.x1 != stroke.x2 and stroke.y1 != stroke.y2);
        }
    };
    var tee = Counter{};
    try glyphStrokes('T', error{}, &tee, Counter.emit);
    try std.testing.expectEqual(@as(usize, 2), tee.n);
    var a = Counter{};
    try glyphStrokes('A', error{}, &a, Counter.emit);
    try std.testing.expect(a.diagonal);
    var blank = Counter{};
    try glyphStrokes(' ', error{}, &blank, Counter.emit);
    try std.testing.expectEqual(@as(usize, 0), blank.n);
}

const Bounds = struct {
    min_y: f64 = std.math.inf(f64),
    max_y: f64 = -std.math.inf(f64),

    fn emit(self: *@This(), stroke: Stroke) error{}!void {
        self.min_y = @min(self.min_y, @min(stroke.y1, stroke.y2));
        self.max_y = @max(self.max_y, @max(stroke.y1, stroke.y2));
    }

    fn of(ch: u8) !@This() {
        var bounds = @This(){};
        try glyphStrokes(ch, error{}, &bounds, emit);
        return bounds;
    }
};

test "capitals and digits share one cap height; lowercase keeps its own shape" {
    const cap_a = try Bounds.of('A');
    const digit = try Bounds.of('1');
    try std.testing.expectEqual(cap_units, cap_a.max_y - cap_a.min_y);
    try std.testing.expectEqual(cap_units, digit.max_y - digit.min_y);
    // Real lowercase now: 'a' spans only its x-height…
    const low_a = try Bounds.of('a');
    try std.testing.expect(low_a.max_y - low_a.min_y < cap_units);
    // …and 'p' descends below the baseline (y grows down; baseline = cap_units).
    const low_p = try Bounds.of('p');
    try std.testing.expect(low_p.max_y > cap_units);
}

// spec: export_gerber - fabricated glyphs occupy 90 percent of their nominal text height and advance proportionally by per-glyph widths
test "fabricated font keeps the 90 percent cap and proportional advances" {
    try std.testing.expectApproxEqAbs(@as(f64, 0.9), heightMm(1), 1e-12);
    // A run's width is the sum of its glyphs' own advances…
    try std.testing.expectApproxEqAbs(
        (advanceUnits('A') + advanceUnits('B')) / em_units,
        widthMm("AB", 1),
        1e-12,
    );
    // …and those advances differ per glyph (a real proportional face).
    try std.testing.expect(widthMm("II", 1) < widthMm("MM", 1));
    // Unknown characters keep the layout stable at the space advance.
    try std.testing.expectApproxEqAbs(widthMm(" ", 1), widthMm("\x01", 1), 1e-12);
}

// spec: export_gerber - the viewer strokes board silkscreen text from the same glyph table the Gerber writer fabricates
test "viewer silk font table matches the fabricated glyphs" {
    const js = @embedFile("serve/assets/pcb_board.js");
    const start_marker = "/*silk-font-table*/";
    const end_marker = "/*end-silk-font-table*/";
    const start = (std.mem.indexOf(u8, js, start_marker) orelse return error.MarkerMissing) + start_marker.len;
    const end = std.mem.indexOf(u8, js, end_marker) orelse return error.MarkerMissing;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, js[start..end], .{});
    defer parsed.deinit();
    const table = parsed.value.object;
    try std.testing.expectEqual(glyphs.len, table.count());
    for (glyphs) |glyph| {
        const key = [1]u8{glyph.c};
        const entry = table.get(&key) orelse return error.GlyphMissing;
        const row = entry.array.items;
        try std.testing.expectEqual(@as(i64, glyph.adv), row[0].integer);
        try std.testing.expectEqual(glyph.points.len * 2 + 1, row.len);
        for (glyph.points, 0..) |point, i| {
            try std.testing.expectEqual(@as(i64, point.x), row[1 + 2 * i].integer);
            try std.testing.expectEqual(@as(i64, point.y), row[2 + 2 * i].integer);
        }
    }
}
