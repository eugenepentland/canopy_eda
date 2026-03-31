const std = @import("std");
const env_mod = @import("eval/env.zig");
const parser_mod = @import("sexpr/parser.zig");
const DesignBlock = env_mod.DesignBlock;
const Instance = env_mod.Instance;
const Net = env_mod.Net;
const Property = env_mod.Property;

const FlatInstance = struct {
    ref_des: []const u8,
    component: []const u8,
    value: []const u8,
    footprint: []const u8,
    properties: []const Property,
    uuid: []const u8,
};

const FlatNet = struct {
    name: []const u8,
    pins: []const FlatPin,
};

const FlatPin = struct {
    ref_des: []const u8,
    pin: []const u8,
};

/// Export a resolved design to KiCad format: netlist + footprints + STEP models.
pub fn exportKicad(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    project_dir: []const u8,
    output_dir: []const u8,
    design_name: []const u8,
) !void {
    // Create output directories
    const fp_dir = try std.fmt.allocPrint(allocator, "{s}/footprints.pretty", .{output_dir});
    defer allocator.free(fp_dir);
    const model_dir = try std.fmt.allocPrint(allocator, "{s}/models", .{output_dir});
    defer allocator.free(model_dir);

    std.fs.cwd().makePath(output_dir) catch |err| {
        std.debug.print("Failed to create output dir {s}: {}\n", .{ output_dir, err });
        return err;
    };
    std.fs.cwd().makePath(fp_dir) catch |err| {
        std.debug.print("Failed to create footprints dir: {}\n", .{err});
        return err;
    };
    std.fs.cwd().makePath(model_dir) catch |err| {
        std.debug.print("Failed to create models dir: {}\n", .{err});
        return err;
    };

    // Flatten hierarchy
    var instances: std.ArrayListUnmanaged(FlatInstance) = .empty;
    defer instances.deinit(allocator);
    var nets: std.ArrayListUnmanaged(FlatNet) = .empty;
    defer nets.deinit(allocator);

    try collectInstances(allocator, block, "", &instances);
    try collectNets(allocator, block, "", &nets);

    // Build footprint name map: internal name -> KiCad declared name
    // Also track which footprints we've already processed
    var fp_name_map = std.StringHashMap([]const u8).init(allocator);
    defer fp_name_map.deinit();
    var processed_fps = std.StringHashMap(void).init(allocator);
    defer processed_fps.deinit();

    // Collect unique footprint names and their associated component names
    var fp_components = std.StringHashMap([]const u8).init(allocator);
    defer fp_components.deinit();

    for (instances.items) |inst| {
        if (inst.footprint.len == 0) continue;
        if (processed_fps.contains(inst.footprint)) continue;
        try processed_fps.put(inst.footprint, {});
        try fp_components.put(inst.footprint, inst.component);

        // Load and parse footprint .sexp to get declared name
        const fp_path = try std.fmt.allocPrint(allocator, "{s}/lib/footprints/{s}.sexp", .{ project_dir, inst.footprint });
        defer allocator.free(fp_path);

        const fp_source = std.fs.cwd().readFileAlloc(allocator, fp_path, 1024 * 1024) catch |err| {
            std.debug.print("Warning: cannot read footprint {s}: {}\n", .{ fp_path, err });
            try fp_name_map.put(inst.footprint, inst.footprint);
            continue;
        };
        defer allocator.free(fp_source);

        const kicad_name = extractFootprintName(allocator, fp_source) catch inst.footprint;
        try fp_name_map.put(inst.footprint, kicad_name);

        // Check for matching STEP model
        const model_name = findModelFile(allocator, project_dir, inst.footprint, inst.component);

        // Write .kicad_mod file
        const mod_output = exportFootprintMod(allocator, fp_source, model_name) catch |err| {
            std.debug.print("Warning: failed to convert footprint {s}: {}\n", .{ inst.footprint, err });
            continue;
        };
        defer allocator.free(mod_output);

        const mod_path = try std.fmt.allocPrint(allocator, "{s}/{s}.kicad_mod", .{ fp_dir, kicad_name });
        defer allocator.free(mod_path);

        const f = try std.fs.cwd().createFile(mod_path, .{});
        defer f.close();
        try f.writeAll(mod_output);
        std.debug.print("  Wrote {s}\n", .{mod_path});

        // Copy STEP model if found
        if (model_name) |mname| {
            defer allocator.free(mname);
            const src_path = try std.fmt.allocPrint(allocator, "{s}/lib/models/{s}", .{ project_dir, mname });
            defer allocator.free(src_path);
            const dst_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ model_dir, mname });
            defer allocator.free(dst_path);

            std.fs.cwd().copyFile(src_path, std.fs.cwd(), dst_path, .{}) catch |err| {
                std.debug.print("Warning: failed to copy model {s}: {}\n", .{ mname, err });
            };
            std.debug.print("  Copied model {s}\n", .{mname});
        }
    }

    // Write netlist
    const net_path = try std.fmt.allocPrint(allocator, "{s}/{s}.net", .{ output_dir, design_name });
    defer allocator.free(net_path);

    // Build footprint pad map for NC pin handling
    var fp_pad_map = std.StringHashMap([]const []const u8).init(allocator);
    defer fp_pad_map.deinit();
    for (instances.items) |inst| {
        if (inst.footprint.len == 0) continue;
        if (fp_pad_map.contains(inst.footprint)) continue;
        const fp_path2 = try std.fmt.allocPrint(allocator, "{s}/lib/footprints/{s}.sexp", .{ project_dir, inst.footprint });
        defer allocator.free(fp_path2);
        const fp_src = std.fs.cwd().readFileAlloc(allocator, fp_path2, 1024 * 1024) catch continue;
        defer allocator.free(fp_src);
        const pad_names = extractPadNames(allocator, fp_src) catch continue;
        try fp_pad_map.put(inst.footprint, pad_names);
    }

    const netlist = try writeNetlist(allocator, design_name, instances.items, nets.items, &fp_name_map, &fp_pad_map);
    defer allocator.free(netlist);

    const nf = try std.fs.cwd().createFile(net_path, .{});
    defer nf.close();
    try nf.writeAll(netlist);
    std.debug.print("  Wrote {s}\n", .{net_path});
}

