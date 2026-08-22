//! Copper-topology and route-intent probes shared by DRC and final cleanup.
//!
//! Clearance DRC proves that copper does not touch the WRONG net. These probes
//! prove the complementary physical facts: every routed trace end lands on
//! useful copper and every through-via joins at least two copper layers. The
//! separate route-intent probe requires an endpoint on the other centreline.
//! A geometric trace graze is neither: it remains open until cleanup inserts a
//! real centreline bridge. Keeping all three readings is deliberate: fabricated
//! connectivity requires a full bottleneck cross-section, while a generated
//! route additionally names every junction explicitly.

const std = @import("std");
const pad_shape = @import("pad_shape.zig");
const copper_contact = @import("copper_contact.zig");

/// Connectivity slack shared with the net-open oracle. Copper inside this
/// 1 µm numeric tolerance may join after the full-cross-section test passes.
const touch_slack_mm = copper_contact.join_slack_mm;

/// Numerical slack for an EXPLICIT trace junction. This is one nanometre in
/// board units: enough to absorb a copied-coordinate round trip, far below any
/// fabrication tolerance, trace width, or router grid. Generated copper is
/// canonicalized to reuse the exact witness coordinate before persistence.
const junction_eps_mm: f64 = 1e-6;

/// One same-net pad terminal in world coordinates.
pub const Terminal = struct {
    shape: pad_shape.Shape,
    net: i32,
    layer: u8,
    thru: bool = false,
};

/// One routed trace projected into topology-only geometry.
pub const Track = struct {
    a: [2]f64,
    b: [2]f64,
    layer: u8,
    width: f64,
    net: i32,
};

/// One routed via projected into topology-only geometry.
pub const Via = struct {
    at: [2]f64,
    dia: f64,
    net: i32,
};

fn layerBit(layer: u8) u64 {
    return if (layer < 64) @as(u64, 1) << @intCast(layer) else 0;
}

fn terminalPointTouch(t: Terminal, x: f64, y: f64, radius: f64, layer: u8, net: i32) bool {
    if (t.net != net or (!t.thru and t.layer != layer)) return false;
    return pad_shape.pointDist(t.shape.x0, t.shape.y0, t.shape.x1, t.shape.y1, t.shape.poly, x, y, std.math.inf(f64)) <= radius + touch_slack_mm;
}

/// The first electrically loose endpoint of `tracks[track_i]`, or null when
/// both ends land on same-net copper. `pour_layers` marks full/filled same-net
/// regions known to cover the endpoint's layer.
///
/// This asks only whether each END is attached — plus the one shape whose ends
/// are attached and which is still not a branch: a route emitted wholly inside
/// the ONLY pad of a one-terminal net, where the land already joins both ends.
/// The GENERAL form of that shape (any net, a chain rather than a segment) is
/// `redundantSections`, which REPORTS rather than removes; this narrow case stays
/// here because the finish has always pruned it and a single-pin breakout's
/// unfinished stub is exactly it.
pub fn looseEnd(
    terminals: []const Terminal,
    tracks: []const Track,
    vias: []const Via,
    track_i: usize,
    pour_layers: [2]u64,
) ?[2]f64 {
    const track = tracks[track_i];
    if (track.net < 0) return null;
    var net_terminals: usize = 0;
    var sole: ?Terminal = null;
    for (terminals) |terminal| {
        if (terminal.net != track.net) continue;
        net_terminals += 1;
        sole = terminal;
    }
    if (net_terminals == 1) {
        const terminal = sole.?;
        if (terminalPointTouch(terminal, track.a[0], track.a[1], track.width / 2, track.layer, track.net) and
            terminalPointTouch(terminal, track.b[0], track.b[1], track.width / 2, track.layer, track.net))
            return track.b;
    }
    for ([_][2]f64{ track.a, track.b }, 0..) |p, end_i| {
        if (!endSupported(terminals, tracks, vias, track_i, p, pour_layers[end_i])) return p;
    }
    return null;
}

fn pointOnCenterline(track: Track, p: [2]f64) bool {
    return pad_shape.segPointDist(
        track.a[0],
        track.a[1],
        track.b[0],
        track.b[1],
        p[0],
        p[1],
    ) <= junction_eps_mm;
}

/// An intentional same-net/same-layer trace junction: at least one stored
/// endpoint lies on the other trace's centreline. This admits an ordinary T
/// without requiring the through-line to be serialized as two sections, while
/// refusing a cap-to-cap graze and a mid-span X whose route topology names no
/// junction at all.
fn tracksJoinExplicitly(a: Track, b: Track) bool {
    if (a.net != b.net or a.layer != b.layer) return false;
    return pointOnCenterline(b, a.a) or pointOnCenterline(b, a.b) or
        pointOnCenterline(a, b.a) or pointOnCenterline(a, b.b);
}

/// The fabrication reading: does one full cross-section of the narrower trace
/// lie in the other trace's copper? Kept separate from
/// `tracksJoinExplicitly`: a robust X crossing conducts but still needs an
/// explicit serialized junction before generated copper is accepted.
fn tracksJoinPhysically(a: Track, b: Track) bool {
    if (a.net != b.net or a.layer != b.layer) return false;
    return copper_contact.trackTrackConnects(
        .{ .a = a.a, .b = a.b, .width = a.width },
        .{ .a = b.a, .b = b.b, .width = b.width },
    );
}

/// The looser drawing-space relation used only to find contacts cleanup can
/// repair. It must never feed a connectivity graph directly.
fn tracksOverlapGeometrically(a: Track, b: Track) bool {
    if (a.net != b.net or a.layer != b.layer) return false;
    return copper_contact.trackTrackCapsulesOverlap(
        .{ .a = a.a, .b = a.b, .width = a.width },
        .{ .a = b.a, .b = b.b, .width = b.width },
    );
}

fn tracksJoin(a: Track, b: Track) bool {
    return tracksJoinPhysically(a, b);
}

fn rootOf(parent: []usize, start: usize) usize {
    var node = start;
    while (parent[node] != node) node = parent[node];
    return node;
}

fn unite(parent: []usize, a: usize, b: usize) void {
    const ra = rootOf(parent, a);
    const rb = rootOf(parent, b);
    if (ra != rb) parent[rb] = ra;
}

