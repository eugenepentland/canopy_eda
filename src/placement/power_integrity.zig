//! Post-route continuous-current capacity screen for power copper.
//!
//! This is deliberately a SCREEN, not a coupled electro-thermal field solve.
//! It evaluates every actual routed width against the board's actual foil,
//! every through-via against its plated barrel area, and every computed plane
//! or user pour as capacity per millimetre of neck width. The current envelope
//! comes from
//! `eval/power_budget.zig`; when a rail has no declared load the geometry still
//! reports its capacity but never claims a pass.
//!
//! The conductor relation is the long-standing IPC-2221 approximation
//!
//!   I = k * dT^0.44 * A^0.725
//!
//! with A in mil^2, k=0.048 for outer copper and 0.024 for inner copper. It is
//! conservative and auditable, but it is not advertised as an IPC-2152 model.
//! Routed traces and vias also form a resistive graph. When physical source and
//! load pads can be resolved, Kirchhoff's current law gives each branch its
//! local current and voltage drop. The actual clearance-carved kept components
//! of planes and pours complete that topology as equipotential sheets. Their
//! neck capacity is independently proven only when the enforced pour minimum
//! width is sufficient; otherwise it remains explicitly not proven.

const std = @import("std");
const env = @import("../eval/env.zig");
const optimizer = @import("optimizer.zig");
const router = @import("router.zig");
const module_policy = @import("module_policy.zig");
const power_budget = @import("../eval/power_budget.zig");
const net_names = @import("../net_name.zig");
const numeric = @import("../numeric.zig");
const power_current = @import("power_current.zig");
const pour = @import("pour.zig");
const implicit_plane = @import("implicit_plane.zig");
const power_capacity = @import("power_capacity.zig");

/// Temperature-rise target used by the continuous-current screen.
pub const temperature_rise_c: f64 = power_capacity.temperature_rise_c;
/// Legacy default for callers that inspect the model without a board. Actual
/// analyses use the board's resolved `(via-plating MM)` value.
pub const via_plating_mm: f64 = env.default_via_plating_mm;
/// Copper resistivity used for the room-temperature voltage-drop estimate.
const copper_resistivity_ohm_m: f64 = 1.724e-8;
const geometry_eps_mm: f64 = 1e-6;

/// Declared whole-rail load and source envelope matched to routed copper.
const Demand = struct {
    typical_a: ?f64 = null,
    maximum_a: ?f64 = null,
    source_typical_a: ?f64 = null,
    source_maximum_a: ?f64 = null,
    source: []const u8 = "",
    source_terminals: []const []const u8 = &.{},
    consumers: []const power_budget.RailConsumer = &.{},
};

/// Capacity facts for one physical routed trace segment.
const Track = struct {
    route_index: usize,
    physical_layer: u8,
    foil_mm: f64,
    capacity_a: f64,
    resistance_ohm: f64,
    current_typical_a: ?f64,
    current_maximum_a: ?f64,
    drop_typical_v: ?f64,
    drop_maximum_v: ?f64,
    required_width_typical_mm: ?f64,
    required_width_maximum_mm: ?f64,
};

/// Capacity facts for one physical through-via barrel.
const Via = struct {
    route_index: usize,
    plating_mm: f64,
    barrel_area_mm2: f64,
    capacity_a: f64,
    resistance_ohm: f64,
    current_typical_a: ?f64,
    current_maximum_a: ?f64,
    drop_typical_v: ?f64,
    drop_maximum_v: ?f64,
    required_count_typical: ?usize,
    required_count_maximum: ?usize,
};

const SurfaceKind = enum {
    plane,
    pour,
    zone,

    /// Stable spelling for the PCB payload and inspector.
    pub fn name(self: SurfaceKind) []const u8 {
        return switch (self) {
            .plane => "plane",
            .pour => "pour",
            .zone => "user-pour",
        };
    }
};

const SurfaceCapacityStatus = enum {
    verified,
    not_proven,
    no_current,

    /// Stable spelling for the PCB payload and inspector.
    pub fn name(self: SurfaceCapacityStatus) []const u8 {
        return switch (self) {
            .verified => "verified",
            .not_proven => "not-proven",
            .no_current => "no-current",
        };
    }
};

/// Capacity-per-neck-width facts for one computed carried plane or pour.
const Plane = struct {
    kind: SurfaceKind,
    physical_layer: u8,
    foil_mm: f64,
    component_count: usize,
    fill_coarsened: bool,
    design_min_width_mm: f64,
    capacity_a_per_mm: f64,
    capacity_at_design_min_a: f64,
    required_neck_typical_mm: ?f64,
    required_neck_maximum_mm: ?f64,
    typical_status: SurfaceCapacityStatus,
    maximum_status: SurfaceCapacityStatus,
};

const Surface = struct {
    net: []const u8,
    kind: SurfaceKind,
    physical_layer: u8,
    signal_layer: ?u8,
    fill: pour.Fill,
};

/// All screened copper belonging to one power-like flattened net.
const Net = struct {
    index: usize,
    name: []const u8,
    demand: Demand,
    typical_status: power_current.Status,
    maximum_status: power_current.Status,
    tracks: []const Track,
    vias: []const Via,
    planes: []const Plane,
};

/// Post-route power-copper analysis grouped by flattened net.
const Analysis = struct {
    nets: []const Net,
};

fn sameNet(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b) or std.ascii.eqlIgnoreCase(net_names.leaf(a), net_names.leaf(b));
}

fn positive(v: f64) ?f64 {
    return if (v > 0 and std.math.isFinite(v)) v else null;
}

/// Continuous-current capacity for a copper cross-section. `area_mm2` is the
/// section perpendicular to current flow, not board-plan copper area.
const capacityForArea = power_capacity.capacityForArea;

/// Ten-degree-rise continuous-current capacity of one routed trace section.
const traceCapacityA = power_capacity.traceCapacityA;

/// Trace width needed to carry `amps`, or null for an absent load/foil.
const requiredTraceWidthMm = power_capacity.requiredTraceWidthMm;

fn conductorResistance(length_mm: f64, area_mm2: f64) f64 {
    if (!(length_mm > 0) or !(area_mm2 > 0)) return 0;
    return copper_resistivity_ohm_m * 1000.0 * length_mm / area_mm2;
}

