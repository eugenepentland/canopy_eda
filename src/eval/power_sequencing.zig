//! Power-sequencing analysis: derives the rail power-up order from the design's
//! rail dependencies and enable relationships, producing the `SequenceRow`s
//! shown in the review's power-sequence panel. Read-only over the design.

const std = @import("std");
const env_mod = @import("env.zig");
const na = @import("net_analysis.zig");
const DesignBlock = env_mod.DesignBlock;

const SUB_PATH_BUF_LEN: usize = 256;

/// Resolution status for one rail's `(enable …)` declaration. `ok` means
/// the enable net traces back to a known upstream rail; `unresolved` flags
/// dangling enables a debugger needs to look at; `always_on` marks rails
/// with no enable that come up unconditionally.
pub const SequenceStatus = enum {
    /// Enable is tied to a known rail (another regulator's output).
    ok,
    /// `(enable "NET")` was declared but that net never appears as a
    /// sub-block output — the regulator would power on unconditionally.
    unresolved,
    /// No `(enable …)` declared on an output port. Not an error (plenty of
    /// rails are always-on), but highlighted so the sequencing is obvious.
    always_on,
};

/// One row in the power-sequencing table: a regulator-sourced rail plus
/// the upstream rail it depends on (resolved through `(enable …)` and any
/// PG signal in the way) and its computed turn-on `order` for top-down
/// reading.
pub const SequenceRow = struct {
    /// Top-level rail name this regulator sources (e.g. "V1P8").
    rail: []const u8,
    /// Sub-block label sourcing the rail (e.g. "ldo").
    source: []const u8,
    /// Net/port that gates this rail on. Empty when `always_on`.
    enable: []const u8 = "",
    /// Rail that `enable` sits on — i.e. the upstream regulator's output.
    /// Empty when `unresolved` or `always_on`.
    depends_on: []const u8 = "",
    /// Intermediate signal when the enable routes through a non-rail signal
    /// like a regulator's PG (power-good) pin. Example: LDO's EN is tied to
    /// PG_3V3, which is driven by buck/PG; `depends_on` becomes VDD (buck's
    /// main rail), and `via` becomes "PG_3V3". Empty when resolution was
    /// direct.
    via: []const u8 = "",
    /// Computed turn-on order, 0 = first to power up.
    order: u32 = 0,
    status: SequenceStatus,
};

/// Walk `block.sub_blocks` output ports and emit one row per rail. The row
/// says which rail gates this one, so the reviewer reads top-down to see
/// power-up order. Ordering is a topological sort over the enable-edges;
/// ties broken by rail name for stability.
///
/// Slice and string fields reference allocations via `allocator` plus strings
/// owned by `block`; caller owns the returned slice.
pub fn analyze(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
) std.mem.Allocator.Error![]const SequenceRow {
    // Map each sub-block output port path ("ldo/VOUT") to the top-level rail
    // it's tied to. `sub_to_rail` drives both row construction and rail-name
    // validation for enable resolution.
    var sub_to_rail: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer sub_to_rail.deinit(allocator);
    for (block.net_ties) |nt| {
        if (std.mem.indexOfScalar(u8, nt.a, '/')) |_| {
            try sub_to_rail.put(allocator, nt.a, na.baseNetName(nt.b));
        } else if (std.mem.indexOfScalar(u8, nt.b, '/')) |_| {
            try sub_to_rail.put(allocator, nt.b, na.baseNetName(nt.a));
        }
    }

    // `primary_rail_of[sb_name]` = that sub-block's power-output rail (e.g.
    // buck → VDD). Used to map a PG signal back to the rail whose stability
    // actually drives it. A sub-block can declare multiple power outputs;
    // we take the first declaration order (rare to have more than one).
    var primary_rail_of: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer primary_rail_of.deinit(allocator);
    // `signal_source[net]` = sub-block driving that top-level net via a
    // non-power output (e.g. PG_3V3 → "buck"). Used to translate a PG-style
    // enable into the underlying rail.
    var signal_source: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer signal_source.deinit(allocator);
    // `power_rail_set` = top-level rails that are actually sourced by a
    // power output (not signal/PG). These are the "known power rails" for
    // enable validation.
    var power_rail_set: std.StringHashMapUnmanaged(void) = .empty;
    defer power_rail_set.deinit(allocator);

    var path_buf: [SUB_PATH_BUF_LEN]u8 = undefined;
    for (block.sub_blocks) |sb| {
        for (sb.block.ports) |port| {
            if (!std.mem.eql(u8, port.direction, "out")) continue;
            const out_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ sb.name, port.name }) catch continue;
            const rail = sub_to_rail.get(out_path) orelse continue;
            if (port.isPowerSource()) {
                if (!primary_rail_of.contains(sb.name)) {
                    try primary_rail_of.put(allocator, sb.name, rail);
                }
                try power_rail_set.put(allocator, rail, {});
            } else {
                try signal_source.put(allocator, rail, sb.name);
            }
        }
    }

    var rows: std.ArrayListUnmanaged(SequenceRow) = .empty;
    for (block.sub_blocks) |sb| {
        for (sb.block.ports) |port| {
            if (!std.mem.eql(u8, port.direction, "out")) continue;
            if (!port.isPowerSource()) continue;

            const out_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ sb.name, port.name }) catch continue;
            const rail = sub_to_rail.get(out_path) orelse continue;

            if (port.enable_net.len == 0) {
                try rows.append(allocator, .{
                    .rail = rail,
                    .source = sb.name,
                    .status = .always_on,
                });
                continue;
            }

            const resolved = resolveEnable(block, &power_rail_set, &signal_source, &primary_rail_of, sb.name, port.enable_net);
            try rows.append(allocator, .{
                .rail = rail,
                .source = sb.name,
                .enable = port.enable_net,
                .depends_on = resolved.depends_on,
                .via = resolved.via,
                .status = if (resolved.depends_on.len > 0) .ok else .unresolved,
            });
        }
    }

    assignOrder(rows.items);
    std.mem.sort(SequenceRow, rows.items, {}, lessThanRow);
    // Ownership contract (doc comment + the tests' `alloc.free(rows)`): return
    // an exact-length owned slice, not `.items` — `.items` is a sub-slice of a
    // capacity-padded allocation, so a non-arena caller's `free` is size-
    // mismatched and can't reclaim the slack.
    return rows.toOwnedSlice(allocator);
}

