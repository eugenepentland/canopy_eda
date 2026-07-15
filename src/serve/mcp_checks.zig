//! ERC / build-report MCP handlers, extracted from `mcp_tools.zig` (which
//! stays the dispatcher): the `run_checks` tool (`toolRunChecks` → `runChecks`,
//! with the optional `severity` / `changed_since` filters), the shared
//! `severityPasses` predicate, and the JSON writers for a single ERC violation
//! (`writeErcViolationJson`) and the `build` tool's report (`writeBuildReport`,
//! which also carries the design's non-fatal eval/lint warnings). Grouped here
//! so `mcp_tools.zig` stays under its size ceiling; arg parsing + the
//! name-resolution helpers (`evalNamedBlock`, `runErcForNamedBlock`) are
//! re-imported from the dispatcher just as `mcp_parts_tools.zig` does.
const std = @import("std");
const json_writer = @import("../json_writer.zig");
const paths = @import("../paths.zig");
const bom = @import("../bom.zig");
const erc_mod = @import("../erc.zig");
const env_mod = @import("../eval/env.zig");
const edit = @import("edit.zig");
const diag_format = @import("diag_format.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const mcp_tools = @import("mcp_tools.zig");

// Arg parsing + name resolution live with the dispatcher; reused verbatim so
// the handlers behave identically to their pre-extraction selves.
const requireString = mcp_tools.requireString;
const optionalString = mcp_tools.optionalString;
const missingArg = mcp_tools.missingArg;
const evalNamedBlock = mcp_tools.evalNamedBlock;
const runErcForNamedBlock = mcp_tools.runErcForNamedBlock;
const warnResolveIdentities = mcp_tools.warnResolveIdentities;

// Shared JSON fragment / error strings live with the dispatcher (single
// definition — reused here to keep the wire format identical).
const json_net_key = mcp_tools.json_net_key;
const err_not_design = mcp_tools.err_not_design;
const err_build_failed = mcp_tools.err_build_failed;

/// True when violation `v` passes the optional `severity` filter
/// (`error`|`warning`|`info`). A null filter passes every violation. Shared by
/// `run_checks` and the `build` tool's `erc[]` emission so both filter the same
/// way. Callers validate the enum word at the schema layer; an unrecognised
/// string simply matches nothing.
pub fn severityPasses(v: erc_mod.Violation, filter: ?[]const u8) bool {
    const sf = filter orelse return true;
    return std.mem.eql(u8, @tagName(v.severity), sf);
}

/// Emit one ERC `Violation` as a compact JSON object (`kind`, `severity`,
/// `message`, and `ref`/`net` when present). Shared by `run_checks`, the
/// `build` report, and `mcp_tools`' module summary.
pub fn writeErcViolationJson(w: anytype, v: erc_mod.Violation) !void {
    try w.writeAll("{\"kind\":\"");
    try w.writeAll(@tagName(v.kind));
    try w.writeAll("\",\"severity\":\"");
    try w.writeAll(@tagName(v.severity));
    try w.writeAll("\",\"message\":");
    try json_writer.writeString(w, v.message);
    if (v.ref_des.len > 0) {
        try w.writeAll(",\"ref\":");
        try json_writer.writeString(w, v.ref_des);
    }
    if (v.net.len > 0) {
        try w.writeAll(json_net_key);
        try json_writer.writeString(w, v.net);
    }
    try w.writeAll("}");
}

/// `run_checks` tool handler: run ERC on a design/module (`name`) and stream
/// the `{filtered,changed_refs,changed_nets,erc}` JSON, honouring the optional
/// `severity` and `changed_since` filters.
pub fn toolRunChecks(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
    w: anytype,
) !bool {
    const name = requireString(args_val, "name") orelse return missingArg(out, allocator, "name");
    const severity = optionalString(args_val, "severity");
    const changed_since = optionalString(args_val, "changed_since");
    return runChecks(allocator, project_dir, name, severity, changed_since, w);
}

fn runChecks(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    severity_filter: ?[]const u8,
    changed_since: ?[]const u8,
    w: anytype,
) !bool {
    var eval = Evaluator.init(allocator, project_dir);
    defer eval.deinit();
    const nb = evalNamedBlock(allocator, project_dir, name, &eval) catch |e| switch (e) {
        error.NotADesign => {
            try w.writeAll(err_not_design);
            return false;
        },
        else => {
            try w.writeAll(err_build_failed);
            return false;
        },
    };
    const block = nb.block;

    if (!nb.is_module) {
        const bom_path = try paths.designSiblingPath(allocator, project_dir, name, ".bom");
        defer allocator.free(bom_path);
        bom.resolveIdentities(allocator, block, bom_path, project_dir) catch |e| warnResolveIdentities(name, e);
    }

    // If changed_since is set, compute the symmetric-difference sets of
    // ref_des and net names between the prior snapshot and the current
    // design. ERC violations are filtered to those touching these sets.
    var changed_refs: std.StringHashMapUnmanaged(void) = .empty;
    defer changed_refs.deinit(allocator);
    var changed_nets: std.StringHashMapUnmanaged(void) = .empty;
    defer changed_nets.deinit(allocator);
    var have_change_filter = false;
    if (changed_since) |cs| {
        // Validate snapshot id for path traversal.
        if (cs.len == 0 or std.mem.indexOf(u8, cs, "..") != null or std.mem.indexOfAny(u8, cs, "/\\") != null) {
            try w.writeAll("error: invalid changed_since id");
            return false;
        }
        const snap_path = try std.fmt.allocPrint(
            allocator,
            "{s}/history/{s}/{s}/{s}.sexp",
            .{ project_dir, name, cs, name },
        );
        defer allocator.free(snap_path);
        var eval_old = Evaluator.init(allocator, project_dir);
        defer eval_old.deinit();
        if (eval_old.evalFile(snap_path)) |old_result| {
            const old_block: *const env_mod.DesignBlock = switch (old_result) {
                .design_block => |b| b,
                else => {
                    try w.writeAll("error: snapshot did not evaluate to a design");
                    return false;
                },
            };
            try diffSets(allocator, old_block, block, &changed_refs, &changed_nets);
            have_change_filter = true;
        } else |_| {
            try w.writeAll("error: could not load snapshot");
            return false;
        }
    }

    try w.print("{{\"filtered\":{s}", .{if (have_change_filter or severity_filter != null) "true" else "false"});

    if (have_change_filter) {
        try w.writeAll(",\"changed_refs\":[");
        var it = changed_refs.iterator();
        var first = true;
        while (it.next()) |e| {
            if (!first) try w.writeAll(",");
            first = false;
            try json_writer.writeString(w, e.key_ptr.*);
        }
        try w.writeAll("],\"changed_nets\":[");
        var it2 = changed_nets.iterator();
        first = true;
        while (it2.next()) |e| {
            if (!first) try w.writeAll(",");
            first = false;
            try json_writer.writeString(w, e.key_ptr.*);
        }
        try w.writeAll("]");
    }

    try w.writeAll(",\"erc\":[");
    const erc_all = try runErcForNamedBlock(allocator, nb, project_dir);
    var first = true;
    for (erc_all) |v| {
        if (!severityPasses(v, severity_filter)) continue;
        if (have_change_filter) {
            const ref_hit = v.ref_des.len > 0 and changed_refs.contains(v.ref_des);
            const net_hit = v.net.len > 0 and changed_nets.contains(v.net);
            if (!ref_hit and !net_hit) continue;
        }
        if (!first) try w.writeAll(",");
        first = false;
        try writeErcViolationJson(w, v);
    }
    try w.writeAll("]}");
    return true;
}

fn diffSets(
    allocator: std.mem.Allocator,
    old_block: *const env_mod.DesignBlock,
    new_block: *const env_mod.DesignBlock,
    changed_refs: *std.StringHashMapUnmanaged(void),
    changed_nets: *std.StringHashMapUnmanaged(void),
) !void {
    var old_refs: std.StringHashMapUnmanaged(void) = .empty;
    defer old_refs.deinit(allocator);
    var new_refs: std.StringHashMapUnmanaged(void) = .empty;
    defer new_refs.deinit(allocator);
    var old_nets: std.StringHashMapUnmanaged(void) = .empty;
    defer old_nets.deinit(allocator);
    var new_nets: std.StringHashMapUnmanaged(void) = .empty;
    defer new_nets.deinit(allocator);

    for (old_block.instances) |i| try old_refs.put(allocator, i.ref_des, {});
    for (new_block.instances) |i| try new_refs.put(allocator, i.ref_des, {});
    for (old_block.nets) |n| try old_nets.put(allocator, n.name, {});
    for (new_block.nets) |n| try new_nets.put(allocator, n.name, {});

    var it = old_refs.iterator();
    while (it.next()) |e| if (!new_refs.contains(e.key_ptr.*)) try changed_refs.put(allocator, e.key_ptr.*, {});
    var it2 = new_refs.iterator();
    while (it2.next()) |e| if (!old_refs.contains(e.key_ptr.*)) try changed_refs.put(allocator, e.key_ptr.*, {});

    var it3 = old_nets.iterator();
    while (it3.next()) |e| if (!new_nets.contains(e.key_ptr.*)) try changed_nets.put(allocator, e.key_ptr.*, {});
    var it4 = new_nets.iterator();
    while (it4.next()) |e| if (!old_nets.contains(e.key_ptr.*)) try changed_nets.put(allocator, e.key_ptr.*, {});
}

/// Render a `BuildReport` from `edit.rebuildDesign` as the JSON the MCP
/// `build` tool returns. Failures keep the live_version unchanged but still
/// report the error message and any partial assertion results. `severity`
/// filters the `erc[]` array only (same enum as `run_checks`); the separate
/// `warnings[]` array carries the evaluator's non-fatal lint findings.
pub fn writeBuildReport(w: anytype, report: edit.BuildReport, severity: ?[]const u8) !void {
    try w.writeAll("{\"ok\":");
    try w.writeAll(if (report.ok) "true" else "false");
    try w.print(",\"version\":{d},\"eval_ok\":{s}", .{
        report.version,
        if (report.eval_ok) "true" else "false",
    });
    try w.writeAll(",\"snapshot\":");
    if (report.snapshot) |s| try json_writer.writeString(w, s) else try w.writeAll("null");
    try w.writeAll(",\"error\":");
    if (report.error_message) |m| try json_writer.writeString(w, m) else try w.writeAll("null");
    // Structured source-located build diagnostic (file/line/col/message/
    // source_line) so an agent can jump straight to the failing form.
    try w.writeAll(",\"diagnostic\":");
    if (report.diagnostic) |d| try diag_format.writeJson(w, d) else try w.writeAll("null");
    try w.writeAll(",\"assertion_failures\":[");
    for (report.assertion_failures, 0..) |a, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"message\":");
        try json_writer.writeString(w, a.message);
        try w.print(",\"is_warning\":{s}}}", .{if (a.is_warning) "true" else "false"});
    }
    try w.writeAll("],\"erc\":[");
    var first = true;
    for (report.erc) |v| {
        if (!severityPasses(v, severity)) continue;
        if (!first) try w.writeAll(",");
        first = false;
        try writeErcViolationJson(w, v);
    }
    // Non-fatal eval/lint warnings (silently-ignored sub-forms etc.) — a
    // separate array from erc[], and NOT touched by the severity filter.
    try w.writeAll("],\"warnings\":[");
    for (report.warnings, 0..) |wn, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{{\"line\":{d},\"col\":{d},\"message\":", .{ wn.line, wn.col });
        try json_writer.writeString(w, wn.message);
        try w.writeAll("}");
    }
    try w.writeAll("]}");
}

