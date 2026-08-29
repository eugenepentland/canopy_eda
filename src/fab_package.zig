//! The fabrication package either side of the gate: which saved board it is
//! built from, when the request can be REFUSED before that board is ever
//! built, and how the archive is composed once the gate authorizes one.
//!
//! ## Why a refusal needs its own cheap path
//!
//! `/api/pcb-gerbers` has always answered an un-fab-ready board with the same
//! 500 the readiness report gives, and it has always done so before composing
//! a single Gerber. What it did NOT do was reach that answer cheaply: it ran
//! the whole release gate first and only then read the verdict off it.
//!
//! Measured on a mid-edit `barracuda` (ReleaseSafe, gate-locked, the shared
//! designs snapshot), one 14.5 s refusal broke down as:
//!
//!     project_state    11 ms   two Git reads
//!     resolve_block   862 ms   evaluating the design
//!     release_view   1718 ms   restoring + pouring the saved board
//!     fab_gate       6203 ms   composed DRC + physical readiness + preflight
//!     identity_mark  4554 ms   digesting the Gerber geometry into a fab ID
//!     release_lock   1111 ms   re-reading and hashing every disk input
//!
//! Every millisecond after the first eleven was spent computing evidence for a
//! certificate the request had already disqualified itself from. The Git reads
//! `fab_release.captureProjectState` makes are the FIRST thing both release
//! handlers do, and for a dirty or unrevisioned project they alone settle the
//! verdict — see `sourceRevisionRefusal` for why that implication is exact.
//!
//! ## What the refusal deliberately does NOT do
//!
//! It does not decide anything the gate decides. It reports the source-revision
//! finding `fab_release` would have reported for the same state, says the rest
//! of the report was not computed, and names `/api/fab-readiness/<design>` —
//! which is left alone, still runs the complete gate, and remains the surface
//! that enumerates every independent finding. Moving a verdict earlier is only
//! safe while the earlier answer is the same answer; a refusal that guessed
//! would be a weaker gate, not a faster one.

const std = @import("std");

const clock = @import("infra/clock.zig");
const export_fab = @import("export_fab.zig");
const export_gerber = @import("export_gerber.zig");
const fab_filename = @import("serve/fab_filename.zig");
const fab_identity = @import("fab_identity.zig");
const fab_readiness = @import("fab_readiness.zig");
const fab_release = @import("fab_release.zig");
const font = @import("font5x7.zig");
const json_writer = @import("json_writer.zig");
const optimizer = @import("placement/optimizer.zig");
const router = @import("placement/router.zig");
const sidecar_store = @import("layout_sidecar_store.zig");
const sidecar_types = @import("layout_sidecar_types.zig");

const SavedLayout = sidecar_types.SavedLayout;

/// `kind` value of a hand-saved layout row, as opposed to a recorded solve.
const kind_manual = "manual";

// ── Which saved board a release is built from ──────────────────────────

/// The saved snapshot the blessed poses come from — the same precedence
/// `chooseSyncPoses` walks (★ default → newest manual → any named), so the
/// fab package's outline + routes are restored from the SAME layout its poses
/// were. Null when only the optimizer cache exists.
pub fn blessedLayout(layouts: []const SavedLayout) ?*const SavedLayout {
    for (layouts) |*L| {
        if (L.default and L.parts.len > 0) return L;
    }
    for (layouts) |*L| {
        if (std.mem.eql(u8, L.kind, kind_manual) and L.parts.len > 0) return L;
    }
    for (layouts) |*L| {
        if (L.parts.len > 0) return L;
    }
    return null;
}

/// What a release request resolves to before any board is built. The two
/// refusing cases are the 404s `fabViewForResolved` raises; the two selecting
/// cases are the boards it goes on to place.
pub const Selection = union(enum) {
    /// A named saved row supplies the poses.
    row: *const SavedLayout,
    /// Nothing is saved but the optimizer cache has poses.
    cache,
    /// `?layout=` named a row that does not exist (or carries no parts).
    unknown_layout,
    /// Nothing is saved and the optimizer cache is empty.
    none_saved,
};

/// The exact board-selection predicate a release applies, factored out of
/// `fabViewForResolved` so a refusal can reach the same 404s without paying
/// for the placement that would otherwise have revealed them. `has_cache_poses`
/// is `sidecar_store.cachePoses(…) != null`, taken as an argument so the caller
/// that needs the poses themselves converts them exactly once.
pub fn select(
    layouts: []const SavedLayout,
    has_cache_poses: bool,
    layout_arg: ?[]const u8,
) Selection {
    if (layout_arg) |wanted| {
        for (layouts) |*L| {
            if (std.mem.eql(u8, L.name, wanted) and L.parts.len > 0) return .{ .row = L };
        }
        return .unknown_layout;
    }
    if (blessedLayout(layouts)) |L| return .{ .row = L };
    return if (has_cache_poses) .cache else .none_saved;
}

