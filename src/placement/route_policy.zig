//! Router policy lowered from resolved `(pcb-plan (route …))` waves.
//!
//! This deliberately contains only router-neutral data so `plan_resolve.zig`
//! and `router.zig` can share it without coupling either module to the other.

const std = @import("std");
const board_layers = @import("../board_layers.zig");
const route_space_cache = @import("route_space_cache.zig");
const route_timing = @import("route_timing.zig");
const pair_pinch = @import("pair_pinch.zig");

/// An ordered routing guide point on a named copper layer.
pub const Waypoint = struct {
    x: f64,
    y: f64,
    layer: u8,
};

/// One hard reference-tree branch from terminal 0 to a later terminal. Branch
/// order is terminal order: branch `i` connects terminal 0 to terminal `i + 1`.
pub const GuideBranch = struct {
    waypoints: []const Waypoint = &.{},
};

/// A physical guide must fit inside the net's hard allowed-layer mask.
/// Unlike real pad terminals, virtual guide points cannot authorize a fanout.
pub fn guideLayersAllowed(mask: u64, points: []const Waypoint) bool {
    const layers = board_layers.LayerSet.fromRaw(mask);
    for (points) |point| if (!layers.contains(board_layers.SignalIndex.of(point.layer))) return false;
    return true;
}

/// Per-net policy lowered from one resolved route wave. A zero/empty field
/// preserves the legacy router behaviour.
pub const NetPolicy = struct {
    wave: struct {
        /// Higher values route earlier and protect against lower-wave rip-up.
        priority: u32 = 0,
        /// Route before plane stitching can occupy this wave's corridor.
        before_planes: u32 = 0,
        /// Include this net in the post-route authored-corridor repair.
        seed_first: bool = false,
        /// Ordered hard corridor tried only after the ordinary net attempt
        /// fails, and again by the post-route residual repair.
        repair_waypoints: []const Waypoint = &.{},
        /// The wave's authored `(branches …)` guide tree, still in AUTHORED
        /// order. Unlike `branches` below it is not positional: which limb
        /// serves which terminal is decided geometrically per net, against that
        /// net's own terminals, by `guide_branch.resolve`. Every net in the
        /// wave shares this list, so a tree that covers one of them exactly may
        /// refuse on another; a refusal simply leaves that net unguided.
        branches: []const GuideBranch = &.{},
    } = .{},
    /// Signal-layer bitset used as a cost preference (0 = no preference).
    preferred_layers: u64 = 0,
    /// Signal-layer bitset used as a hard trace constraint (0 = unrestricted).
    allowed_layers: u64 = 0,
    /// Ordered physical points the route must visit. A multi-terminal net uses
    /// them as one shared trunk from its first terminal to every later branch.
    /// Two consecutive points at the same x/y on different layers request a
    /// via at that coordinate.
    waypoints: []const Waypoint = &.{},
    /// Multi-terminal hard reference paths, used only by reference replay.
    branches: []const GuideBranch = &.{},
    /// Emit recovered reference copper verbatim for plane-net replay. This is
    /// an upper-bound experiment mode, never a normal synthesized route.
    replay_reference_copper: bool = false,
    /// Hard per-net total via limit (`null` = unrestricted). Whole-board routes
    /// count retained copper too. Gap callers lower this to a remaining allowance.
    max_vias: ?u16 = null,
};

/// True when a policy authors the layers that its copper must preserve.
pub fn authorsLayers(policy: NetPolicy) bool {
    return policy.preferred_layers != 0 or policy.allowed_layers != 0 or
        policy.waypoints.len > 0 or hasBranchTree(policy);
}

/// True when a policy carries a hard multi-terminal tree — recovered from
/// reference copper, or authored as `(branches …)`. Both spellings mean the
/// same thing to every reader of a policy (layer authorship, guided probe
/// budgets), so they are asked about in one place rather than each caller
/// remembering that there are two fields.
pub fn hasBranchTree(policy: NetPolicy) bool {
    return policy.branches.len > 0 or policy.wave.branches.len > 0;
}

/// Descending priority comparator with a stable net-index tie break.
pub fn priorityDesc(priorities: []const u64, a: usize, b: usize) bool {
    if (priorities[a] != priorities[b]) return priorities[a] > priorities[b];
    return a < b;
}

