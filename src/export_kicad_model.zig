const std = @import("std");
const env_mod = @import("eval/env.zig");
const DesignBlock = env_mod.DesignBlock;
const Instance = env_mod.Instance;
const Property = env_mod.Property;

const export_kicad = @import("export_kicad.zig");
const FlatInstance = export_kicad.FlatInstance;
const netlist_mod = @import("export_kicad_netlist.zig");
const collectInstances = netlist_mod.collectInstances;
const footprint_mod = @import("export_kicad_footprint.zig");
const exportFootprintMod = footprint_mod.exportFootprintMod;
const findModelFile = footprint_mod.findModelFile;
const findSourceKicadMod = footprint_mod.findSourceKicadMod;
const useSourceKicadMod = footprint_mod.useSourceKicadMod;
const extractFootprintName = netlist_mod.extractFootprintName;

// ── Model config (3D offset/rotation) ──────────────────────────────

/// Per-footprint 3D-model placement loaded from `lib/models/model-config.json`:
/// XYZ `offset` (mm) and `rotation` (degrees) applied to the STEP model when
/// emitted into a `.kicad_mod`, plus an optional `model` filename that
/// overrides the auto-discovered match.
pub const ModelTransform = struct {
    offset: [3]f64,
    rotation: [3]f64,
    model: ?[]const u8 = null,
};

pub const ModelConfigMap = std.StringHashMap(ModelTransform);

/// Read `lib/models/model-config.json` and return a footprint-name →
/// `ModelTransform` map. The JSON is parsed with a minimal hand-rolled
/// scanner; missing or malformed files yield an empty map rather than
/// erroring so footprint export still succeeds without a config.
pub fn loadModelConfig(allocator: std.mem.Allocator, project_dir: []const u8) ModelConfigMap {
    var map = ModelConfigMap.init(allocator);
    const path = std.fmt.allocPrint(allocator, "{s}/lib/models/model-config.json", .{project_dir}) catch return map;
    defer allocator.free(path);
    const content = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch return map;
    defer allocator.free(content);

    var pos: usize = 0;
    while (pos < content.len) {
        const q1 = std.mem.indexOfPos(u8, content, pos, "\"") orelse break;
        const q2 = std.mem.indexOfPos(u8, content, q1 + 1, "\"") orelse break;
        const key = content[q1 + 1 .. q2];

        const brace = std.mem.indexOfPos(u8, content, q2, "{") orelse break;
        const brace_end = std.mem.indexOfPos(u8, content, brace, "}") orelse break;
        const obj = content[brace .. brace_end + 1];

        var transform = ModelTransform{ .offset = .{ 0, 0, 0 }, .rotation = .{ 0, 0, 0 } };

        if (std.mem.indexOf(u8, obj, "\"offset\":[")) |os| {
            const arr_start = os + 10;
            if (std.mem.indexOfPos(u8, obj, arr_start, "]")) |arr_end| {
                transform.offset = parseFloat3(obj[arr_start..arr_end]);
            }
        }
        if (std.mem.indexOf(u8, obj, "\"rotation\":[")) |rs| {
            const arr_start = rs + 12;
            if (std.mem.indexOfPos(u8, obj, arr_start, "]")) |arr_end| {
                transform.rotation = parseFloat3(obj[arr_start..arr_end]);
            }
        }
        if (std.mem.indexOf(u8, obj, "\"model\":\"")) |ms| {
            const val_start = ms + 9;
            if (std.mem.indexOfPos(u8, obj, val_start, "\"")) |val_end| {
                transform.model = allocator.dupe(u8, obj[val_start..val_end]) catch null;
            }
        }

        // OOM mid-parse: stop and return whatever we've collected so far.
        const duped_key = allocator.dupe(u8, key) catch return map;
        map.put(duped_key, transform) catch return map;
        pos = brace_end + 1;
    }

    return map;
}

/// Parse a `"x,y,z"` triple out of the JSON model-config arrays into a
/// fixed-size `[3]f64`. Missing or unparseable components default to `0`,
/// so a malformed entry degrades to an identity offset/rotation.
pub fn parseFloat3(s: []const u8) [3]f64 {
    var result: [3]f64 = .{ 0, 0, 0 };
    var idx: usize = 0;
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |part| {
        if (idx >= 3) break;
        const trimmed = std.mem.trim(u8, part, " \t\n\r");
        result[idx] = std.fmt.parseFloat(f64, trimmed) catch 0;
        idx += 1;
    }
    return result;
}

