//! GET /pcb-layout/:name — interactive force-directed placement preview.
//!
//! The server evaluates the design, runs the optimizer, and emits the result
//! as JSON plus a small client renderer. The board is drawn client-side so
//! parts can be **dragged** (snapping to the 0.1 mm grid) and the layout
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
const outline_mod = @import("../placement/outline.zig");
const export_fab = @import("../export_fab.zig");
const export_gerber = @import("../export_gerber.zig");
const zipfile = @import("../zipfile.zig");
const module_policy = @import("../placement/module_policy.zig");
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

/// Legacy standalone optimizer-cache sidecar. The cache now lives in the
/// `"cache"` key of `.layouts.json` (one sidecar per design); this file is
/// still read as a fallback for boards last solved by an older build, and
/// is deleted the next time the cache is written.
const AUTO_EXT = ".autolayout.json";

/// JSON key prefix shared by every `{"ref": …}` record we emit.
const REF_OPEN = "{\"ref\":";
/// JSON object opener shared by the placement-export / saved-layout records.
const NAME_OPEN = "{\"name\":";
/// JSON key + open bracket shared by the layout/cache/export part arrays.
const PARTS_OPEN = "\"parts\":[";
/// JSON `,"origin":` key shared by the part records that carry the renumber-
/// stable origin key (saved-layout disk + page JSON, live PCB.parts).
const ORIGIN_OPEN = ",\"origin\":";
/// Error bodies shared across the layout handlers.
const NO_BLOCK_MSG = "No design or module by that name";
/// Response header name the fab-output endpoints set their MIME type on.
const CT_HDR = "content-type";
/// Returned when `?sub=<slug>` names a sub-block that doesn't exist in the design.
const NO_SUB_MSG = "No sub-block by that name";
const BAD_JSON_MSG = "bad json";
const PLACEMENT_ERR_MSG = "Placement error";

/// Success body returned by the mutating layout/courtyard endpoints.
const OK_JSON_TRUE = "{\"ok\":true}";

/// The ` checked` HTML attribute fragment, emitted to pre-check a checkbox.
const CHECKED = " checked";

/// The one layout sidecar per design: every *named* saved layout (manual
/// snapshots the user named plus an auto-recorded history of optimizer
/// runs) under `"layouts"`, the KiCad-sync `"default"` marker, and the
/// single-slot optimizer cache under `"cache"`.
const LAYOUTS_EXT = ".layouts.json";

/// Layout `kind` tags. `manual` = a snapshot the user saved by name; `auto` =
/// one recorded automatically each time the optimizer regenerated.
const KIND_MANUAL = "manual";
const KIND_AUTO = "auto";

/// Cap on auto-recorded entries kept per design. On each record the oldest
/// auto entries past this are pruned; manual snapshots are never auto-pruned.
const MAX_AUTO_LAYOUTS: usize = 12;

/// One placed part within a saved layout: ref-des + centre (mm) + rotation,
/// plus the renumber-stable `origin` (the part's module-local `origin_key`).
/// The ref-des is volatile — it shifts when the part renumbers or when the
/// same module is flattened from a different context (standalone vs as a
/// sub-block of a parent board, which produces different counters). `origin`
/// is the module-local source name, invariant across both, so a Load matches
/// on it first and falls back to `ref` only for legacy entries saved before
/// `origin` was recorded (empty string). See `rekeyPosesByOrigin`.
const PartPose = struct {
    ref: []const u8,
    x: f64,
    y: f64,
    rot: f64,
    origin: []const u8 = "",
    /// Board side (viewer F-flip state). Persisted as `"side":"bottom"` only
    /// when bottom, so legacy top-side sidecars stay byte-identical.
    side: optimizer.Side = .top,
    /// Editor lock (viewer refuses drag/rotate/flip). Persisted as
    /// `"locked":true` only when set.
    locked: bool = false,
};

/// Parse a pose object's optional `"side"` field ("bottom" → bottom, else top).
fn jsonSide(v: ?std.json.Value) optimizer.Side {
    const s = v orelse return .top;
    return if (s == .string) optimizer.Side.fromStr(s.string) else .top;
}

/// Parse a pose object's optional boolean field (absent/non-bool → false).
fn jsonFlag(v: ?std.json.Value) bool {
    const b = v orelse return false;
    return b == .bool and b.bool;
}

/// Append the non-default pose fields (`,"side":"bottom"` / `,"locked":true`)
/// — one spelling for every pose writer (sidecar, cache, API blobs).
fn writePoseSideLocked(w: *std.Io.Writer, side: optimizer.Side, locked: bool) std.Io.Writer.Error!void {
    if (side == .bottom) try w.writeAll(",\"side\":\"bottom\"");
    if (locked) try w.writeAll(",\"locked\":true");
}

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
pub const SavedLayout = struct {
    name: []const u8,
    kind: []const u8,
    ts: i64,
    score: ?LayoutScore,
    parts: []const PartPose,
    default: bool = false,
    /// This layout was produced by the Rough seed (`?rough=1`) — the
    /// AI-friendly module-clustered starting point a human then hand-finishes.
    /// Recorded so the schematic's Module-layouts panel can show, per
    /// sub-module, that a rough placement has been seeded (vs. starred/done).
    rough: bool = false,
    /// Routed copper captured with the poses (null = never routed/saved).
    routes: ?SavedRoutes = null,
    /// User-drawn board outline captured with the poses (null = none drawn).
    outline: ?SavedOutline = null,
};

/// One persisted routed-copper segment of a saved layout. Field names match
/// the live route JSON (`l` layer, `w` width; net by NAME — net indices shift
/// across flattens), so the client draws stored and live copper identically.
/// `g` is the stamp group tag: copper stamped from a sub-block module layout
/// carries its group slug so a rigid-group drag moves it along instead of
/// invalidating it ("" = untagged hand-drawn / autorouted copper).
const SavedTrack = struct { x1: f64, y1: f64, x2: f64, y2: f64, l: u8 = 0, w: f64, net: []const u8 = "", g: []const u8 = "" };

/// One persisted via of a saved layout (same shape as the live route JSON).
const SavedVia = struct { x: f64, y: f64, d: f64, drill: f64 = 0, net: []const u8 = "", g: []const u8 = "" };

/// A saved layout's persisted copper — the routed tracks/vias captured with
/// the poses, so a Save → reload → Load round-trips the routing too.
const SavedRoutes = struct { tracks: []const SavedTrack, vias: []const SavedVia };

/// Shared JSON fragments for copper serialization — the sidecar, the page
/// blob, and the Stamp subroutes all write the identical track/via shape.
const TRACK_JSON_FMT = "{{\"x1\":{d},\"y1\":{d},\"x2\":{d},\"y2\":{d},\"l\":{d},\"w\":{d},\"net\":";
/// One outline-polygon vertex as a JSON `[x,y]` pair (sidecar + page blob).
const PT_PAIR_FMT = "[{d},{d}]";
const VIA_JSON_FMT = "{{\"x\":{d},\"y\":{d},\"d\":{d},\"drill\":{d},\"net\":";
const VIAS_ARR_OPEN = "],\"vias\":[";
/// "ref\x00pad" / "prefix\x00origin" composite hash keys.
const PIN_KEY_FMT = "{s}\x00{s}";

/// A user-DRAWN board outline (world mm) captured with a saved layout — the
/// interactive counterpart of the authored `(board (size W H))` form (the
/// ▭ Outline / ⬠ Poly tools: rough-place first, then draw the board around
/// it). When the shown layout carries one it becomes the placement's
/// `board_rect`, so every renderer draws it and the board-edge DRC checks it.
/// `pts` is the closed-polygon vertex list of a ⬠ Poly outline; when set,
/// x/y/w/h are always its bounding box (derived at parse time, so the two
/// can never disagree). Null `pts` = a plain drawn rectangle.
const SavedOutline = struct { x: f64, y: f64, w: f64, h: f64, pts: ?[]const [2]f64 = null };

/// Which layout state the page is showing — the precedence ladder made
/// visible in the scorebar chip: source **spec** > saved **snapshot**
/// (`?refine=`) > **starred** default > **cache** slot > **fresh** solve >
/// plain **grid**. `starred` is the design's ★-marked layout, loaded verbatim
/// as the default page view when nothing more specific is asked for.
const LayoutSource = enum { spec, snapshot, starred, cache, fresh, grid };

/// One chip in the scorebar naming where the shown layout came from, so
/// the precedence between the `(placement …)` spec, saved snapshots, and
/// the optimizer cache is visible instead of implicit.
fn writeSourceChip(w: *std.Io.Writer, src: LayoutSource) std.Io.Writer.Error!void {
    const label: []const u8, const cls: []const u8, const title: []const u8 = switch (src) {
        .spec => .{
            "from spec", "spec",
            "Placed by the (placement …) form in the source file — the source of truth. " ++
                "Saved snapshots and the cache are ignored while a spec is present.",
        },
        .snapshot => .{
            "from snapshot",                                                                         "snap",
            "Showing a saved layout snapshot (?refine=), refined in place. The cache is untouched.",
        },
        .starred => .{
            "★ default", "star",
            "Showing this design's starred (★) saved layout — the blessed reference, " ++
                "loaded verbatim as the default view. Regenerate re-solves; the star is set in the Layouts panel.",
        },
        .cache => .{
            "from cache", "cache",
            "Reusing the optimizer cache from the last solve (the \"cache\" slot of the " ++
                ".layouts.json sidecar). Regenerate re-solves; Save as spec promotes it to the source file.",
        },
        .fresh => .{
            "fresh solve",                                                                     "fresh",
            "Solved on this page load (Regenerate / tuning weights / per-sub-block preview).",
        },
        .grid => .{
            "no layout",                                                                    "grid",
            "Plain grid placeholder — no layout computed yet. Regenerate to auto-place.",
        },
    };
    try w.print("<span class=\"src-chip src-{s}\" id=\"pcb-srcchip\" title=\"{s}\">{s}</span>", .{ cls, title, label });
}

/// Name the rung of the precedence ladder the shown placement came from,
/// mirroring the selection logic at the top of `pcbLayoutPage`.
fn classifyLayoutSource(
    sub: ?[]const u8,
    grid_only: bool,
    spec_drives: bool,
    refine_name: ?[]const u8,
    starred_name: ?[]const u8,
    cached: ?[]const optimizer.RefPose,
) LayoutSource {
    if (sub != null) return .fresh;
    if (grid_only) return .grid;
    if (spec_drives) return .spec;
    if (refine_name != null and cached != null) return .snapshot;
    if (starred_name != null and cached != null) return .starred;
    if (cached != null) return .cache;
    return .fresh;
}

/// The page's resolved placement source: the spec/starred flags the scorebar
/// chip reads, plus the seed poses + grid fallback the solve uses. `verbatim`
/// means the poses are a user-saved layout and must render exactly as saved
/// (`placeFromPoses`), never through `solve`'s apply-or-re-solve ladder — a
/// hand layout with a courtyard overlap is still the user's layout, not a
/// stale cache to discard.
const LayoutChoice = struct {
    spec_drives: bool,
    starred_name: ?[]const u8,
    cached: ?[]const optimizer.RefPose,
    grid_only: bool,
    verbatim: bool,
};

/// Decide which placement `pcbLayoutPage` renders, walking the precedence ladder:
/// explicit `?refine=` snapshot > `(placement …)` spec > the design's starred (★)
/// default saved layout > the auto cache > a plain grid. A `?refine=` seed runs
/// the routed-tuck refine; every other seed (starred / cache) renders verbatim
/// via the `.place` mode. Sub-scoped previews never read a sidecar — they solve
/// fresh and cheap, so all four flags collapse to "solve from scratch".
fn chooseLayout(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    sub: ?[]const u8,
    eff_block: *env_mod.DesignBlock,
    refine_name: ?[]const u8,
    tune: Tuning,
) LayoutChoice {
    // No authored PCB-placement spec exists any more — the board always solves
    // via the force / starred-seed / cache ladder below.
    const spec_drives = false;
    // With no explicit ?refine=, no regen/tuning and no sub preview, default the
    // page to the design's starred (★) layout if it has one — the user's blessed
    // reference, shown verbatim as the seed below.
    const want_default = !(refine_name != null or tune.regen or tune.tuned or tune.show_cache);
    // A sub circuit seeds from its own per-sub sidecar (defaultLayoutName/
    // readLayoutPosesFor are sub-aware), so a starred sub layout shows verbatim on
    // reload just like a design's. Sub circuits have no auto-cache slot, so when
    // nothing is starred they solve fresh (never the plain-grid placeholder).
    const starred_name: ?[]const u8 = if (want_default)
        defaultLayoutName(alloc, project_dir, name, sub)
    else
        null;
    var cached = if (refine_name) |rn|
        readLayoutPosesFor(alloc, project_dir, name, rn, eff_block, sub)
    else if (starred_name) |sn|
        readLayoutPosesFor(alloc, project_dir, name, sn, eff_block, sub)
    else if (tune.regen) null else if (sub == null) readAutoPoses(alloc, project_dir, name) else null;
    // "Rough remaining" is a regen, but one seeded with a base to pin: the ★
    // layout preferred, else the auto cache. The solve locks what the base
    // covers and places only the uncovered parts (`Params.remaining`); with
    // no base at all it degrades to a plain fresh rough.
    if (tune.params.remaining and refine_name == null) {
        const star_base = if (defaultLayoutName(alloc, project_dir, name, sub)) |dn|
            readLayoutPosesFor(alloc, project_dir, name, dn, eff_block, sub)
        else
            null;
        const fallback = cached orelse (if (sub == null) readAutoPoses(alloc, project_dir, name) else null);
        cached = star_base orelse fallback;
    }
    // No layout to show and nothing asked for one: place the parts on a plain grid
    // instead of running the (potentially expensive) optimizer on page open.
    // (Sub circuits always solve fresh instead — there's no grid placeholder.)
    const grid_only = sub == null and refine_name == null and !tune.regen and cached == null;
    // A starred saved layout is the user's hand state: render it VERBATIM.
    // Routing it through `solve` would let `applyCached` reject it on any
    // courtyard overlap (normal mid-floor-planning, e.g. right after a Stamp)
    // and silently re-solve — the "I saved, refreshed, and my edits vanished" bug.
    const verbatim = starred_name != null and cached != null;
    return .{ .spec_drives = spec_drives, .starred_name = starred_name, .cached = cached, .grid_only = grid_only, .verbatim = verbatim };
}

/// Run the placement a resolved `LayoutChoice` calls for: the plain grid
/// placeholder, the saved layout verbatim (`placeFromPoses` — never re-solved,
/// even with courtyard overlaps), or a (possibly seeded) solve / refine.
fn placeForChoice(
    alloc: std.mem.Allocator,
    eff_block: *env_mod.DesignBlock,
    project_dir: []const u8,
    choice: LayoutChoice,
    refine_name: ?[]const u8,
    params: optimizer.Params,
) std.mem.Allocator.Error!optimizer.Placement {
    if (choice.grid_only) return optimizer.gridPlace(alloc, eff_block, project_dir, params);
    if (choice.verbatim) return optimizer.placeFromPoses(alloc, eff_block, project_dir, choice.cached.?, params);
    return optimizer.solve(alloc, eff_block, project_dir, choice.cached, params, if (refine_name != null) .refine else .place);
}

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
    const sub_block: ?env_mod.SubBlock = if (sub) |s|
        (descendToSub(ctx.allocator, block, s) orelse {
            res.status = 404;
            res.body = NO_SUB_MSG;
            return;
        })
    else
        null;
    const eff_block: *env_mod.DesignBlock = if (sub_block) |sb| sb.block else block;
    // Top-level DESIGNS keep exactly one layout ("the board") — no saved-
    // layouts panel, Save writes/overwrites the single starred snapshot.
    // Modules (and ?sub scoped sub circuits) keep the multi-layout panel:
    // a reusable block legitimately wants variants per use case.
    const single = module_res == null and sub == null;
    const embed = isEmbed(req);
    // `?embed=1&edit=1` is the editable embed: trimmed chrome (no navbar / left
    // properties sidebar / 3D), but the full action toolbar + saved-layouts panel
    // and drag-to-edit enabled — the schematic page's per-sub-circuit "PCB Layout"
    // toggle iframes this so a layout can be roughed / dragged / saved / starred in
    // place. It applies both to a module's own page (no `?sub`) and to a `?sub=`
    // scoped sub circuit; the latter persists its saved layouts to a per-sub
    // sidecar (`<design>.<sub>.layouts.json`) via the `sub`-aware save endpoints.
    const edit_embed = embed and queryFlag(req, "edit");

    // Tuning weights come from the query (?w_align=… etc) — any present (or
    // ?regen=1) forces a fresh solve; otherwise the cached layout is reused.
    // ?refine=<layout> seeds the solve from a named saved layout and runs only the
    // routed tuck on it (improve a hand layout in place; the auto cache is left as-is).
    // Sub-scoped previews never touch the design's layout sidecars: they compute
    // fresh each time (the sub-block is small, so this is cheap) so a scoped run
    // can't clobber the whole-design auto cache or its saved-layout history.
    const tune = parseTuning(req);
    const refine_name: ?[]const u8 = if (sub != null) null else if (req.query()) |q| q.get("refine") else |_| null;
    // Resolve which placement the page renders, per the precedence ladder (see
    // chooseLayout): explicit ?refine= snapshot > (placement …) spec > starred ★
    // default > auto cache > plain grid. ?refine= seeds a routed-tuck refine;
    // every other seed renders verbatim. Sub-scoped previews always solve fresh.
    const choice = chooseLayout(ctx.allocator, ctx.project_dir, name, sub, eff_block, refine_name, tune);
    const starred_name = choice.starred_name;
    const grid_only = choice.grid_only;
    var placement = placeForChoice(ctx.allocator, eff_block, ctx.project_dir, choice, refine_name, tune.params) catch {
        res.status = 500;
        res.body = PLACEMENT_ERR_MSG;
        return;
    };
    // Persist the layout + its weights whenever the optimizer ran (miss /
    // stale / regen / tune) — see persistGeneratedLayout.
    persistGeneratedLayout(ctx, name, placement, tune.params, sub, single);
    // Module-layout stamp poses for the Stamp palette — whole-design pages
    // only (a ?sub scoped page IS one sub-circuit already).
    const subseeds: SubSeedsJson = if (sub == null) buildSubSeedsJson(ctx.allocator, ctx.project_dir, eff_block, placement) else .{};
    const shown = if (sub != null or tune.tuned) tune.params else (readAutoParams(ctx.allocator, ctx.project_dir, name) orelse optimizer.Params{});

    // The named-layout history is a whole-design concept; scoped previews show none.
    // Deduplicated + best-score-first for the panel (see displayLayouts).
    const layouts = displayLayouts(ctx.allocator, ctx.project_dir, name, sub);

    // Fold the shown layout's persisted extras (drawn outline, saved copper)
    // into the placement and resolve routing/DRC — see resolveShownView.
    const rv = resolveShownView(ctx, req, &placement, layouts, if (sub == null) (refine_name orelse starred_name) else null);
    const ro = rv.ro;
    const routed = rv.routed;

    const view = View.init(placement);

    var aw: std.Io.Writer.Allocating = .init(ctx.allocator);
    const w = &aw.writer;

    try writeDocHead(w, eff_block.name, embed, edit_embed);
    if (!embed) try pages_tmpl.Navbar.render(.{""}, w);

    try w.writeAll("<div class=\"pcb-layout\">");
    // Cross-probe target for the sidebar's "Show in schematic" links: modules
    // render under /modules/, designs under /schematics/.
    const sch_base: []const u8 = if (module_res != null) "/modules/" else "/schematics/";
    if (!embed) try writeSidebar(w, placement, sch_base);
    try w.writeAll("<main class=\"pcb-main\">");
    const src_class = classifyLayoutSource(sub, grid_only, choice.spec_drives, refine_name, starred_name, choice.cached);
    if (embed and !edit_embed) {
        // Compact, read-only chrome for the per-sub-circuit preview embedded in
        // the schematic page: a score line plus the routed-status + show
        // clearance/DRC toggles (initial state mirrors the page's globals).
        const tg = parseToggles(req);
        try writeEmbedBar(w, if (sub_block) |sb| sb.source else "");
        try writeEmbedRoute(w, ro.params, routed, rv.violations.len, tg.clr, tg.drc);
    } else {
        // Header row: title + the Schematic ⇄ PCB Layout switcher (PCB active).
        // `name` resolves as a design under src/ first, else a reusable module —
        // so the Schematic link points at the matching viewer. The editable embed
        // skips this header (the parent card carries its own Schematic/PCB toggle)
        // but keeps the full editing toolbar that follows.
        if (!embed) {
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
        }
        try writeEditControls(w, placement, name, src_class, grid_only, routed, shown, ro.params, rv.violations.len, single);
    }
    if (embed and !edit_embed) try writeLegend(w, placement, false);
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
    // buttons. Shown on the full page and in the editable embed (so a module's
    // layout can be loaded / starred there); omitted in the read-only preview.
    const show_panel = !single and (!embed or edit_embed);
    if (show_panel) {
        const auto_score = LayoutScore{
            .hpwl = placement.score.hpwl_mm,
            .loop = placement.score.loop_mm,
            .caps = placement.score.loop_caps,
            .objective = placement.breakdown.objective,
        };
        try w.writeAll("<aside class=\"pcb-rside\">");
        try writeLayoutsPanel(w, layouts, auto_score, placement);
        try w.writeAll("</aside>");
    }
    try w.writeAll("</div>");
    try writePcbData(
        w,
        ctx.allocator,
        ctx.project_dir,
        placement,
        shown,
        view,
        name,
        layouts,
        routed,
        ro.params.clearance,
        rv.violations,
        .{
            .read_only = embed and !edit_embed,
            .embed = embed,
            .sub = sub,
            .subseeds_json = subseeds.poses,
            .subseedinfo_json = subseeds.info,
            .submodules_json = subseeds.mods,
            .outline_drawn = rv.outline_drawn,
            .single = single,
            .saved_routes = rv.saved,
            .subroutes_json = subseeds.routes,
        },
    );
    // Shared footprint engine (FP.padShape) must load before the board script
    // runs. Both scripts come after every column so the handlers find the
    // elements they wire, and after the inline `const PCB=…` data block so the
    // external board script (a classic <script>, executed in DOM order) reads it.
    try w.writeAll("<script src=\"/static/footprint_svg.js\"></script>");
    try w.writeAll("<script src=\"/static/pcb_board.js\"></script>");
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
) ?env_mod.SubBlock {
    for (block.sub_blocks) |sb| {
        const slug = review.slugify(allocator, sb.name) catch continue;
        if (std.mem.eql(u8, slug, sub_slug)) return sb;
    }
    return null;
}

/// Persist a freshly generated layout + its weights (auto cache + the named
/// history), so later loads are instant and the controls show the weights
/// that actually produced the layout on screen. Scoped sub-block runs skip
/// this — there's no sidecar key for an individual sub-block yet. A `single`
/// (top-level design) page keeps exactly ONE saved layout, so it writes the
/// cache slot only — never an "auto · …" history row alongside it.
fn persistGeneratedLayout(ctx: *Handler, name: []const u8, placement: optimizer.Placement, params: optimizer.Params, sub: ?[]const u8, single: bool) void {
    if (sub != null or !placement.generated) return;
    writeAutoCache(ctx.allocator, ctx.project_dir, name, placement, params);
    if (!single) recordAutoLayout(ctx.allocator, ctx.project_dir, name, placement, params);
}

/// The Stamp palette's seed blobs: `poses` maps each sub-block's parent-frame
/// ref-des → its module-layout pose, `info` maps each sub-block name → which
/// module snapshot supplied the poses (`{layout, starred, n}`) so the button
/// can say what a Stamp will pull and how much of the group it covers, and
/// `mods` maps every sub-block name → its module source (palette name links).
const SubSeedsJson = struct { poses: []const u8 = "{}", info: []const u8 = "{}", mods: []const u8 = "{}", routes: []const u8 = "{}" };

/// JSON map of sub-block name → module source ("mcu" → "w55rp20"), for the
/// palette's name links to each module's own /pcb-layout page — emitted for
/// every sub-block, including ones with no stampable layout yet (that page is
/// exactly where you go to make one).
fn buildSubModulesJson(alloc: std.mem.Allocator, block: *const env_mod.DesignBlock) []const u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    w.writeByte('{') catch return "{}";
    var first = true;
    for (block.sub_blocks) |sb| {
        if (sb.source.len == 0) continue;
        if (!first) w.writeByte(',') catch return "{}";
        first = false;
        writeJsonStr(w, sb.name) catch return "{}";
        w.writeByte(':') catch return "{}";
        writeJsonStr(w, sb.source) catch return "{}";
    }
    w.writeByte('}') catch return "{}";
    return aw.written();
}

/// Build the viewer's per-group "Stamp" seeds — drop a whole pre-laid
/// sub-circuit onto the board as a rigid cluster instead of laying its parts
/// out again. Built through the same origin_key bridge the KiCad sync seeds
/// from (subBlockPoseByOriginKey), so the poses match what a sync would stamp.
/// Both blobs are "{}" when nothing bridges.
fn buildSubSeedsJson(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    block: *const env_mod.DesignBlock,
    p: optimizer.Placement,
) SubSeedsJson {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    var iw_buf: std.Io.Writer.Allocating = .init(alloc);
    const iw = &iw_buf.writer;
    var rw_buf: std.Io.Writer.Allocating = .init(alloc);
    const rw = &rw_buf.writer;
    w.writeByte('{') catch return .{};
    iw.writeByte('{') catch return .{};
    rw.writeByte('{') catch return .{};
    var first = true;
    var ifirst = true;
    var rfirst = true;
    // Lazily-built parent "ref\x00pad" → net-name map (only when some module
    // snapshot actually carries copper to stamp).
    var dpin_net: ?std.StringHashMap([]const u8) = null;
    for (block.sub_blocks) |sb| {
        var s = subBlockPoseByOriginKey(alloc, project_dir, sb) orelse continue;
        var ok_ref = std.StringHashMap([]const u8).init(alloc);
        var n: usize = 0;
        for (p.instances) |inst| {
            if (inst.ref_des.len <= sb.name.len) continue;
            if (!std.mem.startsWith(u8, inst.ref_des, sb.name) or inst.ref_des[sb.name.len] != '/') continue;
            if (inst.origin_key.len == 0) continue;
            const pose = s.map.get(inst.origin_key) orelse continue;
            ok_ref.put(inst.origin_key, inst.ref_des) catch return .{};
            if (!first) w.writeByte(',') catch return .{};
            first = false;
            n += 1;
            writeJsonStr(w, inst.ref_des) catch return .{};
            w.print(":{{\"x\":{d},\"y\":{d},\"rot\":{d}", .{ pose.x, pose.y, pose.rot }) catch return .{};
            if (pose.side == .bottom) w.writeAll(",\"side\":\"bottom\"") catch return .{};
            w.writeByte('}') catch return .{};
        }
        if (n == 0) continue;
        if (!ifirst) iw.writeByte(',') catch return .{};
        ifirst = false;
        writeJsonStr(iw, sb.name) catch return .{};
        iw.writeAll(":{\"layout\":") catch return .{};
        writeJsonStr(iw, s.layout_name) catch return .{};
        iw.print(",\"starred\":{},\"n\":{d}", .{ s.starred, n }) catch return .{};
        if (s.alt_name.len > 0) {
            iw.writeAll(",\"alt\":") catch return .{};
            writeJsonStr(iw, s.alt_name) catch return .{};
            iw.print(",\"alt_n\":{d}", .{s.alt_n}) catch return .{};
        }
        iw.writeByte('}') catch return .{};
        // The snapshot's copper, net names mapped onto this design's nets so
        // Stamp can carry the module's hand routing onto the board.
        if (s.routes) |sr| {
            if (dpin_net == null) dpin_net = designPinNetMap(alloc, p);
            const dm = if (dpin_net) |*m| m else continue;
            if (!rfirst) rw.writeByte(',') catch return .{};
            rfirst = false;
            writeJsonStr(rw, sb.name) catch return .{};
            rw.writeByte(':') catch return .{};
            writeSubRoutesJson(rw, alloc, sb.name, sr, s.pin_nets, &ok_ref, dm) catch return .{};
        }
    }
    w.writeByte('}') catch return .{};
    iw.writeByte('}') catch return .{};
    rw.writeByte('}') catch return .{};
    return .{
        .poses = aw.written(),
        .info = iw_buf.written(),
        .mods = buildSubModulesJson(alloc, block),
        .routes = rw_buf.written(),
    };
}

