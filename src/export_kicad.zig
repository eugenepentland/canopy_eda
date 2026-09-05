//! KiCad export orchestration: flattens the `DesignBlock` and drives the netlist,
//! footprint, and model writers to hand a design off to KiCad's PCB editor.
//! Re-exports `uuidFromId` — the deterministic 8-char id -> KiCad UUID map that
//! keeps footprint placements stable across re-exports — and the flatten it
//! stamps ids during, both of which are declared in `flat_netlist.zig`.

const std = @import("std");
const infra_fs = @import("infra/fs.zig");
const log = @import("infra/log.zig");
const env_mod = @import("eval/env.zig");
const parser_mod = @import("sexpr/parser.zig");
const DesignBlock = env_mod.DesignBlock;
const flat_netlist = @import("flat_netlist.zig");

const netlist_mod = @import("export_kicad_netlist.zig");
const footprint_mod = @import("export_kicad_footprint.zig");
const model_mod = @import("export_kicad_model.zig");
const sch_mod = @import("export_kicad_sch.zig");
const zipfile = @import("zipfile.zig");
const lib_limits = @import("lib_limits.zig");
const stdlib = @import("stdlib.zig");

const writeNetlist = netlist_mod.writeNetlist;
const extractPadNames = netlist_mod.extractPadNames;

// ── Constants ─────────────────────────────────────────────────────
/// Project-relative sub-path of one footprint; resolved through `stdlib`
/// (project `lib/`, the shared lib root, then the bundled standard library).
const footprint_path_template = "lib/footprints/{s}.sexp";
const model_max_bytes: usize = 20 * 1024 * 1024;
const extractFootprintName = netlist_mod.extractFootprintName;
const exportFootprintMod = footprint_mod.exportFootprintMod;
const findModelFile = footprint_mod.findModelFile;
const ZipEntry = zipfile.Entry;
const buildKicadMod = model_mod.buildKicadMod;
pub const loadModelConfig = model_mod.loadModelConfig;

pub const ModelTransform = model_mod.ModelTransform;
pub const ModelConfigMap = model_mod.ModelConfigMap;
pub const exportSectionLayout = model_mod.exportSectionLayout;
pub const exportFootprints = model_mod.exportFootprints;
pub const parseFloat3 = model_mod.parseFloat3;

/// Error set for the KiCad exporter. Wraps file IO (read & write multiple
/// `.kicad_*` files), parser errors on the source `.sexp`, the writer
/// allocations done while building the output buffers, and — when the bundle
/// includes the schematic — every way the `.kicad_sch` writer can fail its own
/// self-check.
pub const ExportError = std.mem.Allocator.Error ||
    infra_fs.File.OpenError ||
    infra_fs.File.ReadError ||
    infra_fs.File.WriteError ||
    infra_fs.Dir.MakeError ||
    parser_mod.ParseError ||
    sch_mod.SchError ||
    error{ FileTooBig, StreamTooLong, EndOfStream, NotDir, BrokenPipe, NotOpenForWriting };

/// What rides along with the netlist, footprints, and STEP models.
pub const BundleOptions = struct {
    /// Also emit the `.kicad_sch` hierarchy and its project sidecars into the
    /// same directory / archive, so the bundle opens as a complete KiCad
    /// project instead of a netlist waiting for a schematic. Off by default in
    /// the directory flow, so an existing `export-kicad` run is byte-identical
    /// unless `--with-schematic` asks for the drawing.
    schematic: bool = false,
};

/// Derive a full UUID (36-char) from an 8-char hex ID by hashing it. DECLARED
/// in `flat_netlist.zig` alongside the flatten that stamps it onto every
/// `FlatInstance`, and re-exported here for the export-layer callers.
pub const uuidFromId = flat_netlist.uuidFromId;

