//! Flattened introspection for the CLI read tools. `list_instances`,
//! `get_net`, and `list_free_pins` answer top-level-only by default, which
//! is misleading on a hierarchical design: sub-block children are invisible
//! and a rail merged across a `(net …)` tie shows only its top-level pins.
//! These helpers reuse the KiCad-export flattener (`collectInstances` /
//! `flattenAndMergeNets`) — the same machinery the PCB / netlist paths run —
//! so the netlist an agent reads is the netlist the board is built from.
//! Also home to the `list_free_pins` pin classifier, shared with the
//! top-level path in `mcp_tools.zig`.

const std = @import("std");
const env_mod = @import("../eval/env.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const ids = @import("../eval/ids.zig");
const json_writer = @import("../json_writer.zig");
const export_kicad = @import("../export_kicad.zig");
const netlist_mod = @import("../export_kicad_netlist.zig");
const net_names = @import("../net_name.zig");
const variants = @import("../eval/variants.zig");
const net_envelopes = @import("../eval/net_envelopes.zig");

const FlatInstance = export_kicad.FlatInstance;
const FlatNet = export_kicad.FlatNet;
const FlatPin = export_kicad.FlatPin;

/// Open a JSON object whose first key is the flattened `ref_des`.
fn writeRefDesOpen(w: anytype, ref: []const u8) !void {
    try w.writeAll("{\"ref_des\":");
    try json_writer.writeString(w, ref);
}

// ── Assembly variants ──────────────────────────────────────────────────

/// Emit the design's `"variants"` catalog and the `"variant"` this listing was
/// evaluated with, as the leading keys of an instances document.
///
/// Both keys are OMITTED for a design that declares none, so every design in
/// the corpus keeps the exact document it emitted before variants existed —
/// the reader learns "this design has one assembly" from their absence.
pub fn writeVariantHeader(w: anytype, block: *const env_mod.DesignBlock) !void {
    if (block.variants.decls.len == 0) return;
    try w.writeAll("\"variants\":[");
    for (block.variants.decls, 0..) |d, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"name\":");
        try json_writer.writeString(w, d.name);
        try w.writeAll(",\"doc\":");
        try json_writer.writeString(w, d.doc);
        try w.print(",\"default\":{s}}}", .{if (d.is_default) "true" else "false"});
    }
    try w.writeAll("],\"variant\":");
    try json_writer.writeString(w, block.variants.activeName());
    try w.writeAll(",");
}

/// Emit one instance's `,"populated_in":[…]` — every declared variant the part
/// is stuffed in, base included as `""`. Omitted (like the header) for a design
/// that declares no variants.
pub fn writePopulatedIn(
    w: anytype,
    block: *const env_mod.DesignBlock,
    inst_variants: env_mod.InstanceVariants,
    dnp: bool,
) !void {
    if (block.variants.decls.len == 0) return;
    // `dnp` here is the SELECTED variant's answer, so a permanent `(dnp)` has
    // to be read back off the clauses: a part DNP for a reason no clause could
    // have produced is DNP in every variant.
    const base_dnp = variants.unconditionalDnp(dnp, inst_variants.rules);
    try w.writeAll(",\"populated_in\":[");
    var written: usize = 0;
    for (block.variants.decls) |d| {
        if (!variants.populatedIn(inst_variants.rules, base_dnp, d.name)) continue;
        if (written > 0) try w.writeAll(",");
        try json_writer.writeString(w, d.name);
        written += 1;
    }
    try w.writeAll("]");
}

// ── Pin classification (shared with the top-level list_free_pins) ───────

/// Best-effort classification of a pinout function name. Used by
/// `list_free_pins` to filter and annotate unassigned pins. Heuristics are
/// tuned for STM32 / common MCU pinouts and will degrade gracefully (return
/// `.other`) on unfamiliar names — callers should not treat this as authoritative.
pub const PinCategory = enum { gpio, power, clock, analog, other };

/// Classify a pinout function name into a `PinCategory` (best-effort).
pub fn classifyPin(function: []const u8) PinCategory {
    if (function.len == 0) return .other;
    // STM32-style port pin: P[A-Z][digits], optionally followed by alt-function text.
    if (function.len >= 3 and function[0] == 'P' and function[1] >= 'A' and function[1] <= 'Z') {
        var all_digits = true;
        for (function[2..]) |c| {
            if (c < '0' or c > '9') {
                all_digits = false;
                break;
            }
        }
        if (all_digits) return .gpio;
    }
    // Power: VDD, VSS, VCC, VBAT, VBUS, VREF, VDDA…
    if (std.mem.startsWith(u8, function, "V") and function.len >= 2) {
        const rest = function[1..];
        if (std.mem.startsWith(u8, rest, "DD")) return .power;
        if (std.mem.startsWith(u8, rest, "SS")) return .power;
        if (std.mem.startsWith(u8, rest, "CC")) return .power;
        if (std.mem.startsWith(u8, rest, "BAT")) return .power;
        if (std.mem.startsWith(u8, rest, "BUS")) return .power;
        if (std.mem.startsWith(u8, rest, "REF")) return .power;
    }
    if (std.mem.eql(u8, function, "GND") or std.mem.startsWith(u8, function, "GND_")) return .power;
    // Analog: ADC_IN*, A[DI]C prefix, AIN*
    if (std.mem.startsWith(u8, function, "ADC") or
        std.mem.startsWith(u8, function, "AIN") or
        std.mem.startsWith(u8, function, "DAC"))
        return .analog;
    // Clock: OSC*, XTAL*, CLK / CLKIN / CLKOUT prefix
    if (std.mem.startsWith(u8, function, "OSC") or
        std.mem.startsWith(u8, function, "XTAL") or
        std.mem.startsWith(u8, function, "CLK"))
        return .clock;
    return .other;
}

