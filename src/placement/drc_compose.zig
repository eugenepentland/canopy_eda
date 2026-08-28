//! Composing a board's full DRC verdict: the geometric rules, plus the
//! board-text overlap warnings, plus the `net_open` connectivity layer.
//!
//! This is the seam every reporting surface measures a board through, and
//! deliberately NOT `drc.check`: geometry alone says nothing about whether the
//! routed copper actually joins each net's pads, so a board whose copper left a
//! net in two islands reads as clean without the connectivity layer. (The
//! router's candidate loop and the client WASM engine still call `drc.check`
//! directly — the per-net pour raster must not run in a hot path.)
//!
//! It was declared in `serve/drc_rules.zig` next to the `<name>.drc-rules.json`
//! severity sidecar, so `kicad_pcb/route_command.zig` — which scores an
//! uploaded board and wants no server at all — had to import `serve/`. Every
//! input here is a placement type and nothing touches the filesystem or HTTP,
//! so the composition belongs beneath both. `drc_rules.zig` keeps the sidecar
//! half and re-exports `CopperCheck` / `checkDefaultRules`; its
//! `checkFilteredZones` is now visibly this composition plus the override pass.

const std = @import("std");
const drc = @import("drc.zig");
const drc_pour = @import("drc_pour.zig");
const drc_return_path = @import("drc_return_path.zig");
const drc_scope = @import("drc_scope.zig");
const fill_cache = @import("fill_cache.zig");
const bypass_open = @import("bypass_open.zig");
const net_open = @import("net_open.zig");
const optimizer = @import("optimizer.zig");
const router = @import("router.zig");
const pour = @import("pour.zig");
const path_copper = @import("path_copper.zig");
const font = @import("../font5x7.zig");
const silk_font = @import("../silk_font.zig");

/// The copper context one connectivity/geometry DRC pass measures: the
/// placement, the routed copper, the clearance rule, and any hand-drawn user
/// copper pours to credit toward connectivity.
pub const CopperCheck = struct {
    placement: optimizer.Placement,
    routed: router.RouteResult,
    clearance: f64,
    zones: []const pour.UserZone = &.{},
    /// The caller's shared board-edge margin field, when the whole render
    /// pours the same board and seeded it once (see `pour.sharedEdgeField`).
    /// Every fill below — the topology zones and the net-open connectivity —
    /// reads it, so the outline walk is not repeated per pass. Null seeds
    /// per call, exactly as before.
    base_edge: ?pour.EdgeField = null,
    /// Saved board-level silkscreen labels shown with this copper. Empty for
    /// route-only/internal checks that have no layout text context.
    texts: []const font.BoardText = &.{},
};

/// `checkFilteredZones` for copper that belongs to NO project design: an
/// uploaded `.kicad_pcb` on the route-review endpoint, or a board the
/// `route-kicad-reference` CLI is scoring. There is no `<name>.drc-rules.json`
/// to load for a foreign board, so the built-in severities stand — but the
/// `net_open` connectivity layer must still be there, or the report claims a
/// board whose copper leaves islands is DRC-clean. Identical to
/// `checkFilteredZones` against a design with no rule sidecar, minus the
/// pointless filesystem probe.
pub fn checkDefaultRules(alloc: std.mem.Allocator, in: CopperCheck) []const drc.Violation {
    return checkDefaultRulesReport(alloc, in).violations;
}

/// Full DRC result plus the connectivity statuses already built by the
/// net-open layer. Reporting endpoints that also show routed/total consume the
/// statuses instead of repeating the board's per-net plane rasters and unions.
pub const CheckReport = struct {
    violations: []const drc.Violation,
    net_report: net_open.Report,
    /// False when a fill/topology/connectivity stage failed and the ordinary
    /// interactive surface therefore received only a best-effort partial
    /// report.  Fab export consumes this bit and fails closed.
    complete: bool = true,
};

const ViolationStage = struct {
    violations: []const drc.Violation,
    complete: bool,
};

/// Compose all DRC layers while retaining the net-open layer's reusable
/// connectivity report for a caller that also needs a routed tally.
pub fn checkDefaultRulesReport(alloc: std.mem.Allocator, in: CopperCheck) CheckReport {
    // ONE borrow spans every layer below, because the connectivity layer reads
    // the same fill the topology rules judged. It is released on the way out —
    // every violation, status and string this returns is built from the
    // placement, never from the fill (see `fill_cache`'s header).
    var board = boardFills(alloc, in);
    defer board.release();
    const geom = filledViolationsReport(alloc, in, board);
    const silk = withBoardTextReport(alloc, in.placement, geom, in.texts);
    const bypass = withBypassOpenReport(alloc, in.placement, in.routed, silk);
    return withNetOpenReport(alloc, in, bypass, board);
}

/// Everything one accepted board state leaves behind so the NEXT recheck can be
/// scoped: the fills it poured, the specs they came from, the pour audit's
/// evidence, and the findings of the kinds a scoped pass defers.
///
/// It is a snapshot of INPUTS and VERDICTS, never of geometry the caller owns:
/// the `pour.Fill` values point into the memo's retained nodes, which stay alive
/// for exactly as long as the caller holds the borrow this came back with.
pub const Prior = struct {
    /// The memo key of each fill, in the order the board builds them. This is
    /// what a scoped pass hands back to the memo to get the SAME raster with a
    /// proper reference — retaining the `pour.Fill` value instead would be
    /// reading a borrow nothing is holding.
    fill_keys: []const FillKey = &.{},
    /// One content digest per fill, in the same order. The specs themselves are
    /// full of slices into the request arena that built them, so what a session
    /// retains is the digest: enough to prove the board still asks for the same
    /// fill in the same slot, and nothing that can dangle.
    spec_keys: []const u64 = &.{},
    pour_audit: drc_pour.Audited = .{},
    /// The last FULL pass's `reference_plane_gap` / `reference_transition` /
    /// `loop_area` findings, carried through every scoped pass in between.
    deferred: []const drc.Violation = &.{},
};

/// One scoped recheck's answer, plus the state the next one measures against.
pub const ScopedReport = struct {
    violations: []const drc.Violation = &.{},
    net_report: net_open.Report = .{ .violations = &.{}, .connectivity = &.{} },
    complete: bool = true,
    /// What to hand back as `Prior` next time.
    prior: Prior = .{},
    /// The fill borrow this pass's rasters live in. The caller must hold it for
    /// as long as it intends to reuse `prior.fills`, and release it when it
    /// replaces or drops that snapshot.
    held: fill_cache.Held = .{},
    /// False when the scoped path could not be taken and nothing was computed —
    /// the caller falls back to the full check.
    scoped: bool = true,
    /// How much of the board this pass had to re-key and re-pour.
    reuse: FillReuse = .{},
};

/// What a pass did to the board's fills. Reported for the same reason
/// `fill_cache` counts its hits: a scoping predicate that quietly stops
/// excluding anything looks exactly like one that works, and the only
/// difference between them is a number.
pub const FillReuse = struct {
    fills: usize = 0,
    repoured: usize = 0,
};

/// The kinds a scoped recheck does not recompute. They are carried forward from
/// the last full pass, and refreshed the next time one runs.
pub fn isDeferredKind(kind: drc.Kind) bool {
    return switch (kind) {
        .reference_plane_gap, .reference_transition, .loop_area => true,
        else => false,
    };
}

/// Split a full pass's findings into the deferred kinds, so a session can carry
/// them across the scoped passes that follow.
pub fn deferredOf(alloc: std.mem.Allocator, list: []const drc.Violation) []const drc.Violation {
    var out: std.ArrayList(drc.Violation) = .empty;
    for (list) |v| {
        if (!isDeferredKind(v.kind)) continue;
        out.append(alloc, v) catch return out.items;
    }
    return out.items;
}

