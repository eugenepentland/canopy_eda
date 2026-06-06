//! GET /pcb-layout/:name — interactive force-directed placement preview.
//!
//! The server evaluates the design, runs the optimizer, and emits the result
//! as JSON plus a small client renderer. The board is drawn client-side so
//! parts can be **dragged** (snapping to the 0.2 mm grid) and the layout
//! **score** (HPWL + decoupling-loop length) recomputes live — letting you
//! compare a hand placement against the auto one. A sidebar lists every
//! component and the net on each pin; hovering cross-highlights, and hovering
//! a pad (or net chip) reds every pad on that net.

const std = @import("std");
const httpz = @import("httpz");
const paths = @import("../paths.zig");
const infra_fs = @import("../infra/fs.zig");
const clock = @import("../infra/clock.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const env_mod = @import("../eval/env.zig");
const optimizer = @import("../placement/optimizer.zig");
const geometry = @import("../placement/geometry.zig");
const router = @import("../placement/router.zig");
const drc = @import("../placement/drc.zig");
const modules_mod = @import("modules.zig");
const netlist = @import("../export_kicad_netlist.zig");
const export_kicad = @import("../export_kicad.zig");
const export_kicad_footprint = @import("../export_kicad_footprint.zig");
const review = @import("../review.zig");
const render_pcb_png = @import("../render_pcb_png.zig");
const png_mod = @import("../png.zig");
const assets_css = @import("assets_css.zig");
const pages_tmpl = @import("templates/pages.zig");
const serve_root = @import("../serve.zig");
const Handler = serve_root.Handler;

pub const HandlerError = std.mem.Allocator.Error || std.Io.Writer.Error;

// SVG framing.
const SCALE_MIN: f64 = 6.0; // px per mm
const SCALE_MAX: f64 = 48.0;
const TARGET_PX: f64 = 1000.0; // desired content width/height
const MARGIN_MM: f64 = 2.0;

/// Sidecar holding a hand-saved placement (ref → x/y/rot), next to the design.
const SAVED_EXT = ".placement.json";

/// Sidecar caching the auto-generated layout, so the (expensive) optimizer
/// runs once and later loads read this instead. Regenerated on `?regen=1`.
const AUTO_EXT = ".autolayout.json";

/// A saved part placement: centre (mm) + rotation (deg).
const SavedPos = struct { x: f64, y: f64, rot: f64 };

/// JSON key prefix shared by every `{"ref": …}` record we emit.
const REF_OPEN = "{\"ref\":";
/// JSON object opener shared by the placement-export / saved-layout records.
const NAME_OPEN = "{\"name\":";
/// JSON key + open bracket shared by the layout/cache/export part arrays.
const PARTS_OPEN = "\"parts\":[";
/// Error bodies shared across the layout handlers.
const NO_BLOCK_MSG = "No design or module by that name";
/// Returned when `?sub=<slug>` names a sub-block that doesn't exist in the design.
const NO_SUB_MSG = "No sub-block by that name";
const BAD_JSON_MSG = "bad json";
const PLACEMENT_ERR_MSG = "Placement error";

/// Success body returned by the mutating layout/courtyard endpoints.
const OK_JSON_TRUE = "{\"ok\":true}";

/// The ` checked` HTML attribute fragment, emitted to pre-check a checkbox.
const CHECKED = " checked";

/// Sidecar holding every *named* saved layout for a design — manual snapshots
/// the user named, plus an auto-recorded history of optimizer runs. Supersedes
/// the single-slot `.placement.json` (migrated in on first read).
const LAYOUTS_EXT = ".layouts.json";

/// Layout `kind` tags. `manual` = a snapshot the user saved by name; `auto` =
/// one recorded automatically each time the optimizer regenerated.
const KIND_MANUAL = "manual";
const KIND_AUTO = "auto";

/// Cap on auto-recorded entries kept per design. On each record the oldest
/// auto entries past this are pruned; manual snapshots are never auto-pruned.
const MAX_AUTO_LAYOUTS: usize = 12;

/// One placed part within a saved layout: ref-des + centre (mm) + rotation.
const PartPose = struct { ref: []const u8, x: f64, y: f64, rot: f64 };

/// The weighted `objective` the optimizer minimizes plus its visible HPWL +
/// decoupling-loop terms, stored with a layout so the list shows "better/worse"
/// at a glance without re-running the optimizer. `objective` is 0 for legacy
/// entries saved before it was recorded.
const LayoutScore = struct { hpwl: f64, loop: f64, caps: usize, objective: f64 = 0 };

/// A named saved layout: name, kind, capture time (unix s, 0 = unknown),
/// optional score, and the placement itself (newest first within a file).
/// `default` marks the one layout the KiCad sync seeds first-insertion
/// placement + vias from; it's stored once at the top level of the file
/// (`"default":"<name>"`) and reflected here on the matching entry. At most
/// one entry has `default = true`.
const SavedLayout = struct {
    name: []const u8,
    kind: []const u8,
    ts: i64,
    score: ?LayoutScore,
    parts: []const PartPose,
    default: bool = false,
};

/// GET /pcb-layout/:name — evaluate the design, run the optimizer, and return
/// the interactive (drag + live-score) inline-SVG preview with a sidebar.
pub fn pcbLayoutPage(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };

    // Resolve `name` to a renderable block: a design under `src/` first, else
    // a reusable module under `lib/modules/` (so the modules page can preview
    // each module's auto-layout, not just designs).
    var eval = Evaluator.init(ctx.allocator, ctx.project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        ctx.allocator.destroy(mr.eval);
    };
    const block: *env_mod.DesignBlock = resolveBlock(ctx.allocator, ctx.project_dir, name, &eval, &module_res) orelse {
        res.status = 500;
        res.body = NO_BLOCK_MSG;
        return;
    };

    // A `?sub=<slug>` request scopes the layout to a single sub-block — the
    // schematic page's per-sub-block preview — so only that sub-block's parts
    // are placed, never the whole design. `?embed=1` trims the page chrome
    // (navbar/sidebar/edit controls) for inline display in that preview frame.
    const sub = subSlug(req);
    const eff_block: *env_mod.DesignBlock = if (sub) |s|
        (descendToSub(ctx.allocator, block, s) orelse {
            res.status = 404;
            res.body = NO_SUB_MSG;
            return;
        })
    else
        block;
    const embed = isEmbed(req);

    // Tuning weights come from the query (?w_align=… etc) — any present (or
    // ?regen=1) forces a fresh solve; otherwise the cached layout is reused.
    // ?refine=<layout> seeds the solve from a named saved layout and runs only the
    // routed tuck on it (improve a hand layout in place; the auto cache is left as-is).
    // Sub-scoped previews never touch the design's layout sidecars: they compute
    // fresh each time (the sub-block is small, so this is cheap) so a scoped run
    // can't clobber the whole-design auto cache or its saved-layout history.
    const tune = parseTuning(req);
    const refine_name: ?[]const u8 = if (sub != null) null else if (req.query()) |q| q.get("refine") else |_| null;
    const cached = if (sub != null) null else if (refine_name) |rn|
        readLayoutPoses(ctx.allocator, ctx.project_dir, name, rn)
    else if (tune.regen) null else readAutoPoses(ctx.allocator, ctx.project_dir, name);
    // No layout to show and nothing asked for one: place the parts on a plain
    // grid instead of running the (potentially expensive) optimizer on page open.
    // The optimizer still runs on demand — Regenerate / Apply tuning (?regen=/
    // weights), seeding a saved layout (?refine=), and the small per-sub-block
    // previews (which compute fresh and are cheap) all take the `solve` path.
    const grid_only = sub == null and refine_name == null and !tune.regen and cached == null;
    const placement = (if (grid_only)
        optimizer.gridPlace(ctx.allocator, eff_block, ctx.project_dir, tune.params)
    else
        optimizer.solve(ctx.allocator, eff_block, ctx.project_dir, cached, tune.params, if (refine_name != null) .refine else .place)) catch {
        res.status = 500;
        res.body = PLACEMENT_ERR_MSG;
        return;
    };
    // Persist the layout + its weights whenever the optimizer ran (miss /
    // stale / regen / tune), so later loads are instant and the controls show
    // the weights that actually produced the layout on screen. Each run is also
    // appended to the named-layout history so the user can review whether the
    // auto placement got better or worse over time. Scoped sub-block runs skip
    // this — there's no sidecar key for an individual sub-block yet.
    if (sub == null and placement.generated) {
        writeAutoCache(ctx.allocator, ctx.project_dir, name, placement, tune.params);
        recordAutoLayout(ctx.allocator, ctx.project_dir, name, placement);
    }
    const shown = if (sub != null or tune.tuned)
        tune.params
    else
        (readAutoParams(ctx.allocator, ctx.project_dir, name) orelse optimizer.Params{});

    // Routing runs only on demand (the Route button → ?route=1), on whatever
    // placement is loaded — it's not part of every page load.
    const ro = parseRoute(req);
    const routed: ?router.RouteResult = if (ro.run) (router.route(ctx.allocator, placement, ro.params) catch null) else null;
    const violations: []const drc.Violation = if (routed) |r|
        (drc.check(ctx.allocator, placement, r, ro.params.clearance) catch &.{})
    else
        &.{};

    const view = View.init(placement);
    // The named-layout history is a whole-design concept; scoped previews show none.
    const layouts: []const SavedLayout = if (sub != null) &.{} else readLayouts(ctx.allocator, ctx.project_dir, name);

    var aw: std.Io.Writer.Allocating = .init(ctx.allocator);
    const w = &aw.writer;

    try w.writeAll("<!DOCTYPE html><html><head><meta charset=\"utf-8\">");
    try w.writeAll("<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">");
    try w.print("<title>{s} — PCB Layout</title>", .{eff_block.name});
    try w.writeAll("<style>");
    try w.writeAll(assets_css.NAVBAR_CSS);
    try w.writeAll(PAGE_CSS);
    if (embed) try w.writeAll(EMBED_CSS);
    try w.writeAll("</style></head><body");
    if (embed) try w.writeAll(" class=\"embed\"");
    try w.writeAll(">");
    if (!embed) try pages_tmpl.Navbar.render(.{""}, w);

    try w.writeAll("<div class=\"pcb-layout\">");
    if (!embed) try writeSidebar(w, ctx.allocator, placement);
    try w.writeAll("<main class=\"pcb-main\">");
    if (embed) {
        // Compact, read-only chrome for the per-sub-block preview embedded in
        // the schematic page: a score line plus the routed-status + show
        // clearance/DRC toggles (initial state mirrors the page's globals).
        const tg = parseToggles(req);
        try writeEmbedBar(w);
        try writeEmbedRoute(w, ro.params, routed, violations.len, tg.clr, tg.drc);
    } else {
        // Header row: title + the Schematic ⇄ PCB Layout switcher (PCB active).
        // `name` resolves as a design under src/ first, else a reusable module —
        // so the Schematic link points at the matching viewer.
        const schematic_path: []const u8 = if (module_res != null) "/modules/" else "/schematics/";
        try w.writeAll("<div class=\"pcb-head\">");
        try w.print("<h1>{s} <span class=\"pcb-sub\">PCB Layout · force-directed · drag to edit</span></h1>", .{eff_block.name});
        try w.print(
            "<nav class=\"viewtoggle\" aria-label=\"View\">" ++
                "<a href=\"{s}{s}\">Schematic</a>" ++
                "<a class=\"active\" id=\"pcb-tab-2d\" href=\"/pcb-layout/{s}\">PCB Layout</a>" ++
                "<a id=\"pcb-tab-3d\" href=\"#\">3D View</a></nav>",
            .{ schematic_path, name, name },
        );
        try w.writeAll("</div>");
        try writeScorebar(w, placement, name);
        // When showing the plain grid placeholder, say so — the score is the raw
        // grid's, not an optimized layout, and Regenerate computes the real one.
        if (grid_only) try w.writeAll(
            "<div class=\"pcb-note\">Showing parts on a plain grid — no layout computed yet. " ++
                "Drag parts to arrange, or hit <b>Regenerate</b> to auto-place.</div>",
        );
        try writeTuning(w, shown);
        try writeScoreView(w, shown);
        const rp_warn = if (routed) |r| router.returnPathViolations(placement, r, router.RETURN_PATH_RADIUS_MM) else 0;
        try writeRoutePanel(w, ro.params, routed, violations.len, rp_warn);
    }
    try writeLegend(w, placement);
    try w.print(
        "<svg id=\"pcb-svg\" class=\"pcb-svg\" viewBox=\"0 0 {d:.0} {d:.0}\" width=\"{d:.0}\" height=\"{d:.0}\" xmlns=\"http://www.w3.org/2000/svg\"></svg>",
        .{ view.width, view.height, view.width, view.height },
    );
    // WebGL 3D-view stage — hidden until the "3D View" tab is opened, then the
    // body gets `.mode-3d` (CSS swaps the SVG out for this). Built lazily.
    if (!embed) try w.writeAll(PCB_3D_STAGE_HTML);
    if (!embed) try w.writeAll(COURTYARD_MODAL);
    try w.writeAll("</main>");
    // Right sidebar: the saved-layouts history (manual snapshots + auto-recorded
    // optimizer runs). Lives in its own column so the board has the full centre
    // width. Emitted before the scripts so BOARD_JS can wire up its Load/Delete
    // buttons. Omitted in the embedded per-sub-block preview.
    if (!embed) {
        const auto_score = LayoutScore{
            .hpwl = placement.score.hpwl_mm,
            .loop = placement.score.loop_mm,
            .caps = placement.score.loop_caps,
            .objective = placement.breakdown.objective,
        };
        try w.writeAll("<aside class=\"pcb-rside\">");
        try writeLayoutsPanel(w, layouts, auto_score);
        try w.writeAll("</aside>");
    }
    try w.writeAll("</div>");
    try writePcbData(w, ctx.allocator, ctx.project_dir, placement, shown, view, name, layouts, routed, ro.params.clearance, violations, embed);
    // Shared footprint engine (FP.padShape) must load before BOARD_JS runs. Both
    // scripts come after every column so the handlers find the elements they wire.
    try w.writeAll("<script src=\"/static/footprint_svg.js\"></script>");
    try w.writeAll(BOARD_JS);
    // 3D-view tab wiring — lazy-loads the WebGL stack on first open. Omitted in
    // the read-only embedded preview (no toggle there).
    if (!embed) try w.writeAll(PCB_3D_TOGGLE_JS);
    try w.writeAll("</body></html>");

    res.content_type = .HTML;
    res.body = aw.written();
}

/// Resolve `name` to a renderable design block. Preference: a design source
/// under `src/` (evaluated with `eval`). Fallback: a reusable module under
/// `lib/modules/` (via `modules_mod.resolveModuleBlock`, whose evaluator is
/// stashed in `module_res` for the caller to free). Null if neither exists.
fn resolveBlock(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    eval: *Evaluator,
    module_res: *?modules_mod.ResolvedBlock,
) ?*env_mod.DesignBlock {
    if (paths.designSourcePath(alloc, project_dir, name)) |path| {
        defer alloc.free(path);
        if (eval.evalFile(path)) |result| {
            switch (result) {
                .design_block => |b| return b,
                else => {},
            }
        } else |_| {}
    } else |_| {}
    module_res.* = modules_mod.resolveModuleBlock(alloc, project_dir, name);
    if (module_res.*) |mr| return mr.block;
    return null;
}

/// The `?sub=<slug>` query value (a slugified sub-block name), or null when the
/// request targets the whole design. Empty values count as absent.
fn subSlug(req: *httpz.Request) ?[]const u8 {
    const q = req.query() catch return null;
    const s = q.get("sub") orelse return null;
    return if (s.len == 0) null else s;
}

/// True when `?embed=1` is present — render the trimmed, read-only chrome used
/// by the schematic page's inline per-sub-block preview frame.
fn isEmbed(req: *httpz.Request) bool {
    const q = req.query() catch return false;
    return q.get("embed") != null;
}

/// Descend a design block into the top-level sub-block whose slugified name
/// matches `sub_slug` (the same `review.slugify` the schematic page uses for its
/// `data-sub` attributes, so the keys line up). Null when none match. Only the
/// sub-block's parts are then placed/routed — the whole design never is.
fn descendToSub(
    allocator: std.mem.Allocator,
    block: *env_mod.DesignBlock,
    sub_slug: []const u8,
) ?*env_mod.DesignBlock {
    for (block.sub_blocks) |sb| {
        const slug = review.slugify(allocator, sb.name) catch continue;
        if (std.mem.eql(u8, slug, sub_slug)) return sb.block;
    }
    return null;
}

/// Initial state of the embed preview's show-clearance / show-DRC toggles,
/// passed through from the schematic page's global checkboxes as `?clr=` / `?drc=`.
/// Clearance defaults off and DRC on, mirroring the standalone Route panel.
const Toggles = struct { clr: bool, drc: bool };

fn parseToggles(req: *httpz.Request) Toggles {
    const q = req.query() catch return .{ .clr = false, .drc = true };
    const clr_on = if (q.get("clr")) |v| std.mem.eql(u8, v, "1") else false;
    const drc_on = if (q.get("drc")) |v| !std.mem.eql(u8, v, "0") else true;
    return .{ .clr = clr_on, .drc = drc_on };
}

/// GET /api/pcb-layout/:name — export the solved placement as JSON: per-part
/// positions plus the full objective breakdown. The on-screen score bar only
/// shows HPWL + *raw* loop length; this also surfaces the value-weighted loop
/// and alignment terms the optimizer actually minimises, so a layout that looks
/// worse on the visible metric but wins on the true objective can be told apart.
/// Honours the same ?regen / tuning query as the page.
pub fn pcbLayoutJsonApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    var eval = Evaluator.init(ctx.allocator, ctx.project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        ctx.allocator.destroy(mr.eval);
    };
    const block: *env_mod.DesignBlock = resolveBlock(ctx.allocator, ctx.project_dir, name, &eval, &module_res) orelse {
        res.status = 500;
        res.body = NO_BLOCK_MSG;
        return;
    };

    const tune = parseTuning(req);
    const refine_name: ?[]const u8 = if (req.query()) |q| q.get("refine") else |_| null;
    const cached = if (refine_name) |rn|
        readLayoutPoses(ctx.allocator, ctx.project_dir, name, rn)
    else if (tune.regen) null else readAutoPoses(ctx.allocator, ctx.project_dir, name);
    const placement = optimizer.solve(ctx.allocator, block, ctx.project_dir, cached, tune.params, if (refine_name != null) .refine else .place) catch {
        res.status = 500;
        res.body = PLACEMENT_ERR_MSG;
        return;
    };
    if (placement.generated) writeAutoCache(ctx.allocator, ctx.project_dir, name, placement, tune.params);
    const shown = if (tune.tuned) tune.params else (readAutoParams(ctx.allocator, ctx.project_dir, name) orelse optimizer.Params{});

    var aw: std.Io.Writer.Allocating = .init(ctx.allocator);
    try writePlacementJson(&aw.writer, placement, shown, name);
    res.content_type = .JSON;
    res.body = aw.written();
}

const PNG_DEFAULT_WIDTH: u32 = 1200;

/// Inputs for `renderDesignPng` — the union of what the HTTP query and the MCP
/// `get_pcb_layout_image` tool can specify. Empty `highlight_*` → plain board;
/// any value → focus mode (spotlight + dim).
pub const PngRequest = struct {
    width: u32 = PNG_DEFAULT_WIDTH,
    highlight_nets: []const []const u8 = &.{},
    highlight_refs: []const []const u8 = &.{},
    route: bool = false,
    layout: ?[]const u8 = null,
    regen: bool = false,
    sub: ?[]const u8 = null,
};

/// Failures `renderDesignPng` surfaces; callers map these to an HTTP status or
/// MCP error message.
pub const PngError = error{ BlockNotFound, SubNotFound, BuildFailed } || png_mod.Error;

/// Resolve `name`, build (or load from cache) its placement, optionally route
/// it, and render a PNG — shared by the HTTP endpoint and the MCP tool. All
/// allocation goes through `alloc`; the returned bytes are owned by it.
pub fn renderDesignPng(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    opts: PngRequest,
) PngError![]u8 {
    var eval = Evaluator.init(alloc, project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        alloc.destroy(mr.eval);
    };
    const block = resolveBlock(alloc, project_dir, name, &eval, &module_res) orelse return error.BlockNotFound;
    const eff_block: *env_mod.DesignBlock = if (opts.sub) |s|
        (descendToSub(alloc, block, s) orelse return error.SubNotFound)
    else
        block;

    // Same placement-selection logic as the page: a named layout or regen forces
    // a solve; otherwise reuse the auto cache, falling back to a plain grid when
    // nothing is cached so an agent's first call stays cheap.
    const cached = if (opts.sub != null) null else if (opts.layout) |ln|
        readLayoutPoses(alloc, project_dir, name, ln)
    else if (opts.regen) null else readAutoPoses(alloc, project_dir, name);
    const grid_only = opts.sub == null and opts.layout == null and !opts.regen and cached == null;
    const placement = (if (grid_only)
        optimizer.gridPlace(alloc, eff_block, project_dir, .{})
    else
        optimizer.solve(alloc, eff_block, project_dir, cached, .{}, if (opts.layout != null) .refine else .place)) catch return error.BuildFailed;

    const route_params = router.RouteParams{};
    const routed: ?router.RouteResult = if (opts.route) (router.route(alloc, placement, route_params) catch null) else null;
    const violations: []const drc.Violation = if (routed) |r|
        (drc.check(alloc, placement, r, route_params.clearance) catch &.{})
    else
        &.{};

    return render_pcb_png.render(alloc, placement, .{
        .width = opts.width,
        .highlight_nets = opts.highlight_nets,
        .highlight_refs = opts.highlight_refs,
        .routed = routed,
        .violations = violations,
        .title = eff_block.name,
    });
}

/// GET /api/pcb-png/:name — render the solved layout as a PNG so an AI agent (or
/// any HTTP client) can *see* it, not just parse the coordinate JSON.
///
/// Query parameters (all optional):
///   width=<px>            output width (clamped); height follows the board
///   nets=A,B  refs=U1,C3  focus mode — spotlight these nets/components, dim rest
///   route=1               run the router and draw copper + DRC markers
///   layout=<name>         render a specific saved layout (else the auto cache)
///   regen=1               force a fresh solve instead of the cache
///   sub=<slug>            scope to one sub-block (per-sub-block preview)
///
/// Request-scoped allocation uses `req.arena` (freed after the response is sent;
/// `res.body` stays valid until then) — `ctx.allocator` is the global page
/// allocator, so a leaked image per call would never be reclaimed.
pub fn pcbPngApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const arena = req.arena;
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    const width: u32 = blk: {
        const q = req.query() catch break :blk PNG_DEFAULT_WIDTH;
        const wv = q.get("width") orelse break :blk PNG_DEFAULT_WIDTH;
        break :blk std.fmt.parseInt(u32, wv, 10) catch PNG_DEFAULT_WIDTH;
    };
    const opts = PngRequest{
        .width = width,
        .highlight_nets = csvParam(arena, req, "nets"),
        .highlight_refs = csvParam(arena, req, "refs"),
        .route = queryFlag(req, "route"),
        .layout = queryOpt(req, "layout"),
        .regen = queryFlag(req, "regen"),
        .sub = subSlug(req),
    };
    const png_bytes = renderDesignPng(arena, ctx.project_dir, name, opts) catch |e| {
        res.status = if (e == error.BlockNotFound or e == error.SubNotFound) 404 else 500;
        res.body = switch (e) {
            error.BlockNotFound => NO_BLOCK_MSG,
            error.SubNotFound => NO_SUB_MSG,
            else => PLACEMENT_ERR_MSG,
        };
        return;
    };
    res.content_type = .PNG;
    res.header("Cache-Control", "no-store");
    res.body = png_bytes;
}

/// True when query `key` is present and not "0"/empty (a boolean toggle).
fn queryFlag(req: *httpz.Request, key: []const u8) bool {
    const q = req.query() catch return false;
    const v = q.get(key) orelse return false;
    return !(v.len == 0 or std.mem.eql(u8, v, "0"));
}

