//! The `repair_placement` half of `route_experiment`: probe the board that just
//! routed for the geometry walling its still-open nets, compute one bounded set
//! of micro-moves, re-route once on the moved poses, and keep or discard on the
//! count.
//!
//! The campaign this exists for had run its routing economics to the end. Ten
//! measurements on barracuda held at the same routed tally with the same five
//! survivors, each with a PROVEN wall: a coupled pair with no alternative
//! channel, a pocket whose every freed blocker revealed another, corridors
//! geometry-sealed after rips. Every remaining lever on the routing side had
//! been priced and spent. The one lever left is where the PARTS are — and the
//! pinch diagnostics make that surgical rather than speculative, because they
//! name the two bodies and the exact millimetres between them.
//!
//! So this is the smallest seam that turns a diagnosis into an engine action:
//!
//! 1. Ask `pinch_probe` what walls each aim — every declared differential pair's
//!    envelope first (the keystone: a pair with no alternative channel is what
//!    holds a corridor a signal net needs), then each still-open net's own
//!    shortest closing hop.
//! 2. Hand the pinches to `place_repair`, which decides which side may move and
//!    how far, and validates the trial pose against the placement model.
//! 3. Route ONCE more on the moved poses and judge: keep only when the routed
//!    count strictly improves AND the fab-blocking DRC count does not.
//!
//! It sits at the source root rather than under `serve/` for the same reason
//! `fab_readiness` does: it is a cross-layer ANALYSIS that needs the placement
//! model and the routing seam at once, not web plumbing. The CLI handler above
//! it gains no new placement dependency at all.
//!
//! Two properties are load-bearing. It is **off by default and byte-identical
//! when off** — the caller's baseline route is untouched and nothing here runs.
//! And it **persists nothing**: `route_experiment`'s defining property is that it
//! writes no sidecar, and a repair that silently starred a new layout would take
//! that away. An accepted trial comes back as the exact pose list a caller feeds
//! to `set_part_poses` + `save_pcb_layout`, which are the tools already gated for
//! writing.

const std = @import("std");
const env_mod = @import("eval/env.zig");
const drc = @import("placement/drc.zig");
const drc_rules = @import("serve/drc_rules.zig");
const fab_readiness = @import("fab_readiness.zig");
const optimizer = @import("placement/optimizer.zig");
const json_writer = @import("json_writer.zig");
const pinch_probe = @import("placement/pinch_probe.zig");
const place_repair = @import("placement/place_repair.zig");
const route_plan = @import("serve/route_plan.zig");
const router = @import("placement/router.zig");

const repairLog = std.log.info;

/// Most aims one invocation probes. A probe is a CDT mesh over its own window,
/// and a pass that meshed every open net on a large board would spend more than
/// the trial route it exists to set up.
const max_aims: usize = 12;

/// The route a repair has to beat: its copper, its fab-blocking violation count,
/// and what it left open. Grouped because a trial is judged against all three at
/// once — a trial that routes more but dirties DRC is not an improvement.
pub const Baseline = struct {
    result: router.RouteResult,
    drc_errors: usize,
    /// The still-open nets, with the hops that would close them — the aiming
    /// data the probe uses for its terminals.
    open_nets: []const fab_readiness.OpenNet,
};

/// Everything one repair pass needs about the board it is repairing.
pub const Input = struct {
    project_dir: []const u8,
    name: []const u8,
    block: *const env_mod.DesignBlock,
    placement: optimizer.Placement,
    params: router.RouteParams,
    opts: route_plan.ExperimentOpts,
    baseline: Baseline,
};

/// The second route, and the verdict on it.
pub const Trial = struct {
    routed: usize,
    total: usize,
    drc_errors: usize,
    kept: bool,
    /// Why it was kept or discarded, in one clause.
    why: []const u8,
};

/// What one repair pass did, whether or not it moved anything.
pub const Outcome = struct {
    /// Every channel this pass ASKED about, in the order it asked.
    ///
    /// Reported because `pinches[]` alone cannot distinguish the two silences
    /// that matter most: a channel that was probed and found clear, and one that
    /// was never probed at all. On the campaign's keystone pair those are
    /// opposite conclusions — "the placement leaves the pair a corridor" versus
    /// "the pass could not resolve the pair's ends" — and a reader must not have
    /// to guess which happened.
    probed: []const []const u8 = &.{},
    plan: place_repair.Plan = .{},
    trial: ?Trial = null,
    /// The one-line summary a reader gets when there is no trial to report.
    verdict: []const u8 = "",
};

