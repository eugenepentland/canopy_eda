//! System review readiness, content attestation, and deterministic archives.
//!
//! A draft is deliberately read-only and never contains CAM. A final release
//! requires a current authenticated content attestation, a completed checklist,
//! exact board identities/layouts, complete connector observations, clean board
//! release gates, an explicit system token, and explicit waiver acceptance when
//! either board reports one. Upload-ready board ZIPs are then composed by the
//! ordinary fabrication service and nested without modification.

const std = @import("std");
const board_review = @import("board_review_snapshot.zig");
const build_id = @import("build_id.zig");
const export_fab = @import("export_fab.zig");
const export_gerber = @import("export_gerber.zig");
const fab_release = @import("fab_release.zig");
const infra_fs = @import("infra/fs.zig");
const json_writer = @import("json_writer.zig");
const review = @import("review.zig");
const system_review = @import("system_review.zig");
const review_assets = @import("system_review_assets.zig");
const review_md = @import("system_review_md.zig");
const review_pdf = @import("system_review_pdf.zig");
const zipfile = @import("zipfile.zig");
const fab_service = @import("serve/fab_release_service.zig");
const fab_filename = @import("serve/fab_filename.zig");

const max_document_bytes: usize = 4 * 1024 * 1024;
const max_document_total_bytes: usize = 32 * 1024 * 1024;
const max_rendered_document_bytes: usize = 2 * 1024 * 1024;
const max_combined_markdown_bytes: usize = 64 * 1024 * 1024;
const max_system_pdf_bytes: usize = 64 * 1024 * 1024;
const max_nested_board_release_bytes: usize = 64 * 1024 * 1024;
const max_analysis_evidence_bytes: usize = 256 * 1024 * 1024;
const max_archive_entries: usize = 4096;
const max_archive_payload_bytes: usize = 512 * 1024 * 1024;
const max_analysis_inputs: usize = 4096;
const max_layout_identity_bytes: usize = 512;
const Sha256 = std.crypto.hash.sha2.Sha256;

const PreflightMode = enum { draft, release };

/// Complete system gate rendered for CLI, HTTP, and package consumers.
pub const Readiness = struct {
    json: []const u8,
    release_token: [64]u8,
    content_lock: [64]u8,
    blocked: bool,
    needs_waiver: bool,
    attested: bool,
};

/// One complete outer archive and its attachment-safe filename.
pub const PackageResult = struct {
    zip: []const u8,
    filename: []const u8,
    readiness: Readiness,
};

/// Serialized top-level attestation carrying the newly authenticated lock.
pub const AttestationResult = struct {
    attestation_json: []const u8,
    readiness: Readiness,
};

/// Explicit authorization supplied only after a readiness response is read.
pub const ReleaseOptions = struct {
    confirm: []const u8,
    accept_waivers: bool = false,
    actor: []const u8,
    role: []const u8,
    attested_at: []const u8,
};

const DocumentEvidence = struct {
    spec: system_review.DocumentSpec,
    source: []const u8,
    inspected: system_review.DocumentContent,
};

const BoardEvidence = struct {
    member: system_review.BoardMember,
    snapshot: board_review.Snapshot,
    fab: fab_service.Result,
    identity_ok: bool,
};

const GateState = struct {
    identity_ok: bool = true,
    interface_ok: bool = true,
    board_review_ok: bool = true,
    fab_ok: bool = true,
    checklists_ok: bool = true,
    attested: bool = false,
};

const Analysis = struct {
    parsed: system_review.ParsedSystemSpec,
    manifest_source: []const u8,
    documents: []const DocumentEvidence,
    assets: []const review_assets.Asset,
    boards: []const BoardEvidence,
    inputs: []const system_review.InputAttestation,
    document_attestations: []const system_review.DocumentAttestation,
    generated_at: []const u8,
    content_lock: [64]u8,
    release_token: [64]u8,
    needs_waiver: bool,
    state: GateState,
    interface_diagnostic: system_review.Diagnostic,

    fn blocked(self: Analysis) bool {
        const state = self.state;
        return !state.identity_ok or !state.interface_ok or
            !state.board_review_ok or !state.fab_ok or
            !state.checklists_ok or !state.attested;
    }
};

const ReleaseBundle = struct {
    boards: []const fab_service.Result,
    actor: []const u8,
    role: []const u8,
    at: []const u8,
    waivers_accepted: bool,
};

const BoardReleasePlan = struct {
    name: []const u8,
    layout: []const u8,
    dnp: system_review.DnpPolicy,
    release_token: [64]u8,
};

const ReadinessError = @typeInfo(@typeInfo(@TypeOf(readinessImpl)).@"fn".return_type.?).error_union.error_set;

/// Compute the same gate and confirmation token used by final export.
pub fn readiness(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
) ReadinessError!Readiness {
    return readinessImpl(allocator, project_dir, name);
}

fn readinessImpl(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
) !Readiness {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    var analysis = try analyze(scratch.allocator(), allocator, project_dir, name, .release);
    defer analysis.parsed.deinit();
    return copyReadiness(allocator, analysis, try renderReadiness(scratch.allocator(), analysis));
}

const DraftError = @typeInfo(@typeInfo(@TypeOf(draftImpl)).@"fn".return_type.?).error_union.error_set;

/// Build a reviewable, watermarked archive with no fabrication/CAM payloads.
pub fn draft(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
) DraftError!PackageResult {
    return draftImpl(allocator, project_dir, name);
}

fn draftImpl(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
) !PackageResult {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    var analysis = try analyze(scratch.allocator(), allocator, project_dir, name, .draft);
    defer analysis.parsed.deinit();
    const ready_json = try renderReadiness(scratch.allocator(), analysis);
    const built = try composeArchive(scratch.allocator(), allocator, analysis, null);
    errdefer allocator.free(built.zip);
    errdefer allocator.free(built.filename);
    return .{
        .zip = built.zip,
        .filename = built.filename,
        .readiness = try copyReadiness(allocator, analysis, ready_json),
    };
}

const AttestError = @typeInfo(@typeInfo(@TypeOf(attestImpl)).@"fn".return_type.?).error_union.error_set;

/// Compute and serialize a current attestation. Persistence remains at the
/// authenticated VFS/HTTP boundary so this function stays filesystem read-only.
pub fn attest(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    expected_content_lock: []const u8,
    actor: []const u8,
    attested_at: []const u8,
) AttestError!AttestationResult {
    return attestImpl(allocator, project_dir, name, expected_content_lock, actor, attested_at);
}

fn attestImpl(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    expected_content_lock: []const u8,
    actor: []const u8,
    attested_at: []const u8,
) !AttestationResult {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    var analysis = try analyze(scratch.allocator(), allocator, project_dir, name, .release);
    defer analysis.parsed.deinit();
    if (!std.mem.eql(u8, expected_content_lock, &analysis.content_lock))
        return error.ConfirmationRequired;
    if (!analysis.state.checklists_ok) return error.ChecklistIncomplete;

    var attestation = try system_review.makeAttestation(
        scratch.allocator(),
        analysis.parsed.value,
        analysis.inputs,
        analysis.document_attestations,
    );
    attestation.attested_by = actor;
    attestation.attested_at = attested_at;
    var diagnostic: system_review.Diagnostic = .{};
    try system_review.validateReleaseAttestation(
        scratch.allocator(),
        analysis.parsed.value,
        attestation,
        &diagnostic,
    );
    var updated = analysis.parsed.value;
    updated.attestation = attestation;
    var complete_manifest: std.Io.Writer.Allocating = .init(scratch.allocator());
    try system_review.writeSystemSpecJson(scratch.allocator(), &complete_manifest.writer, updated);
    if (complete_manifest.written().len > system_review.max_manifest_bytes)
        return error.ManifestTooLarge;
    var encoded_attestation: std.Io.Writer.Allocating = .init(scratch.allocator());
    try system_review.writeAttestationJson(scratch.allocator(), &encoded_attestation.writer, attestation);

    analysis.state.attested = true;
    const ready_json = try renderReadiness(scratch.allocator(), analysis);
    return .{
        .attestation_json = try allocator.dupe(u8, encoded_attestation.written()),
        .readiness = try copyReadiness(allocator, analysis, ready_json),
    };
}

const ReleaseError = @typeInfo(@typeInfo(@TypeOf(releaseImpl)).@"fn".return_type.?).error_union.error_set;

/// Revalidate, compose both ordinary board releases, revalidate again, and
/// nest those byte-identical board-house archives into one system ZIP.
pub fn release(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    options: ReleaseOptions,
    renderer: fab_service.AssemblyRenderer,
) ReleaseError!PackageResult {
    return releaseImpl(allocator, project_dir, name, options, renderer);
}

fn releaseImpl(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    options: ReleaseOptions,
    renderer: fab_service.AssemblyRenderer,
) !PackageResult {
    if (!validApprovalText(options.actor) or !validApprovalText(options.role)) return error.WriterRequired;
    if (!isUtcSecondTimestamp(options.attested_at)) return error.InvalidApprovalTimestamp;

    var release_state = std.heap.ArenaAllocator.init(allocator);
    defer release_state.deinit();
    const release_allocator = release_state.allocator();
    var plans: std.ArrayList(BoardReleasePlan) = .empty;
    var expected_release_token: [64]u8 = undefined;
    {
        var before_arena = std.heap.ArenaAllocator.init(allocator);
        defer before_arena.deinit();
        var before = try analyze(before_arena.allocator(), allocator, project_dir, name, .release);
        defer before.parsed.deinit();
        if (before.blocked()) return error.SystemReleaseBlocked;
        if (!std.mem.eql(u8, options.confirm, &before.release_token)) return error.ConfirmationRequired;
        if (before.needs_waiver and !options.accept_waivers) return error.WaiverRequired;
        expected_release_token = before.release_token;
        for (before.boards) |board| try plans.append(release_allocator, .{
            .name = try release_allocator.dupe(u8, board.member.name),
            .layout = try release_allocator.dupe(u8, board.member.layout),
            .dnp = board.member.dnp,
            .release_token = board.fab.lock.release_token,
        });
    }

    var released: std.ArrayList(fab_service.Result) = .empty;
    var released_zip_bytes: usize = 0;
    for (plans.items) |plan| {
        const retained_result = blk: {
            var board_arena = std.heap.ArenaAllocator.init(allocator);
            defer board_arena.deinit();
            const result = try fab_service.releaseBounded(
                board_arena.allocator(),
                project_dir,
                plan.name,
                .{
                    .layout = requestedLayout(plan.layout),
                    .dnp = dnpMode(plan.dnp),
                    .accept_waivers = options.accept_waivers,
                },
                renderer,
                max_nested_board_release_bytes,
            );
            if (!std.mem.eql(u8, &result.lock.release_token, &plan.release_token))
                return error.InputsChanged;
            const board_zip = result.zip orelse return error.MissingBoardRelease;
            if (board_zip.len > max_nested_board_release_bytes) return error.BoardReleaseTooLarge;
            try addBoundedBytes(&released_zip_bytes, board_zip.len, max_archive_payload_bytes);
            break :blk try copyFabResult(release_allocator, result);
        };
        try released.append(release_allocator, retained_result);
    }

    var after_arena = std.heap.ArenaAllocator.init(allocator);
    defer after_arena.deinit();
    var after = try analyze(after_arena.allocator(), allocator, project_dir, name, .release);
    defer after.parsed.deinit();
    if (after.blocked() or !std.mem.eql(u8, &expected_release_token, &after.release_token))
        return error.InputsChanged;
    if (after.needs_waiver and !options.accept_waivers) return error.WaiverRequired;
    const bundle = ReleaseBundle{
        .boards = released.items,
        .actor = options.actor,
        .role = options.role,
        .at = options.attested_at,
        .waivers_accepted = options.accept_waivers,
    };
    var compose_arena = std.heap.ArenaAllocator.init(allocator);
    defer compose_arena.deinit();
    const ready_json = try renderReadiness(compose_arena.allocator(), after);
    const built = try composeArchive(compose_arena.allocator(), allocator, after, bundle);
    errdefer allocator.free(built.zip);
    errdefer allocator.free(built.filename);
    return .{
        .zip = built.zip,
        .filename = built.filename,
        .readiness = try copyReadiness(allocator, after, ready_json),
    };
}

