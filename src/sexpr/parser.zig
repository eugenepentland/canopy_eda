//! S-expression parser: turns the tokenizer's stream into the AST (`ast.Node`s,
//! each carrying a source `Span`). Recursive descent with a hard nesting-depth
//! cap so pathological `(((…` input cannot overflow the server's stack. Node
//! string slices borrow the source buffer, which is never freed.

const std = @import("std");
const ast = @import("ast.zig");
const tokenizer_mod = @import("tokenizer.zig");
const Node = ast.Node;
const Span = ast.Span;
const Tokenizer = tokenizer_mod.Tokenizer;
const TokenTag = tokenizer_mod.TokenTag;
const Token = tokenizer_mod.Token;

// ── Constants ─────────────────────────────────────────────────────
const MIL_TO_MM: f64 = 0.0254;

/// Maximum S-expression nesting depth. `parseList` → `parseNode` → `parseList`
/// recurses once per open paren; without a bound, a few hundred KB of `(((…`
/// overflows the process stack and aborts the whole `netlisp serve`. This cap
/// is far beyond any legitimate design (real files nest well under 100 deep)
/// yet stops the runaway before the native stack does. Bounding the parser
/// bounds the evaluator for free — eval recursion follows AST depth.
const MAX_PARSE_DEPTH: u32 = 10_000;

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

/// Source-located explanation for a `ParseError`, mirroring the evaluator's
/// `EvalDiagnostic` (span + borrowed message) so a syntax error can route
/// through the identical `serve/diag_format` rendering path — `file:line:col`,
/// the offending source line, and a caret — instead of surfacing as a bare
/// error name pinned to 1:1. The message is a borrowed static string and
/// outlives any allocator.
pub const ParseDiagnostic = struct {
    span: Span = Span.zero,
    message: []const u8 = "",
};

/// Borrowed, human-readable static message for each `ParseError` kind, used to
/// populate a `ParseDiagnostic`. Kept exhaustive so a new error variant is a
/// compile error here rather than an empty diagnostic at runtime.
pub fn errorMessage(err: ParseError) []const u8 {
    return switch (err) {
        error.UnexpectedEof => "unexpected end of input — a '(' was never closed",
        error.UnexpectedRparen => "unexpected ')' — no matching '(' is open here",
        error.UnexpectedCharacter => "unexpected character",
        error.UnterminatedString => "unterminated string — missing closing '\"'",
        error.InvalidNumber => "invalid number literal",
        error.TooDeep => "s-expression nesting is too deep",
        error.OutOfMemory => "out of memory while parsing",
    };
}

/// Parse S-expression source into a list of top-level nodes, discarding any
/// diagnostic. Thin wrapper over `parseDiag` for the many call sites that only
/// care about success/failure.
pub fn parse(allocator: std.mem.Allocator, source: []const u8) ParseError![]const Node {
    var diag: ParseDiagnostic = .{};
    return parseDiag(allocator, source, &diag);
}

/// Parse S-expression source, writing a source-located diagnostic into `diag`
/// on failure (the failing token/byte span plus a human-readable message). On
/// success `diag` is left untouched. Every error path — including allocation
/// failures — leaves `diag.message` non-empty so callers can render it as
/// `file:line:col: error: <message>` with a caret.
pub fn parseDiag(allocator: std.mem.Allocator, source: []const u8, diag: *ParseDiagnostic) ParseError![]const Node {
    return parseInner(allocator, source, diag) catch |err| {
        if (diag.message.len == 0) diag.* = .{ .span = diag.span, .message = errorMessage(err) };
        return err;
    };
}

fn parseInner(allocator: std.mem.Allocator, source: []const u8, diag: *ParseDiagnostic) ParseError![]const Node {
    var tok = Tokenizer.init(source);
    var nodes: std.ArrayListUnmanaged(Node) = .empty;
    // Recursively free every already-parsed top-level node on error: a syntax
    // error partway through a file leaves complete nodes (with allocated child
    // slices) that a bare `deinit` of the backing array alone would leak.
    errdefer {
        for (nodes.items) |n| freeNode(allocator, n);
        nodes.deinit(allocator);
    }

    while (true) {
        const token = try nextToken(&tok, diag);
        if (token.tag == .eof) break;
        const node = try parseNode(allocator, &tok, token, 0, diag);
        try nodes.append(allocator, node);
    }
    return nodes.toOwnedSlice(allocator);
}