// ── The cheap refusal ──────────────────────────────────────────────────

/// A release refusal that is provable from the project's source revision
/// alone, carrying the same finding the full readiness report would carry for
/// this state.
pub const Refusal = struct {
    status: fab_release.ProjectStatus,
    finding: fab_readiness.Item,
};

/// Null unless the source state captured before the first evaluator read
/// ALREADY forces `releaseEvidenceBlocked`.
///
/// The implication is exact, and it is `fab_release.bindBaseline` that makes it
/// so: whatever status `makeLock` computes later, a `before` of `.dirty` or
/// `.unavailable` is folded in, and the folded result is `.ambiguous`,
/// `.unavailable` or `.dirty` — never `.clean`. A lock that is not clean fails
/// `releaseEvidenceBlocked`, which is the 500. Nothing computed in between can
/// rescue it, so nothing computed in between needs to run.
///
/// `.changed` and `.ambiguous` are deliberately NOT accepted here: neither is
/// knowable before the request has read the inputs it would be comparing, so
/// both keep the slow path they have always taken.
pub fn sourceRevisionRefusal(before: fab_release.ProjectState) ?Refusal {
    switch (before.status) {
        .dirty, .unavailable => {},
        .clean, .changed, .ambiguous => return null,
    }
    return .{
        .status = before.status,
        .finding = fab_release.projectStatusFinding(before.status) orelse return null,
    };
}

/// The complete cheap decision for one fabrication-package request. Null means
/// "answer this the slow, authoritative way" — either because the source
/// revision does not settle it, or because the slower path owes this request a
/// 404 about its saved layouts that only that path can phrase.
pub fn refuseEarly(
    arena: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    layout_arg: ?[]const u8,
    before: fab_release.ProjectState,
) ?Refusal {
    const refusal = sourceRevisionRefusal(before) orelse return null;
    const sidecar = sidecar_store.readDesignDoc(arena, project_dir, name);
    const has_cache = sidecar_store.cachePoses(arena, sidecar.cache) != null;
    return switch (select(sidecar.layouts, has_cache, layout_arg)) {
        .row, .cache => refusal,
        .unknown_layout, .none_saved => null,
    };
}

/// Write the refusal body: the blocking finding, the source status it came
/// from, and an explicit statement that the rest of the report was not
/// computed — with the surface that does compute it. The keys a client already
/// reads off a blocked readiness response (`ok`, `errors`, `project_status`,
/// `release_token`, `internal_checks_complete`, `confirmation_required`) keep
/// their meaning and their values, so a caller that only branches on those
/// cannot tell the fast refusal from the slow one.
pub fn writeRefusalJson(
    writer: *std.Io.Writer,
    name: []const u8,
    refusal: Refusal,
) json_writer.WriteError!void {
    try writer.writeAll("{\"ok\":false,\"errors\":[{\"id\":");
    try json_writer.writeString(writer, refusal.finding.id);
    try writer.writeAll(",\"message\":");
    try json_writer.writeString(writer, refusal.finding.message);
    try writer.writeAll("}],\"warnings\":[],\"release_token\":null,\"project_status\":");
    try json_writer.writeString(writer, @tagName(refusal.status));
    try writer.writeAll(",\"internal_checks_complete\":false,\"confirmation_required\":true,\"report_complete\":false,\"report_url\":");
    var url: [256]u8 = undefined;
    const printed = std.fmt.bufPrint(&url, "/api/fab-readiness/{s}", .{name}) catch "/api/fab-readiness";
    try json_writer.writeString(writer, printed);
    try writer.writeAll(",\"message\":\"the fabrication package was refused on the project's source revision alone; the complete readiness report was not computed\"}");
}

// ── Composing an authorized package ────────────────────────────────────

/// The exact physical board a package is built from, in one shared frame.
pub const Board = struct {
    placement: optimizer.Placement,
    routed: router.RouteResult,
    texts: []const font.BoardText,
    copper: export_gerber.Copper,
    frame: export_fab.Frame,
};

/// The evidence members that travel with the CAM files.
pub const Evidence = struct {
    mark: fab_identity.Mark,
    evidence: fab_release.Evidence,
    lock: fab_release.Lock,
    needs_waiver: bool,
    dnp: export_fab.DnpMode,
    /// The standalone operator page, rendered by the caller because it needs
    /// the whole board-page renderer this module deliberately does not.
    assembly_html: []const u8,
};

pub const ComposeError = export_gerber.Error || std.mem.Allocator.Error || std.Io.Writer.Error;

