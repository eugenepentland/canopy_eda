//! Static routability preflight — geometrically doomed routing read off the
//! PLACEMENT and the design rules alone. No router runs here, nothing is
//! rastered, no net is searched: every finding is a closed-form comparison
//! between a measured millimetre gap and the millimetres that net class's
//! copper demands, so the pass costs microseconds and its verdicts do not move
//! when the router's ordering, priorities or effort tier change.
//!
//! That is the point. The autorouter reports "net X failed" *after* a full
//! solve, and the remedy an agent then reaches for — reorder, re-prioritise,
//! widen the window — cannot help when the obstruction is the footprint's own
//! geometry. Two situations on barracuda cost real routing iterations before
//! anyone measured them:
//!
//!   * `adf4159/C116`, a 0201 whose two pads face each other across 0.180 mm.
//!     Its rail is `(net-class "power" (width 0.2532) (clearance 0.127))`, so a
//!     track hugging either pad's inboard edge needs 0.2536 mm. Nothing can
//!     enter those pads from between them at ANY ordering — the copper has to
//!     arrive at the outboard end.
//!   * `adf4159`'s CE pad, which the router diagnosed as "could not break out
//!     of its own footprint — every exit is sealed". Eight octilinear exits,
//!     all of them inside a foreign pad's clearance halo.
//!
//! Gates implemented here:
//!   • `pad-corridor-tight` — two pads of the SAME part on different nets face
//!                            each other across less than `width/2 + clearance`,
//!                            so neither pad can be entered along the pad axis.
//!   • `pad-sealed`         — a pad with zero legal octilinear escape
//!                            directions: in every one of the eight, the first
//!                            track-centre outside the pad edge is inside
//!                            foreign copper's clearance halo.
//!   • `escape-contended`   — a hub side whose escape fan the corridor there
//!                            cannot seat: more nets leave that way than the
//!                            tightest cross-section has lanes for them, or its
//!                            lanes are split across a void the nets that want
//!                            them cannot reach. Measured by
//!                            `placement/escape_assign.detect`, which is the
//!                            module that owns the cut scan and the joint
//!                            schedule; this gate only reports it, and carries
//!                            the paste-ready `(assign-escapes …)` wave that
//!                            would address it.
//!   • `via-in-pad-conflict` — two SMD pads on one part are closer than the
//!                            copper/drill spacing required by their net-class
//!                            vias, so both escapes cannot transition at their
//!                            pad centres. Reserve one transition and surface-
//!                            fan the other before dropping a via.
//!   • `port-blocked`       — a `(port …)` net of the block with no way OUT of
//!                            it: no corridor from any of its pads to outside
//!                            the parts' courtyard bounding box, and nowhere
//!                            reachable that a via of its class fits. Measured
//!                            by `placement/port_escape.detect`; this gate only
//!                            reports it. The other three gates all key off
//!                            nets that route INSIDE the block, so a port
//!                            terminating on ONE pad — every SPI line of
//!                            `straps-synth-lmx2595` — could be fenced in
//!                            completely without any of them noticing, and the
//!                            router says nothing either because a one-pin net
//!                            is not something it routes. Only fires when the
//!                            caller supplies `Options.port_nets`.
//!
//! All five gates are **warnings**: the geometry is real, but a corridor a
//! track cannot enter is usually fine (enter the pad outboard), a sealed pad may
//! still be reachable if a neighbour moves, and a contended escape routes today
//! — just in whatever order the router happens to arrive in. `port-blocked` is
//! the one whose subject is not a trade-off — a module whose port cannot leave
//! is unusable as designed — but its severity stays `warn` because this module's
//! contract is that it reports geometry and steers nothing; the ENFORCEMENT is
//! the rough solve's own hard repair round (`placement/rough_routability`),
//! which will not keep a placement that seals a port. They tell an agent
//! WHICH edit is worth making — move a part, widen a lane, drop the net class's
//! width, schedule the fan — not that the board is broken.
//!
//! Scope, stated plainly so the findings are not over-read:
//!   * pad copper is compared through `pad_shape` (bounding box, plus the exact
//!     polygon for custom pads), the same model the DRC uses;
//!   * only pads that share a copper face are compared (through-hole pads exist
//!     on every layer, so they always count);
//!   * plane-carried nets are exempt from the sealed gate — they rejoin through
//!     a pour/stitch via rather than a surface escape (via `fab_readiness
//!     .netHasPlane`, so a board with no `(stackup …)` still exempts the grounds
//!     the router's implicit model plants a plane for);
//!   * board-edge and existing-copper obstruction are NOT modelled — this is a
//!     placement-time preflight, and copper is the router's business.
//!
//! Still deliberately NOT implemented: corridor capacity in GENERAL — the rats
//! crossing an arbitrary bottleneck strip against its `floor(gap/pitch)` lanes.
//! Demand there is a routing decision, not a placement fact: which nets cross a
//! given strip depends on the paths the router picks, so any static count is a
//! guess, and a lint that guesses is worse than no lint.
//!
//! `escape-contended` is not that check, and the difference is the whole reason
//! it is admissible. Its strip is not arbitrary — it is one hub's own escape,
//! cut across the direction the fan leaves in — and its demand is not guessed:
//! a net with a pad on that hub and its counterparts on that side MUST cross
//! that hub's boundary there, whatever path the router picks afterwards.
//! Membership is placement, not routing.

const std = @import("std");
const optimizer = @import("optimizer.zig");
const geometry = @import("geometry.zig");
const pad_shape = @import("pad_shape.zig");
const pad_grid = @import("pad_grid.zig");
const escape_assign = @import("escape_assign.zig");
const port_escape = @import("port_escape.zig");
const plane_stitch = @import("plane_stitch.zig");
const power_route_width = @import("power_route_width.zig");

const Allocator = std.mem.Allocator;
const Placement = optimizer.Placement;
const Part = optimizer.Part;

/// Finding severity. Mirrors `layout_lint.Severity` rather than importing it:
/// this module sits below the loop/parasitic gates and shares no other type
/// with them, and the serve layer maps both onto the same `lint[]` words.
pub const Severity = enum { warn, info };

/// One side of a flagged situation — the pad, named the way every other PCB
/// surface names one (`ref` + pad number + net).
pub const Party = struct {
    ref: []const u8,
    pad: []const u8 = "",
    net: []const u8 = "",
};

/// The measurements behind a finding, so a caller can act on numbers instead of
/// re-deriving them from prose. `have_mm` is what the placement offers,
/// `need_mm` what the net class demands; `width_mm`/`clearance_mm` are the two
/// terms `need_mm` is built from. `exits_blocked` is meaningful only for
/// `pad-sealed` (always 8 there — a pad with a legal exit is not reported).
pub const Detail = struct {
    a: Party,
    b: ?Party = null,
    have_mm: f64 = 0,
    need_mm: f64 = 0,
    width_mm: f64 = 0,
    clearance_mm: f64 = 0,
    exits_blocked: u8 = 0,
};

/// The counts and cross-section behind an `escape-contended` finding. Separate
/// from `Detail` because none of these are the pad-to-pad millimetres the two
/// pad gates report — conflating a lane COUNT with a clearance in the same
/// `have_mm` field would make the JSON unreadable at both surfaces.
pub const Escape = struct {
    /// The side of the hub the fan leaves on ("west", "north", …).
    side: []const u8,
    /// Nets that must cross the hub's boundary on this side.
    nets: usize,
    /// Lanes the tightest cross-section offers them.
    lanes: usize,
    /// How many of the fan the joint assignment could seat in those lanes.
    seated: usize,
    /// Contiguous free bands the lanes are split across (>1 = bimodal, so the
    /// raw lane count overstates what any one net can reach).
    bands: usize,
    /// The cross-section those lanes were sliced from.
    cut: EscapeCut,
};

/// Where an `escape-contended` finding was measured: the cross-section's
/// position on the escape axis, its width on the lane axis, and the pitch its
/// lanes were sliced at. One value because the three only mean anything
/// together — `lanes` is what they produce.
pub const EscapeCut = struct {
    at_mm: f64,
    span_mm: f64,
    pitch_mm: f64,
};

/// A flagged situation. `refs` (the parts involved), `msg` and `suggestion` are
/// heap-owned — free the slice with `freeFindings`. `rule` is a static string;
/// the strings inside `detail` point into the placement and outlive nothing.
pub const Finding = struct {
    rule: []const u8,
    severity: Severity,
    refs: []const []const u8,
    msg: []const u8,
    detail: Detail,
    /// The `escape-contended` measurements; null on the two pad gates.
    escape: ?Escape = null,
    /// A paste-ready DSL fragment that would address this finding, or "" when
    /// the gate has no single edit to propose. Only `escape-contended` sets one
    /// today: detection deliberately steers nothing, so the proposed
    /// `(assign-escapes …)` wave is how it stays actionable.
    suggestion: []const u8 = "",
};

/// Cap on how many sealed pads are reported (tightest first) — see
/// `checkSealed`. Forty is far past "this board needs a decision"; a board over
/// it is unplaced, not over-constrained.
const max_sealed_findings: usize = 40;
/// Cap on how many part refs one bucketed finding lists. A board with 60
/// identical 0201s makes one finding, not sixty; past this the message says how
/// many more there are.
const max_refs_per_finding: usize = 40;
/// The eight octilinear escape directions the maze can actually leave a pad on
/// (the router is 45°-constrained), unit length.
const diag: f64 = std.math.sqrt1_2;
const escape_dirs = [8][2]f64{
    .{ 1, 0 },  .{ diag, diag },   .{ 0, 1 },  .{ -diag, diag },
    .{ -1, 0 }, .{ -diag, -diag }, .{ 0, -1 }, .{ diag, -diag },
};

