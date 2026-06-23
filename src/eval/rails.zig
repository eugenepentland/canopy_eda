const std = @import("std");
const env_mod = @import("env.zig");
const na = @import("net_analysis.zig");
const DesignBlock = env_mod.DesignBlock;
const PowerRail = env_mod.PowerRail;
const Port = env_mod.Port;

// ── Constants ─────────────────────────────────────────────────────
const RATING_MIDPOINT: f64 = 0.5;
const GND_NAME: []const u8 = "GND";
const SUB_PATH_BUF_LEN: usize = 256;
/// Sentinel for "no existing capacity declared" — picked so any real
/// declared capacity (>= 0) wins the multi-source tie-break.
const SENTINEL_CAP: f64 = 1.0;

/// Walk `block.sub_blocks` output ports and emit one `PowerRail` per declared
/// source. Ferrite-bead-bridged nets collapse into a single rail by
/// union-find; the source-side name becomes `rail.name`, the downstream
/// bridged names land in `rail.aliases`.
///
/// Voltage resolution falls back through three sources, in order:
///   1. The sub-block output port's `nominal`.
///   2. A section-level power port declaring the same rail name + voltage.
///   3. A top-level design port's `nominal` or `(rated min max)` midpoint.
///
/// GND is excluded from the result. When a design declares no rails (no
/// sub-block output port with declared current capacity), the returned slice
/// is empty.
///
/// The returned slice is owned by the caller's allocator. String fields
/// reference data owned by `block` or freshly allocated paths.
pub fn build(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
) std.mem.Allocator.Error![]const PowerRail {
    // Step 1: union-find on ferrite-bead-bridged nets. A ferrite is a DC
    // conductor: loads on its downstream side belong to the upstream rail.
    var net_parent: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer net_parent.deinit(allocator);
    for (block.instances) |inst| {
        if (!std.mem.startsWith(u8, inst.component, "ferrite")) continue;
        var net_a: ?[]const u8 = null;
        var net_b: ?[]const u8 = null;
        for (block.nets) |net| {
            const base = na.baseNetName(net.name);
            for (net.pins) |p| {
                if (!std.mem.eql(u8, p.ref_des, inst.ref_des)) continue;
                if (std.mem.eql(u8, p.pin, "1")) net_a = base;
                if (std.mem.eql(u8, p.pin, "2")) net_b = base;
            }
        }
        if (net_a != null and net_b != null) try unionNets(allocator, &net_parent, net_a.?, net_b.?);
    }

    // Step 2: derive one rail per sub-block output port marked as a power
    // source (direction=out + has declared current capacity). On a multi-
    // source rail (e.g. battery + charger both on VBATT), the higher-
    // capacity declaration wins so output is independent of declaration
    // order.
    var by_root: std.StringHashMapUnmanaged(PowerRail) = .empty;
    defer by_root.deinit(allocator);
    var path_buf: [SUB_PATH_BUF_LEN]u8 = undefined;
    for (block.sub_blocks) |sb| {
        for (sb.block.ports) |port| {
            if (!std.mem.eql(u8, port.direction, "out")) continue;

            const path_temp = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ sb.name, port.name }) catch continue;
            const top_net = findTopNet(block, path_temp) orelse continue;
            const base = na.baseNetName(top_net);
            if (std.mem.eql(u8, base, GND_NAME)) continue;
            const root = findRoot(&net_parent, base);
            if (std.mem.eql(u8, root, GND_NAME)) continue;

            // A rail source is an output port that either declares power specs
            // OR is tied to a net that reads like a supply rail. The name path
            // lets a bare `(port "VOUT" out)` on a generic buck/LDO/OR module
            // register its rail (VDD5, VDD3V3, VPWR_IN_RAW): without it the
            // supply tree loses its trunk and only spec-annotated leaf rails
            // survive. Electrical specs stay enrichment for the budget, not a
            // gate on recognition.
            if (!port.isPowerSource() and !looksLikeRail(base)) continue;

            const nominal = port.nominal orelse resolveRailVoltage(block, base);
            const existing_cap = if (by_root.get(root)) |existing|
                (existing.capacity_max orelse existing.capacity_typ orelse 0)
            else
                -SENTINEL_CAP;
            const incoming_cap = port.current_max orelse port.current_typ orelse 0;
            if (incoming_cap <= existing_cap) continue;

            // Allocate the persistent path only when we're keeping the rail.
            const path = try allocator.dupe(u8, path_temp);
            const incoming = PowerRail{
                .name = base,
                .nominal = nominal,
                .source_ref_des = sb.name,
                .source_port = port.name,
                .source_path = path,
                .capacity_typ = port.current_typ,
                .capacity_max = port.current_max,
                .enable_net = port.enable_net,
            };

            // Replacing an existing entry on a multi-source rail: free its
            // path before overwriting so we don't leak the loser.
            if (by_root.fetchRemove(root)) |kv| {
                if (kv.value.source_path.len > 0) allocator.free(kv.value.source_path);
            }
            try by_root.put(allocator, root, incoming);
        }
    }

    // Step 3: attach ferrite-bridged aliases to each rail. Walk net_parent
    // once, group children by their root, then merge into the corresponding
    // rail entry.
    var aliases_by_root: std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)) = .empty;
    defer {
        var ait = aliases_by_root.valueIterator();
        while (ait.next()) |list| list.deinit(allocator);
        aliases_by_root.deinit(allocator);
    }
    var np_it = net_parent.iterator();
    while (np_it.next()) |entry| {
        const child = entry.key_ptr.*;
        const root = findRoot(&net_parent, child);
        if (std.mem.eql(u8, child, root)) continue;
        const gop = try aliases_by_root.getOrPut(allocator, root);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(allocator, child);
    }

    var root_it = by_root.iterator();
    while (root_it.next()) |entry| {
        const root = entry.key_ptr.*;
        if (aliases_by_root.getPtr(root)) |list_ptr| {
            entry.value_ptr.aliases = try list_ptr.toOwnedSlice(allocator);
        }
    }

    // Step 4: emit, sorted by name for stable output across builds.
    var out: std.ArrayListUnmanaged(PowerRail) = .empty;
    var it = by_root.valueIterator();
    while (it.next()) |rail| try out.append(allocator, rail.*);
    std.mem.sort(PowerRail, out.items, {}, lessThanRail);
    return out.toOwnedSlice(allocator);
}