fn demandFromRail(rail: power_budget.Rail) Demand {
    return .{
        .typical_a = if (rail.any_typ_load) positive(rail.load_typ_a) else null,
        .maximum_a = if (rail.any_max_load) positive(rail.load_max_a) else null,
        .source_typical_a = if (rail.source_typ_a) |v| positive(v) else null,
        .source_maximum_a = if (rail.source_max_a) |v| positive(v) else null,
        .source = rail.source_label,
        .source_terminals = rail.source_terminals,
        .consumers = rail.consumers,
    };
}

fn demandFor(rails: []const power_budget.Rail, net: []const u8) Demand {
    for (rails) |rail| {
        if (std.ascii.eqlIgnoreCase(rail.net, net)) return demandFromRail(rail);
    }
    var fallback: ?power_budget.Rail = null;
    for (rails) |rail| {
        if (!std.ascii.eqlIgnoreCase(net_names.leaf(rail.net), net_names.leaf(net))) continue;
        // A flattened route may have lost a hierarchy prefix that the power
        // budget retains. A unique leaf is still safe to join; two different
        // hierarchical rails with the same leaf are not. Refuse that
        // ambiguity instead of letting hash-map iteration manufacture a load.
        if (fallback) |prior| {
            if (!std.ascii.eqlIgnoreCase(prior.net, rail.net)) return .{};
        } else fallback = rail;
    }
    return if (fallback) |rail| demandFromRail(rail) else .{};
}

fn isPowerNet(placement: optimizer.Placement, net_index: usize, demand: Demand) bool {
    if (demand.typical_a != null or demand.maximum_a != null) return true;
    const name = placement.nets[net_index].name;
    if (placement.rules.carriesPlane(name)) return true;
    return switch (module_policy.classifyNetName(name)) {
        .ground, .power => true,
        else => false,
    };
}

fn countFor(amps: ?f64, capacity: f64) ?usize {
    const current = amps orelse return null;
    if (!(capacity > 0)) return null;
    return @max(@as(usize, 1), numeric.checkedInt(usize, @ceil(current / capacity)) orelse return null);
}

fn boardThicknessMm(placement: optimizer.Placement) f64 {
    if (placement.rules.physical.board_thickness > 0) return placement.rules.physical.board_thickness;
    if (placement.rules.physical.stack.board_mm > 0) return placement.rules.physical.stack.board_mm;
    return 1.6;
}

fn partForRef(placement: optimizer.Placement, ref_des: []const u8) ?*const optimizer.Part {
    for (placement.parts) |*part| if (std.mem.eql(u8, part.ref_des, ref_des)) return part;
    return null;
}

fn contactForPin(placement: optimizer.Placement, pin: anytype) ?power_current.Contact {
    const part = partForRef(placement, pin.ref_des) orelse return null;
    var found: ?@import("geometry.zig").Pad = null;
    for (part.pads) |pad| {
        if (!std.mem.eql(u8, pad.number, pin.pin)) continue;
        found = pad;
        break;
    }
    const pad = found orelse return null;
    const at = optimizer.worldPadCenter(part, pad.x, pad.y);
    return .{
        .at = at,
        .layer = if (pad.thru) null else if (part.side == .top) 0 else 1,
        .reach_mm = @max(0.01, std.math.hypot(pad.w / 2.0, pad.h / 2.0)),
    };
}

fn descendantOf(ref_des: []const u8, prefix: []const u8) bool {
    return ref_des.len > prefix.len and std.mem.startsWith(u8, ref_des, prefix) and ref_des[prefix.len] == '/';
}

fn appendContact(alloc: std.mem.Allocator, out: *std.ArrayList(power_current.Contact), contact: power_current.Contact) std.mem.Allocator.Error!void {
    for (out.items) |old| {
        if (old.layer == contact.layer and std.math.hypot(old.at[0] - contact.at[0], old.at[1] - contact.at[1]) < geometry_eps_mm) return;
    }
    try out.append(alloc, contact);
}

fn sourceContacts(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    net_index: usize,
    terminals: []const []const u8,
) std.mem.Allocator.Error![]const power_current.Contact {
    var out: std.ArrayList(power_current.Contact) = .empty;
    const net = placement.nets[net_index];
    for (terminals) |path| {
        if (std.mem.startsWith(u8, path, "@external/")) {
            // External board power enters through top-level connector pads on
            // the declared port net. Limit the convention to J/P designators;
            // selecting every top-level hub would incorrectly turn IC loads on
            // the same rail into parallel voltage sources.
            for (net.pins) |pin| {
                if (std.mem.indexOfScalar(u8, pin.ref_des, '/') != null or pin.ref_des.len == 0) continue;
                const prefix = std.ascii.toUpper(pin.ref_des[0]);
                if (prefix != 'J' and prefix != 'P') continue;
                if (contactForPin(placement, pin)) |contact| try appendContact(alloc, &out, contact);
            }
            continue;
        }
        const prefix = net_names.parent(path) orelse continue;
        for (net.pins) |pin| {
            if (!descendantOf(pin.ref_des, prefix)) continue;
            const part = partForRef(placement, pin.ref_des) orelse continue;
            if (part.kind != .hub) continue;
            if (contactForPin(placement, pin)) |contact| try appendContact(alloc, &out, contact);
        }
    }
    return out.items;
}

fn loadContacts(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    net_index: usize,
    consumer: power_budget.RailConsumer,
) std.mem.Allocator.Error!struct { contacts: []const power_current.Contact, complete: bool } {
    var out: std.ArrayList(power_current.Contact) = .empty;
    const net = placement.nets[net_index];
    var exact_ref = false;
    for (net.pins) |pin| if (std.mem.eql(u8, pin.ref_des, consumer.ref_des)) {
        exact_ref = true;
        break;
    };
    if (exact_ref) {
        var complete = true;
        for (consumer.pins) |wanted_pin| {
            var found = false;
            for (net.pins) |pin| {
                if (!std.mem.eql(u8, pin.ref_des, consumer.ref_des) or !std.mem.eql(u8, pin.pin, wanted_pin)) continue;
                found = true;
                if (contactForPin(placement, pin)) |contact| {
                    try appendContact(alloc, &out, contact);
                } else complete = false;
            }
            if (!found) complete = false;
        }
        return .{ .contacts = out.items, .complete = complete and out.items.len > 0 };
    }

    if (!sameNet(net.name, consumer.net)) return .{ .contacts = out.items, .complete = false };

    // Back-computed regulator input loads are keyed on a sub-block port rather
    // than a physical ref-des. Its hub device pads on this flattened net are
    // the physical load contacts.
    for (net.pins) |pin| {
        if (!descendantOf(pin.ref_des, consumer.ref_des)) continue;
        const part = partForRef(placement, pin.ref_des) orelse continue;
        if (part.kind != .hub) continue;
        if (contactForPin(placement, pin)) |contact| try appendContact(alloc, &out, contact);
    }
    return .{ .contacts = out.items, .complete = out.items.len > 0 };
}

