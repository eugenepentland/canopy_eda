//! Resolves a flattened net-pin ref-des back to the diagram node it belongs to.
//!
//! The unified netlist (built via export_kicad_netlist's collect/applyNetTies)
//! prefixes every sub-block part's ref-des with the sub-block path
//! (`lna1/U17`, `lna1/inner/U1`). Top-level and section instances stay
//! unprefixed (`U3`, `J1`). So resolution splits two ways:
//!   - a ref-des with a `/` belongs to the node of its *first* path segment's
//!     top-level sub-block;
//!   - an unprefixed ref-des is a section/top-level instance, looked up exactly.
//!
//! Mirrors the `section_map` intent in render_json.zig:529-562, adapted to this
//! package's node model (one node per section, one per unattached sub-block;
//! attached sub-blocks fold into their host section's node).

const std = @import("std");
const env_mod = @import("../eval/env.zig");
const rb = @import("../render_block_types.zig");

const DesignBlock = env_mod.DesignBlock;
const Allocator = std.mem.Allocator;
const RefMap = std.StringHashMapUnmanaged(u32);

/// Two-way resolver from a flattened net-pin ref-des to its diagram node.
pub const Membership = struct {
    /// Unprefixed ref-des (section + top-level instances) → node id.
    ref_to_node: RefMap,
    /// Top-level sub-block name → node id (host section node when attached,
    /// own node when unattached).
    sub_to_node: RefMap,

    pub fn deinit(self: *Membership, allocator: Allocator) void {
        self.ref_to_node.deinit(allocator);
        self.sub_to_node.deinit(allocator);
    }

    /// Node id owning the part at a flattened ref-des, or null if unmapped.
    pub fn resolve(self: *const Membership, flat_ref: []const u8) ?u32 {
        if (std.mem.indexOfScalar(u8, flat_ref, '/')) |i| {
            return self.sub_to_node.get(flat_ref[0..i]);
        }
        return self.ref_to_node.get(flat_ref);
    }
};

/// Build the membership maps. `sec_node[i]` is section `i`'s node id (null if
/// suppressed); `sub_node[i]` is unattached sub-block `i`'s node id (null when
/// folded); `sub_attachments[i]` is the host section index for an attached
/// sub-block. Caller owns the result and must `deinit`.
pub fn build(
    allocator: Allocator,
    block: *const DesignBlock,
    sec_node: []const ?u32,
    sub_node: []const ?u32,
    sub_attachments: []const ?usize,
) Allocator.Error!Membership {
    var ref_to_node: RefMap = .empty;
    errdefer ref_to_node.deinit(allocator);
    var sub_to_node: RefMap = .empty;
    errdefer sub_to_node.deinit(allocator);

    for (block.sections, 0..) |sec, si| {
        const nid = sec_node[si] orelse continue;
        try addSectionRefs(allocator, &ref_to_node, sec, nid);
        for (sec.sub_sections) |ss| try addSectionRefs(allocator, &ref_to_node, ss, nid);
    }

    for (block.sub_blocks, 0..) |sb, bi| {
        const nid = nodeForSub(bi, sec_node, sub_node, sub_attachments) orelse continue;
        try putIfAbsent(allocator, &sub_to_node, sb.name, nid);
    }

    return .{ .ref_to_node = ref_to_node, .sub_to_node = sub_to_node };
}

fn addSectionRefs(allocator: Allocator, map: *RefMap, sec: env_mod.Section, nid: u32) Allocator.Error!void {
    for (sec.instances) |inst| try putIfAbsent(allocator, map, inst.ref_des, nid);
    for (sec.pin_groups) |pg| try putIfAbsent(allocator, map, pg.ref_des, nid);
}

fn nodeForSub(
    bi: usize,
    sec_node: []const ?u32,
    sub_node: []const ?u32,
    sub_attachments: []const ?usize,
) ?u32 {
    if (bi < sub_attachments.len) {
        if (sub_attachments[bi]) |host_sec| {
            if (host_sec < sec_node.len) return sec_node[host_sec];
            return null;
        }
    }
    if (bi < sub_node.len) return sub_node[bi];
    return null;
}

