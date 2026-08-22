//! Compact DRC/timing summary shared by routing response writers.

const std = @import("std");
const drc = @import("../placement/drc.zig");

/// Write the unambiguous DRC breakdown and elapsed time portion of a routing
/// result. `drc` remains the compatibility total; errors and warnings are
/// separated so callers know whether fabrication is blocked.
pub fn writeDrc(
    w: *std.Io.Writer,
    findings: []const drc.Violation,
    wall_ms: i64,
) std.Io.Writer.Error!void {
    var warnings: usize = 0;
    var diff_warnings: usize = 0;
    var artifact_warnings: usize = 0;
    for (findings) |finding| {
        if (finding.severity == .warn) warnings += 1;
        if (finding.kind == .diff_uncoupled or finding.kind == .diff_skew) diff_warnings += 1;
        if (finding.kind == .single_layer_via or finding.kind == .redundant_via) {
            artifact_warnings += 1;
        } else if (finding.kind == .copper_stub or finding.kind == .implicit_junction or
            finding.kind == .dangling_copper) artifact_warnings += 1;
    }
    try w.print(
        "\"drc\":{d},\"drc_errors\":{d},\"drc_warnings\":{d}," ++
            "\"diff_warnings\":{d},\"artifact_warnings\":{d},\"wall_ms\":{d}",
        .{
            findings.len,
            drc.errorCount(findings),
            warnings,
            diff_warnings,
            artifact_warnings,
            wall_ms,
        },
    );
}

// spec: serve/route-result-stats - a route response separates DRC errors, warnings, differential warnings and topology artifacts
test "route response DRC summary separates actionable categories" {
    const findings = [_]drc.Violation{
        .{ .x = 0, .y = 0, .gap = 0, .clearance = 0.1, .kind = .track_pad, .severity = .err },
        .{ .x = 1, .y = 0, .gap = 0, .clearance = 0, .kind = .diff_uncoupled, .severity = .warn },
        .{ .x = 2, .y = 0, .gap = 1, .clearance = 2, .kind = .single_layer_via, .severity = .warn },
    };
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeDrc(&aw.writer, &findings, 42);
    try std.testing.expectEqualStrings(
        "\"drc\":3,\"drc_errors\":1,\"drc_warnings\":2," ++
            "\"diff_warnings\":1,\"artifact_warnings\":1,\"wall_ms\":42",
        aw.written(),
    );
}
