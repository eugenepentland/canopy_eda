//! Embedded browser assets and their content-hashed HTTP registry.
//! Contract tests here verify critical browser capabilities remain bundled.

const std = @import("std");
const httpz = @import("httpz");

const serve_root = @import("../serve.zig");
const Server = serve_root.Server;

const pdf_viewer_js = @embedFile("assets/pdf_viewer.js");
const pdf_viewer_css = @embedFile("assets/pdf_viewer.css");
const library_js = @embedFile("assets/library.js");
// Shared footprint-drawing engine — one renderer for the library preview, the
// schematic sidebar, and the PCB-layout page (draws from /api/footprint JSON).
const footprint_svg_js = @embedFile("assets/footprint_svg.js");
const footprint_editor_js = @embedFile("assets/footprint_editor.js");
const footprint_editor_css = @embedFile("assets/footprint_editor.css");
const pcb_board_js = @embedFile("assets/pcb_board.js");
// Dependency-free parametric shape model + constraint solver. Loaded before
// editors so board, copper, fabrication, and footprint shapes share one kernel.
const shape_sketch_js = @embedFile("assets/shape_sketch.js");
// Client-side ASCII DXF board-outline importer (the ⤒ DXF button next to the
// ▭ Outline / ⬡ Poly tools). Script-tagged AFTER pcb_board.js — it leans on
// the board script's globals (PCB, snapAll, outlineBboxSync, …) and wires
// the pcb-outline-dxf button the page renders in the toolstrip / action bar.
const pcb_dxf_js = @embedFile("assets/pcb_dxf.js");
const pcb_find_header_html = @embedFile("assets/pcb_find_header.html");
const pcb_find_pane_html = @embedFile("assets/pcb_find_pane.html");
const pcb_kicad_import_js = @embedFile("assets/pcb_kicad_import.js");
// Route-replay panel client for the /pcb-layout page — drives the Replay dock
// against the design-route-review endpoints (POST poses / GET solve / cached).
const pcb_replay_js = @embedFile("assets/pcb_replay.js");
// Interactive routing-session client — the sibling of pcb_replay.js in the same
// #panel-replay dock. Drives /api/route-session/* (start/state/hint/distill),
// paints the stuck-net search frontier, and reuses pcb_replay.js's shared
// surface (window.PCBReplayShared), so it must load AFTER pcb_replay.js.
const pcb_route_session_js = @embedFile("assets/pcb_route_session.js");
const pcb_settings_js = @embedFile("assets/pcb_settings.js");
const pcb_settings_css = @embedFile("assets/pcb_settings.css");
// Stuck-nets panel client — renders the `stuck[]` diagnostics POST /api/pcb-route
// returns (why each unroutable net failed + ranked dsl/code remedies) into the
// #panel-stuck sidebar dock. Pure consumer of the Route button's response; never
// routes on its own (a full board is minutes of work).
const pcb_stuck_js = @embedFile("assets/pcb_stuck.js");
// WebGPU board renderer — copper, vias and pads as instanced signed-distance
// quads on a canvas UNDER the 2D scene, camera = one uniform. Default-on when
// available; ?gpu=0, no adapter, or a lost device leaves the Canvas2D fallback
// in charge. Script-tagged BEFORE pcb_board.js so window.PCBGpu exists when the
// board script boots.
const pcb_gpu_js = @embedFile("assets/pcb_gpu.js");
const route_review_js = @embedFile("assets/route_review.js");
const review_notes_js = @embedFile("assets/review_notes.js");
const assembly_debug_js = @embedFile("assets/assembly_debug.js");
const assembly_debug_css = @embedFile("assets/assembly_debug.css");
// Thermal review page (/thermal/:name) — scenario switching, the ambient
// re-screen fetch and the cross-probe send. Server-rendered page, so the
// client owns no formatting.
const thermal_page_js = @embedFile("assets/thermal_page.js");
const thermal_page_css = @embedFile("assets/thermal_page.css");
// The heat-field overlay the thermal page's board pane loads INSIDE the
// read-only PCB iframe (`?embed=1&review=1&thermal=1`). It claims the
// pcb_board.js overlay seam; the field itself comes from /api/thermal-field.
const pcb_thermal_js = @embedFile("assets/pcb_thermal.js");
// The PCB page stylesheet, read here as the theme's cross-check: every
// `var(--pcb-…)` it names must be a property board_theme.writeCssVars emits.
const pcb_layout_css = @embedFile("assets/pcb_layout.css");

// Vendored CodeMirror 5 (MIT) — core + scheme mode + matchbrackets/
// closebrackets addons concatenated into one bundle. Backs the full-file
// `.sexp` source editor on the schematic page. Self-hosted so the editor
// works offline and behind the OAuth wall.
const codemirror_js = @embedFile("assets/codemirror.bundle.js");
const codemirror_css = @embedFile("assets/codemirror.css");

// 3D model alignment viewer (/library/3d/:footprint). Self-hosted Three.js
// r128 (MIT) + its OrbitControls, OpenCASCADE's occt-import-js (Apache-2.0:
// .js loader + .wasm kernel) for parsing STEP in-browser, and our viewer glue.
// All offline/embedded like CodeMirror so the viewer works behind the OAuth wall.
const three_js = @embedFile("assets/three.min.js");
const orbit_controls_js = @embedFile("assets/OrbitControls.js");
const occt_import_js = @embedFile("assets/occt-import-js.js");
const occt_import_wasm = @embedFile("assets/occt-import-js.wasm");
const model_viewer_3d_js = @embedFile("assets/model_viewer_3d.js");
// 3D PCB-layout viewer (the "3D View" tab on /pcb-layout/:name). Reuses the
// same Three.js + occt-import-js stack as the footprint viewer; lazy-loaded
// only when the tab is first opened.
const pcb_3d_surface_js = @embedFile("assets/pcb_3d_surface.js");
const pcb_3d_viewer_js = @embedFile("assets/pcb_3d_viewer.js");
// Assembly/debug's persistent transparent model-image loader. It reads saved
// PNGs first and invokes the STEP renderer only to populate a missing/stale
// filesystem entry; there is no persistent WebGL scene or render loop.
const pcb_model_sprites_js = @embedFile("assets/pcb_model_sprites.js");

// Client-side WASM design-rule check — the same placement/drc.zig engine
// compiled to wasm32-freestanding (see build.zig's `wasm-drc` step, embedded
// via the `drc.wasm` anonymous import on the exe module). The /pcb-layout page
// fetches this to run the DRC locally instead of round-tripping to the server.
const drc_wasm = @embedFile("drc.wasm");
// Wave-2 client DRC glue: `drc_marshal.js` builds the wasm input JSON from the
// page blob + live editor state (a plain `buildDrcInput`, also require()-able
// under Node for the parity harness); `drc_worker.js` is the Web Worker that
// loads drc.wasm and runs its two-call ABI off the main thread.
const drc_marshal_js = @embedFile("assets/drc_marshal.js");
const drc_worker_js = @embedFile("assets/drc_worker.js");

// Schematic page assets — pub-imported from render_html so we don't
// re-`@embedFile` the underlying byte slices (the JS lives under
// `serve/assets/` already, but the CSS is the concatenation of
// `assets/schematic_inline.css` and the diagram engine's `DIAGRAM_CSS`).
const board_theme = @import("../board_theme.zig");
const render_html = @import("../render_html.zig");
const schematic_viewer_js = render_html.schematic_viewer_js_asset;
const schematic_css = render_html.schematic_css;

/// Error set for the static-asset handler: only writer-side errors propagate
/// to httpz; the lookup itself is fallible only via a 404.
pub const HandlerError = std.mem.Allocator.Error || std.Io.Writer.Error;

const Asset = struct {
    name: []const u8,
    body: []const u8,
    content_type: httpz.ContentType,
};

/// Registry of `@embedFile`-backed assets that page templates link to via
/// `<script src="/static/...">` / `<link href="/static/...">`. Adding a new
/// asset is a one-line entry here plus the `@embedFile` import above —
/// `staticAsset` does the lookup.
const registry = [_]Asset{
    .{ .name = "pdf_viewer.js", .body = pdf_viewer_js, .content_type = .JS },
    .{ .name = "pdf_viewer.css", .body = pdf_viewer_css, .content_type = .CSS },
    .{ .name = "library.js", .body = library_js, .content_type = .JS },
    .{ .name = "footprint_svg.js", .body = footprint_svg_js, .content_type = .JS },
    .{ .name = "footprint_editor.js", .body = footprint_editor_js, .content_type = .JS },
    .{ .name = "footprint_editor.css", .body = footprint_editor_css, .content_type = .CSS },
    .{ .name = "pcb_board.js", .body = pcb_board_js, .content_type = .JS },
    .{ .name = "shape_sketch.js", .body = shape_sketch_js, .content_type = .JS },
    // Compatibility for old cached page markup and third-party integrations.
    .{ .name = "pcb_outline_sketch.js", .body = shape_sketch_js, .content_type = .JS },
    .{ .name = "pcb_dxf.js", .body = pcb_dxf_js, .content_type = .JS },
    .{ .name = "pcb_kicad_import.js", .body = pcb_kicad_import_js, .content_type = .JS },
    .{ .name = "pcb_replay.js", .body = pcb_replay_js, .content_type = .JS },
    .{ .name = "pcb_route_session.js", .body = pcb_route_session_js, .content_type = .JS },
    .{ .name = "pcb_settings.js", .body = pcb_settings_js, .content_type = .JS },
    .{ .name = "pcb_settings.css", .body = pcb_settings_css, .content_type = .CSS },
    .{ .name = "pcb_stuck.js", .body = pcb_stuck_js, .content_type = .JS },
    .{ .name = "pcb_gpu.js", .body = pcb_gpu_js, .content_type = .JS },
    .{ .name = "route_review.js", .body = route_review_js, .content_type = .JS },
    .{ .name = "review_notes.js", .body = review_notes_js, .content_type = .JS },
    .{ .name = "assembly_debug.js", .body = assembly_debug_js, .content_type = .JS },
    .{ .name = "assembly_debug.css", .body = assembly_debug_css, .content_type = .CSS },
    .{ .name = "thermal_page.js", .body = thermal_page_js, .content_type = .JS },
    .{ .name = "thermal_page.css", .body = thermal_page_css, .content_type = .CSS },
    .{ .name = "pcb_thermal.js", .body = pcb_thermal_js, .content_type = .JS },
    .{ .name = "schematic_viewer.js", .body = schematic_viewer_js, .content_type = .JS },
    .{ .name = "schematic.css", .body = schematic_css, .content_type = .CSS },
    .{ .name = "codemirror.bundle.js", .body = codemirror_js, .content_type = .JS },
    .{ .name = "codemirror.css", .body = codemirror_css, .content_type = .CSS },
    .{ .name = "three.min.js", .body = three_js, .content_type = .JS },
    .{ .name = "OrbitControls.js", .body = orbit_controls_js, .content_type = .JS },
    .{ .name = "occt-import-js.js", .body = occt_import_js, .content_type = .JS },
    .{ .name = "occt-import-js.wasm", .body = occt_import_wasm, .content_type = .WASM },
    .{ .name = "model_viewer_3d.js", .body = model_viewer_3d_js, .content_type = .JS },
    .{ .name = "pcb_3d_surface.js", .body = pcb_3d_surface_js, .content_type = .JS },
    .{ .name = "pcb_3d_viewer.js", .body = pcb_3d_viewer_js, .content_type = .JS },
    .{ .name = "pcb_model_sprites.js", .body = pcb_model_sprites_js, .content_type = .JS },
    .{ .name = "drc.wasm", .body = drc_wasm, .content_type = .WASM },
    .{ .name = "drc_marshal.js", .body = drc_marshal_js, .content_type = .JS },
    .{ .name = "drc_worker.js", .body = drc_worker_js, .content_type = .JS },
};