fn putIfAbsent(allocator: Allocator, map: *RefMap, key: []const u8, nid: u32) Allocator.Error!void {
    if (key.len == 0) return;
    const gop = try map.getOrPut(allocator, key);
    if (!gop.found_existing) gop.value_ptr.* = nid;
}

/// Decide, per sub-block, which section (if any) it folds into for the diagram —
/// the `sub_attachments` slice `build`/`collectGraph` consume. A sub-block is
/// adopted by the section it shares the most *signal* nets with (power rails are
/// excluded so a regulator isn't sucked into a consumer), with an explicit
/// `(hosts "sub" …)` binding overriding the heuristic and a connector section
/// losing ties to a functional one. Caller owns the returned slice.
pub fn computeSubBlockAttachments(
    allocator: Allocator,
    block: *const DesignBlock,
) Allocator.Error![]?usize {
    const result = try allocator.alloc(?usize, block.sub_blocks.len);
    for (result) |*r| r.* = null;
    if (block.sub_blocks.len == 0 or block.sections.len == 0) return result;

    var net_to_subs: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(void)) = .empty;
    defer {
        var it = net_to_subs.iterator();
        while (it.next()) |e| e.value_ptr.deinit(allocator);
        net_to_subs.deinit(allocator);
    }

    for (block.net_ties) |nt| {
        const a_slash = std.mem.indexOfScalar(u8, nt.a, '/');
        const b_slash = std.mem.indexOfScalar(u8, nt.b, '/');
        var parent: []const u8 = "";
        var sub: []const u8 = "";
        if (a_slash == null and b_slash != null) {
            parent = nt.a;
            sub = nt.b[0..b_slash.?];
        } else if (b_slash == null and a_slash != null) {
            parent = nt.b;
            sub = nt.a[0..a_slash.?];
        } else continue;

        const gop = try net_to_subs.getOrPut(allocator, parent);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        _ = try gop.value_ptr.getOrPut(allocator, sub);
    }

    var sb_name_to_idx: std.StringHashMapUnmanaged(usize) = .empty;
    defer sb_name_to_idx.deinit(allocator);
    for (block.sub_blocks, 0..) |sb, idx| {
        try sb_name_to_idx.put(allocator, sb.name, idx);
    }

    // Explicit `(hosts "sub" …)` bindings are authoritative — they override the
    // net-count heuristic so a multi-sub subsystem (e.g. a PSU regulator + its
    // INA monitor) folds into one named section node regardless of how its
    // nets happen to tie. First declaration wins if two sections both claim it.
    var explicit_host: std.StringHashMapUnmanaged(usize) = .empty;
    defer explicit_host.deinit(allocator);
    for (block.sections, 0..) |sec, sec_idx| {
        for (sec.hosts) |host_name| {
            const gop = try explicit_host.getOrPut(allocator, host_name);
            if (!gop.found_existing) gop.value_ptr.* = sec_idx;
        }
    }

    // Every net declared as a power port anywhere (`(port … power V)`) is a
    // shared rail, not a peripheral interface. Collect them up front so the
    // affinity count below ignores them — otherwise a regulator sub-block
    // gets adopted into whichever consumer section declares the matching
    // `in power` port.
    var power_nets: std.StringHashMapUnmanaged(void) = .empty;
    defer power_nets.deinit(allocator);
    for (block.sections) |sec| {
        for (sec.ports) |port| {
            if (port.signal_type == .power) try power_nets.put(allocator, port.name, {});
        }
    }

    const sec_count = block.sections.len;
    const sb_count = block.sub_blocks.len;
    const counts = try allocator.alloc(usize, sb_count * sec_count);
    defer allocator.free(counts);
    @memset(counts, 0);

    for (block.sections, 0..) |sec, sec_idx| {
        var sec_nets: std.StringHashMapUnmanaged(void) = .empty;
        defer sec_nets.deinit(allocator);
        for (sec.pin_groups) |pg| {
            for (pg.pins) |p| try sec_nets.put(allocator, p.net, {});
        }
        for (sec.ports) |port| {
            try sec_nets.put(allocator, port.name, {});
        }

        var it = sec_nets.iterator();
        while (it.next()) |entry| {
            if (power_nets.contains(entry.key_ptr.*)) continue;
            const subs_ptr = net_to_subs.getPtr(entry.key_ptr.*) orelse continue;
            if (subs_ptr.count() != 1) continue;
            var sub_it = subs_ptr.keyIterator();
            const sub_name = sub_it.next().?.*;
            const sb_idx = sb_name_to_idx.get(sub_name) orelse continue;
            counts[sb_idx * sec_count + sec_idx] += 1;
        }
    }

    for (block.sub_blocks, 0..) |sb, sb_idx| {
        if (explicit_host.get(sb.name)) |sec_idx| {
            result[sb_idx] = sec_idx;
            continue;
        }
        var best_idx: ?usize = null;
        var best_count: usize = 0;
        var best_is_conn: bool = true;
        for (block.sections, 0..) |sec, sec_idx| {
            const c = counts[sb_idx * sec_count + sec_idx];
            if (c == 0) continue;
            const is_conn = rb.classifyByName(sec.name, sec.instances) == .connector;
            // Highest net-tie count wins; on a tie prefer a non-connector
            // section. A functional sub-block belongs with its subsystem, not
            // the connector it merely routes I/O through (the ADAR2004 RX
            // mixers tie their RFIN array against the mezzanine's ADC channels).
            const better = c > best_count or (c == best_count and best_is_conn and !is_conn);
            if (better) {
                best_count = c;
                best_idx = sec_idx;
                best_is_conn = is_conn;
            }
        }
        if (best_count >= 1) result[sb_idx] = best_idx;
    }
    return result;
}

