//! Power-budget analysis: walks the built design's rails and sums each rail's
//! declared source current against its consumers, tagging every `Rail`
//! ok/tight/over/no-source/no-consumers. Feeds the review doc's power-budget
//! table. Read-only over the `DesignBlock`.

const std = @import("std");
const env_mod = @import("env.zig");
const na = @import("net_analysis.zig");
const DesignBlock = env_mod.DesignBlock;
const Section = env_mod.Section;

/// Verdict for one power rail in the budget table. `tight` flags rails
/// pulling >80% of source capacity, `over` flags rails whose load exceeds
/// declared max, `no_source`/`no_consumers` mark incomplete declarations.
pub const RailStatus = enum { ok, tight, over, no_source, no_consumers };

// ── Constants ─────────────────────────────────────────────────────
const zero_voltage: f64 = 0.0;
const current_convergence_a: f64 = 1e-9;
const percent_full: f64 = 100.0;
const percent_fraction_base: f64 = 1.0;
/// Derating fraction — typical-load threshold at which a rail flips to
/// `.tight` (a rail is "tight" once typical load exceeds 80% of its rating).
const default_derating: f64 = 0.8;
const rating_midpoint: f64 = 0.5;
const sentinel_current: f64 = 1.0;

/// Breakdown of one (ref_des, net) group's contribution to a rail. Pins on
/// the same ref_des but different downstream nets (e.g. both VDDA18USB and
/// VDDA18PLL on the MCU, both rolling up to V1P8 via ferrites) appear as
/// separate consumers so the source net stays visible.
pub const RailConsumer = struct {
    ref_des: []const u8,
    /// Library component of `ref_des` (e.g. "adf5901acpz-rl7") — the part
    /// drawing this current. "" when the ref isn't a top-level instance
    /// (e.g. a regulator-input back-computed consumer keyed on a sub-block).
    component: []const u8 = "",
    /// Optional human label from `(load "name")` on the annotated pin. Used
    /// for rolled-up loads lumped on a carrier part (a bulk cap or filter
    /// bead) so the row names the real consumer instead of the carrier.
    /// "" ⇒ display falls back to `component`.
    label: []const u8 = "",
    /// Net name as declared in source (e.g. "VDDA18USB"), before any
    /// ferrite-bead rollup to the top-level rail name.
    net: []const u8,
    /// Pin identifiers on this ref_des that sit on `net`.
    pins: []const []const u8,
    /// Sum of `(i-typ …)` annotations across this group's pins. Null when
    /// no pin in the group carried an annotation.
    i_typ: ?f64,
    /// Sum of `(i-max …)` annotations across this group's pins. Null when
    /// no pin in the group carried an annotation.
    i_max: ?f64,
};

/// One power rail in the analyzed design. Ferrite-bead-bridged nets collapse
/// into a single Rail: the `net` field is the top-level rail name the source
/// was declared on (e.g. "V1P8"), and `load_typ_a` / `load_max_a` include
/// draws from all downstream rails (e.g. "VDDA18USB" via FB3).
pub const Rail = struct {
    net: []const u8,
    /// Every power-like sub-block output tied to this rail, independent of
    /// whether that output also declares a current capacity. These paths locate
    /// the physical source pads for branch-current analysis.
    source_terminals: []const []const u8 = &.{},
    /// Sub-block output port path (e.g. "ldo/VOUT"), or "" when no source
    /// declared capacity for this rail.
    source_label: []const u8 = "",
    /// Source typical capacity (A). Null when source didn't declare it.
    source_typ_a: ?f64 = null,
    /// Source absolute-max capacity (A). Null when source didn't declare it.
    source_max_a: ?f64 = null,
    load_typ_a: f64 = 0,
    load_max_a: f64 = 0,
    any_typ_load: bool = false,
    any_max_load: bool = false,
    /// 100 * (1 - load_typ / source_typ). Null when margin can't be computed
    /// (either no source typ or no typ loads). Can go negative for "over".
    margin_pct: ?f64 = null,
    status: RailStatus,
    /// Per-device breakdown of what lands on this rail. One entry per
    /// (ref_des, net) pair with at least one pin; sorted by i_typ desc then
    /// ref_des. Empty when the rail has no pin connections at all.
    consumers: []const RailConsumer = &.{},
};

const SourceInfo = struct {
    source_label: []const u8,
    display_rail: []const u8,
    current_typ: ?f64,
    current_max: ?f64,
};

fn collectExternalSources(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    net_parent: *std.StringHashMapUnmanaged([]const u8),
    sources: *std.StringHashMapUnmanaged(SourceInfo),
    source_terminals: *std.StringHashMapUnmanaged(std.ArrayList([]const u8)),
) std.mem.Allocator.Error!void {
    for (block.ports) |port| {
        if (!std.mem.eql(u8, port.direction, "in")) continue;
        if (port.isDeclaredNonPower() or !port.isPowerSource()) continue;
        const base = na.baseNetName(if (port.net.len > 0) port.net else port.name);
        const root = na.findRoot(net_parent, base);
        const path = try std.fmt.allocPrint(allocator, "@external/{s}", .{port.name});
        const label = try std.fmt.allocPrint(allocator, "external/{s}", .{port.name});
        const terminal_gop = try source_terminals.getOrPut(allocator, root);
        if (!terminal_gop.found_existing) terminal_gop.value_ptr.* = .empty;
        try appendUniqueString(allocator, terminal_gop.value_ptr, path);
        if (port.current_typ == null and port.current_max == null) continue;
        try putStrongerSource(allocator, sources, root, .{
            .source_label = label,
            .display_rail = base,
            .current_typ = port.current_typ,
            .current_max = port.current_max,
        });
    }
}

/// A block's OWN `out` power ports, read as the declared rating of the rail
/// they leave on.
///
/// `analyze` only ever runs on the design being built, so on a STANDALONE
/// MODULE PAGE — `bcuda-lt3045-ldo` routed by itself rather than instantiated —
/// the module IS the board, and `(port "VOUT" out power (current 0.5 0.5))` is
/// the only statement anywhere on that page about how much current its output
/// copper carries. Without this pass the page has no rail at all for VOUT, so
/// the router's IPC-2221 widening has nothing to size against and the rail
/// routes at the board default track width.
///
/// A PARALLEL collector rather than a second direction inside
/// `collectExternalSources`, because the two say different things and must not
/// share its tail:
///
///   * an `in` port is where current ENTERS, so it also records an
///     `@external/NAME` source TERMINAL, which `power_integrity` resolves to
///     the connector pads it injects the rail's current at. An `out` port is
///     where current LEAVES; listing one there would inject a rail's whole
///     current at a sink and corrupt the branch-current solve. This collector
///     therefore registers capacity only, never a terminal.
///   * a port with no `(current …)` contributes NOTHING here, where the `in`
///     collector still records its terminal. That keeps the pass inert for
///     every design that does not declare an output current — the only new
///     rail rows are ones the author explicitly rated.
///
/// Parent-board semantics are untouched: a module reached as a `(sub-block …)`
/// is read by the sub-block loop in `analyze` through its parent's `net_ties`,
/// and never by this pass.
fn collectSelfOutputs(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    net_parent: *std.StringHashMapUnmanaged([]const u8),
    sources: *std.StringHashMapUnmanaged(SourceInfo),
) std.mem.Allocator.Error!void {
    for (block.ports) |port| {
        if (!std.mem.eql(u8, port.direction, "out")) continue;
        if (port.current_typ == null and port.current_max == null) continue;
        // An explicit non-power kind is authoritative, exactly as it is for
        // sub-block outputs: `(port "TX" out signal …)` is not a rail.
        if (port.isDeclaredNonPower()) continue;
        const base = na.baseNetName(if (port.net.len > 0) port.net else port.name);
        const root = na.findRoot(net_parent, base);
        try putStrongerSource(allocator, sources, root, .{
            .source_label = try std.fmt.allocPrint(allocator, "external/{s}", .{port.name}),
            .display_rail = base,
            .current_typ = port.current_typ,
            .current_max = port.current_max,
        });
    }
}