/// Query `key` as an optional string (absent/empty → null).
fn queryOpt(req: *httpz.Request, key: []const u8) ?[]const u8 {
    const q = req.query() catch return null;
    const v = q.get(key) orelse return null;
    return if (v.len == 0) null else v;
}

/// Split a comma-separated query parameter into trimmed, non-empty tokens
/// (slices into the request's query buffer). Empty/absent → empty slice.
fn csvParam(arena: std.mem.Allocator, req: *httpz.Request, key: []const u8) []const []const u8 {
    const q = req.query() catch return &.{};
    const v = q.get(key) orelse return &.{};
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, v, ',');
    while (it.next()) |tok| {
        const t = std.mem.trim(u8, tok, " \t");
        if (t.len > 0) list.append(arena, t) catch break;
    }
    return list.toOwnedSlice(arena) catch &.{};
}

/// Serialize a placement for the JSON export: name, generated flag, the steering
/// weights, the visible `score`, the full objective `breakdown` (raw terms plus
/// their weighted contributions and the summed objective), the bounding box, and
/// each part's `ref/kind/x/y/rot/hw/hh`.
fn writePlacementJson(w: *std.Io.Writer, p: optimizer.Placement, params: optimizer.Params, name: []const u8) std.Io.Writer.Error!void {
    const b = p.breakdown;
    try w.writeAll(NAME_OPEN);
    try writeJsonStr(w, name);
    try w.print(",\"generated\":{s},", .{if (p.generated) "true" else "false"});
    try w.print("\"params\":{{\"loop_w\":{d},\"w_align\":{d},\"w_congest\":{d},\"cap_w_max\":{d},\"grid\":{s},\"compact\":\"{s}\"}},", .{
        params.loop_w, params.w_align, params.w_congest, params.cap_w_max, if (params.grid_courtyards) "true" else "false", @tagName(params.compact_mode),
    });
    try w.print("\"score\":{{\"hpwl_mm\":{d},\"loop_mm\":{d},\"loop_caps\":{d}}},", .{ p.score.hpwl_mm, p.score.loop_mm, p.score.loop_caps });
    try w.writeAll("\"breakdown\":");
    try writeBreakdownJson(w, b, params);
    try w.print(",\"bbox\":{{\"minx\":{d},\"miny\":{d},\"maxx\":{d},\"maxy\":{d}}},", .{ p.minx, p.miny, p.maxx, p.maxy });
    try w.writeAll(PARTS_OPEN);
    for (p.parts, 0..) |pt, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"ref\":");
        try writeJsonStr(w, pt.ref_des);
        try w.print(",\"kind\":\"{s}\",\"x\":{d},\"y\":{d},\"rot\":{d},\"hw\":{d},\"hh\":{d},\"fallback\":{s}}}", .{
            if (pt.kind == .hub) "hub" else "passive",
            pt.x,
            pt.y,
            pt.rot,
            pt.hw,
            pt.hh,
            if (pt.fallback) "true" else "false",
        });
    }
    try w.writeAll("]}");
}

/// Emit the objective `breakdown` as a JSON object: the raw terms, each term's
/// weighted contribution, and the summed `objective`. Shared by the GET export
/// and the POST score endpoint so both report the same shape.
fn writeBreakdownJson(w: *std.Io.Writer, b: optimizer.Breakdown, params: optimizer.Params) std.Io.Writer.Error!void {
    try w.print("{{\"hpwl\":{d},\"loop_raw\":{d},\"loop_weighted\":{d},\"loop_nh\":{d},\"loop_nh_weighted\":{d},", .{
        b.hpwl, b.loop_raw, b.loop_weighted, b.loop_nh, b.loop_nh_weighted,
    });
    try w.print("\"alignment\":{d},\"footprint\":{d},\"congestion\":{d},", .{ b.alignment, b.footprint, b.congestion });
    try w.print("\"loop_term\":{d},\"alignment_term\":{d},\"congestion_term\":{d},\"objective\":{d}}}", .{
        params.loop_w * b.loop_nh_weighted, params.w_align * b.alignment, params.w_congest * b.congestion, b.objective,
    });
}

// ── Live regen: background solve + best-so-far progress stream ──────────
//
// The "Regenerate" button no longer blocks the page on an 11–16 s solve.
// Instead it POSTs /api/pcb-regen-start, which spawns the optimizer on a
// background thread with a progress sink; the browser polls /api/pcb-progress
// and re-draws the board each time the optimizer finds a better arrangement, so
// you watch it converge instead of waiting on a spinner. When the run finishes
// the thread has written the auto-cache exactly as the synchronous path does,
// so the page just reloads to pick up the final (routable, history-recorded)
// layout.

/// Work item for a background live-regen solve. `name` is page_allocator-owned
/// (freed by the thread); `project_dir` is borrowed from the long-lived Handler,
/// which outlives every request thread.
const RegenJob = struct {
    name: []const u8,
    project_dir: []const u8,
    params: optimizer.Params,
    gen: u32,
};

/// Context the optimizer's progress sink carries: which design + generation a
/// streamed frame belongs to. Lives on the solver thread's stack for the solve.
const RegenProgress = struct { name: []const u8, gen: u32 };

/// optimizer.ProgressSink callback: serialize the best-so-far poses to a compact
/// frame and publish it under the job's design + generation. Best-effort — a
/// formatting/alloc failure just drops this frame (the next improvement retries).
fn regenOnBest(ctx_ptr: *anyopaque, parts: []const optimizer.Part, score: f64, pass: optimizer.ProgressPass) void {
    const ctx: *RegenProgress = @ptrCast(@alignCast(ctx_ptr));
    var aw: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer aw.deinit();
    const w = &aw.writer;
    w.print("{{\"pass\":\"{s}\",\"score\":{d:.2},\"parts\":[", .{ pass.label(), score }) catch return;
    for (parts, 0..) |p, i| {
        if (i > 0) w.writeAll(",") catch return;
        w.writeAll(REF_OPEN) catch return;
        writeJsonStr(w, p.ref_des) catch return;
        w.print(",\"x\":{d:.3},\"y\":{d:.3},\"rot\":{d:.0}}}", .{ p.x, p.y, p.rot }) catch return;
    }
    w.writeAll("]}") catch return;
    serve_root.pcbJobFrame(ctx.name, ctx.gen, aw.written());
}

/// Background thread: re-evaluate the design in its own arena, run the optimizer
/// with a progress sink streaming best-so-far frames, persist the result the same
/// way the synchronous page does, then mark the job done so the browser reloads.
fn regenThread(job: *RegenJob) void {
    const base = std.heap.page_allocator;
    defer {
        base.free(job.name);
        base.destroy(job);
    }
    var arena = std.heap.ArenaAllocator.init(base);
    defer arena.deinit();
    const a = arena.allocator();

    var had_err = true;
    run: {
        var eval = Evaluator.init(a, job.project_dir);
        defer eval.deinit();
        var module_res: ?modules_mod.ResolvedBlock = null;
        defer if (module_res) |mr| {
            mr.eval.deinit();
            a.destroy(mr.eval);
        };
        const block = resolveBlock(a, job.project_dir, job.name, &eval, &module_res) orelse break :run;

        var prog = RegenProgress{ .name = job.name, .gen = job.gen };
        optimizer.setProgressSink(.{ .ctx = &prog, .onBest = regenOnBest });
        defer optimizer.setProgressSink(null);

        const placement = optimizer.solve(a, block, job.project_dir, null, job.params, .place) catch break :run;
        if (placement.generated) {
            writeAutoCache(a, job.project_dir, job.name, placement, job.params);
            recordAutoLayout(a, job.project_dir, job.name, placement);
        }
        had_err = false;
    }
    serve_root.pcbJobFinish(job.name, job.gen, if (had_err) .failed else .ok);
}

/// POST /api/pcb-regen-start/:name — kick off a live (background) optimizer run
/// and return its generation id. The browser then polls /api/pcb-progress/:name
/// to animate the board converging and reloads when the run finishes. Honours the
/// same tuning query (?w_align / loop_w / w_congest / grid / compact) as ?regen=1.
/// If a run for this design is already in flight, its generation is returned and
/// no second solver is spawned (one per design at a time).
pub fn pcbRegenStartApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    const tune = parseTuning(req);
    const begin = serve_root.pcbJobBegin(name);
    if (begin.fresh) spawn: {
        const job = std.heap.page_allocator.create(RegenJob) catch {
            serve_root.pcbJobFinish(name, begin.gen, .failed);
            break :spawn;
        };
        job.* = .{
            .name = std.heap.page_allocator.dupe(u8, name) catch {
                std.heap.page_allocator.destroy(job);
                serve_root.pcbJobFinish(name, begin.gen, .failed);
                break :spawn;
            },
            .project_dir = ctx.project_dir,
            .params = tune.params,
            .gen = begin.gen,
        };
        const t = std.Thread.spawn(.{}, regenThread, .{job}) catch {
            std.heap.page_allocator.free(job.name);
            std.heap.page_allocator.destroy(job);
            serve_root.pcbJobFinish(name, begin.gen, .failed);
            break :spawn;
        };
        t.detach();
    }
    var aw: std.Io.Writer.Allocating = .init(ctx.allocator);
    try aw.writer.print("{{\"gen\":{d}}}", .{begin.gen});
    res.content_type = .JSON;
    res.body = aw.written();
}

/// GET /api/pcb-progress/:name — current live-regen state for the page's poll
/// loop: the active generation, the frame sequence (so the client skips frames
/// it already drew), run/done/err flags, and the latest best-so-far `frame`
/// (`{pass,score,parts}`) or null. `{"gen":0,"none":true}` means no run has been
/// started for this design.
pub fn pcbProgressApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    res.content_type = .JSON;
    const snap = serve_root.pcbJobSnapshot(ctx.allocator, name) orelse {
        res.body = "{\"gen\":0,\"none\":true}";
        return;
    };
    var aw: std.Io.Writer.Allocating = .init(ctx.allocator);
    const w = &aw.writer;
    try w.print("{{\"gen\":{d},\"seq\":{d},\"running\":{s},\"done\":{s},\"err\":{s},\"frame\":", .{
        snap.gen,
        snap.seq,
        if (snap.running) "true" else "false",
        if (snap.done) "true" else "false",
        if (snap.err) "true" else "false",
    });
    if (snap.frame) |f| try w.writeAll(f) else try w.writeAll("null");
    try w.writeByte('}');
    res.body = aw.written();
}

/// POST /api/pcb-score/:name — score an arbitrary hand layout *on the server*,
/// reusing the optimizer's own objective code (no metric duplicated in JS). Body
/// is the same `{"parts":[{ref,x,y,rot}, …]}` the save endpoint takes; returns
/// the full breakdown for those exact positions. Honours the ?tuning query.
pub fn pcbScoreApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    const body = req.body() orelse {
        res.status = 400;
        res.body = "no body";
        return;
    };
    const root = std.json.parseFromSliceLeaky(std.json.Value, req.arena, body, .{}) catch {
        res.status = 400;
        res.body = BAD_JSON_MSG;
        return;
    };
    if (root != .object) {
        res.status = 400;
        return;
    }
    const parts_v = root.object.get("parts") orelse {
        res.status = 400;
        return;
    };
    if (parts_v != .array) {
        res.status = 400;
        return;
    }
    var poses: std.ArrayListUnmanaged(optimizer.RefPose) = .empty;
    for (parts_v.array.items) |it| {
        if (it != .object) continue;
        const ref = it.object.get("ref") orelse continue;
        if (ref != .string) continue;
        try poses.append(ctx.allocator, .{
            .ref = ref.string,
            .x = jsonNum(it.object.get("x")),
            .y = jsonNum(it.object.get("y")),
            .rot = jsonNum(it.object.get("rot")),
        });
    }

    var eval = Evaluator.init(ctx.allocator, ctx.project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        ctx.allocator.destroy(mr.eval);
    };
    const block: *env_mod.DesignBlock = resolveBlock(ctx.allocator, ctx.project_dir, name, &eval, &module_res) orelse {
        res.status = 500;
        res.body = NO_BLOCK_MSG;
        return;
    };
    const eff_block = if (subSlug(req)) |s|
        (descendToSub(ctx.allocator, block, s) orelse {
            res.status = 404;
            res.body = NO_SUB_MSG;
            return;
        })
    else
        block;

    const tune = parseTuning(req);
    const bd = optimizer.scorePoses(ctx.allocator, eff_block, ctx.project_dir, poses.items, tune.params) catch {
        res.status = 500;
        res.body = "score error";
        return;
    };

    var aw: std.Io.Writer.Allocating = .init(ctx.allocator);
    try writeBreakdownJson(&aw.writer, bd, tune.params);
    res.content_type = .JSON;
    res.body = aw.written();
}

/// POST /api/pcb-route/:name — route the design at the *current on-screen* poses
/// (a loaded saved layout, or hand-dragged parts) rather than the auto-generated
/// placement, and return the copper as JSON. Body is the score endpoint's
/// `{"parts":[{ref,x,y,rot}, …]}` plus optional route params `track_width`,
/// `clearance`, `via_drill`, `via_dia` (mm; absent/0 → the router default).
/// Response `{tracks, vias, drc, routed, total}` is the same routed-copper shape
/// the page embeds, so the client redraws in place — no page reload, which is
/// what used to snap the layout back to auto.
pub fn pcbRouteApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    const body = req.body() orelse {
        res.status = 400;
        res.body = "no body";
        return;
    };
    const root = std.json.parseFromSliceLeaky(std.json.Value, req.arena, body, .{}) catch {
        res.status = 400;
        res.body = BAD_JSON_MSG;
        return;
    };
    if (root != .object) {
        res.status = 400;
        return;
    }
    const parts_v = root.object.get("parts") orelse {
        res.status = 400;
        return;
    };
    if (parts_v != .array) {
        res.status = 400;
        return;
    }
    var poses: std.ArrayListUnmanaged(optimizer.RefPose) = .empty;
    for (parts_v.array.items) |it| {
        if (it != .object) continue;
        const ref = it.object.get("ref") orelse continue;
        if (ref != .string) continue;
        try poses.append(ctx.allocator, .{
            .ref = ref.string,
            .x = jsonNum(it.object.get("x")),
            .y = jsonNum(it.object.get("y")),
            .rot = jsonNum(it.object.get("rot")),
        });
    }

    // Route params from the body (mm); a missing or non-positive field keeps the
    // router default — the same fields the GET ?route=1 query carries.
    var rp = router.RouteParams{};
    const tw = jsonNum(root.object.get("track_width"));
    if (tw > 0) rp.track_width = tw;
    const cl = jsonNum(root.object.get("clearance"));
    if (cl > 0) rp.clearance = cl;
    const vd = jsonNum(root.object.get("via_drill"));
    if (vd > 0) rp.via_drill = vd;
    const va = jsonNum(root.object.get("via_dia"));
    if (va > 0) rp.via_dia = va;

    var eval = Evaluator.init(ctx.allocator, ctx.project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        ctx.allocator.destroy(mr.eval);
    };
    const block: *env_mod.DesignBlock = resolveBlock(ctx.allocator, ctx.project_dir, name, &eval, &module_res) orelse {
        res.status = 500;
        res.body = NO_BLOCK_MSG;
        return;
    };
    const eff_block = if (subSlug(req)) |s|
        (descendToSub(ctx.allocator, block, s) orelse {
            res.status = 404;
            res.body = NO_SUB_MSG;
            return;
        })
    else
        block;

    // Build the placement at the supplied poses (never re-optimized), route it,
    // and DRC-check — exactly the GET ?route=1 pipeline, but on the client's
    // layout instead of the cached auto one.
    const placement = optimizer.placeFromPoses(ctx.allocator, eff_block, ctx.project_dir, poses.items, optimizer.Params{}) catch {
        res.status = 500;
        res.body = PLACEMENT_ERR_MSG;
        return;
    };
    const routed = router.route(ctx.allocator, placement, rp) catch {
        res.status = 500;
        res.body = "Routing error";
        return;
    };
    const violations: []const drc.Violation = drc.check(ctx.allocator, placement, routed, rp.clearance) catch &.{};

    const rp_warn = router.returnPathViolations(placement, routed, router.RETURN_PATH_RADIUS_MM);

    var aw: std.Io.Writer.Allocating = .init(ctx.allocator);
    const w = &aw.writer;
    try w.writeAll("{");
    try writeRoutedArrays(w, routed, violations);
    try w.print(",\"routed\":{d},\"total\":{d},\"return_path\":{d}}}", .{ routed.routed, routed.total, rp_warn });
    res.content_type = .JSON;
    res.body = aw.written();
}

/// POST /api/pcb-layouts/:name — save a named layout snapshot (kind "manual").
/// Body: `{"name","parts":[{ref,x,y,rot}, …]}`; the score is computed on the
/// server (no client-side metric). Upserts by name (re-save overwrites in
/// place); a new name is prepended so the newest sits at the top of the list.
pub fn saveNamedLayoutApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    const root = parseJsonObject(req, res) orelse return;
    const nm_v = root.object.get("name") orelse {
        res.status = 400;
        res.body = "no name";
        return;
    };
    if (nm_v != .string) {
        res.status = 400;
        return;
    }
    const nm = std.mem.trim(u8, nm_v.string, " \t\n\r");
    if (nm.len == 0 or nm.len > 80) {
        res.status = 400;
        res.body = "bad name";
        return;
    }
    const parts = parsePartPoses(req.arena, root.object.get("parts")) orelse {
        res.status = 400;
        res.body = "no parts";
        return;
    };

    // Score the hand layout on the server with the optimizer's own objective —
    // the same code the live `/api/pcb-score` endpoint uses — so a saved layout
    // is directly comparable to the auto baseline (HPWL + real routed-trace
    // loop). A resolve/score failure just leaves the entry unscored.
    var score: ?LayoutScore = null;
    {
        var eval = Evaluator.init(ctx.allocator, ctx.project_dir);
        defer eval.deinit();
        var module_res: ?modules_mod.ResolvedBlock = null;
        defer if (module_res) |mr| {
            mr.eval.deinit();
            ctx.allocator.destroy(mr.eval);
        };
        if (resolveBlock(ctx.allocator, ctx.project_dir, name, &eval, &module_res)) |block| {
            const params = readAutoParams(ctx.allocator, ctx.project_dir, name) orelse optimizer.Params{};
            const poses = try req.arena.alloc(optimizer.RefPose, parts.len);
            for (parts, 0..) |p, i| poses[i] = .{ .ref = p.ref, .x = p.x, .y = p.y, .rot = p.rot };
            if (optimizer.scorePoses(ctx.allocator, block, ctx.project_dir, poses, params)) |bd| {
                score = .{ .hpwl = bd.hpwl, .loop = bd.loop_raw, .caps = 0, .objective = bd.objective };
            } else |_| {}
        }
    }

    var entry = SavedLayout{ .name = nm, .kind = KIND_MANUAL, .ts = clock.timestamp(), .score = score, .parts = parts };
    const existing = readLayouts(req.arena, ctx.project_dir, name);
    var out: std.ArrayListUnmanaged(SavedLayout) = .empty;
    var replaced = false;
    for (existing) |L| {
        if (!replaced and std.mem.eql(u8, L.name, nm)) {
            // Re-saving an existing name overwrites its poses/score in place but
            // keeps its default status — the user re-captured the same layout.
            entry.default = L.default;
            try out.append(req.arena, entry);
            replaced = true;
        } else try out.append(req.arena, L);
    }
    if (!replaced) try out.insert(req.arena, 0, entry);
    writeLayouts(req.arena, ctx.project_dir, name, out.items);
    res.content_type = .JSON;
    res.body = OK_JSON_TRUE;
}

/// POST /api/pcb-layouts/:name/delete — drop a named layout. Body: `{"name"}`.
pub fn deleteNamedLayoutApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    const root = parseJsonObject(req, res) orelse return;
    const nm_v = root.object.get("name") orelse {
        res.status = 400;
        return;
    };
    if (nm_v != .string) {
        res.status = 400;
        return;
    }
    const existing = readLayouts(req.arena, ctx.project_dir, name);
    var out: std.ArrayListUnmanaged(SavedLayout) = .empty;
    for (existing) |L| {
        if (std.mem.eql(u8, L.name, nm_v.string)) continue;
        try out.append(req.arena, L);
    }
    writeLayouts(req.arena, ctx.project_dir, name, out.items);
    res.content_type = .JSON;
    res.body = OK_JSON_TRUE;
}

/// POST /api/pcb-layouts/:name/default — mark which saved layout the KiCad sync
/// seeds first-insertion placement + vias from. Body `{"name":"<layout>"}` sets
/// that entry as the (single) default; an empty/blank name clears the default.
/// A name that matches no entry just clears it. Persists the top-level
/// `"default"` field to `.layouts.json`; returns `{"ok":true}`.
pub fn setDefaultLayoutApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    const root = parseJsonObject(req, res) orelse return;
    const nm_v = root.object.get("name") orelse {
        res.status = 400;
        return;
    };
    if (nm_v != .string) {
        res.status = 400;
        return;
    }
    const want = std.mem.trim(u8, nm_v.string, " \t\n\r");
    const existing = readLayouts(req.arena, ctx.project_dir, name);
    var out: std.ArrayListUnmanaged(SavedLayout) = .empty;
    for (existing) |L| {
        var e = L;
        e.default = want.len > 0 and std.mem.eql(u8, L.name, want);
        try out.append(req.arena, e);
    }
    writeLayouts(req.arena, ctx.project_dir, name, out.items);
    res.content_type = .JSON;
    res.body = OK_JSON_TRUE;
}

/// POST /api/pcb-rescore/:name — recompute every saved layout's objective with
/// the *current* engine and persist the refreshed scores to `.layouts.json`.
///
/// Each saved layout stores the score the engine produced when it was captured;
/// after the placement/scoring code changes those numbers go stale, so the
/// panel's "Δ vs auto" compares an old-engine saved score against a fresh-engine
/// auto baseline (the page-load `solve` always re-scores the auto layout). This
/// re-runs `scorePoses` on each layout's stored part positions so every entry is
/// measured by the live engine again, making the column comparable. Body is
/// ignored; returns `{"ok":true,"rescored":N}`. A layout with no stored parts,
/// or one whose scoring fails, keeps its previous score.
pub fn rescoreLayoutsApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    const existing = readLayouts(req.arena, ctx.project_dir, name);
    if (existing.len == 0) {
        res.content_type = .JSON;
        res.body = "{\"ok\":true,\"rescored\":0}";
        return;
    }

    var eval = Evaluator.init(ctx.allocator, ctx.project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        ctx.allocator.destroy(mr.eval);
    };
    const block: *env_mod.DesignBlock = resolveBlock(ctx.allocator, ctx.project_dir, name, &eval, &module_res) orelse {
        res.status = 500;
        res.body = NO_BLOCK_MSG;
        return;
    };

    // Same weights the on-screen auto baseline uses, so the refreshed saved
    // scores are directly comparable to it (the panel's delta is auto-relative).
    const params = readAutoParams(ctx.allocator, ctx.project_dir, name) orelse optimizer.Params{};

    var out: std.ArrayListUnmanaged(SavedLayout) = .empty;
    var n: usize = 0;
    for (existing) |L| {
        var updated = L;
        if (L.parts.len > 0) {
            const poses = try req.arena.alloc(optimizer.RefPose, L.parts.len);
            for (L.parts, 0..) |p, i| poses[i] = .{ .ref = p.ref, .x = p.x, .y = p.y, .rot = p.rot };
            if (optimizer.scorePoses(req.arena, block, ctx.project_dir, poses, params)) |bd| {
                updated.score = .{
                    .hpwl = bd.hpwl,
                    .loop = bd.loop_raw,
                    .caps = if (L.score) |s| s.caps else 0,
                    .objective = bd.objective,
                };
                n += 1;
            } else |_| {}
        }
        try out.append(req.arena, updated);
    }
    writeLayouts(req.arena, ctx.project_dir, name, out.items);

    res.content_type = .JSON;
    res.body = try std.fmt.allocPrint(req.arena, "{{\"ok\":true,\"rescored\":{d}}}", .{n});
}

