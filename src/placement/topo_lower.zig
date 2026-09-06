//! Lower a RESOLVED `(pcb-plan (route …))` into global-topology corridor
//! guides — the bridge between `plan_resolve` (which says WHICH nets are in
//! which wave) and `topo_plan` (which says WHERE each of them should run).
//!
//! It is deliberately one function with one merge point. `serve/route_plan`'s
//! `resolveOptions` is its only caller, so every routing surface picks the
//! planner up from the same place it picks wave priority and layer masks up
//! from, and preview can never disagree with commit.
//!
//! Three rules govern what actually reaches the router:
//!
//!   * **Opt-in.** Nothing runs unless some resolved route wave carries
//!     `(topology)` (or the caller forces it request-locally). A plan without
//!     the form leaves `options.guides` byte-identical to what it was.
//!   * **Every wave up to the last flagged one is planned, only flagged waves
//!     are emitted.** An unflagged wave BEFORE a flagged one is still handed to
//!     the planner, because the flagged wave's answer depends on it: earlier
//!     waves are stamped in as consumed capacity, later ones pull at a light
//!     background weight. Dropping those would plan a different board. The
//!     `emit` mask is what keeps their nets from receiving guides. A wave AFTER
//!     the last flagged one is a different case — its stamps are read only by
//!     waves later still, and its guides are filtered out — so `Wave.emit`
//!     carries the flag down and `topo_plan` stops there rather than relaxing
//!     work nothing consumes.
//!   * **The author outranks the planner.** A net whose wave authored
//!     `(waypoints …)`, or that an `(assign-escapes …)` wave already aimed a
//!     lane guide at, is offered to the planner as pure DEMAND (it consumes
//!     corridor space so its neighbours plan around it) and is never given a
//!     guide of its own — enforced both inside `topo_plan` (`demandOnly`) and
//!     again here at the merge.
//!
//! Pure: one allocator in, deterministic slices out. No disk, no globals.

const std = @import("std");
const optimizer = @import("optimizer.zig");
const plan_resolve = @import("plan_resolve.zig");
const route_policy = @import("route_policy.zig");
const topo_plan = @import("topo_plan.zig");
const diff_pairs = @import("diff_pairs.zig");
const implicit_plane = @import("implicit_plane.zig");

const Allocator = std.mem.Allocator;

/// What one planner run did, for a caller's result JSON. Small on purpose —
/// the per-net story lives in `topo_plan.NetDiag`, and the debug overlay that
/// renders it is deferred.
pub const Stats = struct {
    /// Route waves the planner relaxed. An unflagged wave counts too when a
    /// flagged one follows it — it is planned for the capacity and demand
    /// context it gives its neighbours — but a wave behind the LAST flagged one
    /// is not planned at all and never counts (see the header).
    waves_planned: usize = 0,
    /// Nets whose planned backbone actually became guides in `options.guides`.
    guides_emitted: usize = 0,
    /// Nets that would have been emitted but whose flow never committed to one
    /// corridor, so the confidence gate refused to assert a topology.
    nets_skipped_low_confidence: usize = 0,
};

/// One merge request: the resolved plan, the placement it was resolved against,
/// and whether the caller forces topology planning on every route wave for this
/// run only (`route_experiment`'s request-local override).
pub const Request = struct {
    plan: plan_resolve.ResolvedPlan,
    placement: optimizer.Placement,
    force: bool = false,
};

/// Plan a global topology for `req` and merge its corridor guides into
/// `options.guides`, AFTER the guides already there (the `(assign-escapes …)`
/// lanes, which keep their nets to themselves). Returns null and leaves
/// `options` untouched when no route wave opted in, so a plan with no
/// `(topology)` hands the router exactly the options it always did.
pub fn merge(
    alloc: Allocator,
    req: Request,
    options: *route_policy.Options,
) Allocator.Error!?Stats {
    if (!wanted(req)) return null;
    const input = try buildInput(alloc, req, options.*);
    const planned = try topo_plan.plan(alloc, &req.placement, input.waves, .{});
    // Field-wise, not a whole-struct replacement: the bundle also carries the
    // hard reserved lanes, and a topology merge has no business dropping them.
    options.guides.tracks = try merged(route_policy.GuideTrack, alloc, options.guides.tracks, planned.tracks, input.emit);
    options.guides.vias = try merged(route_policy.GuideVia, alloc, options.guides.vias, planned.vias, input.emit);
    return statsOf(planned, input.emit);
}

