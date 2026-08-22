//! Ordered two-terminal RF paths extracted from the flattened physical netlist.
//!
//! Placement objectives usually see each net independently.  A series DC-block
//! capacitor therefore looks like two unrelated ratlines even though the useful
//! physical object is one ordered path:
//!
//!     switch pad -> capacitor pad 1 | capacitor pad 2 -> launch pad
//!
//! This module recovers that object without importing `optimizer.zig` (and thus
//! remains safe for the optimizer to import).  It only accepts unambiguous,
//! point-to-point critical nets.  Branched RF nets are deliberately reported and
//! skipped: a rough placer must fall back or use authored intent rather than
//! silently guess which endpoint owns a branch.

const std = @import("std");
const flat_netlist = @import("../flat_netlist.zig");
const net_rules = @import("net_rules.zig");

/// Flattened physical net type consumed by the extractor.
pub const FlatNet = flat_netlist.FlatNet;
/// Resolved per-net routing rule type consumed by the extractor.
pub const NetRule = net_rules.NetRule;

/// Optional classification supplied by the placement front end.  `.auto` is
/// sufficient for the common RF shape: a many-pad/many-RF-pin switch becomes
/// an anchor, a one-RF-pin launch becomes a terminal, and a physical two-pad
/// part joining two critical nets becomes a series element.
pub const PartRole = enum {
    auto,
    anchor,
    terminal,
    series,
    ignore,
};

/// The small, cycle-free projection of a placement part needed for topology
/// extraction. `pad_count` is the physical footprint pad count, not merely the
/// number of pins that happen to appear on critical nets.  That distinction is
/// what keeps a multi-pad RF IC with two RF pins from looking like a two-pad
/// series passive.
pub const Part = struct {
    ref_des: []const u8,
    pad_count: usize,
    role: PartRole = .auto,
};

/// Topological role inferred from critical-only net incidence.
pub const ResolvedRole = enum {
    anchor,
    terminal,
    series,
    other,
    ignored,
};

/// Exact identity of one physical pad in the caller's `parts` array.
pub const PadRef = struct {
    part: usize,
    pad: []const u8,
};

/// One point-to-point copper connection, oriented from the owning anchor toward
/// the terminal.  `net` indexes the caller's flattened net/rule arrays.
pub const Link = struct {
    net: usize,
    from: PadRef,
    to: PadRef,
};

/// Pad polarity of a two-pad series part after ordering the complete path.
/// Placement can orient `in_pad` toward the anchor and `out_pad` toward the
/// launch instead of minimizing two independent ratlines.
pub const SeriesStep = struct {
    part: usize,
    in_pad: []const u8,
    out_pad: []const u8,
};

/// Routing importance accumulated over every net in a recovered path.  These
/// are facts, rather than a pre-blended scalar, so the placement arbiter can use
/// a lexicographic policy (vias/bends before small length improvements).
pub const Importance = struct {
    max_freq_hz: f64 = 0,
    priority: u32 = 0,
    controlled_impedance: bool = false,
    max_target_ohms: f64 = 0,
    max_escape_mm: f64 = 0,
    max_keepout_mm: f64 = 0,

    fn include(self: *Importance, rule: NetRule) void {
        self.max_freq_hz = @max(self.max_freq_hz, rule.rf.max_freq_hz);
        self.priority = @max(self.priority, rule.priority);
        const ohms = @max(rule.rf.impedance.ohms, rule.rf.impedance.diff_ohms);
        self.controlled_impedance = self.controlled_impedance or ohms > 0;
        self.max_target_ohms = @max(self.max_target_ohms, ohms);
        self.max_escape_mm = @max(self.max_escape_mm, rule.rf.escape_mm);
        self.max_keepout_mm = @max(self.max_keepout_mm, rule.rf.keepout_mm);
    }
};

/// One ordered anchor-to-terminal route motif. `links` includes the exact pad
/// pair on every constituent net; `series` records the through-body transitions
/// between adjacent links.
pub const Path = struct {
    hub: usize,
    terminal: usize,
    links: []const Link,
    series: []const SeriesStep,
    importance: Importance,

    /// Exact owner-side pad that begins this ordered path.
    pub fn hubPad(self: Path) PadRef {
        return self.links[0].from;
    }

    /// Exact terminal-side pad that ends this ordered path.
    pub fn terminalPad(self: Path) PadRef {
        return self.links[self.links.len - 1].to;
    }
};

