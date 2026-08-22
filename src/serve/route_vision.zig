//! `POST /api/route-vision/:name` — the autorouter's own view of the board at
//! one recorded moment, as a per-layer grid mask the viewer washes over the
//! copper.
//!
//! The board a finished route shows is not the board the router searched: every
//! net after the first saw copper the earlier ones had already laid down. This
//! endpoint answers "how open was it *when this trace was routed*" by replaying
//! the maze's own `blocked` predicate against the copper snapshot a timeline
//! event carries, on the lattice that attempt recorded (`router.PassContext`).
//!
//! Free space is per NET, not global — clearance comes from the net's
//! `(net-class …)`, so a fat rail sees a far tighter board than a thin signal at
//! the same instant — and per LAYER. The request therefore names one net, and
//! the response carries one mask per signal layer.
//!
//! Two fields ride the same array (the viewer switches modes without refetching):
//!   * FREE  — every node the net may legally occupy.
//!   * REACH — of those, the ones actually connected to the net's seed pad. A
//!             failed net's stranded pads sit in the free-but-unreachable
//!             remainder, which is the whole diagnosis in one picture.
//!
//! Read-only: nothing here writes a design, a layout, or the route cache.

const std = @import("std");
const httpz = @import("httpz");
const serve_root = @import("../serve.zig");
const Server = serve_root.Server;
const optimizer = @import("../placement/optimizer.zig");
const router = @import("../placement/router.zig");
const pcb_layout_page = @import("pcb_layout_page.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const modules_mod = @import("modules.zig");

pub const HandlerError = pcb_layout_page.HandlerError;

const bad_json_msg = "bad json";
const no_net_msg = "no such net";
const no_pass_msg = "this timeline recorded no routing lattice — re-run the route to get vision";
const vision_err_msg = "could not rebuild the router's view";

/// Cell states in the emitted mask. Ordered so `>= .free` is "passable", which
/// is exactly the FREE-mode test.
const Cell = enum(u8) {
    /// `blocked` refuses this node to this net.
    blocked = 0,
    /// Passable, but not connected to the net's seed pad.
    free = 1,
    /// Passable and reachable from the seed pad.
    reached = 2,
};

/// A run of identical cells in the row-major, layer-major mask.
const run_value_max: usize = std.math.maxInt(u16);

/// One pad of the net, tagged with whether the reach flood got to it. A pad
/// reported `reached = false` is stranded: no copper this net can legally draw
/// joins it to the seed, so the failure is geometric, not a search budget.
const PadReach = struct {
    ref: []const u8,
    pin: []const u8,
    x: f64,
    y: f64,
    layer: u8,
    reached: bool,
};

/// Parse the `"pass"` object the `.initial` timeline event carries back into a
/// `PassContext`. A missing/!object value yields the zero context, which
/// `visionMask` rejects — the honest "this replay predates pass recording"
/// path, never a guessed lattice.
fn parsePass(v: ?std.json.Value) router.PassContext {
    const o = (v orelse return .{});
    if (o != .object) return .{};
    const obj = o.object;
    const nx = num(obj.get("nx"));
    const ny = num(obj.get("ny"));
    if (nx < 1 or ny < 1) return .{};
    const scale = num(obj.get("grid_scale"));
    return .{
        .grid = .{
            .ox = num(obj.get("ox")),
            .oy = num(obj.get("oy")),
            .g = num(obj.get("g")),
            .nx = @intFromFloat(nx),
            .ny = @intFromFloat(ny),
        },
        .n_signal = @intFromFloat(@max(0, @min(255, num(obj.get("n_signal"))))),
        .base = .{
            .track_width = num(obj.get("track_width")),
            .clearance = num(obj.get("clearance")),
            .via_dia = num(obj.get("via_dia")),
            .via_drill = num(obj.get("via_drill")),
        },
        .pour = .{ flag(obj.get("pour"), 0), flag(obj.get("pour"), 1) },
        .grid_scale = if (scale > 0) scale else 1,
    };
}

fn num(v: ?std.json.Value) f64 {
    const val = v orelse return 0;
    return switch (val) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => 0,
    };
}

