const std = @import("std");
const parser_mod = @import("sexpr/parser.zig");
const env_mod = @import("eval/env.zig");
const DesignBlock = env_mod.DesignBlock;

const export_kicad = @import("export_kicad.zig");
const FlatInstance = export_kicad.FlatInstance;
const FlatNet = export_kicad.FlatNet;
const FlatPin = export_kicad.FlatPin;
const Property = env_mod.Property;

/// Error set for the KiCad netlist helpers in this module — covers parser
/// failures, allocator failures, and the local `InvalidFormat` thrown when
/// a footprint sexp is missing the expected nodes.
pub const NetlistError = std.mem.Allocator.Error || parser_mod.ParseError || error{InvalidFormat};

// --- Netlist writer ---

/// Emit a KiCad `.net` file body for a flattened design: the components
/// section with footprint references and tstamps, then the nets section
/// where any pad not present on a real net is gathered into the
/// unconnected (`code "0"`) net so KiCad treats them as NC.
pub fn writeNetlist(
    allocator: std.mem.Allocator,
    design_name: []const u8,
    instances: []const FlatInstance,
    nets: []const FlatNet,
    fp_name_map: *const std.StringHashMap([]const u8),
    fp_pad_map: *const std.StringHashMap([]const []const u8),
) std.mem.Allocator.Error![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeAll("(export (version \"E\")\n");
    try w.writeAll("  (design\n");
    try w.print("    (source \"{s}\")\n", .{design_name});
    try w.writeAll("    (tool \"canopy-eda\"))\n");

    // Components
    try w.writeAll("  (components\n");
    for (instances) |inst| {
        try w.print("    (comp (ref \"{s}\")\n", .{inst.ref_des});
        try w.print("      (value \"{s}\")\n", .{inst.value});
        const kicad_fp = fp_name_map.get(inst.footprint) orelse inst.footprint;
        try w.print("      (footprint \"footprints:{s}\")\n", .{kicad_fp});
        // Sheetpath + tstamp for KiCad PCB ↔ netlist matching.
        // KiCad constructs: FindFootprintByPath(sheetpath_tstamps / component_tstamp)
        try w.writeAll("      (sheetpath (names /) (tstamps /))\n");
        if (inst.uuid.len > 0) {
            try w.print("      (tstamp {s})\n", .{inst.uuid});
        }
        // Properties
        for (inst.properties) |prop| {
            try w.print("      (property (name \"{s}\") (value \"{s}\"))\n", .{ prop.key, prop.value });
        }
        try w.writeAll("    )\n");
    }
    try w.writeAll("  )\n");

    // Build set of connected pins per component: "REF\x00PIN" -> true
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const tmp = arena.allocator();
    var connected_pins = std.StringHashMap(void).init(tmp);
    for (nets) |net| {
        for (net.pins) |pin| {
            const key = try std.fmt.allocPrint(tmp, "{s}\x00{s}", .{ pin.ref_des, pin.pin });
            try connected_pins.put(key, {});
        }
    }

    // Nets
    try w.writeAll("  (nets\n");
    // Unconnected net with NC pad nodes
    try w.writeAll("    (net (code \"0\") (name \"\")\n");
    for (instances) |inst| {
        const pads = fp_pad_map.get(inst.footprint) orelse continue;
        for (pads) |pad_name| {
            const key = try std.fmt.allocPrint(tmp, "{s}\x00{s}", .{ inst.ref_des, pad_name });
            if (!connected_pins.contains(key)) {
                try w.print("      (node (ref \"{s}\") (pin \"{s}\"))\n", .{ inst.ref_des, pad_name });
            }
        }
    }
    try w.writeAll("    )\n");
    for (nets, 0..) |net, i| {
        if (net.pins.len == 0) continue;
        try w.print("    (net (code \"{d}\") (name \"{s}\")\n", .{ i + 1, net.name });
        for (net.pins) |pin| {
            try w.print("      (node (ref \"{s}\") (pin \"{s}\"))\n", .{ pin.ref_des, pin.pin });
        }
        try w.writeAll("    )\n");
    }
    try w.writeAll("  )\n");

    try w.writeAll(")\n");
    return buf.toOwnedSlice(allocator);
}

// --- Footprint pad extraction ---

