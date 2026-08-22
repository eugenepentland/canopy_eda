//! Pure importer core for `import-kicad-layout`: turns a parsed KiCad board
//! snapshot plus the flattened design view (instances, nets, board rules) into
//! the poses, copper, and outline of a netlisp layout sidecar, with a full
//! accounting report of everything matched, renamed, tessellated, dropped, or
//! preserved (including copper zones). Arena-based and side-effect free — the
//! CLI seam (`import_layout_command.zig`) owns all file I/O; the board is
//! never written.

const std = @import("std");
const snapshot = @import("snapshot.zig");
const net_aliases = @import("net_aliases.zig");
const optimizer = @import("../placement/optimizer.zig");
const outline_mod = @import("../placement/outline.zig");
const export_kicad = @import("../export_kicad.zig");
const numeric = @import("../numeric.zig");
const board_layers = @import("../board_layers.zig");

/// The only failure mode of the pure importer: arena exhaustion.
pub const Error = std.mem.Allocator.Error;

/// Endpoint tolerance (mm) when chaining Edge.Cuts pieces end-to-start.
const outline_join_tol_mm: f64 = 1e-3;
/// A pour-backed rail with less imported track than this is `pour_fed`.
const pour_fed_threshold_mm: f64 = 5.0;
/// Arc tessellation bounds: chords per arc stay inside this window.
const arc_min_segments: usize = 4;
const arc_max_segments: usize = 64;

/// Caller-assembled inputs: the parsed board plus the flattened design view.
pub const Inputs = struct {
    /// Normalized physical board (opened read-only by the caller).
    board: snapshot.Snapshot,
    /// Flattened design instances (uuid + ref-des + origin_key).
    instances: []const export_kicad.FlatInstance,
    /// Flattened design nets; pins give the pad→net view for renames.
    nets: []const export_kicad.FlatNet,
    /// Board rules supplying the copper-layer → signal-index map.
    rules: optimizer.BoardRules,
};

/// Import tuning knobs.
pub const Options = struct {
    /// Maximum chord deviation (mm) when tessellating copper and outline arcs.
    chord_tol_mm: f64 = 0.05,
};

/// One imported part pose in the netlisp frame (mm, y-down, model rotation).
pub const Pose = struct {
    ref: []const u8,
    origin: []const u8,
    x: f64 = 0,
    y: f64 = 0,
    rot: f64 = 0,
    side: optimizer.Side = .top,
};

/// One imported straight copper segment (sidecar shape: signal-layer index).
pub const Track = struct {
    x1: f64 = 0,
    y1: f64 = 0,
    x2: f64 = 0,
    y2: f64 = 0,
    layer: u8 = 0,
    width: f64 = 0,
    net: []const u8 = "",
};

/// One imported through via.
pub const ViaOut = struct {
    x: f64 = 0,
    y: f64 = 0,
    dia: f64 = 0,
    drill: f64 = 0,
    net: []const u8 = "",
};

/// One imported zone polygon. Authored boundaries and KiCad-computed fills
/// are separate flat records so consumers can prefer exact fills while still
/// falling back to the boundary when a board was saved unfilled. Keepouts are
/// retained as context but are explicitly nonconductive (`keepout = true`).
const ZoneOut = struct {
    net: []const u8 = "",
    layer: []const u8 = "",
    poly: []const [2]f64 = &.{},
    filled: bool = false,
    keepout: bool = false,
    /// KiCad's `(priority N)` — preserved so an imported board's zone-overlap
    /// resolution survives the round-trip (`pour.outranks`).
    priority: i64 = 0,
};

/// The imported board outline: a closed polygon vertex list (first vertex not
/// repeated), or the items' bounding-box rectangle when `fallback` is set.
pub const Outline = struct {
    pts: []const [2]f64 = &.{},
    fallback: bool = false,
};

/// Footprint↔instance matching outcome (counts by identity path + both
/// directions' leftovers — nothing is silently dropped).
pub const MatchReport = struct {
    by_uuid: usize = 0,
    by_ref: usize = 0,
    unmatched_board: []const []const u8 = &.{},
    unmatched_design: []const []const u8 = &.{},
};

/// One safe alias-group fold: stale copper-only spellings onto the canonical.
pub const AliasFold = struct {
    canonical: []const u8 = "",
    aliases: []const []const u8 = &.{},
};

/// The `net_aliases` pre-pass outcome (stale copper-only names folded onto
/// their pad-carrying canonical name before any pad-set mapping).
pub const AliasReport = struct {
    safe_groups: usize = 0,
    ambiguous_groups: usize = 0,
    folds: []const AliasFold = &.{},
};

/// One board→design net rename discovered by the pad-set vote.
pub const NetRename = struct {
    board: []const u8 = "",
    design: []const u8 = "",
};

/// A board net whose shared pads split across several design nets.
pub const AmbiguousNet = struct {
    board: []const u8 = "",
    candidates: []const []const u8 = &.{},
};

/// Pad-set net mapping summary: identical/renamed tallies plus every rename
/// pair, ambiguous vote, and board net no shared pad could place.
pub const NetMapReport = struct {
    identical: usize = 0,
    renamed: usize = 0,
    renames: []const NetRename = &.{},
    ambiguous: []const AmbiguousNet = &.{},
    unmatched: []const []const u8 = &.{},
};

/// Per-copper-layer imported totals (layer named in KiCad spelling).
pub const LayerCopper = struct {
    layer: []const u8 = "",
    tracks: usize = 0,
    mm: f64 = 0,
};

/// One track/arc dropped because its layer has no signal index.
pub const DroppedTrack = struct {
    layer: []const u8 = "",
    net: []const u8 = "",
    length_mm: f64 = 0,
};

/// Arc tessellation totals: arcs seen, chords emitted, worst deviation.
pub const ArcReport = struct {
    count: usize = 0,
    segments: usize = 0,
    max_chord_error_mm: f64 = 0,
};

/// Imported copper totals plus everything that changed shape on the way in.
pub const CopperReport = struct {
    tracks: usize = 0,
    vias: usize = 0,
    non_through_vias: usize = 0,
    per_layer: []const LayerCopper = &.{},
    arcs: ArcReport = .{},
    dropped: []const DroppedTrack = &.{},
};

/// One authored zone inventoried in the fidelity report.
pub const ZoneInfo = struct {
    net: []const u8 = "",
    layers: []const []const u8 = &.{},
    keepout: bool = false,
};

/// Zone inventory plus the rails whose connectivity depends on a pour.
pub const ZoneReport = struct {
    zones: []const ZoneInfo = &.{},
    pour_fed: []const []const u8 = &.{},
};

/// Outline result summary: polygon vertex count and the bbox-fallback flag.
pub const OutlineReport = struct {
    points: usize = 0,
    fallback: bool = false,
};

/// Per-net imported copper (design-mapped name): track mm + via count.
pub const NetCopper = struct {
    net: []const u8 = "",
    mm: f64 = 0,
    vias: usize = 0,
};

