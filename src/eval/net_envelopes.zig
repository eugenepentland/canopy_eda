//! Worst-case DC voltage envelopes per FLAT net name — the data that lets a
//! release rating check say what potential a part's copper actually sees.
//!
//! `eval/rails` answers a different question and answers it at one level: it
//! emits a supply-tree node per `block.sub_blocks[…].ports` output, so a rail is
//! always a TOP-level net. That leaves every node one step further in
//! unnameable — the far side of a module's own input ferrite (`buck_5v75/VIN_F`,
//! `hmc733/V_5VA_FILT`, `lna/VDD_FILT`), which is where a module's decoupling
//! and its feedback divider actually sit. On Board A that was 139 of the 172
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
const rules_mod = @import("net_envelope_rules.zig");
const req = @import("../req_checks.zig");

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
    provenance: NetEnvelope.Provenance,

    fn widen(self: *Span, other: Span) void {
        self.min = @min(self.min, other.min);
        self.max = @max(self.max, other.max);
        // A declared provenance is the only text worth carrying, and the first
        // one wins so output is independent of hash-map iteration order.
        if (self.origin == .derived and other.origin == .declared) {
            self.origin = .declared;
            self.provenance = other.provenance;
        }
    }
};

/// Provenance text for the 0 V every rating surface grants a ground-class name.
pub const ground_rule = "ground-class name";

/// One authored `(net-envelope "NET" (rated LO HI) ["why"])`, before the net
/// name has been resolved against the flattened netlist. Declared in `env` so
/// a block can carry its own forward for its parent to lift — see
/// `env.NetEnvelopeTable`.
pub const Declaration = env_mod.NetEnvelopeDecl;

/// Everything a `build` run is told beyond the block itself.
///
/// The two declaration lists are separate because they are checked against
/// different baselines, which is the whole precedence rule: a MODULE-scope
/// declaration is measured against what the topology derives, and the board's
/// own declarations are then measured against that result. So a board may
/// widen what a module claims about its own insides and may restate it, but a
/// board declaration NARROWER than the module's own is a failed assertion —
/// the module owns the envelope of the node it owns.
pub const Input = struct {
    /// `(net-envelope …)` forms written in this block's own body.
    declarations: []const Declaration = &.{},
    /// Library-declared node potentials (`eval/net_envelope_rules`): a
    /// feedback pin's reference, a SET pin's programmed voltage. Applied only
    /// to nets nothing else bounds, so a datasheet default never rewrites a
    /// fact the design states outright.
    rules: []const rules_mod.Seed = &.{},
    /// Library `(electrical … (max-voltage V))` ceilings, resolved to pins and
    /// flat nets. A device pin cannot push a node past its own declared
    /// maximum, so a driven domain is bounded by the PIN rather than by the
    /// widest supply the part happens to reach.
    pin_limits: []const rules_mod.PinLimit = &.{},
};

/// Read one net's proven potential the way every rating surface must read it:
/// a ground-class name is 0 V by definition, then the design's declared RAILS
/// (and their aliases) by base name, then the derived envelope table. Both
/// scans are case-insensitive on `net_analysis.baseNetName`, which strips a
/// `.ref.pin` split-net suffix but NOT a `sub-block/` prefix — a rail is always
/// top-level, an envelope is keyed by the flat name exactly as the netlist
/// spells it, and that asymmetry is the whole reason both tables are consulted.
///
/// One function so `req_physical_checks`' `(cap-rating …)` and
/// `fab_readiness`' release gate can never disagree about what a net reaches.
pub fn lookupIn(
    rails: []const env_mod.PowerRail,
    envelopes: []const NetEnvelope,
    net: []const u8,
) ?NetEnvelope {
    if (na.isRatingZeroVolts(net)) return .{
        .net = net,
        .min = 0,
        .max = 0,
        .provenance = .{ .rule = ground_rule, .root = net },
    };
    const base = na.baseNetName(net);
    for (rails) |rail| {
        const low = rail.rated_voltage.min orelse rail.nominal orelse continue;
        const high = rail.rated_voltage.max orelse rail.nominal orelse continue;
        var hit = std.ascii.eqlIgnoreCase(base, rail.name);
        if (!hit) for (rail.aliases) |alias| {
            if (std.ascii.eqlIgnoreCase(base, alias)) {
                hit = true;
                break;
            }
        };
        if (!hit) continue;
        return .{
            .net = net,
            .min = @min(low, high),
            .max = @max(low, high),
            .provenance = .{ .rule = "rail", .root = rail.name },
        };
    }
    for (envelopes) |envelope| {
        if (std.ascii.eqlIgnoreCase(base, envelope.net)) return envelope;
    }
    return null;
}

/// `lookupIn` against a design block's own tables — the form every consumer
/// holding a `DesignBlock` should use.
pub fn lookup(block: *const DesignBlock, net: []const u8) ?NetEnvelope {
    return lookupIn(block.rails, block.envelopes.published, net);
}

/// A `.declared` envelope that fails to cover the envelope the design's own
/// declarations already prove for the same net. Reported by the caller as a
/// failed assertion, because the two statements cannot both be true.
pub const Contradiction = struct {
    net: []const u8,
    declared_min: f64,
    declared_max: f64,
    derived_min: f64,
    derived_max: f64,
    /// The declaration's provenance text — which body the form was written in,
    /// so the assertion can say whether the board or a module made the claim.
    rule: []const u8 = "",
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
    input: Input,
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

    // MODULE-scope declarations first, against the purely derived baseline:
    // a module states the envelope of a node it owns, and the parent's own
    // topology is the only thing that can contradict it.
    var scoped: std.ArrayList(Declaration) = .empty;
    defer scoped.deinit(allocator);
    try collectScoped(allocator, block, "", &scoped);
    try applyDeclarations(allocator, scoped.items, .{
        .aliases = &aliases,
        .parent = &parent,
        .by_root = &by_root,
        .baseline = &derived_roots,
        .contradictions = &contradictions,
    });

    // Then this block's own, against the module-informed result: a board may
    // widen or restate what a module claims about its insides, never narrow it.
    var proven_roots = try by_root.clone(allocator);
    defer proven_roots.deinit(allocator);
    try applyDeclarations(allocator, input.declarations, .{
        .aliases = &aliases,
        .parent = &parent,
        .by_root = &by_root,
        .baseline = &proven_roots,
        .contradictions = &contradictions,
    });

    // Library-declared node potentials fill what nothing above bounds.
    try applyRuleSeeds(allocator, input.rules, &aliases, &parent, &by_root);

    // Series-domain derivation runs LAST, over everything already known —
    // seeds and authored declarations alike — and only ever fills nets that
    // are still unknown, so nothing above can be widened or narrowed by it.
    var domains = try deriveSeriesDomains(allocator, .{
        .instances = instances.items,
        .nets = nets.items,
        .pin_limits = input.pin_limits,
    }, &parent, &by_root);
    defer domains.deinit(allocator);

    // Last resort, after every topological route has been tried: a node whose
    // only connection to anything bounded is ONE device pin, and whose library
    // states that pin's absolute maximum. Deliberately last, so a node the
    // topology can bound is bounded by what it actually carries rather than by
    // a datasheet ceiling.
    try boundByPinLimits(allocator, input.pin_limits, nets.items, &parent, &by_root);

    // Emit one entry per flat net whose class carries a potential. Nets with no
    // seed anywhere in their class are simply absent — an absent envelope is
    // "not proven", which is the honest answer and the status quo.
    var out: std.ArrayList(NetEnvelope) = .empty;
    for (nets.items) |net| {
        const root = na.findRoot(&parent, net.name);
        const span = by_root.get(root) orelse continue;
        const derived = domains.get(root) orelse Derived{ .domain = 0, .bounded = false };
        try out.append(allocator, .{
            .net = net.name,
            .min = span.min,
            .max = span.max,
            .origin = span.origin,
            .provenance = .{ .rule = span.provenance.rule, .why = span.provenance.why, .root = root },
            .domain = derived.domain,
            .bounded = derived.bounded,
        });
    }
    std.mem.sort(NetEnvelope, out.items, {}, lessThanEnvelope);
    return .{
        .envelopes = try out.toOwnedSlice(allocator),
        .contradictions = try contradictions.toOwnedSlice(allocator),
    };
}

