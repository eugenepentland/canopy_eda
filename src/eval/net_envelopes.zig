//! Worst-case DC voltage envelopes per FLAT net name — the data that lets a
//! release rating check say what potential a part's copper actually sees.
//!
//! `eval/rails` answers a different question and answers it at one level: it
//! emits a supply-tree node per `block.sub_blocks[…].ports` output, so a rail is
//! always a TOP-level net. That leaves every node one step further in
//! unnameable — the far side of a module's own input ferrite (`buck_5v75/VIN_F`,
//! `hmc733/V_5VA_FILT`, `lna/VDD_FILT`), which is where a module's decoupling
//! and its feedback divider actually sit. On Barracuda that was 139 of the 172
//! `component-rating-unproven` findings: the parts were correctly chosen, the
//! board simply had no vocabulary for the net they are on.
//!
//! Three things are joined here, and all three are needed for a name to match:
//!
//!   1. **Flattening.** Names come from `flat_netlist.flattenAndMergeNetsMapped`,
//!      the same pass the netlist, the placer and the fab gate see, so a derived
//!      envelope is keyed by the name the checker will look up — including the
//!      `sub-block/` prefix and the `(bridge (rename …))` canonicalisation that
//!      collapses `buck_5v75/VIN` onto `V_12V`.
//!   2. **Seeds.** Every declared voltage in the tree: `block.rails`, and every
//!      port at every depth carrying a `(nominal)` or `(rated lo hi)`.
//!   3. **Ferrite propagation.** A ferrite bead is a DC conductor, so its two
//!      nets share a potential. Unlike `net_analysis.buildFerriteBridges` — which
//!      walks `block.instances` and therefore sees only top-level beads — this
//!      runs over the FLATTENED instance list, so a bead declared inside a module
//!      bridges just as well as one on the board.
//!
//! Authored `(net-envelope …)` declarations enter as `.declared` seeds for the
//! cases topology cannot reach: a 3.3 V GPIO driving an enable, a divider tap
//! bounded by two rails. They are checked against the derived result rather than
//! trusted over it — see `contradictions`.

const std = @import("std");
const env_mod = @import("env.zig");
const flat_netlist = @import("../flat_netlist.zig");
const na = @import("net_analysis.zig");

const DesignBlock = env_mod.DesignBlock;
const NetEnvelope = env_mod.NetEnvelope;

/// Ferrite components are recognised by component-name prefix, matching the
/// rule `net_analysis.buildFerriteBridges` already applies board-wide.
const ferrite_prefix = "ferrite";

/// A seeded potential range before propagation. Kept apart from `NetEnvelope`
/// so the merge step can widen bounds in place without republishing strings.
const Span = struct {
    min: f64,
    max: f64,
    origin: NetEnvelope.Origin,
    rationale: []const u8,

    fn widen(self: *Span, other: Span) void {
        self.min = @min(self.min, other.min);
        self.max = @max(self.max, other.max);
        // A declared rationale is the only text worth carrying, and the first
        // one wins so output is independent of hash-map iteration order.
        if (self.origin == .derived and other.origin == .declared) {
            self.origin = .declared;
            self.rationale = other.rationale;
        }
    }
};

/// One authored `(net-envelope "NET" (rated LO HI) ["why"])`, before the net
/// name has been resolved against the flattened netlist.
pub const Declaration = struct {
    net: []const u8,
    min: f64,
    max: f64,
    rationale: []const u8 = "",
};

/// A `.declared` envelope that fails to cover the envelope the design's own
/// declarations already prove for the same net. Reported by the caller as a
/// failed assertion, because the two statements cannot both be true.
pub const Contradiction = struct {
    net: []const u8,
    declared_min: f64,
    declared_max: f64,
    derived_min: f64,
    derived_max: f64,
};