/// The stable string name for a `PinCategory` (matches the tool's enum arg).
pub fn categoryName(c: PinCategory) []const u8 {
    return switch (c) {
        .gpio => "gpio",
        .power => "power",
        .clock => "clock",
        .analog => "analog",
        .other => "other",
    };
}

// ── Shared pin-count / pinout resolution ────────────────────────────────

/// Resolve the `lib/pinouts/<key>.sexp` lookup key for a part: the
/// component's declared pinout name, then its symbol name, then the
/// instance's own symbol string. Resolving through the component's pinout
/// name (not just `symbol`) is what lets a connector that declares
/// `(pinout …)` but no `(symbol …)` still find its pads.
fn pinoutLookupName(eval: *Evaluator, component: []const u8, symbol: []const u8) []const u8 {
    if (eval.component_cache.get(component)) |cd| {
        if (cd.pinout_name.len > 0) return cd.pinout_name;
        if (cd.symbol_name.len > 0) return cd.symbol_name;
    }
    return symbol;
}

/// Pin count for an instance: the explicit multi-part pins when present, else
/// the size of the resolved pinout map. Fixes the `pin_count: 0` a connector
/// used to report — a part that declares `(pinout …)` but no `(symbol …)` has
/// an empty `symbol`, so the old symbol-only lookup found nothing.
pub fn instancePinCount(
    eval: *Evaluator,
    component: []const u8,
    symbol: []const u8,
    parts: []const env_mod.Part,
) usize {
    if (parts.len > 0) {
        var total: usize = 0;
        for (parts) |p| total += p.pins.len;
        return total;
    }
    const key = pinoutLookupName(eval, component, symbol);
    if (key.len == 0) return 0;
    if (ids.getSymbolPins(eval, key)) |pm| return pm.count();
    return 0;
}

// ── Flattened ref helpers ───────────────────────────────────────────────

/// The sub-block-relative leaf of a flattened ref-des ("ldo/U2" → "U2").
const leafOf = net_names.leaf;

/// ASCII case-insensitive slice equality (the ref-matching convention the
/// PCB tools use).
fn eqIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (std.ascii.toUpper(x) != std.ascii.toUpper(y)) return false;
    return true;
}

/// A passive by the first letter of its leaf ref-des (R/L/C/F/D) — the
/// sub-block prefix on a flattened ref must not fool the classifier.
fn isPassiveLeaf(ref: []const u8) bool {
    const leaf = leafOf(ref);
    if (leaf.len == 0) return false;
    return switch (leaf[0]) {
        'R', 'L', 'C', 'F', 'D' => true,
        else => false,
    };
}

fn findFlatByRef(insts: []const FlatInstance, ref: []const u8) ?FlatInstance {
    for (insts) |fi| if (std.mem.eql(u8, fi.ref_des, ref)) return fi;
    return null;
}

/// Match a flattened instance the way the PCB tools match `refs=`: an exact
/// ref-des, then a sub-block leaf, then the stable module-local origin name —
/// all case-insensitive, exact pass first so a full ref never loses to a leaf.
fn findFlatByRefOrLeaf(insts: []const FlatInstance, ref: []const u8) ?FlatInstance {
    for (insts) |fi| if (eqIgnoreCase(fi.ref_des, ref)) return fi;
    for (insts) |fi| if (eqIgnoreCase(leafOf(fi.ref_des), ref)) return fi;
    for (insts) |fi| if (fi.origin_key.len > 0 and eqIgnoreCase(fi.origin_key, ref)) return fi;
    return null;
}

// ── Port-alias-aware net flattening ─────────────────────────────────────

/// Sub-block path join ("ldo" + "VOUT" → "ldo/VOUT"), mirroring the
/// prefixing convention of the export_kicad flattener.
fn joinPath(allocator: std.mem.Allocator, prefix: []const u8, name: []const u8) std.mem.Allocator.Error![]const u8 {
    if (prefix.len == 0) return allocator.dupe(u8, name);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, name });
}

