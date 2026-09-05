//! `generate_fence` CLI tool + `POST /api/pcb-fence/:name` — lay the RF ground
//! via fence a `(net-class … (fence …))` asked for onto a saved layout, then
//! fill the rest of the board with the generated GND stitching lattice.
//!
//! A net is a fence target when its resolved class DECLARES a fence or carries
//! a `(max-freq …)` — the second arm being the "fence the board's RF traces"
//! default that lets the action cover an RF class that never spelled `(fence)`
//! out. Both resolve through the same generator, so the button and an agent
//! call place identical copper on either spelling.
//!
//! This is an END-OF-DESIGN, ON-DEMAND action, never a step of routing: the
//! autorouter has no business dropping decorative ground vias while it is still
//! looking for paths, and a fence is only meaningful once the traces it flanks
//! have stopped moving. So the input is a saved layout's PERSISTED copper, and
//! the output is more persisted copper in the same row.
//!
//! Three properties make it safe to run repeatedly on a nearly-finished board:
//!
//!   * **Idempotent.** Every via already tagged with one of the target nets'
//!     fences is dropped first, so a re-run REPLACES the fence rather than
//!     stacking a second one beside copper that has since moved.
//!   * **Additive-only.** Nothing else is touched — no track is ripped, no part
//!     moves, custom pours survive. An illegal site is a counted gap (see
//!     `via_fence.Skips`), never a forced conflict.
//!   * **Ratcheted** — in `.legal` mode. The merged board is DRC'd against the
//!     board as it stood after the drop; error-severity geometry violations are
//!     matched by identity, the fence vias nearest each unmatched finding are
//!     culled, and the board is re-checked a bounded number of times. Gaps are
//!     acceptable by design, so
//!     culling a via beats rejecting the batch — and warnings never block (a
//!     `sharp_bend` on the RF trace is not the fence's fault).
//!
//! Those three together are the run's contract: **the fence adds ZERO new
//! error-severity DRC violations**, so `drc_errors == drc_errors_before` in every
//! `.legal` result and a nonzero `culled` is the ratchet having enforced it. The
//! ratchet is the BACKSTOP, not the filter — `via_fence`'s prefilter mirrors the
//! `drc.zig` predicates exactly, so on a board it understands the ratchet has
//! nothing left to do and `culled` is 0. A rising `culled` is the signal that some
//! rule reaches the merged board that a per-candidate check cannot see.
//!
//! `via_fence.Mode.all` suspends that contract on purpose: every non-coincident
//! site the generator produced is persisted, and the DRC is still measured and
//! REPORTED but never acted on. It is the debug view for judging ring geometry —
//! `mode=legal`, the default, is what puts manufacturable copper on a board.
//!
//! The CLI tool and the HTTP endpoint share one `run`, so the viewer's Fence
//! button and an agent's `generate_fence` call can never diverge.

const std = @import("std");
const json_writer = @import("../json_writer.zig");
const httpz = @import("httpz");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const modules_mod = @import("modules.zig");
const pcb_layout_page = @import("pcb_layout_page.zig");
const drc = @import("../placement/drc.zig");
const drc_rules = @import("drc_rules.zig");
const optimizer = @import("../placement/optimizer.zig");
const router = @import("../placement/router.zig");
const via_fence = @import("../placement/via_fence.zig");
const fab_readiness = @import("../fab_readiness.zig");
const serve_root = @import("../serve.zig");

const Server = serve_root.Server;
const HandlerError = pcb_layout_page.HandlerError;
const SavedRoutes = pcb_layout_page.SavedRoutes;
const SavedVia = pcb_layout_page.SavedVia;
const SavedLayout = pcb_layout_page.SavedLayout;

/// How far (mm) from a new DRC violation a fence via must be to be considered
/// its cause. A via that breaks a clearance rule sits within roughly its own
/// radius plus the clearance of the reported gap midpoint; 1 mm covers that with
/// room to spare while never reaching across a board to cull an innocent row.
const cull_radius_mm: f64 = 1.0;

/// Cull/re-check rounds the DRC ratchet may spend before it gives up and keeps
/// what it has. Each round removes at least one via or stops, so this only
/// bounds a pathological board.
const max_cull_rounds: usize = 3;

/// Why a fence run produced nothing — each maps to one HTTP status + body and
/// one CLI failure message, so the two surfaces explain themselves identically.
pub const FenceError = @import("../layout_sidecar_store.zig").StoreError || error{
    /// The design/module name resolves to no block.
    BlockNotFound,
    /// A layout was asked for by name and no saved row answers to it.
    UnknownLayout,
    /// Nothing is saved to fence.
    NoSavedLayout,
    /// The layout carries no routed copper, so there is no trace to flank.
    NoCopper,
    /// No `(net-class … (fence …))` is declared on any of this board's nets.
    NoFenceClasses,
    /// The placement itself failed to build.
    PlacementFailed,
} || std.mem.Allocator.Error;

/// How much copper one run moved.
pub const Counts = struct {
    /// All generated vias persisted after the DRC ratchet.
    placed: usize = 0,
    /// RF trace-fence subset of `placed`.
    fence_placed: usize = 0,
    /// Board-wide stitching-grid subset of `placed`.
    grid_placed: usize = 0,
    /// Sites the generator produced that the ratchet then culled.
    culled: usize = 0,
    /// Pre-existing fence vias this run replaced.
    replaced: usize = 0,
    /// Board-wide square stitching lattice report.
    grid: via_fence.GridReport = .{},
};

/// The board's DRC around the edit: every violation, the fab-blocking subset,
/// and the subset count on the board as it stood BEFORE the fence went down —
/// the number the ratchet holds the run to.
pub const DrcDelta = struct {
    all: usize = 0,
    errors: usize = 0,
    before: usize = 0,
};

/// One fence request's caller-chosen knobs. Bundled rather than spread over
/// `run`'s parameter list so a new one (this wave added `mode`) does not have to
/// be threaded through every call site by position.
pub const Options = struct {
    /// Saved layout to fence and write back to; null = the starred snapshot.
    layout: ?[]const u8 = null,
    /// Restrict the pass to these fenced nets; empty = every fence target
    /// (a declared (fence …) or a (max-freq …) RF trace).
    only: []const []const u8 = &.{},
    /// How hard each guide site is vetted. `.legal` is the default on both surfaces.
    mode: via_fence.Mode = .legal,
    /// Report what would be placed and write nothing.
    dry_run: bool = false,
};

/// One fence run's result, before it is serialized for CLI or HTTP.
pub const Outcome = struct {
    /// The saved layout that was fenced (and written back to).
    layout: []const u8,
    /// Per-net reports from the generator — placed / skipped-by-reason / pitch.
    nets: []const via_fence.NetReport,
    /// The board's resolved default ground net ("" when none was found).
    ground: []const u8,
    counts: Counts = .{},
    drc: DrcDelta = .{},
    tally: fab_readiness.Tally = .{},
    /// The request that produced all of the above, echoed back — so a caller
    /// reading the body knows whether the DRC numbers were enforced or merely
    /// measured, and whether anything was written.
    opt: Options,
};

