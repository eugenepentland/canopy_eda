const std = @import("std");

const via_prefix = "via-";

fn hashFloat(hash: *std.hash.Wyhash, value: f64) void {
    hash.update(std.mem.asBytes(&value));
}

/// Stable ID for a legacy via that has no persisted identity yet.
pub fn legacyVia(
    via: anytype,
    ordinal: usize,
    buf: *[via_prefix.len + 16]u8,
) []const u8 {
    var hash = std.hash.Wyhash.init(0x5649415f49445f5f);
    hashFloat(&hash, via.x);
    hashFloat(&hash, via.y);
    hashFloat(&hash, via.d);
    hashFloat(&hash, via.drill);
    hash.update(via.net);
    const has_span: u8 = @intFromBool(via.s != null);
    hash.update(std.mem.asBytes(&has_span));
    if (via.s) |layers| hash.update(&layers);
    const stable_ordinal: u64 = @intCast(ordinal);
    hash.update(std.mem.asBytes(&stable_ordinal));
    return std.fmt.bufPrint(buf, via_prefix ++ "{x:0>16}", .{hash.final()}) catch via_prefix ++ "0000000000000000";
}
