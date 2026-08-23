//! Interactive, read-only autoroute review in two modes sharing one playback
//! page. Upload mode: the browser uploads a KiCad board (and optionally its
//! sibling project file); the server parses and routes it entirely in memory.
//! Design mode: a project design is solved exactly as /pcb-layout would
//! (starred layout preferred) and routed fresh through the shared hierarchical
//! local-then-global seam. Both return the fixed placement plus the router's exact opt-in
//! decision timeline; no source/design file is created or modified.

const std = @import("std");
const httpz = @import("httpz");
const clock = @import("../infra/clock.zig");
const infra_fs = @import("../infra/fs.zig");
const serve_root = @import("../serve.zig");
const Server = serve_root.Server;
const assets_css = @import("assets_css.zig");
const pages = @import("templates/pages.zig");
const snapshot_mod = @import("../kicad_pcb/snapshot.zig");
const project_mod = @import("../kicad_pcb/project_rules.zig");
const net_aliases = @import("../kicad_pcb/net_aliases.zig");
const experiment = @import("../kicad_pcb/experiment.zig");
const adapter = @import("../kicad_pcb/router_adapter.zig");
const optimizer = @import("../placement/optimizer.zig");
const router = @import("../placement/router.zig");
const route_score = @import("../placement/route_score.zig");
const drc = @import("../placement/drc.zig");
const drc_rules = @import("drc_rules.zig");
const fab_readiness = @import("../fab_readiness.zig");
const env_mod = @import("../eval/env.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const modules_mod = @import("modules.zig");
const mcp_tools = @import("mcp_tools.zig");
const pcb_layout_page = @import("pcb_layout_page.zig");
const route_plan = @import("route_plan.zig");
const board_layers = @import("../board_layers.zig");

pub const HandlerError = std.mem.Allocator.Error || std.Io.Writer.Error;

/// Cap on an UPLOADED `.kicad_pcb` request body (this handler's own 413).
/// Deliberately below serve.zig's httpz `max_body_size` of 64 MiB: at or above
/// it, httpz rejects the body first and this friendly error becomes dead code.
/// An untrusted upload is not the same fact as the 64 MiB the local-disk board
/// readers use, so the two no longer share a name. The 413 text spells
/// "48 MiB" - move the value and the message together.
const max_upload_board_bytes: usize = 48 * 1024 * 1024;
const max_project_bytes: usize = 8 * 1024 * 1024;
const boundary_key = "boundary=";
const filename_key = "filename=\"";
const json_point_fmt = "[{d},{d}]";

const Upload = struct {
    board: []const u8,
    board_name: []const u8,
    project: ?[]const u8 = null,
};

const Review = struct {
    name: []const u8,
    project_loaded: bool,
    board: snapshot_mod.Snapshot,
    placement: optimizer.Placement,
    run: router.RouteRun,
    violations: []const drc.Violation,
};

/// GET /route-review — upload + playback surface. Keeping the route data out
/// of the HTML lets the same page review any KiCad board without exposing a
/// server filesystem path or persisting the uploaded design. Design replay
/// moved to each design's /pcb-layout Replay panel (this page is upload-only
/// now); the design-native endpoints below stay as that panel's data source.
pub fn routeReviewPage(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    _ = ctx; // upload-only page now — design replay moved to /pcb-layout's Replay panel
    var aw: std.Io.Writer.Allocating = .init(req.arena);
    const w = &aw.writer;
    try w.writeAll(
        "<!doctype html><html><head><meta charset=\"utf-8\">" ++
            "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">" ++
            "<title>Autoroute Review</title><style>",
    );
    try w.writeAll(assets_css.navbar_css);
    try w.writeAll(@embedFile("assets/route_review.css"));
    try w.writeAll("</style></head><body>");
    try pages.Navbar.render(.{"route-review"}, w);
    try w.writeAll(
        "<header class=\"rr-hero\"><div><p class=\"rr-kicker\">ROUTER AUDIT TRAIL</p>" ++
            "<h1>Watch the board route itself.</h1>" ++
            "<p>Upload a KiCad board and step through every meaningful net, plane, and rip-up decision. " ++
            "The source stays untouched; routing and review happen in memory.</p></div>" ++
            "<form id=\"rr-upload\"><label class=\"rr-drop\" id=\"rr-drop\">" ++
            "<input id=\"rr-files\" type=\"file\" multiple accept=\".kicad_pcb,.kicad_pro\">" ++
            "<span class=\"rr-drop-title\">Choose or drop board files</span>" ++
            "<span class=\"rr-drop-sub\">Required: .kicad_pcb · Recommended: matching .kicad_pro</span>" ++
            "<span class=\"rr-files\" id=\"rr-file-names\">No files selected</span></label>" ++
            "<button class=\"rr-primary\" id=\"rr-run\" type=\"submit\">Route + build timeline</button>" ++
            "<div class=\"rr-status\" id=\"rr-status\" role=\"status\"></div></form></header>",
    );
    try w.writeAll(
        "<section class=\"rr-designs\"><p class=\"rr-designs-title\">" ++
            "Replaying a project design now lives in that design's " ++
            "<a href=\"/\">PCB Layout</a> page — open <b>/pcb-layout/&lt;design&gt;</b> " ++
            "and use the <b>Replay</b> panel to route it fresh and step through the timeline.</p></section>",
    );
    try w.writeAll(
        "<main class=\"rr-app\" id=\"rr-app\" hidden>" ++
            "<section class=\"rr-board-panel\"><div class=\"rr-board-toolbar\">" ++
            "<div><strong id=\"rr-board-name\">Board</strong><span id=\"rr-board-meta\"></span></div>" ++
            "<div class=\"rr-toggles\"><label><input id=\"rr-pads\" type=\"checkbox\" checked> Pads</label>" ++
            "<label><input id=\"rr-labels\" type=\"checkbox\" checked> Labels</label>" ++
            "<label><input id=\"rr-drc\" type=\"checkbox\" checked> Final DRC</label>" ++
            "<button id=\"rr-fit\" type=\"button\">Fit</button></div></div>" ++
            "<div class=\"rr-canvas-wrap\" id=\"rr-canvas-wrap\"><canvas id=\"rr-canvas\"></canvas>" ++
            "<div class=\"rr-layer-legend\"><span class=\"top\">Top</span><span class=\"bottom\">Bottom</span>" ++
            "<span class=\"active-net\">Active net</span>" ++
            "<span class=\"violation\">Final DRC</span></div></div></section>" ++
            "<aside class=\"rr-audit\"><div class=\"rr-summary\">" ++
            "<div><span>Connected</span><strong id=\"rr-routed\">0/0</strong></div>" ++
            "<div><span>Trace</span><strong id=\"rr-trace\">0 mm</strong></div>" ++
            "<div><span>Vias</span><strong id=\"rr-vias\">0</strong></div>" ++
            "<div><span>Final DRC</span><strong id=\"rr-drc-count\">0</strong></div></div>" ++
            "<section class=\"rr-player\"><div class=\"rr-player-row\">" ++
            "<button id=\"rr-prev\" type=\"button\" aria-label=\"Previous step\">&#8592;</button>" ++
            "<button class=\"rr-play\" id=\"rr-play\" type=\"button\">Play</button>" ++
            "<button id=\"rr-next\" type=\"button\" aria-label=\"Next step\">&#8594;</button>" ++
            "<span id=\"rr-step-count\">0 / 0</span></div>" ++
            "<input id=\"rr-slider\" type=\"range\" min=\"0\" max=\"0\" value=\"0\">" ++
            "<div class=\"rr-event-card\"><span id=\"rr-phase\">Initial state</span>" ++
            "<h2 id=\"rr-event-title\">Ready</h2><p id=\"rr-event-detail\"></p>" ++
            "<div class=\"rr-deltas\" id=\"rr-deltas\"></div></div></section>" ++
            "<section class=\"rr-list-wrap\"><div class=\"rr-list-head\"><strong>Decision log</strong>" ++
            "<span>click any step</span></div><ol class=\"rr-list\" id=\"rr-list\"></ol></section></aside></main>" ++
            // The layer spellings the replay client needs. This page ships no PCB
            // blob, so they ride inline — freshly rendered per request, which a
            // cached review payload could not guarantee. `var` (not `const`) so
            // the client can `typeof`-probe it.
            "<script>var RRLayers={b_cu:\"" ++ board_layers.b_cu ++ "\"};</script>" ++
            "<script src=\"/static/route_review.js\"></script></body></html>",
    );
    res.content_type = .HTML;
    res.body = aw.written();
}

/// True when `name` is a listed project design, null when listing fails —
/// the shared endpoint guard (unknown or path-shaped names never reach the
/// filesystem, which is also the traversal defence).
pub fn isListedDesign(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8) ?bool {
    const names = mcp_tools.listDesignNames(alloc, project_dir) catch return null;
    for (names) |candidate| if (std.mem.eql(u8, candidate, name)) return true;
    return false;
}

/// GET|POST /api/design-route-review/run/:name — the design-native replay.
/// The GET (or a POST with no poses) solves the named design's placement
/// exactly as /pcb-layout would (starred layout preferred); a POST body of
/// `{"parts":[{ref,x,y,rot,side}]}` (the /api/pcb-route shape) instead places
/// the client's on-screen board verbatim, so the /pcb-layout Replay panel can
/// route the layout *as drawn*. Either way it routes fresh through the shared
/// `(pcb-plan)` seam with the timeline captured, filters DRC through the
/// project's rule overrides, and answers in the upload endpoint's wire shape so
/// the playback UI works unchanged. The POST body carries ONLY poses — no
/// width/clearance overrides, because replay routes by the authored plan. The
/// result is also saved to the project's `out/` cache for later reload; the
/// design's source and its `(kicad-pcb …)` board file are never touched.
pub fn designRouteReviewApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const arena = req.arena;
    const name = req.param("name") orelse return jsonError(arena, res, 404, "missing design name");
    const known = isListedDesign(arena, ctx.project_dir, name) orelse
        return jsonError(arena, res, 500, "could not list the project designs");
    if (!known) return jsonError(arena, res, 404, "no design by that name");

    const opts = pcb_layout_page.pngRequestFromQuery(arena, req);
    var eval = Evaluator.init(arena, ctx.project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        arena.destroy(mr.eval);
    };
    const solved = pcb_layout_page.solveForRequest(arena, ctx.project_dir, name, opts, &eval, &module_res) catch |e| {
        const fail = pcb_layout_page.pngFailure(e);
        res.status = fail.status;
        res.content_type = .JSON;
        res.body = fail.json;
        return;
    };
    // A POST body of part poses routes the board as drawn (place-from-poses on
    // the same resolved block); an empty/absent body keeps the solved placement.
    const poses: []const optimizer.RefPose = if (req.body()) |body| try parsePosesFromBody(arena, body) else &.{};
    // A poses replay inherits the board edge solveForRequest folded onto
    // solved.placement, so the replay routes/DRCs against the same outline
    // as the page — not edge-blind on a drawn-outline board.
    const placement = if (poses.len > 0)
        try optimizer.placeFromPoses(arena, solved.block, ctx.project_dir, .{
            .poses = poses,
            .outline = optimizer.outlineOf(&solved.placement),
        }, optimizer.Params{})
    else
        solved.placement;
    const replay = replayDesign(arena, ctx.project_dir, name, solved.block, placement) catch
        return jsonError(arena, res, 500, "the autorouter failed");

    var aw: std.Io.Writer.Allocating = .init(arena);
    try writeDesignReviewJson(arena, &aw.writer, name, placement, replay);
    const body = aw.written();
    // Best-effort persist for the page's "Load saved" button — the response
    // itself never depends on the cache write succeeding.
    saveCachedReplay(arena, ctx.project_dir, name, body);
    res.content_type = .JSON;
    res.body = body;
}

