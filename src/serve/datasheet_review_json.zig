//! JSON projection of the authored `(datasheet-review …)` component form.
const std = @import("std");
const ast = @import("../sexpr/ast.zig");
const json_writer = @import("../json_writer.zig");

/// Append the nullable `datasheet_review` field used by component introspection.
pub fn write(writer: anytype, root_body: []const ast.Node) !void {
    try writer.writeAll(",\"datasheet_review\":");
    const children = findBodyForm(root_body, "datasheet-review") orelse {
        try writer.writeAll("null");
        return;
    };
    try writer.writeAll("{\"datasheet\":");
    try json_writer.writeString(writer, reviewField(children, "datasheet"));
    try writer.writeAll(",\"sha256\":");
    try json_writer.writeString(writer, reviewField(children, "sha256"));
    try writer.writeAll(",\"status\":");
    try json_writer.writeString(writer, reviewField(children, "status"));
    try writer.writeAll(",\"reviewed_by\":");
    try json_writer.writeString(writer, reviewField(children, "reviewed-by"));
    try writer.writeAll(",\"date\":");
    try json_writer.writeString(writer, reviewField(children, "date"));
    try writeCategories(writer, children);
    try writeNotApplicable(writer, children);
    try writer.writeAll("}");
}

fn findBodyForm(root_body: []const ast.Node, name: []const u8) ?[]const ast.Node {
    for (root_body) |node| {
        if (!node.isForm(name)) continue;
        return node.asList();
    }
    return null;
}

fn reviewField(children: []const ast.Node, name: []const u8) []const u8 {
    for (children[1..]) |node| {
        const field = node.asList() orelse continue;
        if (field.len < 2) continue;
        if (!std.mem.eql(u8, field[0].asAtom() orelse "", name)) continue;
        return field[1].asText() orelse "";
    }
    return "";
}

fn writeCategories(writer: anytype, children: []const ast.Node) !void {
    try writer.writeAll(",\"categories\":[");
    var first = true;
    for (children[1..]) |node| {
        const field = node.asList() orelse continue;
        if (field.len < 2 or !std.mem.eql(u8, field[0].asAtom() orelse "", "category")) continue;
        if (!first) try writer.writeAll(",");
        first = false;
        try json_writer.writeString(writer, field[1].asText() orelse "");
    }
    try writer.writeAll("]");
}

fn writeNotApplicable(writer: anytype, children: []const ast.Node) !void {
    try writer.writeAll(",\"not_applicable\":[");
    var first = true;
    for (children[1..]) |node| {
        const field = node.asList() orelse continue;
        if (field.len < 3 or !std.mem.eql(u8, field[0].asAtom() orelse "", "category-na")) continue;
        if (!first) try writer.writeAll(",");
        first = false;
        try writer.writeAll("{\"category\":");
        try json_writer.writeString(writer, field[1].asText() orelse "");
        try writer.writeAll(",\"rationale\":");
        try json_writer.writeString(writer, field[2].asText() orelse "");
        try writer.writeAll("}");
    }
    try writer.writeAll("]");
}