/// Record `incoming` as `root`'s source unless a stronger one already holds it.
/// Several sources can land on one rail — a battery and a charger both on
/// VBATT, or an internal regulator and the boundary rating of the port that
/// re-exports its rail — and the budget check wants the highest capacity.
/// Ranking by `current_max` (falling back to typ) makes the answer independent
/// of declaration order.
fn putStrongerSource(
    allocator: std.mem.Allocator,
    sources: *std.StringHashMapUnmanaged(SourceInfo),
    root: []const u8,
    incoming: SourceInfo,
) std.mem.Allocator.Error!void {
    if (sources.get(root)) |existing| {
        const existing_max = existing.current_max orelse existing.current_typ orelse 0;
        const incoming_max = incoming.current_max orelse incoming.current_typ orelse 0;
        if (incoming_max <= existing_max) return;
    }
    try sources.put(allocator, root, incoming);
}

/// Analyze a block's declared sources and annotated consumer currents, and
/// return one Rail entry per rail that has either a source declaration or a
/// nonzero annotated load. GND is excluded. The returned slice is owned by
/// the caller's allocator and references string data in the block itself.
pub fn analyze(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
) std.mem.Allocator.Error![]const Rail {
    // Step 1: union-find on ferrite-bead-bridged nets. A ferrite is a DC
    // conductor, so loads on its downstream side must attribute back to the
    // upstream regulator's budget.
    var net_parent = try na.buildFerriteBridges(allocator, block);

    // Step 2: collect source declarations — from sub-block output ports, and
    // from the block's OWN boundary ports in both directions.
    var sources: std.StringHashMapUnmanaged(SourceInfo) = .empty;
    var source_terminals: std.StringHashMapUnmanaged(std.ArrayList([]const u8)) = .empty;

    // A board-level input power port is an external source, just as a regulator
    // output is an internal source. Keep an explicit synthetic terminal path so
    // post-route analysis can resolve it to the connector pads carrying the
    // port's net. This also lets `(current typ max)` on the boundary participate
    // in the same source-capacity budget as module outputs.
    try collectExternalSources(allocator, block, &net_parent, &sources, &source_terminals);

    // A board-level OUTPUT power port rates the rail it exports: on a standalone
    // module page that declaration is the page's only current figure, and on a
    // board that re-exports a rail through a connector it is what leaves the
    // board. Capacity only, no terminal — see `collectSelfOutputs`.
    try collectSelfOutputs(allocator, block, &net_parent, &sources);

    for (block.sub_blocks) |sb| {
        for (sb.block.ports) |port| {
            if (!std.mem.eql(u8, port.direction, "out")) continue;
            if (port.isDeclaredNonPower()) continue;
            if (!port.isPowerSource() and !std.ascii.eqlIgnoreCase(port.kind, "power")) continue;
            const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ sb.name, port.name });
            for (block.net_ties) |nt| {
                const matched = std.mem.eql(u8, nt.a, path) or std.mem.eql(u8, nt.b, path);
                if (!matched) continue;
                const top_net = if (std.mem.eql(u8, nt.a, path)) nt.b else nt.a;
                const base = na.baseNetName(top_net);
                const root = na.findRoot(&net_parent, base);
                const terminal_gop = try source_terminals.getOrPut(allocator, root);
                if (!terminal_gop.found_existing) terminal_gop.value_ptr.* = .empty;
                try appendUniqueString(allocator, terminal_gop.value_ptr, path);
                if (port.current_typ == null and port.current_max == null) continue;
                // Multiple sources on the same rail (e.g. battery + charger
                // both on VBATT) keep the highest-capacity one — see
                // `putStrongerSource`.
                try putStrongerSource(allocator, &sources, root, .{
                    .source_label = path,
                    .display_rail = base,
                    .current_typ = port.current_typ,
                    .current_max = port.current_max,
                });
            }
        }
    }

    // Step 3: sum consumer currents keyed on canonical root, and record a
    // per-(ref_des, net) breakdown so the review can expand each rail. The
    // walk descends into sub-blocks: a module's annotated pins land on the
    // PARENT rail its port ties to, because on a board whose every load is
    // sealed inside a `(sub-block …)` the top-level nets carry nothing but
    // test points and a connector.
    var tally = LoadTally{};
    const top = try topScope(allocator, block, &net_parent);
    try creditLoads(allocator, block, top, &tally);
    const loads = &tally.loads;
    const consumer_groups = &tally.groups;

    // Step 3b: back-compute input-side draw for sub-blocks with
    // (efficiency) declared on their output port. Iin = Iout × Vout/Vin / η
    // adds each regulator as a consumer on its input rail, so an upstream
    // rail (e.g. VBATT) sees the cumulative draw of every downstream
    // regulator that taps it.
    //
    // Fixed-point iteration: when regulators chain (VBATT → buck → VDD →
    // ldo → V1P8), the order we visit sub-blocks matters. Re-run up to 8×,
    // tracking each sub-block's last contribution and applying only the
    // delta on each pass. Converges in one iteration per tree-depth level.
    const SubContribution = struct { iin_typ: f64, iin_max: f64 };
    var sb_contrib: std.StringHashMapUnmanaged(SubContribution) = .empty;
    var iter: u32 = 0;
    while (iter < 8) : (iter += 1) {
        var changed = false;
        for (block.sub_blocks) |sb| {
            for (sb.block.ports) |out_port| {
                if (!std.mem.eql(u8, out_port.direction, "out")) continue;
                const has_scalar = out_port.efficiency != null;
                if (!has_scalar and !out_port.efficiency_linear) continue;
                const vout = out_port.nominal orelse continue;

                // Convergence + consumer state is keyed per (sub-block, OUTPUT
                // port), not per sub-block: a dual-output module (a PMIC with
                // two efficiency-declared outputs) must charge its input rail
                // for the SUM of both outputs' back-computed draw. Keying on
                // sb.name alone made output B's delta cancel A's and the upsert
                // overwrite it, so the rail saw only the last-visited output.
                const contrib_key = try std.fmt.allocPrint(allocator, "{s}\x00{s}", .{ sb.name, out_port.name });

                const out_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ sb.name, out_port.name });
                const out_rail_root = findRailForSubPath(block, &net_parent, out_path) orelse continue;
                const out_load = loads.get(out_rail_root) orelse RailLoad{};
                if (!out_load.any_typ and !out_load.any_max) continue;

                for (sb.block.ports) |in_port| {
                    if (!std.mem.eql(u8, in_port.direction, "in")) continue;
                    // A regulator draws its current through a SUPPLY input, not
                    // through its enable. Charging the whole input draw to
                    // whatever rail an `(port "EN" in signal …)` sits on both
                    // invents a load that rail never carries and inflates the
                    // dissipation of whatever regulator feeds it.
                    if (in_port.isDeclaredNonPower()) continue;

                    const in_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ sb.name, in_port.name });
                    const in_rail_root = findRailForSubPath(block, &net_parent, in_path) orelse continue;
                    const in_display = loads.get(in_rail_root) orelse RailLoad{
                        .first_name = railNameForSubPath(block, in_path) orelse in_rail_root,
                    };
                    const vin = in_port.nominal orelse resolveRailVoltage(allocator, block, in_display.first_name) orelse continue;
                    if (vin <= zero_voltage) continue;

                    // For linear regulators, η = Vout/Vin (drops out of the ratio below so
                    // Iin ≈ Iout as expected for a pass-through LDO). For switchers, use
                    // the user-declared scalar. `efficiency_linear` takes precedence when
                    // both are declared — it's an explicit "compute this" instruction.
                    const eta = if (out_port.efficiency_linear) vout / vin else out_port.efficiency.?;
                    if (eta <= zero_voltage) continue;

                    const ratio = vout / (vin * eta);
                    const iin_typ = out_load.sum_typ * ratio;
                    const iin_max = out_load.sum_max * ratio;

                    const prev = sb_contrib.get(contrib_key) orelse SubContribution{ .iin_typ = 0, .iin_max = 0 };
                    const delta_typ = iin_typ - prev.iin_typ;
                    const delta_max = iin_max - prev.iin_max;
                    if (@abs(delta_typ) < current_convergence_a and @abs(delta_max) < current_convergence_a) break;
                    changed = true;

                    // Upsert the consumer group. Pin list + any_* flags only
                    // set on first touch; sums are always replaced with the
                    // latest absolute value. Keyed on the OUTPUT port too so a
                    // dual-output module's two outputs land in distinct groups
                    // instead of colliding on the shared input rail.
                    const group_key = try std.fmt.allocPrint(allocator, "{s}\x00{s}\x00{s}", .{ sb.name, out_port.name, in_display.first_name });
                    const gop = try consumer_groups.getOrPut(allocator, group_key);
                    if (!gop.found_existing) {
                        gop.value_ptr.* = .{ .ref_des = sb.name, .net = in_display.first_name, .root = in_rail_root };
                        try gop.value_ptr.pins.append(allocator, in_port.name);
                        var updated = in_display;
                        try updated.group_keys.append(allocator, group_key);
                        try loads.put(allocator, in_rail_root, updated);
                    }
                    gop.value_ptr.sum_typ = iin_typ;
                    gop.value_ptr.sum_max = iin_max;
                    if (out_load.any_typ) gop.value_ptr.any_typ = true;
                    if (out_load.any_max) gop.value_ptr.any_max = true;

                    var in_load = loads.get(in_rail_root) orelse RailLoad{ .first_name = in_display.first_name };
                    in_load.sum_typ += delta_typ;
                    in_load.sum_max += delta_max;
                    if (out_load.any_typ) in_load.any_typ = true;
                    if (out_load.any_max) in_load.any_max = true;
                    try loads.put(allocator, in_rail_root, in_load);

                    try sb_contrib.put(allocator, contrib_key, SubContribution{ .iin_typ = iin_typ, .iin_max = iin_max });
                    break;
                }
            }
        }
        if (!changed) break;
    }

    // Step 4: build Rail rows — one per root that has a source or nonzero
    // load. GND is excluded from the rollup.
    var rails: std.ArrayList(Rail) = .empty;
    var emitted_roots: std.StringHashMapUnmanaged(void) = .empty;

    const derating = default_derating;
    var src_iter = sources.iterator();
    while (src_iter.next()) |entry| {
        const root = entry.key_ptr.*;
        const src = entry.value_ptr.*;
        const load = loads.get(root) orelse RailLoad{};
        const consumers = try buildConsumers(allocator, load.group_keys.items, consumer_groups);
        const rail = buildRail(.{
            .display_name = src.display_rail,
            .source_label = src.source_label,
            .source_typ = src.current_typ,
            .source_max = src.current_max,
            .source_terminals = if (source_terminals.get(root)) |terminals| terminals.items else &.{},
            .load_typ = load.sum_typ,
            .load_max = load.sum_max,
            .any_typ = load.any_typ,
            .any_max = load.any_max,
            .consumers = consumers,
            .derating = derating,
        });
        try rails.append(allocator, rail);
        try emitted_roots.put(allocator, root, {});
    }

    var load_iter = loads.iterator();
    while (load_iter.next()) |entry| {
        const root = entry.key_ptr.*;
        const load = entry.value_ptr.*;
        if (!load.any_typ and !load.any_max) continue;
        if (std.mem.eql(u8, root, "GND")) continue;
        if (emitted_roots.contains(root)) continue;
        const consumers = try buildConsumers(allocator, load.group_keys.items, consumer_groups);
        const rail = buildRail(.{
            .display_name = load.first_name,
            .source_terminals = if (source_terminals.get(root)) |terminals| terminals.items else &.{},
            .load_typ = load.sum_typ,
            .load_max = load.sum_max,
            .any_typ = load.any_typ,
            .any_max = load.any_max,
            .consumers = consumers,
            .derating = derating,
        });
        try rails.append(allocator, rail);
    }

    // Ownership contract (see doc comment): hand back an exact-length owned
    // slice, not `.items` (a sub-slice of a capacity-padded allocation whose
    // slack a non-arena caller's `free` can't return).
    return rails.toOwnedSlice(allocator);
}