/// Element `i` of a JSON bool array, false when absent or not a bool.
fn flag(v: ?std.json.Value, i: usize) bool {
    const val = v orelse return false;
    if (val != .array or i >= val.array.items.len) return false;
    const item = val.array.items[i];
    return item == .bool and item.bool;
}

/// The compact `[x1,y1,x2,y2,layer,width,net]` track encoding the timeline
/// emits, read straight back. Malformed elements are skipped rather than
/// failing the request: a partial view of the copper is still a useful picture,
/// and the client never hand-writes this array.
fn parseTracks(alloc: std.mem.Allocator, v: ?std.json.Value) std.mem.Allocator.Error![]const router.Track {
    const val = v orelse return &.{};
    if (val != .array) return &.{};
    var out: std.ArrayList(router.Track) = .empty;
    for (val.array.items) |it| {
        if (it != .array or it.array.items.len < 7) continue;
        const a = it.array.items;
        try out.append(alloc, .{
            .x1 = num(a[0]),
            .y1 = num(a[1]),
            .x2 = num(a[2]),
            .y2 = num(a[3]),
            .layer = @intFromFloat(@max(0, num(a[4]))),
            .width = num(a[5]),
            .net = @intFromFloat(num(a[6])),
        });
    }
    return out.toOwnedSlice(alloc);
}

/// The compact `[x,y,dia,drill,net]` via encoding, read straight back.
fn parseVias(alloc: std.mem.Allocator, v: ?std.json.Value) std.mem.Allocator.Error![]const router.Via {
    const val = v orelse return &.{};
    if (val != .array) return &.{};
    var out: std.ArrayList(router.Via) = .empty;
    for (val.array.items) |it| {
        if (it != .array or it.array.items.len < 5) continue;
        const a = it.array.items;
        try out.append(alloc, .{
            .x = num(a[0]),
            .y = num(a[1]),
            .dia = num(a[2]),
            .drill = num(a[3]),
            .net = @intFromFloat(num(a[4])),
        });
    }
    return out.toOwnedSlice(alloc);
}

/// Index of the net named `want` in the flattened netlist.
fn netIndex(placement: optimizer.Placement, want: []const u8) ?usize {
    for (placement.nets, 0..) |n, i| {
        if (std.mem.eql(u8, n.name, want)) return i;
    }
    return null;
}

/// The 8 in-layer neighbours of a node, as (dx, dy) steps.
const neighbours = [8][2]i2{
    .{ 1, 0 }, .{ -1, 0 }, .{ 0, 1 },  .{ 0, -1 },
    .{ 1, 1 }, .{ 1, -1 }, .{ -1, 1 }, .{ -1, -1 },
};

/// Flood the free space reachable from `seed`, promoting every cell it lands on
/// from `.free` to `.reached`, in place.
///
/// Movement model: the maze's own — 8-connected within a signal layer, plus a
/// layer change wherever the node is free on BOTH layers. That last rule is an
/// approximation of via legality (a real via additionally needs drill clearance
/// from nearby holes), so the reachable region is a slight OVER-estimate. It
/// errs toward "the router could have got here", which keeps the overlay from
/// claiming a net was sealed in when it was merely search-limited.
fn floodReach(
    alloc: std.mem.Allocator,
    cells: []Cell,
    grid: router.Grid,
    n_signal: usize,
    seed: usize,
) std.mem.Allocator.Error!void {
    const nodes = grid.nx * grid.ny;
    if (seed >= cells.len or cells[seed] == .blocked) return;
    var queue: std.ArrayList(usize) = .empty;
    cells[seed] = .reached;
    try queue.append(alloc, seed);
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const key = queue.items[head];
        const layer = key / nodes;
        const node = key % nodes;
        const ix = node % grid.nx;
        const iy = node / grid.nx;
        for (neighbours) |d| {
            const nix = @as(i64, @intCast(ix)) + d[0];
            const niy = @as(i64, @intCast(iy)) + d[1];
            if (nix < 0 or niy < 0 or nix >= grid.nx or niy >= grid.ny) continue;
            const nkey = layer * nodes + @as(usize, @intCast(niy)) * grid.nx + @as(usize, @intCast(nix));
            if (cells[nkey] != .free) continue;
            cells[nkey] = .reached;
            try queue.append(alloc, nkey);
        }
        // Layer change at this node, where both faces are open.
        for (0..n_signal) |l| {
            if (l == layer) continue;
            const nkey = l * nodes + node;
            if (cells[nkey] != .free) continue;
            cells[nkey] = .reached;
            try queue.append(alloc, nkey);
        }
    }
}