/// Advance the tokenizer, capturing the failing byte's span into `diag` when
/// the lexer rejects a character or an unterminated string.
fn nextToken(tok: *Tokenizer, diag: *ParseDiagnostic) ParseError!Token {
    return tok.next() catch |err| {
        diag.* = .{ .span = tok.error_span, .message = errorMessage(err) };
        return err;
    };
}

/// Record `span` + the message for `err` into `diag` and return `err`, so a
/// parser-level rejection reports where it happened.
fn fail(diag: *ParseDiagnostic, span: Span, err: ParseError) ParseError {
    diag.* = .{ .span = span, .message = errorMessage(err) };
    return err;
}

fn parseNode(
    allocator: std.mem.Allocator,
    tok: *Tokenizer,
    token: Token,
    depth: u32,
    diag: *ParseDiagnostic,
) ParseError!Node {
    switch (token.tag) {
        .lparen => return parseList(allocator, tok, token.span, depth, diag),
        .rparen => return fail(diag, token.span, ParseError.UnexpectedRparen),
        .atom => return Node.atom(token.span, token.text),
        .string => return Node.string(token.span, token.text),
        .int, .float, .si_val, .unit_val => return parseNumberNode(tok, token, diag),
        .eof => return fail(diag, token.span, ParseError.UnexpectedEof),
    }
}

