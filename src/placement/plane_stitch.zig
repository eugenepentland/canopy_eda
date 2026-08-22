//! How a PLANE-CARRIED net reaches its plane: the local surface loop first,
//! then one shared stitch via per ordinary island of that copper. Exposed
//! thermal lands may deliberately own an array; `router.planeNetCopper` places
//! those barrels before applying this module's electrical sharing rule.
//!
//! A net a plane carries (`netHasPlane`: ground and the dominant rail on the
//! implicit model, or exactly the declared `(stackup … (plane IDX "NET"))`
//! nets) is not routed by the maze at all. Every one of its pads simply drops a
//! via to the plane, and the plane does the joining. That is the right answer
//! for two pads on opposite corners of a board, and the wrong one for the pair
//! this module exists for: a bypass cap's leg and the IC pad it decouples,
//! sitting a millimetre and a half apart. Those two got a via each and no
//! copper between them, so the decoupling loop the placer spent its whole
//! objective tightening — cap hugging its bound pad — was then routed DOWN to
//! an inner layer and back up, and the board carried two barrels where one
//! serves. Measured on straps-synth-lmx2595 (2026-08-11): all six `V_3V3`
//! bypass caps bound to `U1` by `(decouples …)` were joined only through In2,
//! 15 rail vias for 15 rail pads, 30 ground vias for 30 ground pads.
//!
//! So the pass now draws the LOCAL SURFACE CONNECTION FIRST:
//!
//!   1. `bonds` reads the placement's own decoupling model (`optimizer.Loop` —
//!      the cap↔hub-pad binding `(decouples "IC" PIN)` and the per-pin
//!      shorthand produce, not a proximity guess) and names the pad pairs of
//!      THIS net that belong together: the power leg on the rail, the ground
//!      leg on ground. The same question asked twice, so no plane kind is a
//!      special case.
//!      A pair further apart than `via_share_max_mm` is not a direct bond. In a
//!      same-target capacitor bank, it may instead join a nearer already-bound
//!      cap by a local hop; a lone far cap remains independent.
//!   2. The caller draws each bond with the ordinary short-hookup machinery
//!      (`net_topology.padJoin` — a land-to-land run when the pair can take
//!      one, the outward-axis escape join otherwise), through the same
//!      DRC-grade probe every other direct leg uses. A bond that cannot be
//!      drawn simply is not, and its pads keep the two vias they had.
//!   3. `Web` records which bonds were drawn, and `served` then answers the via
//!      question: a pad whose own surface copper already reaches a same-net via
//!      within `via_share_max_mm` contributes NO new via — one barrel serves
//!      the island. `viaOrder` puts the bypass cap's own land first so that
//!      barrel lands where a hand router drops it (`capLand` then centres it ON
//!      that land), not out at the IC pad.
//!
//! Nothing here relaxes a clearance rule or invents copper: a bond is drawn
//! only if the probe passes, and a via is skipped only when a real via is
//! already reachable across real copper. Deterministic — bonds come out in
//! loop order, the via order is a fixed permutation, and `served` is a
//! relaxation over that same edge list, so a board routed twice stitches
//! identically.

const std = @import("std");
const optimizer = @import("optimizer.zig");
const pad_exit = @import("pad_exit.zig");
const pad_shape = @import("pad_shape.zig");
const pin_roles = @import("pin_roles.zig");
const implicit_plane = @import("implicit_plane.zig");

/// How far apart two pads may be for ONE via to serve both — the whole
/// definition of "local" here. It gates the bond twice, and BOTH gates measure
/// the same thing: a pair further apart than this (land centre to land centre)
/// gets no surface run drawn at all, and a pad whose bonded chain only reaches a
/// same-net via across more than this much — the spans of the bonds walked, plus
/// the stub that via hangs on — keeps its own via. So every run this pass draws
/// is one a single barrel can serve, and no run is drawn for nothing.
///
/// The two used to measure DIFFERENTLY, and that is exactly how the pass came to
/// plant both barrels on a pair it had just joined. The share walk charged each
/// bond the length of the copper `emitDogleg` had just emitted, which still
/// carries the entry laps INSIDE both lands that `pad_entry` deletes at the end
/// of the finish. Measured on straps-synth-lmx2595's `C_VCCBUF` ↔ `U1` pad 21
/// (2026-08-11, instrumented run): span 2.6712 mm — admitted — emitted 3.3781,
/// so the walk saw 3.3781 + 0.1181 of via stub = 3.4961 and refused to share,
/// while the copper that actually ships between the two lands is 2.6407 mm. The
/// span is within 1.2 % of the shipped copper and on the conservative side of
/// it, so charging the span is both the honest measure and the one the gate
/// already uses.
///
/// The trade: a second via gives its pad a direct drop to the plane instead of
/// a trace to somebody else's drop, and what that buys scales with the trace —
/// a 0.2 mm track runs about 0.8 nH/mm against roughly 0.4 nH for one barrel
/// through this stack. For the pair this exists for that cost is the right one
/// to pay: the barrel lands on the BYPASS CAP's land and the run carries the
/// rail on to the pin, which is the textbook "route power through the
/// decoupling cap" order — the HF loop (pin → cap → ground) is the run itself,
/// and the via sits in the supply feed the cap is there to stiffen. Over a
/// longer hop neither claim holds: the pads are no longer one local cluster,
/// the run would be copper the maze never planned, and the far pad's own drop
/// is worth its place.
///
/// 3.0 mm is that line, and it is the number this codebase already uses for a
/// neighbourly hop — `net_topology.land_run_max_mm`, past two neighbouring
/// 0402s (1.0–1.3 mm here) and well inside `direct_span_mm`. Measured against
/// the corpus's bound cap→pin legs (straps-synth-lmx2595 1.37–2.67 mm,
/// bcuda-synth-lmx2595 1.83–4.30, lmk05318b-clock 1.07–8.36, w55rp20
/// 1.46–12.66): it takes in every leg on the tight synth board and leaves the
/// long tail of the loose ones alone.
///
/// It is deliberately ABSOLUTE rather than scaled to the cluster's span: a rule
/// that grew with the span would share one barrel across an arbitrarily long
/// chain of bonds — the inductance it is trading away is a length, not a ratio.
pub const via_share_max_mm: f64 = 3.0;