/// Build every member of the fabrication archive. The package basename is
/// sanitized ONCE, here, and every member — the layer files, the job file's own
/// `Path` fields, the drills, the centroid and the download's filename — is
/// named from it. JLCPCB rejects an archive whose entry names carry certain
/// words, so a rejected design slug falls back to a neutral one
/// (`fab_filename.prefix`); doing that per call site is how a job file ends up
/// pointing at members the archive does not contain under that name.
pub fn compose(
    arena: std.mem.Allocator,
    name: []const u8,
    board: Board,
    parts: Evidence,
) ComposeError!export_fab.Package {
    const fab_texts = try fab_identity.replaceAdoptedText(arena, board.texts, parts.mark);
    var pkg = export_fab.Package{ .arena = arena, .prefix = fab_filename.prefix(name) };
    const layers = try export_gerber.planLayers(arena, board.placement);
    // ONE clock read for the whole package, so every layer in this ZIP carries
    // the same `%TF.CreationDate`. The writer itself stays deterministic (its
    // CLI/test path passes no stamp at all) — the same split the review PDF
    // uses for `/CreationDate`.
    const stamped = try export_gerber.creationDate(arena, clock.timestamp());
    for (layers) |f| {
        var aw: std.Io.Writer.Allocating = .init(arena);
        try export_gerber.writeLayer(&aw.writer, arena, board.placement, board.copper, fab_texts, board.frame, f.layer, .{ .function = f.function, .created = stamped });
        if (f.exact_name) try pkg.addNamed(f.suffix, aw.written()) else try pkg.add(f.suffix, aw.written());
    }
    // The Gerber Job File ties the package together (board size, layer count,
    // per-file FileFunction). Its Path fields match the entry names above.
    var jbw: std.Io.Writer.Allocating = .init(arena);
    try export_gerber.writeJobFile(&jbw.writer, board.placement, layers, pkg.prefix);
    try pkg.add(export_gerber.job_file_suffix, jbw.written());
    // The drill headers declare the span they drill through, which is the
    // same copper count the job file reports and the layer table generated.
    const copper_layers = board.placement.rules.layerStack().stackCount();
    var pth: std.Io.Writer.Allocating = .init(arena);
    try export_fab.excellonDrill(&pth.writer, arena, board.placement.parts, board.routed.vias, .{ .class = .plated, .copper_layers = copper_layers }, board.frame);
    try pkg.add(export_gerber.plated_drill_suffix, pth.written());
    var npth: std.Io.Writer.Allocating = .init(arena);
    try export_fab.excellonDrill(&npth.writer, arena, board.placement.parts, board.routed.vias, .{ .class = .non_plated, .copper_layers = copper_layers }, board.frame);
    try pkg.add(export_gerber.non_plated_drill_suffix, npth.written());
    var cw: std.Io.Writer.Allocating = .init(arena);
    try export_fab.centroidCsv(&cw.writer, board.placement.parts, board.placement.instances, board.frame, parts.dnp);
    try pkg.add("centroid.csv", cw.written());
    var bw: std.Io.Writer.Allocating = .init(arena);
    try export_fab.assemblyBomCsv(&bw.writer, board.placement.instances, parts.dnp);
    try pkg.add("bom.csv", bw.written());
    try pkg.add("assembly.html", parts.assembly_html);
    var displayed_id = parts.mark.short_hex;
    _ = std.ascii.upperString(&displayed_id, &parts.mark.short_hex);
    const manifest = try std.fmt.allocPrint(arena,
        \\Board part number: {s}
        \\PCB fabrication ID: {s}
        \\Full SHA-256: {s}
        \\Scope: deterministic Gerber and Excellon geometry plus board part number before the generated mark
        \\
    , .{ parts.mark.part_number, &displayed_id, &parts.mark.digest_hex });
    try pkg.add("fab-id.txt", manifest);
    var rrj: std.Io.Writer.Allocating = .init(arena);
    try fab_release.writeMachineReport(&rrj.writer, parts.evidence, parts.lock, parts.needs_waiver);
    try pkg.add("release-report.json", rrj.written());
    var rrm: std.Io.Writer.Allocating = .init(arena);
    try fab_release.writeHumanReport(&rrm.writer, parts.evidence, parts.lock, parts.needs_waiver);
    try pkg.add("release-report.md", rrm.written());
    var rules: std.Io.Writer.Allocating = .init(arena);
    try fab_release.writeRulesJson(&rules.writer, parts.evidence);
    try pkg.add("design-rules.json", rules.written());
    var checksums: std.Io.Writer.Allocating = .init(arena);
    try fab_release.writeChecksums(&checksums.writer, pkg.entries.items);
    try pkg.add("checksums.sha256", checksums.written());
    return pkg;
}