/// The full import accounting, stable-ordered for the JSON report.
pub const Report = struct {
    match: MatchReport = .{},
    aliases: AliasReport = .{},
    net_map: NetMapReport = .{},
    copper: CopperReport = .{},
    zones: ZoneReport = .{},
    outline: OutlineReport = .{},
    per_net: []const NetCopper = &.{},
};

/// Everything `build` produces: sidecar-ready poses/copper/outline + report.
pub const Imported = struct {
    poses: []const Pose = &.{},
    tracks: []const Track = &.{},
    vias: []const ViaOut = &.{},
    zones: []const ZoneOut = &.{},
    outline: Outline = .{},
    report: Report = .{},
};

/// Run the pure import: alias-fold stale copper names, match footprints to
/// design instances, convert poses, map nets by pad-set vote, import copper
/// (arcs tessellated, unmapped layers dropped), preserve zone boundaries and
/// fills, chain the outline, and report pour-fed rails. Every slice in the
/// result lives on `arena`.
pub fn build(arena: std.mem.Allocator, inputs: Inputs, opts: Options) Error!Imported {
    const analysis = try net_aliases.analyze(arena, inputs.board);
    const board = try net_aliases.canonicalize(arena, inputs.board, analysis);
    const matches = try matchFootprints(arena, board, inputs.instances);
    const votes = try voteNets(arena, board, matches, inputs);
    var st = CopperState{ .resolve = .{
        .layer_index = try layerIndexMap(arena, inputs.rules),
        .net_map = votes.map,
    } };
    try importSegments(arena, board, &st);
    try importArcs(arena, board, &st, opts.chord_tol_mm);
    try importVias(arena, board, &st);
    const outline = try chainOutline(arena, board.outline, opts.chord_tol_mm);
    const zones = try importZones(arena, board, &st);
    return .{
        .poses = try posesOf(arena, board, matches, inputs.instances),
        .tracks = st.out.tracks.items,
        .vias = st.out.vias.items,
        .zones = zones.imported,
        .outline = outline,
        .report = .{
            .match = matches.report,
            .aliases = try aliasReport(arena, analysis),
            .net_map = votes.report,
            .copper = .{
                .tracks = st.out.tracks.items.len,
                .vias = st.out.vias.items.len,
                .non_through_vias = st.non_through,
                .per_layer = try layerCopperOf(arena, st.tally.per_layer.items),
                .arcs = st.arcs,
                .dropped = st.out.dropped.items,
            },
            .zones = zones.report,
            .outline = .{ .points = outline.pts.len, .fallback = outline.fallback },
            .per_net = try netCopperOf(arena, st.tally.per_net.items),
        },
    };
}

/// Recover a netlisp-model rotation from KiCad's stored `(at … angle)` for a
/// footprint on `side`. Twin of the private `kicadRotToNetlisp` in
/// `src/serve/sync.zig` (the sync bake's self-inverse in this algebra) — keep
/// the two formulas in lockstep.
fn kicadRotToNetlisp(kicad_rot: f64, side: optimizer.Side) f64 {
    const back_half_turn: f64 = if (side == .bottom) 180.0 else 0.0;
    return @mod(360.0 - kicad_rot + back_half_turn, 360.0);
}

// ── Footprint ↔ instance matching ───────────────────────────────────────────

const MatchPair = struct { fp: usize, inst: usize };

const MatchState = struct {
    pairs: []const MatchPair,
    report: MatchReport,
};

/// Match board footprints to design instances: `canopy_uuid` first (the
/// renumber-proof sync stamp), then exact ref-des; leftovers on either side
/// land in the report.
fn matchFootprints(
    arena: std.mem.Allocator,
    board: snapshot.Snapshot,
    instances: []const export_kicad.FlatInstance,
) Error!MatchState {
    var by_uuid = std.StringHashMapUnmanaged(usize).empty;
    var by_ref = std.StringHashMapUnmanaged(usize).empty;
    for (instances, 0..) |inst, i| {
        if (inst.uuid.len > 0) try by_uuid.put(arena, inst.uuid, i);
        if (inst.ref_des.len > 0) try by_ref.put(arena, inst.ref_des, i);
    }
    const used = try arena.alloc(bool, instances.len);
    @memset(used, false);
    var pairs: std.ArrayList(MatchPair) = .empty;
    var unmatched_board: std.ArrayList([]const u8) = .empty;
    var report = MatchReport{};
    for (board.footprints, 0..) |fp, fp_i| {
        const uuid_hit = if (fp.canopy.uuid.len > 0) by_uuid.get(fp.canopy.uuid) else null;
        const inst_i = uuid_hit orelse by_ref.get(fp.reference) orelse {
            try unmatched_board.append(arena, footprintLabel(fp));
            continue;
        };
        if (uuid_hit != null) report.by_uuid += 1 else report.by_ref += 1;
        used[inst_i] = true;
        try pairs.append(arena, .{ .fp = fp_i, .inst = inst_i });
    }
    var unmatched_design: std.ArrayList([]const u8) = .empty;
    for (instances, used) |inst, was_used| {
        if (!was_used) try unmatched_design.append(arena, inst.ref_des);
    }
    report.unmatched_board = unmatched_board.items;
    report.unmatched_design = unmatched_design.items;
    return .{ .pairs = pairs.items, .report = report };
}

/// The name a report lists an unmatched board footprint under.
fn footprintLabel(fp: snapshot.Footprint) []const u8 {
    return if (fp.reference.len > 0) fp.reference else fp.lib_id;
}

/// Convert every matched footprint pose into the netlisp frame: positions copy
/// 1:1 (same mm y-down frame), rotation through the sync bake inverse, side
/// from the `B.Cu` layer, `origin` from the instance's renumber-stable key.
fn posesOf(
    arena: std.mem.Allocator,
    board: snapshot.Snapshot,
    matches: MatchState,
    instances: []const export_kicad.FlatInstance,
) Error![]const Pose {
    const out = try arena.alloc(Pose, matches.pairs.len);
    for (matches.pairs, out) |pair, *pose| {
        const fp = board.footprints[pair.fp];
        const inst = instances[pair.inst];
        const side: optimizer.Side = if (std.mem.eql(u8, fp.layer, board_layers.b_cu)) .bottom else .top;
        pose.* = .{
            .ref = inst.ref_des,
            .origin = inst.origin_key,
            .x = fp.at.x,
            .y = fp.at.y,
            .rot = kicadRotToNetlisp(fp.at.rotation_deg, side),
            .side = side,
        };
    }
    return out;
}

// ── Net rename map (pad-set vote) ───────────────────────────────────────────

/// Running tally keyed by name — small lists, scanned linearly so first-seen
/// order is preserved for deterministic reports.
const NetTally = struct { name: []const u8, mm: f64 = 0, count: usize = 0 };

