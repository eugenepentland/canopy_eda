//! Connectivity accept gate for DECLARED-resolution rescue windows.
//!
//! A `(net-class … (resolution MM))` window over a board-spanning net has to be
//! allowed past the automatic cell cap to exist at all (`fine_window
//! .max_declared_window_cells`). Raising that cap on its own was measured
//! NET-NEGATIVE: board-a went 83/90 -> 81/90 while the ROUTER's own claim ROSE
//! to 87 — it closed `TXDATA_ADF` and broke `GND`, `loop_amp/LF_OUT` and
//! `boost22/BOOST22_SW`.
//!
//! The reason a wider window can LOSE nets is that its copper is board-scale. A
//! 35 mm fine-grid detour crosses pours, and a pour is connecting copper: the
//! fill recedes around foreign copper, so a trace drawn through it can cut a
//! poured rail into islands and open a net nobody touched. The rescue's existing
//! `fineCopperClean` gate cannot see any of that — it asks only whether the new
//! copper clears the old.
//!
//! So this module asks the ONE connectivity oracle (`fab_readiness`, the same
//! `routed`/`total` every reporting surface quotes) instead, twice per attempt:
//! over the board WITHOUT the attempt's copper, then WITH it. The attempt is
//! accepted only when the board STRICTLY improves — at least one more net
//! connected, and not one net that was connected left open. Anything else is
//! refused and the caller's existing `shrinkCopper` puts the board back byte for
//! byte. That is the `joint_rescue.closesANet` + `router.ripScoreBetter` shape,
//! measured against connectivity rather than against the router's own claim,
//! because the failure being guarded here is precisely a claim that rose while
//! the board got worse.
//!
//! Cost is paid ONLY by a net that declared a resolution: `accepts` returns true
//! before doing any work for every other net, so a board with no `(resolution …)`
//! anywhere routes exactly as it did, at the same price. A declared board pays
//! at most `max_evaluations` oracle pairs, and an attempt arriving past that
//! ceiling is refused rather than admitted unmeasured.

const std = @import("std");
const optimizer = @import("optimizer.zig");
const router = @import("router.zig");
const route_close = @import("route_close.zig");
const route_policy = @import("route_policy.zig");
const fine_window = @import("fine_window.zig");
const pour = @import("pour.zig");
const fab_readiness = @import("../fab_readiness.zig");
const rf_port_report = @import("rf_port_report.zig");
const routed_copper = @import("routed_copper.zig");

/// A board's per-net connectivity, as the oracle counts it.
pub const Connectivity = struct {
    /// How many nets the board's copper (and its pours) actually joins.
    routed: usize = 0,
    /// One flag per design net, in `placement.nets` order.
    connected: []const bool = &.{},
    /// Copper islands on the ONE net the caller asked about (`Gate.weigh`'s
    /// focus), zero when it asked about none. A scalar rather than a per-net
    /// array because the only rule that reads it judges a single net's merge —
    /// and a net that arrives in eight islands closes in seven separate steps,
    /// only the last of which moves `routed` (see `mergesIslands`).
    focus_islands: usize = 0,
};

/// One board's copper, as the gate weighs it.
///
/// All four copper kinds, because the oracle reads all four (`routed_copper
/// .Copper`) and a projection that drops one reports a joined net as OPEN: a
/// native arc's persisted chords are handles whose curved envelope is what
/// carves a pour, and an RF path's compact centreline is a handle whose swept
/// polygon is what actually lands on the pads. Both default empty — a board
/// weighed mid-route carries whichever of them EXISTS at that point in the
/// pipeline (RF port finishing runs in `router.finishRoute`, after every rescue
/// tier, so the in-router callers legitimately hand over none), and a caller
/// holding a finished `router.RouteResult` hands over both.
pub const Board = struct {
    tracks: []const router.Track = &.{},
    vias: []const router.Via = &.{},
    /// Native routed arcs whose exact curve, not their chords, is authoritative.
    arcs: []const router.Arc = &.{},
    /// Successful variable-width RF paths, each swept as one copper region.
    rf_paths: []const rf_port_report.Outcome = &.{},
};