/// Fold library-declared node potentials (a feedback reference, a SET
/// resistor's programmed output) into the envelope set. They never widen or
/// narrow an existing entry: a datasheet default must not rewrite a fact the
/// design states outright, so only a still-unknown root is filled.
fn applyRuleSeeds(
    allocator: std.mem.Allocator,
    seeds: []const rules_mod.Seed,
    aliases: *const flat_netlist.CanonicalNetMap,
    parent: *std.StringHashMapUnmanaged([]const u8),
    by_root: *std.StringHashMapUnmanaged(Span),
) std.mem.Allocator.Error!void {
    for (seeds) |seed| {
        if (!(seed.max >= seed.min)) continue;
        const root = rootOf(aliases, parent, seed.net);
        if (by_root.contains(root) or na.isRatingZeroVolts(root)) continue;
        try by_root.put(allocator, root, .{
            .min = seed.min,
            .max = seed.max,
            .origin = .derived,
            .provenance = .{ .rule = seed.rule },
        });
    }
}

/// Bound a still-unknown net by the declared absolute maximum of the one device
/// pin sitting on it — an IC's internal-regulator or bias node behind its
/// bypass capacitor, which no series conductor reaches and which was therefore
/// the single biggest class of hand-authored `(net-envelope …)` on Board A
/// (39 of the 53 the walk still could not name).
///
/// The ceiling is `min(pin maximum, the widest potential the part itself
/// touches)`: a die node cannot exceed the pin's rating, and it cannot exceed
/// the supplies the part is fed from either. A part that touches NO bounded net
/// bounds nothing — the same refusal an unbounded driver already gets — and the
/// floor is 0 V, since a bypassed bias node is at ground before the part runs.
///
/// This is a RATING, not an observed operating level, exactly as a board author
/// writing "the datasheet publishes no operating level for this pin, so the
/// ceiling is the pin's own maximum" would have written by hand.
fn boundByPinLimits(
    allocator: std.mem.Allocator,
    pin_limits: []const rules_mod.PinLimit,
    nets: []const flat_netlist.FlatNet,
    parent: *std.StringHashMapUnmanaged([]const u8),
    by_root: *std.StringHashMapUnmanaged(Span),
) std.mem.Allocator.Error!void {
    for (pin_limits) |limit| {
        const root = na.findRoot(parent, limit.net);
        if (seedSpanOf(by_root, root) != null) continue;
        var ceiling: ?f64 = null;
        for (nets) |net| {
            var owns = false;
            for (net.pins) |pin| {
                if (std.mem.eql(u8, pin.ref_des, limit.ref_des)) {
                    owns = true;
                    break;
                }
            }
            if (!owns) continue;
            const span = seedSpanOf(by_root, na.findRoot(parent, net.name)) orelse continue;
            ceiling = if (ceiling) |c| @max(c, span.max) else span.max;
        }
        const supply = ceiling orelse continue;
        const high = @min(limit.max_voltage, supply);
        if (!(high > 0)) continue;
        try by_root.put(allocator, root, .{
            .min = 0,
            .max = high,
            .origin = .derived,
            .provenance = .{ .rule = "pin maximum" },
        });
    }
}

fn lessThanEnvelope(_: void, a: NetEnvelope, b: NetEnvelope) bool {
    return std.mem.order(u8, a.net, b.net) == .lt;
}

/// The maps one declaration pass reads and writes. Grouped so the pass keeps
/// one parameter per ROLE rather than six positional pointers.
const DeclPass = struct {
    aliases: *const flat_netlist.CanonicalNetMap,
    parent: *std.StringHashMapUnmanaged([]const u8),
    by_root: *std.StringHashMapUnmanaged(Span),
    /// What each declaration must COVER to be believed. Never the live
    /// `by_root`, which the pass itself widens — comparing against that would
    /// measure a declaration against itself.
    baseline: *const std.StringHashMapUnmanaged(Span),
    contradictions: *std.ArrayList(Contradiction),
};

/// Fold one list of authored declarations into the envelope set, recording any
/// that fails to cover what `baseline` already proves for the same net.
fn applyDeclarations(
    allocator: std.mem.Allocator,
    declarations: []const Declaration,
    pass: DeclPass,
) std.mem.Allocator.Error!void {
    for (declarations) |decl| {
        if (!(decl.max >= decl.min)) continue;
        const root = rootOf(pass.aliases, pass.parent, decl.net);
        if (pass.baseline.get(root)) |known| {
            if (decl.min > known.min or decl.max < known.max) try pass.contradictions.append(allocator, .{
                .net = decl.net,
                .declared_min = decl.min,
                .declared_max = decl.max,
                .derived_min = known.min,
                .derived_max = known.max,
                .rule = decl.rule,
            });
        }
        try put(allocator, pass.by_root, root, .{
            .min = decl.min,
            .max = decl.max,
            .origin = .declared,
            .provenance = .{ .rule = decl.rule, .why = decl.rationale },
        });
    }
}

