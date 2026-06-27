const std = @import("std");
const httpz = @import("httpz");

const serve_root = @import("../serve.zig");
const Handler = serve_root.Handler;

const account_page_js = @embedFile("assets/account_page.js");
const account_page_css = @embedFile("assets/account_page.css");
const pdf_viewer_js = @embedFile("assets/pdf_viewer.js");
const pdf_viewer_css = @embedFile("assets/pdf_viewer.css");
const library_js = @embedFile("assets/library.js");
// Shared footprint-drawing engine — one renderer for the library preview, the
// schematic sidebar, and the PCB-layout page (draws from /api/footprint JSON).
const footprint_svg_js = @embedFile("assets/footprint_svg.js");
const pcb_board_js = @embedFile("assets/pcb_board.js");
const auth_login_js = @embedFile("assets/auth_login.js");
const auth_setup_js = @embedFile("assets/auth_setup.js");
const auth_invite_js = @embedFile("assets/auth_invite.js");
const review_notes_js = @embedFile("assets/review_notes.js");
// KiCad-style sheet editor (prototype) client — renders the scene-graph JSON
// onto a pan/zoom canvas with section-as-sheet navigation + edit hotkeys.
const editor_js = @embedFile("assets/editor.js");

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
const pcb_3d_viewer_js = @embedFile("assets/pcb_3d_viewer.js");

// Schematic page assets — pub-imported from render_html so we don't
// re-`@embedFile` the underlying byte slices (the JS lives under
// `serve/assets/` already, but the CSS is the concatenation of
// `assets/schematic_inline.css` and the diagram engine's `DIAGRAM_CSS`).
const render_html = @import("../render_html.zig");
const schematic_viewer_js = render_html.SCHEMATIC_VIEWER_JS;
const schematic_css = render_html.SCHEMATIC_CSS;

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
const REGISTRY = [_]Asset{
    .{ .name = "account_page.js", .body = account_page_js, .content_type = .JS },
    .{ .name = "account_page.css", .body = account_page_css, .content_type = .CSS },
    .{ .name = "pdf_viewer.js", .body = pdf_viewer_js, .content_type = .JS },
    .{ .name = "pdf_viewer.css", .body = pdf_viewer_css, .content_type = .CSS },
    .{ .name = "library.js", .body = library_js, .content_type = .JS },
    .{ .name = "footprint_svg.js", .body = footprint_svg_js, .content_type = .JS },
    .{ .name = "pcb_board.js", .body = pcb_board_js, .content_type = .JS },
    .{ .name = "auth_login.js", .body = auth_login_js, .content_type = .JS },
    .{ .name = "auth_setup.js", .body = auth_setup_js, .content_type = .JS },
    .{ .name = "auth_invite.js", .body = auth_invite_js, .content_type = .JS },
    .{ .name = "review_notes.js", .body = review_notes_js, .content_type = .JS },
    .{ .name = "editor.js", .body = editor_js, .content_type = .JS },
    .{ .name = "schematic_viewer.js", .body = schematic_viewer_js, .content_type = .JS },
    .{ .name = "schematic.css", .body = schematic_css, .content_type = .CSS },
    .{ .name = "codemirror.bundle.js", .body = codemirror_js, .content_type = .JS },
    .{ .name = "codemirror.css", .body = codemirror_css, .content_type = .CSS },
    .{ .name = "three.min.js", .body = three_js, .content_type = .JS },
    .{ .name = "OrbitControls.js", .body = orbit_controls_js, .content_type = .JS },
    .{ .name = "occt-import-js.js", .body = occt_import_js, .content_type = .JS },
    .{ .name = "occt-import-js.wasm", .body = occt_import_wasm, .content_type = .WASM },
    .{ .name = "model_viewer_3d.js", .body = model_viewer_3d_js, .content_type = .JS },
    .{ .name = "pcb_3d_viewer.js", .body = pcb_3d_viewer_js, .content_type = .JS },
};

/// GET /static/:name — serve an embedded JS/CSS asset. 404 if the name is
/// unknown, so pages can't accidentally pull an asset that isn't registered.
pub fn staticAsset(_: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = 404;
        res.body = "asset not found";
        return;
    };
    for (REGISTRY) |a| {
        if (std.mem.eql(u8, a.name, name)) {
            res.content_type = a.content_type;
            res.body = a.body;
            return;
        }
    }
    res.status = 404;
    res.body = "asset not found";
}