/// The full result: the envelope set to publish on the block, plus any authored
/// declaration that disagrees with it. Both slices are caller-owned.
pub const Result = struct {
    envelopes: []const NetEnvelope = &.{},
    contradictions: []const Contradiction = &.{},
};

/// Derive every net's worst-case DC envelope. See the module comment for the
/// three inputs; the returned names are flattened net names ready to match
/// against a flat netlist. `declarations` may be empty.
///
/// `allocator` must be an arena or the page allocator: the flatten this builds
/// on allocates every prefixed net name and never frees one, the same contract
/// `flat_netlist` has with the exporters and the placer.
pub fn build(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    declarations: []const Declaration,
) std.mem.Allocator.Error!Result {
    var nets: std.ArrayList(flat_netlist.FlatNet) = .empty;
    defer nets.deinit(allocator);
    var aliases: flat_netlist.CanonicalNetMap = .empty;
    defer aliases.deinit(allocator);
    try flat_netlist.flattenAndMergeNetsMapped(allocator, block, &nets, &aliases);

    var instances: std.ArrayList(flat_netlist.FlatInstance) = .empty;
    defer instances.deinit(allocator);
    try flat_netlist.collectInstances(allocator, block, "", &instances);

    var parent = try ferriteBridges(allocator, instances.items, nets.items);
    defer parent.deinit(allocator);

    // Seed by union-find root so a bead's two nets share one potential.
    var by_root: std.StringHashMapUnmanaged(Span) = .empty;
    defer by_root.deinit(allocator);
    try seedRails(allocator, block, &aliases, &parent, &by_root);
    var path: std.ArrayList(u8) = .empty;
    defer path.deinit(allocator);
    try seedPorts(allocator, block, &path, &aliases, &parent, &by_root);

    // The derived answer must be readable on its own before declarations widen
    // it, or a contradiction would be compared against itself.
    var derived_roots = try by_root.clone(allocator);
    defer derived_roots.deinit(allocator);

    var contradictions: std.ArrayList(Contradiction) = .empty;
    defer contradictions.deinit(allocator);
    for (declarations) |decl| {
        if (!(decl.max >= decl.min)) continue;
        const root = rootOf(&aliases, &parent, decl.net);
        const span = Span{ .min = decl.min, .max = decl.max, .origin = .declared, .rationale = decl.rationale };
        if (derived_roots.get(root)) |derived| {
            if (decl.min > derived.min or decl.max < derived.max) try contradictions.append(allocator, .{
                .net = decl.net,
                .declared_min = decl.min,
                .declared_max = decl.max,
                .derived_min = derived.min,
                .derived_max = derived.max,
            });
        }
        try put(allocator, &by_root, root, span);
    }

    // Emit one entry per flat net whose class carries a potential. Nets with no
    // seed anywhere in their class are simply absent — an absent envelope is
    // "not proven", which is the honest answer and the status quo.
    var out: std.ArrayList(NetEnvelope) = .empty;
    for (nets.items) |net| {
        const span = by_root.get(na.findRoot(&parent, net.name)) orelse continue;
        try out.append(allocator, .{
            .net = net.name,
            .min = span.min,
            .max = span.max,
            .origin = span.origin,
            .rationale = span.rationale,
        });
    }
    std.mem.sort(NetEnvelope, out.items, {}, lessThanEnvelope);
    return .{
        .envelopes = try out.toOwnedSlice(allocator),
        .contradictions = try contradictions.toOwnedSlice(allocator),
    };
}

fn lessThanEnvelope(_: void, a: NetEnvelope, b: NetEnvelope) bool {
    return std.mem.order(u8, a.net, b.net) == .lt;
}

