//! Minimal PNG encoder — truecolor (RGB8), filter-0 scanlines, a single
//! zlib-deflated IDAT chunk. Pure Zig (std only), so the renderer can hand an
//! AI agent a real raster image without pulling in a C image library and
//! breaking the single-binary build. The board layout is flat-shaded geometry,
//! so filter-0 + deflate compresses the large constant-colour background well.

const std = @import("std");
const deflate = @import("deflate.zig");

/// 8-byte PNG file signature.
const png_signature = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };

/// Errors `encodeRgb` (and downstream rasterizer encode paths) can produce.
/// `EmptyImage` guards a degenerate 0×N / N×0 canvas — the IHDR spec forbids a
/// zero dimension and decoders reject such a file, so reject it at the source
/// (a pathological aspect ratio can round a computed board dimension to 0).
pub const Error = std.mem.Allocator.Error || std.Io.Writer.Error || error{EmptyImage};

/// Encode a row-major RGB8 buffer (`rgb.len == width*height*3`, no row padding)
/// as PNG bytes owned by `alloc`. Color type 2 (truecolor), 8-bit, no interlace.
pub fn encodeRgb(alloc: std.mem.Allocator, width: u32, height: u32, rgb: []const u8) Error![]u8 {
    if (width == 0 or height == 0) return error.EmptyImage;
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
    const raw_deflate = try deflate.deflateRaw(alloc, filtered);
    defer alloc.free(raw_deflate);
    var zout: std.Io.Writer.Allocating = .init(alloc);
    defer zout.deinit();
    try zout.writer.writeAll(&[_]u8{ 0x78, 0x01 }); // zlib header: deflate, 32 KiB window
    try zout.writer.writeAll(raw_deflate);
    var adler: [4]u8 = undefined;
    std.mem.writeInt(u32, &adler, std.hash.Adler32.hash(filtered), .big);
    try zout.writer.writeAll(&adler);

    // Assemble the chunk stream: signature, IHDR, IDAT, IEND.
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll(&png_signature);

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

/// Emit one PNG chunk: `length` (4 BE) + `kind` (4 ASCII) + `data` + CRC32 of
/// `kind`+`data` (4 BE).
fn writeChunk(w: *std.Io.Writer, kind: *const [4]u8, data: []const u8) !void {
    // A PNG chunk length is a u32; the largest chunk we emit (IDAT) is bounded
    // by the canvas caps, far under 4 GiB. Assert it so the `@intCast` below is
    // a documented invariant rather than a silent panic/UB on a giant buffer.
    std.debug.assert(data.len <= std.math.maxInt(u32));
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
    try std.testing.expectEqualSlices(u8, &png_signature, png[0..8]);
    // IHDR length (13) then "IHDR".
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 13 }, png[8..12]);
    try std.testing.expectEqualSlices(u8, "IHDR", png[12..16]);
    // Width/height encoded big-endian in the IHDR data.
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, png[16..20], .big));
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, png[20..24], .big));
    // Ends with an IEND chunk.
    try std.testing.expectEqualSlices(u8, "IEND", png[png.len - 8 .. png.len - 4]);

    // Round-trip: inflate the IDAT and reconstruct the Up filter, checking the
    // pixels decode back to the original (validates the fixed-Huffman stream).
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
    try std.testing.expectEqualSlices(u8, &png_signature, png[0..8]);
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
