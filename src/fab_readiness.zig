//! Pre-fab correctness gate (audit item 0.1). Before the Gerber ZIP goes to a
//! board house, this module runs a fab-readiness report over the SAME blessed
//! placement + persisted copper the export writes, so the check and the files
//! always describe the same board.
//!
//! It is deliberately a pure function of `(placement, copper)` — no server, no
//! disk — so it is unit-testable in isolation and shares the export's frame /
//! net / plane model exactly. The serve handler wraps it: clean → download,
//! errors → HTTP 409 (unless `?force=1`), warnings → an informational modal.
//!
//! Errors (block the export): a multi-location net whose persisted copper does
//! not connect all its pads (an airwire remaining — plane/pour nets count as
//! connected), an error-severity DRC violation against the persisted copper at
//! the current poses, a part unplaced / stranded in the off-board staging band,
//! a via with drill = 0 (a legacy synthetic via that would emit a bad Excellon
//! hole), and a missing board outline (the profile would fall back to the parts
//! bbox — a guess a fab shouldn't cut to). Warnings (informational): warning-
//! severity DRC findings (courtyard/mask-sliver/silk-over-pad), DNP parts kept
//! in the centroid when `?dnp=keep` overrides the drop-by-default, a malformed
//! (< 3 point) custom outline that fell back to the bounding rect, and a layout
//! coming from the optimizer cache rather than a saved snapshot.

const std = @import("std");
const optimizer = @import("placement/optimizer.zig");
const router = @import("placement/router.zig");
const drc = @import("placement/drc.zig");
const pour = @import("placement/pour.zig");
const export_gerber = @import("export_gerber.zig");
const export_fab = @import("export_fab.zig");
const pad_shape = @import("placement/pad_shape.zig");

/// A part is treated as off-board (staged, not on the real board) when its
/// courtyard centre sits more than this far outside the board outline — the
/// same "clearly off-board" band the `board_edge` DRC skips, promoted here to
/// an explicit export-blocking error.
pub const STAGING_BAND_MM: f64 = 10.0;

/// Copper touching a pad's box within this slack (mm) is taken to electrically
/// connect it — a routed track's endpoint lands on the pad centre but the
/// stored value may be a hair off after snapping/serialization, and a via/pad
/// that merely abuts counts as connected for airwire purposes.
const TOUCH_SLACK_MM: f64 = 0.02;

/// One finding. `id` is a stable machine key (for the viewer to group/style),
/// `message` the human line, and the optional net/ref/count give the modal
/// something concrete to point at.
pub const Item = struct {
    id: []const u8,
    message: []const u8,
    net: ?[]const u8 = null,
    ref: ?[]const u8 = null,
    count: usize = 0,
};

/// Summary counts for the report header + the `stats` JSON object.
pub const Stats = struct {
    parts: usize = 0,
    nets: usize = 0,
    tracks: usize = 0,
    vias: usize = 0,
    /// Nets that needed routing (pads in ≥2 board locations, not plane-carried).
    routable_nets: usize = 0,
    /// Of those, how many are fully connected by the persisted copper.
    connected_nets: usize = 0,
    drc_violations: usize = 0,
    has_outline: bool = false,
    dnp_parts: usize = 0,
};

/// The full report: two severity buckets + stats. `ok()` (no errors) is what
/// gates the export.
pub const Report = struct {
    errors: []const Item,
    warnings: []const Item,
    stats: Stats,

    /// True when nothing blocks the export (warnings alone never block).
    pub fn ok(self: Report) bool {
        return self.errors.len == 0;
    }
};

/// Extra context the serve handler knows but the placement doesn't: whether the
/// blessed layout came from a saved/starred snapshot (vs. the optimizer cache),
/// and whether the centroid CSV keeps DNP parts (`?dnp=keep`). Defaults keep the
/// pure/test path free of server concerns.
pub const Context = struct {
    /// False ⇒ the layout is the single-slot optimizer cache, not a saved
    /// snapshot — a soft warning (a fab run should come off a blessed layout).
    from_saved_layout: bool = true,
    /// True ⇒ the caller asked to KEEP Do-Not-Populate parts in the centroid
    /// CSV (`?dnp=keep`). Since the default now DROPS them, the
    /// `dnp-in-centroid` warning fires only in keep-mode.
    keep_dnp: bool = false,
};