/// Parent placement "ref\x00pad" → net NAME (raw flattened names, matching
/// the net names routed copper carries). Null on allocation failure.
fn designPinNetMap(alloc: std.mem.Allocator, p: optimizer.Placement) ?std.StringHashMap([]const u8) {
    var m = std.StringHashMap([]const u8).init(alloc);
    for (p.nets) |net| {
        for (net.pins) |pin| {
            const key = std.fmt.allocPrint(alloc, PIN_KEY_FMT, .{ pin.ref_des, pin.pin }) catch return null;
            m.put(key, net.name) catch return null;
        }
    }
    return m;
}

/// Serialize one module snapshot's copper for the Stamp palette: coordinates
/// stay module-local (the same frame as the seed poses — the client
/// translates by the stamp offset), net names are mapped module → parent via
/// the origin-key bridge, falling back to the "slug/NET" spelling a
/// module-private net flattens to in the parent anyway.
fn writeSubRoutesJson(
    w: *std.Io.Writer,
    alloc: std.mem.Allocator,
    slug: []const u8,
    sr: SavedRoutes,
    pin_nets: []const SubPinNet,
    ok_ref: *const std.StringHashMap([]const u8),
    dpin_net: *const std.StringHashMap([]const u8),
) std.Io.Writer.Error!void {
    var net_map = std.StringHashMap([]const u8).init(alloc);
    for (pin_nets) |ps| {
        if (net_map.contains(ps.net)) continue;
        const dref = ok_ref.get(ps.origin_key) orelse continue;
        const key = std.fmt.allocPrint(alloc, PIN_KEY_FMT, .{ dref, ps.pad }) catch continue;
        const dn = dpin_net.get(key) orelse continue;
        net_map.put(ps.net, dn) catch break;
    }
    try w.writeAll("{\"tracks\":[");
    for (sr.tracks, 0..) |t, i| {
        if (i > 0) try w.writeAll(",");
        try w.print(TRACK_JSON_FMT, .{ t.x1, t.y1, t.x2, t.y2, t.l, t.w });
        try writeJsonStr(w, mappedNet(alloc, &net_map, slug, t.net));
        try w.writeAll("}");
    }
    try w.writeAll(VIAS_ARR_OPEN);
    for (sr.vias, 0..) |vi, i| {
        if (i > 0) try w.writeAll(",");
        try w.print(VIA_JSON_FMT, .{ vi.x, vi.y, vi.d, vi.drill });
        try writeJsonStr(w, mappedNet(alloc, &net_map, slug, vi.net));
        try w.writeAll("}");
    }
    try w.writeAll("]}");
}

/// A stamped-copper net name in the parent design's namespace: the bridged
/// parent net when a module pin on the net resolved, else "slug/NET" (the
/// flatten's stitching spelling for a module-private net), else "".
fn mappedNet(
    alloc: std.mem.Allocator,
    net_map: *const std.StringHashMap([]const u8),
    slug: []const u8,
    net: []const u8,
) []const u8 {
    if (net.len == 0) return "";
    if (net_map.get(net)) |m| return m;
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ slug, net }) catch net;
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
    // Match the page: with nothing more specific asked for, default to the design's
    // starred (★) saved layout if it has one, so this JSON twin describes the same
    // board the page shows.
    const want_default = !(refine_name != null or tune.regen or tune.tuned or tune.show_cache);
    const starred_name: ?[]const u8 = if (want_default)
        defaultLayoutName(ctx.allocator, ctx.project_dir, name, null)
    else
        null;
    const cached = if (refine_name) |rn|
        readLayoutPosesFor(ctx.allocator, ctx.project_dir, name, rn, block, null)
    else if (starred_name) |sn|
        readLayoutPosesFor(ctx.allocator, ctx.project_dir, name, sn, block, null)
    else if (tune.regen) null else readAutoPoses(ctx.allocator, ctx.project_dir, name);
    // Starred = the user's saved hand layout: verbatim, same as the page (see
    // chooseLayout — `solve` would re-solve it away on any courtyard overlap).
    const placement = (if (starred_name != null and cached != null)
        optimizer.placeFromPoses(ctx.allocator, block, ctx.project_dir, cached.?, tune.params)
    else
        optimizer.solve(ctx.allocator, block, ctx.project_dir, cached, tune.params, if (refine_name != null) .refine else .place)) catch {
        res.status = 500;
        res.body = PLACEMENT_ERR_MSG;
        return;
    };
    if (placement.generated) writeAutoCache(ctx.allocator, ctx.project_dir, name, placement, tune.params);
    const shown = if (tune.tuned) tune.params else (readAutoParams(ctx.allocator, ctx.project_dir, name) orelse optimizer.Params{});

    // Per-part objective blame for the findings sidecar (index-aligned w/ parts).
    const blame = try req.arena.alloc(f64, placement.parts.len);
    optimizer.perPartBlame(placement, shown, blame);

    // Optional `?route=1`: route the board and summarise the real copper so layouts
    // are directly comparable (trace length, via count, DRC) without scraping HTML.
    const ro = parseRoute(req);
    const routed_metrics: ?RoutedMetrics = if (ro.run) blk: {
        const r = router.route(ctx.allocator, placement, ro.params) catch break :blk null;
        const v = drc.check(ctx.allocator, placement, r, ro.params.clearance) catch &.{};
        var trace: f64 = 0;
        for (r.tracks) |t| trace += std.math.hypot(t.x2 - t.x1, t.y2 - t.y1);
        break :blk .{ .trace_mm = trace, .tracks = r.tracks.len, .vias = r.vias.len, .drc = v.len, .routed = r.routed, .total = r.total, .unrouted = r.failed };
    } else null;

    var aw: std.Io.Writer.Allocating = .init(ctx.allocator);
    try writePlacementJson(&aw.writer, placement, shown, name, blame, routed_metrics);
    res.content_type = .JSON;
    res.body = aw.written();
}

/// Summary of a routed board for the JSON API (`?route=1`): total copper length,
/// track/via counts, DRC-violation count, net-completion counts, and the names
/// of the nets that failed — the machine-readable comparison key.
const RoutedMetrics = struct {
    trace_mm: f64,
    tracks: usize,
    vias: usize,
    drc: usize,
    routed: usize = 0,
    total: usize = 0,
    unrouted: []const []const u8 = &.{},
};

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
    /// Experimental courtyard-overlap allowance (mm); 0 = touch only (default).
    court_overlap: f64 = 0,
    /// Routing/copper room between courtyards (mm); 0 = touch (default).
    route_gap: f64 = 0,
    /// Functional-group cohesion / zoning / bank-loop-relief tuning knobs
    /// (negative ⇒ "unset", keep the optimizer default).
    group_w: f64 = -1,
    group_zone_w: f64 = -1,
    group_loop_relief: f64 = -1,
    /// Constructive zone-then-pack floorplan (crisp VIN│IC│L│VOUT rows).
    zone_pack: bool = false,
    /// "Rough remaining": pin what the base layout (★ else auto cache) covers,
    /// rough-place only the uncovered parts (`Params.remaining`).
    remaining: bool = false,
    /// Rough hierarchical / pad-anchored seed (`?rough=1`): cluster each module
    /// into a rigid block, or — for a flat module — ring the anchor IC with each
    /// passive on the side of the pad it serves. A legible, module-intact start
    /// (the `Params.rough` path in the optimizer), deliberately not metric-optimal.
    rough: bool = false,
    /// Diagnostic overlays (see render_pcb_png.Options).
    blame: bool = false,
    loop_labels: bool = false,
    dims: bool = false,
    grid: bool = false,
    /// Saved-layout name to diff the current placement against.
    compare: ?[]const u8 = null,
    /// Part-name labelling (`?names=ref|origin|both`). Null = auto: origin
    /// names when a `(placement …)` spec drives the solve (so the image speaks
    /// the spec's vocabulary), ref-des otherwise.
    names: ?render_pcb_png.NameMode = null,
    /// Parts whose pads get net-name labels (`?pins=U13,C5`; "hubs" = all hubs).
    pins: []const []const u8 = &.{},
    /// Crop the viewport around this part (`?crop=U1`), radius `?r=<mm>`.
    crop: ?[]const u8 = null,
    crop_r: f64 = 6,
    /// Contact sheet (`?sheet=1`): whole board + per-hub pin-labeled closeups.
    sheet: bool = false,
    /// Callout overlay (`?critique=1`): numbered worst-problem markers + panel.
    critique: bool = false,
};

/// Failures `renderDesignPng` surfaces; callers map these to an HTTP status or
/// MCP error message.
pub const PngError = error{ BlockNotFound, SubNotFound, BuildFailed } || png_mod.Error;

/// Resolve `name`, build (or load from cache) its placement, optionally route
/// it, and render a PNG — shared by the HTTP endpoint and the MCP tool. All
/// A solved placement plus the request context the PNG and describe endpoints
/// share — both views must show the *same* board. `placement` references block
/// memory owned by the caller's `eval`/`module_res`, so those must outlive it.
pub const SolvedRequest = struct {
    placement: optimizer.Placement,
    spec_status: ?render_pcb_png.SpecStatus,
    params: optimizer.Params,
    title: []const u8,
    /// The (possibly sub-scoped) design block the placement was solved from —
    /// callers needing a second solve (e.g. the compare overlay) reuse it.
    block: *env_mod.DesignBlock,
};

/// Resolve `name` and apply the request's placement-selection rules: a named
/// `?layout=` renders verbatim, `?regen` forces a fresh solve, `?rough` re-seeds
/// the rough engine, otherwise the design's starred (★) saved layout is shown if
/// it has one (so the PNG / describe / MCP views match the /pcb-layout page),
/// else the auto cache — falling back to a plain grid when nothing is cached so
/// an agent's first call stays cheap. A fresh solve uses the rough engine (the
/// default top-level placer); the `?rough` flag is now redundant with that.
pub fn solveForRequest(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    opts: PngRequest,
    eval: *Evaluator,
    module_res: *?modules_mod.ResolvedBlock,
) PngError!SolvedRequest {
    const block = resolveBlock(alloc, project_dir, name, eval, module_res) orelse return error.BlockNotFound;
    const eff_block: *env_mod.DesignBlock = if (opts.sub) |s|
        (descendToSub(alloc, block, s) orelse return error.SubNotFound).block
    else
        block;

    // With nothing more specific asked for (no ?layout=, no ?regen, no ?rough,
    // not sub-scoped), default to the design's starred (★) saved layout — the
    // same blessed board the /pcb-layout page and its JSON twin show — so the
    // PNG / describe / MCP views describe what the user sees, not a stale auto
    // cache. The layout_match rough/starred probes pass ?rough / ?layout and so
    // skip this, keeping their own seeds.
    const want_default = opts.sub == null and opts.layout == null and !opts.regen and !opts.rough and !opts.remaining;
    const starred_name: ?[]const u8 = if (want_default)
        defaultLayoutName(alloc, project_dir, name, null)
    else
        null;
    var cached = if (opts.sub != null) null else if (opts.layout) |ln|
        readLayoutPosesFor(alloc, project_dir, name, ln, eff_block, null)
    else if (starred_name) |sn|
        readLayoutPosesFor(alloc, project_dir, name, sn, eff_block, null)
    else if (opts.regen) null else readAutoPoses(alloc, project_dir, name);
    // "Rough remaining": a fresh solve seeded with the ★ (else the auto cache)
    // as its pinned base — the solve locks what it covers, places only the
    // rest. The ★ is preferred explicitly: without this, an existing auto
    // cache (some earlier rough) would win and get pinned instead.
    if (opts.remaining and opts.sub == null and opts.layout == null) {
        const star_base = if (defaultLayoutName(alloc, project_dir, name, null)) |dn|
            readLayoutPosesFor(alloc, project_dir, name, dn, eff_block, null)
        else
            null;
        cached = star_base orelse (cached orelse readAutoPoses(alloc, project_dir, name));
    }
    const grid_only = opts.sub == null and opts.layout == null and !opts.regen and cached == null;
    var params = optimizer.Params{ .courtyard_overlap = opts.court_overlap, .route_gap = opts.route_gap };
    if (opts.group_w >= 0) params.group_w = opts.group_w;
    if (opts.group_zone_w >= 0) params.group_zone_w = opts.group_zone_w;
    if (opts.group_loop_relief >= 0) params.group_loop_relief = opts.group_loop_relief;
    if (opts.zone_pack) params.zone_pack = true;
    if (opts.remaining) params.remaining = true;
    // Rough is the default top-level engine — a fresh solve always seeds rough.
    // (`?rough` is now redundant with this; left functional as a harmless alias.)
    params.rough = true;
    // A named saved layout OR the starred default renders VERBATIM
    // (placeFromPoses) — "show me this layout" must display exactly what was
    // saved, not a re-optimized version: refine can drift a hand-tuned layout
    // to a worse arrangement (e.g. a 70.8 hand layout relaxing back to 86
    // because it isn't a relax fixed-point), and `solve` discards any saved
    // layout with a courtyard overlap outright (applyCached's staleness test).
    var placement = (if ((opts.layout != null or starred_name != null) and cached != null)
        optimizer.placeFromPoses(alloc, eff_block, project_dir, cached.?, params)
    else if (grid_only)
        optimizer.gridPlace(alloc, eff_block, project_dir, params)
    else
        optimizer.solve(alloc, eff_block, project_dir, cached, params, .place)) catch return error.BuildFailed;
    // Fold the shown saved layout's user-drawn outline (rectangle or polygon)
    // onto the placement, exactly like the /pcb-layout page does — the PNG /
    // describe / MCP views must show the same board edge the viewer and the
    // fab outputs use.
    if (opts.layout orelse starred_name) |sn| {
        if (opts.sub == null)
            _ = applyShownOutline(&placement, readLayouts(alloc, project_dir, name), sn);
    }

    // Staging coverage from the solve just above (same thread): parts the
    // `(board …)` edge-dock / force path left in the band and the ones autofill
    // pulled back out. Reported so the image hatches staged parts in red.
    const diag = optimizer.placementDiag();
    const spec_status: ?render_pcb_png.SpecStatus = if (diag.unplaced.len > 0 or diag.auto_filled.len > 0)
        .{ .unplaced = diag.unplaced, .auto_filled = diag.auto_filled }
    else
        null;
    return .{ .placement = placement, .spec_status = spec_status, .params = params, .title = eff_block.name, .block = eff_block };
}

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
    const solved = try solveForRequest(alloc, project_dir, name, opts, &eval, &module_res);
    const placement = solved.placement;
    const spec_status = solved.spec_status;
    const png_params = solved.params;
    // Auto name mode: a spec-driven image speaks the spec's vocabulary.
    const name_mode = opts.names orelse
        (if (spec_status != null) render_pcb_png.NameMode.origin else render_pcb_png.NameMode.ref);

    const route_params = router.RouteParams{};
    const routed: ?router.RouteResult = if (opts.route) (router.route(alloc, placement, route_params) catch null) else null;
    const violations: []const drc.Violation = if (routed) |r|
        (drc.check(alloc, placement, r, route_params.clearance) catch &.{})
    else
        &.{};

    // Optional compare layout for the diff overlay (ghost + movement arrows).
    var cmp_placement: ?optimizer.Placement = null;
    if (opts.compare) |cn| {
        if (readLayoutPosesFor(alloc, project_dir, name, cn, solved.block, opts.sub)) |cposes| {
            cmp_placement = optimizer.placeFromPoses(alloc, solved.block, project_dir, cposes, png_params) catch null;
        }
    }

    const ropts = render_pcb_png.Options{
        .width = opts.width,
        .highlight_nets = opts.highlight_nets,
        .highlight_refs = opts.highlight_refs,
        .routed = routed,
        .violations = violations,
        .title = solved.title,
        .params = png_params,
        .blame = opts.blame,
        .loop_labels = opts.loop_labels,
        .dims = opts.dims,
        .grid = opts.grid,
        .compare = cmp_placement,
        .names = name_mode,
        .pin_refs = opts.pins,
        .spec = spec_status,
        .crop = opts.crop,
        .crop_r = opts.crop_r,
        .critique = opts.critique,
    };
    if (opts.sheet) return render_pcb_png.renderSheet(alloc, placement, ropts);
    return render_pcb_png.render(alloc, placement, ropts);
}

/// Parse a `PngRequest` from an HTTP query string — shared by the PNG endpoint
/// and `/api/pcb-describe` so both accept the identical parameter set (and so
/// the facts always describe the placement the image shows).
pub fn pngRequestFromQuery(arena: std.mem.Allocator, req: *httpz.Request) PngRequest {
    const width: u32 = blk: {
        const q = req.query() catch break :blk PNG_DEFAULT_WIDTH;
        const wv = q.get("width") orelse break :blk PNG_DEFAULT_WIDTH;
        break :blk std.fmt.parseInt(u32, wv, 10) catch PNG_DEFAULT_WIDTH;
    };
    return .{
        .width = width,
        .highlight_nets = csvParam(arena, req, "nets"),
        .highlight_refs = csvParam(arena, req, "refs"),
        .route = queryFlag(req, "route"),
        .layout = queryOpt(req, "layout"),
        .regen = queryFlag(req, "regen"),
        .sub = subSlug(req),
        .court_overlap = blk: {
            const q = req.query() catch break :blk 0;
            const v = q.get("court_overlap") orelse break :blk 0;
            break :blk std.fmt.parseFloat(f64, v) catch 0;
        },
        .route_gap = blk: {
            const q = req.query() catch break :blk 0;
            const v = q.get("route_gap") orelse break :blk 0;
            break :blk std.fmt.parseFloat(f64, v) catch 0;
        },
        .group_w = pngFloatOpt(req, "group_w"),
        .group_zone_w = pngFloatOpt(req, "group_zone_w"),
        .group_loop_relief = pngFloatOpt(req, "group_loop_relief"),
        .zone_pack = queryFlag(req, "zone_pack"),
        .rough = queryFlag(req, "rough"),
        .remaining = queryFlag(req, "remaining"),
        .blame = queryFlag(req, "blame"),
        .loop_labels = queryFlag(req, "loops"),
        .dims = queryFlag(req, "dims"),
        .grid = queryFlag(req, "grid"),
        .compare = queryOpt(req, "compare"),
        .names = blk: {
            const v = queryOpt(req, "names") orelse break :blk null;
            break :blk std.meta.stringToEnum(render_pcb_png.NameMode, v);
        },
        .pins = csvParam(arena, req, "pins"),
        .crop = queryOpt(req, "crop"),
        .crop_r = blk: {
            const q = req.query() catch break :blk 6;
            const v = q.get("r") orelse break :blk 6;
            break :blk std.fmt.parseFloat(f64, v) catch 6;
        },
        .sheet = queryFlag(req, "sheet"),
        .critique = queryFlag(req, "critique"),
    };
}

/// GET /api/pcb-png/:name — render the solved layout as a PNG so an AI agent (or
/// any HTTP client) can *see* it, not just parse the coordinate JSON.
///
/// Query parameters (all optional):
///   width=<px>            output width (clamped); height follows the board
///   nets=A,B  refs=U1,C3  focus mode — spotlight these nets/components, dim rest
///   route=1               run the router and draw copper + DRC markers
///   layout=<name>         render a specific saved layout (else the starred ★
///                         default if set, else the auto cache)
///   regen=1               force a fresh solve instead of the cache
///   sub=<slug>            scope to one sub-block (per-sub-block preview)
///   names=ref|origin|both part labels: ref-des, spec origin name, or REF=ORIGIN
///                         (default: origin when a (placement …) spec drives)
///   pins=U13,C5           label these parts' pads with net names ("hubs" = all)
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
    const opts = pngRequestFromQuery(arena, req);
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