/// True when this run must plan a topology: the caller forced it, or some
/// resolved route wave carries `(topology)`. A plan with no route waves has
/// nothing to plan either way.
fn wanted(req: Request) bool {
    if (req.plan.route.len == 0) return false;
    if (req.force) return true;
    for (req.plan.route) |wave| {
        if (wave.steering.topology) return true;
    }
    return false;
}

/// The planner's inputs: every route wave in authored order, plus the
/// index-aligned mask of nets allowed to RECEIVE a guide (see the header).
const Input = struct {
    waves: []const topo_plan.Wave,
    emit: []const bool,
};

fn buildInput(alloc: Allocator, req: Request, options: route_policy.Options) Allocator.Error!Input {
    const facts = Facts{
        .placement = req.placement,
        .policies = options.net,
        .guides = options.guides.tracks,
        .pairs = try diff_pairs.resolve(alloc, req.placement.nets, req.placement.rules.net),
    };
    const emit = try alloc.alloc(bool, req.placement.nets.len);
    @memset(emit, false);
    var waves: std.ArrayList(topo_plan.Wave) = .empty;
    for (req.plan.route) |wave| {
        const flagged = req.force or wave.steering.topology;
        var nets: std.ArrayList(topo_plan.NetInput) = .empty;
        for (wave.members) |net_i| {
            if (net_i >= emit.len) continue;
            const in = netInput(facts, net_i);
            if (flagged and !in.has_authored_guide) emit[net_i] = true;
            try nets.append(alloc, in);
        }
        try waves.append(alloc, .{ .nets = try nets.toOwnedSlice(alloc), .emit = flagged });
    }
    return .{ .waves = try waves.toOwnedSlice(alloc), .emit = emit };
}

/// Everything one net's planner input is read off, all index-aligned with
/// `placement.nets`.
const Facts = struct {
    placement: optimizer.Placement,
    policies: []const route_policy.NetPolicy,
    guides: []const route_policy.GuideTrack,
    pairs: []const diff_pairs.DiffPair,
};

/// Net `net_i`'s planner input. `width`/`clearance` come from the SAME per-net
/// rule `router.setNetParams` reads, so the cross-section the planner reserves
/// is the one the maze will actually draw; `allowed_layers` is the mask
/// `routePolicies` already folded from this net's wave, so the planner cannot
/// route through a layer the router will refuse.
fn netInput(f: Facts, net_i: usize) topo_plan.NetInput {
    const rule: optimizer.NetRule = if (net_i < f.placement.rules.net.len)
        f.placement.rules.net[net_i]
    else
        .{};
    const policy: route_policy.NetPolicy = if (net_i < f.policies.len) f.policies[net_i] else .{};
    return .{
        .net = net_i,
        .width = rule.width,
        .clearance = rule.clearance,
        .allowed_layers = policy.allowed_layers,
        .has_authored_guide = policy.waypoints.len > 0 or hasGuide(f.guides, net_i),
        .is_diff_pair = paired(f.pairs, net_i),
        .is_plane_carried = planeCarried(f.placement, net_i),
    };
}

/// Does a copper plane or pour carry this net? Same rule as
/// `fab_readiness.netHasPlane` — a declared `(stackup …)` carries exactly its
/// `(plane …)`/`(pour …)` nets, and no stackup form keeps the legacy implicit
/// model (`implicit_plane.carries`: every ground-named net, plus the block's
/// dominant supply rail when one qualified). Spelled here off `BoardRules`
/// rather than imported, because `fab_readiness` pulls the whole router in and
/// this module is on the pure placement side of that line.
///
/// Such a net needs no corridor: the plane already reaches every one of its
/// pads. Planning one is the most expensive thing the planner can do (a rail on
/// fifty pads is fifty terminals of star flow) for an answer nothing reads —
/// board-a's `GND` was landing on `no_path` by accident, which was the right
/// outcome reached the wrong way.
fn planeCarried(pl: optimizer.Placement, net_i: usize) bool {
    if (net_i >= pl.nets.len) return false;
    const name = pl.nets[net_i].name;
    if (!pl.rules.declaredStackup()) return implicit_plane.carries(pl.rules, name);
    return pl.rules.carriesPlane(name);
}

