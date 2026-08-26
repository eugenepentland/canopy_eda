//! Interactive routing sessions — the HTTP/serve half. A session pauses the
//! autorouter at each stuck net so a human can inspect the frontier, feed a
//! hint (a corridor, a rip-up, a priority bump, a layer restriction, or an
//! abandon), and resume; accepted hints distill into a `(pcb-plan (route …))`
//! fragment the design can adopt. One session per design name, held in the
//! shared `ServerState` (mutex-guarded, idle-evicted, capped) — the router
//! session owns its own arena and survives across requests. Board/timeline JSON
//! reuses `route_review.zig`'s writers so the front-end replays it unchanged.

const std = @import("std");
const httpz = @import("httpz");
const clock = @import("../infra/clock.zig");
const infra_fs = @import("../infra/fs.zig");
const serve_root = @import("../serve.zig");
const Server = serve_root.Server;
const optimizer = @import("../placement/optimizer.zig");
const board_layers = @import("../board_layers.zig");
const router = @import("../placement/router.zig");
const route_policy = @import("../placement/route_policy.zig");
const route_resume = @import("../route_resume.zig").ManualCompletion;
const drc_rules = @import("drc_rules.zig");
const layer_table_json = @import("layer_table_json.zig");
const env_mod = @import("../eval/env.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const modules_mod = @import("modules.zig");
const pcb_layout_page = @import("pcb_layout_page.zig");
const route_plan = @import("route_plan.zig");
const route_review = @import("route_review.zig");

const HandlerError = route_review.HandlerError;

// ── router-core session API ───────────────────────────────────────────────
// The router-core sibling agent owns `src/placement/route_session.zig` — the
// pausable interactive router. We consume its published surface: RouteSession
// (with .start/.runUntilEvent/.applyHint/.currentRun/.acceptedHints/.deinit),
// Status, Hint (layers carries a LayerMask bitset), StuckReport, and Waypoint.
const route_session = @import("../placement/route_session.zig");

// ── session table ─────────────────────────────────────────────────────────

/// At most this many live sessions across all designs (each pins a solved
/// placement + a router arena) — a new design's `start` is refused when full.
const max_sessions: usize = 4;
/// Sessions untouched for longer than this are freed on the next access.
const idle_secs: i64 = 15 * 60;
/// The durable allocator every persistent session structure uses. Request
/// arenas die with the response; session state must not.
const durable = std.heap.page_allocator;

// Shared literals (extracted so no message/fragment token repeats inline).
const err_missing_name = "missing design name";
const err_no_session = "no active route session for this design";
const err_unknown_net = "hint names an unknown net";
const err_oom = "out of memory";
const wave_open = "\n    (wave ";
const reason_open = ") (reason ";

/// One live session plus everything solving its board allocated: a dedicated
/// arena owning the evaluator, block, placement, and name copies (freed as a
/// unit on eviction), and the router session (owns its own arena).
const SessionEntry = struct {
    arena: *std.heap.ArenaAllocator,
    eval: *Evaluator,
    module_res: ?modules_mod.ResolvedBlock,
    placement: optimizer.Placement,
    name: []const u8,
    project_dir: []const u8,
    session: *route_session.RouteSession,
    status: route_session.Status,
    last_touch: i64,
};

/// The shared route-session table, embedded in `ServerState` so it lives for the
/// server's lifetime without a module-level global. All access is serialized by
/// `mutex`; a start blocks holding it for the full route, so operations on
/// route sessions run one at a time (an interactive, low-concurrency surface).
pub const Store = struct {
    mutex: infra_fs.Mutex = .{},
    map: std.StringHashMapUnmanaged(*SessionEntry) = .empty,
};

/// Free a session and its solve arena. Order matters: the router session is
/// released before the arena backing the placement it references.
fn freeEntry(entry: *SessionEntry) void {
    entry.session.deinit();
    entry.eval.deinit();
    if (entry.module_res) |mr| mr.eval.deinit();
    entry.arena.deinit();
    durable.destroy(entry.arena);
    durable.destroy(entry);
}

/// Drop every session untouched past the idle window. Caller holds `mutex`.
fn evictIdle(store: *Store, now: i64) void {
    while (findIdleKey(store, now)) |key| {
        if (store.map.fetchRemove(key)) |kv| {
            freeEntry(kv.value);
            durable.free(kv.key);
        }
    }
}

/// The first idle session's key, or null when none is idle.
fn findIdleKey(store: *Store, now: i64) ?[]const u8 {
    var it = store.map.iterator();
    while (it.next()) |e| {
        if (now - e.value_ptr.*.last_touch > idle_secs) return e.key_ptr.*;
    }
    return null;
}

/// Insert `entry` for `name`, discarding any existing session for that design.
fn replaceSession(store: *Store, name: []const u8, entry: *SessionEntry) std.mem.Allocator.Error!void {
    const key = try durable.dupe(u8, name);
    errdefer durable.free(key);
    if (store.map.fetchRemove(name)) |kv| {
        freeEntry(kv.value);
        durable.free(kv.key);
    }
    try store.map.put(durable, key, entry);
}

// ── HTTP handlers ─────────────────────────────────────────────────────────

/// POST /api/route-session/:name/start — create (replacing any existing)
/// session for the design, run the first event, and answer full state. An
/// optional `{"parts":[…]}` body places the board as drawn, mirroring
/// /api/design-route-review/run.
pub fn startSessionApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const arena = req.arena;
    const name = req.param("name") orelse return route_review.jsonError(arena, res, 404, err_missing_name);
    const known = route_review.isListedDesign(arena, ctx.project_dir, name) orelse
        return route_review.jsonError(arena, res, 500, "could not list the project designs");
    if (!known) return route_review.jsonError(arena, res, 404, "no design by that name");

    const opts = pcb_layout_page.pngRequestFromQuery(arena, req);
    const poses: []const optimizer.RefPose =
        if (req.body()) |body| try route_review.parsePosesFromBody(arena, body) else &.{};

    const store = &ctx.state.route_sessions;
    store.mutex.lock();
    defer store.mutex.unlock();
    const now = clock.timestamp();
    evictIdle(store, now);
    if (store.map.get(name) == null and store.map.count() >= max_sessions)
        return route_review.jsonError(arena, res, 429, "too many active route sessions — discard one first");

    const entry = createSession(ctx.project_dir, name, opts, poses) catch |e| {
        const fail = createFail(e);
        return route_review.jsonError(arena, res, fail.status, fail.message);
    };
    entry.last_touch = now;
    replaceSession(store, name, entry) catch {
        freeEntry(entry);
        return route_review.jsonError(arena, res, 500, "could not register the route session");
    };
    try respondState(arena, res, entry);
}

/// GET /api/route-session/:name — current state without advancing the router.
pub fn getSessionApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const arena = req.arena;
    const name = req.param("name") orelse return route_review.jsonError(arena, res, 404, err_missing_name);
    const store = &ctx.state.route_sessions;
    store.mutex.lock();
    defer store.mutex.unlock();
    evictIdle(store, clock.timestamp());
    const entry = store.map.get(name) orelse
        return route_review.jsonError(arena, res, 404, err_no_session);
    entry.last_touch = clock.timestamp();
    try respondState(arena, res, entry);
}

