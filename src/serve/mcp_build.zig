//! CLI build orchestration: evaluate a design, render its diagnostics, then
//! attach the content-addressed module dependency list used for that build.
const std = @import("std");
const edit = @import("edit.zig");
const mcp_checks = @import("mcp_checks.zig");
const build_dependencies = @import("build_dependencies.zig");
const preflight = @import("../preflight.zig");

const RunError = build_dependencies.AppendError;

/// Build and serialize one design/module, including its exact reusable-module
/// dependency digests whenever evaluation succeeds.
pub fn run(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    profile: preflight.Profile,
    severity: ?[]const u8,
    out: *std.ArrayList(u8),
) RunError!void {
    const report = edit.rebuildDesign(allocator, project_dir, name, profile);
    defer report.deinitPreflight(allocator);

    var base: std.Io.Writer.Allocating = .init(allocator);
    defer base.deinit();
    try mcp_checks.writeBuildReport(&base.writer, report, severity);

    const status: build_dependencies.EvaluationStatus = if (report.eval_ok) .ok else .failed;
    try build_dependencies.append(allocator, project_dir, name, status, base.written(), out);
}