/// Float slack for the world-position match between a loop's pad and the net's
/// terminal list. Both come from `optimizer.worldPadCenter` on the same part
/// and pad, so they agree bit for bit; the slack only absorbs a coordinate that
/// has been through a round trip.
const eps: f64 = 1e-6;

fn pointSegmentMm(x: f64, y: f64, ax: f64, ay: f64, bx: f64, by: f64) f64 {
    const dx = bx - ax;
    const dy = by - ay;
    const len2 = dx * dx + dy * dy;
    const t = if (len2 <= eps * eps) 0 else std.math.clamp(((x - ax) * dx + (y - ay) * dy) / len2, 0, 1);
    return std.math.hypot(x - (ax + t * dx), y - (ay + t * dy));
}

fn sharedEnd(comptime Track: type, a: Track, b: Track) bool {
    return (std.math.hypot(a.x1 - b.x1, a.y1 - b.y1) <= eps or
        std.math.hypot(a.x1 - b.x2, a.y1 - b.y2) <= eps or
        std.math.hypot(a.x2 - b.x1, a.y2 - b.y1) <= eps or
        std.math.hypot(a.x2 - b.x2, a.y2 - b.y2) <= eps);
}

/// Length of retained same-net surface copper from `pad` to an existing via.
/// This is the idempotence seam between the local carrier phase and the later
/// whole-board plane pass: a via-in-pad or its legal fanout stub is a source,
/// not permission to drill a duplicate beside it.
pub fn retainedStubMm(
    comptime Track: type,
    comptime Via: type,
    arena: std.mem.Allocator,
    maybe_pad: ?pad_shape.Shape,
    layer: u8,
    net: i32,
    tracks: []const Track,
    vias: []const Via,
) std.mem.Allocator.Error!?f64 {
    const pad = maybe_pad orelse return null;
    for (vias) |via| {
        if (via.net != net) continue;
        if (pad_shape.pointDist(pad.x0, pad.y0, pad.x1, pad.y1, pad.poly, via.x, via.y, std.math.inf(f64)) <= via.dia / 2 + eps) return 0;
    }
    const dist = try arena.alloc(f64, tracks.len);
    @memset(dist, std.math.inf(f64));
    for (tracks, 0..) |track, i| {
        if (track.net != net or track.layer != layer) continue;
        const starts = pad_shape.pointDist(pad.x0, pad.y0, pad.x1, pad.y1, pad.poly, track.x1, track.y1, std.math.inf(f64)) <= track.width / 2 + eps or
            pad_shape.pointDist(pad.x0, pad.y0, pad.x1, pad.y1, pad.poly, track.x2, track.y2, std.math.inf(f64)) <= track.width / 2 + eps;
        if (starts) dist[i] = std.math.hypot(track.x2 - track.x1, track.y2 - track.y1);
    }
    for (0..tracks.len) |_| {
        var moved = false;
        for (tracks, 0..) |a, ai| {
            if (!std.math.isFinite(dist[ai]) or a.net != net or a.layer != layer) continue;
            for (tracks, 0..) |b, bi| {
                if (b.net != net or b.layer != layer or !sharedEnd(Track, a, b)) continue;
                const next = dist[ai] + std.math.hypot(b.x2 - b.x1, b.y2 - b.y1);
                if (next < dist[bi]) {
                    dist[bi] = next;
                    moved = true;
                }
            }
        }
        if (!moved) break;
    }
    var best = std.math.inf(f64);
    for (tracks, dist) |track, mm| {
        if (!std.math.isFinite(mm)) continue;
        for (vias) |via| {
            if (via.net != net) continue;
            if (pointSegmentMm(via.x, via.y, track.x1, track.y1, track.x2, track.y2) <= (via.dia + track.width) / 2 + eps) best = @min(best, mm);
        }
    }
    return if (best <= via_share_max_mm) best else null;
}

/// Does `name` have a dedicated copper plane? No `(stackup …)` form ⇒ the
/// implicit model (`implicit_plane.carries`: ground + the dominant supply
/// rail); a declared stackup ⇒ exactly its `(plane …)` nets, case-insensitive
/// on the full or short name, so `(stackup 2)` declares none and ground routes.
pub fn netHasPlane(placement: optimizer.Placement, name: []const u8) bool {
    const planes = placement.rules.plane_nets orelse return implicit_plane.carries(placement.rules, name);
    for (planes) |pn| {
        if (std.ascii.eqlIgnoreCase(pn, name) or std.ascii.eqlIgnoreCase(pn, shortName(name))) return true;
    }
    return false;
}