/// POST /api/route-session/:name/hint — apply one hint and advance the router.
/// A hint naming an unknown net (or malformed) is a 4xx that leaves the session
/// untouched.
pub fn hintSessionApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const arena = req.arena;
    const name = req.param("name") orelse return route_review.jsonError(arena, res, 404, err_missing_name);
    const body = req.body() orelse return route_review.jsonError(arena, res, 400, "missing hint body");
    const store = &ctx.state.route_sessions;
    store.mutex.lock();
    defer store.mutex.unlock();
    evictIdle(store, clock.timestamp());
    const entry = store.map.get(name) orelse
        return route_review.jsonError(arena, res, 404, err_no_session);
    entry.last_touch = clock.timestamp();

    switch (parseHint(arena, entry.arena.allocator(), entry.placement, body)) {
        .err => |e| return route_review.jsonError(arena, res, e.status, e.message),
        .ok => |hint| {
            entry.session.applyHint(hint) catch
                return route_review.jsonError(arena, res, 500, "the router rejected the hint");
            entry.status = entry.session.runUntilEvent() catch
                return route_review.jsonError(arena, res, 500, "the router failed after the hint");
            try respondState(arena, res, entry);
        },
    }
}

/// DELETE /api/route-session/:name — discard the design's session.
pub fn deleteSessionApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const arena = req.arena;
    const name = req.param("name") orelse return route_review.jsonError(arena, res, 404, err_missing_name);
    const store = &ctx.state.route_sessions;
    store.mutex.lock();
    defer store.mutex.unlock();
    evictIdle(store, clock.timestamp());
    const discarded = if (store.map.fetchRemove(name)) |kv| blk: {
        freeEntry(kv.value);
        durable.free(kv.key);
        break :blk true;
    } else false;
    var aw: std.Io.Writer.Allocating = .init(arena);
    try aw.writer.print("{{\"ok\":true,\"discarded\":{s}}}", .{if (discarded) "true" else "false"});
    res.content_type = .JSON;
    res.body = aw.written();
}

/// GET /api/route-session/:name/distill — render accepted hints as a
/// `(pcb-plan (route …))` fragment.
pub fn distillSessionApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const arena = req.arena;
    const name = req.param("name") orelse return route_review.jsonError(arena, res, 404, err_missing_name);
    const store = &ctx.state.route_sessions;
    store.mutex.lock();
    defer store.mutex.unlock();
    evictIdle(store, clock.timestamp());
    const entry = store.map.get(name) orelse
        return route_review.jsonError(arena, res, 404, err_no_session);
    entry.last_touch = clock.timestamp();
    const hints = entry.session.acceptedHints();
    const fragment = try distillFragment(arena, entry.placement, hints);
    var aw: std.Io.Writer.Allocating = .init(arena);
    try aw.writer.writeAll("{\"ok\":true,\"fragment\":");
    try route_review.writeJsonString(&aw.writer, fragment);
    try aw.writer.print(",\"hints\":{d}}}", .{hints.len});
    res.content_type = .JSON;
    res.body = aw.written();
}

// ── session construction ──────────────────────────────────────────────────

/// Reuses the solve's own error set (so `solveForRequest` propagates verbatim,
/// letting `createFail` share one classification) plus the router-start failure.
const CreateError = pcb_layout_page.PngError || error{RouterFailed};

/// Solve `name` exactly as the design replay does (starred layout preferred, or
/// the posted poses placed verbatim), then start a router session and run its
/// first event. Everything durable lives in a dedicated arena the entry owns.
fn createSession(
    project_dir: []const u8,
    name: []const u8,
    opts: pcb_layout_page.PngRequest,
    poses: []const optimizer.RefPose,
) CreateError!*SessionEntry {
    const arena = try durable.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(durable);
    errdefer {
        arena.deinit();
        durable.destroy(arena);
    }
    const sa = arena.allocator();
    const pdir = try sa.dupe(u8, project_dir);
    const name_dup = try sa.dupe(u8, name);
    const eval_ptr = try sa.create(Evaluator);
    eval_ptr.* = Evaluator.init(sa, pdir);
    var module_res: ?modules_mod.ResolvedBlock = null;
    const solved = try pcb_layout_page.solveForRequest(sa, pdir, name, opts, eval_ptr, &module_res);
    // Hold the placement at a stable arena address: the router session borrows it
    // by pointer for its whole life, and the arena outlives the session.
    const placement = try sa.create(optimizer.Placement);
    if (poses.len > 0) {
        // Inherit the board edge solveForRequest already folded onto
        // solved.placement — the maze + bend-smoothing keep this session's copper
        // inside it (and DRC checks it) instead of falling back to the parts bbox.
        placement.* = optimizer.placeFromPoses(sa, solved.block, pdir, .{
            .poses = poses,
            .outline = optimizer.outlineOf(&solved.placement),
        }, .{}) catch return error.BuildFailed;
    } else {
        placement.* = solved.placement;
    }

    const params = placement.rules.design.routeParams();
    const options = route_plan.lowerOrEmpty(sa, solved.block, placement.*);
    const session = route_session.RouteSession.start(durable, placement, params, options) catch
        return error.RouterFailed;
    errdefer session.deinit();
    const status = session.runUntilEvent() catch return error.RouterFailed;

    const entry = try durable.create(SessionEntry);
    entry.* = .{
        .arena = arena,
        .eval = eval_ptr,
        .module_res = module_res,
        .placement = placement.*,
        .name = name_dup,
        .project_dir = pdir,
        .session = session,
        .status = status,
        .last_touch = clock.timestamp(),
    };
    return entry;
}

/// The HTTP status + message for a failed `createSession` — one classifier so
/// the two facets can't drift (and one switch, not two).
fn createFail(e: CreateError) struct { status: u16, message: []const u8 } {
    return switch (e) {
        error.BlockNotFound => .{ .status = 404, .message = "no design or module by that name" },
        error.SubNotFound => .{ .status = 404, .message = "no sub-block by that name" },
        error.RouterFailed => .{ .status = 500, .message = "the router failed to start" },
        else => .{ .status = 500, .message = "could not build the placement" },
    };
}

// ── state serialization ───────────────────────────────────────────────────

/// Write the full session-state JSON and set the response.
fn respondState(arena: std.mem.Allocator, res: *httpz.Response, entry: *SessionEntry) HandlerError!void {
    var aw: std.Io.Writer.Allocating = .init(arena);
    try writeSessionState(arena, &aw.writer, entry);
    res.content_type = .JSON;
    res.body = aw.written();
}

