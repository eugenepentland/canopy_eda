const std = @import("std");

/// Source location for error reporting.
pub const Span = struct {
    line: u32,
    col: u32,
    /// Byte offset into source.
    offset: u32,

    pub const zero = Span{ .line = 1, .col = 1, .offset = 0 };
};

/// AST node for S-expressions.
pub const Node = struct {
    tag: Tag,
    span: Span,

    pub const Tag = union(enum) {
        list: []const Node,
        atom: []const u8,
        string: []const u8,
        int: i64,
        float: f64,
        /// Unit-suffixed value, stored in mm.
        unit_val: f64,
    };

    pub fn list(span: Span, children: []const Node) Node {
        return .{ .tag = .{ .list = children }, .span = span };
    }

    pub fn atom(span: Span, name: []const u8) Node {
        return .{ .tag = .{ .atom = name }, .span = span };
    }

    pub fn string(span: Span, value: []const u8) Node {
        return .{ .tag = .{ .string = value }, .span = span };
    }

    pub fn int(span: Span, value: i64) Node {
        return .{ .tag = .{ .int = value }, .span = span };
    }

    pub fn float(span: Span, value: f64) Node {
        return .{ .tag = .{ .float = value }, .span = span };
    }

    pub fn unitVal(span: Span, mm_value: f64) Node {
        return .{ .tag = .{ .unit_val = mm_value }, .span = span };
    }

    /// Check if this node is a list whose first element is the given atom.
    pub fn isForm(self: Node, name: []const u8) bool {
        switch (self.tag) {
            .list => |children| {
                if (children.len == 0) return false;
                switch (children[0].tag) {
                    .atom => |a| return std.mem.eql(u8, a, name),
                    else => return false,
                }
            },
            else => return false,
        }
    }

    /// Get list children, or null if not a list.
    pub fn asList(self: Node) ?[]const Node {
        return switch (self.tag) {
            .list => |children| children,
            else => null,
        };
    }

    /// Get atom value, or null if not an atom.
    pub fn asAtom(self: Node) ?[]const u8 {
        return switch (self.tag) {
            .atom => |a| a,
            else => null,
        };
    }

    /// Get string value, or null if not a string.
    pub fn asString(self: Node) ?[]const u8 {
        return switch (self.tag) {
            .string => |s| s,
            else => null,
        };
    }

    /// Get numeric value as f64 (works for int, float, and unit_val).
    pub fn asNumber(self: Node) ?f64 {
        return switch (self.tag) {
            .int => |i| @floatFromInt(i),
            .float => |f| f,
            .unit_val => |u| u,
            else => null,
        };
    }
};

test "node constructors" {
    const n = Node.atom(Span.zero, "hello");
    try std.testing.expectEqualStrings("hello", n.asAtom().?);
    try std.testing.expect(n.asNumber() == null);

    const n2 = Node.int(Span.zero, 42);
    try std.testing.expectEqual(@as(f64, 42.0), n2.asNumber().?);
}