/// Walk the sub-block tree and lift every module's own `(net-envelope …)` form
/// into a declaration keyed by the FLAT name its instantiation gives it, so a
/// module can state the envelope of its SET/FB/bias node once instead of every
/// board restating the same datasheet arithmetic per instantiation.
///
/// The block's OWN declarations are deliberately not collected here: they are
/// board-scope and are applied later, against the result this pass produces.
/// `prefix` is the `sub-block/…` path of `block` ("" at the top).
fn collectScoped(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    prefix: []const u8,
    out: *std.ArrayList(Declaration),
) std.mem.Allocator.Error!void {
    for (block.sub_blocks) |sb| {
        const path = if (prefix.len == 0)
            try allocator.dupe(u8, sb.name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, sb.name });
        const rule = try std.fmt.allocPrint(allocator, "declared in module {s}", .{path});
        for (sb.block.envelopes.declared) |decl| {
            try out.append(allocator, .{
                .net = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, decl.net }),
                .min = decl.min,
                .max = decl.max,
                .rationale = decl.rationale,
                .rule = rule,
            });
        }
        try collectScoped(allocator, sb.block, path, out);
    }
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
        const span = Span{ .min = @min(low, high), .max = @max(low, high), .origin = .derived, .provenance = .{ .rule = "rail" } };
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
/// potential of the rail feeding it: Board A ties `board-a-boost25`'s
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
    return .{ .min = @min(lo, hi), .max = @max(lo, hi), .origin = .derived, .provenance = .{ .rule = if (supply_side) "port-supply" else "port-nominal" } };
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
///
/// Public because `fab_readiness` must answer the CURRENT question over exactly
/// the graph this module answers the VOLTAGE question over: a bead is a DC
/// conductor, so `buck_5v75/VIN_F` is the same node as `V_12V` for both. Two
/// topology walks would eventually disagree about which nets are one node, and
/// then a part would be voltage-known but current-unknown for no physical
/// reason — which is exactly the state that stranded `boost22/L16`. Read with
/// `net_analysis.findRoot`; the returned map borrows `nets`/`instances` strings.
pub fn ferriteBridges(
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

// ── Series-domain derivation ───────────────────────────────────────────
//
// A two-terminal series resistor or inductor makes its two nets ONE correlated
// DC node up to its IR drop — an RC filter's tap, a termination or pull-up's
// far side, a bias tee's feed node. The board vocabulary for those nets used
// to be a hand-authored `(net-envelope …)` restating what the topology already
// says ("C blocks DC, so no DC current flows in R and the node sits at the
// near potential"). This pass derives them instead.
//
// The model is the same declared-DC frame the rail budget uses everywhere: a
// branch with no declared current carries none, so the drop across a series
// element defaults to zero and an anchor's envelope crosses it unchanged.
// What keeps that honest rather than optimistic:
//
//   * Only UNKNOWN nets are ever filled. A seeded or authored envelope is
//     never touched, so nothing already proven can be rewritten.
//   * Non-passive pins on a domain WIDEN it: a device with a pin on the
//     domain can drive the node anywhere its own supplies reach, so the
//     domain takes `[min(0, …), max(…)]` over every envelope-known net that
//     device touches. A device touching NO known net is an unbounded driver
//     and poisons the whole domain — it stays unproven.
//   * Two anchors that cannot agree (disjoint envelopes — a divider strung
//     between two rails) prove the domain CARRIES current between them, which
//     is exactly the case zero-drop propagation may not model. The whole
//     domain is refused and stays unproven, preserving the finding.
//
// Each derived net carries a nonzero `NetEnvelope.domain`; nets sharing one
// are correlated, which is what lets the rating check bound the voltage
// ACROSS the series element by its drop instead of by two independent
// intervals (see `fab_readiness.seriesCorrelated`).

/// The two-terminal series conductors the derivation may cross. Ferrites are
/// deliberately absent: they are already unioned into one net class above.
fn isSeriesConductor(component: []const u8) bool {
    return std.mem.startsWith(u8, component, "res-") or
        std.mem.startsWith(u8, component, "ind-");
}

/// Inductors anchor (a bias tee or filter fed FROM a known rail) but never
/// merge two unknown nets: an inductor between two undeclared nets is the
/// energy-storage shape — a switcher's coil — whose two ends genuinely sit at
/// different potentials, exactly what zero-drop union may not claim. That is
/// how a boost converter's 12 V input stays a 12 V input instead of
/// inheriting the switch node's diode-clamped ceiling.
fn isInductor(component: []const u8) bool {
    return std.mem.startsWith(u8, component, "ind-");
}

/// Parts that neither conduct nor drive: their pins say nothing about a net's
/// potential. Capacitors block DC; the rest have no electrical model at all.
fn isInertForDomains(component: []const u8) bool {
    if (std.mem.startsWith(u8, component, "cap-")) return true;
    if (env_mod.isTestPoint(component)) return true;
    const mechanical = [_][]const u8{ "mounting-hole", "fiducial", "board-outline" };
    for (mechanical) |name| {
        if (std.mem.indexOf(u8, component, name) != null) return true;
    }
    return false;
}

/// What is already proven about `root` before derivation: its seeded/declared
/// span, or the 0 V every rating surface grants ground-class names.
fn seedSpanOf(by_root: *const std.StringHashMapUnmanaged(Span), root: []const u8) ?Span {
    if (by_root.get(root)) |span| return span;
    if (na.isRatingZeroVolts(root)) return .{ .min = 0, .max = 0, .origin = .derived, .provenance = .{ .rule = ground_rule } };
    return null;
}

/// One connected component of unknown nets joined by series conductors, while
/// its envelope is being assembled.
/// The one shape zero-drop propagation may not model but Ohm's law can: a
/// single unknown node reached from exactly TWO different known nets through
/// two parseable resistors — a divider tap. Current between the anchors is
/// guaranteed, which is why the general rule refuses the domain; here the
/// potential is simply the ratio, evaluated at the anchors' own corners.
///
/// Every condition is a refusal, not a guess: a third leg, an unparseable
/// value, a zero resistance, an inductor, or a domain of more than one node all
/// leave `usable` false and the domain unproven, exactly as before. The one
/// thing the ratio assumes is that the pin on the tap SENSES it — which is what
/// a divider is for; a part that DRIVES a tap must say so with a
/// `(net-envelope …)`, and that declaration wins because it is applied first.
const TapCandidate = struct {
    /// One resistive path from the tap to a bounded net. The anchor's own
    /// corners are stored flat rather than as a `Span`, so an unused slot is a
    /// zero leg rather than an `undefined` one nothing may read.
    const Leg = struct { min: f64 = 0, max: f64 = 0, ohms: f64 = 0 };

    legs: [2]Leg = .{ .{}, .{} },
    count: usize = 0,
    usable: bool = true,
    /// Set by `compose` when the ratio actually decided the span. Such a
    /// domain claims NO series correlation: the legs DO carry the full drop,
    /// which is the opposite of the zero-drop case `domain` exists for.
    resolved: bool = false,

    fn addLeg(self: *TapCandidate, anchor: Span, ohms: ?f64) void {
        const resistance = ohms orelse {
            self.usable = false;
            return;
        };
        if (!(resistance > 0) or self.count >= self.legs.len) {
            self.usable = false;
            return;
        }
        self.legs[self.count] = .{ .min = anchor.min, .max = anchor.max, .ohms = resistance };
        self.count += 1;
    }
};

const DomainAcc = struct {
    anchors: std.ArrayList(Span) = .empty,
    /// Divider-tap evidence for this domain — see `TapCandidate`.
    tap: TapCandidate = .{},
    /// How many unknown roots this domain joins. The ratio rule applies to one
    /// node only; a chain of them is not a two-resistor divider.
    members: usize = 0,
    /// The one known root all anchors must share. Two DIFFERENT known nets
    /// conducting into one unknown domain is a divider/bridge: current between
    /// them is guaranteed, which is exactly what zero-drop propagation may not
    /// model, so such a domain is refused (`multi_root`).
    anchor_root: ?[]const u8 = null,
    multi_root: bool = false,
    device_min: f64 = 0,
    device_max: f64 = 0,
    has_device: bool = false,
    poisoned: bool = false,
    span_min: f64 = 0,
    span_max: f64 = 0,

    fn noteAnchorRoot(self: *DomainAcc, root: []const u8) void {
        if (self.anchor_root) |existing| {
            if (!std.mem.eql(u8, existing, root)) self.multi_root = true;
        } else self.anchor_root = root;
    }

    fn boundByDevice(self: *DomainAcc, floor: f64, ceil: f64) void {
        self.device_min = if (self.has_device) @min(self.device_min, floor) else floor;
        self.device_max = if (self.has_device) @max(self.device_max, ceil) else ceil;
        self.has_device = true;
    }

    /// Resolve this domain's envelope, or refuse (see the section comment):
    /// a poisoned domain, one nothing bounds, and one anchored by more than
    /// one distinct known net all stay unknown.
    fn compose(self: *DomainAcc) bool {
        if (self.poisoned) return false;
        if (self.multi_root) return self.composeTap();
        if (self.anchors.items.len == 0 and !self.has_device) return false;
        var lo: f64 = std.math.inf(f64);
        var hi: f64 = -std.math.inf(f64);
        for (self.anchors.items) |a| {
            lo = @min(lo, a.min);
            hi = @max(hi, a.max);
        }
        if (self.has_device) {
            lo = @min(lo, self.device_min);
            hi = @max(hi, self.device_max);
        }
        self.span_min = lo;
        self.span_max = hi;
        return true;
    }

    /// Resolve a two-anchor domain by the divider ratio, or refuse it as
    /// before. `V = (Va*Rb + Vb*Ra) / (Ra + Rb)` rises with both anchors, so
    /// the interval corners are the anchors' corners.
    fn composeTap(self: *DomainAcc) bool {
        if (!self.tap.usable or self.tap.count != 2 or self.members != 1) return false;
        const a = self.tap.legs[0];
        const b = self.tap.legs[1];
        const total = a.ohms + b.ohms;
        if (!(total > 0)) return false;
        self.span_min = (a.min * b.ohms + b.min * a.ohms) / total;
        self.span_max = (a.max * b.ohms + b.max * a.ohms) / total;
        self.tap.resolved = true;
        return true;
    }
};

/// Shared state of one derivation run over a flattened design.
const DomainPass = struct {
    allocator: std.mem.Allocator,
    instances: []const flat_netlist.FlatInstance,
    /// Library `(electrical … (max-voltage V))` ceilings, still keyed by FLAT
    /// net name; `limitFor` maps each to its ferrite root on demand.
    pin_limits: []const rules_mod.PinLimit = &.{},
    by_root: *std.StringHashMapUnmanaged(Span),
    /// Ferrite-class roots each part touches, deduplicated, in net order.
    roots_by_ref: std.StringHashMapUnmanaged(std.ArrayList([]const u8)) = .empty,
    /// Union-find over the unknown roots series conductors join.
    dparent: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Unknown roots touched by a series conductor, in first-seen order.
    member_list: std.ArrayList([]const u8) = .empty,
    member_set: std.StringHashMapUnmanaged(void) = .empty,
    acc: std.StringHashMapUnmanaged(DomainAcc) = .empty,

    fn deinit(self: *DomainPass) void {
        var lists = self.roots_by_ref.valueIterator();
        while (lists.next()) |list| list.deinit(self.allocator);
        self.roots_by_ref.deinit(self.allocator);
        self.dparent.deinit(self.allocator);
        self.member_list.deinit(self.allocator);
        self.member_set.deinit(self.allocator);
        var accs = self.acc.valueIterator();
        while (accs.next()) |entry| entry.anchors.deinit(self.allocator);
        self.acc.deinit(self.allocator);
    }

    fn indexRoots(
        self: *DomainPass,
        nets: []const flat_netlist.FlatNet,
        parent: *std.StringHashMapUnmanaged([]const u8),
    ) std.mem.Allocator.Error!void {
        for (nets) |net| {
            const root = na.findRoot(parent, net.name);
            for (net.pins) |pin| {
                const gop = try self.roots_by_ref.getOrPut(self.allocator, pin.ref_des);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                var seen = false;
                for (gop.value_ptr.items) |existing| {
                    if (std.mem.eql(u8, existing, root)) {
                        seen = true;
                        break;
                    }
                }
                if (!seen) try gop.value_ptr.append(self.allocator, root);
            }
        }
    }

    /// The two roots of a populated two-terminal series conductor, or null. A
    /// DNP part is absent copper and joins nothing.
    fn seriesRoots(self: *const DomainPass, inst: flat_netlist.FlatInstance) ?[2][]const u8 {
        if (inst.dnp or !isSeriesConductor(inst.component)) return null;
        const roots = self.roots_by_ref.get(inst.ref_des) orelse return null;
        if (roots.items.len != 2) return null;
        return .{ roots.items[0], roots.items[1] };
    }

    /// Pass 1: union unknown nets joined by a series RESISTOR. Inductors do
    /// not merge unknowns — see `isInductor`.
    fn unionUnknowns(self: *DomainPass) std.mem.Allocator.Error!void {
        for (self.instances) |inst| {
            const pair = self.seriesRoots(inst) orelse continue;
            if (isInductor(inst.component)) continue;
            if (seedSpanOf(self.by_root, pair[0]) != null) continue;
            if (seedSpanOf(self.by_root, pair[1]) != null) continue;
            try unionNets(self.allocator, &self.dparent, pair[0], pair[1]);
        }
    }

    fn register(self: *DomainPass, root: []const u8) std.mem.Allocator.Error!void {
        const member = try self.member_set.getOrPut(self.allocator, root);
        if (member.found_existing) return;
        try self.member_list.append(self.allocator, root);
        (try self.accFor(root)).members += 1;
    }

    fn accFor(self: *DomainPass, root: []const u8) std.mem.Allocator.Error!*DomainAcc {
        const gop = try self.acc.getOrPut(self.allocator, na.findRoot(&self.dparent, root));
        if (!gop.found_existing) gop.value_ptr.* = .{};
        return gop.value_ptr;
    }

    /// Pass 2: register members and collect each domain's anchors — the known
    /// nets one series hop away. The drop across the hop is the declared
    /// branch current times its resistance, and no branch here declares one,
    /// so the anchor envelope crosses unchanged (the declared-DC frame).
    fn collectAnchors(self: *DomainPass) std.mem.Allocator.Error!void {
        for (self.instances) |inst| {
            const pair = self.seriesRoots(inst) orelse continue;
            const span_a = seedSpanOf(self.by_root, pair[0]);
            const span_b = seedSpanOf(self.by_root, pair[1]);
            if (span_a != null and span_b != null) continue;
            // An all-unknown inductor edge is skipped entirely (see
            // isInductor): it neither registers members nor anchors.
            if (span_a == null and span_b == null and isInductor(inst.component)) continue;
            if (span_a == null) try self.register(pair[0]);
            if (span_b == null) try self.register(pair[1]);
            const anchor = span_a orelse span_b orelse continue;
            const anchor_root = if (span_a == null) pair[1] else pair[0];
            const entry = try self.accFor(if (span_a == null) pair[0] else pair[1]);
            try entry.anchors.append(self.allocator, anchor);
            entry.noteAnchorRoot(anchor_root);
            // An inductor's value is not a resistance, so a bias choke can
            // anchor a domain but can never be a divider leg.
            entry.tap.addLeg(anchor, if (isInductor(inst.component)) null else req.parseOhms(inst.value));
        }
    }

    /// Pass 3: every other populated part with a pin on a domain bounds it by
    /// its own known nets — or, knowing none, proves it unboundable.
    fn boundByDevices(self: *DomainPass) std.mem.Allocator.Error!void {
        for (self.instances) |inst| {
            if (inst.dnp or isSeriesConductor(inst.component)) continue;
            if (std.mem.startsWith(u8, inst.component, ferrite_prefix)) continue;
            if (isInertForDomains(inst.component)) continue;
            const roots = self.roots_by_ref.get(inst.ref_des) orelse continue;
            var bound: ?struct { min: f64, max: f64 } = null;
            for (roots.items) |root| {
                const span = seedSpanOf(self.by_root, root) orelse continue;
                const floor = @min(0, span.min);
                bound = if (bound) |b|
                    .{ .min = @min(b.min, floor), .max = @max(b.max, span.max) }
                else
                    .{ .min = floor, .max = span.max };
            }
            for (roots.items) |root| {
                if (!self.member_set.contains(root)) continue;
                if (seedSpanOf(self.by_root, root) != null) continue;
                const entry = try self.accFor(root);
                const b = bound orelse {
                    entry.poisoned = true;
                    continue;
                };
                // A pin's own declared absolute maximum is the tighter of the
                // two feasibility statements: the part cannot present more on
                // THIS pin than its library says, whatever its supplies reach.
                const ceiling = if (self.limitFor(inst.ref_des, root)) |limit|
                    @min(b.max, limit)
                else
                    b.max;
                entry.boundByDevice(b.min, @max(b.min, ceiling));
            }
        }
    }

    /// The tightest library `(electrical … (max-voltage V))` this part declares
    /// on any pin sitting on `root`, or null when it declares none there.
    fn limitFor(self: *DomainPass, ref_des: []const u8, root: []const u8) ?f64 {
        var tightest: ?f64 = null;
        for (self.pin_limits) |limit| {
            if (!std.mem.eql(u8, limit.ref_des, ref_des)) continue;
            const limit_root = na.findRoot(&self.dparent, limit.net);
            if (!std.mem.eql(u8, limit_root, root) and !std.mem.eql(u8, limit.net, root)) continue;
            tightest = if (tightest) |t| @min(t, limit.max_voltage) else limit.max_voltage;
        }
        return tightest;
    }

    /// Compose each domain once, in first-member order so ids are stable, and
    /// fill every member root. Refusals leave the member unknown — exactly the
    /// pre-derivation state, so the release finding survives.
    fn emit(
        self: *DomainPass,
        domains: *std.StringHashMapUnmanaged(Derived),
    ) std.mem.Allocator.Error!void {
        var id_by_domain: std.StringHashMapUnmanaged(u32) = .empty;
        defer id_by_domain.deinit(self.allocator);
        var next_id: u32 = 1;
        for (self.member_list.items) |root| {
            const droot = na.findRoot(&self.dparent, root);
            const idgop = try id_by_domain.getOrPut(self.allocator, droot);
            if (!idgop.found_existing) {
                const entry = self.acc.getPtr(droot);
                idgop.value_ptr.* = if (entry != null and entry.?.compose()) next_id else 0;
                if (idgop.value_ptr.* != 0) next_id += 1;
            }
            if (idgop.value_ptr.* == 0) continue;
            const entry = self.acc.getPtr(droot).?;
            try self.by_root.put(self.allocator, root, .{
                .min = entry.span_min,
                .max = entry.span_max,
                .origin = .derived,
                .provenance = .{ .rule = if (entry.tap.resolved) "divider-tap" else "series-domain" },
            });
            try domains.put(self.allocator, root, .{
                .domain = if (entry.tap.resolved) 0 else idgop.value_ptr.*,
                .bounded = entry.has_device and !entry.tap.resolved,
            });
        }
    }
};

/// The flattened design one derivation run reads, plus the library ceilings
/// that tighten a driven node's bound.
const FlatDesign = struct {
    instances: []const flat_netlist.FlatInstance,
    nets: []const flat_netlist.FlatNet,
    pin_limits: []const rules_mod.PinLimit = &.{},
};

/// What the derivation established for one root: its correlation class, and
/// whether the span's extent rests on device supplies (a feasibility BOUND on
/// a driven node) rather than pure series conduction from one anchor.
const Derived = struct { domain: u32, bounded: bool };

/// Derive envelopes for nets that series conductors correlate with known ones
/// (see the section comment above). Fills `by_root` for every derived root and
/// returns root → correlation-domain id (1-based; roots absent are underived).
fn deriveSeriesDomains(
    allocator: std.mem.Allocator,
    flat: FlatDesign,
    parent: *std.StringHashMapUnmanaged([]const u8),
    by_root: *std.StringHashMapUnmanaged(Span),
) std.mem.Allocator.Error!std.StringHashMapUnmanaged(Derived) {
    var domains: std.StringHashMapUnmanaged(Derived) = .empty;
    errdefer domains.deinit(allocator);
    var pass = DomainPass{
        .allocator = allocator,
        .instances = flat.instances,
        .pin_limits = flat.pin_limits,
        .by_root = by_root,
    };
    defer pass.deinit();
    try pass.indexRoots(flat.nets, parent);
    try pass.unionUnknowns();
    try pass.collectAnchors();
    try pass.boundByDevices();
    try pass.emit(&domains);
    return domains;
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
    // The shape every buck on Board A has: the board rail is bridged onto the
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
    const result = try build(alloc, &outer, .{});
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
    // Board A ties a boost converter's `(port "EN_25V" in signal (rated 0.0 3.6))`
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
    const result = try build(alloc, &outer, .{});
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
    const result = try build(alloc, &outer, .{});
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
    const result = try build(alloc, &outer, .{ .declarations = &decls });
    const declared = envelopeFor(result, "EN_BUCK") orelse return error.TestExpectedEnvelope;
    try testing.expectEqual(@as(f64, 3.3), declared.max);
    try testing.expectEqual(NetEnvelope.Origin.declared, declared.origin);
    try testing.expectEqualStrings("3.3 V GPIO", declared.provenance.why);
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
    const result = try build(alloc, &outer, .{ .declarations = &decls });
    try testing.expectEqual(@as(usize, 1), result.contradictions.len);
    try testing.expectEqualStrings("V_12V", result.contradictions[0].net);
    try testing.expectEqual(@as(f64, 12.6), result.contradictions[0].derived_max);
    // A covering declaration is not a contradiction, and widens the result.
    const wide = [_]Declaration{.{ .net = "V_12V", .min = 0, .max = 30.0 }};
    const covering = try build(alloc, &outer, .{ .declarations = &wide });
    try testing.expectEqual(@as(usize, 0), covering.contradictions.len);
    const merged = envelopeFor(covering, "V_12V") orelse return error.TestExpectedEnvelope;
    try testing.expectEqual(@as(f64, 30.0), merged.max);
}

// ── Series-domain derivation tests ─────────────────────────────────────

/// A flat design for the derivation tests: every net/port/instance slice is
/// borrowed from the caller's frame.
fn flatBlock(
    instances: []const env_mod.Instance,
    nets: []const env_mod.Net,
    ports: []const env_mod.Port,
) DesignBlock {
    return .{
        .name = "outer",
        .instances = instances,
        .nets = nets,
        .ports = ports,
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
}

fn passive(ref: []const u8, component: []const u8, value: []const u8) env_mod.Instance {
    return .{ .ref_des = ref, .component = component, .value = value, .footprint = "", .symbol = "" };
}

// spec: eval/net-envelopes - A series resistor propagates a known envelope onto a capacitor-terminated node as one correlated domain
test "series resistor derives the RC filter node from its rail" {
    var scratch = arena();
    defer scratch.deinit();
    const alloc = scratch.allocator();
    // The shape of every flagged RC filter / series termination: R1 joins the
    // proven rail to FILT, whose only other pin is a DC-blocking capacitor.
    const instances = [_]env_mod.Instance{
        passive("R1", "res-0402", "49.9R"),
        passive("C1", "cap-0402", "22nF"),
    };
    const nets = [_]env_mod.Net{
        .{ .name = "V_3V3", .pins = &[_]env_mod.PinRef{.{ .ref_des = "R1", .pin = "1" }} },
        .{ .name = "FILT", .pins = &[_]env_mod.PinRef{ .{ .ref_des = "R1", .pin = "2" }, .{ .ref_des = "C1", .pin = "1" } } },
        .{ .name = "GND", .pins = &[_]env_mod.PinRef{.{ .ref_des = "C1", .pin = "2" }} },
    };
    const ports = [_]env_mod.Port{.{ .name = "V_3V3", .net = "V_3V3", .direction = "in", .kind = "power", .rated_min = 3.135, .rated_max = 3.465 }};
    const outer = flatBlock(&instances, &nets, &ports);
    const result = try build(alloc, &outer, .{});
    const filt = envelopeFor(result, "FILT") orelse return error.TestExpectedEnvelope;
    try testing.expectEqual(@as(f64, 3.135), filt.min);
    try testing.expectEqual(@as(f64, 3.465), filt.max);
    try testing.expectEqual(NetEnvelope.Origin.derived, filt.origin);
    try testing.expect(filt.domain != 0);
    // The rail itself was seeded, not derived: it claims no correlation.
    const rail = envelopeFor(result, "V_3V3") orelse return error.TestExpectedEnvelope;
    try testing.expectEqual(@as(u32, 0), rail.domain);
}

// spec: eval/net-envelopes - A divider tap between two bounded nets is derived from the leg ratio
test "series derivation solves a divider strung between two rails" {
    var scratch = arena();
    defer scratch.deinit();
    const alloc = scratch.allocator();
    // TAP provably carries current between V5 and ground — the one case
    // zero-drop propagation may not model, and the one Ohm's law does.
    const instances = [_]env_mod.Instance{
        passive("R1", "res-0402", "30k"),
        passive("R2", "res-0402", "10k"),
    };
    const nets = [_]env_mod.Net{
        .{ .name = "V5", .pins = &[_]env_mod.PinRef{.{ .ref_des = "R1", .pin = "1" }} },
        .{ .name = "TAP", .pins = &[_]env_mod.PinRef{ .{ .ref_des = "R1", .pin = "2" }, .{ .ref_des = "R2", .pin = "1" } } },
        .{ .name = "GND", .pins = &[_]env_mod.PinRef{.{ .ref_des = "R2", .pin = "2" }} },
    };
    const ports = [_]env_mod.Port{.{ .name = "V5", .net = "V5", .direction = "in", .kind = "power", .rated_min = 4.75, .rated_max = 5.25 }};
    const outer = flatBlock(&instances, &nets, &ports);
    const result = try build(alloc, &outer, .{});
    const tap = envelopeFor(result, "TAP") orelse return error.TestExpectedEnvelope;
    try testing.expectApproxEqAbs(@as(f64, 4.75 * 0.25), tap.min, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 5.25 * 0.25), tap.max, 1e-9);
    try testing.expectEqualStrings("divider-tap", tap.provenance.rule);
    // The legs DO carry the full drop, so the tap claims no series correlation.
    try testing.expectEqual(@as(u32, 0), tap.domain);
}

// spec: eval/net-envelopes - A resistor ladder with more than one unknown node is refused rather than approximated by a two-leg ratio
test "series derivation refuses a three-resistor ladder" {
    var scratch = arena();
    defer scratch.deinit();
    const alloc = scratch.allocator();
    // The eFuse UVLO/OVLO shape: VIN — R1 — UVLO — R2 — OVLO — R3 — GND. Two
    // unknown nodes, so the two-leg ratio simply does not describe either.
    const instances = [_]env_mod.Instance{
        passive("R1", "res-0402", "470k"),
        passive("R2", "res-0402", "11k"),
        passive("R3", "res-0402", "47k"),
    };
    const nets = [_]env_mod.Net{
        .{ .name = "V12", .pins = &[_]env_mod.PinRef{.{ .ref_des = "R1", .pin = "1" }} },
        .{ .name = "UVLO", .pins = &[_]env_mod.PinRef{ .{ .ref_des = "R1", .pin = "2" }, .{ .ref_des = "R2", .pin = "1" } } },
        .{ .name = "OVLO", .pins = &[_]env_mod.PinRef{ .{ .ref_des = "R2", .pin = "2" }, .{ .ref_des = "R3", .pin = "1" } } },
        .{ .name = "GND", .pins = &[_]env_mod.PinRef{.{ .ref_des = "R3", .pin = "2" }} },
    };
    const ports = [_]env_mod.Port{.{ .name = "V12", .net = "V12", .direction = "in", .kind = "power", .rated_min = 11.4, .rated_max = 12.6 }};
    const outer = flatBlock(&instances, &nets, &ports);
    const result = try build(alloc, &outer, .{});
    try testing.expectEqual(@as(?NetEnvelope, null), envelopeFor(result, "UVLO"));
    try testing.expectEqual(@as(?NetEnvelope, null), envelopeFor(result, "OVLO"));
}

// spec: eval/net-envelopes - A library-declared node potential fills a net the topology cannot bound and never overwrites one it can
test "a library rule seed fills only what nothing else proves" {
    var scratch = arena();
    defer scratch.deinit();
    const alloc = scratch.allocator();
    const instances = [_]env_mod.Instance{passive("C1", "cap-0402", "22nF")};
    const nets = [_]env_mod.Net{
        .{ .name = "V5", .pins = &[_]env_mod.PinRef{.{ .ref_des = "C1", .pin = "1" }} },
        .{ .name = "FB", .pins = &[_]env_mod.PinRef{.{ .ref_des = "C1", .pin = "2" }} },
    };
    const ports = [_]env_mod.Port{.{ .name = "V5", .net = "V5", .direction = "in", .kind = "power", .rated_min = 4.75, .rated_max = 5.25 }};
    const outer = flatBlock(&instances, &nets, &ports);
    const seeds = [_]rules_mod.Seed{
        .{ .net = "FB", .min = 0.6, .max = 0.6, .rule = "feedback reference U1.FB = 0.6 V" },
        // V5 is already a declared supply: a datasheet default must not move it.
        .{ .net = "V5", .min = 0, .max = 100, .rule = "bogus" },
    };
    const result = try build(alloc, &outer, .{ .rules = &seeds });
    const fb = envelopeFor(result, "FB") orelse return error.TestExpectedEnvelope;
    try testing.expectEqual(@as(f64, 0.6), fb.max);
    try testing.expectEqualStrings("feedback reference U1.FB = 0.6 V", fb.provenance.rule);
    const rail = envelopeFor(result, "V5") orelse return error.TestExpectedEnvelope;
    try testing.expectEqual(@as(f64, 5.25), rail.max);
}

// spec: eval/net-envelopes - A bypassed bias node no conductor reaches is bounded by its pin's declared maximum
test "a pin maximum bounds a cap-terminated bias node the topology cannot reach" {
    var scratch = arena();
    defer scratch.deinit();
    const alloc = scratch.allocator();
    // The shape 38 of Board A's hand-authored envelopes have: an IC's
    // internal-regulator output behind its own bypass capacitor. No series
    // conductor touches it, so no domain reaches it — only the library does.
    const instances = [_]env_mod.Instance{
        .{ .ref_des = "U1", .component = "lmx2595", .value = "", .footprint = "", .symbol = "" },
        passive("C1", "cap-0402", "1uF"),
    };
    const nets = [_]env_mod.Net{
        .{ .name = "V_3V3", .pins = &[_]env_mod.PinRef{.{ .ref_des = "U1", .pin = "5" }} },
        .{ .name = "VREGIN", .pins = &[_]env_mod.PinRef{ .{ .ref_des = "U1", .pin = "8" }, .{ .ref_des = "C1", .pin = "1" } } },
        .{ .name = "GND", .pins = &[_]env_mod.PinRef{.{ .ref_des = "C1", .pin = "2" }} },
    };
    const ports = [_]env_mod.Port{.{ .name = "V_3V3", .net = "V_3V3", .direction = "in", .kind = "power", .rated_min = 3.135, .rated_max = 3.465 }};
    const outer = flatBlock(&instances, &nets, &ports);
    try testing.expectEqual(@as(?NetEnvelope, null), envelopeFor(try build(alloc, &outer, .{}), "VREGIN"));
    // The pin's own maximum is 3.6 V, but the part is fed from a 3.465 V rail
    // and a die node cannot exceed the supply either — the tighter wins.
    const limits = [_]rules_mod.PinLimit{.{ .ref_des = "U1", .net = "VREGIN", .max_voltage = 3.6 }};
    const result = try build(alloc, &outer, .{ .pin_limits = &limits });
    const node = envelopeFor(result, "VREGIN") orelse return error.TestExpectedEnvelope;
    try testing.expectEqual(@as(f64, 0), node.min);
    try testing.expectEqual(@as(f64, 3.465), node.max);
    try testing.expectEqualStrings("pin maximum", node.provenance.rule);
}

// spec: eval/net-envelopes - A device pin's declared max-voltage bounds the domain it drives more tightly than the part's supplies
test "a pin max-voltage tightens the bound a driver puts on its domain" {
    var scratch = arena();
    defer scratch.deinit();
    const alloc = scratch.allocator();
    // Without the pin ceiling the 12 V supply bounds NODE; the part's own
    // library says this pin never presents more than 6 V.
    const instances = [_]env_mod.Instance{
        .{ .ref_des = "U1", .component = "ldo-x", .value = "", .footprint = "", .symbol = "" },
        passive("R1", "res-0402", "10k"),
        passive("C1", "cap-0402", "1uF"),
    };
    const nets = [_]env_mod.Net{
        .{ .name = "V12", .pins = &[_]env_mod.PinRef{.{ .ref_des = "U1", .pin = "5" }} },
        .{ .name = "NODE", .pins = &[_]env_mod.PinRef{ .{ .ref_des = "U1", .pin = "4" }, .{ .ref_des = "R1", .pin = "1" } } },
        .{ .name = "FAR", .pins = &[_]env_mod.PinRef{ .{ .ref_des = "R1", .pin = "2" }, .{ .ref_des = "C1", .pin = "1" } } },
        .{ .name = "GND", .pins = &[_]env_mod.PinRef{.{ .ref_des = "C1", .pin = "2" }} },
    };
    const ports = [_]env_mod.Port{.{ .name = "V12", .net = "V12", .direction = "in", .kind = "power", .rated_min = 11.4, .rated_max = 12.6 }};
    const outer = flatBlock(&instances, &nets, &ports);
    const wide = try build(alloc, &outer, .{});
    try testing.expectEqual(@as(f64, 12.6), (envelopeFor(wide, "NODE") orelse return error.TestExpectedEnvelope).max);
    const limits = [_]rules_mod.PinLimit{.{ .ref_des = "U1", .net = "NODE", .max_voltage = 6.0 }};
    const tight = try build(alloc, &outer, .{ .pin_limits = &limits });
    try testing.expectEqual(@as(f64, 6.0), (envelopeFor(tight, "NODE") orelse return error.TestExpectedEnvelope).max);
}

// spec: eval/net-envelopes - A device pin on a derived domain widens it to the device's own known supplies
test "series derivation widens a driven domain by the driver's supplies" {
    var scratch = arena();
    defer scratch.deinit();
    const alloc = scratch.allocator();
    // The active loop-filter shape: the opamp's output node reaches VTUNE
    // through R_ISO; nothing can push either net beyond the opamp's own rail.
    const instances = [_]env_mod.Instance{
        .{ .ref_des = "U1", .component = "opamp-x", .value = "", .footprint = "", .symbol = "" },
        passive("R1", "res-0402", "27R"),
        passive("C1", "cap-0402", "56pF"),
    };
    const nets = [_]env_mod.Net{
        .{ .name = "V12", .pins = &[_]env_mod.PinRef{.{ .ref_des = "U1", .pin = "5" }} },
        .{ .name = "OUT", .pins = &[_]env_mod.PinRef{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "R1", .pin = "1" } } },
        .{ .name = "VTUNE", .pins = &[_]env_mod.PinRef{ .{ .ref_des = "R1", .pin = "2" }, .{ .ref_des = "C1", .pin = "1" } } },
        .{ .name = "GND", .pins = &[_]env_mod.PinRef{.{ .ref_des = "C1", .pin = "2" }} },
    };
    const ports = [_]env_mod.Port{.{ .name = "V12", .net = "V12", .direction = "in", .kind = "power", .rated_min = 11.4, .rated_max = 12.6 }};
    const outer = flatBlock(&instances, &nets, &ports);
    const result = try build(alloc, &outer, .{});
    const out_net = envelopeFor(result, "OUT") orelse return error.TestExpectedEnvelope;
    const vtune = envelopeFor(result, "VTUNE") orelse return error.TestExpectedEnvelope;
    try testing.expectEqual(@as(f64, 0), out_net.min);
    try testing.expectEqual(@as(f64, 12.6), out_net.max);
    try testing.expectEqual(@as(f64, 0), vtune.min);
    try testing.expectEqual(@as(f64, 12.6), vtune.max);
    try testing.expect(out_net.domain != 0);
    try testing.expectEqual(out_net.domain, vtune.domain);
}

