//! Resolve an editable instance by its source label and exact source revision.
const std = @import("std");
const parser = @import("../sexpr/parser.zig");
const Node = @import("../sexpr/ast.zig").Node;
const transaction = @import("../infra/source_transaction.zig");

/// Reject stale offsets, duplicate labels and comment/string lookalikes.
pub fn resolve(allocator: std.mem.Allocator, source: []const u8, identity: []const u8, offset: usize, revision: ?[]const u8) (parser.ParseError || error{ StaleSource, AmbiguousIdentity })!?usize {
    if (revision) |expected| {
        if (!std.mem.eql(u8, expected, &transaction.revision(source))) return error.StaleSource;
    } else if (offset > 0) return error.StaleSource;
    const nodes = try parser.parse(allocator, source);
    var found: ?usize = null;
    try visit(nodes, identity, &found);
    return found;
}

fn visit(nodes: []const Node, identity: []const u8, found: *?usize) error{AmbiguousIdentity}!void {
    for (nodes) |node| {
        const children = node.asList() orelse continue;
        if (node.isForm("instance") and children.len >= 2) {
            const label = children[1].asString() orelse continue;
            if (std.mem.eql(u8, label, identity)) {
                if (found.* != null) return error.AmbiguousIdentity;
                found.* = node.span.offset;
            }
        }
        try visit(children, identity, found);
    }
}

// spec: Web Server - Instance edits require current source revisions and unique parsed source labels rather than stale byte offsets
test "edit target rejects stale offsets and resolves only real unique labels" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const before = "(instance \"R1\" (res \"10k\"))\n(instance \"R2\" (res \"22k\"))";
    const after = "(instance \"R1\" (res \"a much longer value\"))\n(instance \"R2\" (res \"22k\"))";
    const rev = transaction.revision(before);
    try std.testing.expectError(error.StaleSource, resolve(a, after, "R2", 43, &rev));
    try std.testing.expectError(error.StaleSource, resolve(a, before, "R2", 43, null));
    const at = (try resolve(a, before, "R2", 43, &rev)).?;
    try std.testing.expect(std.mem.startsWith(u8, before[at..], "(instance \"R2\""));
    try std.testing.expect((try resolve(a, "; (instance \"R1\" res)\n", "R1", 0, null)) == null);
    try std.testing.expectError(error.AmbiguousIdentity, resolve(a, "(instance \"R1\" res) (instance \"R1\" res)", "R1", 0, null));
}