/// One physical trace contact on which the route would rely despite having no
/// explicit centreline junction. `at` is the marker position; `a`/`b` are the
/// two stored section indices.
pub const ImplicitJoin = struct {
    a: usize,
    b: usize,
    at: [2]f64,
};

/// Every cross-component physical contact. Contacts between sections already
/// connected by an explicit path are harmless same-net overlap and are not
/// reported: deleting that incidental contact would not change route intent.
fn nonExplicitContacts(
    arena: std.mem.Allocator,
    tracks: []const Track,
    robust_only: bool,
) std.mem.Allocator.Error![]const ImplicitJoin {
    const parent = try arena.alloc(usize, tracks.len);
    for (parent, 0..) |*p, i| p.* = i;
    for (tracks, 0..) |track, i| {
        for (tracks[i + 1 ..], i + 1..) |other, j| {
            if (tracksJoinExplicitly(track, other)) unite(parent, i, j);
        }
    }
    var out: std.ArrayList(ImplicitJoin) = .empty;
    for (tracks, 0..) |track, i| {
        for (tracks[i + 1 ..], i + 1..) |other, j| {
            if (rootOf(parent, i) == rootOf(parent, j)) continue;
            if (robust_only) {
                if (!tracksJoinPhysically(track, other)) continue;
            } else if (!tracksOverlapGeometrically(track, other)) continue;
            try out.append(arena, .{
                .a = i,
                .b = j,
                .at = pad_shape.segSegMid(track.a, track.b, other.a, other.b),
            });
        }
    }
    return out.toOwnedSlice(arena);
}

/// Robust but unserialized contacts reported as `implicit_junction` warnings.
/// Weak capsule grazes are absent: the connectivity graph keeps them open.
pub fn implicitJoins(
    arena: std.mem.Allocator,
    tracks: []const Track,
) std.mem.Allocator.Error![]const ImplicitJoin {
    return nonExplicitContacts(arena, tracks, true);
}

/// Every geometric contact across explicit components, including weak grazes.
/// Only junction canonicalization may consume this looser relation, to insert
/// a real centreline bridge before connectivity is evaluated again.
pub fn repairableJoins(
    arena: std.mem.Allocator,
    tracks: []const Track,
) std.mem.Allocator.Error![]const ImplicitJoin {
    return nonExplicitContacts(arena, tracks, false);
}

/// Electrical supports beyond pads and tracks. `live_vias` are barrels that
/// reach at least two copper layers; `pour_layers[i][0..2]` carries the
/// filled/poured layer masks at track i's two endpoints. When present,
/// `pour_components` names the exact fabricated fill component at each
/// endpoint; two endpoints share pour conductivity only when those ids match.
/// Empty slices preserve the no-via/no-pour fixture shorthand.
pub const BranchSupport = struct {
    live_vias: []const Via = &.{},
    pour_layers: []const [2]u64 = &.{},
    pour_components: []const [2]u64 = &.{},
};

/// Exact fabricated-fill membership for the persistent nodes in the via
/// deletion graph. Component ids are opaque but globally unique within one DRC
/// pass; equal ids conduct. Nested slices let a through pad or barrel touch
/// several outer pours / inner planes without collapsing their identities.
pub const ViaSupport = struct {
    candidates: []const bool = &.{},
    terminal_components: []const []const u64 = &.{},
    track_components: []const [2]u64 = &.{},
    via_components: []const []const u64 = &.{},
};

fn endpointPourLayers(support: BranchSupport, track_i: usize) [2]u64 {
    return if (track_i < support.pour_layers.len) support.pour_layers[track_i] else .{ 0, 0 };
}

fn endpointPourComponents(support: BranchSupport, track_i: usize) [2]u64 {
    return if (track_i < support.pour_components.len) support.pour_components[track_i] else .{ 0, 0 };
}

fn endpointPourId(support: BranchSupport, track: Track, track_i: usize, end_i: usize) u64 {
    const exact = endpointPourComponents(support, track_i)[end_i];
    if (exact != 0) return exact;
    if (support.pour_components.len != 0 or track.net < 0) return 0;
    return (@as(u64, @intCast(track.net + 1)) << 8) | @as(u64, track.layer) + 1;
}

fn addNeighbour(
    arena: std.mem.Allocator,
    graph: []std.ArrayList(usize),
    a: usize,
    b: usize,
) std.mem.Allocator.Error!void {
    if (a == b) return;
    for (graph[a].items) |old| if (old == b) return;
    try graph[a].append(arena, b);
    try graph[b].append(arena, a);
}

const PourKey = struct { id: u64 };

fn trackTouchesTerminal(track: Track, terminal: Terminal) bool {
    if (terminal.net != track.net or (!terminal.thru and terminal.layer != track.layer)) return false;
    return copper_contact.padTrackConnects(terminal.shape, track.a, track.b, track.width);
}

fn trackTouchesVia(track: Track, via: Via) bool {
    if (track.net != via.net) return false;
    return copper_contact.trackViaConnects(
        .{ .a = track.a, .b = track.b, .width = track.width },
        .{ .at = via.at, .dia = via.dia },
    );
}

fn pourKeys(arena: std.mem.Allocator, tracks: []const Track, support: BranchSupport) std.mem.Allocator.Error![]const PourKey {
    var keys: std.ArrayList(PourKey) = .empty;
    for (tracks, 0..) |track, i| {
        const poured = endpointPourLayers(support, i);
        for (0..2) |end_i| {
            if (poured[end_i] & layerBit(track.layer) == 0) continue;
            const id = endpointPourId(support, track, i, end_i);
            if (id == 0) continue;
            var exists = false;
            for (keys.items) |old| if (old.id == id) {
                exists = true;
                break;
            };
            if (!exists) try keys.append(arena, .{ .id = id });
        }
    }
    return keys.items;
}

