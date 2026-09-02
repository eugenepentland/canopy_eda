//! The canonical UUID text form, written in exactly one place.
//!
//! Two generators feed it: `bom.generateUuid` (a random v4, minted once when a
//! part first enters the `.bom` sidecar) and `flat_netlist.uuidFromId` (a
//! name-based v5-style digest of an instance's stable 8-char id, recomputed on
//! every export). They differ in where the 16 bytes come from and in nothing
//! else — both stamp the RFC 4122 version nibble and variant bits into the
//! same two byte positions and render the same 8-4-4-4-12 lowercase hex.
//!
//! That rendering is the identity KiCad syncs on: a symbol UUID in the
//! schematic, a footprint UUID in the board, and the `.bom` row that ties them
//! together must be the same 36 characters or the round trip silently forks a
//! part into two. Two copies of the formatter could disagree by a byte index
//! or a case convention and produce exactly that, so there is one.

const std = @import("std");

/// RFC 4122 field offsets in the 16-byte layout. `version` holds the version
/// nibble in its high half; `variant` holds the two variant bits in its top
/// two bits.
const version_byte: usize = 6;
const variant_byte: usize = 8;

/// Which UUID this is. The value is the version nibble already shifted into
/// the high half of `version_byte`, which is how it is stamped.
pub const Version = enum(u8) {
    /// Random (or pseudo-random) — RFC 4122 §4.4.
    random_v4 = 0x40,
    /// Name-based, from a digest of a stable id — RFC 4122 §4.3 layout.
    name_v5 = 0x50,
};

/// Length of the canonical text form: 32 hex digits and 4 dashes.
pub const text_len: usize = 36;

/// Stamp `raw`'s version and variant fields and render the canonical
/// `xxxxxxxx-xxxx-Vxxx-yxxx-xxxxxxxxxxxx` text on `allocator`.
pub fn format(
    allocator: std.mem.Allocator,
    raw: [16]u8,
    version: Version,
) std.mem.Allocator.Error![]const u8 {
    var b = raw;
    b[version_byte] = (b[version_byte] & 0x0f) | @backingInt(version);
    b[variant_byte] = (b[variant_byte] & 0x3f) | 0x80;
    return std.fmt.allocPrint(
        allocator,
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}" ++
            "-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{
            b[0], b[1], b[2],  b[3],  b[4],  b[5],  b[6],  b[7],
            b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15],
        },
    );
}

// spec: bom - The canonical UUID text form stamps the version nibble and variant bits in one place
test "format stamps version and variant and renders the canonical shape" {
    const alloc = std.testing.allocator;
    var raw: [16]u8 = undefined;
    for (&raw, 0..) |*byte, i| byte.* = @intCast(i);

    const v4 = try format(alloc, raw, .random_v4);
    defer alloc.free(v4);
    try std.testing.expectEqualStrings("00010203-0405-4607-8809-0a0b0c0d0e0f", v4);

    const v5 = try format(alloc, raw, .name_v5);
    defer alloc.free(v5);
    try std.testing.expectEqualStrings("00010203-0405-5607-8809-0a0b0c0d0e0f", v5);

    try std.testing.expectEqual(text_len, v4.len);
}