/// True when `name` is unsafe as a file/zip-entry basename — it contains a
/// path separator or a `..` traversal segment. `kicad_name` is read from the
/// *contents* of a `lib/footprints/*.sexp` file (which `import-kicad` and
/// `POST /api/upload-footprint` generate from third-party input), so it is not
/// trusted to be a bare filename: a declared name like `../../etc/x` would
/// otherwise write outside `--output-dir` (or become a zip-slip entry).
fn kicadNameIsUnsafe(name: []const u8) bool {
    if (name.len == 0) return true;
    if (std.mem.indexOfScalar(u8, name, '/') != null) return true;
    if (std.mem.indexOfScalar(u8, name, '\\') != null) return true;
    if (std.mem.indexOf(u8, name, "..") != null) return true;
    return false;
}

/// A filesystem-safe footprint basename derived from the declared `kicad_name`:
/// returns it unchanged when already safe, else replaces every `/`, `\`, and
/// `.` (so `..` can't survive) with `_` and warns. Never returns an empty
/// string. The result is used both as a `.kicad_mod` filename and a zip entry.
fn sanitizeKicadName(allocator: std.mem.Allocator, kicad_name: []const u8) std.mem.Allocator.Error![]const u8 {
    if (!kicadNameIsUnsafe(kicad_name)) return kicad_name;
    const safe = try allocator.alloc(u8, @max(kicad_name.len, 1));
    if (kicad_name.len == 0) {
        safe[0] = '_';
    } else {
        for (kicad_name, 0..) |c, i| {
            safe[i] = if (c == '/' or c == '\\' or c == '.') '_' else c;
        }
    }
    log.warn("export-kicad: unsafe footprint name '{s}' sanitized to '{s}' (path-traversal guard)", .{ kicad_name, safe });
    return safe;
}

/// The flattened-netlist currency types. They are DECLARED in
/// `flat_netlist.zig`, a neutral module beneath both this export layer and the
/// `src/placement/*` layer that consumes them, and re-exported here so callers
/// that legitimately live in the export layer keep their historical spelling.
/// See that module's header for why the split exists.
pub const FlatInstance = flat_netlist.FlatInstance;
pub const FlatNet = flat_netlist.FlatNet;
pub const FlatPin = flat_netlist.FlatPin;

/// Build the footprint -> pad-name-list map used for NC-pin handling, reading
/// and parsing each unique footprint once. Footprints that fail to read or
/// parse are skipped. The caller owns the returned map's `deinit`.
fn buildPadMap(
    allocator: std.mem.Allocator,
    instances: []const FlatInstance,
    project_dir: []const u8,
) ExportError!std.StringHashMapUnmanaged([]const []const u8) {
    var fp_pad_map = std.StringHashMapUnmanaged([]const []const u8).empty;
    errdefer fp_pad_map.deinit(allocator);
    for (instances) |inst| {
        if (inst.footprint.len == 0) continue;
        if (fp_pad_map.contains(inst.footprint)) continue;
        const fp_sub = try std.fmt.allocPrint(allocator, footprint_path_template, .{inst.footprint});
        defer allocator.free(fp_sub);
        const fp_src = stdlib.read(allocator, project_dir, fp_sub, lib_limits.max_footprint_bytes) orelse continue;
        defer allocator.free(fp_src);
        const pad_names = extractPadNames(allocator, fp_src) catch continue;
        try fp_pad_map.put(allocator, inst.footprint, pad_names);
    }
    return fp_pad_map;
}

