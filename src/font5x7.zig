//! A 5x7 bitmap font for PCB-layout PNG labels (ref-designators, net names,
//! captions). Glyphs are authored as visual ASCII-art grids — each row is a
//! 5-char string drawn with '#' (lit) and ' ' (clear) — and packed to
//! column-major bytes at comptime, so the source reads as the rendered shape
//! and is verifiable by eye. Covers uppercase A-Z, digits, and the punctuation
//! that appears in ref-des / net names; the renderer uppercases text before
//! drawing, so lowercase need not be defined (unknown chars render blank).

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

test "font packs a known glyph and leaves unknowns blank" {
    // 'T' has a full top bar (all 5 columns lit in row 0 → bit 0 set).
    var top_lit: u32 = 0;
    for (cols('T')) |col| {
        if (col & 1 != 0) top_lit += 1;
    }
    try std.testing.expectEqual(@as(u32, 5), top_lit);
    // 'T' has a single lit column down the middle on row 6 (the stem).
    try std.testing.expect(cols('T')[2] & (1 << 6) != 0);
    // Undefined chars (here lowercase) render blank.
    try std.testing.expectEqual([_]u8{0} ** GW, cols('a'));
}
