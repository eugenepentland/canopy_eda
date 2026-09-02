//! Splitting one Markdown pipe-table row into trimmed cells.
//!
//! Two review documents are parsed by reading their tables back — the review
//! audit's regeneration (which must carry a reviewer's Disposition column
//! forward) and the waiver register's per-board counts — and each carried its
//! own copy of the split. The copies disagreed on both edges:
//!
//!   * a line with no leading `|`. One copy refused it; the other split it
//!     anyway, so a prose line containing a pipe parsed as a two-cell row.
//!   * more cells than fit. One copy refused the row; the other truncated it,
//!     which silently re-binds every column past the cut to the wrong header.
//!
//! Refusing is right on both counts: these parsers act on what a row SAYS, and
//! a row this cannot represent faithfully must read as "not a row I know"
//! rather than as a row with different contents.
//!
//! No escaped-pipe support: neither document needs one, and inventing it here
//! would be a second dialect of Markdown rather than a shared one.

const std = @import("std");

/// Most cells a row may have. A wider table is refused, not truncated.
pub const max_cells = 16;

/// Split a pipe-table row into trimmed cells written into `out`, returning how
/// many. Zero means "not a table row this can read": no leading `|`, or more
/// than `max_cells` columns. The cells borrow `line`.
pub fn split(line: []const u8, out: *[max_cells][]const u8) usize {
    var body = std.mem.trim(u8, line, " \t\r");
    if (body.len == 0 or body[0] != '|') return 0;
    body = body[1..];
    if (body.len > 0 and body[body.len - 1] == '|') body = body[0 .. body.len - 1];
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, body, '|');
    while (it.next()) |cell| {
        if (n == out.len) return 0;
        out[n] = std.mem.trim(u8, cell, " \t");
        n += 1;
    }
    return n;
}