fn buildSurfaces(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    routed: router.RouteResult,
    zones: []const pour.UserZone,
    base_edge: ?pour.EdgeField,
    memo: ?pour.FillMemo,
) std.mem.Allocator.Error![]const Surface {
    const Meta = struct { net: []const u8, kind: SurfaceKind, physical_layer: u8, signal_layer: ?u8, spec: pour.LayerSpec };
    var metas: std.ArrayList(Meta) = .empty;
    const stack = placement.rules.layerStack();
    if (placement.rules.declaredStackup()) {
        const bottom = stack.stackCount();
        for (placement.rules.planes.declared) |plane| {
            const signal_layer: ?u8 = if (plane.index == 1) 0 else if (plane.index == bottom) 1 else null;
            var spec = if (signal_layer) |layer|
                pour.outerSpec(plane.net, if (layer == 0) .top else .bottom)
            else
                pour.LayerSpec{ .net = .{ .named = plane.net }, .keep_unseeded = true };
            if (signal_layer) |layer| spec.higher = try pour.higherThanDeclared(alloc, zones, layer, spec.net);
            try metas.append(alloc, .{
                .net = plane.net,
                .kind = if (signal_layer == null) .plane else .pour,
                .physical_layer = plane.index,
                .signal_layer = signal_layer,
                .spec = spec,
            });
        }
    } else {
        const planes = implicit_plane.innerPlanes(placement.rules);
        for (planes, 0..) |plane, offset| {
            const physical: u8 = @intCast(implicit_plane.ground_index + offset);
            const net = switch (plane) {
                .ground => "GND",
                .rail => |name| name,
            };
            const spec_net: pour.PlaneNet = switch (plane) {
                .ground => .ground,
                .rail => |name| .{ .named = name },
            };
            try metas.append(alloc, .{
                .net = net,
                .kind = .plane,
                .physical_layer = physical,
                .signal_layer = null,
                .spec = .{ .net = spec_net, .keep_unseeded = true },
            });
        }
    }
    for (zones, 0..) |zone, i| {
        var spec = pour.zoneLayerSpec(zone.net, pour.sideOfSignal(zone.layer), zone.layer, zone.poly);
        spec.higher = try pour.higherPolys(alloc, zones, i);
        try metas.append(alloc, .{
            .net = zone.net,
            .kind = .zone,
            .physical_layer = placement.rules.signalStackIndex(zone.layer),
            .signal_layer = zone.layer,
            .spec = spec,
        });
    }

    const copper: pour.Copper = .{
        .tracks = routed.tracks,
        .vias = routed.vias,
        .arcs = routed.arcs,
        .rf_paths = routed.rf_port_outcomes,
        .zones = zones,
    };
    const out = try alloc.alloc(Surface, metas.items.len);
    for (metas.items, 0..) |meta, i| out[i] = .{
        .net = meta.net,
        .kind = meta.kind,
        .physical_layer = meta.physical_layer,
        .signal_layer = meta.signal_layer,
        .fill = try pour.computeMemo(alloc, placement, copper, meta.spec, base_edge, memo),
    };
    return out;
}

fn sheetLayer(surface: Surface) u8 {
    return surface.signal_layer orelse @intCast(128 + @as(u16, surface.physical_layer));
}

fn appendPoint(alloc: std.mem.Allocator, out: *std.ArrayList([2]f64), at: [2]f64) std.mem.Allocator.Error!void {
    for (out.items) |old| if (std.math.hypot(old[0] - at[0], old[1] - at[1]) < geometry_eps_mm) return;
    try out.append(alloc, at);
}

fn sheetsForNet(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    routed: router.RouteResult,
    net_index: usize,
    surfaces: []const Surface,
) std.mem.Allocator.Error![]const power_current.Sheet {
    var out: std.ArrayList(power_current.Sheet) = .empty;
    const net = placement.nets[net_index];
    for (surfaces) |surface| {
        if (!sameNet(surface.net, net.name) or surface.fill.n_comp == 0) continue;
        const contacts = try alloc.alloc(std.ArrayList([2]f64), surface.fill.n_comp);
        for (contacts) |*component| component.* = .empty;

        if (surface.signal_layer) |layer| for (routed.tracks) |track| {
            if (track.net != @as(i32, @intCast(net_index)) or track.layer != layer) continue;
            const hits = try surface.fill.segmentContacts(alloc, track.x1, track.y1, track.x2, track.y2);
            for (hits) |hit| try appendPoint(alloc, &contacts[@intCast(hit.component)], hit.at);
        };
        for (routed.vias) |via| {
            if (via.net != @as(i32, @intCast(net_index))) continue;
            const component = surface.fill.componentAt(via.x, via.y);
            if (component >= 0) try appendPoint(alloc, &contacts[@intCast(component)], .{ via.x, via.y });
        }
        for (net.pins) |pin| {
            const contact = contactForPin(placement, pin) orelse continue;
            if (contact.layer) |layer| {
                if (surface.signal_layer == null or surface.signal_layer.? != layer) continue;
            }
            const component = surface.fill.componentAt(contact.at[0], contact.at[1]);
            if (component >= 0) try appendPoint(alloc, &contacts[@intCast(component)], contact.at);
        }
        for (contacts) |component| if (component.items.len > 0) try out.append(alloc, .{
            .layer = sheetLayer(surface),
            .contacts = component.items,
        });
    }
    return out.items;
}