/// GET /static/:name — serve an embedded JS/CSS asset. 404 if the name is
/// unknown, so pages can't accidentally pull an asset that isn't registered.
/// Lazily-computed per-asset content hashes (the ETag values). 0 = not yet
/// computed; the benign race (two request threads hashing the same immutable
/// embedded bytes) stores the identical value, so no lock is needed.
var etag_cache: [registry.len]u64 = @splat(0);

fn assetEtag(idx: usize) u64 {
    const v = @atomicLoad(u64, &etag_cache[idx], .monotonic);
    if (v != 0) return v;
    const h = std.hash.Wyhash.hash(0, registry[idx].body);
    const nz: u64 = if (h == 0) 1 else h; // 0 is the "uncomputed" sentinel
    @atomicStore(u64, &etag_cache[idx], nz, .monotonic);
    return nz;
}

/// GET /static/:name — serve an embedded asset with a content-hash ETag and
/// `no-cache` (always revalidate, 304 when unchanged), so deploys can never
/// leave a browser running a stale script against fresh HTML.
pub fn staticAsset(_: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = 404;
        res.body = "asset not found";
        return;
    };
    for (registry, 0..) |a, i| {
        if (std.mem.eql(u8, a.name, name)) {
            // Content-hash ETag + always-revalidate: after a deploy the
            // browser's conditional GET misses the old tag and refetches, so
            // clients can never run a stale script against new HTML (the
            // "button exists but does nothing" failure). Unchanged assets
            // stay cheap — the revalidation answers 304 with no body.
            const tag = std.fmt.allocPrint(req.arena, "\"{x}\"", .{assetEtag(i)}) catch {
                res.content_type = a.content_type;
                res.body = a.body;
                return;
            };
            res.header("etag", tag);
            res.header("cache-control", "no-cache");
            if (req.header("if-none-match")) |inm| {
                if (std.mem.indexOf(u8, inm, tag[1 .. tag.len - 1]) != null) {
                    res.status = 304;
                    return;
                }
            }
            res.content_type = a.content_type;
            res.body = a.body;
            return;
        }
    }
    res.status = 404;
    res.body = "asset not found";
}

// spec: Web Server - The PCB editor imports a DXF board outline: the importer honours $INSUNITS, flips Y to the board frame, preserves native arcs in the editable sketch, and feeds the existing outline-override seam (Save/Update persists it like any drawn outline)
// spec: Web Server - The PCB editor's DXF import assembles a line/arc contour into a closed outline even when the export left sub-µm endpoint seams, mixed winding, or a duplicated contour
test "the DXF board-outline importer asset is registered with its parser seam" {
    // The page template references the asset by name, so it must be served.
    try std.testing.expect(registryHasAsset("pcb_dxf.js"));
    // The parser seam and the editor hooks the page relies on.
    const checks = [_]struct { bytes: []const u8, marker: []const u8 }{
        // The parser seam and the editor hooks the page relies on.
        .{ .bytes = pcb_dxf_js, .marker = "window.PCBDxfParse" },
        .{ .bytes = pcb_dxf_js, .marker = "$INSUNITS" },
        .{ .bytes = pcb_dxf_js, .marker = "LWPOLYLINE" },
        .{ .bytes = pcb_dxf_js, .marker = "function dxfDialog(parsed, fileName)" },
        .{ .bytes = pcb_dxf_js, .marker = "pcb-outline-dxf" },
        .{ .bytes = pcb_dxf_js, .marker = "window.PCBDxfSeams.selfIntersects(pts)" },
        .{ .bytes = pcb_dxf_js, .marker = "seams.outlineBboxSync()" },
        .{ .bytes = pcb_dxf_js, .marker = "seams.recordUndo(pre)" },
        .{ .bytes = pcb_dxf_js, .marker = "seams.markDirty()" },
        .{ .bytes = pcb_dxf_js, .marker = "seams.drawBoardRect()" },
        .{ .bytes = pcb_dxf_js, .marker = "seams.scheduleDrc()" },
        .{ .bytes = pcb_dxf_js, .marker = "if (RO) return;" },
        // Contour assembly tolerates real-world messy outlines: near-
        // coincident endpoints snap into shared vertices, the segment walk is
        // winding-independent, and duplicate contours are not retraced.
        .{ .bytes = pcb_dxf_js, .marker = "MERGE_TOL" },
        .{ .bytes = pcb_dxf_js, .marker = "if (other === prev) continue; // backtracking" },
        .{ .bytes = pcb_dxf_js, .marker = "a winding mismatch cannot strand the walk" },
        .{ .bytes = pcb_dxf_js, .marker = "function bulgeArcSegment(" },
        .{ .bytes = pcb_dxf_js, .marker = "window.PCBOutlineSketch.fromSegments(exact)" },
        // The board script exports the apply-path seam the importer calls (it
        // is an IIFE, so without the export nothing outside it can apply an
        // outline — the failure this seam exists to prevent).
        .{ .bytes = pcb_board_js, .marker = "window.PCBDxfSeams={" },
        .{ .bytes = pcb_board_js, .marker = "selfIntersects: polySelfIntersects" },
        .{ .bytes = pcb_board_js, .marker = "disarmTools: function(){" },
    };
    for (checks) |c| try std.testing.expect(std.mem.indexOf(u8, c.bytes, c.marker) != null);
}

// spec: Web Server - The PCB board-outline sketch keeps stable entities, constraints, driving dimensions, and exact arcs in a separately testable client model loaded before the editor
// spec: Web Server - The neutral shape-sketch kernel is shared by board outlines, custom copper pours and keepouts, fabrication backing regions, custom footprint pads, footprint courtyards, and closed silk/fab artwork; board cutouts and slots remain outside this single-contour engine
// spec: Web Server - Custom copper keepouts use the same copper-area picker and the same full shape-sketch palette as pours; generated rule/perimeter keepouts remain derived and read-only
// spec: Web Server - The PCB outline sketch box-selects corner vertices in Outline mode or the Outline-only filter; Delete removes selected vertices and their incident curves without healing the resulting open profile, while Remove fillet remains a separate sharp-corner command
// spec: Web Server - The PCB outline Line tool stays inside the sketch, creates connected native line chains, snaps endpoints to shared existing point IDs and H/V inference, lets Enter retain an open chain, and normalizes a reconnected closed loop for fabrication
// spec: Web Server - Backspace or Delete on a selected native outline curve removes only that curve, leaves loose endpoints for free sketch editing, remains undoable, and Save explains that open geometry must be reconnected
// spec: Web Server - A malformed custom copper-area save names a clickable exact zone that enters its sketch and frames it; a single connected two-endpoint gap exposes an explicit undoable Close profile repair and is safely closed on save for stale sessions, while branches and disconnected geometry are never guessed closed
test "the shared parametric shape sketch engine is registered with its editor contracts" {
    try std.testing.expect(registryHasAsset("shape_sketch.js"));
    try std.testing.expect(registryHasAsset("pcb_outline_sketch.js"));
    const Check = struct { bytes: []const u8, marker: []const u8 };
    const checks = [_]Check{
        .{ .bytes = shape_sketch_js, .marker = "root.PCBOutlineSketch = api" },
        .{ .bytes = shape_sketch_js, .marker = "root.PCBShapeSketch = api" },
        .{ .bytes = shape_sketch_js, .marker = "function ensurePolygon(o)" },
        .{ .bytes = shape_sketch_js, .marker = "function solve(s,opts)" },
        .{ .bytes = shape_sketch_js, .marker = "function fromSegments(segments)" },
        .{ .bytes = shape_sketch_js, .marker = "function pointDragAxis(s,id,x,y,origin)" },
        .{ .bytes = shape_sketch_js, .marker = "function pointDragTarget(s,id,x,y,axis)" },
        .{ .bytes = shape_sketch_js, .marker = "filletPoint:filletPoint" },
        .{ .bytes = shape_sketch_js, .marker = "chamferPoint:chamferPoint" },
        .{ .bytes = shape_sketch_js, .marker = "offset:offset" },
        .{ .bytes = shape_sketch_js, .marker = "mirror:mirror" },
        .{ .bytes = shape_sketch_js, .marker = "function removeFillet(s,cid)" },
        .{ .bytes = shape_sketch_js, .marker = "function deleteSegment(s,cid)" },
        .{ .bytes = shape_sketch_js, .marker = "function addLinePath(s,coords,tol)" },
        .{ .bytes = shape_sketch_js, .marker = "function closeProfile(s)" },
        .{ .bytes = shape_sketch_js, .marker = "canCloseProfile:canCloseProfile" },
        .{ .bytes = shape_sketch_js, .marker = "closed:isClosed" },
        .{ .bytes = shape_sketch_js, .marker = "snapLinePoint:snapLinePoint" },
        .{ .bytes = pcb_board_js, .marker = "outline-sketch-palette" },
        .{ .bytes = pcb_board_js, .marker = "function outlineSketchDimension()" },
        .{ .bytes = pcb_board_js, .marker = "function outlineSketchConstraint(kind)" },
        .{ .bytes = pcb_board_js, .marker = "function outlineDeleteSelected()" },
        .{ .bytes = pcb_board_js, .marker = "function outlineRemoveFilletSelected()" },
        .{ .bytes = pcb_board_js, .marker = "OS.deleteSegment(sk,id)" },
        .{ .bytes = pcb_board_js, .marker = "function outlineDeleteKeyActive(target)" },
        .{ .bytes = pcb_board_js, .marker = "if(box.outline)" },
        .{ .bytes = pcb_board_js, .marker = "if(outlineRectArmed)outDraw=" },
        .{ .bytes = pcb_board_js, .marker = "function polySnap(m)" },
        .{ .bytes = pcb_board_js, .marker = "polyArm(!(polyMode&&polySketchOwned),true)" },
        .{ .bytes = pcb_board_js, .marker = "OS.addLinePath(sk,pts)" },
        .{ .bytes = pcb_board_js, .marker = "outline is open — reconnect its loose endpoints before saving" },
        .{ .bytes = pcb_board_js, .marker = "function showPourIssue(msg,issue,detail)" },
        .{ .bytes = pcb_board_js, .marker = "function recoverOpenPourSketches()" },
        .{ .bytes = pcb_board_js, .marker = "recoverOpenPourSketches();" },
        .{ .bytes = pcb_board_js, .marker = "data-sk=\"close-profile\"" },
        .{ .bytes = pcb_board_js, .marker = "polyCur=polySnap(mm(ev))" },
        .{ .bytes = pcb_board_js, .marker = "copper keepout" },
        .{ .bytes = pcb_board_js, .marker = "function activeSketchPromote()" },
        .{ .bytes = pcb_board_js, .marker = "OS.ensurePolygon(shape)" },
        .{ .bytes = pcb_board_js, .marker = "OS.fromPolygon(pts)" },
        .{ .bytes = pcb_board_js, .marker = "backing region sketch" },
        .{ .bytes = footprint_editor_js, .marker = "var OS = window.PCBShapeSketch" },
        .{ .bytes = footprint_editor_js, .marker = "function shapeAction(action)" },
    };
    for (checks) |check| try std.testing.expect(std.mem.indexOf(u8, check.bytes, check.marker) != null);
}

