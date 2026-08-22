//! The `keepout_violation` post-route check: foreign copper inside an RF net's
//! declared `(net-class … (keepout MM))` halo. Factored out of `drc.zig` (at its
//! guardian file-size cap) following `drc_diffpair.zig`'s precedent, and called
//! from `drc.check` so it reaches BOTH the server and the client WASM engine.
//!
//! WARNING severity, deliberately. The halo is a signal-integrity preference,
//! not a fab rule: a board that ships with a control track 0.4 mm from an RF
//! trace is manufacturable, just noisier than the author asked for. Error
//! severity is what `drc.errorCount` gates on — `add_tracks`,
//! `close_open_nets` and the fence ratchet all refuse to write when it climbs —
//! so making this an error would block hand routing on advisory findings. Escalate
//! it per design from the viewer's DRC policy drawer when a board wants it hard.
//!
//! The rule (see `keepout.zig` for the shared predicates):
//!
//!   • A keepout net's own TRACKS, VIAS, and component PADS are guarded copper.
//!     Only foreign TRACKS and VIAS offend; foreign pads remain placement-owned.
//!   • Same layer only. A track on the far side crossing under an RF trace is
//!     legal; a through via's barrel is on every layer, so it always owes the
//!     halo — measured from EITHER side (a foreign via near RF copper on any
//!     layer, and foreign copper on any layer near an RF net's own via).
//!   • Ground/plane copper is exempt (`keepout.exempt`) — the fence is wanted.
//!   • Copper of the SAME `(net-class …)` is exempt (`keepout.sameClass`): a
//!     class's members are one signal family and run adjacent by design, so the
//!     halo they share is not one they owe each other. Their spacing is the
//!     class's own clearance, untouched here.
//!   • Within `keepout_escape_mm` of one of the keepout net's own pad terminals
//!     the halo is suspended for the nets that exemption is FOR — a net owning a
//!     pad in the same zone, i.e. the neighbour pin leaving the same IC
//!     (`keepout.escapeAdmits`). A net merely passing through is still flagged;
//!     ungated, the overlapping zones around two RF pads of one filter read as an
//!     open corridor straight between them.
//!
//! Out of scope, deliberately: POUR/zone copper. Only tracks and vias are
//! measured, so a foreign filled zone crowding an RF trace is not reported here.
//! On every board seen so far the pours are ground or plane rails, which the
//! exemption would clear anyway; a signal pour beside RF copper would need the
//! zone geometry threaded in, which is a follow-up rather than a silent gap.
//!
//! Granularity: ONE violation per (offending copper item, keepout net) pair, at
//! its worst gap. A track running parallel to an RF trace is one finding rather
//! than a finding per segment pair, which is what keeps the count readable as
//! "how many pieces of foreign copper intrude" instead of an O(segments²) wash.

const std = @import("std");
const optimizer = @import("optimizer.zig");
const router = @import("router.zig");
const drc = @import("drc.zig");
const keepout = @import("keepout.zig");
const pad_shape = @import("pad_shape.zig");

/// Exact pad copper + the terminal centre read by the escape gate. `drc.check`
/// projects its already-joined `PadBox` list into this, so the pad→net join is
/// not repeated here.
const PadPt = keepout.PadPt;

/// Tolerance shared with the rest of the DRC: a gap equal to the rule passes.
const eps: f64 = 1e-6;

const GuardCopper = struct {
    tracks: []const u32,
    vias: []const u32,
    pads: []const u32,
};

/// One keepout net and everything the check needs about it: the halo/escape it
/// declared, the indices of its own copper, its pad terminals, and the bounding
/// box of that copper already inflated by the halo (the cheap first reject).
const Guard = struct {
    net: i32,
    halo: f64,
    escape: f64,
    copper: GuardCopper,
    terminals: []const [2]f64,
    box: [4]f64,
};

/// The closest approach between a foreign feature and a guard's copper: the
/// edge-to-edge gap and the midpoint of the approach (where the marker lands).
const Approach = struct { gap: f64 = std.math.inf(f64), x: f64 = 0, y: f64 = 0 };