/// What the caller knows that the placement does not.
pub const Options = struct {
    /// Net-index mask of the nets an authored `(assign-escapes …)` route wave
    /// already hands to the joint assignment. A fan every net of which is masked
    /// is not flagged — the author already decided about that escape. Empty (the
    /// default) masks nothing, which is every board that authors no such wave.
    escapes_assigned: []const bool = &.{},
    /// Net-index mask of the block's own `(port …)` nets
    /// (`port_escape.portNets`). A `Placement` carries no port declarations —
    /// they live on the `DesignBlock` — so the port-escape gate is silent unless
    /// the caller, who holds the block, supplies this. Empty (the default) is
    /// every design root that declares no port and every hand-built fixture.
    port_nets: []const bool = &.{},
};

/// Run every gate over a solved placement. Returns a heap slice of findings
/// (possibly empty) the caller frees with `freeFindings`.
pub fn preflight(alloc: Allocator, p: Placement, opts: Options) Allocator.Error![]Finding {
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const cache = try Cache.build(scratch.allocator(), p);
    return preflightCached(alloc, scratch.allocator(), p, opts, cache);
}

/// Run preflight with pose-independent pad/net metadata prepared by the caller.
/// Rough-routability repair evaluates several nearby poses of the same board;
/// only world shapes need rebuilding between those rounds.
pub fn preflightCached(alloc: Allocator, scratch: Allocator, p: Placement, opts: Options, cache: Cache) Allocator.Error![]Finding {
    return preflightCachedInner(alloc, scratch, p, opts, cache, true);
}

/// Pose-dependent subset used after rough repair moves. Corridor and adjacent
/// in-pad-via findings are invariant under the x/y-only moves repair proposes;
/// its baseline already measured them, and it neither acts on nor acceptance-
/// scores the via findings. Repeating them for every candidate pose was pure
/// work in the self-hosted Debug hot path.
pub fn preflightRepairCached(alloc: Allocator, scratch: Allocator, p: Placement, opts: Options, cache: Cache) Allocator.Error![]Finding {
    return preflightCachedInner(alloc, scratch, p, opts, cache, false);
}

fn preflightCachedInner(alloc: Allocator, scratch: Allocator, p: Placement, opts: Options, cache: Cache, include_static_gates: bool) Allocator.Error![]Finding {
    const board = try Board.buildCached(scratch, p, cache);

    var out: std.ArrayList(Finding) = .empty;
    errdefer {
        for (out.items) |f| freeFinding(alloc, f);
        out.deinit(alloc);
    }
    if (include_static_gates) {
        try checkCorridors(alloc, scratch, &board, &out);
        try checkViaInPad(alloc, scratch, &board, &out);
    }
    try checkSealed(alloc, scratch, &board, &out);
    try checkEscapes(alloc, scratch, p, opts, cache.escape, &out);
    try checkPorts(alloc, scratch, p, opts, board.port_pads, &out);
    return out.toOwnedSlice(alloc);
}

/// Free a slice returned by `preflight` (each finding's `refs`, `msg` and
/// `suggestion`, then the slice itself).
pub fn freeFindings(alloc: Allocator, findings: []Finding) void {
    for (findings) |f| freeFinding(alloc, f);
    alloc.free(findings);
}

fn freeFinding(alloc: Allocator, f: Finding) void {
    alloc.free(f.refs);
    alloc.free(f.msg);
    if (f.suggestion.len > 0) alloc.free(f.suggestion);
}

// ── The pad table ────────────────────────────────────────────────────────────

/// The per-net copper geometry a pad's escape must be measured at. Clearance is
/// cached per pad: pairwise clearance is simply the maximum of the two cached
/// values, avoiding a large `BoardRules` walk in the O(pads^2 * directions)
/// sealed-pad scan. A one-pad net has nothing to connect to; a plane-carried net
/// rejoins through the pour, so neither needs an escape.
const PadRule = struct {
    width: f64,
    clearance: f64,
    via_dia: f64,
    via_drill: f64,
    escapes: bool,
};

/// One pad in world space with everything the gates need and nothing else.
const PadInfo = struct {
    id: Party,
    part: usize,
    /// Flattened net index (`Placement.nets`), or -1 when the pad carries no
    /// net — still copper, so still an obstacle, but never a subject.
    net: i32,
    shape: pad_shape.Shape,
    rule: PadRule,
    side: optimizer.Side,
    thru: bool,
};

/// Pose-independent half of `PadInfo`, retained across repair rounds.
const StaticPad = struct {
    id: Party,
    part: usize,
    pad: geometry.Pad,
    /// World shape at the pose where the repair cache was built. Rough repair
    /// changes x/y only, so every later shape is this one translated by the
    /// owning part's displacement; rotations, side, and pad geometry stay
    /// fixed for the lifetime of the cache.
    shape: pad_shape.Shape,
    base_x: f64,
    base_y: f64,
    net: i32,
    rule: PadRule,
    side: optimizer.Side,
    thru: bool,
};

/// Static pad/net metadata for repeated preflights of one placement topology.
pub const Cache = struct {
    pads: []const StaticPad,
    bounds: []const [2]usize,
    grid_reach: f64,
    escape: escape_assign.DetectCache,

    /// Build topology, rules, and pose-invariant pad geometry for repair rounds.
    pub fn build(arena: Allocator, p: Placement) Allocator.Error!Cache {
        const lookup = try NetLookup.build(arena, p);
        var pads: std.ArrayList(StaticPad) = .empty;
        const bounds = try arena.alloc([2]usize, p.parts.len);
        var max_half_width: f64 = 0;
        var max_clearance: f64 = 0;
        for (p.parts, 0..) |part, pi| {
            bounds[pi][0] = pads.items.len;
            for (part.pads) |pad| {
                const info = try staticPadInfo(arena, p, lookup, part, pi, pad);
                max_half_width = @max(max_half_width, info.rule.width / 2);
                max_clearance = @max(max_clearance, info.rule.clearance);
                try pads.append(arena, info);
            }
            bounds[pi][1] = pads.items.len;
        }
        return .{
            .pads = try pads.toOwnedSlice(arena),
            .bounds = bounds,
            .grid_reach = max_half_width + max_clearance,
            .escape = try escape_assign.DetectCache.build(arena, p),
        };
    }
};

/// The placement, flattened once into world-space pads plus the per-part slices
/// and rule defaults both gates read.
const Board = struct {
    p: Placement,
    pads: []const PadInfo,
    /// Broad phase for point escape probes. Built with the largest clearance
    /// any pad pair can require, so `near` is always a superset of the exact
    /// `pointDist` hits and cannot alter a finding.
    pad_grid: ?*const pad_grid.PadGrid,
    /// Index-aligned with `p.parts`; each entry is that part's window into `pads`.
    part_pads: []const []const PadInfo,
    /// Same world shapes projected into the port flood's smaller view. Sharing
    /// this table avoids rebuilding every pad a second time in one preflight.
    port_pads: []const port_escape.PadView,

    fn buildCached(arena: Allocator, p: Placement, cache: Cache) Allocator.Error!Board {
        const flat = try arena.alloc(PadInfo, cache.pads.len);
        for (cache.pads, flat) |st, *pd| {
            const part = p.parts[st.part];
            pd.* = .{
                .id = st.id,
                .part = st.part,
                .net = st.net,
                .shape = try translatedShape(arena, st.shape, part.x - st.base_x, part.y - st.base_y),
                .rule = st.rule,
                .side = st.side,
                .thru = st.thru,
            };
        }
        const windows = try arena.alloc([]const PadInfo, p.parts.len);
        for (cache.bounds, 0..) |b, pi| windows[pi] = flat[b[0]..b[1]];
        const port_pads = try arena.alloc(port_escape.PadView, flat.len);
        for (flat, port_pads) |pd, *port_pd| {
            port_pd.* = .{
                .ref = pd.id.ref,
                .number = pd.id.pad,
                .net = pd.net,
                .shape = pd.shape,
                .side = pd.side,
                .thru = pd.thru,
            };
        }

        var minx = std.math.inf(f64);
        var miny = std.math.inf(f64);
        var maxx = -std.math.inf(f64);
        var maxy = -std.math.inf(f64);
        const obs = try arena.alloc(pad_grid.PadObs, flat.len);
        for (flat, 0..) |pd, i| {
            minx = @min(minx, pd.shape.x0);
            miny = @min(miny, pd.shape.y0);
            maxx = @max(maxx, pd.shape.x1);
            maxy = @max(maxy, pd.shape.y1);
            obs[i] = .{
                .x0 = pd.shape.x0,
                .y0 = pd.shape.y0,
                .x1 = pd.shape.x1,
                .y1 = pd.shape.y1,
                .poly = pd.shape.poly,
                .net = pd.net,
                .thru = pd.thru,
            };
        }
        const grid = if (flat.len == 0)
            null
        else
            pad_grid.PadGrid.build(arena, obs, .{ .minx = minx, .miny = miny, .maxx = maxx, .maxy = maxy }, cache.grid_reach);
        return .{
            .p = p,
            .pads = flat,
            .pad_grid = grid,
            .part_pads = windows,
            .port_pads = port_pads,
        };
    }

    /// True when `a` and `b` share copper — same net (nothing to keep apart), so
    /// no gate applies between them.
    fn sameNet(a: *const PadInfo, b: *const PadInfo) bool {
        // Flattened indexes are canonical when both pads have one. Falling
        // through to a string comparison for two different valid indexes was a
        // substantial Debug-build cost in the sealed-pad inner loop.
        if (a.net >= 0 and b.net >= 0) return a.net == b.net;
        return a.id.net.len > 0 and std.mem.eql(u8, a.id.net, b.id.net);
    }

    /// True when `a`'s copper can obstruct `b`'s: they share a copper face.
    /// A through-hole barrel exists on every layer, so it always can.
    fn sameFace(a: *const PadInfo, b: *const PadInfo) bool {
        return a.thru or b.thru or a.side == b.side;
    }
};