/// Is `now` a STRICTLY better board than `before`? Both halves matter: the
/// count must RISE (an attempt that connects nothing new has bought nothing),
/// and no net that was connected may be left open (a swap that closes one net
/// by islanding another keeps the count level or better while making the board
/// worse — the exact 83/90 -> 81/90 failure this gate exists for).
pub fn strictlyBetter(now: Connectivity, before: Connectivity) bool {
    if (now.routed <= before.routed) return false;
    for (before.connected, now.connected) |was, is| {
        if (was and !is) return false;
    }
    return true;
}

/// Did `now` merge two of the focused net's copper islands without costing
/// another net its connection?
///
/// The safety half is `strictlyBetter`'s exactly — a board that leaves a
/// connected net open is worse however many islands it merged. What differs is
/// the GAIN half: a plane- or pour-carried net rejoins one island at a time, and
/// its `routed` flag flips only when the last island lands, so a count-only rule
/// refuses every step that was making progress. Merging an island is the real
/// unit of that progress, and a merge cannot be faked by copper that joins
/// nothing.
pub fn mergesIslands(now: Connectivity, before: Connectivity) bool {
    for (before.connected, now.connected) |was, is| {
        if (was and !is) return false;
    }
    if (now.routed > before.routed) return true;
    return now.focus_islands < before.focus_islands;
}

/// One rescue attempt as the board lists hold it: the whole copper plus the
/// marks the attempt began at, so the gate can weigh the board with and without
/// the tail without the caller having to copy either.
/// The curved copper rides both halves unsplit: a window rescue only ever
/// APPENDS tracks and vias, so the arcs and RF paths already on the board belong
/// to the prefix and are part of the board with and without the tail alike.
pub const Attempt = struct {
    tracks: []const router.Track,
    vias: []const router.Via,
    arcs: []const router.Arc = &.{},
    rf_paths: []const rf_port_report.Outcome = &.{},
    keep_t: usize,
    keep_v: usize,
};

/// Most attempts one route will pay the oracle for. A declared net's rescue
/// makes a handful of DRC-clean attempts at most (whole-net window, then per
/// leg), so this is headroom rather than a limit in practice — but it is what
/// bounds the gate's cost when a design declares a resolution on many nets.
/// Past it an attempt is REFUSED, never admitted unmeasured.
pub const max_evaluations: usize = 8;