/// Map "path/PORT" → "path/NET" for every sub-block port whose declared net
/// differs from the port name (the `(port "VOUT" vout-str out)` long form).
/// A parent stitch `(net "V3P3" "ldo/VOUT")` references the PORT name, but
/// the flattened net is spelled by the port's internal NET ("ldo/3.3V") —
/// without this aliasing the tie names a net that doesn't exist and the rail
/// never merges.
fn collectPortAliases(
    allocator: std.mem.Allocator,
    block: *const env_mod.DesignBlock,
    prefix: []const u8,
    map: *std.StringHashMapUnmanaged([]const u8),
) std.mem.Allocator.Error!void {
    for (block.sub_blocks) |sb| {
        const sub_prefix = try joinPath(allocator, prefix, sb.name);
        for (sb.block.ports) |p| {
            if (p.net.len == 0 or std.mem.eql(u8, p.net, p.name)) continue;
            const from = try joinPath(allocator, sub_prefix, p.name);
            const to = try joinPath(allocator, sub_prefix, p.net);
            try map.put(allocator, from, to);
        }
        try collectPortAliases(allocator, sb.block, sub_prefix, map);
    }
}

/// A tie side that names no real flattened net but matches a sub-block port
/// maps onto that port's internal net; a real net name always wins.
fn resolvePortAlias(
    name: []const u8,
    real: *const std.StringHashMapUnmanaged(void),
    aliases: *const std.StringHashMapUnmanaged([]const u8),
) []const u8 {
    if (real.contains(name)) return name;
    return aliases.get(name) orelse name;
}

/// Flatten + merge nets like `export_kicad.flattenAndMergeNets`, but first
/// rewrite net-tie sides through the port aliases above so the importer's
/// stitch convention (`(net "CHK_X" "chK/X")` naming a module PORT) merges
/// even when the module's internal net name differs from the port name.
/// Fills `aliases` as a side effect so callers can resolve queries too.
fn flattenNetsPortAware(
    allocator: std.mem.Allocator,
    block: *const env_mod.DesignBlock,
    nets: *std.ArrayList(FlatNet),
    aliases: *std.StringHashMapUnmanaged([]const u8),
) std.mem.Allocator.Error!void {
    try netlist_mod.collectNets(allocator, block, "", nets);
    var ties: std.ArrayList(netlist_mod.FlatTie) = .empty;
    defer ties.deinit(allocator);
    try netlist_mod.collectNetTies(allocator, block, "", &ties);
    try collectPortAliases(allocator, block, "", aliases);
    if (aliases.count() > 0) {
        var real: std.StringHashMapUnmanaged(void) = .empty;
        defer real.deinit(allocator);
        for (nets.items) |n| try real.put(allocator, n.name, {});
        for (ties.items) |*t| {
            t.a = resolvePortAlias(t.a, &real, aliases);
            t.b = resolvePortAlias(t.b, &real, aliases);
        }
    }
    try netlist_mod.applyNetTies(allocator, nets, ties.items);
}

// ── Flattened tools ─────────────────────────────────────────────────────

/// Flattened `list_instances`: every instance in the whole design tree with
/// its sub-block-prefixed ref, module-local origin (null at top level),
/// component, symbol, value, and pin count.
pub fn listInstancesFlat(
    allocator: std.mem.Allocator,
    eval: *Evaluator,
    block: *const env_mod.DesignBlock,
    w: anytype,
) !bool {
    var list: std.ArrayList(FlatInstance) = .empty;
    try netlist_mod.collectInstances(allocator, block, "", &list);

    try w.writeAll("{");
    try writeVariantHeader(w, block);
    try w.writeAll("\"instances\":[");
    for (list.items, 0..) |fi, i| {
        if (i > 0) try w.writeAll(",");
        try writeRefDesOpen(w, fi.ref_des);
        try w.writeAll(",\"origin\":");
        if (fi.origin_key.len > 0) try json_writer.writeString(w, fi.origin_key) else try w.writeAll("null");
        try w.writeAll(",\"component\":");
        try json_writer.writeString(w, fi.component);
        try w.writeAll(",\"symbol\":");
        try json_writer.writeString(w, fi.symbol);
        try w.writeAll(",\"value\":");
        try json_writer.writeString(w, fi.value);
        const pc = instancePinCount(eval, fi.component, fi.symbol, &.{});
        try w.print(",\"pin_count\":{d}", .{pc});
        try writePopulatedIn(w, block, fi.variants, fi.dnp);
        try w.writeAll("}");
    }
    try w.writeAll("]}");
    return true;
}