// ── Load aggregation ──────────────────────────────────────────────────
// A rail's load is not just what the top-level nets carry. A board whose every
// functional block is a sealed `(sub-block …)` declares its currents INSIDE
// those modules, and the top-level rail then shows nothing but test points and
// a connector. The pass below therefore descends: a module's annotated pins are
// credited to the parent rail its port ties to, recursively, so a regulator's
// output rail sees the loads its siblings actually draw.

/// Accumulated load on one canonical rail root.
const RailLoad = struct {
    sum_typ: f64 = 0,
    sum_max: f64 = 0,
    any_typ: bool = false,
    any_max: bool = false,
    /// First non-root net name seen for this root — used as the display
    /// name when no source declared it.
    first_name: []const u8 = "",
    /// Ordered list of `(ref_des, net)` group keys for consumer lookup.
    /// Parallel to entries in the tally's `groups` map, keyed by
    /// `{ref}\0{net}` to avoid the cost of a nested hashmap.
    group_keys: std.ArrayList([]const u8) = .empty,
};

/// One `(ref_des, net)` consumer row under construction.
const ConsumerGroup = struct {
    ref_des: []const u8,
    component: []const u8 = "",
    label: []const u8 = "",
    net: []const u8,
    root: []const u8,
    pins: std.ArrayList([]const u8) = .empty,
    sum_typ: f64 = 0,
    sum_max: f64 = 0,
    any_typ: bool = false,
    any_max: bool = false,
};

