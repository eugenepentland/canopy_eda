//! Revision-locked evidence and report writers for a PCB manufacturing ZIP.
//!
//! The lock binds the exact source, evaluated BOM identities, centroid mode,
//! deterministic CAM digest, strict readiness result, DRC policy/evidence,
//! design revision, project commit and tool build. A confirmation token from
//! an earlier report therefore cannot authorize a changed board.

const std = @import("std");
const builtin = @import("builtin");
const build_id = @import("build_id.zig");
const design_rule_fields = @import("design_rule_fields.zig");
const drc = @import("placement/drc.zig");
const env = @import("eval/env.zig");
const export_fab = @import("export_fab.zig");
const fab_identity = @import("fab_identity.zig");
const fab_readiness = @import("fab_readiness.zig");
const githash = @import("githash.zig");
const infra_fs = @import("infra/fs.zig");
const json_writer = @import("json_writer.zig");
const optimizer = @import("placement/optimizer.zig");
const paths = @import("paths.zig");
const module_metadata = @import("module_metadata.zig");
const pcb_rules_json = @import("serve/pcb_rules_json.zig");
const subprocess = @import("serve/subprocess.zig");
const zipfile = @import("zipfile.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;

/// One resolved DRC policy action included in the release audit.
pub const PolicyEntry = struct {
    kind: []const u8,
    action: []const u8,
};

/// Evaluated physical, schematic, DRC, and source evidence for one release.
pub const Evidence = struct {
    report: fab_readiness.Report,
    design: struct {
        placement: optimizer.Placement,
        revision: env.Revision,
        stackup: env.StackupSpec,
        keep_dnp: bool = false,
        block: ?*const env.DesignBlock = null,
        layout_name: []const u8 = "blessed",
        dependencies: []const module_metadata.Dependency = &.{},
    },
    mark: fab_identity.Mark,
    drc: struct {
        raw: []const drc.Violation,
        effective: []const drc.Violation,
        complete: bool,
        internal_complete: bool = true,
        policy: []const PolicyEntry = &.{},
    },
    inputs: struct {
        evaluation_sha256: [64]u8 = "0000000000000000000000000000000000000000000000000000000000000000".*,
        reviewed_sha256: [64]u8 = "0000000000000000000000000000000000000000000000000000000000000000".*,
        consumed_sha256: [64]u8 = "0000000000000000000000000000000000000000000000000000000000000000".*,
        source_sha256: [64]u8 = "0000000000000000000000000000000000000000000000000000000000000000".*,
        layout_sha256: [64]u8 = "0000000000000000000000000000000000000000000000000000000000000000".*,
        bom_sha256: [64]u8 = "0000000000000000000000000000000000000000000000000000000000000000".*,
    } = .{},
};

/// Immutable digests and source state bound into an authorization token.
pub const Lock = struct {
    token: [64]u8,
    project_commit: []const u8,
    tool_commit: []const u8,
    inputs: struct {
        source_sha256: [64]u8,
        layout_sha256: [64]u8,
        bom_evidence_sha256: [64]u8,
        dependency_sha256: [64]u8,
        consumed_sha256: [64]u8,
    },
    outputs: struct {
        bom_sha256: [64]u8,
        centroid_sha256: [64]u8,
        rules_sha256: [64]u8,
    },
    project_status: ProjectStatus,
};

/// Reproducible Git state that every release snapshot must remain on.
pub const ProjectState = struct {
    commit: []const u8,
    status: ProjectStatus,
};

/// Whether Git can reproduce every tracked or untracked release input.
pub const ProjectStatus = enum {
    clean,
    dirty,
    changed,
    ambiguous,
    unavailable,
};

/// Absolute release-input paths used to pick exact entries from a read trace.
pub const InputPaths = struct {
    source: []const u8,
    checks: []const u8,
    layout: []const u8,
    bom: []const u8,

    pub fn deinit(self: InputPaths, allocator: std.mem.Allocator) void {
        allocator.free(self.source);
        allocator.free(self.checks);
        allocator.free(self.layout);
        allocator.free(self.bom);
    }
};

pub const InputPathError = std.mem.Allocator.Error || error{AmbiguousSource};

/// Resolve all release sidecar paths from one unique source directory,
/// returning null only for an unsafe/missing design name.
pub fn inputPaths(allocator: std.mem.Allocator, project_dir: []const u8, name: []const u8) InputPathError!?InputPaths {
    const canonical_project = infra_fs.canonicalPathAlloc(allocator, project_dir) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer allocator.free(canonical_project);
    const source = paths.designSourcePathUnique(allocator, canonical_project, name) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidName => return null,
        error.AmbiguousName => return error.AmbiguousSource,
    };
    errdefer allocator.free(source);
    const source_dir = std.fs.path.dirname(source) orelse return null;
    const checks = try std.fmt.allocPrint(allocator, "{s}/{s}.checks.sexp", .{ source_dir, name });
    errdefer allocator.free(checks);
    const layout = try std.fmt.allocPrint(allocator, "{s}/{s}.layouts.json", .{ source_dir, name });
    errdefer allocator.free(layout);
    const bom = try std.fmt.allocPrint(allocator, "{s}/{s}.bom", .{ source_dir, name });
    return .{ .source = source, .checks = checks, .layout = layout, .bom = bom };
}

/// Exact input digests selected from the one release read trace.
pub const TracedInputs = struct {
    source: [64]u8 = @splat('0'),
    layout: [64]u8 = @splat('0'),
    bom: [64]u8 = @splat('0'),
    complete: bool = false,
    ambiguous: bool = false,
};

/// Bind source/layout/BOM evidence to exactly the bytes consumed by parsers.
pub fn tracedInputs(
    allocator: std.mem.Allocator,
    trace: *const infra_fs.ReadTrace,
    project_dir: []const u8,
    name: []const u8,
) std.mem.Allocator.Error!TracedInputs {
    const resolved = inputPaths(allocator, project_dir, name) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.AmbiguousSource => return .{ .ambiguous = true },
    };
    const input_paths = resolved orelse return .{};
    defer input_paths.deinit(allocator);
    const source = trace.closureDigest(&.{ input_paths.source, input_paths.checks });
    const layout = trace.digestForPath(input_paths.layout) orelse return .{ .source = source };
    const bom_digest = trace.digestForPath(input_paths.bom) orelse return .{ .source = source, .layout = layout };
    if (trace.digestForPath(input_paths.source) == null) return .{ .source = source, .layout = layout, .bom = bom_digest };
    return .{ .source = source, .layout = layout, .bom = bom_digest, .complete = true };
}

