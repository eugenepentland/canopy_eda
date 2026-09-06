//! Hub-pin layout: groups an IC/connector hub's pins for the schematic box (by
//! declared `(part …)`/group, mapping pad -> pin-function name), splits groups
//! across columns by rendered height, and estimates each spoke's branch count
//! so `context.zig` can size the hub box before drawing.

const std = @import("std");
const env_mod = @import("../eval/env.zig");
const ctx_mod = @import("context.zig");
const RenderCtx = ctx_mod.RenderCtx;
const FlatInst = ctx_mod.FlatInst;
const AdjEntry = ctx_mod.AdjEntry;
const PinGroup = ctx_mod.PinGroup;
const draw = @import("draw.zig");
const per_conn_spacing = draw.per_conn_spacing;
const isGroundNet = draw.isGroundNet;
const baseNetName = draw.baseNetName;
const pinOrder = draw.pinOrder;
const connection = @import("connection.zig");
const branch = @import("branch.zig");
const RenderError = draw.RenderError;

/// How many stubs a group renders given `stub_count` distinct stubs. Every pin
/// is drawn in full, so this is just the count with an empty group reserving
/// one row.
fn displayedStubCount(stub_count: usize) usize {
    return @max(stub_count, 1);
}

/// Stem of a pin function name: the name with trailing digits and one optional
/// `_`/`-` separator stripped. "GND_1" → "GND", "VSS3" → "VSS", "EN/UV" stays.
fn stemOf(name: []const u8) []const u8 {
    var end = name.len;
    while (end > 0 and name[end - 1] >= '0' and name[end - 1] <= '9') end -= 1;
    if (end == name.len or end == 0) return name; // no trailing digits, or all digits
    if (name[end - 1] == '_' or name[end - 1] == '-') end -= 1;
    return if (end == 0) name else name[0..end];
}

fn consecutivePinIds(a: []const u8, b: []const u8) bool {
    const a_num = std.fmt.parseInt(i64, a, 10) catch return true;
    const b_num = std.fmt.parseInt(i64, b, 10) catch return true;
    return b_num == a_num + 1;
}

const HubPinInfo = struct { pin: []const u8, net: []const u8 };

const BuildingGroup = struct {
    net: []const u8,
    pins: std.ArrayList([]const u8) = .empty,
    conns: std.ArrayList(AdjEntry) = .empty,
};

const GroupingState = struct {
    building: std.ArrayList(BuildingGroup) = .empty,
    folded_groups: std.StringHashMapUnmanaged(usize) = .empty,
    previous_group: ?usize = null,
    previous_pin: ?[]const u8 = null,
};

fn groundGroupKey(pi: HubPinInfo, pin_names: *const std.StringHashMapUnmanaged([]const u8)) ?[]const u8 {
    const net_base = baseNetName(pi.net);
    if (isGroundNet(net_base)) return net_base;
    const named_stem = if (pin_names.get(pi.pin)) |name| stemOf(name) else "";
    return if (isGroundNet(named_stem)) named_stem else null;
}

fn appendPinConnections(
    self: *RenderCtx,
    pins: *std.ArrayList([]const u8),
    conns: *std.ArrayList(AdjEntry),
    pin_id: []const u8,
    adj_entries: []const AdjEntry,
) RenderError!void {
    try pins.append(self.allocator, pin_id);
    for (adj_entries) |ae| {
        if (std.mem.eql(u8, ae.pin, pin_id)) try conns.append(self.allocator, ae);
    }
}

/// Build one render stub per physical pin in a group. Pins that share a rail
/// remain in the same `PinGroup`, so the renderer can tie their stubs together
/// with one bus, but none of their labels or package-pin ids are hidden behind
/// a count summary.
const StubLists = struct { labels: []const []const u8, pins: []const []const u8 };

fn buildStubs(
    self: *RenderCtx,
    pins: []const []const u8,
    pin_names: *const std.StringHashMapUnmanaged([]const u8),
) RenderError!StubLists {
    var labels: std.ArrayList([]const u8) = .empty;
    var pin_lists: std.ArrayList([]const u8) = .empty;
    for (pins) |pin| {
        try labels.append(self.allocator, pin_names.get(pin) orelse pin);
        try pin_lists.append(self.allocator, pin);
    }
    return .{ .labels = try labels.toOwnedSlice(self.allocator), .pins = try pin_lists.toOwnedSlice(self.allocator) };
}

/// Build a pin_id -> pin_name map from PartPin data.
pub fn buildPinNameMap(self: *RenderCtx, parts: []const env_mod.Part) std.StringHashMapUnmanaged([]const u8) {
    var map: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (parts) |part| {
        for (part.pins) |pp| {
            if (pp.pin_name.len > 0) {
                map.put(self.allocator, pp.pin, pp.pin_name) catch return map;
            }
        }
    }
    return map;
}

/// Group hub pins in physical pin order. Numerically-adjacent entries sharing
/// the same signal net get merged. Ground rails are the deliberate exception:
/// every pad on the same ground rail folds into the row at its first physical
/// occurrence, keeping large exposed-pad packages compact without scrambling
/// the order of their ordinary signal pins.
pub fn groupHubPins(
    self: *RenderCtx,
    pins: []const []const u8,
    adj_entries: []const AdjEntry,
    pin_names: *const std.StringHashMapUnmanaged([]const u8),
) RenderError![]const PinGroup {
    return groupHubPinsWithMode(self, pins, adj_entries, pin_names, .physical);
}

/// Group hub pins for the functional schematic. Pins on the same canonical
/// net fold into the row at their first physical occurrence, even when their
/// package numbers are separated. This keeps supply rails such as VDD_1,
/// VDD_2, and VDD_3 together while leaving the physical view untouched.
pub fn groupHubPinsFunctional(
    self: *RenderCtx,
    pins: []const []const u8,
    adj_entries: []const AdjEntry,
    pin_names: *const std.StringHashMapUnmanaged([]const u8),
) RenderError![]const PinGroup {
    return groupHubPinsWithMode(self, pins, adj_entries, pin_names, .functional);
}