/// Parse a replay POST body's `parts:[{ref,x,y,rot,side,locked}]` (the
/// /api/pcb-route body shape) into placement poses. An empty slice means "no
/// poses posted" — the caller then routes the solved placement, so a GET (no
/// body) and a POST with no `parts` behave identically. Malformed JSON / a
/// missing or non-array `parts` degrade to no poses (not an error); only an
/// allocation failure propagates.
pub fn parsePosesFromBody(
    alloc: std.mem.Allocator,
    body: []const u8,
) std.mem.Allocator.Error![]const optimizer.RefPose {
    const root = std.json.parseFromSliceLeaky(std.json.Value, alloc, body, .{}) catch return &.{};
    if (root != .object) return &.{};
    const parts_v = root.object.get("parts") orelse return &.{};
    if (parts_v != .array) return &.{};
    var poses: std.ArrayList(optimizer.RefPose) = .empty;
    for (parts_v.array.items) |it| {
        if (it != .object) continue;
        const ref = it.object.get("ref") orelse continue;
        if (ref != .string) continue;
        try poses.append(alloc, .{
            .ref = ref.string,
            .x = jsonNumField(it.object.get("x")),
            .y = jsonNumField(it.object.get("y")),
            .rot = jsonNumField(it.object.get("rot")),
            .side = jsonSideField(it.object.get("side")),
            .locked = jsonFlagField(it.object.get("locked")),
        });
    }
    return poses.items;
}

/// A pose object's numeric field (integer or float; absent/other → 0).
fn jsonNumField(v: ?std.json.Value) f64 {
    const val = v orelse return 0;
    if (val == .float) return val.float;
    if (val == .integer) return @floatFromInt(val.integer);
    return 0;
}

/// A pose object's `"side"` field ("bottom" → bottom, else top).
fn jsonSideField(v: ?std.json.Value) optimizer.Side {
    const s = v orelse return .top;
    return if (s == .string) optimizer.Side.fromStr(s.string) else .top;
}

/// A pose object's optional boolean field (absent/non-bool → false).
fn jsonFlagField(v: ?std.json.Value) bool {
    const b = v orelse return false;
    return b == .bool and b.bool;
}

/// GET /api/design-route-review/cached/:name — the design's last saved replay,
/// served verbatim so a review survives leaving the page (and server restarts)
/// without paying for another route. 404 until a replay has been run.
pub fn cachedDesignRouteReviewApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const arena = req.arena;
    const name = req.param("name") orelse return jsonError(arena, res, 404, "missing design name");
    const known = isListedDesign(arena, ctx.project_dir, name) orelse
        return jsonError(arena, res, 500, "could not list the project designs");
    if (!known) return jsonError(arena, res, 404, "no design by that name");
    const body = readCachedReplay(arena, ctx.project_dir, name) orelse
        return jsonError(arena, res, 404, "no saved replay for this design yet — run one first");
    res.content_type = .JSON;
    res.body = body;
}

const replay_cache_rel = "out/route-review";
const max_cached_replay_bytes: usize = 64 * 1024 * 1024;

/// Cache file for a design's replay JSON, under the project's generated
/// `out/` tree (ignored by the designs repo — tool state, not authored work).
fn replayCachePath(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
) std.mem.Allocator.Error![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/" ++ replay_cache_rel ++ "/{s}.json", .{ project_dir, name });
}

