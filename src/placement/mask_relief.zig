//! Solder-mask relief geometry for RF copper — the ONE computation the Gerber
//! mask writer, the PCB viewer's assembly surface, and the generated
//! sub-circuit silkscreen all consume, so no two of them can disagree about
//! where the board ships bare.
//!
//! Policy (`reliefMm`): an authored `(mask-relief MM)` wins outright (0 =
//! tented). An undeclared max-freq class defaults to the board's mask margin —
//! unless it declares a `(fence …)`, in which case the band widens to swallow
//! the whole fence row (copper-edge gap + fence via diameter + margin), so the
//! shielding-via row, the way a hand-built RF board opens one channel over the
//! whole launch. An RF trace-to-via transition grows that face's ordinary
//! opening polygon over the solved plane antipad plus the same pullback. Vias
//! themselves still carry no mask state: their copper is exposed only where
//! one of those opening polygons overlaps it.
//!
//! Geometry (`compute`): relief follows EXPOSURE RUNS, not raw segments. Each
//! relieved net's centreline (tracks plus tessellated arcs, per outer face) is
//! sampled against the pad dams — every pad's extents grown by the mask margin
//! plus one web — contiguous exposed stretches merge across segment joints,
//! and a run shorter than `min_exposed_mm` stays tented: a sliver of bare
//! trace between two lands is mask the fab would rather keep. A nearby pad that
//! does not meet the centreline is protected later by a local mask island; it
//! does not split the exposed RF trace.

const std = @import("std");
const optimizer = @import("optimizer.zig");
const router = @import("router.zig");
const outline = @import("outline.zig");
const pad_shape = @import("pad_shape.zig");
const bend_smooth = @import("bend_smooth.zig");
const path_copper = @import("path_copper.zig");
const rf_port_report = @import("rf_port_report.zig");
const RfSample = @import("rf_path_solver.zig").Sample;
const via_fence = @import("via_fence.zig");
const via_antipad = @import("via_antipad.zig");
const numeric = @import("../numeric.zig");

/// An exposed stretch shorter than this (measured along the centreline, after
/// dams) keeps its mask.
pub const min_exposed_mm: f64 = 1.0;
/// Centreline sampling pitch for the dam test.
const sample_mm: f64 = 0.05;
/// Two exposure runs whose segment ends land within this of each other are one
/// run for the length test.
const join_tol_mm: f64 = 0.02;
/// Exact path ordering must not mistake both neighbors of a short tessellated
/// arc chord for the same endpoint. The exposure union uses the looser
/// fabrication tolerance above; the outline walk uses this coordinate epsilon.
/// Deliberately NOT `import_layout.outline_join_tol_mm` (1e-3): that one chains
/// authored Edge.Cuts pieces at fabrication tolerance, while this one only
/// separates two computed vertices of our own tessellation.
const outline_point_eps_mm: f64 = 1e-5;
/// Chord tolerance when flattening a routed arc for run measurement/drawing.
const arc_sagitta_mm: f64 = 0.02;

/// One straight mask-opening stroke (world mm): `widths.opening` is the full
/// opening width and `widths.copper` the trace width inside it (what a viewer
/// paints as bare copper). Real endpoints have round caps; `terminal` marks
/// ends clipped by pad dams for an inward fillet. Layer 0 = top, 1 = bottom.
pub const Stroke = struct {
    x1: f64,
    y1: f64,
    x2: f64,
    y2: f64,
    layer: u8,
    widths: struct { opening: f64, copper: f64 },
    terminal: struct {
        trim_start: bool = false,
        trim_end: bool = false,
        /// Requested terminal fillet, capped to half the opening width.
        radius: f64 = 0,
    } = .{},
};

/// One continuous mask opening. `poly` is the closed, filleted boundary used
/// by raster/DRC consumers (the last point is not repeated); `arcs` preserves
/// the same corner fillets as exact three-point circular arcs for vector
/// consumers. Layer 0 = top, 1 = bottom.
const Opening = struct {
    layer: u8,
    poly: []const [2]f64,
    arcs: []const optimizer.BoardArc = &.{},
};

/// One rounding disc at a trace bend: the two round-capped strokes that meet at
/// a joint leave a sharp concave notch on the inside of the turn (the Gerber
/// round cap rounds only the convex side). A full disc of the stroke's opening
/// diameter at the shared endpoint fills that notch — the same radius the
/// viewer's `lineJoin:"round"` paints, so the fab output matches the screen.
/// The disc opens only `layer`'s face, unlike a via land.
pub const Joint = struct { x: f64, y: f64, layer: u8, dia: f64 };

/// The complete relief set for one board's shown copper: every surviving
/// exposure-run opening, construction stroke, and bend-rounding joint disc.
/// There is deliberately no via state: mask openings are geometry, and a via
/// is bare only where that geometry happens to overlap its copper.
pub const Relief = struct {
    openings: []const Opening = &.{},
    strokes: []const Stroke = &.{},
    joints: []const Joint = &.{},

    /// Does this relief open anything at all? A false here is the byte-identity
    /// guarantee: consumers skip their whole relief pass.
    pub fn any(self: Relief) bool {
        return self.openings.len > 0 or self.strokes.len > 0 or self.joints.len > 0;
    }
};

/// The routed copper the relief is computed over (net-indexed model form).
pub const Copper = struct {
    tracks: []const router.Track = &.{},
    arcs: []const router.Arc = &.{},
    /// Exact sampled RF paths. Variable-width spans are pad tapers and stay
    /// tented; only their constant-width trace runs participate in relief.
    rf_paths: []const rf_port_report.Outcome = &.{},
};

/// The concrete per-side pullback `rule`'s routed copper opens at (mm; 0 =
/// stays tented). Authored `(mask-relief MM)` wins; an undeclared max-freq
/// class opens at the mask margin, widened over a declared fence to expose the
/// stitch row's annular rings.
pub fn reliefMm(rule: optimizer.NetRule, design: optimizer.DesignRules) f64 {
    if (rule.rf.mask_relief_mm >= 0) return rule.rf.mask_relief_mm;
    if (rule.rf.max_freq_hz <= 0) return 0;
    if (via_fence.fenceable(rule)) {
        const via = via_fence.resolvedFenceVia(rule, design);
        return via_fence.maskUntentReachMm(rule, design) + via.dia / 2 - via_fence.mask_untent_slack_mm + design.mask.margin;
    }
    return design.mask.margin;
}

fn reliefForNet(placement: optimizer.Placement, net: i32) f64 {
    if (net < 0) return 0;
    const i: usize = @intCast(net);
    if (i >= placement.rules.net.len) return 0;
    return reliefMm(placement.rules.net[i], placement.rules.design);
}

/// Compute the full relief set for `copper` at `placement`'s rules. Arena
/// allocated; an error degrades to "no relief" nowhere — callers get the error.
pub fn compute(arena: std.mem.Allocator, placement: optimizer.Placement, copper: Copper) std.mem.Allocator.Error!Relief {
    return computeImpl(arena, placement, copper, &.{});
}

/// Compute relief for routed copper including its RF via transitions. `vias`
/// are geometry inputs only: a qualifying transition appends an ordinary
/// circular `Opening` on each face whose surviving exposed trace touches its
/// copper. No per-via opening state is retained or emitted.
pub fn computeRouted(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    copper: Copper,
    vias: []const router.Via,
) std.mem.Allocator.Error!Relief {
    return computeImpl(arena, placement, copper, vias);
}

fn computeImpl(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    copper: Copper,
    transition_vias: []const router.Via,
) std.mem.Allocator.Error!Relief {
    var any_net = false;
    for (0..placement.rules.net.len) |i| {
        if (reliefForNet(placement, @intCast(i)) > 0) {
            any_net = true;
            break;
        }
    }
    if (!any_net) return .{};

    const dams = try collectDams(arena, placement);
    var openings: std.ArrayList(Opening) = .empty;
    var strokes: std.ArrayList(Stroke) = .empty;
    var joints: std.ArrayList(Joint) = .empty;
    for (0..placement.nets.len) |ni| {
        const net: i32 = @intCast(ni);
        const relief = reliefForNet(placement, net);
        if (relief <= 0) continue;
        var layer: u8 = 0;
        while (layer <= 1) : (layer += 1) {
            const stroke_start = strokes.items.len;
            try reliefRuns(arena, copper, dams, .{
                .net = net,
                .layer = layer,
                .relief = relief,
                .corner_radius = placement.rules.design.mask.relief_corner_radius,
            }, .{ .openings = &openings, .strokes = &strokes, .joints = &joints });
            try appendTransitionOpenings(arena, placement, transition_vias, strokes.items[stroke_start..], .{
                .net = net,
                .layer = layer,
                .relief = relief,
            }, &openings);
        }
    }
    return .{
        .openings = try openings.toOwnedSlice(arena),
        .strokes = try strokes.toOwnedSlice(arena),
        .joints = try joints.toOwnedSlice(arena),
    };
}

const TransitionSpec = struct { net: i32, layer: u8, relief: f64 };