/// Parse a `.sexp` footprint and return the ordered list of pad names. The
/// netlist writer uses this to surface pads that don't appear on any net,
/// so KiCad sees the full pad inventory even when the design leaves some NC.
pub fn extractPadNames(allocator: std.mem.Allocator, source: []const u8) NetlistError![]const []const u8 {
    const nodes = try parser_mod.parse(allocator, source);
    defer parser_mod.freeNodes(allocator, nodes);

    if (nodes.len == 0) return error.InvalidFormat;
    const root = nodes[0];
    if (!root.isForm("footprint")) return error.InvalidFormat;
    const children = root.asList() orelse return error.InvalidFormat;

    var pads: std.ArrayListUnmanaged([]const u8) = .empty;
    for (children[2..]) |child| {
        if (child.isForm("pad")) {
            const cl = child.asList() orelse continue;
            if (cl.len < 2) continue;
            const name = cl[1].asAtom() orelse cl[1].asString() orelse continue;
            try pads.append(allocator, try allocator.dupe(u8, name));
        }
    }
    return pads.toOwnedSlice(allocator);
}

// --- Footprint name extraction ---

/// Pull the declared footprint name out of a parsed `.sexp` source. The
/// netlist writer uses this to map the project's internal footprint id
/// (e.g. `r-0402`) to the KiCad library name (`R_0402_1005Metric`).
pub fn extractFootprintName(allocator: std.mem.Allocator, source: []const u8) NetlistError![]const u8 {
    const nodes = try parser_mod.parse(allocator, source);
    defer parser_mod.freeNodes(allocator, nodes);

    if (nodes.len == 0) return error.InvalidFormat;
    const root = nodes[0];
    if (!root.isForm("footprint")) return error.InvalidFormat;
    const children = root.asList() orelse return error.InvalidFormat;
    if (children.len < 2) return error.InvalidFormat;

    const name = children[1].asAtom() orelse children[1].asString() orelse return error.InvalidFormat;
    return try allocator.dupe(u8, name);
}

// --- Hierarchy flattening ---

/// Join `prefix` and `name` with a `/`, or duplicate `name` alone when there
/// is no prefix. The unit of hierarchy-path qualification for ref-des and net
/// names as the flattener descends into sub-blocks.
fn prefixed(allocator: std.mem.Allocator, prefix: []const u8, name: []const u8) std.mem.Allocator.Error![]const u8 {
    if (prefix.len == 0) return allocator.dupe(u8, name);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, name });
}

/// Walk the design tree and append a `FlatInstance` for every component,
/// joining `prefix` onto each ref-des as it descends into sub-blocks so
/// references stay unique. Each instance carries the BOM-assigned UUID
/// when available, falling back to a hash of the stable 8-char id.
pub fn collectInstances(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    prefix: []const u8,
    list: *std.ArrayListUnmanaged(FlatInstance),
    ref_style: env_mod.RefStyle,
) std.mem.Allocator.Error!void {
    for (block.instances) |inst| {
        // `(grouped-refdes)` makes ref-deses globally unique, so the sub-block
        // path prefix is redundant — emit the bare ref (`R1_1`, not `a/R1_1`).
        const ref = if (ref_style == .flat)
            try allocator.dupe(u8, inst.ref_des)
        else
            try prefixed(allocator, prefix, inst.ref_des);

        // Use BOM-assigned UUID if available, otherwise derive from ID
        const effective_uuid = if (inst.uuid.len > 0)
            inst.uuid
        else if (inst.id.len > 0)
            (export_kicad.uuidFromId(allocator, inst.id) catch "")
        else
            "";

        try list.append(allocator, .{
            .ref_des = ref,
            .component = inst.component,
            .symbol = inst.symbol,
            .pinout = inst.pinout,
            .origin_key = inst.origin_key,
            .value = inst.value,
            .footprint = inst.footprint,
            .properties = inst.properties,
            .uuid = effective_uuid,
        });
    }
    for (block.sub_blocks) |sb| {
        const sub_prefix = try prefixed(allocator, prefix, sb.name);
        try collectInstances(allocator, sb.block, sub_prefix, list, ref_style);
    }
}