/// POST /api/pcb-score-batch/:name — score every saved layout's stored poses on
/// the server (the design block is resolved once, then each pose-set scored), so
/// the page can re-weigh the whole saved-layout panel under the Score-view
/// weights from a single round-trip. Returns `{"results":[{"name",breakdown}, …]}`
/// with each layout's full raw breakdown; read-only (unlike `pcb-rescore`, it
/// persists nothing). The raw terms the client re-weighs are weight-independent,
/// so the result is stable regardless of `?tuning` (honoured only for parity).
pub fn pcbScoreBatchApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    const layouts = readLayouts(req.arena, ctx.project_dir, name);

    var eval = Evaluator.init(ctx.allocator, ctx.project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        ctx.allocator.destroy(mr.eval);
    };
    const block: *env_mod.DesignBlock = resolveBlock(ctx.allocator, ctx.project_dir, name, &eval, &module_res) orelse {
        res.status = 500;
        res.body = NO_BLOCK_MSG;
        return;
    };
    const tune = parseTuning(req);

    var aw: std.Io.Writer.Allocating = .init(req.arena);
    const w = &aw.writer;
    try w.writeAll("{\"results\":[");
    var first = true;
    for (layouts) |L| {
        if (L.parts.len == 0) continue;
        const poses = try req.arena.alloc(optimizer.RefPose, L.parts.len);
        for (L.parts, 0..) |p, i| poses[i] = .{ .ref = p.ref, .x = p.x, .y = p.y, .rot = p.rot };
        const bd = optimizer.scorePoses(req.arena, block, ctx.project_dir, poses, tune.params) catch continue;
        if (!first) try w.writeAll(",");
        first = false;
        try w.writeAll("{\"name\":");
        try writeJsonStr(w, L.name);
        try w.writeAll(",\"breakdown\":");
        try writeBreakdownJson(w, bd, tune.params);
        try w.writeByte('}');
    }
    try w.writeAll("]}");
    res.content_type = .JSON;
    res.body = aw.written();
}

/// Parse the request body as a JSON object, setting a 400 and returning null on
/// any failure (missing body / malformed JSON / non-object root).
fn parseJsonObject(req: *httpz.Request, res: *httpz.Response) ?std.json.Value {
    const body = req.body() orelse {
        res.status = 400;
        res.body = "no body";
        return null;
    };
    const root = std.json.parseFromSliceLeaky(std.json.Value, req.arena, body, .{}) catch {
        res.status = 400;
        res.body = BAD_JSON_MSG;
        return null;
    };
    if (root != .object) {
        res.status = 400;
        return null;
    }
    return root;
}

fn writeFileAll(path: []const u8, data: []const u8) !void {
    const f = try infra_fs.cwd().createFile(path, .{});
    defer f.close();
    try f.writeAll(data);
}

const MAX_FP_BYTES: usize = 1024 * 1024;

/// Round a courtyard half-extent up to the placement grid, the same rule the
/// optimizer draws with (`optimizer.ceilToGrid`) and the modal preview mirrors
/// (`gceil` in BOARD_JS). The `1e-9` slack stops a half-extent already on the
/// grid from being bumped a whole step by float error — which matters because
/// offset mode constructs a value designed to land exactly on a grid line.
fn courtCeilGrid(v: f64) f64 {
    const g = optimizer.GRID_MM;
    return std.math.ceil(v / g - 1e-9) * g;
}

/// POST /api/courtyard/:name — rewrite a footprint's courtyard. Two modes:
///   `{"fp":"c-0402","mode":"size","hw":1.2,"hh":0.8}` — hw/hh are the
///     *effective* courtyard half-extents (what the layout draws); we invert
///     the loader's air-gap margin so the written rect reloads to exactly those.
///   `{"fp":"c-0402","mode":"offset","offset":0.2}` — the offset is the literal
///     gap from the pad bounding box to the courtyard edge. Sized off the
///     footprint's own pads, snapped to the placer grid, then (like "size") with
///     the loader's air-margin stripped back out, so the drawn courtyard is
///     exactly `pad-bbox + offset` on the grid — no extra margin on top.
/// Mode defaults to "size" when absent. Then re-pack via `?regen=1`.
pub fn savePcbCourtyardApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const body = req.body() orelse {
        res.status = 400;
        res.body = "no body";
        return;
    };
    const root = std.json.parseFromSliceLeaky(std.json.Value, req.arena, body, .{}) catch {
        res.status = 400;
        res.body = BAD_JSON_MSG;
        return;
    };
    if (root != .object) {
        res.status = 400;
        return;
    }
    const fp_v = root.object.get("fp") orelse {
        res.status = 400;
        return;
    };
    if (fp_v != .string or !safeFootprintName(fp_v.string)) {
        res.status = 400;
        res.body = "bad footprint name";
        return;
    }
    const path = std.fmt.allocPrint(ctx.allocator, "{s}/lib/footprints/{s}.sexp", .{ ctx.project_dir, fp_v.string }) catch {
        res.status = 500;
        return;
    };
    defer ctx.allocator.free(path);
    const src = infra_fs.cwd().readFileAlloc(ctx.allocator, path, MAX_FP_BYTES) catch {
        res.status = 404;
        res.body = "footprint not found";
        return;
    };

    // Two ways to size the rect (see the doc comment). Both store an effective
    // half-extent with the loader's air-gap margin stripped out, so geometry.load
    // adds it back to exactly the intended courtyard. "offset" derives that
    // effective extent from the footprint's own pads (pad-bbox + gap, snapped);
    // "size" (the default) takes it straight from the hw/hh fields.
    const is_offset = blk: {
        const mv = root.object.get("mode") orelse break :blk false;
        if (mv != .string) break :blk false;
        break :blk std.mem.eql(u8, mv.string, "offset");
    };
    var rw: f64 = undefined;
    var rh: f64 = undefined;
    if (is_offset) {
        const off = @max(jsonNum(root.object.get("offset")), 0);
        const g = geometry.load(req.arena, ctx.project_dir, fp_v.string, 0, geometry.BBOX_MARGIN_MM);
        var ehw: f64 = 0;
        var ehh: f64 = 0;
        for (g.pads) |p| {
            ehw = @max(ehw, @abs(p.x) + p.w / 2);
            ehh = @max(ehh, @abs(p.y) + p.h / 2);
        }
        if (g.pads.len == 0 or (ehw <= 0 and ehh <= 0)) {
            res.status = 400;
            res.body = "footprint has no pads to offset from";
            return;
        }
        // The offset is the literal gap from the pad bounding box to the
        // courtyard edge. Snap that target half-extent to the grid the placer
        // draws on, then strip the loader's air-margin (geometry.load adds it
        // back) so the rendered courtyard is exactly the grid-snapped gap — no
        // extra margin stacked on top.
        const margin = geometry.BBOX_MARGIN_MM;
        rw = @max(courtCeilGrid(ehw + off) - margin, 0.05);
        rh = @max(courtCeilGrid(ehh + off) - margin, 0.05);
    } else {
        const margin = geometry.BBOX_MARGIN_MM;
        rw = @max(jsonNum(root.object.get("hw")) - margin, 0.05);
        rh = @max(jsonNum(root.object.get("hh")) - margin, 0.05);
    }

    const updated = rewriteCourtyard(ctx.allocator, src, rw, rh) catch {
        res.status = 500;
        res.body = "rewrite failed";
        return;
    };
    writeFileAll(path, updated) catch {
        res.status = 500;
        res.body = "write failed";
        return;
    };
    res.content_type = .JSON;
    res.body = OK_JSON_TRUE;
}

/// A footprint name must be a bare file stem — no path separators or `..`, so a
/// request can't escape `lib/footprints/`.
fn safeFootprintName(fp: []const u8) bool {
    if (fp.len == 0 or fp.len > 128) return false;
    if (std.mem.indexOfScalar(u8, fp, '/') != null) return false;
    if (std.mem.indexOfScalar(u8, fp, '\\') != null) return false;
    if (std.mem.indexOf(u8, fp, "..") != null) return false;
    return true;
}

/// Return `src` with its `(courtyard …)` form replaced by an origin-centred
/// rect of the given half-extents, inserting one before the footprint's closing
/// paren if none exists.
fn rewriteCourtyard(alloc: std.mem.Allocator, src: []const u8, rw: f64, rh: f64) HandlerError![]u8 {
    var buf: std.Io.Writer.Allocating = .init(alloc);
    const w = &buf.writer;
    const form = try std.fmt.allocPrint(alloc, "(courtyard (rect {d:.3} {d:.3} {d:.3} {d:.3}))", .{ -rw, -rh, rw, rh });
    if (std.mem.indexOf(u8, src, "(courtyard")) |start| {
        var depth: i32 = 0;
        var i: usize = start;
        var end: usize = src.len;
        while (i < src.len) : (i += 1) {
            if (src[i] == '(') depth += 1;
            if (src[i] == ')') {
                depth -= 1;
                if (depth == 0) {
                    end = i + 1;
                    break;
                }
            }
        }
        try w.writeAll(src[0..start]);
        try w.writeAll(form);
        try w.writeAll(src[end..]);
    } else {
        const last = std.mem.lastIndexOfScalar(u8, src, ')') orelse {
            try w.writeAll(src);
            return buf.written();
        };
        try w.writeAll(src[0..last]);
        try w.writeAll("  ");
        try w.writeAll(form);
        try w.writeAll("\n");
        try w.writeAll(src[last..]);
    }
    return buf.written();
}

fn jsonNum(v: ?std.json.Value) f64 {
    const val = v orelse return 0;
    return switch (val) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => 0,
    };
}

/// Read the `.placement.json` sidecar into a ref → SavedPos map, or null if
/// absent/unreadable. Strings are owned by `alloc` (request lifetime).
fn readSaved(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8) ?std.StringHashMap(SavedPos) {
    const path = paths.designSiblingPath(alloc, project_dir, name, SAVED_EXT) catch return null;
    defer alloc.free(path);
    const data = infra_fs.cwd().readFileAlloc(alloc, path, 1 << 20) catch return null;
    const root = std.json.parseFromSliceLeaky(std.json.Value, alloc, data, .{}) catch return null;
    if (root != .object) return null;
    const parts = root.object.get("parts") orelse return null;
    if (parts != .array) return null;
    var m = std.StringHashMap(SavedPos).init(alloc);
    for (parts.array.items) |it| {
        if (it != .object) continue;
        const ref = it.object.get("ref") orelse continue;
        if (ref != .string) continue;
        m.put(ref.string, .{
            .x = jsonNum(it.object.get("x")),
            .y = jsonNum(it.object.get("y")),
            .rot = jsonNum(it.object.get("rot")),
        }) catch return m;
    }
    return m;
}

/// The poses of a single named saved layout (`?refine=<layout>`), as `RefPose`s
/// ready to seed `solve`. Null when no layout by that name exists. Used to refine
/// a specific hand layout with the routed tuck rather than re-placing from scratch.
fn readLayoutPoses(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8, want: []const u8) ?[]const optimizer.RefPose {
    for (readLayouts(alloc, project_dir, name)) |lay| {
        if (!std.mem.eql(u8, lay.name, want)) continue;
        var list: std.ArrayListUnmanaged(optimizer.RefPose) = .empty;
        for (lay.parts) |pp| {
            list.append(alloc, .{ .ref = pp.ref, .x = pp.x, .y = pp.y, .rot = pp.rot }) catch return null;
        }
        return list.toOwnedSlice(alloc) catch null;
    }
    return null;
}

/// Read every saved layout for `name` from its `.layouts.json` sidecar
/// (newest first). When that file is absent, migrate the legacy single-slot
/// `.placement.json` into a one-entry list so the historic hand placement is
/// not lost. Returns an empty slice when neither exists or on parse failure;
/// allocations live on `alloc` (request lifetime).
fn readLayouts(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8) []const SavedLayout {
    if (paths.designSiblingPath(alloc, project_dir, name, LAYOUTS_EXT)) |path| {
        defer alloc.free(path);
        if (infra_fs.cwd().readFileAlloc(alloc, path, 1 << 20)) |data| {
            if (parseLayouts(alloc, data)) |list| return list;
        } else |_| {}
    } else |_| {}
    return migrateSaved(alloc, project_dir, name);
}

/// Parse a `.layouts.json` body (`{"layouts":[…]}`) into a slice of
/// `SavedLayout`. Each entry needs a `name`; `kind` defaults to auto, `score`
/// is present only when an `hpwl` field is. Null on malformed top-level JSON.
fn parseLayouts(alloc: std.mem.Allocator, data: []const u8) ?[]const SavedLayout {
    const root = std.json.parseFromSliceLeaky(std.json.Value, alloc, data, .{}) catch return null;
    if (root != .object) return null;
    const arr = root.object.get("layouts") orelse return null;
    if (arr != .array) return null;
    // Top-level `"default":"<name>"` names the one layout the KiCad sync seeds
    // from; flag the matching entry below. Absent / empty → no default.
    const default_name: []const u8 = blk: {
        const dv = root.object.get("default") orelse break :blk "";
        break :blk if (dv == .string) dv.string else "";
    };
    var list: std.ArrayListUnmanaged(SavedLayout) = .empty;
    for (arr.array.items) |it| {
        if (it != .object) continue;
        const nm = it.object.get("name") orelse continue;
        if (nm != .string) continue;
        const kind: []const u8 = blk: {
            const k = it.object.get("kind") orelse break :blk KIND_AUTO;
            break :blk if (k == .string and std.mem.eql(u8, k.string, KIND_MANUAL)) KIND_MANUAL else KIND_AUTO;
        };
        var score: ?LayoutScore = null;
        if (it.object.get("hpwl")) |_| score = .{
            .hpwl = jsonNum(it.object.get("hpwl")),
            .loop = jsonNum(it.object.get("loop")),
            .caps = @intFromFloat(@max(@floor(jsonNum(it.object.get("caps"))), 0)),
            .objective = jsonNum(it.object.get("objective")), // 0 for legacy entries
        };
        const parts = parsePartPoses(alloc, it.object.get("parts")) orelse &[_]PartPose{};
        list.append(alloc, .{
            .name = nm.string,
            .kind = kind,
            .ts = @intFromFloat(jsonNum(it.object.get("ts"))),
            .score = score,
            .parts = parts,
            .default = default_name.len > 0 and std.mem.eql(u8, nm.string, default_name),
        }) catch return list.items;
    }
    return list.toOwnedSlice(alloc) catch null;
}

/// Parse a `[{"ref","x","y","rot"}, …]` JSON array into `PartPose`s. Null when
/// the value is missing or not an array; bad elements are skipped.
fn parsePartPoses(alloc: std.mem.Allocator, v: ?std.json.Value) ?[]const PartPose {
    const arr = v orelse return null;
    if (arr != .array) return null;
    var list: std.ArrayListUnmanaged(PartPose) = .empty;
    for (arr.array.items) |it| {
        if (it != .object) continue;
        const ref = it.object.get("ref") orelse continue;
        if (ref != .string) continue;
        list.append(alloc, .{
            .ref = ref.string,
            .x = jsonNum(it.object.get("x")),
            .y = jsonNum(it.object.get("y")),
            .rot = jsonNum(it.object.get("rot")),
        }) catch return list.items;
    }
    return list.toOwnedSlice(alloc) catch null;
}

/// Build a one-entry layout list from the legacy `.placement.json` slot (kind
/// "manual", name "saved", no score). Empty slice when no legacy file exists.
fn migrateSaved(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8) []const SavedLayout {
    const m = readSaved(alloc, project_dir, name) orelse return &[_]SavedLayout{};
    var parts: std.ArrayListUnmanaged(PartPose) = .empty;
    var it = m.iterator();
    while (it.next()) |e| parts.append(alloc, .{
        .ref = e.key_ptr.*,
        .x = e.value_ptr.x,
        .y = e.value_ptr.y,
        .rot = e.value_ptr.rot,
    }) catch break;
    if (parts.items.len == 0) return &[_]SavedLayout{};
    const one = alloc.alloc(SavedLayout, 1) catch return &[_]SavedLayout{};
    one[0] = .{ .name = "saved", .kind = KIND_MANUAL, .ts = 0, .score = null, .parts = parts.items };
    return one;
}

/// Persist the layout list to `.layouts.json`. Best-effort: a write failure
/// just means the list reverts to what was last on disk.
fn writeLayouts(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8, layouts: []const SavedLayout) void {
    const path = paths.designSiblingPath(alloc, project_dir, name, LAYOUTS_EXT) catch return;
    defer alloc.free(path);
    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    writeLayoutsFileJson(w, layouts) catch return;
    writeFileAll(path, aw.written()) catch return;
}

/// Serialize the layout list to the `.layouts.json` on-disk shape: an optional
/// top-level `"default":"<name>"` (the entry whose `default` flag is set, if
/// any) followed by the `layouts` array. Score fields (hpwl/loop/caps) are
/// flattened onto each entry and omitted when unscored.
fn writeLayoutsFileJson(w: *std.Io.Writer, layouts: []const SavedLayout) std.Io.Writer.Error!void {
    try w.writeAll("{");
    for (layouts) |L| {
        if (!L.default) continue;
        try w.writeAll("\"default\":");
        try writeJsonStr(w, L.name);
        try w.writeAll(",");
        break;
    }
    try w.writeAll("\"layouts\":[");
    for (layouts, 0..) |L, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll(NAME_OPEN);
        try writeJsonStr(w, L.name);
        try w.writeAll(",\"kind\":");
        try writeJsonStr(w, L.kind);
        try w.print(",\"ts\":{d}", .{L.ts});
        if (L.score) |s| try w.print(",\"hpwl\":{d},\"loop\":{d},\"caps\":{d},\"objective\":{d}", .{ s.hpwl, s.loop, s.caps, s.objective });
        try w.writeAll(",\"parts\":[");
        for (L.parts, 0..) |pt, j| {
            if (j > 0) try w.writeAll(",");
            try w.writeAll(REF_OPEN);
            try writeJsonStr(w, pt.ref);
            try w.print(",\"x\":{d},\"y\":{d},\"rot\":{d}}}", .{ pt.x, pt.y, pt.rot });
        }
        try w.writeAll("]}");
    }
    try w.writeAll("]}");
}

/// Append an auto-recorded snapshot of the just-generated `placement` to the
/// layout history. Skips when the newest entry is an identical auto run (same
/// score + part count), then prunes auto entries past `MAX_AUTO_LAYOUTS`.
fn recordAutoLayout(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8, p: optimizer.Placement) void {
    const existing = readLayouts(alloc, project_dir, name);
    const score = LayoutScore{ .hpwl = p.score.hpwl_mm, .loop = p.score.loop_mm, .caps = p.score.loop_caps, .objective = p.breakdown.objective };
    if (existing.len > 0 and std.mem.eql(u8, existing[0].kind, KIND_AUTO)) {
        if (existing[0].score) |s0| {
            if (existing[0].parts.len == p.parts.len and scoreApproxEq(s0, score)) {
                // Same layout as the newest auto entry. If it predates the
                // objective field, backfill it in place; otherwise it's a true
                // duplicate and there's nothing new to record.
                if (s0.objective > 0) return;
                backfillNewestScore(alloc, project_dir, name, existing, score);
                return;
            }
        }
    }
    const parts = alloc.alloc(PartPose, p.parts.len) catch return;
    for (p.parts, 0..) |pt, i| parts[i] = .{ .ref = pt.ref_des, .x = pt.x, .y = pt.y, .rot = pt.rot };
    const now = clock.timestamp();
    const entry = SavedLayout{
        .name = fmtAutoName(alloc, now) catch return,
        .kind = KIND_AUTO,
        .ts = now,
        .score = score,
        .parts = parts,
    };
    // Newest first; keep every manual entry but only the most-recent autos.
    // The entry the user marked default is never pruned (else a default that
    // happens to be an auto run could fall off the cap and dangle the sync).
    var out: std.ArrayListUnmanaged(SavedLayout) = .empty;
    out.append(alloc, entry) catch return;
    var autos: usize = 1;
    for (existing) |L| {
        if (std.mem.eql(u8, L.kind, KIND_AUTO)) {
            if (autos >= MAX_AUTO_LAYOUTS and !L.default) continue;
            autos += 1;
        }
        out.append(alloc, L) catch break;
    }
    writeLayouts(alloc, project_dir, name, out.items);
}

/// Two scores are "the same layout" for dedup when caps match and both
/// continuous metrics agree to within 0.05 mm.
fn scoreApproxEq(a: LayoutScore, b: LayoutScore) bool {
    return a.caps == b.caps and @abs(a.hpwl - b.hpwl) < 0.05 and @abs(a.loop - b.loop) < 0.05;
}

/// Rewrite the layout list with `score` patched onto the newest entry — used to
/// backfill the objective onto a pre-objective auto entry a regen re-confirms,
/// without churning the history with a duplicate row.
fn backfillNewestScore(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8, existing: []const SavedLayout, score: LayoutScore) void {
    var out: std.ArrayListUnmanaged(SavedLayout) = .empty;
    for (existing, 0..) |L, i| {
        var e = L;
        if (i == 0) e.score = score;
        out.append(alloc, e) catch return;
    }
    writeLayouts(alloc, project_dir, name, out.items);
}

/// Name for an auto-recorded entry: `auto · Mon D HH:MM:SS` (UTC). The seconds
/// keep two same-minute regenerations distinct.
fn fmtAutoName(alloc: std.mem.Allocator, ts: i64) std.mem.Allocator.Error![]const u8 {
    const es = clock.epoch.EpochSeconds{ .secs = @intCast(ts) };
    const ds = es.getDaySeconds();
    const md = es.getEpochDay().calculateYearDay().calculateMonthDay();
    return std.fmt.allocPrint(alloc, "auto · {s} {d} {d:0>2}:{d:0>2}:{d:0>2}", .{
        monthAbbrev(md.month),   md.day_index + 1,          ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    });
}

fn monthAbbrev(m: clock.epoch.Month) []const u8 {
    return switch (m) {
        .jan => "Jan",
        .feb => "Feb",
        .mar => "Mar",
        .apr => "Apr",
        .may => "May",
        .jun => "Jun",
        .jul => "Jul",
        .aug => "Aug",
        .sep => "Sep",
        .oct => "Oct",
        .nov => "Nov",
        .dec => "Dec",
    };
}

/// Read the `.autolayout.json` cache into a slice of `RefPose`, or null if
/// absent/unreadable. Strings are owned by `alloc` (request lifetime), which
/// outlives the `solve` call that consumes them.
fn readAutoPoses(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8) ?[]const optimizer.RefPose {
    const path = paths.designSiblingPath(alloc, project_dir, name, AUTO_EXT) catch return null;
    defer alloc.free(path);
    const data = infra_fs.cwd().readFileAlloc(alloc, path, 1 << 20) catch return null;
    const root = std.json.parseFromSliceLeaky(std.json.Value, alloc, data, .{}) catch return null;
    if (root != .object) return null;
    const parts = root.object.get("parts") orelse return null;
    if (parts != .array) return null;
    var list: std.ArrayListUnmanaged(optimizer.RefPose) = .empty;
    for (parts.array.items) |it| {
        if (it != .object) continue;
        const ref = it.object.get("ref") orelse continue;
        if (ref != .string) continue;
        list.append(alloc, .{
            .ref = ref.string,
            .x = jsonNum(it.object.get("x")),
            .y = jsonNum(it.object.get("y")),
            .rot = jsonNum(it.object.get("rot")),
        }) catch return null;
    }
    return list.toOwnedSlice(alloc) catch null;
}

/// One placed part exported to the KiCad sync: centre (mm) + rotation (deg,
/// CCW). The sync stamps these onto a footprint it inserts for the first time.
pub const SyncPose = struct { x: f64, y: f64, rot: f64 };

/// Re-export so the KiCad sync can name a module's poses (`loadSubBlockPoses`)
/// without importing the placement layer directly.
pub const RefPose = optimizer.RefPose;