/// True when a guide already targets this net — today that is an
/// `(assign-escapes …)` lane, the one guide source that runs before this one.
fn hasGuide(guides: []const route_policy.GuideTrack, net_i: usize) bool {
    for (guides) |g| {
        if (asNet(g.net)) |i| {
            if (i == net_i) return true;
        }
    }
    return false;
}

/// True when this net is one half of a resolved differential pair — the pair's
/// coupling owns its shape, so a corridor guide would fight it.
fn paired(pairs: []const diff_pairs.DiffPair, net_i: usize) bool {
    for (pairs) |pair| {
        if (pair.p == net_i or pair.n == net_i) return true;
    }
    return false;
}

/// A guide's `i32` net key as an index, or null for the negative sentinel.
fn asNet(net: i32) ?usize {
    if (net < 0) return null;
    return @intCast(net);
}

fn mayEmit(emit: []const bool, net_i: usize) bool {
    return net_i < emit.len and emit[net_i];
}

/// Keep the guides already in `base`, then append every planned one whose net
/// the emit mask allows. `T` is `GuideTrack` or `GuideVia`; both key on `net`.
fn merged(
    comptime T: type,
    alloc: Allocator,
    base: []const T,
    planned: []const T,
    emit: []const bool,
) Allocator.Error![]const T {
    var out: std.ArrayList(T) = .empty;
    try out.appendSlice(alloc, base);
    for (planned) |g| {
        const net_i = asNet(g.net) orelse continue;
        if (mayEmit(emit, net_i)) try out.append(alloc, g);
    }
    return out.toOwnedSlice(alloc);
}

/// Fold the per-net diagnoses into the caller-facing counts. Waves are counted
/// off the diag stream directly: `topo_plan` emits one diag per net in wave
/// order, so a change of `wave` starts a new one.
fn statsOf(planned: topo_plan.Plan, emit: []const bool) Stats {
    var out = Stats{};
    var last: ?usize = null;
    for (planned.diags) |d| {
        if (last == null or last.? != d.wave) {
            out.waves_planned += 1;
            last = d.wave;
        }
        if (!mayEmit(emit, d.net)) continue;
        if (d.emitted) out.guides_emitted += 1;
        if (d.reason == .low_confidence) out.nets_skipped_low_confidence += 1;
    }
    return out;
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;
const geometry = @import("geometry.zig");
const flat_netlist = @import("../flat_netlist.zig");

const one_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};

fn padPart(ref: []const u8, x: f64, y: f64) optimizer.Part {
    return .{
        .ref_des = ref,
        .kind = .passive,
        .hw = 0.5,
        .hh = 0.5,
        .pads = &one_pad,
        .fallback = false,
        .x = x,
        .y = y,
    };
}

/// Two independent two-pad nets on separate rows — one net per wave, so a plan
/// can flag one wave and leave the other alone.
fn fixtureParts() [4]optimizer.Part {
    return .{
        padPart("R1", 0, 0),
        padPart("R2", 3, 0),
        padPart("R3", 0, 3),
        padPart("R4", 3, 3),
    };
}

const pins_a = [_]flat_netlist.FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } };
const pins_b = [_]flat_netlist.FlatPin{ .{ .ref_des = "R3", .pin = "1" }, .{ .ref_des = "R4", .pin = "1" } };

const fixture_nets = [_]flat_netlist.FlatNet{
    .{ .name = "A", .pins = &pins_a },
    .{ .name = "B", .pins = &pins_b },
};

fn fixturePlacement(parts: []optimizer.Part) optimizer.Placement {
    return .{
        .parts = parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &fixture_nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -0.5,
        .miny = -0.5,
        .maxx = 3.5,
        .maxy = 3.5,
        .generated = true,
    };
}

/// One resolved wave claiming `members`, flagged or not.
fn resolvedWave(name: []const u8, members: []const usize, topology: bool) plan_resolve.ResolvedWave {
    return .{ .name = name, .members = members, .steering = .{ .topology = topology } };
}

fn netsWithGuides(tracks: []const route_policy.GuideTrack) [2]bool {
    var seen = [_]bool{ false, false };
    for (tracks) |t| {
        if (asNet(t.net)) |i| {
            if (i < seen.len) seen[i] = true;
        }
    }
    return seen;
}

