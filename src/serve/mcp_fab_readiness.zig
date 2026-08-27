//! Read-only MCP surface for the same strict manufacturing gate as HTTP.

const std = @import("std");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const export_gerber = @import("../export_gerber.zig");
const fab_gate = @import("../fab_gate.zig");
const fab_release = @import("../fab_release.zig");
const infra_fs = @import("../infra/fs.zig");
const json_writer = @import("../json_writer.zig");
const modules = @import("modules.zig");
const pcb = @import("pcb_layout_page.zig");

fn argString(args: ?std.json.Value, key: []const u8) ?[]const u8 {
    const root = args orelse return null;
    if (root != .object) return null;
    const value = root.object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn fail(out: *std.ArrayList(u8), allocator: std.mem.Allocator, message: []const u8) pcb.HandlerError!bool {
    var buffer: std.Io.Writer.Allocating = .init(allocator);
    try buffer.writer.writeAll("{\"ok\":false,\"error\":");
    try json_writer.writeString(&buffer.writer, message);
    try buffer.writer.writeByte('}');
    try out.appendSlice(allocator, buffer.written());
    return false;
}

/// Run the complete, revision-locked fabrication gate from MCP automation.
pub fn run(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    args: ?std.json.Value,
    out: *std.ArrayList(u8),
) pcb.HandlerError!bool {
    const name = argString(args, "name") orelse return fail(out, allocator, "missing required name");
    const layout = argString(args, "layout");
    const project_before = try fab_release.captureProjectState(allocator, project_dir);
    defer allocator.free(project_before.commit);
    const layout_before = try fab_release.savedLayoutDigest(allocator, project_dir, name);
    const bom_before = try fab_release.savedBomDigest(allocator, project_dir, name);
    var read_trace = infra_fs.ReadTrace.init(allocator);
    defer read_trace.deinit();
    read_trace.begin();
    defer read_trace.end();
    var evaluator = Evaluator.init(allocator, project_dir);
    defer evaluator.deinit();
    var module_result: ?modules.ResolvedBlock = null;
    defer if (module_result) |resolved| {
        resolved.eval.deinit();
        allocator.destroy(resolved.eval);
    };
    const block = pcb.resolveBlock(allocator, project_dir, name, &evaluator, &module_result) orelse
        return fail(out, allocator, "the design could not be resolved");
    const gate_evaluator = if (module_result) |resolved| resolved.eval else &evaluator;
    const view = pcb.fabViewForResolved(allocator, project_dir, name, layout, block) catch |err| return switch (err) {
        error.UnknownLayout => fail(out, allocator, "the requested saved layout does not exist"),
        else => fail(out, allocator, "no saved layout is available; save one before release"),
    };
    const copper = export_gerber.Copper{ .tracks = view.routed.tracks, .arcs = view.routed.arcs, .rf_paths = view.routed.rf_port_outcomes, .vias = view.routed.vias, .zones = view.zones, .silk_keepouts = view.silk_keepouts };
    var gate = fab_gate.check(allocator, .{
        .project_dir = project_dir,
        .name = name,
        .evaluator = gate_evaluator,
        .block = block,
        .physical = .{ .placement = view.placement, .routed = view.routed, .zones = view.zones, .texts = view.texts, .copper = copper },
        .release = .{
            .from_saved = view.selection.from_saved,
            .layout_evidence_complete = view.selection.evidence_complete,
            .keep_dnp = false,
            .board = view.authored.board,
        },
    }) catch |err| return fail(out, allocator, @errorName(err));
    read_trace.end();
    const consumed_inputs_sha256 = read_trace.digest();
    const traced_inputs = try fab_release.tracedInputs(allocator, &read_trace, project_dir, name);
    const source_input_sha256 = traced_inputs.source;
    const layout_input_sha256 = traced_inputs.layout;
    const bom_input_sha256 = traced_inputs.bom;
    const mark = try fab_gate.identityMark(allocator, .{
        .placement = view.placement,
        .routed = view.routed,
        .zones = view.zones,
        .texts = view.texts,
        .copper = copper,
    }, &gate);
    const evidence = fab_release.Evidence{
        .report = gate.report,
        .design = .{
            .placement = view.placement,
            .revision = view.authored.revision,
            .stackup = view.authored.stackup,
            .block = gate.evaluation.block,
            .layout_name = view.selection.name,
            .dependencies = gate.evaluation.dependencies,
        },
        .mark = mark,
        .drc = .{ .raw = gate.drc.raw, .effective = gate.drc.effective, .complete = gate.drc.complete, .internal_complete = gate.internal_complete, .policy = gate.policy },
        .inputs = .{
            .evaluation_sha256 = gate.evaluation.sha256,
            .reviewed_sha256 = gate.evaluation.reviewed_inputs_sha256,
            .consumed_sha256 = consumed_inputs_sha256,
            .source_sha256 = source_input_sha256,
            .layout_sha256 = layout_input_sha256,
            .bom_sha256 = bom_input_sha256,
        },
    };
    var lock = fab_release.makeLock(allocator, project_dir, name, evidence) catch |err|
        return fail(out, allocator, @errorName(err));
    fab_release.bindBaseline(&lock, project_before, layout_before, bom_before);
    fab_release.bindTracedInputs(&lock, traced_inputs, read_trace.verify());
    var response: std.Io.Writer.Allocating = .init(allocator);
    try fab_release.writeReadinessJson(allocator, &response.writer, evidence, lock);
    try out.appendSlice(allocator, response.written());
    return true;
}

fn expectStringEvidenceParity(http: std.json.Value, relative: std.json.Value, absolute: std.json.Value) !void {
    for ([_][]const u8{
        "release_token",
        "source_sha256",
        "layout_sha256",
        "bom_evidence_sha256",
        "evaluated_dependency_sha256",
        "evaluation_read_set_sha256",
        "reviewed_inputs_sha256",
        "consumed_inputs_sha256",
        "project_status",
    }) |key| {
        const expected = http.object.get(key).?.string;
        try std.testing.expectEqualStrings(expected, relative.object.get(key).?.string);
        try std.testing.expectEqualStrings(expected, absolute.object.get(key).?.string);
    }
}

fn expectCountEvidenceParity(http: std.json.Value, relative: std.json.Value, absolute: std.json.Value) !void {
    for ([_][]const u8{ "raw_drc_count", "effective_drc_count", "ignored_drc_count" }) |key| {
        const expected = http.object.get(key).?.integer;
        try std.testing.expectEqual(expected, relative.object.get(key).?.integer);
        try std.testing.expectEqual(expected, absolute.object.get(key).?.integer);
    }
}

// spec: fabrication-release - HTTP and MCP readiness expose the same revision lock independent of canonical project-root spelling
test "MCP fab readiness matches HTTP and canonical project roots" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const absolute_project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    try pcb.FabReleaseTestSupport.setup(allocator, tmp.dir, absolute_project);
    try pcb.FabReleaseTestSupport.git(allocator, absolute_project, &.{ "init", "-q" });
    try pcb.FabReleaseTestSupport.git(allocator, absolute_project, &.{ "add", "." });
    try pcb.FabReleaseTestSupport.git(allocator, absolute_project, &.{ "-c", "user.name=Fab Test", "-c", "user.email=fab@test.invalid", "commit", "-q", "-m", "fixture" });

    const current = try infra_fs.canonicalPathAlloc(allocator, ".");
    const relative_project = try std.fs.path.relative(allocator, current, null, current, absolute_project);
    const http_body = try pcb.FabReleaseTestSupport.readiness(allocator, relative_project);
    const http_json = try std.json.parseFromSliceLeaky(std.json.Value, allocator, http_body, .{});
    const args = try std.json.parseFromSliceLeaky(std.json.Value, allocator, "{\"name\":\"fabok\",\"layout\":\"release\"}", .{});

    var relative_mcp: std.ArrayList(u8) = .empty;
    try std.testing.expect(try run(allocator, relative_project, args, &relative_mcp));
    const relative_json = try std.json.parseFromSliceLeaky(std.json.Value, allocator, relative_mcp.items, .{});
    var absolute_mcp: std.ArrayList(u8) = .empty;
    try std.testing.expect(try run(allocator, absolute_project, args, &absolute_mcp));
    const absolute_json = try std.json.parseFromSliceLeaky(std.json.Value, allocator, absolute_mcp.items, .{});

    try expectStringEvidenceParity(http_json, relative_json, absolute_json);
    try expectCountEvidenceParity(http_json, relative_json, absolute_json);
    try std.testing.expectEqual(
        http_json.object.get("errors").?.array.items.len,
        relative_json.object.get("errors").?.array.items.len,
    );
    try std.testing.expectEqual(
        http_json.object.get("warnings").?.array.items.len,
        relative_json.object.get("warnings").?.array.items.len,
    );
}