/// Run the readiness report. `copper` is the blessed layout's persisted routed
/// copper (the same slice the Gerber writer draws). All output is arena-owned.
pub fn check(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    copper: export_gerber.Copper,
    ctx: Context,
) std.mem.Allocator.Error!Report {
    var errors: std.ArrayList(Item) = .empty;
    var warnings: std.ArrayList(Item) = .empty;
    var stats: Stats = .{
        .parts = placement.parts.len,
        .nets = placement.nets.len,
        .tracks = copper.tracks.len,
        .vias = copper.vias.len,
        .has_outline = placement.board_rect != null,
    };

    // ── Board outline ───────────────────────────────────────────────────────
    // The Edge.Cuts profile is a real cut line; without an authored/drawn
    // outline the writers synthesize one from the parts bbox, which is a guess
    // a fab shouldn't cut to. Block it (the user can draw a rect in one click).
    if (placement.board_rect == null) {
        try errors.append(arena, .{
            .id = "no-outline",
            .message = "no board outline — the Edge.Cuts profile would be guessed from the parts bounding box; draw or author a board outline first",
        });
    }

    // ── Placement: unplaced / off-board parts ───────────────────────────────
    // A part whose courtyard centre is far outside the outline is stranded in
    // the staging band (or was never placed). It still lands in the centroid /
    // copper, so it would ship at a nonsense location.
    if (placement.board_rect) |br| {
        for (placement.parts) |p| {
            const cc = optimizer.worldPadCenter(p, p.ccx, p.ccy);
            const inset = edgeInset(br, cc[0], cc[1]);
            if (inset < -STAGING_BAND_MM) {
                try errors.append(arena, .{
                    .id = "part-off-board",
                    .message = try std.fmt.allocPrint(arena, "{s} sits outside the board outline (staging band)" ++
                        " — place it on the board or remove it", .{p.ref_des}),
                    .ref = p.ref_des,
                });
            }
        }
    }

    // ── Vias with no drill (legacy synthetic) ───────────────────────────────
    // A drill = 0 via would emit a bad Excellon hole (and its annular ring is
    // unknowable). Count them once; report if any.
    var bad_vias: usize = 0;
    for (copper.vias) |v| {
        if (v.drill <= 0) bad_vias += 1;
    }
    if (bad_vias > 0) {
        try errors.append(arena, .{
            .id = "via-no-drill",
            .message = try std.fmt.allocPrint(arena, "{d} via(s) have no drill diameter (legacy synthetic)" ++
                " — they would emit bad drill data; re-route to regenerate them", .{bad_vias}),
            .count = bad_vias,
        });
    }

    // ── DRC against the persisted copper at the current poses ───────────────
    // The router/DRC normally only run on the Route button; here we DRC the
    // saved copper exactly as it will ship. The base clearance is the design's
    // resolved `(design-rules …)` rule (built-in 5-mil default when no form),
    // and `drc.check` layers per-net `(net-class …)` overrides from
    // `placement.rules.net` on top. The gate deliberately ignores any
    // interactive query/panel clearance — it must judge the board against the
    // authored rules, not whatever a user last routed with.
    const clearance = placement.rules.design.clearance;
    const routed = router.RouteResult{
        .tracks = copper.tracks,
        .vias = copper.vias,
        .routed = 0,
        .total = 0,
    };
    const violations = drc.check(arena, placement, routed, clearance) catch &.{};
    stats.drc_violations = violations.len;
    // Partition by severity: error-severity violations block the gate; warnings
    // (courtyard overlap, mask slivers, silkscreen over a pad) flow through as
    // an informational finding but never 409 the download.
    var drc_errs: std.ArrayList(drc.Violation) = .empty;
    var drc_warns: std.ArrayList(drc.Violation) = .empty;
    for (violations) |v| {
        if (v.severity == .warn) try drc_warns.append(arena, v) else try drc_errs.append(arena, v);
    }
    if (drc_errs.items.len > 0) {
        try errors.append(arena, .{
            .id = "drc",
            .message = try std.fmt.allocPrint(arena, "{d} DRC violation(s) in the persisted copper ({s})" ++
                " — open the board's Route/DRC view to inspect them", .{ drc_errs.items.len, drcSummary(arena, drc_errs.items) }),
            .count = drc_errs.items.len,
        });
    }
    if (drc_warns.items.len > 0) {
        try warnings.append(arena, .{
            .id = "drc-warn",
            .message = try std.fmt.allocPrint(arena, "{d} DRC warning(s) in the persisted copper ({s})" ++
                " — assembly-hygiene advisories; they don't block the fab package", .{ drc_warns.items.len, drcSummary(arena, drc_warns.items) }),
            .count = drc_warns.items.len,
        });
    }

    // ── Connectivity: unrouted nets (airwires remaining) ────────────────────
    var routable: usize = 0;
    var connected: usize = 0;
    for (placement.nets, 0..) |net, net_i| {
        const comps = try netComponents(arena, placement, copper, net, @intCast(net_i));
        // A net that lands in <2 distinct board locations needs no copper
        // (single pad, or a plane-carried net whose pads the plane joins).
        if (comps.locations < 2) continue;
        routable += 1;
        if (comps.groups <= 1) {
            connected += 1;
        } else {
            try errors.append(arena, .{
                .id = "unrouted-net",
                .message = try std.fmt.allocPrint(arena, "net {s} is not fully connected" ++
                    " — {d} isolated copper island(s) remain (airwire)", .{ net.name, comps.groups }),
                .net = net.name,
                .count = comps.groups,
            });
        }
    }
    stats.routable_nets = routable;
    stats.connected_nets = connected;

    // ── Warnings ────────────────────────────────────────────────────────────
    var dnp: usize = 0;
    for (placement.instances) |inst| {
        if (inst.dnp) dnp += 1;
    }
    stats.dnp_parts = dnp;
    // DNP parts are dropped from the centroid by default now, so this only
    // warns when the caller opted back in with `?dnp=keep`.
    if (dnp > 0 and ctx.keep_dnp) {
        try warnings.append(arena, .{
            .id = "dnp-in-centroid",
            .message = try std.fmt.allocPrint(arena, "{d} Do-Not-Populate part(s) are kept in the centroid CSV (?dnp=keep)" ++
                " — drop the ?dnp=keep opt-in if your assembler wants only stuffed parts", .{dnp}),
            .count = dnp,
        });
    }

    // A custom outline polygon with < 3 points is degenerate: every fab writer
    // silently falls back to the bounding rectangle, which may not be the shape
    // the user drew. Surface it so the profile isn't a silent guess.
    if (placement.board_poly) |poly| {
        if (poly.len < 3) {
            try warnings.append(arena, .{
                .id = "malformed-outline",
                .message = "malformed custom outline (< 3 points) — the board profile falls back to the bounding" ++
                    " rectangle; redraw the outline to cut the intended shape",
            });
        }
    }
    if (!ctx.from_saved_layout) {
        try warnings.append(arena, .{
            .id = "cache-layout",
            .message = "the exported layout is the optimizer cache, not a saved/starred snapshot" ++
                " — Save the layout so the fab package comes off a blessed board",
        });
    }

    return .{
        .errors = try errors.toOwnedSlice(arena),
        .warnings = try warnings.toOwnedSlice(arena),
        .stats = stats,
    };
}