/// The gate one route run carries: the board it judges, the pours that are part
/// of its connectivity, and two reusable per-net verdict buffers.
pub const Gate = struct {
    placement: optimizer.Placement,
    /// The router's index-keyed retained pours, NAMED for the oracle (a rail
    /// poured rather than traced is joined by its zone and by nothing else).
    zones: []const pour.UserZone,
    before: []bool,
    after: []bool,
    /// Per-measurement scratch. The oracle rasters a pour fill per plane-carried
    /// net, which is far too much to leave in the monotonic route arena.
    scratch: std.heap.ArenaAllocator,
    evaluations: usize = 0,
    /// Most attempts THIS gate will pay the oracle for. Defaults to
    /// `max_evaluations`, so a caller that never sets it is unchanged; a
    /// transactional finishing pass over a rail that arrives in many islands
    /// raises it, because one island per evaluation is its whole shape.
    budget: usize = max_evaluations,

    /// Build a gate over `placement` and the route's retained `zones`. `home`
    /// owns the small per-net buffers and backs the measurement scratch (the
    /// route arena is the natural choice for both); a `.retain_capacity` reset
    /// between measurements reuses the scratch's own pages, so the oracle's
    /// pour fills cost one measurement's peak no matter how many run.
    pub fn init(
        home: std.mem.Allocator,
        placement: optimizer.Placement,
        zones: []const route_policy.ExistingZone,
    ) std.mem.Allocator.Error!Gate {
        const pours = try route_close.userZones(home, placement, zones);
        errdefer home.free(pours);
        const before = try home.alloc(bool, placement.nets.len);
        errdefer home.free(before);
        const after = try home.alloc(bool, placement.nets.len);
        return .{
            .placement = placement,
            .zones = pours,
            .before = before,
            .after = after,
            .scratch = std.heap.ArenaAllocator.init(home),
        };
    }

    pub fn deinit(self: *Gate) void {
        self.scratch.deinit();
    }

    /// Keep the copper `a` appended for `net_i`? True with no work at all for a
    /// net that declared no `(resolution …)`, so an undeclared board never pays
    /// for this gate. For a declared one: measure the board without the tail,
    /// measure it with, and keep only a strict improvement.
    pub fn accepts(self: *Gate, net_i: usize, a: Attempt) std.mem.Allocator.Error!bool {
        if (fine_window.declaredPitch(self.placement, net_i) == null) return true;
        return self.acceptsReplacement(
            .{ .tracks = a.tracks[0..a.keep_t], .vias = a.vias[0..a.keep_v], .arcs = a.arcs, .rf_paths = a.rf_paths },
            .{ .tracks = a.tracks, .vias = a.vias, .arcs = a.arcs, .rf_paths = a.rf_paths },
        );
    }

    /// Judge an arbitrary transactional copper replacement, rather than an
    /// appended fine-window tail. The joint rescue uses this after ripping and
    /// rerouting a small cluster: router status alone cannot see a rerouted
    /// trace cutting a pour or merely grazing its terminal pad. A replacement
    /// therefore survives only when the fabrication oracle connects more nets
    /// and disconnects none that the snapshot connected.
    pub fn acceptsReplacement(
        self: *Gate,
        before: Board,
        after: Board,
    ) std.mem.Allocator.Error!bool {
        const pair = (try self.weigh(.{ .before = before, .after = after })) orelse return false;
        return strictlyBetter(pair.after, pair.before);
    }

    /// Judge one hop of a MULTI-ISLAND net's repair: the same before/after
    /// oracle pair as `acceptsReplacement`, decided by `mergesIslands` so a
    /// stitch that joins two of `net_i`'s islands counts as the gain it is even
    /// though the net is not closed yet.
    pub fn acceptsIslandMerge(
        self: *Gate,
        net_i: usize,
        before: Board,
        after: Board,
    ) std.mem.Allocator.Error!bool {
        const pair = (try self.weigh(.{ .before = before, .after = after, .focus = net_i })) orelse return false;
        return mergesIslands(pair.after, pair.before);
    }

    /// What one evaluation weighs: the two boards, and the net whose island
    /// count the verdict may turn on (null = the routed count alone).
    const Weighing = struct {
        before: Board,
        after: Board,
        focus: ?usize = null,
    };

    /// The two connectivity readings one attempt is decided on, or null once the
    /// evaluation budget is spent — an unmeasured attempt is REFUSED, never
    /// admitted (see `budget`).
    const Pair = struct { before: Connectivity, after: Connectivity };

    fn weigh(self: *Gate, w: Weighing) std.mem.Allocator.Error!?Pair {
        if (self.evaluations >= self.budget) return null;
        self.evaluations += 1;
        const was = try self.measure(w.before, self.before, w.focus);
        const is = try self.measure(w.after, self.after, w.focus);
        return .{ .before = was, .after = is };
    }

    /// One oracle pass over `board`'s copper plus this board's pours, recorded
    /// into `out` (one flag per net) so the verdict outlives the scratch.
    fn measure(
        self: *Gate,
        board: Board,
        out: []bool,
        focus: ?usize,
    ) std.mem.Allocator.Error!Connectivity {
        defer _ = self.scratch.reset(.retain_capacity);
        const copper = routed_copper.Copper{
            .tracks = board.tracks,
            .arcs = board.arcs,
            .rf_paths = board.rf_paths,
            .vias = board.vias,
            .zones = self.zones,
        };
        const conn = try fab_readiness.netConnectivity(self.scratch.allocator(), self.placement, copper);
        var result = Connectivity{ .connected = out };
        for (conn, 0..) |ns, i| {
            if (i >= out.len) break;
            out[i] = ns.connected;
            if (ns.connected) result.routed += 1;
            if (focus) |net_i| if (net_i == i) {
                result.focus_islands = ns.islands;
            };
        }
        return result;
    }
};

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