/// One run's fixed context: where the board is and what it resolved to. Bundled
/// so the DRC and ratchet helpers take a board plus a candidate, not a parameter
/// list that grows with every new lookup they need.
const Ctx = struct {
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    solved: pcb_layout_page.SolvedRequest,
    /// Whether the DRC this context measures is allowed to cull anything.
    mode: via_fence.Mode,

    /// The violation list itself, for the ratchet's cull step.
    fn violations(self: Ctx, rr: router.RouteResult) []const drc.Violation {
        return drc_rules.checkFilteredZones(self.alloc, self.project_dir, self.name, .{
            .placement = self.solved.placement,
            .routed = rr,
            .clearance = self.solved.placement.rules.design.routeParams().clearance,
            .zones = self.solved.shown_zones.user,
        });
    }
};

/// The set of net names this run fences: every net whose resolved class is a
/// fence target — a declared `(fence)` or a `(max-freq …)` RF trace — narrowed
/// by `only` when the caller named some. Empty ⇒ the board has no fence target
/// at all (`NoFenceClasses`), which is a different answer from "the filter
/// matched nothing".
fn targetNets(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    only: []const []const u8,
) std.mem.Allocator.Error!std.StringHashMapUnmanaged(void) {
    var set = std.StringHashMapUnmanaged(void).empty;
    for (placement.nets, 0..) |net, ni| {
        if (ni >= placement.rules.net.len) break;
        if (!via_fence.fenceable(placement.rules.net[ni])) continue;
        if (only.len > 0) {
            var named = false;
            for (only) |o| {
                if (std.mem.eql(u8, o, net.name)) named = true;
            }
            if (!named) continue;
        }
        try set.put(alloc, net.name, {});
    }
    return set;
}

/// `sr` with every via belonging to one of `drop`'s fences removed — the
/// idempotence step. Keyed on the `f` provenance tag alone: the vias' own net is
/// ground, which must never be cleared wholesale, and a hand-drawn ground
/// stitching via carries no tag so it always survives.
fn dropExistingFence(
    alloc: std.mem.Allocator,
    sr: SavedRoutes,
    drop: *const std.StringHashMapUnmanaged(void),
) std.mem.Allocator.Error!struct { routes: SavedRoutes, dropped: usize } {
    var vias: std.ArrayList(SavedVia) = .empty;
    var dropped: usize = 0;
    for (sr.vias) |v| {
        if (v.f.len > 0 and drop.contains(v.f)) dropped += 1 else try vias.append(alloc, v);
    }
    return .{
        .routes = .{ .tracks = sr.tracks, .vias = try vias.toOwnedSlice(alloc), .zones = sr.zones, .rf_paths = sr.rf_paths },
        .dropped = dropped,
    };
}

fn provenanceCount(vias: []const SavedVia, provenance: []const u8) usize {
    var count: usize = 0;
    for (vias) |via| if (std.mem.eql(u8, via.f, provenance)) {
        count += 1;
    };
    return count;
}

/// The generator's sites lowered to persisted vias, each carrying its fenced
/// net as `f`.
fn savedVias(alloc: std.mem.Allocator, sites: []const via_fence.Site) std.mem.Allocator.Error![]SavedVia {
    const out = try alloc.alloc(SavedVia, sites.len);
    for (sites, 0..) |s, i| out[i] = .{
        .x = s.x,
        .y = s.y,
        .d = s.dia,
        .drill = s.drill,
        .net = s.net,
        .f = s.fenced,
        .source = pcb_layout_page.route_source_autorouter,
    };
    return out;
}

/// `base` with `added` appended — tracks, zones and pre-existing vias untouched.
fn withFence(alloc: std.mem.Allocator, base: SavedRoutes, added: []const SavedVia) std.mem.Allocator.Error!SavedRoutes {
    const vias = try alloc.alloc(SavedVia, base.vias.len + added.len);
    @memcpy(vias[0..base.vias.len], base.vias);
    @memcpy(vias[base.vias.len..], added);
    return .{ .tracks = base.tracks, .vias = vias, .zones = base.zones, .rf_paths = base.rf_paths };
}

fn sameViolation(a: drc.Violation, b: drc.Violation) bool {
    if (a.kind != b.kind or a.severity != b.severity or a.layer != b.layer) return false;
    if (@abs(a.x - b.x) > drc.eps or @abs(a.y - b.y) > drc.eps) return false;
    const aw = a.who;
    const bw = b.who;
    return aw.net_a == bw.net_a and aw.net_b == bw.net_b and
        aw.part_a == bw.part_a and aw.part_b == bw.part_b and
        aw.track_a == bw.track_a and
        std.mem.eql(u8, aw.pad_a, bw.pad_a) and std.mem.eql(u8, aw.pad_b, bw.pad_b);
}

/// Error-severity violations in `after` that have no identity-equivalent entry
/// in `before`. Matching is a multiset operation: two coincident instances in
/// the baseline consume two after entries, so a third is still correctly new.
fn introducedErrors(
    alloc: std.mem.Allocator,
    before: []const drc.Violation,
    after: []const drc.Violation,
) std.mem.Allocator.Error![]const drc.Violation {
    const used = try alloc.alloc(bool, before.len);
    @memset(used, false);
    var out: std.ArrayList(drc.Violation) = .empty;
    for (after) |candidate| {
        if (candidate.severity != .err or candidate.kind == .net_open) continue;
        var matched = false;
        for (before, 0..) |prior, i| {
            if (used[i] or prior.severity != .err or prior.kind == .net_open) continue;
            if (!sameViolation(prior, candidate)) continue;
            used[i] = true;
            matched = true;
            break;
        }
        if (!matched) try out.append(alloc, candidate);
    }
    return out.toOwnedSlice(alloc);
}

fn drcDelta(violations: []const drc.Violation) DrcDelta {
    return .{ .all = violations.len, .errors = drc.errorCount(violations) };
}

/// Drop the fence via nearest each NEW error-severity geometry violation. Returns
/// the surviving vias; `removed` is how many the round cost. Only ever culls
/// from `fence` — pre-existing copper is not this pass's to delete.
fn cullNearViolations(
    alloc: std.mem.Allocator,
    fence: []const SavedVia,
    violations: []const drc.Violation,
) std.mem.Allocator.Error!struct { kept: []const SavedVia, removed: usize } {
    const doomed = try alloc.alloc(bool, fence.len);
    @memset(doomed, false);
    var removed: usize = 0;
    for (violations) |vio| {
        if (vio.severity != .err or vio.kind == .net_open) continue;
        var best: ?usize = null;
        var best_d: f64 = cull_radius_mm;
        for (fence, 0..) |s, i| {
            const d = std.math.hypot(s.x - vio.x, s.y - vio.y);
            if (d < best_d) {
                best_d = d;
                best = i;
            }
        }
        if (best) |b| {
            // One via can yield several findings (for example one per nearby
            // conservative track probe). Every finding must keep resolving to
            // that same cause; skipping an already-doomed nearest via would
            // walk outward and delete innocent neighbours in the same round.
            if (!doomed[b]) {
                doomed[b] = true;
                removed += 1;
            }
        }
    }
    var kept: std.ArrayList(SavedVia) = .empty;
    for (fence, 0..) |s, i| {
        if (!doomed[i]) try kept.append(alloc, s);
    }
    return .{ .kept = try kept.toOwnedSlice(alloc), .removed = removed };
}

