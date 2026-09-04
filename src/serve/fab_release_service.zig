//! Reusable, request-independent fabrication release service.
//!
//! The legacy board endpoint and the system review exporter both need the same
//! revision lock, strict gate and package composer. This module exposes that
//! pipeline without making an HTTP request to netlisp itself. A system release
//! can therefore nest ordinary board-house ZIPs while retaining the same fab
//! identity and TOCTOU checks as the single-board flow.

const std = @import("std");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const env = @import("../eval/env.zig");
const export_fab = @import("../export_fab.zig");
const export_gerber = @import("../export_gerber.zig");
const fab_gate = @import("../fab_gate.zig");
const fab_package = @import("../fab_package.zig");
const fab_release = @import("../fab_release.zig");
const infra_fs = @import("../infra/fs.zig");
const zipfile = @import("../zipfile.zig");
const modules = @import("modules.zig");
const pcb = @import("pcb_layout_page.zig");
const standalone_assembly = @import("standalone_assembly.zig");

/// Saved-layout, assembly variant and waiver choices for one board release.
pub const Options = struct {
    layout: ?[]const u8 = null,
    dnp: export_fab.DnpMode = .drop,
    /// Final release only. Readiness always reports whether this is needed.
    accept_waivers: bool = false,
};

/// Auditable outcome of readiness or final composition for one board.
pub const Result = struct {
    identity: struct {
        name: []const u8,
        part_number: []const u8,
        revision: []const u8,
        layout: []const u8,
    },
    lock: struct {
        project_commit: []const u8,
        release_token: [64]u8,
        fab_id: [8]u8,
        project_status: fab_release.ProjectStatus,
    },
    readiness: struct {
        needs_waiver: bool,
        blocked: bool,
        json: []const u8,
    },
    /// Content digests from the ordinary board-release lock. Unlike the Git
    /// commit and release token, these remain stable when the system manifest
    /// is attested in a later commit, so they can participate in that
    /// self-hosted manifest's source-hash attestation without a hash cycle.
    digests: struct {
        reviewed: [64]u8,
        consumed: [64]u8,
        source: [64]u8,
        layout: [64]u8,
        bom_evidence: [64]u8,
        dependency: [64]u8,
        bom: [64]u8,
        centroid: [64]u8,
        rules: [64]u8,
    },
    /// Null for readiness. Present only after an authorized, revalidated
    /// release compose.
    zip: ?[]const u8 = null,
};

pub const ReleaseError = error{
    BoardNotFound,
    LayoutNotFound,
    NoSavedLayout,
    PlacementFailed,
    ReleaseBlocked,
    WaiverRequired,
    InputsChanged,
    BoardReleaseTooLarge,
} || std.mem.Allocator.Error || std.Io.Writer.Error || fab_package.ComposeError || pcb.HandlerError;

const Mode = enum { readiness, release };

/// All evaluated state an embedding UI needs to render the ordinary offline
/// assembly member. Grouping it keeps the callback small and leaves this
/// release service independent of HTTP and the root server module.
pub const AssemblyInput = struct {
    name: []const u8,
    block: *const env.DesignBlock,
    view: pcb.FabView,
    identity: standalone_assembly.ReleaseIdentity,
};

/// Host-provided renderer for the unchanged board-release Assembly.html.
pub const AssemblyRenderer = struct {
    context: *anyopaque,
    render: *const fn (*anyopaque, AssemblyInput) pcb.HandlerError![]const u8,
};

const RunInput = struct {
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    options: Options,
    mode: Mode,
    renderer: ?AssemblyRenderer = null,
    max_zip_bytes: ?usize = null,
};

/// Compute complete release evidence without producing CAM bytes.
pub fn readiness(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    options: Options,
) ReleaseError!Result {
    return run(.{ .allocator = allocator, .project_dir = project_dir, .name = name, .options = options, .mode = .readiness });
}

