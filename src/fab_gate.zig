//! One strict manufacturing verdict shared by HTTP and MCP release surfaces.

const std = @import("std");
const bom = @import("bom.zig");
const drc = @import("placement/drc.zig");
const env = @import("eval/env.zig");
const Evaluator = @import("eval/evaluator.zig").Evaluator;
const export_gerber = @import("export_gerber.zig");
const export_fab = @import("export_fab.zig");
const fab_identity = @import("fab_identity.zig");
const fab_readiness = @import("fab_readiness.zig");
const fab_release = @import("fab_release.zig");
const fab_schematic_gate = @import("fab_schematic_gate.zig");
const font = @import("font5x7.zig");
const module_metadata = @import("module_metadata.zig");
const optimizer = @import("placement/optimizer.zig");
const infra_fs = @import("infra/fs.zig");
const paths = @import("paths.zig");
const pour = @import("placement/pour.zig");
const router = @import("placement/router.zig");
const drc_rules = @import("serve/drc_rules.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;

/// Exact physical snapshot judged and eventually fabricated.
pub const BoardInput = struct {
    placement: optimizer.Placement,
    routed: router.RouteResult,
    zones: []const pour.UserZone,
    texts: []const font.BoardText,
    copper: export_gerber.Copper,
};

/// Authored/saved-state facts needed for manufacturing-only checks.
pub const ReleaseInput = struct {
    from_saved: bool,
    layout_evidence_complete: bool,
    keep_dnp: bool,
    board: env.BoardSpec,
};

/// Inputs that bridge a resolved design and its exact PCB snapshot.
pub const Input = struct {
    project_dir: []const u8,
    name: []const u8,
    evaluator: ?*Evaluator,
    block: ?*const env.DesignBlock,
    physical: BoardInput,
    release: ReleaseInput,
};

/// Strict release result, including raw/effective DRC policy evidence.
pub const Result = struct {
    report: fab_readiness.Report,
    drc: drc_rules.ReleaseCheck,
    policy: []const fab_release.PolicyEntry,
    evaluation: struct {
        block: ?*const env.DesignBlock,
        dependencies: []const module_metadata.Dependency,
        sha256: [64]u8,
        reviewed_inputs_sha256: [64]u8,
    },
    internal_complete: bool,
};

/// Identity findings that mean there is no trustworthy revision/BOM lock and
/// therefore cannot be waived as an ordinary design-rule exception.
fn identityComplete(report: fab_readiness.Report) bool {
    const hard_ids = [_][]const u8{
        "revision-missing",                 "centroid-parity",               "missing-identity",
        "duplicate-identity",               "duplicate-source-identity",     "bom-evidence-incomplete",
        "verification-evidence-incomplete", "footprint-geometry-unresolved", "module_metadata_incomplete",
        "layout-evidence-incomplete",       "bom-identity",
    };
    for (report.errors) |item| for (hard_ids) |id| {
        if (std.mem.eql(u8, item.id, id)) return false;
    };
    return true;
}

// spec: fabrication-release - revision, source-ID, BOM/centroid, and fallback-geometry identity failures can never be waived
test "release identity hard failures are nonwaivable" {
    const ordinary = fab_readiness.Report{ .errors = &.{.{ .id = "component-underrated", .message = "rating" }}, .warnings = &.{}, .stats = .{} };
    const duplicate_source = fab_readiness.Report{ .errors = &.{.{ .id = "duplicate-source-identity", .message = "duplicate" }}, .warnings = &.{}, .stats = .{} };
    const missing_revision = fab_readiness.Report{ .errors = &.{.{ .id = "revision-missing", .message = "revision" }}, .warnings = &.{}, .stats = .{} };
    const fallback = fab_readiness.Report{ .errors = &.{.{ .id = "footprint-geometry-unresolved", .message = "footprint" }}, .warnings = &.{}, .stats = .{} };
    const missing_mpn = fab_readiness.Report{ .errors = &.{.{ .id = "bom-identity", .message = "MPN" }}, .warnings = &.{}, .stats = .{} };
    const malformed_layout = fab_readiness.Report{ .errors = &.{.{ .id = "layout-evidence-incomplete", .message = "layout" }}, .warnings = &.{}, .stats = .{} };
    try std.testing.expect(identityComplete(ordinary));
    try std.testing.expect(!identityComplete(duplicate_source));
    try std.testing.expect(!identityComplete(missing_revision));
    try std.testing.expect(!identityComplete(fallback));
    try std.testing.expect(!identityComplete(missing_mpn));
    try std.testing.expect(!identityComplete(malformed_layout));
}

/// Build the fabrication identity mark while preserving the complete gate
/// report when the mark cannot fit. HTTP and MCP both use this path so an
/// identity failure never hides independent schematic or DRC findings.
pub fn identityMark(
    arena: std.mem.Allocator,
    physical: BoardInput,
    result: *Result,
) std.mem.Allocator.Error!fab_identity.Mark {
    return fab_identity.build(
        arena,
        physical.placement,
        physical.copper,
        physical.texts,
        export_fab.frameFor(physical.placement),
        null,
    ) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        var errors: std.ArrayList(fab_readiness.Item) = .empty;
        try errors.appendSlice(arena, result.report.errors);
        try errors.append(arena, .{
            .id = "fabrication-identity-incomplete",
            .message = try std.fmt.allocPrint(arena, "fabrication identity mark could not be generated ({s}); release is blocked", .{@errorName(err)}),
        });
        result.report.errors = errors.items;
        result.internal_complete = false;
        return .{ .short_hex = @splat('0'), .digest_hex = @splat('0'), .text = null };
    };
}

