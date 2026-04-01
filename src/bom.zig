const std = @import("std");
const env_mod = @import("eval/env.zig");
const parser_mod = @import("sexpr/parser.zig");
const parts_mod = @import("parts.zig");
const DesignBlock = env_mod.DesignBlock;
const Instance = env_mod.Instance;
const Property = env_mod.Property;
const Net = env_mod.Net;

/// A single BOM entry: ref_des → UUID + component + properties.
const BomEntry = struct {
    ref_des: []const u8,
    uuid: []const u8,
    component: []const u8,
    properties: []const Property,
    id: []const u8 = "",
};

/// Load a .bom sidecar file and return the entries.
/// Returns empty slice if file does not exist.
fn loadBom(allocator: std.mem.Allocator, bom_path: []const u8) ![]const BomEntry {
    const source = std.fs.cwd().readFileAlloc(allocator, bom_path, 4 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer allocator.free(source);

    const nodes = parser_mod.parse(allocator, source) catch return &.{};
    defer parser_mod.freeNodes(allocator, nodes);

    var entries: std.ArrayListUnmanaged(BomEntry) = .empty;
    errdefer entries.deinit(allocator);

    for (nodes) |node| {
        if (!node.isForm("part")) continue;
        const children = node.asList() orelse continue;
        if (children.len < 3) continue;

        const ref_des = children[1].asString() orelse continue;
        const uuid = children[2].asString() orelse continue;
        const component = if (children.len >= 4) (children[3].asString() orelse "") else "";

        // Parse sub-forms: (id "..."), (key "val"), ...
        var entry_id: []const u8 = "";
        var props: std.ArrayListUnmanaged(Property) = .empty;
        const start_idx: usize = if (children.len >= 4) 4 else 3;
        if (children.len > start_idx) {
            for (children[start_idx..]) |prop_node| {
                const prop_children = prop_node.asList() orelse continue;
                if (prop_children.len < 2) continue;
                const key = prop_children[0].asAtom() orelse continue;
                const value = prop_children[1].asString() orelse continue;
                if (std.mem.eql(u8, key, "footprint")) {
                    continue; // Ignored — footprint comes from evaluator
                } else if (std.mem.eql(u8, key, "id")) {
                    entry_id = try allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "value")) {
                    // Informational field, not stored in BomEntry
                    continue;
                } else {
                    try props.append(allocator, .{
                        .key = try allocator.dupe(u8, key),
                        .value = try allocator.dupe(u8, value),
                    });
                }
            }
        }

        try entries.append(allocator, .{
            .ref_des = try allocator.dupe(u8, ref_des),
            .uuid = try allocator.dupe(u8, uuid),
            .component = if (component.len > 0) try allocator.dupe(u8, component) else "",
            .properties = props.toOwnedSlice(allocator) catch &.{},
            .id = entry_id,
        });
    }

    return entries.toOwnedSlice(allocator);
}

/// Collect all flat instances from a design block hierarchy.
const FlatInfo = struct {
    ref_des: []const u8,
    component: []const u8,
    footprint: []const u8,
    value: []const u8,
    attrs: []const []const u8,
    nets: []const []const u8,
    properties: []const Property,
    id: []const u8 = "",
};

fn collectFlatInstances(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    prefix: []const u8,
    list: *std.ArrayListUnmanaged(FlatInfo),
) !void {
    var net_map = std.StringHashMap(std.ArrayListUnmanaged([]const u8)).init(allocator);
    defer {
        var it = net_map.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        net_map.deinit();
    }
    for (block.nets) |net| {
        for (net.pins) |pin| {
            const gop = try net_map.getOrPut(pin.ref_des);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(allocator, net.name);
        }
    }

    for (block.instances) |inst| {
        const ref = if (prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, inst.ref_des })
        else
            try allocator.dupe(u8, inst.ref_des);

        const nets_list = if (net_map.get(inst.ref_des)) |nl| blk: {
            const slice = try allocator.alloc([]const u8, nl.items.len);
            @memcpy(slice, nl.items);
            break :blk slice;
        } else &[_][]const u8{};

        try list.append(allocator, .{
            .ref_des = ref,
            .component = inst.component,
            .footprint = inst.footprint,
            .value = inst.value,
            .attrs = inst.attrs,
            .nets = nets_list,
            .properties = inst.properties,
            .id = inst.id,
        });
    }
    for (block.sub_blocks) |sb| {
        const sub_prefix = if (prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, sb.name })
        else
            try allocator.dupe(u8, sb.name);
        try collectFlatInstances(allocator, sb.block, sub_prefix, list);
    }
}

