//! Embedded browser assets and their content-hashed HTTP registry.
//! Contract tests here verify critical browser capabilities remain bundled.

const std = @import("std");
const httpz = @import("httpz");

const serve_root = @import("../serve.zig");
const Server = serve_root.Server;

const pdf_viewer_js = @embedFile("assets/pdf_viewer.js");
const pdf_viewer_css = @embedFile("assets/pdf_viewer.css");
// PDF.js 4.10.38 (Apache-2.0), copied verbatim from the matching pdfjs-dist
// package. The upstream license and provenance live beside these files under
// assets/vendor/pdfjs-4.10.38/. Keeping both modules embedded makes PDF pages
// deterministic and usable without a browser-to-CDN network path.
const pdfjs_lib_js = @embedFile("assets/vendor/pdfjs-4.10.38/pdf.min.mjs");
const pdfjs_worker_js = @embedFile("assets/vendor/pdfjs-4.10.38/pdf.worker.min.mjs");
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
// quads on a canvas UNDER the 2D overlay, camera = one uniform. The editor can
// opt out to its Canvas2D scene; Assembly's exact Gerber view requires this renderer.
// Script-tagged BEFORE pcb_board.js so window.PCBGpu exists when the board
// script boots. Earcut and the Gerber-region adapter precede it.
const pcb_gpu_js = @embedFile("assets/pcb_gpu.js");
const pcb_earcut_js = @embedFile("assets/pcb_earcut.js");
const pcb_region_js = @embedFile("assets/pcb_region.js");
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
const pcb_step_export_js = @embedFile("assets/pcb_step_export.js");
const pcb_step_worker_js = @embedFile("assets/pcb_step_worker.js");
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
    .{ .name = "pdfjs-4.10.38.min.mjs", .body = pdfjs_lib_js, .content_type = .JS },
    .{ .name = "pdfjs-worker-4.10.38.min.mjs", .body = pdfjs_worker_js, .content_type = .JS },
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
    .{ .name = "pcb_earcut.js", .body = pcb_earcut_js, .content_type = .JS },
    .{ .name = "pcb_region.js", .body = pcb_region_js, .content_type = .JS },
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
    .{ .name = "pcb_step_export.js", .body = pcb_step_export_js, .content_type = .JS },
    .{ .name = "pcb_step_worker.js", .body = pcb_step_worker_js, .content_type = .JS },
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
// spec: Web Server - Two selected straight sketch curves can be constrained co-linear, and dragging the two loose line endpoints of one open contour together snaps and merges their stable point identity to close the fabrication profile
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
        .{ .bytes = shape_sketch_js, .marker = "moveGeometry:moveGeometry" },
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
    try std.testing.expect(std.mem.indexOf(u8, pcb_3d_surface_js, "makeStepArtworkWrap") == null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_3d_viewer_js, "SHELL_BASED_SURFACE_MODEL") == null);
}

test "shape sketches expose co-linear constraints and dragged endpoint closure" {
    try std.testing.expect(std.mem.indexOf(u8, shape_sketch_js, "q.kind===\"collinear\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, shape_sketch_js, "function closingEndpointTarget(s,dragId,x,y,tol)") != null);
    try std.testing.expect(std.mem.indexOf(u8, shape_sketch_js, "function closeByMergingEndpoints(s,dropId,keepId)") != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, "data-sk=\"collinear\">Co-linear") != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, "OS.closingEndpointTarget(vsk,vdrag.id,vv.x,vv.y,9/S)") != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, "OS.closeByMergingEndpoints(avs.sketch,vd.id,vd.closeId)") != null);
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

// spec: Web Server - Saving an unchanged PCB state rechecks DRC without invalidating a concurrent copper-pour refill for that same state
test "layout save DRC preserves an in-flight pour refill" {
    const save_start = std.mem.indexOf(u8, pcb_board_js, "function persistLayoutNow(") orelse
        return error.TestExpectedSaveHandler;
    const save_tail = pcb_board_js[save_start..];
    const save_end = std.mem.indexOf(u8, save_tail, "window.PCBFlushLayout=function") orelse
        return error.TestExpectedSaveHandlerEnd;
    const save_body = save_tail[0..save_end];
    try std.testing.expect(std.mem.indexOf(u8, save_body, "scheduleDrc({stateUnchanged:true})") != null);

    const drc_start = std.mem.indexOf(u8, pcb_board_js, "function scheduleDrc(opts)") orelse
        return error.TestExpectedDrcScheduler;
    const drc_tail = pcb_board_js[drc_start..];
    const drc_end = std.mem.indexOf(u8, drc_tail, "// ── Client-side WASM DRC") orelse
        return error.TestExpectedDrcSchedulerEnd;
    const drc_body = drc_tail[0..drc_end];
    try std.testing.expect(std.mem.indexOf(u8, drc_body, "if(!opts.stateUnchanged)copperTouched()") != null);
}

// spec: Web Server - Copper-pour refill responses are accepted only when their exact board and pour inputs still match; the RF finish action waits for an existing refill instead of treating the occupied refill slot as a failure
test "RF finish waits for an active exact-state pour refill" {
    const refill_start = std.mem.indexOf(u8, pcb_board_js, "function refillPours(opts)") orelse
        return error.TestExpectedPourRefill;
    const refill_tail = pcb_board_js[refill_start..];
    const refill_end = std.mem.indexOf(u8, refill_tail, "pourBtns().forEach") orelse
        return error.TestExpectedPourRefillEnd;
    const refill_body = refill_tail[0..refill_end];
    try std.testing.expect(std.mem.indexOf(u8, refill_body, "var fresh=sig===pourStateSignature()") != null);
    try std.testing.expect(std.mem.indexOf(u8, refill_body, "seq===poursReqSeq") == null);

    const fence_start = std.mem.indexOf(u8, pcb_board_js, "function fenceRefreshGap") orelse
        return error.TestExpectedFenceGapRefresh;
    const fence_tail = pcb_board_js[fence_start..];
    const fence_end = std.mem.indexOf(u8, fence_tail, "function fenceRun") orelse
        return error.TestExpectedFenceGapRefreshEnd;
    const fence_body = fence_tail[0..fence_end];
    try std.testing.expect(std.mem.indexOf(u8, fence_body, "var sig=pourStateSignature()") != null);
    try std.testing.expect(std.mem.indexOf(u8, fence_body, "if(poursInFlight){setTimeout(start,100);return;}") != null);
    try std.testing.expect(std.mem.indexOf(u8, fence_body, "if(sig!==pourStateSignature())") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, "OS.movePoint(shape.sketch,vdrag.id,vgx,vgy,vdrag.closeId?null:vdrag.axis)") != null);
}

// spec: Web Server - Sliding a shape-sketch line through line-arc-line corner fillets carries each valid arc rigidly, including saved near-tangent fillets, and changes only the length of its outer straight neighbour
test "shape edge slides carry near-tangent fillets without changing their geometry" {
    // The shared kernel recognizes a simple line-arc-line corner by topology.
    // This includes visually rounded saved corners whose numeric tangent has
    // drifted, while standalone arcs, arc chains and branches remain excluded.
    try std.testing.expect(std.mem.indexOf(u8, shape_sketch_js, "function rigidFilletAt(s,host,pid)") != null);
    try std.testing.expect(std.mem.indexOf(u8, shape_sketch_js, "hit.length!==1||hit[0].kind!==\"arc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, shape_sketch_js, "outer.length!==1||outer[0].kind!==\"line\"||!arcCircle(s,arc)") != null);
    try std.testing.expect(std.mem.indexOf(u8, shape_sketch_js, "tangentAt(s,host,pid)") == null);
    // Its far joined point and native three-point midpoint follow the dragged
    // edge. The final exact translation preserves radius and sweep rather than
    // relying on the numerical solver to leave them merely close.
    try std.testing.expect(std.mem.indexOf(u8, shape_sketch_js, "{arc:f.arc.id,x:f.mx+dx,y:f.my+dy,weight:50}") != null);
    try std.testing.expect(std.mem.indexOf(u8, shape_sketch_js, "f.far.x=f.fx+tx;f.far.y=f.fy+ty;f.arc.mid[0]=f.mx+tx;f.arc.mid[1]=f.my+ty;") != null);
    // Every pointer move starts from the gesture snapshot, preventing repeated
    // move events from accumulating rounding or solver drift in the fillet.
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, "sketch0:sk&&OS.clone(sk)") != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, "if(sd.sketch0)shape.sketch=OS.clone(sd.sketch0)") != null);
}

fn registryHasAsset(name: []const u8) bool {
    for (registry) |a| {
        if (std.mem.eql(u8, a.name, name)) return true;
    }
    return false;
}

// spec: Web Server - The datasheet PDF viewer loads its pinned PDF.js runtime and worker from same-origin embedded assets, so offline/headless browsing never depends on a third-party CDN
test "the PDF viewer embeds its exact same-origin PDF.js runtime and worker" {
    try std.testing.expect(registryHasAsset("pdf_viewer.js"));
    try std.testing.expect(registryHasAsset("pdfjs-4.10.38.min.mjs"));
    try std.testing.expect(registryHasAsset("pdfjs-worker-4.10.38.min.mjs"));

    try std.testing.expect(std.mem.indexOf(u8, pdf_viewer_js, "from '/static/pdfjs-4.10.38.min.mjs'") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf_viewer_js, "workerSrc = '/static/pdfjs-worker-4.10.38.min.mjs'") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf_viewer_js, "://") == null);
    try std.testing.expect(std.mem.indexOf(u8, pdfjs_lib_js, "Copyright 2024 Mozilla Foundation") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdfjs_lib_js, "4.10.38") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdfjs_worker_js, "Copyright 2024 Mozilla Foundation") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdfjs_worker_js, "4.10.38") != null);

    const raster_done = std.mem.indexOf(u8, pdf_viewer_js, "await page.render(") orelse return error.PdfRasterMissing;
    const text_done = std.mem.indexOfPos(u8, pdf_viewer_js, raster_done, "await textLayer.render()") orelse return error.PdfTextLayerMissing;
    const highlights_done = std.mem.indexOfPos(u8, pdf_viewer_js, text_done, "if (currentQuery) applyHighlightTo(rec)") orelse return error.PdfHighlightsMissing;
    const completion = std.mem.indexOfPos(u8, pdf_viewer_js, highlights_done, "dataset.renderComplete = 'true'") orelse return error.PdfCompletionMissing;
    try std.testing.expect(raster_done < text_done);
    try std.testing.expect(text_done < highlights_done);
    try std.testing.expect(highlights_done < completion);
    try std.testing.expect(std.mem.indexOf(u8, pdf_viewer_js, "firstMatch.scrollIntoView({ behavior: 'auto'") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf_viewer_js, "document.body.dataset.pdfReady = 'true'") != null);

    const lib_sha256 = [_]u8{ 0x27, 0xfc, 0x2a, 0x05, 0x7a, 0x00, 0xf9, 0x2a, 0x43, 0x34, 0xad, 0x06, 0xe1, 0x7d, 0xbd, 0x72, 0x59, 0x91, 0x29, 0x54, 0xe9, 0xfb, 0x7f, 0x76, 0x40, 0x0b, 0xcc, 0xa5, 0xfd, 0x19, 0x0a, 0x9c };
    const worker_sha256 = [_]u8{ 0x1b, 0xaa, 0x18, 0x44, 0xc8, 0x9c, 0x80, 0xa5, 0xb2, 0x79, 0x7c, 0x91, 0x6e, 0x75, 0xab, 0x29, 0x25, 0x4b, 0xe4, 0x6d, 0x8e, 0x9c, 0xb5, 0x3c, 0xb6, 0x36, 0x4d, 0x7a, 0xad, 0x84, 0xbe, 0x36 };
    var actual: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(pdfjs_lib_js, &actual, .{});
    try std.testing.expectEqualSlices(u8, &lib_sha256, &actual);
    std.crypto.hash.sha2.Sha256.hash(pdfjs_worker_js, &actual, .{});
    try std.testing.expectEqualSlices(u8, &worker_sha256, &actual);
}

