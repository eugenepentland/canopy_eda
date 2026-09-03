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
const net_graph = @import("net_graph.zig");
const pour = @import("pour.zig");
const implicit_plane = @import("implicit_plane.zig");
const power_capacity = @import("power_capacity.zig");
const net_identity = @import("net_identity.zig");
const flat_netlist = @import("../flat_netlist.zig");

/// Temperature-rise target used by the continuous-current screen.
pub const temperature_rise_c: f64 = power_capacity.temperature_rise_c;
/// Legacy default for callers that inspect the model without a board. Actual
/// analyses use the board's resolved `(via-plating MM)` value.
pub const via_plating_mm: f64 = env.default_via_plating_mm;
/// Copper resistivity used for the room-temperature voltage-drop estimate.
const copper_resistivity_ohm_m: f64 = 1.724e-8;
const geometry_eps_mm: f64 = 1e-6;

/// The width one routed track needs for the current it actually carries, and
/// how well that current is known.
///
/// A DRC consumer needs both halves: `envelope=false` is a solved branch
/// current and is the whole answer for that segment, while `envelope=true` is
/// the entire rail's current charged to a single segment because the topology
/// solve did not complete. The latter is a safe ampacity upper bound but a
/// poor explanation, so `reason` carries the machine-stable
/// `power_current.Status` name that caused it.
pub const LocalWidth = struct {
    /// IPC-2221 width for this track's own current on its own layer.
    width_mm: f64,
    /// true when the solve did not complete and `width_mm` is the whole-rail
    /// envelope (or a partial-solve bound) rather than a solved branch current.
    envelope: bool,
    /// Stable machine reason when envelope=true (the power_current status name,
    /// e.g. "no-source-terminal", "incomplete-load-terminals", "disconnected"),
    /// "" when solved.
    reason: []const u8 = "",
};

/// One rail's copper as the board actually fabricates it: a flattened net plus
/// every per-pin bypass stub renamed off it.
///
/// `(decouple … per-pin …)` deliberately splits a rail into `<rail>.<IC>.<pad>`
/// connection nets (`design_block.zig`), so an 18-pin consumer can have three
/// pins on the rail proper and fifteen on stubs. Nothing about that split is
/// physical: `net_identity.Identity` proves the alias from the bypass loop
/// itself, and every screen here reads the family, not the flattened net. A
/// rail screened without its stubs reports incomplete load terminals and falls
/// back to the whole-rail envelope on all of its copper.
const Family = struct {
    /// Canonical owner net index — the rail every member aliases.
    root: usize,
    /// `root` first, then each proven stub, as flattened net indices.
    members: []const usize,
    /// Every member's pins, concatenated.
    pins: []const flat_netlist.FlatPin,
    /// The root's flattened name; the name planes and demands are keyed on.
    name: []const u8,

    /// True when a routed track/via net index belongs to this rail's copper.
    fn has(self: Family, net: i32) bool {
        if (net < 0) return false;
        const i: usize = @intCast(net);
        for (self.members) |member| if (member == i) return true;
        return false;
    }
};

fn familyFor(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    identity: net_identity.Identity,
    root: usize,
) std.mem.Allocator.Error!Family {
    const members = try identity.familyOf(alloc, root);
    if (members.len == 1) return .{
        .root = root,
        .members = members,
        .pins = placement.nets[root].pins,
        .name = placement.nets[root].name,
    };
    var pins: std.ArrayList(flat_netlist.FlatPin) = .empty;
    for (members) |member| try pins.appendSlice(alloc, placement.nets[member].pins);
    return .{ .root = root, .members = members, .pins = pins.items, .name = placement.nets[root].name };
}

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

/// Top-level connector pads on this rail. The board's own boundary power ports
/// name no reference designator, so the convention is the designator prefix:
/// J/P/X are the parts a rail physically enters or leaves the board through.
/// Selecting every top-level hub instead would turn IC loads on the same rail
/// into parallel voltage sources.
fn boundaryContacts(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    family: Family,
    out: *std.ArrayList(power_current.Contact),
) std.mem.Allocator.Error!void {
    for (family.pins) |pin| {
        if (std.mem.indexOfScalar(u8, pin.ref_des, '/') != null or pin.ref_des.len == 0) continue;
        const prefix = std.ascii.toUpper(pin.ref_des[0]);
        if (prefix != 'J' and prefix != 'P' and prefix != 'X') continue;
        if (contactForPin(placement, pin)) |contact| try appendContact(alloc, out, contact);
    }
}