fn solveCurrent(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    routed: router.RouteResult,
    net_index: usize,
    demand: Demand,
    surfaces: []const Surface,
) std.mem.Allocator.Error!power_current.Result {
    const plating_mm = placement.rules.physical.via_plating_mm;
    var segments: std.ArrayList(power_current.Segment) = .empty;
    for (routed.tracks, 0..) |track, route_index| {
        if (track.net != @as(i32, @intCast(net_index))) continue;
        const foil = placement.rules.physical.stack.foilMm(placement.rules.signalStackIndex(track.layer));
        const area = track.width * foil;
        try segments.append(alloc, .{
            .route_index = route_index,
            .a = .{ track.x1, track.y1 },
            .b = .{ track.x2, track.y2 },
            .layer = track.layer,
            .resistance_ohm_per_mm = if (area > 0) copper_resistivity_ohm_m * 1000.0 / area else 0,
        });
    }
    var barrels: std.ArrayList(power_current.Barrel) = .empty;
    for (routed.vias, 0..) |via, route_index| {
        if (via.net != @as(i32, @intCast(net_index))) continue;
        const drill = if (via.drill > 0) via.drill else @max(0, via.dia - 2.0 * plating_mm);
        const area = std.math.pi * drill * plating_mm;
        try barrels.append(alloc, .{
            .route_index = route_index,
            .at = .{ via.x, via.y },
            .resistance_ohm = conductorResistance(boardThicknessMm(placement), area),
        });
    }
    const sources = try sourceContacts(alloc, placement, net_index, demand.source_terminals);
    const sheets = try sheetsForNet(alloc, placement, routed, net_index, surfaces);
    const loads = try alloc.alloc(power_current.Load, demand.consumers.len);
    for (demand.consumers, 0..) |consumer, i| {
        const resolved = try loadContacts(alloc, placement, net_index, consumer);
        loads[i] = .{
            .contacts = resolved.contacts,
            .typical_a = consumer.i_typ,
            .maximum_a = consumer.i_max,
            .complete = resolved.complete,
        };
    }
    return power_current.solve(alloc, .{
        .segments = segments.items,
        .barrels = barrels.items,
        .sheets = sheets,
        .counts = .{ .tracks = routed.tracks.len, .vias = routed.vias.len },
        .source_contacts = sources,
        .source_complete = sources.len > 0,
        .loads = loads,
    });
}

fn localCurrent(axis: power_current.Axis, route_index: usize, fallback: ?f64, via: bool) ?f64 {
    if (axis.status != .solved) return fallback;
    return if (via) axis.via_current_a[route_index] else axis.track_current_a[route_index];
}

fn localDrop(axis: power_current.Axis, route_index: usize, via: bool) ?f64 {
    if (axis.status != .solved) return null;
    return if (via) axis.via_drop_v[route_index] else axis.track_drop_v[route_index];
}

fn analyzeTracks(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    routed: router.RouteResult,
    net_index: usize,
    demand: Demand,
    flow: power_current.Result,
) std.mem.Allocator.Error![]const Track {
    var out: std.ArrayList(Track) = .empty;
    for (routed.tracks, 0..) |track, route_index| {
        if (track.net != @as(i32, @intCast(net_index))) continue;
        const physical = placement.rules.signalStackIndex(track.layer);
        const foil = placement.rules.physical.stack.foilMm(physical);
        const outer = physical == 1 or physical == placement.rules.layerStack().stackCount();
        const typical = localCurrent(flow.typical, route_index, demand.typical_a, false);
        const maximum = localCurrent(flow.maximum, route_index, demand.maximum_a, false);
        try out.append(alloc, .{
            .route_index = route_index,
            .physical_layer = physical,
            .foil_mm = foil,
            .capacity_a = traceCapacityA(track.width, foil, outer),
            .resistance_ohm = conductorResistance(std.math.hypot(track.x2 - track.x1, track.y2 - track.y1), track.width * foil),
            .current_typical_a = if (flow.typical.status == .solved) typical else null,
            .current_maximum_a = if (flow.maximum.status == .solved) maximum else null,
            .drop_typical_v = localDrop(flow.typical, route_index, false),
            .drop_maximum_v = localDrop(flow.maximum, route_index, false),
            .required_width_typical_mm = if (typical) |a| requiredTraceWidthMm(a, foil, outer) else null,
            .required_width_maximum_mm = if (maximum) |a| requiredTraceWidthMm(a, foil, outer) else null,
        });
    }
    return out.items;
}

fn analyzeVias(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    routed: router.RouteResult,
    net_index: usize,
    demand: Demand,
    flow: power_current.Result,
) std.mem.Allocator.Error![]const Via {
    var out: std.ArrayList(Via) = .empty;
    const board_mm = boardThicknessMm(placement);
    const plating_mm = placement.rules.physical.via_plating_mm;
    for (routed.vias, 0..) |via, route_index| {
        if (via.net != @as(i32, @intCast(net_index))) continue;
        const drill = if (via.drill > 0) via.drill else @max(0, via.dia - 2.0 * plating_mm);
        const area = std.math.pi * drill * plating_mm;
        const capacity = capacityForArea(area, false, temperature_rise_c);
        const typical = localCurrent(flow.typical, route_index, demand.typical_a, true);
        const maximum = localCurrent(flow.maximum, route_index, demand.maximum_a, true);
        try out.append(alloc, .{
            .route_index = route_index,
            .plating_mm = plating_mm,
            .barrel_area_mm2 = area,
            .capacity_a = capacity,
            .resistance_ohm = conductorResistance(board_mm, area),
            .current_typical_a = if (flow.typical.status == .solved) typical else null,
            .current_maximum_a = if (flow.maximum.status == .solved) maximum else null,
            .drop_typical_v = localDrop(flow.typical, route_index, true),
            .drop_maximum_v = localDrop(flow.maximum, route_index, true),
            .required_count_typical = countFor(typical, capacity),
            .required_count_maximum = countFor(maximum, capacity),
        });
    }
    return out.items;
}