test "layout save recovers open copper sketches before rejecting geometry" {
    const recover_fn = std.mem.indexOf(u8, pcb_board_js, "function recoverOpenPourSketches()") orelse
        return error.TestUnexpectedResult;
    const save_fn = std.mem.indexOf(u8, pcb_board_js, "function persistLayoutNow(") orelse
        return error.TestUnexpectedResult;
    const recover_call = std.mem.indexOfPos(u8, pcb_board_js, save_fn, "recoverOpenPourSketches();") orelse
        return error.TestUnexpectedResult;
    const reject_call = std.mem.indexOfPos(u8, pcb_board_js, save_fn, "var pbad=pourSketchBad();") orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(recover_call < reject_call);
    try std.testing.expect(std.mem.indexOfPos(u8, pcb_board_js, recover_fn, "replacement=OS.fromPolygon(pts)") != null);
}

// spec: Web Server - While drawing a custom copper area, nearly horizontal or vertical segments snap onto that axis in both the live preview and committed polygon; holding Ctrl bypasses only this axis inference
test "custom copper area drawing infers axes unless Ctrl is held" {
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, "function pourSnap(m,ev)") != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, "axis=!(ev&&ev.ctrlKey)") != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, "qsn=pourSnap(qm,ev)") != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, "pourCur=pourSnap(mm(ev),ev)") != null);
}

// Once a new custom copper-area contour has its first vertex, clicking through
// an existing pour adds another vertex instead of selecting that pour to edit.
test "custom copper area drawing owns clicks over existing pours" {
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, "if(!pourPts){var qhit=pourAt(qm);if(qhit){pourBeginEdit(qhit);return;}}") != null);
}

// spec: Web Server - Dragging an endpoint of a horizontal or vertical outline segment changes its length without translating the constrained line, with dominant-direction disambiguation at H/V corners
test "axis-constrained outline endpoint drags project the cursor onto the segment" {
    try std.testing.expect(std.mem.indexOf(u8, shape_sketch_js, "function pointDragAxis(s,id,x,y,origin)") != null);
    try std.testing.expect(std.mem.indexOf(u8, shape_sketch_js, "if(axis===\"horizontal\")y=p.y;else if(axis===\"vertical\")x=p.x;") != null);
    try std.testing.expect(std.mem.indexOf(u8, shape_sketch_js, "var target=pointDragTarget(s,id,x,y,axis)") != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, "vdrag.axis=OS.pointDragAxis") != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, "OS.movePoint(shape.sketch,vdrag.id,vgx,vgy,vdrag.axis)") != null);
}

fn registryHasAsset(name: []const u8) bool {
    for (registry) |a| {
        if (std.mem.eql(u8, a.name, name)) return true;
    }
    return false;
}

// spec: Web Server - The PCB editor defers whole-board diagnostics until the user requests them or edits the board
test "PCB editor does not launch optional whole-board analyses during boot" {
    const checks = [_]struct { marker: []const u8, present: bool }{
        .{ .marker = "function loadStarMatch()", .present = true },
        .{ .marker = "el.addEventListener(\"click\",loadStarMatch)", .present = true },
        .{ .marker = "fetch(\"/api/layout-progress/\"", .present = true },
        .{ .marker = "progEnsureChip(); // cheap placeholder; the first click performs the analysis", .present = true },
        .{ .marker = "if(!RO)drcChip((PCB.drc||[]).length)", .present = true },
        .{ .marker = "loadLayoutScores();", .present = false },
        .{ .marker = "fetch(\"/api/pcb-describe/\"", .present = false },
        .{ .marker = "progFetch(); // initial pull on page load", .present = false },
        .{ .marker = "if(!RO)wasmDrcInit(); // warm up the DRC worker", .present = false },
    };
    for (checks) |check| try std.testing.expect((std.mem.indexOf(u8, pcb_board_js, check.marker) != null) == check.present);
}

// spec: Web Server - A plain click on the board outline's edge or a corner handle shows its properties instead of being swallowed by the outline-edit drag arming
test "PCB board editor shows the Board outline properties on a plain outline edge/vertex click" {
    // The helper clears every part/copper/inspector selection, drops the
    // net highlight and repaints the side panel in the Board outline view.
    const markers = [_][]const u8{
        "function showOutlineProps(){inspClear();selCuClear();selClear();selNet(null);",
        "selRef=null;selGroup=null;",
        "pcbSideTab(\"side-props\");renderProps();markGrpRow();markSelPart();",
        "function outlineSelect(type,index,id,ev)",
        "outlineSketchPanelSync();if(!activeSketchIsArea())showOutlineProps();drawBoardRect();",
        // Wired into both outline-gesture releases: a no-move vertex press…
        "else outlineSelect(\"point\",vd.i,vd.id,ev);",
        // …and a no-move edge press.
        "else outlineSelect(\"curve\",od.i,od.id,ev);",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, marker) != null);
}

// spec: Web Server - Selecting a board outline exposes editable dimensions, slides horizontal/vertical edges only perpendicular to themselves, and uses Shift to constrain non-axis-aligned edge slides to their dominant axis
test "PCB board editor edits dimensions and slides outline edges along their normal" {
    const markers = [_][]const u8{
        "pNumRow(\"Width (mm)\",\"prop-outline-width\",bo.w,false)",
        "pNumRow(\"Height (mm)\",\"prop-outline-height\",bo.h,false)",
        "if(!PCB.board)return null;",
        "function outlineResize(w,h)",
        "if(osdrag){osegMove(mm(ev),ev.shiftKey);return;}",
        "if(Math.abs(ey)<=axisTol)dx=0;else if(Math.abs(ex)<=axisTol)dy=0;",
        "else if(square){if(Math.abs(ex)>=Math.abs(ey))dx=0;else dy=0;}",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, marker) != null);
}

// spec: Web Server - The PCB passive inspector offers compatible footprint families from the project library
test "PCB passive inspector edits footprint families through the schematic source API" {
    const markers = [_][]const u8{
        "function passiveFpChoices(p,comps)",
        "fetch(\"/api/lib-index\")",
        "pSelRow(\"Footprint\",\"prop-footprint\"",
        "fetch(\"/api/edit-footprint/\"+encodeURIComponent(PCB.name)",
        "oldComponent:p.component",
        "sourceName:p.srcName",
        "fetch(\"/api/pcb-score/\"+encodeURIComponent(PCB.name)+subq()",
        "refresh:p.ref",
        "function passiveRefreshTopology(index,oldPads,newPads)",
        "passiveRefreshApply(p,o.edit,o.score)",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, marker) != null);
    const flow_start = std.mem.indexOf(u8, pcb_board_js, "function wirePassiveFootprint") orelse return error.PassiveFootprintFlowMissing;
    const flow_end = std.mem.indexOfPos(u8, pcb_board_js, flow_start, "function renderProps") orelse return error.PassiveFootprintFlowEndMissing;
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js[flow_start..flow_end], "location.reload") == null);
}

// spec: Web Server - The PCB pad aligner snaps exact pad centers and moves a source sub-circuit as one owner
test "PCB editor carries the exact pad alignment workflow" {
    const markers = [_][]const u8{
        "function padHitAt", "function padAlignOwner", "function padAlignApply",
        "target.x-source.x", "data-pad-axis",          "padAlignMode",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, marker) != null);
}

// spec: Web Server - F rigidly mirrors a selected sub-circuit or marquee group to the opposite board side around one stable anchor, preserving relative positions and orientations in one undo
test "PCB editor rigidly mirrors the complete selected part target" {
    const markers = [_][]const u8{
        "function flipAnchor(mv,want)",
        "function flipParts(idxs,wantAnchor)",
        "recordUndo();",
        "var before=stampPoseOf(P[anchor]);",
        "var after={x:before.x,y:before.y,rot:before.rot,back:!before.back};",
        "var xf=stampPoseCompose(after,stampPoseInverse(before));",
        "var np=stampPoseCompose(xf,stampPoseOf(P[i]));",
        "P[i].x=np.x;P[i].y=np.y;P[i].rot=np.rot;P[i].side=np.back?\"bottom\":\"top\"",
        "cur>=0&&sel.length>1&&sel.indexOf(cur)>=0",
        "flipParts(sel,cur)",
        "flipParts(GRPS[selGroup]||[])",
        "var fi=selRef?P.findIndex",
        "if(!selRef){var fgi=grpIdxs(fi);if(fgi){flipParts(fgi,fi);return;}}",
        "flipParts([fi],fi)",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, marker) != null);
}

// spec: Web Server - Generated RF fence sites render, select, and edit as ordinary vias; provenance remains internal for safe regeneration
// spec: Web Server - The PCB viewer offers a Fence action that lays (and regenerates) the RF ground via fence onto the active layout's routed RF traces — declared (fence …) classes and max-freq classes alike
test "PCB editor carries the RF via-fence action as ordinary vias" {
    const Check = struct { haystack: []const u8 = pcb_board_js, marker: []const u8, present: bool = true };
    const checks = [_]Check{
        // One normal via row, barrel path and visibility state cover hand-drawn
        // and generated vias alike.
        .{ .marker = "[\"via\",\"Vias\"" },
        .{ .marker = "var byL={},barrel=[],holes=new Path2D(),nb=0;" },
        .{ .marker = "via:anyCopperVisible()?1:0" },
        // The provenance tag survives undo/redo and net-keyed invalidation.
        .{ .marker = "g:v.g,f:v.f" },
        .{ .marker = "if(v.f)return !nets[v.f];" },
        // The action: POST, then reload onto the row the server just wrote.
        .{ .marker = "function fenceRun" },
        .{ .marker = "/api/pcb-fence/" },
        .{ .marker = "function fenceBtnSync" },
        .{ .marker = "PCB.fence_declared" },
        // The old visual class and its dedicated WebGPU slot are both gone.
        .{ .marker = "function isFenceVia", .present = false },
        .{ .marker = "function fenceVisible", .present = false },
        .{ .marker = "filt.fence", .present = false },
        .{ .marker = "[\"fence\",\"Fence vias\"", .present = false },
        .{ .marker = "fenceHole", .present = false },
        .{ .haystack = pcb_gpu_js, .marker = "fenceHole", .present = false },
        .{ .haystack = pcb_gpu_js, .marker = "S_FENCE", .present = false },
    };
    for (checks) |check| try std.testing.expect((std.mem.indexOf(u8, check.haystack, check.marker) != null) == check.present);
}

// spec: Web Server - Drilled via and through-hole pad bores remain board-coloured on every copper view, including generated RF fence sites and the far side of opaque pours
test "PCB editor keeps every drilled bore visible through pours and board flips" {
    const markers = [_][]const u8{
        "padThruTop:1,padThruBot:1",
        "boreTop:1,boreBot:1",
        "ctx.globalAlpha=padAlpha*(pd.drill>0?throughAlpha:focusAlpha)",
        "if(pfd<=0&&!(p.pads||[]).some(function(pd){return pd.drill>0;}))continue",
        // Ordinary editor/review bores remain; CAM Assembly takes them from
        // the independently toggled Excellon layer instead of repainting pads.
        "if(!CAM_REVIEW&&pp.bore&&(!gpuOwns(\"parts\")||hlAny)){ctx.globalAlpha=1",
        "via:anyCopperVisible()?1:0",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, marker) != null);

    const batch_barrel = std.mem.indexOf(u8, pcb_board_js, "for(var vi=0;vi<CB.v.length;vi++)").?;
    const batch_hole = std.mem.indexOfPos(u8, pcb_board_js, batch_barrel, "ctx.fill(CB.h)").?;
    try std.testing.expect(batch_barrel < batch_hole);
    const gpu_barrel = std.mem.indexOf(u8, pcb_gpu_js, "barrel.push([ux(v.x), uy(v.y), rr, 0, vc]);").?;
    const gpu_hole = std.mem.indexOfPos(u8, pcb_gpu_js, gpu_barrel, "hole.push([ux(v.x), uy(v.y), rh, 0, ch]);").?;
    try std.testing.expect(gpu_barrel < gpu_hole);
}