/// Serialize a report to the JSON the endpoint returns / the modal reads:
/// `{"ok":bool,"errors":[{id,message,net?,ref?,count?}],"warnings":[…],"stats":{…}}`.
pub fn writeJson(w: *std.Io.Writer, report: Report) std.Io.Writer.Error!void {
    try w.print("{{\"ok\":{s},\"errors\":[", .{if (report.ok()) "true" else "false"});
    try writeItems(w, report.errors);
    try w.writeAll("],\"warnings\":[");
    try writeItems(w, report.warnings);
    try w.writeAll("],\"stats\":{");
    const s = report.stats;
    try w.print("\"parts\":{d},\"nets\":{d},\"tracks\":{d},\"vias\":{d}," ++
        "\"routable_nets\":{d},\"connected_nets\":{d},\"drc_violations\":{d}," ++
        "\"has_outline\":{s},\"dnp_parts\":{d}", .{
        s.parts,         s.nets,           s.tracks,         s.vias,
        s.routable_nets, s.connected_nets, s.drc_violations, if (s.has_outline) "true" else "false",
        s.dnp_parts,
    });
    try w.writeAll("}}");
}

fn writeItems(w: *std.Io.Writer, items: []const Item) std.Io.Writer.Error!void {
    for (items, 0..) |it, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"id\":");
        try writeJsonStr(w, it.id);
        try w.writeAll(",\"message\":");
        try writeJsonStr(w, it.message);
        if (it.net) |n| {
            try w.writeAll(",\"net\":");
            try writeJsonStr(w, n);
        }
        if (it.ref) |r| {
            try w.writeAll(",\"ref\":");
            try writeJsonStr(w, r);
        }
        if (it.count > 0) try w.print(",\"count\":{d}", .{it.count});
        try w.writeAll("}");
    }
}

/// Minimal JSON string escaper (quotes + backslash + control chars) — the net
/// names and messages here never contain exotic characters, but be safe.
fn writeJsonStr(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => if (c < 0x20) try w.print("\\u{x:0>4}", .{c}) else try w.writeByte(c),
    };
    try w.writeByte('"');
}

// ── Connectivity model ──────────────────────────────────────────────────────

/// A net's connectivity picture: how many distinct board LOCATIONS its pads
/// occupy (single-location nets need no copper), and how many CONNECTED GROUPS
/// those pads fall into once the persisted copper (and any plane) is applied.
const NetConn = struct { locations: usize, groups: usize };

/// One pad terminal of a net, reduced to its world box + centre. `part` lets us
/// treat two pads of the same part on the same net as one location; `thru`/
/// `side` let the pour decide which copper layers the pad reaches.
const PadNode = struct {
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,
    poly: []const [2]f64,
    cx: f64,
    cy: f64,
    part: usize,
    thru: bool,
    side: optimizer.Side,
};