/// Translate a cached world shape after an x/y-only repair move. The overwhelmingly
/// common unchanged-part path returns the cached shape directly (including its
/// polygon slice), while moved polygon pads copy only their already-rotated
/// vertices. This removes repeated trig, outline construction, and ring
/// simplification from repair preflights without changing their geometry.
fn translatedShape(arena: Allocator, base: pad_shape.Shape, dx: f64, dy: f64) Allocator.Error!pad_shape.Shape {
    if (dx == 0 and dy == 0) return base;
    const poly = if (base.poly.len == 0) &.{} else blk: {
        const out = try arena.alloc([2]f64, base.poly.len);
        for (base.poly, out) |point, *dst| dst.* = .{ point[0] + dx, point[1] + dy };
        break :blk out;
    };
    return .{
        .x0 = base.x0 + dx,
        .y0 = base.y0 + dy,
        .x1 = base.x1 + dx,
        .y1 = base.y1 + dy,
        .poly = poly,
    };
}

/// Pairwise copper clearance is the maximum of the two net-class requirements;
/// each cached value already includes the board default.
fn pairClearance(a: *const PadInfo, b: *const PadInfo) f64 {
    return @max(a.rule.clearance, b.rule.clearance);
}

/// `ref|pad` → flattened net index + name, plus the per-net pin counts and
/// plane membership the escape gate keys off.
const NetLookup = struct {
    of_pad: std.StringHashMapUnmanaged(u32),
    /// Per-net: does this net need a surface escape at all? False for a net with
    /// under two pins (nothing to reach) and for a plane-carried net (a pour via
    /// rejoins it without a track leaving the pad sideways).
    escapes: []const bool,

    fn build(arena: Allocator, p: Placement) Allocator.Error!NetLookup {
        var of_pad = std.StringHashMapUnmanaged(u32).empty;
        const escapes = try arena.alloc(bool, p.nets.len);
        for (p.nets, 0..) |net, ni| {
            // `netHasPlane` is the shared predicate, so a board that declares NO
            // `(stackup …)` still exempts its grounds: the router's legacy
            // implicit model gives those a plane, and their pads rejoin by via.
            // Checking only DECLARED planes read every QFN thermal ground pad on
            // a stackup-less board as sealed.
            escapes[ni] = net.pins.len >= 2 and !plane_stitch.netHasPlane(p, net.name);
            for (net.pins) |pin| {
                const key = try std.fmt.allocPrint(arena, "{s}|{s}", .{ pin.ref_des, pin.pin });
                try of_pad.put(arena, key, @intCast(ni));
            }
        }
        return .{ .of_pad = of_pad, .escapes = escapes };
    }

    fn find(self: NetLookup, arena: Allocator, ref: []const u8, pad: []const u8) Allocator.Error!?u32 {
        const key = try std.fmt.allocPrint(arena, "{s}|{s}", .{ ref, pad });
        return self.of_pad.get(key);
    }
};

fn staticPadInfo(
    arena: Allocator,
    p: Placement,
    lookup: NetLookup,
    part: Part,
    pi: usize,
    pad: geometry.Pad,
) Allocator.Error!StaticPad {
    const ni = try lookup.find(arena, part.ref_des, pad.number);
    const net: i32 = if (ni) |n| @intCast(n) else -1;
    const name: []const u8 = if (ni) |n| p.nets[n].name else "";
    const rule: PadRule = .{
        .width = netWidth(p, net),
        .clearance = p.rules.clearanceForNet(net, p.rules.design.clearance),
        .via_dia = netViaDia(p, net),
        .via_drill = netViaDrill(p, net),
        .escapes = if (ni) |n| lookup.escapes[n] else false,
    };
    return .{
        .id = .{ .ref = part.ref_des, .pad = pad.number, .net = name },
        .part = pi,
        .net = net,
        .pad = pad,
        .shape = try pad_shape.worldShape(arena, part, pad),
        .base_x = part.x,
        .base_y = part.y,
        .rule = rule,
        .side = part.side,
        .thru = pad.thru,
    };
}

/// The track width net `net` is routed at: its `(net-class … (width …))` when it
/// declares one, else the board's `(design-rules (track-width …))` default, then
/// reduced to an ordinary fabrication-legal centreline when an unpoured rail
/// will be widened adaptively after routing. This is the geometry that must fit
/// through a corridor; the electrical target is checked on finished copper.
///
/// One deliberate difference: the router also exempts a rail carried by an
/// EXISTING hand-drawn copper zone, and a `Placement` holds no zones — only the
/// DECLARED planes are visible here. A saved zone is therefore conservatively
/// treated as absent and may make a warning measure a narrower search path than
/// the exact sheet-aware fanout eventually uses.
fn netWidth(p: Placement, net: i32) f64 {
    if (net < 0) return p.rules.design.track_width;
    const i: usize = @intCast(net);
    var width = p.rules.design.track_width;
    if (i < p.rules.net.len and p.rules.net[i].width > 0) width = p.rules.net[i].width;
    if (i >= p.nets.len) return width;
    if (power_route_width.adaptiveTargetWidth(&.{}, p, i, width) != null)
        return @max(p.rules.design.min_width, @min(width, p.rules.design.track_width));
    return power_route_width.exactWidth(&.{}, p, i, width);
}

fn netViaDia(p: Placement, net: i32) f64 {
    if (net < 0) return p.rules.design.via_dia;
    const i: usize = @intCast(net);
    if (i >= p.rules.net.len or p.rules.net[i].via_dia <= 0) return p.rules.design.via_dia;
    return p.rules.net[i].via_dia;
}

fn netViaDrill(p: Placement, net: i32) f64 {
    if (net < 0) return p.rules.design.via_drill;
    const i: usize = @intCast(net);
    if (i >= p.rules.net.len or p.rules.net[i].via_drill <= 0) return p.rules.design.via_drill;
    return p.rules.net[i].via_drill;
}

// ── Gate 1: sibling-pad corridors ────────────────────────────────────────────

/// `pad-corridor-tight`: two pads of the same part, on different nets, facing
/// each other across a lane narrower than `max(width)/2 + clearance`. A track
/// entering either pad from between them has its centreline on the pad's inboard
/// edge at best, so half its copper is already in the lane — if the rest of the
/// lane is under the clearance rule, that entry is illegal at every ordering the
/// router could pick. The copper must arrive at the outboard end instead.
///
/// Findings are BUCKETED by their (gap, need) millimetre signature: a board with
/// sixty identical 0201s on one rail has one situation, not sixty, and sixty
/// findings would bury the one QFN row that actually needs a decision.
fn checkCorridors(
    alloc: Allocator,
    arena: Allocator,
    b: *const Board,
    out: *std.ArrayList(Finding),
) Allocator.Error!void {
    var buckets: std.array_hash_map.String(Bucket) = .empty;
    for (b.p.parts, 0..) |_, pi| {
        const pads = b.part_pads[pi];
        for (pads, 0..) |*a, ai| {
            for (pads[ai + 1 ..]) |*c| {
                if (Board.sameNet(a, c) or !Board.sameFace(a, c)) continue;
                const lane = facingGap(a.shape, c.shape) orelse continue;
                const clear = pairClearance(a, c);
                const need = @max(a.rule.width, c.rule.width) / 2 + clear;
                if (lane >= need) continue;
                try recordCorridor(arena, &buckets, .{ .gap = lane, .need = need, .clear = clear }, a.*, c.*);
            }
        }
    }
    for (buckets.values()) |bk| try out.append(alloc, try bk.finish(alloc));
}

/// The three millimetre quantities one corridor bucket is keyed and reported on.
const CorridorMm = struct { gap: f64, need: f64, clear: f64 };

/// One bucketed corridor situation: the representative pad pair, the numbers,
/// and every part exhibiting it.
const Bucket = struct {
    mm: CorridorMm,
    a: Party,
    b: Party,
    refs: std.ArrayList([]const u8),
    pairs: usize,

    fn finish(self: Bucket, alloc: Allocator) Allocator.Error!Finding {
        const shown = @min(self.refs.items.len, max_refs_per_finding);
        return .{
            .rule = "pad-corridor-tight",
            .severity = .warn,
            .refs = try alloc.dupe([]const u8, self.refs.items[0..shown]),
            .msg = try std.fmt.allocPrint(
                alloc,
                "pads face each other across {d:.3} mm but a track entering either " ++
                    "one from between them needs {d:.3} mm (width {d:.4}/2 + clearance {d:.3}); " ++
                    "no ordering or priority can enter these pads along the pad axis — bring the " ++
                    "copper in at the outboard end, or lower the net class width. " ++
                    "{d} pad pair(s) on {d} part(s) ({d} listed), e.g. {s} pad {s} ({s}) vs pad {s} ({s})",
                .{
                    self.mm.gap, self.mm.need,        maxWidth(self), self.mm.clear,
                    self.pairs,  self.refs.items.len, shown,          self.a.ref,
                    self.a.pad,  self.a.net,          self.b.pad,     self.b.net,
                },
            ),
            .detail = .{
                .a = self.a,
                .b = self.b,
                .have_mm = self.mm.gap,
                .need_mm = self.mm.need,
                .width_mm = maxWidth(self),
                .clearance_mm = self.mm.clear,
            },
        };
    }

    /// The width term of `need`, recovered from the two reported numbers so the
    /// message and the detail never disagree.
    fn maxWidth(self: Bucket) f64 {
        return (self.mm.need - self.mm.clear) * 2;
    }
};