/// Generate a v4 UUID string (lowercase hex with dashes).
fn generateUuid(allocator: std.mem.Allocator) ![]const u8 {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    return std.fmt.allocPrint(allocator, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
        bytes[0],  bytes[1],  bytes[2],  bytes[3],
        bytes[4],  bytes[5],  bytes[6],  bytes[7],
        bytes[8],  bytes[9],  bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15],
    });
}

fn netOverlap(a: []const []const u8, b: []const []const u8) f64 {
    if (a.len == 0 and b.len == 0) return 1.0;
    if (a.len == 0 or b.len == 0) return 0.0;
    var matches: usize = 0;
    for (a) |na| {
        for (b) |nb| {
            if (std.mem.eql(u8, na, nb)) {
                matches += 1;
                break;
            }
        }
    }
    const max_len: f64 = @floatFromInt(@max(a.len, b.len));
    return @as(f64, @floatFromInt(matches)) / max_len;
}

/// Lightweight UUID application: reads existing .bom file and applies UUIDs
/// to matching instances by ref-des. Does NOT generate new UUIDs or save.
/// Safe to call from serve handlers (no @constCast issues with arena allocators).
pub fn applyBomUuids(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    project_dir: []const u8,
    design_name: []const u8,
) !void {
    const bom_path = try std.fmt.allocPrint(allocator, "{s}/src/{s}.bom", .{ project_dir, design_name });
    defer allocator.free(bom_path);

    const entries = try loadBom(allocator, bom_path);
    if (entries.len == 0) return;

    // Build ref_des → uuid map
    var uuid_map = std.StringHashMap([]const u8).init(allocator);
    defer uuid_map.deinit();
    for (entries) |entry| {
        if (entry.uuid.len > 0) {
            try uuid_map.put(entry.ref_des, entry.uuid);
        }
    }

    // Apply to instances (uses @constCast — safe because block was just allocated)
    const instances: []Instance = @constCast(block.instances);
    for (instances) |*inst| {
        if (uuid_map.get(inst.ref_des)) |uuid| {
            inst.uuid = uuid;
        }
    }
    for (block.sub_blocks) |sb| {
        try applyBomUuids(allocator, sb.block, project_dir, design_name);
    }
}

