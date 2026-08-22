//! PCB-completion plan *resolution* — the second half of the `(pcb-plan …)`
//! feature (wave 1A parsed + stored the form; this turns it into concrete
//! member sets). Given the parsed `?PcbPlanSpec` and the solved
//! design/placement context, `resolve` produces a `ResolvedPlan`: each place
//! wave's selector names expanded to part indices (into `Placement.parts`) and
//! each route wave's to net indices (into `Placement.nets`, the order
//! `fab_readiness.netConnectivity` reports), with unresolved selector entries
//! collected as `warnings` rather than dropped.
//!
//! Like `progress.zig` (its downstream consumer) this is a PURE function of its
//! inputs — no disk, no re-solve — so the ladder's placement/routing rungs can
//! be split per wave off the same facts every read surface sees. Two invariants
//! the callers rely on: **first-wave-wins** (a part/net matched by several waves
//! belongs to the FIRST in document order) and **determinism** (members are
//! emitted in ascending index order; synthesis is a fixed function of the
//! module-policy read), so the same board always yields the identical plan.
//!
//! When no plan is authored (`spec == null`) `resolve` SYNTHESIZES a default
//! from ref-des conventions + `module_policy` detection: connectors/mechanical,
//! then power (buck/ldo modules + their passives), then main ICs + decoupling,
//! then the rest; routes go high-speed/sensitive, then power, then signals.
//! Empty waves are kept so the plan's shape is stable across designs.

const std = @import("std");
const optimizer = @import("optimizer.zig");
const geometry = @import("geometry.zig");
const pose_math = @import("pose_math.zig");
const module_policy = @import("module_policy.zig");
const route_policy = @import("route_policy.zig");
const escape_assign = @import("escape_assign.zig");
const pour = @import("pour.zig");
const outline_mod = @import("outline.zig");
const env = @import("../eval/env.zig");

const Allocator = std.mem.Allocator;
const NetClass = module_policy.NetClass;
const PartRole = module_policy.PartRole;
const ModuleClass = module_policy.ModuleClass;

/// FNV-1a offset basis and prime — the same constants `progress.zig` /
/// `drc_json.zig` fold a stable 4-hex id with, so a warning's id is minted by
/// the identical scheme.
const fnv_offset: u32 = 0x811c9dc5;
const fnv_prime: u32 = 0x01000193;

/// One unresolved-selector finding: a wave named a ref/section/sub-block/
/// net-class/net that exists nowhere in the design. `id` is a stable 4-hex hash
/// (wave + entry), `wave`/`name` locate it, `message` is the human line. Never
/// an error — the plan resolves around it, and the caller surfaces it as a lint.
pub const Warning = struct {
    id: []const u8,
    kind: []const u8,
    message: []const u8,
    wave: []const u8,
    name: []const u8,
};

/// A route wave's authored signal-layer restrictions, carried verbatim as the
/// KiCad layer NAMES the author wrote: `preferred` biases the maze toward those
/// layers while leaving fallbacks open, `allowed` restricts trace bodies to
/// them. Names are validated against the solved stackup in `resolveAuthored`
/// (an unknown one becomes a plan warning) and folded into layer masks by
/// `routePolicies`. Empty on a place wave and on an unrestricted route wave.
const WaveLayers = struct {
    preferred: []const []const u8 = &.{},
    allowed: []const []const u8 = &.{},
};

const WaveSteering = struct {
    topology: bool = false,
    seed_first: bool = false,
    repair_waypoints: []const env.PlanWaypoint = &.{},
    /// The wave's authored `(branches …)` guide tree, carried verbatim. Its
    /// limbs are bound to a net's terminals geometrically at route time
    /// (`placement/guide_branch`), so nothing here depends on the order the
    /// author happened to write the limbs in.
    branches: []const env.PlanBranch = &.{},
};

/// One resolved wave: the authored name/reason plus the concrete member indices
/// it claims (part indices for a place wave, net indices for a route wave, both
/// ascending) and whether it is the catch-all `rest` wave.
pub const ResolvedWave = struct {
    name: []const u8,
    reason: ?[]const u8 = null,
    members: []const usize,
    /// The wave's authored signal-layer restrictions (see `WaveLayers`). Kept as
    /// one field because the two lists are always validated and lowered together
    /// — `routePolicies` is their only reader, and it folds both into masks.
    layers: WaveLayers = .{},
    waypoints: []const env.PlanWaypoint = &.{},
    max_vias: ?u16 = null,
    /// Route-wave strategy flags; both are false on place/synthesized waves.
    steering: WaveSteering = .{},
    rest: bool = false,
};

/// The fully resolved plan: ordered place + route waves, the unresolved-name
/// `warnings`, and `synthesized` (true when no `(pcb-plan …)` was authored and
/// the default plan was generated). All slices are arena-owned.
pub const ResolvedPlan = struct {
    place: []const ResolvedWave = &.{},
    route: []const ResolvedWave = &.{},
    warnings: []const Warning = &.{},
    /// Soft per-net lane guides from every `(assign-escapes …)` wave, already
    /// flattened across waves and ready for `route_policy.Options.guides` — see
    /// `escape_assign`. They are router GUIDES, not waypoints: they bias the
    /// maze toward the lane the joint assignment gave each net and can never
    /// fail it. Empty for a plan with no `(assign-escapes …)`, so such designs
    /// hand the router byte-identical options.
    escape_guides: []const route_policy.GuideTrack = &.{},
    /// The same lanes as HARD reservations, from the waves that additionally
    /// authored `(assign-escapes … (reserve))` — ready for
    /// `route_policy.Options.reserved_lanes`. A wave without `(reserve)` — which
    /// is every wave in the corpus today — contributes nothing here, so its
    /// guides stay the only thing the router sees and it routes unchanged.
    escape_reserved: []const route_policy.ReservedLane = &.{},
    /// The authored plan-level `(pcb-plan (topology) …)` flag, carried through
    /// verbatim. Every `route` wave's own `topology` is already true when this
    /// is — this field only records that the opt-in was plan-wide rather than
    /// per wave. False for a synthesized plan.
    topology: bool = false,
    synthesized: bool = false,
};

/// An *ad-hoc* net-scoping selector for incremental routing — the routing-side
/// subset of a wave's selectors, used to route (or clear) only a named group of
/// nets without authoring a `(pcb-plan …)`. Each `groups` token is resolved
/// generically against every net-grouping dimension in priority order: an
/// authored `(net-class "name")`, then a `module_policy` criticality class name
/// (`rf`/`clock`/`switch_node`/…), then a sub-block slug, then a bare net name —
/// whichever first recognizes it. `nets` are matched as net names only. Every
/// match unions into one enable mask, so multiple groups route together.
pub const NetScope = struct {
    /// Generic group tokens (case-insensitive), each resolved against the four
    /// grouping dimensions above in order.
    groups: []const []const u8 = &.{},
    /// Explicit net names (full name or bare leaf, case-insensitive).
    nets: []const []const u8 = &.{},
};

/// A resolved net scope. `mask` is index-aligned with `placement.nets`
/// (`true` = the net is in scope); `matched` counts the selected nets;
/// `unknown` lists the selector tokens that resolved to nothing anywhere (never
/// fatal here — the caller decides whether to error or route what matched);
/// `selectors` is the total selector-token count asked for (0 ⇒ no scope, i.e.
/// route the whole board). All slices are arena-owned.
pub const ResolvedScope = struct {
    mask: []bool,
    matched: usize = 0,
    unknown: []const []const u8 = &.{},
    selectors: usize = 0,
};

/// One named section's members, as the caller reads them off `DesignBlock`:
/// the section name and the (renumber-synced) ref-des of every instance the
/// section declares. The resolver maps each ref back to a part index.
pub const SectionMembers = struct {
    name: []const u8,
    refs: []const []const u8,
};

/// Everything the resolver reads, assembled by the caller so this module stays
/// a pure function. `net_class`/`part_role` are index-aligned with
/// `placement.nets`/`placement.parts` (the `module_policy.analyze` outputs);
/// `sections` and `net_class_specs` come straight off the `DesignBlock`.
pub const Context = struct {
    placement: optimizer.Placement,
    net_class: []const NetClass = &.{},
    part_role: []const PartRole = &.{},
    modules: []const module_policy.ModuleInfo = &.{},
    sections: []const SectionMembers = &.{},
    net_class_specs: []const env.NetClassSpec = &.{},
    /// The shown layout's filled user copper pours, when the caller knows them
    /// (the progress/describe seam does). Read ONLY by the reserved-layer
    /// audit, so the empty default keeps every other caller's resolution
    /// byte-identical.
    zones: []const pour.UserZone = &.{},
};

/// Resolve a plan. An authored `spec` expands its waves; a null `spec`
/// synthesizes the default plan from ref conventions + module policy.
pub fn resolve(arena: Allocator, spec: ?env.PcbPlanSpec, ctx: Context) Allocator.Error!ResolvedPlan {
    if (spec) |s| return resolveAuthored(arena, s, ctx);
    return .{
        .place = try synthesizePlace(arena, ctx),
        .route = try synthesizeRoute(arena, ctx),
        .warnings = &.{},
        .synthesized = true,
    };
}

/// Net-index mask of every net an authored `(assign-escapes …)` route wave
/// hands to the joint escape assigner — the "this escape already has an owner"
/// signal the static escape-contention gate suppresses on
/// (`routability_lint.Options.escapes_assigned`).
///
/// The mask is the waves' resolved MEMBERS, not the lanes the assignment then
/// managed to hand out: a wave that authored the form and got partly refused
/// has already said its piece through `plan-escape-unassigned`, and re-reporting
/// the same fan as an un-owned contention would be the duplicate warning this
/// gate must not add.
///
/// Returns an EMPTY slice — masking nothing — when no wave authors the form,
/// which is every design in the corpus today, so the common path costs one walk
/// over the plan's waves and no resolution at all.
pub fn escapeAssignedMask(
    arena: Allocator,
    spec: ?env.PcbPlanSpec,
    ctx: Context,
) Allocator.Error![]const bool {
    const s = spec orelse return &.{};
    var authored = false;
    for (s.route) |w| {
        if (w.corridor.assign_escapes != null) authored = true;
    }
    if (!authored) return &.{};
    var warns: std.ArrayList(Warning) = .empty;
    var scratch: std.ArrayList(usize) = .empty;
    const route = try resolveRoute(arena, s.route, ctx, &warns, &scratch);
    const mask = try arena.alloc(bool, ctx.placement.nets.len);
    @memset(mask, false);
    // Indexed, not zipped: `resolveRoute` may append an implicit catch-all
    // `rest` wave the authored list has no entry for, so the two slices are not
    // the same length. An authored wave keeps its index — the same pairing
    // `resolveAuthored` lowers its guides on.
    for (s.route, 0..) |w, wi| {
        if (w.corridor.assign_escapes == null or wi >= route.len) continue;
        for (route[wi].members) |n| {
            if (n < mask.len) mask[n] = true;
        }
    }
    return mask;
}

/// `escapeAssignedMask` for a caller that holds a `DesignBlock` and a solved
/// placement and nothing else — the two preflight surfaces. It assembles the
/// resolver context itself, INCLUDING the module-policy read the wave selectors
/// need, but only after the cheap early-out above has proved the design authors
/// the form at all: a board with no `(assign-escapes …)` pays one loop and
/// never runs `module_policy.analyze`.
pub fn escapeAssignedFor(
    arena: Allocator,
    block: *const env.DesignBlock,
    placement: optimizer.Placement,
) Allocator.Error![]const bool {
    const spec = block.pcb_plan orelse return &.{};
    var authored = false;
    for (spec.route) |w| {
        if (w.corridor.assign_escapes != null) authored = true;
    }
    if (!authored) return &.{};
    var policy = try module_policy.analyze(arena, placement);
    defer policy.deinit(arena);
    return escapeAssignedMask(arena, spec, .{
        .placement = placement,
        .net_class = policy.net_class,
        .part_role = policy.part_role,
        .modules = policy.modules,
        .sections = try sectionMembers(arena, block),
        .net_class_specs = block.net_classes,
    });
}

// ── Section membership (caller context helper) ───────────────────────────────

/// Build a `SectionMembers` per `(section …)` (and nested sub-section) of
/// `block`: the section name and the ref-des of every instance it declares,
/// recursively. This is the `Context.sections` a plan's `(sections …)` selector
/// reads — hosted here (the cycle-free module every plan surface already
/// imports) so `serve/pcb_progress` and the `/pcb-layout` blob emitter share
/// one walk instead of each keeping a private copy.
pub fn sectionMembers(
    arena: Allocator,
    block: *const env.DesignBlock,
) Allocator.Error![]const SectionMembers {
    var list: std.ArrayList(SectionMembers) = .empty;
    for (block.sections) |*sec| try addSection(arena, &list, sec);
    return list.toOwnedSlice(arena);
}

/// Append `sec` (name + its instances recursively) and each of its sub-sections,
/// so either a parent- or a sub-section name resolves in a plan.
fn addSection(
    arena: Allocator,
    list: *std.ArrayList(SectionMembers),
    sec: *const env.Section,
) Allocator.Error!void {
    var refs: std.ArrayList([]const u8) = .empty;
    try collectSectionRefs(arena, &refs, sec);
    try list.append(arena, .{ .name = sec.name, .refs = try refs.toOwnedSlice(arena) });
    for (sec.sub_sections) |*ss| try addSection(arena, list, ss);
}

/// Gather every instance ref-des a section declares, recursing its sub-sections.
fn collectSectionRefs(
    arena: Allocator,
    refs: *std.ArrayList([]const u8),
    sec: *const env.Section,
) Allocator.Error!void {
    for (sec.instances) |member| try refs.append(arena, member.ref_des);
    for (sec.sub_sections) |*ss| try collectSectionRefs(arena, refs, ss);
}

// ── Authored resolution ──────────────────────────────────────────────────────