/// Choose the part poses the KiCad sync seeds first-insertion placement (and
/// GND vias) from, as `RefPose`s, or null when the design has no layout at all.
/// Preference: the user-marked **default** layout first, then the newest manual
/// snapshot, then the most recent recorded layout of any kind, then the raw
/// `.autolayout.json` optimizer cache. Both `loadSyncLayout` (placement) and
/// `loadSyncVias` (vias) go through this so the vias correspond to exactly the
/// poses the parts land at. Result lives on `alloc` (request lifetime).
fn chooseSyncPoses(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8) ?[]const optimizer.RefPose {
    const layouts = readLayouts(alloc, project_dir, name);
    const chosen: ?[]const PartPose = blk: {
        for (layouts) |L| {
            if (L.default and L.parts.len > 0) break :blk L.parts;
        }
        for (layouts) |L| {
            if (std.mem.eql(u8, L.kind, KIND_MANUAL) and L.parts.len > 0) break :blk L.parts;
        }
        for (layouts) |L| {
            if (L.parts.len > 0) break :blk L.parts;
        }
        break :blk null;
    };
    if (chosen) |parts| {
        const out = alloc.alloc(optimizer.RefPose, parts.len) catch return null;
        for (parts, 0..) |pt, i| out[i] = .{ .ref = pt.ref, .x = pt.x, .y = pt.y, .rot = pt.rot };
        return out;
    }
    // No named/recorded layouts — fall back to the bare optimizer cache.
    const poses = readAutoPoses(alloc, project_dir, name) orelse return null;
    if (poses.len == 0) return null;
    return poses;
}

/// Load the design's premade placement-tool layout for the KiCad sync's
/// first-insertion path, as a ref-des → pose map (mm + degrees), or null when
/// the design has no saved layout at all. The layout is picked by
/// `chooseSyncPoses` (default → manual → any → optimizer cache). The returned
/// map and its keys live on `alloc` (request lifetime). Only positions are
/// exported here — the GND vias are computed separately by `loadSyncVias`.
pub fn loadSyncLayout(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
) ?std.StringHashMap(SyncPose) {
    const poses = chooseSyncPoses(alloc, project_dir, name) orelse return null;
    var m = std.StringHashMap(SyncPose).init(alloc);
    for (poses) |p| m.put(p.ref, .{ .x = p.x, .y = p.y, .rot = p.rot }) catch return m;
    return m;
}

/// One GND-plane stitching via exported to the KiCad sync: centre (mm), pad +
/// hole diameter (mm), and the net name it stitches down to the plane. Saved
/// layouts store only positions, so the vias are *computed* at sync time.
pub const SyncVia = struct { x: f64, y: f64, dia: f64, drill: f64, net: []const u8 };

/// Map a saved layout's poses onto stable `origin_key`, via the *design* named
/// `source` — the one `/pcb-layout/<source>` flattened to produce the layout.
/// The layout's ref-des keys carry that design's wrapper prefix (e.g. the
/// `tpsm84338` eval wraps the module in a `pwr` sub-block → `pwr/U2`), so
/// re-flattening the same design reproduces those refs exactly; each maps to the
/// module-local `origin_key` (stable across renumbering and across boards). A
/// bare-ref alias is also indexed so a layout saved without the wrapper still
/// bridges. Null on any resolution failure (caller falls back to the raw layout).
fn poseByOriginKey(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    source: []const u8,
    layout: []const optimizer.RefPose,
) ?std.StringHashMap(SyncPose) {
    const path = paths.designSourcePath(alloc, project_dir, source) catch return null;
    defer alloc.free(path);
    const eval = alloc.create(Evaluator) catch return null;
    defer {
        eval.deinit();
        alloc.destroy(eval);
    }
    eval.* = Evaluator.init(alloc, project_dir);
    const result = eval.evalFile(path) catch return null;
    const dblock = switch (result) {
        .design_block => |b| b,
        else => return null,
    };
    var flat: std.ArrayListUnmanaged(export_kicad.FlatInstance) = .empty;
    netlist.collectInstances(alloc, dblock, "", &flat) catch return null;
    var ok_of = std.StringHashMap([]const u8).init(alloc);
    for (flat.items) |fi| {
        ok_of.put(fi.ref_des, fi.origin_key) catch return null;
        if (std.mem.lastIndexOfScalar(u8, fi.ref_des, '/')) |slash| {
            ok_of.put(fi.ref_des[slash + 1 ..], fi.origin_key) catch return null;
        }
    }
    var pose_by_ok = std.StringHashMap(SyncPose).init(alloc);
    for (layout) |p| {
        const ok = ok_of.get(p.ref) orelse continue;
        if (ok.len == 0) continue;
        // `ok` borrows the eval's arena (freed on the defer) — dupe it.
        const key = alloc.dupe(u8, ok) catch return null;
        pose_by_ok.put(key, .{ .x = p.x, .y = p.y, .rot = p.rot }) catch return null;
    }
    return pose_by_ok;
}

/// A sub-module's default layout re-keyed onto **`sub_block`'s own flattened
/// ref-des**, bridged by stable `origin_key`. A module's saved layout is keyed
/// by the ref-des of whatever design `/pcb-layout/<module>` rendered when it was
/// saved (e.g. the `tpsm84338` eval wraps the module in a `pwr` sub-block →
/// `pwr/U2`). The *same* part inside another board flattens differently
/// (`buck_3v3d/U11`) — different wrapper AND renumbering — so a prefix-strip
/// can't bridge them. This resolves the module to map its layout refs →
/// `origin_key`, then re-keys the poses onto `sub_block.block`'s flattened refs
/// by matching `origin_key` (the module-local identity, stable across both).
/// Falls back to the raw layout (caller prefix-strips) when the module can't be
/// resolved or nothing bridges. Result lives on `alloc` (request lifetime).
pub fn loadSubBlockPoses(alloc: std.mem.Allocator, project_dir: []const u8, sub_block: env_mod.SubBlock) ?[]const optimizer.RefPose {
    const layout = chooseSyncPoses(alloc, project_dir, sub_block.source) orelse return null;

    // origin_key → pose, via the design that produced the layout (see helper).
    const pose_by_ok = poseByOriginKey(alloc, project_dir, sub_block.source, layout) orelse return layout;

    // Re-key onto sub_block's own flattened refs by origin_key.
    var flat2: std.ArrayListUnmanaged(export_kicad.FlatInstance) = .empty;
    netlist.collectInstances(alloc, sub_block.block, "", &flat2) catch return layout;
    var out: std.ArrayListUnmanaged(optimizer.RefPose) = .empty;
    for (flat2.items) |fi| {
        if (fi.origin_key.len == 0) continue;
        const pose = pose_by_ok.get(fi.origin_key) orelse continue;
        out.append(alloc, .{ .ref = fi.ref_des, .x = pose.x, .y = pose.y, .rot = pose.rot }) catch return layout;
    }
    if (out.items.len == 0) return layout; // nothing bridged — let the caller prefix-strip
    return out.toOwnedSlice(alloc) catch layout;
}

/// The GND vias for a placement at exactly `poses` (built from `block`): run the
/// router's ground-via pass — the same DRC-safe pass the layout page previews —
/// in `block`'s local coordinate frame. Net names come from the placement's
/// flattened nets; via size/drill use the router's proto-fab defaults. Returns
/// null when the placement can't be built or the board is too large to grid (no
/// vias). Used both for a whole design (`loadSyncVias`) and a single sub-block
/// (the per-block seed offsets these by the block's staging origin).
pub fn viasForPoses(
    alloc: std.mem.Allocator,
    block: *const env_mod.DesignBlock,
    project_dir: []const u8,
    poses: []const optimizer.RefPose,
    params: optimizer.Params,
) ?[]const SyncVia {
    const placement = optimizer.placeFromPoses(alloc, block, project_dir, poses, params) catch return null;
    const rp = router.RouteParams{};
    const vias = router.groundVias(alloc, placement, rp) catch return null;
    if (vias.len == 0) return null;
    const out = alloc.alloc(SyncVia, vias.len) catch return null;
    for (vias, 0..) |v, i| {
        const net_name: []const u8 = if (v.net >= 0 and @as(usize, @intCast(v.net)) < placement.nets.len)
            placement.nets[@intCast(v.net)].name
        else
            "";
        out[i] = .{ .x = v.x, .y = v.y, .dia = v.dia, .drill = rp.via_drill, .net = net_name };
    }
    return out;
}

/// The GND vias for the design's sync layout: pick the default-aware poses
/// (`chooseSyncPoses`) and route them (`viasForPoses`). Positions only, no
/// traces. Null when the design has no layout / the board is too large to grid.
pub fn loadSyncVias(
    alloc: std.mem.Allocator,
    block: *const env_mod.DesignBlock,
    project_dir: []const u8,
    name: []const u8,
) ?[]const SyncVia {
    const poses = chooseSyncPoses(alloc, project_dir, name) orelse return null;
    const params = readAutoParams(alloc, project_dir, name) orelse optimizer.Params{};
    return viasForPoses(alloc, block, project_dir, poses, params);
}

/// Persist the generated layout (its tuning weights + ref/x/y/rot per part) to
/// `.autolayout.json`. Best-effort: a write failure just means a regenerate.
fn writeAutoCache(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8, p: optimizer.Placement, params: optimizer.Params) void {
    const path = paths.designSiblingPath(alloc, project_dir, name, AUTO_EXT) catch return;
    defer alloc.free(path);
    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    writeCacheJson(w, p, params) catch return;
    writeFileAll(path, aw.written()) catch return;
}

/// Serialize to `{"params":{…},"parts":[{ref,x,y,rot}, …]}` — the weights so
/// the controls reflect what produced the layout, the parts for the cache.
fn writeCacheJson(w: *std.Io.Writer, p: optimizer.Placement, params: optimizer.Params) std.Io.Writer.Error!void {
    try w.print("{{\"params\":{{\"loop_w\":{d},\"w_align\":{d},\"w_congest\":{d},\"cap_w_max\":{d},\"grid\":{s},\"compact\":\"{s}\"}},", .{
        params.loop_w,                                   params.w_align,                params.w_congest, params.cap_w_max,
        if (params.grid_courtyards) "true" else "false", @tagName(params.compact_mode),
    });
    try w.writeAll(PARTS_OPEN);
    for (p.parts, 0..) |pt, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll(REF_OPEN);
        try writeJsonStr(w, pt.ref_des);
        try w.print(",\"x\":{d},\"y\":{d},\"rot\":{d}}}", .{ pt.x, pt.y, pt.rot });
    }
    try w.writeAll("]}");
}

/// Read the tuning weights stored alongside a cached layout, or null if absent.
fn readAutoParams(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8) ?optimizer.Params {
    const path = paths.designSiblingPath(alloc, project_dir, name, AUTO_EXT) catch return null;
    defer alloc.free(path);
    const data = infra_fs.cwd().readFileAlloc(alloc, path, 1 << 20) catch return null;
    const root = std.json.parseFromSliceLeaky(std.json.Value, alloc, data, .{}) catch return null;
    if (root != .object) return null;
    const po = root.object.get("params") orelse return null;
    if (po != .object) return null;
    var p = optimizer.Params{};
    if (po.object.get("loop_w")) |v| p.loop_w = jsonNum(v);
    if (po.object.get("w_align")) |v| p.w_align = jsonNum(v);
    if (po.object.get("w_congest")) |v| p.w_congest = jsonNum(v);
    if (po.object.get("cap_w_max")) |v| p.cap_w_max = jsonNum(v);
    if (po.object.get("grid")) |v| p.grid_courtyards = v == .bool and v.bool;
    if (po.object.get("compact")) |v| {
        if (v == .string) p.compact_mode = parseCompactMode(v.string);
    }
    return p;
}

/// Tuning weights parsed from the request query, plus whether any were present
/// (`tuned`) and whether a fresh solve is required (`regen` = tuned or `?regen`).
const Tuning = struct { params: optimizer.Params, tuned: bool, regen: bool };

fn parseTuning(req: *httpz.Request) Tuning {
    var p = optimizer.Params{};
    var tuned = false;
    var regen = false;
    const q = req.query() catch return .{ .params = p, .tuned = false, .regen = false };
    if (q.get("regen") != null) regen = true;
    if (q.get("loop_w")) |v| {
        p.loop_w = parseF(v, p.loop_w);
        tuned = true;
    }
    if (q.get("w_align")) |v| {
        p.w_align = parseF(v, p.w_align);
        tuned = true;
    }
    if (q.get("w_congest")) |v| {
        p.w_congest = parseF(v, p.w_congest);
        tuned = true;
    }
    if (q.get("cap_w_max")) |v| {
        p.cap_w_max = parseF(v, p.cap_w_max);
        tuned = true;
    }
    if (q.get("grid")) |v| {
        p.grid_courtyards = !(std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "false"));
        tuned = true;
    }
    if (q.get("compact")) |v| {
        p.compact_mode = parseCompactMode(v);
        tuned = true;
    }
    return .{ .params = p, .tuned = tuned, .regen = regen or tuned };
}

/// Map the `compact` query/cache string to a `CompactMode` (default `.tidiness`).
fn parseCompactMode(s: []const u8) optimizer.CompactMode {
    if (std.mem.eql(u8, s, "bbox")) return .bbox;
    if (std.mem.eql(u8, s, "protrusion")) return .protrusion;
    return .tidiness;
}

fn parseF(s: []const u8, dflt: f64) f64 {
    return std.fmt.parseFloat(f64, std.mem.trim(u8, s, " ")) catch dflt;
}

/// Routing DRC parsed from the query, and whether routing was requested
/// (`?route=1`, set by the Route button).
const RouteOpts = struct { params: router.RouteParams, run: bool };

fn parseRoute(req: *httpz.Request) RouteOpts {
    var p = router.RouteParams{};
    const q = req.query() catch return .{ .params = p, .run = false };
    if (q.get("track_width")) |v| p.track_width = parseF(v, p.track_width);
    if (q.get("clearance")) |v| p.clearance = parseF(v, p.clearance);
    if (q.get("via_drill")) |v| p.via_drill = parseF(v, p.via_drill);
    if (q.get("via_dia")) |v| p.via_dia = parseF(v, p.via_dia);
    return .{ .params = p, .run = q.get("route") != null };
}

// ── View transform ───────────────────────────────────────────────────────

const View = struct {
    scale: f64,
    minx: f64,
    miny: f64,
    width: f64,
    height: f64,

    fn init(p: optimizer.Placement) View {
        const cw = @max(p.maxx - p.minx, 1.0) + 2 * MARGIN_MM;
        const ch = @max(p.maxy - p.miny, 1.0) + 2 * MARGIN_MM;
        const s = std.math.clamp(TARGET_PX / @max(cw, ch), SCALE_MIN, SCALE_MAX);
        return .{ .scale = s, .minx = p.minx, .miny = p.miny, .width = cw * s, .height = ch * s };
    }
};

// ── Score bar + legend ───────────────────────────────────────────────────

fn writeScorebar(w: *std.Io.Writer, p: optimizer.Placement, name: []const u8) std.Io.Writer.Error!void {
    try w.writeAll("<div class=\"pcb-bar\">");
    // The weighted objective the optimizer actually minimises, then its terms.
    // All filled/updated by showScore() — server-computed, never re-derived in JS.
    try w.writeAll("<span class=\"score\" id=\"sc-obj\" title=\"weighted objective the optimizer minimizes\">objective ");
    try w.print("{d:.1}</span>", .{p.breakdown.objective});
    try w.writeAll("<span class=\"delta\" id=\"sc-obj-d\"></span>");
    try w.print("<span class=\"score sc-sub\" id=\"sc-hpwl\" title=\"signal wirelength: RSMT estimate (mm)\">wire {d:.1}</span>", .{p.breakdown.hpwl});
    try w.writeAll("<span class=\"delta\" id=\"sc-hpwl-d\"></span>");
    try w.writeAll("<span class=\"score sc-sub\" id=\"sc-loop\" title=\"weighted decoupling-loop term (loop_w × value-weighted loop length)\">loop …</span>");
    try w.writeAll("<span class=\"delta\" id=\"sc-loop-d\"></span>");
    try w.writeAll("<span class=\"score sc-sub\" id=\"sc-ind\" title=\"hot-loop connection inductance (nH) — the scored loop metric\">loop … nH</span>");
    try w.writeAll("<span class=\"delta\" id=\"sc-ind-d\"></span>");
    try w.writeAll("<span class=\"score sc-sub\" id=\"sc-align\" title=\"sub-module courtyard bounding-box area (mm²) — compactness term\">area …</span>");
    try w.writeAll("<span class=\"delta\" id=\"sc-align-d\"></span>");
    try w.writeAll("<span class=\"score sc-sub\" id=\"sc-cong\" title=\"routing congestion (w_congest × RUDY overflow)\">cong …</span>");
    try w.writeAll("<span class=\"delta\" id=\"sc-cong-d\"></span>");
    try w.writeAll("<button class=\"btn\" id=\"pcb-score\" title=\"Recompute the objective on the server for the current positions\">Score</button>");
    // Stored layout is reused on load; this re-runs the optimizer, overwrites the
    // cache, and records the result into the saved-layout history below.
    try w.writeAll("<a class=\"btn\" id=\"pcb-regen\" href=\"/pcb-layout/");
    try writeAttr(w, name);
    try w.writeAll("?regen=1\" title=\"Re-run the optimizer and watch it converge live\">Regenerate</a>");
    // Export the solved positions + full score breakdown (incl. the
    // value-weighted loop + alignment terms the bar above hides) for inspection.
    try w.writeAll("<a class=\"btn\" href=\"/api/pcb-layout/");
    try writeAttr(w, name);
    try w.writeAll("\" target=\"_blank\" title=\"Download positions + full score breakdown as JSON\">Export JSON</a>");
    try w.writeAll("<button class=\"btn\" id=\"pcb-saveas\" title=\"Save the current placement under a name\">Save as…</button>");
    try w.writeAll("<button class=\"btn\" id=\"pcb-reset\">Reset to auto</button>");
    try w.writeAll("<span class=\"zoom-grp\"><button class=\"btn\" id=\"z-out\" title=\"Zoom out\">−</button>");
    try w.writeAll("<button class=\"btn\" id=\"z-in\" title=\"Zoom in\">+</button>");
    try w.writeAll("<button class=\"btn\" id=\"z-fit\" title=\"Reset zoom\">Fit</button></span>");
    try w.writeAll("<span class=\"savemsg\" id=\"pcb-savemsg\"></span>");
    try w.writeAll("<span class=\"muted\">drag part to move · hover + R to rotate · scroll to zoom · drag background to pan · snaps to ");
    try w.print("{d} mm</span>", .{optimizer.GRID_MM});
    try w.writeAll("</div>");
}

/// Saved-layouts panel: the named history (manual snapshots + auto-recorded
/// optimizer runs), newest first, each row showing its kind, score, and delta
/// of (HPWL+loop) versus the layout currently on screen (`auto`). The Load /
/// delete buttons carry the layout name in data attributes for BOARD_JS.
fn writeLayoutsPanel(w: *std.Io.Writer, layouts: []const SavedLayout, auto: LayoutScore) std.Io.Writer.Error!void {
    try w.writeAll("<div class=\"pcb-saved\"><div class=\"saved-h\"><span>Saved layouts <span class=\"saved-n\">");
    try w.print("{d}</span></span>", .{layouts.len});
    if (layouts.len > 0) {
        try w.writeAll(
            "<button class=\"saved-rescore\" id=\"pcb-rescore\" " ++
                "title=\"Recompute every saved layout's objective with the current engine — " ++
                "use after changing the placement/scoring code to see how old layouts score now\">" ++
                "↻ Rescore all</button>",
        );
    }
    try w.writeAll("</div>");
    if (layouts.len == 0) {
        try w.writeAll("<div class=\"saved-empty\">None yet — drag parts then <b>Save as…</b>, or hit Regenerate to record one.</div></div>");
        return;
    }
    try w.writeAll("<div class=\"saved-list\">");
    for (layouts) |L| {
        // Two stacked lines so the row fits the narrow sidebar: top = kind + name +
        // auto-relative delta; bottom = ★default-toggle + score + Load/Delete.
        // `data-lay-row` keys the row for the Score-view re-weigh (reweighLayouts
        // in BOARD_JS rewrites its `.lay-score` + `.lay-d` in place — both still
        // found by querySelector). The `def` class highlights the sync default.
        try w.writeAll(if (L.default) "<div class=\"lay-row def\" data-lay-row=\"" else "<div class=\"lay-row\" data-lay-row=\"");
        try writeAttr(w, L.name);
        try w.writeAll("\"><div class=\"lay-top\"><span class=\"lay-kind ");
        try w.writeAll(if (std.mem.eql(u8, L.kind, KIND_MANUAL)) "k-man\">manual" else "k-auto\">auto");
        try w.writeAll("</span><span class=\"lay-name\">");
        try writeEscaped(w, L.name);
        try w.writeAll("</span>");
        if (L.score) |s| {
            try writeLayDelta(w, s, auto);
        } else try w.writeAll("<span class=\"lay-d\"></span>");
        try w.writeAll("</div><div class=\"lay-bot\"><span class=\"lay-score\">");
        if (L.score) |s| {
            if (s.objective > 0) try w.print("obj {d:.1} · ", .{s.objective});
            try w.print("HPWL {d:.1} · loop {d:.1}", .{ s.hpwl, s.loop });
        } else try w.writeAll("—");
        try w.writeAll("</span><span class=\"lay-actions\"><button class=\"btn lay-star");
        if (L.default) try w.writeAll(" on");
        try w.writeAll("\" data-lay-default=\"");
        try writeAttr(w, L.name);
        try w.writeAll("\" title=\"");
        try w.writeAll(if (L.default)
            "Default layout — the KiCad sync seeds new parts (placement + GND vias) from this. Click to clear."
        else
            "Make this the KiCad-sync default (seeds new parts' placement + GND vias)");
        try w.writeAll("\">");
        try w.writeAll(if (L.default) "★" else "☆");
        try w.writeAll("</button><button class=\"btn lay-go\" data-lay-load=\"");
        try writeAttr(w, L.name);
        try w.writeAll("\">Load</button><button class=\"btn lay-del\" title=\"Delete\" data-lay-del=\"");
        try writeAttr(w, L.name);
        try w.writeAll("\">✕</button></span></div></div>");
    }
    try w.writeAll("</div></div>");
}

/// Delta of a saved layout's cost versus the on-screen auto baseline, on the
/// weighted objective when both have one (legacy entries with no objective fall
/// back to the combined HPWL+loop). Positive (red) = worse, negative (green) =
/// better — matching the live score-bar deltas.
fn writeLayDelta(w: *std.Io.Writer, s: LayoutScore, auto: LayoutScore) std.Io.Writer.Error!void {
    const d = if (s.objective > 0 and auto.objective > 0)
        s.objective - auto.objective
    else
        (s.hpwl + s.loop) - (auto.hpwl + auto.loop);
    if (@abs(d) < 0.05) {
        try w.writeAll("<span class=\"lay-d\">=</span>");
        return;
    }
    try w.print("<span class=\"lay-d {s}\">{s}{d:.1}</span>", .{
        if (d > 0) "up" else "down",
        if (d > 0) "+" else "",
        d,
    });
}

/// Tuning panel: number inputs for the steering weights + a grid toggle and an
/// Apply button (wired in BOARD_JS to reload with the values as query params,
/// which forces a regenerate). Values reflect the weights behind the layout.
fn writeTuning(w: *std.Io.Writer, params: optimizer.Params) std.Io.Writer.Error!void {
    const sel = struct {
        fn s(active: bool) []const u8 {
            return if (active) " selected" else "";
        }
    }.s;
    const m = params.compact_mode;
    try w.writeAll("<div class=\"pcb-tune\"><span class=\"tune-h\">Tuning</span>");
    try w.print("<label title=\"placement regularizer\">Compact <select id=\"t-compact\">" ++
        "<option value=\"tidiness\"{s}>tidiness (row/col)</option>" ++
        "<option value=\"bbox\"{s}>bbox area</option>" ++
        "<option value=\"protrusion\"{s}>protrusion</option></select></label>", .{
        sel(m == .tidiness), sel(m == .bbox), sel(m == .protrusion),
    });
    try w.print("<label>Compact w <input id=\"t-align\" type=\"number\" step=\"0.05\" min=\"0\" value=\"{d}\"></label>", .{params.w_align});
    try w.print("<label>Loop <input id=\"t-loop\" type=\"number\" step=\"0.5\" min=\"0\" value=\"{d}\"></label>", .{params.loop_w});
    try w.print("<label>Congest <input id=\"t-cong\" type=\"number\" step=\"0.5\" min=\"0\" value=\"{d}\"></label>", .{params.w_congest});
    try w.writeAll("<label class=\"tune-chk\"><input id=\"t-grid\" type=\"checkbox\"");
    if (params.grid_courtyards) try w.writeAll(CHECKED);
    try w.writeAll("> Grid edges</label>");
    try w.writeAll("<button class=\"btn\" id=\"t-apply\">Apply &amp; regenerate</button>");
    try w.writeAll("<span class=\"muted\">re-runs the optimizer with these weights</span></div>");
}