/// Export a resolved design to KiCad format: netlist + footprints + STEP
/// models, plus the `.kicad_sch` hierarchy when `opts.schematic` asks for it.
pub fn exportKicad(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    project_dir: []const u8,
    output_dir: []const u8,
    design_name: []const u8,
    opts: BundleOptions,
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
    var instances: std.ArrayList(FlatInstance) = .empty;
    defer instances.deinit(allocator);
    var nets: std.ArrayList(FlatNet) = .empty;
    defer nets.deinit(allocator);

    try collectInstances(allocator, block, "", &instances);
    try flattenAndMergeNets(allocator, block, &nets);

    // Build footprint name map: internal name -> KiCad declared name
    // Also track which footprints we've already processed
    var fp_name_map = std.StringHashMapUnmanaged([]const u8).empty;
    defer fp_name_map.deinit(allocator);
    var processed_fps = std.StringHashMapUnmanaged(void).empty;
    defer processed_fps.deinit(allocator);

    // Collect unique footprint names and their associated component names
    var fp_components = std.StringHashMapUnmanaged([]const u8).empty;
    defer fp_components.deinit(allocator);

    // Declared KiCad name → source footprint id, to warn when two distinct
    // internal footprints declare the same name (the second .kicad_mod would
    // silently overwrite the first, exporting one part with the other's geometry).
    var seen_kicad_names = std.StringHashMapUnmanaged([]const u8).empty;
    defer seen_kicad_names.deinit(allocator);

    // Load 3D model config for offset/rotation
    var model_cfg = loadModelConfig(allocator, project_dir);
    defer model_cfg.deinit(allocator);

    for (instances.items) |inst| {
        if (inst.footprint.len == 0) continue;
        if (processed_fps.contains(inst.footprint)) continue;
        try processed_fps.put(allocator, inst.footprint, {});
        try fp_components.put(allocator, inst.footprint, inst.component);

        // Load and parse footprint .sexp to get declared name
        const fp_sub = try std.fmt.allocPrint(allocator, footprint_path_template, .{inst.footprint});
        defer allocator.free(fp_sub);

        const fp_source = stdlib.read(allocator, project_dir, fp_sub, lib_limits.max_footprint_bytes) orelse {
            log.warn("cannot read footprint {s} under {s} or the standard library", .{ fp_sub, project_dir });
            try fp_name_map.put(allocator, inst.footprint, inst.footprint);
            continue;
        };
        defer allocator.free(fp_source);

        // The declared name is spliced into a filesystem path + zip entry; sanitize
        // it so a footprint declaring `../../x` can't escape --output-dir.
        const kicad_name = try sanitizeKicadName(allocator, extractFootprintName(allocator, fp_source) catch inst.footprint);
        if (seen_kicad_names.get(kicad_name)) |first| {
            if (!std.mem.eql(u8, first, inst.footprint))
                log.warn("export-kicad: footprints '{s}' and '{s}' both declare KiCad name '{s}' — the .kicad_mod will be overwritten", .{ first, inst.footprint, kicad_name });
        } else {
            try seen_kicad_names.put(allocator, kicad_name, inst.footprint);
        }
        try fp_name_map.put(allocator, inst.footprint, kicad_name);

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
        log.progress("  Wrote {s}", .{mod_path});

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
            log.progress("  Copied model {s}", .{mname});
        }
    }

    // Write netlist
    const net_path = try std.fmt.allocPrint(allocator, "{s}/{s}.net", .{ output_dir, design_name });
    defer allocator.free(net_path);

    // Build footprint pad map for NC pin handling
    var fp_pad_map = try buildPadMap(allocator, instances.items, project_dir);
    defer fp_pad_map.deinit(allocator);

    const netlist = try writeNetlist(allocator, design_name, instances.items, nets.items, &fp_name_map, &fp_pad_map);
    defer allocator.free(netlist);

    const nf = try infra_fs.cwd().createFile(net_path, .{});
    defer nf.close();
    try nf.writeAll(netlist);
    log.progress("  Wrote {s}", .{net_path});

    if (opts.schematic) try writeSchematicInto(allocator, block, project_dir, output_dir, design_name);
}

/// Write the `.kicad_sch` hierarchy and its project sidecars into
/// `output_dir`. Sheet names are bare siblings (that is what the root's
/// `Sheetfile` properties point at), and a sidecar that already exists is left
/// alone — an export aimed at a live KiCad project must not overwrite its
/// `.kicad_pro` or a hand-edited library table.
fn writeSchematicInto(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    project_dir: []const u8,
    output_dir: []const u8,
    design_name: []const u8,
) ExportError!void {
    const out = try sch_mod.exportSch(allocator, block, project_dir, design_name, .{});
    defer out.deinit(allocator);
    for (out.files) |f| {
        const path = try std.fs.path.join(allocator, &.{ output_dir, f.name });
        defer allocator.free(path);
        try infra_fs.cwd().writeFile(.{ .sub_path = path, .data = f.bytes });
        log.progress("  Wrote {s}", .{path});
    }
    for (out.sidecars) |f| {
        const path = try std.fs.path.join(allocator, &.{ output_dir, f.name });
        defer allocator.free(path);
        if (infra_fs.cwd().access(path, .{})) |_| continue else |_| {}
        try infra_fs.cwd().writeFile(.{ .sub_path = path, .data = f.bytes });
        log.progress("  Wrote {s}", .{path});
    }
}

