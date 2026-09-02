//! Balanced-paren matching over raw s-expression TEXT, for the two callers
//! that splice bytes rather than re-print an AST: `id_insert` (stamping
//! `(id …)` into a design's own `.sexp` source without disturbing a byte of
//! its formatting) and `export_kicad_footprint` (replacing a `(model …)` form
//! inside a vendor `.kicad_mod`).
//!
//! Both had their own scanner. Getting one of them wrong does not fail loudly:
//! a paren counted inside a quoted string ends the form early and the splice
//! lands mid-token, corrupting the file it was meant to edit. The two dialects
//! differ in exactly one respect — netlisp `.sexp` has `;` line comments and
//! KiCad's format does not — which is a parameter, not a reason for a second
//! implementation.
//!
//! This is deliberately NOT the tokenizer. The callers hold a byte buffer they
//! are about to edit in place and need offsets into it; parsing to an AST and
//! printing it back would reformat everything around the edit.

const std = @import("std");

/// Whether the dialect being scanned has `;` line comments. KiCad's
/// s-expressions do not, so a `;` there is an ordinary atom character.
pub const Comments = enum { none, line_semicolon };

/// Byte offset of the `)` that closes the form opening at `open`.
///
/// Quoted strings (and their `\` escapes) are skipped, so a parenthesis inside
/// a string — a vendor `.kicad_mod` whose model reads `models/Part(rev2).step`
/// — cannot end the form early and mis-splice the file. Null when `open` does
/// not open a form and when the form is unterminated, so a caller that guessed
/// the start wrong gets a refusal rather than a wrong splice.
pub fn matchingClose(source: []const u8, open: usize, comments: Comments) ?usize {
    if (open >= source.len or source[open] != '(') return null;
    // Entering at the opening paren itself keeps `depth` at 1 or more for
    // every `)` below, so the decrement cannot underflow.
    var depth: u32 = 0;
    var in_string = false;
    var i = open;
    while (i < source.len) : (i += 1) {
        if (in_string) {
            if (source[i] == '\\' and i + 1 < source.len) {
                i += 1; // skip the escaped byte, `\"` included
            } else if (source[i] == '"') {
                in_string = false;
            }
            continue;
        }
        switch (source[i]) {
            '"' => in_string = true,
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            ';' => if (comments == .line_semicolon) {
                while (i < source.len and source[i] != '\n') : (i += 1) {}
            },
            else => {},
        }
    }
    return null;
}

/// One past `matchingClose` — the exclusive end offset a slice-and-splice
/// caller wants.
pub fn endIndex(source: []const u8, open: usize, comments: Comments) ?usize {
    return (matchingClose(source, open, comments) orelse return null) + 1;
}

// spec: sexpr/parser - Paren-span matching skips quoted parens and honours the dialect's comment style
test "matchingClose skips strings and respects the comment dialect" {
    const testing = std.testing;
    try testing.expectEqual(@as(?usize, 28), matchingClose("(instance \"R1\" (cap \"100nF\"))", 0, .line_semicolon));
    // A paren inside a quoted string must not close the form.
    const quoted = "(model \"models/Part(rev2).step\" (offset 0))";
    try testing.expectEqual(@as(?usize, quoted.len - 1), matchingClose(quoted, 0, .none));
    try testing.expectEqual(@as(?usize, quoted.len), endIndex(quoted, 0, .none));
    // An escaped quote keeps the scanner inside the string.
    const escaped = "(a \"x\\\")y\" b)";
    try testing.expectEqual(@as(?usize, escaped.len - 1), matchingClose(escaped, 0, .none));
    // `;` ends a line only where the dialect has line comments.
    const commented = "(a ; ) not a close\n b)";
    try testing.expectEqual(@as(?usize, commented.len - 1), matchingClose(commented, 0, .line_semicolon));
    try testing.expectEqual(@as(?usize, 5), matchingClose(commented, 0, .none));
    // Refusals: not a form, and unterminated.
    try testing.expectEqual(@as(?usize, null), matchingClose("x(a)", 0, .none));
    try testing.expectEqual(@as(?usize, null), matchingClose("(a (b)", 0, .none));
    try testing.expectEqual(@as(?usize, null), matchingClose("(a", 3, .none));
}
