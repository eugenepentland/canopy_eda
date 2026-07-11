//! Minimal DEFLATE (fixed Huffman + LZ77) plus a gzip wrapper. Extracted from
//! the PNG encoder so HTTP response compression can reuse the same proven
//! bitstream. Pure Zig (std only). std's flate *compressor* is unusable in
//! 0.15.1 — the streaming `Compress` is a stub (`drain` panics; `endUnflushed`
//! loops forever on sub-window inputs), `Compress.Simple.finish` references a
//! non-existent `Container.writeFooter` and never feeds its checksum hasher,
//! and `BlockWriter` isn't exported — so we emit a single fixed-Huffman block
//! with hash-chain LZ77 matching. std's `Decompress` *is* complete, so the
//! bytes decode everywhere (browsers, `gzip -d`, the round-trip test below).

const std = @import("std");

/// Failure modes of the compressor: allocation for the match tables/output
/// buffer, and the underlying byte-writer's errors.
pub const Error = std.mem.Allocator.Error || std.Io.Writer.Error;

// RFC 1951 length/distance code tables (index 0 = symbol 257 / distance 0).
const len_base = [_]u16{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
const len_extra = [_]u3{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
const dist_base = [_]u16{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769 } ++
    [_]u16{ 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };
const dist_extra = [_]u4{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };
const max_match: usize = 258;
const max_dist: usize = 32768;
const max_chain: u32 = 128; // hash-chain probes per position (speed/ratio trade)

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
    var li: usize = len_base.len - 1;
    while (@as(usize, len_base[li]) > length) li -= 1;
    try emitLitLen(bw, @intCast(257 + li));
    try bw.writeBits(@intCast(length - len_base[li]), len_extra[li]);

    var di: usize = dist_base.len - 1;
    while (@as(usize, dist_base[di]) > distance) di -= 1;
    try bw.writeBits(bitRev(@intCast(di), 5), 5); // distance code: 5-bit fixed
    try bw.writeBits(@intCast(distance - dist_base[di]), dist_extra[di]);
}

fn hash3(d: []const u8, i: usize) u32 {
    return ((@as(u32, d[i]) << 10) ^ (@as(u32, d[i + 1]) << 5) ^ @as(u32, d[i + 2])) & 0x7FFF;
}

/// Write `data` as one final fixed-Huffman DEFLATE block with greedy LZ77
/// (hash-chain) matching. Correctness is checked by the round-trip tests.
///
/// Input-size limit: positions are stored in the `i32` hash chain (`head`/
/// `prev`), so `data.len` must be < 2 GiB (`maxInt(i32) + 1`). Realistic
/// inputs — PNG scanlines (≤ tens of MB at the canvas caps) and HTTP responses
/// — are far under that; the assert makes the bound explicit rather than
/// letting a 2 GiB input overflow the `@intCast` (panic in safe builds, UB in
/// ReleaseSmall).
fn deflateFixed(alloc: std.mem.Allocator, bw: *BitWriter, data: []const u8) Error!void {
    std.debug.assert(data.len <= std.math.maxInt(i32));
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
            const maxl = @min(max_match, data.len - i);
            var cand = head[hash3(data, i)];
            var chain: u32 = 0;
            while (cand >= 0 and chain < max_chain) : (chain += 1) {
                const cpos: usize = @intCast(cand);
                if (i - cpos > max_dist) break;
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

/// Compress `data` into a bare, byte-aligned DEFLATE stream (one final
/// fixed-Huffman block) owned by `alloc`. The caller wraps it with whatever
/// container framing it needs — a zlib header+Adler32 (the PNG encoder) or a
/// gzip header+CRC32+ISIZE (`gzip` below).
pub fn deflateRaw(alloc: std.mem.Allocator, data: []const u8) Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var bits = BitWriter{ .w = &out.writer };
    try deflateFixed(alloc, &bits, data);
    try bits.flushBits();
    return out.toOwnedSlice();
}

/// Compress `data` as a gzip stream (RFC 1952): a 10-byte header, one
/// fixed-Huffman DEFLATE block, the CRC-32 of the input, and the input size
/// (mod 2^32), both little-endian. The returned slice is owned by `alloc`.
pub fn gzip(alloc: std.mem.Allocator, data: []const u8) Error![]u8 {
    const raw = try deflateRaw(alloc, data);
    defer alloc.free(raw);

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    // Header: magic 1f 8b, CM=deflate(8), FLG=0, MTIME=0, XFL=0, OS=255(unknown).
    try w.writeAll(&[_]u8{ 0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff });
    try w.writeAll(raw);

    var crc = std.hash.Crc32.init();
    crc.update(data);
    var trailer: [8]u8 = undefined;
    std.mem.writeInt(u32, trailer[0..4], crc.final(), .little);
    std.mem.writeInt(u32, trailer[4..8], @truncate(data.len), .little);
    try w.writeAll(&trailer);

    return out.toOwnedSlice();
}

test "gzip round-trips through std flate Decompress" {
    const alloc = std.testing.allocator;
    const text =
        "The quick brown fox jumps over the lazy dog. " ++
        "The quick brown fox jumps over the lazy dog. " ++
        "The quick brown fox jumps over the lazy dog. " ++
        "Repetition compresses well; repetition compresses well; repetition compresses well.";
    const gz = try gzip(alloc, text);
    defer alloc.free(gz);

    // gzip magic + deflate method.
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x1f, 0x8b, 0x08 }, gz[0..3]);
    // Repetitive input must actually shrink.
    try std.testing.expect(gz.len < text.len);

    // Strip the 10-byte gzip header + 8-byte trailer and inflate the raw block.
    const raw_deflate = gz[10 .. gz.len - 8];
    var in: std.Io.Reader = .fixed(raw_deflate);
    var win: [std.compress.flate.max_window_len]u8 = undefined;
    var decomp = std.compress.flate.Decompress.init(&in, .raw, &win);
    const out = try decomp.reader.allocRemaining(alloc, .unlimited);
    defer alloc.free(out);
    try std.testing.expectEqualSlices(u8, text, out);

    // Trailer ISIZE matches the input length.
    try std.testing.expectEqual(@as(u32, @truncate(text.len)), std.mem.readInt(u32, gz[gz.len - 4 ..][0..4], .little));
}

test "gzip handles tiny and empty inputs" {
    const alloc = std.testing.allocator;
    for ([_][]const u8{ "", "a", "ab" }) |text| {
        const gz = try gzip(alloc, text);
        defer alloc.free(gz);
        try std.testing.expect(gz.len >= 18); // header + at least end-of-block byte + trailer
        const raw_deflate = gz[10 .. gz.len - 8];
        var in: std.Io.Reader = .fixed(raw_deflate);
        var win: [std.compress.flate.max_window_len]u8 = undefined;
        var decomp = std.compress.flate.Decompress.init(&in, .raw, &win);
        const out = try decomp.reader.allocRemaining(alloc, .unlimited);
        defer alloc.free(out);
        try std.testing.expectEqualSlices(u8, text, out);
    }
}