/// Add one circular mask polygon around every solved RF antipad reached by a
/// surviving exposed trace on this face. The diameter mirrors trace relief:
/// physical feature (the plane antipad) plus the rule's pullback on both sides.
fn appendTransitionOpenings(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    vias: []const router.Via,
    exposed: []const Stroke,
    spec: TransitionSpec,
    openings: *std.ArrayList(Opening),
) std.mem.Allocator.Error!void {
    if (exposed.len == 0 or spec.net < 0) return;
    const ni: usize = @intCast(spec.net);
    if (ni >= placement.rules.net.len) return;
    const rule = placement.rules.net[ni];
    if (rule.rf.impedance.diff_ohms > 0) return;
    const target = if (rule.rf.impedance.ohms > 0)
        rule.rf.impedance.ohms
    else if (rule.rf.max_freq_hz > 0)
        via_antipad.default_system_ohms
    else
        return;
    const minimum = placement.rules.clearanceForNet(spec.net, placement.rules.design.clearance);

    for (vias) |via| {
        if (via.net != spec.net or !viaTouchesExposedTrace(via, exposed)) continue;
        const antipad_dia = if (via_antipad.solve(
            placement.rules.physical.stack,
            target,
            via.dia,
            via.drill,
            minimum,
        )) |solved| solved.antipad_dia_mm else via.dia + 2 * minimum;
        const dia = antipad_dia + 2 * spec.relief;
        try openings.append(arena, .{
            .layer = spec.layer,
            .poly = try circlePoly(arena, via.x, via.y, dia / 2),
        });
    }
}

fn viaTouchesExposedTrace(via: router.Via, strokes: []const Stroke) bool {
    for (strokes) |stroke| {
        const copper_reach = (via.dia + stroke.widths.copper) / 2 + join_tol_mm;
        if (pointSegmentDistance(via.x, via.y, stroke.x1, stroke.y1, stroke.x2, stroke.y2) <= copper_reach)
            return true;
    }
    return false;
}

fn pointSegmentDistance(px: f64, py: f64, x1: f64, y1: f64, x2: f64, y2: f64) f64 {
    const dx = x2 - x1;
    const dy = y2 - y1;
    const len2 = dx * dx + dy * dy;
    if (!(len2 > 0)) return std.math.hypot(px - x1, py - y1);
    const t = std.math.clamp(((px - x1) * dx + (py - y1) * dy) / len2, 0, 1);
    return std.math.hypot(px - (x1 + t * dx), py - (y1 + t * dy));
}

/// Clockwise circle polygon with at most 5 um radial sagitta, comfortably
/// below ordinary solder-mask registration tolerance.
fn circlePoly(arena: std.mem.Allocator, cx: f64, cy: f64, radius: f64) std.mem.Allocator.Error![]const [2]f64 {
    if (!(radius > 0)) return &.{};
    const max_sagitta_mm: f64 = 0.005;
    const ratio = std.math.clamp(1 - max_sagitta_mm / radius, -1, 1);
    const step = 2 * std.math.acos(ratio);
    const needed = if (step > 0) @ceil(2 * std.math.pi / step) else 24;
    const count = @max(@as(usize, 24), numeric.checkedInt(usize, needed) orelse 24);
    const out = try arena.alloc([2]f64, count);
    for (out, 0..) |*point, i| {
        const angle = -2 * std.math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(count));
        point.* = .{ cx + radius * @cos(angle), cy + radius * @sin(angle) };
    }
    return out;
}

fn maxRadius(poly: []const [2]f64, cx: f64, cy: f64) f64 {
    var radius: f64 = 0;
    for (poly) |point| radius = @max(radius, std.math.hypot(point[0] - cx, point[1] - cy));
    return radius;
}

// ── Dams ────────────────────────────────────────────────────────────────────

/// A pad's dam footprint: the pad's own world copper shape plus the margin +
/// web standoff a relief opening owes it, on the face(s) the pad opens.
///
/// The standoff is measured off the pad's OUTLINE, never off its bounding box.
/// A box is axis-aligned, so a land turned off a quarter turn dams ground it
/// does not cover — a square land at 45° boxes to twice its own area and reaches
/// a full half-diagonal past its copper, which is the pad's mask web being
/// enforced where the pad is not. What that costs is the bare band on the trace
/// terminating there: on rf-switch-eval the 90°-increment launches open their
/// relief 3.10 mm from centre while the four 45° ones lost theirs outright.
///
/// Measuring off the outline also makes the standoff uniform rather than
/// square-cornered, which is what a mask web physically is — the annulus the
/// fab keeps around an opening, not a rectangle around its bounds.
const Dam = struct { shape: pad_shape.Shape, grow: f64, top: bool, bottom: bool };

fn collectDams(arena: std.mem.Allocator, placement: optimizer.Placement) std.mem.Allocator.Error![]const Dam {
    const design = placement.rules.design;
    var out: std.ArrayList(Dam) = .empty;
    for (placement.parts) |p| {
        for (p.pads) |pad| {
            // Each pad's dam is measured off ITS OWN opening (`Pad.maskMargin`
            // — a `(mask-margin …)` pad overrides the board rule), so the web
            // this pass preserves stands against the opening the mask writer
            // actually flashes rather than a smaller one it never draws. This
            // is why the standoff is per-pad rather than one board-wide value:
            // a fiducial's 2.25 mm opening and a signal land's 1:1 one owe
            // their webs completely different distances.
            const grow = pad.maskMargin(design.mask.margin) + design.mask.web;
            const both = pad.thru or pad.npth or pad.drill > 0;
            try out.append(arena, .{
                .shape = try pad_shape.worldShape(arena, p, pad),
                .grow = grow,
                .top = both or p.side == .top,
                .bottom = both or p.side == .bottom,
            });
        }
    }
    return out.toOwnedSlice(arena);
}

fn dammed(dams: []const Dam, layer: u8, x: f64, y: f64) bool {
    for (dams) |d| {
        const blocks = if (layer == 0) d.top else d.bottom;
        if (!blocks) continue;
        const s = d.shape;
        // `pointDist` compares the bounding box first and only walks the outline
        // once the box is within `grow`, so a pad the sample is nowhere near
        // still costs one box comparison — the same work the old rect test did.
        if (pad_shape.pointDist(s.x0, s.y0, s.x1, s.y1, s.poly, x, y, d.grow) <= d.grow) return true;
    }
    return false;
}

// ── Exposure runs ───────────────────────────────────────────────────────────

const Interval = struct { seg: usize, t0: f64, t1: f64 };

/// One (net, outer layer, pullback) unit of relief work — bundled so the run
/// builder's signature stays a readable handful.
const RunSpec = struct { net: i32, layer: u8, relief: f64, corner_radius: f64 };

/// The per-run working set `reliefRuns` builds — the flattened segments, their
/// exposed intervals, and the union-find merge of those intervals — bundled so
/// the joint pass and the run builder share it without a six-parameter call.
const Run = struct {
    segs: []const router.Track,
    terminals: []const ProfileTerminals,
    ivals: []const Interval,
    comp: []usize,
    total: []const f64,
};

const ProfileTerminals = struct {
    trim_start: bool = false,
    trim_end: bool = false,
};

const profile_width_eps_mm: f64 = 1e-6;

fn profileTapers(a: f64, b: f64) bool {
    return @abs(a - b) > profile_width_eps_mm;
}

fn appendSegment(
    arena: std.mem.Allocator,
    segs: *std.ArrayList(router.Track),
    terminals: *std.ArrayList(ProfileTerminals),
    track: router.Track,
    terminal: ProfileTerminals,
) std.mem.Allocator.Error!void {
    try segs.append(arena, track);
    try terminals.append(arena, terminal);
}

/// Append only the uniform-width parts of one solver path. A changing-width
/// span is the launch taper itself: it remains covered by mask instead of
/// inheriting the DRC lowering's staircase of maximum-width capsules.
fn appendRfTraceRuns(
    arena: std.mem.Allocator,
    segs: *std.ArrayList(router.Track),
    terminals: *std.ArrayList(ProfileTerminals),
    path: rf_port_report.Outcome,
) std.mem.Allocator.Error!void {
    if (!path.success or path.physical.gate_removed) return;
    var samples: std.ArrayList(RfSample) = .empty;
    for (path.physical.samples) |sample| {
        if (samples.items.len > 0) {
            const last = &samples.items[samples.items.len - 1];
            if (std.math.hypot(sample.at[0] - last.at[0], sample.at[1] - last.at[1]) <= 1e-9) {
                last.width_mm = @max(last.width_mm, sample.width_mm);
                continue;
            }
        }
        try samples.append(arena, sample);
    }
    if (samples.items.len < 2) return;
    for (samples.items[1..], 1..) |sample, i| {
        const before = samples.items[i - 1];
        if (profileTapers(before.width_mm, sample.width_mm)) continue;
        try appendSegment(arena, segs, terminals, .{
            .x1 = before.at[0],
            .y1 = before.at[1],
            .x2 = sample.at[0],
            .y2 = sample.at[1],
            .layer = path.physical.layer,
            .width = @max(before.width_mm, sample.width_mm),
            .net = path.net,
        }, .{
            .trim_start = i > 1 and profileTapers(samples.items[i - 2].width_mm, before.width_mm),
            .trim_end = i + 1 < samples.items.len and profileTapers(sample.width_mm, samples.items[i + 1].width_mm),
        });
    }
}

const RunOutput = struct {
    openings: *std.ArrayList(Opening),
    strokes: *std.ArrayList(Stroke),
    joints: *std.ArrayList(Joint),
};