/// Re-check a board that differs from `prior`'s board by `delta` alone.
///
/// The claim this must hold — and that `drc-dump --scoped` exists to test on
/// real boards — is that the result equals a full `checkDefaultRulesReport` of
/// the same state for every kind except the three deferred ones. It gets there
/// not by dropping findings but by reusing per-piece work whose inputs the edit
/// provably did not reach: the rasters the edit cannot have moved, and the pour
/// verdicts derived from them.
///
/// Everything else runs in full. The clearance sweep, the copper-topology
/// graph, the connectivity layer and the bypass check are all cheap once the
/// fills are in hand — tens of milliseconds against the seconds the rasters and
/// the ring geometry cost — and a scoped spelling of a whole-board graph is
/// complexity that would buy little and could be wrong.
pub fn checkScopedReport(
    alloc: std.mem.Allocator,
    in: CopperCheck,
    prior: Prior,
    delta: drc_scope.Delta,
) ScopedReport {
    var board = boardFillsScoped(alloc, in, .{
        .keys = prior.fill_keys,
        .spec_keys = prior.spec_keys,
        .tracks = delta.tracks,
        .vias = delta.vias,
    });
    if (board.failed) {
        board.release();
        return .{ .scoped = false };
    }
    const changed_feature = featureKeys(alloc, delta) catch {
        board.release();
        return .{ .scoped = false };
    };
    const filled = filledViolationsScoped(alloc, in, board, .{
        .changed_fill = board.changed,
        .changed_feature = changed_feature,
        .prior = prior.pour_audit,
    });
    const silk = withBoardTextReport(alloc, in.placement, filled.stage, in.texts);
    const bypass = withBypassOpenReport(alloc, in.placement, in.routed, silk);
    const report = withNetOpenReport(alloc, in, bypass, board);
    var all: std.ArrayList(drc.Violation) = .empty;
    all.appendSlice(alloc, report.violations) catch {
        board.release();
        return .{ .scoped = false };
    };
    // The three deferred kinds ride through untouched. They were produced by
    // the last full pass over this design and are refreshed by the next one.
    all.appendSlice(alloc, prior.deferred) catch {
        board.release();
        return .{ .scoped = false };
    };
    return .{
        .violations = all.items,
        .net_report = report.net_report,
        .complete = report.complete,
        .prior = .{
            .fill_keys = board.fill_keys,
            .spec_keys = board.spec_keys,
            .pour_audit = filled.audited,
            .deferred = prior.deferred,
        },
        .held = board.held,
        .reuse = .{ .fills = board.changed.len, .repoured = countChanged(board.changed) },
    };
}

fn countChanged(flags: []const bool) usize {
    var n: usize = 0;
    for (flags) |flag| n += @intFromBool(flag);
    return n;
}

/// The content keys of every feature the edit touched, in the form the pour
/// audit compares against.
fn featureKeys(alloc: std.mem.Allocator, delta: drc_scope.Delta) std.mem.Allocator.Error![]const u64 {
    const out = try alloc.alloc(u64, delta.tracks.len + delta.vias.len);
    for (delta.tracks, out[0..delta.tracks.len]) |t, *k| k.* = drc_scope.trackKey(t);
    for (delta.vias, out[delta.tracks.len..]) |v, *k| k.* = drc_scope.viaKey(v);
    return out;
}

/// A FULL pass that also records what a following scoped pass needs. Identical
/// findings to `checkDefaultRulesReport`; it simply keeps the evidence instead
/// of dropping it on the way out.
pub fn checkPrimingReport(alloc: std.mem.Allocator, in: CopperCheck) ScopedReport {
    var board = boardFillsScoped(alloc, in, .{});
    if (board.failed) {
        board.release();
        return .{ .scoped = false };
    }
    const filled = filledViolationsScoped(alloc, in, board, null);
    const silk = withBoardTextReport(alloc, in.placement, filled.stage, in.texts);
    const bypass = withBypassOpenReport(alloc, in.placement, in.routed, silk);
    const report = withNetOpenReport(alloc, in, bypass, board);
    return .{
        .violations = report.violations,
        .net_report = report.net_report,
        .complete = report.complete,
        .prior = .{
            .fill_keys = board.fill_keys,
            .spec_keys = board.spec_keys,
            .pour_audit = filled.audited,
            .deferred = deferredOf(alloc, report.violations),
        },
        .held = board.held,
        .reuse = .{ .fills = board.changed.len, .repoured = countChanged(board.changed) },
    };
}

/// GEOMETRY-only DRC over a saved board, memoised.
///
/// `drc.check` is a clearance sweep with one exception: the power-width rule
/// asks whether a declared rail's branch is fed by a plane, and answers by
/// rastering every declared plane and pour of the board. `drc.check` passes no
/// prepared copper, so a caller whose placement carries the design's `(i-typ …)`
/// rail demands paid that raster in full on every call — 7.5 s of
/// barracuda-base's 8.2 s geometry pass — and the boards a SERVER checks are
/// saved boards it re-checks over and over.
///
/// This is that same check with the process fill memo wired in. The findings are
/// identical: a memoised fill is bit-identical to a poured one, and every other
/// rule is untouched. It lives here, not in `drc.zig`, because `drc.zig` is
/// compiled into the client's wasm engine, which has no store — nothing in the
/// wasm target reaches `fill_cache` through this seam. Nor does it need to:
/// `wasm_drc.zig` marshals no rail demand, so the raster this memo exists to
/// amortise is unreachable there (that file's own test pins it).
///
/// The router's candidate loop deliberately keeps calling `drc.check`: it
/// mutates the copper those surfaces depend on between calls, so it would only
/// ever miss and pay the keys for nothing.
pub fn checkGeometry(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    routed: router.RouteResult,
    clearance: f64,
) std.mem.Allocator.Error![]drc.Violation {
    const session = fill_cache.beginSession() orelse
        return drc.check(alloc, placement, routed, clearance);
    // Released on the way out: the widths this produces are plain numbers and
    // no violation points into a fill (`fill_cache`'s borrow rule).
    defer session.release();
    return drc.checkMemoised(alloc, placement, routed, clearance, session.memo());
}

/// What the process-wide copper-fill memo has done and is holding. Re-exported
/// here rather than reached for directly, so the reporting layers above have one
/// door into the memo — the same door their fills come through.
pub const fillMemoStats = fill_cache.stats;

/// A live borrow of the rasters one retained board state is made of. The serve
/// layer holds one per open editor session and releases it when the session's
/// board state is replaced or dropped; it reaches it through here (and through
/// `drc_rules`) rather than through `fill_cache`, which is the memo's own
/// business and not the server's.
pub const FillHold = fill_cache.Held;

/// The board-edge margin field every fill of one board starts from, and the
/// walk that seeds it. A reconcile session that holds a placement across edits
/// seeds it ONCE: it is a function of the outline and the lattice alone, so
/// re-walking a three-million-cell raster per recheck was pure repetition.
pub const EdgeField = pour.EdgeField;
pub const sharedEdgeField = pour.sharedEdgeField;

/// The copper edit one scoped recheck is scoped by, and how to derive it from
/// two board states. Re-exported so the serve layer names one door into the
/// scoping machinery instead of reaching past this seam into `drc_scope`.
/// One pour audit's evidence, and what each of its findings was derived from.
/// A reconcile session retains these so the next scoped pass can carry forward
/// the findings its edit could not have moved.
pub const PourAudit = drc_pour.Audited;
pub const PourOwner = drc_pour.Owner;

pub const Delta = drc_scope.Delta;
pub const diffCopper = drc_scope.diffCopper;

/// Run only copper-topology findings against the fabricated fill components.
/// Persisted cleanup uses this to obtain the exact same jointly-safe removal
/// plan as full DRC without paying for unrelated geometry findings each round.
pub fn checkTopologyFilled(alloc: std.mem.Allocator, in: CopperCheck) []const drc.Violation {
    var board = boardFills(alloc, in);
    defer board.release();
    if (board.failed) return &.{};
    return drc.checkTopology(alloc, in.placement, in.routed, board.fills.zones) catch &.{};
}

