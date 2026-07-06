//! A 5x7 bitmap font for PCB-layout PNG labels (ref-designators, net names,
//! captions) and board-level silkscreen text. Glyphs are authored as visual
//! ASCII-art grids — each row is a 5-char string drawn with '#' (lit) and
//! ' ' (clear) — and packed to column-major bytes at comptime, so the source
//! reads as the rendered shape and is verifiable by eye. Covers uppercase
//! A-Z, lowercase a-z, digits, and the punctuation that appears in ref-des /
//! net names / user text; ref-des labelling uppercases text before drawing,
//! but user silkscreen text draws lowercase directly (unknown chars blank).

const std = @import("std");

/// Glyph cell dimensions in font pixels.
pub const GW: u32 = 5;
pub const GH: u32 = 7;

/// Pack a 7-row visual grid into 5 column bytes (bit r = row r, top..bottom).
fn pack(rows: [GH][]const u8) [GW]u8 {
    var out = [_]u8{0} ** GW;
    for (rows, 0..) |row, r| {
        var c: usize = 0;
        while (c < GW) : (c += 1) {
            if (c < row.len and row[c] == '#') out[c] |= (@as(u8, 1) << @as(u3, @intCast(r)));
        }
    }
    return out;
}

const GlyphDef = struct { c: u8, r: [GH][]const u8 };