fn recordCorridor(
    arena: Allocator,
    buckets: *std.array_hash_map.String(Bucket),
    mm: CorridorMm,
    a: PadInfo,
    c: PadInfo,
) Allocator.Error!void {
    const key = try std.fmt.allocPrint(arena, "{d:.4}|{d:.4}", .{ mm.gap, mm.need });
    const slot = try buckets.getOrPut(arena, key);
    if (!slot.found_existing) {
        slot.value_ptr.* = .{ .mm = mm, .a = a.id, .b = c.id, .refs = .empty, .pairs = 0 };
    }
    slot.value_ptr.pairs += 1;
    for (slot.value_ptr.refs.items) |r| {
        if (std.mem.eql(u8, r, a.id.ref)) return;
    }
    try slot.value_ptr.refs.append(arena, a.id.ref);
}

/// The lane (mm, edge to edge) two pad boxes face each other across, or null
/// when they are diagonal neighbours (no shared span, so nothing routes
/// "between" them) or already overlap.
fn facingGap(a: pad_shape.Shape, b: pad_shape.Shape) ?f64 {
    const ox = @min(a.x1, b.x1) - @max(a.x0, b.x0);
    const oy = @min(a.y1, b.y1) - @max(a.y0, b.y0);
    if (ox > 0 and oy <= 0) return -oy;
    if (oy > 0 and ox <= 0) return -ox;
    return null;
}

// ── Gate 2: adjacent in-pad via feasibility ─────────────────────────────────

/// Flag sibling SMD pads whose centres cannot both carry their respective
/// through-vias. This is a static scheduling fact, not a claim that neither net
/// can escape: one may transition at the pad while the other must surface-fan
/// far enough away first.
fn checkViaInPad(
    alloc: Allocator,
    arena: Allocator,
    b: *const Board,
    out: *std.ArrayList(Finding),
) Allocator.Error!void {
    var buckets: std.array_hash_map.String(ViaBucket) = .empty;
    for (b.p.parts, 0..) |_, pi| {
        const pads = b.part_pads[pi];
        for (pads, 0..) |*a, ai| {
            if (a.thru or !a.rule.escapes) continue;
            for (pads[ai + 1 ..]) |*c| {
                if (!viaPairEligible(a, c)) continue;
                const have = std.math.hypot(
                    (a.shape.x0 + a.shape.x1 - c.shape.x0 - c.shape.x1) / 2,
                    (a.shape.y0 + a.shape.y1 - c.shape.y0 - c.shape.y1) / 2,
                );
                const clear = pairClearance(a, c);
                const copper_need = (a.rule.via_dia + c.rule.via_dia) / 2 + clear;
                const drill_need = (a.rule.via_drill + c.rule.via_drill) / 2 + b.p.rules.design.hole_to_hole;
                const need = @max(copper_need, drill_need);
                if (have >= need) continue;
                const key = try std.fmt.allocPrint(arena, "{d:.4}|{d:.4}", .{ have, need });
                const slot = try buckets.getOrPut(arena, key);
                if (!slot.found_existing) slot.value_ptr.* = .{
                    .have = have,
                    .need = need,
                    .clear = clear,
                    .a = a.*,
                    .b = c.*,
                    .refs = .empty,
                    .pairs = 0,
                };
                slot.value_ptr.pairs += 1;
                if (!containsName(slot.value_ptr.refs.items, a.id.ref)) try slot.value_ptr.refs.append(arena, a.id.ref);
            }
        }
    }
    for (buckets.values()) |bucket| try out.append(alloc, try bucket.finish(alloc));
}

fn viaPairEligible(a: *const PadInfo, b: *const PadInfo) bool {
    if (b.thru) return false;
    if (!b.rule.escapes) return false;
    if (Board.sameNet(a, b)) return false;
    return Board.sameFace(a, b);
}

fn containsName(items: []const []const u8, name: []const u8) bool {
    for (items) |item| if (std.mem.eql(u8, item, name)) return true;
    return false;
}

const ViaBucket = struct {
    have: f64,
    need: f64,
    clear: f64,
    a: PadInfo,
    b: PadInfo,
    refs: std.ArrayList([]const u8),
    pairs: usize,

    fn finish(self: ViaBucket, alloc: Allocator) Allocator.Error!Finding {
        const shown = @min(self.refs.items.len, max_refs_per_finding);
        return .{
            .rule = "via-in-pad-conflict",
            .severity = .warn,
            .refs = try alloc.dupe([]const u8, self.refs.items[0..shown]),
            .msg = try std.fmt.allocPrint(
                alloc,
                "adjacent pads are {d:.4} mm centre-to-centre, but their net-class vias need " ++
                    "{d:.4} mm for copper/drill spacing. Both escapes cannot use pad-centred " ++
                    "through-vias: reserve one transition and surface-fan the other before its via. " ++
                    "{d} pad pair(s) on {d} part(s), e.g. {s} pad {s} ({s}, via {d:.3}/{d:.3}) " ++
                    "vs pad {s} ({s}, via {d:.3}/{d:.3})",
                .{
                    self.have,             self.need,     self.pairs,    self.refs.items.len,
                    self.a.id.ref,         self.a.id.pad, self.a.id.net, self.a.rule.via_dia,
                    self.a.rule.via_drill, self.b.id.pad, self.b.id.net, self.b.rule.via_dia,
                    self.b.rule.via_drill,
                },
            ),
            .detail = .{
                .a = self.a.id,
                .b = self.b.id,
                .have_mm = self.have,
                .need_mm = self.need,
                .width_mm = @max(self.a.rule.via_dia, self.b.rule.via_dia),
                .clearance_mm = self.clear,
            },
        };
    }
};

// ── Gate 3: sealed pads ──────────────────────────────────────────────────────

/// `pad-sealed`: a pad none of whose eight octilinear exits clears foreign
/// copper at its own class geometry. This is the static form of the router's
/// own "could not break out of its own footprint" diagnosis — but reported
/// before a solve, from the placement, so the fix (move the neighbour, or
/// narrow the class) is obvious rather than inferred from a failed route.
///
/// The report is capped at the `max_sealed_findings` TIGHTEST pads (smallest
/// best-direction clearance first). A board that produces more than that is not
/// marginally over-constrained, it is unplaced — parts still piled in the
/// staging band, which the `unplaced` lint already says once instead of once per
/// pad (measured: `labstation`, which routes 0/189 nets at its saved layout,
/// yields 104). Capping keeps one broken board from burying a good board's
/// findings in a shared `lint[]`.
fn checkSealed(alloc: Allocator, arena: Allocator, b: *const Board, out: *std.ArrayList(Finding)) Allocator.Error!void {
    var hits: std.ArrayList(Sealed) = .empty;
    for (b.pads) |*pd| {
        if (!pd.rule.escapes) continue;
        const blocked = sealedBy(b, pd) orelse continue;
        try hits.append(arena, .{ .pad = pd.*, .blocked = blocked });
    }
    std.mem.sort(Sealed, hits.items, {}, tighterFirst);
    for (hits.items[0..@min(hits.items.len, max_sealed_findings)]) |h| {
        try out.append(alloc, try sealedFinding(alloc, h.pad, h.blocked));
    }
}

/// One sealed pad awaiting formatting: the victim plus its near-miss direction.
const Sealed = struct { pad: PadInfo, blocked: Blocked };

/// Order sealed pads worst-first — least room on the best available exit.
fn tighterFirst(_: void, a: Sealed, b: Sealed) bool {
    return a.blocked.have < b.blocked.have;
}

/// The blocked direction that came CLOSEST to working, or null when some
/// direction is already legal. Reporting the near-miss (rather than an
/// arbitrary blocked one) names the neighbour actually worth moving and the
/// millimetres that move has to buy.
fn sealedBy(b: *const Board, pd: *const PadInfo) ?Blocked {
    var best: ?Blocked = null;
    for (escape_dirs) |d| {
        const hit = escapeBlocker(b, pd, d) orelse return null;
        if (best == null or hit.have > best.?.have) best = hit;
    }
    return best;
}

/// A blocked escape direction: the pad in the way, how much room the escape
/// site actually has (mm) and how much it needed.
const Blocked = struct { pad: PadInfo, have: f64, need: f64 };

/// The tightest obstruction of the escape leaving `pd` in direction `d`, or
/// null when that direction is legal.
///
/// The test site is the first track-centre position one HALF-WIDTH outside the
/// pad edge — the point at which the copper has genuinely emerged from the pad
/// rather than still being pad. Deliberately a point rather than a swept
/// corridor: a track only has to get clear of the pad's immediate neighbourhood
/// before it may turn, and a fixed-length straight probe called pads sealed that
/// have a perfectly good short lane to turn in (measured on barracuda's
/// `lmx2595/U17` pad 3, which has 0.35 mm of free lane west against a 0.19 mm
/// halo, yet failed a 0.5 mm straight probe).
fn escapeBlocker(b: *const Board, pd: *const PadInfo, d: [2]f64) ?Blocked {
    const half = pd.rule.width / 2;
    const edge = rayExit(pd.shape, d);
    const sx = edge[0] + d[0] * half;
    const sy = edge[1] + d[1] * half;
    var worst: ?Blocked = null;
    if (b.pad_grid) |grid| {
        for (grid.near(sx, sy)) |qi| considerEscapeBlocker(pd, &b.pads[qi], sx, sy, half, &worst);
    } else {
        for (b.pads) |*q| considerEscapeBlocker(pd, q, sx, sy, half, &worst);
    }
    return worst;
}