/// Append exact-target bypass connectivity warnings. This stays beside the
/// net-open layer, outside `drc.check`, so router candidates and client WASM do
/// not rebuild a surface graph for every tentative edit.
fn withBypassOpenReport(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    r: router.RouteResult,
    base: ViolationStage,
) ViolationStage {
    const warnings = bypass_open.check(alloc, placement, r.tracks) catch return .{ .violations = base.violations, .complete = false };
    if (warnings.len == 0) return base;
    var all: std.ArrayList(drc.Violation) = .empty;
    all.appendSlice(alloc, base.violations) catch return .{ .violations = base.violations, .complete = false };
    all.appendSlice(alloc, warnings) catch return .{ .violations = base.violations, .complete = false };
    return .{ .violations = all.items, .complete = base.complete };
}

fn textBox(t: font.BoardText) [4]f64 {
    const width = silk_font.widthMm(t.text, t.size);
    const height = silk_font.heightMm(t.size);
    const radians = t.rot * std.math.pi / 180;
    const cs = @abs(@cos(radians));
    const sn = @abs(@sin(radians));
    const hw = (width * cs + height * sn) / 2;
    const hh = (width * sn + height * cs) / 2;
    return .{ t.x - hw, t.y - hh, t.x + hw, t.y + hh };
}

fn boxOverlap(a: [4]f64, b: optimizer.BoardRect) ?[2]f64 {
    const x0 = @max(a[0], b.minx);
    const y0 = @max(a[1], b.miny);
    const x1 = @min(a[2], b.minx + b.w);
    const y1 = @min(a[3], b.miny + b.h);
    if (!(x1 > x0 + 1e-9 and y1 > y0 + 1e-9)) return null;
    return .{ (x0 + x1) / 2, (y0 + y1) / 2 };
}

/// Add one warning for each board-level silk label whose printed bounding box
/// crosses a same-side component courtyard. Footprint-owned silk already has
/// the exact pad-opening check in `drc.zig`; this covers the layout Text tool.
fn withBoardTextReport(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    base: ViolationStage,
    texts: []const font.BoardText,
) ViolationStage {
    if (texts.len == 0) return base;
    var out: std.ArrayList(drc.Violation) = .empty;
    out.appendSlice(alloc, base.violations) catch return .{ .violations = base.violations, .complete = false };
    for (texts) |t| {
        if (t.text.len == 0 or !(t.size > 0)) continue;
        const tb = textBox(t);
        for (placement.parts, 0..) |part, i| {
            if (t.bottom != (part.side == .bottom)) continue;
            const hit = boxOverlap(tb, optimizer.worldCourtyard(&part)) orelse continue;
            out.append(alloc, .{
                .x = hit[0],
                .y = hit[1],
                .gap = 0,
                .clearance = 0,
                .kind = .silk_over_pad,
                .severity = drc.defaultSeverity(.silk_over_pad),
                .who = .{ .part_a = drc.partyIndex(i) },
            }) catch return .{ .violations = base.violations, .complete = false };
        }
    }
    return .{ .violations = out.items, .complete = base.complete };
}

/// The FULL geometry + copper-topology check against the fabricated fill — the
/// twin of `checkTopologyFilled`, for a caller that must judge copper the same
/// way the fill does AND still see every clearance rule.
///
/// `drc.check` is the same rules with NO fill, and the difference is not
/// cosmetic: the topology rules credit a same-net pour as copper, so a trace
/// that ends on its own rail's pour is a finished run here and an unattached
/// `copper_stub` — an ERROR — to the zone-blind spelling. A caller that pours a
/// rail and then judges its copper without the pour is contradicting itself.
pub fn checkFilled(alloc: std.mem.Allocator, in: CopperCheck) []const drc.Violation {
    var board = boardFills(alloc, in);
    defer board.release();
    return filledViolationsReport(alloc, in, board).violations;
}

/// The geometry rules plus the return-path rule, judged against `board`'s fill.
/// A board whose fill could not be built degrades to the ZONE-BLIND rules
/// rather than to an EMPTY fill: an empty fill is not "no pours", it is "every
/// pour vanished", and it would report every trace that terminates on its own
/// rail's copper as an unattached stub.
fn filledViolationsReport(alloc: std.mem.Allocator, in: CopperCheck, board: BoardFills) ViolationStage {
    return filledViolationsScoped(alloc, in, board, null).stage;
}

/// `filledViolationsReport`, optionally scoped by a copper edit.
///
/// With `scope` null this is the full pass. With one, the pour audit re-judges
/// only what the edit could have moved (`drc_pour.checkAudited`) and the
/// return-path rules do not run at all: `reference_plane_gap`,
/// `reference_transition` and `loop_area` are the three kinds a scoped recheck
/// DEFERS. They read the fabricated reference plane under a whole net's run —
/// a per-net judgement with no local answer — and the caller carries their
/// previous findings forward until a full pass refreshes them.
fn filledViolationsScoped(
    alloc: std.mem.Allocator,
    in: CopperCheck,
    board: BoardFills,
    scope: ?drc_pour.Scope,
) FilledStage {
    if (board.failed) {
        const fallback = drc.check(alloc, in.placement, in.routed, in.clearance) catch &.{};
        return .{ .stage = .{ .violations = fallback, .complete = false } };
    }
    const zones = board.fills.zones;
    const prepared = drc.PreparedCopper{
        .topology_zones = zones,
        .plane_fills = board.fills.plane_fills,
        .zones = in.zones,
        .zone_fills = board.fills.zone_fills,
    };
    const base = drc.checkWithPreparedCopper(
        alloc,
        in.placement,
        in.routed,
        in.clearance,
        prepared,
    ) catch return .{ .stage = .{ .violations = &.{}, .complete = false } };
    var out: std.ArrayList(drc.Violation) = .empty;
    out.appendSlice(alloc, base) catch return .{ .stage = .{ .violations = base, .complete = false } };
    const audited = drc_pour.checkAudited(alloc, in.placement, in.routed, prepared, scope) catch
        return .{ .stage = .{ .violations = base, .complete = false } };
    out.appendSlice(alloc, audited.violations) catch return .{ .stage = .{ .violations = base, .complete = false } };
    if (scope == null)
        drc_return_path.check(alloc, &out, in.placement, in.routed, zones) catch
            return .{ .stage = .{ .violations = base, .complete = false } };
    return .{ .stage = .{ .violations = out.items, .complete = true }, .audited = audited };
}

const FilledStage = struct {
    stage: ViolationStage,
    audited: drc_pour.Audited = .{},
};

/// This board's reduced fill for one DRC pass: either borrowed from the memo or
/// freshly poured into the caller's arena. `release` ends a borrow.
const BoardFills = struct {
    fills: fill_cache.Fills = .{},
    held: fill_cache.Held = .{},
    /// The fill could not be built at all (allocation failure). Distinguished
    /// from an empty fill, which is a legitimate answer for a board with no
    /// planes, pours or zones — see `filledViolations`.
    failed: bool = false,
    /// Every fill of this board in ONE list, planes first (net major, carrying
    /// layer minor) then the user zones in posted order, with the spec each was
    /// poured from and whether this pass had to pour it. Empty for the ordinary
    /// whole-board path, which asks no scoped question.
    fill_keys: []const FillKey = &.{},
    spec_keys: []const u64 = &.{},
    changed: []const bool = &.{},

    fn release(self: *BoardFills) void {
        self.held.release();
    }
};

