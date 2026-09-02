//! Where does the s-expression that opens at this byte end?
//!
//! Every surface that splices a form into a `.sexp` file by byte offset —
//! adding a `(requirement …)` to a component, replacing a design's
//! `(diagram-layout …)` — needs the same answer, and the copies that grew up
//! answering it separately had stopped agreeing about the two inputs that
//! matter:
//!
//!   * a `;` line comment. One copy skipped it, the other counted the parens
//!     inside it, so a comment mentioning `)` moved that copy's idea of the
//!     form's end.
//!   * a `start` that is not an `(`. One copy carried a `usize` depth and
//!     decremented it on the first `)`, which is an underflow panic in a safe
//!     build rather than "unbalanced, return null".
//!
//! This is a byte scanner, not a parser: it is what the SPLICING paths need,
//! which is the exact source span of one form, comments and whitespace intact.
//! Code that wants the form's CONTENT parses it with `sexpr/parser.zig`.

const std = @import("std");

/// Byte index of the `)` closing the list that opens at `open`, or null when
/// `open` is not an `(` or the list never closes.
///
/// String literals (with `\` escapes) and `;` line comments are opaque: parens
/// inside either are text, not structure.
pub fn closeIndex(text: []const u8, open: usize) ?usize {
    if (open >= text.len or text[open] != '(') return null;
    var depth: usize = 0;
    var in_str = false;
    var i = open;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (in_str) {
            if (c == '\\') {
                i += 1;
            } else if (c == '"') in_str = false;
            continue;
        }
        switch (c) {
            '"' => in_str = true,
            ';' => while (i < text.len and text[i] != '\n') : (i += 1) {},
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

/// Exclusive end of the form's byte span — one past `closeIndex`, so
/// `text[open..end]` is the whole form. Null on the same inputs.
pub fn endIndex(text: []const u8, open: usize) ?usize {
    return (closeIndex(text, open) orelse return null) + 1;
}