// spec: placement/route-resolution - a declared-resolution rescue window is accepted only when the connectivity oracle says the whole board strictly improved
test "the accept gate keeps a strict improvement and refuses a swap" {
    const before = Connectivity{ .routed = 2, .connected = &.{ true, true, false, false } };
    // One more net connected, none lost — the case the gate exists to admit.
    try testing.expect(strictlyBetter(.{ .routed = 3, .connected = &.{ true, true, true, false } }, before));
    // Same count: nothing bought.
    try testing.expect(!strictlyBetter(.{ .routed = 2, .connected = &.{ true, true, false, false } }, before));
    // A SWAP — net 2 closes while net 0 opens. The count is level, so a
    // count-only gate would have to call it neutral; it is a regression.
    try testing.expect(!strictlyBetter(.{ .routed = 2, .connected = &.{ false, true, true, false } }, before));
    // Two closed, one lost: the count RISES and the board is still worse. This
    // is the historical 83/90 -> 81/90 shape (the router's claim rose too).
    try testing.expect(!strictlyBetter(.{ .routed = 3, .connected = &.{ false, true, true, true } }, before));
}

// spec: placement/route-resolution - the connectivity accept gate can judge ONE net's island merge, so a hop that joins two islands without yet closing the net is a measurable gain
test "the island rule credits a merge and still refuses a swap" {
    const before = Connectivity{ .routed = 1, .connected = &.{ true, false }, .focus_islands = 8 };
    // Seven islands where there were eight: the net is not closed, and the hop
    // that got it there is exactly what a count-only rule cannot see.
    try testing.expect(mergesIslands(.{ .routed = 1, .connected = &.{ true, false }, .focus_islands = 7 }, before));
    // Copper that joined nothing leaves the count and the islands alone.
    try testing.expect(!mergesIslands(.{ .routed = 1, .connected = &.{ true, false }, .focus_islands = 8 }, before));
    // Closing the net outright is a gain even with no island reading at all.
    try testing.expect(mergesIslands(.{ .routed = 2, .connected = &.{ true, true } }, before));
    // …but never at the price of a net the board already connected, however
    // many islands the focused net merged.
    try testing.expect(!mergesIslands(.{ .routed = 1, .connected = &.{ false, true }, .focus_islands = 1 }, before));
}

const geometry = @import("geometry.zig");
const flat_netlist = @import("../flat_netlist.zig");
const rf_path_solver = @import("rf_path_solver.zig");

/// One-pad passive at (x, y) on the top face, for the gate fixtures below.
fn testPart(ref: []const u8, x: f64, y: f64, pads: []const geometry.Pad) optimizer.Part {
    return .{ .ref_des = ref, .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = pads, .fallback = false, .x = x, .y = y };
}

const plane_nets = [_][]const u8{"GND"};
const top_plane = [_]optimizer.PlaneAt{.{ .index = 1, .net = "GND" }};

/// A 40 x 24 mm board whose TOP copper is a GND plane. The plane is what makes
/// this the historical failure shape: it is `GND`'s only connecting copper, it
/// recedes around foreign copper, and a trace drawn clean across it cuts it in
/// two — opening a net nobody routed, which no per-window DRC check can see.
fn planeBoard(parts: []optimizer.Part, nets: []const flat_netlist.FlatNet) optimizer.Placement {
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
        .maxx = 40,
        .maxy = 24,
        .generated = false,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 40, .h = 24 },
        // The plane sits on the TOP face and these boards are cut so a test
        // track either severs it or merely slits it — verdicts decided by
        // tenths of a millimetre of keepout. So the outer face is PINNED to the
        // same 0.3 mm gap an inner plane defaults to, rather than taking the
        // tighter outer default, which would quietly re-decide every one of them.
        .rules = .{
            .design = .{ .pour = .{ .clearance_outer = 0.3 } },
            .plane_nets = &plane_nets,
            .copper_layers = 2,
            .planes = .{ .declared = &top_plane },
        },
    };
}