/// The board's fill, memoised on the board's own bytes AND on each fill's own.
/// A whole-board hit skips even the per-fill keys; a miss pours only the fills
/// whose own inputs changed and borrows the rest from the board states already
/// retained, then publishes this board state for the next surface to ask about
/// (`fill_cache`).
fn boardFills(alloc: std.mem.Allocator, in: CopperCheck) BoardFills {
    const key = fill_cache.key(in.placement, in.routed, in.zones);
    var held = fill_cache.acquire(key);
    if (held.entry != null) return .{ .fills = held.fills(), .held = held };
    const session = fill_cache.beginSession() orelse {
        // No memo at all this pass: pour it exactly as an unmemoised caller
        // would. A memo failure is never a DRC failure.
        const alone = filledTopology(alloc, in, null, null) catch return .{ .failed = true };
        return .{ .fills = alone.fills };
    };
    const fresh = filledTopology(alloc, in, session.memo(), null) catch {
        session.release();
        return .{ .failed = true };
    };
    fill_cache.put(key, fresh.fills, session);
    // The session, not the entry, is what keeps this pass's rasters alive: the
    // board entry may have been declined, and either way the fills below point
    // into the retained nodes the session borrowed.
    return .{ .fills = fresh.fills, .held = .{ .session = session, .own = fresh.fills } };
}

/// This board's fills with the PREVIOUS board's offered for reuse.
///
/// The whole-board key is deliberately not consulted: a scoped pass reaches
/// here because copper changed, so that key has already moved, and asking costs
/// a hash of every track and via to be told so. The per-fill answer is the one
/// that matters, and `Reuse` gets it without keying the fills the edit could not
/// reach at all.
fn boardFillsScoped(alloc: std.mem.Allocator, in: CopperCheck, reuse: Reuse) BoardFills {
    const session = fill_cache.beginSession() orelse {
        const alone = filledTopology(alloc, in, null, reuse) catch return .{ .failed = true };
        return .{ .fills = alone.fills, .fill_keys = alone.fill_keys, .spec_keys = alone.spec_keys, .changed = alone.changed };
    };
    const fresh = filledTopology(alloc, in, session.memo(), reuse) catch {
        session.release();
        return .{ .failed = true };
    };
    // Publish the board state anyway: the page blob, the derived payload and
    // `describe` all trail the editor by an edit and ask for this exact board.
    fill_cache.put(fill_cache.key(in.placement, in.routed, in.zones), fresh.fills, session);
    return .{
        .fills = fresh.fills,
        .held = .{ .session = session, .own = fresh.fills },
        .fill_keys = fresh.fill_keys,
        .spec_keys = fresh.spec_keys,
        .changed = fresh.changed,
    };
}

/// Reduce every declared plane/pour and hand-authored zone to the exact kept
/// fill components the Gerber uses. The DRC topology graph receives one node
/// per component (and its holes), never one outline-wide conductor.
///
/// This is the expensive half of the reporting seam — one raster per net per
/// carrying layer plus one per user zone — so `boardFills` memoises its result
/// and this runs only for a board no surface has poured yet.
fn filledTopology(alloc: std.mem.Allocator, in: CopperCheck, memo: ?pour.FillMemo, reuse: ?Reuse) std.mem.Allocator.Error!Topology {
    var out: std.ArrayList(drc.TopologyZone) = .empty;
    var plane_fills: std.ArrayList(pour.NetFills) = .empty;
    var component: u64 = 1;
    // Keep the compact route plus its geometry proof intact here. Gerber
    // passes this exact spelling to `computeShared`: the pour engine suppresses
    // RF-owned handles/native arcs itself and carves the finished swept path.
    // Pre-lowering to max-width capsules would make reporting DRC retain a
    // different (over-cleared) fill from the one actually fabricated.
    const copper = pour.Copper{
        .tracks = in.routed.tracks,
        .vias = in.routed.vias,
        .arcs = in.routed.arcs,
        .rf_paths = in.routed.rf_port_outcomes,
        .zones = in.zones,
    };
    // Every plane, pour and zone below rasters the SAME board on the SAME
    // lattice, so the outline walk that seeds each cell's edge margin is done
    // once here and copied per fill. `base_edge` is the whole render's field
    // when the caller seeded it; otherwise we seed our own.
    const base = if (in.base_edge) |b| b else try pour.sharedEdgeField(alloc, in.placement);
    var builder = Builder{ .alloc = alloc, .placement = in.placement, .copper = copper, .base = base, .memo = memo, .reuse = reuse };
    for (in.placement.nets) |net| {
        const layers = try pour.carryingLayers(alloc, in.placement.rules, net.name);
        if (layers.len == 0) continue;
        const prepared_layers = try alloc.alloc(pour.LayerSpec, layers.len);
        const fills = try alloc.alloc(pour.Fill, layers.len);
        for (layers, 0..) |layer, fill_i| {
            var spec = layer;
            if (spec.track_layer) |track_layer|
                spec.higher = try pour.higherThanDeclared(alloc, in.zones, track_layer, spec.net);
            const fill = try builder.take(spec);
            prepared_layers[fill_i] = spec;
            fills[fill_i] = fill;
            for (fill.contours, 0..) |contour, contour_i| {
                try out.append(alloc, .{
                    .net = net.name,
                    .layer = spec.track_layer orelse 0,
                    .stack = spec.stack,
                    .poly = contour,
                    .holes = fill.holes[contour_i],
                    .component = component,
                    .plane = spec.track_layer == null,
                });
                component += 1;
            }
        }
        try plane_fills.append(alloc, .{ .net_name = net.name, .layers = prepared_layers, .fills = fills });
    }
    // The connectivity layer's own whole-board raster is the SAME raster: one
    // user zone has one spec, so the topology pass's fill of it and
    // `net_open.zoneFills`' fill of it share a content key and were already one
    // memo entry. Building it once here retires the second key pass outright —
    // twenty-odd zones' worth of digesting obstacle walk on a barracuda-class
    // board that only ever confirmed what this loop had just poured.
    const zone_fills = try alloc.alloc(pour.Fill, in.zones.len);
    for (in.zones, 0..) |zone, zone_i| {
        var spec = pour.zoneLayerSpec(zone.net, pour.sideOfSignal(zone.layer), zone.layer, zone.poly);
        spec.higher = try pour.higherPolys(alloc, in.zones, zone_i);
        const fill = try builder.take(spec);
        zone_fills[zone_i] = fill;
        for (fill.contours, 0..) |contour, contour_i| {
            try out.append(alloc, .{
                .net = zone.net,
                .layer = zone.layer,
                .poly = contour,
                .holes = fill.holes[contour_i],
                .component = component,
            });
            component += 1;
        }
    }
    return .{
        .fills = .{
            .zones = try out.toOwnedSlice(alloc),
            .plane_fills = try plane_fills.toOwnedSlice(alloc),
            .zone_fills = zone_fills,
        },
        .fill_keys = builder.fill_keys.items,
        .spec_keys = builder.spec_keys.items,
        .changed = builder.changed.items,
    };
}

/// One board's fills plus the per-fill bookkeeping a scoped recheck needs.
const Topology = struct {
    fills: fill_cache.Fills,
    fill_keys: []const FillKey,
    spec_keys: []const u64,
    changed: []const bool,
};

/// The previous board state's fills, offered to this pass so the ones the edit
/// could not have reached are taken as they are instead of re-keyed.
pub const Reuse = struct {
    keys: []const FillKey = &.{},
    spec_keys: []const u64 = &.{},
    /// The copper the edit added or removed, both sides.
    tracks: []const router.Track = &.{},
    vias: []const router.Via = &.{},
};

/// The content key one memoised fill is stored under.
pub const FillKey = @import("content_key.zig").Key;