/// Export just the KiCad netlist as a string.
pub fn exportNetlistOnly(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    project_dir: []const u8,
    design_name: []const u8,
) ExportError![]const u8 {
    var instances: std.ArrayList(FlatInstance) = .empty;
    defer instances.deinit(allocator);
    var nets: std.ArrayList(FlatNet) = .empty;
    defer nets.deinit(allocator);

    try collectInstances(allocator, block, "", &instances);
    try flattenAndMergeNets(allocator, block, &nets);

    var fp_name_map = std.StringHashMapUnmanaged([]const u8).empty;
    defer fp_name_map.deinit(allocator);
    var processed_fps = std.StringHashMapUnmanaged(void).empty;
    defer processed_fps.deinit(allocator);

    for (instances.items) |inst| {
        if (inst.footprint.len == 0) continue;
        if (processed_fps.contains(inst.footprint)) continue;
        try processed_fps.put(allocator, inst.footprint, {});

        const fp_sub = try std.fmt.allocPrint(allocator, footprint_path_template, .{inst.footprint});
        defer allocator.free(fp_sub);

        const fp_source = stdlib.read(allocator, project_dir, fp_sub, lib_limits.max_footprint_bytes) orelse {
            try fp_name_map.put(allocator, inst.footprint, inst.footprint);
            continue;
        };
        defer allocator.free(fp_source);

        const kicad_name = extractFootprintName(allocator, fp_source) catch inst.footprint;
        try fp_name_map.put(allocator, inst.footprint, kicad_name);
    }

    // Build footprint pad map for NC pin handling
    var fp_pad_map = try buildPadMap(allocator, instances.items, project_dir);
    defer fp_pad_map.deinit(allocator);

    return writeNetlist(allocator, design_name, instances.items, nets.items, &fp_name_map, &fp_pad_map);
}