inline fn considerEscapeBlocker(pd: *const PadInfo, q: *const PadInfo, sx: f64, sy: f64, half: f64, worst: *?Blocked) void {
    if (q.part == pd.part and std.mem.eql(u8, q.id.pad, pd.id.pad)) return;
    if (Board.sameNet(pd, q) or !Board.sameFace(pd, q)) return;
    const need = half + pairClearance(pd, q);
    const have = pad_shape.pointDist(q.shape.x0, q.shape.y0, q.shape.x1, q.shape.y1, q.shape.poly, sx, sy, need);
    if (have >= need) return;
    if (worst.* == null or have < worst.*.?.have) worst.* = .{ .pad = q.*, .have = have, .need = need };
}

/// Where a ray from the centre of `s` in direction `d` leaves the pad's box.
/// Custom (polygon) pads use their bounding box here — placing the escape site
/// slightly further out is the conservative side of this test.
fn rayExit(s: pad_shape.Shape, d: [2]f64) [2]f64 {
    const cx = (s.x0 + s.x1) / 2;
    const cy = (s.y0 + s.y1) / 2;
    var t = std.math.inf(f64);
    if (@abs(d[0]) > 1e-12) t = @min(t, ((if (d[0] > 0) s.x1 else s.x0) - cx) / d[0]);
    if (@abs(d[1]) > 1e-12) t = @min(t, ((if (d[1] > 0) s.y1 else s.y0) - cy) / d[1]);
    if (!std.math.isFinite(t)) t = 0;
    return .{ cx + d[0] * t, cy + d[1] * t };
}

fn sealedFinding(alloc: Allocator, pd: PadInfo, hit: Blocked) Allocator.Error!Finding {
    const blocker = hit.pad;
    var refs = [_][]const u8{ pd.id.ref, blocker.id.ref };
    const n: usize = if (std.mem.eql(u8, pd.id.ref, blocker.id.ref)) 1 else 2;
    return .{
        .rule = "pad-sealed",
        .severity = .warn,
        .refs = try alloc.dupe([]const u8, refs[0..n]),
        .msg = try std.fmt.allocPrint(
            alloc,
            "pad {s} on net {s} has no legal escape: in all 8 octilinear directions the " ++
                "first track-centre outside the pad sits inside foreign copper's halo " ++
                "(width {d:.4}/2 + clearance {d:.3} = {d:.4} mm). The best direction clears " ++
                "only {d:.4} mm, short by {d:.4} mm, against {s} pad {s} (net {s}). No route " ++
                "can start here — move that neighbour, rotate the part, or narrow the net class.",
            .{
                pd.id.pad,           pd.id.net,
                pd.rule.width,       hit.need - pd.rule.width / 2,
                hit.need,            hit.have,
                hit.need - hit.have, blocker.id.ref,
                blocker.id.pad,      blocker.id.net,
            },
        ),
        .detail = .{
            .a = pd.id,
            .b = blocker.id,
            .have_mm = hit.have,
            .need_mm = hit.need,
            .width_mm = pd.rule.width,
            .clearance_mm = pairClearance(&pd, &blocker),
            .exits_blocked = escape_dirs.len,
        },
    };
}

// ── Gate 3: contended escape fans ────────────────────────────────────────────

/// `escape-contended`: a hub side that more nets leave through than the
/// corridor there can seat. The measurement is `escape_assign.detect`'s — the
/// module that owns the cut scan and the joint schedule — so this gate is a
/// reporting shell and cannot drift from what an authored `(assign-escapes …)`
/// would actually do with the same fan.
///
/// The finding steers nothing. It names the fan, the cross-section, the
/// shortfall, and the one-line wave that would schedule it, and leaves the
/// decision to whoever reads it: on the measured barracuda case any automatic
/// steering of that fan costs a routed net, so the tidier board is not free.
fn checkEscapes(
    alloc: Allocator,
    arena: Allocator,
    p: Placement,
    opts: Options,
    cache: escape_assign.DetectCache,
    out: *std.ArrayList(Finding),
) Allocator.Error!void {
    const found = try escape_assign.detectCached(arena, p, .{ .assigned = opts.escapes_assigned }, cache);
    for (found) |c| try out.append(alloc, try escapeFinding(alloc, arena, p, c));
}

fn escapeFinding(
    alloc: Allocator,
    arena: Allocator,
    p: Placement,
    c: escape_assign.Contention,
) Allocator.Error!Finding {
    const refs = [_][]const u8{c.hub};
    const span = c.corridor.hi - c.corridor.lo;
    return .{
        .rule = "escape-contended",
        .severity = .warn,
        .refs = try alloc.dupe([]const u8, &refs),
        .msg = try std.fmt.allocPrint(
            alloc,
            "{d} nets must leave {s} on its {s} side, and the tightest cross-section there — " ++
                "at {d:.2} mm, {d:.2} mm wide, {d} lane(s) at {d:.4} mm pitch across {d} band(s) — " ++
                "seats only {d} of them. The other {d} route into whatever the earlier nets left, " ++
                "and no routing ORDER fixes that: whichever net goes first takes the same lane. " ++
                "Nothing is steered by this finding — author the suggested (assign-escapes …) wave " ++
                "to schedule the whole fan into parallel lanes at once.",
            .{
                c.nets.len, c.hub,       @tagName(c.corridor.dir), c.corridor.cut,
                span,       c.lanes,     c.corridor.pitch,         c.bands,
                c.seated,   c.refused(),
            },
        ),
        .detail = .{ .a = .{ .ref = c.hub } },
        .escape = .{
            .side = @tagName(c.corridor.dir),
            .nets = c.nets.len,
            .lanes = c.lanes,
            .seated = c.seated,
            .bands = c.bands,
            .cut = .{ .at_mm = c.corridor.cut, .span_mm = span, .pitch_mm = c.corridor.pitch },
        },
        .suggestion = try alloc.dupe(u8, try escape_assign.suggestDsl(arena, p, c)),
    };
}

// ── Gate 4: ports that cannot leave the block ────────────────────────────────

/// `port-blocked`: a `(port …)` net with no corridor out of the block's own
/// courtyard bounding box and no reachable spot a via of its class fits in. The
/// measurement is `port_escape.detect`'s — the module that owns the hull, the
/// obstacle model and the flood — so this gate is a reporting shell.
///
/// It is the only gate here that needs something the `Placement` does not carry:
/// a port lives on the `DesignBlock`, so `Options.port_nets` is how the caller
/// who holds the block turns the gate on. Without it the gate is silent, which
/// is the right answer for a surface that cannot tell a port from any other net.
fn checkPorts(
    alloc: Allocator,
    arena: Allocator,
    p: Placement,
    opts: Options,
    pads: []const port_escape.PadView,
    out: *std.ArrayList(Finding),
) Allocator.Error!void {
    if (opts.port_nets.len == 0) return;
    const blocked = try port_escape.detectWithPads(arena, p, opts.port_nets, pads);
    for (blocked) |b| try out.append(alloc, try portFinding(alloc, b));
}

/// `refs[0]` is the blocked pad's own part and `refs[1..]` the movable walls, in
/// the order a repair should try them. The repair round reads exactly that, so
/// the finding is the whole instruction rather than a prose hint plus a lookup.
fn portFinding(alloc: Allocator, b: port_escape.Blocked) Allocator.Error!Finding {
    var refs: std.ArrayList([]const u8) = .empty;
    errdefer refs.deinit(alloc);
    try refs.append(alloc, b.ref);
    try refs.appendSlice(alloc, b.blockers);
    return .{
        .rule = "port-blocked",
        .severity = .warn,
        .refs = try refs.toOwnedSlice(alloc),
        .msg = try std.fmt.allocPrint(
            alloc,
            "port net {s} cannot leave this block: from {s} pad {s} no corridor of " ++
                "{d:.4} mm (width {d:.4} + 2x clearance {d:.3}) reaches outside the parts' " ++
                "courtyard bounding box, and nowhere it can reach has room for a via of " ++
                "its class. The least-blocked way out clears {d:.4} mm where it needs " ++
                "{d:.4} mm, against {s}. A port is this block's contract with the board it " ++
                "is stamped onto and nothing inside routes it, so no router or DRC will " ++
                "report this — move the parts fencing the pad, or rotate the part so the " ++
                "pad faces open space.",
            .{
                b.name,
                b.ref,
                b.pad,
                b.mm.width + 2 * b.mm.clearance,
                b.mm.width,
                b.mm.clearance,
                b.mm.have,
                b.mm.need,
                blockerList(b),
            },
        ),
        .detail = .{
            .a = .{ .ref = b.ref, .pad = b.pad, .net = b.name },
            .b = if (b.blocker) |x| .{ .ref = x.ref, .pad = x.pad } else null,
            .have_mm = b.mm.have,
            .need_mm = b.mm.need,
            .width_mm = b.mm.width,
            .clearance_mm = b.mm.clearance,
        },
    };
}