/// Everything the load walk accumulates: per-root totals and the consumer rows
/// behind them. One value so the recursion carries a single pointer.
const LoadTally = struct {
    loads: std.StringHashMapUnmanaged(RailLoad) = .empty,
    groups: std.StringHashMapUnmanaged(ConsumerGroup) = .empty,
};

/// The block currently being credited: which of ITS nets feed a rail, what its
/// parts are called in the report, and its own ref-des → component map.
///
/// At the design's top level `rail_of` holds every net mapped to its own
/// canonical (ferrite-collapsed) root and the prefix is empty. Inside a
/// sub-block only the nets its PORTS expose appear, each mapped onto the
/// parent's root, and the prefix is the `sub-block/` path — so a module's
/// private nets stay private and its parts are named the way the flattened
/// netlist names them.
const LoadScope = struct {
    prefix: []const u8 = "",
    rail_of: std.StringHashMapUnmanaged([]const u8) = .empty,
    components: std.StringHashMapUnmanaged([]const u8) = .empty,
};

/// The design's own scope: every net is a rail of its own, under its canonical
/// ferrite-collapsed root.
fn topScope(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    net_parent: *std.StringHashMapUnmanaged([]const u8),
) std.mem.Allocator.Error!LoadScope {
    var scope = LoadScope{};
    for (block.nets) |net| {
        const base = na.baseNetName(net.name);
        try scope.rail_of.put(allocator, base, na.findRoot(net_parent, base));
    }
    for (block.instances) |inst| try scope.components.put(allocator, inst.ref_des, inst.component);
    return scope;
}

/// A sub-block's scope, seen from `parent`: each port that ties to a net the
/// parent already maps carries that port's INTERNAL net name onto the parent's
/// rail root. A port tying to nothing, or to a net outside the parent's own
/// scope, contributes nothing — its module's pins on that net stay internal.
///
/// Two ports sharing one internal net keep the FIRST mapping, so a module that
/// exposes one node twice credits its load once and does so deterministically.
fn childScope(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    sb: env_mod.SubBlock,
    parent: LoadScope,
) std.mem.Allocator.Error!LoadScope {
    var scope = LoadScope{
        .prefix = try std.fmt.allocPrint(allocator, "{s}{s}/", .{ parent.prefix, sb.name }),
    };
    for (sb.block.ports) |port| {
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ sb.name, port.name });
        defer allocator.free(path);
        const parent_net = railNameForSubPath(block, path) orelse continue;
        const root = parent.rail_of.get(na.baseNetName(parent_net)) orelse continue;
        const internal = na.baseNetName(if (port.net.len > 0) port.net else port.name);
        if (scope.rail_of.contains(internal)) continue;
        try scope.rail_of.put(allocator, internal, root);
    }
    for (sb.block.instances) |inst| try scope.components.put(allocator, inst.ref_des, inst.component);
    return scope;
}

/// Credit every annotated pin in `block` — and in the sub-blocks whose ports
/// reach one of `scope`'s rails — to that rail's tally.
fn creditLoads(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    scope: LoadScope,
    tally: *LoadTally,
) std.mem.Allocator.Error!void {
    for (block.nets) |net| {
        const root = scope.rail_of.get(na.baseNetName(net.name)) orelse continue;
        try creditNet(allocator, tally, scope, net, root);
    }
    for (block.sub_blocks) |sb| {
        const child = try childScope(allocator, block, sb, scope);
        // A module none of whose ports reach a rail here has nothing to
        // contribute, and descending into it would only cost the walk time.
        if (child.rail_of.count() == 0) continue;
        try creditLoads(allocator, sb.block, child, tally);
    }
}

/// Add one net's annotated pins to `root`'s totals and to its per-part rows.
fn creditNet(
    allocator: std.mem.Allocator,
    tally: *LoadTally,
    scope: LoadScope,
    net: env_mod.Net,
    root: []const u8,
) std.mem.Allocator.Error!void {
    const base = na.baseNetName(net.name);
    // A root reached from inside a sub-block is a TOP-LEVEL net name, already
    // seeded by the design's own pass; the fallback only fires for a tie whose
    // parent net carries no pins of its own, where the root is the best name
    // there is.
    var load = tally.loads.get(root) orelse RailLoad{
        .first_name = if (scope.prefix.len == 0) base else root,
    };
    for (net.pins) |pin| {
        if (pin.i_typ) |v| {
            load.sum_typ += v;
            load.any_typ = true;
        }
        if (pin.i_max) |v| {
            load.sum_max += v;
            load.any_max = true;
        }
        if (pin.ref_des.len == 0) continue;
        const ref = if (scope.prefix.len == 0)
            pin.ref_des
        else
            try std.fmt.allocPrint(allocator, "{s}{s}", .{ scope.prefix, pin.ref_des });
        const group_key = try std.fmt.allocPrint(allocator, "{s}\x00{s}", .{ ref, base });
        const gop = try tally.groups.getOrPut(allocator, group_key);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{
                .ref_des = ref,
                .component = scope.components.get(pin.ref_des) orelse "",
                .net = base,
                .root = root,
            };
            try load.group_keys.append(allocator, group_key);
        }
        // First non-empty `(load "…")` label on any pin of the group wins.
        if (gop.value_ptr.label.len == 0 and pin.load_label.len > 0) gop.value_ptr.label = pin.load_label;
        try gop.value_ptr.pins.append(allocator, pin.pin);
        if (pin.i_typ) |v| {
            gop.value_ptr.sum_typ += v;
            gop.value_ptr.any_typ = true;
        }
        if (pin.i_max) |v| {
            gop.value_ptr.sum_max += v;
            gop.value_ptr.any_max = true;
        }
    }
    try tally.loads.put(allocator, root, load);
}

