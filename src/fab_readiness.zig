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
//! connected), a DRC violation against the persisted copper at the current
//! poses, a part unplaced / stranded in the off-board staging band, a via with
//! drill = 0 (a legacy synthetic via that would emit a bad Excellon hole), and
//! a missing board outline (the profile would fall back to the parts bbox — a
//! guess a fab shouldn't cut to). Warnings (informational): DNP parts still in
//! the centroid, a layout coming from the optimizer cache rather than a saved
//! snapshot.

const std = @import("std");
const optimizer = @import("placement/optimizer.zig");
const router = @import("placement/router.zig");
const drc = @import("placement/drc.zig");
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
/// blessed layout came from a saved/starred snapshot (vs. the optimizer cache).
/// Defaults keep the pure/test path free of server concerns.
pub const Context = struct {
    /// False ⇒ the layout is the single-slot optimizer cache, not a saved
    /// snapshot — a soft warning (a fab run should come off a blessed layout).
    from_saved_layout: bool = true,
};

/// Run the readiness report. `copper` is the blessed layout's persisted routed
/// copper (the same slice the Gerber writer draws). All output is arena-owned.
pub fn check(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    copper: export_gerber.Copper,
    ctx: Context,
) std.mem.Allocator.Error!Report {
    var errors: std.ArrayListUnmanaged(Item) = .empty;
    var warnings: std.ArrayListUnmanaged(Item) = .empty;
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
    // saved copper exactly as it will ship. Default clearance is the router's
    // 5-mil rule (the same one /pcb-layout re-checks saved copper with).
    const clearance = (router.RouteParams{}).clearance;
    const routed = router.RouteResult{
        .tracks = copper.tracks,
        .vias = copper.vias,
        .routed = 0,
        .total = 0,
    };
    const violations = drc.check(arena, placement, routed, clearance) catch &.{};
    stats.drc_violations = violations.len;
    if (violations.len > 0) {
        try errors.append(arena, .{
            .id = "drc",
            .message = try std.fmt.allocPrint(arena, "{d} DRC violation(s) in the persisted copper ({s})" ++
                " — open the board's Route/DRC view to inspect them", .{ violations.len, drcSummary(arena, violations) }),
            .count = violations.len,
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
    if (dnp > 0) {
        try warnings.append(arena, .{
            .id = "dnp-in-centroid",
            .message = try std.fmt.allocPrint(arena, "{d} Do-Not-Populate part(s) are still listed in the centroid CSV" ++
                " — drop them from the pick-and-place file if your assembler wants only stuffed parts", .{dnp}),
            .count = dnp,
        });
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
/// treat two pads of the same part on the same net as one location.
const PadNode = struct {
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,
    poly: []const [2]f64,
    cx: f64,
    cy: f64,
    part: usize,
    /// Union-find parent (index into the pad-node list).
    root: usize,
};

/// Compute `net`'s connectivity over the persisted copper. Pads are the nodes;
/// a same-net track or via that touches two pads' copper unions them; a
/// plane-carried net unions every pad (the plane is the connection). `groups`
/// counts the resulting connected components; `locations` counts distinct pad
/// positions (so a net whose every pad sits at one point isn't "routable").
fn netComponents(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    copper: export_gerber.Copper,
    net: @import("export_kicad.zig").FlatNet,
    net_i: i32,
) std.mem.Allocator.Error!NetConn {
    // ref-des → part index for this net's pins.
    var nodes: std.ArrayListUnmanaged(PadNode) = .empty;
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
            .root = nodes.items.len,
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

    // A plane-carried net is connected through the plane copper — every pad on
    // it lands on (or vias down to) the plane, so treat them all as one group.
    if (netHasPlane(placement, net.name)) return .{ .locations = locations, .groups = 1 };

    // Union pads bridged by same-net copper. Each track/via unions the set of
    // pads it touches; a chain of tracks propagates through shared endpoints,
    // but pads are the only union targets we care about (isolated copper with
    // no pad is a separate — harmless-for-connectivity — concern).
    for (copper.tracks) |t| {
        if (!sameNet(t.net, net_i)) continue;
        unionTouching(items, t.x1, t.y1, t.width / 2, t.x2, t.y2);
    }
    for (copper.vias) |v| {
        if (!sameNet(v.net, net_i)) continue;
        unionTouching(items, v.x, v.y, v.dia / 2, v.x, v.y);
    }

    // Count distinct roots.
    var group_root: std.AutoHashMap(usize, void) = .init(arena);
    for (items, 0..) |_, i| try group_root.put(find(items, i), {});
    return .{ .locations = locations, .groups = group_root.count() };
}

/// Union every pad whose copper the given segment (a track, or a via as a
/// zero-length segment with radius) touches — so one track spanning two pads
/// joins them, and a via dropped on a pad joins it into that pad's group.
fn unionTouching(items: []PadNode, x1: f64, y1: f64, radius: f64, x2: f64, y2: f64) void {
    var first: ?usize = null;
    for (items, 0..) |*p, i| {
        const d = segShapeDist(x1, y1, x2, y2, p.*);
        if (d > radius + TOUCH_SLACK_MM) continue;
        if (first) |f| unite(items, f, i) else first = i;
    }
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

// ── Union-find over pad nodes ───────────────────────────────────────────────

fn find(items: []PadNode, i: usize) usize {
    var r = i;
    while (items[r].root != r) r = items[r].root;
    // Path-halving.
    var x = i;
    while (items[x].root != r) {
        const next = items[x].root;
        items[x].root = r;
        x = next;
    }
    return r;
}

fn unite(items: []PadNode, a: usize, b: usize) void {
    const ra = find(items, a);
    const rb = find(items, b);
    if (ra != rb) items[rb].root = ra;
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
    var out: std.ArrayListUnmanaged(u8) = .empty;
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
    const no_outline = try check(arena, placement, .{ .vias = &vias }, .{ .from_saved_layout = false });
    try testing.expect(hasError(no_outline, "no-outline"));
    try testing.expect(hasError(no_outline, "via-no-drill"));
    try testing.expect(hasWarning(no_outline, "dnp-in-centroid"));
    try testing.expect(hasWarning(no_outline, "cache-layout"));

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

fn hasError(r: Report, id: []const u8) bool {
    for (r.errors) |e| if (std.mem.eql(u8, e.id, id)) return true;
    return false;
}
fn hasWarning(r: Report, id: []const u8) bool {
    for (r.warnings) |wn| if (std.mem.eql(u8, wn.id, id)) return true;
    return false;
}
