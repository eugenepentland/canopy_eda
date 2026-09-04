//! Port-escape proof — can a block's own `(port …)` net physically LEAVE the
//! block?
//!
//! Every other routability gate keys off nets that route INSIDE the placement.
//! A module port does not: `straps-synth-lmx2595`'s `SPI_SCK` terminates on ONE
//! pad of `U1` and goes nowhere else in the module, so it has no airwire, no
//! lane demand at any hub's escape fan, and nothing for the router to fail at —
//! its net is a single pin, which the router skips outright. A rough seed can
//! therefore wall that pad in completely and no surface reports a thing. That is
//! the gap this module closes: a port is the block's contract with the board it
//! is stamped onto, so its copper MUST be able to reach the block's boundary.
//!
//! The proof, per port net, is a reachability question and is answered as one.
//! Walk a track centre from the net's own pads through free space until either
//!
//!   * it leaves the placement's HULL — the corridor escape, or
//!   * it reaches a spot where a via of the net's class fits — the via escape.
//!     A via puts the signal on another layer, where the block's parts (all on
//!     one face) are not in the way, so it leaves just as surely.
//!
//! Either one proves the port; a net with neither is one finding naming the pad
//! that came closest and the parts walling it in.
//!
//! ── The definitions this rests on, stated so a finding can be argued with
//!
//! HULL: the bounding box of every part's world COURTYARD
//! (`optimizer.worldCourtyard`, rotation-aware) — the footprint the block
//! occupies on its parent board. Not the `(board …)` outline (a module has none,
//! and a design's outline is usually far larger than its parts), and not
//! `Placement.minx…maxy` (the caller fills those from keep-boxes, which the
//! rough view inflates by the routing gap). A corridor reaching past the
//! courtyard bbox has left the sub-circuit, which is exactly the user-facing
//! statement "routable out of the bounding box of the sub-circuit".
//!
//! OBSTACLES: foreign-net pad copper sharing the subject pad's face, inflated by
//! `width/2 + clearanceBetween(subject, obstacle)` — the same model, resolved
//! the same way, that `routability_lint`'s sealed gate and the router's own
//! obstacle build use. Deliberately NOT courtyards: routing a track between the
//! pads of two side-by-side 0402s is ordinary practice, and treating a body as
//! solid would flag every dense ring in the corpus and hand the repair round a
//! licence to spread every board apart. Copper already on the board is not
//! modelled either — this is a placement-time preflight and copper is the
//! router's business. A VIA is measured against BOTH faces, since its barrel
//! drills through them.
//!
//! GRID: a square lattice at `probe_pitch_mm`, anchored at the hull's min corner
//! minus `hull_margin_mm`, flooded 4-connected. The pitch is the whole accuracy
//! trade and it is one-sided on purpose: a lattice can only MISS a corridor
//! (report a blockage that is not there), never invent one, so it is set fine
//! enough that any corridor with a free band at least one pitch wide is found.
//! The router's own pitch is `track_width + clearance` (0.254 mm on the default
//! class); probing at that pitch would report corridors blocked that exist and
//! the router merely cannot phase onto, and a lint that guesses is worse than no
//! lint. Cells are evaluated lazily against a bucket index of the pads, so a
//! port that escapes in its first few hundred cells costs a few hundred tests
//! and only a genuinely blocked one pays for the whole region.
//!
//! Exemptions mirror the sealed gate: a plane-carried port net rejoins through
//! its pour rather than a surface escape (`plane_stitch.netHasPlane`, so a
//! board declaring no `(stackup …)` still exempts its grounds), a through-hole
//! port pad is already on every layer, and a port naming no pad in this block
//! has nothing to prove.
//!
//! Deterministic: fixed lattice, fixed flood order, blockers ranked by their
//! measured shortfall with the ref-des as the tie-break. No clock, no RNG.

const std = @import("std");
const optimizer = @import("optimizer.zig");
const geometry = @import("geometry.zig");
const pad_shape = @import("pad_shape.zig");
const plane_stitch = @import("plane_stitch.zig");
const power_route_width = @import("power_route_width.zig");
const env = @import("../eval/env.zig");
const flat_netlist = @import("../flat_netlist.zig");
const numeric = @import("../numeric.zig");
const net_name = @import("../net_name.zig");

const Allocator = std.mem.Allocator;
const Placement = optimizer.Placement;
const Part = optimizer.Part;
const FlatNet = flat_netlist.FlatNet;

/// Probe lattice pitch (mm). Fine enough that a corridor whose free band is at
/// least this wide is always found — on the default 0.127/0.127 class the
/// tightest lane between two 0402 pads at a 1.1 mm part pitch leaves a 0.119 mm
/// band, so 0.05 mm finds it twice over. See the module note for why the
/// router's own coarser pitch is the wrong number here.
const probe_pitch_mm: f64 = 0.05;
/// Ring of lattice kept outside the hull, so "left the block" is a cell the
/// flood can stand on rather than an index bound.
const hull_margin_mm: f64 = 0.6;
/// Lattice cells past which the gate declines to answer. A block needing more
/// than this is a whole board, not a sub-circuit whose ports have to clear its
/// own footprint — and the flood is the one part of the preflight that is not
/// closed-form.
const max_cells: usize = 1 << 21;
/// Bucket edge (mm) of the pad index the lazy cell test reads. Each pad is filed
/// in every bucket its inflated bounding box touches, so one bucket lookup sees
/// every pad that could possibly block the cell.
const bucket_mm: f64 = 1.0;
/// Blocking parts named per finding.
const max_blockers: usize = 3;

