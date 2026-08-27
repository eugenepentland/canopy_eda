//! Cold-path integrity checks over the exact retained copper-pour polygons.
//!
//! The ordinary pairwise DRC deliberately stays fill-blind because router
//! candidates call it repeatedly. Reporting DRC already owns the final plane
//! and user-zone fills, so this module checks those emitted solids once: every
//! outer/hole topology must be a well-formed simple polygon, and different-net
//! solids may neither overlap nor touch on the same PHYSICAL copper layer.

const std = @import("std");
const board_layers = @import("../board_layers.zig");
const drc = @import("drc.zig");
const net_name = @import("../net_name.zig");
const numeric = @import("../numeric.zig");
const net_identity = @import("net_identity.zig");
const optimizer = @import("optimizer.zig");
const outline = @import("outline.zig");
const pad_shape = @import("pad_shape.zig");
const path_copper = @import("path_copper.zig");
const pour = @import("pour.zig");
const rf_port_report = @import("rf_port_report.zig");
const router = @import("router.zig");

const Point = [2]f64;
const ring_eps: f64 = 1e-9;
const area2_eps: f64 = 2e-9;
const arc_target_sagitta_mm: f64 = 0.0001;
const max_arc_chords: usize = 4096;

const Box = struct {
    minx: f64,
    miny: f64,
    maxx: f64,
    maxy: f64,

    fn of(poly: []const Point) ?Box {
        if (poly.len == 0) return null;
        var result = Box{ .minx = poly[0][0], .miny = poly[0][1], .maxx = poly[0][0], .maxy = poly[0][1] };
        for (poly[1..]) |point| {
            result.minx = @min(result.minx, point[0]);
            result.miny = @min(result.miny, point[1]);
            result.maxx = @max(result.maxx, point[0]);
            result.maxy = @max(result.maxy, point[1]);
        }
        return result;
    }

    fn touches(a: Box, b: Box) bool {
        return a.maxx >= b.minx - ring_eps and b.maxx >= a.minx - ring_eps and
            a.maxy >= b.miny - ring_eps and b.maxy >= a.miny - ring_eps;
    }

    fn grown(self: Box, radius: f64) Box {
        return .{
            .minx = self.minx - radius,
            .miny = self.miny - radius,
            .maxx = self.maxx + radius,
            .maxy = self.maxy + radius,
        };
    }
};

/// One final connected pour component, identified on the board's physical
/// 1-based copper stack rather than the unrelated persisted signal index.
const Surface = struct {
    net: []const u8,
    net_index: i32,
    carrier: pour.PlaneNet,
    stack: u8,
    layer: ?board_layers.SignalIndex,
    outer: []const Point,
    holes: []const []const Point,
    box: Box,
};

const FillTarget = struct {
    net: []const u8,
    carrier: pour.PlaneNet,
    stack: u8,
    layer: ?board_layers.SignalIndex,
};

const ForeignParty = struct {
    net: i32,
    part: i32 = -1,
    pad: []const u8 = "",
};

/// Conservative straight-segment cover of one emitted circular arc. Each
/// chord capsule grows by the exact sagitta of its assigned arc span, so their
/// union contains the native G02/G03 stroke even when the defensive chord cap
/// is reached. The usual 0.1 µm target keeps the overstatement negligible.
const ArcProbe = struct {
    arc: router.Arc,
    circle: ?outline.ArcCircle,
    chord_count: usize,
    sagitta: f64,

    fn init(arc: router.Arc) ArcProbe {
        const circle = outline.arcCircle(.{ .p1 = arc.p1, .pm = arc.pm, .p2 = arc.p2 }) orelse
            return .{ .arc = arc, .circle = null, .chord_count = 1, .sagitta = 0 };
        if (!validArcCircle(circle))
            return .{ .arc = arc, .circle = null, .chord_count = 1, .sagitta = 0 };
        const sweep = @abs(circle.sweep);
        const max_step = 2 * std.math.acos(std.math.clamp(1 - arc_target_sagitta_mm / circle.radius, -1, 1));
        const raw = @ceil(sweep / @max(max_step, ring_eps));
        const count = @max(1, @min(max_arc_chords, numeric.toCount(raw)));
        const step = sweep / @as(f64, @floatFromInt(count));
        return .{
            .arc = arc,
            .circle = circle,
            .chord_count = count,
            .sagitta = circle.radius * (1 - @cos(step / 2)),
        };
    }

    fn point(self: ArcProbe, index: usize) Point {
        if (index == 0) return self.arc.p1;
        if (index >= self.chord_count) return self.arc.p2;
        const circle = self.circle orelse return self.arc.p2;
        const fraction = @as(f64, @floatFromInt(index)) / @as(f64, @floatFromInt(self.chord_count));
        const angle = circle.start_angle + circle.sweep * fraction;
        return .{ circle.cx + circle.radius * @cos(angle), circle.cy + circle.radius * @sin(angle) };
    }
};

fn validArcCircle(circle: outline.ArcCircle) bool {
    if (!(circle.radius > ring_eps)) return false;
    return std.math.isFinite(circle.radius) and std.math.isFinite(circle.sweep);
}

const Audit = struct {
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    identity: net_identity.Identity,
    violations: *std.ArrayList(drc.Violation),
    surfaces: *std.ArrayList(Surface),

    fn appendInvalid(self: Audit, net: []const u8, layer: ?board_layers.SignalIndex, at: Point) std.mem.Allocator.Error!void {
        try self.violations.append(self.arena, .{
            .x = if (std.math.isFinite(at[0])) at[0] else 0,
            .y = if (std.math.isFinite(at[1])) at[1] else 0,
            .gap = 0,
            .clearance = 0,
            .kind = .pour_invalid,
            .severity = drc.defaultSeverity(.pour_invalid),
            .who = .{ .net_a = namedNetIndex(self.placement, self.identity, net) },
            .layer = layer,
        });
    }

    fn appendOverlap(self: Audit, surface: Surface, foreign: ForeignParty, at: Point) std.mem.Allocator.Error!void {
        try self.violations.append(self.arena, .{
            .x = at[0],
            .y = at[1],
            .gap = 0,
            .clearance = 0,
            .kind = .pour_overlap,
            .severity = drc.defaultSeverity(.pour_overlap),
            .who = .{
                .net_a = surface.net_index,
                .net_b = self.identity.canonical(foreign.net),
                .part_b = foreign.part,
                .pad_b = foreign.pad,
            },
            .layer = surface.layer,
        });
    }

    fn appendFill(self: Audit, target: FillTarget, fill: pour.Fill) std.mem.Allocator.Error!void {
        if (!fill.integrity_ok or fill.holes.len != fill.contours.len) {
            try self.appendInvalid(target.net, target.layer, firstFillPoint(&.{fill}));
            return;
        }
        for (fill.contours, fill.holes) |outer, holes| {
            const box = Box.of(outer) orelse {
                try self.appendInvalid(target.net, target.layer, .{ 0, 0 });
                continue;
            };
            const candidate = Surface{
                .net = target.net,
                .net_index = namedNetIndex(self.placement, self.identity, target.net),
                .carrier = target.carrier,
                .stack = target.stack,
                .layer = target.layer,
                .outer = outer,
                .holes = holes,
                .box = box,
            };
            if (surfaceIssue(candidate)) |at| {
                try self.appendInvalid(target.net, target.layer, at);
            } else try self.surfaces.append(self.arena, candidate);
        }
    }
};