/// The blocking part named in the message — the tightest MOVABLE one when there
/// is one, else the pad's own part, else a plain statement that nothing was
/// measured (a pad whose every seed cell was already illegal).
fn blockerList(b: port_escape.Blocked) []const u8 {
    if (b.blocker) |x| return x.ref;
    if (b.blockers.len > 0) return b.blockers[0];
    return "its own footprint";
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;
const flat_netlist = @import("../flat_netlist.zig");
const impedance = @import("impedance.zig");
const power_budget = @import("../eval/power_budget.zig");
const power_capacity = @import("power_capacity.zig");

fn tPad(n: []const u8, x: f64, y: f64, w: f64, h: f64) geometry.Pad {
    return .{ .number = n, .x = x, .y = y, .w = w, .h = h };
}

fn tPlacement(parts: []Part, nets: []const flat_netlist.FlatNet, rules: optimizer.BoardRules) Placement {
    return .{
        .parts = parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = nets,
        .rules = rules,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -10,
        .miny = -10,
        .maxx = 10,
        .maxy = 10,
        .generated = true,
    };
}

/// Zero values for the escape fixture's arrays, so its fields need no
/// `undefined` placeholder before `build` fills them.
const blank_pad: geometry.Pad = .{ .number = "", .x = 0, .y = 0, .w = 0, .h = 0 };
const blank_part: Part = .{ .ref_des = "", .kind = .passive, .hw = 0, .hh = 0, .pads = &.{}, .fallback = false };
const blank_pin: flat_netlist.FlatPin = .{ .ref_des = "", .pin = "" };
const blank_net: flat_netlist.FlatNet = .{ .name = "", .pins = &.{} };

/// A four-net escape fan out of connector `J1` heading west, with a wall across
/// the corridor. `wall_hh` sets how much of the cross-section the wall eats: at
/// 3.5 it leaves one lane on either side of it (four nets, two lanes), at 0.5 it
/// leaves four each, which the fan fits into comfortably.
const EscapeFan = struct {
    hub_pads: [4]geometry.Pad = @splat(blank_pad),
    leg: [1]geometry.Pad = .{blank_pad},
    parts: [6]Part = @splat(blank_part),
    pins: [4][2]flat_netlist.FlatPin = @splat(.{ blank_pin, blank_pin }),
    nets: [4]flat_netlist.FlatNet = @splat(blank_net),

    const ys = [_]f64{ -1.5, -0.5, 0.5, 1.5 };
    const dests = [_][]const u8{ "R1", "R2", "R3", "R4" };
    const names = [_][]const u8{ "SPI_A", "SPI_B", "SPI_C", "SPI_D" };
    const pad_names = [_][]const u8{ "1", "2", "3", "4" };

    fn build(self: *EscapeFan, wall_hh: f64) Placement {
        self.leg = .{tPad("1", 0, 0, 0.4, 0.4)};
        for (ys, 0..) |y, i| {
            self.hub_pads[i] = tPad(pad_names[i], -0.5, y, 0.4, 0.4);
            self.parts[i + 1] = tLeaf(dests[i], -9, y, &self.leg);
            self.pins[i] = .{
                .{ .ref_des = "J1", .pin = pad_names[i] },
                .{ .ref_des = dests[i], .pin = "1" },
            };
            self.nets[i] = .{ .name = names[i], .pins = &self.pins[i] };
        }
        self.parts[0] = tBox("J1", .hub, .{ 9, 0 }, .{ 1, 4 }, &self.hub_pads);
        self.parts[5] = tBox("WALL", .passive, .{ 4, 0 }, .{ 4, wall_hh }, &self.leg);
        return tPlacement(&self.parts, &self.nets, .{ .design = .{ .track_width = 0.4, .clearance = 0.6 } });
    }
};

fn tLeaf(ref: []const u8, x: f64, y: f64, pads: []const geometry.Pad) Part {
    return tBox(ref, .passive, .{ x, y }, .{ 0.5, 0.5 }, pads);
}

fn tBox(
    ref: []const u8,
    kind: optimizer.PartKind,
    at: [2]f64,
    half: [2]f64,
    pads: []const geometry.Pad,
) Part {
    return .{
        .ref_des = ref,
        .kind = kind,
        .hw = half[0],
        .hh = half[1],
        .pads = pads,
        .fallback = false,
        .x = at[0],
        .y = at[1],
    };
}

/// Fixture builder for the cap test: one walled-in victim pad per cell, cells
/// 20 mm apart so they cannot see each other. Every wall of cell `i` closes in
/// by the same step, so victim `i` is strictly tighter than victim `i-1` in
/// every direction — which makes "the report keeps the tightest" checkable.
fn fillSealedCells(pads: [][5]geometry.Pad, parts: []Part, pins: []flat_netlist.FlatPin) void {
    for (pads, 0..) |*cell, i| {
        const s = @as(f64, @floatFromInt(i)) * 0.0002;
        const ox = @as(f64, @floatFromInt(i)) * 20.0;
        cell.* = .{
            tPad("1", 0, 0, 0.3, 0.3),
            tPad("1", -(0.35 - s), 0, 0.3, 1.0),
            tPad("2", 0.35 - s, 0, 0.3, 1.0),
            tPad("3", 0, -(0.375 - s), 1.0, 0.25),
            tPad("4", 0, 0.375 - s, 1.0, 0.25),
        };
        parts[2 * i] = .{ .ref_des = "V", .kind = .hub, .hw = 1.5, .hh = 1.5, .pads = cell[0..1], .fallback = false, .x = ox, .y = 0 };
        parts[2 * i + 1] = .{ .ref_des = "W", .kind = .hub, .hw = 1.5, .hh = 1.5, .pads = cell[1..5], .fallback = false, .x = ox, .y = 0 };
        pins[2 * i] = .{ .ref_des = "V", .pin = "1" };
        pins[2 * i + 1] = .{ .ref_des = "FAR", .pin = "1" };
    }
}

fn findRule(findings: []const Finding, rule: []const u8) ?Finding {
    for (findings) |f| {
        if (std.mem.eql(u8, f.rule, rule)) return f;
    }
    return null;
}

// spec: placement/routability_lint - flags two pads of one part facing across less than half a track plus clearance
test "preflight flags the sibling-pad corridor of a 0201 on a wide rail" {
    // The measured barracuda case: adf4159/C116, pads 0.400 x 0.460 with
    // centres 0.640 mm apart => a 0.180 mm lane, against the "power" class
    // (width 0.2532, clearance 0.127) demanding 0.2536 mm.
    var pads = [_]geometry.Pad{
        tPad("1", 0, -0.32, 0.400, 0.460),
        tPad("2", 0, 0.32, 0.400, 0.460),
    };
    var parts = [_]Part{
        .{ .ref_des = "C116", .kind = .passive, .hw = 0.5, .hh = 0.6, .pads = &pads, .fallback = false, .x = 0, .y = 0 },
    };
    const rail = [_]flat_netlist.FlatPin{ .{ .ref_des = "C116", .pin = "1" }, .{ .ref_des = "U1", .pin = "1" } };
    const gnd = [_]flat_netlist.FlatPin{ .{ .ref_des = "C116", .pin = "2" }, .{ .ref_des = "U1", .pin = "2" } };
    const nets = [_]flat_netlist.FlatNet{
        .{ .name = "V_1V8A", .pins = &rail },
        .{ .name = "GND", .pins = &gnd },
    };
    const rules = [_]optimizer.NetRule{
        .{ .width = 0.2532, .clearance = 0.127 },
        .{ .width = 0.2532, .clearance = 0.127 },
    };
    const p = tPlacement(&parts, &nets, .{ .net = &rules });

    const findings = try preflight(testing.allocator, p, .{});
    defer freeFindings(testing.allocator, findings);
    const f = findRule(findings, "pad-corridor-tight") orelse return error.TestExpectedEqual;
    try testing.expectEqual(Severity.warn, f.severity);
    try testing.expectEqualStrings("C116", f.refs[0]);
    try testing.expectApproxEqAbs(@as(f64, 0.180), f.detail.have_mm, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.2536), f.detail.need_mm, 1e-9);
}

// spec: placement/routability_lint - a corridor wide enough for the net class's copper is not flagged
test "preflight leaves a roomy sibling-pad corridor alone" {
    // Same pads on the board default geometry (width 0.127, clearance 0.127):
    // the lane needs 0.1905 mm and a 0402-style 0.400 mm lane clears it.
    var pads = [_]geometry.Pad{
        tPad("1", 0, -0.48, 0.560, 0.560),
        tPad("2", 0, 0.48, 0.560, 0.560),
    };
    var parts = [_]Part{
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.6, .hh = 0.8, .pads = &pads, .fallback = false, .x = 0, .y = 0 },
    };
    const rail = [_]flat_netlist.FlatPin{ .{ .ref_des = "C1", .pin = "1" }, .{ .ref_des = "U1", .pin = "1" } };
    const gnd = [_]flat_netlist.FlatPin{ .{ .ref_des = "C1", .pin = "2" }, .{ .ref_des = "U1", .pin = "2" } };
    const nets = [_]flat_netlist.FlatNet{
        .{ .name = "VDD", .pins = &rail },
        .{ .name = "GND", .pins = &gnd },
    };
    const p = tPlacement(&parts, &nets, .{});

    const findings = try preflight(testing.allocator, p, .{});
    defer freeFindings(testing.allocator, findings);
    try testing.expect(findRule(findings, "pad-corridor-tight") == null);
}

// spec: placement/routability_lint - identical corridors across many parts collapse into one bucketed finding
test "preflight buckets identical corridors into a single finding" {
    var pads_a = [_]geometry.Pad{ tPad("1", 0, -0.32, 0.400, 0.460), tPad("2", 0, 0.32, 0.400, 0.460) };
    var pads_b = [_]geometry.Pad{ tPad("1", 0, -0.32, 0.400, 0.460), tPad("2", 0, 0.32, 0.400, 0.460) };
    var parts = [_]Part{
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.5, .hh = 0.6, .pads = &pads_a, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "C2", .kind = .passive, .hw = 0.5, .hh = 0.6, .pads = &pads_b, .fallback = false, .x = 5, .y = 0 },
    };
    const rail = [_]flat_netlist.FlatPin{
        .{ .ref_des = "C1", .pin = "1" }, .{ .ref_des = "C2", .pin = "1" }, .{ .ref_des = "U1", .pin = "1" },
    };
    const gnd = [_]flat_netlist.FlatPin{
        .{ .ref_des = "C1", .pin = "2" }, .{ .ref_des = "C2", .pin = "2" }, .{ .ref_des = "U1", .pin = "2" },
    };
    const nets = [_]flat_netlist.FlatNet{
        .{ .name = "V_1V8A", .pins = &rail },
        .{ .name = "GND", .pins = &gnd },
    };
    const rules = [_]optimizer.NetRule{ .{ .width = 0.2532 }, .{ .width = 0.2532 } };
    const p = tPlacement(&parts, &nets, .{ .net = &rules });

    const findings = try preflight(testing.allocator, p, .{});
    defer freeFindings(testing.allocator, findings);
    var n: usize = 0;
    for (findings) |f| {
        if (std.mem.eql(u8, f.rule, "pad-corridor-tight")) n += 1;
    }
    try testing.expectEqual(@as(usize, 1), n);
    const f = findRule(findings, "pad-corridor-tight").?;
    try testing.expectEqual(@as(usize, 2), f.refs.len);
}