/// One pad, named the way every other PCB surface names one.
pub const Party = struct { ref: []const u8, pad: []const u8 };

/// The millimetres behind a blocked port: the room its least-blocked frontier
/// cell had, the room the net's class demanded there, and the two terms that
/// demand is built from. One value because they only mean anything together.
pub const Mm = struct {
    have: f64 = 0,
    need: f64 = 0,
    width: f64 = 0,
    clearance: f64 = 0,
};

/// A port net with no proof of escape: the pad that came closest, the numbers
/// behind that frontier, and the parts walling it in. `blocker` is the
/// cheapest-to-open obstruction on a DIFFERENT part — the one a placement can
/// actually move — and is null when the net is fenced only by its own part's
/// copper, which is a footprint fact no move answers.
pub const Blocked = struct {
    name: []const u8,
    /// The subject pad the proof got furthest with.
    ref: []const u8,
    pad: []const u8,
    mm: Mm,
    /// Cheapest-to-open movable blocker, or null — see the struct note.
    blocker: ?Party = null,
    /// The MOVABLE parts walling the pad in — the subject pad's own part is
    /// left out, since no placement move answers a part's own footprint —
    /// cheapest to open first, capped at `max_blockers`.
    blockers: []const []const u8 = &.{},
};

/// Net-index mask of `block`'s own `(port …)` declarations. A port names its net
/// by the design-local spelling, so a flattened `pwr/VIN` matches port `VIN` on
/// its leaf exactly as `portCompass` resolves the placer's flow compass. A block
/// declaring no port (every design root that declares none) masks nothing and
/// the gate is then a no-op.
pub fn portNets(
    arena: Allocator,
    block: *const env.DesignBlock,
    nets: []const FlatNet,
) Allocator.Error![]bool {
    const out = try arena.alloc(bool, nets.len);
    @memset(out, false);
    for (block.ports) |pt| {
        const want = if (pt.net.len > 0) pt.net else pt.name;
        if (want.len == 0) continue;
        for (nets, 0..) |net, ni| {
            if (std.mem.eql(u8, net.name, want) or std.mem.eql(u8, leafName(net.name), want)) out[ni] = true;
        }
    }
    return out;
}

const leafName = net_name.leaf;

/// Prove every masked port net can leave the block; return one `Blocked` per net
/// that cannot, in net order. `ports` is index-aligned with `p.nets`; a shorter
/// or empty slice simply masks fewer nets, so a caller with no port information
/// gets no findings.
pub fn detect(arena: Allocator, p: Placement, ports: []const bool) Allocator.Error![]Blocked {
    if (ports.len == 0 or p.parts.len == 0) return arena.alloc(Blocked, 0);
    return detectWithPads(arena, p, ports, try worldPads(arena, p));
}

/// Prove ports using a caller's already-flattened world-pad table. The
/// routability preflight builds the same shapes for its sealed-pad gate, so its
/// repeated repair path can share them instead of resolving pad nets and world
/// geometry twice per pose.
pub fn detectWithPads(arena: Allocator, p: Placement, ports: []const bool, pads: []const PadView) Allocator.Error![]Blocked {
    var out: std.ArrayList(Blocked) = .empty;
    if (ports.len == 0 or p.parts.len == 0) return out.toOwnedSlice(arena);
    const board = try Board.buildWithPads(arena, p, pads);
    const g = board.grid orelse return out.toOwnedSlice(arena);
    const seen = try arena.alloc(bool, g.nx * g.ny);
    for (p.nets, 0..) |net, ni| {
        if (ni >= ports.len or !ports[ni]) continue;
        if (plane_stitch.netHasPlane(p, net.name)) continue;
        if (try board.escape(arena, ni, seen)) |blocked| try out.append(arena, blocked);
    }
    return out.toOwnedSlice(arena);
}

// ── The board model ──────────────────────────────────────────────────────────

/// One pad in world space with the little the flood needs of it.
pub const PadView = struct {
    ref: []const u8,
    number: []const u8,
    /// Flattened net index, or -1 for a pad carrying no net (still copper).
    net: i32,
    shape: pad_shape.Shape,
    side: optimizer.Side,
    thru: bool,

    /// True when this pad's copper shares a face with one on `side`. A
    /// through-hole barrel exists on every layer, so it always does.
    fn onFace(self: PadView, side: optimizer.Side) bool {
        return self.thru or self.side == side;
    }
};

/// The probe lattice: origin, pitch and extent, plus the hull escape is proved
/// from.
const Grid = struct {
    ox: f64,
    oy: f64,
    nx: usize,
    ny: usize,
    hull: [4]f64,

    fn cellX(self: Grid, i: usize) f64 {
        return self.ox + @as(f64, @floatFromInt(i)) * probe_pitch_mm;
    }

    fn cellY(self: Grid, j: usize) f64 {
        return self.oy + @as(f64, @floatFromInt(j)) * probe_pitch_mm;
    }

    /// True when the cell centre lies outside the hull — the escape condition.
    fn outside(self: Grid, x: f64, y: f64) bool {
        return x < self.hull[0] or x > self.hull[2] or y < self.hull[1] or y > self.hull[3];
    }
};

