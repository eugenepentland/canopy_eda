const std = @import("std");
const env_mod = @import("eval/env.zig");
const parser_mod = @import("sexpr/parser.zig");
const DesignBlock = env_mod.DesignBlock;
const Instance = env_mod.Instance;
const Net = env_mod.Net;
const Property = env_mod.Property;

const netlist_mod = @import("export_kicad_netlist.zig");
const footprint_mod = @import("export_kicad_footprint.zig");

const writeNetlist = netlist_mod.writeNetlist;
const extractPadNames = netlist_mod.extractPadNames;
const extractFootprintName = netlist_mod.extractFootprintName;
const exportFootprintMod = footprint_mod.exportFootprintMod;
const findModelFile = footprint_mod.findModelFile;
const buildZip = footprint_mod.buildZip;
const ZipEntry = footprint_mod.ZipEntry;

/// Derive a full UUID (36-char) from an 8-char hex ID by hashing it.
pub fn uuidFromId(allocator: std.mem.Allocator, id: []const u8) ![]const u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("canopy:");
    hasher.update(id);
    const hash = hasher.finalResult();
    // Format as UUID v5 style: xxxxxxxx-xxxx-5xxx-yxxx-xxxxxxxxxxxx
    var bytes: [16]u8 = undefined;
    @memcpy(&bytes, hash[0..16]);
    bytes[6] = (bytes[6] & 0x0f) | 0x50; // version 5
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 1
    return std.fmt.allocPrint(allocator, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
        bytes[0],  bytes[1],  bytes[2],  bytes[3],
        bytes[4],  bytes[5],  bytes[6],  bytes[7],
        bytes[8],  bytes[9],  bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15],
    });
}

pub const FlatInstance = struct {
    ref_des: []const u8,
    component: []const u8,
    value: []const u8,
    footprint: []const u8,
    properties: []const Property,
    uuid: []const u8,
};

pub const FlatNet = struct {
    name: []const u8,
    pins: []const FlatPin,
};

pub const FlatPin = struct {
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

/// Export section layout as JSON for PCB placement.
/// Maps each instance ref_des to its section grid cell.
pub fn exportSectionLayout(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
) ![]const u8 {
    // Flatten sections + sub-sections into a flat list
    var flat_sections: std.ArrayListUnmanaged(struct { name: []const u8, instances: []const Instance, pin_groups: []const env_mod.PinGroup }) = .empty;
    defer flat_sections.deinit(allocator);

    for (block.sections) |sec| {
        // If section has sub-sections, its instances belong to those — skip parent's instances
        if (sec.sub_sections.len > 0) {
            try flat_sections.append(allocator, .{ .name = sec.name, .instances = &.{}, .pin_groups = sec.pin_groups });
        } else {
            try flat_sections.append(allocator, .{ .name = sec.name, .instances = sec.instances, .pin_groups = sec.pin_groups });
        }
        for (sec.sub_sections) |sub| {
            try flat_sections.append(allocator, .{ .name = sub.name, .instances = sub.instances, .pin_groups = sub.pin_groups });
        }
    }

    const n = flat_sections.items.len;
    if (n == 0) return try allocator.dupe(u8, "{\"cell_size_mm\":50,\"sections\":[],\"ref_section\":{}}");

    // Grid dimensions
    var n_cols: usize = 1;
    while (n_cols * n_cols < n) : (n_cols += 1) {}

    // Build ref_des -> section index map
    var ref_map = std.StringHashMap(usize).init(allocator);
    defer ref_map.deinit();

    for (flat_sections.items, 0..) |sec, si| {
        for (sec.instances) |inst| {
            try ref_map.put(inst.ref_des, si);
        }
        // Also capture instances referenced via pin_groups
        for (sec.pin_groups) |pg| {
            if (!ref_map.contains(pg.ref_des)) {
                try ref_map.put(pg.ref_des, si);
            }
        }
    }

    // Write JSON
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeAll("{\"cell_size_mm\":50,\"sections\":[");
    for (flat_sections.items, 0..) |sec, si| {
        if (si > 0) try w.writeAll(",");
        const row = si / n_cols;
        const col = si % n_cols;
        try w.print("{{\"name\":\"{s}\",\"row\":{d},\"col\":{d},\"refs\":[", .{ sec.name, row, col });
        var first = true;
        for (sec.instances) |inst| {
            if (!first) try w.writeAll(",");
            try w.print("\"{s}\"", .{inst.ref_des});
            first = false;
        }
        for (sec.pin_groups) |pg| {
            // Only add if not already listed as a direct instance
            var found = false;
            for (sec.instances) |inst| {
                if (std.mem.eql(u8, inst.ref_des, pg.ref_des)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                if (!first) try w.writeAll(",");
                try w.print("\"{s}\"", .{pg.ref_des});
                first = false;
            }
        }
        try w.writeAll("]}");
    }

    try w.writeAll("],\"ref_section\":{");
    var ref_first = true;
    var ref_iter = ref_map.iterator();
    while (ref_iter.next()) |entry| {
        if (!ref_first) try w.writeAll(",");
        try w.print("\"{s}\":{d}", .{ entry.key_ptr.*, entry.value_ptr.* });
        ref_first = false;
    }
    try w.writeAll("}}");

    return try allocator.dupe(u8, buf.items);
}

const collectInstances = netlist_mod.collectInstances;
const collectNets = netlist_mod.collectNets;

const ConvertError = error{
    InvalidFormat,
    OutOfMemory,
    UnexpectedEof,
    UnexpectedRparen,
    UnexpectedCharacter,
    UnterminatedString,
    InvalidNumber,
};

// spec: export_kicad - Generates a KiCad netlist from a resolved design
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

// spec: export_kicad - Exports a KiCad footprint mod file from footprint data
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