const GroupingMode = enum { physical, functional };

fn foldGroupKey(
    mode: GroupingMode,
    pi: HubPinInfo,
    pin_names: *const std.StringHashMapUnmanaged([]const u8),
) ?[]const u8 {
    if (groundGroupKey(pi, pin_names)) |key| return key;
    return switch (mode) {
        .physical => null,
        .functional => if (pi.net.len > 0) baseNetName(pi.net) else null,
    };
}

fn pinNet(pin_id: []const u8, adj_entries: []const AdjEntry) []const u8 {
    for (adj_entries) |ae| {
        if (!std.mem.eql(u8, ae.pin, pin_id)) continue;
        switch (ae.endpoint) {
            .net => |net| return net,
            .pin => {},
        }
    }
    return "";
}

fn appendBuildingGroup(
    self: *RenderCtx,
    building: *std.ArrayList(BuildingGroup),
    net: []const u8,
) RenderError!usize {
    const idx = building.items.len;
    try building.append(self.allocator, .{ .net = net });
    return idx;
}

fn groupIndexForPin(
    self: *RenderCtx,
    pi: HubPinInfo,
    mode: GroupingMode,
    pin_names: *const std.StringHashMapUnmanaged([]const u8),
    state: *GroupingState,
) RenderError!usize {
    if (foldGroupKey(mode, pi, pin_names)) |key| {
        if (state.folded_groups.get(key)) |idx| return idx;
        const idx = try appendBuildingGroup(self, &state.building, pi.net);
        try state.folded_groups.put(self.allocator, key, idx);
        return idx;
    }
    if (state.previous_group) |idx| {
        const prior = &state.building.items[idx];
        const continues_run = pi.net.len > 0 and
            std.mem.eql(u8, pi.net, prior.net) and
            consecutivePinIds(state.previous_pin.?, pi.pin);
        if (continues_run) return idx;
    }
    return appendBuildingGroup(self, &state.building, pi.net);
}

fn groupHubPinsWithMode(
    self: *RenderCtx,
    pins: []const []const u8,
    adj_entries: []const AdjEntry,
    pin_names: *const std.StringHashMapUnmanaged([]const u8),
    mode: GroupingMode,
) RenderError![]const PinGroup {
    if (pins.len == 0) return &[_]PinGroup{};

    var pin_infos: std.ArrayList(HubPinInfo) = .empty;
    for (pins) |pin_id| {
        try pin_infos.append(self.allocator, .{ .pin = pin_id, .net = pinNet(pin_id, adj_entries) });
    }

    std.mem.sortUnstable(HubPinInfo, pin_infos.items, {}, struct {
        fn lt(_: void, a: HubPinInfo, b: HubPinInfo) bool {
            return pinOrder(a.pin, b.pin);
        }
    }.lt);

    var state: GroupingState = .{};

    for (pin_infos.items) |pi| {
        const group_idx = try groupIndexForPin(self, pi, mode, pin_names, &state);

        try appendPinConnections(
            self,
            &state.building.items[group_idx].pins,
            &state.building.items[group_idx].conns,
            pi.pin,
            adj_entries,
        );
        state.previous_group = group_idx;
        state.previous_pin = pi.pin;
    }

    var groups: std.ArrayList(PinGroup) = .empty;
    for (state.building.items) |*group| {
        try groups.append(self.allocator, try finishGroup(self, &group.pins, &group.conns, pin_names));
    }

    return groups.toOwnedSlice(self.allocator);
}

fn finishGroup(
    self: *RenderCtx,
    pins: *std.ArrayList([]const u8),
    conns: *std.ArrayList(AdjEntry),
    pin_names: *const std.StringHashMapUnmanaged([]const u8),
) !PinGroup {
    var display_name: []const u8 = "~";

    if (pins.items.len > 0) {
        if (pin_names.get(pins.items[0])) |func_name| {
            display_name = func_name;
        }
    }

    if (std.mem.eql(u8, display_name, "~")) {
        for (conns.items) |ae| {
            switch (ae.endpoint) {
                .net => |n| {
                    if (!isGroundNet(n)) {
                        display_name = n;
                        break;
                    } else {
                        display_name = n;
                    }
                },
                .pin => {},
            }
        }
    }

    if (std.mem.eql(u8, display_name, "~")) {
        if (pins.items.len == 1) {
            display_name = pins.items[0];
        }
    }

    var num_buf: std.ArrayList(u8) = .empty;
    for (pins.items, 0..) |pn, i| {
        if (i > 0) try num_buf.append(self.allocator, ',');
        try num_buf.appendSlice(self.allocator, pn);
    }

    const stubs = try buildStubs(self, pins.items, pin_names);
    const display_stem = stemOf(display_name);
    if (pins.items.len > 1 and isGroundNet(display_stem)) {
        // The scene graph has one pin record per group (unlike the SVG path,
        // which can retain a distinct EP/DAP stub), so give the folded row an
        // honest rail-wide count rather than naming it after only the first pad.
        display_name = try std.fmt.allocPrint(self.allocator, "{s}_({d})", .{ display_stem, pins.items.len });
    }
    const deduped = try dedupConns(self, conns.items);

    return PinGroup{
        .display_name = display_name,
        .pin_numbers = try num_buf.toOwnedSlice(self.allocator),
        .stub_labels = stubs.labels,
        .stub_pins = stubs.pins,
        .conns = deduped,
    };
}

/// Deduplicate connections.
fn dedupConns(self: *RenderCtx, conns: []const AdjEntry) ![]const AdjEntry {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var result: std.ArrayList(AdjEntry) = .empty;
    for (conns) |ae| {
        const key = switch (ae.endpoint) {
            // Per-pad derived names such as GND.U1.2 and GND.U1.4 are one
            // canonical rail. Once their pins fold into a row, keep only one
            // copy of that connection so height and rendering stay compact.
            .net => |n| try std.fmt.allocPrint(self.allocator, "net:{s}", .{baseNetName(n)}),
            .pin => |p| try std.fmt.allocPrint(self.allocator, "pin:{s}.{s}", .{ p.ref_des, p.pin }),
        };
        if (!seen.contains(key)) {
            try seen.put(self.allocator, key, {});
            try result.append(self.allocator, ae);
        }
    }
    return result.toOwnedSlice(self.allocator);
}

