//! Two-dimensional quasi-static fallback for transmission-line cross-sections.
//!
//! The solver discretises `div(epsilon grad(V)) = 0` with finite-volume face
//! conductances, then integrates conductor charge. A second vacuum solve gives
//! the inductance through `L = mu0*epsilon0*C_air^-1`. Symmetric pair modes are
//! excited directly, avoiding a numerically noisy matrix inversion:
//! `Zmode = eta0/sqrt(c_air_mode*c_mode)` and `Zdiff = 2*Zodd`.
//!
//! Production callers use the field result as a ratio against an identically
//! meshed ideal cross-section and apply that ratio to the corresponding
//! Hammerstad/Cohn/Kirschning closed form. This removes nearly all box/grid
//! bias while retaining mask, trapezoid, mixed-dielectric and broadside effects.

const std = @import("std");

const eta0: f64 = 120.0 * std.math.pi;
const nx: usize = 129;
const ny: usize = 65;
const max_iterations: usize = 1600;
const convergence: f64 = 1e-5;

/// One horizontal dielectric band spanning the complete solution box.
pub const Band = struct { y_min: f64, y_max: f64, er: f64 };

/// A local dielectric override, used for stepped soldermask above a trace.
pub const Region = struct { x_min: f64, x_max: f64, y_min: f64, y_max: f64, er: f64 };

/// Trapezoidal perfect conductor. Widths are measured at `y_min`/`y_max`;
/// `terminal=0` is ground and terminals 1/2 are the solved signal conductors.
pub const Conductor = struct {
    x_center: f64,
    y_min: f64,
    y_max: f64,
    width_bottom: f64,
    width_top: f64,
    terminal: u8,
};

/// Complete bounded cross-section. The outer box is a grounded enclosure; for
/// an open microstrip its air ceiling and side walls are deliberately remote.
pub const Geometry = struct {
    x_half: f64,
    y_min: f64,
    y_max: f64,
    bands: []const Band,
    regions: []const Region = &.{},
    conductors: []const Conductor,
};

/// Quasi-TEM modal result. Pair fields are null for a one-conductor geometry.
pub const Result = struct {
    single: ?struct { ohms: f64, er_eff: f64 } = null,
    pair: ?struct {
        odd_ohms: f64,
        even_ohms: ?f64 = null,
        diff_ohms: f64,
        common_ohms: ?f64 = null,
        odd_er_eff: f64,
        even_er_eff: ?f64 = null,
    } = null,
};

pub const Error = error{ InvalidGeometry, OutOfMemory, DidNotConverge };

const Excitation = enum { single, odd, even };

const Grid = struct {
    x: [nx]f64,
    y: [ny]f64,
    potential: []f64,
    owner: []i8,
};

fn finitePositive(v: f64) bool {
    return v > 0 and std.math.isFinite(v);
}

fn index(i: usize, j: usize) usize {
    return j * nx + i;
}

fn conductorWidth(c: Conductor, y: f64) f64 {
    if (c.y_max <= c.y_min) return 0;
    const f = std.math.clamp((y - c.y_min) / (c.y_max - c.y_min), 0, 1);
    return c.width_bottom + f * (c.width_top - c.width_bottom);
}

fn inside(c: Conductor, x: f64, y: f64) bool {
    if (y < c.y_min or y > c.y_max) return false;
    return @abs(x - c.x_center) <= conductorWidth(c, y) / 2;
}

fn erAt(g: Geometry, x: f64, y: f64, vacuum: bool) f64 {
    if (vacuum) return 1;
    var er: f64 = 1;
    for (g.bands) |b| {
        if (y >= b.y_min and y <= b.y_max) er = b.er;
    }
    for (g.regions) |r| {
        if (x >= r.x_min and x <= r.x_max and y >= r.y_min and y <= r.y_max) er = r.er;
    }
    return er;
}

fn terminalPotential(terminal: u8, excitation: Excitation) f64 {
    return switch (excitation) {
        .single => if (terminal == 1) 1 else 0,
        .odd => if (terminal == 1) 0.5 else if (terminal == 2) -0.5 else 0,
        .even => if (terminal == 1 or terminal == 2) 1 else 0,
    };
}

