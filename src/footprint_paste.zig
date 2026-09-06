//! Explicit rectangular stencil windows, expressed relative to a copper pad.
const std = @import("std");
const Node = @import("sexpr/ast.zig").Node;
pub const Aperture = struct { x: f64, y: f64, w: f64, h: f64 };

/// Null preserves ordinary full-pad paste; an authored empty list suppresses it.
pub fn parse(a: std.mem.Allocator, pad: Node) (std.mem.Allocator.Error || error{InvalidPaste})!?[]const Aperture {
    const items = pad.asList() orelse return null;
    for (items) |item| {
        if (!item.isForm("paste")) continue;
        const forms = item.asList().?;
        if (forms.len > 257) return error.InvalidPaste;
        var windows: std.ArrayList(Aperture) = .empty;
        for (forms[1..]) |form| {
            if (!form.isForm("rect")) return error.InvalidPaste;
            const v = form.asList().?;
            if (v.len != 5) return error.InvalidPaste;
            const rect = Aperture{ .x = v[1].asNumber() orelse return error.InvalidPaste, .y = v[2].asNumber() orelse return error.InvalidPaste, .w = v[3].asNumber() orelse return error.InvalidPaste, .h = v[4].asNumber() orelse return error.InvalidPaste };
            for ([_]f64{ rect.x, rect.y, rect.w, rect.h }) |n| if (!std.math.isFinite(n) or @abs(n) > 1000) return error.InvalidPaste;
            if (rect.w <= 0 or rect.h <= 0) return error.InvalidPaste;
            try windows.append(a, rect);
        }
        return try windows.toOwnedSlice(a);
    }
    return null;
}

/// Emit windows without creating additional pad numbers or copper.
pub fn write(w: *std.Io.Writer, windows: []const Aperture) std.Io.Writer.Error!void {
    try w.writeAll(" (paste");
    for (windows) |v| try w.print(" (rect {d:.6} {d:.6} {d:.6} {d:.6})", .{ v.x, v.y, v.w, v.h });
    try w.writeByte(')');
}

// spec: IC package builder - Paste parsing empty and malformed
test "IC package paste parsing empty and malformed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parser = @import("sexpr/parser.zig");
    const ordinary = try parser.parse(a, "(pad 1 smd rect)");
    try std.testing.expect(try parse(a, ordinary[0]) == null);
    const empty = try parser.parse(a, "(pad 1 smd rect (paste))");
    try std.testing.expectEqual(@as(usize, 0), (try parse(a, empty[0])).?.len);
    const malformed = try parser.parse(a, "(pad 1 smd rect (paste (rect 0 0 -1 1)))");
    try std.testing.expectError(error.InvalidPaste, parse(a, malformed[0]));
}

/// Check bounded rectangular windows, containment, and non-overlap before saving.
pub fn valid(windows: []const Aperture, width: f64, height: f64) bool {
    if (windows.len > 256) return false;
    for (windows, 0..) |v, i| {
        for ([_]f64{ v.x, v.y, v.w, v.h }) |n| if (!std.math.isFinite(n) or @abs(n) > 1000) return false;
        if (v.w <= 0 or v.h <= 0) return false;
        if (@abs(v.x) + v.w / 2 > width / 2 + 1e-8 or @abs(v.y) + v.h / 2 > height / 2 + 1e-8) return false;
        for (windows[0..i]) |q| if (@abs(v.x - q.x) < (v.w + q.w) / 2 - 1e-8 and @abs(v.y - q.y) < (v.h + q.h) / 2 - 1e-8) return false;
    }
    return true;
}