/// Append every keepout violation to `out`. A no-op when no net declares a
/// keepout, so the DRC output is byte-identical for boards without one.
pub fn check(
    arena: std.mem.Allocator,
    out: *std.ArrayList(drc.Violation),
    placement: optimizer.Placement,
    tracks: []const router.Track,
    vias: []const router.Via,
    pads: []const PadPt,
) std.mem.Allocator.Error!void {
    if (!keepout.anyDeclared(placement)) return;
    const guards = try collectGuards(arena, placement, tracks, vias, pads);
    if (guards.len == 0) return;
    const classes = try keepout.classIds(arena, placement);
    for (tracks) |t| {
        if (exemptCopper(placement, t.net)) continue;
        for (guards) |g| {
            if (t.net == g.net or keepout.sameClass(classes, t.net, g.net)) continue;
            if (boxMisses(g.box, trackBox(t))) continue;
            try appendWorst(arena, out, g, trackApproach(g, tracks, vias, pads, t), t.net, pads);
        }
    }
    for (vias) |v| {
        if (exemptCopper(placement, v.net)) continue;
        for (guards) |g| {
            if (v.net == g.net or keepout.sameClass(classes, v.net, g.net)) continue;
            if (boxMisses(g.box, viaBox(v))) continue;
            try appendWorst(arena, out, g, viaApproach(g, tracks, vias, pads, v), v.net, pads);
        }
    }
}

/// Is copper on net id `net` exempt from every halo? The no-net (-1) sentinel is
/// NOT exempt: unnetted copper can never be a guard, so it is judged as an
/// ordinary aggressor.
fn exemptCopper(placement: optimizer.Placement, net: i32) bool {
    if (net < 0) return false;
    return keepout.exempt(placement, @intCast(net));
}

/// The keepout nets with copper on the board, each with its own copper indexed
/// and its pad terminals gathered.
fn collectGuards(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    tracks: []const router.Track,
    vias: []const router.Via,
    pads: []const PadPt,
) std.mem.Allocator.Error![]const Guard {
    var list: std.ArrayList(Guard) = .empty;
    for (placement.rules.net, 0..) |rule, ni| {
        const halo = rule.rf.keepout_mm;
        if (!(halo > 0)) continue;
        const net: i32 = @intCast(ni);
        var t_idx: std.ArrayList(u32) = .empty;
        var v_idx: std.ArrayList(u32) = .empty;
        var p_idx: std.ArrayList(u32) = .empty;
        var box = [4]f64{ std.math.inf(f64), std.math.inf(f64), -std.math.inf(f64), -std.math.inf(f64) };
        for (tracks, 0..) |t, i| {
            if (t.net != net) continue;
            try t_idx.append(arena, @intCast(i));
            growBox(&box, trackBox(t));
        }
        for (vias, 0..) |v, i| {
            if (v.net != net) continue;
            try v_idx.append(arena, @intCast(i));
            growBox(&box, viaBox(v));
        }
        for (pads, 0..) |p, i| {
            if (p.net != net or p.guard == null) continue;
            try p_idx.append(arena, @intCast(i));
            growBox(&box, padBox(p));
        }
        if (t_idx.items.len == 0 and v_idx.items.len == 0 and p_idx.items.len == 0) continue; // no copper to guard
        var terminals: std.ArrayList([2]f64) = .empty;
        for (pads) |p| {
            if (p.net == net) try terminals.append(arena, .{ p.x, p.y });
        }
        try list.append(arena, .{
            .net = net,
            .halo = halo,
            .escape = rule.rf.keepout_escape_mm,
            .copper = .{ .tracks = t_idx.items, .vias = v_idx.items, .pads = p_idx.items },
            .terminals = terminals.items,
            .box = .{ box[0] - halo, box[1] - halo, box[2] + halo, box[3] + halo },
        });
    }
    return list.toOwnedSlice(arena);
}