// PCB-editor via barrels and bores stay physical geometry even when a wide
// board's fit scale makes them smaller than the old display-size floor.
test "PCB editor renders vias at their true physical diameter" {
    const Check = struct { haystack: []const u8, marker: []const u8, present: bool = true };
    const checks = [_]Check{
        .{ .haystack = pcb_board_js, .marker = "function viaRenderRadius(mm){return mm*S/2;}" },
        .{ .haystack = pcb_board_js, .marker = "var rr=viaRenderRadius(v.d),dr=(v.drill>0)?v.drill:vgd;" },
        .{ .haystack = pcb_board_js, .marker = "var rh=viaRenderRadius(dr);" },
        .{ .haystack = pcb_board_js, .marker = "viaRenderRadius(v.d)+3" }, // selection fringe, separate from copper
        .{ .haystack = pcb_gpu_js, .marker = "var rr = v.d / 2 * S;" },
        .{ .haystack = pcb_gpu_js, .marker = "var rh = dr / 2 * S;" },
        .{ .haystack = pcb_board_js, .marker = "Math.max(v.d/2*S,2.5)", .present = false },
        .{ .haystack = pcb_board_js, .marker = "Math.max(dr/2*S,1)", .present = false },
        .{ .haystack = pcb_gpu_js, .marker = "Math.max(v.d / 2 * S, 2.5)", .present = false },
        .{ .haystack = pcb_gpu_js, .marker = "Math.max(dr / 2 * S, 1)", .present = false },
    };
    for (checks) |check| try std.testing.expect((std.mem.indexOf(u8, check.haystack, check.marker) != null) == check.present);
}

// spec: Web Server - the PCB viewer and replay clients derive their palettes from the blob theme, keeping their literals only as a no-blob fallback
test "PCB browser clients paint from the server's one board theme" {
    // TH/PH are DERIVED (blob over fallback), not two more literal tables, and
    // the fallback objects fix their shape so every TH.xxx read still resolves.
    // The overlay pass walks the SERVER object (`src`), not the fallback: a
    // colour added to board_theme.zig must reach the canvas without a JS edit,
    // and iterating the fallback there dropped every key it had yet to learn.
    const markers = [_][]const u8{
        "function themeFrom(base,src)",
        "if(src)for(k in src)",
        "var TH=themeFrom({bg:\"#001023\"",
        "PCB.theme&&PCB.theme.review",
        "SEL_CU=TH.sel",
        "hexRgba(top?TH.padTop:TH.padBot",
        "l.k==\"proximity\"?TH.awProx",
        // The GPU pour bake reads the SAME two theme keys its 2D twin above
        // does. Hardcoding the fallback hexes there was invisible while the
        // served theme was static, and would have split one board into two
        // colours the moment it became per-board — GPU is the default renderer.
        "ctx.strokeStyle=TH.drc;",
        "(L===0?TH.padTop:TH.padBot)",
    };
    try expectContainsAll(pcb_board_js, &markers);
    // The washes are decoded from the copper colour, never re-typed as rgba.
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, "rgba(200,52,52,") == null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, "rgba(77,127,196,") == null);
    // Nor re-typed as hex. Only the fallback tables (the layer rows and TH's
    // own defaults) may spell a copper colour, and they spell it uppercase —
    // so a lowercase copy is always a read site that escaped the theme.
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, "#c83434") == null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, "#4d7fc4") == null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_replay_js, "THEME.via || \"#B2B27A\"") != null);

    // The stylesheet names the properties the page defines, each with its
    // literal behind it so an embed without the block renders the same.
    const props = [_][]const u8{ "var(--pcb-cu-top,#C83434)", "var(--pcb-cu-bot,#4D7FC4)", "var(--pcb-bg,#001023)" };
    try expectContainsAll(pcb_layout_css, &props);
    try expectEveryVarIsEmitted(std.testing.allocator);
}

/// Every `--pcb-…` custom property the stylesheet READS is one the theme
/// WRITES — the independent oracle for `board_theme.cssProp`, which derives a
/// property name from its wire key instead of storing it. A `var(--pcb-x,#hex)`
/// whose property the emitter has renamed falls back to its own literal in
/// silence, which is a board painted from two palettes at once.
fn expectEveryVarIsEmitted(allocator: std.mem.Allocator) !void {
    var css: std.Io.Writer.Allocating = .init(allocator);
    defer css.deinit();
    try board_theme.writeCssVars(&css.writer);
    var seen: usize = 0;
    var rest: []const u8 = pcb_layout_css;
    while (std.mem.indexOf(u8, rest, "var(--pcb-")) |at| {
        rest = rest[at + "var(".len ..];
        const end = std.mem.indexOfAny(u8, rest, ",)") orelse return error.UnterminatedVar;
        var buf: [64]u8 = undefined;
        const declaration = try std.fmt.bufPrint(&buf, "{s}:", .{rest[0..end]});
        try std.testing.expect(std.mem.indexOf(u8, css.written(), declaration) != null);
        seen += 1;
    }
    // The stylesheet does consume the theme — an empty scan would pass vacuously.
    try std.testing.expect(seen >= 8);
}

/// Every needle appears somewhere in `haystack`.
fn expectContainsAll(haystack: []const u8, needles: []const []const u8) !void {
    for (needles) |needle| try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

// spec: Web Server - The /pcb-layout Appearance dock provides one generic Keepouts layer for fixed typed regions and clean active-copper net-class halos without overlap-darkened fills or decorative pad-escape rings
test "PCB editor carries the generic keepout overlay" {
    const markers = [_][]const u8{
        "function paintKeepouts", "function paintFixedKeepouts", "keepoutMaskCv",
        "viewSt.vis.keepouts",    "PCB.keepouts",                "destination-out",
        "keepout_mm",             "Keepouts",                    "rfKeepoutPadActive(p,pd)",
        "activeLayer",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, marker) != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, "keepout_escape_mm") == null);
}

// spec: Web Server - PCB keepout overlays retain width-batched net-class geometry and a transform-keyed raster so enabling them does not rebuild hundreds of paths on unchanged frames
test "PCB keepout rendering retains its batched geometry and raster" {
    const markers = [_][]const u8{
        "function keepoutBatchGet", "function keepoutStrokeBucket",
        "keepoutOverlayCache",      "function keepoutTransformKey",
        "keepoutMaskKey!==key",     "keepoutGeomDrop();if(gpuOn)",
        "mc.stroke(b.ot[oi].p)",    "ctx.drawImage(keepoutOverlayCv,0,0)",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, marker) != null);
}

test "PCB clearance halos follow exact rotated pad outlines" {
    const start = std.mem.indexOf(u8, pcb_board_js, "function paintClr").?;
    const end = std.mem.indexOfPos(u8, pcb_board_js, start, "window.addEventListener(\"resize\"").?;
    const painter = pcb_board_js[start..end];
    try std.testing.expect(std.mem.indexOf(u8, painter, "worldPadPath(p,pad)") != null);
    try std.testing.expect(std.mem.indexOf(u8, painter, "ctx.lineWidth=2*clr*S;ctx.stroke(shape);ctx.fill(shape)") != null);
    try std.testing.expect(std.mem.indexOf(u8, painter, "wrect(i,pad)") == null);
}

// spec: Web Server - PCB pad-number labels remain capped at 13 screen pixels regardless of pad geometry or zoom
test "PCB pad-number labels have a screen-space size ceiling" {
    const markers = [_][]const u8{
        "PAD_LABEL_MIN_PX=5.5,PAD_LABEL_MAX_PX=13",
        "var labelPx=Math.min(PAD_LABEL_MAX_PX,Math.min(pd.w,pd.h)*S*0.55*k)",
        "var fs=labelPx/k,haloWorld=Math.max(labelPx*0.16,0.7)/k",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, marker) != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, "if(fs*k<5.5)") == null);
}

// spec: Web Server - Front-only and Back-only PCB presets hide opposite-face SMD pad numbers and layer-scoped DRC markers while retaining through-hole labels and layerless findings
test "PCB side presets hide annotations owned by hidden copper" {
    const labels_start = std.mem.indexOf(u8, pcb_board_js, "function paintPadLabels").?;
    const labels_end = std.mem.indexOfPos(u8, pcb_board_js, labels_start, "function padPath").?;
    const labels = pcb_board_js[labels_start..labels_end];
    try std.testing.expect(std.mem.indexOf(u8, labels, "var padLayer=p.side===\"bottom\"?1:0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, labels, "if(!(pd.drill>0)&&layerAlpha(padLayer)<=0)continue;") != null);

    const marker_start = std.mem.indexOf(u8, pcb_board_js, "function drcMarkerVisible").?;
    const marker_end = std.mem.indexOfPos(u8, pcb_board_js, marker_start, "function drawDrc").?;
    const marker = pcb_board_js[marker_start..marker_end];
    try std.testing.expect(std.mem.indexOf(u8, marker, "d.l==null||layerAlpha(d.l)>0") != null);
}

// spec: Web Server - Front-only and Back-only PCB presets hide opposite-face sub-circuit bounding boxes and remove their empty-area hit targets
test "PCB side presets hide opposite-face sub-circuit boxes" {
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, "function partOnVisibleFace(p){return layerAlpha(p&&p.side===\"bottom\"?1:0)>0;}") != null);

    const paint_start = std.mem.indexOf(u8, pcb_board_js, "function paintGroupBoxes").?;
    const paint_end = std.mem.indexOfPos(u8, pcb_board_js, paint_start, "function paintPadAlign").?;
    const painter = pcb_board_js[paint_start..paint_end];
    try std.testing.expect(std.mem.indexOf(u8, painter, "if(unplacedSet[p.ref]||!partOnVisibleFace(p))return;") != null);

    const hit_start = std.mem.indexOf(u8, pcb_board_js, "function grpAt").?;
    const hit_end = std.mem.indexOfPos(u8, pcb_board_js, hit_start, "function grpToggle").?;
    const hit_test = pcb_board_js[hit_start..hit_end];
    try std.testing.expect(std.mem.indexOf(u8, hit_test, "if(unplacedSet[P[i].ref]||!partOnVisibleFace(P[i]))return;") != null);
}

// spec: Web Server - Front-only and Back-only PCB views exclude opposite-face footprints from hover, direct and exact-pad clicks, marquee and select-all selection, and every part/group transform
test "PCB side presets restrict footprint interaction to the visible face" {
    const markers = [_][]const u8{
        "if(!partOnVisibleFace(p)||!reviewPartOnShownSide(p))continue;",
        "function selSet(idxs){sel=visiblePartIdxs(idxs);",
        "if(!partOnVisibleFace(p))return;var b=partAABB(i);",
        "if(!p.locked&&partOnVisibleFace(p))all.push(i);",
        "if(unplacedSet[P[i].ref]||!partOnVisibleFace(P[i]))return;",
        "!P[k].locked&&partOnVisibleFace(P[k])",
        "!P[i].locked&&partOnVisibleFace(P[i])",
        "partInteractionVisibilitySync();",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, marker) != null);

    const picker_start = std.mem.indexOf(u8, pcb_board_js, "function pickPartHits").?;
    const picker_end = std.mem.indexOfPos(u8, pcb_board_js, picker_start, "function pickCandidates").?;
    const picker = pcb_board_js[picker_start..picker_end];
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, picker, "if(!partOnVisibleFace(p)||!reviewPartOnShownSide(p))return;"));
}