// Keep the dense STEP scene idle between interactions and return its temporary
// gesture-scale drawing buffer to native resolution after camera movement.
// spec: Web Server - the footprint 3D alignment viewer renders only after scene or camera changes and temporarily lowers raster density during camera gestures
test "model alignment viewer is event-driven and restores full idle quality" {
    const markers = [_][]const u8{
        "function requestRender()",
        "controls.addEventListener(\"change\", requestRender)",
        "setRenderScale(0.6)",
        "qualityRestoreReady = true",
        "setRenderScale(1)",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, model_viewer_3d_js, marker) != null);
    try std.testing.expect(std.mem.indexOf(u8, model_viewer_3d_js, "requestAnimationFrame(loop)") == null);
}

// spec: Web Server - The PCB editor paints saved geometry, restores exact-state copper fills from persistent browser storage or the fast refill endpoint, then launches whole-board diagnostics and electrical analyses
test "PCB editor defers whole-board analyses until after its first paint" {
    const checks = [_]struct { marker: []const u8, present: bool }{
        .{ .marker = "function loadStarMatch()", .present = true },
        .{ .marker = "el.addEventListener(\"click\",loadStarMatch)", .present = true },
        .{ .marker = "fetch(\"/api/layout-progress/\"", .present = true },
        .{ .marker = "progEnsureChip(); // cheap placeholder; the first click performs the analysis", .present = true },
        .{ .marker = "function loadDeferredAnalysis()", .present = true },
        .{ .marker = "var deferredAnalysisSeq=0", .present = true },
        .{ .marker = "if(run===deferredAnalysisSeq&&PCB.analysis_deferred)loadDeferredAnalysis()", .present = true },
        .{ .marker = "function pourCacheRead(done)", .present = true },
        .{ .marker = "refillPours({deferred:true,done:analysis})", .present = true },
        .{ .marker = "u.searchParams.set(\"derived\",\"1\")", .present = true },
        .{ .marker = "if(!opts.deferred)scheduleServerReconcile()", .present = true },
        .{ .marker = "requestAnimationFrame(function(){requestAnimationFrame(start);});", .present = true },
        .{ .marker = "drcChip(PCB.analysis_deferred?-1:(PCB.drc||[]).length)", .present = true },
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

// spec: Web Server - Clicking a selected PCB part's component name or resolved MPN in Properties copies that exact identifier to the clipboard and reports success
test "PCB part properties copy component and MPN identifiers" {
    const markers = [_][]const u8{
        "pCopyRow(\"Component\",p.component,\"component name\")",
        "p.mpn?pCopyRow(\"MPN\",p.mpn,\"MPN\")",
        "navigator.clipboard.writeText(text)",
        "document.execCommand(\"copy\")",
        "wirePropCopies(body)",
        "btn.textContent=ok?\"Copied \\u2713\":\"Copy failed\"",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, marker) != null);
}

// PCB outline vertex marks appear only during outline editing and retain the
// existing larger coordinate-tested drag target.
test "PCB board outline editing shows compact vertex dots without shrinking hit targets" {
    const markers = [_][]const u8{
        "OUTLINE_VERTEX_SIZE=3;",
        "r:OUTLINE_VERTEX_SIZE/2,fill:col",
        "if(editing)(nominal||pts).forEach",
        "if(editing){var rc=outlinePtsOf(outlineEditable());",
        "function vtxAt(m)",
        "var bd=7/S,best=-1;",
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

// spec: Web Server - The PCB pad aligner moves only the source footprint when both selected pads belong to the same sub-circuit, while an outside target still moves the source sub-circuit as one owner
test "PCB pad alignment resolves same-subcircuit targets to footprint ownership" {
    const start = std.mem.indexOf(u8, pcb_board_js, "function padAlignOwner(hit,target)") orelse
        return error.PadAlignOwnerMissing;
    const tail = pcb_board_js[start..];
    const end = std.mem.indexOf(u8, tail, "function padAlignLabel") orelse
        return error.PadAlignOwnerEndMissing;
    const owner = tail[0..end];
    try std.testing.expect(std.mem.indexOf(u8, owner, "scoped=!!(PCB.sub&&PCB.sub.length)") != null);
    try std.testing.expect(std.mem.indexOf(u8, owner, "sameg=!!(target&&srcg&&srcg===grpOf(P[target.i].ref))") != null);
    try std.testing.expect(std.mem.indexOf(u8, owner, "g=(scoped||sameg)?null:srcg") != null);
    try std.testing.expect(std.mem.indexOf(u8, owner, "[hit.i]") != null);

    // The second pad participates in ownership resolution both when it is
    // picked and when the move is applied. Same-subcircuit pads therefore
    // resolve to the source footprint, while an outside target retains the
    // assembled board's whole-subcircuit ownership.
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, "padAlignOwner(hit,hit)") != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, "padAlignOwner(padAlignA,hit)") != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, "padAlignOwner(padAlignA,padAlignB)") != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, "moving.idxs.indexOf(hit.i)>=0") != null);
}

// spec: Web Server - F rigidly mirrors a selected sub-circuit or marquee group to the opposite board side around one stable anchor, preserving relative positions, orientations, traces, vias, and copper pours in one undo
test "PCB editor rigidly mirrors the complete selected target and its owned copper" {
    const markers = [_][]const u8{
        "function flipAnchor(mv,want)",
        "function flipParts(idxs,wantAnchor)",
        "recordUndo();",
        "var before=stampPoseOf(P[anchor]);",
        "var after={x:before.x,y:before.y,rot:before.rot,back:!before.back};",
        "var xf=stampPoseCompose(after,stampPoseInverse(before));",
        "var g=flipTargetGroup(mv),cop=carriedCopper(mv,g,!g),fills=zoneFillsFor(cop.z);",
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

    const flip_start = std.mem.indexOf(u8, pcb_board_js, "function flipParts(idxs,wantAnchor)") orelse
        return error.FlipPartsMissing;
    const flip_tail = pcb_board_js[flip_start..];
    const flip_end = std.mem.indexOf(u8, flip_tail, "function stampPoseNorm") orelse
        return error.FlipPartsEndMissing;
    const flip_body = flip_tail[0..flip_end];
    try std.testing.expect(std.mem.indexOf(u8, flip_body, "clearRouteFor") == null);
    // Copper moves in place rather than deleting/replacing a whole board array.
    try std.testing.expect(std.mem.indexOf(u8, flip_body, "PCB.tracks=") == null);
    try std.testing.expect(std.mem.indexOf(u8, flip_body, "PCB.vias=") == null);
    try std.testing.expect(std.mem.indexOf(u8, flip_body, "rfDropForTracks(cop.t)") != null);
    try std.testing.expect(std.mem.indexOf(u8, flip_body, "stampPoseApply(xf,t.x1,t.y1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, flip_body, "stampLayer(t.l||0,xf.back)") != null);
    try std.testing.expect(std.mem.indexOf(u8, flip_body, "stampPoseApply(xf,v.x,v.y)") != null);
    try std.testing.expect(std.mem.indexOf(u8, flip_body, "stampPoseApply(xf,+p[0],+p[1])") != null);
    try std.testing.expect(std.mem.indexOf(u8, flip_body, "flipAreaFace(z)") != null);
    try std.testing.expect(std.mem.indexOf(u8, flip_body, "flipAreaFace(f)") != null);
    try std.testing.expect(std.mem.indexOf(u8, flip_body, "if(cop.z.length)refillPours()") != null);
    try std.testing.expect(std.mem.indexOf(u8, flip_body, "ratsUpdate(mv)") != null);
    try std.testing.expect(std.mem.indexOf(u8, flip_body, "scheduleDrc()") != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, "zone_fills:cloneZoneFills()") != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, "PCB.zone_fills=JSON.parse(JSON.stringify(s.zone_fills||[]));") != null);
    // The properties dropdown is the same operation, not a pose-only shortcut.
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, "flipParts([i],i);") != null);
}