// spec: placement/router - keeps a layer hop on a net whose policy authors its own layer choices
test "authored layer policies are distinguished from ordering and via limits" {
    try std.testing.expect(!authorsLayers(.{}));
    try std.testing.expect(!authorsLayers(.{ .wave = .{ .priority = 7 }, .max_vias = 2 }));
    try std.testing.expect(authorsLayers(.{ .preferred_layers = 2 }));
    try std.testing.expect(authorsLayers(.{ .allowed_layers = 1 }));
    const points = [_]Waypoint{
        .{ .x = 1, .y = 0, .layer = 0 },
        .{ .x = 1, .y = 0, .layer = 1 },
    };
    try std.testing.expect(authorsLayers(.{ .waypoints = &points }));
}

// spec: placement/guide-branch - reading an authored tree is a pure extension, so a policy carrying none answers every hard-guide question exactly as it did before the form existed
test "the authored-tree question never changes a policy that carries no tree" {
    const points = [_]Waypoint{.{ .x = 1, .y = 0, .layer = 0 }};
    const reference = [_]GuideBranch{.{ .waypoints = &points }};
    // The three shapes every pre-existing board is one of: nothing authored,
    // waypoints only, and a reference-replay tree. `hasBranchTree` must answer
    // each of them exactly what `policy.branches.len > 0` answered on its own.
    const shapes = [_]NetPolicy{
        .{},
        .{ .waypoints = &points },
        .{ .branches = &reference },
    };
    for (shapes) |policy| {
        try std.testing.expectEqual(policy.branches.len > 0, hasBranchTree(policy));
        try std.testing.expectEqual(
            policy.preferred_layers != 0 or policy.allowed_layers != 0 or
                policy.waypoints.len > 0 or policy.branches.len > 0,
            authorsLayers(policy),
        );
    }
    // Only a WAVE-authored tree makes the two answers diverge, which is the
    // whole of the extension.
    const authored = NetPolicy{ .wave = .{ .branches = &reference } };
    try std.testing.expect(!(authored.branches.len > 0));
    try std.testing.expect(hasBranchTree(authored));
    try std.testing.expect(authorsLayers(authored));
}

/// Preserved routed segment stamped into the maze as an obstacle/source before
/// selected nets route. Coordinates and layer use router signal-layer indices.
pub const ExistingTrack = struct {
    x1: f64,
    y1: f64,
    x2: f64,
    y2: f64,
    layer: u8,
    width: f64,
    net: i32,
};

/// Preserved through-via stamped across every signal layer.
pub const ExistingVia = struct {
    x: f64,
    y: f64,
    dia: f64,
    drill: f64 = 0,
    net: i32,
};

/// A non-copper centerline hint. It never blocks another net; the maze only
/// uses it to lower the cost of a candidate staying near a reference route.
pub const GuideTrack = struct {
    x1: f64,
    y1: f64,
    x2: f64,
    y2: f64,
    layer: u8,
    net: i32,
    width: f64 = 0,
};

/// A copper corridor one net OWNS for the whole run: foreign copper is refused
/// inside it, the owner routes through it freely. The hard counterpart of
/// `GuideTrack` — a guide is a cost bonus a later net may ignore outright,
/// a reservation is a keepout every other net obeys (see `lane_reserve`).
///
/// `width` is the physical corridor width in mm; zero claims exactly the raster
/// nodes the centreline passes through, which is the smallest reservation the
/// grid can express.
pub const ReservedLane = struct {
    x1: f64,
    y1: f64,
    x2: f64,
    y2: f64,
    layer: u8,
    net: i32,
    width: f64 = 0,
};

/// A preferred through-via site recovered from a reference route.
pub const GuideVia = struct {
    x: f64,
    y: f64,
    net: i32,
    dia: f64 = 0,
    drill: f64 = 0,
};