fn buildSupportGraph(
    arena: std.mem.Allocator,
    terminals: []const Terminal,
    tracks: []const Track,
    support: BranchSupport,
    pours: []const PourKey,
) std.mem.Allocator.Error![]std.ArrayList(usize) {
    const terminal_start = tracks.len;
    const via_start = terminal_start + terminals.len;
    const pour_start = via_start + support.live_vias.len;
    const graph = try arena.alloc(std.ArrayList(usize), pour_start + pours.len);
    for (graph) |*neighbours| neighbours.* = .empty;

    for (tracks, 0..) |track, i| {
        for (tracks[i + 1 ..], i + 1..) |other, j| {
            if (tracksJoin(track, other)) try addNeighbour(arena, graph, i, j);
        }
        for (terminals, 0..) |terminal, terminal_i| {
            if (trackTouchesTerminal(track, terminal)) try addNeighbour(arena, graph, i, terminal_start + terminal_i);
        }
        for (support.live_vias, 0..) |via, via_i| {
            if (trackTouchesVia(track, via)) try addNeighbour(arena, graph, i, via_start + via_i);
        }
        const poured = endpointPourLayers(support, i);
        for (0..2) |end_i| {
            const id = endpointPourId(support, track, i, end_i);
            if (poured[end_i] & layerBit(track.layer) == 0 or id == 0) continue;
            for (pours, 0..) |pour, pour_i| {
                if (pour.id == id)
                    try addNeighbour(arena, graph, i, pour_start + pour_i);
            }
        }
    }
    return graph;
}

const Components = struct {
    id: []const usize,
    supports: []const usize,
    first_support: []const ?usize,
};

fn graphComponents(
    arena: std.mem.Allocator,
    graph: []const std.ArrayList(usize),
    track_count: usize,
) std.mem.Allocator.Error!Components {
    const unseen = std.math.maxInt(usize);
    const id = try arena.alloc(usize, graph.len);
    @memset(id, unseen);
    const supports = try arena.alloc(usize, graph.len);
    @memset(supports, 0);
    const first_support = try arena.alloc(?usize, graph.len);
    @memset(first_support, null);
    var queue: std.ArrayList(usize) = .empty;
    var component: usize = 0;
    for (graph, 0..) |_, start| {
        if (id[start] != unseen) continue;
        queue.clearRetainingCapacity();
        try queue.append(arena, start);
        id[start] = component;
        var head: usize = 0;
        while (head < queue.items.len) : (head += 1) {
            const vertex = queue.items[head];
            if (vertex >= track_count) {
                supports[component] += 1;
                if (first_support[component] == null) first_support[component] = vertex;
            }
            for (graph[vertex].items) |other| {
                if (id[other] != unseen) continue;
                id[other] = component;
                try queue.append(arena, other);
            }
        }
        component += 1;
    }
    return .{ .id = id, .supports = supports, .first_support = first_support };
}

const ConnectivityWalk = struct {
    arena: std.mem.Allocator,
    graph: []const std.ArrayList(usize),
    components: Components,
    track_count: usize,
    removed: []const bool,
    seen: []usize,
    queue: std.ArrayList(usize) = .empty,

    fn redundant(self: *ConnectivityWalk, candidate: usize, generation: usize) std.mem.Allocator.Error!bool {
        const component = self.components.id[candidate];
        if (self.components.supports[component] <= 1) return true;
        self.queue.clearRetainingCapacity();
        const start = self.components.first_support[component].?;
        try self.queue.append(self.arena, start);
        self.seen[candidate] = generation;
        self.seen[start] = generation;
        var reached: usize = 0;
        var head: usize = 0;
        while (head < self.queue.items.len) : (head += 1) {
            const vertex = self.queue.items[head];
            if (vertex >= self.track_count) reached += 1;
            for (self.graph[vertex].items) |other| {
                if (other < self.track_count and self.removed[other]) continue;
                if (self.seen[other] == generation) continue;
                self.seen[other] = generation;
                try self.queue.append(self.arena, other);
            }
        }
        return reached == self.components.supports[component];
    }
};

/// One result per stored trace section. A section is redundant when deleting
/// it leaves every pad, live via, and same-net poured region that was connected
/// before the deletion connected afterward. Copper-only limbs do not keep a
/// section alive: they are drawing artifacts, not circuit destinations.
pub fn redundantSections(
    arena: std.mem.Allocator,
    terminals: []const Terminal,
    tracks: []const Track,
    support: BranchSupport,
) std.mem.Allocator.Error![]const bool {
    return (try analyzeRedundancy(arena, terminals, tracks, support)).individual;
}

/// Per-section warning verdicts plus one jointly safe automatic removal set.
pub const RedundancyAnalysis = struct {
    individual: []const bool,
    removal: []const bool,
    /// Does this section's copper component join MORE THAN ONE support? Only
    /// there does a redundancy verdict mean "the board keeps another path to
    /// the same places". A component reaching one support or none is copper
    /// that carries nothing at all — the same warning to a reader, but a
    /// different claim, and one a FILL-BLIND caller must not act on: the
    /// support it cannot see may be the pour the copper was drawn to reach.
    /// DRC reports both shapes; automatic cleanup consumes only the first.
    spanning: []const bool,
};

fn terminalsTouch(a: Terminal, b: Terminal) bool {
    if (a.net != b.net) return false;
    if (!a.thru and !b.thru) {
        if (a.layer != b.layer) return false;
    }
    return pad_shape.shapeGap(a.shape, b.shape, touch_slack_mm) <= touch_slack_mm;
}

fn terminalTouchesVia(terminal: Terminal, via: Via) bool {
    if (terminal.net != via.net) return false;
    return pad_shape.pointDist(
        terminal.shape.x0,
        terminal.shape.y0,
        terminal.shape.x1,
        terminal.shape.y1,
        terminal.shape.poly,
        via.at[0],
        via.at[1],
        std.math.inf(f64),
    ) <= via.dia / 2 + touch_slack_mm;
}

fn viasTouch(a: Via, b: Via) bool {
    if (a.net != b.net) return false;
    return std.math.hypot(a.at[0] - b.at[0], a.at[1] - b.at[1]) <=
        (a.dia + b.dia) / 2 + touch_slack_mm;
}