/// Parse a numeric token (`int`/`float`/`si_val`/`unit_val`) into its AST
/// node, applying the SI scale suffix or the mm/mil dimension conversion.
fn parseNumberNode(tok: *Tokenizer, token: Token, diag: *ParseDiagnostic) ParseError!Node {
    switch (token.tag) {
        .int => {
            const val = std.fmt.parseInt(i64, token.text, 10) catch
                return fail(diag, token.span, ParseError.InvalidNumber);
            return Node.int(token.span, val);
        },
        .float => {
            const val = std.fmt.parseFloat(f64, token.text) catch
                return fail(diag, token.span, ParseError.InvalidNumber);
            return Node.float(token.span, val);
        },
        .si_val => {
            const val = parseSiValue(token.text) orelse return fail(diag, token.span, ParseError.InvalidNumber);
            return Node.float(token.span, val);
        },
        .unit_val => {
            const val = std.fmt.parseFloat(f64, token.text) catch
                return fail(diag, token.span, ParseError.InvalidNumber);
            // Check the source bytes right after the number for mm vs mil
            const after_pos = token.span.offset + @as(u32, @intCast(token.text.len));
            const source = tok.source;
            var mm_value = val;
            if (after_pos + 2 < source.len and source[after_pos] == 'm' and source[after_pos + 1] == 'i' and source[after_pos + 2] == 'l') {
                mm_value = val * MIL_TO_MM; // mil to mm
            }
            return Node.unitVal(token.span, mm_value);
        },
        else => return fail(diag, token.span, ParseError.InvalidNumber),
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

fn parseList(
    allocator: std.mem.Allocator,
    tok: *Tokenizer,
    open_span: Span,
    depth: u32,
    diag: *ParseDiagnostic,
) ParseError!Node {
    if (depth >= MAX_PARSE_DEPTH) return fail(diag, open_span, ParseError.TooDeep);
    var children: std.ArrayListUnmanaged(Node) = .empty;
    // Free the children parsed so far if a later token in this list errors —
    // each may itself be a list owning an allocated slice.
    errdefer {
        for (children.items) |c| freeNode(allocator, c);
        children.deinit(allocator);
    }

    while (true) {
        const token = try nextToken(tok, diag);
        // Point an unterminated list at the '(' that was never closed — the
        // actionable location, not the end of the file where scanning stopped.
        if (token.tag == .eof) return fail(diag, open_span, ParseError.UnexpectedEof);
        if (token.tag == .rparen) break;
        const child = try parseNode(allocator, tok, token, depth + 1, diag);
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
    const depth = MAX_PARSE_DEPTH + 16;
    const src = try alloc.alloc(u8, depth);
    defer alloc.free(src);
    @memset(src, '(');
    try std.testing.expectError(ParseError.TooDeep, parse(alloc, src));
}

// spec: sexpr/parser - Reports the line and column of a syntax error midway through a multi-line source
test "parseDiag locates a mid-file syntax error" {
    const alloc = std.testing.allocator;
    var diag: ParseDiagnostic = .{};
    // The top form closes on line 3 (first ')'), leaving a stray ')' at 3:4.
    const src = "(a\n  (b c)\n  ))";
    try std.testing.expectError(ParseError.UnexpectedRparen, parseDiag(alloc, src, &diag));
    try std.testing.expectEqual(@as(u32, 3), diag.span.line);
    try std.testing.expectEqual(@as(u32, 4), diag.span.col);
    try std.testing.expect(diag.message.len > 0);
}

// spec: sexpr/parser - A parse diagnostic column locates the offending token so a caret aligns under it
test "parseDiag column aligns a caret under the offending token" {
    const alloc = std.testing.allocator;
    var diag: ParseDiagnostic = .{};
    // `]` is an unexpected character at col 6 of the single source line.
    const line = "(bad ]x)";
    try std.testing.expectError(ParseError.UnexpectedCharacter, parseDiag(alloc, line, &diag));
    try std.testing.expectEqual(@as(u32, 1), diag.span.line);
    try std.testing.expectEqual(@as(u32, 6), diag.span.col);

    // Build the caret the diag renderer would: (col-1) spaces then '^'.
    var caret: [8]u8 = undefined;
    const n = diag.span.col - 1;
    @memset(caret[0..n], ' ');
    caret[n] = '^';
    // The caret lands exactly on the offending ']'.
    try std.testing.expectEqual(@as(u8, ']'), line[n]);
    try std.testing.expectEqualStrings("     ^", caret[0 .. n + 1]);
}

// spec: sexpr/parser - An unterminated list is reported at the unclosed open paren
test "parseDiag points an unterminated list at its open paren" {
    const alloc = std.testing.allocator;
    var diag: ParseDiagnostic = .{};
    const src = "(outer\n  (inner 1 2\n";
    try std.testing.expectError(ParseError.UnexpectedEof, parseDiag(alloc, src, &diag));
    // Reported at the inner '(' (2:3), the innermost list left unclosed.
    try std.testing.expectEqual(@as(u32, 2), diag.span.line);
    try std.testing.expectEqual(@as(u32, 3), diag.span.col);
}

// A handful of real S-expressions seed the round-trip property; the malformed
// entries make sure the error paths stay leak-clean under arbitrary bytes.
const parser_fuzz_corpus = [_][]const u8{
    "(design-block \"X\" (instance \"R1\" (res-0402 \"10k\") (pin 1 \"A\") (pin 2 \"B\")))",
    "(net \"VIN\" (pin \"U1\" 6) (pin \"C1\" 1))",
    "(pad 1 smd rect (pos -1.25 1.75) (size 0.7 0.3))",
    "(vals 220k 4.7k 1M 100nF 3.3V 10mA 1.0mm 10mil 42 -5 3.3)",
    "(a (b (c (d (e (f))))))",
    "; comment\n(after \"comment\")\n",
    "(unterminated",
    ")",
    "\"oops",
    "(bad ]char)",
};

/// One fuzz iteration for the S-expression parser: arbitrary bytes must never
/// crash or overflow — every input either parses or returns a `ParseError`, and
/// the `MAX_PARSE_DEPTH` bound (covered by its own test) keeps deep input off
/// the native stack. Runs under `testing.allocator`, so a missed free on any
/// path — including every error path — fails the test. (The parse→print→parse
/// round-trip is fuzzed in printer.zig, which owns the printer, to keep the
/// import graph acyclic.)
fn fuzzParse(allocator: std.mem.Allocator, input: []const u8) anyerror!void {
    const nodes = parse(allocator, input) catch return;
    freeNodes(allocator, nodes);
}

// spec: sexpr/parser - Fuzzing the parser tolerates arbitrary bytes without crashing or leaking
test "fuzz: parser never crashes on arbitrary bytes" {
    try std.testing.fuzz(std.testing.allocator, fuzzParse, .{ .corpus = &parser_fuzz_corpus });
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
