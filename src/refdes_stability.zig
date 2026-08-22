//! Preserve automatically assigned reference designators across evaluations.
//!
//! The generated BOM records `(stable id, flattened ref-des)` for every part.
//! On the next evaluation this module reuses the prior leaf ref-des for the
//! same stable id, then moves genuinely new/conflicting parts above the known
//! range. Full hierarchy paths remain a flattening concern; assignments inside
//! the design tree are globally unique leaf names.

const std = @import("std");
const env = @import("eval/env.zig");
const ids = @import("eval/ids.zig");
const net_name = @import("net_name.zig");

/// A stable component identity and its reference designator from the prior BOM.
pub const Prior = struct { id: []const u8, ref_des: []const u8 };

const Parsed = struct {
    leaf: []const u8,
    prefix: []const u8,
    number: u32,
};

const Live = struct {
    inst: *env.Instance,
    depth: usize,
    prior: ?Parsed = null,
    current: Parsed,
};

// Evaluation arenas own mutable storage but expose their finalized slices as
// read-only. Refdes reconciliation is the one controlled post-evaluation pass
// that updates those records before any flattened views are created.
fn mutable(comptime T: type, items: []const T) []T {
    return @constCast(items);
}

fn parse(ref_des: []const u8) ?Parsed {
    const local = net_name.leaf(ref_des);
    var digit: usize = 0;
    while (digit < local.len and std.ascii.isUpper(local[digit])) : (digit += 1) {}
    if (digit == 0 or digit == local.len) return null;
    const number = std.fmt.parseInt(u32, local[digit..], 10) catch return null;
    return .{ .leaf = local, .prefix = local[0..digit], .number = number };
}

fn collectLive(allocator: std.mem.Allocator, block: *const env.DesignBlock, depth: usize, out: *std.ArrayList(Live)) !void {
    for (mutable(env.Instance, block.instances)) |*inst| {
        const current = parse(inst.ref_des) orelse continue;
        try out.append(allocator, .{ .inst = inst, .depth = depth, .current = current });
    }
    for (mutable(env.SubBlock, block.sub_blocks)) |*sub| {
        try collectLive(allocator, sub.block, depth + 1, out);
    }
}

fn autoManaged(live: Live) bool {
    // A standard ref authored at the design root is an explicit user choice;
    // changing it must override history. Descriptive/shorthand roots and every
    // sub-block leaf are allocator-owned and therefore safe to stabilize.
    return live.depth > 0 or live.inst.origin_key.len == 0 or !ids.isStandardRefDes(live.inst.origin_key);
}

fn noteMax(allocator: std.mem.Allocator, maxima: *std.StringHashMapUnmanaged(u32), parsed: Parsed) !void {
    const gop = try maxima.getOrPut(allocator, parsed.prefix);
    if (!gop.found_existing or parsed.number > gop.value_ptr.*) gop.value_ptr.* = parsed.number;
}

fn nextFresh(
    allocator: std.mem.Allocator,
    prefix: []const u8,
    maxima: *std.StringHashMapUnmanaged(u32),
    used: *std.StringHashMapUnmanaged(void),
) ![]const u8 {
    var number = (maxima.get(prefix) orelse 0) + 1;
    while (true) : (number += 1) {
        const candidate = try std.fmt.allocPrint(allocator, "{s}{d}", .{ prefix, number });
        if (used.contains(candidate)) {
            allocator.free(candidate);
            continue;
        }
        try maxima.put(allocator, prefix, number);
        return candidate;
    }
}

fn mapped(map: *const std.StringHashMapUnmanaged([]const u8), value: []const u8) []const u8 {
    return map.get(value) orelse value;
}

fn renameNet(allocator: std.mem.Allocator, name: []const u8, map: *std.StringHashMapUnmanaged([]const u8)) ![]const u8 {
    var it = map.iterator();
    while (it.next()) |entry| {
        const old = entry.key_ptr.*;
        const token = try std.fmt.allocPrint(allocator, ".{s}.", .{old});
        defer allocator.free(token);
        const pos = std.mem.indexOf(u8, name, token) orelse continue;
        const replacement = try std.fmt.allocPrint(allocator, ".{s}.", .{entry.value_ptr.*});
        defer allocator.free(replacement);
        return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ name[0..pos], replacement, name[pos + token.len ..] });
    }
    return name;
}