/// Audit every retained fill. The result is ordinary error-severity DRC, while
/// allocation failure propagates to `drc_compose`'s fail-closed completeness
/// bit instead of silently claiming the board was checked.
pub fn check(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    routed: router.RouteResult,
    prepared: drc.PreparedCopper,
) std.mem.Allocator.Error![]const drc.Violation {
    var violations: std.ArrayList(drc.Violation) = .empty;
    var surfaces: std.ArrayList(Surface) = .empty;
    const identity = try net_identity.Identity.init(arena, placement);
    const audit = Audit{ .arena = arena, .placement = placement, .identity = identity, .violations = &violations, .surfaces = &surfaces };

    for (prepared.plane_fills) |net_fills| {
        if (net_fills.layers.len != net_fills.fills.len) {
            try audit.appendInvalid(net_fills.net_name, null, firstFillPoint(net_fills.fills));
            continue;
        }
        for (net_fills.layers, net_fills.fills) |spec, fill| {
            const layer = if (spec.track_layer) |signal| board_layers.SignalIndex.of(signal) else null;
            if (spec.stack == 0 or spec.stack > placement.rules.layerStack().stackCount()) {
                try audit.appendInvalid(net_fills.net_name, layer, firstFillPoint(&.{fill}));
                continue;
            }
            try audit.appendFill(.{ .net = net_fills.net_name, .carrier = spec.net, .stack = spec.stack, .layer = layer }, fill);
        }
    }

    if (prepared.zones.len != prepared.zone_fills.len) {
        const point = if (prepared.zone_fills.len > 0) firstFillPoint(prepared.zone_fills) else .{ 0, 0 };
        try audit.appendInvalid("", null, point);
    }
    const zone_count = @min(prepared.zones.len, prepared.zone_fills.len);
    for (prepared.zones[0..zone_count], prepared.zone_fills[0..zone_count]) |zone, fill| {
        const signal_count = placement.rules.signalLayerCount();
        if (zone.layer >= signal_count) {
            try audit.appendInvalid(zone.net, null, firstFillPoint(&.{fill}));
            continue;
        }
        const layer = board_layers.SignalIndex.of(zone.layer);
        const stack = placement.rules.signalStackIndex(zone.layer);
        try audit.appendFill(.{ .net = zone.net, .carrier = .{ .named = zone.net }, .stack = stack, .layer = layer }, fill);
    }

    for (surfaces.items, 0..) |a, i| {
        for (surfaces.items[i + 1 ..]) |b| {
            if (a.stack != b.stack or sameCarrier(audit, a, b)) continue;
            const at = solidContact(a, b) orelse continue;
            var report_surface = a;
            report_surface.layer = a.layer orelse b.layer;
            try audit.appendOverlap(report_surface, .{ .net = b.net_index }, at);
        }
    }
    try checkForeignCopper(audit, routed);
    return violations.toOwnedSlice(arena);
}

fn firstFillPoint(fills: []const pour.Fill) Point {
    for (fills) |fill| for (fill.contours) |contour| if (contour.len > 0) return contour[0];
    return .{ 0, 0 };
}

/// The first malformed location in an outer-with-holes surface, or null when
/// its rings form one valid Gerber-polarity solid. Every ring is strict and
/// every hole must sit strictly inside without touching the dark outer.
/// Sibling LPC clear regions may meet at a zero-area tangency, but a proper
/// crossing, positive-area overlap, or containment is renderer-ambiguous and
/// remains invalid.
fn surfaceIssue(surface: Surface) ?Point {
    if (ringIssue(surface.outer)) |at| return at;
    for (surface.holes, 0..) |hole, i| {
        if (ringIssue(hole)) |at| return at;
        if (ringsContact(surface.outer, hole)) |at| return at;
        if (!pointInRing(surface.outer, hole[0])) return hole[0];
        for (surface.holes[0..i]) |prior| if (siblingHoleIssue(prior, hole)) |at| return at;
    }
    return null;
}

/// Contact/overlap between two already-valid final solids. Every boundary pair
/// is checked continuously; if no boundaries meet, mutual containment finds
/// the only remaining overlap case. `pointInSolid` subtracts holes.
fn solidContact(a: Surface, b: Surface) ?Point {
    if (!a.box.touches(b.box)) return null;
    if (ringsContact(a.outer, b.outer)) |at| return at;
    for (a.holes) |hole| if (ringsContact(hole, b.outer)) |at| return at;
    for (b.holes) |hole| if (ringsContact(a.outer, hole)) |at| return at;
    for (a.holes) |ah| for (b.holes) |bh| if (ringsContact(ah, bh)) |at| return at;
    if (pointInSolid(a, b.outer[0])) return b.outer[0];
    if (pointInSolid(b, a.outer[0])) return a.outer[0];
    return null;
}

fn pointInSolid(surface: Surface, point: Point) bool {
    if (!pointInRing(surface.outer, point)) return false;
    for (surface.holes) |hole| if (pointInRing(hole, point)) return false;
    return true;
}

/// Audit final pour solids against every independently emitted copper feature.
/// These are continuous primitive tests, not raster samples: ordinary tracks
/// are capsules, RF paths use their exact fabricated swept regions, vias are
/// discs, and pads use their world collision rings. Pads are considered only
/// on routable signal layers; vias span the complete physical stack.
fn checkForeignCopper(audit: Audit, routed: router.RouteResult) std.mem.Allocator.Error!void {
    const arcs = try path_copper.filterArcs(audit.arena, routed.rf_port_outcomes, routed.arcs);
    try checkForeignTracks(audit, routed.tracks, routed.rf_port_outcomes, arcs);
    try checkForeignRfPaths(audit, routed.rf_port_outcomes);
    try checkForeignArcs(audit, arcs);
    try checkForeignVias(audit, routed.vias);
    try checkForeignPads(audit);
}

fn checkForeignTracks(
    audit: Audit,
    tracks: []const router.Track,
    paths: []const rf_port_report.Outcome,
    arcs: []const router.Arc,
) std.mem.Allocator.Error!void {
    const signal_count = audit.placement.rules.signalLayerCount();
    for (tracks) |track| {
        if (!validTrack(track, signal_count) or
            path_copper.ownsTrack(paths, track) or
            arcOwnsTrack(arcs, track)) continue;
        const stack = audit.placement.rules.signalStackIndex(track.layer);
        const radius = @max(0, track.width / 2);
        for (audit.surfaces.items) |surface| {
            if (surface.stack != stack or carrierOwnsNet(audit, surface, track.net)) continue;
            const at = solidCapsuleContact(surface, .{ track.x1, track.y1 }, .{ track.x2, track.y2 }, radius) orelse continue;
            try audit.appendOverlap(surface, .{ .net = track.net }, at);
        }
    }
}

/// Audit each successful RF path as the exact polygon union Gerber emits.
/// Compact edit handles and solver chords are suppressed by
/// `checkForeignTracks`, so one physical path has one geometry authority and
/// a taper's narrow end is never widened to its other endpoint's width.
fn checkForeignRfPaths(audit: Audit, paths: []const rf_port_report.Outcome) std.mem.Allocator.Error!void {
    const signal_count = audit.placement.rules.signalLayerCount();
    for (paths) |path| {
        if (!path.success or path.physical.gate_removed) continue;
        if (path.physical.layer >= signal_count or path.physical.samples.len < 2) continue;
        const regions = try path_copper.regions(audit.arena, path.physical.samples);
        const stack = audit.placement.rules.signalStackIndex(path.physical.layer);
        for (audit.surfaces.items) |surface| {
            if (surface.stack != stack or carrierOwnsNet(audit, surface, path.net)) continue;
            for (regions) |region| {
                if (region.len < 3) continue;
                const at = solidRingContact(surface, region) orelse continue;
                try audit.appendOverlap(surface, .{ .net = path.net }, at);
                break;
            }
        }
    }
}