fn sourceContacts(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    family: Family,
    terminals: []const []const u8,
) std.mem.Allocator.Error![]const power_current.Contact {
    var out: std.ArrayList(power_current.Contact) = .empty;
    for (terminals) |path| {
        // External board power enters through top-level connector pads on the
        // declared port net.
        if (std.mem.startsWith(u8, path, "@external/")) {
            try boundaryContacts(alloc, placement, family, &out);
            continue;
        }
        const prefix = net_names.parent(path) orelse continue;
        for (family.pins) |pin| {
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
    family: Family,
    consumer: power_budget.RailConsumer,
) std.mem.Allocator.Error!struct { contacts: []const power_current.Contact, complete: bool } {
    var out: std.ArrayList(power_current.Contact) = .empty;
    // A rail exported off the board leaves through its top-level connector
    // pads, which is where `power_budget` points this synthetic consumer.
    if (std.mem.startsWith(u8, consumer.ref_des, power_budget.export_terminal_prefix)) {
        try boundaryContacts(alloc, placement, family, &out);
        return .{ .contacts = out.items, .complete = out.items.len > 0 };
    }
    var exact_ref = false;
    for (family.pins) |pin| if (std.mem.eql(u8, pin.ref_des, consumer.ref_des)) {
        exact_ref = true;
        break;
    };
    if (exact_ref) {
        var complete = true;
        for (consumer.pins) |wanted_pin| {
            var found = false;
            for (family.pins) |pin| {
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

    if (sameNet(family.name, consumer.net)) try scopedContacts(alloc, placement, family, consumer, &out);
    if (out.items.len == 0) try bridgedContacts(alloc, placement, family, consumer, &out);
    return .{ .contacts = out.items, .complete = out.items.len > 0 };
}

/// Contacts for a sub-block-keyed consumer on this net.
///
/// Back-computed regulator input loads and declared module-port loads are
// keyed on a sub-block port rather than a physical ref-des. Its hub device
// pads on this flattened net are the physical load contacts. A port whose
// module-side net reaches only a filter (a choke, a bead, a series
/// resistor) before the consuming IC has no hub pad on this net at all;
/// the current still leaves the board copper at those passive pads, so
/// they are the contacts when no hub pad exists.
fn scopedContacts(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    family: Family,
    consumer: power_budget.RailConsumer,
    out: *std.ArrayList(power_current.Contact),
) std.mem.Allocator.Error!void {
    const scope = net_names.parent(consumer.ref_des) orelse consumer.ref_des;
    for (family.pins) |pin| {
        if (!descendantOf(pin.ref_des, scope)) continue;
        const part = partForRef(placement, pin.ref_des) orelse continue;
        if (part.kind != .hub) continue;
        if (contactForPin(placement, pin)) |contact| try appendContact(alloc, out, contact);
    }
    if (out.items.len == 0) for (family.pins) |pin| {
        if (!descendantOf(pin.ref_des, scope)) continue;
        if (contactForPin(placement, pin)) |contact| try appendContact(alloc, out, contact);
    };
}

/// How many two-terminal series parts a load may sit behind before this screen
/// gives up on locating where its current leaves the rail.
///
/// Four, because that is the deepest real filter chain the design corpus has:
/// a shared input choke, a per-rail ferrite, a per-pin bead, and a jumper or
/// 0 Ω link is already four, and `straps-synth-lmx2595` uses three of them. The
/// walk is bounded rather than unbounded because a rail's copper is a graph,
/// not a tree: without a depth (and node) budget one decoupling network can
/// reach most of the board through parts that are not the supply path at all.
const series_walk_depth: usize = 4;
/// Nets one walk may visit before it stops. A blast radius, not a tuning knob:
/// a real supply chain visits a handful.
const series_walk_nets: usize = 64;

/// Contacts for a consumer whose annotated pad sits on a DOWNSTREAM net reached
/// from this one through two-terminal series parts (a ferrite bead, an
/// inductor, a jumper, a 0 Ω link). The power budget already rolled that load
/// up onto this rail through the same parts — the union-find in
/// `net_analysis.buildFerriteBridges` is the schematic-side statement of the
/// same fact — so physically the current leaves this net's copper at the FIRST
/// part's pad here, whatever the chain does downstream. That pad is the load
/// contact.
///
/// The walk descends up to `series_walk_depth` parts. Ground is never entered:
/// every decoupling capacitor on the rail is a two-terminal non-hub part whose
/// far pad is GND, and following those turns a bounded supply-path walk into a
/// traversal of the whole board.
fn bridgedContacts(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    family: Family,
    consumer: power_budget.RailConsumer,
    out: *std.ArrayList(power_current.Contact),
) std.mem.Allocator.Error!void {
    // One walk step: the net reached, and the rail-side pad the path left
    // through. The pad is what this function ultimately answers with, so it
    // rides along instead of being recovered by a parent walk.
    const Hop = struct { net: usize, exit: usize };
    var frontier: std.ArrayList(Hop) = .empty;
    var seen: std.ArrayList(Hop) = .empty;

    for (family.pins, 0..) |pin, exit| {
        const far_net = seriesFarNet(placement, pin) orelse continue;
        if (family.has(@intCast(far_net))) continue;
        try frontier.append(alloc, .{ .net = far_net, .exit = exit });
    }

    var depth: usize = 0;
    while (depth < series_walk_depth and frontier.items.len > 0) : (depth += 1) {
        var next: std.ArrayList(Hop) = .empty;
        for (frontier.items) |hop| {
            if (seen.items.len >= series_walk_nets) break;
            var repeat = false;
            for (seen.items) |old| if (old.net == hop.net and old.exit == hop.exit) {
                repeat = true;
                break;
            };
            if (repeat) continue;
            try seen.append(alloc, hop);
            // Ground is a sink shared by the whole board, never a supply hop.
            if (module_policy.classifyNetName(placement.nets[hop.net].name) == .ground) continue;
            if (netCarriesConsumer(placement, hop.net, consumer)) {
                if (contactForPin(placement, family.pins[hop.exit])) |contact| try appendContact(alloc, out, contact);
                continue;
            }
            for (placement.nets[hop.net].pins) |pin| {
                const far_net = seriesFarNet(placement, pin) orelse continue;
                if (far_net == hop.net or family.has(@intCast(far_net))) continue;
                try next.append(alloc, .{ .net = far_net, .exit = hop.exit });
            }
        }
        frontier = next;
    }
}

/// A two-terminal series element in a supply path — a bead, an inductor, a
/// jumper, a 0 Ω link. A CAPACITOR is excluded by role, not by heuristic: it
/// passes no continuous current, so it can never be a DC supply hop however it
/// is wired. That exclusion is also what keeps the walk bounded, since every
/// decoupling cap on a rail is otherwise a two-terminal non-hub part inviting a
/// traversal through ground and out across the whole board.
fn seriesElement(part: optimizer.Part) bool {
    if (part.kind == .hub or part.pads.len != 2) return false;
    const leaf = net_names.leaf(part.ref_des);
    return leaf.len > 0 and std.ascii.toUpper(leaf[0]) != 'C';
}

/// The flattened net on the far side of the series part `pin` belongs to.
fn seriesFarNet(placement: optimizer.Placement, pin: flat_netlist.FlatPin) ?usize {
    const part = partForRef(placement, pin.ref_des) orelse return null;
    if (!seriesElement(part.*)) return null;
    const far_pad = if (std.mem.eql(u8, part.pads[0].number, pin.pin)) part.pads[1] else part.pads[0];
    return netIndexOfPad(placement, pin.ref_des, far_pad.number);
}

/// The flattened net a pad sits on, by reference designator and pad number.
fn netIndexOfPad(placement: optimizer.Placement, ref_des: []const u8, pad_number: []const u8) ?usize {
    for (placement.nets, 0..) |net, index| {
        for (net.pins) |pin| {
            if (std.mem.eql(u8, pin.ref_des, ref_des) and std.mem.eql(u8, pin.pin, pad_number)) return index;
        }
    }
    return null;
}

/// True when `net_index` holds the consumer's own annotated pad, or a hub pad
/// of the sub-block a port-keyed consumer names.
fn netCarriesConsumer(placement: optimizer.Placement, net_index: usize, consumer: power_budget.RailConsumer) bool {
    const scope = net_names.parent(consumer.ref_des) orelse consumer.ref_des;
    for (placement.nets[net_index].pins) |pin| {
        if (std.mem.eql(u8, pin.ref_des, consumer.ref_des)) {
            for (consumer.pins) |wanted| if (std.mem.eql(u8, pin.pin, wanted)) return true;
            continue;
        }
        if (!descendantOf(pin.ref_des, scope)) continue;
        const part = partForRef(placement, pin.ref_des) orelse continue;
        if (part.kind == .hub) return true;
    }
    return false;
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

/// The equipotential sheets one rail's copper reaches, plus the routed
/// conductors that touch each surface. The touch lists are what lets a solved
/// plane report the current actually entering it instead of the whole rail's.
const SheetSet = struct {
    sheets: []const power_current.Sheet = &.{},
    /// Index-aligned with the `surfaces` slice it was built from: the route
    /// indices of this rail's tracks and vias landing on that surface.
    touch: []const Touch = &.{},

    const Touch = struct { tracks: []const usize = &.{}, vias: []const usize = &.{} };
};

/// The poured copper one rail is screened against: the board's computed
/// surfaces and this rail's own contact with them. They are built together,
/// index-aligned, and never meaningful apart.
const Poured = struct {
    surfaces: []const Surface = &.{},
    sheets: SheetSet = .{},
};

fn pourFor(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    routed: router.RouteResult,
    family: Family,
    surfaces: []const Surface,
) std.mem.Allocator.Error!Poured {
    return .{ .surfaces = surfaces, .sheets = try sheetsForNet(alloc, placement, routed, family, surfaces) };
}

fn sheetsForNet(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    routed: router.RouteResult,
    family: Family,
    surfaces: []const Surface,
) std.mem.Allocator.Error!SheetSet {
    var out: std.ArrayList(power_current.Sheet) = .empty;
    const touch = try alloc.alloc(SheetSet.Touch, surfaces.len);
    @memset(touch, .{});
    for (surfaces, 0..) |surface, surface_index| {
        if (!sameNet(surface.net, family.name) or surface.fill.n_comp == 0) continue;
        const contacts = try alloc.alloc(std.ArrayList([2]f64), surface.fill.n_comp);
        for (contacts) |*component| component.* = .empty;
        var touched_tracks: std.ArrayList(usize) = .empty;
        var touched_vias: std.ArrayList(usize) = .empty;

        if (surface.signal_layer) |layer| for (routed.tracks, 0..) |track, route_index| {
            if (!family.has(track.net) or track.layer != layer) continue;
            const hits = try surface.fill.segmentContacts(alloc, track.x1, track.y1, track.x2, track.y2);
            if (hits.len > 0) try touched_tracks.append(alloc, route_index);
            for (hits) |hit| try appendPoint(alloc, &contacts[@intCast(hit.component)], hit.at);
        };
        for (routed.vias, 0..) |via, route_index| {
            if (!family.has(via.net)) continue;
            const component = surface.fill.componentAt(via.x, via.y);
            if (component < 0) continue;
            try touched_vias.append(alloc, route_index);
            try appendPoint(alloc, &contacts[@intCast(component)], .{ via.x, via.y });
        }
        for (family.pins) |pin| {
            const contact = contactForPin(placement, pin) orelse continue;
            if (contact.layer) |layer| {
                if (surface.signal_layer == null or surface.signal_layer.? != layer) continue;
            }
            const component = surface.fill.componentAt(contact.at[0], contact.at[1]);
            if (component >= 0) try appendPoint(alloc, &contacts[@intCast(component)], contact.at);
        }
        touch[surface_index] = .{ .tracks = touched_tracks.items, .vias = touched_vias.items };
        for (contacts) |component| if (component.items.len > 0) try out.append(alloc, .{
            .layer = sheetLayer(surface),
            .contacts = component.items,
        });
    }
    return .{ .sheets = out.items, .touch = touch };
}

fn solveCurrent(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    routed: router.RouteResult,
    family: Family,
    demand: Demand,
    poured: Poured,
) std.mem.Allocator.Error!power_current.Result {
    const plating_mm = placement.rules.physical.via_plating_mm;
    var segments: std.ArrayList(power_current.Segment) = .empty;
    for (routed.tracks, 0..) |track, route_index| {
        if (!family.has(track.net)) continue;
        const foil = placement.rules.physical.stack.foilMm(placement.rules.signalStackIndex(track.layer));
        const area = track.width * foil;
        try segments.append(alloc, .{
            .route_index = route_index,
            .a = .{ track.x1, track.y1 },
            .b = .{ track.x2, track.y2 },
            .layer = track.layer,
            .resistance_ohm_per_mm = if (area > 0) copper_resistivity_ohm_m * 1000.0 / area else 0,
            .width_mm = track.width,
        });
    }
    var barrels: std.ArrayList(power_current.Barrel) = .empty;
    for (routed.vias, 0..) |via, route_index| {
        if (!family.has(via.net)) continue;
        const drill = if (via.drill > 0) via.drill else @max(0, via.dia - 2.0 * plating_mm);
        const area = std.math.pi * drill * plating_mm;
        try barrels.append(alloc, .{
            .route_index = route_index,
            .at = .{ via.x, via.y },
            .resistance_ohm = conductorResistance(boardThicknessMm(placement), area),
            .radius_mm = via.dia / 2,
        });
    }
    const sources = try sourceContacts(alloc, placement, family, demand.source_terminals);
    const loads = try alloc.alloc(power_current.Load, demand.consumers.len);
    for (demand.consumers, 0..) |consumer, i| {
        const resolved = try loadContacts(alloc, placement, family, consumer);
        loads[i] = .{
            .contacts = resolved.contacts,
            .typical_a = consumer.i_typ,
            .maximum_a = consumer.i_max,
            .complete = resolved.complete,
        };
    }
    var flow: power_current.Input = .{
        .segments = segments.items,
        .barrels = barrels.items,
        .sheets = poured.sheets.sheets,
        .counts = .{ .tracks = routed.tracks.len, .vias = routed.vias.len },
        .source = .{ .contacts = sources, .complete = sources.len > 0 },
        .loads = loads,
    };
    // The solver's own centreline snapping is tighter than the fabrication
    // contact policy DRC topology uses, so hand it the canonical junctions —
    // but only for a net that will actually be solved, since that sweep is
    // quadratic in the net's copper and ground would pay it for nothing.
    if (power_current.needsGraph(flow)) flow.joins = try net_graph.joinsFor(alloc, flow);
    return power_current.solve(alloc, flow);
}

fn localCurrent(axis: power_current.Axis, route_index: usize, fallback: ?f64, via: bool) ?f64 {
    if (!axis.status.isSolved()) return fallback;
    const local = if (via) axis.via_current_a[route_index] else axis.track_current_a[route_index];
    // A partial solve leaves the dropped loads' feeders at zero amps. Those are
    // precisely the conductors whose current this solve does NOT know, so they
    // keep the conservative whole-rail envelope rather than reporting nothing.
    if (axis.status == .solved_partial and !(local > 0)) return fallback;
    return local;
}

/// The current this solve actually KNOWS for one conductor, as opposed to the
/// current to screen it at (`localCurrent`, which substitutes the envelope).
/// A partial solve knows nothing about the conductors it left at zero amps.
fn solvedCurrent(axis: power_current.Axis, route_index: usize, via: bool) ?f64 {
    if (!axis.status.isSolved()) return null;
    const local = if (via) axis.via_current_a[route_index] else axis.track_current_a[route_index];
    if (axis.status == .solved_partial and !(local > 0)) return null;
    return local;
}

fn localDrop(axis: power_current.Axis, route_index: usize, via: bool) ?f64 {
    if (!axis.status.isSolved()) return null;
    return if (via) axis.via_drop_v[route_index] else axis.track_drop_v[route_index];
}

fn analyzeTracks(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    routed: router.RouteResult,
    family: Family,
    demand: Demand,
    flow: power_current.Result,
) std.mem.Allocator.Error![]const Track {
    var out: std.ArrayList(Track) = .empty;
    for (routed.tracks, 0..) |track, route_index| {
        if (!family.has(track.net)) continue;
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
            .current_typical_a = solvedCurrent(flow.typical, route_index, false),
            .current_maximum_a = solvedCurrent(flow.maximum, route_index, false),
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
    family: Family,
    demand: Demand,
    flow: power_current.Result,
) std.mem.Allocator.Error![]const Via {
    var out: std.ArrayList(Via) = .empty;
    const board_mm = boardThicknessMm(placement);
    const plating_mm = placement.rules.physical.via_plating_mm;
    for (routed.vias, 0..) |via, route_index| {
        if (!family.has(via.net)) continue;
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
            .current_typical_a = solvedCurrent(flow.typical, route_index, true),
            .current_maximum_a = solvedCurrent(flow.maximum, route_index, true),
            .drop_typical_v = localDrop(flow.typical, route_index, true),
            .drop_maximum_v = localDrop(flow.maximum, route_index, true),
            .required_count_typical = countFor(typical, capacity),
            .required_count_maximum = countFor(maximum, capacity),
        });
    }
    return out.items;
}

/// The strongest current a solved conductor touching `surface` carries.
///
/// A pour is not a current-density mesh here, so the honest local statement
/// about what enters one is the worst of the routed conductors landing on it.
/// Summing them would double count: the same amperes enter through one contact
/// and leave through another. Null keeps the caller on the whole-rail envelope,
/// which is what an unsolved axis is entitled to.
fn surfaceCurrent(axis: power_current.Axis, touch: SheetSet.Touch) ?f64 {
    if (axis.status != .solved) return null;
    // A sheet fed only by pads has no conductor to read a current from. That is
    // an absence of evidence, not a zero, so it keeps the whole-rail envelope.
    if (touch.tracks.len == 0 and touch.vias.len == 0) return null;
    var worst: f64 = 0;
    for (touch.tracks) |route_index| {
        const amps = axis.track_current_a[route_index];
        if (std.math.isFinite(amps)) worst = @max(worst, @abs(amps));
    }
    for (touch.vias) |route_index| {
        const amps = axis.via_current_a[route_index];
        if (std.math.isFinite(amps)) worst = @max(worst, @abs(amps));
    }
    return worst;
}

fn analyzePlanes(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    net_name: []const u8,
    demand: Demand,
    poured: Poured,
    flow: power_current.Result,
) std.mem.Allocator.Error![]const Plane {
    var out: std.ArrayList(Plane) = .empty;
    const stack = placement.rules.physical.stack;
    const design_min = @max(
        @max(0, placement.rules.design.pour.min_width),
        placement.rules.powerWidthForNet(net_name) orelse 0,
    );
    for (poured.surfaces, 0..) |surface, surface_index| {
        if (!sameNet(surface.net, net_name)) continue;
        const foil = stack.foilMm(surface.physical_layer);
        const outer = surface.physical_layer == 1 or surface.physical_layer == placement.rules.layerStack().stackCount();
        const per_mm = traceCapacityA(1.0, foil, outer);
        // A solved rail knows how much of its current this sheet actually
        // carries. Charging every plane the whole rail once told a two-amp
        // board that a pour serving one 40 mA branch needed a two-amp neck.
        const touch = if (surface_index < poured.sheets.touch.len) poured.sheets.touch[surface_index] else SheetSet.Touch{};
        const local_typical: ?f64 = if (surfaceCurrent(flow.typical, touch)) |a| a else demand.typical_a;
        const local_maximum: ?f64 = if (surfaceCurrent(flow.maximum, touch)) |a| a else demand.maximum_a;
        const required_typical = if (local_typical) |a| requiredTraceWidthMm(a, foil, outer) else null;
        const required_maximum = if (local_maximum) |a| requiredTraceWidthMm(a, foil, outer) else null;
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

fn expectNoRequiredWidths(widths: []const ?LocalWidth) !void {
    for (widths) |width| try testing.expect(width == null);
}

fn expectSolvedWidths(widths: []const ?LocalWidth) !void {
    for (widths) |width| try testing.expect(!width.?.envelope);
}

fn expectEnvelopeWidths(widths: []const ?LocalWidth, expected: f64) !void {
    for (widths) |width| {
        try testing.expect(width.?.envelope);
        try testing.expect(width.?.reason.len > 0);
        try testing.expectApproxEqAbs(expected, width.?.width_mm, 1e-12);
    }
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
///
/// EVERY net carrying a declared demand answers, whether or not it opted into
/// `power_branch_width`: a rail's ampacity is a fact about the board, not about
/// an annotation. A solved branch reports its own current
/// (`envelope=false`); a rail whose topology could not be solved reports the
/// WHOLE declared rail current on each of its segments with `envelope=true` and
/// the `power_current.Status` name that caused it. That remains a safe ampacity
/// upper bound and tells the caller exactly how much to trust it. Null is now
/// only for a track whose net declares no current at all.
///
/// Ordinary rails use the trace/via graph; a rail with a fabricated plane or a
/// saved copper zone also includes those computed sheets, so its short fanouts
/// are judged by their actual local load.
pub fn routedTrackRequiredWidths(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    routed: router.RouteResult,
) std.mem.Allocator.Error![]const ?LocalWidth {
    return routedTrackRequiredWidthsMemo(alloc, placement, routed, null);
}

/// `routedTrackRequiredWidths` with a per-fill memo for the plane surfaces it
/// needs. Every surface here is an ordinary declared plane/pour fill of this
/// board, keyed and reused exactly like any other; a null memo is the
/// unmemoised spelling, byte for byte.
pub fn routedTrackRequiredWidthsMemo(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    routed: router.RouteResult,
    memo: ?pour.FillMemo,
) std.mem.Allocator.Error![]const ?LocalWidth {
    return routedTrackRequiredWidthsMemoZones(alloc, placement, routed, memo, &.{});
}

/// `routedTrackRequiredWidthsMemo` with the board's saved user zones.
///
/// A rail whose regulator output pads are fed only by a pour has no track
/// touching them at all; without that pour in the graph the solve reports
/// `no-source-terminal` and every one of the rail's segments falls back to the
/// whole-rail envelope. Sheets are therefore built for EVERY net with a
/// declared demand, not only for nets that opted into branch widths, so the
/// router/editor pass and the reporting pass see the same copper graph.
///
/// Callers that have not plumbed their zone list through pass `&.{}` (that is
/// what the four-argument spelling does) and lose only the user-zone half of
/// that graph; declared planes and pours are always included.
pub fn routedTrackRequiredWidthsMemoZones(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    routed: router.RouteResult,
    memo: ?pour.FillMemo,
    zones: []const pour.UserZone,
) std.mem.Allocator.Error![]const ?LocalWidth {
    var needs_surfaces = false;
    for (placement.nets) |net| {
        const demand = demandFor(placement.rules.physical.rails, net.name);
        if (demand.typical_a == null and demand.maximum_a == null) continue;
        // Rastering is the expensive half of this pass, so it still only runs
        // for a board that actually has poured copper to raster.
        if (!router.netHasPlane(placement, net.name) and !zoneCarriesNet(zones, net.name)) continue;
        needs_surfaces = true;
        break;
    }
    const surfaces = if (needs_surfaces)
        try buildSurfaces(alloc, placement, routed, zones, null, memo)
    else
        &.{};
    return routedTrackRequiredWidthsFromSurfaces(alloc, placement, routed, surfaces);
}

fn zoneCarriesNet(zones: []const pour.UserZone, net_name: []const u8) bool {
    for (zones) |zone| if (sameNet(zone.net, net_name)) return true;
    return false;
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
) std.mem.Allocator.Error![]const ?LocalWidth {
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
) std.mem.Allocator.Error![]const ?LocalWidth {
    const required = try alloc.alloc(?LocalWidth, routed.tracks.len);
    @memset(required, null);
    const identity = try net_identity.Identity.init(alloc, placement);
    for (placement.nets, 0..) |net, net_index| {
        if (!identity.isRoot(net_index)) continue;
        const demand = demandFor(placement.rules.physical.rails, net.name);
        if (demand.typical_a == null and demand.maximum_a == null) continue;
        const family = try familyFor(alloc, placement, identity, net_index);
        const poured = try pourFor(alloc, placement, routed, family, surfaces);
        const flow = try solveCurrent(alloc, placement, routed, family, demand, poured);
        // Never substitute the smaller typical axis when a declared maximum
        // axis is unprovable (for example, because a max-only consumer is
        // disconnected). Typical is sufficient only on a typical-only rail.
        const axis = if (demand.maximum_a != null) flow.maximum else flow.typical;
        if (axis.status != .solved) {
            // A failed topology solve means we cannot divide current among
            // branches, not that IPC-2221 has no answer. Conservatively charge
            // EVERY segment with the full rail envelope, flagged as such: it is
            // an upper bound on any one branch, and the caller can see from
            // `envelope`/`reason` that it is a bound rather than a measurement.
            const amps = if (demand.maximum_a != null) demand.maximum_a else demand.typical_a;
            for (routed.tracks, 0..) |track, route_index| {
                if (!family.has(track.net)) continue;
                required[route_index] = .{
                    .width_mm = trackWidthForAmps(placement, track, amps.?) orelse continue,
                    .envelope = true,
                    .reason = axis.status.name(),
                };
            }
            continue;
        }
        for (routed.tracks, 0..) |track, route_index| {
            if (!family.has(track.net)) continue;
            const amps = axis.track_current_a[route_index];
            if (!std.math.isFinite(amps) or amps < 0) continue;
            required[route_index] = .{
                .width_mm = if (amps == 0) 0 else trackWidthForAmps(placement, track, amps) orelse continue,
                .envelope = false,
            };
        }
    }
    return required;
}

/// IPC-2221 width for `amps` on the foil this track is actually printed on.
fn trackWidthForAmps(placement: optimizer.Placement, track: router.Track, amps: f64) ?f64 {
    const physical = placement.rules.signalStackIndex(track.layer);
    const foil = placement.rules.physical.stack.foilMm(physical);
    const outer = physical == 1 or physical == placement.rules.layerStack().stackCount();
    return requiredTraceWidthMm(amps, foil, outer);
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
    const identity = try net_identity.Identity.init(alloc, placement);
    var nets: std.ArrayList(Net) = .empty;
    for (placement.nets, 0..) |net, net_index| {
        // A per-pin bypass stub is this rail's own copper, reported under the
        // rail — never as a second, three-pin rail of its own.
        if (!identity.isRoot(net_index)) continue;
        const demand = demandFor(placement.rules.physical.rails, net.name);
        if (!isPowerNet(placement, net_index, demand)) continue;
        const family = try familyFor(alloc, placement, identity, net_index);
        const poured = try pourFor(alloc, placement, routed, family, surfaces);
        const flow = try solveCurrent(alloc, placement, routed, family, demand, poured);
        const tracks = try analyzeTracks(alloc, placement, routed, family, demand, flow);
        const vias = try analyzeVias(alloc, placement, routed, family, demand, flow);
        const planes = try analyzePlanes(alloc, placement, net.name, demand, poured, flow);
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

// spec: placement/power-routing - a solved plane-aware rail exposes an index-aligned required width for each local-current branch, while an unsolved rail screens every segment at the whole-rail current and reports why
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
    try expectSolvedWidths(widths);
    try testing.expect(widths[0].?.width_mm > widths[1].?.width_mm);
    try testing.expect(widths[1].?.width_mm > widths[2].?.width_mm);
    try testing.expect(widths[2].?.width_mm < 0.1524);

    var incomplete = rails[0];
    incomplete.source_terminals = &.{"missing/VOUT"};
    var incomplete_placement = placement;
    incomplete_placement.rules.physical.rails = &.{incomplete};
    const conservative = try routedTrackRequiredWidths(arena_inst.allocator(), incomplete_placement, routed);
    const whole_rail_width = requiredTraceWidthMm(1, 0.035, true).?;
    try expectEnvelopeWidths(conservative, whole_rail_width);
    try testing.expectEqualStrings("no-source-terminal", conservative[0].?.reason);

    // Ampacity is a fact about the board, not about an annotation: dropping the
    // `power_branch_width` opt-in no longer silences the rail's own current.
    var unopted_rules = net_rules;
    unopted_rules[0].pad_neck.power_branch_width = 0;
    var unopted_placement = incomplete_placement;
    unopted_placement.rules.net = &unopted_rules;
    try expectEnvelopeWidths(
        try routedTrackRequiredWidths(arena_inst.allocator(), unopted_placement, routed),
        whole_rail_width,
    );

    // A net with no declared current at all still answers null.
    var railless = placement;
    railless.rules.physical.rails = &.{};
    try expectNoRequiredWidths(try routedTrackRequiredWidths(arena_inst.allocator(), railless, routed));

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
    try expectEnvelopeWidths(max_conservative, whole_rail_width);

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
    try expectEnvelopeWidths(
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
    try expectSolvedWidths(zone_widths);
    try testing.expect(zone_widths[0].?.width_mm > zone_widths[1].?.width_mm);
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

    const family = try familyFor(alloc, placement, .{}, 0);
    const contacts = try sourceContacts(alloc, placement, family, &.{"@external/VDD"});
    try testing.expectEqual(@as(usize, 1), contacts.len);
    try testing.expectApproxEqAbs(@as(f64, 0), contacts[0].at[0], 1e-9);
}

// spec: placement/power-routing - a port-keyed consumer whose module-side net reaches only passive parts resolves those pads as its load contacts
test "a port-keyed consumer resolves passive pads when the module has no hub pad on the rail" {
    const pad = @import("geometry.zig").Pad{ .number = "1", .x = 0, .y = 0, .w = 0.2, .h = 0.2 };
    const parts = [_]optimizer.Part{
        .{ .ref_des = "lna/L1", .kind = .passive, .hw = 0.1, .hh = 0.1, .pads = &.{pad}, .fallback = false, .x = 2, .y = 1 },
        .{ .ref_des = "lna/R4", .kind = .passive, .hw = 0.1, .hh = 0.1, .pads = &.{pad}, .fallback = false, .x = 2, .y = 2 },
        .{ .ref_des = "reg/U1", .kind = .hub, .hw = 0.1, .hh = 0.1, .pads = &.{pad}, .fallback = false, .x = 0, .y = 0 },
    };
    const pins = [_]@import("../flat_netlist.zig").FlatPin{
        .{ .ref_des = "lna/L1", .pin = "1" },
        .{ .ref_des = "lna/R4", .pin = "1" },
        .{ .ref_des = "reg/U1", .pin = "1" },
    };
    const nets = [_]optimizer.FlatNet{.{ .name = "V_5VA", .pins = &pins }};
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
        .maxx = 3,
        .maxy = 3,
        .generated = true,
    };
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const family = try familyFor(arena, placement, .{}, 0);
    const port_load = try loadContacts(arena, placement, family, .{ .ref_des = "lna/VDD", .component = "module port", .net = "V_5VA", .pins = &.{"VDD"}, .i_typ = 0.128, .i_max = 0.144 });
    try testing.expect(port_load.complete);
    try testing.expectEqual(@as(usize, 2), port_load.contacts.len);
    // A regulator keyed the same way still prefers its hub pad over passives.
    const reg_load = try loadContacts(arena, placement, family, .{ .ref_des = "reg/VIN", .net = "V_5VA", .pins = &.{"VIN"}, .i_typ = 0.2, .i_max = 0.2 });
    try testing.expect(reg_load.complete);
    try testing.expectEqual(@as(usize, 1), reg_load.contacts.len);
}

// spec: placement/power-routing - a consumer whose annotated pad sits behind a two-terminal series part on a sibling net enters this net's copper at that part's pad
test "a bead-fed consumer on a sibling net resolves to the bead's pad on the rail" {
    const geometry = @import("geometry.zig");
    const one = geometry.Pad{ .number = "1", .x = 0, .y = 0, .w = 0.2, .h = 0.2 };
    const bead_pads = [_]geometry.Pad{ .{ .number = "1", .x = -0.3, .y = 0, .w = 0.2, .h = 0.2 }, .{ .number = "2", .x = 0.3, .y = 0, .w = 0.2, .h = 0.2 } };
    const parts = [_]optimizer.Part{
        .{ .ref_des = "FB1", .kind = .passive, .hw = 0.4, .hh = 0.1, .pads = &bead_pads, .fallback = false, .x = 1, .y = 0 },
        .{ .ref_des = "amp/U1", .kind = .hub, .hw = 0.1, .hh = 0.1, .pads = &.{one}, .fallback = false, .x = 2, .y = 0 },
    };
    const rail_pins = [_]@import("../flat_netlist.zig").FlatPin{.{ .ref_des = "FB1", .pin = "1" }};
    const branch_pins = [_]@import("../flat_netlist.zig").FlatPin{ .{ .ref_des = "FB1", .pin = "2" }, .{ .ref_des = "amp/U1", .pin = "14" } };
    const nets = [_]optimizer.FlatNet{ .{ .name = "V_5VA", .pins = &rail_pins }, .{ .name = "V_5VA_AMP", .pins = &branch_pins } };
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
        .maxx = 3,
        .maxy = 3,
        .generated = true,
    };
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    // Annotated on the amplifier's own pad, declared on its module-local net
    // name, rolled up onto V_5VA by the bead: it enters V_5VA at FB1 pad 1.
    const family = try familyFor(arena, placement, .{}, 0);
    const load = try loadContacts(arena, placement, family, .{ .ref_des = "amp/U1", .net = "V_5VA_AMP", .pins = &.{"14"}, .i_typ = 0.074, .i_max = 0.1 });
    try testing.expect(load.complete);
    try testing.expectEqual(@as(usize, 1), load.contacts.len);
    try testing.expectApproxEqAbs(@as(f64, 0.7), load.contacts[0].at[0], 1e-9);
}

// spec: placement/power-routing - a rail's per-pin bypass stubs are one piece of copper with it, so a consumer whose pins were renamed onto them still resolves and the whole family solves as one graph
test "a per-pin bypass stub is screened as the rail's own copper" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const geometry = @import("geometry.zig");
    const FlatPin = flat_netlist.FlatPin;

    const reg_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.3, .h = 0.3 }};
    const ic_pads = [_]geometry.Pad{
        .{ .number = "50", .x = 0, .y = 0, .w = 0.3, .h = 0.3 },
        .{ .number = "13", .x = 1, .y = 0, .w = 0.3, .h = 0.3 },
    };
    const cap_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.3, .h = 0.3 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "reg/U9", .kind = .hub, .hw = 0.2, .hh = 0.2, .pads = &reg_pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "U23", .kind = .hub, .hw = 0.6, .hh = 0.2, .pads = &ic_pads, .fallback = false, .x = 2, .y = 0 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.2, .hh = 0.2, .pads = &cap_pads, .fallback = false, .x = 3, .y = 0.5 },
    };
    const rail_pins = [_]FlatPin{ .{ .ref_des = "reg/U9", .pin = "1" }, .{ .ref_des = "U23", .pin = "50" } };
    const stub_pins = [_]FlatPin{ .{ .ref_des = "U23", .pin = "13" }, .{ .ref_des = "C1", .pin = "1" } };
    const nets = [_]optimizer.FlatNet{
        .{ .name = "V_3V3D", .pins = &rail_pins },
        .{ .name = "V_3V3D.U23.13", .pins = &stub_pins },
    };
    // The evaluator's own bypass record: pad 13 of U23 decoupled by C1 on the
    // renamed connection net. This is the proof `net_identity` demands.
    const loops = [_]optimizer.Loop{.{
        .cap = 2,
        .hub = 1,
        .cap_pwr = .{ .x = 0, .y = 0, .w = 0.3, .h = 0.3 },
        .cap_gnd = .{ .x = 0, .y = 0, .w = 0.3, .h = 0.3 },
        .hub_pwr = &.{},
        .hub_pwr_pin = .{ .x = 1, .y = 0, .w = 0.3, .h = 0.3 },
        .hub_gnd = &.{},
        .pwr_net = 1,
        .explicit_pin = "13",
    }};
    const consumers = [_]power_budget.RailConsumer{
        .{ .ref_des = "U23", .net = "V_3V3D", .pins = &.{ "50", "13" }, .i_typ = 1.0, .i_max = 1.0 },
    };
    const rails = [_]power_budget.Rail{.{
        .net = "V_3V3D",
        .source_terminals = &.{"reg/VOUT"},
        .load_typ_a = 1.0,
        .load_max_a = 1.0,
        .any_typ_load = true,
        .any_max_load = true,
        .status = .no_source,
        .consumers = &consumers,
    }};
    const foils = [_]@import("impedance.zig").Foil{.{ .index = 1, .thickness_mm = 0.035 }};
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 2, .y2 = 0, .layer = 0, .width = 0.3, .net = 0 },
        .{ .x1 = 2, .y1 = 0, .x2 = 3, .y2 = 0, .layer = 0, .width = 0.3, .net = 1 },
    };
    const routed = router.RouteResult{ .tracks = &tracks, .vias = &.{}, .routed = 2, .total = 2 };
    var placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &loops,
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = -1,
        .maxx = 3,
        .maxy = 1,
        .generated = true,
        .rules = .{
            .copper_layers = 2,
            .physical = .{ .stack = .{ .layers = 2, .foils = &foils }, .rails = &rails },
        },
    };

    const identity = try net_identity.Identity.init(arena, placement);
    const family = try familyFor(arena, placement, identity, 0);
    try testing.expectEqual(@as(usize, 2), family.members.len);
    const load = try loadContacts(arena, placement, family, consumers[0]);
    try testing.expect(load.complete);
    try testing.expectEqual(@as(usize, 2), load.contacts.len);

    // The stub's own track is solved as part of the rail's graph, not skipped
    // as an unrelated net, and neither segment falls back to the envelope.
    const widths = try routedTrackRequiredWidths(arena, placement, routed);
    try expectSolvedWidths(widths);
    try testing.expect(widths[0].?.width_mm > widths[1].?.width_mm);

    // Without the bypass proof the stub is a stranger: the consumer's pad 13 is
    // nowhere on the rail, so the whole rail reverts to its envelope.
    placement.loops = &.{};
    const split = try routedTrackRequiredWidths(arena, placement, routed);
    try testing.expect(split[0].?.envelope);
    try testing.expectEqualStrings("incomplete-load-terminals", split[0].?.reason);
    try testing.expectEqual(@as(?LocalWidth, null), split[1]);
}

