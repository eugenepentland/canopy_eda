//! ERC / build-report CLI handlers, extracted from `mcp_tools.zig` (which
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
const preflight = @import("../preflight.zig");
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
const NamedBlock = mcp_tools.NamedBlock;

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

/// Emit one requirement/datasheet-review result. This is the canonical wire
/// shape shared by `run_checks` and `build`.
pub fn writePreflightFindingJson(w: anytype, finding: preflight.Finding) !void {
    try w.writeAll("{\"kind\":\"");
    try w.writeAll(@tagName(finding.kind));
    try w.writeAll("\",\"status\":\"");
    try w.writeAll(@tagName(finding.status));
    try w.writeAll("\",\"severity\":\"");
    try w.writeAll(@tagName(finding.severity));
    try w.writeAll("\",\"ref\":");
    try json_writer.writeString(w, finding.ref_des);
    try w.writeAll(",\"component\":");
    try json_writer.writeString(w, finding.component);
    try w.writeAll(",\"message\":");
    try json_writer.writeString(w, finding.message);
    if (finding.requirement.id.len > 0) {
        try w.writeAll(",\"requirement_id\":");
        try json_writer.writeString(w, finding.requirement.id);
        try w.writeAll(",\"requirement_text\":");
        try json_writer.writeString(w, finding.requirement.text);
        // Which authority wrote the rule. Emitted alongside every requirement
        // finding — not only design ones — so a consumer never has to infer
        // "library" from the ABSENCE of a field.
        try w.print(",\"requirement_source\":\"{s}\"", .{@tagName(finding.requirement.source)});
    }
    if (finding.requirement.target.len > 0) {
        // What a design rule judged: the matched net, the glob that matched
        // nothing, or the `(on "REF")` target.
        try w.writeAll(",\"requirement_target\":");
        try json_writer.writeString(w, finding.requirement.target);
        if (finding.requirement.block_path.len > 0) {
            try w.writeAll(",\"requirement_block\":");
            try json_writer.writeString(w, finding.requirement.block_path);
        }
        if (finding.requirement.scope.len > 0) {
            try w.writeAll(",\"requirement_scope\":");
            try json_writer.writeString(w, finding.requirement.scope);
        }
    }
    if (finding.requirement.datasheet.len > 0) {
        try w.writeAll(",\"datasheet\":");
        try json_writer.writeString(w, finding.requirement.datasheet);
    }
    if (finding.requirement.citation) |citation| {
        try w.writeAll(",\"citation\":{\"pdf\":");
        try json_writer.writeString(w, citation.pdf);
        try w.print(",\"page\":{d},\"quote\":", .{citation.page});
        if (citation.quote) |quote| try json_writer.writeString(w, quote) else try w.writeAll("null");
        try w.writeAll("}");
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
    const profile_word = optionalString(args_val, "profile");
    const profile = preflight.parseProfile(profile_word) orelse {
        try w.writeAll("error: invalid profile (expected authoring, preflight or release)");
        return false;
    };
    return runChecks(allocator, .{
        .project_dir = project_dir,
        .name = name,
        .severity = severity,
        .changed_since = changed_since,
        .profile = profile,
        .variant = optionalString(args_val, "variant"),
    }, w);
}

const RunChecksArgs = struct {
    project_dir: []const u8,
    name: []const u8,
    severity: ?[]const u8,
    changed_since: ?[]const u8,
    profile: preflight.Profile,
    /// Which assembly variant to evaluate the design in. Null selects the
    /// design's `(default)` variant, else the base — so the checks answer for
    /// the assembly the board is built as unless another is asked for.
    variant: ?[]const u8 = null,
};

const ChangeFilter = struct {
    refs: std.StringHashMapUnmanaged(void) = .empty,
    nets: std.StringHashMapUnmanaged(void) = .empty,
    active: bool = false,

    fn deinit(self: *ChangeFilter, allocator: std.mem.Allocator) void {
        self.refs.deinit(allocator);
        self.nets.deinit(allocator);
    }

    fn filtered(self: ChangeFilter, severity: ?[]const u8) bool {
        return self.active or severity != null;
    }
};

fn loadNamedBlock(
    allocator: std.mem.Allocator,
    args: RunChecksArgs,
    eval: *Evaluator,
    w: anytype,
) !?NamedBlock {
    return evalNamedBlock(allocator, args.project_dir, args.name, eval) catch |err| switch (err) {
        error.NotADesign => {
            try w.writeAll(err_not_design);
            return null;
        },
        else => {
            try w.writeAll(err_build_failed);
            return null;
        },
    };
}

fn resolveBom(allocator: std.mem.Allocator, args: RunChecksArgs, nb: NamedBlock) !void {
    if (!nb.is_module) {
        const bom_path = try paths.designSiblingPath(allocator, args.project_dir, args.name, ".bom");
        defer allocator.free(bom_path);
        bom.resolveIdentities(allocator, nb.block, bom_path, args.project_dir) catch |err|
            warnResolveIdentities(args.name, err);
    }
}

fn validSnapshotId(id: []const u8) bool {
    if (id.len == 0) return false;
    if (std.mem.indexOf(u8, id, "..") != null) return false;
    return std.mem.indexOfAny(u8, id, "/\\") == null;
}

fn loadChangeFilter(
    allocator: std.mem.Allocator,
    args: RunChecksArgs,
    block: *const env_mod.DesignBlock,
    changes: *ChangeFilter,
    w: anytype,
) !bool {
    const snapshot = args.changed_since orelse return true;
    if (!validSnapshotId(snapshot)) {
        try w.writeAll("error: invalid changed_since id");
        return false;
    }
    const snap_path = try std.fmt.allocPrint(
        allocator,
        "{s}/history/{s}/{s}/{s}.sexp",
        .{ args.project_dir, args.name, snapshot, args.name },
    );
    defer allocator.free(snap_path);
    var old_eval = Evaluator.init(allocator, args.project_dir);
    defer old_eval.deinit();
    const old_result = old_eval.evalFile(snap_path) catch {
        try w.writeAll("error: could not load snapshot");
        return false;
    };
    const old_block: *const env_mod.DesignBlock = switch (old_result) {
        .design_block => |value| value,
        else => {
            try w.writeAll("error: snapshot did not evaluate to a design");
            return false;
        },
    };
    try diffSets(allocator, old_block, block, &changes.refs, &changes.nets);
    changes.active = true;
    return true;
}

fn writeStringSet(w: anytype, values: *const std.StringHashMapUnmanaged(void)) !void {
    var iterator = values.iterator();
    var first = true;
    while (iterator.next()) |entry| {
        if (!first) try w.writeAll(",");
        first = false;
        try json_writer.writeString(w, entry.key_ptr.*);
    }
}

fn writeChangeFilter(w: anytype, changes: ChangeFilter) !void {
    if (changes.active) {
        try w.writeAll(",\"changed_refs\":[");
        try writeStringSet(w, &changes.refs);
        try w.writeAll("],\"changed_nets\":[");
        try writeStringSet(w, &changes.nets);
        try w.writeAll("]");
    }
}

fn writeAssertions(w: anytype, eval: *const Evaluator, severity_filter: ?[]const u8) !usize {
    try w.writeAll(",\"assertion_failures\":[");
    var errors: usize = 0;
    var first = true;
    for (eval.assertions.items) |assertion| {
        if (assertion.passed) continue;
        if (!assertion.is_warning) errors += 1;
        const assertion_severity: []const u8 = if (assertion.is_warning) "warning" else "error";
        if (severity_filter) |filter| if (!std.mem.eql(u8, assertion_severity, filter)) continue;
        if (!first) try w.writeAll(",");
        first = false;
        try w.writeAll("{\"kind\":\"assertion\",\"severity\":\"");
        try w.writeAll(assertion_severity);
        try w.writeAll("\",\"message\":");
        try json_writer.writeString(w, assertion.message);
        try w.writeAll("}");
    }
    return errors;
}

fn touchesChanges(violation: erc_mod.Violation, changes: ChangeFilter) bool {
    if (!changes.active) return true;
    if (violation.ref_des.len > 0 and changes.refs.contains(violation.ref_des)) return true;
    return violation.net.len > 0 and changes.nets.contains(violation.net);
}

fn writeErcResults(
    w: anytype,
    violations: []const erc_mod.Violation,
    severity_filter: ?[]const u8,
    changes: ChangeFilter,
) !usize {
    try w.writeAll("],\"erc\":[");
    var errors: usize = 0;
    var first = true;
    for (violations) |violation| {
        if (violation.severity == .@"error") errors += 1;
        if (!severityPasses(violation, severity_filter)) continue;
        if (!touchesChanges(violation, changes)) continue;
        if (!first) try w.writeAll(",");
        first = false;
        try writeErcViolationJson(w, violation);
    }
    return errors;
}

fn writeFindings(
    w: anytype,
    report: preflight.Report,
    severity_filter: ?[]const u8,
    changes: ChangeFilter,
) !void {
    try w.writeAll("],\"findings\":[");
    var first = true;
    for (report.findings) |finding| {
        if (severity_filter) |sf| if (!std.mem.eql(u8, @tagName(finding.severity), sf)) continue;
        if (changes.active and !changes.refs.contains(finding.ref_des)) continue;
        if (!first) try w.writeAll(",");
        first = false;
        try writePreflightFindingJson(w, finding);
    }
}

fn runChecks(allocator: std.mem.Allocator, args: RunChecksArgs, w: anytype) !bool {
    var eval = Evaluator.init(allocator, args.project_dir);
    eval.variants.requested = args.variant;
    defer eval.deinit();
    const nb = (try loadNamedBlock(allocator, args, &eval, w)) orelse return false;
    try resolveBom(allocator, args, nb);

    var changes: ChangeFilter = .{};
    defer changes.deinit(allocator);
    if (!try loadChangeFilter(allocator, args, nb.block, &changes, w)) return false;

    try w.print("{{\"filtered\":{s},\"profile\":\"{s}\"", .{
        if (changes.filtered(args.severity)) "true" else "false",
        @tagName(args.profile),
    });
    try writeChangeFilter(w, changes);
    const assertion_errors = try writeAssertions(w, &eval, args.severity);
    const erc = try runErcForNamedBlock(allocator, nb, args.project_dir);
    const erc_errors = try writeErcResults(w, erc, args.severity, changes);
    const report = try preflight.run(allocator, &eval, nb.block, args.project_dir, args.profile);
    defer report.deinit(allocator);
    try writeFindings(w, report, args.severity, changes);
    const preflight_ok = erc_errors == 0 and assertion_errors == 0 and report.errors == 0;
    try w.print("],\"preflight_ok\":{s},\"finding_errors\":{d},\"finding_warnings\":{d}}}", .{
        if (preflight_ok) "true" else "false",
        report.errors,
        report.warnings,
    });
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

/// Render a `BuildReport` from `edit.rebuildDesign` as the JSON the CLI
/// `build` tool returns. Failures keep the live_version unchanged but still
/// report the error message and any partial assertion results. `severity`
/// filters the `erc[]` array only (same enum as `run_checks`); the separate
/// `warnings[]` array carries the evaluator's non-fatal lint findings.
pub fn writeBuildReport(w: anytype, report: edit.BuildReport, severity: ?[]const u8) !void {
    try w.writeAll("{\"ok\":");
    try w.writeAll(if (report.ok) "true" else "false");
    try w.print(",\"version\":{d},\"eval_ok\":{s},\"profile\":\"{s}\"", .{
        report.version,
        if (report.eval_ok) "true" else "false",
        @tagName(report.validation.profile),
    });
    try w.writeAll(",\"snapshot\":");
    if (report.snapshot) |s| try json_writer.writeString(w, s) else try w.writeAll("null");
    try w.writeAll(",\"error\":");
    if (report.failure.message) |m| try json_writer.writeString(w, m) else try w.writeAll("null");
    // Structured source-located build diagnostic (file/line/col/message/
    // source_line) so an agent can jump straight to the failing form.
    try w.writeAll(",\"diagnostic\":");
    if (report.failure.diagnostic) |d| try diag_format.writeJson(w, d) else try w.writeAll("null");
    try w.writeAll(",\"assertion_failures\":[");
    for (report.validation.assertions, 0..) |a, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"message\":");
        try json_writer.writeString(w, a.message);
        try w.print(",\"is_warning\":{s}}}", .{if (a.is_warning) "true" else "false"});
    }
    try w.writeAll("],\"erc\":[");
    var first = true;
    for (report.validation.erc) |v| {
        if (!severityPasses(v, severity)) continue;
        if (!first) try w.writeAll(",");
        first = false;
        try writeErcViolationJson(w, v);
    }
    try w.writeAll("],\"findings\":[");
    first = true;
    var erc_errors: usize = 0;
    var assertion_errors: usize = 0;
    for (report.validation.erc) |violation| if (violation.severity == .@"error") {
        erc_errors += 1;
    };
    for (report.validation.assertions) |assertion| if (!assertion.is_warning) {
        assertion_errors += 1;
    };
    for (report.validation.findings) |finding| {
        if (severity) |filter| if (!std.mem.eql(u8, @tagName(finding.severity), filter)) continue;
        if (!first) try w.writeAll(",");
        first = false;
        try writePreflightFindingJson(w, finding);
    }
    const strict_failed = preflight.isStrict(report.validation.profile) and !report.ok;
    const preflight_ok = !strict_failed and
        report.validation.finding_errors == 0 and erc_errors == 0 and assertion_errors == 0;
    try w.print("],\"preflight_ok\":{s},\"finding_errors\":{d},\"finding_warnings\":{d}", .{
        if (preflight_ok) "true" else "false",
        report.validation.finding_errors,
        report.validation.finding_warnings,
    });
    // Non-fatal eval/lint warnings (silently-ignored sub-forms etc.) — a
    // separate array from erc[], and NOT touched by the severity filter.
    try w.writeAll(",\"warnings\":[");
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
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const w = &out.writer;
    const violations = [_]erc_mod.Violation{
        .{ .kind = .floating_net, .severity = .warning, .message = "warn one", .net = "NETW" },
        .{ .kind = .unconnected_pin, .severity = .@"error", .message = "err one", .ref_des = "U1" },
    };
    const report = edit.BuildReport{
        .ok = true,
        .version = 1,
        .eval_ok = true,
        .validation = .{ .erc = &violations },
    };
    try writeBuildReport(w, report, "error");
    // The error survives; the warning is filtered out of erc[].
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "err one") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "warn one") == null);
}

