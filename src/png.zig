//! Minimal PNG encoder — truecolor (RGB8), filter-0 scanlines, a single
//! zlib-deflated IDAT chunk. Pure Zig (std only), so the renderer can hand an
//! AI agent a real raster image without pulling in a C image library and
//! breaking the single-binary build. The board layout is flat-shaded geometry,
//! so filter-0 + deflate compresses the large constant-colour background well.

const std = @import("std");

/// 8-byte PNG file signature.
const SIGNATURE = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };

/// Errors `encodeRgb` (and downstream rasterizer encode paths) can produce.
pub const Error = std.mem.Allocator.Error || std.Io.Writer.Error;

/// Encode a row-major RGB8 buffer (`rgb.len == width*height*3`, no row padding)
/// as PNG bytes owned by `alloc`. Color type 2 (truecolor), 8-bit, no interlace.
pub fn encodeRgb(alloc: std.mem.Allocator, width: u32, height: u32, rgb: []const u8) Error![]u8 {
    const stride: usize = @as(usize, width) * 3;
    std.debug.assert(rgb.len == stride * height);

    // Filter each scanline with the PNG "Up" filter (type 2: cur − above): the
    // board's large flat background is identical row-to-row, so the deltas
    // collapse to runs of 0x00 that the DEFLATE pass then crushes.
    const filtered = try alloc.alloc(u8, (stride + 1) * height);
    defer alloc.free(filtered);
    var y: usize = 0;
    while (y < height) : (y += 1) {
        const row = filtered[y * (stride + 1) ..];
        row[0] = 2; // filter type: Up
        const cur = rgb[y * stride ..][0..stride];
        if (y == 0) {
            @memcpy(row[1 .. 1 + stride], cur);
        } else {
            const above = rgb[(y - 1) * stride ..][0..stride];
            for (0..stride) |i| row[1 + i] = cur[i] -% above[i];
        }
    }

    // Compress the filtered scanlines into a zlib stream ourselves. std's flate
    // *compressor* is unusable in 0.15.1 — the streaming `Compress` is a stub
    // (`drain` panics; `endUnflushed` loops forever on sub-window inputs),
    // `Compress.Simple.finish` references a non-existent `Container.writeFooter`
    // and never feeds its checksum hasher, and `BlockWriter` isn't exported. So
    // we emit a single fixed-Huffman DEFLATE block with LZ77 matching; the Up
    // filter leaves the background as long zero-runs that LZ77 collapses. (std's
    // `Decompress` *is* complete, so the bytes decode everywhere — see the test.)
    var zout: std.Io.Writer.Allocating = .init(alloc);
    defer zout.deinit();
    try zout.writer.writeAll(&[_]u8{ 0x78, 0x01 }); // zlib header: deflate, 32 KiB window
    var bits = BitWriter{ .w = &zout.writer };
    try deflateFixed(alloc, &bits, filtered);
    try bits.flushBits();
    var adler: [4]u8 = undefined;
    std.mem.writeInt(u32, &adler, std.hash.Adler32.hash(filtered), .big);
    try zout.writer.writeAll(&adler);

    // Assemble the chunk stream: signature, IHDR, IDAT, IEND.
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll(&SIGNATURE);

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 2; // colour type: truecolor RGB
    ihdr[10] = 0; // compression method: deflate
    ihdr[11] = 0; // filter method: adaptive (per-row; here always Up)
    ihdr[12] = 0; // interlace: none
    try writeChunk(w, "IHDR", &ihdr);
    try writeChunk(w, "IDAT", zout.written());
    try writeChunk(w, "IEND", &.{});

    return out.toOwnedSlice();
}