/// Append the surviving relief strokes for one `RunSpec`: sample the segments
/// against the dams, union contiguous exposed intervals across segment
/// joints, and emit every component whose total length clears
/// `min_exposed_mm`. Bend joints between two surviving intervals also emit a
/// rounding disc (`joints`) so the Gerber mask matches the viewer's round join
/// instead of leaving sharp concave notches.
fn reliefRuns(
    arena: std.mem.Allocator,
    copper: Copper,
    dams: []const Dam,
    spec: RunSpec,
    output: RunOutput,
) std.mem.Allocator.Error!void {
    var segs: std.ArrayList(router.Track) = .empty;
    var terminals: std.ArrayList(ProfileTerminals) = .empty;
    for (copper.tracks) |t| {
        if (t.net != spec.net or t.layer != spec.layer) continue;
        if (path_copper.ownsTrack(copper.rf_paths, t)) continue;
        if (arcOwned(copper.arcs, t)) continue;
        try appendSegment(arena, &segs, &terminals, t, .{});
    }
    for (try path_copper.filterArcs(arena, copper.rf_paths, copper.arcs)) |a| {
        if (a.net != spec.net or a.layer != spec.layer) continue;
        for (try bend_smooth.tessellate(arena, a, arc_sagitta_mm)) |track|
            try appendSegment(arena, &segs, &terminals, track, .{});
    }
    for (copper.rf_paths) |path| {
        if (path.net != spec.net or path.physical.layer != spec.layer) continue;
        try appendRfTraceRuns(arena, &segs, &terminals, path);
    }
    if (segs.items.len == 0) return;

    var ivals: std.ArrayList(Interval) = .empty;
    for (segs.items, 0..) |s, si| {
        const len = std.math.hypot(s.x2 - s.x1, s.y2 - s.y1);
        if (len <= 0) continue;
        const steps = numeric.checkedInt(usize, @ceil(len / sample_mm)) orelse 1;
        var run_start: ?f64 = null;
        var last_exposed: f64 = 0;
        var k: usize = 0;
        while (k <= steps) : (k += 1) {
            const t = len * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(steps));
            const x = s.x1 + (s.x2 - s.x1) * t / len;
            const y = s.y1 + (s.y2 - s.y1) * t / len;
            if (!dammed(dams, spec.layer, x, y)) {
                if (run_start == null) run_start = t;
                last_exposed = t;
                if (k == steps) try ivals.append(arena, .{ .seg = si, .t0 = run_start.?, .t1 = t });
            } else if (run_start) |t0| {
                try ivals.append(arena, .{ .seg = si, .t0 = t0, .t1 = last_exposed });
                run_start = null;
            }
        }
    }
    if (ivals.items.len == 0) return;

    // Union-find over intervals: two intervals join where one's segment end
    // lands on the other's exposed span (end-to-end joints and T-joints alike).
    const comp = try arena.alloc(usize, ivals.items.len);
    for (comp, 0..) |*c, i| c.* = i;
    for (ivals.items, 0..) |a, i| {
        for (ivals.items[i + 1 ..], i + 1..) |b, j| {
            if (intervalsTouch(segs.items, a, b)) unite(comp, i, j);
        }
    }
    const total = try arena.alloc(f64, ivals.items.len);
    @memset(total, 0);
    for (ivals.items, 0..) |iv, i| total[root(comp, i)] += iv.t1 - iv.t0;

    const run = Run{
        .segs = try segs.toOwnedSlice(arena),
        .terminals = try terminals.toOwnedSlice(arena),
        .ivals = try ivals.toOwnedSlice(arena),
        .comp = comp,
        .total = total,
    };
    try emitRunGeometry(arena, dams, spec, run, output);
}

fn emitRunGeometry(arena: std.mem.Allocator, dams: []const Dam, spec: RunSpec, run: Run, output: RunOutput) std.mem.Allocator.Error!void {
    const built = try arena.alloc(?Stroke, run.ivals.len);
    @memset(built, null);
    for (run.ivals, 0..) |iv, i| {
        if (iv.t1 - iv.t0 < 1e-6) continue;
        if (run.total[root(run.comp, i)] < min_exposed_mm) continue;
        const s = run.segs[iv.seg];
        const len = std.math.hypot(s.x2 - s.x1, s.y2 - s.y1);
        const stroke: Stroke = .{
            .x1 = s.x1 + (s.x2 - s.x1) * iv.t0 / len,
            .y1 = s.y1 + (s.y2 - s.y1) * iv.t0 / len,
            .x2 = s.x1 + (s.x2 - s.x1) * iv.t1 / len,
            .y2 = s.y1 + (s.y2 - s.y1) * iv.t1 / len,
            .layer = spec.layer,
            .widths = .{ .opening = s.width + 2 * spec.relief, .copper = s.width },
            .terminal = .{
                .trim_start = intervalTerminal(dams, spec.layer, run, i, true),
                .trim_end = intervalTerminal(dams, spec.layer, run, i, false),
                .radius = spec.corner_radius,
            },
        };
        built[i] = stroke;
        try output.strokes.append(arena, stroke);
    }

    // A relief component is authored and consumed as one closed boundary, not
    // as a pile of independently round-capped route chords. Build the raw
    // left/right offset polygon once, then fillet its actual vertices with the
    // editable design radius. The strokes remain construction data for fence
    // qualification and copper repainting only.
    const emitted = try arena.alloc(bool, run.ivals.len);
    @memset(emitted, false);
    for (built, 0..) |maybe_stroke, i| {
        if (maybe_stroke == null) continue;
        const component = root(run.comp, i);
        if (emitted[component]) continue;
        emitted[component] = true;
        var component_strokes: std.ArrayList(Stroke) = .empty;
        for (built, 0..) |candidate, j| {
            if (candidate != null and root(run.comp, j) == component)
                try component_strokes.append(arena, candidate.?);
        }
        if (try openingForRun(arena, component_strokes.items, spec.corner_radius)) |opening|
            try output.openings.append(arena, opening);
    }
    try emitJoints(arena, run, spec, output.joints);
}

/// Is one exposed interval endpoint clipped by a pad dam? Sampling can leave a
/// zero-length interval at the end of a short route chord, followed by a fully
/// exposed chord whose local t starts at zero. Probe just behind that exposed
/// endpoint so the pad-dam terminal survives the chord boundary and receives
/// the authored fillet. An actual exposed continuation wins first, preventing
/// an ordinary bend or T-joint near a pad from being mistaken for a terminal.
fn intervalTerminal(dams: []const Dam, layer: u8, run: Run, index: usize, at_start: bool) bool {
    const iv = run.ivals[index];
    const s = run.segs[iv.seg];
    const len = segLen(s);
    if (at_start and iv.t0 > join_tol_mm) return true;
    if (!at_start and len - iv.t1 > join_tol_mm) return true;
    const t = if (at_start) iv.t0 else iv.t1;
    if (endpointHasExposedContinuation(run, index, t)) return false;
    const profile = run.terminals[iv.seg];
    const profile_terminal = if (at_start) profile.trim_start else profile.trim_end;
    if (profile_terminal) return true;
    const probe = if (at_start) t - sample_mm - join_tol_mm else t + sample_mm + join_tol_mm;
    const x = s.x1 + (s.x2 - s.x1) * probe / len;
    const y = s.y1 + (s.y2 - s.y1) * probe / len;
    return dammed(dams, layer, x, y);
}

fn endpointHasExposedContinuation(run: Run, index: usize, t: f64) bool {
    const source = run.segs[run.ivals[index].seg];
    const len = segLen(source);
    const x = source.x1 + (source.x2 - source.x1) * t / len;
    const y = source.y1 + (source.y2 - source.y1) * t / len;
    for (run.ivals, 0..) |other, other_index| {
        if (other_index == index or other.t1 - other.t0 < 1e-6) continue;
        if (run.total[root(run.comp, other_index)] < min_exposed_mm) continue;
        if (pointOnInterval(run.segs, other, x, y)) return true;
    }
    return false;
}

/// Round the bends of one run: any two surviving intervals whose segments meet
/// at a coincident endpoint get a full disc at that vertex. The disc fills the
/// concave notch the two round caps leave and is a no-op on the convex side
/// (already covered), which is exactly a round join.
fn emitJoints(
    arena: std.mem.Allocator,
    run: Run,
    spec: RunSpec,
    out: *std.ArrayList(Joint),
) std.mem.Allocator.Error!void {
    const segs = run.segs;
    const ivals = run.ivals;
    for (ivals, 0..) |a, i| {
        if (run.total[root(run.comp, i)] < min_exposed_mm) continue;
        for (ivals[i + 1 ..], i + 1..) |b, j| {
            if (run.total[root(run.comp, j)] < min_exposed_mm) continue;
            const pt = sharedEndpoint(segs, a, b) orelse continue;
            const dia = @max(segs[a.seg].width, segs[b.seg].width) + 2 * spec.relief;
            try out.append(arena, .{ .x = pt[0], .y = pt[1], .layer = spec.layer, .dia = dia });
        }
    }
}

/// The point where intervals `a` and `b` meet end-to-end at a real corner: a
/// segment endpoint of `a` that its exposed span reaches, coinciding (within
/// `join_tol_mm`) with a segment endpoint of `b` that its exposed span reaches,
/// and the two segments NOT collinear. Null for T-joints (a straight
/// continuation has no corner to round), for a collinear run split across two
/// tracks (the joint is already covered), and for trimmed, dammed ends.
fn sharedEndpoint(segs: []const router.Track, a: Interval, b: Interval) ?[2]f64 {
    if (a.seg == b.seg) return null;
    const sa = segs[a.seg];
    const sb = segs[b.seg];
    const la = segLen(sa);
    const lb = segLen(sb);
    const ea = [2][2]f64{ .{ sa.x1, sa.y1 }, .{ sa.x2, sa.y2 } };
    const eb = [2][2]f64{ .{ sb.x1, sb.y1 }, .{ sb.x2, sb.y2 } };
    for (ea, 0..) |pa, ai| {
        const at_a: f64 = if (ai == 0) 0 else la;
        if (@abs(a.t0 - at_a) > join_tol_mm and @abs(a.t1 - at_a) > join_tol_mm) continue;
        for (eb, 0..) |pb, bi| {
            const at_b: f64 = if (bi == 0) 0 else lb;
            if (@abs(b.t0 - at_b) > join_tol_mm and @abs(b.t1 - at_b) > join_tol_mm) continue;
            if (std.math.hypot(pa[0] - pb[0], pa[1] - pb[1]) > join_tol_mm) continue;
            // Collinear (a straight run split across two tracks) has no corner:
            // its disc would sit exactly inside the capsule it already is.
            const dax = sa.x2 - sa.x1;
            const day = sa.y2 - sa.y1;
            const dbx = sb.x2 - sb.x1;
            const dby = sb.y2 - sb.y1;
            const cross = dax * dby - day * dbx;
            if (@abs(cross) <= 1e-3 * la * lb) return null;
            return pb;
        }
    }
    return null;
}

