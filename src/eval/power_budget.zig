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
const ZERO_VOLTAGE: f64 = 0.0;
const CURRENT_CONVERGENCE_A: f64 = 1e-9;
const PERCENT_FULL: f64 = 100.0;
const PERCENT_FRACTION_BASE: f64 = 1.0;
/// Derating fraction — typical-load threshold at which a rail flips to
/// `.tight` (a rail is "tight" once typical load exceeds 80% of its rating).
const DEFAULT_DERATING: f64 = 0.8;
const RATING_MIDPOINT: f64 = 0.5;
const SENTINEL_CURRENT: f64 = 1.0;

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

/// Analyze a block's declared sources and annotated consumer currents, and
/// return one Rail entry per rail that has either a source declaration or a
/// nonzero annotated load. GND is excluded. The returned slice is owned by
/// the caller's allocator and references string data in the block itself.
pub fn analyze(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
) std.mem.Allocator.Error![]const Rail {
    // ref_des → library component, so each consumer row can show the part
    // number (e.g. "U10" → "adf5901acpz-rl7") instead of just the ref.
    var components: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (block.instances) |inst| try components.put(allocator, inst.ref_des, inst.component);

    // Step 1: union-find on ferrite-bead-bridged nets. A ferrite is a DC
    // conductor, so loads on its downstream side must attribute back to the
    // upstream regulator's budget.
    var net_parent = try na.buildFerriteBridges(allocator, block);

    // Step 2: collect source declarations from sub-block output ports.
    const SourceInfo = struct {
        source_label: []const u8,
        display_rail: []const u8,
        current_typ: ?f64,
        current_max: ?f64,
    };
    var sources: std.StringHashMapUnmanaged(SourceInfo) = .empty;
    for (block.sub_blocks) |sb| {
        for (sb.block.ports) |port| {
            if (port.current_typ == null and port.current_max == null) continue;
            if (!std.mem.eql(u8, port.direction, "out")) continue;
            const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ sb.name, port.name });
            for (block.net_ties) |nt| {
                const matched = std.mem.eql(u8, nt.a, path) or std.mem.eql(u8, nt.b, path);
                if (!matched) continue;
                const top_net = if (std.mem.eql(u8, nt.a, path)) nt.b else nt.a;
                const base = na.baseNetName(top_net);
                const root = na.findRoot(&net_parent, base);
                // Multiple sources on the same rail (e.g. battery + charger
                // both on VBATT): keep the highest-capacity one for the
                // budget check. Picking by current_max makes the result
                // independent of sub-block declaration order.
                const incoming = SourceInfo{
                    .source_label = path,
                    .display_rail = base,
                    .current_typ = port.current_typ,
                    .current_max = port.current_max,
                };
                if (sources.get(root)) |existing| {
                    const existing_max = existing.current_max orelse existing.current_typ orelse 0;
                    const incoming_max = incoming.current_max orelse incoming.current_typ orelse 0;
                    if (incoming_max <= existing_max) continue;
                }
                try sources.put(allocator, root, incoming);
            }
        }
    }

    // Step 3: sum consumer currents keyed on canonical root, and record a
    // per-(ref_des, net) breakdown so the review can expand each rail.
    const RailLoad = struct {
        sum_typ: f64 = 0,
        sum_max: f64 = 0,
        any_typ: bool = false,
        any_max: bool = false,
        /// First non-root net name seen for this root — used as the display
        /// name when no source declared it.
        first_name: []const u8 = "",
        /// Ordered list of `(ref_des, net)` group keys for consumer lookup.
        /// Parallel to entries in `consumer_groups` below, keyed by
        /// `{ref}\0{net}` to avoid the cost of a nested hashmap.
        group_keys: std.ArrayListUnmanaged([]const u8) = .empty,
    };
    var loads: std.StringHashMapUnmanaged(RailLoad) = .empty;

    const ConsumerGroup = struct {
        ref_des: []const u8,
        component: []const u8 = "",
        label: []const u8 = "",
        net: []const u8,
        root: []const u8,
        pins: std.ArrayListUnmanaged([]const u8) = .empty,
        sum_typ: f64 = 0,
        sum_max: f64 = 0,
        any_typ: bool = false,
        any_max: bool = false,
    };
    var consumer_groups: std.StringHashMapUnmanaged(ConsumerGroup) = .empty;

    for (block.nets) |net| {
        const base = na.baseNetName(net.name);
        const root = na.findRoot(&net_parent, base);
        var load = loads.get(root) orelse RailLoad{ .first_name = base };
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
            const group_key = try std.fmt.allocPrint(allocator, "{s}\x00{s}", .{ pin.ref_des, base });
            const gop = try consumer_groups.getOrPut(allocator, group_key);
            if (!gop.found_existing) {
                gop.value_ptr.* = .{
                    .ref_des = pin.ref_des,
                    .component = components.get(pin.ref_des) orelse "",
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
        try loads.put(allocator, root, load);
    }

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

                    const in_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ sb.name, in_port.name });
                    const in_rail_root = findRailForSubPath(block, &net_parent, in_path) orelse continue;
                    const in_display = loads.get(in_rail_root) orelse RailLoad{
                        .first_name = findDisplayForSubPath(block, in_path) orelse in_rail_root,
                    };
                    const vin = in_port.nominal orelse resolveRailVoltage(allocator, block, in_display.first_name) orelse continue;
                    if (vin <= ZERO_VOLTAGE) continue;

                    // For linear regulators, η = Vout/Vin (drops out of the ratio below so
                    // Iin ≈ Iout as expected for a pass-through LDO). For switchers, use
                    // the user-declared scalar. `efficiency_linear` takes precedence when
                    // both are declared — it's an explicit "compute this" instruction.
                    const eta = if (out_port.efficiency_linear) vout / vin else out_port.efficiency.?;
                    if (eta <= ZERO_VOLTAGE) continue;

                    const ratio = vout / (vin * eta);
                    const iin_typ = out_load.sum_typ * ratio;
                    const iin_max = out_load.sum_max * ratio;

                    const prev = sb_contrib.get(contrib_key) orelse SubContribution{ .iin_typ = 0, .iin_max = 0 };
                    const delta_typ = iin_typ - prev.iin_typ;
                    const delta_max = iin_max - prev.iin_max;
                    if (@abs(delta_typ) < CURRENT_CONVERGENCE_A and @abs(delta_max) < CURRENT_CONVERGENCE_A) break;
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
    var rails: std.ArrayListUnmanaged(Rail) = .empty;
    var emitted_roots: std.StringHashMapUnmanaged(void) = .empty;

    const derating = DEFAULT_DERATING;
    var src_iter = sources.iterator();
    while (src_iter.next()) |entry| {
        const root = entry.key_ptr.*;
        const src = entry.value_ptr.*;
        const load = loads.get(root) orelse RailLoad{};
        const consumers = try buildConsumers(allocator, load.group_keys.items, &consumer_groups);
        const rail = buildRail(
            src.display_rail,
            src.source_label,
            src.current_typ,
            src.current_max,
            load.sum_typ,
            load.sum_max,
            load.any_typ,
            load.any_max,
            consumers,
            derating,
        );
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
        const consumers = try buildConsumers(allocator, load.group_keys.items, &consumer_groups);
        const rail = buildRail(load.first_name, "", null, null, load.sum_typ, load.sum_max, load.any_typ, load.any_max, consumers, derating);
        try rails.append(allocator, rail);
    }

    // Ownership contract (see doc comment): hand back an exact-length owned
    // slice, not `.items` (a sub-slice of a capacity-padded allocation whose
    // slack a non-arena caller's `free` can't return).
    return rails.toOwnedSlice(allocator);
}

