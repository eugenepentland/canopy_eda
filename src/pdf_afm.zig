//! Base-14 font metrics and WinAnsi text encoding for the PDF writer
//! (`src/pdf.zig`). Two concerns live here because they are inseparable: a
//! glyph's advance width is only defined once the text has been mapped into
//! the byte encoding the PDF font resource declares, so measuring and encoding
//! must walk the same table.
//!
//! Only the four base-14 faces netlisp needs are covered — `Courier` /
//! `Courier-Bold` (fixed 600/1000 em, which makes schematic anchor math exact)
//! and `Helvetica` / `Helvetica-Bold` (Adobe AFM width tables, transcribed
//! below indexed by WinAnsi code). Base-14 fonts are built into every PDF
//! reader, so nothing is embedded and no font file ships with the binary.
//!
//! Encoding is `WinAnsiEncoding`: ASCII and the Latin-1 upper half map
//! straight through (so µ, °, ± survive), the CP1252 0x80–0x9F block maps from
//! its Unicode originals, a small fallback table spells out glyphs WinAnsi has
//! no code for (Ω → `ohm`), and anything left over becomes `?`. Malformed
//! UTF-8 is decoded leniently — a bad byte yields `?` and the walk advances —
//! so untrusted design text can never make the writer raise or loop.

const std = @import("std");

/// The base-14 faces the PDF writer can select. `Courier*` is the monospace
/// face used for schematic text; `Helvetica*` is the prose/table face.
pub const Font = enum { courier, courier_bold, helvetica, helvetica_bold };

/// Courier and Courier-Bold advance every glyph by this many 1/1000 em units.
const courier_width: u16 = 600;

/// Codepoint substituted for anything the encoding cannot represent.
const unmappable: u8 = '?';

/// Sentinel codepoint produced by the lenient UTF-8 decoder for a malformed
/// sequence. Above the Unicode maximum, so it always falls through to
/// `unmappable` without a separate branch.
const bad_codepoint: u32 = 0xFFFF_FFFF;

/// Advance width of `s` in points when set in `font` at `size`, measured over
/// the same WinAnsi bytes `encodeWinAnsi` would produce (so a fallback
/// expansion such as `Ω` → `ohm` is measured as three glyphs, and text-anchor
/// math agrees with what the page actually draws). Allocation-free.
pub fn textWidth(font: Font, size: f64, s: []const u8) f64 {
    var total: u64 = 0;
    var i: usize = 0;
    while (i < s.len) {
        const d = decodeAt(s[i..]);
        i += d.len;
        const m = mapCodepoint(d.cp);
        for (m.bytes[0..m.len]) |b| total += glyphWidth(font, b);
    }
    return emWidth(total, size);
}

/// Advance width in points of already-encoded WinAnsi `bytes`. The page's text
/// operator encodes once and measures with this, avoiding a second encode.
pub fn widthOfEncoded(font: Font, size: f64, bytes: []const u8) f64 {
    var total: u64 = 0;
    for (bytes) |b| total += glyphWidth(font, b);
    return emWidth(total, size);
}

/// Convert an accumulated 1/1000-em advance to points at `size`.
fn emWidth(total: u64, size: f64) f64 {
    return @as(f64, @floatFromInt(total)) * size / 1000.0;
}

/// Encode `s` (UTF-8, possibly malformed) as WinAnsi bytes owned by `gpa`.
pub fn encodeWinAnsi(gpa: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < s.len) {
        const d = decodeAt(s[i..]);
        i += d.len;
        const m = mapCodepoint(d.cp);
        try out.appendSlice(gpa, m.bytes[0..m.len]);
    }
    return out.toOwnedSlice(gpa);
}

/// Advance width, in 1/1000 em, of the glyph WinAnsi code `code` selects.
/// Codes WinAnsi leaves undefined measure 0 for the Helvetica faces; the
/// encoder never emits them, so the value is unobservable in output.
fn glyphWidth(font: Font, code: u8) u16 {
    return switch (font) {
        .courier, .courier_bold => courier_width,
        .helvetica => helvetica_widths[code],
        .helvetica_bold => helvetica_bold_widths[code],
    };
}

/// One codepoint's WinAnsi expansion: 1 byte for a mapped glyph, or up to 4
/// for a spelled-out fallback.
const Mapped = struct { bytes: [4]u8, len: u8 };

/// A codepoint WinAnsi has no code for, spelled out in ASCII instead.
const Fallback = struct { cp: u32, text: []const u8 };

