//! The `(near "REF" PIN [(own PAD)])` adjacency model the placement passes read:
//! which pad of which part a layout-critical passive was told to sit beside.
//!
//! `(decouples …)` says "this bypass cap serves that supply pin", and carries a
//! ground return and a loop with it. `(near …)` says only "this leg belongs at
//! that pad" — a series termination at its driver, a feedback resistor at FB, an
//! RF matching element at the port it matches, a bulk cap at the rail's entry
//! pin. There is no return path to measure, so a near binding NEVER produces a
//! `Loop`: it never enters the inductance score and never reaches plane
//! stitching. It is adjacency, nothing more.
//!
//! Resolution is deliberately a shared, pure pass rather than something the
//! solver does inline, because three consumers must agree about it — the seed's
//! ownership/target ladder, the `bound-far` layout lint, and the `bindings`
//! facts `/api/pcb-describe` reports. A binding that resolved one way for the
//! placer and another for the report would be worse than no report.
//!
//! Like `cap_bind.zig`, this holds only ref-des and pad STRINGS, never the
//! solver's `Part` values, so the dependency runs one way and the module stays
//! testable without a board.

const std = @import("std");
const flat_netlist = @import("../flat_netlist.zig");

const FlatInstance = flat_netlist.FlatInstance;
const FlatNet = flat_netlist.FlatNet;

/// One resolved `(near …)` adjacency: the declaring part, the pad of its own it
/// docks with, and the exact part + pad it must sit beside. Indices are into the
/// index-aligned `instances` slice the solver's `parts` mirror.
pub const NearPair = struct {
    /// The declaring passive.
    part: usize,
    /// The part it must sit beside.
    target: usize,
    /// The declaring part's own pad — `(own PAD)` when spelled, else the leg
    /// that shares a net with the target pin.
    own_pin: []const u8,
    /// The target's pad, as resolved by `builders.resolveNearTargets`.
    target_pin: []const u8,
    /// The flattened net both pads sit on. Carried so the drawn adjacency
    /// airwire can be coloured by net class like any other link.
    net: []const u8,
};

/// Why a declared `(near …)` produced no pair. Each is a distinct authoring
/// mistake, so the lint names which one rather than saying "unresolved".
pub const Why = enum {
    /// The named ref is not a part on this board (a typo, or a part that only
    /// exists in another sub-block).
    no_such_ref,
    /// The named ref exists but carries no such pad on any net — an unresolved
    /// function name, a pad number the part does not have, or a genuinely
    /// unconnected pin.
    pin_not_on_target,
    /// Neither of the declaring part's legs sits on the target pin's net, so
    /// there is no electrical reason for the two to be adjacent.
    no_shared_net,
    /// `(own PAD)` names a pad that is not on the target pin's net.
    own_pad_off_net,

    /// One-line explanation, for the lint message.
    pub fn text(self: Why) []const u8 {
        return switch (self) {
            .no_such_ref => "names a part that is not on this board",
            .pin_not_on_target => "names a pad the target does not carry on any net",
            .no_shared_net => "shares no net with the target pad",
            .own_pad_off_net => "declares an (own PAD) that is not on the target pad's net",
        };
    }
};

/// One declared-but-unresolved `(near …)`, kept so the lint can report a
/// binding the author wrote and the board could not honour. Silently dropping
/// it would leave the part placed by the generic heuristics with no sign that
/// the declaration did nothing.
pub const Unresolved = struct {
    part: usize,
    why: Why,
};

/// Everything one `resolve` pass found.
pub const Resolved = struct {
    pairs: []const NearPair = &.{},
    unresolved: []const Unresolved = &.{},
};