fn checkForeignArcs(audit: Audit, arcs: []const router.Arc) std.mem.Allocator.Error!void {
    const signal_count = audit.placement.rules.signalLayerCount();
    for (arcs) |arc| {
        if (!validArc(arc, signal_count)) continue;
        const stack = audit.placement.rules.signalStackIndex(arc.layer);
        const probe = ArcProbe.init(arc);
        for (audit.surfaces.items) |surface| {
            if (surface.stack != stack or carrierOwnsNet(audit, surface, arc.net)) continue;
            const at = solidArcContact(surface, probe) orelse continue;
            try audit.appendOverlap(surface, .{ .net = arc.net }, at);
        }
    }
}

fn validTrack(track: router.Track, signal_count: u8) bool {
    if (track.layer >= signal_count or !std.math.isFinite(track.width)) return false;
    return finitePoint(.{ track.x1, track.y1 }) and finitePoint(.{ track.x2, track.y2 });
}

fn validArc(arc: router.Arc, signal_count: u8) bool {
    if (arc.layer >= signal_count or !std.math.isFinite(arc.width)) return false;
    if (!finitePoint(arc.p1) or !finitePoint(arc.pm)) return false;
    return finitePoint(arc.p2);
}

fn arcOwnsTrack(arcs: []const router.Arc, track: router.Track) bool {
    for (arcs) |arc| {
        if (!matchingArcTrackIdentity(arc, track)) continue;
        if (outline.arcCircle(.{ .p1 = arc.p1, .pm = arc.pm, .p2 = arc.p2 }) == null) {
            if (sameSegment(arc.p1, arc.p2, .{ track.x1, track.y1 }, .{ track.x2, track.y2 })) return true;
            continue;
        }
        if (outline.arcOwnsSegment(.{ .p1 = arc.p1, .pm = arc.pm, .p2 = arc.p2 }, .{ track.x1, track.y1 }, .{ track.x2, track.y2 }, 0.0001)) return true;
    }
    return false;
}

fn matchingArcTrackIdentity(arc: router.Arc, track: router.Track) bool {
    if (arc.layer != track.layer or arc.net != track.net) return false;
    return @abs(arc.width - track.width) <= 0.0001;
}

fn sameSegment(a: Point, b: Point, c: Point, d: Point) bool {
    return (samePoint(a, c) and samePoint(b, d)) or (samePoint(a, d) and samePoint(b, c));
}

fn samePoint(a: Point, b: Point) bool {
    return distance2(a, b) <= ring_eps * ring_eps;
}

fn checkForeignVias(audit: Audit, vias: []const router.Via) std.mem.Allocator.Error!void {
    for (vias) |via| {
        const center = Point{ via.x, via.y };
        if (!finitePoint(center) or !std.math.isFinite(via.dia)) continue;
        const radius = @max(0, via.dia / 2);
        for (audit.surfaces.items) |surface| {
            if (carrierOwnsNet(audit, surface, via.net)) continue;
            const at = solidCapsuleContact(surface, center, center, radius) orelse continue;
            try audit.appendOverlap(surface, .{ .net = via.net }, at);
        }
    }
}

fn checkForeignPads(audit: Audit) std.mem.Allocator.Error!void {
    for (audit.placement.parts, 0..) |part, part_i| {
        for (part.pads) |pad| {
            if (pad.npth) continue;
            const pad_net = padNetIndex(audit.placement, part.ref_des, pad.number);
            const shape = try pad_shape.worldShape(audit.arena, part, pad);
            for (audit.surfaces.items) |surface| {
                if (!padOnSurface(audit.placement.rules, part, pad.thru, surface) or
                    carrierOwnsNet(audit, surface, pad_net)) continue;
                const at = solidPadContact(surface, shape) orelse continue;
                try audit.appendOverlap(surface, .{ .net = pad_net, .part = drc.partyIndex(part_i), .pad = pad.number }, at);
            }
        }
    }
}

fn padOnSurface(rules: optimizer.BoardRules, part: optimizer.Part, thru: bool, surface: Surface) bool {
    if (thru) return true;
    const signal = surface.layer orelse return false;
    if (rules.signalStackIndex(signal.int()) != surface.stack) return false;
    return switch (signal) {
        .top => part.side == .top,
        .bottom => part.side == .bottom,
        else => false,
    };
}

fn solidCapsuleContact(surface: Surface, a: Point, b: Point, radius: f64) ?Point {
    if (!surface.box.touches(segmentBox(a, b).grown(radius))) return null;
    if (pointInSolid(surface, a)) return a;
    if (pointInSolid(surface, b)) return b;
    if (ringCapsuleContact(surface.outer, a, b, radius)) |at| return at;
    for (surface.holes) |hole| if (ringCapsuleContact(hole, a, b, radius)) |at| return at;
    return null;
}

fn solidArcContact(surface: Surface, probe: ArcProbe) ?Point {
    var before = probe.point(0);
    const radius = @max(0, probe.arc.width / 2) + probe.sagitta;
    for (1..probe.chord_count + 1) |i| {
        const after = probe.point(i);
        if (solidCapsuleContact(surface, before, after, radius)) |at| return at;
        before = after;
    }
    return null;
}

fn ringCapsuleContact(ring: []const Point, a: Point, b: Point, radius: f64) ?Point {
    const capsule_box = segmentBox(a, b).grown(radius);
    for (ring, 0..) |p, i| {
        const q = ring[(i + 1) % ring.len];
        if (!capsule_box.touches(segmentBox(p, q))) continue;
        if (pad_shape.segSegDist(a, b, p, q) <= radius + ring_eps)
            return pad_shape.segSegMid(a, b, p, q);
    }
    return null;
}

fn solidPadContact(surface: Surface, shape: pad_shape.Shape) ?Point {
    if (shape.poly.len >= 3) return solidRingContact(surface, shape.poly);
    const rect = [4]Point{
        .{ shape.x0, shape.y0 },
        .{ shape.x1, shape.y0 },
        .{ shape.x1, shape.y1 },
        .{ shape.x0, shape.y1 },
    };
    return solidRingContact(surface, &rect);
}

fn solidRingContact(surface: Surface, ring: []const Point) ?Point {
    const box = Box.of(ring) orelse return null;
    if (!surface.box.touches(box)) return null;
    if (ringsContact(surface.outer, ring)) |at| return at;
    for (surface.holes) |hole| if (ringsContact(hole, ring)) |at| return at;
    if (pointInSolid(surface, ring[0])) return ring[0];
    if (pointInRing(ring, surface.outer[0])) return surface.outer[0];
    return null;
}

fn sameCarrier(audit: Audit, a: Surface, b: Surface) bool {
    if (audit.identity.same(a.net_index, b.net_index)) return true;
    const a_ground = carrierIsGround(audit, a);
    const b_ground = carrierIsGround(audit, b);
    if (a.carrier == .ground or b.carrier == .ground) return a_ground and b_ground;
    if (std.ascii.eqlIgnoreCase(a.carrier.named, b.carrier.named)) return true;
    const a_index = namedNetIndex(audit.placement, audit.identity, a.carrier.named);
    const b_index = namedNetIndex(audit.placement, audit.identity, b.carrier.named);
    return audit.identity.same(a_index, b_index);
}

fn carrierOwnsNet(audit: Audit, surface: Surface, feature_net: i32) bool {
    if (audit.identity.same(surface.net_index, feature_net)) return true;
    const feature_name = canonicalNetName(audit.placement, audit.identity, feature_net);
    return switch (surface.carrier) {
        .ground => optimizer.isGroundName(net_name.leaf(feature_name)),
        .named => |name| blk: {
            const carrier_index = namedNetIndex(audit.placement, audit.identity, name);
            break :blk audit.identity.same(carrier_index, feature_net) or
                std.ascii.eqlIgnoreCase(name, feature_name);
        },
    };
}