/// The route-session wire shape: envelope + the shared board/timeline payload
/// (reused verbatim from route_review so the front-end replays it unchanged) +
/// the status-specific `stuck`/`final` block + the accepted-hint count.
fn writeSessionState(arena: std.mem.Allocator, w: *std.Io.Writer, entry: *SessionEntry) HandlerError!void {
    const run = entry.session.currentRun();
    const hints_accepted = entry.session.acceptedHints().len;
    try w.writeAll("{\"ok\":true,\"session\":");
    try route_review.writeJsonString(w, entry.name);
    try w.print(",\"status\":\"{s}\",\"events\":", .{statusStr(entry.status)});
    try route_review.writeTimelineArray(w, entry.placement, run.timeline);
    try route_review.writeNets(w, entry.placement);
    try route_review.writeNetClasses(w, entry.placement);
    try route_review.writeDesignBoundsAndOutline(w, entry.placement);
    try route_review.writeParts(arena, w, entry.placement);
    switch (entry.status) {
        .stuck => |rep| try writeStuck(arena, w, entry.placement, rep),
        .done => try writeDoneFinal(arena, w, entry, run.routed),
        .aborted => {},
    }
    try w.print(",\"hints_accepted\":{d}}}", .{hints_accepted});
}

/// The status string the wire reports.
fn statusStr(status: route_session.Status) []const u8 {
    return switch (status) {
        .stuck => "stuck",
        .done => "done",
        .aborted => "aborted",
    };
}

/// The `"final"` block (route_review's shape) for a completed session, with the
/// DRC filtered through the design's rule overrides like the replay does.
fn writeDoneFinal(
    arena: std.mem.Allocator,
    w: *std.Io.Writer,
    entry: *SessionEntry,
    routed: router.RouteResult,
) HandlerError!void {
    const clearance = entry.placement.rules.design.routeParams().clearance;
    const violations = drc_rules.checkFiltered(
        arena,
        entry.project_dir,
        entry.name,
        entry.placement,
        routed,
        clearance,
    );
    try route_review.writeFinal(w, entry.placement, routed, violations);
}

/// The `"stuck"` block: the paused net, its pads, the frontier grid (cells
/// base64-encoded row-major), the per-layer occupancy grids over the same
/// window, competing nets, and per-layer occupancy fractions.
fn writeStuck(
    arena: std.mem.Allocator,
    w: *std.Io.Writer,
    placement: optimizer.Placement,
    rep: route_session.StuckReport,
) HandlerError!void {
    try w.writeAll(",\"stuck\":{\"net\":");
    try writeNetRef(w, placement, rep.net_i);
    try w.print(",\"attempts\":{d},\"pads\":[", .{rep.attempts});
    for (rep.pads, 0..) |p, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("[{d},{d}]", .{ p[0], p[1] });
    }
    try w.print("],\"frontier\":{{\"origin\":[{d},{d}],\"cell_mm\":{d},\"cols\":{d},\"rows\":{d},\"cells\":", .{
        rep.frontier.origin[0], rep.frontier.origin[1], rep.frontier.cell_mm, rep.frontier.cols, rep.frontier.rows,
    });
    try writeBase64Cells(arena, w, rep.frontier.cells);
    try w.writeAll("},\"occupancy\":[");
    for (rep.occupancy, 0..) |grid, i| {
        if (i > 0) try w.writeByte(',');
        var buf: [8]u8 = undefined;
        try w.writeAll("{\"layer\":");
        try route_review.writeJsonString(w, placement.rules.signalLayerName(@intCast(i), &buf));
        try w.writeAll(",\"cells\":");
        try writeBase64Cells(arena, w, grid);
        try w.writeByte('}');
    }
    try w.writeAll("],\"blockers\":[");
    for (rep.blockers, 0..) |b, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"net\":");
        try writeNetRef(w, placement, b.net_i);
        try w.print(",\"share\":{d},\"rip_cost\":{d}}}", .{ b.share, b.rip_cost });
    }
    try w.writeAll("],\"layer_occupancy\":[");
    for (rep.layer_occupancy, 0..) |occ, i| {
        if (i > 0) try w.writeByte(',');
        var buf: [8]u8 = undefined;
        try w.writeAll("{\"layer\":");
        try route_review.writeJsonString(w, placement.rules.signalLayerName(@intCast(i), &buf));
        try w.print(",\"occupied\":{d}}}", .{occ});
    }
    try w.writeAll("]}");
}

/// A net index as its JSON name, or `null` when out of range.
fn writeNetRef(w: *std.Io.Writer, placement: optimizer.Placement, net_i: usize) HandlerError!void {
    if (net_i < placement.nets.len)
        try route_review.writeJsonString(w, placement.nets[net_i].name)
    else
        try w.writeAll("null");
}

/// Emit the frontier cells as a base64 JSON string (one byte per cell).
fn writeBase64Cells(arena: std.mem.Allocator, w: *std.Io.Writer, cells: []const u2) HandlerError!void {
    const bytes = try arena.alloc(u8, cells.len);
    for (cells, 0..) |c, i| bytes[i] = c;
    const enc = std.base64.standard.Encoder;
    const out = try arena.alloc(u8, enc.calcSize(bytes.len));
    try w.writeByte('"');
    try w.writeAll(enc.encode(out, bytes));
    try w.writeByte('"');
}

// ── hint parsing ──────────────────────────────────────────────────────────

/// A parsed hint, or the 4xx/5xx to answer with (which leaves the session
/// unadvanced — the caller only applies the `.ok` variant).
const HintParse = union(enum) {
    ok: route_session.Hint,
    err: struct { status: u16, message: []const u8 },
};

fn hintErr(status: u16, message: []const u8) HintParse {
    return .{ .err = .{ .status = status, .message = message } };
}

/// The flattened-net index for `name` (exact match, then case-insensitive).
fn resolveNetIndex(placement: optimizer.Placement, name: []const u8) ?usize {
    for (placement.nets, 0..) |net, i| if (std.mem.eql(u8, net.name, name)) return i;
    for (placement.nets, 0..) |net, i| if (std.ascii.eqlIgnoreCase(net.name, name)) return i;
    return null;
}

/// The signal-layer bit for a copper-layer name ("F.Cu"/"B.Cu"/"In1.Cu"…),
/// case-insensitive — the inverse of `BoardRules.signalLayerName`, matching how
/// plan_resolve lowers an `(allowed-layers …)` name to a `LayerMask` bit.
fn layerBit(rules: optimizer.BoardRules, name: []const u8) ?u6 {
    const sig = rules.layerStack().signalIndexOfName(name) orelse return null;
    return sig.bit();
}

/// Parse a hint request body. `transient` parses the JSON; `store_alloc` (the
/// session arena) backs the retained hint memory so it outlives the request.
fn parseHint(
    transient: std.mem.Allocator,
    store_alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    body: []const u8,
) HintParse {
    const root = std.json.parseFromSliceLeaky(std.json.Value, transient, body, .{}) catch
        return hintErr(400, "malformed hint JSON");
    if (root != .object) return hintErr(400, "hint body must be a JSON object");
    const action_v = root.object.get("action") orelse return hintErr(400, "hint is missing an action");
    if (action_v != .string) return hintErr(400, "hint action must be a string");
    const action = action_v.string;
    if (std.mem.eql(u8, action, "corridor")) return parseCorridor(store_alloc, placement, root.object);
    if (std.mem.eql(u8, action, "rip")) return parseRip(store_alloc, placement, root.object);
    if (std.mem.eql(u8, action, "route_now")) return parseSingleNet(placement, root.object, .route_now);
    if (std.mem.eql(u8, action, "layers")) return parseLayers(placement, root.object);
    if (std.mem.eql(u8, action, "abandon")) return parseSingleNet(placement, root.object, .abandon);
    return hintErr(400, "unknown hint action");
}