fn gitStatusClean(allocator: std.mem.Allocator, project_dir: []const u8) std.mem.Allocator.Error!?bool {
    const argv = [_][]const u8{
        "git", "-C", project_dir, "status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignore-submodules=none",
    };
    const result = try subprocess.runCaptured(allocator, &argv, 4 * 1024 * 1024, 5000);
    defer result.deinit(allocator);
    if (result.outcome != .ok or (result.exit_code orelse 1) != 0) return null;
    return result.stdout.len == 0;
}

fn unavailableProjectState(allocator: std.mem.Allocator) std.mem.Allocator.Error!ProjectState {
    return .{ .commit = try allocator.dupe(u8, "unavailable"), .status = .unavailable };
}

/// Capture an atomic-enough full-HEAD/clean-worktree identity. Two status reads
/// and two direct HEAD reads prevent a concurrent commit from pairing an old
/// commit label with a newly-clean tree. Dirty/unavailable state is returned,
/// not thrown, so readiness can still disclose every independent board issue.
pub fn captureProjectState(allocator: std.mem.Allocator, project_dir: []const u8) std.mem.Allocator.Error!ProjectState {
    const before = githash.fullHash(infra_fs.currentIo(), allocator, project_dir) orelse
        return unavailableProjectState(allocator);
    const clean_before = (gitStatusClean(allocator, project_dir) catch |err| {
        allocator.free(before);
        return err;
    }) orelse {
        allocator.free(before);
        return unavailableProjectState(allocator);
    };
    const after = githash.fullHash(infra_fs.currentIo(), allocator, project_dir) orelse {
        allocator.free(before);
        return unavailableProjectState(allocator);
    };
    const clean_after = (gitStatusClean(allocator, project_dir) catch |err| {
        allocator.free(before);
        allocator.free(after);
        return err;
    }) orelse {
        allocator.free(before);
        allocator.free(after);
        return unavailableProjectState(allocator);
    };
    const unchanged = std.mem.eql(u8, before, after);
    allocator.free(before);
    return .{
        .commit = after,
        .status = if (clean_before and clean_after and unchanged) .clean else .dirty,
    };
}

fn hashString(hash: *Sha256, value: []const u8) void {
    var len: [8]u8 = undefined;
    std.mem.writeInt(u64, &len, @intCast(value.len), .little);
    hash.update(&len);
    hash.update(value);
}

fn hashCount(hash: *Sha256, value: usize) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, @intCast(value), .little);
    hash.update(&bytes);
}

fn hashFloat(hash: *Sha256, value: f64) void {
    var bytes = std.mem.toBytes(value);
    if (builtin.cpu.arch.endian() == .big) std.mem.reverse(u8, &bytes);
    hash.update(&bytes);
}

fn projectStatusFinding(status: ProjectStatus) ?fab_readiness.Item {
    return switch (status) {
        .clean => null,
        .dirty => .{
            .id = "source-worktree-dirty",
            .message = "release inputs have tracked or untracked changes; commit the exact board/library state before release",
        },
        .changed => .{
            .id = "source-snapshot-changed",
            .message = "release inputs changed while the board snapshot was evaluated; rerun readiness on a stable source revision",
        },
        .ambiguous => .{
            .id = "source-bundle-ambiguous",
            .message = "more than one source has this design basename, so one unambiguous source/layout/BOM/rules bundle cannot be revision-locked",
        },
        .unavailable => .{
            .id = "source-revision-unavailable",
            .message = "a clean full Git revision and all reviewed inputs could not be proven; release is blocked",
        },
    };
}

fn hashItems(hash: *Sha256, items: []const fab_readiness.Item) void {
    for (items) |item| {
        hashString(hash, item.id);
        hashString(hash, item.message);
        hashString(hash, item.net orelse "");
        hashString(hash, item.ref orelse "");
        hashCount(hash, item.count);
    }
}

fn hashStats(hash: *Sha256, stats: fab_readiness.Stats) void {
    hashCount(hash, stats.parts);
    hashCount(hash, stats.nets);
    hashCount(hash, stats.tracks);
    hashCount(hash, stats.vias);
    hashCount(hash, stats.routable_nets);
    hashCount(hash, stats.connected_nets);
    hashCount(hash, stats.connectivity.drc_violations);
    hashCount(hash, stats.connectivity.dangling_copper);
    hashCount(hash, stats.connectivity.implicit_junctions);
    hashCount(hash, stats.connectivity.hairline_gaps);
    hash.update(&.{ @intFromBool(stats.connectivity.coarsened), @intFromBool(stats.has_outline) });
    hashCount(hash, stats.dnp_parts);
}

fn hashViolation(hash: *Sha256, violation: drc.Violation) void {
    hashString(hash, @tagName(violation.kind));
    hashString(hash, @tagName(violation.severity));
    hashFloat(hash, violation.x);
    hashFloat(hash, violation.y);
    hashFloat(hash, violation.gap);
    hashFloat(hash, violation.clearance);
    hashString(hash, violation.who.pad_a);
    hashString(hash, violation.who.pad_b);
    var parties: [20]u8 = undefined;
    std.mem.writeInt(i32, parties[0..4], violation.who.net_a, .little);
    std.mem.writeInt(i32, parties[4..8], violation.who.net_b, .little);
    std.mem.writeInt(i32, parties[8..12], violation.who.part_a, .little);
    std.mem.writeInt(i32, parties[12..16], violation.who.part_b, .little);
    std.mem.writeInt(i32, parties[16..20], violation.who.track_a, .little);
    hash.update(&parties);
    hash.update(&.{if (violation.layer) |layer| layer.int() else 0xff});
    hash.update(&.{@intFromBool(violation.who.bridge != null)});
    if (violation.who.bridge) |bridge| for (bridge) |coordinate| hashFloat(hash, coordinate);
}

fn hashEvaluatedBom(hash: *Sha256, placement: optimizer.Placement) void {
    for (placement.instances) |instance| {
        hashString(hash, instance.ref_des);
        hashString(hash, instance.component);
        hashString(hash, instance.value);
        hashString(hash, instance.footprint);
        hashString(hash, instance.uuid);
        hash.update(&.{@intFromBool(instance.dnp)});
        for (instance.properties) |property| {
            hashString(hash, property.key);
            hashString(hash, property.value);
        }
    }
}