const gate_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
const sig_pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } };
const gnd_pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "R3", .pin = "1" }, .{ .ref_des = "R4", .pin = "1" } };
/// `SIG` is net 0 and the one that DECLARED a raster, so it is the gated one;
/// `GND` is the innocent neighbour riding the plane.
const gate_nets = [_]flat_netlist.FlatNet{
    .{ .name = "SIG", .pins = &sig_pins },
    .{ .name = "GND", .pins = &gnd_pins },
};
const gate_rules = [_]optimizer.NetRule{ .{ .resolution_mm = 0.05 }, .{} };

/// `SIG`'s two pads at (x1,y1)/(x2,y2), plus two `GND` pads on opposite sides of
/// the board's midline so a full-height cut separates them.
fn gateBoard(parts: *[4]optimizer.Part, a: [2]f64, b: [2]f64) optimizer.Placement {
    parts.* = .{
        testPart("R1", a[0], a[1], &gate_pad),
        testPart("R2", b[0], b[1], &gate_pad),
        testPart("R3", 12, 12, &gate_pad),
        testPart("R4", 28, 12, &gate_pad),
    };
    var placement = planeBoard(parts, &gate_nets);
    placement.rules.net = &gate_rules;
    return placement;
}

// spec: placement/route-resolution - a declared-resolution rescue window whose copper closes its own net but islands the plane another net rides is refused, and the gate leaves the copper it judged untouched
test "the gate refuses a window that closes one net by islanding another's plane" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    // SIG's pads sit at the top and bottom edges, so the copper joining them
    // runs clean across the board — and clean through the GND plane.
    var parts: [4]optimizer.Part = undefined;
    const placement = gateBoard(&parts, .{ 20, 1 }, .{ 20, 23 });
    var gate = try Gate.init(arena, placement, &.{});
    defer gate.deinit();

    // Narrow enough to carry its full cross-section on the 0.6 mm terminal
    // lands, while still making the full-height plane cut this fixture needs.
    const cutting = [_]router.Track{.{ .x1 = 20, .y1 = 1, .x2 = 20, .y2 = 23, .layer = 0, .width = 0.5, .net = 0 }};
    const attempt = Attempt{ .tracks = &cutting, .vias = &.{}, .keep_t = 0, .keep_v = 0 };
    try testing.expect(!try gate.accepts(0, attempt));
    // SIG really did close — the refusal is about what it cost, not about a
    // failed route. (`before`/`after` are the gate's own recorded verdicts.)
    try testing.expect(gate.after[0] and !gate.before[0]);
    try testing.expect(gate.before[1] and !gate.after[1]);
    // The gate is read-only over the copper it judges, so the caller's rollback
    // restores exactly what it handed in.
    try testing.expectEqual(@as(f64, 1), cutting[0].y1);
    try testing.expectEqual(@as(usize, 1), gate.evaluations);
    // Deterministic: the same board and the same tail give the same verdict.
    try testing.expect(!try gate.accepts(0, attempt));
}

// spec: placement/route-resolution - a declared-resolution rescue window that closes its net without costing another is kept
test "the gate keeps a window that closes its net and costs no other" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    // The same board with SIG's pads 3 mm apart: joining them punches a slit in
    // the plane rather than cutting it, so GND is untouched.
    var parts: [4]optimizer.Part = undefined;
    const placement = gateBoard(&parts, .{ 5, 12 }, .{ 8, 12 });
    var gate = try Gate.init(arena, placement, &.{});
    defer gate.deinit();

    const joining = [_]router.Track{.{ .x1 = 5, .y1 = 12, .x2 = 8, .y2 = 12, .layer = 0, .width = 0.2, .net = 0 }};
    try testing.expect(try gate.accepts(0, .{ .tracks = &joining, .vias = &.{}, .keep_t = 0, .keep_v = 0 }));
    try testing.expect(gate.after[0] and gate.after[1]);

    // A net that declared NO resolution never reaches the oracle at all — the
    // evaluation counter does not move, which is what keeps an undeclared board
    // paying exactly nothing for this gate.
    const spent = gate.evaluations;
    try testing.expect(try gate.accepts(1, .{ .tracks = &joining, .vias = &.{}, .keep_t = 0, .keep_v = 0 }));
    try testing.expectEqual(spent, gate.evaluations);
}