/// Paths sharing one local RF owner.  Path indices are stable indices into
/// `Result.paths`; `members` contains the hub, every series part, and every
/// terminal exactly once in caller part order.
pub const Island = struct {
    hub: usize,
    paths: []const usize,
    members: []const usize,
};

/// Counts of ambiguous inputs deliberately excluded from automatic paths.
pub const Diagnostics = struct {
    critical_nets: usize = 0,
    /// Critical nets that were not point-to-point after ignored parts were
    /// removed.  They require authored intent or a more general tree motif.
    branched_nets: usize = 0,
    /// Critical pins whose ref-des was absent from `parts`; such a net is never
    /// used to infer a path.
    unresolved_pins: usize = 0,
    /// Anchor edges that entered another anchor/ordinary part or formed a
    /// series-only cycle instead of reaching a terminal.
    incomplete_paths: usize = 0,
};

/// Complete ordered-path, island, role, and diagnostic extraction result.
pub const Result = struct {
    roles: []const ResolvedRole,
    paths: []const Path,
    islands: []const Island,
    diagnostics: Diagnostics,
    /// Rules are retained by net index so design-level geometry can evaluate
    /// the same controlled width, escape, and bend radius as final routing.
    rules: []const NetRule = &.{},
};

/// A net opts into RF physical-path extraction only through authored RF facts,
/// never its spelling.  Controlled impedance is sufficient even if a maximum
/// frequency was omitted; routing priority alone is intentionally insufficient.
fn isCriticalRule(rule: NetRule) bool {
    return rule.rf.max_freq_hz > 0 or
        rule.rf.impedance.ohms > 0 or
        rule.rf.impedance.diff_ohms > 0;
}

const Incident = struct {
    net: usize,
    pad: []const u8,
    peer: usize,
    peer_pad: []const u8,
};

fn ruleAt(rules: []const NetRule, net: usize) NetRule {
    return if (net < rules.len) rules[net] else .{};
}

fn samePad(a: PadRef, b: PadRef) bool {
    return a.part == b.part and std.mem.eql(u8, a.pad, b.pad);
}

fn containsPad(pads: []const PadRef, want: PadRef) bool {
    for (pads) |pad| if (samePad(pad, want)) return true;
    return false;
}

fn inferRole(part: Part, incidents: []const Incident) ResolvedRole {
    return switch (part.role) {
        .anchor => .anchor,
        .terminal => .terminal,
        .series => .series,
        .ignore => .ignored,
        .auto => blk: {
            if (incidents.len == 0) break :blk .other;
            if (incidents.len == 1) break :blk .terminal;
            const two_terminal = part.pad_count == 2 and incidents.len == 2;
            const bridges_nets = two_terminal and incidents[0].net != incidents[1].net;
            if (bridges_nets and !std.mem.eql(u8, incidents[0].pad, incidents[1].pad)) {
                break :blk .series;
            }
            break :blk .anchor;
        },
    };
}

fn appendTerminalPairs(
    arena: std.mem.Allocator,
    roles: []ResolvedRole,
    incidents: []const std.ArrayList(Incident),
    rules: []const NetRule,
    paths: *std.ArrayList(Path),
    islands: *std.ArrayList(Island),
) std.mem.Allocator.Error!void {
    for (roles, 0..) |role, a| {
        if (role != .terminal or incidents[a].items.len != 1) continue;
        const incident = incidents[a].items[0];
        const b = incident.peer;
        if (a >= b or roles[b] != .terminal or incidents[b].items.len != 1) continue;
        var importance: Importance = .{};
        importance.include(ruleAt(rules, incident.net));
        const links = try arena.alloc(Link, 1);
        links[0] = .{ .net = incident.net, .from = .{ .part = a, .pad = incident.pad }, .to = .{ .part = b, .pad = incident.peer_pad } };
        const path_index = paths.items.len;
        try paths.append(arena, .{ .hub = a, .terminal = b, .links = links, .series = &.{}, .importance = importance });
        roles[a] = .anchor;
        const path_indices = try arena.dupe(usize, &.{path_index});
        const members = try arena.dupe(usize, &.{ a, b });
        try islands.append(arena, .{ .hub = a, .paths = path_indices, .members = members });
    }
}

