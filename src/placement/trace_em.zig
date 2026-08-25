//! Geometry-aware 2.5D quasi-TEM analysis of a routed controlled-impedance net.
//!
//! This is deliberately not described as a full-wave field solver.  It uses
//! the stackup's closed-form microstrip/grounded-CPWG/stripline solution for
//! every routed width, cascades the real route as lossy transmission-line
//! sections, and inserts a first-order lumped model at each through-via.  That
//! makes width steps, delay, skin-effect loss, dielectric loss, and via
//! discontinuities visible while keeping the model deterministic and
//! auditable.  Radiation, connector launches, solder mask, copper roughness,
//! and coupling to nearby shapes still require a 3D solver or measurement.

const std = @import("std");
const impedance = @import("impedance.zig");
const optimizer = @import("optimizer.zig");
const router = @import("router.zig");
const via_antipad = @import("via_antipad.zig");

/// Number of logarithmically spaced samples emitted for each route sweep.
pub const sweep_points: usize = 61;
/// Explicit generic-FR-4 dielectric-loss assumption used by the loss model.
pub const assumed_loss_tangent: f64 = 0.02;
/// Bulk annealed-copper conductivity assumed by the skin-effect estimate.
pub const copper_conductivity_s_per_m: f64 = 5.8e7;

const c0_m_per_s: f64 = 299_792_458.0;
const mu0_h_per_m: f64 = 1.256_637_062_12e-6;
const point_tol_mm: f64 = 0.0001;

/// Whether the route was swept, or the reason analysis was refused.
pub const Status = enum {
    ok,
    no_copper,
    no_stackup,
    unsupported_geometry,
    unsupported_topology,

    /// Stable kebab-case status string written to the browser JSON.
    pub fn name(self: Status) []const u8 {
        return switch (self) {
            .ok => "ok",
            .no_copper => "no-copper",
            .no_stackup => "no-stackup",
            .unsupported_geometry => "unsupported-geometry",
            .unsupported_topology => "unsupported-topology",
        };
    }
};

/// One uniform routed transmission-line section and its local field solution.
pub const Section = struct {
    from: [2]f64,
    to: [2]f64,
    layers: struct { route: u8, physical: u8 },
    width_mm: f64,
    length_mm: f64,
    electrical: struct {
        z0_ohms: f64,
        er_eff: f64,
        structure: []const u8,
        ground_gap_mm: f64 = 0,
        gap_capped: bool = false,
    },
};

/// One frequency-domain two-port result in the logarithmic sweep.
pub const Sample = struct {
    frequency_hz: f64,
    return_loss_db: f64,
    insertion_loss_db: f64,
    zin_re_ohms: f64,
    zin_im_ohms: f64,
    s11_phase_deg: f64,
};

/// Complete per-net result consumed by the PCB trace inspector.
pub const Analysis = struct {
    status: Status,
    target: struct {
        ohms: f64,
        band: struct { start_hz: f64, stop_hz: f64, assumed: bool, return_loss_db: f64 },
        ground_gap_mm: f64,
        ground_gap_max_mm: f64 = 0,
        width_derived: bool,
    },
    sections: []const Section,
    samples: []const Sample,
    via_count: usize,
    summary: struct {
        total_length_mm: f64,
        delay_ps: f64,
        z0: struct { min_ohms: f64, max_ohms: f64, weighted_ohms: f64 },
        ground_gap: struct { min_mm: f64 = 0, max_mm: f64 = 0, capped_length_mm: f64 = 0 } = .{},
        worst_return_loss_db: f64,
        worst_insertion_loss_db: f64,
    },
};

const Complex = struct {
    re: f64 = 0,
    im: f64 = 0,

    fn add(a: Complex, b: Complex) Complex {
        return .{ .re = a.re + b.re, .im = a.im + b.im };
    }
    fn sub(a: Complex, b: Complex) Complex {
        return .{ .re = a.re - b.re, .im = a.im - b.im };
    }
    fn mul(a: Complex, b: Complex) Complex {
        return .{ .re = a.re * b.re - a.im * b.im, .im = a.re * b.im + a.im * b.re };
    }
    fn scale(a: Complex, v: f64) Complex {
        return .{ .re = a.re * v, .im = a.im * v };
    }
    fn div(a: Complex, b: Complex) Complex {
        const d = b.re * b.re + b.im * b.im;
        return .{ .re = (a.re * b.re + a.im * b.im) / d, .im = (a.im * b.re - a.re * b.im) / d };
    }
    fn abs(a: Complex) f64 {
        return @sqrt(a.re * a.re + a.im * a.im);
    }
};