/// Best-effort persist of a replay body so the page can reload it later
/// without re-routing. Atomic (temp + rename) so a reader never sees a torn
/// file; any failure is swallowed — worst case is routing fresh again.
/// Public so the live-route job can persist its finished run as the design's
/// cached replay through the same path the design replay uses.
pub fn saveCachedReplay(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8, body: []const u8) void {
    const dir_path = std.fmt.allocPrint(alloc, "{s}/" ++ replay_cache_rel, .{project_dir}) catch return;
    infra_fs.cwd().makePath(dir_path) catch return;
    const path = replayCachePath(alloc, project_dir, name) catch return;
    var write_buf: [4096]u8 = undefined;
    var atomic = infra_fs.cwd().atomicFile(path, .{ .write_buffer = &write_buf }) catch return;
    defer atomic.deinit();
    atomic.file_writer.interface.writeAll(body) catch return;
    atomic.finish() catch return;
}

/// The cached replay body, or null when none has been saved yet.
fn readCachedReplay(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8) ?[]u8 {
    const path = replayCachePath(alloc, project_dir, name) catch return null;
    return infra_fs.cwd().readFileAlloc(alloc, path, max_cached_replay_bytes) catch null;
}

/// A routed design replay: the router's timeline run plus the final DRC —
/// the design-native twin of the upload path's `Review` payload. Public so
/// the live-route job can persist its own finished run in this exact shape.
pub const DesignReplay = struct {
    run: router.RouteRun,
    violations: []const drc.Violation,
    /// What the ROUTER claimed it routed, before the connectivity oracle
    /// corrected `run.routed.routed`. Above the oracle's count it means the
    /// router counted a net complete whose pads its own copper never joins — a
    /// router defect worth seeing rather than silently repairing (the same
    /// diagnostic `route_close.Reconciled.claimed_routed` carries on every other
    /// routing surface).
    router_claimed: usize = 0,
};

/// The pure core of the design replay (block + placement in, run + DRC out):
/// route fresh through the shared local-then-global seam with the timeline captured,
/// then filter the final DRC through the design's `<name>.drc-rules.json` rule
/// overrides — the same `drc_rules.checkFiltered` the /pcb-layout page uses, so
/// the replay's DRC count matches the PCB page's (an `ignore`d kind never
/// surfaces here either). `project_dir`/`name` locate that rule sidecar.
/// HTTP-free so tests drive it on fixtures.
///
/// Accepted local sub-circuit copper is frozen before the global recorder
/// starts, making it visible in the `.initial` frame. The shared planned-live
/// seam also applies the normal post-route connectivity gate and preserves the
/// router's pre-gate claim beside the honest count.
fn replayDesign(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    block: *const env_mod.DesignBlock,
    placement: optimizer.Placement,
) std.mem.Allocator.Error!DesignReplay {
    const params = placement.rules.design.routeParams();
    var options = route_plan.lowerOrEmpty(alloc, block, placement);
    if (options.stop.deadline_ns == 0 and options.stop.max_route_ms > 0) {
        options.stop.deadline_ns = clock.nanoTimestamp() +
            @as(i128, @intCast(options.stop.max_route_ms)) * @as(i128, clock.ns_per_ms);
    }
    _ = try pcb_layout_page.addSubcircuitRouteSeeds(alloc, project_dir, block, placement, params, &options);
    const planned = try route_plan.routeLoweredLive(alloc, placement, params, &options, .{ .timeline = .on });
    const run = planned.run;
    const violations = drc_rules.checkFiltered(alloc, project_dir, name, placement, run.routed, params.clearance);
    return .{ .run = run, .violations = violations, .router_claimed = planned.claimed_routed };
}

/// POST /api/kicad-route-review/run — multipart board/project upload in,
/// self-contained placement + route-timeline JSON out. This is a pure compute
/// endpoint and is intentionally safe for read-only users.
pub fn routeReviewApi(_: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const upload = (try parseUpload(req, res)) orelse return;
    if (upload.board.len > max_upload_board_bytes) return jsonError(req.arena, res, 413, "board file is larger than 48 MiB");
    if (upload.project) |source| if (source.len > max_project_bytes)
        return jsonError(req.arena, res, 413, "project file is larger than 8 MiB");

    const arena = req.arena;
    const source_board = snapshot_mod.parse(arena, upload.board) catch |err|
        return jsonParseError(arena, res, "could not parse the KiCad board", err);
    const aliases = net_aliases.analyze(arena, source_board) catch
        return jsonError(arena, res, 500, "could not normalize the board nets");
    const board = net_aliases.canonicalize(arena, source_board, aliases) catch
        return jsonError(arena, res, 500, "could not normalize the board nets");
    const project: ?project_mod.ProjectRules = if (upload.project) |source|
        project_mod.parse(arena, source) catch |err|
            return jsonParseError(arena, res, "could not parse the KiCad project", err)
    else
        null;
    const erased = experiment.virtualErase(arena, board, &.{}) catch
        return jsonError(arena, res, 500, "could not erase the reference copper in memory");
    const adapted = adapter.adapt(arena, board, project) catch
        return jsonError(arena, res, 500, "could not adapt the KiCad layout for routing");
    const options = adapter.routeOptions(arena, adapted, erased.seed, &.{}) catch
        return jsonError(arena, res, 500, "could not build the routing constraints");
    const run = router.routeWithTimeline(arena, adapted.placement, adapted.params, options) catch
        return jsonError(arena, res, 500, "the autorouter failed");
    const routed = run.routed;
    // The same layered seam every other reporting surface uses, not bare
    // `drc.check`: geometry ALONE says nothing about whether the routed copper
    // actually joins each net's pads, so an uploaded board whose copper leaves
    // islands used to be reported DRC-clean. `checkDefaultRules` is
    // `checkFilteredZones` for copper that belongs to no project design — a
    // foreign board has no `<name>.drc-rules.json` to honour, but it still needs
    // the `net_open` layer.
    const violations = drc_rules.checkDefaultRules(arena, .{
        .placement = adapted.placement,
        .routed = routed,
        .clearance = adapted.params.clearance,
    });

    var aw: std.Io.Writer.Allocating = .init(arena);
    try writeReviewJson(arena, &aw.writer, .{
        .name = std.fs.path.basename(upload.board_name),
        .project_loaded = project != null,
        .board = board,
        .placement = adapted.placement,
        .run = run,
        .violations = violations,
    });
    res.content_type = .JSON;
    res.body = aw.written();
}

fn parseUpload(req: *httpz.Request, res: *httpz.Response) HandlerError!?Upload {
    const body = req.body() orelse {
        try jsonError(req.arena, res, 400, "missing upload body");
        return null;
    };
    const content_type = req.header("content-type") orelse "";
    const bi = std.mem.indexOf(u8, content_type, boundary_key) orelse {
        try jsonError(req.arena, res, 400, "expected a multipart upload");
        return null;
    };
    var boundary = std.mem.trim(u8, content_type[bi + boundary_key.len ..], " \t\r\n\"");
    if (std.mem.indexOfScalar(u8, boundary, ';')) |semi| boundary = boundary[0..semi];
    const delimiter = std.fmt.allocPrint(req.arena, "--{s}", .{boundary}) catch return null;
    var upload = Upload{ .board = &.{}, .board_name = "board.kicad_pcb" };
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, body, pos, delimiter)) |start| {
        var head_start = start + delimiter.len;
        if (head_start + 1 < body.len and body[head_start] == '\r' and body[head_start + 1] == '\n') head_start += 2;
        const rel_head_end = std.mem.indexOf(u8, body[head_start..], "\r\n\r\n") orelse break;
        const headers = body[head_start .. head_start + rel_head_end];
        const data_start = head_start + rel_head_end + 4;
        const next = std.mem.indexOfPos(u8, body, data_start, delimiter) orelse body.len;
        var data_end = next;
        if (data_end >= 2 and body[data_end - 2] == '\r' and body[data_end - 1] == '\n') data_end -= 2;
        const data = body[data_start..data_end];
        const lower = std.ascii.allocLowerString(req.arena, headers) catch {
            pos = next;
            continue;
        };
        if (std.mem.indexOf(u8, lower, "name=\"board\"")) |_| {
            upload.board = data;
            upload.board_name = uploadFilename(headers) orelse upload.board_name;
        } else if (std.mem.indexOf(u8, lower, "name=\"project\"")) |_| {
            upload.project = data;
        }
        pos = next;
    }
    if (upload.board.len == 0) {
        try jsonError(req.arena, res, 400, "select a .kicad_pcb file");
        return null;
    }
    return upload;
}