/// The DRC ratchet: keep as much of `fence` as introduces no new error identity
/// beyond `baseline`. New findings are answered by culling the nearest vias and
/// re-checking, up to `max_cull_rounds` — never by rejecting the
/// whole batch, because a fence with gaps is the accepted outcome here and
/// throwing away a hundred good vias over one crowded corner is not.
///
/// In `.all` mode the board is still DRC'd — the caller wants the number — but
/// nothing is culled: the point of that mode is that the persisted fence is
/// exactly the ring the generator drew, DRC and all.
const Gated = struct { fence: []const SavedVia, merged: SavedRoutes, drc: DrcDelta };

fn ratchet(
    ctx: Ctx,
    base: SavedRoutes,
    fence_in: []const SavedVia,
    baseline: []const drc.Violation,
) std.mem.Allocator.Error!Gated {
    const alloc = ctx.alloc;
    const before = drc.errorCount(baseline);
    var fence = fence_in;
    var merged = try withFence(alloc, base, fence);
    var rr = pcb_layout_page.restoreRoutes(alloc, merged, ctx.solved.placement.nets);
    var violations = if (rr) |r| ctx.violations(r) else &.{};
    var count = drcDelta(violations);
    if (ctx.mode == .all) {
        count.before = before;
        return .{ .fence = fence, .merged = merged, .drc = count };
    }
    var introduced = try introducedErrors(alloc, baseline, violations);
    var round: usize = 0;
    while (introduced.len > 0 and fence.len > 0 and round < max_cull_rounds) : (round += 1) {
        const culled = try cullNearViolations(alloc, fence, introduced);
        if (culled.removed == 0) break;
        fence = culled.kept;
        merged = try withFence(alloc, base, fence);
        rr = pcb_layout_page.restoreRoutes(alloc, merged, ctx.solved.placement.nets);
        violations = if (rr) |r| ctx.violations(r) else &.{};
        count = drcDelta(violations);
        introduced = try introducedErrors(alloc, baseline, violations);
    }
    count.before = before;
    return .{ .fence = fence, .merged = merged, .drc = count };
}

/// Generate (and unless `dry_run`, persist) the fence for `name`'s saved layout.
/// The one implementation behind both the CLI tool and the HTTP endpoint.
pub fn run(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    opt: Options,
) FenceError!Outcome {
    const layout_arg = opt.layout;
    const only = opt.only;
    var eval = Evaluator.init(alloc, project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        alloc.destroy(mr.eval);
    };
    const solved = pcb_layout_page.solveForRequest(alloc, project_dir, name, .{ .layout = layout_arg }, &eval, &module_res) catch |e|
        return switch (e) {
            error.BlockNotFound, error.SubNotFound => error.BlockNotFound,
            error.OutOfMemory => error.OutOfMemory,
            else => error.PlacementFailed,
        };
    const placement = solved.placement;
    if (!via_fence.anyFenceable(placement)) return error.NoFenceClasses;

    const working = pcb_layout_page.mcpReadWorking(alloc, project_dir, name, layout_arg) orelse
        return if (layout_arg != null) error.UnknownLayout else error.NoSavedLayout;
    const routes = working.routes orelse return error.NoCopper;

    var drop = try targetNets(alloc, placement, only);
    const add_grid = only.len == 0;
    if (add_grid) try drop.put(alloc, via_fence.board_grid_provenance, {});
    const dropped = try dropExistingFence(alloc, routes, &drop);
    const base = dropped.routes;

    // The generator sees the board WITHOUT the fence it is about to replace, so
    // last run's vias never block this run's sites.
    const restored = pcb_layout_page.restoreRoutes(alloc, base, placement.nets);
    const res = try via_fence.generate(alloc, .{
        .placement = placement,
        .tracks = if (restored) |r| r.tracks else &.{},
        .vias = if (restored) |r| r.vias else &.{},
        .rf_paths = if (restored) |r| r.rf_port_outcomes else &.{},
        .only = only,
        .mode = opt.mode,
        .board_grid = add_grid,
    });

    const ctx = Ctx{
        .alloc = alloc,
        .project_dir = project_dir,
        .name = name,
        .solved = solved,
        .mode = opt.mode,
    };
    const baseline = if (restored) |r| ctx.violations(r) else &.{};
    const fresh = try savedVias(alloc, res.sites);
    const gated = try ratchet(ctx, base, fresh, baseline);

    const tally = if (pcb_layout_page.restoreRoutes(alloc, gated.merged, placement.nets)) |rr|
        try fab_readiness.routableTally(alloc, placement, .{
            .tracks = rr.tracks,
            .arcs = rr.arcs,
            .rf_paths = rr.rf_port_outcomes,
            .vias = rr.vias,
            .zones = solved.shown_zones.user,
        })
    else
        fab_readiness.Tally{};

    const entry_name = pcb_layout_page.mcpWorkingName(alloc, project_dir, name, layout_arg);
    if (!opt.dry_run) {
        try pcb_layout_page.mcpPersistWorking(alloc, project_dir, name, .{
            .name = entry_name,
            .kind = "manual",
            .ts = 0,
            .score = working.score,
            .parts = working.parts,
            .routes = gated.merged,
            .outline = working.outline,
            .texts = working.texts,
        }, false);
    }
    const grid_surviving = provenanceCount(gated.fence, via_fence.board_grid_provenance);
    var grid = res.grid;
    grid.culled = grid.placed -| grid_surviving;
    grid.placed = grid_surviving;
    return .{
        .layout = entry_name,
        .nets = res.nets,
        .ground = res.ground,
        .counts = .{
            .placed = gated.fence.len,
            .fence_placed = gated.fence.len - grid_surviving,
            .grid_placed = grid_surviving,
            .culled = res.sites.len - gated.fence.len,
            .replaced = dropped.dropped,
            .grid = grid,
        },
        .drc = gated.drc,
        .tally = tally,
        .opt = opt,
    };
}

/// The failure text for a `?mode=` / `mode:` value neither surface knows. Names
/// what was given and what the two spellings mean, so a bad call is
/// self-correcting rather than a bare rejection.
fn unknownModeMsg(alloc: std.mem.Allocator, given: []const u8) []const u8 {
    return std.fmt.allocPrint(
        alloc,
        "unknown mode \"{s}\" — expected \"all\" (place every ring site, DRC reported but not enforced) " ++
            "or \"legal\" (skip vetoed sites and cull vias implicated in newly introduced DRC errors)",
        .{given},
    ) catch err_unknown_mode;
}

