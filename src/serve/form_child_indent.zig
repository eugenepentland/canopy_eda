//! The indent a splice into an existing `.sexp` form should use.
//!
//! Every write-back that inserts a child into a form — a `(datasheet …)` into
//! a component, a part into a `(section …)` — wants the file's own indent
//! style rather than a fixed two spaces, and two copies of that eight-line
//! scan had drifted apart to nothing but their parameter names. One rule, so a
//! change to it (tabs, a deeper convention) reaches every splice at once.

const std = @import("std");

/// Fallback for a form that has no child line to copy: two spaces, the
/// convention every generated `.sexp` in the tree is written in.
pub const default_indent = "  ";

/// The leading whitespace of the first line after the one `form_start` sits
/// on — i.e. the indent of the form's first child.
///
/// Returns `default_indent` when the form is written on a single line (no
/// newline after it) or its next line starts hard against the margin, which
/// covers both "the form is empty" and "the file has no indent style here".
/// The returned slice borrows `source`.
pub fn firstChild(source: []const u8, form_start: usize) []const u8 {
    var i: usize = form_start;
    while (i < source.len and source[i] != '\n') : (i += 1) {}
    if (i >= source.len) return default_indent;
    i += 1;
    const indent_start = i;
    while (i < source.len and (source[i] == ' ' or source[i] == '\t')) : (i += 1) {}
    if (i == indent_start) return default_indent;
    return source[indent_start..i];
}
