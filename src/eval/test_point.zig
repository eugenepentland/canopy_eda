const std = @import("std");
const ast = @import("../sexpr/ast.zig");
const env_mod = @import("env.zig");

const Node = ast.Node;
const TestPoint = env_mod.TestPoint;
const TestPointTag = env_mod.TestPointTag;

/// Parse a `(test-point "TP1" "NET" (purpose "...") (required-for tag1 tag2))`
/// form into a `TestPoint`. Returns null when the positional ref-des or net
/// is missing — caller handles the malformed-form case (typically by
/// emitting a parse warning and skipping the form).
///
/// Sub-form recognition is forgiving: unknown sub-forms are silently
/// ignored so the language can grow new optional annotations without
/// breaking older designs. Unknown tags inside `(required-for …)` are
/// likewise dropped, surfaced (eventually) by a separate lint rather than
/// a hard parse error.
///
/// The returned slice for `required_for` is freshly allocated; strings in
/// `ref_des`, `net`, and `purpose` are borrowed from the source AST.
pub fn parse(
    allocator: std.mem.Allocator,
    form_children: []const Node,
) std.mem.Allocator.Error!?TestPoint {
    // form_children[0] is the head atom ("test-point"); positional args
    // start at index 1.
    if (form_children.len < 3) return null;
    const ref_des = form_children[1].asString() orelse return null;
    const net = form_children[2].asString() orelse return null;

    var purpose: []const u8 = "";
    var tags: std.ArrayListUnmanaged(TestPointTag) = .empty;
    defer tags.deinit(allocator);

    for (form_children[3..]) |sub| {
        const sub_list = sub.asList() orelse continue;
        if (sub_list.len < 2) continue;
        const head = sub_list[0].asAtom() orelse continue;

        if (std.mem.eql(u8, head, "purpose")) {
            if (sub_list[1].asString()) |s| purpose = s;
        } else if (std.mem.eql(u8, head, "required-for")) {
            for (sub_list[1..]) |tag_node| {
                const tag_atom = tag_node.asAtom() orelse continue;
                if (parseTag(tag_atom)) |t| try tags.append(allocator, t);
            }
        }
        // Unknown sub-forms ignored on purpose.
    }

    return .{
        .ref_des = ref_des,
        .net = net,
        .purpose = purpose,
        .required_for = try tags.toOwnedSlice(allocator),
    };
}

fn parseTag(s: []const u8) ?TestPointTag {
    if (std.mem.eql(u8, s, "bring-up")) return .bring_up;
    if (std.mem.eql(u8, s, "power")) return .power;
    if (std.mem.eql(u8, s, "clock")) return .clock;
    if (std.mem.eql(u8, s, "reset")) return .reset;
    if (std.mem.eql(u8, s, "debug")) return .debug;
    if (std.mem.eql(u8, s, "signal")) return .signal;
    return null;
}

// ── Tests ──────────────────────────────────────────────────────────────

const parser = @import("../sexpr/parser.zig");

fn parseFirstForm(allocator: std.mem.Allocator, source: []const u8) ![]const Node {
    const nodes = try parser.parse(allocator, source);
    return nodes[0].asList().?;
}

fn freeTestPoint(allocator: std.mem.Allocator, tp: TestPoint) void {
    if (tp.required_for.len > 0) allocator.free(tp.required_for);
}

// spec: eval/test_point - Parses ref-des and net from the first two positional arguments
test "parse reads ref_des and net positionally" {
    const alloc = std.testing.allocator;
    const nodes = try parser.parse(alloc, "(test-point \"TP1\" \"VDD_3V3\")");
    defer parser.freeNodes(alloc, nodes);
    const form = nodes[0].asList().?;

    const tp = (try parse(alloc, form)).?;
    defer freeTestPoint(alloc, tp);
    try std.testing.expectEqualStrings("TP1", tp.ref_des);
    try std.testing.expectEqualStrings("VDD_3V3", tp.net);
}

// spec: eval/test_point - Parses an optional (purpose "...") sub-form into the purpose field
test "parse extracts purpose sub-form" {
    const alloc = std.testing.allocator;
    const nodes = try parser.parse(alloc, "(test-point \"TP1\" \"VDD_3V3\" (purpose \"3.3V rail probe\"))");
    defer parser.freeNodes(alloc, nodes);
    const form = nodes[0].asList().?;

    const tp = (try parse(alloc, form)).?;
    defer freeTestPoint(alloc, tp);
    try std.testing.expectEqualStrings("3.3V rail probe", tp.purpose);
}

// spec: eval/test_point - Parses (required-for ...) sub-form recognizing bring-up power clock reset debug and signal tags
test "parse collects required-for tags" {
    const alloc = std.testing.allocator;
    const nodes = try parser.parse(alloc, "(test-point \"TP1\" \"VDD_3V3\" (required-for bring-up power clock reset debug signal))");
    defer parser.freeNodes(alloc, nodes);
    const form = nodes[0].asList().?;

    const tp = (try parse(alloc, form)).?;
    defer freeTestPoint(alloc, tp);
    try std.testing.expectEqual(@as(usize, 6), tp.required_for.len);
    try std.testing.expectEqual(TestPointTag.bring_up, tp.required_for[0]);
    try std.testing.expectEqual(TestPointTag.power, tp.required_for[1]);
    try std.testing.expectEqual(TestPointTag.clock, tp.required_for[2]);
    try std.testing.expectEqual(TestPointTag.reset, tp.required_for[3]);
    try std.testing.expectEqual(TestPointTag.debug, tp.required_for[4]);
    try std.testing.expectEqual(TestPointTag.signal, tp.required_for[5]);
}

// spec: eval/test_point - Returns null when ref-des or net positional arguments are missing
test "parse returns null when positional args missing" {
    const alloc = std.testing.allocator;
    const nodes = try parser.parse(alloc, "(test-point)");
    defer parser.freeNodes(alloc, nodes);
    const form = nodes[0].asList().?;

    try std.testing.expect((try parse(alloc, form)) == null);
}

// spec: eval/test_point - Ignores unknown sub-forms and unknown required-for tags
test "parse ignores unknown sub-forms and tags" {
    const alloc = std.testing.allocator;
    const nodes = try parser.parse(alloc, "(test-point \"TP1\" \"VDD_3V3\" (random-thing \"abc\") (required-for power gibberish))");
    defer parser.freeNodes(alloc, nodes);
    const form = nodes[0].asList().?;

    const tp = (try parse(alloc, form)).?;
    defer freeTestPoint(alloc, tp);
    try std.testing.expectEqual(@as(usize, 1), tp.required_for.len);
    try std.testing.expectEqual(TestPointTag.power, tp.required_for[0]);
}