/// Visual glyph definitions. Each is a 7×5 grid.
const GLYPHS = [_]GlyphDef{
    .{ .c = '0', .r = .{ " ### ", "#   #", "#  ##", "# # #", "##  #", "#   #", " ### " } },
    .{ .c = '1', .r = .{ "  #  ", " ##  ", "  #  ", "  #  ", "  #  ", "  #  ", " ### " } },
    .{ .c = '2', .r = .{ " ### ", "#   #", "    #", "   # ", "  #  ", " #   ", "#####" } },
    .{ .c = '3', .r = .{ "#####", "   # ", "  #  ", "   # ", "    #", "#   #", " ### " } },
    .{ .c = '4', .r = .{ "   # ", "  ## ", " # # ", "#  # ", "#####", "   # ", "   # " } },
    .{ .c = '5', .r = .{ "#####", "#    ", "#### ", "    #", "    #", "#   #", " ### " } },
    .{ .c = '6', .r = .{ " ### ", "#   #", "#    ", "#### ", "#   #", "#   #", " ### " } },
    .{ .c = '7', .r = .{ "#####", "    #", "   # ", "  #  ", " #   ", " #   ", " #   " } },
    .{ .c = '8', .r = .{ " ### ", "#   #", "#   #", " ### ", "#   #", "#   #", " ### " } },
    .{ .c = '9', .r = .{ " ### ", "#   #", "#   #", " ####", "    #", "#   #", " ### " } },
    .{ .c = 'A', .r = .{ " ### ", "#   #", "#   #", "#####", "#   #", "#   #", "#   #" } },
    .{ .c = 'B', .r = .{ "#### ", "#   #", "#   #", "#### ", "#   #", "#   #", "#### " } },
    .{ .c = 'C', .r = .{ " ### ", "#   #", "#    ", "#    ", "#    ", "#   #", " ### " } },
    .{ .c = 'D', .r = .{ "#### ", "#   #", "#   #", "#   #", "#   #", "#   #", "#### " } },
    .{ .c = 'E', .r = .{ "#####", "#    ", "#    ", "#### ", "#    ", "#    ", "#####" } },
    .{ .c = 'F', .r = .{ "#####", "#    ", "#    ", "#### ", "#    ", "#    ", "#    " } },
    .{ .c = 'G', .r = .{ " ### ", "#   #", "#    ", "# ###", "#   #", "#   #", " ### " } },
    .{ .c = 'H', .r = .{ "#   #", "#   #", "#   #", "#####", "#   #", "#   #", "#   #" } },
    .{ .c = 'I', .r = .{ " ### ", "  #  ", "  #  ", "  #  ", "  #  ", "  #  ", " ### " } },
    .{ .c = 'J', .r = .{ "  ###", "   # ", "   # ", "   # ", "   # ", "#  # ", " ##  " } },
    .{ .c = 'K', .r = .{ "#   #", "#  # ", "# #  ", "##   ", "# #  ", "#  # ", "#   #" } },
    .{ .c = 'L', .r = .{ "#    ", "#    ", "#    ", "#    ", "#    ", "#    ", "#####" } },
    .{ .c = 'M', .r = .{ "#   #", "## ##", "# # #", "# # #", "#   #", "#   #", "#   #" } },
    .{ .c = 'N', .r = .{ "#   #", "#   #", "##  #", "# # #", "#  ##", "#   #", "#   #" } },
    .{ .c = 'O', .r = .{ " ### ", "#   #", "#   #", "#   #", "#   #", "#   #", " ### " } },
    .{ .c = 'P', .r = .{ "#### ", "#   #", "#   #", "#### ", "#    ", "#    ", "#    " } },
    .{ .c = 'Q', .r = .{ " ### ", "#   #", "#   #", "#   #", "# # #", "#  # ", " ## #" } },
    .{ .c = 'R', .r = .{ "#### ", "#   #", "#   #", "#### ", "# #  ", "#  # ", "#   #" } },
    .{ .c = 'S', .r = .{ " ####", "#    ", "#    ", " ### ", "    #", "    #", "#### " } },
    .{ .c = 'T', .r = .{ "#####", "  #  ", "  #  ", "  #  ", "  #  ", "  #  ", "  #  " } },
    .{ .c = 'U', .r = .{ "#   #", "#   #", "#   #", "#   #", "#   #", "#   #", " ### " } },
    .{ .c = 'V', .r = .{ "#   #", "#   #", "#   #", "#   #", "#   #", " # # ", "  #  " } },
    .{ .c = 'W', .r = .{ "#   #", "#   #", "#   #", "# # #", "# # #", "## ##", "#   #" } },
    .{ .c = 'X', .r = .{ "#   #", "#   #", " # # ", "  #  ", " # # ", "#   #", "#   #" } },
    .{ .c = 'Y', .r = .{ "#   #", "#   #", " # # ", "  #  ", "  #  ", "  #  ", "  #  " } },
    .{ .c = 'Z', .r = .{ "#####", "    #", "   # ", "  #  ", " #   ", "#    ", "#####" } },
    .{ .c = '-', .r = .{ "     ", "     ", "     ", "#####", "     ", "     ", "     " } },
    .{ .c = '_', .r = .{ "     ", "     ", "     ", "     ", "     ", "     ", "#####" } },
    .{ .c = '.', .r = .{ "     ", "     ", "     ", "     ", "     ", " ##  ", " ##  " } },
    .{ .c = ',', .r = .{ "     ", "     ", "     ", "     ", " ##  ", " ##  ", " #   " } },
    .{ .c = '/', .r = .{ "    #", "    #", "   # ", "  #  ", " #   ", "#    ", "#    " } },
    .{ .c = '+', .r = .{ "     ", "  #  ", "  #  ", "#####", "  #  ", "  #  ", "     " } },
    .{ .c = ':', .r = .{ "     ", " ##  ", " ##  ", "     ", " ##  ", " ##  ", "     " } },
    .{ .c = '=', .r = .{ "     ", "     ", "#####", "     ", "#####", "     ", "     " } },
    .{ .c = '#', .r = .{ " # # ", " # # ", "#####", " # # ", "#####", " # # ", " # # " } },
    .{ .c = '(', .r = .{ "  ## ", " #   ", " #   ", " #   ", " #   ", " #   ", "  ## " } },
    .{ .c = ')', .r = .{ " ##  ", "   # ", "   # ", "   # ", "   # ", "   # ", " ##  " } },
    .{ .c = '>', .r = .{ "#    ", " #   ", "  #  ", "   # ", "  #  ", " #   ", "#    " } },
    .{ .c = '<', .r = .{ "    #", "   # ", "  #  ", " #   ", "  #  ", "   # ", "    #" } },
    .{ .c = '*', .r = .{ "     ", "# # #", " ### ", "#####", " ### ", "# # #", "     " } },
    .{ .c = '%', .r = .{ "##  #", "## # ", "  #  ", " #   ", "# ## ", "#  ##", "    #" } },
    // Lowercase a-z. Two-row ascender/descender headroom keeps them inside the
    // 7-row cell; drawn directly for user silkscreen text (ref-des is uppercased).
    .{ .c = 'a', .r = .{ "     ", "     ", " ### ", "    #", " ####", "#   #", " ####" } },
    .{ .c = 'b', .r = .{ "#    ", "#    ", "#### ", "#   #", "#   #", "#   #", "#### " } },
    .{ .c = 'c', .r = .{ "     ", "     ", " ### ", "#   #", "#    ", "#   #", " ### " } },
    .{ .c = 'd', .r = .{ "    #", "    #", " ####", "#   #", "#   #", "#   #", " ####" } },
    .{ .c = 'e', .r = .{ "     ", "     ", " ### ", "#   #", "#####", "#    ", " ### " } },
    .{ .c = 'f', .r = .{ "  ## ", " #   ", "#### ", " #   ", " #   ", " #   ", " #   " } },
    .{ .c = 'g', .r = .{ "     ", " ####", "#   #", "#   #", " ####", "    #", " ### " } },
    .{ .c = 'h', .r = .{ "#    ", "#    ", "#### ", "#   #", "#   #", "#   #", "#   #" } },
    .{ .c = 'i', .r = .{ "  #  ", "     ", " ##  ", "  #  ", "  #  ", "  #  ", " ### " } },
    .{ .c = 'j', .r = .{ "   # ", "     ", "  ## ", "   # ", "   # ", "#  # ", " ##  " } },
    .{ .c = 'k', .r = .{ "#    ", "#    ", "#  # ", "# #  ", "##   ", "# #  ", "#  # " } },
    .{ .c = 'l', .r = .{ " ##  ", "  #  ", "  #  ", "  #  ", "  #  ", "  #  ", " ### " } },
    .{ .c = 'm', .r = .{ "     ", "     ", "## # ", "# # #", "# # #", "# # #", "#   #" } },
    .{ .c = 'n', .r = .{ "     ", "     ", "#### ", "#   #", "#   #", "#   #", "#   #" } },
    .{ .c = 'o', .r = .{ "     ", "     ", " ### ", "#   #", "#   #", "#   #", " ### " } },
    .{ .c = 'p', .r = .{ "     ", "#### ", "#   #", "#   #", "#### ", "#    ", "#    " } },
    .{ .c = 'q', .r = .{ "     ", " ####", "#   #", "#   #", " ####", "    #", "    #" } },
    .{ .c = 'r', .r = .{ "     ", "     ", "# ## ", "##  #", "#    ", "#    ", "#    " } },
    .{ .c = 's', .r = .{ "     ", "     ", " ####", "#    ", " ### ", "    #", "#### " } },
    .{ .c = 't', .r = .{ " #   ", " #   ", "#### ", " #   ", " #   ", " #  #", "  ## " } },
    .{ .c = 'u', .r = .{ "     ", "     ", "#   #", "#   #", "#   #", "#  ##", " ## #" } },
    .{ .c = 'v', .r = .{ "     ", "     ", "#   #", "#   #", "#   #", " # # ", "  #  " } },
    .{ .c = 'w', .r = .{ "     ", "     ", "#   #", "# # #", "# # #", "# # #", " # # " } },
    .{ .c = 'x', .r = .{ "     ", "     ", "#   #", " # # ", "  #  ", " # # ", "#   #" } },
    .{ .c = 'y', .r = .{ "     ", "#   #", "#   #", "#   #", " ####", "    #", " ### " } },
    .{ .c = 'z', .r = .{ "     ", "     ", "#####", "   # ", "  #  ", " #   ", "#####" } },
};