const unavailable_read_set = "evaluation-read-set-unavailable-00000000000000000000000000000000".*;
const ReadSet = struct { sha256: [64]u8, complete: bool };

fn hashField(hash: *Sha256, value: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, @intCast(value.len), .little);
    hash.update(&length);
    hash.update(value);
}

fn evaluationReadSet(arena: std.mem.Allocator, evaluator: *Evaluator) ReadSet {
    var names: std.ArrayList([]const u8) = .empty;
    var iterator = evaluator.loaded_files.keyIterator();
    while (iterator.next()) |name| {
        const canonical = infra_fs.canonicalPathAlloc(arena, name.*) catch
            return .{ .sha256 = unavailable_read_set, .complete = false };
        names.append(arena, canonical) catch return .{ .sha256 = unavailable_read_set, .complete = false };
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    var hash = Sha256.init(.{});
    for (names.items) |name| {
        const bytes = infra_fs.cwd().readFileAlloc(arena, name, 16 * 1024 * 1024) catch
            return .{ .sha256 = unavailable_read_set, .complete = false };
        hashField(&hash, name);
        hashField(&hash, bytes);
    }
    var digest: [Sha256.digest_length]u8 = undefined;
    hash.final(&digest);
    return .{ .sha256 = std.fmt.bytesToHex(digest, .lower), .complete = names.items.len > 0 };
}

fn checksSidecarLoaded(arena: std.mem.Allocator, project_dir: []const u8, name: []const u8, evaluator: *Evaluator) bool {
    const path = paths.designSiblingPath(arena, project_dir, name, ".checks.sexp") catch return false;
    infra_fs.cwd().access(path, .{}) catch |err| return err == error.FileNotFound;
    const wanted = infra_fs.canonicalPathAlloc(arena, path) catch return false;
    var iterator = evaluator.loaded_files.keyIterator();
    while (iterator.next()) |loaded| {
        const canonical = infra_fs.canonicalPathAlloc(arena, loaded.*) catch continue;
        if (std.mem.eql(u8, canonical, wanted)) return true;
    }
    return false;
}

fn policyEntries(arena: std.mem.Allocator, rules: drc_rules.Rules) std.mem.Allocator.Error![]const fab_release.PolicyEntry {
    var result: std.ArrayList(fab_release.PolicyEntry) = .empty;
    for (@typeInfo(drc.Kind).@"enum".field_names, 0..) |field_name, index| {
        const action = rules.ov[index] orelse continue;
        try result.append(arena, .{ .kind = field_name, .action = @tagName(action) });
    }
    return result.toOwnedSlice(arena);
}

/// Run full composed DRC, physical readiness, strict schematic preflight and
/// persisted BOM freshness over one exact board snapshot.
pub fn check(arena: std.mem.Allocator, input: Input) std.mem.Allocator.Error!Result {
    const read_set = if (input.evaluator) |evaluator|
        evaluationReadSet(arena, evaluator)
    else
        ReadSet{ .sha256 = unavailable_read_set, .complete = false };
    const physical = input.physical;
    const composed = drc_rules.checkRelease(arena, input.project_dir, input.name, .{
        .placement = physical.placement,
        .routed = physical.routed,
        .clearance = physical.placement.rules.design.clearance,
        .zones = physical.zones,
        .texts = physical.texts,
    });
    const report = try fab_readiness.check(arena, physical.placement, physical.copper, .{
        .from_saved_layout = input.release.from_saved,
        .keep_dnp = input.release.keep_dnp,
        .conn = composed.net_report.connectivity,
        .release = .{
            .composed_drc = composed.effective,
            .composed_drc_complete = composed.complete,
            .authored_board_w = input.release.board.w,
            .authored_board_h = input.release.board.h,
            .authored_corner_radius = input.release.board.corner_radius,
        },
    });
    const block = input.block orelse {
        var errors: std.ArrayList(fab_readiness.Item) = .empty;
        try errors.appendSlice(arena, report.errors);
        try errors.append(arena, .{ .id = "schematic-check-failed", .message = "strict schematic preflight could not resolve the design" });
        return .{
            .report = .{ .errors = errors.items, .warnings = report.warnings, .stats = report.stats },
            .drc = composed,
            .policy = try policyEntries(arena, composed.rules),
            .evaluation = .{
                .block = null,
                .dependencies = &.{},
                .sha256 = read_set.sha256,
                .reviewed_inputs_sha256 = @splat('0'),
            },
            .internal_complete = false,
        };
    };
    const evaluator = input.evaluator orelse {
        var errors: std.ArrayList(fab_readiness.Item) = .empty;
        try errors.appendSlice(arena, report.errors);
        try errors.append(arena, .{ .id = "schematic-check-failed", .message = "strict schematic preflight has no evaluator snapshot" });
        return .{
            .report = .{ .errors = errors.items, .warnings = report.warnings, .stats = report.stats },
            .drc = composed,
            .policy = try policyEntries(arena, composed.rules),
            .evaluation = .{
                .block = block,
                .dependencies = &.{},
                .sha256 = read_set.sha256,
                .reviewed_inputs_sha256 = @splat('0'),
            },
            .internal_complete = false,
        };
    };
    const reviewed_before = try fab_release.reviewedInputDigest(arena, input.project_dir, block);
    const strict = try fab_schematic_gate.append(arena, report, evaluator, block, input.project_dir, input.release.keep_dnp);
    const reviewed_after = try fab_release.reviewedInputDigest(arena, input.project_dir, block);
    const reviewed_complete = reviewed_before.complete and reviewed_after.complete and
        std.mem.eql(u8, &reviewed_before.sha256, &reviewed_after.sha256);
    const bom_path = paths.designSiblingPath(arena, input.project_dir, input.name, ".bom") catch null;
    const bom_complete = if (bom_path) |path| bom.existingSidecarMatches(arena, block, path, input.project_dir) catch false else false;
    var release_report = strict;
    if (!input.release.layout_evidence_complete) {
        var errors: std.ArrayList(fab_readiness.Item) = .empty;
        try errors.appendSlice(arena, release_report.errors);
        try errors.append(arena, .{
            .id = "layout-evidence-incomplete",
            .message = "the selected saved layout contains malformed/defaulted manufacturing records, or only an optimizer cache was available; save a structurally complete layout before release",
        });
        release_report.errors = errors.items;
    }
    if (!bom_complete) {
        var errors: std.ArrayList(fab_readiness.Item) = .empty;
        try errors.appendSlice(arena, release_report.errors);
        try errors.append(arena, .{
            .id = "bom-evidence-incomplete",
            .message = "the persisted BOM is missing, malformed, or stale against component/value/net identity; rebuild before release",
        });
        release_report.errors = errors.items;
    }
    const checks_complete = checksSidecarLoaded(arena, input.project_dir, input.name, evaluator);
    if (!checks_complete or !read_set.complete) {
        var errors: std.ArrayList(fab_readiness.Item) = .empty;
        try errors.appendSlice(arena, release_report.errors);
        try errors.append(arena, .{
            .id = "verification-evidence-incomplete",
            .message = "the exact evaluator read-set or an existing .checks.sexp sidecar could not be loaded; release is blocked",
        });
        release_report.errors = errors.items;
    }
    if (!reviewed_complete) {
        var errors: std.ArrayList(fab_readiness.Item) = .empty;
        try errors.appendSlice(arena, release_report.errors);
        try errors.append(arena, .{
            .id = "reviewed-input-evidence-incomplete",
            .message = "one or more datasheet PDFs consumed by strict preflight could not be read and locked",
        });
        release_report.errors = errors.items;
    }
    return .{
        .report = release_report,
        .drc = composed,
        .policy = try policyEntries(arena, composed.rules),
        .evaluation = .{
            .block = block,
            .dependencies = try module_metadata.collectDependencies(arena, input.project_dir, block),
            .sha256 = read_set.sha256,
            .reviewed_inputs_sha256 = reviewed_after.sha256,
        },
        .internal_complete = input.release.layout_evidence_complete and bom_complete and checks_complete and
            read_set.complete and reviewed_complete and identityComplete(release_report),
    };
}
