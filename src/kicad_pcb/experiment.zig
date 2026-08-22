//! Non-destructive KiCad reference-routing experiments.
//!
//! `virtualErase` creates an in-memory seed with selected traces/arcs/vias
//! removed while sharing all immutable placement, pad, zone, outline, and
//! stackup facts with the source snapshot. `scoreCandidate` compares a separate
//! candidate board against that fixed reference; neither function writes or
//! mutates a `.kicad_pcb` file.

const std = @import("std");
const snapshot_mod = @import("snapshot.zig");
const project_mod = @import("project_rules.zig");

/// Compact copper burden for a selected set of nets.
pub const CopperMetrics = struct {
    nets: usize = 0,
    segments: usize = 0,
    arcs: usize = 0,
    vias: usize = 0,
    length_mm: f64 = 0,
};

/// A shallow snapshot view with selected routed copper removed. Zones remain:
/// the experiment models deleting traces/vias in KiCad, not destroying planes.
pub const VirtualErasure = struct {
    seed: snapshot_mod.Snapshot,
    selected_nets: []const []const u8,
    unknown_nets: []const []const u8,
    removed: CopperMetrics,
    retained: CopperMetrics,
};

/// Candidate quality report. The scalar objective is intentionally dominated
/// lexicographically: fixed-geometry drift, then missing nets, then hard rule
/// violations, then via count and copper length. Lower is better.
pub const CandidateScore = struct {
    selected_nets: []const []const u8,
    unknown_nets: []const []const u8,
    eligible_nets: usize,
    routed_nets: usize,
    missing_nets: []const []const u8,
    fixed_geometry_mismatches: usize,
    rule_violations: usize,
    reference_rule_violations: usize,
    reference: CopperMetrics,
    candidate: CopperMetrics,
    reference_objective: f64,
    objective: f64,
};

const Selection = struct {
    all: bool,
    names: []const []const u8,
    unknown: []const []const u8,
};

/// Build an in-memory board view with all routed copper, or just `requested`
/// nets' routed copper, removed. The input snapshot is left byte-for-byte
/// unchanged and the seed shares its non-copper slices.
pub fn virtualErase(
    arena: std.mem.Allocator,
    board: snapshot_mod.Snapshot,
    requested: []const []const u8,
) std.mem.Allocator.Error!VirtualErasure {
    const selection = try resolveSelection(arena, board, requested);
    var seed = board;
    seed.segments = try filterSegments(arena, board.segments, selection, false);
    seed.arcs = try filterArcs(arena, board.arcs, selection, false);
    seed.vias = try filterVias(arena, board.vias, selection, false);
    return .{
        .seed = seed,
        .selected_nets = selection.names,
        .unknown_nets = selection.unknown,
        .removed = try copperMetrics(arena, board, selection, true),
        .retained = try copperMetrics(arena, board, selection, false),
    };
}

/// Score `candidate` against the selected reference routes. Footprints and the
/// outline are required to stay fixed. The reference project supplies global
/// hard manufacturing minima; net-class widths remain preferences, not DRC
/// minima, matching KiCad semantics.
pub fn scoreCandidate(
    arena: std.mem.Allocator,
    reference: snapshot_mod.Snapshot,
    candidate: snapshot_mod.Snapshot,
    project: ?project_mod.ProjectRules,
    requested: []const []const u8,
) std.mem.Allocator.Error!CandidateScore {
    const selection = try resolveSelection(arena, reference, requested);
    const eligible = try eligibleNets(arena, reference, selection);
    var missing: std.ArrayList([]const u8) = .empty;
    var routed: usize = 0;
    for (eligible) |name| {
        if (hasCopper(candidate, name)) {
            routed += 1;
        } else {
            try missing.append(arena, name);
        }
    }
    const ref_metrics = try copperMetrics(arena, reference, selection, true);
    const cand_metrics = try copperMetrics(arena, candidate, selection, true);
    const geometry = try fixedGeometryMismatches(arena, reference, candidate);
    const ref_rules = hardRuleViolations(reference, project, selection);
    const cand_rules = hardRuleViolations(candidate, project, selection);
    const missing_count = missing.items.len;
    const missing_names = try missing.toOwnedSlice(arena);
    return .{
        .selected_nets = selection.names,
        .unknown_nets = selection.unknown,
        .eligible_nets = eligible.len,
        .routed_nets = routed,
        .missing_nets = missing_names,
        .fixed_geometry_mismatches = geometry,
        .rule_violations = cand_rules,
        .reference_rule_violations = ref_rules,
        .reference = ref_metrics,
        .candidate = cand_metrics,
        .reference_objective = objective(0, 0, ref_rules, ref_metrics),
        .objective = objective(geometry, missing_count, cand_rules, cand_metrics),
    };
}

fn objective(geometry: usize, missing: usize, rules: usize, copper: CopperMetrics) f64 {
    return @as(f64, @floatFromInt(geometry)) * 1e12 +
        @as(f64, @floatFromInt(missing)) * 1e9 +
        @as(f64, @floatFromInt(rules)) * 1e6 +
        @as(f64, @floatFromInt(copper.vias)) * 20 +
        copper.length_mm;
}