/// Walks the board's fills in order, taking each either from `reuse` or from
/// the pour, and recording which it was.
const Builder = struct {
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    copper: pour.Copper,
    base: ?pour.EdgeField,
    memo: ?pour.FillMemo,
    reuse: ?Reuse,
    fill_keys: std.ArrayList(FillKey) = .empty,
    spec_keys: std.ArrayList(u64) = .empty,
    changed: std.ArrayList(bool) = .empty,

    fn take(self: *Builder, spec: pour.LayerSpec) std.mem.Allocator.Error!pour.Fill {
        const index = self.spec_keys.items.len;
        const digest = specDigest(spec);
        try self.spec_keys.append(self.alloc, digest);
        if (self.borrow(index, digest, spec)) |kept| {
            try self.changed.append(self.alloc, false);
            try self.fill_keys.append(self.alloc, self.reuse.?.keys[index]);
            return kept;
        }
        const keyed = try pour.computeMemoKeyed(self.alloc, self.placement, self.copper, spec, self.base, self.memo);
        try self.changed.append(self.alloc, true);
        try self.fill_keys.append(self.alloc, keyed.key);
        return keyed.fill;
    }

    /// The prior raster for this slot, when the board still asks for the same
    /// fill in the same place, the edit provably cannot have moved it, and the
    /// memo still holds it.
    ///
    /// The last of those is why this goes through the memo rather than through
    /// a retained value: the answer comes back with a REFERENCE this pass owns.
    /// A miss (the entry was evicted) simply falls through to the pour, which is
    /// the "cache loss changes latency, never findings" rule this whole seam is
    /// built on.
    fn borrow(self: Builder, index: usize, digest: u64, spec: pour.LayerSpec) ?pour.Fill {
        const r = self.reuse orelse return null;
        const memo = self.memo orelse return null;
        if (index >= r.keys.len or index >= r.spec_keys.len) return null;
        if (r.spec_keys[index] != digest) return null;
        if (!pour.fillKeyStable(self.placement, spec, r.tracks, r.vias)) return null;
        return memo.get(memo.ctx, r.keys[index]);
    }
};

/// A fill spec reduced to one 64-bit content digest.
///
/// A scoped recheck runs over an UNCHANGED placement and an unchanged zone list,
/// so the spec walk reproduces its predecessor exactly and this only has to
/// notice when it did not — a design reloaded under the session, a zone list
/// that shifted, a plane that changed layers. Everything the raster reads about
/// the spec's IDENTITY is folded in; the clip and priority polygons go in by
/// their points, so a moved zone boundary is a different fill and falls back to
/// a pour rather than borrowing the old one.
fn specDigest(spec: pour.LayerSpec) u64 {
    var h = std.hash.Wyhash.init(0x73706563); // "spec"
    switch (spec.net) {
        .ground => h.update("\x00ground"),
        .named => |name| {
            h.update("\x01");
            h.update(name);
        },
    }
    h.update(std.mem.asBytes(&spec.stack));
    h.update(std.mem.asBytes(&spec.keep_unseeded));
    const layer: u16 = if (spec.track_layer) |l| l else 0x100;
    h.update(std.mem.asBytes(&layer));
    const side: u8 = if (spec.side) |sd| (if (sd == .top) 1 else 2) else 0;
    h.update(std.mem.asBytes(&side));
    hashPoly(&h, spec.clip);
    for (spec.higher) |poly| hashPoly(&h, poly);
    return h.final();
}

fn hashPoly(h: *std.hash.Wyhash, poly: []const [2]f64) void {
    h.update(std.mem.asBytes(&poly.len));
    for (poly) |p| for (p) |v| h.update(std.mem.asBytes(&v));
}

/// Append the net-open connectivity violations to the geometric ones. Fail-open:
/// on any allocation failure the geometric list rides through unchanged (a
/// partial DRC beats none).
fn withNetOpenReport(
    alloc: std.mem.Allocator,
    in: CopperCheck,
    geom: ViolationStage,
    board: BoardFills,
) CheckReport {
    const empty: net_open.Report = .{ .violations = &.{}, .connectivity = &.{} };
    const tracks = connectivityTracks(alloc, in.routed) catch return .{ .violations = geom.violations, .net_report = empty, .complete = false };
    const arcs = path_copper.filterArcs(alloc, in.routed.rf_port_outcomes, in.routed.arcs) catch
        return .{ .violations = geom.violations, .net_report = empty, .complete = false };
    const prepared: net_open.Prepared = .{
        .base = in.base_edge,
        .plane_fills = board.fills.plane_fills,
        // A board whose fill could not be built has no PREPARED zone rasters —
        // which is not the same fact as a board that rasters to none, so the
        // failed pass asks for its own rather than claiming there are no zones.
        .zone_fills = if (board.failed) null else board.fills.zone_fills,
    };
    const report = net_open.checkWithConnectivity(alloc, in.placement, .{ .tracks = tracks, .vias = in.routed.vias, .arcs = arcs, .zones = in.zones }, prepared) catch
        return .{ .violations = geom.violations, .net_report = empty, .complete = false };
    const connectivity_complete = !board.failed and report.connectivity.len == in.placement.nets.len;
    if (report.violations.len == 0) return .{ .violations = geom.violations, .net_report = report, .complete = geom.complete and connectivity_complete };
    var all: std.ArrayList(drc.Violation) = .empty;
    all.appendSlice(alloc, geom.violations) catch return .{ .violations = geom.violations, .net_report = report, .complete = false };
    all.appendSlice(alloc, report.violations) catch return .{ .violations = geom.violations, .net_report = report, .complete = false };
    return .{ .violations = all.items, .net_report = report, .complete = geom.complete and connectivity_complete };
}

/// A persisted RF path intentionally omits its solver chords: the compact
/// sample chain is the copper authority rendered and fabricated as one swept
/// polygon. Reconstruct those chords only for connectivity when no ordinary
/// track remains on that net. Geometry DRC keeps the polygon proof instead of
/// reclassifying its implementation samples as editable track segments.
fn connectivityTracks(alloc: std.mem.Allocator, r: router.RouteResult) std.mem.Allocator.Error![]const router.Track {
    return path_copper.tracks(alloc, r);
}

fn exactFillKeepsCopperLoweringRemoves(exact: pour.Fill, lowered: pour.Fill) bool {
    var y: f64 = 4.0;
    while (y <= 6.0) : (y += 0.05) {
        var x: f64 = 2.0;
        while (x <= 4.0) : (x += 0.05) {
            if (exact.componentAt(x, y) >= 0 and lowered.componentAt(x, y) < 0) return true;
        }
    }
    return false;
}

// ── Tests ─────────────────────────────────────────────────────────────────

// spec: placement/fill-cache - a second reporting DRC over an unchanged board reuses the retained fill instead of re-pouring it and returns the identical verdict
test "a memoised board fill returns the verdict the pour that built it returned" {
    const testing = std.testing;
    const geometry = @import("geometry.zig");
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const alloc = arena_inst.allocator();
    // Two GND pads under one hand-drawn GND pour: the pour is what joins them,
    // so a verdict taken against a wrong or missing fill would differ loudly.
    const pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads, .fallback = false, .x = 1, .y = 1 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads, .fallback = false, .x = 4, .y = 1 },
    };
    const pins = [_]@import("../flat_netlist.zig").FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } };
    const nets = [_]optimizer.FlatNet{.{ .name = "GND", .pins = &pins }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 5,
        .maxy = 2,
        .generated = true,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 5, .h = 2 },
    };
    const drawn = [_][2]f64{ .{ 0.2, 0.2 }, .{ 4.8, 0.2 }, .{ 4.8, 1.8 }, .{ 0.2, 1.8 } };
    const zones = [_]pour.UserZone{.{ .net = "GND", .layer = 0, .poly = &drawn }};
    const empty = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 1 };
    const in: CopperCheck = .{ .placement = placement, .routed = empty, .clearance = 0.127, .zones = &zones };

    const poured = checkDefaultRules(alloc, in);
    // The pour is load-bearing in this fixture: the identical board judged
    // WITHOUT it reads differently, so the comparison below cannot pass by
    // accident on a memo that handed back the wrong fill (or none).
    const unpoured = checkDefaultRules(alloc, .{ .placement = placement, .routed = empty, .clearance = 0.127 });
    try testing.expect(drc.countKind(unpoured, .net_open) != drc.countKind(poured, .net_open));

    // The board is retained now, so the pass below borrows its fill rather
    // than rastering the pour a second time.
    var held = fill_cache.acquire(fill_cache.key(placement, empty, &zones));
    defer held.release();
    try testing.expect(held.entry != null);

    const memoised = checkDefaultRules(alloc, in);
    try testing.expectEqual(poured.len, memoised.len);
    try testing.expectEqual(drc.errorCount(poured), drc.errorCount(memoised));
    try testing.expectEqual(drc.countKind(poured, .net_open), drc.countKind(memoised, .net_open));
    for (poured, memoised) |a, b| {
        try testing.expectEqual(a.kind, b.kind);
        try testing.expectEqual(a.severity, b.severity);
        try testing.expectEqual(a.x, b.x);
        try testing.expectEqual(a.y, b.y);
        try testing.expectEqual(a.gap, b.gap);
        try testing.expectEqualStrings(a.who.pad_a, b.who.pad_a);
        try testing.expectEqualStrings(a.who.pad_b, b.who.pad_b);
    }
    // A board that MOVED is a different board, and its fill is not that one.
    parts[1].x = 4.5;
    var moved = fill_cache.acquire(fill_cache.key(placement, empty, &zones));
    defer moved.release();
    try testing.expect(moved.entry == null);
}