/// Physical copper graph used by redundant-via pruning. Exact fabricated fill
/// components supplied through `ViaSupport` are persistent vertices alongside
/// every pad, trace, and via. Callers protect any contact whose fill cannot be
/// named exactly, so an outline alone never receives conductivity credit.
fn buildViaGraph(
    arena: std.mem.Allocator,
    terminals: []const Terminal,
    tracks: []const Track,
    vias: []const Via,
    support: ViaSupport,
) std.mem.Allocator.Error![]std.ArrayList(usize) {
    const terminal_start = tracks.len;
    const via_start = terminal_start + terminals.len;
    const component_start = via_start + vias.len;
    const components = try viaComponentKeys(arena, support);
    const graph = try arena.alloc(std.ArrayList(usize), component_start + components.len);
    for (graph) |*neighbours| neighbours.* = .empty;

    for (tracks, 0..) |track, track_i| {
        for (tracks[track_i + 1 ..], track_i + 1..) |other, other_i| {
            if (tracksJoin(track, other)) try addNeighbour(arena, graph, track_i, other_i);
        }
        for (terminals, 0..) |terminal, terminal_i| {
            if (trackTouchesTerminal(track, terminal))
                try addNeighbour(arena, graph, track_i, terminal_start + terminal_i);
        }
        for (vias, 0..) |via, via_i| {
            if (trackTouchesVia(track, via))
                try addNeighbour(arena, graph, track_i, via_start + via_i);
        }
    }
    for (terminals, 0..) |terminal, terminal_i| {
        for (terminals[terminal_i + 1 ..], terminal_i + 1..) |other, other_i| {
            if (terminalsTouch(terminal, other))
                try addNeighbour(arena, graph, terminal_start + terminal_i, terminal_start + other_i);
        }
        for (vias, 0..) |via, via_i| {
            if (terminalTouchesVia(terminal, via))
                try addNeighbour(arena, graph, terminal_start + terminal_i, via_start + via_i);
        }
    }
    for (vias, 0..) |via, via_i| {
        for (vias[via_i + 1 ..], via_i + 1..) |other, other_i| {
            if (viasTouch(via, other))
                try addNeighbour(arena, graph, via_start + via_i, via_start + other_i);
        }
    }
    try connectViaSupport(
        arena,
        graph,
        components,
        .{ .component = component_start, .terminal = terminal_start, .via = via_start },
        .{ tracks.len, terminals.len, vias.len },
        support,
    );
    return graph;
}

fn viaComponentKeys(arena: std.mem.Allocator, support: ViaSupport) std.mem.Allocator.Error![]const u64 {
    var components: std.ArrayList(u64) = .empty;
    for (support.terminal_components) |ids| for (ids) |id| try appendComponent(arena, &components, id);
    for (support.track_components) |ends| for (ends) |id| try appendComponent(arena, &components, id);
    for (support.via_components) |ids| for (ids) |id| try appendComponent(arena, &components, id);
    return components.items;
}

const ViaGraphStarts = struct {
    component: usize,
    terminal: usize,
    via: usize,
};

fn connectViaSupport(
    arena: std.mem.Allocator,
    graph: []std.ArrayList(usize),
    components: []const u64,
    starts: ViaGraphStarts,
    counts: [3]usize,
    support: ViaSupport,
) std.mem.Allocator.Error!void {
    for (support.track_components, 0..) |ends, track_i| {
        if (track_i >= counts[0]) break;
        for (ends) |id| try connectComponent(arena, graph, components, starts.component, track_i, id);
    }
    for (support.terminal_components, 0..) |ids, terminal_i| {
        if (terminal_i >= counts[1]) break;
        for (ids) |id| try connectComponent(arena, graph, components, starts.component, starts.terminal + terminal_i, id);
    }
    for (support.via_components, 0..) |ids, via_i| {
        if (via_i >= counts[2]) break;
        for (ids) |id| try connectComponent(arena, graph, components, starts.component, starts.via + via_i, id);
    }
}

fn appendComponent(arena: std.mem.Allocator, components: *std.ArrayList(u64), id: u64) std.mem.Allocator.Error!void {
    if (id == 0) return;
    for (components.items) |old| if (old == id) return;
    try components.append(arena, id);
}

fn connectComponent(
    arena: std.mem.Allocator,
    graph: []std.ArrayList(usize),
    components: []const u64,
    component_start: usize,
    node: usize,
    id: u64,
) std.mem.Allocator.Error!void {
    if (id == 0) return;
    for (components, 0..) |component, component_i| {
        if (component != id) continue;
        try addNeighbour(arena, graph, node, component_start + component_i);
        return;
    }
}