// spec: eval/net-envelopes - A device with no envelope-known net anywhere poisons the domain it drives
test "series derivation refuses a domain driven by an unbounded device" {
    var scratch = arena();
    defer scratch.deinit();
    const alloc = scratch.allocator();
    const instances = [_]env_mod.Instance{
        .{ .ref_des = "U1", .component = "mystery-driver", .value = "", .footprint = "", .symbol = "" },
        passive("R1", "res-0402", "49.9R"),
    };
    const nets = [_]env_mod.Net{
        .{ .name = "V5", .pins = &[_]env_mod.PinRef{.{ .ref_des = "R1", .pin = "1" }} },
        .{ .name = "NODE", .pins = &[_]env_mod.PinRef{ .{ .ref_des = "R1", .pin = "2" }, .{ .ref_des = "U1", .pin = "1" } } },
    };
    const ports = [_]env_mod.Port{.{ .name = "V5", .net = "V5", .direction = "in", .kind = "power", .rated_min = 4.75, .rated_max = 5.25 }};
    const outer = flatBlock(&instances, &nets, &ports);
    const result = try build(alloc, &outer, .{});
    try testing.expectEqual(@as(?NetEnvelope, null), envelopeFor(result, "NODE"));
}

// spec: eval/net-envelopes - A DNP series resistor is absent copper and derives nothing
test "series derivation ignores a DNP resistor" {
    var scratch = arena();
    defer scratch.deinit();
    const alloc = scratch.allocator();
    var option = passive("R1", "res-0402", "0R");
    option.dnp = true;
    const instances = [_]env_mod.Instance{ option, passive("C1", "cap-0402", "1uF") };
    const nets = [_]env_mod.Net{
        .{ .name = "V5", .pins = &[_]env_mod.PinRef{.{ .ref_des = "R1", .pin = "1" }} },
        .{ .name = "FILT", .pins = &[_]env_mod.PinRef{ .{ .ref_des = "R1", .pin = "2" }, .{ .ref_des = "C1", .pin = "1" } } },
        .{ .name = "GND", .pins = &[_]env_mod.PinRef{.{ .ref_des = "C1", .pin = "2" }} },
    };
    const ports = [_]env_mod.Port{.{ .name = "V5", .net = "V5", .direction = "in", .kind = "power", .rated_min = 4.75, .rated_max = 5.25 }};
    const outer = flatBlock(&instances, &nets, &ports);
    const result = try build(alloc, &outer, .{});
    try testing.expectEqual(@as(?NetEnvelope, null), envelopeFor(result, "FILT"));
}

