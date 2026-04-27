const std = @import("std");
const infra_fs = @import("infra/fs.zig");
const log = @import("infra/log.zig");
const env_mod = @import("eval/env.zig");
const parser_mod = @import("sexpr/parser.zig");
const DesignBlock = env_mod.DesignBlock;
const Instance = env_mod.Instance;
const Net = env_mod.Net;
const Property = env_mod.Property;

const netlist_mod = @import("export_kicad_netlist.zig");
const footprint_mod = @import("export_kicad_footprint.zig");
const model_mod = @import("export_kicad_model.zig");
const modules_mod = @import("export_kicad_modules.zig");

pub const writeModulesJson = modules_mod.writeModulesJson;
pub const buildModulesJson = modules_mod.buildModulesJson;

const writeNetlist = netlist_mod.writeNetlist;
const extractPadNames = netlist_mod.extractPadNames;

// ── Constants ─────────────────────────────────────────────────────
const FOOTPRINT_PATH_TEMPLATE = "{s}/lib/footprints/{s}.sexp";
const MODEL_MAX_BYTES: usize = 20 * 1024 * 1024;
// UUID v5 byte indices (RFC 4122)
const UUID_VERSION_BYTE: usize = 6;
const UUID_VARIANT_BYTE: usize = 8;
const UUID_BYTE_5: usize = 5;
const UUID_BYTE_7: usize = 7;
const UUID_BYTE_9: usize = 9;
const UUID_BYTE_10: usize = 10;
const UUID_BYTE_11: usize = 11;
const UUID_BYTE_12: usize = 12;
const UUID_BYTE_13: usize = 13;
const UUID_BYTE_14: usize = 14;
const UUID_BYTE_15: usize = 15;
const extractFootprintName = netlist_mod.extractFootprintName;
const exportFootprintMod = footprint_mod.exportFootprintMod;
const findModelFile = footprint_mod.findModelFile;
const buildZip = footprint_mod.buildZip;
const ZipEntry = footprint_mod.ZipEntry;
const buildKicadMod = model_mod.buildKicadMod;
pub const loadModelConfig = model_mod.loadModelConfig;

pub const ModelTransform = model_mod.ModelTransform;
pub const ModelConfigMap = model_mod.ModelConfigMap;
pub const exportSectionLayout = model_mod.exportSectionLayout;
pub const exportFootprints = model_mod.exportFootprints;
pub const parseFloat3 = model_mod.parseFloat3;

/// Error set for the KiCad exporter. Wraps file IO (read & write multiple
/// `.kicad_*` files), parser errors on the source `.sexp`, and the writer
/// allocations done while building the output buffers.
pub const ExportError = std.mem.Allocator.Error ||
    std.fs.File.OpenError ||
    std.fs.File.ReadError ||
    std.fs.File.WriteError ||
    std.fs.Dir.MakeError ||
    parser_mod.ParseError ||
    error{ FileTooBig, StreamTooLong, EndOfStream, NotDir };

/// Derive a full UUID (36-char) from an 8-char hex ID by hashing it.
pub fn uuidFromId(allocator: std.mem.Allocator, id: []const u8) std.mem.Allocator.Error![]const u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("canopy:");
    hasher.update(id);
    const hash = hasher.finalResult();
    // Format as UUID v5 style: xxxxxxxx-xxxx-5xxx-yxxx-xxxxxxxxxxxx
    var bytes: [16]u8 = undefined;
    @memcpy(&bytes, hash[0..16]);
    bytes[UUID_VERSION_BYTE] = (bytes[UUID_VERSION_BYTE] & 0x0f) | 0x50; // version 5
    bytes[UUID_VARIANT_BYTE] = (bytes[UUID_VARIANT_BYTE] & 0x3f) | 0x80; // variant 1
    return std.fmt.allocPrint(allocator, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}" ++
        "-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
        bytes[0],                 bytes[1],            bytes[2],                 bytes[3],
        bytes[4],                 bytes[UUID_BYTE_5],  bytes[UUID_VERSION_BYTE], bytes[UUID_BYTE_7],
        bytes[UUID_VARIANT_BYTE], bytes[UUID_BYTE_9],  bytes[UUID_BYTE_10],      bytes[UUID_BYTE_11],
        bytes[UUID_BYTE_12],      bytes[UUID_BYTE_13], bytes[UUID_BYTE_14],      bytes[UUID_BYTE_15],
    });
}