/// The placement flattened once: world pads, the lattice, and a bucket index so
/// a cell test reads only the pads that could reach it.
const Board = struct {
    p: Placement,
    pads: []const PadView,
    grid: ?Grid,
    buckets: []const []const u32,
    bx: usize = 0,
    by: usize = 0,

    fn buildWithPads(arena: Allocator, p: Placement, pads: []const PadView) Allocator.Error!Board {
        const hull = courtyardHull(p.parts);
        var board: Board = .{
            .p = p,
            .pads = pads,
            .grid = latticeOver(hull),
            .buckets = &.{},
        };
        if (board.grid) |g| try board.indexPads(arena, g);
        return board;
    }

    /// File every pad into each bucket its clearance-inflated box touches, so a
    /// cell's own bucket lists every pad that can block it. Inflated by the
    /// widest halo any net class on this board demands — a bound, never a
    /// filter: the exact per-pair distance is still measured per cell.
    fn indexPads(self: *Board, arena: Allocator, g: Grid) Allocator.Error!void {
        const reach = self.maxHalo();
        self.bx = bucketCount(g.nx);
        self.by = bucketCount(g.ny);
        const lists = try arena.alloc(std.ArrayList(u32), self.bx * self.by);
        for (lists) |*l| l.* = .empty;
        for (self.pads, 0..) |pd, pi| {
            const lo = self.bucketOf(g, pd.shape.x0 - reach, pd.shape.y0 - reach);
            const hi = self.bucketOf(g, pd.shape.x1 + reach, pd.shape.y1 + reach);
            for (lo[1]..hi[1] + 1) |b| {
                for (lo[0]..hi[0] + 1) |a| try lists[b * self.bx + a].append(arena, @intCast(pi));
            }
        }
        const out = try arena.alloc([]const u32, lists.len);
        for (lists, out) |*l, *o| o.* = l.items;
        self.buckets = out;
    }

    /// The widest halo any copper on this board projects: the widest track (or
    /// via) plus the widest clearance. Sizes the bucket index only.
    fn maxHalo(self: Board) f64 {
        var width = @max(self.p.rules.design.track_width, self.p.rules.design.via_dia);
        var clear = self.p.rules.design.clearance;
        for (self.p.rules.net) |r| {
            width = @max(width, @max(r.width, r.via_dia));
            clear = @max(clear, r.clearance);
        }
        return width / 2 + clear;
    }

    fn bucketOf(self: Board, g: Grid, x: f64, y: f64) [2]usize {
        return .{ floorIndex((x - g.ox) / bucket_mm, self.bx), floorIndex((y - g.oy) / bucket_mm, self.by) };
    }

    /// Prove net `ni` can leave, or describe why it cannot. `seen` is the
    /// caller's scratch visit map, reset here so one buffer serves every net.
    fn escape(self: Board, arena: Allocator, ni: usize, seen: []bool) Allocator.Error!?Blocked {
        const g = self.grid orelse return null;
        var subjects: std.ArrayList(PadView) = .empty;
        for (self.pads) |pd| {
            if (pd.net == @as(i32, @intCast(ni)) and !pd.thru) try subjects.append(arena, pd);
        }
        if (subjects.items.len == 0) return null;
        // Every pad of the net on one face is seeded together: the port is proved
        // when ANY of them gets out, which is what "at least one pad can escape"
        // means, and one flood answers for all of them.
        var blocked: ?Blocked = null;
        for ([_]optimizer.Side{ .top, .bottom }) |side| {
            var flood = Flood.build(self, ni, g, side, seen);
            var any = false;
            for (subjects.items) |pd| {
                if (!pd.onFace(side)) continue;
                any = true;
                try flood.seedFrom(arena, pd);
            }
            if (!any) continue;
            if (try flood.run(arena)) return null;
            if (blocked == null) blocked = try flood.report(arena, nearestToEdge(g, subjects.items, side));
        }
        return blocked;
    }
};

fn bucketCount(cells: usize) usize {
    const span = @as(f64, @floatFromInt(cells)) * probe_pitch_mm;
    return numeric.toCount(@ceil(span / bucket_mm)) + 1;
}

/// Floor `f` into `[0, n-1]`. The clamp runs in float space, so the narrowing
/// is always in range whatever a degenerate coordinate hands it.
fn floorIndex(f: f64, n: usize) usize {
    const hi = @as(f64, @floatFromInt(n)) - 1;
    return numeric.toCount(@floor(std.math.clamp(f, 0, @max(hi, 0))));
}

/// The net's pad with the least distance to the hull edge — the shortest escape
/// it could possibly have had, and so the one a failed finding is written about.
/// Ties break on ref-des then pad number, so the choice is stable.
fn nearestToEdge(g: Grid, pads: []const PadView, side: optimizer.Side) PadView {
    var best = pads[0];
    var best_d = std.math.inf(f64);
    for (pads) |pd| {
        if (!pd.onFace(side)) continue;
        const cx = (pd.shape.x0 + pd.shape.x1) / 2;
        const cy = (pd.shape.y0 + pd.shape.y1) / 2;
        const d = @min(@min(cx - g.hull[0], g.hull[2] - cx), @min(cy - g.hull[1], g.hull[3] - cy));
        if (d < best_d or (d == best_d and padOrder(pd, best))) {
            best = pd;
            best_d = d;
        }
    }
    return best;
}

