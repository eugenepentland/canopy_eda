//! One net's electrical junction list, decided by the canonical contact policy
//! in `copper_contact.zig` — the very predicates the DRC topology oracle
//! (`fab_readiness.buildNetGraph`, read by `net_open.zig`) uses to decide
//! whether a net's copper is one island.
//!
//! `power_current.zig` used to decide that for itself, with private centreline
//! rules: a trace end joined another trace only within half the NARROWER
//! trace's width, a via only inside its own barrel radius, a pad only where a
//! node already happened to exist. Those rules are strictly tighter than the
//! fabrication bottleneck rule, so a rail that DRC calls solid came back
//! `disconnected` from the current solve and every conductor on it silently
//! fell back to the whole-rail envelope. This module closes that gap: it reads
//! the same solver input, applies the canonical predicates, and hands back the
//! explicit junctions `power_current.Input.joins` accepts.
//!
//! `guardian.toml` forbids `src/placement/*` importing `fab_readiness.zig`
//! (placement COMPUTES a board, readiness INSPECTS one), so the four-line
//! union-find below is deliberately a second copy of the one that file uses
//! rather than an import. Only `islandCount` needs it, and only to let tests
//! state the parity property directly.

const std = @import("std");
const copper_contact = @import("copper_contact.zig");
const pad_shape = @import("pad_shape.zig");
const power_current = @import("power_current.zig");

const Segment = power_current.Segment;
const Barrel = power_current.Barrel;
const Contact = power_current.Contact;
const Join = power_current.Join;
const Input = power_current.Input;

/// Every junction the canonical contact policy finds in one net's solver
/// input. Feeding these back through `Input.joins` makes the current solve
/// agree with DRC topology about what is one piece of copper.
pub fn joinsFor(alloc: std.mem.Allocator, input: Input) std.mem.Allocator.Error![]const Join {
    var out: std.ArrayList(Join) = .empty;
    try appendTrackTrack(alloc, input, &out);
    try appendTrackVia(alloc, input, &out);
    try appendViaVia(alloc, input, &out);
    try appendTerminals(alloc, input, &out);
    try appendSheets(alloc, input, &out);
    return out.items;
}

/// How many islands this net's copper forms under the same predicates. One
/// island means every terminal shares metal with every other, which is exactly
/// the condition under which `power_current.solve` must not answer
/// `disconnected`.
pub fn islandCount(alloc: std.mem.Allocator, input: Input) std.mem.Allocator.Error!usize {
    const bases = Bases.of(input);
    const parent = try alloc.alloc(usize, bases.load + input.loads.len);
    for (parent, 0..) |*slot, i| slot.* = i;

    const route_of_track = try alloc.alloc(?usize, input.counts.tracks);
    const route_of_via = try alloc.alloc(?usize, input.counts.vias);
    @memset(route_of_track, null);
    @memset(route_of_via, null);
    for (input.segments, 0..) |segment, i| {
        if (segment.route_index < route_of_track.len) route_of_track[segment.route_index] = i;
    }
    for (input.barrels, 0..) |barrel, i| {
        if (barrel.route_index < route_of_via.len) route_of_via[barrel.route_index] = i;
    }
    for (try joinsFor(alloc, input)) |join| {
        const a = nodeOfAnchor(join.a, route_of_track, route_of_via, bases) orelse continue;
        const b = nodeOfAnchor(join.b, route_of_track, route_of_via, bases) orelse continue;
        unite(parent, a, b);
    }

    var roots: std.ArrayList(usize) = .empty;
    for (0..parent.len) |node| {
        if (!present(input, node, bases)) continue;
        const root = find(parent, node);
        var seen = false;
        for (roots.items) |old| if (old == root) {
            seen = true;
            break;
        };
        if (!seen) try roots.append(alloc, root);
    }
    return roots.items.len;
}

/// Where each kind of feature starts in the flat union-find node array:
/// tracks first (base 0), then vias, then sheets, then the one source
/// terminal, then the loads.
const Bases = struct {
    via: usize,
    sheet: usize,
    source: usize,
    load: usize,

    fn of(input: Input) Bases {
        const via = input.segments.len;
        const sheet = via + input.barrels.len;
        const source = sheet + input.sheets.len;
        return .{ .via = via, .sheet = sheet, .source = source, .load = source + 1 };
    }
};