// ── Minimal DEFLATE (fixed Huffman + LZ77) ─────────────────────────────────
// RFC 1951 length/distance code tables (index 0 = symbol 257 / distance 0).
const LEN_BASE = [_]u16{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
const LEN_EXTRA = [_]u3{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
const DIST_BASE = [_]u16{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769 } ++
    [_]u16{ 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };
const DIST_EXTRA = [_]u4{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };
const MAX_MATCH: usize = 258;
const MAX_DIST: usize = 32768;
const MAX_CHAIN: u32 = 128; // hash-chain probes per position (speed/ratio trade)

/// LSB-first bit accumulator over a byte writer (DEFLATE bit order).
const BitWriter = struct {
    w: *std.Io.Writer,
    acc: u32 = 0,
    nbits: u6 = 0,

    /// Append the low `count` (≤16) bits of `value`, least-significant first.
    fn writeBits(self: *BitWriter, value: u32, count: u6) std.Io.Writer.Error!void {
        const masked = value & ((@as(u32, 1) << @intCast(count)) - 1);
        self.acc |= masked << @intCast(self.nbits);
        self.nbits += count;
        while (self.nbits >= 8) {
            try self.w.writeByte(@truncate(self.acc));
            self.acc >>= 8;
            self.nbits -= 8;
        }
    }

    /// Pad the partial final byte to a byte boundary.
    fn flushBits(self: *BitWriter) std.Io.Writer.Error!void {
        if (self.nbits > 0) {
            try self.w.writeByte(@truncate(self.acc));
            self.acc = 0;
            self.nbits = 0;
        }
    }
};

/// Reverse the low `len` bits of `code` (Huffman codes go out MSB-first, but the
/// bit writer is LSB-first, so codes are pre-reversed).
fn bitRev(code: u32, len: u6) u32 {
    var v = code;
    var r: u32 = 0;
    var k: u6 = 0;
    while (k < len) : (k += 1) {
        r = (r << 1) | (v & 1);
        v >>= 1;
    }
    return r;
}

/// Emit a literal/length symbol using the fixed Huffman code (RFC 1951 §3.2.6).
fn emitLitLen(bw: *BitWriter, sym: u32) std.Io.Writer.Error!void {
    var code: u32 = undefined;
    var len: u6 = undefined;
    if (sym <= 143) {
        code = 0x30 + sym;
        len = 8;
    } else if (sym <= 255) {
        code = 0x190 + (sym - 144);
        len = 9;
    } else if (sym <= 279) {
        code = sym - 256;
        len = 7;
    } else {
        code = 0xC0 + (sym - 280);
        len = 8;
    }
    try bw.writeBits(bitRev(code, len), len);
}

/// Emit an LZ77 (length, distance) back-reference in the fixed-Huffman alphabet.
fn emitMatch(bw: *BitWriter, length: usize, distance: usize) std.Io.Writer.Error!void {
    var li: usize = LEN_BASE.len - 1;
    while (@as(usize, LEN_BASE[li]) > length) li -= 1;
    try emitLitLen(bw, @intCast(257 + li));
    try bw.writeBits(@intCast(length - LEN_BASE[li]), LEN_EXTRA[li]);

    var di: usize = DIST_BASE.len - 1;
    while (@as(usize, DIST_BASE[di]) > distance) di -= 1;
    try bw.writeBits(bitRev(@intCast(di), 5), 5); // distance code: 5-bit fixed
    try bw.writeBits(@intCast(distance - DIST_BASE[di]), DIST_EXTRA[di]);
}

fn hash3(d: []const u8, i: usize) u32 {
    return ((@as(u32, d[i]) << 10) ^ (@as(u32, d[i + 1]) << 5) ^ @as(u32, d[i + 2])) & 0x7FFF;
}

/// Write `data` as one final fixed-Huffman DEFLATE block with greedy LZ77
/// (hash-chain) matching. Correctness is checked by the round-trip test.
fn deflateFixed(alloc: std.mem.Allocator, bw: *BitWriter, data: []const u8) !void {
    try bw.writeBits(1, 1); // BFINAL = 1
    try bw.writeBits(1, 2); // BTYPE = 01 (fixed Huffman)

    const head = try alloc.alloc(i32, 1 << 15);
    defer alloc.free(head);
    @memset(head, -1);
    const prev = try alloc.alloc(i32, @max(data.len, 1));
    defer alloc.free(prev);

    var i: usize = 0;
    while (i < data.len) {
        var best_len: usize = 0;
        var best_dist: usize = 0;
        if (i + 3 <= data.len) {
            const maxl = @min(MAX_MATCH, data.len - i);
            var cand = head[hash3(data, i)];
            var chain: u32 = 0;
            while (cand >= 0 and chain < MAX_CHAIN) : (chain += 1) {
                const cpos: usize = @intCast(cand);
                if (i - cpos > MAX_DIST) break;
                var l: usize = 0;
                while (l < maxl and data[cpos + l] == data[i + l]) l += 1;
                if (l > best_len) {
                    best_len = l;
                    best_dist = i - cpos;
                    if (l >= maxl) break;
                }
                cand = prev[cpos];
            }
        }
        const span = if (best_len >= 3) span: {
            try emitMatch(bw, best_len, best_dist);
            break :span best_len;
        } else span: {
            try emitLitLen(bw, data[i]);
            break :span 1;
        };
        // Insert hash entries for every position consumed, then advance.
        const end = i + span;
        while (i < end) : (i += 1) {
            if (i + 3 <= data.len) {
                const h = hash3(data, i);
                prev[i] = head[h];
                head[h] = @intCast(i);
            }
        }
    }
    try emitLitLen(bw, 256); // end-of-block
}

/// Emit one PNG chunk: `length` (4 BE) + `kind` (4 ASCII) + `data` + CRC32 of
/// `kind`+`data` (4 BE).
fn writeChunk(w: *std.Io.Writer, kind: *const [4]u8, data: []const u8) !void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(data.len), .big);
    try w.writeAll(&len);
    try w.writeAll(kind);
    try w.writeAll(data);

    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    var crcb: [4]u8 = undefined;
    std.mem.writeInt(u32, &crcb, crc.final(), .big);
    try w.writeAll(&crcb);
}