/// Resolve every flattened instance's `(near …)` declaration against the
/// flattened netlist. Allocates into `arena`; index-aligned with `instances`.
///
/// The own pad defaults to the declaring part's leg on the target pin's net,
/// taken in net-membership order so the choice is deterministic; `(own PAD)`
/// overrides it and is checked against that same net. A part whose BOTH legs sit
/// on the target net and which spells no `(own PAD)` binds its first leg — the
/// `(own PAD)` override exists exactly for that case, and guessing is better
/// than refusing since either leg puts the body at the pad.
pub fn resolve(
    arena: std.mem.Allocator,
    instances: []const FlatInstance,
    nets: []const FlatNet,
) std.mem.Allocator.Error!Resolved {
    var idx_of: std.StringHashMapUnmanaged(usize) = .empty;
    for (instances, 0..) |inst, i| try idx_of.put(arena, inst.ref_des, i);

    var pairs: std.ArrayList(NearPair) = .empty;
    var bad: std.ArrayList(Unresolved) = .empty;
    for (instances, 0..) |inst, pi| {
        const nb = inst.bind.near;
        if (nb.ref.len == 0 or nb.pin.len == 0) continue;
        const ti = idx_of.get(nb.ref) orelse {
            try bad.append(arena, .{ .part = pi, .why = .no_such_ref });
            continue;
        };
        const net = netCarrying(nets, nb.ref, nb.pin) orelse {
            try bad.append(arena, .{ .part = pi, .why = .pin_not_on_target });
            continue;
        };
        const own = ownPinOn(net, inst.ref_des, nb.own) orelse {
            try bad.append(arena, .{
                .part = pi,
                .why = if (nb.own.len > 0) .own_pad_off_net else .no_shared_net,
            });
            continue;
        };
        try pairs.append(arena, .{
            .part = pi,
            .target = ti,
            .own_pin = own,
            .target_pin = nb.pin,
            .net = net.name,
        });
    }
    return .{
        .pairs = try pairs.toOwnedSlice(arena),
        .unresolved = try bad.toOwnedSlice(arena),
    };
}

/// The net carrying `ref`'s pad `pin`, or null when no net does.
fn netCarrying(nets: []const FlatNet, ref: []const u8, pin: []const u8) ?FlatNet {
    for (nets) |net| {
        for (net.pins) |pr| {
            if (std.mem.eql(u8, pr.ref_des, ref) and std.mem.eql(u8, pr.pin, pin)) return net;
        }
    }
    return null;
}

/// The declaring part's pad on `net`: `want` when spelled (and only when it is
/// genuinely on this net), else its first pad in net order.
fn ownPinOn(net: FlatNet, ref: []const u8, want: []const u8) ?[]const u8 {
    for (net.pins) |pr| {
        if (!std.mem.eql(u8, pr.ref_des, ref)) continue;
        if (want.len == 0) return pr.pin;
        if (std.mem.eql(u8, pr.pin, want)) return pr.pin;
    }
    return null;
}

const testing = std.testing;

fn fixtureInstance(ref: []const u8, near: @import("../eval/env.zig").NearBind) FlatInstance {
    return .{
        .ref_des = ref,
        .component = "",
        .value = "",
        .footprint = "",
        .properties = &.{},
        .uuid = "",
        .bind = .{ .near = near },
    };
}

// spec: placement/optimizer - a (near "REF" PIN) binding resolves to the declaring part's leg on the target pad's net
test "resolve infers the own pad from the shared net" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const insts = [_]FlatInstance{
        fixtureInstance("U3", .{}),
        fixtureInstance("R1", .{ .ref = "U3", .pin = "14" }),
    };
    const nets = [_]FlatNet{
        .{ .name = "GPIO10", .pins = &.{
            .{ .ref_des = "U3", .pin = "14" },
            .{ .ref_des = "R1", .pin = "1" },
        } },
        .{ .name = "TAP", .pins = &.{
            .{ .ref_des = "R1", .pin = "2" },
            .{ .ref_des = "J1", .pin = "3" },
        } },
    };
    const r = try resolve(arena, &insts, &nets);
    try testing.expectEqual(@as(usize, 0), r.unresolved.len);
    try testing.expectEqual(@as(usize, 1), r.pairs.len);
    try testing.expectEqual(@as(usize, 1), r.pairs[0].part);
    try testing.expectEqual(@as(usize, 0), r.pairs[0].target);
    try testing.expectEqualStrings("1", r.pairs[0].own_pin);
    try testing.expectEqualStrings("14", r.pairs[0].target_pin);
    try testing.expectEqualStrings("GPIO10", r.pairs[0].net);
}