/// Extract ordered RF paths and group them into local-hub islands.
///
/// All returned slices and internal indices live in `arena`; callers normally
/// pass the same per-solve arena used to prepare placement geometry.  `parts`
/// must contain unique ref-des values. Duplicate names are rejected because an
/// exact physical pad identity would otherwise be ambiguous.
pub fn extract(
    arena: std.mem.Allocator,
    parts: []const Part,
    nets: []const FlatNet,
    rules: []const NetRule,
) (std.mem.Allocator.Error || error{DuplicatePart})!Result {
    var diagnostics: Diagnostics = .{};

    var part_of = std.StringHashMapUnmanaged(usize).empty;
    for (parts, 0..) |part, i| {
        const gop = try part_of.getOrPut(arena, part.ref_des);
        if (gop.found_existing) return error.DuplicatePart;
        gop.value_ptr.* = i;
    }

    const incidents = try arena.alloc(std.ArrayList(Incident), parts.len);
    for (incidents) |*list| list.* = .empty;

    // Build only exact two-ended links. An ignored test point may be removed
    // explicitly, but an unknown ref or any remaining third pad makes the net
    // ambiguous and therefore unusable for automatic path construction.
    for (nets, 0..) |net, ni| {
        if (!isCriticalRule(ruleAt(rules, ni))) continue;
        diagnostics.critical_nets += 1;

        var endpoints: std.ArrayList(PadRef) = .empty;
        var unresolved = false;
        for (net.pins) |pin| {
            const pi = part_of.get(pin.ref_des) orelse {
                diagnostics.unresolved_pins += 1;
                unresolved = true;
                continue;
            };
            if (parts[pi].role == .ignore) continue;
            const endpoint = PadRef{ .part = pi, .pad = pin.pin };
            if (!containsPad(endpoints.items, endpoint)) try endpoints.append(arena, endpoint);
        }
        if (unresolved or endpoints.items.len != 2 or endpoints.items[0].part == endpoints.items[1].part) {
            diagnostics.branched_nets += 1;
            continue;
        }
        const a = endpoints.items[0];
        const b = endpoints.items[1];
        try incidents[a.part].append(arena, .{ .net = ni, .pad = a.pad, .peer = b.part, .peer_pad = b.pad });
        try incidents[b.part].append(arena, .{ .net = ni, .pad = b.pad, .peer = a.part, .peer_pad = a.pad });
    }

    const roles = try arena.alloc(ResolvedRole, parts.len);
    for (parts, incidents, roles) |part, part_incidents, *role| {
        role.* = inferRole(part, part_incidents.items);
    }

    var paths: std.ArrayList(Path) = .empty;
    var islands: std.ArrayList(Island) = .empty;
    const seen = try arena.alloc(bool, parts.len);
    const member_mask = try arena.alloc(bool, parts.len);

    for (parts, 0..) |_, hub| {
        if (roles[hub] != .anchor) continue;
        const first_path = paths.items.len;
        @memset(member_mask, false);
        member_mask[hub] = true;

        for (incidents[hub].items) |first| {
            @memset(seen, false);
            seen[hub] = true;
            var links: std.ArrayList(Link) = .empty;
            var series: std.ArrayList(SeriesStep) = .empty;
            var importance: Importance = .{};

            try links.append(arena, .{
                .net = first.net,
                .from = .{ .part = hub, .pad = first.pad },
                .to = .{ .part = first.peer, .pad = first.peer_pad },
            });
            importance.include(ruleAt(rules, first.net));

            var current = first.peer;
            var arrived_pad = first.peer_pad;
            var incoming_net = first.net;
            var terminal: ?usize = null;
            var steps: usize = 0;
            while (steps < parts.len) : (steps += 1) {
                if (seen[current]) break;
                seen[current] = true;
                switch (roles[current]) {
                    .terminal => {
                        terminal = current;
                        break;
                    },
                    .series => {
                        if (incidents[current].items.len != 2) break;
                        const a = incidents[current].items[0];
                        const b = incidents[current].items[1];
                        const next = if (a.net != incoming_net) a else if (b.net != incoming_net) b else break;
                        if (next.net == incoming_net or std.mem.eql(u8, next.pad, arrived_pad)) break;
                        try series.append(arena, .{ .part = current, .in_pad = arrived_pad, .out_pad = next.pad });
                        try links.append(arena, .{
                            .net = next.net,
                            .from = .{ .part = current, .pad = next.pad },
                            .to = .{ .part = next.peer, .pad = next.peer_pad },
                        });
                        importance.include(ruleAt(rules, next.net));
                        incoming_net = next.net;
                        current = next.peer;
                        arrived_pad = next.peer_pad;
                    },
                    else => break,
                }
            }

            const target = terminal orelse {
                diagnostics.incomplete_paths += 1;
                continue;
            };
            try paths.append(arena, .{
                .hub = hub,
                .terminal = target,
                .links = try links.toOwnedSlice(arena),
                .series = try series.toOwnedSlice(arena),
                .importance = importance,
            });
            member_mask[target] = true;
            for (paths.items[paths.items.len - 1].series) |step| member_mask[step.part] = true;
        }

        if (paths.items.len == first_path) continue;
        const path_indices = try arena.alloc(usize, paths.items.len - first_path);
        for (path_indices, 0..) |*pi, offset| pi.* = first_path + offset;
        var members: std.ArrayList(usize) = .empty;
        for (member_mask, 0..) |member, pi| if (member) try members.append(arena, pi);
        try islands.append(arena, .{
            .hub = hub,
            .paths = path_indices,
            .members = try members.toOwnedSlice(arena),
        });
    }

    // A calibration THRU is deliberately just two one-port launches. Neither
    // endpoint has enough RF incidence to infer an IC-like anchor, but the
    // exact point-to-point net is still an unambiguous ordered physical path.
    // Give the lower part index temporary ownership so design roughing can
    // face and space the pair; each incident is unique, so no real switch path
    // can enter this branch.
    try appendTerminalPairs(arena, roles, incidents, rules, &paths, &islands);

    return .{
        .roles = roles,
        .paths = try paths.toOwnedSlice(arena),
        .islands = try islands.toOwnedSlice(arena),
        .diagnostics = diagnostics,
        .rules = rules,
    };
}