const Resolution = struct {
    /// Power rail this enable ultimately depends on. Empty when unresolved.
    depends_on: []const u8 = "",
    /// Intermediate signal net when the enable routes through a PG/signal
    /// output. Empty for direct rail-to-rail dependencies.
    via: []const u8 = "",
};

/// Resolve an `(enable "...")` on sub-block `sb_name`'s output port to a
/// power rail. Strategy:
///   1. Find the top-level net the sub-block's `enable_name` port is tied
///      to (e.g. ldo/EN → "PG_3V3"; buck/VIN → "VBATT").
///   2. If that net is itself a power rail → depends_on = net.
///   3. Else if the net is driven by another sub-block's signal output
///      (e.g. buck/PG drives PG_3V3), look up that sub-block's primary
///      power rail → depends_on = that rail, via = the signal net.
///   4. Otherwise unresolved.
fn resolveEnable(
    block: *const DesignBlock,
    power_rails: *const std.StringHashMapUnmanaged(void),
    signal_source: *const std.StringHashMapUnmanaged([]const u8),
    primary_rail_of: *const std.StringHashMapUnmanaged([]const u8),
    sb_name: []const u8,
    enable_name: []const u8,
) Resolution {
    var path_buf: [SUB_PATH_BUF_LEN]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ sb_name, enable_name }) catch return .{};
    var target: []const u8 = "";
    for (block.net_ties) |nt| {
        if (std.mem.eql(u8, nt.a, path)) {
            target = na.baseNetName(nt.b);
            break;
        }
        if (std.mem.eql(u8, nt.b, path)) {
            target = na.baseNetName(nt.a);
            break;
        }
    }
    if (target.len == 0) target = na.baseNetName(enable_name);

    if (power_rails.contains(target)) return .{ .depends_on = target };

    if (signal_source.get(target)) |driving_sb| {
        if (primary_rail_of.get(driving_sb)) |rail| {
            return .{ .depends_on = rail, .via = target };
        }
    }
    return .{};
}

fn assignOrder(rows: []SequenceRow) void {
    // Up to 8 passes — more than any real power tree. On each pass a row's
    // order becomes 1 + the highest order of any row it depends on.
    var iter: u32 = 0;
    while (iter < 8) : (iter += 1) {
        var changed = false;
        for (rows) |*r| {
            if (r.depends_on.len == 0) continue;
            var max_dep: u32 = 0;
            for (rows) |d| {
                if (!std.mem.eql(u8, d.rail, r.depends_on)) continue;
                if (d.order >= max_dep) max_dep = d.order;
            }
            const wanted = max_dep + 1;
            if (r.order != wanted) {
                r.order = wanted;
                changed = true;
            }
        }
        if (!changed) break;
    }
}

fn lessThanRow(_: void, a: SequenceRow, b: SequenceRow) bool {
    if (a.order != b.order) return a.order < b.order;
    return std.mem.order(u8, a.rail, b.rail) == .lt;
}

// ── Tests ──────────────────────────────────────────────────────────────