// spec: placement/power-routing - a consumer several two-terminal series parts downstream still enters this rail at the first part's pad on it
test "a consumer behind a shared choke and a per-pin bead resolves to the choke's rail pad" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const geometry = @import("geometry.zig");
    const FlatPin = flat_netlist.FlatPin;

    const two = [_]geometry.Pad{
        .{ .number = "1", .x = -0.3, .y = 0, .w = 0.2, .h = 0.2 },
        .{ .number = "2", .x = 0.3, .y = 0, .w = 0.2, .h = 0.2 },
    };
    const one = [_]geometry.Pad{.{ .number = "6", .x = 0, .y = 0, .w = 0.2, .h = 0.2 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "synth/L1", .kind = .passive, .hw = 0.4, .hh = 0.1, .pads = &two, .fallback = false, .x = 1, .y = 0 },
        .{ .ref_des = "synth/FB2", .kind = .passive, .hw = 0.4, .hh = 0.1, .pads = &two, .fallback = false, .x = 3, .y = 0 },
        .{ .ref_des = "synth/U10", .kind = .hub, .hw = 0.5, .hh = 0.5, .pads = &one, .fallback = false, .x = 5, .y = 0 },
    };
    const rail_pins = [_]FlatPin{.{ .ref_des = "synth/L1", .pin = "1" }};
    const mid_pins = [_]FlatPin{ .{ .ref_des = "synth/L1", .pin = "2" }, .{ .ref_des = "synth/FB2", .pin = "1" } };
    const vcc_pins = [_]FlatPin{ .{ .ref_des = "synth/FB2", .pin = "2" }, .{ .ref_des = "synth/U10", .pin = "6" } };
    const nets = [_]optimizer.FlatNet{
        .{ .name = "V_3V3_LMX", .pins = &rail_pins },
        .{ .name = "synth/V_3V3", .pins = &mid_pins },
        .{ .name = "synth/V_3V3_VCC", .pins = &vcc_pins },
    };
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = -1,
        .maxx = 6,
        .maxy = 1,
        .generated = true,
    };
    const family = try familyFor(arena, placement, .{}, 0);
    // Two series parts deep: the old one-hop bridge found nothing here and the
    // whole rail fell back to its envelope.
    const load = try loadContacts(arena, placement, family, .{
        .ref_des = "synth/U10",
        .net = "V_3V3",
        .pins = &.{"6"},
        .i_typ = 0.35,
        .i_max = 0.4,
    });
    try testing.expect(load.complete);
    try testing.expectEqual(@as(usize, 1), load.contacts.len);
    try testing.expectApproxEqAbs(@as(f64, 0.7), load.contacts[0].at[0], 1e-9);
}

