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

test "padNumberText reads quoted, bare-atom, and bare-int pad numbers" {
    const parser = @import("../sexpr/parser.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // spec: kicad_pcb/format - padNumberText reads quoted, bare-atom, and bare-int pad numbers
    const quoted = (try parser.parse(a, "(pad \"1\" smd)"))[0].asList().?[1];
    const atom = (try parser.parse(a, "(pad A1 smd)"))[0].asList().?[1];
    const int = (try parser.parse(a, "(pad 2 smd)"))[0].asList().?[1];
    try std.testing.expectEqualStrings("1", padNumberText(a, quoted).?);
    try std.testing.expectEqualStrings("A1", padNumberText(a, atom).?);
    try std.testing.expectEqualStrings("2", padNumberText(a, int).?);
}
