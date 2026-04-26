const std = @import("std");
const infra_fs = @import("infra/fs.zig");
const env_mod = @import("eval/env.zig");
const DesignBlock = env_mod.DesignBlock;

/// Emit a JSON sidecar listing every `sub-block` instance in the design block
/// tree along with the ordered refs of the components inside it. Used by
/// `pcb_update.py` to detect identical module instances for one-shot layout
/// replication.
///
/// Schema:
/// ```
/// {
///   "instances": [
///     {
///       "path": "adc1",
///       "module": "AD7380-4 Channel 1",
///       "refs": ["adc1/U14", "adc1/C136", ...]
///     },
///     ...
///   ]
/// }
/// ```
///
/// `path` is the sub-block name as declared in the parent (e.g., "adc1").
/// `module` is the inner design-block name (the `defmodule`'s output).
/// Module identity is matched by `module` (same name → replication candidate).
/// `refs` is in declaration order — identical across sibling instances of the
/// same module, so position-based matching on the Python side works.
/// Returns the modules JSON as an owned string. Caller frees.
pub fn buildModulesJson(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeAll("{\n  \"instances\": [\n");
    var first = true;
    try emitSubBlocks(allocator, block, "", w, &first);
    try w.writeAll("\n  ]\n}\n");

    return buf.toOwnedSlice(allocator);
}

/// Build the modules sidecar via `buildModulesJson` and write it to disk
/// at `out_path`. The KiCad `pcb_update.py` plugin reads this file to spot
/// repeated sub-block instances and replicate their layout in one shot.
pub fn writeModulesJson(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    out_path: []const u8,
) !void {
    const json = try buildModulesJson(allocator, block);
    defer allocator.free(json);

    const file = try infra_fs.cwd().createFile(out_path, .{});
    defer file.close();
    try file.writeAll(json);
}

fn emitSubBlocks(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    prefix: []const u8,
    w: anytype,
    first: *bool,
) !void {
    for (block.sub_blocks) |sb| {
        const sub_path = if (prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, sb.name })
        else
            try allocator.dupe(u8, sb.name);
        defer allocator.free(sub_path);

        if (!first.*) try w.writeAll(",\n");
        first.* = false;

        try w.writeAll("    {");
        try w.print("\"path\": \"{s}\", ", .{sub_path});
        try w.print("\"module\": \"{s}\", ", .{sb.block.name});
        try w.writeAll("\"refs\": [");

        var ref_first = true;
        try collectRefs(allocator, sb.block, sub_path, w, &ref_first);

        try w.writeAll("]}");

        // Recurse into nested sub-blocks (each with its own entry).
        try emitSubBlocks(allocator, sb.block, sub_path, w, first);
    }
}

fn collectRefs(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    prefix: []const u8,
    w: anytype,
    first: *bool,
) !void {
    for (block.instances) |inst| {
        if (!first.*) try w.writeAll(", ");
        first.* = false;
        try w.print("\"{s}/{s}\"", .{ prefix, inst.ref_des });
    }
    for (block.sub_blocks) |sb| {
        const sub_prefix = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, sb.name });
        defer allocator.free(sub_prefix);
        try collectRefs(allocator, sb.block, sub_prefix, w, first);
    }
}
