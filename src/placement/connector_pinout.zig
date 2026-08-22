//! Request-local constrained connector-pin assignment search.
//!
//! The search preserves the connector's net-token multiplicities, honours
//! caller-fixed pins, seats ordered/adjacent signal groups with optional ground
//! shells, then hill-climbs the remaining pins against a placement-derived
//! wirelength and crossing surrogate. It never edits schematic or layout data.

const std = @import("std");

/// One board-space point in millimetres.
pub const Point = struct { x: f64, y: f64 };

/// One physical connector pad eligible for assignment.
pub const Pin = struct {
    name: []const u8,
    at: Point,
};

/// One distinct connector net and the non-connector terminals it must reach.
pub const Net = struct {
    name: []const u8,
    remote: []const Point = &.{},
    ignore_cost: bool = false,
};

/// A hard pin-to-net assignment.
pub const Fixed = struct { pin: usize, net: usize };

/// Restrict one net token to a caller-supplied set of connector pins.
pub const Allowed = struct { net: usize, pins: []const usize };

/// An adjacent/ordered signal group with an optional surrounding guard net.
pub const Group = struct {
    nets: []const usize,
    max_spacing_mm: f64 = 0,
    ordered: bool = false,
    guard_net: ?usize = null,
    guard_radius_mm: f64 = 0,
};

/// Hard assignment, eligibility, grouping, and movement constraints.
pub const Constraints = struct {
    fixed: []const Fixed = &.{},
    allowed: []const Allowed = &.{},
    groups: []const Group = &.{},
    movable: []const bool = &.{},
};

/// Bounded deterministic search controls.
pub const Options = struct {
    samples: usize = 2000,
    top_k: usize = 10,
    seed: u64 = 1,
};

/// Complete connector assignment problem.
pub const Problem = struct {
    pins: []const Pin,
    nets: []const Net,
    /// One dense net index per connector pin. Duplicate indices preserve
    /// multi-contact rails and returns as indistinguishable assignment tokens.
    current: []const usize,
    constraints: Constraints = .{},
    options: Options = .{},
};

/// One ranked virtual pin map; lower cost is better.
pub const Candidate = struct {
    assignment: []const usize,
    cost: f64,
};

/// Search telemetry and the retained best unique candidates.
pub const Result = struct {
    candidates: []const Candidate,
    evaluated: usize,
    feasible: usize,
    baseline_cost: f64,
};

/// Search validation plus allocation failures.
pub const SearchError = std.mem.Allocator.Error || error{
    InvalidProblem,
    InvalidConstraint,
    GroupNetMustHaveOneConnectorPin,
};

const max_pins = 128;
const crossing_cost_mm = 2.0;

const Rng = struct {
    state: u64,

    fn next(self: *Rng) u64 {
        var x = self.state;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.state = if (x == 0) 0x9e3779b97f4a7c15 else x;
        return self.state;
    }

    fn below(self: *Rng, n: usize) usize {
        return if (n == 0) 0 else @intCast(self.next() % n);
    }
};

const Workspace = struct {
    assignment: [max_pins]usize,
    reserved: [max_pins]bool,
    desired: [max_pins]?usize,
    tokens: [max_pins]usize,
    filled: [max_pins]bool,
};

/// Search without mutating the caller's problem or persistent design data.
pub fn search(alloc: std.mem.Allocator, p: Problem) SearchError!Result {
    try validateProblem(p);
    const keep = @min(@max(p.options.top_k, 1), 100);
    const sample_count = @min(@max(p.options.samples, 1), 200_000);
    var best: std.ArrayList(Candidate) = .empty;
    var rng = Rng{ .state = if (p.options.seed == 0) 1 else p.options.seed };
    var evaluated: usize = 0;
    var feasible: usize = 0;
    var work: Workspace = undefined;

    for (0..sample_count) |sample_i| {
        if (!buildSeed(p, &rng, sample_i == 0, &work)) continue;
        evaluated += 1;
        const assignment = work.assignment[0..p.pins.len];
        improve(p, &rng, assignment, work.reserved[0..p.pins.len]);
        if (violationCount(p, assignment) != 0) continue;
        feasible += 1;
        try retain(alloc, &best, keep, assignment, assignmentScore(p, assignment));
    }

    std.mem.sort(Candidate, best.items, {}, cheaper);
    return .{
        .candidates = try best.toOwnedSlice(alloc),
        .evaluated = evaluated,
        .feasible = feasible,
        .baseline_cost = assignmentScore(p, p.current),
    };
}