// spec: Web Server - Generated RF fence sites render with a dashed annular ring in both Canvas and WebGPU views, while ordinary and perimeter vias stay solid; all remain selectable and editable, and provenance remains internal for safe regeneration
// spec: Web Server - The PCB viewer offers one Tapers + fence action that preserves RF route centerlines while refreshing controlled-impedance widths and ground-pour gaps, replaces stale taper paths from current pad and route geometry, DRC-gates and saves the result, then regenerates the RF ground via fence around that exact copper and a board-wide 5 mm GND stitching grid whose blocked sites may shift by at most 1 mm
// spec: Web Server - The PCB editor always shows the RF via-fence action, regardless of whether the board declares perimeter fencing or currently resolves a fenceable RF class
test "PCB editor renders generated RF fence vias as dashed editable annuli" {
    const Check = struct { haystack: []const u8 = pcb_board_js, marker: []const u8, present: bool = true };
    const checks = [_]Check{
        // One normal via row and visibility state cover every via. Generated
        // RF-fence barrels alone branch to the dashed annulus in both renderers.
        .{ .marker = "[\"via\",\"Vias\"" },
        .{ .marker = "var byL={},barrel=[],fence=[],holes=new Path2D();" },
        .{ .marker = "function paintFenceVia" },
        .{ .marker = "function paintFenceVias" },
        .{ .marker = "paintFenceVias(ctx,CB.f)" },
        .{ .marker = "if(routeFenceVia(v))paintFenceVia" },
        .{ .marker = "viaFence:routeFenceVia" },
        .{ .haystack = pcb_gpu_js, .marker = "(O.viaFence && O.viaFence(v)) ? -rh : 0" },
        .{ .haystack = pcb_gpu_js, .marker = "sin(3.0 * atan2" },
        .{ .marker = "via:anyCopperVisible()?1:0" },
        // The provenance tag survives undo/redo so fence regeneration can
        // still distinguish generated sites from ordinary ground vias.
        .{ .marker = "g:v.g,f:v.f" },
        // The action: update widths without moving the stored centreline,
        // rebuild tapers, refill the derived CPWG gap, save that exact copper,
        // POST the fence around its row, then reload what the server wrote.
        .{ .marker = "function fenceRun" },
        .{ .marker = "drawRfClassWidthPlan()" },
        .{ .marker = "drawRfClassWidthsSet(widths,false)" },
        .{ .marker = "drawRfRetrofitSaved({replace:true,undoBefore:before,widthChanged:!!changed" },
        .{ .marker = "drawRfRetrofitCheck(original)" },
        .{ .marker = "refillPours({deferred:true" },
        .{ .marker = "persistLayout(curLayout,\"updating\",false)" },
        .{ .marker = "Tapers + fence" },
        .{ .marker = "/api/pcb-fence/" },
        .{ .marker = "grid.shifted+\" shifted ≤1 mm" },
        // The action is never hidden based on board metadata. In particular,
        // perimeter-fence and RF-class declarations do not gate visibility.
        .{ .marker = "function fenceBtnSync", .present = false },
        .{ .marker = "function fenceDeclared", .present = false },
        .{ .marker = "style.display=fence", .present = false },
        // The old filter/visibility class and dedicated WebGPU slot remain gone:
        // dashed provenance is a barrel style, not another selectable object row.
        .{ .marker = "function isFenceVia", .present = false },
        .{ .marker = "function fenceVisible", .present = false },
        .{ .marker = "filt.fence", .present = false },
        .{ .marker = "[\"fence\",\"Fence vias\"", .present = false },
        .{ .marker = "fenceHole", .present = false },
        .{ .haystack = pcb_gpu_js, .marker = "fenceHole", .present = false },
        .{ .haystack = pcb_gpu_js, .marker = "S_FENCE", .present = false },
    };
    for (checks) |check| try std.testing.expect((std.mem.indexOf(u8, check.haystack, check.marker) != null) == check.present);

    const finish_start = std.mem.indexOf(u8, pcb_board_js, "function fenceRun") orelse
        return error.FenceRunMissing;
    const width_start = std.mem.indexOf(u8, pcb_board_js, "function drawRfClassWidthPlan") orelse
        return error.FenceWidthPlanMissing;
    const width_end = std.mem.indexOfPos(u8, pcb_board_js, width_start, "function drawRfRetrofitSaved") orelse
        return error.FenceWidthPlanEndMissing;
    const width_body = pcb_board_js[width_start..width_end];
    try std.testing.expect(std.mem.indexOf(u8, width_body, "q.track.w=w") != null);
    try std.testing.expect(std.mem.indexOf(u8, width_body, "q.track.x1=") == null);
    try std.testing.expect(std.mem.indexOf(u8, width_body, "q.track.y1=") == null);
    try std.testing.expect(std.mem.indexOf(u8, width_body, "q.track.x2=") == null);
    try std.testing.expect(std.mem.indexOf(u8, width_body, "q.track.y2=") == null);
    const finish_body = pcb_board_js[finish_start..];
    const width_at = std.mem.indexOf(u8, finish_body, "drawRfClassWidthsSet(widths,false)") orelse
        return error.FenceWidthRefreshMissing;
    const rebuild_at = std.mem.indexOf(u8, finish_body, "drawRfRetrofitSaved({replace:true,undoBefore:before,widthChanged:!!changed") orelse
        return error.FenceTaperRebuildMissing;
    const gap_at = std.mem.indexOf(u8, finish_body, "fenceRefreshGap(b,tapers,changed)") orelse
        return error.FenceGapRefreshMissing;
    const gap_start = std.mem.indexOf(u8, pcb_board_js, "function fenceRefreshGap") orelse
        return error.FenceGapFunctionMissing;
    const gap_body = pcb_board_js[gap_start..finish_start];
    const refill_at = std.mem.indexOf(u8, gap_body, "refillPours({deferred:true") orelse
        return error.FencePourRefillMissing;
    const gap_save_at = std.mem.indexOf(u8, gap_body, "fenceSave(b,tapers,widths,true)") orelse
        return error.FenceGapSaveMissing;
    const save_start = std.mem.indexOf(u8, pcb_board_js, "function fenceSave") orelse
        return error.FenceSaveFunctionMissing;
    const save_body = pcb_board_js[save_start..gap_start];
    const save_at = std.mem.indexOf(u8, save_body, "persistLayout(curLayout,\"updating\",false)") orelse
        return error.FenceTaperSaveMissing;
    const fence_at = std.mem.indexOf(u8, save_body, "fencePost(b,tapers,widths,gap)") orelse
        return error.FencePostMissing;
    try std.testing.expect(width_at < rebuild_at);
    try std.testing.expect(rebuild_at < gap_at);
    try std.testing.expect(refill_at < gap_save_at);
    try std.testing.expect(save_at < fence_at);
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
        "function paintViaHoles(ctx,cop,only)",
        "ctx.fill(cuBatchGet().h)",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, marker) != null);

    const batch_barrel = std.mem.indexOf(u8, pcb_board_js, "for(var vi=0;vi<CB.v.length;vi++)").?;
    const batch_hole = std.mem.indexOfPos(u8, pcb_board_js, batch_barrel, "ctx.fill(cuBatchGet().h)").?;
    try std.testing.expect(batch_barrel < batch_hole);
    const gpu_barrel = std.mem.indexOf(u8, pcb_gpu_js, "barrel.push([ux(v.x), uy(v.y), rr, (O.viaFence && O.viaFence(v)) ? -rh : 0, vc]);").?;
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

// spec: Web Server - PCB keepout overlays retain width-batched net-class geometry and one transform-keyed raster cropped to the visible halo bounds, painting fixed regions directly so a zoom never clears or copies a redundant viewport-sized overlay
test "PCB keepout rendering retains its batched geometry and raster" {
    const markers = [_][]const u8{
        "function keepoutBatchGet",                                          "function keepoutStrokeBucket",
        "paintFixedKeepouts(ctx,k);paintNetKeepouts(ctx,keepoutBatchGet())", "function keepoutTransformKey",
        "function keepoutPixelBounds",                                       "mc.clearRect(crop.x,crop.y,crop.w,crop.h)",
        "keepoutMaskKey!==key",                                              "keepoutGeomDrop();if(gpuOn)",
        "mc.stroke(b.ot[oi].p)",                                             "ctx.drawImage(cv,crop.x,crop.y,crop.w,crop.h",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, marker) != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, "keepoutOverlayCv") == null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, "keepoutOverlayCache") == null);
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
        "Import into netlisp",
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

// spec: Web Server - The PCB hand router defers adaptive electrical-width verdicts its zone-blind WASM tier cannot prove, while retaining branch-floor and fabrication-minimum errors locally
test "PCB hand router defers adaptive electrical width without hiding hard width floors" {
    const markers = [_][]const u8{
        "v=c&&parseFloat(c.power_branch_width)",
        "if(!(v>0))v=c&&parseFloat(c.width)",
        "function drcGateDefersPowerWidth(d)",
        "d.k!==\"track width\"",
        "if(branch>0)return +d.gap+1e-7>=branch",
        "adaptive>0&&+d.gap+1e-7>=fab",
        "!DRC_BLOCK[d.k]||drcGateDefersPowerWidth(d)",
        "applyDrcOverrides(resp.drc).filter(function(d){return !drcGateDefersPowerWidth(d);})",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, marker) != null);
}

// Every finding whose verdict needs the server's current / fill solve is
// deferred by PREFIX, so a parenthesised qualifier the checker adds later
// ("power width (envelope)") cannot leak an unprovable error into the fast
// client tier before this list is updated.
// spec: Web Server - The PCB editor defers every server-solved power finding — the solved width, its whole-rail envelope variant, and the via-count rule — to the authoritative server DRC
test "PCB editor defers every server-only power DRC kind by prefix" {
    const markers = [_][]const u8{
        "function drcPowerKindDeferred(k)",
        "k.indexOf(\"power width\")===0||k.indexOf(\"via current\")===0",
        "if(drcPowerKindDeferred(d.k))return true;",
        "if(d.k&&d.k.indexOf(\"via current\")===0)return tag+d.k+on+",
        "if(d.k&&d.k.indexOf(\"power width\")===0)return tag+d.k+on+",
        "function drcReason(d)",
        "d.reason||d.why||d.msg",
        // The recut is seeded by the SOLVED kind only: the envelope variant is
        // a warning about a rail the server could not solve, and a warning must
        // not drive an automatic recut of copper the user placed.
        "forEach(function(d){if(d.k!==\"power width\")return;",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, marker) != null);
}

// spec: Web Server - The PCB editor widens adaptive power copper to each track's own solved branch current, falling back to the whole-rail envelope only when that screen is absent, stale, or unsolved
test "PCB editor sizes adaptive power copper per track from the solved screen" {
    const markers = [_][]const u8{
        "var POWER_WIDTH_STEP=0.0254;",
        "function powerWidthRound(mm)",
        "function powerFlowSolved(status)",
        "status===\"solved\"||status===\"solved-partial\"",
        "function powerTargetForTrack(t)",
        "var a=powerIntegrityDirty?null:powerIntegrityInfo(net),g=a?powerIntegrityTrack(a,t||{}):null;",
        "source:\"rail\"",
        "source:\"branch\"",
        "Math.max(fab,branchFloor,powerWidthRound(req))",
        // Widening only: a solved branch target below the copper already on the
        // board must never recut a wide trunk down.
        "var q=powerTargetForTrack(t),target=Math.max(q.target,Math.min(+((t&&t.w))||0,rail));",
        "function rewidenRunTarget(tracks,geo)",
        "run.target=rewidenRunTarget(run.tracks,geo)",
        "return powerTargetForTrack({net:net||\"\"}).target||v;",
        // The inspector names the authority behind the required width.
        "Sized by branch current: ",
        "Sized by whole-rail envelope: ",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, marker) != null);
}