/// Export a resolved design as an in-memory zip file containing netlist + footprints + models.
/// Export just the KiCad netlist as a string.
pub fn exportNetlistOnly(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    project_dir: []const u8,
    design_name: []const u8,
) ![]const u8 {
    var instances: std.ArrayListUnmanaged(FlatInstance) = .empty;
    defer instances.deinit(allocator);
    var nets: std.ArrayListUnmanaged(FlatNet) = .empty;
    defer nets.deinit(allocator);

    try collectInstances(allocator, block, "", &instances);
    try collectNets(allocator, block, "", &nets);

    var fp_name_map = std.StringHashMap([]const u8).init(allocator);
    defer fp_name_map.deinit();
    var processed_fps = std.StringHashMap(void).init(allocator);
    defer processed_fps.deinit();

    for (instances.items) |inst| {
        if (inst.footprint.len == 0) continue;
        if (processed_fps.contains(inst.footprint)) continue;
        try processed_fps.put(inst.footprint, {});

        const fp_path = try std.fmt.allocPrint(allocator, "{s}/lib/footprints/{s}.sexp", .{ project_dir, inst.footprint });
        defer allocator.free(fp_path);

        const fp_source = std.fs.cwd().readFileAlloc(allocator, fp_path, 1024 * 1024) catch {
            try fp_name_map.put(inst.footprint, inst.footprint);
            continue;
        };
        defer allocator.free(fp_source);

        const kicad_name = extractFootprintName(allocator, fp_source) catch inst.footprint;
        try fp_name_map.put(inst.footprint, kicad_name);
    }

    // Build footprint pad map for NC pin handling
    var fp_pad_map = std.StringHashMap([]const []const u8).init(allocator);
    defer fp_pad_map.deinit();
    for (instances.items) |inst| {
        if (inst.footprint.len == 0) continue;
        if (fp_pad_map.contains(inst.footprint)) continue;
        const fp_path = try std.fmt.allocPrint(allocator, "{s}/lib/footprints/{s}.sexp", .{ project_dir, inst.footprint });
        defer allocator.free(fp_path);
        const fp_src = std.fs.cwd().readFileAlloc(allocator, fp_path, 1024 * 1024) catch continue;
        defer allocator.free(fp_src);
        const pad_names = extractPadNames(allocator, fp_src) catch continue;
        try fp_pad_map.put(inst.footprint, pad_names);
    }

    return writeNetlist(allocator, design_name, instances.items, nets.items, &fp_name_map, &fp_pad_map);
}