/// Result of splitting hub pin groups into left/right columns.
pub const SplitGroups = struct {
    left: []const PinGroup,
    right: []const PinGroup,
    left_heights: []f64,
    right_heights: []f64,
};

/// Whether a net joins two pin groups for layout purposes — a signal, or a
/// supply private to this hub. The one rule, shared with `connection`. Only
/// a DIRECT reach (`groupReachesNet`) uses it: the island walk below still
/// stops at every supply, so two pull-ups to one local rail do not pair
/// their signal pins through it.
const functionalLayoutNet = connection.functionalLayoutNet;
const functionalSignalAnchor = draw.isFunctionalSignalNet;

/// Do two pin groups hang off the SAME functional signal through their
/// passives? Two groups that do belong side by side with no gap — they are one
/// island of the schematic, not two.
///
/// Public because the section-inset view draws the same island rule and had
/// grown a byte-identical copy of it under another name; a divergence there
/// would gap the zoomed view differently from the hub it zooms into.
pub fn groupsSharePassiveAnchor(self: *const RenderCtx, a: PinGroup, b: PinGroup) bool {
    for (a.conns) |a_conn| {
        const a_pin = switch (a_conn.endpoint) {
            .pin => |pin| pin,
            .net => continue,
        };
        const a_anchor = self.spoke_anchor_net.get(a_pin.ref_des) orelse continue;
        if (!functionalSignalAnchor(baseNetName(a_anchor))) continue;
        for (b.conns) |b_conn| {
            const b_pin = switch (b_conn.endpoint) {
                .pin => |pin| pin,
                .net => continue,
            };
            const b_anchor = self.spoke_anchor_net.get(b_pin.ref_des) orelse continue;
            if (std.mem.eql(u8, baseNetName(a_anchor), baseNetName(b_anchor))) return true;
        }
    }
    return false;
}

fn groupContainsHubPin(group: PinGroup, pin_id: []const u8) bool {
    for (group.stub_pins) |pin| {
        if (std.mem.eql(u8, pin, pin_id)) return true;
    }
    for (group.conns) |conn| {
        if (std.mem.eql(u8, conn.pin, pin_id)) return true;
    }
    return false;
}

/// Walk only passive parts and non-power signal nets. This is intentionally
/// separate from the drawing chain walker: Functional rendering stops at a
/// visible port net, but column placement still needs to see a differential
/// termination beyond that boundary. For example, the LMX2595 path is
/// OSCINP -> coupling C -> REF_P -> 100 R -> REF_N -> coupling C -> OSCINM.
fn passiveSignalPathReachesGroup(
    self: *RenderCtx,
    hub_ref: []const u8,
    spoke_ref: []const u8,
    target: PinGroup,
    visited: *std.StringHashMapUnmanaged(void),
) RenderError!bool {
    if (visited.contains(spoke_ref)) return false;
    try visited.put(self.allocator, spoke_ref, {});

    const adj = self.adjacency.get(spoke_ref) orelse return false;
    for (adj.items) |entry| switch (entry.endpoint) {
        .pin => |pin| {
            if (std.mem.eql(u8, pin.ref_des, hub_ref)) {
                if (groupContainsHubPin(target, pin.pin)) return true;
            } else if (self.spoke_set.contains(pin.ref_des) and
                try passiveSignalPathReachesGroup(self, hub_ref, pin.ref_des, target, visited))
            {
                return true;
            }
        },
        .net => |net| {
            const signal_net = baseNetName(net);
            if (!functionalSignalAnchor(signal_net)) continue;
            const pins = self.net_index.get(signal_net) orelse continue;
            for (pins.items) |pin| {
                if (std.mem.eql(u8, pin.ref_des, hub_ref)) {
                    if (groupContainsHubPin(target, pin.pin)) return true;
                } else if (self.spoke_set.contains(pin.ref_des) and
                    try passiveSignalPathReachesGroup(self, hub_ref, pin.ref_des, target, visited))
                {
                    return true;
                }
            }
        },
    };
    return false;
}

/// Whether two pin groups of one hub are joined through signal-side passives.
pub fn groupsSharePassiveSignalPath(self: *RenderCtx, hub_ref: []const u8, source: PinGroup, target: PinGroup) RenderError!bool {
    var visited: std.StringHashMapUnmanaged(void) = .empty;
    for (source.conns) |conn| {
        const spoke = switch (conn.endpoint) {
            .pin => |pin| pin,
            .net => continue,
        };
        if (!self.spoke_set.contains(spoke.ref_des)) continue;
        if (try passiveSignalPathReachesGroup(self, hub_ref, spoke.ref_des, target, &visited)) return true;
    }
    return false;
}

fn groupCanonicalNet(self: *RenderCtx, hub_ref: []const u8, group: PinGroup) RenderError![]const u8 {
    for (group.conns) |conn| {
        const key = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ hub_ref, conn.pin });
        if (self.pin_canonical_nets.get(key)) |net| return baseNetName(net);
    }
    return "";
}

fn groupReachesNet(self: *RenderCtx, hub_ref: []const u8, group: PinGroup, target_net: []const u8) RenderError!bool {
    for (group.conns) |conn| {
        const spoke = switch (conn.endpoint) {
            .pin => |pin| pin,
            .net => continue,
        };
        if (!self.spoke_set.contains(spoke.ref_des)) continue;
        const terminal = baseNetName(try connection.getConnTerminal(self, conn.endpoint, hub_ref, conn.pin));
        if (functionalLayoutNet(self, terminal) and std.mem.eql(u8, terminal, target_net)) return true;
    }
    return false;
}