/// Expand every authored place/route wave and gather the unresolved-name
/// warnings into one plan.
fn resolveAuthored(arena: Allocator, spec: env.PcbPlanSpec, ctx: Context) Allocator.Error!ResolvedPlan {
    var warns: std.ArrayList(Warning) = .empty;
    var scratch: std.ArrayList(usize) = .empty;
    var escapes: std.ArrayList(route_policy.GuideTrack) = .empty;
    var reserved: std.ArrayList(route_policy.ReservedLane) = .empty;
    const place = try resolvePlace(arena, spec.place, ctx, &warns, &scratch);
    const route = try resolveRoute(arena, spec.route, ctx, &warns, &scratch);
    for (spec.route, 0..) |wave, wi| {
        for (wave.preferred_layers) |name| if (signalLayerIndex(ctx.placement.rules, name) == null)
            try warns.append(arena, try mkLayerWarning(arena, wave.name, name));
        for (wave.allowed_layers) |name| if (signalLayerIndex(ctx.placement.rules, name) == null)
            try warns.append(arena, try mkLayerWarning(arena, wave.name, name));
        for (wave.corridor.waypoints) |point| if (point.guide == null and signalLayerIndex(ctx.placement.rules, point.layer) == null)
            try warns.append(arena, try mkLayerWarning(arena, wave.name, point.layer));
        for (wave.corridor.repair_waypoints) |point| if (signalLayerIndex(ctx.placement.rules, point.layer) == null)
            try warns.append(arena, try mkLayerWarning(arena, wave.name, point.layer));
        for (wave.corridor.branches) |branch| {
            for (branch.waypoints) |point| if (signalLayerIndex(ctx.placement.rules, point.layer) == null)
                try warns.append(arena, try mkLayerWarning(arena, wave.name, point.layer));
        }
        try branchArityWarnings(arena, wave, route[wi].members, ctx, &warns);
        route[wi].waypoints = try lowerGuides(arena, wave, ctx, &warns);
        try lowerEscapes(arena, .{ .guides = &escapes, .reserved = &reserved }, .{ .wave = wave, .members = route[wi].members, .ctx = ctx }, &warns);
        if (try reservedLayerWarning(arena, wave, route[wi].members, ctx)) |warn|
            try warns.append(arena, warn);
    }
    // A plan-level `(topology)` implies every route wave, including the implicit
    // rest wave `buildWaves` appends (which has no authored `PlanWave` to read a
    // flag from, so the loop above cannot reach it). Place waves keep false —
    // topology planning orders NETS, and `(topology)` is a route-only selector.
    if (spec.topology) for (route) |*w| {
        w.steering.topology = true;
    };
    return .{
        .place = place,
        .route = route,
        .warnings = try warns.toOwnedSlice(arena),
        .escape_guides = try escapes.toOwnedSlice(arena),
        .escape_reserved = try reserved.toOwnedSlice(arena),
        .topology = spec.topology,
        .synthesized = false,
    };
}

/// One selector entry's provenance for a warning: the wave that named it, the
/// entry text, and the human word for its kind ("ref", "section", …).
const Entry = struct { wave: []const u8, name: []const u8, word: []const u8 };

/// Carries the per-resolution mutable state (the claim owner map, the warning
/// sink, and the reusable candidate scratch) so the per-wave claim helpers stay
/// low-arity.
const Claimer = struct {
    arena: Allocator,
    owner: []?usize,
    warns: *std.ArrayList(Warning),
    scratch: *std.ArrayList(usize),

    /// Apply one selector entry: warn when the name resolves to nothing in the
    /// design, else claim every unclaimed candidate for wave `wi`
    /// (first-wave-wins — an already-owned member is left with its earlier
    /// owner). `scratch` holds the candidate indices the matcher just filled.
    fn apply(self: *Claimer, recognized: bool, wi: usize, e: Entry) Allocator.Error!void {
        if (!recognized) {
            try self.warns.append(self.arena, try mkWarning(self.arena, e.wave, e.name, e.word));
            return;
        }
        for (self.scratch.items) |c| {
            if (self.owner[c] == null) self.owner[c] = wi;
        }
    }

    /// Resolve a place wave's three selector kinds (refs, sections, sub-blocks).
    fn place(self: *Claimer, w: env.PlanWave, wi: usize, ctx: Context) Allocator.Error!void {
        for (w.refs) |nm| {
            const ok = try matchRef(ctx, nm, self.scratch, self.arena);
            try self.apply(ok, wi, .{ .wave = w.name, .name = nm, .word = "ref" });
        }
        for (w.sections) |nm| {
            const ok = try matchSection(ctx, nm, self.scratch, self.arena);
            try self.apply(ok, wi, .{ .wave = w.name, .name = nm, .word = "section" });
        }
        for (w.sub_blocks) |nm| {
            const ok = try matchSubBlock(ctx, nm, self.scratch, self.arena);
            try self.apply(ok, wi, .{ .wave = w.name, .name = nm, .word = "sub-block" });
        }
    }

    /// Resolve a route wave's three selector kinds (classes, net-classes, nets).
    fn route(self: *Claimer, w: env.PlanWave, wi: usize, ctx: Context) Allocator.Error!void {
        for (w.classes) |nm| {
            const ok = try matchClass(ctx, nm, self.scratch, self.arena);
            try self.apply(ok, wi, .{ .wave = w.name, .name = nm, .word = "class" });
        }
        for (w.net_classes) |nm| {
            const ok = try matchNetClass(ctx, nm, self.scratch, self.arena);
            try self.apply(ok, wi, .{ .wave = w.name, .name = nm, .word = "net-class" });
        }
        for (w.nets) |nm| {
            const ok = try matchNet(ctx, nm, self.scratch, self.arena);
            try self.apply(ok, wi, .{ .wave = w.name, .name = nm, .word = "net" });
        }
    }
};

/// Resolve the place waves over the part index space.
fn resolvePlace(
    arena: Allocator,
    waves: []const env.PlanWave,
    ctx: Context,
    warns: *std.ArrayList(Warning),
    scratch: *std.ArrayList(usize),
) Allocator.Error![]const ResolvedWave {
    const owner = try arena.alloc(?usize, ctx.placement.parts.len);
    @memset(owner, null);
    var claimer: Claimer = .{ .arena = arena, .owner = owner, .warns = warns, .scratch = scratch };
    var has_rest = false;
    for (waves, 0..) |w, wi| {
        if (w.rest) {
            has_rest = true;
            claimLeftovers(owner, wi);
        } else try claimer.place(w, wi, ctx);
    }
    if (!has_rest) claimLeftovers(owner, waves.len);
    return buildWaves(arena, waves, owner, has_rest, "Everything else");
}

/// Resolve the route waves over the net index space.
fn resolveRoute(
    arena: Allocator,
    waves: []const env.PlanWave,
    ctx: Context,
    warns: *std.ArrayList(Warning),
    scratch: *std.ArrayList(usize),
) Allocator.Error![]ResolvedWave {
    const owner = try arena.alloc(?usize, ctx.placement.nets.len);
    @memset(owner, null);
    var claimer: Claimer = .{ .arena = arena, .owner = owner, .warns = warns, .scratch = scratch };
    var has_rest = false;
    for (waves, 0..) |w, wi| {
        if (w.rest) {
            has_rest = true;
            claimLeftovers(owner, wi);
        } else try claimer.route(w, wi, ctx);
    }
    if (!has_rest) claimLeftovers(owner, waves.len);
    return buildWaves(arena, waves, owner, has_rest, "Remaining nets");
}

/// Freeze the `owner` map into a `ResolvedWave` per authored wave (members in
/// ascending index order), appending an implicit rest wave named `rest_name`
/// when the author declared none.
fn buildWaves(
    arena: Allocator,
    waves: []const env.PlanWave,
    owner: []const ?usize,
    has_rest: bool,
    rest_name: []const u8,
) Allocator.Error![]ResolvedWave {
    const extra: usize = if (has_rest) 0 else 1;
    const list = try arena.alloc(ResolvedWave, waves.len + extra);
    for (waves, 0..) |w, wi| {
        list[wi] = .{
            .name = w.name,
            .reason = w.reason,
            .members = try membersOf(arena, owner, wi),
            .layers = .{ .preferred = w.preferred_layers, .allowed = w.allowed_layers },
            .waypoints = w.corridor.waypoints,
            .max_vias = w.max_vias,
            .steering = .{
                .topology = w.corridor.topology,
                .seed_first = w.corridor.seed_first,
                .repair_waypoints = w.corridor.repair_waypoints,
                .branches = w.corridor.branches,
            },
            .rest = w.rest,
        };
    }
    if (extra == 1) {
        const rest_members = try membersOf(arena, owner, waves.len);
        list[waves.len] = .{ .name = rest_name, .reason = null, .members = rest_members, .rest = true };
    }
    return list;
}

const guide_clearance_mm: f64 = 0.2;

/// Lower a route wave's stable, placement-relative guide vocabulary into the
/// same ordered physical waypoint list used by the router. Explicit `(at …)`
/// points stay first for backwards compatibility; authored relative guides
/// follow in their declared order.
fn lowerGuides(
    arena: Allocator,
    wave: env.PlanWave,
    ctx: Context,
    warns: *std.ArrayList(Warning),
) Allocator.Error![]const env.PlanWaypoint {
    var has_guides = false;
    for (wave.corridor.waypoints) |point| {
        if (point.guide != null) {
            has_guides = true;
            break;
        }
    }
    if (!has_guides) return wave.corridor.waypoints;
    var points: std.ArrayList(env.PlanWaypoint) = .empty;
    for (wave.corridor.waypoints) |authored| {
        const guide = authored.guide orelse {
            try points.append(arena, authored);
            continue;
        };
        switch (guide) {
            .escape_from => |g| {
                if (!try validGuideLayer(arena, wave.name, g.layer, ctx, warns)) continue;
                const located = try locateGuidePin(arena, wave.name, g.ref, g.pin, ctx, warns) orelse continue;
                const point = escapePoint(located.part.*, located.pad.*, ctx.placement.rules.design.clearance);
                try points.append(arena, guideWaypoint(point, g.layer));
            },
            .between_pins => |g| {
                if (!try validGuideLayer(arena, wave.name, g.layer, ctx, warns)) continue;
                const from = try locateGuidePin(arena, wave.name, g.from_ref, g.from_pin, ctx, warns) orelse continue;
                const to = try locateGuidePin(arena, wave.name, g.to_ref, g.to_pin, ctx, warns) orelse continue;
                const a = optimizer.worldPadCenter(from.part, from.pad.x, from.pad.y);
                const b = optimizer.worldPadCenter(to.part, to.pad.x, to.pad.y);
                try points.append(arena, guideWaypoint(.{
                    (a[0] + b[0]) / 2,
                    (a[1] + b[1]) / 2,
                }, g.layer));
            },
            .beside => |g| {
                if (!try validGuideLayer(arena, wave.name, g.layer, ctx, warns)) continue;
                const pi = guidePartIndex(ctx, g.ref) orelse {
                    try warns.append(arena, try mkWarning(arena, wave.name, g.ref, "guide ref"));
                    continue;
                };
                const rect = optimizer.worldCourtyard(&ctx.placement.parts[pi]);
                const maxx = rect.minx + rect.w;
                const maxy = rect.miny + rect.h;
                const point: [2]f64 = switch (g.side) {
                    .north => .{ rect.minx + rect.w / 2, rect.miny - guide_clearance_mm },
                    .south => .{ rect.minx + rect.w / 2, maxy + guide_clearance_mm },
                    .east => .{ maxx + guide_clearance_mm, rect.miny + rect.h / 2 },
                    .west => .{ rect.minx - guide_clearance_mm, rect.miny + rect.h / 2 },
                };
                try points.append(arena, guideWaypoint(point, g.layer));
            },
        }
    }
    return points.toOwnedSlice(arena);
}

/// Lower an authored `(assign-escapes …)` on one route wave: hand the wave's
/// resolved net set to the joint escape assigner and keep the soft per-net lane
/// guides it produces. A wave without the form, or a set the assigner cannot
/// schedule (no shared hub, no free lane), contributes nothing but a warning —
/// routing then proceeds exactly as it did before the form existed.
const EscapeWave = struct {
    wave: env.PlanWave,
    members: []const usize,
    ctx: Context,
};

/// Where one wave's lowering lands: the soft guides every `(assign-escapes …)`
/// produces, and the hard reservations only a `(reserve)` wave adds to.
const EscapeOut = struct {
    guides: *std.ArrayList(route_policy.GuideTrack),
    reserved: *std.ArrayList(route_policy.ReservedLane),
};

fn lowerEscapes(
    arena: Allocator,
    out: EscapeOut,
    in: EscapeWave,
    warns: *std.ArrayList(Warning),
) Allocator.Error!void {
    const spec = in.wave.corridor.assign_escapes orelse return;
    const rules = in.ctx.placement.rules;
    if (spec.layer.len > 0 and signalLayerIndex(rules, spec.layer) == null)
        try warns.append(arena, try mkLayerWarning(arena, in.wave.name, spec.layer));
    const assigned = try escape_assign.plan(arena, in.ctx.placement, .{
        .nets = in.members,
        .hub = spec.hub,
        .layer = if (spec.layer.len > 0) signalLayerIndex(rules, spec.layer) else null,
    });
    if (!assigned.ok) {
        const why = try std.fmt.allocPrint(arena, "{s} — its nets route unassigned", .{assigned.reason});
        try warns.append(arena, try mkEscapeWarning(arena, in.wave.name, why));
        return;
    }
    try out.guides.appendSlice(arena, try escape_assign.guideTracks(arena, assigned, escape_assign.guide_run_mm));
    // `(reserve)` adds the hard half over the same geometry — the guides are
    // still emitted, so a reserving wave is a strict superset of a plain one.
    if (spec.reserve)
        try out.reserved.appendSlice(arena, try escape_assign.reservedLanes(arena, assigned, escape_assign.guide_run_mm));
    // A PARTIAL assignment is the normal outcome of a corridor whose free space
    // is not where every net wants to cross, and it used to be silent: the wave
    // asked for a joint escape, some of its nets simply got no guide, and
    // nothing said which or why. The refused nets route exactly as they would
    // with no form authored, so this is a warning and never an error.
    if (assigned.schedule.unassigned.len > 0)
        try warns.append(arena, try mkEscapeWarning(
            arena,
            in.wave.name,
            try refusalDetail(arena, in.ctx.placement, assigned),
        ));
}