/// Minimal DesignBlock for attachment tests — all collections empty so the
/// test only populates the fields it exercises.
fn emptyAttachBlock(name: []const u8) DesignBlock {
    return .{
        .name = name,
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
}

// spec: diagram/membership - Excludes power-classified nets so a power-producer sub-block is not adopted into a consuming section
test "computeSubBlockAttachments keeps a power producer out of a consuming section" {
    // Mirrors cyclops-analog: the "1.8 V LDO" section *consumes* V_RF_3P3
    // via `(port "V_RF_3P3" in power 3.3)`, while the buck33 sub-block
    // *produces* that rail. A separate USB section consumes a buck-
    // independent signal from the usb sub-block. Adoption must follow the
    // signal net, not the shared power rail.
    const ldo_ports = [_]env_mod.SectionPort{
        .{ .name = "V_RF_3P3", .direction = .in, .signal_type = .power, .voltage = 3.3 },
    };
    const usb_ports = [_]env_mod.SectionPort{
        .{ .name = "USB_DP", .direction = .io, .signal_type = .differential },
    };
    const sections = [_]env_mod.Section{
        .{ .name = "TPS7A2018 1.8 V LDO", .ports = &ldo_ports },
        .{ .name = "USB", .ports = &usb_ports },
    };

    var buck_design = emptyAttachBlock("tps63806-rail");
    var usb_design = emptyAttachBlock("usb-c-hs");
    const sub_blocks = [_]env_mod.SubBlock{
        .{ .name = "buck33", .block = &buck_design },
        .{ .name = "usb", .block = &usb_design },
    };

    // Net-ties as the evaluator materialises bridge / consolidated-net
    // wiring: one side carries the `<sub>/<port>` prefix, the other the
    // parent net the design wires it to.
    const net_ties = [_]env_mod.NetTie{
        .{ .a = "buck33/VOUT", .b = "V_RF_3P3" }, // buck33 produces the rail
        .{ .a = "usb/DP", .b = "USB_DP" }, // usb drives the signal
    };

    var block = emptyAttachBlock("cyclops-analog");
    block.sections = &sections;
    block.sub_blocks = &sub_blocks;
    block.net_ties = &net_ties;

    const attachments = try computeSubBlockAttachments(std.testing.allocator, &block);
    defer std.testing.allocator.free(attachments);

    // buck33 shares only the power rail with the LDO section → not adopted,
    // so it renders as its own top-level synthetic card.
    try std.testing.expectEqual(@as(?usize, null), attachments[0]);
    // usb shares a signal net with the USB section (idx 1) → still adopted.
    try std.testing.expectEqual(@as(?usize, 1), attachments[1]);
}