fn groupsFunctionallyLinked(self: *RenderCtx, hub_ref: []const u8, a: PinGroup, b: PinGroup) RenderError!bool {
    if (try groupsSharePassiveSignalPath(self, hub_ref, a, b) or
        try groupsSharePassiveSignalPath(self, hub_ref, b, a)) return true;
    if (groupsSharePassiveAnchor(self, a, b)) return true;
    const a_net = try groupCanonicalNet(self, hub_ref, a);
    const b_net = try groupCanonicalNet(self, hub_ref, b);
    return try groupReachesNet(self, hub_ref, a, b_net) or try groupReachesNet(self, hub_ref, b, a_net);
}

/// Split an ordered run of pin groups at the prefix whose visual height is
/// closest to half the total. Both columns therefore contain contiguous pin
/// ranges: scan the left column top-to-bottom, then the right column, and the
/// physical pin ids remain sequential. A height-aware boundary keeps the two
/// columns as balanced as possible without interleaving odd/even groups.
fn splitGroupsAtBalancedPrefix(
    self: *RenderCtx,
    hub_ref: []const u8,
    all_groups: []const PinGroup,
    all_heights: []const f64,
) RenderError!SplitGroups {
    std.debug.assert(all_groups.len == all_heights.len);

    if (all_groups.len == 0) return .{
        .left = &.{},
        .right = &.{},
        .left_heights = &.{},
        .right_heights = &.{},
    };

    var total: f64 = 0;
    for (all_heights) |h| total += h;

    var split_idx: usize = all_groups.len;
    if (all_groups.len > 1) {
        var prefix: f64 = 0;
        var best_delta = std.math.inf(f64);
        for (all_heights[0 .. all_heights.len - 1], 0..) |h, i| {
            prefix += h;
            if (self.render_scratch.functional_layout and
                try groupsFunctionallyLinked(self, hub_ref, all_groups[i], all_groups[i + 1])) continue;
            const delta = @abs(total - 2.0 * prefix);
            if (delta < best_delta) {
                best_delta = delta;
                split_idx = i + 1;
            }
        }
    }

    var left: std.ArrayList(PinGroup) = .empty;
    var right: std.ArrayList(PinGroup) = .empty;
    var left_h: std.ArrayList(f64) = .empty;
    var right_h: std.ArrayList(f64) = .empty;
    try left.appendSlice(self.allocator, all_groups[0..split_idx]);
    try right.appendSlice(self.allocator, all_groups[split_idx..]);
    try left_h.appendSlice(self.allocator, all_heights[0..split_idx]);
    try right_h.appendSlice(self.allocator, all_heights[split_idx..]);

    return .{
        .left = try left.toOwnedSlice(self.allocator),
        .right = try right.toOwnedSlice(self.allocator),
        .left_heights = try left_h.toOwnedSlice(self.allocator),
        .right_heights = try right_h.toOwnedSlice(self.allocator),
    };
}

/// Split hub pin groups into two sequential, visually balanced columns.
/// `groupHeights` accounts for branch slots, so the prefix boundary balances
/// rendered height rather than raw group count.
pub fn splitGroupsByHeight(
    self: *RenderCtx,
    all_groups: []const PinGroup,
    hub_ref: []const u8,
) RenderError!SplitGroups {
    const all_heights = try groupHeights(self, all_groups, hub_ref);
    defer self.allocator.free(all_heights);

    return splitGroupsAtBalancedPrefix(self, hub_ref, all_groups, all_heights);
}

/// Whether `spoke_ref` hangs off a hub pin in one of `earlier` groups — the
/// rows that render before this one, in this order, and so draw it first.
fn spokeDrawnByEarlierGroup(self: *const RenderCtx, spoke_ref: []const u8, hub_ref: []const u8, earlier: []const PinGroup) bool {
    const adj = self.adjacency.get(spoke_ref) orelse return false;
    for (adj.items) |entry| switch (entry.endpoint) {
        .pin => |hp| {
            if (!std.mem.eql(u8, hp.ref_des, hub_ref)) continue;
            for (earlier) |g| if (groupContainsHubPin(g, hp.pin)) return true;
        },
        .net => {},
    };
    return false;
}

/// `shouldShowOwnNet` as it will answer when this row renders: it also turns
/// true once an earlier row has drawn a spoke on the net. Heights are computed
/// before any row has drawn, so that render-order fact is predicted from the
/// group order here; reading `rendered_spokes` instead left the row out of the
/// band and the fan overran it by one row on each side.
fn ownNetRowShown(self: *RenderCtx, net: []const u8, hub_ref: []const u8, earlier: []const PinGroup) bool {
    if (connection.shouldShowOwnNet(self, net, hub_ref)) return true;
    const pins = self.net_index.get(net) orelse return false;
    for (pins.items) |np| {
        if (!self.spoke_set.contains(np.ref_des)) continue;
        if (spokeDrawnByEarlierGroup(self, np.ref_des, hub_ref, earlier)) return true;
    }
    return false;
}

/// Calculate per-group heights based on connection count and branch estimates.
/// `groups` is in render order, which the estimate leans on: a spoke shared
/// with an earlier group is drawn there and skipped here (`rendered_spokes`),
/// and the pin's own net gains a row once an earlier group has drawn a spoke
/// on it.
pub fn groupHeights(self: *RenderCtx, groups: []const PinGroup, hub_ref: []const u8) RenderError![]f64 {
    var heights = try self.allocator.alloc(f64, groups.len);
    for (groups, 0..) |group, i| {
        var total_slots: i32 = 0;
        var first_pin_id: []const u8 = "";
        for (group.conns) |conn| {
            first_pin_id = conn.pin;
            break;
        }
        const canon_key = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ hub_ref, first_pin_id });
        const pin_net_name = self.pin_canonical_nets.get(canon_key) orelse "";
        const earlier = groups[0..i];
        for (group.conns) |conn| {
            switch (conn.endpoint) {
                .pin => |p| {
                    if (self.spoke_set.contains(p.ref_des)) {
                        if (spokeDrawnByEarlierGroup(self, p.ref_des, hub_ref, earlier)) continue;
                        total_slots += @intCast(estimateBranchCount(self, p.ref_des, hub_ref));
                    } else {
                        total_slots += 1;
                    }
                },
                .net => |net| {
                    const bn = baseNetName(net);
                    if (self.significant_nets.contains(bn)) {
                        const own = std.mem.eql(u8, bn, baseNetName(pin_net_name));
                        if (own and !ownNetRowShown(self, bn, hub_ref, earlier)) continue;
                        total_slots += 1;
                    }
                },
            }
        }
        // Each pin in the group draws its own stub, so the group must be tall
        // enough for whichever is larger: its connection slots or pin count.
        const stubs: i32 = @intCast(displayedStubCount(group.stub_labels.len));
        const rows = @max(total_slots, stubs);
        const base: f64 = 40.0;
        heights[i] = base + @as(f64, @floatFromInt(@max(rows, 1) - 1)) * per_conn_spacing;
    }
    return heights;
}