/// How many refused nets one warning names before it stops listing them.
const escape_refusals_listed: usize = 4;

/// Spell out a partial assignment: how many nets got no lane, and for the first
/// few, which net, why, and how far off its own ideal crossing the corridor
/// would have put it.
fn refusalDetail(
    arena: Allocator,
    placement: optimizer.Placement,
    assigned: escape_assign.Plan,
) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, try std.fmt.allocPrint(
        arena,
        "{d} of its {d} nets got no lane and route unassigned (cap {d:.2} mm):",
        .{ assigned.schedule.unassigned.len, assigned.schedule.assignments.len, assigned.corridor.cap },
    ));
    for (assigned.schedule.unassigned, 0..) |a, i| {
        if (i >= escape_refusals_listed) {
            const more = try std.fmt.allocPrint(arena, " …+{d} more", .{assigned.schedule.unassigned.len - i});
            try out.appendSlice(arena, more);
            break;
        }
        const name = if (a.net < placement.nets.len) placement.nets[a.net].name else "?";
        try out.appendSlice(arena, try std.fmt.allocPrint(
            arena,
            " {s} {s} {d:.2} mm;",
            .{ name, @tagName(a.fit.refusal), a.fit.offset },
        ));
    }
    return out.toOwnedSlice(arena);
}

/// The `(assign-escapes …)` counterpart of `mkWarning`: the wave asked for a
/// joint escape and the geometry could supply none, or only part, of one.
/// `detail` also keys the id, so a wave that both assigns and refuses does not
/// mint two warnings under one id.
fn mkEscapeWarning(arena: Allocator, wave: []const u8, detail: []const u8) Allocator.Error!Warning {
    return .{
        .id = try hashId(arena, "plan-escape-unassigned", detail),
        .kind = "plan-escape-unassigned",
        .message = try std.fmt.allocPrint(
            arena,
            "wave '{s}' asked for (assign-escapes …) but {s}",
            .{ wave, detail },
        ),
        .wave = wave,
        .name = wave,
    };
}

/// Per-axis sample count for the pour-coverage test. Coarse but deterministic:
/// a layer counts "fully covered" only when EVERY sampled board point sits in
/// (or within pour clearance of) a pour, so a partial pour never trips it.
const coverage_samples: usize = 48;

/// One wave-named layer resolved to its signal index.
const NamedLayer = struct { name: []const u8, sig: u8 };

/// Warn when EVERY layer a route wave names in `(allowed-layers …)` /
/// `(preferred-layers …)` is an inner signal layer whose area is fully covered
/// by pours of nets outside the wave. Pour clearance then blocks every cell
/// there for the wave's nets (the router's `zoneBlocksPoint`; its gap pass
/// excludes such layers outright), the terminals force the outer faces back
/// in, and the wave routes byte-identically to having no layer policy at all —
/// barracuda's In2.Cu under three rail pours cost real iterations before
/// anyone measured that. The blocking is pour honesty working; the silence is
/// the defect, so name WHICH layer is reserved by WHICH pours.
fn reservedLayerWarning(
    arena: Allocator,
    wave: env.PlanWave,
    members: []const usize,
    ctx: Context,
) Allocator.Error!?Warning {
    if (members.len == 0 or ctx.zones.len == 0) return null;
    var layers: std.ArrayList(NamedLayer) = .empty;
    try collectWaveLayers(arena, wave.preferred_layers, ctx, &layers);
    try collectWaveLayers(arena, wave.allowed_layers, ctx, &layers);
    if (layers.items.len == 0) return null;
    for (layers.items) |L| {
        if (!layerReserved(ctx, L.sig, members)) return null;
    }
    return try mkReservedWarning(arena, wave.name, layers.items, ctx, members.len);
}

/// Append each of `names` that resolves to a signal layer, deduplicated by
/// index. Unknown names are skipped — `mkLayerWarning` already reported them.
fn collectWaveLayers(
    arena: Allocator,
    names: []const []const u8,
    ctx: Context,
    out: *std.ArrayList(NamedLayer),
) Allocator.Error!void {
    for (names) |name| {
        const sig = signalLayerIndex(ctx.placement.rules, name) orelse continue;
        var seen = false;
        for (out.items) |have| {
            if (have.sig == sig) seen = true;
        }
        if (!seen) try out.append(arena, .{ .name = name, .sig = sig });
    }
}

/// True when signal layer `sig` offers the wave's nets nothing: an inner layer
/// carrying pours, none of them owned by a member net (a net can always route
/// into its OWN pour), whose pours jointly cover the whole board region. The
/// outer faces are never reserved — pads live there, and a poured face stays
/// routable at pour cost.
fn layerReserved(ctx: Context, sig: u8, members: []const usize) bool {
    if (sig < 2) return false;
    var poured = false;
    for (ctx.zones) |z| {
        if (z.layer != sig) continue;
        poured = true;
        for (members) |ni| {
            if (ni < ctx.placement.nets.len and zoneNetIs(z.net, ctx.placement.nets[ni].name)) return false;
        }
    }
    if (!poured) return false;
    return layerFullyPoured(ctx, sig);
}

/// Every sampled board point sits inside (or within pour clearance of) some
/// pour on `sig` — the whole layer is spoken for. Sampled on a fixed
/// `coverage_samples²` grid over the board outline (else the placement bbox),
/// so the verdict is deterministic and cheap.
fn layerFullyPoured(ctx: Context, sig: u8) bool {
    const p = ctx.placement;
    const clear = p.rules.design.clearance;
    if (p.maxx <= p.minx or p.maxy <= p.miny) return false;
    var iy: usize = 0;
    while (iy < coverage_samples) : (iy += 1) {
        var ix: usize = 0;
        while (ix < coverage_samples) : (ix += 1) {
            const fx = (@as(f64, @floatFromInt(ix)) + 0.5) / @as(f64, @floatFromInt(coverage_samples));
            const fy = (@as(f64, @floatFromInt(iy)) + 0.5) / @as(f64, @floatFromInt(coverage_samples));
            const x = p.minx + fx * (p.maxx - p.minx);
            const y = p.miny + fy * (p.maxy - p.miny);
            if (!boardContains(p, x, y)) continue;
            if (!pointPoured(ctx.zones, sig, x, y, clear)) return false;
        }
    }
    return true;
}

/// Is (x,y) on the board? The authored outline polygon when one exists, else
/// the `(board …)` rectangle, else everywhere (the sample grid already spans
/// only the placement bbox).
fn boardContains(p: optimizer.Placement, x: f64, y: f64) bool {
    if (p.board_poly) |poly| {
        if (poly.len >= 3) return outline_mod.contains(poly, x, y);
    }
    if (p.board_rect) |r| {
        return x >= r.minx and x <= r.minx + r.w and y >= r.miny and y <= r.miny + r.h;
    }
    return true;
}

/// Is (x,y) inside (or within `clear` of) any pour on signal layer `sig`?
fn pointPoured(zones: []const pour.UserZone, sig: u8, x: f64, y: f64, clear: f64) bool {
    for (zones) |z| {
        if (z.layer != sig) continue;
        if (outline_mod.contains(z.poly, x, y) or outline_mod.distToEdge(z.poly, x, y) < clear) return true;
    }
    return false;
}

/// Zone net name ↔ flattened net name: exact or `/`-leaf match, ASCII
/// case-insensitive — the identification `pour.zig` uses for fills.
fn zoneNetIs(zone_net: []const u8, net: []const u8) bool {
    return eqUpper(zone_net, net) or eqUpper(leafOf(zone_net), leafOf(net));
}

/// Build the reserved-layer warning: each named layer with the pour nets
/// covering it, so the author sees which copper owns the layer they asked for.
fn mkReservedWarning(
    arena: Allocator,
    wave: []const u8,
    layers: []const NamedLayer,
    ctx: Context,
    net_count: usize,
) Allocator.Error!Warning {
    var covered: std.ArrayList(u8) = .empty;
    for (layers, 0..) |L, i| {
        if (i > 0) try covered.appendSlice(arena, "; ");
        try covered.appendSlice(arena, L.name);
        try covered.appendSlice(arena, " is fully covered by pours ");
        try appendPourNets(arena, &covered, ctx, L.sig);
    }
    const msg = try std.fmt.allocPrint(
        arena,
        "wave \"{s}\" layer policy names only reserved copper: {s}; none of the wave's " ++
            "{d} net(s) can lay tracks there, so the (allowed-layers …)/(preferred-layers …) " ++
            "selection is inert",
        .{ wave, covered.items, net_count },
    );
    const key = try std.fmt.allocPrint(arena, "{s}\x1f{s}", .{ wave, covered.items });
    return .{
        .id = try hashId(arena, "plan-layer-reserved", key),
        .kind = "plan-layer-reserved",
        .message = msg,
        .wave = wave,
        .name = layers[0].name,
    };
}

/// Append the deduplicated net names of the pours on signal layer `sig`.
fn appendPourNets(arena: Allocator, text: *std.ArrayList(u8), ctx: Context, sig: u8) Allocator.Error!void {
    var n: usize = 0;
    for (ctx.zones, 0..) |z, i| {
        if (z.layer != sig) continue;
        var dup = false;
        for (ctx.zones[0..i]) |prev| {
            if (prev.layer == sig and eqUpper(prev.net, z.net)) dup = true;
        }
        if (dup) continue;
        if (n > 0) try text.appendSlice(arena, ", ");
        try text.appendSlice(arena, z.net);
        n += 1;
    }
}

fn guideWaypoint(point: [2]f64, layer: []const u8) env.PlanWaypoint {
    return .{
        .x = @round(point[0] / optimizer.grid_mm) * optimizer.grid_mm,
        .y = @round(point[1] / optimizer.grid_mm) * optimizer.grid_mm,
        .layer = layer,
    };
}

fn validGuideLayer(
    arena: Allocator,
    wave: []const u8,
    layer: []const u8,
    ctx: Context,
    warns: *std.ArrayList(Warning),
) Allocator.Error!bool {
    if (signalLayerIndex(ctx.placement.rules, layer) != null) return true;
    try warns.append(arena, try mkLayerWarning(arena, wave, layer));
    return false;
}

const LocatedGuidePin = struct {
    part: *const optimizer.Part,
    pad: *const geometry.Pad,
};

fn locateGuidePin(
    arena: Allocator,
    wave: []const u8,
    ref: []const u8,
    pin: []const u8,
    ctx: Context,
    warns: *std.ArrayList(Warning),
) Allocator.Error!?LocatedGuidePin {
    const pi = guidePartIndex(ctx, ref) orelse {
        try warns.append(arena, try mkWarning(arena, wave, ref, "guide ref"));
        return null;
    };
    const part = &ctx.placement.parts[pi];
    for (part.pads) |*pad| if (eqUpper(pad.number, pin)) {
        return .{ .part = part, .pad = pad };
    };
    const name = try std.fmt.allocPrint(arena, "{s}:{s}", .{ ref, pin });
    try warns.append(arena, try mkWarning(arena, wave, name, "guide pin"));
    return null;
}

fn guidePartIndex(ctx: Context, ref: []const u8) ?usize {
    for (ctx.placement.parts, 0..) |part, i| {
        if (refMatches(ctx, i, part.ref_des, ref)) return i;
    }
    return null;
}

fn escapePoint(part: optimizer.Part, pad: geometry.Pad, clearance: f64) [2]f64 {
    const rect = optimizer.worldCourtyard(&part);
    const maxx = rect.minx + rect.w;
    const maxy = rect.miny + rect.h;
    const center = optimizer.worldPadCenter(&part, pad.x, pad.y);
    const north = @abs(center[1] - rect.miny);
    const south = @abs(maxy - center[1]);
    const east = @abs(maxx - center[0]);
    const west = @abs(center[0] - rect.minx);
    const nearest = @min(@min(north, south), @min(east, west));
    const rotation = @mod(part.rot + pad.rot, 360);
    const ext = pose_math.aabbHalf(pad.w / 2, pad.h / 2, rotation);
    const half_w = ext[0];
    const half_h = ext[1];
    if (nearest == north) return .{ center[0], center[1] - half_h - clearance };
    if (nearest == south) return .{ center[0], center[1] + half_h + clearance };
    if (nearest == east) return .{ center[0] + half_w + clearance, center[1] };
    return .{ center[0] - half_w - clearance, center[1] };
}

/// Assign every still-unclaimed slot to wave `wi` — the rest wave's claim.
fn claimLeftovers(owner: []?usize, wi: usize) void {
    for (owner) |*o| {
        if (o.* == null) o.* = wi;
    }
}

/// Collect the ascending indices owned by wave `wi`.
fn membersOf(arena: Allocator, owner: []const ?usize, wi: usize) Allocator.Error![]const usize {
    var list: std.ArrayList(usize) = .empty;
    for (owner, 0..) |o, i| {
        if (o == wi) try list.append(arena, i);
    }
    return list.toOwnedSlice(arena);
}

// ── Selector matchers ────────────────────────────────────────────────────────
// Each clears `out`, fills it with candidate indices, and returns whether the
// selector NAME was recognized at all (an unrecognized name is what warns — a
// recognized name that happens to claim nothing does not).

/// Place `refs`: exact ref-des, bare sub-block leaf, or stable origin name — the
/// `?refs=` convention.
fn matchRef(ctx: Context, name: []const u8, out: *std.ArrayList(usize), arena: Allocator) Allocator.Error!bool {
    out.clearRetainingCapacity();
    for (ctx.placement.parts, 0..) |part, i| {
        if (refMatches(ctx, i, part.ref_des, name)) try out.append(arena, i);
    }
    return out.items.len > 0;
}