const SingleKind = enum { route_now, abandon };

/// route_now / abandon — a single named net, no retained allocation.
fn parseSingleNet(placement: optimizer.Placement, obj: std.json.ObjectMap, kind: SingleKind) HintParse {
    const net_i = objNetIndex(placement, obj) orelse return hintErr(400, err_unknown_net);
    return .{ .ok = switch (kind) {
        .route_now => .{ .route_now = .{ .net_i = net_i } },
        .abandon => .{ .abandon = .{ .net_i = net_i } },
    } };
}

/// corridor — a net plus an ordered `points:[[x,y]]` world-space corridor. The
/// router `Waypoint` is layerless (a spatial guide), so any 3rd element is
/// ignored.
fn parseCorridor(store_alloc: std.mem.Allocator, placement: optimizer.Placement, obj: std.json.ObjectMap) HintParse {
    const net_i = objNetIndex(placement, obj) orelse return hintErr(400, err_unknown_net);
    const points_v = obj.get("points") orelse return hintErr(400, "corridor hint is missing points");
    if (points_v != .array) return hintErr(400, "corridor points must be an array");
    var pts: std.ArrayList(route_session.Waypoint) = .empty;
    for (points_v.array.items) |pv| {
        if (pv != .array or pv.array.items.len < 2) return hintErr(400, "each corridor point must be [x,y]");
        pts.append(store_alloc, .{ .x = jsonNum(pv.array.items[0]), .y = jsonNum(pv.array.items[1]) }) catch
            return hintErr(500, err_oom);
    }
    if (pts.items.len == 0) return hintErr(400, "corridor hint names no points");
    return .{ .ok = .{ .corridor = .{ .net_i = net_i, .points = pts.items } } };
}

/// rip — one or more named nets to tear up.
fn parseRip(store_alloc: std.mem.Allocator, placement: optimizer.Placement, obj: std.json.ObjectMap) HintParse {
    const nets_v = obj.get("nets") orelse return hintErr(400, "rip hint is missing nets");
    if (nets_v != .array) return hintErr(400, "rip nets must be an array");
    var idx: std.ArrayList(usize) = .empty;
    for (nets_v.array.items) |nv| {
        if (nv != .string) return hintErr(400, "rip nets must be strings");
        const ni = resolveNetIndex(placement, nv.string) orelse return hintErr(400, err_unknown_net);
        idx.append(store_alloc, ni) catch return hintErr(500, err_oom);
    }
    if (idx.items.len == 0) return hintErr(400, "rip hint names no nets");
    return .{ .ok = .{ .rip = .{ .nets = idx.items } } };
}

/// layers — restrict a net to the named copper layers, lowered to the router's
/// `LayerMask` bitset (bit L = signal layer L).
fn parseLayers(placement: optimizer.Placement, obj: std.json.ObjectMap) HintParse {
    const net_i = objNetIndex(placement, obj) orelse return hintErr(400, err_unknown_net);
    const allowed_v = obj.get("allowed") orelse return hintErr(400, "layers hint is missing allowed layers");
    if (allowed_v != .array) return hintErr(400, "allowed must be an array");
    var mask: route_session.LayerMask = 0;
    for (allowed_v.array.items) |lv| {
        if (lv != .string) return hintErr(400, "allowed layers must be strings");
        const bit = layerBit(placement.rules, lv.string) orelse return hintErr(400, "unknown copper layer name");
        mask |= @as(u64, 1) << bit;
    }
    if (mask == 0) return hintErr(400, "layers hint names no layers");
    return .{ .ok = .{ .layers = .{ .net_i = net_i, .allowed = mask } } };
}

/// The `"net"` string field resolved to a flattened-net index.
fn objNetIndex(placement: optimizer.Placement, obj: std.json.ObjectMap) ?usize {
    const net_v = obj.get("net") orelse return null;
    if (net_v != .string) return null;
    return resolveNetIndex(placement, net_v.string);
}

/// A JSON number (int or float) as f64; other kinds → 0.
fn jsonNum(v: std.json.Value) f64 {
    if (v == .float) return v.float;
    if (v == .integer) return @floatFromInt(v.integer);
    return 0;
}

// ── distill ───────────────────────────────────────────────────────────────

const WaveKind = enum { route_now, corridor, layers };

/// Render the accepted hints as a `(pcb-plan (route …))` fragment: route_now
/// hints become the first waves (priority order), then corridors (waypoints),
/// then layer restrictions (allowed-layers). rip/abandon carry no plan
/// directive, so they are documented as trailing comments.
fn distillFragment(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    hints: []const route_session.Hint,
) HandlerError![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    var have_waves = false;
    for (hints) |h| switch (h) {
        .corridor, .layers, .route_now => have_waves = true,
        else => {},
    };
    if (have_waves) {
        try w.writeAll("(pcb-plan\n  (route");
        try emitWaves(w, placement, hints, .route_now);
        try emitWaves(w, placement, hints, .corridor);
        try emitWaves(w, placement, hints, .layers);
        try w.writeAll("))");
    } else {
        try w.writeAll("(pcb-plan)");
    }
    for (hints) |h| switch (h) {
        .rip => |r| try emitRipComment(w, placement, r.nets),
        .abandon => |a| try emitAbandonComment(w, placement, a.net_i),
        else => {},
    };
    return aw.written();
}

/// Emit every hint of one kind as a route wave.
fn emitWaves(
    w: *std.Io.Writer,
    placement: optimizer.Placement,
    hints: []const route_session.Hint,
    kind: WaveKind,
) HandlerError!void {
    for (hints) |h| switch (h) {
        .route_now => |x| if (kind == .route_now) try emitRouteNow(w, placement, x.net_i),
        .corridor => |x| if (kind == .corridor) try emitCorridor(w, placement, x.net_i, x.points),
        .layers => |x| if (kind == .layers) try emitLayers(w, placement, x.net_i, x.allowed),
        else => {},
    };
}

fn emitRouteNow(w: *std.Io.Writer, placement: optimizer.Placement, net_i: usize) HandlerError!void {
    const name = netNameOr(placement, net_i, "net");
    try w.writeAll(wave_open);
    try writeWaveName(w, "route-now", name);
    try w.writeAll(" (nets ");
    try writeSexprStr(w, name);
    try w.writeAll(reason_open);
    try writeSexprStr(w, "operator route-now priority");
    try w.writeAll("))");
}

