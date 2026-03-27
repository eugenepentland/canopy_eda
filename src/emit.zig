const std = @import("std");
const env_mod = @import("eval/env.zig");
const DesignBlock = env_mod.DesignBlock;
const Instance = env_mod.Instance;
const Net = env_mod.Net;
const Port = env_mod.Port;
const SubBlock = env_mod.SubBlock;

/// Emit a resolved design as an S-expression string.
/// Flattens hierarchy with / prefixed ref-des.
pub fn emitResolved(allocator: std.mem.Allocator, block: *const DesignBlock) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeAll("(resolved-design ");
    try writeString(w, block.name);

    // Instances (flattened)
    try w.writeAll("\n\n  (instances");
    try emitInstances(w, block, "");
    try w.writeByte(')');

    // Nets (flattened)
    try w.writeAll("\n\n  (nets");
    try emitNets(w, block, "");
    try w.writeByte(')');

    // Ports (flattened)
    if (block.ports.len > 0 or block.sub_blocks.len > 0) {
        try w.writeAll("\n\n  (ports");
        try emitPorts(w, block, "");
        try w.writeByte(')');
    }

    // Hierarchy
    if (block.sub_blocks.len > 0) {
        try w.writeAll("\n\n  (hierarchy");
        try emitHierarchy(w, block);
        try w.writeByte(')');
    }

    // Notes (flattened)
    if (hasNotes(block)) {
        try w.writeAll("\n\n  (notes");
        try emitNotes(w, block, "");
        try w.writeByte(')');
    }

    try w.writeAll(")\n");
    return buf.toOwnedSlice(allocator);
}

fn emitInstances(w: anytype, block: *const DesignBlock, prefix: []const u8) !void {
    for (block.instances) |inst| {
        try w.writeAll("\n    (instance ");
        try writePrefixedString(w, prefix, inst.ref_des);
        try w.writeByte(' ');
        try writeString(w, inst.component);
        try w.writeByte(' ');
        try writeString(w, inst.value);
        try w.writeAll("\n      (footprint ");
        try writeString(w, inst.footprint);
        try w.writeAll(")\n      (symbol ");
        try writeString(w, inst.symbol);
        try w.writeAll("))");
    }
    for (block.sub_blocks) |sb| {
        try emitInstances(w, sb.block, try prefixStr(w, prefix, sb.name));
    }
}

fn emitNets(w: anytype, block: *const DesignBlock, prefix: []const u8) !void {
    for (block.nets) |net| {
        try w.writeAll("\n    (net ");
        try writePrefixedString(w, prefix, net.name);
        for (net.pins) |pin| {
            try w.writeAll("\n      (pin ");
            try writePrefixedString(w, prefix, pin.ref_des);
            try w.print(" {d})", .{pin.pin});
        }
        try w.writeByte(')');
    }
    for (block.sub_blocks) |sb| {
        try emitNets(w, sb.block, try prefixStr(w, prefix, sb.name));
    }
}

fn emitPorts(w: anytype, block: *const DesignBlock, prefix: []const u8) !void {
    for (block.ports) |port| {
        try w.writeAll("\n    (port ");
        try writePrefixedString(w, prefix, port.name);
        try w.writeByte(' ');
        try writePrefixedString(w, prefix, port.net);
        try w.print(" {s}", .{port.direction});
        if (port.rated_min != null and port.rated_max != null) {
            try w.print(" (rated {d:.1} {d:.1})", .{ port.rated_min.?, port.rated_max.? });
        }
        try w.writeByte(')');
    }
    for (block.sub_blocks) |sb| {
        try emitPorts(w, sb.block, try prefixStr(w, prefix, sb.name));
    }
}

fn emitHierarchy(w: anytype, block: *const DesignBlock) !void {
    for (block.sub_blocks) |sb| {
        try w.writeAll("\n    (block ");
        try writeString(w, sb.name);
        try w.writeByte(' ');
        try writeString(w, sb.block.name);
        try w.writeAll("\n      (children");
        for (sb.block.instances) |inst| {
            try w.print(" \"{s}\"", .{inst.ref_des});
        }
        try w.writeByte(')');
        if (sb.block.groups.len > 0) {
            try w.writeAll("\n      (groups");
            for (sb.block.groups) |grp| {
                try w.writeAll("\n        (group ");
                try writeString(w, grp.name);
                try w.writeAll(" (");
                for (grp.members, 0..) |m, i| {
                    if (i > 0) try w.writeByte(' ');
                    try writeString(w, m);
                }
                try w.writeAll("))");
            }
            try w.writeByte(')');
        }
        try w.writeByte(')');
    }
}

fn emitNotes(w: anytype, block: *const DesignBlock, prefix: []const u8) !void {
    for (block.notes) |note| {
        try w.writeAll("\n    (note ");
        try writePrefixedString(w, prefix, note.ref_des);
        try w.writeByte(' ');
        try writeString(w, note.text);
        try w.writeByte(')');
    }
    for (block.sub_blocks) |sb| {
        try emitNotes(w, sb.block, try prefixStr(w, prefix, sb.name));
    }
}

fn hasNotes(block: *const DesignBlock) bool {
    if (block.notes.len > 0) return true;
    for (block.sub_blocks) |sb| {
        if (hasNotes(sb.block)) return true;
    }
    return false;
}

// Helpers

fn writeString(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    try w.writeAll(s);
    try w.writeByte('"');
}

fn writePrefixedString(w: anytype, prefix: []const u8, name: []const u8) !void {
    try w.writeByte('"');
    if (prefix.len > 0) {
        try w.writeAll(prefix);
        try w.writeByte('/');
    }
    try w.writeAll(name);
    try w.writeByte('"');
}

/// Build a prefix string. We use a simple static buffer approach since
/// this is only for output emission.
var prefix_buf: [256]u8 = undefined;

fn prefixStr(_: anytype, prefix: []const u8, name: []const u8) ![]const u8 {
    if (prefix.len == 0) return name;
    const total = prefix.len + 1 + name.len;
    if (total > prefix_buf.len) return error.OutOfMemory;
    @memcpy(prefix_buf[0..prefix.len], prefix);
    prefix_buf[prefix.len] = '/';
    @memcpy(prefix_buf[prefix.len + 1 ..][0..name.len], name);
    return prefix_buf[0..total];
}

// Tests

test "emit placeholder" {
    // Basic smoke test that emit compiles
    const alloc = std.testing.allocator;
    var block = DesignBlock{
        .name = "test",
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    const output = try emitResolved(alloc, &block);
    defer alloc.free(output);
    try std.testing.expect(std.mem.startsWith(u8, output, "(resolved-design \"test\""));
}