fn analyzePlanes(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    net_name: []const u8,
    demand: Demand,
    surfaces: []const Surface,
) std.mem.Allocator.Error![]const Plane {
    var out: std.ArrayList(Plane) = .empty;
    const stack = placement.rules.physical.stack;
    const design_min = @max(
        @max(0, placement.rules.design.pour.min_width),
        placement.rules.powerWidthForNet(net_name) orelse 0,
    );
    for (surfaces) |surface| {
        if (!sameNet(surface.net, net_name)) continue;
        const foil = stack.foilMm(surface.physical_layer);
        const outer = surface.physical_layer == 1 or surface.physical_layer == placement.rules.layerStack().stackCount();
        const per_mm = traceCapacityA(1.0, foil, outer);
        const required_typical = if (demand.typical_a) |a| requiredTraceWidthMm(a, foil, outer) else null;
        const required_maximum = if (demand.maximum_a) |a| requiredTraceWidthMm(a, foil, outer) else null;
        try out.append(alloc, .{
            .kind = surface.kind,
            .physical_layer = surface.physical_layer,
            .foil_mm = foil,
            .component_count = surface.fill.n_comp,
            .fill_coarsened = surface.fill.coarsened,
            .design_min_width_mm = design_min,
            .capacity_a_per_mm = per_mm,
            .capacity_at_design_min_a = traceCapacityA(design_min, foil, outer),
            .required_neck_typical_mm = required_typical,
            .required_neck_maximum_mm = required_maximum,
            .typical_status = surfaceCapacityStatus(surface.fill, design_min, required_typical),
            .maximum_status = surfaceCapacityStatus(surface.fill, design_min, required_maximum),
        });
    }
    return out.items;
}

fn surfaceCapacityStatus(fill: pour.Fill, design_min: f64, required: ?f64) SurfaceCapacityStatus {
    const width = required orelse return .no_current;
    if (fill.n_comp == 0 or fill.coarsened) return .not_proven;
    if (!(design_min > 0) or design_min + geometry_eps_mm < width) return .not_proven;
    return .verified;
}

fn expectNoRequiredWidths(widths: []const ?f64) !void {
    for (widths) |width| try testing.expect(width == null);
}

fn expectRequiredWidths(widths: []const ?f64, expected: f64) !void {
    for (widths) |width| try testing.expectApproxEqAbs(expected, width.?, 1e-12);
}

/// Analyze only nets that are electrically power-like, plane-carried, or have
/// declared load current. Signal nets add no payload and pay no per-track work.
pub fn analyze(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    routed: router.RouteResult,
) std.mem.Allocator.Error!Analysis {
    return analyzeCopper(alloc, placement, routed, &.{}, null);
}

/// Maximum (or typical-only) IPC-2221 width required by each routed track's
/// solved LOCAL current. The result is index-aligned with `routed.tracks`.
/// When an opted-in power branch cannot be localized, every segment receives
/// the width for the WHOLE declared rail current instead. That remains a safe
/// ampacity upper bound without making one unresolved terminal reinstate the
/// unrelated net-class trunk width across the board. Null is reserved for nets
/// that did not explicitly opt into current-aware branch sizing.
///
/// Ordinary rails use the trace/via graph. A net that explicitly declares a
/// `power_branch_width` and has a fabricated plane or saved copper zone also
/// includes that computed sheet, allowing its short fanouts to be judged by
/// their actual local load.
pub fn routedTrackRequiredWidths(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    routed: router.RouteResult,
) std.mem.Allocator.Error![]const ?f64 {
    return routedTrackRequiredWidthsMemo(alloc, placement, routed, null);
}

/// `routedTrackRequiredWidths` with a per-fill memo for the plane surfaces it
/// needs. Its TRUE inputs are the placement and the routed copper and nothing
/// else — the zone list it passes `buildSurfaces` is empty and the shared edge
/// field is null — so every surface here is an ordinary declared plane/pour fill
/// of this board, keyed and reused exactly like any other. A null memo is the
/// unmemoised spelling, byte for byte.
pub fn routedTrackRequiredWidthsMemo(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    routed: router.RouteResult,
    memo: ?pour.FillMemo,
) std.mem.Allocator.Error![]const ?f64 {
    var needs_surfaces = false;
    for (placement.nets, 0..) |net, net_index| {
        const demand = demandFor(placement.rules.physical.rails, net.name);
        const has_demand = demand.typical_a != null or demand.maximum_a != null;
        const branch_opted = net_index < placement.rules.net.len and
            placement.rules.net[net_index].pad_neck.power_branch_width > 0;
        if (has_demand and branch_opted and router.netHasPlane(placement, net.name)) {
            needs_surfaces = true;
            break;
        }
    }
    const surfaces = if (needs_surfaces)
        try buildSurfaces(alloc, placement, routed, &.{}, null, memo)
    else
        &.{};
    return routedTrackRequiredWidthsFromSurfaces(alloc, placement, routed, surfaces);
}

/// The reporting DRC spelling: consume the exact carrying-layer and user-zone
/// fills it already computed and cached for topology/connectivity. This keeps
/// the local-current verdict tied to fabricated copper without rastering the
/// board a second time.
pub fn routedTrackRequiredWidthsPrepared(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    routed: router.RouteResult,
    plane_fills: []const pour.NetFills,
    zones: []const pour.UserZone,
    zone_fills: []const pour.Fill,
) std.mem.Allocator.Error![]const ?f64 {
    var surfaces: std.ArrayList(Surface) = .empty;
    for (plane_fills) |net_fills| {
        for (net_fills.layers, net_fills.fills) |layer, fill| try surfaces.append(alloc, .{
            .net = net_fills.net_name,
            .kind = if (layer.track_layer == null) .plane else .pour,
            .physical_layer = if (layer.stack > 0) layer.stack else if (layer.track_layer) |signal|
                placement.rules.signalStackIndex(signal)
            else
                0,
            .signal_layer = layer.track_layer,
            .fill = fill,
        });
    }
    const zone_count = @min(zones.len, zone_fills.len);
    for (zones[0..zone_count], zone_fills[0..zone_count]) |zone, fill| try surfaces.append(alloc, .{
        .net = zone.net,
        .kind = .zone,
        .physical_layer = placement.rules.signalStackIndex(zone.layer),
        .signal_layer = zone.layer,
        .fill = fill,
    });
    return routedTrackRequiredWidthsFromSurfaces(alloc, placement, routed, surfaces.items);
}

