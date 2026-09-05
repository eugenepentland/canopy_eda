//! Standalone SVG export of the same footprint description the browser renders.
const std = @import("std");
const preview = @import("footprint_preview.zig");
const escape = @import("../escape.zig");
const V = std.json.Value;
fn value(v: V, key: []const u8) V {
    return if (v == .object) v.object.get(key) orelse .null else .null;
}
fn number(v: V) f64 {
    return switch (v) {
        .float => v.float,
        .integer => @floatFromInt(v.integer),
        else => 0,
    };
}
fn n(v: V, key: []const u8) f64 {
    return number(value(v, key));
}
fn items(v: V) []const V {
    return if (v == .array) v.array.items else &.{};
}
fn points(w: *std.Io.Writer, poly: V) !void {
    for (items(poly), 0..) |p, i| {
        const q = items(p);
        if (q.len != 2) continue;
        if (i > 0) try w.writeByte(' ');
        try w.print("{d},{d}", .{ number(q[0]), number(q[1]) });
    }
}
fn layer(w: *std.Io.Writer, v: V, color: []const u8) !void {
    try w.print("<g fill=\"none\" stroke=\"{s}\" stroke-width=\".04\">", .{color});
    for (items(value(v, "rects"))) |rect| {
        const p = items(rect);
        if (p.len != 4) continue;
        try w.print("<rect x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\"/>", .{ @min(number(p[0]), number(p[2])), @min(number(p[1]), number(p[3])), @abs(number(p[2]) - number(p[0])), @abs(number(p[3]) - number(p[1])) });
    }
    for (items(value(v, "lines"))) |line| {
        const p = items(line);
        if (p.len != 4) continue;
        try w.print("<line x1=\"{d}\" y1=\"{d}\" x2=\"{d}\" y2=\"{d}\"/>", .{ number(p[0]), number(p[1]), number(p[2]), number(p[3]) });
    }
    for (items(value(v, "circles"))) |circle| {
        const p = items(circle);
        if (p.len != 3) continue;
        try w.print("<circle cx=\"{d}\" cy=\"{d}\" r=\"{d}\"/>", .{ number(p[0]), number(p[1]), number(p[2]) });
    }
    for (items(value(v, "polys"))) |poly| {
        try w.writeAll("<polygon points=\"");
        try points(w, poly);
        try w.writeAll("\"/>");
    }
    try w.writeAll("</g>");
}

/// Export full geometry, including overrides, stencil windows, drills, and artwork.
pub fn render(a: std.mem.Allocator, source: []const u8) (std.json.ParseError(std.json.Scanner) || @import("../sexpr/parser.zig").ParseError || std.mem.Allocator.Error || std.Io.Writer.Error || error{InvalidFootprint})![]const u8 {
    const data = try std.json.parseFromSliceLeaky(V, a, try preview.describeSource(a, source), .{});
    const box = value(data, "bbox");
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    try w.print("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"{d} {d} {d} {d}\" style=\"background:#101820\">", .{ n(box, "x"), n(box, "y"), n(box, "w"), n(box, "h") });
    try layer(w, value(data, "courtyard"), "#9d5fb0");
    try layer(w, value(data, "fab"), "#84ced0");
    try layer(w, value(data, "silk"), "#dddddd");
    for (items(value(data, "pads"))) |p| {
        const x = n(p, "x");
        const y = n(p, "y");
        const width = n(p, "w");
        const height = n(p, "h");
        try w.print("<g transform=\"rotate({d} {d} {d})\">", .{ n(p, "rot"), x, y });
        const shape = value(p, "shape");
        if (value(p, "poly") == .array) {
            try w.writeAll("<polygon fill=\"#d8ad55\" points=\"");
            try points(w, value(p, "poly"));
            try w.writeAll("\"/>");
        } else if (shape == .string and std.mem.eql(u8, shape.string, "circle")) {
            try w.print("<ellipse cx=\"{d}\" cy=\"{d}\" rx=\"{d}\" ry=\"{d}\" fill=\"#d8ad55\"/>", .{ x, y, width / 2, height / 2 });
        } else {
            var radius: f64 = 0;
            if (shape == .string and std.mem.eql(u8, shape.string, "oval")) radius = @min(width, height) / 2;
            if (shape == .string and std.mem.eql(u8, shape.string, "roundrect")) radius = @min(width, height) * (if (value(p, "roundrectRatio") == .null) 0.25 else n(p, "roundrectRatio"));
            try w.print("<rect x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" rx=\"{d}\" fill=\"#d8ad55\"/>", .{ x - width / 2, y - height / 2, width, height, radius });
        }
        if (value(p, "noPaste") != .bool or !value(p, "noPaste").bool) for (items(value(p, "paste"))) |v| try w.print("<rect x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" fill=\"#b4d8d0\"/>", .{ x + n(v, "x") - n(v, "w") / 2, y + n(v, "y") - n(v, "h") / 2, n(v, "w"), n(v, "h") });
        if (n(p, "drillX") > 0) try w.print("<ellipse cx=\"{d}\" cy=\"{d}\" rx=\"{d}\" ry=\"{d}\" fill=\"#101820\"/>", .{ x, y, n(p, "drillX") / 2, n(p, "drillY") / 2 });
        try w.writeAll("</g>");
        try w.print("<text x=\"{d}\" y=\"{d}\" text-anchor=\"middle\" dominant-baseline=\"central\" font-size=\".22\" fill=\"#111\">", .{ x, y });
        const id = value(p, "id");
        if (id == .string) try escape.writeXml(w, id.string);
        try w.writeAll("</text>");
    }
    try w.writeAll("</svg>");
    return out.toOwnedSlice();
}