fn emitCorridor(
    w: *std.Io.Writer,
    placement: optimizer.Placement,
    net_i: usize,
    points: []const route_session.Waypoint,
) HandlerError!void {
    const name = netNameOr(placement, net_i, "net");
    try w.writeAll(wave_open);
    try writeWaveName(w, "corridor", name);
    try w.writeAll(" (nets ");
    try writeSexprStr(w, name);
    try w.writeAll(") (waypoints");
    // The router waypoint is layerless; the DSL `(at X Y "layer")` requires a
    // layer, so the fragment defaults to the top layer for the user to edit.
    for (points) |p| try w.print(" (at {d} {d} \"" ++ board_layers.f_cu ++ "\")", .{ p.x, p.y });
    try w.writeAll(reason_open);
    try writeSexprStr(w, "operator corridor hint");
    try w.writeAll("))");
}

fn emitLayers(
    w: *std.Io.Writer,
    placement: optimizer.Placement,
    net_i: usize,
    allowed: route_session.LayerMask,
) HandlerError!void {
    const name = netNameOr(placement, net_i, "net");
    try w.writeAll(wave_open);
    try writeWaveName(w, "layers", name);
    try w.writeAll(" (nets ");
    try writeSexprStr(w, name);
    try w.writeAll(") (allowed-layers");
    const count = placement.rules.signalLayerCount();
    var sig: u8 = 0;
    var buf: [12]u8 = undefined;
    while (sig < count and sig < 64) : (sig += 1) {
        if (allowed & (@as(u64, 1) << @intCast(sig)) == 0) continue;
        try w.writeByte(' ');
        try writeSexprStr(w, placement.rules.signalLayerName(sig, &buf));
    }
    try w.writeAll(reason_open);
    try writeSexprStr(w, "operator layer restriction");
    try w.writeAll("))");
}

fn emitRipComment(w: *std.Io.Writer, placement: optimizer.Placement, nets: []const usize) HandlerError!void {
    try w.writeAll("\n; rip:");
    for (nets) |ni| {
        try w.writeByte(' ');
        try w.writeAll(netNameOr(placement, ni, "?"));
    }
    try w.writeAll(" -- ripped up during the session (not a persisted plan directive)");
}

fn emitAbandonComment(w: *std.Io.Writer, placement: optimizer.Placement, net_i: usize) HandlerError!void {
    try w.print("\n; abandon: {s} -- operator left this net unrouted", .{netNameOr(placement, net_i, "?")});
}

/// The net name at `net_i`, or `fallback` when out of range.
fn netNameOr(placement: optimizer.Placement, net_i: usize, fallback: []const u8) []const u8 {
    return if (net_i < placement.nets.len) placement.nets[net_i].name else fallback;
}

/// Emit `"hint <kind> <name>"` as an S-expression string (escaped).
fn writeWaveName(w: *std.Io.Writer, kind: []const u8, name: []const u8) HandlerError!void {
    try w.writeByte('"');
    try w.print("hint {s} ", .{kind});
    try writeSexprEscaped(w, name);
    try w.writeByte('"');
}

/// Emit `value` as a quoted S-expression string literal.
fn writeSexprStr(w: *std.Io.Writer, value: []const u8) HandlerError!void {
    try w.writeByte('"');
    try writeSexprEscaped(w, value);
    try w.writeByte('"');
}

/// Escape the body of an S-expression string literal (quote + backslash).
fn writeSexprEscaped(w: *std.Io.Writer, value: []const u8) HandlerError!void {
    for (value) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        else => try w.writeByte(c),
    };
}

// ── manual-route completion API ───────────────────────────────────────────

// A dashed editor suggestion asks a much smaller question than Route board:
// join this trace head to its selected destination without disturbing existing
// copper. Reuse the gap router already owned by this interactive-routing module
// so the request avoids subcircuit routing and whole-board reporting passes.
const completion_margin_mm: f64 = 6.0;
const completion_deadline_ms: u64 = 1200;
const completion_bad_json = "invalid route completion request";
const completion_failed = "route completion failed";
const CompletionError = error{InvalidPoints} || std.mem.Allocator.Error;

fn completionPoint(p: route_resume.Point) router.NetPt {
    return .{ .x = p.point.x, .y = p.point.y, .layer = p.point.layer };
}

fn completionGap(from: route_resume.Point, to: route_resume.Point) CompletionError!router.Gap {
    if (from.net != to.net) return error.InvalidPoints;
    return .{ .net_i = from.net, .from = completionPoint(from), .to = completionPoint(to) };
}

fn completionWindow(points: []const route_resume.Point) CompletionError!router.GapWindow {
    if (points.len < 2 or points.len % 2 != 0) return error.InvalidPoints;
    var window = router.GapWindow.around(try completionGap(points[0], points[1]), completion_margin_mm);
    var i: usize = 2;
    while (i < points.len) : (i += 2) {
        const next = router.GapWindow.around(try completionGap(points[i], points[i + 1]), completion_margin_mm);
        window.x0 = @min(window.x0, next.x0);
        window.y0 = @min(window.y0, next.y0);
        window.x1 = @max(window.x1, next.x1);
        window.y1 = @max(window.y1, next.y1);
    }
    return window;
}

fn completionZones(
    alloc: std.mem.Allocator,
    prep: pcb_layout_page.RoutePrep,
    gaps: []const router.Gap,
    window: router.GapWindow,
    options: route_policy.Options,
) CompletionError![]const route_policy.ExistingZone {
    var allowed: u64 = 0;
    var constrained = false;
    for (gaps) |gap| {
        if (gap.net_i >= options.net.len) continue;
        const mask = options.net[gap.net_i].allowed_layers;
        if (mask == 0) continue;
        allowed = if (constrained) allowed & mask else mask;
        constrained = true;
    }
    if (!constrained) return prep.scoped.existing_zones;
    const polygon = try alloc.dupe([2]f64, &.{
        .{ window.x0, window.y0 }, .{ window.x1, window.y0 },
        .{ window.x1, window.y1 }, .{ window.x0, window.y1 },
    });
    var zones: std.ArrayList(route_policy.ExistingZone) = .empty;
    try zones.appendSlice(alloc, prep.scoped.existing_zones);
    for (0..prep.placement.rules.signalLayerCount()) |layer| {
        if (layer < 64 and allowed & (@as(u64, 1) << @intCast(layer)) != 0) continue;
        try zones.append(alloc, .{
            .polygon = polygon,
            .layer = @intCast(layer),
            .net = -2,
            .tracks_blocked = true,
            .copper = false,
        });
    }
    return zones.toOwnedSlice(alloc);
}

