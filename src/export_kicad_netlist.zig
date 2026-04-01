const std = @import("std");
const parser_mod = @import("sexpr/parser.zig");
const env_mod = @import("eval/env.zig");
const DesignBlock = env_mod.DesignBlock;

const export_kicad = @import("export_kicad.zig");
const FlatInstance = export_kicad.FlatInstance;
const FlatNet = export_kicad.FlatNet;
const FlatPin = export_kicad.FlatPin;
const Property = env_mod.Property;

// --- Netlist writer ---

pub fn writeNetlist(
    allocator: std.mem.Allocator,
    design_name: []const u8,
    instances: []const FlatInstance,
    nets: []const FlatNet,
    fp_name_map: *const std.StringHashMap([]const u8),
    fp_pad_map: *const std.StringHashMap([]const []const u8),
) ![]const u8 {
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

pub fn extractPadNames(allocator: std.mem.Allocator, source: []const u8) ![]const []const u8 {
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

pub fn extractFootprintName(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
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

pub fn collectInstances(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    prefix: []const u8,
    list: *std.ArrayListUnmanaged(FlatInstance),
) !void {
    for (block.instances) |inst| {
        const ref = if (prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, inst.ref_des })
        else
            try allocator.dupe(u8, inst.ref_des);

        // Derive UUID from 8-char ID if available, fall back to existing uuid
        const effective_uuid = if (inst.id.len > 0)
            (export_kicad.uuidFromId(allocator, inst.id) catch inst.uuid)
        else
            inst.uuid;

        try list.append(allocator, .{
            .ref_des = ref,
            .component = inst.component,
            .value = inst.value,
            .footprint = inst.footprint,
            .properties = inst.properties,
            .uuid = effective_uuid,
        });
    }
    for (block.sub_blocks) |sb| {
        const sub_prefix = if (prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, sb.name })
        else
            try allocator.dupe(u8, sb.name);
        try collectInstances(allocator, sb.block, sub_prefix, list);
    }
}

pub fn collectNets(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    prefix: []const u8,
    list: *std.ArrayListUnmanaged(FlatNet),
) !void {
    for (block.nets) |net| {
        const net_name = if (prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, net.name })
        else
            try allocator.dupe(u8, net.name);

        var pins = try allocator.alloc(FlatPin, net.pins.len);
        for (net.pins, 0..) |pin, i| {
            pins[i] = .{
                .ref_des = if (prefix.len > 0)
                    try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, pin.ref_des })
                else
                    try allocator.dupe(u8, pin.ref_des),
                .pin = pin.pin,
            };
        }

        try list.append(allocator, .{
            .name = net_name,
            .pins = pins,
        });
    }
    for (block.sub_blocks) |sb| {
        const sub_prefix = if (prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, sb.name })
        else
            try allocator.dupe(u8, sb.name);
        try collectNets(allocator, sb.block, sub_prefix, list);
    }
}