/// Recurse through the design tree and append a `FlatNet` per net, prefixing
/// both the net name and each pin's ref-des with `prefix` so sub-block-local
/// nets stay distinct before `applyNetTies` merges them onto the canonical
/// top-level name.
pub fn collectNets(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    prefix: []const u8,
    list: *std.ArrayListUnmanaged(FlatNet),
    ref_style: env_mod.RefStyle,
) std.mem.Allocator.Error!void {
    for (block.nets) |net| {
        // Net names stay prefixed even under grouped-refdes: sub-block-local
        // nets can share a name and must stay distinct. Only the ref-des part
        // of each pin goes bare (it is already globally unique when grouped).
        const net_name = try prefixed(allocator, prefix, net.name);

        var pins = try allocator.alloc(FlatPin, net.pins.len);
        for (net.pins, 0..) |pin, i| {
            pins[i] = .{
                .ref_des = if (ref_style == .flat)
                    try allocator.dupe(u8, pin.ref_des)
                else
                    try prefixed(allocator, prefix, pin.ref_des),
                .pin = pin.pin,
            };
        }

        try list.append(allocator, .{
            .name = net_name,
            .pins = pins,
        });
    }
    for (block.sub_blocks) |sb| {
        const sub_prefix = try prefixed(allocator, prefix, sb.name);
        try collectNets(allocator, sb.block, sub_prefix, list, ref_style);
    }
}

/// One side-to-side net-tie collected from the design hierarchy: `a` and
/// `b` are net names (already prefixed by sub-block path) that
/// `applyNetTies` should treat as the same electrical net when merging
/// the flat netlist.
pub const FlatTie = struct {
    a: []const u8,
    b: []const u8,
};

/// Gather (net "A" "B" ...) ties from the block tree, prefixing each side with
/// the sub-block path so they can be matched against names in the flat net
/// list produced by `collectNets`.
pub fn collectNetTies(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    prefix: []const u8,
    list: *std.ArrayListUnmanaged(FlatTie),
) std.mem.Allocator.Error!void {
    for (block.net_ties) |t| {
        const a = try prefixed(allocator, prefix, t.a);
        const b = try prefixed(allocator, prefix, t.b);
        try list.append(allocator, .{ .a = a, .b = b });
    }
    for (block.sub_blocks) |sb| {
        const sub_prefix = try prefixed(allocator, prefix, sb.name);
        try collectNetTies(allocator, sb.block, sub_prefix, list);
    }
}

/// Prefer topmost (fewest slashes), then shortest, then lexicographic.
fn preferName(candidate: []const u8, incumbent: []const u8) bool {
    const cs = std.mem.count(u8, candidate, "/");
    const is_ = std.mem.count(u8, incumbent, "/");
    if (cs != is_) return cs < is_;
    if (candidate.len != incumbent.len) return candidate.len < incumbent.len;
    return std.mem.lessThan(u8, candidate, incumbent);
}