/// Worst approach of foreign track `t` to guard `g`'s copper: its own layer
/// against the guard's same-layer tracks, and every layer against the guard's
/// vias (a barrel is on all of them).
fn trackApproach(g: Guard, tracks: []const router.Track, vias: []const router.Via, pads: []const PadPt, t: router.Track) Approach {
    var best = Approach{};
    for (g.copper.tracks) |i| {
        const k = tracks[i];
        if (k.layer != t.layer) continue;
        const d = pad_shape.segSegDist(.{ t.x1, t.y1 }, .{ t.x2, t.y2 }, .{ k.x1, k.y1 }, .{ k.x2, k.y2 });
        take(&best, d - t.width / 2 - k.width / 2, segSegMid(t, k));
    }
    for (g.copper.vias) |i| {
        const v = vias[i];
        const d = pad_shape.segPointDist(t.x1, t.y1, t.x2, t.y2, v.x, v.y);
        take(&best, d - t.width / 2 - v.dia / 2, nearestOnSeg(t, v.x, v.y));
    }
    for (g.copper.pads) |i| {
        const p = pads[i];
        const s = p.guard.?;
        if (!s.thru and s.layer != t.layer) continue;
        const shape = pad_shape.Shape{ .x0 = s.bounds[0], .y0 = s.bounds[1], .x1 = s.bounds[2], .y1 = s.bounds[3], .poly = s.poly };
        const d = pad_shape.segmentDist(shape, .{ t.x1, t.y1 }, .{ t.x2, t.y2 }, g.halo + t.width / 2);
        take(&best, d - t.width / 2, nearestOnSeg(t, p.x, p.y));
    }
    return best;
}

/// Worst approach of foreign via `v` to guard `g`'s copper. The barrel spans
/// every layer, so the guard's tracks are measured whatever layer they are on.
fn viaApproach(g: Guard, tracks: []const router.Track, vias: []const router.Via, pads: []const PadPt, v: router.Via) Approach {
    var best = Approach{};
    for (g.copper.tracks) |i| {
        const k = tracks[i];
        const d = pad_shape.segPointDist(k.x1, k.y1, k.x2, k.y2, v.x, v.y);
        take(&best, d - v.dia / 2 - k.width / 2, nearestOnSeg(k, v.x, v.y));
    }
    for (g.copper.vias) |i| {
        const k = vias[i];
        const d = std.math.hypot(v.x - k.x, v.y - k.y);
        take(&best, d - v.dia / 2 - k.dia / 2, .{ (v.x + k.x) / 2, (v.y + k.y) / 2 });
    }
    for (g.copper.pads) |i| {
        const p = pads[i];
        const s = p.guard.?;
        const d = pad_shape.pointDist(s.bounds[0], s.bounds[1], s.bounds[2], s.bounds[3], s.poly, v.x, v.y, g.halo + v.dia / 2);
        take(&best, d - v.dia / 2, .{ v.x, v.y });
    }
    return best;
}

/// Keep `cand` when it is the closest approach seen so far.
fn take(best: *Approach, gap: f64, at: [2]f64) void {
    if (gap >= best.gap) return;
    best.* = .{ .gap = gap, .x = at[0], .y = at[1] };
}

/// Emit the finding for one (foreign feature, guard) pair when the approach
/// breaks the halo and the NET-GATED escape exemption does not cover it: the
/// offender is excused only inside an escape zone it owns a pad in, so the
/// exemption reaches the neighbour pin it was carved out for and nobody else.
fn appendWorst(
    arena: std.mem.Allocator,
    out: *std.ArrayList(drc.Violation),
    g: Guard,
    a: Approach,
    offender: i32,
    pads: []const PadPt,
) std.mem.Allocator.Error!void {
    if (!(a.gap < g.halo - eps)) return;
    if (keepout.escapeAdmits(pads, g.terminals, g.escape, a.x, a.y, offender)) return;
    try out.append(arena, .{
        .x = a.x,
        .y = a.y,
        .gap = a.gap,
        .clearance = g.halo,
        .kind = .keepout_violation,
        .severity = drc.defaultSeverity(.keepout_violation),
        .who = .{ .net_a = g.net, .net_b = offender },
    });
}