fn padOrder(a: PadView, b: PadView) bool {
    if (!std.mem.eql(u8, a.ref, b.ref)) return std.mem.order(u8, a.ref, b.ref) == .lt;
    return std.mem.order(u8, a.number, b.number) == .lt;
}

/// World-space pads of every part, in part then pad order.
fn worldPads(arena: Allocator, p: Placement) Allocator.Error![]const PadView {
    var of_pad = std.StringHashMapUnmanaged(u32).empty;
    for (p.nets, 0..) |net, ni| {
        for (net.pins) |pin| {
            const key = try std.fmt.allocPrint(arena, "{s}|{s}", .{ pin.ref_des, pin.pin });
            try of_pad.put(arena, key, @intCast(ni));
        }
    }
    var out: std.ArrayList(PadView) = .empty;
    for (p.parts) |part| {
        for (part.pads) |pad| {
            const key = try std.fmt.allocPrint(arena, "{s}|{s}", .{ part.ref_des, pad.number });
            const ni = of_pad.get(key);
            try out.append(arena, .{
                .ref = part.ref_des,
                .number = pad.number,
                .net = if (ni) |n| @intCast(n) else -1,
                .shape = try pad_shape.worldShape(arena, part, pad),
                .side = part.side,
                .thru = pad.thru,
            });
        }
    }
    return out.toOwnedSlice(arena);
}

/// Bounding box of every part's world courtyard — the block's footprint. See the
/// module note on why this and not the board outline.
fn courtyardHull(parts: []const Part) [4]f64 {
    var hull = [4]f64{ std.math.inf(f64), std.math.inf(f64), -std.math.inf(f64), -std.math.inf(f64) };
    for (parts) |part| {
        const r = optimizer.worldCourtyard(&part);
        hull[0] = @min(hull[0], r.minx);
        hull[1] = @min(hull[1], r.miny);
        hull[2] = @max(hull[2], r.minx + r.w);
        hull[3] = @max(hull[3], r.miny + r.h);
    }
    return hull;
}

/// The lattice over `hull` plus its escape ring, or null when the block is
/// degenerate or would need more than `max_cells` of probing.
fn latticeOver(hull: [4]f64) ?Grid {
    if (!std.math.isFinite(hull[0]) or !std.math.isFinite(hull[2])) return null;
    if (hull[2] < hull[0] or hull[3] < hull[1]) return null;
    const fx = @ceil((hull[2] - hull[0] + 2 * hull_margin_mm) / probe_pitch_mm) + 1;
    const fy = @ceil((hull[3] - hull[1] + 2 * hull_margin_mm) / probe_pitch_mm) + 1;
    if (fx < 2 or fy < 2) return null;
    if (!withinCellCap(fx, fy)) return null;
    return .{
        .ox = hull[0] - hull_margin_mm,
        .oy = hull[1] - hull_margin_mm,
        .nx = numeric.toCount(fx),
        .ny = numeric.toCount(fy),
        .hull = hull,
    };
}

/// True when a lattice of `fx` x `fy` cells is inside `max_cells`. Each side is
/// bounded first so the product cannot overflow into a finite lie.
fn withinCellCap(fx: f64, fy: f64) bool {
    const cap = @as(f64, @floatFromInt(max_cells));
    if (fx > cap or fy > cap) return false;
    return fx * fy <= cap;
}

// ── The flood ────────────────────────────────────────────────────────────────

/// A blocked frontier cell's tightest obstruction: how much room it had against
/// how much it needed, and whose copper took the difference.
const Frontier = struct {
    ref: []const u8,
    pad: []const u8,
    have: f64,
    need: f64,
    /// True when the obstruction is the subject pad's own part — real geometry,
    /// but not something a placement move can answer.
    own: bool = false,
};