// spec: placement/routability_lint - adjacent QFN pads that cannot both carry legal in-pad vias are flagged before routing
test "preflight flags adjacent pad-centred vias whose copper spacing conflicts" {
    var pads = [_]geometry.Pad{
        tPad("17", -0.25, 0, 0.25, 0.55),
        tPad("18", 0.25, 0, 0.25, 0.55),
    };
    var parts = [_]Part{
        .{ .ref_des = "U16", .kind = .hub, .hw = 1.5, .hh = 1.5, .pads = &pads, .fallback = false, .x = 0, .y = 0 },
    };
    const sck = [_]flat_netlist.FlatPin{ .{ .ref_des = "U16", .pin = "17" }, .{ .ref_des = "J1", .pin = "1" } };
    const dsa = [_]flat_netlist.FlatPin{ .{ .ref_des = "U16", .pin = "18" }, .{ .ref_des = "J1", .pin = "2" } };
    const nets = [_]flat_netlist.FlatNet{
        .{ .name = "SPI_SCK", .pins = &sck },
        .{ .name = "SPI_DSA", .pins = &dsa },
    };
    const p = tPlacement(&parts, &nets, .{ .design = .{
        .clearance = 0.127,
        .hole_to_hole = 0.25,
        .via_dia = 0.4,
        .via_drill = 0.2,
    } });

    const findings = try preflight(testing.allocator, p, .{});
    defer freeFindings(testing.allocator, findings);
    const f = findRule(findings, "via-in-pad-conflict") orelse return error.TestExpectedEqual;
    try testing.expectEqualStrings("U16", f.refs[0]);
    try testing.expectApproxEqAbs(@as(f64, 0.5), f.detail.have_mm, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.527), f.detail.need_mm, 1e-9);
    try testing.expect(std.mem.indexOf(u8, f.msg, "reserve one transition") != null);
}

// spec: placement/routability_lint - flags a pad whose eight octilinear escapes are all inside foreign clearance
test "preflight flags a pad with no legal escape direction" {
    // A 0.3 mm victim pad walled in by four foreign bars: the side walls sit
    // 0.05 mm away and the top/bottom 0.10 mm, both under the 0.1905 mm halo
    // (width 0.127/2 + clearance 0.127). The four diagonals leave through the
    // box corners and land inside a side wall before clearing it.
    var vic = [_]geometry.Pad{tPad("1", 0, 0, 0.3, 0.3)};
    var ring = [_]geometry.Pad{
        tPad("1", -0.35, 0, 0.3, 1.0),
        tPad("2", 0.35, 0, 0.3, 1.0),
        tPad("3", 0, -0.375, 1.0, 0.25),
        tPad("4", 0, 0.375, 1.0, 0.25),
    };
    var parts = [_]Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1.5, .hh = 1.5, .pads = &vic, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "U2", .kind = .hub, .hw = 1.5, .hh = 1.5, .pads = &ring, .fallback = false, .x = 0, .y = 0 },
    };
    const sig = [_]flat_netlist.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "U3", .pin = "1" } };
    const other = [_]flat_netlist.FlatPin{
        .{ .ref_des = "U2", .pin = "1" }, .{ .ref_des = "U2", .pin = "2" },
        .{ .ref_des = "U2", .pin = "3" }, .{ .ref_des = "U2", .pin = "4" },
    };
    const nets = [_]flat_netlist.FlatNet{
        .{ .name = "ADF_CE", .pins = &sig },
        .{ .name = "V_1V8A", .pins = &other },
    };
    const p = tPlacement(&parts, &nets, .{});

    const findings = try preflight(testing.allocator, p, .{});
    defer freeFindings(testing.allocator, findings);
    const f = findRule(findings, "pad-sealed") orelse return error.TestExpectedEqual;
    try testing.expectEqualStrings("U1", f.refs[0]);
    try testing.expectEqualStrings("ADF_CE", f.detail.a.net);
    try testing.expectEqual(@as(u8, 8), f.detail.exits_blocked);
}

// spec: placement/routability_lint - a pad keeping one clear octilinear exit is not sealed
test "preflight leaves a pad with one open exit alone" {
    var vic = [_]geometry.Pad{tPad("1", 0, 0, 0.3, 0.3)};
    // The same walls with the +x one removed: the eastward probe then clears
    // the top/bottom bars by 0.25 mm, over the 0.1905 mm halo. One way out is
    // all a pad needs.
    var ring = [_]geometry.Pad{
        tPad("1", -0.35, 0, 0.3, 1.0),
        tPad("3", 0, -0.375, 1.0, 0.25),
        tPad("4", 0, 0.375, 1.0, 0.25),
    };
    var parts = [_]Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1.5, .hh = 1.5, .pads = &vic, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "U2", .kind = .hub, .hw = 1.5, .hh = 1.5, .pads = &ring, .fallback = false, .x = 0, .y = 0 },
    };
    const sig = [_]flat_netlist.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "U3", .pin = "1" } };
    const other = [_]flat_netlist.FlatPin{
        .{ .ref_des = "U2", .pin = "1" }, .{ .ref_des = "U2", .pin = "3" }, .{ .ref_des = "U2", .pin = "4" },
    };
    const nets = [_]flat_netlist.FlatNet{
        .{ .name = "ADF_CE", .pins = &sig },
        .{ .name = "V_1V8A", .pins = &other },
    };
    const p = tPlacement(&parts, &nets, .{});

    const findings = try preflight(testing.allocator, p, .{});
    defer freeFindings(testing.allocator, findings);
    try testing.expect(findRule(findings, "pad-sealed") == null);
}

// spec: placement/routability_lint - the sealed-pad report is capped at the tightest pads so an unplaced board cannot flood it
test "preflight caps the sealed-pad report and reports the tightest first" {
    // One walled-in victim per "part pair", repeated past the cap. Each victim's
    // walls sit a hair closer than the previous one's, so the emitted order is
    // checkable: the report must keep the TIGHTEST, not the first N found.
    const n = max_sealed_findings + 5;
    const alloc = testing.allocator;
    const pads = try alloc.alloc([5]geometry.Pad, n);
    defer alloc.free(pads);
    const parts = try alloc.alloc(Part, 2 * n);
    defer alloc.free(parts);
    const pins = try alloc.alloc(flat_netlist.FlatPin, 2 * n);
    defer alloc.free(pins);
    fillSealedCells(pads, parts, pins);
    // One net over every victim pad (plus an off-board pin) and one over the walls.
    const wall_pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "W", .pin = "1" }, .{ .ref_des = "W", .pin = "2" } };
    const nets = [_]flat_netlist.FlatNet{
        .{ .name = "SIG", .pins = pins },
        .{ .name = "WALL", .pins = &wall_pins },
    };
    const p = tPlacement(parts, &nets, .{});

    const findings = try preflight(alloc, p, .{});
    defer freeFindings(alloc, findings);
    var sealed: usize = 0;
    var prev: f64 = -1;
    for (findings) |f| {
        if (!std.mem.eql(u8, f.rule, "pad-sealed")) continue;
        sealed += 1;
        // Worst-first: each reported pad has no more room than the one before.
        try testing.expect(prev < 0 or f.detail.have_mm >= prev - 1e-9);
        prev = f.detail.have_mm;
    }
    try testing.expectEqual(max_sealed_findings, sealed);
}

// spec: placement/routability_lint - a plane-carried net's pad is exempt from the sealed gate, declared plane or implicit ground alike
test "preflight exempts a plane-carried net from the escape gate" {
    var vic = [_]geometry.Pad{tPad("1", 0, 0, 0.3, 0.3)};
    var ring = [_]geometry.Pad{
        tPad("1", -0.35, 0, 0.3, 1.0),
        tPad("2", 0.35, 0, 0.3, 1.0),
        tPad("3", 0, -0.375, 1.0, 0.25),
        tPad("4", 0, 0.375, 1.0, 0.25),
    };
    var parts = [_]Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1.5, .hh = 1.5, .pads = &vic, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "U2", .kind = .hub, .hw = 1.5, .hh = 1.5, .pads = &ring, .fallback = false, .x = 0, .y = 0 },
    };
    const vpins = [_]flat_netlist.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "U3", .pin = "1" } };
    const other = [_]flat_netlist.FlatPin{
        .{ .ref_des = "U2", .pin = "1" }, .{ .ref_des = "U2", .pin = "2" },
        .{ .ref_des = "U2", .pin = "3" }, .{ .ref_des = "U2", .pin = "4" },
    };
    // (a) A DECLARED `(stackup … (plane …))` net, whose name is not groundy — it
    // can only be exempt through the declared-plane path.
    const declared = [_]flat_netlist.FlatNet{
        .{ .name = "V_PLANE", .pins = &vpins },
        .{ .name = "V_1V8A", .pins = &other },
    };
    const plane_nets = [_][]const u8{"V_PLANE"};
    const planes = [_]optimizer.PlaneAt{.{ .index = 2, .net = "V_PLANE" }};
    const with_plane = try preflight(testing.allocator, tPlacement(&parts, &declared, .{
        .plane_nets = &plane_nets,
        .planes = .{ .declared = &planes },
        .copper_layers = 4,
    }), .{});
    defer freeFindings(testing.allocator, with_plane);
    try testing.expect(findRule(with_plane, "pad-sealed") == null);

    // (b) A board with NO `(stackup …)` at all: the router's legacy implicit
    // model plants ground planes, so a ground pad is exempt there too.
    const implicit = [_]flat_netlist.FlatNet{
        .{ .name = "GND", .pins = &vpins },
        .{ .name = "V_1V8A", .pins = &other },
    };
    const no_stackup = try preflight(testing.allocator, tPlacement(&parts, &implicit, .{}), .{});
    defer freeFindings(testing.allocator, no_stackup);
    try testing.expect(findRule(no_stackup, "pad-sealed") == null);
}