/// Run-length encode one layer's cells as `(value, count-1)` triples — one
/// value byte plus a little-endian u16 — then base64 the byte stream.
///
/// The mask is overwhelmingly long runs of open board and long runs of pad
/// copper, so this collapses a ~130 k-cell layer to a few kB. A raw array would
/// dominate the response on every scrub step.
fn encodeLayer(alloc: std.mem.Allocator, cells: []const Cell) std.mem.Allocator.Error![]const u8 {
    var raw: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < cells.len) {
        const v = cells[i];
        var run: usize = 1;
        while (i + run < cells.len and cells[i + run] == v and run < run_value_max) run += 1;
        const count: u16 = @intCast(run - 1);
        try raw.append(alloc, @backingInt(v));
        try raw.append(alloc, @truncate(count));
        try raw.append(alloc, @truncate(count >> 8));
        i += run;
    }
    const enc = std.base64.standard.Encoder;
    const out = try alloc.alloc(u8, enc.calcSize(raw.items.len));
    return enc.encode(out, raw.items);
}

/// POST /api/route-vision/:name — the router's free-space view for one net at
/// one recorded decision.
///
/// Body is the `POST /api/pcb-route/:name` body (`parts`, `outline`, `routes`
/// — so the placement, board edge and pours match the route exactly) plus:
///   * `net`    — the net whose view this is (required; free space is per net)
///   * `pass`   — the lattice, verbatim from the `.initial` timeline event
///   * `event_tracks` / `event_vias` — the copper AS OF the event being viewed,
///     in the timeline's compact array encoding. Deliberately NOT spelled
///     `tracks`/`vias`: those keys already mean "the board's saved copper" to
///     `prepareRouteFromJson`, and drawing the finished board's openness
///     against an early decision is precisely the error this endpoint exists
///     to prevent.
///
/// Response `{grid:{ox,oy,g,nx,ny}, n_signal, layers:[b64,…], pads:[…]}` — one
/// RLE'd mask per signal layer (0 blocked / 1 free / 2 reached) plus the net's
/// pads tagged with whether the flood reached them.
pub fn routeVisionApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = pcb_layout_page.nameParam(req, res) orelse return;
    const body = pcb_layout_page.bodyParam(req, res) orelse return;
    const root = std.json.parseFromSliceLeaky(std.json.Value, req.arena, body, .{}) catch {
        res.status = 400;
        res.body = bad_json_msg;
        return;
    };
    if (root != .object) {
        res.status = 400;
        res.body = bad_json_msg;
        return;
    }
    const net_v = root.object.get("net") orelse {
        res.status = 400;
        res.body = no_net_msg;
        return;
    };
    if (net_v != .string) {
        res.status = 400;
        res.body = no_net_msg;
        return;
    }
    const pass = parsePass(root.object.get("pass"));
    if (!pass.recorded()) {
        res.status = 409;
        res.body = no_pass_msg;
        return;
    }

    var eval = Evaluator.init(ctx.allocator, ctx.project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        ctx.allocator.destroy(mr.eval);
    };
    const prep = pcb_layout_page.prepareRouteFromJson(req.arena, .{
        .project_dir = ctx.project_dir,
        .name = name,
        .sub = pcb_layout_page.subSlug(req),
        .root = root,
    }, &eval, &module_res) catch |e| {
        const fail = pcb_layout_page.routePrepFailure(e);
        res.status = fail.status;
        if (fail.msg) |m| res.body = m;
        return;
    };
    const net_i = netIndex(prep.placement, net_v.string) orelse {
        res.status = 404;
        res.body = no_net_msg;
        return;
    };

    const mask = router.visionMask(req.arena, .{
        .placement = prep.placement,
        .pass = pass,
        .net_i = net_i,
        .tracks = try parseTracks(req.arena, root.object.get("event_tracks")),
        .vias = try parseVias(req.arena, root.object.get("event_vias")),
        .zones = prep.scoped.existing_zones,
    }) catch {
        res.status = 500;
        res.body = vision_err_msg;
        return;
    } orelse {
        res.status = 409;
        res.body = no_pass_msg;
        return;
    };

    const nodes = mask.grid.nx * mask.grid.ny;
    const cells = try req.arena.alloc(Cell, mask.free.len);
    for (mask.free, 0..) |f, i| cells[i] = if (f != 0) .free else .blocked;

    // Seed the flood at the net's FIRST pad — the maze's own starting terminal.
    // Seeding every pad instead would paint two mutually-sealed pockets as
    // equally "reachable" and hide exactly the failure this mode exists to show.
    const pads = try netPadReach(req.arena, prep.placement, net_i, cells, mask, nodes);

    var aw: std.Io.Writer.Allocating = .init(req.arena);
    const w = &aw.writer;
    try w.print(
        "{{\"grid\":{{\"ox\":{d},\"oy\":{d},\"g\":{d},\"nx\":{d},\"ny\":{d}}},\"n_signal\":{d},\"layers\":[",
        .{ mask.grid.ox, mask.grid.oy, mask.grid.g, mask.grid.nx, mask.grid.ny, mask.n_signal },
    );
    for (0..mask.n_signal) |l| {
        if (l > 0) try w.writeByte(',');
        try w.writeByte('"');
        try w.writeAll(try encodeLayer(req.arena, cells[l * nodes ..][0..nodes]));
        try w.writeByte('"');
    }
    try w.writeAll("],\"pads\":[");
    for (pads, 0..) |p, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{{\"ref\":\"{s}\",\"pin\":\"{s}\",\"x\":{d},\"y\":{d},\"layer\":{d},\"reached\":{s}}}", .{
            p.ref,
            p.pin,
            p.x,
            p.y,
            p.layer,
            if (p.reached) "true" else "false",
        });
    }
    try w.writeAll("]}");
    res.content_type = .JSON;
    res.body = aw.written();
}