// ── Geometry helpers ────────────────────────────────────────────────────────

/// Midpoint of the closest approach between two track centrelines, in the
/// `pad_shape` form the ROUTER's own probe asks the escape gate at — one
/// implementation, so a finding here and a refusal there name the same point.
fn segSegMid(a: router.Track, b: router.Track) [2]f64 {
    return pad_shape.segSegMid(.{ a.x1, a.y1 }, .{ a.x2, a.y2 }, .{ b.x1, b.y1 }, .{ b.x2, b.y2 });
}

/// The point on track `t`'s centreline closest to (x, y).
fn nearestOnSeg(t: router.Track, x: f64, y: f64) [2]f64 {
    const dx = t.x2 - t.x1;
    const dy = t.y2 - t.y1;
    const len2 = dx * dx + dy * dy;
    if (len2 < eps) return .{ t.x1, t.y1 };
    const u = std.math.clamp(((x - t.x1) * dx + (y - t.y1) * dy) / len2, 0, 1);
    return .{ t.x1 + u * dx, t.y1 + u * dy };
}

fn trackBox(t: router.Track) [4]f64 {
    const hw = t.width / 2;
    return .{ @min(t.x1, t.x2) - hw, @min(t.y1, t.y2) - hw, @max(t.x1, t.x2) + hw, @max(t.y1, t.y2) + hw };
}

fn viaBox(v: router.Via) [4]f64 {
    const r = v.dia / 2;
    return .{ v.x - r, v.y - r, v.x + r, v.y + r };
}

fn padBox(p: PadPt) [4]f64 {
    return p.guard.?.bounds;
}

fn growBox(box: *[4]f64, b: [4]f64) void {
    box[0] = @min(box[0], b[0]);
    box[1] = @min(box[1], b[1]);
    box[2] = @max(box[2], b[2]);
    box[3] = @max(box[3], b[3]);
}

