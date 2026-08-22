//! Guarded closing of the temporary grid-snap gap between courtyards.

const std = @import("std");
const testing = std.testing;

/// Grid and policy values governing guarded courtyard contact.
pub const Settings = struct {
    grid_mm: f64,
    max_move_mm: f64,
    route_gap_mm: f64,
    overlap_allowance_mm: f64,
};

const Point = struct { x: f64, y: f64 };
/// Axis-aligned world-space courtyard bounds.
pub const Rect = struct { minx: f64, miny: f64, w: f64, h: f64 };
const Search = struct {
    origin: Point,
    best: ?Point = null,
    best_d2: f64 = std.math.inf(f64),
    best_target_is_hub: bool = true,
};
const eps = 1e-6;

/// Whether two rectangles share an edge with positive overlap along that edge.
pub fn edgeContact(a: Rect, b: Rect) bool {
    const gx = @max(a.minx, b.minx) - @min(a.minx + a.w, b.minx + b.w);
    const gy = @max(a.miny, b.miny) - @min(a.miny + a.h, b.miny + b.h);
    return (@abs(gx) <= eps and gy < -eps) or (@abs(gy) <= eps and gx < -eps);
}

/// Move each unlocked passive without an existing contact by at most the snap
/// safety gap. A candidate must make exact rendered-courtyard contact while
/// passing both the caller's placement keepouts and strict courtyard geometry.
/// Passive-to-passive contact wins candidate selection so compact rows keep
/// their IC breakout.
pub fn close(
    comptime Part: type,
    parts: []Part,
    settings: Settings,
    comptime courtyardFn: *const fn (*const Part) Rect,
    comptime overlapsFn: *const fn ([]const Part, *const Part) bool,
) void {
    if (parts.len < 2 or settings.route_gap_mm > eps or settings.overlap_allowance_mm > eps) return;
    for (parts, 0..) |*part, i| {
        if (part.kind == .hub or part.locked or touchesAny(Part, parts, i, courtyardFn)) continue;
        var search = Search{ .origin = .{ .x = part.x, .y = part.y } };
        const court = courtyardFn(part);
        for (parts, 0..) |*other, j| {
            if (i == j or part.side != other.side) continue;
            const target = courtyardFn(other);
            const x_overlap = overlap1d(court.minx, court.w, target.minx, target.w);
            const y_overlap = overlap1d(court.miny, court.h, target.miny, target.h);
            if (y_overlap >= settings.grid_mm - eps) {
                if (target.minx >= court.minx + court.w) {
                    consider(Part, parts, i, .{ .x = part.x + target.minx - (court.minx + court.w), .y = part.y }, other.kind == .hub, settings, &search, courtyardFn, overlapsFn);
                }
                if (court.minx >= target.minx + target.w) {
                    consider(Part, parts, i, .{ .x = part.x - (court.minx - target.minx - target.w), .y = part.y }, other.kind == .hub, settings, &search, courtyardFn, overlapsFn);
                }
            }
            if (x_overlap >= settings.grid_mm - eps) {
                if (target.miny >= court.miny + court.h) {
                    consider(Part, parts, i, .{ .x = part.x, .y = part.y + target.miny - (court.miny + court.h) }, other.kind == .hub, settings, &search, courtyardFn, overlapsFn);
                }
                if (court.miny >= target.miny + target.h) {
                    consider(Part, parts, i, .{ .x = part.x, .y = part.y - (court.miny - target.miny - target.h) }, other.kind == .hub, settings, &search, courtyardFn, overlapsFn);
                }
            }
        }
        if (search.best) |at| {
            part.x = at.x;
            part.y = at.y;
        }
    }
}