/// Retained filled copper or a routing keepout on one signal layer. Copper
/// regions carry their owning net; keepouts use a negative net and apply the
/// permissions serialized by KiCad.
pub const ExistingZone = struct {
    polygon: []const [2]f64,
    layer: u8,
    net: i32,
    tracks_blocked: bool = false,
    vias_blocked: bool = false,
    copper: bool = true,
    /// KiCad zone-fill priority. Where two different-net pours overlap on one
    /// layer, the strictly-higher priority one owns the overlap and the lower
    /// one's fill is knocked back — so the lower pour has NO COPPER there even
    /// though its polygon covers the point (`pour.clippedByHigher`). A router
    /// that does not carry this aims plane stitches at copper that was never
    /// poured. Default 0 keeps every existing caller's behaviour.
    priority: i64 = 0,
};

/// Live progress callback invoked synchronously once per captured router
/// timeline event, so a background job can stream a route as it happens.
///
/// `ev` is a `*const router.RouteEvent` erased to `*const anyopaque` — this
/// module stays router-neutral (see the header), so the router hands the real
/// event pointer and the consumer restores the type with
/// `@ptrCast(@alignCast(ev))`. The pointer is the arena-owned event just
/// appended to the run's timeline; it is valid ONLY for the duration of the
/// synchronous `emit` call (a later capture may reallocate the backing store),
/// so a consumer that needs to retain it must copy out.
///
/// The sink fires only while the timeline is being captured (the live job
/// always enables it). Because the router backfills each event's total net
/// count at finish, `state.total` reads 0 during streaming — derive progress
/// from `state.routed` or an out-of-band total. A second `.initial` event means
/// the run restarted on a finer grid (see `router.routeWithCapture`); a
/// consumer should reset its accumulated view when it sees one.
pub const ProgressSink = struct {
    ctx: ?*anyopaque,
    emit: *const fn (ctx: ?*anyopaque, ev: *const anyopaque) void,
};

/// Optional policy input for one whole routing run, indexed like Placement.nets.
/// How hard one route tries before it reports a net failed.
///
/// The retry machinery — the escalate/rip-up interleave, the last-resort
/// expansion tier, the windowed fine rescue — was built to squeeze the last
/// nets out of a board unattended. Measured on board-a it does not earn that
/// cost: universal rip-up eligibility bought ZERO nets, the multi-net rip tier
/// and repair cascade were net-NEGATIVE (disabling them closed `TXDATA_ADF`),
/// and failed hops spend seconds to minutes proving a path impossible. Under an
/// agent that reads `stuck[]` and edits the plan, that time is pure latency
/// between iterations, and the agent's next DSL edit is a better move than any
/// rescue the router can invent for itself.
pub const Effort = enum {
    /// One deterministic pass. A net the maze cannot route fails immediately,
    /// with its diagnosis, instead of entering a rescue ladder. The mode for a
    /// human or agent iterating on the plan.
    one_shot,
    /// The historical behaviour: escalate, rip up, re-route, rescue in fine
    /// windows. For an unattended route where wall clock does not matter.
    standard,

    /// May this run enter the escalate / rip-up / rescue machinery at all?
    pub fn retries(self: Effort) bool {
        return self == .standard;
    }

    /// The ONE place a tier NAME becomes a tier. Both the enum's own spelling
    /// (`one_shot`) and the DSL's hyphenated one (`one-shot`) are accepted,
    /// because a caller reads the word out of `(route (effort one-shot))` as
    /// often as out of an API field. Null for anything else, so each caller
    /// decides whether an unrecognised word is an error (`route_experiment`
    /// rejects it) or simply "keep the authored tier" (the viewer's route POST).
    pub fn fromName(text: []const u8) ?Effort {
        if (std.mem.eql(u8, text, "one_shot") or std.mem.eql(u8, text, "one-shot")) return .one_shot;
        if (std.mem.eql(u8, text, "standard")) return .standard;
        return null;
    }
};