fn completeRoute(
    alloc: std.mem.Allocator,
    prep: pcb_layout_page.RoutePrep,
    submitted: router.RouteResult,
) CompletionError!router.RouteResult {
    const points = prep.steering.resume_points;
    const window = try completionWindow(points);
    const gaps = try alloc.alloc(router.Gap, points.len / 2);
    for (gaps, 0..) |*gap, i| gap.* = try completionGap(points[i * 2], points[i * 2 + 1]);
    const options = route_plan.lowerOrEmpty(alloc, prep.eff_block, prep.placement);
    const completions = try router.closeGaps(alloc, prep.placement, prep.rp, .{
        .tracks = submitted.tracks,
        .vias = submitted.vias,
        .zones = try completionZones(alloc, prep, gaps, window, options),
        .reserved_lanes = options.guides.reserved,
    }, gaps, .{
        .ripup = false,
        .shape = .fallback,
        .raster = .{
            .window = window,
            .stop = .{ .deadline_ns = clock.nanoTimestamp() + @as(i128, completion_deadline_ms) * @as(i128, clock.ns_per_ms) },
        },
    });

    var tracks: std.ArrayList(router.Track) = .empty;
    var vias: std.ArrayList(router.Via) = .empty;
    var failed: std.ArrayList([]const u8) = .empty;
    var routed: usize = 0;
    for (completions, gaps) |path, gap| {
        if (path) |p| {
            try tracks.appendSlice(alloc, p.tracks);
            try vias.appendSlice(alloc, p.vias);
            routed += 1;
        } else if (gap.net_i < prep.placement.nets.len) {
            try failed.append(alloc, prep.placement.nets[gap.net_i].name);
        }
    }
    return .{
        .tracks = try tracks.toOwnedSlice(alloc),
        .vias = try vias.toOwnedSlice(alloc),
        .routed = routed,
        .total = gaps.len,
        .failed = try failed.toOwnedSlice(alloc),
    };
}

fn completionNetName(prep: pcb_layout_page.RoutePrep, index: i32) []const u8 {
    if (index < 0 or index >= prep.placement.nets.len) return "";
    return prep.placement.nets[@intCast(index)].name;
}

fn writeCompletion(w: *std.Io.Writer, prep: pcb_layout_page.RoutePrep, result: router.RouteResult) std.Io.Writer.Error!void {
    try w.writeAll("{\"tracks\":[");
    for (result.tracks, 0..) |track, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{{\"x1\":{d},\"y1\":{d},\"x2\":{d},\"y2\":{d},\"l\":{d},\"w\":{d},\"net\":", .{
            track.x1, track.y1, track.x2, track.y2, track.layer, track.width,
        });
        try pcb_layout_page.writeJsonStr(w, completionNetName(prep, track.net));
        try w.writeAll(",\"source\":\"autorouter\"}");
    }
    try w.writeAll("],\"vias\":[");
    for (result.vias, 0..) |via, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{{\"x\":{d},\"y\":{d},\"d\":{d},\"drill\":{d},\"net\":", .{ via.x, via.y, via.dia, via.drill });
        try pcb_layout_page.writeJsonStr(w, completionNetName(prep, via.net));
        try w.writeAll(",\"source\":\"autorouter\"}");
    }
    try w.writeAll("],\"rf_paths\":[],\"unrouted\":[");
    for (result.failed, 0..) |name, i| {
        if (i > 0) try w.writeByte(',');
        try pcb_layout_page.writeJsonStr(w, name);
    }
    try w.print("],\"routed\":{d},\"total\":{d}}}", .{ result.routed, result.total });
}

/// POST /api/pcb-route-complete/:name — route only the explicit head→target
/// pairs in `resume_points`, returning only newly proposed copper.
pub fn completeApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = pcb_layout_page.nameParam(req, res) orelse return;
    const body = pcb_layout_page.bodyParam(req, res) orelse return;
    const root = std.json.parseFromSliceLeaky(std.json.Value, req.arena, body, .{}) catch {
        res.status = 400;
        res.body = completion_bad_json;
        return;
    };
    var eval = Evaluator.init(ctx.allocator, ctx.project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |resolved| {
        resolved.eval.deinit();
        ctx.allocator.destroy(resolved.eval);
    };
    const prep = pcb_layout_page.prepareRouteFromJson(ctx.allocator, .{
        .project_dir = ctx.project_dir,
        .name = name,
        .sub = pcb_layout_page.subSlug(req),
        .root = root,
        .default_effort = .one_shot,
    }, &eval, &module_res) catch |err| {
        const failure = pcb_layout_page.routePrepFailure(err);
        res.status = failure.status;
        if (failure.msg) |message| res.body = message;
        return;
    };
    const empty = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 0 };
    const submitted = if (pcb_layout_page.parseSavedRoutes(ctx.allocator, root)) |saved|
        pcb_layout_page.restoreRoutes(ctx.allocator, saved, prep.placement.nets) orelse empty
    else
        empty;
    const result = completeRoute(ctx.allocator, prep, submitted) catch |err| {
        res.status = if (err == error.InvalidPoints) 400 else 500;
        res.body = if (err == error.InvalidPoints) completion_bad_json else completion_failed;
        return;
    };
    var aw: std.Io.Writer.Allocating = .init(ctx.allocator);
    try writeCompletion(&aw.writer, prep, result);
    res.content_type = .JSON;
    res.body = aw.written();
}

// ── tests ─────────────────────────────────────────────────────────────────

const testing = std.testing;
const geometry = @import("../placement/geometry.zig");
const export_kicad = @import("../export_kicad.zig");
const parser = @import("../sexpr/parser.zig");

test "manual completion bounds the search around every head and target" {
    const points = [_]route_resume.Point{
        .{ .net = 2, .point = .{ .x = 10, .y = 20, .layer = 0 } },
        .{ .net = 2, .point = .{ .x = 18, .y = 24, .layer = 0 } },
        .{ .net = 3, .point = .{ .x = 9, .y = 19, .layer = 0 } },
        .{ .net = 3, .point = .{ .x = 19, .y = 25, .layer = 0 } },
    };
    const window = try completionWindow(&points);
    try testing.expectEqual(@as(f64, 3), window.x0);
    try testing.expectEqual(@as(f64, 13), window.y0);
    try testing.expectEqual(@as(f64, 25), window.x1);
    try testing.expectEqual(@as(f64, 31), window.y1);
}

test "manual completion rejects unpaired and cross-net points" {
    const odd = [_]route_resume.Point{.{ .net = 1, .point = .{ .x = 0, .y = 0, .layer = 0 } }};
    try testing.expectError(error.InvalidPoints, completionWindow(&odd));
    const crossed = [_]route_resume.Point{
        .{ .net = 1, .point = .{ .x = 0, .y = 0, .layer = 0 } },
        .{ .net = 2, .point = .{ .x = 1, .y = 1, .layer = 0 } },
    };
    try testing.expectError(error.InvalidPoints, completionWindow(&crossed));
}

const fixture_pins = [_]export_kicad.FlatPin{
    .{ .ref_des = "R1", .pin = "1" },
    .{ .ref_des = "R2", .pin = "1" },
};

/// A minimal routable two-pad placement (mirrors route_review's fixture): one
/// net between two 0.4 mm pads 3 mm apart on the legacy 2-layer rules.
fn buildFixture(a: std.mem.Allocator) std.mem.Allocator.Error!optimizer.Placement {
    const pad = try a.dupe(geometry.Pad, &.{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }});
    const parts = try a.dupe(optimizer.Part, &.{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = pad, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = pad, .fallback = false, .x = 3, .y = 0 },
    });
    const nets = try a.dupe(optimizer.FlatNet, &.{.{ .name = "SIG", .pins = &fixture_pins }});
    return .{
        .parts = parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -0.5,
        .miny = -0.5,
        .maxx = 3.5,
        .maxy = 0.5,
        .generated = true,
    };
}