const test_rf_rule = NetRule{
    .priority = 90,
    .rf = .{
        .max_freq_hz = 6.0e9,
        .escape_mm = 1.0,
        .keepout_mm = 0.3,
        .impedance = .{ .ohms = 50 },
    },
};

fn testPin(ref_des: []const u8, pad: []const u8) flat_netlist.FlatPin {
    return .{ .ref_des = ref_des, .pin = pad };
}

test "critical paths recover series polarity and group local switch islands" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parts = [_]Part{
        .{ .ref_des = "U1", .pad_count = 16 },
        .{ .ref_des = "C1", .pad_count = 2 },
        .{ .ref_des = "J1", .pad_count = 2 },
        .{ .ref_des = "C2", .pad_count = 2 },
        .{ .ref_des = "J2", .pad_count = 2 },
        .{ .ref_des = "U2", .pad_count = 6 },
        .{ .ref_des = "J3", .pad_count = 2 },
        .{ .ref_des = "J4", .pad_count = 2 },
    };
    const n0 = [_]flat_netlist.FlatPin{ testPin("U1", "2"), testPin("C1", "1") };
    const n1 = [_]flat_netlist.FlatPin{ testPin("C1", "2"), testPin("J1", "1") };
    const n2 = [_]flat_netlist.FlatPin{ testPin("U1", "14"), testPin("C2", "1") };
    const n3 = [_]flat_netlist.FlatPin{ testPin("C2", "2"), testPin("J2", "1") };
    const n4 = [_]flat_netlist.FlatPin{ testPin("U2", "5"), testPin("J3", "1") };
    const n5 = [_]flat_netlist.FlatPin{ testPin("U2", "3"), testPin("J4", "1") };
    const gnd = [_]flat_netlist.FlatPin{ testPin("J1", "G1"), testPin("J2", "G1"), testPin("J3", "G1"), testPin("J4", "G1") };
    const nets = [_]FlatNet{
        .{ .name = "SKY_RFC_IC", .pins = &n0 },
        .{ .name = "SKY_RFC", .pins = &n1 },
        .{ .name = "SKY_RF1_IC", .pins = &n2 },
        .{ .name = "SKY_RF1", .pins = &n3 },
        .{ .name = "BGS_RFIN", .pins = &n4 },
        .{ .name = "BGS_RF1", .pins = &n5 },
        .{ .name = "GND", .pins = &gnd },
    };
    const rules = [_]NetRule{ test_rf_rule, test_rf_rule, test_rf_rule, test_rf_rule, test_rf_rule, test_rf_rule, .{} };

    const result = try extract(arena, &parts, &nets, &rules);
    try std.testing.expectEqual(@as(usize, 4), result.paths.len);
    try std.testing.expectEqual(@as(usize, 2), result.islands.len);
    try std.testing.expectEqual(ResolvedRole.anchor, result.roles[0]);
    try std.testing.expectEqual(ResolvedRole.series, result.roles[1]);
    try std.testing.expectEqual(ResolvedRole.terminal, result.roles[2]);
    try std.testing.expectEqual(ResolvedRole.anchor, result.roles[5]);

    const sky_rfc = result.paths[0];
    try std.testing.expectEqual(@as(usize, 0), sky_rfc.hub);
    try std.testing.expectEqual(@as(usize, 2), sky_rfc.terminal);
    try std.testing.expectEqual(@as(usize, 2), sky_rfc.links.len);
    try std.testing.expectEqual(@as(usize, 1), sky_rfc.series.len);
    try std.testing.expectEqualStrings("2", sky_rfc.hubPad().pad);
    try std.testing.expectEqualStrings("1", sky_rfc.series[0].in_pad);
    try std.testing.expectEqualStrings("2", sky_rfc.series[0].out_pad);
    try std.testing.expectEqualStrings("1", sky_rfc.terminalPad().pad);
    try std.testing.expectEqual(@as(f64, 6.0e9), sky_rfc.importance.max_freq_hz);
    try std.testing.expect(sky_rfc.importance.controlled_impedance);

    try std.testing.expectEqual(@as(usize, 5), result.islands[0].members.len);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3, 4 }, result.islands[0].members);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, result.islands[0].paths);
    try std.testing.expectEqualSlices(usize, &.{ 2, 3 }, result.islands[1].paths);
}