const Matrix = struct {
    a: Complex = .{ .re = 1 },
    b: Complex = .{},
    c: Complex = .{},
    d: Complex = .{ .re = 1 },

    fn cascade(lhs: Matrix, rhs: Matrix) Matrix {
        return .{
            .a = Complex.add(Complex.mul(lhs.a, rhs.a), Complex.mul(lhs.b, rhs.c)),
            .b = Complex.add(Complex.mul(lhs.a, rhs.b), Complex.mul(lhs.b, rhs.d)),
            .c = Complex.add(Complex.mul(lhs.c, rhs.a), Complex.mul(lhs.d, rhs.c)),
            .d = Complex.add(Complex.mul(lhs.c, rhs.b), Complex.mul(lhs.d, rhs.d)),
        };
    }
};

const Element = union(enum) {
    line: usize,
    via: struct { inductance_nh: f64, capacitance_pf: f64 },
};

const Node = struct { x: f64, y: f64, layer: u8, degree: usize = 0 };
const EdgeKind = union(enum) { track: usize, via: usize };
const Edge = struct { a: usize, b: usize, kind: EdgeKind, used: bool = false };
const GeometryCounts = struct { tracks: usize = 0, vias: usize = 0 };
const ElementContext = struct {
    routed: router.RouteResult,
    stack: impedance.Stack,
    rule: optimizer.NetRule,
    board_clearance: f64,
};
const Graph = struct {
    sections: []Section,
    track_to_section: []usize,
    nodes: []Node,
    edges: []Edge,
    node_count: usize,
    edge_count: usize,
    geometry_ok: bool,
};

fn samePoint(a: f64, b: f64) bool {
    return @abs(a - b) <= point_tol_mm;
}

fn findOrAddNode(nodes: []Node, count: *usize, x: f64, y: f64, layer: u8) usize {
    for (nodes[0..count.*], 0..) |n, i| {
        if (n.layer == layer and samePoint(n.x, x) and samePoint(n.y, y)) return i;
    }
    const result = count.*;
    nodes[result] = .{ .x = x, .y = y, .layer = layer };
    count.* += 1;
    return result;
}

fn emptyAnalysis(rule: optimizer.NetRule, status: Status) Analysis {
    const stop = if (rule.rf.max_freq_hz > 0) rule.rf.max_freq_hz else 1.0e9;
    const start = if (rule.rf.electrical.band_start_hz > 0) rule.rf.electrical.band_start_hz else stop / 100.0;
    return .{
        .status = status,
        .target = .{
            .ohms = rule.rf.impedance.ohms,
            .band = .{ .start_hz = start, .stop_hz = stop, .assumed = !(rule.rf.max_freq_hz > 0), .return_loss_db = rule.rf.electrical.return_loss_target_db },
            .ground_gap_mm = rule.rf.impedance.ground_gap_mm,
            .ground_gap_max_mm = rule.rf.impedance.ground_gap_max_mm,
            .width_derived = rule.rf.impedance.width_derived,
        },
        .sections = &.{},
        .samples = &.{},
        .via_count = 0,
        .summary = .{
            .total_length_mm = 0,
            .delay_ps = 0,
            .z0 = .{ .min_ohms = 0, .max_ohms = 0, .weighted_ohms = 0 },
            .ground_gap = .{},
            .worst_return_loss_db = 0,
            .worst_insertion_loss_db = 0,
        },
    };
}