/// Follow a hierarchy-local name to its canonical flat name, then to its
/// ferrite-class root. Both hops are identity when nothing applies, so an
/// already-canonical unbridged name maps to itself.
///
/// `name` may point at a caller's scratch buffer: the alias map is keyed by
/// CONTENT and yields a string the flatten owns, so every root this returns
/// outlives the call — except the identity case, where the caller's own name is
/// returned and must itself be stable.
fn rootOf(
    aliases: *const flat_netlist.CanonicalNetMap,
    parent: *std.StringHashMapUnmanaged([]const u8),
    name: []const u8,
) []const u8 {
    return na.findRoot(parent, aliases.get(name) orelse name);
}

fn put(
    allocator: std.mem.Allocator,
    by_root: *std.StringHashMapUnmanaged(Span),
    root: []const u8,
    span: Span,
) std.mem.Allocator.Error!void {
    const gop = try by_root.getOrPut(allocator, root);
    if (gop.found_existing) gop.value_ptr.widen(span) else gop.value_ptr.* = span;
}

/// Every derived rail already carries a proven envelope; seeding them here is
/// what lets a rail's potential cross a module-internal bead onto a net the
/// rails pass never named.
fn seedRails(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    aliases: *const flat_netlist.CanonicalNetMap,
    parent: *std.StringHashMapUnmanaged([]const u8),
    by_root: *std.StringHashMapUnmanaged(Span),
) std.mem.Allocator.Error!void {
    for (block.rails) |rail| {
        const low = rail.rated_voltage.min orelse rail.nominal orelse continue;
        const high = rail.rated_voltage.max orelse rail.nominal orelse continue;
        const span = Span{ .min = @min(low, high), .max = @max(low, high), .origin = .derived, .rationale = "" };
        try put(allocator, by_root, rootOf(aliases, parent, rail.name), span);
        for (rail.aliases) |alias| try put(allocator, by_root, rootOf(aliases, parent, alias), span);
    }
}

/// Which of a port's declared numbers actually describe the NET, rather than
/// the part behind the pin. The distinction decides correctness, not taste.
///
/// A `(rated LO HI)` on an OUTPUT, or on a board-edge port, is a supply
/// statement: this is what the port drives, or what the board is fed. On an
/// INTERNAL INPUT it is the opposite — the pin's tolerated range, the datasheet
/// absolute maximum. Seeding those would let a consumer's tolerance rewrite the
/// potential of the rail feeding it: Barracuda ties `bcuda-boost25`'s
/// `(port "EN_25V" in signal (nominal 3.3) (rated 0.0 3.6))` straight to
/// `V_5VA`, and reading that 0 V floor as a rail fact widened the whole 5 V
/// domain to 0–5.25 V, which then "proved" a 91 Ω LNA feed resistor at 0.30 W
/// against its 0.1 W rating. That finding was an artefact of the rule, not a
/// fault in the board. (The tie itself is a real design question — a 5 V rail on
/// a pin rated to 3.6 V — but it is a question for ERC, not for this table.)
///
/// A bare `(nominal V)` with no rated range is kept from any direction: with
/// nothing to tolerate, the only thing it can be saying is where the net sits.
fn portSpan(port: env_mod.Port, supply_side: bool) ?Span {
    const low, const high = if (supply_side)
        .{ port.rated_min orelse port.nominal, port.rated_max orelse port.nominal }
    else if (port.rated_min == null and port.rated_max == null)
        .{ port.nominal, port.nominal }
    else
        .{ null, null };
    const lo = low orelse return null;
    const hi = high orelse return null;
    return .{ .min = @min(lo, hi), .max = @max(lo, hi), .origin = .derived, .rationale = "" };
}