fn tallyAdd(
    arena: std.mem.Allocator,
    list: *std.ArrayList(NetTally),
    name: []const u8,
    mm: f64,
    count: usize,
) Error!void {
    for (list.items) |*t| {
        if (std.mem.eql(u8, t.name, name)) {
            t.mm += mm;
            t.count += count;
            return;
        }
    }
    try list.append(arena, .{ .name = name, .mm = mm, .count = count });
}

const VoteState = struct {
    /// board net → design net, present only for unambiguous mappings.
    map: std.StringHashMapUnmanaged([]const u8),
    report: NetMapReport,
};

const BoardVote = struct { board: []const u8, candidates: std.ArrayList(NetTally) };

/// Vote each board net onto a design net over the pads the matched footprints
/// share, then classify: identical, renamed (one candidate), ambiguous
/// (several candidates — board spelling kept), or unmatched (no shared pad).
fn voteNets(
    arena: std.mem.Allocator,
    board: snapshot.Snapshot,
    matches: MatchState,
    inputs: Inputs,
) Error!VoteState {
    const pad_net = try designPadNets(arena, inputs.nets);
    var votes: std.ArrayList(BoardVote) = .empty;
    for (matches.pairs) |pair| {
        const fp = board.footprints[pair.fp];
        const inst = inputs.instances[pair.inst];
        try voteFootprintPads(arena, &votes, fp, inst.ref_des, pad_net);
    }
    return classifyVotes(arena, board, votes.items);
}

/// Add one matched footprint's pad evidence to the per-board-net vote lists.
fn voteFootprintPads(
    arena: std.mem.Allocator,
    votes: *std.ArrayList(BoardVote),
    fp: snapshot.Footprint,
    ref_des: []const u8,
    pad_net: std.StringHashMapUnmanaged([]const u8),
) Error!void {
    for (fp.pads) |pad| {
        if (pad.net.len == 0) continue;
        const key = try std.fmt.allocPrint(arena, "{s}\x00{s}", .{ ref_des, pad.number });
        const design_net = pad_net.get(key) orelse continue;
        const entry = try findOrAddVote(arena, votes, pad.net);
        try tallyAdd(arena, &entry.candidates, design_net, 0, 1);
    }
}

fn findOrAddVote(
    arena: std.mem.Allocator,
    votes: *std.ArrayList(BoardVote),
    board_net: []const u8,
) Error!*BoardVote {
    for (votes.items) |*v| {
        if (std.mem.eql(u8, v.board, board_net)) return v;
    }
    try votes.append(arena, .{ .board = board_net, .candidates = .empty });
    return &votes.items[votes.items.len - 1];
}

/// The design-side pad→net view: `"ref\x00pin"` → flattened net name.
fn designPadNets(
    arena: std.mem.Allocator,
    nets: []const export_kicad.FlatNet,
) Error!std.StringHashMapUnmanaged([]const u8) {
    var out = std.StringHashMapUnmanaged([]const u8).empty;
    for (nets) |net| {
        for (net.pins) |pin| {
            const key = try std.fmt.allocPrint(arena, "{s}\x00{s}", .{ pin.ref_des, pin.pin });
            try out.put(arena, key, net.name);
        }
    }
    return out;
}

/// Turn the raw vote lists into the mapping table + `NetMapReport`.
fn classifyVotes(
    arena: std.mem.Allocator,
    board: snapshot.Snapshot,
    votes: []const BoardVote,
) Error!VoteState {
    var map = std.StringHashMapUnmanaged([]const u8).empty;
    var report = NetMapReport{};
    var renames: std.ArrayList(NetRename) = .empty;
    var ambiguous: std.ArrayList(AmbiguousNet) = .empty;
    for (votes) |vote| {
        if (vote.candidates.items.len == 1) {
            const design = vote.candidates.items[0].name;
            try map.put(arena, vote.board, design);
            if (std.mem.eql(u8, vote.board, design)) {
                report.identical += 1;
            } else {
                report.renamed += 1;
                try renames.append(arena, .{ .board = vote.board, .design = design });
            }
        } else {
            try ambiguous.append(arena, .{
                .board = vote.board,
                .candidates = try candidateNames(arena, vote.candidates.items),
            });
        }
    }
    report.renames = renames.items;
    report.ambiguous = ambiguous.items;
    report.unmatched = try unvotedNets(arena, board, votes);
    return .{ .map = map, .report = report };
}

/// Candidate design nets of an ambiguous vote, strongest first.
fn candidateNames(arena: std.mem.Allocator, tallies: []const NetTally) Error![]const []const u8 {
    const sorted = try arena.dupe(NetTally, tallies);
    std.mem.sort(NetTally, sorted, {}, tallyMoreVotes);
    const names = try arena.alloc([]const u8, sorted.len);
    for (sorted, names) |t, *n| n.* = t.name;
    return names;
}

fn tallyMoreVotes(_: void, a: NetTally, b: NetTally) bool {
    if (a.count != b.count) return a.count > b.count;
    return std.mem.lessThan(u8, a.name, b.name);
}

/// Every board net no shared pad voted on — spelling kept, reported.
fn unvotedNets(
    arena: std.mem.Allocator,
    board: snapshot.Snapshot,
    votes: []const BoardVote,
) Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (board.nets) |net| {
        var voted = false;
        for (votes) |vote| {
            if (std.mem.eql(u8, vote.board, net.name)) {
                voted = true;
                break;
            }
        }
        if (!voted) try out.append(arena, net.name);
    }
    return out.items;
}

/// The safe alias-group folds of the pre-pass, in group order.
fn aliasReport(arena: std.mem.Allocator, analysis: net_aliases.Analysis) Error!AliasReport {
    var folds: std.ArrayList(AliasFold) = .empty;
    for (analysis.groups) |group| {
        if (!group.safe) continue;
        var aliases: std.ArrayList([]const u8) = .empty;
        for (group.members) |member| {
            if (std.mem.eql(u8, member.name, group.canonical)) continue;
            try aliases.append(arena, member.name);
        }
        try folds.append(arena, .{ .canonical = group.canonical, .aliases = aliases.items });
    }
    return .{
        .safe_groups = analysis.safe_groups,
        .ambiguous_groups = analysis.ambiguous_groups,
        .folds = folds.items,
    };
}

// ── Copper import ───────────────────────────────────────────────────────────

/// Name-resolution tables the copper walk consults for every item.
const NetResolve = struct {
    /// KiCad copper-layer name → signal-layer index (from the board rules).
    layer_index: std.StringHashMapUnmanaged(u8),
    /// Board net → design net (unambiguous pad-set mappings only).
    net_map: std.StringHashMapUnmanaged([]const u8),
};

/// The retained copper being accumulated.
const CopperOut = struct {
    tracks: std.ArrayList(Track) = .empty,
    vias: std.ArrayList(ViaOut) = .empty,
    dropped: std.ArrayList(DroppedTrack) = .empty,
};

/// Per-layer + per-net running totals (mm + item counts).
const CopperTally = struct {
    per_layer: std.ArrayList(NetTally) = .empty,
    per_net: std.ArrayList(NetTally) = .empty,
};