/// True when part `i` answers to `name` by ref-des, leaf, or origin key.
fn refMatches(ctx: Context, i: usize, ref: []const u8, name: []const u8) bool {
    if (eqUpper(ref, name)) return true;
    if (eqUpper(leafOf(ref), name)) return true;
    if (i < ctx.placement.instances.len and eqUpper(ctx.placement.instances[i].origin_key, name)) return true;
    return false;
}

/// Place `sections`: every instance declared in the named `(section …)`.
/// Recognized when the section name exists, even if it maps to no placed part.
fn matchSection(ctx: Context, name: []const u8, out: *std.ArrayList(usize), arena: Allocator) Allocator.Error!bool {
    out.clearRetainingCapacity();
    var found = false;
    for (ctx.sections) |sec| {
        if (!eqUpper(sec.name, name)) continue;
        found = true;
        for (sec.refs) |r| {
            if (partIndexOf(ctx, r)) |pi| try out.append(arena, pi);
        }
    }
    return found;
}

/// Place `sub_blocks`: every part whose flattened ref carries the slug as a
/// leading path segment (`pwr` → `pwr/C1`).
fn matchSubBlock(ctx: Context, slug: []const u8, out: *std.ArrayList(usize), arena: Allocator) Allocator.Error!bool {
    out.clearRetainingCapacity();
    for (ctx.placement.parts, 0..) |part, i| {
        if (hasSlugPrefix(part.ref_des, slug)) try out.append(arena, i);
    }
    return out.items.len > 0;
}

/// Route `classes`: every net whose `module_policy` class equals the named
/// taxonomy class. Recognized when the class name is a valid `NetClass` — a
/// valid class matching zero nets is not an unknown name.
fn matchClass(ctx: Context, name: []const u8, out: *std.ArrayList(usize), arena: Allocator) Allocator.Error!bool {
    out.clearRetainingCapacity();
    const cl = std.meta.stringToEnum(NetClass, name) orelse return false;
    for (ctx.placement.nets, 0..) |_, ni| {
        if (ni < ctx.net_class.len and ctx.net_class[ni] == cl) try out.append(arena, ni);
    }
    return true;
}

/// Route `net_classes`: inherit ALL nets listed in the authored `(net-class …)`
/// of that name — a wave never has to repeat the class's nets.
fn matchNetClass(ctx: Context, name: []const u8, out: *std.ArrayList(usize), arena: Allocator) Allocator.Error!bool {
    out.clearRetainingCapacity();
    var found = false;
    for (ctx.net_class_specs) |spec| {
        if (!eqUpper(spec.name, name)) continue;
        found = true;
        for (spec.nets) |nn| {
            if (netIndexOf(ctx, nn)) |ni| try out.append(arena, ni);
        }
    }
    return found;
}

/// Route `nets`: match a net by name (exact or bare leaf, case-insensitive).
fn matchNet(ctx: Context, name: []const u8, out: *std.ArrayList(usize), arena: Allocator) Allocator.Error!bool {
    out.clearRetainingCapacity();
    for (ctx.placement.nets, 0..) |net, ni| {
        if (eqUpper(net.name, name) or eqUpper(leafOf(net.name), name)) try out.append(arena, ni);
    }
    return out.items.len > 0;
}

/// First part index whose ref-des equals `ref` (case-insensitive).
fn partIndexOf(ctx: Context, ref: []const u8) ?usize {
    for (ctx.placement.parts, 0..) |part, i| {
        if (eqUpper(part.ref_des, ref)) return i;
    }
    return null;
}

/// First net index whose name matches `name` by full name or bare leaf.
fn netIndexOf(ctx: Context, name: []const u8) ?usize {
    return netIndexByName(ctx.placement, name);
}

/// First net index in `placement` whose name matches `want` by full name or
/// bare leaf, ASCII case-insensitive — the same lookup convention the PCB DSL
/// `(nets …)` route selectors use, exposed so the read-only per-net surfaces
/// (the route-analyze endpoint) resolve a caller-named net through one matcher.
pub fn netIndexByName(placement: optimizer.Placement, want: []const u8) ?usize {
    for (placement.nets, 0..) |net, ni| {
        if (eqUpper(net.name, want) or eqUpper(leafOf(net.name), want)) return ni;
    }
    return null;
}

// ── Ad-hoc net-scope resolution (incremental routing) ───────────────────────

/// Resolve a `NetScope` over `ctx` into an enable mask + diagnostics. Reuses the
/// same selector matchers the plan resolver uses, so an ad-hoc "route the RF
/// group" scope selects exactly the nets a `(route (wave … (net-classes "RF")))`
/// wave would. A token recognized nowhere lands in `unknown` (never fatal here);
/// pure and deterministic like `resolve`.
pub fn resolveNetScope(arena: Allocator, scope: NetScope, ctx: Context) Allocator.Error!ResolvedScope {
    const mask = try arena.alloc(bool, ctx.placement.nets.len);
    @memset(mask, false);
    var unknown: std.ArrayList([]const u8) = .empty;
    var scratch: std.ArrayList(usize) = .empty;
    for (scope.groups) |tok| {
        if (try matchGroupToken(ctx, tok, &scratch, arena)) {
            for (scratch.items) |ni| if (ni < mask.len) {
                mask[ni] = true;
            };
        } else try unknown.append(arena, tok);
    }
    for (scope.nets) |tok| {
        if (try matchNet(ctx, tok, &scratch, arena)) {
            for (scratch.items) |ni| if (ni < mask.len) {
                mask[ni] = true;
            };
        } else try unknown.append(arena, tok);
    }
    var matched: usize = 0;
    for (mask) |m| {
        if (m) matched += 1;
    }
    return .{
        .mask = mask,
        .matched = matched,
        .unknown = try unknown.toOwnedSlice(arena),
        .selectors = scope.groups.len + scope.nets.len,
    };
}

/// Resolve one generic group token against every net-grouping dimension in
/// priority order — an authored `(net-class …)` name, a `module_policy`
/// criticality class name, a sub-block slug, then a bare net name — filling
/// `out` with the first dimension that actually selects nets. Preferring the
/// first *non-empty* dimension keeps a profile-only authored net-class (a class
/// that carries geometry but lists no members) from shadowing the criticality
/// class of the same name. Returns whether ANY dimension recognized the token —
/// a recognized-but-empty class still counts (the group exists, it is merely
/// empty on this board), so the caller can report "matched no nets" distinctly
/// from an unknown name.
fn matchGroupToken(ctx: Context, tok: []const u8, out: *std.ArrayList(usize), arena: Allocator) Allocator.Error!bool {
    var recognized = false;
    if (try matchNetClass(ctx, tok, out, arena)) {
        if (out.items.len > 0) return true;
        recognized = true;
    }
    if (try matchClassCI(ctx, tok, out, arena)) {
        if (out.items.len > 0) return true;
        recognized = true;
    }
    if (try matchSubBlockNets(ctx, tok, out, arena)) {
        if (out.items.len > 0) return true;
        recognized = true;
    }
    if (try matchNet(ctx, tok, out, arena)) return true; // a net match implies ≥1
    return recognized;
}