/// The allocation-free fallback for `unknownModeMsg`.
const err_unknown_mode: []const u8 = "unknown mode — expected \"all\" or \"legal\"";

/// The one-line explanation for each `FenceError`, shared by both surfaces.
pub fn errorMessage(e: FenceError) []const u8 {
    return switch (e) {
        error.BlockNotFound => "no such design or module",
        error.UnknownLayout => "no saved layout by that name",
        error.NoSavedLayout => "no saved layout to fence — save a layout first",
        error.NoCopper => "the saved layout carries no routed copper — route or draw the RF traces first",
        error.NoFenceClasses => "this board declares no (fence …) and has no (max-freq …) RF traces — nothing to fence",
        error.PlacementFailed => "the placement could not be built",
        error.OutOfMemory => "out of memory",
        error.CannotReadSidecar, error.InvalidSidecar => "cannot read saved layouts safely",
        error.CannotWriteSidecar => "cannot persist saved layout",
    };
}

/// The HTTP status a `FenceError` answers with: 404 for a name that resolves to
/// nothing, 409 for a board that resolves fine but has nothing to fence yet.
pub fn errorStatus(e: FenceError) u16 {
    return switch (e) {
        error.BlockNotFound, error.UnknownLayout => 404,
        error.NoSavedLayout, error.NoCopper, error.NoFenceClasses => 409,
        error.PlacementFailed, error.OutOfMemory, error.CannotReadSidecar, error.InvalidSidecar, error.CannotWriteSidecar => 500,
    };
}

/// Serialize an `Outcome` as the shared result JSON — the same body the CLI tool
/// returns and the viewer's Fence button reads, so what an agent sees and what
/// the browser toasts can never drift.
fn writeOutcome(w: *std.Io.Writer, o: Outcome, version: u64) std.Io.Writer.Error!void {
    try w.print("{{\"ok\":true,\"live_version\":{d},\"layout\":", .{version});
    try json_writer.writeScriptString(w, o.layout);
    try w.print(
        ",\"mode\":\"{s}\",\"placed\":{d},\"fence_placed\":{d},\"grid_placed\":{d}," ++
            "\"culled\":{d},\"replaced\":{d},\"dry_run\":{}," ++
            "\"drc\":{d},\"drc_errors\":{d},\"drc_errors_before\":{d}," ++
            "\"routed\":{d},\"total\":{d},\"ground\":",
        .{
            @tagName(o.opt.mode), o.counts.placed,   o.counts.fence_placed, o.counts.grid_placed,
            o.counts.culled,      o.counts.replaced, o.opt.dry_run,         o.drc.all,
            o.drc.errors,         o.drc.before,      o.tally.routed,        o.tally.total,
        },
    );
    try json_writer.writeScriptString(w, o.ground);
    try w.writeAll(",\"nets\":[");
    for (o.nets, 0..) |n, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"net\":");
        try json_writer.writeScriptString(w, n.net);
        try w.writeAll(",\"stitch\":");
        try json_writer.writeScriptString(w, n.stitch);
        try w.print(
            ",\"placed\":{d},\"candidates\":{d},\"layers\":{d},\"contours\":{d},\"guide_mm\":{d:.3}," ++
                "\"pitch_mm\":{d:.4},\"pitch_clamped\":{}," ++
                "\"gap_mm\":{d:.4},\"guide_dist_mm\":{d:.4}," ++
                "\"skipped\":{{\"pad\":{d},\"track\":{d},\"via\":{d}," ++
                "\"keepout\":{d},\"outline\":{d},\"dedup\":{d}}}",
            .{
                n.placed,         n.march.sites,   n.march.layers,    n.contours,        n.march.guide_mm,
                n.march.pitch_mm, n.march.clamped, n.march.gap_mm,    n.march.dist_mm,   n.skipped.pad,
                n.skipped.track,  n.skipped.via,   n.skipped.keepout, n.skipped.outline, n.skipped.dedup,
            },
        );
        if (n.err.len > 0) {
            try w.writeAll(",\"error\":");
            try json_writer.writeScriptString(w, n.err);
        }
        try w.writeAll("}");
    }
    try w.writeAll("],\"grid\":{");
    try w.print(
        "\"placed\":{d},\"candidates\":{d},\"shifted\":{d},\"culled\":{d}," ++
            "\"pitch_mm\":{d:.3},\"relocate_mm\":{d:.3}," ++
            "\"skipped\":{{\"pad\":{d},\"track\":{d},\"via\":{d}," ++
            "\"keepout\":{d},\"outline\":{d},\"dedup\":{d}}}",
        .{
            o.counts.grid.placed,          o.counts.grid.candidates,        o.counts.grid.shifted,
            o.counts.grid.culled,          o.counts.grid.geometry.pitch_mm, o.counts.grid.geometry.relocate_mm,
            o.counts.grid.skipped.pad,     o.counts.grid.skipped.track,     o.counts.grid.skipped.via,
            o.counts.grid.skipped.keepout, o.counts.grid.skipped.outline,   o.counts.grid.skipped.dedup,
        },
    );
    if (o.counts.grid.err.len > 0) {
        try w.writeAll(",\"error\":");
        try json_writer.writeScriptString(w, o.counts.grid.err);
    }
    try w.writeAll("}}");
}

/// `POST /api/pcb-fence/:name[?layout=<row>&mode=legal|all&dry_run=1&nets=A,B]` —
/// the viewer's Fence button. Same implementation, same JSON body as
/// `generate_fence`. `mode` defaults to `legal`, so the button places only sites
/// the board's own rules accept without being asked to.
pub fn pcbFenceApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = pcb_layout_page.nameParam(req, res) orelse return;
    const layout_arg = pcb_layout_page.queryOpt(req, "layout");
    const mode_arg = pcb_layout_page.queryOpt(req, "mode");
    const mode = if (mode_arg) |m| via_fence.Mode.fromStr(m) orelse {
        res.status = 400;
        res.content_type = .JSON;
        var bad: std.Io.Writer.Allocating = .init(req.arena);
        try bad.writer.writeAll("{\"ok\":false,\"error\":");
        try json_writer.writeScriptString(&bad.writer, unknownModeMsg(req.arena, m));
        try bad.writer.writeAll("}");
        res.body = bad.written();
        return;
    } else .legal;
    const o = run(req.arena, ctx.project_dir, name, .{
        .layout = layout_arg,
        .only = csvQuery(req.arena, req, "nets"),
        .mode = mode,
        .dry_run = pcb_layout_page.queryFlag(req, "dry_run"),
    }) catch |e| {
        res.status = errorStatus(e);
        res.content_type = .JSON;
        var aw: std.Io.Writer.Allocating = .init(req.arena);
        try aw.writer.writeAll("{\"ok\":false,\"error\":");
        // An unknown ?layout= names the rows that DO exist, exactly like every
        // other per-layout endpoint's dead-link body.
        try json_writer.writeScriptString(&aw.writer, if (e == error.UnknownLayout)
            pcb_layout_page.unknownLayoutMsg(req.arena, ctx.project_dir, name, null, layout_arg orelse "")
        else
            errorMessage(e));
        try aw.writer.writeAll("}");
        res.body = aw.written();
        return;
    };
    var aw: std.Io.Writer.Allocating = .init(req.arena);
    try writeOutcome(&aw.writer, o, serve_root.getLiveVersion(name));
    res.content_type = .JSON;
    res.body = aw.written();
}