fn copyReadiness(
    allocator: std.mem.Allocator,
    analysis: Analysis,
    json: []const u8,
) !Readiness {
    return .{
        .json = try allocator.dupe(u8, json),
        .release_token = analysis.release_token,
        .content_lock = analysis.content_lock,
        .blocked = analysis.blocked(),
        .needs_waiver = analysis.needs_waiver,
        .attested = analysis.state.attested,
    };
}

fn copyFabResult(
    allocator: std.mem.Allocator,
    source: fab_service.Result,
) !fab_service.Result {
    const identity_name = try allocator.dupe(u8, source.identity.name);
    errdefer allocator.free(identity_name);
    const part_number = try allocator.dupe(u8, source.identity.part_number);
    errdefer allocator.free(part_number);
    const revision = try allocator.dupe(u8, source.identity.revision);
    errdefer allocator.free(revision);
    const layout = try allocator.dupe(u8, source.identity.layout);
    errdefer allocator.free(layout);
    const project_commit = try allocator.dupe(u8, source.lock.project_commit);
    errdefer allocator.free(project_commit);
    const readiness_json = try allocator.dupe(u8, source.readiness.json);
    errdefer allocator.free(readiness_json);
    const archive = if (source.zip) |zip| try allocator.dupe(u8, zip) else null;
    errdefer if (archive) |zip| allocator.free(zip);
    return .{
        .identity = .{
            .name = identity_name,
            .part_number = part_number,
            .revision = revision,
            .layout = layout,
        },
        .lock = .{
            .project_commit = project_commit,
            .release_token = source.lock.release_token,
            .fab_id = source.lock.fab_id,
            .project_status = source.lock.project_status,
        },
        .readiness = .{
            .needs_waiver = source.readiness.needs_waiver,
            .blocked = source.readiness.blocked,
            .json = readiness_json,
        },
        .digests = source.digests,
        .zip = archive,
    };
}

fn analyze(
    allocator: std.mem.Allocator,
    transient_allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    preflight_mode: PreflightMode,
) !Analysis {
    if (!simpleName(name)) return error.InvalidSystemName;
    const manifest_rel = try std.fmt.allocPrint(allocator, "src/systems/{s}/system.json", .{name});
    const manifest_source = try review_assets.readContainedFile(
        allocator,
        project_dir,
        manifest_rel,
        system_review.max_manifest_bytes,
    );
    var parsed = try parseManifestForRefresh(allocator, manifest_source);
    errdefer parsed.deinit();
    if (!std.mem.eql(u8, name, parsed.value.name)) return error.SystemNameMismatch;

    var documents: std.ArrayList(DocumentEvidence) = .empty;
    var document_attestations: std.ArrayList(system_review.DocumentAttestation) = .empty;
    var diagnostic: system_review.Diagnostic = .{};
    var checklists_ok = true;
    var document_bytes: usize = 0;
    const workspace_prefix = try std.fmt.allocPrint(allocator, "src/systems/{s}/", .{parsed.value.name});
    for (parsed.value.documents) |document| {
        if (document.status != .active) continue;
        const source = (try readActiveDocument(allocator, project_dir, document)) orelse continue;
        if (source.len > max_document_total_bytes - document_bytes) return error.DocumentsTooLarge;
        document_bytes += source.len;
        const inspected = try system_review.inspectDocumentContent(document, source, &diagnostic);
        const workspace_owned = std.mem.startsWith(u8, document.path, workspace_prefix);
        const validation = if (workspace_owned)
            validateAuthoredMarkdown(allocator, source)
        else
            validateRawMarkdown(source);
        validation catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.InvalidDocument,
        };
        try documents.append(allocator, .{ .spec = document, .source = source, .inspected = inspected });
        try document_attestations.append(
            allocator,
            try system_review.attestDocument(allocator, document, source, &diagnostic),
        );
        if (requiredChecklistBlocks(document, inspected))
            checklists_ok = false;
    }

    var boards: std.ArrayList(BoardEvidence) = .empty;
    var inputs: std.ArrayList(system_review.InputAttestation) = .empty;
    var seen_inputs: std.StringHashMapUnmanaged(usize) = .empty;
    const assets = try review_assets.enumerate(allocator, project_dir, name);
    try appendAssetInputs(allocator, &inputs, &seen_inputs, assets);
    var identity_ok = true;
    var board_review_ok = true;
    var fab_ok = true;
    var needs_waiver = false;
    var generated_at: []const u8 = "";
    var analysis_evidence_bytes: usize = 0;
    for (parsed.value.boards) |member| {
        const connectors = try connectorsForBoard(allocator, parsed.value, member.name);
        var fab_before_arena = std.heap.ArenaAllocator.init(transient_allocator);
        defer fab_before_arena.deinit();
        const fab_before = try fab_service.readiness(fab_before_arena.allocator(), project_dir, member.name, .{
            .layout = requestedLayout(member.layout),
            .dnp = dnpMode(member.dnp),
        });
        try addFabEvidenceBytes(&analysis_evidence_bytes, fab_before);
        const snapshot = try board_review.build(allocator, project_dir, member.name, .{
            .layout = requestedLayout(member.layout),
            .connectors = connectors,
        });
        const fab = try fab_service.readiness(allocator, project_dir, member.name, .{
            .layout = requestedLayout(member.layout),
            .dnp = dnpMode(member.dnp),
        });
        if (!sameFabSnapshot(fab_before, fab)) return error.InputsChanged;
        if (!sameReviewFabInputs(snapshot, fab)) return error.InputsChanged;
        if (!board_review.verifySnapshot(allocator, project_dir, snapshot)) return error.InputsChanged;
        if (!validLayoutIdentity(snapshot.identity.layout) or !validLayoutIdentity(fab.identity.layout))
            return error.InvalidLayoutIdentity;
        try addBoardEvidenceBytes(&analysis_evidence_bytes, snapshot, fab);
        const exact_identity = boardSourceMatches(member.source, snapshot.identity.source) and
            std.mem.eql(u8, snapshot.identity.part_number, member.part_number) and
            std.mem.eql(u8, snapshot.identity.revision, member.revision) and
            selectedLayoutMatches(member.layout, snapshot.identity.layout) and
            std.mem.eql(u8, fab.identity.part_number, member.part_number) and
            std.mem.eql(u8, fab.identity.revision, member.revision) and
            selectedLayoutMatches(member.layout, fab.identity.layout) and
            std.mem.eql(u8, snapshot.identity.layout, fab.identity.layout);
        identity_ok = identity_ok and exact_identity;
        board_review_ok = board_review_ok and snapshot.review.status != .fail and snapshot.review.open_notes == 0;
        fab_ok = fab_ok and !fab.readiness.blocked;
        needs_waiver = needs_waiver or fab.readiness.needs_waiver or snapshot.review.status == .warn;
        if (generated_at.len == 0) generated_at = snapshot.identity.generated_at;
        try boards.append(allocator, .{
            .member = member,
            .snapshot = snapshot,
            .fab = fab,
            .identity_ok = exact_identity,
        });
        for (snapshot.physical.sources) |source|
            try appendInput(allocator, &inputs, &seen_inputs, source.name, source.data);
        if (snapshot.review.notes_source) |source|
            try appendInput(allocator, &inputs, &seen_inputs, source.name, source.data);
        const review_digest_path = try std.fmt.allocPrint(allocator, "review-inputs/{s}/consumed.sha256", .{member.role});
        try appendDigest(allocator, &inputs, &seen_inputs, review_digest_path, &snapshot.physical.consumed_sha256);
        try appendBoardDigests(allocator, &inputs, &seen_inputs, member.role, fab);
    }

    var interface_diagnostic: system_review.Diagnostic = .{};
    const observations = try interfaceObservations(allocator, parsed.value, boards.items);
    const interface_ok = blk: {
        system_review.validateInterfaceCompleteness(parsed.value, observations, &interface_diagnostic) catch break :blk false;
        break :blk true;
    };
    const content_lock = try system_review.systemLockDigest(
        allocator,
        parsed.value,
        inputs.items,
        document_attestations.items,
    );
    const stored_attested = currentStoredAttestation(
        allocator,
        parsed.value,
        content_lock,
        &diagnostic,
    );
    const release_token = releaseToken(content_lock, boards.items);
    const result = Analysis{
        .parsed = parsed,
        .manifest_source = manifest_source,
        .documents = documents.items,
        .assets = assets,
        .boards = boards.items,
        .inputs = inputs.items,
        .document_attestations = document_attestations.items,
        .generated_at = generated_at,
        .content_lock = content_lock,
        .release_token = release_token,
        .needs_waiver = needs_waiver,
        .state = .{
            .identity_ok = identity_ok,
            .interface_ok = interface_ok,
            .board_review_ok = board_review_ok,
            .fab_ok = fab_ok,
            .checklists_ok = checklists_ok,
            .attested = stored_attested,
        },
        .interface_diagnostic = interface_diagnostic,
    };
    // Preflight the exact safe Markdown composition used by draft/final export
    // before readiness or attestation can call these inputs current.
    const preflight_markdown = try renderSystemMarkdown(allocator, result, true);
    const archive_names = try preflightArchiveNames(allocator, result, preflight_mode);
    try preflightArchivePayload(allocator, result, archive_names, preflight_markdown.len);
    return result;
}

fn addBoardEvidenceBytes(
    total: *usize,
    snapshot: board_review.Snapshot,
    fab: fab_service.Result,
) !void {
    try addBoundedBytes(total, @sizeOf(board_review.Snapshot), max_analysis_evidence_bytes);
    try addBoundedBytes(total, snapshot.physical.consumed_trace.retainedBytes(), max_analysis_evidence_bytes);
    const slices = [_][]const u8{
        snapshot.identity.name,
        snapshot.identity.source,
        snapshot.identity.title,
        snapshot.identity.part_number,
        snapshot.identity.revision,
        snapshot.identity.layout,
        snapshot.identity.generated_at,
        snapshot.review.notes_path,
        snapshot.review.markdown,
        snapshot.review.pdf,
        snapshot.review.json,
        snapshot.review.bom_csv,
        snapshot.physical.pcb_png,
    };
    for (slices) |bytes| try addBoundedBytes(total, bytes.len, max_analysis_evidence_bytes);
    if (snapshot.review.notes_source) |notes| {
        try addBoundedBytes(total, @sizeOf(zipfile.Entry), max_analysis_evidence_bytes);
        try addBoundedBytes(total, notes.name.len, max_analysis_evidence_bytes);
        try addBoundedBytes(total, notes.data.len, max_analysis_evidence_bytes);
    }
    const source_storage = std.math.mul(
        usize,
        snapshot.physical.sources.len,
        @sizeOf(zipfile.Entry),
    ) catch return error.ArchiveTooLarge;
    try addBoundedBytes(total, source_storage, max_analysis_evidence_bytes);
    for (snapshot.physical.sources) |source| {
        try addBoundedBytes(total, source.name.len, max_analysis_evidence_bytes);
        try addBoundedBytes(total, source.data.len, max_analysis_evidence_bytes);
    }
    const connection_storage = std.math.mul(
        usize,
        snapshot.physical.connections.len,
        @sizeOf(board_review.Connection),
    ) catch return error.ArchiveTooLarge;
    try addBoundedBytes(total, connection_storage, max_analysis_evidence_bytes);
    for (snapshot.physical.connections) |connection| {
        try addBoundedBytes(total, connection.connector.len, max_analysis_evidence_bytes);
        try addBoundedBytes(total, connection.pin.len, max_analysis_evidence_bytes);
        try addBoundedBytes(total, connection.net.len, max_analysis_evidence_bytes);
    }
    try addFabEvidenceBytes(total, fab);
}