/// One module's declared draw on one rail: the `(current typ max)` a
/// `(sub-block …)` states on an INPUT power port, resolved to the top-level
/// rail that port ties to.
///
/// Deliberately NOT a `RailConsumer` and deliberately not summed into
/// `load_typ_a` / `load_max_a`. A `RailConsumer` is an annotated PIN — a
/// measured contribution the budget table adds up — while this is a boundary
/// declaration made by the module about itself, which the budget has never
/// counted. Folding it in would silently restate every board's rail totals.
///
/// What it IS good for is branch sizing: everything inside the module reaches
/// the rail through that port, so no series element in there can carry more
/// than the port declares. `fab_readiness` uses it to size a module's own
/// ferrite/jumper against the branch it actually feeds instead of against the
/// whole rail's worst case.
pub const BranchLoad = struct {
    /// Sub-block instance name (e.g. "lna"). Every flattened ref-des inside
    /// that module carries it as a `path ++ "/"` prefix.
    path: []const u8,
    /// Top-level rail net name the branch taps (e.g. "V_5VA").
    rail: []const u8,
    /// Summed `(current typ …)` across this module's input ports on the rail.
    i_typ: ?f64,
    /// Summed `(current … max)` across this module's input ports on the rail.
    i_max: ?f64,
};

/// Every `(path, rail)` pair for which a sub-block's input power ports declare
/// a current. A module tapping one rail through several ports contributes the
/// SUM of those ports, because one series element inside it may feed them all.
///
/// Top-level sub-blocks only: a port nested two modules deep ties to a net in
/// its parent's private scope, not to a board rail, and inventing a mapping for
/// it would be guessing. A branch with no entry simply has no declared data,
/// and every caller must keep its conservative whole-rail answer there.
pub fn branchLoads(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
) std.mem.Allocator.Error![]const BranchLoad {
    var out: std.ArrayList(BranchLoad) = .empty;
    for (block.sub_blocks) |sb| {
        for (sb.block.ports) |port| {
            if (!std.mem.eql(u8, port.direction, "in")) continue;
            if (port.isDeclaredNonPower() or !port.isPowerSource()) continue;
            if (port.current_typ == null and port.current_max == null) continue;
            const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ sb.name, port.name });
            defer allocator.free(path);
            const rail = railNameForSubPath(block, path) orelse continue;
            try accumulateBranch(allocator, &out, sb.name, rail, port);
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Add one input port's declared current to its module's `(path, rail)` entry,
/// creating the entry on first sight.
fn accumulateBranch(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(BranchLoad),
    path: []const u8,
    rail: []const u8,
    port: env_mod.Port,
) std.mem.Allocator.Error!void {
    for (out.items) |*existing| {
        if (!std.mem.eql(u8, existing.path, path)) continue;
        if (!std.ascii.eqlIgnoreCase(existing.rail, rail)) continue;
        if (port.current_typ) |v| existing.i_typ = (existing.i_typ orelse 0) + v;
        if (port.current_max) |v| existing.i_max = (existing.i_max orelse 0) + v;
        return;
    }
    try out.append(allocator, .{
        .path = path,
        .rail = rail,
        .i_typ = port.current_typ,
        .i_max = port.current_max,
    });
}

fn buildConsumers(
    allocator: std.mem.Allocator,
    group_keys: []const []const u8,
    groups: anytype,
) std.mem.Allocator.Error![]const RailConsumer {
    var out: std.ArrayList(RailConsumer) = .empty;
    for (group_keys) |key| {
        const g = groups.get(key) orelse continue;
        // Skip groups with no current annotation on either axis — test
        // points, connectors, and other passive witnesses don't contribute
        // to the rail budget and just clutter the review.
        if (!g.any_typ and !g.any_max) continue;
        try out.append(allocator, .{
            .ref_des = g.ref_des,
            .component = g.component,
            .label = g.label,
            .net = g.net,
            .pins = g.pins.items,
            .i_typ = if (g.any_typ) g.sum_typ else null,
            .i_max = if (g.any_max) g.sum_max else null,
        });
    }
    std.mem.sort(RailConsumer, out.items, {}, lessThanConsumer);
    return out.toOwnedSlice(allocator);
}

/// Highest typ draw first (annotated groups above unannotated); ties broken
/// by ref_des for stable output.
fn lessThanConsumer(_: void, a: RailConsumer, b: RailConsumer) bool {
    const a_typ = a.i_typ orelse -sentinel_current;
    const b_typ = b.i_typ orelse -sentinel_current;
    if (a_typ != b_typ) return a_typ > b_typ;
    return std.mem.order(u8, a.ref_des, b.ref_des) == .lt;
}

const RailInput = struct {
    display_name: []const u8,
    source_label: []const u8 = "",
    source_typ: ?f64 = null,
    source_max: ?f64 = null,
    source_terminals: []const []const u8 = &.{},
    load_typ: f64,
    load_max: f64,
    any_typ: bool,
    any_max: bool,
    consumers: []const RailConsumer,
    derating: f64,
};

fn buildRail(input: RailInput) Rail {
    var status: RailStatus = .ok;
    var margin: ?f64 = null;

    if (input.source_label.len == 0) {
        status = .no_source;
    } else if (!input.any_typ and !input.any_max) {
        status = .no_consumers;
    } else if (input.source_max) |smax| {
        if (input.any_max and input.load_max > smax) status = .over;
    }

    if (status == .ok) {
        if (input.source_typ) |styp| {
            if (input.any_typ) {
                margin = percent_full * (percent_fraction_base - input.load_typ / styp);
                if (input.load_typ > input.derating * styp) status = .tight;
            }
        }
    } else if (status == .over) {
        if (input.source_typ) |styp| if (input.any_typ) {
            margin = percent_full * (percent_fraction_base - input.load_typ / styp);
        };
    }

    return .{
        .net = input.display_name,
        .source_terminals = input.source_terminals,
        .source_label = input.source_label,
        .source_typ_a = input.source_typ,
        .source_max_a = input.source_max,
        .load_typ_a = input.load_typ,
        .load_max_a = input.load_max,
        .any_typ_load = input.any_typ,
        .any_max_load = input.any_max,
        .margin_pct = margin,
        .status = status,
        .consumers = input.consumers,
    };
}

fn appendUniqueString(
    allocator: std.mem.Allocator,
    list: *std.ArrayList([]const u8),
    value: []const u8,
) std.mem.Allocator.Error!void {
    for (list.items) |existing| if (std.mem.eql(u8, existing, value)) return;
    try list.append(allocator, value);
}

/// Find the canonical rail root for a sub-block path like `"ldo/VIN"` by
/// resolving it through net_ties and then through the ferrite union-find.
fn findRailForSubPath(
    block: *const DesignBlock,
    net_parent: *std.StringHashMapUnmanaged([]const u8),
    path: []const u8,
) ?[]const u8 {
    for (block.net_ties) |nt| {
        const matched = std.mem.eql(u8, nt.a, path) or std.mem.eql(u8, nt.b, path);
        if (!matched) continue;
        const top_net = if (std.mem.eql(u8, nt.a, path)) nt.b else nt.a;
        const base = na.baseNetName(top_net);
        return na.findRoot(net_parent, base);
    }
    return null;
}

/// Return the display-friendly top-level net name tied to a sub-block path
/// (e.g. `"ldo/VOUT"` → `"V3P3"`), or null when nothing ties it. Public because
/// the thermal analyzer asks the same question of the same `net_ties` when it
/// charges a regulator with its conversion loss — one resolution, one answer.
pub fn railNameForSubPath(block: *const DesignBlock, path: []const u8) ?[]const u8 {
    for (block.net_ties) |nt| {
        const matched = std.mem.eql(u8, nt.a, path) or std.mem.eql(u8, nt.b, path);
        if (!matched) continue;
        const top_net = if (std.mem.eql(u8, nt.a, path)) nt.b else nt.a;
        return na.baseNetName(top_net);
    }
    return null;
}

/// Resolve the expected voltage of a top-level rail. Checks, in order:
///   1. Any sub-block output port tied to this rail that declares `nominal`
///      (the regulator's output voltage IS the rail voltage).
///   2. A section-level power port (e.g. `(port "VDD" in power 3.3)`).
///   3. A top-level design-block port's `nominal` or midpoint of `rated`.
/// Returns null when nothing resolves — the analyzer skips the
/// back-computation so the user can see which rail needs a voltage hint.
/// Public because the thermal analyzer answers the same question about the
/// same rails: two resolutions would be two different boards.
pub fn resolveRailVoltage(allocator: std.mem.Allocator, block: *const DesignBlock, rail_name: []const u8) ?f64 {
    // 1. Sub-block output port → look for a net-tie tying its path to the rail.
    for (block.sub_blocks) |sb| {
        for (sb.block.ports) |p| {
            if (!std.mem.eql(u8, p.direction, "out")) continue;
            const v = p.nominal orelse continue;
            // Use the caller's allocator for the scratch path rather than
            // punching a fresh page_allocator allocation through a request
            // arena. Freed immediately either way.
            const path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ sb.name, p.name }) catch continue;
            defer allocator.free(path);
            for (block.net_ties) |nt| {
                const matched = std.mem.eql(u8, nt.a, path) or std.mem.eql(u8, nt.b, path);
                if (!matched) continue;
                const top_net = if (std.mem.eql(u8, nt.a, path)) nt.b else nt.a;
                if (std.mem.eql(u8, na.baseNetName(top_net), rail_name)) return v;
            }
        }
    }

    // 2. Section-level power port.
    for (block.sections) |sec| if (sectionVoltage(sec, rail_name)) |v| return v;

    // 3. Top-level port.
    for (block.ports) |p| {
        const port_net = if (p.net.len > 0) p.net else p.name;
        if (!std.mem.eql(u8, port_net, rail_name)) continue;
        if (p.nominal) |v| return v;
        if (p.rated_min != null and p.rated_max != null) {
            return (p.rated_min.? + p.rated_max.?) * rating_midpoint;
        }
    }
    return null;
}

