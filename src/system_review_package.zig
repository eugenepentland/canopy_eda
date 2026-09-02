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
const frequency_plan = @import("frequency_plan.zig");
const infra_fs = @import("infra/fs.zig");
const json_writer = @import("json_writer.zig");
const pll_loop = @import("pll_loop.zig");
const review = @import("review.zig");
const system_review = @import("system_review.zig");
const system_review_markers = @import("system_review_markers.zig");
const review_assets = @import("system_review_assets.zig");
const review_html = @import("system_review_html.zig");
const review_md = @import("system_review_md.zig");
const review_pdf = @import("system_review_pdf.zig");
const zipfile = @import("zipfile.zig");
const system_of_boards = @import("diagram/system_of_boards.zig");
const fab_service = @import("serve/fab_release_service.zig");
const fab_filename = @import("serve/fab_filename.zig");

const max_document_bytes: usize = 4 * 1024 * 1024;
const max_document_total_bytes: usize = 32 * 1024 * 1024;
const max_rendered_document_bytes: usize = 2 * 1024 * 1024;
const max_combined_markdown_bytes: usize = 64 * 1024 * 1024;
const max_system_pdf_bytes: usize = 64 * 1024 * 1024;
const max_system_html_bytes: usize = review_html.max_html_bytes;
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

/// The waiver register's verdict for one board: whether the system carries a
/// register at all, and every category whose registered count is not the
/// release run's count.
const WaiverEvidence = struct {
    register_present: bool = false,
    drift: []const waiver_register.Drift = &.{},
};

const BoardEvidence = struct {
    member: system_review.BoardMember,
    snapshot: board_review.Snapshot,
    fab: fab_service.Result,
    identity_ok: bool,
    /// Every part locked and every needs-layout sub-block starred on the
    /// release layout — the ladder's placement and sub-circuit rungs done.
    layout_frozen: bool = true,
    waivers: WaiverEvidence = .{},
};