// spec: eval/net-envelopes - An inductor bias feed derives its bias node from the rail it taps
test "series derivation crosses a bias-tee inductor" {
    var scratch = arena();
    defer scratch.deinit();
    const alloc = scratch.allocator();
    // The LMX bias-tee shape: an 18 nH choke feeds LO_BIAS from the rail; the
    // node's other pins are its bypass capacitor and the 50R pull-ups.
    const instances = [_]env_mod.Instance{
        passive("L1", "ind-0402", "18nH"),
        passive("C1", "cap-0402", "0.01uF"),
    };
    const nets = [_]env_mod.Net{
        .{ .name = "V_3V3", .pins = &[_]env_mod.PinRef{.{ .ref_des = "L1", .pin = "2" }} },
        .{ .name = "LO_BIAS", .pins = &[_]env_mod.PinRef{ .{ .ref_des = "L1", .pin = "1" }, .{ .ref_des = "C1", .pin = "1" } } },
        .{ .name = "GND", .pins = &[_]env_mod.PinRef{.{ .ref_des = "C1", .pin = "2" }} },
    };
    const ports = [_]env_mod.Port{.{ .name = "V_3V3", .net = "V_3V3", .direction = "in", .kind = "power", .rated_min = 3.135, .rated_max = 3.465 }};
    const outer = flatBlock(&instances, &nets, &ports);
    const result = try build(alloc, &outer, .{});
    const bias = envelopeFor(result, "LO_BIAS") orelse return error.TestExpectedEnvelope;
    try testing.expectEqual(@as(f64, 3.135), bias.min);
    try testing.expectEqual(@as(f64, 3.465), bias.max);
    try testing.expect(bias.domain != 0);
}