/// Everything a resolved plan steers the maze WITH, as opposed to the copper it
/// hands it: the soft reference topology (`tracks`/`vias` — the shape a route is
/// nudged toward, none of it retained as real metal) and the hard lanes
/// (`reserved` — corridors only their own net may cross).
///
/// One struct because they come from one decision. `(assign-escapes …)` solves a
/// contended escape and emits the lanes as guides; `(assign-escapes … (reserve))`
/// emits the SAME lanes twice, once soft and once hard, and a caller that had to
/// carry them in two unrelated places could hand the router a bias toward one
/// corridor while holding a different one open.
pub const Guides = struct {
    /// Permit validated saved module tracks/vias after fresh local routing.
    /// Disable when measuring or generating copper entirely with the router.
    saved_module_routes: bool = true,
    /// Reuse unrestricted fresh local signals as soft paths the global route may revise.
    module_signals_guided: bool = false,
    /// Experimental join-weighted module slices; equal shares preserve the default scheduler.
    module_budget_weighted: bool = false,

    tracks: []const GuideTrack = &.{},
    vias: []const GuideVia = &.{},
    /// Lanes reserved for their owning nets for the WHOLE run (see
    /// `ReservedLane` and `lane_reserve`). Empty for every caller that authors
    /// no `(reserve)`, and the stamp early-outs on empty, so such a run is
    /// byte-identical to one built before the field existed.
    reserved: []const ReservedLane = &.{},
    /// A/B-selectable route-space director for ordinary unguided legs.
    route_space: RouteSpace = .lattice,
    /// The same choice for a COUPLED differential pair's centreline: which
    /// space its envelope-wide channel may be searched in (see `PairChannel`).
    /// A pair is routed as one centreline rather than as two legs, so its
    /// search space is a separate question from `route_space`'s.
    pair_channel: PairChannel = .maze_only,
    /// Where that tier RECORDS the wall it could not pass (see `pair_pinch`).
    /// Null — every run that has ever routed — measures and records nothing; a
    /// caller holding rip authority arms one so a refused pair channel names
    /// copper it could move. It sits beside `pair_channel` because it is that
    /// one tier's output, and a caller arming it without turning the tier on has
    /// asked for the diagnosis of a search that never runs.
    pinch: ?*PinchLog = null,
};

/// Where a coupled pair's envelope search records the wall that stopped it, and
/// which side of that wall a reader is asking about — re-exported so a caller
/// may arm one, and read what it collected, without reaching past the policy
/// surface into the solver's own modules.
pub const PinchLog = pair_pinch.Log;
pub const PinchSide = pair_pinch.Side;

/// Geometry provider used to direct ordinary unconstrained same-layer legs.
/// Scheduling, policy, rip-up, exact acceptance, and every fallback remain in
/// `router.zig`; only the representation of free space differs.
pub const RouteSpace = union(enum) {
    /// Historical whole-board lattice (`route_grid.zig`).
    lattice,
    /// Pour-derived signed-margin field. Its caller supplies recyclable scratch
    /// storage because a high-resolution whole-board query is intentionally
    /// much larger than the result arena and must be released between legs.
    field: struct {
        scratch: std.mem.Allocator,
        /// Optional run-scoped cache of signed-margin fields and path answers.
        /// The field provider remains correct when this is null.
        cache: ?*route_space_cache.Cache = null,
    },

    /// Stable spelling used by benchmark output and experiment ledgers.
    pub fn name(self: RouteSpace) []const u8 {
        return @tagName(self);
    }

    /// Scratch allocator carried only by the field provider.
    pub fn fieldAllocator(self: RouteSpace) ?std.mem.Allocator {
        return switch (self) {
            .lattice => null,
            .field => |config| config.scratch,
        };
    }

    /// Run-scoped reuse cache carried only by the field provider.
    pub fn fieldCache(self: RouteSpace) ?*route_space_cache.Cache {
        return switch (self) {
            .lattice => null,
            .field => |config| config.cache,
        };
    }
};