fn islandReachesOtherHubPin(
    self: *RenderCtx,
    net_pins: []const env_mod.PinRef,
    spoke_rd: []const u8,
    hub_ref: []const u8,
    hub_pin: ?[]const u8,
) bool {
    for (net_pins) |np| {
        if (std.mem.eql(u8, np.ref_des, spoke_rd) or !self.spoke_set.contains(np.ref_des)) continue;
        const other_adj = self.adjacency.get(np.ref_des) orelse continue;
        for (other_adj.items) |other| switch (other.endpoint) {
            .pin => |pin| {
                if (std.mem.eql(u8, pin.ref_des, hub_ref) and
                    (hub_pin == null or !std.mem.eql(u8, pin.pin, hub_pin.?))) return true;
            },
            .net => {},
        };
    }
    return false;
}

fn branchSpokeCount(self: *const RenderCtx, net_pins: []const env_mod.PinRef, source_ref: []const u8) u32 {
    var count: u32 = 0;
    for (net_pins) |pin| {
        if (std.mem.eql(u8, pin.ref_des, source_ref) or !self.spoke_set.contains(pin.ref_des)) continue;
        count += 1;
    }
    return count;
}

fn groundedResolvedBranchSlots(self: *RenderCtx, spoke_ref: []const u8, hub_ref: []const u8, hub_pin: []const u8) ?u32 {
    if (!self.render_scratch.functional_layout) return null;
    var visited: std.StringHashMapUnmanaged(void) = .empty;
    visited.put(self.allocator, spoke_ref, {}) catch return null;
    const result = connection.findSpokeChain(
        self,
        spoke_ref,
        .{ .pin = .{ .ref_des = hub_ref, .pin = hub_pin } },
        &visited,
    ) catch return null;
    if (!self.rendersWhenAlone(baseNetName(result.terminal))) return null;
    for (result.branches) |resolved_branch| {
        if (isGroundNet(baseNetName(resolved_branch.terminal))) return @intCast(result.branches.len + 1);
    }
    return null;
}

/// Estimate how many vertical slots a spoke connection needs.
pub fn estimateBranchCount(self: *RenderCtx, spoke_rd: []const u8, hub_ref: []const u8) u32 {
    const adj_list = self.adjacency.get(spoke_rd) orelse return 1;
    var spoke_hub_pin: ?[]const u8 = null;
    var hub_pin: ?[]const u8 = null;
    for (adj_list.items) |ae| {
        switch (ae.endpoint) {
            .pin => |p| {
                if (std.mem.eql(u8, p.ref_des, hub_ref)) {
                    spoke_hub_pin = ae.pin;
                    hub_pin = p.pin;
                    break;
                }
            },
            .net => {},
        }
    }

    if (hub_pin) |pin| {
        if (groundedResolvedBranchSlots(self, spoke_rd, hub_ref, pin)) |slots| return slots;
    }

    for (adj_list.items) |ae| {
        if (spoke_hub_pin != null and std.mem.eql(u8, ae.pin, spoke_hub_pin.?)) continue;
        switch (ae.endpoint) {
            .net => |net| {
                const bn = baseNetName(net);
                // Mirror `tryChainConns`: ground and sub-block-shared rails are
                // terminals, so the chain needs just one slot — not one per
                // sibling spoke on the rail. Without this the reserved height
                // still counts the fanned-out branches the walker no longer
                // draws, so each hub block stays oversized.
                if (isGroundNet(bn) or self.shared_rail_nets.contains(bn)) return 1;
                const net_pins = self.net_index.get(bn) orelse continue;
                var has_hub = false;
                for (net_pins.items) |np| {
                    if (!self.spoke_set.contains(np.ref_des) and !std.mem.eql(u8, np.ref_des, spoke_rd)) {
                        has_hub = true;
                        break;
                    }
                }
                if (has_hub) return 1;

                // Functional draws a passive-only island shared by two hub
                // pins as one outside rail. Its choke/bypass tree is centred
                // between those rows, so neither pull-up needs to reserve the
                // island's full fan-out height beside its own pin.
                if (self.render_scratch.functional_layout and
                    islandReachesOtherHubPin(self, net_pins.items, spoke_rd, hub_ref, hub_pin)) return 1;

                const branch_count = branchSpokeCount(self, net_pins.items, spoke_rd);
                if (branch_count <= 1) return 1;
                return branch_count;
            },
            .pin => {},
        }
    }
    return 1;
}