// spec: Web Server - A click that magnetically snaps to a same-net pad or existing trace endpoint finishes the manual trace only after the path reaches that endpoint.
test "PCB editor finishes a manual trace on a magnetic endpoint snap" {
    const markers = [_][]const u8{
        "finish:!!(net&&pd.net===net)",
        "finish:!!(net&&t.net===net&&(!dtrace||dtrace.laid.indexOf(t)<0))",
        "if(dl.t.finish&&!dl.clipped){drawEnd();return;}",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, marker) != null);
}

// spec: Web Server - While hand-routing, one faded dashed ratsnest line follows the legal preview endpoint to the closest unresolved same-net pad, trace body, via, or filled-pour point outside the launch island, including when routing resumes from existing copper.
test "PCB editor carries the live route ratsnest to the nearest destination" {
    const markers = [_][]const u8{
        "function drawDests(pi,pd,net,layer,x,y)",
        "function drawRatTargets(tr)",
        "kind:\"track\"",
        "kind:\"via\"",
        "kind:\"fill\"",
        "function drawFillNearest(a,x,y)",
        "function drawTrackTouchesFill(a,t,r)",
        "function drawFillOnStartRoot(a,tr,roots,root)",
        "function drawNearestRatTarget(head,limit)",
        "best={x:copper.x,y:copper.y,mag:true,finish:true}",
        "function drawNearestDest(head)",
        "function paintDrawRatline(ctx,head)",
        "ctx.setLineDash([5,4])",
        "ctx.globalAlpha=0.42;ctx.lineWidth=0.8",
        "var head=dl.legs.length?dl.legs[dl.legs.length-1]",
        "paintDrawRatline(ctx,head)",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, marker) != null);
}

// spec: Web Server - While hand-routing a single trace or coupled differential pair, the scoped autorouter preserves the fixed manual prefix, previews only its proposed remainder as faded dashed tracks and vias, and Enter commits that proposal as one undoable trace completion; Enter never substitutes a manual partial finish when no proposal is ready, while double-click remains the explicit manual finish action.
test "PCB editor previews and accepts an autorouted route remainder" {
    const markers = [_][]const u8{
        "function drawAutoSchedule(now,accept)",
        "payload.resume_points=[]",
        "payload.nets=drawAutoNets(tr)",
        "fetch(\"/api/pcb-route-complete/\"+encodeURIComponent(PCB.name)+subq()",
        "var request=new AbortController();drawAutoRequest=request",
        "if(err&&err.name===\"AbortError\")return",
        "if(a&&(a.state===\"queued\"||a.state===\"loading\")){a.accept=true",
        "tr.auto.tracks=(j.tracks||[]).filter(function(t){return drawAutoOwn(t.net,tr);})",
        "legs.push({net:pr.net",
        "tr.pair.ratTargets=drawRatTargets(tr.pair)",
        "tr.auto.legs.forEach(function(g){payload.resume_points.push(",
        "function paintDrawAutoRoute(ctx)",
        "ctx.globalAlpha=0.34",
        "ctx.setLineDash([6,4])",
        "function drawAutoAccept()",
        "a.tracks.forEach(function(t){t.source=\"autorouter\"",
        "if(ev.key==\"Enter\"&&dtrace){ev.preventDefault();drawAutoAccept();return;}",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, marker) != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, "if(tr.pair)return drawEnd()") == null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, "if(!tr.ratTargets||!tr.ratTargets.length)return drawEnd()") == null);
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

// spec: Web Server - The PCB editor batches attributable saved-layout RF taper migration candidates into at most two whole-board DRC passes, conservatively falls back for unlocated errors, and reuses rejected results while the submitted board state is unchanged
test "PCB editor automatically lowers every local controlled-impedance pad taper" {
    const markers = [_][]const u8{
        "function drawTaperProfile",                                 "Math.abs(span-nominal)<=1e-9",           "pad_neck_width",                                       "kind:\"rf\"",
        "nominal*1.2",                                               "function drawTaperTracks",               "function drawApplyAutomaticTapers",                    "automatic pad tapers added",
        "window.PCBDrawTaperTracks",                                 "function drawTaperPath",                 "track_ids:tracks.map(trackIdEnsure)",                  "window.PCBDrawPadLaunch",
        "function drawRfTaperPlan",                                  "window.PCBDrawRfTaperPlan",              "through-via contributes its real annulus width",       "function drawTrackEndDirection",
        "function rfFallbackRegions",                                "function rfRingFolded",                  "overlapping simple segment",                           "polys=rfFallbackRegions(pts,ws,poly)",
        "function rfCleanSamples",                                   "function rfCompactRing",                 "ws[last]=Math.max(ws[last],w)",                        "clean.pts.length<2",
        "function drawPathPadLaunch",                                "window.PCBDrawPathPadLaunch",            "first box-boundary",                                   "span:f.spanAt(ex,ey,-wy,wx)",
        "function drawPadPortal",                                    "function drawTaperPortalPath",           "function drawRfMissingPortalGroups",                   "drawTaperPortalProbes(paths)",
        "pd.shape===\"roundrect\"||pd.shape===\"oval\"",             "ctx.arcTo(hw,-hh,hw,-hh+rr,rr)",         "acceptedBundles++",                                    "track_ids:(ownerIds||[]).slice()",
        "a.net||\"\"",                                               "planned.push(collar)",                   "PCB.rf_paths||[]).length",                             "drawSamePortalPath",
        "function rfPathBelongsToTrack",                             "p.portal",                               "portal:!!p.portal",                                    "rfPathBelongsToTrack(p,t)",
        "shape===\"rect\"||shape===\"roundrect\"||shape===\"oval\"", "if(path.portal)return",                  "path.track_ids=ownerIds.slice()",                      "if(RO||PCB.analysis_deferred||!curLayout||",
        "if(!RO)setTimeout(drawRfRetrofitSaved,0);",                 "function drawRfRetrofitCached(pending)", "sig:drawRfRetrofitSignature(pending),blocked:blocked", "function drawRfRetrofitBlockGroups(pending,blocks)",
        "drawRfRetrofitCheck(original.concat(proposed))",            "pcb-rf-retrofit-v2:",                    "routeStatMsg(\"confirming \"+clean.length",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, marker) != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, "function drawRfTaperAllowed") == null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, "function drawReplaceLaid") == null);
}

// spec: Web Server - the PCB hand router previews an authored pad neck at its tapered physical width, checks wide/short-pad launches against their exact swept regions, and submits compact handles plus those regions to the synchronous DRC gate
test "PCB hand router gates pad entry and exit at the prospective tapered width" {
    const markers = [_][]const u8{
        "function drawAutomaticTaperPlan",
        "window.PCBDrawAutomaticTaperPlan",
        "function drawProspectiveTaperPlan",
        "dtrace.n===0?dtrace.startPad:null",
        "taperF=drawProspectiveTaperPlan(planF)",
        "drcGateBlocks(planF.tracks,null,taperF.paths)",
        "taperC=drawProspectiveTaperPlan(planC)",
        "drcGateBlocks(planC.tracks,null,taperC.paths)",
        "function drawTaperPathsPadViolation",
        "drawTaperPathOwnsProbe(taper.paths,t)",
        "preview=drawProspectiveTaperPlan(drawRoutePlan(dl.legs)).tracks",
        "Math.max((t.w||dtrace.w)*S,1.2)",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, marker) != null);
}

// spec: placement/power-routing - the hand router steers an unpoured current-rated rail at ordinary fabrication width, then independently exact-DRC-fits each local interval as the same ordinary track capsule it will commit, up to its electrical target with 45-degree tapers from the pad's smaller dimension
test "PCB hand router adaptively widens power copper after steering" {
    const markers = [_][]const u8{
        "adaptive_power_width",
        "function drawNetGeometry",
        "powerTarget:geo.target",
        "function drawAdaptiveClearWidth",
        "for(var i=0;i<11;i++)",
        "function drawAdaptiveExactClearWidth",
        "drawAdaptiveProbeTrack(a,b,layer,net,w)",
        "for(var i=0;i<7;i++)",
        "function drawAdaptiveRefinedClearWidth",
        "function drawAdaptiveIntervalBlocker",
        "baseCache[key]=baseCounts",
        "baseCounts=drcBlockCounts(drcGateRun",
        "function drawAdaptiveRunClearer",
        "function drawAdaptivePowerRun",
        "ss[i-1].w+(ss[i].bend&&ss[i-1].bend?0:2*(ss[i].s-ss[i-1].s))",
        "function drawAdaptivePowerPlan",
        "window.PCBDrawAdaptivePowerPlan",
        "window.PCBDrawAdaptivePowerPlanExact",
        "window.PCBDrawAdaptivePowerGateReady",
        "initial=power?drawAdaptivePowerPlan",
        "drawAdaptivePowerPlan(old,sp,tp,nominal,powerTarget,drawAdaptiveRefinedClearWidth)",
        "power route widened locally up to ",
        // Equal-width collinear stations collapse, and the shaped copper itself
        // is what the gate judges and what the board keeps — no second
        // representation to go stale under the next drag.
        "function drawShapedPush",
        "drawShapedPush(shaped,{x1:a.x,y1:a.y,x2:b.x,y2:b.y,l:layer,w:w,net:net,source:\"human\"})",
        "function drawCommitShaped",
        "trialAfter=rest.concat(power?trial.tracks:old)",
        "trialPaths=power?(PCB.rf_paths||[]):(PCB.rf_paths||[]).concat(trial.paths)",
        "drcGateDiffBlocks(base.tracks||[],base.vias||[],rest.concat(exact.tracks),PCB.vias||[],base.rf_paths||[],trialPaths)",
        "drawCommitShaped(old,shaped);dtrace.laid=shaped.slice()",
        "return {ok:true,changed:true,paths:[],power:true,maxWidth:physical.maxWidth||nominal}",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, marker) != null);
    // Only the controlled-impedance branch publishes a swept overlay.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, pcb_board_js, "Array.prototype.push.apply(PCB.rf_paths,paths)"));
}