/// Everything the copper walk reads and writes, threaded through the helpers.
const CopperState = struct {
    resolve: NetResolve,
    out: CopperOut = .{},
    tally: CopperTally = .{},
    arcs: ArcReport = .{},
    non_through: usize = 0,
};

/// A board net's imported spelling: the design mapping when one exists, else
/// the (already alias-canonicalized) board spelling.
fn mappedNet(st: *const CopperState, name: []const u8) []const u8 {
    return st.resolve.net_map.get(name) orelse name;
}

/// KiCad-layer-name → signal-index map for the design's copper stack, keyed
/// on arena-owned copies of "F.Cu"/"B.Cu"/"In<k>.Cu".
fn layerIndexMap(
    arena: std.mem.Allocator,
    rules: optimizer.BoardRules,
) Error!std.StringHashMapUnmanaged(u8) {
    var out = std.StringHashMapUnmanaged(u8).empty;
    var buf: [8]u8 = undefined;
    var sig: u8 = 0;
    while (sig < rules.signalLayerCount()) : (sig += 1) {
        const name = rules.signalLayerName(sig, &buf);
        try out.put(arena, try arena.dupe(u8, name), sig);
    }
    return out;
}

/// Append one retained straight track and roll its length into the tallies.
fn addTrack(
    arena: std.mem.Allocator,
    st: *CopperState,
    track: Track,
    layer_name: []const u8,
) Error!void {
    const mm = std.math.hypot(track.x2 - track.x1, track.y2 - track.y1);
    try st.out.tracks.append(arena, track);
    try tallyAdd(arena, &st.tally.per_layer, layer_name, mm, 1);
    try tallyAdd(arena, &st.tally.per_net, track.net, mm, 0);
}

/// Record a track/arc whose layer has no signal index — reported, not kept.
fn dropTrack(
    arena: std.mem.Allocator,
    st: *CopperState,
    layer: []const u8,
    net: []const u8,
    mm: f64,
) Error!void {
    try st.out.dropped.append(arena, .{ .layer = layer, .net = net, .length_mm = mm });
}

/// Import every straight segment whose layer maps into the signal stack.
fn importSegments(arena: std.mem.Allocator, board: snapshot.Snapshot, st: *CopperState) Error!void {
    for (board.segments) |seg| {
        const net = mappedNet(st, seg.net);
        const sig = st.resolve.layer_index.get(seg.layer) orelse {
            try dropTrack(arena, st, seg.layer, net, snapshot.segmentLength(seg));
            continue;
        };
        try addTrack(arena, st, .{
            .x1 = seg.start.x,
            .y1 = seg.start.y,
            .x2 = seg.end.x,
            .y2 = seg.end.y,
            .layer = sig,
            .width = seg.width,
            .net = net,
        }, seg.layer);
    }
}

/// Import every copper arc as a tessellated polyline of straight chords.
fn importArcs(
    arena: std.mem.Allocator,
    board: snapshot.Snapshot,
    st: *CopperState,
    tol_mm: f64,
) Error!void {
    for (board.arcs) |arc| {
        const net = mappedNet(st, arc.net);
        const sig = st.resolve.layer_index.get(arc.layer) orelse {
            try dropTrack(arena, st, arc.layer, net, snapshot.arcLength(arc));
            continue;
        };
        const pts = try tessellateArc(arena, .{ arc.start, arc.mid, arc.end }, tol_mm, &st.arcs);
        st.arcs.count += 1;
        var i: usize = 1;
        while (i < pts.len) : (i += 1) {
            st.arcs.segments += 1;
            try addTrack(arena, st, .{
                .x1 = pts[i - 1].x,
                .y1 = pts[i - 1].y,
                .x2 = pts[i].x,
                .y2 = pts[i].y,
                .layer = sig,
                .width = arc.width,
                .net = net,
            }, arc.layer);
        }
    }
}

/// Circle geometry recovered from an arc's three defining points.
const ArcGeometry = struct {
    cx: f64,
    cy: f64,
    radius: f64,
    start_angle: f64,
    /// Signed sweep (radians): positive = CCW toward the end point.
    sweep: f64,
};

/// The circumcircle + signed sweep of a start/mid/end arc, or null when the
/// three points are (near-)collinear and the arc degenerates to a polyline.
fn arcGeometry(pts: [3]snapshot.Point) ?ArcGeometry {
    const a = pts[0];
    const b = pts[1];
    const c = pts[2];
    const d = 2 * (a.x * (b.y - c.y) + b.x * (c.y - a.y) + c.x * (a.y - b.y));
    if (@abs(d) < 1e-12) return null;
    const a2 = a.x * a.x + a.y * a.y;
    const b2 = b.x * b.x + b.y * b.y;
    const c2 = c.x * c.x + c.y * c.y;
    const ux = (a2 * (b.y - c.y) + b2 * (c.y - a.y) + c2 * (a.y - b.y)) / d;
    const uy = (a2 * (c.x - b.x) + b2 * (a.x - c.x) + c2 * (b.x - a.x)) / d;
    const radius = std.math.hypot(a.x - ux, a.y - uy);
    const tau = 2 * std.math.pi;
    const start_angle = std.math.atan2(a.y - uy, a.x - ux);
    const mid_angle = std.math.atan2(b.y - uy, b.x - ux);
    const end_angle = std.math.atan2(c.y - uy, c.x - ux);
    const ccw_end = @mod(end_angle - start_angle + tau, tau);
    const ccw_mid = @mod(mid_angle - start_angle + tau, tau);
    const ccw = ccw_mid <= ccw_end + 1e-9;
    const sweep = if (ccw) ccw_end else -(tau - ccw_end);
    return .{ .cx = ux, .cy = uy, .radius = radius, .start_angle = start_angle, .sweep = sweep };
}

/// Tessellate a start/mid/end arc into chords whose sagitta stays within
/// `tol_mm` (chord count clamped to the per-arc window), rolling the worst
/// actual deviation into `arcs.max_chord_error_mm`. Degenerate (collinear)
/// arcs come back as the start→mid→end polyline with zero deviation.
fn tessellateArc(
    arena: std.mem.Allocator,
    pts: [3]snapshot.Point,
    tol_mm: f64,
    arcs: *ArcReport,
) Error![]const snapshot.Point {
    const geom = arcGeometry(pts) orelse return try arena.dupe(snapshot.Point, &pts);
    const n = chordCount(geom, tol_mm);
    const err = geom.radius * (1 - @cos(@abs(geom.sweep) / (2 * @as(f64, @floatFromInt(n)))));
    arcs.max_chord_error_mm = @max(arcs.max_chord_error_mm, err);
    const out = try arena.alloc(snapshot.Point, n + 1);
    out[0] = pts[0];
    out[n] = pts[2];
    var i: usize = 1;
    while (i < n) : (i += 1) {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n));
        const angle = geom.start_angle + geom.sweep * t;
        out[i] = .{ .x = geom.cx + geom.radius * @cos(angle), .y = geom.cy + geom.radius * @sin(angle) };
    }
    return out;
}