/// Compute `net`'s connectivity over the persisted copper. Pads, track
/// segments, vias, AND the computed copper-pour components are all union-find
/// nodes, so connectivity propagates through multi-segment route chains, via
/// layer-jumps, and the real (island-verified) plane fill. `groups` counts the
/// connected components over the PADS; `locations` counts distinct pad
/// positions (so a net whose every pad sits at one point isn't "routable").
fn netComponents(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    copper: export_gerber.Copper,
    net: @import("export_kicad.zig").FlatNet,
    net_i: i32,
) std.mem.Allocator.Error!NetConn {
    // ref-des → part index for this net's pins.
    var nodes: std.ArrayList(PadNode) = .empty;
    for (net.pins) |pin| {
        const pi = partIndex(placement, pin.ref_des) orelse continue;
        const part = placement.parts[pi];
        const pad = padOf(part, pin.pin) orelse continue;
        const sh = try pad_shape.worldShape(arena, part, pad);
        try nodes.append(arena, .{
            .x0 = sh.x0,
            .y0 = sh.y0,
            .x1 = sh.x1,
            .y1 = sh.y1,
            .poly = sh.poly,
            .cx = (sh.x0 + sh.x1) / 2,
            .cy = (sh.y0 + sh.y1) / 2,
            .part = pi,
            .thru = pad.thru,
            .side = part.side,
        });
    }
    const items = nodes.items;

    // Distinct board locations: unique pad-centre positions (0.05 mm buckets).
    // A net with <2 must not be flagged as unrouted (one pad, or all pads
    // coincident — a bridge/net-tie footprint).
    var locations: usize = 0;
    for (items, 0..) |a, i| {
        var dup = false;
        for (items[0..i]) |b| {
            if (@abs(a.cx - b.cx) < 0.05 and @abs(a.cy - b.cy) < 0.05) {
                dup = true;
                break;
            }
        }
        if (!dup) locations += 1;
    }
    if (locations < 2) return .{ .locations = locations, .groups = if (items.len == 0) 0 else 1 };

    // Union pads bridged by same-net copper — TRANSITIVELY through track
    // chains and via jumps. A maze route is many short segments and only its
    // END segments touch the pads, so tracks (and vias) must be union-find
    // nodes themselves: pad↔track and pad↔via where the copper lands on the
    // pad, track↔track where a same-layer joint touches, track↔via for the
    // layer jump. Pads are what we count at the end.
    var segs: std.ArrayList(router.Track) = .empty;
    for (copper.tracks) |t| {
        if (sameNet(t.net, net_i)) try segs.append(arena, t);
    }
    var vs: std.ArrayList(router.Via) = .empty;
    for (copper.vias) |v| {
        if (sameNet(v.net, net_i)) try vs.append(arena, v);
    }
    // The computed copper POUR is the honest replacement for the old "any
    // plane-carried net is one group" short-circuit: a pad counts as
    // plane-connected iff it lands in a KEPT pour component (thermal-relieved
    // pads still count — the spokes keep them in-component). A pad the pour
    // cannot reach (isolated by its antipad ring, a plane a foreign trace
    // split, the wrong side of a single-sided pour) stays its own group → an
    // honest airwire, no longer believed-connected.
    const qpads = try planeQueries(arena, items);
    const join = try pour.planeConnect(arena, placement, .{ .tracks = copper.tracks, .vias = copper.vias }, net.name, qpads, vs.items);
    const n_pads = items.len;
    const n_tracks = segs.items.len;
    const parent = try arena.alloc(usize, n_pads + n_tracks + vs.items.len + join.n_comp);
    for (parent, 0..) |*p, i| p.* = i;
    planeUnite(parent, join, n_pads, n_tracks);

    for (segs.items, 0..) |t, ti| {
        // pad ↔ track (pads union with copper on any layer, matching the
        // original behaviour — SMD pads only ever meet their own-side copper
        // in practice, and thru pads meet both).
        for (items, 0..) |p, pi| {
            if (segShapeDist(t.x1, t.y1, t.x2, t.y2, p) <= t.width / 2 + TOUCH_SLACK_MM)
                unite(parent, pi, n_pads + ti);
        }
        // track ↔ track: a same-layer joint (an endpoint of one on the body
        // of the other) chains the route segments together.
        for (segs.items[ti + 1 ..], ti + 1..) |b, bi| {
            if (t.layer != b.layer) continue;
            const touch = t.width / 2 + b.width / 2 + TOUCH_SLACK_MM;
            if (segPointDist(t.x1, t.y1, t.x2, t.y2, b.x1, b.y1) <= touch or
                segPointDist(t.x1, t.y1, t.x2, t.y2, b.x2, b.y2) <= touch or
                segPointDist(b.x1, b.y1, b.x2, b.y2, t.x1, t.y1) <= touch or
                segPointDist(b.x1, b.y1, b.x2, b.y2, t.x2, t.y2) <= touch)
                unite(parent, n_pads + ti, n_pads + bi);
        }
        // track ↔ via: the cross-layer jump.
        for (vs.items, 0..) |v, vi| {
            if (segPointDist(t.x1, t.y1, t.x2, t.y2, v.x, v.y) <= t.width / 2 + v.dia / 2 + TOUCH_SLACK_MM)
                unite(parent, n_pads + ti, n_pads + n_tracks + vi);
        }
    }
    // pad ↔ via (a via dropped on/next to a pad joins its group).
    for (vs.items, 0..) |v, vi| {
        for (items, 0..) |p, pi| {
            if (segShapeDist(v.x, v.y, v.x, v.y, p) <= v.dia / 2 + TOUCH_SLACK_MM)
                unite(parent, pi, n_pads + n_tracks + vi);
        }
    }

    // Count distinct roots over the PAD nodes only.
    var group_root: std.AutoHashMapUnmanaged(usize, void) = .empty;
    for (0..n_pads) |i| try group_root.put(arena, find(parent, i), {});
    return .{ .locations = locations, .groups = group_root.count() };
}

/// Reduce the net's pad nodes to the pour engine's membership queries.
fn planeQueries(arena: std.mem.Allocator, items: []const PadNode) std.mem.Allocator.Error![]const pour.PadQuery {
    const out = try arena.alloc(pour.PadQuery, items.len);
    for (items, 0..) |p, i| {
        out[i] = .{ .cx = p.cx, .cy = p.cy, .x0 = p.x0, .y0 = p.y0, .x1 = p.x1, .y1 = p.y1, .thru = p.thru, .side = p.side };
    }
    return out;
}

/// Fold the pour-component assignment into the union-find: unite each pad / via
/// with the (arena-tail) node for the kept pour component it landed in. Pads /
/// vias in no component (-1) touch no pour node and stay their own group.
fn planeUnite(parent: []usize, join: pour.Join, n_pads: usize, n_tracks: usize) void {
    const base = n_pads + n_tracks + join.via_comp.len;
    for (join.pad_comp, 0..) |c, i| {
        if (c >= 0) unite(parent, i, base + @as(usize, @intCast(c)));
    }
    for (join.via_comp, 0..) |c, j| {
        if (c >= 0) unite(parent, n_pads + n_tracks + j, base + @as(usize, @intCast(c)));
    }
}

