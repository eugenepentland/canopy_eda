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