/// Chords needed so each sagitta stays within `tol_mm`, clamped to the
/// per-arc window (`2·acos(1 − tol/r)` step angle).
fn chordCount(geom: ArcGeometry, tol_mm: f64) usize {
    const ratio = std.math.clamp(1 - tol_mm / geom.radius, -1.0, 1.0);
    const step = 2 * std.math.acos(ratio);
    const raw = @ceil(@abs(geom.sweep) / @max(step, 1e-9));
    const n = numeric.checkedInt(usize, raw) orelse arc_max_segments;
    return std.math.clamp(n, arc_min_segments, arc_max_segments);
}

/// Import every via as a through via, counting spans that are not the plain
/// outer-to-outer pair (they flatten to through vias — a reported delta).
fn importVias(arena: std.mem.Allocator, board: snapshot.Snapshot, st: *CopperState) Error!void {
    for (board.vias) |via| {
        const net = mappedNet(st, via.net);
        if (!isOuterSpan(via.layers)) st.non_through += 1;
        try st.out.vias.append(arena, .{
            .x = via.at.x,
            .y = via.at.y,
            .dia = via.size,
            .drill = via.drill,
            .net = net,
        });
        try tallyAdd(arena, &st.tally.per_net, net, 0, 1);
    }
}

/// True for the plain outer-to-outer (F.Cu↔B.Cu) via span, in either order.
/// A missing span or the `*.Cu` wildcard also reads as through.
fn isOuterSpan(layers: []const []const u8) bool {
    if (layers.len == 0) return true;
    if (layers.len == 1) return std.mem.eql(u8, layers[0], "*.Cu");
    if (layers.len != 2) return false;
    const fb = std.mem.eql(u8, layers[0], board_layers.f_cu) and std.mem.eql(u8, layers[1], board_layers.b_cu);
    const bf = std.mem.eql(u8, layers[0], board_layers.b_cu) and std.mem.eql(u8, layers[1], board_layers.f_cu);
    return fb or bf;
}

/// Freeze the per-layer tallies into the report's `LayerCopper` rows.
fn layerCopperOf(arena: std.mem.Allocator, tallies: []const NetTally) Error![]const LayerCopper {
    const out = try arena.alloc(LayerCopper, tallies.len);
    for (tallies, out) |t, *row| row.* = .{ .layer = t.name, .tracks = t.count, .mm = t.mm };
    return out;
}

/// Freeze the per-net tallies into the report's `NetCopper` rows.
fn netCopperOf(arena: std.mem.Allocator, tallies: []const NetTally) Error![]const NetCopper {
    const out = try arena.alloc(NetCopper, tallies.len);
    for (tallies, out) |t, *row| row.* = .{ .net = t.name, .mm = t.mm, .vias = t.count };
    return out;
}

// ── Outline chaining ────────────────────────────────────────────────────────

const OutlinePiece = struct { pts: []const snapshot.Point, used: bool = false };

/// Chain the board's Edge.Cuts pieces (lines, tessellated arcs, rects, polys)
/// end-to-start into ONE closed polygon. When the pieces cannot chain closed
/// (gaps, leftovers, self-intersection) the result falls back to the items'
/// bounding-box rectangle with the `fallback` flag set.
fn chainOutline(
    arena: std.mem.Allocator,
    items: []const snapshot.OutlineGraphic,
    tol_mm: f64,
) Error!Outline {
    const pieces = try outlinePieces(arena, items, tol_mm);
    if (pieces.len == 0) return .{ .fallback = true };
    if (try chainPieces(arena, pieces)) |poly| {
        if (outline_mod.valid(poly)) return .{ .pts = poly };
    }
    return outlineBboxFallback(arena, items);
}

/// Expand each Edge.Cuts item into an open polyline piece (closed rect/poly
/// items repeat their first vertex so they chain onto themselves).
fn outlinePieces(
    arena: std.mem.Allocator,
    items: []const snapshot.OutlineGraphic,
    tol_mm: f64,
) Error![]OutlinePiece {
    var out: std.ArrayList(OutlinePiece) = .empty;
    var scratch = ArcReport{};
    for (items) |item| {
        switch (item.kind) {
            .line => if (item.points.len >= 2) {
                try out.append(arena, .{ .pts = item.points[0..2] });
            },
            .arc => if (item.points.len >= 3) {
                const three = [3]snapshot.Point{ item.points[0], item.points[1], item.points[2] };
                try out.append(arena, .{ .pts = try tessellateArc(arena, three, tol_mm, &scratch) });
            },
            .rect => if (item.points.len >= 2) {
                try out.append(arena, .{ .pts = try rectLoop(arena, item.points[0], item.points[1]) });
            },
            .polygon => if (item.points.len >= 3) {
                try out.append(arena, .{ .pts = try closedLoop(arena, item.points) });
            },
        }
    }
    return out.items;
}

/// A rect's corner loop (closed: first corner repeated).
fn rectLoop(arena: std.mem.Allocator, s: snapshot.Point, e: snapshot.Point) Error![]snapshot.Point {
    const out = try arena.alloc(snapshot.Point, 5);
    out[0] = s;
    out[1] = .{ .x = e.x, .y = s.y };
    out[2] = e;
    out[3] = .{ .x = s.x, .y = e.y };
    out[4] = s;
    return out;
}

/// A polygon's vertex list with the first vertex repeated at the end.
fn closedLoop(arena: std.mem.Allocator, pts: []const snapshot.Point) Error![]snapshot.Point {
    const out = try arena.alloc(snapshot.Point, pts.len + 1);
    @memcpy(out[0..pts.len], pts);
    out[pts.len] = pts[0];
    return out;
}

/// Greedy end-to-start chain over the pieces; null unless every piece is
/// consumed and the walk returns to its start within the join tolerance.
fn chainPieces(arena: std.mem.Allocator, pieces: []OutlinePiece) Error!?[]const [2]f64 {
    var chain: std.ArrayList(snapshot.Point) = .empty;
    try chain.appendSlice(arena, pieces[0].pts);
    pieces[0].used = true;
    var remaining = pieces.len - 1;
    while (remaining > 0) {
        if (!(try chainNextPiece(arena, &chain, pieces))) break;
        remaining -= 1;
    }
    if (remaining > 0) return null;
    const first = chain.items[0];
    const last = chain.items[chain.items.len - 1];
    if (!nearPoint(first, last)) return null;
    if (chain.items.len < 4) return null;
    const poly = try arena.alloc([2]f64, chain.items.len - 1);
    for (chain.items[0..poly.len], poly) |p, *v| v.* = .{ p.x, p.y };
    return poly;
}