/// Optional policy input for one whole routing run, indexed like Placement.nets.
pub const Options = struct {
    net: []const NetPolicy = &.{},
    /// How hard this run retries before reporting a net failed (see `Effort`).
    /// Defaults to the historical `standard`, so every existing caller and
    /// every design without an authored `(effort …)` routes exactly as before.
    effort: Effort = .standard,
    /// Index-aligned enable mask. Empty routes every net.
    selected_nets: []const bool = &.{},
    /// Copper retained by a leave-one-net/pair experiment. It is emitted
    /// unchanged in the result and blocks newly routed foreign nets.
    existing_tracks: []const ExistingTrack = &.{},
    existing_vias: []const ExistingVia = &.{},
    existing_zones: []const ExistingZone = &.{},
    /// How this run is STEERED: the soft reference topology and the hard
    /// reserved lanes (see `Guides`).
    guides: Guides = .{},
    /// Internal single-net retry resolution relative to the base grid pitch.
    /// Zero selects the router's adaptive default; ignored for multi-net runs.
    grid_scale: f64 = 0,
    /// Live progress sink for a streaming background job. Fires once per
    /// captured timeline event; null (the default) is exactly the batch path.
    /// Only observed when the run captures a timeline (`routeWithTimeline`).
    sink: ?ProgressSink = null,
    /// Request-local cooperative stop policy: an optional external cancel flag
    /// plus the relative/armed wall-clock deadline for this whole transaction.
    stop: Stop = .{},
    /// Optional per-phase wall-clock instrumentation (`bench-route --breakdown`
    /// arms one per board). Null (the default) costs one null check per phase
    /// site and nothing else — the production surfaces never set it.
    timing: ?*route_timing.PhaseTimer = null,
};

/// How hard a COUPLED differential pair looks for the channel its envelope needs.
///
/// The coupled construction routes ONE centreline whose copper profile is the
/// whole pair envelope (`2·width + gap`) and splits it into two exact offset
/// legs. That centreline comes from the raster maze, and a maze answer of "no
/// envelope-wide corridor" is a statement about the LATTICE as much as about the
/// board — the same verdict the gridless mesh already answers for single nets
/// (`router.shapeInput` into `cdt_layers.route`).
///
/// `maze_only` is every existing caller and keeps every board byte-identical.
/// `mesh_behind_maze` lets a pair whose maze found nothing re-ask the mesh, at
/// the envelope width, and hand what it finds to the same leg construction and
/// the same exact clearance probe — so a mesh channel is accepted on precisely
/// the terms a maze channel is, or not at all.
pub const PairChannel = enum {
    maze_only,
    mesh_behind_maze,

    /// May the mesh be asked once the maze has declined?
    pub fn meshes(self: PairChannel) bool {
        return self == .mesh_behind_maze;
    }
};

/// Request-local cooperative stop conditions shared by every attempt in one
/// routing transaction.
pub const Stop = struct {
    cancel: ?*std.atomic.Value(bool) = null,
    /// Relative wall-clock allowance. Zero preserves the historical behavior.
    max_route_ms: u64 = 0,
    /// Armed once by the outer transaction, then copied through every retry.
    deadline_ns: i128 = 0,
};

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: placement/route-effort - an authored (effort one-shot) route skips the escalate, rip-up and fine-rescue machinery entirely
test "one_shot refuses the retry machinery and standard allows it" {
    try testing.expect(!Effort.one_shot.retries());
    try testing.expect(Effort.standard.retries());
}

// spec: placement/route-effort - a design with no authored effort routes exactly as it did before the form existed
test "the default effort is the historical behaviour" {
    const defaults = Options{};
    try testing.expectEqual(Effort.standard, defaults.effort);
    try testing.expect(defaults.effort.retries());
}

// spec: placement/route-effort - a tier name becomes a tier through one shared spelling that takes the enum and DSL forms and rejects anything else
test "a tier name maps onto the tier in both its spellings" {
    // The DSL writes `(effort one-shot)`; an API field writes the enum's own
    // `one_shot`. Both name the same tier, which is why there is one mapping.
    try testing.expectEqual(Effort.one_shot, Effort.fromName("one_shot") orelse return error.TestNoTier);
    try testing.expectEqual(Effort.one_shot, Effort.fromName("one-shot") orelse return error.TestNoTier);
    try testing.expectEqual(Effort.standard, Effort.fromName("standard") orelse return error.TestNoTier);
    // Anything else is null rather than a silent default, so each caller can
    // decide between rejecting a typo and keeping the authored tier.
    try testing.expect(Effort.fromName("") == null);
    try testing.expect(Effort.fromName("ONE_SHOT") == null);
    try testing.expect(Effort.fromName("oneshot") == null);
    try testing.expect(Effort.fromName("fast") == null);
}