fn dependencyDigest(evidence: Evidence) [64]u8 {
    var hash = Sha256.init(.{});
    hashString(&hash, &evidence.inputs.evaluation_sha256);
    for (evidence.design.dependencies) |dependency| {
        hashString(&hash, dependency.source);
        hashString(&hash, dependency.module);
        hashString(&hash, &dependency.source_sha256);
    }
    var digest: [Sha256.digest_length]u8 = undefined;
    hash.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

/// Hash the exact saved-layout sidecar bytes selected from during fab view
/// construction. Layout sidecars are intentionally Git-ignored, so this
/// explicit digest brackets them across evaluation and CAM generation.
pub fn savedLayoutDigest(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
) std.mem.Allocator.Error![64]u8 {
    const layout_path = paths.designSiblingPath(allocator, project_dir, name, ".layouts.json") catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidName => {
            var invalid: [Sha256.digest_length]u8 = undefined;
            Sha256.hash("invalid-layout-name", &invalid, .{});
            return std.fmt.bytesToHex(invalid, .lower);
        },
    };
    defer allocator.free(layout_path);
    const owned = infra_fs.cwd().readFileAlloc(allocator, layout_path, 64 * 1024 * 1024) catch null;
    defer if (owned) |bytes| allocator.free(bytes);
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(owned orelse "unavailable", &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// Hash the persisted BOM sidecar bytes applied read-only during evaluation.
/// BOM sidecars are Git-ignored, so the release flow compares this digest to a
/// baseline captured before resolving the block.
pub fn savedBomDigest(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
) std.mem.Allocator.Error![64]u8 {
    const bom_path = paths.designSiblingPath(allocator, project_dir, name, ".bom") catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidName => {
            var invalid: [Sha256.digest_length]u8 = undefined;
            Sha256.hash("invalid-bom-name", &invalid, .{});
            return std.fmt.bytesToHex(invalid, .lower);
        },
    };
    defer allocator.free(bom_path);
    const owned = infra_fs.cwd().readFileAlloc(allocator, bom_path, 64 * 1024 * 1024) catch null;
    defer if (owned) |bytes| allocator.free(bytes);
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(owned orelse "unavailable", &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// Bind a lock to state captured before the first evaluator/layout/BOM read.
/// Any mismatch is non-waivable even when the later snapshot itself is clean.
pub fn bindBaseline(
    lock: *Lock,
    before: ProjectState,
    layout_sha256: [64]u8,
    bom_evidence_sha256: [64]u8,
) void {
    const original_status = lock.project_status;
    if (lock.project_status == .ambiguous) {
        // Unique source identity is already the strongest applicable blocker.
    } else if (before.status == .unavailable or lock.project_status == .unavailable) {
        lock.project_status = .unavailable;
    } else if (before.status == .dirty or lock.project_status == .dirty) {
        lock.project_status = .dirty;
    } else if (baselineInputsChanged(lock, before, layout_sha256, bom_evidence_sha256)) {
        lock.project_status = .changed;
    }
    if (lock.project_status != original_status) invalidate(lock, "release-baseline-status-changed");
}

/// Apply exact-consumed-input verification after all parsers have finished.
pub fn bindTracedInputs(lock: *Lock, traced: TracedInputs, verified: bool) void {
    if (traced.ambiguous) {
        lock.project_status = .ambiguous;
        invalidate(lock, "release-source-bundle-ambiguous");
    } else if (!traced.complete or !verified) {
        lock.project_status = .changed;
        invalidate(lock, "consumed-inputs-changed");
    }
}

fn baselineInputsChanged(lock: *const Lock, before: ProjectState, layout_sha256: [64]u8, bom_evidence_sha256: [64]u8) bool {
    if (!std.mem.eql(u8, before.commit, lock.project_commit)) return true;
    if (!std.mem.eql(u8, &layout_sha256, &lock.inputs.layout_sha256)) return true;
    return !std.mem.eql(u8, &bom_evidence_sha256, &lock.inputs.bom_evidence_sha256);
}

/// Make a post-lock evidence failure produce a token distinct from any clean
/// report. This prevents a token copied from a hard-blocked report from later
/// authorizing a clean snapshot whose pre-bind token happened to match.
pub fn invalidate(lock: *Lock, reason: []const u8) void {
    var hash = Sha256.init(.{});
    hashString(&hash, "netlisp-fab-release-invalid-v1");
    hashString(&hash, &lock.token);
    hashString(&hash, @tagName(lock.project_status));
    hashString(&hash, reason);
    var digest: [Sha256.digest_length]u8 = undefined;
    hash.final(&digest);
    lock.token = std.fmt.bytesToHex(digest, .lower);
}

/// Digest and completeness of ignored/non-Git files consulted by preflight.
pub const ReviewedInputDigest = struct {
    sha256: [64]u8,
    complete: bool,
};

fn collectReviewedNames(
    allocator: std.mem.Allocator,
    block: *const env.DesignBlock,
    names: *std.StringHashMapUnmanaged(void),
) std.mem.Allocator.Error!void {
    for (block.instances) |instance| {
        const review = instance.docs.review orelse continue;
        if (review.datasheet.len == 0) continue;
        try names.put(allocator, review.datasheet, {});
    }
    for (block.sub_blocks) |sub| try collectReviewedNames(allocator, sub.block, names);
}

fn safeReviewedName(name: []const u8) bool {
    return name.len > 0 and std.mem.indexOfAny(u8, name, "/\\\x00") == null and
        !std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..");
}

/// Hash exactly the ignored datasheet PDFs strict preflight reads. Tracked
/// source/library inputs are reconstructed by the clean full Git commit; this
/// closes the intentionally ignored PDF portion of the evidence set without
/// rescanning the entire multi-hundred-megabyte library.
pub fn reviewedInputDigest(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    block: *const env.DesignBlock,
) std.mem.Allocator.Error!ReviewedInputDigest {
    var names = std.StringHashMapUnmanaged(void).empty;
    defer names.deinit(allocator);
    try collectReviewedNames(allocator, block, &names);
    var ordered: std.ArrayList([]const u8) = .empty;
    defer ordered.deinit(allocator);
    var iterator = names.keyIterator();
    while (iterator.next()) |name| try ordered.append(allocator, name.*);
    std.mem.sort([]const u8, ordered.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    var complete = true;
    var hash = Sha256.init(.{});
    for (ordered.items) |name| {
        hashString(&hash, name);
        if (!safeReviewedName(name)) {
            complete = false;
            hashString(&hash, "unsafe-reviewed-input");
            continue;
        }
        const path = std.fs.path.join(allocator, &.{ project_dir, "lib", "datasheets", name }) catch |err| return err;
        defer allocator.free(path);
        const bytes = infra_fs.cwd().readFileAlloc(allocator, path, 128 * 1024 * 1024) catch {
            complete = false;
            hashString(&hash, "unreadable-reviewed-input");
            continue;
        };
        defer allocator.free(bytes);
        hashString(&hash, bytes);
    }
    var digest: [Sha256.digest_length]u8 = undefined;
    hash.final(&digest);
    return .{ .sha256 = std.fmt.bytesToHex(digest, .lower), .complete = complete };
}

/// Build a token that authorizes only this exact evaluated release snapshot.
pub const LockError = std.mem.Allocator.Error || std.Io.Writer.Error;

/// Build the authorization token and every artifact/source digest it binds.
pub fn makeLock(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    evidence: Evidence,
) LockError!Lock {
    const project_before = try captureProjectState(allocator, project_dir);
    defer allocator.free(project_before.commit);
    const source_hex = evidence.inputs.source_sha256;
    const layout_hex = evidence.inputs.layout_sha256;
    const bom_evidence_hex = evidence.inputs.bom_sha256;

    var bom_bytes: std.Io.Writer.Allocating = .init(allocator);
    defer bom_bytes.deinit();
    try export_fab.assemblyBomCsv(
        &bom_bytes.writer,
        evidence.design.placement.instances,
        if (evidence.design.keep_dnp) .keep else .drop,
    );
    var bom_digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bom_bytes.written(), &bom_digest, .{});
    const bom_hex = std.fmt.bytesToHex(bom_digest, .lower);

    var centroid_bytes: std.Io.Writer.Allocating = .init(allocator);
    defer centroid_bytes.deinit();
    try export_fab.centroidCsv(
        &centroid_bytes.writer,
        evidence.design.placement.parts,
        evidence.design.placement.instances,
        export_fab.frameFor(evidence.design.placement),
        if (evidence.design.keep_dnp) .keep else .drop,
    );
    var centroid_digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(centroid_bytes.written(), &centroid_digest, .{});
    const centroid_hex = std.fmt.bytesToHex(centroid_digest, .lower);

    var rules_bytes: std.Io.Writer.Allocating = .init(allocator);
    defer rules_bytes.deinit();
    try writeRulesJson(&rules_bytes.writer, evidence);
    var rules_digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(rules_bytes.written(), &rules_digest, .{});
    const rules_hex = std.fmt.bytesToHex(rules_digest, .lower);
    const dependency_hex = dependencyDigest(evidence);
    const reviewed = if (evidence.design.block) |block|
        try reviewedInputDigest(allocator, project_dir, block)
    else
        ReviewedInputDigest{ .sha256 = @splat('0'), .complete = false };
    const project_after = try captureProjectState(allocator, project_dir);
    const project_status: ProjectStatus = if (project_before.status == .unavailable or project_after.status == .unavailable or !reviewed.complete)
        .unavailable
    else if (project_before.status == .dirty or project_after.status == .dirty)
        .dirty
    else if (!std.mem.eql(u8, project_before.commit, project_after.commit) or !std.mem.eql(u8, &reviewed.sha256, &evidence.inputs.reviewed_sha256))
        .changed
    else
        .clean;
    const project_commit = project_after.commit;
    const tool_commit = build_id.current();

    var hash = Sha256.init(.{});
    hashString(&hash, "netlisp-fab-release-v1");
    hashString(&hash, name);
    hashString(&hash, &source_hex);
    hashString(&hash, project_commit);
    hashString(&hash, tool_commit);
    hashString(&hash, evidence.design.revision.id);
    hashString(&hash, evidence.design.revision.date);
    hashString(&hash, &evidence.mark.digest_hex);
    hashString(&hash, evidence.design.layout_name);
    hashString(&hash, &layout_hex);
    hashString(&hash, &bom_evidence_hex);
    hashString(&hash, &bom_hex);
    hashString(&hash, &centroid_hex);
    hashString(&hash, &rules_hex);
    hashString(&hash, &dependency_hex);
    hashString(&hash, &evidence.inputs.evaluation_sha256);
    hashString(&hash, &evidence.inputs.reviewed_sha256);
    hashString(&hash, &evidence.inputs.consumed_sha256);
    hashString(&hash, @tagName(project_status));
    hash.update(&.{ @intFromBool(evidence.design.keep_dnp), @intFromBool(evidence.drc.complete), @intFromBool(evidence.drc.internal_complete) });
    hashItems(&hash, evidence.report.errors);
    hashItems(&hash, evidence.report.warnings);
    hashStats(&hash, evidence.report.stats);
    hashEvaluatedBom(&hash, evidence.design.placement);
    for (evidence.drc.raw) |violation| hashViolation(&hash, violation);
    for (evidence.drc.policy) |entry| {
        hashString(&hash, entry.kind);
        hashString(&hash, entry.action);
    }
    for (evidence.design.dependencies) |dependency| {
        hashString(&hash, dependency.source);
        hashString(&hash, dependency.module);
        hashString(&hash, &dependency.source_sha256);
    }
    var token_digest: [Sha256.digest_length]u8 = undefined;
    hash.final(&token_digest);
    return .{
        .token = std.fmt.bytesToHex(token_digest, .lower),
        .project_commit = project_commit,
        .tool_commit = tool_commit,
        .inputs = .{
            .source_sha256 = source_hex,
            .layout_sha256 = layout_hex,
            .bom_evidence_sha256 = bom_evidence_hex,
            .dependency_sha256 = dependency_hex,
            .consumed_sha256 = evidence.inputs.consumed_sha256,
        },
        .outputs = .{
            .bom_sha256 = bom_hex,
            .centroid_sha256 = centroid_hex,
            .rules_sha256 = rules_hex,
        },
        .project_status = project_status,
    };
}

/// The readiness API plus the lock the user must echo to export.
pub const ReadinessJsonError = std.mem.Allocator.Error || std.Io.Writer.Error || error{InvalidReadinessJson};
pub const ReportWriteError = std.mem.Allocator.Error || std.Io.Writer.Error;

/// Write readiness findings and the token only a complete snapshot may use.
pub fn writeReadinessJson(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    evidence: Evidence,
    lock: Lock,
) ReadinessJsonError!void {
    var source_errors: std.ArrayList(fab_readiness.Item) = .empty;
    defer source_errors.deinit(allocator);
    try source_errors.appendSlice(allocator, evidence.report.errors);
    if (projectStatusFinding(lock.project_status)) |finding| try source_errors.append(allocator, finding);
    var release_report = evidence.report;
    release_report.errors = source_errors.items;
    var base: std.Io.Writer.Allocating = .init(allocator);
    defer base.deinit();
    try fab_readiness.writeJson(&base.writer, release_report);
    const bytes = base.written();
    if (bytes.len == 0 or bytes[bytes.len - 1] != '}') return error.InvalidReadinessJson;
    try writer.writeAll(bytes[0 .. bytes.len - 1]);
    try writer.writeAll(",\"release_token\":");
    const authorizable = evidence.drc.complete and evidence.drc.internal_complete and lock.project_status == .clean;
    if (authorizable)
        try json_writer.writeString(writer, &lock.token)
    else
        try writer.writeAll("null");
    try writer.writeAll(",\"revision\":");
    try json_writer.writeString(writer, evidence.design.revision.id);
    try writer.writeAll(",\"part_number\":");
    try json_writer.writeString(writer, evidence.mark.part_number);
    try writer.writeAll(",\"fab_id\":");
    try json_writer.writeString(writer, &evidence.mark.short_hex);
    try writer.writeAll(",\"source_sha256\":");
    try json_writer.writeString(writer, &lock.inputs.source_sha256);
    const needs_waiver = release_report.errors.len > 0 or release_report.warnings.len > 0 or evidence.drc.raw.len > evidence.drc.effective.len;
    try writer.writeAll(",\"project_commit\":");
    try json_writer.writeString(writer, lock.project_commit);
    try writer.writeAll(",\"tool_commit\":");
    try json_writer.writeString(writer, lock.tool_commit);
    try writer.writeAll(",\"layout\":");
    try json_writer.writeString(writer, evidence.design.layout_name);
    try writer.writeAll(",\"layout_sha256\":");
    try json_writer.writeString(writer, &lock.inputs.layout_sha256);
    try writer.writeAll(",\"bom_evidence_sha256\":");
    try json_writer.writeString(writer, &lock.inputs.bom_evidence_sha256);
    try writer.writeAll(",\"evaluated_dependency_sha256\":");
    try json_writer.writeString(writer, &lock.inputs.dependency_sha256);
    try writer.writeAll(",\"evaluation_read_set_sha256\":");
    try json_writer.writeString(writer, &evidence.inputs.evaluation_sha256);
    try writer.writeAll(",\"reviewed_inputs_sha256\":");
    try json_writer.writeString(writer, &evidence.inputs.reviewed_sha256);
    try writer.writeAll(",\"consumed_inputs_sha256\":");
    try json_writer.writeString(writer, &lock.inputs.consumed_sha256);
    try writer.writeAll(",\"project_status\":");
    try json_writer.writeString(writer, @tagName(lock.project_status));
    try writer.writeAll(",\"raw_drc\":[");
    for (evidence.drc.raw, 0..) |violation, index| {
        if (index > 0) try writer.writeByte(',');
        try writeViolationJson(writer, evidence, violation);
    }
    try writer.print("],\"raw_drc_count\":{d},\"effective_drc_count\":{d},\"ignored_drc_count\":{d},\"internal_checks_complete\":{s},\"needs_waiver\":{s},\"confirmation_required\":true}}", .{
        evidence.drc.raw.len,
        evidence.drc.effective.len,
        evidence.drc.raw.len -| evidence.drc.effective.len,
        if (evidence.drc.complete and evidence.drc.internal_complete and lock.project_status == .clean) "true" else "false",
        if (needs_waiver) "true" else "false",
    });
}

fn writeItemJson(writer: *std.Io.Writer, item: fab_readiness.Item) !void {
    try writer.writeAll("{\"id\":");
    try json_writer.writeString(writer, item.id);
    try writer.writeAll(",\"message\":");
    try json_writer.writeString(writer, item.message);
    if (item.net) |net| {
        try writer.writeAll(",\"net\":");
        try json_writer.writeString(writer, net);
    }
    if (item.ref) |ref| {
        try writer.writeAll(",\"ref\":");
        try json_writer.writeString(writer, ref);
    }
    if (item.count > 0) try writer.print(",\"count\":{d}", .{item.count});
    try writer.writeByte('}');
}

fn writeViolationJson(writer: *std.Io.Writer, evidence: Evidence, violation: drc.Violation) !void {
    try writer.writeAll("{\"kind\":");
    try json_writer.writeString(writer, @tagName(violation.kind));
    try writer.writeAll(",\"severity\":");
    try json_writer.writeString(writer, @tagName(violation.severity));
    try writer.writeAll(",\"x_mm\":");
    try writeFinite(writer, violation.x);
    try writer.writeAll(",\"y_mm\":");
    try writeFinite(writer, violation.y);
    try writer.writeAll(",\"gap_mm\":");
    try writeFinite(writer, violation.gap);
    try writer.writeAll(",\"required_mm\":");
    try writeFinite(writer, violation.clearance);
    try writer.print(",\"net_a\":{d},\"net_b\":{d},\"part_a\":{d},\"part_b\":{d},\"track_a\":{d}", .{
        violation.who.net_a,
        violation.who.net_b,
        violation.who.part_a,
        violation.who.part_b,
        violation.who.track_a,
    });
    if (violation.who.net_a >= 0 and @as(usize, @intCast(violation.who.net_a)) < evidence.design.placement.nets.len) {
        try writer.writeAll(",\"net_a_name\":");
        try json_writer.writeString(writer, evidence.design.placement.nets[@intCast(violation.who.net_a)].name);
    }
    if (violation.who.net_b >= 0 and @as(usize, @intCast(violation.who.net_b)) < evidence.design.placement.nets.len) {
        try writer.writeAll(",\"net_b_name\":");
        try json_writer.writeString(writer, evidence.design.placement.nets[@intCast(violation.who.net_b)].name);
    }
    if (violation.who.part_a >= 0 and @as(usize, @intCast(violation.who.part_a)) < evidence.design.placement.parts.len) {
        try writer.writeAll(",\"part_a_ref\":");
        try json_writer.writeString(writer, evidence.design.placement.parts[@intCast(violation.who.part_a)].ref_des);
    }
    if (violation.who.part_b >= 0 and @as(usize, @intCast(violation.who.part_b)) < evidence.design.placement.parts.len) {
        try writer.writeAll(",\"part_b_ref\":");
        try json_writer.writeString(writer, evidence.design.placement.parts[@intCast(violation.who.part_b)].ref_des);
    }
    try writer.writeAll(",\"pad_a\":");
    try json_writer.writeString(writer, violation.who.pad_a);
    try writer.writeAll(",\"pad_b\":");
    try json_writer.writeString(writer, violation.who.pad_b);
    if (violation.layer) |layer|
        try writer.print(",\"layer\":{d}", .{layer.int()})
    else
        try writer.writeAll(",\"layer\":null");
    if (violation.who.bridge) |bridge| {
        try writer.writeAll(",\"bridge\":[");
        for (bridge, 0..) |coordinate, index| {
            if (index > 0) try writer.writeByte(',');
            try writeFinite(writer, coordinate);
        }
        try writer.writeByte(']');
    } else try writer.writeAll(",\"bridge\":null");
    try writer.writeByte('}');
}

fn writeFinite(writer: *std.Io.Writer, value: f64) !void {
    if (std.math.isFinite(value)) return writer.print("{d}", .{value});
    return writer.writeAll("null");
}

/// Write the complete machine-readable release audit packaged beside CAM.
pub fn writeMachineReport(
    writer: *std.Io.Writer,
    evidence: Evidence,
    lock: Lock,
    waiver: bool,
) ReportWriteError!void {
    try writer.writeAll("{\"schema\":\"netlisp-fab-release-v1\",\"release_token\":");
    try json_writer.writeString(writer, &lock.token);
    try writer.writeAll(",\"revision\":");
    try json_writer.writeString(writer, evidence.design.revision.id);
    try writer.writeAll(",\"revision_date\":");
    try json_writer.writeString(writer, evidence.design.revision.date);
    try writer.writeAll(",\"part_number\":");
    try json_writer.writeString(writer, evidence.mark.part_number);
    try writer.writeAll(",\"project_commit\":");
    try json_writer.writeString(writer, lock.project_commit);
    try writer.writeAll(",\"tool_commit\":");
    try json_writer.writeString(writer, lock.tool_commit);
    try writer.writeAll(",\"source_sha256\":");
    try json_writer.writeString(writer, &lock.inputs.source_sha256);
    try writer.writeAll(",\"fab_sha256\":");
    try json_writer.writeString(writer, &evidence.mark.digest_hex);
    try writer.writeAll(",\"layout\":");
    try json_writer.writeString(writer, evidence.design.layout_name);
    try writer.writeAll(",\"layout_sha256\":");
    try json_writer.writeString(writer, &lock.inputs.layout_sha256);
    try writer.writeAll(",\"bom_sha256\":");
    try json_writer.writeString(writer, &lock.outputs.bom_sha256);
    try writer.writeAll(",\"bom_evidence_sha256\":");
    try json_writer.writeString(writer, &lock.inputs.bom_evidence_sha256);
    try writer.writeAll(",\"centroid_sha256\":");
    try json_writer.writeString(writer, &lock.outputs.centroid_sha256);
    try writer.writeAll(",\"rules_sha256\":");
    try json_writer.writeString(writer, &lock.outputs.rules_sha256);
    try writer.writeAll(",\"evaluated_dependency_sha256\":");
    try json_writer.writeString(writer, &lock.inputs.dependency_sha256);
    try writer.writeAll(",\"evaluation_read_set_sha256\":");
    try json_writer.writeString(writer, &evidence.inputs.evaluation_sha256);
    try writer.writeAll(",\"reviewed_inputs_sha256\":");
    try json_writer.writeString(writer, &evidence.inputs.reviewed_sha256);
    try writer.writeAll(",\"consumed_inputs_sha256\":");
    try json_writer.writeString(writer, &lock.inputs.consumed_sha256);
    try writer.writeAll(",\"project_status\":");
    try json_writer.writeString(writer, @tagName(lock.project_status));
    try writer.print(",\"confirmed\":true,\"waiver\":{s},\"dnp_centroid\":\"{s}\",\"drc_complete\":{s}", .{
        if (waiver) "true" else "false",
        if (evidence.design.keep_dnp) "keep" else "drop",
        if (evidence.drc.complete and evidence.drc.internal_complete and lock.project_status == .clean) "true" else "false",
    });
    try writer.writeAll(",\"errors\":[");
    for (evidence.report.errors, 0..) |item, index| {
        if (index > 0) try writer.writeByte(',');
        try writeItemJson(writer, item);
    }
    try writer.writeAll("],\"warnings\":[");
    for (evidence.report.warnings, 0..) |item, index| {
        if (index > 0) try writer.writeByte(',');
        try writeItemJson(writer, item);
    }
    try writer.writeAll("],\"raw_drc\":[");
    for (evidence.drc.raw, 0..) |violation, index| {
        if (index > 0) try writer.writeByte(',');
        try writeViolationJson(writer, evidence, violation);
    }
    try writer.writeAll("],\"module_dependencies\":[");
    for (evidence.design.dependencies, 0..) |dependency, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.writeAll("{\"source\":");
        try json_writer.writeString(writer, dependency.source);
        try writer.writeAll(",\"module\":");
        try json_writer.writeString(writer, dependency.module);
        try writer.writeAll(",\"source_sha256\":");
        try json_writer.writeString(writer, &dependency.source_sha256);
        try writer.writeByte('}');
    }
    try writer.writeAll("],\"drc_policy\":[");
    for (evidence.drc.policy, 0..) |entry, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.writeAll("{\"kind\":");
        try json_writer.writeString(writer, entry.kind);
        try writer.writeAll(",\"action\":");
        try json_writer.writeString(writer, entry.action);
        try writer.writeByte('}');
    }
    try writer.print("],\"effective_drc_count\":{d}}}", .{evidence.drc.effective.len});
}

/// Write the concise human-readable companion to the machine release audit.
pub fn writeHumanReport(writer: *std.Io.Writer, evidence: Evidence, lock: Lock, waiver: bool) std.Io.Writer.Error!void {
    try writer.print("# Fabrication release report\n\nPart number: `{s}`  \nRevision: `{s}` ({s})  \nProject commit: `{s}` ({s})  \nTool commit: `{s}`  \nDesign + checks source closure SHA-256: `{s}`  \nEvaluator read-set SHA-256: `{s}`  \nEvaluated dependency closure SHA-256: `{s}`  \nReviewed non-Git inputs SHA-256: `{s}`  \nLayout `{s}` SHA-256: `{s}`  \nCAM SHA-256: `{s}`  \nBOM SHA-256: `{s}`  \nCentroid SHA-256: `{s}`  \nRules/stackup SHA-256: `{s}`  \nRelease token: `{s}`  \nConfirmation: explicit; waiver: {s}\n\n", .{
        evidence.mark.part_number,
        evidence.design.revision.id,
        evidence.design.revision.date,
        lock.project_commit,
        @tagName(lock.project_status),
        lock.tool_commit,
        &lock.inputs.source_sha256,
        &evidence.inputs.evaluation_sha256,
        &lock.inputs.dependency_sha256,
        &evidence.inputs.reviewed_sha256,
        evidence.design.layout_name,
        &lock.inputs.layout_sha256,
        &evidence.mark.digest_hex,
        &lock.outputs.bom_sha256,
        &lock.outputs.centroid_sha256,
        &lock.outputs.rules_sha256,
        &lock.token,
        if (waiver) "yes" else "no",
    });
    try writer.print("## Remaining errors ({d})\n\n", .{evidence.report.errors.len});
    if (evidence.report.errors.len == 0) try writer.writeAll("None.\n") else for (evidence.report.errors) |item| try writer.print("- **{s}**: {s}\n", .{ item.id, item.message });
    try writer.print("\n## Remaining warnings ({d})\n\n", .{evidence.report.warnings.len});
    if (evidence.report.warnings.len == 0) try writer.writeAll("None.\n") else for (evidence.report.warnings) |item| try writer.print("- **{s}**: {s}\n", .{ item.id, item.message });
    try writer.print("\n## DRC evidence\n\nFull composed DRC completed: {s}. Raw findings: {d}; effective findings after policy: {d}. Ignored findings remain in `release-report.json`.\n", .{
        if (evidence.drc.complete) "yes" else "no",
        evidence.drc.raw.len,
        evidence.drc.effective.len,
    });
}

/// Write the effective stackup, board rules, and resolved per-net rules.
pub fn writeRulesJson(writer: *std.Io.Writer, evidence: Evidence) ReportWriteError!void {
    const rules = evidence.design.placement.rules.design;
    const stack = evidence.design.stackup;
    try writer.writeAll("{\"part_number\":");
    try json_writer.writeString(writer, evidence.mark.part_number);
    try writer.writeAll(",\"stackup\":{\"preset\":");
    try json_writer.writeString(writer, stack.preset);
    try writer.print(",\"layers\":{d},\"finished_thickness_mm\":{d},\"planes\":[", .{ stack.layers, stack.thickness });
    for (stack.planes, 0..) |plane, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.print("{{\"layer\":{d},\"net\":", .{plane.index});
        try json_writer.writeString(writer, plane.net);
        try writer.writeByte('}');
    }
    try writer.writeAll("],\"copper\":[");
    for (stack.copper, 0..) |layer, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.print("{{\"layer\":{d},\"thickness_mm\":{d},\"material\":", .{ layer.index, layer.thickness });
        try json_writer.writeString(writer, layer.material);
        try writer.writeByte('}');
    }
    try writer.writeAll("],\"dielectrics\":[");
    for (stack.dielectrics, 0..) |layer, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.print("{{\"after_layer\":{d},\"kind\":\"{s}\",\"material\":", .{ layer.after_layer, @tagName(layer.kind) });
        try json_writer.writeString(writer, layer.material);
        try writer.print(",\"thickness_mm\":{d},\"er\":{d}}}", .{ layer.thickness, layer.er });
    }
    try writer.print("],\"present\":{s}}},\"design_rules\":{{\"clearance_mm\":{d},\"min_drill_mm\":{d},\"min_annular_mm\":{d},\"hole_to_hole_mm\":{d},\"via_to_via_mm\":{d},\"min_width_mm\":{d},\"track_width_mm\":{d},\"via_dia_mm\":{d},\"via_drill_mm\":{d},\"edge_copper_mm\":{d},\"edge_component_mm\":{d},\"mask_margin_mm\":{d}", .{
        if (stack.present) "true" else "false",
        rules.clearance,
        rules.min_drill,
        rules.min_annular,
        rules.hole_to_hole,
        rules.via_to_via,
        rules.min_width,
        rules.track_width,
        rules.via_dia,
        rules.via_drill,
        rules.edge.copper,
        rules.edge.component,
        rules.mask.margin,
    });
    try writer.print(",\"{s}_mm\":{d},\"{s}_mm\":{d},\"{s}_inner_mm\":{d},\"{s}_outer_mm\":{d},\"{s}_mm\":{d},\"{s}_mm\":{d},\"ground_via_max_mm\":{d},\"via_plating_mm\":{d},\"board_thickness_mm\":{d}}},\"net_rules\":[", .{
        design_rule_fields.release.web,
        rules.mask.web,
        design_rule_fields.release.relief_radius,
        rules.mask.relief_corner_radius,
        design_rule_fields.release.pour,
        @field(rules, design_rule_fields.release.pour),
        design_rule_fields.release.pour,
        rules.pour.clearance_outer,
        design_rule_fields.release.pour_width,
        rules.pour.min_width,
        design_rule_fields.release.pour_radius,
        rules.pour.corner_radius,
        rules.pour.ground_via_max,
        evidence.design.placement.rules.physical.via_plating_mm,
        evidence.design.placement.rules.physical.board_thickness,
    });
    for (evidence.design.placement.nets, 0..) |net, index| {
        if (index > 0) try writer.writeByte(',');
        const rule = if (index < evidence.design.placement.rules.net.len) evidence.design.placement.rules.net[index] else optimizer.NetRule{};
        try writer.writeAll("{\"net\":");
        try json_writer.writeString(writer, net.name);
        try writer.writeAll(",\"class\":");
        try json_writer.writeString(writer, rule.class.name);
        try writer.print(",\"width_mm\":{d},\"clearance_mm\":{d},\"via_dia_mm\":{d},\"via_drill_mm\":{d},\"diff_gap_mm\":{d},\"impedance_ohms\":{d},\"diff_impedance_ohms\":{d},\"impedance_layer\":{d},\"ground_gap_mm\":{d},\"width_derived\":{s}}}", .{
            rule.width,
            rule.clearance,
            rule.via_dia,
            rule.via_drill,
            rule.diff_gap,
            rule.rf.impedance.ohms,
            rule.rf.impedance.diff_ohms,
            rule.rf.impedance.layer,
            rule.rf.impedance.ground_gap_mm,
            if (rule.rf.impedance.width_derived) "true" else "false",
        });
    }
    try writer.writeByte(']');
    try pcb_rules_json.writeNetClasses(writer, evidence.design.placement);
    try writer.writeByte('}');
}