/// Like `exportKicad`, but returns the entire output bundle as in-memory ZIP
/// entries: netlist, every `.kicad_mod` and STEP model, and optionally the
/// complete schematic hierarchy and project sidecars.
pub fn exportKicadEntries(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    project_dir: []const u8,
    design_name: []const u8,
    opts: BundleOptions,
) ExportError![]const zipfile.Entry {
    var instances: std.ArrayList(FlatInstance) = .empty;
    defer instances.deinit(allocator);
    var nets: std.ArrayList(FlatNet) = .empty;
    defer nets.deinit(allocator);

    try collectInstances(allocator, block, "", &instances);
    try flattenAndMergeNets(allocator, block, &nets);

    var fp_name_map = std.StringHashMapUnmanaged([]const u8).empty;
    defer fp_name_map.deinit(allocator);
    var processed_fps = std.StringHashMapUnmanaged(void).empty;
    defer processed_fps.deinit(allocator);
    // Same duplicate-name / zip-slip guard as exportFootprints (see there).
    var seen_kicad_names = std.StringHashMapUnmanaged([]const u8).empty;
    defer seen_kicad_names.deinit(allocator);

    // Collect zip entries
    var zip_files: std.ArrayList(ZipEntry) = .empty;
    defer zip_files.deinit(allocator);

    var model_cfg = loadModelConfig(allocator, project_dir);
    defer model_cfg.deinit(allocator);

    for (instances.items) |inst| {
        if (inst.footprint.len == 0) continue;
        if (processed_fps.contains(inst.footprint)) continue;
        try processed_fps.put(allocator, inst.footprint, {});

        const fp_sub = try std.fmt.allocPrint(allocator, footprint_path_template, .{inst.footprint});
        defer allocator.free(fp_sub);

        const fp_source = stdlib.read(allocator, project_dir, fp_sub, lib_limits.max_footprint_bytes) orelse {
            try fp_name_map.put(allocator, inst.footprint, inst.footprint);
            continue;
        };
        defer allocator.free(fp_source);

        // Sanitize the declared name before it becomes a zip entry (zip-slip).
        const kicad_name = try sanitizeKicadName(allocator, extractFootprintName(allocator, fp_source) catch inst.footprint);
        if (seen_kicad_names.get(kicad_name)) |first| {
            if (!std.mem.eql(u8, first, inst.footprint))
                log.warn("export-kicad: footprints '{s}' and '{s}' both declare KiCad name '{s}' — the .kicad_mod will be overwritten in the zip", .{ first, inst.footprint, kicad_name });
        } else {
            try seen_kicad_names.put(allocator, kicad_name, inst.footprint);
        }
        try fp_name_map.put(allocator, inst.footprint, kicad_name);

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
            const model_data = infra_fs.cwd().readFileAlloc(allocator, src_path, model_max_bytes) catch continue;
            const model_filename = try std.fmt.allocPrint(allocator, "models/{s}", .{mname});
            try zip_files.append(allocator, .{ .name = model_filename, .data = model_data });
        }
    }

    // Build footprint pad map for NC pin handling
    var fp_pad_map = try buildPadMap(allocator, instances.items, project_dir);
    defer fp_pad_map.deinit(allocator);

    // Netlist
    const netlist = try writeNetlist(allocator, design_name, instances.items, nets.items, &fp_name_map, &fp_pad_map);
    const net_filename = try std.fmt.allocPrint(allocator, "{s}.net", .{design_name});
    try zip_files.append(allocator, .{ .name = net_filename, .data = netlist });

    // The schematic rides at the archive root beside the netlist, because the
    // root sheet's `Sheetfile` links name bare siblings and the project
    // sidecars only resolve from the directory holding the `.kicad_pro`.
    const sch = if (opts.schematic)
        try sch_mod.exportSch(allocator, block, project_dir, design_name, .{})
    else
        sch_mod.Output{ .files = &.{}, .sidecars = &.{} };
    for (sch.files) |f| try zip_files.append(allocator, .{ .name = f.name, .data = f.bytes });
    for (sch.sidecars) |f| try zip_files.append(allocator, .{ .name = f.name, .data = f.bytes });

    return zip_files.toOwnedSlice(allocator);
}

/// Like `exportKicadEntries`, serialized as the standalone download archive.
/// Keeping the entry-producing seam public lets larger engineering handoff
/// archives place the files directly in their own tree instead of hiding a
/// second ZIP inside the first one.
pub fn exportKicadZip(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    project_dir: []const u8,
    design_name: []const u8,
    opts: BundleOptions,
) ExportError![]const u8 {
    const zip_files = try exportKicadEntries(allocator, block, project_dir, design_name, opts);
    defer allocator.free(zip_files);
    var zw: std.Io.Writer.Allocating = .init(allocator);
    errdefer zw.deinit();
    try zipfile.write(&zw.writer, zip_files);
    return zw.toOwnedSlice();
}

const collectInstances = flat_netlist.collectInstances;

/// Flatten a design's `(sub-block …)` hierarchy into prefixed nets and merge
/// its net ties. DECLARED in `flat_netlist.zig` — joining the hierarchy is not
/// a KiCad concern, and `src/placement/*` needs the same flatten this exporter
/// does — and re-exported here for the export-layer callers.
pub const flattenAndMergeNets = flat_netlist.flattenAndMergeNets;
pub const flattenAndMergeNetsMapped = flat_netlist.flattenAndMergeNetsMapped;

const ConvertError = error{
    InvalidFormat,
    OutOfMemory,
    UnexpectedEof,
    UnexpectedRparen,
    UnexpectedCharacter,
    UnterminatedString,
    InvalidNumber,
};