/// One net's reachability search over the lattice, on one board face. Cells are
/// tested lazily, so a port that escapes early never pays for the rest of the
/// board.
const Flood = struct {
    board: Board,
    g: Grid,
    net: usize,
    side: optimizer.Side,
    width: f64,
    via_r: f64,
    seen: []bool,
    queue: std.ArrayList(u32),
    /// The least-blocked obstruction met on the frontier, one per blocking part.
    walls: std.ArrayList(Frontier),

    fn build(board: Board, ni: usize, g: Grid, side: optimizer.Side, seen: []bool) Flood {
        @memset(seen, false);
        const rules = board.p.rules;
        var via = rules.design.via_dia;
        if (ni < rules.net.len and rules.net[ni].via_dia > 0) via = rules.net[ni].via_dia;
        return .{
            .board = board,
            .g = g,
            .net = ni,
            .side = side,
            .width = netWidth(board.p, ni),
            .via_r = via / 2,
            .seen = seen,
            .queue = .empty,
            .walls = .empty,
        };
    }

    /// Clearance the subject net's copper owes pad `q`'s, for a centreline
    /// carrying `half` of its own copper either side.
    fn needAgainst(self: Flood, q: PadView, half: f64) f64 {
        const base = self.board.p.rules.design.clearance;
        return half + self.board.p.rules.clearanceBetween(@intCast(self.net), q.net, base);
    }

    /// Seed cells: every free lattice cell inside the pad's box grown by half a
    /// track — the positions a track centre may occupy while still standing on
    /// its own pad or just off its edge. This is the sealed gate's "first
    /// track-centre outside the pad edge", widened to a set so a pad with one
    /// usable corner is not decided by which of eight rays happened to sample it.
    fn seedFrom(self: *Flood, arena: Allocator, pd: PadView) Allocator.Error!void {
        const reach = self.width / 2;
        const lo = self.cellIndex(pd.shape.x0 - reach, pd.shape.y0 - reach);
        const hi = self.cellIndex(pd.shape.x1 + reach, pd.shape.y1 + reach);
        for (lo[1]..hi[1] + 1) |j| {
            for (lo[0]..hi[0] + 1) |i| {
                const c = j * self.g.nx + i;
                if (self.seen[c]) continue;
                self.seen[c] = true;
                // A blocked seed is recorded like any other frontier: on a pad
                // fenced flush, the whole fence lies inside this box and the
                // flood never gets far enough to meet it as a neighbour.
                if (self.blockedAt(self.g.cellX(i), self.g.cellY(j))) |wall| {
                    try self.noteWall(arena, wall);
                    continue;
                }
                try self.queue.append(arena, @intCast(c));
            }
        }
    }

    fn cellIndex(self: Flood, x: f64, y: f64) [2]usize {
        return .{
            floorIndex((x - self.g.ox) / probe_pitch_mm, self.g.nx),
            floorIndex((y - self.g.oy) / probe_pitch_mm, self.g.ny),
        };
    }

    /// The tightest foreign pad blocking a track centre at (x,y), or null when
    /// the position is legal. Only the cell's own bucket is read — every pad
    /// whose halo can reach here was filed in it.
    fn blockedAt(self: Flood, x: f64, y: f64) ?Frontier {
        const half = self.width / 2;
        var worst: ?Frontier = null;
        for (self.bucketAt(x, y)) |pi| {
            const q = self.board.pads[pi];
            if (q.net == @as(i32, @intCast(self.net)) or !q.onFace(self.side)) continue;
            const need = self.needAgainst(q, half);
            const have = padDist(q, x, y, need);
            if (have >= need) continue;
            if (worst == null or have < worst.?.have) {
                worst = .{ .ref = q.ref, .pad = q.number, .have = have, .need = need };
            }
        }
        return worst;
    }

    /// True when a via of this net's class fits at (x,y): clear of foreign copper
    /// on EITHER face (the barrel drills through both) and landing in no pad at
    /// all, its own net's included — a via in a pad is not an escape, it is a fab
    /// defect.
    fn viaFits(self: Flood, x: f64, y: f64) bool {
        for (self.bucketAt(x, y)) |pi| {
            const q = self.board.pads[pi];
            const need = if (q.net == @as(i32, @intCast(self.net))) 0 else self.needAgainst(q, self.via_r);
            const have = padDist(q, x, y, @max(need, probe_pitch_mm));
            if (have <= 0 or have < need) return false;
        }
        return true;
    }

    fn bucketAt(self: Flood, x: f64, y: f64) []const u32 {
        const b = self.board.bucketOf(self.g, x, y);
        return self.board.buckets[b[1] * self.board.bx + b[0]];
    }

    /// Flood the seeded queue; true the moment a reached cell is outside the hull
    /// or takes a via. Records the frontier obstructions on the way, so a failed
    /// run already knows who walled the pad in.
    fn run(self: *Flood, arena: Allocator) Allocator.Error!bool {
        var head: usize = 0;
        while (head < self.queue.items.len) : (head += 1) {
            const c = self.queue.items[head];
            const i = c % self.g.nx;
            const j = c / self.g.nx;
            const x = self.g.cellX(i);
            const y = self.g.cellY(j);
            if (self.g.outside(x, y)) return true;
            if (self.viaFits(x, y)) return true;
            try self.step(arena, i, j);
        }
        return false;
    }

    /// Enqueue the four orthogonal neighbours that are free; record the tightest
    /// obstruction of each that is not.
    fn step(self: *Flood, arena: Allocator, i: usize, j: usize) Allocator.Error!void {
        const steps = [4][2]i64{ .{ 1, 0 }, .{ -1, 0 }, .{ 0, 1 }, .{ 0, -1 } };
        for (steps) |d| {
            const a = @as(i64, @intCast(i)) + d[0];
            const b = @as(i64, @intCast(j)) + d[1];
            if (a < 0 or b < 0 or a >= self.g.nx or b >= self.g.ny) continue;
            const ai: usize = @intCast(a);
            const bi: usize = @intCast(b);
            const nc = bi * self.g.nx + ai;
            if (self.seen[nc]) continue;
            self.seen[nc] = true;
            if (self.blockedAt(self.g.cellX(ai), self.g.cellY(bi))) |wall| {
                try self.noteWall(arena, wall);
                continue;
            }
            try self.queue.append(arena, @intCast(nc));
        }
    }

    /// Keep the least-blocked obstruction per blocking part — the move that buys
    /// the escape most cheaply is the one against the smallest shortfall.
    fn noteWall(self: *Flood, arena: Allocator, wall: Frontier) Allocator.Error!void {
        for (self.walls.items) |*w| {
            if (!std.mem.eql(u8, w.ref, wall.ref)) continue;
            if (wall.have > w.have) {
                w.pad = wall.pad;
                w.have = wall.have;
                w.need = wall.need;
            }
            return;
        }
        try self.walls.append(arena, wall);
    }

    /// Describe the failure: the subject pad, the frontier that came closest to
    /// legal, and the MOVABLE parts responsible, cheapest to open first. The
    /// pad's own part is left out of `blockers` on purpose — it is real
    /// geometry, but a repair that pushed a part away from its own pad would be
    /// moving the victim, not the wall.
    fn report(self: *Flood, arena: Allocator, pd: PadView) Allocator.Error!Blocked {
        for (self.walls.items) |*w| w.own = std.mem.eql(u8, w.ref, pd.ref);
        std.mem.sort(Frontier, self.walls.items, {}, looserFirst);
        var movable: std.ArrayList(Frontier) = .empty;
        for (self.walls.items) |w| {
            if (w.own or movable.items.len >= max_blockers) continue;
            try movable.append(arena, w);
        }
        const refs = try arena.alloc([]const u8, movable.items.len);
        for (movable.items, refs) |w, *r| r.* = w.ref;
        const closest = self.walls.items;
        return .{
            .name = self.board.p.nets[self.net].name,
            .ref = pd.ref,
            .pad = pd.number,
            .mm = .{
                .have = if (closest.len > 0) closest[0].have else 0,
                .need = if (closest.len > 0) closest[0].need else self.defaultNeed(),
                .width = self.width,
                .clearance = self.board.p.rules.design.clearance,
            },
            .blocker = if (movable.items.len > 0)
                .{ .ref = movable.items[0].ref, .pad = movable.items[0].pad }
            else
                null,
            .blockers = refs,
        };
    }

    /// The room a track would have needed when no frontier was recorded at all
    /// (a pad whose every seed cell was already illegal).
    fn defaultNeed(self: Flood) f64 {
        return self.width / 2 + self.board.p.rules.design.clearance;
    }
};