fn present(input: Input, node: usize, bases: Bases) bool {
    if (node < bases.source) return true;
    if (node == bases.source) return input.source.contacts.len > 0;
    return input.loads[node - bases.load].contacts.len > 0;
}

fn nodeOfAnchor(
    anchor: power_current.Anchor,
    route_of_track: []const ?usize,
    route_of_via: []const ?usize,
    bases: Bases,
) ?usize {
    return switch (anchor) {
        .track => |ref| offsetNode(route_of_track, ref.index, 0),
        .via => |index| offsetNode(route_of_via, index, bases.via),
        .sheet => |index| bases.sheet + index,
        .source => bases.source,
        .load => |index| bases.load + index,
    };
}

fn offsetNode(map: []const ?usize, route_index: usize, base: usize) ?usize {
    if (route_index >= map.len) return null;
    const position = map[route_index] orelse return null;
    return base + position;
}

fn find(parent: []usize, node: usize) usize {
    var root = node;
    while (parent[root] != root) root = parent[root];
    var walk = node;
    while (parent[walk] != root) {
        const next = parent[walk];
        parent[walk] = root;
        walk = next;
    }
    return root;
}

fn unite(parent: []usize, a: usize, b: usize) void {
    const ra = find(parent, a);
    const rb = find(parent, b);
    if (ra != rb) parent[ra] = rb;
}

fn traceOf(segment: Segment) copper_contact.Trace {
    return .{ .a = segment.a, .b = segment.b, .width = segment.width_mm };
}

fn barrelLand(barrel: Barrel) copper_contact.Via {
    return .{ .at = barrel.at, .dia = barrel.radius_mm * 2 };
}

/// A terminal's land as this solve knows it: `reach_mm` is the pad bounding
/// box's circumradius, so the disc is the smallest circle that certainly
/// contains the land. Judging the pad as that disc is looser than judging the
/// true outline, but it is strictly TIGHTER than the "any node within reach"
/// rule it replaces, so no join this returns is new over-connection.
fn terminalLand(contact: Contact) copper_contact.Via {
    return .{ .at = contact.at, .dia = contact.reach_mm * 2 };
}

fn contactOnLayer(contact: Contact, layer: u8) bool {
    return copper_contact.padOnLayer(contact.layer == null, contact.layer orelse layer, layer);
}

fn boxesNear(a: Segment, b: Segment, slack: f64) bool {
    if (@min(a.a[0], a.b[0]) - slack > @max(b.a[0], b.b[0])) return false;
    if (@min(b.a[0], b.b[0]) - slack > @max(a.a[0], a.b[0])) return false;
    if (@min(a.a[1], a.b[1]) - slack > @max(b.a[1], b.b[1])) return false;
    if (@min(b.a[1], b.b[1]) - slack > @max(a.a[1], a.b[1])) return false;
    return true;
}

const Meet = struct { on_a: [2]f64, on_b: [2]f64 };

/// Where two joined centrelines are closest — the point the junction cuts both
/// traces at. Crossing traces meet at their intersection; otherwise the best of
/// the four endpoint projections is the witness of the closest approach.
fn meetOf(a: Segment, b: Segment) Meet {
    if (crossPoint(a, b)) |p| return .{ .on_a = p, .on_b = p };
    var best = std.math.inf(f64);
    var out = Meet{ .on_a = a.a, .on_b = b.a };
    for ([2][2]f64{ b.a, b.b }) |p| {
        const near = pad_shape.closestOnSeg(a.a[0], a.a[1], a.b[0], a.b[1], p[0], p[1]);
        if (near.d < best) {
            best = near.d;
            out = .{ .on_a = .{ near.x, near.y }, .on_b = p };
        }
    }
    for ([2][2]f64{ a.a, a.b }) |p| {
        const near = pad_shape.closestOnSeg(b.a[0], b.a[1], b.b[0], b.b[1], p[0], p[1]);
        if (near.d < best) {
            best = near.d;
            out = .{ .on_a = p, .on_b = .{ near.x, near.y } };
        }
    }
    return out;
}