/// Resolve a net query to an index into the merged net list. Tries, in order:
///  1. exact canonical name ("V3P3", "GND");
///  2. a sub-scoped spelling — a port-name spelling ("ldo/VOUT") maps through
///     the port aliases onto its internal net, then the raw pre-merge net of
///     that name is located and one of its pins followed into the merged net
///     it was folded into;
///  3. a unique leaf-name spelling ("MCU_RUN" for "mcu/MCU_RUN", "VOUT" for
///     "ldo/VOUT"), so module-internal nets are reachable without their
///     sub-block prefix; an ambiguous leaf lists the matches.
/// On failure writes the not-found (or ambiguous) message to `w` and returns
/// null, so callers can `orelse return false`.
fn resolveMergedNet(
    allocator: std.mem.Allocator,
    block: *const env_mod.DesignBlock,
    merged: []const FlatNet,
    query: []const u8,
    aliases: *const std.StringHashMapUnmanaged([]const u8),
    w: anytype,
) !?usize {
    for (merged, 0..) |n, i| {
        if (std.mem.eql(u8, n.name, query)) return i;
    }
    const spelled = aliases.get(query) orelse query;
    var raw: std.ArrayList(FlatNet) = .empty;
    try netlist_mod.collectNets(allocator, block, "", &raw);

    // Exact raw-name spelling (includes the sub-scoped port case).
    for (raw.items) |rn| {
        if (!std.mem.eql(u8, rn.name, spelled)) continue;
        if (rn.pins.len == 0) continue;
        if (mergedByRawPin(merged, rn.pins[0])) |i| return i;
    }

    // Leaf-name fallback over raw nets: "MCU_RUN" → "mcu/MCU_RUN".
    var leaf_hits: std.ArrayList(usize) = .empty;
    defer leaf_hits.deinit(allocator);
    for (raw.items, 0..) |rn, ri| {
        if (net_names.parent(rn.name) == null) continue;
        if (!std.mem.eql(u8, net_names.leaf(rn.name), query)) continue;
        try leaf_hits.append(allocator, ri);
    }
    if (leaf_hits.items.len == 1) {
        const rn = raw.items[leaf_hits.items[0]];
        if (rn.pins.len > 0) {
            if (mergedByRawPin(merged, rn.pins[0])) |i| return i;
        }
    } else if (leaf_hits.items.len > 1) {
        try w.writeAll("error: net not found — '");
        try w.writeAll(query);
        try w.writeAll("' is ambiguous; matches: ");
        for (leaf_hits.items, 0..) |ri, k| {
            if (k > 0) try w.writeAll(", ");
            try w.writeAll(raw.items[ri].name);
        }
        return null;
    }
    try w.writeAll("error: net not found");
    return null;
}

/// Follow a raw-net pin into the merged rail that folded it in; null when the
/// pin is absent from every merged net.
fn mergedByRawPin(merged: []const FlatNet, p: FlatPin) ?usize {
    for (merged, 0..) |mn, i| {
        for (mn.pins) |mp| {
            if (std.mem.eql(u8, mp.ref_des, p.ref_des) and std.mem.eql(u8, mp.pin, p.pin)) return i;
        }
    }
    return null;
}

/// Emit the `envelope` member of a `get_net` payload: the worst-case DC
/// potential window `eval/net_envelopes` proves for this net, how it was
/// established, and the ferrite-class root it was resolved on.
///
/// `null` when the design declares nothing that bounds the net — the honest
/// answer, and the same one `(cap-rating …)` reports as `unproven`. `source`
/// separates an author's `(net-envelope …)` claim (`authored`) from a
/// consequence of declarations the design already makes (`derived`), and
/// `origin` names the rule and what it rests on.
pub fn writeNetEnvelope(
    w: anytype,
    block: *const env_mod.DesignBlock,
    net: []const u8,
) !void {
    try w.writeAll(",\"envelope\":");
    const found = net_envelopes.lookup(block, net) orelse return w.writeAll("null");
    try w.print("{{\"lo\":{d},\"hi\":{d},\"source\":", .{ found.min, found.max });
    try json_writer.writeString(w, if (found.origin == .declared) "authored" else "derived");
    try w.writeAll(",\"origin\":");
    try json_writer.writeString(w, found.provenance.rule);
    try w.writeAll(",\"why\":");
    try json_writer.writeString(w, found.provenance.why);
    try w.writeAll(",\"path\":");
    try json_writer.writeString(w, if (found.provenance.root.len > 0) found.provenance.root else found.net);
    try w.writeAll("}");
}

/// Flattened `get_net`: every pin on the merged rail (flattened refs +
/// resolved function names) plus the passives on it. `query` accepts the
/// canonical merged name or a sub-scoped spelling.
pub fn getNetFlat(
    allocator: std.mem.Allocator,
    eval: *Evaluator,
    block: *const env_mod.DesignBlock,
    query: []const u8,
    w: anytype,
) !bool {
    var nets: std.ArrayList(FlatNet) = .empty;
    var aliases: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer aliases.deinit(allocator);
    try flattenNetsPortAware(allocator, block, &nets, &aliases);

    const idx = (try resolveMergedNet(allocator, block, nets.items, query, &aliases, w)) orelse
        return false;
    const net = nets.items[idx];

    var insts: std.ArrayList(FlatInstance) = .empty;
    try netlist_mod.collectInstances(allocator, block, "", &insts);

    try w.writeAll("{\"name\":");
    try json_writer.writeString(w, net.name);
    try writeNetEnvelope(w, block, net.name);
    try w.writeAll(",\"pins\":[");

    var passive_refs: std.StringHashMapUnmanaged(void) = .empty;
    defer passive_refs.deinit(allocator);

    for (net.pins, 0..) |p, i| {
        if (i > 0) try w.writeAll(",");
        var fname: []const u8 = "";
        if (findFlatByRef(insts.items, p.ref_des)) |fi| {
            const key = pinoutLookupName(eval, fi.component, fi.symbol);
            if (key.len > 0) {
                if (ids.getSymbolPins(eval, key)) |pm| {
                    if (pm.get(p.pin)) |f| fname = f;
                }
            }
            if (isPassiveLeaf(fi.ref_des)) try passive_refs.put(allocator, fi.ref_des, {});
        }
        try writeRefDesOpen(w, p.ref_des);
        try w.writeAll(",\"pin\":");
        try json_writer.writeString(w, p.pin);
        try w.writeAll(",\"function\":");
        try json_writer.writeString(w, fname);
        try w.writeAll("}");
    }
    try w.writeAll("],\"passives\":[");

    var it = passive_refs.iterator();
    var first = true;
    while (it.next()) |e| {
        const fi = findFlatByRef(insts.items, e.key_ptr.*) orelse continue;
        if (!first) try w.writeAll(",");
        first = false;
        try writeRefDesOpen(w, fi.ref_des);
        try w.writeAll(",\"component\":");
        try json_writer.writeString(w, fi.component);
        try w.writeAll(",\"value\":");
        try json_writer.writeString(w, fi.value);
        try w.writeAll("}");
    }
    try w.writeAll("]}");
    return true;
}

