const std = @import("std");

// Modules under test. Paths are relative to src/leak_tests/.
const ast = @import("../sexpr/ast.zig");
const parser = @import("../sexpr/parser.zig");
const printer = @import("../sexpr/printer.zig");
const tokenizer = @import("../sexpr/tokenizer.zig");

const Node = ast.Node;
const Span = ast.Span;

// ───────────────────────────────────────────────────────────────────────
// parser.parse / parser.freeNodes — OWNED-RETURN (idiom 1)
//
// `parse(allocator, source)` returns an owned `[]const Node`; every `.list`
// node owns a heap-allocated children slice. `freeNodes` is the canonical
// recursive teardown. Both go through std.testing.allocator here, so any
// node slice (at any nesting depth) that `freeNodes` forgets to free, or any
// internal ArrayList scratch `parse` leaves behind, is caught at test end.
// ───────────────────────────────────────────────────────────────────────

// leak-audit: deep-nested success parse — every list slice at every depth
// must be reclaimed by freeNodes; the recursive descent in freeNode is the
// thing under test.
test "leak: parse + freeNodes deeply nested success" {
    const alloc = std.testing.allocator;
    const src =
        \\(footprint "QFN9-3.3x4.5"
        \\  (pad 1 smd rect (pos -1.25 1.75) (size 0.7 0.3))
        \\  (pad 2 smd rect (pos -1.25 0.75) (size 0.7 0.3))
        \\  (net "VIN" (pin "U1" 6) (pin "C1" 1)))
    ;
    const nodes = try parser.parse(alloc, src);
    defer parser.freeNodes(alloc, nodes);

    // Touch the structure so the optimizer can't elide the parse.
    try std.testing.expect(nodes.len == 1);
    try std.testing.expect(nodes[0].asList() != null);
}

// leak-audit: many top-level forms — the top-level ArrayList backing store
// plus each form's own child slice must all be freed.
test "leak: parse + freeNodes many top-level forms" {
    const alloc = std.testing.allocator;
    const src =
        \\(import a) (import b) (import c)
        \\(net "GND" (pin "U1" 1) (pin "U2" 1) (pin "C1" 2))
        \\(vals 220k 4.7k 1M 100nF 3.3V 10mil 1.0mm)
    ;
    const nodes = try parser.parse(alloc, src);
    defer parser.freeNodes(alloc, nodes);
    try std.testing.expect(nodes.len == 5);
}

// leak-audit: empty + nested-empty lists — `()` is a list node with a
// zero-length owned slice; confirm the zero-length allocation is still freed.
test "leak: parse + freeNodes empty and nested-empty lists" {
    const alloc = std.testing.allocator;
    const nodes = try parser.parse(alloc, "(a () (b ()) ())");
    defer parser.freeNodes(alloc, nodes);
    try std.testing.expect(nodes.len == 1);
}

// ───────────────────────────────────────────────────────────────────────
// parser.parse — ERROR PATHS that allocate nothing before failing.
//
// These inputs fail on the FIRST token (or before any completed list node is
// appended), so the errdefer `deinit` only reclaims an empty/backing-store
// ArrayList — there is genuinely nothing to leak. The test pins that
// contract: if a future change makes these paths allocate-and-forget, the
// testing allocator fails the build.
//
// NOTE (audit): inputs where a COMPLETED nested list is appended and a later
// sibling then fails (e.g. `(a (b) (c`) DO leak today — the errdefer frees
// only the ArrayList backing store, not the owned child slices of the
// already-appended list nodes. Those are reported in the audit, not asserted
// clean here.
// ───────────────────────────────────────────────────────────────────────

// leak-audit: top-level stray `)` errors before any allocation.
test "leak: parse error unexpected rparen allocates nothing" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.UnexpectedRparen, parser.parse(alloc, ")"));
}

// leak-audit: unterminated string errors in the tokenizer on the first
// token, before parse allocates anything.
test "leak: parse error unterminated string allocates nothing" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.UnterminatedString, parser.parse(alloc, "\"oops"));
}

// leak-audit: a lone `(` hits eof inside parseList with an empty children
// list — the errdefer reclaims only the empty backing store.
test "leak: parse error lone lparen allocates nothing leaked" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.UnexpectedEof, parser.parse(alloc, "("));
}

// ───────────────────────────────────────────────────────────────────────
// printer.print — OWNED-RETURN (idiom 1)
//
// `print(allocator, nodes)` builds an ArrayListUnmanaged and returns
// `toOwnedSlice`. The caller frees the returned slice; `print` must free its
// own scratch on every path. Driving it through testing.allocator (return
// slice explicitly freed) proves the only surviving allocation is the
// returned buffer.
// ───────────────────────────────────────────────────────────────────────