/// Do two AABBs fail to overlap? The guard box arrives pre-inflated by its halo,
/// so a miss proves the pair beyond the rule — the O(guards × copper) scan below
/// only ever measures candidates this survives.
fn boxMisses(a: [4]f64, b: [4]f64) bool {
    return a[2] < b[0] or b[2] < a[0] or a[3] < b[1] or b[3] < a[1];
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Net indices the fixtures below use: 0 = the keepout (RF) net, 1 = a foreign
/// signal net, 2 = ground.
const rf_net: i32 = 0;
const sig_net: i32 = 1;
const gnd_net: i32 = 2;

/// Owns the arrays a fixture `Placement` borrows, so `placement()` can hand out
/// a value whose `rules.net` slice outlives the call (a `&[_]…{}` temporary built
/// from runtime arguments would not).
const Fx = struct {
    rules: [3]optimizer.NetRule,
    pads: [2]PadPt,

    fn placement(self: *const Fx) optimizer.Placement {
        return .{
            .parts = &.{},
            .links = &.{},
            .loops = &.{},
            .stubs = &.{},
            .instances = &.{},
            .nets = &fixture_nets,
            .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
            .minx = 0,
            .miny = 0,
            .maxx = 30,
            .maxy = 30,
            .generated = true,
            .rules = .{ .net = &self.rules },
        };
    }
};

/// A three-net placement (RF / signal / GND) whose RF class declares
/// `(keepout halo (escape escape))`, plus one RF pad terminal at `pad` and a
/// SIG pad right beside it — the neighbour pin leaving the same footprint, which
/// is what the net-gated escape exemption is there to let out.
fn fixture(halo: f64, escape: f64, pad: [2]f64) Fx {
    return .{
        .rules = .{
            .{ .rf = .{ .keepout_mm = halo, .keepout_escape_mm = escape } },
            .{},
            .{},
        },
        .pads = .{
            .{ .net = rf_net, .x = pad[0], .y = pad[1] },
            .{ .net = sig_net, .x = pad[0] + 0.5, .y = pad[1] + 0.4 },
        },
    };
}

const fixture_nets = [_]optimizer.FlatNet{
    .{ .name = "RF_IN", .pins = &.{} },
    .{ .name = "SPI_SCK", .pins = &.{} },
    .{ .name = "GND", .pins = &.{} },
};

/// An RF trace along y=10 from x=5 to x=15 on `layer`.
fn rfTrack(layer: u8) router.Track {
    return .{ .x1 = 5, .y1 = 10, .x2 = 15, .y2 = 10, .layer = layer, .width = 0.2, .net = rf_net };
}

/// A parallel track on `net`, `dy` mm from the RF trace, on `layer`.
fn parallel(net: i32, dy: f64, layer: u8) router.Track {
    return .{ .x1 = 5, .y1 = 10 + dy, .x2 = 15, .y2 = 10 + dy, .layer = layer, .width = 0.2, .net = net };
}

/// Run the check alone over one fixture (no full `drc.check`, so only keepout
/// findings come back).
fn run(
    arena: std.mem.Allocator,
    halo: f64,
    escape: f64,
    tracks: []const router.Track,
    vias: []const router.Via,
) ![]const drc.Violation {
    const fx = fixture(halo, escape, .{ 5, 10 });
    var out: std.ArrayList(drc.Violation) = .empty;
    try check(arena, &out, fx.placement(), tracks, vias, &fx.pads);
    return out.items;
}

// spec: placement/drc - flags foreign copper inside an RF net's keepout halo on the same layer and passes a crossing on another layer
test "keepout is same-layer: a top-side neighbour violates, a bottom-side crossing does not" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // 0.4 mm centre-to-centre with two 0.2 mm tracks ⇒ 0.2 mm edge-to-edge,
    // inside the 0.5 mm halo.
    const same = [_]router.Track{ rfTrack(0), parallel(sig_net, 0.4, 0) };
    const hits = try run(arena, 0.5, 0, &same, &.{});
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqual(drc.Kind.keepout_violation, hits[0].kind);
    try testing.expectEqual(drc.Severity.warn, hits[0].severity);
    try testing.expectApproxEqAbs(@as(f64, 0.2), hits[0].gap, 1e-9);
    try testing.expectEqual(@as(f64, 0.5), hits[0].clearance);
    // The keepout net is party A, the intruder party B.
    try testing.expectEqual(rf_net, hits[0].who.net_a);
    try testing.expectEqual(sig_net, hits[0].who.net_b);

    // The SAME geometry on the bottom layer is legal by design — the board is
    // the shield, so a crossing signal underneath owes only clearance.
    const other = [_]router.Track{ rfTrack(0), parallel(sig_net, 0.4, 1) };
    try testing.expectEqual(@as(usize, 0), (try run(arena, 0.5, 0, &other, &.{})).len);
}

// spec: placement/drc - a keepout net's component pad guards its exact copper outline on the SMD face and every layer when through-hole
test "RF component pads carry the same keepout halo as routed copper" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const fx = fixture(0.5, 0, .{ 10, 10 });
    const pads = [_]PadPt{.{
        .net = rf_net,
        .x = 10,
        .y = 10,
        .guard = .{ .bounds = .{ 9.5, 9.5, 10.5, 10.5 }, .layer = 0 },
    }};

    // 0.3 mm edge-to-edge from the top SMD pad: inside its 0.5 mm halo,
    // despite there being no RF track or via in this fixture.
    const top = [_]router.Track{.{ .x1 = 9, .y1 = 10.9, .x2 = 11, .y2 = 10.9, .layer = 0, .width = 0.2, .net = sig_net }};
    var out: std.ArrayList(drc.Violation) = .empty;
    try check(arena, &out, fx.placement(), &top, &.{}, &pads);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectApproxEqAbs(@as(f64, 0.3), out.items[0].gap, 1e-9);

    // The same track on the far face is shielded by the board for an SMD pad.
    var far: std.ArrayList(drc.Violation) = .empty;
    const bottom = [_]router.Track{.{ .x1 = 9, .y1 = 10.9, .x2 = 11, .y2 = 10.9, .layer = 1, .width = 0.2, .net = sig_net }};
    try check(arena, &far, fx.placement(), &bottom, &.{}, &pads);
    try testing.expectEqual(@as(usize, 0), far.items.len);

    // A through pad owns copper on every signal layer and therefore guards the
    // identical bottom-side approach.
    var through_pads = pads;
    through_pads[0].guard.?.thru = true;
    var through: std.ArrayList(drc.Violation) = .empty;
    try check(arena, &through, fx.placement(), &bottom, &.{}, &through_pads);
    try testing.expectEqual(@as(usize, 1), through.items.len);
}