/// Probe, plan, trial, judge. Never mutates the caller's placement: the trial
/// routes over a private copy of the poses.
pub fn run(alloc: std.mem.Allocator, in: Input) std.mem.Allocator.Error!Outcome {
    const aims = try buildAims(alloc, in);
    if (aims.len == 0) {
        repairLog("placement repair: nothing to probe — no declared pair and no open net with a closing hop", .{});
        return .{ .verdict = "no aim to probe" };
    }
    const plan = try place_repair.plan(alloc, in.placement, aims, .{});
    const probed = try alloc.alloc([]const u8, aims.len);
    for (aims, probed) |aim, *label| label.* = aim.label;
    logPlan(in.placement, probed, plan);
    if (plan.moves.len == 0) {
        return .{
            .probed = probed,
            .plan = plan,
            .verdict = if (plan.findings.len == 0)
                "no placement pinch — every channel probed has a corridor in the pads-and-copper model"
            else
                "no legal move — every pinch owner is immovable",
        };
    }
    const trial = try routeTrial(alloc, in, plan.moves);
    return .{ .probed = probed, .plan = plan, .trial = trial, .verdict = trial.why };
}

/// Re-route the board with the planned moves applied, and judge the result.
///
/// STRICT improvement is the whole gate. A trial that routes the same count has
/// bought nothing and cost a placement change, and one that routes more while
/// adding a fab-blocking violation has bought a board that cannot be made.
fn routeTrial(
    alloc: std.mem.Allocator,
    in: Input,
    moves: []const place_repair.Move,
) std.mem.Allocator.Error!Trial {
    var moved = in.placement;
    moved.parts = try alloc.dupe(optimizer.Part, in.placement.parts);
    for (moves) |m| {
        moved.parts[m.part].x = m.to[0];
        moved.parts[m.part].y = m.to[1];
    }
    const exp = try route_plan.routeExperiment(alloc, in.block, moved, in.params, in.opts);
    const violations = drc_rules.checkFilteredZones(alloc, in.project_dir, in.name, .{
        .placement = moved,
        .routed = exp.result,
        .clearance = in.params.clearance,
        .zones = try route_plan.retainedZones(alloc, moved, .{ .existing_zones = in.opts.zones }),
    });
    const errors = drc.errorCount(violations);
    const better = exp.result.routed > in.baseline.result.routed;
    const clean = errors <= in.baseline.drc_errors;
    const kept = better and clean;
    const why = if (kept)
        "kept — the trial routes more with no new fab-blocking violation"
    else if (!better)
        "discarded — the trial routes no more than the baseline"
    else
        "discarded — the trial adds a fab-blocking DRC violation";
    repairLog("placement repair: trial routed {d}/{d}, drc_errors {d} vs baseline {d}/{d}, {d} ({s})", .{
        exp.result.routed,
        exp.result.total,
        errors,
        in.baseline.result.routed,
        in.baseline.result.total,
        in.baseline.drc_errors,
        if (kept) "kept" else "discarded",
    });
    return .{
        .routed = exp.result.routed,
        .total = exp.result.total,
        .drc_errors = errors,
        .kept = kept,
        .why = why,
    };
}