// spec: placement/optimizer - (own PAD) overrides the inferred leg and an off-net (own PAD) resolves nothing
test "resolve honours (own PAD) and rejects one off the target net" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Both of R1's legs sit on the target pad's net (a strap doubled onto one
    // rail), so `(own 2)` is the only way to say which leg docks.
    const insts = [_]FlatInstance{
        fixtureInstance("U3", .{}),
        fixtureInstance("R1", .{ .ref = "U3", .pin = "7", .own = "2" }),
        fixtureInstance("R2", .{ .ref = "U3", .pin = "7", .own = "9" }),
    };
    const nets = [_]FlatNet{
        .{ .name = "VREF", .pins = &.{
            .{ .ref_des = "U3", .pin = "7" },
            .{ .ref_des = "R1", .pin = "1" },
            .{ .ref_des = "R1", .pin = "2" },
            .{ .ref_des = "R2", .pin = "1" },
        } },
    };
    const r = try resolve(arena, &insts, &nets);
    try testing.expectEqual(@as(usize, 1), r.pairs.len);
    try testing.expectEqualStrings("2", r.pairs[0].own_pin);
    // R2's `(own 9)` is not on VREF at all: no pair, and the lint hears why.
    try testing.expectEqual(@as(usize, 1), r.unresolved.len);
    try testing.expectEqual(@as(usize, 2), r.unresolved[0].part);
    try testing.expectEqual(Why.own_pad_off_net, r.unresolved[0].why);
}

// spec: placement/optimizer - a (near …) naming an absent ref, an absent pad, or a foreign net resolves nothing and is reported
test "resolve reports each way a near binding fails to land" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const insts = [_]FlatInstance{
        fixtureInstance("U3", .{}),
        fixtureInstance("R1", .{ .ref = "U9", .pin = "1" }), // no such ref
        fixtureInstance("R2", .{ .ref = "U3", .pin = "99" }), // pad not on any net
        fixtureInstance("R3", .{ .ref = "U3", .pin = "14" }), // shares no net
    };
    const nets = [_]FlatNet{
        .{ .name = "GPIO10", .pins = &.{
            .{ .ref_des = "U3", .pin = "14" },
            .{ .ref_des = "R1", .pin = "1" },
        } },
        .{ .name = "ELSEWHERE", .pins = &.{
            .{ .ref_des = "R3", .pin = "1" },
            .{ .ref_des = "R3", .pin = "2" },
        } },
    };
    const r = try resolve(arena, &insts, &nets);
    try testing.expectEqual(@as(usize, 0), r.pairs.len);
    try testing.expectEqual(@as(usize, 3), r.unresolved.len);
    try testing.expectEqual(Why.no_such_ref, r.unresolved[0].why);
    try testing.expectEqual(Why.pin_not_on_target, r.unresolved[1].why);
    try testing.expectEqual(Why.no_shared_net, r.unresolved[2].why);
}

// spec: placement/optimizer - a design that declares no (near …) resolves to no adjacency pairs at all
test "resolve is a no-op on a board with no near bindings" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const insts = [_]FlatInstance{ fixtureInstance("U1", .{}), fixtureInstance("C1", .{}) };
    const nets = [_]FlatNet{.{ .name = "VDD", .pins = &.{
        .{ .ref_des = "U1", .pin = "1" },
        .{ .ref_des = "C1", .pin = "1" },
    } }};
    const r = try resolve(arena, &insts, &nets);
    try testing.expectEqual(@as(usize, 0), r.pairs.len);
    try testing.expectEqual(@as(usize, 0), r.unresolved.len);
}