/// Write SHA-256 checksum lines for every prior release-archive entry.
pub fn writeChecksums(writer: *std.Io.Writer, entries: []const zipfile.Entry) std.Io.Writer.Error!void {
    for (entries) |entry| {
        var digest: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(entry.data, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        try writer.print("{s}  {s}\n", .{ &hex, entry.name });
    }
}

/// Filename-safe manufacturing revision label.
pub fn safeRevision(allocator: std.mem.Allocator, revision: []const u8) std.mem.Allocator.Error![]const u8 {
    if (revision.len == 0) return allocator.dupe(u8, "unversioned");
    const result = try allocator.alloc(u8, revision.len);
    for (revision, result) |source, *dest| dest.* = if (std.ascii.isAlphanumeric(source) or source == '-' or source == '_') source else '_';
    return result;
}

// spec: fabrication-release - relative project roots resolve to the canonical absolute path identity recorded by the exact read trace
test "release input paths canonicalize a relative project root" {
    const allocator = std.testing.allocator;
    const resolved = (try inputPaths(allocator, ".", "demo")) orelse return error.TestUnexpectedResult;
    defer resolved.deinit(allocator);
    try std.testing.expect(std.fs.path.isAbsolute(resolved.source));
    try std.testing.expect(std.fs.path.isAbsolute(resolved.layout));
    try std.testing.expect(std.fs.path.isAbsolute(resolved.bom));
    const root = try infra_fs.canonicalPathAlloc(allocator, ".");
    defer allocator.free(root);
    try std.testing.expect(std.mem.startsWith(u8, resolved.source, root));
}

// spec: fab_readiness - release confirmation tokens bind report findings, CAM identity, source and evaluated BOM
test "release lock changes when an evaluated BOM value changes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "src", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/demo.sexp", .data = "(design \"demo\")\n" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    try runTestGit(std.testing.allocator, root, &.{ "git", "init", "-q" });
    try runTestGit(std.testing.allocator, root, &.{ "git", "add", "src/demo.sexp" });
    try runTestGit(std.testing.allocator, root, &.{ "git", "-c", "user.name=Release Test", "-c", "user.email=release@test.invalid", "commit", "-q", "-m", "fixture" });
    const instances_a = [_]@import("flat_netlist.zig").FlatInstance{.{ .ref_des = "R1", .component = "res-0402", .value = "1k", .footprint = "r0402", .properties = &.{}, .uuid = "u" }};
    const instances_b = [_]@import("flat_netlist.zig").FlatInstance{.{ .ref_des = "R1", .component = "res-0402", .value = "2k", .footprint = "r0402", .properties = &.{}, .uuid = "u" }};
    const report = fab_readiness.Report{ .errors = &.{}, .warnings = &.{}, .stats = .{} };
    const mark = fab_identity.Mark{ .short_hex = @splat('a'), .digest_hex = @splat('b'), .text = null };
    const a = try makeLock(std.testing.allocator, root, "demo", .{
        .report = report,
        .design = .{ .placement = testPlacement(&instances_a), .revision = .{ .id = "A", .present = true }, .stackup = .{} },
        .mark = mark,
        .drc = .{ .raw = &.{}, .effective = &.{}, .complete = true },
    });
    defer std.testing.allocator.free(a.project_commit);
    const b = try makeLock(std.testing.allocator, root, "demo", .{
        .report = report,
        .design = .{ .placement = testPlacement(&instances_b), .revision = .{ .id = "A", .present = true }, .stackup = .{} },
        .mark = mark,
        .drc = .{ .raw = &.{}, .effective = &.{}, .complete = true },
    });
    defer std.testing.allocator.free(b.project_commit);
    try std.testing.expect(!std.mem.eql(u8, &a.token, &b.token));
}