// spec: kicad_pcb/import-layout - the PCB editor previews KiCad warnings before replacing its starred layout
test "PCB editor carries the guarded inbound KiCad sync workflow" {
    const markers = [_][]const u8{
        "PCBFlushLayout",
        "?dry_run=1",
        "KiCad footprints with no design instance",
        "zones/keepouts are reported but not rendered",
        "Import into EDA",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_kicad_import_js, marker) != null);
}

// spec: Web Server - The PCB editor can explicitly make one named saved layout authoritative in KiCad after a destructive-change preview
test "PCB editor carries the guarded outbound KiCad layout push" {
    const markers = [_][]const u8{
        "PCBActiveLayoutName",
        "push_layout=1",
        "Replace KiCad layout",
        "This replaces every KiCad track, via, \" + LN.edge_cuts + \" item, and group. ",
        "refill zones before DRC/Gerber generation",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_kicad_import_js, marker) != null or
        std.mem.indexOf(u8, pcb_board_js, marker) != null);
}

// spec: Web Server - tangent trace bends and outline fillets remain native editable arcs in the PCB editor
test "PCB editor carries tangent arc routing geometry" {
    const markers = [_][]const u8{
        "function arcCorner",      "function arcRoundedTracks",  "function drawRoutePlan",
        "function drawCommitPlan", "kind:\"single\"",            "fit-limited arc",
        "function trackArcGeom",   "function outlineFilletGeom", "prop-outline-radius",
        "0.01",                    "3*(dtrace?dtrace.w",         "drawLegsViolate",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, marker) != null);
}

// spec: Web Server - While hand-routing, the PCB editor can toggle the preview and committed path between 45-degree octilinear and 90-degree Manhattan bends
test "PCB editor carries persistent 45 and 90 degree manual bend modes" {
    const markers = [_][]const u8{
        "DRAW_ANGLE_KEY=\"pcb-draw-angle\"",                                  "function drawAngleSet",
        "drawAngle+\"° trace bends\"",
        "if(drawAngle===\"90\")return [po===0?{x:t.x,y:ay}:{x:ax,y:t.y},t];", "drawAngleSet(drawAngle===\"45\"?\"90\":\"45\",true)",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, marker) != null);
}

test "PCB editor styles the two-trace fillet radius menu" {
    const markers = [_][]const u8{
        ".pcb-trace-menu{",
        ".pcb-trace-form{",
        ".pcb-trace-form input{",
        ".pcb-trace-error{",
        ".pcb-trace-buttons{",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_layout_css, marker) != null);
}

test "PCB editor automatically lowers every local controlled-impedance pad taper" {
    const markers = [_][]const u8{
        "function drawTaperProfile", "Math.abs(span-nominal)<=1e-9", "pad_neck_width",                      "kind:\"rf\"",
        "nominal*1.2",               "function drawTaperTracks",     "function drawApplyAutomaticTapers",   "automatic pad tapers added",
        "window.PCBDrawTaperTracks", "function drawTaperPath",       "track_ids:tracks.map(trackIdEnsure)", "window.PCBDrawPadLaunch",
        "function drawRfTaperPlan",  "window.PCBDrawRfTaperPlan",    "vias, opposite-side terminals",       "function drawTrackEndDirection",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, marker) != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, "function drawRfTaperAllowed") == null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, "function drawReplaceLaid") == null);
}

test "PCB editor DRC lowers taper polygons to private probe tracks" {
    for ([_][]const u8{ "var physicalTracks", "window.PCBRfOwnsTrack", "physicalTracks.push" }) |marker|
        try std.testing.expect(std.mem.indexOf(u8, drc_marshal_js, marker) != null or std.mem.indexOf(u8, pcb_board_js, marker) != null);
}

test "browser saves keep the newest-edited layout first in memory and in the panel" {
    const markers = [_][]const u8{
        "list.insertBefore(row,list.firstChild)",
        "Ls.splice(foundAt,1);Ls.unshift(found)",
        "else Ls.unshift({name:nm",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, marker) != null);
}

// spec: Web Server - PCB trace selection preserves layer color and component drags ignore click jitter
test "PCB trace highlight and component drag guard stay coupled to editor gestures" {
    const markers = [_][]const u8{
        "function layerHighlightColor", "PART_DRAG_SLOP_PX=5", "function partDragReady",
        "function dragSnapPose",        "d.x0+Math.round",     "drag.active",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, marker) != null);
}

// Browser-side contract for the assembly/debug physical PCB paint pipeline.
test "PCB review carries the physical board paint pipeline" {
    const markers = [_][]const u8{
        "var PHYSICAL_REVIEW=RO&&", "function paintPhysicalBoard", "PH.mask",
        "PCB.rules.mask_margin",    "PH.copperUnder",              "physicalFace",
        "Math.max(0.12*S,1)",       "function reviewFocusGroups",  "kind:reviewText(spec.kind)",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, marker) != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly_debug_js, "kind: kind || ''") != null);
    // Copper passes UNDER the part bodies in the review — an opaque package sits
    // on the board, so its copper cannot paint over it. That is now the shared
    // stage table's `rv` (review rank) ordering, checked against the canonical
    // list in render_order.zig; here we only assert the viewer still ranks the
    // three stages that way.
    const order = @import("../render_order.zig");
    try std.testing.expect(order.stages[order.indexOf("copper").?].review <
        order.stages[order.indexOf("parts").?].review);
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, "var seq=PHYSICAL_REVIEW?REVIEW_STAGES:PAINT_STAGES") != null);
}

// spec: Web Server - The Assembly board substrate paints parsed Gerber/Excellon operations instead of rebuilding fabrication artwork from browser fonts and placement objects
// spec: Web Server - Assembly layer controls independently toggle face copper, every physical inner copper layer, solder mask, paste, silkscreen, drills, board outline, and component overlays
test "Assembly review paints ordered CAM bytes with independent layer visibility" {
    const Check = struct { bytes: []const u8, marker: []const u8 };
    const checks = [_]Check{
        .{ .bytes = pcb_board_js, .marker = "var CAM_REVIEW=PHYSICAL_REVIEW&&PCB.cam" },
        .{ .bytes = pcb_board_js, .marker = "function paintCamBoard" },
        .{ .bytes = pcb_board_js, .marker = "function camDrawOp" },
        .{ .bytes = pcb_board_js, .marker = "if(L.negative)" },
        .{ .bytes = pcb_board_js, .marker = "if(camVisible(\"components\")){paintParts" },
        .{ .bytes = pcb_board_js, .marker = "eda-pcb-cam-visibility" },
        .{ .bytes = pcb_board_js, .marker = "PCB.cam.profile" },
        .{ .bytes = assembly_debug_js, .marker = "function applyCamLayers" },
        .{ .bytes = assembly_debug_js, .marker = "data-cam-layer" },
        .{ .bytes = assembly_debug_js, .marker = "assembly-cam-layers:" },
        .{ .bytes = assembly_debug_js, .marker = "populateInnerCopperLayers" },
        .{ .bytes = assembly_debug_js, .marker = "copper-inner-" },
        .{ .bytes = pcb_board_js, .marker = "innerLayers:STACK.filter" },
        .{ .bytes = pcb_board_js, .marker = "hasOwnProperty.call(camVisibility,L.id)" },
    };
    for (checks) |check| try std.testing.expect(std.mem.indexOf(u8, check.bytes, check.marker) != null);
}

// spec: Web Server - Assembly mask openings repaint actual pour copper as bare copper while leaving only copper-free gaps as exposed substrate
test "PCB review composes mask openings from substrate and actual copper" {
    const markers = [_][]const u8{
        "mc.strokeStyle=PH.substrate",
        "mc.globalCompositeOperation=\"source-atop\"",
        "reviewCopperAreas().forEach",
        "mc.fillStyle=PH.copper",
        "reviewAreaLayer(q)!==L",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, marker) != null);
}

// spec: Web Server - Assembly mask relief retains one authored-radius terminal fillet where a pad terminates or crosses the RF route
test "PCB review finishes rounded mask terminals after chord caps" {
    const start = std.mem.indexOf(u8, pcb_board_js, "function paintMaskRelief") orelse return error.TestUnexpectedResult;
    const tail = pcb_board_js[start..];
    const end = std.mem.indexOf(u8, tail, "function keepoutPolyPath") orelse return error.TestUnexpectedResult;
    const relief_painter = tail[0..end];
    try std.testing.expect(std.mem.indexOf(u8, relief_painter, "reliefOpeningPath") != null);
    try std.testing.expect(std.mem.indexOf(u8, relief_painter, "reliefTerminalFinish") != null);
    try std.testing.expect(std.mem.indexOf(u8, relief_painter, "destination-out") != null);
}

// spec: Web Server - Assembly and 3D mask relief restore a local pad-shaped web without interrupting the exposed trace
test "physical previews restore local mask islands around pads" {
    const board_markers = [_][]const u8{
        "function clearMaskPadIslands",             "worldPadPath(p,pd)", "PCB.rules&&PCB.rules.mask_web",
        "if(hasRfRelief)clearMaskPadIslands(mc,L)",
    };
    for (board_markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, marker) != null);

    const relief = std.mem.indexOf(u8, pcb_3d_surface_js, "punchRelief(ctx, data, side);") orelse return error.TestUnexpectedResult;
    const island = std.mem.indexOf(u8, pcb_3d_surface_js, "drawPadIslands(ctx, data, side);") orelse return error.TestUnexpectedResult;
    const aperture = std.mem.indexOfPos(u8, pcb_3d_surface_js, island, "drawPads(ctx, data, side, true);") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, pcb_3d_surface_js, "function drawPadIslands") != null);
    try std.testing.expect(relief < island and island < aperture);
}

// spec: Web Server - assembly model bodies load from persistent calibrated PNGs and render STEP only to populate a missing or stale filesystem cache entry
test "PCB review loads persistent model sprites before falling back to STEP" {
    const markers = [_][]const u8{
        "requestAnimationFrame(function () { requestAnimationFrame(start); })",
        "Object.keys(models).sort",
        "fetch(\"/api/model-sprite/\" + encodeURIComponent(footprint)",
        "if (loaded.sprite)",
        "return persistSprite(footprint, loaded.source, sprite)",
        "window.PCBSetAssemblySprite(footprint, sprite)",
        "if (renderStack) renderStack.then",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_model_sprites_js, marker) != null);
    const cache_lookup = std.mem.indexOf(u8, pcb_model_sprites_js, "cachedSprite(footprint") orelse return error.TestUnexpectedResult;
    const step_parse = std.mem.indexOf(u8, pcb_model_sprites_js, "parseModel(stack.occt, footprint)") orelse return error.TestUnexpectedResult;
    try std.testing.expect(cache_lookup < step_parse);
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, "assemblySprites[p.fp]") != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, "sprite.x*S,sprite.y*S,sprite.w*S,sprite.h*S") != null);
}

// spec: Web Server - the PCB 3D viewer extrudes the physical outline at the authored thickness and mounts bottom-side footprints beneath it
test "PCB 3D viewer uses the physical board profile and component side" {
    const markers = [_][]const u8{
        "function outlinePoints()",
        "DATA.board_poly",
        "DATA.rules.board_thickness",
        "new THREE.ExtrudeGeometry(shape",
        "board.position.z = -thickness",
        "var bottom = p.side === \"bottom\"",
        "mount.rotation.y = bottom ? Math.PI : 0",
        "mount.position.z = bottom ? -thickness : 0",
        "(p.side || \"top\")",
        "pcb3d-bottom",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_3d_viewer_js, marker) != null);
}