fn uploadFilename(headers: []const u8) ?[]const u8 {
    const fi = std.mem.indexOf(u8, headers, filename_key) orelse return null;
    const start = fi + filename_key.len;
    const end = std.mem.indexOfPos(u8, headers, start, "\"") orelse return null;
    return headers[start..end];
}

fn jsonParseError(arena: std.mem.Allocator, res: *httpz.Response, prefix: []const u8, err: anyerror) HandlerError!void {
    var aw: std.Io.Writer.Allocating = .init(arena);
    try aw.writer.writeAll("{\"ok\":false,\"error\":");
    const message = try std.fmt.allocPrint(arena, "{s}: {s}", .{ prefix, @errorName(err) });
    try writeJsonString(&aw.writer, message);
    try aw.writer.writeByte('}');
    res.status = 400;
    res.content_type = .JSON;
    res.body = aw.written();
}

/// Answer with `{"ok":false,"error":"<message>"}` at `status` — the shared
/// JSON error envelope for the route-review and route-session endpoints.
pub fn jsonError(arena: std.mem.Allocator, res: *httpz.Response, status: u16, message: []const u8) HandlerError!void {
    var aw: std.Io.Writer.Allocating = .init(arena);
    try aw.writer.writeAll("{\"ok\":false,\"error\":");
    try writeJsonString(&aw.writer, message);
    try aw.writer.writeByte('}');
    res.status = status;
    res.content_type = .JSON;
    res.body = aw.written();
}

fn writeReviewJson(
    arena: std.mem.Allocator,
    w: *std.Io.Writer,
    review: Review,
) HandlerError!void {
    try w.writeAll("{\"ok\":true,\"mode\":\"kicad\",\"name\":");
    try writeJsonString(w, review.name);
    try w.print(",\"project_loaded\":{s},\"copper_layers\":{d}", .{
        if (review.project_loaded) "true" else "false",
        review.placement.rules.copper_layers,
    });
    try writeBoundsAndOutline(w, review.board);
    try writeZones(w, review.board);
    try writeNets(w, review.placement);
    try writeParts(arena, w, review.placement);
    try writeTimeline(w, review.placement, review.run.timeline);
    try writeFinal(w, review.placement, review.run.routed, review.violations);
    try w.writeByte('}');
}

/// The design replay's wire twin of `writeReviewJson`: same shape (so
/// route_review.js plays it unchanged) with `mode:"design"`, bounds/outline
/// from the solved placement instead of a KiCad snapshot, and no zones —
/// declared `(stackup …)` planes are routing policy here, not drawn pours.
/// Public so the live-route job persists its finished run in this shape.
pub fn writeDesignReviewJson(
    arena: std.mem.Allocator,
    w: *std.Io.Writer,
    name: []const u8,
    placement: optimizer.Placement,
    replay: DesignReplay,
) HandlerError!void {
    try w.writeAll("{\"ok\":true,\"mode\":\"design\",\"name\":");
    try writeJsonString(w, name);
    try w.print(",\"generated_at\":{d},\"project_loaded\":false,\"copper_layers\":{d}", .{
        clock.timestamp(),
        placement.rules.copper_layers,
    });
    try writeDesignBoundsAndOutline(w, placement);
    try w.writeAll(",\"zones\":[]");
    try writeNets(w, placement);
    try writeNetClasses(w, placement);
    try writeParts(arena, w, placement);
    try writeTimeline(w, placement, replay.run.timeline);
    try writeFinal(w, placement, replay.run.routed, replay.violations);
    // The router's own pre-oracle claim, beside the `final.routed` the oracle
    // corrected it to. Equal on a healthy run; above it means the router counted
    // a net complete whose pads its copper never joined.
    try w.print(",\"router_claimed\":{d}", .{replay.router_claimed});
    try writeRouteScore(arena, w, replay);
    try w.writeByte('}');
}

/// Emit `,"route_score":{"score":X,"score_v":V}` — the deterministic
/// accept/reject scalar (route_score.zig) for this replay, computed from the
/// same routed/total/via/trace/DRC numbers the `final` block reports. It is a
/// distinct top-level field, unrelated to the placement `score` block.
///
/// Every half of the score is the honest one: `routed`/`total` are the
/// connectivity oracle's (see `replayDesign`), the error term is
/// `drc.errorCount`, which drops `net_open` so an open net is charged once,
/// through completion, instead of once there and again at 50 points a piece,
/// and the v2 geometry terms are the shared measurements — `bendCount` over
/// this replay's own copper and `qualityWarnCount` over its own DRC findings —
/// so this replay and the `route_experiment` tool count identically.
fn writeRouteScore(alloc: std.mem.Allocator, w: *std.Io.Writer, replay: DesignReplay) HandlerError!void {
    var trace_mm: f64 = 0;
    for (replay.run.routed.tracks) |t| trace_mm += std.math.hypot(t.x2 - t.x1, t.y2 - t.y1);
    const s = route_score.score(.{
        .routed = replay.run.routed.routed,
        .total = replay.run.routed.total,
        .vias = replay.run.routed.vias.len,
        .trace_mm = trace_mm,
        .drc_errors = drc.errorCount(replay.violations),
        .bends = try route_score.bendCount(alloc, replay.run.routed.tracks),
        .quality_warns = route_score.qualityWarnCount(replay.violations),
    });
    try w.print(",\"route_score\":{{\"score\":{d:.2},\"score_v\":{d}}}", .{ s, route_score.formula_version });
}

/// Per-net `(net-class …)` annotation aligned with `nets` — the browser's
/// decision log groups routing steps by these, making the priority order
/// (rf first, then lvds, …) legible. Null for nets outside any class.
pub fn writeNetClasses(w: *std.Io.Writer, placement: optimizer.Placement) HandlerError!void {
    try w.writeAll(",\"net_class\":[");
    for (placement.nets, 0..) |_, i| {
        if (i > 0) try w.writeByte(',');
        const rule: ?optimizer.NetRule = if (i < placement.rules.net.len) placement.rules.net[i] else null;
        if (rule != null and rule.?.class.name.len > 0) {
            try w.writeAll("{\"name\":");
            try writeJsonString(w, rule.?.class.name);
            try w.print(",\"priority\":{d}}}", .{rule.?.priority});
        } else {
            try w.writeAll("null");
        }
    }
    try w.writeByte(']');
}