const GateState = struct {
    identity_ok: bool = true,
    interface_ok: bool = true,
    board_review_ok: bool = true,
    fab_ok: bool = true,
    checklists_ok: bool = true,
    attested: bool = false,
    /// The DRC waiver register is present when a board needs waivers, and
    /// its counts are the release run's counts.
    waivers_ok: bool = true,
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
            !state.checklists_ok or !state.attested or !state.waivers_ok;
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

const DossierHtmlError = @typeInfo(@typeInfo(@TypeOf(draftDossierHtmlImpl)).@"fn".return_type.?).error_union.error_set;

/// Compose the draft dossier's HTML face on its own — byte-identical to the
/// `review/<base>.html` member `draft` archives, watermark included, without
/// building the ZIP around it. Read-only over current workspace state, so a
/// browser surface can serve the review document directly.
pub fn draftDossierHtml(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
) DossierHtmlError![]const u8 {
    return draftDossierHtmlImpl(allocator, project_dir, name);
}

fn draftDossierHtmlImpl(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
) ![]const u8 {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    var analysis = try analyze(scratch.allocator(), allocator, project_dir, name, .draft);
    defer analysis.parsed.deinit();
    return allocator.dupe(u8, try composeDossierHtml(scratch.allocator(), analysis, true));
}

/// The archive's HTML member composition, shared by `composeArchive` and the
/// standalone dossier surface so neither can drift from the other.
fn composeDossierHtml(
    allocator: std.mem.Allocator,
    analysis: Analysis,
    draft_mode: bool,
) ![]const u8 {
    const bodies = try renderDocumentBodies(allocator, analysis);
    return dossierHtmlFromBodies(allocator, analysis, bodies, draft_mode, false);
}

/// The HTML member over already-rendered document bodies — `composeArchive`
/// renders those once for the Markdown face and reuses them here.
fn dossierHtmlFromBodies(
    allocator: std.mem.Allocator,
    analysis: Analysis,
    bodies: DocumentBodies,
    draft_mode: bool,
    waivers_accepted: bool,
) ![]const u8 {
    const html = try renderSystemHtml(allocator, analysis, bodies, draft_mode, waivers_accepted);
    if (html.len > max_system_html_bytes) return error.ArchiveTooLarge;
    return html;
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

/// A system's manifest as `analyze` needs it: the exact bytes read from the
/// workspace plus the validated spec they parse to.
const LoadedManifest = struct {
    source: []const u8,
    parsed: system_review.ParsedSystemSpec,
};

/// The board-free front of `analyze`: reject an unusable `name`, read the
/// manifest, validate it, and confirm it claims the name that was asked for.
/// Factored out so `dossierPreflight` can answer the identical refusals without
/// starting the per-board evidence pass — one implementation, so the fast
/// pre-check and the composer can never disagree about what they reject.
fn loadManifest(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
) !LoadedManifest {
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
    return .{ .source = manifest_source, .parsed = parsed };
}

const PreflightError = @typeInfo(@typeInfo(@TypeOf(dossierPreflightImpl)).@"fn".return_type.?).error_union.error_set;

/// Decide, without touching a board, whether composing this system's dossier is
/// worth starting at all. Returns exactly the refusals `analyze` would reach
/// before its first board — an unusable name, an absent or oversized manifest,
/// a manifest that does not validate, and a manifest naming a different system.
/// Anything this accepts may still fail later inside `analyze`; the point is
/// only that these four never need a minute of board analysis to be reported.
pub fn dossierPreflight(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
) PreflightError!void {
    return dossierPreflightImpl(allocator, project_dir, name);
}

fn dossierPreflightImpl(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
) !void {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    var loaded = try loadManifest(scratch.allocator(), project_dir, name);
    loaded.parsed.deinit();
}

fn analyze(
    allocator: std.mem.Allocator,
    transient_allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    preflight_mode: PreflightMode,
) !Analysis {
    const loaded = try loadManifest(allocator, project_dir, name);
    const manifest_source = loaded.source;
    var parsed = loaded.parsed;
    errdefer parsed.deinit();

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

    var waiver_source: ?[]const u8 = null;
    for (documents.items) |document| if (std.mem.eql(u8, document.spec.id, waiver_document_id)) {
        waiver_source = document.source;
    };
    var waivers_ok = true;
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
        const frozen = layoutFrozen(transient_allocator, project_dir, member);
        board_review_ok = board_review_ok and snapshot.review.status != .fail and snapshot.review.open_notes == 0 and frozen;
        fab_ok = fab_ok and !fab.readiness.blocked;
        const waivers = try boardWaivers(allocator, waiver_source, member.name, fab.readiness.json);
        if (waivers.drift.len > 0 or (!waivers.register_present and fab.readiness.needs_waiver)) waivers_ok = false;
        needs_waiver = needs_waiver or fab.readiness.needs_waiver or snapshot.review.status == .warn;
        if (generated_at.len == 0) generated_at = snapshot.identity.generated_at;
        try boards.append(allocator, .{
            .member = member,
            .snapshot = snapshot,
            .fab = fab,
            .identity_ok = exact_identity,
            .layout_frozen = frozen,
            .waivers = waivers,
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
            .waivers_ok = waivers_ok,
        },
        .interface_diagnostic = interface_diagnostic,
    };
    // Preflight the exact safe Markdown composition used by draft/final export
    // before readiness or attestation can call these inputs current.
    // Compose the document faces once, in draft form, purely to prove the
    // package fits its ceilings before any of it is written anywhere.
    const preflight_bodies = try renderDocumentBodies(allocator, result);
    const preflight_markdown = try renderSystemMarkdown(allocator, result, preflight_bodies, true);
    const preflight_html = try renderSystemHtml(allocator, result, preflight_bodies, true, false);
    const archive_names = try preflightArchiveNames(allocator, result, preflight_mode);
    try preflightArchivePayload(
        allocator,
        result,
        archive_names,
        preflight_markdown.len,
        preflight_html.len,
    );
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
        snapshot.review.diagram_svg,
        snapshot.physical.pcb_png,
        snapshot.physical.assembly.board_html,
    };
    for (slices) |bytes| try addBoundedBytes(total, bytes.len, max_analysis_evidence_bytes);
    for (snapshot.physical.assembly.sprites) |sprite|
        try addBoundedBytes(total, sprite.png.len, max_analysis_evidence_bytes);
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
    try addEngineeringEvidenceBytes(total, snapshot.analysis);
    try addFabEvidenceBytes(total, fab);
}

/// Charge the retained engineering evidence against the same ceiling as the
/// rendered evidence beside it. The snapshot layer already caps every list, so
/// this is a bound being proved rather than one being imposed.
fn addEngineeringEvidenceBytes(total: *usize, analysis: board_review.Engineering) !void {
    try addBoundedBytes(total, @sizeOf(board_review.Engineering), max_analysis_evidence_bytes);
    for (analysis.power) |rail| {
        try addBoundedBytes(total, @sizeOf(board_review.PowerRail), max_analysis_evidence_bytes);
        try addBoundedBytes(total, rail.net.len, max_analysis_evidence_bytes);
        try addBoundedBytes(total, rail.source.label.len, max_analysis_evidence_bytes);
    }
    try addBoundedBytes(total, analysis.thermal.hottest.ref_des.len, max_analysis_evidence_bytes);
    for (analysis.checks.findings) |finding| {
        try addBoundedBytes(total, @sizeOf(board_review.Finding), max_analysis_evidence_bytes);
        try addBoundedBytes(total, finding.ref_des.len, max_analysis_evidence_bytes);
        try addBoundedBytes(total, finding.net.len, max_analysis_evidence_bytes);
        try addBoundedBytes(total, finding.message.len, max_analysis_evidence_bytes);
    }
    for (analysis.pll) |report| try addPllEvidenceBytes(total, report);
    for (analysis.frequency) |report| try addFrequencyPlanEvidenceBytes(total, report);
}

fn addFrequencyPlanEvidenceBytes(total: *usize, report: board_review.FrequencyPlanReport) !void {
    try addBoundedBytes(total, @sizeOf(board_review.FrequencyPlanReport), max_analysis_evidence_bytes);
    try addBoundedBytes(total, report.name.len, max_analysis_evidence_bytes);
    for (report.plans) |plan| {
        try addBoundedBytes(total, @sizeOf(board_review.FrequencyPlanSideband), max_analysis_evidence_bytes);
        const product_storage = std.math.mul(
            usize,
            plan.spurs.rows.len,
            @sizeOf(board_review.SpurProduct),
        ) catch return error.ArchiveTooLarge;
        try addBoundedBytes(total, product_storage, max_analysis_evidence_bytes);
        for (plan.screens.failing) |screen| {
            try addBoundedBytes(total, @sizeOf(board_review.FrequencyScreen), max_analysis_evidence_bytes);
            try addBoundedBytes(total, screen.message.len, max_analysis_evidence_bytes);
        }
    }
}

fn addPllEvidenceBytes(total: *usize, report: board_review.PllReport) !void {
    try addBoundedBytes(total, @sizeOf(board_review.PllReport), max_analysis_evidence_bytes);
    try addBoundedBytes(total, report.name.len, max_analysis_evidence_bytes);
    const schedule_storage = std.math.mul(
        usize,
        report.schedule.len,
        @sizeOf(pll_loop.ScheduleEntry),
    ) catch return error.ArchiveTooLarge;
    try addBoundedBytes(total, schedule_storage, max_analysis_evidence_bytes);
    for (report.populations) |population| {
        try addBoundedBytes(total, @sizeOf(board_review.PllPopulation), max_analysis_evidence_bytes);
        for (population.failing) |screen| {
            try addBoundedBytes(total, @sizeOf(board_review.PllScreen), max_analysis_evidence_bytes);
            try addBoundedBytes(total, screen.message.len, max_analysis_evidence_bytes);
        }
    }
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
    const without_markers = try system_review_markers.stripMarkerLines(allocator, source);
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

const waiver_register = @import("waiver_register.zig");
const pcb_describe = @import("serve/pcb_describe.zig");

/// The manifest document id the standard reserves for the DRC waiver register.
const waiver_document_id = "drc-waivers";

/// Whether the ladder JSON says the release layout is frozen: placement and
/// sub-circuit rungs both done.
fn progressFrozen(allocator: std.mem.Allocator, body: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const stages = parsed.value.object.get("stages") orelse return false;
    if (stages != .array) return false;
    var placement_done = false;
    var subs_done = false;
    for (stages.array.items) |stage| {
        if (stage != .object) continue;
        const id = stage.object.get("id") orelse continue;
        const status = stage.object.get("status") orelse continue;
        if (id != .string or status != .string) continue;
        const done = std.mem.eql(u8, status.string, "done");
        if (std.mem.eql(u8, id.string, "placement")) placement_done = done;
        if (std.mem.eql(u8, id.string, "sub_circuits")) subs_done = done;
    }
    return placement_done and subs_done;
}

/// Ask the completion ladder whether `member`'s release layout is frozen. Any
/// failure to compute the ladder reads as not frozen — a board whose layout
/// cannot be inspected is not one to release.
fn layoutFrozen(transient_allocator: std.mem.Allocator, project_dir: []const u8, member: system_review.BoardMember) bool {
    var arena = std.heap.ArenaAllocator.init(transient_allocator);
    defer arena.deinit();
    const body = pcb_describe.describeProgress(arena.allocator(), project_dir, member.name, .{ .layout = requestedLayout(member.layout) }, null) catch return false;
    return progressFrozen(arena.allocator(), body);
}

/// Compare the register's rows for `board` with the readiness run.
fn boardWaivers(
    allocator: std.mem.Allocator,
    register_source: ?[]const u8,
    board: []const u8,
    readiness_json: []const u8,
) std.mem.Allocator.Error!WaiverEvidence {
    const source = register_source orelse return .{};
    const entries = try waiver_register.parseBoard(allocator, source, board);
    defer allocator.free(entries);
    const actual = try waiver_register.actualWarnings(allocator, readiness_json);
    return .{ .register_present = true, .drift = try waiver_register.drift(allocator, entries, actual) };
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
    try writeBoolField(w, "waivers", analysis.state.waivers_ok, true);
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
        try w.print(",\"layout_frozen\":{s},\"waiver_register\":{s},\"waiver_drift\":[", .{
            if (board.layout_frozen) "true" else "false",
            if (board.waivers.register_present) "true" else "false",
        });
        for (board.waivers.drift, 0..) |entry, drift_index| {
            if (drift_index > 0) try w.writeByte(',');
            try w.writeAll("{\"category\":");
            try json_writer.writeString(w, entry.label);
            try w.print(",\"register\":{d},\"actual\":{d}}}", .{ entry.register, entry.actual });
        }
        try w.writeAll("]}");
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
    try appendEmptyEntry(allocator, &entries, try std.fmt.allocPrint(allocator, "review/{s}.html", .{base}));
    try appendEmptyEntry(allocator, &entries, "review/source/system.json");
    if (spec.boards.len > 0) try appendEmptyEntry(allocator, &entries, system_diagram_member);
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
    html_bytes: usize,
) !void {
    var payload: usize = 0;
    try addBoundedBytes(&payload, analysis.manifest_source.len, max_archive_payload_bytes);
    try addBoundedBytes(&payload, markdown_bytes, max_archive_payload_bytes);
    try addBoundedBytes(&payload, html_bytes, max_archive_payload_bytes);
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
            board.snapshot.review.diagram_svg,
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
    const bodies = try renderDocumentBodies(allocator, analysis);
    const markdown = try renderSystemMarkdown(allocator, analysis, bodies, !is_release);
    const identity = try std.fmt.allocPrint(allocator, "{s} / Rev {s}", .{ spec.part_number, spec.revision });
    const pdf = try review_pdf.compose(allocator, markdown, .{
        .title = spec.title,
        .identity = identity,
        .generated_at = analysis.generated_at,
        .build_id = build_id.current(),
        .draft = !is_release,
    });
    if (pdf.len > max_system_pdf_bytes) return error.ArchiveTooLarge;
    const waivers_accepted = if (release_bundle) |bundle| bundle.waivers_accepted else false;
    const html = try dossierHtmlFromBodies(allocator, analysis, bodies, !is_release, waivers_accepted);

    var entries: std.ArrayList(zipfile.Entry) = .empty;
    const readme = try renderReadme(allocator, analysis, is_release);
    try entries.append(allocator, .{ .name = "README.md", .data = readme });
    const readiness_json = try renderReadiness(allocator, analysis);
    try entries.append(allocator, .{ .name = "readiness.json", .data = readiness_json });
    const base = try std.fmt.allocPrint(allocator, "{s}-rev-{s}-system-review", .{ safe_part, safe_revision });
    try entries.append(allocator, .{ .name = try std.fmt.allocPrint(allocator, "review/{s}.md", .{base}), .data = markdown });
    try entries.append(allocator, .{ .name = try std.fmt.allocPrint(allocator, "review/{s}.pdf", .{base}), .data = pdf });
    // Review evidence, not CAM, exactly like the .md and .pdf beside it, and
    // offline like the per-board fabrication `assembly.html`: a draft carries
    // it too.
    try entries.append(allocator, .{ .name = try std.fmt.allocPrint(allocator, "review/{s}.html", .{base}), .data = html });
    try entries.append(allocator, .{ .name = "review/source/system.json", .data = analysis.manifest_source });
    // Review evidence, not CAM: the system figure the combined Markdown points
    // at travels beside it. A board-free manifest draws nothing and the member
    // is omitted rather than archived empty.
    const system_diagram = try renderSystemDiagram(allocator, spec);
    if (system_diagram.len > 0)
        try entries.append(allocator, .{ .name = system_diagram_member, .data = system_diagram });
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

/// Draw the system-of-boards figure as a standalone SVG document, from the
/// already-validated manifest alone — no filesystem, no evaluator, no clock —
/// so the member is a pure function of the manifest bytes. Returns empty for a
/// manifest with no boards.
fn renderSystemDiagram(
    allocator: std.mem.Allocator,
    spec: system_review.SystemSpec,
) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    if (!try system_of_boards.renderSystemDocumentSvg(allocator, &spec, .{}, &out.writer)) {
        out.deinit();
        return "";
    }
    return out.written();
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
        if (!allowedSvgMember(entry.name)) return error.UnexpectedSvgMember;
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

/// The one archive filename allowed to be an SVG, under each board's evidence
/// directory.
const board_diagram_member = "diagram.svg";
/// The one system-level SVG: the boards-and-interfaces figure the combined
/// review Markdown points at.
const system_diagram_member = "review/system-diagram.svg";

/// SVG is admitted at exactly two shapes of path — `boards/<role>/diagram.svg`
/// and `review/system-diagram.svg` — and refused everywhere else, in draft and
/// release alike.
///
/// The distinction is provenance, not the format: both files are written by the
/// diagram renderers inside this process, one from an evaluated design and one
/// from the validated manifest, so their markup is ours. An SVG a person
/// uploaded is not, and can carry script, so `system_review_assets.Kind` still
/// refuses SVG at the upload boundary — this check keeps that refusal true of
/// the archive as well, so a future asset kind cannot quietly smuggle a
/// hand-authored SVG in beside the review Markdown.
fn allowedSvgMember(name: []const u8) bool {
    if (!std.ascii.endsWithIgnoreCase(name, ".svg")) return true;
    if (std.mem.eql(u8, name, system_diagram_member)) return true;
    const boards_prefix = "boards/";
    if (!std.mem.startsWith(u8, name, boards_prefix)) return false;
    const tail = name[boards_prefix.len..];
    const separator = std.mem.indexOfScalar(u8, tail, '/') orelse return false;
    if (separator == 0) return false;
    return std.mem.eql(u8, tail[separator + 1 ..], board_diagram_member);
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
    // Review evidence, not CAM: the block diagram belongs in the draft as much
    // as review.md does. A design the diagram engine declines to draw yields no
    // bytes, and the member is omitted rather than archived empty.
    if (board.snapshot.review.diagram_svg.len > 0) try entries.append(allocator, .{
        .name = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, board_diagram_member }),
        .data = board.snapshot.review.diagram_svg,
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

/// One inlined manifest document, with its generated regions already expanded
/// and the result canonicalised. Produced exactly once per composition so the
/// combined Markdown, the PDF, and the HTML dossier can never show a reader
/// three different systems.
const RenderedDocument = struct {
    spec: system_review.DocumentSpec,
    markdown: []const u8,
    checklist: system_review.ChecklistSummary,
};

/// One active document archived beside the combined members instead of inlined.
const SupportingDocument = struct {
    title: []const u8,
    path: []const u8,
};

/// Every document face of one analysis: the inlined bodies in manifest order,
/// and the archived-only references listed after them.
const DocumentBodies = struct {
    inlined: []const RenderedDocument,
    supporting: []const SupportingDocument,
};

fn renderDocumentBodies(allocator: std.mem.Allocator, analysis: Analysis) !DocumentBodies {
    const spec = analysis.parsed.value;
    const workspace_prefix = try std.fmt.allocPrint(allocator, "src/systems/{s}/", .{spec.name});
    var inlined: std.ArrayList(RenderedDocument) = .empty;
    var supporting: std.ArrayList(SupportingDocument) = .empty;
    for (analysis.documents) |document| {
        if (!document.spec.include_in_fab) continue;
        if (!std.mem.startsWith(u8, document.spec.path, workspace_prefix)) {
            try supporting.append(allocator, .{
                .title = document.spec.title,
                .path = try archivedDocumentName(allocator, spec.name, document.spec.path),
            });
            continue;
        }
        const expanded = try expandGeneratedRegions(allocator, analysis, document);
        var parsed = try review_md.parse(allocator, expanded, .{});
        defer parsed.deinit();
        try inlined.append(allocator, .{
            .spec = document.spec,
            .markdown = try review_md.renderMarkdownAlloc(allocator, &parsed),
            .checklist = document.inspected.checklist,
        });
    }
    return .{ .inlined = inlined.items, .supporting = supporting.items };
}

fn renderSystemMarkdown(
    allocator: std.mem.Allocator,
    analysis: Analysis,
    bodies: DocumentBodies,
    draft_mode: bool,
) ![]const u8 {
    var combined: std.Io.Writer.Allocating = .init(allocator);
    const spec = analysis.parsed.value;
    try combined.writer.print("# {s} — System Review Package\n\n", .{spec.title});
    if (draft_mode) try combined.writer.writeAll(review_html.draft_marker ++ "\n\n");
    try combined.writer.print("Part number: `{s}`  \nRevision: `{s}`  \nSystem release token: `{s}`\n\n", .{
        spec.part_number,
        spec.revision,
        &analysis.release_token,
    });
    try ensureMarkdownSize(&combined, max_combined_markdown_bytes);
    for (bodies.inlined) |document| {
        try writeMarkdownBounded(&combined, "\n---\n\n", max_combined_markdown_bytes);
        try writeMarkdownBounded(&combined, document.markdown, max_combined_markdown_bytes);
        if (!std.mem.endsWith(u8, document.markdown, "\n"))
            try writeMarkdownBounded(&combined, "\n", max_combined_markdown_bytes);
    }
    try writeMarkdownBounded(&combined, "\n---\n\n## Active supporting documents\n\n", max_combined_markdown_bytes);
    for (bodies.supporting) |document| {
        try combined.writer.print("- {s}: `{s}`\n", .{ document.title, document.path });
        try ensureMarkdownSize(&combined, max_combined_markdown_bytes);
    }
    return canonicalMarkdown(allocator, combined.written(), max_combined_markdown_bytes);
}

/// Render the same expanded documents as the offline HTML dossier: one numbered
/// section per inlined manifest document, the tool-drawn system-of-boards
/// figure, and one per-board evidence section linking the sibling members.
fn renderSystemHtml(
    allocator: std.mem.Allocator,
    analysis: Analysis,
    bodies: DocumentBodies,
    draft_mode: bool,
    waivers_accepted: bool,
) ![]const u8 {
    const sections = try allocator.alloc(review_html.Section, bodies.inlined.len);
    for (bodies.inlined, sections) |document, *section| section.* = .{
        .title = document.spec.title,
        .classification = @tagName(document.spec.classification),
        .markdown = document.markdown,
        .checklist = document.checklist,
    };
    const supporting = try allocator.alloc(review_html.Supporting, bodies.supporting.len);
    for (bodies.supporting, supporting) |document, *entry| entry.* = .{
        .title = document.title,
        .path = document.path,
    };
    const boards = try allocator.alloc(review_html.Board, analysis.boards.len);
    for (analysis.boards, boards) |board, *entry| {
        const source_assembly = board.snapshot.physical.assembly;
        const sprites = try allocator.alloc(review_html.Board.Visual.Sprite, source_assembly.sprites.len);
        for (source_assembly.sprites, sprites) |sprite, *dest| dest.* = .{
            .footprint = sprite.footprint,
            .x = sprite.x,
            .y = sprite.y,
            .w = sprite.w,
            .h = sprite.h,
            .png = sprite.png,
        };
        entry.* = .{
            .identity = .{
                .role = board.member.role,
                .design = board.member.name,
                .title = board.snapshot.identity.title,
                .part_number = board.member.part_number,
                .revision = board.member.revision,
                .layout = board.snapshot.identity.layout,
                .generated_at = board.snapshot.identity.generated_at,
            },
            .review = .{
                .status = @tagName(board.snapshot.review.status),
                .open_notes = board.snapshot.review.open_notes,
                .diagram_svg = board.snapshot.review.diagram_svg,
                .has_notes = board.snapshot.review.notes_source != null,
            },
            .fabrication = if (board.fab.readiness.blocked)
                .blocked
            else if (board.fab.readiness.needs_waiver)
                .waiver
            else
                .ready,
            .visual = .{
                .board_html = source_assembly.board_html,
                .sprites = sprites,
            },
        };
    }
    return review_html.compose(allocator, sections, .{
        .spec = &analysis.parsed.value,
        .draft = draft_mode,
        .provenance = .{
            .generated_at = analysis.generated_at,
            .build_id = build_id.current(),
            .content_lock = &analysis.content_lock,
            .release_token = &analysis.release_token,
        },
        .state = .{
            .blocked = analysis.blocked(),
            .waiver = if (!analysis.needs_waiver)
                .none
            else if (waivers_accepted)
                .accepted
            else
                .required,
            .attested = analysis.state.attested,
            .gates = .{
                .identity_ok = analysis.state.identity_ok,
                .interface_ok = analysis.state.interface_ok,
                .board_review_ok = analysis.state.board_review_ok,
                .fab_ok = analysis.state.fab_ok,
                .checklists_ok = analysis.state.checklists_ok,
            },
        },
        .checklist = aggregateChecklist(analysis),
        .boards = boards,
        .supporting = supporting,
    });
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
        if (system_review_markers.openId(line)) |id| {
            skipping = true;
            try writeGeneratedSection(&out, analysis, id, max_rendered_document_bytes);
            continue;
        }
        try out.writer.print("{s}\n", .{raw});
        try ensureMarkdownSize(&out, max_rendered_document_bytes);
    }
    return out.written();
}

/// Expand one `<!-- netlisp:generated <id> -->` region.
///
/// Dispatch is over the typed id rather than raw strings: `inspectDocumentContent`
/// already refused any marker whose id is not a `GeneratedSection`, and a
/// document that failed inspection never became evidence, so an unresolvable id
/// here cannot come from a real package.
fn writeGeneratedSection(
    out: *std.Io.Writer.Allocating,
    analysis: Analysis,
    id: []const u8,
    limit: usize,
) !void {
    const section = system_review.generatedSection(id) orelse return;
    switch (section) {
        .@"system-summary" => try writeSystemSummary(out, analysis),
        .@"board-summary" => try writeBoardSummary(out, analysis, limit),
        .@"interface-matrix" => try writeInterfaceMatrix(out, analysis, limit),
        .@"validation-summary" => try writeValidationSummary(out, analysis),
        .@"release-status" => try writeReleaseStatus(out, analysis),
        .@"bom-summary" => try writeBomSummary(out, analysis, limit),
        .@"drc-summary" => try writeDrcSummary(out, analysis, limit),
        .@"checklist-summary" => try writeChecklistSummary(out, analysis),
        .@"power-summary" => try writePowerSummary(out, analysis, limit),
        .@"thermal-summary" => try writeThermalSummary(out, analysis, limit),
        .@"pll-summary" => try writePllSummary(out, analysis, limit),
        .@"frequency-plan-summary" => try writeFrequencyPlanSummary(out, analysis, limit),
        .@"erc-summary" => try writeErcSummary(out, analysis, limit),
        .@"mechanical-summary" => try writeMechanicalSummary(out, analysis, limit),
        .@"open-items" => try writeOpenItems(out, analysis, limit),
        .@"system-diagram" => try writeSystemDiagram(out, analysis, limit),
    }
    try ensureMarkdownSize(out, limit);
}

fn writeSystemSummary(out: *std.Io.Writer.Allocating, analysis: Analysis) !void {
    const spec = analysis.parsed.value;
    try out.writer.print("| Field | Value |\n| --- | --- |\n| System | {s} |\n| Part number | `{s}` |\n| Revision | `{s}` |\n| Content lock | `{s}` |\n| Release token | `{s}` |\n\n", .{
        spec.name, spec.part_number, spec.revision, &analysis.content_lock, &analysis.release_token,
    });
}

fn writeBoardSummary(out: *std.Io.Writer.Allocating, analysis: Analysis, limit: usize) !void {
    const w = &out.writer;
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
}

fn writeInterfaceMatrix(out: *std.Io.Writer.Allocating, analysis: Analysis, limit: usize) !void {
    const w = &out.writer;
    for (analysis.parsed.value.interfaces) |interface| {
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
}

fn writeValidationSummary(out: *std.Io.Writer.Allocating, analysis: Analysis) !void {
    const w = &out.writer;
    try w.writeAll("| Gate | Result |\n| --- | --- |\n");
    try writeGateRow(w, "Board identity and layouts", analysis.state.identity_ok);
    try writeGateRow(w, "Evaluated interface contract", analysis.state.interface_ok);
    try writeGateRow(w, "Board engineering reviews", analysis.state.board_review_ok);
    try writeGateRow(w, "Fabrication readiness", analysis.state.fab_ok);
    try writeGateRow(w, "Release checklists", analysis.state.checklists_ok);
    try writeGateRow(w, "Content attestation", analysis.state.attested);
    try w.writeByte('\n');
}

fn writeReleaseStatus(out: *std.Io.Writer.Allocating, analysis: Analysis) !void {
    try out.writer.print("System release is **{s}**. Confirmation token: `{s}`. Waiver acceptance is {s}.\n\n", .{
        if (analysis.blocked()) "BLOCKED" else "READY",
        &analysis.release_token,
        if (analysis.needs_waiver) "required" else "not required",
    });
}

fn writeDrcSummary(out: *std.Io.Writer.Allocating, analysis: Analysis, limit: usize) !void {
    const w = &out.writer;
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
}

fn writeChecklistSummary(out: *std.Io.Writer.Allocating, analysis: Analysis) !void {
    const checklist = aggregateChecklist(analysis);
    try out.writer.print("| Total | Complete | Open |\n| ---: | ---: | ---: |\n| {d} | {d} | {d} |\n\n", .{
        checklist.total,
        checklist.complete,
        checklist.open,
    });
}

fn aggregateChecklist(analysis: Analysis) system_review.ChecklistSummary {
    var checklist: system_review.ChecklistSummary = .{};
    for (analysis.documents) |candidate| if (candidate.spec.classification == .checklist) {
        checklist.total += candidate.inspected.checklist.total;
        checklist.complete += candidate.inspected.checklist.complete;
        checklist.open += candidate.inspected.checklist.open;
    };
    return checklist;
}

fn writeGateRow(w: *std.Io.Writer, label: []const u8, ok: bool) !void {
    try w.print("| {s} | {s} |\n", .{ label, if (ok) "PASS" else "BLOCKED" });
}

// ── generated engineering sections ─────────────────────────────────────
//
// Every writer below renders from `Analysis` alone — no filesystem, no clock,
// no evaluator — so the same inputs always produce the same bytes. Each one
// states its own "nothing declared" line rather than emitting a headerless
// table, and each row is bounded by the retention caps the board snapshot
// already applied, re-checked against `limit` as it goes.

/// Longest engine-authored prose a generated table cell carries. Messages are
/// one line by construction; this is a ceiling on a pathological one.
const max_generated_cell_bytes: usize = 200;

/// Write engine prose into one Markdown table cell. A pipe would end the cell
/// and a newline would end the row, so both are neutralized, and the text is
/// clipped on a complete codepoint so the document stays valid UTF-8.
fn writeCell(w: *std.Io.Writer, text: []const u8) !void {
    const clipped = clipUtf8(text, max_generated_cell_bytes);
    for (clipped) |byte| switch (byte) {
        '|' => try w.writeByte('/'),
        0...0x1f, 0x7f => try w.writeByte(' '),
        else => try w.writeByte(byte),
    };
    if (clipped.len < text.len) try w.writeAll("...");
}

fn clipUtf8(text: []const u8, limit: usize) []const u8 {
    if (text.len <= limit) return text;
    var end = limit;
    while (end > 0 and text[end] & 0xc0 == 0x80) end -= 1;
    return text[0..end];
}

fn writeVolts(w: *std.Io.Writer, value: ?f64) !void {
    if (value) |volts| try w.print("{d:.3} V", .{volts}) else try w.writeAll("n/a");
}

fn writeAmps(w: *std.Io.Writer, value: ?f64) !void {
    if (value) |amps| try w.print("{d:.3} A", .{amps}) else try w.writeAll("n/a");
}

fn writePercent(w: *std.Io.Writer, value: ?f64) !void {
    if (value) |pct| try w.print("{d:.1}%", .{pct}) else try w.writeAll("n/a");
}

fn writeCelsius(w: *std.Io.Writer, value: ?f64) !void {
    if (value) |degrees| try w.print("{d:.1} C", .{degrees}) else try w.writeAll("n/a");
}

/// SI-scaled frequency, so a loop table reads `1.000 MHz` rather than a raw
/// seven-digit hertz count.
fn writeHertz(w: *std.Io.Writer, hz: f64) !void {
    if (!(hz > 0)) return w.writeAll("n/a");
    if (hz >= 1e9) return w.print("{d:.3} GHz", .{hz / 1e9});
    if (hz >= 1e6) return w.print("{d:.3} MHz", .{hz / 1e6});
    if (hz >= 1e3) return w.print("{d:.3} kHz", .{hz / 1e3});
    return w.print("{d:.1} Hz", .{hz});
}

/// SI-scaled current, for charge-pump figures that live in the milliamp and
/// microamp decades.
fn writeScaledAmps(w: *std.Io.Writer, amps: f64) !void {
    if (!(amps > 0)) return w.writeAll("n/a");
    if (amps >= 1e-3) return w.print("{d:.3} mA", .{amps * 1e3});
    return w.print("{d:.1} uA", .{amps * 1e6});
}

fn writeOutline(w: *std.Io.Writer, outline: board_review.Outline) !void {
    if (!outline.present) return w.writeAll("undeclared");
    try w.print("{d:.3} x {d:.3} mm", .{ outline.w, outline.h });
}

fn writePowerSummary(out: *std.Io.Writer.Allocating, analysis: Analysis, limit: usize) !void {
    const w = &out.writer;
    var rails: usize = 0;
    for (analysis.boards) |board| rails += board.snapshot.analysis.power.len;
    if (rails == 0) {
        try w.writeAll("No board in this system declares a power-rail budget, so there is no generated rail table.\n\n");
        return;
    }
    try w.writeAll("| Board | Rail | Nominal | Source | Source max | Load max | Margin | Consumers | Status |\n" ++
        "| --- | --- | --- | --- | --- | --- | --- | ---: | --- |\n");
    for (analysis.boards) |board| for (board.snapshot.analysis.power) |rail| {
        try w.print("| {s} | `{s}` | ", .{ board.member.role, rail.net });
        try writeVolts(w, rail.nominal_v);
        try w.writeAll(" | ");
        if (rail.source.label.len > 0)
            try w.print("`{s}`", .{rail.source.label})
        else
            try w.writeAll("undeclared");
        try w.writeAll(" | ");
        try writeAmps(w, rail.source.max_a);
        try w.print(" | {d:.3} A | ", .{rail.load_max_a});
        try writePercent(w, rail.margin_pct);
        try w.print(" | {d} | {s} |\n", .{ rail.consumers, @tagName(rail.status) });
        try ensureMarkdownSize(out, limit);
    };
    try w.writeAll("\nPer-device consumer breakdowns for each rail are in `boards/ROLE/review.json`.\n\n");
}

/// The heat rollup, headlined by each board's own board-coupled verdict.
///
/// The Verdict and ambient columns come from `Thermal.verdict` / `.window`,
/// which the snapshot fills from the board review's headline — the cooling
/// ladder over the real outline where a layout resolved one. The datasheet
/// package screen is the more optimistic model (a JEDEC 2s2p theta-JA on a
/// board a fifth its area), so it is never the headline while a board answer
/// exists: it is quoted underneath, labelled as an estimate, and only where it
/// actually disagrees. Under that go the coverage disclosures — a board whose
/// parts mostly declare no power reads cool for want of input, and a release
/// document must never let that pass for a characterised result.
fn writeThermalSummary(out: *std.Io.Writer.Allocating, analysis: Analysis, limit: usize) !void {
    const w = &out.writer;
    var powered: usize = 0;
    for (analysis.boards) |board| powered += board.snapshot.analysis.thermal.coverage.with_power;
    if (powered == 0) {
        try w.writeAll("No board in this system declares part dissipation, so thermal screening has no input.\n\n");
        return;
    }
    try w.writeAll("| Board | Dissipation | Powered parts | Hottest part | Verdict | Ambient | Max ambient | Min ambient |\n" ++
        "| --- | --- | ---: | --- | --- | --- | --- | --- |\n");
    for (analysis.boards) |board| {
        const heat = board.snapshot.analysis.thermal;
        try w.print("| {s} | {d:.3} W | {d} | ", .{ board.member.role, heat.total_w, heat.coverage.with_power });
        if (heat.hottest.ref_des.len > 0)
            try w.print("`{s}` at {d:.3} W", .{ heat.hottest.ref_des, heat.hottest.watts })
        else
            try w.writeAll("n/a");
        try w.print(" | {s} | {d:.1} C | ", .{ @tagName(heat.verdict), heat.ambient_c });
        try writeCelsius(w, heat.window.max_c);
        try w.writeAll(" | ");
        try writeCelsius(w, heat.window.min_c);
        try w.writeAll(" |\n");
        try ensureMarkdownSize(out, limit);
    }
    try w.writeByte('\n');
    try writeThermalDisclosures(out, analysis, limit);
    try w.writeAll("Verdict and ambient window are each board's board-coupled answer where its review resolved a layout, and the package-level screen where it did not; dissipation and the hottest part are the lumped screen's own figures.\n\n");
}

/// Everything the table alone would let a reader believe wrongly, per board and
/// in board order so the section stays a pure function of its inputs.
fn writeThermalDisclosures(out: *std.Io.Writer.Allocating, analysis: Analysis, limit: usize) !void {
    const w = &out.writer;
    var disclosed = false;
    for (analysis.boards) |board| {
        const heat = board.snapshot.analysis.thermal;
        if (thermalEstimateDiffers(heat)) {
            try w.print(
                "- `{s}`: the datasheet package estimate reads `{s}` — theta-JA on the JEDEC 2s2p board (76 x 114 mm), optimistic for anything smaller — while the board-coupled verdict above is `{s}`. The board verdict governs.\n",
                .{ board.member.role, @tagName(heat.model.estimate), @tagName(heat.verdict) },
            );
            disclosed = true;
            try ensureMarkdownSize(out, limit);
        }
        if (!heat.model.board_coupled and heat.verdict != .insufficient_data) {
            try w.print(
                "- `{s}`: no layout resolved for this board, so its verdict is the datasheet package estimate (theta-JA on the JEDEC 2s2p board) rather than a board-coupled result.\n",
                .{board.member.role},
            );
            disclosed = true;
            try ensureMarkdownSize(out, limit);
        }
        if (heat.coverage.unknown_power > 0) {
            try w.print(
                "- `{s}`: {d} of {d} screened parts carry power data; the remaining {d} are unmodelled, so these figures are a partial screen rather than a characterised result.\n",
                .{
                    board.member.role,
                    heat.coverage.with_power,
                    heat.coverage.screened(),
                    heat.coverage.unknown_power,
                },
            );
            disclosed = true;
            try ensureMarkdownSize(out, limit);
        }
    }
    if (disclosed) try w.writeByte('\n');
}

/// Does the demoted datasheet estimate actually disagree with the headline?
/// Quoted only then: a second verdict that says the same thing is noise, and a
/// board with no ladder has no second opinion to disagree with.
fn thermalEstimateDiffers(heat: board_review.Thermal) bool {
    return heat.model.board_coupled and heat.model.estimate != heat.verdict;
}

fn writeErcSummary(out: *std.Io.Writer.Allocating, analysis: Analysis, limit: usize) !void {
    const w = &out.writer;
    if (analysis.boards.len == 0) {
        try w.writeAll("This system declares no boards, so there are no rule-check results to roll up.\n\n");
        return;
    }
    try w.writeAll("| Board | ERC errors | ERC warnings | Assertions pass | warn | fail |\n" ++
        "| --- | ---: | ---: | ---: | ---: | ---: |\n");
    var errors: usize = 0;
    for (analysis.boards) |board| {
        const checks = board.snapshot.analysis.checks;
        errors += checks.errors;
        try w.print("| {s} | {d} | {d} | {d} | {d} | {d} |\n", .{
            board.member.role,
            checks.errors,
            checks.warnings,
            checks.assertions_pass,
            checks.assertions_warn,
            checks.assertions_fail,
        });
        try ensureMarkdownSize(out, limit);
    }
    try w.writeByte('\n');
    if (errors == 0) {
        try w.writeAll("No error-severity ERC violation is outstanding on any board.\n\n");
        return;
    }
    try w.writeAll("| Board | Kind | Ref | Net | Detail |\n| --- | --- | --- | --- | --- |\n");
    for (analysis.boards) |board| try writeErcFindings(out, board, limit);
    try w.writeByte('\n');
    for (analysis.boards) |board| if (board.snapshot.analysis.checks.truncated) {
        try w.print(
            "Listing for `{s}` is capped at {d} of {d} error-severity findings; the complete list is in `boards/{s}/review.json`.\n\n",
            .{
                board.member.name,
                board.snapshot.analysis.checks.findings.len,
                board.snapshot.analysis.checks.errors,
                board.member.role,
            },
        );
        try ensureMarkdownSize(out, limit);
    };
}

fn writeErcFindings(out: *std.Io.Writer.Allocating, board: BoardEvidence, limit: usize) !void {
    const w = &out.writer;
    for (board.snapshot.analysis.checks.findings) |finding| {
        try w.print("| {s} | `{s}` | ", .{ board.member.role, finding.kind });
        if (finding.ref_des.len > 0) try w.print("`{s}`", .{finding.ref_des}) else try w.writeAll("-");
        try w.writeAll(" | ");
        if (finding.net.len > 0) try w.print("`{s}`", .{finding.net}) else try w.writeAll("-");
        try w.writeAll(" | ");
        try writeCell(w, finding.message);
        try w.writeAll(" |\n");
        try ensureMarkdownSize(out, limit);
    }
}

fn writeMechanicalSummary(out: *std.Io.Writer.Allocating, analysis: Analysis, limit: usize) !void {
    const w = &out.writer;
    var described: usize = 0;
    for (analysis.boards) |board| {
        const mech = board.snapshot.analysis.mechanical;
        if (mech.declared.present or mech.measured.present or mech.stackup_layers > 0) described += 1;
    }
    if (described == 0) {
        try w.writeAll("No board in this system declares a board outline or stackup, so there is no generated mechanical table.\n\n");
        return;
    }
    try w.writeAll("| Board | Declared outline | Corner radius | Stackup preset | Layers | Measured outline | Outline |\n" ++
        "| --- | --- | --- | --- | ---: | --- | --- |\n");
    for (analysis.boards) |board| {
        const mech = board.snapshot.analysis.mechanical;
        try w.print("| {s} | ", .{board.member.role});
        try writeOutline(w, mech.declared);
        try w.print(" | {d:.3} mm | ", .{mech.declared.corner_radius});
        if (mech.stackup_preset.len > 0) try w.print("`{s}`", .{mech.stackup_preset}) else try w.writeAll("custom");
        try w.print(" | {d} | ", .{mech.stackup_layers});
        try writeOutline(w, mech.measured);
        try w.print(" | {s} |\n", .{mech.outline.label()});
        try ensureMarkdownSize(out, limit);
    }
    try w.writeAll("\nThe measured outline is the fabrication edge of the exact saved layout this package selected. " ++
        "The Outline column is the same declared-vs-saved verdict the board's `fab-readiness.json` reports as `outline-drift`, " ++
        "computed by the same predicate, and it names what disagrees: `DRIFT (size)` for a bbox outside the fabrication tolerance, " ++
        "`DRIFT (shape)` for a profile the declared rectangle and corner radius do not describe, and " ++
        "`DRIFT (stale approval)` when the source's `(outline-approved …)` pin no longer matches the saved profile. " ++
        "`approved shape` is a non-rectangular profile the source pinned deliberately.\n\n");
}

fn writeBomSummary(out: *std.Io.Writer.Allocating, analysis: Analysis, limit: usize) !void {
    const w = &out.writer;
    if (analysis.boards.len == 0) {
        try w.writeAll("This system declares no boards, so no bill of materials is generated.\n\n");
        return;
    }
    try w.writeAll("Generated BOM CSVs are bound to the selected board release inputs.\n\n" ++
        "| Board | Placements | Distinct lines | DNP placements | DNP lines | CSV |\n" ++
        "| --- | ---: | ---: | ---: | ---: | --- |\n");
    for (analysis.boards) |board| {
        const bom = board.snapshot.analysis.bom;
        try w.print("| `{s}` | {d} | {d} | {d} | {d} | `boards/{s}/bom.csv` |\n", .{
            board.member.name,
            bom.placements,
            bom.lines,
            bom.dnp_placements,
            bom.dnp_lines,
            board.member.role,
        });
        try ensureMarkdownSize(out, limit);
    }
    try w.writeAll("\nPlacements exclude test points, which are probe pads rather than sourced parts, and count each populated instance once. Distinct lines are the CSV's own grouping, so a do-not-populate variant of a part is its own line.\n\n");
}

fn writeSystemDiagram(out: *std.Io.Writer.Allocating, analysis: Analysis, limit: usize) !void {
    const w = &out.writer;
    const spec = analysis.parsed.value;
    if (spec.boards.len == 0) {
        try w.writeAll("This system declares no boards, so no system block diagram is generated.\n\n");
        return;
    }
    try w.print("System block diagram: `{s}` — one node per board, each board-to-board contract drawn as a labeled spine of signal lanes.\n\n", .{system_diagram_member});
    try w.writeAll("| Board | Role | Part number | Revision |\n| --- | --- | --- | --- |\n");
    for (spec.boards) |board| {
        try w.print("| `{s}` | {s} | `{s}` | `{s}` |\n", .{ board.name, board.role, board.part_number, board.revision });
        try ensureMarkdownSize(out, limit);
    }
    try w.writeByte('\n');
    if (spec.interfaces.len == 0) {
        try w.writeAll("No board-to-board interface is declared, so the diagram draws the boards alone.\n\n");
        return;
    }
    try w.writeAll("| Interface | Left | Right | Contacts |\n| --- | --- | --- | ---: |\n");
    for (spec.interfaces) |interface| {
        try w.print("| `{s}` | {s} / `{s}` | {s} / `{s}` | {d} |\n", .{
            interface.id,
            interface.left.board,
            interface.left.connector,
            interface.right.board,
            interface.right.connector,
            interface.contact_count,
        });
        try ensureMarkdownSize(out, limit);
    }
    try w.writeByte('\n');
}

fn writePllSummary(out: *std.Io.Writer.Allocating, analysis: Analysis, limit: usize) !void {
    const w = &out.writer;
    var reports: usize = 0;
    for (analysis.boards) |board| reports += board.snapshot.analysis.pll.len;
    if (reports == 0) {
        try w.writeAll("No board in this system declares a phase-locked-loop filter, so there is no generated loop table.\n\n");
        return;
    }
    for (analysis.boards) |board| for (board.snapshot.analysis.pll) |report| {
        try writePllReport(out, board.member.role, report, limit);
    };
}

fn writePllReport(
    out: *std.Io.Writer.Allocating,
    role: []const u8,
    report: board_review.PllReport,
    limit: usize,
) !void {
    const w = &out.writer;
    try w.print("### {s} loop ", .{role});
    try writeCell(w, report.name);
    try w.print("\n\nMode: {s}. Screening reached: {s}.\n\n", .{ @tagName(report.mode), @tagName(report.outcome) });
    try w.writeAll("| Parameter | Value |\n| --- | --- |\n| Phase detector | ");
    try writeHertz(w, report.profile.pfd_hz);
    try w.print(" |\n| Divider N | {d:.0} |\n| Prescaler | {d:.0} |\n| Charge pump | ", .{
        report.profile.pll_n,
        report.profile.prescaler,
    });
    try writeScaledAmps(w, report.profile.charge_pump_a);
    try w.writeAll(" |\n| Op-amp GBW | ");
    try writeHertz(w, report.profile.op_amp_gbw_hz);
    try w.print(" |\n| Phase-margin target | {d:.1} to {d:.1} deg |\n| Ramp phase-error limit | {d:.4} rad |\n\n", .{
        report.profile.phase_margin_target_deg.min,
        report.profile.phase_margin_target_deg.max,
        report.profile.max_ramp_phase_error_rad,
    });
    try ensureMarkdownSize(out, limit);
    try w.writeAll("| Population | Nominal LBW | Nominal PM | Corner LBW | Corner PM | Ramp phase error | Pass | Warn | Fail |\n" ++
        "| --- | --- | --- | --- | --- | --- | ---: | ---: | ---: |\n");
    for (report.populations) |population| try writePllPopulationRow(out, population, limit);
    try w.writeByte('\n');
    try writePllFailures(out, report, limit);
    try writePllSchedule(out, report, limit);
}

fn writePllPopulationRow(
    out: *std.Io.Writer.Allocating,
    population: board_review.PllPopulation,
    limit: usize,
) !void {
    const w = &out.writer;
    try w.print("| {s} | ", .{@tagName(population.kind)});
    try writeSweepBandwidth(w, population.results.nominal);
    try w.writeAll(" | ");
    try writeSweepPhase(w, population.results.nominal);
    try w.writeAll(" | ");
    try writeSweepBandwidth(w, population.results.tolerance);
    try w.writeAll(" | ");
    try writeSweepPhase(w, population.results.tolerance);
    try w.print(" | {d:.4} rad | {d} | {d} | {d} |\n", .{
        population.results.ramp_phase_error_rad,
        population.pass,
        population.warn,
        population.fail,
    });
    try ensureMarkdownSize(out, limit);
}

fn writeSweepBandwidth(w: *std.Io.Writer, sweep: pll_loop.SweepSummary) !void {
    if (sweep.corners == 0) return w.writeAll("n/a");
    try writeHertz(w, sweep.min_bandwidth_hz);
    try w.writeAll(" to ");
    try writeHertz(w, sweep.max_bandwidth_hz);
}

fn writeSweepPhase(w: *std.Io.Writer, sweep: pll_loop.SweepSummary) !void {
    if (sweep.corners == 0) return w.writeAll("n/a");
    try w.print("{d:.1} to {d:.1} deg", .{ sweep.min_phase_margin_deg, sweep.max_phase_margin_deg });
}

fn writePllFailures(
    out: *std.Io.Writer.Allocating,
    report: board_review.PllReport,
    limit: usize,
) !void {
    const w = &out.writer;
    var failing: usize = 0;
    for (report.populations) |population| failing += population.failing.len;
    if (failing == 0) {
        try w.writeAll("Every screen on this loop passes.\n\n");
        return;
    }
    try w.writeAll("| Population | Screen | Status | Detail |\n| --- | --- | --- | --- |\n");
    for (report.populations) |population| for (population.failing) |screen| {
        try w.print("| {s} | `{s}` | {s} | ", .{ @tagName(population.kind), screen.screen, @tagName(screen.status) });
        try writeCell(w, screen.message);
        try w.writeAll(" |\n");
        try ensureMarkdownSize(out, limit);
    };
    try w.writeByte('\n');
}

fn writePllSchedule(
    out: *std.Io.Writer.Allocating,
    report: board_review.PllReport,
    limit: usize,
) !void {
    if (report.schedule.len == 0) return;
    const w = &out.writer;
    try w.writeAll("Charge-pump schedule:\n\n| Step | Divider N | Kvco | I_CP |\n| ---: | ---: | --- | --- |\n");
    for (report.schedule) |entry| {
        try w.print("| {d} | {d:.0} | ", .{ entry.step, entry.pll_n });
        try writeHertz(w, entry.kvco_hz_per_v);
        try w.writeAll("/V | ");
        try writeScaledAmps(w, entry.current_a);
        try w.writeAll(" |\n");
        try ensureMarkdownSize(out, limit);
    }
    try w.writeByte('\n');
}

/// Megahertz to three decimals — the scale and precision the frequency-plan
/// engine writes its own assertions in, so a generated row and the build
/// assertion behind it show a reader the same digits.
fn writeMhz(w: *std.Io.Writer, hz: f64) !void {
    try w.print("{d:.3} MHz", .{hz / 1e6});
}

fn writeMhzBand(w: *std.Io.Writer, band: frequency_plan.Band) !void {
    try w.print("{d:.3}-{d:.3} MHz", .{ band.lo_hz / 1e6, band.hi_hz / 1e6 });
}

fn sidebandWord(side: frequency_plan.Sideband) []const u8 {
    return switch (side) {
        .high => "high",
        .low => "low",
        .either => "either",
    };
}

fn placementWord(placement: frequency_plan.Placement) []const u8 {
    return switch (placement) {
        .wanted => "wanted",
        .co_channel => "co-channel",
        .filter_rejected => "filter-rejected",
        .out_of_band => "out-of-band",
    };
}

/// What removes a band, in the words the engine's own image assertion uses.
/// `.none` is never rendered as "unfiltered": it means nothing declared
/// removes this band, and an image nothing removes reaches the mixer at full
/// amplitude, which is the fact a reader needs.
fn rejectionWords(rejection: frequency_plan.Rejection) []const u8 {
    return switch (rejection) {
        .none => "removed by nothing declared — it reaches the mixer at full amplitude",
        .if_low_pass => "wholly above the declared IF low-pass cutoff",
        .rf_low_pass => "wholly above the declared RF low-pass cutoff",
        .rf_high_pass => "wholly below the declared RF high-pass cutoff",
        .outside_delivered => "wholly outside the delivered source passband",
    };
}

/// The product table's governing-mechanism cell. A co-channel product is one
/// no filter can reach, which is a different statement from an out-of-band
/// product that merely has no declared filter aimed at it.
fn writeGovernedBy(w: *std.Io.Writer, product: board_review.SpurProduct) !void {
    if (product.placement == .wanted) return w.writeAll("the wanted product");
    if (product.rejection != .none) return w.writeAll(rejectionWords(product.rejection));
    return w.writeAll(switch (product.placement) {
        .co_channel => "no declared filter removes it",
        else => "misses the output band; nothing declared removes it",
    });
}

/// The level cell. A product with no `(spur-table …)` entry states WHERE it
/// lands and nothing about how big it is — this engine never invents a level,
/// so such a row prints no dBc at all. A declared entry that no in-band limit
/// judged prints the authored number and says plainly that nothing claimed it.
fn writeSpurLevel(w: *std.Io.Writer, level: frequency_plan.Level) !void {
    if (!level.declared) return w.writeAll("placement only");
    switch (level.verdict) {
        .unclaimed => try w.print("{d:.1} dBc declared, no in-band claim", .{level.dbc}),
        .within_limit => try w.print("{d:.1} dBc, within limit", .{level.dbc}),
        .over_limit => try w.print("{d:.1} dBc, over limit", .{level.dbc}),
    }
}

fn writeFrequencyPlanSummary(out: *std.Io.Writer.Allocating, analysis: Analysis, limit: usize) !void {
    const w = &out.writer;
    var reports: usize = 0;
    for (analysis.boards) |board| reports += board.snapshot.analysis.frequency.len;
    if (reports == 0) {
        try w.writeAll("No board in this system declares a frequency plan, so there is no generated mixer spur table.\n\n");
        return;
    }
    for (analysis.boards) |board| for (board.snapshot.analysis.frequency) |report| {
        try writeFrequencyPlanReport(out, board.member.role, report, limit);
    };
}

fn writeFrequencyPlanReport(
    out: *std.Io.Writer.Allocating,
    role: []const u8,
    report: board_review.FrequencyPlanReport,
    limit: usize,
) !void {
    const w = &out.writer;
    try w.print("### {s} frequency plan ", .{role});
    try writeCell(w, report.name);
    try w.writeByte('\n');
    try w.writeByte('\n');
    try writeFrequencyProfileLine(out, report);
    for (report.plans) |plan|
        try writeFrequencySidebandPlan(out, plan, report.profile.plan.source.range, limit);
}

/// One sentence-per-fact profile line: the mode the declaration screens under,
/// the LO it mixes against, the band it commands and the enumeration it was
/// screened to. Drive, drive window and in-band limit appear only where the
/// declaration actually authored them.
fn writeFrequencyProfileLine(
    out: *std.Io.Writer.Allocating,
    report: board_review.FrequencyPlanReport,
) !void {
    const w = &out.writer;
    const profile = report.profile;
    const lo = profile.mixer.lo;
    try w.print("Mode: {s}. Screening reached: {s}. LO ", .{ @tagName(report.mode), @tagName(report.outcome) });
    try writeMhz(w, lo.frequency_hz);
    if (lo.drive_declared) {
        try w.print(" at {d:.2} dBm", .{lo.drive_dbm});
        if (lo.window.declared)
            try w.print(" into a {d:.2} to {d:.2} dBm drive window", .{ lo.window.min_dbm, lo.window.max_dbm });
    }
    try w.print(", {s} mixing, sideband {s}. Output band ", .{
        @tagName(profile.mixer.sense),
        sidebandWord(profile.mixer.sideband),
    });
    try writeMhzBand(w, profile.plan.output_band);
    if (profile.plan.source.delivered.declared()) {
        try w.writeAll(" from a source delivering ");
        try writeMhzBand(w, profile.plan.source.delivered);
    } else try w.writeAll(" from a source with no declared delivered passband");
    try w.print(". Products enumerated to order {d}", .{profile.spurs.max_order});
    if (profile.spurs.limit_declared)
        try w.print(" against a {d:.1} dBc in-band limit", .{profile.spurs.in_band_limit_dbc});
    try w.writeAll(".\n\n");
}

fn writeFrequencySidebandPlan(
    out: *std.Io.Writer.Allocating,
    plan: board_review.FrequencyPlanSideband,
    range: frequency_plan.Band,
    limit: usize,
) !void {
    const w = &out.writer;
    try w.print("#### {s}-side plan\n\n", .{sidebandWord(plan.sideband)});
    // An unrealizable sideband carries only its rf_window verdict and no
    // products at all, so it is stated as the refusal it is rather than
    // rendered as a table with no rows under it.
    if (plan.spurs.enumerated == 0) {
        try w.writeAll("This sideband is not a realizable plan against the declared LO: no RF window closed, so no products were enumerated.\n\n");
        return writeFrequencyScreenTable(out, plan, limit);
    }
    try writeFrequencyWindowFacts(out, plan, range, limit);
    try w.writeAll("| Product | Band | Placement | Governed by | Level |\n| --- | --- | --- | --- | --- |\n");
    for (plan.spurs.rows) |product| try writeSpurRow(out, product, limit);
    if (plan.spurs.rows.len < plan.spurs.enumerated)
        try w.print("\nTable capped at {d} of {d} enumerated products.\n", .{
            plan.spurs.rows.len,
            plan.spurs.enumerated,
        });
    try w.writeByte('\n');
    try writeFrequencyScreenTable(out, plan, limit);
}

/// The band facts behind the table: what RF the sideband demands, how the
/// declared source covers it, where the image lands, and the `(m,m)` diagonal
/// family's two counts — the unbounded closed form and what this enumeration
/// actually reached, which are different numbers and are never merged.
fn writeFrequencyWindowFacts(
    out: *std.Io.Writer.Allocating,
    plan: board_review.FrequencyPlanSideband,
    range: frequency_plan.Band,
    limit: usize,
) !void {
    const w = &out.writer;
    try w.writeAll("- Required RF window: ");
    try writeMhzBand(w, plan.rf.required);
    if (range.declared()) {
        try w.writeAll(if (plan.rf.in_range)
            "; the declared source range contains it"
        else
            "; the declared source range does NOT contain it");
    }
    try w.writeAll(".\n- Source coverage: ");
    try writeCoverage(w, plan.rf);
    try w.writeAll("\n- Image: the image band lands at ");
    try writeMhzBand(w, plan.image.band);
    try w.print(" and is {s}.\n- Diagonal (m,m) family: ", .{rejectionWords(plan.image.rejection)});
    try w.print("{d} land in band at the ", .{plan.diagonal.worst_case_count});
    try writeMhz(w, plan.diagonal.worst_case_if_hz);
    try w.print(" low edge, of which this enumeration reached {d}; the band is diagonal-clean above ", .{
        plan.diagonal.enumerated_count,
    });
    try writeMhz(w, plan.diagonal.clean_above_hz);
    try w.writeAll(".\n\n");
    try ensureMarkdownSize(out, limit);
}

fn writeCoverage(w: *std.Io.Writer, window: frequency_plan.RfWindow) !void {
    if (!window.covered_checked)
        return w.writeAll("no delivered passband is declared, so band closure was not screened.");
    if (window.covered)
        return w.writeAll("the delivered passband contains the whole required window.");
    var wrote = false;
    if (!window.uncovered_low.isEmpty()) {
        try writeMhzBand(w, window.uncovered_low);
        try w.writeAll(" of the required window falls below the delivered passband");
        wrote = true;
    }
    if (!window.uncovered_high.isEmpty()) {
        try w.writeAll(if (wrote) " and " else "");
        try writeMhzBand(w, window.uncovered_high);
        try w.writeAll(" falls above it");
    }
    try w.writeAll(" — the plan does not close.");
}

fn writeSpurRow(
    out: *std.Io.Writer.Allocating,
    product: board_review.SpurProduct,
    limit: usize,
) !void {
    const w = &out.writer;
    try w.print("| ({d},{d}) | ", .{ product.order.m, product.order.n });
    try writeMhzBand(w, product.band);
    try w.print(" | {s} | ", .{placementWord(product.placement)});
    try writeGovernedBy(w, product);
    try w.writeAll(" | ");
    try writeSpurLevel(w, product.level);
    try w.writeAll(" |\n");
    try ensureMarkdownSize(out, limit);
}

fn writeFrequencyScreenTable(
    out: *std.Io.Writer.Allocating,
    plan: board_review.FrequencyPlanSideband,
    limit: usize,
) !void {
    const w = &out.writer;
    if (plan.screens.failing.len == 0) {
        try w.writeAll("Every screen on this plan passes.\n\n");
        return;
    }
    try w.writeAll("| Screen | Status | Detail |\n| --- | --- | --- |\n");
    for (plan.screens.failing) |screen| {
        try w.print("| `{s}` | {s} | ", .{ screen.screen, @tagName(screen.status) });
        try writeCell(w, screen.message);
        try w.writeAll(" |\n");
        try ensureMarkdownSize(out, limit);
    }
    if (plan.screens.failing.len < plan.screens.warn + plan.screens.fail)
        try w.print("\nList capped at {d} of {d} non-passing screens.\n", .{
            plan.screens.failing.len,
            plan.screens.warn + plan.screens.fail,
        });
    try w.writeByte('\n');
}

/// One row of the release-blocker register: a stable id, where it came from,
/// how badly it blocks, and a one-line summary.
const OpenItem = struct {
    id: []const u8,
    source: []const u8,
    severity: []const u8,
    summary: []const u8,
};

fn writeOpenItems(out: *std.Io.Writer.Allocating, analysis: Analysis, limit: usize) !void {
    const w = &out.writer;
    if (!openItemsPresent(analysis)) {
        try w.writeAll("No open items: every package gate, board review, rule check, loop screen and frequency-plan screen in this system is clear.\n\n");
        return;
    }
    try w.writeAll("| Item | Source | Severity | Summary |\n| --- | --- | --- | --- |\n");
    try writeGateOpenItems(out, analysis, limit);
    for (analysis.boards) |board| try writeBoardOpenItems(out, board, limit);
    try w.writeByte('\n');
}

fn openItemsPresent(analysis: Analysis) bool {
    if (analysis.blocked()) return true;
    for (analysis.boards) |board| {
        const snapshot = board.snapshot;
        if (snapshot.review.open_notes > 0 or snapshot.review.status != .pass) return true;
        if (snapshot.analysis.checks.errors > 0) return true;
        if (board.fab.readiness.blocked or board.fab.readiness.needs_waiver) return true;
        if (boardPllFailures(board) > 0) return true;
        if (boardFrequencyPlanFailures(board) > 0) return true;
    }
    return false;
}

fn boardPllFailures(board: BoardEvidence) usize {
    var failing: usize = 0;
    for (board.snapshot.analysis.pll) |report| {
        for (report.populations) |population| failing += population.failing.len;
    }
    return failing;
}

fn boardFrequencyPlanFailures(board: BoardEvidence) usize {
    var failing: usize = 0;
    for (board.snapshot.analysis.frequency) |report| {
        for (report.plans) |plan| failing += plan.screens.failing.len;
    }
    return failing;
}

fn writeOpenItemRow(out: *std.Io.Writer.Allocating, item: OpenItem, limit: usize) !void {
    const w = &out.writer;
    try w.print("| `{s}` | {s} | {s} | ", .{ item.id, item.source, item.severity });
    if (restatesSeverity(item.summary, item.severity)) {
        // The row still appears — dropping an open item would falsify the
        // register — but its Summary cell points at the evidence instead of
        // echoing the column beside it.
        try w.print("no detail beyond the severity; see this item's {s} evidence", .{item.source});
    } else try writeCell(w, item.summary);
    try w.writeAll(" |\n");
    try ensureMarkdownSize(out, limit);
}

/// Does this Summary cell say anything the Severity column did not?
///
/// An empty summary, or one that is the severity word under another spelling
/// ("warn" against "warning"), costs the reader a cell and tells them nothing.
/// Case-insensitive and prefix-wise in both directions, so neither the enum
/// tags nor the severity words can drift into agreement unnoticed.
fn restatesSeverity(summary: []const u8, severity: []const u8) bool {
    const text = std.mem.trim(u8, summary, " \t");
    if (text.len == 0) return true;
    const shorter = @min(text.len, severity.len);
    if (shorter == 0) return false;
    return std.ascii.eqlIgnoreCase(text[0..shorter], severity[0..shorter]);
}

fn writeGateOpenItems(out: *std.Io.Writer.Allocating, analysis: Analysis, limit: usize) !void {
    const gates = [_]struct { id: []const u8, ok: bool, summary: []const u8 }{
        .{ .id = "gate-identity", .ok = analysis.state.identity_ok, .summary = "a board's evaluated identity or layout does not match the manifest" },
        .{ .id = "gate-interface", .ok = analysis.state.interface_ok, .summary = "the evaluated connector observations do not satisfy the declared contract" },
        .{ .id = "gate-board-review", .ok = analysis.state.board_review_ok, .summary = "a board engineering review is failing or carries open design notes" },
        .{ .id = "gate-fabrication", .ok = analysis.state.fab_ok, .summary = "a board's fabrication readiness gate is blocked" },
        .{ .id = "gate-checklists", .ok = analysis.state.checklists_ok, .summary = "a required release checklist still has open tasks" },
        .{ .id = "gate-attestation", .ok = analysis.state.attested, .summary = "no current content attestation covers these exact inputs" },
    };
    for (gates) |gate| if (!gate.ok) try writeOpenItemRow(out, .{
        .id = gate.id,
        .source = "package gate",
        .severity = "blocker",
        .summary = gate.summary,
    }, limit);
}

/// What a non-passing board review actually found, in words. The status tag on
/// its own ("warn", "fail") only respells the Severity column beside it, which
/// is how this row used to read; the archived per-board review is where the
/// finding itself lives, so the summary sends the reader there.
fn reviewStatusSummary(status: review.Status) []const u8 {
    return switch (status) {
        .pass => "",
        .warn => "engineering review passed with unresolved warnings; the findings are in this board's `review.md`",
        .fail => "engineering review failed; the findings are in this board's `review.md`",
    };
}

fn writeBoardOpenItems(out: *std.Io.Writer.Allocating, board: BoardEvidence, limit: usize) !void {
    const w = &out.writer;
    const snapshot = board.snapshot;
    if (snapshot.review.status != .pass) try writeOpenItemRow(out, .{
        .id = board.member.role,
        .source = "board review",
        .severity = if (snapshot.review.status == .fail) "blocker" else "warning",
        .summary = reviewStatusSummary(snapshot.review.status),
    }, limit);
    if (snapshot.review.open_notes > 0) {
        try w.print("| `{s}` | design notes | warning | {d} open note(s) in `boards/{s}/design-notes.md` |\n", .{
            board.member.role,
            snapshot.review.open_notes,
            board.member.role,
        });
        try ensureMarkdownSize(out, limit);
    }
    if (snapshot.analysis.checks.errors > 0) {
        try w.print("| `{s}` | ERC | blocker | {d} error-severity violation(s) |\n", .{
            board.member.role,
            snapshot.analysis.checks.errors,
        });
        try ensureMarkdownSize(out, limit);
    }
    if (board.fab.readiness.blocked or board.fab.readiness.needs_waiver) try writeOpenItemRow(out, .{
        .id = board.member.role,
        .source = "fabrication",
        .severity = if (board.fab.readiness.blocked) "blocker" else "waiver",
        .summary = if (board.fab.readiness.blocked)
            "board release gate is blocked"
        else
            "board release requires an explicit waiver",
    }, limit);
    for (snapshot.analysis.pll) |report| try writePllOpenItems(out, board.member.role, report, limit);
    for (snapshot.analysis.frequency) |report|
        try writeFrequencyPlanOpenItems(out, board.member.role, report, limit);
}

/// Where a failing frequency-plan screen names itself in the register. Static
/// per sideband so the row costs no allocation, and worded so two sidebands of
/// one declaration never collapse into the same-looking row.
fn frequencyPlanSource(side: frequency_plan.Sideband) []const u8 {
    return switch (side) {
        .high => "frequency plan (high side)",
        .low => "frequency plan (low side)",
        .either => "frequency plan",
    };
}

fn writeFrequencyPlanOpenItems(
    out: *std.Io.Writer.Allocating,
    role: []const u8,
    report: board_review.FrequencyPlanReport,
    limit: usize,
) !void {
    for (report.plans) |plan| for (plan.screens.failing) |screen| {
        try writeOpenItemRow(out, .{
            .id = role,
            .source = frequencyPlanSource(plan.sideband),
            .severity = @tagName(screen.status),
            .summary = screen.message,
        }, limit);
    };
}

fn writePllOpenItems(
    out: *std.Io.Writer.Allocating,
    role: []const u8,
    report: board_review.PllReport,
    limit: usize,
) !void {
    const w = &out.writer;
    for (report.populations) |population| for (population.failing) |screen| {
        try w.print("| `{s}` | PLL {s} | {s} | ", .{ role, @tagName(population.kind), @tagName(screen.status) });
        try writeCell(w, screen.message);
        try w.writeAll(" |\n");
        try ensureMarkdownSize(out, limit);
    };
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

// spec: system-review - the only archived SVG is the tool-rendered per-board block diagram; SVG is refused at every other archive path in draft and release alike
test "SVG is admitted only as tool-rendered per-board diagram evidence" {
    try std.testing.expect(allowedSvgMember("boards/rf/diagram.svg"));
    // Not SVG at all ⇒ this rule has no opinion.
    try std.testing.expect(allowedSvgMember("boards/rf/review.md"));
    // The permitted name is exact, so no case variant widens the opening.
    try std.testing.expect(!allowedSvgMember("boards/rf/DIAGRAM.SVG"));
    // A user-uploaded asset stays refused here even if the assets allowlist
    // ever grew an SVG kind.
    try std.testing.expect(!allowedSvgMember("review/assets/scope.svg"));
    try std.testing.expect(!allowedSvgMember("boards/rf/extra.svg"));
    try std.testing.expect(!allowedSvgMember("boards/rf/nested/diagram.svg"));
    try std.testing.expect(!allowedSvgMember("boards/diagram.svg"));
    try std.testing.expect(!allowedSvgMember("diagram.svg"));

    const diagram = [_]zipfile.Entry{.{ .name = "boards/rf/diagram.svg", .data = "<svg/>" }};
    try validateArchiveEntries(std.testing.allocator, &diagram, false);
    try validateArchiveEntries(std.testing.allocator, &diagram, true);
    const smuggled = [_]zipfile.Entry{.{ .name = "review/assets/scope.svg", .data = "<svg onload=\"x\"/>" }};
    try std.testing.expectError(
        error.UnexpectedSvgMember,
        validateArchiveEntries(std.testing.allocator, &smuggled, false),
    );
    try std.testing.expectError(
        error.UnexpectedSvgMember,
        validateArchiveEntries(std.testing.allocator, &smuggled, true),
    );
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
            .diagram_svg = "<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>",
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
        .analysis = .{},
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

/// One archive composed from a fixed Analysis carrying two inlined manifest
/// documents, one archived-only supporting document, and one board — enough
/// shape for the HTML dossier to exercise every section kind it renders.
/// `title` is caller-chosen so a test can prove hostile identity text is
/// escaped rather than emitted as markup.
fn composeHtmlFixture(
    allocator: std.mem.Allocator,
    title: []const u8,
    mode: PreflightMode,
) !BuiltArchive {
    const analysis = try htmlFixtureAnalysis(allocator, title, mode);
    if (mode == .draft) return composeArchive(allocator, allocator, analysis, null);
    const released_boards = try allocator.dupe(
        fab_service.Result,
        &[_]fab_service.Result{analysis.boards[0].fab},
    );
    return composeArchive(allocator, allocator, analysis, .{
        .boards = released_boards,
        .actor = "reviewer@example.com",
        .role = "writer",
        .at = "2026-08-29T00:00:00Z",
        .waivers_accepted = false,
    });
}

fn htmlFixtureAnalysis(
    allocator: std.mem.Allocator,
    title: []const u8,
    mode: PreflightMode,
) !Analysis {
    // Titles chosen by callers here never contain a quote or a backslash, so
    // direct interpolation stays valid JSON.
    const manifest = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"netlisp-system-review-v1\",\"name\":\"demo\",\"title\":\"{s}\",\"part_number\":\"SYS-1\",\"revision\":\"A\",\"boards\":[{{\"name\":\"one\",\"role\":\"main\",\"source\":\"src/one.sexp\",\"part_number\":\"ONE\",\"revision\":\"A\"}}]}}",
        .{title},
    );
    const parsed = try std.json.parseFromSlice(system_review.SystemSpec, allocator, manifest, .{});
    const inspected: system_review.DocumentContent = .{
        .sha256 = @splat('0'),
        .checklist = .{},
        .generated_regions = 0,
    };
    const documents = [_]DocumentEvidence{
        .{
            .spec = .{
                .id = "overview",
                .title = "System overview",
                .path = "src/systems/demo/system-overview.md",
                .classification = .design,
            },
            .source = "# Architecture\n\n<!-- netlisp:generated board-summary -->\n<!-- /netlisp:generated -->\n\n<!-- netlisp:generated power-summary -->\n<!-- /netlisp:generated -->\n",
            .inspected = inspected,
        },
        .{
            .spec = .{
                .id = "bringup",
                .title = "Bring-up & acceptance",
                .path = "src/systems/demo/bring-up.md",
                .classification = .bringup,
            },
            .source = "# Bring-up\n\nPower the base board first.\n",
            .inspected = inspected,
        },
        .{
            .spec = .{
                .id = "icd",
                .title = "Interface control",
                .path = "docs/demo-icd.md",
                .classification = .reference,
            },
            .source = "# ICD\n",
            .inspected = inspected,
        },
    };
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
            .diagram_svg = "<svg viewBox=\"0 0 10 10\" class=\"dg-svg\" xmlns=\"http://www.w3.org/2000/svg\"></svg>",
        },
        .analysis = .{},
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
        .zip = if (mode == .release) "PK\x03\x04board" else null,
    };
    const boards = try allocator.dupe(BoardEvidence, &[_]BoardEvidence{.{
        .member = parsed.value.boards[0],
        .snapshot = snapshot,
        .fab = released,
        .identity_ok = true,
    }});
    return .{
        .parsed = parsed,
        .manifest_source = manifest,
        .documents = try allocator.dupe(DocumentEvidence, &documents),
        .assets = &.{},
        .boards = boards,
        .inputs = &.{},
        .document_attestations = &.{},
        .generated_at = "2026-08-29T00:00:00Z",
        .content_lock = @splat('l'),
        .release_token = @splat('t'),
        .needs_waiver = false,
        .state = .{ .attested = mode == .release },
        .interface_diagnostic = .{},
    };
}

const html_member = "review/SYS-1-rev-A-system-review.html";

// spec: system-review - the offline HTML dossier ships beside the combined Markdown and PDF in draft and release, carrying the draft marker only in draft
test "system review HTML dossier is a draft and release member" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const draft_archive = try composeHtmlFixture(allocator, "Demo System", .draft);
    const draft_html = (try draftMemberBytes(allocator, draft_archive.zip, html_member)) orelse
        return error.MissingHtmlMember;
    try std.testing.expect(std.mem.startsWith(u8, draft_html, "<!DOCTYPE html>"));
    try std.testing.expect(std.mem.endsWith(u8, std.mem.trimEnd(u8, draft_html, "\n"), "</html>"));
    try std.testing.expect(std.mem.indexOf(u8, draft_html, "Demo System") != null);
    try std.testing.expect(std.mem.indexOf(u8, draft_html, review_html.draft_marker) != null);
    // The package member and live face carry the same indexed, linear review.
    try std.testing.expect(std.mem.indexOf(u8, draft_html, "Executive summary") != null);
    try std.testing.expect(std.mem.indexOf(u8, draft_html, "<aside class=\"section-index\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, draft_html, "<section class=\"sec\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, draft_html, "<details class=\"sec\"") == null);
    // One numbered section per inlined manifest document, by manifest title.
    try std.testing.expect(std.mem.indexOf(u8, draft_html, "System overview") != null);
    try std.testing.expect(std.mem.indexOf(u8, draft_html, "Bring-up &amp; acceptance") != null);
    // The archived-only document is referenced, not inlined.
    try std.testing.expect(std.mem.indexOf(u8, draft_html, "../review/source/docs/demo-icd.md.txt") != null);
    // The generated region expanded into the HTML exactly as it does into the
    // Markdown: one expansion, rendered by both faces.
    try std.testing.expect(std.mem.indexOf(u8, draft_html, "<th>Role</th>") != null);
    // Sibling evidence is reachable from review/.
    try std.testing.expect(std.mem.indexOf(u8, draft_html, "\"../boards/main/bom.csv\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, draft_html, "\"../boards/main/diagram.svg\"") != null);
    // Same inputs ⇒ same bytes.
    const repeat = try composeHtmlFixture(allocator, "Demo System", .draft);
    try std.testing.expectEqualSlices(u8, draft_archive.zip, repeat.zip);

    const release_archive = try composeHtmlFixture(allocator, "Demo System", .release);
    const release_html = (try draftMemberBytes(allocator, release_archive.zip, html_member)) orelse
        return error.MissingHtmlMember;
    try std.testing.expect(std.mem.indexOf(u8, release_html, review_html.draft_marker) == null);
    try std.testing.expect(std.mem.indexOf(u8, release_html, "Demo System") != null);
}

// spec: system-review - the standalone draft dossier is the archive's own HTML member composed without the archive around it
test "the standalone draft dossier HTML is the archived member byte for byte" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const analysis = try htmlFixtureAnalysis(allocator, "Demo System", .draft);
    const standalone = try composeDossierHtml(allocator, analysis, true);
    // A whole review document, not a fragment: the browser gets the same
    // watermarked page the ZIP member carries.
    try std.testing.expect(std.mem.startsWith(u8, standalone, "<!DOCTYPE html>"));
    try std.testing.expect(std.mem.indexOf(u8, standalone, "Demo System") != null);
    try std.testing.expect(std.mem.indexOf(u8, standalone, review_html.draft_marker) != null);
    // Manifest documents are inlined as numbered sections, not merely linked.
    try std.testing.expect(std.mem.indexOf(u8, standalone, "System overview") != null);

    const archive = try composeHtmlFixture(allocator, "Demo System", .draft);
    const member = (try draftMemberBytes(allocator, archive.zip, html_member)) orelse
        return error.MissingHtmlMember;
    try std.testing.expectEqualSlices(u8, member, standalone);
}

// spec: system-review - identity text reaching the HTML dossier is escaped, so no manifest string can become page markup
test "system review HTML dossier escapes hostile manifest identity" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    // A raw `<` cannot reach this far: the strict Markdown profile refuses the
    // combined member first, which is exactly the layering we want. `&` does
    // reach the page, and must arrive as text rather than an entity opener.
    const archive = try composeHtmlFixture(allocator, "R&D Demo", .draft);
    const html = (try draftMemberBytes(allocator, archive.zip, html_member)) orelse
        return error.MissingHtmlMember;
    try std.testing.expect(std.mem.indexOf(u8, html, "R&amp;D Demo") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "R&D Demo") == null);
}