// ── Tests ─────────────────────────────────────────────────────────

test "severityPasses passes everything for a null filter" {
    // spec: serve/mcp_tools - severityPasses passes all violations when the filter is null, else only that severity
    const v = erc_mod.Violation{ .kind = .floating_net, .severity = .warning, .message = "x" };
    try std.testing.expect(severityPasses(v, null));
    try std.testing.expect(severityPasses(v, "warning"));
    try std.testing.expect(!severityPasses(v, "error"));
    try std.testing.expect(!severityPasses(v, "info"));
}

test "writeBuildReport severity filter drops non-matching erc entries" {
    // spec: serve/mcp_tools - build tool severity arg filters the erc[] array to the named severity
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    const w = out.writer(std.testing.allocator);
    const violations = [_]erc_mod.Violation{
        .{ .kind = .floating_net, .severity = .warning, .message = "warn one", .net = "NETW" },
        .{ .kind = .unconnected_pin, .severity = .@"error", .message = "err one", .ref_des = "U1" },
    };
    const report = edit.BuildReport{ .ok = true, .version = 1, .eval_ok = true, .erc = &violations };
    try writeBuildReport(w, report, "error");
    // The error survives; the warning is filtered out of erc[].
    try std.testing.expect(std.mem.indexOf(u8, out.items, "err one") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "warn one") == null);
}

test "writeBuildReport emits eval warnings in a separate array" {
    // spec: serve/mcp_tools - build response carries eval warnings in a warnings[] array separate from erc[]
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    const w = out.writer(std.testing.allocator);
    const warns = [_]edit.BuildWarning{
        .{ .line = 12, .col = 3, .message = "unknown sub-form (rolle ...)" },
    };
    const report = edit.BuildReport{ .ok = true, .version = 2, .eval_ok = true, .warnings = &warns };
    try writeBuildReport(w, report, null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"warnings\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "unknown sub-form (rolle ...)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"line\":12") != null);
}
