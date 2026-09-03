//! The CURRENT-CAPACITY half of the track-width rule: how wide a routed power
//! branch has to be for the current it actually carries, and which finding a
//! shortfall becomes. Factored out of `drc.zig` (at its guardian file-size cap)
//! following `drc_diffpair.zig`'s precedent; `drc.checkTrackWidth` calls
//! `duty` once per track and `report` once per pass.
//!
//! ## The tiers, widest-binding first
//!
//! A routed track's required width is the MAXIMUM of what fabrication, the
//! author, and physics each demand:
//!
//!   1. the board `min_width` — fabrication, always;
//!   2. the class's `(power-branch-width MM)` — an authored FLOOR under every
//!      branch of the rail, so a fanout never thins below what the author is
//!      willing to build even where the solved current is tiny;
//!   3. the solved per-track IPC-2221 width for THIS track's own current on
//!      THIS track's own layer.
//!
//! The net class's `(width MM)` is deliberately NOT in that list once a solve
//! exists. A class width is one number for a whole rail — the conservative
//! stand-in for a current analysis nobody had run yet. Charging a solved
//! 0.08 mm branch against a 0.2532 mm trunk width reports copper that is
//! electrically correct as a defect, and the repair it asks for (widen every
//! leaf to the trunk) is the very thing current-aware sizing exists to avoid.
//! So a track with a solve is judged by its solve; the class width stays in
//! force as the ROUTER's target and as the rule for every track without one.
//!
//! ## Solved vs envelope
//!
//! `power_integrity` cannot always divide a rail's current among its branches:
//! a rail with no source terminal, a disconnected load, a singular graph. It
//! still answers, with the WHOLE-RAIL envelope for the track's layer — a safe
//! upper bound on any one branch, and the honest statement of "this much
//! current has to get through here somewhere". The two answers are not the
//! same claim, so they are not the same finding:
//!
//!   • `power_width` — a shortfall against a SOLVED width. This copper cannot
//!     carry the current this track was measured to carry: an ERROR.
//!   • `power_width_envelope` — a shortfall against the envelope. The rail's
//!     total demand does not fit, but nobody has proven THIS branch carries it;
//!     the finding names the solver status that forced the fallback, so the
//!     reader can fix the model (a missing source terminal) instead of widening
//!     copper that may already be right. A WARNING: it must not block
//!     fabrication or hand routing on an unproven number.
//!
//! Both are judged after the pad-entry neck exemption (`pad_neck.judgePowerNeck`)
//! and reported ALL IN ONE PASS, so a repair sees the whole set rather than
//! discovering one shortfall per re-check.

const std = @import("std");
const board_layers = @import("../board_layers.zig");
const drc = @import("drc.zig");
const optimizer = @import("optimizer.zig");
const pad_neck = @import("pad_neck.zig");
const router = @import("router.zig");

/// One routed track's solved current-capacity requirement, as
/// `power_integrity` answers it.
///
/// INTEGRATION NOTE: this mirrors `power_integrity.LocalWidth` field for
/// field. It is declared here rather than imported so this checker can be
/// built and tested against the contract while the solver lands; collapse it
/// to `pub const LocalWidth = power_integrity.LocalWidth;` and delete
/// `promote` below once that type exists.
pub const LocalWidth = struct {
    /// IPC-2221 width for this track's own current on its own layer; 0 when
    /// the track was solved to carry no current at all.
    width_mm: f64,
    /// The solve failed and `width_mm` is the whole-rail per-layer envelope.
    envelope: bool = false,
    /// The `power_current` status name behind an envelope width
    /// ("no-source-terminal", "disconnected", …); empty when solved.
    reason: []const u8 = "",
};

