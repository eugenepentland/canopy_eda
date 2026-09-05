//! Extract the text indexed by `list_library` without making the main CLI
//! dispatcher own component/module file parsing details.
const std = @import("std");
const stdlib = @import("../stdlib.zig");
const module_metadata = @import("../module_metadata.zig");
const lib_limits = @import("../lib_limits.zig");

/// Return allocator-owned searchable text for a component or module source.
/// `path` is whatever the listing resolved — a real filename, or a bundled
/// standard-library path, which `readPath` serves out of the binary.
pub fn extract(allocator: std.mem.Allocator, path: []const u8, sub: []const u8) ?[]const u8 {
    const src = stdlib.readPath(allocator, path, lib_limits.max_lib_file_bytes) orelse return null;
    defer allocator.free(src);
    if (std.mem.eql(u8, sub, "modules")) {
        return module_metadata.searchDescription(allocator, src);
    }
    const marker = "(description \"";
    const idx = std.mem.indexOf(u8, src, marker) orelse return null;
    const start = idx + marker.len;
    const end = std.mem.indexOfScalarPos(u8, src, start, '\"') orelse return null;
    return allocator.dupe(u8, src[start..end]) catch null;
}