fn resolveSelection(
    arena: std.mem.Allocator,
    board: snapshot_mod.Snapshot,
    requested: []const []const u8,
) std.mem.Allocator.Error!Selection {
    if (requested.len == 0) {
        const names = try arena.alloc([]const u8, board.nets.len);
        for (board.nets, names) |net, *name| name.* = net.name;
        return .{ .all = true, .names = names, .unknown = &.{} };
    }
    var names: std.ArrayList([]const u8) = .empty;
    var unknown: std.ArrayList([]const u8) = .empty;
    for (requested) |want| {
        var found: ?[]const u8 = null;
        for (board.nets) |net| {
            if (std.ascii.eqlIgnoreCase(net.name, want)) {
                found = net.name;
                break;
            }
        }
        if (found) |name| {
            if (!containsName(names.items, name)) try names.append(arena, name);
        } else if (!containsName(unknown.items, want)) {
            try unknown.append(arena, want);
        }
    }
    return .{
        .all = false,
        .names = try names.toOwnedSlice(arena),
        .unknown = try unknown.toOwnedSlice(arena),
    };
}

fn containsName(names: []const []const u8, want: []const u8) bool {
    for (names) |name| if (std.ascii.eqlIgnoreCase(name, want)) return true;
    return false;
}

fn selected(selection: Selection, name: []const u8) bool {
    return selection.all or containsName(selection.names, name);
}

fn filterSegments(
    arena: std.mem.Allocator,
    source: []const snapshot_mod.Segment,
    selection: Selection,
    keep_selected: bool,
) std.mem.Allocator.Error![]const snapshot_mod.Segment {
    var out: std.ArrayList(snapshot_mod.Segment) = .empty;
    for (source) |item| if (selected(selection, item.net) == keep_selected) try out.append(arena, item);
    return out.toOwnedSlice(arena);
}

fn filterArcs(
    arena: std.mem.Allocator,
    source: []const snapshot_mod.Arc,
    selection: Selection,
    keep_selected: bool,
) std.mem.Allocator.Error![]const snapshot_mod.Arc {
    var out: std.ArrayList(snapshot_mod.Arc) = .empty;
    for (source) |item| if (selected(selection, item.net) == keep_selected) try out.append(arena, item);
    return out.toOwnedSlice(arena);
}

fn filterVias(
    arena: std.mem.Allocator,
    source: []const snapshot_mod.Via,
    selection: Selection,
    keep_selected: bool,
) std.mem.Allocator.Error![]const snapshot_mod.Via {
    var out: std.ArrayList(snapshot_mod.Via) = .empty;
    for (source) |item| if (selected(selection, item.net) == keep_selected) try out.append(arena, item);
    return out.toOwnedSlice(arena);
}

fn copperMetrics(
    arena: std.mem.Allocator,
    board: snapshot_mod.Snapshot,
    selection: Selection,
    want_selected: bool,
) std.mem.Allocator.Error!CopperMetrics {
    var out: CopperMetrics = .{};
    var nets = std.StringHashMapUnmanaged(void).empty;
    for (board.segments) |item| if (selected(selection, item.net) == want_selected) {
        out.segments += 1;
        out.length_mm += snapshot_mod.segmentLength(item);
        if (item.net.len > 0) try nets.put(arena, item.net, {});
    };
    for (board.arcs) |item| if (selected(selection, item.net) == want_selected) {
        out.arcs += 1;
        out.length_mm += snapshot_mod.arcLength(item);
        if (item.net.len > 0) try nets.put(arena, item.net, {});
    };
    for (board.vias) |item| if (selected(selection, item.net) == want_selected) {
        out.vias += 1;
        if (item.net.len > 0) try nets.put(arena, item.net, {});
    };
    out.nets = nets.count();
    return out;
}

fn eligibleNets(
    arena: std.mem.Allocator,
    board: snapshot_mod.Snapshot,
    selection: Selection,
) std.mem.Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (selection.names) |name| {
        var pads: usize = 0;
        for (board.footprints) |fp| for (fp.pads) |pad| {
            if (std.ascii.eqlIgnoreCase(pad.net, name)) pads += 1;
        };
        if (pads >= 2 or hasCopper(board, name)) try out.append(arena, name);
    }
    return out.toOwnedSlice(arena);
}

fn hasCopper(board: snapshot_mod.Snapshot, name: []const u8) bool {
    for (board.segments) |item| if (std.ascii.eqlIgnoreCase(item.net, name)) return true;
    for (board.arcs) |item| if (std.ascii.eqlIgnoreCase(item.net, name)) return true;
    for (board.vias) |item| if (std.ascii.eqlIgnoreCase(item.net, name)) return true;
    for (board.zones) |item| if (std.ascii.eqlIgnoreCase(item.net, name)) return true;
    return false;
}

