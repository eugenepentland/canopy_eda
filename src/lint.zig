//! Id-hygiene linter. Reports the legacy `(id …)` residue and token problems
//! that accumulated before stable child-id sidecars existed (see
//! docs/uuid_research.md failure mode F6):
//!   - `(id …)` forms attached to `(note …)` / `(net …)` forms (never map to a
//!     component, so the token is dead);
//!   - nested `(id X (id Y) …)` forms (only the first token is ever parsed);
//!   - tokens that aren't 8 hex chars starting a–f (e.g. a hand-typed one);
//!   - the same token used on two forms.
//! Report-only: it points at the lines so they can be cleaned by hand or by a
//! later `--fix` pass; it never rewrites source.

const std = @import("std");
const ast = @import("sexpr/ast.zig");
const parser_mod = @import("sexpr/parser.zig");
const infra_fs = @import("infra/fs.zig");

const Node = ast.Node;

pub const LintError = std.mem.Allocator.Error ||
    std.fs.File.OpenError ||
    std.fs.File.ReadError ||
    error{ FileTooBig, StreamTooLong, EndOfStream, ParseError };

const Ctx = struct {
    path: []const u8,
    /// token → 1-based line of first occurrence, for duplicate detection.
    seen: std.StringHashMap(u32),
    count: usize = 0,
};

/// Lint a single `.sexp` file, printing one line per issue to stderr. Returns
/// the number of issues found (0 = clean).
pub fn lintFile(allocator: std.mem.Allocator, path: []const u8) LintError!usize {
    const source = try infra_fs.cwd().readFileAlloc(allocator, path, 10 * 1024 * 1024);
    const nodes = parser_mod.parse(allocator, source) catch return LintError.ParseError;
    var ctx = Ctx{ .path = path, .seen = std.StringHashMap(u32).init(allocator) };
    defer ctx.seen.deinit();
    for (nodes) |n| walk(&ctx, n);
    return ctx.count;
}

fn report(ctx: *Ctx, line: u32, kind: []const u8, tok: []const u8) void {
    std.debug.print("{s}:{d}: {s}: '{s}'\n", .{ ctx.path, line, kind, tok });
    ctx.count += 1;
}

fn walk(ctx: *Ctx, node: Node) void {
    const children = node.asList() orelse return;
    if (children.len == 0) return;
    const head = children[0].asAtom() orelse {
        for (children) |c| walk(ctx, c);
        return;
    };

    if (std.mem.eql(u8, head, "id")) {
        if (children.len >= 2) checkToken(ctx, children[1]);
        if (children.len > 2) report(ctx, node.span.line, "nested-id", head);
        for (children[1..]) |c| walk(ctx, c);
        return;
    }
    if (std.mem.eql(u8, head, "ids")) {
        for (children[1..]) |pair_node| {
            const pair = pair_node.asList() orelse continue;
            if (pair.len >= 2) checkToken(ctx, pair[1]);
        }
        return;
    }
    if (std.mem.eql(u8, head, "note") or std.mem.eql(u8, head, "net")) {
        for (children[1..]) |c| {
            if (c.isForm("id")) {
                report(ctx, node.span.line, "id-on-non-component", head);
                break;
            }
        }
    }
    for (children[1..]) |c| walk(ctx, c);
}

fn checkToken(ctx: *Ctx, node: Node) void {
    const tok = node.asAtom() orelse (node.asString() orelse return);
    if (!isValidToken(tok)) report(ctx, node.span.line, "bad-token", tok);
    const gop = ctx.seen.getOrPut(tok) catch return;
    if (gop.found_existing) {
        report(ctx, node.span.line, "duplicate-id", tok);
    } else {
        gop.value_ptr.* = node.span.line;
    }
}

/// A well-formed token is exactly 8 chars: first in a–f, rest hex digits. This
/// matches what `generateId` produces and rejects hand-typed near-misses.
fn isValidToken(tok: []const u8) bool {
    if (tok.len != 8) return false;
    if (tok[0] < 'a' or tok[0] > 'f') return false;
    for (tok) |c| {
        const is_hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        if (!is_hex) return false;
    }
    return true;
}

// spec: lint - flags an (id …) form attached to a note or net
// spec: lint - flags a nested (id (id …)) residue form
// spec: lint - flags a token that is not 8 hex chars starting a-f
// spec: lint - flags a duplicate id token within one design
test "lint detects residue and bad tokens" {
    const alloc = std.testing.allocator;
    const src =
        \\(design-block "t"
        \\  (note "x" (id db0a04fb))
        \\  (net "GND" (id fd3769fb))
        \\  (instance "R1" comp (id cfc02418 (id b422d7a1)))
        \\  (instance "R2" comp (id c0de5wd6))
        \\  (instance "R3" comp (id fd3769fb)))
    ;
    const nodes = try parser_mod.parse(alloc, src);
    defer parser_mod.freeNodes(alloc, nodes);
    var ctx = Ctx{ .path = "t.sexp", .seen = std.StringHashMap(u32).init(alloc) };
    defer ctx.seen.deinit();
    for (nodes) |n| walk(&ctx, n);
    // id-on-note, id-on-net, nested-id, bad-token (c0de5wd6),
    // duplicate-id (fd3769fb reused). = 5 issues.
    try std.testing.expectEqual(@as(usize, 5), ctx.count);
}

test "lint passes a clean design" {
    const alloc = std.testing.allocator;
    const src =
        \\(design-block "t"
        \\  (instance "R1" comp (id cfc02418))
        \\  (decouple "VDD" (cap "100nF") 1 per-pin R1 (id a1b2c3d4)
        \\    (ids ("100nF@1#0" e5f6a7b8))))
    ;
    const nodes = try parser_mod.parse(alloc, src);
    defer parser_mod.freeNodes(alloc, nodes);
    var ctx = Ctx{ .path = "t.sexp", .seen = std.StringHashMap(u32).init(alloc) };
    defer ctx.seen.deinit();
    for (nodes) |n| walk(&ctx, n);
    try std.testing.expectEqual(@as(usize, 0), ctx.count);
}
