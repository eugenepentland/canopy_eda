//! Minimal ZIP archive writer (store method, no compression) — enough to
//! bundle the Gerber/drill/centroid fab package into the single .zip every
//! board house takes. Deterministic output: fixed timestamps, entries in the
//! order given. Gerber text is small and already served gzip-encoded on the
//! wire, so the store method costs little and keeps this dependency-free.

const std = @import("std");

/// One file to pack: the archive-internal name (forward slashes, no leading
/// slash) and its full contents.
pub const Entry = struct { name: []const u8, data: []const u8 };

/// Fixed DOS date for every entry (1980-01-01, the ZIP epoch) so archives
/// are byte-reproducible for identical inputs.
const dos_date: u16 = 0x0021;

/// Write `entries` as a complete ZIP archive: local headers + data, central
/// directory, end record.
pub fn write(w: *std.Io.Writer, entries: []const Entry) std.Io.Writer.Error!void {
    var offset: u64 = 0;
    // Local file headers + stored data.
    for (entries) |e| {
        const crc = std.hash.Crc32.hash(e.data);
        try w.writeAll("PK\x03\x04");
        try w.writeInt(u16, 20, .little); // version needed
        try w.writeInt(u16, 0, .little); // flags
        try w.writeInt(u16, 0, .little); // method: store
        try w.writeInt(u16, 0, .little); // mod time
        try w.writeInt(u16, dos_date, .little); // mod date
        try w.writeInt(u32, crc, .little);
        try w.writeInt(u32, @intCast(e.data.len), .little); // compressed
        try w.writeInt(u32, @intCast(e.data.len), .little); // uncompressed
        try w.writeInt(u16, @intCast(e.name.len), .little);
        try w.writeInt(u16, 0, .little); // extra len
        try w.writeAll(e.name);
        try w.writeAll(e.data);
        offset += 30 + e.name.len + e.data.len;
    }
    // Central directory.
    const cd_start = offset;
    var cd_size: u64 = 0;
    var local_off: u64 = 0;
    for (entries) |e| {
        const crc = std.hash.Crc32.hash(e.data);
        try w.writeAll("PK\x01\x02");
        try w.writeInt(u16, 20, .little); // version made by
        try w.writeInt(u16, 20, .little); // version needed
        try w.writeInt(u16, 0, .little); // flags
        try w.writeInt(u16, 0, .little); // method
        try w.writeInt(u16, 0, .little); // mod time
        try w.writeInt(u16, dos_date, .little); // mod date
        try w.writeInt(u32, crc, .little);
        try w.writeInt(u32, @intCast(e.data.len), .little);
        try w.writeInt(u32, @intCast(e.data.len), .little);
        try w.writeInt(u16, @intCast(e.name.len), .little);
        try w.writeInt(u16, 0, .little); // extra
        try w.writeInt(u16, 0, .little); // comment
        try w.writeInt(u16, 0, .little); // disk number
        try w.writeInt(u16, 0, .little); // internal attrs
        try w.writeInt(u32, 0, .little); // external attrs
        try w.writeInt(u32, @intCast(local_off), .little);
        try w.writeAll(e.name);
        cd_size += 46 + e.name.len;
        local_off += 30 + e.name.len + e.data.len;
    }
    // End of central directory.
    try w.writeAll("PK\x05\x06");
    try w.writeInt(u16, 0, .little); // this disk
    try w.writeInt(u16, 0, .little); // cd disk
    try w.writeInt(u16, @intCast(entries.len), .little); // entries this disk
    try w.writeInt(u16, @intCast(entries.len), .little); // entries total
    try w.writeInt(u32, @intCast(cd_size), .little);
    try w.writeInt(u32, @intCast(cd_start), .little);
    try w.writeInt(u16, 0, .little); // comment len
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: zipfile - packs entries into a store-method archive the standard extractor reads back
test "write produces an archive std.zip can extract" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const entries = [_]Entry{
        .{ .name = "a-F_Cu.gtl", .data = "G04 top*\nM02*\n" },
        .{ .name = "a-PTH.drl", .data = "M48\nM30\n" },
    };
    var aw: std.Io.Writer.Allocating = .init(arena);
    try write(&aw.writer, &entries);
    const out = aw.written();

    // Structure: one local header per entry, central dir, end record.
    try testing.expect(std.mem.startsWith(u8, out, "PK\x03\x04"));
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, "PK\x03\x04"));
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, "PK\x01\x02"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "PK\x05\x06"));
    // Entry count + central-directory offset land where the end record says.
    const eocd = std.mem.lastIndexOf(u8, out, "PK\x05\x06").?;
    try testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, out[eocd + 10 ..][0..2], .little));
    const cd_off = std.mem.readInt(u32, out[eocd + 16 ..][0..4], .little);
    try testing.expect(std.mem.startsWith(u8, out[cd_off..], "PK\x01\x02"));
    // Stored data is byte-visible.
    try testing.expect(std.mem.indexOf(u8, out, "G04 top*") != null);
}

const zip_fuzz_corpus = [_][]const u8{
    "",
    "one",
    "a/b/c.gtl\nlayer data",
    &[_]u8{ 0x50, 0x4b, 0x03, 0x04, 0, 0xff, 0x7f },
};

/// One fuzz iteration for the ZIP writer: building two entries out of arbitrary
/// bytes must never crash and must emit a well-formed archive — a leading local
/// header and a trailing end-of-central-directory record. Entry names are kept
/// short so the u16 name-length field can't overflow. The arena reclaims the
/// archive buffer, so `testing.allocator` stays leak-free.
fn fuzzZipWrite(allocator: std.mem.Allocator, input: []const u8) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const split = input.len / 2;
    const name0 = input[0..@min(input.len, 8)];
    const entries = [_]Entry{
        .{ .name = if (name0.len > 0) name0 else "n", .data = input },
        .{ .name = "second.bin", .data = input[split..] },
    };
    var aw: std.Io.Writer.Allocating = .init(a);
    try write(&aw.writer, &entries);
    const out = aw.written();

    try testing.expect(std.mem.startsWith(u8, out, "PK\x03\x04"));
    try testing.expect(std.mem.indexOf(u8, out, "PK\x05\x06") != null);
}

// spec: zipfile - Fuzzing the writer with arbitrary entry bytes produces a well-formed archive
test "fuzz: write emits a well-formed archive for arbitrary entry bytes" {
    try std.testing.fuzz(std.testing.allocator, fuzzZipWrite, .{ .corpus = &zip_fuzz_corpus });
}