// spec: placement/drc - reporting DRC retains the same exact variable-width RF carve that Gerber computes from the raw route proof
test "filled topology and Gerber proof carve the same RF taper" {
    const testing = std.testing;
    const rf_path_solver = @import("rf_path_solver.zig");
    const rf_port_report = @import("rf_port_report.zig");
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const alloc = arena_inst.allocator();

    const nets = [_]optimizer.FlatNet{
        .{ .name = "GND", .pins = &.{} },
        .{ .name = "RF", .pins = &.{} },
    };
    const placement = optimizer.Placement{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 10,
        .maxy = 10,
        .generated = true,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 10, .h = 10 },
        .rules = .{ .copper_layers = 2, .design = .{ .pour = .{ .clearance_outer = 0.2 } } },
    };
    const samples = [_]rf_path_solver.Sample{
        .{ .at = .{ 2, 5 }, .s_mm = 0, .curvature = 0, .width_mm = 0.2 },
        .{ .at = .{ 8, 5 }, .s_mm = 6, .curvature = 0, .width_mm = 1.0 },
    };
    const outcomes = [_]rf_port_report.Outcome{.{
        .net = 1,
        .chosen = 0,
        .feasible = true,
        .success = true,
        .metrics = .{},
        .trials = &.{},
        .physical = .{ .sample_count = samples.len, .samples = &samples, .layer = 0 },
    }};
    const handle = [_]router.Track{.{
        .x1 = 2,
        .y1 = 5,
        .x2 = 8,
        .y2 = 5,
        .layer = 0,
        .width = 0.2,
        .net = 1,
    }};
    const zone_poly = [_][2]f64{ .{ 0.2, 0.2 }, .{ 9.8, 0.2 }, .{ 9.8, 9.8 }, .{ 0.2, 9.8 } };
    const zones = [_]pour.UserZone{.{ .net = "GND", .layer = 0, .poly = &zone_poly }};
    const routed = router.RouteResult{
        .tracks = &handle,
        .vias = &.{},
        .rf_port_outcomes = &outcomes,
        .routed = 1,
        .total = 1,
    };
    const in: CopperCheck = .{ .placement = placement, .routed = routed, .clearance = 0.127, .zones = &zones };
    const retained = (try filledTopology(alloc, in, null, null)).fills;
    try testing.expectEqual(@as(usize, 1), retained.zone_fills.len);

    const base = try pour.sharedEdgeField(alloc, placement);
    const spec = pour.zoneLayerSpec("GND", .top, 0, &zone_poly);
    const exact = try pour.computeShared(alloc, placement, .{
        .tracks = &handle,
        .rf_paths = &outcomes,
        .zones = &zones,
    }, spec, base);
    try testing.expectEqual(@as(usize, 1), exact.contours.len);
    try testing.expectEqual(@as(usize, 1), retained.zones.len);
    try testing.expectEqualSlices([2]f64, exact.contours[0], retained.zones[0].poly);
    try testing.expectEqual(@as(usize, 1), exact.holes[0].len);
    try testing.expectEqual(@as(usize, 1), retained.zones[0].holes.len);
    try testing.expectEqualSlices([2]f64, exact.holes[0][0], retained.zones[0].holes[0]);
    try testing.expectEqual(exact.integrity_ok, retained.zone_fills[0].integrity_ok);
    try testing.expectEqual(exact.n_comp, retained.zone_fills[0].n_comp);
    try testing.expectEqualSlices(i32, exact.labels, retained.zone_fills[0].labels);

    // Prove this fixture catches the old adapter: its max-endpoint-width
    // capsule removes copper near the narrow end that the tapered film keeps.
    const lowered_tracks = try path_copper.tracks(alloc, routed);
    const lowered = try pour.computeShared(alloc, placement, .{ .tracks = lowered_tracks, .zones = &zones }, spec, base);
    try testing.expect(exactFillKeepsCopperLoweringRemoves(exact, lowered));
}

/// A two-layer board with copper on both faces and a drawn pour on each: enough
/// for the per-fill memo to have something it must reuse (the far face) and
/// something it must not (the edited face).
fn twoFaceBoard(parts: []optimizer.Part, nets: []const optimizer.FlatNet) optimizer.Placement {
    return .{
        .parts = parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 10,
        .maxy = 6,
        .generated = true,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 10, .h = 6 },
        .rules = .{ .copper_layers = 2 },
    };
}

fn expectSamePolys(a: []const []const [2]f64, b: []const []const [2]f64) !void {
    try std.testing.expectEqual(a.len, b.len);
    for (a, b) |pa, pb| try std.testing.expectEqualSlices([2]f64, pa, pb);
}

/// Bit-identity of one raster: the labels the connectivity layer samples, the
/// component count, the traced boundary, its holes, and the two flags a
/// fabrication gate reads. A borrowed fill that differs in ANY of these is a
/// wrong DRC verdict waiting to happen.
fn expectSameFill(cold: pour.Fill, warm: pour.Fill) !void {
    const testing = std.testing;
    try testing.expectEqual(cold.frame, warm.frame);
    try testing.expectEqual(cold.n_comp, warm.n_comp);
    try testing.expectEqual(cold.coarsened, warm.coarsened);
    try testing.expectEqual(cold.integrity_ok, warm.integrity_ok);
    try testing.expectEqualSlices(i32, cold.labels, warm.labels);
    try expectSamePolys(cold.contours, warm.contours);
    try testing.expectEqual(cold.holes.len, warm.holes.len);
    for (cold.holes, warm.holes) |ch, wh| try expectSamePolys(ch, wh);
}

fn expectSameFills(cold: fill_cache.Fills, warm: fill_cache.Fills) !void {
    const testing = std.testing;
    try testing.expectEqual(cold.zones.len, warm.zones.len);
    for (cold.zones, warm.zones) |c, w| {
        try testing.expectEqualStrings(c.net, w.net);
        try testing.expectEqual(c.layer, w.layer);
        try testing.expectEqual(c.stack, w.stack);
        try testing.expectEqual(c.component, w.component);
        try testing.expectEqual(c.plane, w.plane);
        try testing.expectEqualSlices([2]f64, c.poly, w.poly);
        try expectSamePolys(c.holes, w.holes);
    }
    try testing.expectEqual(cold.plane_fills.len, warm.plane_fills.len);
    for (cold.plane_fills, warm.plane_fills) |c, w| {
        try testing.expectEqualStrings(c.net_name, w.net_name);
        try testing.expectEqual(c.fills.len, w.fills.len);
        for (c.fills, w.fills) |cf, wf| try expectSameFill(cf, wf);
    }
    try testing.expectEqual(cold.zone_fills.len, warm.zone_fills.len);
    for (cold.zone_fills, warm.zone_fills) |c, w| try expectSameFill(c, w);
}