/// Char → 5 column bytes, built once at comptime. Index 0 (and any undefined
/// char) is blank.
const TABLE: [128][GW]u8 = blk: {
    @setEvalBranchQuota(100_000);
    var t = [_][GW]u8{[_]u8{0} ** GW} ** 128;
    for (GLYPHS) |g| t[g.c] = pack(g.r);
    break :blk t;
};

/// Column bitmap for `c` (blank for chars outside the table).
pub fn cols(c: u8) [GW]u8 {
    return if (c < 128) TABLE[c] else TABLE[0];
}

/// A board-level silkscreen text label placed by the viewer's Text tool and
/// persisted in the layout sidecar (`SavedLayout.texts`). World-mm anchor,
/// quarter-turn rotation, board side, cap height in mm (the stroke font is
/// vector — `size` scales the 5x7 pixel pitch), and the string. Bottom-side
/// text mirrors on the silk layer so it reads from the board's bottom view,
/// the same convention as ref-des.
pub const BoardText = struct {
    x: f64,
    y: f64,
    /// Rotation in degrees; only 0/90/180/270 are meaningful.
    rot: f64 = 0,
    /// "top" or "bottom" — which silk layer the text lands on.
    bottom: bool = false,
    /// Cap height in mm (glyph is GH pixels tall, so pixel pitch = size / GH).
    size: f64 = 1.0,
    text: []const u8,
};