/// Walk every port at every depth, seeding the ones `portSpan` accepts. The
/// `path` prefix is what makes a module-internal net nameable at all.
/// `path` is a growable scratch buffer holding the current `sub-block/…` prefix.
/// It is truncated back on the way out of each level, so the whole descent
/// costs one allocation and no scoped name outlives its frame — the map key
/// actually stored is the canonical name the flatten owns (see `rootOf`).
fn seedPorts(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    path: *std.ArrayList(u8),
    aliases: *const flat_netlist.CanonicalNetMap,
    parent: *std.StringHashMapUnmanaged([]const u8),
    by_root: *std.StringHashMapUnmanaged(Span),
) std.mem.Allocator.Error!void {
    const base = path.items.len;
    for (block.ports) |port| {
        // A board-edge port (no path) states what enters or leaves the board;
        // an output states what it drives. Both are supply-side facts.
        const span = portSpan(port, base == 0 or std.mem.eql(u8, port.direction, "out")) orelse continue;
        path.shrinkRetainingCapacity(base);
        try path.appendSlice(allocator, if (port.net.len > 0) port.net else port.name);
        // A port naming a net no pin sits on proves nothing about copper, and
        // its scoped name is a scratch slice — so an alias miss must not seed.
        const canonical = aliases.get(path.items) orelse continue;
        try put(allocator, by_root, na.findRoot(parent, canonical), span);
    }
    for (block.sub_blocks) |sb| {
        path.shrinkRetainingCapacity(base);
        try path.appendSlice(allocator, sb.name);
        try path.append(allocator, '/');
        try seedPorts(allocator, sb.block, path, aliases, parent, by_root);
    }
    path.shrinkRetainingCapacity(base);
}

/// Union-find over FLAT net names bridged by ferrite beads, at any hierarchy
/// depth. Mirrors `net_analysis.buildFerriteBridges` exactly — pad `1`↔pad `2`
/// first, else a by-membership bridge when the bead touches exactly two nets —
/// but reads the flattened instance/net lists so a bead inside a module counts.
fn ferriteBridges(
    allocator: std.mem.Allocator,
    instances: []const flat_netlist.FlatInstance,
    nets: []const flat_netlist.FlatNet,
) std.mem.Allocator.Error!std.StringHashMapUnmanaged([]const u8) {
    var parent: std.StringHashMapUnmanaged([]const u8) = .empty;
    errdefer parent.deinit(allocator);
    for (instances) |inst| {
        if (!std.mem.startsWith(u8, inst.component, ferrite_prefix)) continue;
        var pad_a: ?[]const u8 = null;
        var pad_b: ?[]const u8 = null;
        var first: ?[]const u8 = null;
        var second: ?[]const u8 = null;
        var multi = false;
        for (nets) |net| {
            var touches = false;
            for (net.pins) |p| {
                if (!std.mem.eql(u8, p.ref_des, inst.ref_des)) continue;
                touches = true;
                if (std.mem.eql(u8, p.pin, "1")) pad_a = net.name;
                if (std.mem.eql(u8, p.pin, "2")) pad_b = net.name;
            }
            if (!touches) continue;
            if (first == null) {
                first = net.name;
            } else if (!std.mem.eql(u8, first.?, net.name)) {
                if (second == null) second = net.name else if (!std.mem.eql(u8, second.?, net.name)) multi = true;
            }
        }
        if (pad_a != null and pad_b != null) {
            try unionNets(allocator, &parent, pad_a.?, pad_b.?);
        } else if (!multi) {
            if (first) |a| if (second) |b| try unionNets(allocator, &parent, a, b);
        }
    }
    return parent;
}

fn unionNets(
    allocator: std.mem.Allocator,
    parent: *std.StringHashMapUnmanaged([]const u8),
    a: []const u8,
    b: []const u8,
) std.mem.Allocator.Error!void {
    const ra = na.findRoot(parent, a);
    const rb = na.findRoot(parent, b);
    if (std.mem.eql(u8, ra, rb)) return;
    try parent.put(allocator, rb, ra);
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

fn envelopeFor(result: Result, net: []const u8) ?NetEnvelope {
    for (result.envelopes) |e| if (std.mem.eql(u8, e.net, net)) return e;
    return null;
}

/// `build` flattens, and a flatten never frees the names it mints — so every
/// test runs on an arena rather than the leak-checking test allocator.
fn arena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(testing.allocator);
}