fn segLen(s: router.Track) f64 {
    return std.math.hypot(s.x2 - s.x1, s.y2 - s.y1);
}

fn root(comp: []usize, i: usize) usize {
    var r = i;
    while (comp[r] != r) r = comp[r];
    var w = i;
    while (comp[w] != w) {
        const next = comp[w];
        comp[w] = r;
        w = next;
    }
    return r;
}

fn unite(comp: []usize, a: usize, b: usize) void {
    comp[root(comp, a)] = root(comp, b);
}

/// Do intervals `a` and `b` form one continuous exposed run? True when an
/// exposed END of either interval lies on the other's exposed span (within
/// `join_tol_mm`) — which covers end-to-end chains and mid-span T-joints.
fn intervalsTouch(segs: []const router.Track, a: Interval, b: Interval) bool {
    return endOnSpan(segs, a, b) or endOnSpan(segs, b, a);
}

fn endOnSpan(segs: []const router.Track, from: Interval, on: Interval) bool {
    const fs = segs[from.seg];
    const flen = std.math.hypot(fs.x2 - fs.x1, fs.y2 - fs.y1);
    if (flen <= 0) return false;
    for ([2]f64{ from.t0, from.t1 }) |t| {
        const x = fs.x1 + (fs.x2 - fs.x1) * t / flen;
        const y = fs.y1 + (fs.y2 - fs.y1) * t / flen;
        if (pointOnInterval(segs, on, x, y)) return true;
    }
    return false;
}

fn pointOnInterval(segs: []const router.Track, interval: Interval, x: f64, y: f64) bool {
    const s = segs[interval.seg];
    const len = segLen(s);
    if (len <= 0) return false;
    const proj = ((x - s.x1) * (s.x2 - s.x1) + (y - s.y1) * (s.y2 - s.y1)) / len;
    if (proj < interval.t0 - join_tol_mm or proj > interval.t1 + join_tol_mm) return false;
    const clamped = std.math.clamp(proj, 0, len);
    const px = s.x1 + (s.x2 - s.x1) * clamped / len;
    const py = s.y1 + (s.y2 - s.y1) * clamped / len;
    return std.math.hypot(x - px, y - py) <= join_tol_mm;
}

fn arcOwned(arcs: []const router.Arc, track: router.Track) bool {
    for (arcs) |arc| {
        if (arc.layer != track.layer or arc.net != track.net or @abs(arc.width - track.width) > 0.0001) continue;
        if (outline.arcOwnsSegment(.{ .p1 = arc.p1, .pm = arc.pm, .p2 = arc.p2 }, .{ track.x1, track.y1 }, .{ track.x2, track.y2 }, 0.0001)) return true;
    }
    return false;
}

// ── Continuous opening outlines ────────────────────────────────────────────

const OrientedStroke = struct {
    stroke: Stroke,
    reversed: bool,

    fn start(self: OrientedStroke) [2]f64 {
        return if (self.reversed) .{ self.stroke.x2, self.stroke.y2 } else .{ self.stroke.x1, self.stroke.y1 };
    }

    fn end(self: OrientedStroke) [2]f64 {
        return if (self.reversed) .{ self.stroke.x1, self.stroke.y1 } else .{ self.stroke.x2, self.stroke.y2 };
    }
};

const BoundaryLine = struct { a: [2]f64, b: [2]f64, half: f64 };

/// Turn one non-branching exposure-run component into a single closed offset
/// polygon and fillet the polygon's vertices. RF signal routes are paths; a
/// genuinely branching component is left to the legacy stroke fallback until
/// it has an explicit planar-union representation rather than pretending its
/// independent capsules are one polygon.
fn openingForRun(arena: std.mem.Allocator, strokes: []const Stroke, corner_radius: f64) std.mem.Allocator.Error!?Opening {
    if (strokes.len == 0) return null;
    const ordered = try orderRun(arena, strokes) orelse return null;

    var raw: std.ArrayList([2]f64) = .empty;
    var lines = try arena.alloc(BoundaryLine, ordered.len);
    for (ordered, 0..) |s, i| lines[i] = boundaryLine(s, 1);
    try appendUniquePoint(&raw, arena, lines[0].a);
    for (0..lines.len - 1) |i| try appendBoundaryJoin(&raw, arena, lines[i], lines[i + 1]);
    try appendUniquePoint(&raw, arena, lines[lines.len - 1].b);

    for (ordered, 0..) |s, line_index| {
        const right = boundaryLine(s, -1);
        lines[line_index] = .{ .a = right.b, .b = right.a, .half = right.half };
    }
    try appendUniquePoint(&raw, arena, lines[lines.len - 1].a);
    var i = lines.len - 1;
    while (i > 0) : (i -= 1) try appendBoundaryJoin(&raw, arena, lines[i], lines[i - 1]);
    try appendUniquePoint(&raw, arena, lines[0].b);
    if (raw.items.len < 3) return null;

    const radii = try arena.alloc(f64, raw.items.len);
    @memset(radii, @max(0, corner_radius));
    const filleted = try outline.filletPath(arena, raw.items, radii, 0.005);
    return .{ .layer = strokes[0].layer, .poly = filleted.poly, .arcs = filleted.arcs };
}

/// Order a path component from one degree-one endpoint to the other. Returning
/// null for a branch is deliberate: choosing one arbitrary walk through a
/// junction would create a self-crossing mask boundary.
fn orderRun(arena: std.mem.Allocator, strokes: []const Stroke) std.mem.Allocator.Error!?[]const OrientedStroke {
    const used = try arena.alloc(bool, strokes.len);
    @memset(used, false);

    var first: ?usize = null;
    var first_reversed = false;
    for (strokes, 0..) |s, i| {
        if (endpointDegree(strokes, .{ s.x1, s.y1 }) == 1) {
            first = i;
            break;
        }
        if (endpointDegree(strokes, .{ s.x2, s.y2 }) == 1) {
            first = i;
            first_reversed = true;
            break;
        }
    }
    const start_index = first orelse return null;
    var ordered: std.ArrayList(OrientedStroke) = .empty;
    var current = OrientedStroke{ .stroke = strokes[start_index], .reversed = first_reversed };
    var current_index = start_index;
    while (true) {
        used[current_index] = true;
        try ordered.append(arena, current);
        const p = current.end();
        var next: ?usize = null;
        var next_reversed = false;
        for (strokes, 0..) |candidate, candidate_index| {
            if (used[candidate_index]) continue;
            const at_start = pointsMeet(p, .{ candidate.x1, candidate.y1 });
            const at_end = pointsMeet(p, .{ candidate.x2, candidate.y2 });
            if (!at_start and !at_end) continue;
            if (next != null) return null;
            next = candidate_index;
            next_reversed = at_end;
        }
        current_index = next orelse break;
        current = .{ .stroke = strokes[current_index], .reversed = next_reversed };
    }
    for (used) |was_used| if (!was_used) return null;
    return try ordered.toOwnedSlice(arena);
}

fn endpointDegree(strokes: []const Stroke, p: [2]f64) usize {
    var degree: usize = 0;
    for (strokes) |s| {
        if (pointsMeet(p, .{ s.x1, s.y1 })) degree += 1;
        if (pointsMeet(p, .{ s.x2, s.y2 })) degree += 1;
    }
    return degree;
}

fn pointsMeet(a: [2]f64, b: [2]f64) bool {
    return std.math.hypot(a[0] - b[0], a[1] - b[1]) <= outline_point_eps_mm;
}

fn boundaryLine(s: OrientedStroke, side: f64) BoundaryLine {
    const a = s.start();
    const b = s.end();
    const len = std.math.hypot(b[0] - a[0], b[1] - a[1]);
    const half = s.stroke.widths.opening / 2;
    const nx = if (len > 0) -(b[1] - a[1]) / len * side else 0;
    const ny = if (len > 0) (b[0] - a[0]) / len * side else side;
    return .{
        .a = .{ a[0] + nx * half, a[1] + ny * half },
        .b = .{ b[0] + nx * half, b[1] + ny * half },
        .half = half,
    };
}

fn appendBoundaryJoin(out: *std.ArrayList([2]f64), arena: std.mem.Allocator, a: BoundaryLine, b: BoundaryLine) std.mem.Allocator.Error!void {
    if (lineIntersection(a.a, a.b, b.a, b.b)) |p| {
        // Reject an unbounded miter at a near reversal. A short bevel is a
        // faithful polygon corner and the common fillet pass rounds both ends.
        const reach = std.math.hypot(p[0] - a.b[0], p[1] - a.b[1]);
        if (reach <= 4 * @max(a.half, b.half)) {
            try appendUniquePoint(out, arena, p);
            return;
        }
    }
    try appendUniquePoint(out, arena, a.b);
    try appendUniquePoint(out, arena, b.a);
}

fn lineIntersection(a0: [2]f64, a1: [2]f64, b0: [2]f64, b1: [2]f64) ?[2]f64 {
    const ax = a1[0] - a0[0];
    const ay = a1[1] - a0[1];
    const bx = b1[0] - b0[0];
    const by = b1[1] - b0[1];
    const cross = ax * by - ay * bx;
    if (@abs(cross) < 1e-9) return null;
    const qx = b0[0] - a0[0];
    const qy = b0[1] - a0[1];
    const t = (qx * by - qy * bx) / cross;
    return .{ a0[0] + t * ax, a0[1] + t * ay };
}