test "manual completion returns only the requested fixture bridge" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const placement = try buildFixture(arena);
    const points = [_]route_resume.Point{
        .{ .net = 0, .point = .{ .x = 0, .y = 0, .layer = 0 } },
        .{ .net = 0, .point = .{ .x = 3, .y = 0, .layer = 0 } },
    };
    const prep = pcb_layout_page.RoutePrep{
        .eff_block = &route_review_fixture_block,
        .placement = placement,
        .rp = placement.rules.design.routeParams(),
        .scoped = .{},
        .user_zones = &.{},
        .steering = .{ .resume_points = &points },
    };
    const empty = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 0 };
    const result = try completeRoute(arena, prep, empty);
    try testing.expectEqual(@as(usize, 1), result.routed);
    try testing.expectEqual(@as(usize, 1), result.total);
    try testing.expect(result.tracks.len > 0);
    try testing.expectEqual(@as(usize, 0), result.failed.len);

    var json: std.Io.Writer.Allocating = .init(arena);
    try writeCompletion(&json.writer, prep, result);
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, json.written(), .{});
    try testing.expectEqual(result.tracks.len, root.object.get("tracks").?.array.items.len);
    try testing.expectEqual(@as(usize, 0), root.object.get("vias").?.array.items.len);
    try testing.expectEqual(@as(i64, 1), root.object.get("routed").?.integer);
}

// spec: serve/route-session - a hint's layer name resolves through the shared board layer lookup, so a plane-claimed inner names no bit
test "layerBit resolves hint layer names through the shared layer table" {
    // 6 copper layers with planes on In1 (stack 2) and In4 (stack 5): the
    // routable set is F.Cu, B.Cu and the two plane-free inners.
    const planes = [_]optimizer.PlaneAt{ .{ .index = 2, .net = "GND" }, .{ .index = 5, .net = "V_3V3" } };
    const rules = optimizer.BoardRules{
        .plane_nets = &.{ "GND", "V_3V3" },
        .copper_layers = 6,
        .planes = .{ .declared = &planes },
    };
    try testing.expectEqual(@as(?u6, 0), layerBit(rules, "F.Cu"));
    try testing.expectEqual(@as(?u6, 1), layerBit(rules, "B.Cu"));
    // Case-insensitive, like every other layer-name lookup on this board.
    try testing.expectEqual(@as(?u6, 2), layerBit(rules, "in2.cu"));
    try testing.expectEqual(@as(?u6, 3), layerBit(rules, "In3.Cu"));
    // A plane floods its layer, so a hint may not ask for copper there.
    try testing.expectEqual(@as(?u6, null), layerBit(rules, "In1.Cu"));
    try testing.expectEqual(@as(?u6, null), layerBit(rules, "Edge.Cuts"));
}

// spec: serve/route-session - the layers popover's offered rows are exactly the copper layers a layers hint resolves, on a declared stack and on the implicit model
test "the blob's routable layer rows are exactly the layers a hint accepts" {
    // pcb_route_session.js buildLayersList fills the popover by filtering the
    // PCB blob's `layer_table` down to rows carrying a numeric `l`, then posts
    // those NAMES as a layers hint. So an offered row must resolve to a bit and
    // a withheld one must not — otherwise the popover offers a layer the hint
    // endpoint answers 400 "unknown copper layer name" for. (Until the client's
    // dead `window.PCB` gate was fixed the table was never read at all, and
    // every board fell back to a hard-coded F.Cu/B.Cu pair.)
    const planes = [_]optimizer.PlaneAt{ .{ .index = 2, .net = "GND" }, .{ .index = 5, .net = "V_3V3" } };
    try expectPopoverOffersHintableLayers(.{
        .plane_nets = &.{ "GND", "V_3V3" },
        .copper_layers = 6,
        .planes = .{ .declared = &planes },
    }, &.{ "F.Cu", "In2.Cu", "In3.Cu", "B.Cu" });
    // The legacy implicit model claims both inners, so only the outers remain —
    // the pair the hard-coded fallback assumed for every board.
    try expectPopoverOffersHintableLayers(.{ .planes = .{ .implicit_rail = "V_3V3" } }, &.{ "F.Cu", "B.Cu" });
    // A declared plane-less four-layer stack: the inners route too, and this is
    // what the fallback was silently hiding.
    try expectPopoverOffersHintableLayers(
        .{ .plane_nets = &.{}, .copper_layers = 4 },
        &.{ "F.Cu", "In1.Cu", "In2.Cu", "B.Cu" },
    );
}

/// Assert the blob's `layer_table` offers `want` (in stack order) to the layers
/// popover and that each offered name resolves to the routable index the row
/// advertises, while every withheld row resolves to no bit at all.
fn expectPopoverOffersHintableLayers(rules: optimizer.BoardRules, want: []const []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // `layer_table_json.write` emits one member of the blob object, trailing
    // comma included — the `"_"` filler closes it into standalone JSON.
    var aw: std.Io.Writer.Allocating = .init(arena);
    try aw.writer.writeByte('{');
    try layer_table_json.write(&aw.writer, rules);
    try aw.writer.writeAll("\"_\":0}");
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, aw.written(), .{});

    var offered: std.ArrayList([]const u8) = .empty;
    for (root.object.get("layer_table").?.array.items) |row| {
        const name = row.object.get("name").?.string;
        const l = row.object.get("l").?;
        if (l != .integer) {
            // A plane-claimed inner holds no track, so the popover withholds it
            // and the hint endpoint would refuse it.
            try testing.expectEqual(@as(?u6, null), layerBit(rules, name));
            continue;
        }
        try testing.expectEqual(@as(?u6, @intCast(l.integer)), layerBit(rules, name));
        try offered.append(arena, name);
    }
    try testing.expectEqual(want.len, offered.items.len);
    for (want, offered.items) |expected, got| try testing.expectEqualStrings(expected, got);
}

// spec: serve/route-session - a route session start routes the placement exactly as the design replay does
test "session start routes the fixture like the design replay" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const placement = try buildFixture(arena);
    const params = placement.rules.design.routeParams();
    const options = route_plan.lowerOrEmpty(arena, &route_review_fixture_block, placement);

    const session = try route_session.RouteSession.start(testing.allocator, &placement, params, options);
    defer session.deinit();
    const status = try session.runUntilEvent();
    try testing.expect(status == .done);
    const run = session.currentRun();
    try testing.expectEqual(@as(usize, 1), run.routed.routed);
    try testing.expectEqual(@as(usize, 1), run.routed.total);

    // The design replay routes the same inputs through the same seam: identical count.
    const replay = try router.routeWithTimeline(arena, placement, params, options);
    try testing.expectEqual(replay.routed.routed, run.routed.routed);
}