// spec: system-review - a generated engineering section's no-data line reaches the HTML dossier through the same single expansion the Markdown face renders
test "system review HTML dossier carries a generated section's no-data line for empty board analysis" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    // The fixture board's engineering analysis is default-empty, so the
    // power-summary region must reach the HTML as its no-data sentence.
    const archive = try composeHtmlFixture(allocator, "Demo System", .draft);
    const html = (try draftMemberBytes(allocator, archive.zip, html_member)) orelse
        return error.MissingHtmlMember;
    try std.testing.expect(std.mem.indexOf(
        u8,
        html,
        "No board in this system declares a power-rail budget",
    ) != null);
}

/// One board's draft archive, composed twice from a fixed Analysis so a test
/// can assert both its inventory and its reproducibility. `diagram_svg` is the
/// only thing that varies: empty stands for a design the diagram engine
/// declined to draw.
fn composeDraftForDiagramTest(
    allocator: std.mem.Allocator,
    diagram_svg: []const u8,
) !struct { first: BuiltArchive, second: BuiltArchive } {
    const parsed = try std.json.parseFromSlice(
        system_review.SystemSpec,
        allocator,
        "{\"schema\":\"netlisp-system-review-v1\",\"name\":\"demo\",\"title\":\"Demo\",\"part_number\":\"SYS-1\",\"revision\":\"A\",\"boards\":[{\"name\":\"one\",\"role\":\"main\",\"source\":\"src/one.sexp\",\"part_number\":\"ONE\",\"revision\":\"A\"}]}",
        .{},
    );
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
            .diagram_svg = diagram_svg,
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
        .analysis = .{},
    };
    const boards = try allocator.dupe(BoardEvidence, &[_]BoardEvidence{.{
        .member = parsed.value.boards[0],
        .snapshot = snapshot,
        .fab = .{
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
        },
        .identity_ok = true,
    }});
    const analysis = Analysis{
        .parsed = parsed,
        .manifest_source = "{}",
        .documents = &.{},
        .assets = &.{},
        .boards = boards,
        .inputs = &.{},
        .document_attestations = &.{},
        .generated_at = "2026-08-29T00:00:00Z",
        .content_lock = @splat('l'),
        .release_token = @splat('t'),
        .needs_waiver = false,
        .state = .{},
        .interface_diagnostic = .{},
    };
    return .{
        .first = try composeArchive(allocator, allocator, analysis, null),
        .second = try composeArchive(allocator, allocator, analysis, null),
    };
}