// spec: placement/power-routing - an adaptive rail carries its width as ordinary copper: a drawn run commits its shaped tracks with equal-width collinear stations collapsed, an inherited overlay bakes its sample widths onto the tracks it owns before any edit releases it, and a gesture that collapses copper to zero length takes the crumb with it
test "PCB editor keeps adaptive power width on the copper across edits" {
    const markers = [_][]const u8{
        // Bake, don't drop: an overlay whose net has no impedance class is the
        // only record of that rail's width, and nothing regenerates it.
        "function rfPathSpanWidth",
        "function rfPathPower",
        "function rfPathBakeWidth",
        "function rfBakePath",
        "function rfWasIndex",
        "function rfDropForTracks(ts,was)",
        "if(rfPathPower(p))rfBakePath(p,ix)",
        "function rfLoadBake",
        "rfLoadBake(); // saved adaptive overlays",
        "PCB.drc=[];rfLoadBake();drawRoute();drawDrc();",
        // The whole moved set releases its overlays, judged against the drag
        // snapshot's pre-gesture geometry and its pre-gesture path list.
        "function segDragTracks",
        "rfDropForTracks(segDragTracks(sd),sd.snap.tracks)",
        "rfDropForTracks(vd.at.map(function(w){return w.q;}))",
        "drcGateDiffBlocks(sgd.snap.tracks||[],sgd.snap.vias||[],PCB.tracks||[],PCB.vias||[],sgd.snap.rf_paths||[],PCB.rf_paths||[])",
        "drcGateDiffBlocks(vgd.snap.tracks||[],vgd.snap.vias||[],PCB.tracks||[],PCB.vias||[],vgd.snap.rf_paths||[],PCB.rf_paths||[])",
        // Zero-length copper joins nothing, so the gesture that collapsed one
        // takes it away with it.
        "function segCrumbClean",
        "segCrumbClean(sgd);",
        "return trackLength(t)<1e-6;",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, marker) != null);
    // The released blind spots must not come back: a segment drag that dropped
    // only the grabbed track's overlay, and a cleanup that saw only its jogs.
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, "rfDropForTracks([sd.t])") == null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, "function segJogClean") == null);
}

// spec: placement/power-routing - moving adaptive power copper recuts the maximal same-net runs the gesture touched to the clearance they have after the move, growing or shrinking under the exact DRC gate and never below the routing floor
test "PCB editor re-widens adaptive power runs after an edit moves them" {
    const markers = [_][]const u8{
        // The class target and the pen's own routing floor, read without the
        // width selector so saved copper heals whatever the pen is set to.
        "function rewidenTarget",
        "rail=c?+c.adaptive_power_width||0:0",
        "floor=Math.max(+rules.min_width||0,Math.min(target,ordinary))",
        // One unambiguous same-net, same-layer chain: a land, a branch, an arc
        // or another run's copper ends it.
        "function rewidenTrack",
        "t.xm==null&&!rfOwnsTrack(t)",
        "function rewidenGrow",
        "pad=drawEndpointLand(last.net,last.l||0,x,y);if(pad)break;",
        "if(touch.length!==1)break;",
        "if(next.length!==1||claimed[trackIdEnsure(next[0].t)]){joint=+touch[0].w||0;break;}",
        "function rewidenRun(",
        "function rewidenRuns",
        // Recut with the pen's own planner, all-or-nothing behind the exact
        // gate, committed as ordinary copper.
        "function rewidenDeclined",
        "function rewidenPlan",
        "drawAdaptivePowerPlan(r.run,r.startPad||drawJointProfile(r.startJoint,r.target),r.endPad||drawJointProfile(r.endJoint,r.target),r.floor,r.target,drawAdaptiveRefinedClearWidth)",
        "shaped=r.run.map(function(q){return rewidenAtFloor(q,r.floor);});",
        "function rewidenStatus",
        "function adaptiveWidthDrcTracks",
        "function rewidenTry",
        "function rewidenApply",
        "if(RO||!drcGate.ready||drcGate.failed)return 0;",
        "afterVias=baseVias.filter(function(v){return !routeFenceVia(v)||!shaped.some(function(t){return routeFenceHitsTrack(v,t);});});",
        "var blocked=drcGateDiffBlocks(base,baseVias,rest.concat(shaped),afterVias,PCB.rf_paths||[],PCB.rf_paths||[],includeFenceVias);",
        "runs.forEach(function(r){var n=rewidenTry([r],drcRepair);",
        "drawCommitShaped(r.tracks,r.shaped)",
        "window.PCBRewidenPlan",
        "window.PCBRewidenStatus",
        "window.PCBApplyAdaptiveRewiden",
        // Healing rides the gesture's own undo step, scoped to the copper it moved.
        "function rewidenHeal",
        "recordUndo(sgd.snap);rewidenHeal(segDragTracks(sgd));",
        "recordUndo(vgd.snap);rewidenHeal(vgd.at.map(function(w){return w.q;}));",
        "recordUndo(gsnap);rewidenHeal(gct.map(function(o){return o.t;}));",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, marker) != null);
    // Release only — every interval of a recut bisects against the exact engine,
    // so it must stay unreachable from a pointermove: one definition, three
    // gesture releases, and nothing else.
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, pcb_board_js, "rewidenHeal("));
}

// spec: placement/power-routing - the PCB DRC panel offers an undoable repair for every authoritative adaptive power-width finding that loads the exact geometry gate on demand, recuts only failing runs without moving their centre lines, removes generated stitching posts crossed by the wider copper, commits independently clean repairs when another run is constrained, and never expands one finding into more taper-slice findings
test "PCB editor offers a DRC-targeted adaptive width repair" {
    const markers = [_][]const u8{
        // The manual action deliberately stays available for every board with
        // an adaptive class: stored width alone cannot prove a fit is fresh.
        "adaptiveClasses=classes.some(function(c){return +c.adaptive_power_width>0;})",
        "id=\"drc-adaptive-width\"",
        "if(adaptive)adaptive.addEventListener(\"click\",function(){applyAdaptiveRewiden();});",
        // The DRC panel is a valid first entry point: initialize once, share an
        // in-flight load, then resume this same action without another click.
        "var adaptiveRewidenPending=false;",
        "drcGateInit().then(function(ok){adaptiveRewidenPending=false;",
        "if(ok){applyAdaptiveRewiden();return;}",
        "if(drcGate.load)return drcGate.load;",
        // Server findings select the failing copper; below-target but exempt
        // runs never enter the repair plan.
        "var before=snapAll(),n=rewidenApply(seeds,true);",
        "var geo=rewidenTarget(t);if(!geo||!rewidenTrack(t,t.net||\"\",t.l||0))return;",
        "recordUndo(before);PCB.drc=[];",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, marker) != null);
}

// spec: placement/power-routing - two adaptive slices meeting at a bend or at a plain two-way splice with existing copper are emitted at one width, with the 45-degree transition moved onto the adjoining straight, while pad lands, via corners and T-junctions keep their free trunk/branch step
test "PCB adaptive power copper never steps its width on a joint" {
    const markers = [_][]const u8{
        // A direction-changing track boundary is a bend station, and a run
        // terminal spliced onto copper is pinned the same way.
        "function drawAdaptiveBendJoint",
        "return Math.abs(ax*by-ay*bx)>1e-9||ax*bx+ay*by<=0;",
        "if(i&&drawAdaptiveBendJoint(tracks[i-1],t))bends.push(base);",
        "bend:bends.some(function(q){return Math.abs(q-s)<=1e-8;})",
        "if(start&&start.joint)ss[0].bend=true;",
        "if(end&&end.joint)ss[ss.length-1].bend=true;",
        // Two pinned stations sharing one interval level to the narrower of the
        // pair — a zero-distance flank limit run in both directions.
        "ss[i-1].w+(ss[i].bend&&ss[i-1].bend?0:2*(ss[i].s-ss[i-1].s))",
        "ss[i+1].w+(ss[i].bend&&ss[i+1].bend?0:2*(ss[i+1].s-ss[i].s))",
        // An interval touching a pinned station is emitted AT that width; the
        // far-side interval still takes the max and its round cap covers the
        // shared station.
        "w=a.bend&&b.bend?Math.min(a.w,b.w):(a.bend?a.w:(b.bend?b.w:Math.max(a.w,b.w)));",
        // The neighbour's width becomes an ordinary launch profile: held at the
        // joint, then the standard 45-degree flank to or down from target.
        "function drawJointProfile",
        "return {kind:\"joint\",joint:true,width:width,land:0,taper:flank,step:Math.max(.005,flank/4)};",
        "sr=startPad.joint?startPad:drawTaperProfile(",
        "er=endPad.joint?endPad:drawTaperProfile(",
        // Run boundaries on both surfaces: the recut walk's non-land stops, and
        // a fresh gesture that starts or finishes on existing copper.
        "if(next.length!==1||claimed[trackIdEnsure(next[0].t)]){joint=+touch[0].w||0;break;}",
        "startJoint:behind.joint,endJoint:ahead.joint",
        "r.startPad||drawJointProfile(r.startJoint,r.target)",
        "r.endPad||drawJointProfile(r.endJoint,r.target)",
        "function drawJointNeighbourWidth",
        "if(hits.length!==1)return 0;",
        "if(power&&!sp)sp=drawJointProfile(drawJointNeighbourWidth(first.net,first.l||0,first.x1,first.y1,old),powerTarget);",
        "if(power&&!tp)tp=drawJointProfile(drawJointNeighbourWidth(dtrace.net,dtrace.l,dtrace.lx,dtrace.ly,old),powerTarget);",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, marker) != null);
    // A T-junction and a via-covered corner stay free: the via test is what
    // separates a splice from a barrel, and a land never becomes a joint.
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, "if((PCB.vias||[]).some(function(v){return (v.net||\"\")===key&&Math.hypot(v.x-x,v.y-y)<=DRAW_JOINT_SNAP;}))return 0;") != null);
    // The un-pinned emission must not survive anywhere in the adaptive planner.
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, "var a=ss[i-1],b=ss[i],w=Math.max(a.w,b.w);") == null);
}

// spec: Web Server - A hand-routed RF launch keeps its generated portal collar inside the source pad, retries a DRC-blocked wide-land taper with progressively shorter flares, and finishes with the independently DRC-confirmed uniform trace when no automatic taper fits
test "PCB hand router fits automatic tapers to DRC" {
    const markers = [_][]const u8{
        "function drawCompactTaperProfile",
        "scales=[1,.75,.5,.25,.125,.0625]",
        "automatic pad taper omitted — no DRC-clean flare fits",
        "compact DRC-safe pad taper added",
        "ax=p.a.x-ox*r",
        "if(!drcGate.ready||drcGate.failed)return {ok:true,changed:false,paths:[],omitted:true",
        "drcGateDiffBlocks(base.tracks||[],base.vias||[],board,PCB.vias||[])",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, marker) != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, "automatic pad taper would violate DRC") == null);
}

// spec: Web Server - A controlled-impedance launch approaching a pad corner substitutes the pad's narrow dimension for a degenerate local chord, retaining a visible wide-land taper while a genuinely narrow land still receives its physical-width taper
test "PCB RF taper rejects degenerate corner chords" {
    const markers = [_][]const u8{
        "var padWidth=Math.min(+pad.pd.w||0,+pad.pd.h||0)",
        "if(padWidth>0)span=Math.max(span,padWidth)",
        "a 0.190 mm line pinched to 0.028 mm",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, marker) != null);
}