test "critical paths refuse a branched RF net instead of guessing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parts = [_]Part{
        .{ .ref_des = "U1", .pad_count = 8, .role = .anchor },
        .{ .ref_des = "J1", .pad_count = 2 },
        .{ .ref_des = "TP1", .pad_count = 1 },
    };
    const branch = [_]flat_netlist.FlatPin{ testPin("U1", "RF"), testPin("J1", "1"), testPin("TP1", "1") };
    const nets = [_]FlatNet{.{ .name = "RF", .pins = &branch }};
    const rules = [_]NetRule{test_rf_rule};

    const result = try extract(arena, &parts, &nets, &rules);
    try std.testing.expectEqual(@as(usize, 0), result.paths.len);
    try std.testing.expectEqual(@as(usize, 1), result.diagnostics.critical_nets);
    try std.testing.expectEqual(@as(usize, 1), result.diagnostics.branched_nets);
}

test "ignored probe restores an otherwise point-to-point physical path" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parts = [_]Part{
        .{ .ref_des = "U1", .pad_count = 8, .role = .anchor },
        .{ .ref_des = "J1", .pad_count = 2 },
        .{ .ref_des = "TP1", .pad_count = 1, .role = .ignore },
    };
    const branch = [_]flat_netlist.FlatPin{ testPin("U1", "RF"), testPin("J1", "1"), testPin("TP1", "1") };
    const nets = [_]FlatNet{.{ .name = "RF", .pins = &branch }};
    const rules = [_]NetRule{test_rf_rule};

    const result = try extract(arena, &parts, &nets, &rules);
    try std.testing.expectEqual(@as(usize, 1), result.paths.len);
    try std.testing.expectEqual(@as(usize, 1), result.islands.len);
    try std.testing.expectEqual(ResolvedRole.ignored, result.roles[2]);
}

// spec: placement/rf-port-frame-routing - a terminal-to-terminal RF calibration net becomes its own physical island
test "terminal-to-terminal RF calibration net becomes its own physical island" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parts = [_]Part{
        .{ .ref_des = "J11", .pad_count = 2 },
        .{ .ref_des = "J12", .pad_count = 2 },
    };
    const pins = [_]flat_netlist.FlatPin{ testPin("J11", "1"), testPin("J12", "1") };
    const nets = [_]FlatNet{.{ .name = "CAL_THRU", .pins = &pins }};
    const rules = [_]NetRule{test_rf_rule};
    const result = try extract(arena, &parts, &nets, &rules);
    try std.testing.expectEqual(@as(usize, 1), result.paths.len);
    try std.testing.expectEqual(@as(usize, 1), result.islands.len);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, result.islands[0].members);
    try std.testing.expectEqualStrings("1", result.paths[0].hubPad().pad);
    try std.testing.expectEqualStrings("1", result.paths[0].terminalPad().pad);
}

test "controlled impedance qualifies but routing priority alone does not" {
    try std.testing.expect(isCriticalRule(.{ .rf = .{ .impedance = .{ .ohms = 50 } } }));
    try std.testing.expect(isCriticalRule(.{ .rf = .{ .impedance = .{ .diff_ohms = 100 } } }));
    try std.testing.expect(!isCriticalRule(.{ .priority = 100 }));
    try std.testing.expect(!isCriticalRule(.{}));
}