/// Shortest distance from point (px,py) to segment (ax,ay)-(bx,by).
fn segPointDist(ax: f64, ay: f64, bx: f64, by: f64, px: f64, py: f64) f64 {
    const dx = bx - ax;
    const dy = by - ay;
    const len2 = dx * dx + dy * dy;
    if (len2 < 1e-12) return std.math.hypot(px - ax, py - ay);
    const t = std.math.clamp(((px - ax) * dx + (py - ay) * dy) / len2, 0, 1);
    return std.math.hypot(px - (ax + t * dx), py - (ay + t * dy));
}

/// Distance from segment (ax,ay)-(bx,by) to a pad's copper (0 inside it).
/// Sampled endpoints + a midpoint against the pad's real outline — exact
/// enough to decide "does this copper land on the pad" for connectivity.
fn segShapeDist(ax: f64, ay: f64, bx: f64, by: f64, p: PadNode) f64 {
    var best = std.math.inf(f64);
    const samples = 8;
    var i: usize = 0;
    while (i <= samples) : (i += 1) {
        const t = @as(f64, @floatFromInt(i)) / samples;
        const px = ax + (bx - ax) * t;
        const py = ay + (by - ay) * t;
        const d = pad_shape.pointDist(p.x0, p.y0, p.x1, p.y1, p.poly, px, py, best);
        if (d < best) best = d;
    }
    return best;
}

// ── Union-find over copper nodes (pads | tracks | vias) ─────────────────────

fn find(parent: []usize, i: usize) usize {
    var r = i;
    while (parent[r] != r) r = parent[r];
    // Path-halving.
    var x = i;
    while (parent[x] != r) {
        const next = parent[x];
        parent[x] = r;
        x = next;
    }
    return r;
}

fn unite(parent: []usize, a: usize, b: usize) void {
    const ra = find(parent, a);
    const rb = find(parent, b);
    if (ra != rb) parent[rb] = ra;
}

// ── Net / plane / geometry helpers ──────────────────────────────────────────

/// Net index equality that respects the router's -1 = "no net" convention.
fn sameNet(a: i32, b: i32) bool {
    return a == b and a != -1;
}

/// ref-des → part index (linear; net fan-out is small).
fn partIndex(placement: optimizer.Placement, ref: []const u8) ?usize {
    for (placement.parts, 0..) |p, i| {
        if (std.mem.eql(u8, p.ref_des, ref)) return i;
    }
    return null;
}

/// The pad on `part` with number `num`, or null.
fn padOf(part: optimizer.Part, num: []const u8) ?@import("placement/geometry.zig").Pad {
    for (part.pads) |pad| {
        if (std.mem.eql(u8, pad.number, num)) return pad;
    }
    return null;
}

/// Does a copper plane carry `name`? Mirrors the router's `netHasPlane` /
/// Gerber `planeCarries`: no `(stackup …)` form ⇒ every ground-named net is
/// plane-carried; a declared stackup carries exactly its `(plane …)` nets
/// (case-insensitive, full or leaf name).
fn netHasPlane(placement: optimizer.Placement, name: []const u8) bool {
    const planes = placement.rules.plane_nets orelse return optimizer.isGroundName(leafName(name));
    for (planes) |pn| {
        if (std.ascii.eqlIgnoreCase(pn, name) or std.ascii.eqlIgnoreCase(pn, leafName(name))) return true;
    }
    return false;
}

/// The net name's leaf after the last '/' (sub-block flatten prefix).
fn leafName(s: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, s, '/')) |i| return s[i + 1 ..];
    return s;
}

/// Signed distance from (x,y) to the nearest outline edge — positive inside.
fn edgeInset(br: optimizer.BoardRect, x: f64, y: f64) f64 {
    const dl = x - br.minx;
    const dr = br.minx + br.w - x;
    const dt = y - br.miny;
    const db = br.miny + br.h - y;
    return @min(@min(dl, dr), @min(dt, db));
}