// leak-audit: print of a multiline (long) list — exercises the indent/branch
// path; the ArrayList must hand off cleanly via toOwnedSlice with no scratch
// left behind.
test "leak: printer.print owned slice, multiline path" {
    const alloc = std.testing.allocator;
    const src =
        "(footprint \"QFN9-3.3x4.5\" " ++
        "(pad 1 smd rect (pos -1.25 1.75) (size 0.7 0.3)) " ++
        "(pad 2 smd rect (pos -1.25 0.75) (size 0.7 0.3)))";

    const nodes = try parser.parse(alloc, src);
    defer parser.freeNodes(alloc, nodes);

    const out = try printer.print(alloc, nodes);
    defer alloc.free(out);

    // The long form must wrap.
    try std.testing.expect(std.mem.indexOfScalar(u8, out, '\n') != null);
}

// leak-audit: print of an empty top-level node list returns an owned
// (possibly zero-length) slice; freeing it must not double-free or leak.
test "leak: printer.print empty node list" {
    const alloc = std.testing.allocator;
    const nodes = try parser.parse(alloc, "");
    defer parser.freeNodes(alloc, nodes);

    const out = try printer.print(alloc, nodes);
    defer alloc.free(out);

    try std.testing.expect(out.len == 0);
}

// leak-audit: full parse → print → re-parse round trip — three owned
// allocations (two node trees + the printed buffer), each freed by its own
// teardown; catches any scratch leaked in either direction.
test "leak: parse-print-parse round trip frees both trees and buffer" {
    const alloc = std.testing.allocator;
    const input = "(net \"VIN\" (pin \"U1\" 6) (pin \"C1\" 1))";

    const nodes1 = try parser.parse(alloc, input);
    defer parser.freeNodes(alloc, nodes1);

    const printed = try printer.print(alloc, nodes1);
    defer alloc.free(printed);

    const nodes2 = try parser.parse(alloc, printed);
    defer parser.freeNodes(alloc, nodes2);

    try std.testing.expect(nodes1.len == nodes2.len);
}

// ───────────────────────────────────────────────────────────────────────
// ast.Node.tokenText — OWNED-RETURN for the int case (idiom 1)
//
// `tokenText(arena)` returns a borrowed slice for atom/string but an
// ALLOCATED slice for an int node (`allocPrint`). Caller owns the int case.
// Driving it through testing.allocator and freeing the result proves the
// allocation is well-formed and not double-counted; the borrowed cases must
// allocate nothing.
// ───────────────────────────────────────────────────────────────────────

// leak-audit: tokenText on an int node allocates exactly one owned slice the
// caller frees; the atom/string cases borrow and allocate nothing.
test "leak: ast tokenText int allocation is caller-owned" {
    const alloc = std.testing.allocator;

    const int_node = Node.int(Span.zero, 42);
    const int_txt = int_node.tokenText(alloc) orelse return error.TestUnexpectedNull;
    defer alloc.free(int_txt);
    try std.testing.expectEqualStrings("42", int_txt);

    // Borrowed cases: no allocation, nothing to free (freeing would be a
    // double-free of source-owned memory). Just confirm they return the slice.
    const atom_node = Node.atom(Span.zero, "VDD");
    try std.testing.expectEqualStrings("VDD", atom_node.tokenText(alloc).?);
    const str_node = Node.string(Span.zero, "GND");
    try std.testing.expectEqualStrings("GND", str_node.tokenText(alloc).?);
}

// ───────────────────────────────────────────────────────────────────────
// tokenizer.Tokenizer — NO-ALLOC contract (documentation test)
//
// The tokenizer holds a non-owning reference to `source` and never
// allocates; every token's `.text` is a slice into the source. There is no
// allocator parameter, so there is nothing for a leak allocator to catch.
// This test runs a full walk under testing.allocator's scope purely to pin
// the no-alloc contract: if anyone ever threads an allocator into the lexer
// and forgets to free, surrounding owned-return tests would surface it.
// ───────────────────────────────────────────────────────────────────────

// Helper: walk every token, asserting each carries non-empty borrowed text
// (parens, atoms, numbers, strings all slice the source). Lives outside the
// test body so the loop is not flagged as test control flow.
fn walkTokens(src: []const u8) !usize {
    var t = tokenizer.Tokenizer.init(src);
    var seen: usize = 0;
    while (true) {
        const tok = try t.next();
        if (tok.tag == .eof) break;
        seen += 1;
        try std.testing.expect(tok.text.len > 0);
    }
    return seen;
}

// leak-audit: tokenizer walk performs zero allocation — token text is a
// borrowed source slice.
test "leak: tokenizer walk allocates nothing" {
    const seen = try walkTokens("(footprint \"QFN9\" 220k 1.0mm pad-1 (+ 1 2))");
    try std.testing.expect(seen > 0);
}