fn renameSections(sections: []env.Section, map: *const std.StringHashMapUnmanaged([]const u8)) void {
    for (sections) |*section| {
        for (mutable(env.Instance, section.instances)) |*inst| inst.ref_des = mapped(map, inst.ref_des);
        for (mutable(env.PinGroup, section.pin_groups)) |*group| group.ref_des = mapped(map, group.ref_des);
        renameSections(mutable(env.Section, section.sub_sections), map);
    }
}

fn renameReferences(
    allocator: std.mem.Allocator,
    block: *const env.DesignBlock,
    map: *std.StringHashMapUnmanaged([]const u8),
) !void {
    for (mutable(env.Net, block.nets)) |*net| {
        for (mutable(env.PinRef, net.pins)) |*pin| pin.ref_des = mapped(map, pin.ref_des);
        net.name = try renameNet(allocator, net.name, map);
    }
    for (mutable(env.Note, block.notes)) |*note| note.ref_des = mapped(map, note.ref_des);
    for (mutable(env.Instance, block.instances)) |*inst| {
        inst.bind.decouple.ic = mapped(map, inst.bind.decouple.ic);
        inst.bind.near.ref = mapped(map, inst.bind.near.ref);
    }
    for (mutable(env.Group, block.groups)) |*group| {
        for (mutable([]const u8, group.members)) |*member| member.* = mapped(map, member.*);
    }
    for (mutable(env.TestPoint, block.test_points)) |*point| point.ref_des = mapped(map, point.ref_des);
    for (mutable(env.Verification, block.verifications)) |*verification| {
        verification.ref_des = mapped(map, verification.ref_des);
    }
    renameSections(mutable(env.Section, block.sections), map);
    for (mutable(env.SubBlock, block.sub_blocks)) |*sub| try renameReferences(allocator, sub.block, map);
}

/// Reuse prior ref-des leaves by stable ID. The first run has no priors and is
/// deliberately a no-op; its generated BOM becomes the annotation ledger for
/// every subsequent run.
pub fn apply(allocator: std.mem.Allocator, block: *const env.DesignBlock, priors: []const Prior) std.mem.Allocator.Error!void {
    if (priors.len == 0) return;

    var prior_by_id = std.StringHashMapUnmanaged(Parsed).empty;
    defer prior_by_id.deinit(allocator);
    var maxima = std.StringHashMapUnmanaged(u32).empty;
    defer maxima.deinit(allocator);
    for (priors) |prior| {
        if (prior.id.len == 0) continue;
        const parsed = parse(prior.ref_des) orelse continue;
        try prior_by_id.put(allocator, prior.id, parsed);
        try noteMax(allocator, &maxima, parsed);
    }

    var lives: std.ArrayList(Live) = .empty;
    defer lives.deinit(allocator);
    try collectLive(allocator, block, 0, &lives);
    for (lives.items) |*live| {
        const prior = prior_by_id.get(live.inst.id) orelse continue;
        if (autoManaged(live.*) and std.mem.eql(u8, prior.prefix, live.current.prefix)) live.prior = prior;
    }

    var prior_counts = std.StringHashMapUnmanaged(u32).empty;
    defer prior_counts.deinit(allocator);
    for (lives.items) |live| if (live.prior) |prior| {
        const gop = try prior_counts.getOrPut(allocator, prior.leaf);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    };

    var used = std.StringHashMapUnmanaged(void).empty;
    defer used.deinit(allocator);
    const assignments = try allocator.alloc(?[]const u8, lives.items.len);
    defer allocator.free(assignments);
    @memset(assignments, null);

    // Existing stable owners reserve their old labels before any new part can
    // keep a coincident provisional number.
    for (lives.items, 0..) |live, index| if (live.prior) |prior| {
        if ((prior_counts.get(prior.leaf) orelse 0) != 1 or used.contains(prior.leaf)) continue;
        const stable_leaf = try allocator.dupe(u8, prior.leaf);
        assignments[index] = stable_leaf;
        try used.put(allocator, stable_leaf, {});
    };

    // Unchanged/non-conflicting provisional labels remain readable and reserve
    // their names before conflicts are assigned.
    for (lives.items, 0..) |live, index| {
        if (assignments[index] != null) continue;
        if (used.contains(live.current.leaf)) continue;
        assignments[index] = live.current.leaf;
        try used.put(allocator, live.current.leaf, {});
        try noteMax(allocator, &maxima, live.current);
    }

    // A new part that temporarily took an old label moves above the labels
    // which have actual stable or current owners.
    for (lives.items, 0..) |live, index| {
        if (assignments[index] != null) continue;
        const fresh = try nextFresh(allocator, live.current.prefix, &maxima, &used);
        assignments[index] = fresh;
        try used.put(allocator, fresh, {});
    }

    var rename_map = std.StringHashMapUnmanaged([]const u8).empty;
    defer rename_map.deinit(allocator);
    for (lives.items, assignments) |live, assigned_opt| {
        const assigned = assigned_opt orelse continue;
        if (!std.mem.eql(u8, live.current.leaf, assigned)) try rename_map.put(allocator, live.current.leaf, assigned);
    }
    if (rename_map.count() == 0) return;
    for (lives.items, assignments) |live, assigned| live.inst.ref_des = assigned orelse live.inst.ref_des;
    try renameReferences(allocator, block, &rename_map);
}

