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
const power_voltage = @import("power_voltage.zig");
const net_graph = @import("net_graph.zig");
const pad_shape = @import("pad_shape.zig");
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

/// One declared source terminal and how many physical pads it resolved to.
/// Zero contacts is the whole explanation for a `no-source-terminal` rail:
/// the terminal was declared, and no pad on this net answered to it.
pub const SourceFlow = struct {
    terminal: []const u8,
    contacts: usize,
};

/// The current one consumer declares, on both axes.
pub const Draw = struct {
    typical_a: ?f64 = null,
    maximum_a: ?f64 = null,
};

/// Whether each axis's solve actually placed a load on reachable copper.
/// A load can resolve to contacts (`LoadFlow.contacts > 0`) and still not be
/// placed, which is precisely the `disconnected` / `solved_partial` story.
pub const Placed = struct {
    typical: bool = false,
    maximum: bool = false,
};

/// One consumer of a rail as the current solve resolved it. This is the whole
/// diagnosis for an unsolved rail: `contacts = 0` means no pad of this load
/// was found on the rail's copper at all, `complete = false` means only some
/// of its declared pins were, and `placed = false` on a resolved load means
/// the copper it sits on never reaches the source.
pub const LoadFlow = struct {
    /// The consumer's reference designator (or sub-block port path).
    ref: []const u8,
    /// The net the power budget annotated the consumer on.
    net: []const u8,
    /// The consumer's declared pins.
    pins: []const []const u8,
    /// Declared current on each axis.
    draw: Draw,
    /// Physical pads this load resolved to on the rail's copper.
    contacts: usize,
    /// True when every declared pin resolved to a pad.
    complete: bool,
    /// Per-axis placement outcome.
    placed: Placed,
    drop_v: struct { typical: ?f64 = null, maximum: ?f64 = null } = .{},
};

/// One current axis's outcome for a whole rail.
pub const AxisFlow = struct {
    status: power_current.Status,
    /// Amperes belonging to loads this axis could not place. Zero on a full
    /// solve; nonzero is the size of what a partial solve does not know.
    unplaced_a: f64 = 0,
};

/// Why a rail solved the way it did: the two axis verdicts plus the terminal
/// resolution that produced them.
pub const Flow = struct {
    typical: AxisFlow,
    maximum: AxisFlow,
    sources: []const SourceFlow = &.{},
    loads: []const LoadFlow = &.{},
    /// How many separate islands this rail's copper forms under the canonical
    /// contact policy, counted ONLY for a rail that came back `disconnected`
    /// (0 otherwise — "not asked", not "no copper"). It is the difference
    /// between the two ways that verdict happens: more than one island means
    /// the copper really is in pieces, and exactly one means the solve refused
    /// a rail the contact policy calls whole.
    islands: usize = 0,
};

/// All screened copper belonging to one power-like flattened net.
pub const Net = struct {
    index: usize,
    name: []const u8,
    demand: Demand,
    flow: Flow,
    tracks: []const Track,
    vias: []const Via,
    planes: []const Plane,
};