fn carrierIsGround(audit: Audit, surface: Surface) bool {
    return switch (surface.carrier) {
        .ground => true,
        .named => |name| optimizer.isGroundName(net_name.leaf(if (surface.net_index >= 0)
            canonicalNetName(audit.placement, audit.identity, surface.net_index)
        else
            name)),
    };
}

fn canonicalNetName(placement: optimizer.Placement, identity: net_identity.Identity, index: i32) []const u8 {
    return identity.canonicalName(placement.nets, index);
}

fn namedNetIndex(placement: optimizer.Placement, identity: net_identity.Identity, name: []const u8) i32 {
    if (name.len == 0) return -1;
    // An exact flattened spelling always wins. This also lets the canonical
    // owner of a structurally proven bypass stub identify its parent rail.
    for (placement.nets, 0..) |candidate, i| {
        const index = drc.partyIndex(i);
        if (std.ascii.eqlIgnoreCase(candidate.name, name) or
            std.ascii.eqlIgnoreCase(identity.canonicalName(placement.nets, index), name))
            return identity.canonical(index);
    }

    // A short declaration such as `VOUT` may refer to a flattened
    // `power/VOUT`, but only when that leaf identifies one physical net. Never
    // strip an already-qualified query: `left/SIG` and `right/SIG` are sibling
    // nets, not aliases merely because both end in `SIG`.
    if (std.mem.indexOfScalar(u8, name, '/') != null) return -1;
    var unique: i32 = -1;
    for (placement.nets, 0..) |candidate, i| {
        const index = drc.partyIndex(i);
        const canonical_name = identity.canonicalName(placement.nets, index);
        if (!std.ascii.eqlIgnoreCase(net_name.leaf(candidate.name), name) and
            !std.ascii.eqlIgnoreCase(net_name.leaf(canonical_name), name)) continue;
        const canonical = identity.canonical(index);
        if (unique < 0) {
            unique = canonical;
        } else if (!identity.same(unique, canonical)) {
            return -1;
        }
    }
    return unique;
}

fn padNetIndex(placement: optimizer.Placement, ref_des: []const u8, pad_number: []const u8) i32 {
    var result: i32 = -1;
    for (placement.nets, 0..) |net, i| {
        for (net.pins) |pin| {
            if (!std.mem.eql(u8, pin.ref_des, ref_des) or !std.mem.eql(u8, pin.pin, pad_number)) continue;
            result = drc.partyIndex(i);
        }
    }
    return result;
}

/// Strict simple-ring validation including the cases `outline.selfIntersects`
/// intentionally does not classify: collinear overlap, repeated vertices,
/// zero-length edges, adjacent 180-degree retrace, and non-finite coordinates.
fn ringIssue(poly: []const Point) ?Point {
    if (poly.len < 3) return if (poly.len > 0) poly[0] else .{ 0, 0 };
    var area2: f64 = 0;
    for (poly, 0..) |a, i| {
        const b = poly[(i + 1) % poly.len];
        if (!finitePoint(a) or !finitePoint(b)) return a;
        if (distance2(a, b) <= ring_eps * ring_eps) return a;
        area2 += a[0] * b[1] - b[0] * a[1];
        for (i + 1..poly.len) |j| {
            const c = poly[j];
            const d = poly[(j + 1) % poly.len];
            const adjacent = (i + 1) % poly.len == j or (j + 1) % poly.len == i;
            if (adjacent) {
                if (adjacentRetrace(a, b, c, d)) return b;
                continue;
            }
            if (segmentsTouch(a, b, c, d)) return midpoint4(a, b, c, d);
        }
    }
    if (!std.math.isFinite(area2) or @abs(area2) < area2_eps) return poly[0];
    return null;
}

fn ringsContact(a: []const Point, b: []const Point) ?Point {
    const a_box = Box.of(a) orelse return null;
    const b_box = Box.of(b) orelse return null;
    if (!a_box.touches(b_box)) return null;
    for (a, 0..) |p, i| {
        const q = a[(i + 1) % a.len];
        const ab = segmentBox(p, q);
        for (b, 0..) |r, j| {
            const s = b[(j + 1) % b.len];
            if (!ab.touches(segmentBox(r, s))) continue;
            if (segmentsTouch(p, q, r, s)) return midpoint4(p, q, r, s);
        }
    }
    return null;
}

/// A sibling clear-region relationship that removes positive-area copper.
/// Exterior tangencies are valid LPC union boundaries; crossings, containment,
/// and coincident edges whose interiors lie on the same side are not.
fn siblingHoleIssue(a: []const Point, b: []const Point) ?Point {
    const a_box = Box.of(a) orelse return null;
    const b_box = Box.of(b) orelse return null;
    if (!a_box.touches(b_box)) return null;
    const a_area = outline.signedArea2(a);
    const b_area = outline.signedArea2(b);
    for (a, 0..) |p, i| {
        const q = a[(i + 1) % a.len];
        for (b, 0..) |r, j| {
            const s = b[(j + 1) % b.len];
            if (!segmentBox(p, q).touches(segmentBox(r, s))) continue;
            const tolerance = segmentTolerance(p, q, r, s);
            const pqr = orient(p, q, r);
            const pqs = orient(p, q, s);
            const rsp = orient(r, s, p);
            const rsq = orient(r, s, q);
            if (opposite(pqr, pqs, tolerance) and opposite(rsp, rsq, tolerance))
                return midpoint4(p, q, r, s);
            const collinear = @abs(pqr) <= tolerance and @abs(pqs) <= tolerance and
                @abs(rsp) <= tolerance and @abs(rsq) <= tolerance;
            if (collinear and collinearOverlap(p, q, r, s) > tolerance and
                sameInteriorSide(p, q, a_area, r, s, b_area))
                return midpoint4(p, q, r, s);
        }
    }
    for (a) |point| if (pointStrictlyInRing(b, point)) return point;
    for (b) |point| if (pointStrictlyInRing(a, point)) return point;
    return null;
}

fn segmentTolerance(a: Point, b: Point, c: Point, d: Point) f64 {
    return ring_eps * @max(1, @max(std.math.hypot(b[0] - a[0], b[1] - a[1]), std.math.hypot(d[0] - c[0], d[1] - c[1])));
}

fn collinearOverlap(a: Point, b: Point, c: Point, d: Point) f64 {
    if (@abs(b[0] - a[0]) >= @abs(b[1] - a[1]))
        return @min(@max(a[0], b[0]), @max(c[0], d[0])) - @max(@min(a[0], b[0]), @min(c[0], d[0]));
    return @min(@max(a[1], b[1]), @max(c[1], d[1])) - @max(@min(a[1], b[1]), @min(c[1], d[1]));
}

fn sameInteriorSide(a: Point, b: Point, a_area: f64, c: Point, d: Point, b_area: f64) bool {
    const an = if (a_area > 0)
        Point{ a[1] - b[1], b[0] - a[0] }
    else
        Point{ b[1] - a[1], a[0] - b[0] };
    const bn = if (b_area > 0)
        Point{ c[1] - d[1], d[0] - c[0] }
    else
        Point{ d[1] - c[1], c[0] - d[0] };
    return an[0] * bn[0] + an[1] * bn[1] > 0;
}

fn pointStrictlyInRing(poly: []const Point, point: Point) bool {
    for (poly, 0..) |a, i| {
        const b = poly[(i + 1) % poly.len];
        const tolerance = ring_eps * @max(1, std.math.hypot(b[0] - a[0], b[1] - a[1]));
        if (@abs(orient(a, b, point)) <= tolerance and pointOnSegment(point, a, b, tolerance)) return false;
    }
    return pointInRing(poly, point);
}