fn crossPoint(a: Segment, b: Segment) ?[2]f64 {
    const t = power_current.crossParam(a, b) orelse return null;
    return .{ a.a[0] + (a.b[0] - a.a[0]) * t, a.a[1] + (a.b[1] - a.a[1]) * t };
}

fn closestOn(segment: Segment, at: [2]f64) [2]f64 {
    const near = pad_shape.closestOnSeg(segment.a[0], segment.a[1], segment.b[0], segment.b[1], at[0], at[1]);
    return .{ near.x, near.y };
}

fn appendTrackTrack(alloc: std.mem.Allocator, input: Input, out: *std.ArrayList(Join)) std.mem.Allocator.Error!void {
    for (input.segments, 0..) |a, i| {
        for (input.segments[i + 1 ..]) |b| {
            if (a.layer != b.layer) continue;
            const slack = a.width_mm / 2 + b.width_mm / 2 + copper_contact.join_slack_mm;
            if (!boxesNear(a, b, slack)) continue;
            if (!copper_contact.trackTrackConnects(traceOf(a), traceOf(b))) continue;
            const meet = meetOf(a, b);
            try out.append(alloc, .{
                .a = .{ .track = .{ .index = a.route_index, .at = meet.on_a } },
                .b = .{ .track = .{ .index = b.route_index, .at = meet.on_b } },
            });
        }
    }
}

fn appendTrackVia(alloc: std.mem.Allocator, input: Input, out: *std.ArrayList(Join)) std.mem.Allocator.Error!void {
    for (input.segments) |segment| {
        for (input.barrels) |barrel| {
            if (!copper_contact.trackViaConnects(traceOf(segment), barrelLand(barrel))) continue;
            try out.append(alloc, .{
                .a = .{ .track = .{ .index = segment.route_index, .at = closestOn(segment, barrel.at) } },
                .b = .{ .via = barrel.route_index },
            });
        }
    }
}

fn appendViaVia(alloc: std.mem.Allocator, input: Input, out: *std.ArrayList(Join)) std.mem.Allocator.Error!void {
    for (input.barrels, 0..) |a, i| {
        for (input.barrels[i + 1 ..]) |b| {
            const reach = a.radius_mm + b.radius_mm + copper_contact.join_slack_mm;
            if (std.math.hypot(a.at[0] - b.at[0], a.at[1] - b.at[1]) > reach) continue;
            try out.append(alloc, .{ .a = .{ .via = a.route_index }, .b = .{ .via = b.route_index } });
        }
    }
}

fn appendTerminals(alloc: std.mem.Allocator, input: Input, out: *std.ArrayList(Join)) std.mem.Allocator.Error!void {
    try appendTerminal(alloc, input, out, .source, input.source.contacts);
    for (input.loads, 0..) |load, i| try appendTerminal(alloc, input, out, .{ .load = i }, load.contacts);
}

fn appendTerminal(
    alloc: std.mem.Allocator,
    input: Input,
    out: *std.ArrayList(Join),
    anchor: power_current.Anchor,
    contacts: []const Contact,
) std.mem.Allocator.Error!void {
    for (contacts) |contact| {
        if (!(contact.reach_mm > 0)) continue;
        for (input.segments) |segment| {
            if (!contactOnLayer(contact, segment.layer)) continue;
            if (!copper_contact.trackViaConnects(traceOf(segment), terminalLand(contact))) continue;
            try out.append(alloc, .{
                .a = anchor,
                .b = .{ .track = .{ .index = segment.route_index, .at = closestOn(segment, contact.at) } },
            });
        }
        for (input.barrels) |barrel| {
            const reach = contact.reach_mm + barrel.radius_mm + copper_contact.join_slack_mm;
            if (std.math.hypot(contact.at[0] - barrel.at[0], contact.at[1] - barrel.at[1]) > reach) continue;
            try out.append(alloc, .{ .a = anchor, .b = .{ .via = barrel.route_index } });
        }
    }
}