/// Case-insensitive `matchClass`: the `module_policy.NetClass` enum names are
/// lowercase, but a human/agent writes `RF`/`Rf`. Lowercases the token before
/// the enum lookup; an over-long token can name no class.
fn matchClassCI(ctx: Context, name: []const u8, out: *std.ArrayList(usize), arena: Allocator) Allocator.Error!bool {
    var buf: [32]u8 = undefined;
    if (name.len > buf.len) return false;
    for (name, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return matchClass(ctx, buf[0..name.len], out, arena);
}

/// Route a sub-block by slug: every net with a pin on a part whose flattened
/// ref-des carries `slug` as a leading path segment (`pwr/…`). This catches the
/// sub-block's private nets AND its boundary nets (one pin inside, one out).
/// Recognized when at least one part carries the slug prefix.
fn matchSubBlockNets(ctx: Context, slug: []const u8, out: *std.ArrayList(usize), arena: Allocator) Allocator.Error!bool {
    out.clearRetainingCapacity();
    var exists = false;
    for (ctx.placement.parts) |part| {
        if (hasSlugPrefix(part.ref_des, slug)) {
            exists = true;
            break;
        }
    }
    if (!exists) return false;
    for (ctx.placement.nets, 0..) |net, ni| {
        for (net.pins) |pin| {
            if (hasSlugPrefix(pin.ref_des, slug)) {
                try out.append(arena, ni);
                break;
            }
        }
    }
    return true;
}

// ── Default synthesis ────────────────────────────────────────────────────────

/// Synthesize the default place waves: connectors & mechanical, then power
/// (buck/ldo modules + their role passives), then main ICs & decoupling, then
/// the rest. Empty waves are kept so the shape is stable.
fn synthesizePlace(arena: Allocator, ctx: Context) Allocator.Error![]const ResolvedWave {
    const n = ctx.placement.parts.len;
    const owner = try arena.alloc(?usize, n);
    @memset(owner, null);
    for (0..n) |p| if (owner[p] == null and isConnectorOrMech(ctx, p)) {
        owner[p] = 0;
    };
    for (0..n) |p| if (owner[p] == null and isPowerPart(ctx, p)) {
        owner[p] = 1;
    };
    for (0..n) |p| if (owner[p] == null and isMainOrDecoup(ctx, p)) {
        owner[p] = 2;
    };
    claimLeftovers(owner, 3);
    const list = try arena.alloc(ResolvedWave, 4);
    list[0] = .{ .name = "Connectors & mechanical", .members = try membersOf(arena, owner, 0) };
    list[1] = .{ .name = "Power", .members = try membersOf(arena, owner, 1) };
    list[2] = .{ .name = "Main ICs & decoupling", .members = try membersOf(arena, owner, 2) };
    list[3] = .{ .name = "Everything else", .members = try membersOf(arena, owner, 3), .rest = true };
    return list;
}

/// Synthesize the default route waves: high-speed & sensitive, then power, then
/// signals.
fn synthesizeRoute(arena: Allocator, ctx: Context) Allocator.Error![]const ResolvedWave {
    const n = ctx.placement.nets.len;
    const owner = try arena.alloc(?usize, n);
    @memset(owner, null);
    for (0..n) |i| if (owner[i] == null and inClasses(ctx, i, &.{ .rf, .clock, .switch_node, .feedback })) {
        owner[i] = 0;
    };
    for (0..n) |i| if (owner[i] == null and inClasses(ctx, i, &.{ .input_rail, .power, .ground })) {
        owner[i] = 1;
    };
    claimLeftovers(owner, 2);
    const list = try arena.alloc(ResolvedWave, 3);
    list[0] = .{ .name = "High-speed & sensitive", .members = try membersOf(arena, owner, 0) };
    list[1] = .{ .name = "Power", .members = try membersOf(arena, owner, 1) };
    list[2] = .{ .name = "Signals", .members = try membersOf(arena, owner, 2), .rest = true };
    return list;
}

/// True when net `ni`'s module-policy class is one of `classes`.
fn inClasses(ctx: Context, ni: usize, classes: []const NetClass) bool {
    if (ni >= ctx.net_class.len) return false;
    for (classes) |c| if (ctx.net_class[ni] == c) return true;
    return false;
}

/// A connector (J/P/X ref prefix) or mounting/mechanical part (MH/H ref, or a
/// footprint that reads as a mounting hole / standoff / fiducial).
fn isConnectorOrMech(ctx: Context, p: usize) bool {
    const leaf = leafOf(ctx.placement.parts[p].ref_des);
    if (leaf.len == 0) return false;
    const c = std.ascii.toUpper(leaf[0]);
    if (c == 'J' or c == 'P' or c == 'X') return true;
    if (isMountingLeaf(leaf)) return true;
    return footprintIsMechanical(ctx, p);
}

/// A mounting-hole ref: an `MH…` leaf or `H<digit>…`.
fn isMountingLeaf(leaf: []const u8) bool {
    if (leaf.len >= 2 and std.ascii.toUpper(leaf[0]) == 'M' and std.ascii.toUpper(leaf[1]) == 'H') return true;
    if (leaf.len >= 2 and std.ascii.toUpper(leaf[0]) == 'H' and std.ascii.isDigit(leaf[1])) return true;
    return false;
}

/// True when the part's footprint name reads as mechanical hardware.
fn footprintIsMechanical(ctx: Context, p: usize) bool {
    if (p >= ctx.placement.instances.len) return false;
    const fp = ctx.placement.instances[p].footprint;
    const words = [_][]const u8{ "MOUNT", "HOLE", "STANDOFF", "FIDUCIAL" };
    for (words) |wd| if (containsUpper(fp, wd)) return true;
    return false;
}

/// A part of a buck/ldo power module: the module's hub IC, its input/bulk/
/// feedback passives, or its power inductor.
fn isPowerPart(ctx: Context, p: usize) bool {
    const part = ctx.placement.parts[p];
    if (part.kind == .hub) {
        if (hubModuleClass(ctx, p)) |mc| return mc == .buck or mc == .ldo;
        return false;
    }
    if (p < ctx.part_role.len) {
        const role = ctx.part_role[p];
        if (role == .input_cap or role == .bulk_cap or role == .feedback_divider) return true;
    }
    if (module_policy.isInductor(part.ref_des) and touchesClass(ctx, p, &.{ .switch_node, .input_rail })) return true;
    return false;
}

/// A remaining hub IC or a decoupling/bulk cap — the main-IC support cluster.
fn isMainOrDecoup(ctx: Context, p: usize) bool {
    if (ctx.placement.parts[p].kind == .hub) return true;
    if (p >= ctx.part_role.len) return false;
    const role = ctx.part_role[p];
    return role == .decoupling_cap or role == .bulk_cap;
}

/// The `ModuleClass` of the hub at part index `p`, if it anchors a module.
fn hubModuleClass(ctx: Context, p: usize) ?ModuleClass {
    for (ctx.modules) |m| if (m.hub == p) return m.class;
    return null;
}

/// True when part `p` shares a net whose module-policy class is one of `classes`.
fn touchesClass(ctx: Context, p: usize, classes: []const NetClass) bool {
    const ref = ctx.placement.parts[p].ref_des;
    for (ctx.placement.nets, 0..) |net, ni| {
        if (ni >= ctx.net_class.len) continue;
        var on = false;
        for (net.pins) |pin| {
            if (std.mem.eql(u8, pin.ref_des, ref)) on = true;
        }
        if (!on) continue;
        for (classes) |c| if (ctx.net_class[ni] == c) return true;
    }
    return false;
}

// ── Small helpers ────────────────────────────────────────────────────────────

/// Build one unresolved-name warning with a stable id keyed on wave + entry.
fn mkWarning(arena: Allocator, wave: []const u8, name: []const u8, word: []const u8) Allocator.Error!Warning {
    const msg = try std.fmt.allocPrint(arena, "wave \"{s}\" names unknown {s} \"{s}\"", .{ wave, word, name });
    const key = try std.fmt.allocPrint(arena, "{s}\x1f{s}", .{ wave, name });
    return .{
        .id = try hashId(arena, "plan-unknown-name", key),
        .kind = "plan-unknown-name",
        .message = msg,
        .wave = wave,
        .name = name,
    };
}

/// Build one invalid routing-layer warning. Validation happens after placement
/// because only the solved stackup knows which inner layers are signal layers.
fn mkLayerWarning(arena: Allocator, wave: []const u8, name: []const u8) Allocator.Error!Warning {
    const msg = try std.fmt.allocPrint(arena, "wave \"{s}\" names unavailable signal layer \"{s}\"", .{ wave, name });
    const key = try std.fmt.allocPrint(arena, "{s}\x1f{s}", .{ wave, name });
    return .{
        .id = try hashId(arena, "plan-unknown-layer", key),
        .kind = "plan-unknown-layer",
        .message = msg,
        .wave = wave,
        .name = name,
    };
}

/// Warn once per member net whose terminal count an authored `(branches …)`
/// tree cannot cover exactly once. The router refuses such a tree silently —
/// it has no lint channel and a refusal is never fatal — so this is the only
/// place an author is told that a tree they wrote is doing nothing.
///
/// Counted on the net's PINS, which is what the author reads in the schematic;
/// the router drops a pin whose part or pad it cannot find, but such a pin is
/// already a netlist error reported elsewhere.
fn branchArityWarnings(
    arena: Allocator,
    wave: env.PlanWave,
    members: []const usize,
    ctx: Context,
    warns: *std.ArrayList(Warning),
) Allocator.Error!void {
    const authored = wave.corridor.branches.len;
    if (authored == 0) return;
    for (members) |net_i| {
        if (net_i >= ctx.placement.nets.len) continue;
        const net = ctx.placement.nets[net_i];
        if (authored + 1 == net.pins.len) continue;
        const msg = try std.fmt.allocPrint(
            arena,
            "wave \"{s}\" authors {d} (branch …) limb(s) but net \"{s}\" has {d} terminals — " ++
                "a guide tree needs one limb per non-root terminal, so this net routes unguided",
            .{ wave.name, authored, net.name, net.pins.len },
        );
        const key = try std.fmt.allocPrint(arena, "{s}\x1f{s}", .{ wave.name, net.name });
        try warns.append(arena, .{
            .id = try hashId(arena, "plan-branch-arity", key),
            .kind = "plan-branch-arity",
            .message = msg,
            .wave = wave.name,
            .name = net.name,
        });
    }
}

/// Signal-layer index for a canonical KiCad layer name, or null when the
/// stackup has no routable signal layer by that name. The shared layer model
/// owns the lookup (`board_layers.Stack.signalIndexOfName`).
fn signalLayerIndex(rules: optimizer.BoardRules, name: []const u8) ?u8 {
    return rules.signalIndexOfName(name);
}

/// Lower a wave's authored guide tree into router signal-layer indices, keeping
/// the authored limb order (which limb serves which terminal is decided per net
/// at route time). A limb left with no usable point by an unavailable layer
/// name — already reported as a plan warning — voids the WHOLE tree: half a
/// tree is a corridor the author never described, and the net is better routed
/// unguided than through one.
fn lowerBranches(
    arena: Allocator,
    authored: []const env.PlanBranch,
    placement: optimizer.Placement,
) Allocator.Error![]const route_policy.GuideBranch {
    if (authored.len == 0) return &.{};
    const out = try arena.alloc(route_policy.GuideBranch, authored.len);
    for (authored, out) |branch, *slot| {
        var points: std.ArrayList(route_policy.Waypoint) = .empty;
        for (branch.waypoints) |point| if (signalLayerIndex(placement.rules, point.layer)) |sig| {
            try points.append(arena, .{ .x = point.x, .y = point.y, .layer = sig });
        };
        if (points.items.len != branch.waypoints.len) return &.{};
        slot.* = .{ .waypoints = points.items };
    }
    return out;
}

/// Lower resolved route waves into the compact, net-indexed policy consumed by
/// the router. Earlier waves receive a higher priority. Invalid layer names
/// were already surfaced as plan warnings and are ignored here.
pub fn routePolicies(
    arena: Allocator,
    plan: ResolvedPlan,
    placement: optimizer.Placement,
    authored: bool,
) Allocator.Error![]const route_policy.NetPolicy {
    const out = try arena.alloc(route_policy.NetPolicy, placement.nets.len);
    @memset(out, .{});
    for (plan.route, 0..) |wave, wi| {
        const wave_priority: u32 = @intCast(plan.route.len - wi);
        var preferred: u64 = 0;
        var allowed: u64 = 0;
        var waypoints: std.ArrayList(route_policy.Waypoint) = .empty;
        var repair_waypoints: std.ArrayList(route_policy.Waypoint) = .empty;
        for (wave.layers.preferred) |name| if (signalLayerIndex(placement.rules, name)) |sig| {
            if (sig < 64) preferred |= @as(u64, 1) << @intCast(sig);
        };
        for (wave.layers.allowed) |name| if (signalLayerIndex(placement.rules, name)) |sig| {
            if (sig < 64) allowed |= @as(u64, 1) << @intCast(sig);
        };
        for (wave.waypoints) |point| if (signalLayerIndex(placement.rules, point.layer)) |sig| {
            try waypoints.append(arena, .{ .x = point.x, .y = point.y, .layer = sig });
        };
        for (wave.steering.repair_waypoints) |point| if (signalLayerIndex(placement.rules, point.layer)) |sig| {
            try repair_waypoints.append(arena, .{ .x = point.x, .y = point.y, .layer = sig });
        };
        const branches = try lowerBranches(arena, wave.steering.branches, placement);
        for (wave.members) |net_i| if (net_i < out.len) {
            out[net_i] = .{
                .wave = .{
                    .priority = wave_priority,
                    .before_planes = @intFromBool(authored and !wave.rest),
                    .seed_first = authored and wave.steering.seed_first,
                    .repair_waypoints = repair_waypoints.items,
                    .branches = branches,
                },
                .preferred_layers = preferred,
                .allowed_layers = allowed,
                .waypoints = waypoints.items,
                .max_vias = wave.max_vias,
            };
        };
    }
    return out;
}

test "route policies lower wave order and validated layer masks" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const pins_a = onePin("R1");
    const pins_b = onePin("R2");
    const nets = [_]flat_netlist.FlatNet{
        .{ .name = "RF", .pins = &pins_a },
        .{ .name = "SIG", .pins = &pins_b },
    };
    var p = fixturePlacement(&.{}, &.{}, &nets);
    p.rules = .{ .plane_nets = &.{}, .copper_layers = 2 };
    const first_waypoints = [_]env.PlanWaypoint{.{ .x = 1.5, .y = 2.5, .layer = "F.Cu" }};
    const repair_waypoints = [_]env.PlanWaypoint{.{ .x = 2.5, .y = 3.5, .layer = "B.Cu" }};
    const waves = [_]env.PlanWave{
        .{
            .name = "first",
            .nets = &.{"RF"},
            .preferred_layers = &.{"F.Cu"},
            .corridor = .{
                .waypoints = &first_waypoints,
                .repair_waypoints = &repair_waypoints,
                .seed_first = true,
            },
            .max_vias = 1,
        },
        .{ .name = "rest", .rest = true, .allowed_layers = &.{"B.Cu"} },
    };
    const plan = try resolve(arena, .{ .route = &waves }, .{ .placement = p });
    const policies = try routePolicies(arena, plan, p, true);
    try testing.expect(policies[0].wave.priority > policies[1].wave.priority);
    try testing.expectEqual(@as(u32, 1), policies[0].wave.before_planes);
    try testing.expect(policies[0].wave.seed_first);
    try testing.expectEqual(@as(u32, 0), policies[1].wave.before_planes);
    try testing.expect(!policies[1].wave.seed_first);
    try testing.expectEqual(@as(u64, 1), policies[0].preferred_layers);
    try testing.expectEqual(@as(u64, 2), policies[1].allowed_layers);
    try testing.expectEqual(@as(usize, 1), policies[0].waypoints.len);
    try testing.expectEqual(@as(f64, 1.5), policies[0].waypoints[0].x);
    try testing.expectEqual(@as(u8, 0), policies[0].waypoints[0].layer);
    try testing.expectEqual(@as(usize, 1), policies[0].wave.repair_waypoints.len);
    try testing.expectEqual(@as(f64, 2.5), policies[0].wave.repair_waypoints[0].x);
    try testing.expectEqual(@as(u8, 1), policies[0].wave.repair_waypoints[0].layer);
    try testing.expectEqual(@as(u16, 1), policies[0].max_vias.?);

    const invalid = [_]env.PlanWave{.{
        .name = "bad",
        .nets = &.{"RF"},
        .preferred_layers = &.{"In2.Cu"},
    }};
    const invalid_plan = try resolve(arena, .{ .route = &invalid }, .{ .placement = p });
    try testing.expectEqual(@as(usize, 1), invalid_plan.warnings.len);
    try testing.expectEqualStrings("plan-unknown-layer", invalid_plan.warnings[0].kind);
}

// spec: placement/plan-resolve - an authored branch tree lowers into per-net guide branches in authored limb order, and a limb count that cannot cover a member net warns
test "a route wave's branch tree lowers to guide branches and warns on a count it cannot cover" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const clock_pins = [_]flat_netlist.FlatPin{
        .{ .ref_des = "U1", .pin = "25" },
        .{ .ref_des = "U2", .pin = "17" },
        .{ .ref_des = "U3", .pin = "16" },
    };
    const lone_pins = onePin("R9");
    const nets = [_]flat_netlist.FlatNet{
        .{ .name = "SCK", .pins = &clock_pins },
        .{ .name = "SIG", .pins = &lone_pins },
    };
    var p = fixturePlacement(&.{}, &.{}, &nets);
    p.rules = .{ .plane_nets = &.{}, .copper_layers = 2 };

    const east = [_]env.PlanWaypoint{
        .{ .x = 2, .y = 0, .layer = "F.Cu" },
        .{ .x = 18, .y = 0, .layer = "B.Cu" },
    };
    const west = [_]env.PlanWaypoint{.{ .x = -18, .y = 0, .layer = "B.Cu" }};
    const branches = [_]env.PlanBranch{ .{ .waypoints = &east }, .{ .waypoints = &west } };
    const waves = [_]env.PlanWave{
        .{ .name = "clock", .nets = &.{"SCK"}, .corridor = .{ .branches = &branches } },
        .{ .name = "rest", .rest = true },
    };
    const plan = try resolve(arena, .{ .route = &waves }, .{ .placement = p });
    // Three terminals, two limbs: an exact cover, so no arity warning.
    try testing.expectEqual(@as(usize, 0), plan.warnings.len);

    const policies = try routePolicies(arena, plan, p, true);
    try testing.expectEqual(@as(usize, 2), policies[0].wave.branches.len);
    try testing.expectEqual(@as(usize, 2), policies[0].wave.branches[0].waypoints.len);
    try testing.expectEqual(@as(f64, 18), policies[0].wave.branches[0].waypoints[1].x);
    try testing.expectEqual(@as(u8, 1), policies[0].wave.branches[0].waypoints[1].layer);
    try testing.expectEqual(@as(usize, 1), policies[0].wave.branches[1].waypoints.len);
    // A net in no branch wave carries no tree, and the tree makes the net's
    // layer choices authored so cleanup may not simplify them away.
    try testing.expectEqual(@as(usize, 0), policies[1].wave.branches.len);
    try testing.expect(route_policy.authorsLayers(policies[0]));
    try testing.expect(!route_policy.authorsLayers(policies[1]));

    // The same tree over the one-terminal net cannot cover it: warned, named.
    const wide = [_]env.PlanWave{
        .{ .name = "clock", .nets = &.{ "SCK", "SIG" }, .corridor = .{ .branches = &branches } },
        .{ .name = "rest", .rest = true },
    };
    const wide_plan = try resolve(arena, .{ .route = &wide }, .{ .placement = p });
    try testing.expectEqual(@as(usize, 1), wide_plan.warnings.len);
    try testing.expectEqualStrings("plan-branch-arity", wide_plan.warnings[0].kind);
    try testing.expectEqualStrings("SIG", wide_plan.warnings[0].name);

    // An unavailable layer name voids the whole tree rather than half of it.
    const inner = [_]env.PlanWaypoint{.{ .x = 2, .y = 0, .layer = "In2.Cu" }};
    const mixed = [_]env.PlanBranch{ .{ .waypoints = &east }, .{ .waypoints = &inner } };
    const bad = [_]env.PlanWave{
        .{ .name = "clock", .nets = &.{"SCK"}, .corridor = .{ .branches = &mixed } },
        .{ .name = "rest", .rest = true },
    };
    const bad_plan = try resolve(arena, .{ .route = &bad }, .{ .placement = p });
    try testing.expectEqualStrings("plan-unknown-layer", bad_plan.warnings[0].kind);
    const bad_policies = try routePolicies(arena, bad_plan, p, true);
    try testing.expectEqual(@as(usize, 0), bad_policies[0].wave.branches.len);
}