fn routedTrackRequiredWidthsFromSurfaces(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    routed: router.RouteResult,
    surfaces: []const Surface,
) std.mem.Allocator.Error![]const ?f64 {
    const required = try alloc.alloc(?f64, routed.tracks.len);
    @memset(required, null);
    for (placement.nets, 0..) |net, net_index| {
        const demand = demandFor(placement.rules.physical.rails, net.name);
        if (demand.typical_a == null and demand.maximum_a == null) continue;
        const branch_opted = net_index < placement.rules.net.len and
            placement.rules.net[net_index].pad_neck.power_branch_width > 0;
        var has_surface = false;
        if (branch_opted) for (surfaces) |surface| {
            if (sameNet(surface.net, net.name) and surface.fill.n_comp > 0) {
                has_surface = true;
                break;
            }
        };
        const flow = try solveCurrent(
            alloc,
            placement,
            routed,
            net_index,
            demand,
            if (has_surface) surfaces else &.{},
        );
        // Never substitute the smaller typical axis when a declared maximum
        // axis is unprovable (for example, because a max-only consumer is
        // disconnected). Typical is sufficient only on a typical-only rail.
        const axis = if (demand.maximum_a != null) flow.maximum else flow.typical;
        if (axis.status != .solved) {
            // A failed topology solve means we cannot divide current among
            // branches, not that IPC-2221 has no answer. For a net whose
            // author explicitly supplied `power_branch_width`, conservatively
            // charge EVERY segment with the full rail envelope. This is an
            // upper bound on any one branch and lets DRC retain the fabrication
            // minimum + branch floor instead of reverting to an often much
            // wider trunk class because one load pad was renamed or omitted.
            if (!branch_opted) continue;
            const amps = if (demand.maximum_a != null) demand.maximum_a else demand.typical_a;
            for (routed.tracks, 0..) |track, route_index| {
                if (track.net != @as(i32, @intCast(net_index))) continue;
                const physical = placement.rules.signalStackIndex(track.layer);
                const foil = placement.rules.physical.stack.foilMm(physical);
                const outer = physical == 1 or physical == placement.rules.layerStack().stackCount();
                required[route_index] = requiredTraceWidthMm(amps.?, foil, outer);
            }
            continue;
        }
        for (routed.tracks, 0..) |track, route_index| {
            if (track.net != @as(i32, @intCast(net_index))) continue;
            const amps = axis.track_current_a[route_index];
            if (!std.math.isFinite(amps) or amps < 0) continue;
            if (amps == 0) {
                required[route_index] = 0;
                continue;
            }
            const physical = placement.rules.signalStackIndex(track.layer);
            const foil = placement.rules.physical.stack.foilMm(physical);
            const outer = physical == 1 or physical == placement.rules.layerStack().stackCount();
            required[route_index] = requiredTraceWidthMm(amps, foil, outer);
        }
    }
    return required;
}

/// Analyze routed copper together with the exact saved user pours and the
/// render's shared fill edge field. Every clearance-carved kept component is
/// included in connectivity; sheet capacity is proven only when the board's
/// enforced pour-min-width meets the required full-rail neck width.
pub fn analyzeCopper(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    routed: router.RouteResult,
    zones: []const pour.UserZone,
    base_edge: ?pour.EdgeField,
) std.mem.Allocator.Error!Analysis {
    const surfaces = try buildSurfaces(alloc, placement, routed, zones, base_edge, null);
    var nets: std.ArrayList(Net) = .empty;
    for (placement.nets, 0..) |net, net_index| {
        const demand = demandFor(placement.rules.physical.rails, net.name);
        if (!isPowerNet(placement, net_index, demand)) continue;
        const flow = try solveCurrent(alloc, placement, routed, net_index, demand, surfaces);
        const tracks = try analyzeTracks(alloc, placement, routed, net_index, demand, flow);
        const vias = try analyzeVias(alloc, placement, routed, net_index, demand, flow);
        const planes = try analyzePlanes(alloc, placement, net.name, demand, surfaces);
        if (tracks.len == 0 and vias.len == 0 and planes.len == 0) continue;
        try nets.append(alloc, .{
            .index = net_index,
            .name = net.name,
            .demand = demand,
            .typical_status = flow.typical.status,
            .maximum_status = flow.maximum.status,
            .tracks = tracks,
            .vias = vias,
            .planes = planes,
        });
    }
    return .{ .nets = nets.items };
}

const testing = std.testing;

test "trace capacity uses actual foil and outer versus inner coefficient" {
    const outer = traceCapacityA(0.30, 0.035, true);
    const inner = traceCapacityA(0.30, 0.035, false);
    try testing.expectApproxEqAbs(@as(f64, 1.0), outer, 0.03);
    try testing.expectApproxEqAbs(outer / 2.0, inner, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.30), requiredTraceWidthMm(outer, 0.035, true).?, 1e-12);
}

test "via barrel capacity and required parallel count" {
    const area = std.math.pi * 0.30 * env.default_via_plating_mm;
    const cap = capacityForArea(area, false, temperature_rise_c);
    try testing.expect(cap > 0.7 and cap < 1.2);
    try testing.expectEqual(@as(?usize, 3), countFor(cap * 2.1, cap));
    try testing.expectEqual(@as(?usize, null), countFor(null, cap));
}

test "missing current leaves required geometry unknown" {
    try testing.expectEqual(@as(?f64, null), requiredTraceWidthMm(0, 0.035, true));
    try testing.expectEqual(@as(?usize, null), countFor(null, 1));
}

test "surface capacity is proven only by an enforced sufficient minimum width" {
    const fill = pour.Fill{
        .frame = .{ .minx = 0, .miny = 0, .pitch = 0.1, .nx = 1, .ny = 1 },
        .labels = &.{0},
        .n_comp = 1,
        .contours = &.{},
        .holes = &.{},
        .coarsened = false,
    };
    try testing.expectEqual(SurfaceCapacityStatus.no_current, surfaceCapacityStatus(fill, 0.4, null));
    try testing.expectEqual(SurfaceCapacityStatus.not_proven, surfaceCapacityStatus(fill, 0.2, 0.4));
    try testing.expectEqual(SurfaceCapacityStatus.verified, surfaceCapacityStatus(fill, 0.4, 0.4));
    var coarse = fill;
    coarse.coarsened = true;
    try testing.expectEqual(SurfaceCapacityStatus.not_proven, surfaceCapacityStatus(coarse, 1.0, 0.4));
}

test "exact hierarchical rail demand wins over a same-leaf fallback" {
    const rails = [_]power_budget.Rail{
        .{ .net = "other/VDD", .load_max_a = 4, .any_max_load = true, .status = .no_source },
        .{ .net = "radio/VDD", .load_max_a = 0.4, .any_max_load = true, .status = .no_source },
    };
    try testing.expectEqual(@as(?f64, 0.4), demandFor(&rails, "radio/VDD").maximum_a);
}