/// A comma-separated query parameter as trimmed, non-empty tokens.
fn csvQuery(arena: std.mem.Allocator, req: *httpz.Request, key: []const u8) []const []const u8 {
    const raw = pcb_layout_page.queryOpt(req, key) orelse return &.{};
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, raw, ',');
    while (it.next()) |tok| {
        const t = std.mem.trim(u8, tok, " \t");
        if (t.len > 0) list.append(arena, t) catch break;
    }
    return list.toOwnedSlice(arena) catch &.{};
}

/// `generate_fence` — the CLI mutation twin of `POST /api/pcb-fence/:name`.
pub fn mcpGenerateFence(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) HandlerError!bool {
    const name = argStr(args_val, "name") orelse return fail(out, alloc, "missing required arg: name");
    const mode_arg = argStr(args_val, "mode");
    const mode = if (mode_arg) |m|
        via_fence.Mode.fromStr(m) orelse return fail(out, alloc, unknownModeMsg(alloc, m))
    else
        via_fence.Mode.legal;
    const o = run(alloc, project_dir, name, .{
        .layout = argStr(args_val, "layout"),
        .only = pcb_layout_page.mcpArgStrList(alloc, args_val, "nets"),
        .mode = mode,
        .dry_run = argBool(args_val, "dry_run"),
    }) catch |e| return fail(out, alloc, errorMessage(e));
    var aw: std.Io.Writer.Allocating = .init(alloc);
    try writeOutcome(&aw.writer, o, serve_root.getLiveVersion(name));
    try out.appendSlice(alloc, aw.written());
    return true;
}