// spec: placement/fill-cache - a board rebuilt after a copper edit borrows the fills the edit did not reach, and every borrowed raster is bit-identical to the one a cold pour produces
test "fills borrowed across an edit are bit-identical to a cold pour" {
    const testing = std.testing;
    const geometry = @import("geometry.zig");
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const alloc = arena_inst.allocator();

    const pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads, .fallback = false, .x = 1.5, .y = 1.5 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads, .fallback = false, .x = 8, .y = 1.5 },
        .{ .ref_des = "R3", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads, .fallback = false, .x = 1.5, .y = 4.5, .side = .bottom },
    };
    const flat = @import("../flat_netlist.zig");
    const gnd_pins = [_]flat.FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R3", .pin = "1" } };
    const sig_pins = [_]flat.FlatPin{.{ .ref_des = "R2", .pin = "1" }};
    const nets = [_]optimizer.FlatNet{
        .{ .name = "GND", .pins = &gnd_pins },
        .{ .name = "SIG", .pins = &sig_pins },
    };
    const placement = twoFaceBoard(&parts, &nets);

    // One drawn GND pour per face. The bottom one is what the memo must hand
    // back untouched when a TOP-layer track moves.
    const top_poly = [_][2]f64{ .{ 0.4, 0.4 }, .{ 9.6, 0.4 }, .{ 9.6, 2.8 }, .{ 0.4, 2.8 } };
    const bottom_poly = [_][2]f64{ .{ 0.4, 3.2 }, .{ 9.6, 3.2 }, .{ 9.6, 5.6 }, .{ 0.4, 5.6 } };
    const zones = [_]pour.UserZone{
        .{ .net = "GND", .layer = 0, .poly = &top_poly },
        .{ .net = "GND", .layer = 1, .poly = &bottom_poly },
    };
    const saved_tracks = [_]router.Track{
        .{ .x1 = 2.5, .y1 = 1.5, .x2 = 7.5, .y2 = 1.5, .layer = 0, .width = 0.25, .net = 1 },
        .{ .x1 = 2.5, .y1 = 4.5, .x2 = 7.5, .y2 = 4.5, .layer = 1, .width = 0.25, .net = 1 },
    };
    const saved = router.RouteResult{ .tracks = &saved_tracks, .vias = &.{}, .routed = 1, .total = 2 };
    const before: CopperCheck = .{ .placement = placement, .routed = saved, .clearance = 0.15, .zones = &zones };

    // The board as saved, poured once through the memo and KEPT borrowed, so
    // its fills are still retained when the edited state asks for them.
    var first = fill_cache.beginSession() orelse return error.TestExpectedSession;
    defer first.release();
    _ = try filledTopology(alloc, before, first.memo(), null);

    // The edit: the TOP track moves. The bottom face cannot have changed.
    var edited_tracks = saved_tracks;
    edited_tracks[0].x1 += 0.4;
    edited_tracks[0].x2 += 0.4;
    const after: CopperCheck = .{
        .placement = placement,
        .routed = .{ .tracks = &edited_tracks, .vias = &.{}, .routed = 1, .total = 2 },
        .clearance = 0.15,
        .zones = &zones,
    };

    const hits_before = fill_cache.stats().tally.fill_hits;
    var second = fill_cache.beginSession() orelse return error.TestExpectedSession;
    defer second.release();
    const warm = (try filledTopology(alloc, after, second.memo(), null)).fills;
    // Something WAS borrowed — otherwise the comparison below would be two
    // cold pours agreeing with each other, which proves nothing.
    try testing.expect(fill_cache.stats().tally.fill_hits > hits_before);

    // …and every fill of the edited board matches the fill a caller with no
    // memo at all computes for that same board.
    const cold = (try filledTopology(alloc, after, null, null)).fills;
    try expectSameFills(cold, warm);

    // The edit is load-bearing: the top face's raster really did move, so a
    // memo that wrongly reused it would fail the comparison above rather than
    // pass it by describing an unchanged board.
    const unedited = (try filledTopology(alloc, before, null, null)).fills;
    try testing.expectEqual(unedited.zone_fills.len, cold.zone_fills.len);
    try testing.expect(!std.mem.eql(i32, unedited.zone_fills[0].labels, cold.zone_fills[0].labels));
    try testing.expectEqualSlices(i32, unedited.zone_fills[1].labels, cold.zone_fills[1].labels);
}

/// Every finding as one sortable line, so two passes compare as multisets and a
/// reordering is not a difference (`drc-dump` prints the same shape).
fn findingLines(arena: std.mem.Allocator, list: []const drc.Violation) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (list) |v| {
        if (isDeferredKind(v.kind)) continue;
        var aw: std.Io.Writer.Allocating = .init(arena);
        try aw.writer.print("{s} {s} {d:.6},{d:.6} gap={d:.6} clr={d:.6} a={d}/{d} b={d}/{d}", .{
            @tagName(v.kind), @tagName(v.severity), v.x,         v.y,
            v.gap,            v.clearance,          v.who.net_a, v.who.part_a,
            v.who.net_b,      v.who.part_b,
        });
        try out.append(arena, aw.written());
    }
    const lines = out.items;
    std.mem.sort([]const u8, lines, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    return lines;
}

fn expectSameFindings(arena: std.mem.Allocator, expected: []const drc.Violation, actual: []const drc.Violation) !void {
    const want = try findingLines(arena, expected);
    const got = try findingLines(arena, actual);
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |a, b| try std.testing.expectEqualStrings(a, b);
}

/// Two nets a hair apart on one face under a drawn GND pour: enough copper for
/// a clearance finding, a connectivity finding, and a pour to reuse.
fn scopeFixture(parts: []optimizer.Part, nets: []const optimizer.FlatNet) optimizer.Placement {
    var p = twoFaceBoard(parts, nets);
    p.rules.design.clearance = 0.2;
    return p;
}

// spec: placement/drc - a scoped recheck returns the findings a full check of the same board returns, for every kind it does not defer
test "a scoped recheck equals a full check across a sequence of copper edits" {
    const testing = std.testing;
    const geometry = @import("geometry.zig");
    const flat = @import("../flat_netlist.zig");
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const alloc = arena_inst.allocator();

    const pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads, .fallback = false, .x = 1.5, .y = 1.5 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads, .fallback = false, .x = 8, .y = 1.5 },
        .{ .ref_des = "R3", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads, .fallback = false, .x = 1.5, .y = 4.5, .side = .bottom },
    };
    const gnd_pins = [_]flat.FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R3", .pin = "1" } };
    const sig_pins = [_]flat.FlatPin{.{ .ref_des = "R2", .pin = "1" }};
    const nets = [_]optimizer.FlatNet{
        .{ .name = "GND", .pins = &gnd_pins },
        .{ .name = "SIG", .pins = &sig_pins },
    };
    const placement = scopeFixture(&parts, &nets);
    const top_poly = [_][2]f64{ .{ 0.4, 0.4 }, .{ 9.6, 0.4 }, .{ 9.6, 2.8 }, .{ 0.4, 2.8 } };
    const bottom_poly = [_][2]f64{ .{ 0.4, 3.2 }, .{ 9.6, 3.2 }, .{ 9.6, 5.6 }, .{ 0.4, 5.6 } };
    const zones = [_]pour.UserZone{
        .{ .net = "GND", .layer = 0, .poly = &top_poly },
        .{ .net = "GND", .layer = 1, .poly = &bottom_poly },
    };
    var tracks = [_]router.Track{
        .{ .x1 = 2.5, .y1 = 1.5, .x2 = 7.5, .y2 = 1.5, .layer = 0, .width = 0.25, .net = 1 },
        .{ .x1 = 2.5, .y1 = 4.5, .x2 = 7.5, .y2 = 4.5, .layer = 1, .width = 0.25, .net = 1 },
    };
    const vias = [_]router.Via{.{ .x = 5, .y = 5.2, .dia = 0.6, .net = 0, .drill = 0.3 }};

    const in = struct {
        fn of(p: optimizer.Placement, t: []const router.Track, v: []const router.Via, z: []const pour.UserZone) CopperCheck {
            return .{ .placement = p, .routed = .{ .tracks = t, .vias = v, .routed = 1, .total = 2 }, .clearance = 0.2, .zones = z };
        }
    };

    var session = checkPrimingReport(alloc, in.of(placement, &tracks, &vias, &zones));
    defer session.held.release();
    try testing.expect(session.scoped);
    // The priming pass IS a full pass: same findings, evidence kept.
    try expectSameFindings(alloc, checkDefaultRules(alloc, in.of(placement, &tracks, &vias, &zones)), session.violations);

    // A sequence of edits, each applied to the state the last one left — a
    // moved track, an added one, a moved via (which unsettles every fill), and
    // a deletion. After each, the scoped answer must be the full answer.
    var state = tracks;
    var live_vias = vias;
    var extra = [_]router.Track{
        tracks[0],
        .{ .x1 = 3, .y1 = 2.0, .x2 = 6, .y2 = 2.0, .layer = 0, .width = 0.25, .net = 1 },
        tracks[1],
    };
    const steps = [_]struct { t: []router.Track, v: []router.Via }{
        .{ .t = &state, .v = &live_vias },
        .{ .t = &extra, .v = &live_vias },
        .{ .t = &extra, .v = &live_vias },
        .{ .t = extra[0..2], .v = &live_vias },
    };
    var prev: router.RouteResult = .{ .tracks = &tracks, .vias = &vias, .routed = 1, .total = 2 };
    for (steps, 0..) |step, i| {
        switch (i) {
            0 => {
                state[0].y1 += 0.35;
                state[0].y2 += 0.35;
            },
            2 => live_vias[0].x += 0.4,
            else => {},
        }
        const next: router.RouteResult = .{ .tracks = step.t, .vias = step.v, .routed = 1, .total = 2 };
        const delta = try drc_scope.diffCopper(alloc, prev, next, placement.nets.len);
        const now = in.of(placement, step.t, step.v, &zones);
        const scoped = checkScopedReport(alloc, now, session.prior, delta);
        try testing.expect(scoped.scoped);
        try expectSameFindings(alloc, checkDefaultRules(alloc, now), scoped.violations);
        session.held.release();
        session = scoped;
        prev = next;
    }
}