test "ambiguous hierarchical rail leaves do not invent route current" {
    const rails = [_]power_budget.Rail{
        .{ .net = "radio_a/VDD", .load_max_a = 0.4, .any_max_load = true, .status = .no_source },
        .{ .net = "radio_b/VDD", .load_max_a = 4, .any_max_load = true, .status = .no_source },
    };
    try testing.expectEqual(@as(?f64, null), demandFor(&rails, "VDD").maximum_a);
}

test "analysis joins routed geometry to stack foil rail load and declared plane" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const rails = [_]power_budget.Rail{.{
        .net = "VDD",
        .load_typ_a = 1.0,
        .load_max_a = 2.0,
        .any_typ_load = true,
        .any_max_load = true,
        .status = .no_source,
    }};
    const planes = [_]optimizer.PlaneAt{.{ .index = 2, .net = "VDD" }};
    const plane_indices = [_]u8{2};
    const foils = [_]@import("impedance.zig").Foil{
        .{ .index = 1, .thickness_mm = 0.035 },
        .{ .index = 2, .thickness_mm = 0.0152 },
        .{ .index = 6, .thickness_mm = 0.035 },
    };
    const nets = [_]optimizer.FlatNet{.{ .name = "VDD", .pins = &.{} }};
    const placement = optimizer.Placement{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 10,
        .maxy = 10,
        .generated = true,
        .rules = .{
            .plane_nets = &.{"VDD"},
            .copper_layers = 6,
            .planes = .{ .declared = &planes },
            .physical = .{
                .board_thickness = 1.6,
                .via_plating_mm = 0.020,
                .stack = .{ .layers = 6, .planes = &plane_indices, .foils = &foils, .board_mm = 1.6 },
                .rails = &rails,
            },
        },
    };
    const tracks = [_]router.Track{.{ .x1 = 0, .y1 = 0, .x2 = 10, .y2 = 0, .layer = 0, .width = 0.2532, .net = 0 }};
    const vias = [_]router.Via{.{ .x = 10, .y = 0, .dia = 0.5, .drill = 0.3, .net = 0 }};
    const result = router.RouteResult{ .tracks = &tracks, .vias = &vias, .routed = 1, .total = 1 };

    const screened = try analyze(arena_inst.allocator(), placement, result);
    try testing.expectEqual(@as(usize, 1), screened.nets.len);
    const net = screened.nets[0];
    try testing.expectEqual(@as(?f64, 2.0), net.demand.maximum_a);
    try testing.expectEqual(@as(usize, 1), net.tracks.len);
    try testing.expectEqual(@as(u8, 1), net.tracks[0].physical_layer);
    try testing.expectEqual(@as(f64, 0.035), net.tracks[0].foil_mm);
    try testing.expect(net.tracks[0].required_width_maximum_mm.? > tracks[0].width);
    try testing.expectEqual(@as(f64, 0.020), net.vias[0].plating_mm);
    try testing.expectEqual(@as(?usize, 3), net.vias[0].required_count_maximum);
    try testing.expectEqual(@as(u8, 2), net.planes[0].physical_layer);
    try testing.expectEqual(@as(f64, 0.0152), net.planes[0].foil_mm);
    try testing.expect(net.planes[0].required_neck_maximum_mm.? > 1.0);
}