/// `args.key` as a string (null when absent / not a string).
fn argStr(args_val: ?std.json.Value, key: []const u8) ?[]const u8 {
    const av = args_val orelse return null;
    if (av != .object) return null;
    const v = av.object.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

/// `args.key` as a bool (absent / non-bool ⇒ false).
fn argBool(args_val: ?std.json.Value, key: []const u8) bool {
    const av = args_val orelse return false;
    if (av != .object) return false;
    const v = av.object.get(key) orelse return false;
    return v == .bool and v.bool;
}

/// Write an `{"ok":false,"error":…}` envelope and return false (the CLI layer
/// flags the result `isError`).
fn fail(out: *std.ArrayList(u8), alloc: std.mem.Allocator, msg: []const u8) HandlerError!bool {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    try aw.writer.writeAll("{\"ok\":false,\"error\":");
    try json_writer.writeScriptString(&aw.writer, msg);
    try aw.writer.writeAll("}");
    try out.appendSlice(alloc, aw.written());
    return false;
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

/// A two-cap board whose `SIG` net is a 12 GHz fenced RF class, with one ★ saved
/// layout carrying a three-segment `SIG` trace and no vias — the smallest board
/// on which a fence has something to flank and somewhere to put it.
fn writeFenceFixture(dir: std.Io.Dir) !void {
    try dir.createDirPath(std.testing.io, "lib/components");
    try dir.createDirPath(std.testing.io, "lib/footprints");
    try dir.createDirPath(std.testing.io, "src");
    try dir.writeFile(std.testing.io, .{ .sub_path = "lib/components/cap.sexp", .data =
        \\(component-family cap
        \\  (param-type capacitance)
        \\  (footprint "0402"))
    });
    try dir.writeFile(std.testing.io, .{ .sub_path = "lib/footprints/0402.sexp", .data =
        \\(footprint "0402"
        \\  (pad 1 smd roundrect (pos -0.48 0.00) (size 0.56 0.62))
        \\  (pad 2 smd roundrect (pos 0.48 0.00) (size 0.56 0.62))
        \\  (courtyard (rect -0.91 -0.46 0.91 0.46)))
    });
    try dir.writeFile(std.testing.io, .{ .sub_path = "src/fencefx.sexp", .data =
        \\(design-block "Fence Fixture"
        \\  (import cap)
        \\  (board (size 20 10))
        \\  (net-class "rf" (width 0.3) (clearance 0.127) (max-freq 12G) (fence (layers 2))
        \\    (nets "SIG"))
        \\  (instance "C1" (cap "10nF") (pin 1 "SIG") (pin 2 "GND"))
        \\  (instance "C2" (cap "10nF") (pin 1 "SIG") (pin 2 "GND")))
    });
    try dir.writeFile(std.testing.io, .{ .sub_path = "src/fencefx.layouts.json", .data =
        \\{"default":"routed","layouts":[
        \\ {"name":"routed","kind":"manual","ts":2,"default":true,"parts":[
        \\   {"ref":"C1","x":5,"y":5,"rot":0},{"ref":"C2","x":10,"y":5,"rot":0}],
        \\  "routes":{"tracks":[
        \\   {"x1":4.52,"y1":5,"x2":4.52,"y2":3,"l":0,"w":0.3,"net":"SIG"},
        \\   {"x1":4.52,"y1":3,"x2":9.52,"y2":3,"l":0,"w":0.3,"net":"SIG"},
        \\   {"x1":9.52,"y1":3,"x2":9.52,"y2":5,"l":0,"w":0.3,"net":"SIG"},
        \\   {"x1":7,"y1":3.4,"x2":7.5,"y2":3.4,"l":0,"w":0.2,"net":"PWR"}],"vias":[]}}]}
    });
}

/// `POST /api/pcb-fence/fencefx` through the real handler. Returns the status and
/// the body duped onto `alloc` (the harness arena dies with the call).
fn fencePost(alloc: std.mem.Allocator, project: []const u8, query: []const [2][]const u8) !struct { status: u16, body: []const u8 } {
    var state = serve_root.ServerState{};
    var srv = Server{ .allocator = alloc, .project_dir = project, .auth_dir = project, .state = &state };
    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.param("name", "fencefx");
    for (query) |kv| ht.query(kv[0], kv[1]);
    try pcbFenceApi(&srv, ht.req, ht.res);
    return .{ .status = ht.res.status, .body = try alloc.dupe(u8, ht.res.body) };
}

/// The `vias` array of `fencefx`'s ★ saved layout, straight off disk.
fn savedFenceVias(alloc: std.mem.Allocator, project: []const u8) []const SavedVia {
    const layouts = pcb_layout_page.readLayouts(alloc, project, "fencefx");
    if (layouts.len == 0) return &.{};
    const r = layouts[0].routes orelse return &.{};
    return r.vias;
}

/// The numeric text of the FIRST `"<key>":N` in a fence result body — the
/// top-level counter, since the per-net array is written after them. Enough to
/// compare two runs numerically without pulling a JSON parser into the test.
fn resultNum(body: []const u8, key: []const u8) ?[]const u8 {
    var buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "\"{s}\":", .{key}) catch return null;
    const at = std.mem.indexOf(u8, body, needle) orelse return null;
    const from = at + needle.len;
    var end = from;
    while (end < body.len and (std.ascii.isDigit(body[end]) or body[end] == '-' or body[end] == '.')) end += 1;
    return if (end > from) body[from..end] else null;
}

/// `resultNum` parsed as a count.
fn resultInt(body: []const u8, key: []const u8) ?i64 {
    return std.fmt.parseInt(i64, resultNum(body, key) orelse return null, 10) catch null;
}

/// `resultNum` parsed as millimetres.
fn resultFloat(body: []const u8, key: []const u8) ?f64 {
    return std.fmt.parseFloat(f64, resultNum(body, key) orelse return null) catch null;
}

// spec: Web Server - POST /api/pcb-fence/:name lays (and regenerates) the RF ground via fence onto a saved layout's persisted copper — every declared (fence …) or (max-freq …) RF trace — and reports what it placed and skipped
// spec: Web Server - The unfiltered fence endpoint also persists a 5 mm board-wide GND stitching grid, reports its shifted and blocked nominal sites, and replaces that generated grid on a repeated run
// spec: Web Server - The fence endpoint reports the resolved layer count for each fenced net
// spec: Web Server - A fence dry run reports what it would place and writes nothing to the layout
test "the fence endpoint fences a saved layout, and a dry run writes nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    try writeFenceFixture(tmp.dir);

    const dry = try fencePost(alloc, project, &.{.{ "dry_run", "1" }});
    try testing.expectEqual(@as(u16, 200), dry.status);
    try testing.expect(std.mem.indexOf(u8, dry.body, "\"ok\":true") != null);
    try testing.expect(std.mem.indexOf(u8, dry.body, "\"dry_run\":true") != null);
    // The 12 GHz class resolves λg/10 ≈ 1.191 mm and rings the 9 mm trace, and it
    // names the ground net it chose and the net it flanked.
    try testing.expect(std.mem.indexOf(u8, dry.body, "\"ground\":\"GND\"") != null);
    try testing.expect(std.mem.indexOf(u8, dry.body, "\"net\":\"SIG\"") != null);
    try testing.expect(std.mem.indexOf(u8, dry.body, "\"pitch_mm\":1.191") != null);
    try testing.expectEqual(@as(i64, 2), resultInt(dry.body, "layers").?);
    try testing.expect(std.mem.indexOf(u8, dry.body, "\"pitch_clamped\":false") != null);
    // The ring is CLOSED, so its perimeter beats the two 9 mm flanks on their own:
    // the end caps and the corner miters are the difference.
    try testing.expect(resultFloat(dry.body, "guide_mm").? > 18);
    // Nothing was written: the ★ row still carries the fixture's zero vias.
    try testing.expectEqual(@as(usize, 0), savedFenceVias(alloc, project).len);

    const real = try fencePost(alloc, project, &.{});
    try testing.expectEqual(@as(u16, 200), real.status);
    try testing.expect(std.mem.indexOf(u8, real.body, "\"dry_run\":false") != null);
    const vias = savedFenceVias(alloc, project);
    try testing.expect(vias.len > 0);
    // Every persisted via stitches GND; RF rows carry SIG provenance and the
    // board-wide lattice carries its reserved regeneration tag.
    for (vias) |v| {
        try testing.expectEqualStrings("GND", v.net);
        try testing.expect(std.mem.eql(u8, "SIG", v.f) or
            std.mem.eql(u8, via_fence.board_grid_provenance, v.f));
    }
    // The counters agree with the vias on disk, and the default vets: the fixture
    // parks a foreign 0.2 mm track across the guide, so the ring's candidates are
    // more than what landed and the difference is all counted as skips.
    try testing.expectEqual(@as(i64, @intCast(vias.len)), resultInt(real.body, "placed").?);
    try testing.expect(resultInt(real.body, "fence_placed").? < resultInt(real.body, "candidates").?);
    try testing.expect(resultInt(real.body, "grid_placed").? > 0);
    try testing.expect(std.mem.indexOf(u8, real.body, "\"grid\":{") != null);
    try testing.expect(std.mem.indexOf(u8, real.body, "\"pitch_mm\":5.000") != null);
    try testing.expect(std.mem.indexOf(u8, real.body, "\"relocate_mm\":1.000") != null);
    // A clean board stays clean: the fence adds no error-severity violation at all.
    try testing.expectEqual(@as(i64, 0), resultInt(real.body, "drc_errors_before").?);
    try testing.expectEqual(@as(i64, 0), resultInt(real.body, "drc_errors").?);
    try testing.expectEqual(@as(i64, 0), resultInt(real.body, "culled").?);
}

// spec: Web Server - A board whose RF class carries only (max-freq …) — no (fence …) — is still fenced by the endpoint, the pitch deriving as λg/10 and the vias persisting with the flanked net as provenance
// spec: Web Server - The fence endpoint accepts a max-freq-only RF board and reports a normal dry run on it, so the Fence action covers RF traces that never spelled (fence) out
test "the fence endpoint fences a max-freq RF class that declares no fence" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    try writeFenceFixture(tmp.dir);
    // Strip the (fence) declaration: the class keeps its 12 GHz max-freq, so the
    // board still has an RF trace to fence — just one whose every fence parameter
    // must be derived rather than read off the form.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/fencefx.sexp", .data =
        \\(design-block "Fence Fixture"
        \\  (import cap)
        \\  (board (size 20 10))
        \\  (net-class "rf" (width 0.3) (clearance 0.127) (max-freq 12G)
        \\    (nets "SIG"))
        \\  (instance "C1" (cap "10nF") (pin 1 "SIG") (pin 2 "GND"))
        \\  (instance "C2" (cap "10nF") (pin 1 "SIG") (pin 2 "GND")))
    });

    // The endpoint accepts the board (no NoFenceClasses) and a dry run reports the
    // derived ring: the same λg/10 ≈ 1.191 mm pitch a bare (fence) resolves on the
    // same 12 GHz class, naming the ground it stitches and the net it flanks.
    const dry = try fencePost(alloc, project, &.{.{ "dry_run", "1" }});
    try testing.expectEqual(@as(u16, 200), dry.status);
    try testing.expect(std.mem.indexOf(u8, dry.body, "\"ok\":true") != null);
    try testing.expect(std.mem.indexOf(u8, dry.body, "\"ground\":\"GND\"") != null);
    try testing.expect(std.mem.indexOf(u8, dry.body, "\"net\":\"SIG\"") != null);
    try testing.expect(std.mem.indexOf(u8, dry.body, "\"pitch_mm\":1.191") != null);
    try testing.expect(resultInt(dry.body, "candidates").? > 0);
    // Nothing was written: the ★ row still carries the fixture's zero vias.
    try testing.expectEqual(@as(usize, 0), savedFenceVias(alloc, project).len);

    // The real run persists the fence exactly as a declared one would — GND
    // stitching vias carrying SIG as their provenance tag, so a later re-run (or
    // a trace edit) replaces rather than doubles them.
    const real = try fencePost(alloc, project, &.{});
    try testing.expectEqual(@as(u16, 200), real.status);
    const vias = savedFenceVias(alloc, project);
    try testing.expect(vias.len > 0);
    for (vias) |v| {
        try testing.expectEqualStrings("GND", v.net);
        try testing.expect(std.mem.eql(u8, "SIG", v.f) or
            std.mem.eql(u8, via_fence.board_grid_provenance, v.f));
    }
    // The board's own DRC stays the judge: the derived fence adds no error-level
    // violation, the same contract a declared fence holds to.
    try testing.expectEqual(
        resultInt(real.body, "drc_errors_before"),
        resultInt(real.body, "drc_errors"),
    );
}