// spec: placement/drc - a scoped recheck retires the findings its edit changed and carries the ones it did not
test "a scoped recheck drops a fixed clash, gains a new one, and keeps an untouched one" {
    const testing = std.testing;
    const geometry = @import("geometry.zig");
    const flat = @import("../flat_netlist.zig");
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const alloc = arena_inst.allocator();

    const pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads, .fallback = false, .x = 1, .y = 1 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads, .fallback = false, .x = 9, .y = 1 },
    };
    const a_pins = [_]flat.FlatPin{.{ .ref_des = "R1", .pin = "1" }};
    const b_pins = [_]flat.FlatPin{.{ .ref_des = "R2", .pin = "1" }};
    const nets = [_]optimizer.FlatNet{ .{ .name = "A", .pins = &a_pins }, .{ .name = "B", .pins = &b_pins } };
    const placement = scopeFixture(&parts, &nets);

    // Three same-layer pairs, each a hair inside the 0.2 mm rule: the first
    // pair is the one the edit repairs, the third is far away and untouched.
    var tracks = [_]router.Track{
        .{ .x1 = 2, .y1 = 1.0, .x2 = 4, .y2 = 1.0, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 2, .y1 = 1.25, .x2 = 4, .y2 = 1.25, .layer = 0, .width = 0.2, .net = 1 },
        .{ .x1 = 6, .y1 = 1.0, .x2 = 8, .y2 = 1.0, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 6, .y1 = 1.25, .x2 = 8, .y2 = 1.25, .layer = 0, .width = 0.2, .net = 1 },
    };
    const before: CopperCheck = .{ .placement = placement, .routed = .{ .tracks = &tracks, .vias = &.{}, .routed = 0, .total = 2 }, .clearance = 0.2 };
    var session = checkPrimingReport(alloc, before);
    defer session.held.release();
    try testing.expectEqual(@as(usize, 2), drc.countKind(session.violations, .track_track));

    // Move the first pair's B leg clear, and drag a NEW B leg beside the far
    // pair's A leg so one finding is repaired and one is created.
    var after_tracks = tracks;
    after_tracks[1].y1 = 3.0;
    after_tracks[1].y2 = 3.0;
    const after: CopperCheck = .{
        .placement = placement,
        .routed = .{ .tracks = &after_tracks, .vias = &.{}, .routed = 0, .total = 2 },
        .clearance = 0.2,
    };
    const delta = try drc_scope.diffCopper(alloc, before.routed, after.routed, placement.nets.len);
    try testing.expectEqual(@as(usize, 2), delta.count);
    var scoped = checkScopedReport(alloc, after, session.prior, delta);
    defer scoped.held.release();
    try testing.expect(scoped.scoped);

    // Exactly one clearance finding survives — the far pair — and it is the one
    // the earlier pass reported, unchanged.
    try testing.expectEqual(@as(usize, 1), drc.countKind(scoped.violations, .track_track));
    try expectSameFindings(alloc, checkDefaultRules(alloc, after), scoped.violations);
    var kept: ?drc.Violation = null;
    for (scoped.violations) |v| {
        if (v.kind == .track_track) kept = v;
    }
    try testing.expect(kept != null);
    try testing.expect(kept.?.x > 5);
}

// spec: placement/drc - the three reference-plane kinds are carried across scoped rechecks rather than recomputed
test "a scoped recheck carries the deferred kinds forward untouched" {
    const testing = std.testing;
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const alloc = arena_inst.allocator();

    // The three kinds a scoped pass defers, and one it does not.
    try testing.expect(isDeferredKind(.reference_plane_gap));
    try testing.expect(isDeferredKind(.reference_transition));
    try testing.expect(isDeferredKind(.loop_area));
    try testing.expect(!isDeferredKind(.track_track));
    try testing.expect(!isDeferredKind(.net_open));

    const mixed = [_]drc.Violation{
        .{ .x = 1, .y = 1, .gap = 0, .clearance = 0, .kind = .loop_area, .severity = .warn },
        .{ .x = 2, .y = 2, .gap = 0.1, .clearance = 0.2, .kind = .track_track },
        .{ .x = 3, .y = 3, .gap = 0, .clearance = 0, .kind = .reference_plane_gap, .severity = .warn },
    };
    const carried = deferredOf(alloc, &mixed);
    try testing.expectEqual(@as(usize, 2), carried.len);
    try testing.expectEqual(drc.Kind.loop_area, carried[0].kind);
    try testing.expectEqual(drc.Kind.reference_plane_gap, carried[1].kind);

    // A scoped pass over a board with NO return-path rules of its own still
    // reports the carried findings: they ride on the snapshot, not on the rules.
    var parts = [_]optimizer.Part{};
    const nets = [_]optimizer.FlatNet{.{ .name = "A", .pins = &.{} }};
    const placement = scopeFixture(&parts, &nets);
    const tracks = [_]router.Track{.{ .x1 = 2, .y1 = 1, .x2 = 4, .y2 = 1, .layer = 0, .width = 0.2, .net = 0 }};
    const in: CopperCheck = .{ .placement = placement, .routed = .{ .tracks = &tracks, .vias = &.{}, .routed = 0, .total = 0 }, .clearance = 0.2 };
    var session = checkPrimingReport(alloc, in);
    defer session.held.release();
    try testing.expectEqual(@as(usize, 0), drc.countKind(session.violations, .loop_area));

    var prior = session.prior;
    prior.deferred = &mixed;
    var scoped = checkScopedReport(alloc, in, prior, .{});
    defer scoped.held.release();
    try testing.expect(scoped.scoped);
    // All three ride through, including the `track_track` that was handed to it
    // as deferred state — the carry is verbatim, never re-judged.
    try testing.expectEqual(@as(usize, 1), drc.countKind(scoped.violations, .loop_area));
    try testing.expectEqual(@as(usize, 1), drc.countKind(scoped.violations, .reference_plane_gap));
    try testing.expect(scoped.prior.deferred.len == mixed.len);
}