// spec: Web Server - the PCB 3D viewer composites each face's outer copper, soldermask, and silkscreen—including generated sub-circuit, test-point, and pin-1 artwork—into one non-overlapping visible cap and cuts circular drills and slots through the board
test "PCB 3D viewer textures both manufactured faces and cuts drills" {
    const Check = struct { bytes: []const u8, marker: []const u8 };
    const checks = [_]Check{
        .{ .bytes = pcb_3d_surface_js, .marker = "function drawCopper(ctx, data, side)" },
        .{ .bytes = pcb_3d_surface_js, .marker = "function maskCanvas(data, pts, b, width, height, scale, side)" },
        .{ .bytes = pcb_3d_surface_js, .marker = "function drawFootprintSilk(ctx, data, side)" },
        .{ .bytes = pcb_board_js, .marker = "window.PCBGeneratedSilk=function(){return boardSilkCurrentGeom();}" },
        .{ .bytes = pcb_3d_surface_js, .marker = "function drawGeneratedSilk(ctx, side)" },
        .{ .bytes = pcb_3d_surface_js, .marker = "(all.subs || []).forEach" },
        .{ .bytes = pcb_3d_surface_js, .marker = "(all.tps || []).forEach" },
        .{ .bytes = pcb_3d_surface_js, .marker = "(all.pin1 || []).forEach" },
        .{ .bytes = pcb_3d_surface_js, .marker = "new THREE.CanvasTexture(cv)" },
        .{ .bytes = pcb_3d_surface_js, .marker = "function collectHoles(data, pts)" },
        .{ .bytes = pcb_3d_surface_js, .marker = "pad.slot_half" },
        .{ .bytes = pcb_3d_surface_js, .marker = "ROUND_HOLE_SEGMENTS = 16" },
        .{ .bytes = pcb_3d_surface_js, .marker = "shape.holes.push(path)" },
        .{ .bytes = pcb_3d_viewer_js, .marker = "surface.collectHoles(DATA, pts)" },
        .{ .bytes = pcb_3d_viewer_js, .marker = "surface.makeTexture(THREE, DATA, pts, side)" },
        .{ .bytes = pcb_3d_viewer_js, .marker = "new THREE.ShapeGeometry(shape)" },
        .{ .bytes = pcb_3d_viewer_js, .marker = "new THREE.MeshBasicMaterial({ visible: false })" },
        .{ .bytes = pcb_3d_viewer_js, .marker = "color: surface.maskColor" },
        .{ .bytes = pcb_3d_viewer_js, .marker = "addBoardFace(shape, pts, \"top\", 0)" },
        .{ .bytes = pcb_3d_viewer_js, .marker = "addBoardFace(shape, pts, \"bottom\", -thickness)" },
        .{ .bytes = pcb_3d_viewer_js, .marker = "pcb3d-t-surface" },
    };
    for (checks) |check| try std.testing.expect(std.mem.indexOf(u8, check.bytes, check.marker) != null);
}

// spec: Web Server - PCB design-rule settings illustrate every board rule with an accessible SVG
test "PCB settings include an SVG explanation for every design rule" {
    const keys = [_][]const u8{
        "clearance",      "track_width",    "via_dia",                   "via_drill",      "min_width",
        "min_drill",      "min_annular",    "hole_to_hole",              "via_to_via",     "copper_edge",
        "component_edge", "pour_clearance", "pour_clearance_outer",      "pour_min_width", "pour_corner_radius",
        "ground_via_max", "mask_margin",    "mask_relief_corner_radius", "mask_web",       "board_thickness",
    };
    for (keys) |key| try std.testing.expect(std.mem.indexOf(u8, pcb_settings_js, key) != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_settings_js, "<svg class=\"ds-rule-svg\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_settings_js, "role=\"img\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_settings_js, "<title>") != null);
}

// spec: Web Server - Design Settings renders validated numeric rule inputs with save-and-rebuild feedback
test "PCB settings expose numeric rule editors and the save-rebuild action" {
    const markers = [_][]const u8{
        "data-ds-rule", "/api/design-rules/", "Save changes", "Saving and rebuilding", "location.reload()",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_settings_js, marker) != null);
}

// spec: Web Server - The PCB replay client streams the live-route endpoint into the timeline player, follows the head, and reattaches to a running job through the overlay seam
test "PCB replay client streams the live route and follows the head" {
    const markers = [_][]const u8{
        "panel-replay", // the dock (now inside the Route panel) it attaches to
        "PCBOverlay", // the non-persistent copper overlay seam
        "PCBOverlay.exclusive", // exclusive view mode: hides the board's own copper while a run/replay is loaded
        "rp-slider", // the transport scrubber control (grows during a live run)
        "rp-ghost", // the "ghost saved copper" toggle
        "route-live", // the live-route poll / cancel endpoint family
        "PCBLiveRoute", // the driver surface the Route button hands the job to
        "follow", // follow-head: track the newest event until the user scrubs back
        "reattach", // resume watching a job still running on page load
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_replay_js, marker) != null);
}

// spec: Web Server - The PCB live-route Stop action freezes the displayed elapsed time immediately while cooperative cancellation finishes, and resumes live progress if the cancellation request fails
test "PCB live-route Stop freezes elapsed time while cancellation finishes" {
    const markers = [_][]const u8{
        "stopping: false, elapsedMs: 0, stopElapsedMs: 0",
        "live.stopping = true; live.stopElapsedMs = live.elapsedMs;",
        "if (live.stopping) {",
        "(live.stopElapsedMs / 1000).toFixed(1)",
        "live.stopping = false;",
        "stop failed — router still running",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_replay_js, marker) != null);
}

// spec: Web Server - The PCB autorouter client offers full local-then-global and subcircuits-only stages, and the local stage never falls back to the blocking whole-board endpoint
test "PCB autorouter client selects a terminal subcircuit stage" {
    const markers = [_]struct { body: []const u8, marker: []const u8 }{
        .{ .body = pcb_board_js, .marker = "r-stage" },
        .{ .body = pcb_board_js, .marker = "Subcircuits + whole board" },
        .{ .body = pcb_board_js, .marker = "Subcircuits only" },
        .{ .body = pcb_board_js, .marker = "stage:stage" },
        .{ .body = pcb_board_js, .marker = "subcircuits-only stage needs the live router" },
        .{ .body = pcb_board_js, .marker = "Route subcircuits" },
        .{ .body = pcb_replay_js, .marker = "subcircuit_start" },
        .{ .body = pcb_replay_js, .marker = "Routing subcircuit" },
        .{ .body = pcb_replay_js, .marker = "subcircuit_complete" },
        .{ .body = pcb_replay_js, .marker = "Subcircuit complete" },
        .{ .body = pcb_replay_js, .marker = "Candidate copper from this module is now visible" },
    };
    for (markers) |check| try std.testing.expect(std.mem.indexOf(u8, check.body, check.marker) != null);
}

// spec: Web Server - The PCB live-route status freezes the local-stage clock when whole-board routing starts, names final DRC work, and preserves the final elapsed time after the job ends
test "PCB live-route status distinguishes finished local routing from later phases" {
    const cases = [_]struct { body: []const u8, marker: []const u8 }{
        .{ .body = pcb_replay_js, .marker = "sawSubcircuit: false, localElapsedMs: null" },
        .{ .body = pcb_replay_js, .marker = "Routing whole board" },
        .{ .body = pcb_replay_js, .marker = "Subcircuits \" + (live.localElapsedMs / 1000).toFixed(1) + \"s ✓" },
        .{ .body = pcb_replay_js, .marker = "finalizing DRC…" },
        .{ .body = pcb_replay_js, .marker = "elapsedMs: live.elapsedMs" },
        .{ .body = pcb_board_js, .marker = "typeof opts.elapsedMs===\"number\"" },
        .{ .body = pcb_board_js, .marker = "finalOpts.elapsedMs=liveMeta.elapsedMs" },
    };
    for (cases) |case| try std.testing.expect(std.mem.indexOf(u8, case.body, case.marker) != null);
}

// spec: Web Server - The PCB thermal overlay paints the cached heat field over the read-only board through the overlay seam
test "PCB thermal overlay claims the board overlay seam and reads the cached field endpoint" {
    const markers = [_][]const u8{
        "PCBOverlay", // the per-frame overlay hook it paints through
        "PCBOverlay.exclusive", // copper/clearance/DRC step aside under the heat wash
        "api/thermal-field", // the cached solve it reads (never solves anything itself)
        "thermal:view", // parent -> frame: scenario / ambient / opacity / labels
        "thermal:state", // frame -> parent: the payload the panel's legend reads
        "pcb-thermal", // the surface name this overlay answers to
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_thermal_js, marker) != null);
}

// spec: Web Server - The PCB board editor publishes the replay overlay, copper-adopt, and live-route result seams the replay client drives
test "PCB board editor exposes the replay overlay, copper-adopt, and live-route seams" {
    const markers = [_][]const u8{
        "window.PCBOverlay", // per-frame overlay hook painted after paintTracks
        "PCBOverlay.exclusive", // the exclusive-view switch that hides the board's own copper
        "function paintGuides", // exclusive view keeps placement guides while hiding airwires/copper
        "window.PCBAdoptCopper", // the shared Route-button copper application path
        "route-live", // the Route button POSTs /api/route-live/<name>/start to stream the live route
        "window.PCBApplyRouteResult", // the shared route-result application seam the live driver calls on finish
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, marker) != null);
}

test "PCB board find indexes and activates every phase-one entity kind" {
    try std.testing.expect(std.mem.indexOf(u8, pcb_find_header_html, "id=\"pcb-find-input\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_find_header_html, "role=\"combobox\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_find_header_html, "aria-controls=\"pcb-find-results\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_find_pane_html, "id=\"side-find\" hidden>") != null);
    const markers = [_][]const u8{
        "function findParse(raw)",
        "function findBuild(q)",
        "function findActivate(r)",
        "focusPart(r.data.ref,true)",
        "reviewSet({nets:[r.data.net]",
        "drcGoto(r.data.i)",
        "focusPoint(r.data.x,r.data.y)",
        "ev.key===\"ArrowDown\"||ev.key===\"ArrowUp\"",
        "ev.ctrlKey||ev.metaKey",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, marker) != null);
}

// spec: Web Server - The interactive route-session client bundles the stuck-net, corridor, and frontier surfaces
test "PCB route-session client carries the stuck-net, corridor, and frontier surfaces" {
    const markers = [_][]const u8{
        "route-session", // the /api/route-session/* endpoint family it drives
        "rs-stuck", // the stuck-net evidence card it fills
        "rs-corridor", // the corridor-drawing gesture control
        "frontier", // the search-frontier heatmap it paints from the stuck report
        "rs-occview", // the per-layer occupied-cells grid-view switcher
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_route_session_js, marker) != null);
}