/// TEMPORARY BRIDGE — delete when `power_integrity` returns `?LocalWidth`.
/// Promotes the historical `?f64` per-track widths into records, marking every
/// one SOLVED because the old signature had no way to say otherwise.
pub fn promote(
    alloc: std.mem.Allocator,
    widths: []const ?f64,
) std.mem.Allocator.Error![]const ?LocalWidth {
    const out = try alloc.alloc(?LocalWidth, widths.len);
    for (widths, out) |width, *slot| {
        slot.* = if (width) |mm| LocalWidth{ .width_mm = mm } else null;
    }
    return out;
}

/// What one track's ELECTRICAL duty requires, and how a shortfall reads.
///
/// `kind == null` is the ordinary signal case: this track has no
/// current-derived requirement at all and the geometric width rules own it.
pub const Duty = struct {
    /// The width this track's current demands, already raised to the board
    /// minimum and the authored branch floor. 0 when there is no duty.
    required_mm: f64 = 0,
    /// The finding a shortfall becomes: `.power_width` for a solved
    /// requirement, `.power_width_envelope` for a whole-rail fallback.
    kind: ?drc.Kind = null,
    /// Why the requirement is an envelope; empty for a solved one.
    reason: []const u8 = "",
    /// A per-track solve REPLACES the net-class `(width …)` rather than being
    /// maxed with it — see the module header. The whole-rail tier does not:
    /// it is the same order of conservatism as the class and stacks with it.
    supersedes_class: bool = false,
};

/// The current-capacity requirement for the track of `net_index` whose solve
/// is `local`. `min_width` is the board fabrication minimum.
///
/// `local` null means the power solver produced no entry for this track — the
/// net declares no current demand at all, or the caller ran no solve. Only
/// then does the conservative whole-rail tier apply, and it stays a
/// `power_width` ERROR rather than an envelope warning: an envelope is what a
/// FAILED solve produced and must therefore explain itself, while this tier is
/// the pre-solve rule for copper no solver looked at. In practice a net with a
/// whole-rail width always has a declared demand and therefore an entry, so
/// this tier is the safety net under a caller that supplies none.
pub fn duty(
    placement: optimizer.Placement,
    net_index: usize,
    local: ?LocalWidth,
    min_width: f64,
) Duty {
    if (local) |solved| {
        const floor = if (net_index < placement.rules.net.len)
            placement.rules.net[net_index].pad_neck.power_branch_width
        else
            0;
        return .{
            .required_mm = @max(min_width, @max(floor, solved.width_mm)),
            .kind = if (solved.envelope) .power_width_envelope else .power_width,
            .reason = if (solved.envelope) solved.reason else "",
            .supersedes_class = true,
        };
    }
    if (!wholeRailNet(placement, net_index)) return .{};
    const rail = placement.rules.powerWidthForNet(placement.nets[net_index].name) orelse return .{};
    return .{ .required_mm = rail, .kind = .power_width };
}

/// Whether a net still falls back to the conservative WHOLE-RAIL width because
/// no per-track solve reached it. A planed rail carries its current in copper
/// this rule cannot see, and an impedance-controlled or differential net's
/// width is set by its transmission line, not by ampacity — none of them may
/// be widened by a rail envelope.
fn wholeRailNet(placement: optimizer.Placement, net_index: usize) bool {
    if (net_index >= placement.nets.len) return false;
    const name = placement.nets[net_index].name;
    if (placement.rules.powerWidthForNet(name) == null or router.netHasPlane(placement, name)) return false;
    if (net_index < placement.rules.net.len) {
        const rule = placement.rules.net[net_index];
        if (rule.rf.impedance.ohms > 0 or rule.rf.impedance.diff_ohms > 0) return false;
    }
    for (placement.diff_pairs) |pair| if (pair.p == net_index or pair.n == net_index) return false;
    return true;
}

/// One track measured short of its current-capacity requirement, held back
/// until the whole pass is collected so the pad-entry neck walk can judge it
/// against its NEIGHBOURS' requirements.
pub const Shortfall = struct {
    track_index: usize,
    /// The track's actual width (mm).
    actual: f64,
    /// The requirement it fell short of (mm).
    required: f64,
    /// `.power_width` or `.power_width_envelope`, from `Duty.kind`.
    kind: drc.Kind,
    /// The envelope reason, carried into the finding's `who.extra` note.
    reason: []const u8 = "",
};