// spec: placement/plan-resolve - an (assign-escapes) route wave lowers its nets into soft per-net escape-lane guides
test "an assign-escapes wave lowers to per-net lane guides" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const hub_pads = [_]geometry.Pad{
        .{ .number = "1", .x = -0.5, .y = -1, .w = 0.4, .h = 0.4 },
        .{ .number = "2", .x = -0.5, .y = 1, .w = 0.4, .h = 0.4 },
    };
    const leg = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "J1", .kind = .hub, .hw = 1, .hh = 3, .pads = &hub_pads, .fallback = false, .x = 10, .y = 0 },
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &leg, .fallback = false, .x = 0, .y = -1 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &leg, .fallback = false, .x = 0, .y = 1 },
    };
    const pins_a = [_]flat_netlist.FlatPin{ .{ .ref_des = "J1", .pin = "1" }, .{ .ref_des = "R1", .pin = "1" } };
    const pins_b = [_]flat_netlist.FlatPin{ .{ .ref_des = "J1", .pin = "2" }, .{ .ref_des = "R2", .pin = "1" } };
    const nets = [_]flat_netlist.FlatNet{
        .{ .name = "A", .pins = &pins_a },
        .{ .name = "B", .pins = &pins_b },
    };
    var p = fixturePlacement(&parts, &.{}, &nets);
    p.minx = -1;
    p.maxx = 11;
    p.miny = -5;
    p.maxy = 5;
    p.rules = .{ .plane_nets = &.{}, .copper_layers = 2 };

    const plain = [_]env.PlanWave{.{ .name = "bus", .nets = &.{ "A", "B" } }};
    const before = try resolve(arena, .{ .route = &plain }, .{ .placement = p });
    try testing.expectEqual(@as(usize, 0), before.escape_guides.len);

    const waves = [_]env.PlanWave{.{
        .name = "bus",
        .nets = &.{ "A", "B" },
        .corridor = .{ .assign_escapes = .{} },
    }};
    const plan = try resolve(arena, .{ .route = &waves }, .{ .placement = p });
    try testing.expect(plan.escape_guides.len >= 2);
    var seen_a = false;
    var seen_b = false;
    for (plan.escape_guides) |g| {
        if (g.net == 0) seen_a = true;
        if (g.net == 1) seen_b = true;
    }
    try testing.expect(seen_a and seen_b);
}

// spec: placement/plan-resolve - the nets an authored (assign-escapes) wave hands to the assigner are reported as a mask, and a plan authoring none reports an empty one
test "the assign-escapes mask names exactly the waves that authored the form" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();
    const pins_a = onePin("R1");
    const pins_b = onePin("R2");
    const pins_c = onePin("R3");
    const nets = [_]flat_netlist.FlatNet{
        .{ .name = "A", .pins = &pins_a },
        .{ .name = "B", .pins = &pins_b },
        .{ .name = "C", .pins = &pins_c },
    };
    const p = fixturePlacement(&.{}, &.{}, &nets);

    // No wave authors the form: an EMPTY mask, so the escape-contention gate
    // sees nothing owned and no resolution is run at all.
    const plain = [_]env.PlanWave{.{ .name = "bus", .nets = &.{ "A", "B", "C" } }};
    try testing.expectEqual(@as(usize, 0), (try escapeAssignedMask(arena, .{ .route = &plain }, .{ .placement = p })).len);
    try testing.expectEqual(@as(usize, 0), (try escapeAssignedMask(arena, null, .{ .placement = p })).len);

    // One wave does: only ITS nets are owned; the other wave's are still free
    // to be reported as contended.
    const mixed = [_]env.PlanWave{
        .{ .name = "escape", .nets = &.{ "A", "B" }, .corridor = .{ .assign_escapes = .{} } },
        .{ .name = "rest", .nets = &.{"C"} },
    };
    const mask = try escapeAssignedMask(arena, .{ .route = &mixed }, .{ .placement = p });
    try testing.expectEqual(@as(usize, 3), mask.len);
    try testing.expect(mask[0] and mask[1] and !mask[2]);
}

// spec: placement/plan-resolve - an (assign-escapes) wave whose nets share no hub warns instead of silently routing unassigned
test "an unassignable assign-escapes wave becomes a plan warning" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();
    const pins_a = onePin("R1");
    const pins_b = onePin("R2");
    const nets = [_]flat_netlist.FlatNet{
        .{ .name = "A", .pins = &pins_a },
        .{ .name = "B", .pins = &pins_b },
    };
    const p = fixturePlacement(&.{}, &.{}, &nets);
    const waves = [_]env.PlanWave{.{
        .name = "bus",
        .nets = &.{ "A", "B" },
        .corridor = .{ .assign_escapes = .{} },
    }};
    const plan = try resolve(arena, .{ .route = &waves }, .{ .placement = p });
    try testing.expectEqual(@as(usize, 0), plan.escape_guides.len);
    var warned = false;
    for (plan.warnings) |warn| {
        if (std.mem.eql(u8, warn.kind, "plan-escape-unassigned")) warned = true;
    }
    try testing.expect(warned);
}

const blank_escape_part: optimizer.Part = .{
    .ref_des = "",
    .kind = .passive,
    .hw = 0,
    .hh = 0,
    .pads = &.{},
    .fallback = false,
};
const blank_escape_pin: flat_netlist.FlatPin = .{ .ref_des = "", .pin = "" };
const blank_escape_net: optimizer.FlatNet = .{ .name = "", .pins = &.{} };

/// A three-net escape whose corridor free space is ONE narrow band: two nets
/// cross inside it and a third's ideal lands 3.75 mm below it, far past the
/// 1.25 mm displacement cap the 0.25 mm lane pitch implies. Returns the parts
/// (index 0 is the hub) so the caller can hand them to `fixturePlacement`.
const PartialEscape = struct {
    hub_pads: [3]geometry.Pad = .{
        .{ .number = "1", .x = -0.5, .y = -0.1, .w = 0.2, .h = 0.2 },
        .{ .number = "2", .x = -0.5, .y = 0.1, .w = 0.2, .h = 0.2 },
        .{ .number = "3", .x = -0.5, .y = -4.0, .w = 0.2, .h = 0.2 },
    },
    leg: [1]geometry.Pad = .{.{ .number = "1", .x = 0, .y = 0, .w = 0.2, .h = 0.2 }},
    parts: [6]optimizer.Part = @splat(blank_escape_part),
    pins: [3][2]flat_netlist.FlatPin = @splat(.{ blank_escape_pin, blank_escape_pin }),
    nets: [3]optimizer.FlatNet = @splat(blank_escape_net),

    fn build(self: *PartialEscape) void {
        const refs = [_][]const u8{ "R1", "R2", "R3" };
        const names = [_][]const u8{ "A", "B", "C" };
        self.parts[0] = .{
            .ref_des = "J1",
            .kind = .hub,
            .hw = 1,
            .hh = 6,
            .pads = &self.hub_pads,
            .fallback = false,
            .x = 10,
            .y = 0,
        };
        for (self.hub_pads, refs, names, 0..) |pad, ref, name, i| {
            self.parts[i + 1] = .{
                .ref_des = ref,
                .kind = .passive,
                .hw = 0.5,
                .hh = 0.5,
                .pads = &self.leg,
                .fallback = false,
                .x = -10,
                .y = pad.y,
            };
            self.pins[i] = .{ .{ .ref_des = "J1", .pin = pad.number }, .{ .ref_des = ref, .pin = "1" } };
            self.nets[i] = .{ .name = name, .pins = &self.pins[i] };
        }
        // Walls across the whole cut scan, leaving free space only in y (-0.375, 0.375).
        self.parts[4] = escapeWall("LOW", -5.25, &self.leg);
        self.parts[5] = escapeWall("HIGH", 5.25, &self.leg);
    }

    fn placement(self: *PartialEscape) optimizer.Placement {
        var p = fixturePlacement(&self.parts, &.{}, &self.nets);
        p.minx = -11;
        p.maxx = 11;
        p.miny = -11;
        p.maxy = 11;
        p.rules = .{ .plane_nets = &.{}, .copper_layers = 2, .design = .{ .track_width = 0.1, .clearance = 0.15 } };
        return p;
    }
};

fn escapeWall(ref: []const u8, y: f64, pads: []const geometry.Pad) optimizer.Part {
    return .{ .ref_des = ref, .kind = .passive, .hw = 4, .hh = 4.75, .pads = pads, .fallback = false, .x = 5, .y = y };
}

// spec: placement/plan-resolve - an (assign-escapes) wave that assigns only some of its nets keeps the guides it earned and warns naming every net it refused
test "a partly assigned assign-escapes wave keeps its guides and names the refusals" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();
    var f: PartialEscape = .{};
    f.build();
    const waves = [_]env.PlanWave{.{
        .name = "bus",
        .nets = &.{ "A", "B", "C" },
        .corridor = .{ .assign_escapes = .{} },
    }};
    const plan = try resolve(arena, .{ .route = &waves }, .{ .placement = f.placement() });
    // The two nets that cross inside the band keep their lanes …
    try testing.expectEqual(@as(usize, 2), plan.escape_guides.len);
    // … and the third, 3.75 mm below every lane, is named in a plan warning
    // rather than dragged onto one.
    var message: []const u8 = "";
    for (plan.warnings) |warn| {
        if (std.mem.eql(u8, warn.kind, "plan-escape-unassigned")) message = warn.message;
    }
    try testing.expect(std.mem.indexOf(u8, message, "1 of its 3 nets") != null);
    try testing.expect(std.mem.indexOf(u8, message, "out_of_band") != null);
    try testing.expect(std.mem.indexOf(u8, message, " C ") != null);
}

// spec: placement/plan-resolve - the guides an (assign-escapes) wave lowers are exactly the ones the escape assigner reports for the same net set, so the preview and the route agree
test "wave lowering emits exactly the assigner's own guides" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();
    var f: PartialEscape = .{};
    f.build();
    const p = f.placement();
    const waves = [_]env.PlanWave{.{
        .name = "bus",
        .nets = &.{ "A", "B", "C" },
        .corridor = .{ .assign_escapes = .{} },
    }};
    const lowered = try resolve(arena, .{ .route = &waves }, .{ .placement = p });
    // The read-only preview's call shape: the same net set, straight to the
    // assigner, lowered with the same shared run length.
    const members = [_]usize{ 0, 1, 2 };
    const assigned = try escape_assign.plan(arena, p, .{ .nets = &members });
    const preview = try escape_assign.guideTracks(arena, assigned, escape_assign.guide_run_mm);
    try testing.expectEqual(preview.len, lowered.escape_guides.len);
    for (preview, lowered.escape_guides) |a, b| {
        try testing.expectEqual(a.net, b.net);
        try testing.expectEqual(a.layer, b.layer);
        try testing.expectApproxEqAbs(a.x1, b.x1, 1e-12);
        try testing.expectApproxEqAbs(a.y1, b.y1, 1e-12);
        try testing.expectApproxEqAbs(a.x2, b.x2, 1e-12);
        try testing.expectApproxEqAbs(a.y2, b.y2, 1e-12);
    }
}

// spec: eval/pcb-plan - (pcb-plan (topology)) - A plan-level (topology) sets the resolved topology flag on every route wave including the implicit rest wave
test "a plan-level (topology) flags every resolved route wave" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();
    const pins_a = onePin("R1");
    const pins_b = onePin("R2");
    const nets = [_]flat_netlist.FlatNet{
        .{ .name = "A", .pins = &pins_a },
        .{ .name = "B", .pins = &pins_b },
    };
    const p = fixturePlacement(&.{}, &.{}, &nets);
    // One authored wave and NO (rest): buildWaves appends the implicit rest
    // wave, which has no authored PlanWave to carry a flag of its own.
    const waves = [_]env.PlanWave{.{ .name = "bus", .nets = &.{"A"} }};
    const plan = try resolve(arena, .{ .route = &waves, .topology = true }, .{ .placement = p });
    try testing.expect(plan.topology);
    try testing.expectEqual(@as(usize, 2), plan.route.len);
    try testing.expect(allTopology(plan.route));
}

// spec: eval/pcb-plan - (pcb-plan (topology)) - A wave-level (topology) sets the resolved flag on that wave alone and leaves the other waves false
test "a wave-level (topology) flags only its own resolved wave" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();
    const pins_a = onePin("R1");
    const pins_b = onePin("R2");
    const nets = [_]flat_netlist.FlatNet{
        .{ .name = "A", .pins = &pins_a },
        .{ .name = "B", .pins = &pins_b },
    };
    const p = fixturePlacement(&.{}, &.{}, &nets);
    const waves = [_]env.PlanWave{
        .{ .name = "planned", .nets = &.{"A"}, .corridor = .{ .topology = true } },
        .{ .name = "rest", .rest = true },
    };
    const plan = try resolve(arena, .{ .route = &waves }, .{ .placement = p });
    // No plan-level flag, so the plan itself stays false even though a wave opted in.
    try testing.expect(!plan.topology);
    try testing.expect(plan.route[0].steering.topology);
    try testing.expect(!plan.route[1].steering.topology);
}

// spec: eval/pcb-plan - (pcb-plan (topology)) - A plan with no (topology) anywhere resolves every place and route wave with the flag false
test "a plan with no (topology) resolves every wave unflagged" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();
    const pins_a = onePin("R1");
    const pins_b = onePin("R2");
    const nets = [_]flat_netlist.FlatNet{
        .{ .name = "A", .pins = &pins_a },
        .{ .name = "B", .pins = &pins_b },
    };
    var parts = [_]optimizer.Part{hub("U1")};
    const p = fixturePlacement(&parts, &.{}, &nets);
    const place_waves = [_]env.PlanWave{.{ .name = "hubs", .refs = &.{"U1"} }};
    const route_waves = [_]env.PlanWave{.{ .name = "bus", .nets = &.{"A"} }};
    const plan = try resolve(
        arena,
        .{ .place = &place_waves, .route = &route_waves },
        .{ .placement = p },
    );
    try testing.expect(!plan.topology);
    try testing.expect(!anyTopology(plan.place));
    try testing.expect(!anyTopology(plan.route));
    // The synthesized default plan (no authored spec at all) is unflagged too.
    const synth = try resolve(arena, null, .{ .placement = p });
    try testing.expect(!synth.topology);
    try testing.expect(!anyTopology(synth.route));
}