// spec: Web Server - A fence run defaults to the vetted mode, placing only sites the board accepts and ending at the DRC error count it started from, while mode=all places every non-coincident site and reports the DRC without culling it
test "the default fence mode vets every site and mode all keeps every non-coincident one" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    try writeFenceFixture(tmp.dir);

    // Default: the vetted mode. The fixture parks a foreign 0.2 mm track right where
    // the guide runs, so the sites over it are refused and the board ends at exactly
    // the error count it started from — the run's whole contract, with nothing for
    // the ratchet left to cull.
    const legal = try fencePost(alloc, project, &.{.{ "dry_run", "1" }});
    try testing.expectEqual(@as(u16, 200), legal.status);
    try testing.expect(std.mem.indexOf(u8, legal.body, "\"mode\":\"legal\"") != null);
    try testing.expectEqual(
        resultInt(legal.body, "drc_errors_before"),
        resultInt(legal.body, "drc_errors"),
    );
    try testing.expectEqual(@as(i64, 0), resultInt(legal.body, "culled").?);

    // mode=all marches the identical guide and places every non-coincident site,
    // so it lands strictly more copper and REPORTS the violations that copper
    // causes without acting on any of them. The pad-first anchor deliberately
    // wins a coincident contour site, which is reported as a dedup rather than a
    // second barrel in the same hole.
    const all = try fencePost(alloc, project, &.{ .{ "mode", "all" }, .{ "dry_run", "1" } });
    try testing.expect(std.mem.indexOf(u8, all.body, "\"mode\":\"all\"") != null);
    try testing.expectEqual(@as(i64, 0), resultInt(all.body, "culled").?);
    try testing.expectEqual(
        resultInt(all.body, "candidates").?,
        resultInt(all.body, "fence_placed").? + resultInt(all.body, "dedup").?,
    );
    try testing.expectEqual(resultInt(all.body, "candidates"), resultInt(legal.body, "candidates"));
    try testing.expect(resultInt(legal.body, "fence_placed").? < resultInt(all.body, "fence_placed").?);
    try testing.expect(resultInt(all.body, "drc_errors").? > resultInt(all.body, "drc_errors_before").?);
}

// spec: Web Server - The fence's DRC ratchet culls the fence vias implicated in a new error-severity violation and leaves warnings, net-open findings and pre-existing copper alone
// spec: Web Server - Repeated DRC findings from one generated fence via cull that via once rather than consuming its legal neighbours
test "the fence ratchet culls the vias a new violation implicates, and only those" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // Three fence vias in a row. The prefilter is an exact mirror of the DRC, so on
    // a real board it leaves the ratchet nothing to do — which is exactly why the
    // backstop is pinned here on a synthetic violation list rather than waited for
    // on a fixture board: it has to still work the day some rule reaches the merged
    // board that a per-candidate check cannot see.
    const fence = [_]SavedVia{
        .{ .x = 1, .y = 1, .d = 0.4, .drill = 0.2, .net = "GND", .f = "SIG" },
        .{ .x = 5, .y = 1, .d = 0.4, .drill = 0.2, .net = "GND", .f = "SIG" },
        .{ .x = 9, .y = 1, .d = 0.4, .drill = 0.2, .net = "GND", .f = "SIG" },
    };
    // One error at the middle via, one WARNING and one net_open on top of the others.
    // Only the error may cost a via: a sharp bend on the RF trace is not the fence's
    // fault, and an open net is a routing state rather than a clash.
    const viols = [_]drc.Violation{
        .{ .x = 5.05, .y = 1, .gap = -0.1, .clearance = 0.127, .kind = .via_track },
        .{ .x = 1, .y = 1, .gap = 0, .clearance = 0, .kind = .sharp_bend, .severity = .warn },
        .{ .x = 9, .y = 1, .gap = 0, .clearance = 0, .kind = .net_open },
    };
    const out = try cullNearViolations(alloc, &fence, &viols);
    try testing.expectEqual(@as(usize, 1), out.removed);
    try testing.expectEqual(@as(usize, 2), out.kept.len);
    try testing.expectEqual(@as(f64, 1), out.kept[0].x);
    try testing.expectEqual(@as(f64, 9), out.kept[1].x);

    // A path lowered into several conservative probes can report the same via
    // more than once. All three findings resolve to the centre post; the two
    // neighbours must survive the round.
    const dense_fence = [_]SavedVia{
        .{ .x = 4.2, .y = 1, .d = 0.4, .drill = 0.2, .net = "GND", .f = "SIG" },
        .{ .x = 5, .y = 1, .d = 0.4, .drill = 0.2, .net = "GND", .f = "SIG" },
        .{ .x = 5.8, .y = 1, .d = 0.4, .drill = 0.2, .net = "GND", .f = "SIG" },
    };
    const repeated = [_]drc.Violation{
        .{ .x = 5, .y = 1, .gap = -0.1, .clearance = 0.127, .kind = .via_track },
        .{ .x = 5, .y = 1, .gap = -0.2, .clearance = 0.127, .kind = .via_track },
        .{ .x = 5, .y = 1, .gap = -0.3, .clearance = 0.127, .kind = .via_track },
    };
    const unique = try cullNearViolations(alloc, &dense_fence, &repeated);
    try testing.expectEqual(@as(usize, 1), unique.removed);
    try testing.expectEqual(@as(usize, 2), unique.kept.len);
    try testing.expectEqual(@as(f64, 4.2), unique.kept[0].x);
    try testing.expectEqual(@as(f64, 5.8), unique.kept[1].x);

    // A violation with no fence via within the cull radius costs nothing — the
    // ratchet never reaches across a board to blame an innocent row, and it can only
    // ever delete from the fence it just generated.
    const distant = [_]drc.Violation{.{ .x = 40, .y = 40, .gap = -0.1, .clearance = 0.127, .kind = .via_pad }};
    const untouched = try cullNearViolations(alloc, &fence, &distant);
    try testing.expectEqual(@as(usize, 0), untouched.removed);
    try testing.expectEqual(fence.len, untouched.kept.len);
}