/// Emit one finding per candidate that the pad-entry neck exemption does not
/// forgive. `board.required` must hold the effective requirement of EVERY
/// track, not only the candidates: the neck walk asks whether the copper a
/// narrow segment runs into satisfies its own rule.
///
/// A pad the neck serves can legitimately be narrower than the solved width —
/// a short neck into wide copper is accepted practice — so it is exempted
/// silently, exactly like the own-land and port-frame-taper exemptions. One
/// geometric walk covers a whole taper chain, so its verdict is cached across
/// that chain's slices.
pub fn report(
    arena: std.mem.Allocator,
    out: *std.ArrayList(drc.Violation),
    board: pad_neck.PowerNeckBoard,
    candidates: []const Shortfall,
) std.mem.Allocator.Error!void {
    var neck_verdicts: std.AutoHashMapUnmanaged(usize, bool) = .empty;
    for (candidates) |candidate| {
        const exempt = neck_verdicts.get(candidate.track_index) orelse blk: {
            const verdict = try pad_neck.judgePowerNeck(arena, board, candidate.track_index);
            for (verdict.chain) |member| try neck_verdicts.put(arena, member, verdict.exempt);
            break :blk verdict.exempt;
        };
        if (exempt) continue;
        const track = board.tracks[candidate.track_index];
        try out.append(arena, .{
            .x = (track.x1 + track.x2) / 2,
            .y = (track.y1 + track.y2) / 2,
            .gap = candidate.actual,
            .clearance = candidate.required,
            .kind = candidate.kind,
            .severity = drc.defaultSeverity(candidate.kind),
            .who = .{
                .net_a = track.net,
                .track_a = drc.partyIndex(candidate.track_index),
                .extra = if (candidate.reason.len > 0) .{ .note = candidate.reason } else .none,
            },
            .layer = board_layers.SignalIndex.of(track.layer),
        });
    }
}

const testing = std.testing;
const FlatNet = @import("../flat_netlist.zig").FlatNet;

fn testPlacement(net_rules: []const optimizer.NetRule, nets: []const FlatNet) optimizer.Placement {
    return .{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -10,
        .miny = -10,
        .maxx = 10,
        .maxy = 10,
        .generated = true,
        .rules = .{ .net = net_rules, .plane_nets = &.{}, .copper_layers = 2 },
    };
}

// spec: placement/drc - a solved local-current width replaces the net-class width for that track, floored by fabrication and the authored power-branch-width
test "a solved width supersedes the class width and is floored, never narrowed, by it" {
    const net_rules = [_]optimizer.NetRule{.{ .width = 0.2532, .pad_neck = .{ .power_branch_width = 0.15 } }};
    const nets = [_]FlatNet{.{ .name = "V3P3", .pins = &.{} }};
    const placement = testPlacement(&net_rules, &nets);

    // A real branch current: the solved width wins outright over the trunk class.
    const solved = duty(placement, 0, .{ .width_mm = 0.33 }, 0.127);
    try testing.expectEqual(drc.Kind.power_width, solved.kind.?);
    try testing.expect(solved.supersedes_class);
    try testing.expectApproxEqAbs(@as(f64, 0.33), solved.required_mm, 1e-12);
    try testing.expectEqualStrings("", solved.reason);

    // The authored branch floor still binds under a thinner solve…
    const floored = duty(placement, 0, .{ .width_mm = 0.08 }, 0.127);
    try testing.expectApproxEqAbs(@as(f64, 0.15), floored.required_mm, 1e-12);

    // …and a 0 A stub falls to fabrication, NOT to the 0.2532 class width,
    // with no branch floor authored.
    const bare_rules = [_]optimizer.NetRule{.{ .width = 0.2532 }};
    const bare = testPlacement(&bare_rules, &nets);
    const stub = duty(bare, 0, .{ .width_mm = 0 }, 0.127);
    try testing.expectApproxEqAbs(@as(f64, 0.127), stub.required_mm, 1e-12);
    try testing.expectEqual(drc.Kind.power_width, stub.kind.?);
}

