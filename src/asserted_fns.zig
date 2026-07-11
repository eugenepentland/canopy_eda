//! Shared builder for the (ref_des|pin) -> asserted-function map consumed by
//! both renderers (`render_html.zig`, `render_json.zig`). A pin's
//! `asserted_fns` come from `(verifies …)` sign-offs; multiple functions on
//! one pin are joined with ", ". Keys are allocator-owned `"{ref_des}|{pin}"`.

const std = @import("std");
const env_mod = @import("eval/env.zig");
const DesignBlock = env_mod.DesignBlock;
const Allocator = std.mem.Allocator;

const Map = std.StringHashMapUnmanaged([]const u8);

/// Build the (ref_des|pin) -> asserted-function map for an entire design,
/// recursing through sub-blocks. Keys and joined values are owned by `allocator`.
pub fn buildMap(allocator: Allocator, block: *const DesignBlock) Allocator.Error!Map {
    var map: Map = .empty;
    try appendFromBlock(allocator, &map, block);
    return map;
}

fn appendFromBlock(allocator: Allocator, map: *Map, block: *const DesignBlock) Allocator.Error!void {
    for (block.nets) |net| {
        for (net.pins) |p| {
            if (p.asserted_fns.len == 0) continue;
            const key = std.fmt.allocPrint(allocator, "{s}|{s}", .{ p.ref_des, p.pin }) catch continue;
            const joined = join(allocator, p.asserted_fns) orelse continue;
            try map.put(allocator, key, joined);
        }
    }
    for (block.sub_blocks) |sb| try appendFromBlock(allocator, map, sb.block);
}

fn join(allocator: Allocator, fns: []const []const u8) ?[]const u8 {
    if (fns.len == 0) return null;
    if (fns.len == 1) return fns[0];
    var buf: std.ArrayList(u8) = .empty;
    const w = buf.writer(allocator);
    for (fns, 0..) |f, i| {
        if (i > 0) w.writeAll(", ") catch return null;
        w.writeAll(f) catch return null;
    }
    return buf.toOwnedSlice(allocator) catch null;
}