fn lessThanRail(_: void, a: PowerRail, b: PowerRail) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

/// Heuristic: does a net name read like a supply rail? Lets a regulator's bare
/// `(port "VOUT" out)` (no declared specs) still register as a rail source.
/// Mirrors the diagram classifier's power-name prefixes; deliberately narrow
/// (a `V` + prefix or `V` + digit) so signal outputs like NRST/FAULT/MUXOUT —
/// and V-initial signal names like VSYNC — don't become phantom rails.
fn looksLikeRail(name: []const u8) bool {
    if (name.len >= 2 and name[0] == 'V' and name[1] >= '0' and name[1] <= '9') return true;
    for (rail_prefixes) |p| {
        if (std.mem.startsWith(u8, name, p)) return true;
    }
    return false;
}

const rail_prefixes = [_][]const u8{
    "VDD", "VCC", "VOUT", "VBUS", "VPWR", "VREG", "VBAT", "VSYS", "VRAW", "V_",
};

/// Find the top-level net tied to a sub-block path like `"buck/VOUT"`.
fn findTopNet(block: *const DesignBlock, path: []const u8) ?[]const u8 {
    for (block.net_ties) |nt| {
        if (std.mem.eql(u8, nt.a, path)) return nt.b;
        if (std.mem.eql(u8, nt.b, path)) return nt.a;
    }
    return null;
}

fn findRoot(parent: *std.StringHashMapUnmanaged([]const u8), name: []const u8) []const u8 {
    var cur = name;
    while (parent.get(cur)) |p| {
        if (std.mem.eql(u8, p, cur)) return cur;
        cur = p;
    }
    return cur;
}

fn unionNets(
    allocator: std.mem.Allocator,
    parent: *std.StringHashMapUnmanaged([]const u8),
    a: []const u8,
    b: []const u8,
) std.mem.Allocator.Error!void {
    const ra = findRoot(parent, a);
    const rb = findRoot(parent, b);
    if (std.mem.eql(u8, ra, rb)) return;
    try parent.put(allocator, rb, ra);
}

/// Three-tier voltage resolution for a rail name. Mirrors the cascade in
/// `power_budget.resolveRailVoltage` but operates on the canonical rail
/// name (post-ferrite-union) the rails-build pass already chose.
fn resolveRailVoltage(block: *const DesignBlock, rail_name: []const u8) ?f64 {
    // 2. Section-level power port.
    for (block.sections) |sec| if (sectionVoltage(sec, rail_name)) |v| return v;

    // 3. Top-level port.
    for (block.ports) |p| {
        const port_net = if (p.net.len > 0) p.net else p.name;
        if (!std.mem.eql(u8, port_net, rail_name)) continue;
        if (p.nominal) |v| return v;
        if (p.rated_min != null and p.rated_max != null) {
            return (p.rated_min.? + p.rated_max.?) * RATING_MIDPOINT;
        }
    }
    return null;
}