fn segmentsTouch(a: Point, b: Point, c: Point, d: Point) bool {
    if (!segmentBox(a, b).touches(segmentBox(c, d))) return false;
    const tolerance = segmentTolerance(a, b, c, d);
    const abc = orient(a, b, c);
    const abd = orient(a, b, d);
    const cda = orient(c, d, a);
    const cdb = orient(c, d, b);
    if (opposite(abc, abd, tolerance) and opposite(cda, cdb, tolerance)) return true;
    if (@abs(abc) <= tolerance and pointOnSegment(c, a, b, tolerance)) return true;
    if (@abs(abd) <= tolerance and pointOnSegment(d, a, b, tolerance)) return true;
    if (@abs(cda) <= tolerance and pointOnSegment(a, c, d, tolerance)) return true;
    return @abs(cdb) <= tolerance and pointOnSegment(b, c, d, tolerance);
}

fn adjacentRetrace(a: Point, b: Point, c: Point, d: Point) bool {
    const ab = Point{ b[0] - a[0], b[1] - a[1] };
    const cd = Point{ d[0] - c[0], d[1] - c[1] };
    const scale = @max(1, std.math.hypot(ab[0], ab[1]) * std.math.hypot(cd[0], cd[1]));
    return @abs(ab[0] * cd[1] - ab[1] * cd[0]) <= ring_eps * scale and
        ab[0] * cd[0] + ab[1] * cd[1] < -ring_eps * scale;
}

fn pointInRing(poly: []const Point, point: Point) bool {
    var inside = false;
    var j = poly.len - 1;
    for (poly, 0..) |a, i| {
        const b = poly[j];
        if ((a[1] > point[1]) != (b[1] > point[1])) {
            const crossing_x = (b[0] - a[0]) * (point[1] - a[1]) / (b[1] - a[1]) + a[0];
            if (point[0] < crossing_x) inside = !inside;
        }
        j = i;
    }
    return inside;
}

fn pointOnSegment(point: Point, a: Point, b: Point, tolerance: f64) bool {
    return point[0] >= @min(a[0], b[0]) - tolerance and point[0] <= @max(a[0], b[0]) + tolerance and
        point[1] >= @min(a[1], b[1]) - tolerance and point[1] <= @max(a[1], b[1]) + tolerance;
}

fn opposite(a: f64, b: f64, tolerance: f64) bool {
    return (a > tolerance and b < -tolerance) or (a < -tolerance and b > tolerance);
}

fn orient(a: Point, b: Point, c: Point) f64 {
    return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]);
}

fn segmentBox(a: Point, b: Point) Box {
    return .{ .minx = @min(a[0], b[0]), .miny = @min(a[1], b[1]), .maxx = @max(a[0], b[0]), .maxy = @max(a[1], b[1]) };
}

fn midpoint4(a: Point, b: Point, c: Point, d: Point) Point {
    return .{ (a[0] + b[0] + c[0] + d[0]) / 4, (a[1] + b[1] + c[1] + d[1]) / 4 };
}

fn distance2(a: Point, b: Point) f64 {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    return dx * dx + dy * dy;
}

fn finitePoint(point: Point) bool {
    return std.math.isFinite(point[0]) and std.math.isFinite(point[1]);
}

// ── Tests ───────────────────────────────────────────────────────────────────

fn testSurface(net: []const u8, outer: []const Point, holes: []const []const Point) Surface {
    return .{ .net = net, .net_index = -1, .carrier = .{ .named = net }, .stack = 1, .layer = .top, .outer = outer, .holes = holes, .box = Box.of(outer).? };
}

fn testRoute(tracks: []const router.Track, vias: []const router.Via) router.RouteResult {
    return .{ .tracks = tracks, .vias = vias, .routed = tracks.len, .total = tracks.len };
}

fn testPlacement(nets: []const optimizer.FlatNet, rules: optimizer.BoardRules) optimizer.Placement {
    return .{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 10,
        .maxy = 10,
        .generated = false,
        .rules = rules,
    };
}

fn testFill(contours: []const []const Point, holes: []const []const []const Point) pour.Fill {
    return .{
        .frame = .{ .minx = 0, .miny = 0, .pitch = 1, .nx = 0, .ny = 0 },
        .labels = &.{},
        .n_comp = contours.len,
        .contours = contours,
        .holes = holes,
        .coarsened = false,
    };
}

// spec: placement/drc - malformed final pour outers and holes are fab-blocking DRC errors
test "pour audit rejects self-intersecting outer and hole rings" {
    var arena_i = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();
    const square = [_]Point{ .{ 0, 0 }, .{ 4, 0 }, .{ 4, 4 }, .{ 0, 4 } };
    const bow_tie = [_]Point{ .{ 0, 0 }, .{ 4, 4 }, .{ 0, 4 }, .{ 4, 0 } };
    try std.testing.expect(surfaceIssue(testSurface("A", &bow_tie, &.{})) != null);

    const hole = [_][]const Point{&bow_tie};
    try std.testing.expect(surfaceIssue(testSurface("A", &square, &hole)) != null);

    const contours = [_][]const Point{&bow_tie};
    const no_component_holes = [_][]const Point{};
    const holes_by_component = [_][]const []const Point{&no_component_holes};
    const fills = [_]pour.Fill{testFill(&contours, &holes_by_component)};
    const layers = [_]pour.LayerSpec{.{ .net = .{ .named = "A" }, .stack = 1, .side = .top, .track_layer = 0 }};
    const plane_fills = [_]pour.NetFills{.{ .net_name = "A", .layers = &layers, .fills = &fills }};
    const nets = [_]optimizer.FlatNet{.{ .name = "A", .pins = &.{} }};
    const violations = try check(arena, testPlacement(&nets, .{}), testRoute(&.{}, &.{}), .{ .topology_zones = &.{}, .plane_fills = &plane_fills, .zones = &.{}, .zone_fills = &.{} });
    try std.testing.expectEqual(@as(usize, 1), drc.countKind(violations, .pour_invalid));
}

// spec: placement/drc - sibling Gerber clear-hole regions may be disjoint or meet at zero-area tangencies, while proper crossings, positive-area overlap, containment/nesting, malformed rings, and dark-outer contact remain invalid
test "pour audit accepts sibling tangency but rejects overlap nesting and outer contact" {
    const outer = [_]Point{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } };
    const first = [_]Point{ .{ 2, 2 }, .{ 5, 2 }, .{ 5, 5 }, .{ 2, 5 } };
    const touching = [_]Point{ .{ 5, 5 }, .{ 8, 5 }, .{ 8, 8 }, .{ 5, 8 } };
    const overlapping = [_]Point{ .{ 4, 3 }, .{ 7, 3 }, .{ 7, 6 }, .{ 4, 6 } };
    const nested = [_]Point{ .{ 3, 3 }, .{ 4, 3 }, .{ 4, 4 }, .{ 3, 4 } };
    const collinear_overlap = [_]Point{ .{ 4, 2 }, .{ 7, 2 }, .{ 7, 5 }, .{ 4, 5 } };
    const outer_touch = [_]Point{ .{ 0, 3 }, .{ 2, 3 }, .{ 2, 5 }, .{ 0, 5 } };

    const touch_union = [_][]const Point{ &first, &touching };
    const overlap_union = [_][]const Point{ &first, &overlapping };
    const nested_union = [_][]const Point{ &first, &nested };
    const collinear_union = [_][]const Point{ &first, &collinear_overlap };
    const invalid_outer = [_][]const Point{&outer_touch};
    try std.testing.expect(surfaceIssue(testSurface("GND", &outer, &touch_union)) == null);
    try std.testing.expect(surfaceIssue(testSurface("GND", &outer, &overlap_union)) != null);
    try std.testing.expect(surfaceIssue(testSurface("GND", &outer, &nested_union)) != null);
    try std.testing.expect(surfaceIssue(testSurface("GND", &outer, &collinear_union)) != null);
    try std.testing.expect(surfaceIssue(testSurface("GND", &outer, &invalid_outer)) != null);
}