fn routePhysicalLayer(rules: optimizer.BoardRules, route_layer: u8) ?u8 {
    // Persisted route-layer indices always keep the two outer faces first:
    // 0 = F.Cu, 1 = B.Cu, then plane-free inner layers in stack order.  The
    // impedance helper's signalLayers() result is instead in physical
    // top-to-bottom order, so indexing that slice directly misread B.Cu as
    // the first routable inner layer on a multilayer board.
    if (route_layer >= rules.signalLayerCount()) return null;
    return rules.signalStackIndex(route_layer);
}

fn lineMatrix(section: Section, frequency_hz: f64) Matrix {
    const length_m = section.length_mm / 1000.0;
    const width_m = section.width_mm / 1000.0;
    const beta = 2.0 * std.math.pi * frequency_hz * @sqrt(section.electrical.er_eff) / c0_m_per_s;
    const surface_resistance = @sqrt(std.math.pi * frequency_hz * mu0_h_per_m / copper_conductivity_s_per_m);
    // Incremental-inductance approximation.  It is intentionally conservative
    // and is reported as such in the UI; roughness and plating profile are not
    // available in the stackup DSL.
    const alpha_conductor = surface_resistance / (section.electrical.z0_ohms * width_m);
    const alpha_dielectric = beta * assumed_loss_tangent / 2.0;
    const al = (alpha_conductor + alpha_dielectric) * length_m;
    const bl = beta * length_m;
    const ch = Complex{ .re = std.math.cosh(al) * @cos(bl), .im = std.math.sinh(al) * @sin(bl) };
    const sh = Complex{ .re = std.math.sinh(al) * @cos(bl), .im = std.math.cosh(al) * @sin(bl) };
    return .{ .a = ch, .b = sh.scale(section.electrical.z0_ohms), .c = sh.scale(1.0 / section.electrical.z0_ohms), .d = ch };
}

fn viaMatrix(inductance_nh: f64, capacitance_pf: f64, frequency_hz: f64) Matrix {
    const omega = 2.0 * std.math.pi * frequency_hz;
    const z = Complex{ .im = omega * inductance_nh * 1e-9 };
    const half_y = Complex{ .im = omega * capacitance_pf * 1e-12 / 2.0 };
    const shunt = Matrix{ .c = half_y };
    const series = Matrix{ .b = z };
    return Matrix.cascade(Matrix.cascade(shunt, series), shunt);
}

fn sampleAt(elements: []const Element, sections: []const Section, frequency_hz: f64, reference_ohms: f64) Sample {
    var m = Matrix{};
    for (elements) |element| m = Matrix.cascade(m, switch (element) {
        .line => |index| lineMatrix(sections[index], frequency_hz),
        .via => |v| viaMatrix(v.inductance_nh, v.capacitance_pf, frequency_hz),
    });
    const zref = Complex{ .re = reference_ohms };
    const den = Complex.add(Complex.add(m.a, m.b.scale(1.0 / reference_ohms)), Complex.add(m.c.scale(reference_ohms), m.d));
    const num11 = Complex.sub(Complex.add(m.a, m.b.scale(1.0 / reference_ohms)), Complex.add(m.c.scale(reference_ohms), m.d));
    const s11 = Complex.div(num11, den);
    const s21 = Complex.div(.{ .re = 2 }, den);
    const zin = Complex.div(Complex.add(Complex.mul(m.a, zref), m.b), Complex.add(Complex.mul(m.c, zref), m.d));
    const s11_mag = s11.abs();
    const s21_mag = s21.abs();
    return .{
        .frequency_hz = frequency_hz,
        .return_loss_db = if (s11_mag <= 1e-15) 300 else -20.0 * std.math.log10(s11_mag),
        .insertion_loss_db = if (s21_mag <= 1e-15) 300 else -20.0 * std.math.log10(s21_mag),
        .zin_re_ohms = zin.re,
        .zin_im_ohms = zin.im,
        .s11_phase_deg = std.math.atan2(s11.im, s11.re) * 180.0 / std.math.pi,
    };
}

fn geometryCounts(routed: router.RouteResult, net: i32) GeometryCounts {
    var result = GeometryCounts{};
    for (routed.tracks) |track| result.tracks += @intFromBool(track.net == net);
    for (routed.vias) |via| result.vias += @intFromBool(via.net == net);
    return result;
}