/// Score-view panel: per-metric enable toggles + display weights that recompute
/// the headline objective *in the browser* from the breakdown's stored raw terms
/// — no re-placement, no server round-trip. Lets you re-weigh or drop each metric
/// to see how it moves the total (e.g. disable Wire + Align + Congest to compare
/// two layouts on pure hot-loop inductance). Defaults mirror the engine weights,
/// so the headline matches the optimizer's objective until you change something.
fn writeScoreView(w: *std.Io.Writer, params: optimizer.Params) std.Io.Writer.Error!void {
    try w.writeAll("<div class=\"pcb-tune pcb-scoreview\"><span class=\"tune-h\">Score view</span>");
    try svRow(w, "wire", "Wire", 1.0);
    try svRow(w, "loop", "Loop", params.loop_w);
    try svRow(w, "align", "Compact", params.w_align);
    try svRow(w, "cong", "Congest", params.w_congest);
    try w.writeAll("<button class=\"btn\" id=\"sv-reset\" title=\"Restore engine weights, all metrics enabled\">Reset</button>");
    try w.writeAll("<span class=\"muted\">recomputes the headline — doesn't move parts</span></div>");
}

/// One score-view metric row: an enable checkbox (the metric drops out of the
/// objective entirely when cleared) plus its display weight input.
fn svRow(w: *std.Io.Writer, key: []const u8, label: []const u8, weight: f64) std.Io.Writer.Error!void {
    try w.print(
        "<span class=\"sv-row\"><label class=\"tune-chk\"><input id=\"sv-en-{s}\" type=\"checkbox\" checked> {s}</label>" ++
            "<label class=\"sv-wl\">×<input id=\"sv-w-{s}\" type=\"number\" step=\"0.1\" min=\"0\" value=\"{d}\"></label></span>",
        .{ key, label, key, weight },
    );
}

/// Routing panel: DRC inputs (mm) + a Route button (wired in BOARD_JS to
/// reload with `?route=1&…`). Shows the routed/total tally + DRC result.
fn writeRoutePanel(w: *std.Io.Writer, params: router.RouteParams, routed: ?router.RouteResult, n_drc: usize, n_rp: usize) std.Io.Writer.Error!void {
    try w.writeAll("<div class=\"pcb-route\"><span class=\"tune-h\">Route</span>");
    try w.print("<label>Track <input id=\"r-tw\" type=\"number\" step=\"0.05\" min=\"0.05\" value=\"{d}\"></label>", .{params.track_width});
    try w.print("<label>Clearance <input id=\"r-cl\" type=\"number\" step=\"0.05\" min=\"0.05\" value=\"{d}\"></label>", .{params.clearance});
    try w.print("<label>Via drill <input id=\"r-vd\" type=\"number\" step=\"0.05\" min=\"0.1\" value=\"{d}\"></label>", .{params.via_drill});
    try w.print("<label>Via Ø <input id=\"r-va\" type=\"number\" step=\"0.05\" min=\"0.2\" value=\"{d}\"></label>", .{params.via_dia});
    try w.writeAll("<button class=\"btn\" id=\"r-go\">Route</button>");
    try w.writeAll("<label class=\"tune-chk\"><input id=\"r-clr-show\" type=\"checkbox\"> show clearance</label>");
    try w.writeAll("<label class=\"tune-chk\"><input id=\"r-drc-show\" type=\"checkbox\" checked> show DRC</label>");
    // Status spans, updated in place by the Route button's POST (no reload, so
    // the on-screen layout stays put); pre-filled here for a direct ?route=1 GET.
    if (routed) |r| {
        const cls = if (r.routed == r.total) "ok" else "warn";
        try w.print("<span class=\"route-stat {s}\" id=\"r-stat\">routed {d}/{d} nets · {d} vias</span>", .{ cls, r.routed, r.total, r.vias.len });
        if (n_drc == 0) {
            try w.writeAll("<span class=\"route-stat ok\" id=\"r-drc\">DRC clean ✓</span>");
        } else {
            try w.print("<span class=\"route-stat err\" id=\"r-drc\">{d} DRC violation(s)</span>", .{n_drc});
        }
        if (n_rp == 0) {
            try w.writeAll("<span class=\"route-stat ok\" id=\"r-rp\">return paths ✓</span>");
        } else {
            try w.print("<span class=\"route-stat warn\" id=\"r-rp\">{d} return-path warning(s)</span>", .{n_rp});
        }
    } else {
        try w.writeAll("<span class=\"route-stat\" id=\"r-stat\"></span>");
        try w.writeAll("<span class=\"route-stat\" id=\"r-drc\"></span>");
        try w.writeAll("<span class=\"route-stat\" id=\"r-rp\"></span>");
        try w.writeAll("<span class=\"muted\" id=\"r-hint\">4-layer: top/GND/PWR/bottom · GND→plane vias</span>");
    }
    try w.writeAll("</div>");
}

/// Compact, read-only score line for the embedded per-sub-block preview. Holds
/// the same `sc-*` spans BOARD_JS's showScore() fills (deltas read "=" since the
/// baseline is the layout itself) plus the zoom group — no edit buttons.
fn writeEmbedBar(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll("<div class=\"pcb-bar\">");
    try w.writeAll("<span class=\"score\" id=\"sc-obj\">objective …</span><span class=\"delta\" id=\"sc-obj-d\"></span>");
    try w.writeAll("<span class=\"score sc-sub\" id=\"sc-hpwl\">HPWL …</span><span class=\"delta\" id=\"sc-hpwl-d\"></span>");
    try w.writeAll("<span class=\"score sc-sub\" id=\"sc-loop\">loop …</span><span class=\"delta\" id=\"sc-loop-d\"></span>");
    try w.writeAll("<span class=\"score sc-sub\" id=\"sc-area\">loop area …</span><span class=\"delta\" id=\"sc-area-d\"></span>");
    try w.writeAll("<span class=\"score sc-sub\" id=\"sc-align\">area …</span><span class=\"delta\" id=\"sc-align-d\"></span>");
    try w.writeAll("<span class=\"score sc-sub\" id=\"sc-iso\">iso …</span><span class=\"delta\" id=\"sc-iso-d\"></span>");
    try w.writeAll("<span class=\"zoom-grp\"><button class=\"btn\" id=\"z-out\" title=\"Zoom out\">−</button>");
    try w.writeAll("<button class=\"btn\" id=\"z-in\" title=\"Zoom in\">+</button>");
    try w.writeAll("<button class=\"btn\" id=\"z-fit\" title=\"Reset zoom\">Fit</button></span>");
    try w.writeAll("</div>");
}

/// Read-only route status + display toggles for the embedded preview. The
/// via/track/clearance values the server routed with are emitted as hidden
/// inputs so BOARD_JS's clearance overlay + via rendering read the right
/// numbers; the only visible controls are the show-clearance / show-DRC toggles
/// (their initial state mirrors the schematic page's global checkboxes).
fn writeEmbedRoute(
    w: *std.Io.Writer,
    params: router.RouteParams,
    routed: ?router.RouteResult,
    n_drc: usize,
    show_clr: bool,
    show_drc: bool,
) std.Io.Writer.Error!void {
    try w.writeAll("<div class=\"pcb-route\">");
    try w.print("<input type=\"hidden\" id=\"r-tw\" value=\"{d}\">", .{params.track_width});
    try w.print("<input type=\"hidden\" id=\"r-cl\" value=\"{d}\">", .{params.clearance});
    try w.print("<input type=\"hidden\" id=\"r-vd\" value=\"{d}\">", .{params.via_drill});
    try w.print("<input type=\"hidden\" id=\"r-va\" value=\"{d}\">", .{params.via_dia});
    try w.print("<label class=\"tune-chk\"><input id=\"r-clr-show\" type=\"checkbox\"{s}> show clearance</label>", .{if (show_clr) CHECKED else ""});
    try w.print("<label class=\"tune-chk\"><input id=\"r-drc-show\" type=\"checkbox\"{s}> show DRC</label>", .{if (show_drc) CHECKED else ""});
    if (routed) |r| {
        const cls = if (r.routed == r.total) "ok" else "warn";
        try w.print("<span class=\"route-stat {s}\" id=\"r-stat\">routed {d}/{d} nets · {d} vias</span>", .{ cls, r.routed, r.total, r.vias.len });
        if (n_drc == 0) {
            try w.writeAll("<span class=\"route-stat ok\" id=\"r-drc\">DRC clean ✓</span>");
        } else {
            try w.print("<span class=\"route-stat err\" id=\"r-drc\">{d} DRC violation(s)</span>", .{n_drc});
        }
    } else {
        try w.writeAll("<span class=\"route-stat\" id=\"r-stat\"></span>");
        try w.writeAll("<span class=\"route-stat\" id=\"r-drc\"></span>");
    }
    try w.writeAll("</div>");
}

fn writeLegend(w: *std.Io.Writer, p: optimizer.Placement) std.Io.Writer.Error!void {
    var fallback_count: usize = 0;
    for (p.parts) |part| {
        if (part.fallback) fallback_count += 1;
    }
    try w.writeAll("<div class=\"pcb-legend\">");
    try w.writeAll("<span class=\"sw prox\"></span> power leg (L1)");
    try w.writeAll("<span class=\"sw l2gnd\"></span> GND return (images under trace, L2 plane)");
    try w.writeAll("<span class=\"sw viadot\"></span> GND via (L1↔L2, Ø from route params)");
    try w.writeAll("<span class=\"sw sig\"></span> signal");
    if (fallback_count > 0) {
        try w.print("<span class=\"note\">{d} part(s) using a placeholder box (no library footprint) — shown dashed</span>", .{fallback_count});
    }
    try w.writeAll("</div>");
}

// ── Sidebar (component → pin/net list) ───────────────────────────────────

const PinNet = struct { pin: []const u8, net: []const u8 };

fn writeSidebar(w: *std.Io.Writer, alloc: std.mem.Allocator, p: optimizer.Placement) HandlerError!void {
    var by_ref = std.StringHashMap(std.ArrayListUnmanaged(PinNet)).init(alloc);
    for (p.nets) |net| {
        for (net.pins) |pin| {
            const gop = try by_ref.getOrPut(pin.ref_des);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(alloc, .{ .pin = pin.pin, .net = net.name });
        }
    }

    try w.writeAll("<aside class=\"pcb-side\">");
    try w.print("<div class=\"side-h\">Components <span class=\"side-n\">{d}</span></div>", .{p.instances.len});
    try w.writeAll("<ul class=\"comp-list\">");
    for (p.instances) |inst| {
        try w.writeAll("<li class=\"comp\" data-ref=\"");
        try writeAttr(w, inst.ref_des);
        try w.writeAll("\"><div class=\"comp-top\"><span class=\"comp-ref\">");
        try writeEscaped(w, shortName(inst.ref_des));
        try w.writeAll("</span><span class=\"comp-val\">");
        try writeEscaped(w, instLabel(inst));
        try w.writeAll("</span></div>");
        if (inst.footprint.len > 0) {
            try w.writeAll("<button class=\"comp-fp court-edit\" data-court-ref=\"");
            try writeAttr(w, inst.ref_des);
            try w.writeAll("\" title=\"Edit footprint courtyard\">▢ ");
            try writeEscaped(w, inst.footprint);
            try w.writeAll("</button>");
        }
        if (by_ref.getPtr(inst.ref_des)) |pins| {
            std.mem.sort(PinNet, pins.items, {}, lessPin);
            try w.writeAll("<div class=\"comp-pins\">");
            for (pins.items) |pn| {
                try w.writeAll("<span class=\"pn\" data-net=\"");
                try writeAttr(w, netKey(pn.net));
                try w.writeAll("\"><b>");
                try writeEscaped(w, pn.pin);
                try w.writeAll("</b>");
                try writeEscaped(w, netLabel(pn.net));
                try w.writeAll("</span>");
            }
            try w.writeAll("</div>");
        }
        try w.writeAll("</li>");
    }
    try w.writeAll("</ul></aside>");
}

// ── Embedded board data (consumed by BOARD_JS) ───────────────────────────

const LocalPt = struct { x: f64, y: f64 };

/// World position of the GND-plane via covering the pad centred at (`cx`,`cy`),
/// or that pad centre itself when no via is near (big board / no route). The
/// loop overlay drops its GND via here so the previewed via is the DRC-safe one
/// routing will use — never a second via beside it. A via belonging to this pad
/// sits within the fan-out radius; anything past `VIA_MATCH_MM` is a neighbour's.
const VIA_MATCH_MM: f64 = 3.0;
/// Only run the pass-1 GND-via preview on boards small enough that the page
/// already pays for routed scoring (mirrors the optimizer's ROUTED_SCORE_MAX_PARTS);
/// bigger boards skip it and the overlay falls back to the pad centre.
const ROUTED_VIA_PREVIEW_MAX_PARTS: usize = 48;
/// The DRC-safe GND-via nearest `(cx,cy)` within `VIA_MATCH_MM`, or null when the
/// router placed no via there. Null is meaningful: a fat EP/thermal GND pad often
/// can't take a fanned via at all, so the overlay must *not* invent one at the raw
/// pad centre (it would sit on a neighbouring pad — e.g. the FB tap abutting the
/// thermal pad — and never match what routing actually drops).
fn dropViaPos(vias: []const router.Via, cx: f64, cy: f64) ?LocalPt {
    var best_d2: f64 = VIA_MATCH_MM * VIA_MATCH_MM;
    var found: ?LocalPt = null;
    for (vias) |vi| {
        const d2 = (vi.x - cx) * (vi.x - cx) + (vi.y - cy) * (vi.y - cy);
        if (d2 <= best_d2) {
            best_d2 = d2;
            found = .{ .x = vi.x, .y = vi.y };
        }
    }
    return found;
}

/// Emit a via drop point as `{"x":…,"y":…}`, or `null` when none exists — the
/// overlay reads null as "draw the GND return path but no via dot here".
fn writeViaDropJson(w: *std.Io.Writer, p: ?LocalPt) std.Io.Writer.Error!void {
    if (p) |q| {
        try w.print("{{\"x\":{d},\"y\":{d}}}", .{ q.x, q.y });
    } else try w.writeAll("null");
}

fn writePcbData(
    w: *std.Io.Writer,
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    p: optimizer.Placement,
    params: optimizer.Params,
    v: View,
    name: []const u8,
    layouts: []const SavedLayout,
    routed: ?router.RouteResult,
    clearance: f64,
    violations: []const drc.Violation,
    embed: bool,
) HandlerError!void {
    // ref → part index, and "ref|pin" → collapsed net (for pad tags).
    var idx = std.StringHashMap(usize).init(alloc);
    for (p.parts, 0..) |pt, i| try idx.put(pt.ref_des, i);
    // ref → footprint name (for the courtyard editor).
    var fp_of = std.StringHashMap([]const u8).init(alloc);
    for (p.instances) |inst| try fp_of.put(inst.ref_des, inst.footprint);
    var pin_net = std.StringHashMap([]const u8).init(alloc);
    for (p.nets) |net| {
        for (net.pins) |pin| {
            const key = try std.fmt.allocPrint(alloc, "{s}|{s}", .{ pin.ref_des, pin.pin });
            try pin_net.put(key, netKey(net.name));
        }
    }

    try w.writeAll("<script>const PCB=");
    try w.print("{{\"scale\":{d},\"minx\":{d},\"miny\":{d},", .{ v.scale, v.minx, v.miny });
    try w.print("\"margin\":{d},\"grid\":{d},\"w\":{d},\"h\":{d},", .{ MARGIN_MM, optimizer.GRID_MM, v.width, v.height });
    try w.print("\"clr\":{d},\"cmargin\":{d},", .{ clearance, geometry.BBOX_MARGIN_MM });
    // Read-only flag for the embedded per-sub-block preview — BOARD_JS skips all
    // edit wiring (drag/rotate/route/save) when set, leaving a pan/zoom viewer.
    try w.print("\"ro\":{s},", .{if (embed) "true" else "false"});
    // Server-computed objective breakdown of the layout on screen — the baseline
    // the live score deltas against. Same shape the /api/pcb-score endpoint returns.
    try w.print("\"caps\":{d},\"auto\":", .{p.score.loop_caps});
    try writeBreakdownJson(w, p.breakdown, params);
    try w.writeAll(",\"name\":");
    try writeJsonStr(w, name);
    try w.writeAll(",");
    try writeLayoutsJson(w, layouts);

    // Parts.
    try w.writeAll(PARTS_OPEN);
    for (p.parts, 0..) |pt, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll(REF_OPEN);
        try writeJsonStr(w, pt.ref_des);
        try w.print(",\"x\":{d},\"y\":{d},\"rot\":{d},\"hw\":{d},\"hh\":{d},\"kind\":\"{s}\",\"fb\":{s},", .{
            pt.x,                                 pt.y,  pt.rot,
            pt.hw,                                pt.hh, if (pt.kind == .hub) "hub" else "passive",
            if (pt.fallback) "true" else "false",
        });
        try w.writeAll("\"fp\":");
        try writeJsonStr(w, fp_of.get(pt.ref_des) orelse "");
        try w.writeAll(",\"pads\":[");
        for (pt.pads, 0..) |pad, j| {
            if (j > 0) try w.writeAll(",");
            try w.print("{{\"x\":{d},\"y\":{d},\"w\":{d},\"h\":{d},\"shape\":", .{ pad.x, pad.y, pad.w, pad.h });
            try writeJsonStr(w, pad.shape);
            // Custom pad: the real copper outline so the shared FP engine draws
            // the polygon, not the bounding box.
            if (pad.poly.len >= 3) {
                try w.writeAll(",\"poly\":[");
                for (pad.poly, 0..) |pp, k| {
                    if (k > 0) try w.writeAll(",");
                    try w.print("[{d},{d}]", .{ pp[0], pp[1] });
                }
                try w.writeAll("]");
            }
            const pkey = try std.fmt.allocPrint(alloc, "{s}|{s}", .{ pt.ref_des, pad.number });
            if (pin_net.get(pkey)) |nk| {
                try w.writeAll(",\"net\":");
                try writeJsonStr(w, nk);
            }
            try w.writeAll("}");
        }
        try w.writeAll("],\"silk\":{\"l\":[");
        for (pt.silk_lines, 0..) |s, j| {
            if (j > 0) try w.writeAll(",");
            try w.print("[{d},{d},{d},{d}]", .{ s.x1, s.y1, s.x2, s.y2 });
        }
        try w.writeAll("],\"c\":[");
        for (pt.silk_circles, 0..) |c, j| {
            if (j > 0) try w.writeAll(",");
            try w.print("[{d},{d},{d}]", .{ c.cx, c.cy, c.r });
        }
        try w.writeAll("]}}");
    }
    try w.writeAll("],");

    // Airwires.
    try w.writeAll("\"links\":[");
    for (p.links, 0..) |l, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{{\"a\":{d},\"ax\":{d},\"ay\":{d},", .{ l.a, l.ax, l.ay });
        try w.print("\"b\":{d},\"bx\":{d},\"by\":{d},\"k\":\"{s}\"}}", .{ l.b, l.bx, l.by, kindStr(l.kind) });
    }
    try w.writeAll("],");

    // (Single-pin breakout corridors are still reserved in the part keepout and
    // routed by the escape pass — they're no longer drawn as a 2 mm placeholder
    // hint, since the router now emits the real short-stub + via.)

    // Decoupling loops: cap power/ground pads + the hub's candidate power/
    // ground pads, plus the *pinned* hub power/ground pads (`pp`/`gp`) the score
    // actually uses — the client draws the exact scored loop (power leg, L2 ground
    // return to `gp`) from those. `cgv`/`gpv` are the DRC-safe via drop points,
    // valid for the *emitted* pose only — once a part is hand-dragged the client
    // (BOARD_JS `moved()`) recomputes the via at the live GND pad centre instead.
    //
    // The GND vias the loop overlay draws: the routed set when a route is present,
    // else `route`'s pass-1 placement on small boards — so the previewed loop via
    // is exactly the one routing will drop (no preview-via + real-via doubling),
    // and it always meets clearance. Big boards (no routed scoring) fall back to
    // the raw pad centre inside `dropViaPos`.
    const drop_vias: []const router.Via = if (routed) |r|
        r.vias
    else if (p.parts.len <= ROUTED_VIA_PREVIEW_MAX_PARTS)
        (router.groundVias(alloc, p, .{}) catch &.{})
    else
        &.{};

    try w.writeAll("\"loops\":[");
    for (p.loops, 0..) |lp, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{{\"cap\":{d},\"hub\":{d},\"cp\":", .{ lp.cap, lp.hub });
        try writePadRect(w, lp.cap_pwr);
        try w.writeAll(",\"cg\":");
        try writePadRect(w, lp.cap_gnd);
        try w.writeAll(",\"pp\":");
        try writePadRect(w, lp.hub_pwr_pin);
        try w.writeAll(",\"gp\":");
        try writePadRect(w, lp.hub_gnd_pin);
        try w.writeAll(",\"hp\":");
        try writePadRectList(w, lp.hub_pwr);
        try w.writeAll(",\"hg\":");
        try writePadRectList(w, lp.hub_gnd);
        // DRC-safe via drop points (world mm) where the L2 ground return punches to
        // the plane: the cap's GND pad and the IC's pinned GND pin.
        const cg_c = optimizer.worldPadCenter(p.parts[lp.cap], lp.cap_gnd.x, lp.cap_gnd.y);
        const gp_c = optimizer.worldPadCenter(p.parts[lp.hub], lp.hub_gnd_pin.x, lp.hub_gnd_pin.y);
        try w.writeAll(",\"cgv\":");
        try writeViaDropJson(w, dropViaPos(drop_vias, cg_c[0], cg_c[1]));
        try w.writeAll(",\"gpv\":");
        try writeViaDropJson(w, dropViaPos(drop_vias, gp_c[0], gp_c[1]));
        try w.writeAll("}");
    }
    try w.writeAll("],");

    // Signal nets (for the HPWL score) — same set the server scored.
    try w.writeAll("\"nets\":[");
    var first_net = true;
    for (p.nets) |net| {
        if (isGroundNet(net.name)) continue;
        if (!first_net) try w.writeAll(",");
        first_net = false;
        try w.writeAll("[");
        var first_pin = true;
        for (net.pins) |pin| {
            const i = idx.get(pin.ref_des) orelse continue;
            const loc = padLocalPage(p.parts[i], pin.pin);
            if (!first_pin) try w.writeAll(",");
            first_pin = false;
            try w.print("{{\"p\":{d},\"x\":{d},\"y\":{d}}}", .{ i, loc.x, loc.y });
        }
        try w.writeAll("]");
    }
    try w.writeAll("],");

    // Routed copper + DRC markers — emitted in the same shape the
    // /api/pcb-route endpoint returns so drawRoute/drawClr/drawDrc read either.
    try writeRoutedArrays(w, routed, violations);

    // Per-footprint STEP-model references (URL + KiCad offset/rotation) for the
    // 3D-view tab. Only the full page needs it; the embedded preview has no 3D
    // toggle, so it skips the (filesystem-scanning) model resolution entirely.
    try w.writeAll(",\"models\":");
    if (embed) {
        try w.writeAll("{}");
    } else {
        try writeModelsJson(w, alloc, project_dir, p.instances);
    }
    try w.writeAll("};</script>");
}