fn appendUniquePoint(out: *std.ArrayList([2]f64), arena: std.mem.Allocator, p: [2]f64) std.mem.Allocator.Error!void {
    if (out.items.len > 0) {
        const q = out.items[out.items.len - 1];
        if (std.math.hypot(q[0] - p[0], q[1] - p[1]) <= 1e-7) return;
    }
    try out.append(arena, p);
}

// ── Opening outlines ────────────────────────────────────────────────────────

/// Quarter-circle tessellation for one terminal fillet. Mask Gerbers use 1 µm
/// coordinates, while six chords over the small (normally 0.2–0.3 mm) radius
/// keep the outline comfortably below ordinary solder-mask registration error.
const terminal_arc_segments: usize = 6;

/// Exact opening outline for one stroke. Real copper endpoints keep the
/// historical semicircular cap. An endpoint clipped by a pad dam instead ends
/// at the dam boundary with an inward corner fillet, so the later clear dam
/// does not slice a round stroke into the sharp vertical corners seen in the
/// assembly review. Arena allocated, clockwise, and not explicitly closed.
pub fn openingPoly(arena: std.mem.Allocator, s: Stroke) std.mem.Allocator.Error![]const [2]f64 {
    const dx = s.x2 - s.x1;
    const dy = s.y2 - s.y1;
    const len = std.math.hypot(dx, dy);
    const half = s.widths.opening / 2;
    if (!(len > 0) or !(half > 0)) return &.{};
    const ux = dx / len;
    const uy = dy / len;
    const cap_limit = if (s.terminal.trim_start and s.terminal.trim_end) len / 2 else len;
    const requested = @max(0, s.terminal.radius);
    const rs = if (s.terminal.trim_start) @min(requested, @min(half, cap_limit)) else half;
    const re = if (s.terminal.trim_end) @min(requested, @min(half, cap_limit)) else half;
    const pi: f64 = std.math.pi;

    var out: std.ArrayList([2]f64) = .empty;
    var builder = OpeningBuilder{ .arena = arena, .out = &out, .stroke = s, .ux = ux, .uy = uy };
    try builder.point(if (s.terminal.trim_start) rs else 0, half);
    try builder.point(if (s.terminal.trim_end) len - re else len, half);

    if (s.terminal.trim_end) {
        if (re > 0) try builder.arc(.{ .cx = len - re, .cy = half - re, .radius = re, .start = pi / 2, .end = 0 });
        try builder.point(len, -half + re);
        if (re > 0) try builder.arc(.{ .cx = len - re, .cy = -half + re, .radius = re, .start = 0, .end = -pi / 2 });
    } else {
        try builder.arc(.{ .cx = len, .cy = 0, .radius = half, .start = pi / 2, .end = -pi / 2, .segments = 2 * terminal_arc_segments });
    }

    try builder.point(if (s.terminal.trim_start) rs else 0, -half);
    if (s.terminal.trim_start) {
        if (rs > 0) try builder.arc(.{ .cx = rs, .cy = -half + rs, .radius = rs, .start = -pi / 2, .end = -pi });
        try builder.point(0, half - rs);
        if (rs > 0) try builder.arc(.{ .cx = rs, .cy = half - rs, .radius = rs, .start = pi, .end = pi / 2 });
    } else {
        try builder.arc(.{ .cx = 0, .cy = 0, .radius = half, .start = -pi / 2, .end = -3 * pi / 2, .segments = 2 * terminal_arc_segments });
    }
    return out.toOwnedSlice(arena);
}

/// Final local repair for one dam-clipped terminal. Relief routes are often
/// tessellated into chords much shorter than the mask opening is wide, so the
/// round cap of the NEXT chord can overlap an otherwise-correct terminal
/// polygon and make every authored radius look the same. Consumers apply all
/// `clear` quads after drawing the run, then repaint every `patch`: the result
/// is one exact fillet at the original dam boundary, independent of chord
/// length or draw order.
pub const TerminalFinish = struct {
    clear: [4][2]f64,
    patch: []const [2]f64,
};

/// Build the clear-and-repaint polygons for one selected end of `s`.
pub fn terminalFinish(arena: std.mem.Allocator, s: Stroke, at_start: bool) std.mem.Allocator.Error!?TerminalFinish {
    if (at_start) {
        if (!s.terminal.trim_start) return null;
    } else if (!s.terminal.trim_end) return null;
    const dx = s.x2 - s.x1;
    const dy = s.y2 - s.y1;
    const len = std.math.hypot(dx, dy);
    const half = s.widths.opening / 2;
    if (!(len > 0) or !(half > 0)) return null;
    const direction: f64 = if (at_start) 1 else -1;
    const ux = direction * dx / len;
    const uy = direction * dy / len;
    const tx = if (at_start) s.x1 else s.x2;
    const ty = if (at_start) s.y1 else s.y2;
    const radius = @min(@max(0, s.terminal.radius), half);
    const clear = [4][2]f64{
        terminalPoint(tx, ty, ux, uy, -half, half),
        terminalPoint(tx, ty, ux, uy, radius, half),
        terminalPoint(tx, ty, ux, uy, radius, -half),
        terminalPoint(tx, ty, ux, uy, -half, -half),
    };
    if (!(radius > 0)) return .{ .clear = clear, .patch = &.{} };
    const pi: f64 = std.math.pi;

    var out: std.ArrayList([2]f64) = .empty;
    try out.append(arena, terminalPoint(tx, ty, ux, uy, radius, half));
    try out.append(arena, terminalPoint(tx, ty, ux, uy, radius, -half));
    try terminalArc(arena, &out, .{ tx, ty }, .{ ux, uy }, .{
        .cx = radius,
        .cy = -half + radius,
        .radius = radius,
        .start = -pi / 2,
        .end = -pi,
    });
    try out.append(arena, terminalPoint(tx, ty, ux, uy, 0, half - radius));
    try terminalArc(arena, &out, .{ tx, ty }, .{ ux, uy }, .{
        .cx = radius,
        .cy = half - radius,
        .radius = radius,
        .start = pi,
        .end = pi / 2,
    });
    return .{ .clear = clear, .patch = try out.toOwnedSlice(arena) };
}

fn terminalPoint(tx: f64, ty: f64, ux: f64, uy: f64, along: f64, normal: f64) [2]f64 {
    return .{ tx + ux * along - uy * normal, ty + uy * along + ux * normal };
}

fn terminalArc(
    arena: std.mem.Allocator,
    out: *std.ArrayList([2]f64),
    terminal: [2]f64,
    direction: [2]f64,
    arc: LocalArc,
) std.mem.Allocator.Error!void {
    for (1..arc.segments + 1) |i| {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(arc.segments));
        const angle = arc.start + (arc.end - arc.start) * t;
        try out.append(arena, terminalPoint(
            terminal[0],
            terminal[1],
            direction[0],
            direction[1],
            arc.cx + arc.radius * @cos(angle),
            arc.cy + arc.radius * @sin(angle),
        ));
    }
}

const LocalArc = struct {
    cx: f64,
    cy: f64,
    radius: f64,
    start: f64,
    end: f64,
    segments: usize = terminal_arc_segments,
};

const OpeningBuilder = struct {
    arena: std.mem.Allocator,
    out: *std.ArrayList([2]f64),
    stroke: Stroke,
    ux: f64,
    uy: f64,

    fn point(self: *OpeningBuilder, along: f64, normal: f64) std.mem.Allocator.Error!void {
        const p = [2]f64{
            self.stroke.x1 + self.ux * along - self.uy * normal,
            self.stroke.y1 + self.uy * along + self.ux * normal,
        };
        if (self.out.items.len > 0) {
            const prev = self.out.items[self.out.items.len - 1];
            if (std.math.hypot(prev[0] - p[0], prev[1] - p[1]) < 1e-9) return;
        }
        try self.out.append(self.arena, p);
    }

    fn arc(self: *OpeningBuilder, a: LocalArc) std.mem.Allocator.Error!void {
        for (1..a.segments + 1) |i| {
            const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(a.segments));
            const angle = a.start + (a.end - a.start) * t;
            try self.point(a.cx + a.radius * @cos(angle), a.cy + a.radius * @sin(angle));
        }
    }
};

/// The square-cap outline of one stroke's OPENING — the obstacle silkscreen
/// treats a bare-copper band as (ink on exposed copper is scrap). Square caps
/// slightly over-cover the round Gerber caps, which is the right direction for
/// a keepout.
pub fn strokePoly(s: Stroke) [4][2]f64 {
    const dx = s.x2 - s.x1;
    const dy = s.y2 - s.y1;
    const len = std.math.hypot(dx, dy);
    const h = s.widths.opening / 2;
    const ux = if (len > 0) dx / len else 1;
    const uy = if (len > 0) dy / len else 0;
    const ax = s.x1 - ux * h;
    const ay = s.y1 - uy * h;
    const bx = s.x2 + ux * h;
    const by = s.y2 + uy * h;
    return .{
        .{ ax - uy * h, ay + ux * h },
        .{ bx - uy * h, by + ux * h },
        .{ bx + uy * h, by - ux * h },
        .{ ax + uy * h, ay - ux * h },
    };
}

// ── Sub-minimum web suppression ────────────────────────────────────────────

const merge_eps: f64 = 1e-9;

/// One round-ended dark stroke on a negative solder-mask layer. `layer` uses
/// the routed-copper convention (0 = top, 1 = bottom).
pub const Merge = struct {
    x1: f64,
    y1: f64,
    x2: f64,
    y2: f64,
    width: f64,
    layer: u8,
};

