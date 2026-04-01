const std = @import("std");
const ast = @import("ast.zig");
const tokenizer_mod = @import("tokenizer.zig");
const Node = ast.Node;
const Span = ast.Span;
const Tokenizer = tokenizer_mod.Tokenizer;
const TokenTag = tokenizer_mod.TokenTag;
const Token = tokenizer_mod.Token;

pub const ParseError = error{
    UnexpectedEof,
    UnexpectedRparen,
    UnexpectedCharacter,
    UnterminatedString,
    InvalidNumber,
    OutOfMemory,
};

/// Parse S-expression source into a list of top-level nodes.
pub fn parse(allocator: std.mem.Allocator, source: []const u8) ParseError![]const Node {
    var tok = Tokenizer.init(source);
    var nodes: std.ArrayListUnmanaged(Node) = .empty;
    errdefer nodes.deinit(allocator);

    while (true) {
        const token = try tok.next();
        if (token.tag == .eof) break;
        const node = try parseNode(allocator, &tok, token);
        try nodes.append(allocator, node);
    }
    return nodes.toOwnedSlice(allocator);
}

fn parseNode(allocator: std.mem.Allocator, tok: *Tokenizer, token: Token) ParseError!Node {
    switch (token.tag) {
        .lparen => return parseList(allocator, tok, token.span),
        .rparen => return ParseError.UnexpectedRparen,
        .atom => return Node.atom(token.span, token.text),
        .string => return Node.string(token.span, token.text),
        .int => {
            const val = std.fmt.parseInt(i64, token.text, 10) catch return ParseError.InvalidNumber;
            return Node.int(token.span, val);
        },
        .float => {
            const val = std.fmt.parseFloat(f64, token.text) catch return ParseError.InvalidNumber;
            return Node.float(token.span, val);
        },
        .unit_val => {
            const val = std.fmt.parseFloat(f64, token.text) catch return ParseError.InvalidNumber;
            // Check the source bytes right after the number for mm vs mil
            const after_pos = token.span.offset + @as(u32, @intCast(token.text.len));
            const source = tok.source;
            var mm_value = val;
            if (after_pos + 2 < source.len and source[after_pos] == 'm' and source[after_pos + 1] == 'i' and source[after_pos + 2] == 'l') {
                mm_value = val * 0.0254; // mil to mm
            }
            return Node.unitVal(token.span, mm_value);
        },
        .eof => return ParseError.UnexpectedEof,
    }
}

fn parseList(allocator: std.mem.Allocator, tok: *Tokenizer, open_span: Span) ParseError!Node {
    var children: std.ArrayListUnmanaged(Node) = .empty;
    errdefer children.deinit(allocator);

    while (true) {
        const token = try tok.next();
        if (token.tag == .eof) return ParseError.UnexpectedEof;
        if (token.tag == .rparen) break;
        const child = try parseNode(allocator, tok, token);
        try children.append(allocator, child);
    }
    return Node.list(open_span, try children.toOwnedSlice(allocator));
}

// ── Tests ──────────────────────────────────────────────────────────────

// spec: sexpr/parser - Parses a simple S-expression list into an AST node
test "parse simple list" {
    const alloc = std.testing.allocator;
    const nodes = try parse(alloc, "(hello 42 \"world\")");
    defer alloc.free(nodes);
    defer alloc.free(nodes[0].asList().?);

    try std.testing.expectEqual(@as(usize, 1), nodes.len);
    const children = nodes[0].asList().?;
    try std.testing.expectEqual(@as(usize, 3), children.len);
    try std.testing.expectEqualStrings("hello", children[0].asAtom().?);
    try std.testing.expectEqual(@as(f64, 42.0), children[1].asNumber().?);
    try std.testing.expectEqualStrings("world", children[2].asString().?);
}

// spec: sexpr/parser - Parses nested S-expression lists into a tree
test "parse nested lists" {
    const alloc = std.testing.allocator;
    const nodes = try parse(alloc, "(a (b c) (d (e)))");
    defer freeNodes(alloc, nodes);

    const children = nodes[0].asList().?;
    try std.testing.expectEqual(@as(usize, 3), children.len);

    const inner1 = children[1].asList().?;
    try std.testing.expectEqual(@as(usize, 2), inner1.len);

    const inner2 = children[2].asList().?;
    try std.testing.expectEqual(@as(usize, 2), inner2.len);
}

// spec: sexpr/parser - Parses numbers and unit values into typed AST nodes
test "parse numbers and units" {
    const alloc = std.testing.allocator;
    const nodes = try parse(alloc, "(pos 1.0mm 0.5mm 10mil)");
    defer freeNodes(alloc, nodes);

    const children = nodes[0].asList().?;
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), children[1].asNumber().?, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), children[2].asNumber().?, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.254), children[3].asNumber().?, 0.001);
}

// spec: sexpr/parser - Parses input containing comments by ignoring them
test "parse with comments" {
    const alloc = std.testing.allocator;
    const nodes = try parse(alloc,
        \\; top comment
        \\(pin 1 "VIN" power-in left 1)
        \\; another comment
    );
    defer freeNodes(alloc, nodes);

    try std.testing.expectEqual(@as(usize, 1), nodes.len);
    const children = nodes[0].asList().?;
    try std.testing.expectEqual(@as(usize, 6), children.len);
    try std.testing.expectEqualStrings("pin", children[0].asAtom().?);
}

// spec: sexpr/parser - Parses multiple top-level forms into separate AST nodes
test "parse multiple top-level forms" {
    const alloc = std.testing.allocator;
    const nodes = try parse(alloc, "(import a) (import b)");
    defer freeNodes(alloc, nodes);

    try std.testing.expectEqual(@as(usize, 2), nodes.len);
    try std.testing.expect(nodes[0].isForm("import"));
    try std.testing.expect(nodes[1].isForm("import"));
}

// spec: sexpr/parser - Identifies forms by head atom via isForm helper
test "parse isForm helper" {
    const alloc = std.testing.allocator;
    const nodes = try parse(alloc, "(net \"VIN\" (pin \"U1\" 6))");
    defer freeNodes(alloc, nodes);

    try std.testing.expect(nodes[0].isForm("net"));
    try std.testing.expect(!nodes[0].isForm("pin"));
}

/// Recursively free all allocated slices in a node tree.
pub fn freeNodes(allocator: std.mem.Allocator, nodes: []const Node) void {
    for (nodes) |node| {
        freeNode(allocator, node);
    }
    allocator.free(nodes);
}

fn freeNode(allocator: std.mem.Allocator, node: Node) void {
    switch (node.tag) {
        .list => |children| {
            for (children) |child| {
                freeNode(allocator, child);
            }
            allocator.free(children);
        },
        else => {},
    }
}