/// How many DEDICATED inner planes a barrel on `name` crosses, read from the
/// DECLARATION alone. This is the fill-blind fallback for every seam that has
/// no plane contour to raster: the standalone/WASM DRC and the router's own
/// finish. Outer indices are signal faces (their pours are `netPourLayers`),
/// so only interior `(plane …)` entries count; with no `(stackup …)` at all the
/// implicit model contributes its single legacy plane.
///
/// It exists as one function because both readers must agree: the finish
/// decides which barrels are real connectivity destinations, and DRC decides
/// which sections reaching them carry nothing. Two spellings of "is this via
/// live" would have the finish keep copper the check calls dead, or delete
/// copper the check calls load-bearing.
pub fn declaredPlaneContacts(placement: optimizer.Placement, name: []const u8) u8 {
    if (!placement.rules.declaredStackup()) return @intFromBool(netHasPlane(placement, name));
    var count: u8 = 0;
    for (placement.rules.planes.declared) |plane| {
        if (plane.index == 1 or plane.index == placement.rules.copper_layers) continue;
        if (!std.ascii.eqlIgnoreCase(plane.net, name) and
            !std.ascii.eqlIgnoreCase(shortName(plane.net), shortName(name))) continue;
        count +|= 1;
    }
    return count;
}

/// Which outer signal layers (index 0 = top, 1 = bottom) carry `name` as a
/// declared pour — the faces where a same-net pad is already IN the copper.
/// Both false on the legacy implicit model (its planes are inner-only).
pub fn netPourLayers(placement: optimizer.Placement, name: []const u8) [2]bool {
    var out = [2]bool{ false, false };
    inline for ([_]optimizer.Side{ .top, .bottom }, 0..) |side, li| {
        if (placement.rules.pourNetOnSide(side)) |pn| {
            out[li] = std.ascii.eqlIgnoreCase(pn, name) or std.ascii.eqlIgnoreCase(pn, shortName(name));
        }
    }
    return out;
}

/// True when route terminal `c` already sits in one of its net's outer-layer
/// pours (`pour` from `netPourLayers`): an SMD pad on the poured face, or a
/// through-hole barrel, which meets a pour on either face.
pub fn padInPour(pour: [2]bool, c: pad_exit.NetPt) bool {
    if (c.thru) return pour[0] or pour[1];
    return pour[c.layer];
}

/// The leaf of a hierarchical net name (`amp1/VCC` → `VCC`), which is the other
/// spelling a declared plane may name its net by.
fn shortName(s: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, s, '/')) |i| s[i + 1 ..] else s;
}

/// Two pads of one plane-carried net that the placement's decoupling model
/// binds together, as indices into that net's terminal list. `cap` is the
/// bypass cap's own land — where the shared via belongs — and `hub` the IC pad
/// it serves. `mm` is the pair's span (land centre to land centre): the length
/// the gate admitted the pair on, and the length the share walk charges the run
/// realizing it (see `via_share_max_mm`).
pub const Bond = struct { cap: usize, hub: usize, mm: f64 };

const Candidate = struct { cap: usize, hub: usize, mm: f64 };