/// A compact "3× via_pad, 1× track_track" style summary of the DRC kinds, for
/// the error line (the full list lives behind the Route/DRC view).
fn drcSummary(arena: std.mem.Allocator, violations: []const drc.Violation) []const u8 {
    var counts = std.enums.EnumArray(drc.Kind, usize).initFill(0);
    for (violations) |v| counts.set(v.kind, counts.get(v.kind) + 1);
    var out: std.ArrayList(u8) = .empty;
    var first = true;
    inline for (@typeInfo(drc.Kind).@"enum".fields) |f| {
        const k: drc.Kind = @enumFromInt(f.value);
        const c = counts.get(k);
        if (c > 0) {
            if (!first) out.appendSlice(arena, ", ") catch return "DRC";
            first = false;
            out.writer(arena).print("{d}× {s}", .{ c, f.name }) catch return "DRC";
        }
    }
    return out.items;
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;
const geometry = @import("placement/geometry.zig");
const export_kicad = @import("export_kicad.zig");

// spec: fab_readiness - a routed net is connected; an unrouted multi-pad net is flagged
test "connectivity flags an unrouted net and passes a routed one" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    // U1.1 at (0,0) and C1.1 at (10,0), both on net SIG, at two board
    // locations 10 mm apart.
    const u_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    const c_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &u_pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 1, .hh = 1, .pads = &c_pads, .fallback = false, .x = 10, .y = 0 },
    };
    const pins = [_]export_kicad.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C1", .pin = "1" } };
    const nets = [_]export_kicad.FlatNet{.{ .name = "SIG", .pins = &pins }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -2,
        .miny = -2,
        .maxx = 12,
        .maxy = 2,
        .generated = false,
        .board_rect = .{ .minx = -2, .miny = -2, .w = 16, .h = 6 },
        // (stackup 2): no plane, so SIG must be routed as real copper.
        .rules = .{ .plane_nets = &.{}, .copper_layers = 2 },
    };

    // No copper: the net is unrouted (an airwire remains).
    const bare = try check(arena, placement, .{}, .{});
    try testing.expect(!bare.ok());
    try testing.expect(hasError(bare, "unrouted-net"));
    try testing.expectEqual(@as(usize, 1), bare.stats.routable_nets);
    try testing.expectEqual(@as(usize, 0), bare.stats.connected_nets);

    // A track spanning both pads connects them → no unrouted-net error.
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 10, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
    };
    const routed = try check(arena, placement, .{ .tracks = &tracks }, .{});
    try testing.expect(!hasError(routed, "unrouted-net"));
    try testing.expectEqual(@as(usize, 1), routed.stats.connected_nets);

    // A real maze route is a CHAIN of segments (only the end segments touch
    // the pads) — the union must propagate through the track↔track joints.
    const chain = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 3, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 3, .y1 = 0, .x2 = 3, .y2 = 1.5, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 3, .y1 = 1.5, .x2 = 10, .y2 = 1.5, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 10, .y1 = 1.5, .x2 = 10, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
    };
    const chained = try check(arena, placement, .{ .tracks = &chain }, .{});
    try testing.expect(!hasError(chained, "unrouted-net"));
    try testing.expectEqual(@as(usize, 1), chained.stats.connected_nets);

    // …and through a via layer-jump: top stub → via → bottom run → via → top stub.
    const jump = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 2, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 2, .y1 = 0, .x2 = 8, .y2 = 0, .layer = 1, .width = 0.2, .net = 0 },
        .{ .x1 = 8, .y1 = 0, .x2 = 10, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
    };
    const jvias = [_]router.Via{
        .{ .x = 2, .y = 0, .dia = 0.4, .drill = 0.2, .net = 0 },
        .{ .x = 8, .y = 0, .dia = 0.4, .drill = 0.2, .net = 0 },
    };
    const jumped = try check(arena, placement, .{ .tracks = &jump, .vias = &jvias }, .{});
    try testing.expect(!hasError(jumped, "unrouted-net"));
    try testing.expectEqual(@as(usize, 1), jumped.stats.connected_nets);

    // Two same-layer segments that do NOT touch stay two islands (no false
    // transitivity from the chain logic).
    const gap = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 4, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 6, .y1 = 0, .x2 = 10, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
    };
    const gapped = try check(arena, placement, .{ .tracks = &gap }, .{});
    try testing.expect(hasError(gapped, "unrouted-net"));
}

// spec: fab_readiness - connectivity propagates across an inner-signal-layer chain through its vias
test "an inner-layer route chain counts as connected" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const u_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    const c_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &u_pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 1, .hh = 1, .pads = &c_pads, .fallback = false, .x = 10, .y = 0 },
    };
    const pins = [_]export_kicad.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C1", .pin = "1" } };
    const nets = [_]export_kicad.FlatNet{.{ .name = "SIG", .pins = &pins }};
    // (stackup 4 (plane 2 "GND")): SIG must be real copper; the run crosses on
    // the inner signal layer (index 2), reached through two vias.
    const gnd_names = [_][]const u8{"GND"};
    const planes = [_]optimizer.PlaneAt{.{ .index = 2, .net = "GND" }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -2,
        .miny = -2,
        .maxx = 12,
        .maxy = 2,
        .generated = false,
        .board_rect = .{ .minx = -2, .miny = -2, .w = 16, .h = 6 },
        .rules = .{ .plane_nets = &gnd_names, .copper_layers = 4, .planes = &planes },
    };

    // Top stub → via → INNER (l=2) run → via → top stub: one connected group.
    const chain = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 2, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 2, .y1 = 0, .x2 = 8, .y2 = 0, .layer = 2, .width = 0.2, .net = 0 },
        .{ .x1 = 8, .y1 = 0, .x2 = 10, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
    };
    const cvias = [_]router.Via{
        .{ .x = 2, .y = 0, .dia = 0.4, .drill = 0.2, .net = 0 },
        .{ .x = 8, .y = 0, .dia = 0.4, .drill = 0.2, .net = 0 },
    };
    const linked = try check(arena, placement, .{ .tracks = &chain, .vias = &cvias }, .{});
    try testing.expect(!hasError(linked, "unrouted-net"));
    try testing.expectEqual(@as(usize, 1), linked.stats.connected_nets);

    // The same chain WITHOUT the vias must stay three islands — the inner run
    // never touches the top stubs on its own layer.
    const cut = try check(arena, placement, .{ .tracks = &chain }, .{});
    try testing.expect(hasError(cut, "unrouted-net"));
}

// spec: fab_readiness - a ground plane connects its pads without routed copper
test "a plane-carried net counts as connected" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const u_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6, .thru = true, .drill = 0.3 }};
    const c_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6, .thru = true, .drill = 0.3 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &u_pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 1, .hh = 1, .pads = &c_pads, .fallback = false, .x = 10, .y = 0 },
    };
    const pins = [_]export_kicad.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C1", .pin = "1" } };
    const nets = [_]export_kicad.FlatNet{.{ .name = "GND", .pins = &pins }};
    // No (stackup …) form → implicit planes → ground is plane-carried.
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -2,
        .miny = -2,
        .maxx = 12,
        .maxy = 2,
        .generated = false,
        .board_rect = .{ .minx = -2, .miny = -2, .w = 16, .h = 6 },
    };
    const r = try check(arena, placement, .{}, .{});
    try testing.expect(!hasError(r, "unrouted-net"));
    try testing.expectEqual(@as(usize, 1), r.stats.connected_nets);
}