fn initGrid(allocator: std.mem.Allocator, g: Geometry, excitation: Excitation) Error!Grid {
    if (!finitePositive(g.x_half) or !(g.y_max > g.y_min)) return Error.InvalidGeometry;
    if (g.conductors.len == 0) return Error.InvalidGeometry;
    var grid = Grid{
        .x = @splat(0),
        .y = @splat(0),
        .potential = allocator.alloc(f64, nx * ny) catch return Error.OutOfMemory,
        .owner = allocator.alloc(i8, nx * ny) catch return Error.OutOfMemory,
    };
    errdefer allocator.free(grid.potential);
    errdefer allocator.free(grid.owner);

    // sinh mapping concentrates x samples around the signal conductors while
    // retaining remote grounded walls for open structures.
    const alpha: f64 = 2.2;
    const sinh_alpha = std.math.sinh(alpha);
    for (0..nx) |i| {
        const q = -1.0 + 2.0 * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(nx - 1));
        grid.x[i] = g.x_half * std.math.sinh(alpha * q) / sinh_alpha;
    }
    for (0..ny) |j| {
        const q = @as(f64, @floatFromInt(j)) / @as(f64, @floatFromInt(ny - 1));
        grid.y[j] = g.y_min + q * (g.y_max - g.y_min);
    }

    @memset(grid.owner, -1);
    @memset(grid.potential, 0);
    for (1..ny - 1) |j| for (1..nx - 1) |i| {
        const k = index(i, j);
        grid.owner[k] = 0;
        for (g.conductors) |c| {
            if (!inside(c, grid.x[i], grid.y[j])) continue;
            grid.owner[k] = @intCast(c.terminal + 1);
            grid.potential[k] = terminalPotential(c.terminal, excitation);
            break;
        }
    };
    // A thin inner foil can fall between two y samples on a coarse calibrated
    // grid. Pin it to the nearest interior row instead of silently deleting a
    // conductor; the identical ideal solve receives the same stair-step.
    for (g.conductors) |c| {
        var found = false;
        for (grid.owner) |owner| {
            if (owner == @as(i8, @intCast(c.terminal + 1))) {
                found = true;
                break;
            }
        }
        if (found) continue;
        const middle_y = (c.y_min + c.y_max) / 2;
        var nearest_j: usize = 1;
        for (2..ny - 1) |j| if (@abs(grid.y[j] - middle_y) < @abs(grid.y[nearest_j] - middle_y)) {
            nearest_j = j;
        };
        const width = (c.width_bottom + c.width_top) / 2;
        var marked = false;
        for (1..nx - 1) |i| {
            if (@abs(grid.x[i] - c.x_center) > width / 2) continue;
            const k = index(i, nearest_j);
            grid.owner[k] = @intCast(c.terminal + 1);
            grid.potential[k] = terminalPotential(c.terminal, excitation);
            marked = true;
        }
        if (!marked) return Error.InvalidGeometry;
    }
    return grid;
}

fn faceEr(a: f64, b: f64) f64 {
    if (!(a > 0 and b > 0)) return 1;
    return 2 * a * b / (a + b);
}