fn buildTrackGraph(
    alloc: std.mem.Allocator,
    routed: router.RouteResult,
    net: i32,
    rules: optimizer.BoardRules,
    rule: optimizer.NetRule,
    counts: GeometryCounts,
) std.mem.Allocator.Error!Graph {
    const stack = rules.physical.stack;
    const sections = try alloc.alloc(Section, counts.tracks);
    const track_to_section = try alloc.alloc(usize, routed.tracks.len);
    @memset(track_to_section, std.math.maxInt(usize));
    const nodes = try alloc.alloc(Node, counts.tracks * 2);
    const edges = try alloc.alloc(Edge, counts.tracks + counts.vias);
    var graph = Graph{
        .sections = sections,
        .track_to_section = track_to_section,
        .nodes = nodes,
        .edges = edges,
        .node_count = 0,
        .edge_count = 0,
        .geometry_ok = true,
    };
    var section_count: usize = 0;
    for (routed.tracks, 0..) |track, track_index| {
        if (track.net != net) continue;
        const physical_layer = routePhysicalLayer(rules, track.layer) orelse {
            graph.geometry_ok = false;
            continue;
        };
        const ref = impedance.reference(stack, physical_layer) orelse {
            graph.geometry_ok = false;
            continue;
        };
        const foil = stack.foilMm(physical_layer);
        var ground_gap = rule.rf.impedance.ground_gap_mm;
        var gap_capped = false;
        const outer_cpwg = switch (ref) {
            .microstrip => true,
            .stripline => false,
        };
        if (outer_cpwg and rule.rf.impedance.ground_gap_max_mm > ground_gap and ground_gap > 0) {
            const gap_solution = impedance.refGroundGapForZ0(
                ref,
                track.width,
                foil,
                rule.rf.impedance.ohms,
                ground_gap,
                rule.rf.impedance.ground_gap_max_mm,
            ) catch {
                graph.geometry_ok = false;
                continue;
            };
            ground_gap = gap_solution.gap_mm;
            gap_capped = gap_solution.capped;
        }
        const z0 = impedance.refZ0WithGroundGap(ref, track.width, foil, ground_gap) catch {
            graph.geometry_ok = false;
            continue;
        };
        const er_eff = impedance.refEffectiveErWithGroundGap(ref, track.width, foil, ground_gap) catch {
            graph.geometry_ok = false;
            continue;
        };
        graph.sections[section_count] = .{
            .from = .{ track.x1, track.y1 },
            .to = .{ track.x2, track.y2 },
            .layers = .{ .route = track.layer, .physical = physical_layer },
            .width_mm = track.width,
            .length_mm = std.math.hypot(track.x2 - track.x1, track.y2 - track.y1),
            .electrical = .{
                .z0_ohms = z0,
                .er_eff = er_eff,
                .structure = ref.kindNameWithGroundGap(ground_gap),
                .ground_gap_mm = ground_gap,
                .gap_capped = gap_capped,
            },
        };
        graph.track_to_section[track_index] = section_count;
        section_count += 1;
        const a = findOrAddNode(graph.nodes, &graph.node_count, track.x1, track.y1, track.layer);
        const b = findOrAddNode(graph.nodes, &graph.node_count, track.x2, track.y2, track.layer);
        graph.edges[graph.edge_count] = .{ .a = a, .b = b, .kind = .{ .track = track_index } };
        graph.edge_count += 1;
    }
    graph.sections = graph.sections[0..section_count];
    return graph;
}

fn connectVias(graph: *Graph, routed: router.RouteResult, net: i32) void {
    for (routed.vias, 0..) |via, via_index| {
        if (via.net != net) continue;
        var matches: [32]usize = undefined;
        var match_count: usize = 0;
        for (graph.nodes[0..graph.node_count], 0..) |node, node_index| {
            if (samePoint(node.x, via.x) and samePoint(node.y, via.y) and match_count < matches.len) {
                matches[match_count] = node_index;
                match_count += 1;
            }
        }
        if (match_count != 2) continue;
        graph.edges[graph.edge_count] = .{ .a = matches[0], .b = matches[1], .kind = .{ .via = via_index } };
        graph.edge_count += 1;
    }
}