/// A pour component's contact points come straight from `pour.Fill`, so a
/// point is on the sheet by construction. What has to be decided here is which
/// piece of routed copper that point belongs to — the solver's own sheet
/// attachment lands on the exact contact coordinate, which is beside the
/// trace's centreline whenever the contact sits off-axis, and therefore builds
/// an island node instead of joining the trace.
fn appendSheets(alloc: std.mem.Allocator, input: Input, out: *std.ArrayList(Join)) std.mem.Allocator.Error!void {
    for (input.sheets, 0..) |sheet, si| {
        for (sheet.contacts) |at| {
            for (input.segments) |segment| {
                if (segment.layer != sheet.layer or !(segment.width_mm > 0)) continue;
                const gap = pad_shape.segPointDist(segment.a[0], segment.a[1], segment.b[0], segment.b[1], at[0], at[1]);
                if (gap > segment.width_mm / 2 + copper_contact.join_slack_mm) continue;
                try out.append(alloc, .{
                    .a = .{ .sheet = si },
                    .b = .{ .track = .{ .index = segment.route_index, .at = closestOn(segment, at) } },
                });
            }
            for (input.barrels) |barrel| {
                const reach = barrel.radius_mm + copper_contact.join_slack_mm;
                if (std.math.hypot(at[0] - barrel.at[0], at[1] - barrel.at[1]) > reach) continue;
                try out.append(alloc, .{ .a = .{ .sheet = si }, .b = .{ .via = barrel.route_index } });
            }
        }
        // One tie per terminal, not one per contact point: a pour that touches
        // a pad at fifty sampled points is still one junction, and fifty
        // parallel micro-ohm ties would only wreck the matrix's conditioning.
        try appendSheetTerminal(alloc, out, si, sheet.contacts, .source, input.source.contacts);
        for (input.loads, 0..) |load, i| {
            try appendSheetTerminal(alloc, out, si, sheet.contacts, .{ .load = i }, load.contacts);
        }
    }
}

fn appendSheetTerminal(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(Join),
    sheet_index: usize,
    points: []const [2]f64,
    anchor: power_current.Anchor,
    contacts: []const Contact,
) std.mem.Allocator.Error!void {
    for (points) |at| {
        for (contacts) |contact| {
            // The pour's own contact list already applied the layer and
            // membership rules, so the pad is credited exactly when one of
            // those points IS the pad anchor. Matching at the contact's reach
            // instead would let an inner plane adopt a top land it never
            // touched; a via sitting on the pad reaches the sheet through the
            // pad-via and via-sheet junctions instead.
            if (std.math.hypot(at[0] - contact.at[0], at[1] - contact.at[1]) > copper_contact.join_slack_mm) continue;
            try out.append(alloc, .{ .a = .{ .sheet = sheet_index }, .b = anchor });
            return;
        }
    }
}

const testing = std.testing;

/// The audit's barracuda shape: a thin branch T-ing into the interior of a
/// wide trunk. The branch's whole cross-section lies inside the trunk's
/// copper, so `copper_contact` calls it connected; the solver's own snap only
/// reaches half the BRANCH's width and calls it open.
fn tJunction(joins: []const Join) Input {
    return .{
        .segments = &[_]Segment{
            .{ .route_index = 0, .a = .{ 0, 0 }, .b = .{ 4, 0 }, .layer = 0, .resistance_ohm_per_mm = 0.001, .width_mm = 2.0 },
            .{ .route_index = 1, .a = .{ 2, 0.9 }, .b = .{ 2, 3 }, .layer = 0, .resistance_ohm_per_mm = 0.01, .width_mm = 0.2 },
        },
        .barrels = &.{},
        .counts = .{ .tracks = 2, .vias = 0 },
        .source = .{ .contacts = &.{.{ .at = .{ 0, 0 }, .layer = 0, .reach_mm = 0.3 }}, .complete = true },
        .loads = &[_]power_current.Load{.{
            .contacts = &.{.{ .at = .{ 2, 3 }, .layer = 0, .reach_mm = 0.3 }},
            .typical_a = 1,
            .maximum_a = null,
        }},
        .joins = joins,
    };
}