// spec: Web Server - Every /pcb-layout client reads the page's lexical PCB blob directly, so no board read is gated on the undefined window.PCB
test "PCB clients read the lexical const PCB blob, never a window property" {
    // The page emits its blob as `const PCB=…` (pcb_layout_page.writePcbData).
    // A classic-script top-level `const` is a LEXICAL global, not a property on
    // window, so `window.PCB` is permanently undefined and any read gated on it
    // is dead code that silently takes its fallback branch. Two such gates in
    // pcb_route_session.js pinned the layers popover to a hard-coded two-layer
    // list and posted an empty parts array (routing the solved placement rather
    // than the board on screen). Nothing under assets/ may spell a gate that way.
    try expectNoScriptGatesOnWindowPcb();
    // The route-session client's two reads, in the strict-safe form the 3D
    // viewer established (it resolves lazily at init, so it cannot lean on its
    // module-level `typeof PCB === "undefined"` bail the way this client does).
    const session_reads = [_][]const u8{
        "(typeof PCB !== \"undefined\" && PCB.parts)", // start posts the board as drawn
        "(typeof PCB !== \"undefined\" && PCB.layer_table && PCB.layer_table.length)", // popover lists real layers
        "typeof r.l === \"number\"", // …filtered to the ROUTABLE rows, as pcb_board.js does
    };
    for (session_reads) |read| try std.testing.expect(std.mem.indexOf(u8, pcb_route_session_js, read) != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_3d_viewer_js, "(typeof PCB !== \"undefined\" ? PCB : {})") != null);
    // …and the sibling clients that always read the bare binding correctly.
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, "const P=PCB.parts") != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_replay_js, "(PCB.layer_table && PCB.layer_table.length)") != null);
}

// Client half of the assembly cold-load contract tested with the server output
// in pcb_layout_page.zig.
test "Assembly board defers exact CAM until after its first paint" {
    const markers = [_][]const u8{
        "function loadCamReview()",
        "requestAnimationFrame(function(){requestAnimationFrame(start);})",
        "fetch(PCB.cam_url)",
        "PCB.cam=cam;CAM_REVIEW=true",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, marker) != null);
}

/// No registered script may gate a read on `window.PCB` — the page's blob is a
/// lexical `const`, so such a gate is always false and silently takes its
/// fallback. Both spacings, since either spelling reads as a live guard.
fn expectNoScriptGatesOnWindowPcb() !void {
    for (registry) |asset| {
        if (asset.content_type != .JS) continue;
        try std.testing.expect(std.mem.indexOf(u8, asset.body, "window.PCB &&") == null);
        try std.testing.expect(std.mem.indexOf(u8, asset.body, "window.PCB&&") == null);
    }
}

// spec: Web Server - The Stuck-nets panel client renders the Route response's stuck diagnostics with copyable DSL remedies
test "PCB stuck-nets client binds the panel and renders remedies with a copy control" {
    const client_markers = [_][]const u8{
        "panel-stuck", // the accordion panel it attaches to
        "window.PCBStuckUpdate", // the seam pcb_board.js calls with the route response's stuck[]
        "PCBSelNet", // the idempotent board net-highlight bridge it flashes blockers/nets through
        "sk-target-code", // the code-target remedy badge (a router-limitation, no DSL)
        "sk-copy", // the DSL-snippet clipboard control
    };
    for (client_markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_stuck_js, marker) != null);
    // The Route button hands its stuck[] straight to the panel — never a second route.
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, "window.PCBStuckUpdate(j.stuck") != null);
}

// spec: Web Server - The /pcb-layout page ships a self-contained WebGPU board renderer, on by default where the browser exposes WebGPU and inert under the ?gpu=0 opt-out
test "PCB WebGPU renderer carries its own pipelines and honours the ?gpu=0 opt-out" {
    const gpu_markers = [_][]const u8{
        "window.PCBGpu", // the single global pcb_board.js drives it through
        "navigator.gpu", // the capability probe every path is gated on
        "requestAdapter", // …and the adapter that must actually answer
        "alphaMode: \"premultiplied\"", // it composites UNDER the (transparent) 2D canvas
        "@vertex fn vsSeg", // instanced capsule pipeline — tracks
        "@vertex fn vsCir", // annulus pipeline — via barrels, hole punches, drill bores
        "@vertex fn vsPad", // rect/circle SDF pipeline — pads
        "@vertex fn vsPoly", // fan-triangulated convex polygon pads
    };
    for (gpu_markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_gpu_js, marker) != null);
    // The board script decides GPU_REQ once per page load — WebGPU present and
    // no ?gpu=0 — hands the renderer a per-frame policy blob, and keeps every
    // seam behind that flag.
    const js = pcb_board_js;
    try std.testing.expect(std.mem.indexOf(u8, js, "GPU_REQ=!/(?:^|[?&])gpu=0(?:&|$)/.test(QS)&&!!(window.navigator&&window.navigator.gpu)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "PCBGpu.frame(vb,gpuState())") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "function gpuLive()") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "PCBGpu.rebuildCopper()") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "PCBGpu.rebuildParts()") != null);
    // The overscan pixel buffer stands down: a GPU pan is a uniform write.
    try std.testing.expect(std.mem.indexOf(u8, js, "if(gpuOn)return false;") != null);
    // The status-bar chip tracks the LIVE renderer state, device loss included.
    try std.testing.expect(std.mem.indexOf(u8, js, "function gpuStatusSync()") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "getElementById(\"st-gpu\")") != null);
}

// spec: Web Server - Custom pads use the exact Canvas2D polygon path instead of the WebGPU triangle fan
test "PCB WebGPU renderer leaves custom pads to exact Canvas2D painting" {
    const js = pcb_board_js;
    try std.testing.expect(std.mem.indexOf(u8, js, "var exactPoly=!!(pd.poly&&pd.poly.length>=3);") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "if(!gpuOwns(\"parts\")||hl||exactPoly)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "polyGpuSafe") == null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_gpu_js, "every custom outline to Canvas2D's exact polygon fill") != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_gpu_js, "var v0 = pd.poly[0]") == null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_gpu_js, "ACCEPTED LIMITATION") == null);
}

// spec: Web Server - WebGPU pan and zoom frames replay a cached render bundle until geometry, layer order, or visible-pour membership changes
test "PCB WebGPU renderer caches its static command stream as a render bundle" {
    const markers = [_][]const u8{
        "createRenderBundleEncoder",
        "function bundleFingerprint",
        "pass.executeBundles([bundle])",
        "bundle = null",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_gpu_js, marker) != null);
}

// spec: Web Server - The WebGPU renderer drops a track whose layer the board does not have instead of repainting it on F.Cu
test "PCB WebGPU renderer skips out-of-range track layers as the 2D path does" {
    // The bucket loop guards the push instead of clamping the index to 0.
    try std.testing.expect(std.mem.indexOf(u8, pcb_gpu_js, "if (L >= 0 && L < O.nsig) byL[L].push(ts[i]);") != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_gpu_js, "byL[(L >= 0 && L < O.nsig) ? L : 0]") == null);
    // The behaviour being matched: the 2D painter walks only real layers, so a
    // track on a layer the board has not got is drawn by neither renderer.
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, "function trackLayerOrder(){var ord=[];") != null);
}

// spec: Web Server - The Appearance panel separates Layers and Objects tabs, listing real fabrication layers in top-to-bottom physical order and the feature overlays under Objects
// spec: Web Server - The PCB editor selection filter includes the board outline and a session-only Outline only preset that disables every other filter type and suppresses board-text selection without making a reopened board appear unresponsive
test "PCB Appearance panel splits real layers from feature objects" {
    const Check = struct { haystack: []const u8 = pcb_board_js, marker: []const u8, present: bool = true };
    const checks = [_]Check{
        // The Layers rows are the copper stack followed by the static tech
        // layers; selectable overlays live under Objects. Net colours are the
        // permanent board presentation rather than another pane.
        .{ .marker = "function apLayerRows(){var rows=[];" },
        .{ .marker = "function apObjectRows(){return [" },
        .{ .marker = "function apNetsHtml(compact){", .present = false },
        .{ .marker = "{key:\"clr\",name:\"Clearance halos\"" },
        .{ .marker = "{key:\"padnum\",name:\"Pad numbers\"" },
        .{ .marker = "{key:\"netcol\",name:\"Net colours\"", .present = false },
        .{ .marker = "{key:\"rats\",name:\"Ratsnest\"", .present = false },
        .{ .marker = "{key:\"guides\",name:\"Placement guides\"", .present = false },
        .{ .marker = "var netColOn=true;" },
        // The selection filter is Objects' second half, not a separate builder.
        .{ .marker = "<span>Selection filter</span>" },
        .{ .marker = "function apFiltRows(){return [" },
        .{ .marker = "[\"outline\",\"Board outline\"" },
        .{ .marker = "data-ap-filt-only=\"outline\"" },
        .{ .marker = "return k===\"filt\"?undefined:v" },
        .{ .marker = "Legacy persisted filters are intentionally" },
        .{ .marker = "if(outlineOnlyFilter())directText=-1;" },
        .{ .marker = "if(!activeSketchIsArea()&&(outlineMode||outlineOnlyFilter()))drawOutlineSketchSelection" },
        // Pad-number labels became a real toggle rather than an unconditional pass.
        .{ .marker = "if(PHYSICAL_REVIEW||!viewSt.vis.padnum||k<1.15||gestureBusy())return;" },
        // The old split-brain wiring is gone with the panels it served.
        .{ .marker = "var box=document.getElementById(\"ap-objects\")", .present = false },
        .{ .marker = "apClr.addEventListener", .present = false },
        .{ .marker = "function copperLabel", .present = false },
    };
    for (checks) |check| try std.testing.expect((std.mem.indexOf(u8, check.haystack, check.marker) != null) == check.present);
}

// A stationary primary click over overlapping, filter-enabled PCB objects opens
// an exact-object chooser without delaying the normal click/drag path.
test "PCB editor click and hold disambiguates overlapping selectable objects" {
    const markers = [_][]const u8{
        "var PICK_HOLD_MS=450,PICK_SLOP_PX=5",
        "function pickCandidates(m){var out=[];",
        "if(viewSt.filt.sub)pickGroupHits(m)",
        "if(viewSt.filt.fp)pickPartHits(m)",
        "if(viewSt.filt.pad)pickPadHits(m)",
        "if(viewSt.filt.via){var vt=",
        "if(viewSt.filt.track){var tt=",
        "if(viewSt.filt.zone&&!RO)",
        "if(viewSt.filt.drc){var dt=",
        "if(items.length<2)return;h.open=true;pickGestureCancel();pickMenuOpen(items,h.at);",
        "if(Math.hypot(ev.clientX-h.cx,ev.clientY-h.cy)>PICK_SLOP_PX)pickHoldCancel",
        "class=\"pcb-pick-item\" role=\"menuitem\"",
        "function pickPreviewSet(c){var next=c?c.data:null;",
        "function pickMenuClose(){pickPreviewSet(null);",
        "b.addEventListener(\"pointerenter\",function(){pickPreviewSet(c);});",
        "b.addEventListener(\"focus\",function(){pickPreviewSet(c);});",
        "menu.addEventListener(\"pointerleave\",function(){pickPreviewSet(null);});",
        "function paintPickPreview(ctx){var d=pickPreview;if(!d)return;",
        "if(pickHoldRelease(ev)){ev.preventDefault();return;}",
        "if(pickMenu){ev.preventDefault();return;}",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, marker) != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_layout_css, ".pcb-pick-menu{") != null);
}