fn sectionVoltage(sec: env_mod.Section, rail_name: []const u8) ?f64 {
    for (sec.ports) |sp| {
        if (!std.mem.eql(u8, sp.name, rail_name)) continue;
        if (sp.voltage) |v| return v;
    }
    for (sec.sub_sections) |sub| if (sectionVoltage(sub, rail_name)) |v| return v;
    return null;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// The shape every sealed-module board has, and the one the top-level-only
/// walk could not see:
///
/// ```
///   V12 ──[buck: η 0.5, 12 V → 3.3 V]──▶ V3P3 ──▶ loadmod
///                                                   U1   0.25 A on its VDD port net
///                                                   inner/U2 0.10 A, two levels down
///                                                   U3   5.00 A on PRIV, exposed by no port
/// ```
///
/// Nothing at the TOP level is annotated — the only top-level pin is a test
/// point, exactly as on a board whose every load lives in a `(sub-block …)`.
fn siblingChainBlock(alloc: std.mem.Allocator) !DesignBlock {
    const inner = try alloc.create(DesignBlock);
    const inner_pins = try alloc.dupe(env_mod.PinRef, &.{.{ .ref_des = "U2", .pin = "1", .i_typ = 0.10 }});
    inner.* = .{
        .name = "inner",
        .instances = try alloc.dupe(env_mod.Instance, &.{namedPart("U2", "child-chip")}),
        .nets = try alloc.dupe(env_mod.Net, &.{.{ .name = "VCC", .pins = inner_pins }}),
        .ports = try alloc.dupe(env_mod.Port, &.{.{ .name = "VCC", .net = "VCC", .direction = "in" }}),
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };

    const load_mod = try alloc.create(DesignBlock);
    const vdd_pins = try alloc.dupe(env_mod.PinRef, &.{.{ .ref_des = "U1", .pin = "1", .i_typ = 0.25 }});
    const priv_pins = try alloc.dupe(env_mod.PinRef, &.{.{ .ref_des = "U3", .pin = "1", .i_typ = 5.0 }});
    load_mod.* = .{
        .name = "loadmod",
        .instances = try alloc.dupe(env_mod.Instance, &.{ namedPart("U1", "big-chip"), namedPart("U3", "private-chip") }),
        .nets = try alloc.dupe(env_mod.Net, &.{
            .{ .name = "VDD", .pins = vdd_pins },
            .{ .name = "PRIV", .pins = priv_pins },
        }),
        .ports = try alloc.dupe(env_mod.Port, &.{.{ .name = "VDD", .net = "VDD", .direction = "in" }}),
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = try alloc.dupe(env_mod.SubBlock, &.{.{ .name = "inner", .block = inner }}),
        .net_ties = try alloc.dupe(env_mod.NetTie, &.{.{ .a = "VDD", .b = "inner/VCC" }}),
    };

    const buck = try alloc.create(DesignBlock);
    buck.* = .{
        .name = "buck",
        .instances = try alloc.dupe(env_mod.Instance, &.{namedPart("U9", "buck-chip")}),
        .nets = &.{},
        .ports = try alloc.dupe(env_mod.Port, &.{
            .{ .name = "VIN", .net = "VIN", .direction = "in", .nominal = 12.0 },
            .{ .name = "VOUT", .net = "VOUT", .direction = "out", .nominal = 3.3, .efficiency = 0.5 },
        }),
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };

    const tp_pins = try alloc.dupe(env_mod.PinRef, &.{.{ .ref_des = "TP1", .pin = "1" }});
    return .{
        .name = "board",
        .instances = try alloc.dupe(env_mod.Instance, &.{namedPart("TP1", "testpoint")}),
        .nets = try alloc.dupe(env_mod.Net, &.{
            .{ .name = "V12", .pins = &.{} },
            .{ .name = "V3P3", .pins = tp_pins },
        }),
        .ports = try alloc.dupe(env_mod.Port, &.{.{ .name = "V12", .net = "V12", .direction = "in", .nominal = 12.0 }}),
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = try alloc.dupe(env_mod.SubBlock, &.{
            .{ .name = "buck", .block = buck },
            .{ .name = "loadmod", .block = load_mod },
        }),
        .net_ties = try alloc.dupe(env_mod.NetTie, &.{
            .{ .a = "V12", .b = "buck/VIN" },
            .{ .a = "V3P3", .b = "buck/VOUT" },
            .{ .a = "V3P3", .b = "loadmod/VDD" },
        }),
    };
}

/// A minimal placed part for the fixtures above.
fn namedPart(ref_des: []const u8, component: []const u8) env_mod.Instance {
    return .{
        .ref_des = ref_des,
        .component = component,
        .value = "",
        .footprint = "",
        .symbol = "",
    };
}

/// The analyzed rail named `net`, or null when the walk emitted none.
fn railNamed(rails: []const Rail, net: []const u8) ?Rail {
    for (rails) |rail| {
        if (std.mem.eql(u8, rail.net, net)) return rail;
    }
    return null;
}

// spec: eval/power_budget - a sibling sub-block's annotated pins load the parent rail its port ties to, so a rail whose consumers are all sealed in modules is no longer empty
test "a sub-block's annotated pins land on the parent rail its port ties to" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const block = try siblingChainBlock(alloc);
    const rails = try analyze(alloc, &block);
    const v3p3 = railNamed(rails, "V3P3").?;

    try testing.expectEqual(@as(usize, 1), v3p3.source_terminals.len);
    try testing.expectEqualStrings("buck/VOUT", v3p3.source_terminals[0]);
    try testing.expectEqualStrings("", v3p3.source_label);

    // 0.25 A from loadmod/U1 plus 0.10 A two levels down — the top level itself
    // carries only a test point.
    try testing.expect(v3p3.any_typ_load);
    try testing.expectApproxEqAbs(@as(f64, 0.35), v3p3.load_typ_a, 1e-9);

    var found_u1 = false;
    for (v3p3.consumers) |c| {
        if (!std.mem.eql(u8, c.ref_des, "loadmod/U1")) continue;
        found_u1 = true;
        try testing.expectApproxEqAbs(@as(f64, 0.25), c.i_typ.?, 1e-9);
        // The row names the module's own part and net, under the flattened ref.
        try testing.expectEqualStrings("big-chip", c.component);
        try testing.expectEqualStrings("VDD", c.net);
    }
    try testing.expect(found_u1);
}