// spec: placement/routability_lint - an empty placement yields no findings and allocates nothing to free
test "preflight on an empty placement returns no findings" {
    var parts = [_]Part{};
    const p = tPlacement(&parts, &.{}, .{});
    const findings = try preflight(testing.allocator, p, .{});
    defer freeFindings(testing.allocator, findings);
    try testing.expectEqual(@as(usize, 0), findings.len);
}

// spec: placement/routability_lint - flags a hub escape fan the corridor at its tightest cut cannot seat, with the paste-ready assignment
test "preflight flags an escape fan the corridor cannot seat" {
    var fan: EscapeFan = .{};
    // A wall leaving one lane on either side of it: four nets, two lanes.
    const p = fan.build(3.5);
    const findings = try preflight(testing.allocator, p, .{});
    defer freeFindings(testing.allocator, findings);
    const f = findRule(findings, "escape-contended") orelse return error.TestExpectedEqual;
    try testing.expectEqual(Severity.warn, f.severity);
    try testing.expectEqualStrings("J1", f.refs[0]);
    const e = f.escape orelse return error.TestExpectedEqual;
    try testing.expectEqualStrings("west", e.side);
    try testing.expectEqual(@as(usize, 4), e.nets);
    try testing.expectEqual(@as(usize, 2), e.lanes);
    try testing.expectEqual(@as(usize, 2), e.seated);
    try testing.expectEqual(@as(usize, 2), e.bands);
    try testing.expect(e.cut.pitch_mm > 0 and e.cut.span_mm > 0);
    // …and the finding carries the one-line wave that would address it.
    try testing.expect(std.mem.indexOf(u8, f.suggestion, "(assign-escapes \"F.Cu\" \"J1\")") != null);
    try testing.expect(std.mem.indexOf(u8, f.suggestion, "\"SPI_A\"") != null);
}

// spec: placement/routability_lint - an escape fan the corridor seats in full is not flagged
test "preflight leaves a roomy escape fan alone" {
    var fan: EscapeFan = .{};
    // The same fan with a wall a quarter the height: every net gets a lane.
    const p = fan.build(0.5);
    const findings = try preflight(testing.allocator, p, .{});
    defer freeFindings(testing.allocator, findings);
    try testing.expect(findRule(findings, "escape-contended") == null);
}

// spec: placement/routability_lint - a port net with no corridor out of the block and no room for a via is flagged, and only when the caller supplies the port mask
test "preflight flags a walled-in port net only when told which nets are ports" {
    // The sealed-pad fixture's geometry: a 0.3 mm victim pad ringed by four
    // foreign bars. Its net is now the block's `SPI_CSN` port, so besides having
    // no exit it also has nowhere to go — the ring is tighter than a via.
    var vic = [_]geometry.Pad{tPad("1", 0, 0, 0.3, 0.3)};
    var ring = [_]geometry.Pad{
        tPad("1", -0.35, 0, 0.3, 1.0),
        tPad("2", 0.35, 0, 0.3, 1.0),
        tPad("3", 0, -0.375, 1.0, 0.25),
        tPad("4", 0, 0.375, 1.0, 0.25),
    };
    var parts = [_]Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1.5, .hh = 1.5, .pads = &vic, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "U2", .kind = .hub, .hw = 1.5, .hh = 1.5, .pads = &ring, .fallback = false, .x = 0, .y = 0 },
    };
    const sig = [_]flat_netlist.FlatPin{.{ .ref_des = "U1", .pin = "1" }};
    const other = [_]flat_netlist.FlatPin{
        .{ .ref_des = "U2", .pin = "1" }, .{ .ref_des = "U2", .pin = "2" },
        .{ .ref_des = "U2", .pin = "3" }, .{ .ref_des = "U2", .pin = "4" },
    };
    const nets = [_]flat_netlist.FlatNet{
        .{ .name = "SPI_CSN", .pins = &sig },
        .{ .name = "V_1V8A", .pins = &other },
    };
    const p = tPlacement(&parts, &nets, .{});

    // Without the mask nothing here is known to be a port, so the gate is silent
    // even though the geometry is identical.
    const unmasked = try preflight(testing.allocator, p, .{});
    defer freeFindings(testing.allocator, unmasked);
    try testing.expect(findRule(unmasked, "port-blocked") == null);

    const ports = [_]bool{ true, false };
    const findings = try preflight(testing.allocator, p, .{ .port_nets = &ports });
    defer freeFindings(testing.allocator, findings);
    const f = findRule(findings, "port-blocked") orelse return error.TestExpectedEqual;
    try testing.expectEqual(Severity.warn, f.severity);
    try testing.expectEqualStrings("U1", f.refs[0]);
    try testing.expectEqualStrings("SPI_CSN", f.detail.a.net);
    try testing.expectEqualStrings("U2", (f.detail.b orelse return error.TestExpectedEqual).ref);
    try testing.expect(f.detail.need_mm > f.detail.have_mm);
}

// spec: placement/routability_lint - an escape fan every net of which an authored assignment already covers is not flagged
test "preflight skips an escape fan an authored assignment already covers" {
    var fan: EscapeFan = .{};
    const p = fan.build(3.5);
    const covered: [4]bool = @splat(true);
    const findings = try preflight(testing.allocator, p, .{ .escapes_assigned = &covered });
    defer freeFindings(testing.allocator, findings);
    try testing.expect(findRule(findings, "escape-contended") == null);
}

/// A four-layer board carrying a 0.5 A rail on `V3P3`, a ground plane, and one
/// signal net — the minimum for asking what width each of them is measured at.
fn widthRulesPlacement(
    parts: []Part,
    nets: []const flat_netlist.FlatNet,
    rails: []const power_budget.Rail,
    planes: []const []const u8,
) Placement {
    return tPlacement(parts, nets, .{
        .design = .{ .track_width = 0.127, .clearance = 0.127 },
        .plane_nets = planes,
        .copper_layers = 4,
        .physical = .{ .stack = .{ .layers = 4 }, .rails = rails },
    });
}

// spec: placement/routability_lint - a corridor is measured at the adaptive router's narrow search width, while a plane-carried rail keeps its authored fanout width
test "netWidth mirrors adaptive power-route search geometry" {
    const rails = [_]power_budget.Rail{
        .{ .net = "V3P3", .load_max_a = 0.5, .any_max_load = true, .status = .no_source },
        .{ .net = "GND", .load_max_a = 0.5, .any_max_load = true, .status = .no_source },
    };
    const nets = [_]flat_netlist.FlatNet{
        .{ .name = "V3P3", .pins = &.{} },
        .{ .name = "GND", .pins = &.{} },
        .{ .name = "SPI_SCK", .pins = &.{} },
    };
    const planes = [_][]const u8{"GND"};
    var parts: [0]Part = .{};
    const p = widthRulesPlacement(&parts, &nets, &rails, &planes);

    // Worst layer of a uniform four-layer stack is an inner one.
    const envelope = power_capacity.requiredTraceWidthMm(0.5, impedance.default_foil_mm, false).?;
    try testing.expect(envelope > p.rules.design.track_width);
    try testing.expectEqual(p.rules.design.track_width, netWidth(p, 0));
    // A plane-carried rail fans out into its pour, so the router never widens
    // its surface copper and neither does the gate.
    try testing.expectEqual(p.rules.design.track_width, netWidth(p, 1));
    // A signal net, and a pad on no net at all, keep the board default.
    try testing.expectEqual(p.rules.design.track_width, netWidth(p, 2));
    try testing.expectEqual(p.rules.design.track_width, netWidth(p, -1));
}

// spec: placement/routability_lint - an adaptive rail's authored wide class remains an electrical target and does not widen the static route corridor
test "netWidth keeps a wide adaptive power class out of corridor geometry" {
    const rails = [_]power_budget.Rail{
        .{ .net = "V3P3", .load_max_a = 0.5, .any_max_load = true, .status = .no_source },
    };
    const nets = [_]flat_netlist.FlatNet{.{ .name = "V3P3", .pins = &.{} }};
    var parts: [0]Part = .{};

    const envelope = power_capacity.requiredTraceWidthMm(0.5, impedance.default_foil_mm, false).?;
    const class = [_]optimizer.NetRule{.{ .width = envelope * 2 }};
    var p = widthRulesPlacement(&parts, &nets, &rails, &.{});
    p.rules.net = &class;
    try testing.expectEqual(p.rules.design.track_width, netWidth(p, 0));

    const narrow = [_]optimizer.NetRule{.{ .width = envelope / 2 }};
    p.rules.net = &narrow;
    try testing.expectEqual(p.rules.design.track_width, netWidth(p, 0));
}