/// Attach one more unused piece onto the chain's tail (either orientation).
fn chainNextPiece(
    arena: std.mem.Allocator,
    chain: *std.ArrayList(snapshot.Point),
    pieces: []OutlinePiece,
) Error!bool {
    const tail = chain.items[chain.items.len - 1];
    for (pieces) |*piece| {
        if (piece.used) continue;
        const pts = piece.pts;
        if (nearPoint(tail, pts[0])) {
            try chain.appendSlice(arena, pts[1..]);
            piece.used = true;
            return true;
        }
        if (nearPoint(tail, pts[pts.len - 1])) {
            try appendReversed(arena, chain, pts);
            piece.used = true;
            return true;
        }
    }
    return false;
}

/// Append `pts` tail-to-head onto the chain, skipping the shared joint.
fn appendReversed(
    arena: std.mem.Allocator,
    chain: *std.ArrayList(snapshot.Point),
    pts: []const snapshot.Point,
) Error!void {
    var i = pts.len - 1;
    while (i > 0) : (i -= 1) try chain.append(arena, pts[i - 1]);
}

fn nearPoint(a: snapshot.Point, b: snapshot.Point) bool {
    return @abs(a.x - b.x) <= outline_join_tol_mm and @abs(a.y - b.y) <= outline_join_tol_mm;
}

/// The bounding-box rectangle of every Edge.Cuts point — the flagged
/// fallback when chaining fails. Degenerate bounds yield an empty outline.
fn outlineBboxFallback(
    arena: std.mem.Allocator,
    items: []const snapshot.OutlineGraphic,
) Error!Outline {
    const bounds = snapshot.outlineBounds(.{ .outline = items });
    if (!bounds.valid or bounds.width() <= 0 or bounds.height() <= 0) {
        return .{ .fallback = true };
    }
    const poly = try arena.alloc([2]f64, 4);
    poly[0] = .{ bounds.min.x, bounds.min.y };
    poly[1] = .{ bounds.max.x, bounds.min.y };
    poly[2] = .{ bounds.max.x, bounds.max.y };
    poly[3] = .{ bounds.min.x, bounds.max.y };
    return .{ .pts = poly, .fallback = true };
}

// ── Zones ───────────────────────────────────────────────────────────────────

const ImportedZones = struct {
    imported: []const ZoneOut,
    report: ZoneReport,
};

/// Preserve every authored boundary (once per named layer) and every exact
/// KiCad-computed fill. The flat records are useful both for rendering and for
/// net highlighting; a fill-free zone still has its boundary as a fallback.
/// Keepouts use the same geometry but remain explicitly nonconductive. Also
/// flag every pour-backed rail whose imported track length is below the
/// threshold, since its connectivity depends primarily on zone copper.
fn importZones(
    arena: std.mem.Allocator,
    board: snapshot.Snapshot,
    st: *const CopperState,
) Error!ImportedZones {
    var imported: std.ArrayList(ZoneOut) = .empty;
    var zones: std.ArrayList(ZoneInfo) = .empty;
    var pour_fed: std.ArrayList([]const u8) = .empty;
    var seen = std.StringHashMapUnmanaged(void).empty;
    for (board.zones) |zone| {
        const keepout = zone.keepout != null;
        const net = mappedNet(st, zone.net);
        try zones.append(arena, .{ .net = net, .layers = zone.layers, .keepout = keepout });

        if (zone.polygon.len >= 3) {
            for (zone.layers) |layer| {
                try imported.append(arena, .{
                    .net = net,
                    .layer = layer,
                    .poly = try zonePoints(arena, zone.polygon),
                    .keepout = keepout,
                    .priority = zone.priority,
                });
            }
        }
        for (zone.filled) |fill| {
            if (fill.polygon.len < 3) continue;
            try imported.append(arena, .{
                .net = net,
                .layer = fill.layer,
                .poly = try zonePoints(arena, fill.polygon),
                .filled = true,
                .keepout = keepout,
                .priority = zone.priority,
            });
        }

        if (keepout or zone.net.len == 0 or seen.contains(net)) continue;
        try seen.put(arena, net, {});
        if (importedNetMm(st, net) < pour_fed_threshold_mm) try pour_fed.append(arena, net);
    }
    return .{
        .imported = imported.items,
        .report = .{ .zones = zones.items, .pour_fed = pour_fed.items },
    };
}

fn zonePoints(arena: std.mem.Allocator, points: []const snapshot.Point) Error![]const [2]f64 {
    const out = try arena.alloc([2]f64, points.len);
    for (points, out) |point, *dst| dst.* = .{ point.x, point.y };
    return out;
}

/// Total imported straight-track length (mm) recorded for a design net.
fn importedNetMm(st: *const CopperState, net: []const u8) f64 {
    for (st.tally.per_net.items) |t| {
        if (std.mem.eql(u8, t.name, net)) return t.mm;
    }
    return 0;
}

// ── Tests ───────────────────────────────────────────────────────────────────

/// Test shorthand: a flat design instance carrying only identity fields.
fn testInstance(ref: []const u8, uuid: []const u8, origin: []const u8) export_kicad.FlatInstance {
    return .{
        .ref_des = ref,
        .component = "",
        .origin_key = origin,
        .value = "",
        .footprint = "",
        .properties = &.{},
        .uuid = uuid,
    };
}

/// Test shorthand: run the importer with legacy 2-signal-layer rules.
fn buildTest(
    arena: std.mem.Allocator,
    board: snapshot.Snapshot,
    instances: []const export_kicad.FlatInstance,
    nets: []const export_kicad.FlatNet,
) Error!Imported {
    return build(arena, .{ .board = board, .instances = instances, .nets = nets, .rules = .{} }, .{});
}

/// Worst distance (mm) of any track endpoint from a circle of `radius` at the
/// origin — the on-circle assertion helper for the arc tessellation test.
fn maxRadialError(tracks: []const Track, radius: f64) f64 {
    var worst: f64 = 0;
    for (tracks) |t| {
        worst = @max(worst, @abs(std.math.hypot(t.x1, t.y1) - radius));
        worst = @max(worst, @abs(std.math.hypot(t.x2, t.y2) - radius));
    }
    return worst;
}

// spec: kicad_pcb/import-layout - a board footprint matches by canopy_uuid first, then by exact ref-des
test "canopy_uuid outranks the ref-des when matching footprints" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const board = snapshot.Snapshot{
        .footprints = &.{
            // Drifted ref-des on the board: only the sync stamp identifies it.
            .{ .reference = "U9", .canopy = .{ .uuid = "uuid-1" }, .layer = "F.Cu" },
            .{ .reference = "C1", .layer = "F.Cu" },
        },
    };
    const instances = [_]export_kicad.FlatInstance{
        testInstance("U1", "uuid-1", "u1"),
        testInstance("C1", "uuid-2", "c1"),
    };
    const got = try buildTest(arena, board, &instances, &.{});
    try std.testing.expectEqual(@as(usize, 1), got.report.match.by_uuid);
    try std.testing.expectEqual(@as(usize, 1), got.report.match.by_ref);
    try std.testing.expectEqualStrings("U1", got.poses[0].ref);
    try std.testing.expectEqualStrings("C1", got.poses[1].ref);
}