fn validateProblem(p: Problem) SearchError!void {
    const bad_size = p.pins.len == 0 or p.pins.len != p.current.len;
    if (bad_size or p.pins.len > max_pins or p.nets.len == 0) return error.InvalidProblem;
    if (p.nets.len > max_pins) return error.InvalidProblem;
    for (p.current) |n| if (n >= p.nets.len) return error.InvalidProblem;
    const movable = p.constraints.movable;
    if (movable.len != 0 and movable.len != p.pins.len) return error.InvalidProblem;
    for (p.constraints.fixed) |f| {
        if (f.pin >= p.pins.len or f.net >= p.nets.len) return error.InvalidConstraint;
    }
    for (p.constraints.allowed) |a| {
        if (a.net >= p.nets.len) return error.InvalidConstraint;
        for (a.pins) |pin| if (pin >= p.pins.len) return error.InvalidConstraint;
    }
    var counts: [max_pins]usize = @splat(0);
    for (p.current) |n| counts[n] += 1;
    for (p.constraints.groups) |g| try validateGroup(p, g, &counts);
}

fn validateGroup(p: Problem, group: Group, counts: *const [max_pins]usize) SearchError!void {
    if (group.nets.len == 0 or group.nets.len > 8) return error.InvalidConstraint;
    for (group.nets) |net| {
        if (net >= p.nets.len) return error.InvalidConstraint;
        if (counts[net] != 1) return error.GroupNetMustHaveOneConnectorPin;
    }
    if (group.guard_net) |net| if (net >= p.nets.len) return error.InvalidConstraint;
}

fn buildSeed(p: Problem, rng: *Rng, prefer_current: bool, work: *Workspace) bool {
    const desired = work.desired[0..p.pins.len];
    const reserved = work.reserved[0..p.pins.len];
    @memset(desired, null);
    @memset(reserved, false);
    if (!reserveStatic(p, desired, reserved)) return false;
    if (!reserveGroups(p, rng, prefer_current, desired, reserved)) return false;
    const token_n = remainingTokens(p, desired, &work.tokens) orelse return false;
    if (!prefer_current) shuffle(rng, work.tokens[0..token_n]);
    const ok = fillFree(
        p,
        prefer_current,
        desired,
        work.tokens[0..token_n],
        work.assignment[0..p.pins.len],
        work.filled[0..p.pins.len],
    );
    if (!ok) return false;
    return violationCount(p, work.assignment[0..p.pins.len]) == 0;
}

fn reserveStatic(p: Problem, desired: []?usize, reserved: []bool) bool {
    if (p.constraints.movable.len != 0) {
        for (p.constraints.movable, 0..) |can_move, pin| {
            if (can_move) continue;
            if (!placeDesired(desired, reserved, pin, p.current[pin])) return false;
        }
    }
    for (p.constraints.fixed) |fixed| {
        if (!placeDesired(desired, reserved, fixed.pin, fixed.net)) return false;
    }
    return true;
}

fn reserveGroups(
    p: Problem,
    rng: *Rng,
    prefer_current: bool,
    desired: []?usize,
    reserved: []bool,
) bool {
    for (p.constraints.groups) |group| {
        var seats: [8]usize = undefined;
        const chosen = seats[0..group.nets.len];
        if (!chooseSeats(p, group, rng, prefer_current, desired, chosen)) return false;
        for (group.nets, chosen) |net, pin| {
            if (!placeDesired(desired, reserved, pin, net)) return false;
        }
        if (!reserveGuard(p, group, chosen, desired, reserved)) return false;
    }
    return true;
}