// spec: placement/power-routing - a solved rail sizes each pour's neck for the current that pour actually carries, and keeps the whole-rail envelope only while the solve is unproven
test "a plane's required neck follows its own solved current" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const foils = [_]@import("impedance.zig").Foil{.{ .index = 1, .thickness_mm = 0.035 }};
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
        .maxx = 4,
        .maxy = 4,
        .generated = true,
        .rules = .{ .copper_layers = 2, .physical = .{ .stack = .{ .layers = 2, .foils = &foils } } },
    };
    const labels: [4]i32 = @splat(0);
    const surfaces = [_]Surface{.{
        .net = "VDD",
        .kind = .zone,
        .physical_layer = 1,
        .signal_layer = 0,
        .fill = .{
            .frame = .{ .minx = 0, .miny = 0, .pitch = 1, .nx = 2, .ny = 2 },
            .labels = &labels,
            .n_comp = 1,
            .contours = &.{},
            .holes = &.{},
            .coarsened = false,
        },
    }};
    const touch = [_]SheetSet.Touch{.{ .tracks = &.{0}, .vias = &.{} }};
    const sheets = SheetSet{ .sheets = &.{}, .touch = &touch };
    const demand = Demand{ .typical_a = 2.0, .maximum_a = 2.0 };

    var current = [_]f64{0.2};
    var drop = [_]f64{0};
    const solved_axis = power_current.Axis{
        .status = .solved,
        .track_current_a = &current,
        .track_drop_v = &drop,
        .via_current_a = &.{},
        .via_drop_v = &.{},
    };
    const solved = try analyzePlanes(arena, placement, "VDD", demand, .{ .surfaces = &surfaces, .sheets = sheets }, .{
        .typical = solved_axis,
        .maximum = solved_axis,
    });
    try testing.expectApproxEqAbs(
        requiredTraceWidthMm(0.2, 0.035, true).?,
        solved[0].required_neck_maximum_mm.?,
        1e-12,
    );

    var unsolved_axis = solved_axis;
    unsolved_axis.status = .disconnected;
    const unproven = try analyzePlanes(arena, placement, "VDD", demand, .{ .surfaces = &surfaces, .sheets = sheets }, .{
        .typical = unsolved_axis,
        .maximum = unsolved_axis,
    });
    try testing.expectApproxEqAbs(
        requiredTraceWidthMm(2.0, 0.035, true).?,
        unproven[0].required_neck_maximum_mm.?,
        1e-12,
    );
    try testing.expect(unproven[0].required_neck_maximum_mm.? > solved[0].required_neck_maximum_mm.?);
}