fn addFabEvidenceBytes(total: *usize, fab: fab_service.Result) !void {
    try addBoundedBytes(total, @sizeOf(fab_service.Result), max_analysis_evidence_bytes);
    const slices = [_][]const u8{
        fab.identity.name,
        fab.identity.part_number,
        fab.identity.revision,
        fab.identity.layout,
        fab.lock.project_commit,
        fab.readiness.json,
    };
    for (slices) |bytes| try addBoundedBytes(total, bytes.len, max_analysis_evidence_bytes);
    if (fab.zip) |board_zip| try addBoundedBytes(total, board_zip.len, max_analysis_evidence_bytes);
}

fn addBoundedBytes(total: *usize, amount: usize, limit: usize) !void {
    if (total.* > limit or amount > limit - total.*) return error.ArchiveTooLarge;
    total.* += amount;
}

fn readActiveDocument(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    document: system_review.DocumentSpec,
) !?[]const u8 {
    return review_assets.readContainedFile(
        allocator,
        project_dir,
        document.path,
        max_document_bytes,
    ) catch |err| switch (err) {
        error.FileNotFound => if (document.required) return error.RequiredDocumentMissing else null,
        else => return err,
    };
}

fn validateAuthoredMarkdown(allocator: std.mem.Allocator, source: []const u8) !void {
    const without_markers = try stripGeneratedMarkerLines(allocator, source);
    defer allocator.free(without_markers);
    var parsed = try review_md.parse(allocator, without_markers, .{});
    defer parsed.deinit();
}

fn validateRawMarkdown(source: []const u8) !void {
    if (source.len > max_document_bytes) return error.DocumentTooLarge;
    if (!std.unicode.utf8ValidateSlice(source)) return error.InvalidUtf8;
    var lines: usize = 0;
    var line_bytes: usize = 0;
    for (source) |byte| {
        const low_control = byte < 0x20;
        const accepted_spacing = byte == '\n' or byte == '\r' or byte == '\t';
        if (byte == 0 or (low_control and !accepted_spacing)) return error.InvalidControlCharacter;
        if (byte == '\n') {
            lines += 1;
            line_bytes = 0;
            if (lines > 64 * 1024) return error.LimitExceeded;
        } else {
            line_bytes += 1;
            if (line_bytes > 32 * 1024) return error.LineTooLong;
        }
    }
}

fn requiredChecklistBlocks(
    document: system_review.DocumentSpec,
    inspected: system_review.DocumentContent,
) bool {
    return document.required and document.classification == .checklist and
        !inspected.checklist.allComplete();
}

fn parseManifestForRefresh(
    allocator: std.mem.Allocator,
    source: []const u8,
) !system_review.ParsedSystemSpec {
    if (source.len > system_review.max_manifest_bytes) return error.ManifestTooLarge;
    var parsed = std.json.parseFromSlice(system_review.SystemSpec, allocator, source, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
    }) catch |first_error| blk: {
        const without_attestation = manifestWithoutAttestation(allocator, source) catch return first_error;
        defer allocator.free(without_attestation);
        break :blk std.json.parseFromSlice(system_review.SystemSpec, allocator, without_attestation, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = false,
        }) catch return first_error;
    };
    errdefer parsed.deinit();
    var authored = parsed.value;
    authored.attestation = null;
    var diagnostic: system_review.Diagnostic = .{};
    try system_review.validateSystemSpec(allocator, authored, &diagnostic);
    return parsed;
}

fn manifestWithoutAttestation(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var syntax = try std.json.parseFromSlice(std.json.Value, allocator, source, .{});
    defer syntax.deinit();
    const object = switch (syntax.value) {
        .object => |*value| value,
        else => return error.InvalidManifest,
    };
    const attestation = object.getPtr("attestation") orelse return error.InvalidManifest;
    if (attestation.* == .null) return error.InvalidManifest;
    attestation.* = .null;

    var encoded: std.Io.Writer.Allocating = .init(allocator);
    errdefer encoded.deinit();
    try std.json.Stringify.value(syntax.value, .{}, &encoded.writer);
    return encoded.toOwnedSlice();
}

fn simpleName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128) return false;
    if (!std.ascii.isAlphanumeric(name[0])) return false;
    for (name[1..]) |c| if (!simpleNameByte(c)) return false;
    return true;
}

fn simpleNameByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.';
}

fn validApprovalText(value: []const u8) bool {
    if (value.len == 0 or value.len > 512 or !std.unicode.utf8ValidateSlice(value)) return false;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}

fn isUtcSecondTimestamp(value: []const u8) bool {
    if (value.len != 20) return false;
    if (value[4] != '-' or value[7] != '-') return false;
    if (value[10] != 'T' or value[13] != ':') return false;
    if (value[16] != ':' or value[19] != 'Z') return false;
    for (value, 0..) |byte, index| {
        switch (index) {
            4, 7, 10, 13, 16, 19 => continue,
            else => {},
        }
        if (!std.ascii.isDigit(byte)) return false;
    }
    return true;
}

fn dnpMode(policy: system_review.DnpPolicy) export_fab.DnpMode {
    return if (policy == .keep) .keep else .drop;
}

fn requestedLayout(layout: []const u8) ?[]const u8 {
    return if (std.mem.eql(u8, layout, "blessed")) null else layout;
}

fn selectedLayoutMatches(requested: []const u8, selected: []const u8) bool {
    return requestedLayout(requested) == null or std.mem.eql(u8, requested, selected);
}

fn validLayoutIdentity(layout: []const u8) bool {
    if (layout.len == 0 or layout.len > max_layout_identity_bytes) return false;
    for (layout) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return std.unicode.utf8ValidateSlice(layout);
}

fn sameFabSnapshot(before: fab_service.Result, after: fab_service.Result) bool {
    if (!std.mem.eql(u8, before.identity.name, after.identity.name)) return false;
    if (!std.mem.eql(u8, before.identity.part_number, after.identity.part_number)) return false;
    if (!std.mem.eql(u8, before.identity.revision, after.identity.revision)) return false;
    if (!std.mem.eql(u8, before.identity.layout, after.identity.layout)) return false;
    if (!std.mem.eql(u8, before.lock.project_commit, after.lock.project_commit)) return false;
    if (!std.mem.eql(u8, &before.lock.release_token, &after.lock.release_token)) return false;
    if (before.lock.project_status != after.lock.project_status) return false;
    if (before.readiness.blocked != after.readiness.blocked) return false;
    if (before.readiness.needs_waiver != after.readiness.needs_waiver) return false;
    return std.meta.eql(before.digests, after.digests);
}

fn sameReviewFabInputs(snapshot: board_review.Snapshot, fab: fab_service.Result) bool {
    const traced = snapshot.physical.fab_inputs;
    if (!traced.complete or traced.ambiguous) return false;
    if (!std.mem.eql(u8, &traced.source, &fab.digests.source)) return false;
    if (!std.mem.eql(u8, &traced.layout, &fab.digests.layout)) return false;
    return std.mem.eql(u8, &traced.bom, &fab.digests.bom_evidence);
}

fn boardSourceMatches(manifest_source: []const u8, resolved_source: []const u8) bool {
    return std.mem.eql(u8, manifest_source, resolved_source);
}

fn connectorsForBoard(
    allocator: std.mem.Allocator,
    spec: system_review.SystemSpec,
    board: []const u8,
) ![]const []const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    for (spec.interfaces) |interface| {
        const candidates = [_]system_review.InterfaceEndpoint{ interface.left, interface.right };
        for (candidates) |endpoint| {
            if (!std.mem.eql(u8, endpoint.board, board)) continue;
            var seen = false;
            for (result.items) |existing| if (std.mem.eql(u8, existing, endpoint.connector)) {
                seen = true;
                break;
            };
            if (!seen) try result.append(allocator, endpoint.connector);
        }
    }
    return result.items;
}

fn appendInput(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(system_review.InputAttestation),
    seen: *std.StringHashMapUnmanaged(usize),
    path: []const u8,
    content: []const u8,
) !void {
    const digest = system_review.sha256Hex(content);
    try appendInputDigest(allocator, out, seen, path, &digest);
}

fn appendAssetInputs(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(system_review.InputAttestation),
    seen: *std.StringHashMapUnmanaged(usize),
    assets: []const review_assets.Asset,
) !void {
    for (assets) |asset|
        try appendInput(allocator, out, seen, asset.relative_path, asset.data);
}

fn appendDigest(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(system_review.InputAttestation),
    seen: *std.StringHashMapUnmanaged(usize),
    path: []const u8,
    digest: *const [64]u8,
) !void {
    try appendInputDigest(allocator, out, seen, path, digest);
}

fn appendInputDigest(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(system_review.InputAttestation),
    seen: *std.StringHashMapUnmanaged(usize),
    path: []const u8,
    digest: *const [64]u8,
) !void {
    if (!system_review.isSafeRelativePath(path)) return error.UnsafeInputPath;
    if (seen.get(path)) |index| {
        if (!std.mem.eql(u8, out.items[index].sha256, digest)) return error.ConflictingInput;
        return;
    }
    if (out.items.len >= max_analysis_inputs) return error.TooManyInputs;
    const owned_path = try allocator.dupe(u8, path);
    const owned_digest = try allocator.dupe(u8, digest);
    const index = out.items.len;
    try out.append(allocator, .{
        .path = owned_path,
        .sha256 = owned_digest,
    });
    try seen.put(allocator, owned_path, index);
}

fn appendBoardDigests(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(system_review.InputAttestation),
    seen: *std.StringHashMapUnmanaged(usize),
    role: []const u8,
    fab: fab_service.Result,
) !void {
    const names = [_][]const u8{
        "reviewed", "consumed", "source", "layout", "bom-evidence", "dependency", "bom", "centroid", "rules",
    };
    const values = [_]*const [64]u8{
        &fab.digests.reviewed,
        &fab.digests.consumed,
        &fab.digests.source,
        &fab.digests.layout,
        &fab.digests.bom_evidence,
        &fab.digests.dependency,
        &fab.digests.bom,
        &fab.digests.centroid,
        &fab.digests.rules,
    };
    for (names, values) |label, digest| {
        const path = try std.fmt.allocPrint(allocator, "release-inputs/{s}/{s}.sha256", .{ role, label });
        try appendDigest(allocator, out, seen, path, digest);
    }
}

