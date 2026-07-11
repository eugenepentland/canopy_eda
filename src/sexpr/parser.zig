const std = @import("std");
const ast = @import("ast.zig");
const tokenizer_mod = @import("tokenizer.zig");
const Node = ast.Node;
const Span = ast.Span;
const Tokenizer = tokenizer_mod.Tokenizer;
const TokenTag = tokenizer_mod.TokenTag;
const Token = tokenizer_mod.Token;

// ── Constants ─────────────────────────────────────────────────────
const mil_to_mm: f64 = 0.0254;

/// Maximum S-expression nesting depth. `parseList` → `parseNode` → `parseList`
/// recurses once per open paren; without a bound, a few hundred KB of `(((…`
/// overflows the process stack and aborts the whole `netlisp serve`. This cap
/// is far beyond any legitimate design (real files nest well under 100 deep)
/// yet stops the runaway before the native stack does. Bounding the parser
/// bounds the evaluator for free — eval recursion follows AST depth.
const max_parse_depth: u32 = 10_000;

pub const ParseError = error{
    UnexpectedEof,
    UnexpectedRparen,
    UnexpectedCharacter,
    UnterminatedString,
    InvalidNumber,
    /// S-expression nesting exceeded `MAX_PARSE_DEPTH` — almost certainly
    /// malformed/hostile input rather than a real design.
    TooDeep,
    OutOfMemory,
};

/// Parse S-expression source into a list of top-level nodes.
pub fn parse(allocator: std.mem.Allocator, source: []const u8) ParseError![]const Node {
    var tok = Tokenizer.init(source);
    var nodes: std.ArrayList(Node) = .empty;
    errdefer nodes.deinit(allocator);

    while (true) {
        const token = try tok.next();
        if (token.tag == .eof) break;
        const node = try parseNode(allocator, &tok, token, 0);
        try nodes.append(allocator, node);
    }
    return nodes.toOwnedSlice(allocator);
}

fn parseNode(allocator: std.mem.Allocator, tok: *Tokenizer, token: Token, depth: u32) ParseError!Node {
    switch (token.tag) {
        .lparen => return parseList(allocator, tok, token.span, depth),
        .rparen => return ParseError.UnexpectedRparen,
        .atom => return Node.atom(token.span, token.text),
        .string => return Node.string(token.span, token.text),
        .int, .float, .si_val, .unit_val => return parseNumberNode(tok, token),
        .eof => return ParseError.UnexpectedEof,
    }
}

/// Parse a numeric token (`int`/`float`/`si_val`/`unit_val`) into its AST
/// node, applying the SI scale suffix or the mm/mil dimension conversion.
fn parseNumberNode(tok: *Tokenizer, token: Token) ParseError!Node {
    switch (token.tag) {
        .int => {
            const val = std.fmt.parseInt(i64, token.text, 10) catch return ParseError.InvalidNumber;
            return Node.int(token.span, val);
        },
        .float => {
            const val = std.fmt.parseFloat(f64, token.text) catch return ParseError.InvalidNumber;
            return Node.float(token.span, val);
        },
        .si_val => {
            const val = parseSiValue(token.text) orelse return ParseError.InvalidNumber;
            return Node.float(token.span, val);
        },
        .unit_val => {
            const val = std.fmt.parseFloat(f64, token.text) catch return ParseError.InvalidNumber;
            // Check the source bytes right after the number for mm vs mil
            const after_pos = token.span.offset + @as(u32, @intCast(token.text.len));
            const source = tok.source;
            var mm_value = val;
            if (after_pos + 2 < source.len and source[after_pos] == 'm' and source[after_pos + 1] == 'i' and source[after_pos + 2] == 'l') {
                mm_value = val * mil_to_mm; // mil to mm
            }
            return Node.unitVal(token.span, mm_value);
        },
        else => return ParseError.InvalidNumber,
    }
}