fn draftMemberBytes(
    allocator: std.mem.Allocator,
    archive: []const u8,
    wanted: []const u8,
) !?[]const u8 {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "system.zip", .data = archive });
    var file = try tmp.dir.openFile(std.testing.io, "system.zip", .{});
    defer file.close(std.testing.io);
    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(std.testing.io, &read_buffer);
    var iterator = try std.zip.Iterator.init(&reader);
    while (try iterator.next()) |entry| {
        var name_buffer: [1024]u8 = undefined;
        const filename = try entry.getFilename(&reader, &name_buffer, .{});
        if (!std.mem.eql(u8, filename, wanted)) continue;
        var extracted: std.Io.Writer.Allocating = .init(allocator);
        try entry.extractTo(&reader, &extracted.writer);
        return extracted.written();
    }
    return null;
}

// spec: system-review - per-board block diagram evidence is archived as boards/<role>/diagram.svg in draft and release, reproducibly, and omitted when the design has no diagram
test "board diagram is a deterministic draft member and absent when undrawn" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const rendered = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 10 10\"></svg>";
    const drawn = try composeDraftForDiagramTest(allocator, rendered);
    const member = (try draftMemberBytes(allocator, drawn.first.zip, "boards/main/diagram.svg")) orelse
        return error.MissingDiagramMember;
    try std.testing.expectEqualStrings(rendered, member);
    // The diagram is review evidence, so a draft carries it: composition would
    // have failed with DraftContainsCam otherwise.
    try std.testing.expect(std.mem.indexOf(u8, drawn.first.filename, "draft") != null);
    // Its digest is inventoried alongside every other member.
    const manifest = (try draftMemberBytes(allocator, drawn.first.zip, "release-manifest.json")) orelse
        return error.MissingDiagramMember;
    try std.testing.expect(std.mem.indexOf(u8, manifest, "boards/main/diagram.svg") != null);
    // Same inputs ⇒ same bytes.
    try std.testing.expectEqualSlices(u8, drawn.first.zip, drawn.second.zip);

    const undrawn = try composeDraftForDiagramTest(allocator, "");
    try std.testing.expect((try draftMemberBytes(allocator, undrawn.first.zip, "boards/main/diagram.svg")) == null);
    // Every other board member is still there, so the omission is targeted.
    try std.testing.expect((try draftMemberBytes(allocator, undrawn.first.zip, "boards/main/review.md")) != null);
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

