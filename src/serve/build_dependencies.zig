//! Adds deterministic reusable-module dependency digests to the CLI build
//! response without coupling the core BuildReport to a persisted lock format.

const std = @import("std");
const json_writer = @import("../json_writer.zig");
const paths = @import("../paths.zig");
const infra_fs = @import("../infra/fs.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const eval_modules = @import("../eval/modules.zig");
const module_metadata = @import("../module_metadata.zig");

/// Whether the preceding build produced an evaluable design.
pub const EvaluationStatus = enum { ok, failed };

/// Errors produced while extending the JSON response.
pub const AppendError = std.mem.Allocator.Error || std.Io.Writer.Error;

/// Append a normal build JSON object to `out`, injecting
/// `module_dependencies` before its closing brace when the named design can be
/// evaluated. On an eval failure the original build JSON is preserved.
pub fn append(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    status: EvaluationStatus,
    base: []const u8,
    out: *std.ArrayList(u8),
) AppendError!void {
    if (status == .failed or base.len == 0 or base[base.len - 1] != '}') {
        try out.appendSlice(allocator, base);
        return;
    }
    var eval = Evaluator.init(allocator, project_dir);
    defer eval.deinit();
    const block = resolveBlock(allocator, project_dir, name, &eval) catch {
        try out.appendSlice(allocator, base);
        return;
    };
    const dependencies = try module_metadata.collectDependencies(allocator, project_dir, block);
    defer module_metadata.freeDependencies(allocator, dependencies);

    try out.appendSlice(allocator, base[0 .. base.len - 1]);
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, out);
    defer out.* = aw.toArrayList();
    const writer = &aw.writer;
    try writer.writeAll(",\"module_dependencies\":[");
    for (dependencies, 0..) |dependency, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.writeAll("{\"source\":");
        try json_writer.writeString(writer, dependency.source);
        try writer.writeAll(",\"module\":");
        try json_writer.writeString(writer, dependency.module);
        try writer.writeAll(",\"source_sha256\":");
        try json_writer.writeString(writer, dependency.source_sha256[0..]);
        try writer.writeAll("}");
    }
    try writer.writeAll("]}");
}

fn resolveBlock(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    eval: *Evaluator,
) !*@import("../eval/env.zig").DesignBlock {
    const design_path = try paths.designSourcePath(allocator, project_dir, name);
    defer allocator.free(design_path);
    if (infra_fs.cwd().access(design_path, .{})) |_| {
        const result = try eval.evalFile(design_path);
        switch (result) {
            .design_block => |block| return block,
            else => {},
        }
    } else |_| {}

    const module_path = try std.fmt.allocPrint(allocator, "{s}/lib/modules/{s}.sexp", .{ project_dir, name });
    defer allocator.free(module_path);
    try infra_fs.cwd().access(module_path, .{});
    const result = try eval_modules.instantiateStandalone(eval, name);
    return switch (result) {
        .design_block => |block| block,
        else => error.NotADesign,
    };
}
