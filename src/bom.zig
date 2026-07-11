const std = @import("std");
const infra_fs = @import("infra/fs.zig");
const paths = @import("paths.zig");
const env_mod = @import("eval/env.zig");
const parser_mod = @import("sexpr/parser.zig");
const parts_mod = @import("parts.zig");
const infra_random = @import("infra/random.zig");
const kicad_format = @import("kicad_pcb/format.zig");
const DesignBlock = env_mod.DesignBlock;
const Instance = env_mod.Instance;
const Property = env_mod.Property;
const Net = env_mod.Net;
const bom_resolve = @import("bom_resolve.zig");

pub const resolveIdentities = bom_resolve.resolveIdentities;

// ── Constants ─────────────────────────────────────────────────────
// UUID v4 byte indices (RFC 4122)
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

/// Error set for BOM loading and application. Covers parser-side errors,
/// the file IO surface infra_fs.cwd() exposes, and `OutOfMemory`.
pub const BomError = std.mem.Allocator.Error ||
    std.fs.File.OpenError ||
    std.fs.File.ReadError ||
    error{ FileTooBig, StreamTooLong, EndOfStream };

/// A single BOM entry: ref_des → UUID + component + properties.
pub const BomEntry = struct {
    ref_des: []const u8,
    uuid: []const u8,
    component: []const u8,
    properties: []const Property,
    id: []const u8 = "",
    nets: []const []const u8 = &.{},
};

/// Decode a `.bom` string token (undoing the writer's `sexprEscape`) into a
/// freshly-owned copy that outlives the parse buffer. A no-op decode (no
/// backslash) still returns an owned dupe, so every returned field is owned by
/// `allocator` exactly once — no transient-allocation leak, and the writers'
/// escape-on-write round-trips without double-escaping.
fn decodeOwned(allocator: std.mem.Allocator, raw: []const u8) std.mem.Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, raw, '\\') == null) return allocator.dupe(u8, raw);
    // Count decoded length first so the returned buffer is exactly sized (a
    // realloc'd sub-slice would mismatch the allocation length on free).
    var n: usize = 0;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '\\' and i + 1 < raw.len) i += 1;
        n += 1;
    }
    const out = try allocator.alloc(u8, n);
    var w: usize = 0;
    i = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '\\' and i + 1 < raw.len) i += 1;
        out[w] = raw[i];
        w += 1;
    }
    return out;
}

/// Load a .bom sidecar file and return the entries.
/// Returns empty slice if file does not exist.
pub fn loadBom(allocator: std.mem.Allocator, bom_path: []const u8) BomError![]const BomEntry {
    const source = infra_fs.cwd().readFileAlloc(allocator, bom_path, 4 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer allocator.free(source);

    const nodes = parser_mod.parse(allocator, source) catch return &.{};
    defer parser_mod.freeNodes(allocator, nodes);

    var entries: std.ArrayList(BomEntry) = .empty;
    errdefer entries.deinit(allocator);

    for (nodes) |node| {
        if (!node.isForm("part")) continue;
        const children = node.asList() orelse continue;
        if (children.len < 3) continue;

        const ref_des = children[1].asString() orelse continue;
        const uuid = children[2].asString() orelse continue;
        // Third positional arg (component) is optional for backwards compat
        const component = if (children.len >= 4 and children[3].asString() != null) (children[3].asString() orelse "") else "";
        const has_component = children.len >= 4 and children[3].asString() != null;

        // Parse sub-forms: (id "..."), (key "val"), ...
        var entry_id: []const u8 = "";
        var props: std.ArrayList(Property) = .empty;
        var entry_nets: std.ArrayList([]const u8) = .empty;
        const start_idx: usize = if (has_component) 4 else 3;
        if (children.len > start_idx) {
            for (children[start_idx..]) |prop_node| {
                const prop_children = prop_node.asList() orelse continue;
                if (prop_children.len < 2) continue;
                const key = prop_children[0].asAtom() orelse continue;
                if (std.mem.eql(u8, key, "nets")) {
                    for (prop_children[1..]) |net_node| {
                        const net_str = net_node.asString() orelse continue;
                        try entry_nets.append(allocator, try decodeOwned(allocator, net_str));
                    }
                    continue;
                }
                const value = prop_children[1].asString() orelse continue;
                if (std.mem.eql(u8, key, "footprint")) {
                    continue;
                } else if (std.mem.eql(u8, key, "id")) {
                    entry_id = try allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "value")) {
                    continue;
                } else {
                    try props.append(allocator, .{
                        .key = try allocator.dupe(u8, key),
                        .value = try decodeOwned(allocator, value),
                    });
                }
            }
        }

        try entries.append(allocator, .{
            .ref_des = try decodeOwned(allocator, ref_des),
            .uuid = try allocator.dupe(u8, uuid),
            .component = if (component.len > 0) try decodeOwned(allocator, component) else "",
            .properties = props.toOwnedSlice(allocator) catch &.{},
            .id = entry_id,
            .nets = entry_nets.toOwnedSlice(allocator) catch &.{},
        });
    }

    return entries.toOwnedSlice(allocator);
}