// spec: Web Server - Generated RF fence vias are disposable while hand-routing: previews, exact DRC gates, and scoped autocomplete ignore them, committed copper removes only intersecting posts, and perimeter/ordinary vias remain obstacles
test "PCB hand router routes through generated RF fence vias and culls the crossed posts" {
    const markers = [_][]const u8{
        "function routeFenceVia(v){return !!(v&&v.f&&v.f!==\"@perimeter\");}",
        "if(routeFenceVia(v)||sameNet(v.net,net))continue",
        "function routeFenceCull(tracks,vias,paths)",
        "dropped=routeFenceCull(newTracks,newVias,tapered.paths)",
        "dropped=routeFenceCull(newTracks,newVias,(tapered.paths||[]).concat(a.rf_paths))",
        "payload.vias=(payload.vias||[]).filter(function(v){return !routeFenceVia(v);})",
        "ignore_rf_fence_vias:includeFenceVias?false:true",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, marker) != null);
    // Both the segment and via fallback gates skip disposable posts.
    try std.testing.expect(std.mem.count(u8, pcb_board_js, "if(routeFenceVia(v)||sameNet(v.net,net))continue") >= 2);
    // The shared marshaler strips only RF-generated posts on route-gate calls;
    // its ordinary worker/server-parity use still checks the complete board.
    try std.testing.expect(std.mem.indexOf(u8, drc_marshal_js, "if (live.ignore_rf_fence_vias)") != null);
    try std.testing.expect(std.mem.indexOf(u8, drc_marshal_js, "!v.f || v.f === \"@perimeter\"") != null);
}

// spec: Web Server - Escape cancels an active manual route even when its final route-wide DRC check rejects finishing it, restoring the route-start copper and exiting Draw instead of retrying the blocked finish
test "PCB editor Escape cancels a DRC-blocked manual route" {
    const markers = [_][]const u8{
        "function drawCancel()",                          "restoreCopperSnap(snap)",
        "if(dtrace)drawCancel();else drawModeSet(false)", "routeStatMsg(\"routing cancelled\")",
        "function drawAutoReset()",                       "Cancel active trace and exit Draw",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, marker) != null);
}

test "PCB editor DRC lowers taper polygons to private probe tracks" {
    for ([_][]const u8{ "var physicalTracks", "window.PCBRfOwnsTrack", "physicalTracks.push", "Math.max(+a[2], +b[2])", "if (live.rf_paths !== undefined) return false" }) |marker|
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

test "Assembly review publishes semantic state at the completed paint seam" {
    const markers = [_][]const u8{
        "window.PCBReviewPainted=function()",
        "reviewPainted={revision:++reviewPaintRevision,side:reviewSide,rotation:reviewRotation",
        "reviewPainted=null,reviewPaintDirty=true",
        "if(!PHYSICAL_REVIEW||!reviewPaintDirty)return",
        "layers:Object.assign({},reviewPainted.layers)",
        "paintFlash(ctx);\n reviewPaintPublish();",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, marker) != null);
    const scene_paint = std.mem.indexOf(u8, pcb_board_js, "function scenePaint()") orelse return error.ScenePaintMissing;
    const publish = std.mem.indexOfPos(u8, pcb_board_js, scene_paint, "reviewPaintPublish();") orelse return error.ReviewPaintReadinessMissing;
    const paint_tail = std.mem.indexOfPos(u8, pcb_board_js, scene_paint, "paintFlash(ctx);") orelse return error.ScenePaintTailMissing;
    try std.testing.expect(paint_tail < publish);
}

// spec: Web Server - Before opt-in CAM Review supplies its exact profile, Assembly preserves the saved outline's native arcs instead of joining their endpoints as chamfers
// spec: Web Server - CAM Review paints parsed Gerber/Excellon operations in WebGPU instead of rebuilding fabrication artwork from browser fonts and placement objects
// spec: Web Server - Assembly layer controls independently toggle face copper, every physical inner copper layer, solder mask, paste, silkscreen, drills, board outline, and component overlays
// spec: Web Server - Assembly paints the closest enabled copper film from the viewed face bright gold and every enabled film behind it dim gold
test "Assembly review resolves ordered CAM policy with independent layer visibility" {
    const Check = struct { bytes: []const u8, marker: []const u8 };
    const checks = [_]Check{
        .{ .bytes = pcb_board_js, .marker = "var CAM_REVIEW=false,camReviewRequested=false,camLoadStarted=false" },
        .{ .bytes = pcb_board_js, .marker = "function camLayerVisible" },
        .{ .bytes = pcb_gpu_js, .marker = "function camOpDark" },
        .{ .bytes = pcb_gpu_js, .marker = "if (L.negative) dark = !dark" },
        .{ .bytes = pcb_board_js, .marker = "if(camVisible(\"components\")){paintParts" },
        .{ .bytes = pcb_board_js, .marker = "netlisp-pcb-cam-visibility" },
        .{ .bytes = pcb_board_js, .marker = "PCB.cam.profile" },
        .{ .bytes = pcb_board_js, .marker = "function physicalReviewOutlinePoints()" },
        .{ .bytes = pcb_board_js, .marker = "this read-only page omits the sketch compiler" },
        .{ .bytes = pcb_board_js, .marker = "physical=physicalReviewOutlinePoints()" },
        .{ .bytes = assembly_debug_js, .marker = "function applyCamLayers" },
        .{ .bytes = assembly_debug_js, .marker = "data-cam-layer" },
        .{ .bytes = assembly_debug_js, .marker = "assembly-cam-layers:" },
        .{ .bytes = assembly_debug_js, .marker = "populateInnerCopperLayers" },
        .{ .bytes = assembly_debug_js, .marker = "copper-inner-" },
        .{ .bytes = assembly_debug_js, .marker = "frame.contentWindow.PCBReviewInnerLayers" },
        .{ .bytes = pcb_board_js, .marker = "window.PCBReviewInnerLayers=reviewInnerLayers" },
        .{ .bytes = pcb_board_js, .marker = "innerLayers:reviewInnerLayers()" },
        .{ .bytes = pcb_board_js, .marker = "hasOwnProperty.call(camVisibility,L.id)" },
        .{ .bytes = pcb_board_js, .marker = "function camCopperPaintOrder" },
        .{ .bytes = pcb_board_js, .marker = "if(activeLayer===0)shown.reverse()" },
        .{ .bytes = pcb_board_js, .marker = "i===cu.length-1?1:0.24" },
    };
    for (checks) |check| try std.testing.expect(std.mem.indexOf(u8, check.bytes, check.marker) != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, "function paintCamBoard") == null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, "function camDrawOp") == null);
    const draw_board = std.mem.indexOf(u8, pcb_board_js, "function drawBoardRect(tmp)") orelse return error.TestUnexpectedResult;
    const physical_return = std.mem.indexOfPos(u8, pcb_board_js, draw_board, "if(PHYSICAL_REVIEW)return;") orelse return error.TestUnexpectedResult;
    const authoring_outline = std.mem.indexOfPos(u8, pcb_board_js, draw_board, "var linePreview=") orelse return error.TestUnexpectedResult;
    try std.testing.expect(physical_return < authoring_outline);
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

// spec: Web Server - the PCB 3D viewer places its visible axis origin at the PCB outline bounding-box centre in X/Y and the board thickness mid-plane in Z, and its camera orbits that same datum
test "PCB 3D viewer centers its visible origin on the board" {
    const markers = [_][]const u8{
        "center.z = -thickness / 2",
        "axes.position.set(center.x, center.y, center.z)",
        "controls.target.set(center.x, center.y, center.z)",
        "new THREE.Vector3(center.x, center.y, center.z)",
        "obj.material.depthTest = false; obj.material.depthWrite = false",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_3d_viewer_js, marker) != null);
}

// spec: Web Server - the PCB 3D viewer paints its base board before component previews finish, parses vendor STEP models outside the UI thread, renders only after scene or camera changes, and lowers raster density while interacting on a software WebGL renderer
test "PCB 3D STEP previews parse in a worker" {
    const worker_markers = [_][]const u8{
        "importScripts(\"/static/occt-import-js.js\")",
        "occt.ReadStepFile",
        "self.postMessage({ id: id, result: result })",
    };
    for (worker_markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_step_worker_js, marker) != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_3d_viewer_js, "ReadStepFile") == null);
}

test "PCB 3D base preview remains interactive while models stream" {
    const viewer_markers = [_][]const u8{
        "new Worker(\"/static/pcb_step_worker.js\")",
        "postMessage({ id: id, buffer: buffer }, [buffer])",
        "function hasSoftwareWebGL()",
        "idlePixelRatio = softwareRenderer ? Math.min(nativePixelRatio, 1) : nativePixelRatio",
        "interactivePixelRatio = softwareRenderer ? Math.min(idlePixelRatio, 0.35) : idlePixelRatio",
        "controls.addEventListener(\"change\", requestRender)",
        "modelProgress: modelProgress",
        "cameraState: cameraState",
        "setStatus(null)",
    };
    for (viewer_markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_3d_viewer_js, marker) != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_3d_viewer_js, "idlePixelRatio = softwareRenderer ? 0.5") == null);
}

test "generated auxiliary STEP bodies remain faceted B-reps rather than presentation tessellation" {
    const writer_markers = [_][]const u8{
        "function splitComponents(body)",
        "function orientClosedComponent(points, triangles)",
        "function chunkItems(items, faceBudget)",
        "productFaceBudget = +faceBudget > 0 ? +faceBudget : 20000",
        "chunkItems(closedItems, productFaceBudget)",
        "CARTESIAN_POINT('',",
        "POLY_LOOP('',(#",
        "FACE_OUTER_BOUND('',#",
        "PLANE('',#",
        "FACE_SURFACE('',(#",
        "CLOSED_SHELL",
        "FACETED_BREP(",
        "FACETED_BREP_SHAPE_REPRESENTATION",
        "MECHANICAL_DESIGN_GEOMETRIC_PRESENTATION_REPRESENTATION",
        "SI_UNIT(.MILLI.,.METRE.)",
    };
    for (writer_markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_step_export_js, marker) != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_step_export_js, "ADVANCED_FACE('',(#") == null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_step_export_js, "OPEN_SHELL(") == null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_step_export_js, "SHELL_BASED_SURFACE_MODEL(") == null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_step_export_js, "MANIFOLD_SURFACE_SHAPE_REPRESENTATION(") == null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_step_export_js, "=SHAPE_REPRESENTATION(") == null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_step_export_js, "TRIANGULATED_FACE(") == null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_step_export_js, "TESSELLATED_SHAPE_REPRESENTATION(") == null);
}