// spec: render_svg - Group heights follow render order: a spoke shared with an earlier group is counted there, and the own net's row is reserved once an earlier group draws a spoke on it
test "group heights follow render order for spokes shared between two groups" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    // Two pull-ups from pin 1 to the hub-private rail on pin 6. Pin 1's row
    // draws both; pin 6's row skips them (`rendered_spokes`) and instead
    // shows its own net, which those drawn spokes now make worth following.
    const instances = [_]env_mod.Instance{
        .{ .ref_des = "U1", .component = "ic", .value = "", .footprint = "", .symbol = "" },
        .{ .ref_des = "R1", .component = "res-0402", .value = "10k", .footprint = "", .symbol = "generic-res" },
        .{ .ref_des = "R3", .component = "res-0402", .value = "10k", .footprint = "", .symbol = "generic-res" },
    };
    const ctrl = [_]env_mod.PinRef{
        .{ .ref_des = "U1", .pin = "1" },
        .{ .ref_des = "R1", .pin = "2" },
        .{ .ref_des = "R3", .pin = "2" },
    };
    const rail = [_]env_mod.PinRef{
        .{ .ref_des = "U1", .pin = "6" },
        .{ .ref_des = "R1", .pin = "1" },
        .{ .ref_des = "R3", .pin = "1" },
    };
    const nets = [_]env_mod.Net{
        .{ .name = "CTRL", .pins = &ctrl },
        .{ .name = "VDD_F", .pins = &rail },
    };
    const block: env_mod.DesignBlock = .{
        .name = "shared-spoke-heights",
        .instances = &instances,
        .nets = &nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    var ctx = RenderCtx.init(allocator);
    try ctx.setup(&block);
    var pin_names: std.StringHashMapUnmanaged([]const u8) = .empty;
    const pins = [_][]const u8{ "1", "6" };
    const groups = try groupHubPinsFunctional(&ctx, &pins, ctx.adjacency.get("U1").?.items, &pin_names);
    try testing.expectEqual(@as(usize, 2), groups.len);

    const heights = try groupHeights(&ctx, groups, "U1");
    // Pin 1: two spoke rows. Pin 6: one row for its own net — not one per
    // already-drawn spoke plus a surprise own-net row at render time.
    try testing.expectEqual(@as(f64, 80.0), heights[0]);
    try testing.expectEqual(@as(f64, 40.0), heights[1]);
}

// spec: render_svg - Parallel passives returning to the same hub pin reserve their full branch-tree height instead of masquerading as a cross-pin island
test "branch count distinguishes the spoke pin from the destination hub pin" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    var ctx = RenderCtx.init(allocator);
    ctx.render_scratch.functional_layout = true;

    for ([_][]const u8{ "L2", "R4", "C5", "L3" }) |ref| {
        try ctx.spoke_set.put(allocator, ref, {});
    }

    var l2_adj: std.ArrayList(AdjEntry) = .empty;
    try l2_adj.append(allocator, .{ .pin = "2", .endpoint = .{ .pin = .{ .ref_des = "U1", .pin = "7" } } });
    try l2_adj.append(allocator, .{ .pin = "1", .endpoint = .{ .net = "VDD_FILT" } });
    try ctx.adjacency.put(allocator, "L2", l2_adj);

    var r4_adj: std.ArrayList(AdjEntry) = .empty;
    try r4_adj.append(allocator, .{ .pin = "2", .endpoint = .{ .pin = .{ .ref_des = "U1", .pin = "7" } } });
    try ctx.adjacency.put(allocator, "R4", r4_adj);

    var filt_pins: std.ArrayList(env_mod.PinRef) = .empty;
    try filt_pins.appendSlice(allocator, &.{
        .{ .ref_des = "L2", .pin = "1" },
        .{ .ref_des = "R4", .pin = "1" },
        .{ .ref_des = "C5", .pin = "1" },
        .{ .ref_des = "L3", .pin = "2" },
    });
    try ctx.net_index.put(allocator, "VDD_FILT", filt_pins);

    try testing.expectEqual(@as(u32, 3), estimateBranchCount(&ctx, "L2", "U1"));
}

const testing = std.testing;

test "groupHubPins merges two consecutive pins on the same net into one group" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ctx = RenderCtx.init(arena_state.allocator());
    const pins = [_][]const u8{ "1", "2" };
    const adj = [_]AdjEntry{
        .{ .pin = "1", .endpoint = .{ .net = "VDD" } },
        .{ .pin = "2", .endpoint = .{ .net = "VDD" } },
    };
    var names: std.StringHashMapUnmanaged([]const u8) = .empty;
    const groups = try groupHubPins(&ctx, &pins, &adj, &names);
    // Both pins share net VDD, so the should-merge flag (a `break :blk true`)
    // collapses them into a single group; flipping it to false yields two.
    try testing.expectEqual(@as(usize, 1), groups.len);
    try testing.expectEqualStrings("1,2", groups[0].pin_numbers);
}

test "groupHubPins keeps physical pin order and does not fold separated same-net pins" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ctx = RenderCtx.init(arena_state.allocator());
    const pins = [_][]const u8{ "3", "1", "2" };
    const adj = [_]AdjEntry{
        .{ .pin = "1", .endpoint = .{ .net = "Z_NET" } },
        .{ .pin = "2", .endpoint = .{ .net = "A_NET" } },
        .{ .pin = "3", .endpoint = .{ .net = "Z_NET" } },
    };
    var names: std.StringHashMapUnmanaged([]const u8) = .empty;
    const groups = try groupHubPins(&ctx, &pins, &adj, &names);

    try testing.expectEqual(@as(usize, 3), groups.len);
    try testing.expectEqualStrings("1", groups[0].pin_numbers);
    try testing.expectEqualStrings("2", groups[1].pin_numbers);
    try testing.expectEqualStrings("3", groups[2].pin_numbers);
}