// ── generated engineering sections ─────────────────────────────────────

/// Two boards joined by one interface: enough for every generated section to
/// have a shape to render, and enough for a mixed system where one board
/// carries engineering evidence and the other declares nothing.
const engineering_manifest =
    \\{"schema":"netlisp-system-review-v1","name":"demo","title":"Demo","part_number":"SYS-1","revision":"A",
    \\"boards":[{"name":"one","role":"main","source":"src/one.sexp","part_number":"ONE","revision":"A"},
    \\{"name":"two","role":"rf","source":"src/two.sexp","part_number":"TWO","revision":"A"}],
    \\"interfaces":[{"id":"j1","left":{"board":"one","connector":"J1"},"right":{"board":"two","connector":"J1"},
    \\"contact_count":2,"signals":[
    \\{"canonical":"V_3V3","left_pin":"1","left_net":"V3P3","right_pin":"1","right_net":"V3P3"},
    \\{"canonical":"GND","left_pin":"2","left_net":"GND","right_pin":"2","right_net":"GND"}]}]}
;

/// Populated evidence for the `main` board: one rail, one hot part, one ERC
/// error, a drifted outline, a failing loop screen and a real BOM rollup.
fn fixtureEngineering(allocator: std.mem.Allocator) !board_review.Engineering {
    const rails = try allocator.dupe(board_review.PowerRail, &.{.{
        .net = "V3P3",
        .nominal_v = 3.3,
        .source = .{ .label = "buck/VOUT", .max_a = 2.0 },
        .load_max_a = 1.25,
        .margin_pct = 37.5,
        .status = .ok,
        .consumers = 4,
    }});
    const findings = try allocator.dupe(board_review.Finding, &.{.{
        .kind = "floating_net",
        .ref_des = "U7",
        .net = "LNA_BYPASS",
        .message = "net has a single connection",
    }});
    const failing = try allocator.dupe(board_review.PllScreen, &.{.{
        .screen = "nominal_phase_target",
        .status = .fail,
        .message = "phase margin 31.2 deg below the 45.0 deg target",
    }});
    const populations = try allocator.dupe(board_review.PllPopulation, &.{.{
        .kind = .fitted,
        .results = .{
            .nominal = .{ .corners = 3, .min_bandwidth_hz = 1200, .max_bandwidth_hz = 3400, .min_phase_margin_deg = 31.2, .max_phase_margin_deg = 48.0 },
            .tolerance = .{ .corners = 27, .min_bandwidth_hz = 900, .max_bandwidth_hz = 4100, .min_phase_margin_deg = 24.5, .max_phase_margin_deg = 55.0 },
            .ramp_phase_error_rad = 0.0123,
        },
        .pass = 18,
        .warn = 1,
        .fail = 1,
        .failing = failing,
    }});
    const schedule = try allocator.dupe(pll_loop.ScheduleEntry, &.{
        .{ .pll_n = 200, .kvco_hz_per_v = 6e7, .step = 4, .current_a = 2.5e-3 },
    });
    const pll = try allocator.dupe(board_review.PllReport, &.{.{
        .name = "chirp-loop",
        .mode = .gate,
        .outcome = .screened,
        .profile = .{
            .pfd_hz = 1e6,
            .charge_pump_a = 2.5e-3,
            .prescaler = 4,
            .pll_n = 200,
            .op_amp_gbw_hz = 1e7,
            .phase_margin_target_deg = .{ .min = 45, .max = 60 },
            .max_ramp_phase_error_rad = 0.05,
        },
        .populations = populations,
        .schedule = schedule,
    }});
    return .{
        .power = rails,
        .frequency = try fixtureFrequencyPlans(allocator),
        // The barracuda shape: the board-coupled ladder wants airflow where the
        // datasheet screen called the same board passively fine, and most of
        // the population declares no power at all.
        .thermal = .{
            .ambient_c = 25,
            .verdict = .needs_airflow,
            .total_w = 2.0,
            .hottest = .{ .ref_des = "U2", .watts = 1.75 },
            .window = .{ .max_c = 61.5, .min_c = -40 },
            .model = .{
                .board_coupled = true,
                .estimate = .passive_ok,
                .estimate_window = .{ .max_c = 85, .min_c = -40 },
            },
            .coverage = .{ .with_power = 2, .unknown_power = 5 },
        },
        .checks = .{
            .errors = 3,
            .warnings = 5,
            .findings = findings,
            .truncated = true,
            .assertions_pass = 12,
            .assertions_warn = 1,
            .assertions_fail = 2,
        },
        .mechanical = .{
            .declared = .{ .w = 60, .h = 40, .corner_radius = 2, .present = true },
            .measured = .{ .w = 60.5, .h = 40, .corner_radius = 2, .present = true },
            .outline = .dimensions,
            .stackup_preset = "JLC06161H-3313",
            .stackup_layers = 6,
        },
        .pll = pll,
        .bom = .{ .placements = 4, .lines = 3, .dnp_placements = 1, .dnp_lines = 1 },
    };
}