/// Collect all flat instances from a design block hierarchy.
pub const FlatInfo = struct {
    ref_des: []const u8,
    component: []const u8,
    footprint: []const u8,
    value: []const u8,
    attrs: []const []const u8,
    nets: []const []const u8,
    properties: []const Property,
    id: []const u8 = "",
    /// Do Not Populate — carried from the source instance's `(dnp)` flag so the
    /// BOM can mark the row and drop it from the populated-part tally.
    dnp: bool = false,
};

/// Walk a design block and append a flat `FlatInfo` per instance into `list`,
/// recursing into sub-blocks with `prefix` joined onto the ref-des path so
/// every instance is uniquely identified across the hierarchy.
pub fn collectFlatInstances(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    prefix: []const u8,
    list: *std.ArrayList(FlatInfo),
    ref_style: env_mod.RefStyle,
) std.mem.Allocator.Error!void {
    var net_map = std.StringHashMapUnmanaged(std.ArrayList([]const u8)).empty;
    defer {
        var it = net_map.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        net_map.deinit(allocator);
    }
    for (block.nets) |net| {
        for (net.pins) |pin| {
            const gop = try net_map.getOrPut(allocator, pin.ref_des);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(allocator, net.name);
        }
    }

    for (block.instances) |inst| {
        // Grouped-refdes makes ref-deses globally unique → drop the redundant
        // sub-block path prefix so the BOM key is the bare `R1_1`, not `a/R1_1`.
        const ref = if (prefix.len > 0 and ref_style == .hierarchical)
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
            .dnp = inst.dnp,
        });
    }
    for (block.sub_blocks) |sb| {
        const sub_prefix = if (prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, sb.name })
        else
            try allocator.dupe(u8, sb.name);
        try collectFlatInstances(allocator, sb.block, sub_prefix, list, ref_style);
    }
}

/// Generate a v4 UUID string (lowercase hex with dashes).
pub fn generateUuid(allocator: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
    var bytes: [16]u8 = undefined;
    infra_random.bytes(&bytes);
    bytes[UUID_VERSION_BYTE] = (bytes[UUID_VERSION_BYTE] & 0x0f) | 0x40;
    bytes[UUID_VARIANT_BYTE] = (bytes[UUID_VARIANT_BYTE] & 0x3f) | 0x80;

    return std.fmt.allocPrint(allocator, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}" ++
        "-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
        bytes[0],                 bytes[1],            bytes[2],                 bytes[3],
        bytes[4],                 bytes[UUID_BYTE_5],  bytes[UUID_VERSION_BYTE], bytes[UUID_BYTE_7],
        bytes[UUID_VARIANT_BYTE], bytes[UUID_BYTE_9],  bytes[UUID_BYTE_10],      bytes[UUID_BYTE_11],
        bytes[UUID_BYTE_12],      bytes[UUID_BYTE_13], bytes[UUID_BYTE_14],      bytes[UUID_BYTE_15],
    });
}

/// Jaccard-style overlap of two net lists in [0, 1]: `|a ∩ b| / |a ∪ b|`.
/// Returns 1.0 when both are empty, 0.0 when exactly one is empty.
pub fn netOverlap(a: []const []const u8, b: []const []const u8) f64 {
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
) BomError!void {
    const bom_path = try paths.designSiblingPath(allocator, project_dir, design_name, ".bom");
    defer allocator.free(bom_path);

    const entries = try loadBom(allocator, bom_path);
    if (entries.len == 0) return;

    // Build ref_des → uuid map. `.bom` keys for sub-block parts are
    // hierarchical (`buck/C3`), so uuids must be matched against the same
    // prefixed key — matching on the child's bare ref_des applied a top-level
    // `C3`'s uuid to every same-named sub-block twin (duplicate identities).
    var uuid_map = std.StringHashMapUnmanaged([]const u8).empty;
    defer uuid_map.deinit(allocator);
    for (entries) |entry| {
        if (entry.uuid.len > 0) {
            try uuid_map.put(allocator, entry.ref_des, entry.uuid);
        }
    }

    applyBomUuidsRec(block, &uuid_map, allocator, "");
}

/// Apply the ref_des→uuid map through the block hierarchy, threading the
/// `sub-block/…` prefix so hierarchical `.bom` keys line up (mirrors
/// `bom_resolve.applyBom`'s prefix threading).
fn applyBomUuidsRec(
    block: *const DesignBlock,
    uuid_map: *const std.StringHashMapUnmanaged([]const u8),
    allocator: std.mem.Allocator,
    prefix: []const u8,
) void {
    // Apply to instances (uses @constCast — safe because block was just allocated)
    const instances: []Instance = @constCast(block.instances);
    for (instances) |*inst| {
        const key = if (prefix.len > 0)
            (std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, inst.ref_des }) catch continue)
        else
            inst.ref_des;
        defer if (prefix.len > 0) allocator.free(key);
        if (uuid_map.get(key)) |uuid| {
            inst.uuid = uuid;
        }
    }
    for (block.sub_blocks) |sb| {
        const child_prefix = if (prefix.len > 0)
            (std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, sb.name }) catch continue)
        else
            sb.name;
        defer if (prefix.len > 0) allocator.free(child_prefix);
        applyBomUuidsRec(sb.block, uuid_map, allocator, child_prefix);
    }
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