fn pathEndpoints(graph: *Graph) ?[2]usize {
    for (graph.edges[0..graph.edge_count]) |edge| {
        graph.nodes[edge.a].degree += 1;
        graph.nodes[edge.b].degree += 1;
    }
    var endpoints: [2]usize = undefined;
    var count: usize = 0;
    for (graph.nodes[0..graph.node_count], 0..) |node, node_index| {
        if (node.degree == 1 and count < endpoints.len) {
            endpoints[count] = node_index;
            count += 1;
        } else if (node.degree == 0 or node.degree > 2) return null;
    }
    return if (count == endpoints.len) endpoints else null;
}

fn orderedElements(
    elements: []Element,
    graph: *Graph,
    endpoints: [2]usize,
    context: ElementContext,
) ?usize {
    var count: usize = 0;
    var current = endpoints[0];
    while (count < graph.edge_count) {
        var found: ?usize = null;
        for (graph.edges[0..graph.edge_count], 0..) |edge, edge_index| {
            if (!edge.used and (edge.a == current or edge.b == current)) {
                found = edge_index;
                break;
            }
        }
        const edge_index = found orelse return null;
        graph.edges[edge_index].used = true;
        const edge = graph.edges[edge_index];
        elements[count] = switch (edge.kind) {
            .track => |track_index| .{ .line = graph.track_to_section[track_index] },
            .via => |via_index| blk: {
                const via = context.routed.vias[via_index];
                const drill = if (via.drill > 0) via.drill else if (context.rule.via_drill > 0) context.rule.via_drill else via.dia * 0.5;
                const solved = via_antipad.solve(context.stack, context.rule.rf.impedance.ohms, via.dia, drill, context.board_clearance);
                break :blk .{ .via = if (solved) |v|
                    .{ .inductance_nh = v.inductance_nh, .capacitance_pf = v.capacitance_pf }
                else
                    .{ .inductance_nh = 0, .capacitance_pf = 0 } };
            },
        };
        count += 1;
        current = if (edge.a == current) edge.b else edge.a;
    }
    return if (current == endpoints[1]) count else null;
}

/// Analyze one flattened net.  `null` means the net has no single-ended
/// controlled-impedance target; all other refusal modes are explicit in the
/// returned status so the UI never silently substitutes geometry.
pub fn analyzeNet(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    routed: router.RouteResult,
    net_index: usize,
) std.mem.Allocator.Error!?Analysis {
    if (net_index >= placement.rules.net.len) return null;
    const rule = placement.rules.net[net_index];
    if (!(rule.rf.impedance.ohms > 0)) return null;
    const stack = placement.rules.physical.stack;
    var base = emptyAnalysis(rule, if (stack.layers > 0) .no_copper else .no_stackup);
    if (stack.layers == 0) return base;

    const net: i32 = @intCast(net_index);
    const counts = geometryCounts(routed, net);
    if (counts.tracks == 0) return base;
    var graph = try buildTrackGraph(alloc, routed, net, placement.rules, rule, counts);
    base.sections = graph.sections;
    base.via_count = counts.vias;
    if (!graph.geometry_ok or graph.sections.len != counts.tracks) {
        base.status = .unsupported_geometry;
        return base;
    }
    connectVias(&graph, routed, net);
    const endpoints = pathEndpoints(&graph) orelse {
        base.status = .unsupported_topology;
        summarize(&base);
        return base;
    };
    const elements = try alloc.alloc(Element, graph.edge_count);
    const clearance = if (rule.clearance > 0) rule.clearance else placement.rules.design.clearance;
    const element_count = orderedElements(elements, &graph, endpoints, .{
        .routed = routed,
        .stack = stack,
        .rule = rule,
        .board_clearance = clearance,
    }) orelse {
        base.status = .unsupported_topology;
        summarize(&base);
        return base;
    };

    base.status = .ok;
    summarize(&base);
    const samples = try alloc.alloc(Sample, sweep_points);
    const ratio = base.target.band.stop_hz / base.target.band.start_hz;
    for (samples, 0..) |*sample, i| {
        const u = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(sweep_points - 1));
        const frequency = base.target.band.start_hz * std.math.pow(f64, ratio, u);
        sample.* = sampleAt(elements[0..element_count], base.sections, frequency, base.target.ohms);
    }
    base.samples = samples;
    base.summary.worst_return_loss_db = 300;
    for (samples) |sample| {
        base.summary.worst_return_loss_db = @min(base.summary.worst_return_loss_db, sample.return_loss_db);
        base.summary.worst_insertion_loss_db = @max(base.summary.worst_insertion_loss_db, sample.insertion_loss_db);
    }
    return base;
}