// spec: placement/power-routing - a solved plane-aware rail exposes an index-aligned required width for each local-current branch, while an incomplete opted-in rail screens every segment at the whole-rail current
test "analysis assigns split branch currents and required widths from physical source and load pads" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const pad = @import("geometry.zig").Pad{ .number = "1", .x = 0, .y = 0, .w = 0.2, .h = 0.2 };
    const parts = [_]optimizer.Part{
        .{ .ref_des = "src/U1", .kind = .hub, .hw = 0.1, .hh = 0.1, .pads = &.{pad}, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "load_a/U1", .kind = .hub, .hw = 0.1, .hh = 0.1, .pads = &.{pad}, .fallback = false, .x = 2, .y = 1 },
        .{ .ref_des = "load_b/U1", .kind = .hub, .hw = 0.1, .hh = 0.1, .pads = &.{pad}, .fallback = false, .x = 2, .y = -1 },
    };
    const pins = [_]@import("../flat_netlist.zig").FlatPin{
        .{ .ref_des = "src/U1", .pin = "1" },
        .{ .ref_des = "load_a/U1", .pin = "1" },
        .{ .ref_des = "load_b/U1", .pin = "1" },
    };
    const consumers = [_]power_budget.RailConsumer{
        .{ .ref_des = "load_a/U1", .net = "VDD", .pins = &.{"1"}, .i_typ = 0.8, .i_max = 0.8 },
        .{ .ref_des = "load_b/U1", .net = "VDD", .pins = &.{"1"}, .i_typ = 0.2, .i_max = 0.2 },
    };
    const rails = [_]power_budget.Rail{.{
        .net = "VDD",
        .source_terminals = &.{"src/VOUT"},
        .load_typ_a = 1,
        .load_max_a = 1,
        .any_typ_load = true,
        .any_max_load = true,
        .status = .no_source,
        .consumers = &consumers,
    }};
    const nets = [_]optimizer.FlatNet{.{ .name = "VDD", .pins = &pins }};
    const foils = [_]@import("impedance.zig").Foil{.{ .index = 1, .thickness_mm = 0.035 }};
    const planes = [_]optimizer.PlaneAt{.{ .index = 2, .net = "VDD" }};
    const net_rules = [_]optimizer.NetRule{.{ .width = 0.3048, .pad_neck = .{ .power_branch_width = 0.1524 } }};
    const placement = optimizer.Placement{
        .parts = @constCast(&parts),
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = -1,
        .maxx = 2,
        .maxy = 1,
        .generated = true,
        .rules = .{
            .plane_nets = &.{"VDD"},
            .net = &net_rules,
            .copper_layers = 2,
            .planes = .{ .declared = &planes },
            .physical = .{ .stack = .{ .layers = 2, .foils = &foils }, .rails = &rails },
        },
    };
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 0, .layer = 0, .width = 0.3, .net = 0 },
        .{ .x1 = 1, .y1 = 0, .x2 = 2, .y2 = 1, .layer = 0, .width = 0.3, .net = 0 },
        .{ .x1 = 1, .y1 = 0, .x2 = 2, .y2 = -1, .layer = 0, .width = 0.3, .net = 0 },
    };
    const routed = router.RouteResult{ .tracks = &tracks, .vias = &.{}, .routed = 1, .total = 1 };

    const result = try analyze(arena_inst.allocator(), placement, routed);
    try testing.expectEqual(power_current.Status.solved, result.nets[0].typical_status);
    try testing.expectApproxEqAbs(@as(f64, 1), result.nets[0].tracks[0].current_typical_a.?, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.8), result.nets[0].tracks[1].current_typical_a.?, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.2), result.nets[0].tracks[2].current_typical_a.?, 1e-9);
    try testing.expect(result.nets[0].tracks[2].required_width_typical_mm.? < result.nets[0].tracks[1].required_width_typical_mm.?);

    const widths = try routedTrackRequiredWidths(arena_inst.allocator(), placement, routed);
    try testing.expectEqual(@as(usize, tracks.len), widths.len);
    try testing.expect(widths[0].? > widths[1].?);
    try testing.expect(widths[1].? > widths[2].?);
    try testing.expect(widths[2].? < 0.1524);

    var incomplete = rails[0];
    incomplete.source_terminals = &.{"missing/VOUT"};
    var incomplete_placement = placement;
    incomplete_placement.rules.physical.rails = &.{incomplete};
    const conservative = try routedTrackRequiredWidths(arena_inst.allocator(), incomplete_placement, routed);
    const whole_rail_width = requiredTraceWidthMm(1, 0.035, true).?;
    try expectRequiredWidths(conservative, whole_rail_width);

    var unopted_rules = net_rules;
    unopted_rules[0].pad_neck.power_branch_width = 0;
    var unopted_placement = incomplete_placement;
    unopted_placement.rules.net = &unopted_rules;
    try expectNoRequiredWidths(try routedTrackRequiredWidths(arena_inst.allocator(), unopted_placement, routed));

    const max_only_consumers = [_]power_budget.RailConsumer{
        .{ .ref_des = "load_a/U1", .net = "VDD", .pins = &.{"1"}, .i_typ = 0.8, .i_max = 0.8 },
        .{ .ref_des = "load_b/U1", .net = "VDD", .pins = &.{"1"}, .i_typ = null, .i_max = 0.2 },
    };
    var max_incomplete = rails[0];
    max_incomplete.consumers = &max_only_consumers;
    var max_incomplete_placement = placement;
    max_incomplete_placement.rules.physical.rails = &.{max_incomplete};
    var max_incomplete_routed = routed;
    max_incomplete_routed.tracks = tracks[0..2];
    const max_conservative = try routedTrackRequiredWidths(arena_inst.allocator(), max_incomplete_placement, max_incomplete_routed);
    try expectRequiredWidths(max_conservative, whole_rail_width);

    // The same source and loads joined only through a saved user zone are
    // unsolved in the zone-blind spelling, then become locally measurable when
    // reporting DRC supplies its already-computed fabricated fill.
    var zone_placement = placement;
    zone_placement.rules.planes = .{};
    zone_placement.rules.plane_nets = &.{};
    const zone_tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 0.8, .y2 = 0, .layer = 0, .width = 0.1524, .net = 0 },
        .{ .x1 = 1.2, .y1 = 0, .x2 = 2, .y2 = 1, .layer = 0, .width = 0.1524, .net = 0 },
        .{ .x1 = 1.2, .y1 = 0, .x2 = 2, .y2 = -1, .layer = 0, .width = 0.1524, .net = 0 },
    };
    const zone_routed = router.RouteResult{ .tracks = &zone_tracks, .vias = &.{}, .routed = 1, .total = 1 };
    try expectRequiredWidths(
        try routedTrackRequiredWidths(arena_inst.allocator(), zone_placement, zone_routed),
        whole_rail_width,
    );
    const zone_poly = [_][2]f64{ .{ 0.5, -0.5 }, .{ 1.5, -0.5 }, .{ 1.5, 0.5 }, .{ 0.5, 0.5 } };
    const zones = [_]pour.UserZone{.{ .net = "VDD", .layer = 0, .poly = &zone_poly }};
    const labels: [100]i32 = @splat(0);
    const zone_fill = pour.Fill{
        .frame = .{ .minx = 0.5, .miny = -0.5, .pitch = 0.1, .nx = 10, .ny = 10 },
        .labels = &labels,
        .n_comp = 1,
        .contours = &.{},
        .holes = &.{},
        .coarsened = false,
    };
    const zone_widths = try routedTrackRequiredWidthsPrepared(
        arena_inst.allocator(),
        zone_placement,
        zone_routed,
        &.{},
        &zones,
        &.{zone_fill},
    );
    try testing.expect(zone_widths[0] != null);
    try testing.expect(zone_widths[1] != null);
    try testing.expect(zone_widths[2] != null);
}

test "external power source terminals resolve only top-level connector pads" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const alloc = arena_inst.allocator();
    const pad = @import("geometry.zig").Pad{ .number = "1", .x = 0, .y = 0, .w = 0.2, .h = 0.2 };
    const parts = [_]optimizer.Part{
        .{ .ref_des = "J1", .kind = .hub, .hw = 0.1, .hh = 0.1, .pads = &.{pad}, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "U1", .kind = .hub, .hw = 0.1, .hh = 0.1, .pads = &.{pad}, .fallback = false, .x = 2, .y = 0 },
        .{ .ref_des = "child/J2", .kind = .hub, .hw = 0.1, .hh = 0.1, .pads = &.{pad}, .fallback = false, .x = 4, .y = 0 },
    };
    const pins = [_]@import("../flat_netlist.zig").FlatPin{
        .{ .ref_des = "J1", .pin = "1" },
        .{ .ref_des = "U1", .pin = "1" },
        .{ .ref_des = "child/J2", .pin = "1" },
    };
    const nets = [_]optimizer.FlatNet{.{ .name = "VDD", .pins = &pins }};
    const placement = optimizer.Placement{
        .parts = @constCast(&parts),
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 4,
        .maxy = 1,
        .generated = true,
        .rules = .{},
    };

    const contacts = try sourceContacts(alloc, placement, 0, &.{"@external/VDD"});
    try testing.expectEqual(@as(usize, 1), contacts.len);
    try testing.expectApproxEqAbs(@as(f64, 0), contacts[0].at[0], 1e-9);
}