fn reserveGuard(
    p: Problem,
    group: Group,
    seats: []const usize,
    desired: []?usize,
    reserved: []bool,
) bool {
    const guard = group.guard_net orelse return true;
    if (group.guard_radius_mm <= 0) return true;
    for (seats) |seat| {
        for (p.pins, 0..) |other, pin| {
            if (contains(seats, pin)) continue;
            if (distance(p.pins[seat].at, other.at) > group.guard_radius_mm + 1e-9) continue;
            if (!placeDesired(desired, reserved, pin, guard)) return false;
        }
    }
    return true;
}

fn remainingTokens(p: Problem, desired: []const ?usize, tokens: *[max_pins]usize) ?usize {
    var count: [max_pins]usize = @splat(0);
    for (p.current) |net| count[net] += 1;
    for (desired) |want| if (want) |net| {
        if (count[net] == 0) return null;
        count[net] -= 1;
    };
    var len: usize = 0;
    for (count[0..p.nets.len], 0..) |amount, net| {
        for (0..amount) |_| {
            tokens[len] = net;
            len += 1;
        }
    }
    return len;
}

fn fillFree(
    p: Problem,
    prefer_current: bool,
    desired: []const ?usize,
    tokens: []const usize,
    out: []usize,
    filled: []bool,
) bool {
    var used: [max_pins]bool = @splat(false);
    @memset(filled, false);
    for (desired, 0..) |want, pin| if (want) |net| {
        out[pin] = net;
        filled[pin] = true;
    };
    if (prefer_current) fillCurrentWherePossible(p, desired, tokens, out, filled, &used);
    for (desired, 0..) |want, pin| {
        if (want != null or filled[pin]) continue;
        const token_i = findAllowedToken(p, tokens, &used, pin) orelse return false;
        out[pin] = tokens[token_i];
        used[token_i] = true;
        filled[pin] = true;
    }
    return true;
}

fn fillCurrentWherePossible(
    p: Problem,
    desired: []const ?usize,
    tokens: []const usize,
    out: []usize,
    filled: []bool,
    used: *[max_pins]bool,
) void {
    for (desired, 0..) |want, pin| {
        if (want != null) continue;
        const current = p.current[pin];
        for (tokens, 0..) |token, token_i| {
            if (used[token_i] or token != current) continue;
            if (!allowedAt(p, current, pin)) continue;
            out[pin] = current;
            filled[pin] = true;
            used[token_i] = true;
            break;
        }
    }
}

fn findAllowedToken(p: Problem, tokens: []const usize, used: *const [max_pins]bool, pin: usize) ?usize {
    for (tokens, 0..) |token, token_i| {
        if (!used[token_i] and allowedAt(p, token, pin)) return token_i;
    }
    return null;
}

fn chooseSeats(
    p: Problem,
    group: Group,
    rng: *Rng,
    prefer_current: bool,
    desired: []const ?usize,
    out: []usize,
) bool {
    if (prefer_current) {
        for (group.nets, 0..) |net, i| out[i] = indexOf(p.current, net) orelse return false;
        if (seatValid(p, group, desired, out)) return true;
    }
    for (0..512) |_| {
        for (group.nets, 0..) |net, i| {
            out[i] = fixedPinFor(p, net) orelse rng.below(p.pins.len);
        }
        if (seatValid(p, group, desired, out)) return true;
    }
    if (group.nets.len != 1) return false;
    for (p.pins, 0..) |_, pin| {
        out[0] = pin;
        if (seatValid(p, group, desired, out)) return true;
    }
    return false;
}