/// Glyphs the schematic/review emitters use that WinAnsi cannot encode. The
/// table is consulted BEFORE the direct maps, so an entry here always wins —
/// that is deliberate for `×`, which keeps ref-des captions ("sub-block x7")
/// pure ASCII regardless of the reader's glyph coverage.
const fallbacks = [_]Fallback{
    .{ .cp = 0x03A9, .text = "ohm" }, // GREEK CAPITAL LETTER OMEGA
    .{ .cp = 0x2126, .text = "ohm" }, // OHM SIGN
    .{ .cp = 0x2190, .text = "<-" }, // LEFTWARDS ARROW
    .{ .cp = 0x2192, .text = "->" }, // RIGHTWARDS ARROW
    .{ .cp = 0x2194, .text = "<->" }, // LEFT RIGHT ARROW
    .{ .cp = 0x00D7, .text = "x" }, // MULTIPLICATION SIGN
    .{ .cp = 0x2264, .text = "<=" }, // LESS-THAN OR EQUAL TO
    .{ .cp = 0x2265, .text = ">=" }, // GREATER-THAN OR EQUAL TO
    .{ .cp = 0x2260, .text = "!=" }, // NOT EQUAL TO
    .{ .cp = 0x2248, .text = "~" }, // ALMOST EQUAL TO
    .{ .cp = 0x2713, .text = "OK" }, // CHECK MARK
    .{ .cp = 0x2717, .text = "X" }, // BALLOT X
};

/// Unicode originals of the CP1252 0x80–0x9F block, in code order. The five
/// codes WinAnsi leaves undefined (0x81, 0x8D, 0x8F, 0x90, 0x9D) hold 0.
const cp1252_high = [_]u32{
    0x20AC, 0,      0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
    0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0,      0x017D, 0,
    0,      0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
    0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0,      0x017E, 0x0178,
};

/// Wrap a single WinAnsi byte as a `Mapped`.
fn oneByte(b: u8) Mapped {
    return .{ .bytes = .{ b, 0, 0, 0 }, .len = 1 };
}

/// Wrap an ASCII fallback string (≤4 bytes) as a `Mapped`.
fn manyBytes(text: []const u8) Mapped {
    var m: Mapped = .{ .bytes = .{ 0, 0, 0, 0 }, .len = @intCast(text.len) };
    @memcpy(m.bytes[0..text.len], text);
    return m;
}

/// Map one Unicode codepoint to WinAnsi bytes: fallback table, then printable
/// ASCII, then the CP1252 0x80–0x9F block, then Latin-1 0xA0–0xFF, else `?`.
fn mapCodepoint(cp: u32) Mapped {
    for (fallbacks) |f| {
        if (f.cp == cp) return manyBytes(f.text);
    }
    if (cp >= 0x20 and cp < 0x7F) return oneByte(@intCast(cp));
    for (cp1252_high, 0..) |orig, i| {
        if (orig != 0 and orig == cp) return oneByte(@intCast(0x80 + i));
    }
    if (cp >= 0xA0 and cp <= 0xFF) return oneByte(@intCast(cp));
    return oneByte(unmappable);
}

/// One decoded UTF-8 scalar and how many input bytes it consumed. `len` is
/// never 0, so a decode loop always advances.
const Decoded = struct { cp: u32, len: usize };

/// Lenient UTF-8 decode of the scalar starting at `bytes[0]`. A malformed
/// lead byte, a truncated sequence, a bad continuation byte, or an
/// out-of-range scalar all yield `bad_codepoint` and consume exactly one byte.
fn decodeAt(bytes: []const u8) Decoded {
    const b0 = bytes[0];
    if (b0 < 0x80) return .{ .cp = b0, .len = 1 };
    const n: usize = if (b0 & 0xE0 == 0xC0) 2 else if (b0 & 0xF0 == 0xE0) 3 else if (b0 & 0xF8 == 0xF0) 4 else 0;
    if (n == 0 or bytes.len < n) return .{ .cp = bad_codepoint, .len = 1 };
    var cp: u32 = switch (n) {
        2 => b0 & 0x1F,
        3 => b0 & 0x0F,
        else => b0 & 0x07,
    };
    for (bytes[1..n]) |b| {
        if (b & 0xC0 != 0x80) return .{ .cp = bad_codepoint, .len = 1 };
        cp = (cp << 6) | @as(u32, b & 0x3F);
    }
    if (cp > 0x10FFFF) return .{ .cp = bad_codepoint, .len = 1 };
    return .{ .cp = cp, .len = n };
}

// THIRD-PARTY DATA — the two tables below are transcribed from Adobe's Core
// 14 AFM files (`Helvetica.afm` and `Helvetica-Bold.afm`, AFM 4.1, 1997):
//
//   Copyright (c) 1985, 1987, 1989, 1990, 1997 Adobe Systems Incorporated.
//   All Rights Reserved.
//
// Adobe's redistribution notice, reproduced verbatim from `MustRead.html` in
// that distribution, and not to be modified:
//
//   This file and the 14 PostScript(R) AFM files it accompanies may be used,
//   copied, and distributed for any purpose and without charge, with or
//   without modification, provided that all copyright notices are retained;
//   that the AFM files are not distributed without this file; that all
//   modifications to this file or any of the AFM files are prominently noted
//   in the modified file(s); and that this paragraph is not modified. Adobe
//   Systems has no responsibility or obligation to support the use of the AFM
//   files.
//
// Modification, prominently noted as that notice requires: no AFM file is
// present in this repository. The advance widths were re-indexed from AFM
// glyph names to WinAnsi codes and written as the two `[256]u16` arrays
// below; nothing else of the AFM files was taken, and no font program is
// embedded in any PDF this writer produces. See THIRD_PARTY_NOTICES.md.