/// Compose one upload-ready board release ZIP after the caller has approved the
/// enclosing system lock. The same evidence is recomputed and rechecked after
/// composition; no bytes are returned if anything moved.
pub fn release(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    options: Options,
    renderer: AssemblyRenderer,
) ReleaseError!Result {
    return run(.{
        .allocator = allocator,
        .project_dir = project_dir,
        .name = name,
        .options = options,
        .mode = .release,
        .renderer = renderer,
    });
}

/// Compose one board release while refusing its exact ZIP32 size before the
/// archive writer allocates more than `max_zip_bytes`. System packages use
/// this for each nested upload-ready board archive.
pub fn releaseBounded(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    options: Options,
    renderer: AssemblyRenderer,
    max_zip_bytes: usize,
) ReleaseError!Result {
    if (max_zip_bytes == 0) return error.BoardReleaseTooLarge;
    return run(.{
        .allocator = allocator,
        .project_dir = project_dir,
        .name = name,
        .options = options,
        .mode = .release,
        .renderer = renderer,
        .max_zip_bytes = max_zip_bytes,
    });
}

fn run(input: RunInput) ReleaseError!Result {
    const allocator = input.allocator;
    const project_dir = input.project_dir;
    const name = input.name;
    const options = input.options;
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
        return error.BoardNotFound;
    const gate_evaluator = if (module_result) |resolved| resolved.eval else &evaluator;
    const bom_evidence_complete = try fab_gate.prepareBomEvidence(allocator, project_dir, name, block);
    const view = pcb.fabViewForResolved(allocator, project_dir, name, options.layout, block) catch |err| return switch (err) {
        error.BlockNotFound => error.BoardNotFound,
        error.UnknownLayout => error.LayoutNotFound,
        error.NoSavedLayout => error.NoSavedLayout,
        error.PlacementFailed => error.PlacementFailed,
    };
    const copper = export_gerber.Copper{
        .tracks = view.routed.tracks,
        .arcs = view.routed.arcs,
        .rf_paths = view.routed.rf_port_outcomes,
        .vias = view.routed.vias,
        .zones = view.zones,
        .silk_keepouts = view.silk_keepouts,
    };
    var gate = try fab_gate.check(allocator, .{
        .project_dir = project_dir,
        .name = name,
        .evaluator = gate_evaluator,
        .block = block,
        .physical = .{
            .placement = view.placement,
            .routed = view.routed,
            .zones = view.zones,
            .texts = view.texts,
            .copper = copper,
        },
        .release = .{
            .from_saved = view.selection.from_saved,
            .layout_evidence_complete = view.selection.evidence_complete,
            .bom_evidence_complete = bom_evidence_complete,
            .keep_dnp = options.dnp == .keep,
            .board = view.authored.board,
        },
    });
    read_trace.end();
    const consumed_sha256 = read_trace.digest();
    const traced = try fab_release.tracedInputs(allocator, &read_trace, project_dir, name);
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
            .keep_dnp = options.dnp == .keep,
            .block = gate.evaluation.block,
            .layout_name = view.selection.name,
            .dependencies = gate.evaluation.dependencies,
        },
        .mark = mark,
        .drc = .{
            .raw = gate.drc.raw,
            .effective = gate.drc.effective,
            .complete = gate.drc.complete,
            .internal_complete = gate.internal_complete,
            .policy = gate.policy,
        },
        .inputs = .{
            .evaluation_sha256 = gate.evaluation.sha256,
            .reviewed_sha256 = gate.evaluation.reviewed_inputs_sha256,
            .consumed_sha256 = consumed_sha256,
            .source_sha256 = traced.source,
            .layout_sha256 = traced.layout,
            .bom_sha256 = traced.bom,
        },
    };
    var lock = try fab_release.makeLock(allocator, project_dir, name, evidence);
    fab_release.bindBaseline(&lock, project_before, layout_before, bom_before);
    fab_release.bindTracedInputs(&lock, traced, read_trace.verify());

    const blocked = !gate.drc.complete or !gate.internal_complete or
        gate.evaluation.block == null or fab_release.projectStatusBlocksRelease(lock.project_status);
    const needs_waiver = gate.report.errors.len > 0 or gate.report.warnings.len > 0 or
        gate.drc.raw.len > gate.drc.effective.len or fab_release.projectStatusNeedsWaiver(lock.project_status);
    var readiness_out: std.Io.Writer.Allocating = .init(allocator);
    try fab_release.writeReadinessJson(allocator, &readiness_out.writer, evidence, lock);

    var result = Result{
        .identity = .{
            .name = try allocator.dupe(u8, name),
            .part_number = try allocator.dupe(u8, mark.part_number),
            .revision = try allocator.dupe(u8, view.authored.revision.id),
            .layout = try allocator.dupe(u8, view.selection.name),
        },
        .lock = .{
            .project_commit = try allocator.dupe(u8, project_before.commit),
            .release_token = lock.token,
            .fab_id = mark.short_hex,
            .project_status = lock.project_status,
        },
        .readiness = .{
            .needs_waiver = needs_waiver,
            .blocked = blocked,
            .json = readiness_out.written(),
        },
        .digests = .{
            .reviewed = evidence.inputs.reviewed_sha256,
            .consumed = lock.inputs.consumed_sha256,
            .source = lock.inputs.source_sha256,
            .layout = lock.inputs.layout_sha256,
            .bom_evidence = lock.inputs.bom_evidence_sha256,
            .dependency = lock.inputs.dependency_sha256,
            .bom = lock.outputs.bom_sha256,
            .centroid = lock.outputs.centroid_sha256,
            .rules = lock.outputs.rules_sha256,
        },
    };
    if (input.mode == .readiness) return result;
    if (blocked) return error.ReleaseBlocked;
    if (needs_waiver and !options.accept_waivers) return error.WaiverRequired;

    const renderer = input.renderer orelse return error.ReleaseBlocked;
    var displayed_id = mark.short_hex;
    _ = std.ascii.upperString(&displayed_id, &mark.short_hex);
    // The legacy page renderer must not smuggle a second filesystem snapshot
    // into Assembly.html. Re-open the same trace and require it to observe only
    // the already-bound paths at the same bytes.
    read_trace.begin();
    const assembly_html = renderer.render(renderer.context, .{
        .name = name,
        .block = block,
        .view = view,
        .identity = .{
            .part_number = mark.part_number,
            .revision = view.authored.revision.id,
            .fab_id = &displayed_id,
            .release_token = &lock.token,
        },
    }) catch |err| {
        read_trace.end();
        return err;
    };
    read_trace.end();
    // Assembly rendering may legitimately discover release-only inputs that
    // the electrical/CAM gate does not consume (for example rework guides or
    // locally present datasheets). Keep those reads in the same cumulative
    // trace and verify their exact bytes; a larger read set is not itself a
    // design change. `ReadTrace` still fails closed if any earlier path is
    // reread with different bytes, and the final lock verifies the expanded
    // set again after package composition.
    if (!read_trace.verify()) return error.InputsChanged;
    const package = try fab_package.compose(allocator, name, .{
        .placement = view.placement,
        .routed = view.routed,
        .texts = view.texts,
        .copper = copper,
        .frame = export_fab.frameFor(view.placement),
    }, .{
        .mark = mark,
        .evidence = evidence,
        .lock = lock,
        .needs_waiver = needs_waiver,
        .dnp = options.dnp,
        .assembly_html = assembly_html,
    });
    const zip_bytes = try writePackageZip(allocator, package.entries.items, input.max_zip_bytes);

    // The final lock rereads Git, ignored layout/BOM sidecars, and every traced
    // dependency after CAM and the offline assembly document were rendered.
    var final_lock = try fab_release.makeLock(allocator, project_dir, name, evidence);
    fab_release.bindBaseline(&final_lock, project_before, layout_before, bom_before);
    fab_release.bindTracedInputs(&final_lock, traced, read_trace.verify());
    if (fab_release.projectStatusBlocksRelease(final_lock.project_status) or !std.mem.eql(u8, &lock.token, &final_lock.token))
        return error.InputsChanged;
    result.zip = zip_bytes;
    return result;
}

