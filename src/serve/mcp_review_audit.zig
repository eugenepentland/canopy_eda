//! Read-only CLI surface for the generated Board Review Audit — the same
//! document `netlisp review-audit <board>` writes, returned as a JSON string
//! so an agent can register it as a board-scoped review document.

const std = @import("std");
const json_writer = @import("../json_writer.zig");
const review_audit = @import("../review_audit.zig");

fn argString(args: ?std.json.Value, key: []const u8) ?[]const u8 {
    const root = args orelse return null;
    if (root != .object) return null;
    const value = root.object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

/// Everything the handler can fail with: the JSON buffer and the output list.
pub const RunError = std.mem.Allocator.Error || std.Io.Writer.Error;

fn fail(out: *std.ArrayList(u8), allocator: std.mem.Allocator, message: []const u8) RunError!bool {
    var buffer: std.Io.Writer.Allocating = .init(allocator);
    defer buffer.deinit();
    try buffer.writer.writeAll("{\"ok\":false,\"error\":");
    try json_writer.writeString(&buffer.writer, message);
    try buffer.writer.writeByte('}');
    try out.appendSlice(allocator, buffer.written());
    return false;
}

/// `review_audit {name, layout?}` → `{ok, name, layout, markdown}`.
pub fn run(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    args: ?std.json.Value,
    out: *std.ArrayList(u8),
) RunError!bool {
    const name = argString(args, "name") orelse return fail(out, allocator, "missing required name");
    const layout = argString(args, "layout");
    const markdown = review_audit.render(allocator, project_dir, name, .{ .layout = layout }) catch |err| {
        return fail(out, allocator, @errorName(err));
    };
    defer allocator.free(markdown);
    var buffer: std.Io.Writer.Allocating = .init(allocator);
    defer buffer.deinit();
    try buffer.writer.writeAll("{\"ok\":true,\"name\":");
    try json_writer.writeString(&buffer.writer, name);
    try buffer.writer.writeAll(",\"layout\":");
    try json_writer.writeString(&buffer.writer, layout orelse "starred");
    try buffer.writer.writeAll(",\"markdown\":");
    try json_writer.writeString(&buffer.writer, markdown);
    try buffer.writer.writeByte('}');
    try out.appendSlice(allocator, buffer.written());
    return true;
}