/// Merge nets in `nets` according to `ties`. A tie `(a, b)` means the two net
/// names refer to the same electrical net. Per-pin split nets of the form
/// `<base>.<ref>.<pin>` get renamed alongside their base when the base is
/// merged, so `buck/VIN.U12.VIN_1` follows `buck/VIN` → `VBATT` to become
/// `VBATT.U12.VIN_1` (still a separate micro-net for decoupling, but rooted on
/// the right parent name).
pub fn applyNetTies(
    allocator: std.mem.Allocator,
    nets: *std.ArrayListUnmanaged(FlatNet),
    ties: []const FlatTie,
) std.mem.Allocator.Error!void {
    if (ties.len == 0 and nets.items.len == 0) return;

    var name_to_idx: std.StringHashMapUnmanaged(u32) = .empty;
    defer name_to_idx.deinit(allocator);
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer names.deinit(allocator);
    var parent: std.ArrayListUnmanaged(u32) = .empty;
    defer parent.deinit(allocator);

    const getOrAdd = struct {
        fn f(
            al: std.mem.Allocator,
            n: []const u8,
            idx_map: *std.StringHashMapUnmanaged(u32),
            all_names: *std.ArrayListUnmanaged([]const u8),
            par: *std.ArrayListUnmanaged(u32),
        ) !u32 {
            const gop = try idx_map.getOrPut(al, n);
            if (gop.found_existing) return gop.value_ptr.*;
            const i: u32 = @intCast(all_names.items.len);
            try all_names.append(al, n);
            try par.append(al, i);
            gop.value_ptr.* = i;
            return i;
        }
    }.f;

    const find = struct {
        fn f(par: *std.ArrayListUnmanaged(u32), idx: u32) u32 {
            var i = idx;
            while (par.items[i] != i) : (i = par.items[i]) {}
            var j = idx;
            while (par.items[j] != i) {
                const next = par.items[j];
                par.items[j] = i;
                j = next;
            }
            return i;
        }
    }.f;

    // A name is "live" (eligible to be the canonical net name) if either it
    // has pins, or it's on the LHS of a tie — i.e., the user wrote it as the
    // preferred name in a `(net "LHS" "rhs" ...)` form. Without this, a tie
    // LHS like `PG_3V3` (all its pins come in through other nets) would be
    // dropped from canonical selection and a sub-block-prefixed RHS would
    // win. RHS names aren't marked live because auto-aliases created by
    // symbol pin-function lookup can produce junk names like "1" or "5"
    // that would otherwise hijack shorter-wins preference.
    var live_names: std.StringHashMapUnmanaged(void) = .empty;
    defer live_names.deinit(allocator);
    for (nets.items) |net| {
        _ = try getOrAdd(allocator, net.name, &name_to_idx, &names, &parent);
        try live_names.put(allocator, net.name, {});
    }
    for (ties) |t| {
        const ai = try getOrAdd(allocator, t.a, &name_to_idx, &names, &parent);
        const bi = try getOrAdd(allocator, t.b, &name_to_idx, &names, &parent);
        try live_names.put(allocator, t.a, {});
        const ra = find(&parent, ai);
        const rb = find(&parent, bi);
        if (ra != rb) parent.items[rb] = ra;
    }

    // Canonical name per root — only among names that actually have pins.
    var canonical: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer canonical.deinit(allocator);
    for (names.items, 0..) |nm, i| {
        if (!live_names.contains(nm)) continue;
        const root = find(&parent, @intCast(i));
        const existing = canonical.get(root);
        if (existing) |best_i| {
            if (preferName(nm, names.items[best_i])) {
                try canonical.put(allocator, root, @intCast(i));
            }
        } else {
            try canonical.put(allocator, root, @intCast(i));
        }
    }

    // old_name → canonical_name (only when they differ). If a root has no
    // live name (all tie-only), skip — nothing to rename.
    var rename_map: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer rename_map.deinit(allocator);
    for (names.items, 0..) |nm, i| {
        const root = find(&parent, @intCast(i));
        const canon_i = canonical.get(root) orelse continue;
        const canon_name = names.items[canon_i];
        if (!std.mem.eql(u8, nm, canon_name)) {
            try rename_map.put(allocator, nm, canon_name);
        }
    }

    // Rename per-pin split nets: <base>.<ref>.<pin> inherits base's new name.
    var per_pin_renames: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer per_pin_renames.deinit(allocator);
    for (nets.items) |net| {
        const dot = std.mem.indexOfScalar(u8, net.name, '.') orelse continue;
        const base = net.name[0..dot];
        const suffix = net.name[dot..];
        const canon_base = rename_map.get(base) orelse continue;
        const new_name = try std.fmt.allocPrint(allocator, "{s}{s}", .{ canon_base, suffix });
        try per_pin_renames.put(allocator, net.name, new_name);
    }

    // Rebuild nets list, merging pins by canonical name.
    var merged: std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged(FlatPin)) = .empty;
    defer {
        var it = merged.iterator();
        while (it.next()) |e| e.value_ptr.deinit(allocator);
        merged.deinit(allocator);
    }

    for (nets.items) |net| {
        const canon = if (per_pin_renames.get(net.name)) |pn|
            pn
        else if (rename_map.get(net.name)) |rn|
            rn
        else
            net.name;
        const gop = try merged.getOrPut(allocator, canon);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        for (net.pins) |p| try gop.value_ptr.append(allocator, p);
    }

    nets.clearRetainingCapacity();
    var mit = merged.iterator();
    while (mit.next()) |entry| {
        try nets.append(allocator, .{
            .name = entry.key_ptr.*,
            .pins = try entry.value_ptr.toOwnedSlice(allocator),
        });
    }
}