/// The Barracuda shape: a swept X-band source behind a filter pair that does
/// NOT reach the bottom of the window the plan demands, a fixed LO whose image
/// nothing declared removes, and a spur table that claims one co-channel
/// product and leaves the rest stating placement only.
fn fixtureFrequencyPlans(allocator: std.mem.Allocator) ![]const board_review.FrequencyPlanReport {
    const products = try allocator.dupe(board_review.SpurProduct, &.{
        .{
            .order = .{ .m = 0, .n = 1 },
            .band = .{ .lo_hz = 10.95e9, .hi_hz = 10.95e9 },
            .placement = .out_of_band,
            .rejection = .none,
            .level = .{},
        },
        .{
            .order = .{ .m = 1, .n = 1 },
            .band = .{ .lo_hz = 50e6, .hi_hz = 1.5e9 },
            .placement = .wanted,
            .rejection = .none,
            .level = .{},
        },
        .{
            .order = .{ .m = 2, .n = 2 },
            // Hull across a DC crossing: both monotone branches reach down to 0.
            .band = .{ .lo_hz = 0, .hi_hz = 3e9 },
            .placement = .co_channel,
            .rejection = .none,
            .level = .{ .dbc = -62, .declared = true, .verdict = .within_limit },
        },
        .{
            .order = .{ .m = 3, .n = 1 },
            .band = .{ .lo_hz = 22.05e9, .hi_hz = 26.4e9 },
            .placement = .filter_rejected,
            .rejection = .if_low_pass,
            .level = .{},
        },
    });
    const failing = try allocator.dupe(board_review.FrequencyScreen, &.{
        .{
            .screen = "band_closure",
            .status = .fail,
            .message = "Barracuda Band 1: the high-side RF window 11000.000-12450.000 MHz for output band 50.000-1500.000 MHz leaves the delivered passband 11100.000-12900.000 MHz",
        },
        .{
            .screen = "spur_coverage",
            .status = .warn,
            .message = "Barracuda Band 1: 1 of the high-side co-channel products carry no declared suppression",
        },
    });
    const plans = try allocator.dupe(board_review.FrequencyPlanSideband, &.{.{
        .sideband = .high,
        .rf = .{
            .required = .{ .lo_hz = 11e9, .hi_hz = 12.45e9 },
            .uncovered_low = .{ .lo_hz = 11e9, .hi_hz = 11.1e9 },
            .covered = false,
            .covered_checked = true,
            .in_range = true,
        },
        .image = .{ .band = .{ .lo_hz = 9.45e9, .hi_hz = 10.9e9 }, .rejection = .none },
        .diagonal = .{
            .worst_case_if_hz = 50e6,
            .worst_case_count = 29,
            .enumerated_count = 4,
            .clean_above_hz = 750e6,
        },
        .spurs = .{ .rows = products, .enumerated = products.len },
        .screens = .{ .pass = 4, .warn = 1, .fail = 1, .failing = failing },
    }});
    return allocator.dupe(board_review.FrequencyPlanReport, &.{.{
        .name = "Barracuda Band 1",
        .mode = .gate,
        .outcome = .screened,
        .profile = .{
            .plan = .{
                .output_band = .{ .lo_hz = 50e6, .hi_hz = 1.5e9 },
                .source = .{
                    .range = .{ .lo_hz = 10e9, .hi_hz = 13e9 },
                    .delivered = .{ .lo_hz = 11.1e9, .hi_hz = 12.9e9 },
                },
                .filters = .{ .if_low_pass_hz = 6e9 },
            },
            .mixer = .{
                .sense = .difference,
                .sideband = .high,
                .lo = .{
                    .frequency_hz = 10.95e9,
                    .drive_dbm = 15,
                    .drive_declared = true,
                    .window = .{ .min_dbm = 13, .max_dbm = 17, .declared = true },
                },
                .declared = true,
            },
            .spurs = .{ .max_order = 5, .in_band_limit_dbc = -60, .limit_declared = true },
        },
        .plans = plans,
    }});
}