// spec: fabrication-release - release tokens bind finding counts, report statistics, and complete DRC bridge evidence
test "release token binds finding counts stats and DRC bridge evidence" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "src", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/demo.sexp", .data = "(design \"demo\")\n" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    try runTestGit(allocator, root, &.{ "git", "init", "-q" });
    try runTestGit(allocator, root, &.{ "git", "add", "src/demo.sexp" });
    try runTestGit(allocator, root, &.{ "git", "-c", "user.name=Release Test", "-c", "user.email=release@test.invalid", "commit", "-q", "-m", "fixture" });
    const mark = fab_identity.Mark{ .short_hex = @splat('a'), .digest_hex = @splat('b'), .text = null };
    const placement = testPlacement(&.{});
    const finding_one = [_]fab_readiness.Item{.{ .id = "drc", .message = "same summary", .count = 1 }};
    const finding_two = [_]fab_readiness.Item{.{ .id = "drc", .message = "same summary", .count = 2 }};
    const base_violation = drc.Violation{ .x = 1, .y = 2, .gap = 0, .clearance = 0.1, .kind = .net_open };
    const bridge_violation = drc.Violation{ .x = 1, .y = 2, .gap = 0, .clearance = 0.1, .kind = .net_open, .who = .{ .bridge = .{ 1, 2, 3, 4 } } };
    const base_evidence = Evidence{
        .report = .{ .errors = &finding_one, .warnings = &.{}, .stats = .{ .parts = 1 } },
        .design = .{
            .placement = placement,
            .revision = .{ .id = "A", .present = true },
            .stackup = .{},
        },
        .mark = mark,
        .drc = .{ .raw = &.{base_violation}, .effective = &.{base_violation}, .complete = true },
    };
    const base = try makeLock(allocator, root, "demo", base_evidence);
    defer allocator.free(base.project_commit);
    var changed_count = base_evidence;
    changed_count.report.errors = &finding_two;
    const count_lock = try makeLock(allocator, root, "demo", changed_count);
    defer allocator.free(count_lock.project_commit);
    var changed_stats = base_evidence;
    changed_stats.report.stats.parts = 2;
    const stats_lock = try makeLock(allocator, root, "demo", changed_stats);
    defer allocator.free(stats_lock.project_commit);
    var changed_bridge = base_evidence;
    changed_bridge.drc.raw = &.{bridge_violation};
    changed_bridge.drc.effective = &.{bridge_violation};
    const bridge_lock = try makeLock(allocator, root, "demo", changed_bridge);
    defer allocator.free(bridge_lock.project_commit);

    try std.testing.expect(!std.mem.eql(u8, &base.token, &count_lock.token));
    try std.testing.expect(!std.mem.eql(u8, &base.token, &stats_lock.token));
    try std.testing.expect(!std.mem.eql(u8, &base.token, &bridge_lock.token));
    var report: std.Io.Writer.Allocating = .init(allocator);
    defer report.deinit();
    try writeMachineReport(&report.writer, changed_bridge, bridge_lock, true);
    try std.testing.expect(std.mem.indexOf(u8, report.written(), "\"count\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, report.written(), "\"bridge\":[1,2,3,4]") != null);
}

fn runTestGit(allocator: std.mem.Allocator, root: []const u8, argv_tail: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, argv_tail);
    if (argv.items.len > 1) try argv.insert(allocator, 1, "-C");
    if (argv.items.len > 2) try argv.insert(allocator, 2, root);
    const result = try subprocess.runCaptured(allocator, argv.items, 64 * 1024, 5000);
    defer result.deinit(allocator);
    try std.testing.expectEqual(subprocess.Outcome.ok, result.outcome);
    try std.testing.expectEqual(@as(?u8, 0), result.exit_code);
}

fn testPlacement(instances: []const @import("flat_netlist.zig").FlatInstance) optimizer.Placement {
    return .{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = instances,
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 0,
        .maxy = 0,
        .generated = false,
    };
}