fn solvePotential(g: Geometry, grid: *Grid, vacuum: bool) Error!void {
    const omega: f64 = 1.82;
    var iteration: usize = 0;
    while (iteration < max_iterations) : (iteration += 1) {
        var max_change: f64 = 0;
        for (1..ny - 1) |j| for (1..nx - 1) |i| {
            const k = index(i, j);
            if (grid.owner[k] != 0) continue;
            const x = grid.x[i];
            const y = grid.y[j];
            const dx_cv = (grid.x[i + 1] - grid.x[i - 1]) / 2;
            const dy_cv = (grid.y[j + 1] - grid.y[j - 1]) / 2;
            const here = erAt(g, x, y, vacuum);
            const ge = faceEr(here, erAt(g, grid.x[i + 1], y, vacuum)) * dy_cv / (grid.x[i + 1] - x);
            const gw = faceEr(here, erAt(g, grid.x[i - 1], y, vacuum)) * dy_cv / (x - grid.x[i - 1]);
            const gn = faceEr(here, erAt(g, x, grid.y[j + 1], vacuum)) * dx_cv / (grid.y[j + 1] - y);
            const gs = faceEr(here, erAt(g, x, grid.y[j - 1], vacuum)) * dx_cv / (y - grid.y[j - 1]);
            const denom = ge + gw + gn + gs;
            if (!(denom > 0)) return Error.InvalidGeometry;
            const candidate = (ge * grid.potential[index(i + 1, j)] +
                gw * grid.potential[index(i - 1, j)] +
                gn * grid.potential[index(i, j + 1)] +
                gs * grid.potential[index(i, j - 1)]) / denom;
            const old = grid.potential[k];
            const next = old + omega * (candidate - old);
            grid.potential[k] = next;
            max_change = @max(max_change, @abs(next - old));
        };
        if (iteration >= 50 and max_change < convergence) return;
    }
    return Error.DidNotConverge;
}

fn terminalCharge(g: Geometry, grid: Grid, vacuum: bool, terminal: u8) f64 {
    var q: f64 = 0;
    for (1..ny - 1) |j| for (1..nx - 1) |i| {
        const k = index(i, j);
        if (grid.owner[k] != @as(i8, @intCast(terminal + 1))) continue;
        const vc = grid.potential[k];
        const x = grid.x[i];
        const y = grid.y[j];
        const here = erAt(g, x, y, vacuum);
        const dx_cv = (grid.x[i + 1] - grid.x[i - 1]) / 2;
        const dy_cv = (grid.y[j + 1] - grid.y[j - 1]) / 2;
        const neighbors = [_]struct { ni: usize, nj: usize, conductance: f64 }{
            .{ .ni = i + 1, .nj = j, .conductance = faceEr(here, erAt(g, grid.x[i + 1], y, vacuum)) * dy_cv / (grid.x[i + 1] - x) },
            .{ .ni = i - 1, .nj = j, .conductance = faceEr(here, erAt(g, grid.x[i - 1], y, vacuum)) * dy_cv / (x - grid.x[i - 1]) },
            .{ .ni = i, .nj = j + 1, .conductance = faceEr(here, erAt(g, x, grid.y[j + 1], vacuum)) * dx_cv / (grid.y[j + 1] - y) },
            .{ .ni = i, .nj = j - 1, .conductance = faceEr(here, erAt(g, x, grid.y[j - 1], vacuum)) * dx_cv / (y - grid.y[j - 1]) },
        };
        for (neighbors) |n| {
            const nk = index(n.ni, n.nj);
            if (grid.owner[nk] == grid.owner[k]) continue;
            q += n.conductance * (vc - grid.potential[nk]);
        }
    };
    return @abs(q);
}

fn modalCapacitance(allocator: std.mem.Allocator, g: Geometry, excitation: Excitation, vacuum: bool) Error!f64 {
    var grid = try initGrid(allocator, g, excitation);
    defer allocator.free(grid.potential);
    defer allocator.free(grid.owner);
    try solvePotential(g, &grid, vacuum);
    const q = terminalCharge(g, grid, vacuum, 1);
    const drive: f64 = switch (excitation) {
        .single, .even => 1.0,
        .odd => 0.5,
    };
    const c = q / drive;
    if (!finitePositive(c)) return Error.InvalidGeometry;
    return c;
}