// spec: Web Server - the PCB 3D viewer asks the server for a self-contained millimetre-based AP242 assembly: each unique library STEP entity graph is embedded once without tessellation and reused through rigid component occurrences, the board outline/thickness/mechanical holes become one green analytic manifold B-rep rather than a faceted mesh, native board-outline arcs become circular edge curves and cylindrical side faces rather than chorded corner facets, and an unchecked heatsink is omitted from the assembly
test "PCB 3D viewer sends an analytic board recipe and exact component occurrences to the server" {
    const viewer_markers = [_][]const u8{
        "function collectGeneratedStepBodies()",
        "function exactStepBoard()",
        "function outlineGeometry()",
        "window.PCBOutlineGeometry",
        "arc.p1.x",
        "function exactStepInstances()",
        "function collectStepMeshes(group, name)",
        "obj.userData.pcb3dKind === \"surfaces\"",
        "outline: pts.map(function (point) { return [+point[0], -(+point[1])]; })",
        "arcs: arcs.map(function (arc)",
        "holes: holes",
        "thickness: boardThickness()",
        "board: exactStepBoard()",
        "if (layerVisible.heatsink)",
        "partGroups.forEach",
        "heatsinkGroup.children",
        "new THREE.Matrix4().multiplyMatrices(mount.matrixWorld, local.matrix)",
        "matrix: Array.prototype.slice.call(world.elements)",
        "window.PCBStepExport.prepareBodies(out)",
        "function stepFabricationId()",
        "text.fabrication_id",
        "window.PCBStepExport.fileName(DATA.name, stepFabricationId())",
        "fetch(\"/api/pcb-step/\"",
        "downloadBlob(blob, stepFileName())",
    };
    for (viewer_markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_3d_viewer_js, marker) != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, "window.PCBOutlineGeometry=function(o)") != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_3d_viewer_js, "collectStepMeshes(boardGroup, \"PCB\")") == null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_3d_viewer_js, "stepArtwork") == null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_3d_viewer_js, "window.PCBStepExport.build(DATA.name") == null);
}

// spec: Web Server - the PCB STEP download name ends in `_ID_XXXXXXXX.step` using the exact eight-hex fabrication identity printed on that PCB
test "PCB STEP filename carries the printed fabrication identity" {
    const markers = [_][]const u8{
        "function fileName(name, fabricationId)",
        "replace(/^ID[\\s_-]*/i, \"\")",
        "if (/^[0-9a-f]{8}$/i.test(id)) base += \"_ID_\" + id.toUpperCase()",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_step_export_js, marker) != null);
}

// spec: Web Server - the Full archive control runs the ordinary fab-readiness confirmation flow, posts the same analytic full-board STEP recipe as the 3D tab, and downloads the complete design archive
test "PCB full archive reuses release confirmation and exact STEP data" {
    const board_markers = [_][]const u8{
        "fabExportKind=\"archive\"",
        "fabEnsure3D()",
        "window.PCB3D.archivePayload",
        "\"/api/design-archive/\"",
        "↧ Full archive",
    };
    for (board_markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, marker) != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_3d_viewer_js, "archivePayload: function () { return built ? stepPayload() : null; }") != null);
}

// spec: Web Server - a failed Full archive download identifies the archive and displays the server's actual rejection reason
test "PCB full archive reports the server failure instead of a generic fab alert" {
    const markers = [_][]const u8{
        "if(!r.ok)return r.text()",
        "throw new Error(body||",
        "Complete design archive",
        "err.message",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, marker) != null);
}

// spec: Web Server - the PCB 3D viewer composites each face's outer copper, soldermask, and silkscreen—including generated sub-circuit, test-point, and pin-1 artwork—into one non-overlapping visible canvas cap; the regular STEP export omits that raster artwork instead of turning it into selectable geometry, and only mechanical drills strictly larger than 1 mm are cut through the board
// spec: Web Server - exposed RF copper on both board faces uses the same swept taper polygons in Assembly and the PCB 3D viewer
test "PCB 3D viewer textures both manufactured faces and cuts drills" {
    const Check = struct { bytes: []const u8, marker: []const u8 };
    const checks = [_]Check{
        .{ .bytes = pcb_3d_surface_js, .marker = "function drawCopper(ctx, data, side)" },
        .{ .bytes = pcb_board_js, .marker = "window.PCBRfSurfacePolys=function(data)" },
        .{ .bytes = pcb_3d_surface_js, .marker = "function drawRfPaths(ctx, data, side)" },
        .{ .bytes = pcb_3d_surface_js, .marker = "window.PCBRfSurfacePolys(data)" },
        .{ .bytes = pcb_3d_surface_js, .marker = "drawRfPaths(ctx, data, side)" },
        .{ .bytes = pcb_3d_surface_js, .marker = "function maskCanvas(data, pts, b, width, height, scale, side)" },
        .{ .bytes = pcb_3d_surface_js, .marker = "function drawFootprintSilk(ctx, data, side)" },
        .{ .bytes = pcb_board_js, .marker = "window.PCBGeneratedSilk=function(){return boardSilkCurrentGeom();}" },
        .{ .bytes = pcb_3d_surface_js, .marker = "function drawGeneratedSilk(ctx, side)" },
        .{ .bytes = pcb_3d_surface_js, .marker = "(all.subs || []).forEach" },
        .{ .bytes = pcb_3d_surface_js, .marker = "(all.tps || []).forEach" },
        .{ .bytes = pcb_3d_surface_js, .marker = "(all.pin1 || []).forEach" },
        .{ .bytes = pcb_3d_surface_js, .marker = "new THREE.CanvasTexture(cv)" },
        .{ .bytes = pcb_3d_surface_js, .marker = "function collectHoles(data, pts)" },
        .{ .bytes = pcb_3d_surface_js, .marker = "MECHANICAL_HOLE_MIN_DIAMETER = 1.0" },
        .{ .bytes = pcb_3d_surface_js, .marker = "drill > MECHANICAL_HOLE_MIN_DIAMETER" },
        .{ .bytes = pcb_3d_surface_js, .marker = "pad.slot_half" },
        .{ .bytes = pcb_3d_surface_js, .marker = "ROUND_HOLE_SEGMENTS = 16" },
        .{ .bytes = pcb_3d_surface_js, .marker = "shape.holes.push(path)" },
        .{ .bytes = pcb_3d_viewer_js, .marker = "surface.collectHoles(DATA, pts)" },
        .{ .bytes = pcb_3d_viewer_js, .marker = "surface.makeTexture(THREE, DATA, pts, side)" },
        .{ .bytes = pcb_3d_viewer_js, .marker = "DATA.zone_fills, DATA.rf_paths" },
        .{ .bytes = pcb_3d_viewer_js, .marker = "new THREE.ShapeGeometry(shape)" },
        .{ .bytes = pcb_3d_viewer_js, .marker = "new THREE.MeshBasicMaterial({ color: surface.maskColor, visible: false })" },
        .{ .bytes = pcb_3d_viewer_js, .marker = "boardEdgeMat = new THREE.MeshStandardMaterial({ color: surface.maskColor" },
        .{ .bytes = pcb_3d_viewer_js, .marker = "addBoardFace(shape, pts, \"top\", 0)" },
        .{ .bytes = pcb_3d_viewer_js, .marker = "addBoardFace(shape, pts, \"bottom\", -thickness)" },
        .{ .bytes = pcb_3d_viewer_js, .marker = "pcb3d-t-surface" },
    };
    for (checks) |check| try std.testing.expect(std.mem.indexOf(u8, check.bytes, check.marker) != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_3d_viewer_js, "Fusion bundle") == null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_3d_viewer_js, "makeDecalImage") == null);
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

// spec: Web Server - Design Settings exposes whole-layer copper assignments with add, edit, delete, validated save, and read-only states
test "PCB settings edit whole-layer copper assignments" {
    const markers = [_][]const u8{
        "Whole-layer copper", "Add whole-layer pour", "ds-plane-layer",
        "ds-plane-net",       "ds-plane-delete",      "/api/stackup-planes/",
        "Save plane changes", "planes:vals",          "This layout is read-only.",
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

// The timeline transport must be usable as soon as a route finishes. A smooth
// page scroll keeps every control in motion for hundreds of milliseconds, so
// browsers (and assistive automation) correctly defer the first click until
// it settles. Reveal the review synchronously instead.
test "route review controls are stable immediately after loading a timeline" {
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, route_review_js, "app.scrollIntoView({behavior:\"auto\",block:\"start\"})"));
    try std.testing.expect(std.mem.indexOf(u8, route_review_js, "app.scrollIntoView({behavior:\"smooth\"") == null);
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
        "ctx.clip()", // the heat wash follows the exact authored board polygon
        "g.active", // rounded-off mesh cells stay transparent to the viewer
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

// Keep both entry points tied to one cleanup path, and keep the older embedded
// viewer behavior as the fallback when the full Find dock is absent.
test "PCB board find clears its focus and accepts pin-to-net navigation" {
    const markers = [_][]const u8{
        "function findFocusClear()",
        "function findClose(){if(!findOpen)return;var prev=findPrev;findFocusClear();",
        "findClear.addEventListener(\"click\",function(){findFocusClear();",
        "window.PCBFindNet=function(net)",
        "findInput.value=\"net:\"+net",
        "if(window.PCBFindNet)window.PCBFindNet(nn);else selNet(nn)",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, marker) != null);
}

// Keep the keystroke path proportional to search candidates: copper summaries
// are presentation data, and belong only on the capped rows being rendered.
test "PCB board find defers whole-board net summaries until after matching" {
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, "findCandidate(\"net\",n.name,\"\",") != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, "findNetDetails(shown)") != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, "stats[key]={row:r") != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, "findCandidate(\"net\",n.name,findNetInfo(") == null);
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