const ViaConnectivityWalk = struct {
    arena: std.mem.Allocator,
    graph: []const std.ArrayList(usize),
    components: Components,
    terminals: []const Terminal,
    tracks: []const Track,
    vias: []const Via,
    support: ViaSupport,
    via_start: usize,
    removed: []const bool,
    seen: []usize,
    queue: std.ArrayList(usize) = .empty,

    fn active(self: ViaConnectivityWalk, vertex: usize) bool {
        if (vertex < self.via_start or vertex >= self.via_start + self.vias.len) return true;
        return !self.removed[vertex - self.via_start];
    }

    fn endSupportedAfterRemoval(self: ViaConnectivityWalk, track_i: usize, end_i: usize, p: [2]f64) bool {
        const track = self.tracks[track_i];
        if (track_i < self.support.track_components.len and self.support.track_components[track_i][end_i] != 0)
            return true;
        for (self.terminals) |terminal| {
            if (!terminalPointTouch(terminal, p[0], p[1], track.width / 2, track.layer, track.net)) continue;
            if (trackTouchesTerminal(track, terminal)) return true;
        }
        for (self.vias, 0..) |via, via_i| {
            if (self.removed[via_i] or via.net != track.net) continue;
            if (std.math.hypot(via.at[0] - p[0], via.at[1] - p[1]) >
                via.dia / 2 + track.width / 2 + touch_slack_mm) continue;
            if (trackTouchesVia(track, via)) return true;
        }
        for (self.tracks, 0..) |other, other_i| {
            if (other_i == track_i or other.net != track.net or other.layer != track.layer) continue;
            if (pad_shape.segPointDist(other.a[0], other.a[1], other.b[0], other.b[1], p[0], p[1]) >
                other.width / 2 + track.width / 2 + touch_slack_mm) continue;
            if (tracksJoinPhysically(track, other)) return true;
        }
        return false;
    }

    /// A via may be a graph leaf without carrying pad-to-pad connectivity, yet
    /// still be the only copper supporting a stored trace endpoint. Removing it
    /// would turn that trace into a new `copper_stub`, so endpoint support is a
    /// second invariant beside component connectivity.
    fn keepsTrackEnds(self: ViaConnectivityWalk, candidate: usize) bool {
        const via = self.vias[candidate];
        for (self.tracks, 0..) |track, track_i| {
            if (!trackTouchesVia(track, via)) continue;
            for ([_][2]f64{ track.a, track.b }, 0..) |p, end_i| {
                if (std.math.hypot(via.at[0] - p[0], via.at[1] - p[1]) >
                    via.dia / 2 + track.width / 2 + touch_slack_mm) continue;
                if (!self.endSupportedAfterRemoval(track_i, end_i, p)) return false;
            }
        }
        return true;
    }

    fn redundant(self: *ViaConnectivityWalk, candidate: usize, generation: usize) std.mem.Allocator.Error!bool {
        if (!self.keepsTrackEnds(candidate)) return false;
        const candidate_node = self.via_start + candidate;
        const component = self.components.id[candidate_node];
        var expected: usize = 0;
        var start: ?usize = null;
        for (self.graph, 0..) |_, vertex| {
            if (vertex == candidate_node or self.components.id[vertex] != component or !self.active(vertex)) continue;
            expected += 1;
            if (start == null) start = vertex;
        }
        if (expected <= 1) return true;

        self.queue.clearRetainingCapacity();
        try self.queue.append(self.arena, start.?);
        self.seen[candidate_node] = generation;
        self.seen[start.?] = generation;
        var reached: usize = 0;
        var head: usize = 0;
        while (head < self.queue.items.len) : (head += 1) {
            const vertex = self.queue.items[head];
            reached += 1;
            for (self.graph[vertex].items) |other| {
                if (!self.active(other) or self.seen[other] == generation) continue;
                self.seen[other] = generation;
                try self.queue.append(self.arena, other);
            }
        }
        return reached == expected;
    }
};

/// Classify vias whose removal leaves every pad, trace, and other via component
/// exactly as connected as before, then derive one jointly safe newest-first
/// deletion plan. `support.candidates` is indexed like `vias`; false entries
/// protect ground, retained scope, and other intentional barrels.
pub fn analyzeViaRedundancy(
    arena: std.mem.Allocator,
    terminals: []const Terminal,
    tracks: []const Track,
    vias: []const Via,
    support: ViaSupport,
) std.mem.Allocator.Error!RedundancyAnalysis {
    const graph = try buildViaGraph(arena, terminals, tracks, vias, support);
    const components = try graphComponents(arena, graph, tracks.len);
    const removed = try arena.alloc(bool, vias.len);
    @memset(removed, false);
    const individual = try arena.alloc(bool, vias.len);
    const seen = try arena.alloc(usize, graph.len);
    @memset(seen, 0);
    var walk = ViaConnectivityWalk{
        .arena = arena,
        .graph = graph,
        .components = components,
        .terminals = terminals,
        .tracks = tracks,
        .vias = vias,
        .support = support,
        .via_start = tracks.len + terminals.len,
        .removed = removed,
        .seen = seen,
    };
    for (vias, 0..) |via, via_i| {
        const eligible = via.net >= 0 and (support.candidates.len == 0 or
            (via_i < support.candidates.len and support.candidates[via_i]));
        removed[via_i] = eligible;
        individual[via_i] = eligible and try walk.redundant(via_i, via_i + 1);
        removed[via_i] = false;
    }
    const spanning = try arena.alloc(bool, vias.len);
    for (vias, 0..) |_, i| spanning[i] = components.supports[components.id[walk.via_start + i]] > 1;
    var generation: usize = vias.len + 1;
    var via_i = vias.len;
    while (via_i > 0) {
        via_i -= 1;
        const via = vias[via_i];
        const eligible = via.net >= 0 and (support.candidates.len == 0 or
            (via_i < support.candidates.len and support.candidates[via_i]));
        if (!eligible) continue;
        removed[via_i] = true;
        if (!try walk.redundant(via_i, generation)) removed[via_i] = false;
        generation += 1;
    }
    return .{ .individual = individual, .removal = removed, .spanning = spanning };
}

/// Classify every independently redundant section, mark which of those
/// verdicts rest on a real alternate path (`spanning`), and derive a
/// deterministic, jointly safe deletion plan from the same support graph.
pub fn analyzeRedundancy(
    arena: std.mem.Allocator,
    terminals: []const Terminal,
    tracks: []const Track,
    support: BranchSupport,
) std.mem.Allocator.Error!RedundancyAnalysis {
    const pours = try pourKeys(arena, tracks, support);
    const graph = try buildSupportGraph(arena, terminals, tracks, support, pours);
    const components = try graphComponents(arena, graph, tracks.len);
    const removed = try arena.alloc(bool, tracks.len);
    @memset(removed, false);
    const individual = try arena.alloc(bool, tracks.len);
    const seen = try arena.alloc(usize, graph.len);
    @memset(seen, 0);
    var walk = ConnectivityWalk{
        .arena = arena,
        .graph = graph,
        .components = components,
        .track_count = tracks.len,
        .removed = removed,
        .seen = seen,
    };
    const spanning = try arena.alloc(bool, tracks.len);
    for (tracks, 0..) |track, i| {
        individual[i] = track.net >= 0 and try walk.redundant(i, i + 1);
        spanning[i] = components.supports[components.id[i]] > 1;
    }
    // Sections are considered newest-first so late detours disappear before
    // established trunks. Accepted deletions participate in all later checks.
    var generation: usize = tracks.len + 1;
    var i = tracks.len;
    while (i > 0) {
        i -= 1;
        if (tracks[i].net < 0) continue;
        removed[i] = true;
        if (!try walk.redundant(i, generation)) removed[i] = false;
        generation += 1;
    }
    return .{ .individual = individual, .removal = removed, .spanning = spanning };
}