/// Bounds = the parts bbox grown to the authored/saved board rect; outline =
/// the exact drawn polygon when one exists, else the board rect, else nothing
/// (the parts bbox alone frames partless or outline-less designs).
pub fn writeDesignBoundsAndOutline(w: *std.Io.Writer, placement: optimizer.Placement) HandlerError!void {
    var min_x = placement.minx;
    var min_y = placement.miny;
    var max_x = placement.maxx;
    var max_y = placement.maxy;
    if (placement.board_rect) |rect| {
        min_x = @min(min_x, rect.minx);
        min_y = @min(min_y, rect.miny);
        max_x = @max(max_x, rect.minx + rect.w);
        max_y = @max(max_y, rect.miny + rect.h);
    }
    try w.print(",\"bounds\":{{\"min_x\":{d},\"min_y\":{d},\"max_x\":{d},\"max_y\":{d}}},\"outline\":[", .{
        min_x,
        min_y,
        max_x,
        max_y,
    });
    if (placement.board_poly) |poly| {
        try w.writeAll("{\"kind\":\"polygon\",\"points\":[");
        for (poly, 0..) |point, pi| {
            if (pi > 0) try w.writeByte(',');
            try w.print(json_point_fmt, .{ point[0], point[1] });
        }
        try w.writeAll("]}");
    } else if (placement.board_rect) |rect| {
        try w.print("{{\"kind\":\"rect\",\"points\":[[{d},{d}],[{d},{d}]]}}", .{
            rect.minx,
            rect.miny,
            rect.minx + rect.w,
            rect.miny + rect.h,
        });
    }
    try w.writeByte(']');
}

fn writeZones(w: *std.Io.Writer, board: snapshot_mod.Snapshot) HandlerError!void {
    try w.writeAll(",\"zones\":[");
    for (board.zones, 0..) |zone, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"net\":");
        try writeJsonString(w, zone.net);
        try w.print(",\"keepout\":{s},\"layers\":[", .{if (zone.keepout != null) "true" else "false"});
        for (zone.layers, 0..) |layer, li| {
            if (li > 0) try w.writeByte(',');
            try writeJsonString(w, layer);
        }
        try w.writeAll("],\"poly\":[");
        for (zone.polygon, 0..) |point, pi| {
            if (pi > 0) try w.writeByte(',');
            try w.print(json_point_fmt, .{ point.x, point.y });
        }
        try w.writeAll("]}");
    }
    try w.writeByte(']');
}

fn writeBoundsAndOutline(w: *std.Io.Writer, board: snapshot_mod.Snapshot) HandlerError!void {
    const bounds = snapshot_mod.outlineBounds(board);
    try w.print(",\"bounds\":{{\"min_x\":{d},\"min_y\":{d},\"max_x\":{d},\"max_y\":{d}}},\"outline\":[", .{
        bounds.min.x,
        bounds.min.y,
        bounds.max.x,
        bounds.max.y,
    });
    for (board.outline, 0..) |item, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{{\"kind\":\"{s}\",\"points\":[", .{@tagName(item.kind)});
        for (item.points, 0..) |point, pi| {
            if (pi > 0) try w.writeByte(',');
            try w.print(json_point_fmt, .{ point.x, point.y });
        }
        try w.writeAll("]}");
    }
    try w.writeByte(']');
}

/// The flattened net-name list, aligned with every `net`/`net_i` index the
/// timeline and stuck report reference.
pub fn writeNets(w: *std.Io.Writer, placement: optimizer.Placement) HandlerError!void {
    try w.writeAll(",\"nets\":[");
    for (placement.nets, 0..) |net, i| {
        if (i > 0) try w.writeByte(',');
        try writeJsonString(w, net.name);
    }
    try w.writeByte(']');
}

/// Every placed part with its pose, courtyard, and pad geometry (each pad
/// carrying its flattened net index) — the board the playback UI paints.
pub fn writeParts(arena: std.mem.Allocator, w: *std.Io.Writer, placement: optimizer.Placement) HandlerError!void {
    var pin_net = std.StringHashMapUnmanaged(usize).empty;
    for (placement.nets, 0..) |net, net_i| for (net.pins) |pin| {
        const key = try std.fmt.allocPrint(arena, "{s}|{s}", .{ pin.ref_des, pin.pin });
        try pin_net.put(arena, key, net_i);
    };
    try w.writeAll(",\"parts\":[");
    for (placement.parts, 0..) |part, part_i| {
        if (part_i > 0) try w.writeByte(',');
        const court = optimizer.worldCourtyard(&part);
        try w.writeAll("{\"ref\":");
        try writeJsonString(w, part.ref_des);
        try w.print(",\"x\":{d},\"y\":{d},\"side\":\"{s}\",\"court\":[{d},{d},{d},{d}],\"pads\":[", .{
            part.x,
            part.y,
            @tagName(part.side),
            court.minx,
            court.miny,
            court.minx + court.w,
            court.miny + court.h,
        });
        for (part.pads, 0..) |pad, pad_i| {
            if (pad_i > 0) try w.writeByte(',');
            const center = optimizer.worldPadCenter(&part, pad.x, pad.y);
            const key = try std.fmt.allocPrint(arena, "{s}|{s}", .{ part.ref_des, pad.number });
            const net_i = pin_net.get(key);
            const pad_rot = part.rot + (if (part.side == .bottom) -pad.rot else pad.rot);
            try w.writeAll("{\"number\":");
            try writeJsonString(w, pad.number);
            try w.writeAll(",\"shape\":");
            try writeJsonString(w, pad.shape);
            try w.print(
                ",\"x\":{d},\"y\":{d},\"w\":{d},\"h\":{d},\"rot\":{d}," ++
                    "\"rratio\":{d},\"drill\":{d},\"thru\":{s},\"net\":",
                .{
                    center[0],
                    center[1],
                    pad.w,
                    pad.h,
                    pad_rot,
                    pad.rratio(),
                    pad.drill,
                    if (pad.thru) "true" else "false",
                },
            );
            if (net_i) |value| try w.print("{d}", .{value}) else try w.writeAll("null");
            try w.writeAll(",\"poly\":[");
            for (pad.poly, 0..) |point, pi| {
                if (pi > 0) try w.writeByte(',');
                const world = optimizer.worldPadCenter(&part, point[0], point[1]);
                try w.print(json_point_fmt, .{ world[0], world[1] });
            }
            try w.writeAll("]}");
        }
        try w.writeAll("]}");
    }
    try w.writeByte(']');
}

fn writeTimeline(
    w: *std.Io.Writer,
    placement: optimizer.Placement,
    timeline: []const router.RouteEvent,
) HandlerError!void {
    try w.writeAll(",\"timeline\":");
    try writeTimelineArray(w, placement, timeline);
}

/// The router decision timeline as a bare JSON array (no leading key) — each
/// element the `{seq,kind,pass?,net,related,round,routed,total,trace_mm,tracks,vias}`
/// event shape the playback UI plays. Split out so the route-session endpoint
/// can emit the identical elements under its own `"events"` key.
pub fn writeTimelineArray(
    w: *std.Io.Writer,
    placement: optimizer.Placement,
    timeline: []const router.RouteEvent,
) HandlerError!void {
    try w.writeByte('[');
    for (timeline, 0..) |event, i| {
        if (i > 0) try w.writeByte(',');
        try writeTimelineEvent(w, placement, event, i);
    }
    try w.writeByte(']');
}

/// The attempt's routing lattice as a `"pass":{…},` fragment (trailing comma —
/// callers emit it mid-object). Omitted entirely when the run recorded no pass
/// context, so a client reading an older replay sees no `pass` key and disables
/// the vision overlay rather than rendering a guessed lattice.
///
/// This is the contract `POST /api/route-vision/:name` accepts straight back,
/// so the overlay reconstructs on the geometry the maze actually searched.
fn writePassContext(w: *std.Io.Writer, pass: router.PassContext) HandlerError!void {
    const grid = pass.grid orelse return;
    if (!pass.recorded()) return;
    try w.print(
        "\"pass\":{{\"ox\":{d},\"oy\":{d},\"g\":{d},\"nx\":{d},\"ny\":{d},\"n_signal\":{d}," ++
            "\"track_width\":{d},\"clearance\":{d},\"via_dia\":{d},\"via_drill\":{d}," ++
            "\"pour\":[{s},{s}],\"grid_scale\":{d}}},",
        .{
            grid.ox,
            grid.oy,
            grid.g,
            grid.nx,
            grid.ny,
            pass.n_signal,
            pass.base.track_width,
            pass.base.clearance,
            pass.base.via_dia,
            pass.base.via_drill,
            if (pass.pour[0]) "true" else "false",
            if (pass.pour[1]) "true" else "false",
            pass.grid_scale,
        },
    );
}