/// Fail when `plan` carries a reserved-layer warning — the negative arm of the
/// audit test below.
fn expectNoReservedWarning(plan: ResolvedPlan) !void {
    for (plan.warnings) |warn| {
        if (std.mem.eql(u8, warn.kind, "plan-layer-reserved")) return error.TestUnexpectedWarning;
    }
}

// spec: placement/plan-resolve - a route wave whose only permitted layers are fully covered by foreign pours warns naming each reserved layer and its pours
test "a wave restricted to a fully poured inner layer warns that the selection is inert" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const nets = [_]flat_netlist.FlatNet{
        .{ .name = "SIG", .pins = &.{} },
        .{ .name = "V_3V3A", .pins = &.{} },
    };
    var p = fixturePlacement(&.{}, &.{}, &nets);
    // 4 copper layers, no declared planes: signal layers F.Cu, B.Cu, In1.Cu,
    // In2.Cu — In2.Cu is signal index 3, the layer the zones below sit on.
    p.rules = .{ .plane_nets = &.{}, .copper_layers = 4 };
    // One pour swallowing the whole placement bbox (0..1 on both axes).
    const covering = [_][2]f64{ .{ -1, -1 }, .{ 2, -1 }, .{ 2, 2 }, .{ -1, 2 } };
    const zones = [_]pour.UserZone{.{ .net = "V_3V3A", .layer = 3, .poly = &covering }};
    const ctx = Context{ .placement = p, .zones = &zones };

    // The barracuda shape: a signal wave allowed only onto the poured layer.
    const waves = [_]env.PlanWave{.{ .name = "spi", .nets = &.{"SIG"}, .allowed_layers = &.{"In2.Cu"} }};
    const plan = try resolve(arena, .{ .route = &waves }, ctx);
    var found: ?Warning = null;
    for (plan.warnings) |warn| {
        if (std.mem.eql(u8, warn.kind, "plan-layer-reserved")) found = warn;
    }
    const warn = found orelse return error.TestExpectedWarning;
    try testing.expectEqualStrings("spi", warn.wave);
    try testing.expect(std.mem.indexOf(u8, warn.message, "In2.Cu") != null);
    try testing.expect(std.mem.indexOf(u8, warn.message, "V_3V3A") != null);

    // An outer face in the same selection keeps the policy live — no warning.
    const with_outer = [_]env.PlanWave{.{ .name = "spi", .nets = &.{"SIG"}, .allowed_layers = &.{ "F.Cu", "In2.Cu" } }};
    try expectNoReservedWarning(try resolve(arena, .{ .route = &with_outer }, ctx));

    // A wave whose net OWNS the covering pour can route into it — no warning.
    const owner = [_]env.PlanWave{.{ .name = "rail", .nets = &.{"V_3V3A"}, .allowed_layers = &.{"In2.Cu"} }};
    try expectNoReservedWarning(try resolve(arena, .{ .route = &owner }, ctx));

    // A pour covering only part of the layer leaves routable space — no warning.
    const half = [_][2]f64{ .{ -1, -1 }, .{ 0.5, -1 }, .{ 0.5, 2 }, .{ -1, 2 } };
    const partial = [_]pour.UserZone{.{ .net = "V_3V3A", .layer = 3, .poly = &half }};
    try expectNoReservedWarning(try resolve(arena, .{ .route = &waves }, .{ .placement = p, .zones = &partial }));
}

/// FNV-1a over kind + `0x1f` + key, folded to 16 bits → a 4-hex string.
/// Mirrors `progress.zig`/`drc_json.zig` so a finding's id is stable.
fn hashId(arena: Allocator, kind: []const u8, key: []const u8) Allocator.Error![]const u8 {
    var h: u32 = fnv_offset;
    for (kind) |c| h = (h ^ c) *% fnv_prime;
    h = (h ^ 0x1f) *% fnv_prime;
    for (key) |c| h = (h ^ c) *% fnv_prime;
    const folded: u16 = @truncate(h ^ (h >> 16));
    return std.fmt.allocPrint(arena, "{x:0>4}", .{folded});
}

/// The bare leaf of a slash-qualified name (`pwr/C1` → `C1`).
fn leafOf(name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, '/')) |i| return name[i + 1 ..];
    return name;
}

/// True when `ref` carries `slug` as a leading path segment (`slug/…`).
fn hasSlugPrefix(ref: []const u8, slug: []const u8) bool {
    if (ref.len <= slug.len or ref[slug.len] != '/') return false;
    return eqUpper(ref[0..slug.len], slug);
}

/// ASCII case-insensitive slice equality.
fn eqUpper(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toUpper(x) != std.ascii.toUpper(y)) return false;
    }
    return true;
}

/// True when `haystack` contains `needle` (ASCII case-insensitive).
fn containsUpper(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (eqUpper(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;
const flat_netlist = @import("../flat_netlist.zig");

/// Assemble a `Placement` from parts / instances / nets, leaving the rest at
/// the test defaults — enough to exercise every selector matcher.
fn fixturePlacement(
    parts: []optimizer.Part,
    instances: []const flat_netlist.FlatInstance,
    nets: []const optimizer.FlatNet,
) optimizer.Placement {
    return .{
        .parts = parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = instances,
        .nets = nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 1,
        .maxy = 1,
        .generated = false,
    };
}

fn hub(ref: []const u8) optimizer.Part {
    return .{ .ref_des = ref, .kind = .hub, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false };
}

fn passive(ref: []const u8) optimizer.Part {
    return .{ .ref_des = ref, .kind = .passive, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false };
}

fn inst(ref: []const u8, origin: []const u8, footprint: []const u8) flat_netlist.FlatInstance {
    return .{
        .ref_des = ref,
        .component = "",
        .value = "",
        .footprint = footprint,
        .properties = &.{},
        .uuid = "",
        .origin_key = origin,
    };
}

fn onePin(ref: []const u8) [1]flat_netlist.FlatPin {
    return .{.{ .ref_des = ref, .pin = "1" }};
}

fn hasMember(wave: ResolvedWave, idx: usize) bool {
    for (wave.members) |m| if (m == idx) return true;
    return false;
}

/// True when every wave carries the topology flag (the plan-level implies-all
/// assertion). Vacuously true for an empty slice.
fn allTopology(waves: []const ResolvedWave) bool {
    for (waves) |w| if (!w.steering.topology) return false;
    return true;
}

/// True when any wave carries the topology flag — the negative arm, so an
/// unflagged plan can be asserted without a loop in the test body.
fn anyTopology(waves: []const ResolvedWave) bool {
    for (waves) |w| if (w.steering.topology) return true;
    return false;
}

fn placeWaveNamed(plan: ResolvedPlan, name: []const u8) ?ResolvedWave {
    for (plan.place) |w| if (std.mem.eql(u8, w.name, name)) return w;
    return null;
}

fn routeWaveNamed(plan: ResolvedPlan, name: []const u8) ?ResolvedWave {
    for (plan.route) |w| if (std.mem.eql(u8, w.name, name)) return w;
    return null;
}

// spec: placement/plan-resolve - relative route guides lower from current part and pin geometry into deterministic waypoints
test "relative route guides lower from placed pin geometry" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const a_pads = [_]geometry.Pad{.{
        .number = "1",
        .x = 0.5,
        .y = -0.8,
        .w = 0.3,
        .h = 0.3,
    }};
    const b_pads = [_]geometry.Pad{.{
        .number = "2",
        .x = 0.4,
        .y = 0.6,
        .w = 0.3,
        .h = 0.3,
    }};
    var parts = [_]optimizer.Part{
        .{
            .ref_des = "U1",
            .kind = .hub,
            .hw = 2,
            .hh = 1,
            .pads = &a_pads,
            .fallback = false,
            .x = 10,
            .y = 10,
        },
        .{
            .ref_des = "J1",
            .kind = .hub,
            .hw = 1,
            .hh = 2,
            .pads = &b_pads,
            .fallback = false,
            .x = 20,
            .y = 20,
            .rot = 90,
            .side = .bottom,
        },
    };
    const insts = [_]flat_netlist.FlatInstance{ inst("U1", "core", ""), inst("J1", "connector", "") };
    const pins = [_]flat_netlist.FlatPin{
        .{ .ref_des = "U1", .pin = "1" },
        .{ .ref_des = "J1", .pin = "2" },
    };
    const nets = [_]optimizer.FlatNet{.{ .name = "SIG", .pins = &pins }};
    var placement = fixturePlacement(&parts, &insts, &nets);
    placement.rules = .{ .plane_nets = &.{}, .copper_layers = 2 };
    const points = [_]env.PlanWaypoint{
        .{ .guide = .{ .escape_from = .{ .ref = "U1", .pin = "1", .layer = "F.Cu" } } },
        .{ .guide = .{ .between_pins = .{
            .from_ref = "U1",
            .from_pin = "1",
            .to_ref = "J1",
            .to_pin = "2",
            .layer = "B.Cu",
        } } },
        .{ .guide = .{ .beside = .{ .ref = "J1", .side = .east, .layer = "F.Cu" } } },
    };
    const waves = [_]env.PlanWave{.{ .name = "Signals", .nets = &.{"SIG"}, .corridor = .{ .waypoints = &points } }};
    const plan = try resolve(arena, .{ .route = &waves }, .{ .placement = placement });
    const got = routeWaveNamed(plan, "Signals") orelse return error.TestExpectedWave;
    try testing.expectEqual(@as(usize, 3), got.waypoints.len);
    try testing.expectApproxEqAbs(@as(f64, 10.5), got.waypoints[0].x, 1e-9);
    const escaped = guideWaypoint(.{
        10.5,
        9.2 - 0.15 - placement.rules.design.clearance,
    }, "F.Cu");
    try testing.expectApproxEqAbs(escaped.x, got.waypoints[0].x, 1e-9);
    try testing.expectApproxEqAbs(escaped.y, got.waypoints[0].y, 1e-9);
    const a = optimizer.worldPadCenter(&parts[0], a_pads[0].x, a_pads[0].y);
    const b = optimizer.worldPadCenter(&parts[1], b_pads[0].x, b_pads[0].y);
    const middle = guideWaypoint(.{ (a[0] + b[0]) / 2, (a[1] + b[1]) / 2 }, "B.Cu");
    try testing.expectApproxEqAbs(middle.x, got.waypoints[1].x, 1e-9);
    try testing.expectApproxEqAbs(middle.y, got.waypoints[1].y, 1e-9);
    const court = optimizer.worldCourtyard(&parts[1]);
    const beside = guideWaypoint(.{
        court.minx + court.w + guide_clearance_mm,
        court.miny + court.h / 2,
    }, "F.Cu");
    try testing.expectApproxEqAbs(beside.x, got.waypoints[2].x, 1e-9);
    try testing.expectApproxEqAbs(beside.y, got.waypoints[2].y, 1e-9);
}

// spec: placement/plan-resolve - a refs selector matches parts by exact ref and by bare sub-block leaf
test "refs selector matches exact ref and sub-block leaf" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    var parts = [_]optimizer.Part{ hub("U1"), passive("pwr/C1") };
    const insts = [_]flat_netlist.FlatInstance{ inst("U1", "U1", ""), inst("pwr/C1", "C_IN", "") };
    const ctx = Context{ .placement = fixturePlacement(&parts, &insts, &.{}) };

    const waves = [_]env.PlanWave{.{ .name = "Core", .refs = &.{ "U1", "C1" } }};
    const plan = try resolve(arena, .{ .place = &waves, .route = &.{} }, ctx);
    const core = placeWaveNamed(plan, "Core") orelse return error.TestExpectedWave;
    try testing.expect(hasMember(core, 0)); // U1 exact
    try testing.expect(hasMember(core, 1)); // pwr/C1 by leaf "C1"
}

// spec: placement/plan-resolve - a sections selector claims every instance declared in the named section
test "sections selector claims the section's instances" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    var parts = [_]optimizer.Part{ hub("U1"), passive("C1"), passive("R1") };
    const secs = [_]SectionMembers{.{ .name = "USB", .refs = &.{ "U1", "C1" } }};
    const ctx = Context{ .placement = fixturePlacement(&parts, &.{}, &.{}), .sections = &secs };

    const waves = [_]env.PlanWave{.{ .name = "usb", .sections = &.{"USB"} }};
    const plan = try resolve(arena, .{ .place = &waves, .route = &.{} }, ctx);
    const usb = placeWaveNamed(plan, "usb") orelse return error.TestExpectedWave;
    try testing.expect(hasMember(usb, 0) and hasMember(usb, 1));
    try testing.expect(!hasMember(usb, 2)); // R1 is not in the section
}

// spec: placement/plan-resolve - a sub-blocks selector claims every part under the sub-block slug prefix
test "sub-blocks selector claims parts under the slug prefix" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    var parts = [_]optimizer.Part{ passive("pwr/C1"), passive("pwr/L1"), passive("C9") };
    const ctx = Context{ .placement = fixturePlacement(&parts, &.{}, &.{}) };

    const waves = [_]env.PlanWave{.{ .name = "pwr", .sub_blocks = &.{"pwr"} }};
    const plan = try resolve(arena, .{ .place = &waves, .route = &.{} }, ctx);
    const w = placeWaveNamed(plan, "pwr") orelse return error.TestExpectedWave;
    try testing.expect(hasMember(w, 0) and hasMember(w, 1));
    try testing.expect(!hasMember(w, 2)); // top-level C9 has no slug prefix
}