// spec: eval/net-envelopes - An inductor between two unknown nets is a switching coil and merges nothing
test "series derivation does not merge unknown nets across an inductor" {
    var scratch = arena();
    defer scratch.deinit();
    const alloc = scratch.allocator();
    // The boost-converter shape: VIN (undeclared here) — L — SW, with the
    // rectifier diode giving SW a path to the declared 22 V output. Merging
    // across the coil would hand the input rail the output's ceiling.
    const instances = [_]env_mod.Instance{
        passive("L1", "ind-0402", "4.7uH"),
        .{ .ref_des = "D1", .component = "diode-sod323", .value = "", .footprint = "", .symbol = "" },
        .{ .ref_des = "U1", .component = "lm2733", .value = "", .footprint = "", .symbol = "" },
    };
    const nets = [_]env_mod.Net{
        .{ .name = "VIN_UNDECLARED", .pins = &[_]env_mod.PinRef{.{ .ref_des = "L1", .pin = "1" }} },
        .{ .name = "SW", .pins = &[_]env_mod.PinRef{ .{ .ref_des = "L1", .pin = "2" }, .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "D1", .pin = "1" } } },
        .{ .name = "V_22V", .pins = &[_]env_mod.PinRef{ .{ .ref_des = "D1", .pin = "2" }, .{ .ref_des = "U1", .pin = "2" } } },
    };
    const ports = [_]env_mod.Port{.{ .name = "V_22V", .net = "V_22V", .direction = "out", .kind = "power", .rated_min = 21.5, .rated_max = 22.13 }};
    const outer = flatBlock(&instances, &nets, &ports);
    const result = try build(alloc, &outer, .{});
    // Neither coil end derives: VIN must not inherit the output's ceiling,
    // and SW (an energy-storage node) has no series-resistor correlation.
    try testing.expectEqual(@as(?NetEnvelope, null), envelopeFor(result, "VIN_UNDECLARED"));
    try testing.expectEqual(@as(?NetEnvelope, null), envelopeFor(result, "SW"));
}