// spec: placement/drc - final pour overlap checks subtract holes and allow same-net unions
test "pour audit solid contact respects holes while same-net identity remains mergeable" {
    const outer = [_]Point{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } };
    const hole_ring = [_]Point{ .{ 3, 3 }, .{ 7, 3 }, .{ 7, 7 }, .{ 3, 7 } };
    const holes = [_][]const Point{&hole_ring};
    const inside_hole = [_]Point{ .{ 4, 4 }, .{ 6, 4 }, .{ 6, 6 }, .{ 4, 6 } };
    const inside_copper = [_]Point{ .{ 1, 1 }, .{ 2, 1 }, .{ 2, 2 }, .{ 1, 2 } };
    const donut = testSurface("GND", &outer, &holes);
    try std.testing.expect(solidContact(donut, testSurface("VCC", &inside_hole, &.{})) == null);
    try std.testing.expect(solidContact(donut, testSurface("VCC", &inside_copper, &.{})) != null);
}

// spec: placement/drc - a leaf-only net alias is accepted only when unique; sibling flattened nets with the same leaf remain distinct copper
test "pour audit does not coalesce sibling nets that share a leaf name" {
    var arena_i = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();
    const nets = [_]optimizer.FlatNet{
        .{ .name = "left/SIG", .pins = &.{} },
        .{ .name = "right/SIG", .pins = &.{} },
    };
    const placement = testPlacement(&nets, .{});
    const identity = try net_identity.Identity.init(arena, placement);
    try std.testing.expectEqual(@as(i32, -1), namedNetIndex(placement, identity, "SIG"));
    try std.testing.expectEqual(@as(i32, 0), namedNetIndex(placement, identity, "left/SIG"));
    try std.testing.expectEqual(@as(i32, 1), namedNetIndex(placement, identity, "right/SIG"));

    const overlap = [_]Point{ .{ 0, 0 }, .{ 2, 0 }, .{ 2, 2 }, .{ 0, 2 } };
    const contours = [_][]const Point{&overlap};
    const no_holes = [_][]const Point{};
    const holes = [_][]const []const Point{&no_holes};
    const fills = [_]pour.Fill{testFill(&contours, &holes)};
    const left_layer = [_]pour.LayerSpec{.{ .net = .{ .named = "left/SIG" }, .stack = 1, .side = .top, .track_layer = 0 }};
    const right_layer = [_]pour.LayerSpec{.{ .net = .{ .named = "right/SIG" }, .stack = 1, .side = .top, .track_layer = 0 }};
    const planes = [_]pour.NetFills{
        .{ .net_name = "left/SIG", .layers = &left_layer, .fills = &fills },
        .{ .net_name = "right/SIG", .layers = &right_layer, .fills = &fills },
    };
    const violations = try check(arena, placement, testRoute(&.{}, &.{}), .{
        .topology_zones = &.{},
        .plane_fills = &planes,
        .zones = &.{},
        .zone_fills = &.{},
    });
    try std.testing.expectEqual(@as(usize, 1), drc.countKind(violations, .pour_overlap));
}

test "pour audit resolves one unqualified leaf alias to its canonical net" {
    var arena_i = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();
    const nets = [_]optimizer.FlatNet{.{ .name = "power/VOUT", .pins = &.{} }};
    const placement = testPlacement(&nets, .{});
    const identity = try net_identity.Identity.init(arena, placement);
    try std.testing.expectEqual(@as(i32, 0), namedNetIndex(placement, identity, "VOUT"));
    const surface = testSurface("VOUT", &.{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 } }, &.{});
    var violations: std.ArrayList(drc.Violation) = .empty;
    var surfaces: std.ArrayList(Surface) = .empty;
    const audit = Audit{ .arena = arena, .placement = placement, .identity = identity, .violations = &violations, .surfaces = &surfaces };
    try std.testing.expect(carrierOwnsNet(audit, surface, 0));
}

// spec: placement/drc - different-net final pour solids may not overlap or touch on one physical copper layer
test "pour audit flags foreign overlap and boundary touch" {
    var arena_i = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();
    const nets = [_]optimizer.FlatNet{ .{ .name = "A", .pins = &.{} }, .{ .name = "B", .pins = &.{} } };
    const placement = testPlacement(&nets, .{});
    const a = [_]Point{ .{ 0, 0 }, .{ 2, 0 }, .{ 2, 2 }, .{ 0, 2 } };
    const b = [_]Point{ .{ 2, 0.5 }, .{ 3, 0.5 }, .{ 3, 1.5 }, .{ 2, 1.5 } };
    const empty_holes = [_][]const Point{};
    const fill_holes = [_][]const []const Point{&empty_holes};
    const a_contours = [_][]const Point{&a};
    const b_contours = [_][]const Point{&b};
    const fills_a = [_]pour.Fill{testFill(&a_contours, &fill_holes)};
    const fills_b = [_]pour.Fill{testFill(&b_contours, &fill_holes)};
    const layers_a = [_]pour.LayerSpec{.{ .net = .{ .named = "A" }, .stack = 1, .side = .top, .track_layer = 0 }};
    const layers_b = [_]pour.LayerSpec{.{ .net = .{ .named = "B" }, .stack = 1, .side = .top, .track_layer = 0 }};
    const planes = [_]pour.NetFills{
        .{ .net_name = "A", .layers = &layers_a, .fills = &fills_a },
        .{ .net_name = "B", .layers = &layers_b, .fills = &fills_b },
    };
    const violations = try check(arena, placement, testRoute(&.{}, &.{}), .{ .topology_zones = &.{}, .plane_fills = &planes, .zones = &.{}, .zone_fills = &.{} });
    try std.testing.expectEqual(@as(usize, 1), drc.countKind(violations, .pour_overlap));
}

// spec: placement/drc - pour overlap compares a zone signal index with a plane's physical stack index
test "pour audit keys signal zones and planes by physical stack position" {
    var arena_i = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();
    const plane_names = [_][]const u8{"A"};
    const plane_defs = [_]optimizer.PlaneAt{.{ .index = 2, .net = "A" }};
    const rules = optimizer.BoardRules{ .plane_nets = &plane_names, .copper_layers = 4, .planes = .{ .declared = &plane_defs } };
    const nets = [_]optimizer.FlatNet{ .{ .name = "A", .pins = &.{} }, .{ .name = "B", .pins = &.{} } };
    const placement = testPlacement(&nets, rules);
    try std.testing.expectEqual(@as(u8, 3), placement.rules.signalStackIndex(2));

    const square = [_]Point{ .{ 0, 0 }, .{ 2, 0 }, .{ 2, 2 }, .{ 0, 2 } };
    const contours = [_][]const Point{&square};
    const empty_holes = [_][]const Point{};
    const holes = [_][]const []const Point{&empty_holes};
    const plane_fill = [_]pour.Fill{testFill(&contours, &holes)};
    const zone_fill = [_]pour.Fill{testFill(&contours, &holes)};
    const zone = [_]pour.UserZone{.{ .net = "B", .layer = 2, .poly = &square }};

    const stack_two = [_]pour.LayerSpec{.{ .net = .{ .named = "A" }, .stack = 2 }};
    const planes_two = [_]pour.NetFills{.{ .net_name = "A", .layers = &stack_two, .fills = &plane_fill }};
    const separate = try check(arena, placement, testRoute(&.{}, &.{}), .{ .topology_zones = &.{}, .plane_fills = &planes_two, .zones = &zone, .zone_fills = &zone_fill });
    try std.testing.expectEqual(@as(usize, 0), drc.countKind(separate, .pour_overlap));

    const stack_three = [_]pour.LayerSpec{.{ .net = .{ .named = "A" }, .stack = 3 }};
    const planes_three = [_]pour.NetFills{.{ .net_name = "A", .layers = &stack_three, .fills = &plane_fill }};
    const overlapping = try check(arena, placement, testRoute(&.{}, &.{}), .{ .topology_zones = &.{}, .plane_fills = &planes_three, .zones = &zone, .zone_fills = &zone_fill });
    try std.testing.expectEqual(@as(usize, 1), drc.countKind(overlapping, .pour_overlap));
}