pub fn exportKicadZip(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    project_dir: []const u8,
    design_name: []const u8,
) ![]const u8 {
    var instances: std.ArrayListUnmanaged(FlatInstance) = .empty;
    defer instances.deinit(allocator);
    var nets: std.ArrayListUnmanaged(FlatNet) = .empty;
    defer nets.deinit(allocator);

    try collectInstances(allocator, block, "", &instances);
    try collectNets(allocator, block, "", &nets);

    var fp_name_map = std.StringHashMap([]const u8).init(allocator);
    defer fp_name_map.deinit();
    var processed_fps = std.StringHashMap(void).init(allocator);
    defer processed_fps.deinit();

    // Collect zip entries
    var zip_files: std.ArrayListUnmanaged(ZipEntry) = .empty;
    defer zip_files.deinit(allocator);

    for (instances.items) |inst| {
        if (inst.footprint.len == 0) continue;
        if (processed_fps.contains(inst.footprint)) continue;
        try processed_fps.put(inst.footprint, {});

        const fp_path = try std.fmt.allocPrint(allocator, "{s}/lib/footprints/{s}.sexp", .{ project_dir, inst.footprint });
        defer allocator.free(fp_path);

        const fp_source = std.fs.cwd().readFileAlloc(allocator, fp_path, 1024 * 1024) catch {
            try fp_name_map.put(inst.footprint, inst.footprint);
            continue;
        };
        defer allocator.free(fp_source);

        const kicad_name = extractFootprintName(allocator, fp_source) catch inst.footprint;
        try fp_name_map.put(inst.footprint, kicad_name);

        const model_name = findModelFile(allocator, project_dir, inst.footprint, inst.component);

        const mod_output = exportFootprintMod(allocator, fp_source, model_name) catch continue;

        const mod_filename = try std.fmt.allocPrint(allocator, "footprints.pretty/{s}.kicad_mod", .{kicad_name});
        try zip_files.append(allocator, .{ .name = mod_filename, .data = mod_output });

        // Add STEP model
        if (model_name) |mname| {
            defer allocator.free(mname);
            const src_path = try std.fmt.allocPrint(allocator, "{s}/lib/models/{s}", .{ project_dir, mname });
            defer allocator.free(src_path);
            const model_data = std.fs.cwd().readFileAlloc(allocator, src_path, 20 * 1024 * 1024) catch continue;
            const model_filename = try std.fmt.allocPrint(allocator, "models/{s}", .{mname});
            try zip_files.append(allocator, .{ .name = model_filename, .data = model_data });
        }
    }

    // Build footprint pad map for NC pin handling
    var fp_pad_map = std.StringHashMap([]const []const u8).init(allocator);
    defer fp_pad_map.deinit();
    for (instances.items) |inst| {
        if (inst.footprint.len == 0) continue;
        if (fp_pad_map.contains(inst.footprint)) continue;
        const fp_path = try std.fmt.allocPrint(allocator, "{s}/lib/footprints/{s}.sexp", .{ project_dir, inst.footprint });
        defer allocator.free(fp_path);
        const fp_src = std.fs.cwd().readFileAlloc(allocator, fp_path, 1024 * 1024) catch continue;
        defer allocator.free(fp_src);
        const pad_names = extractPadNames(allocator, fp_src) catch continue;
        try fp_pad_map.put(inst.footprint, pad_names);
    }

    // Netlist
    const netlist = try writeNetlist(allocator, design_name, instances.items, nets.items, &fp_name_map, &fp_pad_map);
    const net_filename = try std.fmt.allocPrint(allocator, "{s}.net", .{design_name});
    try zip_files.append(allocator, .{ .name = net_filename, .data = netlist });

    // Build zip
    return buildZip(allocator, zip_files.items);
}

const ZipEntry = struct {
    name: []const u8,
    data: []const u8,
};