// ── Module-scope declaration tests ──────────────────────────────────────

/// A one-instance module block whose own `(net-envelope …)` forms are already
/// parsed — the shape `design_block.materializeBlock` publishes.
fn moduleBlock(
    name: []const u8,
    instances: []const env_mod.Instance,
    nets: []const env_mod.Net,
    ports: []const env_mod.Port,
    declared: []const Declaration,
) DesignBlock {
    return .{
        .name = name,
        .instances = instances,
        .nets = nets,
        .ports = ports,
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
        .envelopes = .{ .declared = declared },
    };
}

// spec: eval/net-envelopes - A module's own net-envelope declaration applies to the flattened sub-block/NET name
test "a module-scope declaration reaches the net its instantiation names" {
    var scratch = arena();
    defer scratch.deinit();
    const alloc = scratch.allocator();
    // The LT3045 shape: the module owns its SET node's envelope, so the board
    // never states it. `vout` is the module's own parameter, already evaluated.
    const instances = [_]env_mod.Instance{passive("R_SET", "res-0402", "49.9k")};
    const nets = [_]env_mod.Net{
        .{ .name = "SET", .pins = &[_]env_mod.PinRef{.{ .ref_des = "R_SET", .pin = "1" }} },
        .{ .name = "GND", .pins = &[_]env_mod.PinRef{.{ .ref_des = "R_SET", .pin = "2" }} },
    };
    const declared = [_]Declaration{.{
        .net = "SET",
        .min = 4.85,
        .max = 5.15,
        .rationale = "100 uA into R_SET",
        .rule = "declared in module ldo_5v",
    }};
    var inner = moduleBlock("ldo", &instances, &nets, &.{}, &declared);
    const sbs = [_]env_mod.SubBlock{.{ .name = "ldo_5v", .block = &inner }};
    const outer: DesignBlock = .{
        .name = "outer",
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &sbs,
    };
    const result = try build(alloc, &outer, .{});
    const set = envelopeFor(result, "ldo_5v/SET") orelse return error.TestExpectedEnvelope;
    try testing.expectEqual(@as(f64, 4.85), set.min);
    try testing.expectEqual(@as(f64, 5.15), set.max);
    try testing.expectEqual(NetEnvelope.Origin.declared, set.origin);
    try testing.expectEqualStrings("declared in module ldo_5v", set.provenance.rule);
    try testing.expectEqual(@as(usize, 0), result.contradictions.len);
}

