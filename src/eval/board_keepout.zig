//! `(board … (keepout "name" (rect X Y W H) (side top|bottom|both) …))` parsing.
//!
//! The AUTHORED counterpart of the perimeter band in `design_block.parsePerimeterFence`.
//! A perimeter keepout is derived — move the outline or the fence and the band
//! follows — so a malformed one degrades to a warning and an inert band. This
//! form states a mechanical fact instead: a rectangle of board that a heatsink
//! plate, a shield can or a bracket already owns. There is nothing to fall back
//! to, and a silently dropped region reads on every surface exactly like a board
//! that never reserved the space. So every malformed field here is an
//! evaluation ERROR carrying the offending node's span, and the build stops.
//!
//! The rectangle is board-local millimetres from the outline's top-left — the
//! same frame `(heatsink (rect …))` uses, because both are read off the same
//! mechanical drawing.

const std = @import("std");
const ast = @import("../sexpr/ast.zig");
const env = @import("env.zig");
const evaluator_mod = @import("evaluator.zig");

const Evaluator = evaluator_mod.Evaluator;
const EvalError = evaluator_mod.EvalError;
const Node = ast.Node;

/// Millimetre slack when testing the rectangle against the outline, so an
/// exactly edge-flush region (the common case — the plate runs to the board
/// edge) is not rejected by floating-point noise.
pub const edge_tolerance_mm: f64 = 1e-6;

/// `(side top|bottom|both)` keyword → face selection; null for anything else.
pub fn sideFromAtom(word: []const u8) ?env.BoardKeepoutSide {
    if (std.mem.eql(u8, word, "top")) return .top;
    if (std.mem.eql(u8, word, "bottom")) return .bottom;
    if (std.mem.eql(u8, word, "both")) return .both;
    return null;
}

const Rect = struct { x: f64, y: f64, w: f64, h: f64 };

/// Working state while one `(keepout …)` body is read, so each sub-form parser
/// stays a few lines and the completeness check has one place to look.
const Draft = struct {
    name: []const u8,
    rect: ?Rect = null,
    side: ?env.BoardKeepoutSide = null,
    blocks: ?env.PerimeterKeepoutBlocks = null,
    allow_nets: []const []const u8 = &.{},
    reason: []const u8 = "",
};

/// `(rect X Y W H)`, board-local mm. Non-positive extents are rejected here:
/// a zero-area region reserves nothing and would read as an accepted keepout.
fn readRect(self: *Evaluator, draft: *Draft, rule: []const Node) EvalError!void {
    if (rule.len != 5) return fail(self, rule[0], "(keepout … (rect X Y W H)) needs exactly four millimetre numbers");
    var v: [4]f64 = undefined;
    for (rule[1..5], &v) |node, *out| {
        out.* = node.asNumber() orelse return fail(self, node, "(keepout … (rect X Y W H)) needs four millimetre numbers");
    }
    if (!(v[2] > 0) or !(v[3] > 0)) {
        return fail(self, rule[0], "(keepout … (rect X Y W H)) needs a positive width and height");
    }
    draft.rect = .{ .x = v[0], .y = v[1], .w = v[2], .h = v[3] };
}

/// `(side top|bottom|both)`.
fn readSide(self: *Evaluator, draft: *Draft, rule: []const Node) EvalError!void {
    if (rule.len != 2) return fail(self, rule[0], "(keepout … (side top|bottom|both)) needs exactly one face word");
    const word = rule[1].asAtom() orelse rule[1].asString() orelse "";
    draft.side = sideFromAtom(word) orelse
        return failFmt(self, rule[1], "unknown keepout side '{s}' — expected top, bottom, or both", .{word});
}

/// `(blocks components tracks vias)` — a listed family is forbidden in the
/// region. An empty list is rejected: it declares a keepout that keeps nothing.
fn readBlocks(self: *Evaluator, draft: *Draft, rule: []const Node) EvalError!void {
    var blocks: env.PerimeterKeepoutBlocks = .{};
    for (rule[1..]) |node| {
        const word = node.asString() orelse node.asAtom() orelse "";
        if (std.mem.eql(u8, word, "components")) {
            blocks.components = true;
        } else if (std.mem.eql(u8, word, "tracks")) {
            blocks.tracks = true;
        } else if (std.mem.eql(u8, word, "vias")) {
            blocks.vias = true;
        } else {
            return failFmt(self, node, "unknown keepout feature '{s}' — expected components, tracks, or vias", .{word});
        }
    }
    if (!blocksAnything(blocks)) {
        return fail(self, rule[0], "(keepout … (blocks …)) needs at least one of components, tracks, vias");
    }
    draft.blocks = blocks;
}

/// Does this policy forbid at least one physical family?
fn blocksAnything(b: env.PerimeterKeepoutBlocks) bool {
    return b.components or b.tracks or b.vias;
}