// spec: Web Server - The fence ratchet compares violation identity against the baseline and never culls a new fence via merely because it is near a pre-existing error
test "the fence ratchet isolates introduced errors from the baseline" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const before = [_]drc.Violation{
        .{ .x = 1, .y = 1, .gap = -0.1, .clearance = 0.127, .kind = .via_track, .who = .{ .net_a = 1, .net_b = 2 } },
    };
    const after = [_]drc.Violation{
        before[0],
        .{ .x = 5, .y = 1, .gap = -0.1, .clearance = 0.127, .kind = .via_pad, .who = .{ .net_a = 1, .net_b = 3 } },
    };
    const introduced = try introducedErrors(alloc, &before, &after);
    try testing.expectEqual(@as(usize, 1), introduced.len);
    try testing.expectEqual(drc.Kind.via_pad, introduced[0].kind);

    const fence = [_]SavedVia{
        .{ .x = 1, .y = 1, .d = 0.4, .drill = 0.2, .net = "GND", .f = "SIG" },
        .{ .x = 5, .y = 1, .d = 0.4, .drill = 0.2, .net = "GND", .f = "SIG" },
    };
    const culled = try cullNearViolations(alloc, &fence, introduced);
    try testing.expectEqual(@as(usize, 1), culled.removed);
    try testing.expectEqual(@as(usize, 1), culled.kept.len);
    try testing.expectEqual(@as(f64, 1), culled.kept[0].x);
}

// spec: Web Server - The fence endpoint and the generate_fence tool reject an unknown mode naming the two spellings that exist
test "an unknown fence mode is rejected on both surfaces" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    try writeFenceFixture(tmp.dir);

    const bad = try fencePost(alloc, project, &.{.{ "mode", "loose" }});
    try testing.expectEqual(@as(u16, 400), bad.status);
    try testing.expect(std.mem.indexOf(u8, bad.body, "\"ok\":false") != null);
    // The body names what was given AND both spellings that would have worked.
    try testing.expect(std.mem.indexOf(u8, bad.body, "loose") != null);
    try testing.expect(std.mem.indexOf(u8, bad.body, "all") != null);
    try testing.expect(std.mem.indexOf(u8, bad.body, "legal") != null);
    // A rejected mode writes nothing.
    try testing.expectEqual(@as(usize, 0), savedFenceVias(alloc, project).len);

    // The CLI tool answers the same way, as a tool failure rather than a crash.
    const args = try std.json.parseFromSliceLeaky(std.json.Value, alloc, "{\"name\":\"fencefx\",\"mode\":\"loose\"}", .{});
    var out: std.ArrayList(u8) = .empty;
    try testing.expect(!try mcpGenerateFence(alloc, project, args, &out));
    try testing.expect(std.mem.indexOf(u8, out.items, "unknown mode") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "loose") != null);
}

// spec: Web Server - Re-running the fence on a layout replaces the previous fence rather than stacking a second row beside the same trace
test "a second fence run replaces the first instead of doubling it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    try writeFenceFixture(tmp.dir);

    _ = try fencePost(alloc, project, &.{});
    const first = savedFenceVias(alloc, project).len;
    try testing.expect(first > 0);

    const again = try fencePost(alloc, project, &.{});
    try testing.expectEqual(@as(u16, 200), again.status);
    // The second run reports it replaced the first run's vias…
    try testing.expect(std.mem.indexOf(u8, again.body, "\"replaced\":") != null);
    try testing.expect(std.mem.indexOf(u8, again.body, "\"replaced\":0") == null);
    // …and the board ends with ONE fence, not two rows in the same holes.
    try testing.expectEqual(first, savedFenceVias(alloc, project).len);
}

// spec: Web Server - The fence endpoint 404s an unknown layout naming the rows that exist, and refuses a board that declares no fence
test "the fence endpoint explains a dead layout link and a fence-free board" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    try writeFenceFixture(tmp.dir);

    const dead = try fencePost(alloc, project, &.{.{ "layout", "nope" }});
    try testing.expectEqual(@as(u16, 404), dead.status);
    // The dead-link body names the row asked for AND the rows that do exist,
    // JSON-escaped inside the error envelope (so the quotes arrive as \").
    try testing.expect(std.mem.indexOf(u8, dead.body, "\\\"nope\\\"") != null);
    try testing.expect(std.mem.indexOf(u8, dead.body, "\\\"routed\\\"") != null);

    // Strip the (fence) declaration: the board resolves fine and there is simply
    // nothing to do — a 409 that says so, not a silent empty success.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/fencefx.sexp", .data =
        \\(design-block "Fence Fixture"
        \\  (import cap)
        \\  (board (size 20 10))
        \\  (instance "C1" (cap "10nF") (pin 1 "SIG") (pin 2 "GND"))
        \\  (instance "C2" (cap "10nF") (pin 1 "SIG") (pin 2 "GND")))
    });
    const bare = try fencePost(alloc, project, &.{});
    try testing.expectEqual(@as(u16, 409), bare.status);
    try testing.expect(std.mem.indexOf(u8, bare.body, "nothing to fence") != null);
}

// spec: Web Server - The generate_fence CLI tool and the fence HTTP endpoint share one implementation, so they report the same board
test "generate_fence returns the same body as the fence endpoint" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    try writeFenceFixture(tmp.dir);

    const args = try std.json.parseFromSliceLeaky(std.json.Value, alloc, "{\"name\":\"fencefx\",\"dry_run\":true}", .{});
    var out: std.ArrayList(u8) = .empty;
    try testing.expect(try mcpGenerateFence(alloc, project, args, &out));
    const http = try fencePost(alloc, project, &.{.{ "dry_run", "1" }});
    try testing.expectEqualStrings(http.body, out.items);

    // A `nets` filter naming a net with no fence fences nothing, and says so per
    // net rather than failing the board.
    const filtered = try std.json.parseFromSliceLeaky(std.json.Value, alloc, "{\"name\":\"fencefx\",\"nets\":\"GND\",\"dry_run\":true}", .{});
    var narrowed: std.ArrayList(u8) = .empty;
    try testing.expect(try mcpGenerateFence(alloc, project, filtered, &narrowed));
    try testing.expect(std.mem.indexOf(u8, narrowed.items, "\"placed\":0") != null);
    try testing.expect(std.mem.indexOf(u8, narrowed.items, "\"nets\":[]") != null);

    // A missing name is a tool failure, not a crash.
    var bad: std.ArrayList(u8) = .empty;
    try testing.expect(!try mcpGenerateFence(alloc, project, null, &bad));
    try testing.expect(std.mem.indexOf(u8, bad.items, "\"ok\":false") != null);
}