const PadOpening = struct {
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,
    top: bool,
    bottom: bool,
};

fn openingOn(o: PadOpening, layer: u8) bool {
    return if (layer == 0) o.top else o.bottom;
}

fn appendMerge(out: *std.ArrayList(Merge), arena: std.mem.Allocator, a: PadOpening, b: PadOpening, layer: u8, min_web: f64) std.mem.Allocator.Error!void {
    if (!openingOn(a, layer) or !openingOn(b, layer)) return;

    const gx = @max(a.x0 - b.x1, b.x0 - a.x1);
    const gy = @max(a.y0 - b.y1, b.y0 - a.y1);
    if (gx >= min_web - merge_eps or gy >= min_web - merge_eps) return;
    const gap = if (gx > 0 and gy > 0) std.math.hypot(gx, gy) else @max(gx, gy);
    // Non-positive means the apertures already merge. A legal-width web stays.
    if (gap <= merge_eps or gap >= min_web - merge_eps) return;

    var merge: Merge = undefined;
    if (gx > 0 and gy <= 0) {
        // Side-by-side apertures: delete the complete web over their shared Y
        // span, rather than merely nicking its centre.
        const left = if (a.x1 <= b.x0) a else b;
        const right = if (a.x1 <= b.x0) b else a;
        const lo = @max(a.y0, b.y0);
        const hi = @min(a.y1, b.y1);
        if (hi - lo <= merge_eps) return;
        merge = .{ .x1 = left.x1, .y1 = (lo + hi) / 2, .x2 = right.x0, .y2 = (lo + hi) / 2, .width = hi - lo, .layer = layer };
    } else if (gy > 0 and gx <= 0) {
        // Stacked apertures: the corresponding full shared X span.
        const lower = if (a.y1 <= b.y0) a else b;
        const upper = if (a.y1 <= b.y0) b else a;
        const lo = @max(a.x0, b.x0);
        const hi = @min(a.x1, b.x1);
        if (hi - lo <= merge_eps) return;
        merge = .{ .x1 = (lo + hi) / 2, .y1 = lower.y1, .x2 = (lo + hi) / 2, .y2 = upper.y0, .width = hi - lo, .layer = layer };
    } else {
        // Corner-to-corner adjacency has no shared projection. Cut a bounded
        // min-web-wide diagonal join between the nearest aperture corners.
        const ax = if (a.x1 <= b.x0) a.x1 else a.x0;
        const bx = if (a.x1 <= b.x0) b.x0 else b.x1;
        const ay = if (a.y1 <= b.y0) a.y1 else a.y0;
        const by = if (a.y1 <= b.y0) b.y0 else b.y1;
        const narrow = @min(@min(a.x1 - a.x0, a.y1 - a.y0), @min(b.x1 - b.x0, b.y1 - b.y0));
        merge = .{ .x1 = ax, .y1 = ay, .x2 = bx, .y2 = by, .width = @min(min_web, narrow), .layer = layer };
    }
    if (merge.width > merge_eps) try out.append(arena, merge);
}

/// Collect every pad-aperture join needed by the resolved minimum mask web.
/// SMD pads open on their component face; through/NPTH pads open on both.
/// Each pad's own mask-margin override sizes its aperture before the pair is
/// judged. Pairs inside one footprint are included: a fab limit applies to the
/// finished mask regardless of which footprint authored the neighbouring pads.
pub fn collectMerges(arena: std.mem.Allocator, placement: optimizer.Placement) std.mem.Allocator.Error![]const Merge {
    const min_web = placement.rules.design.mask.web;
    if (min_web <= 0) return &.{};

    var openings: std.ArrayList(PadOpening) = .empty;
    for (placement.parts) |part| {
        for (part.pads) |pad| {
            const shape = try pad_shape.worldShape(arena, part, pad);
            const margin = pad.maskMargin(placement.rules.design.mask.margin);
            const opening = PadOpening{
                .x0 = shape.x0 - margin,
                .y0 = shape.y0 - margin,
                .x1 = shape.x1 + margin,
                .y1 = shape.y1 + margin,
                .top = pad.thru or pad.npth or part.side == .top,
                .bottom = pad.thru or pad.npth or part.side == .bottom,
            };
            // A sufficiently negative override can suppress the aperture.
            if (opening.x1 - opening.x0 <= merge_eps or opening.y1 - opening.y0 <= merge_eps) continue;
            try openings.append(arena, opening);
        }
    }

    var out: std.ArrayList(Merge) = .empty;
    for (openings.items, 0..) |a, i| {
        for (openings.items[i + 1 ..]) |b| {
            try appendMerge(&out, arena, a, b, 0, min_web);
            try appendMerge(&out, arena, a, b, 1, min_web);
        }
    }
    return out.toOwnedSlice(arena);
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;
const flat_netlist = @import("../flat_netlist.zig");
const geometry = @import("geometry.zig");

fn testPlacement(parts: []optimizer.Part, nets: []const flat_netlist.FlatNet, rules: []const optimizer.NetRule) optimizer.Placement {
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
        .maxx = 20,
        .maxy = 10,
        .generated = false,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 20, .h = 10 },
        .rules = .{ .net = rules },
    };
}

const two_nets = [_]flat_netlist.FlatNet{
    .{ .name = "RF", .pins = &.{} },
    .{ .name = "GND", .pins = &.{} },
};

test "sub-minimum pad-aperture webs are merged" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.2, .hh = 0.2, .pads = &pads, .fallback = false },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.2, .hh = 0.2, .pads = &pads, .fallback = false, .x = 0.45 },
    };
    const merges = try collectMerges(arena, testPlacement(&parts, &.{}, &.{}));
    try testing.expectEqual(@as(usize, 1), merges.len);
    try testing.expectEqual(@as(u8, 0), merges[0].layer);
    try testing.expectApproxEqAbs(@as(f64, 0.2), merges[0].x1, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.25), merges[0].x2, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.4), merges[0].width, 1e-9);

    parts[1].x = 0.5; // opening gap = 0.1 mm: exactly legal, no merge.
    try testing.expectEqual(@as(usize, 0), (try collectMerges(arena, testPlacement(&parts, &.{}, &.{}))).len);
}

test "through-pad web merges reach both faces and use pad margins" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const pads = [_]geometry.Pad{
        .{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4, .thru = true, .drill = 0.2, .overrides = .{ .mask_margin = 0.1 } },
        .{ .number = "2", .x = 0.65, .y = 0, .w = 0.4, .h = 0.4, .thru = true, .drill = 0.2, .overrides = .{ .mask_margin = 0.1 } },
    };
    var parts = [_]optimizer.Part{.{ .ref_des = "J1", .kind = .passive, .hw = 0.6, .hh = 0.2, .pads = &pads, .fallback = false }};
    const merges = try collectMerges(arena, testPlacement(&parts, &.{}, &.{}));
    try testing.expectEqual(@as(usize, 2), merges.len);
    try testing.expectEqual(@as(u8, 0), merges[0].layer);
    try testing.expectEqual(@as(u8, 1), merges[1].layer);
}

// spec: placement/mask-relief - a fenced max-freq class's default band widens to expose the fence row's annular rings
// spec: placement/mask-relief - a layered fence's default band reaches the outermost row
// spec: placement/mask-relief - a layered fence can limit its derived mask opening to the innermost N rows
// spec: placement/mask-relief - a max-freq class without a (fence …) widens the same way, because it is a fence target too and its generated fence row must untent
test "fenced default band swallows the fence row" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const fenced = [_]optimizer.NetRule{
        .{ .class = .{ .name = "rf" }, .rf = .{ .max_freq_hz = 12e9, .fence = .{ .declared = true } } },
        .{},
    };
    var placement = testPlacement(&.{}, &two_nets, &fenced);
    const tracks = [_]router.Track{.{ .x1 = 2, .y1 = 5, .x2 = 8, .y2 = 5, .layer = 0, .width = 0.2, .net = 0 }};
    const r = try compute(arena, placement, .{ .tracks = &tracks });
    try testing.expectEqual(@as(usize, 1), r.strokes.len);
    // gap (0.127 clearance + 0.1 margin) + fence via 0.4 + zero mask margin,
    // each side of the 0.2 trace ⇒ 0.2 + 2×0.627.
    try testing.expectApproxEqAbs(@as(f64, 1.454), r.strokes[0].widths.opening, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.2), r.strokes[0].widths.copper, 1e-9);

    const layered = [_]optimizer.NetRule{
        .{ .class = .{ .name = "rf" }, .rf = .{ .max_freq_hz = 12e9, .fence = .{ .declared = true, .rows = .{ .generated = 2 } } } },
        .{},
    };
    placement.rules.net = &layered;
    const lr = try compute(arena, placement, .{ .tracks = &tracks });
    const pitch = via_fence.guidedWavelengthMm(12e9) / via_fence.pitch_wavelength_divisor;
    const layered_opening = 0.2 + 2 * (0.227 + 0.4 + pitch);
    try testing.expectApproxEqAbs(layered_opening, lr.strokes[0].widths.opening, 1e-9);

    const selective = [_]optimizer.NetRule{
        .{ .class = .{ .name = "rf" }, .rf = .{ .max_freq_hz = 12e9, .fence = .{ .declared = true, .rows = .{ .generated = 2, .mask_open = 1 } } } },
        .{},
    };
    placement.rules.net = &selective;
    const sr = try compute(arena, placement, .{ .tracks = &tracks });
    try testing.expectApproxEqAbs(@as(f64, 1.454), sr.strokes[0].widths.opening, 1e-9);

    // A max-freq class WITHOUT a (fence) widens identically: it is a fence
    // target, so the fence the Fence action will generate needs the same
    // annular-ring exposure a declared one does.
    const undeclared = [_]optimizer.NetRule{
        .{ .class = .{ .name = "rf" }, .rf = .{ .max_freq_hz = 12e9 } },
        .{},
    };
    placement.rules.net = &undeclared;
    const ur = try compute(arena, placement, .{ .tracks = &tracks });
    try testing.expectApproxEqAbs(@as(f64, 1.454), ur.strokes[0].widths.opening, 1e-9);

    // An authored (mask-relief MM) still wins over the derived band either way.
    const authored = [_]optimizer.NetRule{
        .{ .class = .{ .name = "rf" }, .rf = .{ .max_freq_hz = 12e9, .mask_relief_mm = 0.5 } },
        .{},
    };
    placement.rules.net = &authored;
    const ar = try compute(arena, placement, .{ .tracks = &tracks });
    try testing.expectApproxEqAbs(@as(f64, 1.2), ar.strokes[0].widths.opening, 1e-9);
}