test "encodeRgb produces a decodable 2x2 PNG" {
    const alloc = std.testing.allocator;
    // 2x2: red, green / blue, white.
    const rgb = [_]u8{
        255, 0, 0,   0,   255, 0,
        0,   0, 255, 255, 255, 255,
    };
    const png = try encodeRgb(alloc, 2, 2, &rgb);
    defer alloc.free(png);

    try std.testing.expect(png.len > 8);
    try std.testing.expectEqualSlices(u8, &SIGNATURE, png[0..8]);
    // IHDR length (13) then "IHDR".
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 13 }, png[8..12]);
    try std.testing.expectEqualSlices(u8, "IHDR", png[12..16]);
    // Width/height encoded big-endian in the IHDR data.
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, png[16..20], .big));
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, png[20..24], .big));
    // Ends with an IEND chunk.
    try std.testing.expectEqualSlices(u8, "IEND", png[png.len - 8 .. png.len - 4]);

    // Round-trip: inflate the IDAT and reconstruct the Up filter, checking the
    // pixels decode back to the original (validates the dynamic-Huffman stream).
    try expectRoundTrip(alloc, png, 2, 2, &rgb);
}

test "encodeRgb round-trips and compresses a larger patterned image" {
    const alloc = std.testing.allocator;
    const w: u32 = 80;
    const h: u32 = 60;
    const buf = try alloc.alloc(u8, @as(usize, w) * h * 3);
    defer alloc.free(buf);
    // Flat dark background with a bright rectangle: after the Up filter this is
    // dominated by zero-runs (back-references) with a few literals at the edges.
    for (0..h) |y| {
        for (0..w) |x| {
            const o = (y * w + x) * 3;
            const inside = x >= 20 and x < 60 and y >= 15 and y < 45;
            const c: u8 = if (inside) 0xb0 else 0x0d;
            buf[o] = c;
            buf[o + 1] = c;
            buf[o + 2] = if (inside) 0x57 else 0x17;
        }
    }
    const png = try encodeRgb(alloc, w, h, buf);
    defer alloc.free(png);
    try std.testing.expectEqualSlices(u8, &SIGNATURE, png[0..8]);
    try expectRoundTrip(alloc, png, w, h, buf);
    // The matcher should crush this well under half the raw size.
    try std.testing.expect(png.len < @as(usize, w) * h * 3 / 2);
}

fn expectRoundTrip(alloc: std.mem.Allocator, png: []const u8, width: u32, height: u32, rgb: []const u8) !void {
    // Locate the IDAT payload (single chunk in our encoder).
    var i: usize = 8;
    var idat: []const u8 = &.{};
    while (i + 8 <= png.len) {
        const clen = std.mem.readInt(u32, png[i..][0..4], .big);
        const kind = png[i + 4 ..][0..4];
        const data = png[i + 8 ..][0..clen];
        if (std.mem.eql(u8, kind, "IDAT")) idat = data;
        i += 12 + clen;
    }
    try std.testing.expect(idat.len > 0);

    var in: std.Io.Reader = .fixed(idat);
    var win: [std.compress.flate.max_window_len]u8 = undefined;
    var decomp = std.compress.flate.Decompress.init(&in, .zlib, &win);
    const stride: usize = @as(usize, width) * 3;
    const raw = try decomp.reader.allocRemaining(alloc, .unlimited);
    defer alloc.free(raw);
    try std.testing.expectEqual((stride + 1) * height, raw.len);
    // Reverse the Up filter (type 2) and compare to the original pixels.
    const recon = try alloc.alloc(u8, stride * height);
    defer alloc.free(recon);
    var y: usize = 0;
    while (y < height) : (y += 1) {
        try std.testing.expectEqual(@as(u8, 2), raw[y * (stride + 1)]);
        const drow = raw[y * (stride + 1) + 1 ..][0..stride];
        for (0..stride) |k| {
            const above: u8 = if (y == 0) 0 else recon[(y - 1) * stride + k];
            recon[y * stride + k] = drow[k] +% above;
        }
    }
    try std.testing.expectEqualSlices(u8, rgb, recon);
}