// spec: fab_readiness - a surface pad isolated from the plane is flagged until a plane via bridges it
test "a plane via bridges a surface pad to the ground plane" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    // Two GND SURFACE-MOUNT pads (no barrel) over the implicit inner ground
    // plane. With no via they do not reach the inner plane — honestly isolated
    // (the old short-circuit believed them connected). The router's plane-via
    // pass drops a via on each pad; those vias land in the plane and bridge the
    // pads to it, so a routed board is one connected group again.
    const u_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    const c_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &u_pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 1, .hh = 1, .pads = &c_pads, .fallback = false, .x = 10, .y = 0 },
    };
    const pins = [_]export_kicad.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C1", .pin = "1" } };
    const nets = [_]export_kicad.FlatNet{.{ .name = "GND", .pins = &pins }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -2,
        .miny = -2,
        .maxx = 12,
        .maxy = 2,
        .generated = false,
        .board_rect = .{ .minx = -2, .miny = -2, .w = 16, .h = 6 },
    };

    // Unrouted: the surface pads cannot reach the inner plane → an airwire.
    const bare = try check(arena, placement, .{}, .{});
    try testing.expect(hasError(bare, "unrouted-net"));

    // A GND plane via on each pad bridges it to the plane → one group.
    const vias = [_]router.Via{
        .{ .x = 0, .y = 0, .dia = 0.4, .drill = 0.2, .net = 0 },
        .{ .x = 10, .y = 0, .dia = 0.4, .drill = 0.2, .net = 0 },
    };
    const wired = try check(arena, placement, .{ .vias = &vias }, .{});
    try testing.expect(!hasError(wired, "unrouted-net"));
    try testing.expectEqual(@as(usize, 1), wired.stats.connected_nets);
}

// spec: fab_readiness - a missing outline, off-board part, drill-less via, and DNP all surface
test "outline, off-board, drill-less via, and DNP findings" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    // U1 on the board, U2 stranded 50 mm off to the side.
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false, .x = 5, .y = 5 },
        .{ .ref_des = "U2", .kind = .hub, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false, .x = 60, .y = 5 },
    };
    const insts = [_]export_kicad.FlatInstance{
        .{ .ref_des = "U1", .component = "u", .value = "V", .footprint = "F", .uuid = "", .properties = &.{} },
        .{ .ref_des = "U2", .component = "u", .value = "V", .footprint = "F", .uuid = "", .properties = &.{}, .dnp = true },
    };

    // First: no board_rect at all → the no-outline error (and no off-board
    // check, which needs an outline).
    var placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &insts,
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 10,
        .maxy = 10,
        .generated = false,
    };
    const vias = [_]router.Via{.{ .x = 5, .y = 5, .dia = 0.4, .drill = 0, .net = 0 }};
    // keep_dnp mode: the DNP part is listed in the centroid, so the warning fires.
    const no_outline = try check(arena, placement, .{ .vias = &vias }, .{ .from_saved_layout = false, .keep_dnp = true });
    try testing.expect(hasError(no_outline, "no-outline"));
    try testing.expect(hasError(no_outline, "via-no-drill"));
    try testing.expect(hasWarning(no_outline, "dnp-in-centroid"));
    try testing.expect(hasWarning(no_outline, "cache-layout"));

    // Default (drop DNP): the same DNP part no longer warrants the warning.
    const drop_dnp = try check(arena, placement, .{ .vias = &vias }, .{ .from_saved_layout = false });
    try testing.expect(!hasWarning(drop_dnp, "dnp-in-centroid"));

    // Now give it an outline: U2 (at x=60) is >10 mm outside the 10×10 board.
    placement.board_rect = .{ .minx = 0, .miny = 0, .w = 10, .h = 10 };
    const with_outline = try check(arena, placement, .{ .vias = &vias }, .{});
    try testing.expect(!hasError(with_outline, "no-outline"));
    try testing.expect(hasError(with_outline, "part-off-board"));
}

// spec: fab_readiness - a clean board produces no errors and reports ok
test "a clean routed board is export-ready" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const u_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    const c_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &u_pads, .fallback = false, .x = 3, .y = 3 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 1, .hh = 1, .pads = &c_pads, .fallback = false, .x = 7, .y = 3 },
    };
    const pins = [_]export_kicad.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C1", .pin = "1" } };
    const nets = [_]export_kicad.FlatNet{.{ .name = "SIG", .pins = &pins }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 10,
        .maxy = 6,
        .generated = false,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 10, .h = 6 },
        .rules = .{ .plane_nets = &.{}, .copper_layers = 2 },
    };
    const tracks = [_]router.Track{.{ .x1 = 3, .y1 = 3, .x2 = 7, .y2 = 3, .layer = 0, .width = 0.2, .net = 0 }};
    const vias = [_]router.Via{.{ .x = 5, .y = 3, .dia = 0.4, .drill = 0.2, .net = 0 }};
    const r = try check(arena, placement, .{ .tracks = &tracks, .vias = &vias }, .{});
    try testing.expect(r.ok());
    try testing.expectEqual(@as(usize, 0), r.errors.len);

    // The JSON round-trips (has "ok":true and the stats block).
    var aw: std.Io.Writer.Allocating = .init(arena);
    try writeJson(&aw.writer, r);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "\"ok\":true") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "\"routable_nets\":1") != null);
}