// spec: placement/power-routing - the current solver's connectivity follows the canonical copper-contact policy, so a branch that overlaps the trunk's copper is one node even when the centrelines miss
test "canonical junctions connect a T branch the solver's own snap misses" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const bare = tJunction(&.{});
    try testing.expectEqual(power_current.Status.disconnected, (try power_current.solve(arena, bare)).typical.status);

    var joined = bare;
    joined.joins = try joinsFor(arena, bare);
    try testing.expect(joined.joins.len > 0);
    const result = try power_current.solve(arena, joined);
    try testing.expectEqual(power_current.Status.solved, result.typical.status);
    try testing.expectApproxEqAbs(@as(f64, 1.0), result.typical.track_current_a[1], 1e-9);
}

// spec: placement/power-routing - a net whose canonical copper topology is a single island never solves disconnected
test "a single-island net never solves disconnected" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bare = tJunction(&.{});
    try testing.expectEqual(@as(usize, 1), try islandCount(arena, bare));

    var joined = bare;
    joined.joins = try joinsFor(arena, bare);
    const result = try power_current.solve(arena, joined);
    try testing.expect(result.typical.status.isSolved());
}

// spec: placement/power-routing - copper the canonical policy leaves open stays two islands, so a genuinely broken rail is still reported
test "an open gap stays two islands and stays disconnected" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A 0.15 mm centreline gap between two 0.2 mm traces: no complete
    // cross-section of either fits in the other, so this is a real open.
    const input: Input = .{
        .segments = &[_]Segment{
            .{ .route_index = 0, .a = .{ 0, 0 }, .b = .{ 1, 0 }, .layer = 0, .resistance_ohm_per_mm = 0.01, .width_mm = 0.2 },
            .{ .route_index = 1, .a = .{ 1.15, 0 }, .b = .{ 2, 0 }, .layer = 0, .resistance_ohm_per_mm = 0.01, .width_mm = 0.2 },
        },
        .barrels = &.{},
        .counts = .{ .tracks = 2, .vias = 0 },
        .source = .{ .contacts = &.{.{ .at = .{ 0, 0 }, .layer = 0, .reach_mm = 0.05 }}, .complete = true },
        .loads = &[_]power_current.Load{.{
            .contacts = &.{.{ .at = .{ 2, 0 }, .layer = 0, .reach_mm = 0.05 }},
            .typical_a = 1,
            .maximum_a = null,
        }},
    };
    try testing.expectEqual(@as(usize, 2), try islandCount(arena, input));
    var joined = input;
    joined.joins = try joinsFor(arena, input);
    try testing.expectEqual(power_current.Status.disconnected, (try power_current.solve(arena, joined)).typical.status);
}

// spec: placement/power-routing - a pour component joins the traces whose copper covers its contact points, not only traces whose centreline passes exactly through them
test "a sheet contact off a trace centreline still joins that trace" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Both contacts sit 0.2 mm off the traces' centrelines, inside their copper.
    const sheet_points = [_][2]f64{ .{ 1, 0.2 }, .{ 3, 0.2 } };
    const input: Input = .{
        .segments = &[_]Segment{
            .{ .route_index = 0, .a = .{ 0, 0 }, .b = .{ 1, 0 }, .layer = 0, .resistance_ohm_per_mm = 0.01, .width_mm = 0.6 },
            .{ .route_index = 1, .a = .{ 3, 0 }, .b = .{ 4, 0 }, .layer = 0, .resistance_ohm_per_mm = 0.01, .width_mm = 0.6 },
        },
        .barrels = &.{},
        .sheets = &.{.{ .layer = 0, .contacts = &sheet_points }},
        .counts = .{ .tracks = 2, .vias = 0 },
        .source = .{ .contacts = &.{.{ .at = .{ 0, 0 }, .layer = 0, .reach_mm = 0.05 }}, .complete = true },
        .loads = &[_]power_current.Load{.{
            .contacts = &.{.{ .at = .{ 4, 0 }, .layer = 0, .reach_mm = 0.05 }},
            .typical_a = 1,
            .maximum_a = null,
        }},
    };
    try testing.expectEqual(power_current.Status.disconnected, (try power_current.solve(arena, input)).typical.status);
    var joined = input;
    joined.joins = try joinsFor(arena, input);
    const result = try power_current.solve(arena, joined);
    try testing.expectEqual(power_current.Status.solved, result.typical.status);
    try testing.expectApproxEqAbs(@as(f64, 1.0), result.typical.track_current_a[0], 1e-8);
}