fn interfaceObservations(
    allocator: std.mem.Allocator,
    spec: system_review.SystemSpec,
    boards: []const BoardEvidence,
) ![]const system_review.InterfaceObservation {
    var result: std.ArrayList(system_review.InterfaceObservation) = .empty;
    for (spec.interfaces) |interface| {
        const endpoints = [_]system_review.InterfaceEndpoint{ interface.left, interface.right };
        for (endpoints) |endpoint| {
            const board = findBoard(boards, endpoint.board) orelse continue;
            var contacts: std.ArrayList(system_review.ContactObservation) = .empty;
            for (board.snapshot.physical.connections) |connection| {
                if (!std.mem.eql(u8, connection.connector, endpoint.connector)) continue;
                try contacts.append(allocator, .{ .pin = connection.pin, .net = connection.net });
            }
            try result.append(allocator, .{
                .board = endpoint.board,
                .connector = endpoint.connector,
                .contacts = contacts.items,
            });
        }
    }
    return result.items;
}

fn findBoard(boards: []const BoardEvidence, name: []const u8) ?BoardEvidence {
    for (boards) |board| if (std.mem.eql(u8, board.member.name, name)) return board;
    return null;
}

fn currentStoredAttestation(
    allocator: std.mem.Allocator,
    spec: system_review.SystemSpec,
    content_lock: [64]u8,
    diagnostic: *system_review.Diagnostic,
) bool {
    const attestation = spec.attestation orelse return false;
    system_review.validateReleaseAttestation(allocator, spec, attestation, diagnostic) catch return false;
    return std.mem.eql(u8, attestation.system_lock_sha256, &content_lock);
}

fn hashField(hash: *Sha256, value: []const u8) void {
    var len: [8]u8 = undefined;
    std.mem.writeInt(u64, &len, value.len, .little);
    hash.update(&len);
    hash.update(value);
}

const ReleaseBinding = struct { role: []const u8, token: [64]u8 };

fn releaseToken(content_lock: [64]u8, boards: []const BoardEvidence) [64]u8 {
    var bindings: [64]ReleaseBinding = undefined;
    for (boards, 0..) |board, index| bindings[index] = .{
        .role = board.member.role,
        .token = board.fab.lock.release_token,
    };
    return releaseTokenBindings(content_lock, bindings[0..boards.len]);
}

fn releaseTokenBindings(content_lock: [64]u8, bindings: []const ReleaseBinding) [64]u8 {
    var hash = Sha256.init(.{});
    hashField(&hash, "netlisp-system-review-release-v1");
    hashField(&hash, &content_lock);
    for (bindings) |binding| {
        hashField(&hash, binding.role);
        hashField(&hash, &binding.token);
    }
    var digest: [Sha256.digest_length]u8 = undefined;
    hash.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn renderReadiness(allocator: std.mem.Allocator, analysis: Analysis) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    const w = &out.writer;
    const spec = analysis.parsed.value;
    try w.writeAll("{\"schema\":\"netlisp-system-readiness-v1\",\"system\":");
    try json_writer.writeString(w, spec.name);
    try w.writeAll(",\"part_number\":");
    try json_writer.writeString(w, spec.part_number);
    try w.writeAll(",\"revision\":");
    try json_writer.writeString(w, spec.revision);
    try w.writeAll(",\"ok\":");
    try w.writeAll(if (analysis.blocked()) "false" else "true");
    try w.writeAll(",\"blocked\":");
    try w.writeAll(if (analysis.blocked()) "true" else "false");
    try w.writeAll(",\"needs_waiver\":");
    try w.writeAll(if (analysis.needs_waiver) "true" else "false");
    try w.writeAll(",\"release_token\":");
    try json_writer.writeString(w, &analysis.release_token);
    try w.writeAll(",\"content_lock\":");
    try json_writer.writeString(w, &analysis.content_lock);
    try w.writeAll(",\"attested\":");
    try w.writeAll(if (analysis.state.attested) "true" else "false");
    try w.writeAll(",\"checks\":{");
    try writeBoolField(w, "identity", analysis.state.identity_ok, false);
    try writeBoolField(w, "interfaces", analysis.state.interface_ok, true);
    try writeBoolField(w, "board_review", analysis.state.board_review_ok, true);
    try writeBoolField(w, "fabrication", analysis.state.fab_ok, true);
    try writeBoolField(w, "checklists", analysis.state.checklists_ok, true);
    try w.writeAll("},\"boards\":[");
    for (analysis.boards, 0..) |board, index| {
        if (index > 0) try w.writeByte(',');
        try w.writeAll("{\"role\":");
        try json_writer.writeString(w, board.member.role);
        try w.writeAll(",\"name\":");
        try json_writer.writeString(w, board.member.name);
        try w.writeAll(",\"layout\":");
        try json_writer.writeString(w, board.snapshot.identity.layout);
        try w.writeAll(",\"identity_ok\":");
        try w.writeAll(if (board.identity_ok) "true" else "false");
        try w.writeAll(",\"review_status\":");
        try json_writer.writeString(w, @tagName(board.snapshot.review.status));
        try w.print(",\"open_notes\":{d},\"fab_blocked\":{s},\"needs_waiver\":{s},\"release_token\":", .{
            board.snapshot.review.open_notes,
            if (board.fab.readiness.blocked) "true" else "false",
            if (board.fab.readiness.needs_waiver) "true" else "false",
        });
        try json_writer.writeString(w, &board.fab.lock.release_token);
        try w.writeByte('}');
    }
    try w.writeAll("],\"documents\":[");
    for (analysis.documents, 0..) |document, index| {
        if (index > 0) try w.writeByte(',');
        try w.writeAll("{\"id\":");
        try json_writer.writeString(w, document.spec.id);
        try w.writeAll(",\"sha256\":");
        try json_writer.writeString(w, &document.inspected.sha256);
        try w.print(",\"checklist\":{{\"total\":{d},\"complete\":{d},\"open\":{d}}}", .{
            document.inspected.checklist.total,
            document.inspected.checklist.complete,
            document.inspected.checklist.open,
        });
        try w.writeByte('}');
    }
    try w.writeAll("]");
    if (!analysis.state.interface_ok) {
        try w.writeAll(",\"interface_diagnostic\":{");
        try json_writer.writeField(w, "code", @tagName(analysis.interface_diagnostic.code));
        try w.writeAll(",");
        try json_writer.writeField(w, "message", analysis.interface_diagnostic.message);
        try w.writeAll(",");
        try json_writer.writeField(w, "value", analysis.interface_diagnostic.value);
        try w.writeByte('}');
    }
    try w.writeByte('}');
    return out.written();
}

fn writeBoolField(w: *std.Io.Writer, name: []const u8, value: bool, comma: bool) !void {
    if (comma) try w.writeByte(',');
    try json_writer.writeString(w, name);
    try w.writeByte(':');
    try w.writeAll(if (value) "true" else "false");
}

const BuiltArchive = struct { zip: []const u8, filename: []const u8 };

fn preflightArchiveNames(
    allocator: std.mem.Allocator,
    analysis: Analysis,
    mode: PreflightMode,
) ![]const zipfile.Entry {
    var entries: std.ArrayList(zipfile.Entry) = .empty;
    const spec = analysis.parsed.value;
    const safe_part = try fab_release.safeRevision(allocator, spec.part_number);
    const safe_revision = try fab_release.safeRevision(allocator, spec.revision);
    const base = try std.fmt.allocPrint(allocator, "{s}-rev-{s}-system-review", .{ safe_part, safe_revision });
    try appendEmptyEntry(allocator, &entries, "README.md");
    try appendEmptyEntry(allocator, &entries, "readiness.json");
    try appendEmptyEntry(allocator, &entries, try std.fmt.allocPrint(allocator, "review/{s}.md", .{base}));
    try appendEmptyEntry(allocator, &entries, try std.fmt.allocPrint(allocator, "review/{s}.pdf", .{base}));
    try appendEmptyEntry(allocator, &entries, "review/source/system.json");
    for (analysis.documents) |document| if (document.spec.include_in_fab)
        try appendEmptyEntry(
            allocator,
            &entries,
            try archivedDocumentName(allocator, spec.name, document.spec.path),
        );
    for (analysis.assets) |asset|
        try appendEmptyEntry(allocator, &entries, try std.fmt.allocPrint(allocator, "review/assets/{s}", .{asset.name}));
    const board_suffixes = [_][]const u8{
        "review.md", "review.pdf", "review.json", "bom.csv", "pcb.png", "fab-readiness.json",
    };
    for (analysis.boards) |board| {
        for (board_suffixes) |suffix|
            try appendEmptyEntry(allocator, &entries, try std.fmt.allocPrint(allocator, "boards/{s}/{s}", .{ board.member.role, suffix }));
        if (board.snapshot.review.notes_source != null)
            try appendEmptyEntry(allocator, &entries, try std.fmt.allocPrint(allocator, "boards/{s}/design-notes.md", .{board.member.role}));
        if (mode == .release) {
            const fab_name = try boardReleaseFilename(allocator, board.member, board.fab);
            try appendEmptyEntry(allocator, &entries, try std.fmt.allocPrint(allocator, "fab/{s}", .{fab_name}));
        }
    }
    var seen_sources: std.StringHashMapUnmanaged(void) = .empty;
    defer seen_sources.deinit(allocator);
    for (analysis.boards) |board| for (board.snapshot.physical.sources) |source| {
        if (seen_sources.contains(source.name)) continue;
        try seen_sources.put(allocator, source.name, {});
        try appendEmptyEntry(allocator, &entries, try std.fmt.allocPrint(allocator, "source/design/{s}", .{source.name}));
    };
    if (mode == .release) try appendEmptyEntry(allocator, &entries, "approval.json");
    try appendEmptyEntry(allocator, &entries, "release-manifest.json");
    try appendEmptyEntry(allocator, &entries, "checksums.sha256");
    try validateArchiveEntries(allocator, entries.items, mode == .release);
    return entries.items;
}

fn preflightArchivePayload(
    allocator: std.mem.Allocator,
    analysis: Analysis,
    archive_names: []const zipfile.Entry,
    markdown_bytes: usize,
) !void {
    var payload: usize = 0;
    try addBoundedBytes(&payload, analysis.manifest_source.len, max_archive_payload_bytes);
    try addBoundedBytes(&payload, markdown_bytes, max_archive_payload_bytes);
    try addBoundedBytes(&payload, max_system_pdf_bytes, max_archive_payload_bytes);
    try addArchiveMetadataReserve(&payload, archive_names);
    for (analysis.documents) |document| if (document.spec.include_in_fab)
        try addBoundedBytes(&payload, document.source.len, max_archive_payload_bytes);
    for (analysis.assets) |asset|
        try addBoundedBytes(&payload, asset.data.len, max_archive_payload_bytes);
    for (analysis.boards) |board| {
        const board_slices = [_][]const u8{
            board.snapshot.review.markdown,
            board.snapshot.review.pdf,
            board.snapshot.review.json,
            board.snapshot.review.bom_csv,
            board.snapshot.physical.pcb_png,
            board.fab.readiness.json,
        };
        for (board_slices) |bytes| try addBoundedBytes(&payload, bytes.len, max_archive_payload_bytes);
        if (board.snapshot.review.notes_source) |notes|
            try addBoundedBytes(&payload, notes.data.len, max_archive_payload_bytes);
        // Nested fabrication ZIPs do not exist during readiness analysis.
        // Their exact sizes are bounded per board and in aggregate during the
        // release loop, then checked again with the complete outer payload.
    }
    var seen_sources: std.StringHashMapUnmanaged(void) = .empty;
    defer seen_sources.deinit(allocator);
    for (analysis.boards) |board| for (board.snapshot.physical.sources) |source| {
        if (seen_sources.contains(source.name)) continue;
        try seen_sources.put(allocator, source.name, {});
        try addBoundedBytes(&payload, source.data.len, max_archive_payload_bytes);
    };
}