// spec: placement/mask-relief - an exposed run shorter than one millimetre stays tented
test "short exposed run between two pads keeps its mask" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Two pads 1.6 mm apart: their dams (pad half 0.25 + zero margin + web
    // 0.1 each) leave a 0.9 mm sliver between them — under the 1 mm floor,
    // so nothing opens.
    const pads = [_]geometry.Pad{
        .{ .number = "1", .x = -0.8, .y = 0, .w = 0.5, .h = 0.5 },
        .{ .number = "2", .x = 0.8, .y = 0, .w = 0.5, .h = 0.5 },
    };
    var parts = [_]optimizer.Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 1.5, .hh = 0.5, .pads = &pads, .fallback = false, .x = 5, .y = 5 },
    };
    const rules = [_]optimizer.NetRule{
        .{ .class = .{ .name = "rf" }, .rf = .{ .max_freq_hz = 12e9 } },
        .{},
    };
    const placement = testPlacement(&parts, &two_nets, &rules);
    const tracks = [_]router.Track{.{ .x1 = 4.2, .y1 = 5, .x2 = 5.8, .y2 = 5, .layer = 0, .width = 0.2, .net = 0 }};
    const r = try compute(arena, placement, .{ .tracks = &tracks });
    try testing.expectEqual(@as(usize, 0), r.strokes.len);
}

// spec: placement/mask-relief - a pad beside an exposed RF trace does not interrupt the trace relief centreline
test "nearby pad leaves the RF relief continuous" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // The trace centreline clears this GND land by 0.35 mm. Its 0.8 mm mask
    // opening overlaps the land's local mask island, but that island belongs
    // in the mask composition pass and must not split the RF opening itself.
    const pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.5, .h = 0.5 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "C101", .kind = .passive, .hw = 0.25, .hh = 0.25, .pads = &pads, .fallback = false, .x = 5, .y = 0.6 },
    };
    const rules = [_]optimizer.NetRule{
        .{ .class = .{ .name = "rf" }, .rf = .{ .max_freq_hz = 12e9, .mask_relief_mm = 0.3 } },
        .{},
    };
    const placement = testPlacement(&parts, &two_nets, &rules);
    const tracks = [_]router.Track{.{ .x1 = 2, .y1 = 0, .x2 = 8, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 }};
    const relief = try compute(arena, placement, .{ .tracks = &tracks });

    try testing.expectEqual(@as(usize, 1), relief.strokes.len);
    try testing.expectEqual(@as(usize, 1), relief.openings.len);
    try testing.expectApproxEqAbs(@as(f64, 2), relief.strokes[0].x1, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 8), relief.strokes[0].x2, 1e-9);
}

// spec: placement/mask-relief - a rotated land's dam follows its outline, so relief runs up to the pad and not to its bounding box
test "a 45-degree land dams only its own copper" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // A 3 × 0.4 mm land on a part turned 45°, fed along the world x axis. Its
    // bounding box is 2.404 mm square, so the box dam reached 1.452 mm back
    // from the pad centre; the copper the trace actually approaches is 0.636 mm
    // away at the margin + web standoff. That 0.8 mm is bare band the launch
    // was losing purely to its pose.
    const pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 3.0, .h = 0.4 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "J1", .kind = .hub, .hw = 2, .hh = 2, .pads = &pads, .fallback = false, .x = 10, .y = 5, .rot = 45 },
    };
    const rules = [_]optimizer.NetRule{
        .{ .class = .{ .name = "rf" }, .rf = .{ .max_freq_hz = 12e9 } },
        .{},
    };
    const placement = testPlacement(&parts, &two_nets, &rules);
    const tracks = [_]router.Track{.{ .x1 = 5, .y1 = 5, .x2 = 10, .y2 = 5, .layer = 0, .width = 0.2, .net = 0 }};
    const r = try compute(arena, placement, .{ .tracks = &tracks });

    try testing.expectEqual(@as(usize, 1), r.strokes.len);
    const s = r.strokes[0];
    const reach = @max(s.x1, s.x2);
    // Sampling quantizes the boundary to 0.05 mm, so allow one pitch.
    // The standoff is met where the diagonal edge is (h/2 + margin + web) away.
    try testing.expectApproxEqAbs(@as(f64, 10) - 0.35 / @cos(std.math.pi / 4.0), reach, sample_mm + 1e-9);
    // Well past where the bounding box would have stopped it.
    try testing.expect(reach > 10 - 1.4);
    // And it is still a pad-dam terminal, so it keeps its authored fillet.
    try testing.expect(s.terminal.trim_end);
}

// spec: placement/mask-relief - exposure runs merge across segment joints before the length test
test "runs merge across a joint to clear the length floor" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const rules = [_]optimizer.NetRule{
        .{ .class = .{ .name = "rf" }, .rf = .{ .max_freq_hz = 12e9 } },
        .{},
    };
    const placement = testPlacement(&.{}, &two_nets, &rules);
    // Two 0.7 mm segments joined at a corner: each alone is under the 1 mm
    // floor, together they are one 1.4 mm run and both open.
    const tracks = [_]router.Track{
        .{ .x1 = 5, .y1 = 5, .x2 = 5.7, .y2 = 5, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 5.7, .y1 = 5, .x2 = 5.7, .y2 = 5.7, .layer = 0, .width = 0.2, .net = 0 },
    };
    const r = try compute(arena, placement, .{ .tracks = &tracks });
    try testing.expectEqual(@as(usize, 2), r.strokes.len);

    // The same two segments pulled apart are two 0.7 mm islands — both tented.
    const apart = [_]router.Track{
        .{ .x1 = 5, .y1 = 5, .x2 = 5.7, .y2 = 5, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 8, .y1 = 5, .x2 = 8, .y2 = 5.7, .layer = 0, .width = 0.2, .net = 0 },
    };
    const r2 = try compute(arena, placement, .{ .tracks = &apart });
    try testing.expectEqual(@as(usize, 0), r2.strokes.len);
}

// spec: placement/mask-relief - mask relief contains no per-via state; via exposure is solely polygon overlap with copper
test "mask relief has no via-specific state" {
    try testing.expect(!@hasField(Copper, "vias"));
    try testing.expect(!@hasField(Relief, "vias"));
}

// spec: placement/mask-relief - an exposed RF trace-to-via transition opens its solved antipad plus the trace pullback only on the connected face
test "RF transition appends an antipad-sized opening polygon" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const rules = [_]optimizer.NetRule{
        .{ .class = .{ .name = "rf" }, .rf = .{
            .max_freq_hz = 12e9,
            .mask_relief_mm = 0.1,
            .impedance = .{ .ohms = 50 },
        } },
        .{},
    };
    var placement = testPlacement(&.{}, &two_nets, &rules);
    placement.rules.physical.stack = .{ .layers = 4, .board_mm = 1.6 };
    const tracks = [_]router.Track{.{ .x1 = 2, .y1 = 5, .x2 = 8, .y2 = 5, .layer = 0, .width = 0.2, .net = 0 }};
    const vias = [_]router.Via{
        .{ .x = 8, .y = 5, .dia = 0.4, .drill = 0.2, .net = 0 }, // trace transition
        .{ .x = 12, .y = 5, .dia = 0.4, .drill = 0.2, .net = 0 }, // unrelated RF via
    };
    const relief = try computeRouted(arena, placement, .{ .tracks = &tracks }, &vias);

    // One trace-run polygon plus one circular transition polygon. The unrelated
    // RF via creates nothing, and no polygon is emitted on the unconnected back.
    try testing.expectEqual(@as(usize, 2), relief.openings.len);
    try testing.expectEqual(@as(u8, 0), relief.openings[1].layer);
    for (relief.openings) |opening| try testing.expectEqual(@as(u8, 0), opening.layer);

    const solved = via_antipad.solve(placement.rules.physical.stack, 50, 0.4, 0.2, placement.rules.design.clearance).?;
    const expected_radius = solved.antipad_dia_mm / 2 + 0.1;
    try testing.expectApproxEqAbs(expected_radius, maxRadius(relief.openings[1].poly, 8, 5), 1e-9);
}