// ── Tests ──────────────────────────────────────────────────────────────

fn testRow(name: []const u8, default: bool, parts: []const sidecar_types.PartPose) SavedLayout {
    return .{ .name = name, .kind = kind_manual, .ts = 1, .score = null, .default = default, .parts = parts };
}

const one_part: []const sidecar_types.PartPose = &.{.{ .ref = "U1", .x = 1, .y = 2, .rot = 0 }};

// spec: fabrication-release - a fabrication package request whose project source revision already blocks the release is refused before the board is placed, checked or digested
test "a dirty or unrevisioned project is a provable refusal, a clean one is not" {
    const dirty = sourceRevisionRefusal(.{ .commit = "abc", .status = .dirty }) orelse return error.TestExpectedRefusal;
    try std.testing.expectEqualStrings("source-worktree-dirty", dirty.finding.id);
    try std.testing.expectEqual(fab_release.ProjectStatus.dirty, dirty.status);

    const unavailable = sourceRevisionRefusal(.{ .commit = "unavailable", .status = .unavailable }) orelse
        return error.TestExpectedRefusal;
    try std.testing.expectEqualStrings("source-revision-unavailable", unavailable.finding.id);

    // The two statuses that are only knowable after the request has read the
    // inputs it compares keep the authoritative slow path.
    try std.testing.expect(sourceRevisionRefusal(.{ .commit = "abc", .status = .clean }) == null);
    try std.testing.expect(sourceRevisionRefusal(.{ .commit = "abc", .status = .changed }) == null);
    try std.testing.expect(sourceRevisionRefusal(.{ .commit = "abc", .status = .ambiguous }) == null);
}

// spec: fabrication-release - the fast fabrication refusal cites the same source-revision finding as the full report and states that the rest of the report was not computed
test "the refusal body names the blocking finding and the report it did not compute" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const refusal = sourceRevisionRefusal(.{ .commit = "abc", .status = .dirty }) orelse return error.TestExpectedRefusal;
    var aw: std.Io.Writer.Allocating = .init(alloc);
    try writeRefusalJson(&aw.writer, "barracuda", refusal);
    const body = aw.written();

    // Parses, and every key a blocked readiness response is branched on keeps
    // its meaning: no token, not internally complete, still a 500-shaped no.
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, alloc, body, .{});
    try std.testing.expect(!parsed.object.get("ok").?.bool);
    try std.testing.expect(parsed.object.get("release_token").? == .null);
    try std.testing.expect(!parsed.object.get("internal_checks_complete").?.bool);
    try std.testing.expectEqualStrings("dirty", parsed.object.get("project_status").?.string);
    // The blocking reason is named with the SAME id/message the full report
    // would have used, not a paraphrase of it.
    const first = parsed.object.get("errors").?.array.items[0];
    try std.testing.expectEqualStrings("source-worktree-dirty", first.object.get("id").?.string);
    try std.testing.expectEqualStrings(
        fab_release.projectStatusFinding(.dirty).?.message,
        first.object.get("message").?.string,
    );
    // …and it is explicit that the rest of the report was skipped, naming the
    // surface that still computes it.
    try std.testing.expect(!parsed.object.get("report_complete").?.bool);
    try std.testing.expectEqualStrings("/api/fab-readiness/barracuda", parsed.object.get("report_url").?.string);
}

// spec: fabrication-release - the fast fabrication refusal declines every request the saved-layout selection still owes a 404
test "an early refusal never answers a request that is owed a saved-layout 404" {
    const rows: []const SavedLayout = &.{
        testRow("open", false, one_part),
        testRow("routed", true, one_part),
    };

    // ★ wins with no ?layout=; a named row is selected exactly.
    try std.testing.expectEqualStrings("routed", select(rows, false, null).row.name);
    try std.testing.expectEqualStrings("open", select(rows, false, "open").row.name);

    // The two selections that owe a 404 are refused a fast answer, whatever
    // the project state says — the slow path is the only one that can phrase
    // "no such layout" / "nothing saved" for this design.
    try std.testing.expect(select(rows, true, "nope") == .unknown_layout);
    try std.testing.expect(select(&.{}, false, null) == .none_saved);
    // …while a cache-only board still selects, because a release CAN be built
    // from the optimizer cache (and is then blocked on its own evidence).
    try std.testing.expect(select(&.{}, true, null) == .cache);

    // A row with no parts is not a row: naming it is still an unknown layout.
    const empty: []const SavedLayout = &.{testRow("bare", true, &.{})};
    try std.testing.expect(select(empty, false, "bare") == .unknown_layout);
    try std.testing.expect(select(empty, false, null) == .none_saved);
}