/// `(allow-nets "GND" …)` — copper admitted through the region anyway.
fn readAllowNets(self: *Evaluator, draft: *Draft, rule: []const Node) EvalError!void {
    var nets: std.ArrayList([]const u8) = .empty;
    for (rule[1..]) |node| {
        const name = node.asString() orelse node.asAtom() orelse
            return fail(self, node, "(keepout … (allow-nets …)) takes net names");
        nets.append(self.allocator, name) catch return EvalError.OutOfMemory;
    }
    draft.allow_nets = nets.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory;
}

/// Dispatch one `(keepout …)` sub-form. An unrecognised head is an error, not
/// a skip: a typo'd option would otherwise silently widen the region's policy.
fn readOption(self: *Evaluator, draft: *Draft, node: Node) EvalError!void {
    const rule = node.asList() orelse return fail(self, node, "(keepout …) options are lists, e.g. (rect X Y W H)");
    if (rule.len < 1) return fail(self, node, "(keepout …) options are lists, e.g. (rect X Y W H)");
    const head = rule[0].asAtom() orelse return fail(self, rule[0], "(keepout …) option heads are bare words");
    if (std.mem.eql(u8, head, "rect")) return readRect(self, draft, rule);
    if (std.mem.eql(u8, head, "side")) return readSide(self, draft, rule);
    if (std.mem.eql(u8, head, "blocks")) return readBlocks(self, draft, rule);
    if (std.mem.eql(u8, head, "allow-nets")) return readAllowNets(self, draft, rule);
    if (std.mem.eql(u8, head, "reason")) {
        draft.reason = if (rule.len >= 2) rule[1].asString() orelse rule[1].asAtom() orelse "" else "";
        return;
    }
    return failFmt(self, rule[0], "unknown board (keepout …) sub-form ({s} …)", .{head});
}

/// The rectangle must lie wholly inside the declared outline. A region hanging
/// off the board describes space the fabricator never delivers, and silently
/// clipping it would enforce a smaller keepout than the author wrote.
fn checkWithin(self: *Evaluator, node: Node, rect: Rect, w: f64, h: f64) EvalError!void {
    const t = edge_tolerance_mm;
    if (rect.x >= -t and rect.y >= -t and rect.x + rect.w <= w + t and rect.y + rect.h <= h + t) return;
    return failFmt(
        self,
        node,
        "(keepout … (rect {d} {d} {d} {d})) lies outside the declared {d} x {d} mm outline — " ++
            "the rectangle is board-local mm from the outline's top-left",
        .{ rect.x, rect.y, rect.w, rect.h, w, h },
    );
}

/// Parse one `(keepout "name" …)` child of a `(board …)` form against an
/// outline of `w` x `h` mm.
fn parseOne(self: *Evaluator, node: Node, children: []const Node, w: f64, h: f64) EvalError!env.BoardKeepoutSpec {
    if (children.len < 1) return fail(self, node, "(keepout …) needs a name, e.g. (keepout \"heatsink plate\" …)");
    var draft: Draft = .{
        .name = children[0].asString() orelse children[0].asAtom() orelse
            return fail(self, children[0], "(keepout …) needs a quoted name as its first argument"),
    };
    if (draft.name.len == 0) return fail(self, children[0], "(keepout …) needs a non-empty name");
    for (children[1..]) |option| try readOption(self, &draft, option);
    const rect = draft.rect orelse return fail(self, node, "(keepout …) needs a (rect X Y W H)");
    const side = draft.side orelse return fail(self, node, "(keepout …) needs a (side top|bottom|both)");
    try checkWithin(self, node, rect, w, h);
    return .{
        .name = draft.name,
        .rect = .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h },
        .side = side,
        .blocks = draft.blocks orelse .{ .components = true, .tracks = true, .vias = true },
        .allow_nets = draft.allow_nets,
        .reason = draft.reason,
    };
}

/// Every `(keepout …)` child of a `(board …)` form, in authored order, checked
/// against the outline the same form declares. `w`/`h` are that outline in mm;
/// a board with no `(size …)` is inert, so its regions warn and are dropped
/// rather than being validated against a zero-area board.
pub fn parseAll(
    self: *Evaluator,
    form_children: []const Node,
    w: f64,
    h: f64,
) EvalError![]const env.BoardKeepoutSpec {
    var out: std.ArrayList(env.BoardKeepoutSpec) = .empty;
    for (form_children) |child| {
        const c = child.asList() orelse continue;
        if (c.len < 1) continue;
        if (!std.mem.eql(u8, c[0].asAtom() orelse "", "keepout")) continue;
        if (!(w > 0) or !(h > 0)) {
            self.warnFmt(c[0].span, "(board … (keepout …)) is inert without a (size W H) outline", .{});
            continue;
        }
        out.append(self.allocator, try parseOne(self, child, c[1..], w, h)) catch return EvalError.OutOfMemory;
    }
    return out.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory;
}