/// ONE timeline event as its wire element — the exact
/// `{seq,kind,pass?,net,related,round,routed,total,trace_mm,tracks,vias}` object
/// `writeTimelineArray` emits (which loops over this, so the two can never
/// drift). Split out so the live-route job can serialize each event the moment
/// the router's progress sink hands it over, byte-identical to a replay.
/// `seq` is the caller's position in its stream — the array writer passes the
/// element index; a live stream passes its attempt-local cursor.
pub fn writeTimelineEvent(
    w: *std.Io.Writer,
    placement: optimizer.Placement,
    event: router.RouteEvent,
    seq: usize,
) HandlerError!void {
    try w.print("{{\"seq\":{d},\"kind\":\"{s}\",", .{ seq, @tagName(event.kind) });
    // The routing lattice rides the `.initial` event only. It is constant for
    // an attempt, and an attempt is exactly what an `.initial` opens — a second
    // one means a finer-grid restart, which is when the client re-latches it.
    // Repeating it on every event would add ~120 bytes to each of hundreds.
    if (event.kind == .initial) try writePassContext(w, event.pass);
    try w.writeAll("\"net\":");
    if (event.net) |net_i| {
        if (net_i < placement.nets.len)
            try writeJsonString(w, placement.nets[net_i].name)
        else
            try w.writeAll("null");
    } else try w.writeAll("null");
    try w.writeAll(",\"related\":[");
    for (event.related_nets, 0..) |net_i, ri| {
        if (net_i >= placement.nets.len) continue;
        if (ri > 0) try w.writeByte(',');
        try writeJsonString(w, placement.nets[net_i].name);
    }
    try w.print("],\"round\":{d},\"detail\":", .{event.round});
    try writeJsonString(w, event.detail);
    try w.print(",\"routed\":{d},\"total\":{d},\"trace_mm\":{d},\"tracks\":[", .{
        event.state.routed,
        event.state.total,
        event.state.trace_mm,
    });
    for (event.state.tracks, 0..) |track, ti| {
        if (ti > 0) try w.writeByte(',');
        try w.print("[{d},{d},{d},{d},{d},{d},{d}]", .{
            track.x1,
            track.y1,
            track.x2,
            track.y2,
            track.layer,
            track.width,
            track.net,
        });
    }
    try w.writeAll("],\"vias\":[");
    for (event.state.vias, 0..) |via, vi| {
        if (vi > 0) try w.writeByte(',');
        try w.print("[{d},{d},{d},{d},{d}]", .{ via.x, via.y, via.dia, via.drill, via.net });
    }
    try w.writeAll("]}");
}

/// The `"final"` block — routed/total counts, failed/limited/replayed net
/// lists, and the filtered DRC — emitted when a route run has completed.
pub fn writeFinal(
    w: *std.Io.Writer,
    placement: optimizer.Placement,
    routed: router.RouteResult,
    violations: []const drc.Violation,
) HandlerError!void {
    try w.print(",\"final\":{{\"routed\":{d},\"total\":{d},\"grid_overflow\":{s},\"ripup_rounds\":{d},\"failed\":[", .{
        routed.routed,
        routed.total,
        if (routed.grid_overflow) "true" else "false",
        routed.ripup_rounds,
    });
    for (routed.failed, 0..) |name, i| {
        if (i > 0) try w.writeByte(',');
        try writeJsonString(w, name);
    }
    try w.writeAll("],\"search_limited\":");
    try writeNetIndices(w, placement, routed.search_limited);
    try w.writeAll(",\"reference_replayed\":");
    try writeNetIndices(w, placement, routed.reference_replayed);
    try w.writeAll(",\"rf_paths\":[");
    var first_path = true;
    for (routed.rf_port_outcomes) |outcome| {
        if (!outcome.success or outcome.physical.gate_removed) continue;
        if (outcome.physical.samples.len < 2 or outcome.net < 0) continue;
        const net_i: usize = @intCast(outcome.net);
        if (net_i >= placement.nets.len) continue;
        if (!first_path) try w.writeByte(',');
        first_path = false;
        try w.writeAll("{\"net\":");
        try writeJsonString(w, placement.nets[net_i].name);
        try w.print(",\"l\":{d},\"samples\":[", .{outcome.physical.layer});
        for (outcome.physical.samples, 0..) |sample, si| {
            if (si > 0) try w.writeByte(',');
            try w.print("[{d},{d},{d}]", .{ sample.at[0], sample.at[1], sample.width_mm });
        }
        try w.writeAll("]}");
    }
    try w.writeAll("]");
    try w.writeAll(",\"drc\":[");
    for (violations, 0..) |violation, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{{\"kind\":\"{s}\",\"severity\":\"{s}\",\"x\":{d},\"y\":{d},\"gap\":{d},\"clearance\":{d}}}", .{
            @tagName(violation.kind),
            @tagName(violation.severity),
            violation.x,
            violation.y,
            violation.gap,
            violation.clearance,
        });
    }
    try w.writeAll("]}");
}

fn writeNetIndices(
    w: *std.Io.Writer,
    placement: optimizer.Placement,
    indices: []const usize,
) HandlerError!void {
    try w.writeByte('[');
    var emitted: usize = 0;
    for (indices) |net_i| {
        if (net_i >= placement.nets.len) continue;
        if (emitted > 0) try w.writeByte(',');
        try writeJsonString(w, placement.nets[net_i].name);
        emitted += 1;
    }
    try w.writeByte(']');
}

/// Emit `value` as a JSON string literal (quotes + control-char escaping) —
/// shared so every routing surface encodes net/design names identically.
pub fn writeJsonString(w: *std.Io.Writer, value: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    for (value) |byte| switch (byte) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => if (byte >= 0x20) try w.writeByte(byte),
    };
    try w.writeByte('"');
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;
const geometry = @import("../placement/geometry.zig");
const export_kicad = @import("../export_kicad.zig");

// spec: serve/route-review - the replay final payload carries solver RF paths so adopting it preserves custom taper polygons
test "replay final carries solver RF paths for adoption" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const placement = fixturePlacement(&.{}, &[_]optimizer.FlatNet{.{ .name = "RF", .pins = &.{} }});
    const samples = [_]@import("../placement/rf_path_solver.zig").Sample{
        .{ .at = .{ 1, 2 }, .s_mm = 0, .curvature = 0, .width_mm = 0.1 },
        .{ .at = .{ 3, 2 }, .s_mm = 2, .curvature = 0, .width_mm = 0.3 },
    };
    const outcomes = [_]@import("../placement/rf_port_report.zig").Outcome{.{
        .net = 0,
        .chosen = 0,
        .feasible = true,
        .success = true,
        .metrics = .{},
        .trials = &.{},
        .physical = .{ .sample_count = 2, .samples = &samples, .layer = 0 },
    }};
    const routed = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .rf_port_outcomes = &outcomes, .routed = 1, .total = 1 };
    var aw: std.Io.Writer.Allocating = .init(arena);
    try writeFinal(&aw.writer, placement, routed, &.{});
    try testing.expect(std.mem.indexOf(u8, aw.written(), "\"rf_paths\":[{\"net\":\"RF\",\"l\":0,\"samples\":[[1,2,0.1],[3,2,0.3]]}]") != null);
}