fn sectionVoltage(sec: env_mod.Section, rail_name: []const u8) ?f64 {
    for (sec.ports) |sp| {
        if (!std.mem.eql(u8, sp.name, rail_name)) continue;
        if (sp.voltage) |v| return v;
    }
    for (sec.sub_sections) |sub| if (sectionVoltage(sub, rail_name)) |v| return v;
    return null;
}

// ── Tests ──────────────────────────────────────────────────────────────

fn outPort(name: []const u8, nominal: ?f64) Port {
    return .{
        .name = name,
        .net = name,
        .direction = "out",
        .nominal = nominal,
        .current_typ = 1.0,
        .current_max = 1.5,
    };
}

fn freeRails(allocator: std.mem.Allocator, rails: []const PowerRail) void {
    for (rails) |r| {
        if (r.source_path.len > 0) allocator.free(r.source_path);
        if (r.aliases.len > 0) allocator.free(r.aliases);
    }
    allocator.free(rails);
}

// spec: eval/rails - Derives one PowerRail per sub-block output port marked power direction out
test "build derives one rail per power output port" {
    const alloc = std.testing.allocator;
    var inner: DesignBlock = .{
        .name = "buck",
        .instances = &.{},
        .nets = &.{},
        .ports = &[_]Port{outPort("VOUT", 3.3)},
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
    const rails = try build(alloc, &outer);
    defer freeRails(alloc, rails);
    try std.testing.expectEqual(@as(usize, 1), rails.len);
    try std.testing.expectEqualStrings("VDD", rails[0].name);
}

// spec: eval/rails - Recognizes a spec-less regulator output tied to a rail-named net
test "build recognizes a bare VOUT tied to a rail-named net" {
    const alloc = std.testing.allocator;
    // Generic buck/OR modules declare a bare `(port "VOUT" out)` with no specs.
    // VOUT ties to a rail-named net (recognized); PG ties to a signal net (not).
    var inner: DesignBlock = .{
        .name = "buck",
        .instances = &.{},
        .nets = &.{},
        // Bare out ports — no nominal/current/efficiency, like a generic buck.
        .ports = &[_]Port{
            .{ .name = "VOUT", .net = "VOUT", .direction = "out" },
            .{ .name = "PG", .net = "PG", .direction = "out" },
        },
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    const sbs = [_]env_mod.SubBlock{.{ .name = "buck", .block = &inner }};
    const ties = [_]env_mod.NetTie{
        .{ .a = "buck/VOUT", .b = "VDD5" },
        .{ .a = "buck/PG", .b = "PG_3V3" },
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
    const rails = try build(alloc, &outer);
    defer freeRails(alloc, rails);
    try std.testing.expectEqual(@as(usize, 1), rails.len);
    try std.testing.expectEqualStrings("VDD5", rails[0].name);
}

// spec: eval/rails - Collapses ferrite-bead-bridged nets into a single rail via union-find
test "build collapses ferrite-bridged nets into single rail" {
    const alloc = std.testing.allocator;
    var inner: DesignBlock = .{
        .name = "ldo",
        .instances = &.{},
        .nets = &.{},
        .ports = &[_]Port{outPort("VOUT", 1.8)},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    const sbs = [_]env_mod.SubBlock{.{ .name = "ldo", .block = &inner }};
    const ties = [_]env_mod.NetTie{.{ .a = "ldo/VOUT", .b = "V1P8" }};
    // Ferrite bridging V1P8 <-> VDDA18USB
    const ferrite = env_mod.Instance{
        .ref_des = "FB1",
        .component = "ferrite-0402",
        .value = "",
        .footprint = "",
        .symbol = "",
    };
    const insts = [_]env_mod.Instance{ferrite};
    const nets = [_]env_mod.Net{
        .{ .name = "V1P8", .pins = &[_]env_mod.PinRef{.{ .ref_des = "FB1", .pin = "1" }} },
        .{ .name = "VDDA18USB", .pins = &[_]env_mod.PinRef{.{ .ref_des = "FB1", .pin = "2" }} },
    };
    const outer: DesignBlock = .{
        .name = "outer",
        .instances = &insts,
        .nets = &nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &sbs,
        .net_ties = &ties,
    };
    const rails = try build(alloc, &outer);
    defer freeRails(alloc, rails);

    try std.testing.expectEqual(@as(usize, 1), rails.len);
    try std.testing.expectEqualStrings("V1P8", rails[0].name);
    try std.testing.expectEqual(@as(usize, 1), rails[0].aliases.len);
    try std.testing.expectEqualStrings("VDDA18USB", rails[0].aliases[0]);
}

// spec: eval/rails - Resolves rail voltage from sub-block output port nominal first
test "build uses sub-block port nominal for voltage" {
    const alloc = std.testing.allocator;
    var inner: DesignBlock = .{
        .name = "buck",
        .instances = &.{},
        .nets = &.{},
        .ports = &[_]Port{outPort("VOUT", 3.3)},
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
    const rails = try build(alloc, &outer);
    defer freeRails(alloc, rails);
    try std.testing.expectEqual(@as(?f64, 3.3), rails[0].nominal);
}

// spec: eval/rails - Falls back to section power port voltage when sub-block port nominal absent
test "build falls back to section power port voltage" {
    const alloc = std.testing.allocator;
    var inner: DesignBlock = .{
        .name = "buck",
        .instances = &.{},
        .nets = &.{},
        .ports = &[_]Port{outPort("VOUT", null)}, // no nominal on sub-block port
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    const sbs = [_]env_mod.SubBlock{.{ .name = "buck", .block = &inner }};
    const ties = [_]env_mod.NetTie{.{ .a = "buck/VOUT", .b = "VDD" }};
    const sec_ports = [_]env_mod.SectionPort{.{ .name = "VDD", .direction = .in, .signal_type = .power, .voltage = 3.3 }};
    const sections = [_]env_mod.Section{.{
        .name = "VDD Power",
        .ports = &sec_ports,
    }};
    const outer: DesignBlock = .{
        .name = "outer",
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &sbs,
        .net_ties = &ties,
        .sections = &sections,
    };
    const rails = try build(alloc, &outer);
    defer freeRails(alloc, rails);
    try std.testing.expectEqual(@as(?f64, 3.3), rails[0].nominal);
}

// spec: eval/rails - Falls back to top-level design port nominal when neither sub-block nor section voltage declared
test "build falls back to top-level design port nominal" {
    const alloc = std.testing.allocator;
    var inner: DesignBlock = .{
        .name = "buck",
        .instances = &.{},
        .nets = &.{},
        .ports = &[_]Port{outPort("VOUT", null)},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    const sbs = [_]env_mod.SubBlock{.{ .name = "buck", .block = &inner }};
    const ties = [_]env_mod.NetTie{.{ .a = "buck/VOUT", .b = "VDD" }};
    const top_ports = [_]Port{.{ .name = "VDD", .net = "VDD", .direction = "out", .nominal = 3.3 }};
    const outer: DesignBlock = .{
        .name = "outer",
        .instances = &.{},
        .nets = &.{},
        .ports = &top_ports,
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &sbs,
        .net_ties = &ties,
    };
    const rails = try build(alloc, &outer);
    defer freeRails(alloc, rails);
    try std.testing.expectEqual(@as(?f64, 3.3), rails[0].nominal);
}

// spec: eval/rails - Excludes GND from the derived rail set
test "build excludes GND" {
    const alloc = std.testing.allocator;
    var inner: DesignBlock = .{
        .name = "buck",
        .instances = &.{},
        .nets = &.{},
        .ports = &[_]Port{outPort("VOUT", 3.3)},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    const sbs = [_]env_mod.SubBlock{.{ .name = "buck", .block = &inner }};
    // The output is bizarrely net-tied to GND — should not produce a rail.
    const ties = [_]env_mod.NetTie{.{ .a = "buck/VOUT", .b = "GND" }};
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
    const rails = try build(alloc, &outer);
    defer freeRails(alloc, rails);
    try std.testing.expectEqual(@as(usize, 0), rails.len);
}

// spec: eval/rails - Records source_ref_des and source_port on each rail from the source instance
test "build records source_ref_des and source_port" {
    const alloc = std.testing.allocator;
    var inner: DesignBlock = .{
        .name = "buck",
        .instances = &.{},
        .nets = &.{},
        .ports = &[_]Port{outPort("VOUT", 3.3)},
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
    const rails = try build(alloc, &outer);
    defer freeRails(alloc, rails);
    try std.testing.expectEqualStrings("buck", rails[0].source_ref_des);
    try std.testing.expectEqualStrings("VOUT", rails[0].source_port);
    try std.testing.expectEqualStrings("buck/VOUT", rails[0].source_path);
}

// spec: eval/rails - Returns empty slice when design declares no rails
test "build returns empty slice when no rails declared" {
    const alloc = std.testing.allocator;
    const outer: DesignBlock = .{
        .name = "outer",
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    const rails = try build(alloc, &outer);
    defer freeRails(alloc, rails);
    try std.testing.expectEqual(@as(usize, 0), rails.len);
}