/// Default cap height (mm) for a new silkscreen text — matches the ~1 mm
/// ref-des height (GH * 0.15 mm pixel pitch), the KiCad stock legend size.
pub const DEFAULT_SIZE_MM: f64 = @as(f64, @floatFromInt(GH)) * 0.15;

/// One lit horizontal run in a glyph row: pixel columns [c0, c1] (inclusive)
/// are lit on row `r`. `c0 == c1` is a single lit pixel (a dot).
pub const Run = struct { r: u5, c0: u5, c1: u5 };

/// Enumerate the lit horizontal runs of `ch`'s glyph, calling `emit(Run)` for
/// each. The shared glyph→segment traversal both the Gerber stroker and the
/// PNG renderer use, so text renders identically across outputs. `E` is the
/// emit callback's error set (use `error{}` for an infallible callback).
pub fn glyphRuns(ch: u8, comptime E: type, ctx: anytype, emit: fn (@TypeOf(ctx), Run) E!void) E!void {
    const g = cols(ch);
    var r: u5 = 0;
    while (r < GH) : (r += 1) {
        const bit = @as(u8, 1) << @as(u3, @intCast(r));
        var c: u5 = 0;
        while (c < GW) {
            if (g[c] & bit == 0) {
                c += 1;
                continue;
            }
            var e = c;
            while (e + 1 < GW and g[e + 1] & bit != 0) e += 1;
            try emit(ctx, .{ .r = r, .c0 = c, .c1 = e });
            c = e + 1;
        }
    }
}

test "font packs a known glyph and leaves unknowns blank" {
    // 'T' has a full top bar (all 5 columns lit in row 0 → bit 0 set).
    var top_lit: u32 = 0;
    for (cols('T')) |col| {
        if (col & 1 != 0) top_lit += 1;
    }
    try std.testing.expectEqual(@as(u32, 5), top_lit);
    // 'T' has a single lit column down the middle on row 6 (the stem).
    try std.testing.expect(cols('T')[2] & (1 << 6) != 0);
    // Lowercase now has its own glyphs (not blank); space and truly undefined
    // chars still render blank.
    try std.testing.expect(!std.meta.eql([_]u8{0} ** GW, cols('a')));
    try std.testing.expectEqual([_]u8{0} ** GW, cols(' '));
    try std.testing.expectEqual([_]u8{0} ** GW, cols('\t'));
}

test "glyphRuns enumerates a glyph's lit horizontal runs" {
    const Counter = struct {
        n: usize = 0,
        top_run: bool = false,
        fn emit(self: *@This(), run: Run) error{}!void {
            self.n += 1;
            // 'T' row 0 is a full 5-wide bar → one run spanning cols 0..4.
            if (run.r == 0 and run.c0 == 0 and run.c1 == 4) self.top_run = true;
        }
    };
    var ctr = Counter{};
    try glyphRuns('T', error{}, &ctr, Counter.emit);
    try std.testing.expect(ctr.top_run);
    // 'T' = 5-wide top bar + a 1-wide stem on rows 1..6 → 7 runs total.
    try std.testing.expectEqual(@as(usize, 7), ctr.n);
    // A blank glyph emits nothing.
    var ctr2 = Counter{};
    try glyphRuns(' ', error{}, &ctr2, Counter.emit);
    try std.testing.expectEqual(@as(usize, 0), ctr2.n);
}