// spec: eval/power_budget - the sub-block load walk recurses, so a module nested inside a module still credits the board rail its ports chain up to
test "a nested sub-block's load reaches the board rail two levels up" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const block = try siblingChainBlock(alloc);
    const rails = try analyze(alloc, &block);
    const v3p3 = railNamed(rails, "V3P3").?;

    var inner: ?RailConsumer = null;
    for (v3p3.consumers) |c| {
        if (std.mem.eql(u8, c.ref_des, "loadmod/inner/U2")) inner = c;
    }
    try testing.expectApproxEqAbs(@as(f64, 0.10), inner.?.i_typ.?, 1e-9);
    try testing.expectEqualStrings("child-chip", inner.?.component);
}

// spec: eval/power_budget - only a sub-block net a port exposes credits the parent; a module's private net stays private however heavily it is annotated
test "a module's private net is never credited to a parent rail" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const block = try siblingChainBlock(alloc);
    const rails = try analyze(alloc, &block);

    // PRIV carries 5 A — twenty times the rest of the board — and reaches no
    // port, so it appears on no rail at all.
    for (rails) |rail| {
        try testing.expect(rail.load_typ_a < 1.0);
        for (rail.consumers) |c| {
            try testing.expect(!std.mem.eql(u8, c.ref_des, "loadmod/U3"));
        }
    }
}

// spec: eval/power_budget - a regulator's input draw is charged to a supply input, never to the rail an explicitly signal-kinded enable input sits on
test "an enable input never carries the regulator's input draw" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var block = try siblingChainBlock(alloc);
    // Give the buck an ENABLE input on the rail it feeds, declared `signal`,
    // and strip the supply input's voltage so only the enable resolves one —
    // the exact shape that charged a boost converter's whole 12 V draw to the
    // 3.3 V rail holding its enable pin.
    const buck = block.sub_blocks[0].block;
    const ports = try alloc.alloc(env_mod.Port, 3);
    ports[0] = .{ .name = "VIN", .net = "VIN", .direction = "in", .rated_min = 5.0, .rated_max = 24.0 };
    ports[1] = buck.ports[1];
    ports[2] = .{ .name = "EN", .net = "EN", .direction = "in", .kind = "signal", .nominal = 3.3 };
    buck.ports = ports;
    const ties = try alloc.alloc(env_mod.NetTie, block.net_ties.len + 1);
    @memcpy(ties[0..block.net_ties.len], block.net_ties);
    ties[block.net_ties.len] = .{ .a = "V3P3", .b = "buck/EN" };
    block.net_ties = ties;

    const rails = try analyze(alloc, &block);
    const v3p3 = railNamed(rails, "V3P3").?;
    // The rail still carries only the two real loads — not the buck's own draw.
    try testing.expectApproxEqAbs(@as(f64, 0.35), v3p3.load_typ_a, 1e-9);
    for (v3p3.consumers) |c| {
        try testing.expect(!std.mem.eql(u8, c.ref_des, "buck"));
    }
}

// spec: eval/power_budget - a regulator's back-computed input draw counts its output rail's sub-block loads exactly once, as one consumer row on the input rail
test "the input-side back-computation does not double count sub-block loads" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const block = try siblingChainBlock(alloc);
    const rails = try analyze(alloc, &block);
    const v12 = railNamed(rails, "V12").?;

    // Iin = Iout × Vout/(Vin × η) = 0.35 × 3.3/(12 × 0.5) = 0.1925 A. Counted
    // twice it would read 0.385; the fixed-point pass applies deltas, not sums.
    try testing.expectApproxEqAbs(@as(f64, 0.1925), v12.load_typ_a, 1e-9);

    var buck_rows: usize = 0;
    for (v12.consumers) |c| {
        if (std.mem.eql(u8, c.ref_des, "buck")) buck_rows += 1;
    }
    try testing.expectEqual(@as(usize, 1), buck_rows);
}

// spec: eval/power_budget - a top-level input power port is an external rail source, and its declared current capacity and synthetic physical terminal survive into the rail budget
test "a top-level input power port supplies its board rail" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var block = try siblingChainBlock(alloc);
    const ports = try alloc.dupe(env_mod.Port, block.ports);
    ports[0].current_typ = 0.85;
    ports[0].current_max = 1.0;
    block.ports = ports;

    const rails = try analyze(alloc, &block);
    const v12 = railNamed(rails, "V12").?;
    try testing.expectEqualStrings("external/V12", v12.source_label);
    try testing.expectEqual(@as(?f64, 0.85), v12.source_typ_a);
    try testing.expectEqual(@as(?f64, 1.0), v12.source_max_a);
    try testing.expectEqual(@as(usize, 1), v12.source_terminals.len);
    try testing.expectEqualStrings("@external/V12", v12.source_terminals[0]);
}