/// Adobe AFM advance widths for `Helvetica`, indexed by WinAnsi code
/// (1/1000 em). Zero marks a code WinAnsi leaves undefined.
const helvetica_widths = [256]u16{
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 0x00
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 0x10
    278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, 278, 278, // 0x20
    556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 278, 278, 584, 584, 584, 556, // 0x30
    1015, 667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667, 556, 833, 722, 778, // 0x40
    667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 278, 278, 278, 469, 556, // 0x50
    333, 556, 556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833, 556, 556, // 0x60
    556, 556, 333, 500, 278, 556, 500, 722, 500, 500, 500, 334, 260, 334, 584, 0, // 0x70
    556, 0, 222, 556, 333, 1000, 556, 556, 333, 1000, 667, 333, 1000, 0, 611, 0, // 0x80
    0, 222, 222, 333, 333, 350, 556, 1000, 333, 1000, 500, 333, 944, 0, 500, 667, // 0x90
    278, 333, 556, 556, 556, 556, 260, 556, 333, 737, 370, 556, 584, 333, 737, 333, // 0xA0
    400, 584, 333, 333, 333, 556, 537, 278, 333, 333, 365, 556, 834, 834, 834, 611, // 0xB0
    667, 667, 667, 667, 667, 667, 1000, 722, 667, 667, 667, 667, 278, 278, 278, 278, // 0xC0
    722, 722, 778, 778, 778, 778, 778, 584, 778, 722, 722, 722, 722, 667, 667, 611, // 0xD0
    556, 556, 556, 556, 556, 556, 889, 500, 556, 556, 556, 556, 278, 278, 278, 278, // 0xE0
    556, 556, 556, 556, 556, 556, 556, 584, 611, 556, 556, 556, 556, 500, 556, 500, // 0xF0
};

/// Adobe AFM advance widths for `Helvetica-Bold`, indexed by WinAnsi code.
const helvetica_bold_widths = [256]u16{
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 0x00
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 0x10
    278, 333, 474, 556, 556, 889, 722, 238, 333, 333, 389, 584, 278, 333, 278, 278, // 0x20
    556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 333, 333, 584, 584, 584, 611, // 0x30
    975, 722, 722, 722, 722, 667, 611, 778, 722, 278, 556, 722, 611, 833, 722, 778, // 0x40
    667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 333, 278, 333, 584, 556, // 0x50
    333, 556, 611, 556, 611, 556, 333, 611, 611, 278, 278, 556, 278, 889, 611, 611, // 0x60
    611, 611, 389, 556, 333, 611, 556, 778, 556, 556, 500, 389, 280, 389, 584, 0, // 0x70
    556, 0, 278, 556, 500, 1000, 556, 556, 333, 1000, 667, 333, 1000, 0, 611, 0, // 0x80
    0, 278, 278, 500, 500, 350, 556, 1000, 333, 1000, 556, 333, 944, 0, 500, 667, // 0x90
    278, 333, 556, 556, 556, 556, 280, 556, 333, 737, 370, 556, 584, 333, 737, 333, // 0xA0
    400, 584, 333, 333, 333, 611, 556, 278, 333, 333, 365, 556, 834, 834, 834, 611, // 0xB0
    722, 722, 722, 722, 722, 722, 1000, 722, 667, 667, 667, 667, 278, 278, 278, 278, // 0xC0
    722, 722, 778, 778, 778, 778, 778, 584, 778, 722, 722, 722, 722, 667, 667, 611, // 0xD0
    556, 556, 556, 556, 556, 556, 889, 556, 556, 556, 556, 556, 278, 278, 278, 278, // 0xE0
    611, 611, 611, 611, 611, 611, 611, 584, 611, 611, 611, 611, 611, 556, 611, 556, // 0xF0
};

test "pdf afm: encodeWinAnsi maps Latin-1 directly and spells out fallbacks" {
    const alloc = std.testing.allocator;
    const enc = try encodeWinAnsi(alloc, "µ° ±10\u{03A9}");
    defer alloc.free(enc);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xB5, 0xB0, ' ', 0xB1, '1', '0', 'o', 'h', 'm' }, enc);
}

test "pdf afm: textWidth measures the encoded expansion, not the input codepoints" {
    // Courier is fixed-pitch: "ohm" is three glyphs even though the source is
    // a single Ω codepoint.
    try std.testing.expectApproxEqAbs(
        @as(f64, 3 * 600.0 * 10.0 / 1000.0),
        textWidth(.courier, 10, "\u{03A9}"),
        1e-9,
    );
}
