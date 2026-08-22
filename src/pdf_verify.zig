//! Structural self-check for the bytes `src/pdf.zig` emits — the in-repo oracle
//! that stands in for the PDF tooling this box does not have (no qpdf, poppler,
//! or mutool). We wrote every byte, so verifying our own file-format invariants
//! is cheap and catches exactly the classes of bug a hand-rolled writer makes:
//! a cross-reference offset that drifted after an edit, a `/Length` that no
//! longer matches its stream, or a content stream whose `q`/`Q` or `BT`/`ET`
//! nesting leaked.
//!
//! Deliberately a *structural* check, not a parser: it never interprets page
//! content semantically. `src/pdf.zig`'s tests run it on every document they
//! build, the fuzz harness runs it on arbitrary operation sequences, and the
//! WP-C composer's tests reuse it on the finished review PDF.

const std = @import("std");

/// Every way a document can fail the structural self-check. Each names one
/// invariant so a test can assert the specific breakage it injected.
pub const ValidateError = error{
    /// The file does not start with a `%PDF-1.` header.
    BadHeader,
    /// No `startxref` keyword, or no integer after it.
    MissingStartxref,
    /// `startxref` names an offset that is out of range or not at an `xref`.
    BadXrefOffset,
    /// The cross-reference subsection header or an entry is malformed.
    BadXrefTable,
    /// An entry's offset does not point at that object's `N 0 obj` header.
    ObjectOffsetMismatch,
    /// The trailer's `/Size` disagrees with the entry count.
    BadTrailerSize,
    /// A stream's `/Length` disagrees with the bytes between the keywords.
    StreamLengthMismatch,
    /// A content stream's `q` / `Q` operators do not nest to zero.
    UnbalancedGraphicsState,
    /// A content stream's `BT` / `ET` operators do not pair up.
    UnbalancedTextObject,
};

/// Byte length of one cross-reference table entry (`nnnnnnnnnn ggggg n \n`),
/// fixed by the PDF spec so entry `i` sits at a computable offset.
const xref_entry_len = 20;

/// Walk `bytes` and verify the writer's structural invariants: header, the
/// cross-reference table's offsets, the trailer `/Size`, every stream's
/// `/Length`, and the operator nesting inside every stream. Returns on success.
pub fn validate(bytes: []const u8) ValidateError!void {
    if (!std.mem.startsWith(u8, bytes, "%PDF-1.")) return error.BadHeader;
    const xref_off = try startxrefOffset(bytes);
    if (xref_off >= bytes.len) return error.BadXrefOffset;
    if (!std.mem.startsWith(u8, bytes[xref_off..], "xref")) return error.BadXrefOffset;

    const table = try readXref(bytes, xref_off);
    try checkObjectOffsets(bytes, table);
    try checkTrailerSize(bytes[table.trailer_at..], table.count);
    try checkStreams(bytes);
}

/// A parsed cross-reference table: how many entries it declares, where the
/// first entry's bytes start, and where the following `trailer` keyword is.
const Xref = struct { count: usize, first_at: usize, trailer_at: usize };

/// Offset named by the file's last `startxref` keyword.
fn startxrefOffset(bytes: []const u8) ValidateError!usize {
    const at = std.mem.lastIndexOf(u8, bytes, "startxref") orelse return error.MissingStartxref;
    var i = at + "startxref".len;
    while (i < bytes.len and isSpace(bytes[i])) i += 1;
    const start = i;
    while (i < bytes.len and std.ascii.isDigit(bytes[i])) i += 1;
    if (i == start) return error.MissingStartxref;
    return std.fmt.parseInt(usize, bytes[start..i], 10) catch error.MissingStartxref;
}

/// Parse the `xref` keyword, its single `first count` subsection header, and
/// locate the `trailer` keyword that must follow the entry block.
fn readXref(bytes: []const u8, xref_off: usize) ValidateError!Xref {
    var i = xref_off + "xref".len;
    while (i < bytes.len and isSpace(bytes[i])) i += 1;
    const first = try readUint(bytes, &i);
    if (first != 0) return error.BadXrefTable;
    while (i < bytes.len and isSpace(bytes[i])) i += 1;
    const count = try readUint(bytes, &i);
    if (count == 0) return error.BadXrefTable;
    while (i < bytes.len and isSpace(bytes[i])) i += 1;
    const end = i + count * xref_entry_len;
    if (end > bytes.len) return error.BadXrefTable;
    if (!std.mem.startsWith(u8, bytes[end..], "trailer")) return error.BadXrefTable;
    return .{ .count = count, .first_at = i, .trailer_at = end };
}

/// Read a decimal integer at `*i`, advancing past it.
fn readUint(bytes: []const u8, i: *usize) ValidateError!usize {
    const start = i.*;
    while (i.* < bytes.len and std.ascii.isDigit(bytes[i.*])) i.* += 1;
    if (i.* == start) return error.BadXrefTable;
    return std.fmt.parseInt(usize, bytes[start..i.*], 10) catch error.BadXrefTable;
}

/// Whitespace bytes the PDF lexer treats as separators.
fn isSpace(c: u8) bool {
    return c == ' ' or c == '\n' or c == '\r' or c == '\t';
}