/// Emit one pin object of the free/assigned lists; `net` is null for a free pin.
fn emitFreePin(w: anytype, pin_id: []const u8, fname: []const u8, cat: PinCategory, net: ?[]const u8) !void {
    try w.writeAll("{\"pin\":");
    try json_writer.writeString(w, pin_id);
    try w.writeAll(",\"function\":");
    try json_writer.writeString(w, fname);
    if (net) |n| {
        try w.writeAll(",\"net\":");
        try json_writer.writeString(w, n);
    }
    try w.print(",\"category\":\"{s}\"}}", .{categoryName(cat)});
}

/// Flattened `list_free_pins`: `ref` matches a flattened instance by exact
/// ref / leaf / origin, and assignments come from the merged netlist, so a
/// sub-block child's assigned pins carry their canonical rail names.
pub fn listFreePinsFlat(
    allocator: std.mem.Allocator,
    eval: *Evaluator,
    block: *const env_mod.DesignBlock,
    ref_des: []const u8,
    filter: ?[]const u8,
    w: anytype,
) !bool {
    var insts: std.ArrayList(FlatInstance) = .empty;
    try netlist_mod.collectInstances(allocator, block, "", &insts);

    const target = findFlatByRefOrLeaf(insts.items, ref_des) orelse {
        try w.writeAll("error: instance not found");
        return false;
    };

    const lookup_name = pinoutLookupName(eval, target.component, target.symbol);
    if (lookup_name.len == 0) {
        try w.writeAll("{\"free_pins\":[],\"assigned_pins\":[],\"note\":\"instance has no associated symbol pinout\"}");
        return true;
    }
    const pin_map = ids.getSymbolPins(eval, lookup_name) orelse {
        try w.writeAll("{\"free_pins\":[],\"assigned_pins\":[],\"note\":\"pinout file not found for symbol\"}");
        return true;
    };

    var nets: std.ArrayList(FlatNet) = .empty;
    var aliases: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer aliases.deinit(allocator);
    try flattenNetsPortAware(allocator, block, &nets, &aliases);
    var assigned: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer assigned.deinit(allocator);
    for (nets.items) |net| {
        for (net.pins) |p| {
            if (std.mem.eql(u8, p.ref_des, target.ref_des)) try assigned.put(allocator, p.pin, net.name);
        }
    }

    try w.writeAll("{\"free_pins\":[");
    var it = pin_map.iterator();
    var first = true;
    while (it.next()) |e| {
        const pin_id = e.key_ptr.*;
        if (assigned.contains(pin_id)) continue;
        const cat = classifyPin(e.value_ptr.*);
        if (filter) |f| if (!std.mem.eql(u8, f, categoryName(cat))) continue;
        if (!first) try w.writeAll(",");
        first = false;
        try emitFreePin(w, pin_id, e.value_ptr.*, cat, null);
    }
    try w.writeAll("],\"assigned_pins\":[");
    var it2 = pin_map.iterator();
    var first2 = true;
    while (it2.next()) |e| {
        const pin_id = e.key_ptr.*;
        const net_name = assigned.get(pin_id) orelse continue;
        const cat = classifyPin(e.value_ptr.*);
        if (filter) |f| if (!std.mem.eql(u8, f, categoryName(cat))) continue;
        if (!first2) try w.writeAll(",");
        first2 = false;
        try emitFreePin(w, pin_id, e.value_ptr.*, cat, net_name);
    }
    try w.writeAll("]}");
    return true;
}

// ── Tests ───────────────────────────────────────────────────────────────

const ldochip_comp =
    \\(component "ldochip"
    \\  (description "test LDO IC")
    \\  (symbol ldochip)
    \\  (pinout ldochip)
    \\  (footprint fp-ldo)
    \\  (ignore-requirements))
;
const ldochip_pinout =
    \\(pinout "ldochip"
    \\  (pin 1 "VIN")
    \\  (pin 2 "VOUT")
    \\  (pin 3 "GND")
    \\  (pin 4 "EN")
    \\  (pin 5 "NC"))