fn padDist(q: PadView, x: f64, y: f64, slack: f64) f64 {
    return pad_shape.pointDist(q.shape.x0, q.shape.y0, q.shape.x1, q.shape.y1, q.shape.poly, x, y, slack);
}

/// Frontier order: the obstruction closest to already being legal first (it is
/// the cheapest to open), ref-des as the tie-break so the report is stable.
fn looserFirst(_: void, a: Frontier, b: Frontier) bool {
    if (a.have != b.have) return a.have > b.have;
    return std.mem.order(u8, a.ref, b.ref) == .lt;
}

/// The track width net `ni` is routed at — its `(net-class … (width …))` when it
/// declares one, else the board default, reduced to an ordinary legal
/// centreline when an unpoured rail will be widened adaptively after routing.
///
/// One deliberate difference: the router also exempts a rail whose copper an
/// EXISTING hand-drawn zone already carries, and a `Placement` holds no zones —
/// only the DECLARED planes are visible here (`plane_stitch.netHasPlane`, the
/// same predicate the escape exemption above uses). A rail poured by such a zone
/// is conservatively treated as absent here; the post-route clearance oracle
/// still judges its final sheet-aware fanout geometry exactly.
fn netWidth(p: Placement, ni: usize) f64 {
    var width = p.rules.design.track_width;
    if (ni < p.rules.net.len and p.rules.net[ni].width > 0) width = p.rules.net[ni].width;
    if (ni >= p.nets.len) return width;
    if (power_route_width.adaptiveTargetWidth(&.{}, p, ni, width) != null)
        return @max(p.rules.design.min_width, @min(width, p.rules.design.track_width));
    return power_route_width.exactWidth(&.{}, p, ni, width);
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;
const impedance = @import("impedance.zig");
const power_budget = @import("../eval/power_budget.zig");
const power_capacity = @import("power_capacity.zig");

fn tPad(n: []const u8, x: f64, y: f64, w: f64, h: f64) geometry.Pad {
    return .{ .number = n, .x = x, .y = y, .w = w, .h = h };
}

fn tPart(ref: []const u8, kind: optimizer.PartKind, at: [2]f64, half: [2]f64, pads: []const geometry.Pad) Part {
    return .{
        .ref_des = ref,
        .kind = kind,
        .hw = half[0],
        .hh = half[1],
        .pads = pads,
        .fallback = false,
        .x = at[0],
        .y = at[1],
    };
}

fn tPlacement(parts: []Part, nets: []const flat_netlist.FlatNet) Placement {
    return .{
        .parts = parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = nets,
        .rules = .{ .design = .{ .track_width = 0.127, .clearance = 0.127 } },
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -10,
        .miny = -10,
        .maxx = 10,
        .maxy = 10,
        .generated = true,
    };
}

/// Zero values so a fixture's arrays need no `undefined` placeholder before
/// `build` fills them.
const blank_part: Part = .{ .ref_des = "", .kind = .passive, .hw = 0, .hh = 0, .pads = &.{}, .fallback = false };
const blank_net: flat_netlist.FlatNet = .{ .name = "", .pins = &.{} };

/// A port pad at the bottom of a slot: three sides walled by one foreign part
/// `W`, the mouth crossed by two movable bars `WL`/`WR` leaving a lane of `gap`.
/// The pocket is deliberately too tight for a via, so `gap` alone decides — at 0
/// the port is sealed, at 0.8 mm a 0.127 mm track walks straight out.
///
/// Bars rather than real 0402s so the fixture states ONE thing — a lane of a
/// chosen width — instead of depending on where a footprint puts its pads.
const SlottedPort = struct {
    hub_pads: [1]geometry.Pad = .{tPad("1", 0, 0, 0.3, 0.3)},
    slot: [3]geometry.Pad = .{
        tPad("1", -0.55, 0, 0.3, 1.4),
        tPad("2", 0.55, 0, 0.3, 1.4),
        tPad("3", 0, -0.55, 1.4, 0.3),
    },
    mouth_l: [1]geometry.Pad = .{tPad("1", 0, 0, 0.7, 0.3)},
    mouth_r: [1]geometry.Pad = .{tPad("1", 0, 0, 0.7, 0.3)},
    parts: [4]Part = @splat(blank_part),
    pins: [1]flat_netlist.FlatPin = .{.{ .ref_des = "U1", .pin = "1" }},
    wall_pins: [5]flat_netlist.FlatPin = .{
        .{ .ref_des = "W", .pin = "1" },  .{ .ref_des = "W", .pin = "2" },
        .{ .ref_des = "W", .pin = "3" },  .{ .ref_des = "WL", .pin = "1" },
        .{ .ref_des = "WR", .pin = "1" },
    },
    nets: [2]flat_netlist.FlatNet = .{ blank_net, blank_net },

    /// The two mouth bars each run from the lane edge out to the slot's own
    /// outer extent (±0.7), so the mouth is exactly `gap` wide and nothing else
    /// about the pocket changes with it.
    fn build(self: *SlottedPort, gap: f64) Placement {
        const w = 0.7 - gap / 2;
        const c = 0.7 - w / 2;
        self.mouth_l = .{tPad("1", 0, 0, w, 0.3)};
        self.mouth_r = .{tPad("1", 0, 0, w, 0.3)};
        self.parts = .{
            tPart("U1", .hub, .{ 0, 0 }, .{ 0.2, 0.2 }, &self.hub_pads),
            tPart("W", .hub, .{ 0, 0 }, .{ 0.7, 0.7 }, &self.slot),
            tPart("WL", .passive, .{ -c, 0.55 }, .{ w / 2, 0.15 }, &self.mouth_l),
            tPart("WR", .passive, .{ c, 0.55 }, .{ w / 2, 0.15 }, &self.mouth_r),
        };
        self.nets = .{
            .{ .name = "SPI_SCK", .pins = &self.pins },
            .{ .name = "V_1V8", .pins = &self.wall_pins },
        };
        return tPlacement(&self.parts, &self.nets);
    }
};

/// A port pad in a CLOSED pocket roomy enough for a via: no corridor reaches the
/// hull, but a 0.4 mm via with 0.127 mm clearance fits beside the pad, so the
/// signal leaves by layer instead.
const ViaPocket = struct {
    hub_pads: [1]geometry.Pad = .{tPad("1", 0, 0, 0.3, 0.3)},
    ring: [4]geometry.Pad = .{
        tPad("1", -1.0, 0, 0.3, 2.6),
        tPad("2", 1.0, 0, 0.3, 2.6),
        tPad("3", 0, -1.0, 2.6, 0.3),
        tPad("4", 0, 1.0, 2.6, 0.3),
    },
    parts: [2]Part = @splat(blank_part),
    pins: [1]flat_netlist.FlatPin = .{.{ .ref_des = "U1", .pin = "1" }},
    wall_pins: [4]flat_netlist.FlatPin = .{
        .{ .ref_des = "W", .pin = "1" }, .{ .ref_des = "W", .pin = "2" },
        .{ .ref_des = "W", .pin = "3" }, .{ .ref_des = "W", .pin = "4" },
    },
    nets: [2]flat_netlist.FlatNet = .{ blank_net, blank_net },

    fn build(self: *ViaPocket) Placement {
        self.parts = .{
            tPart("U1", .hub, .{ 0, 0 }, .{ 0.2, 0.2 }, &self.hub_pads),
            tPart("W", .hub, .{ 0, 0 }, .{ 1.3, 1.3 }, &self.ring),
        };
        self.nets = .{
            .{ .name = "SPI_SDO", .pins = &self.pins },
            .{ .name = "V_1V8", .pins = &self.wall_pins },
        };
        return tPlacement(&self.parts, &self.nets);
    }
};

fn detectPorts(arena: Allocator, p: Placement) Allocator.Error![]Blocked {
    const ports = [_]bool{ true, false };
    return detect(arena, p, &ports);
}

// spec: placement/port_escape - a port net whose only pad is fenced in reports the pad and the parts walling it in
test "detect flags a port pad sealed into its slot" {
    var fx: SlottedPort = .{};
    const p = fx.build(0);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const found = try detectPorts(arena.allocator(), p);
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqualStrings("SPI_SCK", found[0].name);
    try testing.expectEqualStrings("U1", found[0].ref);
    try testing.expectEqualStrings("1", found[0].pad);
    try testing.expect(found[0].blockers.len > 0);
    try testing.expect(found[0].mm.need > found[0].mm.have);
    // The wall is a different part, so the repair has something it can move.
    const b = found[0].blocker orelse return error.TestExpectedEqual;
    try testing.expect(!std.mem.eql(u8, b.ref, "U1"));
}

// spec: placement/port_escape - a lane wide enough for the net's class proves the port escapes
test "detect clears a port pad with an open lane out of its slot" {
    var fx: SlottedPort = .{};
    // 0.8 mm of mouth: a 0.127 mm track needs 0.381 mm of lane, so the walk out
    // is legal with room to spare.
    const p = fx.build(0.8);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const found = try detectPorts(arena.allocator(), p);
    try testing.expectEqual(@as(usize, 0), found.len);
}

// spec: placement/port_escape - a reachable spot big enough for the net's class via proves the port escapes with no corridor at all
test "detect accepts a via as the escape from a closed pocket" {
    var fx: ViaPocket = .{};
    const p = fx.build();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(@as(usize, 0), (try detectPorts(arena.allocator(), p)).len);

    // The same pocket shrunk under a via's own footprint has neither escape, so
    // it is the via that cleared the roomy one and not the fixture's shape.
    var tight: SlottedPort = .{};
    const q = tight.build(0);
    try testing.expectEqual(@as(usize, 1), (try detectPorts(arena.allocator(), q)).len);
}

// spec: placement/port_escape - a plane-carried port net needs no surface escape
test "detect exempts a plane-carried port net" {
    var fx: SlottedPort = .{};
    const p = fx.build(0);
    // A board declaring no (stackup …) plants implicit ground planes, so the
    // same sealed pad on GND rejoins by pour via and the gate stays silent.
    var gnd_pins = [_]flat_netlist.FlatPin{.{ .ref_des = "U1", .pin = "1" }};
    var nets = [_]flat_netlist.FlatNet{
        .{ .name = "GND", .pins = &gnd_pins },
        p.nets[1],
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const grounded = tPlacement(p.parts, &nets);
    try testing.expectEqual(@as(usize, 0), (try detectPorts(arena.allocator(), grounded)).len);
}

// spec: placement/port_escape - the port mask names exactly the block's declared port nets, matching a flattened net on its leaf
test "portNets masks the block's declared ports and nothing else" {
    const ports = [_]env.Port{
        .{ .name = "SPI_SCK", .net = "SPI_SCK", .direction = "in" },
        .{ .name = "VOUT", .net = "V_3V3", .direction = "out" },
    };
    const block = env.DesignBlock{
        .name = "t",
        .instances = &.{},
        .nets = &.{},
        .ports = &ports,
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    const nets = [_]flat_netlist.FlatNet{
        .{ .name = "SPI_SCK", .pins = &.{} },
        .{ .name = "pll/V_3V3", .pins = &.{} },
        .{ .name = "LMX_CPOUT", .pins = &.{} },
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const mask = try portNets(arena.allocator(), &block, &nets);
    try testing.expectEqualSlices(bool, &.{ true, true, false }, mask);
}

// spec: placement/port_escape - detecting on the same placement twice reports the same findings
test "detect is deterministic on identical input" {
    var a: SlottedPort = .{};
    var b: SlottedPort = .{};
    const pa = a.build(0);
    const pb = b.build(0);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fa = try detectPorts(arena.allocator(), pa);
    const fb = try detectPorts(arena.allocator(), pb);
    try testing.expectEqual(fa.len, fb.len);
    for (fa, fb) |x, y| {
        try testing.expectEqualStrings(x.name, y.name);
        try testing.expectEqualStrings(x.ref, y.ref);
        try testing.expectEqual(x.mm.have, y.mm.have);
        try testing.expectEqual(x.blockers.len, y.blockers.len);
        for (x.blockers, y.blockers) |m, n| try testing.expectEqualStrings(m, n);
    }
}

// spec: placement/port_escape - an empty port mask leaves every net unexamined
test "detect with no port mask reports nothing" {
    var fx: SlottedPort = .{};
    const p = fx.build(0);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(@as(usize, 0), (try detect(arena.allocator(), p, &.{})).len);
}

// spec: placement/port_escape - a port corridor uses the adaptive power router's narrow search width while a plane-carried fanout keeps its authored width
test "netWidth mirrors adaptive power-route search geometry" {
    const rails = [_]power_budget.Rail{
        .{ .net = "V3P3", .load_max_a = 0.5, .any_max_load = true, .status = .no_source },
        .{ .net = "GND", .load_max_a = 0.5, .any_max_load = true, .status = .no_source },
    };
    const nets = [_]flat_netlist.FlatNet{
        .{ .name = "V3P3", .pins = &.{} },
        .{ .name = "GND", .pins = &.{} },
        .{ .name = "SPI_SCK", .pins = &.{} },
    };
    const planes = [_][]const u8{"GND"};
    var parts: [0]Part = .{};
    var p = tPlacement(&parts, &nets);
    p.rules = .{
        .design = .{ .track_width = 0.127, .clearance = 0.127 },
        .plane_nets = &planes,
        .copper_layers = 4,
        .physical = .{ .stack = .{ .layers = 4 }, .rails = &rails },
    };

    // Worst layer of a uniform four-layer stack is an inner one.
    const envelope = power_capacity.requiredTraceWidthMm(0.5, impedance.default_foil_mm, false).?;
    try testing.expect(envelope > p.rules.design.track_width);
    try testing.expectEqual(p.rules.design.track_width, netWidth(p, 0));
    // A plane-carried rail rejoins through its pour, so neither the router nor
    // this probe widens its surface copper.
    try testing.expectEqual(p.rules.design.track_width, netWidth(p, 1));
    try testing.expectEqual(p.rules.design.track_width, netWidth(p, 2));

    // An authored wide class remains the electrical target and does not seal
    // the port before the narrow centreline search runs.
    const class = [_]optimizer.NetRule{.{ .width = envelope * 2 }};
    p.rules.net = &class;
    try testing.expectEqual(p.rules.design.track_width, netWidth(p, 0));
}