// Client half of the Assembly opt-in CAM contract tested with the shell and
// server output in assembly_debug.zig and pcb_layout_page.zig.
test "Assembly board loads exact CAM only on explicit review request" {
    const markers = [_][]const u8{
        "var CAM_REVIEW=false,camReviewRequested=false,camLoadStarted=false",
        "function camReviewSet(enabled)",
        "window.PCBReviewCamMode=camReviewSet",
        "if(msg.type===\"netlisp-pcb-cam-mode\")",
        "function loadCamReview()",
        "if(!PHYSICAL_REVIEW||CAM_REVIEW||!camReviewRequested)return",
        "if(!camReviewRequested)return",
        "fetch(PCB.cam_url)",
        "PCB.cam=cam;camLoadStarted=false;if(camReviewRequested)camReviewUse()",
        "camReviewPost(\"semantic\")",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, marker) != null);
    // There is exactly one call site: camReviewSet(true), reached from the
    // explicit parent message. A second call here previously eager-loaded CAM
    // at startup and raced the shell's button state.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, pcb_board_js, "loadCamReview();"));
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, "loadCamReview();dragCacheDrop()") == null);
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
    try std.testing.expect(std.mem.indexOf(u8, js, "PCBGpu.frame(vb,camGpu?gpuCamState():gpuState())") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "function gpuLive()") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "PCBGpu.rebuildCopper()") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "PCBGpu.rebuildParts()") != null);
    // The overscan pixel buffer stands down: a GPU pan is a uniform write.
    try std.testing.expect(std.mem.indexOf(u8, js, "if(gpuOn)return false;") != null);
    // The status-bar chip tracks the LIVE renderer state, device loss included.
    try std.testing.expect(std.mem.indexOf(u8, js, "function gpuStatusSync()") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "getElementById(\"st-gpu\")") != null);
}

// spec: Web Server - Assembly opens on its compact read-only semantic board and requests no Gerber/Excellon payload until the operator enables CAM Review
// spec: Web Server - A settled CAM Review rerasterizes retained generated Gerber/Excellon operations into a camera-matched two-samples-per-axis WebGPU film, while only the short pan/zoom gesture window samples a full-board preview and its trailing paint restores inspection quality; Canvas2D remains only as the transparent component/interaction overlay and never interprets CAM operations
// spec: Web Server - CAM Review decomposes self-crossing Gerber region contours into simple faces selected by the Gerber non-zero winding rule before triangulation
// spec: Web Server - Assembly requires WebGPU for generated Gerber/Excellon artwork; an unavailable adapter, initialization/render failure, device loss, or Assembly ?gpu=0 displays a blocking requirement message instead of invoking a Canvas manufacturing renderer
// spec: Web Server - An opposite-face heatsink is retained in the WebGPU CAM command stream behind the opaque board instead of forcing a Canvas CAM fallback
test "Assembly requires zoom-matched WebGPU CAM artwork and keeps Canvas as an overlay" {
    const markers = [_]struct { haystack: []const u8, marker: []const u8 }{
        .{ .haystack = pcb_gpu_js, .marker = "rebuildCam: rebuildCam" },
        .{ .haystack = pcb_gpu_js, .marker = "function camBuild()" },
        .{ .haystack = pcb_gpu_js, .marker = "window.PCBRegionTriangles(raw)" },
        .{ .haystack = pcb_gpu_js, .marker = "@fragment fn fsStencilArc" },
        .{ .haystack = pcb_gpu_js, .marker = "function camQualityBoundsFor(vb)" },
        .{ .haystack = pcb_gpu_js, .marker = "scale = Math.min(3, limit / cvs.width, limit / cvs.height)" },
        .{ .haystack = pcb_gpu_js, .marker = "function camWarmCoarse(base, layers, sceneKey, rearHeatsink)" },
        .{ .haystack = pcb_gpu_js, .marker = "if (cst.gesture)" },
        .{ .haystack = pcb_earcut_js, .marker = "window.PCBEarcut=Ua" },
        .{ .haystack = pcb_region_js, .marker = "window.PCBRegionTriangles = triangulate" },
        .{ .haystack = pcb_region_js, .marker = "if (!winding(ring, sample)) continue" },
        .{ .haystack = pcb_board_js, .marker = "function gpuCamLive()" },
        .{ .haystack = pcb_board_js, .marker = "function gpuCamState()" },
        .{ .haystack = pcb_gpu_js, .marker = "camGeo.source !== O.PCB.cam" },
        .{ .haystack = pcb_board_js, .marker = "var ASSEMBLY_WEBGPU_REQUIRED=PHYSICAL_REVIEW&&!!(PCB.cam_url||camPayloadReady())" },
        .{ .haystack = pcb_board_js, .marker = "function assemblyGpuFail(detail)" },
        .{ .haystack = pcb_board_js, .marker = "Assembly requires WebGPU" },
        .{ .haystack = pcb_layout_css, .marker = ".pcb-webgpu-required" },
        .{ .haystack = pcb_gpu_js, .marker = "function camQualityEnsure()" },
        .{ .haystack = pcb_gpu_js, .marker = "mode: \"inspection\"" },
        .{ .haystack = pcb_gpu_js, .marker = "camEncodeScene(p, base, layers, rearHeatsink)" },
    };
    for (markers) |entry| try std.testing.expect(std.mem.indexOf(u8, entry.haystack, entry.marker) != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, "function paintCamBoard") == null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, "function camLayerBitmap") == null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, "gesture:Date.now()<vbQuiet") != null);
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

// spec: Web Server - Swept variable-width RF paths remain on WebGPU as exact triangulated stencil unions, while their hidden centreline tracks are omitted from the GPU copper stream and a hidden copper layer cannot leak its taper through a visible layer's stencil cover
test "PCB WebGPU renderer retains exact swept RF copper" {
    const gpu_markers = [_][]const u8{
        "ST_UNION",
        "pipeUnion",
        "window.PCBRegionTriangles(ring)",
        "if (O.rfOwnsTrack && O.rfOwnsTrack(raw[i])) continue;",
        "rfPaths:rfPathGeom,rfOwnsTrack:rfOwnsTrack",
    };
    for (gpu_markers) |marker| {
        const haystack = if (std.mem.indexOf(u8, marker, "rfPaths:") != null) pcb_board_js else pcb_gpu_js;
        try std.testing.expect(std.mem.indexOf(u8, haystack, marker) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, "&&!(PCB.rf_paths||[]).length") == null);

    // A cover draw both paints and clears the union stencil. At zero layer
    // alpha it must still reach the stencil pass: fragment discard would leave
    // the hidden layer's taper bits for the next visible layer's cover to paint.
    const cover_start = std.mem.indexOf(u8, pcb_gpu_js, "@fragment fn fsCover").?;
    const cover_end = std.mem.indexOfPos(u8, pcb_gpu_js, cover_start, "\"}\",").?;
    const cover_shader = pcb_gpu_js[cover_start..cover_end];
    try std.testing.expect(std.mem.indexOf(u8, cover_shader, "discard") == null);
}

// spec: Web Server - The deterministic PCB-editor zoom gate measures fit-to-8×-to-fit paints in both directions, covers the DPR-2 Canvas fallback, asserts an RF-heavy Barracuda workload stays on WebGPU, and is required metadata on every deployable release candidate
test "PCB editor zoom gate covers both renderers and certifies release candidates" {
    const board_markers = [_][]const u8{
        "FBENCH_ZOOM",
        "if(FBENCH_ZOOM){",
        "profile:FBENCH_ZOOM?\"zoom\"",
        "rf_paths:(PCB.rf_paths||[]).length",
        "WebGPU did not become active",
    };
    for (board_markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, marker) != null);
    // scripts/ui_browser_perf/manifest.test.js complements this asset-level
    // test by checking the runner budgets and the prepare/deploy marker chain.
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
// spec: Web Server - The opt-in PCB frame benchmark waits for the page's deferred DRC, RF retrofit and pour round-trips before measuring, so the repaint each answer triggers is never recorded as a camera frame
test "PCB frame benchmark carries human-readable dwell points outside movement phases" {
    const markers = [_][]const u8{
        "dwell(\"fit\",300)",
        "dwell(\"max_zoom\",550)",
        "dwell(\"seek\",250)",
        "dwell(\"turn_\"+(n+1),350)",
        "if(ent.wait)setTimeout",
        "physical_review:PHYSICAL_REVIEW,cam_review:!!CAM_REVIEW",
        "ZN=(FBENCH_QUICK||FBENCH_ZOOM)?10:60,PN=FBENCH_QUICK?30:120",
        "var dx=0.6*VBW/(FBENCH_QUICK?120:PN)",
        "function fbRunWhenReady()",
        "if(!GPU_REQ||gpuOn){fbRun();return;}",
        "else if(CAM_REVIEW&&window.__fbenchCamReadyMs>0){fbRun();return;}",
        "window.__fbenchCamReadyMs=+performance.now().toFixed(2)",
        "\"CAM payload did not load within 240 seconds\"",
        "setTimeout(fbRunWhenReady,1000)",
        // The editable page's deferred round-trips — the pour refill, the
        // `?derived=1` payload, the authoritative DRC and the RF retrofit
        // check — each repaint the board when they answer, and they CHAIN, so
        // the benchmark waits for a quiet interval rather than for one of them.
        // Without the wait it recorded whichever repaint landed mid-program as
        // a camera frame, and which runs saw that depended on how fast the
        // server answered.
        "var drcFlight=0,drcDone=0;",
        "function drcFlightBegin(){drcFlight++;}",
        "function drcFlightEnd(){if(drcFlight>0)drcFlight--;drcDone++;}",
        "var quiet=RO||(drcDone>0&&drcFlight===0)",
        "var deferredSettled=quiet&&(t-quietSince>=fb_quiet_ms)",
        "the page's deferred server work did not settle within 240 seconds",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, marker) != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, pcb_board_js, "window.__fbenchCamReadyMs=+performance.now().toFixed(2)"));
    // One begin per repainting round-trip (DRC, RF retrofit, pour refill), and
    // an end on EVERY terminal branch of each — a begin whose end one path
    // misses hangs every benchmark run on this page for the full 240 s
    // deadline, so the pairing is pinned per call site rather than by a count.
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, pcb_board_js, "drcFlightBegin();"));
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, ".then(drcFlightEnd,drcFlightEnd);") != null);
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, "function(r){drcFlightEnd();if(!r.ok)throw 0;return r.json();},function(e){drcFlightEnd();throw e;}") != null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, pcb_board_js, "poursInFlight=false;drcFlightEnd();"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, pcb_board_js, ".then(drcFlightEnd,drcFlightEnd);"));
    const scene_paint = std.mem.indexOf(u8, pcb_board_js, "function scenePaint()") orelse return error.ScenePaintMissing;
    const cam_painted = std.mem.indexOf(u8, pcb_board_js, "window.__fbenchCamReadyMs=+performance.now().toFixed(2)") orelse return error.CamPaintReadinessMissing;
    try std.testing.expect(scene_paint < cam_painted);
    // The physical CAM surface keeps the cheaper direct repaint path; the
    // browser A/B gate showed that rebuilding its 2.56x buffer regresses p95.
    try std.testing.expect(std.mem.indexOf(u8, pcb_board_js, "if(PHYSICAL_REVIEW)return false;       // measured A/B") != null);
}