/// The bonded pad pairs of one plane-carried net: for every decoupling loop,
/// its power leg (cap's rail pad ↔ the hub pad it decouples) and its ground leg
/// (cap's ground pad ↔ the hub ground pad the return targets). A leg lands here
/// only when BOTH of its pads are terminals of the net being stitched, so the
/// rail's pass sees the power legs, ground's pass sees the ground legs, and no
/// caller has to know which is which.
///
/// A pair is LOCAL by `via_share_max_mm`. A cap within that distance of its hub
/// bonds directly. A farther cap in a bank may bond to a nearer cap already
/// connected to the SAME target pad, provided that cap-to-cap hop is local;
/// this forms the ordinary pin -> smallest cap -> larger caps surface chain.
/// The web's separate path-length gate still decides where another via is
/// needed, so a chain can never share one barrel beyond the same bound.
///
/// A plain NC/N/C pad which the author deliberately assigned to the same net as
/// a real ground pad on its package is another local bond. The real ground is
/// the preferred-via (`cap`) side, so an exposed paddle's thermal field serves
/// the optional land through surface copper instead of every NC pad drilling a
/// duplicate barrel. A DNC/DNU/reserved pad is never tagged `optional_nc` and
/// cannot enter this rule.
pub fn bonds(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    pts: []const pad_exit.NetPt,
) std.mem.Allocator.Error![]const Bond {
    var candidates: std.ArrayList(Candidate) = .empty;
    for (placement.loops) |loop| {
        if (loop.cap >= placement.parts.len or loop.hub >= placement.parts.len) continue;
        const cap = placement.parts[loop.cap];
        const hub = placement.parts[loop.hub];
        const legs = [2][2]optimizer.PadRect{
            .{ loop.cap_pwr, loop.hub_pwr_pin },
            .{ loop.cap_gnd, loop.hub_gnd_pin },
        };
        for (legs) |leg| {
            const a = terminalAt(pts, cap, leg[0]) orelse continue;
            const b = terminalAt(pts, hub, leg[1]) orelse continue;
            if (a == b or pts[a].layer != pts[b].layer or candidateKnown(candidates.items, a, b)) continue;
            try candidates.append(arena, .{
                .cap = a,
                .hub = b,
                .mm = std.math.hypot(pts[b].x - pts[a].x, pts[b].y - pts[a].y),
            });
        }
    }

    // Optional package grounds are semantic, not proximity guesses: both roles
    // come from this exact part's pinout. Choose the nearest real ground pad on
    // the same face, and put that real return on the preferred-via side.
    for (pts, 0..) |pt, optional_i| {
        if (terminalClass(placement, pt) != .optional_nc) continue;
        var best: ?Candidate = null;
        for (pts, 0..) |anchor, ground_i| {
            if (terminalClass(placement, anchor) != .ground or anchor.layer != pt.layer) continue;
            if (!std.mem.eql(u8, anchor.ref_des, pt.ref_des)) continue;
            const mm = std.math.hypot(anchor.x - pt.x, anchor.y - pt.y);
            if (best != null and mm >= best.?.mm) continue;
            best = .{ .cap = ground_i, .hub = optional_i, .mm = mm };
        }
        const candidate = best orelse continue;
        if (!candidateKnown(candidates.items, candidate.cap, candidate.hub)) try candidates.append(arena, candidate);
    }

    var out: std.ArrayList(Bond) = .empty;
    const parent = try arena.alloc(usize, pts.len);
    for (parent, 0..) |*slot, i| slot.* = i;
    for (candidates.items) |candidate| {
        if (candidate.mm > via_share_max_mm) continue;
        try out.append(arena, .{ .cap = candidate.cap, .hub = candidate.hub, .mm = candidate.mm });
        unite(parent, candidate.cap, candidate.hub);
    }
    var changed = true;
    while (changed) {
        changed = false;
        for (candidates.items) |candidate| {
            if (root(parent, candidate.cap) == root(parent, candidate.hub)) continue;
            var best: ?Candidate = null;
            for (candidates.items) |anchor| {
                if (anchor.cap == candidate.cap or anchor.hub != candidate.hub) continue;
                if (root(parent, anchor.cap) != root(parent, candidate.hub)) continue;
                const mm = std.math.hypot(pts[anchor.cap].x - pts[candidate.cap].x, pts[anchor.cap].y - pts[candidate.cap].y);
                if (mm > via_share_max_mm or (best != null and mm >= best.?.mm)) continue;
                best = .{ .cap = candidate.cap, .hub = anchor.cap, .mm = mm };
            }
            const hop = best orelse continue;
            try out.append(arena, .{ .cap = hop.cap, .hub = hop.hub, .mm = hop.mm });
            unite(parent, hop.cap, hop.hub);
            changed = true;
        }
    }
    return out.items;
}

/// Look up a routed terminal's library role without widening the generic
/// terminal or obstacle types. Missing pinout metadata preserves legacy
/// behavior by classifying the terminal as ordinary.
fn terminalClass(placement: optimizer.Placement, pt: pad_exit.NetPt) pin_roles.PinClass {
    for (placement.parts, 0..) |part, i| {
        if (!std.mem.eql(u8, part.ref_des, pt.ref_des)) continue;
        if (i >= placement.pin_roles.len) return .other;
        return placement.pin_roles[i].classOf(pt.pin);
    }
    return .other;
}

/// Whether `obstacle_i` in `router.buildObstacles` order is an optional NC
/// land. Keeping the role lookup separate avoids inflating every obstacle with
/// metadata needed only by the final ground-via-distance pass.
pub fn optionalNcObstacle(placement: optimizer.Placement, obstacle_i: usize) bool {
    var first: usize = 0;
    for (placement.parts, 0..) |part, part_i| {
        const past = first + part.pads.len;
        if (obstacle_i < past) {
            if (part_i >= placement.pin_roles.len) return false;
            return placement.pin_roles[part_i].classOf(part.pads[obstacle_i - first].number) == .optional_nc;
        }
        first = past;
    }
    return false;
}

fn candidateKnown(list: []const Candidate, a: usize, b: usize) bool {
    for (list) |candidate| if (candidate.cap == a and candidate.hub == b) return true;
    return false;
}

fn root(parent: []const usize, start: usize) usize {
    var at = start;
    while (parent[at] != at) at = parent[at];
    return at;
}

fn unite(parent: []usize, a: usize, b: usize) void {
    const ar = root(parent, a);
    const br = root(parent, b);
    if (ar != br) parent[@max(ar, br)] = @min(ar, br);
}

/// The terminal index of part `p`'s pad `rect`, or null when this net has no
/// such terminal. A zero-sized rect is the loop model's "unset" (a fixture, or
/// a hub with no ground pad) and never matches.
fn terminalAt(pts: []const pad_exit.NetPt, p: optimizer.Part, rect: optimizer.PadRect) ?usize {
    if (rect.w <= 0 or rect.h <= 0) return null;
    const c = optimizer.worldPadCenter(&p, rect.x, rect.y);
    for (pts, 0..) |pt, i| {
        if (!std.mem.eql(u8, pt.ref_des, p.ref_des)) continue;
        if (@abs(pt.x - c[0]) <= eps and @abs(pt.y - c[1]) <= eps) return i;
    }
    return null;
}