/// Emit `{ "<footprint>": {"o":[x,y,z],"r":[x,y,z]} }` for every distinct
/// footprint in the design that resolves to a STEP model — the KiCad offset/
/// rotation the 3D-view tab orients each part body with (it fetches the bytes
/// from `/api/model-file/<fp>`, keyed on the map entry). Footprints with no
/// model are omitted (the viewer shows their pads only).
fn writeModelsJson(
    w: *std.Io.Writer,
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    instances: []const export_kicad.FlatInstance,
) HandlerError!void {
    const cfg = export_kicad.loadModelConfig(alloc, project_dir);
    var seen = std.StringHashMap(void).init(alloc);
    try w.writeByte('{');
    var first = true;
    for (instances) |inst| {
        const fp = inst.footprint;
        if (fp.len == 0) continue;
        if (seen.contains(fp)) continue;
        try seen.put(fp, {});
        const tf = cfg.get(fp);
        // Resolve the STEP model the same way the KiCad export / footprint
        // viewer do: an explicit `model` override wins, else a filesystem
        // match. Skip footprints with no model — the 3D view shows pads only.
        const has_model = (if (tf) |t| t.model != null else false) or
            export_kicad_footprint.findModelFile(alloc, project_dir, fp, fp) != null;
        if (!has_model) continue;
        const off = if (tf) |t| t.offset else [3]f64{ 0, 0, 0 };
        const rot = if (tf) |t| t.rotation else [3]f64{ 0, 0, 0 };
        if (!first) try w.writeByte(',');
        first = false;
        try writeJsonStr(w, fp);
        try w.print(
            ":{{\"o\":[{d},{d},{d}],\"r\":[{d},{d},{d}]}}",
            .{ off[0], off[1], off[2], rot[0], rot[1], rot[2] },
        );
    }
    try w.writeByte('}');
}

/// Emit `"tracks":[…],"vias":[…],"drc":[…]` (world mm; track layer 0=top,
/// 1=bottom). Shared by the page's embedded PCB blob and the /api/pcb-route
/// response so both speak one routed-copper shape the client redraws from.
fn writeRoutedArrays(w: *std.Io.Writer, routed: ?router.RouteResult, violations: []const drc.Violation) std.Io.Writer.Error!void {
    try w.writeAll("\"tracks\":[");
    if (routed) |r| for (r.tracks, 0..) |t, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{{\"x1\":{d},\"y1\":{d},\"x2\":{d},\"y2\":{d},\"l\":{d},\"w\":{d}}}", .{ t.x1, t.y1, t.x2, t.y2, t.layer, t.width });
    };
    try w.writeAll("],\"vias\":[");
    if (routed) |r| for (r.vias, 0..) |vi, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{{\"x\":{d},\"y\":{d},\"d\":{d}}}", .{ vi.x, vi.y, vi.dia });
    };
    try w.writeAll("],\"drc\":[");
    for (violations, 0..) |vio, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{{\"x\":{d},\"y\":{d},\"gap\":{d},\"clr\":{d},\"k\":\"{s}\"}}", .{ vio.x, vio.y, vio.gap, vio.clearance, drcKindStr(vio.kind) });
    }
    try w.writeAll("]");
}

/// Short label for a DRC violation kind (shown in the marker tooltip).
fn drcKindStr(k: drc.Kind) []const u8 {
    return switch (k) {
        .via_pad => "via↔pad",
        .via_via => "via↔via",
        .via_track => "via↔track",
        .pad_pad => "pad↔pad",
    };
}

// ── Small helpers ────────────────────────────────────────────────────────

/// Emit `"layouts":[ … ],` — the saved-layout history for the client. Each
/// entry carries its name, kind, optional score, and `parts` as a ref → {x,y,
/// rot} map so a Load just reads positions by ref. Trailing comma included.
fn writeLayoutsJson(w: *std.Io.Writer, layouts: []const SavedLayout) std.Io.Writer.Error!void {
    try w.writeAll("\"layouts\":[");
    for (layouts, 0..) |L, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll(NAME_OPEN);
        try writeJsonStr(w, L.name);
        try w.writeAll(",\"kind\":");
        try writeJsonStr(w, L.kind);
        if (L.score) |s| {
            try w.print(",\"score\":{{\"hpwl\":{d},\"loop\":{d},\"caps\":{d},\"objective\":{d}}}", .{ s.hpwl, s.loop, s.caps, s.objective });
        } else try w.writeAll(",\"score\":null");
        try w.writeAll(",\"parts\":{");
        for (L.parts, 0..) |pt, j| {
            if (j > 0) try w.writeAll(",");
            try writeJsonStr(w, pt.ref);
            try w.print(":{{\"x\":{d},\"y\":{d},\"rot\":{d}}}", .{ pt.x, pt.y, pt.rot });
        }
        try w.writeAll("}}");
    }
    try w.writeAll("],");
}

fn padLocalPage(part: optimizer.Part, pin: []const u8) LocalPt {
    for (part.pads) |pd| {
        if (std.mem.eql(u8, pd.number, pin)) return .{ .x = pd.x, .y = pd.y };
    }
    return .{ .x = 0, .y = 0 };
}

/// Emit a pad rect as `{"x","y","w","h"}` (footprint-local mm).
fn writePadRect(w: *std.Io.Writer, pr: optimizer.PadRect) std.Io.Writer.Error!void {
    try w.print("{{\"x\":{d},\"y\":{d},\"w\":{d},\"h\":{d}}}", .{ pr.x, pr.y, pr.w, pr.h });
}

/// Emit a list of pad rects as a JSON array.
fn writePadRectList(w: *std.Io.Writer, list: []const optimizer.PadRect) std.Io.Writer.Error!void {
    try w.writeByte('[');
    for (list, 0..) |pr, i| {
        if (i > 0) try w.writeByte(',');
        try writePadRect(w, pr);
    }
    try w.writeByte(']');
}

fn kindStr(k: optimizer.RatKind) []const u8 {
    return switch (k) {
        .proximity => "proximity",
        .ground => "ground",
        .signal => "signal",
    };
}

fn instLabel(inst: anytype) []const u8 {
    if (inst.value.len > 0) return inst.value;
    for (inst.properties) |prop| {
        if (std.mem.eql(u8, prop.key, "value") and prop.value.len > 0) return prop.value;
    }
    return inst.component;
}

fn lessPin(_: void, a: PinNet, b: PinNet) bool {
    const an = std.fmt.parseInt(u32, a.pin, 10) catch null;
    const bn = std.fmt.parseInt(u32, b.pin, 10) catch null;
    if (an != null and bn != null) return an.? < bn.?;
    return std.mem.lessThan(u8, a.pin, b.pin);
}

fn shortName(s: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, s, '/')) |i| return s[i + 1 ..];
    return s;
}

/// Net grouping key — dot-collapsed to the rail, sub-block prefix kept.
fn netKey(name: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, name, '.')) |i| return name[0..i];
    return name;
}

/// Poured net name shown to the user: collapsed rail, prefix stripped.
fn netLabel(name: []const u8) []const u8 {
    return shortName(netKey(name));
}

/// Mirrors the optimizer's ground-net set, so the page's HPWL net groups
/// match the server-computed baseline exactly.
fn isGroundNet(name: []const u8) bool {
    const grounds = [_][]const u8{ "GND", "GNDA", "AGND", "PGND", "DGND", "GNDD", "VSS", "VSSA" };
    const s = shortName(name);
    for (grounds) |g| {
        if (std.mem.eql(u8, s, g)) return true;
    }
    return false;
}

fn writeEscaped(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    for (s) |c| switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        else => try w.writeByte(c),
    };
}

fn writeAttr(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    for (s) |c| switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        else => try w.writeByte(c),
    };
}

/// Emit `s` as a quoted, JSON-escaped string to a `std.Io.Writer`.
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

// ── Courtyard editor modal ───────────────────────────────────────────────

/// Hidden-by-default overlay; populated + shown by BOARD_JS when a sidebar
/// footprint button is clicked. Edits the courtyard half-extents on the grid.
const COURTYARD_MODAL =
    \\<div id="court-modal" class="court-modal" hidden><div class="court-dialog">
    \\<div class="court-h"><span id="court-title">Courtyard</span><button id="court-x" class="court-x" title="Close">×</button></div>
    \\<svg id="court-svg" class="court-svg" viewBox="0 0 260 220" xmlns="http://www.w3.org/2000/svg"></svg>
    \\<div class="court-mode" id="court-mode">
    \\<label><input type="radio" name="court-mode" value="size" checked> Overall size</label>
    \\<label><input type="radio" name="court-mode" value="offset"> Pad offset</label></div>
    \\<div class="court-fields" id="court-fields-size">
    \\<label>½-width <input id="court-hw" type="number" step="0.2" min="0"> mm</label>
    \\<label>½-height <input id="court-hh" type="number" step="0.2" min="0"> mm</label></div>
    \\<div class="court-fields" id="court-fields-offset" hidden>
    \\<label>Offset from pads <input id="court-off" type="number" step="0.05" min="0"> mm</label></div>
    \\<div id="court-full" class="court-full"></div>
    \\<div class="court-note" id="court-note">Half-extents from the part centre;
    \\ edges stay on the 0.2 mm grid. Saving rewrites the footprint file and applies to every design that uses it.</div>
    \\<div class="court-actions"><button id="court-save" class="btn">Save courtyard</button>
    \\<button id="court-cancel" class="btn">Cancel</button><span id="court-msg" class="savemsg"></span></div>
    \\</div></div>
;

// ── Styles + client renderer ─────────────────────────────────────────────