// spec: eval/power_sequencing - Emits one always_on row per sub-block output with no enable
test "analyze marks rail with no enable as always_on" {
    const alloc = std.testing.allocator;
    var inner: DesignBlock = .{
        .name = "buck",
        .instances = &.{},
        .nets = &.{},
        .ports = &[_]env_mod.Port{.{ .name = "VOUT", .net = "VOUT", .direction = "out", .nominal = 3.3 }},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    const sbs = [_]env_mod.SubBlock{.{ .name = "buck", .block = &inner }};
    const ties = [_]env_mod.NetTie{.{ .a = "buck/VOUT", .b = "VDD" }};
    const outer: DesignBlock = .{
        .name = "outer",
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &sbs,
        .net_ties = &ties,
    };
    const rows = try analyze(alloc, &outer);
    defer alloc.free(rows);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqual(SequenceStatus.always_on, rows[0].status);
    try std.testing.expectEqualStrings("VDD", rows[0].rail);
}

// spec: eval/power_sequencing - Orders dependent rail after its enable source
test "analyze orders dependent rail after enable source" {
    const alloc = std.testing.allocator;
    var buck: DesignBlock = .{
        .name = "buck",
        .instances = &.{},
        .nets = &.{},
        .ports = &[_]env_mod.Port{.{ .name = "VOUT", .net = "VOUT", .direction = "out", .nominal = 3.3 }},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    var ldo: DesignBlock = .{
        .name = "ldo",
        .instances = &.{},
        .nets = &.{},
        .ports = &[_]env_mod.Port{.{
            .name = "VOUT",
            .net = "VOUT",
            .direction = "out",
            .nominal = 1.8,
            .enable_net = "VDD",
        }},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    const sbs = [_]env_mod.SubBlock{
        .{ .name = "buck", .block = &buck },
        .{ .name = "ldo", .block = &ldo },
    };
    const ties = [_]env_mod.NetTie{
        .{ .a = "buck/VOUT", .b = "VDD" },
        .{ .a = "ldo/VOUT", .b = "V1P8" },
    };
    const outer: DesignBlock = .{
        .name = "outer",
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &sbs,
        .net_ties = &ties,
    };
    const rows = try analyze(alloc, &outer);
    defer alloc.free(rows);
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqualStrings("VDD", rows[0].rail);
    try std.testing.expectEqual(@as(u32, 0), rows[0].order);
    try std.testing.expectEqualStrings("V1P8", rows[1].rail);
    try std.testing.expectEqual(@as(u32, 1), rows[1].order);
    try std.testing.expectEqualStrings("VDD", rows[1].depends_on);
    try std.testing.expectEqual(SequenceStatus.ok, rows[1].status);
}

// spec: eval/power_sequencing - Flags enable that never resolves to a known rail
test "analyze flags unresolved when depends_on rail does not exist" {
    const alloc = std.testing.allocator;
    var ldo: DesignBlock = .{
        .name = "ldo",
        .instances = &.{},
        .nets = &.{},
        .ports = &[_]env_mod.Port{.{
            .name = "VOUT",
            .net = "VOUT",
            .direction = "out",
            .nominal = 1.8,
            .enable_net = "NOWHERE",
        }},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    const sbs = [_]env_mod.SubBlock{.{ .name = "ldo", .block = &ldo }};
    const ties = [_]env_mod.NetTie{.{ .a = "ldo/VOUT", .b = "V1P8" }};
    const outer: DesignBlock = .{
        .name = "outer",
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &sbs,
        .net_ties = &ties,
    };
    const rows = try analyze(alloc, &outer);
    defer alloc.free(rows);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqual(SequenceStatus.unresolved, rows[0].status);
    try std.testing.expectEqualStrings("", rows[0].depends_on);
}

// spec: eval/power_sequencing - Routes enable through PG signal to source rail
test "analyze routes enable through PG signal to source rail" {
    const alloc = std.testing.allocator;
    var buck: DesignBlock = .{
        .name = "buck",
        .instances = &.{},
        .nets = &.{},
        .ports = &[_]env_mod.Port{
            .{ .name = "VOUT", .net = "VOUT", .direction = "out", .nominal = 3.3 },
            .{ .name = "PG", .net = "PG", .direction = "out" },
        },
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    var ldo: DesignBlock = .{
        .name = "ldo",
        .instances = &.{},
        .nets = &.{},
        .ports = &[_]env_mod.Port{.{
            .name = "VOUT",
            .net = "VOUT",
            .direction = "out",
            .nominal = 1.8,
            .enable_net = "EN",
        }},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    const sbs = [_]env_mod.SubBlock{
        .{ .name = "buck", .block = &buck },
        .{ .name = "ldo", .block = &ldo },
    };
    const ties = [_]env_mod.NetTie{
        .{ .a = "buck/VOUT", .b = "VDD" },
        .{ .a = "buck/PG", .b = "PG_3V3" },
        .{ .a = "ldo/VOUT", .b = "V1P8" },
        .{ .a = "ldo/EN", .b = "PG_3V3" },
    };
    const outer: DesignBlock = .{
        .name = "outer",
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &sbs,
        .net_ties = &ties,
    };
    const rows = try analyze(alloc, &outer);
    defer alloc.free(rows);
    // Only power outputs get rows — buck/VOUT and ldo/VOUT. buck/PG is
    // signal-only, used only to route the enable.
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqualStrings("VDD", rows[0].rail);
    try std.testing.expectEqual(SequenceStatus.always_on, rows[0].status);
    try std.testing.expectEqualStrings("V1P8", rows[1].rail);
    try std.testing.expectEqual(SequenceStatus.ok, rows[1].status);
    try std.testing.expectEqualStrings("VDD", rows[1].depends_on);
    try std.testing.expectEqualStrings("PG_3V3", rows[1].via);
}