// spec: placement/drc - a foreign via's barrel breaks an RF keepout halo from either layer while foreign pads never offend
test "a foreign via violates the halo whatever layer the RF copper is on" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // A signal via 0.35 mm off an RF trace: 0.35 − 0.1 (track) − 0.2 (via r) =
    // 0.05 mm edge-to-edge.
    const via = [_]router.Via{.{ .x = 10, .y = 10.35, .dia = 0.4, .drill = 0.2, .net = sig_net }};
    const top = [_]router.Track{rfTrack(0)};
    const hit_top = try run(arena, 0.5, 0, &top, &via);
    try testing.expectEqual(@as(usize, 1), hit_top.len);
    try testing.expectApproxEqAbs(@as(f64, 0.05), hit_top[0].gap, 1e-9);

    // The barrel spans every layer, so the RF copper being on the BOTTOM makes
    // no difference — this is the one case where "same layer" still bites.
    const bot = [_]router.Track{rfTrack(1)};
    try testing.expectEqual(@as(usize, 1), (try run(arena, 0.5, 0, &bot, &via)).len);

    // And the reverse pairing: the RF net's own via against a foreign track on
    // the far layer.
    const rf_via = [_]router.Via{.{ .x = 10, .y = 10, .dia = 0.4, .drill = 0.2, .net = rf_net }};
    const far = [_]router.Track{parallel(sig_net, 0.35, 1)};
    try testing.expectEqual(@as(usize, 1), (try run(arena, 0.5, 0, &far, &rf_via)).len);
}

// spec: placement/drc - ground copper is never a keepout aggressor, so a stitching fence via beside an RF trace is clean
test "ground tracks and fence vias inside the halo are exempt" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // A ground via at the fence offset — exactly the copper stage 2 generates.
    const fence = [_]router.Via{.{ .x = 10, .y = 10.583, .dia = 0.4, .drill = 0.2, .net = gnd_net }};
    const rf = [_]router.Track{rfTrack(0)};
    try testing.expectEqual(@as(usize, 0), (try run(arena, 0.5, 0, &rf, &fence)).len);

    // A coplanar ground track hugging the trace is the wanted fence too.
    const coplanar = [_]router.Track{ rfTrack(0), parallel(gnd_net, 0.4, 0) };
    try testing.expectEqual(@as(usize, 0), (try run(arena, 0.5, 0, &coplanar, &.{})).len);
}

// spec: placement/drc - two nets of one net-class never break each other's keepout halo, while a net in a different class still does
test "a class's own members owe each other no keepout halo" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // The filter-chain geometry: two nets of one RF class running 0.2 mm apart
    // edge-to-edge, far inside the 0.5 mm halo they both declare. They must be
    // allowed to — the halo exists to keep OTHER traffic off this pair.
    const tracks = [_]router.Track{ rfTrack(0), parallel(sig_net, 0.4, 0) };
    var same = fixture(0.5, 0, .{ 5, 10 });
    same.rules[0].class = .{ .name = "rf" };
    same.rules[1] = .{ .class = .{ .name = "rf" }, .rf = .{ .keepout_mm = 0.5 } };
    var out: std.ArrayList(drc.Violation) = .empty;
    try check(arena, &out, same.placement(), &tracks, &.{}, &same.pads);
    try testing.expectEqual(@as(usize, 0), out.items.len);

    // Put the neighbour in a DIFFERENT class and the identical copper is flagged
    // from both sides: each class's halo still holds the other one off.
    var apart = same;
    apart.rules[1].class = .{ .name = "clk" };
    var flagged: std.ArrayList(drc.Violation) = .empty;
    try check(arena, &flagged, apart.placement(), &tracks, &.{}, &apart.pads);
    try testing.expectEqual(@as(usize, 2), flagged.items.len);
}

