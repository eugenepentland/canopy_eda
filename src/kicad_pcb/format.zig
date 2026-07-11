//! Constants describing the `.kicad_pcb` S-expression schema, shared by
//! the reader and writer so the two stay in lockstep on what counts as
//! a "structural" property vs. a custom field.

const std = @import("std");
const ast = @import("../sexpr/ast.zig");

/// `(property "Reference" "U1" …)` — the visible ref-des.
pub const PROP_REFERENCE = "Reference";
/// `(property "Value" "100nF" …)` — the visible value text.
pub const PROP_VALUE = "Value";
/// `(property "canopy_uuid" "<uuid>" …)` — our cross-sync identity tag.
pub const PROP_CANOPY_UUID = "canopy_uuid";

/// Extract a pad's number/name token (slot 1 of a `(pad …)` form) as text,
/// regardless of how it was serialised. Modern `.sexp`-generated footprints
/// quote it (`(pad "1" …)`); KiCad-5 `(module …)` sources leave alphanumeric
/// pads bare (`(pad A1 …)`); and KiCad re-saves purely-numeric pads as a bare
/// integer (`(pad 1 …)`). Reader and writer must agree on all three or a pad
/// silently drops out of the net diff and never gets wired. Returns null for
/// genuinely unnumbered pads (e.g. NPTH mounting holes with no usable token).
pub fn padNumberText(arena: std.mem.Allocator, n: ast.Node) ?[]const u8 {
    if (n.asString()) |s| return s;
    if (n.asAtom()) |a| return a;
    return switch (n.tag) {
        .int => |i| std.fmt.allocPrint(arena, "{d}", .{i}) catch null,
        else => null,
    };
}

/// True when `s` needs escaping to sit safely inside a double-quoted
/// S-expression token — i.e. it contains a raw `"` or `\`.
pub fn needsSexprEscape(s: []const u8) bool {
    return std.mem.indexOfScalar(u8, s, '"') != null or
        std.mem.indexOfScalar(u8, s, '\\') != null;
}

/// Escape `s` so it can be the payload of a `Node.string` that the printer
/// emits verbatim between quotes. The printer writes `Node.string` bytes
/// unchanged (they are assumed to already be grammar-escaped tokenizer
/// slices), so any value that reached the writer via a *different* route —
/// a JSON-decoded sync op field, an HTTP-supplied BOM value — must be
/// escaped here or a raw `"`/trailing `\` produces an unparseable
/// `.kicad_pcb` / `.bom`. Mirrors the tokenizer's `\`-escape convention
/// (`"` → `\"`, `\` → `\\`); no allocation when nothing needs escaping.
pub fn sexprEscape(arena: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error![]const u8 {
    if (!needsSexprEscape(s)) return s;
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        if (c == '"' or c == '\\') try out.append(arena, '\\');
        try out.append(arena, c);
    }
    return out.toOwnedSlice(arena);
}

/// Inverse of `sexprEscape`: decode a tokenizer string slice (with `\x`
/// escapes) back to its literal bytes. `sexprUnescape(sexprEscape(s)) == s`
/// for any `s`, and it is a no-op on text with no backslash — so decoding a
/// legacy, never-escaped value returns it unchanged. Callers that re-serialise
/// loaded `.bom` values use this on read so the writer's escape-on-write can't
/// double-escape across a load→edit→save cycle.
pub fn sexprUnescape(arena: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '\\') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len) {
            i += 1;
        }
        try out.append(arena, s[i]);
    }
    return out.toOwnedSlice(arena);
}

// spec: kicad_pcb/format - sexprUnescape inverts sexprEscape so a load→save round-trip does not double-escape
test "sexprUnescape inverts sexprEscape and is a no-op on clean text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("VIN", try sexprUnescape(a, "VIN"));
    inline for (.{ "a\"b", "path\\", "he said \"hi\" \\", "plain" }) |raw| {
        const round = try sexprUnescape(a, try sexprEscape(a, raw));
        try std.testing.expectEqualStrings(raw, round);
    }
}

// spec: kicad_pcb/format - sexprEscape escapes embedded quotes and trailing backslash so the printed token round-trips
test "sexprEscape escapes quotes and backslashes, passes clean text through" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("VIN", try sexprEscape(a, "VIN"));
    try std.testing.expectEqualStrings("a\\\"b", try sexprEscape(a, "a\"b"));
    try std.testing.expectEqualStrings("path\\\\", try sexprEscape(a, "path\\"));
    // Escaped output re-tokenizes as the ORIGINAL bytes (round-trip proof).
    const tok = @import("../sexpr/tokenizer.zig");
    const raw = "he said \"hi\" \\";
    const esc = try sexprEscape(a, raw);
    const quoted = try std.fmt.allocPrint(a, "\"{s}\"", .{esc});
    var tokenizer = tok.Tokenizer.init(quoted);
    const t = try tokenizer.next();
    try std.testing.expectEqual(tok.TokenTag.string, t.tag);
    // The tokenizer captures the escaped bytes between the quotes; decoding
    // `\x`→`x` must recover the raw input exactly.
    var decoded: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < t.text.len) : (i += 1) {
        if (t.text[i] == '\\' and i + 1 < t.text.len) i += 1;
        try decoded.append(a, t.text[i]);
    }
    try std.testing.expectEqualStrings(raw, decoded.items);
}

// spec: kicad_pcb/format - padNumberText reads quoted, bare-atom, and bare-int pad numbers
test "padNumberText reads quoted, bare-atom, and bare-int pad numbers" {
    const parser = @import("../sexpr/parser.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const quoted = (try parser.parse(a, "(pad \"1\" smd)"))[0].asList().?[1];
    const atom = (try parser.parse(a, "(pad A1 smd)"))[0].asList().?[1];
    const int = (try parser.parse(a, "(pad 2 smd)"))[0].asList().?[1];
    try std.testing.expectEqualStrings("1", padNumberText(a, quoted).?);
    try std.testing.expectEqualStrings("A1", padNumberText(a, atom).?);
    try std.testing.expectEqualStrings("2", padNumberText(a, int).?);
}