fn buildConsumers(
    allocator: std.mem.Allocator,
    group_keys: []const []const u8,
    groups: anytype,
) std.mem.Allocator.Error![]const RailConsumer {
    var out: std.ArrayListUnmanaged(RailConsumer) = .empty;
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
    const a_typ = a.i_typ orelse -SENTINEL_CURRENT;
    const b_typ = b.i_typ orelse -SENTINEL_CURRENT;
    if (a_typ != b_typ) return a_typ > b_typ;
    return std.mem.order(u8, a.ref_des, b.ref_des) == .lt;
}

fn buildRail(
    display_name: []const u8,
    source_label: []const u8,
    source_typ: ?f64,
    source_max: ?f64,
    load_typ: f64,
    load_max: f64,
    any_typ: bool,
    any_max: bool,
    consumers: []const RailConsumer,
    derating: f64,
) Rail {
    var status: RailStatus = .ok;
    var margin: ?f64 = null;

    if (source_label.len == 0) {
        status = .no_source;
    } else if (!any_typ and !any_max) {
        status = .no_consumers;
    } else if (source_max) |smax| {
        if (any_max and load_max > smax) status = .over;
    }

    if (status == .ok) {
        if (source_typ) |styp| {
            if (any_typ) {
                margin = PERCENT_FULL * (PERCENT_FRACTION_BASE - load_typ / styp);
                if (load_typ > derating * styp) status = .tight;
            }
        }
    } else if (status == .over) {
        if (source_typ) |styp| if (any_typ) {
            margin = PERCENT_FULL * (PERCENT_FRACTION_BASE - load_typ / styp);
        };
    }

    return .{
        .net = display_name,
        .source_label = source_label,
        .source_typ_a = source_typ,
        .source_max_a = source_max,
        .load_typ_a = load_typ,
        .load_max_a = load_max,
        .any_typ_load = any_typ,
        .any_max_load = any_max,
        .margin_pct = margin,
        .status = status,
        .consumers = consumers,
    };
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

/// Return the display-friendly top-level net name tied to a sub-block path.
fn findDisplayForSubPath(block: *const DesignBlock, path: []const u8) ?[]const u8 {
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
fn resolveRailVoltage(allocator: std.mem.Allocator, block: *const DesignBlock, rail_name: []const u8) ?f64 {
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
            return (p.rated_min.? + p.rated_max.?) * RATING_MIDPOINT;
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