fn writePackageZip(
    allocator: std.mem.Allocator,
    entries: []const zipfile.Entry,
    max_zip_bytes: ?usize,
) ReleaseError![]const u8 {
    const encoded_size = zipfile.encodedSize(entries) catch return error.WriteFailed;
    const output_len = std.math.cast(usize, encoded_size) orelse return error.WriteFailed;
    if (max_zip_bytes) |limit| if (output_len > limit) return error.BoardReleaseTooLarge;
    const output = try allocator.alloc(u8, output_len);
    errdefer allocator.free(output);
    var writer: std.Io.Writer = .fixed(output);
    try zipfile.write(&writer, entries);
    if (writer.buffered().len != output_len) return error.WriteFailed;
    return output;
}

// spec: fabrication-release - a stable release renderer may extend the exact read trace with assembly-only inputs, while any changed byte still blocks packaging
test "release renderer may extend a stable input trace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "gate.sexp", .data = "gate" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "assembly.md", .data = "assembly" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    const gate_path = try std.fs.path.join(allocator, &.{ root, "gate.sexp" });
    const assembly_path = try std.fs.path.join(allocator, &.{ root, "assembly.md" });

    var trace = infra_fs.ReadTrace.init(allocator);
    defer trace.deinit();
    trace.begin();
    _ = try infra_fs.cwd().readFileAlloc(allocator, gate_path, 32);
    trace.end();
    const gate_digest = trace.digest();

    trace.begin();
    _ = try infra_fs.cwd().readFileAlloc(allocator, assembly_path, 32);
    trace.end();
    const expanded_digest = trace.digest();
    try std.testing.expect(!std.mem.eql(u8, &gate_digest, &expanded_digest));
    try std.testing.expect(trace.verify());

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "assembly.md", .data = "changed" });
    try std.testing.expect(!trace.verify());
}