/// The plan-lowering block reads only `pcb_plan`; an empty block lowers to
/// empty options, matching a plan-less design.
const route_review_fixture_block = env_mod.DesignBlock{
    .name = "fixture",
    .instances = &.{},
    .nets = &.{},
    .ports = &.{},
    .notes = &.{},
    .groups = &.{},
    .sub_blocks = &.{},
};

// spec: serve/route-session - a hint naming an unknown net is a 400 that leaves the session unadvanced
test "unknown-net hint is a 400 that never advances the session" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const placement = try buildFixture(arena);

    // Unknown net → 400, and (per the handler) the .err branch returns before applyHint.
    const bad = parseHint(arena, arena, placement, "{\"action\":\"route_now\",\"net\":\"NOPE\"}");
    try testing.expect(bad == .err);
    try testing.expectEqual(@as(u16, 400), bad.err.status);

    // A known net parses, and applying it is what advances the accepted-hint log.
    const good = parseHint(arena, arena, placement, "{\"action\":\"route_now\",\"net\":\"SIG\"}");
    try testing.expect(good == .ok);
    const rp = placement.rules.design.routeParams();
    const session = try route_session.RouteSession.start(testing.allocator, &placement, rp, .{});
    defer session.deinit();
    try testing.expectEqual(@as(usize, 0), session.acceptedHints().len);
    try session.applyHint(good.ok);
    try testing.expectEqual(@as(usize, 1), session.acceptedHints().len);
}

// spec: serve/route-session - the distilled plan fragment parses as a valid s-expression
test "distilled hint fragment parses as a valid s-expression" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const placement = try buildFixture(arena);
    const waypoints = [_]route_session.Waypoint{ .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 } };
    const rip_nets = [_]usize{0};
    // F.Cu (bit 0) | B.Cu (bit 1) on the fixture's 2-signal-layer stack.
    const allowed: route_session.LayerMask = 0b11;
    const hints = [_]route_session.Hint{
        .{ .route_now = .{ .net_i = 0 } },
        .{ .corridor = .{ .net_i = 0, .points = &waypoints } },
        .{ .layers = .{ .net_i = 0, .allowed = allowed } },
        .{ .rip = .{ .nets = &rip_nets } },
        .{ .abandon = .{ .net_i = 0 } },
    };
    const fragment = try distillFragment(arena, placement, &hints);
    try testing.expect(std.mem.indexOf(u8, fragment, "(pcb-plan") != null);
    try testing.expect(std.mem.indexOf(u8, fragment, "(waypoints (at 1 0 \"F.Cu\")") != null);
    try testing.expect(std.mem.indexOf(u8, fragment, "(allowed-layers \"F.Cu\" \"B.Cu\")") != null);
    // The whole fragment (comments and all) is syntactically valid S-expression.
    const nodes = try parser.parse(arena, fragment);
    try testing.expect(nodes.len >= 1);
}

/// Build a full page_allocator-backed entry on the two-pad fixture — the shape
/// the table stores. Freed via `freeEntry`.
fn makeTestEntry(name: []const u8) !*SessionEntry {
    const arena = try durable.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(durable);
    const sa = arena.allocator();
    const eval_ptr = try sa.create(Evaluator);
    eval_ptr.* = Evaluator.init(sa, "/nonexistent");
    const placement = try sa.create(optimizer.Placement);
    placement.* = try buildFixture(sa);
    const session = try route_session.RouteSession.start(durable, placement, .{}, .{});
    const status = try session.runUntilEvent();
    const entry = try durable.create(SessionEntry);
    entry.* = .{
        .arena = arena,
        .eval = eval_ptr,
        .module_res = null,
        .placement = placement.*,
        .name = try sa.dupe(u8, name),
        .project_dir = try sa.dupe(u8, "/nonexistent"),
        .session = session,
        .status = status,
        .last_touch = clock.timestamp(),
    };
    return entry;
}

// spec: serve/route-session - a second start replaces the design's existing session
test "a second start replaces the existing session for a design" {
    var store: Store = .{};
    defer clearStore(&store);
    const first = try makeTestEntry("board");
    try replaceSession(&store, "board", first);
    const second = try makeTestEntry("board");
    try replaceSession(&store, "board", second);
    try testing.expectEqual(@as(usize, 1), store.map.count());
    try testing.expectEqual(second, store.map.get("board").?);
}

// spec: serve/route-session - idle sessions are evicted on access
test "an idle session is evicted while a fresh one survives" {
    var store: Store = .{};
    defer clearStore(&store);
    const now = clock.timestamp();
    const stale = try makeTestEntry("stale");
    stale.last_touch = now - idle_secs - 1;
    try replaceSession(&store, "stale", stale);
    const fresh = try makeTestEntry("fresh");
    fresh.last_touch = now;
    try replaceSession(&store, "fresh", fresh);

    evictIdle(&store, now);
    try testing.expect(store.map.get("stale") == null);
    try testing.expect(store.map.get("fresh") != null);
}

/// Free every entry a test left in `store`.
fn clearStore(store: *Store) void {
    var it = store.map.iterator();
    while (it.next()) |e| {
        freeEntry(e.value_ptr.*);
        durable.free(e.key_ptr.*);
    }
    store.map.deinit(durable);
}

// spec: serve/route-session - the stuck block serializes each layer's occupancy grid alongside the frontier
test "stuck block carries a named occupancy grid per signal layer" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const placement = try buildFixture(arena);
    const grids = [_][]const u2{ &.{ 0, 2 }, &.{ 3, 1 } };
    const rep = route_session.StuckReport{
        .net_i = 0,
        .attempts = 1,
        .pads = &.{},
        .frontier = .{ .origin = .{ 0, 0 }, .cell_mm = 0.5, .cols = 2, .rows = 1, .cells = &.{ 0, 1 } },
        .occupancy = &grids,
        .blockers = &.{},
        .layer_occupancy = &.{ 0.5, 0.5 },
    };
    var aw: std.Io.Writer.Allocating = .init(arena);
    try writeStuck(arena, &aw.writer, placement, rep);
    const json = aw.written();
    // One named entry per signal layer, cells base64-encoded like the frontier's.
    try testing.expect(std.mem.indexOf(u8, json, "\"occupancy\":[{\"layer\":\"F.Cu\",\"cells\":\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "{\"layer\":\"B.Cu\",\"cells\":\"") != null);
}

// spec: serve/route-session - the frontier grid cells round-trip through base64
test "frontier cells round-trip through base64" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cells = [_]u2{ 0, 1, 2, 3, 2, 1, 0, 3 };
    var aw: std.Io.Writer.Allocating = .init(arena);
    try writeBase64Cells(arena, &aw.writer, &cells);
    const quoted = aw.written();
    try testing.expect(quoted[0] == '"' and quoted[quoted.len - 1] == '"');
    const b64 = quoted[1 .. quoted.len - 1];
    const dec = std.base64.standard.Decoder;
    const out = try arena.alloc(u8, try dec.calcSizeForSlice(b64));
    try dec.decode(out, b64);
    try testing.expectEqual(@as(usize, cells.len), out.len);
    for (cells, 0..) |c, i| try testing.expectEqual(@as(u8, c), out[i]);
}