/// The order the stitch pass offers one net's pads a via: every bonded CAP land
/// first (in terminal order), then everything else (in terminal order).
///
/// Order decides WHERE the shared barrel lands, because the first pad to ask
/// gets it and the rest of its island are then served. A bypass cap's own land
/// is the hand-router answer — the drop to the plane sits beside the cap and
/// the trace runs on to the pin, so the cap sees the pin directly. A net with
/// no bonds gets the identity permutation, so its stitching is unchanged.
pub fn viaOrder(
    arena: std.mem.Allocator,
    n: usize,
    bs: []const Bond,
) std.mem.Allocator.Error![]const usize {
    if (bs.len == 0) return identity(arena, n);
    const out = try arena.alloc(usize, n);
    const taken = try arena.alloc(bool, n);
    @memset(taken, false);
    var k: usize = 0;
    for (0..n) |i| {
        for (bs) |bond| {
            if (bond.cap != i) continue;
            out[k] = i;
            taken[i] = true;
            k += 1;
            break;
        }
    }
    for (0..n) |i| {
        if (taken[i]) continue;
        out[k] = i;
        k += 1;
    }
    return out;
}

fn identity(arena: std.mem.Allocator, n: usize) std.mem.Allocator.Error![]const usize {
    const out = try arena.alloc(usize, n);
    for (out, 0..) |*slot, i| slot.* = i;
    return out;
}

/// One drawn bond: the two terminals it joined and the span it was charged
/// (`Bond.mm` — see `via_share_max_mm` for why the span and not the emitted
/// polyline).
const Edge = struct { a: usize, b: usize, mm: f64 };

/// What one plane-carried net's surface copper joins, and which of its pads
/// already own a via — the state the share rule is decided on.
pub const Web = struct {
    edges: std.ArrayList(Edge),
    /// Per pad: the length of the stub from its land to its OWN via, or
    /// infinity when it has none.
    via_mm: []f64,
    /// Scratch distances for `served`, owned so the query allocates nothing.
    dist: []f64,

    /// A web over `n` terminals with no copper drawn and no via placed. The two
    /// per-terminal arrays are one allocation split in half — same shape, same
    /// lifetime, and nothing to unwind if it fails.
    pub fn init(arena: std.mem.Allocator, n: usize) std.mem.Allocator.Error!Web {
        const buf = try arena.alloc(f64, 2 * n);
        @memset(buf[0..n], std.math.inf(f64));
        return .{ .edges = .empty, .via_mm = buf[0..n], .dist = buf[n..] };
    }

    /// Record that terminals `a` and `b` were joined by a run charged `mm` (the
    /// bond's span).
    pub fn drew(self: *Web, arena: std.mem.Allocator, a: usize, b: usize, mm: f64) std.mem.Allocator.Error!void {
        try self.edges.append(arena, .{ .a = a, .b = b, .mm = mm });
    }

    /// Record that terminal `pad` got its own via, `stub_mm` of copper away.
    pub fn placedVia(self: *Web, pad: usize, stub_mm: f64) void {
        self.via_mm[pad] = @min(self.via_mm[pad], stub_mm);
    }

    /// Is terminal `i` the cap land of a bond this pass actually DREW — the pad
    /// whose barrel the rest of that cluster shares? A bond the probe refused is no
    /// cluster and gets no say: its pads keep the sites the ordinary ladder picks,
    /// which is what keeps this rule from moving stitch vias all over a board whose
    /// bonds are all refused (barracuda's ground, straps-synth's ground).
    ///
    /// The caller sites THAT barrel on the land's own centre when the land admits it
    /// (clearance to foreign copper and to every barrel already down; the annular
    /// ring is the via's own geometry and is unaffected by where it stands), falling
    /// back to the ordinary ladder — grid-snapped anchor, the in-pad scan, then the
    /// outward fan — when it does not. This is the one placement rule the literature
    /// is unanimous on: the connection inductance a bypass cap actually buys is set
    /// by the loop from its land to the plane. LearnEMC's worked examples put a
    /// tight land-to-plane connection near 0.6 nH and the same cap reached by a
    /// trace out to a via at 15.7 nH; Sierra Circuits states the order outright —
    /// connect the component pin to the capacitor first and then to the via, with
    /// vias within or immediately adjacent to the capacitor pads; Axotron's
    /// measurements put a barrel IN the land at 0.44 nH against 0.63 nH beside it.
    /// It is also what removes the stub the share walk used to charge: a via ON the
    /// land needs no copper to reach it, so the cluster's budget is spent entirely
    /// on the run that carries the rail to the pin.
    ///
    /// Nothing here makes a via-in-pad legal that was not already: a same-net barrel
    /// standing in its own land has always been legal copper here — `findGroundVia`
    /// aims at the pad anchor first and `plane_via.InPad` searches the land itself —
    /// and the one rule that names via-in-pad, `routability_lint`'s
    /// `via-in-pad-conflict`, is a PLACEMENT warning about two neighbouring pads
    /// that cannot both host one. This only stops the barrel drifting off centre by
    /// a grid step.
    pub fn capLand(self: *const Web, pad: usize) bool {
        for (self.edges.items) |e| {
            if (e.a == pad) return true;
        }
        return false;
    }

    /// Is `pad` already served — does its own surface copper reach a placed
    /// same-net via within `via_share_max_mm` of bonded span plus stub?
    ///
    /// The walk is a relaxation over the drawn edges (a handful per net, and a
    /// forest in practice), so it needs no priority queue and no allocation;
    /// a pad in no bond reaches nothing but itself.
    pub fn served(self: *Web, pad: usize) bool {
        if (self.edges.items.len == 0) return self.via_mm[pad] <= via_share_max_mm;
        @memset(self.dist, std.math.inf(f64));
        self.dist[pad] = 0;
        for (0..self.edges.items.len) |_| {
            var moved = false;
            for (self.edges.items) |e| {
                if (self.dist[e.a] + e.mm < self.dist[e.b]) {
                    self.dist[e.b] = self.dist[e.a] + e.mm;
                    moved = true;
                }
                if (self.dist[e.b] + e.mm < self.dist[e.a]) {
                    self.dist[e.a] = self.dist[e.b] + e.mm;
                    moved = true;
                }
            }
            if (!moved) break;
        }
        for (self.dist, self.via_mm) |d, v| {
            if (d + v <= via_share_max_mm) return true;
        }
        return false;
    }
};

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