fn endSupported(
    terminals: []const Terminal,
    tracks: []const Track,
    vias: []const Via,
    track_i: usize,
    p: [2]f64,
    pour_layers: u64,
) bool {
    const track = tracks[track_i];
    if (pour_layers & layerBit(track.layer) != 0) return true;
    for (terminals) |terminal| {
        if (!terminalPointTouch(terminal, p[0], p[1], track.width / 2, track.layer, track.net)) continue;
        if (trackTouchesTerminal(track, terminal)) return true;
    }
    for (vias) |via| {
        if (via.net != track.net) continue;
        if (std.math.hypot(via.at[0] - p[0], via.at[1] - p[1]) > via.dia / 2 + track.width / 2 + touch_slack_mm) continue;
        if (trackTouchesVia(track, via)) return true;
    }
    for (tracks, 0..) |other, other_i| {
        if (other_i == track_i or other.net != track.net or other.layer != track.layer) continue;
        if (pad_shape.segPointDist(other.a[0], other.a[1], other.b[0], other.b[1], p[0], p[1]) >
            other.width / 2 + track.width / 2 + touch_slack_mm) continue;
        if (tracksJoinPhysically(track, other)) return true;
    }
    return false;
}

/// Copper layers physically reached by `via`. `pour_layers` is the bitmask of
/// same-net filled regions covering the via coordinate; `plane_contacts` is the
/// count of same-net dedicated planes crossed by its barrel.
pub fn viaUseCount(
    terminals: []const Terminal,
    tracks: []const Track,
    via: Via,
    pour_layers: u64,
    plane_contacts: u8,
) usize {
    var layers = pour_layers;
    if (via.net < 0) return @popCount(layers) + plane_contacts;
    for (tracks) |track| {
        if (trackTouchesVia(track, via)) layers |= layerBit(track.layer);
    }
    for (terminals) |terminal| {
        if (terminal.net != via.net) continue;
        if (pad_shape.pointDist(terminal.shape.x0, terminal.shape.y0, terminal.shape.x1, terminal.shape.y1, terminal.shape.poly, via.at[0], via.at[1], std.math.inf(f64)) >
            via.dia / 2 + touch_slack_mm) continue;
        if (terminal.thru) {
            // A via-in-through-pad is already a multi-layer terminal. Keeping
            // it is conservative; duplicate-drill cleanup is a separate rule.
            layers |= 0b11;
        } else {
            layers |= layerBit(terminal.layer);
        }
    }
    return @popCount(layers) + plane_contacts;
}

// spec: placement/copper-topology - a trace end must land on a same-net pad, via, pour, or trace; a free leaf remains loose
test "trace endpoints distinguish real terminals and a dangling leaf" {
    const pads = [_]Terminal{.{ .shape = .{ .x0 = -0.3, .y0 = -0.3, .x1 = 0.3, .y1 = 0.3 }, .net = 0, .layer = 0 }};
    const tracks = [_]Track{
        .{ .a = .{ 0, 0 }, .b = .{ 2, 0 }, .layer = 0, .width = 0.2, .net = 0 },
        .{ .a = .{ 2, 0 }, .b = .{ 3, 0 }, .layer = 0, .width = 0.2, .net = 0 },
    };
    try std.testing.expect(looseEnd(&pads, &tracks, &.{}, 0, .{ 0, 0 }) == null);
    const loose = looseEnd(&pads, &tracks, &.{}, 1, .{ 0, 0 }).?;
    try std.testing.expectApproxEqAbs(@as(f64, 3), loose[0], 1e-9);
    try std.testing.expect(looseEnd(&.{}, tracks[1..2], &.{}, 0, .{ 1, 1 }) == null); // same-net pour
    // Copper wholly inside the ONE pad of a one-terminal net is still loose (the
    // finish has always pruned that shape), and `redundantSections` sees the
    // same copper as removable — the general form of it, on any net.
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const pad_only = [_]Track{.{ .a = .{ 0, 0 }, .b = .{ 0.1, 0 }, .layer = 0, .width = 0.2, .net = 0 }};
    try std.testing.expect(looseEnd(&pads, &pad_only, &.{}, 0, .{ 0, 0 }) != null);
    try std.testing.expect((try redundantSections(arena_inst.allocator(), &pads, &pad_only, .{}))[0]);
}

// spec: placement/copper-topology - a redundancy verdict is marked spanning only when the section's component joins more than one support, separating an alternate path from copper that reaches nothing
// spec: placement/copper-topology - a stored trace section is redundant when deleting it preserves the connectivity of every pad, live via, and poured region
test "copper that leaves a land and returns to it carries nothing" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const pads = [_]Terminal{
        .{ .shape = .{ .x0 = -0.3, .y0 = -0.3, .x1 = 0.3, .y1 = 0.3 }, .net = 0, .layer = 0 },
        .{ .shape = .{ .x0 = 4.7, .y0 = -0.3, .x1 = 5.3, .y1 = 0.3 }, .net = 0, .layer = 0 },
    };
    // A hook: out of the land by less than a half width and back. Both ends are
    // "supported" by the land, so `looseEnd` sees nothing — and it joins nothing.
    const hook = [_]Track{
        .{ .a = .{ 0.2, 0 }, .b = .{ 0.35, 0 }, .layer = 0, .width = 0.2, .net = 0 },
        .{ .a = .{ 0.35, 0 }, .b = .{ 0.2, 0.2 }, .layer = 0, .width = 0.2, .net = 0 },
    };
    try std.testing.expect(looseEnd(&pads, &hook, &.{}, 0, .{ 0, 0 }) == null);
    const dead = try analyzeRedundancy(arena, &pads, &hook, .{});
    try std.testing.expect(dead.individual[0] and dead.individual[1]);
    // …but the hook reaches only the one land, so nothing about it is an
    // ALTERNATE path. An automatic caller that cannot see fill must leave it.
    try std.testing.expect(!dead.spanning[0] and !dead.spanning[1]);
    // The same shape once it actually goes somewhere: a run to the second pad.
    const run = [_]Track{
        .{ .a = .{ 0.2, 0 }, .b = .{ 0.35, 0 }, .layer = 0, .width = 0.2, .net = 0 },
        .{ .a = .{ 0.2, 0 }, .b = .{ 4.8, 0 }, .layer = 0, .width = 0.2, .net = 0 },
    };
    const live = try analyzeRedundancy(arena, &pads, &run, .{});
    // The first short section is still wholly bypassed by pad 1; the long
    // section is the only connection to pad 2 and therefore remains essential.
    try std.testing.expect(live.individual[0] and !live.individual[1]);
    // Both now sit on a component joining both lands, so the verdict on the
    // short one is a genuine "the board has another way there".
    try std.testing.expect(live.spanning[0] and live.spanning[1]);
}