// spec: kicad_pcb/import-layout - unmatched board footprints and design instances are reported, never dropped
test "unmatched footprints and instances both surface in the report" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const board = snapshot.Snapshot{ .footprints = &.{
        .{ .reference = "U1", .layer = "F.Cu" },
        .{ .reference = "J9", .layer = "F.Cu" },
    } };
    const instances = [_]export_kicad.FlatInstance{
        testInstance("U1", "", "u1"),
        testInstance("R5", "", "r5"),
    };
    const got = try buildTest(arena, board, &instances, &.{});
    try std.testing.expectEqual(@as(usize, 1), got.poses.len);
    try std.testing.expectEqual(@as(usize, 1), got.report.match.unmatched_board.len);
    try std.testing.expectEqualStrings("J9", got.report.match.unmatched_board[0]);
    try std.testing.expectEqual(@as(usize, 1), got.report.match.unmatched_design.len);
    try std.testing.expectEqualStrings("R5", got.report.match.unmatched_design[0]);
}

// spec: kicad_pcb/import-layout - a pose copies x and y and derives rotation and side via the sync bake inverse
test "pose conversion mirrors the sync rotation bake and B.Cu side" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const board = snapshot.Snapshot{ .footprints = &.{
        .{ .reference = "U1", .layer = "F.Cu", .at = .{ .x = 10, .y = 20, .rotation_deg = 90 } },
        .{ .reference = "C1", .layer = "B.Cu", .at = .{ .x = 5, .y = 6, .rotation_deg = 0 } },
    } };
    const instances = [_]export_kicad.FlatInstance{
        testInstance("U1", "", "u1"),
        testInstance("C1", "", "c1"),
    };
    const got = try buildTest(arena, board, &instances, &.{});
    try std.testing.expectEqual(@as(f64, 10), got.poses[0].x);
    try std.testing.expectEqual(@as(f64, 20), got.poses[0].y);
    try std.testing.expectApproxEqAbs(@as(f64, 270), got.poses[0].rot, 1e-9);
    try std.testing.expectEqual(optimizer.Side.top, got.poses[0].side);
    try std.testing.expectApproxEqAbs(@as(f64, 180), got.poses[1].rot, 1e-9);
    try std.testing.expectEqual(optimizer.Side.bottom, got.poses[1].side);
    // The bake is its own inverse (sync.zig round-trip semantics).
    const twice = kicadRotToNetlisp(kicadRotToNetlisp(37.5, .bottom), .bottom);
    try std.testing.expectApproxEqAbs(@as(f64, 37.5), twice, 1e-9);
}

// spec: kicad_pcb/import-layout - stale copper-only net names fold onto their pad-carrying canonical before mapping
test "stale copper spelling folds onto the pad net before mapping" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const board = snapshot.Snapshot{
        .nets = &.{ .{ .name = "BPF_RF" }, .{ .name = "RF1_A" } },
        .footprints = &.{.{
            .reference = "U1",
            .layer = "F.Cu",
            .pads = &.{.{
                .number = "1",
                .shape = "rect",
                .size = .{ .x = 1, .y = 1 },
                .layers = &.{"F.Cu"},
                .net = "RF1_A",
            }},
        }},
        // Track still carries the pre-rename name but lands on the pad.
        .segments = &.{.{
            .start = .{ .x = 0, .y = 0 },
            .end = .{ .x = 8, .y = 0 },
            .width = 0.2,
            .layer = "F.Cu",
            .net = "BPF_RF",
        }},
    };
    const pins = [_]export_kicad.FlatPin{.{ .ref_des = "U1", .pin = "1" }};
    const nets = [_]export_kicad.FlatNet{.{ .name = "RF1_A", .pins = &pins }};
    const instances = [_]export_kicad.FlatInstance{testInstance("U1", "", "u1")};
    const got = try buildTest(arena, board, &instances, &nets);
    try std.testing.expectEqual(@as(usize, 1), got.report.aliases.safe_groups);
    try std.testing.expectEqualStrings("RF1_A", got.report.aliases.folds[0].canonical);
    try std.testing.expectEqualStrings("BPF_RF", got.report.aliases.folds[0].aliases[0]);
    try std.testing.expectEqualStrings("RF1_A", got.tracks[0].net);
}

// spec: kicad_pcb/import-layout - a board net whose pads agree on one design net maps to it as identical or renamed
test "pad-set vote maps a renamed board net onto its design net" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const board = snapshot.Snapshot{
        .nets = &.{ .{ .name = "VCC_IN" }, .{ .name = "GND" } },
        .footprints = &.{
            .{ .reference = "U1", .layer = "F.Cu", .pads = &.{
                .{ .number = "1", .net = "VCC_IN" },
                .{ .number = "2", .net = "GND" },
            } },
            .{ .reference = "C1", .layer = "F.Cu", .at = .{ .x = 30, .y = 0 }, .pads = &.{
                .{ .number = "1", .net = "VCC_IN" },
                .{ .number = "2", .net = "GND" },
            } },
        },
        // Far from every pad so no alias fold interferes with the vote.
        .segments = &.{.{
            .start = .{ .x = 0, .y = 50 },
            .end = .{ .x = 10, .y = 50 },
            .width = 0.2,
            .layer = "F.Cu",
            .net = "VCC_IN",
        }},
    };
    const vdd_pins = [_]export_kicad.FlatPin{
        .{ .ref_des = "U1", .pin = "1" },
        .{ .ref_des = "C1", .pin = "1" },
    };
    const gnd_pins = [_]export_kicad.FlatPin{
        .{ .ref_des = "U1", .pin = "2" },
        .{ .ref_des = "C1", .pin = "2" },
    };
    const nets = [_]export_kicad.FlatNet{
        .{ .name = "VDD", .pins = &vdd_pins },
        .{ .name = "GND", .pins = &gnd_pins },
    };
    const instances = [_]export_kicad.FlatInstance{
        testInstance("U1", "", "u1"),
        testInstance("C1", "", "c1"),
    };
    const got = try buildTest(arena, board, &instances, &nets);
    try std.testing.expectEqual(@as(usize, 1), got.report.net_map.identical);
    try std.testing.expectEqual(@as(usize, 1), got.report.net_map.renamed);
    try std.testing.expectEqualStrings("VCC_IN", got.report.net_map.renames[0].board);
    try std.testing.expectEqualStrings("VDD", got.report.net_map.renames[0].design);
    try std.testing.expectEqualStrings("VDD", got.tracks[0].net);
}