// spec: eval/net-envelopes - Derives a voltage envelope for a sub-block-internal net across a module-internal ferrite bead
test "build carries a rail envelope across a module-internal ferrite" {
    var scratch = arena();
    defer scratch.deinit();
    const alloc = scratch.allocator();
    // The shape every buck on Barracuda has: the board rail is bridged onto the
    // module's VIN port, and the module's OWN input bead separates that from the
    // VIN_F node its decoupling and its converter pin actually sit on.
    const bead = env_mod.Instance{
        .ref_des = "FB1",
        .component = "ferrite-0805",
        .value = "",
        .footprint = "",
        .symbol = "",
    };
    const inner_insts = [_]env_mod.Instance{bead};
    const inner_nets = [_]env_mod.Net{
        .{ .name = "VIN", .pins = &[_]env_mod.PinRef{.{ .ref_des = "FB1", .pin = "1" }} },
        .{ .name = "VIN_F", .pins = &[_]env_mod.PinRef{.{ .ref_des = "FB1", .pin = "2" }} },
    };
    var inner: DesignBlock = .{
        .name = "buck",
        .instances = &inner_insts,
        .nets = &inner_nets,
        .ports = &[_]env_mod.Port{.{ .name = "VIN", .net = "VIN", .direction = "in", .kind = "power" }},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    const sbs = [_]env_mod.SubBlock{.{ .name = "buck", .block = &inner }};
    const ties = [_]env_mod.NetTie{.{ .a = "V_12V", .b = "buck/VIN" }};
    const outer: DesignBlock = .{
        .name = "outer",
        .instances = &.{},
        .nets = &.{},
        .ports = &[_]env_mod.Port{.{ .name = "V_12V", .net = "V_12V", .direction = "in", .kind = "power", .rated_min = 11.4, .rated_max = 12.6 }},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &sbs,
        .net_ties = &ties,
    };
    const result = try build(alloc, &outer, &.{});
    const filtered = envelopeFor(result, "buck/VIN_F") orelse return error.TestExpectedEnvelope;
    try testing.expectEqual(@as(f64, 11.4), filtered.min);
    try testing.expectEqual(@as(f64, 12.6), filtered.max);
    try testing.expectEqual(NetEnvelope.Origin.derived, filtered.origin);
}

// spec: eval/net-envelopes - An internal input port's rated range is a pin tolerance and does not widen the net it sits on
test "build ignores an internal input port's rated range" {
    var scratch = arena();
    defer scratch.deinit();
    const alloc = scratch.allocator();
    // Barracuda ties a boost converter's `(port "EN_25V" in signal (rated 0.0 3.6))`
    // straight to V_5VA. Reading that 0 V floor as a rail fact used to widen the
    // whole 5 V domain and manufacture a dissipation failure downstream.
    const inner_nets = [_]env_mod.Net{
        .{ .name = "EN", .pins = &[_]env_mod.PinRef{.{ .ref_des = "U1", .pin = "4" }} },
    };
    var inner: DesignBlock = .{
        .name = "boost",
        .instances = &.{},
        .nets = &inner_nets,
        .ports = &[_]env_mod.Port{.{ .name = "EN", .net = "EN", .direction = "in", .kind = "signal", .nominal = 3.3, .rated_min = 0.0, .rated_max = 3.6 }},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    const sbs = [_]env_mod.SubBlock{.{ .name = "boost", .block = &inner }};
    const ties = [_]env_mod.NetTie{.{ .a = "V_5VA", .b = "boost/EN" }};
    const outer: DesignBlock = .{
        .name = "outer",
        .instances = &.{},
        .nets = &.{},
        .ports = &[_]env_mod.Port{.{ .name = "V_5VA", .net = "V_5VA", .direction = "in", .kind = "power", .rated_min = 4.75, .rated_max = 5.25 }},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &sbs,
        .net_ties = &ties,
    };
    const result = try build(alloc, &outer, &.{});
    const rail = envelopeFor(result, "V_5VA") orelse return error.TestExpectedEnvelope;
    try testing.expectEqual(@as(f64, 4.75), rail.min);
    try testing.expectEqual(@as(f64, 5.25), rail.max);
}

// spec: eval/net-envelopes - Leaves a design with no sub-blocks and no declarations unchanged
test "build emits nothing for a flat design with no declared voltages" {
    var scratch = arena();
    defer scratch.deinit();
    const alloc = scratch.allocator();
    const nets = [_]env_mod.Net{
        .{ .name = "SIG", .pins = &[_]env_mod.PinRef{.{ .ref_des = "R1", .pin = "1" }} },
    };
    const outer: DesignBlock = .{
        .name = "outer",
        .instances = &.{},
        .nets = &nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    const result = try build(alloc, &outer, &.{});
    try testing.expectEqual(@as(usize, 0), result.envelopes.len);
    try testing.expectEqual(@as(usize, 0), result.contradictions.len);
}

// spec: eval/net-envelopes - An authored net-envelope declaration bounds a signal net the topology cannot derive
test "build accepts a declared envelope for an underivable signal net" {
    var scratch = arena();
    defer scratch.deinit();
    const alloc = scratch.allocator();
    const nets = [_]env_mod.Net{
        .{ .name = "EN_BUCK", .pins = &[_]env_mod.PinRef{.{ .ref_des = "R1", .pin = "1" }} },
    };
    const outer: DesignBlock = .{
        .name = "outer",
        .instances = &.{},
        .nets = &nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    const decls = [_]Declaration{.{ .net = "EN_BUCK", .min = 0, .max = 3.3, .rationale = "3.3 V GPIO" }};
    const result = try build(alloc, &outer, &decls);
    const declared = envelopeFor(result, "EN_BUCK") orelse return error.TestExpectedEnvelope;
    try testing.expectEqual(@as(f64, 3.3), declared.max);
    try testing.expectEqual(NetEnvelope.Origin.declared, declared.origin);
    try testing.expectEqualStrings("3.3 V GPIO", declared.rationale);
    try testing.expectEqual(@as(usize, 0), result.contradictions.len);
}

// spec: eval/net-envelopes - Reports a declared envelope that fails to cover the envelope the design already proves
test "build reports a declared envelope narrower than the derived one" {
    var scratch = arena();
    defer scratch.deinit();
    const alloc = scratch.allocator();
    const nets = [_]env_mod.Net{
        .{ .name = "V_12V", .pins = &[_]env_mod.PinRef{.{ .ref_des = "R1", .pin = "1" }} },
    };
    const ports = [_]env_mod.Port{.{ .name = "V_12V", .net = "V_12V", .direction = "in", .kind = "power", .rated_min = 11.4, .rated_max = 12.6 }};
    const outer: DesignBlock = .{
        .name = "outer",
        .instances = &.{},
        .nets = &nets,
        .ports = &ports,
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    const decls = [_]Declaration{.{ .net = "V_12V", .min = 0, .max = 5.0 }};
    const result = try build(alloc, &outer, &decls);
    try testing.expectEqual(@as(usize, 1), result.contradictions.len);
    try testing.expectEqualStrings("V_12V", result.contradictions[0].net);
    try testing.expectEqual(@as(f64, 12.6), result.contradictions[0].derived_max);
    // A covering declaration is not a contradiction, and widens the result.
    const wide = [_]Declaration{.{ .net = "V_12V", .min = 0, .max = 30.0 }};
    const covering = try build(alloc, &outer, &wide);
    try testing.expectEqual(@as(usize, 0), covering.contradictions.len);
    const merged = envelopeFor(covering, "V_12V") orelse return error.TestExpectedEnvelope;
    try testing.expectEqual(@as(f64, 30.0), merged.max);
}