;
const hdr4_comp =
    \\(component "hdr4"
    \\  (description "4-pin test header")
    \\  (pinout hdr4)
    \\  (footprint fp-hdr4)
    \\  (ignore-requirements))
;
const hdr4_pinout =
    \\(pinout "hdr4"
    \\  (pin 1 "1")
    \\  (pin 2 "2")
    \\  (pin 3 "3")
    \\  (pin 4 "4"))
;
const ldomod_src =
    \\(import ldochip)
    \\(defmodule ldomod ((vout 3.3))
    \\  (design-block "LDO"
    \\    (instance "U1" ldochip
    \\      (pin 1 "VIN")
    \\      (pin 2 "VOUT")
    \\      (pin 3 "GND"))
    \\    (instance "C1" (cap-0402 "10uF")
    \\      (pin 1 "VOUT")
    \\      (pin 2 "GND"))
    \\    (port "VIN" in)
    \\    (port "VOUT" out)
    \\    (port "GND" bidi)))
;
const board_src =
    \\(import ldochip)
    \\(import hdr4)
    \\(import ldomod)
    \\(design-block "Flatten Test Board"
    \\  (instance "J1" hdr4
    \\    (pin 1 "VIN_5V")
    \\    (pin 2 "VIN_5V")
    \\    (pin 3 "GND")
    \\    (pin 4 "GND"))
    \\  (instance "D1" (led-0402 "green")
    \\    (pin 1 "V3P3")
    \\    (pin 2 "LED_K"))
    \\  (instance "R1" (res-0402 "1k")
    \\    (pin 1 "LED_K")
    \\    (pin 2 "GND"))
    \\  (sub-block "ldo" (ldomod))
    \\  (net "VIN_5V" "ldo/VIN")
    \\  (net "V3P3" "ldo/VOUT")
    \\  (net "GND" "ldo/GND"))
;

// A module whose VOUT port's internal NET differs from the port name (the
// lt3045 `(port "VOUT" vout-str out)` pattern — vout-str is fmt-generated,
// here a literal). The parent stitches it BY PORT NAME ("ldo/VOUT"), so the
// merge must map the port onto its net ("ldo/3.3V") to find the rail.
const ldoport_src =
    \\(import ldochip)
    \\(defmodule ldoport ()
    \\  (design-block "LDO Port"
    \\    (instance "U1" ldochip
    \\      (pin 1 "VIN")
    \\      (pin 2 "3.3V")
    \\      (pin 3 "GND"))
    \\    (instance "C1" (cap-0402 "10uF")
    \\      (pin 1 "3.3V")
    \\      (pin 2 "GND"))
    \\    (port "VIN" in)
    \\    (port "VOUT" "3.3V" out)
    \\    (port "GND" bidi)))
;
const board2_src =
    \\(import ldochip)
    \\(import ldoport)
    \\(design-block "Port Stitch Board"
    \\  (instance "D1" (led-0402 "green")
    \\    (pin 1 "V3P3")
    \\    (pin 2 "GND"))
    \\  (sub-block "ldo" (ldoport))
    \\  (net "VIN_5V" "ldo/VIN")
    \\  (net "V3P3" "ldo/VOUT")
    \\  (net "GND" "ldo/GND"))
;

const cap_family =
    \\(component-family "cap-0402" (symbol generic-cap) (parameter "value" capacitance))
;
const res_family =
    \\(component-family "res-0402" (symbol generic-res) (parameter "value" resistance))
;
const led_family =
    \\(component-family "led-0402" (symbol generic-led) (parameter "color" string))
;

/// Write the full fixture project (passives + custom IC/connector + module +
/// design) under `dir`. Used by the flatten tests below.
fn writeFlattenFixture(dir: std.Io.Dir) !void {
    try dir.createDirPath(std.testing.io, "lib/components");
    try dir.createDirPath(std.testing.io, "lib/pinouts");
    try dir.createDirPath(std.testing.io, "lib/modules");
    try dir.createDirPath(std.testing.io, "src");
    try dir.writeFile(std.testing.io, .{ .sub_path = "lib/components/cap-0402.sexp", .data = cap_family });
    try dir.writeFile(std.testing.io, .{ .sub_path = "lib/components/res-0402.sexp", .data = res_family });
    try dir.writeFile(std.testing.io, .{ .sub_path = "lib/components/led-0402.sexp", .data = led_family });
    try dir.writeFile(std.testing.io, .{ .sub_path = "lib/components/ldochip.sexp", .data = ldochip_comp });
    try dir.writeFile(std.testing.io, .{ .sub_path = "lib/pinouts/ldochip.sexp", .data = ldochip_pinout });
    try dir.writeFile(std.testing.io, .{ .sub_path = "lib/components/hdr4.sexp", .data = hdr4_comp });
    try dir.writeFile(std.testing.io, .{ .sub_path = "lib/pinouts/hdr4.sexp", .data = hdr4_pinout });
    try dir.writeFile(std.testing.io, .{ .sub_path = "lib/modules/ldomod.sexp", .data = ldomod_src });
    try dir.writeFile(std.testing.io, .{ .sub_path = "lib/modules/ldoport.sexp", .data = ldoport_src });
    try dir.writeFile(std.testing.io, .{ .sub_path = "src/board.sexp", .data = board_src });
    try dir.writeFile(std.testing.io, .{ .sub_path = "src/board2.sexp", .data = board2_src });
}