// spec: kicad_pcb/import-layout - a board net whose pads split across design nets keeps its spelling as ambiguous
test "a split pad-set vote keeps the board spelling and reports ambiguity" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const board = snapshot.Snapshot{
        .nets = &.{.{ .name = "X" }},
        .footprints = &.{.{ .reference = "U1", .layer = "F.Cu", .pads = &.{
            .{ .number = "1", .net = "X" },
            .{ .number = "2", .net = "X" },
        } }},
        .segments = &.{.{
            .start = .{ .x = 0, .y = 50 },
            .end = .{ .x = 4, .y = 50 },
            .width = 0.2,
            .layer = "F.Cu",
            .net = "X",
        }},
    };
    const a_pins = [_]export_kicad.FlatPin{.{ .ref_des = "U1", .pin = "1" }};
    const b_pins = [_]export_kicad.FlatPin{.{ .ref_des = "U1", .pin = "2" }};
    const nets = [_]export_kicad.FlatNet{
        .{ .name = "A", .pins = &a_pins },
        .{ .name = "B", .pins = &b_pins },
    };
    const instances = [_]export_kicad.FlatInstance{testInstance("U1", "", "u1")};
    const got = try buildTest(arena, board, &instances, &nets);
    try std.testing.expectEqual(@as(usize, 1), got.report.net_map.ambiguous.len);
    try std.testing.expectEqualStrings("X", got.report.net_map.ambiguous[0].board);
    try std.testing.expectEqual(@as(usize, 2), got.report.net_map.ambiguous[0].candidates.len);
    try std.testing.expectEqualStrings("X", got.tracks[0].net);
}

// spec: kicad_pcb/import-layout - a board net with no shared pads keeps its spelling and is reported unmatched
test "a board net no shared pad voted on is reported unmatched" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const board = snapshot.Snapshot{
        .nets = &.{.{ .name = "ORPHAN" }},
        .segments = &.{.{
            .start = .{ .x = 0, .y = 50 },
            .end = .{ .x = 4, .y = 50 },
            .width = 0.2,
            .layer = "F.Cu",
            .net = "ORPHAN",
        }},
    };
    const got = try buildTest(arena, board, &.{}, &.{});
    try std.testing.expectEqual(@as(usize, 1), got.report.net_map.unmatched.len);
    try std.testing.expectEqualStrings("ORPHAN", got.report.net_map.unmatched[0]);
    try std.testing.expectEqualStrings("ORPHAN", got.tracks[0].net);
}

// spec: kicad_pcb/import-layout - a track on a layer outside the signal stack is dropped with layer, net, and length
test "a track on a plane-claimed inner layer is dropped and reported" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const board = snapshot.Snapshot{
        .nets = &.{.{ .name = "SIG" }},
        .segments = &.{
            .{
                .start = .{ .x = 0, .y = 0 },
                .end = .{ .x = 3, .y = 4 },
                .width = 0.2,
                .layer = "In2.Cu",
                .net = "SIG",
            },
            .{
                .start = .{ .x = 0, .y = 0 },
                .end = .{ .x = 1, .y = 0 },
                .width = 0.2,
                .layer = "F.Cu",
                .net = "SIG",
            },
        },
    };
    const got = try buildTest(arena, board, &.{}, &.{});
    try std.testing.expectEqual(@as(usize, 1), got.tracks.len);
    try std.testing.expectEqual(@as(usize, 1), got.report.copper.dropped.len);
    try std.testing.expectEqualStrings("In2.Cu", got.report.copper.dropped[0].layer);
    try std.testing.expectEqualStrings("SIG", got.report.copper.dropped[0].net);
    try std.testing.expectApproxEqAbs(@as(f64, 5), got.report.copper.dropped[0].length_mm, 1e-9);
}

// spec: kicad_pcb/import-layout - a copper arc tessellates into chords whose deviation stays within the chord tolerance
test "arc tessellation stays on the circle within the chord tolerance" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const board = snapshot.Snapshot{
        .nets = &.{.{ .name = "RF" }},
        .arcs = &.{.{
            .start = .{ .x = 10, .y = 0 },
            .mid = .{ .x = 0, .y = 10 },
            .end = .{ .x = -10, .y = 0 },
            .width = 0.3,
            .layer = "F.Cu",
            .net = "RF",
        }},
    };
    const got = try buildTest(arena, board, &.{}, &.{});
    try std.testing.expectEqual(@as(usize, 1), got.report.copper.arcs.count);
    try std.testing.expectEqual(got.tracks.len, got.report.copper.arcs.segments);
    try std.testing.expect(got.tracks.len >= arc_min_segments);
    try std.testing.expect(got.tracks.len <= arc_max_segments);
    try std.testing.expect(got.report.copper.arcs.max_chord_error_mm <= 0.05 + 1e-9);
    try std.testing.expect(maxRadialError(got.tracks, 10) < 1e-9);
    try std.testing.expectEqual(@as(f64, 10), got.tracks[0].x1);
    try std.testing.expectEqual(@as(f64, -10), got.tracks[got.tracks.len - 1].x2);
}

// spec: kicad_pcb/import-layout - edge-cuts pieces chain end-to-start into one closed outline polygon
test "shuffled edge-cuts lines chain into one closed polygon" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const board = snapshot.Snapshot{
        .outline = &.{
            .{ .kind = .line, .points = &.{ .{ .x = 0, .y = 0 }, .{ .x = 20, .y = 0 } } },
            // Deliberately reversed: the chainer must flip it.
            .{ .kind = .line, .points = &.{ .{ .x = 20, .y = 10 }, .{ .x = 20, .y = 0 } } },
            .{ .kind = .line, .points = &.{ .{ .x = 20, .y = 10 }, .{ .x = 0, .y = 10 } } },
            .{ .kind = .line, .points = &.{ .{ .x = 0, .y = 10 }, .{ .x = 0, .y = 0 } } },
        },
    };
    const got = try buildTest(arena, board, &.{}, &.{});
    try std.testing.expect(!got.outline.fallback);
    try std.testing.expectEqual(@as(usize, 4), got.outline.pts.len);
    try std.testing.expectEqual(@as(f64, 20), got.outline.pts[1][0]);
    try std.testing.expectEqual(@as(f64, 10), got.outline.pts[2][1]);
    try std.testing.expectEqual(@as(usize, 4), got.report.outline.points);
}

// spec: kicad_pcb/import-layout - an unclosed outline falls back to the flagged bounding-box rectangle
test "a gapped outline falls back to the bounding box and is flagged" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const board = snapshot.Snapshot{
        .outline = &.{
            .{ .kind = .line, .points = &.{ .{ .x = 0, .y = 0 }, .{ .x = 20, .y = 0 } } },
            .{ .kind = .line, .points = &.{ .{ .x = 20, .y = 0 }, .{ .x = 20, .y = 10 } } },
            // Disconnected stub: the loop can never close.
            .{ .kind = .line, .points = &.{ .{ .x = 5, .y = 7 }, .{ .x = 9, .y = 7 } } },
        },
    };
    const got = try buildTest(arena, board, &.{}, &.{});
    try std.testing.expect(got.outline.fallback);
    try std.testing.expect(got.report.outline.fallback);
    try std.testing.expectEqual(@as(usize, 4), got.outline.pts.len);
    try std.testing.expectEqual(@as(f64, 20), got.outline.pts[2][0]);
    try std.testing.expectEqual(@as(f64, 10), got.outline.pts[2][1]);
}