fn fixtureBoardEvidence(
    allocator: std.mem.Allocator,
    member: system_review.BoardMember,
    engineering: board_review.Engineering,
    open_notes: usize,
) BoardEvidence {
    return .{
        .member = member,
        .snapshot = .{
            .identity = .{
                .name = member.name,
                .source = member.source,
                .title = member.name,
                .part_number = member.part_number,
                .revision = member.revision,
                .layout = "layout-a",
                .generated_at = "2026-08-29T00:00:00Z",
            },
            .review = .{
                .status = .pass,
                .open_notes = open_notes,
                .notes_path = "src/one.notes.md",
                .notes_source = null,
                .markdown = "# review\n",
                .pdf = "%PDF-board",
                .json = "{}",
                .bom_csv = "Ref,Part\n",
                .diagram_svg = "",
            },
            .physical = .{
                .pcb_png = "\x89PNG\r\n\x1a\n",
                .consumed_sha256 = @splat('c'),
                .consumed_trace = infra_fs.ReadTrace.init(allocator),
                .fab_inputs = .{ .source = @splat('3'), .layout = @splat('4'), .bom = @splat('5'), .complete = true },
                .sources = &.{},
                .connections = &.{},
            },
            .analysis = engineering,
        },
        .fab = .{
            .identity = .{ .name = member.name, .part_number = member.part_number, .revision = member.revision, .layout = "layout-a" },
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
        },
        .identity_ok = true,
    };
}

/// An `Analysis` over `engineering_manifest` whose `main` board carries
/// `engineering` and whose `aux` board declares nothing.
fn fixtureAnalysis(
    allocator: std.mem.Allocator,
    engineering: board_review.Engineering,
    clean: bool,
) !Analysis {
    const parsed = try std.json.parseFromSlice(
        system_review.SystemSpec,
        allocator,
        engineering_manifest,
        .{},
    );
    const boards = try allocator.dupe(BoardEvidence, &.{
        fixtureBoardEvidence(allocator, parsed.value.boards[0], engineering, if (clean) 0 else 2),
        fixtureBoardEvidence(allocator, parsed.value.boards[1], .{}, 0),
    });
    return .{
        .parsed = parsed,
        .manifest_source = engineering_manifest,
        .documents = &.{},
        .assets = &.{},
        .boards = boards,
        .inputs = &.{},
        .document_attestations = &.{},
        .generated_at = "2026-08-29T00:00:00Z",
        .content_lock = @splat('l'),
        .release_token = @splat('t'),
        .needs_waiver = false,
        .state = .{
            .identity_ok = true,
            .interface_ok = true,
            .board_review_ok = clean,
            .fab_ok = true,
            .checklists_ok = true,
            .attested = clean,
        },
        .interface_diagnostic = .{},
    };
}

// spec: system-review - readiness reports the waiver register drift and a board whose release layout is not frozen fails board review
test "readiness carries waiver drift and the layout freeze per board" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    try std.testing.expect(progressFrozen(allocator, "{\"stages\":[{\"id\":\"placement\",\"status\":\"done\"},{\"id\":\"sub_circuits\",\"status\":\"done\"}]}"));
    try std.testing.expect(!progressFrozen(allocator, "{\"stages\":[{\"id\":\"placement\",\"status\":\"current\"},{\"id\":\"sub_circuits\",\"status\":\"done\"}]}"));
    try std.testing.expect(!progressFrozen(allocator, "not json"));
    var analysis = try fixtureAnalysis(allocator, .{}, true);
    const boards = try allocator.dupe(BoardEvidence, analysis.boards);
    boards[0].layout_frozen = false;
    boards[0].waivers = .{ .register_present = true, .drift = &.{.{ .label = "courtyard overlap", .register = 0, .actual = 1 }} };
    analysis.boards = boards;
    analysis.state.waivers_ok = false;
    const json = try renderReadiness(allocator, analysis);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"waivers\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"blocked\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"layout_frozen\":false,\"waiver_register\":true,\"waiver_drift\":[{\"category\":\"courtyard overlap\",\"register\":0,\"actual\":1}]") != null);
    const evidence = try boardWaivers(allocator, "### `main`\n\n| Category | Count | Nature |\n| --- | ---: | --- |\n| courtyard overlap | 2 | x |\n", "main", "{\"raw_drc\":[{\"kind\":\"courtyard\",\"severity\":\"warn\"}]}");
    try std.testing.expect(evidence.register_present);
    try std.testing.expectEqual(@as(usize, 1), evidence.drift.len);
    try std.testing.expectEqual(@as(usize, 2), evidence.drift[0].register);
    const absent = try boardWaivers(allocator, null, "main", "{}");
    try std.testing.expect(!absent.register_present);
}

fn renderSection(allocator: std.mem.Allocator, analysis: Analysis, id: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try writeGeneratedSection(&out, analysis, id, max_rendered_document_bytes);
    return out.written();
}

// spec: system-review - the generated power, thermal, mechanical and BOM sections render each board's own computed rows
test "power, thermal, mechanical and BOM sections carry the design's own numbers" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const analysis = try fixtureAnalysis(allocator, try fixtureEngineering(allocator), true);

    const power = try renderSection(allocator, analysis, "power-summary");
    try std.testing.expect(std.mem.indexOf(u8, power, "| main | `V3P3` | 3.300 V | `buck/VOUT` | 2.000 A | 1.250 A | 37.5% | 4 | ok |") != null);

    const heat = try renderSection(allocator, analysis, "thermal-summary");
    try std.testing.expect(std.mem.indexOf(u8, heat, "| main | 2.000 W | 2 | `U2` at 1.750 W | needs_airflow | 25.0 C | 61.5 C | -40.0 C |") != null);
    // The board that declares nothing still gets a row, reading as zeroes.
    try std.testing.expect(std.mem.indexOf(u8, heat, "| rf | 0.000 W | 0 | n/a |") != null);

    const mech = try renderSection(allocator, analysis, "mechanical-summary");
    try std.testing.expect(std.mem.indexOf(u8, mech, "60.000 x 40.000 mm") != null);
    try std.testing.expect(std.mem.indexOf(u8, mech, "`JLC06161H-3313`") != null);
    try std.testing.expect(std.mem.indexOf(u8, mech, "| 60.500 x 40.000 mm | DRIFT (size) |") != null);
    // A board with no outline at all says so rather than claiming a match.
    try std.testing.expect(std.mem.indexOf(u8, mech, "| rf | undeclared") != null);

    const bom = try renderSection(allocator, analysis, "bom-summary");
    try std.testing.expect(std.mem.indexOf(u8, bom, "| `one` | 4 | 3 | 1 | 1 | `boards/main/bom.csv` |") != null);
    // The CSV pointers the section always carried are still there.
    try std.testing.expect(std.mem.indexOf(u8, bom, "`boards/rf/bom.csv`") != null);
}

// spec: system-review - the generated thermal section states each board's board-coupled verdict and quotes the datasheet package screen only as a labelled estimate
test "the thermal section headlines the board verdict and demotes the datasheet screen" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const analysis = try fixtureAnalysis(allocator, try fixtureEngineering(allocator), true);

    const heat = try renderSection(allocator, analysis, "thermal-summary");
    // The board being built needs airflow; the optimistic datasheet verdict
    // reaches the reader only under the table, named as an estimate.
    try std.testing.expect(std.mem.indexOf(u8, heat, "| needs_airflow | 25.0 C | 61.5 C |") != null);
    try std.testing.expect(std.mem.indexOf(u8, heat, "| passive_ok |") == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        heat,
        "- `main`: the datasheet package estimate reads `passive_ok`",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, heat, "JEDEC 2s2p board (76 x 114 mm), optimistic") != null);
    try std.testing.expect(std.mem.indexOf(u8, heat, "The board verdict governs.") != null);

    // A board whose review resolved no layout has no board answer to state, so
    // the section says the verdict it prints is the datasheet estimate.
    var unplaced = try fixtureEngineering(allocator);
    unplaced.thermal.verdict = .passive_ok;
    unplaced.thermal.model = .{ .board_coupled = false, .estimate = .passive_ok, .estimate_window = .{ .max_c = 85 } };
    const flat = try renderSection(allocator, try fixtureAnalysis(allocator, unplaced, true), "thermal-summary");
    try std.testing.expect(std.mem.indexOf(u8, flat, "- `main`: no layout resolved for this board") != null);
    // With one verdict and one model there is nothing to contradict.
    try std.testing.expect(std.mem.indexOf(u8, flat, "datasheet package estimate reads") == null);
}

// spec: system-review - the generated thermal section discloses how much of the screened population carries no power data whenever any part does not
test "the thermal section discloses unmodelled parts behind its numbers" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const analysis = try fixtureAnalysis(allocator, try fixtureEngineering(allocator), true);

    const heat = try renderSection(allocator, analysis, "thermal-summary");
    try std.testing.expect(std.mem.indexOf(
        u8,
        heat,
        "- `main`: 2 of 7 screened parts carry power data; the remaining 5 are unmodelled",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, heat, "partial screen rather than a characterised result") != null);

    // A fully modelled population has nothing to disclose and says nothing.
    var complete = try fixtureEngineering(allocator);
    complete.thermal.coverage = .{ .with_power = 7, .unknown_power = 0 };
    const full = try renderSection(allocator, try fixtureAnalysis(allocator, complete, true), "thermal-summary");
    try std.testing.expect(std.mem.indexOf(u8, full, "carry power data") == null);
    try std.testing.expect(std.mem.indexOf(u8, full, "unmodelled") == null);
}

// spec: system-review - no open-items row carries a summary that only restates the severity column beside it
test "open-items summaries say more than the severity column" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    var analysis = try fixtureAnalysis(allocator, try fixtureEngineering(allocator), false);
    // A non-passing board review is the row that used to read "warning | warn".
    const boards = try allocator.dupe(BoardEvidence, analysis.boards);
    boards[0].snapshot.review.status = .warn;
    boards[1].snapshot.review.status = .fail;
    analysis.boards = boards;

    const items = try renderSection(allocator, analysis, "open-items");
    try std.testing.expect(std.mem.indexOf(u8, items, "| `main` | board review | warning | engineering review passed with unresolved warnings;") != null);
    try std.testing.expect(std.mem.indexOf(u8, items, "| `rf` | board review | blocker | engineering review failed;") != null);
    try expectSummariesAddDetail(items);

    // The guard behind that invariant, at the two spellings that used to slip
    // through: the status tag against its severity word, and an empty cell.
    try std.testing.expect(restatesSeverity("warn", "warning"));
    try std.testing.expect(restatesSeverity("   ", "blocker"));
    try std.testing.expect(!restatesSeverity("engineering review failed", "blocker"));
}

/// No rendered open-items row may leave its Summary cell echoing the Severity
/// cell beside it — checked over the table itself rather than over the strings
/// the writers happen to pass, so a future row cannot reintroduce the defect.
fn expectSummariesAddDetail(rendered: []const u8) !void {
    var lines = std.mem.splitScalar(u8, rendered, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "| `")) continue;
        var cells = std.mem.splitSequence(u8, std.mem.trim(u8, line, "| "), " | ");
        var seen: usize = 0;
        var severity: []const u8 = "";
        var summary: []const u8 = "";
        while (cells.next()) |cell| : (seen += 1) {
            severity = summary;
            summary = cell;
        }
        if (seen < 4) continue;
        try std.testing.expect(!restatesSeverity(summary, severity));
    }
}