// spec: placement/plan-resolve - a classes selector claims every net of the named module-policy class
test "classes selector claims nets of that module-policy class" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const nets = [_]optimizer.FlatNet{
        .{ .name = "SW", .pins = &.{} },
        .{ .name = "SIG", .pins = &.{} },
    };
    const classes = [_]NetClass{ .switch_node, .signal };
    var parts = [_]optimizer.Part{hub("U1")};
    const ctx = Context{ .placement = fixturePlacement(&parts, &.{}, &nets), .net_class = &classes };

    const waves = [_]env.PlanWave{.{ .name = "hot", .classes = &.{"switch_node"} }};
    const plan = try resolve(arena, .{ .place = &.{}, .route = &waves }, ctx);
    const hot = routeWaveNamed(plan, "hot") orelse return error.TestExpectedWave;
    try testing.expect(hasMember(hot, 0)); // SW
    try testing.expect(!hasMember(hot, 1)); // SIG
}

// spec: placement/plan-resolve - a net-classes selector inherits all nets of the authored net-class it names
test "net-classes selector inherits the authored class's nets" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const nets = [_]optimizer.FlatNet{
        .{ .name = "CLK", .pins = &.{} },
        .{ .name = "DAT", .pins = &.{} },
        .{ .name = "GND", .pins = &.{} },
    };
    const classes = [_]NetClass{ .clock, .signal, .ground };
    const specs = [_]env.NetClassSpec{.{ .name = "hs", .nets = &.{ "CLK", "DAT" } }};
    var parts = [_]optimizer.Part{hub("U1")};
    const ctx = Context{
        .placement = fixturePlacement(&parts, &.{}, &nets),
        .net_class = &classes,
        .net_class_specs = &specs,
    };

    // The wave names only the net-class "hs" — it must inherit CLK and DAT.
    const waves = [_]env.PlanWave{.{ .name = "fast", .net_classes = &.{"hs"} }};
    const plan = try resolve(arena, .{ .place = &.{}, .route = &waves }, ctx);
    const fast = routeWaveNamed(plan, "fast") orelse return error.TestExpectedWave;
    try testing.expect(hasMember(fast, 0) and hasMember(fast, 1));
    try testing.expect(!hasMember(fast, 2)); // GND is not in the class
}

// spec: placement/plan-resolve - a nets selector claims nets by name
test "nets selector matches by name" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const nets = [_]optimizer.FlatNet{
        .{ .name = "VBUS", .pins = &.{} },
        .{ .name = "SIG", .pins = &.{} },
    };
    const classes = [_]NetClass{ .power, .signal };
    var parts = [_]optimizer.Part{hub("U1")};
    const ctx = Context{ .placement = fixturePlacement(&parts, &.{}, &nets), .net_class = &classes };

    const waves = [_]env.PlanWave{.{ .name = "bus", .nets = &.{"VBUS"} }};
    const plan = try resolve(arena, .{ .place = &.{}, .route = &waves }, ctx);
    const bus = routeWaveNamed(plan, "bus") orelse return error.TestExpectedWave;
    try testing.expect(hasMember(bus, 0) and !hasMember(bus, 1));
}

// spec: placement/plan-resolve - a part matched by two waves belongs to the first wave in document order
test "first wave wins for a doubly-matched part" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    var parts = [_]optimizer.Part{ hub("U1"), passive("C1") };
    const ctx = Context{ .placement = fixturePlacement(&parts, &.{}, &.{}) };

    const waves = [_]env.PlanWave{
        .{ .name = "first", .refs = &.{"C1"} },
        .{ .name = "second", .refs = &.{"C1"} },
    };
    const plan = try resolve(arena, .{ .place = &waves, .route = &.{} }, ctx);
    const first = placeWaveNamed(plan, "first") orelse return error.TestExpectedWave;
    const second = placeWaveNamed(plan, "second") orelse return error.TestExpectedWave;
    try testing.expect(hasMember(first, 1));
    try testing.expect(!hasMember(second, 1));
}

// spec: placement/plan-resolve - parts unmatched by any wave fall to the rest wave whether authored or implicit
test "leftovers fall to the rest wave" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    var parts = [_]optimizer.Part{ hub("U1"), passive("C1"), passive("R1") };
    const ctx = Context{ .placement = fixturePlacement(&parts, &.{}, &.{}) };

    // No authored rest → an implicit "Everything else" wave collects R1.
    const implicit = [_]env.PlanWave{.{ .name = "core", .refs = &.{ "U1", "C1" } }};
    const plan_i = try resolve(arena, .{ .place = &implicit, .route = &.{} }, ctx);
    const rest_i = placeWaveNamed(plan_i, "Everything else") orelse return error.TestExpectedWave;
    try testing.expect(rest_i.rest and hasMember(rest_i, 2));

    // Authored rest wave collects the leftover directly.
    const authored = [_]env.PlanWave{
        .{ .name = "core", .refs = &.{ "U1", "C1" } },
        .{ .name = "leftovers", .rest = true },
    };
    const plan_a = try resolve(arena, .{ .place = &authored, .route = &.{} }, ctx);
    try testing.expectEqual(@as(usize, 2), plan_a.place.len); // no extra implicit wave
    const rest_a = placeWaveNamed(plan_a, "leftovers") orelse return error.TestExpectedWave;
    try testing.expect(rest_a.rest and hasMember(rest_a, 2));
}

// spec: placement/plan-resolve - an unknown selector name yields a stable warning and is never dropped silently
test "unknown selector name warns with a stable id" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    var parts = [_]optimizer.Part{hub("U1")};
    const ctx = Context{ .placement = fixturePlacement(&parts, &.{}, &.{}) };
    const waves = [_]env.PlanWave{.{ .name = "core", .refs = &.{"NOPE"} }};

    const a = try resolve(arena, .{ .place = &waves, .route = &.{} }, ctx);
    try testing.expectEqual(@as(usize, 1), a.warnings.len);
    try testing.expectEqualStrings("plan-unknown-name", a.warnings[0].kind);
    try testing.expectEqual(@as(usize, 4), a.warnings[0].id.len);
    try testing.expectEqualStrings("core", a.warnings[0].wave);

    const b = try resolve(arena, .{ .place = &waves, .route = &.{} }, ctx);
    try testing.expectEqualStrings(a.warnings[0].id, b.warnings[0].id);
}

// spec: placement/plan-resolve - resolving the same inputs twice yields an identical plan
test "resolution is deterministic across two runs" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    var parts = [_]optimizer.Part{ hub("U1"), passive("C1"), passive("C2"), passive("R1") };
    const ctx = Context{ .placement = fixturePlacement(&parts, &.{}, &.{}) };
    const waves = [_]env.PlanWave{.{ .name = "core", .refs = &.{ "U1", "C1", "C2" } }};

    const a = try resolve(arena, .{ .place = &waves, .route = &.{} }, ctx);
    const b = try resolve(arena, .{ .place = &waves, .route = &.{} }, ctx);
    try testing.expectEqual(a.place.len, b.place.len);
    for (a.place, b.place) |wa, wb| {
        try testing.expectEqualStrings(wa.name, wb.name);
        try testing.expectEqualSlices(usize, wa.members, wb.members);
    }
}

// spec: placement/plan-resolve - an absent plan synthesizes connector power and high-speed waves from module policy
test "synthesis derives the default plan from module policy" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    // A tiny buck: hub U1, inductor L1 and input cap C1; connector J1; an RF net.
    var parts = [_]optimizer.Part{ hub("U1"), passive("L1"), passive("C1"), hub("J1") };
    const insts = [_]flat_netlist.FlatInstance{
        inst("U1", "U1", ""), inst("L1", "L1", ""), inst("C1", "C_IN", ""), inst("J1", "J1", ""),
    };
    const vin_pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C1", .pin = "1" } };
    const sw_pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "U1", .pin = "2" }, .{ .ref_des = "L1", .pin = "1" } };
    const rf_pins = onePin("U1");
    const nets = [_]optimizer.FlatNet{
        .{ .name = "VIN", .pins = &vin_pins },
        .{ .name = "SW", .pins = &sw_pins },
        .{ .name = "RFOUT", .pins = &rf_pins },
    };
    const placement = fixturePlacement(&parts, &insts, &nets);

    var policy = try module_policy.analyze(testing.allocator, placement);
    defer policy.deinit(testing.allocator);
    const ctx = Context{
        .placement = placement,
        .net_class = policy.net_class,
        .part_role = policy.part_role,
        .modules = policy.modules,
    };

    const plan = try resolve(arena, null, ctx);
    try testing.expect(plan.synthesized);

    // J1 (index 3) lands in the connectors wave.
    const conn = placeWaveNamed(plan, "Connectors & mechanical") orelse return error.TestExpectedWave;
    try testing.expect(hasMember(conn, 3));

    // The buck hub U1 (index 0) lands in Power.
    const power = placeWaveNamed(plan, "Power") orelse return error.TestExpectedWave;
    try testing.expect(hasMember(power, 0));

    // The SW net (index 1) is high-speed/sensitive.
    const hs = routeWaveNamed(plan, "High-speed & sensitive") orelse return error.TestExpectedWave;
    try testing.expect(hasMember(hs, 1));

    // Empty waves are still present (shape is stable).
    try testing.expectEqual(@as(usize, 4), plan.place.len);
    try testing.expectEqual(@as(usize, 3), plan.route.len);
}

// spec: placement/plan-resolve - resolveNetScope selects a criticality-class group token's nets and reports the selector count
test "net scope resolves a criticality class token" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const nets = [_]optimizer.FlatNet{
        .{ .name = "RFOUT", .pins = &.{} },
        .{ .name = "SIG", .pins = &.{} },
    };
    const classes = [_]NetClass{ .rf, .signal };
    var parts = [_]optimizer.Part{hub("U1")};
    const ctx = Context{ .placement = fixturePlacement(&parts, &.{}, &nets), .net_class = &classes };

    // "RF" (uppercase) resolves through the case-insensitive criticality lookup.
    const scope = try resolveNetScope(arena, .{ .groups = &.{"RF"} }, ctx);
    try testing.expect(scope.mask[0] and !scope.mask[1]);
    try testing.expectEqual(@as(usize, 1), scope.matched);
    try testing.expectEqual(@as(usize, 0), scope.unknown.len);
    try testing.expectEqual(@as(usize, 1), scope.selectors);
}

// spec: placement/plan-resolve - resolveNetScope resolves an authored net-class name and unions multiple group tokens
test "net scope resolves an authored net-class and unions groups" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const nets = [_]optimizer.FlatNet{
        .{ .name = "CLK", .pins = &.{} },
        .{ .name = "DAT", .pins = &.{} },
        .{ .name = "RFOUT", .pins = &.{} },
        .{ .name = "GND", .pins = &.{} },
    };
    const classes = [_]NetClass{ .clock, .signal, .rf, .ground };
    const specs = [_]env.NetClassSpec{.{ .name = "hs", .nets = &.{ "CLK", "DAT" } }};
    var parts = [_]optimizer.Part{hub("U1")};
    const ctx = Context{
        .placement = fixturePlacement(&parts, &.{}, &nets),
        .net_class = &classes,
        .net_class_specs = &specs,
    };

    // "hs" → the authored class's CLK+DAT; "rf" → the criticality RFOUT.
    const scope = try resolveNetScope(arena, .{ .groups = &.{ "hs", "rf" } }, ctx);
    try testing.expect(scope.mask[0] and scope.mask[1] and scope.mask[2] and !scope.mask[3]);
    try testing.expectEqual(@as(usize, 3), scope.matched);
    try testing.expectEqual(@as(usize, 0), scope.unknown.len);
}

// spec: placement/plan-resolve - resolveNetScope selects a sub-block slug's private and boundary nets by pin membership
test "net scope resolves a sub-block slug by pin membership" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    // The pwr sub-block holds U1 and C1. VOUT is private (both pins inside);
    // VIN is a boundary net (one pin pwr/U1, one pin top-level J1); USB is
    // fully outside.
    const vout_pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "pwr/U1", .pin = "2" }, .{ .ref_des = "pwr/C1", .pin = "1" } };
    const vin_pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "pwr/U1", .pin = "1" }, .{ .ref_des = "J1", .pin = "1" } };
    const usb_pins = [_]flat_netlist.FlatPin{.{ .ref_des = "J1", .pin = "2" }};
    const nets = [_]optimizer.FlatNet{
        .{ .name = "pwr/VOUT", .pins = &vout_pins },
        .{ .name = "VIN", .pins = &vin_pins },
        .{ .name = "USB", .pins = &usb_pins },
    };
    var parts = [_]optimizer.Part{ hub("pwr/U1"), passive("pwr/C1"), hub("J1") };
    const ctx = Context{ .placement = fixturePlacement(&parts, &.{}, &nets) };

    const scope = try resolveNetScope(arena, .{ .groups = &.{"pwr"} }, ctx);
    try testing.expect(scope.mask[0] and scope.mask[1] and !scope.mask[2]);
    try testing.expectEqual(@as(usize, 2), scope.matched);
    try testing.expectEqual(@as(usize, 0), scope.unknown.len);
}

// spec: placement/plan-resolve - resolveNetScope collects an unrecognized token and resolves explicit nets while empty selectors mark a whole-board route
test "net scope collects unknown tokens and resolves explicit nets" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const nets = [_]optimizer.FlatNet{
        .{ .name = "VBUS", .pins = &.{} },
        .{ .name = "SIG", .pins = &.{} },
    };
    var parts = [_]optimizer.Part{hub("U1")};
    const ctx = Context{ .placement = fixturePlacement(&parts, &.{}, &nets) };

    const scope = try resolveNetScope(arena, .{ .groups = &.{"nope"}, .nets = &.{"VBUS"} }, ctx);
    try testing.expect(scope.mask[0] and !scope.mask[1]);
    try testing.expectEqual(@as(usize, 1), scope.matched);
    try testing.expectEqual(@as(usize, 1), scope.unknown.len);
    try testing.expectEqualStrings("nope", scope.unknown[0]);

    // No selector token at all ⇒ the whole-board sentinel (selectors == 0).
    const none = try resolveNetScope(arena, .{}, ctx);
    try testing.expectEqual(@as(usize, 0), none.selectors);
    try testing.expectEqual(@as(usize, 0), none.matched);
}