/// Post-route power-copper analysis grouped by flattened net.
pub const Analysis = struct {
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

/// Every pad land of every part on this rail, in `family.pins` order.
///
/// These are conductors, not terminals. DRC topology
/// (`fab_readiness.buildNetGraph`) makes each land a union-find node, so two
/// tracks that both end on a buck's VOUT land — or a track and a via that meet
/// only through a decoupling cap's pad — are one island there. The current
/// solve knew only the pads a SOURCE or LOAD terminal resolved to, so the same
/// copper split into islands and the rail reported `disconnected` while the DRC
/// reported no `net_open` at all.
fn landsFor(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    family: Family,
) std.mem.Allocator.Error![]const net_graph.Land {
    var out: std.ArrayList(net_graph.Land) = .empty;
    for (family.pins, 0..) |pin, logical| {
        const part = partForRef(placement, pin.ref_des) orelse continue;
        for (part.pads) |pad| {
            if (!std.mem.eql(u8, pad.number, pin.pin)) continue;
            try out.append(alloc, .{
                .shape = try pad_shape.worldShape(alloc, part.*, pad),
                .layer = if (pad.thru) null else if (part.side == .top) @as(u8, 0) else 1,
                .logical = logical,
            });
        }
    }
    return out.items;
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

/// Every source pad of a rail, plus the per-terminal tally a reader needs to
/// see WHICH declared terminal found nothing. The combined list is built once
/// and deduplicated across terminals exactly as before; each terminal's count
/// is the contacts it contributed to that one list, so the counts sum to the
/// list's length and a zero names the terminal that resolved to no pad.
fn sourceContacts(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    family: Family,
    terminals: []const []const u8,
) std.mem.Allocator.Error!struct { contacts: []const power_current.Contact, per_terminal: []const SourceFlow } {
    var out: std.ArrayList(power_current.Contact) = .empty;
    const per_terminal = try alloc.alloc(SourceFlow, terminals.len);
    for (terminals, per_terminal) |path, *entry| {
        const before = out.items.len;
        // External board power enters through top-level connector pads on the
        // declared port net.
        if (std.mem.startsWith(u8, path, "@external/")) {
            try boundaryContacts(alloc, placement, family, &out);
        } else if (net_names.parent(path)) |prefix| {
            try scopedSources(alloc, placement, family, prefix, &out, true);
            // A rail whose source node carries NO device pin — a boost output
            // formed by the catch diode, the output caps and the feedback
            // divider (board-a's `boost22/V_25V_RAW`) — has no hub pad under
            // the prefix at all, and the terminal used to resolve to nothing.
            // The current still physically enters the rail at those rectifier
            // and reservoir pads, so they are the source contacts, exactly as
            // `scopedContacts` already falls back for a load.
            if (out.items.len == before) try scopedSources(alloc, placement, family, prefix, &out, false);
        }
        entry.* = .{ .terminal = path, .contacts = out.items.len - before };
    }
    return .{ .contacts = out.items, .per_terminal = per_terminal };
}

/// Pads under a source terminal's sub-block prefix that sit on this rail.
/// `hubs_only` selects the ordinary case (the regulator/converter IC pin that
/// drives the rail); the relaxed pass is the fallback for a source node built
/// entirely from discretes.
fn scopedSources(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    family: Family,
    prefix: []const u8,
    out: *std.ArrayList(power_current.Contact),
    hubs_only: bool,
) std.mem.Allocator.Error!void {
    for (family.pins) |pin| {
        if (!descendantOf(pin.ref_des, prefix)) continue;
        const part = partForRef(placement, pin.ref_des) orelse continue;
        if (hubs_only and part.kind != .hub) continue;
        if (contactForPin(placement, pin)) |contact| try appendContact(alloc, out, contact);
    }
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
/// 0 Ω link is already four, and `board-d-synth-lmx2595` uses three of them. The
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
    /// The rail's pad lands, built once here because BOTH the sheet contact
    /// map and the junction list need every pad geometry, not one per pin.
    lands: []const net_graph.Land = &.{},
};

fn pourFor(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    routed: router.RouteResult,
    family: Family,
    surfaces: []const Surface,
) std.mem.Allocator.Error!Poured {
    const lands = try landsFor(alloc, placement, family);
    return .{
        .surfaces = surfaces,
        .sheets = try sheetsForNet(alloc, routed, family, surfaces, lands),
        .lands = lands,
    };
}

fn sheetsForNet(
    alloc: std.mem.Allocator,
    routed: router.RouteResult,
    family: Family,
    surfaces: []const Surface,
    lands: []const net_graph.Land,
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
        // EVERY pad geometry, not one contact per pin. A buck's VOUT pin is
        // drawn as one SMD land plus six plated pad-vias; crediting only the
        // first geometry hid the fact that those barrels are what carries the
        // rail into the inner plane, and the current solve then reported the
        // regulator's own output pad as an island of its own.
        for (lands) |land| {
            if (land.layer) |layer| {
                if (surface.signal_layer == null or surface.signal_layer.? != layer) continue;
            }
            const at = pad_shape.copperAnchor(land.shape);
            const component = surface.fill.componentAt(at[0], at[1]);
            if (component >= 0) try appendPoint(alloc, &contacts[@intCast(component)], at);
        }
        touch[surface_index] = .{ .tracks = touched_tracks.items, .vias = touched_vias.items };
        for (contacts) |component| if (component.items.len > 0) try out.append(alloc, .{
            .layer = sheetLayer(surface),
            .contacts = component.items,
        });
    }
    return .{ .sheets = out.items, .touch = touch };
}

/// One rail's current solve together with the terminal resolution that
/// produced it. They are one answer: a status without its loads explains
/// nothing, and every consumer of the solve wants the pair.
const Solved = struct {
    flow: power_current.Result,
    sources: []const SourceFlow = &.{},
    loads: []const LoadFlow = &.{},
    /// Islands the rail's copper forms; see `Flow.islands`. Counted only for a
    /// `disconnected` rail, where it is the whole difference between broken
    /// copper and a solve that disagrees with the contact policy.
    islands: usize = 0,

    /// The per-net diagnosis in payload terms.
    fn diagnosis(self: Solved) Flow {
        return .{
            .typical = .{ .status = self.flow.typical.status, .unplaced_a = self.flow.typical.unplaced.typical_a },
            .maximum = .{ .status = self.flow.maximum.status, .unplaced_a = self.flow.maximum.unplaced.maximum_a },
            .sources = self.sources,
            .loads = self.loads,
            .islands = self.islands,
        };
    }
};

/// A rail whose declared demand is zero on both axes: the solver's own
/// `no-current` verdict, reached without building a copper graph OR a sheet
/// contact map. Ground is the reason this exists — it is a power net by
/// classification, carries the board's largest pour and most of its barrels,
/// and rastering sheet contacts for a solve that can only answer `no-current`
/// was the single largest avoidable cost in the copper screen.
fn currentlessSolve(alloc: std.mem.Allocator, routed: router.RouteResult) std.mem.Allocator.Error!Solved {
    const empty: power_current.Input = .{
        .segments = &.{},
        .barrels = &.{},
        .counts = .{ .tracks = routed.tracks.len, .vias = routed.vias.len },
        .source = .{ .contacts = &.{}, .complete = false },
        .loads = &.{},
    };
    return .{ .flow = try power_current.solve(alloc, empty) };
}

fn solveCurrent(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    routed: router.RouteResult,
    family: Family,
    demand: Demand,
    poured: Poured,
) std.mem.Allocator.Error!Solved {
    return solveTerminals(alloc, placement, routed, family, .{ .demand = demand }, poured);
}

const Terminals = struct { source: []const power_current.Contact, loads: []const power_current.Load };

fn solveTerminals(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    routed: router.RouteResult,
    family: Family,
    terminals: struct { demand: Demand = .{}, override: ?Terminals = null },
    poured: Poured,
) std.mem.Allocator.Error!Solved {
    const demand = terminals.demand;
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
    const resolutions = try alloc.alloc(LoadFlow, demand.consumers.len);
    for (demand.consumers, 0..) |consumer, i| {
        const resolved = try loadContacts(alloc, placement, family, consumer);
        loads[i] = .{
            .contacts = resolved.contacts,
            .typical_a = consumer.i_typ,
            .maximum_a = consumer.i_max,
            .complete = resolved.complete,
        };
        resolutions[i] = .{
            .ref = consumer.ref_des,
            .net = consumer.net,
            .pins = consumer.pins,
            .draw = .{ .typical_a = consumer.i_typ, .maximum_a = consumer.i_max },
            .contacts = resolved.contacts.len,
            .complete = resolved.complete,
            .placed = .{},
        };
    }
    var flow: power_current.Input = .{
        .segments = segments.items,
        .barrels = barrels.items,
        .sheets = poured.sheets.sheets,
        .counts = .{ .tracks = routed.tracks.len, .vias = routed.vias.len },
        .source = .{ .contacts = sources.contacts, .complete = sources.contacts.len > 0 },
        .loads = loads,
    };
    if (terminals.override) |replacement| {
        flow.source = .{ .contacts = replacement.source, .complete = replacement.source.len > 0 };
        flow.loads = replacement.loads;
    }
    // The solver's own centreline snapping is tighter than the fabrication
    // contact policy DRC topology uses, so hand it the canonical junctions —
    // but only for a net that will actually be solved, since that sweep is
    // quadratic in the net's copper and ground would pay it for nothing.
    if (power_current.needsGraph(flow)) flow.joins = try net_graph.joinsFor(alloc, flow, poured.lands);
    const result = try power_current.solve(alloc, flow);
    for (resolutions, 0..) |*resolution, i| {
        resolution.placed = .{
            .typical = i < result.typical.placed.len and result.typical.placed[i],
            .maximum = i < result.maximum.placed.len and result.maximum.placed[i],
        };
        resolution.drop_v = .{
            .typical = if (i < result.typical.load_drop_v.len) result.typical.load_drop_v[i] else null,
            .maximum = if (i < result.maximum.load_drop_v.len) result.maximum.load_drop_v[i] else null,
        };
    }
    const disconnected = result.typical.status == .disconnected or result.maximum.status == .disconnected;
    return .{
        .flow = result,
        .sources = sources.per_terminal,
        .loads = resolutions,
        .islands = if (disconnected) try net_graph.islandCount(alloc, flow, poured.lands) else 0,
    };
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
    const surfaces = try demandedSurfaces(alloc, placement, routed, memo, zones);
    return routedTrackRequiredWidthsFromSurfaces(alloc, placement, routed, surfaces);
}

/// Poured surfaces for a board whose rails need them, and nothing at all for a
/// board that does not. Rastering is the expensive half of an unprepared pass,
/// so it still only runs for a board that actually has poured copper to raster
/// under a rail carrying declared current.
fn demandedSurfaces(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    routed: router.RouteResult,
    memo: ?pour.FillMemo,
    zones: []const pour.UserZone,
) std.mem.Allocator.Error![]const Surface {
    for (placement.nets) |net| {
        const demand = demandFor(placement.rules.physical.rails, net.name);
        if (demand.typical_a == null and demand.maximum_a == null and !voltageReturnNamed(placement, net.name)) continue;
        if (!router.netHasPlane(placement, net.name) and !zoneCarriesNet(zones, net.name)) continue;
        return buildSurfaces(alloc, placement, routed, zones, null, memo);
    }
    return &.{};
}

fn voltageReturnNamed(placement: optimizer.Placement, name: []const u8) bool {
    for (placement.rules.net) |rule| {
        if (rule.voltage_drop.limit_v != 0 and std.ascii.eqlIgnoreCase(rule.voltage_drop.return_net, name)) return true;
    }
    return false;
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
    const surfaces = try preparedSurfaces(alloc, placement, plane_fills, zones, zone_fills);
    return routedTrackRequiredWidthsFromSurfaces(alloc, placement, routed, surfaces);
}

/// The already-poured fills of the reporting seam, in this module's surface
/// terms. One spelling for every `*Prepared` entry point, so the track rule,
/// the via rule and their shared solve can never disagree about which copper
/// a rail is screened against.
fn preparedSurfaces(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    plane_fills: []const pour.NetFills,
    zones: []const pour.UserZone,
    zone_fills: []const pour.Fill,
) std.mem.Allocator.Error![]const Surface {
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
    return surfaces.items;
}

/// Both rules' requirements from one solve per rail, over the bare board.
pub fn routedPowerRequirements(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    routed: router.RouteResult,
) std.mem.Allocator.Error!PowerRequirements {
    return routedPowerRequirementsMemo(alloc, placement, routed, null);
}

/// `routedPowerRequirements` with a per-fill memo. The pour is gated by the
/// TRACK rule's predicate, which is the broader of the two: a rail that is
/// worth rastering for its traces is worth rastering for its barrels, and the
/// two rules now read one solve, so there is only one gate left to state.
pub fn routedPowerRequirementsMemo(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    routed: router.RouteResult,
    memo: ?pour.FillMemo,
) std.mem.Allocator.Error!PowerRequirements {
    return routedPowerRequirementsMemoZones(alloc, placement, routed, memo, &.{});
}

/// `routedPowerRequirementsMemo` with the board's saved user zones, on exactly
/// the terms `routedTrackRequiredWidthsMemoZones` states: a rail fed only by a
/// hand-drawn pour is unsolvable without that pour in the graph.
pub fn routedPowerRequirementsMemoZones(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    routed: router.RouteResult,
    memo: ?pour.FillMemo,
    zones: []const pour.UserZone,
) std.mem.Allocator.Error!PowerRequirements {
    const surfaces = try demandedSurfaces(alloc, placement, routed, memo, zones);
    return routedPowerRequirementsFromSurfaces(alloc, placement, routed, surfaces);
}

/// The reporting DRC spelling: both rules' requirements over the exact fills
/// the seam already poured, from one solve per rail.
pub fn routedPowerRequirementsPrepared(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    routed: router.RouteResult,
    plane_fills: []const pour.NetFills,
    zones: []const pour.UserZone,
    zone_fills: []const pour.Fill,
) std.mem.Allocator.Error!PowerRequirements {
    const surfaces = try preparedSurfaces(alloc, placement, plane_fills, zones, zone_fills);
    return routedPowerRequirementsFromSurfaces(alloc, placement, routed, surfaces);
}

/// Both post-route power-copper verdicts, from ONE current solve per rail.
///
/// The track rule and the via rule ask the same question of the same copper —
/// "how much current does this conductor carry?" — and used to answer it by
/// solving every power net TWICE per DRC pass, once each. The solve is the
/// expensive half (a conductance graph plus a dense elimination per axis), so
/// they now share it, and each rule reads its own index-aligned array out of
/// this pair.
pub const PowerRequirements = struct {
    /// Index-aligned with `routed.tracks`; see `routedTrackRequiredWidths`.
    tracks: []const ?LocalWidth,
    /// Index-aligned with `routed.vias`; see `routedViaRequirements`.
    vias: []const ?ViaCurrent,
    voltage: []const power_voltage.Assessment = &.{},
};

/// One rail's screening current on one conductor: its solved branch share, or
/// the whole-rail envelope when the solve did not resolve.
const Charged = struct {
    axis: power_current.Axis,
    envelope_a: f64,
    resolved: bool,

    fn track(self: Charged, route_index: usize) f64 {
        return if (self.resolved) self.axis.track_current_a[route_index] else self.envelope_a;
    }

    fn via(self: Charged, route_index: usize) f64 {
        return if (self.resolved) self.axis.via_current_a[route_index] else self.envelope_a;
    }
};

fn fillTrackWidths(
    placement: optimizer.Placement,
    routed: router.RouteResult,
    family: Family,
    charged: Charged,
    out: []?LocalWidth,
) void {
    for (routed.tracks, 0..) |track, route_index| {
        if (!family.has(track.net)) continue;
        const amps = charged.track(route_index);
        // A failed topology solve means we cannot divide current among
        // branches, not that IPC-2221 has no answer. Conservatively charge
        // EVERY segment with the full rail envelope, flagged as such: it is an
        // upper bound on any one branch, and the caller can see from
        // `envelope`/`reason` that it is a bound rather than a measurement.
        if (!charged.resolved) {
            const width_mm = trackWidthForAmps(placement, track, amps) orelse continue;
            out[route_index] = .{
                .width_mm = width_mm,
                .envelope = true,
                .reason = charged.axis.status.name(),
            };
            continue;
        }
        if (!std.math.isFinite(amps) or amps < 0) continue;
        const width_mm = if (amps == 0) 0 else trackWidthForAmps(placement, track, amps) orelse continue;
        out[route_index] = .{
            .width_mm = width_mm,
            .envelope = false,
        };
    }
}

fn fillViaCurrents(
    placement: optimizer.Placement,
    routed: router.RouteResult,
    family: Family,
    charged: Charged,
    out: []?ViaCurrent,
) void {
    for (routed.vias, 0..) |via, route_index| {
        if (!family.has(via.net)) continue;
        const amps = charged.via(route_index);
        if (!std.math.isFinite(amps) or amps < 0) continue;
        out[route_index] = .{
            .current_a = amps,
            .capacity_a = viaBarrelCapacityA(placement, via),
            .envelope = !charged.resolved,
            .reason = charged.axis.status.name(),
        };
    }
}

/// Inputs already prepared by the shared current/width solve.
const VoltageContext = struct {
    placement: optimizer.Placement,
    routed: router.RouteResult,
    copper: struct { identity: net_identity.Identity, family: Family, poured: Poured, surfaces: []const Surface },
    demand: Demand,
    solved: Solved,
    budget: env.NetClassSpec.VoltageDrop,
};

fn voltageModelReason(c: VoltageContext) []const u8 {
    if (!c.budget.valid()) return "invalid-voltage-drop-budget";
    if (c.demand.maximum_a == null or c.demand.consumers.len == 0) return "missing-maximum-load-current";
    var total: f64 = 0;
    for (c.demand.consumers) |load| {
        const amps = load.i_max orelse return "missing-maximum-load-current";
        if (!std.math.isFinite(amps) or amps < 0) return "invalid-maximum-load-current";
        total += amps;
    }
    if (@abs(total - c.demand.maximum_a.?) > 1e-9) return "incomplete-maximum-load-current";
    for (c.solved.sources) |source| if (source.contacts == 0) return "incomplete-source-terminals";
    if (c.copper.poured.sheets.sheets.len > 0) return "supply-sheet-resistance-unmodeled";
    if (c.solved.flow.maximum.status != .solved) return c.solved.flow.maximum.status.name();
    return "";
}

const ReturnFlow = struct {
    axis: ?power_current.Axis = null,
    net: ?usize = null,
    reason: []const u8 = "",
};

fn voltageReturn(alloc: std.mem.Allocator, c: VoltageContext) std.mem.Allocator.Error!ReturnFlow {
    var root: ?usize = null;
    for (c.placement.nets, 0..) |net, i| {
        if (std.ascii.eqlIgnoreCase(net.name, c.budget.return_net)) root = @intCast(c.copper.identity.canonical(@intCast(i)));
    }
    const return_i = root orelse return .{ .reason = "missing-return-net" };
    var out = ReturnFlow{ .net = return_i };
    if (return_i == c.copper.family.root) {
        out.reason = "return-net-is-supply";
        return out;
    }
    const family = try familyFor(alloc, c.placement, c.copper.identity, return_i);
    // Any surviving return sheet needs a resistive mesh. Refuse before
    // mapping hundreds of ground contacts repeatedly for every supply rail.
    for (c.copper.surfaces) |surface| {
        if (!sameNet(surface.net, family.name) or surface.fill.n_comp == 0) continue;
        out.reason = "return-sheet-resistance-unmodeled";
        return out;
    }
    // Independent per-rail solves cannot prove a shared return. Other rails'
    // return injections and converter ground currents need a coupled model.
    // Refuse that case instead of silently charging ground with just this rail.
    for (c.placement.rules.physical.rails) |rail| {
        if (sameNet(rail.net, c.copper.family.name)) continue;
        if (rail.any_typ_load or rail.any_max_load) {
            out.reason = "shared-return-current-unmodeled";
            return out;
        }
    }
    const terminals = try returnTerminals(alloc, c, family) orelse {
        out.reason = "ambiguous-or-missing-return-terminals";
        return out;
    };
    const poured = try pourFor(alloc, c.placement, c.routed, family, c.copper.surfaces);
    const solved = try solveTerminals(alloc, c.placement, c.routed, family, .{ .override = terminals }, poured);
    if (solved.flow.maximum.status != .solved) {
        out.reason = solved.flow.maximum.status.name();
        return out;
    }
    out.axis = solved.flow.maximum;
    return out;
}

/// Return pads must belong to the exact device that owns the supply terminal.
/// A module port landing on a bead is not enough evidence to guess the IC's
/// ground; it remains unverified until the actual load terminals are modeled.
fn oppositeContacts(
    alloc: std.mem.Allocator,
    c: VoltageContext,
    family: Family,
    supply: []const power_current.Contact,
) std.mem.Allocator.Error!?[]const power_current.Contact {
    var owner: ?[]const u8 = null;
    for (supply) |contact| {
        var found = false;
        for (c.copper.family.pins) |pin| {
            const pad = contactForPin(c.placement, pin) orelse continue;
            if (pad.layer != contact.layer or std.math.hypot(pad.at[0] - contact.at[0], pad.at[1] - contact.at[1]) > geometry_eps_mm) continue;
            if (owner) |ref| {
                if (!std.mem.eql(u8, ref, pin.ref_des)) return null;
            } else owner = pin.ref_des;
            found = true;
        }
        if (!found) return null;
    }
    const ref = owner orelse return null;
    var contacts: std.ArrayList(power_current.Contact) = .empty;
    for (family.pins) |pin| {
        if (!std.mem.eql(u8, ref, pin.ref_des)) continue;
        const contact = contactForPin(c.placement, pin) orelse return null;
        try appendContact(alloc, &contacts, contact);
    }
    if (contacts.items.len == 0) return null;
    return contacts.items;
}

fn returnTerminals(alloc: std.mem.Allocator, c: VoltageContext, family: Family) std.mem.Allocator.Error!?Terminals {
    const supply_source = try sourceContacts(alloc, c.placement, c.copper.family, c.demand.source_terminals);
    const source = try oppositeContacts(alloc, c, family, supply_source.contacts) orelse return null;
    const loads = try alloc.alloc(power_current.Load, c.demand.consumers.len);
    for (c.demand.consumers, loads) |consumer, *load| {
        const supply = try loadContacts(alloc, c.placement, c.copper.family, consumer);
        const contacts = try oppositeContacts(alloc, c, family, supply.contacts) orelse return null;
        load.* = .{ .contacts = contacts, .typical_a = consumer.i_typ, .maximum_a = consumer.i_max };
    }
    return .{ .source = source, .loads = loads };
}

fn assessVoltage(alloc: std.mem.Allocator, c: VoltageContext, out: *std.ArrayList(power_voltage.Assessment)) std.mem.Allocator.Error!void {
    const reason = voltageModelReason(c);
    if (reason.len > 0) {
        try out.append(alloc, .{ .net = c.copper.family.root, .budget = c.budget, .reason = reason });
        return;
    }
    const ret = try voltageReturn(alloc, c);
    // Uniform copper temperature scales every R equally, leaving the KCL
    // current division unchanged. TI Precision Labs, Temperature Error:
    // R(T) = R(20 C) * [1 + 0.00393 * (T - 20 C)]. Clamp below 20 C to
    // retain the room-temperature bound instead of taking credit for cold.
    const resistance_scale = 1 + 0.00393 * @max(0, c.budget.copper_temperature_c - 20);
    for (c.demand.consumers, 0..) |consumer, i| {
        const supply = if (i < c.solved.flow.maximum.load_drop_v.len) c.solved.flow.maximum.load_drop_v[i] else null;
        const back = if (ret.axis) |axis| (if (i < axis.load_drop_v.len) axis.load_drop_v[i] else null) else null;
        try out.append(alloc, .{
            .net = c.copper.family.root,
            .load = consumer.ref_des,
            .budget = c.budget,
            .supply_drop_v = if (supply) |v| v * resistance_scale else null,
            .return_drop_v = if (back) |v| v * resistance_scale else null,
            .return_net = ret.net,
            .reason = if (ret.reason.len > 0) ret.reason else if (supply == null or back == null) "unplaced-load" else "",
        });
    }
}

fn routedPowerRequirementsFromSurfaces(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    routed: router.RouteResult,
    surfaces: []const Surface,
) std.mem.Allocator.Error!PowerRequirements {
    const widths = try alloc.alloc(?LocalWidth, routed.tracks.len);
    @memset(widths, null);
    const barrels = try alloc.alloc(?ViaCurrent, routed.vias.len);
    @memset(barrels, null);
    const identity = try net_identity.Identity.init(alloc, placement);
    var voltage: std.ArrayList(power_voltage.Assessment) = .empty;
    for (placement.nets, 0..) |net, net_index| {
        // A per-pin bypass stub is judged as its rail's own copper.
        if (!identity.isRoot(net_index)) continue;
        const demand = demandFor(placement.rules.physical.rails, net.name);
        // The declared whole-rail envelope, on the axis the verdict is taken
        // on: never substitute the smaller typical axis for a declared maximum
        // (for example, because a max-only consumer is disconnected).
        const budget = if (net_index < placement.rules.net.len) placement.rules.net[net_index].voltage_drop else env.NetClassSpec.VoltageDrop{};
        const envelope = if (demand.maximum_a != null) demand.maximum_a else demand.typical_a;
        if (envelope == null and budget.limit_v == 0) continue;
        const envelope_a = envelope orelse 0;
        const family = try familyFor(alloc, placement, identity, net_index);
        const poured = try pourFor(alloc, placement, routed, family, surfaces);
        const solved = try solveCurrent(alloc, placement, routed, family, demand, poured);
        const axis = if (demand.maximum_a != null) solved.flow.maximum else solved.flow.typical;
        // A partial solve cannot say what an unplaced load's current does at
        // this conductor, so it is screened at the envelope with its status as
        // the reason.
        const charged: Charged = .{ .axis = axis, .envelope_a = envelope_a, .resolved = axis.status == .solved };
        if (envelope != null) {
            fillTrackWidths(placement, routed, family, charged, widths);
            fillViaCurrents(placement, routed, family, charged, barrels);
        }
        if (budget.limit_v != 0) try assessVoltage(alloc, .{
            .placement = placement,
            .routed = routed,
            .copper = .{ .identity = identity, .family = family, .poured = poured, .surfaces = surfaces },
            .demand = demand,
            .solved = solved,
            .budget = budget,
        }, &voltage);
    }
    return .{ .tracks = widths, .vias = barrels, .voltage = voltage.items };
}

fn routedTrackRequiredWidthsFromSurfaces(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    routed: router.RouteResult,
    surfaces: []const Surface,
) std.mem.Allocator.Error![]const ?LocalWidth {
    return (try routedPowerRequirementsFromSurfaces(alloc, placement, routed, surfaces)).tracks;
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
        // A rail with no declared current on either axis can only ever answer
        // `no-current`, and neither its sheet contact map nor its conductance
        // graph changes that. Ground takes this door.
        const currentless = demand.typical_a == null and demand.maximum_a == null;
        const poured: Poured = if (currentless)
            .{ .surfaces = surfaces }
        else
            try pourFor(alloc, placement, routed, family, surfaces);
        const solved = if (currentless)
            try currentlessSolve(alloc, routed)
        else
            try solveCurrent(alloc, placement, routed, family, demand, poured);
        const flow = solved.flow;
        const tracks = try analyzeTracks(alloc, placement, routed, family, demand, flow);
        const vias = try analyzeVias(alloc, placement, routed, family, demand, flow);
        const planes = try analyzePlanes(alloc, placement, net.name, demand, poured, flow);
        if (tracks.len == 0 and vias.len == 0 and planes.len == 0) continue;
        try nets.append(alloc, .{
            .index = net_index,
            .name = net.name,
            .demand = demand,
            .flow = solved.diagnosis(),
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
    try testing.expectEqual(power_current.Status.solved, result.nets[0].flow.typical.status);
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
    const sources = try sourceContacts(alloc, placement, family, &.{"@external/VDD"});
    try testing.expectEqual(@as(usize, 1), sources.contacts.len);
    try testing.expectApproxEqAbs(@as(f64, 0), sources.contacts[0].at[0], 1e-9);
    // The per-terminal tally is what names the terminal that found nothing.
    try testing.expectEqual(@as(usize, 1), sources.per_terminal.len);
    try testing.expectEqualStrings("@external/VDD", sources.per_terminal[0].terminal);
    try testing.expectEqual(@as(usize, 1), sources.per_terminal[0].contacts);
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

// spec: placement/power-routing - the sheet contact map credits every pad geometry, so a pin's plated pad-vias carry the rail into an inner plane even when its outer land does not
test "an inner plane credits a pin's pad-vias, not only its first geometry" {
    const geometry = @import("geometry.zig");
    // A regulator output pin drawn the way real buck footprints are: one outer
    // land, plus plated pad-vias that carry the rail down to the inner plane.
    const vout = [_]geometry.Pad{
        .{ .number = "VOUT", .x = 2, .y = 2, .w = 0.4, .h = 0.4 },
        .{ .number = "VOUT", .x = 0.5, .y = 0.5, .w = 0.3, .h = 0.3, .thru = true },
    };
    const parts = [_]optimizer.Part{
        .{ .ref_des = "buck/U1", .kind = .hub, .hw = 1.5, .hh = 1.5, .pads = &vout, .fallback = false, .x = 0, .y = 0 },
    };
    const pins = [_]flat_netlist.FlatPin{.{ .ref_des = "buck/U1", .pin = "VOUT" }};
    const nets = [_]optimizer.FlatNet{.{ .name = "V_3V3D", .pins = &pins }};
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
    // One filled inner plane component over [0,1] x [0,1]: it reaches the
    // pad-vias and never the outer land at (2,2).
    const labels: [100]i32 = @splat(0);
    const surfaces = [_]Surface{.{
        .net = "V_3V3D",
        .kind = .plane,
        .physical_layer = 3,
        .signal_layer = null,
        .fill = .{
            .frame = .{ .minx = 0, .miny = 0, .pitch = 0.1, .nx = 10, .ny = 10 },
            .labels = &labels,
            .n_comp = 1,
            .contours = &.{},
            .holes = &.{},
            .coarsened = false,
        },
    }};
    const family = try familyFor(arena, placement, .{}, 0);
    // The one-contact-per-pin spelling looked at the FIRST geometry only, and
    // that land is not on the plane at all.
    const first = contactForPin(placement, pins[0]).?;
    try testing.expectEqual(@as(i32, -1), surfaces[0].fill.componentAt(first.at[0], first.at[1]));

    const routed = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 0 };
    const lands = try landsFor(arena, placement, family);
    try testing.expectEqual(@as(usize, 2), lands.len);
    const sheets = try sheetsForNet(arena, routed, family, &surfaces, lands);
    try testing.expectEqual(@as(usize, 1), sheets.sheets.len);
    try testing.expectEqual(@as(usize, 1), sheets.sheets[0].contacts.len);
    try testing.expectApproxEqAbs(@as(f64, 0.5), sheets.sheets[0].contacts[0][0], 1e-9);
}

// spec: placement/power-routing - a source terminal whose sub-block carries no hub pad on the rail resolves the discrete pads the current physically enters through
test "a source terminal with no hub pad on the rail falls back to its sub-block's discretes" {
    const geometry = @import("geometry.zig");
    const one = geometry.Pad{ .number = "1", .x = 0, .y = 0, .w = 0.2, .h = 0.2 };
    // A boost output node: the catch diode, the reservoir cap and the feedback
    // divider form the rail. No converter pin sits on it at all.
    const parts = [_]optimizer.Part{
        .{ .ref_des = "boost22/D1", .kind = .passive, .hw = 0.1, .hh = 0.1, .pads = &.{one}, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "boost22/C5", .kind = .passive, .hw = 0.1, .hh = 0.1, .pads = &.{one}, .fallback = false, .x = 1, .y = 0 },
        .{ .ref_des = "amp/U1", .kind = .hub, .hw = 0.1, .hh = 0.1, .pads = &.{one}, .fallback = false, .x = 3, .y = 0 },
    };
    const pins = [_]flat_netlist.FlatPin{
        .{ .ref_des = "boost22/D1", .pin = "1" },
        .{ .ref_des = "boost22/C5", .pin = "1" },
        .{ .ref_des = "amp/U1", .pin = "1" },
    };
    const nets = [_]optimizer.FlatNet{.{ .name = "V_25V_RAW", .pins = &pins }};
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
    };
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const family = try familyFor(arena, placement, .{}, 0);
    const sources = try sourceContacts(arena, placement, family, &.{"boost22/V_25V_RAW"});
    try testing.expectEqual(@as(usize, 2), sources.contacts.len);
    try testing.expectEqual(@as(usize, 2), sources.per_terminal[0].contacts);
    // The load's own hub pad is NOT a source: the fallback stays inside the
    // terminal's own sub-block.
    for (sources.contacts) |contact| try testing.expect(contact.at[0] < 2);

    // A sub-block that does carry a converter pin keeps the hub-only answer:
    // the discretes beside it are not second voltage sources.
    const hub_parts = [_]optimizer.Part{
        .{ .ref_des = "boost22/D1", .kind = .passive, .hw = 0.1, .hh = 0.1, .pads = &.{one}, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "boost22/U7", .kind = .hub, .hw = 0.1, .hh = 0.1, .pads = &.{one}, .fallback = false, .x = 1, .y = 0 },
    };
    const hub_pins = [_]flat_netlist.FlatPin{
        .{ .ref_des = "boost22/D1", .pin = "1" },
        .{ .ref_des = "boost22/U7", .pin = "1" },
    };
    const hub_nets = [_]optimizer.FlatNet{.{ .name = "V_25V_RAW", .pins = &hub_pins }};
    var hub_placement = placement;
    hub_placement.parts = @constCast(&hub_parts);
    hub_placement.nets = &hub_nets;
    const hub_family = try familyFor(arena, hub_placement, .{}, 0);
    const hub_sources = try sourceContacts(arena, hub_placement, hub_family, &.{"boost22/V_25V_RAW"});
    try testing.expectEqual(@as(usize, 1), hub_sources.contacts.len);
    try testing.expectApproxEqAbs(@as(f64, 1), hub_sources.contacts[0].at[0], 1e-9);
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

// ── Per-via current requirements ────────────────────────────────────────────
//
// The barrel twin of `routedTrackRequiredWidths*` above, kept as one
// self-contained block: same three seams (bare / memoised / prepared fills),
// same demand gating, same "maximum axis when a maximum is declared" rule, and
// the same conservative whole-rail fallback when the solve does not resolve.
//
// It exists because a via had no capacity rule at all. The pre-route geometry
// used to compensate by fattening EVERY barrel on a rail to the drill one
// barrel would need for the whole rail current, which is both wrong (the solver
// splits current between parallel barrels) and expensive (a fat barrel that
// cannot clear its neighbours fails the route). Post-route the answer is
// local: this reports what each barrel actually carries, and `drc_power_via`
// turns that into "add N vias here".

/// What one routed via barrel is asked to carry, and what it can carry.
/// Produced index-aligned with `routed.vias`; null for a barrel on a net with
/// no declared current demand, which is the only case with no answer at all.
pub const ViaCurrent = struct {
    /// Current charged to this barrel, in amperes.
    current_a: f64,
    /// This barrel's IPC-2221 plated-area capacity at the screen's
    /// temperature rise, in amperes.
    capacity_a: f64,
    /// True when `current_a` is the WHOLE-RAIL envelope rather than this
    /// barrel's solved share, because the net's current solve did not resolve.
    /// It is an upper bound on any one barrel, so a reader must credit the
    /// parallel barrels beside it before calling the transition undersized.
    envelope: bool,
    /// Why the solve produced what it did (`power_current.Status.name`).
    reason: []const u8,

    /// How many barrels of this geometry the charged current needs — the
    /// number a repair message counts down from. At least one whenever the
    /// geometry is judgeable at all.
    pub fn requiredCount(self: ViaCurrent) usize {
        return countFor(self.current_a, self.capacity_a) orelse 1;
    }
};

/// Continuous-current capacity of one routed barrel, from the board's own
/// plating rule and the barrel's drill (or its land minus two plating walls
/// when a saved via records no drill).
fn viaBarrelCapacityA(placement: optimizer.Placement, via: router.Via) f64 {
    const plating_mm = placement.rules.physical.via_plating_mm;
    const drill = if (via.drill > 0) via.drill else @max(0, via.dia - 2.0 * plating_mm);
    return capacityForArea(std.math.pi * drill * plating_mm, false, temperature_rise_c);
}

/// Solved local current and barrel capacity for every routed via, index-aligned
/// with `routed.vias`. The barrel spelling of `routedTrackRequiredWidths`.
pub fn routedViaRequirements(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    routed: router.RouteResult,
) std.mem.Allocator.Error![]const ?ViaCurrent {
    return routedViaRequirementsMemo(alloc, placement, routed, null);
}

/// `routedViaRequirements` with a per-fill memo, on exactly the terms
/// `routedTrackRequiredWidthsMemo` states: the only surfaces it can ever want
/// are ordinary declared plane/pour fills of this board, so they are keyed and
/// reused like any other, and a null memo is the unmemoised spelling. The
/// pour is gated by the SAME predicate as the track twin, so adding this rule
/// cannot make any caller raster a board it was not already rastering.
pub fn routedViaRequirementsMemo(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    routed: router.RouteResult,
    memo: ?pour.FillMemo,
) std.mem.Allocator.Error![]const ?ViaCurrent {
    var needs_surfaces = false;
    if (routed.vias.len > 0) for (placement.nets, 0..) |net, net_index| {
        const demand = demandFor(placement.rules.physical.rails, net.name);
        const has_demand = demand.typical_a != null or demand.maximum_a != null;
        const branch_opted = net_index < placement.rules.net.len and
            placement.rules.net[net_index].pad_neck.power_branch_width > 0;
        if (has_demand and branch_opted and router.netHasPlane(placement, net.name)) {
            needs_surfaces = true;
            break;
        }
    };
    const surfaces = if (needs_surfaces)
        try buildSurfaces(alloc, placement, routed, &.{}, null, memo)
    else
        &.{};
    return routedViaRequirementsFromSurfaces(alloc, placement, routed, surfaces);
}

/// The reporting DRC spelling: consume the exact carrying-layer and user-zone
/// fills the seam already poured, so a plane-backed rail's barrels are judged
/// against a solved sheet instead of falling back to the whole-rail envelope.
pub fn routedViaRequirementsPrepared(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    routed: router.RouteResult,
    plane_fills: []const pour.NetFills,
    zones: []const pour.UserZone,
    zone_fills: []const pour.Fill,
) std.mem.Allocator.Error![]const ?ViaCurrent {
    const surfaces = try preparedSurfaces(alloc, placement, plane_fills, zones, zone_fills);
    return routedViaRequirementsFromSurfaces(alloc, placement, routed, surfaces);
}

fn routedViaRequirementsFromSurfaces(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    routed: router.RouteResult,
    surfaces: []const Surface,
) std.mem.Allocator.Error![]const ?ViaCurrent {
    if (routed.vias.len == 0) return try alloc.alloc(?ViaCurrent, 0);
    return (try routedPowerRequirementsFromSurfaces(alloc, placement, routed, surfaces)).vias;
}

// ── One solve, two rules ────────────────────────────────────────────────────

/// A two-layer rail: a source pad, a track up to a barrel, the barrel, and a
/// track on down to the load pad. The smallest board that exercises BOTH
/// power-copper rules at once, which is what the shared solve has to answer
/// identically to the two per-array spellings.
const LayerJumpRig = struct {
    parts: [2]optimizer.Part,
    pins: [2]flat_netlist.FlatPin,
    nets: [1]optimizer.FlatNet,
    consumers: [1]power_budget.RailConsumer,
    terminals: [1][]const u8,
    rails: [1]power_budget.Rail,

    const pad = @import("geometry.zig").Pad{ .number = "1", .x = 0, .y = 0, .w = 0.2, .h = 0.2, .thru = true };
    const pads = [_]@import("geometry.zig").Pad{pad};
    const foils = [_]@import("impedance.zig").Foil{
        .{ .index = 1, .thickness_mm = 0.035 },
        .{ .index = 2, .thickness_mm = 0.035 },
    };

    fn init(amps: f64) LayerJumpRig {
        return .{
            .parts = .{
                .{ .ref_des = "src/U1", .kind = .hub, .hw = 0.1, .hh = 0.1, .pads = &pads, .fallback = false, .x = 0, .y = 0 },
                .{ .ref_des = "load/U1", .kind = .hub, .hw = 0.1, .hh = 0.1, .pads = &pads, .fallback = false, .x = 4, .y = 0 },
            },
            .pins = .{
                .{ .ref_des = "src/U1", .pin = "1" },
                .{ .ref_des = "load/U1", .pin = "1" },
            },
            .nets = .{.{ .name = "VDD", .pins = &.{} }},
            .consumers = .{.{ .ref_des = "load/U1", .net = "VDD", .pins = &.{"1"}, .i_typ = amps, .i_max = amps }},
            .terminals = .{"src/VOUT"},
            .rails = .{.{
                .net = "VDD",
                .load_typ_a = amps,
                .load_max_a = amps,
                .any_typ_load = true,
                .any_max_load = true,
                .status = .no_source,
            }},
        };
    }

    fn placement(self: *LayerJumpRig) optimizer.Placement {
        self.nets[0].pins = &self.pins;
        self.rails[0].consumers = &self.consumers;
        self.rails[0].source_terminals = &self.terminals;
        return .{
            .parts = &self.parts,
            .links = &.{},
            .loops = &.{},
            .stubs = &.{},
            .instances = &.{},
            .nets = &self.nets,
            .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
            .minx = 0,
            .miny = -1,
            .maxx = 4,
            .maxy = 1,
            .generated = true,
            .rules = .{
                .copper_layers = 2,
                .physical = .{
                    .board_thickness = 1.6,
                    .via_plating_mm = 0.02,
                    .stack = .{ .layers = 2, .foils = &foils, .board_mm = 1.6 },
                    .rails = &self.rails,
                },
            },
        };
    }
};

const layer_jump_tracks = [_]router.Track{
    .{ .x1 = 0, .y1 = 0, .x2 = 2, .y2 = 0, .layer = 0, .width = 0.5, .net = 0 },
    .{ .x1 = 2, .y1 = 0, .x2 = 4, .y2 = 0, .layer = 1, .width = 0.5, .net = 0 },
};
const layer_jump_vias = [_]router.Via{.{ .x = 2, .y = 0, .dia = 0.4, .drill = 0.2, .net = 0 }};

// spec: placement/power-routing - one shared current solve answers the track-width and via-current rules with exactly the arrays the two per-rule entry points return
test "the shared power requirements equal the two per-array spellings" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const alloc = arena_inst.allocator();
    var rig = LayerJumpRig.init(0.62);
    const placement = rig.placement();
    const routed = router.RouteResult{ .tracks = &layer_jump_tracks, .vias = &layer_jump_vias, .routed = 1, .total = 1 };

    const both = try routedPowerRequirements(alloc, placement, routed);
    const widths = try routedTrackRequiredWidths(alloc, placement, routed);
    const barrels = try routedViaRequirements(alloc, placement, routed);

    try expectSameWidths(widths, both.tracks);
    try expectSameVias(barrels, both.vias);
    // The rig is only worth anything if it actually solved and actually put the
    // rail's whole current through the one barrel that carries it.
    try testing.expect(!both.vias[0].?.envelope);
    try testing.expectApproxEqAbs(@as(f64, 0.62), both.vias[0].?.current_a, 1e-6);
    try testing.expect(!both.tracks[0].?.envelope);

    // …and an unsolvable rail agrees on the envelope verdict too, which is the
    // half of the answer the two rules used to reach by solving twice.
    var missing = rig;
    missing.terminals = .{"missing/VOUT"};
    const unsolved = missing.placement();
    const both_unsolved = try routedPowerRequirements(alloc, unsolved, routed);
    try expectSameWidths(try routedTrackRequiredWidths(alloc, unsolved, routed), both_unsolved.tracks);
    try expectSameVias(try routedViaRequirements(alloc, unsolved, routed), both_unsolved.vias);
    try testing.expect(both_unsolved.tracks[0].?.envelope);
    try testing.expectEqualStrings("no-source-terminal", both_unsolved.vias[0].?.reason);
}

/// Two required-width arrays agree entry for entry, presence included.
fn expectSameWidths(want: []const ?LocalWidth, got: []const ?LocalWidth) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |a, b| {
        try testing.expectEqual(a == null, b == null);
        if (a) |width| {
            try testing.expectApproxEqAbs(width.width_mm, b.?.width_mm, 1e-12);
            try testing.expectEqual(width.envelope, b.?.envelope);
            try testing.expectEqualStrings(width.reason, b.?.reason);
        }
    }
}

/// Two barrel-current arrays agree entry for entry, presence included.
fn expectSameVias(want: []const ?ViaCurrent, got: []const ?ViaCurrent) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |a, b| {
        try testing.expectEqual(a == null, b == null);
        if (a) |via| {
            try testing.expectApproxEqAbs(via.current_a, b.?.current_a, 1e-12);
            try testing.expectApproxEqAbs(via.capacity_a, b.?.capacity_a, 1e-12);
            try testing.expectEqual(via.envelope, b.?.envelope);
            try testing.expectEqualStrings(via.reason, b.?.reason);
        }
    }
}