/// Query `key` as a float, or -1 when absent/unparseable — the "unset" sentinel
/// the PNG path uses to keep the optimizer's own default for a group knob.
fn pngFloatOpt(req: *httpz.Request, key: []const u8) f64 {
    const q = req.query() catch return -1;
    const v = q.get(key) orelse return -1;
    return std.fmt.parseFloat(f64, v) catch -1;
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
/// World position (mm) of a footprint-local pad on a placed part.
fn worldPad(pt: optimizer.Part, pad: optimizer.PadRect) [2]f64 {
    const a = pt.rot * std.math.pi / 180.0;
    const c = @cos(a);
    const s = @sin(a);
    return .{ pt.x + pad.x * c - pad.y * s, pt.y + pad.x * s + pad.y * c };
}

/// Layout JSON + a `findings` sidecar: each part's normalized objective `blame`
/// (0–1, the render heatmap value) and a `loops` list (per decoupling loop:
/// cap, hub, inductance nH, and power-leg length mm) — the machine-readable twin
/// of the PNG diagnostic overlays, so an agent gets precise numbers, not pixels.
/// `blame` is index-aligned with `p.parts` (empty ⇒ all zero).
fn writePlacementJson(w: *std.Io.Writer, p: optimizer.Placement, params: optimizer.Params, name: []const u8, blame: []const f64, routed: ?RoutedMetrics) std.Io.Writer.Error!void {
    const b = p.breakdown;
    var bmax: f64 = 0;
    for (blame) |v| bmax = @max(bmax, v);
    try w.writeAll(NAME_OPEN);
    try writeJsonStr(w, name);
    try w.print(",\"generated\":{s},", .{if (p.generated) "true" else "false"});
    try w.print("\"params\":{{\"loop_w\":{d},\"w_align\":{d},\"w_congest\":{d},\"cap_w_max\":{d},\"grid\":{s}}},", .{
        params.loop_w,                                   optimizer.effAlignW(params), params.w_congest, params.cap_w_max,
        if (params.grid_courtyards) "true" else "false",
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
        if (i < p.instances.len) {
            try w.writeAll(ORIGIN_OPEN);
            try writeJsonStr(w, p.instances[i].origin_key);
        }
        const bl = if (i < blame.len and bmax > 0) blame[i] / bmax else 0;
        try w.print(",\"kind\":\"{s}\",\"x\":{d},\"y\":{d},\"rot\":{d},\"hw\":{d},\"hh\":{d},\"fallback\":{s},\"blame\":{d:.3}", .{
            if (pt.kind == .hub) "hub" else "passive",
            pt.x,
            pt.y,
            pt.rot,
            pt.hw,
            pt.hh,
            if (pt.fallback) "true" else "false",
            bl,
        });
        if (pt.ccx != 0 or pt.ccy != 0) try w.print(",\"ccx\":{d},\"ccy\":{d}", .{ pt.ccx, pt.ccy });
        try writePoseSideLocked(w, pt.side, pt.locked);
        try w.writeAll("}");
    }
    try w.writeAll("],\"loops\":[");
    for (p.loops, 0..) |L, i| {
        if (i > 0) try w.writeAll(",");
        const cap = p.parts[L.cap];
        const hub = p.parts[L.hub];
        const cw = worldPad(cap, L.cap_pwr);
        const hp = worldPad(hub, L.hub_pwr_pin);
        const leg = std.math.hypot(cw[0] - hp[0], cw[1] - hp[1]);
        try w.writeAll("{\"cap\":");
        try writeJsonStr(w, cap.ref_des);
        try w.writeAll(",\"hub\":");
        try writeJsonStr(w, hub.ref_des);
        try w.print(",\"nh\":{d:.3},\"leg_mm\":{d:.3}}}", .{ optimizer.loopNh(p.parts, L), leg });
    }
    try w.writeAll("]");
    if (routed) |r| {
        try w.print(
            ",\"routed\":{{\"trace_mm\":{d:.1},\"tracks\":{d},\"vias\":{d},\"drc\":{d},\"routed\":{d},\"total\":{d},\"unrouted\":[",
            .{ r.trace_mm, r.tracks, r.vias, r.drc, r.routed, r.total },
        );
        for (r.unrouted, 0..) |name_s, i| {
            if (i > 0) try w.writeAll(",");
            try writeJsonStr(w, name_s);
        }
        try w.writeAll("]}");
    }
    // Report any parts the solve left staged below the board (the `(board …)`
    // edge-dock / force path) and the ones autofill pulled back out. Read straight
    // from the optimizer's per-solve thread-local — set during the `solve` above.
    const pl = optimizer.placementDiag();
    if (pl.unplaced.len > 0 or pl.auto_filled.len > 0) {
        try w.writeAll(",\"placement\":{\"unplaced\":[");
        for (pl.unplaced, 0..) |ref, i| {
            if (i > 0) try w.writeAll(",");
            try writeJsonStr(w, ref);
        }
        try w.writeAll("],\"auto_filled\":[");
        for (pl.auto_filled, 0..) |ref, i| {
            if (i > 0) try w.writeAll(",");
            try writeJsonStr(w, ref);
        }
        try w.writeAll("]}");
    }
    try w.writeAll("}");
}

/// Emit the objective `breakdown` as a JSON object: the raw terms, each term's
/// weighted contribution, and the summed `objective`. Shared by the GET export
/// and the POST score endpoint so both report the same shape.
fn writeBreakdownJson(w: *std.Io.Writer, b: optimizer.Breakdown, params: optimizer.Params) std.Io.Writer.Error!void {
    try w.writeByte('{');
    try writeBreakdownFields(w, b, params);
    try w.writeByte('}');
}

/// The breakdown's fields with no enclosing braces, so the score endpoint can
/// splice an extra `"blame"` map into the same object for the live Heatmap.
fn writeBreakdownFields(w: *std.Io.Writer, b: optimizer.Breakdown, params: optimizer.Params) std.Io.Writer.Error!void {
    try w.print("\"hpwl\":{d},\"loop_raw\":{d},\"loop_weighted\":{d},\"loop_nh\":{d},\"loop_nh_weighted\":{d},", .{
        b.hpwl, b.loop_raw, b.loop_weighted, b.loop_nh, b.loop_nh_weighted,
    });
    try w.print("\"alignment\":{d},\"footprint\":{d},\"congestion\":{d},", .{ b.alignment, b.footprint, b.congestion });
    try w.print("\"loop_term\":{d},\"alignment_term\":{d},\"congestion_term\":{d},\"objective\":{d}", .{
        params.loop_w * b.loop_nh_weighted, optimizer.effAlignW(params) * b.alignment, params.w_congest * b.congestion, b.objective,
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

        // "Rough remaining": pin the base layout (★ else auto cache) and place
        // only the parts it doesn't cover.
        const cached: ?[]const optimizer.RefPose = if (job.params.remaining) blk: {
            if (defaultLayoutName(a, job.project_dir, job.name, null)) |dn| {
                if (readLayoutPosesFor(a, job.project_dir, job.name, dn, block, null)) |ps| break :blk ps;
            }
            break :blk readAutoPoses(a, job.project_dir, job.name);
        } else null;
        const placement = optimizer.solve(a, block, job.project_dir, cached, job.params, .place) catch break :run;
        if (placement.generated) {
            writeAutoCache(a, job.project_dir, job.name, placement, job.params);
            recordAutoLayout(a, job.project_dir, job.name, placement, job.params);
        }
        had_err = false;
    }
    serve_root.pcbJobFinish(job.name, job.gen, if (had_err) .failed else .ok);
}

/// POST /api/pcb-regen-start/:name — kick off a live (background) optimizer run
/// and return its generation id. The browser then polls /api/pcb-progress/:name
/// to animate the board converging and reloads when the run finishes. Honours the
/// same tuning query (?w_align / loop_w / w_congest / grid) as ?regen=1.
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
    // Everything here is request-scoped; use req.arena (reclaimed after the
    // response is sent) — NOT ctx.allocator (the global page_allocator, never
    // freed: an agent hammering this endpoint for a layout search would OOM the
    // server, since each call allocates the parsed design + full scorePoses set).
    const arena = req.arena;
    var poses: std.ArrayListUnmanaged(optimizer.RefPose) = .empty;
    for (parts_v.array.items) |it| {
        if (it != .object) continue;
        const ref = it.object.get("ref") orelse continue;
        if (ref != .string) continue;
        try poses.append(arena, .{
            .ref = ref.string,
            .x = jsonNum(it.object.get("x")),
            .y = jsonNum(it.object.get("y")),
            .rot = jsonNum(it.object.get("rot")),
            .side = jsonSide(it.object.get("side")),
            .locked = jsonFlag(it.object.get("locked")),
        });
    }

    var eval = Evaluator.init(arena, ctx.project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        arena.destroy(mr.eval);
    };
    const block: *env_mod.DesignBlock = resolveBlock(arena, ctx.project_dir, name, &eval, &module_res) orelse {
        res.status = 500;
        res.body = NO_BLOCK_MSG;
        return;
    };
    const eff_block = if (subSlug(req)) |s|
        (descendToSub(arena, block, s) orelse {
            res.status = 404;
            res.body = NO_SUB_MSG;
            return;
        }).block
    else
        block;

    const tune = parseTuning(req);
    // The live Heatmap asks for per-part blame (`"blame":true`, sent only while
    // the view is on) so a drag refreshes the tint. That needs a built Placement
    // (perPartBlame attributes over its parts/links/loops), so we take the
    // heavier placeFromPoses path — whose breakdown is the same scoreLayout +
    // surrogateLoops the light scorePoses returns, so the score bar never jumps.
    // Without the flag, stay on the cheap surrogate-only score (no Placement).
    const want_blame = blk: {
        const v = root.object.get("blame") orelse break :blk false;
        break :blk v == .bool and v.bool;
    };

    var aw: std.Io.Writer.Allocating = .init(arena);
    if (want_blame) {
        const placement = optimizer.placeFromPoses(arena, eff_block, ctx.project_dir, poses.items, tune.params) catch {
            res.status = 500;
            res.body = "score error";
            return;
        };
        const blame = partBlameRaw(arena, placement, tune.params);
        try aw.writer.writeByte('{');
        try writeBreakdownFields(&aw.writer, placement.breakdown, tune.params);
        try aw.writer.writeAll(",\"blame\":{");
        for (placement.parts, 0..) |pt, i| {
            if (i > 0) try aw.writer.writeByte(',');
            try writeJsonStr(&aw.writer, pt.ref_des);
            try aw.writer.print(":{d:.4}", .{if (i < blame.len) blame[i] else 0});
        }
        try aw.writer.writeAll("}}");
    } else {
        const bd = optimizer.scorePoses(arena, eff_block, ctx.project_dir, poses.items, tune.params) catch {
            res.status = 500;
            res.body = "score error";
            return;
        };
        try writeBreakdownJson(&aw.writer, bd, tune.params);
    }
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
            .side = jsonSide(it.object.get("side")),
            .locked = jsonFlag(it.object.get("locked")),
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
        }).block
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
    try writeRoutedArrays(w, routed, violations, placement.nets, null);
    try w.print(",\"routed\":{d},\"total\":{d},\"return_path\":{d}}}", .{ routed.routed, routed.total, rp_warn });
    res.content_type = .JSON;
    res.body = aw.written();
}

/// Resolve `name`'s design block and build a placement at its blessed poses
/// (★ default → newest manual → any snapshot → optimizer cache — the same
/// preference the KiCad sync seeds from). Null (+ a client error status) when
/// the design/module doesn't resolve or has no saved layout at all — fab
/// outputs are only meaningful for a deliberately placed board.
fn blessedPlacement(ctx: *Handler, req: *httpz.Request, res: *httpz.Response, name: []const u8) ?optimizer.Placement {
    var eval = Evaluator.init(req.arena, ctx.project_dir);
    var module_res: ?modules_mod.ResolvedBlock = null;
    const block: *env_mod.DesignBlock = resolveBlock(req.arena, ctx.project_dir, name, &eval, &module_res) orelse {
        res.status = 404;
        res.body = NO_BLOCK_MSG;
        return null;
    };
    const poses = chooseSyncPoses(req.arena, ctx.project_dir, name) orelse {
        res.status = 404;
        res.body = "no saved layout — place the board (and save/star a layout) first";
        return null;
    };
    return optimizer.placeFromPoses(req.arena, block, ctx.project_dir, poses, optimizer.Params{}) catch {
        res.status = 500;
        res.body = PLACEMENT_ERR_MSG;
        return null;
    };
}

/// Everything the fab writers need, resolved ONCE so every file of a package
/// agrees: the blessed placement with the ★ layout's drawn outline applied
/// (it's the board edge the gerbers profile), that layout's persisted routed
/// copper, and the shared y-up output frame derived from that outline. A
/// drill file and a copper file built from different FabViews would
/// mis-stack in CAM — always build one view per package.
const FabView = struct {
    placement: optimizer.Placement,
    tracks: []const router.Track = &.{},
    vias: []const router.Via = &.{},
    frame: export_fab.Frame,
};

/// Resolve `name`'s fab view (see `FabView`); null (+ client error status)
/// when the design/module doesn't resolve or has no saved layout.
fn blessedFabView(ctx: *Handler, req: *httpz.Request, res: *httpz.Response, name: []const u8) ?FabView {
    var placement = blessedPlacement(ctx, req, res, name) orelse return null;
    var tracks: []const router.Track = &.{};
    var vias: []const router.Via = &.{};
    for (readLayouts(req.arena, ctx.project_dir, name)) |L| {
        if (!L.default) continue;
        if (L.outline) |o| {
            placement.board_rect = .{ .minx = o.x, .miny = o.y, .w = o.w, .h = o.h };
            placement.board_poly = o.pts; // exact polygon when one was drawn
        }
        if (L.routes) |sr| {
            if (restoreRoutes(req.arena, sr, placement.nets)) |r| {
                tracks = r.tracks;
                vias = r.vias;
            }
        }
        break;
    }
    return .{ .placement = placement, .tracks = tracks, .vias = vias, .frame = export_fab.frameFor(placement) };
}

/// GET /api/pcb-centroid/:name — the pick-and-place centroid CSV at the
/// design's blessed poses (see `blessedPlacement`), side-aware, in the
/// shared fab frame. The assembly half of the fab package; pairs with the
/// BOM CSV.
pub fn pcbCentroidApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    const fv = blessedFabView(ctx, req, res, name) orelse return;
    var aw: std.Io.Writer.Allocating = .init(req.arena);
    try export_fab.centroidCsv(&aw.writer, fv.placement.parts, fv.placement.instances, fv.frame);
    res.header(CT_HDR, "text/csv; charset=utf-8");
    res.body = aw.written();
}

/// GET /api/pcb-drill/:name[?npth=1] — the Excellon drill file at the design's
/// blessed poses: plated through-hole pads + the ★ layout's persisted routed
/// vias (PTH), or the non-plated mounting holes (`?npth=1`).
pub fn pcbDrillApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    const fv = blessedFabView(ctx, req, res, name) orelse return;
    const class: export_fab.DrillClass = if (queryFlag(req, "npth")) .non_plated else .plated;
    var aw: std.Io.Writer.Allocating = .init(req.arena);
    try export_fab.excellonDrill(&aw.writer, req.arena, fv.placement.parts, fv.vias, class, fv.frame);
    res.header(CT_HDR, "text/plain; charset=utf-8");
    res.body = aw.written();
}

/// GET /api/pcb-gerbers/:name — the complete fab package as one ZIP: Gerber
/// copper (outer signal layers + stackup-derived inner planes), solder mask,
/// paste, silkscreen, board profile, Excellon PTH/NPTH drills, and the
/// centroid CSV — all at the blessed poses with the ★ layout's persisted
/// routed copper, in one shared y-up frame. What a board house needs to
/// build the board, no KiCad in the loop.
pub fn pcbGerbersApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    const fv = blessedFabView(ctx, req, res, name) orelse return;
    const copper = export_gerber.Copper{ .tracks = fv.tracks, .vias = fv.vias };

    var entries: std.ArrayListUnmanaged(zipfile.Entry) = .empty;
    for (try export_gerber.planLayers(req.arena, fv.placement)) |f| {
        var aw: std.Io.Writer.Allocating = .init(req.arena);
        try export_gerber.writeLayer(&aw.writer, req.arena, fv.placement, copper, fv.frame, f.layer, f.function);
        try entries.append(req.arena, .{
            .name = try std.fmt.allocPrint(req.arena, "{s}-{s}", .{ name, f.suffix }),
            .data = aw.written(),
        });
    }
    var pth: std.Io.Writer.Allocating = .init(req.arena);
    try export_fab.excellonDrill(&pth.writer, req.arena, fv.placement.parts, fv.vias, .plated, fv.frame);
    try entries.append(req.arena, .{
        .name = try std.fmt.allocPrint(req.arena, "{s}-PTH.drl", .{name}),
        .data = pth.written(),
    });
    var npth: std.Io.Writer.Allocating = .init(req.arena);
    try export_fab.excellonDrill(&npth.writer, req.arena, fv.placement.parts, fv.vias, .non_plated, fv.frame);
    try entries.append(req.arena, .{
        .name = try std.fmt.allocPrint(req.arena, "{s}-NPTH.drl", .{name}),
        .data = npth.written(),
    });
    var cw: std.Io.Writer.Allocating = .init(req.arena);
    try export_fab.centroidCsv(&cw.writer, fv.placement.parts, fv.placement.instances, fv.frame);
    try entries.append(req.arena, .{
        .name = try std.fmt.allocPrint(req.arena, "{s}-centroid.csv", .{name}),
        .data = cw.written(),
    });

    var zw: std.Io.Writer.Allocating = .init(req.arena);
    try zipfile.write(&zw.writer, entries.items);
    res.header(CT_HDR, "application/zip");
    res.header("content-disposition", try std.fmt.allocPrint(req.arena, "attachment; filename=\"{s}-gerbers.zip\"", .{name}));
    res.body = zw.written();
}