// spec: Web Server - A resolved board click retains the exact-object stack so Tab or Alt-click can cycle priority losers with the hold picker's preview and unified selection apply path
test "PCB editor cycles overlapping selectable objects after a click" {
    const markers = [_][]const u8{
        "function pickCycleSort(items){var rank={via:0,track:1,pad:2,fp:3,sub:4,zone:5,keepout:5,drc:6};",
        "function pickCycleRemember(m,at,data){pickPreviewSet(null);pickCycleSet(pickCandidates(m),at,data);}",
        "function pickMenuOpen(items,at){pickMenuClose();items=pickCycleSort(items);",
        "pickCycle.i=(pickCycle.i+step+n)%n;var c=pickCycle.items[pickCycle.i];pickSelect(c,pickCycle.at);pickPreviewSet(c);",
        "if(!RO&&!anyDrawTool()&&ev.button===0&&ev.altKey&&!ev.ctrlKey&&!ev.metaKey){pickHoldCancel();pickCycleAt(ev,m);return;}",
        "if(ev.key!==\"Tab\"||ev.ctrlKey||ev.metaKey||kbTyping(ev.target)||pickMenu||RO||anyDrawTool())return;",
        "pickCycleSet(items,at,c.data);pickSelect(c,at);",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, marker) != null);
}

// spec: Web Server - Marquee and Select All expose transient count chips that can drop one selection kind or Alt-keep only footprints, tracks, vias, or combined copper without changing the global Objects filter
test "PCB editor prunes bulk selections with post-hoc type chips" {
    const markers = [_][]const u8{
        "function marqChipApply(kind,only){var seed=selectionSeed();",
        "if(kind!==\"track\"&&kind!==\"copper\")seed.t=[];",
        "if(kind!==\"via\"&&kind!==\"copper\")seed.v=[];",
        "selectionCommit(seed);if(seed.p.length||seed.t.length||seed.v.length)marqChipsShow(marqChipsAt);",
        "b.setAttribute(\"data-selection-type\",s.k);",
        "selectionCommit({p:all,t:at,v:av});marqReport(all.length,at.length,av.length,null)",
        "selectionCommit({p:pick,t:ct,v:cv});marqReport(pick.length,ct.length,cv.length,ev)",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, marker) != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_layout_css, ".pcb-selection-chips{") != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_layout_css, ".pcb-selection-chip.copper{") != null);
}

// spec: Web Server - Double-clicking routed copper or pressing J under the pointer selects its endpoint/via-connected run, and repeating expands through the shared mixed-selection commit to every track and via on the net
test "PCB editor expands copper selection by connectivity then full net" {
    const markers = [_][]const u8{
        "function netCopper(seed){var net=netCollapse(seed.o.net||\"\");",
        "function connectedCopper(seed){var all=netCopper(seed);",
        "var roots=linksBuildNet({ts:all.t,vs:all.v,ps:[]})",
        "roots[connKey(t.x1,t.y1,t.l||0)]===root",
        "selectionCommit({p:[],t:cu.t,v:cu.v});marqChipsShow(at);",
        "double-click again for the full net",
        "(ev.key===\"j\"||ev.key===\"J\")",
        "if(!RO&&!anyDrawTool()){var cm=mm(ev),ch=semanticCopperAt(cm);",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, marker) != null);
}

// spec: Web Server - The /pcb-layout Appearance dock and the embed layers popover render their rows from one shared builder, so a layer is named, ordered and wired identically in both
test "PCB Appearance rows come from one builder for both containers" {
    const Check = struct { marker: []const u8, present: bool = true };
    const checks = [_]Check{
        // ONE fill helper, ONE wiring helper, applied to every container.
        .{ .marker = "function apFill(box,html){if(!box)return;box.innerHTML=html;apWire(box);}" },
        .{ .marker = "apFill(document.getElementById(\"ap-layers\"),apLayersHtml());" },
        .{ .marker = "apFill(document.getElementById(\"ap-objects\"),apObjectsHtml(false));" },
        .{ .marker = "apFill(document.getElementById(\"ap-nets\"),apNetsHtml(false));", .present = false },
        // The embed popover uses those same two builders.
        .{ .marker = "function apPopHtml(){return apLayersHtml()+apObjectsHtml(true);}" },
        .{ .marker = "function popOpen(){if(!pop||!lb)return;apFill(pop,apPopHtml());" },
        // One row renderer, so a row's markup exists in exactly one place.
        .{ .marker = "function apRow(r){var cur=(r.stack!=null&&r.stack===activeStack);" },
        .{ .marker = "function apWire(box){" },
        // …and one state read re-marks every container's rows.
        .{ .marker = "document.querySelectorAll(\"[data-ap-eye]\").forEach(function(b){\n   b.classList.toggle(\"off\",!viewSt.vis[b.getAttribute(\"data-ap-eye\")]);});" },
        // The popover no longer carries its own divergent naming or markup.
        .{ .marker = "function buildPop()", .present = false },
        .{ .marker = "lp-swatch", .present = false },
        .{ .marker = "lp-stack", .present = false },
        .{ .marker = "Top copper", .present = false },
    };
    for (checks) |check| try std.testing.expect((std.mem.indexOf(u8, pcb_board_js, check.marker) != null) == check.present);
}

// spec: Web Server - Footprint silkscreen and courtyards are visible per board side, and a hidden courtyard layer never hides a selected part's outline
test "PCB silkscreen and courtyard visibility split per board side" {
    const markers = [_][]const u8{
        // One flag per side, tested against the part's own side.
        "{key:LN.b_silks,name:LN.b_silks",
        "{key:LN.b_crtyd,name:LN.b_crtyd",
        // The silk eye is read by the footprint-silk pass, which paints above
        // the copper instead of inside paintParts.
        "if(!viewSt.vis[bot?LN.b_silks:LN.f_silks])continue;",
        "if(st&&st.c===TH.court&&!unp&&!viewSt.vis[bot?LN.b_crtyd:LN.f_crtyd])st=null;",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, marker) != null);
    // The single both-sides silk flag is gone.
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, "viewSt.vis.silk") == null);
}

// spec: Web Server - Every PCB layer's visibility is keyed by its canonical layer name and a stored legacy view state migrates onto those names once
test "PCB layer visibility keys are canonical names with a one-time migration" {
    const Check = struct { marker: []const u8, present: bool = true };
    const checks = [_]Check{
        .{ .marker = "function visKey(l){return layerName(l);}" },
        .{ .marker = "STACK.forEach(function(_L){viewSt.vis[_L.name]=(_L.l==null)?0:1;});" },
        .{ .marker = "TECH.forEach(function(_T){viewSt.vis[_T.key]=1;});" },
        // The migration table: position-named copper, the merged silk flag and
        // the short edge key all become the layer's own name, saved back once.
        .{ .marker = "function visMigrate(v){var out={},hit=false,k;" },
        .{ .marker = "if(k===\"top\"){hit=true;out[layerName(0)]=val;}" },
        .{ .marker = "else if(k===\"bottom\"){hit=true;out[layerName(1)]=val;}" },
        .{ .marker = "else if(/^l[0-9]+$/.test(k)){hit=true;out[layerName(parseInt(k.slice(1),10))]=val;}" },
        .{ .marker = "else if(k===\"silk\"){hit=true;out[LN.f_silks]=val;out[LN.b_silks]=val;}" },
        .{ .marker = "else if(k===\"edge\"){hit=true;out[LN.edge_cuts]=val;}" },
        .{ .marker = "return hit?out:null;}" },
        .{ .marker = "if(_vmig)viewSave();" },
        // Unknown keys keep being dropped: only known flags are copied across.
        .{ .marker = "for(var _k in viewSt.vis)if(_sv[_k]!==undefined)viewSt.vis[_k]=_sv[_k];" },
        // Painters read the canonical spelling…
        .{ .marker = "if(!tmp&&!viewSt.vis[LN.edge_cuts]&&!linePreview)return;" },
        // …and nothing still speaks the legacy namespace.
        .{ .marker = "vis:{top:1,bottom:1", .present = false },
        .{ .marker = "viewSt.vis[\"l\"+", .present = false },
        .{ .marker = "viewSt.vis.edge", .present = false },
    };
    for (checks) |check| try std.testing.expect((std.mem.indexOf(u8, pcb_board_js, check.marker) != null) == check.present);
}

// spec: Web Server - A PCB plane layer carries its own visibility eye, still renders when it is not the viewed row, and keeps vias drawn when it is the only visible copper
test "PCB plane layers have their own eye honoured by both pour painters" {
    const markers = [_][]const u8{
        // ONE alpha ladder, read by the 2D painter and the GPU state blob.
        "function planeAlpha(st){if(!st||!viewSt.vis[st.name])return 0;",
        "return st.i===activeStack?0.95:0.30;}",
        "a=planeOnly?planeAlpha(st):(L==null?0.55:layerAlpha(L));",
        "a=(st&&st.l==null?planeAlpha(st):(L==null?0.55:layerAlpha(L)))",
        // Vias survive a board showing nothing but a plane.
        "function anyCopperVisible(){for(var i=0;i<STACK.length;i++)if(viewSt.vis[STACK[i].name])return true;return false;}",
        // Viewing a plane reveals it, exactly as selecting copper does.
        "viewSt.vis[st.name]=1;",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, marker) != null);
    // The old "visible only while active" rule is gone from both painters.
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, "st.i===activeStack?0.95:0)") == null);
}

// spec: Web Server - The Appearance Layers tab offers All, Front, Back and Copper-only presets that rewrite the layer visibility map in one click
test "PCB Appearance layer presets rewrite the whole layer visibility map" {
    const markers = [_][]const u8{
        "var AP_PRESETS=[\"All\",\"Front\",\"Back\",\"Copper only\"];",
        "function apPresetApply(n){",
        // Copper: All everything, Front/Back the matching outer face, Copper
        // only every routable layer (planes stay off, as they default).
        "viewSt.vis[L.name]=(n===\"All\")?1:(n===\"Front\")?(L.l===0?1:0):(n===\"Back\")?(L.l===1?1:0):(L.l!=null?1:0);});",
        // Tech: sided rows follow the preset's side, unsided ones stay on, and
        // Copper only keeps Edge.Cuts as the board's frame.
        "viewSt.vis[T.key]=(n===\"All\")?1:(n===\"Copper only\")?(T.key===LN.edge_cuts?1:0):",
        "(f||b)?((n===\"Front\")===f?1:0):1;});",
        "data-ap-preset=",
        "apPresetApply(b.getAttribute(\"data-ap-preset\"));",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, marker) != null);
}

// spec: Web Server - The clearance-halo toggle persists with the rest of the PCB view state and both of its surfaces read that one value
test "PCB clearance halos persist in the view state instead of only the checkbox" {
    // A defaults-off key beside the other Appearance rows, saved through the
    // same viewSave() path, re-read by the painter, and mirrored onto every
    // surface holding the checkbox (an embed's ?clr=1 seeds it without saving).
    const markers = [_][]const u8{ "keepouts:1,antipads:0,clr:0,heatsink:1}", "function clrOn(){return !!viewSt.vis.clr;}", "function clrSet(on){viewSt.vis.clr=on?1:0;viewSave();clrSync();drawClr();}", "function clrSync(){var els=document.querySelectorAll(\"#r-clr-show\");", "if(clrCb.checked)viewSt.vis.clr=1;", "if(!clrOn())return;" };
    for (markers) |m| try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, m) != null);
    // …and never from the DOM checkbox the painter used to consult.
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, "var cb=document.getElementById(\"r-clr-show\");if(!cb||!cb.checked)return;") == null);
}

// spec: Web Server - The opt-in PCB frame benchmark briefly dwells at fit, maximum zoom, seek, and pan turnarounds without mixing those pauses into movement percentiles
test "PCB frame benchmark carries human-readable dwell points outside movement phases" {
    const markers = [_][]const u8{
        "dwell(\"fit\",300)",
        "dwell(\"max_zoom\",550)",
        "dwell(\"seek\",250)",
        "dwell(\"turn_\"+(n+1),350)",
        "if(ent.wait)setTimeout",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, marker) != null);
}