// spec: placement/power-routing - a net declaring no current is answered no-current without building a copper graph or rastering its sheet contacts
test "a currentless net short-circuits before the copper graph and the sheet raster" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const alloc = arena_inst.allocator();
    const routed = router.RouteResult{ .tracks = &layer_jump_tracks, .vias = &layer_jump_vias, .routed = 1, .total = 1 };

    // Ground's shape: real copper, real barrels, and not one declared ampere.
    // `needsGraph` is the solver's own statement that it will answer from the
    // pre-status alone, which is what lets `analyzeCopper` skip both the
    // quadratic junction sweep and the sheet contact raster for this net.
    try testing.expect(!power_current.needsGraph(.{
        .segments = &.{.{ .route_index = 0, .a = .{ 0, 0 }, .b = .{ 2, 0 }, .layer = 0, .resistance_ohm_per_mm = 1, .width_mm = 0.5 }},
        .barrels = &.{.{ .route_index = 0, .at = .{ 2, 0 }, .resistance_ohm = 0.002, .radius_mm = 0.2 }},
        .counts = .{ .tracks = routed.tracks.len, .vias = routed.vias.len },
        .source = .{ .contacts = &.{}, .complete = false },
        .loads = &.{},
    }));

    const solved = try currentlessSolve(alloc, routed);
    try testing.expectEqual(power_current.Status.no_current, solved.flow.typical.status);
    try testing.expectEqual(power_current.Status.no_current, solved.flow.maximum.status);
    try testing.expectEqual(@as(usize, 0), solved.loads.len);
    // The arrays a currentless answer hands back are still route-index shaped,
    // so `analyzeTracks`/`analyzeVias` read them exactly as they read a solve.
    try testing.expectEqual(routed.tracks.len, solved.flow.typical.track_current_a.len);
    try testing.expectEqual(routed.vias.len, solved.flow.maximum.via_current_a.len);

    // A rail that DOES declare current is not short-circuited by any of this.
    var rig = LayerJumpRig.init(0.62);
    const analysis = try analyzeCopper(alloc, rig.placement(), routed, &.{}, null);
    try testing.expectEqual(power_current.Status.solved, analysis.nets[0].flow.typical.status);
}