// spec: fab_readiness - the fab gate's DRC measures against the design's resolved clearance rule
test "fab gate DRC uses the design's clearance, not a hardcoded default" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    // Two single-pad parts on different nets, 0.2 mm edge-to-edge apart (pad
    // half-width 0.3; centres 0.8 apart ⇒ 0.8 − 0.3 − 0.3 = 0.2). Each net has one
    // pad (no airwire) and there's no routed copper, and the courtyards are kept
    // small (hw 0.35 < half the 0.8 pitch) so they don't overlap — so the ONLY
    // thing that can flag is the pad↔pad clearance. At the 0.127 mm default the
    // board is clean; a (design-rules (clearance 0.3)) — resolved onto
    // placement.rules.design — must make the gate's DRC flag it, proving the gate
    // reads the authored rule.
    const u_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    const c_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 0.35, .hh = 0.35, .pads = &u_pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.35, .hh = 0.35, .pads = &c_pads, .fallback = false, .x = 0.8, .y = 0 },
    };
    const ap = [_]export_kicad.FlatPin{.{ .ref_des = "U1", .pin = "1" }};
    const bp = [_]export_kicad.FlatPin{.{ .ref_des = "C1", .pin = "1" }};
    const nets = [_]export_kicad.FlatNet{ .{ .name = "A", .pins = &ap }, .{ .name = "B", .pins = &bp } };
    const base = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -2,
        .miny = -2,
        .maxx = 4,
        .maxy = 4,
        .generated = false,
        .board_rect = .{ .minx = -2, .miny = -2, .w = 6, .h = 6 },
    };
    const empty = export_gerber.Copper{};

    // Default clearance ⇒ the 0.2 mm pad gap is legal; no DRC error.
    const r0 = try check(arena, base, empty, .{});
    try testing.expect(!hasError(r0, "drc"));

    // A 0.3 mm design clearance ⇒ the same gap flags; the gate reports a DRC error.
    var strict = base;
    strict.rules = .{ .design = .{ .clearance = 0.3 } };
    const r1 = try check(arena, strict, empty, .{});
    try testing.expect(hasError(r1, "drc"));
}

// spec: fab_readiness - a warning-severity DRC finding flows through as a gate warning; an error-severity one blocks
test "the gate blocks on error-severity DRC but not on warnings" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    // Two pad-less hubs whose 2×2 courtyards overlap (a warning-only finding)
    // on an otherwise clean, outlined board.
    var warn_parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false, .x = 3, .y = 3 },
        .{ .ref_des = "U2", .kind = .hub, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false, .x = 3.5, .y = 3 },
    };
    const warn_pl = optimizer.Placement{
        .parts = &warn_parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 10,
        .maxy = 6,
        .generated = false,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 10, .h = 6 },
    };
    const wr = try check(arena, warn_pl, .{}, .{});
    try testing.expect(wr.ok()); // a courtyard overlap alone never 409s
    try testing.expect(!hasError(wr, "drc"));
    try testing.expect(hasWarning(wr, "drc-warn"));

    // Two hubs with pads on DIFFERENT nets sitting on top of each other — a
    // pad↔pad copper clash (error severity) — must block.
    const a_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    const b_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var err_parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &a_pad, .fallback = false, .x = 3, .y = 3 },
        .{ .ref_des = "U2", .kind = .hub, .hw = 1, .hh = 1, .pads = &b_pad, .fallback = false, .x = 3.2, .y = 3 },
    };
    const a_pin = [_]export_kicad.FlatPin{.{ .ref_des = "U1", .pin = "1" }};
    const b_pin = [_]export_kicad.FlatPin{.{ .ref_des = "U2", .pin = "1" }};
    const enets = [_]export_kicad.FlatNet{ .{ .name = "A", .pins = &a_pin }, .{ .name = "B", .pins = &b_pin } };
    const err_pl = optimizer.Placement{
        .parts = &err_parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &enets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 10,
        .maxy = 6,
        .generated = false,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 10, .h = 6 },
    };
    const er = try check(arena, err_pl, .{}, .{});
    try testing.expect(!er.ok()); // the pad clash blocks the download
    try testing.expect(hasError(er, "drc"));
}

// spec: fab_readiness - a custom outline polygon with fewer than 3 points warns that the profile fell back to a rect
test "a malformed custom outline surfaces a warning" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false, .x = 5, .y = 3 },
    };
    // A board_poly with only 2 points is degenerate — the writers fall back to
    // the bbox rect, so warn.
    const bad_poly = [_][2]f64{ .{ 0, 0 }, .{ 10, 6 } };
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
        .maxx = 10,
        .maxy = 6,
        .generated = false,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 10, .h = 6 },
        .board_poly = &bad_poly,
    };
    const r = try check(arena, placement, .{}, .{});
    try testing.expect(hasWarning(r, "malformed-outline"));
    // A well-formed (≥ 3 point) polygon does not warn.
    var good = placement;
    const good_poly = [_][2]f64{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 6 }, .{ 0, 6 } };
    good.board_poly = &good_poly;
    try testing.expect(!hasWarning(try check(arena, good, .{}, .{}), "malformed-outline"));
}

fn hasError(r: Report, id: []const u8) bool {
    for (r.errors) |e| if (std.mem.eql(u8, e.id, id)) return true;
    return false;
}
fn hasWarning(r: Report, id: []const u8) bool {
    for (r.warnings) |wn| if (std.mem.eql(u8, wn.id, id)) return true;
    return false;
}