const geometry = @import("geometry.zig");

/// A bypass cap 2 mm below an IC: cap pad 1 on the rail with the IC's pad 7,
/// cap pad 2 on ground with the IC's pad 8, bound by the loop model.
const bond_fixture = struct {
    const cap_pwr = optimizer.PadRect{ .x = -0.27, .y = 0, .w = 0.54, .h = 0.64 };
    const cap_gnd = optimizer.PadRect{ .x = 0.27, .y = 0, .w = 0.54, .h = 0.64 };
    const hub_pwr = optimizer.PadRect{ .x = 0, .y = -0.5, .w = 0.3, .h = 0.85 };
    const hub_gnd = optimizer.PadRect{ .x = 0, .y = 0.5, .w = 0.3, .h = 0.85 };
    var cap_pads = [_]geometry.Pad{
        .{ .number = "1", .x = cap_pwr.x, .y = cap_pwr.y, .w = cap_pwr.w, .h = cap_pwr.h },
        .{ .number = "2", .x = cap_gnd.x, .y = cap_gnd.y, .w = cap_gnd.w, .h = cap_gnd.h },
    };
    var hub_pads = [_]geometry.Pad{
        .{ .number = "7", .x = hub_pwr.x, .y = hub_pwr.y, .w = hub_pwr.w, .h = hub_pwr.h },
        .{ .number = "8", .x = hub_gnd.x, .y = hub_gnd.y, .w = hub_gnd.w, .h = hub_gnd.h },
    };
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &hub_pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.5, .hh = 0.4, .pads = &cap_pads, .fallback = false, .x = 0, .y = 2 },
    };
    var loops = [_]optimizer.Loop{.{
        .cap = 1,
        .hub = 0,
        .cap_pwr = cap_pwr,
        .cap_gnd = cap_gnd,
        .hub_pwr = &.{},
        .hub_pwr_pin = hub_pwr,
        .hub_gnd = &.{},
        .hub_gnd_pin = hub_gnd,
    }};
};

fn bondFixture() optimizer.Placement {
    return .{
        .parts = &bond_fixture.parts,
        .links = &.{},
        .loops = &bond_fixture.loops,
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -5,
        .miny = -5,
        .maxx = 5,
        .maxy = 5,
        .generated = true,
    };
}

/// That fixture's rail terminals: the cap's pad 1 and the hub's pad 7.
fn railPts() [2]pad_exit.NetPt {
    return .{
        .{ .x = 0, .y = -0.5, .layer = 0, .ref_des = "U1", .pin = "7" },
        .{ .x = -0.27, .y = 2, .layer = 0, .ref_des = "C1", .pin = "1" },
    };
}

// spec: placement/plane-stitch - a decoupling loop's power leg bonds the cap's rail land to the hub pad it decouples
test "the rail leg of a loop is a bond on the rail net" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const pts = railPts();
    const bs = try bonds(arena_inst.allocator(), bondFixture(), &pts);
    try testing.expectEqual(@as(usize, 1), bs.len);
    // the CAP land is the bond's cap side, whichever order the terminals came in
    try testing.expectEqualStrings("C1", pts[bs[0].cap].ref_des);
    try testing.expectEqualStrings("U1", pts[bs[0].hub].ref_des);
}

// spec: placement/plane-stitch - a loop's ground leg bonds on the ground net by the same rule, so no plane kind is a special case
test "the ground leg of a loop is a bond on the ground net" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const pts = [_]pad_exit.NetPt{
        .{ .x = 0, .y = 0.5, .layer = 0, .ref_des = "U1", .pin = "8" },
        .{ .x = 0.27, .y = 2, .layer = 0, .ref_des = "C1", .pin = "2" },
    };
    const bs = try bonds(arena_inst.allocator(), bondFixture(), &pts);
    try testing.expectEqual(@as(usize, 1), bs.len);
    try testing.expectEqualStrings("C1", pts[bs[0].cap].ref_des);
    try testing.expectEqualStrings("U1", pts[bs[0].hub].ref_des);
}