test "groupHubPinsFunctional groups separated supply pads without sorting the other pins" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ctx = RenderCtx.init(arena_state.allocator());
    const pins = [_][]const u8{ "13", "7", "9", "6" };
    const adj = [_]AdjEntry{
        .{ .pin = "6", .endpoint = .{ .net = "VDD_F.U1.6" } },
        .{ .pin = "7", .endpoint = .{ .net = "CTRL" } },
        .{ .pin = "9", .endpoint = .{ .net = "VDD_F.U1.9" } },
        .{ .pin = "13", .endpoint = .{ .net = "VDD_F.U1.13" } },
    };
    var names: std.StringHashMapUnmanaged([]const u8) = .empty;
    try names.put(ctx.allocator, "6", "VDD_1");
    try names.put(ctx.allocator, "7", "DATA");
    try names.put(ctx.allocator, "9", "VDD_2");
    try names.put(ctx.allocator, "13", "VDD_3");
    const groups = try groupHubPinsFunctional(&ctx, &pins, &adj, &names);

    try testing.expectEqual(@as(usize, 2), groups.len);
    try testing.expectEqualStrings("6,9,13", groups[0].pin_numbers);
    try testing.expectEqualSlices([]const u8, &.{ "VDD_1", "VDD_2", "VDD_3" }, groups[0].stub_labels);
    try testing.expectEqualSlices([]const u8, &.{ "6", "9", "13" }, groups[0].stub_pins);
    try testing.expectEqualStrings("7", groups[1].pin_numbers);
}

// spec: render_svg - Ground pads fold into one row at their first physical occurrence while ordinary signals remain in pin order
// spec: render_svg - Ground and supply pins sharing a rail render one labeled stub and pin number per physical pad
test "groupHubPins folds separated ground pads without sorting signal pins by net" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ctx = RenderCtx.init(arena_state.allocator());
    const pins = [_][]const u8{ "4", "1", "3", "2" };
    const adj = [_]AdjEntry{
        .{ .pin = "1", .endpoint = .{ .net = "SIG_A" } },
        .{ .pin = "2", .endpoint = .{ .net = "GND.U1.2" } },
        .{ .pin = "3", .endpoint = .{ .net = "SIG_B" } },
        .{ .pin = "4", .endpoint = .{ .net = "GND.U1.4" } },
    };
    var names: std.StringHashMapUnmanaged([]const u8) = .empty;
    try names.put(ctx.allocator, "2", "GND_1");
    try names.put(ctx.allocator, "4", "GND_2");
    const groups = try groupHubPins(&ctx, &pins, &adj, &names);

    try testing.expectEqual(@as(usize, 3), groups.len);
    try testing.expectEqualStrings("1", groups[0].pin_numbers);
    try testing.expectEqualStrings("2,4", groups[1].pin_numbers);
    try testing.expectEqualStrings("GND_(2)", groups[1].display_name);
    try testing.expectEqualSlices([]const u8, &.{ "GND_1", "GND_2" }, groups[1].stub_labels);
    try testing.expectEqualSlices([]const u8, &.{ "2", "4" }, groups[1].stub_pins);
    try testing.expectEqual(@as(usize, 1), groups[1].conns.len);
    try testing.expectEqualStrings("3", groups[2].pin_numbers);
}

test "splitGroupsByHeight keeps sequential pin ranges in each column" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ctx = RenderCtx.init(arena_state.allocator());
    const groups = [_]PinGroup{
        .{ .display_name = "", .pin_numbers = "1", .conns = &.{} },
        .{ .display_name = "", .pin_numbers = "2", .conns = &.{} },
        .{ .display_name = "", .pin_numbers = "3", .conns = &.{} },
        .{ .display_name = "", .pin_numbers = "4", .conns = &.{} },
    };
    const split = try splitGroupsByHeight(&ctx, &groups, "U1");

    try testing.expectEqual(@as(usize, 2), split.left.len);
    try testing.expectEqual(@as(usize, 2), split.right.len);
    try testing.expectEqualStrings("1", split.left[0].pin_numbers);
    try testing.expectEqualStrings("2", split.left[1].pin_numbers);
    try testing.expectEqualStrings("3", split.right[0].pin_numbers);
    try testing.expectEqualStrings("4", split.right[1].pin_numbers);
}

test "functional height split keeps a passive-connected pin pair in one column" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ctx = RenderCtx.init(arena_state.allocator());
    ctx.render_scratch.functional_layout = true;
    try ctx.spoke_set.put(ctx.allocator, "R2", {});
    try ctx.spoke_set.put(ctx.allocator, "R3", {});
    try ctx.spoke_anchor_net.put(ctx.allocator, "R2", "SIGNAL_RETURN");
    try ctx.spoke_anchor_net.put(ctx.allocator, "R3", "SIGNAL_RETURN");
    const groups = [_]PinGroup{
        .{ .display_name = "", .pin_numbers = "1", .conns = &.{} },
        .{ .display_name = "", .pin_numbers = "2", .conns = &.{.{ .pin = "2", .endpoint = .{ .pin = .{ .ref_des = "R2", .pin = "1" } } }} },
        .{ .display_name = "", .pin_numbers = "3", .conns = &.{.{ .pin = "3", .endpoint = .{ .pin = .{ .ref_des = "R3", .pin = "1" } } }} },
        .{ .display_name = "", .pin_numbers = "4", .conns = &.{} },
    };
    const split = try splitGroupsByHeight(&ctx, &groups, "U1");

    try testing.expectEqual(@as(usize, 1), split.left.len);
    try testing.expectEqual(@as(usize, 3), split.right.len);
    try testing.expectEqualStrings("2", split.right[0].pin_numbers);
    try testing.expectEqualStrings("3", split.right[1].pin_numbers);
}