/// Build a ZIP file in memory using store (no compression).
fn buildZip(allocator: std.mem.Allocator, entries: []const ZipEntry) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    // Track offsets for central directory
    var offsets = try allocator.alloc(u32, entries.len);
    defer allocator.free(offsets);

    // Write local file headers + data
    for (entries, 0..) |entry, i| {
        offsets[i] = @intCast(buf.items.len);
        // Local file header
        try buf.appendSlice(allocator, &[_]u8{ 'P', 'K', 3, 4 }); // signature
        try appendU16(&buf, allocator, 20); // version needed
        try appendU16(&buf, allocator, 0); // flags
        try appendU16(&buf, allocator, 0); // compression: store
        try appendU16(&buf, allocator, 0); // mod time
        try appendU16(&buf, allocator, 0); // mod date
        try appendU32(&buf, allocator, crc32(entry.data)); // crc32
        try appendU32(&buf, allocator, @intCast(entry.data.len)); // compressed size
        try appendU32(&buf, allocator, @intCast(entry.data.len)); // uncompressed size
        try appendU16(&buf, allocator, @intCast(entry.name.len)); // filename len
        try appendU16(&buf, allocator, 0); // extra field len
        try buf.appendSlice(allocator, entry.name);
        try buf.appendSlice(allocator, entry.data);
    }

    // Central directory
    const cd_start: u32 = @intCast(buf.items.len);
    for (entries, 0..) |entry, i| {
        try buf.appendSlice(allocator, &[_]u8{ 'P', 'K', 1, 2 }); // signature
        try appendU16(&buf, allocator, 20); // version made by
        try appendU16(&buf, allocator, 20); // version needed
        try appendU16(&buf, allocator, 0); // flags
        try appendU16(&buf, allocator, 0); // compression: store
        try appendU16(&buf, allocator, 0); // mod time
        try appendU16(&buf, allocator, 0); // mod date
        try appendU32(&buf, allocator, crc32(entry.data)); // crc32
        try appendU32(&buf, allocator, @intCast(entry.data.len)); // compressed size
        try appendU32(&buf, allocator, @intCast(entry.data.len)); // uncompressed size
        try appendU16(&buf, allocator, @intCast(entry.name.len)); // filename len
        try appendU16(&buf, allocator, 0); // extra field len
        try appendU16(&buf, allocator, 0); // comment len
        try appendU16(&buf, allocator, 0); // disk number start
        try appendU16(&buf, allocator, 0); // internal attrs
        try appendU32(&buf, allocator, 0); // external attrs
        try appendU32(&buf, allocator, offsets[i]); // local header offset
        try buf.appendSlice(allocator, entry.name);
    }
    const cd_size: u32 = @intCast(buf.items.len - cd_start);

    // End of central directory
    try buf.appendSlice(allocator, &[_]u8{ 'P', 'K', 5, 6 }); // signature
    try appendU16(&buf, allocator, 0); // disk number
    try appendU16(&buf, allocator, 0); // disk with CD
    try appendU16(&buf, allocator, @intCast(entries.len)); // entries on disk
    try appendU16(&buf, allocator, @intCast(entries.len)); // total entries
    try appendU32(&buf, allocator, cd_size); // CD size
    try appendU32(&buf, allocator, cd_start); // CD offset
    try appendU16(&buf, allocator, 0); // comment len

    return buf.toOwnedSlice(allocator);
}

fn appendU16(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, val: u16) !void {
    try buf.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(u16, val)));
}

fn appendU32(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, val: u32) !void {
    try buf.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(u32, val)));
}

fn crc32(data: []const u8) u32 {
    var crc: u32 = 0xFFFFFFFF;
    for (data) |byte| {
        crc = crc ^ @as(u32, byte);
        for (0..8) |_| {
            const mask: u32 = if (crc & 1 != 0) 0xEDB88320 else 0;
            crc = (crc >> 1) ^ mask;
        }
    }
    return crc ^ 0xFFFFFFFF;
}

// --- Hierarchy flattening ---