// spec: placement/power-routing - the per-net diagnosis names every source terminal's contact count and every load's contacts, pin completeness and per-axis placement
test "the rail diagnosis names the load that failed to resolve" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const alloc = arena_inst.allocator();
    const routed = router.RouteResult{ .tracks = &layer_jump_tracks, .vias = &layer_jump_vias, .routed = 1, .total = 1 };

    var rig = LayerJumpRig.init(0.62);
    const solved = try analyzeCopper(alloc, rig.placement(), routed, &.{}, null);
    const flow = solved.nets[0].flow;
    try testing.expectEqual(@as(usize, 1), flow.sources.len);
    try testing.expectEqualStrings("src/VOUT", flow.sources[0].terminal);
    try testing.expectEqual(@as(usize, 1), flow.sources[0].contacts);
    try testing.expectEqual(@as(usize, 1), flow.loads.len);
    try testing.expectEqualStrings("load/U1", flow.loads[0].ref);
    try testing.expectEqual(@as(usize, 1), flow.loads[0].contacts);
    try testing.expect(flow.loads[0].complete);
    try testing.expect(flow.loads[0].placed.typical and flow.loads[0].placed.maximum);
    try testing.expectApproxEqAbs(@as(f64, 0), flow.typical.unplaced_a, 1e-12);

    // A consumer named on a reference designator the board does not carry is
    // the `incomplete-load-terminals` story, and the diagnosis says WHICH one.
    var orphaned = rig;
    orphaned.consumers = .{.{ .ref_des = "ghost/U9", .net = "VDD", .pins = &.{"1"}, .i_typ = 0.62, .i_max = 0.62 }};
    const broken = try analyzeCopper(alloc, orphaned.placement(), routed, &.{}, null);
    const bad = broken.nets[0].flow;
    try testing.expectEqual(power_current.Status.incomplete_load_terminals, bad.typical.status);
    try testing.expectEqualStrings("ghost/U9", bad.loads[0].ref);
    try testing.expectEqual(@as(usize, 0), bad.loads[0].contacts);
    try testing.expect(!bad.loads[0].complete);
    try testing.expect(!bad.loads[0].placed.typical);

    // A source terminal naming nothing on the board reports zero contacts,
    // which is the whole of the `no-source-terminal` explanation.
    var unsourced = rig;
    unsourced.terminals = .{"missing/VOUT"};
    const no_source = try analyzeCopper(alloc, unsourced.placement(), routed, &.{}, null);
    try testing.expectEqual(power_current.Status.no_source_terminal, no_source.nets[0].flow.maximum.status);
    try testing.expectEqual(@as(usize, 0), no_source.nets[0].flow.sources[0].contacts);
}
