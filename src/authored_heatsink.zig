//! Bridge board-authored heatsink defaults into layout and thermal views.
//!
//! The `.sexp` target is a stable `(sub-block scope, source origin)` pair.
//! Layouts and the thermal kernel use the current flattened ref-des, so this
//! module performs that identity join once and keeps it out of the already
//! large PCB page implementation.

const std = @import("std");
const env = @import("eval/env.zig");
const thermal = @import("eval/thermal.zig");
const flat = @import("flat_netlist.zig");
const net_name = @import("net_name.zig");
const optimizer = @import("placement/optimizer.zig");
const scenarios = @import("thermal_scenarios.zig");
const sidecar = @import("layout_sidecar_types.zig");

/// Resolve and lower the source-authored default into the sidecar-shaped
/// assembly shared by the PCB renderers and the thermal handoff.
pub fn lower(placement: optimizer.Placement, spec: ?env.BoardHeatsinkSpec) ?sidecar.SavedHeatsink {
    const sink = spec orelse return null;
    const board = placement.board_rect orelse return null;
    const target_ref = target(placement, sink.target.scope, sink.target.origin) orelse return null;
    return .{
        .x = board.minx + sink.rect.x,
        .y = board.miny + sink.rect.y,
        .w = sink.rect.w,
        .h = sink.rect.h,
        .side = @tagName(sink.side),
        .target_ref = target_ref,
        .material = sink.material,
        .base_mm = sink.geometry.base_mm,
        .fin_height_mm = sink.geometry.fin_height_mm,
        .fin_thickness_mm = sink.geometry.fin_thickness_mm,
        .fin_gap_mm = sink.geometry.fin_gap_mm,
        .fin_axis = sink.geometry.fin_axis,
        .pad_thickness_mm = sink.pad.thickness_mm,
        .pad_k_w_mk = sink.pad.conductivity_w_mk,
    };
}

/// Lift a board-authored axial fan from board-local coordinates into the
/// absolute placement frame consumed by thermal fields and renderers.
pub fn lowerFanSaved(placement: optimizer.Placement, spec: ?env.BoardFanSpec) ?sidecar.SavedFan {
    const fan = spec orelse return null;
    const board = placement.board_rect orelse return null;
    return .{
        .model = fan.model,
        .rect = .{ .x = board.minx + fan.rect.x, .y = board.miny + fan.rect.y, .w = fan.rect.w, .h = fan.rect.h },
        .side = @tagName(fan.side),
        .distance_mm = fan.distance_mm,
        .curve = .{ .free_air_flow_m3_s = fan.free_air_flow_m3_s, .max_static_pressure_pa = fan.max_static_pressure_pa },
        .operating_flow_fraction = fan.operating_flow_fraction,
    };
}

/// Resolve a saved layout override over the source-authored fan defaults.
pub fn resolveFan(placement: optimizer.Placement, saved: ?sidecar.SavedFan, spec: ?env.BoardFanSpec) ?sidecar.SavedFan {
    return saved orelse lowerFanSaved(placement, spec);
}

/// Convert the persisted/editor shape into the thermal kernel input.
pub fn fanThermalInput(saved: sidecar.SavedFan) scenarios.Fan {
    return .{
        .model = saved.model,
        .footprint = .{ .x_mm = saved.rect.x, .y_mm = saved.rect.y, .w_mm = saved.rect.w, .h_mm = saved.rect.h },
        .face = if (std.mem.eql(u8, saved.side, "bottom")) .bottom else .top,
        .distance_mm = saved.distance_mm,
        .free_air_flow_m3_s = saved.curve.free_air_flow_m3_s,
        .max_static_pressure_pa = saved.curve.max_static_pressure_pa,
        .operating_flow_fraction = saved.operating_flow_fraction,
    };
}

/// Backward-compatible direct lowering for non-layout callers.
pub fn lowerFan(placement: optimizer.Placement, spec: ?env.BoardFanSpec) ?scenarios.Fan {
    return fanThermalInput(lowerFanSaved(placement, spec) orelse return null);
}

/// Apply a saved layout's physical override while keeping an authored target
/// bound to its stable source identity. Boards without a source declaration
/// retain the historical sidecar-only behavior.
pub fn resolve(
    placement: optimizer.Placement,
    saved: ?sidecar.SavedHeatsink,
    spec: ?env.BoardHeatsinkSpec,
) ?sidecar.SavedHeatsink {
    const authored = lower(placement, spec);
    if (spec != null and authored == null) return null;
    if (saved) |value| {
        var merged = value;
        if (authored) |fallback| {
            merged.target_ref = fallback.target_ref;
        }
        return merged;
    }
    return authored;
}