const PAGE_CSS =
    \\html,body{margin:0;background:#0d1117;color:#c9d1d9;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
    \\a{color:#58a6ff;text-decoration:none}a:hover{text-decoration:underline}
    \\.pcb-layout{display:flex;gap:16px;align-items:flex-start;max-width:1760px;margin:0 auto;padding:12px 18px}
    \\.pcb-main{flex:1;min-width:0}
    \\.pcb-note{font-size:12px;color:#d29922;background:#1d2230;border:1px solid #30363d;border-left:3px solid #d29922;
    \\  border-radius:6px;padding:6px 10px;margin:2px 0 8px}
    \\.pcb-note b{color:#f0f6fc}
    \\.pcb-head{display:flex;align-items:center;gap:12px;margin:6px 0 2px;flex-wrap:wrap}
    \\.pcb-head h1{flex:1;min-width:0}
    \\.pcb-main h1{font-size:18px;font-weight:600;margin:4px 0;color:#f0f6fc}
    \\.pcb-sub{font-size:13px;font-weight:400;color:#8b949e}
    \\.pcb-bar{display:flex;gap:10px;align-items:center;margin:8px 0;flex-wrap:wrap}
    \\.pcb-bar .score{font-weight:600;color:#e6edf3;background:#161b22;border:1px solid #21262d;border-radius:4px;padding:2px 8px}
    \\.pcb-bar .sc-sub{font-weight:500;font-size:12px;color:#8b949e;background:#0d1117}
    \\.pcb-bar .delta{font-size:12px;font-weight:600;min-width:34px}
    \\.pcb-bar .delta.up{color:#f85149}
    \\.pcb-bar .delta.down{color:#3fb950}
    \\.pcb-bar .btn{font:inherit;font-size:12px;border:1px solid #30363d;background:#21262d;border-radius:5px;
    \\  padding:3px 9px;cursor:pointer;text-decoration:none;color:#c9d1d9;display:inline-block}
    \\.pcb-bar .btn:hover{background:#30363d;border-color:#58a6ff;color:#e6edf3}
    \\.pcb-bar .btn:disabled{opacity:.45;cursor:default}
    \\.pcb-bar .zoom-grp{display:inline-flex;gap:4px}
    \\.pcb-bar .zoom-grp .btn{min-width:26px;text-align:center;padding:3px 7px}
    \\.pcb-bar .savemsg{font-size:12px;color:#3fb950;font-weight:600}
    \\.pcb-bar .muted{font-size:11.5px;color:#6e7681}
    \\.pcb-rside{width:320px;flex:none;position:sticky;top:8px;max-height:calc(100vh - 16px);overflow:auto}
    \\.pcb-saved{border:1px solid #21262d;border-radius:8px;background:#161b22;overflow:hidden}
    \\.pcb-saved .saved-h{font-size:12px;font-weight:700;color:#f0f6fc;padding:8px 10px;background:#0d1117;border-bottom:1px solid #21262d;
    \\  display:flex;align-items:center;justify-content:space-between;gap:8px}
    \\.saved-rescore{font:inherit;font-size:11px;font-weight:600;border:1px solid #30363d;background:#21262d;color:#c9d1d9;
    \\  border-radius:5px;padding:2px 9px;cursor:pointer}
    \\.saved-rescore:hover{background:#30363d;border-color:#58a6ff;color:#e6edf3}
    \\.saved-rescore:disabled{opacity:.5;cursor:default}
    \\.pcb-saved .saved-n{color:#8b949e;font-weight:400}
    \\.pcb-saved .saved-empty{font-size:12px;color:#8b949e;padding:10px;line-height:1.5}
    \\.saved-list{display:flex;flex-direction:column}
    \\.lay-row{display:flex;flex-direction:column;gap:5px;padding:8px 10px;border-bottom:1px solid #21262d;font-size:12px}
    \\.lay-row:last-child{border-bottom:0}
    \\.lay-top{display:flex;gap:6px;align-items:center}
    \\.lay-bot{display:flex;gap:8px;align-items:center;justify-content:space-between}
    \\.lay-kind{font-size:9.5px;font-weight:700;border-radius:3px;padding:1px 5px;letter-spacing:.03em;flex:none}
    \\.lay-kind.k-man{background:#14365c;color:#79c0ff}
    \\.lay-kind.k-auto{background:#21262d;color:#8b949e}
    \\.lay-name{font-weight:600;color:#e6edf3;flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
    \\.lay-score{color:#8b949e;font-size:11px;flex:1;min-width:0}
    \\.lay-d{font-weight:600;min-width:36px;text-align:right;flex:none}
    \\.lay-d.up{color:#f85149}
    \\.lay-d.down{color:#3fb950}
    \\.lay-actions{display:flex;gap:6px;flex:none}
    \\.lay-row .btn{font:inherit;font-size:11px;border:1px solid #30363d;background:#21262d;border-radius:5px;padding:2px 8px;cursor:pointer;color:#c9d1d9}
    \\.lay-row .btn:hover{background:#30363d;border-color:#58a6ff;color:#e6edf3}
    \\.lay-row .lay-del{color:#f85149;border-color:#5b1e28;padding:2px 7px}
    \\.lay-row .lay-del:hover{background:#30363d;border-color:#f85149;color:#ffa198}
    \\.lay-row .lay-star{color:#8b949e;padding:2px 7px;line-height:1}
    \\.lay-row .lay-star:hover{color:#e3b341;border-color:#e3b341}
    \\.lay-row .lay-star.on{color:#e3b341;border-color:#7a5c12;background:#2b2410}
    \\.lay-row.def{background:#13210f;box-shadow:inset 2px 0 0 #e3b341}
    \\.pcb-tune{display:flex;gap:10px;align-items:center;margin:2px 0 8px;flex-wrap:wrap;font-size:12px;color:#8b949e}
    \\.pcb-tune .tune-h{font-weight:700;color:#f0f6fc}
    \\.pcb-tune label{display:flex;gap:4px;align-items:center}
    \\.pcb-tune input[type=number]{width:54px;font:inherit;font-size:12px;border:1px solid #30363d;
    \\  background:#0d1117;color:#c9d1d9;border-radius:4px;padding:2px 4px}
    \\.pcb-tune .muted{font-size:11px;color:#6e7681}
    \\.pcb-scoreview .sv-row{display:flex;gap:3px;align-items:center}
    \\.pcb-scoreview .sv-wl{gap:1px}
    \\.pcb-scoreview input[type=number]{width:44px}
    \\.pcb-bar .sc-off{opacity:.35;text-decoration:line-through}
    \\.pcb-route{display:flex;gap:10px;align-items:center;margin:2px 0 8px;flex-wrap:wrap;font-size:12px;color:#8b949e}
    \\.pcb-route .tune-h{font-weight:700;color:#f0f6fc}
    \\.pcb-route label{display:flex;gap:4px;align-items:center}
    \\.pcb-route input[type=number]{width:54px;font:inherit;font-size:12px;border:1px solid #30363d;
    \\  background:#0d1117;color:#c9d1d9;border-radius:4px;padding:2px 4px}
    \\.pcb-route .muted{font-size:11px;color:#6e7681}
    \\.pcb-route .route-stat{font-weight:600}
    \\.pcb-route .route-stat.ok{color:#3fb950}
    \\.pcb-route .route-stat.warn{color:#f85149}
    \\.pcb-route .route-stat.err{color:#fff;background:#da3633;border-radius:4px;padding:1px 7px}
    \\.pcb-legend{display:flex;gap:14px;align-items:center;font-size:12px;color:#8b949e;margin:4px 0 12px;flex-wrap:wrap}
    \\.pcb-legend .sw{display:inline-block;width:18px;height:0;border-top-width:3px;border-top-style:solid;vertical-align:middle}
    \\.pcb-legend .sw.prox{border-color:#ea580c}
    \\.pcb-legend .sw.gnd{border-color:#22b8cf}
    \\.pcb-legend .sw.l2gnd{border-color:#58a6ff;border-top-style:dashed}
    \\.pcb-legend .sw.viadot{border:0;height:9px;width:9px;border-radius:50%;background:radial-gradient(circle,#fff 0 1.5px,#ca8a04 1.5px)}
    \\.pcb-legend .sw.sig{border-color:#9aa7b4}
    \\.pcb-legend .note{color:#d29922}
    \\.pcb-svg{background:#010409;border:1px solid #30363d;border-radius:8px;max-width:100%;height:auto;touch-action:none}
    \\.pcb-ref{font:600 9px system-ui,sans-serif;text-anchor:middle;pointer-events:none;user-select:none}
    \\.part{cursor:grab}
    \\.part .court{transition:filter .08s}
    \\.part.hl .court{filter:drop-shadow(0 0 3px rgba(88,166,255,.75))}
    \\.pad{transition:fill .08s}
    \\.pad.net-hl{fill:#f85149}
    \\.pn.net-hl{background:#5b1e28;color:#ffa198}
    \\.pcb-side{width:288px;flex:none;position:sticky;top:8px;max-height:calc(100vh - 16px);
    \\  overflow:auto;border:1px solid #21262d;border-radius:8px;background:#161b22}
    \\.side-h{font-size:13px;font-weight:600;padding:10px 12px;border-bottom:1px solid #21262d;position:sticky;top:0;background:#161b22;color:#f0f6fc}
    \\.side-n{color:#8b949e;font-weight:400}
    \\.comp-list{list-style:none;margin:0;padding:0}
    \\.comp{padding:8px 12px;border-bottom:1px solid #21262d;cursor:default}
    \\.comp.hl{background:#1c2230}
    \\.comp.sel{background:#1f2937;box-shadow:inset 3px 0 0 #58a6ff;animation:compflash .7s ease-out}
    \\@keyframes compflash{from{background:#2d3b52}to{background:#1f2937}}
    \\.comp-top{display:flex;gap:8px;align-items:baseline}
    \\.comp-ref{font-weight:600;font-size:13px;color:#e6edf3}
    \\.comp-val{font-size:12px;color:#8b949e;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
    \\.comp-fp{font-size:10.5px;color:#6e7681;margin:1px 0 4px}
    \\.comp-fp.court-edit{display:block;width:100%;text-align:left;background:none;border:0;padding:1px 0 4px;
    \\  cursor:pointer;font-family:inherit}
    \\.comp-fp.court-edit:hover{color:#58a6ff;text-decoration:underline}
    \\.comp-pins{display:flex;flex-wrap:wrap;gap:3px 5px}
    \\.pn{font-size:11px;color:#c9d1d9;background:#21262d;border-radius:3px;padding:0 5px;white-space:nowrap}
    \\.pn b{color:#e6edf3;font-weight:600;margin-right:3px}
    \\.court-modal{position:fixed;inset:0;background:rgba(1,4,9,0.7);display:flex;
    \\  align-items:center;justify-content:center;z-index:200}
    \\.court-modal[hidden]{display:none}
    \\.court-dialog{background:#161b22;border:1px solid #30363d;color:#c9d1d9;border-radius:10px;padding:16px 18px;width:320px;
    \\  box-shadow:0 12px 40px rgba(0,0,0,0.5);font-family:system-ui,sans-serif}
    \\.court-h{display:flex;align-items:center;justify-content:space-between;font-weight:600;
    \\  color:#f0f6fc;font-size:14px;margin-bottom:8px}
    \\.court-x{border:0;background:none;font-size:20px;line-height:1;cursor:pointer;color:#8b949e}
    \\.court-svg{width:100%;height:200px;background:#010409;border-radius:6px;display:block}
    \\.court-mode{display:flex;gap:14px;align-items:center;margin:10px 0 4px;font-size:12px;color:#c9d1d9}
    \\.court-mode label{display:flex;gap:4px;align-items:center;cursor:pointer}
    \\.court-fields{display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin:4px 0 4px;font-size:12px;color:#c9d1d9}
    \\.court-fields[hidden]{display:none}
    \\.court-fields input{width:64px;font:inherit;background:#0d1117;border:1px solid #30363d;color:#c9d1d9;border-radius:4px;padding:2px 4px}
    \\.court-full{color:#8b949e;font-size:12px;margin:2px 0 8px}
    \\.court-note{font-size:11px;color:#6e7681;line-height:1.4;margin-bottom:10px}
    \\.court-actions{display:flex;gap:8px;align-items:center}
    \\.court-dialog .btn{font:inherit;font-size:12px;border:1px solid #30363d;background:#21262d;
    \\  border-radius:5px;padding:4px 11px;cursor:pointer;color:#c9d1d9}
    \\.court-dialog .btn:hover{background:#30363d;border-color:#58a6ff;color:#e6edf3}
    \\.court-dialog .btn:disabled{opacity:.45;cursor:default}
    \\.pcb-3d-stage{display:none;position:relative;width:100%;height:calc(100vh - 150px);min-height:460px;
    \\  background:#010409;border:1px solid #30363d;border-radius:8px;overflow:hidden}
    \\body.mode-3d .pcb-3d-stage{display:block}
    \\.pcb-3d-stage canvas{display:block;width:100%;height:100%;touch-action:none}
    \\#pcb-3d-status{position:absolute;top:50%;left:50%;transform:translate(-50%,-50%);color:#8b949e;
    \\  font-size:13px;background:rgba(13,17,23,.8);padding:6px 12px;border-radius:6px}
    \\#pcb-3d-status.err{color:#f85149}
    \\.pcb-3d-tools{position:absolute;top:10px;right:10px;display:flex;gap:6px;align-items:center;flex-wrap:wrap;
    \\  background:rgba(22,27,34,.85);border:1px solid #30363d;border-radius:6px;padding:5px 8px;font-size:12px;color:#8b949e}
    \\.pcb-3d-tools .btn{font:inherit;font-size:12px;border:1px solid #30363d;background:#21262d;border-radius:5px;
    \\  padding:3px 9px;cursor:pointer;color:#c9d1d9}
    \\.pcb-3d-tools .btn:hover{background:#30363d;border-color:#58a6ff;color:#e6edf3}
    \\.pcb-3d-tools label{display:flex;gap:3px;align-items:center;cursor:pointer}
    \\.pcb-3d-tools .sep{width:1px;height:16px;background:#30363d}
    \\body.mode-3d .pcb-svg,body.mode-3d .pcb-tune,body.mode-3d .pcb-route,
    \\body.mode-3d .pcb-legend,body.mode-3d .pcb-note,body.mode-3d .pcb-bar{display:none}
    \\/* Live-regen status card — floats over the top of the board (pointer-events
    \\   off) so the optimizer's best-so-far arrangement stays fully visible and
    \\   animating underneath while it converges. */
    \\.pcb-live{position:fixed;top:68px;left:50%;transform:translateX(-50%);z-index:300;pointer-events:none}
    \\.pcb-live-card{display:flex;align-items:center;gap:10px;background:rgba(13,17,23,.92);
    \\  border:1px solid #30363d;border-radius:9px;padding:9px 15px;box-shadow:0 4px 18px rgba(0,0,0,.45);
    \\  font-size:13px;color:#e6edf3;max-width:90vw}
    \\.pcb-live-spin{width:15px;height:15px;border:2px solid #30363d;border-top-color:#58a6ff;
    \\  border-radius:50%;animation:pcb-live-rot .8s linear infinite;flex:0 0 auto}
    \\.pcb-live.err .pcb-live-spin{border-top-color:#f85149;animation:none}
    \\.pcb-live.done .pcb-live-spin{border-top-color:#3fb950;animation:none}
    \\.pcb-live-msg{font-weight:600}
    \\.pcb-live-sub{color:#8b949e;font-size:12px;font-variant-numeric:tabular-nums}
    \\@keyframes pcb-live-rot{to{transform:rotate(360deg)}}
;

/// Extra rules layered on top of PAGE_CSS only when `?embed=1` — the body gets
/// the `embed` class. Strips outer padding, lets the board fill the frame
/// width, and drops the grab cursor (no dragging in the read-only preview).
const EMBED_CSS =
    \\body.embed .pcb-layout{padding:8px 10px;max-width:none}
    \\body.embed .pcb-bar{margin:4px 0}
    \\body.embed .pcb-route{margin:2px 0 6px}
    \\body.embed .pcb-svg{width:100%}
    \\body.embed .part{cursor:default}
;

/// The (hidden) WebGL stage for the 3D-view tab: a canvas, a status overlay,
/// and a floating toolbar (camera presets + layer toggles). CSS `.mode-3d`
/// reveals it and hides the 2D board; `pcb_3d_viewer.js` builds the scene.
const PCB_3D_STAGE_HTML =
    \\<div class="pcb-3d-stage" id="pcb-3d-stage">
    \\<canvas id="pcb-3d-canvas"></canvas>
    \\<div id="pcb-3d-status">Loading 3D view…</div>
    \\<div class="pcb-3d-tools">
    \\<button class="btn" id="pcb3d-iso">Iso</button>
    \\<button class="btn" id="pcb3d-top">Top</button>
    \\<button class="btn" id="pcb3d-front">Front</button>
    \\<button class="btn" id="pcb3d-side">Side</button>
    \\<span class="sep"></span>
    \\<label><input type="checkbox" id="pcb3d-t-models" checked>Models</label>
    \\<label><input type="checkbox" id="pcb3d-t-pads" checked>Pads</label>
    \\<label><input type="checkbox" id="pcb3d-t-board" checked>Board</label>
    \\<label><input type="checkbox" id="pcb3d-t-axes" checked>Axes</label>
    \\</div></div>
;

/// Tab wiring for the Schematic ⇄ PCB Layout ⇄ 3D View switcher. Toggling to
/// 3D adds `.mode-3d` (CSS swaps in the stage), then lazily injects the WebGL
/// stack (Three.js + OrbitControls + occt-import-js) and our viewer before
/// calling `PCB3D.init()` — so the heavy assets load only when 3D is opened.
/// The PCB Layout tab flips back to 2D in place (no reload) when 3D is active.
const PCB_3D_TOGGLE_JS =
    \\<script>(function(){
    \\var tab3d=document.getElementById("pcb-tab-3d"),tab2d=document.getElementById("pcb-tab-2d");
    \\if(!tab3d||!tab2d)return;
    \\var loaded=false,loading=null;
    \\function loadScript(src){return new Promise(function(res,rej){
    \\ var s=document.createElement("script");s.src=src;s.onload=res;
    \\ s.onerror=function(){rej(new Error("load "+src));};document.head.appendChild(s);});}
    \\function ensure(){
    \\ if(loaded)return Promise.resolve();
    \\ if(loading)return loading;
    \\ var seq=Promise.resolve();
    \\ ["/static/three.min.js","/static/OrbitControls.js","/static/occt-import-js.js","/static/pcb_3d_viewer.js"]
    \\  .forEach(function(u){seq=seq.then(function(){return loadScript(u);});});
    \\ loading=seq.then(function(){loaded=true;});
    \\ return loading;}
    \\function show3d(){
    \\ document.body.classList.add("mode-3d");
    \\ tab3d.classList.add("active");tab2d.classList.remove("active");
    \\ ensure().then(function(){
    \\  if(window.PCB3D){window.PCB3D.init();
    \\   requestAnimationFrame(function(){window.PCB3D.onShow();});}
    \\ }).catch(function(e){console.error(e);
    \\  var st=document.getElementById("pcb-3d-status");
    \\  if(st){st.textContent="3D assets failed to load";st.className="err";}});}
    \\function show2d(){
    \\ document.body.classList.remove("mode-3d");
    \\ tab2d.classList.add("active");tab3d.classList.remove("active");}
    \\tab3d.addEventListener("click",function(e){e.preventDefault();show3d();});
    \\tab2d.addEventListener("click",function(e){
    \\ if(document.body.classList.contains("mode-3d")){e.preventDefault();show2d();}});
    \\})();</script>
;

const BOARD_JS =
    \\<script>(function(){
    \\const NS="http://www.w3.org/2000/svg";
    \\const S=PCB.scale,MX=PCB.minx,MY=PCB.miny,M=PCB.margin,G=PCB.grid;
    \\const P=PCB.parts, orig=P.map(function(p){return {x:p.x,y:p.y,rot:p.rot||0};});
    \\var RO=!!PCB.ro;
    \\const X=function(mm){return (mm-MX+M)*S;}, Y=function(mm){return (mm-MY+M)*S;};
    \\const svg=document.getElementById("pcb-svg");
    \\const gP=document.createElementNS(NS,"g"), gR=document.createElementNS(NS,"g");
    \\const gT=document.createElementNS(NS,"g"), gC=document.createElementNS(NS,"g"), gD=document.createElementNS(NS,"g");
    \\svg.appendChild(gP); svg.appendChild(gC); svg.appendChild(gT); svg.appendChild(gR); svg.appendChild(gD);
    \\gT.style.pointerEvents="none"; gR.style.pointerEvents="none"; gC.style.pointerEvents="none"; gD.style.pointerEvents="none";
    \\const els=[], bodies=[];
    \\function el(n,a){var e=document.createElementNS(NS,n);for(var k in a)e.setAttribute(k,a[k]);return e;}
    \\function wpt(i,lx,ly){var p=P[i],a=(p.rot||0)*Math.PI/180,c=Math.cos(a),s=Math.sin(a);
    \\ return {x:p.x+lx*c-ly*s,y:p.y+lx*s+ly*c};}
    \\function moved(i){return P[i].x!==orig[i].x||P[i].y!==orig[i].y||(P[i].rot||0)!==orig[i].rot;}
    \\function wrect(i,pad){var p=P[i],c=wpt(i,pad.x,pad.y),q=(((p.rot||0)%360)+360)%360;
    \\ var hw=(q==90||q==270)?pad.h/2:pad.w/2, hh=(q==90||q==270)?pad.w/2:pad.h/2;
    \\ return {x0:c.x-hw,y0:c.y-hh,x1:c.x+hw,y1:c.y+hh};}
    \\function setT(i){var p=P[i];
    \\ els[i].setAttribute("transform","translate("+X(p.x).toFixed(1)+","+Y(p.y).toFixed(1)+")");
    \\ bodies[i].setAttribute("transform","rotate("+(p.rot||0)+")");}
    \\P.forEach(function(p,i){
    \\ var g=el("g",{"class":"part","data-ref":p.ref});
    \\ var body=el("g",{"class":"body"});
    \\ body.appendChild(el("rect",{"class":"court",x:(-p.hw*S).toFixed(1),y:(-p.hh*S).toFixed(1),
    \\   width:(2*p.hw*S).toFixed(1),height:(2*p.hh*S).toFixed(1),rx:2,fill:"#161b22",
    \\   stroke:p.kind=="hub"?"#58a6ff":"#8b949e","stroke-width":1.3,
    \\   "stroke-dasharray":p.fb?"4 3":"0"}));
    \\ if(p.silk){
    \\  p.silk.l.forEach(function(s){body.appendChild(el("line",{x1:(s[0]*S).toFixed(1),y1:(s[1]*S).toFixed(1),
    \\    x2:(s[2]*S).toFixed(1),y2:(s[3]*S).toFixed(1),stroke:"#8b949e","stroke-width":0.8,"stroke-linecap":"round"}));});
    \\  p.silk.c.forEach(function(c){body.appendChild(el("circle",{cx:(c[0]*S).toFixed(1),cy:(c[1]*S).toFixed(1),
    \\    r:Math.max(c[2]*S,1).toFixed(1),fill:"none",stroke:"#8b949e","stroke-width":0.8}));});}
    \\ p.pads.forEach(function(pad){
    \\   var at={fill:"#b08d57"}; if(pad.net)at["data-net"]=pad.net;
    \\   body.appendChild(FP.padShape(pad,{scale:S,minPx:1.5,cls:"pad",attrs:at}));});
    \\ g.appendChild(body);
    \\ var t=el("text",{"class":"pcb-ref",x:0,y:(-p.hh*S-2).toFixed(1),fill:p.kind=="hub"?"#58a6ff":"#8b949e"});
    \\ t.textContent=p.ref; g.appendChild(t);
    \\ gP.appendChild(g); els.push(g); bodies.push(body);
    \\ setT(i);
    \\});
    \\function aw(a,b,col,sw,op){gR.appendChild(el("line",{x1:X(a.x).toFixed(1),y1:Y(a.y).toFixed(1),
    \\ x2:X(b.x).toFixed(1),y2:Y(b.y).toFixed(1),stroke:col,"stroke-width":sw,opacity:op}));}
    \\function rats(){
    \\ while(gR.firstChild)gR.removeChild(gR.firstChild);
    \\ PCB.links.forEach(function(l){
    \\   var a=wpt(l.a,l.ax,l.ay),b=wpt(l.b,l.bx,l.by);
    \\   var col=l.k=="proximity"?"#ea580c":(l.k=="ground"?"#22b8cf":"#9aa7b4");
    \\   aw(a,b,col,l.k=="signal"?0.7:1.3,l.k=="signal"?0.55:0.9);});
    \\ var routedNow=((PCB.tracks||[]).length>0);
    \\ // Use the server's DRC-safe GND-via drop (cgv/gpv) only while the cap/hub is
    \\ // at its emitted pose; once dragged that world point is stale, so recompute
    \\ // the via at the live GND pad centre so it follows the part (the prior via is
    \\ // already cleared with gR above; Route re-derives the exact DRC-safe fan).
    \\ PCB.loops.forEach(function(L){
    \\   // cgv/gpv are the server's DRC-safe via drops, valid only at the emitted
    \\   // pose. Once a part is dragged that point is stale, and cgv/gpv come back
    \\   // null when the router can't fan a via there at all (a fat thermal/EP GND
    \\   // pad next to a small pad). In both cases draw the return *path* to the raw
    \\   // pad centre but DON'T draw a via dot — an invented dot would land on the
    \\   // neighbouring pad (the FB tap) and never match what Route actually drops.
    \\   var cReal=(L.cgv&&!moved(L.cap)), dReal=(L.gpv&&!moved(L.hub));
    \\   var A=wpt(L.hub,L.pp.x,L.pp.y), B=wpt(L.cap,L.cp.x,L.cp.y),
    \\       C=cReal?L.cgv:wpt(L.cap,L.cg.x,L.cg.y),
    \\       D=dReal?L.gpv:wpt(L.hub,L.gp.x,L.gp.y);
    \\   aw(B,A,"#ea580c",1.3,0.95);
    \\   var rp=[C,B,A,D].map(function(q){return X(q.x).toFixed(1)+","+Y(q.y).toFixed(1);}).join(" ");
    \\   var pl=el("polyline",{points:rp,fill:"none",stroke:"#58a6ff","stroke-width":1.3,opacity:0.85,"stroke-dasharray":"4 2"});
    \\   var gt=el("title",{}); gt.textContent="GND return images under the power trace on the L2 plane (drops at the DRC-safe GND vias)"; pl.appendChild(gt);
    \\   gR.appendChild(pl);
    \\   if(!routedNow){ if(cReal)drawVia(gR,C.x,C.y,viaGeo().dia,viaGeo().drill);
    \\                   if(dReal)drawVia(gR,D.x,D.y,viaGeo().dia,viaGeo().drill); }});
    \\}
    \\function delta(id,cur,base){
    \\ var e=document.getElementById(id);if(!e)return;var d=cur-base;
    \\ if(Math.abs(d)<0.05){e.textContent="=";e.className="delta";}
    \\ else{e.textContent=(d>0?"+":"")+d.toFixed(1);e.className="delta "+(d>0?"up":"down");}
    \\}
    \\function setSc(id,t){var e=document.getElementById(id);if(e)e.textContent=t;}
    \\// Score view: recompute the headline from the breakdown's raw terms × the
    \\// per-metric display weights/toggles, so re-weighing is instant and never
    \\// re-places parts. Defaults equal the engine weights ⇒ matches the server.
    \\var lastBreak=null;
    \\function svGet(){
    \\ function n(id,d){var e=document.getElementById(id);if(!e)return d;var v=parseFloat(e.value);return isFinite(v)?v:d;}
    \\ function on(id){var e=document.getElementById(id);return e?e.checked:true;}
    \\ return {wire:{on:on("sv-en-wire"),w:n("sv-w-wire",1)},loop:{on:on("sv-en-loop"),w:n("sv-w-loop",6)},
    \\  align:{on:on("sv-en-align"),w:n("sv-w-align",0.5)},cong:{on:on("sv-en-cong"),w:n("sv-w-cong",2)}};
    \\}
    \\function svTerms(b){var s=svGet();
    \\ var wire=s.wire.on?s.wire.w*(b.hpwl||0):0,loop=s.loop.on?s.loop.w*(b.loop_nh_weighted||0):0;
    \\ var align=s.align.on?s.align.w*(b.alignment||0):0,cong=s.cong.on?s.cong.w*(b.congestion||0):0;
    \\ return {wire:wire,loop:loop,align:align,cong:cong,obj:wire+loop+align+cong,s:s};
    \\}
    \\function svOff(id,off){var e=document.getElementById(id);if(e)e.classList.toggle("sc-off",off);}
    \\function showScore(b){lastBreak=b;
    \\ var t=svTerms(b),a=svTerms(PCB.auto);
    \\ setSc("sc-obj","objective "+t.obj.toFixed(1));
    \\ setSc("sc-hpwl","wire "+(b.hpwl||0).toFixed(1));
    \\ setSc("sc-loop","loop "+t.loop.toFixed(1)+" · "+PCB.caps+" cap");
    \\ setSc("sc-ind","loop "+(b.loop_nh||0).toFixed(2)+" nH");
    \\ setSc("sc-align","area "+((b.footprint!=null?b.footprint:b.alignment)||0).toFixed(1)+" mm²");
    \\ setSc("sc-cong","cong "+t.cong.toFixed(1));
    \\ delta("sc-obj-d",t.obj,a.obj);
    \\ delta("sc-hpwl-d",b.hpwl||0,PCB.auto.hpwl||0);
    \\ delta("sc-loop-d",t.loop,a.loop);
    \\ delta("sc-ind-d",b.loop_nh||0,PCB.auto.loop_nh||0);
    \\ delta("sc-align-d",(b.footprint!=null?b.footprint:b.alignment)||0,(PCB.auto.footprint!=null?PCB.auto.footprint:PCB.auto.alignment)||0);
    \\ delta("sc-cong-d",t.cong,a.cong);
    \\ svOff("sc-hpwl",!t.s.wire.on);svOff("sc-hpwl-d",!t.s.wire.on);
    \\ svOff("sc-loop",!t.s.loop.on);svOff("sc-loop-d",!t.s.loop.on);
    \\ svOff("sc-ind",!t.s.loop.on);svOff("sc-ind-d",!t.s.loop.on);
    \\ svOff("sc-align",!t.s.align.on);svOff("sc-align-d",!t.s.align.on);
    \\ svOff("sc-cong",!t.s.cong.on);svOff("sc-cong-d",!t.s.cong.on);
    \\}
    \\// Each saved layout's raw breakdown (fetched once via pcb-score-batch), so
    \\// the panel re-weighs under the Score-view weights with no per-row round-trip.
    \\var layBreaks={};
    \\function svApply(){if(lastBreak)showScore(lastBreak);reweighLayouts();}
    \\function reweighLayouts(){var aobj=svTerms(PCB.auto).obj;
    \\ document.querySelectorAll(".lay-row").forEach(function(row){
    \\  var nm=row.getAttribute("data-lay-row"),b=layBreaks[nm];if(!b)return;var t=svTerms(b);
    \\  var sc=row.querySelector(".lay-score");
    \\  if(sc)sc.textContent="obj "+t.obj.toFixed(1)+" · loop "+(b.loop_raw||0).toFixed(1)+
    \\   " · area "+((b.footprint!=null?b.footprint:b.alignment)||0).toFixed(0)+" mm²";
    \\  var dd=row.querySelector(".lay-d");if(!dd)return;var d=t.obj-aobj;
    \\  if(Math.abs(d)<0.05){dd.textContent="=";dd.className="lay-d";}
    \\  else{dd.textContent=(d>0?"+":"")+d.toFixed(1);dd.className="lay-d "+(d>0?"up":"down");}});
    \\}
    \\var scoreReq=0;
    \\function fetchScore(){
    \\ setSc("sc-obj","objective …");var seq=++scoreReq;
    \\ var payload={parts:P.map(function(p){return {ref:p.ref,x:p.x,y:p.y,rot:p.rot||0};})};
    \\ fetch("/api/pcb-score/"+encodeURIComponent(PCB.name),{method:"POST",
    \\   headers:{"Content-Type":"application/json"},body:JSON.stringify(payload)})
    \\  .then(function(r){return r.json();})
    \\  .then(function(b){if(seq===scoreReq)showScore(b);})
    \\  .catch(function(){if(seq===scoreReq)setSc("sc-obj","objective —");});
    \\}
    \\function mm(ev){var r=svg.getBoundingClientRect(),vb=svg.viewBox.baseVal;
    \\ var sx=vb.x+(ev.clientX-r.left)*(vb.width/r.width);
    \\ var sy=vb.y+(ev.clientY-r.top)*(vb.height/r.height);
    \\ return {x:sx/S+MX-M,y:sy/S+MY-M};}
    \\if(!RO){
    \\var drag=null, cur=-1;
    \\// Click a part on the board → reveal it in the component sidebar: scroll the
    \\// matching <li> into view and flash it so you can see what the part is.
    \\function scrollToComp(ref){var li=document.querySelector('.comp[data-ref="'+ref+'"]');
    \\ if(!li)return;li.scrollIntoView({behavior:"smooth",block:"center"});
    \\ document.querySelectorAll(".comp.sel").forEach(function(e){e.classList.remove("sel");});
    \\ void li.offsetWidth;li.classList.add("sel");}
    \\els.forEach(function(g,i){
    \\ g.addEventListener("mouseenter",function(){cur=i;});
    \\ g.addEventListener("mouseleave",function(){if(cur===i)cur=-1;});
    \\ g.addEventListener("pointerdown",function(ev){ev.preventDefault();var m=mm(ev);
    \\   drag={i:i,ox:P[i].x-m.x,oy:P[i].y-m.y};g.setPointerCapture(ev.pointerId);g.style.cursor="grabbing";});
    \\ g.addEventListener("pointermove",function(ev){if(!drag||drag.i!==i)return;var m=mm(ev);
    \\   var nx=Math.round((m.x+drag.ox)/G)*G,ny=Math.round((m.y+drag.oy)/G)*G;
    \\   if(nx===P[i].x&&ny===P[i].y)return;P[i].x=nx;P[i].y=ny;
    \\   if(!drag.moved){drag.moved=true;clearRoute();}setT(i);rats();drawClr();});
    \\ g.addEventListener("pointerup",function(ev){var mv=drag&&drag.moved;drag=null;g.style.cursor="grab";
    \\   try{g.releasePointerCapture(ev.pointerId);}catch(e){}if(mv)fetchScore();else scrollToComp(P[i].ref);});
    \\});
    \\document.addEventListener("keydown",function(ev){
    \\ if((ev.key=="r"||ev.key=="R")&&cur>=0){ev.preventDefault();
    \\   P[cur].rot=((((P[cur].rot||0)+(ev.shiftKey?-90:90))%360)+360)%360;
    \\   setT(cur);clearRoute();rats();fetchScore();}});
    \\function applyAll(){P.forEach(function(p,i){setT(i);});clearRoute();rats();fetchScore();
    \\ if(window.PCB3D&&window.PCB3D.sync)window.PCB3D.sync();}
    \\document.getElementById("pcb-reset").addEventListener("click",function(){
    \\ P.forEach(function(p,i){p.x=orig[i].x;p.y=orig[i].y;p.rot=orig[i].rot;});applyAll();});
    \\document.getElementById("pcb-score").addEventListener("click",fetchScore);
    \\document.getElementById("t-apply").addEventListener("click",function(ev){ev.preventDefault();
    \\ var v=function(id){return encodeURIComponent(document.getElementById(id).value);};
    \\ var g=document.getElementById("t-grid").checked?1:0;
    \\ liveRegen("?w_align="+v("t-align")+"&loop_w="+v("t-loop")+"&w_congest="+v("t-cong")+
    \\  "&grid="+g+"&compact="+v("t-compact"));});
    \\(function(){var ids=["sv-en-wire","sv-w-wire","sv-en-loop","sv-w-loop","sv-en-align","sv-w-align","sv-en-cong","sv-w-cong"];
    \\ var def={};ids.forEach(function(id){var e=document.getElementById(id);if(!e)return;
    \\  def[id]=(e.type=="checkbox")?e.checked:e.value;e.addEventListener("input",svApply);});
    \\ var rb=document.getElementById("sv-reset");
    \\ if(rb)rb.addEventListener("click",function(){ids.forEach(function(id){var e=document.getElementById(id);
    \\   if(e){if(e.type=="checkbox")e.checked=def[id];else e.value=def[id];}});svApply();});})();
    \\function pad2(n){return (n<10?"0":"")+n;}
    \\function stamp(){var d=new Date();return pad2(d.getMonth()+1)+"-"+pad2(d.getDate())+" "+pad2(d.getHours())+":"+pad2(d.getMinutes());}
    \\document.getElementById("pcb-saveas").addEventListener("click",function(){
    \\ var nm=window.prompt("Name this layout:","layout "+stamp());
    \\ if(nm===null)return; nm=nm.trim(); if(!nm)return;
    \\ var msg=document.getElementById("pcb-savemsg");
    \\ var payload={name:nm,parts:P.map(function(p){return {ref:p.ref,x:p.x,y:p.y,rot:p.rot||0};})};
    \\ msg.style.color="#8b949e";msg.textContent="saving…";
    \\ fetch("/api/pcb-layouts/"+encodeURIComponent(PCB.name),{method:"POST",
    \\   headers:{"Content-Type":"application/json"},body:JSON.stringify(payload)})
    \\  .then(function(r){if(!r.ok)throw 0;return r.json();})
    \\  .then(function(){msg.style.color="#3fb950";msg.textContent="saved ✓";
    \\    setTimeout(function(){window.location.reload();},300);})
    \\  .catch(function(){msg.style.color="#f85149";msg.textContent="save failed";});});
    \\function layByName(nm){var Ls=PCB.layouts||[];for(var i=0;i<Ls.length;i++)if(Ls[i].name===nm)return Ls[i];return null;}
    \\document.querySelectorAll("[data-lay-load]").forEach(function(b){
    \\ b.addEventListener("click",function(){var L=layByName(b.getAttribute("data-lay-load"));if(!L)return;
    \\   P.forEach(function(p){var s=L.parts[p.ref];if(s){p.x=s.x;p.y=s.y;p.rot=s.rot||0;}});applyAll();});});
    \\document.querySelectorAll("[data-lay-del]").forEach(function(b){
    \\ b.addEventListener("click",function(){var nm=b.getAttribute("data-lay-del");
    \\   if(!window.confirm("Delete layout \""+nm+"\"?"))return;
    \\   fetch("/api/pcb-layouts/"+encodeURIComponent(PCB.name)+"/delete",{method:"POST",
    \\     headers:{"Content-Type":"application/json"},body:JSON.stringify({name:nm})})
    \\    .then(function(r){if(!r.ok)throw 0;window.location.reload();}).catch(function(){});});});
    \\// ★ toggle: set this layout as the KiCad-sync default, or clear it if already
    \\// default (send an empty name). The server seeds new parts' placement + GND
    \\// vias from the default on the next sync.
    \\document.querySelectorAll("[data-lay-default]").forEach(function(b){
    \\ b.addEventListener("click",function(){var nm=b.getAttribute("data-lay-default");
    \\   var send=b.classList.contains("on")?"":nm;
    \\   fetch("/api/pcb-layouts/"+encodeURIComponent(PCB.name)+"/default",{method:"POST",
    \\     headers:{"Content-Type":"application/json"},body:JSON.stringify({name:send})})
    \\    .then(function(r){if(!r.ok)throw 0;window.location.reload();}).catch(function(){});});});
    \\var rescoreBtn=document.getElementById("pcb-rescore");
    \\if(rescoreBtn)rescoreBtn.addEventListener("click",function(){
    \\ rescoreBtn.disabled=true;rescoreBtn.textContent="Rescoring…";
    \\ fetch("/api/pcb-rescore/"+encodeURIComponent(PCB.name),{method:"POST"})
    \\  .then(function(r){if(!r.ok)throw 0;return r.json();})
    \\  .then(function(){window.location.reload();})
    \\  .catch(function(){rescoreBtn.disabled=false;rescoreBtn.textContent="↻ Rescore all";});});
    \\// Fetch each saved layout's raw breakdown once, then re-weigh the panel so its
    \\// scores/deltas track the Score-view weights alongside the live bar.
    \\(function(){if(!((PCB.layouts||[]).length))return;
    \\ fetch("/api/pcb-score-batch/"+encodeURIComponent(PCB.name),{method:"POST"})
    \\  .then(function(r){return r.json();})
    \\  .then(function(j){(j.results||[]).forEach(function(it){layBreaks[it.name]=it.breakdown;});reweighLayouts();})
    \\  .catch(function(){});})();
    \\}
    \\function hlBy(at,v,cls,on){document.querySelectorAll("["+at+"]").forEach(function(e){
    \\ if(e.getAttribute(at)===v)e.classList.toggle(cls,on);});}
    \\function wire(at,cls){document.querySelectorAll("["+at+"]").forEach(function(e){
    \\ e.addEventListener("mouseenter",function(){hlBy(at,e.getAttribute(at),cls,true);});
    \\ e.addEventListener("mouseleave",function(){hlBy(at,e.getAttribute(at),cls,false);});});}
    \\wire("data-ref","hl"); wire("data-net","net-hl");
    \\var VBW=PCB.w,VBH=PCB.h,vb={x:0,y:0,w:VBW,h:VBH};
    \\function setVB(){svg.setAttribute("viewBox",vb.x.toFixed(1)+" "+vb.y.toFixed(1)+" "+vb.w.toFixed(1)+" "+vb.h.toFixed(1));}
    \\function zoomAt(cx,cy,f){if((f<1&&vb.w<VBW*0.08)||(f>1&&vb.w>VBW*8))return;
    \\ var r=svg.getBoundingClientRect();
    \\ var px=vb.x+(cx-r.left)*(vb.w/r.width),py=vb.y+(cy-r.top)*(vb.h/r.height);
    \\ vb.x=px-(px-vb.x)*f; vb.y=py-(py-vb.y)*f; vb.w*=f; vb.h*=f; setVB();}
    \\svg.addEventListener("wheel",function(ev){ev.preventDefault();zoomAt(ev.clientX,ev.clientY,ev.deltaY>0?1.1:0.9);},{passive:false});
    \\function zc(f){var r=svg.getBoundingClientRect();zoomAt(r.left+r.width/2,r.top+r.height/2,f);}
    \\var zi=document.getElementById("z-in");if(zi)zi.addEventListener("click",function(){zc(0.8);});
    \\var zo=document.getElementById("z-out");if(zo)zo.addEventListener("click",function(){zc(1.25);});
    \\var zf=document.getElementById("z-fit");if(zf)zf.addEventListener("click",function(){vb={x:0,y:0,w:VBW,h:VBH};setVB();});
    \\var pan=null;
    \\svg.addEventListener("pointerdown",function(ev){if(ev.target!==svg)return;ev.preventDefault();
    \\ pan={cx:ev.clientX,cy:ev.clientY,vx:vb.x,vy:vb.y};svg.setPointerCapture(ev.pointerId);svg.style.cursor="grabbing";});
    \\svg.addEventListener("pointermove",function(ev){if(!pan)return;var r=svg.getBoundingClientRect();
    \\ vb.x=pan.vx-(ev.clientX-pan.cx)*(vb.w/r.width);vb.y=pan.vy-(ev.clientY-pan.cy)*(vb.h/r.height);setVB();});
    \\svg.addEventListener("pointerup",function(ev){pan=null;svg.style.cursor="";try{svg.releasePointerCapture(ev.pointerId);}catch(e){}});
    \\function viaGeo(){var va=parseFloat((document.getElementById("r-va")||{}).value),
    \\ vd=parseFloat((document.getElementById("r-vd")||{}).value);return {dia:va>0?va:0.4,drill:vd>0?vd:0.2};}
    \\function drawVia(g,wx,wy,dia,drill){var r=Math.max(dia/2*S,2.5),rh=Math.min(Math.max(drill/2*S,1),r*0.7);
    \\ g.appendChild(el("circle",{cx:X(wx).toFixed(1),cy:Y(wy).toFixed(1),r:r.toFixed(1),fill:"#ca8a04"}));
    \\ g.appendChild(el("circle",{cx:X(wx).toFixed(1),cy:Y(wy).toFixed(1),r:rh.toFixed(1),fill:"#fff"}));}
    \\function drawRoute(){while(gT.firstChild)gT.removeChild(gT.firstChild);
    \\ (PCB.tracks||[]).forEach(function(t){gT.appendChild(el("line",{x1:X(t.x1).toFixed(1),y1:Y(t.y1).toFixed(1),
    \\   x2:X(t.x2).toFixed(1),y2:Y(t.y2).toFixed(1),stroke:t.l==0?"#f85149":"#388bfd",
    \\   "stroke-width":Math.max(t.w*S,1.2).toFixed(1),"stroke-linecap":"round","stroke-linejoin":"round",opacity:0.85}));});
    \\ (PCB.vias||[]).forEach(function(v){drawVia(gT,v.x,v.y,v.d,viaGeo().drill);});}
    \\function clrVal(){var ci=document.getElementById("r-cl"),c=ci?parseFloat(ci.value):NaN;
    \\ return (c>0)?c:(PCB.clr||0.127);}
    \\function drawClr(){while(gC.firstChild)gC.removeChild(gC.firstChild);
    \\ var cb=document.getElementById("r-clr-show"); if(!cb||!cb.checked)return;
    \\ var clr=clrVal();
    \\ P.forEach(function(p,i){p.pads.forEach(function(pad){var r=wrect(i,pad);
    \\   gC.appendChild(el("rect",{x:X(r.x0-clr).toFixed(1),y:Y(r.y0-clr).toFixed(1),
    \\     width:((r.x1-r.x0+2*clr)*S).toFixed(1),height:((r.y1-r.y0+2*clr)*S).toFixed(1),
    \\     rx:(clr*S).toFixed(1),fill:"rgba(210,153,34,0.13)",stroke:"#d29922","stroke-width":0.8,"stroke-dasharray":"3 2"}));});});
    \\ (PCB.vias||[]).forEach(function(v){gC.appendChild(el("circle",{cx:X(v.x).toFixed(1),cy:Y(v.y).toFixed(1),
    \\   r:((v.d/2+clr)*S).toFixed(1),fill:"rgba(210,153,34,0.13)",stroke:"#d29922","stroke-width":0.8,"stroke-dasharray":"3 2"}));});
    \\ (PCB.tracks||[]).forEach(function(t){gC.appendChild(el("line",{x1:X(t.x1).toFixed(1),y1:Y(t.y1).toFixed(1),
    \\   x2:X(t.x2).toFixed(1),y2:Y(t.y2).toFixed(1),stroke:"#d29922","stroke-opacity":0.20,
    \\   "stroke-width":((t.w+2*clr)*S).toFixed(1),"stroke-linecap":"round"}));});}
    \\var clrCb=document.getElementById("r-clr-show");
    \\if(clrCb)clrCb.addEventListener("change",drawClr);
    \\var clrIn=document.getElementById("r-cl");
    \\if(clrIn)clrIn.addEventListener("input",drawClr);
    \\function drawDrc(){while(gD.firstChild)gD.removeChild(gD.firstChild);
    \\ var cb=document.getElementById("r-drc-show"); if(cb&&!cb.checked)return;
    \\ (PCB.drc||[]).forEach(function(d){var cx=X(d.x),cy=Y(d.y);
    \\   var t=el("title",{}); t.textContent=d.k+" — gap "+d.gap.toFixed(3)+" mm < "+d.clr+" mm";
    \\   var c=el("circle",{cx:cx.toFixed(1),cy:cy.toFixed(1),r:8,fill:"none",stroke:"#ef4444","stroke-width":2}); c.appendChild(t);
    \\   gD.appendChild(c);
    \\   gD.appendChild(el("circle",{cx:cx.toFixed(1),cy:cy.toFixed(1),r:2.4,fill:"#ef4444"}));});}
    \\var drcCb=document.getElementById("r-drc-show");
    \\if(drcCb)drcCb.addEventListener("change",drawDrc);
    \\function setStat(id,cls,txt){var e=document.getElementById(id);
    \\ if(e){e.className="route-stat"+(cls?" "+cls:"");e.textContent=txt;}}
    \\function clearRoute(){if(!(PCB.tracks&&PCB.tracks.length)&&!(PCB.vias&&PCB.vias.length)&&!(PCB.drc&&PCB.drc.length))return;
    \\ PCB.tracks=[];PCB.vias=[];PCB.drc=[];drawRoute();drawClr();drawDrc();setStat("r-stat","","");setStat("r-drc","","");setStat("r-rp","","");}
    \\var courtState=null;
    \\function partByRef(ref){for(var i=0;i<P.length;i++)if(P[i].ref===ref)return P[i];return null;}
    \\function gceil(v){return Math.ceil(v/G-1e-9)*G;}
    \\function padExt(p){var hw=0,hh=0;p.pads.forEach(function(pd){
    \\ hw=Math.max(hw,Math.abs(pd.x)+pd.w/2);hh=Math.max(hh,Math.abs(pd.y)+pd.h/2);});return {hw:hw,hh:hh};}
    \\function courtDraw(p,hw,hh){var s=document.getElementById("court-svg");while(s.firstChild)s.removeChild(s.firstChild);
    \\ var VB=260,VH=220,pd=28,sc=Math.min((VB-pd)/(2*hw),(VH-pd)/(2*hh)),cx=VB/2,cy=VH/2;
    \\ var g=el("g",{transform:"translate("+cx+","+cy+")"});s.appendChild(g);
    \\ g.appendChild(el("rect",{x:(-hw*sc).toFixed(1),y:(-hh*sc).toFixed(1),width:(2*hw*sc).toFixed(1),height:(2*hh*sc).toFixed(1),
    \\   rx:3,fill:"none",stroke:p.kind=="hub"?"#58a6ff":"#8b949e","stroke-width":1.4,"stroke-dasharray":"5 3"}));
    \\ p.pads.forEach(function(pad){g.appendChild(FP.padShape(pad,{scale:sc,minPx:2,attrs:{fill:"#b08d57"}}));});}
    \\function courtBox(){var c=courtState;return c.mode=="offset"?{hw:gceil(c.ext.hw+c.offset),hh:gceil(c.ext.hh+c.offset)}:{hw:c.hw,hh:c.hh};}
    \\function courtRefresh(){if(!courtState)return;var b=courtBox();courtDraw(courtState.p,b.hw,b.hh);
    \\ document.getElementById("court-full").textContent="full "+(2*b.hw).toFixed(2)+" × "+(2*b.hh).toFixed(2)+" mm";}
    \\function courtSetMode(m){if(!courtState)return;courtState.mode=m;
    \\ document.getElementById("court-fields-size").hidden=(m!="size");
    \\ document.getElementById("court-fields-offset").hidden=(m!="offset");courtRefresh();}
    \\function openCourt(ref){var p=partByRef(ref);if(!p)return;var ext=padExt(p),cm=PCB.cmargin||0.15;
    \\ var min={hw:gceil(ext.hw+cm),hh:gceil(ext.hh+cm)};
    \\ courtState={p:p,fp:p.fp,mode:"size",hw:p.hw,hh:p.hh,offset:0.2,ext:ext,min:min};
    \\ document.getElementById("court-title").textContent=p.fp+"  ·  "+p.ref;
    \\ var hwI=document.getElementById("court-hw"),hhI=document.getElementById("court-hh"),offI=document.getElementById("court-off");
    \\ var sv=document.getElementById("court-save"),note=document.getElementById("court-note"),msg=document.getElementById("court-msg");
    \\ msg.textContent="";hwI.value=p.hw.toFixed(1);hhI.value=p.hh.toFixed(1);hwI.min=min.hw;hhI.min=min.hh;offI.value=(0.2).toFixed(2);
    \\ var fab=p.fb||!p.fp,noPads=!(ext.hw>0||ext.hh>0);
    \\ sv.disabled=fab;hwI.disabled=fab;hhI.disabled=fab;offI.disabled=fab||noPads;
    \\ document.querySelectorAll("input[name=court-mode]").forEach(function(r){r.checked=(r.value=="size");r.disabled=fab||(r.value=="offset"&&noPads);});
    \\ courtSetMode("size");
    \\ note.textContent=fab?"Synthesized placeholder box (no footprint file) — courtyard can't be edited.":
    \\  "Overall size sets the half-extents directly; Pad offset puts the courtyard edge that gap "+
    \\  "outside the pad bounding box, snapped to the 0.2 mm grid. "+
    \\  "Saving rewrites lib/footprints/"+p.fp+".sexp and applies to every design using it.";
    \\ document.getElementById("court-modal").hidden=false;}
    \\function courtClose(){document.getElementById("court-modal").hidden=true;courtState=null;}
    \\document.querySelectorAll("[data-court-ref]").forEach(function(b){
    \\ b.addEventListener("click",function(){openCourt(b.getAttribute("data-court-ref"));});});
    \\var cxBtn=document.getElementById("court-x"),ccBtn=document.getElementById("court-cancel"),modalBg=document.getElementById("court-modal");
    \\if(cxBtn)cxBtn.addEventListener("click",courtClose);
    \\if(ccBtn)ccBtn.addEventListener("click",courtClose);
    \\if(modalBg)modalBg.addEventListener("click",function(ev){if(ev.target===modalBg)courtClose();});
    \\document.querySelectorAll("input[name=court-mode]").forEach(function(r){
    \\ r.addEventListener("change",function(){if(r.checked)courtSetMode(r.value);});});
    \\function courtInput(which){if(!courtState)return;var inp=document.getElementById(which=="hw"?"court-hw":"court-hh");
    \\ var v=Math.round(parseFloat(inp.value)/G)*G;if(!(v>0))v=courtState.min[which];
    \\ v=Math.max(v,courtState.min[which]);courtState[which]=v;inp.value=v.toFixed(1);courtRefresh();}
    \\var hwI2=document.getElementById("court-hw"),hhI2=document.getElementById("court-hh");
    \\if(hwI2)hwI2.addEventListener("change",function(){courtInput("hw");});
    \\if(hhI2)hhI2.addEventListener("change",function(){courtInput("hh");});
    \\var offI2=document.getElementById("court-off");
    \\if(offI2)offI2.addEventListener("change",function(){if(!courtState)return;var v=parseFloat(offI2.value);
    \\ if(!(v>=0))v=0;v=Math.round(v/0.05)*0.05;courtState.offset=v;offI2.value=v.toFixed(2);courtRefresh();});
    \\var csv=document.getElementById("court-save");
    \\if(csv)csv.addEventListener("click",function(){if(!courtState||!courtState.fp)return;
    \\ var msg=document.getElementById("court-msg");msg.style.color="#8b949e";msg.textContent="saving…";
    \\ var body=courtState.mode=="offset"?{fp:courtState.fp,mode:"offset",offset:courtState.offset}
    \\   :{fp:courtState.fp,mode:"size",hw:courtState.hw,hh:courtState.hh};
    \\ fetch("/api/courtyard/"+encodeURIComponent(PCB.name),{method:"POST",headers:{"Content-Type":"application/json"},
    \\   body:JSON.stringify(body)})
    \\  .then(function(r){if(!r.ok)throw 0;return r.json();})
    \\  .then(function(){msg.style.color="#3fb950";msg.textContent="saved ✓ — rebuilding";
    \\    window.location="/pcb-layout/"+encodeURIComponent(PCB.name)+"?regen=1";})
    \\  .catch(function(){msg.style.color="#f85149";msg.textContent="save failed";});});
    \\var rgo=document.getElementById("r-go");
    \\if(rgo)rgo.addEventListener("click",function(){
    \\ var nf=function(id){return parseFloat(document.getElementById(id).value);};
    \\ var hint=document.getElementById("r-hint");if(hint)hint.style.display="none";
    \\ setStat("r-stat","","routing…");setStat("r-drc","","");rgo.disabled=true;
    \\ var payload={parts:P.map(function(p){return {ref:p.ref,x:p.x,y:p.y,rot:p.rot||0};}),
    \\   track_width:nf("r-tw"),clearance:nf("r-cl"),via_drill:nf("r-vd"),via_dia:nf("r-va")};
    \\ fetch("/api/pcb-route/"+encodeURIComponent(PCB.name),{method:"POST",
    \\   headers:{"Content-Type":"application/json"},body:JSON.stringify(payload)})
    \\  .then(function(r){if(!r.ok)throw 0;return r.json();})
    \\  .then(function(j){PCB.tracks=j.tracks||[];PCB.vias=j.vias||[];PCB.drc=j.drc||[];
    \\    if(payload.clearance>0)PCB.clr=payload.clearance;drawRoute();drawClr();drawDrc();
    \\    rats();/* re-run with tracks present: routedNow is now true, so the loop
    \\           overlay drops its preview GND vias and only the router's real vias
    \\           remain — no preview+routed via doubling on the bypass caps. */
    \\    var ok=(j.routed===j.total);
    \\    setStat("r-stat",ok?"ok":"warn","routed "+j.routed+"/"+j.total+" nets · "+((j.vias||[]).length)+" vias");
    \\    setStat("r-drc",(j.drc||[]).length?"err":"ok",(j.drc||[]).length?(j.drc.length+" DRC violation(s)"):"DRC clean ✓");
    \\    var rp=j.return_path||0; setStat("r-rp",rp?"warn":"ok",rp?(rp+" return-path warning(s)"):"return paths ✓");
    \\    rgo.disabled=false;})
    \\  .catch(function(){setStat("r-stat","err","route failed");rgo.disabled=false;});});
    \\// ── Live regenerate: run the optimizer in the background and animate the
    \\//    board converging on its best-so-far arrangement (poll-driven). The
    \\//    Regenerate / Apply buttons start a background solve instead of a
    \\//    blocking page nav; on any error we fall back to the old ?regen=1 path.
    \\var byRef={}; P.forEach(function(p,i){byRef[p.ref]=i;});
    \\// Anchor the main IC (the hub with the largest courtyard — falls back to the
    \\// biggest part) so every tried arrangement is shown *relative* to it: each
    \\// live frame is translated to pin this part at its on-screen spot, so the IC
    \\// stays put in the centre and only the parts around it visibly rearrange.
    \\var anchorRef=null,anchorTX=0,anchorTY=0;
    \\(function(){var bi=-1,bs=-1;P.forEach(function(p,i){
    \\  var s=(p.hw||0)*(p.hh||0)+(p.kind==="hub"?1e6:0);if(s>bs){bs=s;bi=i;}});
    \\ if(bi>=0){anchorRef=P[bi].ref;anchorTX=orig[bi].x;anchorTY=orig[bi].y;}})();
    \\var liveBox=null;
    \\function liveCard(){
    \\ if(liveBox)return liveBox;
    \\ liveBox=document.createElement("div"); liveBox.className="pcb-live";
    \\ liveBox.innerHTML='<div class="pcb-live-card"><div class="pcb-live-spin"></div>'+
    \\   '<div><div class="pcb-live-msg" id="pcb-live-msg">Starting optimizer…</div>'+
    \\   '<div class="pcb-live-sub" id="pcb-live-sub"></div></div></div>';
    \\ document.body.appendChild(liveBox); return liveBox;
    \\}
    \\function liveMsg(m,s,cls){var box=liveCard();
    \\ box.className="pcb-live"+(cls?" "+cls:"");
    \\ var a=document.getElementById("pcb-live-msg");if(a&&m!==undefined)a.textContent=m;
    \\ var b=document.getElementById("pcb-live-sub");if(b)b.textContent=(s===undefined?"":s);}
    \\function liveHide(){if(liveBox&&liveBox.parentNode)liveBox.parentNode.removeChild(liveBox);liveBox=null;}
    \\function liveApply(f){if(!f||!f.parts)return;
    \\ // Translate the frame so the anchor IC lands on its fixed on-screen point.
    \\ var dx=0,dy=0;
    \\ if(anchorRef!==null){f.parts.forEach(function(q){
    \\   if(q.ref===anchorRef){dx=anchorTX-q.x;dy=anchorTY-q.y;}});}
    \\ f.parts.forEach(function(q){var i=byRef[q.ref];if(i===undefined)return;
    \\   P[i].x=q.x+dx;P[i].y=q.y+dy;P[i].rot=q.rot||0;});
    \\ P.forEach(function(p,i){setT(i);}); clearRoute(); rats();}
    \\function liveFallback(query){window.location="/pcb-layout/"+encodeURIComponent(PCB.name)+
    \\  "?regen=1"+(query?("&"+query.replace(/^\?/,"")):"");}
    \\function liveRegen(query){
    \\ liveMsg("Starting optimizer…","","");
    \\ fetch("/api/pcb-regen-start/"+encodeURIComponent(PCB.name)+(query||""),{method:"POST"})
    \\  .then(function(r){return r.json();})
    \\  .then(function(j){if(typeof j.gen!=="number"||!j.gen)throw 0;livePoll(j.gen,-1,0);})
    \\  .catch(function(){liveFallback(query);});}
    \\function livePoll(gen,lastSeq,misses){
    \\ fetch("/api/pcb-progress/"+encodeURIComponent(PCB.name))
    \\  .then(function(r){return r.json();})
    \\  .then(function(j){
    \\   if(j.gen!==gen){liveHide();return;}
    \\   if(j.frame&&j.seq>lastSeq){liveApply(j.frame);lastSeq=j.seq;
    \\     liveMsg("Optimizing — "+(j.frame.pass==="refine"?"refining best layout":"exploring layouts"),
    \\       "candidate score "+(+j.frame.score).toFixed(1)+" · update "+j.seq,"");}
    \\   if(j.done){if(j.err){liveMsg("Optimizer error — falling back…","","err");
    \\       setTimeout(function(){liveFallback("");},700);}
    \\     else{liveMsg("Converged — loading final layout…","","done");
    \\       setTimeout(function(){window.location.reload();},400);}
    \\     return;}
    \\   setTimeout(function(){livePoll(gen,lastSeq,0);},350);})
    \\  .catch(function(){if(misses>20){liveHide();return;}
    \\   setTimeout(function(){livePoll(gen,lastSeq,misses+1);},700);});}
    \\var rgl=document.getElementById("pcb-regen");
    \\if(rgl)rgl.addEventListener("click",function(ev){ev.preventDefault();liveRegen("");});
    \\rats(); showScore(PCB.auto); drawRoute(); drawClr(); drawDrc();
    \\})();</script>
;
