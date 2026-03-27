const std = @import("std");
const ast = @import("ast.zig");
const Node = ast.Node;

/// Pretty-print a list of top-level nodes as S-expression text.
pub fn print(allocator: std.mem.Allocator, nodes: []const Node) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    for (nodes, 0..) |node, i| {
        if (i > 0) try writer.writeByte('\n');
        try printNode(writer, node, 0);
    }
    return buf.toOwnedSlice(allocator);
}

fn printNode(writer: anytype, node: Node, indent: u32) !void {
    switch (node.tag) {
        .list => |children| {
            if (children.len == 0) {
                try writer.writeAll("()");
                return;
            }

            // Short lists (no nested lists, total estimated width < 72) print on one line.
            if (isShortList(children)) {
                try writer.writeByte('(');
                for (children, 0..) |child, i| {
                    if (i > 0) try writer.writeByte(' ');
                    try printNode(writer, child, indent + 2);
                }
                try writer.writeByte(')');
            } else {
                try writer.writeByte('(');
                try printNode(writer, children[0], indent + 2);
                for (children[1..]) |child| {
                    try writer.writeByte('\n');
                    try writeIndent(writer, indent + 2);
                    try printNode(writer, child, indent + 2);
                }
                try writer.writeByte(')');
            }
        },
        .atom => |a| try writer.writeAll(a),
        .string => |s| {
            try writer.writeByte('"');
            for (s) |c| {
                if (c == '"') {
                    try writer.writeAll("\\\"");
                } else if (c == '\\') {
                    try writer.writeAll("\\\\");
                } else {
                    try writer.writeByte(c);
                }
            }
            try writer.writeByte('"');
        },
        .int => |i| try writer.print("{d}", .{i}),
        .float => |f| try printFloat(writer, f),
        .unit_val => |u| {
            try printFloat(writer, u);
            try writer.writeAll("mm");
        },
    }
}

fn printFloat(writer: anytype, f: f64) !void {
    var buf: [64]u8 = undefined;
    const formatted = std.fmt.bufPrint(&buf, "{d:.6}", .{f}) catch {
        try writer.print("{d}", .{f});
        return;
    };
    // Trim trailing zeros but keep at least one decimal digit
    var end: usize = formatted.len;
    if (std.mem.indexOfScalar(u8, formatted, '.') != null) {
        while (end > 1 and formatted[end - 1] == '0') : (end -= 1) {}
        if (end > 0 and formatted[end - 1] == '.') end += 1;
    }
    try writer.writeAll(formatted[0..end]);
}

fn estimateWidth(node: Node, depth: u32) ?usize {
    if (depth > 3) return null;
    return switch (node.tag) {
        .list => |children| {
            var w: usize = 2; // parens
            for (children, 0..) |child, i| {
                if (i > 0) w += 1; // space
                w += estimateWidth(child, depth + 1) orelse return null;
            }
            return w;
        },
        .atom => |a| a.len,
        .string => |s| s.len + 2,
        .int => |i| blk: {
            var buf: [24]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{i}) catch break :blk 12;
            break :blk s.len;
        },
        .float => |f| blk: {
            var buf: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d:.6}", .{f}) catch break :blk 12;
            break :blk s.len;
        },
        .unit_val => |u| blk: {
            var buf: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d:.6}", .{u}) catch break :blk 14;
            break :blk s.len + 2; // +2 for "mm"
        },
    };
}

fn isShortList(children: []const Node) bool {
    var total_width: usize = 2; // outer parens
    for (children, 0..) |child, i| {
        if (i > 0) total_width += 1;
        total_width += estimateWidth(child, 0) orelse return false;
        if (total_width > 72) return false;
    }
    return true;
}

fn writeIndent(writer: anytype, indent: u32) !void {
    for (0..indent) |_| {
        try writer.writeByte(' ');
    }
}

// ── Tests ──────────────────────────────────────────────────────────────

test "print simple list" {
    const alloc = std.testing.allocator;
    const parser = @import("parser.zig");
    const nodes = try parser.parse(alloc, "(hello 42 \"world\")");
    defer parser.freeNodes(alloc, nodes);

    const output = try print(alloc, nodes);
    defer alloc.free(output);

    try std.testing.expectEqualStrings("(hello 42 \"world\")", output);
}

test "print short nested lists inline" {
    const alloc = std.testing.allocator;
    const parser = @import("parser.zig");
    const nodes = try parser.parse(alloc, "(pad 1 smd rect (pos -1.25 1.75) (size 0.7 0.3))");
    defer parser.freeNodes(alloc, nodes);

    const output = try print(alloc, nodes);
    defer alloc.free(output);

    // Short enough to fit on one line
    try std.testing.expect(std.mem.indexOf(u8, output, "\n") == null);
}

test "print long nested lists multiline" {
    const alloc = std.testing.allocator;
    const parser = @import("parser.zig");
    // This is too long for one line (> 72 chars with nested lists)
    const nodes = try parser.parse(alloc, "(footprint \"QFN9-3.3x4.5\" (pad 1 smd rect (pos -1.25 1.75) (size 0.7 0.3)) (pad 2 smd rect (pos -1.25 0.75) (size 0.7 0.3)))");
    defer parser.freeNodes(alloc, nodes);

    const output = try print(alloc, nodes);
    defer alloc.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "\n") != null);
}

test "round-trip parse-print-parse" {
    const alloc = std.testing.allocator;
    const parser = @import("parser.zig");
    const input = "(net \"VIN\" (pin \"U1\" 6) (pin \"C1\" 1))";

    const nodes1 = try parser.parse(alloc, input);
    defer parser.freeNodes(alloc, nodes1);

    const printed = try print(alloc, nodes1);
    defer alloc.free(printed);

    const nodes2 = try parser.parse(alloc, printed);
    defer parser.freeNodes(alloc, nodes2);

    try std.testing.expectEqual(nodes1.len, nodes2.len);
    try expectNodesEqual(nodes1[0], nodes2[0]);
}

fn expectNodesEqual(a: Node, b: Node) !void {
    switch (a.tag) {
        .list => |ac| {
            const bc = b.asList() orelse return error.TestExpectedEqual;
            try std.testing.expectEqual(ac.len, bc.len);
            for (ac, bc) |ai, bi| {
                try expectNodesEqual(ai, bi);
            }
        },
        .atom => |av| try std.testing.expectEqualStrings(av, b.asAtom() orelse return error.TestExpectedEqual),
        .string => |sv| try std.testing.expectEqualStrings(sv, b.asString() orelse return error.TestExpectedEqual),
        .int => |iv| try std.testing.expectEqual(iv, switch (b.tag) {
            .int => |bv| bv,
            else => return error.TestExpectedEqual,
        }),
        .float => |fv| try std.testing.expectApproxEqAbs(fv, switch (b.tag) {
            .float => |bv| bv,
            else => return error.TestExpectedEqual,
        }, 0.0001),
        .unit_val => |uv| try std.testing.expectApproxEqAbs(uv, switch (b.tag) {
            .unit_val => |bv| bv,
            else => return error.TestExpectedEqual,
        }, 0.0001),
    }
}