// spec: placement/copper-topology - separate fabricated fill components on one net and layer never form an alternate route for redundancy deletion
test "split pour components cannot make a direct route redundant" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const pads = [_]Terminal{
        .{ .shape = .{ .x0 = -0.3, .y0 = -0.3, .x1 = 0.3, .y1 = 0.3 }, .net = 0, .layer = 0 },
        .{ .shape = .{ .x0 = 4.7, .y0 = -0.3, .x1 = 5.3, .y1 = 0.3 }, .net = 0, .layer = 0 },
    };
    const tracks = [_]Track{
        .{ .a = .{ 0, 0 }, .b = .{ 5, 0 }, .layer = 0, .width = 0.2, .net = 0 },
        .{ .a = .{ 0, 0 }, .b = .{ 0, 2 }, .layer = 0, .width = 0.2, .net = 0 },
        .{ .a = .{ 5, 0 }, .b = .{ 5, 2 }, .layer = 0, .width = 0.2, .net = 0 },
    };
    const layers = [_][2]u64{ .{ 0, 0 }, .{ 0, 1 }, .{ 0, 1 } };
    const split = [_][2]u64{ .{ 0, 0 }, .{ 0, 101 }, .{ 0, 202 } };
    const split_result = try redundantSections(arena, &pads, &tracks, .{
        .pour_layers = &layers,
        .pour_components = &split,
    });
    try std.testing.expect(!split_result[0]);

    const joined = [_][2]u64{ .{ 0, 0 }, .{ 0, 101 }, .{ 0, 101 } };
    const joined_result = try redundantSections(arena, &pads, &tracks, .{
        .pour_layers = &layers,
        .pour_components = &joined,
    });
    try std.testing.expect(joined_result[0]);
}

// spec: placement/copper-topology - a redundant-section removal plan considers newest copper first and preserves support connectivity after all planned deletions are applied together
test "alternate route sections are redundant while an anchored tee survives" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const pads = [_]Terminal{
        .{ .shape = .{ .x0 = -0.3, .y0 = -0.3, .x1 = 0.3, .y1 = 0.3 }, .net = 0, .layer = 0 },
        .{ .shape = .{ .x0 = 4.7, .y0 = -0.3, .x1 = 5.3, .y1 = 0.3 }, .net = 0, .layer = 0 },
        .{ .shape = .{ .x0 = 2.7, .y0 = 1.7, .x1 = 3.3, .y1 = 2.3 }, .net = 0, .layer = 0 },
    };
    const tracks = [_]Track{
        // Direct pad-to-pad trunk plus a two-section alternate path. Deleting
        // any one of these three sections leaves both pads connected.
        .{ .a = .{ 0, 0 }, .b = .{ 5, 0 }, .layer = 0, .width = 0.2, .net = 0 },
        .{ .a = .{ 0, 0 }, .b = .{ 2.5, 1 }, .layer = 0, .width = 0.2, .net = 0 },
        .{ .a = .{ 2.5, 1 }, .b = .{ 5, 0 }, .layer = 0, .width = 0.2, .net = 0 },
        // A real tee from the trunk to a third pad must remain useful.
        .{ .a = .{ 0, 0 }, .b = .{ 3, 2 }, .layer = 0, .width = 0.2, .net = 0 },
    };
    const redundant = try redundantSections(arena, &pads, &tracks, .{});
    try std.testing.expect(redundant[0] and redundant[1] and redundant[2]);
    try std.testing.expect(!redundant[3]);
    const removal = (try analyzeRedundancy(arena, &pads, &tracks, .{})).removal;
    try std.testing.expect(!removal[0] and removal[1] and removal[2] and !removal[3]);

    const retained = [_]Track{ tracks[0], tracks[3] };
    const after = try redundantSections(arena, &pads, &retained, .{});
    try std.testing.expect(!after[0] and !after[1]);
}

// spec: placement/copper-topology - physical same-net contact does not join route topology unless an endpoint lands on the other centreline
test "mid-span trace crossing is reported as an implicit junction" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const pads = [_]Terminal{
        .{ .shape = .{ .x0 = -2.3, .y0 = -0.3, .x1 = -1.7, .y1 = 0.3 }, .net = 0, .layer = 0 },
        .{ .shape = .{ .x0 = -0.3, .y0 = -2.3, .x1 = 0.3, .y1 = -1.7 }, .net = 0, .layer = 0 },
    };
    const tracks = [_]Track{
        .{ .a = .{ -2, 0 }, .b = .{ 2, 0 }, .layer = 0, .width = 0.2, .net = 0 },
        .{ .a = .{ 0, -2 }, .b = .{ 0, 2 }, .layer = 0, .width = 0.2, .net = 0 },
    };
    const redundant = try redundantSections(arena_inst.allocator(), &pads, &tracks, .{});
    try std.testing.expect(!redundant[0] and !redundant[1]);
    const implicit = try implicitJoins(arena_inst.allocator(), &tracks);
    try std.testing.expectEqual(@as(usize, 1), implicit.len);
    try std.testing.expectEqual(@as(usize, 0), implicit[0].a);
    try std.testing.expectEqual(@as(usize, 1), implicit[0].b);

    // A serialized T is explicit even when the through-line is one section.
    const tee = [_]Track{
        tracks[0],
        .{ .a = .{ 0, 0 }, .b = .{ 0, 2 }, .layer = 0, .width = 0.2, .net = 0 },
    };
    try std.testing.expect(tracksJoinExplicitly(tee[0], tee[1]));
    try std.testing.expectEqual(@as(usize, 0), (try implicitJoins(arena_inst.allocator(), &tee)).len);
}