// spec: serve/route-review - the multipart upload filename is read from the part headers
test "uploadFilename reads the multipart filename" {
    try std.testing.expectEqualStrings(
        "Baraccuda_RF.kicad_pcb",
        uploadFilename("Content-Disposition: form-data; name=\"board\"; filename=\"Baraccuda_RF.kicad_pcb\"").?,
    );
}

/// A minimal routable two-pad placement (mirrors route_plan.zig's fixture):
/// one net between two 0.4 mm pads 3 mm apart on the legacy 2-layer rules.
fn fixturePlacement(
    parts: []optimizer.Part,
    nets: []const optimizer.FlatNet,
) optimizer.Placement {
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

/// A design block carrying only what the replay core reads (`pcb_plan` +
/// `kicad_pcb_path`); everything else stays empty.
fn fixtureBlock(plan: ?env_mod.PcbPlanSpec, kicad_pcb_path: ?[]const u8) env_mod.DesignBlock {
    return .{
        .name = "fixture",
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
        .pcb_plan = plan,
        .kicad_pcb_path = kicad_pcb_path,
    };
}

const route_review_fixture_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};

fn twoPadParts() [2]optimizer.Part {
    return .{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &route_review_fixture_pad, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &route_review_fixture_pad, .fallback = false, .x = 3, .y = 0 },
    };
}

const fixture_pins = [_]export_kicad.FlatPin{
    .{ .ref_des = "R1", .pin = "1" },
    .{ .ref_des = "R2", .pin = "1" },
};

/// Total track length routed on signal layer `layer`.
fn trackMmOnLayer(tracks: []const router.Track, layer: u8) f64 {
    var mm: f64 = 0;
    for (tracks) |t| {
        if (t.layer == layer) mm += std.math.hypot(t.x2 - t.x1, t.y2 - t.y1);
    }
    return mm;
}

/// Total routed track length across every layer — the score's `trace_mm`.
fn trackMmTotal(tracks: []const router.Track) f64 {
    var mm: f64 = 0;
    for (tracks) |t| mm += std.math.hypot(t.x2 - t.x1, t.y2 - t.y1);
    return mm;
}

// spec: serve/route-review - the design replay freezes accepted local sub-circuit copper in its first timeline frame before whole-board routing decisions
test "design replay begins on accepted local sub-circuit copper" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = twoPadParts();
    parts[0].ref_des = "amp/R1";
    parts[1].ref_des = "amp/R2";
    const pins = [_]export_kicad.FlatPin{
        .{ .ref_des = "amp/R1", .pin = "1" },
        .{ .ref_des = "amp/R2", .pin = "1" },
    };
    const nets = [_]optimizer.FlatNet{.{ .name = "SIG", .pins = &pins }};
    var child = fixtureBlock(null, null);
    const sub_blocks = [_]env_mod.SubBlock{.{ .name = "amp", .block = &child }};
    var block = fixtureBlock(null, null);
    block.sub_blocks = &sub_blocks;

    const replay = try replayDesign(arena, no_project, "fixture", &block, fixturePlacement(&parts, &nets));
    try testing.expect(replay.run.timeline.len > 1);
    try testing.expectEqual(router.RouteEventKind.initial, replay.run.timeline[0].kind);
    try testing.expect(replay.run.timeline[0].state.tracks.len > 0);
    try testing.expectEqual(@as(i32, 0), replay.run.timeline[0].state.tracks[0].net);

    const client = @embedFile("assets/pcb_replay.js");
    try testing.expect(std.mem.indexOf(u8, client, "Subcircuit routes frozen") != null);
}

// spec: serve/route-review - the design replay honors the authored plan's allowed-layers restriction
test "design replay keeps copper off plan-disallowed layers" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = twoPadParts();
    const nets = [_]optimizer.FlatNet{.{ .name = "SIG", .pins = &fixture_pins }};
    // Prefer the bottom (which alone would route B.Cu — see route_plan.zig's
    // fixture test) but forbid it: only F.Cu is allowed.
    const waves = [_]env_mod.PlanWave{.{
        .name = "outer-only",
        .rest = true,
        .allowed_layers = &.{"F.Cu"},
        .preferred_layers = &.{"B.Cu"},
    }};
    const block = fixtureBlock(.{ .route = &waves }, null);
    const replay = try replayDesign(arena, no_project, "fixture", &block, fixturePlacement(&parts, &nets));
    try testing.expectEqual(@as(usize, 1), replay.run.routed.routed);
    try testing.expectEqual(@as(f64, 0), trackMmOnLayer(replay.run.routed.tracks, 1));
    try testing.expectEqual(@as(usize, 0), replay.run.routed.vias.len);
    try testing.expect(trackMmOnLayer(replay.run.routed.tracks, 0) > 2.0);
}

// spec: serve/route-review - the design replay JSON carries design mode, empty zones, and placement bounds
test "design replay JSON keeps the upload wire shape" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = twoPadParts();
    const nets = [_]optimizer.FlatNet{.{ .name = "SIG", .pins = &fixture_pins }};
    var placement = fixturePlacement(&parts, &nets);
    placement.board_rect = .{ .minx = -1, .miny = -1, .w = 5, .h = 2 };
    const block = fixtureBlock(null, null);
    const replay = try replayDesign(arena, no_project, "fixture", &block, placement);
    var aw: std.Io.Writer.Allocating = .init(arena);
    try writeDesignReviewJson(arena, &aw.writer, "fixture", placement, replay);
    const json = aw.written();
    try testing.expect(std.mem.indexOf(u8, json, "\"ok\":true,\"mode\":\"design\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"zones\":[]") != null);
    const bounds = "\"bounds\":{\"min_x\":-1,\"min_y\":-1,\"max_x\":4,\"max_y\":1}";
    try testing.expect(std.mem.indexOf(u8, json, bounds) != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"rect\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"timeline\":[") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"final\":{") != null);
}

// spec: serve/route-review - the design replay JSON labels each net with its class name and priority
test "design replay JSON carries per-net class labels" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = twoPadParts();
    const nets = [_]optimizer.FlatNet{.{ .name = "SIG", .pins = &fixture_pins }};
    var placement = fixturePlacement(&parts, &nets);
    placement.rules.net = &[_]optimizer.NetRule{.{ .class = .{ .name = "rf" }, .priority = 6 }};
    const block = fixtureBlock(null, null);
    const replay = try replayDesign(arena, no_project, "fixture", &block, placement);
    var aw: std.Io.Writer.Allocating = .init(arena);
    try writeDesignReviewJson(arena, &aw.writer, "fixture", placement, replay);
    const wanted = "\"net_class\":[{\"name\":\"rf\",\"priority\":6}]";
    try testing.expect(std.mem.indexOf(u8, aw.written(), wanted) != null);
}

// spec: serve/route-review - the design replay JSON carries the deterministic routing score and its formula version
test "design replay JSON carries the routing score" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = twoPadParts();
    const nets = [_]optimizer.FlatNet{.{ .name = "SIG", .pins = &fixture_pins }};
    const placement = fixturePlacement(&parts, &nets);
    const block = fixtureBlock(null, null);
    const replay = try replayDesign(arena, no_project, "fixture", &block, placement);
    var aw: std.Io.Writer.Allocating = .init(arena);
    try writeDesignReviewJson(arena, &aw.writer, "fixture", placement, replay);
    const json = aw.written();
    // The single routable net connects, so the score is the emitted value for
    // this replay's own routed/total/via/trace/bend numbers (this fixture draws
    // no DRC errors and no self-inflicted warnings).
    const expected = route_score.score(.{
        .routed = replay.run.routed.routed,
        .total = replay.run.routed.total,
        .vias = replay.run.routed.vias.len,
        .trace_mm = trackMmTotal(replay.run.routed.tracks),
        .drc_errors = 0,
        .bends = try route_score.bendCount(arena, replay.run.routed.tracks),
        .quality_warns = route_score.qualityWarnCount(replay.violations),
    });
    const wanted = try std.fmt.allocPrint(arena, "\"route_score\":{{\"score\":{d:.2},\"score_v\":2}}", .{expected});
    try testing.expect(std.mem.indexOf(u8, json, wanted) != null);
}