/// Every channel worth probing, keystone first.
///
/// A declared differential pair leads because a pair is the one structure that
/// occupies a corridor it cannot share: when its envelope has no alternative,
/// every signal wanting that corridor is blocked by geometry rather than by
/// routing order. Then each still-open net's SHORTEST closing hop — the oracle's
/// own aiming data, so the probe asks about the same gap `add_tracks` would.
fn buildAims(alloc: std.mem.Allocator, in: Input) std.mem.Allocator.Error![]const place_repair.Aim {
    var out: std.ArrayList(place_repair.Aim) = .empty;
    for (in.placement.diff_pairs) |pair| {
        if (out.items.len >= max_aims) break;
        if (pair.p >= in.placement.nets.len or pair.n >= in.placement.nets.len) continue;
        var ends = (try pinch_probe.pairEnds(alloc, in.placement, pair)) orelse continue;
        // A controlled-impedance pair runs on the layer its class NAMES, which
        // for a coupled stripline is an inner one — not the face its pads sit
        // on. Probing the pad face would answer about a corridor the pair never
        // uses, so the declared layer wins where there is one.
        if (declaredLayer(in.placement, pair.p)) |sig| ends.layer = sig;
        const tw = netWidth(in, pair.p);
        // BOTH legs' copper comes off for a pair. `skip_net` takes one net, and
        // a pair is re-homed as one unit — leaving the twin's copper standing
        // would have the pair's own N leg named as the wall its P leg cannot
        // pass, which is a diagnosis about a route that is about to be torn up
        // rather than about the placement.
        const bare = try withoutNets(alloc, in.baseline.result, .{ @intCast(pair.p), @intCast(pair.n) });
        try out.append(alloc, .{
            .label = try std.fmt.allocPrint(alloc, "{s}/{s}", .{
                in.placement.nets[pair.p].name,
                in.placement.nets[pair.n].name,
            }),
            .net = @intCast(pair.p),
            .ends = ends,
            // The envelope both legs and their intra-pair gap have to fit in —
            // the same substitution the coupled construction makes.
            .width = 2 * tw + pair.gap,
            .clearance = netClearance(in, pair.p),
            .tracks = bare.tracks,
            .vias = bare.vias,
        });
    }
    for (in.baseline.open_nets) |open| {
        if (out.items.len >= max_aims) break;
        if (open.gaps.len == 0) continue;
        const net_i = netIndex(in.placement, open.net) orelse continue;
        const gap = open.gaps[0];
        try out.append(alloc, .{
            .label = open.net,
            .net = @intCast(net_i),
            .ends = .{
                .from = .{ gap.from.x, gap.from.y },
                .to = .{ gap.to.x, gap.to.y },
                .layer = sideLayer(gap.from.side),
            },
            .width = netWidth(in, net_i),
            .clearance = netClearance(in, net_i),
            .tracks = in.baseline.result.tracks,
            .vias = in.baseline.result.vias,
        });
    }
    return out.toOwnedSlice(alloc);
}

/// The signal layer a net's class declared for it through `(impedance …
/// (layer N))` / `(diff-impedance … (layer N))`, as a signal index the probe can
/// mesh. Null when the class named none, or named a copper layer this board
/// carries no signal index for (a plane) — in which case the caller keeps the
/// pads' own face rather than meshing a layer the net cannot use.
fn declaredLayer(placement: optimizer.Placement, net_i: usize) ?u8 {
    if (net_i >= placement.rules.net.len) return null;
    const stack = placement.rules.net[net_i].rf.impedance.layer;
    if (stack == 0) return null;
    const n = placement.rules.signalLayerCount();
    var sig: u8 = 0;
    while (sig < n) : (sig += 1) {
        if (placement.rules.signalStackIndex(sig) == stack) return sig;
    }
    return null;
}

/// The board's copper with two nets' own runs removed — what a pair's envelope
/// would be searched against once the pair itself is lifted off.
fn withoutNets(
    alloc: std.mem.Allocator,
    result: router.RouteResult,
    drop: [2]i32,
) std.mem.Allocator.Error!struct { tracks: []const router.Track, vias: []const router.Via } {
    var tracks: std.ArrayList(router.Track) = .empty;
    for (result.tracks) |t| {
        if (t.net == drop[0] or t.net == drop[1]) continue;
        try tracks.append(alloc, t);
    }
    var vias: std.ArrayList(router.Via) = .empty;
    for (result.vias) |v| {
        if (v.net == drop[0] or v.net == drop[1]) continue;
        try vias.append(alloc, v);
    }
    return .{ .tracks = try tracks.toOwnedSlice(alloc), .vias = try vias.toOwnedSlice(alloc) };
}

/// This net's effective track width — the `(net-class …)` overlay on the board
/// default, exactly as the router resolves it.
fn netWidth(in: Input, net_i: usize) f64 {
    if (net_i < in.placement.rules.net.len) {
        const w = in.placement.rules.net[net_i].width;
        if (w > 0) return w;
    }
    return in.params.track_width;
}

/// This net's effective clearance, resolved the same way.
fn netClearance(in: Input, net_i: usize) f64 {
    if (net_i < in.placement.rules.net.len) {
        const c = in.placement.rules.net[net_i].clearance;
        if (c > 0) return c;
    }
    return in.params.clearance;
}

fn netIndex(placement: optimizer.Placement, name: []const u8) ?usize {
    for (placement.nets, 0..) |net, i| {
        if (std.mem.eql(u8, net.name, name)) return i;
    }
    return null;
}