// spec: placement/copper-topology - overlapping round caps remain electrically open until a real centreline bridge gives them a full-width junction
test "wide trace caps cannot hide an open route junction" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const tracks = [_]Track{
        .{ .a = .{ 0, 0 }, .b = .{ 1, 0 }, .layer = 0, .width = 0.2, .net = 0 },
        .{ .a = .{ 1.05, 0 }, .b = .{ 2, 0 }, .layer = 0, .width = 0.2, .net = 0 },
    };
    try std.testing.expect(tracksOverlapGeometrically(tracks[0], tracks[1]));
    try std.testing.expect(!tracksJoinPhysically(tracks[0], tracks[1]));
    try std.testing.expect(!tracksJoinExplicitly(tracks[0], tracks[1]));
    try std.testing.expect(looseEnd(&.{}, &tracks, &.{}, 0, .{ 1, 0 }) != null);
    try std.testing.expectEqual(@as(usize, 0), (try implicitJoins(arena_inst.allocator(), &tracks)).len);
    try std.testing.expectEqual(@as(usize, 1), (try repairableJoins(arena_inst.allocator(), &tracks)).len);
}

// spec: placement/copper-topology - a trace crossing a same-net land at mid-span electrically supports that land
test "mid-span pad contact keeps a load-bearing trace" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const pads = [_]Terminal{
        .{ .shape = .{ .x0 = -0.3, .y0 = -0.3, .x1 = 0.3, .y1 = 0.3 }, .net = 0, .layer = 0 },
        .{ .shape = .{ .x0 = 1.7, .y0 = -0.3, .x1 = 2.3, .y1 = 0.3 }, .net = 0, .layer = 0 },
    };
    const tracks = [_]Track{.{ .a = .{ -1, 0 }, .b = .{ 2, 0 }, .layer = 0, .width = 0.2, .net = 0 }};
    const redundant = try redundantSections(arena_inst.allocator(), &pads, &tracks, .{});
    try std.testing.expect(!redundant[0]);
}

// spec: placement/copper-topology - a via used by one routed layer is dangling while a second layer, pad, pour, or plane makes it useful
test "via use counts distinct copper layers" {
    const via = Via{ .at = .{ 0, 0 }, .dia = 0.5, .net = 0 };
    const top = [_]Track{.{ .a = .{ 0, 0 }, .b = .{ 2, 0 }, .layer = 0, .width = 0.2, .net = 0 }};
    try std.testing.expectEqual(@as(usize, 1), viaUseCount(&.{}, &top, via, 0, 0));
    const both = [_]Track{
        top[0],
        .{ .a = .{ 0, 0 }, .b = .{ 0, 2 }, .layer = 1, .width = 0.2, .net = 0 },
    };
    try std.testing.expectEqual(@as(usize, 2), viaUseCount(&.{}, &both, via, 0, 0));
    try std.testing.expectEqual(@as(usize, 2), viaUseCount(&.{}, &top, via, 0, 1));
}

// spec: placement/copper-topology - redundant-via pruning preserves every persistent copper component and chooses a jointly safe subset of parallel layer jumps
test "via redundancy keeps one of two parallel layer jumps" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const tracks = [_]Track{
        .{ .a = .{ 0, 0 }, .b = .{ 2, 0 }, .layer = 0, .width = 0.2, .net = 0 },
        .{ .a = .{ 0, 0 }, .b = .{ 2, 0 }, .layer = 1, .width = 0.2, .net = 0 },
    };
    const vias = [_]Via{
        .{ .at = .{ 0.5, 0 }, .dia = 0.4, .net = 0 },
        .{ .at = .{ 1.5, 0 }, .dia = 0.4, .net = 0 },
    };
    const analysis = try analyzeViaRedundancy(arena_inst.allocator(), &.{}, &tracks, &vias, .{});
    try std.testing.expect(analysis.individual[0] and analysis.individual[1]);
    try std.testing.expectEqual(@as(usize, 1), @as(usize, @intFromBool(analysis.removal[0])) + @intFromBool(analysis.removal[1]));
    try std.testing.expect(!analysis.removal[0] and analysis.removal[1]);
}

// spec: placement/copper-topology - a via that is the only robust bridge between persistent copper features is never deletion-invariant
test "via redundancy retains an articulation and honors protection" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const tracks = [_]Track{
        .{ .a = .{ 0, 0 }, .b = .{ 1, 0 }, .layer = 0, .width = 0.2, .net = 0 },
        .{ .a = .{ 1, 0 }, .b = .{ 2, 0 }, .layer = 1, .width = 0.2, .net = 0 },
    };
    const vias = [_]Via{.{ .at = .{ 1, 0 }, .dia = 0.4, .net = 0 }};
    const essential = try analyzeViaRedundancy(arena_inst.allocator(), &.{}, &tracks, &vias, .{});
    try std.testing.expect(!essential.individual[0]);
    try std.testing.expect(!essential.removal[0]);

    const isolated = [_]Via{.{ .at = .{ 4, 0 }, .dia = 0.4, .net = 0 }};
    const protected = [_]bool{false};
    const protected_analysis = try analyzeViaRedundancy(arena_inst.allocator(), &.{}, &tracks, &isolated, .{ .candidates = &protected });
    try std.testing.expect(!protected_analysis.individual[0]);
    try std.testing.expect(!protected_analysis.removal[0]);
}

// spec: placement/copper-topology - a via that is the sole support for a trace endpoint remains even when deleting its graph leaf would not split a component
test "via redundancy preserves trace endpoint support" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const pads = [_]Terminal{.{
        .shape = .{ .x0 = -0.3, .y0 = -0.3, .x1 = 0.3, .y1 = 0.3 },
        .net = 0,
        .layer = 0,
    }};
    const tracks = [_]Track{.{ .a = .{ 0, 0 }, .b = .{ 2, 0 }, .layer = 0, .width = 0.2, .net = 0 }};
    const vias = [_]Via{.{ .at = .{ 2, 0 }, .dia = 0.4, .net = 0 }};
    const analysis = try analyzeViaRedundancy(arena_inst.allocator(), &pads, &tracks, &vias, .{});
    try std.testing.expect(!analysis.individual[0]);
    try std.testing.expect(!analysis.removal[0]);
}