fn seatValid(p: Problem, group: Group, desired: []const ?usize, seats: []const usize) bool {
    for (seats, 0..) |pin, i| {
        if (pin >= p.pins.len) return false;
        if (contains(seats[0..i], pin)) return false;
        if (desired[pin]) |net| if (net != group.nets[i]) return false;
        if (!allowedAt(p, group.nets[i], pin)) return false;
        if (fixedPinFor(p, group.nets[i])) |fixed_pin| if (fixed_pin != pin) return false;
        if (i > 0 and group.max_spacing_mm > 0) {
            const previous = p.pins[seats[i - 1]].at;
            if (distance(previous, p.pins[pin].at) > group.max_spacing_mm + 1e-9) return false;
        }
    }
    if (!group.ordered or seats.len < 2) return true;
    const axis = majorAxis(p.pins);
    for (1..seats.len) |i| {
        const before = project(p.pins[seats[i - 1]].at, axis);
        if (before >= project(p.pins[seats[i]].at, axis)) return false;
    }
    return true;
}

fn improve(p: Problem, rng: *Rng, assignment: []usize, reserved: []const bool) void {
    var best = assignmentScore(p, assignment);
    const attempts = @max(256, assignment.len * assignment.len * 4);
    for (0..attempts) |_| {
        const a = rng.below(assignment.len);
        const b = rng.below(assignment.len);
        if (!maySwap(p, assignment, reserved, a, b)) continue;
        std.mem.swap(usize, &assignment[a], &assignment[b]);
        const next = assignmentScore(p, assignment);
        if (next + 1e-9 < best) {
            best = next;
        } else {
            std.mem.swap(usize, &assignment[a], &assignment[b]);
        }
    }
}

fn maySwap(p: Problem, assignment: []const usize, reserved: []const bool, a: usize, b: usize) bool {
    if (a == b or reserved[a] or reserved[b]) return false;
    const movable = p.constraints.movable;
    if (movable.len != 0) {
        if (!movable[a] or !movable[b]) return false;
    }
    const na = assignment[a];
    const nb = assignment[b];
    if (na == nb) return false;
    return allowedAt(p, na, b) and allowedAt(p, nb, a);
}

fn assignmentScore(p: Problem, assignment: []const usize) f64 {
    var total: f64 = 0;
    const axis = majorAxis(p.pins);
    for (p.nets, 0..) |net, net_i| {
        if (net.ignore_cost or net.remote.len == 0) continue;
        total += netBoundingCost(p, assignment, net_i, net);
    }
    return total + crossingCost(p, assignment, axis);
}

fn netBoundingCost(p: Problem, assignment: []const usize, net_i: usize, net: Net) f64 {
    var minx = std.math.inf(f64);
    var miny = std.math.inf(f64);
    var maxx = -std.math.inf(f64);
    var maxy = -std.math.inf(f64);
    for (net.remote) |point| grow(&minx, &miny, &maxx, &maxy, point);
    for (assignment, 0..) |assigned, pin| {
        if (assigned == net_i) grow(&minx, &miny, &maxx, &maxy, p.pins[pin].at);
    }
    return (maxx - minx) + (maxy - miny);
}

fn crossingCost(p: Problem, assignment: []const usize, axis: Axis) f64 {
    var total: f64 = 0;
    for (p.nets, 0..) |a_net, a| {
        if (a_net.ignore_cost or a_net.remote.len == 0) continue;
        const ap = uniquePin(assignment, a) orelse continue;
        const ar = remoteProjection(a_net.remote, axis);
        for (p.nets[a + 1 ..], a + 1..) |b_net, b| {
            if (b_net.ignore_cost or b_net.remote.len == 0) continue;
            const bp = uniquePin(assignment, b) orelse continue;
            const br = remoteProjection(b_net.remote, axis);
            const pin_delta = project(p.pins[ap].at, axis) - project(p.pins[bp].at, axis);
            if (pin_delta * (ar - br) < 0) total += crossing_cost_mm;
        }
    }
    return total;
}

fn violationCount(p: Problem, assignment: []const usize) usize {
    var bad: usize = 0;
    for (p.constraints.fixed) |fixed| if (assignment[fixed.pin] != fixed.net) {
        bad += 1;
    };
    bad += movementViolations(p, assignment);
    for (assignment, 0..) |net, pin| if (!allowedAt(p, net, pin)) {
        bad += 1;
    };
    for (p.constraints.groups) |group| bad += groupViolations(p, assignment, group);
    return bad;
}