/// Convert a sidecar-shaped assembly into the package-relative thermal input.
/// Null is deliberate: a stale saved ref must never cool a recycled part.
pub fn thermalInput(
    placement: optimizer.Placement,
    bt: thermal.BoardThermal,
    saved: sidecar.SavedHeatsink,
) ?scenarios.Heatsink {
    const physical = optimizer.Side.fromStr(saved.side);
    if (saved.target_ref.len == 0) return .{
        .side = .board_backside,
        .physical_face = if (physical == .top) .top else .bottom,
        .geometry = .{
            .width_mm = saved.w,
            .length_mm = saved.h,
            .base_mm = saved.base_mm,
            .fin_height_mm = saved.fin_height_mm,
            .fin_thickness_mm = saved.fin_thickness_mm,
            .fin_gap_mm = saved.fin_gap_mm,
            .fin_axis = std.meta.stringToEnum(scenarios.FinAxis, saved.fin_axis) orelse .length,
        },
        .material = std.meta.stringToEnum(scenarios.HeatsinkMaterial, saved.material) orelse .aluminum_6063,
        .contact = .{ .x_mm = saved.x, .y_mm = saved.y, .w_mm = saved.w, .h_mm = saved.h },
        .pad = .{ .thickness_mm = saved.pad_thickness_mm, .conductivity_w_mk = saved.pad_k_w_mk },
    };
    const mounted = scenarios.resolveMountedTarget(bt, placement, saved.target_ref) orelse return null;
    return .{
        .ref_des = mounted.ref_des,
        .side = if (physical == mounted.side) .package_top else .board_backside,
        .physical_face = if (physical == .top) .top else .bottom,
        .geometry = .{
            .width_mm = saved.w,
            .length_mm = saved.h,
            .base_mm = saved.base_mm,
            .fin_height_mm = saved.fin_height_mm,
            .fin_thickness_mm = saved.fin_thickness_mm,
            .fin_gap_mm = saved.fin_gap_mm,
            .fin_axis = std.meta.stringToEnum(scenarios.FinAxis, saved.fin_axis) orelse .length,
        },
        .material = std.meta.stringToEnum(scenarios.HeatsinkMaterial, saved.material) orelse .aluminum_6063,
        .contact = .{ .x_mm = saved.x, .y_mm = saved.y, .w_mm = saved.w, .h_mm = saved.h },
        .pad = .{ .thickness_mm = saved.pad_thickness_mm, .conductivity_w_mk = saved.pad_k_w_mk },
    };
}

fn target(placement: optimizer.Placement, scope: []const u8, origin: []const u8) ?[]const u8 {
    for (placement.instances) |instance| {
        if (!std.mem.eql(u8, instance.origin_key, origin)) continue;
        const parent = net_name.parent(instance.ref_des) orelse "";
        if (std.mem.eql(u8, parent, scope)) return instance.ref_des;
    }
    return null;
}

test "authored target follows source identity across ref-des renumbering" {
    var parts = [_]optimizer.Part{
        .{ .ref_des = "synth/U42", .kind = .hub, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false },
        .{ .ref_des = "filter/U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false },
    };
    const instances = [_]flat.FlatInstance{
        .{ .ref_des = "filter/U1", .component = "cold", .origin_key = "U1", .value = "", .footprint = "", .properties = &.{}, .uuid = "" },
        .{ .ref_des = "synth/U42", .component = "hot", .origin_key = "U1", .value = "", .footprint = "", .properties = &.{}, .uuid = "" },
    };
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &instances,
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 10,
        .maxy = 10,
        .board_rect = .{ .minx = 100, .miny = 50, .w = 20, .h = 10 },
        .generated = false,
    };
    const sink = lower(placement, .{
        .rect = .{ .x = 0, .y = 0, .w = 10, .h = 10 },
        .side = .bottom,
        .target = .{ .scope = "synth", .origin = "U1" },
    }) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("synth/U42", sink.target_ref);
    try std.testing.expectEqual(@as(f64, 100), sink.x);
    try std.testing.expectEqual(@as(f64, 50), sink.y);

    var stale = sink;
    stale.target_ref = "filter/U1";
    const merged = resolve(placement, stale, .{
        .rect = .{ .x = 0, .y = 0, .w = 10, .h = 10 },
        .side = .bottom,
        .target = .{ .scope = "synth", .origin = "U1" },
    }) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("synth/U42", merged.target_ref);

    const missing = resolve(placement, stale, .{
        .rect = .{ .x = 0, .y = 0, .w = 10, .h = 10 },
        .side = .bottom,
        .target = .{ .scope = "missing", .origin = "U1" },
    });
    try std.testing.expectEqual(@as(?sidecar.SavedHeatsink, null), missing);
}

// spec: placement/thermal_field - a saved layout can override the authored fan's projected position, PCB face and outlet-to-board standoff without changing how the thermal field consumes its operating point
test "authored fan footprint is lifted from board-local and accepts a saved override" {
    const placement = optimizer.Placement{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 0,
        .maxy = 0,
        .board_rect = .{ .minx = 100, .miny = 50, .w = 81, .h = 25 },
        .generated = false,
    };
    const fan = lowerFan(placement, .{
        .model = "9A0812G4D011",
        .rect = .{ .x = 0.5, .y = -27.5, .w = 80, .h = 80 },
        .side = .top,
        .distance_mm = 10,
        .free_air_flow_m3_s = 0.025,
        .max_static_pressure_pa = 80.4,
        .operating_flow_fraction = 0.6,
    }) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("9A0812G4D011", fan.model);
    try std.testing.expectEqual(@as(f64, 100.5), fan.footprint.?.x_mm);
    try std.testing.expectEqual(@as(f64, 22.5), fan.footprint.?.y_mm);
    try std.testing.expectEqual(scenarios.Side.top, fan.face);

    const overridden = resolveFan(placement, .{
        .model = "9A0812G4D011",
        .rect = .{ .x = 120, .y = 40, .w = 80, .h = 80 },
        .side = "bottom",
        .distance_mm = 25,
        .curve = .{ .free_air_flow_m3_s = 0.025, .max_static_pressure_pa = 80.4 },
        .operating_flow_fraction = 0.5,
    }, null) orelse return error.TestUnexpectedResult;
    const thermal_fan = fanThermalInput(overridden);
    try std.testing.expectEqual(@as(f64, 120), thermal_fan.footprint.?.x_mm);
    try std.testing.expectEqual(@as(f64, 25), thermal_fan.distance_mm);
    try std.testing.expectEqual(scenarios.Side.bottom, thermal_fan.face);
}