/// Eval `src/<name>.sexp` under `project` and return the design block. The
/// evaluator (which owns the block's memory) is caller-owned so the block
/// stays alive; tests use page_allocator because eval AST memory is never freed.
fn evalBoard(alloc: std.mem.Allocator, project: []const u8, eval: *Evaluator, name: []const u8) !*env_mod.DesignBlock {
    const path = try std.fmt.allocPrint(alloc, "{s}/src/{s}.sexp", .{ project, name });
    const result = try eval.evalFile(path);
    return switch (result) {
        .design_block => |b| b,
        else => error.TestNotADesign,
    };
}

test "flatten list_instances surfaces sub-block children with prefixed refs and origins" {
    // spec: serve/mcp_tools - flatten makes list_instances include sub-block children with prefixed refs and origins
    const alloc = std.heap.page_allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFlattenFixture(tmp.dir);
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);

    var eval = Evaluator.init(alloc, project);
    defer eval.deinit();
    const block = try evalBoard(alloc, project, &eval, "board");

    var out: std.Io.Writer.Allocating = .init(alloc);
    try std.testing.expect(try listInstancesFlat(alloc, &eval, block, &out.writer));

    // The LDO module's children appear with sub-block-prefixed refs (renumbered
    // globally, e.g. ldo/U2) and their stable module-local origins (U1, C1) —
    // all invisible to the top-level-only listing.
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"ref_des\":\"ldo/") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"origin\":\"U1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"origin\":\"C1\"") != null);
    // Top-level parts keep their refs.
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"ref_des\":\"J1\"") != null);
    // The IC's pin count comes from its 5-pad pinout (only ldochip has 5 pads).
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"component\":\"ldochip\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"pin_count\":5") != null);
}

test "instancePinCount counts a connector's pads from its pinout when it has no symbol" {
    // spec: serve/mcp_tools - list_instances counts pins from the component pinout when the part declares no symbol
    const alloc = std.heap.page_allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFlattenFixture(tmp.dir);
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);

    var eval = Evaluator.init(alloc, project);
    defer eval.deinit();
    const block = try evalBoard(alloc, project, &eval, "board");

    // J1 is a pin header: it declares (pinout hdr4) but no (symbol …), so its
    // instance symbol is empty. The old symbol-only lookup returned 0.
    var j1: ?env_mod.Instance = null;
    for (block.instances) |inst| {
        if (std.mem.eql(u8, inst.ref_des, "J1")) j1 = inst;
    }
    try std.testing.expect(j1 != null);
    try std.testing.expectEqualStrings("", j1.?.symbol);
    try std.testing.expectEqual(@as(usize, 4), instancePinCount(&eval, j1.?.component, j1.?.symbol, j1.?.parts));
}

test "flatten get_net returns the merged rail and resolves a sub-scoped spelling" {
    // spec: serve/mcp_tools - flatten makes get_net return the merged rail and resolve a sub-scoped net spelling
    const alloc = std.heap.page_allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFlattenFixture(tmp.dir);
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);

    var eval = Evaluator.init(alloc, project);
    defer eval.deinit();
    const block = try evalBoard(alloc, project, &eval, "board");

    // Canonical name: V3P3 merges the top-level LED pin with the module's VOUT
    // pins (LDO output + output cap) — flattened refs, sub-block pins included.
    var out: std.Io.Writer.Allocating = .init(alloc);
    try std.testing.expect(try getNetFlat(alloc, &eval, block, "V3P3", &out.writer));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"name\":\"V3P3\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"ref_des\":\"D1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"ref_des\":\"ldo/") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"function\":\"VOUT\"") != null);

    // The sub-scoped spelling resolves to the same canonical merged net.
    var out2: std.Io.Writer.Allocating = .init(alloc);
    try std.testing.expect(try getNetFlat(alloc, &eval, block, "ldo/VOUT", &out2.writer));
    try std.testing.expect(std.mem.indexOf(u8, out2.written(), "\"name\":\"V3P3\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out2.written(), "\"ref_des\":\"ldo/") != null);
}

test "flatten get_net resolves a bare leaf name to the unique module-internal net" {
    // spec: serve/mcp_tools - flatten makes get_net resolve a bare leaf name to the unique module-internal net
    const alloc = std.heap.page_allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFlattenFixture(tmp.dir);
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);

    var eval = Evaluator.init(alloc, project);
    defer eval.deinit();
    const block = try evalBoard(alloc, project, &eval, "board");

    // "VOUT" (leaf of ldo/VOUT) resolves to the merged V3P3 rail.
    var out: std.Io.Writer.Allocating = .init(alloc);
    try std.testing.expect(try getNetFlat(alloc, &eval, block, "VOUT", &out.writer));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"name\":\"V3P3\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"ref_des\":\"ldo/") != null);

    // "VIN" (leaf of ldo/VIN) resolves to the merged VIN_5V rail.
    var out2: std.Io.Writer.Allocating = .init(alloc);
    try std.testing.expect(try getNetFlat(alloc, &eval, block, "VIN", &out2.writer));
    try std.testing.expect(std.mem.indexOf(u8, out2.written(), "\"name\":\"VIN_5V\"") != null);
}