/// The signal layer a pad on this side sits on.
fn sideLayer(side: optimizer.Side) u8 {
    return if (side == .bottom) 1 else 0;
}

/// One named verdict line per pinch, per move and per refusal, so a run whose
/// trial never finishes has still SAID what it found.
fn logPlan(placement: optimizer.Placement, probed: []const []const u8, plan: place_repair.Plan) void {
    for (probed) |label| {
        var walled = false;
        for (plan.findings) |f| {
            if (std.mem.eql(u8, f.label, label)) walled = true;
        }
        if (!walled) repairLog("placement repair: probed {s} — a corridor exists, nothing to widen", .{label});
    }
    for (plan.findings) |f| {
        repairLog("placement repair: pinch {s} — {s} vs {s} need {d:.3}mm have {d:.3}mm at ({d:.3},{d:.3}) L{d}", .{
            f.label,
            ownerName(placement, f.pinch.a, f.a_ref),
            if (f.pinch.b) |other| ownerName(placement, other, f.b_ref) else "the same body",
            f.pinch.need_mm,
            f.pinch.have_mm,
            f.pinch.at[0],
            f.pinch.at[1],
            f.pinch.layer,
        });
    }
    for (plan.moves) |m| {
        repairLog("placement repair: moving {s} ({d:.3},{d:.3})mm to open {s}", .{
            m.ref,
            m.to[0] - m.from[0],
            m.to[1] - m.from[1],
            m.label,
        });
    }
    for (plan.refusals) |r| {
        repairLog("placement repair: {s} not moved for {s} — {s}", .{
            if (r.ref.len > 0) r.ref else "the pinch owner",
            r.label,
            r.why.text(),
        });
    }
}

/// What to call one side of a wall: its part when it has one, else its net, else
/// what kind of thing it is.
fn ownerName(placement: optimizer.Placement, owner: pinch_probe.Owner, ref: []const u8) []const u8 {
    if (ref.len > 0) return ref;
    if (owner.kind == .keepout) return "a keepout or the board edge";
    if (owner.net < 0) return "unowned copper";
    const ni: usize = @intCast(owner.net);
    if (ni >= placement.nets.len) return "unowned copper";
    return placement.nets[ni].name;
}

// ── JSON ─────────────────────────────────────────────────────────────────────

/// The `,"placement_repair":{…}` block: what was walled, what moved, and how the
/// trial went. `moves[]` is deliberately shaped as `set_part_poses` takes it, so
/// an accepted trial is one call away from being a saved layout — this tool
/// persists nothing itself.
pub fn writeRepairJson(w: *std.Io.Writer, placement: optimizer.Placement, out: Outcome) json_writer.WriteError!void {
    try w.writeAll(",\"placement_repair\":{\"verdict\":");
    try json_writer.writeString(w, out.verdict);
    try w.writeAll(",\"probed\":[");
    for (out.probed, 0..) |label, i| {
        if (i > 0) try w.writeAll(",");
        try json_writer.writeString(w, label);
    }
    try w.writeAll("],\"pinches\":[");
    for (out.plan.findings, 0..) |f, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"channel\":");
        try json_writer.writeString(w, f.label);
        try w.writeAll(",\"a\":");
        try json_writer.writeString(w, ownerName(placement, f.pinch.a, f.a_ref));
        try w.writeAll(",\"b\":");
        const b_name = if (f.pinch.b) |other| ownerName(placement, other, f.b_ref) else "the same body";
        try json_writer.writeString(w, b_name);
        try w.print(",\"need_mm\":{d:.4},\"have_mm\":{d:.4},\"x\":{d:.3},\"y\":{d:.3},\"layer\":{d}}}", .{
            f.pinch.need_mm,
            f.pinch.have_mm,
            f.pinch.at[0],
            f.pinch.at[1],
            f.pinch.layer,
        });
    }
    try w.writeAll("],\"moves\":[");
    for (out.plan.moves, 0..) |m, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"ref\":");
        try json_writer.writeString(w, m.ref);
        try w.writeAll(",\"opens\":");
        try json_writer.writeString(w, m.label);
        try w.print(",\"x\":{d:.3},\"y\":{d:.3},\"from_x\":{d:.3},\"from_y\":{d:.3},\"dist_mm\":{d:.3}}}", .{
            m.to[0],
            m.to[1],
            m.from[0],
            m.from[1],
            m.distMm(),
        });
    }
    try w.writeAll("],\"refused\":[");
    for (out.plan.refusals, 0..) |r, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"ref\":");
        try json_writer.writeString(w, r.ref);
        try w.writeAll(",\"channel\":");
        try json_writer.writeString(w, r.label);
        try w.writeAll(",\"why\":");
        try json_writer.writeString(w, r.why.text());
        try w.writeAll("}");
    }
    try w.writeAll("]");
    if (out.trial) |t| {
        try w.print(",\"trial\":{{\"routed\":{d},\"total\":{d},\"drc_errors\":{d},\"kept\":{}}}", .{
            t.routed,
            t.total,
            t.drc_errors,
            t.kept,
        });
    }
    try w.writeAll("}");
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;
const mcp_tools = @import("serve/mcp_tools.zig");

