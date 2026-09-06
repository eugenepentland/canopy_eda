//! Optional component assignment, prepared before a package transaction commits.
const std = @import("std");
const fs = @import("../infra/fs.zig");
const parser = @import("../sexpr/parser.zig");
const Node = @import("../sexpr/ast.zig").Node;
const library = @import("library.zig");
const gen = @import("package_generator.zig");
const bounds = @import("../sexp_form_bounds.zig");
pub const Change = struct { path: []const u8, bytes: []const u8 };
fn text(a: std.mem.Allocator, n: Node) ![]const u8 {
    if (n.asString()) |v| return v;
    if (n.asAtom()) |v| return v;
    if (n.asNumber()) |v| return std.fmt.allocPrint(a, "{d}", .{v});
    return error.InvalidPinout;
}

/// Require an existing local component and an exactly matching pinout before assignment.
pub fn prepare(a: std.mem.Allocator, project: []const u8, name: []const u8, r: gen.Recipe, pads: []const gen.Pad) (std.mem.Allocator.Error || std.Io.Dir.ReadFileAllocError || parser.ParseError || error{ InvalidName, InvalidPinout, InvalidComponent, PinoutMismatch })!Change {
    if (!library.isSafeLibName(name)) return error.InvalidName;
    const path = try std.fmt.allocPrint(a, "{s}/lib/components/{s}.sexp", .{ project, name });
    const source = try fs.cwd().readFileAlloc(a, path, 256 * 1024);
    const nodes = try parser.parse(a, source);
    if (nodes.len != 1 or !nodes[0].isForm("component")) return error.InvalidComponent;
    const children = nodes[0].asList().?;
    var pinout: ?[]const u8 = null;
    var fp: ?Node = null;
    for (children) |node| {
        const v = node.asList() orelse continue;
        if (node.isForm("pinout") and v.len == 2) pinout = try text(a, v[1]);
        if (node.isForm("footprint")) {
            if (fp != null) return error.InvalidComponent;
            fp = node;
        }
    }
    const po = pinout orelse return error.InvalidPinout;
    if (!library.isSafeLibName(po)) return error.InvalidPinout;
    const sub = try std.fmt.allocPrint(a, "lib/pinouts/{s}.sexp", .{po});
    const pin_source = @import("../stdlib.zig").read(a, project, sub, 256 * 1024) orelse return error.InvalidPinout;
    const pin_nodes = try parser.parse(a, pin_source);
    if (pin_nodes.len != 1 or !pin_nodes[0].isForm("pinout")) return error.InvalidPinout;
    var ids: std.StringHashMapUnmanaged(void) = .empty;
    for (pin_nodes[0].asList().?) |node| if (node.isForm("pin")) {
        const v = node.asList().?;
        if (v.len < 2) return error.InvalidPinout;
        try ids.put(a, try text(a, v[1]), {});
    };
    if (ids.count() != pads.len) return error.PinoutMismatch;
    for (pads) |p| if (!ids.contains(p.id)) return error.PinoutMismatch;
    const replacement = try std.fmt.allocPrint(a, "(footprint \"{s}\")", .{r.name});
    if (fp) |node| {
        const start = node.span.offset;
        const end = bounds.endIndex(source, start) orelse return error.InvalidComponent;
        return .{ .path = path, .bytes = try std.mem.concat(a, u8, &.{ source[0..start], replacement, source[end..] }) };
    }
    const close = (bounds.endIndex(source, nodes[0].span.offset) orelse return error.InvalidComponent) - 1;
    return .{ .path = path, .bytes = try std.mem.concat(a, u8, &.{ source[0..close], "\n  ", replacement, "\n", source[close..] }) };
}

// spec: IC package builder - Component assignment requires exact pinout compatibility and joins the package save transaction
test "IC package component assignment preserves source and rejects mismatched pins" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    try tmp.dir.createDirPath(std.testing.io, "lib/components");
    try tmp.dir.createDirPath(std.testing.io, "lib/pinouts");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/components/ic.sexp", .data = "; retain this comment\n(component \"ic\" (pinout \"ic\") (footprint \"old\"))\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/pinouts/ic.sexp", .data = "(pinout \"ic\" (pin 1 \"A\") (pin 2 \"B\") (pin 3 \"C\") (pin 4 \"D\") (pin 5 \"E\") (pin 6 \"F\"))" });
    var r = gen.template(.dfn);
    r.name = "new-dfn";
    r.dimensions_verified = true;
    const pads = try gen.basePads(a, r);
    const change = try prepare(a, root, "ic", r, pads);
    try std.testing.expect(std.mem.startsWith(u8, change.bytes, "; retain this comment\n"));
    try std.testing.expect(std.mem.indexOf(u8, change.bytes, "(footprint \"new-dfn\")") != null);
    _ = try @import("package_store.zig").saveAttached(a, root, r, "ic");
    const assigned = try fs.cwd().readFileAlloc(a, change.path, 4096);
    try std.testing.expectEqualStrings(change.bytes, assigned);
    try std.testing.expectError(error.PinoutMismatch, prepare(a, root, "ic", r, pads[0..2]));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/components/ic.sexp", .data = "(component \"ic\")" });
    try std.testing.expectError(error.InvalidPinout, prepare(a, root, "ic", r, pads));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/components/ic.sexp", .data = "(footprint \"ic\")" });
    try std.testing.expectError(error.InvalidComponent, prepare(a, root, "ic", r, pads));
}