// spec: export_kicad - Re-exports the flattened-netlist currency types from the export layer as the same types

test "the export layer re-exports the flatten currency types unchanged" {
    // The types are DECLARED in `flat_netlist.zig` so `src/placement/*` can
    // reach them without importing this exporter. This layer keeps the
    // historical spelling, and the re-export must stay the SAME type — a
    // distinct copy would mean a `FlatPin` built by placement no longer fits a
    // netlist writer, which is the whole point of the shared currency.
    try std.testing.expectEqual(flat_netlist.FlatPin, FlatPin);
    try std.testing.expectEqual(flat_netlist.FlatNet, FlatNet);
    try std.testing.expectEqual(flat_netlist.FlatInstance, FlatInstance);
}

// spec: export_kicad - Generates a KiCad netlist from a resolved design
test "netlist generation" {
    const alloc = std.testing.allocator;
    var fp_map = std.StringHashMapUnmanaged([]const u8).empty;
    defer fp_map.deinit(alloc);
    try fp_map.put(alloc, "r-0402", "R_0402_1005Metric");

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
    var fp_pad_map = std.StringHashMapUnmanaged([]const []const u8).empty;
    defer fp_pad_map.deinit(alloc);
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

// spec: export_kicad - Sanitizes a declared footprint name so a path-traversal component can't escape the output directory
test "sanitizeKicadName neutralizes traversal and passes safe names through" {
    const alloc = std.testing.allocator;
    // Safe names return the input slice unchanged (no allocation).
    try std.testing.expect(!kicadNameIsUnsafe("R_0402_1005Metric"));
    try std.testing.expectEqualStrings("R_0402_1005Metric", try sanitizeKicadName(alloc, "R_0402_1005Metric"));

    // Traversal / separators are unsafe and get scrubbed to a bare basename.
    try std.testing.expect(kicadNameIsUnsafe("../../etc/passwd"));
    const s1 = try sanitizeKicadName(alloc, "../../etc/passwd");
    defer alloc.free(s1);
    try std.testing.expect(std.mem.indexOfScalar(u8, s1, '/') == null);
    try std.testing.expect(std.mem.indexOf(u8, s1, "..") == null);

    try std.testing.expect(kicadNameIsUnsafe("a\\b"));
    const s2 = try sanitizeKicadName(alloc, "a\\b");
    defer alloc.free(s2);
    try std.testing.expect(std.mem.indexOfScalar(u8, s2, '\\') == null);
}

// spec: export_kicad - a cap's decoupling target IC survives the flatten carrying the same sub-block prefix its ref-des takes
test "collectInstances prefixes a decoupling binding's target IC like the ref-des" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A module holding an IC and a bypass cap bound to it. The binding names the
    // module-LOCAL "U1"; two such modules on one board would otherwise both
    // resolve to whichever "U1" a consumer met first.
    var child = env_mod.DesignBlock{
        .name = "rail",
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
        .instances = &.{
            .{ .ref_des = "U1", .label = "U1", .component = "ic", .value = "", .footprint = "", .symbol = "" },
            .{
                .ref_des = "C1",
                .label = "C1",
                .component = "cap-0402",
                .value = "100nF",
                .footprint = "",
                .symbol = "",
                .bind = .{ .decouple = .{ .ic = "U1", .pin = "4" } },
            },
        },
    };
    const block = env_mod.DesignBlock{
        .name = "board",
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{.{ .name = "pwr", .block = &child }},
    };

    var list: std.ArrayList(FlatInstance) = .empty;
    try netlist_mod.collectInstances(arena, &block, "", &list);
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    const cap = list.items[1];
    try std.testing.expectEqualStrings("pwr/C1", cap.ref_des);
    // Same prefix as the ref-des — the cap and its target are siblings.
    try std.testing.expectEqualStrings("pwr/U1", cap.bind.decouple.ic);
    try std.testing.expectEqualStrings("4", cap.bind.decouple.pin);
    // An unbound part gains no spurious prefix-only string.
    try std.testing.expectEqualStrings("", list.items[0].bind.decouple.ic);
}