/// One component flattened out of the design hierarchy for KiCad export:
/// the joined `sub-block/REF` reference designator plus the value,
/// footprint, properties, and stable UUID written into the `.net` file.
pub const FlatInstance = struct {
    ref_des: []const u8,
    component: []const u8,
    value: []const u8,
    footprint: []const u8,
    properties: []const Property,
    uuid: []const u8,
};

/// One net in the flattened design with a hierarchically-prefixed name and
/// the list of `FlatPin`s connected to it. Net ties from `applyNetTies`
/// merge multiple `FlatNet`s into one before the netlist is emitted.
pub const FlatNet = struct {
    name: []const u8,
    pins: []const FlatPin,
};

/// One `(node (ref …) (pin …))` entry in a KiCad netlist: the flattened
/// component reference designator and the physical pad name on the
/// component's footprint.
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
) ExportError!void {
    // Create output directories
    const fp_dir = try std.fmt.allocPrint(allocator, "{s}/footprints.pretty", .{output_dir});
    defer allocator.free(fp_dir);
    const model_dir = try std.fmt.allocPrint(allocator, "{s}/models", .{output_dir});
    defer allocator.free(model_dir);

    infra_fs.cwd().makePath(output_dir) catch |err| {
        log.warn("Failed to create output dir {s}: {}", .{ output_dir, err });
        return err;
    };
    infra_fs.cwd().makePath(fp_dir) catch |err| {
        log.warn("Failed to create footprints dir: {}", .{err});
        return err;
    };
    infra_fs.cwd().makePath(model_dir) catch |err| {
        log.warn("Failed to create models dir: {}", .{err});
        return err;
    };

    // Flatten hierarchy
    var instances: std.ArrayListUnmanaged(FlatInstance) = .empty;
    defer instances.deinit(allocator);
    var nets: std.ArrayListUnmanaged(FlatNet) = .empty;
    defer nets.deinit(allocator);

    try collectInstances(allocator, block, "", &instances);
    try flattenAndMergeNets(allocator, block, &nets);

    // Build footprint name map: internal name -> KiCad declared name
    // Also track which footprints we've already processed
    var fp_name_map = std.StringHashMap([]const u8).init(allocator);
    defer fp_name_map.deinit();
    var processed_fps = std.StringHashMap(void).init(allocator);
    defer processed_fps.deinit();

    // Collect unique footprint names and their associated component names
    var fp_components = std.StringHashMap([]const u8).init(allocator);
    defer fp_components.deinit();

    // Load 3D model config for offset/rotation
    var model_cfg = loadModelConfig(allocator, project_dir);
    defer model_cfg.deinit();

    for (instances.items) |inst| {
        if (inst.footprint.len == 0) continue;
        if (processed_fps.contains(inst.footprint)) continue;
        try processed_fps.put(inst.footprint, {});
        try fp_components.put(inst.footprint, inst.component);

        // Load and parse footprint .sexp to get declared name
        const fp_path = try std.fmt.allocPrint(allocator, FOOTPRINT_PATH_TEMPLATE, .{ project_dir, inst.footprint });
        defer allocator.free(fp_path);

        const fp_source = infra_fs.cwd().readFileAlloc(allocator, fp_path, 1024 * 1024) catch |err| {
            log.warn("cannot read footprint {s}: {}", .{ fp_path, err });
            try fp_name_map.put(inst.footprint, inst.footprint);
            continue;
        };
        defer allocator.free(fp_source);

        const kicad_name = extractFootprintName(allocator, fp_source) catch inst.footprint;
        try fp_name_map.put(inst.footprint, kicad_name);

        // Check for matching STEP model (config override > auto-discovery)
        const mcfg = model_cfg.get(inst.footprint);
        const model_name = if (mcfg) |c|
            (c.model orelse findModelFile(allocator, project_dir, inst.footprint, inst.component))
        else
            findModelFile(allocator, project_dir, inst.footprint, inst.component);

        // Write .kicad_mod file (prefer original source if available)
        const mod_output = buildKicadMod(
            allocator,
            project_dir,
            inst.footprint,
            fp_source,
            model_name,
            if (mcfg) |c| c.offset else null,
            if (mcfg) |c| c.rotation else null,
        ) catch |err| {
            log.warn("failed to convert footprint {s}: {}", .{ inst.footprint, err });
            continue;
        };
        defer allocator.free(mod_output);

        const mod_path = try std.fmt.allocPrint(allocator, "{s}/{s}.kicad_mod", .{ fp_dir, kicad_name });
        defer allocator.free(mod_path);

        const f = try infra_fs.cwd().createFile(mod_path, .{});
        defer f.close();
        try f.writeAll(mod_output);
        std.debug.print("  Wrote {s}\n", .{mod_path});

        // Copy STEP model if found
        if (model_name) |mname| {
            defer if (mcfg == null) allocator.free(mname);
            const src_path = try std.fmt.allocPrint(allocator, "{s}/lib/models/{s}", .{ project_dir, mname });
            defer allocator.free(src_path);
            const dst_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ model_dir, mname });
            defer allocator.free(dst_path);

            infra_fs.cwd().copyFile(src_path, infra_fs.cwd(), dst_path, .{}) catch |err| {
                log.warn("failed to copy model {s}: {}", .{ mname, err });
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
        const fp_path2 = try std.fmt.allocPrint(allocator, FOOTPRINT_PATH_TEMPLATE, .{ project_dir, inst.footprint });
        defer allocator.free(fp_path2);
        const fp_src = infra_fs.cwd().readFileAlloc(allocator, fp_path2, 1024 * 1024) catch continue;
        defer allocator.free(fp_src);
        const pad_names = extractPadNames(allocator, fp_src) catch continue;
        try fp_pad_map.put(inst.footprint, pad_names);
    }

    const netlist = try writeNetlist(allocator, design_name, instances.items, nets.items, &fp_name_map, &fp_pad_map);
    defer allocator.free(netlist);

    const nf = try infra_fs.cwd().createFile(net_path, .{});
    defer nf.close();
    try nf.writeAll(netlist);
    std.debug.print("  Wrote {s}\n", .{net_path});

    // Modules sidecar — consumed by pcb_update.py for one-shot layout replication.
    const modules_path = try std.fmt.allocPrint(allocator, "{s}/{s}.modules.json", .{ output_dir, design_name });
    defer allocator.free(modules_path);
    writeModulesJson(allocator, block, modules_path) catch |err| {
        log.warn("failed to write modules sidecar: {}", .{err});
    };
}