// spec: system-review - the generated loop-filter section renders each population's bandwidth and phase-margin ranges, its failing screens and the charge-pump schedule
test "the loop-filter section renders ranges, failing screens and the pump schedule" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const analysis = try fixtureAnalysis(allocator, try fixtureEngineering(allocator), true);

    const pll = try renderSection(allocator, analysis, "pll-summary");
    try std.testing.expect(std.mem.indexOf(u8, pll, "### main loop chirp-loop") != null);
    try std.testing.expect(std.mem.indexOf(u8, pll, "| Phase detector | 1.000 MHz |") != null);
    try std.testing.expect(std.mem.indexOf(u8, pll, "| Charge pump | 2.500 mA |") != null);
    try std.testing.expect(std.mem.indexOf(u8, pll, "| Phase-margin target | 45.0 to 60.0 deg |") != null);
    // Nominal and corner sweeps both appear on the population row, with counts.
    try std.testing.expect(std.mem.indexOf(u8, pll, "| fitted | 1.200 kHz to 3.400 kHz | 31.2 to 48.0 deg | 900.0 Hz to 4.100 kHz | 24.5 to 55.0 deg | 0.0123 rad | 18 | 1 | 1 |") != null);
    // The failing screen is named with its message, not merely counted.
    try std.testing.expect(std.mem.indexOf(u8, pll, "`nominal_phase_target`") != null);
    try std.testing.expect(std.mem.indexOf(u8, pll, "phase margin 31.2 deg below the 45.0 deg target") != null);
    try std.testing.expect(std.mem.indexOf(u8, pll, "Charge-pump schedule:") != null);
    try std.testing.expect(std.mem.indexOf(u8, pll, "| 4 | 200 | 60.000 MHz/V | 2.500 mA |") != null);
}

// spec: system-review - the generated frequency-plan section renders each sideband's band closure, image rejection wording, both diagonal counts and every enumerated product's placement, claiming a level only where one was declared
test "the frequency-plan section renders the closure gap, the image and every product row" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const analysis = try fixtureAnalysis(allocator, try fixtureEngineering(allocator), true);

    const plan = try renderSection(allocator, analysis, "frequency-plan-summary");
    try std.testing.expect(std.mem.indexOf(u8, plan, "### main frequency plan Barracuda Band 1") != null);
    // The profile line states the LO, its drive against the mixer's window,
    // the commanded band, the delivered source and the enumeration bound.
    try std.testing.expect(std.mem.indexOf(
        u8,
        plan,
        "Mode: gate. Screening reached: screened. LO 10950.000 MHz at 15.00 dBm into a 13.00 to 17.00 dBm drive window, difference mixing, sideband high. Output band 50.000-1500.000 MHz from a source delivering 11100.000-12900.000 MHz. Products enumerated to order 5 against a -60.0 dBc in-band limit.",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, plan, "#### high-side plan") != null);
    // Band closure names the interval the delivered passband does not reach.
    try std.testing.expect(std.mem.indexOf(
        u8,
        plan,
        "- Source coverage: 11000.000-11100.000 MHz of the required window falls below the delivered passband — the plan does not close.",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, plan, "- Required RF window: 11000.000-12450.000 MHz; the declared source range contains it.") != null);
    // An image nothing removes is stated as reaching the mixer, not as "none".
    try std.testing.expect(std.mem.indexOf(
        u8,
        plan,
        "- Image: the image band lands at 9450.000-10900.000 MHz and is removed by nothing declared — it reaches the mixer at full amplitude.",
    ) != null);
    // Both diagonal counts, never merged into one number.
    try std.testing.expect(std.mem.indexOf(
        u8,
        plan,
        "- Diagonal (m,m) family: 29 land in band at the 50.000 MHz low edge, of which this enumeration reached 4; the band is diagonal-clean above 750.000 MHz.",
    ) != null);
    // The wanted product stays in the table, labelled rather than counted as a spur.
    try std.testing.expect(std.mem.indexOf(u8, plan, "| (1,1) | 50.000-1500.000 MHz | wanted | the wanted product | placement only |") != null);
    // A co-channel product with a declared level prints it with its verdict;
    // the hull of a DC-crossing product is rendered whole.
    try std.testing.expect(std.mem.indexOf(u8, plan, "| (2,2) | 0.000-3000.000 MHz | co-channel | no declared filter removes it | -62.0 dBc, within limit |") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan, "| (3,1) | 22050.000-26400.000 MHz | filter-rejected | wholly above the declared IF low-pass cutoff | placement only |") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan, "| (0,1) | 10950.000-10950.000 MHz | out-of-band | misses the output band; nothing declared removes it | placement only |") != null);
    // No dBc is claimed anywhere for a product that declared none: the only
    // dBc figures in the whole section are the one declared level and the
    // declared in-band limit.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, plan, " dBc"));
    // Non-passing screens are listed with their messages, as the loop section does.
    try std.testing.expect(std.mem.indexOf(u8, plan, "| `band_closure` | fail | Barracuda Band 1: the high-side RF window 11000.000-12450.000 MHz") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan, "| `spur_coverage` | warn |") != null);
}

// spec: system-review - the generated frequency-plan section renders an unrealizable sideband as a stated refusal and names its own retention caps whenever a product or screen list truncates
test "the frequency-plan section states an unrealizable sideband and its own caps" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    // An unrealizable low-side plan carries only its rf_window verdict and no
    // products, which must read as the refusal it is.
    const refused = try allocator.dupe(board_review.FrequencyScreen, &.{.{
        .screen = "rf_window",
        .status = .fail,
        .message = "Barracuda Band 1: the low-side RF window 9450.000-10900.000 MHz is not a realizable sweep",
    }});
    // A truncated plan: fewer retained rows and screens than the engine produced.
    const rows = try allocator.dupe(board_review.SpurProduct, &.{.{
        .order = .{ .m = 1, .n = 1 },
        .band = .{ .lo_hz = 50e6, .hi_hz = 1.5e9 },
        .placement = .wanted,
        .rejection = .none,
        .level = .{},
    }});
    const plans = try allocator.dupe(board_review.FrequencyPlanSideband, &.{
        .{ .sideband = .low, .screens = .{ .fail = 1, .failing = refused } },
        .{
            .sideband = .high,
            .rf = .{ .required = .{ .lo_hz = 11e9, .hi_hz = 12.45e9 } },
            .spurs = .{ .rows = rows, .enumerated = 83 },
            .screens = .{ .pass = 1, .warn = 3, .failing = refused },
        },
    });
    var engineering: board_review.Engineering = .{};
    engineering.frequency = try allocator.dupe(board_review.FrequencyPlanReport, &.{.{
        .name = "Barracuda Band 1",
        .mode = .advisory,
        .outcome = .unrealizable,
        .profile = .{},
        .plans = plans,
    }});

    const rendered = try renderSection(allocator, try fixtureAnalysis(allocator, engineering, true), "frequency-plan-summary");
    try std.testing.expect(std.mem.indexOf(u8, rendered, "#### low-side plan") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        rendered,
        "This sideband is not a realizable plan against the declared LO: no RF window closed, so no products were enumerated.",
    ) != null);
    // The refusal still carries its verdict; it does not become an empty table.
    try std.testing.expect(std.mem.indexOf(u8, rendered, "| `rf_window` | fail | Barracuda Band 1: the low-side RF window") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "| Product | Band |") != null);
    // Both caps are stated in the rendered text where they bite.
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Table capped at 1 of 83 enumerated products.") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "List capped at 1 of 3 non-passing screens.") != null);
}

// spec: system-review - failing and warning frequency-plan screens join the aggregated open-items register beside the loop screens, one row per screen
test "failing frequency-plan screens reach the open-items register" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const analysis = try fixtureAnalysis(allocator, try fixtureEngineering(allocator), false);

    const items = try renderSection(allocator, analysis, "open-items");
    try std.testing.expect(std.mem.indexOf(
        u8,
        items,
        "| `main` | frequency plan (high side) | fail | Barracuda Band 1: the high-side RF window",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, items, "| `main` | frequency plan (high side) | warn | Barracuda Band 1: 1 of the high-side") != null);
    // The same register still carries the loop screens beside them.
    try std.testing.expect(std.mem.indexOf(u8, items, "| `main` | PLL fitted | fail |") != null);
    try expectSummariesAddDetail(items);

    // A system whose frequency plans all pass contributes no such row, and the
    // clear-register sentence names the frequency screens it checked.
    const clear = try fixtureAnalysis(allocator, .{}, true);
    const none = try renderSection(allocator, clear, "open-items");
    try std.testing.expect(std.mem.indexOf(u8, none, "frequency plan (") == null);
    try std.testing.expect(std.mem.indexOf(u8, none, "frequency-plan screen in this system is clear") != null);
}

// spec: system-review - the generated ERC section reports counts by severity and lists the error-severity findings, stating the cap when it truncates
test "the ERC section rolls up severities and states its own listing cap" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const analysis = try fixtureAnalysis(allocator, try fixtureEngineering(allocator), true);

    const rendered = try renderSection(allocator, analysis, "erc-summary");
    try std.testing.expect(std.mem.indexOf(u8, rendered, "| main | 3 | 5 | 12 | 1 | 2 |") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "| rf | 0 | 0 | 0 | 0 | 0 |") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "| main | `floating_net` | `U7` | `LNA_BYPASS` | net has a single connection |") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "capped at 1 of 3 error-severity findings") != null);

    // A clean system says so instead of printing an empty findings table.
    const clean = try fixtureAnalysis(allocator, .{}, true);
    const quiet = try renderSection(allocator, clean, "erc-summary");
    try std.testing.expect(std.mem.indexOf(u8, quiet, "No error-severity ERC violation is outstanding") != null);
    try std.testing.expect(std.mem.indexOf(u8, quiet, "floating_net") == null);
}

// spec: system-review - the aggregated open-items register lists every failing package gate, board review note, ERC error and failing loop screen, and says so plainly when there are none
test "the open-items register aggregates every blocker the package knows about" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const analysis = try fixtureAnalysis(allocator, try fixtureEngineering(allocator), false);

    const items = try renderSection(allocator, analysis, "open-items");
    try std.testing.expect(std.mem.indexOf(u8, items, "`gate-board-review`") != null);
    try std.testing.expect(std.mem.indexOf(u8, items, "`gate-attestation`") != null);
    try std.testing.expect(std.mem.indexOf(u8, items, "2 open note(s) in `boards/main/design-notes.md`") != null);
    try std.testing.expect(std.mem.indexOf(u8, items, "| `main` | ERC | blocker | 3 error-severity violation(s) |") != null);
    try std.testing.expect(std.mem.indexOf(u8, items, "| `main` | PLL fitted | fail |") != null);
    // A gate that passes contributes no row.
    try std.testing.expect(std.mem.indexOf(u8, items, "`gate-interface`") == null);

    const clear = try fixtureAnalysis(allocator, .{}, true);
    const none = try renderSection(allocator, clear, "open-items");
    try std.testing.expect(std.mem.indexOf(u8, none, "No open items") != null);
    try std.testing.expect(std.mem.indexOf(u8, none, "| Item |") == null);
}

// spec: system-review - every generated section renders bounded, safe Markdown that is deterministic and states its own no-data line when the design declares nothing
test "every generated section is deterministic, safe Markdown with a no-data line" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const empty = try fixtureAnalysis(allocator, .{}, true);
    const full = try fixtureAnalysis(allocator, try fixtureEngineering(allocator), false);

    for (@typeInfo(system_review.GeneratedSection).@"enum".field_names) |id| {
        try expectSectionRendersSafely(allocator, empty, full, id);
    }

    try expectNoDataLines(allocator, empty);
}

/// The data-driven sections name their own missing input rather than
/// emitting a table header with no rows under it.
fn expectNoDataLines(allocator: std.mem.Allocator, empty: Analysis) !void {
    const absent = [_]struct { id: []const u8, phrase: []const u8 }{
        .{ .id = "power-summary", .phrase = "declares a power-rail budget" },
        .{ .id = "thermal-summary", .phrase = "declares part dissipation" },
        .{ .id = "pll-summary", .phrase = "declares a phase-locked-loop filter" },
        .{ .id = "frequency-plan-summary", .phrase = "declares a frequency plan" },
        .{ .id = "mechanical-summary", .phrase = "declares a board outline or stackup" },
    };
    for (absent) |expected| {
        const rendered = try renderSection(allocator, empty, expected.id);
        try std.testing.expect(std.mem.indexOf(u8, rendered, expected.phrase) != null);
        try std.testing.expect(std.mem.indexOf(u8, rendered, "| --- |") == null);
    }
}

/// One generated id renders the same bytes twice, stays inside the rendered-
/// document ceiling, and survives the strict Markdown profile the combined
/// document is composed under — with and without engineering evidence.
fn expectSectionRendersSafely(
    allocator: std.mem.Allocator,
    empty: Analysis,
    full: Analysis,
    id: []const u8,
) !void {
    for ([_]Analysis{ empty, full }) |analysis| {
        const rendered = try renderSection(allocator, analysis, id);
        try std.testing.expect(rendered.len <= max_rendered_document_bytes);
        try std.testing.expectEqualStrings(rendered, try renderSection(allocator, analysis, id));
        try std.testing.expect(std.unicode.utf8ValidateSlice(rendered));
        // The strict profile refuses raw HTML and malformed tables, so a
        // section that parses here can never poison the combined document.
        _ = try canonicalMarkdown(allocator, rendered, max_rendered_document_bytes);
    }
}

// spec: system-review - the system block diagram is archived as review/system-diagram.svg, referenced by the generated system-diagram section, and admitted as the one system-level SVG
test "the system diagram is an archived SVG document the generated section points at" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const analysis = try fixtureAnalysis(allocator, try fixtureEngineering(allocator), true);

    const section = try renderSection(allocator, analysis, "system-diagram");
    try std.testing.expect(std.mem.indexOf(u8, section, "`review/system-diagram.svg`") != null);
    try std.testing.expect(std.mem.indexOf(u8, section, "| `one` | main | `ONE` | `A` |") != null);
    try std.testing.expect(std.mem.indexOf(u8, section, "| `j1` | one / `J1` | two / `J1` | 2 |") != null);

    const built = try composeArchive(allocator, allocator, analysis, null);
    const member = (try draftMemberBytes(allocator, built.zip, system_diagram_member)) orelse
        return error.MissingSystemDiagram;
    try std.testing.expect(std.mem.startsWith(u8, member, "<svg xmlns=\"http://www.w3.org/2000/svg\""));
    try std.testing.expect(std.mem.endsWith(u8, member, "</svg>"));
    try std.testing.expect(std.mem.indexOf(u8, member, "<div") == null);
    // Same inputs, same archive: the figure does not disturb reproducibility.
    const again = try composeArchive(allocator, allocator, analysis, null);
    try std.testing.expectEqualSlices(u8, built.zip, again.zip);

    // The one system-level SVG path is exact; nothing else beside it is admitted.
    try std.testing.expect(allowedSvgMember(system_diagram_member));
    try std.testing.expect(!allowedSvgMember("review/system-diagram-copy.svg"));
    try std.testing.expect(!allowedSvgMember("review/SYSTEM-DIAGRAM.SVG"));
}