/// A regulator module as its OWN design root — the standalone module page, where
/// nothing is a `(sub-block …)` and the only current figure on the page is the
/// rating of the module's own output port.
fn standaloneModuleBlock(alloc: std.mem.Allocator) !DesignBlock {
    const vout_pins = try alloc.dupe(env_mod.PinRef, &.{
        .{ .ref_des = "U1", .pin = "10" },
        .{ .ref_des = "C_VOUT", .pin = "1" },
    });
    return .{
        .name = "3.3 V LDO",
        .instances = try alloc.dupe(env_mod.Instance, &.{ namedPart("U1", "lt3045edd"), namedPart("C_VOUT", "cap-0603") }),
        .nets = try alloc.dupe(env_mod.Net, &.{
            .{ .name = "VIN", .pins = &.{} },
            .{ .name = "VOUT", .pins = vout_pins },
        }),
        .ports = try alloc.dupe(env_mod.Port, &.{
            .{ .name = "VIN", .net = "VIN", .direction = "in", .rated_min = 1.8, .rated_max = 20.0 },
            .{
                .name = "VOUT",
                .net = "VOUT",
                .direction = "out",
                .kind = "power",
                .nominal = 3.3,
                .current_typ = 0.5,
                .current_max = 0.5,
                .efficiency_linear = true,
            },
            .{ .name = "EN_UV", .net = "EN_UV", .direction = "in", .kind = "signal", .optional = true, .rated_min = 0.0, .rated_max = 20.0 },
        }),
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
}

// spec: eval/power_budget - a standalone module page's own out power port rates the rail it exports, so a module routed as the board still has a current figure to size copper against
test "a top-level output power port rates its own rail" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const block = try standaloneModuleBlock(alloc);
    const rails = try analyze(alloc, &block);

    const vout = railNamed(rails, "VOUT").?;
    try testing.expectEqualStrings("external/VOUT", vout.source_label);
    try testing.expectEqual(@as(?f64, 0.5), vout.source_typ_a);
    try testing.expectEqual(@as(?f64, 0.5), vout.source_max_a);
    // Current LEAVES through this port, so it is NOT a synthetic injection
    // terminal — listing it would make the branch-current solve treat a sink as
    // a source.
    try testing.expectEqual(@as(usize, 0), vout.source_terminals.len);
    // Nothing on the page is annotated, so the rating stands alone.
    try testing.expect(!vout.any_typ_load);
    try testing.expect(!vout.any_max_load);
    try testing.expectEqual(RailStatus.no_consumers, vout.status);

    // The rated input port keeps its old behaviour: an external terminal, but no
    // capacity, because it declared no `(current …)`.
    try testing.expect(railNamed(rails, "VIN") == null);
}

// spec: eval/power_budget - only a `(current …)` on a top-level out port creates a rail, and an explicitly signal-kinded output never becomes one
test "a top-level output port without a declared current rates nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var block = try standaloneModuleBlock(alloc);
    const ports = try alloc.dupe(env_mod.Port, block.ports);
    ports[1].current_typ = null;
    ports[1].current_max = null;
    block.ports = ports;
    try testing.expect(railNamed(try analyze(alloc, &block), "VOUT") == null);

    // A declared non-power kind is authoritative even with a current on it.
    const signal = try alloc.dupe(env_mod.Port, block.ports);
    signal[1].current_typ = 0.5;
    signal[1].current_max = 0.5;
    signal[1].kind = "signal";
    block.ports = signal;
    try testing.expect(railNamed(try analyze(alloc, &block), "VOUT") == null);
}

// spec: eval/power_budget - a sub-block input power port's declared current is reported as a branch load for series sizing and never enters the rail's summed budget
test "a module's declared input current is a branch load, not a budget entry" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var block = try siblingChainBlock(alloc);
    const before = railNamed(try analyze(alloc, &block), "V3P3").?;
    try testing.expectEqual(@as(usize, 0), (try branchLoads(alloc, &block)).len);

    // The load module now states what it draws at its own boundary. Its inner
    // module declares one too, and must be ignored: a nested port ties to its
    // parent's private scope, not to a board rail.
    const load_mod = block.sub_blocks[1].block;
    const load_ports = try alloc.dupe(env_mod.Port, load_mod.ports);
    load_ports[0].kind = "power";
    load_ports[0].current_typ = 0.128;
    load_ports[0].current_max = 0.144;
    load_mod.ports = load_ports;
    const inner = load_mod.sub_blocks[0].block;
    const inner_ports = try alloc.dupe(env_mod.Port, inner.ports);
    inner_ports[0].kind = "power";
    inner_ports[0].current_max = 9.0;
    inner.ports = inner_ports;

    const branches = try branchLoads(alloc, &block);
    try testing.expectEqual(@as(usize, 1), branches.len);
    try testing.expectEqualStrings("loadmod", branches[0].path);
    try testing.expectEqualStrings("V3P3", branches[0].rail);
    try testing.expectEqual(@as(?f64, 0.128), branches[0].i_typ);
    try testing.expectEqual(@as(?f64, 0.144), branches[0].i_max);

    // The rail's summed budget is byte-for-byte what it was: a boundary
    // declaration is evidence about a branch, not a second copy of the load.
    const after = railNamed(try analyze(alloc, &block), "V3P3").?;
    try testing.expectEqual(before.load_typ_a, after.load_typ_a);
    try testing.expectEqual(before.load_max_a, after.load_max_a);
    try testing.expectEqual(before.consumers.len, after.consumers.len);
}

// spec: eval/power_budget - a parent board reads a module's rating through its sub-block port, and the highest declared capacity wins a rail whichever way it was declared
test "a sub-block source outranks a smaller boundary rating on the same rail" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var block = try siblingChainBlock(alloc);
    // The buck declares 2 A on V3P3; the board also re-exports V3P3 at 0.5 A.
    const buck = block.sub_blocks[0].block;
    const buck_ports = try alloc.dupe(env_mod.Port, buck.ports);
    buck_ports[1].current_typ = 2.0;
    buck_ports[1].current_max = 2.0;
    buck.ports = buck_ports;
    const ports = try alloc.alloc(env_mod.Port, block.ports.len + 1);
    @memcpy(ports[0..block.ports.len], block.ports);
    ports[block.ports.len] = .{
        .name = "V3P3",
        .net = "V3P3",
        .direction = "out",
        .kind = "power",
        .current_typ = 0.5,
        .current_max = 0.5,
    };
    block.ports = ports;

    const v3p3 = railNamed(try analyze(alloc, &block), "V3P3").?;
    try testing.expectEqualStrings("buck/VOUT", v3p3.source_label);
    try testing.expectEqual(@as(?f64, 2.0), v3p3.source_max_a);
    // The regulator's own physical terminal is still the injection point.
    try testing.expectEqual(@as(usize, 1), v3p3.source_terminals.len);
    try testing.expectEqualStrings("buck/VOUT", v3p3.source_terminals[0]);
}