// spec: placement/drc - independently emitted tracks, vias, and signal-layer pads may not contact a foreign final pour solid, while holes and physical-layer separation remain empty
test "pour audit catches foreign routed copper continuously and respects holes and pad faces" {
    const geometry = @import("geometry.zig");
    const FlatPin = @import("../flat_netlist.zig").FlatPin;
    var arena_i = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const outer = [_]Point{ .{ 0, 0 }, .{ 4, 0 }, .{ 4, 4 }, .{ 0, 4 } };
    const hole_ring = [_]Point{ .{ 1, 1 }, .{ 3, 1 }, .{ 3, 3 }, .{ 1, 3 } };
    const component_holes = [_][]const Point{&hole_ring};
    const contours = [_][]const Point{&outer};
    const holes = [_][]const []const Point{&component_holes};
    const fills = [_]pour.Fill{testFill(&contours, &holes)};
    const layers = [_]pour.LayerSpec{.{ .net = .{ .named = "A" }, .stack = 1, .side = .top, .track_layer = 0 }};
    const planes = [_]pour.NetFills{.{ .net_name = "A", .layers = &layers, .fills = &fills }};

    const smd = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    const thru = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4, .thru = true, .drill = 0.2 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "TOP", .kind = .passive, .hw = 0.3, .hh = 0.3, .pads = &smd, .fallback = false, .x = 3.5, .y = 3.5 },
        .{ .ref_des = "BOT", .kind = .passive, .hw = 0.3, .hh = 0.3, .pads = &smd, .fallback = false, .x = 3.5, .y = 3.5, .side = .bottom },
        .{ .ref_des = "THRU", .kind = .passive, .hw = 0.3, .hh = 0.3, .pads = &thru, .fallback = false, .x = 2, .y = 2 },
    };
    const b_pins = [_]FlatPin{
        .{ .ref_des = "TOP", .pin = "1" },
        .{ .ref_des = "BOT", .pin = "1" },
        .{ .ref_des = "THRU", .pin = "1" },
    };
    const nets = [_]optimizer.FlatNet{ .{ .name = "A", .pins = &.{} }, .{ .name = "B", .pins = &b_pins } };
    var placement = testPlacement(&nets, .{});
    placement.parts = &parts;

    const tracks = [_]router.Track{
        .{ .x1 = -1, .y1 = 0.5, .x2 = 5, .y2 = 0.5, .layer = 0, .width = 0.2, .net = 1 },
        .{ .x1 = 1.5, .y1 = 2, .x2 = 2.5, .y2 = 2, .layer = 0, .width = 0.2, .net = 1 },
        .{ .x1 = -1, .y1 = 0.5, .x2 = 5, .y2 = 0.5, .layer = 1, .width = 0.2, .net = 1 },
    };
    const vias = [_]router.Via{
        .{ .x = 0.5, .y = 2, .dia = 0.4, .net = 1 },
        .{ .x = 2, .y = 2, .dia = 0.2, .net = 1 },
        .{ .x = 0.5, .y = 3, .dia = 0.4, .net = 0 },
    };
    const violations = try check(arena, placement, testRoute(&tracks, &vias), .{ .topology_zones = &.{}, .plane_fills = &planes, .zones = &.{}, .zone_fills = &.{} });
    try std.testing.expectEqual(@as(usize, 3), drc.countKind(violations, .pour_overlap));

    const no_holes = [_][]const Point{};
    const solid_holes = [_][]const []const Point{&no_holes};
    const inner_fills = [_]pour.Fill{testFill(&contours, &solid_holes)};
    const inner_layer = [_]pour.LayerSpec{.{ .net = .{ .named = "A" }, .stack = 2 }};
    const inner_planes = [_]pour.NetFills{.{ .net_name = "A", .layers = &inner_layer, .fills = &inner_fills }};
    const inner = try check(arena, placement, testRoute(&.{}, &.{}), .{ .topology_zones = &.{}, .plane_fills = &inner_planes, .zones = &.{}, .zone_fills = &.{} });
    try std.testing.expectEqual(@as(usize, 1), drc.countKind(inner, .pour_overlap));
}

// spec: placement/drc - native routed arc strokes are audited against final pours on outer and inner physical layers, subtract holes, and replace their stored chords
test "pour audit covers native arc bulges without retaining their chord handles" {
    var arena_i = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();
    const plane_names = [_][]const u8{"PWR"};
    const plane_defs = [_]optimizer.PlaneAt{.{ .index = 2, .net = "PWR" }};
    const rules = optimizer.BoardRules{ .plane_nets = &plane_names, .copper_layers = 4, .planes = .{ .declared = &plane_defs } };
    const nets = [_]optimizer.FlatNet{ .{ .name = "A", .pins = &.{} }, .{ .name = "B", .pins = &.{} }, .{ .name = "PWR", .pins = &.{} } };
    const placement = testPlacement(&nets, rules);

    const bulge = [_]Point{ .{ 1.7, -0.3 }, .{ 2.3, -0.3 }, .{ 2.3, 0.3 }, .{ 1.7, 0.3 } };
    const chord_only = [_]Point{ .{ 1.7, 1.7 }, .{ 2.3, 1.7 }, .{ 2.3, 2.3 }, .{ 1.7, 2.3 } };
    const empty_holes = [_][]const Point{};
    const one_empty = [_][]const []const Point{&empty_holes};
    const bulge_contours = [_][]const Point{&bulge};
    const chord_contours = [_][]const Point{&chord_only};
    const bulge_fill = [_]pour.Fill{testFill(&bulge_contours, &one_empty)};
    const chord_fill = [_]pour.Fill{testFill(&chord_contours, &one_empty)};
    const top_layer = [_]pour.LayerSpec{.{ .net = .{ .named = "A" }, .stack = 1, .side = .top, .track_layer = 0 }};
    const top_bulge = [_]pour.NetFills{.{ .net_name = "A", .layers = &top_layer, .fills = &bulge_fill }};
    const top_chord = [_]pour.NetFills{.{ .net_name = "A", .layers = &top_layer, .fills = &chord_fill }};

    const chord = [_]router.Track{.{ .x1 = 0, .y1 = 2, .x2 = 4, .y2 = 2, .layer = 0, .width = 0.2, .net = 1 }};
    const top_arc = [_]router.Arc{.{ .p1 = .{ 0, 2 }, .pm = .{ 2, 0 }, .p2 = .{ 4, 2 }, .layer = 0, .width = 0.2, .net = 1 }};
    var top_route = testRoute(&chord, &.{});
    top_route.arcs = &top_arc;
    const hit = try check(arena, placement, top_route, .{ .topology_zones = &.{}, .plane_fills = &top_bulge, .zones = &.{}, .zone_fills = &.{} });
    try std.testing.expectEqual(@as(usize, 1), drc.countKind(hit, .pour_overlap));
    const suppressed_chord = try check(arena, placement, top_route, .{ .topology_zones = &.{}, .plane_fills = &top_chord, .zones = &.{}, .zone_fills = &.{} });
    try std.testing.expectEqual(@as(usize, 0), drc.countKind(suppressed_chord, .pour_overlap));

    const donut_outer = [_]Point{ .{ -1, -1 }, .{ 5, -1 }, .{ 5, 3 }, .{ -1, 3 } };
    const donut_hole = [_]Point{ .{ -0.5, -0.5 }, .{ 4.5, -0.5 }, .{ 4.5, 2.5 }, .{ -0.5, 2.5 } };
    const donut_holes = [_][]const Point{&donut_hole};
    const donut_contours = [_][]const Point{&donut_outer};
    const donut_by_component = [_][]const []const Point{&donut_holes};
    const donut_fill = [_]pour.Fill{testFill(&donut_contours, &donut_by_component)};
    const donut_plane = [_]pour.NetFills{.{ .net_name = "A", .layers = &top_layer, .fills = &donut_fill }};
    const in_hole = try check(arena, placement, top_route, .{ .topology_zones = &.{}, .plane_fills = &donut_plane, .zones = &.{}, .zone_fills = &.{} });
    try std.testing.expectEqual(@as(usize, 0), drc.countKind(in_hole, .pour_overlap));

    const inner_arc = [_]router.Arc{.{ .p1 = .{ 0, 2 }, .pm = .{ 2, 0 }, .p2 = .{ 4, 2 }, .layer = 2, .width = 0.2, .net = 1 }};
    var inner_route = testRoute(&.{}, &.{});
    inner_route.arcs = &inner_arc;
    const inner_zone = [_]pour.UserZone{.{ .net = "A", .layer = 2, .poly = &bulge }};
    const inner_hit = try check(arena, placement, inner_route, .{ .topology_zones = &.{}, .plane_fills = &.{}, .zones = &inner_zone, .zone_fills = &bulge_fill });
    try std.testing.expectEqual(@as(usize, 1), drc.countKind(inner_hit, .pour_overlap));
}