/// Produce the `.kicad_mod` text for a footprint. Prefers passing through
/// an unmodified `lib/sources/<name>.kicad_mod` (with the 3D model block
/// rewritten) so vendor-supplied geometry survives round-trips, and falls
/// back to converting the project's `.sexp` footprint when no source exists.
pub fn buildKicadMod(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    fp_name: []const u8,
    fp_sexp_source: []const u8,
    model_name: ?[]const u8,
    model_offset: ?[3]f64,
    model_rotation: ?[3]f64,
) ![]const u8 {
    if (findSourceKicadMod(allocator, project_dir, fp_name)) |src_path| {
        defer allocator.free(src_path);
        if (std.fs.cwd().readFileAlloc(allocator, src_path, 10 * 1024 * 1024)) |original| {
            defer allocator.free(original);
            return useSourceKicadMod(allocator, original, model_name, model_offset, model_rotation);
        } else |_| {}
    }
    return exportFootprintMod(allocator, fp_sexp_source, model_name, model_offset, model_rotation);
}

/// Export all footprint .kicad_mod files used by a design to a .pretty directory.
pub fn exportFootprints(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    project_dir: []const u8,
    output_pretty_dir: []const u8,
) !void {
    const pretty_parent = std.fs.path.dirname(output_pretty_dir) orelse ".";
    const model_dir = try std.fmt.allocPrint(allocator, "{s}/models", .{pretty_parent});
    defer allocator.free(model_dir);
    try std.fs.cwd().makePath(model_dir);

    var instances: std.ArrayListUnmanaged(FlatInstance) = .empty;
    defer instances.deinit(allocator);
    try collectInstances(allocator, block, "", &instances);

    var processed_fps = std.StringHashMap(void).init(allocator);
    defer processed_fps.deinit();

    var model_cfg = loadModelConfig(allocator, project_dir);
    defer model_cfg.deinit();

    for (instances.items) |inst| {
        if (inst.footprint.len == 0) continue;
        if (processed_fps.contains(inst.footprint)) continue;
        try processed_fps.put(inst.footprint, {});

        const fp_path = try std.fmt.allocPrint(allocator, "{s}/lib/footprints/{s}.sexp", .{ project_dir, inst.footprint });
        defer allocator.free(fp_path);

        const fp_source = std.fs.cwd().readFileAlloc(allocator, fp_path, 1024 * 1024) catch continue;
        defer allocator.free(fp_source);

        const kicad_name = extractFootprintName(allocator, fp_source) catch inst.footprint;
        const mcfg = model_cfg.get(inst.footprint);
        const model_name = if (mcfg) |c| (c.model orelse findModelFile(allocator, project_dir, inst.footprint, inst.component)) else findModelFile(allocator, project_dir, inst.footprint, inst.component);

        const mod_output = buildKicadMod(allocator, project_dir, inst.footprint, fp_source, model_name, if (mcfg) |c| c.offset else null, if (mcfg) |c| c.rotation else null) catch {
            if (mcfg == null) if (model_name) |m| allocator.free(m);
            continue;
        };
        defer allocator.free(mod_output);

        const mod_path = try std.fmt.allocPrint(allocator, "{s}/{s}.kicad_mod", .{ output_pretty_dir, kicad_name });
        defer allocator.free(mod_path);

        const f = std.fs.cwd().createFile(mod_path, .{}) catch {
            if (mcfg == null) if (model_name) |m| allocator.free(m);
            continue;
        };
        defer f.close();
        try f.writeAll(mod_output);

        if (model_name) |mname| {
            defer if (mcfg == null) allocator.free(mname);
            const src_path = std.fmt.allocPrint(allocator, "{s}/lib/models/{s}", .{ project_dir, mname }) catch continue;
            defer allocator.free(src_path);
            const dst_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ model_dir, mname }) catch continue;
            defer allocator.free(dst_path);
            std.fs.cwd().copyFile(src_path, std.fs.cwd(), dst_path, .{}) catch |e| {
                std.debug.print("warning: copy {s}: {s}\n", .{ mname, @errorName(e) });
            };
        }
    }
}

/// Export section layout as JSON for PCB placement.
pub fn exportSectionLayout(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
) ![]const u8 {
    var flat_sections: std.ArrayListUnmanaged(struct { name: []const u8, instances: []const Instance, pin_groups: []const env_mod.PinGroup }) = .empty;
    defer flat_sections.deinit(allocator);

    for (block.sections) |sec| {
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

    var n_cols: usize = 1;
    while (n_cols * n_cols < n) : (n_cols += 1) {}

    var ref_map = std.StringHashMap(usize).init(allocator);
    defer ref_map.deinit();

    for (flat_sections.items, 0..) |sec, si| {
        for (sec.instances) |inst| {
            try ref_map.put(inst.ref_des, si);
        }
        for (sec.pin_groups) |pg| {
            if (!ref_map.contains(pg.ref_des)) {
                try ref_map.put(pg.ref_des, si);
            }
        }
    }

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