fn addArchiveMetadataReserve(total: *usize, archive_names: []const zipfile.Entry) !void {
    // One manifest-sized fixed reserve covers identity/board/readiness JSON.
    // Each path then appears in both release-manifest.json and checksums, with
    // fixed digest/length syntax. Portable archive names need no JSON escaping.
    try addBoundedBytes(total, system_review.max_manifest_bytes, max_archive_payload_bytes);
    for (archive_names) |entry| {
        const doubled_name = std.math.mul(usize, entry.name.len, 2) catch return error.ArchiveTooLarge;
        const per_entry = std.math.add(usize, doubled_name, 256) catch return error.ArchiveTooLarge;
        try addBoundedBytes(total, per_entry, max_archive_payload_bytes);
    }
}

fn appendEmptyEntry(
    allocator: std.mem.Allocator,
    entries: *std.ArrayList(zipfile.Entry),
    name: []const u8,
) !void {
    try entries.append(allocator, .{ .name = try allocator.dupe(u8, name), .data = "" });
}

fn composeArchive(
    scratch_allocator: std.mem.Allocator,
    output_allocator: std.mem.Allocator,
    analysis: Analysis,
    release_bundle: ?ReleaseBundle,
) !BuiltArchive {
    const allocator = scratch_allocator;
    const is_release = release_bundle != null;
    const spec = analysis.parsed.value;
    const safe_part = try fab_release.safeRevision(allocator, spec.part_number);
    const safe_revision = try fab_release.safeRevision(allocator, spec.revision);
    const markdown = try renderSystemMarkdown(allocator, analysis, !is_release);
    const identity = try std.fmt.allocPrint(allocator, "{s} / Rev {s}", .{ spec.part_number, spec.revision });
    const pdf = try review_pdf.compose(allocator, markdown, .{
        .title = spec.title,
        .identity = identity,
        .generated_at = analysis.generated_at,
        .build_id = build_id.current(),
        .draft = !is_release,
    });
    if (pdf.len > max_system_pdf_bytes) return error.ArchiveTooLarge;

    var entries: std.ArrayList(zipfile.Entry) = .empty;
    const readme = try renderReadme(allocator, analysis, is_release);
    try entries.append(allocator, .{ .name = "README.md", .data = readme });
    const readiness_json = try renderReadiness(allocator, analysis);
    try entries.append(allocator, .{ .name = "readiness.json", .data = readiness_json });
    const base = try std.fmt.allocPrint(allocator, "{s}-rev-{s}-system-review", .{ safe_part, safe_revision });
    try entries.append(allocator, .{ .name = try std.fmt.allocPrint(allocator, "review/{s}.md", .{base}), .data = markdown });
    try entries.append(allocator, .{ .name = try std.fmt.allocPrint(allocator, "review/{s}.pdf", .{base}), .data = pdf });
    try entries.append(allocator, .{ .name = "review/source/system.json", .data = analysis.manifest_source });
    for (analysis.documents) |document| if (document.spec.include_in_fab) {
        try entries.append(allocator, .{
            .name = try archivedDocumentName(allocator, spec.name, document.spec.path),
            .data = document.source,
        });
    };
    try appendAssetEntries(allocator, &entries, analysis.assets);
    for (analysis.boards) |board| try appendBoardEntries(allocator, &entries, board);
    try appendSourceEntries(allocator, &entries, analysis.boards);
    if (release_bundle) |bundle| {
        try entries.append(allocator, .{ .name = "approval.json", .data = try renderApproval(allocator, analysis, bundle) });
        for (bundle.boards, 0..) |board_release, index| {
            const member = analysis.boards[index].member;
            const filename = try boardReleaseFilename(allocator, member, board_release);
            const board_zip = board_release.zip orelse return error.MissingBoardRelease;
            if (board_zip.len > max_nested_board_release_bytes) return error.BoardReleaseTooLarge;
            try entries.append(allocator, .{
                .name = try std.fmt.allocPrint(allocator, "fab/{s}", .{filename}),
                .data = board_zip,
            });
        }
    }
    const release_manifest = try renderReleaseManifest(allocator, analysis, entries.items, release_bundle);
    try entries.append(allocator, .{ .name = "release-manifest.json", .data = release_manifest });
    var checksums: std.Io.Writer.Allocating = .init(allocator);
    try fab_release.writeChecksums(&checksums.writer, entries.items);
    try entries.append(allocator, .{ .name = "checksums.sha256", .data = checksums.written() });
    try validateArchiveEntries(allocator, entries.items, is_release);
    const encoded_size = zipfile.encodedSize(entries.items) catch return error.ArchiveTooLarge;
    const archive_len = std.math.cast(usize, encoded_size) orelse return error.ArchiveTooLarge;
    if (archive_len > max_archive_payload_bytes) return error.ArchiveTooLarge;
    const archive_bytes = try output_allocator.alloc(u8, archive_len);
    errdefer output_allocator.free(archive_bytes);
    var archive_writer: std.Io.Writer = .fixed(archive_bytes);
    try zipfile.write(&archive_writer, entries.items);
    if (archive_writer.buffered().len != archive_len) return error.ArchiveTooLarge;
    const mode = if (is_release) "release" else "draft";
    return .{
        .zip = archive_bytes,
        .filename = try std.fmt.allocPrint(output_allocator, "{s}-rev-{s}-system-review-{s}.zip", .{ safe_part, safe_revision, mode }),
    };
}

fn validateArchiveEntries(
    allocator: std.mem.Allocator,
    entries: []const zipfile.Entry,
    is_release: bool,
) !void {
    if (entries.len > max_archive_entries or entries.len > std.math.maxInt(u16))
        return error.TooManyArchiveEntries;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);
    var folded_seen: std.StringHashMapUnmanaged(void) = .empty;
    defer folded_seen.deinit(allocator);
    var folded_names: std.ArrayList([]const u8) = .empty;
    defer {
        for (folded_names.items) |name| allocator.free(name);
        folded_names.deinit(allocator);
    }
    var payload_bytes: usize = 0;
    for (entries) |entry| {
        if (!portableArchivePath(entry.name) or entry.name.len > std.math.maxInt(u16))
            return error.UnsafeArchivePath;
        if (entry.data.len > std.math.maxInt(u32) or
            entry.data.len > max_archive_payload_bytes - payload_bytes)
            return error.ArchiveTooLarge;
        payload_bytes += entry.data.len;
        if (seen.contains(entry.name)) return error.DuplicateArchiveEntry;
        try seen.put(allocator, entry.name, {});
        const folded = try asciiFoldAlloc(allocator, entry.name);
        if (folded_seen.contains(folded)) {
            allocator.free(folded);
            return error.DuplicateArchiveEntry;
        }
        folded_seen.put(allocator, folded, {}) catch |err| {
            allocator.free(folded);
            return err;
        };
        folded_names.append(allocator, folded) catch |err| {
            _ = folded_seen.remove(folded);
            allocator.free(folded);
            return err;
        };
        if (!is_release and draftForbiddenMember(entry.name)) return error.DraftContainsCam;
    }
}

fn asciiFoldAlloc(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    const folded = try allocator.dupe(u8, value);
    for (folded) |*byte| byte.* = std.ascii.toLower(byte.*);
    return folded;
}

fn portableArchivePath(path: []const u8) bool {
    if (!system_review.isSafeRelativePath(path)) return false;
    if (!std.unicode.utf8ValidateSlice(path)) return false;
    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |segment| {
        if (!portableArchiveSegment(segment)) return false;
    }
    return true;
}

fn portableArchiveSegment(segment: []const u8) bool {
    if (segment.len > 255) return false;
    if (segment[segment.len - 1] == '.' or segment[segment.len - 1] == ' ') return false;
    for (segment) |byte| switch (byte) {
        0x80...0xff => return false,
        '<', '>', ':', '"', '|', '?', '*' => return false,
        else => {},
    };
    return !windowsReservedSegment(segment);
}

fn windowsReservedSegment(segment: []const u8) bool {
    for ([_][]const u8{ "con", "prn", "aux", "nul" }) |reserved| {
        if (reservedStem(segment, reserved)) return true;
    }
    for ([_][]const u8{ "com", "lpt" }) |prefix| {
        if (segment.len < 4) continue;
        if (!std.ascii.eqlIgnoreCase(segment[0..3], prefix)) continue;
        if (segment[3] < '1' or segment[3] > '9') continue;
        if (segment.len == 4 or segment[4] == '.') return true;
    }
    return false;
}

fn reservedStem(segment: []const u8, reserved: []const u8) bool {
    if (segment.len < reserved.len) return false;
    if (!std.ascii.eqlIgnoreCase(segment[0..reserved.len], reserved)) return false;
    return segment.len == reserved.len or segment[reserved.len] == '.';
}

fn draftForbiddenMember(name: []const u8) bool {
    if (std.mem.startsWith(u8, name, "fab/")) return true;
    if (export_gerber.isCamOutputFilename(name)) return true;
    const suffixes = [_][]const u8{
        ".zip", ".pos", ".pnp", ".mnt", ".xy", ".ipc", ".ipc356",
    };
    for (suffixes) |suffix| if (std.ascii.endsWithIgnoreCase(name, suffix)) return true;
    return false;
}

fn appendAssetEntries(
    allocator: std.mem.Allocator,
    entries: *std.ArrayList(zipfile.Entry),
    assets: []const review_assets.Asset,
) !void {
    for (assets) |asset| try entries.append(allocator, .{
        .name = try std.fmt.allocPrint(allocator, "review/assets/{s}", .{asset.name}),
        .data = asset.data,
    });
}

fn appendBoardEntries(
    allocator: std.mem.Allocator,
    entries: *std.ArrayList(zipfile.Entry),
    board: BoardEvidence,
) !void {
    const prefix = try std.fmt.allocPrint(allocator, "boards/{s}", .{board.member.role});
    const files = [_]struct { suffix: []const u8, data: []const u8 }{
        .{ .suffix = "review.md", .data = board.snapshot.review.markdown },
        .{ .suffix = "review.pdf", .data = board.snapshot.review.pdf },
        .{ .suffix = "review.json", .data = board.snapshot.review.json },
        .{ .suffix = "bom.csv", .data = board.snapshot.review.bom_csv },
        .{ .suffix = "pcb.png", .data = board.snapshot.physical.pcb_png },
        .{ .suffix = "fab-readiness.json", .data = board.fab.readiness.json },
    };
    for (files) |file| try entries.append(allocator, .{
        .name = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, file.suffix }),
        .data = file.data,
    });
    if (board.snapshot.review.notes_source) |notes_source| try entries.append(allocator, .{
        .name = try std.fmt.allocPrint(allocator, "{s}/design-notes.md", .{prefix}),
        .data = notes_source.data,
    });
}