// spec: placement/drc - foreign-pour DRC audits an RF path's exact swept regions and suppresses its compact handles, never replacing a narrow taper end with the widest endpoint capsule
test "pour audit uses exact RF taper regions instead of widest endpoint capsules" {
    const Sample = @import("rf_path_solver.zig").Sample;
    var arena_i = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const nets = [_]optimizer.FlatNet{
        .{ .name = "GND", .pins = &.{} },
        .{ .name = "RF", .pins = &.{} },
    };
    const placement = testPlacement(&nets, .{});
    const samples = [_]Sample{
        .{ .at = .{ 0, 0 }, .s_mm = 0, .curvature = 0, .width_mm = 2 },
        .{ .at = .{ 4, 0 }, .s_mm = 4, .curvature = 0, .width_mm = 0.2 },
    };
    const paths = [_]rf_port_report.Outcome{.{
        .net = 1,
        .chosen = 0,
        .feasible = true,
        .success = true,
        .metrics = .{},
        .trials = &.{},
        .physical = .{ .sample_count = samples.len, .samples = &samples, .layer = 0 },
    }};
    const handles = [_]router.Track{.{
        .x1 = 0,
        .y1 = 0,
        .x2 = 4,
        .y2 = 0,
        .layer = 0,
        .width = 0.2,
        .net = 1,
    }};
    var routed = testRoute(&handles, &.{});
    routed.rf_port_outcomes = &paths;

    const narrow_clear = [_]Point{ .{ 3.4, 0.35 }, .{ 3.8, 0.35 }, .{ 3.8, 0.55 }, .{ 3.4, 0.55 } };
    const exact_hit = [_]Point{ .{ 3.4, 0.15 }, .{ 3.8, 0.15 }, .{ 3.8, 0.3 }, .{ 3.4, 0.3 } };
    const empty_holes = [_][]const Point{};
    const holes = [_][]const []const Point{&empty_holes};
    const layer = [_]pour.LayerSpec{.{ .net = .{ .named = "GND" }, .stack = 1, .side = .top, .track_layer = 0 }};

    // This is the old false-positive geometry: a max-endpoint 2 mm capsule
    // reaches the narrow-end square even though the fabricated taper does not.
    try std.testing.expect(solidCapsuleContact(testSurface("GND", &narrow_clear, &.{}), samples[0].at, samples[1].at, 1) != null);
    const clear_contours = [_][]const Point{&narrow_clear};
    const clear_fills = [_]pour.Fill{testFill(&clear_contours, &holes)};
    const clear_planes = [_]pour.NetFills{.{ .net_name = "GND", .layers = &layer, .fills = &clear_fills }};
    const clear = try check(arena, placement, routed, .{ .topology_zones = &.{}, .plane_fills = &clear_planes, .zones = &.{}, .zone_fills = &.{} });
    try std.testing.expectEqual(@as(usize, 0), drc.countKind(clear, .pour_overlap));

    // Moving the square onto the trapezoid's sloped flank is a real polygon
    // overlap and must still produce exactly one finding for the physical path.
    const hit_contours = [_][]const Point{&exact_hit};
    const hit_fills = [_]pour.Fill{testFill(&hit_contours, &holes)};
    const hit_planes = [_]pour.NetFills{.{ .net_name = "GND", .layers = &layer, .fills = &hit_fills }};
    const hit = try check(arena, placement, routed, .{ .topology_zones = &.{}, .plane_fills = &hit_planes, .zones = &.{}, .zone_fills = &.{} });
    try std.testing.expectEqual(@as(usize, 1), drc.countKind(hit, .pour_overlap));
}

// spec: placement/drc - implicit ground fills are one physical carrier and a fill whose boundary construction failed remains invalid even when empty
test "pour audit coalesces implicit ground carriers and preserves invalid empty fills" {
    var arena_i = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();
    const square = [_]Point{ .{ 0, 0 }, .{ 2, 0 }, .{ 2, 2 }, .{ 0, 2 } };
    const contours = [_][]const Point{&square};
    const empty_holes = [_][]const Point{};
    const holes = [_][]const []const Point{&empty_holes};
    const valid_fills = [_]pour.Fill{testFill(&contours, &holes)};
    const ground_layer = [_]pour.LayerSpec{.{ .net = .ground, .stack = 2 }};
    const ground_planes = [_]pour.NetFills{
        .{ .net_name = "GND", .layers = &ground_layer, .fills = &valid_fills },
        .{ .net_name = "AGND", .layers = &ground_layer, .fills = &valid_fills },
    };
    const nets = [_]optimizer.FlatNet{ .{ .name = "GND", .pins = &.{} }, .{ .name = "AGND", .pins = &.{} } };
    const placement = testPlacement(&nets, .{});
    const shared = try check(arena, placement, testRoute(&.{}, &.{}), .{ .topology_zones = &.{}, .plane_fills = &ground_planes, .zones = &.{}, .zone_fills = &.{} });
    try std.testing.expectEqual(@as(usize, 0), drc.countKind(shared, .pour_overlap));

    var invalid = testFill(&.{}, &.{});
    invalid.integrity_ok = false;
    const invalid_fills = [_]pour.Fill{invalid};
    const invalid_planes = [_]pour.NetFills{.{ .net_name = "GND", .layers = &ground_layer, .fills = &invalid_fills }};
    const rejected = try check(arena, placement, testRoute(&.{}, &.{}), .{ .topology_zones = &.{}, .plane_fills = &invalid_planes, .zones = &.{}, .zone_fills = &.{} });
    try std.testing.expectEqual(@as(usize, 1), drc.countKind(rejected, .pour_invalid));
}
