//! Stable pad-transition shaping seam shared by route lowering and the solver.
//!
//! The web layer must not import placement implementation modules directly.
//! This small root-level adapter keeps that boundary while ensuring replayed
//! sub-circuit copper uses the exact same fabrication profile as a normal
//! router result.

const std = @import("std");
const optimizer = @import("placement/optimizer.zig");
const router = @import("placement/router.zig");
const pad_neck = @import("placement/pad_neck.zig");
const rf_port_report = @import("placement/rf_port_report.zig");
const rf_taper_paths = @import("placement/rf_taper_paths.zig");
const variable_width_copper = @import("placement/variable_width_copper.zig");

/// Restore selected replay tracks to their authored nominal class width, then
/// apply the ordinary authored neck or controlled-impedance taper profile at
/// SMD endpoints.
pub fn restoreGeneratedTracks(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    selected: []const bool,
    routed: router.RouteResult,
) std.mem.Allocator.Error!router.RouteResult {
    var tracks: std.ArrayList(router.Track) = .empty;
    try tracks.appendSlice(arena, routed.tracks);
    for (tracks.items) |*track| {
        if (track.net < 0) continue;
        const ni: usize = @intCast(track.net);
        if (ni >= selected.len or !selected[ni] or ni >= placement.rules.net.len) continue;
        const rule = placement.rules.net[ni];
        if (rule.width > 0) track.width = rule.width;
    }
    _ = try pad_neck.shapeGeneratedTracks(arena, placement, selected, routed.vias, &tracks);
    var out = routed;
    out.tracks = tracks.items;
    return out;
}

fn hasExactPath(
    outcomes: []const rf_port_report.Outcome,
    tracks: []const router.Track,
    net: i32,
) bool {
    for (outcomes) |outcome| {
        if (outcome.net != net or !outcome.success) continue;
        if (outcome.physical.gate_removed or outcome.physical.samples.len < 2) continue;
        for (tracks) |track| {
            if (track.net != net or track.layer != outcome.physical.layer) continue;
            if (variable_width_copper.ownsTrack(outcome.physical.samples, track)) return true;
        }
    }
    return false;
}

/// Reapply pad transitions to final generated copper that escaped a late route
/// rescue without exact path metadata, then replace its conservative taper
/// slices with the same swept-copper representation the ordinary router finish
/// emits. `selected` must name generated, mutable nets only; existing/user
/// copper is deliberately outside this adapter's authority.
pub fn finishExactRfTapers(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    selected: []const bool,
    routed: router.RouteResult,
) std.mem.Allocator.Error!router.RouteResult {
    const missing = try arena.alloc(bool, placement.nets.len);
    var any_missing = false;
    for (missing, 0..) |*slot, net_i| {
        const in_scope = selected.len == 0 or (net_i < selected.len and selected[net_i]);
        slot.* = in_scope and !hasExactPath(routed.rf_port_outcomes, routed.tracks, @intCast(net_i));
        any_missing = any_missing or slot.*;
    }
    if (!any_missing) return routed;

    var shaped = try restoreGeneratedTracks(arena, placement, missing, routed);
    const fallbacks = try rf_taper_paths.exactFallbacks(
        arena,
        placement,
        shaped.tracks,
        shaped.rf_port_outcomes,
    );
    if (fallbacks.len == 0) return shaped;

    var tracks: std.ArrayList(router.Track) = .empty;
    try tracks.appendSlice(arena, shaped.tracks);
    try rf_taper_paths.compactFallbackHandles(arena, &tracks, fallbacks);
    var outcomes: std.ArrayList(rf_port_report.Outcome) = .empty;
    try outcomes.appendSlice(arena, shaped.rf_port_outcomes);
    try outcomes.appendSlice(arena, fallbacks);
    shaped.tracks = try tracks.toOwnedSlice(arena);
    shaped.rf_port_outcomes = try outcomes.toOwnedSlice(arena);
    return shaped;
}

// spec: placement/rf-port-frame-routing - late route-plan rescue re-applies DRC-clean exact RF tapers to generated nets that lost finished path metadata without rewriting retained user copper, and keeps the gate-proven uniform trace when no legal flare fits
test "late rescued RF centreline regains its exact two-sided taper" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const flat_netlist = @import("flat_netlist.zig");
    const geometry = @import("placement/geometry.zig");

    const wide_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.8, .h = 0.6 }};
    const narrow_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.2 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "J1", .kind = .hub, .hw = 1, .hh = 1, .pads = &wide_pad, .fallback = false },
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &narrow_pad, .fallback = false, .x = 3 },
    };
    const pins = [_]flat_netlist.FlatPin{
        .{ .ref_des = "J1", .pin = "1" },
        .{ .ref_des = "U1", .pin = "1" },
    };
    const nets = [_]flat_netlist.FlatNet{.{ .name = "RF", .pins = &pins }};
    const rules = [_]optimizer.NetRule{.{
        .width = 0.4,
        .rf = .{ .impedance = .{ .ohms = 50 } },
    }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .rules = .{ .net = &rules, .design = .{ .track_width = 0.127, .min_width = 0.127 } },
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -1,
        .miny = -1,
        .maxx = 4,
        .maxy = 1,
        .generated = true,
    };
    const stale_samples = [_]@import("placement/rf_path_solver.zig").Sample{
        .{ .at = .{ 0, 0 }, .s_mm = 0, .curvature = 0, .width_mm = 0.4 },
        .{ .at = .{ 3, 0 }, .s_mm = 3, .curvature = 0, .width_mm = 0.4 },
    };
    const stale = [_]rf_port_report.Outcome{.{
        .net = 0,
        .chosen = 0,
        .feasible = true,
        .success = true,
        .metrics = .{},
        .trials = &.{},
        .physical = .{ .samples = &stale_samples, .sample_count = stale_samples.len, .gate_removed = true },
    }};
    const finished = try finishExactRfTapers(arena, placement, &.{true}, .{
        .tracks = &.{.{ .x1 = 0, .y1 = 0, .x2 = 3, .y2 = 0, .layer = 0, .width = 0.3124, .net = 0 }},
        .vias = &.{},
        .rf_port_outcomes = &stale,
        .routed = 1,
        .total = 1,
    });

    const exact = finished.rf_port_outcomes[1];
    try std.testing.expectEqual(@as(usize, 1), finished.tracks.len);
    try std.testing.expectEqual(@as(usize, 2), finished.rf_port_outcomes.len);
    try std.testing.expect(exact.success and exact.physical.samples.len > 2);
    try std.testing.expectApproxEqAbs(@as(f64, 0.6), exact.physical.samples[0].width_mm, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), exact.physical.samples[exact.physical.samples.len - 1].width_mm, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), finished.tracks[0].width, 1e-9);
}