/// Parse an SI-scaled literal token (`220k`, `100nF`, `3.3V`, `10mA`) into
/// its numeric value. The numeric prefix is multiplied by the scale letter's
/// entry in `tokenizer.si_scales`; a trailing unit letter carries no scale.
/// Returns null when the text has no parsable numeric prefix — the
/// tokenizer's suffix rules make that unreachable for `.si_val` tokens.
fn parseSiValue(text: []const u8) ?f64 {
    var num_end: usize = 0;
    while (num_end < text.len) : (num_end += 1) {
        const c = text[num_end];
        const numeric = (c >= '0' and c <= '9') or c == '.' or (c == '-' and num_end == 0);
        if (!numeric) break;
    }
    if (num_end == 0 or num_end == text.len) return null;
    const base = std.fmt.parseFloat(f64, text[0..num_end]) catch return null;
    const scale: f64 = for (tokenizer_mod.si_scales) |s| {
        if (s.letter == text[num_end]) break s.multiplier;
    } else 1.0; // bare unit letter (V/A/F/H/R)
    return base * scale;
}

fn parseList(allocator: std.mem.Allocator, tok: *Tokenizer, open_span: Span, depth: u32) ParseError!Node {
    if (depth >= max_parse_depth) return ParseError.TooDeep;
    var children: std.ArrayList(Node) = .empty;
    errdefer children.deinit(allocator);

    while (true) {
        const token = try tok.next();
        if (token.tag == .eof) return ParseError.UnexpectedEof;
        if (token.tag == .rparen) break;
        const child = try parseNode(allocator, tok, token, depth + 1);
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

// spec: sexpr/parser - Parses SI-scaled literals (220k, 100nF, 3.3V, 10mA) into scaled float nodes
test "parse si scaled values" {
    const alloc = std.testing.allocator;
    const nodes = try parse(alloc, "(vals 220k 4.7k 1M 2G 10u 100n 22p 100nF 1uH 10mA 100mV 3.3V 0.5A 47R)");
    defer freeNodes(alloc, nodes);

    const c = nodes[0].asList().?;
    try std.testing.expectApproxEqRel(@as(f64, 220000.0), c[1].asNumber().?, 1e-12);
    try std.testing.expectApproxEqRel(@as(f64, 4700.0), c[2].asNumber().?, 1e-12);
    try std.testing.expectApproxEqRel(@as(f64, 1e6), c[3].asNumber().?, 1e-12);
    try std.testing.expectApproxEqRel(@as(f64, 2e9), c[4].asNumber().?, 1e-12);
    try std.testing.expectApproxEqRel(@as(f64, 1e-5), c[5].asNumber().?, 1e-12);
    try std.testing.expectApproxEqRel(@as(f64, 1e-7), c[6].asNumber().?, 1e-12);
    try std.testing.expectApproxEqRel(@as(f64, 22e-12), c[7].asNumber().?, 1e-12);
    // 100nF == 100n — the unit letter carries no scale
    try std.testing.expectApproxEqRel(@as(f64, 1e-7), c[8].asNumber().?, 1e-12);
    try std.testing.expectApproxEqRel(@as(f64, 1e-6), c[9].asNumber().?, 1e-12);
    try std.testing.expectApproxEqRel(@as(f64, 0.01), c[10].asNumber().?, 1e-12);
    try std.testing.expectApproxEqRel(@as(f64, 0.1), c[11].asNumber().?, 1e-12);
    try std.testing.expectApproxEqRel(@as(f64, 3.3), c[12].asNumber().?, 1e-12);
    try std.testing.expectApproxEqRel(@as(f64, 0.5), c[13].asNumber().?, 1e-12);
    try std.testing.expectApproxEqRel(@as(f64, 47.0), c[14].asNumber().?, 1e-12);
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

// spec: sexpr/parser - Rejects input nested past MAX_PARSE_DEPTH with TooDeep instead of overflowing the stack
test "parse rejects excessively deep nesting" {
    const alloc = std.testing.allocator;
    // MAX_PARSE_DEPTH + a margin of open parens: deep enough to trip the guard
    // but nowhere near a native stack overflow, so the test itself is safe.
    const depth = max_parse_depth + 16;
    const src = try alloc.alloc(u8, depth);
    defer alloc.free(src);
    @memset(src, '(');
    try std.testing.expectError(ParseError.TooDeep, parse(alloc, src));
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