// spec: system-review - a board release reports CAM blocking and waiver conditions independently
test "release result keeps blocking and waiver states distinct" {
    const clean = Result{
        .identity = .{ .name = "board", .part_number = "PN", .revision = "A", .layout = "release" },
        .lock = .{ .project_commit = "abc", .release_token = @splat('0'), .fab_id = "12345678".*, .project_status = .clean },
        .readiness = .{ .needs_waiver = true, .blocked = false, .json = "{}" },
        .digests = .{
            .reviewed = @splat('0'),
            .consumed = @splat('0'),
            .source = @splat('1'),
            .layout = @splat('2'),
            .bom_evidence = @splat('3'),
            .dependency = @splat('4'),
            .bom = @splat('5'),
            .centroid = @splat('6'),
            .rules = @splat('7'),
        },
    };
    try std.testing.expect(clean.readiness.needs_waiver);
    try std.testing.expect(!clean.readiness.blocked);
    try std.testing.expect(clean.zip == null);
}

test "bounded board ZIP rejects its exact size before allocating output" {
    const entries = [_]zipfile.Entry{
        .{ .name = "board.gbr", .data = "G04\nM02*\n" },
        .{ .name = "board.drl", .data = "M48\nM30\n" },
    };
    const exact_size = std.math.cast(usize, try zipfile.encodedSize(&entries)).?;
    try std.testing.expectError(
        error.BoardReleaseTooLarge,
        writePackageZip(std.testing.allocator, &entries, exact_size - 1),
    );
    const archive = try writePackageZip(std.testing.allocator, &entries, exact_size);
    defer std.testing.allocator.free(archive);
    try std.testing.expectEqual(exact_size, archive.len);
}