// spec: placement/plane-stitch - a grounded NC pad bonds to its package's real ground pad with the real return offered the shared via, while an ordinary unclassified pad does not
// spec: placement/plane-stitch - obstacle-order role lookup identifies only optional NC lands so the router's ground-via maximum cannot recreate their suppressed barrels
test "an optional grounded NC pad shares its package real-ground stitch" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var role = pin_roles.PartRoles{};
    try role.map.put(arena, "17", .ground);
    try role.map.put(arena, "1", .optional_nc);
    try role.map.put(arena, "7", .optional_nc);
    var roles = [_]pin_roles.PartRoles{ role, .{} };
    var placement = bondFixture();
    placement.pin_roles = &roles;
    try testing.expect(optionalNcObstacle(placement, 0));
    try testing.expect(!optionalNcObstacle(placement, 1));
    try testing.expect(!optionalNcObstacle(placement, 2));
    try testing.expect(!optionalNcObstacle(placement, 99));
    const pts = [_]pad_exit.NetPt{
        .{ .x = 0, .y = 0, .layer = 0, .ref_des = "U1", .pin = "17" },
        .{ .x = 1.4, .y = 0, .layer = 0, .ref_des = "U1", .pin = "1" },
        .{ .x = -1.4, .y = 0, .layer = 0, .ref_des = "U1", .pin = "3" },
    };
    const bs = try bonds(arena, placement, &pts);
    try testing.expectEqual(@as(usize, 1), bs.len);
    try testing.expectEqual(@as(usize, 0), bs[0].cap); // real GND owns the via
    try testing.expectEqual(@as(usize, 1), bs[0].hub); // optional NC shares it
    const order = try viaOrder(arena_inst.allocator(), pts.len, bs);
    try testing.expectEqual(@as(usize, 0), order[0]);
}

// spec: placement/plane-stitch - a lone leg whose pads are farther apart than via_share_max_mm is no bond, so no run is drawn that one via could not serve
test "a leg longer than the share distance is not a bond" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    // the same rail leg, with the cap pushed a hair past the distance
    var pts = railPts();
    pts[1].y = pts[0].y + via_share_max_mm + 0.1;
    var far = bondFixture();
    var parts = [_]optimizer.Part{ bond_fixture.parts[0], bond_fixture.parts[1] };
    parts[1].y = pts[1].y;
    far.parts = &parts;
    try testing.expectEqual(@as(usize, 0), (try bonds(arena_inst.allocator(), far, &pts)).len);
}

// spec: placement/plane-stitch - a bond carries the pair's span, so the share walk charges a run the same length the gate admitted it on
test "a bond is charged the span its gate measured" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const pts = railPts();
    const bs = try bonds(arena_inst.allocator(), bondFixture(), &pts);
    const want = std.math.hypot(pts[1].x - pts[0].x, pts[1].y - pts[0].y);
    try testing.expectApproxEqAbs(want, bs[0].mm, 1e-12);
    try testing.expect(bs[0].mm <= via_share_max_mm); // the gate's own measure
    // and the walk over that charge serves the far pad from one barrel
    var web = try Web.init(arena_inst.allocator(), pts.len);
    try web.drew(arena_inst.allocator(), bs[0].cap, bs[0].hub, bs[0].mm);
    web.placedVia(bs[0].cap, 0); // centred in the cap's own land: no stub
    try testing.expect(web.served(bs[0].hub));
    // …and it is the CAP's land the caller centres that barrel on, only because
    // the run was drawn: a refused bond is no cluster and keeps the ladder.
    try testing.expect(web.capLand(bs[0].cap));
    try testing.expect(!web.capLand(bs[0].hub));
    var refused = try Web.init(arena_inst.allocator(), pts.len);
    try testing.expect(!refused.capLand(bs[0].cap));
}

// spec: placement/plane-stitch - a leg whose pads are not both terminals of the net being stitched is no bond, so a rail's pass never draws a ground leg
test "a leg with a pad outside this net is not a bond" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    // only the hub's rail pad is on this net — the cap's leg is elsewhere
    const pts = [_]pad_exit.NetPt{.{ .x = 0, .y = -0.5, .layer = 0, .ref_des = "U1", .pin = "7" }};
    const bs = try bonds(arena_inst.allocator(), bondFixture(), &pts);
    try testing.expectEqual(@as(usize, 0), bs.len);
}

// spec: placement/plane-stitch - the bonded cap land is offered a via before any other pad, so the shared barrel lands beside the cap
test "via order puts the bonded cap land first" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const bs = [_]Bond{.{ .cap = 2, .hub = 0, .mm = 1 }};
    const order = try viaOrder(arena_inst.allocator(), 4, &bs);
    try testing.expectEqualSlices(usize, &.{ 2, 0, 1, 3 }, order);
    // no bond at all ⇒ the terminal order the pass always used
    const plain = try viaOrder(arena_inst.allocator(), 3, &.{});
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, plain);
}

// spec: placement/plane-stitch - a pad whose surface copper reaches a same-net via within via_share_max_mm needs no via of its own
test "a pad served across drawn copper contributes no via" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    var web = try Web.init(arena_inst.allocator(), 3);
    // a bond well inside the share distance, and a 0.1 mm stub to the via
    try web.drew(arena_inst.allocator(), 0, 1, via_share_max_mm - 0.6);
    try testing.expect(!web.served(0));
    web.placedVia(0, 0.1);
    try testing.expect(web.served(0));
    try testing.expect(web.served(1));
    try testing.expect(!web.served(2)); // no copper to either
}