fn appendSourceEntries(
    allocator: std.mem.Allocator,
    entries: *std.ArrayList(zipfile.Entry),
    boards: []const BoardEvidence,
) !void {
    var seen: std.StringHashMapUnmanaged([64]u8) = .empty;
    defer seen.deinit(allocator);
    for (boards) |board| for (board.snapshot.physical.sources) |source| {
        try appendUniqueSource(allocator, entries, &seen, source);
    };
}

fn appendUniqueSource(
    allocator: std.mem.Allocator,
    entries: *std.ArrayList(zipfile.Entry),
    seen: *std.StringHashMapUnmanaged([64]u8),
    source: zipfile.Entry,
) !void {
    const digest = system_review.sha256Hex(source.data);
    if (seen.get(source.name)) |prior| {
        if (!std.mem.eql(u8, &prior, &digest)) return error.ConflictingInput;
        return;
    }
    try seen.put(allocator, source.name, digest);
    try entries.append(allocator, .{
        .name = try std.fmt.allocPrint(allocator, "source/design/{s}", .{source.name}),
        .data = source.data,
    });
}

fn renderReadme(allocator: std.mem.Allocator, analysis: Analysis, is_release: bool) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    const spec = analysis.parsed.value;
    try out.writer.print("# {s} system review\n\n", .{spec.title});
    if (is_release)
        try out.writer.writeAll("This is an approved fabrication release. Upload-ready board packages are nested unchanged under `fab/`.\n\n")
    else
        try out.writer.writeAll("**DRAFT — NOT FOR FABRICATION.** This archive contains review evidence only; it intentionally contains no Gerber, drill, centroid, or board fabrication ZIP.\n\n");
    try out.writer.print("System identity: `{s}` revision `{s}`.\n\n", .{ spec.part_number, spec.revision });
    try out.writer.writeAll("Start with the combined Markdown or PDF under `review/`. Board evidence is under `boards/ROLE/`; authored active documents are preserved verbatim as controlled source under `review/source/`; evaluated source closure is under `source/design/`. Verify `checksums.sha256` before review or handoff.\n");
    return canonicalMarkdown(allocator, out.written(), 1024 * 1024);
}

fn renderSystemMarkdown(allocator: std.mem.Allocator, analysis: Analysis, draft_mode: bool) ![]const u8 {
    var combined: std.Io.Writer.Allocating = .init(allocator);
    const spec = analysis.parsed.value;
    try combined.writer.print("# {s} — System Review Package\n\n", .{spec.title});
    if (draft_mode) try combined.writer.writeAll("DRAFT — NOT FOR FABRICATION\n\n");
    try combined.writer.print("Part number: `{s}`  \nRevision: `{s}`  \nSystem release token: `{s}`\n\n", .{
        spec.part_number,
        spec.revision,
        &analysis.release_token,
    });
    try ensureMarkdownSize(&combined, max_combined_markdown_bytes);
    const workspace_prefix = try std.fmt.allocPrint(allocator, "src/systems/{s}/", .{spec.name});
    for (analysis.documents) |document| {
        if (!document.spec.include_in_fab or !std.mem.startsWith(u8, document.spec.path, workspace_prefix)) continue;
        const expanded = try expandGeneratedRegions(allocator, analysis, document);
        var parsed = try review_md.parse(allocator, expanded, .{});
        defer parsed.deinit();
        const canonical = try review_md.renderMarkdownAlloc(allocator, &parsed);
        try writeMarkdownBounded(&combined, "\n---\n\n", max_combined_markdown_bytes);
        try writeMarkdownBounded(&combined, canonical, max_combined_markdown_bytes);
        if (!std.mem.endsWith(u8, canonical, "\n"))
            try writeMarkdownBounded(&combined, "\n", max_combined_markdown_bytes);
    }
    try writeMarkdownBounded(&combined, "\n---\n\n## Active supporting documents\n\n", max_combined_markdown_bytes);
    for (analysis.documents) |document| {
        if (!document.spec.include_in_fab or std.mem.startsWith(u8, document.spec.path, workspace_prefix)) continue;
        const archived_path = try archivedDocumentName(allocator, spec.name, document.spec.path);
        try combined.writer.print("- {s}: `{s}`\n", .{ document.spec.title, archived_path });
        try ensureMarkdownSize(&combined, max_combined_markdown_bytes);
    }
    return canonicalMarkdown(allocator, combined.written(), max_combined_markdown_bytes);
}

fn writeMarkdownBounded(
    out: *std.Io.Writer.Allocating,
    bytes: []const u8,
    limit: usize,
) !void {
    if (out.written().len > limit or bytes.len > limit - out.written().len)
        return error.DocumentTooLarge;
    try out.writer.writeAll(bytes);
}

fn ensureMarkdownSize(out: *std.Io.Writer.Allocating, limit: usize) !void {
    if (out.written().len > limit) return error.DocumentTooLarge;
}

fn canonicalMarkdown(
    allocator: std.mem.Allocator,
    source: []const u8,
    source_limit: usize,
) ![]const u8 {
    var options: review_md.Options = .{};
    options.limits.source_bytes = source_limit;
    var parsed = try review_md.parse(allocator, source, options);
    defer parsed.deinit();
    return review_md.renderMarkdownAlloc(allocator, &parsed);
}

fn archivedDocumentName(
    allocator: std.mem.Allocator,
    system_name: []const u8,
    path: []const u8,
) ![]const u8 {
    const workspace_prefix = try std.fmt.allocPrint(allocator, "src/systems/{s}/", .{system_name});
    defer allocator.free(workspace_prefix);
    if (std.mem.startsWith(u8, path, workspace_prefix))
        return std.fmt.allocPrint(allocator, "review/source/{s}", .{path});
    // Supporting project Markdown is retained byte-for-byte but deliberately
    // receives an inert suffix because it is not rendered by the strict profile.
    return std.fmt.allocPrint(allocator, "review/source/{s}.txt", .{path});
}

fn expandGeneratedRegions(
    allocator: std.mem.Allocator,
    analysis: Analysis,
    document: DocumentEvidence,
) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    var lines = std.mem.splitScalar(u8, document.source, '\n');
    var skipping = false;
    var in_fence = false;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (skipping) {
            if (std.mem.eql(u8, line, system_review.generated_region_close)) skipping = false;
            continue;
        }
        if (in_fence) {
            try out.writer.print("{s}\n", .{raw});
            try ensureMarkdownSize(&out, max_rendered_document_bytes);
            if (std.mem.eql(u8, line, "```")) in_fence = false;
            continue;
        }
        if (std.mem.startsWith(u8, line, "```")) {
            in_fence = true;
            try out.writer.print("{s}\n", .{raw});
            try ensureMarkdownSize(&out, max_rendered_document_bytes);
            continue;
        }
        if (generatedMarkerId(line)) |id| {
            skipping = true;
            try writeGeneratedSection(&out, analysis, id, max_rendered_document_bytes);
            continue;
        }
        try out.writer.print("{s}\n", .{raw});
        try ensureMarkdownSize(&out, max_rendered_document_bytes);
    }
    return out.written();
}

fn stripGeneratedMarkerLines(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    var lines = std.mem.splitScalar(u8, source, '\n');
    var in_fence = false;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        var marker = false;
        if (in_fence) {
            if (std.mem.eql(u8, trimmed, "```")) in_fence = false;
        } else if (std.mem.startsWith(u8, trimmed, "```")) {
            in_fence = true;
        } else {
            marker = generatedMarkerId(trimmed) != null or
                std.mem.eql(u8, trimmed, system_review.generated_region_close);
        }
        if (!marker) try out.writer.print("{s}\n", .{line});
    }
    return out.toOwnedSlice();
}

fn generatedMarkerId(line: []const u8) ?[]const u8 {
    const suffix = " -->";
    if (!std.mem.startsWith(u8, line, system_review.generated_region_open) or
        !std.mem.endsWith(u8, line, suffix)) return null;
    return line[system_review.generated_region_open.len .. line.len - suffix.len];
}

fn writeGeneratedSection(
    out: *std.Io.Writer.Allocating,
    analysis: Analysis,
    id: []const u8,
    limit: usize,
) !void {
    const w = &out.writer;
    const spec = analysis.parsed.value;
    if (std.mem.eql(u8, id, "system-summary")) {
        try w.print("| Field | Value |\n| --- | --- |\n| System | {s} |\n| Part number | `{s}` |\n| Revision | `{s}` |\n| Content lock | `{s}` |\n| Release token | `{s}` |\n\n", .{
            spec.name, spec.part_number, spec.revision, &analysis.content_lock, &analysis.release_token,
        });
    } else if (std.mem.eql(u8, id, "board-summary")) {
        try w.writeAll("| Role | Design | Part number | Revision | Layout | Review | Fab gate |\n| --- | --- | --- | --- | --- | --- | --- |\n");
        for (analysis.boards) |board| {
            try w.print("| {s} | `{s}` | `{s}` | `{s}` | `{s}` | {s} | {s} |\n", .{
                board.member.role,
                board.member.name,
                board.member.part_number,
                board.member.revision,
                board.snapshot.identity.layout,
                @tagName(board.snapshot.review.status),
                if (board.fab.readiness.blocked) "BLOCKED" else "ready",
            });
            try ensureMarkdownSize(out, limit);
        }
        try w.writeByte('\n');
    } else if (std.mem.eql(u8, id, "interface-matrix")) {
        for (spec.interfaces) |interface| {
            try w.print("### {s}\n\n| Canonical | {s} pin/net | {s} pin/net | Required |\n| --- | --- | --- | --- |\n", .{
                interface.id, interface.left.board, interface.right.board,
            });
            for (interface.signals) |signal| {
                try w.print("| `{s}` | {s} / `{s}` | {s} / `{s}` | {s} |\n", .{
                    signal.canonical,
                    signal.left_pin,
                    signal.left_net,
                    signal.right_pin,
                    signal.right_net,
                    if (signal.required) "yes" else "no",
                });
                try ensureMarkdownSize(out, limit);
            }
            try w.writeByte('\n');
        }
    } else if (std.mem.eql(u8, id, "validation-summary")) {
        try w.writeAll("| Gate | Result |\n| --- | --- |\n");
        try writeGateRow(w, "Board identity and layouts", analysis.state.identity_ok);
        try writeGateRow(w, "Evaluated interface contract", analysis.state.interface_ok);
        try writeGateRow(w, "Board engineering reviews", analysis.state.board_review_ok);
        try writeGateRow(w, "Fabrication readiness", analysis.state.fab_ok);
        try writeGateRow(w, "Release checklists", analysis.state.checklists_ok);
        try writeGateRow(w, "Content attestation", analysis.state.attested);
        try w.writeByte('\n');
    } else if (std.mem.eql(u8, id, "release-status")) {
        try w.print("System release is **{s}**. Confirmation token: `{s}`. Waiver acceptance is {s}.\n\n", .{
            if (analysis.blocked()) "BLOCKED" else "READY",
            &analysis.release_token,
            if (analysis.needs_waiver) "required" else "not required",
        });
    } else if (std.mem.eql(u8, id, "bom-summary")) {
        try w.writeAll("Generated BOM CSVs are bound to the selected board release inputs and included at:\n\n");
        for (analysis.boards) |board| {
            try w.print("- `{s}`: `boards/{s}/bom.csv`\n", .{ board.member.name, board.member.role });
            try ensureMarkdownSize(out, limit);
        }
        try w.writeByte('\n');
    } else if (std.mem.eql(u8, id, "drc-summary")) {
        try w.writeAll("| Board | Complete gate | Waiver required | Evidence |\n| --- | --- | --- | --- |\n");
        for (analysis.boards) |board| {
            try w.print("| `{s}` | {s} | {s} | `boards/{s}/fab-readiness.json` |\n", .{
                board.member.name,
                if (board.fab.readiness.blocked) "no" else "yes",
                if (board.fab.readiness.needs_waiver) "yes" else "no",
                board.member.role,
            });
            try ensureMarkdownSize(out, limit);
        }
        try w.writeByte('\n');
    } else if (std.mem.eql(u8, id, "checklist-summary")) {
        var total: usize = 0;
        var complete: usize = 0;
        var open: usize = 0;
        for (analysis.documents) |candidate| if (candidate.spec.classification == .checklist) {
            total += candidate.inspected.checklist.total;
            complete += candidate.inspected.checklist.complete;
            open += candidate.inspected.checklist.open;
        };
        try w.print("| Total | Complete | Open |\n| ---: | ---: | ---: |\n| {d} | {d} | {d} |\n\n", .{ total, complete, open });
    }
    try ensureMarkdownSize(out, limit);
}