fn fail(self: *Evaluator, node: Node, message: []const u8) EvalError {
    self.setError(node.span, message);
    return EvalError.InvalidForm;
}

fn failFmt(self: *Evaluator, node: Node, comptime fmt: []const u8, args: anytype) EvalError {
    self.setErrorFmt(node.span, fmt, args);
    return EvalError.InvalidForm;
}

const testing = std.testing;
const sexpr_parser = @import("../sexpr/parser.zig");
const design_block = @import("design_block.zig");

/// Evaluate one `(design-block …)` source and hand back its board declaration,
/// or the evaluation error the malformed form raised.
fn boardOf(alloc: std.mem.Allocator, src: []const u8) !env.BoardSpec {
    const nodes = try sexpr_parser.parse(alloc, src);
    const form = nodes[0].asList() orelse return error.TestUnexpectedResult;
    var eval = Evaluator.init(alloc, "");
    var scope = env.Env.init(alloc, null);
    const value = try design_block.evalDesignBlock(&eval, form[1..], &scope);
    return value.design_block.board;
}

// spec: eval/design_block - board form parses repeatable authored keepout regions with their side, blocked families, allowed nets, and reason
test "a board form carries every authored keepout region it declares" {
    const board = try boardOf(std.heap.page_allocator,
        \\(design-block "test"
        \\  (board (size 80 55)
        \\    (keepout "heatsink plate"
        \\      (rect 47.5 0 15 8.9)
        \\      (side bottom)
        \\      (allow-nets "GND")
        \\      (reason "bottom-side conduction plate"))
        \\    (keepout "antenna window"
        \\      (rect 2 2 10 10)
        \\      (side both)
        \\      (blocks tracks vias))))
    );
    try testing.expectEqual(@as(usize, 2), board.keepouts.len);

    const plate = board.keepouts[0];
    try testing.expectEqualStrings("heatsink plate", plate.name);
    try testing.expectApproxEqAbs(@as(f64, 47.5), plate.rect.x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 8.9), plate.rect.h, 1e-9);
    try testing.expectEqual(env.BoardKeepoutSide.bottom, plate.side);
    // No `(blocks …)` ⇒ every family, the same default the perimeter band takes.
    try testing.expect(plate.blocks.components and plate.blocks.tracks and plate.blocks.vias);
    try testing.expectEqualStrings("GND", plate.allow_nets[0]);
    try testing.expectEqualStrings("bottom-side conduction plate", plate.reason);

    const window = board.keepouts[1];
    try testing.expectEqual(env.BoardKeepoutSide.both, window.side);
    try testing.expect(!window.blocks.components);
    try testing.expect(window.blocks.tracks and window.blocks.vias);
    try testing.expectEqual(@as(usize, 0), window.allow_nets.len);
    try testing.expectEqualStrings("", window.reason);
}

// spec: eval/design_block - an authored board keepout with a rectangle outside the outline, a non-positive size, an unknown side or blocks word, or a missing rect or side is an evaluation error
test "a malformed board keepout stops the build instead of degrading" {
    const a = std.heap.page_allocator;
    const cases = [_][]const u8{
        // Off the right edge of an 80 x 55 outline.
        \\(design-block "t" (board (size 80 55) (keepout "k" (rect 78 2 10 5) (side top))))
        ,
        // Above the outline's top edge.
        \\(design-block "t" (board (size 80 55) (keepout "k" (rect 2 -1 10 5) (side top))))
        ,
        \\(design-block "t" (board (size 80 55) (keepout "k" (rect 2 2 0 5) (side top))))
        ,
        \\(design-block "t" (board (size 80 55) (keepout "k" (rect 2 2 10 5) (side sideways))))
        ,
        \\(design-block "t" (board (size 80 55) (keepout "k" (rect 2 2 10 5) (side top) (blocks pours))))
        ,
        \\(design-block "t" (board (size 80 55) (keepout "k" (rect 2 2 10 5) (side top) (blocks))))
        ,
        \\(design-block "t" (board (size 80 55) (keepout "k" (side top))))
        ,
        \\(design-block "t" (board (size 80 55) (keepout "k" (rect 2 2 10 5))))
        ,
        \\(design-block "t" (board (size 80 55) (keepout "k" (rect 2 2 10 5) (side top) (bloks vias))))
        ,
        \\(design-block "t" (board (size 80 55) (keepout (rect 2 2 10 5) (side top))))
        ,
    };
    for (cases) |src| try testing.expectError(EvalError.InvalidForm, boardOf(a, src));

    // The exactly edge-flush rectangle the barracuda plate needs is legal.
    const flush = try boardOf(a,
        \\(design-block "t" (board (size 80 55) (keepout "k" (rect 0 0 80 55) (side both))))
    );
    try testing.expectEqual(@as(usize, 1), flush.keepouts.len);
}