// spec: placement/route-resolution - an arbitrary joint-rescue copper replacement is accepted only when the connectivity oracle connects more nets and disconnects none
test "the replacement gate refuses a router gain that disconnects a poured net" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    var parts: [4]optimizer.Part = undefined;
    const placement = gateBoard(&parts, .{ 20, 1 }, .{ 20, 23 });
    var gate = try Gate.init(arena, placement, &.{});
    defer gate.deinit();

    const cutting = [_]router.Track{.{
        .x1 = 20,
        .y1 = 1,
        .x2 = 20,
        .y2 = 23,
        .layer = 0,
        .width = 0.5,
        .net = 0,
    }};
    try testing.expect(!try gate.acceptsReplacement(.{}, .{ .tracks = &cutting }));
    try testing.expect(gate.after[0] and !gate.before[0]);
    try testing.expect(gate.before[1] and !gate.after[1]);
}

/// A swept RF taper joining `SIG`'s two lands, narrow enough to carry its full
/// cross-section on the 0.6 mm terminals. The compact centreline a save would
/// keep is a HANDLE; this sampled path is the copper actually on the board.
const taper_samples = [_]rf_path_solver.Sample{
    .{ .at = .{ 5, 12 }, .s_mm = 0, .curvature = 0, .width_mm = 0.2 },
    .{ .at = .{ 8, 12 }, .s_mm = 3, .curvature = 0, .width_mm = 0.2 },
};
const taper = [_]rf_port_report.Outcome{.{
    .net = 0,
    .chosen = 0,
    .feasible = true,
    .success = true,
    .metrics = .{},
    .trials = &.{},
    .physical = .{ .sample_count = taper_samples.len, .samples = &taper_samples, .layer = 0 },
}};

// spec: placement/route-resolution - the accept gate weighs a board's swept RF paths and native arcs too, so copper duplicating a net an RF taper already joins buys nothing
test "the gate sees a net joined only by its RF taper and credits no gain for duplicating it" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    var parts: [4]optimizer.Part = undefined;
    const placement = gateBoard(&parts, .{ 5, 12 }, .{ 8, 12 });
    var gate = try Gate.init(arena, placement, &.{});
    defer gate.deinit();

    // Wider than the taper, so it is a track in its own right rather than one of
    // the path's own handles (`path_copper.ownsTrack` keeps only the narrower).
    const duplicate = [_]router.Track{.{ .x1 = 5, .y1 = 12, .x2 = 8, .y2 = 12, .layer = 0, .width = 0.5, .net = 0 }};

    // SIG is already joined — by the taper and by nothing else — so the second
    // path across the same gap connects no net that was not connected.
    const before = Board{ .rf_paths = &taper };
    const after = Board{ .tracks = &duplicate, .rf_paths = &taper };
    try testing.expect(!try gate.acceptsReplacement(before, after));
    try testing.expect(gate.before[0] and gate.after[0]);

    // …and that verdict is the taper's doing: hand the same pair of boards over
    // with the swept path dropped and the duplicate looks like the copper that
    // closed SIG, which is exactly the gain a partial projection invents.
    try testing.expect(try gate.acceptsReplacement(
        .{ .tracks = before.tracks },
        .{ .tracks = after.tracks },
    ));
    try testing.expect(!gate.before[0] and gate.after[0]);
}

// spec: placement/route-resolution - the accept gate spends a bounded number of oracle evaluations per route and refuses, rather than admits, an attempt arriving past that ceiling
test "the gate refuses rather than admits once its evaluation budget is spent" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    var parts: [4]optimizer.Part = undefined;
    const placement = gateBoard(&parts, .{ 5, 12 }, .{ 8, 12 });
    var gate = try Gate.init(arena, placement, &.{});
    defer gate.deinit();

    const joining = [_]router.Track{.{ .x1 = 5, .y1 = 12, .x2 = 8, .y2 = 12, .layer = 0, .width = 0.2, .net = 0 }};
    const attempt = Attempt{ .tracks = &joining, .vias = &.{}, .keep_t = 0, .keep_v = 0 };
    // A genuine improvement is kept while the budget lasts…
    try testing.expect(try gate.accepts(0, attempt));
    gate.evaluations = max_evaluations;
    // …and past the ceiling the SAME attempt is refused: an unmeasured window
    // is exactly what the 83/90 -> 81/90 regression was.
    try testing.expect(!try gate.accepts(0, attempt));
    try testing.expectEqual(max_evaluations, gate.evaluations);
}