// spec: placement/drc - a plane-carried rail is exempt from a keepout halo even when it is not ground-named
test "a declared plane net is exempt from the keepout halo" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const nets = [_]optimizer.FlatNet{
        .{ .name = "RF_IN", .pins = &.{} },
        .{ .name = "V_3V3", .pins = &.{} },
    };
    const rules = [_]optimizer.NetRule{ .{ .rf = .{ .keepout_mm = 0.5 } }, .{} };
    const planes = [_][]const u8{"V_3V3"};
    var p = optimizer.Placement{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 30,
        .maxy = 30,
        .generated = true,
        .rules = .{ .net = &rules },
    };
    const tracks = [_]router.Track{ rfTrack(0), parallel(1, 0.4, 0) };

    // Not ground-named and no stackup declared: the rail is an ordinary
    // aggressor.
    var out: std.ArrayList(drc.Violation) = .empty;
    try check(arena, &out, p, &tracks, &.{}, &.{});
    try testing.expectEqual(@as(usize, 1), out.items.len);

    // Declaring the plane makes it a reference, so the finding goes away.
    p.rules = .{ .net = &rules, .plane_nets = &planes };
    var poured: std.ArrayList(drc.Violation) = .empty;
    try check(arena, &poured, p, &tracks, &.{}, &.{});
    try testing.expectEqual(@as(usize, 0), poured.items.len);
}

// spec: placement/drc - the keepout escape radius clears a neighbour leaving the same pad as the RF net
test "a neighbour inside the escape radius of an RF pad is not flagged" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // The RF pad terminal sits at (5,10) — the trace's own start. A short
    // neighbour stub right beside it is the IC-breakout case.
    const near_pad = [_]router.Track{
        rfTrack(0),
        .{ .x1 = 5, .y1 = 10.4, .x2 = 5.5, .y2 = 10.4, .layer = 0, .width = 0.2, .net = sig_net },
    };
    // No escape declared: the stub is flagged.
    try testing.expectEqual(@as(usize, 1), (try run(arena, 0.5, 0, &near_pad, &.{})).len);
    // A 1 mm escape covers it — the stub's own net owns a pad in that zone
    // (`run`'s fixture parks a SIG pad beside the RF one).
    try testing.expectEqual(@as(usize, 0), (try run(arena, 0.5, 1.0, &near_pad, &.{})).len);
    // The exemption is local: the same stub 8 mm along the trace is still flagged.
    const far_along = [_]router.Track{
        rfTrack(0),
        .{ .x1 = 13, .y1 = 10.4, .x2 = 13.5, .y2 = 10.4, .layer = 0, .width = 0.2, .net = sig_net },
    };
    try testing.expectEqual(@as(usize, 1), (try run(arena, 0.5, 1.0, &far_along, &.{})).len);
}