fn writeGateRow(w: *std.Io.Writer, label: []const u8, ok: bool) !void {
    try w.print("| {s} | {s} |\n", .{ label, if (ok) "PASS" else "BLOCKED" });
}

fn renderApproval(allocator: std.mem.Allocator, analysis: Analysis, bundle: ReleaseBundle) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    const w = &out.writer;
    try w.writeAll("{\"schema\":\"netlisp-system-approval-v1\",\"approved_by\":");
    try json_writer.writeString(w, bundle.actor);
    try w.writeAll(",\"role\":");
    try json_writer.writeString(w, bundle.role);
    try w.writeAll(",\"approved_at\":");
    try json_writer.writeString(w, bundle.at);
    try w.writeAll(",\"release_token\":");
    try json_writer.writeString(w, &analysis.release_token);
    try w.writeAll(",\"content_lock\":");
    try json_writer.writeString(w, &analysis.content_lock);
    try w.writeAll(",\"waivers_accepted\":");
    try w.writeAll(if (bundle.waivers_accepted) "true" else "false");
    try w.writeByte('}');
    return out.written();
}

fn renderReleaseManifest(
    allocator: std.mem.Allocator,
    analysis: Analysis,
    entries: []const zipfile.Entry,
    release_bundle: ?ReleaseBundle,
) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    const w = &out.writer;
    const spec = analysis.parsed.value;
    try w.writeAll("{\"schema\":\"netlisp-system-package-v1\",\"mode\":");
    try json_writer.writeString(w, if (release_bundle == null) "draft" else "release");
    try w.writeAll(",\"system\":");
    try json_writer.writeString(w, spec.name);
    try w.writeAll(",\"part_number\":");
    try json_writer.writeString(w, spec.part_number);
    try w.writeAll(",\"revision\":");
    try json_writer.writeString(w, spec.revision);
    try w.writeAll(",\"generated_at\":");
    try json_writer.writeString(w, analysis.generated_at);
    try w.writeAll(",\"tool_commit\":");
    try json_writer.writeString(w, build_id.current());
    try w.writeAll(",\"release_token\":");
    try json_writer.writeString(w, &analysis.release_token);
    try w.writeAll(",\"content_lock\":");
    try json_writer.writeString(w, &analysis.content_lock);
    try w.writeAll(",\"boards\":[");
    for (analysis.boards, 0..) |board, index| {
        if (index > 0) try w.writeByte(',');
        try w.writeAll("{\"role\":");
        try json_writer.writeString(w, board.member.role);
        try w.writeAll(",\"name\":");
        try json_writer.writeString(w, board.member.name);
        try w.writeAll(",\"part_number\":");
        try json_writer.writeString(w, board.member.part_number);
        try w.writeAll(",\"revision\":");
        try json_writer.writeString(w, board.member.revision);
        try w.writeAll(",\"layout\":");
        try json_writer.writeString(w, board.snapshot.identity.layout);
        try w.writeAll(",\"fab_id\":");
        try json_writer.writeString(w, &board.fab.lock.fab_id);
        try w.writeAll(",\"board_release_token\":");
        try json_writer.writeString(w, &board.fab.lock.release_token);
        try w.writeByte('}');
    }
    try w.writeAll("],\"file_inventory_excludes\":[\"release-manifest.json\",\"checksums.sha256\"],\"checksum_excludes\":[\"checksums.sha256\"],\"files\":[");
    for (entries, 0..) |entry, index| {
        if (index > 0) try w.writeByte(',');
        const digest = system_review.sha256Hex(entry.data);
        try w.writeAll("{\"path\":");
        try json_writer.writeString(w, entry.name);
        try w.writeAll(",\"sha256\":");
        try json_writer.writeString(w, &digest);
        try w.print(",\"bytes\":{d}}}", .{entry.data.len});
    }
    try w.writeAll("]}");
    return out.written();
}

fn boardReleaseFilename(
    allocator: std.mem.Allocator,
    member: system_review.BoardMember,
    result: fab_service.Result,
) ![]const u8 {
    const revision = try fab_release.safeRevision(allocator, member.revision);
    const role = try fab_release.safeRevision(allocator, member.role);
    return std.fmt.allocPrint(allocator, "{s}-{s}-rev-{s}-{s}-release.zip", .{
        role,
        fab_filename.prefix(member.name),
        revision,
        &result.lock.fab_id,
    });
}

// spec: system-review - draft archives are visibly non-fabrication packages and contain no nested board release ZIPs
test "draft README states the no-CAM contract" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var parsed = try std.json.parseFromSlice(system_review.SystemSpec, allocator, "{\"schema\":\"netlisp-system-review-v1\",\"name\":\"demo\",\"title\":\"Demo\",\"part_number\":\"SYS-1\",\"revision\":\"A\",\"boards\":[{\"name\":\"one\",\"role\":\"main\",\"source\":\"src/one.sexp\",\"part_number\":\"ONE\",\"revision\":\"A\"}]}", .{});
    defer parsed.deinit();
    const fake = Analysis{
        .parsed = parsed,
        .manifest_source = "{}",
        .documents = &.{},
        .assets = &.{},
        .boards = &.{},
        .inputs = &.{},
        .document_attestations = &.{},
        .generated_at = "2026-08-29T00:00:00Z",
        .content_lock = @splat('1'),
        .release_token = @splat('2'),
        .needs_waiver = false,
        .state = .{},
        .interface_diagnostic = .{},
    };
    const text = try renderReadme(allocator, fake, false);
    try std.testing.expect(std.mem.indexOf(u8, text, "DRAFT") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "no Gerber") != null);
}

// spec: system-review - archive members are safe, unique project-relative paths, and draft validation rejects CAM and nested ZIP payloads
test "draft archive validation rejects CAM traversal and duplicate members" {
    const good = [_]zipfile.Entry{
        .{ .name = "README.md", .data = "review" },
        .{ .name = "boards/rf/review.pdf", .data = "%PDF-" },
    };
    try validateArchiveEntries(std.testing.allocator, &good, false);

    const traversal = [_]zipfile.Entry{.{ .name = "../escape.md", .data = "bad" }};
    try std.testing.expectError(error.UnsafeArchivePath, validateArchiveEntries(std.testing.allocator, &traversal, false));
    const duplicate = [_]zipfile.Entry{
        .{ .name = "README.md", .data = "one" },
        .{ .name = "README.md", .data = "two" },
    };
    try std.testing.expectError(error.DuplicateArchiveEntry, validateArchiveEntries(std.testing.allocator, &duplicate, false));
    const case_collision = [_]zipfile.Entry{
        .{ .name = "review/scope.png", .data = "one" },
        .{ .name = "review/SCOPE.PNG", .data = "two" },
    };
    try std.testing.expectError(error.DuplicateArchiveEntry, validateArchiveEntries(std.testing.allocator, &case_collision, false));
    const reserved = [_]zipfile.Entry{.{ .name = "review/CON.txt", .data = "bad" }};
    try std.testing.expectError(error.UnsafeArchivePath, validateArchiveEntries(std.testing.allocator, &reserved, false));
    const nested_release = [_]zipfile.Entry{.{ .name = "fab/board-release.zip", .data = "PK" }};
    try std.testing.expectError(error.DraftContainsCam, validateArchiveEntries(std.testing.allocator, &nested_release, false));
    try validateArchiveEntries(std.testing.allocator, &nested_release, true);
    const gerber = [_]zipfile.Entry{.{ .name = "review/assets/copper.GTL", .data = "G04" }};
    try std.testing.expectError(error.DraftContainsCam, validateArchiveEntries(std.testing.allocator, &gerber, false));
}

// spec: system-review - optional active documents may be absent without blocking release, while every required active document and required checklist must pass
test "optional document lifecycle does not weaken required checklists" {
    var document = system_review.DocumentSpec{
        .id = "optional",
        .title = "Optional evidence",
        .path = "__netlisp_system_review_missing_optional__.md",
        .classification = .checklist,
        .required = false,
    };
    try std.testing.expect((try readActiveDocument(std.testing.allocator, ".", document)) == null);
    const open = system_review.DocumentContent{
        .sha256 = @splat('0'),
        .checklist = .{ .total = 1, .open = 1 },
        .generated_regions = 0,
    };
    try std.testing.expect(!requiredChecklistBlocks(document, open));
    document.required = true;
    try std.testing.expectError(
        error.RequiredDocumentMissing,
        readActiveDocument(std.testing.allocator, ".", document),
    );
    try std.testing.expect(requiredChecklistBlocks(document, open));
    var complete = open;
    complete.checklist = .{ .total = 1, .complete = 1 };
    try std.testing.expect(!requiredChecklistBlocks(document, complete));
}

// spec: system-review - duplicate attestation or source paths are accepted only when their bytes agree
test "duplicate release inputs fail closed on conflicting bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var inputs: std.ArrayList(system_review.InputAttestation) = .empty;
    var seen_inputs: std.StringHashMapUnmanaged(usize) = .empty;
    try appendInput(allocator, &inputs, &seen_inputs, "src/shared.sexp", "same");
    try appendInput(allocator, &inputs, &seen_inputs, "src/shared.sexp", "same");
    try std.testing.expectEqual(@as(usize, 1), inputs.items.len);
    try std.testing.expectError(
        error.ConflictingInput,
        appendInput(allocator, &inputs, &seen_inputs, "src/shared.sexp", "changed"),
    );

    var entries: std.ArrayList(zipfile.Entry) = .empty;
    var seen_sources: std.StringHashMapUnmanaged([64]u8) = .empty;
    try appendUniqueSource(allocator, &entries, &seen_sources, .{ .name = "lib/shared.sexp", .data = "same" });
    try appendUniqueSource(allocator, &entries, &seen_sources, .{ .name = "lib/shared.sexp", .data = "same" });
    try std.testing.expectEqual(@as(usize, 1), entries.items.len);
    try std.testing.expectError(
        error.ConflictingInput,
        appendUniqueSource(allocator, &entries, &seen_sources, .{ .name = "lib/shared.sexp", .data = "changed" }),
    );
}