test "flatten get_net reports an ambiguous leaf name with the matches" {
    // spec: serve/mcp_tools - flatten makes get_net list the candidates when a bare leaf name is ambiguous
    // spec: serve/mcp_tools - A module file that uses its own components imports them, so a design can import the module alone without also importing the module's dependencies
    const alloc = std.heap.page_allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFlattenFixture(tmp.dir);
    // Two ldomod instances share the "VOUT" leaf (only GND is stitched, so
    // VOUT stays module-local in both copies). ldochip is imported first,
    // mirroring board_src: ldomod's body references it bare, which only
    // resolves when the component is already cached from the parent's import.
    const amb =
        \\(import ldochip)
        \\(import ldomod)
        \\(design-block "Ambiguous Leaf Board"
        \\  (sub-block "a" (ldomod))
        \\  (sub-block "b" (ldomod))
        \\  (net "GND" "a/GND" "b/GND"))
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/amb.sexp", .data = amb });
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);

    var eval = Evaluator.init(alloc, project);
    defer eval.deinit();
    const block = try evalBoard(alloc, project, &eval, "amb");

    // "VOUT" is the leaf of both a/VOUT and b/VOUT — report both, not one.
    var out: std.Io.Writer.Allocating = .init(alloc);
    try std.testing.expect(!try getNetFlat(alloc, &eval, block, "VOUT", &out.writer));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "'VOUT' is ambiguous") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "a/VOUT") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "b/VOUT") != null);
}

test "flatten list_free_pins matches a child by name and reads assignments from the merged net" {
    // spec: serve/mcp_tools - flatten makes list_free_pins match a flattened child by name and read merged assignments
    const alloc = std.heap.page_allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFlattenFixture(tmp.dir);
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);

    var eval = Evaluator.init(alloc, project);
    defer eval.deinit();
    const block = try evalBoard(alloc, project, &eval, "board");

    // The module IC renumbers to ldo/U2, but its module-local origin "U1" still
    // finds it. Pins EN/NC are unwired; the wired VOUT pad reports the merged
    // canonical rail name "V3P3".
    var out: std.Io.Writer.Allocating = .init(alloc);
    try std.testing.expect(try listFreePinsFlat(alloc, &eval, block, "U1", null, &out.writer));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"function\":\"EN\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"function\":\"NC\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"function\":\"VOUT\",\"net\":\"V3P3\"") != null);
}

test "flatten merges a stitch that names a module port whose internal net differs" {
    // spec: serve/mcp_tools - flatten merges a sub-block stitch written against a port name whose module net differs
    const alloc = std.heap.page_allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFlattenFixture(tmp.dir);
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);

    var eval = Evaluator.init(alloc, project);
    defer eval.deinit();
    const block = try evalBoard(alloc, project, &eval, "board2");

    // The lt3045 pattern: the module's VOUT port carries the internal net
    // "3.3V", the parent stitches `(net "V3P3" "ldo/VOUT")` by PORT name.
    // The merged rail must contain the top-level LED, the module's output
    // pin (function VOUT), and the module's 10uF output cap.
    var out: std.Io.Writer.Allocating = .init(alloc);
    try std.testing.expect(try getNetFlat(alloc, &eval, block, "V3P3", &out.writer));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"name\":\"V3P3\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"ref_des\":\"D1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"ref_des\":\"ldo/") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"function\":\"VOUT\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"value\":\"10uF\"") != null);

    // Both sub-scoped spellings — the port name and the internal net name —
    // resolve to the same canonical merged rail.
    var out2: std.Io.Writer.Allocating = .init(alloc);
    try std.testing.expect(try getNetFlat(alloc, &eval, block, "ldo/VOUT", &out2.writer));
    try std.testing.expect(std.mem.indexOf(u8, out2.written(), "\"name\":\"V3P3\"") != null);
    var out3: std.Io.Writer.Allocating = .init(alloc);
    try std.testing.expect(try getNetFlat(alloc, &eval, block, "ldo/3.3V", &out3.writer));
    try std.testing.expect(std.mem.indexOf(u8, out3.written(), "\"name\":\"V3P3\"") != null);

    // list_free_pins shares the aliasing: the module IC's wired output pad
    // reports the canonical merged rail name, not the internal spelling.
    var out4: std.Io.Writer.Allocating = .init(alloc);
    try std.testing.expect(try listFreePinsFlat(alloc, &eval, block, "U1", null, &out4.writer));
    try std.testing.expect(std.mem.indexOf(u8, out4.written(), "\"function\":\"VOUT\",\"net\":\"V3P3\"") != null);
}