fn fixedGeometryMismatches(
    arena: std.mem.Allocator,
    reference: snapshot_mod.Snapshot,
    candidate: snapshot_mod.Snapshot,
) std.mem.Allocator.Error!usize {
    var by_ref = std.StringHashMapUnmanaged(snapshot_mod.Footprint).empty;
    for (candidate.footprints) |fp| if (fp.reference.len > 0) try by_ref.put(arena, fp.reference, fp);
    var mismatches: usize = 0;
    var matched: usize = 0;
    for (reference.footprints) |want| {
        const got = by_ref.get(want.reference) orelse {
            mismatches += 1;
            continue;
        };
        matched += 1;
        if (!samePose(want, got)) mismatches += 1;
    }
    if (candidate.footprints.len > matched) mismatches += candidate.footprints.len - matched;
    const rb = snapshot_mod.outlineBounds(reference);
    const cb = snapshot_mod.outlineBounds(candidate);
    if (reference.outline.len != candidate.outline.len or !sameBounds(rb, cb)) mismatches += 1;
    return mismatches;
}

fn samePose(a: snapshot_mod.Footprint, b: snapshot_mod.Footprint) bool {
    return std.mem.eql(u8, a.layer, b.layer) and a.pads.len == b.pads.len and
        @abs(a.at.x - b.at.x) <= 1e-6 and @abs(a.at.y - b.at.y) <= 1e-6 and
        @abs(a.at.rotation_deg - b.at.rotation_deg) <= 1e-6;
}

fn sameBounds(a: snapshot_mod.Bounds, b: snapshot_mod.Bounds) bool {
    if (a.valid != b.valid) return false;
    if (!a.valid) return true;
    return @abs(a.min.x - b.min.x) <= 1e-6 and @abs(a.min.y - b.min.y) <= 1e-6 and
        @abs(a.max.x - b.max.x) <= 1e-6 and @abs(a.max.y - b.max.y) <= 1e-6;
}

fn hardRuleViolations(
    board: snapshot_mod.Snapshot,
    project: ?project_mod.ProjectRules,
    selection: Selection,
) usize {
    const rules = if (project) |p| p.design else project_mod.DesignRules{};
    var count: usize = 0;
    for (board.segments) |item| if (selected(selection, item.net)) {
        if (rules.min_track_width > 0 and item.width + 1e-9 < rules.min_track_width) count += 1;
        if (!validCopperLayer(board, item.layer)) count += 1;
    };
    for (board.arcs) |item| if (selected(selection, item.net)) {
        if (rules.min_track_width > 0 and item.width + 1e-9 < rules.min_track_width) count += 1;
        if (!validCopperLayer(board, item.layer)) count += 1;
    };
    for (board.vias) |item| if (selected(selection, item.net)) {
        if (rules.min_via_diameter > 0 and item.size + 1e-9 < rules.min_via_diameter) count += 1;
        if (rules.min_via_drill > 0 and item.drill + 1e-9 < rules.min_via_drill) count += 1;
    };
    return count;
}

fn validCopperLayer(board: snapshot_mod.Snapshot, name: []const u8) bool {
    for (board.layers) |layer| if (layer.copper and std.mem.eql(u8, layer.name, name)) return true;
    return false;
}

test "virtual erasure filters copper without mutating the source" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const nets = [_]snapshot_mod.Net{ .{ .name = "A" }, .{ .name = "B" } };
    const segments = [_]snapshot_mod.Segment{
        .{ .start = .{}, .end = .{ .x = 2 }, .net = "A", .layer = "F.Cu", .width = 0.2 },
        .{ .start = .{}, .end = .{ .x = 3 }, .net = "B", .layer = "F.Cu", .width = 0.2 },
    };
    const board = snapshot_mod.Snapshot{ .nets = &nets, .segments = &segments };
    const erased = try virtualErase(arena, board, &.{"A"});
    try std.testing.expectEqual(@as(usize, 2), board.segments.len);
    try std.testing.expectEqual(@as(usize, 1), erased.seed.segments.len);
    try std.testing.expectEqualStrings("B", erased.seed.segments[0].net);
    try std.testing.expectApproxEqAbs(@as(f64, 2), erased.removed.length_mm, 1e-9);
}

test "candidate scoring makes missing copper dominate route burden" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const nets = [_]snapshot_mod.Net{.{ .name = "A" }};
    const pads = [_]snapshot_mod.Pad{ .{ .net = "A" }, .{ .net = "A" } };
    const fps = [_]snapshot_mod.Footprint{.{ .reference = "U1", .layer = "F.Cu", .pads = &pads }};
    const layers = [_]snapshot_mod.Layer{.{ .name = "F.Cu", .copper = true }};
    const segments = [_]snapshot_mod.Segment{.{
        .start = .{},
        .end = .{ .x = 2 },
        .net = "A",
        .layer = "F.Cu",
        .width = 0.2,
    }};
    const reference = snapshot_mod.Snapshot{
        .nets = &nets,
        .footprints = &fps,
        .layers = &layers,
        .segments = &segments,
    };
    const missing = try scoreCandidate(arena, reference, .{
        .nets = &nets,
        .footprints = &fps,
        .layers = &layers,
    }, null, &.{"A"});
    const same = try scoreCandidate(arena, reference, reference, null, &.{"A"});
    try std.testing.expectEqual(@as(usize, 1), missing.missing_nets.len);
    try std.testing.expect(missing.objective > same.objective + 1e8);
}