test "writeBuildReport emits eval warnings in a separate array" {
    // spec: serve/mcp_tools - build response carries eval warnings in a warnings[] array separate from erc[]
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const w = &out.writer;
    const warns = [_]edit.BuildWarning{
        .{ .line = 12, .col = 3, .message = "unknown sub-form (rolle ...)" },
    };
    const report = edit.BuildReport{ .ok = true, .version = 2, .eval_ok = true, .warnings = &warns };
    try writeBuildReport(w, report, null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"warnings\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "unknown sub-form (rolle ...)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"line\":12") != null);
}

// spec: serve/mcp_checks - build and run_checks share structured requirement/datasheet preflight finding fields
test "writeBuildReport emits structured preflight findings" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const findings = [_]preflight.Finding{.{
        .kind = .requirement,
        .status = .fail,
        .severity = .@"error",
        .ref_des = "U1",
        .component = "regulator",
        .message = "no capacitor found",
        .requirement = .{
            .id = "deadbeef",
            .text = "VIN must be decoupled",
            .citation = .{ .pdf = "regulator.pdf", .page = 7, .quote = "Place a capacitor" },
            .datasheet = "regulator.pdf",
        },
    }};
    const report = edit.BuildReport{
        .ok = false,
        .version = 2,
        .eval_ok = true,
        .validation = .{
            .profile = .preflight,
            .findings = &findings,
            .finding_errors = 1,
        },
    };
    try writeBuildReport(&out.writer, report, null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"findings\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"requirement_id\":\"deadbeef\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"preflight_ok\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"profile\":\"preflight\"") != null);
}

// spec: serve/mcp_checks - build preflight_ok includes non-warning assertion failures
test "writeBuildReport preflight_ok includes assertion errors" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const assertions = [_]edit.AssertionFailure{.{ .message = "rail out of range", .is_warning = false }};
    const report = edit.BuildReport{
        .ok = false,
        .version = 2,
        .eval_ok = true,
        .validation = .{ .profile = .preflight, .assertions = &assertions },
    };
    try writeBuildReport(&out.writer, report, null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"preflight_ok\":false") != null);

    var failed_out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer failed_out.deinit();
    const failed_report = edit.BuildReport{
        .ok = false,
        .version = 2,
        .eval_ok = true,
        .validation = .{ .profile = .preflight },
    };
    try writeBuildReport(&failed_out.writer, failed_report, null);
    try std.testing.expect(std.mem.indexOf(u8, failed_out.written(), "\"preflight_ok\":false") != null);
}