// spec: render_svg - Functional hub pins joined by a passive-only signal path stay in the same column
test "functional height split keeps a passively terminated differential pair in one column" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    var ctx = RenderCtx.init(allocator);
    ctx.render_scratch.functional_layout = true;

    for ([_][]const u8{ "C_OSCINP", "R_OSC_TERM", "C_OSCINM" }) |ref| {
        try ctx.spoke_set.put(allocator, ref, {});
    }

    var cp_adj: std.ArrayList(AdjEntry) = .empty;
    try cp_adj.append(allocator, .{ .pin = "2", .endpoint = .{ .pin = .{ .ref_des = "U1", .pin = "8" } } });
    try cp_adj.append(allocator, .{ .pin = "1", .endpoint = .{ .net = "REF_P" } });
    try ctx.adjacency.put(allocator, "C_OSCINP", cp_adj);

    var term_adj: std.ArrayList(AdjEntry) = .empty;
    try term_adj.append(allocator, .{ .pin = "1", .endpoint = .{ .net = "REF_P" } });
    try term_adj.append(allocator, .{ .pin = "2", .endpoint = .{ .net = "REF_N" } });
    try ctx.adjacency.put(allocator, "R_OSC_TERM", term_adj);

    var cm_adj: std.ArrayList(AdjEntry) = .empty;
    try cm_adj.append(allocator, .{ .pin = "1", .endpoint = .{ .net = "REF_N" } });
    try cm_adj.append(allocator, .{ .pin = "2", .endpoint = .{ .pin = .{ .ref_des = "U1", .pin = "9" } } });
    try ctx.adjacency.put(allocator, "C_OSCINM", cm_adj);

    var ref_p_pins: std.ArrayList(env_mod.PinRef) = .empty;
    try ref_p_pins.appendSlice(allocator, &.{
        .{ .ref_des = "C_OSCINP", .pin = "1" },
        .{ .ref_des = "R_OSC_TERM", .pin = "1" },
    });
    try ctx.net_index.put(allocator, "REF_P", ref_p_pins);
    var ref_n_pins: std.ArrayList(env_mod.PinRef) = .empty;
    try ref_n_pins.appendSlice(allocator, &.{
        .{ .ref_des = "R_OSC_TERM", .pin = "2" },
        .{ .ref_des = "C_OSCINM", .pin = "1" },
    });
    try ctx.net_index.put(allocator, "REF_N", ref_n_pins);

    const groups = [_]PinGroup{
        .{ .display_name = "CE", .pin_numbers = "7", .stub_labels = &.{"CE"}, .stub_pins = &.{"7"}, .conns = &.{} },
        .{ .display_name = "OSCINP", .pin_numbers = "8", .stub_labels = &.{"OSCINP"}, .stub_pins = &.{"8"}, .conns = &.{.{ .pin = "8", .endpoint = .{ .pin = .{ .ref_des = "C_OSCINP", .pin = "2" } } }} },
        .{ .display_name = "OSCINM", .pin_numbers = "9", .stub_labels = &.{"OSCINM"}, .stub_pins = &.{"9"}, .conns = &.{.{ .pin = "9", .endpoint = .{ .pin = .{ .ref_des = "C_OSCINM", .pin = "2" } } }} },
        .{ .display_name = "VREGIN", .pin_numbers = "10", .stub_labels = &.{"VREGIN"}, .stub_pins = &.{"10"}, .conns = &.{} },
    };
    const split = try splitGroupsByHeight(&ctx, &groups, "U1");

    try testing.expectEqual(@as(usize, 1), split.left.len);
    try testing.expectEqual(@as(usize, 3), split.right.len);
    try testing.expectEqualStrings("8", split.right[0].pin_numbers);
    try testing.expectEqualStrings("9", split.right[1].pin_numbers);
}

test "functional height split does not pair signal pins through a supply rail" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    var ctx = RenderCtx.init(allocator);
    ctx.render_scratch.functional_layout = true;

    for ([_][]const u8{ "R_PULLUP_A", "R_PULLUP_B" }) |ref| {
        try ctx.spoke_set.put(allocator, ref, {});
    }
    var a_adj: std.ArrayList(AdjEntry) = .empty;
    try a_adj.append(allocator, .{ .pin = "1", .endpoint = .{ .pin = .{ .ref_des = "U1", .pin = "2" } } });
    try a_adj.append(allocator, .{ .pin = "2", .endpoint = .{ .net = "VDD" } });
    try ctx.adjacency.put(allocator, "R_PULLUP_A", a_adj);
    var b_adj: std.ArrayList(AdjEntry) = .empty;
    try b_adj.append(allocator, .{ .pin = "1", .endpoint = .{ .pin = .{ .ref_des = "U1", .pin = "3" } } });
    try b_adj.append(allocator, .{ .pin = "2", .endpoint = .{ .net = "VDD" } });
    try ctx.adjacency.put(allocator, "R_PULLUP_B", b_adj);
    var supply_pins: std.ArrayList(env_mod.PinRef) = .empty;
    try supply_pins.appendSlice(allocator, &.{
        .{ .ref_des = "R_PULLUP_A", .pin = "2" },
        .{ .ref_des = "R_PULLUP_B", .pin = "2" },
    });
    try ctx.net_index.put(allocator, "VDD", supply_pins);

    const groups = [_]PinGroup{
        .{ .display_name = "", .pin_numbers = "1", .conns = &.{} },
        .{ .display_name = "A", .pin_numbers = "2", .stub_pins = &.{"2"}, .conns = &.{.{ .pin = "2", .endpoint = .{ .pin = .{ .ref_des = "R_PULLUP_A", .pin = "1" } } }} },
        .{ .display_name = "B", .pin_numbers = "3", .stub_pins = &.{"3"}, .conns = &.{.{ .pin = "3", .endpoint = .{ .pin = .{ .ref_des = "R_PULLUP_B", .pin = "1" } } }} },
        .{ .display_name = "", .pin_numbers = "4", .conns = &.{} },
    };
    const split = try splitGroupsByHeight(&ctx, &groups, "U1");

    try testing.expectEqual(@as(usize, 2), split.left.len);
    try testing.expectEqual(@as(usize, 2), split.right.len);
}

test "groupHeights ignores a suppressed own-net label" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    var ctx = RenderCtx.init(allocator);
    try ctx.significant_nets.put(allocator, "LOCAL", {});
    try ctx.significant_nets.put(allocator, "VISIBLE", {});
    try ctx.pin_canonical_nets.put(allocator, "U1.1", "LOCAL");
    const groups = [_]PinGroup{.{
        .display_name = "IO",
        .pin_numbers = "1",
        .conns = &.{
            .{ .pin = "1", .endpoint = .{ .net = "LOCAL" } },
            .{ .pin = "1", .endpoint = .{ .net = "VISIBLE" } },
        },
    }};

    const heights = try groupHeights(&ctx, &groups, "U1");
    try testing.expectEqual(@as(f64, 40.0), heights[0]);
}