fn collectInstances(
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

        try list.append(allocator, .{
            .ref_des = ref,
            .component = inst.component,
            .value = inst.value,
            .footprint = inst.footprint,
            .properties = inst.properties,
            .uuid = inst.uuid,
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

fn collectNets(
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

// --- Netlist writer ---

fn writeNetlist(
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

fn extractPadNames(allocator: std.mem.Allocator, source: []const u8) ![]const []const u8 {
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

fn extractFootprintName(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
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

// --- Footprint .sexp -> .kicad_mod ---

fn exportFootprintMod(allocator: std.mem.Allocator, source: []const u8, model_name: ?[]const u8) ![]const u8 {
    const nodes = try parser_mod.parse(allocator, source);
    defer parser_mod.freeNodes(allocator, nodes);

    if (nodes.len == 0) return error.InvalidFormat;
    const root = nodes[0];
    if (!root.isForm("footprint")) return error.InvalidFormat;
    const children = root.asList() orelse return error.InvalidFormat;
    if (children.len < 2) return error.InvalidFormat;

    const name = children[1].asAtom() orelse children[1].asString() orelse return error.InvalidFormat;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeAll("(footprint \"");
    try w.writeAll(name);
    try w.writeAll("\"\n");
    try w.writeAll("  (version 20240108)\n");
    try w.writeAll("  (generator \"canopy-eda\")\n");
    try w.writeAll("  (layer \"F.Cu\")\n");

    // Description
    for (children[2..]) |child| {
        if (child.isForm("description")) {
            const cl = child.asList().?;
            if (cl.len >= 2) {
                const desc = cl[1].asAtom() orelse cl[1].asString() orelse "";
                try w.print("  (descr \"{s}\")\n", .{desc});
            }
        }
    }

    // Pads
    for (children[2..]) |child| {
        if (child.isForm("pad")) {
            try emitKicadPad(w, child);
        }
    }

    // Courtyard
    for (children[2..]) |child| {
        if (child.isForm("courtyard")) {
            try emitKicadCourtyard(w, child);
        }
    }

    // Silkscreen
    for (children[2..]) |child| {
        if (child.isForm("silkscreen")) {
            try emitKicadSilkscreen(w, child);
        }
    }

    // 3D model reference
    if (model_name) |mname| {
        try w.writeAll("  (model \"${KIPRJMOD}/models/");
        try w.writeAll(mname);
        try w.writeAll("\"\n");
        try w.writeAll("    (offset (xyz 0 0 0))\n");
        try w.writeAll("    (scale (xyz 1 1 1))\n");
        try w.writeAll("    (rotate (xyz 0 0 0))\n");
        try w.writeAll("  )\n");
    }

    try w.writeAll(")\n");
    return buf.toOwnedSlice(allocator);
}

fn emitKicadPad(w: anytype, node: @import("sexpr/ast.zig").Node) !void {
    const children = node.asList() orelse return;
    if (children.len < 5) return;

    // (pad NAME TYPE SHAPE (pos X Y) (size W H))
    const pad_type_internal = children[2].asAtom() orelse return;
    const pad_shape_internal = children[3].asAtom() orelse return;

    // Reverse map types
    const kicad_type = reverseMapPadType(pad_type_internal);
    const kicad_shape = pad_shape_internal; // shapes are same names

    var x: f64 = 0;
    var y: f64 = 0;
    var sx: f64 = 0;
    var sy: f64 = 0;
    var drill_x: f64 = 0;
    var drill_y: f64 = 0;
    var has_drill = false;
    var is_oval_drill = false;

    for (children[4..]) |child| {
        if (child.isForm("pos")) {
            const cl = child.asList().?;
            if (cl.len >= 3) {
                x = cl[1].asNumber() orelse 0;
                y = cl[2].asNumber() orelse 0;
            }
        }
        if (child.isForm("size")) {
            const cl = child.asList().?;
            if (cl.len >= 3) {
                sx = cl[1].asNumber() orelse 0;
                sy = cl[2].asNumber() orelse 0;
            }
        }
        if (child.isForm("drill")) {
            const cl = child.asList().?;
            has_drill = true;
            if (cl.len >= 2) {
                if (cl[1].asAtom()) |a| {
                    if (std.mem.eql(u8, a, "oval") and cl.len >= 4) {
                        is_oval_drill = true;
                        drill_x = cl[2].asNumber() orelse 0;
                        drill_y = cl[3].asNumber() orelse 0;
                    }
                } else {
                    drill_x = cl[1].asNumber() orelse 0;
                    drill_y = drill_x;
                }
            }
        }
    }

    // Write pad name - handle atom, string, or numeric names
    if (children[1].asAtom() orelse children[1].asString()) |pn| {
        try w.print("  (pad \"{s}\" {s} {s}\n", .{ pn, kicad_type, kicad_shape });
    } else if (children[1].asNumber()) |num| {
        const inum: i64 = @intFromFloat(num);
        try w.print("  (pad \"{d}\" {s} {s}\n", .{ inum, kicad_type, kicad_shape });
    } else {
        return;
    }

    try w.print("    (at {d:.2} {d:.2})\n", .{ x, y });
    try w.print("    (size {d:.2} {d:.2})\n", .{ sx, sy });

    // Drill for through-hole pads
    if (std.mem.eql(u8, pad_type_internal, "thru") or std.mem.eql(u8, pad_type_internal, "npth")) {
        if (has_drill) {
            if (is_oval_drill) {
                try w.print("    (drill oval {d:.2} {d:.2})\n", .{ drill_x, drill_y });
            } else {
                try w.print("    (drill {d:.2})\n", .{drill_x});
            }
        } else {
            // Fallback: guess drill as min dimension
            const drill = @min(sx, sy);
            try w.print("    (drill {d:.2})\n", .{drill});
        }
    }

    // Layers
    if (std.mem.eql(u8, pad_type_internal, "smd")) {
        try w.writeAll("    (layers \"F.Cu\" \"F.Mask\" \"F.Paste\")\n");
        if (std.mem.eql(u8, kicad_shape, "roundrect")) {
            try w.writeAll("    (roundrect_rratio 0.25)\n");
        }
    } else if (std.mem.eql(u8, pad_type_internal, "thru")) {
        try w.writeAll("    (layers \"*.Cu\" \"*.Mask\")\n");
    } else if (std.mem.eql(u8, pad_type_internal, "npth")) {
        try w.writeAll("    (layers \"*.Cu\" \"*.Mask\")\n");
    }

    try w.writeAll("  )\n");
}

fn emitKicadCourtyard(w: anytype, node: @import("sexpr/ast.zig").Node) !void {
    const children = node.asList() orelse return;
    // (courtyard (rect X1 Y1 X2 Y2))
    for (children[1..]) |child| {
        if (child.isForm("rect")) {
            const cl = child.asList() orelse continue;
            if (cl.len >= 5) {
                const x1 = cl[1].asNumber() orelse 0;
                const y1 = cl[2].asNumber() orelse 0;
                const x2 = cl[3].asNumber() orelse 0;
                const y2 = cl[4].asNumber() orelse 0;
                try w.print("  (fp_rect (start {d:.2} {d:.2}) (end {d:.2} {d:.2})\n", .{ x1, y1, x2, y2 });
                try w.writeAll("    (stroke (width 0.05) (type default))\n");
                try w.writeAll("    (fill none)\n");
                try w.writeAll("    (layer \"F.CrtYd\")\n");
                try w.writeAll("  )\n");
            }
        }
    }
}

fn emitKicadSilkscreen(w: anytype, node: @import("sexpr/ast.zig").Node) !void {
    const children = node.asList() orelse return;
    for (children[1..]) |child| {
        if (child.isForm("line")) {
            const cl = child.asList() orelse continue;
            // (line (X1 Y1) (X2 Y2))
            if (cl.len >= 3) {
                const start = cl[1].asList() orelse continue;
                const end = cl[2].asList() orelse continue;
                if (start.len >= 2 and end.len >= 2) {
                    const sx = start[0].asNumber() orelse continue;
                    const sy = start[1].asNumber() orelse continue;
                    const ex = end[0].asNumber() orelse continue;
                    const ey = end[1].asNumber() orelse continue;
                    try w.print("  (fp_line (start {d:.2} {d:.2}) (end {d:.2} {d:.2})\n", .{ sx, sy, ex, ey });
                    try w.writeAll("    (stroke (width 0.12) (type default))\n");
                    try w.writeAll("    (layer \"F.SilkS\")\n");
                    try w.writeAll("  )\n");
                }
            }
        }
        if (child.isForm("circle")) {
            const cl = child.asList() orelse continue;
            // (circle (CX CY) R)
            if (cl.len >= 3) {
                const center = cl[1].asList() orelse continue;
                if (center.len >= 2) {
                    const cx = center[0].asNumber() orelse continue;
                    const cy = center[1].asNumber() orelse continue;
                    const r = cl[2].asNumber() orelse continue;
                    // KiCad uses center + end point
                    try w.print("  (fp_circle (center {d:.2} {d:.2}) (end {d:.2} {d:.2})\n", .{ cx, cy, cx + r, cy });
                    try w.writeAll("    (stroke (width 0.12) (type default))\n");
                    try w.writeAll("    (fill none)\n");
                    try w.writeAll("    (layer \"F.SilkS\")\n");
                    try w.writeAll("  )\n");
                }
            }
        }
    }
}

fn reverseMapPadType(internal: []const u8) []const u8 {
    if (std.mem.eql(u8, internal, "smd")) return "smd";
    if (std.mem.eql(u8, internal, "thru")) return "thru_hole";
    if (std.mem.eql(u8, internal, "npth")) return "np_thru_hole";
    return "smd";
}

// --- STEP model finder ---

fn findModelFile(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    footprint_name: []const u8,
    component_name: []const u8,
) ?[]const u8 {
    // Try exact footprint name match
    const fp_step = std.fmt.allocPrint(allocator, "{s}.step", .{footprint_name}) catch return null;
    defer allocator.free(fp_step);
    {
        const check_path = std.fmt.allocPrint(allocator, "{s}/lib/models/{s}", .{ project_dir, fp_step }) catch return null;
        defer allocator.free(check_path);
        if (std.fs.cwd().access(check_path, .{})) |_| {
            return allocator.dupe(u8, fp_step) catch null;
        } else |_| {}
    }

    // Try component name match
    const comp_step = std.fmt.allocPrint(allocator, "{s}.step", .{component_name}) catch return null;
    defer allocator.free(comp_step);
    {
        const check_path = std.fmt.allocPrint(allocator, "{s}/lib/models/{s}", .{ project_dir, comp_step }) catch return null;
        defer allocator.free(check_path);
        if (std.fs.cwd().access(check_path, .{})) |_| {
            return allocator.dupe(u8, comp_step) catch null;
        } else |_| {}
    }

    // Scan models directory for partial match
    const models_path = std.fmt.allocPrint(allocator, "{s}/lib/models", .{project_dir}) catch return null;
    defer allocator.free(models_path);

    var dir = std.fs.cwd().openDir(models_path, .{ .iterate = true }) catch return null;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".step")) continue;
        // Check if model filename contains the footprint or component name
        const basename = entry.name[0 .. entry.name.len - 5]; // strip .step
        if (std.mem.indexOf(u8, footprint_name, basename) != null or
            std.mem.indexOf(u8, basename, footprint_name) != null or
            std.mem.indexOf(u8, component_name, basename) != null or
            std.mem.indexOf(u8, basename, component_name) != null)
        {
            return allocator.dupe(u8, entry.name) catch null;
        }
    }

    return null;
}

const ConvertError = error{
    InvalidFormat,
    OutOfMemory,
    UnexpectedEof,
    UnexpectedRparen,
    UnexpectedCharacter,
    UnterminatedString,
    InvalidNumber,
};

test "netlist generation" {
    const alloc = std.testing.allocator;
    var fp_map = std.StringHashMap([]const u8).init(alloc);
    defer fp_map.deinit();
    try fp_map.put("r-0402", "R_0402_1005Metric");

    const instances = [_]FlatInstance{
        .{ .ref_des = "R1", .component = "res-0402", .value = "220k", .footprint = "r-0402", .properties = &.{}, .uuid = "" },
    };
    const pins = [_]FlatPin{
        .{ .ref_des = "R1", .pin = "1" },
        .{ .ref_des = "U1", .pin = "3" },
    };
    const nets_arr = [_]FlatNet{
        .{ .name = "VDD", .pins = &pins },
    };
    var fp_pad_map = std.StringHashMap([]const []const u8).init(alloc);
    defer fp_pad_map.deinit();
    const output = try writeNetlist(alloc, "test", &instances, &nets_arr, &fp_map, &fp_pad_map);
    defer alloc.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "(export (version \"E\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "(ref \"R1\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "footprints:R_0402_1005Metric") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "(name \"VDD\")") != null);
}

test "footprint mod export" {
    const alloc = std.testing.allocator;
    const source =
        \\(footprint "R_0402_1005Metric"
        \\  (description "Resistor SMD 0402")
        \\
        \\  (pad 1 smd roundrect (pos -0.51 0.00) (size 0.54 0.64))
        \\  (pad 2 smd roundrect (pos 0.51 0.00) (size 0.54 0.64))
        \\  (courtyard (rect -0.93 -0.47 0.93 0.47))
        \\  (silkscreen
        \\    (line (-0.15 -0.35) (0.15 -0.35))
        \\  )
        \\)
    ;

    const output = try exportFootprintMod(alloc, source, null);
    defer alloc.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "(footprint \"R_0402_1005Metric\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "thru_hole") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "(pad \"1\" smd roundrect") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "(layers \"F.Cu\" \"F.Mask\" \"F.Paste\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "fp_rect") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "fp_line") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "(layer \"F.SilkS\")") != null);
}