fn testBlock(instances: []env.Instance, nets: []env.Net, sub_blocks: []env.SubBlock) env.DesignBlock {
    return .{ .name = "test", .instances = instances, .nets = nets, .ports = &.{}, .notes = &.{}, .groups = &.{}, .sub_blocks = sub_blocks };
}

fn testInstance(ref_des: []const u8, origin_key: []const u8, id: []const u8) env.Instance {
    return .{
        .ref_des = ref_des,
        .origin_key = origin_key,
        .id = id,
        .component = "cap",
        .value = "100nF",
        .footprint = "0402",
        .symbol = "Device:C",
    };
}

// spec: bom-resolve - automatically assigned refdes reuse the prior BOM label by stable ID while newly inserted parts take numbers above the prior range
test "stable refdes keeps old IDs and assigns an inserted capacitor above the prior range" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    var instances = [_]env.Instance{
        testInstance("C1", "C_NEW", "new00001"),
        testInstance("C2", "C_OLD_A", "old00001"),
        testInstance("C3", "C_OLD_B", "old00002"),
    };
    var pins = [_]env.PinRef{ .{ .ref_des = "C1", .pin = "1" }, .{ .ref_des = "C2", .pin = "1" }, .{ .ref_des = "C3", .pin = "1" } };
    var nets = [_]env.Net{.{ .name = "N", .pins = &pins }};
    var block = testBlock(&instances, &nets, &.{});
    try apply(allocator, &block, &.{
        .{ .id = "old00001", .ref_des = "power/C1" },
        .{ .id = "old00002", .ref_des = "power/C2" },
    });
    try std.testing.expectEqualStrings("C3", instances[0].ref_des);
    try std.testing.expectEqualStrings("C1", instances[1].ref_des);
    try std.testing.expectEqualStrings("C2", instances[2].ref_des);
    try std.testing.expectEqualStrings("C3", pins[0].ref_des);
    try std.testing.expectEqualStrings("C1", pins[1].ref_des);
    try std.testing.expectEqualStrings("C2", pins[2].ref_des);
}

test "stable refdes respects an explicit root rename but stabilizes sub-block leaves" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    var root_instances = [_]env.Instance{testInstance("C9", "C9", "root0001")};
    var child_instances = [_]env.Instance{testInstance("C10", "C1", "child001")};
    var child = testBlock(&child_instances, &.{}, &.{});
    var subs = [_]env.SubBlock{.{ .name = "power", .block = &child }};
    var block = testBlock(&root_instances, &.{}, &subs);
    try apply(allocator, &block, &.{
        .{ .id = "root0001", .ref_des = "C1" },
        .{ .id = "child001", .ref_des = "power/C7" },
    });
    try std.testing.expectEqualStrings("C9", root_instances[0].ref_des);
    try std.testing.expectEqualStrings("C7", child_instances[0].ref_des);
}