// spec: system-review - the release manifest states which self-referential inventory and checksum members it excludes
test "release manifest declares inventory and checksum exclusions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var parsed = try std.json.parseFromSlice(system_review.SystemSpec, allocator, "{\"schema\":\"netlisp-system-review-v1\",\"name\":\"demo\",\"title\":\"Demo\",\"part_number\":\"SYS-1\",\"revision\":\"A\",\"boards\":[{\"name\":\"one\",\"role\":\"main\",\"source\":\"src/one.sexp\",\"part_number\":\"ONE\",\"revision\":\"A\"}]}", .{});
    defer parsed.deinit();
    const fake = Analysis{
        .parsed = parsed,
        .manifest_source = "{}",
        .documents = &.{},
        .assets = &.{},
        .boards = &.{},
        .inputs = &.{},
        .document_attestations = &.{},
        .generated_at = "2026-08-29T00:00:00Z",
        .content_lock = @splat('1'),
        .release_token = @splat('2'),
        .needs_waiver = false,
        .state = .{},
        .interface_diagnostic = .{},
    };
    const manifest = try renderReleaseManifest(
        allocator,
        fake,
        &.{.{ .name = "README.md", .data = "review" }},
        null,
    );
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"file_inventory_excludes\":[\"release-manifest.json\",\"checksums.sha256\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"checksum_excludes\":[\"checksums.sha256\"]") != null);
}

test "refresh parsing recovers syntactically valid obsolete attestation shapes" {
    const source =
        \\{"schema":"netlisp-system-review-v1","name":"demo","title":"Demo","part_number":"SYS-1","revision":"A","boards":[{"name":"one","role":"main","source":"src/one.sexp","part_number":"ONE","revision":"A"}],"documents":[{"id":"release","title":"Release","path":"src/systems/demo/release.md","classification":"checklist","required":true}],"attestation":"obsolete"}
    ;
    var parsed = try parseManifestForRefresh(std.testing.allocator, source);
    defer parsed.deinit();
    try std.testing.expect(parsed.value.attestation == null);
}

test "final archive nests unchanged board release and emits approval inventory and checksums" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    var parsed = try std.json.parseFromSlice(
        system_review.SystemSpec,
        allocator,
        "{\"schema\":\"netlisp-system-review-v1\",\"name\":\"demo\",\"title\":\"Demo\",\"part_number\":\"SYS-1\",\"revision\":\"A\",\"boards\":[{\"name\":\"one\",\"role\":\"main\",\"source\":\"src/one.sexp\",\"part_number\":\"ONE\",\"revision\":\"A\"}]}",
        .{},
    );
    defer parsed.deinit();

    const source_entries = [_]zipfile.Entry{
        .{ .name = "src/one.sexp", .data = "(design-block one)" },
    };
    const snapshot: board_review.Snapshot = .{
        .identity = .{
            .name = "one",
            .source = "src/one.sexp",
            .title = "One",
            .part_number = "ONE",
            .revision = "A",
            .layout = "layout-a",
            .generated_at = "2026-08-29T00:00:00Z",
        },
        .review = .{
            .status = .pass,
            .open_notes = 0,
            .notes_path = "src/one.notes.md",
            .notes_source = null,
            .markdown = "# One review\n",
            .pdf = "%PDF-board",
            .json = "{}",
            .bom_csv = "Ref,Part\n",
        },
        .physical = .{
            .pcb_png = "\x89PNG\r\n\x1a\n",
            .consumed_sha256 = @splat('c'),
            .consumed_trace = infra_fs.ReadTrace.init(allocator),
            .fab_inputs = .{
                .source = @splat('3'),
                .layout = @splat('4'),
                .bom = @splat('5'),
                .complete = true,
            },
            .sources = &source_entries,
            .connections = &.{},
        },
    };
    const nested_board_zip = "PK\x03\x04unchanged-board-release";
    const released: fab_service.Result = .{
        .identity = .{ .name = "one", .part_number = "ONE", .revision = "A", .layout = "layout-a" },
        .lock = .{
            .project_commit = "commit",
            .release_token = @splat('r'),
            .fab_id = "1234abcd".*,
            .project_status = .clean,
        },
        .readiness = .{ .needs_waiver = false, .blocked = false, .json = "{\"blocked\":false}" },
        .digests = .{
            .reviewed = @splat('1'),
            .consumed = @splat('2'),
            .source = @splat('3'),
            .layout = @splat('4'),
            .bom_evidence = @splat('5'),
            .dependency = @splat('6'),
            .bom = @splat('7'),
            .centroid = @splat('8'),
            .rules = @splat('9'),
        },
        .zip = nested_board_zip,
    };
    const board_evidence = [_]BoardEvidence{.{
        .member = parsed.value.boards[0],
        .snapshot = snapshot,
        .fab = released,
        .identity_ok = true,
    }};
    const analysis = Analysis{
        .parsed = parsed,
        .manifest_source = "{}",
        .documents = &.{},
        .assets = &.{},
        .boards = &board_evidence,
        .inputs = &.{},
        .document_attestations = &.{},
        .generated_at = "2026-08-29T00:00:00Z",
        .content_lock = @splat('l'),
        .release_token = @splat('t'),
        .needs_waiver = false,
        .state = .{
            .identity_ok = true,
            .interface_ok = true,
            .board_review_ok = true,
            .fab_ok = true,
            .checklists_ok = true,
            .attested = true,
        },
        .interface_diagnostic = .{},
    };
    const released_boards = [_]fab_service.Result{released};
    const built = try composeArchive(allocator, allocator, analysis, .{
        .boards = &released_boards,
        .actor = "reviewer@example.com",
        .role = "writer",
        .at = "2026-08-29T00:00:00Z",
        .waivers_accepted = false,
    });

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "system.zip", .data = built.zip });
    var file = try tmp.dir.openFile(std.testing.io, "system.zip", .{});
    defer file.close(std.testing.io);
    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(std.testing.io, &read_buffer);
    var iterator = try std.zip.Iterator.init(&reader);
    var saw_nested = false;
    var saw_approval = false;
    var saw_manifest = false;
    var saw_checksums = false;
    while (try iterator.next()) |entry| {
        var name_buffer: [1024]u8 = undefined;
        const filename = try entry.getFilename(&reader, &name_buffer, .{});
        var extracted: std.Io.Writer.Allocating = .init(allocator);
        try entry.extractTo(&reader, &extracted.writer);
        if (std.mem.startsWith(u8, filename, "fab/") and std.mem.endsWith(u8, filename, ".zip")) {
            saw_nested = true;
            try std.testing.expectEqualStrings(nested_board_zip, extracted.written());
        } else if (std.mem.eql(u8, filename, "approval.json")) {
            saw_approval = true;
            try std.testing.expect(std.mem.indexOf(u8, extracted.written(), "reviewer@example.com") != null);
        } else if (std.mem.eql(u8, filename, "release-manifest.json")) {
            saw_manifest = true;
            try std.testing.expect(std.mem.indexOf(u8, extracted.written(), "\"mode\":\"release\"") != null);
        } else if (std.mem.eql(u8, filename, "checksums.sha256")) {
            saw_checksums = true;
            try std.testing.expect(std.mem.indexOf(u8, extracted.written(), "fab/") != null);
        }
    }
    try std.testing.expect(saw_nested and saw_approval and saw_manifest and saw_checksums);
}

// spec: system-review - flat safe workspace assets are content-validated, deterministically hashed, and archived beside combined Markdown under review/assets
test "workspace assets become source attestations and colocated review members" {
    const assets = [_]review_assets.Asset{
        .{ .name = "scope.txt", .relative_path = "src/systems/demo/assets/scope.txt", .data = "trace\n" },
    };
    var inputs: std.ArrayList(system_review.InputAttestation) = .empty;
    defer inputs.deinit(std.testing.allocator);
    var seen: std.StringHashMapUnmanaged(usize) = .empty;
    defer seen.deinit(std.testing.allocator);
    try appendAssetInputs(std.testing.allocator, &inputs, &seen, &assets);
    defer for (inputs.items) |input| {
        std.testing.allocator.free(input.path);
        std.testing.allocator.free(input.sha256);
    };
    try std.testing.expectEqual(@as(usize, 1), inputs.items.len);
    try std.testing.expectEqualStrings(assets[0].relative_path, inputs.items[0].path);

    var entries: std.ArrayList(zipfile.Entry) = .empty;
    defer {
        for (entries.items) |entry| std.testing.allocator.free(entry.name);
        entries.deinit(std.testing.allocator);
    }
    try appendAssetEntries(std.testing.allocator, &entries, &assets);
    try std.testing.expectEqualStrings("review/assets/scope.txt", entries.items[0].name);
    try std.testing.expectEqualStrings("trace\n", entries.items[0].data);
}

// spec: system-review - independently allocated fabrication snapshots compare their identity strings by value
test "fabrication stability accepts equal identities from separate evaluations" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const before = fab_service.Result{
        .identity = .{ .name = "board", .part_number = "PN", .revision = "B3", .layout = "release" },
        .lock = .{
            .project_commit = "abc",
            .release_token = @splat('0'),
            .fab_id = "12345678".*,
            .project_status = .dirty,
        },
        .readiness = .{ .needs_waiver = true, .blocked = true, .json = "{}" },
        .digests = .{
            .reviewed = @splat('1'),
            .consumed = @splat('2'),
            .source = @splat('3'),
            .layout = @splat('4'),
            .bom_evidence = @splat('5'),
            .dependency = @splat('6'),
            .bom = @splat('7'),
            .centroid = @splat('8'),
            .rules = @splat('9'),
        },
    };
    var after = before;
    after.identity = .{
        .name = try allocator.dupe(u8, before.identity.name),
        .part_number = try allocator.dupe(u8, before.identity.part_number),
        .revision = try allocator.dupe(u8, before.identity.revision),
        .layout = try allocator.dupe(u8, before.identity.layout),
    };
    after.lock.project_commit = try allocator.dupe(u8, before.lock.project_commit);
    try std.testing.expect(sameFabSnapshot(before, after));

    after.identity.layout = "prototype";
    try std.testing.expect(!sameFabSnapshot(before, after));
}

// spec: system-review - the system release token binds the stable content lock to every ordinary board release token
test "system release token changes with either board lock" {
    const first = ReleaseBinding{ .role = "rf", .token = @splat('1') };
    var second = ReleaseBinding{ .role = "base", .token = @splat('2') };
    const before = releaseTokenBindings(@splat('a'), &.{ first, second });
    second.token = @splat('3');
    const after = releaseTokenBindings(@splat('a'), &.{ first, second });
    try std.testing.expect(!std.mem.eql(u8, &before, &after));
}

test "board identity requires the exact resolved root source" {
    try std.testing.expect(boardSourceMatches(
        "src/boards/barracuda/barracuda.sexp",
        "src/boards/barracuda/barracuda.sexp",
    ));
    try std.testing.expect(!boardSourceMatches(
        "lib/modules/base-interface.sexp",
        "src/boards/barracuda/barracuda.sexp",
    ));
}

test "blessed layout sentinel selects and records the concrete starred row" {
    try std.testing.expect(requestedLayout("blessed") == null);
    try std.testing.expect(selectedLayoutMatches("blessed", "production-v4"));
    try std.testing.expectEqualStrings("production-v4", requestedLayout("production-v4").?);
    try std.testing.expect(selectedLayoutMatches("production-v4", "production-v4"));
    try std.testing.expect(!selectedLayoutMatches("production-v4", "prototype"));
}