/// Solve a one- or two-signal cross-section. Terminal 1 must exist; terminal 2
/// selects odd/even pair analysis. Ground conductors use terminal 0.
pub fn analyze(allocator: std.mem.Allocator, g: Geometry) Error!Result {
    var has_one = false;
    var has_two = false;
    for (g.conductors) |c| {
        if (!finitePositive(c.width_bottom) or !finitePositive(c.width_top)) return Error.InvalidGeometry;
        if (!(c.y_max > c.y_min) or c.terminal > 2) return Error.InvalidGeometry;
        has_one = has_one or c.terminal == 1;
        has_two = has_two or c.terminal == 2;
    }
    if (!has_one) return Error.InvalidGeometry;
    if (!has_two) {
        const c = try modalCapacitance(allocator, g, .single, false);
        const c_air = try modalCapacitance(allocator, g, .single, true);
        return .{ .single = .{ .ohms = eta0 / @sqrt(c * c_air), .er_eff = c / c_air } };
    }
    const c_odd = try modalCapacitance(allocator, g, .odd, false);
    const ca_odd = try modalCapacitance(allocator, g, .odd, true);
    const c_even = try modalCapacitance(allocator, g, .even, false);
    const ca_even = try modalCapacitance(allocator, g, .even, true);
    const z_odd = eta0 / @sqrt(c_odd * ca_odd);
    const z_even = eta0 / @sqrt(c_even * ca_even);
    return .{ .pair = .{
        .odd_ohms = z_odd,
        .even_ohms = z_even,
        .diff_ohms = 2 * z_odd,
        .common_ohms = z_even / 2,
        .odd_er_eff = c_odd / ca_odd,
        .even_er_eff = c_even / ca_even,
    } };
}

/// Solve only the odd excitation of a two-conductor pair. This is the minimal
/// capacitance-matrix path required for differential impedance synthesis.
pub fn analyzeOdd(allocator: std.mem.Allocator, g: Geometry) Error!Result {
    var has_one = false;
    var has_two = false;
    for (g.conductors) |c| {
        has_one = has_one or c.terminal == 1;
        has_two = has_two or c.terminal == 2;
    }
    if (!has_one or !has_two) return Error.InvalidGeometry;
    const c_odd = try modalCapacitance(allocator, g, .odd, false);
    const ca_odd = try modalCapacitance(allocator, g, .odd, true);
    const z_odd = eta0 / @sqrt(c_odd * ca_odd);
    return .{ .pair = .{
        .odd_ohms = z_odd,
        .diff_ohms = 2 * z_odd,
        .odd_er_eff = c_odd / ca_odd,
    } };
}

const testing = std.testing;

// spec: placement/impedance - vacuum capacitance and dielectric capacitance produce the quasi-TEM impedance and effective permittivity of a layered microstrip
test "field solver resolves a finite microstrip cross-section" {
    const bands = [_]Band{.{ .y_min = -0.2, .y_max = 0, .er = 4.4 }};
    const conductors = [_]Conductor{.{
        .x_center = 0,
        .y_min = 0,
        .y_max = 0.035,
        .width_bottom = 0.35,
        .width_top = 0.35,
        .terminal = 1,
    }};
    const result = try analyze(testing.allocator, .{
        .x_half = 1.4,
        .y_min = -0.2,
        .y_max = 0.8,
        .bands = &bands,
        .conductors = &conductors,
    });
    try testing.expect(result.single.?.ohms > 35 and result.single.?.ohms < 70);
    try testing.expect(result.single.?.er_eff > 2 and result.single.?.er_eff < 4.4);
}

// spec: placement/impedance - odd mode drives two conductors oppositely and differential impedance is exactly twice the resulting odd-mode impedance
test "field solver differential impedance is two times odd mode" {
    const bands = [_]Band{.{ .y_min = -0.2, .y_max = 0, .er = 4.4 }};
    const conductors = [_]Conductor{
        .{ .x_center = -0.175, .y_min = 0, .y_max = 0.035, .width_bottom = 0.2, .width_top = 0.18, .terminal = 1 },
        .{ .x_center = 0.175, .y_min = 0, .y_max = 0.035, .width_bottom = 0.2, .width_top = 0.18, .terminal = 2 },
    };
    const result = try analyze(testing.allocator, .{
        .x_half = 1.5,
        .y_min = -0.2,
        .y_max = 0.8,
        .bands = &bands,
        .conductors = &conductors,
    });
    try testing.expectApproxEqRel(2 * result.pair.?.odd_ohms, result.pair.?.diff_ohms, 1e-12);
    try testing.expect(result.pair.?.odd_ohms < result.pair.?.even_ohms.?);
}