// spec: Topology planner - only a topology-flagged wave's nets are given guides, while an unflagged wave is still planned for its capacity
test "an unflagged wave is planned but never emitted" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var parts = fixtureParts();
    // The unflagged wave runs FIRST, which is the case its planning pays for:
    // the flagged wave behind it is planned around the capacity it consumed.
    const waves = [_]plan_resolve.ResolvedWave{
        resolvedWave("rest", &.{1}, false),
        resolvedWave("planned", &.{0}, true),
    };
    var options = route_policy.Options{};
    const stats = try merge(arena, .{
        .plan = .{ .route = &waves },
        .placement = fixturePlacement(&parts),
    }, &options) orelse return error.PlannerDidNotRun;

    const seen = netsWithGuides(options.guides.tracks);
    try testing.expect(seen[0]);
    try testing.expect(!seen[1]);
    // Both waves were relaxed even though only one may emit.
    try testing.expectEqual(@as(usize, 2), stats.waves_planned);
    try testing.expectEqual(@as(usize, 1), stats.guides_emitted);
}

// spec: Topology planner - planning stops after the last guide-emitting wave, whose capacity stamps no later wave reads
test "a wave behind the last flagged one is never planned" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var parts = fixtureParts();
    const waves = [_]plan_resolve.ResolvedWave{
        resolvedWave("planned", &.{0}, true),
        resolvedWave("rest", &.{1}, false),
    };
    var options = route_policy.Options{};
    const stats = try merge(arena, .{
        .plan = .{ .route = &waves },
        .placement = fixturePlacement(&parts),
    }, &options) orelse return error.PlannerDidNotRun;

    // Same two waves as above, the other way round: the trailing unflagged wave
    // emits nothing and nothing later reads its stamps, so it is not relaxed.
    try testing.expectEqual(@as(usize, 1), stats.waves_planned);
    try testing.expectEqual(@as(usize, 1), stats.guides_emitted);
    const seen = netsWithGuides(options.guides.tracks);
    try testing.expect(seen[0]);
    try testing.expect(!seen[1]);
}

// spec: Topology planner - a plan with no topology-flagged wave never runs the planner and leaves the router's guides untouched
test "an unflagged plan leaves the guides alone" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var parts = fixtureParts();
    const waves = [_]plan_resolve.ResolvedWave{resolvedWave("rest", &.{ 0, 1 }, false)};
    const lane = [_]route_policy.GuideTrack{.{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 0, .layer = 0, .net = 0 }};
    var options = route_policy.Options{ .guides = .{ .tracks = &lane } };
    const stats = try merge(arena, .{
        .plan = .{ .route = &waves },
        .placement = fixturePlacement(&parts),
    }, &options);

    try testing.expect(stats == null);
    try testing.expectEqual(@as(usize, 1), options.guides.tracks.len);
    try testing.expectEqual(@as(i32, 0), options.guides.tracks[0].net);
    try testing.expectEqual(@as(f64, 1), options.guides.tracks[0].x2);
    try testing.expectEqual(@as(usize, 0), options.guides.vias.len);
}

// spec: Topology planner - a net an escape-lane guide already targets keeps that guide and is never given a planner corridor
test "an existing lane guide outranks a planner corridor" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var parts = fixtureParts();
    const waves = [_]plan_resolve.ResolvedWave{resolvedWave("all", &.{ 0, 1 }, true)};
    const lane = [_]route_policy.GuideTrack{.{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 0, .layer = 0, .net = 0 }};
    var options = route_policy.Options{ .guides = .{ .tracks = &lane } };
    const stats = try merge(arena, .{
        .plan = .{ .route = &waves },
        .placement = fixturePlacement(&parts),
    }, &options) orelse return error.PlannerDidNotRun;

    // Net 0 keeps exactly the one lane segment it arrived with; net 1, which
    // nothing authored, is the only one the planner may add corridors for.
    var net0: usize = 0;
    for (options.guides.tracks) |t| {
        if (t.net == 0) net0 += 1;
    }
    try testing.expectEqual(@as(usize, 1), net0);
    try testing.expect(netsWithGuides(options.guides.tracks)[1]);
    try testing.expectEqual(@as(usize, 1), stats.guides_emitted);
}