// Retained local fanout copper exercises the same idempotence contract as the
// end-to-end hierarchical-route regression.
test "retained local carrier drops are served idempotently" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const Track = struct { x1: f64, y1: f64, x2: f64, y2: f64, width: f64, layer: u8, net: i32 };
    const Via = struct { x: f64, y: f64, dia: f64, net: i32 };
    const pad = pad_shape.Shape{ .x0 = -0.2, .y0 = -0.2, .x1 = 0.2, .y1 = 0.2 };
    const centred = [_]Via{.{ .x = 0, .y = 0, .dia = 0.4, .net = 0 }};
    try testing.expectEqual(@as(?f64, 0), try retainedStubMm(Track, Via, arena_inst.allocator(), pad, 0, 0, &.{}, &centred));

    const stub = [_]Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 0.5, .y2 = 0, .width = 0.2, .layer = 0, .net = 0 },
        .{ .x1 = 0.5, .y1 = 0, .x2 = 1, .y2 = 0, .width = 0.2, .layer = 0, .net = 0 },
    };
    const fanned = [_]Via{.{ .x = 1, .y = 0, .dia = 0.4, .net = 0 }};
    try testing.expectApproxEqAbs(@as(f64, 1), (try retainedStubMm(Track, Via, arena_inst.allocator(), pad, 0, 0, &stub, &fanned)).?, eps);
    try testing.expect((try retainedStubMm(Track, Via, arena_inst.allocator(), pad, 0, 1, &stub, &fanned)) == null);
}

// spec: placement/plane-stitch - a pad further along the copper than via_share_max_mm keeps its own via
test "a pad past the share distance keeps its own via" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    var web = try Web.init(arena_inst.allocator(), 3);
    // two hops, each inside the distance, together past it — the walk measures
    // the copper actually drawn, so the far end earns its own drop
    try web.drew(arena_inst.allocator(), 0, 1, via_share_max_mm * 0.6);
    try web.drew(arena_inst.allocator(), 1, 2, via_share_max_mm * 0.6);
    web.placedVia(0, 0.1);
    try testing.expect(web.served(1));
    try testing.expect(!web.served(2));
}

// spec: placement/plane-stitch - a net with no drawn copper shares nothing, so every pad of it is stitched exactly as before
test "with no bonds drawn every pad still asks for its own via" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    var web = try Web.init(arena_inst.allocator(), 3);
    web.placedVia(0, 0.1);
    try testing.expect(web.served(0));
    try testing.expect(!web.served(1));
    try testing.expect(!web.served(2));
}

// spec: placement/plane-stitch - the implicit model plants a plane on ground and the dominant rail, a declared stackup on exactly its declared nets
test "which nets a plane carries" {
    const implicit = optimizer.Placement{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .rules = .{ .planes = .{ .implicit_rail = "V_3V3" } },
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 1,
        .maxy = 1,
        .generated = true,
    };
    try testing.expect(netHasPlane(implicit, "GND"));
    try testing.expect(netHasPlane(implicit, "V_3V3"));
    try testing.expect(!netHasPlane(implicit, "SPI_SCK"));
    var declared = implicit;
    declared.rules.plane_nets = &.{"GND"};
    try testing.expect(netHasPlane(declared, "GND"));
    try testing.expect(!netHasPlane(declared, "V_3V3"));
}

// spec: placement/plane-stitch - a barrel's declared plane contacts count only interior planes of its own net, and fall back to the implicit model's single plane when no stackup is declared
test "declared plane contacts count interior same-net planes" {
    const implicit = optimizer.Placement{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .rules = .{ .planes = .{ .implicit_rail = "V_3V3" } },
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 1,
        .maxy = 1,
        .generated = true,
    };
    try testing.expectEqual(@as(u8, 1), declaredPlaneContacts(implicit, "GND"));
    try testing.expectEqual(@as(u8, 0), declaredPlaneContacts(implicit, "SPI_SCK"));

    // A four-layer stackup: In1/In2 are interior, the outer indices are signal
    // faces whose copper is a pour rather than a barrel contact.
    const planes = [_]optimizer.PlaneAt{
        .{ .index = 2, .net = "GND" },
        .{ .index = 3, .net = "amp1/V_3V3" },
        .{ .index = 4, .net = "GND" },
    };
    var declared = implicit;
    declared.rules.plane_nets = &.{ "GND", "V_3V3" };
    declared.rules.copper_layers = 4;
    declared.rules.planes = .{ .declared = &planes };
    try testing.expectEqual(@as(u8, 1), declaredPlaneContacts(declared, "GND"));
    try testing.expectEqual(@as(u8, 1), declaredPlaneContacts(declared, "V_3V3"));
    try testing.expectEqual(@as(u8, 0), declaredPlaneContacts(declared, "SPI_SCK"));
}

// spec: placement/plane-stitch - a pad already sitting in an outer-layer pour of its own net is stitched by the pour, not by a via
test "a pad in its own net's outer pour needs no via" {
    const smd_top = pad_exit.NetPt{ .x = 0, .y = 0, .layer = 0 };
    const smd_bottom = pad_exit.NetPt{ .x = 0, .y = 0, .layer = 1 };
    const thru = pad_exit.NetPt{ .x = 0, .y = 0, .layer = 0, .thru = true };
    try testing.expect(padInPour(.{ true, false }, smd_top));
    try testing.expect(!padInPour(.{ true, false }, smd_bottom));
    try testing.expect(padInPour(.{ false, true }, thru)); // a barrel meets either face
    try testing.expect(!padInPour(.{ false, false }, thru));
}