fn movementViolations(p: Problem, assignment: []const usize) usize {
    const movable = p.constraints.movable;
    if (movable.len == 0) return 0;
    var bad: usize = 0;
    for (movable, 0..) |can_move, pin| {
        if (!can_move and assignment[pin] != p.current[pin]) bad += 1;
    }
    return bad;
}

fn groupViolations(p: Problem, assignment: []const usize, group: Group) usize {
    var seats: [8]usize = undefined;
    for (group.nets, 0..) |net, i| seats[i] = uniquePin(assignment, net) orelse return 1;
    var no_desired: [max_pins]?usize = @splat(null);
    const chosen = seats[0..group.nets.len];
    if (!seatValid(p, group, &no_desired, chosen)) return 1;
    const guard = group.guard_net orelse return 0;
    if (group.guard_radius_mm <= 0) return 0;
    var bad: usize = 0;
    for (chosen) |seat| {
        for (p.pins, 0..) |other, pin| {
            if (contains(chosen, pin)) continue;
            if (distance(p.pins[seat].at, other.at) <= group.guard_radius_mm + 1e-9) {
                if (assignment[pin] != guard) bad += 1;
            }
        }
    }
    return bad;
}

fn allowedAt(p: Problem, net: usize, pin: usize) bool {
    for (p.constraints.allowed) |allowed| {
        if (allowed.net == net) return contains(allowed.pins, pin);
    }
    return true;
}

fn placeDesired(desired: []?usize, reserved: []bool, pin: usize, net: usize) bool {
    if (desired[pin]) |old| if (old != net) return false;
    desired[pin] = net;
    reserved[pin] = true;
    return true;
}

fn fixedPinFor(p: Problem, net: usize) ?usize {
    for (p.constraints.fixed) |fixed| if (fixed.net == net) return fixed.pin;
    return null;
}

fn retain(
    alloc: std.mem.Allocator,
    best: *std.ArrayList(Candidate),
    limit: usize,
    assignment: []const usize,
    cost: f64,
) std.mem.Allocator.Error!void {
    for (best.items) |candidate| {
        if (std.mem.eql(usize, candidate.assignment, assignment)) return;
    }
    try best.append(alloc, .{ .assignment = try alloc.dupe(usize, assignment), .cost = cost });
    std.mem.sort(Candidate, best.items, {}, cheaper);
    if (best.items.len <= limit) return;
    const dropped = best.pop().?;
    alloc.free(dropped.assignment);
}

fn cheaper(_: void, a: Candidate, b: Candidate) bool {
    return a.cost < b.cost;
}

fn uniquePin(assignment: []const usize, net: usize) ?usize {
    var found: ?usize = null;
    for (assignment, 0..) |assigned, pin| {
        if (assigned != net) continue;
        if (found != null) return null;
        found = pin;
    }
    return found;
}

fn indexOf(items: []const usize, wanted: usize) ?usize {
    for (items, 0..) |item, i| if (item == wanted) return i;
    return null;
}

fn contains(items: []const usize, wanted: usize) bool {
    return indexOf(items, wanted) != null;
}

fn shuffle(rng: *Rng, items: []usize) void {
    var n = items.len;
    while (n > 1) {
        const j = rng.below(n);
        n -= 1;
        std.mem.swap(usize, &items[n], &items[j]);
    }
}

fn grow(minx: *f64, miny: *f64, maxx: *f64, maxy: *f64, point: Point) void {
    minx.* = @min(minx.*, point.x);
    miny.* = @min(miny.*, point.y);
    maxx.* = @max(maxx.*, point.x);
    maxy.* = @max(maxy.*, point.y);
}

fn distance(a: Point, b: Point) f64 {
    return std.math.hypot(a.x - b.x, a.y - b.y);
}

const Axis = enum { x, y };