// spec: placement/mask-relief - a bend between two exposed runs emits a rounding disc at the shared vertex
test "bend emits a rounding joint disc" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const rules = [_]optimizer.NetRule{ .{ .class = .{ .name = "rf" }, .rf = .{ .max_freq_hz = 12e9 } }, .{} };
    const placement = testPlacement(&.{}, &two_nets, &rules);
    const tracks = [_]router.Track{
        .{ .x1 = 2, .y1 = 5, .x2 = 4, .y2 = 5, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 4, .y1 = 5, .x2 = 4, .y2 = 7, .layer = 0, .width = 0.2, .net = 0 },
    };
    const r = try compute(arena, placement, .{ .tracks = &tracks });
    try testing.expectEqual(@as(usize, 2), r.strokes.len);
    try testing.expectEqual(@as(usize, 1), r.joints.len);
    try testing.expectApproxEqAbs(@as(f64, 4), r.joints[0].x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 5), r.joints[0].y, 1e-9);
    try testing.expectEqual(@as(u8, 0), r.joints[0].layer);
    // dia = max width + 2×relief; the class is a max-freq fence target, so the
    // band is the fence row's (gap 0.227 + via 0.4 + zero mask margin) and the
    // bend disc rounds that wider corner: 0.2 + 2×0.627.
    try testing.expectApproxEqAbs(@as(f64, 1.454), r.joints[0].dia, 1e-9);

    // A collinear continuation (two straight segments joined) emits no disc —
    // there is no corner to round, and the joint is already covered.
    const straight = [_]router.Track{
        .{ .x1 = 2, .y1 = 5, .x2 = 4, .y2 = 5, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 4, .y1 = 5, .x2 = 6, .y2 = 5, .layer = 0, .width = 0.2, .net = 0 },
    };
    const rs = try compute(arena, placement, .{ .tracks = &straight });
    try testing.expectEqual(@as(usize, 2), rs.strokes.len);
    try testing.expectEqual(@as(usize, 0), rs.joints.len);
}

// spec: placement/mask-relief - a continuous exposure run emits one closed offset polygon whose actual boundary vertices receive the editable corner radius
test "continuous run emits one filleted opening polygon" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const rules = [_]optimizer.NetRule{
        .{ .class = .{ .name = "rf" }, .rf = .{ .mask_relief_mm = 0.3 } },
        .{},
    };
    var placement = testPlacement(&.{}, &two_nets, &rules);
    placement.rules.design.mask.relief_corner_radius = 0.2;
    const tracks = [_]router.Track{
        .{ .x1 = 2, .y1 = 5, .x2 = 5, .y2 = 5, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 5, .y1 = 5, .x2 = 5, .y2 = 8, .layer = 0, .width = 0.2, .net = 0 },
    };
    const relief = try compute(arena, placement, .{ .tracks = &tracks });
    try testing.expectEqual(@as(usize, 1), relief.openings.len);
    try testing.expect(relief.openings[0].poly.len > 6);
    try testing.expect(relief.openings[0].arcs.len >= 4);
    try testing.expect(!outline.selfIntersects(relief.openings[0].poly));
}

// spec: placement/mask-relief - a solver-authored variable-width pad taper stays fully tented while its uniform trace run opens from one exact, non-rasterized boundary
test "sampled pad taper stays tented before the uniform RF trace" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const rules = [_]optimizer.NetRule{
        .{ .class = .{ .name = "rf" }, .rf = .{ .mask_relief_mm = 0.2 } },
        .{},
    };
    const placement = testPlacement(&.{}, &two_nets, &rules);
    const tracks = [_]router.Track{.{ .x1 = 2, .y1 = 5, .x2 = 8, .y2 = 5, .layer = 0, .width = 0.2, .net = 0 }};
    const samples = [_]RfSample{
        .{ .at = .{ 2, 5 }, .s_mm = 0, .curvature = 0, .width_mm = 1.2 },
        .{ .at = .{ 5, 5 }, .s_mm = 3, .curvature = 0, .width_mm = 0.2 },
        .{ .at = .{ 8, 5 }, .s_mm = 6, .curvature = 0, .width_mm = 0.2 },
    };
    const paths = [_]rf_port_report.Outcome{.{
        .net = 0,
        .chosen = 0,
        .feasible = true,
        .success = true,
        .metrics = .{},
        .trials = &.{},
        .physical = .{ .sample_count = samples.len, .samples = &samples, .layer = 0 },
    }};
    const relief = try compute(arena, placement, .{ .tracks = &tracks, .rf_paths = &paths });

    try testing.expectEqual(@as(usize, 1), relief.strokes.len);
    try testing.expectEqual(@as(usize, 1), relief.openings.len);
    try testing.expectApproxEqAbs(@as(f64, 5), relief.strokes[0].x1, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 8), relief.strokes[0].x2, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.2), relief.strokes[0].widths.copper, 1e-9);
    try testing.expect(relief.strokes[0].terminal.trim_start);
    try testing.expect(!relief.strokes[0].terminal.trim_end);
    for (relief.openings[0].poly) |point| try testing.expect(point[0] >= 5 - 1e-9);
}

// spec: placement/mask-relief - a pad-dam termination uses the authored mask-relief corner radius without weakening the mask web
test "pad-dam termination emits an inward corner fillet" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 1.0, .h = 0.5 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &pads, .fallback = false, .x = 8, .y = 5 },
    };
    const rules = [_]optimizer.NetRule{ .{ .class = .{ .name = "rf" }, .rf = .{ .max_freq_hz = 12e9 } }, .{} };
    var placement = testPlacement(&parts, &two_nets, &rules);
    placement.rules.design.mask.relief_corner_radius = 0.2;
    const tracks = [_]router.Track{.{ .x1 = 2, .y1 = 5, .x2 = 8, .y2 = 5, .layer = 0, .width = 0.2, .net = 0 }};
    const relief = try compute(arena, placement, .{ .tracks = &tracks });
    try testing.expectEqual(@as(usize, 1), relief.strokes.len);
    const stroke = relief.strokes[0];
    try testing.expect(!stroke.terminal.trim_start);
    try testing.expect(stroke.terminal.trim_end);
    try testing.expectApproxEqAbs(@as(f64, 0.2), stroke.terminal.radius, 1e-9);

    const poly = try openingPoly(arena, stroke);
    var max_x = -std.math.inf(f64);
    var max_end_dy: f64 = 0;
    for (poly) |point| {
        max_x = @max(max_x, point[0]);
        if (@abs(point[0] - stroke.x2) < 1e-9) max_end_dy = @max(max_end_dy, @abs(point[1] - stroke.y2));
    }
    const half = stroke.widths.opening / 2;
    // The filleted cap stays entirely on the trace side of the pad dam, and
    // reaches the boundary only between the two inward 0.2 mm corner arcs.
    try testing.expectApproxEqAbs(stroke.x2, max_x, 1e-9);
    try testing.expectApproxEqAbs(half - 0.2, max_end_dy, 1e-9);
}

// spec: placement/mask-relief - a pad-dam terminal keeps its authored fillet when the dam boundary lands between short route chords
// spec: placement/mask-relief - overlapping round caps from short route chords are replaced by one authored-radius terminal fillet
test "pad-dam terminal survives a short route chord boundary" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 1.0, .h = 0.5 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &pads, .fallback = false, .x = 10, .y = 5 },
    };
    const rules = [_]optimizer.NetRule{ .{ .class = .{ .name = "rf" }, .rf = .{ .max_freq_hz = 12e9 } }, .{} };
    var placement = testPlacement(&parts, &two_nets, &rules);
    placement.rules.design.mask.relief_corner_radius = 0.4;
    // The pad dam begins at x=9.4. The short first chord ends at x=9.36,
    // producing only a zero-length exposed sample; the next, 0.064 mm chord
    // starts fully exposed at local t=0 and must still carry a 0.4 mm fillet.
    const tracks = [_]router.Track{
        .{ .x1 = 10, .y1 = 5, .x2 = 9.36, .y2 = 5, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 9.36, .y1 = 5, .x2 = 9.296, .y2 = 5, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 9.296, .y1 = 5, .x2 = 2, .y2 = 5, .layer = 0, .width = 0.2, .net = 0 },
    };
    const relief = try compute(arena, placement, .{ .tracks = &tracks });
    try testing.expectEqual(@as(usize, 2), relief.strokes.len);
    try testing.expect(relief.strokes[0].terminal.trim_start);
    try testing.expect(!relief.strokes[0].terminal.trim_end);
    try testing.expectApproxEqAbs(@as(f64, 0.4), relief.strokes[0].terminal.radius, 1e-9);
    const finish = (try terminalFinish(arena, relief.strokes[0], true)).?;
    try testing.expectEqual(@as(usize, 15), finish.patch.len);
    // The patch reaches the authored 0.4 mm into the exposed trace even
    // though its carrier chord is only 0.064 mm long.
    try testing.expectApproxEqAbs(@as(f64, 0.4), relief.strokes[0].x1 - finish.patch[0][0], 1e-9);
}

// spec: placement/mask-relief - an authored mask-relief overrides the fenced default and zero keeps the net tented
test "authored pullback overrides the fence-derived default" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const authored = [_]optimizer.NetRule{
        .{ .class = .{ .name = "rf" }, .rf = .{ .max_freq_hz = 12e9, .fence = .{ .declared = true }, .mask_relief_mm = 0.1 } },
        .{},
    };
    var placement = testPlacement(&.{}, &two_nets, &authored);
    const tracks = [_]router.Track{.{ .x1 = 2, .y1 = 5, .x2 = 8, .y2 = 5, .layer = 0, .width = 0.2, .net = 0 }};
    const r = try compute(arena, placement, .{ .tracks = &tracks });
    try testing.expectApproxEqAbs(@as(f64, 0.4), r.strokes[0].widths.opening, 1e-9);

    const zeroed = [_]optimizer.NetRule{
        .{ .class = .{ .name = "rf" }, .rf = .{ .max_freq_hz = 12e9, .fence = .{ .declared = true }, .mask_relief_mm = 0 } },
        .{},
    };
    placement.rules.net = &zeroed;
    const rz = try compute(arena, placement, .{ .tracks = &tracks });
    try testing.expectEqual(@as(usize, 0), rz.strokes.len);
}