/// Resolve identities and BOM data for all instances in a design block.
/// Loads existing .bom, matches instances, assigns UUIDs, merges properties
/// and footprints, then saves the updated .bom file.
pub fn resolveIdentities(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    bom_path: []const u8,
    project_dir: []const u8,
) !void {
    const old_entries = try loadBom(allocator, bom_path);
    defer {
        for (old_entries) |e| {
            if (e.ref_des.len > 0) allocator.free(e.ref_des);
            if (e.uuid.len > 0) allocator.free(e.uuid);
            if (e.component.len > 0) allocator.free(e.component);
            if (e.id.len > 0) allocator.free(e.id);
            for (e.properties) |p| {
                allocator.free(p.key);
                allocator.free(p.value);
            }
            if (e.properties.len > 0) allocator.free(e.properties);
        }
        allocator.free(old_entries);
    }

    var flat_list: std.ArrayListUnmanaged(FlatInfo) = .empty;
    defer flat_list.deinit(allocator);
    try collectFlatInstances(allocator, block, "", &flat_list);

    var old_by_ref = std.StringHashMap(usize).init(allocator);
    defer old_by_ref.deinit();
    for (old_entries, 0..) |e, i| {
        try old_by_ref.put(e.ref_des, i);
    }

    var claimed = try allocator.alloc(bool, old_entries.len);
    defer allocator.free(claimed);
    @memset(claimed, false);

    var result_map = std.StringHashMap([]const u8).init(allocator);
    defer result_map.deinit();
    var props_map = std.StringHashMap([]const Property).init(allocator);
    defer props_map.deinit();

    // Pass 0: match by (id ...) — stable even if ref_des changes
    var old_by_id = std.StringHashMap(usize).init(allocator);
    defer old_by_id.deinit();
    for (old_entries, 0..) |e, i| {
        if (e.id.len > 0) try old_by_id.put(e.id, i);
    }
    for (flat_list.items) |info| {
        if (info.id.len > 0) {
            if (old_by_id.get(info.id)) |idx| {
                if (!claimed[idx]) {
                    try result_map.put(info.ref_des, try allocator.dupe(u8, old_entries[idx].uuid));
                    if (old_entries[idx].properties.len > 0) {
                        try props_map.put(info.ref_des, old_entries[idx].properties);
                    }
                    claimed[idx] = true;
                }
            }
        }
    }

    // Pass 1: exact ref_des match (for entries without IDs)
    for (flat_list.items) |info| {
        if (result_map.contains(info.ref_des)) continue;
        if (old_by_ref.get(info.ref_des)) |idx| {
            if (claimed[idx]) continue;
            try result_map.put(info.ref_des, try allocator.dupe(u8, old_entries[idx].uuid));
            if (old_entries[idx].properties.len > 0) {
                try props_map.put(info.ref_des, old_entries[idx].properties);
            }
            claimed[idx] = true;
        }
    }

    // Pass 2: rename detection
    for (flat_list.items) |info| {
        if (result_map.contains(info.ref_des)) continue;
        var best_idx: ?usize = null;
        var sole_match: ?usize = null;
        var same_component_count: usize = 0;
        for (old_entries, 0..) |old, idx| {
            if (claimed[idx]) continue;
            if (std.mem.eql(u8, old.component, info.component)) {
                same_component_count += 1;
                sole_match = idx;
            }
        }
        if (same_component_count == 1) best_idx = sole_match;

        if (best_idx) |idx| {
            try result_map.put(info.ref_des, try allocator.dupe(u8, old_entries[idx].uuid));
            if (old_entries[idx].properties.len > 0) {
                try props_map.put(info.ref_des, old_entries[idx].properties);
            }
            claimed[idx] = true;
        }
    }

    // Pass 3: assign new UUIDs
    for (flat_list.items) |info| {
        if (result_map.contains(info.ref_des)) continue;
        try result_map.put(info.ref_des, try generateUuid(allocator));
    }

    // Pass 4: auto-resolve manufacturer + MPN from parts DB
    var parts_db = parts_mod.PartsDb.init(allocator, project_dir);
    defer parts_db.deinit();

    for (flat_list.items) |info| {
        // Skip if BOM sidecar already has mpn (manual override)
        if (props_map.get(info.ref_des)) |existing_props| {
            var has_mpn = false;
            for (existing_props) |p| {
                if (std.mem.eql(u8, p.key, "mpn")) {
                    has_mpn = true;
                    break;
                }
            }
            if (has_mpn) continue;
        }
        // Skip unsized families (no footprint = can't resolve)
        if (info.footprint.len == 0) {
            if (info.value.len > 0) {
                std.debug.print("warning: {s} uses unsized family '{s}' — no footprint or MPN resolution\n", .{ info.ref_des, info.component });
            }
            continue;
        }
        // Skip if component already has manufacturer+mpn from component definition
        var has_mpn_from_component = false;
        for (info.properties) |p| {
            if (std.mem.eql(u8, p.key, "mpn")) {
                has_mpn_from_component = true;
                break;
            }
        }
        if (has_mpn_from_component) continue;

        if (parts_db.lookup(info.component, info.value, info.attrs)) |part| {
            var new_props: std.ArrayListUnmanaged(Property) = .empty;
            // Carry forward existing props from BOM/component
            if (props_map.get(info.ref_des)) |existing| {
                for (existing) |p| try new_props.append(allocator, p);
            }
            if (part.manufacturer.len > 0) {
                try new_props.append(allocator, .{
                    .key = try allocator.dupe(u8, "manufacturer"),
                    .value = try allocator.dupe(u8, part.manufacturer),
                });
            }
            if (part.mpn.len > 0) {
                try new_props.append(allocator, .{
                    .key = try allocator.dupe(u8, "mpn"),
                    .value = try allocator.dupe(u8, part.mpn),
                });
            }
            try props_map.put(info.ref_des, try new_props.toOwnedSlice(allocator));
        }
    }

    // Apply UUIDs, properties, and footprints to the design block
    try applyBom(allocator, block, &result_map, &props_map, "");

    // Save .bom file
    try saveBom(allocator, bom_path, flat_list.items, &result_map, &props_map);
}