/// Export just the KiCad netlist as a string.
pub fn exportNetlistOnly(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    project_dir: []const u8,
    design_name: []const u8,
) ExportError![]const u8 {
    var instances: std.ArrayListUnmanaged(FlatInstance) = .empty;
    defer instances.deinit(allocator);
    var nets: std.ArrayListUnmanaged(FlatNet) = .empty;
    defer nets.deinit(allocator);

    try collectInstances(allocator, block, "", &instances);
    try flattenAndMergeNets(allocator, block, &nets);

    var fp_name_map = std.StringHashMap([]const u8).init(allocator);
    defer fp_name_map.deinit();
    var processed_fps = std.StringHashMap(void).init(allocator);
    defer processed_fps.deinit();

    for (instances.items) |inst| {
        if (inst.footprint.len == 0) continue;
        if (processed_fps.contains(inst.footprint)) continue;
        try processed_fps.put(inst.footprint, {});

        const fp_path = try std.fmt.allocPrint(allocator, FOOTPRINT_PATH_TEMPLATE, .{ project_dir, inst.footprint });
        defer allocator.free(fp_path);

        const fp_source = infra_fs.cwd().readFileAlloc(allocator, fp_path, 1024 * 1024) catch {
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
        const fp_path = try std.fmt.allocPrint(allocator, FOOTPRINT_PATH_TEMPLATE, .{ project_dir, inst.footprint });
        defer allocator.free(fp_path);
        const fp_src = infra_fs.cwd().readFileAlloc(allocator, fp_path, 1024 * 1024) catch continue;
        defer allocator.free(fp_src);
        const pad_names = extractPadNames(allocator, fp_src) catch continue;
        try fp_pad_map.put(inst.footprint, pad_names);
    }

    return writeNetlist(allocator, design_name, instances.items, nets.items, &fp_name_map, &fp_pad_map);
}

/// Like `exportKicad`, but returns the entire output bundle (netlist plus
/// every `.kicad_mod` and STEP model) as an in-memory zip — useful for
/// the web download endpoint that streams a single file to the browser.
pub fn exportKicadZip(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    project_dir: []const u8,
    design_name: []const u8,
) ExportError![]const u8 {
    var instances: std.ArrayListUnmanaged(FlatInstance) = .empty;
    defer instances.deinit(allocator);
    var nets: std.ArrayListUnmanaged(FlatNet) = .empty;
    defer nets.deinit(allocator);

    try collectInstances(allocator, block, "", &instances);
    try flattenAndMergeNets(allocator, block, &nets);

    var fp_name_map = std.StringHashMap([]const u8).init(allocator);
    defer fp_name_map.deinit();
    var processed_fps = std.StringHashMap(void).init(allocator);
    defer processed_fps.deinit();

    // Collect zip entries
    var zip_files: std.ArrayListUnmanaged(ZipEntry) = .empty;
    defer zip_files.deinit(allocator);

    var model_cfg = loadModelConfig(allocator, project_dir);
    defer model_cfg.deinit();

    for (instances.items) |inst| {
        if (inst.footprint.len == 0) continue;
        if (processed_fps.contains(inst.footprint)) continue;
        try processed_fps.put(inst.footprint, {});

        const fp_path = try std.fmt.allocPrint(allocator, FOOTPRINT_PATH_TEMPLATE, .{ project_dir, inst.footprint });
        defer allocator.free(fp_path);

        const fp_source = infra_fs.cwd().readFileAlloc(allocator, fp_path, 1024 * 1024) catch {
            try fp_name_map.put(inst.footprint, inst.footprint);
            continue;
        };
        defer allocator.free(fp_source);

        const kicad_name = extractFootprintName(allocator, fp_source) catch inst.footprint;
        try fp_name_map.put(inst.footprint, kicad_name);

        const mcfg = model_cfg.get(inst.footprint);
        const model_name = if (mcfg) |c|
            (c.model orelse findModelFile(allocator, project_dir, inst.footprint, inst.component))
        else
            findModelFile(allocator, project_dir, inst.footprint, inst.component);

        const mod_output = buildKicadMod(
            allocator,
            project_dir,
            inst.footprint,
            fp_source,
            model_name,
            if (mcfg) |c| c.offset else null,
            if (mcfg) |c| c.rotation else null,
        ) catch continue;

        const mod_filename = try std.fmt.allocPrint(allocator, "footprints.pretty/{s}.kicad_mod", .{kicad_name});
        try zip_files.append(allocator, .{ .name = mod_filename, .data = mod_output });

        // Add STEP model
        if (model_name) |mname| {
            defer if (mcfg == null) allocator.free(mname);
            const src_path = try std.fmt.allocPrint(allocator, "{s}/lib/models/{s}", .{ project_dir, mname });
            defer allocator.free(src_path);
            const model_data = infra_fs.cwd().readFileAlloc(allocator, src_path, MODEL_MAX_BYTES) catch continue;
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
        const fp_path = try std.fmt.allocPrint(allocator, FOOTPRINT_PATH_TEMPLATE, .{ project_dir, inst.footprint });
        defer allocator.free(fp_path);
        const fp_src = infra_fs.cwd().readFileAlloc(allocator, fp_path, 1024 * 1024) catch continue;
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

const collectInstances = netlist_mod.collectInstances;
const collectNets = netlist_mod.collectNets;
const collectNetTies = netlist_mod.collectNetTies;
const applyNetTies = netlist_mod.applyNetTies;
const FlatTie = netlist_mod.FlatTie;

fn flattenAndMergeNets(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    nets: *std.ArrayListUnmanaged(FlatNet),
) !void {
    try collectNets(allocator, block, "", nets);
    var ties: std.ArrayListUnmanaged(FlatTie) = .empty;
    defer ties.deinit(allocator);
    try collectNetTies(allocator, block, "", &ties);
    try applyNetTies(allocator, nets, ties.items);
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

    const output = try exportFootprintMod(alloc, source, null, null, null);
    defer alloc.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "(footprint \"R_0402_1005Metric\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "thru_hole") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "(pad \"1\" smd roundrect") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "(layers \"F.Cu\" \"F.Mask\" \"F.Paste\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "fp_rect") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "fp_line") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "(layer \"F.SilkS\")") != null);
}