fn summarize(result: *Analysis) void {
    result.summary.z0.min_ohms = std.math.inf(f64);
    result.summary.ground_gap.min_mm = std.math.inf(f64);
    var weighted: f64 = 0;
    for (result.sections) |section| {
        result.summary.total_length_mm += section.length_mm;
        result.summary.delay_ps += (section.length_mm / 1000.0) * @sqrt(section.electrical.er_eff) / c0_m_per_s * 1e12;
        result.summary.z0.min_ohms = @min(result.summary.z0.min_ohms, section.electrical.z0_ohms);
        result.summary.z0.max_ohms = @max(result.summary.z0.max_ohms, section.electrical.z0_ohms);
        if (section.electrical.ground_gap_mm > 0) {
            result.summary.ground_gap.min_mm = @min(result.summary.ground_gap.min_mm, section.electrical.ground_gap_mm);
            result.summary.ground_gap.max_mm = @max(result.summary.ground_gap.max_mm, section.electrical.ground_gap_mm);
        }
        if (section.electrical.gap_capped) result.summary.ground_gap.capped_length_mm += section.length_mm;
        weighted += section.electrical.z0_ohms * section.length_mm;
    }
    if (result.summary.total_length_mm > 0) result.summary.z0.weighted_ohms = weighted / result.summary.total_length_mm;
    if (!std.math.isFinite(result.summary.z0.min_ohms)) result.summary.z0.min_ohms = 0;
    if (!std.math.isFinite(result.summary.ground_gap.min_mm)) result.summary.ground_gap.min_mm = 0;
}

const testing = std.testing;

// spec: placement/trace-em - a matched quarter-wave section remains matched
test "matched uniform section has negligible reflection" {
    const section = Section{
        .from = .{ 0, 0 },
        .to = .{ 10, 0 },
        .layers = .{ .route = 0, .physical = 1 },
        .width_mm = 0.32,
        .length_mm = 10,
        .electrical = .{ .z0_ohms = 50, .er_eff = 3.2, .structure = "grounded-coplanar" },
    };
    const sample = sampleAt(&.{.{ .line = 0 }}, &.{section}, 1.0e9, 50);
    try testing.expect(sample.return_loss_db > 250);
    try testing.expect(sample.insertion_loss_db > 0);
}

// spec: placement/trace-em - a width step is visible as finite return loss
test "impedance step produces reflection" {
    const sections = [_]Section{
        .{ .from = .{ 0, 0 }, .to = .{ 10, 0 }, .layers = .{ .route = 0, .physical = 1 }, .width_mm = 0.32, .length_mm = 10, .electrical = .{ .z0_ohms = 50, .er_eff = 3.2, .structure = "grounded-coplanar" } },
        .{ .from = .{ 10, 0 }, .to = .{ 15, 0 }, .layers = .{ .route = 0, .physical = 1 }, .width_mm = 0.15, .length_mm = 5, .electrical = .{ .z0_ohms = 75, .er_eff = 3.1, .structure = "grounded-coplanar" } },
    };
    const sample = sampleAt(&.{ .{ .line = 0 }, .{ .line = 1 } }, &sections, 6.0e9, 50);
    try testing.expect(sample.return_loss_db < 30);
    try testing.expect(sample.return_loss_db > 0);
}