/// Recursively apply BOM data (UUIDs, properties, footprints) to Instance structs.
fn applyBom(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    uuid_map: *const std.StringHashMap([]const u8),
    props_map: *const std.StringHashMap([]const Property),
    prefix: []const u8,
) !void {
    const instances: []Instance = @constCast(block.instances);
    for (instances) |*inst| {
        const key = if (prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, inst.ref_des })
        else
            inst.ref_des;
        defer if (prefix.len > 0) allocator.free(key);

        if (uuid_map.get(key)) |uuid| {
            inst.uuid = allocator.dupe(u8, uuid) catch uuid;
        }

        // Merge .bom properties into instance
        if (props_map.get(key)) |bom_props| {
            if (bom_props.len > 0) {
                var merged: std.ArrayListUnmanaged(Property) = .empty;
                for (inst.properties) |cp| {
                    var overridden = false;
                    for (bom_props) |ip| {
                        if (std.mem.eql(u8, cp.key, ip.key)) {
                            overridden = true;
                            break;
                        }
                    }
                    if (!overridden) merged.append(allocator, cp) catch {};
                }
                for (bom_props) |ip| merged.append(allocator, .{
                    .key = allocator.dupe(u8, ip.key) catch ip.key,
                    .value = allocator.dupe(u8, ip.value) catch ip.value,
                }) catch {};
                inst.properties = merged.toOwnedSlice(allocator) catch inst.properties;
            }
        }
    }
    for (block.sub_blocks) |sb| {
        const child_prefix = if (prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, sb.name })
        else
            sb.name;
        defer if (prefix.len > 0) allocator.free(child_prefix);
        try applyBom(allocator, sb.block, uuid_map, props_map, child_prefix);
    }
}

/// Save the .bom sidecar file.
fn saveBom(
    allocator: std.mem.Allocator,
    bom_path: []const u8,
    flat_instances: []const FlatInfo,
    uuid_map: *const std.StringHashMap([]const u8),
    props_map: *const std.StringHashMap([]const Property),
) !void {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeAll(";; BOM — auto-generated by eda build\n");
    try w.writeAll(";; Stores identity and properties per instance\n\n");

    for (flat_instances) |info| {
        const uuid = uuid_map.get(info.ref_des) orelse continue;
        const props = props_map.get(info.ref_des) orelse info.properties;

        try w.print("(part \"{s}\" \"{s}\" \"{s}\"\n", .{ info.ref_des, uuid, info.component });
        try w.print("  (id \"{s}\")\n", .{info.id});
        for (props) |p| {
            try w.print("  ({s} \"{s}\")\n", .{ p.key, p.value });
        }
        try w.writeAll(")\n");
    }

    const f = try std.fs.cwd().createFile(bom_path, .{});
    defer f.close();
    try f.writeAll(buf.items);
}

// spec: bom - Generates deterministic UUIDs in the expected format
test "generate uuid format" {
    const alloc = std.testing.allocator;
    const uuid = try generateUuid(alloc);
    defer alloc.free(uuid);
    try std.testing.expectEqual(@as(usize, 36), uuid.len);
    try std.testing.expectEqual(@as(u8, '-'), uuid[8]);
    try std.testing.expectEqual(@as(u8, '-'), uuid[13]);
    try std.testing.expectEqual(@as(u8, '-'), uuid[18]);
    try std.testing.expectEqual(@as(u8, '-'), uuid[23]);
}

// spec: bom - Loads an empty BOM file without error
test "load empty bom" {
    const alloc = std.testing.allocator;
    const entries = try loadBom(alloc, "/nonexistent/path.bom");
    try std.testing.expectEqual(@as(usize, 0), entries.len);
}

// spec: bom - Detects net overlap between components
test "net overlap" {
    const a = &[_][]const u8{ "VDD", "GND", "SDA" };
    const b = &[_][]const u8{ "VDD", "GND", "SCL" };
    const overlap = netOverlap(a, b);
    try std.testing.expectApproxEqAbs(0.6666, overlap, 0.01);
}