// spec: fabrication-release - MCP preserves the full release report and null authorization token for an ambiguous source bundle
test "MCP and HTTP preserve full findings for an ambiguous release source" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    try pcb.FabReleaseTestSupport.setup(allocator, tmp.dir, project);
    try tmp.dir.createDirPath(std.testing.io, "src/duplicate");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "src/duplicate/fabok.sexp",
        .data = "(design-block \"Ambiguous Duplicate\" (revision \"A\") (board (size 1 1)))",
    });
    try pcb.FabReleaseTestSupport.git(allocator, project, &.{ "init", "-q" });
    try pcb.FabReleaseTestSupport.git(allocator, project, &.{ "add", "." });
    try pcb.FabReleaseTestSupport.git(allocator, project, &.{ "-c", "user.name=Fab Test", "-c", "user.email=fab@test.invalid", "commit", "-q", "-m", "fixture" });

    const http = try pcb.FabReleaseTestSupport.readiness_response(allocator, project);
    try std.testing.expectEqual(@as(u16, 500), http.status);
    const http_json = try std.json.parseFromSliceLeaky(std.json.Value, allocator, http.body, .{});
    const args = try std.json.parseFromSliceLeaky(std.json.Value, allocator, "{\"name\":\"fabok\",\"layout\":\"release\"}", .{});
    var mcp: std.ArrayList(u8) = .empty;
    try std.testing.expect(try run(allocator, project, args, &mcp));
    const mcp_json = try std.json.parseFromSliceLeaky(std.json.Value, allocator, mcp.items, .{});
    for ([_]std.json.Value{ http_json, mcp_json }) |report| {
        try std.testing.expect(report.object.get("release_token").? == .null);
        try std.testing.expectEqualStrings("ambiguous", report.object.get("project_status").?.string);
    }
    try std.testing.expect(std.mem.indexOf(u8, http.body, "source-bundle-ambiguous") != null);
    try std.testing.expect(std.mem.indexOf(u8, mcp.items, "source-bundle-ambiguous") != null);
    try std.testing.expect(std.mem.indexOf(u8, http.body, "intentional fixture waiver") != null);
    try std.testing.expect(std.mem.indexOf(u8, mcp.items, "intentional fixture waiver") != null);
    try std.testing.expectEqual(
        http_json.object.get("errors").?.array.items.len,
        mcp_json.object.get("errors").?.array.items.len,
    );
}