/// Flood from the net's first pad, then report every pad of the net with the
/// verdict. Mutates `cells` in place (promoting `.free` → `.reached`).
fn netPadReach(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    net_i: usize,
    cells: []Cell,
    mask: router.VisionMask,
    nodes: usize,
) std.mem.Allocator.Error![]const PadReach {
    var idx_of: std.StringHashMapUnmanaged(usize) = .empty;
    for (placement.parts, 0..) |p, i| try idx_of.put(alloc, p.ref_des, i);
    const pts = try router.netPoints(alloc, placement, &idx_of, placement.nets[net_i]);
    if (pts.len == 0) return &.{};

    const key = padKey(mask, pts[0], nodes);
    try floodReach(alloc, cells, mask.grid, mask.n_signal, key);

    var out: std.ArrayList(PadReach) = .empty;
    for (pts) |pt| {
        const k = padKey(mask, pt, nodes);
        try out.append(alloc, .{
            .ref = pt.ref_des,
            .pin = pt.pin,
            .x = pt.x,
            .y = pt.y,
            .layer = pt.layer,
            .reached = k < cells.len and cells[k] == .reached,
        });
    }
    return out.toOwnedSlice(alloc);
}

/// Flat (layer, node) key of a pad centre. A through pad is keyed on the top
/// layer, matching the maze's own convention that a `thru` pad exists on both.
fn padKey(mask: router.VisionMask, pt: router.NetPt, nodes: usize) usize {
    const cell = mask.grid.nearest(pt.x, pt.y);
    const layer: usize = if (pt.thru) 0 else @min(pt.layer, mask.n_signal - 1);
    return layer * nodes + mask.grid.node(cell[0], cell[1]);
}