/// Entry 0 must be the free-list head; every later entry's offset must land on
/// that object's `N 0 obj` header.
fn checkObjectOffsets(bytes: []const u8, table: Xref) ValidateError!void {
    var n: usize = 0;
    while (n < table.count) : (n += 1) {
        const entry = bytes[table.first_at + n * xref_entry_len ..][0..xref_entry_len];
        const kind = entry[17];
        if (n == 0) {
            if (kind != 'f') return error.BadXrefTable;
            continue;
        }
        if (kind != 'n') return error.BadXrefTable;
        const off = std.fmt.parseInt(usize, entry[0..10], 10) catch return error.BadXrefTable;
        if (off >= bytes.len) return error.ObjectOffsetMismatch;
        var buf: [32]u8 = undefined;
        const want = std.fmt.bufPrint(&buf, "{d} 0 obj", .{n}) catch return error.BadXrefTable;
        if (!std.mem.startsWith(u8, bytes[off..], want)) return error.ObjectOffsetMismatch;
    }
}

/// The trailer dictionary's `/Size` must equal the entry count.
fn checkTrailerSize(trailer: []const u8, count: usize) ValidateError!void {
    const at = std.mem.indexOf(u8, trailer, "/Size") orelse return error.BadTrailerSize;
    var i = at + "/Size".len;
    while (i < trailer.len and isSpace(trailer[i])) i += 1;
    const size = readUint(trailer, &i) catch return error.BadTrailerSize;
    if (size != count) return error.BadTrailerSize;
}

/// For every `stream` in the file: its dictionary `/Length` must match the byte
/// count between `stream\n` and `\nendstream`, and the payload's operators must
/// nest to zero.
fn checkStreams(bytes: []const u8) ValidateError!void {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, at, "stream")) |kw| {
        // `endstream` also contains "stream"; skip those hits.
        if (kw >= 3 and std.mem.eql(u8, bytes[kw - 3 .. kw], "end")) {
            at = kw + "stream".len;
            continue;
        }
        const nl_at = kw + "stream".len;
        if (nl_at >= bytes.len or bytes[nl_at] != '\n') return error.StreamLengthMismatch;
        const data_at = nl_at + 1;
        const declared = try streamLength(bytes[0..kw]);
        const data_end = data_at + declared;
        if (data_end > bytes.len) return error.StreamLengthMismatch;
        if (!std.mem.startsWith(u8, bytes[data_end..], "\nendstream")) return error.StreamLengthMismatch;
        try checkNesting(bytes[data_at..data_end]);
        at = data_end;
    }
}

/// The `/Length` value of the dictionary immediately preceding a `stream`.
fn streamLength(before: []const u8) ValidateError!usize {
    const at = std.mem.lastIndexOf(u8, before, "/Length") orelse return error.StreamLengthMismatch;
    var i = at + "/Length".len;
    while (i < before.len and isSpace(before[i])) i += 1;
    return readUint(before, &i) catch error.StreamLengthMismatch;
}

/// Count `q`/`Q` and `BT`/`ET` operators over a content stream, skipping
/// literal `( … )` strings so a parenthesised label containing a `q` cannot
/// throw the tally off. Both must nest to zero and never go negative.
fn checkNesting(content: []const u8) ValidateError!void {
    var depth: i64 = 0;
    var text_depth: i64 = 0;
    var i: usize = 0;
    while (i < content.len) {
        if (content[i] == '(') {
            i = skipLiteral(content, i);
            continue;
        }
        const tok = tokenAt(content, &i);
        if (tok.len == 0) continue;
        if (std.mem.eql(u8, tok, "q")) depth += 1;
        if (std.mem.eql(u8, tok, "Q")) depth -= 1;
        if (std.mem.eql(u8, tok, "BT")) text_depth += 1;
        if (std.mem.eql(u8, tok, "ET")) text_depth -= 1;
        if (depth < 0) return error.UnbalancedGraphicsState;
        if (text_depth < 0 or text_depth > 1) return error.UnbalancedTextObject;
    }
    if (depth != 0) return error.UnbalancedGraphicsState;
    if (text_depth != 0) return error.UnbalancedTextObject;
}

/// Advance past a `( … )` literal string, honouring backslash escapes and
/// nested parentheses. Returns the index just after the closing paren.
fn skipLiteral(content: []const u8, open_at: usize) usize {
    var i = open_at + 1;
    var nest: usize = 1;
    while (i < content.len) {
        switch (content[i]) {
            '\\' => i += 1,
            '(' => nest += 1,
            ')' => {
                nest -= 1;
                if (nest == 0) return i + 1;
            },
            else => {},
        }
        i += 1;
    }
    return content.len;
}

/// Read the next whitespace-delimited token at `*i`, advancing past it. Returns
/// an empty slice when only separators were consumed.
fn tokenAt(content: []const u8, i: *usize) []const u8 {
    while (i.* < content.len and isSpace(content[i.*])) i.* += 1;
    const start = i.*;
    while (i.* < content.len and !isSpace(content[i.*]) and content[i.*] != '(') i.* += 1;
    return content[start..i.*];
}

test "pdf verify: a literal string hides its parentheses and operator letters" {
    // "q" inside a label must not count toward the graphics-state depth.
    try checkNesting("q\nBT\n(Q q BT \\) ) Tj\nET\nQ\n");
}

test "pdf verify: an unmatched save is rejected" {
    try std.testing.expectError(error.UnbalancedGraphicsState, checkNesting("q\nq\nQ\n"));
    try std.testing.expectError(error.UnbalancedTextObject, checkNesting("BT\n"));
}