// spec: eval/net-envelopes - A board declaration narrower than the module's own claim about the same net is a contradiction
test "the module owns its node's envelope and a board may only widen it" {
    var scratch = arena();
    defer scratch.deinit();
    const alloc = scratch.allocator();
    const instances = [_]env_mod.Instance{passive("R_SET", "res-0402", "33k")};
    const nets = [_]env_mod.Net{
        .{ .name = "SET", .pins = &[_]env_mod.PinRef{.{ .ref_des = "R_SET", .pin = "1" }} },
        .{ .name = "GND", .pins = &[_]env_mod.PinRef{.{ .ref_des = "R_SET", .pin = "2" }} },
    };
    const declared = [_]Declaration{.{ .net = "SET", .min = 3.2, .max = 3.4, .rule = "declared in module ldo_3v3" }};
    var inner = moduleBlock("ldo", &instances, &nets, &.{}, &declared);
    const sbs = [_]env_mod.SubBlock{.{ .name = "ldo_3v3", .block = &inner }};
    const outer: DesignBlock = .{
        .name = "outer",
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &sbs,
    };
    // Narrower than the module's own claim: the two statements cannot both hold.
    const narrow = [_]Declaration{.{ .net = "ldo_3v3/SET", .min = 3.23, .max = 3.37 }};
    const clash = try build(alloc, &outer, .{ .declarations = &narrow });
    try testing.expectEqual(@as(usize, 1), clash.contradictions.len);
    try testing.expectEqual(@as(f64, 3.2), clash.contradictions[0].derived_min);
    // Widening is not a contradiction, and the union is what gets published.
    const wide = [_]Declaration{.{ .net = "ldo_3v3/SET", .min = 0, .max = 3.6 }};
    const merged = try build(alloc, &outer, .{ .declarations = &wide });
    try testing.expectEqual(@as(usize, 0), merged.contradictions.len);
    const set = envelopeFor(merged, "ldo_3v3/SET") orelse return error.TestExpectedEnvelope;
    try testing.expectEqual(@as(f64, 0), set.min);
    try testing.expectEqual(@as(f64, 3.6), set.max);
}

// spec: eval/net-envelopes - lookup reads a net's proven potential from rails, ground-class names and the envelope table alike
test "lookup answers from every table a rating surface must consult" {
    const envelopes = [_]NetEnvelope{.{ .net = "buck/VIN_F", .min = 11.4, .max = 12.6 }};
    const rails = [_]env_mod.PowerRail{.{ .name = "V_3V3", .nominal = 3.3, .rated_voltage = .{ .min = 3.135, .max = 3.465 } }};
    const block: DesignBlock = .{
        .name = "outer",
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
        .rails = &rails,
        .envelopes = .{ .published = &envelopes },
    };
    // A ground-class name is 0 V without any declaration.
    const gnd = lookup(&block, "GND") orelse return error.TestExpectedEnvelope;
    try testing.expectEqual(@as(f64, 0), gnd.max);
    try testing.expectEqualStrings(ground_rule, gnd.provenance.rule);
    // A rail resolves even when the envelope table never named it …
    const rail = lookup(&block, "V_3V3") orelse return error.TestExpectedEnvelope;
    try testing.expectEqual(@as(f64, 3.465), rail.max);
    // … and a module-internal name resolves only in the envelope table, whose
    // `.ref.pin` split-net suffix is stripped exactly as a rail's is.
    const filtered = lookup(&block, "buck/VIN_F.U1.IN") orelse return error.TestExpectedEnvelope;
    try testing.expectEqual(@as(f64, 12.6), filtered.max);
    try testing.expectEqual(@as(?NetEnvelope, null), lookup(&block, "NOWHERE"));
}