fn consider(
    comptime Part: type,
    parts: []Part,
    i: usize,
    candidate: Point,
    target_is_hub: bool,
    settings: Settings,
    search: *Search,
    comptime courtyardFn: *const fn (*const Part) Rect,
    comptime overlapsFn: *const fn ([]const Part, *const Part) bool,
) void {
    const at = Point{
        .x = gridRound(candidate.x, settings.grid_mm),
        .y = gridRound(candidate.y, settings.grid_mm),
    };
    const dx = at.x - search.origin.x;
    const dy = at.y - search.origin.y;
    const d2 = dx * dx + dy * dy;
    if (d2 > settings.max_move_mm * settings.max_move_mm + eps) return;
    if (search.best != null) {
        if (target_is_hub != search.best_target_is_hub) {
            if (target_is_hub) return;
        } else if (d2 >= search.best_d2 - 1e-12) return;
    }
    parts[i].x = at.x;
    parts[i].y = at.y;
    const legal = !overlapsFn(parts, &parts[i]) and
        !overlapsCourtyard(Part, parts, i, courtyardFn) and
        touchesAny(Part, parts, i, courtyardFn);
    parts[i].x = search.origin.x;
    parts[i].y = search.origin.y;
    if (!legal) return;
    search.best = at;
    search.best_d2 = d2;
    search.best_target_is_hub = target_is_hub;
}

fn touchesAny(comptime Part: type, parts: []const Part, i: usize, comptime courtyardFn: *const fn (*const Part) Rect) bool {
    const a = courtyardFn(&parts[i]);
    for (parts, 0..) |*part, j| {
        if (i == j or parts[i].side != part.side) continue;
        const b = courtyardFn(part);
        if (edgeContact(a, b)) return true;
    }
    return false;
}

fn overlapsCourtyard(comptime Part: type, parts: []const Part, i: usize, comptime courtyardFn: *const fn (*const Part) Rect) bool {
    const a = courtyardFn(&parts[i]);
    for (parts, 0..) |*part, j| {
        if (i == j or parts[i].side != part.side) continue;
        const b = courtyardFn(part);
        if (overlap1d(a.minx, a.w, b.minx, b.w) > eps and overlap1d(a.miny, a.h, b.miny, b.h) > eps) return true;
    }
    return false;
}

fn overlap1d(a0: f64, aw: f64, b0: f64, bw: f64) f64 {
    return @min(a0 + aw, b0 + bw) - @max(a0, b0);
}

fn gridRound(value: f64, grid: f64) f64 {
    return @round(value / grid) * grid;
}

const TestKind = enum { hub, passive };
const TestPart = struct {
    kind: TestKind,
    side: u1 = 0,
    locked: bool = false,
    x: f64,
    y: f64,
    hw: f64,
    hh: f64,
};
fn testCourtyard(part: *const TestPart) Rect {
    return .{ .minx = part.x - part.hw, .miny = part.y - part.hh, .w = 2 * part.hw, .h = 2 * part.hh };
}

fn noKeepoutOverlap(_: []const TestPart, _: *const TestPart) bool {
    return false;
}

// spec: placement/optimizer - fresh rough placement lets adjacent courtyard edges share one grid line exactly while retaining overlap-free legalization
test "snap safety gap closes to a passive edge before the hub edge" {
    var parts = [_]TestPart{
        .{ .kind = .hub, .x = 0, .y = 0, .hw = 2, .hh = 2 },
        .{ .kind = .passive, .x = 2.5, .y = 0, .hw = 0.4, .hh = 0.4 },
        .{ .kind = .passive, .x = 2.5, .y = 0.9, .hw = 0.4, .hh = 0.4 },
    };
    close(TestPart, &parts, .{
        .grid_mm = 0.1,
        .max_move_mm = 0.1,
        .route_gap_mm = 0,
        .overlap_allowance_mm = 0,
    }, testCourtyard, noKeepoutOverlap);

    try testing.expectApproxEqAbs(@as(f64, 2.5), parts[1].x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.1), parts[1].y, 1e-9);
    try testing.expect(edgeContact(testCourtyard(&parts[1]), testCourtyard(&parts[2])));
    try testing.expect(touchesAny(TestPart, &parts, 1, testCourtyard));
    try testing.expect(!overlapsCourtyard(TestPart, &parts, 1, testCourtyard));
}