/// POST /api/pcb-layouts/:name — save a named layout snapshot (kind "manual").
/// Body: `{"name","parts":[{ref,x,y,rot,origin?}, …]}`; the score is computed on the
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
    // `?sub=` scopes the save to a sub circuit: score against that sub-block and
    // persist to its own `<design>.<sub>.layouts.json` sidecar (see writeLayoutsSub).
    const sub = subSlug(req);

    // Score the hand layout on the server with the optimizer's own objective —
    // the same code the live `/api/pcb-score` endpoint uses — so a saved layout
    // is directly comparable to the auto baseline (HPWL + real routed-trace
    // loop). A resolve/score failure just leaves the entry unscored.
    var score: ?LayoutScore = null;
    var single_design = false;
    {
        var eval = Evaluator.init(ctx.allocator, ctx.project_dir);
        defer eval.deinit();
        var module_res: ?modules_mod.ResolvedBlock = null;
        defer if (module_res) |mr| {
            mr.eval.deinit();
            ctx.allocator.destroy(mr.eval);
        };
        if (resolveBlock(ctx.allocator, ctx.project_dir, name, &eval, &module_res)) |block| {
            single_design = module_res == null and sub == null;
            // For a sub circuit, score against the scoped sub-block (its parts),
            // not the whole parent design — null when the slug no longer resolves.
            const score_block: ?*env_mod.DesignBlock = if (sub) |s| blk: {
                const sb = descendToSub(ctx.allocator, block, s) orelse break :blk null;
                break :blk sb.block;
            } else block;
            if (score_block) |sblk| {
                const params = readAutoParams(ctx.allocator, ctx.project_dir, name) orelse optimizer.Params{};
                const poses = try refPosesFromPartPoses(req.arena, parts);
                if (optimizer.scorePoses(ctx.allocator, sblk, ctx.project_dir, poses, params)) |bd| {
                    score = .{ .hpwl = bd.hpwl, .loop = bd.loop_raw, .caps = 0, .objective = bd.objective };
                } else |_| {}
            }
        }
    }

    var entry = SavedLayout{
        .name = nm,
        .kind = KIND_MANUAL,
        .ts = clock.timestamp(),
        .score = score,
        .parts = parts,
        .routes = parseSavedRoutes(req.arena, root.object.get("routes")),
        .outline = parseSavedOutline(req.arena, root.object.get("outline")),
    };
    // A top-level DESIGN keeps exactly one layout: the save replaces the whole
    // list with this snapshot, auto-starred so KiCad sync + the fab outputs
    // use it. Modules and ?sub sub circuits keep the multi-snapshot history.
    if (single_design) {
        entry.name = "layout";
        entry.default = true;
        const only = [_]SavedLayout{entry};
        writeLayoutsSub(req.arena, ctx.project_dir, name, sub, &only);
        res.content_type = .JSON;
        res.body = "{\"ok\":true,\"single\":true}";
        return;
    }
    const existing = readLayoutsSub(req.arena, ctx.project_dir, name, sub);
    var out: std.ArrayListUnmanaged(SavedLayout) = .empty;
    // `replaced` = wrote `entry` in place of a matching row (same name, or an
    // auto run of this exact arrangement, promoted to the named keeper).
    // `dup` = this arrangement is already saved as another named layout, so we
    // keep that one and add nothing (no duplicate).
    var replaced = false;
    var dup = false;
    for (existing) |L| {
        const open = !replaced and !dup; // still searching for the row to update
        if (open and std.mem.eql(u8, L.name, nm)) {
            // Re-saving an existing name overwrites its poses/score in place but
            // keeps its default status — the user re-captured under the same name.
            entry.default = L.default;
            try out.append(req.arena, entry);
            replaced = true;
        } else if (open and sameLayoutScore(L.score, entry.score)) {
            if (std.mem.eql(u8, L.kind, KIND_AUTO)) {
                // Same arrangement as an auto run → promote it to this named
                // keeper in place rather than leaving a duplicate behind.
                entry.default = L.default;
                try out.append(req.arena, entry);
                replaced = true;
            } else {
                // Already saved as a named layout — keep it, don't duplicate.
                dup = true;
                try out.append(req.arena, L);
            }
        } else try out.append(req.arena, L);
    }
    if (!replaced and !dup) try out.insert(req.arena, 0, entry);
    writeLayoutsSub(req.arena, ctx.project_dir, name, sub, out.items);
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
    const sub = subSlug(req);
    const existing = readLayoutsSub(req.arena, ctx.project_dir, name, sub);
    var out: std.ArrayListUnmanaged(SavedLayout) = .empty;
    for (existing) |L| {
        if (std.mem.eql(u8, L.name, nm_v.string)) continue;
        try out.append(req.arena, L);
    }
    writeLayoutsSub(req.arena, ctx.project_dir, name, sub, out.items);
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
    const sub = subSlug(req);
    const existing = readLayoutsSub(req.arena, ctx.project_dir, name, sub);
    var out: std.ArrayListUnmanaged(SavedLayout) = .empty;
    for (existing) |L| {
        var e = L;
        e.default = want.len > 0 and std.mem.eql(u8, L.name, want);
        try out.append(req.arena, e);
    }
    writeLayoutsSub(req.arena, ctx.project_dir, name, sub, out.items);
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
    const sub = subSlug(req);
    const existing = readLayoutsSub(req.arena, ctx.project_dir, name, sub);
    if (existing.len == 0) {
        res.content_type = .JSON;
        res.body = "{\"ok\":true,\"rescored\":0}";
        return;
    }
    // Sub circuits keep their save-time scores — the bulk rescore resolves the
    // whole parent design block, which doesn't match a sub-block's part set.
    if (sub != null) {
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
            const poses = try refPosesFromPartPoses(req.arena, L.parts);
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
    const sub = subSlug(req);
    const layouts = readLayoutsSub(req.arena, ctx.project_dir, name, sub);

    var eval = Evaluator.init(ctx.allocator, ctx.project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        ctx.allocator.destroy(mr.eval);
    };
    const block_root: *env_mod.DesignBlock = resolveBlock(ctx.allocator, ctx.project_dir, name, &eval, &module_res) orelse {
        res.status = 500;
        res.body = NO_BLOCK_MSG;
        return;
    };
    // Score against the scoped sub-block when `?sub=` is present, so the panel
    // re-weigh matches the sub circuit's own parts.
    const block: *env_mod.DesignBlock = if (sub) |s| blk: {
        const sb = descendToSub(ctx.allocator, block_root, s) orelse {
            res.status = 404;
            res.body = NO_SUB_MSG;
            return;
        };
        break :blk sb.block;
    } else block_root;
    const tune = parseTuning(req);

    var aw: std.Io.Writer.Allocating = .init(req.arena);
    const w = &aw.writer;
    try w.writeAll("{\"results\":[");
    var first = true;
    for (layouts) |L| {
        if (L.parts.len == 0) continue;
        const poses = try refPosesFromPartPoses(req.arena, L.parts);
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
    // Atomic write (tmp → rename): the layout sidecar is rewritten on GET (the
    // dedup pass in `displayLayouts`) and on every solve, from multiple worker
    // threads with no lock. A truncate-then-write left a window where a
    // concurrent reader — or a crash — saw a half-written file, and
    // `parseLayouts` treats any parse failure as "no layouts", silently
    // discarding every saved/starred layout (and the KiCad-sync seed). The
    // rename is atomic, so a reader sees either the old or the new file whole;
    // concurrent writers degrade to last-writer-wins instead of corruption.
    var write_buf: [4096]u8 = undefined;
    var atomic = try infra_fs.cwd().atomicFile(path, .{ .write_buffer = &write_buf });
    defer atomic.deinit();
    try atomic.file_writer.interface.writeAll(data);
    try atomic.finish();
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

/// `courtCeilGrid`'s outward twin for a low edge (rounds down / away).
fn courtFloorGrid(v: f64) f64 {
    const g = optimizer.GRID_MM;
    return std.math.floor(v / g + 1e-9) * g;
}

/// POST /api/courtyard/:name — rewrite a footprint's courtyard. Three modes:
///   `{"fp":"conn-x","mode":"rect","x0":-1.2,"y0":-0.8,"x1":2.4,"y1":0.8}` —
///     the four *effective* edges verbatim (the drag editor; the box needn't
///     be origin-centred); the loader's air-gap margin is inverted per side so
///     the written rect reloads to exactly those edges.
///   `{"fp":"c-0402","mode":"offset","offset":0.2}` — the offset is the literal
///     gap from the pad bounding box to the courtyard edge on every side,
///     grid-snapped outward per side (asymmetric pads stay hugged), then with
///     the loader's air-margin stripped back out.
///   `{"fp":"c-0402","mode":"size","hw":1.2,"hh":0.8}` — legacy symmetric
///     *effective* half-extents about the origin.
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

    // Three ways to size the rect (see the doc comment). All store an
    // *effective* box with the loader's air-gap margin stripped per side, so
    // geometry.load adds it back to exactly the intended courtyard.
    //   "rect"   — the four effective edges verbatim (the drag editor; the box
    //              needn't be origin-centred).
    //   "offset" — the pad bounding box + that gap on every side, grid-snapped
    //              outward (per side, so asymmetric pads stay hugged).
    //   "size"   — legacy symmetric half-extents.
    const mode: []const u8 = blk: {
        const mv = root.object.get("mode") orelse break :blk "size";
        break :blk if (mv == .string) mv.string else "size";
    };
    const margin = geometry.BBOX_MARGIN_MM;
    var rx0: f64 = undefined;
    var ry0: f64 = undefined;
    var rx1: f64 = undefined;
    var ry1: f64 = undefined;
    if (std.mem.eql(u8, mode, "rect")) {
        rx0 = jsonNum(root.object.get("x0")) + margin;
        ry0 = jsonNum(root.object.get("y0")) + margin;
        rx1 = jsonNum(root.object.get("x1")) - margin;
        ry1 = jsonNum(root.object.get("y1")) - margin;
    } else if (std.mem.eql(u8, mode, "offset")) {
        const off = @max(jsonNum(root.object.get("offset")), 0);
        const g = geometry.load(req.arena, ctx.project_dir, fp_v.string, 0, margin);
        var px0: f64 = std.math.inf(f64);
        var py0: f64 = std.math.inf(f64);
        var px1: f64 = -std.math.inf(f64);
        var py1: f64 = -std.math.inf(f64);
        for (g.pads) |p| {
            px0 = @min(px0, p.x - p.w / 2);
            px1 = @max(px1, p.x + p.w / 2);
            py0 = @min(py0, p.y - p.h / 2);
            py1 = @max(py1, p.y + p.h / 2);
        }
        if (g.pads.len == 0) {
            res.status = 400;
            res.body = "footprint has no pads to offset from";
            return;
        }
        // The offset is the literal gap from the pad bounding box to the
        // effective courtyard edge, snapped outward to the grid per side, then
        // deflated by the loader's air-margin (geometry.load adds it back).
        rx0 = courtFloorGrid(px0 - off) + margin;
        ry0 = courtFloorGrid(py0 - off) + margin;
        rx1 = courtCeilGrid(px1 + off) - margin;
        ry1 = courtCeilGrid(py1 + off) - margin;
    } else {
        const rw = @max(jsonNum(root.object.get("hw")) - margin, 0.05);
        const rh = @max(jsonNum(root.object.get("hh")) - margin, 0.05);
        rx0 = -rw;
        ry0 = -rh;
        rx1 = rw;
        ry1 = rh;
    }
    // Degenerate guard: a span the margin deflation collapsed keeps a sliver.
    if (rx1 - rx0 < 0.05) {
        const cx = (rx0 + rx1) / 2;
        rx0 = cx - 0.025;
        rx1 = cx + 0.025;
    }
    if (ry1 - ry0 < 0.05) {
        const cy = (ry0 + ry1) / 2;
        ry0 = cy - 0.025;
        ry1 = cy + 0.025;
    }

    const updated = rewriteCourtyard(ctx.allocator, src, rx0, ry0, rx1, ry1) catch {
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

/// Return `src` with its `(courtyard …)` form replaced by the given rect
/// (footprint-local corners — need not be origin-centred), inserting one
/// before the footprint's closing paren if none exists.
fn rewriteCourtyard(alloc: std.mem.Allocator, src: []const u8, x0: f64, y0: f64, x1: f64, y1: f64) HandlerError![]u8 {
    var buf: std.Io.Writer.Allocating = .init(alloc);
    const w = &buf.writer;
    const form = try std.fmt.allocPrint(alloc, "(courtyard (rect {d:.3} {d:.3} {d:.3} {d:.3}))", .{ x0, y0, x1, y1 });
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

/// Saved-layout `PartPose`s from a solved placement, each stamped with its
/// renumber-stable `origin_key` (the placement's `instances` run index-aligned
/// with `parts`). Snapshots written through this can be re-loaded by origin
/// after the parts renumber. Null on allocation failure.
fn posesFromPlacement(alloc: std.mem.Allocator, p: optimizer.Placement) ?[]PartPose {
    const parts = alloc.alloc(PartPose, p.parts.len) catch return null;
    for (p.parts, 0..) |pt, i| parts[i] = .{
        .ref = pt.ref_des,
        .x = pt.x,
        .y = pt.y,
        .rot = pt.rot,
        .origin = if (i < p.instances.len) p.instances[i].origin_key else "",
        .side = pt.side,
        .locked = pt.locked,
    };
    return parts;
}

/// PartPose slice → RefPose slice, carrying side/locked — shared by the
/// scoring endpoints so a saved layout's board sides survive the conversion.
fn refPosesFromPartPoses(alloc: std.mem.Allocator, parts: []const PartPose) std.mem.Allocator.Error![]optimizer.RefPose {
    const out = try alloc.alloc(optimizer.RefPose, parts.len);
    for (parts, 0..) |p, i| out[i] = .{ .ref = p.ref, .x = p.x, .y = p.y, .rot = p.rot, .side = p.side, .locked = p.locked };
    return out;
}

/// The sub-block scope of a hierarchical ref-des: everything before the last
/// `/` ("hmc733/U14" → "hmc733", "U5" → ""). Origin keys are module-LOCAL, so
/// they only identify a part within one sub-block's scope.
fn refPrefix(ref: []const u8) []const u8 {
    const i = std.mem.lastIndexOfScalar(u8, ref, '/') orelse return "";
    return ref[0..i];
}

/// Re-key a saved layout's poses onto `block`'s *current* ref-des. A pose
/// whose stored `ref` still exists in the flatten keeps it verbatim (exact
/// identity beats any heuristic). Otherwise the renumber-stable `origin_key`
/// bridges the drift — scoped by the ref's sub-block prefix, because origin
/// keys are module-local ("U1" names the main IC of EVERY sub-block; an
/// unscoped map would let 13 sub-blocks clobber each other and drop 12 poses).
/// A pose with no origin (a legacy entry) or no match keeps its stored `ref`.
/// Null only on a flatten/allocation failure (caller falls back to raw refs).
fn rekeyPosesByOrigin(
    alloc: std.mem.Allocator,
    block: *env_mod.DesignBlock,
    parts: []const PartPose,
) ?[]const optimizer.RefPose {
    var flat: std.ArrayListUnmanaged(export_kicad.FlatInstance) = .empty;
    netlist.collectInstances(alloc, block, "", &flat, block.refStyle()) catch return null;
    var live = std.StringHashMap(void).init(alloc);
    var ref_of = std.StringHashMap([]const u8).init(alloc);
    for (flat.items) |fi| {
        live.put(fi.ref_des, {}) catch return null;
        if (fi.origin_key.len == 0) continue;
        const key = std.fmt.allocPrint(alloc, PIN_KEY_FMT, .{ refPrefix(fi.ref_des), fi.origin_key }) catch return null;
        ref_of.put(key, fi.ref_des) catch return null;
    }
    const out = alloc.alloc(optimizer.RefPose, parts.len) catch return null;
    for (parts, 0..) |pp, i| {
        const ref = if (live.contains(pp.ref))
            pp.ref
        else if (pp.origin.len > 0) blk: {
            const key = std.fmt.allocPrint(alloc, PIN_KEY_FMT, .{ refPrefix(pp.ref), pp.origin }) catch return null;
            break :blk ref_of.get(key) orelse pp.ref;
        } else pp.ref;
        out[i] = .{ .ref = ref, .x = pp.x, .y = pp.y, .rot = pp.rot, .side = pp.side, .locked = pp.locked };
    }
    return out;
}

/// Name of the design's starred (★ default) saved layout — the one the Layouts
/// panel marks with a filled star and the KiCad sync seeds first-insertion
/// placement from — or null when nothing is starred (or the starred entry has
/// no poses). Lets the `/pcb-layout` page default to that blessed layout on open.
fn defaultLayoutName(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8, sub: ?[]const u8) ?[]const u8 {
    for (readLayoutsSub(alloc, project_dir, name, sub)) |lay| {
        if (lay.default and lay.parts.len > 0) return lay.name;
    }
    return null;
}

/// The poses of a single named saved layout (`?refine=` / `?layout=`), as
/// `RefPose`s ready to seed `solve` / `placeFromPoses` — re-keyed onto `block`'s
/// current ref-des by `origin_key` (see `rekeyPosesByOrigin`) so a layout saved
/// against a different flattening of the same block still lands on the right
/// parts. Null when no layout by that name exists.
fn readLayoutPosesFor(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    want: []const u8,
    block: *env_mod.DesignBlock,
    sub: ?[]const u8,
) ?[]const optimizer.RefPose {
    for (readLayoutsSub(alloc, project_dir, name, sub)) |lay| {
        if (!std.mem.eql(u8, lay.name, want)) continue;
        if (rekeyPosesByOrigin(alloc, block, lay.parts)) |poses| return poses;
        // Re-key failed (flatten error) — fall back to the raw stored refs.
        var list: std.ArrayListUnmanaged(optimizer.RefPose) = .empty;
        for (lay.parts) |pp| {
            list.append(alloc, .{ .ref = pp.ref, .x = pp.x, .y = pp.y, .rot = pp.rot, .side = pp.side, .locked = pp.locked }) catch return null;
        }
        return list.toOwnedSlice(alloc) catch null;
    }
    return null;
}

/// Sidecar path for a design's (or sub circuit's) layout store. `sub == null` →
/// the design's own `<design>.layouts.json`, resolved next to the source via
/// `designSiblingPath`. `sub` set → the per-sub-circuit store
/// `<design>.<sub>.layouts.json` placed in the design's directory, so a
/// path-/inline-sourced sub circuit (no module page of its own) still gets
/// editable, persisted layouts — scoped to this design. The slug is filesystem
/// safe (`review.slugify` output, `[a-z0-9-]`), so no escaping is needed.
fn layoutsSidecar(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8, sub: ?[]const u8, ext: []const u8) ?[]u8 {
    const s = sub orelse return (paths.designSiblingPath(alloc, project_dir, name, ext) catch null);
    const src = paths.designSourcePath(alloc, project_dir, name) catch return null;
    defer alloc.free(src);
    const dir = std.fs.path.dirname(src) orelse ".";
    return std.fmt.allocPrint(alloc, "{s}/{s}.{s}{s}", .{ dir, name, s, ext }) catch null;
}

/// Read every saved layout for `name` from its `.layouts.json` sidecar
/// (newest first). Returns an empty slice when the file doesn't exist or on
/// parse failure; allocations live on `alloc` (request lifetime).
pub fn readLayouts(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8) []const SavedLayout {
    return readLayoutsSub(alloc, project_dir, name, null);
}

/// As `readLayouts`, but for a `?sub=` scoped sub circuit reads its per-sub
/// sidecar (`layoutsSidecar`). `sub == null` is identical to `readLayouts`.
fn readLayoutsSub(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8, sub: ?[]const u8) []const SavedLayout {
    if (layoutsSidecar(alloc, project_dir, name, sub, LAYOUTS_EXT)) |path| {
        defer alloc.free(path);
        if (infra_fs.cwd().readFileAlloc(alloc, path, 1 << 20)) |data| {
            if (parseLayouts(alloc, data)) |list| return list;
        } else |_| {}
    }
    return &[_]SavedLayout{};
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
        const rough = blk: {
            const rv = it.object.get("rough") orelse break :blk false;
            break :blk rv == .bool and rv.bool;
        };
        list.append(alloc, .{
            .name = nm.string,
            .kind = kind,
            .ts = @intFromFloat(jsonNum(it.object.get("ts"))),
            .score = score,
            .parts = parts,
            .default = default_name.len > 0 and std.mem.eql(u8, nm.string, default_name),
            .rough = rough,
            .routes = parseSavedRoutes(alloc, it.object.get("routes")),
            .outline = parseSavedOutline(alloc, it.object.get("outline")),
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
        const origin: []const u8 = blk: {
            const ov = it.object.get("origin") orelse break :blk "";
            break :blk if (ov == .string) ov.string else "";
        };
        list.append(alloc, .{
            .ref = ref.string,
            .x = jsonNum(it.object.get("x")),
            .y = jsonNum(it.object.get("y")),
            .rot = jsonNum(it.object.get("rot")),
            .origin = origin,
            .side = jsonSide(it.object.get("side")),
            .locked = jsonFlag(it.object.get("locked")),
        }) catch return list.items;
    }
    return list.toOwnedSlice(alloc) catch null;
}

/// Parse a `{"tracks":[…],"vias":[…]}` saved-routes object (the same shape
/// the live route JSON and the layouts sidecar use). Null when absent,
/// malformed, or empty — an empty routes object is treated as "no routes".
fn parseSavedRoutes(alloc: std.mem.Allocator, v: ?std.json.Value) ?SavedRoutes {
    const obj = v orelse return null;
    if (obj != .object) return null;
    var tracks: std.ArrayListUnmanaged(SavedTrack) = .empty;
    if (obj.object.get("tracks")) |tv| if (tv == .array) {
        for (tv.array.items) |it| {
            if (it != .object) continue;
            tracks.append(alloc, .{
                .x1 = jsonNum(it.object.get("x1")),
                .y1 = jsonNum(it.object.get("y1")),
                .x2 = jsonNum(it.object.get("x2")),
                .y2 = jsonNum(it.object.get("y2")),
                .l = if (jsonNum(it.object.get("l")) >= 1) 1 else 0,
                .w = jsonNum(it.object.get("w")),
                .net = jsonStrField(it.object.get("net")),
                .g = jsonStrField(it.object.get("g")),
            }) catch return null;
        }
    };
    var vias: std.ArrayListUnmanaged(SavedVia) = .empty;
    if (obj.object.get("vias")) |vv| if (vv == .array) {
        for (vv.array.items) |it| {
            if (it != .object) continue;
            vias.append(alloc, .{
                .x = jsonNum(it.object.get("x")),
                .y = jsonNum(it.object.get("y")),
                .d = jsonNum(it.object.get("d")),
                .drill = jsonNum(it.object.get("drill")),
                .net = jsonStrField(it.object.get("net")),
                .g = jsonStrField(it.object.get("g")),
            }) catch return null;
        }
    };
    if (tracks.items.len == 0 and vias.items.len == 0) return null;
    return .{
        .tracks = tracks.toOwnedSlice(alloc) catch return null,
        .vias = vias.toOwnedSlice(alloc) catch return null,
    };
}

/// Parse an `{"x","y","w","h"[,"pts":[[x,y],…]]}` outline object; null when
/// absent/malformed or degenerate (w/h must be positive real board
/// dimensions). A valid `pts` closed polygon (≥3 vertices) wins: x/y/w/h are
/// re-derived from its bounding box so the rect fields can never drift from
/// the polygon (old rect-only sidecars keep loading unchanged).
fn parseSavedOutline(alloc: std.mem.Allocator, v: ?std.json.Value) ?SavedOutline {
    const obj = v orelse return null;
    if (obj != .object) return null;
    if (parseOutlinePts(alloc, obj.object.get("pts"))) |pts| {
        const bb = outline_mod.bboxRect(pts);
        if (bb.w > 0 and bb.h > 0)
            return .{ .x = bb.minx, .y = bb.miny, .w = bb.w, .h = bb.h, .pts = pts };
        alloc.free(pts);
    }
    const o = SavedOutline{
        .x = jsonNum(obj.object.get("x")),
        .y = jsonNum(obj.object.get("y")),
        .w = jsonNum(obj.object.get("w")),
        .h = jsonNum(obj.object.get("h")),
    };
    if (!(o.w > 0) or !(o.h > 0)) return null;
    return o;
}

/// Serialize a `SavedOutline` as the sidecar/page JSON object — the exact
/// shape `parseSavedOutline` reads back (rect fields always, `pts` only for
/// polygon outlines). Shared by the sidecar writer and the page blob so the
/// two can never diverge.
fn writeSavedOutlineJson(w: *std.Io.Writer, o: SavedOutline) std.Io.Writer.Error!void {
    try w.print("{{\"x\":{d},\"y\":{d},\"w\":{d},\"h\":{d}", .{ o.x, o.y, o.w, o.h });
    if (o.pts) |pts| {
        try w.writeAll(",\"pts\":[");
        for (pts, 0..) |p, i| {
            if (i > 0) try w.writeAll(",");
            try w.print(PT_PAIR_FMT, .{ p[0], p[1] });
        }
        try w.writeAll("]");
    }
    try w.writeAll("}");
}

/// Parse a `[[x,y],…]` polygon vertex array: ≥3 well-formed 2-number pairs,
/// else null (malformed entries reject the whole polygon rather than
/// silently reshaping the board).
fn parseOutlinePts(alloc: std.mem.Allocator, v: ?std.json.Value) ?[]const [2]f64 {
    const arr = v orelse return null;
    if (arr != .array or arr.array.items.len < 3) return null;
    const pts = alloc.alloc([2]f64, arr.array.items.len) catch return null;
    for (arr.array.items, 0..) |it, i| {
        if (it != .array or it.array.items.len != 2) {
            alloc.free(pts);
            return null;
        }
        pts[i] = .{ jsonNum(it.array.items[0]), jsonNum(it.array.items[1]) };
    }
    return pts;
}

/// A pose/route JSON string field, or "" when absent/not a string.
fn jsonStrField(v: ?std.json.Value) []const u8 {
    const sv = v orelse return "";
    return if (sv == .string) sv.string else "";
}

/// Serialize saved routes in the shared live-JSON shape (see `SavedTrack`).
fn writeSavedRoutesJson(w: *std.Io.Writer, sr: SavedRoutes) std.Io.Writer.Error!void {
    try w.writeAll("{\"tracks\":[");
    for (sr.tracks, 0..) |t, i| {
        if (i > 0) try w.writeAll(",");
        try w.print(TRACK_JSON_FMT, .{ t.x1, t.y1, t.x2, t.y2, t.l, t.w });
        try writeJsonStr(w, t.net);
        if (t.g.len > 0) {
            try w.writeAll(",\"g\":");
            try writeJsonStr(w, t.g);
        }
        try w.writeAll("}");
    }
    try w.writeAll(VIAS_ARR_OPEN);
    for (sr.vias, 0..) |vi, i| {
        if (i > 0) try w.writeAll(",");
        try w.print(VIA_JSON_FMT, .{ vi.x, vi.y, vi.d, vi.drill });
        try writeJsonStr(w, vi.net);
        if (vi.g.len > 0) {
            try w.writeAll(",\"g\":");
            try writeJsonStr(w, vi.g);
        }
        try w.writeAll("}");
    }
    try w.writeAll("]}");
}

/// Rebuild a `router.RouteResult` from a layout's persisted copper, resolving
/// each stored net NAME back to its index in the *current* flattened netlist
/// (unknown names → −1, still drawn + DRC-checked as foreign copper). Lets the
/// page draw saved routes on open and re-run DRC against the current poses.
fn restoreRoutes(alloc: std.mem.Allocator, sr: SavedRoutes, nets: []const export_kicad.FlatNet) ?router.RouteResult {
    var idx = std.StringHashMap(i32).init(alloc);
    for (nets, 0..) |net, i| idx.put(net.name, @intCast(i)) catch return null;
    const tracks = alloc.alloc(router.Track, sr.tracks.len) catch return null;
    for (sr.tracks, 0..) |t, i| tracks[i] = .{
        .x1 = t.x1,
        .y1 = t.y1,
        .x2 = t.x2,
        .y2 = t.y2,
        .layer = t.l,
        .width = t.w,
        .net = if (t.net.len > 0) (idx.get(t.net) orelse -1) else -1,
    };
    const vias = alloc.alloc(router.Via, sr.vias.len) catch return null;
    for (sr.vias, 0..) |vi, i| vias[i] = .{
        .x = vi.x,
        .y = vi.y,
        .dia = vi.d,
        .drill = vi.drill,
        .net = if (vi.net.len > 0) (idx.get(vi.net) orelse -1) else -1,
    };
    return .{ .tracks = tracks, .vias = vias, .routed = 0, .total = 0 };
}

/// The page's resolved routing view: route params, the copper to draw (fresh
/// ?route=1 result, else the shown layout's persisted routes), its DRC
/// violations against the CURRENT poses, and whether a user-drawn outline was
/// applied onto the placement (see applyShownOutline).
const ShownView = struct {
    ro: RouteOpts,
    routed: ?router.RouteResult,
    violations: []const drc.Violation,
    outline_drawn: bool,
    /// The SavedRoutes the shown copper was restored from (null when the
    /// copper is a fresh ?route=1 result) — index-aligned with `routed`, so
    /// the blob writer can re-emit per-segment stamp group tags (`g`).
    saved: ?SavedRoutes = null,
};

/// Resolve everything the shown saved layout contributes to the page: apply
/// its drawn outline onto the placement (before DRC, so the board-edge check
/// sees it), run routing when ?route=1 asked for it, else restore the
/// layout's persisted copper, and DRC whatever copper is shown. `shown` is
/// null for ?sub scoped pages (no whole-design layout applies).
fn resolveShownView(
    ctx: *Handler,
    req: *httpz.Request,
    placement: *optimizer.Placement,
    layouts: []const SavedLayout,
    shown: ?[]const u8,
) ShownView {
    // Drawn outline wins over the authored (board (size …)) rectangle — it's
    // the explicit per-layout edit.
    const outline_drawn = applyShownOutline(placement, layouts, shown);
    // Routing runs only on demand (?route=1); otherwise the shown saved
    // layout's persisted copper is restored (see shownSavedRoutes).
    const ro = parseRoute(req);
    var routed: ?router.RouteResult = if (ro.run) (router.route(ctx.allocator, placement.*, ro.params) catch null) else null;
    var saved: ?SavedRoutes = null;
    if (routed == null) {
        saved = shownSavedRoutes(layouts, shown);
        if (saved) |sr| routed = restoreRoutes(ctx.allocator, sr, placement.nets);
    }
    const violations: []const drc.Violation = if (routed) |r|
        (drc.check(ctx.allocator, placement.*, r, ro.params.clearance) catch &.{})
    else
        &.{};
    return .{ .ro = ro, .routed = routed, .violations = violations, .outline_drawn = outline_drawn, .saved = saved };
}

/// Apply the shown saved layout's user-drawn outline (if any) onto the
/// placement: sets `board_rect` and grows the framing bbox so the whole
/// rectangle is on screen. Returns true when an outline was applied (the
/// blob then flags it editable — see PCB.outline in the viewer).
fn applyShownOutline(placement: *optimizer.Placement, layouts: []const SavedLayout, shown: ?[]const u8) bool {
    const sn = shown orelse return false;
    for (layouts) |L| {
        if (!std.mem.eql(u8, L.name, sn)) continue;
        const o = L.outline orelse return false;
        placement.board_rect = .{ .minx = o.x, .miny = o.y, .w = o.w, .h = o.h };
        placement.board_poly = o.pts; // exact polygon when one was drawn
        placement.minx = @min(placement.minx, o.x);
        placement.miny = @min(placement.miny, o.y);
        placement.maxx = @max(placement.maxx, o.x + o.w);
        placement.maxy = @max(placement.maxy, o.y + o.h);
        return true;
    }
    return false;
}

/// The shown saved layout's persisted copper — the page draws it when no
/// fresh ?route=1 ran (rebuilt against the current netlist by the caller via
/// `restoreRoutes`, which DRC re-checks it against the CURRENT poses so
/// copper gone stale after a part move shows violations). Null when nothing
/// is shown or the layout carries no routes.
fn shownSavedRoutes(layouts: []const SavedLayout, shown: ?[]const u8) ?SavedRoutes {
    const sn = shown orelse return null;
    for (layouts) |L| {
        if (!std.mem.eql(u8, L.name, sn)) continue;
        return L.routes;
    }
    return null;
}

/// The single-slot optimizer cache: the tuning weights that produced the
/// last solve plus its part poses. Lives in the `"cache"` key of
/// `.layouts.json`; never shown as a snapshot row.
const CacheSlot = struct {
    params: optimizer.Params,
    /// Null when the slot carried no parts array at all (callers treat
    /// that as "no cached layout — solve fresh").
    parts: ?[]const PartPose,
};

/// Parse a `{"params":{…},"parts":[…]}` cache object (either the `"cache"`
/// key of `.layouts.json` or the root of a legacy `.autolayout.json`).
fn parseCacheSlot(alloc: std.mem.Allocator, v: std.json.Value) ?CacheSlot {
    if (v != .object) return null;
    var p = optimizer.Params{};
    if (v.object.get("params")) |po| {
        if (po == .object) parseCacheParams(po, &p);
    }
    return .{ .params = p, .parts = parsePartPoses(alloc, v.object.get("parts")) };
}

/// Apply the cache's stored tuning weights onto `p`.
fn parseCacheParams(po: std.json.Value, p: *optimizer.Params) void {
    if (po.object.get("loop_w")) |v| p.loop_w = jsonNum(v);
    if (po.object.get("w_congest")) |v| p.w_congest = jsonNum(v);
    if (po.object.get("cap_w_max")) |v| p.cap_w_max = jsonNum(v);
    if (po.object.get("grid")) |v| p.grid_courtyards = v == .bool and v.bool;
    // A negative `w_align` is the auto sentinel current builds write; 0.5 is the
    // legacy shipped default — the tidiness term has since been pair-normalized
    // (its weight scale moved to W_ALIGN_TIDINESS), so re-pinning the old number
    // would silently apply a ~5× weaker alignment than either era intended.
    // Both resolve to auto; anything else was a deliberate tuning override.
    if (po.object.get("w_align")) |v| {
        const a = jsonNum(v);
        const legacy_default = a == 0.5;
        if (a >= 0 and !legacy_default) p.w_align = a;
    }
}

/// Read the optimizer-cache slot for `name`: the `"cache"` key of
/// `.layouts.json` first, falling back to the legacy standalone
/// `.autolayout.json` for boards last solved by an older build.
fn readCacheSlot(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8) ?CacheSlot {
    if (paths.designSiblingPath(alloc, project_dir, name, LAYOUTS_EXT)) |path| {
        defer alloc.free(path);
        if (infra_fs.cwd().readFileAlloc(alloc, path, 1 << 20)) |data| {
            if (std.json.parseFromSliceLeaky(std.json.Value, alloc, data, .{})) |root| {
                if (root == .object) {
                    if (root.object.get("cache")) |c| {
                        if (parseCacheSlot(alloc, c)) |slot| return slot;
                    }
                }
            } else |_| {}
        } else |_| {}
    } else |_| {}
    const path = paths.designSiblingPath(alloc, project_dir, name, AUTO_EXT) catch return null;
    defer alloc.free(path);
    const data = infra_fs.cwd().readFileAlloc(alloc, path, 1 << 20) catch return null;
    const root = std.json.parseFromSliceLeaky(std.json.Value, alloc, data, .{}) catch return null;
    return parseCacheSlot(alloc, root);
}

/// Persist the layout list to `.layouts.json`, carrying the existing cache
/// slot over unchanged. Best-effort: a write failure just means the list
/// reverts to what was last on disk.
fn writeLayouts(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8, layouts: []const SavedLayout) void {
    writeLayoutsFile(alloc, project_dir, name, layouts, readCacheSlot(alloc, project_dir, name));
}

/// As `writeLayouts`, but for a `?sub=` scoped sub circuit writes its per-sub
/// sidecar. The sub store carries no auto-cache slot (sub previews always solve
/// fresh), so only the layouts array is persisted. `sub == null` delegates to
/// `writeLayouts` (design store, cache preserved).
fn writeLayoutsSub(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8, sub: ?[]const u8, layouts: []const SavedLayout) void {
    if (sub == null) return writeLayouts(alloc, project_dir, name, layouts);
    const path = layoutsSidecar(alloc, project_dir, name, sub, LAYOUTS_EXT) orelse return;
    defer alloc.free(path);
    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    writeLayoutsFileJson(w, layouts, null) catch return;
    writeFileAll(path, aw.written()) catch return;
}

/// Persist layouts + cache slot to `.layouts.json` (the whole sidecar).
fn writeLayoutsFile(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    layouts: []const SavedLayout,
    cache: ?CacheSlot,
) void {
    const path = paths.designSiblingPath(alloc, project_dir, name, LAYOUTS_EXT) catch return;
    defer alloc.free(path);
    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    writeLayoutsFileJson(w, layouts, cache) catch return;
    writeFileAll(path, aw.written()) catch return;
}

/// Serialize the sidecar to its on-disk shape: an optional top-level
/// `"default":"<name>"` (the entry whose `default` flag is set, if any),
/// the optional `"cache"` slot, then the `layouts` array. Score fields
/// (hpwl/loop/caps) are flattened onto each entry and omitted when unscored.
fn writeLayoutsFileJson(w: *std.Io.Writer, layouts: []const SavedLayout, cache: ?CacheSlot) std.Io.Writer.Error!void {
    try w.writeAll("{");
    for (layouts) |L| {
        if (!L.default) continue;
        try w.writeAll("\"default\":");
        try writeJsonStr(w, L.name);
        try w.writeAll(",");
        break;
    }
    if (cache) |c| {
        try w.writeAll("\"cache\":");
        try writeCacheSlotJson(w, c);
        try w.writeAll(",");
    }
    try w.writeAll("\"layouts\":[");
    for (layouts, 0..) |L, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll(NAME_OPEN);
        try writeJsonStr(w, L.name);
        try w.writeAll(",\"kind\":");
        try writeJsonStr(w, L.kind);
        try w.print(",\"ts\":{d}", .{L.ts});
        if (L.rough) try w.writeAll(",\"rough\":true");
        if (L.routes) |sr| {
            try w.writeAll(",\"routes\":");
            try writeSavedRoutesJson(w, sr);
        }
        if (L.outline) |o| {
            try w.writeAll(",\"outline\":");
            try writeSavedOutlineJson(w, o);
        }
        if (L.score) |s| try w.print(",\"hpwl\":{d},\"loop\":{d},\"caps\":{d},\"objective\":{d}", .{ s.hpwl, s.loop, s.caps, s.objective });
        try w.writeAll(",\"parts\":[");
        for (L.parts, 0..) |pt, j| {
            if (j > 0) try w.writeAll(",");
            try w.writeAll(REF_OPEN);
            try writeJsonStr(w, pt.ref);
            try w.print(",\"x\":{d},\"y\":{d},\"rot\":{d}", .{ pt.x, pt.y, pt.rot });
            try writePoseSideLocked(w, pt.side, pt.locked);
            if (pt.origin.len > 0) {
                try w.writeAll(ORIGIN_OPEN);
                try writeJsonStr(w, pt.origin);
            }
            try w.writeAll("}");
        }
        try w.writeAll("]}");
    }
    try w.writeAll("]}");
}

/// Two saved layouts are duplicates when their score matches: the headline
/// objective and its two visible raw terms (HPWL + loop length) agree to 0.1.
/// This is the "duplicate layout" the panel dedups on — what the user reads as
/// the same row, e.g. repeated Regenerate runs that reconverge to the same
/// objective even if a part lands a grid step off. (Position isn't compared:
/// the deterministic optimizer can reach an equal-score arrangement that differs
/// by a hair, which the user still sees as the same layout.) Unscored legacy
/// entries never match — they're kept rather than guessed at.
fn sameLayoutScore(a: ?LayoutScore, b: ?LayoutScore) bool {
    const x = a orelse return false;
    const y = b orelse return false;
    return @abs(x.objective - y.objective) < 0.1 and @abs(x.hpwl - y.hpwl) < 0.1 and @abs(x.loop - y.loop) < 0.1;
}

/// Panel sort key: lower is better, so the best layout sorts to the top. Entries
/// predating the objective field fall back to HPWL+loop; unscored entries last.
fn layoutCost(L: SavedLayout) f64 {
    const s = L.score orelse return std.math.inf(f64);
    return if (s.objective > 0) s.objective else s.hpwl + s.loop;
}
fn layoutLessByScore(_: void, a: SavedLayout, b: SavedLayout) bool {
    return layoutCost(a) < layoutCost(b);
}

/// Collapse saved layouts that are the same arrangement into one, so the panel
/// never lists a placement twice (chiefly repeated Regenerate runs that
/// converged identically). Input order is preserved; each group's survivor keeps
/// a manual name over an auto stamp and the default flag if any member had it.
fn dedupLayouts(alloc: std.mem.Allocator, layouts: []const SavedLayout) []const SavedLayout {
    var out: std.ArrayListUnmanaged(SavedLayout) = .empty;
    for (layouts) |L| {
        var merged = false;
        for (out.items) |*K| {
            if (!sameLayoutScore(K.score, L.score)) continue;
            const keep_default = K.default or L.default;
            // Prefer to keep a manual (named) entry over an auto stamp.
            if (std.mem.eql(u8, L.kind, KIND_MANUAL) and !std.mem.eql(u8, K.kind, KIND_MANUAL)) K.* = L;
            K.default = keep_default;
            merged = true;
            break;
        }
        if (!merged) out.append(alloc, L) catch return layouts;
    }
    return out.items;
}

/// The saved-layout list for the panel: duplicate arrangements collapsed (legacy
/// histories that accumulated repeated Regenerate runs — the cleanup is persisted
/// once), then sorted best-score-first. The on-disk order stays newest-first
/// (only this display copy is re-sorted), so recordAutoLayout keeps its
/// "newest = entry 0" assumption. Empty for sub-scoped previews.
fn displayLayouts(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8, sub: ?[]const u8) []const SavedLayout {
    const raw = readLayoutsSub(alloc, project_dir, name, sub);
    const deduped = dedupLayouts(alloc, raw);
    if (deduped.len != raw.len) writeLayoutsSub(alloc, project_dir, name, sub, deduped);
    const sorted = alloc.dupe(SavedLayout, deduped) catch return deduped;
    std.mem.sort(SavedLayout, sorted, {}, layoutLessByScore);
    return sorted;
}

/// Append an auto-recorded snapshot of the just-generated `placement` to the
/// layout history — unless that arrangement is *already saved* (under any name,
/// auto or manual), in which case there is nothing new to record. Then prunes
/// auto entries past `MAX_AUTO_LAYOUTS`.
fn recordAutoLayout(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8, p: optimizer.Placement, params: optimizer.Params) void {
    const existing = readLayouts(alloc, project_dir, name);
    const score = LayoutScore{ .hpwl = p.score.hpwl_mm, .loop = p.score.loop_mm, .caps = p.score.loop_caps, .objective = p.breakdown.objective };
    const parts = posesFromPlacement(alloc, p) orelse return;
    // Dedup against EVERY saved layout, not just the newest: a regen that
    // reproduces an arrangement already in the list (same objective + HPWL +
    // loop) adds nothing. If the match is the newest entry and predates the
    // objective field, backfill it in place. A rough solve that reconverges to
    // an existing (untagged) arrangement still tags it rough so the panel's
    // "rough seeded" status lights up.
    for (existing, 0..) |L, i| {
        if (!sameLayoutScore(L.score, score)) continue;
        if (params.rough and !L.rough) {
            tagRough(alloc, project_dir, name, existing, i);
        } else if (i == 0 and (L.score == null or L.score.?.objective <= 0)) {
            backfillNewestScore(alloc, project_dir, name, existing, score);
        }
        return;
    }
    const now = clock.timestamp();
    const entry = SavedLayout{
        .name = fmtAutoName(alloc, now) catch return,
        .kind = KIND_AUTO,
        .ts = now,
        .score = score,
        .parts = parts,
        .rough = params.rough,
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

/// Rewrite the layout list with the `rough` flag set on entry `idx` — used when
/// a Rough solve reconverges to an arrangement already saved without the flag,
/// so the schematic's Module-layouts panel still reads "rough seeded" rather
/// than recording a duplicate row.
fn tagRough(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8, existing: []const SavedLayout, idx: usize) void {
    var out: std.ArrayListUnmanaged(SavedLayout) = .empty;
    for (existing, 0..) |L, i| {
        var e = L;
        if (i == idx) e.rough = true;
        out.append(alloc, e) catch return;
    }
    writeLayouts(alloc, project_dir, name, out.items);
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

/// Read the optimizer cache's poses into a slice of `RefPose`, or null if
/// no cache slot exists. Strings are owned by `alloc` (request lifetime),
/// which outlives the `solve` call that consumes them.
fn readAutoPoses(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8) ?[]const optimizer.RefPose {
    const slot = readCacheSlot(alloc, project_dir, name) orelse return null;
    const parts = slot.parts orelse return null;
    const out = alloc.alloc(optimizer.RefPose, parts.len) catch return null;
    for (parts, 0..) |pt, i| out[i] = .{ .ref = pt.ref, .x = pt.x, .y = pt.y, .rot = pt.rot, .side = pt.side, .locked = pt.locked };
    return out;
}

/// One placed part exported to the KiCad sync: centre (mm) + rotation (deg,
/// CCW) + board side. The sync stamps these onto a footprint it inserts for
/// the first time.
pub const SyncPose = struct { x: f64, y: f64, rot: f64, side: optimizer.Side = .top };

/// Re-export so the KiCad sync can name a module's poses (`loadSubBlockPoses`)
/// without importing the placement layer directly.
pub const RefPose = optimizer.RefPose;

/// Choose the part poses the KiCad sync seeds first-insertion placement (and
/// GND vias) from, as `RefPose`s, or null when the design has no layout at all.
/// Preference: the user-marked **default** layout first, then the newest manual
/// snapshot, then the most recent recorded layout of any kind, then the raw
/// optimizer-cache slot. Both `loadSyncLayout` (placement) and
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
    if (chosen) |parts| return refPosesFromParts(alloc, parts);
    // No named/recorded layouts — fall back to the bare optimizer cache.
    const poses = readAutoPoses(alloc, project_dir, name) orelse return null;
    if (poses.len == 0) return null;
    return poses;
}

/// Saved-layout parts as sync `RefPose`s (null on allocation failure).
fn refPosesFromParts(alloc: std.mem.Allocator, parts: []const PartPose) ?[]const optimizer.RefPose {
    const out = alloc.alloc(optimizer.RefPose, parts.len) catch return null;
    for (parts, 0..) |pt, i| out[i] = .{ .ref = pt.ref, .x = pt.x, .y = pt.y, .rot = pt.rot, .side = pt.side, .locked = pt.locked };
    return out;
}

/// `chooseModuleSnapshot` result: the snapshot to seed from, plus — when a
/// different snapshot covers strictly more of the module's current parts —
/// that fuller alternative (surfaced as a staleness hint, never auto-taken
/// over a ★).
const SnapshotChoice = struct {
    chosen: *const SavedLayout,
    /// Fuller non-chosen snapshot (only set when it beats `chosen`).
    alt: ?*const SavedLayout = null,
    /// How many module parts `alt` covers.
    alt_n: usize = 0,
};

/// Pick which of a module's saved snapshots to seed a Stamp / sync from,
/// scoring each by how many of its refs still exist in the module's *current*
/// flatten (`ok_of`, ref-des → origin_key). A starred (★) snapshot that
/// bridges at all wins outright — the user's blessing (and what the KiCad sync
/// seeds from). With no ★, best coverage wins, manual beating auto on equal
/// coverage — replacing a blind "newest manual first": a module that grew
/// since an old hand save would stamp 42 of 59 parts from the stale snapshot
/// while a newer, fuller one sat unused. When the winner is a ★ that a
/// non-starred snapshot out-covers, that snapshot is reported as `alt` so the
/// UI can flag the stale star. Null when no snapshot bridges anything (caller
/// may fall back to the volatile cache slot).
fn chooseModuleSnapshot(
    layouts: []const SavedLayout,
    ok_of: *const std.StringHashMap([]const u8),
) ?SnapshotChoice {
    var starred: ?*const SavedLayout = null;
    var starred_score: usize = 0;
    var best: ?*const SavedLayout = null;
    var best_score: usize = 0;
    for (layouts) |*L| {
        if (L.parts.len == 0) continue;
        var score: usize = 0;
        for (L.parts) |p| {
            const ok = ok_of.get(p.ref) orelse continue;
            if (ok.len > 0) score += 1;
        }
        if (score == 0) continue;
        if (L.default) {
            starred = L;
            starred_score = score;
            continue;
        }
        const cur = best orelse {
            best = L;
            best_score = score;
            continue;
        };
        const manual = std.mem.eql(u8, L.kind, KIND_MANUAL);
        const cur_manual = std.mem.eql(u8, cur.kind, KIND_MANUAL);
        const wins = if (score == best_score) manual and !cur_manual else score > best_score;
        if (wins) {
            best = L;
            best_score = score;
        }
    }
    if (starred) |st| {
        const stale = best != null and best_score > starred_score;
        return .{ .chosen = st, .alt = if (stale) best else null, .alt_n = if (stale) best_score else 0 };
    }
    const b = best orelse return null;
    return .{ .chosen = b };
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
    for (poses) |p| m.put(p.ref, .{ .x = p.x, .y = p.y, .rot = p.rot, .side = p.side }) catch return m;
    return m;
}

/// One GND-plane stitching via exported to the KiCad sync: centre (mm), pad +
/// hole diameter (mm), and the net name it stitches down to the plane. Saved
/// layouts store only positions, so the vias are *computed* at sync time.
pub const SyncVia = struct { x: f64, y: f64, dia: f64, drill: f64, net: []const u8 };

/// The design named `source` flattened to ref-des → origin_key — the bridge
/// from a saved layout's ref-des keys (which carry that design's wrapper
/// prefix, e.g. the `tpsm84338` eval wraps the module in a `pwr` sub-block →
/// `pwr/U2`) to the module-local identity that survives renumbering. A
/// bare-ref alias is indexed for each prefixed ref so a layout saved without
/// the wrapper still bridges. Strings are duped onto `alloc` (the evaluator is
/// torn down before returning). Null when the source path can't be evaluated —
/// e.g. a `lib/modules/` defmodule with no design file.
fn sourceOriginKeys(alloc: std.mem.Allocator, project_dir: []const u8, source: []const u8) ?std.StringHashMap([]const u8) {
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
    netlist.collectInstances(alloc, dblock, "", &flat, dblock.refStyle()) catch return null;
    var ok_of = std.StringHashMap([]const u8).init(alloc);
    for (flat.items) |fi| {
        const ref = alloc.dupe(u8, fi.ref_des) catch return null;
        const ok = alloc.dupe(u8, fi.origin_key) catch return null;
        ok_of.put(ref, ok) catch return null;
        if (std.mem.lastIndexOfScalar(u8, ref, '/')) |slash| {
            ok_of.put(ref[slash + 1 ..], ok) catch return null;
        }
    }
    return ok_of;
}

/// Re-key layout poses from ref-des to origin_key through `ok_of`.
fn poseMapByOrigin(
    alloc: std.mem.Allocator,
    ok_of: *const std.StringHashMap([]const u8),
    layout: []const optimizer.RefPose,
) ?std.StringHashMap(SyncPose) {
    var pose_by_ok = std.StringHashMap(SyncPose).init(alloc);
    for (layout) |p| {
        const ok = ok_of.get(p.ref) orelse continue;
        if (ok.len == 0) continue;
        pose_by_ok.put(ok, .{ .x = p.x, .y = p.y, .rot = p.rot, .side = p.side }) catch return null;
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
    // Coverage-aware snapshot pick when the source design resolves (see
    // `chooseModuleSnapshot`); the legacy ★→manual→any→cache preference when it
    // doesn't (nothing to score against).
    const ok_of_opt = sourceOriginKeys(alloc, project_dir, sub_block.source);
    const layout: []const optimizer.RefPose = blk: {
        if (ok_of_opt) |*ok_of| {
            const layouts = readLayouts(alloc, project_dir, sub_block.source);
            if (chooseModuleSnapshot(layouts, ok_of)) |c|
                if (refPosesFromParts(alloc, c.chosen.parts)) |poses| break :blk poses;
        }
        break :blk chooseSyncPoses(alloc, project_dir, sub_block.source) orelse return null;
    };

    // origin_key → pose, via the design that produced the layout (see helper).
    const pose_by_ok = (if (ok_of_opt) |*ok_of|
        poseMapByOrigin(alloc, ok_of, layout)
    else
        null) orelse return layout;

    // Re-key onto sub_block's own flattened refs by origin_key. This is a
    // module-scoped re-key (matched by origin_key), not the grouped root, so
    // keep the prefixed walk regardless of the design's grouped-refdes setting.
    var flat2: std.ArrayListUnmanaged(export_kicad.FlatInstance) = .empty;
    netlist.collectInstances(alloc, sub_block.block, "", &flat2, .hierarchical) catch return layout;
    var out: std.ArrayListUnmanaged(optimizer.RefPose) = .empty;
    for (flat2.items) |fi| {
        if (fi.origin_key.len == 0) continue;
        const pose = pose_by_ok.get(fi.origin_key) orelse continue;
        out.append(alloc, .{ .ref = fi.ref_des, .x = pose.x, .y = pose.y, .rot = pose.rot, .side = pose.side }) catch return layout;
    }
    if (out.items.len == 0) return layout; // nothing bridged — let the caller prefix-strip
    return out.toOwnedSlice(alloc) catch layout;
}

/// A sub-block's module-layout seed: poses keyed by stable `origin_key`, plus
/// which module snapshot supplied them (shown in the Stamp palette so a user
/// can tell a ★-blessed pull from a best-coverage fallback). `alt_*` name a
/// fuller non-chosen snapshot when the chosen ★ has gone stale (module grew
/// since it was starred) — a hint to re-star, never taken automatically.
pub const SubBlockSeeds = struct {
    map: std.StringHashMap(SyncPose),
    layout_name: []const u8,
    starred: bool,
    alt_name: []const u8 = "",
    alt_n: usize = 0,
    /// The chosen snapshot's persisted copper (module-local coordinates and
    /// module-local net names) — Stamp carries it onto the parent board.
    routes: ?SavedRoutes = null,
    /// One entry per flattened module pin (net, origin_key, pad) — the bridge
    /// buildSubSeedsJson uses to map module net names to parent nets. Only
    /// populated when the snapshot carries routes.
    pin_nets: []const SubPinNet = &.{},
};

/// A flattened module pin sample: which module-local net the pad at
/// (origin_key, pad) sits on. See `SubBlockSeeds.pin_nets`.
const SubPinNet = struct { net: []const u8, origin_key: []const u8, pad: []const u8 };

/// The sub-block's saved module layout — the starred (★) snapshot when one
/// bridges, else best current-flatten coverage (`chooseModuleSnapshot`) — keyed
/// by stable `origin_key`, so a caller can match each flattened part by its
/// `FlatInstance.origin_key`, the module-local identity that survives the
/// parent design's `(hierarchical-ids)` renumbering.
///
/// The layout is keyed by the *module-standalone* ref-des (`U1`, `R1`, `C1`…,
/// as the `/pcb-layout/<module>` solve assigned them when the layout was saved),
/// which is NOT the parent-renumbered ref (`buck_3v3d/U11`, `mcu/C57`). The
/// missing link is `standalone-ref → origin_key`, and the ONLY way to reproduce
/// the exact standalone ref-des is to re-flatten the module the same way the
/// layout was made — `modules_mod.resolveModuleBlock` (real instantiation first,
/// else zero-arg) — NOT the parent's already-renumbered `sub_block.block`, and
/// NOT `sourceOriginKeys` (which re-resolves the module *source path*, failing
/// on a `lib/modules/` defmodule). With that bridge: layout ref `C1` →
/// origin_key `100nF@3#0` → board part `mcu/C57` (same origin_key). Null when
/// the module has no saved layout or nothing bridges.
pub fn subBlockPoseByOriginKey(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    sub_block: env_mod.SubBlock,
) ?SubBlockSeeds {
    const resolved = modules_mod.resolveModuleBlock(alloc, project_dir, sub_block.source) orelse return null;
    // Standalone-flatten ref-des → origin_key (its refs key the saved layout).
    var flat: std.ArrayListUnmanaged(export_kicad.FlatInstance) = .empty;
    netlist.collectInstances(alloc, resolved.block, "", &flat, .hierarchical) catch return null;
    var ok_of = std.StringHashMap([]const u8).init(alloc);
    for (flat.items) |fi| ok_of.put(fi.ref_des, fi.origin_key) catch return null;
    const layouts = readLayouts(alloc, project_dir, sub_block.source);
    const choice = chooseModuleSnapshot(layouts, &ok_of) orelse {
        // No snapshot bridges — last resort is the volatile optimizer cache.
        const poses = readAutoPoses(alloc, project_dir, sub_block.source) orelse return null;
        const m = seedMapFromPoses(alloc, &ok_of, poses) orelse return null;
        return .{ .map = m, .layout_name = "cache", .starred = false };
    };
    const layout = refPosesFromParts(alloc, choice.chosen.parts) orelse return null;
    const m = seedMapFromPoses(alloc, &ok_of, layout) orelse return null;
    return .{
        .map = m,
        .layout_name = choice.chosen.name,
        .starred = choice.chosen.default,
        .alt_name = if (choice.alt) |a| a.name else "",
        .alt_n = choice.alt_n,
        .routes = choice.chosen.routes,
        .pin_nets = if (choice.chosen.routes != null) modulePinNets(alloc, resolved.block, &ok_of) else &.{},
    };
}

/// Flatten the module's nets the same way its instances were flattened and
/// sample every pin as (net, origin_key, pad) — the module side of the
/// stamped-copper net-name bridge. Empty on any failure (copper then falls
/// back to slug-prefixed net names, which is what a module-private net
/// flattens to in the parent anyway).
fn modulePinNets(
    alloc: std.mem.Allocator,
    block: *const env_mod.DesignBlock,
    ok_of: *const std.StringHashMap([]const u8),
) []const SubPinNet {
    var fnets: std.ArrayListUnmanaged(export_kicad.FlatNet) = .empty;
    netlist.collectNets(alloc, block, "", &fnets, .hierarchical) catch return &.{};
    var pn: std.ArrayListUnmanaged(SubPinNet) = .empty;
    for (fnets.items) |net| {
        for (net.pins) |pin| {
            const ok = ok_of.get(pin.ref_des) orelse continue;
            if (ok.len == 0) continue;
            pn.append(alloc, .{ .net = net.name, .origin_key = ok, .pad = pin.pin }) catch return &.{};
        }
    }
    return pn.toOwnedSlice(alloc) catch &.{};
}

/// Layout ref → origin_key → pose (null when nothing bridges).
fn seedMapFromPoses(
    alloc: std.mem.Allocator,
    ok_of: *const std.StringHashMap([]const u8),
    layout: []const optimizer.RefPose,
) ?std.StringHashMap(SyncPose) {
    var m = std.StringHashMap(SyncPose).init(alloc);
    for (layout) |p| {
        const ok = ok_of.get(p.ref) orelse continue;
        if (ok.len == 0) continue;
        m.put(ok, .{ .x = p.x, .y = p.y, .rot = p.rot, .side = p.side }) catch return null;
    }
    if (m.count() == 0) return null;
    return m;
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

/// Persist the generated layout (its tuning weights + ref/x/y/rot per part)
/// into the `"cache"` slot of `.layouts.json`, then drop the superseded
/// standalone `.autolayout.json` so each design carries one layout sidecar.
/// Best-effort: a write failure just means a regenerate.
fn writeAutoCache(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8, p: optimizer.Placement, params: optimizer.Params) void {
    const parts = posesFromPlacement(alloc, p) orelse return;
    const layouts = readLayouts(alloc, project_dir, name);
    writeLayoutsFile(alloc, project_dir, name, layouts, .{ .params = params, .parts = parts });
    if (paths.designSiblingPath(alloc, project_dir, name, AUTO_EXT)) |legacy| {
        defer alloc.free(legacy);
        infra_fs.cwd().deleteFile(legacy) catch |e| switch (e) {
            // Usually already gone — only first post-upgrade solve has one.
            error.FileNotFound => {},
            else => {},
        };
    } else |_| {}
}

/// Serialize a cache slot to `{"params":{…},"parts":[{ref,x,y,rot}, …]}` —
/// the weights so the controls reflect what produced the layout, the parts
/// for the cache.
fn writeCacheSlotJson(w: *std.Io.Writer, c: CacheSlot) std.Io.Writer.Error!void {
    try w.print("{{\"params\":{{\"loop_w\":{d},\"w_align\":{d},\"w_congest\":{d},\"cap_w_max\":{d},\"grid\":{s}}},", .{
        c.params.loop_w,                                   c.params.w_align, c.params.w_congest, c.params.cap_w_max,
        if (c.params.grid_courtyards) "true" else "false",
    });
    try w.writeAll(PARTS_OPEN);
    for (c.parts orelse &[_]PartPose{}, 0..) |pt, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll(REF_OPEN);
        try writeJsonStr(w, pt.ref);
        try w.print(",\"x\":{d},\"y\":{d},\"rot\":{d}", .{ pt.x, pt.y, pt.rot });
        try writePoseSideLocked(w, pt.side, pt.locked);
        try w.writeAll("}");
    }
    try w.writeAll("]}");
}

/// Read the tuning weights stored alongside the cached layout, or null when
/// no cache slot exists.
fn readAutoParams(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8) ?optimizer.Params {
    const slot = readCacheSlot(alloc, project_dir, name) orelse return null;
    return slot.params;
}

/// Tuning weights parsed from the request query, plus whether any were present
/// (`tuned`) and whether a fresh solve is required (`regen` = tuned or `?regen`).
const Tuning = struct {
    params: optimizer.Params,
    tuned: bool,
    regen: bool,
    /// `?show=cache` — display the optimizer-cache layout even when a starred
    /// layout exists. The live-regen completion reload uses it so a fresh
    /// Regenerate/Rough result is what you SEE (instead of the page snapping
    /// back to the starred layout and the run looking like a no-op).
    show_cache: bool = false,
};

fn parseTuning(req: *httpz.Request) Tuning {
    var p = optimizer.Params{};
    var tuned = false;
    var regen = false;
    var show_cache = false;
    const q = req.query() catch return .{ .params = p, .tuned = false, .regen = false };
    if (q.get("regen") != null) regen = true;
    if (q.get("show")) |v| show_cache = std.mem.eql(u8, v, "cache");
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
    // Experimental: allow drawn courtyards to overlap their clearance bands by N mm
    // (default 0 = touch only, no overlap). See Params.courtyard_overlap.
    if (q.get("court_overlap")) |v| {
        p.courtyard_overlap = parseF(v, p.courtyard_overlap);
        tuned = true;
    }
    // Routing/copper room between courtyards (mm); group cohesion + zoning weights.
    if (q.get("route_gap")) |v| {
        p.route_gap = parseF(v, p.route_gap);
        tuned = true;
    }
    if (q.get("group_w")) |v| {
        p.group_w = parseF(v, p.group_w);
        tuned = true;
    }
    if (q.get("group_zone_w")) |v| {
        p.group_zone_w = parseF(v, p.group_zone_w);
        tuned = true;
    }
    if (q.get("group_loop_relief")) |v| {
        p.group_loop_relief = parseF(v, p.group_loop_relief);
        tuned = true;
    }
    if (q.get("zone_pack")) |v| {
        p.zone_pack = !(std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "false"));
        tuned = true;
    }
    // `?rough=1` — the rough module-clustered / pad-anchored seed (the "Rough"
    // button); forces a fresh solve down the `Params.rough` path.
    if (q.get("rough")) |v| {
        p.rough = !(std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "false"));
        if (p.rough) tuned = true;
    }
    // `?remaining=1` — "Rough remaining": pin every part the base layout (the
    // ★, else the auto cache) covers and rough-place only the uncovered/new
    // parts around them. The incremental button for a hand-finished board.
    if (q.get("remaining")) |v| {
        p.remaining = !(std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "false"));
        if (p.remaining) tuned = true;
    }
    return .{ .params = p, .tuned = tuned, .regen = regen or tuned, .show_cache = show_cache };
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

/// The editable control stack shared by the full page and the editable embed
/// (`?embed=1&edit=1`): the action toolbar (Regenerate / Rough / Save as… /
/// Update / Undo / Redo / Reset / zoom), the collapsible tuning/score/route
/// panels, and the hidden legends (revealed by their chips). The full page
/// prepends its own header (title + Schematic⇄PCB nav); the editable embed skips
/// that — its parent schematic card carries the Schematic/PCB toggle instead.
fn writeEditControls(
    w: *std.Io.Writer,
    placement: optimizer.Placement,
    name: []const u8,
    src: LayoutSource,
    grid_only: bool,
    routed: ?router.RouteResult,
    shown: optimizer.Params,
    ro_params: router.RouteParams,
    n_drc: usize,
    single: bool,
) std.Io.Writer.Error!void {
    try writeScorebar(w, placement, name, src, single);
    // When showing the plain grid placeholder, say so — the score is the raw
    // grid's, not an optimized layout, and Regenerate computes the real one.
    if (grid_only) try w.writeAll(
        "<div class=\"pcb-note\">Showing parts on a plain grid — no layout computed yet. " ++
            "Drag parts to arrange, or hit <b>Regenerate</b> to auto-place.</div>",
    );
    // Secondary controls collapse behind a chip row (accordion: one panel open at
    // a time) so the default view is just the toolbar + board. The Route panel
    // auto-opens when the page loaded already routed, so its status is visible
    // without a click.
    const route_open = routed != null;
    try writeTabsRow(w, route_open);
    try w.writeAll("<div class=\"pcb-panels\">");
    try writeTuning(w, shown);
    try writeScoreView(w, shown, name);
    const rp_warn = if (routed) |r| router.returnPathViolations(placement, r, router.RETURN_PATH_RADIUS_MM) else 0;
    try writeRoutePanel(w, ro_params, routed, n_drc, rp_warn, route_open);
    try w.writeAll("</div>");
    try writeLegend(w, placement, true); // hidden; revealed by the Legend chip
    try writeHeatLegend(w); // hidden; revealed by the Heatmap chip
    try writeNetLegend(w); // hidden; revealed by the Net colours chip
}

// Action-bar group wrappers — small inline-flex clusters separated by thin rules
// so the buttons read as grouped (place / save / edit) rather than one long row.
// Extracted as consts (each used 3× in writeScorebar).
const BAR_SEP = "<span class=\"bar-sep\"></span>";
const BAR_GRP = "<span class=\"bar-grp\">";
const BAR_GRP_END = "</span>" ++ BAR_SEP;

fn writeScorebar(w: *std.Io.Writer, p: optimizer.Placement, name: []const u8, src: LayoutSource, single: bool) std.Io.Writer.Error!void {
    try w.writeAll("<div class=\"pcb-bar\">");
    try writeSourceChip(w, src);
    // Headline objective + its delta only — the per-term breakdown (wire / loop /
    // area / congestion) moved into the Score panel so this action bar stays a
    // clean row of "what to do". Filled/updated by showScore().
    try w.writeAll("<span class=\"score\" id=\"sc-obj\" " ++
        "title=\"weighted objective the optimizer minimizes (term breakdown in the Score chip)\">objective ");
    try w.print("{d:.1}</span>", .{p.breakdown.objective});
    try w.writeAll("<span class=\"delta\" id=\"sc-obj-d\"></span>");
    try w.writeAll(BAR_SEP);
    // Auto-place group: Regenerate re-runs the optimizer live; Rough drops the
    // legible module-clustered seed. Both nav to a fresh solve.
    try w.writeAll(BAR_GRP);
    try w.writeAll("<a class=\"btn\" id=\"pcb-regen\" href=\"/pcb-layout/");
    try writeAttr(w, name);
    try w.writeAll("?regen=1\" title=\"Re-run the optimizer and watch it converge live\">Regenerate</a>");
    try w.writeAll("<a class=\"btn\" id=\"pcb-rough\" href=\"/pcb-layout/");
    try writeAttr(w, name);
    try w.writeAll("?remaining=1\" title=\"Keep every part the \u{2605} (or last auto) layout already places, " ++
        "and rough-place only the new/uncovered parts around them — the incremental rough for a " ++
        "hand-finished board that grew\">Rough remaining</a>");
    try w.writeAll(BAR_GRP_END);
    // Save group: Save as… mints a new snapshot; Update overwrites the loaded one
    // in place (disabled until a saved layout is the active edit target).
    try w.writeAll(BAR_GRP);
    if (single) {
        // Designs keep ONE layout: Save overwrites it in place (auto-starred
        // server-side), so there's no name prompt, no Update, no active chip.
        try w.writeAll("<button class=\"btn\" id=\"pcb-saveas\" title=\"Save the board layout (the design's single layout — " ++
            "overwritten in place, used by KiCad sync and the fab outputs)\">Save layout</button>");
    } else try w.writeAll("<button class=\"btn\" id=\"pcb-saveas\" title=\"Save the current placement under a new name\">Save as…</button>");
    if (!single) {
        try w.writeAll("<button class=\"btn\" id=\"pcb-update\" disabled " ++
            "title=\"Save changes back into the loaded layout (overwrite in place)\">Update</button>");
        try w.writeAll("<span class=\"lay-active\" id=\"pcb-active\" style=\"display:none\"></span>");
    }
    try w.writeAll(BAR_GRP_END);
    // Edit group: undo / redo the last manual move-or-rotate (Ctrl+Z / Ctrl+Shift+Z),
    // and reset back to the auto layout. Undo/redo start disabled (empty history).
    try w.writeAll(BAR_GRP);
    try w.writeAll("<button class=\"btn\" id=\"pcb-undo\" disabled title=\"Undo last move / rotate (Ctrl+Z)\">↶ Undo</button>");
    try w.writeAll("<button class=\"btn\" id=\"pcb-redo\" disabled title=\"Redo (Ctrl+Shift+Z)\">↷ Redo</button>");
    try w.writeAll("<button class=\"btn\" id=\"pcb-reset\" title=\"Discard manual edits, restore the auto layout\">Reset</button>");
    try w.writeAll("<button class=\"btn\" id=\"pcb-outline\" title=\"Draw the board outline: click, then drag a rectangle " ++
        "on the board (a plain click clears it). Grid-snapped; saved with the layout (Save/Update); becomes the board edge " ++
        "the renderers draw and the board-edge DRC checks.\">\u{25AD} Outline</button>");
    try w.writeAll("<button class=\"btn\" id=\"pcb-outline-poly\" title=\"Draw a POLYGON board outline (L/T shapes, cutout-free " ++
        "notches): click to place vertices (grid-snapped), click the first vertex or press Enter to close, Backspace removes " ++
        "the last vertex, Esc cancels. After closing, drag a vertex handle to edit. Saved with the layout (Save/Update); " ++
        "becomes the exact board edge the renderers draw, the board-edge DRC measures, and the Gerber Edge.Cuts traces." ++
        "\">\u{2B21} Poly</button>");
    try w.writeAll("<button class=\"btn\" id=\"pcb-draw\" title=\"Hand-route (X): click a pad to start a trace, click to " ++
        "fix corners (45\u{b0}/grid snapped, Shift = free angle), V drops a via and flips layer, click a same-net pad or " ++
        "double-click to finish, Backspace steps back, Esc ends. Right-click deletes the track/via under the cursor. " ++
        "Copper is saved with the layout (Save/Update).\">\u{270E} Draw</button>");
    try w.writeAll(BAR_GRP_END);
    // Fab handoff: the complete manufacturing package at the saved (★) layout.
    try w.writeAll(BAR_GRP);
    try w.writeAll("<a class=\"btn\" id=\"pcb-fab\" href=\"/api/pcb-gerbers/");
    try writeAttr(w, name);
    try w.writeAll("\" download title=\"Download the fab package (ZIP): Gerber copper / mask / paste / silk / " ++
        "board profile + Excellon drills + centroid CSV, at the saved (\u{2605}) layout with its saved routed " ++
        "copper. Save a layout first.\">\u{2913} Gerbers</a>");
    try w.writeAll(BAR_GRP_END);
    try w.writeAll("<span class=\"zoom-grp\"><button class=\"btn\" id=\"z-out\" title=\"Zoom out\">−</button>");
    try w.writeAll("<button class=\"btn\" id=\"z-in\" title=\"Zoom in\">+</button>");
    try w.writeAll("<button class=\"btn\" id=\"z-fit\" title=\"Reset zoom\">Fit</button></span>");
    try w.writeAll("<span class=\"savemsg\" id=\"pcb-savemsg\"></span>");
    try w.print("<span class=\"muted\" title=\"drag part to move · hover + R to rotate · Ctrl+Z undo · " ++
        "two-finger drag / middle-drag to pan · scroll wheel or pinch to zoom · snaps to {d} mm grid · press ? for all shortcuts\">" ++
        "drag · R rotate · Ctrl+Z undo · ? help</span>", .{optimizer.GRID_MM});
    try w.writeAll("</div>");
}

/// Saved-layouts panel: the named history (manual snapshots + auto-recorded
/// optimizer runs), newest first, each row showing its kind, score, and delta
/// of (HPWL+loop) versus the layout currently on screen (`auto`). The Load /
/// delete buttons carry the layout name in data attributes for BOARD_JS.
/// How many of the placement's parts a saved layout covers, matched the same
/// way a Load applies poses: by ref-des, else by module-local origin key. A
/// count below the part total means the design grew since the layout was
/// saved (a stale ★) — the uncovered parts would sit at the origin on Load.
pub fn layoutCoverage(L: SavedLayout, p: optimizer.Placement) usize {
    var covered: usize = 0;
    for (p.parts, 0..) |part, i| {
        const origin = if (i < p.instances.len and p.instances[i].origin_key.len > 0)
            p.instances[i].origin_key
        else
            part.ref_des;
        for (L.parts) |pt| {
            const by_origin = pt.origin.len > 0 and std.mem.eql(u8, pt.origin, origin);
            if (by_origin or std.mem.eql(u8, pt.ref, part.ref_des)) {
                covered += 1;
                break;
            }
        }
    }
    return covered;
}

fn writeLayoutsPanel(w: *std.Io.Writer, layouts: []const SavedLayout, auto: LayoutScore, placement: optimizer.Placement) std.Io.Writer.Error!void {
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
        const cov = layoutCoverage(L, placement);
        if (cov < placement.parts.len) {
            try w.print(
                "<span class=\"lay-cover\" title=\"Covers {d} of {d} current parts — the design grew since " ++
                    "this layout was saved; re-save (or Rough remaining) to refresh it\">{d}/{d}</span>",
                .{ cov, placement.parts.len, cov, placement.parts.len },
            );
        }
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

/// Chip row that toggles the collapsible control panels (Tuning / Score /
/// Route — an accordion, one open at a time) plus the two board-view overlays
/// (the blame Heatmap tint and the trace Legend). The Route chip starts active
/// when the page loaded already routed, so its status panel is visible without a
/// click. All behaviour is wired in BOARD_JS by the `data-panel` / id hooks.
/// Opening tag shared by the board-view toggle chips (Ratsnest / Net colours /
/// Heatmap / Legend) — extracted so the repeated literal stays in one place.
const VIEW_CHIP_OPEN = "<label class=\"view-chip\" ";

fn writeTabsRow(w: *std.Io.Writer, route_open: bool) std.Io.Writer.Error!void {
    try w.writeAll("<div class=\"pcb-tabs\">");
    try w.writeAll("<button class=\"tab-chip\" data-panel=\"panel-tune\" " ++
        "title=\"Steering weights — re-runs the optimizer\">Tuning</button>");
    try w.writeAll("<button class=\"tab-chip\" data-panel=\"panel-score\" " ++
        "title=\"Score breakdown + re-weigh — doesn't move parts\">Score</button>");
    try w.writeAll(if (route_open)
        "<button class=\"tab-chip active\" data-panel=\"panel-route\" title=\"Autoroute + DRC\">Route</button>"
    else
        "<button class=\"tab-chip\" data-panel=\"panel-route\" title=\"Autoroute + DRC\">Route</button>");
    try w.writeAll("<span class=\"tabs-sep\"></span>");
    try w.writeAll(VIEW_CHIP_OPEN ++
        "title=\"Show the ratsnest airwires + decoupling-loop overlays (pin-to-pin) — " ++
        "uncheck to hide them and read the bare placement\">" ++
        "<input type=\"checkbox\" id=\"v-rats\" checked> Ratsnest</label>");
    try w.writeAll(VIEW_CHIP_OPEN ++
        "title=\"Give every net its own pad/airwire colour — no-connect white, GND " ++
        "brown, power warm, each signal net a distinct colour — so connectivity " ++
        "reads off the board without the schematic\">" ++
        "<input type=\"checkbox\" id=\"v-netcol\" checked> Net colours</label>");
    try w.writeAll(VIEW_CHIP_OPEN ++
        "title=\"Tint each part green→red by its share of the objective (cost/blame heatmap)\">" ++
        "<input type=\"checkbox\" id=\"v-heat\"> Heatmap</label>");
    try w.writeAll(VIEW_CHIP_OPEN ++ "title=\"Show the trace / via colour key\">" ++
        "<input type=\"checkbox\" id=\"v-legend\"> Legend</label>");
    try w.writeAll("</div>");
}

// ── Net-colours view palette ────────────────────────────────────────────────
// Four buckets, not the full criticality taxonomy: no-connect → white, ground →
// one brown, power-family → a vivid warm colour (red/orange/yellow band), and
// every other (signal) net → its own distinct colour spread around the wheel.
// The goal is "tell the nets apart at a glance", not "label each net's role".
const NET_BROWN = "#8a5a2b"; // every ground variant (GND/AGND/PGND/…)
const NET_WHITE = "#ffffff"; // no-connect nets + pads on no net at all

/// `h` in degrees [0,360), `s`/`l` in [0,1] → `"#rrggbb"` written into `buf`.
fn hslHex(buf: *[7]u8, h: f64, s: f64, l: f64) []const u8 {
    const c = (1 - @abs(2 * l - 1)) * s;
    const hp = h / 60.0;
    const x = c * (1 - @abs(@mod(hp, 2.0) - 1));
    var r: f64 = 0;
    var g: f64 = 0;
    var b: f64 = 0;
    if (hp < 1) {
        r = c;
        g = x;
    } else if (hp < 2) {
        r = x;
        g = c;
    } else if (hp < 3) {
        g = c;
        b = x;
    } else if (hp < 4) {
        g = x;
        b = c;
    } else if (hp < 5) {
        r = x;
        b = c;
    } else {
        r = c;
        b = x;
    }
    const m = l - c / 2.0;
    const rgb = [3]u8{ chan(r + m), chan(g + m), chan(b + m) };
    const HEXD = "0123456789abcdef";
    buf[0] = '#';
    for (rgb, 0..) |v, i| {
        buf[1 + i * 2] = HEXD[v >> 4];
        buf[2 + i * 2] = HEXD[v & 0x0f];
    }
    return buf[0..7];
}

fn chan(v: f64) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
}

/// True for a no-connect net name (mirrors `optimizer.isNoConnect`, private).
fn isNoConnectName(name: []const u8) bool {
    const s = shortName(name);
    if (std.mem.eql(u8, s, "NC") or std.mem.eql(u8, s, "DNC")) return true;
    return std.mem.startsWith(u8, s, "unconnected") or std.mem.startsWith(u8, s, "no_connect");
}

/// True for a digit-first voltage-rail name — `6V`, `12V`, `3V3`, `5V0`, `1V8`.
/// The shared `classifyNetName` only treats `V`-prefixed names as power, so these
/// common rail spellings would otherwise colour as signals. Kept LOCAL to the
/// colour view (not folded into the classifier) so it can't shift the placement/
/// router net-class behaviour that consumes `classifyNetName`.
fn looksLikeVoltageRail(name: []const u8) bool {
    const s = shortName(name);
    var i: usize = 0;
    while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    if (i == 0 or i >= s.len) return false; // must start with digit(s)…
    return std.ascii.toUpper(s[i]) == 'V'; // …immediately followed by 'V'
}

/// Colour for one net: white (no-connect), brown (ground), a warm colour stepped
/// through the red→yellow band per power net (`pi`), or a distinct colour stepped
/// around the rest of the wheel per signal net (`si`). The golden-angle step
/// (137.508°) keeps consecutive nets far apart in hue so they read as distinct.
/// `pi`/`si` are bumped so each net in its bucket gets a fresh slot.
fn netColorHex(name: []const u8, buf: *[7]u8, pi: *usize, si: *usize) []const u8 {
    if (isNoConnectName(name)) return NET_WHITE;
    const cls = module_policy.classifyNetName(name);
    if (cls == .ground) return NET_BROWN;
    const is_power = cls == .power or cls == .input_rail or cls == .switch_node or looksLikeVoltageRail(name);
    if (is_power) {
        const h = @mod(@as(f64, @floatFromInt(pi.*)) * 137.508, 50.0);
        pi.* += 1;
        return hslHex(buf, h, 0.92, 0.52);
    }
    const h = 60.0 + @mod(@as(f64, @floatFromInt(si.*)) * 137.508, 300.0);
    si.* += 1;
    return hslHex(buf, h, 0.72, 0.58);
}

/// Emit `"links":[ {a,ax,ay,b,bx,by,k,net?}, … ]` — the ratsnest airwires. Each
/// carries its collapsed `netKey` (when known) so the Net-colours view can tint
/// it by class.
fn writeLinks(w: *std.Io.Writer, links: []const optimizer.Link) std.Io.Writer.Error!void {
    try w.writeAll("\"links\":[");
    for (links, 0..) |l, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{{\"a\":{d},\"ax\":{d},\"ay\":{d},", .{ l.a, l.ax, l.ay });
        try w.print("\"b\":{d},\"bx\":{d},\"by\":{d},\"k\":\"{s}\"", .{ l.b, l.bx, l.by, kindStr(l.kind) });
        if (l.net.len > 0) {
            try w.writeAll(",\"net\":");
            try writeJsonStr(w, netKey(l.net));
        }
        try w.writeAll("}");
    }
    try w.writeAll("],");
}

/// Emit `"netcolor":{ "<netKey>":"<hex>", … }` — a per-net colour map keyed by
/// the same collapsed `netKey` the pad/airwire `net` fields use. The Net-colours
/// view paints each pad/airwire straight from this (no class indirection): white
/// for no-connect, brown for ground, warm for power, a distinct colour per signal
/// net. Dotted bypass-stub nets collapse to one rail key (first net assigns the
/// slot — same key always lands the same bucket). `netColorHex` walks the buckets
/// and steps the per-bucket index so distinct nets get distinct colours.
fn writeNetColors(w: *std.Io.Writer, alloc: std.mem.Allocator, p: optimizer.Placement) HandlerError!void {
    try w.writeAll("\"netcolor\":{");
    var seen = std.StringHashMap(void).init(alloc);
    var first = true;
    var pi: usize = 0;
    var si: usize = 0;
    var buf: [7]u8 = undefined;
    for (p.nets) |net| {
        const k = netKey(net.name);
        if (seen.contains(k)) continue;
        try seen.put(k, {});
        const hex = netColorHex(net.name, &buf, &pi, &si);
        if (!first) try w.writeAll(",");
        first = false;
        try writeJsonStr(w, k);
        try w.writeAll(":");
        try writeJsonStr(w, hex);
    }
    try w.writeAll("}");
}

/// Swatch key for the Net-colours view, shown only while that view is enabled —
/// the four buckets the per-net colouring uses (signal shown as a spectrum since
/// every signal net gets its own colour).
fn writeNetLegend(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll("<div class=\"net-legend\" id=\"net-legend\">" ++
        "<span class=\"net-h\">Net colours</span>" ++
        "<span class=\"net-sw\"><i style=\"background:" ++ NET_WHITE ++ "\"></i>No-connect</span>" ++
        "<span class=\"net-sw\"><i style=\"background:" ++ NET_BROWN ++ "\"></i>GND</span>" ++
        "<span class=\"net-sw\"><i style=\"background:linear-gradient(90deg,#e5484d,#ff924d,#f2cd2e)\"></i>Power</span>" ++
        "<span class=\"net-sw\"><i style=\"background:linear-gradient(90deg," ++
        "#3fb950,#2dd4bf,#58a6ff,#bc6bff,#f778ba)\"></i>Signal — one colour per net</span>" ++
        "<span class=\"muted\">each signal net gets its own colour · ground returns stay as the dashed loop overlay</span></div>");
}

/// Gradient key for the blame Heatmap, shown only while that view is enabled.
fn writeHeatLegend(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll("<div class=\"heat-legend\" id=\"heat-legend\" hidden>" ++
        "<span class=\"heat-h\">Heatmap</span>" ++
        "<span class=\"heat-lbl\">cheap</span><span class=\"heat-bar\"></span><span class=\"heat-lbl\">costly</span>" ++
        "<span class=\"muted\">each part tinted by its share of the objective · " ++
        "scale fixed when toggled on (re-toggle to re-base) · hover a part for the raw number</span>" ++
        "</div>");
}

/// Tuning panel: number inputs for the steering weights + a grid toggle and an
/// Apply button (wired in BOARD_JS to reload with the values as query params,
/// which forces a regenerate). Values reflect the weights behind the layout.
fn writeTuning(w: *std.Io.Writer, params: optimizer.Params) std.Io.Writer.Error!void {
    try w.writeAll("<div class=\"pcb-tune pcb-panel\" id=\"panel-tune\" hidden><span class=\"tune-h\">Tuning</span>");
    try w.print("<label title=\"placement regularizer\">Compact w <input id=\"t-align\" type=\"number\" step=\"0.05\" min=\"0\" value=\"{d}\"></label>", .{optimizer.effAlignW(params)});
    try w.print("<label>Loop <input id=\"t-loop\" type=\"number\" step=\"0.5\" min=\"0\" value=\"{d}\"></label>", .{params.loop_w});
    try w.print("<label>Congest <input id=\"t-cong\" type=\"number\" step=\"0.5\" min=\"0\" value=\"{d}\"></label>", .{params.w_congest});
    try w.writeAll("<label class=\"tune-chk\"><input id=\"t-grid\" type=\"checkbox\"");
    if (params.grid_courtyards) try w.writeAll(CHECKED);
    try w.writeAll("> Grid edges</label>");
    try w.writeAll("<button class=\"btn\" id=\"t-apply\">Apply &amp; regenerate</button>");
    try w.writeAll("<span class=\"muted\">re-runs the optimizer with these weights</span></div>");
}

/// The `<head>` + opening `<body>` of the layout page: charset/viewport metas,
/// title, and the navbar + page styles (embeds add the chrome-trimming CSS and
/// the `.embed` body class).
fn writeDocHead(w: *std.Io.Writer, title: []const u8, embed: bool, edit_embed: bool) std.Io.Writer.Error!void {
    try w.writeAll("<!DOCTYPE html><html><head><meta charset=\"utf-8\">");
    try w.writeAll("<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">");
    try w.print("<title>{s} — PCB Layout</title>", .{title});
    try w.writeAll("<style>");
    try w.writeAll(assets_css.NAVBAR_CSS);
    try w.writeAll(PAGE_CSS);
    if (embed) try w.writeAll(EMBED_CSS);
    try w.writeAll("</style></head><body");
    // `.embed` trims chrome; `.embed-edit` re-enables drag (the read-only preview
    // forces a default cursor) for the editable embed used by the sub-circuit toggle.
    if (edit_embed) {
        try w.writeAll(" class=\"embed embed-edit\"");
    } else if (embed) {
        try w.writeAll(" class=\"embed\"");
    }
    try w.writeAll(">");
}

/// Score-view panel: per-metric enable toggles + display weights that recompute
/// the headline objective *in the browser* from the breakdown's stored raw terms
/// — no re-placement, no server round-trip. Lets you re-weigh or drop each metric
/// to see how it moves the total (e.g. disable Wire + Align + Congest to compare
/// two layouts on pure hot-loop inductance). Defaults mirror the engine weights,
/// so the headline matches the optimizer's objective until you change something.
fn writeScoreView(w: *std.Io.Writer, params: optimizer.Params, name: []const u8) std.Io.Writer.Error!void {
    try w.writeAll("<div class=\"pcb-tune pcb-scoreview pcb-panel\" id=\"panel-score\" hidden><span class=\"tune-h\">Score</span>");
    // Live per-term readout, relocated off the action bar to declutter it. The
    // spans are updated in place by showScore(); Recompute + Export JSON sit here
    // too as score-detail utilities (rarely needed mid-edit).
    try w.writeAll("<div class=\"sc-readout\">");
    try w.writeAll("<span class=\"score sc-sub\" id=\"sc-hpwl\" title=\"signal wirelength: RSMT estimate (mm)\">wire …</span>");
    try w.writeAll("<span class=\"delta\" id=\"sc-hpwl-d\"></span>");
    try w.writeAll("<span class=\"score sc-sub\" id=\"sc-loop\" title=\"weighted decoupling-loop term (loop_w × value-weighted loop length)\">loop …</span>");
    try w.writeAll("<span class=\"delta\" id=\"sc-loop-d\"></span>");
    try w.writeAll("<span class=\"score sc-sub\" id=\"sc-ind\" title=\"hot-loop connection inductance (nH) — the scored loop metric\">loop … nH</span>");
    try w.writeAll("<span class=\"delta\" id=\"sc-ind-d\"></span>");
    try w.writeAll("<span class=\"score sc-sub\" id=\"sc-align\" title=\"sub-module courtyard bounding-box area (mm²) — compactness term\">area …</span>");
    try w.writeAll("<span class=\"delta\" id=\"sc-align-d\"></span>");
    try w.writeAll("<span class=\"score sc-sub\" id=\"sc-cong\" title=\"routing congestion (w_congest × RUDY overflow)\">cong …</span>");
    try w.writeAll("<span class=\"delta\" id=\"sc-cong-d\"></span>");
    try w.writeAll("<button class=\"btn\" id=\"pcb-score\" title=\"Recompute the objective on the server for the current positions\">Recompute</button>");
    try w.writeAll("<a class=\"btn\" href=\"/api/pcb-layout/");
    try writeAttr(w, name);
    try w.writeAll("\" target=\"_blank\" title=\"Download positions + full score breakdown as JSON\">Export JSON</a>");
    try w.writeAll("</div>");
    try svRow(w, "wire", "Wire", 1.0);
    try svRow(w, "loop", "Loop", params.loop_w);
    try svRow(w, "align", "Compact", optimizer.effAlignW(params));
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
fn writeRoutePanel(
    w: *std.Io.Writer,
    params: router.RouteParams,
    routed: ?router.RouteResult,
    n_drc: usize,
    n_rp: usize,
    start_open: bool,
) std.Io.Writer.Error!void {
    try w.writeAll("<div class=\"pcb-route pcb-panel\" id=\"panel-route\"");
    if (!start_open) try w.writeAll(" hidden");
    try w.writeAll("><span class=\"tune-h\">Route</span>");
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
/// `module_source` = the sub-block's module name (empty when the sub-block
/// has no module provenance): renders an "Edit module layout" escape hatch
/// to the module's own full PCB page, where the spec panel saves into the
/// module file — the read-only preview stays read-only.
fn writeEmbedBar(w: *std.Io.Writer, module_source: []const u8) std.Io.Writer.Error!void {
    try w.writeAll("<div class=\"pcb-bar\">");
    if (module_source.len > 0 and std.mem.indexOfScalar(u8, module_source, '/') == null and
        !std.mem.endsWith(u8, module_source, ".sexp"))
    {
        try w.writeAll("<a class=\"btn\" target=\"_top\" title=\"Open the module's own PCB page — " ++
            "its spec panel saves the layout into lib/modules, so every design using it picks the change up\" href=\"/pcb-layout/");
        try writeAttr(w, module_source);
        try w.writeAll("\">Edit module layout →</a>");
    }
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
        try w.print("<span class=\"route-stat {s}\" id=\"r-stat\">routed {d}/{d} nets · {d} vias", .{ cls, r.routed, r.total, r.vias.len });
        if (r.failed.len > 0) {
            try w.writeAll(" · missing: ");
            for (r.failed, 0..) |fname, i| {
                if (i > 0) try w.writeAll(", ");
                try writeHtmlText(w, fname);
            }
        }
        try w.writeAll("</span>");
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

fn writeLegend(w: *std.Io.Writer, p: optimizer.Placement, hidden: bool) std.Io.Writer.Error!void {
    var fallback_count: usize = 0;
    for (p.parts) |part| {
        if (part.fallback) fallback_count += 1;
    }
    try w.writeAll(if (hidden) "<div class=\"pcb-legend\" id=\"pcb-legend\" hidden>" else "<div class=\"pcb-legend\" id=\"pcb-legend\">");
    try w.writeAll("<span class=\"sw prox\"></span> power leg (L1)");
    try w.writeAll("<span class=\"sw l2gnd\"></span> GND return (images under trace, L2 plane)");
    try w.writeAll("<span class=\"sw viadot\"></span> GND via (L1↔L2, Ø from route params)");
    try w.writeAll("<span class=\"sw sig\"></span> signal");
    if (fallback_count > 0) {
        try w.print("<span class=\"note\">{d} part(s) using a placeholder box (no library footprint) — shown dashed</span>", .{fallback_count});
    }
    try w.writeAll("</div>");
}

// ── Sidebar (single-part properties panel, KiCad-style) ──────────────────

/// KiCad-style properties sidebar: empty until a part is clicked on the board,
/// then BOARD_JS (`renderProps`) fills it with just that one part's properties
/// — ref, value, footprint (courtyard-edit), live position/rotation, pin→net
/// list, and a schematic jump. Every per-part field already ships in the
/// embedded `PCB.parts`, so this only emits the container + the empty-state
/// hint; the part count and the schematic-jump base (`/schematics/` vs
/// `/modules/`, stashed as `data-schbase`) are the lone server-rendered bits.
fn writeSidebar(w: *std.Io.Writer, p: optimizer.Placement, sch_base: []const u8) HandlerError!void {
    try w.writeAll("<aside class=\"pcb-side\">");
    try w.writeAll("<div class=\"side-h\">Properties</div>");
    try w.writeAll("<div id=\"prop-body\" class=\"prop-body\" data-schbase=\"");
    try writeAttr(w, sch_base);
    try w.print(
        "\"><div class=\"prop-empty\">Click a part on the board to see its properties." ++
            "<br><span class=\"prop-empty-n\">{d} components</span></div>",
        .{p.instances.len},
    );
    try w.writeAll("</div></aside>");
}

// ── Embedded board data (consumed by BOARD_JS) ───────────────────────────

const LocalPt = struct { x: f64, y: f64 };

/// Page-mode flags for the embedded `PCB` object: `read_only` drives `PCB.ro`
/// (BOARD_JS skips all edit wiring when set); `embed` is any embedded chrome
/// (read-only preview *or* editable embed) — neither has the 3D toggle, so both
/// skip the filesystem-scanning STEP-model resolution; `sub` is the `?sub=` slug
/// a sub circuit's save/star POSTs append to target the per-sub layout sidecar.
const PcbDataOpts = struct {
    read_only: bool,
    embed: bool,
    sub: ?[]const u8,
    /// Prebuilt `buildSubSeedsJson` object (the blob writer has no block).
    subseeds_json: []const u8 = "{}",
    /// Which module snapshot each group's seeds came from (`buildSubSeedsJson`).
    subseedinfo_json: []const u8 = "{}",
    /// Sub-block name → module source, for palette name links (`buildSubModulesJson`).
    submodules_json: []const u8 = "{}",
    /// The blob's "board" rect came from a user-DRAWN layout outline (the ▭
    /// tool), so the viewer treats it as editable (PCB.outline).
    outline_drawn: bool = false,
    /// Top-level design (not a module / ?sub page): exactly ONE layout — the
    /// viewer saves straight to it (no name prompt, no saved-layouts panel).
    single: bool = false,
    /// SavedRoutes the shown copper was restored from (ShownView.saved) —
    /// lets writeRoutedArrays re-emit per-segment stamp group tags.
    saved_routes: ?SavedRoutes = null,
    /// Per-group module copper for Stamp (`buildSubSeedsJson`): the ★ module
    /// snapshot's tracks/vias in module-local coordinates with net names
    /// mapped to this design's nets.
    subroutes_json: []const u8 = "{}",
};

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

/// Raw per-part objective blame (the same attribution the PNG heatmap uses), in
/// `alloc`; empty on alloc failure. The client normalizes for the colour ramp —
/// excluding the anchor IC — and refreshes it on drag via the score endpoint.
fn partBlameRaw(alloc: std.mem.Allocator, p: optimizer.Placement, params: optimizer.Params) []const f64 {
    const blame = alloc.alloc(f64, p.parts.len) catch return &.{};
    optimizer.perPartBlame(p, params, blame);
    return blame;
}

/// Emit one part's `,"pads":[…]` array — each pad's geometry, number, optional
/// custom-poly copper outline, and resolved net (looked up in `pin_net`, keyed
/// `"<ref>|<num>"`). Opens with the `,"pads"` key and closes the array, so the
/// caller continues straight into `,"silk":…`.
fn writePadsJson(
    w: *std.Io.Writer,
    alloc: std.mem.Allocator,
    pt: optimizer.Part,
    pin_net: std.StringHashMap([]const u8),
) HandlerError!void {
    try w.writeAll(",\"pads\":[");
    for (pt.pads, 0..) |pad, j| {
        if (j > 0) try w.writeAll(",");
        try w.print("{{\"x\":{d},\"y\":{d},\"w\":{d},\"h\":{d},\"shape\":", .{ pad.x, pad.y, pad.w, pad.h });
        try writeJsonStr(w, pad.shape);
        try w.writeAll(",\"num\":");
        try writeJsonStr(w, pad.number);
        // Custom pad: the real copper outline so the shared FP engine draws
        // the polygon, not the bounding box.
        if (pad.poly.len >= 3) {
            try w.writeAll(",\"poly\":[");
            for (pad.poly, 0..) |pp, k| {
                if (k > 0) try w.writeAll(",");
                try w.print(PT_PAIR_FMT, .{ pp[0], pp[1] });
            }
            try w.writeAll("]");
        }
        // Drilled bore (mm) so the viewer punches a hole through thru/npth pads.
        if (pad.drill > 0) {
            try w.print(",\"drill\":{d}", .{pad.drill});
            if (pad.npth) try w.writeAll(",\"npth\":true");
        }
        const pkey = try std.fmt.allocPrint(alloc, "{s}|{s}", .{ pt.ref_des, pad.number });
        if (pin_net.get(pkey)) |nk| {
            try w.writeAll(",\"net\":");
            try writeJsonStr(w, nk);
        }
        try w.writeAll("}");
    }
    try w.writeAll("]");
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
    opts: PcbDataOpts,
) HandlerError!void {
    // ref → part index, and "ref|pin" → collapsed net (for pad tags).
    var idx = std.StringHashMap(usize).init(alloc);
    for (p.parts, 0..) |pt, i| try idx.put(pt.ref_des, i);
    // ref → footprint name (for the courtyard editor).
    var fp_of = std.StringHashMap([]const u8).init(alloc);
    for (p.instances) |inst| try fp_of.put(inst.ref_des, inst.footprint);
    // ref → display value ("100nF", "STM32…") for the properties panel.
    var val_of = std.StringHashMap([]const u8).init(alloc);
    for (p.instances) |inst| try val_of.put(inst.ref_des, instLabel(inst));
    var pin_net = std.StringHashMap([]const u8).init(alloc);
    for (p.nets) |net| {
        for (net.pins) |pin| {
            const key = try std.fmt.allocPrint(alloc, "{s}|{s}", .{ pin.ref_des, pin.pin });
            try pin_net.put(key, netKey(net.name));
        }
    }

    try w.writeAll("<script>const PCB=");
    try writeBlobHead(w, v, clearance, p, opts);
    // Server-computed objective breakdown of the layout on screen — the baseline
    // the live score deltas against. Same shape the /api/pcb-score endpoint returns.
    try w.print("\"caps\":{d},\"auto\":", .{p.score.loop_caps});
    try writeBreakdownJson(w, p.breakdown, params);
    try w.writeAll(",\"name\":");
    try writeJsonStr(w, name);
    try w.writeAll(",");
    try writeLayoutsJson(w, layouts);

    // Raw per-part objective blame → the live "Heatmap" toggle tints each
    // courtyard by its share (client normalizes, excluding the anchor IC).
    const blame = partBlameRaw(alloc, p, params);

    // Parts.
    try w.writeAll(PARTS_OPEN);
    for (p.parts, 0..) |pt, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll(REF_OPEN);
        try writeJsonStr(w, pt.ref_des);
        // Renumber-stable module-local key, so a saved-layout Load can match on
        // it instead of the volatile ref-des (see PartPose.origin / bindLayLoad).
        try w.writeAll(ORIGIN_OPEN);
        try writeJsonStr(w, if (i < p.instances.len) p.instances[i].origin_key else "");
        try w.print(",\"x\":{d},\"y\":{d},\"rot\":{d},\"hw\":{d},\"hh\":{d},\"kind\":\"{s}\",\"fb\":{s}", .{
            pt.x,                                 pt.y,  pt.rot,
            pt.hw,                                pt.hh, if (pt.kind == .hub) "hub" else "passive",
            if (pt.fallback) "true" else "false",
        });
        // Courtyard-box centre offset (footprint-local; omitted when centred).
        if (pt.ccx != 0 or pt.ccy != 0) try w.print(",\"ccx\":{d},\"ccy\":{d}", .{ pt.ccx, pt.ccy });
        try writePoseSideLocked(w, pt.side, pt.locked);
        try w.print(",\"blame\":{d:.4},", .{if (i < blame.len) blame[i] else 0});
        try w.writeAll("\"fp\":");
        try writeJsonStr(w, fp_of.get(pt.ref_des) orelse "");
        try w.writeAll(",\"val\":");
        try writeJsonStr(w, val_of.get(pt.ref_des) orelse "");
        try writePadsJson(w, alloc, pt, pin_net);
        try w.writeAll(",\"silk\":{\"l\":[");
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

    // Airwires (each tagged with its collapsed net name for the Net-colours view).
    try writeLinks(w, p.links);

    // Per-net colour map the "Net colours" view paints pads + airwires from.
    try writeNetColors(w, alloc, p);
    try w.writeAll(",");

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
    try writeRoutedArrays(w, routed, violations, p.nets, opts.saved_routes);

    // Per-footprint STEP-model references (URL + KiCad offset/rotation) for the
    // 3D-view tab. Only the full page needs it; the embedded preview has no 3D
    // toggle, so it skips the (filesystem-scanning) model resolution entirely.
    try w.writeAll(",\"models\":");
    if (opts.embed) {
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
fn writeRoutedArrays(
    w: *std.Io.Writer,
    routed: ?router.RouteResult,
    violations: []const drc.Violation,
    nets: []const export_kicad.FlatNet,
    saved: ?SavedRoutes,
) std.Io.Writer.Error!void {
    try w.writeAll("\"tracks\":[");
    if (routed) |r| for (r.tracks, 0..) |t, i| {
        if (i > 0) try w.writeAll(",");
        try w.print(TRACK_JSON_FMT, .{ t.x1, t.y1, t.x2, t.y2, t.layer, t.width });
        try writeJsonStr(w, netNameOf(nets, t.net));
        // Stamp group tag — restoreRoutes maps SavedRoutes 1:1, so the source
        // entry at the same index carries this segment's tag (fresh ?route=1
        // copper has no source and stays untagged).
        if (saved) |sr| if (i < sr.tracks.len and sr.tracks[i].g.len > 0) {
            try w.writeAll(",\"g\":");
            try writeJsonStr(w, sr.tracks[i].g);
        };
        try w.writeAll("}");
    };
    try w.writeAll(VIAS_ARR_OPEN);
    if (routed) |r| for (r.vias, 0..) |vi, i| {
        if (i > 0) try w.writeAll(",");
        try w.print(VIA_JSON_FMT, .{ vi.x, vi.y, vi.dia, vi.drill });
        try writeJsonStr(w, netNameOf(nets, vi.net));
        if (saved) |sr| if (i < sr.vias.len and sr.vias[i].g.len > 0) {
            try w.writeAll(",\"g\":");
            try writeJsonStr(w, sr.vias[i].g);
        };
        try w.writeAll("}");
    };
    try w.writeAll("],\"drc\":[");
    for (violations, 0..) |vio, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{{\"x\":{d},\"y\":{d},\"gap\":{d},\"clr\":{d},\"k\":\"{s}\"}}", .{ vio.x, vio.y, vio.gap, vio.clearance, drcKindStr(vio.kind) });
    }
    // Names of the nets the router could NOT fully connect — the actionable
    // half of the routed/total count (which connections are missing, not just
    // how many). Empty when everything routed or no route ran.
    try w.writeAll("],\"unrouted\":[");
    if (routed) |r| for (r.failed, 0..) |name, i| {
        if (i > 0) try w.writeAll(",");
        try writeJsonStr(w, name);
    };
    try w.writeAll("]");
}

/// The PCB blob's leading scalar/flag fields: projection, grid, board rect
/// (the placement's — carries a drawn outline when one was applied), the
/// read-only/sub flags, and the Stamp seed poses. Split from writePcbData
/// purely to keep both under the function-length cap.
fn writeBlobHead(w: *std.Io.Writer, v: View, clearance: f64, p: optimizer.Placement, opts: PcbDataOpts) HandlerError!void {
    try w.print("{{\"scale\":{d},\"minx\":{d},\"miny\":{d},", .{ v.scale, v.minx, v.miny });
    try w.print("\"margin\":{d},\"grid\":{d},\"w\":{d},\"h\":{d},", .{ MARGIN_MM, optimizer.GRID_MM, v.width, v.height });
    try w.print("\"clr\":{d},\"cmargin\":{d},", .{ clearance, geometry.BBOX_MARGIN_MM });
    // Outline rectangle (world mm) — the authored `(board (size W H) …)` or
    // the shown layout's drawn outline; null when neither exists. A
    // non-rectangular board also carries its exact polygon (`board_poly`,
    // `[[x,y],…]`) — the rect is then that polygon's bounding box.
    if (p.board_rect) |br| {
        try w.print("\"board\":{{\"x\":{d},\"y\":{d},\"w\":{d},\"h\":{d}}},", .{ br.minx, br.miny, br.w, br.h });
    } else {
        try w.writeAll("\"board\":null,");
    }
    if (p.board_poly) |poly| {
        try w.writeAll("\"board_poly\":[");
        for (poly, 0..) |pp, i| {
            if (i > 0) try w.writeAll(",");
            try w.print(PT_PAIR_FMT, .{ pp[0], pp[1] });
        }
        try w.writeAll("],");
    } else {
        try w.writeAll("\"board_poly\":null,");
    }
    // Read-only flag for the embedded per-sub-block preview — BOARD_JS skips all
    // edit wiring (drag/rotate/route/save) when set, leaving a pan/zoom viewer.
    try w.print("\"ro\":{s},", .{if (opts.read_only) "true" else "false"});
    // `sub` slug when this page is a `?sub=` scoped sub circuit — BOARD_JS appends
    // it as `?sub=` to the save/delete/star/rescore POSTs so they persist to the
    // per-sub layout sidecar instead of the parent design's.
    if (opts.sub) |sq| {
        try w.writeAll("\"sub\":");
        try writeJsonStr(w, sq);
        try w.writeAll(",");
    } else {
        try w.writeAll("\"sub\":null,");
    }
    if (opts.outline_drawn) try w.writeAll("\"outline_drawn\":true,");
    if (opts.single) try w.writeAll("\"single\":true,");
    // Per-sub-block module-layout seed poses for the palette's Stamp button,
    // plus which snapshot supplied each group's seeds (tooltip/coverage).
    try w.writeAll("\"subseeds\":");
    try w.writeAll(if (opts.subseeds_json.len > 0) opts.subseeds_json else "{}");
    try w.writeAll(",\"subseedinfo\":");
    try w.writeAll(if (opts.subseedinfo_json.len > 0) opts.subseedinfo_json else "{}");
    try w.writeAll(",\"submodules\":");
    try w.writeAll(if (opts.submodules_json.len > 0) opts.submodules_json else "{}");
    // Per-group module copper (net-mapped, module-local coords) for Stamp.
    try w.writeAll(",\"subroutes\":");
    try w.writeAll(if (opts.subroutes_json.len > 0) opts.subroutes_json else "{}");
    try w.writeAll(",");
}

/// A routed feature's net NAME for the persistable route JSON ("" for −1).
fn netNameOf(nets: []const export_kicad.FlatNet, idx: i32) []const u8 {
    if (idx < 0 or idx >= nets.len) return "";
    return nets[@intCast(idx)].name;
}

/// Short label for a DRC violation kind (shown in the marker tooltip).
fn drcKindStr(k: drc.Kind) []const u8 {
    return switch (k) {
        .via_pad => "via↔pad",
        .via_via => "via↔via",
        .via_track => "via↔track",
        .track_track => "track↔track",
        .track_pad => "track↔pad",
        .pad_pad => "pad↔pad",
        .annular => "annular ring",
        .board_edge => "board edge",
    };
}

// ── Small helpers ────────────────────────────────────────────────────────

/// Emit `"layouts":[ … ],` — the saved-layout history for the client. Each
/// entry carries its name, kind, optional score, and `parts` as a ref → {x,y,
/// rot, origin?} map so a Load reads positions by the renumber-stable `origin`
/// (falling back to the ref key for legacy entries). Trailing comma included.
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
        if (L.routes) |sr| {
            try w.writeAll(",\"routes\":");
            try writeSavedRoutesJson(w, sr);
        }
        if (L.outline) |o| {
            try w.writeAll(",\"outline\":");
            try writeSavedOutlineJson(w, o);
        }
        try w.writeAll(",\"parts\":{");
        for (L.parts, 0..) |pt, j| {
            if (j > 0) try w.writeAll(",");
            try writeJsonStr(w, pt.ref);
            try w.print(":{{\"x\":{d},\"y\":{d},\"rot\":{d}", .{ pt.x, pt.y, pt.rot });
            try writePoseSideLocked(w, pt.side, pt.locked);
            if (pt.origin.len > 0) {
                try w.writeAll(ORIGIN_OPEN);
                try writeJsonStr(w, pt.origin);
            }
            try w.writeAll("}");
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

fn shortName(s: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, s, '/')) |i| return s[i + 1 ..];
    return s;
}

/// Net grouping key — dot-collapsed to the rail, sub-block prefix kept.
fn netKey(name: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, name, '.')) |i| return name[0..i];
    return name;
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

/// Emit `s` as HTML text content: `&`, `<`, `>` escaped, nothing else — for
/// interpolating net/ref names into server-rendered markup.
fn writeHtmlText(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    for (s) |c| switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        else => try w.writeByte(c),
    };
}

/// Emit `s` as a quoted, JSON-escaped string to a `std.Io.Writer`. This
/// serializer's output is emitted verbatim INSIDE a `<script>` element (the
/// `const PCB=…` data blob and the editor's `window.SCENE=`), so it must also
/// neutralize the `<script>`-context breakouts a plain JSON escaper misses:
/// `<` is escaped to `<` (so a net/ref/value/layout name containing
/// `</script>` can't close the tag → stored XSS), and U+2028/U+2029 are
/// escaped (they terminate a JS string literal in older engines).
pub fn writeJsonStr(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            '<' => try w.writeAll("\\u003c"),
            0xE2 => {
                if (i + 2 < s.len and s[i + 1] == 0x80 and (s[i + 2] == 0xA8 or s[i + 2] == 0xA9)) {
                    try w.writeAll(if (s[i + 2] == 0xA8) "\\u2028" else "\\u2029");
                    i += 2;
                } else try w.writeByte(c);
            },
            else => if (c < 0x20) try w.print("\\u{x:0>4}", .{c}) else try w.writeByte(c),
        }
    }
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
    \\<label>left <input id="court-x0" type="number" step="0.1"></label>
    \\<label>top <input id="court-y0" type="number" step="0.1"></label>
    \\<label>right <input id="court-x1" type="number" step="0.1"></label>
    \\<label>bottom <input id="court-y1" type="number" step="0.1"></label></div>
    \\<div class="court-fields" id="court-fields-offset" hidden>
    \\<label>Offset from pads <input id="court-off" type="number" step="0.05" min="0"> mm</label></div>
    \\<div id="court-full" class="court-full"></div>
    \\<div class="court-note" id="court-note">Drag any box edge — each edge moves independently (mm from the
    \\ part origin) and snaps to the grid. Saving rewrites the footprint file and applies to every design that uses it.</div>
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
    \\.src-chip{font-size:11px;padding:2px 9px;border-radius:10px;border:1px solid #30363d;color:#8b949e;cursor:help;white-space:nowrap}
    \\.src-chip.src-spec{color:#3fb950;border-color:#238636}
    \\.src-chip.src-snap{color:#58a6ff;border-color:#1f6feb}
    \\.src-chip.src-star{color:#e3b341;border-color:#9e6a03}
    \\.src-chip.src-cache{color:#d29922;border-color:#9e6a03}
    \\.src-chip.src-grid{color:#f85149;border-color:#da3633}
    \\/* Fixed-footprint score chips: inline-block + min-width + tabular digits,
    \\   so a recalculated number never rewraps the toolbar and jumps the board. */
    \\.pcb-bar .score{font-weight:600;color:#e6edf3;background:#161b22;border:1px solid #21262d;border-radius:4px;padding:2px 8px;
    \\  display:inline-block;min-width:118px;text-align:center;font-variant-numeric:tabular-nums}
    \\.pcb-bar .delta{font-size:12px;font-weight:600;min-width:34px;display:inline-block;font-variant-numeric:tabular-nums}
    \\.pcb-bar .delta.up{color:#f85149}
    \\.pcb-bar .delta.down{color:#3fb950}
    \\.pcb-bar .bar-grp{display:inline-flex;gap:5px;align-items:center}
    \\.pcb-bar .bar-sep{width:1px;height:18px;background:#30363d;flex:none}
    \\.pcb-bar .btn{font:inherit;font-size:12px;border:1px solid #30363d;background:#21262d;border-radius:5px;
    \\  padding:3px 9px;cursor:pointer;text-decoration:none;color:#c9d1d9;display:inline-block}
    \\.pcb-bar .btn:hover{background:#30363d;border-color:#58a6ff;color:#e6edf3}
    \\.pcb-bar .btn:disabled{opacity:.45;cursor:default}
    \\.pcb-bar .zoom-grp{display:inline-flex;gap:4px}
    \\.pcb-bar .zoom-grp .btn{min-width:26px;text-align:center;padding:3px 7px}
    \\.pcb-bar .savemsg{font-size:12px;color:#3fb950;font-weight:600}
    \\.pcb-bar .lay-active{font-size:12px;color:#58a6ff;font-weight:600;font-style:italic}
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
    \\.lay-cover{font-size:9.5px;font-weight:700;border-radius:3px;padding:1px 5px;flex:none;background:#3a2c12;color:#d29922;cursor:help}
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
    \\.lay-row.active{background:#0d1f2d;box-shadow:inset 2px 0 0 #58a6ff}
    \\.lay-row.active.def{box-shadow:inset 2px 0 0 #58a6ff,inset 4px 0 0 #e3b341}
    \\/* Collapsible control deck: a chip row toggles one panel at a time, so the
    \\   default view is the toolbar + board instead of a stack of control strips. */
    \\.pcb-tabs{display:flex;gap:6px;align-items:center;margin:6px 0 8px;flex-wrap:wrap}
    \\.pcb-tabs .tab-chip{font:inherit;font-size:12px;border:1px solid #30363d;background:#161b22;color:#c9d1d9;
    \\  border-radius:14px;padding:3px 12px;cursor:pointer}
    \\.pcb-tabs .tab-chip:hover{background:#21262d;border-color:#58a6ff;color:#e6edf3}
    \\.pcb-tabs .tab-chip.active{background:rgba(31,111,235,.22);border-color:#58a6ff;color:#e6edf3}
    \\.pcb-tabs .tabs-sep{width:1px;height:18px;background:#30363d;margin:0 3px}
    \\.pcb-tabs .view-chip{display:inline-flex;gap:5px;align-items:center;font-size:12px;color:#c9d1d9;
    \\  border:1px solid #30363d;background:#161b22;border-radius:14px;padding:3px 11px;cursor:pointer}
    \\.pcb-tabs .view-chip:hover{border-color:#58a6ff;color:#e6edf3}
    \\.pcb-panel{background:#0d1117;border:1px solid #21262d;border-radius:8px;padding:8px 12px}
    \\.pcb-panel[hidden]{display:none}
    \\.pcb-panel .btn{font:inherit;font-size:12px;border:1px solid #30363d;background:#21262d;border-radius:5px;
    \\  padding:3px 9px;cursor:pointer;text-decoration:none;color:#c9d1d9;display:inline-block}
    \\.pcb-panel .btn:hover{background:#30363d;border-color:#58a6ff;color:#e6edf3}
    \\.heat-legend{display:flex;gap:9px;align-items:center;font-size:12px;color:#8b949e;margin:4px 0 12px;flex-wrap:wrap}
    \\.heat-legend[hidden]{display:none}
    \\.heat-legend .heat-h{font-weight:700;color:#f0f6fc}
    \\.heat-legend .heat-lbl{font-size:11px;color:#8b949e}
    \\.heat-legend .heat-bar{width:120px;height:10px;border-radius:5px;border:1px solid #30363d;
    \\  background:linear-gradient(90deg,#15302a,#b8860b,#c0392b)}
    \\.heat-legend .muted{font-size:11px;color:#6e7681}
    \\.net-legend{display:flex;gap:10px;align-items:center;font-size:12px;color:#8b949e;margin:4px 0 12px;flex-wrap:wrap}
    \\.net-legend[hidden]{display:none}
    \\.net-legend .net-h{font-weight:700;color:#f0f6fc}
    \\.net-legend .net-sw{display:inline-flex;gap:5px;align-items:center;font-size:11px;color:#c9d1d9}
    \\.net-legend .net-sw i{width:13px;height:13px;border-radius:3px;border:1px solid #30363d;display:inline-block}
    \\.net-legend .muted{font-size:11px;color:#6e7681}
    \\.pcb-legend[hidden]{display:none}
    \\.pcb-tune{display:flex;gap:10px;align-items:center;margin:2px 0 8px;flex-wrap:wrap;font-size:12px;color:#8b949e}
    \\.pcb-tune .tune-h{font-weight:700;color:#f0f6fc}
    \\.pcb-tune label{display:flex;gap:4px;align-items:center}
    \\.pcb-tune input[type=number]{width:54px;font:inherit;font-size:12px;border:1px solid #30363d;
    \\  background:#0d1117;color:#c9d1d9;border-radius:4px;padding:2px 4px}
    \\.pcb-tune .muted{font-size:11px;color:#6e7681}
    \\.pcb-scoreview .sv-row{display:flex;gap:3px;align-items:center}
    \\.pcb-scoreview .sv-wl{gap:1px}
    \\.pcb-scoreview input[type=number]{width:44px}
    \\.pcb-scoreview .sc-readout{flex-basis:100%;display:flex;gap:8px;align-items:center;flex-wrap:wrap;margin-bottom:6px}
    \\.sc-readout .score{font-weight:600;color:#e6edf3;background:#161b22;border:1px solid #21262d;border-radius:4px;padding:2px 8px}
    \\.sc-readout .sc-sub{font-weight:500;font-size:12px;color:#8b949e;background:#0d1117}
    \\.sc-readout .delta{font-size:12px;font-weight:600;min-width:30px}
    \\.sc-readout .delta.up{color:#f85149}
    \\.sc-readout .delta.down{color:#3fb950}
    \\.sc-readout .sc-off{opacity:.35;text-decoration:line-through}
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
    \\/* The scene (parts/pads/airwires/copper) is painted on the canvas; the
    \\   transparent SVG above it carries pointer events + light overlays. */
    \\.pcb-svg{background:transparent;border:1px solid #30363d;border-radius:8px;max-width:100%;height:auto;
    \\  touch-action:none;position:relative;z-index:1}
    \\.pcb-scene{position:absolute;pointer-events:none;z-index:0;border-radius:8px}
    \\.pcb-ref{font:600 9px system-ui,sans-serif;text-anchor:middle;pointer-events:none;user-select:none}
    \\.part{cursor:grab}
    \\/* Highlights are plain strokes — SVG drop-shadow filters forced slow
    \\   repaints of everything under them on every hover/drag. */
    \\.part.hl .court{stroke:#58a6ff!important;stroke-width:2!important}
    \\.part.sel .court{stroke:#58a6ff!important;stroke-width:2.4!important}
    \\.part.msel .court{stroke:#d2a8ff!important;stroke-width:2!important}
    \\/* Bottom-side (B.Cu) parts: blue body wash + blue pads, KiCad-style. The
    \\   geometry itself is mirrored by setT (scale(-1,1) inside the rotation). */
    \\.part.botside .court{fill:#122036}
    \\.padset.botside .pad{fill:#5b8dd6}
    \\/* Locked parts refuse drag/rotate/flip — dashed outline + no grab cursor. */
    \\.part.plocked{cursor:not-allowed}
    \\.part.plocked .court{stroke-dasharray:2 2!important;opacity:.92}
    \\/* Outline-draw mode: crosshair + a lit toolbar button while armed. */
    \\.pcb-svg.outline-mode{cursor:crosshair}
    \\#pcb-outline.on{color:#7ee787;border-color:#2ea043;box-shadow:0 0 0 1px #2ea04366}
    \\#pcb-draw.on{color:#f0c674;border-color:#b08800;box-shadow:0 0 0 1px #b0880066}
    \\/* Rigid sub-circuit hover: every member of the group glows together, so
    \\   "this whole block drags as one" is visible before you grab it. */
    \\.part.grp-hl .court{stroke:#7ee787!important;stroke-width:2!important}
    \\/* Sub-circuits palette (sidebar): one row per sub-block. */
    \\.sub-panel{border-top:1px solid #21262d}
    \\.sub-row{display:flex;align-items:center;gap:6px;padding:5px 12px;font-size:12px}
    \\.sub-row:hover{background:#1c2129}
    \\.sub-row.cur{background:#0d1f2d;box-shadow:inset 2px 0 0 #58a6ff}
    \\.sub-name{color:#e6edf3;flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
    \\a.sub-name:hover,a.grp-name:hover{color:#58a6ff;text-decoration:underline}
    \\.sub-n{color:#6e7681;font-size:11px}
    \\.sub-rigid,.sub-stamp{background:#21262d;border:1px solid #30363d;border-radius:4px;color:#c9d1d9;
    \\  font-size:11px;padding:1px 7px;cursor:pointer}
    \\.sub-rigid.on{color:#7ee787;border-color:#2ea04366}
    \\.sub-stamp:hover,.sub-rigid:hover{border-color:#58a6ff}
    \\.sub-cov{color:#d29922;font-size:10.5px;font-weight:600;cursor:help}
    \\.sub-noseed{color:#6e7681;font-size:11px;cursor:help;padding:1px 7px}
    \\/* Properties panel: the selected part's sub-circuit row (+ per-part Stamp). */
    \\.prop-grp{display:flex;align-items:center;gap:8px;padding:6px 14px;font-size:12px;flex-wrap:wrap}
    \\.grp-name{color:#7ee787;font-weight:600}
    \\.grp-n{color:#6e7681;font-size:11px}
    \\.grp-stamp{background:#21262d;border:1px solid #30363d;border-radius:4px;color:#c9d1d9;
    \\  font-size:11px;padding:1px 7px;cursor:pointer}
    \\.grp-stamp:hover{border-color:#58a6ff}
    \\.grp-noseed{color:#6e7681;font-size:11px;cursor:help}
    \\.marquee{fill:rgba(88,166,255,.12);stroke:#58a6ff;stroke-width:1;stroke-dasharray:4 3;vector-effect:non-scaling-stroke;pointer-events:none}
    \\.pad[data-net]{cursor:pointer}
    \\.pad.net-hl{fill:#f85149}
    \\.pn.net-hl{background:#5b1e28;color:#ffa198}
    \\/* Sticky net selection (click a pad / pin chip): a gold glow + ring on every
    \\   pad on that net, drawn as a filter so it shows over any fill (net colours
    \\   on or off). Re-click the same net, or click the empty board, to clear. */
    \\.pad.net-sel{stroke:#ffd33d;stroke-width:1.8;paint-order:stroke}
    \\/* The authored decoupling target pad on the IC (a cap's defined pin): red
    \\   glow instead of gold, so you can see exactly which pad each cap decouples. */
    \\.pad.net-sel-pin{stroke:#f85149;stroke-width:1.8;paint-order:stroke}
    \\.pn.net-sel{background:#3a2e07;color:#ffd33d;box-shadow:0 0 0 1px #ffd33d}
    \\.pcb-side{width:288px;flex:none;position:sticky;top:8px;max-height:calc(100vh - 16px);
    \\  overflow:auto;border:1px solid #21262d;border-radius:8px;background:#161b22}
    \\.side-h{font-size:13px;font-weight:600;padding:10px 12px;border-bottom:1px solid #21262d;position:sticky;top:0;background:#161b22;color:#f0f6fc}
    \\.prop-empty{padding:16px 14px;color:#8b949e;line-height:1.55;font-size:12.5px}
    \\.prop-empty-n{display:inline-block;margin-top:6px;color:#6e7681;font-size:11.5px}
    \\.prop-head{display:flex;align-items:baseline;gap:8px;padding:11px 12px;border-bottom:1px solid #21262d}
    \\.prop-ref{font-weight:700;font-size:16px;color:#f0f6fc}
    \\.prop-val{font-size:12.5px;color:#8b949e;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
    \\.prop-rows{padding:7px 12px;border-bottom:1px solid #21262d}
    \\.prop-row{display:flex;justify-content:space-between;gap:10px;padding:2.5px 0;font-size:12px}
    \\.prop-row .k{color:#8b949e}
    \\.prop-row .v{color:#e6edf3;font-variant-numeric:tabular-nums;text-align:right}
    \\.prop-fp{display:block;width:100%;text-align:left;background:none;border:0;border-bottom:1px solid #21262d;
    \\  padding:8px 12px;cursor:pointer;font-family:inherit;font-size:11px;color:#6e7681}
    \\.prop-fp:hover{color:#58a6ff;text-decoration:underline}
    \\.prop-sec{font-size:10.5px;text-transform:uppercase;letter-spacing:.05em;color:#6e7681;padding:9px 12px 5px}
    \\.prop-pins{display:flex;flex-wrap:wrap;gap:4px 5px;padding:0 12px 11px}
    \\.prop-sch{display:block;padding:10px 12px;font-size:12px;color:#58a6ff;border-top:1px solid #21262d}
    \\.prop-sch:hover{text-decoration:underline}
    \\.pn{font-size:11px;color:#c9d1d9;background:#21262d;border-radius:3px;padding:0 5px;white-space:nowrap}
    \\.pn b{color:#e6edf3;font-weight:600;margin-right:3px}
    \\.part.focus-flash .court{stroke:#f0b72f!important;stroke-width:2.6!important;animation:partflash .55s ease-in-out 4}
    \\@keyframes partflash{50%{stroke-opacity:0.25}}
    \\/* Parts the placement spec didn't list (auto-staged): flag them red, and
    \\   the gU overlay draws a dashed red box around the whole staged cluster. */
    \\.part.unplaced .court{stroke:#f85149!important;stroke-dasharray:4 3!important;fill:rgba(248,81,73,.12)!important}
    \\.part.unplaced .pcb-ref{fill:#f85149!important}
    \\.unplaced-box{fill:rgba(248,81,73,.05);stroke:#f85149;stroke-width:1.4;stroke-dasharray:7 5}
    \\.unplaced-lbl{fill:#f85149;font:700 11px system-ui,sans-serif}
    \\.kbd-overlay{position:fixed;inset:0;background:rgba(1,4,9,0.72);z-index:340;display:flex;align-items:center;justify-content:center}
    \\.kbd-box{background:#161b22;border:1px solid #30363d;border-radius:10px;min-width:320px;max-width:480px;
    \\  padding:18px 22px;box-shadow:0 16px 48px rgba(0,0,0,0.7)}
    \\.kbd-box h3{margin:0 0 12px;font-size:15px;color:#f0f6fc}
    \\.kbd-row{display:flex;justify-content:space-between;gap:18px;padding:4px 0;font-size:13px;color:#c9d1d9}
    \\.kbd-row kbd{background:#21262d;border:1px solid #30363d;border-bottom-width:2px;border-radius:4px;
    \\  padding:1px 7px;font-family:ui-monospace,monospace;font-size:11.5px;color:#79c0ff;white-space:nowrap}
    \\.kbd-hint{margin-top:12px;font-size:11.5px;color:#6e7681}
    \\.court-modal{position:fixed;inset:0;background:rgba(1,4,9,0.7);display:flex;
    \\  align-items:center;justify-content:center;z-index:200}
    \\.court-modal[hidden]{display:none}
    \\.court-dialog{background:#161b22;border:1px solid #30363d;color:#c9d1d9;border-radius:10px;padding:16px 18px;width:320px;
    \\  box-shadow:0 12px 40px rgba(0,0,0,0.5);font-family:system-ui,sans-serif}
    \\.court-h{display:flex;align-items:center;justify-content:space-between;font-weight:600;
    \\  color:#f0f6fc;font-size:14px;margin-bottom:8px}
    \\.court-x{border:0;background:none;font-size:20px;line-height:1;cursor:pointer;color:#8b949e}
    \\.court-svg{width:100%;height:240px;background:#010409;border-radius:6px;display:block;touch-action:none}
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
    \\body.mode-3d .pcb-svg,body.mode-3d .pcb-tune,body.mode-3d .pcb-route,body.mode-3d .pcb-tabs,
    \\body.mode-3d .pcb-panel,body.mode-3d .heat-legend,body.mode-3d .net-legend,
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
    \\/* Touch: the board owns its gestures (one finger pans, two pinch-zoom —
    \\   see BOARD_JS) — without this the browser scrolls/zooms the page instead
    \\   and every touch drag dies as a pointercancel. */
    \\.pcb-svg{touch-action:none}
    \\/* Phone / narrow-tablet layout: the three columns (board · saved layouts ·
    \\   findings sidebar) stack vertically — board first, panels below — and the
    \\   sidebars lose their sticky/viewport-height framing. Buttons and chips get
    \\   finger-sized padding. */
    \\@media (max-width:920px){
    \\  .pcb-layout{flex-direction:column;gap:12px;padding:8px 10px}
    \\  /* Stack order: board first, then the part-properties panel (it fills on
    \\     tap), then the saved-layouts history — regardless of DOM order (the
    \\     properties aside precedes the board for the desktop left column). */
    \\  .pcb-main{width:100%;order:1}
    \\  .pcb-side{order:2}
    \\  .pcb-rside{order:3}
    \\  .pcb-rside,.pcb-side{width:100%;position:static;max-height:none}
    \\  .pcb-bar .btn,.pcb-panel .btn,.pcb-tabs .tab-chip,.pcb-tabs .view-chip{padding:6px 12px}
    \\  .pcb-bar{gap:8px}
    \\  .pcb-bar .score{min-width:0}
    \\  .pcb-head h1{font-size:16px}
    \\  .pcb-live{top:56px;width:calc(100vw - 20px)}
    \\}
;

/// Extra rules layered on top of PAGE_CSS only when `?embed=1` — the body gets
/// the `embed` class. Strips outer padding, lets the board fill the frame
/// width, and drops the grab cursor (no dragging in the read-only preview).
const EMBED_CSS =
    \\body.embed .pcb-layout{padding:8px 10px;max-width:none}
    \\body.embed .pcb-bar{margin:4px 0}
    \\body.embed .pcb-route{margin:2px 0 6px}
    \\body.embed .pcb-svg{width:100%}
    \\body.embed:not(.embed-edit) .part{cursor:default}
    \\body.embed-edit .part{cursor:grab}
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

// ── Tests ──────────────────────────────────────────────────────────────

// spec: Web Server - The layouts sidecar round-trips snapshots and the optimizer cache slot through one file
test "layouts sidecar round-trips cache slot" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const parts = [_]PartPose{.{ .ref = "U1", .x = 1.5, .y = -2.0, .rot = 90 }};
    const layouts = [_]SavedLayout{.{
        .name = "best",
        .kind = KIND_MANUAL,
        .ts = 123,
        .score = .{ .hpwl = 10, .loop = 2, .caps = 1, .objective = 42 },
        .parts = &parts,
        .default = true,
    }};
    var params = optimizer.Params{};
    params.loop_w = 7;
    const cache = CacheSlot{ .params = params, .parts = &parts };

    var aw: std.Io.Writer.Allocating = .init(alloc);
    try writeLayoutsFileJson(&aw.writer, &layouts, cache);
    const text = aw.written();

    const got = parseLayouts(alloc, text) orelse return error.TestParseFailed;
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqualStrings("best", got[0].name);
    try std.testing.expect(got[0].default);
    try std.testing.expectEqual(@as(usize, 1), got[0].parts.len);

    const root = try std.json.parseFromSliceLeaky(std.json.Value, alloc, text, .{});
    const slot = parseCacheSlot(alloc, root.object.get("cache").?) orelse return error.TestParseFailed;
    try std.testing.expectEqual(@as(f64, 7), slot.params.loop_w);
    try std.testing.expectEqual(@as(usize, 1), slot.parts.?.len);
    try std.testing.expectEqualStrings("U1", slot.parts.?[0].ref);
}

// spec: Web Server - A rough-seeded saved layout round-trips its rough flag through the sidecar
test "layouts sidecar round-trips rough flag" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const parts = [_]PartPose{.{ .ref = "U1", .x = 0, .y = 0, .rot = 0 }};
    const layouts = [_]SavedLayout{
        .{ .name = "rough seed", .kind = KIND_AUTO, .ts = 1, .score = null, .parts = &parts, .rough = true },
        .{ .name = "hand", .kind = KIND_MANUAL, .ts = 2, .score = null, .parts = &parts },
    };

    var aw: std.Io.Writer.Allocating = .init(alloc);
    try writeLayoutsFileJson(&aw.writer, &layouts, null);

    const got = parseLayouts(alloc, aw.written()) orelse return error.TestParseFailed;
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expect(got[0].rough);
    try std.testing.expect(!got[1].rough);
}

// spec: Web Server - The /pcb-layout page defaults to the design's starred (★) saved layout, below an explicit ?refine= snapshot and a (placement …) spec
test "scorebar source classifies the starred default layout" {
    const poses = [_]optimizer.RefPose{.{ .ref = "U1", .x = 0, .y = 0, .rot = 0 }};
    const cached: ?[]const optimizer.RefPose = &poses;
    // Nothing more specific asked for + a starred layout loaded → starred default.
    try std.testing.expectEqual(LayoutSource.starred, classifyLayoutSource(null, false, false, null, "best", cached));
    // An explicit ?refine= snapshot still outranks the starred default.
    try std.testing.expectEqual(LayoutSource.snapshot, classifyLayoutSource(null, false, false, "hand", "best", cached));
    // A driving (placement …) spec outranks the starred default.
    try std.testing.expectEqual(LayoutSource.spec, classifyLayoutSource(null, false, true, null, "best", cached));
    // No starred layout, just the auto cache → cache.
    try std.testing.expectEqual(LayoutSource.cache, classifyLayoutSource(null, false, false, null, null, cached));
}

// spec: Web Server - A saved layout round-trips each part's renumber-stable origin key through the sidecar
test "layouts sidecar round-trips part origin" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // One part with an origin key, one legacy part without (empty origin).
    const parts = [_]PartPose{
        .{ .ref = "C1", .x = 1, .y = 2, .rot = 90, .origin = "C_VDDIN_BULK" },
        .{ .ref = "U1", .x = 0, .y = 0, .rot = 0 },
    };
    const layouts = [_]SavedLayout{.{ .name = "hand", .kind = KIND_MANUAL, .ts = 1, .score = null, .parts = &parts }};

    var aw: std.Io.Writer.Allocating = .init(alloc);
    try writeLayoutsFileJson(&aw.writer, &layouts, null);
    const text = aw.written();
    // The empty origin is omitted from the JSON; the populated one is present.
    try std.testing.expect(std.mem.indexOf(u8, text, "\"origin\":\"C_VDDIN_BULK\"") != null);

    const got = parseLayouts(alloc, text) orelse return error.TestParseFailed;
    try std.testing.expectEqual(@as(usize, 2), got[0].parts.len);
    try std.testing.expectEqualStrings("C_VDDIN_BULK", got[0].parts[0].origin);
    try std.testing.expectEqualStrings("", got[0].parts[1].origin);
}

// spec: Web Server - A saved layout round-trips its user-drawn board outline through the sidecar
test "layouts sidecar round-trips a drawn outline" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const parts = [_]PartPose{.{ .ref = "U1", .x = 0, .y = 0, .rot = 0 }};
    const layouts = [_]SavedLayout{.{
        .name = "outlined",
        .kind = KIND_MANUAL,
        .ts = 1,
        .score = null,
        .parts = &parts,
        .outline = .{ .x = -5, .y = -2.5, .w = 50, .h = 40 },
    }};
    var aw: std.Io.Writer.Allocating = .init(alloc);
    try writeLayoutsFileJson(&aw.writer, &layouts, null);
    const got = parseLayouts(alloc, aw.written()) orelse return error.TestParseFailed;
    const o = got[0].outline orelse return error.TestParseFailed;
    try std.testing.expectEqual(@as(f64, -5), o.x);
    try std.testing.expectEqual(@as(f64, 50), o.w);
    try std.testing.expectEqual(@as(f64, 40), o.h);
    try std.testing.expect(o.pts == null);
    // A degenerate outline (zero size) never round-trips into existence.
    try std.testing.expect(parseSavedOutline(alloc, null) == null);
}

// spec: Web Server - A saved layout round-trips a polygon board outline; the rect fields are re-derived as its bbox
test "layouts sidecar round-trips a polygon outline" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // L-shaped outline; the stored rect fields deliberately LIE (0,0,1,1) —
    // the parser must re-derive them from the polygon bbox.
    const l_pts = [_][2]f64{ .{ -5, 0 }, .{ 45, 0 }, .{ 45, 20 }, .{ 20, 20 }, .{ 20, 40 }, .{ -5, 40 } };
    const parts = [_]PartPose{.{ .ref = "U1", .x = 0, .y = 0, .rot = 0 }};
    const layouts = [_]SavedLayout{.{
        .name = "poly-outlined",
        .kind = KIND_MANUAL,
        .ts = 1,
        .score = null,
        .parts = &parts,
        .outline = .{ .x = 0, .y = 0, .w = 1, .h = 1, .pts = &l_pts },
    }};
    var aw: std.Io.Writer.Allocating = .init(alloc);
    try writeLayoutsFileJson(&aw.writer, &layouts, null);
    const got = parseLayouts(alloc, aw.written()) orelse return error.TestParseFailed;
    const o = got[0].outline orelse return error.TestParseFailed;
    const pts = o.pts orelse return error.TestParseFailed;
    try std.testing.expectEqual(@as(usize, 6), pts.len);
    try std.testing.expectEqual(@as(f64, 20), pts[3][0]);
    try std.testing.expectEqual(@as(f64, 20), pts[3][1]);
    // Rect fields = polygon bbox, not the stored lie.
    try std.testing.expectEqual(@as(f64, -5), o.x);
    try std.testing.expectEqual(@as(f64, 0), o.y);
    try std.testing.expectEqual(@as(f64, 50), o.w);
    try std.testing.expectEqual(@as(f64, 40), o.h);
    // A malformed vertex list (pair with one number) rejects the polygon but
    // keeps the rect, so a corrupt sidecar can never reshape the board.
    const bad = parseLayouts(alloc,
        \\{"layouts":[{"name":"b","kind":"manual","ts":1,
        \\ "outline":{"x":1,"y":2,"w":30,"h":20,"pts":[[0],[1,1],[2,2]]},
        \\ "parts":[{"ref":"U1","x":0,"y":0,"rot":0}]}]}
    ) orelse return error.TestParseFailed;
    const bo = bad[0].outline orelse return error.TestParseFailed;
    try std.testing.expect(bo.pts == null);
    try std.testing.expectEqual(@as(f64, 30), bo.w);
}

// spec: Web Server - A saved layout round-trips its routed copper (tracks + vias, net-name keyed) through the sidecar
test "layouts sidecar round-trips saved routes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const parts = [_]PartPose{.{ .ref = "U1", .x = 0, .y = 0, .rot = 0 }};
    const tracks = [_]SavedTrack{.{ .x1 = 0, .y1 = 0, .x2 = 3, .y2 = 0, .l = 1, .w = 0.3, .net = "VBUS" }};
    const vias = [_]SavedVia{.{ .x = 1, .y = 0, .d = 0.6, .drill = 0.3, .net = "VBUS" }};
    const layouts = [_]SavedLayout{.{
        .name = "routed",
        .kind = KIND_MANUAL,
        .ts = 1,
        .score = null,
        .parts = &parts,
        .routes = .{ .tracks = &tracks, .vias = &vias },
    }};

    var aw: std.Io.Writer.Allocating = .init(alloc);
    try writeLayoutsFileJson(&aw.writer, &layouts, null);
    const got = parseLayouts(alloc, aw.written()) orelse return error.TestParseFailed;
    const sr = got[0].routes orelse return error.TestParseFailed;
    try std.testing.expectEqual(@as(usize, 1), sr.tracks.len);
    try std.testing.expectEqual(@as(u8, 1), sr.tracks[0].l);
    try std.testing.expectEqual(@as(f64, 0.3), sr.tracks[0].w);
    try std.testing.expectEqualStrings("VBUS", sr.tracks[0].net);
    try std.testing.expectEqual(@as(usize, 1), sr.vias.len);
    try std.testing.expectEqual(@as(f64, 0.3), sr.vias[0].drill);

    // Restore against a netlist where VBUS is index 1 → indices re-resolve.
    const pins = [_]export_kicad.FlatPin{.{ .ref_des = "U1", .pin = "1" }};
    const nets = [_]export_kicad.FlatNet{ .{ .name = "GND", .pins = &pins }, .{ .name = "VBUS", .pins = &pins } };
    const restored = restoreRoutes(alloc, sr, &nets) orelse return error.TestParseFailed;
    try std.testing.expectEqual(@as(i32, 1), restored.tracks[0].net);
    try std.testing.expectEqual(@as(i32, 1), restored.vias[0].net);
}

// spec: Web Server - Stamped module copper keeps its group tag through the sidecar so rigid-group moves carry it
test "layouts sidecar round-trips the copper stamp group tag" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const parts = [_]PartPose{.{ .ref = "buck/U1", .x = 0, .y = 0, .rot = 0 }};
    const tracks = [_]SavedTrack{
        .{ .x1 = 0, .y1 = 0, .x2 = 3, .y2 = 0, .w = 0.3, .net = "VOUT", .g = "buck" },
        .{ .x1 = 3, .y1 = 0, .x2 = 5, .y2 = 0, .w = 0.3, .net = "VOUT" },
    };
    const vias = [_]SavedVia{.{ .x = 1, .y = 0, .d = 0.6, .drill = 0.3, .net = "GND", .g = "buck" }};
    const layouts = [_]SavedLayout{.{
        .name = "routed",
        .kind = KIND_MANUAL,
        .ts = 1,
        .score = null,
        .parts = &parts,
        .routes = .{ .tracks = &tracks, .vias = &vias },
    }};

    var aw: std.Io.Writer.Allocating = .init(alloc);
    try writeLayoutsFileJson(&aw.writer, &layouts, null);
    const got = parseLayouts(alloc, aw.written()) orelse return error.TestParseFailed;
    const sr = got[0].routes orelse return error.TestParseFailed;
    try std.testing.expectEqualStrings("buck", sr.tracks[0].g);
    try std.testing.expectEqualStrings("", sr.tracks[1].g);
    try std.testing.expectEqualStrings("buck", sr.vias[0].g);
}

// spec: Web Server - Stamped module copper maps its net names onto the parent design via the origin-key bridge, slug-prefixing private nets
test "stamped copper nets map to parent nets with slug fallback" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // Module side: pin (origin U1, pad 2) sits on module net "VOUT".
    const pin_nets = [_]SubPinNet{.{ .net = "VOUT", .origin_key = "U1", .pad = "2" }};
    // Bridge: module origin "U1" is design part "buck/U11".
    var ok_ref = std.StringHashMap([]const u8).init(alloc);
    try ok_ref.put("U1", "buck/U11");
    // Parent side: design pad buck/U11.2 is on parent net "5V0".
    var dpin = std.StringHashMap([]const u8).init(alloc);
    try dpin.put(try std.fmt.allocPrint(alloc, PIN_KEY_FMT, .{ "buck/U11", "2" }), "5V0");

    const tracks = [_]SavedTrack{
        .{ .x1 = 0, .y1 = 0, .x2 = 3, .y2 = 0, .w = 0.3, .net = "VOUT" },
        .{ .x1 = 0, .y1 = 1, .x2 = 3, .y2 = 1, .w = 0.2, .net = "FB" },
    };
    const sr = SavedRoutes{ .tracks = &tracks, .vias = &.{} };

    var aw: std.Io.Writer.Allocating = .init(alloc);
    try writeSubRoutesJson(&aw.writer, alloc, "buck", sr, &pin_nets, &ok_ref, &dpin);
    const out = aw.written();
    // Bridged net → the parent's name; unbridged private net → slug-prefixed.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"net\":\"5V0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"net\":\"buck/FB\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"net\":\"VOUT\"") == null);
}

// spec: Web Server - A saved layout round-trips each part's board side and lock flag through the sidecar
test "layouts sidecar round-trips side and locked" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // One bottom-side locked part; one default (top, unlocked) part.
    const parts = [_]PartPose{
        .{ .ref = "U1", .x = 1, .y = 2, .rot = 0, .side = .bottom, .locked = true },
        .{ .ref = "C1", .x = 3, .y = 4, .rot = 90 },
    };
    const layouts = [_]SavedLayout{.{ .name = "two-sided", .kind = KIND_MANUAL, .ts = 1, .score = null, .parts = &parts }};

    var aw: std.Io.Writer.Allocating = .init(alloc);
    try writeLayoutsFileJson(&aw.writer, &layouts, null);
    const text = aw.written();
    // Non-default fields are spelled out; the default part stays legacy-shaped.
    try std.testing.expect(std.mem.indexOf(u8, text, "\"side\":\"bottom\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"locked\":true") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "\"side\""));

    const got = parseLayouts(alloc, text) orelse return error.TestParseFailed;
    try std.testing.expectEqual(optimizer.Side.bottom, got[0].parts[0].side);
    try std.testing.expect(got[0].parts[0].locked);
    try std.testing.expectEqual(optimizer.Side.top, got[0].parts[1].side);
    try std.testing.expect(!got[0].parts[1].locked);
}