test {
    testing.refAllDecls(@This());
}

/// A placement with `n` nets and no parts — enough to exercise the naming and
/// per-net rule lookups without a board.
fn netsOnly(nets: []const optimizer.FlatNet) optimizer.Placement {
    return .{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 0,
        .maxy = 0,
        .generated = true,
    };
}

// spec: route_repair - a repair pass with nothing to probe reports that it had no aim rather than claiming the board is clear
test "a board with no pair and no open net has nothing to probe" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const p = netsOnly(&.{});
    const out = try run(arena_state.allocator(), .{
        .project_dir = ".",
        .name = "fixture",
        .block = undefined,
        .placement = p,
        .params = .{},
        .opts = .{},
        .baseline = .{
            .result = .{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 0 },
            .drc_errors = 0,
            .open_nets = &.{},
        },
    });
    try testing.expectEqual(@as(usize, 0), out.plan.findings.len);
    try testing.expect(out.trial == null);
    try testing.expectEqualStrings("no aim to probe", out.verdict);
}

// spec: route_repair - a pinch side is named by the part carrying it, falling back to its net and then to what kind of body it is
test "a wall side is named by part, then net, then kind" {
    const nets = [_]optimizer.FlatNet{.{ .name = "V_3V3A", .pins = &.{} }};
    const p = netsOnly(&nets);
    try testing.expectEqualStrings("C41", ownerName(p, .{ .kind = .pad, .net = 0 }, "C41"));
    try testing.expectEqualStrings("V_3V3A", ownerName(p, .{ .kind = .track, .net = 0 }, ""));
    try testing.expectEqualStrings("a keepout or the board edge", ownerName(p, .{ .kind = .keepout }, ""));
    try testing.expectEqualStrings("unowned copper", ownerName(p, .{ .kind = .track, .net = 9 }, ""));
}

// spec: route_repair - repair_placement is an argument of the read-only route_experiment tool, so a repair pass persists nothing
test "the repair pass rides a read-only tool" {
    try testing.expect(mcp_tools.isKnownTool("route_experiment"));
    try testing.expect(!mcp_tools.isMutationTool("route_experiment"));
    // The argument is declared in the embedded tool listing, whose input schemas
    // are `additionalProperties:false` — an undeclared argument is refused by a
    // strict client before the handler ever sees it.
    try testing.expect(std.mem.indexOf(u8, mcp_tools.tools_list_result, "repair_placement") != null);
}

// spec: route_repair - a repair JSON block always names its verdict and its four lists, so a channel probed and found clear is legible rather than silently absent
test "an empty repair block still carries its verdict and lists" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeRepairJson(&aw.writer, netsOnly(&.{}), .{ .verdict = "no aim to probe" });
    const s = aw.written();
    try testing.expect(std.mem.indexOf(u8, s, "\"placement_repair\":{") != null);
    try testing.expect(std.mem.indexOf(u8, s, "\"verdict\":\"no aim to probe\"") != null);
    try testing.expect(std.mem.indexOf(u8, s, "\"probed\":[]") != null);
    try testing.expect(std.mem.indexOf(u8, s, "\"pinches\":[]") != null);
    try testing.expect(std.mem.indexOf(u8, s, "\"moves\":[]") != null);
    try testing.expect(std.mem.indexOf(u8, s, "\"refused\":[]") != null);
    // No trial ran, so no trial is claimed.
    try testing.expect(std.mem.indexOf(u8, s, "\"trial\"") == null);
}