// spec: placement/drc - an unsolvable rail is judged against the whole-rail envelope as a warning naming the solver status, not as a fabrication error
test "an envelope width is a separate finding carrying the solver's reason" {
    const net_rules = [_]optimizer.NetRule{.{ .width = 0.2532 }};
    const nets = [_]FlatNet{.{ .name = "V3P3", .pins = &.{} }};
    const placement = testPlacement(&net_rules, &nets);

    const envelope = duty(placement, 0, .{
        .width_mm = 0.62,
        .envelope = true,
        .reason = "no-source-terminal",
    }, 0.127);
    try testing.expectEqual(drc.Kind.power_width_envelope, envelope.kind.?);
    try testing.expectApproxEqAbs(@as(f64, 0.62), envelope.required_mm, 1e-12);
    try testing.expectEqualStrings("no-source-terminal", envelope.reason);
    try testing.expectEqual(drc.Severity.warn, drc.defaultSeverity(envelope.kind.?));
    try testing.expectEqual(drc.Severity.err, drc.defaultSeverity(drc.Kind.power_width));
}

// spec: placement/drc - a net with no solved entry and no rail demand imposes no current-capacity requirement at all
test "no solve and no declared rail leaves the width rule to geometry" {
    const net_rules = [_]optimizer.NetRule{.{ .width = 0.2532 }};
    const nets = [_]FlatNet{.{ .name = "V3P3", .pins = &.{} }};
    const placement = testPlacement(&net_rules, &nets);
    const none = duty(placement, 0, null, 0.127);
    try testing.expectEqual(@as(?drc.Kind, null), none.kind);
    try testing.expectApproxEqAbs(@as(f64, 0), none.required_mm, 1e-12);
    // An out-of-range net index must degrade to "no duty", never panic.
    try testing.expectEqual(@as(?drc.Kind, null), duty(placement, 7, null, 0.127).kind);
}

// spec: placement/drc - each power-width shortfall becomes one finding of its own kind and severity, with the envelope reason attached
test "report emits every candidate with its kind, severity, and envelope note" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const nets = [_]FlatNet{.{ .name = "V3P3", .pins = &.{} }};
    const placement = testPlacement(&.{}, &nets);
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 2, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 0, .y1 = 1, .x2 = 2, .y2 = 1, .layer = 0, .width = 0.2, .net = 0 },
    };
    const required = [_]f64{ 0.4, 0.6 };
    const candidates = [_]Shortfall{
        .{ .track_index = 0, .actual = 0.2, .required = 0.4, .kind = .power_width },
        .{
            .track_index = 1,
            .actual = 0.2,
            .required = 0.6,
            .kind = .power_width_envelope,
            .reason = "no-source-terminal",
        },
    };
    var out: std.ArrayList(drc.Violation) = .empty;
    try report(arena, &out, .{
        .placement = placement,
        .tracks = &tracks,
        .vias = &.{},
        .required = &required,
    }, &candidates);

    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqual(drc.Kind.power_width, out.items[0].kind);
    try testing.expectEqual(drc.Severity.err, out.items[0].severity);
    try testing.expectEqualStrings("", out.items[0].who.noteText());
    try testing.expectEqual(@as(i32, 0), out.items[0].who.track_a);

    try testing.expectEqual(drc.Kind.power_width_envelope, out.items[1].kind);
    try testing.expectEqual(drc.Severity.warn, out.items[1].severity);
    try testing.expectEqualStrings("no-source-terminal", out.items[1].who.noteText());
    try testing.expectApproxEqAbs(@as(f64, 0.6), out.items[1].clearance, 1e-12);
}