// spec: serve/route-review - a design replay saved to the project cache is read back verbatim
test "cached replay round-trips through the project out directory" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const project_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    try testing.expect(readCachedReplay(arena, project_dir, "fixture") == null);
    saveCachedReplay(arena, project_dir, "fixture", "{\"ok\":true}");
    const body = readCachedReplay(arena, project_dir, "fixture") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("{\"ok\":true}", body);
    try testing.expect(readCachedReplay(arena, project_dir, "other") == null);
}

// spec: serve/route-review - the design replay never opens the design's kicad-pcb board path
test "design replay ignores the declared kicad-pcb board file" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = twoPadParts();
    const nets = [_]optimizer.FlatNet{.{ .name = "SIG", .pins = &fixture_pins }};
    // A bogus path proves the replay routes fresh from the placement alone:
    // touching the board file would fail, but the replay never reads it.
    const block = fixtureBlock(null, "/nonexistent/route-review-fixture.kicad_pcb");
    const replay = try replayDesign(arena, no_project, "fixture", &block, fixturePlacement(&parts, &nets));
    try testing.expectEqual(@as(usize, 1), replay.run.routed.routed);
    try testing.expectEqual(@as(usize, 0), replay.violations.len);
}

/// A project path that does not exist — replay tests that don't care about DRC
/// overrides pass it as `project_dir` so `drc_rules.load` finds no sidecar and
/// returns the default (unfiltered) rules.
const no_project = "/nonexistent-route-review-project";

// spec: serve/route-review - a POST body of part poses routes the replay at those exact poses
test "parsePosesFromBody reads posted part poses and an empty body falls back" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A moved part: its ref, position, rotation, and bottom side all survive.
    const body =
        "{\"parts\":[{\"ref\":\"R2\",\"x\":7.5,\"y\":2.5,\"rot\":90,\"side\":\"bottom\",\"locked\":true}]}";
    const poses = try parsePosesFromBody(arena, body);
    try testing.expectEqual(@as(usize, 1), poses.len);
    try testing.expectEqualStrings("R2", poses[0].ref);
    try testing.expectEqual(@as(f64, 7.5), poses[0].x);
    try testing.expectEqual(@as(f64, 2.5), poses[0].y);
    try testing.expectEqual(@as(f64, 90), poses[0].rot);
    try testing.expectEqual(optimizer.Side.bottom, poses[0].side);
    try testing.expect(poses[0].locked);
    // No `parts` / not JSON → no poses, so the endpoint falls back to the solve.
    try testing.expectEqual(@as(usize, 0), (try parsePosesFromBody(arena, "{}")).len);
    try testing.expectEqual(@as(usize, 0), (try parsePosesFromBody(arena, "not json at all")).len);
}

// spec: serve/route-review - the design replay filters DRC through the project's rule overrides
test "design replay applies the design's DRC ignore overrides" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const project_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);

    // Two parts stacked at the same spot on different nets: their pads overlap,
    // a deterministic pad_pad violation the router can't fix (single-pin nets,
    // nothing to route) — so the DRC output is independent of routing.
    const pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 0, .y = 0 },
    };
    const nets = [_]optimizer.FlatNet{
        .{ .name = "N1", .pins = &[_]export_kicad.FlatPin{.{ .ref_des = "R1", .pin = "1" }} },
        .{ .name = "N2", .pins = &[_]export_kicad.FlatPin{.{ .ref_des = "R2", .pin = "1" }} },
    };
    const placement = fixturePlacement(&parts, &nets);
    const block = fixtureBlock(null, null);

    // No rule sidecar: the pad_pad violation surfaces (proves there is one to
    // filter — the assertion is meaningful).
    const raw = try replayDesign(arena, project_dir, "unruled", &block, placement);
    try testing.expect(countKind(raw.violations, .pad_pad) > 0);

    // A `<name>.drc-rules.json` that ignores pad_pad drops every one — the replay
    // reads the same override sidecar the /pcb-layout page's DRC does.
    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/ruled.drc-rules.json", .data = "{\"pad_pad\":\"ignore\"}" });
    const filtered = try replayDesign(arena, project_dir, "ruled", &block, placement);
    try testing.expectEqual(@as(usize, 0), countKind(filtered.violations, .pad_pad));
}

/// Count DRC violations of a given kind — the DRC-override filtering assertion.
fn countKind(violations: []const drc.Violation, kind: drc.Kind) usize {
    var n: usize = 0;
    for (violations) |v| {
        if (v.kind == kind) n += 1;
    }
    return n;
}

// spec: serve/route-review - the design replay reports the connectivity oracle's routed/total and keeps the router's own claim beside it
test "design replay counters are the oracle's, with the router's claim kept beside them" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // R1 pad 1 and R2 pad 1 sit at the SAME point on one net: electrically
    // joined already, so the oracle counts it non-routable (pads in <2 board
    // locations) and excludes it from both numerator and denominator. The
    // router has no such notion — it counts the net it was handed. That gap is
    // the whole point of the gate `routeWithTimeline` skips.
    const pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 0, .y = 0 },
    };
    const nets = [_]optimizer.FlatNet{.{ .name = "SIG", .pins = &fixture_pins }};
    const placement = fixturePlacement(&parts, &nets);
    const block = fixtureBlock(null, null);
    const replay = try replayDesign(arena, no_project, "fixture", &block, placement);

    // What the payload reports is the oracle's answer, byte for byte.
    const oracle = try fab_readiness.routableTally(arena, placement, .{
        .tracks = replay.run.routed.tracks,
        .vias = replay.run.routed.vias,
    });
    try testing.expectEqual(oracle.routed, replay.run.routed.routed);
    try testing.expectEqual(oracle.total, replay.run.routed.total);
    try testing.expectEqual(@as(usize, 0), oracle.total); // the fixture's net needs no copper

    // …and the router's own pre-gate claim survives as a diagnostic rather than
    // being reported as connectivity. Here it exceeds the oracle, which is
    // exactly the case the field exists to make visible.
    try testing.expectEqual(@as(usize, 1), replay.router_claimed);
    var aw: std.Io.Writer.Allocating = .init(arena);
    try writeDesignReviewJson(arena, &aw.writer, "fixture", placement, replay);
    const json = aw.written();
    try testing.expect(std.mem.indexOf(u8, json, "\"router_claimed\":1") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"final\":{\"routed\":0,\"total\":0") != null);
}

// spec: serve/route-review - the upload replay layers the net-open connectivity check onto its geometric DRC
test "the upload replay's final DRC runs through the net-open-layered seam" {
    // `routeReviewApi` needs a multipart .kicad_pcb upload to exercise end to
    // end, so the wiring is asserted structurally: the handler must call the
    // shared `drc_rules` seam, never bare `drc.check`. Bare geometry cannot see
    // a net whose copper landed in two islands, so an unfinished board came
    // back reported as DRC-clean.
    // Both needles are ASSEMBLED from pieces so this test body can never match
    // itself — the only text that can satisfy either is the handler's own.
    const source = @embedFile("route_review.zig");
    const layered = "drc_rules." ++ "checkDefaultRules(arena, .{";
    const bare = "= drc" ++ ".check(";
    try testing.expect(std.mem.indexOf(u8, source, layered) != null);
    try testing.expect(std.mem.indexOf(u8, source, bare) == null);
}