/// The board the end-to-end fixture routes: two pads 56 mm apart with a
/// through-hole wall between them, split by a 0.431 mm gap centred on y = 9.7.
///
/// Every number is chosen so the gap is passable ONLY at a declared raster.
/// A 0.127/0.127 net needs its centreline within 0.025 mm of 9.7, and every grid
/// the rescue can build on its own puts its nearest row outside that strip: the
/// whole-board 0.254 mm lattice at 9.668, the board-spanning 0.0635 mm pass at
/// 9.668 / 9.7315. The terminal box is also wide enough (62 x 24 mm) that BOTH
/// automatic window tiers overflow `max_window_cells` and are dropped. A
/// declared 0.10 mm window is 149,661 cells — over that cap, under the declared
/// one — and its rows land on 9.7 exactly.
fn fineOnlyBoard(parts: []optimizer.Part, nets: []const flat_netlist.FlatNet, rules: []const optimizer.NetRule) optimizer.Placement {
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
        .maxx = 60,
        .maxy = 22,
        .generated = true,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 60, .h = 22 },
        .rules = .{ .net = rules },
    };
}

const fine_only_pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "S1", .pin = "1" }, .{ .ref_des = "S2", .pin = "1" } };
const fine_only_nets = [_]flat_netlist.FlatNet{.{ .name = "FINE_ONLY", .pins = &fine_only_pins }};
const wall_lower = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.5, .h = 11.4845, .thru = true, .drill = 0.2 }};
const wall_upper = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.5, .h = 14.0845, .thru = true, .drill = 0.2 }};

fn fineOnlyParts(parts: *[4]optimizer.Part) void {
    parts.* = .{
        testPart("S1", 2, 2, &gate_pad),
        testPart("S2", 58, 20, &gate_pad),
        .{ .ref_des = "W1", .kind = .hub, .hw = 0.25, .hh = 5.74225, .pads = &wall_lower, .fallback = false, .x = 30, .y = 3.74225 },
        .{ .ref_des = "W2", .kind = .hub, .hw = 0.25, .hh = 7.04225, .pads = &wall_upper, .fallback = false, .x = 30, .y = 16.95775 },
    };
}

/// Route `fineOnlyBoard` once, at the whole batch policy every caller uses.
fn routeFineOnly(arena: std.mem.Allocator, rules: []const optimizer.NetRule) std.mem.Allocator.Error!router.RouteResult {
    var parts: [4]optimizer.Part = undefined;
    fineOnlyParts(&parts);
    const placement = fineOnlyBoard(&parts, &fine_only_nets, rules);
    return router.routeWithOptions(arena, placement, .{ .track_width = 0.127, .clearance = 0.127 }, .{});
}

// spec: placement/route-resolution - a net whose only legal corridor lands on no raster the rescue builds by itself routes once its class declares that raster, and stays unrouted without the declaration
test "a net routable only at a declared raster routes when it declares one" {
    // Undeclared: the base lattice, both automatic window tiers and the
    // board-spanning fine pass all miss the gap, so the net stays open.
    const plain = [_]optimizer.NetRule{.{}};
    {
        var before_arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer before_arena.deinit();
        const before = try routeFineOnly(before_arena.allocator(), &plain);
        try testing.expectEqual(@as(usize, 0), before.routed);
    }

    // The SAME board with `(net-class … (resolution 0.10))` on that net: the
    // whole-net window is built at the declared pitch even though it is past
    // the automatic cell cap, a row lands in the gap, and the accept gate keeps
    // the result because the board strictly improved.
    const declared = [_]optimizer.NetRule{.{ .resolution_mm = 0.10 }};
    {
        var after_arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer after_arena.deinit();
        const after = try routeFineOnly(after_arena.allocator(), &declared);
        try testing.expectEqual(@as(usize, 1), after.routed);
        try testing.expect(after.tracks.len > 0);
    }
}