// spec: placement/drc - a keepout escape zone excuses only a net with its own pad inside it, so a foreign trace threading between two RF pads is still flagged
test "the escape exemption is net-gated: a passer-by in the zone stays flagged" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // The filter case: TWO RF pads 2 mm apart, their 1.5 mm escape zones
    // overlapping into a corridor straight between them, and a foreign trace
    // running down that corridor 0.4 mm off the RF trace.
    const rf = [_]router.Track{.{ .x1 = 5, .y1 = 10, .x2 = 7, .y2 = 10, .layer = 0, .width = 0.2, .net = rf_net }};
    const thread = [_]router.Track{
        rf[0],
        .{ .x1 = 5.2, .y1 = 10.4, .x2 = 6.8, .y2 = 10.4, .layer = 0, .width = 0.2, .net = sig_net },
    };
    const zone_pads = [_]PadPt{ .{ .net = rf_net, .x = 5, .y = 10 }, .{ .net = rf_net, .x = 7, .y = 10 } };
    const fx = fixture(0.5, 1.5, .{ 5, 10 });
    const p = fx.placement();

    // Ungated this was silent — every cell of the corridor sits inside one of
    // the two zones. Gated, SPI_SCK owns no pad there and is flagged.
    var out: std.ArrayList(drc.Violation) = .empty;
    try check(arena, &out, p, &thread, &.{}, &zone_pads);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqual(sig_net, out.items[0].who.net_b);

    // Give SPI_SCK a pad of its own inside the first zone and the SAME copper is
    // excused: that is the neighbour-pin breakout the exemption is for.
    const with_pad = zone_pads ++ [_]PadPt{.{ .net = sig_net, .x = 5.2, .y = 10.4 }};
    var excused: std.ArrayList(drc.Violation) = .empty;
    try check(arena, &excused, p, &thread, &.{}, &with_pad);
    try testing.expectEqual(@as(usize, 0), excused.items.len);
}

// spec: placement/drc - a pad inside a keepout halo is never an offender and copper outside the halo is silent
test "pads never offend the keepout and copper beyond the halo passes" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // A foreign pad centred 0.15 mm from the RF trace — closer than any track
    // in these tests — produces nothing: placement owns pad positions, and an RF
    // trace legitimately runs between a 0402's lands.
    const fx = fixture(0.5, 0, .{ 5, 10 });
    const tracks = [_]router.Track{rfTrack(0)};
    const pads = [_]PadPt{
        .{ .net = rf_net, .x = 5, .y = 10 },
        .{ .net = sig_net, .x = 10, .y = 10.15 },
    };
    var out: std.ArrayList(drc.Violation) = .empty;
    try check(arena, &out, fx.placement(), &tracks, &.{}, &pads);
    try testing.expectEqual(@as(usize, 0), out.items.len);

    // A neighbour beyond the halo is silent (0.8 − 0.2 = 0.6 mm > 0.5 mm).
    const clear = [_]router.Track{ rfTrack(0), parallel(sig_net, 0.8, 0) };
    try testing.expectEqual(@as(usize, 0), (try run(arena, 0.5, 0, &clear, &.{})).len);

    // And a board that declares no keepout at all is skipped outright.
    const none = [_]optimizer.NetRule{ .{}, .{}, .{} };
    var p = fx.placement();
    p.rules = .{ .net = &none };
    const tight = [_]router.Track{ rfTrack(0), parallel(sig_net, 0.25, 0) };
    var quiet: std.ArrayList(drc.Violation) = .empty;
    try check(arena, &quiet, p, &tight, &.{}, &fx.pads);
    try testing.expectEqual(@as(usize, 0), quiet.items.len);
}

// spec: placement/drc - one keepout finding is reported per offending copper piece rather than per segment pair
test "a multi-segment RF trace yields one finding per offending track" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Three RF segments and one long neighbour: the neighbour is ONE finding, at
    // its worst gap, not one per (segment, neighbour) pair.
    const tracks = [_]router.Track{
        .{ .x1 = 5, .y1 = 10, .x2 = 8, .y2 = 10, .layer = 0, .width = 0.2, .net = rf_net },
        .{ .x1 = 8, .y1 = 10, .x2 = 11, .y2 = 10, .layer = 0, .width = 0.2, .net = rf_net },
        .{ .x1 = 11, .y1 = 10, .x2 = 15, .y2 = 10, .layer = 0, .width = 0.2, .net = rf_net },
        .{ .x1 = 5, .y1 = 10.4, .x2 = 15, .y2 = 10.3, .layer = 0, .width = 0.2, .net = sig_net },
    };
    const hits = try run(arena, 0.5, 0, &tracks, &.{});
    try testing.expectEqual(@as(usize, 1), hits.len);
    // The worst approach is the 0.3 mm end (0.3 − 0.2 = 0.1 mm edge-to-edge).
    try testing.expectApproxEqAbs(@as(f64, 0.1), hits[0].gap, 1e-6);
}