// spec: placement/trace-em - routed CPWG sections synthesize their local gap from exact widths
test "routed CPWG sections synthesize their local gap from exact widths" {
    var arena_instance = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    var parts = [_]optimizer.Part{};
    const planes = [_]u8{2};
    const dielectrics = [_]impedance.Dielectric{.{ .after_layer = 1, .thickness_mm = 0.2104, .er = 4.4 }};
    const rule = optimizer.NetRule{
        .class = .{ .name = "rf-50ohm" },
        .width = 0.3214700487624722,
        .clearance = 0.127,
        .rf = .{
            .max_freq_hz = 6e9,
            .electrical = .{ .band_start_hz = 60e6, .return_loss_target_db = 20 },
            .impedance = .{ .ohms = 50, .layer = 1, .ground_gap_mm = 0.127, .ground_gap_max_mm = 1.75, .width_derived = true },
        },
    };
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 2,
        .maxy = 1,
        .generated = false,
        .rules = .{
            .net = &.{rule},
            .physical = .{ .stack = .{ .layers = 2, .planes = &planes, .dielectrics = &dielectrics } },
        },
    };
    // Deliberately reverse the input slice: topology traversal, not append
    // order, establishes the two-port chain.
    const tracks = [_]router.Track{
        .{ .x1 = 1, .y1 = 0, .x2 = 2, .y2 = 0, .layer = 0, .width = 0.4, .net = 0 },
        .{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 0, .layer = 0, .width = 0.3214700487624722, .net = 0 },
    };
    const result = (try analyzeNet(arena, placement, .{ .tracks = &tracks, .vias = &.{}, .routed = 1, .total = 1 }, 0)).?;
    try testing.expectEqual(Status.ok, result.status);
    try testing.expectEqual(@as(usize, sweep_points), result.samples.len);
    try testing.expectApproxEqAbs(@as(f64, 50), result.summary.z0.weighted_ohms, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.127), result.summary.ground_gap.min_mm, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.29747), result.summary.ground_gap.max_mm, 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 0), result.summary.ground_gap.capped_length_mm, 1e-9);
    try testing.expect(result.summary.worst_return_loss_db > result.target.band.return_loss_db);
}

// spec: placement/trace-em - route layer 1 maps to bottom physical copper on multilayer boards
test "bottom route layer maps to the bottom physical copper" {
    var arena_instance = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    var parts = [_]optimizer.Part{};
    const physical_planes = [_]u8{ 2, 5 };
    const plane_rows = [_]optimizer.PlaneAt{
        .{ .index = 2, .net = "GND" },
        .{ .index = 5, .net = "GND" },
    };
    const dielectrics = [_]impedance.Dielectric{
        .{ .after_layer = 1, .thickness_mm = 0.0994, .er = 4.4 },
        .{ .after_layer = 5, .thickness_mm = 0.0994, .er = 4.4 },
    };
    const rule = optimizer.NetRule{
        .class = .{ .name = "rf-50ohm" },
        .width = 0.18335412052887323,
        .clearance = 0.127,
        .rf = .{
            .max_freq_hz = 12e9,
            .electrical = .{ .band_start_hz = 120e6, .return_loss_target_db = 20 },
            .impedance = .{ .ohms = 50, .ground_gap_mm = 0.127, .width_derived = true },
        },
    };
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 2,
        .maxy = 1,
        .generated = false,
        .rules = .{
            .net = &.{rule},
            .plane_nets = &.{},
            .copper_layers = 6,
            .planes = .{ .declared = &plane_rows },
            .physical = .{ .stack = .{ .layers = 6, .planes = &physical_planes, .dielectrics = &dielectrics } },
        },
    };
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 2, .y2 = 0, .layer = 1, .width = rule.width, .net = 0 },
    };
    const result = (try analyzeNet(arena, placement, .{ .tracks = &tracks, .vias = &.{}, .routed = 1, .total = 1 }, 0)).?;
    try testing.expectEqual(Status.ok, result.status);
    try testing.expectEqual(@as(u8, 1), result.sections[0].layers.route);
    try testing.expectEqual(@as(u8, 6), result.sections[0].layers.physical);
    try testing.expectEqualStrings("grounded-coplanar", result.sections[0].electrical.structure);
    try testing.expectApproxEqAbs(@as(f64, 50), result.sections[0].electrical.z0_ohms, 1e-9);
}