/// A worst-and-best-case mask shape: one very long run (the open board) followed
/// by maximal alternation (the pad-dense region), so the round-trip is exercised
/// at both extremes of the encoder's run lengths.
fn samplePattern(cells: []Cell) void {
    for (cells, 0..) |*c, i| {
        if (i < 500) {
            c.* = .free;
            continue;
        }
        c.* = if (i % 2 == 0) .blocked else .reached;
    }
}

/// Inverse of `encodeLayer`, for the round-trip assertion.
fn decodeLayer(alloc: std.mem.Allocator, b64: []const u8) ![]const Cell {
    const dec = std.base64.standard.Decoder;
    const raw = try alloc.alloc(u8, try dec.calcSizeForSlice(b64));
    try dec.decode(raw, b64);
    var out: std.ArrayList(Cell) = .empty;
    var i: usize = 0;
    while (i < raw.len) : (i += 3) {
        const count = @as(usize, raw[i + 1]) | (@as(usize, raw[i + 2]) << 8);
        try out.appendNTimes(alloc, @fromBackingInt(@intCast(raw[i])), count + 1);
    }
    return out.toOwnedSlice(alloc);
}

// spec: Web Server - the route-vision mask survives a run-length round trip across both long runs and maximal alternation
test "run-length encoding round-trips a mask with alternating and long runs" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const alloc = arena_inst.allocator();

    var cells: [600]Cell = undefined;
    samplePattern(&cells);
    const decoded = try decodeLayer(alloc, try encodeLayer(alloc, &cells));
    try std.testing.expectEqualSlices(Cell, &cells, decoded);
}

// spec: Web Server - the route-vision reach flood promotes only free space connected to the seed pad, leaving a walled-off pocket unreached
test "the reach flood stops at a wall and leaves the far pocket unreached" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const alloc = arena_inst.allocator();

    // One signal layer, 11x5, with a full-height blocked wall down column 5:
    // free space left of it is reachable from the seed, free space right of it
    // is a sealed pocket the router could never enter.
    const grid = router.Grid{ .ox = 0, .oy = 0, .g = 1, .nx = 11, .ny = 5 };
    const cells = try alloc.alloc(Cell, grid.nx * grid.ny);
    @memset(cells, .free);
    for (0..grid.ny) |iy| cells[grid.node(5, iy)] = .blocked;

    try floodReach(alloc, cells, grid, 1, grid.node(0, 0));

    try std.testing.expectEqual(Cell.reached, cells[grid.node(4, 4)]);
    try std.testing.expectEqual(Cell.blocked, cells[grid.node(5, 2)]);
    try std.testing.expectEqual(Cell.free, cells[grid.node(6, 0)]);
    try std.testing.expectEqual(Cell.free, cells[grid.node(10, 4)]);
}

test "a pass object missing its grid extent parses as unrecorded" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const alloc = arena_inst.allocator();
    const parsed = try std.json.parseFromSliceLeaky(
        std.json.Value,
        alloc,
        "{\"ox\":0,\"oy\":0,\"g\":0.25,\"n_signal\":2}",
        .{},
    );
    try std.testing.expect(!parsePass(parsed).recorded());
    try std.testing.expect(!parsePass(null).recorded());
}