fn majorAxis(pins: []const Pin) Axis {
    var minx = std.math.inf(f64);
    var miny = std.math.inf(f64);
    var maxx = -std.math.inf(f64);
    var maxy = -std.math.inf(f64);
    for (pins) |pin| grow(&minx, &miny, &maxx, &maxy, pin.at);
    return if (maxx - minx > maxy - miny) .x else .y;
}

fn project(point: Point, axis: Axis) f64 {
    return if (axis == .x) point.x else point.y;
}

fn remoteProjection(points: []const Point, axis: Axis) f64 {
    var sum: f64 = 0;
    for (points) |point| sum += project(point, axis);
    return sum / @as(f64, @floatFromInt(points.len));
}

fn freeResult(alloc: std.mem.Allocator, result: Result) void {
    for (result.candidates) |candidate| alloc.free(candidate.assignment);
    alloc.free(result.candidates);
}

test "fixed guarded signal keeps a complete ground shell" {
    const pins = [_]Pin{
        .{ .name = "1", .at = .{ .x = 0, .y = 0 } },
        .{ .name = "2", .at = .{ .x = 1, .y = 0 } },
        .{ .name = "3", .at = .{ .x = 2, .y = 0 } },
        .{ .name = "4", .at = .{ .x = 0, .y = 1 } },
        .{ .name = "5", .at = .{ .x = 1, .y = 1 } },
        .{ .name = "6", .at = .{ .x = 2, .y = 1 } },
    };
    const nets = [_]Net{
        .{ .name = "GND", .ignore_cost = true },
        .{ .name = "IF", .remote = &.{.{ .x = -5, .y = 0 }} },
        .{ .name = "A", .remote = &.{.{ .x = 5, .y = 0 }} },
    };
    const group_nets = [_]usize{1};
    const result = try search(std.testing.allocator, .{
        .pins = &pins,
        .nets = &nets,
        .current = &.{ 0, 1, 0, 0, 2, 0 },
        .constraints = .{
            .fixed = &.{.{ .pin = 1, .net = 1 }},
            .groups = &.{.{
                .nets = &group_nets,
                .guard_net = 0,
                .guard_radius_mm = 1.1,
            }},
        },
        .options = .{ .samples = 50, .top_k = 3 },
    });
    defer freeResult(std.testing.allocator, result);
    try std.testing.expect(result.candidates.len > 0);
    const assignment = result.candidates[0].assignment;
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 0 }, assignment[0..3]);
    try std.testing.expectEqual(@as(usize, 0), assignment[4]);
}

test "ordered adjacent pair follows connector major axis" {
    const pins = [_]Pin{
        .{ .name = "1", .at = .{ .x = 0, .y = 0 } },
        .{ .name = "2", .at = .{ .x = 0, .y = 1 } },
        .{ .name = "3", .at = .{ .x = 0, .y = 2 } },
        .{ .name = "4", .at = .{ .x = 0, .y = 3 } },
    };
    const nets = [_]Net{
        .{ .name = "N", .remote = &.{.{ .x = -2, .y = 0 }} },
        .{ .name = "P", .remote = &.{.{ .x = -2, .y = 1 }} },
        .{ .name = "A" },
        .{ .name = "B" },
    };
    const pair = [_]usize{ 0, 1 };
    const result = try search(std.testing.allocator, .{
        .pins = &pins,
        .nets = &nets,
        .current = &.{ 0, 1, 2, 3 },
        .constraints = .{ .groups = &.{.{
            .nets = &pair,
            .max_spacing_mm = 1.01,
            .ordered = true,
        }} },
        .options = .{ .samples = 100, .top_k = 4 },
    });
    defer freeResult(std.testing.allocator, result);
    try std.testing.expect(result.candidates.len > 0);
    for (result.candidates) |candidate| {
        const n = uniquePin(candidate.assignment, 0).?;
        const positive = uniquePin(candidate.assignment, 1).?;
        try std.testing.expectEqual(n + 1, positive);
    }
}
